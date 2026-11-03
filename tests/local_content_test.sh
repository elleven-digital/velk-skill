# tests/local_content_test.sh — "local" mode's copy of the site: the released
# engine, the live theme, uploads, and content only — nothing personal, no
# production secret.

DB_SECRET="prod-db-S3cret"

content_world() {
    sandbox_velk_server
    sandbox_require_php
    sandbox_theme "${SERVER}/theme"
    base=$(sandbox_release v9.9.9)
    printf '{"version":"v9.9.9","release_base_url":"%s"}\n' "$base" > "${SERVER}/.velk-version"
    echo '<?php // only on the server' > "${SERVER}/core/ServerOnly.php"
    mkdir -p "${SERVER}/storage/uploads/2026" "${SERVER}/storage/form-uploads"
    echo jpg > "${SERVER}/storage/uploads/2026/a.jpg"
    echo pdf > "${SERVER}/storage/form-uploads/lead.pdf"
    cat > "${SERVER}/.env" <<ENV
APP_NAME="Exemplo"
APP_TIMEZONE=America/Sao_Paulo
ADMIN_LOCALE=pt
DB_HOST=localhost
DB_DATABASE=u1_site
DB_USERNAME=u1_admin
DB_PASSWORD="${DB_SECRET}"
SMTP_PASS="smtp-S3cret"
STRIPE_SECRET_KEY="sk_live_S3cret"
TURNSTILE_SECRET_KEY="ts-S3cret"
ENV
    # mysqldump on the server: logs its arguments and what its option file held.
    cat > "${FAKE_REMOTE_PATH}/mysqldump" <<'FAKE'
#!/bin/bash
opt="${1#--defaults-extra-file=}"
{ echo "ARGS $*"; echo "OPTFILE ${opt}"; grep -q "prod-db-S3cret" "$opt" && echo "OPTFILE_HAS_PASSWORD"; } >> "${SANDBOX}/mysqldump.log"
echo "INSERT INTO \`items\` (\`id\`) VALUES (1);"
FAKE
    chmod +x "${FAKE_REMOTE_PATH}/mysqldump"
    # the local mysql client: logs arguments and whatever SQL it is fed.
    mkdir -p "${SANDBOX}/bin"
    printf '#!/bin/bash\n{ echo "ARGS $*"; cat; } >> "%s/mysql.log"\n' "$SANDBOX" > "${SANDBOX}/bin/mysql"
    chmod +x "${SANDBOX}/bin/mysql"
    cfg=$(sandbox_config)
    jq --arg php "$DEV_PHP" --arg mysql "${SANDBOX}/bin/mysql" \
        '.local = {"php_bin": $php, "mysql_bin": $mysql}' "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
}

run_content() {
    bash "${SKILL_DIR}/scripts/local/content.sh" --project "$PROJECT" 2>"${SANDBOX}/content.err"
}

test_the_engine_comes_from_the_release_never_from_the_server() {
    content_world
    out=$(run_content); code=$?
    assert_status 0 "$code" "$(cat "${SANDBOX}/content.err")"
    assert_eq "<?php // app" "$(cat "${PROJECT}/core/App.php")"
    assert_no_file "${PROJECT}/core/ServerOnly.php"
    assert_eq "v9.9.9" "$(jq -r .version "${PROJECT}/.velk-version")"
}

test_uploads_come_down_and_form_attachments_never_do() {
    content_world
    run_content >/dev/null
    assert_file "${PROJECT}/storage/uploads/2026/a.jpg"
    assert_no_file "${PROJECT}/storage/form-uploads/lead.pdf"
}

test_the_local_env_file_has_no_production_secret() {
    content_world
    run_content >/dev/null
    env_file=$(cat "${PROJECT}/.env")
    for secret in "$DB_SECRET" smtp-S3cret sk_live_S3cret ts-S3cret u1_admin; do
        assert_not_contains "$env_file" "$secret"
    done
    assert_contains "$env_file" "ADMIN_LOCALE=pt"
    assert_contains "$env_file" "APP_DEBUG=true"
    assert_eq "600" "$(stat -f %Lp "${PROJECT}/.env")"
}

test_only_the_content_tables_are_dumped_and_only_their_data() {
    content_world
    run_content >/dev/null
    args=$(grep '^ARGS' "${SANDBOX}/mysqldump.log")
    assert_contains "$args" "--no-create-info"
    assert_contains "$args" " u1_site items item_term terms pages media settings languages config_translations theme_strings form_settings"
    for personal in users members orders form_submissions form_recipients tracking_scripts; do
        assert_not_contains "$args" " ${personal}"
    done
}

test_the_production_db_password_never_leaves_the_server() {
    content_world
    run_content >/dev/null
    log=$(cat "${SANDBOX}/mysqldump.log")
    assert_contains "$log" "OPTFILE_HAS_PASSWORD" "the dump must authenticate through the option file"
    assert_not_contains "$(grep '^ARGS' "${SANDBOX}/mysqldump.log")" "$DB_SECRET"
    assert_no_file "$(sed -n 's/^OPTFILE //p' "${SANDBOX}/mysqldump.log")" "the option file must be gone"
    assert_eq "" "$(grep -rl "$DB_SECRET" "$PROJECT" || true)"
}

test_the_import_empties_the_content_tables_first_and_silences_conversions() {
    content_world
    run_content >/dev/null
    sql=$(cat "${SANDBOX}/mysql.log")
    assert_contains "$sql" "TRUNCATE TABLE \`items\`;"
    assert_contains "$sql" "TRUNCATE TABLE \`form_settings\`;"
    before_insert="${sql%%INSERT INTO*}"
    assert_contains "$before_insert" "TRUNCATE TABLE \`theme_strings\`;"
    assert_contains "$sql" "UPDATE \`form_settings\` SET \`conversion_snippet\` = NULL;"
}

test_a_local_admin_is_created_and_reported() {
    content_world
    out=$(run_content)
    assert_contains "$out" "STATUS=READY"
    assert_contains "$out" "ADMIN_EMAIL=admin@local.test"
    pass=$(sed -n 's/^ADMIN_PASSWORD=//p' <<< "$out")
    [ "${#pass}" -ge 16 ] || fail "local admin password too short: [$pass]"
    assert_contains "$(cat "${PROJECT}/.stub-calls")" "install --email=admin@local.test --password=${pass}"
}

test_the_theme_arrives_with_its_starting_point() {
    content_world
    run_content >/dev/null
    assert_file "${PROJECT}/theme/site.json"
    assert_file "${PROJECT}/.deploy/theme-base.json"
    assert_eq "1" "$(grep -cx '.deploy/' "${PROJECT}/.gitignore")"
}

test_the_local_copy_passes_on_someone_elses_publish() {
    content_world
    lock_as "Maria@other-mac" 30
    out=$(run_content); code=$?
    assert_status 5 "$code"
    assert_contains "$out" "STATUS=BUSY"
    assert_contains "$out" "OWNER=Maria@other-mac"
}

test_the_local_copy_can_take_over_a_stale_lock() {
    content_world
    lock_as "Maria@other-mac" 1000
    out=$(bash "${SKILL_DIR}/scripts/local/content.sh" --project "$PROJECT" --take-over-stale 2>"${SANDBOX}/content.err"); code=$?
    assert_status 0 "$code" "$(cat "${SANDBOX}/content.err")"
    assert_contains "$out" "STATUS=READY"
    assert_contains "$out" "RECOVERED=released-lock"
    assert_no_dir "${SERVER}/.velk-theme.lock"
}

test_the_local_copy_passes_on_what_the_recovery_warned_about() {
    content_world
    unrecorded_swap_with_warning
    out=$(run_content); code=$?
    assert_status 0 "$code" "$(cat "${SANDBOX}/content.err")"
    assert_contains "$out" "RECOVERED=finished-publish"
    assert_contains "$out" "WARN=STILL_FAILING schema:validate"
}

test_a_refresh_stops_before_unpublished_theme_work() {
    content_world
    run_content >/dev/null || fail "first run"
    echo '<?php // mine' > "${PROJECT}/theme/templates/home.php"
    echo '<?php // new' > "${PROJECT}/theme/templates/landing.php"
    out=$(run_content); code=$?
    assert_status 4 "$code"
    assert_contains "$out" "STATUS=LOCAL_CHANGES"
    assert_contains "$out" "LOCAL_CHANGE=templates/home.php"
    assert_contains "$out" "LOCAL_CHANGE=templates/landing.php"
    assert_eq '<?php // mine' "$(cat "${PROJECT}/theme/templates/home.php")"
    assert_file "${PROJECT}/theme/templates/landing.php"
    out=$(bash "${SKILL_DIR}/scripts/local/content.sh" --project "$PROJECT" --discard-theme-changes 2>/dev/null); code=$?
    assert_status 0 "$code"
    assert_contains "$out" "STATUS=READY"
    assert_no_file "${PROJECT}/theme/templates/landing.php"
}

test_a_refresh_with_no_theme_changes_goes_through() {
    content_world
    run_content >/dev/null || fail "first run"
    out=$(run_content); code=$?
    assert_status 0 "$code"
    assert_contains "$out" "STATUS=READY"
}

test_a_noisy_php_on_the_server_reaches_neither_the_local_env_nor_the_dump() {
    content_world
    noisy_server_php
    run_content >/dev/null || fail "run: $(cat "${SANDBOX}/content.err")"
    assert_not_contains "$(cat "${PROJECT}/.env")" "PHP Warning"
    assert_not_contains "$(cat "${SANDBOX}/mysqldump.log")" "PHP Warning"
    assert_contains "$(grep '^ARGS' "${SANDBOX}/mysqldump.log")" "u1_site"
}

test_engine_paths_naming_the_project_itself_are_skipped() {
    content_world
    sandbox_release v9.9.9 "" '.engine_paths += ["", ".", "./"] | .post_install_cleanup += ["", "."]' >/dev/null
    run_content >/dev/null || fail "run: $(cat "${SANDBOX}/content.err")"
    assert_file "${PROJECT}/.deploy/ssh.json" "the project itself is never an engine path"
    assert_file "${PROJECT}/theme/site.json"
}

test_public_settings_are_read_the_way_velk_reads_them() {
    content_world
    printf '%s\n' 'export APP_NAME="Exemplo \"Site\""' 'ADMIN_LOCALE=pt' 'DB_DATABASE=u1_site' 'DB_USERNAME=u1_admin' \
        "DB_PASSWORD=\"${DB_SECRET}\"" > "${SERVER}/.env"
    run_content >/dev/null || fail "run: $(cat "${SANDBOX}/content.err")"
    assert_contains "$(cat "${PROJECT}/.env")" 'APP_NAME="Exemplo \"Site\""'
    assert_contains "$(cat "${PROJECT}/.env")" "ADMIN_LOCALE=pt"
}

test_the_local_import_never_puts_the_password_on_a_command_line() {
    content_world
    printf '#!/bin/bash\n{ echo "ARGS $*"; cat "${1#--defaults-extra-file=}"; cat; } >> "%s/mysql.log"\n' "$SANDBOX" > "${SANDBOX}/bin/mysql"
    jq '.local.db_password = "loc-S3cret"' "${PROJECT}/.deploy/ssh.json" > "${PROJECT}/.deploy/ssh.json.tmp" \
        && mv "${PROJECT}/.deploy/ssh.json.tmp" "${PROJECT}/.deploy/ssh.json"
    run_content >/dev/null || fail "run: $(cat "${SANDBOX}/content.err")"
    log=$(cat "${SANDBOX}/mysql.log")
    assert_contains "$log" 'password="loc-S3cret"' "the password travels in the option file"
    assert_not_contains "$(grep '^ARGS' <<< "$log")" "loc-S3cret" "never on a command line"
    assert_contains "$(grep '^ARGS' <<< "$log")" "--defaults-extra-file="
}

test_a_refresh_without_a_starting_point_compares_with_what_is_live() {
    content_world
    run_content >/dev/null || fail "first run"
    rm -rf "${PROJECT}/.deploy/theme-base" "${PROJECT}/.deploy/theme-base.json"
    echo '<?php // mine' > "${PROJECT}/theme/templates/home.php"
    out=$(run_content); code=$?
    assert_status 4 "$code"
    assert_contains "$out" "LOCAL_CHANGE=templates/home.php"
    assert_eq '<?php // mine' "$(cat "${PROJECT}/theme/templates/home.php")"
}

test_the_comparison_with_what_is_live_leaves_no_file_behind() {
    content_world
    run_content >/dev/null || fail "first run"
    rm -rf "${PROJECT}/.deploy/theme-base" "${PROJECT}/.deploy/theme-base.json"
    echo '<?php // mine' > "${PROJECT}/theme/templates/home.php"
    mkdir -p "${SANDBOX}/bin"     # macOS mktemp ignores TMPDIR: log what it makes instead
    printf '#!/bin/bash\nf=$(/usr/bin/mktemp "$@") || exit\necho "$f" >> "%s/mktemp.log"\necho "$f"\n' "$SANDBOX" \
        > "${SANDBOX}/bin/mktemp"
    chmod +x "${SANDBOX}/bin/mktemp"
    out=$(export PATH="${SANDBOX}/bin:${PATH}"; run_content); code=$?
    assert_status 4 "$code"
    while IFS= read -r f; do
        [[ ! -e "$f" ]] || fail "left behind: ${f}"
    done < <(cat "${SANDBOX}/mktemp.log" 2>/dev/null)
}
