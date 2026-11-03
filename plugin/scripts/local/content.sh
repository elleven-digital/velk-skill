#!/usr/bin/env bash
# content.sh --project <dir> [--take-over-stale] [--discard-theme-changes]
#
# "Local" mode's copy of the site, for building and previewing:
#   - the engine from the PUBLISHED release the server runs (never copied from
#     the server), so it passes check-engine by construction;
#   - the live theme, with its starting point for the next publish;
#   - storage/uploads/ — never storage/form-uploads/ (lead attachments);
#   - a local .env with no production secret;
#   - the data of the content tables only. Personal and security tables stay
#     empty; form_recipients too (a local test never emails the real
#     recipient) and tracking_scripts (localhost never fires the client's
#     pixels), and form conversion snippets are cleared for the same reason;
#   - a local-only admin, created here.
# Needs env.sh first (PHP + MySQL). Run again, it refreshes everything —
# except a theme with changes not yet published: then it stops before
# touching anything (a refresh would overwrite them), unless
# --discard-theme-changes says, after asking, to throw them away.
#
# stdout: STATUS=READY, URL, ADMIN_EMAIL, ADMIN_PASSWORD, SERVE, RECOVERED=<action>…,
#         WARN=… — or, with exit 4, STATUS=LOCAL_CHANGES and a LOCAL_CHANGE=<path>
#         line per changed theme file — or, with exit 5, download-theme's
#         STATUS=BUSY / STATUS=STALE_LOCK (someone else's publish; a stale
#         lock is taken over only with --take-over-stale, after asking)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../theme/_lib.sh
source "${SCRIPT_DIR}/../theme/_lib.sh"
# shellcheck source=../release-lib.sh
source "${SCRIPT_DIR}/../release-lib.sh"

CONTENT_TABLES=(items item_term terms pages media settings languages
                config_translations theme_strings form_settings)

project_args "$@"
take_stale="" discard_theme=""
for a in ${REST[@]+"${REST[@]}"}; do
    case "$a" in
        --take-over-stale)       take_stale=--take-over-stale ;;
        --discard-theme-changes) discard_theme=1 ;;
        *) err "Unknown arg: $a"; exit 2 ;;
    esac
done
build_ssh_args
project="$PROJECT_DIR"

# A theme changed here since its starting point — or, without one, differing
# from what is live — holds work not yet published: the refresh below would
# overwrite it. Nothing is touched until the person decides.
if [[ -z "$discard_theme" && -d "${project}/theme" ]]; then
    load_theme_filters
    if [[ -f "${project}/.deploy/theme-base.json" ]]; then reference=$(cat "${project}/.deploy/theme-base.json")
    else reference=$(remote_theme_manifest) || die "Could not read the live theme."
    fi
    changed=$(perl "$MANIFEST_PL" diff <(printf '%s' "$reference") <(local_theme_manifest "${project}/theme") \
              | jq -r '(.added + .changed + .removed)[]')
    if [[ -n "$changed" ]]; then
        echo "STATUS=LOCAL_CHANGES"
        sed 's/^/LOCAL_CHANGE=/' <<< "$changed"
        exit 4
    fi
fi
rp=$(remote_path)
remote_php=$(resolve_php_bin)

php=$(cfg_get '.local.php_bin'); [[ -n "$php" ]] || php=$(command -v php || true)
mysql=$(cfg_get '.local.mysql_bin'); [[ -n "$mysql" ]] || mysql=$(command -v mysql || true)
[[ -x "$php" && -x "$mysql" ]] || die "PHP and MySQL are needed locally — run scripts/local/env.sh first."

set_config() {   # set_config <jq-path> <value>
    local tmp
    tmp=$(mktemp)
    jq --arg v "$2" "$1 = \$v" "$CONFIG_PATH" > "$tmp" && mv "$tmp" "$CONFIG_PATH"
    chmod 600 "$CONFIG_PATH"
}

# ── engine, from the release the server runs ─────────────────────────────
server_version_json=$("${ssh_args[@]}" "cat $(shell_quote "${rp}/.velk-version")") \
    || die "The server has no .velk-version — which release does it run?"
version=$(jq -r '.version // empty' <<< "$server_version_json")
base=$(jq -r --arg d "$VELK_DEFAULT_RELEASE_BASE" '.release_base_url // $d' <<< "$server_version_json")
[[ -n "$version" ]] || die "The server's .velk-version has no version."

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
step "Fetching the engine ${version}"
src=$(fetch_release "$version" "$base" "$work")

# .gitignore is the client's here (it keeps .deploy/ out of git), never the
# engine's — skipped when copying and when cleaning up; and a path naming the
# project itself ("", ".", "./") never gets synced over it or removed.
while IFS= read -r p; do
    case "$p" in ""|.|./|/*|*..*|.gitignore) continue ;; esac
    if [[ "$p" == */ ]]; then
        [[ -d "${src}/${p}" ]] || continue
        mkdir -p "${project}/${p}"
        rsync -a --delete "${src}/${p}" "${project}/${p}"
    elif [[ -f "${src}/${p}" ]]; then
        mkdir -p "$(dirname "${project}/${p}")"
        cp "${src}/${p}" "${project}/${p}"
    fi
done < <(jq -r '.engine_paths[]' "${src}/engine-manifest.json")
jq -n --arg v "$version" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg base "$base" \
    '{version: $v, installed_at: $at, release_base_url: $base}' > "${project}/.velk-version"
ok "Engine ${version} in place"

# ── theme and uploads ────────────────────────────────────────────────────
set +e
theme_out=$(bash "${SCRIPT_DIR}/../theme/download-theme.sh" --project "$project" $take_stale)
code=$?
set -e
if (( code == 5 )); then printf '%s\n' "$theme_out"; exit 5; fi    # someone else's publish, as is
(( code == 0 )) || die "Could not download the theme."
step "Downloading storage/uploads/"
mkdir -p "${project}/storage/uploads"
rsync -a --delete -e "$(rsync_remote_shell)" \
    "$(rsync_target_for "${rp}/storage/uploads")/" "${project}/storage/uploads/" >&2 \
    || die "rsync of storage/uploads/ failed"

# ── local .env: public settings from the server, local database, no secret ─
db_name=$(cfg_get '.local.db_name')
if [[ -z "$db_name" ]]; then
    d=$(cfg_get '.site.url'); d="${d#*://}"; d="${d%%/*}"; d="${d%%:*}"
    db_name="velk_$(printf '%s' "$d" | LC_ALL=C tr -c 'A-Za-z0-9' '_' | cut -c1-58)"
fi
db_host=$(cfg_get '.local.db_host' 'localhost')
db_user=$(cfg_get '.local.db_user' 'root')
db_pass=$(cfg_get '.local.db_password')
set_config '.local.db_name' "$db_name"
set_config '.local.db_host' "$db_host"
set_config '.local.db_user' "$db_user"

public_env=$(remote_script "${SCRIPT_DIR}/../remote/db.sh" settings "$rp" "$remote_php") || public_env=""
( umask 077
  {
      echo "# Local copy of $(cfg_get '.site.url'), written by the Velk skill."
      echo "# No production secret here: no SMTP, no Stripe, no Turnstile, not the production database."
      printf '%s\n' "$public_env"
      echo 'APP_URL=""'
      echo 'APP_DEBUG=true'
      echo 'DB_DRIVER=mysql'
      echo "DB_HOST=${db_host}"
      echo 'DB_PORT=3306'
      echo "DB_DATABASE=${db_name}"
      echo "DB_USERNAME=${db_user}"
      echo "DB_PASSWORD=\"${db_pass}\""
  } > "${project}/.env" )
chmod 600 "${project}/.env"

# ── database: schema from the engine, then the content ───────────────────
admin_email=$(cfg_get '.local.admin_email' 'admin@local.test')
admin_pass=$(cfg_get '.local.admin_password')
if [[ -z "$admin_pass" ]]; then
    admin_pass=$(head -c 256 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-20)
fi
set_config '.local.admin_email' "$admin_email"
set_config '.local.admin_password' "$admin_pass"

step "Creating the local database and admin"
# install is idempotent: it creates what's missing and leaves an existing
# admin alone, so running this again refreshes without a second admin.
( cd "$project" && "$php" bin/velk install --email="$admin_email" --password="$admin_pass" --name="Local admin" ) >&2 \
    || die "bin/velk install failed locally."
while IFS= read -r p; do
    case "$p" in ""|.|./|/*|*..*|.gitignore) continue ;; esac
    rm -rf "${project:?}/${p%/}"
done < <(jq -r '.post_install_cleanup[]? // empty' "${src}/engine-manifest.json")

step "Copying the content tables"
dump="${work}/content.sql"
remote_script "${SCRIPT_DIR}/../remote/db.sh" dump "$rp" "$remote_php" "${CONTENT_TABLES[@]}" > "$dump" \
    || die "The content dump failed on the server."
db_opt=$(local_db_defaults)      # the password in an option file, never on a command line
{
    echo "SET FOREIGN_KEY_CHECKS=0;"
    for t in "${CONTENT_TABLES[@]}"; do echo "TRUNCATE TABLE \`${t}\`;"; done
    cat "$dump"
    echo "UPDATE \`form_settings\` SET \`conversion_snippet\` = NULL;"
    echo "SET FOREIGN_KEY_CHECKS=1;"
} | "$mysql" --defaults-extra-file="$db_opt" "$db_name" || { rm -f "$db_opt"; die "Importing the content into ${db_name} failed."; }
rm -f "$db_opt"

touch "${project}/.gitignore"
grep -qxF '.deploy/' "${project}/.gitignore" || echo '.deploy/' >> "${project}/.gitignore"

ok "Local copy ready"
echo "STATUS=READY"
echo "URL=http://localhost:8080"
echo "ADMIN_EMAIL=${admin_email}"
echo "ADMIN_PASSWORD=${admin_pass}"
echo "SERVE=${php} bin/velk serve 8080"
grep -E '^(RECOVERED|WARN)=' <<< "$theme_out" || true
