# tests/preflight_test.sh — the one check before touching a server: SSH,
# what the target holds, its database with the server's own credentials, and
# the local database when asked. It only looks.

world() { CFG=$(sandbox_config); }
preflight() { out=$(bash "${SKILL_DIR}/scripts/preflight.sh" --project "$PROJECT" "$@" 2>"${SANDBOX}/err"); code=$?; }
server_env() { printf 'DB_HOST=localhost\nDB_DATABASE=site\nDB_USERNAME=u1\nDB_PASSWORD="%s"\n' "$1" > "${SERVER}/.env"; }
remote_mysql() {   # remote_mysql <script body> — the server's mysql client
    printf '#!/bin/bash\n%s\n' "$1" > "${FAKE_REMOTE_PATH}/mysql"
    chmod +x "${FAKE_REMOTE_PATH}/mysql"
}

test_a_server_with_velk_and_a_database_that_answers_is_ok() {
    sandbox_velk_server
    world
    server_env "pf-S3cret"
    remote_mysql "{ echo \"ARGS \$*\"; cat \"\${1#--defaults-extra-file=}\"; } >> '${SANDBOX}/check.log'"
    preflight
    assert_status 0 "$code" "$(cat "${SANDBOX}/err")"
    assert_eq $'STATUS=OK\nSSH=ok\nTARGET=EXISTS\nDB=ok' "$out"
    assert_contains "$(cat "${SANDBOX}/check.log")" 'password="pf-S3cret"' "the server's own credentials, in the option file"
    assert_not_contains "$(cat "$FAKE_CALLS")" "pf-S3cret" "and never on a command line"
}

test_an_empty_target_skips_the_database() {
    world                                   # the folder exists, nothing in it
    preflight
    assert_status 0 "$code" "$(cat "${SANDBOX}/err")"
    assert_eq $'STATUS=OK\nSSH=ok\nTARGET=EMPTY\nDB=skipped' "$out"
}

test_a_missing_folder_is_reported_not_created() {
    world
    rmdir "$SERVER"
    preflight
    assert_status 0 "$code" "$(cat "${SANDBOX}/err")"
    assert_eq $'STATUS=OK\nSSH=ok\nTARGET=MISSING\nDB=skipped' "$out"
    assert_no_dir "$SERVER" "preflight only looks"
}

test_a_database_that_does_not_answer_fails_the_check() {
    sandbox_velk_server
    world
    server_env "x"
    remote_mysql 'echo "ERROR 1045 (28000): Access denied for user" >&2; exit 1'
    preflight
    assert_status 1 "$code"
    assert_eq $'STATUS=FAILED\nSSH=ok\nTARGET=EXISTS\nFAILED=db\nREASON=ERROR 1045 (28000): Access denied for user' "$out"
}

test_a_server_that_cannot_be_reached_fails_first() {
    sandbox_velk_server
    world
    export FAKE_SSH_UNREACHABLE=1
    preflight
    assert_status 1 "$code"
    assert_eq $'STATUS=FAILED\nFAILED=ssh' "$(head -2 <<< "$out")"
    assert_contains "$out" "REASON=ssh: connect to host site.test port 65002: Connection refused"
    assert_not_contains "$out" "TARGET="
}

test_the_local_database_is_checked_through_an_option_file() {
    sandbox_velk_server
    world
    server_env "x"
    remote_mysql 'exit 0'
    mkdir -p "${SANDBOX}/bin"
    printf '#!/bin/bash\n{ echo "ARGS $*"; cat "${1#--defaults-extra-file=}"; } >> "%s/local.log"\n' "$SANDBOX" > "${SANDBOX}/bin/mysql"
    printf '#!/bin/bash\n' > "${SANDBOX}/bin/mysqldump"
    chmod +x "${SANDBOX}/bin/"*
    jq --arg m "${SANDBOX}/bin/mysql" \
        '.local = {"db_name": "l", "db_user": "dev", "db_password": "loc-S3cret", "mysql_bin": $m}' \
        "$CFG" > "${CFG}.tmp" && mv "${CFG}.tmp" "$CFG"
    option_files() { ls "${TMPDIR:-/tmp}" | grep -c '^velk-local-db\.' || true; }
    before=$(option_files)
    preflight --local-db
    assert_status 0 "$code" "$(cat "${SANDBOX}/err")"
    assert_eq $'STATUS=OK\nSSH=ok\nTARGET=EXISTS\nDB=ok\nLOCAL_DB=ok\nMYSQLDUMP=ok' "$out"
    log=$(cat "${SANDBOX}/local.log")
    assert_contains "$log" 'password="loc-S3cret"'
    assert_not_contains "$(grep '^ARGS' <<< "$log")" "loc-S3cret" "never on a command line"
    assert_contains "$(grep '^ARGS' <<< "$log")" "SELECT 1"
    assert_eq "$before" "$(option_files)" "the option file is gone"
}

test_a_local_mysql_that_is_missing_fails_the_check() {
    sandbox_velk_server
    world
    server_env "x"
    remote_mysql 'exit 0'
    jq '.local = {"db_name": "l"}' "$CFG" > "${CFG}.tmp" && mv "${CFG}.tmp" "$CFG"
    preflight --local-db                    # a stock macOS has no mysql on PATH
    assert_status 1 "$code"
    assert_contains "$out" "FAILED=local_db"
    assert_contains "$out" "REASON=no mysql on this Mac"
}
