# tests/integration_test.sh — everything that touches a site first finishes
# or undoes an interrupted publish, and a publish refuses a server that has
# no Velk yet.

site() {   # a live site at v1 — nothing downloaded yet
    sandbox_velk_server
    sandbox_theme "${SERVER}/theme"
    CFG=$(sandbox_config)
    ( CONFIG_PATH="$CFG"; . "${SKILL_DIR}/scripts/theme/_lib.sh"; set +e
      build_ssh_args; load_theme_filters; write_server_state 1 "Setup" ) || fail "setup failed"
}

test_a_publish_refuses_a_server_without_velk() {
    site
    rm "${SERVER}/core/Bootstrap.php"
    mkdir -p "${PROJECT}/theme"
    out=$(bash "${SKILL_DIR}/scripts/theme/publish.sh" run --project "$PROJECT" 2>/dev/null); code=$?
    assert_status 11 "$code"
    assert_eq "STATUS=NO_VELK" "$out"
    assert_no_dir "${SERVER}/.velk-theme.lock" "nothing was touched"
}

test_a_server_without_velk_is_refused_before_anything_on_it_is_recovered() {
    site
    rm "${SERVER}/core/Bootstrap.php"
    lock_as "Tester@$(hostname -s)" 30              # this machine's publish, died halfway
    mkdir -p "${SERVER}/.velk-theme-staging"
    mkdir -p "${PROJECT}/theme"
    out=$(bash "${SKILL_DIR}/scripts/theme/publish.sh" run --project "$PROJECT" 2>/dev/null); code=$?
    assert_status 11 "$code"
    assert_eq "STATUS=NO_VELK" "$out"
    assert_dir "${SERVER}/.velk-theme-staging" "the guard comes first: a server without Velk is not recovered"
    assert_file "${SERVER}/.velk-theme.lock/owner"
}

test_a_server_that_cannot_be_reached_is_not_mistaken_for_one_without_velk() {
    site
    mkdir -p "${PROJECT}/theme"
    out=$(FAKE_SSH_UNREACHABLE=1 bash "${SKILL_DIR}/scripts/theme/publish.sh" run --project "$PROJECT" 2>&1); code=$?
    assert_status 1 "$code"
    assert_not_contains "$out" "NO_VELK"
    assert_contains "$out" "Could not read the server"
}

test_downloading_the_theme_finishes_an_interrupted_publish_first() {
    site
    lock_as "Tester@$(hostname -s)" 30
    mkdir -p "${SERVER}/.velk-theme-staging"
    mv "${SERVER}/theme" "${SERVER}/.velk-theme-previous"      # died between the two renames
    out=$(bash "${SKILL_DIR}/scripts/theme/download-theme.sh" --project "$PROJECT" 2>/dev/null); code=$?
    assert_status 0 "$code"
    assert_contains "$out" "STATUS=DOWNLOADED"
    assert_contains "$out" "RECOVERED=restored-previous"
    assert_contains "$out" "RECOVERED=removed-staging"
    assert_file "${PROJECT}/theme/site.json" "the theme put back is what gets downloaded"
    assert_eq "1" "$(jq -r .version "${PROJECT}/.deploy/theme-base.json")"
    assert_no_dir "${SERVER}/.velk-theme-staging"
    assert_no_dir "${SERVER}/.velk-theme.lock"
}

test_downloading_the_theme_stops_at_a_lock_it_may_not_touch() {
    site
    lock_as "Maria@other-mac" 1000
    out=$(bash "${SKILL_DIR}/scripts/theme/download-theme.sh" --project "$PROJECT" 2>/dev/null); code=$?
    assert_status 5 "$code"
    assert_contains "$out" "STATUS=STALE_LOCK"
    assert_no_file "${PROJECT}/theme/site.json"
}

test_content_writes_clean_up_first_but_never_wait_for_a_theme_publish() {
    site
    lock_as "Tester@$(hostname -s)" 30
    mkdir -p "${SERVER}/.velk-theme-staging"
    echo '{"title":"x"}' | bash "${SKILL_DIR}/scripts/content/velk.sh" --project "$PROJECT" -- item:create post --json-stdin >/dev/null 2>&1
    assert_status 0 $?
    assert_no_dir "${SERVER}/.velk-theme-staging"
    assert_eq '{"title":"x"}' "$(cat "${SERVER}/.stub-stdin")" "the JSON reaches bin/velk, not the recovery"

    lock_as "Maria@other-mac" 30                     # a publish in progress
    echo '{"title":"y"}' | bash "${SKILL_DIR}/scripts/content/velk.sh" --project "$PROJECT" -- item:create post --json-stdin >/dev/null 2>&1
    assert_status 0 $? "a theme publish must not block content"
    assert_dir "${SERVER}/.velk-theme.lock" "and its lock stays"
    assert_eq $'{"title":"x"}\n{"title":"y"}' "$(cat "${SERVER}/.stub-stdin")"
}

test_a_content_dry_run_or_a_refused_call_recovers_nothing() {
    site
    lock_as "Tester@$(hostname -s)" 30
    mkdir -p "${SERVER}/.velk-theme-staging"
    echo '{"title":"x"}' | bash "${SKILL_DIR}/scripts/content/velk.sh" --project "$PROJECT" -- item:create post --json-stdin --dry-run >/dev/null 2>&1
    assert_status 0 $?
    bash "${SKILL_DIR}/scripts/content/velk.sh" --project "$PROJECT" item:create post >/dev/null 2>&1   # no "--"
    assert_status 2 $?
    assert_dir "${SERVER}/.velk-theme-staging" "neither a dry run nor a refused call touches the server"
}
