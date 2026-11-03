# tests/remote_velk_test.sh — velk.sh runs bin/velk on the server: any verb
# with its arguments intact, this side's stdin only when asked, a recovery
# before a write, and an answer that always parses.

server() { sandbox_velk_server; CFG=$(sandbox_config); }
velk() { bash "${SKILL_DIR}/scripts/content/velk.sh" --project "$PROJECT" "$@"; }
calls() { cat "${SERVER}/.stub-calls" 2>/dev/null; }

test_any_verb_reaches_the_server_intact_and_content_commands_answer_in_json() {
    server
    velk -- item:schema post >/dev/null 2>&1
    assert_eq "item:schema post --format=json" "$(calls)"
    velk -- item:list post --format=json --status=draft >/dev/null 2>&1
    assert_eq "item:list post --format=json --status=draft" "$(tail -1 <<< "$(calls)")" "--format=json is not added twice"
    velk -- page:sync >/dev/null 2>&1
    assert_eq "page:sync" "$(tail -1 <<< "$(calls)")" "only the content commands get --format=json"
}

test_arguments_reach_bin_velk_exactly_as_given() {
    server
    velk -- item:list 'a b' "it's" '$HOME' '`id`' 'x"y' '' '--json={"t":"a b"}' >/dev/null 2>&1
    assert_status 0 $?
    # bin/velk records its argv as JSON: `$*` could not tell "a b" from two
    # arguments, nor an empty one from none.
    read -r expected <<'JSON'
["item:list","a b","it's","$HOME","`id`","x\"y","","--json={\"t\":\"a b\"}","--format=json"]
JSON
    assert_eq "$expected" "$(cat "${SERVER}/.stub-argv")"
}

test_bin_velks_own_answer_and_exit_code_pass_through() {
    server
    echo 3 > "${SERVER}/.stub-exit-item-get"
    out=$(velk -- item:get post nope 2>/dev/null); code=$?
    assert_status 3 "$code"
    assert_eq "forced failure of item:get" "$out"
}

test_the_json_reaches_bin_velk_with_json_stdin() {
    server
    echo '{"title":"x"}' | velk -- item:create post --json-stdin >/dev/null 2>&1
    assert_status 0 $?
    assert_eq '{"title":"x"}' "$(cat "${SERVER}/.stub-stdin")"
    assert_eq "item:create post --json-stdin --format=json" "$(calls)"
}

test_a_read_leaves_this_sides_stdin_alone() {
    server
    rest=$(printf 'a\nb\n' | { velk -- item:list post >/dev/null 2>&1; cat; })
    assert_eq $'a\nb' "$rest" "without --json-stdin the server gets no stdin, so none is eaten"
}

test_a_write_finishes_an_interrupted_publish_first_and_a_read_does_not() {
    server
    lock_as "Tester@$(hostname -s)" 30
    mkdir -p "${SERVER}/.velk-theme-staging"
    velk -- item:list post >/dev/null 2>&1
    assert_dir "${SERVER}/.velk-theme-staging" "a read recovers nothing"
    echo '{"title":"x"}' | velk -- item:create post --json-stdin --dry-run >/dev/null 2>&1
    assert_dir "${SERVER}/.velk-theme-staging" "nor does a dry run"
    echo '{"title":"y"}' | velk -- item:create post --json-stdin >/dev/null 2>&1
    assert_status 0 $?
    assert_no_dir "${SERVER}/.velk-theme-staging"
    assert_eq $'{"title":"x"}\n{"title":"y"}' "$(cat "${SERVER}/.stub-stdin")" "each JSON reaches bin/velk, never the recovery"
}

test_when_ssh_fails_the_answer_is_still_json() {
    server
    export FAKE_SSH_UNREACHABLE=1
    out=$(velk -- item:list post 2>/dev/null); code=$?
    assert_status 1 "$code"
    assert_eq "false" "$(jq -r .ok <<< "$out")"
    assert_contains "$(jq -r .error <<< "$out")" "ssh could not run bin/velk"
}

test_without_the_separator_nothing_runs() {
    server
    out=$(velk item:list post 2>&1); code=$?
    assert_status 2 "$code"
    assert_contains "$out" "Usage: velk.sh"
    assert_eq "" "$(calls)"
}
