#!/usr/bin/env bash
# download-theme.sh --project <dir> [--config <ssh.json>] [--take-over-stale]
#
# Brings the live theme/ into <dir>/theme and records it as the starting point
# of the next publish, with the version the server says it is (0 when the
# server isn't versioned yet — the first versioned publish makes it v1).
#
# stdout: STATUS=DOWNLOADED, VERSION=<n>, and a RECOVERED=<action> line for
#         each thing the recovery did first (with its WARN= lines) — or
#         recover.sh's STATUS=BUSY / STATUS=STALE_LOCK with exit 5.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${SCRIPT_DIR}/_lib.sh"

project_args "$@"
take_stale=""
for a in ${REST[@]+"${REST[@]}"}; do
    case "$a" in
        --take-over-stale) take_stale=--take-over-stale ;;
        *) err "Unknown arg: $a"; exit 2 ;;
    esac
done
build_ssh_args
load_theme_filters

# A publish that died halfway is finished or undone first. Someone else's
# lock stops the download (exit 5): the theme may be mid-publish — a stale
# one is taken over only with --take-over-stale, after asking.
set +e
recovery=$(bash "${SCRIPT_DIR}/recover.sh" --project "$PROJECT_DIR" --config "$CONFIG_PATH" $take_stale)
code=$?
set -e
if (( code == 5 )); then printf '%s\n' "$recovery"; exit 5; fi
(( code == 0 )) || die "Recovering the server failed."
recovered=$(sed -n 's/^ACTION=/RECOVERED=/p; /^WARN=/p' <<< "$recovery")

state=$(remote_state) || die "Could not read the server."
version=$(state_version "$state")
[[ -n "$version" ]] || version=0

step "Downloading the live theme"
mkdir -p "${PROJECT_DIR}/theme"
theme_rsync --delete -e "$(rsync_remote_shell)" \
    "$(rsync_target_for "$(remote_path)/theme")/" "${PROJECT_DIR}/theme/" >&2 \
    || die "rsync of theme/ failed"
record_theme_base "$PROJECT_DIR" "$version"
# What an unfinished publish left here (its plan, conflicts, backup) belongs to
# the copy just replaced.
rm -rf "${PROJECT_DIR}/.deploy/publish"
ok "Theme downloaded (server version ${version})"
echo "STATUS=DOWNLOADED"
echo "VERSION=${version}"
if [[ -n "$recovered" ]]; then echo "$recovered"; fi
