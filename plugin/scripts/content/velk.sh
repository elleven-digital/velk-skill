#!/usr/bin/env bash
# velk.sh --project <dir> [--config <ssh.json>] -- <bin/velk arguments...>
#
# Runs bin/velk on the site's server, with the PHP the config names, and
# hands back what it printed:
#   scripts/content/velk.sh --project . -- item:list post --status=draft
# Everything after "--" reaches bin/velk as it was given (references/cli.md
# lists the commands).
#
# For the content commands — item:* and page:list/schema/get/update —
# --format=json is added when missing, so the answer always parses. Before
# one that writes (item:create/update/publish/unpublish/delete, page:update)
# and isn't a --dry-run, a theme publish that died halfway is finished or
# undone first (scripts/theme/recover.sh). Someone else's publish lock
# doesn't stop a content edit — content lives in the database, not in
# theme/ — and neither does a server that can't be checked: both only warn.
#
# This side's stdin reaches bin/velk only when --json-stdin is among the
# arguments; otherwise the server gets none (ssh hands stdin to the first
# remote command it runs — the recovery, once, ate the JSON).
#
# stdout: bin/velk's, untouched, with its exit code — with --format=json it
#         answers {"ok": false, …} to its own errors. When ssh itself fails
#         (255): {"ok": false, "error": …} and exit 1.
# Exit:   bin/velk's · 1 ssh failed · 2 bad arguments

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../ssh-lib.sh
source "${SCRIPT_DIR}/../ssh-lib.sh"

usage() { err "Usage: velk.sh --project <dir> [--config <ssh.json>] -- <bin/velk arguments...>"; exit 2; }

# Ours before "--", bin/velk's after it.
ours=()
while [[ $# -gt 0 && "$1" != "--" ]]; do ours+=("$1"); shift; done
[[ "${1:-}" == "--" ]] || usage
shift
(( $# > 0 )) || usage
project_args ${ours[@]+"${ours[@]}"}
[[ ${#REST[@]} -eq 0 ]] || { err "Unknown arg: ${REST[0]}"; exit 2; }
build_ssh_args

verb="$1"
json_stdin=0 dry_run=0 has_format=0
for a in "$@"; do
    case "$a" in
        --json-stdin) json_stdin=1 ;;
        --dry-run)    dry_run=1 ;;
        --format=*)   has_format=1 ;;
    esac
done
content=0 writes=0
case "$verb" in
    item:types|item:schema|item:list|item:get|page:list|page:schema|page:get) content=1 ;;
    item:create|item:update|item:publish|item:unpublish|item:delete|page:update) content=1; writes=1 ;;
esac
args=("$@")
if (( content && ! has_format )); then args+=("--format=json"); fi

if (( writes && ! dry_run )); then
    rc=0
    bash "${SCRIPT_DIR}/../theme/recover.sh" --project "$PROJECT_DIR" --config "$CONFIG_PATH" </dev/null >&2 || rc=$?
    if (( rc == 5 )); then
        warn "A theme publish is in progress or waiting for a decision (above) — going on with the content edit."
    elif (( rc != 0 )); then
        warn "Could not check the server for an interrupted theme publish (above) — going on with the content edit."
    fi
fi

step "bin/velk ${args[*]} on ${ssh_target}"
set +e
if (( json_stdin )); then
    remote_velk "${args[@]}"
else
    remote_velk "${args[@]}" </dev/null
fi
code=$?
set -e
if (( code == 255 )); then
    echo '{"ok": false, "error": "ssh could not run bin/velk on the server — see the messages above"}'
    exit 1
fi
exit "$code"
