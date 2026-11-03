# tests/engine_test.sh — the local engine must be exactly the published release.

check_engine() {
    bash "${SKILL_DIR}/scripts/check-engine.sh" --project "$PROJECT" 2>/dev/null
}

test_a_pristine_engine_passes() {
    base=$(sandbox_release v9.9.9)
    sandbox_engine_project v9.9.9 "$base"
    out=$(check_engine); code=$?
    assert_status 0 "$code"
    assert_eq "ENGINE_OK" "$out"
}

test_an_edited_engine_file_is_reported() {
    base=$(sandbox_release v9.9.9)
    sandbox_engine_project v9.9.9 "$base"
    echo '<?php // patched' > "${PROJECT}/core/App.php"
    out=$(check_engine); code=$?
    assert_status 1 "$code"
    assert_eq "CHANGED core/App.php" "$out"
}

test_a_file_added_inside_the_engine_is_reported() {
    base=$(sandbox_release v9.9.9)
    sandbox_engine_project v9.9.9 "$base"
    echo '<?php' > "${PROJECT}/core/Extra.php"
    out=$(check_engine); code=$?
    assert_status 1 "$code"
    assert_eq "ADDED core/Extra.php" "$out"
}

test_a_missing_engine_file_is_reported() {
    base=$(sandbox_release v9.9.9)
    sandbox_engine_project v9.9.9 "$base"
    rm "${PROJECT}/index.php"
    out=$(check_engine); code=$?
    assert_status 1 "$code"
    assert_eq "MISSING index.php" "$out"
}

test_paths_an_install_cleans_up_may_be_absent_but_not_edited() {
    base=$(sandbox_release v9.9.9)
    sandbox_engine_project v9.9.9 "$base"
    # migrations/ is in post_install_cleanup: absent is normal...
    out=$(check_engine); assert_eq "ENGINE_OK" "$out"
    # ...but when it is there, it must match the release.
    mkdir -p "${PROJECT}/migrations"
    echo '<?php // edited' > "${PROJECT}/migrations/001_init.php"
    out=$(check_engine); code=$?
    assert_status 1 "$code"
    assert_eq "CHANGED migrations/001_init.php" "$out"
}

test_the_projects_own_gitignore_is_not_the_engine() {
    base=$(sandbox_release v9.9.9)
    sandbox_engine_project v9.9.9 "$base"
    echo '.deploy/' >> "${PROJECT}/.gitignore"      # what deploy.md and connect.sh do
    out=$(check_engine); code=$?
    assert_status 0 "$code"
    assert_eq "ENGINE_OK" "$out"
}

test_finder_metadata_is_ignored() {
    base=$(sandbox_release v9.9.9)
    sandbox_engine_project v9.9.9 "$base"
    touch "${PROJECT}/core/.DS_Store"
    out=$(check_engine)
    assert_eq "ENGINE_OK" "$out"
}

test_theme_and_storage_are_not_the_engine() {
    base=$(sandbox_release v9.9.9)
    sandbox_engine_project v9.9.9 "$base"
    sandbox_theme "${PROJECT}/theme"
    mkdir -p "${PROJECT}/storage/uploads"; echo x > "${PROJECT}/storage/uploads/a.jpg"
    out=$(check_engine)
    assert_eq "ENGINE_OK" "$out"
}

test_an_unreachable_release_is_an_error_not_a_pass() {
    base=$(sandbox_release v9.9.9)
    sandbox_engine_project v9.9.9 "file://${SANDBOX}/nowhere"
    out=$(check_engine); code=$?
    assert_status 2 "$code"
    assert_not_contains "$out" "ENGINE_OK"
}

test_init_refuses_to_deploy_an_edited_engine() {
    sandbox_velk_server
    rm -rf "${SERVER:?}"/*          # init wants an empty target
    base=$(sandbox_release v9.9.9)
    sandbox_engine_project v9.9.9 "$base"
    echo '<?php // patched' > "${PROJECT}/core/App.php"
    cfg=$(sandbox_config)
    jq '.db = {"name": "d", "user": "u", "password": "p"}' "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
    out=$(cd "$PROJECT" && bash "${SKILL_DIR}/scripts/deploy/init.sh" --project "$PROJECT" 2>&1); code=$?
    assert_status 1 "$code"
    assert_contains "$out" "CHANGED core/App.php"
    assert_not_contains "$out" "Dumping local DB" "init must stop at the engine check"
    assert_eq "" "$(ls -A "$SERVER")" "nothing may reach the server"
}

test_init_gets_past_the_engine_check_when_the_engine_is_pristine() {
    sandbox_velk_server
    rm -rf "${SERVER:?}"/*
    base=$(sandbox_release v9.9.9)
    sandbox_engine_project v9.9.9 "$base"
    cfg=$(sandbox_config)
    # No local.db_name: init stops at its NEXT step (the local dump), which
    # proves it went past the engine check.
    jq '.db = {"name": "d", "user": "u", "password": "p"}' "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
    out=$(cd "$PROJECT" && bash "${SKILL_DIR}/scripts/deploy/init.sh" --project "$PROJECT" 2>&1)
    assert_contains "$out" "ENGINE_OK"
    assert_contains "$out" "local.db_name must be set"
}
