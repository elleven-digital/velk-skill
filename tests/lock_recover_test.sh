# tests/lock_recover_test.sh — the publish lock, and finishing or undoing a
# publish that died halfway.

ME="Tester@$(hostname -s)"
LOCK=""

lib() {
    sandbox_velk_server
    sandbox_theme "${SERVER}/theme"
    CONFIG_PATH=$(sandbox_config)
    . "${SKILL_DIR}/scripts/theme/_lib.sh"
    set +e
    build_ssh_args
    load_theme_filters
    LOCK="${SERVER}/.velk-theme.lock"
}
recover() { bash "${SKILL_DIR}/scripts/theme/recover.sh" --project "$PROJECT" "$@" 2>/dev/null; }
lock_held_by() {   # lock_held_by <owner> <pid> — a fresh lock held by that process of this Mac
    mkdir -p "$LOCK"
    echo "$2" > "${LOCK}/pid"
    process_start "$2" > "${LOCK}/pidstart"
    date -u +%s > "${LOCK}/since"
    echo "$1" > "${LOCK}/owner"
}
record_live_as() {   # record_live_as <version> — a server state describing what is live now
    write_server_state "$1" "Someone" || fail "could not write the state"
}

test_the_lock_holds_who_and_since_by_the_server_clock() {
    lib
    lock_acquire || fail "should get a free lock"
    assert_eq "$ME" "$(cat "${LOCK}/owner")"
    [[ "$(cat "${LOCK}/since")" =~ ^[0-9]+$ ]] || fail "since must be epoch seconds"
}

test_a_fresh_lock_of_someone_else_is_respected() {
    lib
    lock_as "Maria@other-mac" 60
    lock_acquire && fail "must not take Maria's lock"
    assert_eq "FOREIGN" "$LOCK_STATE"
    assert_eq "Maria@other-mac" "$(cat "${LOCK}/owner")"
}

test_my_own_crashed_lock_is_taken_back() {
    lib
    lock_as "$ME" 30
    lock_acquire || fail "my own lock must be taken back"
    assert_eq "$ME" "$(cat "${LOCK}/owner")"
}

test_a_stale_lock_is_only_taken_with_permission() {
    lib
    lock_as "Maria@other-mac" 1000
    lock_acquire && fail "a stale lock needs the user's permission"
    assert_eq "STALE" "$LOCK_STATE"
    lock_acquire --take-over-stale || fail "with permission it is taken over"
    assert_eq "$ME" "$(cat "${LOCK}/owner")"
}

test_a_lock_without_a_time_is_fresh_until_its_folder_is_old() {
    lib
    mkdir -p "$LOCK"                       # died between mkdir and writing owner/since
    lock_state; assert_eq "FOREIGN" "$LOCK_STATE"
    touch -t "$(date -v-20M +%Y%m%d%H%M)" "$LOCK"
    lock_state; assert_eq "STALE" "$LOCK_STATE"
}

test_release_removes_my_lock_and_never_someone_elses() {
    lib
    lock_acquire || fail "should get a free lock"
    lock_release
    assert_no_dir "$LOCK"
    lock_as "Maria@other-mac" 60
    LOCK_HELD=1
    lock_release
    assert_dir "$LOCK"
}

test_a_takeover_only_replaces_the_lock_it_expected() {
    lib
    lock_as "Maria@other-mac" 1000
    since=$(cat "${LOCK}/since")
    # someone else took it over first: owner/since no longer match
    start=$(process_start $$)
    remote_script "${SKILL_DIR}/scripts/theme/remote/lock.sh" "$SERVER" takeover "$ME" "$$" "$start" "Maria@other-mac" "12345"
    assert_status 1 $?
    assert_eq "Maria@other-mac" "$(cat "${LOCK}/owner")"
    assert_no_dir "${LOCK}/takeover"
    remote_script "${SKILL_DIR}/scripts/theme/remote/lock.sh" "$SERVER" takeover "$ME" "$$" "$start" "Maria@other-mac" "$since"
    assert_status 0 $?
    assert_eq "$ME" "$(cat "${LOCK}/owner")"
}

test_another_live_session_of_mine_keeps_its_lock() {
    # Same person, same Mac, two sessions: the lock of the one still running
    # is not "a crash of ours" — the other waits like anyone else.
    lib
    sleep 60 & other=$!
    lock_held_by "$ME" "$other"
    lock_acquire && fail "must not take a lock whose process is alive"
    assert_eq "FOREIGN" "$LOCK_STATE"
    assert_eq "$other" "$(cat "${LOCK}/pid")"
    kill "$other"; wait "$other" 2>/dev/null
    lock_acquire || fail "once that process is gone, the lock is ours to take back"
    assert_eq "$$" "$(cat "${LOCK}/pid")"
}

test_a_live_session_of_mine_is_recognised_from_another_language_and_time_zone() {
    # ps writes a start time in each session's language and time zone; a
    # desktop-app session and a Terminal session must still agree on it.
    lib
    sleep 60 & other=$!
    lock_held_by "$ME" "$other"
    LANG=pt_BR.UTF-8 LC_ALL=pt_BR.UTF-8 TZ=Asia/Tokyo lock_state
    kill "$other"; wait "$other" 2>/dev/null
    assert_eq "FOREIGN" "$LOCK_STATE"
}

test_release_waits_for_a_takeover_in_progress() {
    lib
    lock_acquire || fail "should get a free lock"
    mkdir "${LOCK}/takeover"                             # someone is taking over right now
    remote_lock release "$ME" "$$"
    assert_status 1 $?
    assert_dir "$LOCK"
    rmdir "${LOCK}/takeover"
    lock_release
    assert_no_dir "$LOCK"
}

test_only_the_process_that_took_the_lock_releases_it() {
    lib
    lock_acquire || fail "should get a free lock"
    remote_lock release "$ME" 99999                    # another session of the same person
    assert_status 1 $?
    assert_dir "$LOCK"
    lock_release
    assert_no_dir "$LOCK"
}

test_a_takeover_that_died_inside_the_mutex_does_not_jam_the_lock() {
    lib
    lock_as "Maria@other-mac" 1000
    mkdir "${LOCK}/takeover"                            # a takeover in progress, right now
    lock_acquire --take-over-stale && fail "a live takeover holds the mutex"
    assert_eq "Maria@other-mac" "$(cat "${LOCK}/owner")"
    touch -t "$(date -v-5M +%Y%m%d%H%M)" "${LOCK}/takeover"   # ...or one that died long ago
    lock_acquire --take-over-stale || fail "a dead mutex must not jam the lock forever"
    assert_eq "$ME" "$(cat "${LOCK}/owner")"
    assert_no_dir "${LOCK}/takeover"
}

test_staleness_is_judged_by_the_server_clock() {
    # The server's clock runs a day ahead of the Mac's. By the server this
    # lock is 1000 s old — stale; by the Mac it would be in the future.
    lib
    ahead=$(( $(date -u +%s) + 86400 ))
    printf '#!/bin/bash\nif [ "$*" = "-u +%%s" ]; then echo %s; else exec /bin/date "$@"; fi\n' "$ahead" \
        > "${FAKE_REMOTE_PATH}/date"
    chmod +x "${FAKE_REMOTE_PATH}/date"
    mkdir -p "$LOCK"
    echo $(( ahead - 1000 )) > "${LOCK}/since"
    echo "Maria@other-mac" > "${LOCK}/owner"
    lock_state
    assert_eq "STALE" "$LOCK_STATE"
    assert_eq "1000" "$LOCK_AGE"
}

test_recover_on_a_clean_server_does_nothing() {
    lib
    out=$(recover); code=$?
    assert_status 0 "$code"
    assert_eq "STATUS=CLEAN" "$out"
}

test_recover_leaves_a_publish_in_progress_alone() {
    lib
    lock_as "Maria@other-mac" 60
    mkdir -p "${SERVER}/.velk-theme-staging" "${SERVER}/.velk-theme-previous"
    out=$(recover); code=$?
    assert_status 5 "$code"
    assert_contains "$out" "STATUS=BUSY"
    assert_contains "$out" "OWNER=Maria@other-mac"
    assert_dir "${SERVER}/.velk-theme-staging"; assert_dir "${SERVER}/.velk-theme-previous"
}

test_recover_asks_before_taking_a_stale_lock() {
    lib
    lock_as "Maria@other-mac" 1000
    out=$(recover); code=$?
    assert_status 5 "$code"
    assert_contains "$out" "STATUS=STALE_LOCK"
    out=$(recover --take-over-stale); code=$?
    assert_status 0 "$code"
    assert_no_dir "$LOCK"
}

test_recover_leaves_another_live_session_of_mine_alone() {
    lib
    sleep 60 & other=$!
    lock_held_by "$ME" "$other"
    mkdir -p "${SERVER}/.velk-theme-staging"
    out=$(recover); code=$?
    kill "$other"; wait "$other" 2>/dev/null
    assert_status 5 "$code"
    assert_contains "$out" "STATUS=BUSY"
    assert_contains "$out" "PID=${other}"
    assert_dir "${SERVER}/.velk-theme-staging"
}

test_recover_removes_a_staging_copy_left_behind() {
    lib
    lock_as "$ME" 30
    mkdir -p "${SERVER}/.velk-theme-staging"
    out=$(recover)
    assert_contains "$out" "STATUS=RECOVERED"
    assert_contains "$out" "ACTION=removed-staging"
    assert_no_dir "${SERVER}/.velk-theme-staging"
    assert_no_dir "$LOCK"
}

test_recover_puts_the_previous_theme_back_when_theme_is_missing() {
    lib
    lock_as "$ME" 30
    mv "${SERVER}/theme" "${SERVER}/.velk-theme-previous"
    out=$(recover)
    assert_contains "$out" "ACTION=restored-previous"
    assert_file "${SERVER}/theme/site.json"
    assert_no_dir "${SERVER}/.velk-theme-previous"
}

test_recover_finishes_a_publish_that_died_after_the_swap() {
    lib
    record_live_as 3
    cp -R "${SERVER}/theme" "${SERVER}/.velk-theme-previous"
    echo 'body { color: red; }' > "${SERVER}/theme/style.css"      # the new theme went live
    lock_as "Maria@other-mac" 1000
    out=$(recover --take-over-stale); code=$?
    assert_status 0 "$code"
    assert_contains "$out" "ACTION=finished-publish"
    assert_eq "4" "$(jq -r .version "${SERVER}/.velk-theme.json")"
    assert_eq "Maria" "$(jq -r .published_by "${SERVER}/.velk-theme.json")"
    assert_eq "red" "$(grep -o red "${SERVER}/theme/style.css")"
    assert_no_dir "${SERVER}/.velk-theme-previous"
}

test_recover_swaps_back_a_live_theme_that_fails_validation() {
    lib
    record_live_as 3
    cp -R "${SERVER}/theme" "${SERVER}/.velk-theme-previous"
    echo '{ broken' > "${SERVER}/theme/site.json"
    lock_as "$ME" 30
    out=$(recover)
    assert_contains "$out" "ACTION=swapped-back"
    assert_eq "3" "$(jq -r .version "${SERVER}/.velk-theme.json")"
    jq -e . "${SERVER}/theme/site.json" >/dev/null || fail "the previous site.json must be back"
    assert_no_dir "${SERVER}/.velk-theme-previous"; assert_no_dir "${SERVER}/.velk-theme-failed"
}

test_recover_does_not_record_a_version_twice() {
    lib
    cp -R "${SERVER}/theme" "${SERVER}/.velk-theme-previous"
    echo 'body { color: red; }' > "${SERVER}/theme/style.css"
    record_live_as 4                         # died after recording, before cleaning up
    lock_as "$ME" 30
    out=$(recover)
    assert_contains "$out" "ACTION=already-recorded"
    assert_eq "4" "$(jq -r .version "${SERVER}/.velk-theme.json")"
    assert_no_dir "${SERVER}/.velk-theme-previous"
}

test_recover_clears_a_swap_back_that_died_halfway() {
    lib
    lock_as "$ME" 30
    mkdir -p "${SERVER}/.velk-theme-failed"            # died before its last rm
    out=$(recover)
    assert_contains "$out" "ACTION=removed-failed"
    assert_no_dir "${SERVER}/.velk-theme-failed"
    assert_file "${SERVER}/theme/site.json"

    lock_as "$ME" 30                                    # died between its two renames
    mv "${SERVER}/theme" "${SERVER}/.velk-theme-failed"
    cp -R "${SERVER}/.velk-theme-failed" "${SERVER}/.velk-theme-previous"
    out=$(recover)
    assert_contains "$out" "ACTION=restored-previous"
    assert_contains "$out" "ACTION=removed-failed"
    assert_file "${SERVER}/theme/site.json"
    assert_no_dir "${SERVER}/.velk-theme-failed"
}

test_recover_never_guesses_a_version_over_an_unreadable_record() {
    lib
    cp -R "${SERVER}/theme" "${SERVER}/.velk-theme-previous"
    echo 'body { color: red; }' > "${SERVER}/theme/style.css"
    echo 'not json' > "${SERVER}/.velk-theme.json"
    lock_as "$ME" 30
    out=$(recover); code=$?
    assert_status 0 "$code"
    assert_contains "$out" "ACTION=finished-publish-unrecorded"
    assert_not_contains "$out" "VERSION="
    assert_eq "not json" "$(cat "${SERVER}/.velk-theme.json")" "the record is left for the next publish"
    assert_no_dir "${SERVER}/.velk-theme-previous"
}

test_a_broken_manifest_never_empties_the_record() {
    # On a real server a PHP warning can land on stdout in front of the
    # manifest's JSON; recording from it must fail, not write an empty record.
    lib
    record_live_as 3
    remote_theme_manifest() { echo "PHP Warning: hash_file(style.css): Permission denied"; echo '{"files":{}}'; }
    write_server_state 4 "Someone"; code=$?
    [ "$code" -ne 0 ] || fail "recording from a broken manifest must fail"
    assert_eq "3" "$(jq -r .version "${SERVER}/.velk-theme.json")"
}

test_an_unreadable_theme_file_fails_the_manifest() {
    # The Mac's openrsync refuses to list an unreadable file; the server's GNU
    # rsync lists it. A fake rsync that lists it makes PHP's read be what fails.
    lib
    printf '#!/bin/bash\nprintf "style.css\\n"\n' > "${FAKE_REMOTE_PATH}/rsync"
    chmod +x "${FAKE_REMOTE_PATH}/rsync"
    chmod 000 "${SERVER}/theme/style.css"
    out=$(remote_theme_manifest 2>"${SANDBOX}/manifest.err"); code=$?
    chmod 644 "${SERVER}/theme/style.css"
    [ "$code" -ne 0 ] || fail "an unreadable file must fail the manifest"
    assert_contains "$(cat "${SANDBOX}/manifest.err")" "cannot read theme file: style.css"
    assert_not_contains "$out" "sha256:"
}
