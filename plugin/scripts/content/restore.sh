#!/usr/bin/env bash
# restore.sh --project <dir> [--config <ssh.json>] --file <backup.sql> --confirm
#
# Put a content backup (backup.sh) back — it overwrites the live tables it
# holds, so it needs --confirm, given only after the user's yes.
#
# The file goes to a fresh name in the server's /tmp that only its owner can
# read, and is imported there into the site database with the credentials of
# the server's own .env (scripts/remote/db.sh), then deleted: the password
# never sits on a command line nor travels to this machine.
#
# stdout: one line of JSON — {"ok": true, "restored": <file>} or
#         {"ok": false, "error": …}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../ssh-lib.sh
source "${SCRIPT_DIR}/../ssh-lib.sh"

project_args "$@"
FILE=""
CONFIRM=0
set -- ${REST[@]+"${REST[@]}"}
while [[ $# -gt 0 ]]; do
    case "$1" in
        --file)    FILE="$2"; shift 2 ;;
        --confirm) CONFIRM=1; shift ;;
        *) err "Unknown arg: $1"; exit 2 ;;
    esac
done

if [[ -z "$FILE" || ! -f "$FILE" ]]; then
    echo '{"ok": false, "error": "--file must name a backup made by backup.sh"}'
    exit 2
fi
if [[ "$CONFIRM" != "1" ]]; then
    echo '{"ok": false, "error": "restoring overwrites the live tables in the backup — pass --confirm after the user says yes"}'
    exit 2
fi

build_ssh_args

step "Sending the backup to the server"
if ! remote_file=$("${ssh_args[@]}" "mktemp /tmp/velk-content-restore.XXXXXX" </dev/null) \
   || ! "${ssh_args[@]}" "cat > $(shell_quote "$remote_file")" < "$FILE"; then
    echo '{"ok": false, "error": "could not send the backup to the server"}'
    exit 1
fi

step "Importing it into the site database"
if ! remote_script "${SCRIPT_DIR}/../remote/db.sh" import \
        "$(remote_path)" "$(resolve_php_bin)" "$remote_file" >&2; then
    "${ssh_args[@]}" "rm -f $(shell_quote "$remote_file")" || true
    echo '{"ok": false, "error": "the import failed on the server — see the messages above"}'
    exit 1
fi
ok "Restored"

jq -n -c --arg file "$FILE" '{ok: true, restored: $file}'
