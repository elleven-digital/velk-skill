# tests/lib/assert.sh — assertions. A failure prints why and exits the
# test's bash with status 1, which is how run.sh counts it.

fail() { printf '✗ %s\n' "$*" >&2; exit 1; }

assert_eq() {
    [ "$1" = "$2" ] || fail "${3:-values differ}"$'\n'"  expected: [$1]"$'\n'"  actual:   [$2]"
}
assert_contains() {       # <haystack> <needle> [msg]
    case "$1" in *"$2"*) ;; *) fail "${3:-text not found}: [$2]"$'\n'"  in: [$1]" ;; esac
}
assert_not_contains() {   # <haystack> <needle> [msg]
    case "$1" in *"$2"*) fail "${3:-text must be absent}: [$2]"$'\n'"  in: [$1]" ;; esac
}
assert_file()    { [ -f "$1" ] || fail "${2:-file missing}: $1"; }
assert_no_file() { [ ! -e "$1" ] || fail "${2:-must not exist}: $1"; }
assert_dir()     { [ -d "$1" ] || fail "${2:-directory missing}: $1"; }
assert_no_dir()  { [ ! -e "$1" ] || fail "${2:-directory must not exist}: $1"; }
assert_status()  { [ "$1" = "$2" ] || fail "${3:-exit status}: expected $1, got $2"; }
