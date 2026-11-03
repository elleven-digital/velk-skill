#!/usr/bin/env bash
# Update the Velk engine on a remote install from a PUBLISHED release.
#
# Downloads the tarball for the target version (--version, else the local
# .velk-version), verifies its sha256, and rsyncs the engine_paths declared
# in that tarball's manifest — never the local working copy. Then runs
# `php bin/velk migrate` and, only if that succeeded, removes the
# post_install_cleanup paths (migrations/ among them) from the server.
#
# Never touches theme/, storage/, .env, or the live .htaccess/robots.txt.
# Refuses if Velk isn't already installed at the target.
#
# update-cms.sh --project <dir> [--config <ssh.json>] [--version vX.Y.Z]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../ssh-lib.sh
source "${SCRIPT_DIR}/../ssh-lib.sh"
# shellcheck source=../release-lib.sh
source "${SCRIPT_DIR}/../release-lib.sh"

project_args "$@"
VELK_VERSION=""
set -- ${REST[@]+"${REST[@]}"}
while [[ $# -gt 0 ]]; do
    case "$1" in
        # Which published version to ship. Defaults to whatever .velk-version
        # says the local install is on.
        --version) VELK_VERSION="$2"; shift 2 ;;
        *) err "Unknown arg: $1"; exit 2 ;;
    esac
done
cd "$PROJECT_DIR"      # everything below is relative to the project root

build_ssh_args
remote_path=$(remote_path)
# Where the site answers, subpath included: on a subdirectory install the
# bare site.url is a different site, and a 200 there proves nothing.
app_url=$(site_base_url)

step "update-cms → ${ssh_target}:${remote_path}"

# --- Refuse if target is empty ---
target_state
case "$TARGET_STATE" in
    EXISTS) ok "Velk detected — proceeding" ;;
    EMPTY|MISSING)
        err "Velk não detectado em ${remote_path}."
        err "update-cms só roda em instalações existentes. Use init.sh para o primeiro deploy."
        exit 1 ;;
    *) refuse_unreadable_target ;;
esac

# --- Fetch the release tarball for the version being deployed ---
#
# The source is a PUBLISHED release, not the local working copy. Three
# things follow from that, and the third is why this changed:
#
#   1. The server receives exactly a released version. What sits in the
#      working folder — a local edit, an uncommitted change — can't leak
#      into a client site by accident.
#   2. The manifest comes from the tarball, which always carries one, so
#      the hand-maintained fallback path list this script used to need is
#      gone. Nothing to drift.
#   3. `migrations/` no longer has to survive in the local install. It is
#      deleted after being applied (it's in post_install_cleanup), and the
#      tarball brings it back whenever a database actually has to move.
#
# Version: --version, else whatever .velk-version says this install is on.
target_version="${VELK_VERSION:-$(version_for .)}"
[[ -n "$target_version" ]] || die "Could not determine which version to deploy. Pass --version vX.Y.Z."

release_base=$(release_base_for .)

# Compara com o que o SERVIDOR roda antes de empurrar. Sem isto, uma cópia
# local desatualizada rebaixa o engine do cliente em silêncio — e o banco
# fica com o schema da versão mais nova, que o código antigo não conhece.
# A v3.5.0, por exemplo, dropa colunas: descer dali é porta de mão única.
remote_version=$("${ssh_args[@]}" "cat $(shell_quote "${remote_path}/.velk-version") 2>/dev/null" | jq -r '.version // empty' 2>/dev/null || true)
if [[ -n "$remote_version" && "$remote_version" != "$target_version" ]]; then
    newest=$(printf '%s\n%s\n' "${remote_version#v}" "${target_version#v}" | sort -V | tail -1)
    if [[ "v${newest}" == "$remote_version" ]]; then
        err "Downgrade blocked: the server runs ${remote_version}, you are deploying ${target_version}."
        err ""
        err "The database keeps the newer schema, which older code doesn't know about."
        err "If you really mean it, pass --version ${remote_version} or newer, or upgrade"
        err "this install first so .velk-version matches what you intend to ship."
        exit 1
    fi
    step "Server is on ${remote_version} → deploying ${target_version}"
fi

step "Fetching ${target_version} from ${release_base}"
tmp_dir=$(mktemp -d)
# shellcheck disable=SC2064
trap "rm -rf '${tmp_dir}'" EXIT
src_dir=$(fetch_release "$target_version" "$release_base" "$tmp_dir")
ok "${target_version} verified and extracted"

# --- Rsync engine ---
# WHAT counts as "the engine" comes from engine-manifest.json (engine_paths) —
# the same source the upgrade path reads — never a list hand-maintained here.
# A hardcoded list drifts silently: config/ joined the engine in v3.2.0, the
# old `for sub in core bin migrations` never learned about it, and sites
# updated to v3.3.0 got a new core/ calling path('form_uploads') against a
# config/env.php that never gained the key — form file uploads failed closed,
# with no error anywhere.
#
# Flat layout, so engine_paths mixes directories (trailing "/") with root
# files. Directories rsync with --delete scoped to themselves — safe, since
# theme/ and storage/ live at the root and are never engine_paths. Root files
# copy without --delete.
#
# The old "don't touch live .htaccess/robots.txt" “rule” needs no special case
# here: those aren't engine_paths at all — only .htaccess.example and
# robots.txt.example are — so deriving from the manifest preserves that
# property for free.
step "Syncing engine paths (from engine-manifest.json)"
rsh=$(rsync_remote_shell)
rsync_dest=$(rsync_target_for "$remote_path")

# Read from the EXTRACTED manifest, which always exists — the tarball
# carries it. No fallback list to hand-maintain, and nothing to drift when
# engine_paths changes upstream.
engine_dirs=()
engine_files=()
while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    if [[ "$p" == */ ]]; then engine_dirs+=("${p%/}"); else engine_files+=("$p"); fi
done < <(jq -r '.engine_paths[]? // empty' "${src_dir}/engine-manifest.json")
(( ${#engine_dirs[@]} + ${#engine_files[@]} > 0 )) || die "engine_paths empty in the tarball manifest."

for sub in "${engine_dirs[@]}"; do
    # Mesma validação que a limpeza faz: este laço usa --delete, então uma
    # entrada como "/" espelharia sobre a raiz da instalação e levaria
    # theme/, storage/ e .env junto. O tarball é verificado por sha256, mas
    # o custo de checar é zero e a assimetria (um laço valida, o outro não)
    # é convite a erro.
    case "$sub" in
        /*|*..*) warn "Skipping suspicious engine path: ${sub}"; continue ;;
    esac
    if [[ ! -d "${src_dir}/$sub" ]]; then
        warn "${sub}/ declared in the manifest but absent from the tarball — skipping"
        continue
    fi
    step "  rsync ${sub}/"
    rsync -avz --delete \
        --exclude='.DS_Store' \
        -e "$rsh" \
        "${src_dir}/${sub}/" "${rsync_dest}/${sub}/" >&2 || die "rsync failed for ${sub}/"
done

step "  rsync root engine files"
root_files=()
for f in "${engine_files[@]}"; do
    case "$f" in
        /*|*..*) warn "Skipping suspicious engine path: ${f}"; continue ;;
        # O .gitignore do tarball é o do repositório do engine, e a limpeza
        # abaixo o apaga: enviá-lo levaria junto o .gitignore do projeto no
        # servidor. Como no content.sh e no check-engine, nunca é do engine.
        .gitignore) continue ;;
    esac
    # `if`, não `[[ ]] && ...`: com set -e, um teste falso na ÚLTIMA iteração
    # vira o status de saída do laço e aborta o script — depois de core/ já
    # ter sido substituído e antes do migrate.
    if [[ -f "${src_dir}/$f" ]]; then
        root_files+=("$f")
    fi
done
# Caminhos RELATIVOS com -R, rodando de dentro do tarball: um arquivo do
# engine dentro de uma pasta (docs/messages.md) chega na mesma pasta. Com
# caminhos absolutos e sem -R o rsync achata tudo no destino, e
# docs/messages.md caía na raiz como messages.md. Não dá para usar o
# marcador `/./` do -R: o openrsync do macOS não o entende e recriaria o
# caminho absoluto inteiro no servidor.
if (( ${#root_files[@]} > 0 )); then
    ( cd "$src_dir" && rsync -avzR \
        -e "$rsh" \
        "${root_files[@]}" "${rsync_dest}/" ) >&2 || die "rsync failed for root engine files"
fi
ok "Engine synced"

# CRITICAL: live .htaccess, robots.txt, .env, theme/, storage/ are NOT touched.
# If Velk core ships a new .htaccess.example, the user can manually merge
# changes into their live .htaccess (they're gitignored — not auto-synced).

# --- Run migrations ---
#
# Success is the EXIT CODE, never a grep of the output. Two ways the old
# grep-for-"error|fatal" was wrong, and the second is the dangerous one:
# it false-positived on any benign line containing "error", and — worse —
# `bash: php: command not found` matches NEITHER word, so a host where the
# binary isn't on PATH looked like a clean run. The cleanup below deletes
# migrations/, so "looked clean" would mean deleting the files after
# running nothing at all.
#
# remote_velk runs it with the PHP the config names (`.remote.php_bin`) —
# cPanel hosts routinely need /opt/cpanel/ea-phpXX/root/usr/bin/php.
step "Running bin/velk migrate on the remote"
set +e
mig_out=$(remote_velk migrate 2>&1 </dev/null)
mig_code=$?
set -e
echo "$mig_out" | sed 's/^/  /' >&2

if (( mig_code != 0 )); then
    err "Migration failed (exit ${mig_code}). Review the output above."
    err ""
    err "The server keeps its migrations/ folder — cleanup is SKIPPED on failure,"
    err "so you can fix the cause and re-run this script. Deleting them now would"
    err "leave new engine code against a half-applied schema with nothing to retry."
    exit 1
fi
ok "Migrations OK"

# --- Post-install cleanup on the server ---
#
# Runs ONLY after migrate succeeded, and that ordering is the whole safety
# of it: migrations/ is deleted here, so doing it with a half-applied schema
# would leave the site running new code against an old database with no
# files left to retry from.
#
# The list comes from the tarball manifest. Trailing slash means directory.
step "Cleaning up post-install paths on the server"
cleanup_paths=()
while IFS= read -r p; do
    [[ -n "$p" ]] && cleanup_paths+=("$p")
done < <(jq -r '.post_install_cleanup[]? // empty' "${src_dir}/engine-manifest.json")

for p in "${cleanup_paths[@]}"; do
    # Guard against a manifest entry escaping the install root.
    case "$p" in
        /*|*..*) warn "Skipping suspicious cleanup path: ${p}"; continue ;;
        # Not sent above, so the .gitignore there is the project's own.
        .gitignore) continue ;;
    esac
    if [[ "$p" == */ ]]; then
        "${ssh_args[@]}" "rm -rf $(shell_quote "${remote_path}/${p%/}")" >/dev/null 2>&1 || true
    else
        "${ssh_args[@]}" "rm -f $(shell_quote "${remote_path}/${p}")" >/dev/null 2>&1 || true
    fi
    echo "  removed ${p}" >&2
done
ok "Cleanup done"

# --- Record the deployed version on the server ---
#
# Sem isto o .velk-version remoto envelhece e passa a mentir — e o
# `migrate:status` novo manda justamente confiar nesse arquivo quando as
# migrations não estão mais lá.
step "Recording ${target_version} in the server's .velk-version"
installed_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
velk_version_json=$(jq -nc \
    --arg v "$target_version" \
    --arg at "$installed_at" \
    --arg prev "${remote_version:-unknown}" \
    --arg base "$release_base" \
    '{version:$v, installed_at:$at, previous_version:$prev, release_base_url:$base}')
"${ssh_args[@]}" "cat > $(shell_quote "${remote_path}/.velk-version")" <<< "$velk_version_json" \
    || warn "Could not write .velk-version on the server — deploy is fine, but the file is stale."

# --- Verify site still serves ---
step "Verifying ${app_url}"
http_code=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 15 -L "${app_url}/" || echo 000)
if [[ "$http_code" == "200" ]]; then
    ok "HTTP 200 OK"
else
    warn "HTTP ${http_code} — check the site manually: ${app_url}"
fi

echo
ok "update-cms complete."
echo
echo "  Site:    ${app_url}"
echo "  Path:    ${remote_path}"
echo "  Version: ${target_version} (from ${release_base})"
echo "  Touched: engine_paths from the release tarball + ran migrate"
echo
echo "Não modificado: theme/, storage/uploads/, .env, banco (exceto migrations)."
echo "Removido do servidor após aplicar: migrations/ e demais post_install_cleanup."
