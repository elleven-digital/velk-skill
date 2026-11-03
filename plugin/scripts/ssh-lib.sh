#!/usr/bin/env bash
# scripts/ssh-lib.sh — what every action script shares: the config
# (.deploy/ssh.json), the SSH transport, rsync through it, bin/velk and the
# skill's own scripts on the server, and the local database's option file.
#
# Sourced, never run:
#
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "${SCRIPT_DIR}/../ssh-lib.sh"      # or ../theme/_lib.sh, which loads it
#
# One SSH style: build_ssh_args fills the `ssh_args` array (and `ssh_target`,
# for display); callers do "${ssh_args[@]}" "remote command", or go through
# remote_in_root, remote_velk and remote_script. Every value that reaches the
# remote shell goes through shell_quote.

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────
# Output — all of it to stderr, so stdout stays clean for the answer
# ─────────────────────────────────────────────────────────────────────

C_BLUE='\033[0;34m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[1;33m'
C_RED='\033[0;31m'
C_DIM='\033[2m'
C_RESET='\033[0m'

step()  { echo -e "${C_BLUE}▸${C_RESET} $*" >&2; }
ok()    { echo -e "${C_GREEN}✓${C_RESET} $*" >&2; }
warn()  { echo -e "${C_YELLOW}!${C_RESET} $*" >&2; }
err()   { echo -e "${C_RED}✗${C_RESET} $*" >&2; }
dim()   { echo -e "${C_DIM}$*${C_RESET}" >&2; }

die() {
    err "$*"
    exit 1
}

# ─────────────────────────────────────────────────────────────────────
# Config access
# ─────────────────────────────────────────────────────────────────────

# cfg_get '.dot.path' [default]
# Returns the JSON value at path, or default (or empty) if absent/null.
cfg_get() {
    local path="$1"
    local default="${2:-}"
    local val
    val=$(jq -r "${path} // empty" "$CONFIG_PATH" 2>/dev/null)
    if [[ -z "$val" || "$val" == "null" ]]; then
        echo "$default"
    else
        echo "$val"
    fi
}

# Validates that CONFIG_PATH is set and points to a parseable JSON file.
require_config() {
    if [[ -z "${CONFIG_PATH:-}" ]]; then
        echo "ERROR: CONFIG_PATH not set. Pass --config <path>." >&2
        exit 2
    fi
    if [[ ! -f "$CONFIG_PATH" ]]; then
        echo "ERROR: Config not found at $CONFIG_PATH" >&2
        exit 2
    fi
    if ! jq -e . "$CONFIG_PATH" >/dev/null 2>&1; then
        echo "ERROR: Config at $CONFIG_PATH is not valid JSON" >&2
        exit 2
    fi
}

# project_args <args...> — the arguments every action script takes:
# --project <dir> (required) and --config <file> (default
# <dir>/.deploy/ssh.json), into PROJECT_DIR and CONFIG_PATH — both made
# absolute, so a script that cds into the project (init, update-cms) still
# reads the config it was given; whatever else was given stays in REST, for
# the script to read.
project_args() {
    PROJECT_DIR="" CONFIG_PATH="" REST=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --project) PROJECT_DIR="${2%/}"; shift 2 ;;
            --config)  CONFIG_PATH="$2";     shift 2 ;;
            *) REST+=("$1"); shift ;;
        esac
    done
    [[ -n "$PROJECT_DIR" && -d "$PROJECT_DIR" ]] || { err "--project <dir> is required"; exit 2; }
    PROJECT_DIR=$(cd "$PROJECT_DIR" && pwd -P)
    [[ -n "$CONFIG_PATH" ]] || CONFIG_PATH="${PROJECT_DIR}/.deploy/ssh.json"
    require_config
    CONFIG_PATH="$(cd "$(dirname "$CONFIG_PATH")" && pwd -P)/${CONFIG_PATH##*/}"
}

# ─────────────────────────────────────────────────────────────────────
# ssh_endpoint_ok <user|alias> [host] [port] — shapes ssh can't take for an
# option and no shell can take for code. A config that fails it never reaches
# ssh (an access file is checked field by field before it becomes a config;
# this guards a config edited by hand).
ssh_endpoint_ok() {
    local re_user='^[A-Za-z0-9_][A-Za-z0-9._-]*$' re_host='^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$'
    [[ "$1" =~ $re_user ]] || return 1
    [[ -z "${2:-}" || "$2" =~ $re_host ]] || return 1
    [[ -z "${3:-}" || "$3" =~ ^[0-9]{1,5}$ ]]
}

# SSH
# ─────────────────────────────────────────────────────────────────────
# Sets globals: ssh_args (array), ssh_target (string for display).
# Usage:
#   build_ssh_args
#   "${ssh_args[@]}" "remote command"
build_ssh_args() {
    local alias
    alias=$(cfg_get '.ssh.alias')
    if [[ -n "$alias" ]]; then
        ssh_endpoint_ok "$alias" || die "ssh.alias in the config has a shape ssh could take for an option — refusing."
        ssh_args=("ssh" "$alias")
        ssh_target="$alias"
        return
    fi
    local host port user key
    host=$(cfg_get '.ssh.host')
    port=$(cfg_get '.ssh.port' '22')
    user=$(cfg_get '.ssh.user')
    key=$(cfg_get '.ssh.key_path' "$HOME/.ssh/id_ed25519")
    [[ -z "$host" || -z "$user" ]] && die "ssh config must provide either alias OR host+user (+ optional port/key_path)"
    ssh_endpoint_ok "$user" "$host" "$port" \
        || die "ssh.user / ssh.host / ssh.port in the config have a shape ssh could take for an option or a command — refusing."
    key="${key/#\~/$HOME}"
    ssh_args=("ssh" "-p" "$port" "-i" "$key" "-o" "BatchMode=yes" "${user}@${host}")
    ssh_target="${user}@${host}"
}

# rsync remote shell prefix matching build_ssh_args.
# Usage: rsh=$(rsync_remote_shell); rsync -e "$rsh" ...
rsync_remote_shell() {
    local alias
    alias=$(cfg_get '.ssh.alias')
    if [[ -n "$alias" ]]; then
        echo "ssh"
        return
    fi
    local port key
    port=$(cfg_get '.ssh.port' '22')
    key=$(cfg_get '.ssh.key_path' "$HOME/.ssh/id_ed25519")
    key="${key/#\~/$HOME}"
    echo "ssh -p $port -i $key -o BatchMode=yes"
}

# Returns "user@host:path" or "alias:path" for rsync/scp.
rsync_target_for() {
    local remote="$1"
    local alias
    alias=$(cfg_get '.ssh.alias')
    if [[ -n "$alias" ]]; then
        echo "${alias}:${remote}"
        return
    fi
    local host user
    host=$(cfg_get '.ssh.host')
    user=$(cfg_get '.ssh.user')
    echo "${user}@${host}:${remote}"
}

# ─────────────────────────────────────────────────────────────────────
# Remote path
# ─────────────────────────────────────────────────────────────────────
# Required field on most hosts — varies wildly:
#   Hostinger shared:   /home/uXXX/domains/<domain>/public_html
#   cPanel shared:      /home/<user>/public_html
#   Locaweb/KingHost:   /home/<user>/www  or similar
#   DreamHost:          /home/<user>/<domain>
#   VPS/cloud:          anywhere — typically /var/www/<project> or /srv/<domain>
remote_path() {
    local path
    path=$(cfg_get '.ssh.remote_path')
    if [[ -z "$path" ]]; then
        die "ssh.remote_path is required in config — absolute path on the remote host where Velk lives (e.g. /var/www/site, /home/user/public_html, /home/u123/domains/site.com/public_html)"
    fi
    # Strip trailing slash for consistent concatenation.
    echo "${path%/}"
}

# site_base_url — the public address of the install: site.url plus
# site.subpath, without a trailing slash (https://ex.com/blog). Every URL a
# script builds for the site starts here: site.url alone is the host, and on
# a subdirectory install it's a different site — or nothing.
site_base_url() {
    local url sub
    url=$(cfg_get '.site.url'); url="${url%/}"
    sub=$(cfg_get '.site.subpath'); sub="${sub%/}"
    if [[ -n "$sub" && "$sub" != /* ]]; then sub="/${sub}"; fi
    printf '%s%s\n' "$url" "$sub"
}

# theme_leftovers <theme-dir> — what's left of a converted site's source in
# the theme, one path per line (theme/…): a PHP in the theme's root other than
# functions.php, and theme/includes/. Velk never loads either — templates live
# in templates/ and partials/ — so they're the original pages kept "for
# comparison" (references/theme-convert.md keeps the source in _source/).
# init and the theme publish both refuse to ship while this prints anything.
theme_leftovers() {
    local dir="${1%/}" f
    while IFS= read -r f; do
        printf 'theme/%s\n' "${f#"${dir}/"}"
    done < <(find "$dir" -maxdepth 1 -type f -name '*.php' ! -name functions.php 2>/dev/null | sort)
    if [[ -d "${dir}/includes" ]]; then echo "theme/includes/"; fi
    return 0
}

# remote_in_root <command> — runs a shell command in the install root.
remote_in_root() { "${ssh_args[@]}" "cd $(shell_quote "$(remote_path)") && $1"; }

# target_state — what the install root holds, by the server's own answer on
# stdout, into TARGET_STATE: EXISTS (core/Bootstrap.php is there), EMPTY
# (the folder, without Velk), MISSING (no folder) — or whatever else came
# back (a login banner, an error), for the caller to refuse. ssh's stderr is
# kept apart, in TARGET_STDERR: a first-connect warning or an sshd Banner is
# noise, not an answer. Needs build_ssh_args first.
target_state() {
    local rp errf
    rp=$(remote_path); errf=$(mktemp)
    TARGET_STATE=$("${ssh_args[@]}" "if [ -f $(shell_quote "${rp}/core/Bootstrap.php") ]; then echo EXISTS; elif [ -d $(shell_quote "$rp") ]; then echo EMPTY; else echo MISSING; fi" 2>"$errf" </dev/null) || true
    TARGET_STDERR=$(grep -v '^[[:space:]]*$' "$errf" | head -3 || true)
    rm -f "$errf"
}

# refuse_unreadable_target — the answer was none of the three: say what came
# back (printf, never echo -e: the text is the server's) and stop.
refuse_unreadable_target() {
    err "Could not tell whether $(remote_path) holds Velk — nothing was sent."
    err "The server answered:"
    printf '%s\n' "$TARGET_STATE" "$TARGET_STDERR" | grep -v '^[[:space:]]*$' | sed 's/^/    /' >&2 || true
    err "Run scripts/preflight.sh --project . first."
    exit 1
}

# local_db_defaults — a MySQL option file with the local database's
# credentials (.local.db_*), for --defaults-extra-file: the password never
# sits on a command line, where ps shows it. Prints the file's path; it is
# only its owner's, and the caller removes it when done. The value is
# written the way scripts/remote/db.sh writes the server's: backslashes
# doubled, then whichever quote mark the password lacks — or none.
local_db_defaults() {
    local host port user pass esc value file
    host=$(cfg_get '.local.db_host' 'localhost')
    port=$(cfg_get '.local.db_port' '3306')
    user=$(cfg_get '.local.db_user' 'root')
    pass=$(cfg_get '.local.db_password')
    esc="${pass//\\/\\\\}"
    if [[ "$pass" != *'"'* ]]; then value="\"${esc}\""
    elif [[ "$pass" != *"'"* ]]; then value="'${esc}'"
    elif [[ "$pass" != *'#'* && "$pass" == "${pass#[[:space:]]}" && "$pass" == "${pass%[[:space:]]}" \
            && ! ( "${pass:0:1}" == "${pass: -1}" && "${pass:0:1}" == [\"\'] ) ]]; then value="$esc"
    else die "local.db_password holds both quote marks and a #, edge spaces or the same quote mark at both ends, which an option file cannot hold"
    fi
    file=$(umask 077; mktemp "${TMPDIR:-/tmp}/velk-local-db.XXXXXX") || die "mktemp failed"
    printf '[client]\nhost=%s\nport=%s\nuser=%s\npassword=%s\n' "$host" "$port" "$user" "$value" > "$file"
    printf '%s\n' "$file"
}

# ─────────────────────────────────────────────────────────────────────
# bin/velk on the server
# ─────────────────────────────────────────────────────────────────────
# Lets sites override which PHP interpreter runs — useful on shared
# hosts where multiple PHP versions live side-by-side and the default
# `php` in PATH isn't the one Velk expects.
resolve_php_bin() {
    local p
    p=$(cfg_get '.remote.php_bin')
    echo "${p:-php}"
}

# remote_velk <args...> — runs bin/velk in the install root with the PHP the
# config names ("<php> ./bin/velk", not "./bin/velk": the script's shebang is
# `env php`, which ignores .remote.php_bin — and hosts whose default php is
# too old are exactly why that setting exists), each argument as given. stdin
# is left alone: the caller decides whether the server gets it (</dev/null
# when not). Needs build_ssh_args first.
remote_velk() { remote_in_root "$(shell_quote "$(resolve_php_bin)") ./bin/velk $(shell_quote "$@")"; }

# ─────────────────────────────────────────────────────────────────────
# Running local scripts on the server
# ─────────────────────────────────────────────────────────────────────

# shell_quote <arg>... — each argument single-quoted for the remote POSIX
# shell, embedded quotes included ("it's" → 'it'\''s'). bash 3.2's printf %q
# would emit $'…' for non-ASCII, which dash doesn't understand.
shell_quote() {
    local a out="" q="'\\''"
    for a in "$@"; do out="${out} '${a//\'/$q}'"; done
    printf '%s' "${out# }"
}

# remote_script <script-file> [args...] — runs a script from this skill ON
# THE SERVER: bash reads it from stdin, so nothing is installed there.
# Needs build_ssh_args first.
remote_script() {
    local script="$1"
    shift
    "${ssh_args[@]}" "bash -s -- $(shell_quote "$@")" < "$script"
}
