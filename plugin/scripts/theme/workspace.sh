#!/usr/bin/env bash
# workspace.sh open|close --project <dir> [--take-over-stale]
#
# "Live" mode: every request that touches the theme works in a throwaway copy
# of the live theme, <dir>/.deploy/workspace/, deleted when the request ends.
# Nothing of the theme stays on the machine between requests — so nothing can
# be deleted there by accident and later published as a deletion, and the
# starting point is always fresh. An old workspace is never reused.
#
# stdout: open  → STATUS=OPEN, WORKSPACE=<path>, DISCARDED=0|1, VERSION=<n>,
#                  RECOVERED=<action>…, WARN=… — or, with exit 5, download-theme's
#                  STATUS=BUSY / STATUS=STALE_LOCK (someone else's publish)
#         close → STATUS=CLOSED

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${SCRIPT_DIR}/_lib.sh"

action="${1:-}"
shift || true
project_args "$@"
take_stale=""
for a in ${REST[@]+"${REST[@]}"}; do
    case "$a" in
        --take-over-stale) take_stale=--take-over-stale ;;
        *) err "Unknown arg: $a"; exit 2 ;;
    esac
done
ws="${PROJECT_DIR}/.deploy/workspace"

case "$action" in
    open)
        discarded=0
        if [[ -e "$ws" ]]; then discarded=1; rm -rf "$ws"; fi
        mkdir -p "${ws}/.deploy"
        ( umask 077; cp "$CONFIG_PATH" "${ws}/.deploy/ssh.json" )
        set +e
        out=$(bash "${SCRIPT_DIR}/download-theme.sh" --project "$ws" $take_stale)
        code=$?
        set -e
        if (( code != 0 )); then
            rm -rf "$ws"
            if (( code == 5 )); then printf '%s\n' "$out"; exit 5; fi    # someone else's publish, as is
            die "Could not download the theme."
        fi
        echo "STATUS=OPEN"
        echo "WORKSPACE=${ws}"
        echo "DISCARDED=${discarded}"
        grep -E '^(VERSION|RECOVERED|WARN)=' <<< "$out"
        ;;
    close)
        rm -rf "$ws"
        echo "STATUS=CLOSED"
        ;;
    *) err "Usage: workspace.sh open|close --project <dir> [--take-over-stale]"; exit 2 ;;
esac
