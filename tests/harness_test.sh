# tests/harness_test.sh — the harness proves itself before anything relies on it.

test_temporary_files_stay_inside_the_sandbox() {
    # Scripts and tests make temporary files with mktemp: inside the sandbox
    # they go away with it, instead of piling up in this Mac's real TMPDIR.
    case "$TMPDIR" in "${SANDBOX}/"*) ;; *) fail "TMPDIR is outside the sandbox: ${TMPDIR}" ;; esac
    f=$(mktemp); d=$(mktemp -d)
    case "$f" in "${SANDBOX}/"*) ;; *) fail "mktemp wrote outside the sandbox: ${f}" ;; esac
    case "$d" in "${SANDBOX}/"*) ;; *) fail "mktemp -d wrote outside the sandbox: ${d}" ;; esac
}

test_fake_ssh_runs_the_remote_command_locally() {
    out=$(ssh -p 65002 -i /no/such/key -o BatchMode=yes u1@site.test "cd '${SERVER}' && pwd")
    assert_eq "$SERVER" "$out"
}

test_fake_ssh_accepts_options_after_the_destination() {
    # preflight.sh does exactly this: "${ssh_args[@]}" -o ConnectTimeout=10 "echo OK"
    out=$(ssh -p 65002 -o BatchMode=yes u1@site.test -o ConnectTimeout=10 "echo OK")
    assert_eq "OK" "$out"
}

test_rsync_through_the_fake_ssh_copies_files() {
    sandbox_theme "${PROJECT}/theme"
    rsync -a -e "ssh -p 65002" "${PROJECT}/theme/" "u1@site.test:${SERVER}/theme/" 2>&1
    assert_file "${SERVER}/theme/templates/home.php"
}

test_fake_ssh_refuses_an_unauthorized_key() {
    sandbox_require_auth
    ssh-keygen -q -t ed25519 -N '' -f "${HOME}/.ssh/id_ed25519" -C t
    out=$(ssh u1@site.test "echo OK" 2>&1); code=$?
    assert_status 255 "$code"
    assert_contains "$out" "Permission denied"
}

test_fake_ssh_accepts_an_authorized_key() {
    sandbox_require_auth
    ssh-keygen -q -t ed25519 -N '' -f "${HOME}/.ssh/id_ed25519" -C t
    sandbox_authorize "${HOME}/.ssh/id_ed25519.pub"
    out=$(ssh u1@site.test "echo OK")
    assert_eq "OK" "$out"
}

test_fake_ssh_falls_back_to_default_keys_when_the_given_one_is_missing() {
    # real ssh warns about a missing -i file and still tries ~/.ssh/id_*
    sandbox_require_auth
    ssh-keygen -q -t ed25519 -N '' -f "${HOME}/.ssh/id_ed25519" -C t
    sandbox_authorize "${HOME}/.ssh/id_ed25519.pub"
    out=$(ssh -i "${HOME}/.ssh/nope" u1@site.test "echo OK")
    assert_eq "OK" "$out"
}

test_fake_ssh_can_fail_with_a_given_error() {
    export FAKE_SSH_ERROR="kex_exchange_identification: read: Connection reset by peer"
    out=$(ssh u1@site.test "echo OK" 2>&1); code=$?
    assert_status 255 "$code"
    assert_eq "$FAKE_SSH_ERROR" "$out"
}

test_fake_ssh_can_be_unreachable() {
    export FAKE_SSH_UNREACHABLE=1
    out=$(ssh u1@site.test "echo OK" 2>&1); code=$?
    assert_status 255 "$code"
    assert_contains "$out" "Connection refused"
}

test_fake_curl_answers_with_the_configured_status() {
    echo 500 > "$FAKE_HTTP_STATUS_FILE"
    out=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 15 -L "https://site.test/")
    assert_eq "500" "$out"
}

test_remote_commands_find_php_and_local_ones_do_not() {
    sandbox_require_php
    assert_eq "" "$(command -v php || true)" "the local side must not find a php"
    out=$(ssh u1@site.test "php -r 'echo 7*6;'")
    assert_eq "42" "$out"
}

test_the_real_preflight_script_sees_velk_on_the_fake_server() {
    sandbox_velk_server
    sandbox_config >/dev/null
    printf 'DB_DATABASE=site\nDB_USERNAME=u1\nDB_PASSWORD=x\n' > "${SERVER}/.env"
    printf '#!/bin/bash\nexit 0\n' > "${FAKE_REMOTE_PATH}/mysql"; chmod +x "${FAKE_REMOTE_PATH}/mysql"
    out=$(bash "${SKILL_DIR}/scripts/preflight.sh" --project "$PROJECT" 2>/dev/null)
    assert_contains "$out" "TARGET=EXISTS"
}

test_the_local_side_sees_a_stock_macos() {
    assert_eq "/usr/bin/jq" "$(command -v jq)"
    assert_eq "/usr/bin/rsync" "$(command -v rsync)"
    assert_contains "$(/bin/bash --version | head -1)" "version 3.2"
}

test_scripts_stay_bash_32_compatible() {
    # /bin/bash on macOS is 3.2. A bash 4+ construct works on a dev Mac with
    # a newer bash on PATH and breaks on a client's Mac.
    hits=$(grep -rnE 'declare -A|local -A|mapfile|readarray|\$\{[A-Za-z_][A-Za-z_0-9]*(,,|\^\^)|\|&|coproc' \
        "${SKILL_DIR}/scripts" "${TESTS_DIR}/lib" "${TESTS_DIR}/bin" 2>/dev/null || true)
    assert_eq "" "$hits" "bash 4+ construct found"
}

test_no_script_uses_a_retired_helper() {
    # One style of SSH (arrays), one of output (step/ok/warn/err), one of
    # arguments (project_args): the eval-style transport, the log_* names,
    # the per-group parse_args and the helpers that put a password on a
    # command line are gone — from every script, the library and the harness's own helpers included.
    hits=$(grep -rnE 'resolve_ssh_cmd|(^|[^A-Z_])SSH_CMD|SSH_TARGET|log_(step|ok|warn|err)|remote_prefix|remote_velk_stdin|remote_db_args|local_db_dump_cmd|confirm_yes|confirm_phrase|remote_base_path|parse_args|project_config' \
        "${SKILL_DIR}/scripts" "${TESTS_DIR}/lib" "${TESTS_DIR}/bin" 2>/dev/null || true)
    assert_eq "" "$hits" "retired helper still there"
}

test_no_remote_command_hard_quotes_a_path() {
    # ssh-lib.sh's header asserts it: every value that reaches the remote
    # shell goes through shell_quote — never '${path}' inside the command.
    hits=$(grep -rnE "'\\\$\{?(remote_path|rp|remote_file|remote_dump_path)\b" "${SKILL_DIR}/scripts" 2>/dev/null || true)
    assert_eq "" "$hits" "a remote command hard-quotes an interpolated path"
}

test_every_script_the_docs_name_exists_and_runs() {
    # A doc that names a script the skill no longer ships sends Claude down a
    # path that fails — and then it improvises. And one the docs show as a
    # command must be executable: `scripts/preflight.sh --project .` on a
    # 644 file is "permission denied". Libraries (*-lib.sh, _lib.sh), the
    # scripts bash reads on the server (scripts/remote/, scripts/theme/remote/)
    # and the Perl helpers are never run by path.
    bad=""
    # (the regex admits no whitespace, so the list word-splits safely)
    for p in $(grep -ohE 'scripts/[A-Za-z0-9_./-]+\.(sh|pl)' "${SKILL_DIR}/SKILL.md" "${SKILL_DIR}/README.md" "${SKILL_DIR}"/references/*.md | sort -u); do
        [ -e "${SKILL_DIR}/${p}" ] || { bad="${bad}missing: ${p}"$'\n'; continue; }
        case "$p" in *-lib.sh|*/_lib.sh|scripts/remote/*|scripts/theme/remote/*|*.pl) continue ;; esac
        [ -x "${SKILL_DIR}/${p}" ] || bad="${bad}not executable: ${p}"$'\n'
    done
    assert_eq "" "$bad" "the docs name a script that does not exist or cannot be run"
}

test_runner_fails_a_test_that_dies_early_with_status_zero() {
    # bash 3.2: a failed `source` under errexit, with an EXIT trap set, ends
    # the shell with status 0. The runner must still count it as a failure.
    fake="${SANDBOX}/fake-suite"
    mkdir -p "${fake}/tests/lib"
    cp "${TESTS_DIR}/run.sh" "${fake}/tests/"
    cp "${TESTS_DIR}/lib/"*.sh "${fake}/tests/lib/"
    cat > "${fake}/tests/early_test.sh" <<'T'
test_sources_a_missing_file() {
    set -e
    . /no/such/file
    echo "never reached"
}
T
    out=$(bash "${fake}/tests/run.sh" 2>&1); code=$?
    assert_status 1 "$code" "the runner must fail"
    assert_contains "$out" "0 passed, 1 failed"
}

test_runner_fails_a_test_file_that_does_not_parse() {
    # A syntax error in a test file made `source` stop there: the tests after
    # it vanished from the run and the count shrank, with nothing failing.
    # (bash 3.2 cannot parse a bare `pat)` case inside $( ) — a real one.)
    fake="${SANDBOX}/fake-suite"
    mkdir -p "${fake}/tests/lib"
    cp "${TESTS_DIR}/run.sh" "${fake}/tests/"
    cp "${TESTS_DIR}/lib/"*.sh "${fake}/tests/lib/"
    cat > "${fake}/tests/broken_test.sh" <<'T'
test_before_the_error() { :; }
x=$(case a in a) echo hi ;; esac)
test_after_the_error() { :; }
T
    out=$(bash "${fake}/tests/run.sh" 2>&1); code=$?
    assert_status 1 "$code" "the runner must fail"
    assert_contains "$out" "does not parse"
    assert_contains "$out" "0 passed, 1 failed"
}
