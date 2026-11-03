# tests/ssh_lib_test.sh — the shared transport library on its own: the
# arguments every action script takes, and the local database's option file.

load_lib() {
    . "${SKILL_DIR}/scripts/ssh-lib.sh"
    set +e   # ssh-lib turns on errexit; the tests check statuses themselves
}
local_config() {   # local_config <db_password> — a config with a local database section, loaded
    CONFIG_PATH=$(sandbox_config)
    jq --arg p "$1" '.local = {"db_host": "127.0.0.1", "db_name": "l", "db_user": "dev", "db_password": $p}' \
        "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
}

test_project_args_finds_the_config_inside_the_project() {
    load_lib
    sandbox_config >/dev/null
    project_args --project "${PROJECT}/" --tables items
    assert_eq "$PROJECT" "$PROJECT_DIR"
    assert_eq "${PROJECT}/.deploy/ssh.json" "$CONFIG_PATH"
    assert_eq "--tables items" "${REST[*]}"
}

test_project_args_takes_another_config_when_told() {
    load_lib
    sandbox_config >/dev/null
    cp "${PROJECT}/.deploy/ssh.json" "${SANDBOX}/other.json"
    project_args --project "$PROJECT" --config "${SANDBOX}/other.json"
    assert_eq "${SANDBOX}/other.json" "$CONFIG_PATH"
}

test_project_args_makes_both_paths_absolute_so_a_script_may_cd() {
    load_lib
    sandbox_config >/dev/null
    cp "${PROJECT}/.deploy/ssh.json" "${SANDBOX}/other.json"
    out=$(cd "$SANDBOX" && project_args --project project --config other.json && printf '%s\n%s' "$PROJECT_DIR" "$CONFIG_PATH")
    assert_eq "${PROJECT}"$'\n'"${SANDBOX}/other.json" "$out"
    out=$(cd "$SANDBOX" && project_args --project project && printf '%s' "$CONFIG_PATH")
    assert_eq "${PROJECT}/.deploy/ssh.json" "$out"
}

test_project_args_needs_a_project() {
    load_lib
    sandbox_config >/dev/null
    out=$(project_args --config "${PROJECT}/.deploy/ssh.json" 2>&1); code=$?
    assert_status 2 "$code"
    assert_contains "$out" "--project <dir> is required"
}

test_the_local_option_file_writes_passwords_the_way_mysql_reads_them() {
    load_lib
    lines=""
    for p in 'plain #1 ' 'dq"only #2' "it's \$HOME; & \"x\"" 'back\slash'; do
        local_config "$p"
        f=$(local_db_defaults) || fail "could not write the option file for [$p]"
        lines="${lines}$(grep '^password=' "$f")"$'\n'
        assert_eq "600" "$(stat -f %Lp "$f")" "only its owner may read it"
        rm -f "$f"
    done
    # How MySQL reads them back (checked against my_print_defaults): quotes the
    # value lacks, or none; backslashes doubled — as scripts/remote/db.sh writes.
    expected=$(printf '%s\n' 'password="plain #1 "' "password='dq\"only #2'" "password=it's \$HOME; & \"x\"" 'password="back\\slash"')
    assert_eq "$expected" "${lines%$'\n'}"
}

test_a_local_password_no_option_file_can_hold_is_refused() {
    load_lib
    local_config "it's \"x\" #3"
    out=$(local_db_defaults 2>&1); code=$?
    assert_status 1 "$code"
    assert_contains "$out" "same quote mark at both ends"
}

test_the_local_option_file_carries_host_port_and_user() {
    load_lib
    local_config ""
    f=$(local_db_defaults)
    assert_eq $'[client]\nhost=127.0.0.1\nport=3306\nuser=dev\npassword=""' "$(cat "$f")"
    rm -f "$f"
}

test_the_site_url_carries_the_subpath() {
    load_lib
    CONFIG_PATH=$(sandbox_config)
    assert_eq "https://site.test" "$(site_base_url)"
    for sub in "/blog" "/blog/" "blog"; do
        jq --arg s "$sub" '.site.subpath = $s' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
        assert_eq "https://site.test/blog" "$(site_base_url)" "subpath \"$sub\""
    done
}

test_theme_leftovers_names_source_pages_and_spares_functions_php() {
    load_lib
    t="${SANDBOX}/um tema"; mkdir -p "${t}/templates" "${t}/includes"
    touch "${t}/functions.php" "${t}/templates/page-home.php" "${t}/index.php" "${t}/header.php"
    assert_eq $'theme/header.php\ntheme/index.php\ntheme/includes/' "$(theme_leftovers "$t")"
    rm -rf "${t}/includes" "${t}/index.php" "${t}/header.php"
    assert_eq "" "$(theme_leftovers "$t")"
}
