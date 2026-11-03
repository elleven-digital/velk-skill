# tests/access_generate_test.sh — the access file carries only what the
# allowlist names, and never a value the config holds back.

SECRET="Pr0d-DB-p4ss!w0rd"

agency_config() {
    cat > "${PROJECT}/.deploy/ssh.json" <<JSON
{
  "ssh": { "host": "exemplo.com.br", "port": 65002, "user": "u123456789",
           "key_path": "~/.ssh/id_ed25519",
           "remote_path": "/home/u123456789/domains/exemplo.com.br/public_html" },
  "site": { "url": "https://exemplo.com.br", "domain": "exemplo.com.br", "subpath": "",
            "local_url": "http://localhost:8080" },
  "db": { "host": "localhost", "name": "u123456789_site", "user": "u123456789_admin",
          "password": "${SECRET}" },
  "local": { "db_host": "localhost", "db_name": "exemplo", "db_user": "root", "db_password": "" },
  "identity": "Marina"
}
JSON
    echo "${PROJECT}/.deploy/ssh.json"
}

generate() {
    bash "${SKILL_DIR}/scripts/access/generate.sh" "$@" 2>/dev/null
}

test_the_file_holds_exactly_the_allowed_fields() {
    cfg=$(agency_config)
    out=$(generate --project "$PROJECT"); code=$?
    assert_status 0 "$code"
    file="${out#ACCESS_FILE=}"
    keys=$(jq -r 'paths(scalars) | join(".")' "$file" | sort | tr '\n' ' ')
    assert_eq "created_at created_by path site.subpath site.url ssh.host ssh.port ssh.user velk_access " "$keys"
}

test_the_database_password_never_reaches_the_file() {
    cfg=$(agency_config)
    out=$(generate --project "$PROJECT")
    file="${out#ACCESS_FILE=}"
    assert_file "$file"
    assert_not_contains "$(cat "$file")" "$SECRET"
    assert_not_contains "$(cat "$file")" "u123456789_admin"
}

test_the_file_is_named_after_the_domain_at_the_project_root() {
    cfg=$(agency_config)
    out=$(generate --project "$PROJECT")
    assert_eq "ACCESS_FILE=${PROJECT}/exemplo.com.br.velk" "$out"
    assert_eq "1" "$(jq -r .velk_access "${PROJECT}/exemplo.com.br.velk")"
    assert_eq "65002" "$(jq -r '.ssh.port | tostring' "${PROJECT}/exemplo.com.br.velk")"
}

test_there_is_no_option_saying_who_authorizes_the_key() {
    # Whoever has access to the hosting authorizes the client's key; the file
    # doesn't say who. The old flags are refused, not silently ignored.
    cfg=$(agency_config)
    generate --project "$PROJECT" --authorize agency --contact "Marina" >/dev/null; code=$?
    assert_status 2 "$code"
    assert_no_file "${PROJECT}/exemplo.com.br.velk"
}

test_an_ssh_alias_is_resolved_to_the_real_server() {
    cfg=$(agency_config)
    jq '.ssh = {"alias": "exemplo", "remote_path": "/home/u9/public_html"}' "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
    printf 'user u9\nhostname srv.hosting.test\nport 2222\nidentityfile ~/.ssh/agency_key\n' > "$FAKE_SSH_G_OUTPUT"
    generate --project "$PROJECT" >/dev/null
    f="${PROJECT}/exemplo.com.br.velk"
    assert_eq "srv.hosting.test 2222 u9" "$(jq -r '"\(.ssh.host) \(.ssh.port) \(.ssh.user)"' "$f")"
    assert_not_contains "$(cat "$f")" "agency_key"
}

test_a_secret_typed_into_an_allowed_field_aborts_and_deletes_the_file() {
    cfg=$(agency_config)
    out=$(bash "${SKILL_DIR}/scripts/access/generate.sh" --project "$PROJECT" \
        --created-by "Marina ${SECRET}" 2>&1); code=$?
    assert_status 3 "$code"
    assert_contains "$out" "db.password"
    assert_not_contains "$out" "$SECRET" "the report names the key, never the value"
    assert_no_file "${PROJECT}/exemplo.com.br.velk"
}

test_leak_check_rejects_a_key_outside_the_allowlist() {
    cfg=$(agency_config)
    printf '{"velk_access":1,"site":{"url":"https://exemplo.com.br"},"db":{"name":"x"}}\n' > "${SANDBOX}/f.velk"
    out=$(perl "${SKILL_DIR}/scripts/access/leak-check.pl" --config "$cfg" --file "${SANDBOX}/f.velk"); code=$?
    assert_status 1 "$code"
    assert_eq "KEY db.name" "$out"
}

test_leak_check_accepts_the_domain_inside_the_url() {
    # site.domain is public and naturally appears inside site.url and path —
    # a naive "no config value may appear" rule would abort every real file.
    cfg=$(agency_config)
    generate --project "$PROJECT" >/dev/null
    out=$(perl "${SKILL_DIR}/scripts/access/leak-check.pl" --config "$cfg" --file "${PROJECT}/exemplo.com.br.velk"); code=$?
    assert_status 0 "$code"
    assert_eq "" "$out"
}

test_leak_check_treats_an_unknown_config_field_as_secret() {
    cfg=$(agency_config)
    jq '.stripe = {"token": "tok_live_abcdef"}' "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
    printf '{"velk_access":1,"created_by":"tok_live_abcdef"}\n' > "${SANDBOX}/f.velk"
    out=$(perl "${SKILL_DIR}/scripts/access/leak-check.pl" --config "$cfg" --file "${SANDBOX}/f.velk"); code=$?
    assert_status 1 "$code"
    assert_eq "VALUE stripe.token" "$out"
}

test_the_servers_php_and_theme_excludes_travel_in_the_file() {
    cfg=$(agency_config)
    jq '.remote = {"php_bin": "/opt/cpanel/ea-php82/root/usr/bin/php"} | .rsync = {"theme_extra_excludes": ["docs/", "*.psd"]}' \
        "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
    out=$(generate --project "$PROJECT"); code=$?
    assert_status 0 "$code"
    file="${out#ACCESS_FILE=}"
    assert_eq "/opt/cpanel/ea-php82/root/usr/bin/php" "$(jq -r .remote.php_bin "$file")"
    assert_eq '["docs/","*.psd"]' "$(jq -c .rsync.theme_extra_excludes "$file")"
}

test_a_config_the_client_would_refuse_writes_no_file() {
    cfg=$(agency_config)
    jq '.ssh.remote_path = "/home/u1/pub'"'"'lic"' "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
    out=$(generate --project "$PROJECT"); code=$?
    assert_status 2 "$code"
    assert_no_file "${PROJECT}/exemplo.com.br.velk"
}
