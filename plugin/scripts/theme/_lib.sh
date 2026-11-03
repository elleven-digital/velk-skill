#!/usr/bin/env bash
# scripts/theme/_lib.sh — shared by the versioned-theme scripts (download,
# workspace, recover, publish). Sourced, never run.
#
# One rule runs through all of it: what counts as "the theme" is decided by
# rsync, with the filters below — when sending, downloading, and hashing on
# either side. Nothing re-implements them, so the file lists can't drift.

THEME_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../ssh-lib.sh
source "${THEME_LIB_DIR}/../ssh-lib.sh"
MANIFEST_PL="${THEME_LIB_DIR}/manifest.pl"

# theme_filter_args — the rsync filters, one per line: the fixed list below,
# then the config's rsync.theme_extra_excludes. functions.php is included
# BEFORE root *.php is excluded because rsync stops at the first rule that
# matches.
theme_filter_args() {
    printf '%s\n' \
        '--exclude=install/seed.php' \
        '--exclude=storage/' \
        '--exclude=*.bak' \
        '--exclude=.DS_Store' \
        '--exclude=*.swp' \
        '--include=/functions.php' \
        '--exclude=/*.php'
    jq -r '.rsync.theme_extra_excludes[]? // empty | "--exclude=" + .' "$CONFIG_PATH"
}

# load_theme_filters — fills the FILTERS array every rsync call here uses.
load_theme_filters() {
    local f
    FILTERS=()
    while IFS= read -r f; do FILTERS+=("$f"); done < <(theme_filter_args)
}

# theme_list <dir> — the theme's paths (directories end in "/"), as rsync
# would send them to an empty destination.
theme_list() {
    local dir="${1%/}" empty status=0
    empty=$(mktemp -d)
    rsync -an -8 --out-format='%n' "${FILTERS[@]}" "${dir}/" "${empty}/" || status=$?
    rmdir "$empty"
    return "$status"
}

# local_theme_manifest <dir> — manifest of a theme folder on this Mac.
local_theme_manifest() {
    theme_list "$1" | perl "$MANIFEST_PL" hash "$1"
}

# remote_theme_manifest — manifest of the theme live on the server.
remote_theme_manifest() {
    remote_script "${THEME_LIB_DIR}/remote/manifest.sh" \
        "$(remote_path)/theme" "$(resolve_php_bin)" "${FILTERS[@]}"
}

# theme_rsync <args...> — every theme copy goes through here. -c compares
# content, not size+mtime: a file edited within the same second at the same
# size would otherwise be skipped, and a stale copy is exactly the kind of
# silent error a merge can't recover from.
theme_rsync() {
    rsync -a -c "${FILTERS[@]}" "$@"
}

# remote_state — the server's .velk-theme.json as JSON; NONE when there is
# none; UNREADABLE when it exists but isn't a valid state. Never guesses.
remote_state() {
    local raw
    raw=$("${ssh_args[@]}" "f=$(shell_quote "$(remote_path)/.velk-theme.json"); if [ -e \"\$f\" ]; then cat \"\$f\"; else echo NONE; fi") \
        || return 1
    if [[ "$raw" == "NONE" ]]; then echo NONE; return 0; fi
    if jq -e '(.version | type == "number") and (.files | type == "object")' <<< "$raw" >/dev/null 2>&1; then
        printf '%s\n' "$raw"
    else
        echo UNREADABLE
    fi
}

# state_version <remote_state output> — the version; 0 for NONE; empty for
# UNREADABLE.
state_version() {
    case "$1" in
        NONE) echo 0 ;;
        UNREADABLE) echo "" ;;
        *) jq -r '.version' <<< "$1" ;;
    esac
}

# record_theme_base <project> <version> [<from>] — <from> (default
# <project>/theme) becomes the starting point of the next publish: an untouched
# copy in .deploy/theme-base/ and, in .deploy/theme-base.json, its manifest
# and the version it came from. If the copy fails, the old record stays and
# it returns non-zero — also when called with `||`, where bash would not stop.
record_theme_base() {
    local project="${1%/}" version="$2" from="${3:-${1%/}/theme}" base manifest
    base="${project}/.deploy/theme-base"
    mkdir -p "$base" || return 1
    theme_rsync --delete "${from%/}/" "${base}/" || return 1
    manifest=$(local_theme_manifest "$base") || return 1
    jq -n --argjson v "$version" --argjson m "$manifest" '{version: $v, files: $m.files}' > "${base}.json.tmp" \
        && mv "${base}.json.tmp" "${base}.json"
}

# ── publish lock ─────────────────────────────────────────────────────────

LOCK_STALE_AFTER=900    # seconds, by the server's clock
LOCK_HELD=0

# publisher_id — identity@machine. The same person on two computers counts
# as two publishers.
publisher_id() { printf '%s@%s' "$(cfg_get '.identity' "$(id -un)")" "$(hostname -s)"; }

# process_start <pid> — when that process started, on this Mac. With the pid
# it names one process for good: a reused pid has another start time. The
# format is pinned (C locale, UTC): ps writes it in each session's language
# and time zone, and a desktop-app session and a Terminal one must agree.
process_start() { LC_ALL=C TZ=UTC ps -o lstart= -p "$1" 2>/dev/null | sed 's/^ *//; s/ *$//'; }

remote_lock() { remote_script "${THEME_LIB_DIR}/remote/lock.sh" "$(remote_path)" "$@"; }

# lock_state — sets LOCK_STATE (FREE | OWN | STALE | FOREIGN), LOCK_OWNER,
# LOCK_SINCE, LOCK_AGE (seconds; empty when unknown) and LOCK_PID (the
# holding process, on the machine named in LOCK_OWNER). A lock of ours whose
# process is still running — another session of the same person on this
# Mac — is FOREIGN, and stays so however old it gets (it isn't a crash):
# only a lock whose process is gone is OWN, a crash of ours to take back.
lock_state() {
    local out k v now="" old="" pidstart=""
    LOCK_STATE="" LOCK_OWNER="" LOCK_SINCE="" LOCK_AGE="" LOCK_PID=""
    out=$(remote_lock state) || return 1
    if [[ "$out" == FREE ]]; then LOCK_STATE=FREE; return 0; fi
    while IFS='=' read -r k v; do
        case "$k" in
            owner)    LOCK_OWNER="$v" ;;
            since)    LOCK_SINCE="$v" ;;
            pid)      LOCK_PID="$v" ;;
            pidstart) pidstart="$v" ;;
            now)      now="$v" ;;
            old)      old="$v" ;;
        esac
    done <<< "$out"
    if [[ "$LOCK_SINCE" =~ ^[0-9]+$ && "$now" =~ ^[0-9]+$ ]]; then LOCK_AGE=$(( now - LOCK_SINCE )); fi
    if [[ "$LOCK_OWNER" == "$(publisher_id)" ]]; then
        if [[ -n "$LOCK_PID" && -n "$pidstart" && "$(process_start "$LOCK_PID")" == "$pidstart" ]]; then
            LOCK_STATE=FOREIGN
        else
            LOCK_STATE=OWN
        fi
    elif [[ -n "$LOCK_AGE" ]] && (( LOCK_AGE >= LOCK_STALE_AFTER )); then LOCK_STATE=STALE
    elif [[ -z "$LOCK_SINCE" && "$old" == yes ]]; then LOCK_STATE=STALE
    else LOCK_STATE=FOREIGN
    fi
}

# lock_acquire [--take-over-stale] — 0 once the lock is ours, held by this
# process ($$). A lock of ours left by a dead process is taken back at once;
# a stale one only with the flag, after the user agreed; a fresh one of
# someone else — another live session of ours included — never. On 1,
# LOCK_STATE and LOCK_OWNER/SINCE/AGE/PID say who holds it. When the lock
# can't even be read, the whole script stops (die).
lock_acquire() {
    local take_stale="${1:-}" me start attempt
    me=$(publisher_id)
    start=$(process_start $$)
    for attempt in 1 2 3; do
        if remote_lock acquire "$me" "$$" "$start"; then LOCK_HELD=1; LOCK_ME="$me"; return 0; fi
        lock_state || die "Could not read the publish lock on the server."
        case "$LOCK_STATE" in
            FREE)    continue ;;                   # released between our two calls
            FOREIGN) return 1 ;;
            STALE)   [[ "$take_stale" == --take-over-stale ]] || return 1 ;;
        esac
        if remote_lock takeover "$me" "$$" "$start" "$LOCK_OWNER" "$LOCK_SINCE"; then
            LOCK_HELD=1; LOCK_ME="$me"; return 0
        fi
    done
    return 1
}

# lock_release — lets go of the lock this process took, with the identity it
# took it under (the machine's name can change mid-publish).
lock_release() {
    if [[ "$LOCK_HELD" == 1 ]]; then
        remote_lock release "$LOCK_ME" "$$" || true
        LOCK_HELD=0
    fi
}

# lock_report <STATUS> — the lock holder, for Claude to put in words. PID is
# the holding process on the machine named in OWNER — when that is this Mac,
# the process to look at if it seems stuck.
lock_report() {
    echo "STATUS=$1"
    echo "OWNER=${LOCK_OWNER}"
    echo "SINCE=${LOCK_SINCE}"
    echo "AGE=${LOCK_AGE}"
    echo "PID=${LOCK_PID}"
}

# ── the live site ────────────────────────────────────────────────────────

# server_leftovers — which of theme/ and the publish folders exist, one per
# line.
server_leftovers() {
    remote_in_root 'for d in theme .velk-theme-previous .velk-theme-staging .velk-theme-failed .velk-theme-check; do if [ -e "$d" ]; then echo "$d"; fi; done'
}

site_home_url() {
    printf '%s/\n' "$(site_base_url)"
}

# validate_live [accepted] [home-before] — decides whether the theme now live
# stays: schema:validate and page:sync by EXIT CODE (grepping their output let
# "php: command not found" pass), then the home page not answering a server
# error (5xx) or nothing at all (000). Another code — 401 behind a password,
# 403 from a firewall — only warns, unless the home answered 2xx before this
# publish (home-before, from live_baseline): then it fails too. A failure the
# site already had, which the person accepted (live_baseline,
# --accept-live-failure — "schema:validate", "home"), only warns; any other
# swaps back. Sets LIVE_FAILURE, and LIVE_WARNINGS (one per line).
validate_live() {
    local accepted=" ${1:-} " before="${2:-}" php code
    php=$(shell_quote "$(resolve_php_bin)")
    LIVE_FAILURE="" LIVE_WARNINGS=""
    if ! remote_in_root "${php} bin/velk schema:validate" >&2; then
        [[ "$accepted" == *" schema:validate "* ]] || { LIVE_FAILURE="schema:validate"; return 1; }
        LIVE_WARNINGS="${LIVE_WARNINGS}STILL_FAILING schema:validate"$'\n'
    fi
    if ! remote_in_root "${php} bin/velk page:sync" >&2; then LIVE_FAILURE="page:sync"; return 1; fi
    code=$(home_status)
    case "$code" in
        200) ;;
        2??) ;;
        5??|000)
            [[ "$accepted" == *" home "* ]] || { LIVE_FAILURE="home page answered ${code}"; return 1; }
            LIVE_WARNINGS="${LIVE_WARNINGS}STILL_FAILING home page answered ${code}"$'\n' ;;
        *)
            [[ "$before" != 2?? ]] || { LIVE_FAILURE="home page answered ${code}, ${before} before"; return 1; }
            LIVE_WARNINGS="${LIVE_WARNINGS}HOME_PAGE_ANSWERED_${code}"$'\n' ;;
    esac
}

# home_status — the home page's HTTP status as this machine sees it, asked
# past any page cache (a query it has never seen, and no-cache); 000 when it
# can't be reached (curl prints 000 itself, and then fails).
home_status() {
    local code
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 -L -H 'Cache-Control: no-cache' \
        "$(site_home_url)?velk-check=$(date +%s)" || true)
    echo "${code:-000}"
}

# live_baseline — before a publish: how is the site doing now? Prints
# HOME=<code>, then FAILURE=schema:validate (with DETAIL= lines: what it said)
# and/or FAILURE=home page answered <code> for what already fails. (No
# page:sync: it writes.)
live_baseline() {
    local php code said
    php=$(shell_quote "$(resolve_php_bin)")
    code=$(home_status)
    echo "HOME=${code}"
    if ! said=$(remote_in_root "${php} bin/velk schema:validate" 2>&1); then
        echo "FAILURE=schema:validate"
        printf '%s\n' "$said" | grep -v '^[[:space:]]*$' | head -10 | sed 's/^/DETAIL=/'
    fi
    case "$code" in 5??|000) echo "FAILURE=home page answered ${code}" ;; esac
}

# swap_back — the theme that was live before goes back live, and page:sync
# runs again so page titles follow it (the rejected theme's sync already ran).
swap_back() {
    remote_in_root 'rm -rf .velk-theme-failed && mv theme .velk-theme-failed && mv .velk-theme-previous theme && rm -rf .velk-theme-failed' \
        || return 1
    remote_in_root "$(shell_quote "$(resolve_php_bin)") bin/velk page:sync" >&2 \
        || warn "Swapped back, but page:sync failed — page titles may still be the rejected theme's."
}

# write_server_state <version> <published_by> — records what is live NOW as
# that version. The record is built and checked here first, then written
# under a temporary name and renamed only if every byte arrived: the server's
# one permanent file is never replaced by an empty or cut-off one.
write_server_state() {
    local live at doc bytes
    live=$(remote_theme_manifest) || return 1
    at=$("${ssh_args[@]}" "date -u +%Y-%m-%dT%H:%M:%SZ") || return 1
    doc=$(jq -n --argjson v "$1" --arg at "$at" --arg by "$2" --argjson m "$live" \
        '{format: 1, version: $v, published_at: $at, published_by: $by, files: $m.files}') || return 1
    bytes=$(printf '%s\n' "$doc" | wc -c | tr -d ' ')
    printf '%s\n' "$doc" \
        | remote_in_root "cat > .velk-theme.json.tmp && [ \"\$(wc -c < .velk-theme.json.tmp | tr -d ' ')\" = ${bytes} ] && mv .velk-theme.json.tmp .velk-theme.json"
}

# crash_point <name> — test hook. With VELK_TEST_CRASH_AT=<name> the script
# dies right here as if the machine lost power (SIGKILL: no trap runs, the
# lock and every leftover stay). Inert otherwise.
crash_point() {
    if [[ "${VELK_TEST_CRASH_AT:-}" == "$1" ]]; then kill -9 $$; fi
}
