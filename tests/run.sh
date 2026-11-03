#!/bin/bash
# tests/run.sh — the skill's test suite.
#
#   bash tests/run.sh           every tests/*_test.sh
#   bash tests/run.sh publish   only files whose name contains "publish"
#
# Each test_* function runs in its own bash with a fresh sandbox (see
# lib/sandbox.sh), so nothing leaks from one test to the next. PATH is
# reset to what a stock macOS ships plus tests/bin (the fakes): a script
# that quietly depends on a Homebrew tool fails here, not on a client's Mac.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$TESTS_DIR")"
# The skill is the plugin folder; the repo root holds the tests and tooling.
SKILL_DIR="${REPO_DIR}/plugin"
export TESTS_DIR REPO_DIR SKILL_DIR

# The fake server needs PHP — every real Velk server has it. The local side
# must never rely on it, so it is captured here, before PATH is reset, and
# only the fake ssh hands it back (to "remote" commands, see sandbox.sh).
DEV_PHP="${DEV_PHP:-$(command -v php 2>/dev/null || true)}"
export DEV_PHP

export PATH="${TESTS_DIR}/bin:/usr/bin:/bin:/usr/sbin:/sbin"

filter="${1:-}"
pass=0; fail=0; skip=0; failed=""
marker="__VELK_TEST_FINISHED__"

for file in "${TESTS_DIR}"/*_test.sh; do
    [ -f "$file" ] || continue
    case "$(basename "$file")" in *"${filter}"*) ;; *) continue ;; esac
    echo "$(basename "$file")"
    # A file that doesn't parse would `source` up to the error and quietly
    # lose every test after it: the count shrinks and nothing fails.
    if ! err=$(bash -n "$file" 2>&1); then
        fail=$((fail + 1)); failed="${failed} $(basename "$file" .sh):(does not parse)"
        printf '  \033[31m✗\033[0m does not parse\n'
        printf '%s\n' "$err" | sed 's/^/      /'
        continue
    fi
    names=$(bash -c ". '${file}' >/dev/null 2>&1; declare -F" | awk '{print $3}' | grep '^test_' || true)
    for t in $names; do
        out=$(bash -c "
            . '${TESTS_DIR}/lib/assert.sh'
            . '${TESTS_DIR}/lib/sandbox.sh'
            . '${file}'
            sandbox_create
            ${t}
            echo ${marker}
        " 2>&1 </dev/null)
        code=$?
        # bash 3.2 exits 0 when a failed `source` trips errexit while an EXIT
        # trap is set, so a status of 0 alone doesn't prove the test ran: it
        # passes only if it also reached the marker after its last line.
        finished=0
        if [ "$(printf '%s' "$out" | tail -1)" = "$marker" ]; then finished=1; fi
        out=$(printf '%s\n' "$out" | grep -v "^${marker}\$")
        if [ "$code" -eq 0 ] && [ "$finished" = 1 ]; then
            pass=$((pass + 1)); printf '  \033[32m✓\033[0m %s\n' "$t"
        elif [ "$code" -eq 99 ]; then
            skip=$((skip + 1)); printf '  \033[33m-\033[0m %s (skipped: %s)\n' "$t" "$(printf '%s' "$out" | tail -1)"
        else
            fail=$((fail + 1)); failed="${failed} $(basename "$file" .sh):${t}"
            printf '  \033[31m✗\033[0m %s\n' "$t"
            if [ "$code" -eq 0 ]; then echo "      (exited with status 0 before reaching its end)"; fi
            printf '%s\n' "$out" | sed 's/^/      /'
        fi
    done
done

echo
echo "${pass} passed, ${fail} failed, ${skip} skipped"
[ -n "$failed" ] && echo "failed:${failed}"
[ "$fail" -eq 0 ]
