#!/usr/bin/env bash
# init.sh --project <dir> [--config <ssh.json>]
#
# First-time deploy: rsync project + dump+restore DB + generate prod .env +
# write robots.txt + create top-level shim/.htaccess so Hostinger serves
# Velk correctly without needing a custom DocumentRoot.
#
# Hard guarantee: refuses if Velk already exists at target. There is no --force.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../ssh-lib.sh
source "${SCRIPT_DIR}/../ssh-lib.sh"

project_args "$@"
[[ ${#REST[@]} -eq 0 ]] || { err "Unknown arg: ${REST[0]}"; exit 2; }
cd "$PROJECT_DIR"      # everything below is relative to the project root

build_ssh_args
remote_path=$(remote_path)

step "init deploy → ${ssh_target}:${remote_path}"

# --- 1) Refuse if Velk already exists ---
# Only EMPTY or MISSING (no folder yet — init creates it) lets init go on. A
# login banner on stdout, anything unexpected, must not pass for "empty":
# init would then rsync over a live site and import a database on top of it.
target_state
case "$TARGET_STATE" in
    EMPTY|MISSING) ok "Target empty — proceeding" ;;
    EXISTS)
        err "Velk já está instalado em ${remote_path}."
        err "init sobrescreveria o site em produção (DB + arquivos) — bloqueado."
        err "Para alterações, use update-cms.sh ou scripts/theme/publish.sh run."
        err "Se você realmente quer recomeçar do zero, apague o conteúdo de ${remote_path} manualmente primeiro."
        exit 1 ;;
    *) refuse_unreadable_target ;;
esac

# --- 1b) Refuse to ship an edited engine ---
# init is the only deploy that uploads the local project wholesale, core/
# included. An edited engine would go live and then vanish on the next
# upgrade, so the local engine must be exactly its published release.
step "Checking the local engine against its published release"
set +e
engine_report=$(bash "${SCRIPT_DIR}/../check-engine.sh" --project .)
engine_code=$?
set -e
echo "$engine_report" | sed 's/^/  /' >&2
if (( engine_code == 1 )); then
    err "The local engine was edited (listed above). init refuses to deploy it."
    err "Engine paths are replaced wholesale on upgrade: move the change into theme/ or theme/functions.php."
    exit 1
elif (( engine_code != 0 )); then
    err "Could not verify the local engine against its release — nothing was sent."
    exit 1
fi
ok "Engine matches the published release"

# --- 1c) Source leftovers ---
# A theme-convert works from the original site in _source/ and generates the
# theme beside it (references/theme-convert.md). Neither belongs on the
# server: the source pages aren't templates, and init uploads the whole
# project root. Refused here, before anything is sent — a refusal halfway
# would leave a target init can no longer retry.
step "Checking for source leftovers"
leftovers=()
while IFS= read -r f; do
    leftovers+=("$f")
done < <(theme_leftovers theme)
if [[ -d _source ]] && ! jq -e '(.rsync.extra_excludes // []) | any(. == "_source" or . == "_source/")' "$CONFIG_PATH" >/dev/null; then
    leftovers+=("_source/")
fi
if (( ${#leftovers[@]} > 0 )); then
    err "Source files would be deployed as part of the site — nothing was sent:"
    printf '  %s\n' "${leftovers[@]}" >&2
    in_theme=0 in_source=0
    for f in "${leftovers[@]}"; do
        case "$f" in theme/*) in_theme=1 ;; _source/) in_source=1 ;; esac
    done
    if (( in_theme )); then
        err "theme/ holds only site.json, functions.php and the theme's folders: remove the original pages."
    fi
    if (( in_source )); then
        err "Delete _source/ (or move it out of the project) once the conversion is approved, or list it in rsync.extra_excludes."
    fi
    exit 1
fi
ok "No source leftovers"

# --- 2) Resolve config values needed for the deploy ---
domain=$(cfg_get '.site.domain')
app_url=$(cfg_get '.site.url')
subpath=$(cfg_get '.site.subpath' '')
db_name=$(cfg_get '.db.name')
db_user=$(cfg_get '.db.user')
db_pass=$(cfg_get '.db.password')
db_host=$(cfg_get '.db.host' 'localhost')
local_db_name=$(cfg_get '.local.db_name')

[[ -z "$app_url" || -z "$db_name" ]] && die "Config missing required fields (site.url, db.name)"

# Strip trailing slash from app_url
app_url="${app_url%/}"
# app_url is the origin (APP_URL never carries the subdirectory — that's
# APP_BASE_PATH); site_url is where the site answers, subpath included.
site_url=$(site_base_url)

# --- 3) Dump local DB ---
# Through an option file (local_db_defaults): the password never sits on a
# command line. The dump holds the whole database, admin password hashes
# included, so on this Mac too only its owner can read it.
step "Dumping local DB '${local_db_name}'"
[[ -n "$local_db_name" ]] || die "local.db_name must be set in config"
mysqldump_bin=$(cfg_get '.local.mysql_bin'); mysqldump_bin="${mysqldump_bin:+$(dirname "$mysqldump_bin")/mysqldump}"
[[ -n "$mysqldump_bin" && -x "$mysqldump_bin" ]] || mysqldump_bin=mysqldump
dump_file=$(umask 077; mktemp "${TMPDIR:-/tmp}/velk-init-$(date +%Y%m%d-%H%M%S).XXXXXX") || die "mktemp failed"
db_opt=$(local_db_defaults)
# A MySQL with GTIDs on (Homebrew's, among others) writes SET @@SESSION.SQL_LOG_BIN
# and @@GLOBAL.GTID_PURGED at the top of the dump. Importing those needs
# BINLOG ADMIN, which a shared-hosting user never has: the import fails AFTER
# the files and .env are up, and init then refuses to run again. MariaDB's
# mysqldump has no such option (and writes no such lines), hence the probe.
# Not `--help | grep -q`: under pipefail, grep quitting early SIGPIPEs
# mysqldump and the test reads false even when the option exists.
dump_flags=(--no-tablespaces --single-transaction)
if [[ "$("$mysqldump_bin" --help 2>/dev/null || true)" == *--set-gtid-purged* ]]; then
    dump_flags+=(--set-gtid-purged=OFF)
fi
if ! "$mysqldump_bin" --defaults-extra-file="$db_opt" "${dump_flags[@]}" "$local_db_name" > "$dump_file"; then
    err "mysqldump failed. Check local.* config."
    rm -f "$dump_file" "$db_opt"
    exit 1
fi
rm -f "$db_opt"
dump_size=$(wc -c < "$dump_file")
ok "Dump: ${dump_file} (${dump_size} bytes)"

# --- 4) Rsync project files ---
step "Rsync project files"
rsh=$(rsync_remote_shell)
rsync_dest=$(rsync_target_for "$remote_path")

# Build exclude list. Defaults + user-supplied extras.
excludes=(
    --exclude=.env
    --exclude=.env.*
    --exclude=.git/
    --exclude=.github/
    --exclude=.deploy/
    --exclude=.claude/
    --exclude=.metrik/
    --exclude=.DS_Store
    --exclude=Thumbs.db
    --exclude=node_modules/
    # dev-only — versioned in git but not shipped to production (mirrors the WordPress build)
    --exclude=tests/
    --exclude=docs/
    --exclude=storage/cache/*
    --exclude=storage/logs/*
    --exclude=*.bak
    --exclude=*.swp
)
# No theme/*.php here on purpose: it used to hide pages left over from a
# theme-convert, and took theme/functions.php down with them — the first
# deploy shipped a theme without its code. Leftovers are refused before the
# dump instead (see "Source leftovers" above), so what's in theme/ is the theme.

# Append user-provided extra excludes
while IFS= read -r ex; do
    [[ -n "$ex" ]] && excludes+=("--exclude=$ex")
done < <(jq -r '.rsync.extra_excludes[]? // empty' "$CONFIG_PATH")

# Ensure remote dir exists
"${ssh_args[@]}" "mkdir -p $(shell_quote "$remote_path")"

# Rsync project root → remote
if ! rsync -avz --delete-after \
    "${excludes[@]}" \
    -e "$rsh" \
    "./" "${rsync_dest}/" >&2; then
    err "rsync failed"
    rm -f "$dump_file"
    exit 1
fi
ok "Files synced"

# --- 5) Generate and upload .env (prod) ---
step "Writing remote .env"
env_tmp=$(mktemp)
cat > "$env_tmp" <<EOF
# Generated by velk-deploy-hostinger init on $(date -u +%Y-%m-%dT%H:%M:%SZ)
APP_NAME="${domain}"
APP_URL="${app_url}"
APP_DEBUG=false
APP_TIMEZONE=America/Sao_Paulo
APP_LOCALE=pt_BR
EOF
if [[ -n "$subpath" && "$subpath" != "/" ]]; then
    echo "APP_BASE_PATH=\"${subpath}\"" >> "$env_tmp"
fi
cat >> "$env_tmp" <<EOF

DB_DRIVER=mysql
DB_HOST=${db_host}
DB_PORT=3306
DB_DATABASE=${db_name}
DB_USERNAME=${db_user}
DB_PASSWORD="${db_pass}"

SESSION_NAME=nano_session
SESSION_LIFETIME=604800

SMTP_HOST=""
SMTP_PORT=587
SMTP_USER=""
SMTP_PASS=""
SMTP_FROM="${domain} <noreply@${domain}>"
EOF

# Use scp via the same alias/direct args
if [[ -n "$(cfg_get '.ssh.alias')" ]]; then
    scp -q "$env_tmp" "$(cfg_get '.ssh.alias'):${remote_path}/.env"
else
    port=$(cfg_get '.ssh.port' '22')
    key=$(cfg_get '.ssh.key_path' "$HOME/.ssh/id_ed25519")
    key="${key/#\~/$HOME}"
    user=$(cfg_get '.ssh.user')
    host=$(cfg_get '.ssh.host')
    scp -q -P "$port" -i "$key" "$env_tmp" "${user}@${host}:${remote_path}/.env"
fi
rm -f "$env_tmp"
"${ssh_args[@]}" "chmod 0640 $(shell_quote "${remote_path}/.env")"
ok ".env written and chmod 0640"

# --- 6) Upload SQL dump and import ---
step "Uploading dump and importing into '${db_name}'"
# A fresh name in the server's /tmp that only its owner can read: the dump
# holds the whole database, admin password hashes included.
if ! remote_dump_path=$("${ssh_args[@]}" "mktemp /tmp/velk-init-import.XXXXXX" </dev/null) \
   || ! "${ssh_args[@]}" "cat > $(shell_quote "$remote_dump_path")" < "$dump_file"; then
    err "Uploading the dump failed."
    rm -f "$dump_file"
    exit 1
fi

# With the credentials of the .env just written (scripts/remote/db.sh): the
# password never sits on a command line. It deletes the uploaded dump.
if ! remote_script "${SCRIPT_DIR}/../remote/db.sh" import "$remote_path" "$(resolve_php_bin)" "$remote_dump_path"; then
    err "MySQL import failed — see above."
    rm -f "$dump_file"
    exit 1
fi
ok "DB imported"
rm -f "$dump_file"

# --- 7) Run migrate (idempotent — catches any schema gap between dump and current code) ---
# remote_velk runs it with the PHP the config names (`.remote.php_bin`) —
# cPanel hosts routinely need /opt/cpanel/ea-phpXX/root/usr/bin/php.
step "Running bin/velk migrate"
set +e
mig_out=$(remote_velk migrate 2>&1 </dev/null)
mig_code=$?
set -e
echo "$mig_out" | sed 's/^/  /' >&2
# Files and database are already up, so init refuses a second run: the way
# back is an empty target (references/deploy.md, "Retries are safe").
(( mig_code == 0 )) || die "bin/velk migrate failed on the remote (exit ${mig_code}) — see above. The files and the database are already on the server, so init will not run again: fix the cause, have the user empty ${remote_path}, then run preflight and init."
ok "Migrations OK"

# --- 8) Overwrite robots.txt with prod sitemap URL ---
# Velk's flat layout puts robots.txt at the project root. The rsync above
# already shipped a robots.txt (copied by Installer from robots.txt.example)
# but it points at example.com — overwrite with the real APP_URL.
# No Disallow for the admin (engine v3.8.1+): the admin answers
# `X-Robots-Tag: noindex`, which a crawler only sees if it may fetch the
# page — and robots.txt is public, so listing the admin gives its path away.
step "Writing robots.txt with production sitemap URL"
robots_tmp=$(mktemp)
cat > "$robots_tmp" <<EOF
User-agent: *
Allow: /

Sitemap: ${site_url}/sitemap.xml
EOF
if [[ -n "$(cfg_get '.ssh.alias')" ]]; then
    scp -q "$robots_tmp" "$(cfg_get '.ssh.alias'):${remote_path}/robots.txt"
else
    port=$(cfg_get '.ssh.port' '22')
    key=$(cfg_get '.ssh.key_path' "$HOME/.ssh/id_ed25519")
    key="${key/#\~/$HOME}"
    user=$(cfg_get '.ssh.user')
    host=$(cfg_get '.ssh.host')
    scp -q -P "$port" -i "$key" "$robots_tmp" "${user}@${host}:${remote_path}/robots.txt"
fi
rm -f "$robots_tmp"
ok "robots.txt written with Sitemap: ${site_url}/sitemap.xml"
# Crawlers read robots.txt only at the host's root. On a subdirectory install
# this file is never fetched: the sitemap has to be declared in the root's
# robots.txt (someone else's site) or sent through Search Console.
if [[ "$site_url" != "$app_url" ]]; then
    warn "Subdirectory install: crawlers never read ${site_url}/robots.txt — declare ${site_url}/sitemap.xml in ${app_url}/robots.txt or in Search Console."
fi

# Note: no top-level shim needed. Velk's flat layout puts index.php and
# .htaccess at the project root already (rsynced from local), so Apache
# serves them directly. The .htaccess shipped with Velk blocks core/, bin/,
# migrations/, theme/*.php, .env, etc.

# --- 9) Verify with curl ---
step "Verifying ${site_url}"
http_code=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 15 -L "${site_url}/" || echo 000)
if [[ "$http_code" == "200" ]]; then
    ok "HTTP 200 OK"
else
    warn "HTTP ${http_code} — site may need a moment to warm up. Check manually: ${site_url}"
fi

echo
ok "Init deploy complete."
echo
echo "  Site:   ${site_url}"
echo "  Admin:  ${site_url}/admin/login"
echo "  Path:   ${remote_path}"
echo
echo "Próximos passos:"
echo "  - Acessa o admin e confirma que o conteúdo migrou"
echo "  - Configurar SMTP em .env se forms forem enviar e-mail"
echo "  - Para mudanças de tema:  scripts/theme/publish.sh run --project ${PROJECT_DIR}"
echo "  - Para mudanças de core:  scripts/deploy/update-cms.sh --project ${PROJECT_DIR}"
