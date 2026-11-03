#!/usr/bin/env bash
# check-engine.sh --project <dir> [--version vX.Y.Z]
#
# Is the project's engine exactly the published release it claims to be on?
# Fetches that release (sha256-verified, the same path update-cms uses) and
# compares engine_paths file by file.
#
# stdout: ENGINE_OK, or one CHANGED/ADDED/MISSING <path> line per difference.
# Exit:   0 identical · 1 the engine was altered · 2 could not check
#         (no version, release unreachable) — never read as a pass.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_PATH=/dev/null
# shellcheck source=ssh-lib.sh
source "${SCRIPT_DIR}/ssh-lib.sh"
# shellcheck source=release-lib.sh
source "${SCRIPT_DIR}/release-lib.sh"

project="" version=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --project) project="$2"; shift 2 ;;
        --version) version="$2"; shift 2 ;;
        *) err "Unknown arg: $1"; exit 2 ;;
    esac
done
[[ -n "$project" && -d "$project" ]] || { err "Usage: check-engine.sh --project <dir>"; exit 2; }

[[ -n "$version" ]] || version=$(version_for "$project")
[[ -n "$version" ]] || { err "No .velk-version or core/VERSION in ${project} — which release is this?"; exit 2; }
base=$(release_base_for "$project")

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
step "Comparing the local engine with ${version} (${base})"
src=$(fetch_release "$version" "$base" "$work") || { err "Could not fetch ${version} — the engine was NOT checked."; exit 2; }

set +e
perl "${SCRIPT_DIR}/lib/engine-diff.pl" "$src" "$project"
code=$?
set -e
case "$code" in
    0) ok "Engine matches ${version}" ;;
    1) err "The engine differs from the published ${version} (lines above)." ;;
    *) err "Could not compare the engine."; exit 2 ;;
esac
exit "$code"
