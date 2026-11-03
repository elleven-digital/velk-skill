#!/bin/bash
# Runs ON THE SERVER, fed by remote_script:
#   db.sh dump [--with-schema] <install-root> <php> [table...]
#   db.sh import <install-root> <php> <sql-file>
#   db.sh check <install-root> <php>
#   db.sh settings <install-root> <php>
#
# dump:     the DATA (no schema) of the given tables — or, with --with-schema,
#           schema and data: a backup that restores on its own. No table: all.
# import:   runs an SQL file into the site database, then deletes the file.
# check:    the database answers.
# settings: the few .env settings that are not secret and make a local copy
#           behave like production — an allowlist: a key added to .env
#           tomorrow stays on the server.
#
# Everything the skill reads from the server's .env goes through here, read
# the way Velk's core/Env.php reads it ("export " prefix, quotes, escapes in
# double quotes, the first line of a repeated key wins). The database
# credentials go into an option file readable only by its owner, which exists
# for the length of the command: the production password never sits on a
# command line (where `ps` shows it) and never travels to the Mac.
set -euo pipefail
verb="${1:-}"
case "$verb" in dump|import|check|settings) shift ;; *) echo "usage: db.sh dump|import|check|settings …" >&2; exit 2 ;; esac
schema=--no-create-info
if [ "$verb" = dump ] && [ "${1:-}" = --with-schema ]; then schema=""; shift; fi
root="$1"; php="$2"; shift 2
cd "$root"
opt=$(mktemp)
chmod 600 "$opt"
trap 'rm -f "$opt"' EXIT
out=$("$php" -d display_errors=stderr -d display_startup_errors=0 -r '
    // .env the way Velk reads it (core/Env.php).
    $env = [];
    foreach (file(".env", FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) ?: [] as $line) {
        $line = trim($line);
        if ($line === "" || $line[0] === "#") continue;
        if (strncmp($line, "export ", 7) === 0) $line = substr($line, 7);
        $eq = strpos($line, "=");
        if ($eq === false) continue;
        $k = trim(substr($line, 0, $eq));
        $v = trim(substr($line, $eq + 1));
        if (!preg_match("/^[A-Za-z_][A-Za-z0-9_]*$/", $k)) continue;
        if (strlen($v) >= 2 && ($v[0] === "\"" || $v[0] === "\x27") && substr($v, -1) === $v[0]) {
            $q = $v[0];
            $v = substr($v, 1, -1);
            if ($q === "\"") {
                $v = str_replace(["\\n", "\\r", "\\t", "\\\"", "\\\\"], ["\n", "\r", "\t", "\"", "\\"], $v);
            }
        }
        if (!array_key_exists($k, $env)) $env[$k] = $v;  // Velk keeps the first
    }
    if ($argv[1] === "settings") {
        // Plain when plain, else double-quoted the way Velk reads it back.
        foreach (["APP_NAME", "APP_TIMEZONE", "ADMIN_LOCALE", "ADMIN_PREFIX"] as $k) {
            if (!array_key_exists($k, $env)) continue;
            $v = $env[$k];
            if (!preg_match("#^[A-Za-z0-9_./:@+-]*$#", $v)) {
                $v = "\"" . str_replace(["\\", "\"", "\n", "\r", "\t"], ["\\\\", "\\\"", "\\n", "\\r", "\\t"], $v) . "\"";
            }
            echo $k, "=", $v, "\n";
        }
        exit(0);
    }
    // An option file value: backslashes doubled, then whichever quote marks
    // the password lacks — or none. Holding both quote marks and a "#", edge
    // spaces or the same quote mark at both ends, it cannot be written.
    $pass = $env["DB_PASSWORD"] ?? "";
    $esc = str_replace("\\", "\\\\", $pass);
    if (strpos($pass, "\"") === false) {
        $value = "\"" . $esc . "\"";
    } elseif (strpos($pass, "\x27") === false) {
        $value = "\x27" . $esc . "\x27";
    } elseif (strpos($pass, "#") === false && trim($pass) === $pass
              && !($pass[0] === substr($pass, -1) && strpos("\"\x27", $pass[0]) !== false)) {
        $value = $esc;
    } else {
        fwrite(STDERR, "DB_PASSWORD holds both quote marks and a #, edge spaces or the same quote mark at both ends, which an option file cannot hold\n");
        exit(3);
    }
    file_put_contents($argv[2], sprintf("[client]\nhost=%s\nport=%s\nuser=%s\npassword=%s\n",
        $env["DB_HOST"] ?? "localhost", $env["DB_PORT"] ?? "3306", $env["DB_USERNAME"] ?? "", $value));
    echo $env["DB_DATABASE"] ?? "";
' "$verb" "$opt")
if [ "$verb" = settings ]; then [ -z "$out" ] || printf '%s\n' "$out"; exit 0; fi
db="$out"
[ -n "$db" ] || { echo "DB_DATABASE is missing from .env" >&2; exit 3; }
case "$verb" in
    dump)
        mysqldump --defaults-extra-file="$opt" ${schema:+"$schema"} --complete-insert --skip-triggers \
            --single-transaction --no-tablespaces "$db" "$@" ;;
    import)
        file="$1"
        trap 'rm -f "$opt" "$file"' EXIT
        mysql --defaults-extra-file="$opt" "$db" < "$file" ;;
    check)
        mysql --defaults-extra-file="$opt" "$db" -e 'SELECT 1' >/dev/null ;;
esac
