#!/usr/bin/env bash
# recover.sh --project <dir> [--config <ssh.json>] [--take-over-stale]
#
# Finishes or undoes a publish that died halfway. Everything that touches a
# site — publish, download, content edits — runs this first.
#
# It acts only when the lock is free, ours (same identity AND machine), or
# stale (15 minutes by the server's clock) — and a stale one only with
# --take-over-stale, once the user agreed. A fresh lock of someone else is a
# publish in progress: its staging and previous copies aren't leftovers, and
# nothing of it is touched.
#
#   theme missing, previous there      → the previous theme goes back
#   theme and previous both there      → the swap happened: already recorded →
#                                        clean up; else validate what's live
#                                        by the publish's own rules
#                                        (.velk-theme-check):
#                                        passes → record it (finishes the
#                                        publish) — unless the record is
#                                        unreadable: no version is guessed,
#                                        the next publish rewrites it;
#                                        fails → swap back
#   staging / failed there             → removed
#
# stdout: STATUS=CLEAN | STATUS=RECOVERED + ACTION=… lines (+ VERSION= when a
#         version was recorded, + WARN= lines when a finished publish went
#         live with warnings) | STATUS=BUSY or STATUS=STALE_LOCK + OWNER/SINCE/AGE/PID
# Exit:   0 clean or recovered · 5 someone else's lock · 2 bad arguments ·
#         any other code: an error (the failing command's own, under set -e)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${SCRIPT_DIR}/_lib.sh"

project_args "$@"
take_stale=""
for a in ${REST[@]+"${REST[@]}"}; do
    case "$a" in
        --take-over-stale) take_stale=--take-over-stale ;;
        *) err "Unknown arg: $a"; exit 2 ;;
    esac
done
build_ssh_args
load_theme_filters

lock_state || die "Could not read the server."
case "$LOCK_STATE" in
    FOREIGN) lock_report BUSY; exit 5 ;;
    STALE)   if [[ -z "$take_stale" ]]; then lock_report STALE_LOCK; exit 5; fi ;;
esac
crashed_owner="${LOCK_OWNER%@*}"
had_lock="$LOCK_STATE"

leftovers=$(server_leftovers) || die "Could not read the server."
if [[ "$had_lock" == FREE && "$leftovers" == theme ]]; then echo "STATUS=CLEAN"; exit 0; fi

lock_acquire "$take_stale" || { lock_report BUSY; exit 5; }
live=""
trap 'rm -f "${live:-}"; lock_release' EXIT
live=$(mktemp)
leftovers=$(server_leftovers)          # again, now that nobody else can change them
has() { grep -qxF "$1" <<< "$leftovers"; }
actions=()
recorded_version="" live_warnings=""

if ! has theme && ! has .velk-theme-previous; then
    die "theme/ is missing on the server and there is no previous copy to put back — this needs a person."
elif ! has theme; then
    remote_in_root 'mv .velk-theme-previous theme'
    actions+=(restored-previous)
elif has theme && has .velk-theme-previous; then
    state=$(remote_state)
    remote_theme_manifest > "$live"
    rules=""        # the crashed publish's: the failures it accepted, then the home's answer before it
    if has .velk-theme-check; then rules=$(remote_in_root 'cat .velk-theme-check' || true); fi
    if [[ "$state" != NONE && "$state" != UNREADABLE ]] \
       && perl "$MANIFEST_PL" same <(printf '%s' "$state") "$live"; then
        actions+=(already-recorded)
    elif validate_live "$(sed -n 1p <<< "$rules")" "$(sed -n 2p <<< "$rules")"; then
        live_warnings="$LIVE_WARNINGS"
        if [[ "$state" == UNREADABLE ]]; then
            # Which version this was can't be known, and a guess would reuse
            # numbers. The theme stays; the next publish rewrites the record.
            actions+=(finished-publish-unrecorded)
        else
            version=$(state_version "$state")
            recorded_version=$(( ${version:-0} + 1 ))
            write_server_state "$recorded_version" "${crashed_owner:-unknown}" \
                || die "Could not record the finished publish."
            actions+=(finished-publish)
        fi
    else
        warn "The theme left live fails validation (${LIVE_FAILURE}) — swapping back"
        swap_back
        actions+=(swapped-back)
    fi
    remote_in_root 'rm -rf .velk-theme-previous'
fi
if has .velk-theme-staging; then remote_in_root 'rm -rf .velk-theme-staging'; actions+=(removed-staging); fi
if has .velk-theme-failed;  then remote_in_root 'rm -rf .velk-theme-failed';  actions+=(removed-failed); fi
if has .velk-theme-check;   then remote_in_root 'rm -f .velk-theme-check'; fi
if [[ "$had_lock" != FREE ]]; then actions+=(released-lock); fi

echo "STATUS=RECOVERED"
for a in ${actions[@]+"${actions[@]}"}; do echo "ACTION=${a}"; done
if [[ -n "$recorded_version" ]]; then echo "VERSION=${recorded_version}"; fi
printf '%s' "$live_warnings" | sed 's/^/WARN=/'
