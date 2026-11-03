#!/usr/bin/env bash
# preflight.sh --project <dir> [--config <ssh.json>] [--local-db]
#
# The one check before anything touches a server: SSH answers, what the
# target holds, and its database — with the credentials of the server's own
# .env (scripts/remote/db.sh), so no password sits on any command line. With
# --local-db, the local database of .local.db_* too, through an option file,
# and a mysqldump beside it: what init and the local copy need.
#
# It only looks: nothing is created on the server, not even the folder.
#
# stdout: STATUS=OK, then one line per check, in this order:
#   SSH=ok
#   TARGET=EXISTS|EMPTY|MISSING   core/Bootstrap.php in remote_path | the folder,
#                                 without Velk | no folder (init creates it)
#   DB=ok|skipped                 skipped unless TARGET=EXISTS: before init
#                                 there is no .env to read
#   LOCAL_DB=ok, MYSQLDUMP=ok     only with --local-db
# — or, at the first failure: STATUS=FAILED, the lines that passed,
# FAILED=ssh|target|db|local_db|mysqldump and REASON=<one line>.
# Exit:   0 every check passed · 1 a check failed · 2 bad arguments

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ssh-lib.sh
source "${SCRIPT_DIR}/ssh-lib.sh"

project_args "$@"
local_db=""
for a in ${REST[@]+"${REST[@]}"}; do
    case "$a" in
        --local-db) local_db=1 ;;
        *) err "Unknown arg: $a"; exit 2 ;;
    esac
done
build_ssh_args
rp=$(remote_path)

errf=$(mktemp)
opt=""
trap 'rm -f "$errf" "${opt:-}"' EXIT
passed=()
fail_check() {   # fail_check <check> <reason> — says what passed, what failed, why
    echo "STATUS=FAILED"
    for l in ${passed[@]+"${passed[@]}"}; do echo "$l"; done
    echo "FAILED=$1"
    echo "REASON=$2"
    exit 1
}
first_line() { grep -v '^[[:space:]]*$' "$1" | head -1; }

step "Preflight against ${ssh_target}:${rp}"
"${ssh_args[@]}" -o ConnectTimeout=10 "echo OK" >/dev/null 2>"$errf" </dev/null \
    || fail_check ssh "$(first_line "$errf")"
passed+=("SSH=ok")

target=$("${ssh_args[@]}" "if [ -f $(shell_quote "${rp}/core/Bootstrap.php") ]; then echo EXISTS; elif [ -d $(shell_quote "$rp") ]; then echo EMPTY; else echo MISSING; fi" 2>"$errf" </dev/null) \
    || fail_check target "$(first_line "$errf")"
case "$target" in
    EXISTS|EMPTY|MISSING) passed+=("TARGET=${target}") ;;
    *) fail_check target "unexpected answer from the server: ${target}" ;;
esac

if [[ "$target" == EXISTS ]]; then
    remote_script "${SCRIPT_DIR}/remote/db.sh" check "$rp" "$(resolve_php_bin)" >/dev/null 2>"$errf" \
        || fail_check db "$(first_line "$errf")"
    passed+=("DB=ok")
else
    passed+=("DB=skipped")
fi

if [[ -n "$local_db" ]]; then
    mysql=$(cfg_get '.local.mysql_bin'); [[ -n "$mysql" && -x "$mysql" ]] || mysql=$(command -v mysql || true)
    [[ -n "$mysql" ]] || fail_check local_db "no mysql on this Mac — scripts/local/env.sh installs one"
    opt=$(local_db_defaults 2>"$errf") || fail_check local_db "$(first_line "$errf")"
    "$mysql" --defaults-extra-file="$opt" -e 'SELECT 1' >/dev/null 2>"$errf" </dev/null \
        || fail_check local_db "$(first_line "$errf")"
    passed+=("LOCAL_DB=ok")
    dump="$(dirname "$mysql")/mysqldump"
    [[ -x "$dump" ]] || dump=$(command -v mysqldump || true)
    [[ -n "$dump" ]] || fail_check mysqldump "no mysqldump beside ${mysql} nor on PATH"
    passed+=("MYSQLDUMP=ok")
fi

ok "Preflight passed"
echo "STATUS=OK"
for l in ${passed[@]+"${passed[@]}"}; do echo "$l"; done
