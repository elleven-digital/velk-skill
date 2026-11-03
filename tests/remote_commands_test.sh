# tests/remote_commands_test.sh — commands meant for the server run on the
# server, with the configured PHP, and with arguments intact.

server() {
    sandbox_velk_server
    CFG=$(sandbox_config)
}

test_content_writes_run_on_the_server() {
    server
    mkdir -p "${PROJECT}/bin"                                   # a local Velk project...
    printf '#!/bin/bash\necho LOCAL >> "%s/local-calls"\n' "$SANDBOX" > "${PROJECT}/bin/velk"
    chmod +x "${PROJECT}/bin/velk"
    (cd "$PROJECT" && echo '{"title":"x"}' | bash "${SKILL_DIR}/scripts/content/velk.sh" --project "$PROJECT" -- item:create post --json-stdin >/dev/null 2>&1)
    assert_status 0 $?
    assert_contains "$(cat "${SERVER}/.stub-calls" 2>/dev/null)" "item:create post --json-stdin --format=json"
    assert_no_file "${SANDBOX}/local-calls" "...whose bin/velk must never be the one that runs"
}

test_a_read_asks_the_server() {
    server
    (cd "$PROJECT" && bash "${SKILL_DIR}/scripts/content/velk.sh" --project "$PROJECT" -- item:types >/dev/null 2>&1)
    assert_contains "$(cat "${SERVER}/.stub-calls" 2>/dev/null)" "item:types --format=json"
}

test_the_configured_remote_php_is_the_one_that_runs() {
    server
    printf '#!/bin/bash\necho "$*" >> "%s/php-wrapper-calls"\nexec "%s" "$@"\n' "$SANDBOX" "$DEV_PHP" > "${SANDBOX}/ea-php82"
    chmod +x "${SANDBOX}/ea-php82"
    jq --arg p "${SANDBOX}/ea-php82" '.remote.php_bin = $p' "$CFG" > "${CFG}.tmp" && mv "${CFG}.tmp" "$CFG"
    echo '{"title":"x"}' | bash "${SKILL_DIR}/scripts/content/velk.sh" --project "$PROJECT" -- item:create post --json-stdin >/dev/null 2>&1
    assert_contains "$(cat "${SANDBOX}/php-wrapper-calls" 2>/dev/null)" "bin/velk item:create"
}

test_the_content_backup_uses_the_servers_own_database_credentials() {
    server
    sandbox_require_php
    pass="it's \$HOME; & \"x\""
    printf 'DB_HOST=localhost\nDB_DATABASE=site\nDB_USERNAME=u1\nDB_PASSWORD="%s"\n' "$pass" > "${SERVER}/.env"
    cat > "${FAKE_REMOTE_PATH}/mysqldump" <<'FAKE'
#!/bin/bash
{ echo "ARGS $*"; cat "${1#--defaults-extra-file=}"; } >> "${SANDBOX}/dump.log"
echo "CREATE TABLE items (id int);"
FAKE
    chmod +x "${FAKE_REMOTE_PATH}/mysqldump"
    # The config has no database section at all — like one written from an access file.
    out=$(cd "$PROJECT" && bash "${SKILL_DIR}/scripts/content/backup.sh" --project "$PROJECT" --tables items 2>/dev/null); code=$?
    assert_status 0 "$code"
    assert_contains "$(cat "${SANDBOX}/dump.log")" "password=${pass}" "the password travels in the option file, intact"
    args=$(grep '^ARGS' "${SANDBOX}/dump.log")
    assert_not_contains "$args" "$pass" "and never on a command line"
    assert_contains "$args" "site items"
    assert_not_contains "$args" "--no-create-info" "a backup keeps the schema"
    path=$(jq -r .backup_path <<< "$out")
    assert_eq "CREATE TABLE items (id int);" "$(cat "$path")"
    rm -f "$path"
}

test_the_option_file_holds_passwords_with_quotes() {
    server
    sandbox_require_php
    printf '#!/bin/bash\ngrep "^password=" "${1#--defaults-extra-file=}" >> "%s/password-lines"\necho "-- dump"\n' "$SANDBOX" \
        > "${FAKE_REMOTE_PATH}/mysqldump"
    chmod +x "${FAKE_REMOTE_PATH}/mysqldump"
    backup_with() {   # backup_with <the .env's DB_PASSWORD value, as written there>
        printf 'DB_DATABASE=site\nDB_USERNAME=u1\nDB_PASSWORD=%s\n' "$1" > "${SERVER}/.env"
        (cd "$PROJECT" && bash "${SKILL_DIR}/scripts/content/backup.sh" --project "$PROJECT" --tables items >/dev/null 2>&1)
    }
    backup_with '"plain #1 "' || fail "plain"
    backup_with 'dq"only #2' || fail "double quote"
    backup_with "it's \$HOME; & \"x\"" || fail "both quotes"
    backup_with 'back\slash' || fail "backslash"
    if backup_with "it's \"x\" #3"; then fail "a password no option file can hold must stop the backup"; fi
    # How MySQL reads them back (checked against my_print_defaults): quotes the
    # value lacks, or none; backslashes doubled.
    expected=$(printf '%s\n' 'password="plain #1 "' "password='dq\"only #2'" "password=it's \$HOME; & \"x\"" 'password="back\\slash"')
    assert_eq "$expected" "$(cat "${SANDBOX}/password-lines")"
}

test_an_empty_table_list_backs_up_nothing() {
    server
    printf '#!/bin/bash\necho called >> "%s/dump-called"\n' "$SANDBOX" > "${FAKE_REMOTE_PATH}/mysqldump"
    chmod +x "${FAKE_REMOTE_PATH}/mysqldump"
    out=$(cd "$PROJECT" && bash "${SKILL_DIR}/scripts/content/backup.sh" --project "$PROJECT" --tables "" 2>/dev/null); code=$?
    assert_status 2 "$code"
    assert_eq "false" "$(jq -r .ok <<< "$out")"
    assert_no_file "${SANDBOX}/dump-called" "no dump of the whole database"
}

test_a_content_backup_goes_back_with_the_servers_own_credentials() {
    server
    sandbox_require_php
    printf 'DB_HOST=localhost\nDB_DATABASE=site\nDB_USERNAME=u1\nDB_PASSWORD="s3cret"\n' > "${SERVER}/.env"
    printf '#!/bin/bash\n{ echo "ARGS $*"; cat "${1#--defaults-extra-file=}"; echo "SQL:"; cat; } >> "%s/import.log"\n' "$SANDBOX" \
        > "${FAKE_REMOTE_PATH}/mysql"
    chmod +x "${FAKE_REMOTE_PATH}/mysql"
    echo "INSERT INTO items VALUES (1);" > "${SANDBOX}/backup.sql"
    restore() { (cd "$PROJECT" && bash "${SKILL_DIR}/scripts/content/restore.sh" --project "$PROJECT" --file "${SANDBOX}/backup.sql" "$@" 2>/dev/null); }
    out=$(restore); code=$?
    assert_status 2 "$code" "putting live tables back needs --confirm"
    assert_no_file "${SANDBOX}/import.log"
    out=$(FAKE_SSH_HOOK_ON="'import'" \
          FAKE_SSH_HOOK='stat -f %Lp "$(grep -o "/tmp/velk-content-restore[.][A-Za-z0-9]*" <<< "$FAKE_SSH_CMD")" > "${SANDBOX}/sent-mode"' \
          restore --confirm); code=$?
    assert_status 0 "$code"
    assert_eq "600" "$(cat "${SANDBOX}/sent-mode")" "on the server's /tmp only its owner can read it"
    assert_eq "true" "$(jq -r .ok <<< "$out")"
    log=$(cat "${SANDBOX}/import.log")
    assert_contains "$log" 'password="s3cret"'
    assert_contains "$log" "INSERT INTO items VALUES (1);"
    assert_contains "$(grep '^ARGS' "${SANDBOX}/import.log")" " site"
    assert_not_contains "$(grep '^ARGS' "${SANDBOX}/import.log")" "s3cret"
    sent=$(grep -o '/tmp/velk-content-restore[.][A-Za-z0-9]*' "$FAKE_CALLS" | grep -v XXXXXX | head -1)
    [ -n "$sent" ] || fail "the backup must travel to the server's /tmp"
    assert_no_file "$sent" "and be gone once imported"
}

test_a_noisy_php_on_the_server_leaves_the_backup_intact() {
    server
    sandbox_require_php
    noisy_server_php
    printf 'DB_DATABASE=site\nDB_USERNAME=u1\nDB_PASSWORD=pw123\n' > "${SERVER}/.env"
    printf '#!/bin/bash\necho "ARGS $*" >> "%s/dump.log"\necho "-- dump"\n' "$SANDBOX" > "${FAKE_REMOTE_PATH}/mysqldump"
    chmod +x "${FAKE_REMOTE_PATH}/mysqldump"
    (cd "$PROJECT" && bash "${SKILL_DIR}/scripts/content/backup.sh" --project "$PROJECT" --tables items >/dev/null 2>&1)
    assert_status 0 $?
    assert_contains "$(cat "${SANDBOX}/dump.log")" " site items"
    assert_not_contains "$(cat "${SANDBOX}/dump.log")" "PHP Warning"
}

test_a_password_with_the_same_quote_at_both_ends_is_explained() {
    server
    sandbox_require_php
    printf 'DB_DATABASE=site\nDB_USERNAME=u1\nDB_PASSWORD="%s"\n' "'a\"b'" > "${SERVER}/.env"
    err=$(cd "$PROJECT" && bash "${SKILL_DIR}/scripts/content/backup.sh" --project "$PROJECT" --tables items 2>&1 >/dev/null); code=$?
    [ "$code" -ne 0 ] || fail "such a password cannot be written"
    assert_contains "$err" "same quote mark at both ends"
}

test_a_key_path_with_a_space_reaches_ssh_whole() {
    server
    sandbox_require_auth
    mkdir -p "${HOME}/.ssh/my keys"
    ssh-keygen -q -t ed25519 -N "" -f "${HOME}/.ssh/my keys/site" >/dev/null
    sandbox_authorize "${HOME}/.ssh/my keys/site.pub"
    jq --arg k "${HOME}/.ssh/my keys/site" '.ssh.key_path = $k' "$CFG" > "${CFG}.tmp" && mv "${CFG}.tmp" "$CFG"
    (cd "$PROJECT" && bash "${SKILL_DIR}/scripts/content/velk.sh" --project "$PROJECT" -- item:types >/dev/null 2>&1)
    assert_contains "$(cat "${SERVER}/.stub-calls" 2>/dev/null)" "item:types" "the key opened the server"
}

test_the_server_env_is_read_the_way_velk_reads_it() {
    server
    sandbox_require_php
    printf '%s\n' 'export DB_DATABASE=site' 'export DB_USERNAME=u1' 'export DB_PASSWORD="dq\"x \\ y"' > "${SERVER}/.env"
    printf '#!/bin/bash\n{ echo "ARGS $*"; cat "${1#--defaults-extra-file=}"; } >> "%s/dump.log"\necho "-- dump"\n' "$SANDBOX" \
        > "${FAKE_REMOTE_PATH}/mysqldump"
    chmod +x "${FAKE_REMOTE_PATH}/mysqldump"
    (cd "$PROJECT" && bash "${SKILL_DIR}/scripts/content/backup.sh" --project "$PROJECT" --tables items >/dev/null 2>&1)
    assert_status 0 $?
    assert_contains "$(cat "${SANDBOX}/dump.log")" " site items"
    assert_contains "$(cat "${SANDBOX}/dump.log")" "$(printf '%s' "password='dq\"x \\\\ y'")"
}

test_a_key_the_env_repeats_keeps_its_first_value_as_in_velk() {
    server
    sandbox_require_php
    printf '%s\n' DB_DATABASE=site DB_PASSWORD=first DB_DATABASE=other DB_PASSWORD=second > "${SERVER}/.env"
    printf '#!/bin/bash\n{ echo "ARGS $*"; cat "${1#--defaults-extra-file=}"; } >> "%s/dump.log"\necho "-- dump"\n' "$SANDBOX" \
        > "${FAKE_REMOTE_PATH}/mysqldump"
    chmod +x "${FAKE_REMOTE_PATH}/mysqldump"
    (cd "$PROJECT" && bash "${SKILL_DIR}/scripts/content/backup.sh" --project "$PROJECT" --tables items >/dev/null 2>&1)
    assert_status 0 $?
    assert_contains "$(cat "${SANDBOX}/dump.log")" " site items"
    assert_contains "$(cat "${SANDBOX}/dump.log")" 'password="first"'
    assert_not_contains "$(cat "${SANDBOX}/dump.log")" "second"
}

test_the_backup_on_this_mac_is_only_its_owners() {
    server
    sandbox_require_php
    printf 'DB_DATABASE=site\nDB_USERNAME=u1\nDB_PASSWORD=x\n' > "${SERVER}/.env"
    printf '#!/bin/bash\necho "-- dump"\n' > "${FAKE_REMOTE_PATH}/mysqldump"; chmod +x "${FAKE_REMOTE_PATH}/mysqldump"
    out=$(cd "$PROJECT" && bash "${SKILL_DIR}/scripts/content/backup.sh" --project "$PROJECT" --tables items 2>/dev/null)
    path=$(jq -r .backup_path <<< "$out")
    assert_contains "$path" "velk-content-backup-"
    assert_eq "600" "$(stat -f %Lp "$path")" "it holds the client's content"
    assert_contains "$(jq -r .rollback_hint <<< "$out")" "restore.sh --project ${PROJECT} --file ${path} --confirm"
    rm -f "$path"
}

test_an_empty_dump_is_not_a_backup() {
    # A dump that brings nothing back would be reported as a backup of the
    # client's content and trusted for a rollback later: it is a failure, and
    # no empty file stays behind under a backup's name.
    server
    sandbox_require_php
    printf 'DB_DATABASE=site\nDB_USERNAME=u1\nDB_PASSWORD=x\n' > "${SERVER}/.env"
    printf '#!/bin/bash\nexit 0\n' > "${FAKE_REMOTE_PATH}/mysqldump"; chmod +x "${FAKE_REMOTE_PATH}/mysqldump"
    out=$(cd "$PROJECT" && bash "${SKILL_DIR}/scripts/content/backup.sh" --project "$PROJECT" --tables items 2>/dev/null); code=$?
    assert_status 1 "$code"
    assert_eq "false" "$(jq -r .ok <<< "$out")"
    assert_contains "$(jq -r .error <<< "$out")" "empty"
    assert_eq "" "$(find "$TMPDIR" -name 'velk-content-backup-*')" "no empty backup file may be left"
}

test_a_backup_cut_short_leaves_no_file() {
    # Stopped mid-dump (a closed terminal, a killed process), what reached the
    # file is part of the client's content under a backup's name: it goes too.
    server
    sandbox_require_php
    printf 'DB_DATABASE=site\nDB_USERNAME=u1\nDB_PASSWORD=x\n' > "${SERVER}/.env"
    printf '#!/bin/bash\necho "-- partial"\nsleep 2\necho "-- rest"\n' > "${FAKE_REMOTE_PATH}/mysqldump"
    chmod +x "${FAKE_REMOTE_PATH}/mysqldump"
    (cd "$PROJECT" && exec bash "${SKILL_DIR}/scripts/content/backup.sh" --project "$PROJECT" --tables items >/dev/null 2>&1) &
    pid=$!
    for _ in $(seq 1 50); do
        [ -n "$(find "$TMPDIR" -name 'velk-content-backup-*' -size +0)" ] && break
        sleep 0.1
    done
    [ -n "$(find "$TMPDIR" -name 'velk-content-backup-*' -size +0)" ] || fail "the dump never started"
    # SIGTERM, not SIGINT: a background job of a non-interactive shell ignores SIGINT.
    kill -TERM "$pid"
    wait "$pid" 2>/dev/null
    sleep 2.5      # let the rest of the dump finish writing, if anything still holds the file
    assert_eq "" "$(find "$TMPDIR" -name 'velk-content-backup-*')" "a partial dump may not stay on this Mac"
}
