#!/usr/bin/env bash
# env.sh check|install --project <dir>
#
# The local environment for "local" mode: PHP + MySQL. No Apache — `bin/velk
# serve` is PHP's built-in server. PHP must match production's major.minor:
# code that runs clean on 8.5 here (array_find, say) is a fatal error on an
# 8.2 server, which Velk supports.
#
# check   → STATUS=READY|NEEDS_INSTALL|NEEDS_BREW first, then PRODUCTION_PHP,
#           FORMULA, BREW, LOCAL_PHP, LOCAL_PHP_VERSION, PHP_MATCH=yes|no, MYSQL
# install → STATUS=INSTALLED, LOCAL_PHP, MYSQL [, WARN=PHP_VERSION_MISMATCH];
#           without Homebrew: STATUS=NEEDS_BREW + INSTALL_COMMAND (exit 3) —
#           its installer asks for the Mac's password, which only the user
#           can type, in Terminal.
# Run install only after the user said yes.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../theme/_lib.sh
source "${SCRIPT_DIR}/../theme/_lib.sh"

BREW_INSTALL_COMMAND='/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'

action="${1:-}"
shift || true
project_args "$@"
build_ssh_args

# Homebrew lives in one of two places (Apple Silicon, Intel).
find_brew() {
    local b
    for b in ${VELK_BREW_CANDIDATES:-/opt/homebrew/bin/brew /usr/local/bin/brew}; do
        if [[ -x "$b" ]]; then echo "$b"; return 0; fi
    done
    return 1
}
php_version_of() { "$1" -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;' 2>/dev/null; }
set_local() {
    local tmp
    tmp=$(mktemp)
    jq --arg k "$1" --arg v "$2" '.local[$k] = $v' "$CONFIG_PATH" > "$tmp" && mv "$tmp" "$CONFIG_PATH" \
        || die "Could not save .local.$1 in ${CONFIG_PATH}."
    chmod 600 "$CONFIG_PATH"
}

prod=$("${ssh_args[@]}" "$(shell_quote "$(resolve_php_bin)") -d display_errors=stderr -d display_startup_errors=0 -r 'echo PHP_VERSION;'") \
    || die "Could not read the server's PHP version."
prod_mm=$(cut -d. -f1,2 <<< "$prod")
formula="php@${prod_mm}"
brew=$(find_brew || true)

local_php=$(cfg_get '.local.php_bin')
[[ -n "$local_php" && -x "$local_php" ]] || local_php=""
if [[ -z "$local_php" && -n "$brew" && -x "$("$brew" --prefix "$formula")/bin/php" ]]; then
    local_php="$("$brew" --prefix "$formula")/bin/php"
fi
[[ -n "$local_php" ]] || local_php=$(command -v php || true)
local_mm=""
if [[ -n "$local_php" ]]; then local_mm=$(php_version_of "$local_php"); fi
match=no
if [[ -n "$local_mm" && "$local_mm" == "$prod_mm" ]]; then match=yes; fi

mysql_bin=$(cfg_get '.local.mysql_bin')
[[ -n "$mysql_bin" && -x "$mysql_bin" ]] || mysql_bin=$(command -v mysql || true)
if [[ -z "$mysql_bin" && -n "$brew" && -x "$("$brew" --prefix mysql)/bin/mysql" ]]; then
    mysql_bin="$("$brew" --prefix mysql)/bin/mysql"
fi

case "$action" in
    check)
        if [[ "$match" == yes && -n "$mysql_bin" ]]; then status=READY
        elif [[ -n "$brew" ]]; then status=NEEDS_INSTALL
        else status=NEEDS_BREW; fi
        echo "STATUS=${status}"
        echo "PRODUCTION_PHP=${prod}"
        echo "FORMULA=${formula}"
        echo "BREW=${brew}"
        echo "LOCAL_PHP=${local_php}"
        echo "LOCAL_PHP_VERSION=${local_mm}"
        echo "PHP_MATCH=${match}"
        echo "MYSQL=${mysql_bin}"
        if [[ -z "$brew" ]]; then echo "INSTALL_COMMAND=${BREW_INSTALL_COMMAND}"; fi
        ;;
    install)
        if [[ -z "$brew" ]]; then
            echo "STATUS=NEEDS_BREW"
            echo "INSTALL_COMMAND=${BREW_INSTALL_COMMAND}"
            exit 3
        fi
        mismatch=0
        if [[ "$match" != yes ]]; then
            step "Installing ${formula}"
            if "$brew" install "$formula" >&2; then
                local_php="$("$brew" --prefix "$formula")/bin/php"
            else
                warn "Homebrew has no ${formula} — installing the current php instead"
                "$brew" install php >&2 || die "brew install php failed"
                local_php="$("$brew" --prefix php)/bin/php"
                mismatch=1
            fi
        fi
        if [[ -z "$mysql_bin" ]]; then
            step "Installing MySQL"
            "$brew" install mysql >&2 || die "brew install mysql failed"
            mysql_bin="$("$brew" --prefix mysql)/bin/mysql"
        fi
        # Trust nothing Homebrew says: the binaries recorded below must exist.
        [[ -x "$local_php" ]] || die "Homebrew reported success, but there is no PHP at ${local_php}."
        [[ -x "$mysql_bin" ]] || die "Homebrew reported success, but there is no MySQL at ${mysql_bin}."
        "$brew" services start mysql >&2 || warn "Could not start MySQL — run: brew services start mysql"
        set_local php_bin "$local_php"
        set_local mysql_bin "$mysql_bin"
        echo "STATUS=INSTALLED"
        echo "LOCAL_PHP=${local_php}"
        echo "MYSQL=${mysql_bin}"
        if (( mismatch )); then echo "WARN=PHP_VERSION_MISMATCH"; fi
        ;;
    *) err "Usage: env.sh check|install --project <dir>"; exit 2 ;;
esac
