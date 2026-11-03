# tests/deploy_init_test.sh — the first deploy's migrate: it runs with the
# PHP the config names, and a failing one stops the deploy.

init_world() {   # a pristine local Velk project, an empty target, fake databases
    sandbox_require_php
    sandbox_velk_server
    rm -rf "${SERVER:?}"/*                       # init wants an empty target
    base=$(sandbox_release v9.9.9)
    sandbox_engine_project v9.9.9 "$base"
    CFG=$(sandbox_config)
    mkdir -p "${SANDBOX}/bin"
    printf '#!/bin/bash\necho "-- local dump"\n' > "${SANDBOX}/bin/mysqldump"   # the local database
    printf '#!/bin/bash\n{ echo "ARGS $*"; cat "${1#--defaults-extra-file=}"; } >> "%s/import.log"\ncat >/dev/null\n' \
        "$SANDBOX" > "${FAKE_REMOTE_PATH}/mysql"                                   # the server's
    chmod +x "${SANDBOX}/bin/mysqldump" "${FAKE_REMOTE_PATH}/mysql"
    export PATH="${SANDBOX}/bin:${PATH}"
    printf '#!/bin/bash\necho "$*" >> "%s/php-calls"\nexec "%s" "$@"\n' "$SANDBOX" "$DEV_PHP" > "${SANDBOX}/ea-php82"
    chmod +x "${SANDBOX}/ea-php82"
    jq --arg php "${SANDBOX}/ea-php82" '.db = {"name": "d", "user": "u", "password": "init-S3cret"}
        | .local = {"db_name": "l"} | .remote.php_bin = $php' "$CFG" > "${CFG}.tmp" && mv "${CFG}.tmp" "$CFG"
}
init() { out=$(bash "${SKILL_DIR}/scripts/deploy/init.sh" --project "$PROJECT" 2>&1); code=$?; }   # from anywhere: the script cds itself

test_init_migrates_with_the_configured_php() {
    init_world
    init
    assert_status 0 "$code" "$out"
    assert_contains "$(cat "${SANDBOX}/php-calls" 2>/dev/null)" "bin/velk migrate"
    assert_contains "$out" "Init deploy complete"
}

test_init_takes_a_relative_project_path() {
    init_world
    out=$(cd "$SANDBOX" && bash "${SKILL_DIR}/scripts/deploy/init.sh" --project project 2>&1); code=$?
    assert_status 0 "$code" "$out"
    assert_contains "$out" "Init deploy complete"
}

test_init_refuses_a_target_it_cannot_read_as_plainly_empty() {
    init_world
    sandbox_velk_server                          # Velk IS there…
    echo live > "${SERVER}/theme/live.txt"
    FAKE_SSH_HOOK_ON="core/Bootstrap.php" \
    FAKE_SSH_HOOK='echo "Welcome to site.test"' \
        init                                     # …behind a login banner on stdout
    assert_status 1 "$code" "$out"
    assert_contains "$out" "nothing was sent"
    assert_not_contains "$out" "Dumping local DB"
    assert_file "${SERVER}/theme/live.txt" "the live site is untouched"
}

test_init_goes_on_when_ssh_only_warns_on_stderr() {
    init_world
    FAKE_SSH_HOOK_ON="core/Bootstrap.php" \
    FAKE_SSH_HOOK='echo "Warning: Permanently added site.test to the list of known hosts." >&2' \
        init                                     # a first connection; the target is empty
    assert_status 0 "$code" "$out"
    assert_contains "$out" "Init deploy complete"
}

test_a_failing_migrate_stops_the_deploy() {
    init_world
    echo 1 > "${PROJECT}/.stub-exit-migrate"     # shipped to the server with the rest
    init
    assert_status 1 "$code"
    assert_not_contains "$out" "Init deploy complete"
}

test_the_database_import_never_puts_the_password_on_a_command_line() {
    init_world
    FAKE_SSH_HOOK_ON="'import'" \
    FAKE_SSH_HOOK='stat -f %Lp "$(grep -o "/tmp/velk-init-import[.][A-Za-z0-9]*" <<< "$FAKE_SSH_CMD")" > "${SANDBOX}/sent-mode"' \
        init
    assert_status 0 "$code" "$out"
    assert_contains "$(cat "${SANDBOX}/import.log")" 'password="init-S3cret"'
    assert_not_contains "$(cat "$FAKE_CALLS")" "init-S3cret"
    assert_eq "600" "$(cat "${SANDBOX}/sent-mode")" "the dump on the server's /tmp is only its owner's"
}

test_the_local_dump_never_puts_the_password_on_a_command_line() {
    init_world
    printf '#!/bin/bash\n{ echo "ARGS $*"; cat "${1#--defaults-extra-file=}"; } >> "%s/local-dump.log"\necho "-- local dump"\n' "$SANDBOX" \
        > "${SANDBOX}/bin/mysqldump"
    jq '.local.db_password = "loc-S3cret"' "$CFG" > "${CFG}.tmp" && mv "${CFG}.tmp" "$CFG"
    FAKE_SSH_HOOK_ON="velk-init-import" \
    FAKE_SSH_HOOK='stat -f %Lp "${TMPDIR:-/tmp}"/velk-init-*.?????? > "${SANDBOX}/dump-modes"' \
        init
    assert_status 0 "$code" "$out"
    log=$(cat "${SANDBOX}/local-dump.log")
    assert_contains "$log" 'password="loc-S3cret"' "the password travels in the option file"
    assert_not_contains "$(grep '^ARGS' <<< "$log")" "loc-S3cret" "never on a command line"
    assert_contains "$(grep '^ARGS' <<< "$log")" "--no-tablespaces --single-transaction l"
    assert_not_contains "$log" "--set-gtid-purged" "a mysqldump without the option (MariaDB) never gets it"
    assert_eq "600" "$(sort -u "${SANDBOX}/dump-modes")" "the dump on this Mac is only its owner's"
}

test_init_robots_txt_does_not_list_the_admin() {   # engine v3.8.1: the admin answers noindex; a Disallow would hide it, and robots.txt is public
    init_world
    init
    assert_status 0 "$code" "$out"
    local robots; robots=$(cat "${SERVER}/robots.txt")
    assert_contains "$robots" "/sitemap.xml" "robots.txt points at the real sitemap"
    assert_not_contains "$robots" "Disallow" "a Disallow keeps crawlers from ever seeing the admin's noindex"
    assert_not_contains "$robots" "admin" "robots.txt is public: listing the admin gives away its path"
}

test_a_gtid_dump_is_turned_off_where_mysqldump_offers_it() {   # Homebrew MySQL: SQL_LOG_BIN in the dump, refused by shared hosting on import
    init_world
    printf '#!/bin/bash\nif [ "$1" = --help ]; then echo "  --set-gtid-purged[=name]"; exit 0; fi\necho "ARGS $*" >> "%s/local-dump.log"\necho "-- local dump"\n' "$SANDBOX" \
        > "${SANDBOX}/bin/mysqldump"
    init
    assert_status 0 "$code" "$out"
    assert_contains "$(cat "${SANDBOX}/local-dump.log")" "--set-gtid-purged=OFF"
}

test_init_ships_functions_php() {   # it used to fall under --exclude=theme/*.php: a first deploy without the theme's code
    init_world
    mkdir -p "${PROJECT}/theme"
    echo '<?php function tema_ok() {}' > "${PROJECT}/theme/functions.php"
    init
    assert_status 0 "$code" "$out"
    assert_file "${SERVER}/theme/functions.php"
}

test_init_refuses_source_pages_left_in_the_theme() {
    init_world
    mkdir -p "${PROJECT}/theme"
    echo '<?php // produto.php do template' > "${PROJECT}/theme/produto.php"
    mkdir -p "${PROJECT}/theme/includes"; echo '<?php' > "${PROJECT}/theme/includes/helpers.php"
    init
    assert_status 1 "$code" "$out"
    assert_contains "$out" "theme/produto.php"
    assert_contains "$out" "theme/includes/"
    assert_not_contains "$out" "Delete _source" "no _source/ here: no advice about it"
    assert_contains "$out" "nothing was sent"
    assert_not_contains "$out" "Dumping local DB"
    assert_no_file "${SERVER}/core/Bootstrap.php" "the target stays empty, so init can run again"
}

test_init_refuses_a_source_folder_unless_the_config_excludes_it() {
    init_world
    mkdir -p "${PROJECT}/_source/data"; echo '{"emails": "internos"}' > "${PROJECT}/_source/data/contato.json"
    init
    assert_status 1 "$code" "$out"
    assert_contains "$out" "_source/"
    assert_no_file "${SERVER}/core/Bootstrap.php"
    jq '.rsync.extra_excludes = ["_source/"]' "$CFG" > "${CFG}.tmp" && mv "${CFG}.tmp" "$CFG"
    init
    assert_status 0 "$code" "$out"
    assert_no_dir "${SERVER}/_source" "an excluded source folder never reaches the server"
}

test_a_subdirectory_install_gets_its_own_sitemap_url() {
    init_world
    jq '.site.subpath = "/blog"' "$CFG" > "${CFG}.tmp" && mv "${CFG}.tmp" "$CFG"
    init
    assert_status 0 "$code" "$out"
    assert_contains "$(cat "${SERVER}/robots.txt")" "Sitemap: https://site.test/blog/sitemap.xml"
    assert_contains "$out" "Verifying https://site.test/blog"
    assert_contains "$out" "crawlers never read https://site.test/blog/robots.txt"
}

test_a_root_install_gets_no_subdirectory_warning() {
    init_world
    init
    assert_status 0 "$code" "$out"
    assert_contains "$(cat "${SERVER}/robots.txt")" "Sitemap: https://site.test/sitemap.xml"
    assert_not_contains "$out" "Subdirectory install"
}
