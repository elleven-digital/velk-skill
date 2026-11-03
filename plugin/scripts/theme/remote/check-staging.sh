#!/bin/bash
# Runs ON THE SERVER, fed by remote_script:
#   check-staging.sh <staging-dir> <php> <rsync filter args...>
#
# Pure-PHP checks on the staged theme before it goes live, without booting
# the engine: every theme .php must lint and site.json must decode. The theme
# is listed with the same filters as everything else, so legacy files the
# deploy never ships don't block it. One line per problem; exit 1 if any, 2
# if the check itself could not run.
set -uo pipefail
dir="$1"; php="$2"; shift 2
cd "$dir" || exit 2
"$php" -v >/dev/null 2>&1 || { echo "PHP (${php}) doesn't run here." >&2; exit 2; }
empty=$(mktemp -d) || exit 2
trap 'rm -rf "$empty"' EXIT
list=$(rsync -an -8 --out-format='%n' "$@" ./ "${empty}/") || { echo "Could not list the staged theme." >&2; exit 2; }
bad=0
while IFS= read -r f; do
    case "$f" in *.php) ;; *) continue ;; esac
    [ -f "$f" ] || continue
    if ! out=$("$php" -l "$f" 2>&1); then
        echo "PHP_LINT ${f}: $(printf '%s\n' "$out" | grep -m1 -i 'error')"
        bad=1
    fi
done <<< "$list"
if ! "$php" -r 'json_decode((string) @file_get_contents("site.json")); exit(json_last_error() === JSON_ERROR_NONE ? 0 : 1);'; then
    echo "SITE_JSON site.json is not valid JSON"
    bad=1
fi
exit "$bad"
