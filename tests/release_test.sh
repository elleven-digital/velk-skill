# tests/release_test.sh — fetching a published release, and update-cms on top of it.

load_release_lib() {
    CONFIG_PATH=/dev/null
    . "${SKILL_DIR}/scripts/ssh-lib.sh"
    . "${SKILL_DIR}/scripts/release-lib.sh"
    set +e   # ssh-lib turns on errexit; the tests check statuses themselves
}

test_fetch_release_extracts_a_verified_tarball() {
    base=$(sandbox_release v9.9.9)
    load_release_lib
    work=$(mktemp -d)
    src=$(fetch_release v9.9.9 "$base" "$work")
    assert_status 0 $?
    assert_file "${src}/engine-manifest.json"
    assert_eq "v9.9.9" "$(cat "${src}/core/VERSION")"
}

test_fetch_release_refuses_a_tampered_tarball_before_extracting() {
    base=$(sandbox_release v9.9.9 0000000000000000000000000000000000000000000000000000000000000000)
    load_release_lib
    work=$(mktemp -d)
    out=$(fetch_release v9.9.9 "$base" "$work" 2>&1); code=$?
    assert_status 1 "$code"
    assert_contains "$out" "Integrity check failed"
    assert_eq "" "$(find "$work" -maxdepth 1 -name 'velk-*')" "nothing may be extracted"
}

test_fetch_release_refuses_an_unpublished_version() {
    base=$(sandbox_release v9.9.9)
    load_release_lib
    out=$(fetch_release v1.0.0 "$base" "$(mktemp -d)" 2>&1); code=$?
    assert_status 1 "$code"
    assert_contains "$out" "not published"
}

test_version_for_prefers_velk_version_over_core_version() {
    load_release_lib
    mkdir -p "${PROJECT}/core"
    echo "v1.0.0" > "${PROJECT}/core/VERSION"
    assert_eq "v1.0.0" "$(version_for "$PROJECT")"
    echo '{"version":"v2.0.0"}' > "${PROJECT}/.velk-version"
    assert_eq "v2.0.0" "$(version_for "$PROJECT")"
}

test_release_base_for_falls_back_to_the_official_server() {
    load_release_lib
    assert_eq "https://releases.velkcms.com" "$(release_base_for "$PROJECT")"
    echo '{"version":"v2.0.0","release_base_url":"file:///mirror"}' > "${PROJECT}/.velk-version"
    assert_eq "file:///mirror" "$(release_base_for "$PROJECT")"
}

test_update_cms_ships_the_release_engine_and_migrates() {
    sandbox_velk_server
    base=$(sandbox_release v9.9.9)
    sandbox_engine_project v9.9.9 "$base"
    cfg=$(sandbox_config)
    out=$(cd "$PROJECT" && bash "${SKILL_DIR}/scripts/deploy/update-cms.sh" --project "$PROJECT" 2>&1); code=$?
    assert_status 0 "$code" "update-cms failed: $out"
    assert_eq "<?php // app" "$(cat "${SERVER}/core/App.php")"
    assert_contains "$(cat "${SERVER}/.stub-calls")" "migrate"
    assert_eq "v9.9.9" "$(jq -r .version "${SERVER}/.velk-version")"
    assert_no_dir "${SERVER}/migrations" "post_install_cleanup must run after migrate"
}

test_update_cms_puts_an_engine_file_inside_a_folder_where_it_belongs() {
    # docs/messages.md is an engine FILE, not a folder: shipped among the root
    # files, it used to land as <remote>/messages.md — next to index.php —
    # while docs/messages.md stayed on the old version.
    sandbox_velk_server
    base=$(sandbox_release v9.9.9)
    sandbox_engine_project v9.9.9 "$base"
    sandbox_config >/dev/null
    out=$(bash "${SKILL_DIR}/scripts/deploy/update-cms.sh" --project "$PROJECT" 2>&1); code=$?
    assert_status 0 "$code" "$out"
    assert_eq "# messages v9.9.9" "$(cat "${SERVER}/docs/messages.md" 2>/dev/null)"
    assert_no_file "${SERVER}/messages.md" "a file inside a folder must not land in the install root"
    assert_eq '<?php require __DIR__ . "/core/Bootstrap.php";' "$(cat "${SERVER}/index.php")"
}

test_update_cms_leaves_the_servers_own_gitignore_alone() {
    # The engine ships its repo's .gitignore and cleans it up after install:
    # shipping it over the server's and then cleaning up would delete the
    # project's own. Like content.sh and check-engine, it is never the engine's.
    sandbox_velk_server
    base=$(sandbox_release v9.9.9)
    sandbox_engine_project v9.9.9 "$base"
    sandbox_config >/dev/null
    printf '.deploy/\n' > "${SERVER}/.gitignore"
    out=$(bash "${SKILL_DIR}/scripts/deploy/update-cms.sh" --project "$PROJECT" 2>&1); code=$?
    assert_status 0 "$code" "$out"
    assert_eq ".deploy/" "$(cat "${SERVER}/.gitignore" 2>/dev/null)" "the project's .gitignore is not the engine's"
}

test_update_cms_refuses_a_tampered_release_and_leaves_the_server_alone() {
    sandbox_velk_server
    base=$(sandbox_release v9.9.9 0000000000000000000000000000000000000000000000000000000000000000)
    sandbox_engine_project v9.9.9 "$base"
    cfg=$(sandbox_config)
    out=$(cd "$PROJECT" && bash "${SKILL_DIR}/scripts/deploy/update-cms.sh" --project "$PROJECT" 2>&1); code=$?
    assert_status 1 "$code"
    assert_contains "$out" "Integrity check failed"
    assert_no_file "${SERVER}/core/App.php" "nothing may reach the server"
}

test_update_cms_ships_the_version_asked_for() {
    sandbox_velk_server
    base=$(sandbox_release v9.9.9)
    sandbox_engine_project v9.9.9 "$base"
    sandbox_config >/dev/null
    out=$(bash "${SKILL_DIR}/scripts/deploy/update-cms.sh" --project "$PROJECT" --version v8.8.8 2>&1); code=$?
    assert_status 1 "$code"
    assert_contains "$out" "not published"      # --version reached fetch_release: v8.8.8 isn't in versions.json
    assert_no_file "${SERVER}/core/App.php" "nothing may reach the server"
}

test_update_cms_refuses_a_server_without_velk() {
    base=$(sandbox_release v9.9.9)
    sandbox_engine_project v9.9.9 "$base"
    sandbox_config >/dev/null
    out=$(bash "${SKILL_DIR}/scripts/deploy/update-cms.sh" --project "$PROJECT" 2>&1); code=$?
    assert_status 1 "$code"
    assert_contains "$out" "init.sh"
    assert_no_file "${SERVER}/core/App.php"
}

test_update_cms_reads_a_remote_path_with_a_quote_in_it() {
    sandbox_velk_server
    base=$(sandbox_release v9.9.9)
    sandbox_engine_project v9.9.9 "$base"
    cfg=$(sandbox_config)
    odd="${SANDBOX}/server/it's public_html"
    mv "$SERVER" "$odd"
    jq --arg p "$odd" '.ssh.remote_path = $p' "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
    # --version v8.8.8 isn't published: the script stops right after the
    # checks that read the server — as far as rsync would let it go anyway.
    out=$(bash "${SKILL_DIR}/scripts/deploy/update-cms.sh" --project "$PROJECT" --version v8.8.8 2>&1); code=$?
    assert_status 1 "$code"
    assert_contains "$out" "not published" "the guard saw Velk through the quote and went on to the release"
    assert_not_contains "$out" "init.sh"
}

test_update_cms_goes_on_when_ssh_only_warns_on_stderr() {
    sandbox_velk_server
    base=$(sandbox_release v9.9.9)
    sandbox_engine_project v9.9.9 "$base"
    sandbox_config >/dev/null
    out=$(FAKE_SSH_HOOK_ON="core/Bootstrap.php" FAKE_SSH_HOOK='echo "Warning: Permanently added site.test to the list of known hosts." >&2' \
        bash "${SKILL_DIR}/scripts/deploy/update-cms.sh" --project "$PROJECT" 2>&1); code=$?
    assert_status 0 "$code" "$out"
    assert_eq "<?php // app" "$(cat "${SERVER}/core/App.php")"
}

test_update_cms_refuses_a_target_it_cannot_read() {
    sandbox_velk_server
    base=$(sandbox_release v9.9.9)
    sandbox_engine_project v9.9.9 "$base"
    sandbox_config >/dev/null
    out=$(FAKE_SSH_HOOK_ON="core/Bootstrap.php" FAKE_SSH_HOOK='echo "Welcome to site.test"' \
        bash "${SKILL_DIR}/scripts/deploy/update-cms.sh" --project "$PROJECT" 2>&1); code=$?
    assert_status 1 "$code"
    assert_contains "$out" "nothing was sent"
    assert_not_contains "$out" "init.sh" "a banner on stdout is not \"no Velk\""
    assert_no_file "${SERVER}/core/App.php"
}
