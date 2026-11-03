# tests/theme_download_test.sh — bringing the live theme down, the starting
# point it leaves behind, the throwaway workspace, and the working mode.

live_site() {   # an installed Velk with a theme on the fake server
    sandbox_velk_server
    sandbox_theme "${SERVER}/theme"
    mkdir -p "${SERVER}/theme/install"; echo seed > "${SERVER}/theme/install/seed.php"
}

download() { bash "${SKILL_DIR}/scripts/theme/download-theme.sh" --project "${1:-$PROJECT}" 2>/dev/null; }

test_download_brings_the_theme_and_records_version_zero_when_unversioned() {
    live_site
    sandbox_config >/dev/null
    out=$(download); code=$?
    assert_status 0 "$code"
    assert_contains "$out" "STATUS=DOWNLOADED"
    assert_contains "$out" "VERSION=0"
    assert_eq "$(cat "${SERVER}/theme/style.css")" "$(cat "${PROJECT}/theme/style.css")"
    assert_no_file "${PROJECT}/theme/install/seed.php" "filtered files stay on the server"
    assert_eq "0" "$(jq -r .version "${PROJECT}/.deploy/theme-base.json")"
    assert_file "${PROJECT}/.deploy/theme-base/templates/home.php"
}

test_the_starting_point_matches_the_live_manifest() {
    live_site
    cfg=$(sandbox_config)
    download >/dev/null
    CONFIG_PATH="$cfg"; . "${SKILL_DIR}/scripts/theme/_lib.sh"; set +e
    build_ssh_args; load_theme_filters
    remote_theme_manifest > "${SANDBOX}/live.json"
    perl "${SKILL_DIR}/scripts/theme/manifest.pl" same "${SANDBOX}/live.json" "${PROJECT}/.deploy/theme-base.json" \
        || fail "theme-base.json must describe what is live"
}

test_download_records_the_server_version() {
    live_site
    sandbox_config >/dev/null
    printf '{"format":1,"version":4,"files":{}}\n' > "${SERVER}/.velk-theme.json"
    out=$(download)
    assert_contains "$out" "VERSION=4"
    assert_eq "4" "$(jq -r .version "${PROJECT}/.deploy/theme-base.json")"
}

test_workspace_open_always_starts_from_a_fresh_download() {
    live_site
    sandbox_config >/dev/null
    mkdir -p "${PROJECT}/.deploy/workspace/theme" "${PROJECT}/.deploy/workspace/.deploy/publish"
    echo stale > "${PROJECT}/.deploy/workspace/theme/leftover.css"
    echo '{"next_version": 9}' > "${PROJECT}/.deploy/workspace/.deploy/publish/plan.json"   # an abandoned plan
    out=$(bash "${SKILL_DIR}/scripts/theme/workspace.sh" open --project "$PROJECT" 2>/dev/null); code=$?
    assert_status 0 "$code"
    assert_contains "$out" "STATUS=OPEN"
    assert_contains "$out" "WORKSPACE=${PROJECT}/.deploy/workspace"
    assert_contains "$out" "DISCARDED=1"
    assert_no_file "${PROJECT}/.deploy/workspace/theme/leftover.css"
    assert_no_dir "${PROJECT}/.deploy/workspace/.deploy/publish" "nothing of an old session survives"
    assert_file "${PROJECT}/.deploy/workspace/theme/site.json"
    assert_file "${PROJECT}/.deploy/workspace/.deploy/theme-base.json"
    assert_eq "600" "$(stat -f %Lp "${PROJECT}/.deploy/workspace/.deploy/ssh.json")"
}

test_workspace_close_leaves_nothing_behind() {
    live_site
    sandbox_config >/dev/null
    bash "${SKILL_DIR}/scripts/theme/workspace.sh" open --project "$PROJECT" >/dev/null 2>&1
    out=$(bash "${SKILL_DIR}/scripts/theme/workspace.sh" close --project "$PROJECT" 2>/dev/null)
    assert_eq "STATUS=CLOSED" "$out"
    assert_no_dir "${PROJECT}/.deploy/workspace"
    assert_file "${PROJECT}/.deploy/ssh.json" "the real config stays"
}

test_the_working_mode_is_recorded_in_the_config() {
    sandbox_config >/dev/null
    out=$(bash "${SKILL_DIR}/scripts/access/connect.sh" mode live --project "$PROJECT" 2>/dev/null)
    assert_contains "$out" "MODE=live"
    assert_eq "live" "$(jq -r .mode "${PROJECT}/.deploy/ssh.json")"
    bash "${SKILL_DIR}/scripts/access/connect.sh" mode sideways --project "$PROJECT" >/dev/null 2>&1
    assert_status 2 $?
}

test_the_starting_point_copies_content_even_when_size_and_time_match() {
    # rsync's quick check compares size + mtime; a file edited within the same
    # second at the same size would be skipped. Every theme copy uses -c.
    live_site
    sandbox_config >/dev/null
    download >/dev/null
    printf 'AAAA' > "${PROJECT}/theme/style.css"
    printf 'BBBB' > "${PROJECT}/.deploy/theme-base/style.css"
    touch -t 202601010000 "${PROJECT}/theme/style.css" "${PROJECT}/.deploy/theme-base/style.css"
    CONFIG_PATH="${PROJECT}/.deploy/ssh.json"; . "${SKILL_DIR}/scripts/theme/_lib.sh"; set +e
    load_theme_filters
    record_theme_base "$PROJECT" 0
    assert_eq "AAAA" "$(cat "${PROJECT}/.deploy/theme-base/style.css")"
}

test_workspace_open_passes_on_someone_elses_publish() {
    live_site
    sandbox_config >/dev/null
    lock_as "Maria@other-mac" 30
    out=$(bash "${SKILL_DIR}/scripts/theme/workspace.sh" open --project "$PROJECT" 2>/dev/null); code=$?
    assert_status 5 "$code"
    assert_contains "$out" "STATUS=BUSY"
    assert_contains "$out" "OWNER=Maria@other-mac"
    assert_no_dir "${PROJECT}/.deploy/workspace"
}

test_workspace_open_can_take_over_a_stale_lock() {
    live_site
    sandbox_config >/dev/null
    lock_as "Maria@other-mac" 1000
    out=$(bash "${SKILL_DIR}/scripts/theme/workspace.sh" open --project "$PROJECT" 2>/dev/null); code=$?
    assert_status 5 "$code"
    assert_contains "$out" "STATUS=STALE_LOCK"
    out=$(bash "${SKILL_DIR}/scripts/theme/workspace.sh" open --project "$PROJECT" --take-over-stale 2>/dev/null); code=$?
    assert_status 0 "$code"
    assert_contains "$out" "STATUS=OPEN"
    assert_contains "$out" "RECOVERED=released-lock"
    assert_no_dir "${SERVER}/.velk-theme.lock"
}

test_a_download_clears_an_unfinished_publish() {
    live_site
    sandbox_config >/dev/null
    mkdir -p "${PROJECT}/.deploy/publish"
    echo '[{"kind":"binary","path":"logo.png"}]' > "${PROJECT}/.deploy/publish/open-conflicts.json"
    download >/dev/null
    assert_no_dir "${PROJECT}/.deploy/publish" "a fresh copy starts no publish half-done"
}

test_a_download_passes_on_what_the_recovery_warned_about() {
    live_site
    sandbox_config >/dev/null
    unrecorded_swap_with_warning
    out=$(download); code=$?
    assert_status 0 "$code"
    assert_contains "$out" "RECOVERED=finished-publish"
    assert_contains "$out" "WARN=STILL_FAILING schema:validate"
}

test_workspace_open_passes_on_what_the_recovery_warned_about() {
    live_site
    sandbox_config >/dev/null
    unrecorded_swap_with_warning
    out=$(bash "${SKILL_DIR}/scripts/theme/workspace.sh" open --project "$PROJECT" 2>/dev/null); code=$?
    assert_status 0 "$code"
    assert_contains "$out" "RECOVERED=finished-publish"
    assert_contains "$out" "WARN=STILL_FAILING schema:validate"
}
