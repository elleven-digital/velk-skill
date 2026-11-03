#!/usr/bin/env bash
# generate.sh --project <dir> [--config <ssh.json>] [--created-by <name>] [--out <dir>]
#
# Writes <domain>.velk: what a client needs to connect to this site, and
# nothing else. The file is assembled field by field from an allowlist —
# never copied from the config, which holds the production database password —
# then re-read by leak-check.pl. It contains no secret: access only exists once
# someone authorizes the public key of the client's machine.
#
# stdout: ACCESS_FILE=<path>
# Exit:   0 written · 2 bad input · 3 the check found a leak (file deleted)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../ssh-lib.sh
source "${SCRIPT_DIR}/../ssh-lib.sh"

project_args "$@"
created_by="" out_dir=""
set -- ${REST[@]+"${REST[@]}"}
while [[ $# -gt 0 ]]; do
    case "$1" in
        --created-by) created_by="$2";  shift 2 ;;
        --out)        out_dir="$2";     shift 2 ;;
        *) err "Unknown arg: $1"; exit 2 ;;
    esac
done

# The client has none of the agency's ~/.ssh/config, so an alias is resolved
# here to the real server, port and user.
alias_name=$(cfg_get '.ssh.alias')
if [[ -n "$alias_name" ]]; then
    resolved=$(ssh -G "$alias_name") || { err "ssh -G ${alias_name} failed"; exit 2; }
    host=$(awk '$1 == "hostname" {print $2; exit}' <<< "$resolved")
    port=$(awk '$1 == "port" {print $2; exit}' <<< "$resolved")
    user=$(awk '$1 == "user" {print $2; exit}' <<< "$resolved")
else
    host=$(cfg_get '.ssh.host'); port=$(cfg_get '.ssh.port' '22'); user=$(cfg_get '.ssh.user')
fi
path=$(cfg_get '.ssh.remote_path')
php_bin=$(cfg_get '.remote.php_bin')
excludes=$(jq -c '.rsync.theme_extra_excludes // []' "$CONFIG_PATH")
url=$(cfg_get '.site.url'); url="${url%/}"
subpath=$(cfg_get '.site.subpath' '')
[[ -n "$host" && -n "$user" && -n "$path" && -n "$url" ]] \
    || { err "Config needs ssh host/user (or alias), ssh.remote_path and site.url"; exit 2; }
[[ "$port" =~ ^[0-9]+$ ]] || { err "ssh port is not a number: ${port}"; exit 2; }
[[ -n "$created_by" ]] || created_by=$(cfg_get '.identity')
[[ -n "$created_by" ]] || created_by=$(id -F 2>/dev/null || id -un)

domain="${url#*://}"; domain="${domain%%/*}"; domain="${domain%%:*}"
[[ -n "$out_dir" ]] || out_dir="$PROJECT_DIR"
file="${out_dir%/}/${domain}.velk"

jq -n \
    --arg url "$url" --arg subpath "$subpath" \
    --arg host "$host" --argjson port "$port" --arg user "$user" \
    --arg path "$path" \
    --arg created_by "$created_by" --arg created_at "$(date +%Y-%m-%d)" \
    --arg php_bin "$php_bin" --argjson excludes "$excludes" \
    '{velk_access: 1,
      site: {url: $url, subpath: $subpath},
      ssh: {host: $host, port: $port, user: $user},
      path: $path,
      created_by: $created_by,
      created_at: $created_at}
     + (if $php_bin != "" then {remote: {php_bin: $php_bin}} else {} end)
     + (if ($excludes | length) > 0 then {rsync: {theme_extra_excludes: $excludes}} else {} end)' > "$file"

# The client's side refuses a malformed file; better to find out here.
if ! inspected=$(bash "${SCRIPT_DIR}/connect.sh" inspect "$file" 2>/dev/null); then
    rm -f "$file"
    err "The config holds a value the client would refuse ($(sed -n 's/^REASON=//p' <<< "$inspected")) — fix it and generate again."
    exit 2
fi

set +e
problems=$(perl "${SCRIPT_DIR}/leak-check.pl" --config "$CONFIG_PATH" --file "$file")
code=$?
set -e
if (( code != 0 )); then
    rm -f "$file"
    err "The access file failed its safety check and was deleted:"
    printf '%s\n' "$problems" | sed 's/^/  /' >&2
    exit 3
fi
ok "Access file written: ${file}"
echo "ACCESS_FILE=${file}"
