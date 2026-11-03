# tests/access_connect_test.sh — the client side: read the file, write the
# config, get a key authorized.

access_file() {   # a valid access file for the fake server
    local f="${SANDBOX}/site.test.velk"
    jq -n --arg path "$SERVER" '{
        velk_access: 1,
        site: {url: "https://site.test", subpath: ""},
        ssh: {host: "site.test", port: 65002, user: "u1"},
        path: $path,
        created_by: "Marina — Elleven Digital",
        created_at: "2026-09-21"}' > "$f"
    echo "$f"
}

connect() { bash "${SKILL_DIR}/scripts/access/connect.sh" "$@" 2>/dev/null; }

test_platform_accepts_macos_15_and_newer() {
    export FAKE_SW_VERS=15.0
    out=$(connect platform); code=$?
    assert_status 0 "$code"
    assert_eq "STATUS=OK" "$out"
}

test_platform_refuses_an_older_macos() {
    export FAKE_SW_VERS=14.6
    out=$(connect platform); code=$?
    assert_status 3 "$code"
    assert_contains "$out" "STATUS=MACOS_TOO_OLD"
}

test_platform_refuses_anything_but_macos() {
    export FAKE_UNAME=Linux
    out=$(connect platform); code=$?
    assert_status 3 "$code"
    assert_eq "STATUS=UNSUPPORTED_OS" "$out"
}

test_inspect_shows_what_will_be_connected() {
    f=$(access_file)
    out=$(connect inspect "$f"); code=$?
    assert_status 0 "$code"
    assert_contains "$out" "STATUS=OK"
    assert_contains "$out" "SITE=https://site.test"
    assert_contains "$out" "SERVER=u1@site.test:65002"
    assert_contains "$out" "CREATED_BY=Marina — Elleven Digital"
    assert_not_contains "$out" "AUTHORIZE"
    assert_not_contains "$out" "CONTACT"
}

test_inspect_refuses_an_old_file_that_says_who_authorizes() {
    # Who authorizes the key was never something the client needs; a file
    # from before it was dropped is asked for again, not half-read.
    for old in '{"by": "agency", "contact": "Marina"}' '{"by": "self"}'; do
        f=$(access_file)
        jq --argjson a "$old" '.authorize = $a' "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
        out=$(connect inspect "$f"); code=$?
        assert_status 2 "$code" "$old"
        assert_contains "$out" "STATUS=INVALID"
        assert_contains "$out" "authorize"
    done
}

test_inspect_rejects_a_file_with_a_field_outside_the_allowlist() {
    f=$(access_file)
    jq '.db = {"password": "x"}' "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
    out=$(connect inspect "$f"); code=$?
    assert_status 2 "$code"
    assert_contains "$out" "STATUS=INVALID"
}

test_inspect_rejects_a_file_that_is_not_json() {
    echo "not json" > "${SANDBOX}/x.velk"
    out=$(connect inspect "${SANDBOX}/x.velk"); code=$?
    assert_status 2 "$code"
    assert_contains "$out" "STATUS=INVALID"
}

test_setup_writes_a_private_config_without_any_database_section() {
    f=$(access_file)
    out=$(connect setup "$f" --project "$PROJECT" --identity "Maria"); code=$?
    assert_status 0 "$code"
    cfg="${PROJECT}/.deploy/ssh.json"
    assert_eq "site.test 65002 u1 ${SERVER}" "$(jq -r '"\(.ssh.host) \(.ssh.port) \(.ssh.user) \(.ssh.remote_path)"' "$cfg")"
    assert_eq "Maria" "$(jq -r .identity "$cfg")"
    assert_eq "null" "$(jq -c .db "$cfg")"
    assert_eq '{"created_by":"Marina — Elleven Digital"}' "$(jq -c .access "$cfg")"
    assert_eq "600" "$(stat -f %Lp "$cfg")"
}

test_setup_keeps_deploy_out_of_git_exactly_once() {
    f=$(access_file)
    connect setup "$f" --project "$PROJECT" --identity "Maria" >/dev/null
    connect setup "$f" --project "$PROJECT" --identity "Maria" >/dev/null
    assert_eq "1" "$(grep -cx '.deploy/' "${PROJECT}/.gitignore")"
}

test_setup_again_keeps_the_key_and_mode_already_chosen() {
    f=$(access_file)
    connect setup "$f" --project "$PROJECT" --identity "Maria" >/dev/null
    cfg="${PROJECT}/.deploy/ssh.json"
    jq '.ssh.key_path = "/k" | .mode = "live"' "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
    connect setup "$f" --project "$PROJECT" --identity "Maria" >/dev/null
    assert_eq "/k live" "$(jq -r '"\(.ssh.key_path) \(.mode)"' "$cfg")"
}

test_setup_again_drops_who_authorizes_from_an_old_config() {
    f=$(access_file)
    connect setup "$f" --project "$PROJECT" --identity "Maria" >/dev/null
    cfg="${PROJECT}/.deploy/ssh.json"
    jq '.access.authorize = {"by": "self"}' "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
    connect setup "$f" --project "$PROJECT" --identity "Maria" >/dev/null
    assert_eq '{"created_by":"Marina — Elleven Digital"}' "$(jq -c .access "$cfg")"
}

test_key_reports_authorized_without_creating_anything_when_access_works() {
    f=$(access_file)
    connect setup "$f" --project "$PROJECT" --identity "Maria" >/dev/null
    out=$(connect key --project "$PROJECT"); code=$?
    assert_status 0 "$code"
    assert_contains "$out" "STATUS=AUTHORIZED"
    assert_eq "" "$(ls "${HOME}/.ssh")"
}

test_key_reuses_a_default_key_without_a_passphrase() {
    sandbox_require_auth
    ssh-keygen -q -t ed25519 -N '' -f "${HOME}/.ssh/id_ed25519" -C mine
    f=$(access_file)
    connect setup "$f" --project "$PROJECT" --identity "Maria" >/dev/null
    out=$(connect key --project "$PROJECT"); code=$?
    assert_status 0 "$code"
    assert_contains "$out" "STATUS=NEEDS_AUTHORIZATION"
    assert_contains "$out" "KEY_FILE=${HOME}/.ssh/id_ed25519"
    assert_contains "$out" "KEY_CREATED=0"
    assert_contains "$out" "PUBLIC_KEY=$(cat "${HOME}/.ssh/id_ed25519.pub")"
    assert_eq "${HOME}/.ssh/id_ed25519" "$(jq -r .ssh.key_path "${PROJECT}/.deploy/ssh.json")"
}

test_key_creates_the_computers_key_when_there_is_none() {
    # The Mac of someone who never used SSH: not even ~/.ssh.
    sandbox_require_auth
    rmdir "${HOME}/.ssh"
    f=$(access_file)
    connect setup "$f" --project "$PROJECT" --identity "João Silva" >/dev/null
    out=$(connect key --project "$PROJECT"); code=$?
    assert_status 0 "$code"
    assert_contains "$out" "STATUS=NEEDS_AUTHORIZATION"
    assert_contains "$out" "KEY_FILE=${HOME}/.ssh/id_ed25519"
    assert_contains "$out" "KEY_CREATED=1"
    assert_contains "$out" "PUBLIC_KEY=$(cat "${HOME}/.ssh/id_ed25519.pub")"
    assert_eq "velk Joao-Silva" "$(awk '{print $3, $4}' "${HOME}/.ssh/id_ed25519.pub")"
    ssh-keygen -y -P '' -f "${HOME}/.ssh/id_ed25519" >/dev/null 2>&1 || fail "the new key must have no passphrase"
    assert_eq "${HOME}/.ssh/id_ed25519" "$(jq -r .ssh.key_path "${PROJECT}/.deploy/ssh.json")"
    assert_eq "700" "$(stat -f %Lp "${HOME}/.ssh")"
}

test_key_never_writes_over_a_public_key_it_did_not_create() {
    # A lone id_ed25519.pub — its private half kept by 1Password's agent, say —
    # is someone else's setup (IdentityFile, git signing): ssh-keygen would
    # replace it without asking.
    sandbox_require_auth
    echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOrphanOrphanOrphanOrphanOrphanOrphanOrph mine" > "${HOME}/.ssh/id_ed25519.pub"
    before=$(cat "${HOME}/.ssh/id_ed25519.pub")
    f=$(access_file)
    connect setup "$f" --project "$PROJECT" --identity "Maria" >/dev/null
    out=$(connect key --project "$PROJECT")
    assert_contains "$out" "KEY_FILE=${HOME}/.ssh/velk_ed25519"
    assert_contains "$out" "KEY_CREATED=1"
    assert_eq "$before" "$(cat "${HOME}/.ssh/id_ed25519.pub")"
    assert_no_file "${HOME}/.ssh/id_ed25519"
}

test_key_never_writes_through_a_symlink() {
    sandbox_require_auth
    mkdir -p "${SANDBOX}/elsewhere"
    ln -s "${SANDBOX}/elsewhere/key" "${HOME}/.ssh/id_ed25519"
    f=$(access_file)
    connect setup "$f" --project "$PROJECT" --identity "Maria" >/dev/null
    out=$(connect key --project "$PROJECT")
    assert_contains "$out" "KEY_FILE=${HOME}/.ssh/velk_ed25519"
    assert_no_file "${SANDBOX}/elsewhere/key"
}

test_key_never_writes_through_a_public_key_link() {
    sandbox_require_auth
    ln -s "${SANDBOX}/nowhere.pub" "${HOME}/.ssh/id_ed25519.pub"
    f=$(access_file)
    connect setup "$f" --project "$PROJECT" --identity "Maria" >/dev/null
    out=$(connect key --project "$PROJECT")
    assert_contains "$out" "KEY_FILE=${HOME}/.ssh/velk_ed25519"
    assert_no_file "${SANDBOX}/nowhere.pub"
}

test_key_gives_up_rather_than_write_over_a_lone_velk_public_key() {
    sandbox_require_auth
    ssh-keygen -q -t ed25519 -N 'secret phrase' -f "${HOME}/.ssh/id_ed25519" -C mine
    echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOrphanOrphanOrphanOrphanOrphanOrphanOrph mine" > "${HOME}/.ssh/velk_ed25519.pub"
    before=$(cat "${HOME}/.ssh/velk_ed25519.pub")
    f=$(access_file)
    connect setup "$f" --project "$PROJECT" --identity "Maria" >/dev/null
    out=$(connect key --project "$PROJECT"); code=$?
    assert_status 4 "$code"
    assert_contains "$out" "STATUS=FAILED"
    assert_eq "$before" "$(cat "${HOME}/.ssh/velk_ed25519.pub")"
    assert_no_file "${HOME}/.ssh/velk_ed25519"
}

test_key_shows_the_real_public_key_even_when_the_pub_file_is_missing_or_stale() {
    sandbox_require_auth
    ssh-keygen -q -t ed25519 -N '' -f "${HOME}/.ssh/id_ed25519" -C mine
    real=$(ssh-keygen -y -P '' -f "${HOME}/.ssh/id_ed25519")
    rm "${HOME}/.ssh/id_ed25519.pub"
    f=$(access_file)
    connect setup "$f" --project "$PROJECT" --identity "Maria" >/dev/null
    out=$(connect key --project "$PROJECT"); code=$?
    assert_status 0 "$code"
    assert_contains "$out" "PUBLIC_KEY=${real}"
    echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIStaleStaleStaleStaleStaleStaleStaleStaleSt old" > "${HOME}/.ssh/id_ed25519.pub"
    out=$(connect key --project "$PROJECT")
    assert_contains "$out" "PUBLIC_KEY=${real}"
    assert_not_contains "$out" "Stale"
}

test_key_keeps_the_key_this_project_already_uses() {
    sandbox_require_auth
    ssh-keygen -q -t ed25519 -N '' -f "${HOME}/.ssh/id_ed25519" -C mine
    ssh-keygen -q -t ed25519 -N '' -f "${HOME}/.ssh/work" -C work
    f=$(access_file)
    connect setup "$f" --project "$PROJECT" --identity "Maria" >/dev/null
    cfg="${PROJECT}/.deploy/ssh.json"
    jq '.ssh.key_path = "~/.ssh/work"' "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
    out=$(connect key --project "$PROJECT")
    assert_contains "$out" "KEY_FILE=${HOME}/.ssh/work"
    assert_contains "$out" "KEY_CREATED=0"
    assert_eq "${HOME}/.ssh/work" "$(jq -r .ssh.key_path "$cfg")"
}

test_key_reuses_an_rsa_key_too() {
    sandbox_require_auth
    ssh-keygen -q -t rsa -b 2048 -N '' -f "${HOME}/.ssh/id_rsa" -C mine
    f=$(access_file)
    connect setup "$f" --project "$PROJECT" --identity "Maria" >/dev/null
    out=$(connect key --project "$PROJECT")
    assert_contains "$out" "KEY_FILE=${HOME}/.ssh/id_rsa"
    assert_contains "$out" "KEY_CREATED=0"
}

test_key_creates_a_velk_key_when_the_default_one_has_a_passphrase() {
    # A passphrase makes every non-interactive ssh fail without saying why.
    # Without its .pub, only the private key itself says the path is taken.
    sandbox_require_auth
    ssh-keygen -q -t ed25519 -N 'secret phrase' -f "${HOME}/.ssh/id_ed25519" -C mine
    rm "${HOME}/.ssh/id_ed25519.pub"
    f=$(access_file)
    connect setup "$f" --project "$PROJECT" --identity "João Silva" >/dev/null
    out=$(connect key --project "$PROJECT")
    assert_contains "$out" "KEY_FILE=${HOME}/.ssh/velk_ed25519"
    assert_contains "$out" "KEY_CREATED=1"
    assert_eq "velk Joao-Silva" "$(awk '{print $3, $4}' "${HOME}/.ssh/velk_ed25519.pub")"
    ssh-keygen -y -P '' -f "${HOME}/.ssh/velk_ed25519" >/dev/null 2>&1 || fail "the new key must have no passphrase"
}

test_key_reuses_the_velk_key_on_a_mac_whose_default_key_has_a_passphrase() {
    # The key made for the first site serves the next ones too.
    sandbox_require_auth
    ssh-keygen -q -t ed25519 -N 'secret phrase' -f "${HOME}/.ssh/id_ed25519" -C mine
    ssh-keygen -q -t ed25519 -N '' -f "${HOME}/.ssh/velk_ed25519" -C "velk Maria 2026-09-01"
    f=$(access_file)
    connect setup "$f" --project "$PROJECT" --identity "Maria" >/dev/null
    out=$(connect key --project "$PROJECT"); code=$?
    assert_status 0 "$code"
    assert_contains "$out" "KEY_FILE=${HOME}/.ssh/velk_ed25519"
    assert_contains "$out" "KEY_CREATED=0"
}

test_a_second_site_reuses_the_key_created_for_the_first() {
    # One key per computer: a second site only needs it authorized there.
    sandbox_require_auth
    f=$(access_file)
    connect setup "$f" --project "$PROJECT" --identity "Maria" >/dev/null
    connect key --project "$PROJECT" >/dev/null
    other="${SANDBOX}/outro"; mkdir -p "$other"
    jq '.site.url = "https://outro.test"' "$f" > "${SANDBOX}/outro.test.velk"
    connect setup "${SANDBOX}/outro.test.velk" --project "$other" --identity "Maria" >/dev/null
    out=$(connect key --project "$other")
    assert_contains "$out" "KEY_FILE=${HOME}/.ssh/id_ed25519"
    assert_contains "$out" "KEY_CREATED=0"
    assert_eq "id_ed25519 id_ed25519.pub" "$(ls "${HOME}/.ssh" | tr '\n' ' ' | sed 's/ $//')"
}

test_key_says_the_server_did_not_answer_instead_of_asking_for_authorization() {
    sandbox_require_auth
    ssh-keygen -q -t ed25519 -N '' -f "${HOME}/.ssh/id_ed25519" -C mine
    f=$(access_file)
    connect setup "$f" --project "$PROJECT" --identity "Maria" >/dev/null
    export FAKE_SSH_UNREACHABLE=1
    out=$(connect key --project "$PROJECT"); code=$?
    assert_status 4 "$code"
    assert_contains "$out" "STATUS=UNREACHABLE"
    assert_not_contains "$out" "PUBLIC_KEY"
}

test_key_creates_nothing_while_the_server_does_not_answer() {
    # A new key would be one more thing to authorize, for a problem that is
    # the address, the port or the network.
    sandbox_require_auth
    f=$(access_file)
    connect setup "$f" --project "$PROJECT" --identity "Maria" >/dev/null
    export FAKE_SSH_UNREACHABLE=1
    out=$(connect key --project "$PROJECT"); code=$?
    assert_status 4 "$code"
    assert_contains "$out" "STATUS=UNREACHABLE"
    assert_eq "" "$(ls "${HOME}/.ssh")"
    assert_eq "null" "$(jq -r .ssh.key_path "${PROJECT}/.deploy/ssh.json")"
}

test_key_is_not_fooled_by_a_banner_that_says_timed_out() {
    # The server answered: its login banner just happens to say "timed out",
    # and the failure is another one — an agent offering too many keys, say.
    # That's no unreachable server: the key step goes on.
    sandbox_require_auth
    f=$(access_file)
    connect setup "$f" --project "$PROJECT" --identity "Maria" >/dev/null
    export FAKE_SSH_ERROR=$'Idle sessions are timed out after 15 minutes.\nReceived disconnect from 203.0.113.9 port 65002:2: Too many authentication failures'
    out=$(connect key --project "$PROJECT"); code=$?
    assert_status 0 "$code"
    assert_contains "$out" "STATUS=NEEDS_AUTHORIZATION"
    assert_contains "$out" "KEY_CREATED=1"
}

test_key_reads_a_refused_connection_or_an_unknown_host_as_unreachable() {
    # "Permission denied" before any connection is a firewall saying no, not
    # the server refusing the key; and a host ssh can't find is no key matter.
    sandbox_require_auth
    f=$(access_file)
    connect setup "$f" --project "$PROJECT" --identity "Maria" >/dev/null
    for err in "ssh: connect to host site.test port 65002: Permission denied" \
               'ssh: Could not resolve host "site.test"'; do
        export FAKE_SSH_ERROR="$err"
        out=$(connect key --project "$PROJECT"); code=$?
        assert_status 4 "$code" "$err"
        assert_contains "$out" "STATUS=UNREACHABLE"
    done
    assert_eq "" "$(ls "${HOME}/.ssh")"
}

test_key_stops_at_a_changed_server_identity() {
    # Stop and confirm with the agency first: no key is created meanwhile.
    sandbox_require_auth
    f=$(access_file)
    connect setup "$f" --project "$PROJECT" --identity "Maria" >/dev/null
    export FAKE_SSH_ERROR="@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@"
    out=$(connect key --project "$PROJECT"); code=$?
    assert_status 4 "$code"
    assert_contains "$out" "STATUS=HOST_KEY_CHANGED"
    assert_not_contains "$out" "PUBLIC_KEY"
    assert_eq "" "$(ls "${HOME}/.ssh")"
    out=$(connect test --project "$PROJECT"); code=$?
    assert_status 4 "$code"
    assert_eq "STATUS=HOST_KEY_CHANGED" "$out"
}

test_key_reports_any_other_failure_with_its_detail() {
    sandbox_require_auth
    ssh-keygen -q -t ed25519 -N '' -f "${HOME}/.ssh/id_ed25519" -C mine
    f=$(access_file)
    connect setup "$f" --project "$PROJECT" --identity "Maria" >/dev/null
    export FAKE_SSH_ERROR="kex_exchange_identification: read: Connection reset by peer"
    out=$(connect key --project "$PROJECT"); code=$?
    assert_status 4 "$code"
    assert_contains "$out" "STATUS=FAILED"
    assert_contains "$out" "DETAIL=kex_exchange_identification: read: Connection reset by peer"
    assert_not_contains "$out" "PUBLIC_KEY"
}

test_key_shows_the_public_key_and_leaves_the_clipboard_alone() {
    sandbox_require_auth
    export FAKE_CLIPBOARD="${SANDBOX}/clipboard"
    f=$(access_file)
    connect setup "$f" --project "$PROJECT" --identity "Maria" >/dev/null
    out=$(connect key --project "$PROJECT")
    assert_contains "$out" "PUBLIC_KEY=$(cat "${HOME}/.ssh/id_ed25519.pub")"
    assert_no_file "$FAKE_CLIPBOARD"
    assert_not_contains "$out" "AUTHORIZE_BY"
    assert_not_contains "$out" "CONTACT"
}

test_key_gives_up_when_every_key_it_could_use_has_a_passphrase() {
    sandbox_require_auth
    ssh-keygen -q -t ed25519 -N 'secret phrase' -f "${HOME}/.ssh/id_ed25519" -C mine
    ssh-keygen -q -t ed25519 -N 'secret phrase' -f "${HOME}/.ssh/velk_ed25519" -C mine
    f=$(access_file)
    connect setup "$f" --project "$PROJECT" --identity "Maria" >/dev/null
    out=$(connect key --project "$PROJECT"); code=$?
    assert_status 4 "$code"
    assert_contains "$out" "STATUS=FAILED"
    assert_contains "$out" "DETAIL="
    assert_eq "id_ed25519 id_ed25519.pub velk_ed25519 velk_ed25519.pub" "$(ls "${HOME}/.ssh" | tr '\n' ' ' | sed 's/ $//')"
}

test_test_tells_apart_unauthorized_unreachable_and_authorized() {
    sandbox_require_auth
    f=$(access_file)
    connect setup "$f" --project "$PROJECT" --identity "Maria" >/dev/null
    connect key --project "$PROJECT" >/dev/null
    out=$(connect test --project "$PROJECT"); code=$?
    assert_status 4 "$code"; assert_eq "STATUS=NOT_AUTHORIZED" "$out"

    sandbox_authorize "${HOME}/.ssh/id_ed25519.pub"
    out=$(connect test --project "$PROJECT"); code=$?
    assert_status 0 "$code"; assert_eq "STATUS=AUTHORIZED" "$out"

    export FAKE_SSH_UNREACHABLE=1
    out=$(connect test --project "$PROJECT"); code=$?
    assert_status 4 "$code"; assert_eq "STATUS=UNREACHABLE" "$out"
}

test_test_goes_through_the_ssh_alias_of_an_agency_config() {
    sandbox_velk_server
    cfg=$(sandbox_config)
    jq '.ssh = {"alias": "velk-staging", "remote_path": .ssh.remote_path}' "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
    out=$(connect test --project "$PROJECT"); code=$?
    assert_status 0 "$code"
    assert_eq "STATUS=AUTHORIZED" "$out"
    assert_contains "$(grep '^ssh ' "$FAKE_CALLS" | tail -1)" " velk-staging "
}

refused() {   # refused <jq path> <json value> — inspect and setup both refuse the file
    local f out code
    f=$(access_file)
    jq --argjson v "$2" "$1 = \$v" "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
    out=$(connect inspect "$f"); code=$?
    assert_status 2 "$code" "inspect must refuse $1 = $2"
    assert_contains "$out" "STATUS=INVALID"
    connect setup "$f" --project "$PROJECT" >/dev/null; code=$?
    assert_status 2 "$code" "setup must refuse $1 = $2"
}
str() { jq -n --arg s "$1" '$s'; }

test_a_file_with_hostile_fields_is_refused_before_anything_runs() {
    refused .ssh.user "$(str "-oProxyCommand=touch ${SANDBOX}/pwned;#")"
    refused .ssh.host "$(str "x';touch ${SANDBOX}/pwned;'")"
    refused .ssh.host "$(str "-oProxyCommand=x")"
    refused .ssh.port 0
    refused .ssh.port 70000
    refused .ssh.port 22.5
    refused .path "$(str "/home/u1/pub'lic")"
    refused .path "$(str "home/u1")"
    refused .path "$(str '/home/$(id)')"
    refused .site.url "$(str "javascript:alert(1)")"
    refused .site.url "$(str "https://site.test/a b")"
    refused .site.subpath "$(str "/x;rm")"
    refused .created_by "$(str $'\e[31mEvil')"
    refused .remote "$(jq -n '{php_bin: "php; touch pwned"}')"
    refused .rsync "$(jq -n '{theme_extra_excludes: ["a\nb"]}')"
    assert_no_file "${PROJECT}/.deploy/ssh.json"
    assert_eq "" "$(ls "$SANDBOX" | grep pwned)"
}

test_the_reason_names_the_field() {
    f=$(access_file)
    jq '.ssh.user = "-x"' "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
    assert_contains "$(connect inspect "$f")" "REASON=malformed field: ssh.user"
}

test_a_hand_edited_config_never_reaches_a_shell() {
    sandbox_velk_server
    cfg=$(sandbox_config)
    jq --arg h "x';touch ${SANDBOX}/pwned-host;'" '.ssh.host = $h' "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
    echo '{}' | bash "${SKILL_DIR}/scripts/content/velk.sh" --project "$PROJECT" -- page:update home --json-stdin --dry-run >/dev/null 2>&1
    jq --arg u "-oProxyCommand=touch ${SANDBOX}/pwned-user" '.ssh.host = "site.test" | .ssh.user = $u' \
        "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
    connect test --project "$PROJECT" >/dev/null
    bash "${SKILL_DIR}/scripts/theme/download-theme.sh" --project "$PROJECT" >/dev/null 2>&1
    assert_eq "" "$(ls "$SANDBOX" | grep pwned)"
}

test_setup_carries_the_servers_php_and_theme_excludes() {
    f=$(access_file)
    jq '.remote = {"php_bin": "/opt/cpanel/ea-php82/root/usr/bin/php"} | .rsync = {"theme_extra_excludes": ["docs/", "*.psd"]}' \
        "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
    out=$(connect setup "$f" --project "$PROJECT" --identity "Maria"); code=$?
    assert_status 0 "$code"
    cfg="${PROJECT}/.deploy/ssh.json"
    assert_eq "/opt/cpanel/ea-php82/root/usr/bin/php" "$(jq -r .remote.php_bin "$cfg")"
    assert_eq '["docs/","*.psd"]' "$(jq -c .rsync.theme_extra_excludes "$cfg")"
}

test_setup_again_keeps_a_php_set_here_when_the_file_names_none() {
    f=$(access_file)
    connect setup "$f" --project "$PROJECT" --identity "Maria" >/dev/null
    cfg="${PROJECT}/.deploy/ssh.json"
    jq '.remote = {"php_bin": "/usr/local/bin/php82"}' "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
    connect setup "$f" --project "$PROJECT" --identity "Maria" >/dev/null
    assert_eq "/usr/local/bin/php82" "$(jq -r .remote.php_bin "$cfg")"
}
