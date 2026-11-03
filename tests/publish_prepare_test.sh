# tests/publish_prepare_test.sh — publish.sh prepare/abort: deciding, merging
# into the local copy, and checking — without touching the server.

live_site() { sandbox_velk_server; sandbox_theme "${SERVER}/theme"; sandbox_config >/dev/null; }
download() {   # Tester's copy, downloaded from the live site
    bash "${SKILL_DIR}/scripts/theme/download-theme.sh" --project "$PROJECT" >/dev/null 2>&1 \
        || fail "download failed"
}
world() { live_site; download; }
server_lib() {   # the theme library, pointed at Tester's config
    CONFIG_PATH="${PROJECT}/.deploy/ssh.json"
    . "${SKILL_DIR}/scripts/theme/_lib.sh"; set +e
    build_ssh_args; load_theme_filters
}
server_publishes() {   # server_publishes <version> — what's live now, recorded as that version
    ( server_lib; write_server_state "$1" "Joao" ) || fail "could not record v$1"
}
prepare() {
    out=$(bash "${SKILL_DIR}/scripts/theme/publish.sh" prepare --project "$PROJECT" "$@" 2>"${SANDBOX}/err"); code=$?
}
snapshot() { rsync -a "$1/" "$2/"; }
same_tree() { diff -r "$1" "$2" >/dev/null || fail "trees differ: $1 vs $2"$'\n'"$(diff -r "$1" "$2")"; }

test_a_first_publish_on_an_unversioned_server_goes_straight_through() {
    world
    echo 'body { color: blue; }' > "${PROJECT}/theme/style.css"
    prepare
    assert_status 0 "$code" "$(cat "${SANDBOX}/err")"
    assert_contains "$out" "STATUS=READY"
    assert_contains "$out" "DECISION=fast"
    assert_contains "$out" "NEXT_VERSION=1"
    assert_file "${PROJECT}/.deploy/publish/plan.json"
    assert_not_contains "$(cat "${SERVER}/theme/style.css")" "blue" "prepare never touches the server"
}

test_what_the_server_gained_meanwhile_is_merged_into_the_local_copy() {
    world
    server_publishes 1
    echo '<?php echo "joao";' > "${SERVER}/theme/templates/home.php"
    server_publishes 2
    echo 'body { color: blue; }' > "${PROJECT}/theme/style.css"
    prepare
    assert_status 0 "$code" "$(cat "${SANDBOX}/err")"
    assert_contains "$out" "DECISION=merge"
    assert_contains "$out" "TOOK_THEIRS=templates/home.php"
    assert_contains "$out" "NEXT_VERSION=3"
    assert_contains "$(cat "${PROJECT}/theme/templates/home.php")" "joao"
    assert_contains "$(cat "${PROJECT}/theme/style.css")" "blue"
    assert_eq "2" "$(jq -r .version "${PROJECT}/.deploy/theme-base.json")" "the starting point is now the server's version"
}

test_a_conflict_stops_with_labelled_markers_and_asks() {
    world
    echo 'body { color: green; }' > "${SERVER}/theme/style.css"
    server_publishes 1
    echo 'body { color: blue; }' > "${PROJECT}/theme/style.css"
    prepare
    assert_status 3 "$code"
    assert_contains "$out" "STATUS=CONFLICTS"
    assert_contains "$out" "CONFLICT=text style.css"
    assert_contains "$(cat "${PROJECT}/theme/style.css")" "<<<<<<< local"
    assert_contains "$(cat "${SERVER}/theme/style.css")" "green" "the server is untouched"
}

test_prepare_again_refuses_until_the_markers_are_resolved() {
    world
    echo 'body { color: green; }' > "${SERVER}/theme/style.css"; server_publishes 1
    echo 'body { color: blue; }' > "${PROJECT}/theme/style.css"
    prepare
    prepare
    assert_status 3 "$code"
    assert_contains "$out" "STATUS=UNRESOLVED_CONFLICTS"
    assert_contains "$out" "CONFLICT_FILE=style.css"
}

test_abort_puts_the_local_copy_and_its_starting_point_back() {
    world
    echo 'body { color: green; }' > "${SERVER}/theme/style.css"; server_publishes 1
    echo 'body { color: blue; }' > "${PROJECT}/theme/style.css"
    snapshot "${PROJECT}/theme" "${SANDBOX}/before-theme"
    snapshot "${PROJECT}/.deploy/theme-base" "${SANDBOX}/before-base"
    cp "${PROJECT}/.deploy/theme-base.json" "${SANDBOX}/before-base.json"
    prepare
    out=$(bash "${SKILL_DIR}/scripts/theme/publish.sh" abort --project "$PROJECT" 2>/dev/null)
    assert_eq "STATUS=ABORTED" "$out"
    same_tree "${SANDBOX}/before-theme" "${PROJECT}/theme"
    same_tree "${SANDBOX}/before-base" "${PROJECT}/.deploy/theme-base"
    cmp -s "${SANDBOX}/before-base.json" "${PROJECT}/.deploy/theme-base.json" || fail "theme-base.json must be back"
    assert_no_dir "${PROJECT}/.deploy/publish"
}

test_deleting_a_live_file_needs_confirmation() {
    world
    rm "${PROJECT}/theme/partials/header.php"
    prepare
    assert_status 4 "$code"
    assert_contains "$out" "STATUS=NEEDS_CONFIRMATION"
    assert_contains "$out" "DELETE=partials/header.php"
}

test_a_starting_point_ahead_of_the_server_stops() {
    world
    server_publishes 2
    jq '.version = 5' "${PROJECT}/.deploy/theme-base.json" > "${SANDBOX}/b" && mv "${SANDBOX}/b" "${PROJECT}/.deploy/theme-base.json"
    echo 'x' > "${PROJECT}/theme/new.css"
    prepare
    assert_status 6 "$code"
    assert_contains "$out" "STATUS=BASE_AHEAD"
    assert_contains "$out" "BASE_VERSION=5"
    assert_contains "$out" "SERVER_VERSION=2"
}

test_an_unreadable_server_record_joins_nothing_silently() {
    world
    echo 'not json' > "${SERVER}/.velk-theme.json"
    echo 'body { color: blue; }' > "${PROJECT}/theme/style.css"
    prepare
    assert_status 3 "$code"
    assert_contains "$out" "DECISION=two-way"
    assert_contains "$out" "WARN=SERVER_RECORD_UNREADABLE"
    assert_contains "$out" "CONFLICT=added-both style.css"
}

test_a_change_made_outside_the_skill_is_merged_not_overwritten() {
    world
    server_publishes 1
    echo '<?php // edited over FTP' > "${SERVER}/theme/partials/header.php"
    echo 'body { color: blue; }' > "${PROJECT}/theme/style.css"
    prepare
    assert_status 0 "$code"
    assert_contains "$out" "WARN=CHANGED_OUTSIDE_THE_SKILL"
    assert_contains "$out" "TOOK_THEIRS=partials/header.php"
    assert_contains "$(cat "${PROJECT}/theme/partials/header.php")" "FTP"
}

test_nothing_to_publish_is_said_plainly() {
    world
    prepare
    assert_status 0 "$code"
    assert_contains "$out" "STATUS=UP_TO_DATE"
    assert_no_file "${PROJECT}/.deploy/publish/plan.json"
}

test_css_loaded_without_a_version_in_its_url_is_flagged() {
    world
    echo "<link rel=\"stylesheet\" href=\"<?= e(asset('theme/style.css')) ?>\">" > "${PROJECT}/theme/partials/header.php"
    echo 'body { color: blue; }' > "${PROJECT}/theme/style.css"
    prepare
    assert_contains "$out" "WARN=CACHE_BUSTING"
}

test_css_urls_in_files_that_are_never_published_are_not_flagged() {
    world
    mkdir -p "${PROJECT}/theme/install"
    echo "<link href=\"<?= e(asset('theme/style.css')) ?>\">" > "${PROJECT}/theme/install/seed.php"   # the seed is never published
    echo 'body { color: blue; }' > "${PROJECT}/theme/style.css"
    prepare
    assert_contains "$out" "STATUS=READY"
    assert_not_contains "$out" "CACHE_BUSTING"
}

test_versioned_css_urls_are_not_flagged() {
    world
    echo "<link href=\"<?= e(asset('theme/style.css') . '?v=' . filemtime(dirname(__DIR__) . '/style.css')) ?>\">" \
        > "${PROJECT}/theme/partials/header.php"
    echo 'body { color: blue; }' > "${PROJECT}/theme/style.css"
    prepare
    assert_contains "$out" "STATUS=READY"
    assert_not_contains "$out" "CACHE_BUSTING"
}

test_local_checks_stop_a_broken_theme_before_the_server() {
    world
    cp "${TESTS_DIR}/fixtures/bin-velk-stub.php" "${PROJECT}/bin-velk"; mkdir -p "${PROJECT}/bin"
    mv "${PROJECT}/bin-velk" "${PROJECT}/bin/velk"
    cfg="${PROJECT}/.deploy/ssh.json"
    jq --arg php "$DEV_PHP" '.mode = "local" | .local.php_bin = $php' "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
    echo '<?php if (' > "${PROJECT}/theme/templates/home.php"
    prepare
    assert_status 7 "$code"
    assert_contains "$out" "STATUS=LOCAL_INVALID"
    assert_contains "$out" "PHP_LINT=templates/home.php"
}

resolve() { bash "${SKILL_DIR}/scripts/theme/publish.sh" resolve --project "$PROJECT" "$@" 2>/dev/null; }

test_a_binary_conflict_waits_for_a_decision_across_tries() {
    live_site; printf 'P\0base' > "${SERVER}/theme/logo.png"; download
    printf 'P\0server' > "${SERVER}/theme/logo.png"; server_publishes 1
    printf 'P\0mine' > "${PROJECT}/theme/logo.png"
    prepare
    assert_status 3 "$code"
    assert_contains "$out" "CONFLICT=binary logo.png"
    prepare                                                   # a retry must not forget it
    assert_status 3 "$code"
    assert_contains "$out" "STATUS=UNRESOLVED_CONFLICTS"
    assert_contains "$out" "CONFLICT=binary logo.png"
    out=$(resolve logo.png server)
    assert_contains "$out" "STATUS=RESOLVED"
    cmp -s "${SERVER}/theme/logo.png" "${PROJECT}/theme/logo.png" || fail "the server's logo must be in place"
    prepare
    assert_status 0 "$code"
    assert_contains "$out" "STATUS=UP_TO_DATE"
}

test_a_change_to_a_file_the_server_deleted_waits_for_a_decision() {
    world
    rm "${SERVER}/theme/partials/header.php"; server_publishes 1
    echo '<?php // mine' > "${PROJECT}/theme/partials/header.php"
    prepare
    assert_status 3 "$code"
    assert_contains "$out" "CONFLICT=changed-here-deleted-there partials/header.php"
    out=$(resolve partials/header.php local)
    assert_contains "$out" "KEPT=local"
    prepare
    assert_status 0 "$code"
    assert_contains "$out" "STATUS=READY"
    assert_file "${PROJECT}/theme/partials/header.php"
}

test_a_binary_conflict_can_keep_this_copy() {
    live_site; printf 'P\0base' > "${SERVER}/theme/logo.png"; download
    printf 'P\0server' > "${SERVER}/theme/logo.png"; server_publishes 1
    printf 'P\0mine' > "${PROJECT}/theme/logo.png"
    prepare
    assert_status 3 "$code"
    assert_contains "$(resolve logo.png local)" "KEPT=local"
    prepare
    assert_status 0 "$code"
    assert_contains "$out" "STATUS=READY"
    cmp -s <(printf 'P\0mine') "${PROJECT}/theme/logo.png" || fail "this copy's logo must stay"
}

test_resolve_wants_one_path_and_a_side() {
    world
    out=$(resolve style.css); code=$?
    assert_status 2 "$code"; assert_eq "" "$out"
    out=$(resolve style.css both); code=$?
    assert_status 2 "$code"; assert_eq "" "$out"
    out=$(resolve style.css local extra); code=$?
    assert_status 2 "$code"; assert_eq "" "$out"
}

test_resolve_refuses_a_path_with_no_open_conflict() {
    world
    out=$(resolve style.css local); code=$?
    assert_status 2 "$code"
    assert_contains "$out" "STATUS=NOT_OPEN"
}

test_either_side_of_a_deletion_conflict_can_be_kept() {
    world
    rm "${SERVER}/theme/partials/header.php"
    echo '<?php echo "server home";' > "${SERVER}/theme/templates/home.php"; server_publishes 1
    echo '<?php // mine' > "${PROJECT}/theme/partials/header.php"    # changed here, deleted there
    rm "${PROJECT}/theme/templates/home.php"                        # deleted here, changed there
    prepare
    assert_status 3 "$code"
    assert_contains "$out" "CONFLICT=changed-here-deleted-there partials/header.php"
    assert_contains "$out" "CONFLICT=deleted-here-changed-there templates/home.php"
    assert_contains "$(resolve partials/header.php server)" "KEPT=server"
    assert_contains "$(resolve templates/home.php local)" "KEPT=local"
    assert_no_file "${PROJECT}/theme/partials/header.php"
    assert_no_file "${PROJECT}/theme/templates/home.php"
    prepare
    assert_status 4 "$code"
    assert_contains "$out" "DELETE=templates/home.php"
}

test_a_site_json_the_merge_broke_waits_until_it_is_valid() {
    live_site; printf '{\n  "a": 1,\n  "s": 0,\n  "b": 2\n}\n' > "${SERVER}/theme/site.json"; download
    printf '{\n  "a": 1,\n  "s": 0,\n  "b": 3\n}\n' > "${SERVER}/theme/site.json"; server_publishes 1
    printf '{\n  "a": 1\n  "s": 0,\n  "b": 2\n}\n' > "${PROJECT}/theme/site.json"
    prepare
    assert_status 3 "$code"
    assert_contains "$out" "CONFLICT=invalid-json site.json"
    out=$(resolve site.json server); code=$?
    assert_status 2 "$code"                                   # settled by fixing the file, not by a side
    prepare                                                   # still not JSON: still waiting
    assert_status 3 "$code"
    assert_contains "$out" "CONFLICT=invalid-json site.json"
    printf '{\n  "a": 1,\n  "s": 0,\n  "b": 3\n}\n' > "${PROJECT}/theme/site.json"
    prepare
    assert_status 0 "$code"
    assert_contains "$out" "STATUS=UP_TO_DATE"
}

test_an_interrupted_backup_is_never_trusted() {
    world
    echo 'body { color: green; }' > "${SERVER}/theme/style.css"; server_publishes 1
    echo '<?php // my work' > "${PROJECT}/theme/partials/mywork.php"
    chmod 000 "${PROJECT}/theme/partials/mywork.php"
    prepare                                                   # the backup copy fails midway
    chmod 644 "${PROJECT}/theme/partials/mywork.php"
    [ "$code" -ne 0 ] || fail "prepare must stop when the backup can't be made"
    prepare
    out=$(bash "${SKILL_DIR}/scripts/theme/publish.sh" abort --project "$PROJECT" 2>/dev/null)
    assert_eq "STATUS=ABORTED" "$out"
    assert_eq "<?php // my work" "$(cat "${PROJECT}/theme/partials/mywork.php")"
}

test_abort_leaves_files_the_publish_never_touches() {
    world
    mkdir -p "${PROJECT}/theme/install"; echo 'v1' > "${PROJECT}/theme/install/seed.php"
    echo 'a { }' > "${PROJECT}/theme/mine.css"               # something to publish: no UP_TO_DATE
    echo 'body { color: green; }' > "${SERVER}/theme/style.css"; server_publishes 1
    prepare
    echo 'v2' > "${PROJECT}/theme/install/seed.php"           # edited after prepare
    bash "${SKILL_DIR}/scripts/theme/publish.sh" abort --project "$PROJECT" >/dev/null 2>&1
    assert_eq "v2" "$(cat "${PROJECT}/theme/install/seed.php")"
}

test_a_second_prepare_keeps_the_first_backup() {
    world
    echo 'a { }' > "${PROJECT}/theme/mine.css"               # something to publish: no UP_TO_DATE
    snapshot "${PROJECT}/theme" "${SANDBOX}/before-theme"
    echo 'body { color: green; }' > "${SERVER}/theme/style.css"; server_publishes 1
    prepare                                                   # merges, backs up the original
    echo '<?php // server 2' > "${SERVER}/theme/partials/header.php"; server_publishes 2
    prepare                                                   # merges again
    bash "${SKILL_DIR}/scripts/theme/publish.sh" abort --project "$PROJECT" >/dev/null 2>&1
    same_tree "${SANDBOX}/before-theme" "${PROJECT}/theme"
}

test_an_unreadable_record_gives_the_version_after_the_starting_point() {
    world
    jq '.version = 5' "${PROJECT}/.deploy/theme-base.json" > "${SANDBOX}/b" && mv "${SANDBOX}/b" "${PROJECT}/.deploy/theme-base.json"
    echo 'not json' > "${SERVER}/.velk-theme.json"
    echo 'b { }' > "${PROJECT}/theme/new.css"
    prepare
    assert_status 0 "$code"
    assert_contains "$out" "NEXT_VERSION=6"
}

test_a_server_without_a_record_is_behind_a_versioned_starting_point() {
    world
    jq '.version = 3' "${PROJECT}/.deploy/theme-base.json" > "${SANDBOX}/b" && mv "${SANDBOX}/b" "${PROJECT}/.deploy/theme-base.json"
    echo 'x' > "${PROJECT}/theme/new.css"
    prepare
    assert_status 6 "$code"
    assert_contains "$out" "SERVER_VERSION=none"
}

test_an_unreadable_record_does_not_merge_twice() {
    world
    echo 'not json' > "${SERVER}/.velk-theme.json"
    echo 'body { color: blue; }' > "${PROJECT}/theme/style.css"
    prepare
    assert_status 3 "$code"
    assert_contains "$out" "CONFLICT=added-both style.css"
    echo 'body { color: blue; }' > "${PROJECT}/theme/style.css"   # the user's decision
    prepare
    assert_status 0 "$code"
    assert_contains "$out" "DECISION=fast"
}

test_links_and_empty_folders_survive_a_merge() {
    world
    ln -s style.css "${PROJECT}/theme/alias.css"
    mkdir -p "${PROJECT}/theme/assets/empty"
    echo 'body { color: green; }' > "${SERVER}/theme/style.css"; server_publishes 1
    prepare
    [ -L "${PROJECT}/theme/alias.css" ] || fail "the link must survive the merge"
    assert_dir "${PROJECT}/theme/assets/empty"
}

test_an_empty_file_survives_a_merge() {
    live_site; : > "${SERVER}/theme/.gitkeep"; download
    echo 'body { color: green; }' > "${SERVER}/theme/style.css"; server_publishes 1
    prepare
    assert_status 0 "$code" "$(cat "${SANDBOX}/err")"
    [ -r "${PROJECT}/theme/.gitkeep" ] && [ ! -s "${PROJECT}/theme/.gitkeep" ] || fail ".gitkeep must stay empty and readable"
}

test_a_folder_the_server_turned_into_a_file_comes_in() {
    world
    rm -r "${SERVER}/theme/partials"; echo 'now a file' > "${SERVER}/theme/partials"; server_publishes 1
    prepare
    assert_status 0 "$code" "$(cat "${SANDBOX}/err")"
    assert_eq "now a file" "$(cat "${PROJECT}/theme/partials")"
}

test_a_file_the_server_turned_into_a_folder_comes_in() {
    live_site; echo 'one icon' > "${SERVER}/theme/icons"; download
    rm "${SERVER}/theme/icons"; mkdir "${SERVER}/theme/icons"; echo '<svg/>' > "${SERVER}/theme/icons/a.svg"; server_publishes 1
    prepare
    assert_status 0 "$code" "$(cat "${SANDBOX}/err")"
    assert_eq "<svg/>" "$(cat "${PROJECT}/theme/icons/a.svg")"
}

test_markers_in_files_that_are_never_published_do_not_block() {
    world
    printf '<<<<<<< local\nx\n=======\ny\n>>>>>>> server\n' > "${PROJECT}/theme/style.css.bak"
    echo 'body { color: blue; }' > "${PROJECT}/theme/style.css"
    prepare
    assert_status 0 "$code"
    assert_contains "$out" "STATUS=READY"
}

test_up_to_date_still_reports_warnings() {
    world
    echo 'not json' > "${SERVER}/.velk-theme.json"
    prepare
    assert_contains "$out" "STATUS=UP_TO_DATE"
    assert_contains "$out" "WARN=SERVER_RECORD_UNREADABLE"
}

test_prepare_never_writes_to_the_server() {
    world
    echo 'body { color: green; }' > "${SERVER}/theme/style.css"; server_publishes 1
    echo '<?php // mine' > "${PROJECT}/theme/partials/header.php"
    snapshot "$SERVER" "${SANDBOX}/server-before"
    prepare
    # .stub-calls and .stub-argv are the fake engine's own logs: the checks
    # before a publish run schema:validate, which only reads — never
    # page:sync, which writes.
    diff -r -x .stub-calls -x .stub-argv "${SANDBOX}/server-before" "$SERVER" >/dev/null \
        || fail "prepare wrote to the server: $(diff -r -x .stub-calls -x .stub-argv "${SANDBOX}/server-before" "$SERVER")"
    assert_not_contains "$(cat "${SERVER}/.stub-calls" 2>/dev/null)" "page:sync"
}

test_a_file_the_server_deleted_is_reported() {
    world
    rm "${SERVER}/theme/partials/header.php"; server_publishes 1
    echo 'body { color: blue; }' > "${PROJECT}/theme/style.css"
    prepare
    assert_contains "$out" "GONE_FROM_SERVER=partials/header.php"
    assert_no_file "${PROJECT}/theme/partials/header.php"
}

test_a_file_the_server_deleted_is_reported_even_with_nothing_to_publish() {
    world
    rm "${SERVER}/theme/partials/header.php"; server_publishes 1
    prepare
    assert_contains "$out" "STATUS=UP_TO_DATE"
    assert_contains "$out" "GONE_FROM_SERVER=partials/header.php"
}

test_a_refused_prepare_leaves_no_plan_behind() {
    world
    echo 'body { color: blue; }' > "${PROJECT}/theme/style.css"
    prepare
    assert_status 0 "$code"
    assert_file "${PROJECT}/.deploy/publish/plan.json"
    printf '<<<<<<< local\nx\n=======\ny\n>>>>>>> server\n' > "${PROJECT}/theme/style.css"
    prepare
    assert_status 3 "$code"
    assert_no_file "${PROJECT}/.deploy/publish/plan.json"
}

test_a_stray_argument_is_refused() {
    world
    prepare style.css
    assert_status 2 "$code"
}

test_a_text_conflict_can_be_settled_by_keeping_this_copys_side() {
    world
    echo 'body { color: green; }' > "${SERVER}/theme/style.css"; server_publishes 1
    echo 'body { color: blue; }' > "${PROJECT}/theme/style.css"
    prepare
    assert_status 3 "$code"
    assert_contains "$out" "CONFLICT=text style.css"
    assert_contains "$(resolve style.css local)" "KEPT=local"
    assert_eq 'body { color: blue; }' "$(cat "${PROJECT}/theme/style.css")"
    prepare
    assert_status 0 "$code"
    assert_contains "$out" "STATUS=READY"
}

test_a_text_conflict_can_take_the_live_side() {
    world
    echo 'body { color: green; }' > "${SERVER}/theme/style.css"; server_publishes 1
    echo 'body { color: blue; }' > "${PROJECT}/theme/style.css"
    prepare
    assert_contains "$(resolve style.css server)" "KEPT=server"
    assert_eq 'body { color: green; }' "$(cat "${PROJECT}/theme/style.css")"
    prepare
    assert_status 0 "$code"
    assert_contains "$out" "STATUS=UP_TO_DATE"
}

test_the_first_versioned_publish_of_an_older_project_settles_file_by_file() {
    world
    rm -rf "${PROJECT}/.deploy/theme-base" "${PROJECT}/.deploy/theme-base.json"   # predates versioning
    echo 'body { color: blue; }' > "${PROJECT}/theme/style.css"
    prepare
    assert_status 3 "$code"
    assert_contains "$out" "CONFLICT=added-both style.css"
    assert_contains "$(resolve style.css local)" "KEPT=local"
    prepare
    assert_status 0 "$code"
    assert_contains "$out" "STATUS=READY"
}

test_local_checks_read_a_noisy_production_php_right() {
    world
    noisy_server_php
    mkdir -p "${PROJECT}/bin"; cp "${TESTS_DIR}/fixtures/bin-velk-stub.php" "${PROJECT}/bin/velk"
    cfg="${PROJECT}/.deploy/ssh.json"
    jq --arg php "$DEV_PHP" '.mode = "local" | .local.php_bin = $php' "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
    echo 'body { color: blue; }' > "${PROJECT}/theme/style.css"
    prepare
    assert_status 0 "$code" "$(cat "${SANDBOX}/err")"
    assert_not_contains "$out" "LOCAL_PHP_DIFFERS"
}

test_source_pages_left_in_the_theme_stop_prepare_before_the_server() {   # the same rule init applies
    world
    echo '<?php // index.php do template' > "${PROJECT}/theme/index.php"
    mkdir -p "${PROJECT}/theme/includes"; echo '<?php' > "${PROJECT}/theme/includes/dados.php"
    prepare
    assert_status 7 "$code"
    assert_contains "$out" "STATUS=SOURCE_LEFTOVERS"
    assert_contains "$out" "LEFTOVER=theme/index.php"
    assert_contains "$out" "LEFTOVER=theme/includes/"
    assert_no_file "${PROJECT}/.deploy/publish/plan.json"
}

test_functions_php_is_not_a_leftover() {
    world
    echo '<?php function tema_ok() {}' > "${PROJECT}/theme/functions.php"
    prepare
    assert_status 0 "$code" "$(cat "${SANDBOX}/err")"
    assert_contains "$out" "STATUS=READY"
}

test_stray_php_on_the_server_is_reported() {   # outside every manifest: a publish can't see or delete it
    world
    echo '<?php' > "${SERVER}/theme/header.php"
    echo 'body { color: blue; }' > "${PROJECT}/theme/style.css"
    prepare
    assert_status 0 "$code" "$(cat "${SANDBOX}/err")"
    assert_contains "$out" "WARN=SERVER_LEFTOVERS theme/header.php"
}
