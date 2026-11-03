# tests/publish_commit_test.sh — publish.sh commit/run against the fake
# server: two people publishing, refusals, swap-back, and crashes (SIGKILL)
# at each step of a publish.

PROJECT_B=""

two_devs() {   # a live site at v1; Tester ($PROJECT) and Joao ($PROJECT_B) both downloaded it
    sandbox_velk_server
    sandbox_theme "${SERVER}/theme"
    sandbox_config >/dev/null
    ( CONFIG_PATH="${PROJECT}/.deploy/ssh.json"; . "${SKILL_DIR}/scripts/theme/_lib.sh"; set +e
      build_ssh_args; load_theme_filters; write_server_state 1 "Setup" ) || fail "setup failed"
    PROJECT_B="${SANDBOX}/project-b"
    sandbox_config "$PROJECT_B" "Joao" >/dev/null
    for p in "$PROJECT" "$PROJECT_B"; do
        bash "${SKILL_DIR}/scripts/theme/download-theme.sh" --project "$p" >/dev/null 2>&1 || fail "download failed"
    done
}
publish() {   # publish <project> <action> [flags] — sets out, code
    local dir="$1"; shift
    out=$(bash "${SKILL_DIR}/scripts/theme/publish.sh" "$1" --project "$dir" "${@:2}" 2>"${SANDBOX}/err"); code=$?
}
live_version() { jq -r .version "${SERVER}/.velk-theme.json"; }
no_leftovers() {
    assert_no_dir "${SERVER}/.velk-theme-staging"; assert_no_dir "${SERVER}/.velk-theme-previous"
    assert_no_dir "${SERVER}/.velk-theme-failed";  assert_no_dir "${SERVER}/.velk-theme.lock"
    assert_no_file "${SERVER}/.velk-theme-check"
}

test_the_two_developers_example() {
    # v1 → Joao publishes (server = his base) → v2 → Tester publishes (server
    # ahead of his base): merged, validated → v3, with both changes live.
    two_devs
    echo '<?php echo "joao";' > "${PROJECT_B}/theme/templates/home.php"
    publish "$PROJECT_B" run
    assert_status 0 "$code" "$(cat "${SANDBOX}/err")"
    assert_contains "$out" "STATUS=PUBLISHED"
    assert_contains "$out" "VERSION=2"

    echo 'body { color: blue; }' > "${PROJECT}/theme/style.css"
    publish "$PROJECT" run
    assert_status 0 "$code" "$(cat "${SANDBOX}/err")"
    assert_contains "$out" "VERSION=3"
    assert_contains "$out" "TOOK_THEIRS=templates/home.php"
    assert_contains "$(cat "${SERVER}/theme/templates/home.php")" "joao"
    assert_contains "$(cat "${SERVER}/theme/style.css")" "blue"
    assert_eq "3" "$(live_version)"
    assert_eq "Tester" "$(jq -r .published_by "${SERVER}/.velk-theme.json")"
    no_leftovers
}

test_after_publishing_the_starting_point_is_what_went_live() {
    two_devs
    echo 'body { color: blue; }' > "${PROJECT}/theme/style.css"
    publish "$PROJECT" run
    assert_eq "2" "$(jq -r .version "${PROJECT}/.deploy/theme-base.json")"
    perl "${SKILL_DIR}/scripts/theme/manifest.pl" same "${PROJECT}/.deploy/theme-base.json" "${SERVER}/.velk-theme.json" \
        || fail "the local starting point must be exactly what was published"
    assert_no_dir "${PROJECT}/.deploy/publish"
}

test_a_plan_the_server_outdated_is_refused_then_redone() {
    two_devs
    echo 'body { color: blue; }' > "${PROJECT}/theme/style.css"
    publish "$PROJECT" prepare
    echo '<?php echo "joao";' > "${PROJECT_B}/theme/templates/home.php"
    publish "$PROJECT_B" run
    publish "$PROJECT" commit
    assert_status 8 "$code"
    assert_contains "$out" "STATUS=STALE_PLAN"
    assert_eq "2" "$(live_version)"
    publish "$PROJECT" run
    assert_status 0 "$code" "$(cat "${SANDBOX}/err")"
    assert_eq "3" "$(live_version)"
    assert_contains "$(cat "${SERVER}/theme/templates/home.php")" "joao"
}

test_run_waits_while_someone_else_publishes() {
    two_devs
    mkdir -p "${SERVER}/.velk-theme.lock"
    echo "Joao@other-mac" > "${SERVER}/.velk-theme.lock/owner"; date -u +%s > "${SERVER}/.velk-theme.lock/since"
    echo 'body { color: blue; }' > "${PROJECT}/theme/style.css"
    publish "$PROJECT" run
    assert_status 5 "$code"
    assert_contains "$out" "STATUS=BUSY"
    assert_contains "$out" "OWNER=Joao@other-mac"
    assert_not_contains "$(cat "${SERVER}/theme/style.css")" "blue"
}

test_a_syntax_error_never_goes_live() {
    two_devs
    echo '<?php if (' > "${PROJECT}/theme/templates/home.php"
    publish "$PROJECT" run
    assert_status 9 "$code"
    assert_contains "$out" "STATUS=STAGING_INVALID"
    assert_contains "$out" "DETAIL=PHP_LINT templates/home.php"
    assert_eq '<?php echo "home";' "$(cat "${SERVER}/theme/templates/home.php")"
    assert_eq "1" "$(live_version)"
    no_leftovers
}

test_a_theme_the_engine_rejects_is_swapped_back() {
    two_devs
    echo 'body { color: blue; }' > "${PROJECT}/theme/style.css"
    publish "$PROJECT" prepare
    echo 1 > "${SERVER}/.stub-exit-schema-validate"         # the new theme breaks it
    publish "$PROJECT" commit
    assert_status 9 "$code"
    assert_contains "$out" "STATUS=LIVE_INVALID"
    assert_contains "$out" "FAILURE=schema:validate"
    assert_not_contains "$(cat "${SERVER}/theme/style.css")" "blue"
    assert_eq "1" "$(live_version)"
    no_leftovers
}

test_a_broken_home_page_is_swapped_back() {
    two_devs
    echo 'body { color: blue; }' > "${PROJECT}/theme/style.css"
    publish "$PROJECT" prepare
    echo 500 > "$FAKE_HTTP_STATUS_FILE"                      # the new theme breaks it
    publish "$PROJECT" commit
    assert_status 9 "$code"
    assert_contains "$out" "FAILURE=home page answered 500"
    assert_not_contains "$(cat "${SERVER}/theme/style.css")" "blue"
    assert_eq "1" "$(live_version)"
    no_leftovers
}

test_deletions_go_live_only_once_confirmed() {
    two_devs
    rm "${PROJECT}/theme/partials/header.php"
    publish "$PROJECT" run
    assert_status 4 "$code"
    publish "$PROJECT" commit
    assert_status 4 "$code"
    assert_file "${SERVER}/theme/partials/header.php"
    publish "$PROJECT" commit --confirm-deletions
    assert_status 0 "$code" "$(cat "${SANDBOX}/err")"
    assert_no_file "${SERVER}/theme/partials/header.php"
}

test_a_resolved_conflict_is_published_as_resolved() {
    two_devs
    echo 'body { color: green; }' > "${PROJECT_B}/theme/style.css"
    publish "$PROJECT_B" run
    echo 'body { color: blue; }' > "${PROJECT}/theme/style.css"
    publish "$PROJECT" run
    assert_status 3 "$code"
    publish "$PROJECT" commit
    assert_status 3 "$code" "markers must block the commit"
    echo 'body { color: teal; }' > "${PROJECT}/theme/style.css"      # the user's decision
    publish "$PROJECT" commit
    assert_status 0 "$code" "$(cat "${SANDBOX}/err")"
    assert_eq "body { color: teal; }" "$(cat "${SERVER}/theme/style.css")"
    assert_eq "3" "$(live_version)"
}

test_files_filtered_out_of_the_theme_survive_a_publish() {
    two_devs
    mkdir -p "${SERVER}/theme/install"; echo '<?php if (' > "${SERVER}/theme/install/seed.php"   # never shipped, never linted
    echo 'body { color: blue; }' > "${PROJECT}/theme/style.css"
    publish "$PROJECT" run
    assert_status 0 "$code" "$(cat "${SANDBOX}/err")"
    assert_file "${SERVER}/theme/install/seed.php"
}

test_a_crash_while_staging_leaves_the_site_alone_and_the_next_publish_cleans_up() {
    two_devs
    echo 'body { color: blue; }' > "${PROJECT}/theme/style.css"
    VELK_TEST_CRASH_AT=after-staging publish "$PROJECT" run
    assert_dir "${SERVER}/.velk-theme-staging"; assert_dir "${SERVER}/.velk-theme.lock"
    assert_not_contains "$(cat "${SERVER}/theme/style.css")" "blue"
    publish "$PROJECT" run
    assert_status 0 "$code" "$(cat "${SANDBOX}/err")"
    assert_contains "$out" "RECOVERED=removed-staging"
    assert_eq "2" "$(live_version)"
    no_leftovers
}

test_a_crash_after_the_swap_is_finished_by_the_next_action() {
    two_devs
    echo 'body { color: blue; }' > "${PROJECT}/theme/style.css"
    VELK_TEST_CRASH_AT=after-swap publish "$PROJECT" run
    assert_dir "${SERVER}/.velk-theme-previous"
    assert_eq "1" "$(live_version)"
    publish "$PROJECT" run
    assert_status 0 "$code" "$(cat "${SANDBOX}/err")"
    assert_contains "$out" "RECOVERED=finished-publish"
    assert_contains "$out" "STATUS=UP_TO_DATE"
    assert_eq "2" "$(live_version)"
    assert_eq "2" "$(jq -r .version "${PROJECT}/.deploy/theme-base.json")"
    no_leftovers
}

test_a_crash_after_recording_never_counts_a_version_twice() {
    two_devs
    echo 'body { color: blue; }' > "${PROJECT}/theme/style.css"
    VELK_TEST_CRASH_AT=after-record publish "$PROJECT" run
    assert_eq "2" "$(live_version)"
    publish "$PROJECT" run
    assert_status 0 "$code" "$(cat "${SANDBOX}/err")"
    assert_contains "$out" "RECOVERED=already-recorded"
    assert_eq "2" "$(live_version)"
    assert_eq "2" "$(jq -r .version "${PROJECT}/.deploy/theme-base.json")"
    no_leftovers
}

test_commit_refuses_while_a_conflict_waits_for_a_decision() {
    two_devs
    rm "${PROJECT_B}/theme/partials/header.php"
    publish "$PROJECT_B" run
    publish "$PROJECT_B" commit --confirm-deletions
    assert_status 0 "$code" "$(cat "${SANDBOX}/err")"
    echo '<?php // tester' > "${PROJECT}/theme/partials/header.php"
    publish "$PROJECT" run
    assert_status 3 "$code"
    assert_contains "$out" "CONFLICT=changed-here-deleted-there partials/header.php"
    publish "$PROJECT" commit
    assert_status 3 "$code" "a conflict waiting for a decision must block the commit"
    assert_no_file "${SERVER}/theme/partials/header.php"
    bash "${SKILL_DIR}/scripts/theme/publish.sh" resolve --project "$PROJECT" partials/header.php local >/dev/null 2>&1
    publish "$PROJECT" run
    assert_status 0 "$code" "$(cat "${SANDBOX}/err")"
    assert_eq '<?php // tester' "$(cat "${SERVER}/theme/partials/header.php")"
}

test_commit_without_a_plan_says_so() {
    two_devs
    publish "$PROJECT" commit
    assert_status 2 "$code"
    assert_eq "STATUS=NO_PLAN" "$out"
}

test_commit_takes_the_lock_itself() {
    two_devs
    echo 'body { color: blue; }' > "${PROJECT}/theme/style.css"
    publish "$PROJECT" prepare
    FAKE_SSH_HOOK_ON="'acquire'" \
    FAKE_SSH_HOOK="mkdir -p '${SERVER}/.velk-theme.lock' && echo Maria@other-mac > '${SERVER}/.velk-theme.lock/owner' && date -u +%s > '${SERVER}/.velk-theme.lock/since'" \
        publish "$PROJECT" commit
    assert_status 5 "$code"
    assert_contains "$out" "STATUS=BUSY"
    assert_contains "$out" "OWNER=Maria@other-mac"
    assert_not_contains "$(cat "${SERVER}/theme/style.css")" "blue"
}

test_a_change_saved_during_the_publish_waits_for_the_next_one() {
    two_devs
    echo 'body { color: blue; }' > "${PROJECT}/theme/style.css"
    publish "$PROJECT" prepare
    assert_status 0 "$code" "$(cat "${SANDBOX}/err")"
    FAKE_SSH_HOOK_ON="cp -a theme .velk-theme-staging" \
    FAKE_SSH_HOOK="echo 'body { color: red; }' > '${PROJECT}/theme/style.css' && rm '${PROJECT}/theme/partials/header.php'" \
        publish "$PROJECT" commit
    assert_status 0 "$code" "$(cat "${SANDBOX}/err")"
    assert_eq "body { color: blue; }" "$(cat "${SERVER}/theme/style.css")"
    assert_file "${SERVER}/theme/partials/header.php" "a deletion nobody confirmed must not go live"
    assert_eq "body { color: blue; }" "$(cat "${PROJECT}/.deploy/theme-base/style.css")"
    assert_eq "body { color: red; }" "$(cat "${PROJECT}/theme/style.css")"
    publish "$PROJECT" run                                     # the next publish sees both changes
    assert_status 4 "$code"
    assert_contains "$out" "DELETE=partials/header.php"
}

test_a_deletion_made_after_the_list_was_shown_is_shown_again() {
    two_devs
    rm "${PROJECT}/theme/partials/header.php"
    publish "$PROJECT" prepare
    assert_status 4 "$code"
    rm "${PROJECT}/theme/style.css"                           # after the list was shown
    publish "$PROJECT" commit --confirm-deletions
    assert_status 4 "$code"
    assert_contains "$out" "STATUS=DELETIONS_CHANGED"
    assert_contains "$out" "DELETE=style.css"
    assert_file "${SERVER}/theme/style.css"
}

test_a_hand_edit_on_the_server_after_prepare_makes_the_plan_stale() {
    two_devs
    echo 'body { color: blue; }' > "${PROJECT}/theme/style.css"
    publish "$PROJECT" prepare
    echo '<?php // edited on the server' > "${SERVER}/theme/partials/header.php"   # same version, new content
    publish "$PROJECT" commit
    assert_status 8 "$code"
    assert_contains "$out" "STATUS=STALE_PLAN"
    assert_eq '<?php // edited on the server' "$(cat "${SERVER}/theme/partials/header.php")"
}

test_a_site_json_that_does_not_decode_never_goes_live() {
    two_devs
    echo '{ "site": ' > "${PROJECT}/theme/site.json"
    publish "$PROJECT" run
    assert_status 9 "$code"
    assert_contains "$out" "STATUS=STAGING_INVALID"
    assert_contains "$out" "DETAIL=SITE_JSON site.json is not valid JSON"
    assert_eq "1" "$(live_version)"
    no_leftovers
}

test_commit_checks_again_what_it_is_about_to_send() {
    two_devs
    mkdir -p "${PROJECT}/bin"; cp "${TESTS_DIR}/fixtures/bin-velk-stub.php" "${PROJECT}/bin/velk"
    cfg="${PROJECT}/.deploy/ssh.json"
    jq --arg php "$DEV_PHP" '.mode = "local" | .local.php_bin = $php' "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
    echo 'body { color: blue; }' > "${PROJECT}/theme/style.css"
    publish "$PROJECT" prepare
    assert_status 0 "$code" "$(cat "${SANDBOX}/err")"
    echo '<?php if (' > "${PROJECT}/theme/templates/home.php"   # broken after prepare
    publish "$PROJECT" commit
    assert_status 7 "$code"
    assert_contains "$out" "PHP_LINT=templates/home.php"
    assert_eq '<?php echo "home";' "$(cat "${SERVER}/theme/templates/home.php")"
}

test_run_reports_one_outcome_and_keeps_the_warnings() {
    two_devs
    echo '<?php // by hand' > "${SERVER}/theme/partials/header.php"   # changed outside the skill
    echo 'body { color: blue; }' > "${PROJECT}/theme/style.css"
    publish "$PROJECT" run
    assert_status 0 "$code" "$(cat "${SANDBOX}/err")"
    assert_eq "STATUS=PUBLISHED" "$(grep '^STATUS=' <<< "$out")"
    assert_contains "$out" "WARN=CHANGED_OUTSIDE_THE_SKILL"
    assert_eq "1" "$(grep -c '^TOOK_THEIRS=partials/header.php$' <<< "$out")"
}

test_a_check_that_never_ran_is_not_reported_as_a_refused_theme() {
    two_devs
    echo 'body { color: blue; }' > "${PROJECT}/theme/style.css"
    FAKE_SSH_HOOK_ON="/.velk-theme-staging' " FAKE_SSH_HOOK="rm -rf '${SERVER}/.velk-theme-staging'" \
        publish "$PROJECT" run
    assert_status 1 "$code"
    assert_not_contains "$out" "STAGING_INVALID"
    assert_eq "1" "$(live_version)"
    no_leftovers
}

test_a_staging_copy_that_cannot_be_listed_is_not_passed() {
    two_devs
    printf '#!/bin/bash\ncase "$PWD" in */.velk-theme-staging) exit 23 ;; esac\nexec /usr/bin/rsync "$@"\n' > "${FAKE_REMOTE_PATH}/rsync"
    chmod +x "${FAKE_REMOTE_PATH}/rsync"
    echo '<?php if (' > "${PROJECT}/theme/templates/home.php"
    publish "$PROJECT" run
    assert_status 1 "$code"
    assert_eq '<?php echo "home";' "$(cat "${SERVER}/theme/templates/home.php")"
    no_leftovers
}

test_a_cleanup_failure_after_recording_still_reports_the_publish() {
    two_devs
    echo 'body { color: blue; }' > "${PROJECT}/theme/style.css"
    base="${PROJECT}/.deploy/theme-base"
    FAKE_SSH_HOOK_ON="rm -rf .velk-theme-previous" \
    FAKE_SSH_HOOK="chmod 555 '${SERVER}/.velk-theme-previous/partials' && rm '${base}/style.css' && mkdir -p '${base}/style.css/x' && chmod 555 '${base}/style.css'" \
        publish "$PROJECT" run                                 # neither cleanup nor the local copy can finish
    chmod 755 "${SERVER}/.velk-theme-previous/partials" "${base}/style.css"
    assert_status 0 "$code" "$(cat "${SANDBOX}/err")"
    assert_contains "$out" "STATUS=PUBLISHED"
    assert_eq "2" "$(live_version)"
    assert_dir "${SERVER}/.velk-theme-previous"
    assert_eq "1" "$(jq -r .version "${PROJECT}/.deploy/theme-base.json")" "a copy that failed is not recorded"
    publish "$PROJECT" run                                     # the next action heals both
    assert_status 0 "$code" "$(cat "${SANDBOX}/err")"
    assert_contains "$out" "STATUS=UP_TO_DATE"
    assert_eq "2" "$(jq -r .version "${PROJECT}/.deploy/theme-base.json")"
    no_leftovers
}

test_a_swap_back_syncs_the_pages_again() {
    two_devs
    echo 'body { color: blue; }' > "${PROJECT}/theme/style.css"
    publish "$PROJECT" prepare
    echo 500 > "$FAKE_HTTP_STATUS_FILE"
    publish "$PROJECT" commit
    assert_status 9 "$code"
    assert_eq "2" "$(grep -c '^page:sync' "${SERVER}/.stub-calls")" "page:sync again, for the theme that went back"
}

test_changes_to_different_lines_of_one_file_are_published_merged() {
    two_devs
    printf '/* 1 */\n/* 2 */\n/* 3 */\n/* 4 */\n/* 5 */\n' > "${PROJECT_B}/theme/notes.css"
    publish "$PROJECT_B" run                                   # v2, with notes.css
    publish "$PROJECT" run                                     # Tester takes it in
    assert_contains "$out" "STATUS=UP_TO_DATE"
    sed -i '' 's|/\* 1 \*/|/* joao */|' "${PROJECT_B}/theme/notes.css"
    publish "$PROJECT_B" run                                   # v3
    sed -i '' 's|/\* 5 \*/|/* tester */|' "${PROJECT}/theme/notes.css"
    publish "$PROJECT" run
    assert_status 0 "$code" "$(cat "${SANDBOX}/err")"
    assert_contains "$out" "MERGED=notes.css"
    assert_contains "$(cat "${SERVER}/theme/notes.css")" "/* joao */"
    assert_contains "$(cat "${SERVER}/theme/notes.css")" "/* tester */"
    assert_eq "4" "$(live_version)"
}

test_a_home_page_behind_a_password_still_publishes() {
    two_devs
    echo 401 > "$FAKE_HTTP_STATUS_FILE"                      # basic auth, a firewall's 403…
    echo 'body { color: blue; }' > "${PROJECT}/theme/style.css"
    publish "$PROJECT" run
    assert_status 0 "$code" "$(cat "${SANDBOX}/err")"
    assert_contains "$out" "STATUS=PUBLISHED"
    assert_contains "$out" "WARN=HOME_PAGE_ANSWERED_401"
    assert_contains "$(grep '^curl ' "$FAKE_CALLS" | tail -1)" "?velk-check=" "past any page cache"
}

test_a_site_already_failing_stops_before_blaming_the_new_theme() {
    two_devs
    echo 1 > "${SERVER}/.stub-exit-schema-validate"           # broken before this publish
    echo 'body { color: blue; }' > "${PROJECT}/theme/style.css"
    publish "$PROJECT" run
    assert_status 10 "$code"
    assert_contains "$out" "STATUS=LIVE_ALREADY_FAILING"
    assert_contains "$out" "FAILURE=schema:validate"
    assert_not_contains "$(cat "${SERVER}/theme/style.css")" "blue"
    assert_eq "0" "$(grep -c '^page:sync' "${SERVER}/.stub-calls" 2>/dev/null || true)" "nothing swapped, nothing synced"
}

test_an_accepted_failure_only_warns_but_a_new_one_still_swaps_back() {
    two_devs
    echo 1 > "${SERVER}/.stub-exit-schema-validate"
    echo 'body { color: blue; }' > "${PROJECT}/theme/style.css"
    publish "$PROJECT" run --accept-live-failure
    assert_status 0 "$code" "$(cat "${SANDBOX}/err")"
    assert_contains "$out" "STATUS=PUBLISHED"
    assert_contains "$out" "WARN=STILL_FAILING schema:validate"
    echo 'body { color: red; }' > "${PROJECT}/theme/style.css"
    publish "$PROJECT" prepare --accept-live-failure
    echo 500 > "$FAKE_HTTP_STATUS_FILE"                      # something new breaks
    publish "$PROJECT" commit
    assert_status 9 "$code"
    assert_contains "$out" "FAILURE=home page answered 500"
    assert_contains "$(cat "${SERVER}/theme/style.css")" "blue"
}

test_confirm_deletions_belongs_to_commit_only() {
    two_devs
    rm "${PROJECT}/theme/partials/header.php"
    publish "$PROJECT" run --confirm-deletions
    assert_status 2 "$code"
    assert_contains "$(cat "${SANDBOX}/err")" "commit"
    assert_file "${SERVER}/theme/partials/header.php"
}

test_a_swap_that_fails_halfway_puts_the_live_theme_back() {
    two_devs
    echo 'body { color: blue; }' > "${PROJECT}/theme/style.css"
    FAKE_SSH_HOOK_ON="mv theme .velk-theme-previous" FAKE_SSH_HOOK="rm -rf '${SERVER}/.velk-theme-staging'" \
        publish "$PROJECT" run
    assert_status 1 "$code"
    assert_file "${SERVER}/theme/style.css" "the live theme is back"
    assert_not_contains "$(cat "${SERVER}/theme/style.css")" "blue"
    no_leftovers
}

test_a_theme_folder_that_is_a_link_is_refused() {
    two_devs
    mv "${SERVER}/theme" "${SERVER}/theme-real"; ln -s theme-real "${SERVER}/theme"
    echo 'body { color: blue; }' > "${PROJECT}/theme/style.css"
    publish "$PROJECT" run
    assert_status 1 "$code"
    assert_contains "$(cat "${SANDBOX}/err")" "link"
    assert_not_contains "$(cat "${SERVER}/theme-real/style.css")" "blue"
    [ -L "${SERVER}/theme" ] || fail "the link stays as it was"
}

test_a_php_that_is_gone_at_check_time_is_not_a_refused_theme() {
    two_devs
    echo 'body { color: blue; }' > "${PROJECT}/theme/style.css"
    FAKE_SSH_HOOK_ON="/.velk-theme-staging' " FAKE_SSH_HOOK="rm -f '${FAKE_REMOTE_PATH}/php'" \
        publish "$PROJECT" run
    assert_status 1 "$code"
    assert_not_contains "$out" "STAGING_INVALID"
    assert_eq "1" "$(live_version)"
    no_leftovers
}

test_every_failure_the_site_already_had_is_named_and_accepted() {
    two_devs
    echo 1 > "${SERVER}/.stub-exit-schema-validate"
    echo 500 > "$FAKE_HTTP_STATUS_FILE"
    echo 'body { color: blue; }' > "${PROJECT}/theme/style.css"
    publish "$PROJECT" run
    assert_status 10 "$code"
    assert_contains "$out" "FAILURE=schema:validate"
    assert_contains "$out" "FAILURE=home page answered 500"
    assert_contains "$out" "DETAIL=forced failure of schema:validate"
    publish "$PROJECT" run --accept-live-failure
    assert_status 0 "$code" "$(cat "${SANDBOX}/err")"
    assert_contains "$out" "WARN=STILL_FAILING schema:validate"
    assert_contains "$out" "WARN=STILL_FAILING home page answered 500"
}

test_a_site_already_failing_still_reports_what_came_in_from_the_server() {
    # prepare took Joao's publish into this copy before it found the site
    # failing: the person hears of it now, not never.
    two_devs
    echo '<?php echo "joao";' > "${PROJECT_B}/theme/templates/home.php"
    rm "${PROJECT_B}/theme/partials/header.php"
    publish "$PROJECT_B" prepare
    publish "$PROJECT_B" commit --confirm-deletions
    assert_status 0 "$code" "$(cat "${SANDBOX}/err")"
    echo 1 > "${SERVER}/.stub-exit-schema-validate"
    echo 'body { color: blue; }' > "${PROJECT}/theme/style.css"
    publish "$PROJECT" run
    assert_status 10 "$code"
    assert_contains "$out" "STATUS=LIVE_ALREADY_FAILING"
    assert_contains "$out" "TOOK_THEIRS=templates/home.php"
    assert_contains "$out" "GONE_FROM_SERVER=partials/header.php"
}

test_recovery_honours_an_accepted_failure() {
    two_devs
    echo 1 > "${SERVER}/.stub-exit-schema-validate"
    echo 'body { color: blue; }' > "${PROJECT}/theme/style.css"
    VELK_TEST_CRASH_AT=after-swap publish "$PROJECT" run --accept-live-failure
    out=$(bash "${SKILL_DIR}/scripts/theme/recover.sh" --project "$PROJECT" 2>/dev/null); code=$?
    assert_status 0 "$code"
    assert_contains "$out" "ACTION=finished-publish"
    assert_contains "$(cat "${SERVER}/theme/style.css")" "blue"
    assert_eq "2" "$(live_version)"
    no_leftovers
}

test_recovery_swaps_back_a_home_that_answered_before_and_not_after() {
    two_devs
    echo 'body { color: blue; }' > "${PROJECT}/theme/style.css"
    publish "$PROJECT" prepare
    echo 404 > "$FAKE_HTTP_STATUS_FILE"                      # fine before, gone after
    VELK_TEST_CRASH_AT=after-swap publish "$PROJECT" commit
    out=$(bash "${SKILL_DIR}/scripts/theme/recover.sh" --project "$PROJECT" 2>/dev/null); code=$?
    assert_status 0 "$code"
    assert_contains "$out" "ACTION=swapped-back"
    assert_not_contains "$(cat "${SERVER}/theme/style.css")" "blue"
    assert_eq "1" "$(live_version)"
    no_leftovers
}

test_a_publish_passes_on_what_its_recovery_warned_about() {
    two_devs
    echo 1 > "${SERVER}/.stub-exit-schema-validate"
    echo 'body { color: blue; }' > "${PROJECT}/theme/style.css"
    VELK_TEST_CRASH_AT=after-swap publish "$PROJECT" run --accept-live-failure
    publish "$PROJECT" prepare
    assert_status 0 "$code" "$(cat "${SANDBOX}/err")"
    assert_contains "$out" "RECOVERED=finished-publish"
    assert_contains "$out" "WARN=STILL_FAILING schema:validate"
}

test_a_home_page_that_answered_before_and_not_after_is_swapped_back() {
    two_devs
    echo 'body { color: blue; }' > "${PROJECT}/theme/style.css"
    publish "$PROJECT" prepare
    echo 404 > "$FAKE_HTTP_STATUS_FILE"                      # fine before, gone after
    publish "$PROJECT" commit
    assert_status 9 "$code"
    assert_contains "$out" "FAILURE=home page answered 404"
    assert_not_contains "$(cat "${SERVER}/theme/style.css")" "blue"
}

test_nothing_to_publish_is_up_to_date_even_on_a_failing_site() {
    two_devs
    echo 1 > "${SERVER}/.stub-exit-schema-validate"
    publish "$PROJECT" run
    assert_status 0 "$code"
    assert_contains "$out" "STATUS=UP_TO_DATE"
}
