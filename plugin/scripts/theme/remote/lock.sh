#!/bin/bash
# Runs ON THE SERVER, fed by remote_script:
#   lock.sh <install-root> state
#   lock.sh <install-root> acquire  <me> <pid> <pidstart>
#   lock.sh <install-root> release  <me> <pid>
#   lock.sh <install-root> takeover <me> <pid> <pidstart> <expected-owner> <expected-since>
#
# The publish lock is the directory .velk-theme.lock/ — mkdir is atomic —
# holding "owner" (identity@machine), "pid" and "pidstart" (the process that
# holds it, on that machine) and "since" (epoch seconds). Every time comes
# from this server's clock; the Mac's never decides anything. "owner" is
# written last, so whoever reads an owner also finds its pid.
set -u
cd "$1" || exit 2
lock=.velk-theme.lock
mutex="$lock/takeover"

# Nothing holds the mutex for more than an instant, so one older than a
# minute was left by a process that died inside it — without this, the lock
# could never be taken over again.
clear_dead_mutex() { find "$mutex" -maxdepth 0 -mmin +1 -exec rmdir {} \; 2>/dev/null || true; }

write_holder() {   # <me> <pid> <pidstart>
    printf '%s\n' "$2" > "$lock/pid"
    printf '%s\n' "$3" > "$lock/pidstart"
    date -u +%s > "$lock/since"
    printf '%s\n' "$1" > "$lock/owner"
}

case "$2" in
    state)
        if [ ! -d "$lock" ]; then echo "FREE"; exit 0; fi
        echo "LOCKED"
        echo "owner=$(cat "$lock/owner" 2>/dev/null)"
        echo "since=$(cat "$lock/since" 2>/dev/null)"
        echo "pid=$(cat "$lock/pid" 2>/dev/null)"
        echo "pidstart=$(cat "$lock/pidstart" 2>/dev/null)"
        echo "now=$(date -u +%s)"
        # For a lock that died before "since" was written: is the folder old?
        if [ -n "$(find "$lock" -maxdepth 0 -mmin +15 2>/dev/null)" ]; then echo "old=yes"; fi
        ;;
    acquire)
        mkdir "$lock" 2>/dev/null || exit 1
        write_holder "$3" "$4" "$5"
        ;;
    release)
        # Only the process that took the lock lets it go — not another session
        # of the same person — and under the mutex, so a takeover can't slip in
        # between the check and the removal.
        [ -d "$lock" ] || exit 0
        clear_dead_mutex
        mkdir "$mutex" 2>/dev/null || exit 1
        if [ "$(cat "$lock/owner" 2>/dev/null)" != "$3" ] || [ "$(cat "$lock/pid" 2>/dev/null)" != "$4" ]; then
            rmdir "$mutex"
            exit 1
        fi
        mv "$lock" "$lock.gone.$$" && rm -rf "$lock.gone.$$"
        ;;
    takeover)
        # Replaces a stale lock — or one whose process is gone — without ever
        # removing it, so nobody slips in between. Creating the mutex is the
        # atomic step, and owner/since are re-checked under it: of two
        # takeovers racing for the same lock, one wins.
        clear_dead_mutex
        mkdir "$mutex" 2>/dev/null || exit 1
        if [ "$(cat "$lock/owner" 2>/dev/null)" != "$6" ] || [ "$(cat "$lock/since" 2>/dev/null)" != "$7" ]; then
            rmdir "$mutex"
            exit 1
        fi
        write_holder "$3" "$4" "$5"
        rmdir "$mutex"
        ;;
    *) exit 2 ;;
esac
