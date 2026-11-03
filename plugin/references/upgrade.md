# Upgrading the Velk engine

## Scenario

The user wants an installed Velk project on the latest engine, or a specific
tagged version — "atualiza o velk aqui", "tem versão nova?", "instala a
v1.2.5 nesse projeto". Requires `core/Bootstrap.php` to already exist; this
isn't a fresh install (that's `references/install.md`).

## The model

Velk is treated as a versioned dependency, not a fork — no git involved, on
either end. Three pieces make that possible:

- **`.velk-version`** — JSON at the project root recording the installed
  version. Written by install, updated by this flow, travels with the
  project through deploy/download.
- **Release manifest** — `https://releases.velkcms.com/versions.json` lists
  every version with its tarball URL and sha256. `latest` names the newest.
- **Release tarball** — the full engine plus `engine-manifest.json`, which
  declares exactly which paths ARE the engine (`core/`, `bin/`,
  `migrations/`, `index.php`…). Only those paths ever get touched.

Read `.velk-version` → resolve the target in `versions.json` → download and
verify the tarball → copy only `engine_paths`, read from the NEW tarball's
manifest (not the project's old one — the path list itself can change
between versions) → run migrations → update `.velk-version`.

## Steps

1. **Pre-flight** — confirm `core/Bootstrap.php` + `bin/velk` exist, and
   `curl`/`tar`/`jq`/`rsync` are available.
2. **Detect current version** from `.velk-version` (see "Legacy installs" if
   missing).
3. **Resolve target** — `--version=vX.Y.Z` if given, else `.latest` from the
   manifest; look up its `url` and `sha256`.
4. **Compare** — already on the target version → report and stop.
5. **Check `references/upgrade-notes.md`** for every version in the range
   `(current, target]`. Some releases need work the file swap cannot do —
   data preserved before a column is dropped, a function renamed in `theme/`,
   a config key set. **Read it before step 7**, because the "before" steps
   have to run while the OLD schema still exists; once the migration runs,
   what they were protecting is gone.

   Fold whatever you find into the confirmation below, so the user approves
   the real plan rather than a generic one.
6. **Confirm with the user** — from/to version, which top-level paths get
   replaced vs preserved, that `bin/velk migrate` will run, **and any
   upgrade-note steps that apply**. Wait for an explicit yes; this overwrites
   engine files.
7. **Fetch** — download to a tmpdir, verify sha256 against the manifest entry
   before extracting anything. A mismatch aborts — never extract unverified
   content.
8. **Apply** — walk the EXTRACTED tarball's `engine-manifest.json`:
   directories sync with `rsync -a --delete`, files copy with `cp -f` into
   their own folder (`docs/messages.md` lands in `docs/`), `.gitignore`
   skipped (see step 10). The `--delete` matters — if the new version dropped
   a file from `core/`, the local copy must lose it too, or the project runs
   stale code the engine no longer expects.
9. **Migrate** — `./bin/velk migrate`. A failure here is recoverable, not
   fatal: engine files are already on the new version and `migrate` is safe to
   re-run once fixed. **Do NOT proceed to cleanup if this fails** — step 10
   deletes `migrations/`, and doing that with the schema half-applied leaves
   the site with new code, an old database, and no files to retry from.
10. **Cleanup** — remove the paths in the new manifest's
   `post_install_cleanup`, and nothing else. Two consequences:

   - **`.htaccess.example` and `robots.txt.example` stay.** They're engine
     paths the manifest doesn't clean up, like the engine's own installer,
     `update-cms` and the local copy leave them; `scripts/check-engine.sh`
     reports them `MISSING` when they're gone, and `bin/velk files:init`
     rebuilds the live files from them. Harmless in the docroot: Velk's
     `.htaccess` blocks `*.example`.
   - **`.gitignore` is never touched** — not copied in step 8, not removed
     here. The tarball's is the engine repo's own, and the cleanup lists it,
     so copying it and then cleaning up deletes the project's `.gitignore` —
     the one that keeps `.deploy/` (and the database password in
     `.deploy/ssh.json`) out of git. `check-engine` and the local copy skip it
     for the same reason.

   `post_install_cleanup` now carries **directories** as well as files —
   `migrations/` among them — so the loop has to branch on the trailing slash:

   ```bash
   CLEAN=$(mktemp); jq -r '.post_install_cleanup[]?' "$NEW_MANIFEST" > "$CLEAN"
   while read -r ep; do
       case "$ep" in ""|/*|*..*|.gitignore) continue ;; esac
       if [ "${ep%/}" != "$ep" ]; then
           [ -d "./${ep%/}" ] && rm -rf "./${ep%/}"
       else
           [ -f "./$ep" ] && rm -f "./$ep"
       fi
   done < "$CLEAN"; rm -f "$CLEAN"
   ```

   **Why `migrations/` goes away.** They exist to move a database forward, and
   once applied on this install they have no further job here: a site being
   moved between servers carries its database, it doesn't re-run migrations.
   Every upgrade fetches a fresh tarball that brings the files back, applies
   them, and drops them again — so the folder is scaffolding, not state.

   The cost, and it's real: `migrate:status` can no longer tell "up to date"
   from "the files aren't here", because both leave `pending()` empty. The
   command says so explicitly instead of claiming everything is applied, and
   points at `.velk-version` plus the `migrations` table for what actually
   ran.
11. **Mark** — rewrite `.velk-version` with the new version, a timestamp, and
    `previous_version` — the field a rollback command targets.
12. **Report** — from/to version, migrations applied, what was preserved, and
    the rollback command (`--version=<previous_version>`).

## Reference implementation

The steps that must be exact — version resolution, integrity, and the apply
loop. Everything else is judgement.

**Resolve the target (step 3):**

```bash
RELEASE_BASE_URL=$(jq -r '.release_base_url // "https://releases.velkcms.com"' .velk-version)
MANIFEST=$(curl -fsSL "${RELEASE_BASE_URL}/versions.json") \
  || die "Não consegui buscar ${RELEASE_BASE_URL}/versions.json."

TARGET="${VERSION:-$(echo "$MANIFEST" | jq -r '.latest')}"
ENTRY=$(echo "$MANIFEST" | jq -c --arg v "$TARGET" '.versions[] | select(.version==$v)')
[[ -n "$ENTRY" && "$ENTRY" != "null" ]] || die "Versão ${TARGET} não encontrada."
URL=$(echo "$ENTRY" | jq -r '.url')
SHA256=$(echo "$ENTRY" | jq -r '.sha256')
```

**Fetch and verify BEFORE extracting (step 7).** A mismatch must abort while
the project is still untouched:

```bash
TMPDIR=$(mktemp -d)
TARBALL="$TMPDIR/velk-${TARGET}.tar.gz"
curl -fSL "$URL" -o "$TARBALL" || { rm -rf "$TMPDIR"; die "Falha ao baixar $URL"; }

if command -v shasum >/dev/null 2>&1; then
    GOT=$(shasum -a 256 "$TARBALL" | awk '{print $1}')
else
    GOT=$(sha256sum "$TARBALL" | awk '{print $1}')
fi
[[ "$GOT" == "$SHA256" ]] || { rm -rf "$TMPDIR"; die "Integridade: esperado $SHA256, obtido $GOT"; }

tar -xzf "$TARBALL" -C "$TMPDIR/"
EXTRACTED=$(find "$TMPDIR" -maxdepth 1 -type d -name "velk-*" | head -1)
[ -f "$EXTRACTED/engine-manifest.json" ] || die "Tarball sem engine-manifest.json — versão anterior a v1.0.0?"
```

**Apply engine paths from the NEW manifest (step 8):**

```bash
NEW_MANIFEST="$EXTRACTED/engine-manifest.json"
TMPL=$(mktemp); trap 'rm -f "$TMPL"' EXIT
jq -r '.engine_paths[]' "$NEW_MANIFEST" > "$TMPL"
while read -r ep; do
    case "$ep" in ""|/*|*..*|.gitignore) continue ;; esac
    src="$EXTRACTED/$ep"; dst="./$ep"
    if [ "${ep%/}" != "$ep" ]; then
        [ -d "$src" ] || { echo "  warn: $ep ausente no tarball; pulando" >&2; continue; }
        mkdir -p "$dst"
        rsync -a --delete "$src" "$dst"
    elif [ -f "$src" ]; then
        mkdir -p "$(dirname "$dst")"
        cp -f "$src" "$dst"
    else
        echo "  warn: $ep declarado no manifest mas ausente no tarball; pulando" >&2
    fi
done < "$TMPL"
```

Cinco detalhes deste loop não são estilo, são o que impede perda de dados:

**A variável é `ep`, nunca `path`.** No zsh — o shell padrão do macOS —
`path` é o array amarrado ao `PATH`: `read -r path` troca o `PATH` inteiro
pelo nome do arquivo, e todo comando seguinte vira `command not found`. Rode o
laço com `bash` e mesmo assim não use `path`: ele é copiado para terminais e
`zsh -c` com frequência.

**O `.gitignore` fica de fora** (e da limpeza do passo 10). O do tarball é o
do repositório do engine e está no `post_install_cleanup`: copiá-lo e depois
limpar apaga o `.gitignore` do projeto, que mantém `.deploy/` fora do git.

**O destino do `rsync` é `$dst`, não `$(dirname "$dst")/`.** Com `ep="core/"`,
`dst="./core/"` e `dirname "./core/"` devolve `.` — o comando vira
`rsync -a --delete "$EXTRACTED/core/" "./"`, que copia o conteúdo de `core/`
para a raiz do projeto **e apaga tudo que não estiver lá dentro**: `theme/`,
`storage/`, `.env`, o projeto inteiro. `rsync -a --delete SRC/ DST/` já espelha
o conteúdo de SRC dentro de DST; o `dirname` sobra.

**Lista em arquivo temporário, não `| while` nem `< <(...)`.** Um pipe roda o
`while` em subshell e perde variáveis; a substituição de processo depende de
`/dev/fd`, que hospedagem compartilhada endurecida às vezes não monta — o
sintoma é `/dev/fd/63: No such file or directory` na primeira iteração.

**`[ "${ep%/}" != "$ep" ]` em vez de `[[ "$ep" == */ ]]`** pelo mesmo
motivo de portabilidade entre shells do host remoto. E um arquivo do engine
pode morar numa pasta (`docs/messages.md`): o `mkdir -p "$(dirname "$dst")"`
antes do `cp` é o que o faz chegar lá.

**Mark the new version (step 11):**

```bash
cat > .velk-version <<EOF
{
  "version": "${TARGET}",
  "installed_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "previous_version": "${CURRENT}",
  "release_base_url": "${RELEASE_BASE_URL}"
}
EOF
```

## Report back like this

```
✓ Velk atualizado.

  De:  v3.3.0
  Pra: v3.3.1

  Migrations aplicadas: 2026_08_09_000001_form_click_ids
  Removidos:            INSTALL.md
  Preservado:           .env, .htaccess, robots.txt, .gitignore, theme/, storage/, .deploy/

  Próximo:
    - Teste o site: abra / e /admin/login
    - Rollback, se precisar: upgrade --version=v3.3.0
      (engine volta; DB e conteúdo seguem intactos)
```

Always show the previous version as a literal rollback command — it's exactly
what `--version=` takes.

## Legacy installs (no `.velk-version`)

- **`.git/` + `core/VERSION` present**: derive the current version from
  `core/VERSION`, offer to write `.velk-version` and drop `.git/`, proceed
  normally.
- **`.git/` without `core/VERSION`** (pre-v1.0.0), or **neither** (project
  was copied/unzipped in, not installed): no way to know the starting
  version. Offer to treat it as "unknown → latest" — same flow, engine paths
  still get overwritten, `theme/`/`storage/`/`.env` still preserved, pending
  migrations still apply. Warn explicitly that hand-edits inside engine paths
  (e.g. a patched `core/Bootstrap.php`) are lost. Afterward record
  `previous_version: "unknown (migrated)"` and drop `.git/` if present.

## No-shell hosts

Shared hosting reachable only by FTP can't run this skill's shell steps.
Engine files still need to land some other way, but the DB side self-heals:
Velk auto-migrates on the first web request after new engine files are in
place (`AUTO_MIGRATE`, on by default) — so the upgrade finishes without ever
running `bin/velk migrate` by hand.

## Gotchas

- Diff against the NEW tarball's manifest, never the old one —
  `engine_paths` itself can change release to release.
- sha256 mismatch or a corrupt tarball aborts before touching the project;
  rsync dying mid-copy (full disk, killed process) can leave `core/`
  half-updated — just re-run the upgrade once the underlying issue is fixed.
- Downgrading works for engine files, but migrations have no "down" — DB
  schema can end up ahead of the older code. An accepted, explicit tradeoff.
- Very old tags (pre-v1.0.0) predate `engine-manifest.json` entirely —
  caught at fetch time; fix is picking a version >= v1.0.0.
- Never force-merges local edits to engine files — a hand-patched `core/`
  file is silently discarded on upgrade. Customization belongs in `theme/`
  or `theme/functions.php`, never `core/`, precisely so upgrades stay safe.
- Doesn't back up the database itself — assumes the user has their own
  process before a destructive engine swap.
