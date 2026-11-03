#!/usr/bin/env bash
# backup.sh --project <dir> [--config <ssh.json>] [--tables items,pages]
#
# Backup remote DB tables before any content write.
#
# Streams a `mysqldump` of the tables — schema and data — from the server
# back to a file on this Mac (velk-content-backup-<ts>.…, in the temp
# folder, readable only by its owner: it holds the client's content).
# Default tables: items,pages — those are the only ones content commands
# ever touch. Override with --tables for a fuller backup if needed.
#
# The dump runs on the server with the database credentials of the server's
# own .env (scripts/remote/db.sh): a config without database access — a
# site connected from an access file — backs up just the same, and the
# password never sits on a command line nor travels to this machine.
#
# Why dump just two tables and not the whole DB: speed and clarity. The
# rollback story is "restore items and pages" — full DB dumps include user
# data, form submissions, etc. that have nothing to do with content edits
# and just bloat the file.
#
# stdout: one line of JSON — {"ok": true, "backup_path": …, "rollback_hint": …}
#         or {"ok": false, "error": …}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../ssh-lib.sh
source "${SCRIPT_DIR}/../ssh-lib.sh"

project_args "$@"
TABLES="items,pages"
set -- ${REST[@]+"${REST[@]}"}
while [[ $# -gt 0 ]]; do
    case "$1" in
        --tables) TABLES="$2"; shift 2 ;;
        *) err "Unknown arg: $1"; exit 2 ;;
    esac
done
build_ssh_args

TS=$(date +%Y%m%d-%H%M%S)
IFS=',' read -r -a TABLE_ARGS <<< "$TABLES"
if (( ${#TABLE_ARGS[@]} == 0 )); then      # with no table, mysqldump would dump every table
    echo '{"ok": false, "error": "--tables is empty — name the tables to back up (default items,pages)"}'
    exit 2
fi
BACKUP_FILE=$(umask 077; mktemp "${TMPDIR:-/tmp}/velk-content-backup-${TS}.XXXXXX") || die "mktemp failed"

# Until the dump comes back whole, the file is provisional: any other way out
# — a failed or empty dump, Ctrl-C, a killed process — removes it. Left
# behind under a backup's name, an empty or half-written file looks like a
# restore point, and the half-written one holds part of the client's content.
# The signals become exits so the EXIT trap runs (bash runs it once the dump
# it is waiting on ends).
backup_kept=0
trap '[[ $backup_kept == 1 ]] || rm -f "$BACKUP_FILE"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

step "Backing up remote tables [${TABLES}]"

# The dump streams over SSH straight to the local file (--single-transaction
# and --no-tablespaces, which shared hosts need, are in the remote script).
if ! remote_script "${SCRIPT_DIR}/../remote/db.sh" dump --with-schema \
        "$(remote_path)" "$(resolve_php_bin)" "${TABLE_ARGS[@]}" > "$BACKUP_FILE"; then
    cat <<EOF
{"ok": false, "error": "mysqldump failed on remote — check the server's .env or the table names. Tables requested: ${TABLES}"}
EOF
    exit 1
fi
# mysqldump with the schema always writes something: an empty file means the
# dump never ran, and a backup of nothing must not be reported as one.
if [[ ! -s "$BACKUP_FILE" ]]; then
    jq -nc --arg t "$TABLES" \
        '{ok: false, error: ("the dump came back empty — nothing was saved. Check the server'"'"'s .env and the table names. Tables requested: " + $t)}'
    exit 1
fi
backup_kept=1

SIZE=$(wc -c < "$BACKUP_FILE" | tr -d ' ')
ok "Backup written ($SIZE bytes)"

# Single-line JSON so the caller can parse without ceremony.
jq -n \
    --arg path "$BACKUP_FILE" \
    --arg tables "$TABLES" \
    --arg ssh_target "$ssh_target" \
    --argjson size "$SIZE" \
    --arg ts "$TS" \
    --arg project "$PROJECT_DIR" \
    '{
        ok: true,
        backup_path: $path,
        size_bytes: $size,
        tables: ($tables | split(",")),
        ssh_target: $ssh_target,
        timestamp: $ts,
        rollback_hint: ("scripts/content/restore.sh --project " + $project + " --file " + $path + " --confirm")
    }'
