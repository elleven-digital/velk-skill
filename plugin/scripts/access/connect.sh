#!/usr/bin/env bash
# connect.sh — the client side of an access file ("conecte esse site").
#
#   connect.sh platform
#   connect.sh inspect <file.velk>
#   connect.sh setup   <file.velk> --project <dir> [--identity <name>]
#   connect.sh key     --project <dir>
#   connect.sh test    --project <dir>
#   connect.sh mode    local|live --project <dir>
#
# Answers on stdout as KEY=value lines (STATUS= first) for Claude to put in
# the user's words; progress goes to stderr. Never prompts: every question to
# the user is Claude's, between two calls.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../ssh-lib.sh
source "${SCRIPT_DIR}/../ssh-lib.sh"

# ── helpers ──────────────────────────────────────────────────────────────

# access_problem <file> — prints why the access file is unusable, or nothing.
access_problem() {
    local file="$1" keys bad
    [[ -f "$file" ]] || { echo "file not found"; return; }
    jq -e 'type == "object"' "$file" >/dev/null 2>&1 || { echo "not a JSON object"; return; }
    [[ "$(jq -r '.velk_access' "$file")" == "1" ]] || { echo "not a Velk access file"; return; }
    keys=$(perl "${SCRIPT_DIR}/leak-check.pl" --file "$file") || { echo "unexpected fields: $(echo $keys)"; return; }
    # The file arrives by WhatsApp or email: every field must have the one
    # shape it can have. A user or host starting with "-" would be an ssh
    # option (-oProxyCommand=… runs anything); a quote, "$" or backtick would
    # be shell code; a control character could rewrite what the terminal shows.
    bad=$(jq -r '
        def text($max): type == "string" and length <= $max and (test("[[:cntrl:]]") | not);
        [ ["site.url", (.site.url | type == "string" and length <= 200
              and test("^https?://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?(/[A-Za-z0-9._~%/-]*)?$"))],
          ["site.subpath", ((.site.subpath // "") | type == "string" and test("^(/[A-Za-z0-9._~-]+)*/?$"))],
          ["ssh.host", (.ssh.host | type == "string" and length <= 253
              and test("^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$"))],
          ["ssh.port", (.ssh.port | type == "number" and . == floor and . >= 1 and . <= 65535)],
          ["ssh.user", (.ssh.user | type == "string" and length <= 64 and test("^[A-Za-z0-9_][A-Za-z0-9._-]*$"))],
          ["path", (.path | type == "string" and length <= 255 and test("^/[A-Za-z0-9._~@+/-]*$"))],
          ["remote.php_bin", ((.remote.php_bin // "/") | type == "string" and length <= 255
              and test("^/[A-Za-z0-9._+/-]*$"))],
          ["rsync.theme_extra_excludes", ((.rsync.theme_extra_excludes // []) | type == "array"
              and all(.[]; type == "string" and length <= 200 and test("^[A-Za-z0-9._*?/\\[\\]-]+$")))],
          ["created_by", ((.created_by // "") | text(120))],
          ["created_at", ((.created_at // "") | text(40))] ]
        | map(select(.[1] | not) | .[0]) | first // empty' "$file" 2>/dev/null) || bad="unreadable"
    [[ -z "$bad" ]] || echo "malformed field: ${bad}"
}

# ascii_slug <text> — "João Silva" → "Joao-Silva". The key comment ends up in
# the server's authorized_keys and in hosting panels, which don't all cope
# with non-ASCII.
ascii_slug() {
    perl -CSA -MUnicode::Normalize -e \
        '$_ = NFD($ARGV[0]); s/\p{Mn}//g; s/[^A-Za-z0-9._-]+/-/g; s/^-+|-+$//g; print' "$1"
}

# access_ssh <cmd...> — runs a command on the server with the configured key
# (or through the config's ssh alias), never prompting. accept-new records the
# host key on the first connection and still refuses a CHANGED one.
access_ssh() {
    local key args alias
    alias=$(cfg_get '.ssh.alias')
    if [[ -n "$alias" ]]; then     # an agency config: ~/.ssh/config knows the rest
        ssh_endpoint_ok "$alias" || { echo "malformed ssh.alias in the config" >&2; return 255; }
        ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "$alias" "$@"
        return
    fi
    ssh_endpoint_ok "$(cfg_get '.ssh.user')" "$(cfg_get '.ssh.host')" "$(cfg_get '.ssh.port' '22')" \
        || { echo "malformed ssh.user / ssh.host / ssh.port in the config" >&2; return 255; }
    key=$(cfg_get '.ssh.key_path')
    args=(ssh -p "$(cfg_get '.ssh.port' '22')" -o BatchMode=yes -o ConnectTimeout=10
          -o StrictHostKeyChecking=accept-new)
    if [[ -n "$key" ]]; then args+=(-i "${key/#\~/$HOME}" -o IdentitiesOnly=yes); fi
    "${args[@]}" "$(cfg_get '.ssh.user')@$(cfg_get '.ssh.host')" "$@"
}

# key_is_usable <file> — exists and opens without a passphrase. A key with a
# passphrase makes every BatchMode ssh fail with no explanation.
key_is_usable() { [[ -f "$1" ]] && ssh-keygen -y -P '' -f "$1" >/dev/null 2>&1; }

# key_path_taken <path> — something already sits at the key's path or at its
# .pub, a symlink included: ssh-keygen would replace the .pub, or write through
# the link, without asking.
key_path_taken() { [[ -e "$1" || -L "$1" || -e "${1}.pub" || -L "${1}.pub" ]]; }

# ssh_failure_status <ssh stderr> — the STATUS (and DETAIL) of a connection
# that failed, told apart the same way by key and test. Unreachable means one
# of ssh's own connection errors: a server's login banner can say "timed out"
# too, and a server that sent one did answer. It is checked before "Permission
# denied", which a firewall refusing the connection prints as well.
ssh_failure_status() {
    case "$1" in
        *"IDENTIFICATION HAS CHANGED"*|*"Host key verification failed"*) echo "STATUS=HOST_KEY_CHANGED" ;;
        *"ssh: connect to host "*|*"ssh: Could not resolve host"*|*"Connection timed out during banner exchange"*)
            echo "STATUS=UNREACHABLE" ;;
        *"Permission denied"*) echo "STATUS=NOT_AUTHORIZED" ;;
        *) echo "STATUS=FAILED"; echo "DETAIL=$(printf '%s' "$1" | head -1)" ;;
    esac
}

# record_key <file> — this project connects with this key from now on.
record_key() {
    local tmp
    tmp=$(mktemp)
    jq --arg k "$1" '.ssh.key_path = $k' "$CONFIG_PATH" > "$tmp" && mv "$tmp" "$CONFIG_PATH"
    chmod 600 "$CONFIG_PATH"
}

# needs_authorization <file> <created: 0|1> — the public key, for whoever has
# access to the hosting to authorize. It goes to the chat and nowhere else.
# Derived from the private key: a .pub can be missing, or from another key.
needs_authorization() {
    local pub
    pub=$(ssh-keygen -y -P '' -f "$1")
    echo "STATUS=NEEDS_AUTHORIZATION"
    echo "KEY_FILE=$1"
    echo "KEY_CREATED=$2"
    echo "PUBLIC_KEY=${pub}"
}

# ── commands ─────────────────────────────────────────────────────────────

cmd_platform() {
    if [[ "$(uname -s)" != "Darwin" ]]; then echo "STATUS=UNSUPPORTED_OS"; exit 3; fi
    local v major
    v=$(sw_vers -productVersion); major="${v%%.*}"
    # macOS 15 is the first to ship /usr/bin/jq, which every script relies on.
    if (( major < 15 )) || [[ ! -x /usr/bin/jq ]]; then
        echo "STATUS=MACOS_TOO_OLD"; echo "VERSION=${v}"; exit 3
    fi
    echo "STATUS=OK"
}

cmd_inspect() {
    local file="${1:-}" problem
    problem=$(access_problem "$file")
    if [[ -n "$problem" ]]; then echo "STATUS=INVALID"; echo "REASON=${problem}"; exit 2; fi
    echo "STATUS=OK"
    jq -r '"SITE=\(.site.url)\(.site.subpath // "")",
           "SERVER=\(.ssh.user)@\(.ssh.host):\(.ssh.port)",
           "REMOTE_PATH=\(.path)",
           "CREATED_BY=\(.created_by // "")",
           "CREATED_AT=\(.created_at // "")"' "$file"
}

cmd_setup() {
    local file="${1:-}" project="" identity="" cfg old problem
    shift || true
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --project)  project="$2";  shift 2 ;;
            --identity) identity="$2"; shift 2 ;;
            *) err "Unknown arg: $1"; exit 2 ;;
        esac
    done
    [[ -n "$project" && -d "$project" ]] || { err "--project <dir> is required"; exit 2; }
    problem=$(access_problem "$file")
    if [[ -n "$problem" ]]; then echo "STATUS=INVALID"; echo "REASON=${problem}"; exit 2; fi
    [[ -n "$identity" ]] || identity=$(id -F 2>/dev/null || true)
    [[ -n "$identity" ]] || identity=$(id -un)

    cfg="${project%/}/.deploy/ssh.json"
    mkdir -p "${project%/}/.deploy"
    old='{}'
    if jq -e 'type == "object"' "$cfg" >/dev/null 2>&1; then old=$(cat "$cfg"); fi
    # Only what the file carries, plus the choices already made here (key,
    # mode, local environment) when this runs again. Never a database section:
    # this machine never gets the production password.
    ( umask 077
      jq -n --slurpfile a "$file" --argjson old "$old" --arg id "$identity" '
        $a[0] as $a
        | {ssh: ({host: $a.ssh.host, port: $a.ssh.port, user: $a.ssh.user, remote_path: $a.path}
                 + (if $old.ssh.key_path then {key_path: $old.ssh.key_path} else {} end)),
           site: {url: $a.site.url, subpath: ($a.site.subpath // "")},
           identity: $id,
           access: {created_by: $a.created_by}}
        + (if $a.remote.php_bin then {remote: {php_bin: $a.remote.php_bin}}
           elif $old.remote then {remote: $old.remote} else {} end)
        + (if $a.rsync.theme_extra_excludes then {rsync: {theme_extra_excludes: $a.rsync.theme_extra_excludes}}
           elif $old.rsync then {rsync: $old.rsync} else {} end)
        + (if $old.mode then {mode: $old.mode} else {} end)
        + (if $old.local then {local: $old.local} else {} end)' > "${cfg}.tmp" )
    mv "${cfg}.tmp" "$cfg"
    chmod 600 "$cfg"
    touch "${project%/}/.gitignore"
    grep -qxF '.deploy/' "${project%/}/.gitignore" || echo '.deploy/' >> "${project%/}/.gitignore"
    echo "STATUS=CONFIGURED"
    echo "CONFIG=${cfg}"
    echo "IDENTITY=${identity}"
}

cmd_key() {
    local key="" candidate out code status
    project_args "$@"
    [[ ${#REST[@]} -eq 0 ]] || { err "Unknown arg: ${REST[0]}"; exit 2; }

    # Before asking anyone to authorize anything: maybe it already works, with
    # the configured key or with what ssh offers by itself. And when the server
    # doesn't answer, or its identity changed, no key would help: say so before
    # creating or recording anything.
    set +e
    out=$(access_ssh true 2>&1 >/dev/null)
    code=$?
    set -e
    if (( code == 0 )); then
        echo "STATUS=AUTHORIZED"
        echo "KEY_FILE=$(cfg_get '.ssh.key_path')"
        return 0
    fi
    status=$(ssh_failure_status "$out")
    case "$status" in
        STATUS=UNREACHABLE|STATUS=HOST_KEY_CHANGED) echo "$status"; exit 4 ;;
    esac

    # The computer's key, one for every site this Mac connects to. A key with
    # a passphrase doesn't count: every non-interactive ssh fails with it.
    for candidate in "$(cfg_get '.ssh.key_path')" "${HOME}/.ssh/id_ed25519" \
                     "${HOME}/.ssh/id_rsa" "${HOME}/.ssh/velk_ed25519"; do
        candidate="${candidate/#\~/$HOME}"
        if [[ -n "$candidate" ]] && key_is_usable "$candidate"; then key="$candidate"; break; fi
    done

    if [[ -z "$key" ]]; then
        # None: create one — ~/.ssh/id_ed25519, unless something already sits
        # there (a key with a passphrase, a lone .pub, a link).
        key="${HOME}/.ssh/id_ed25519"
        if key_path_taken "$key"; then key="${HOME}/.ssh/velk_ed25519"; fi
        if key_path_taken "$key"; then
            echo "STATUS=FAILED"
            echo "DETAIL=no usable key, and ~/.ssh/id_ed25519 and ~/.ssh/velk_ed25519 are both taken (a key with a passphrase, or another file)"
            exit 4
        fi
        mkdir -p "${HOME}/.ssh"; chmod 700 "${HOME}/.ssh"
        ssh-keygen -q -t ed25519 -N '' -f "$key" \
            -C "velk $(ascii_slug "$(cfg_get '.identity')") $(date +%Y-%m-%d)" </dev/null
        ok "Created ${key}"
        record_key "$key"
        # A key created just now can't be authorized yet.
        needs_authorization "$key" 1
        return 0
    fi

    record_key "$key"
    set +e
    out=$(access_ssh true 2>&1 >/dev/null)
    code=$?
    set -e
    if (( code == 0 )); then echo "STATUS=AUTHORIZED"; echo "KEY_FILE=${key}"; return 0; fi
    status=$(ssh_failure_status "$out")
    if [[ "$status" == "STATUS=NOT_AUTHORIZED" ]]; then needs_authorization "$key" 0; return 0; fi
    # Some other failure (step 0 already stopped at an unreachable server or a
    # changed identity): authorizing a key wouldn't help, so say what it was.
    printf '%s\n' "$status"
    echo "KEY_FILE=${key}"
    exit 4
}

cmd_test() {
    local out code
    project_args "$@"
    [[ ${#REST[@]} -eq 0 ]] || { err "Unknown arg: ${REST[0]}"; exit 2; }
    set +e
    out=$(access_ssh true 2>&1 >/dev/null)
    code=$?
    set -e
    if (( code == 0 )); then echo "STATUS=AUTHORIZED"; return 0; fi
    ssh_failure_status "$out"
    exit 4
}

cmd_mode() {
    local mode="${1:-}" tmp
    shift || true
    case "$mode" in local|live) ;; *) err "mode must be local or live"; exit 2 ;; esac
    project_args "$@"
    [[ ${#REST[@]} -eq 0 ]] || { err "Unknown arg: ${REST[0]}"; exit 2; }
    tmp=$(mktemp)
    jq --arg m "$mode" '.mode = $m' "$CONFIG_PATH" > "$tmp" && mv "$tmp" "$CONFIG_PATH"
    chmod 600 "$CONFIG_PATH"
    echo "STATUS=MODE_SET"
    echo "MODE=${mode}"
}

cmd="${1:-}"
shift || true
case "$cmd" in
    mode)     cmd_mode "$@" ;;
    platform) cmd_platform ;;
    inspect)  cmd_inspect "$@" ;;
    setup)    cmd_setup "$@" ;;
    key)      cmd_key "$@" ;;
    test)     cmd_test "$@" ;;
    *) err "Usage: connect.sh platform | inspect <file> | setup <file> --project <dir> | key --project <dir> | test --project <dir> | mode local|live --project <dir>"; exit 2 ;;
esac
