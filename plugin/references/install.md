# Install Velk

Scenario: an empty (or near-empty) folder, nothing Velk-related in it yet. The
user wants a working install — files, database, admin user — ready to hit
`/admin/login`. It's an interactive flow, not a script to run blind: real DB
and admin credentials have to come from the user before anything is written.

## The model: tarball, not git clone

The engine's source repo is private; distribution is a separate, versioned
pipeline. Never `git clone` it.

- Fetch the manifest: `curl -fsSL https://releases.velkcms.com/versions.json`
  — a `{latest, versions: [{version, url, sha256}]}` document produced by
  `bin/release` in the engine repo.
- Resolve a version (default the manifest's `latest`, or an explicit
  `--version=vX.Y.Z`), download its tarball, and verify `sha256` against the
  manifest entry before extracting. A mismatch aborts — there's no GitHub
  fallback to lean on.
- Extract into the current directory. The tarball wraps everything in a
  `velk-<version>/` folder; strip that wrapper when copying into place.
- Sanity-check the result: `core/Bootstrap.php` and `bin/velk` must exist, or
  the install is broken before it starts.

This is why the finished project has no `.git/` for Velk — it's a versioned
dependency copied into place (think `vendor/`, not a fork). A
`--release-base-url=<url>` override (for self-hosters/mirrors) gets persisted
so future upgrades keep pulling from the same place.

## The flow

1. **Pre-flight** — `ls -la`. If `core/Bootstrap.php` already exists, stop:
   offer wipe+reinstall, an upgrade (`references/upgrade.md`), or just `./bin/velk install` to apply
   pending migrations, rather than silently overwriting. An existing `.env`
   needs explicit confirmation before it's touched.
2. **Fetch** — download, verify, extract, as above.
3. **Gather config** — batch the questions (AskUserQuestion or grouped
   prompts) instead of round-tripping one field at a time:

   | Field | Default | Notes |
   |---|---|---|
   | `DB_HOST` / `DB_PORT` | `localhost` / `3306` | |
   | `DB_DATABASE` | — | created if it doesn't exist |
   | `DB_USERNAME` / `DB_PASSWORD` | `root` / empty | user needs CREATE DATABASE if the DB is missing |
   | `INITIAL_USER_EMAIL` | — | first admin login |
   | `INITIAL_USER_PASSWORD` | — | at least 8 characters — the installer refuses a shorter one |
   | `INITIAL_USER_NAME` | `Admin` | |
   | `APP_URL` | empty | optional; blank is fine locally, Velk auto-detects the host; used by `sitemap.xml` / `absolute_url()` |

   Mention SMTP is optional and skippable — forms just won't send email until
   `SMTP_HOST`/`SMTP_USER`/`SMTP_PASS`/`SMTP_FROM` are set in `.env` later.
4. **Write `.env`** — start from the shipped `.env.example`, fill in answers,
   `chmod 0600 .env`.
5. **Run the installer** — `./bin/velk install`. It creates the DB if
   missing, runs migrations, creates the admin user, and copies per-project
   files (`.htaccess`, `robots.txt`) from their `.example` templates. A `FAIL`
   on the DB step means don't leave a half-written `.env` — go back, re-ask
   credentials, retry (give up after ~3 tries and point the user at manual
   debugging).
6. **Clean up scaffolding** — only once install reports success.
7. **Write `.velk-version`** — version pulled from `core/VERSION`, plus
   `installed_at` and `release_base_url`, so the upgrade and deploy flows
   (`references/upgrade.md`, `references/deploy.md`) know what's running without needing git.
8. **Report** — login URL, what got cleaned up, next steps (`./bin/velk
   serve`, drop a theme into `theme/`).

## Reference implementation

Fetch, verify, extract (step 2). The sha256 gate matters more here than
anywhere else — the source repo is private, so there's no GitHub fallback and
no implicit trust to lean on:

```bash
BASE="${RELEASE_BASE_URL:-https://releases.velkcms.com}"
MANIFEST=$(curl -fsSL "${BASE}/versions.json") || die "Não consegui buscar ${BASE}/versions.json."

TARGET="${VERSION:-$(echo "$MANIFEST" | jq -r '.latest')}"
ENTRY=$(echo "$MANIFEST" | jq -c --arg v "$TARGET" '.versions[] | select(.version==$v)')
[[ -n "$ENTRY" && "$ENTRY" != "null" ]] || die "Versão ${TARGET} não encontrada."

TMPDIR=$(mktemp -d)
curl -fSL "$(echo "$ENTRY" | jq -r '.url')" -o "$TMPDIR/velk.tar.gz" || die "Falha ao baixar."

WANT=$(echo "$ENTRY" | jq -r '.sha256')
if command -v shasum >/dev/null 2>&1; then
    GOT=$(shasum -a 256 "$TMPDIR/velk.tar.gz" | awk '{print $1}')
else
    GOT=$(sha256sum "$TMPDIR/velk.tar.gz" | awk '{print $1}')
fi
[[ "$GOT" == "$WANT" ]] || { rm -rf "$TMPDIR"; die "Integridade: esperado $WANT, obtido $GOT"; }

tar -xzf "$TMPDIR/velk.tar.gz" -C "$TMPDIR/"
SRC=$(find "$TMPDIR" -maxdepth 1 -type d -name "velk-*" | head -1)
# Copia o CONTEÚDO, sem a pasta-wrapper velk-<version>/.
cp -a "$SRC"/. ./
rm -rf "$TMPDIR"

[ -f core/Bootstrap.php ] && [ -f bin/velk ] || die "Extração incompleta."
```

Record the version (step 7), so upgrade and deploy know what's running
without git:

```bash
cat > .velk-version <<EOF
{
  "version": "$(tr -d '[:space:]' < core/VERSION)",
  "installed_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "release_base_url": "${BASE}"
}
EOF
```

## Gotchas

- **Cleanup only runs after a successful install.** On failure, leave
  everything in place for debugging.
- **`.htaccess.example` and `robots.txt.example` stay.** They're engine paths
  the manifest's `post_install_cleanup` doesn't list: the installer copies
  them into `.htaccess`/`robots.txt` and leaves them, `bin/velk files:init`
  rebuilds the live files from them, and `scripts/check-engine.sh` reports
  them `MISSING` if they're gone — which `init` then refuses to deploy.
  Velk's `.htaccess` blocks `*.example`, so keeping them costs nothing.
- **`migrations/` is removed once applied**, like the rest of
  `post_install_cleanup`. They exist to move a database forward; after running
  here they have no further job, and a site moved between servers carries its
  database rather than re-running them. Every upgrade fetches a fresh tarball
  that brings the files back, applies them, and drops them again — scaffolding,
  not state.

  `post_install_cleanup` now holds **directories** as well as files, so the
  cleanup loop must branch on the trailing slash (`rm -rf` for `foo/`, `rm -f`
  otherwise) — snippet in `references/upgrade.md`.

  Two consequences worth knowing. `bin/velk migrate:status` can no longer tell
  "up to date" from "the files aren't here", so it says so explicitly instead
  of claiming everything is applied. And `update-cms` no longer pushes the
  local `migrations/` folder — it fetches the release tarball, so the server
  receives exactly a published version rather than whatever sits in the
  working copy.
- **The shipped `.gitignore` is removed unconditionally.** It's the upstream
  engine repo's own `.gitignore` (ignores `/theme/`, `.htaccess`,
  `robots.txt` — exactly what a project owner wants to commit); leaving it
  would sabotage `git init` on the user's project.
- **`engine-manifest.json` and `nginx.conf.example` are also removed** —
  install/upgrade always read the manifest from the tarball, never a local
  copy, and Velk's installer only generates Apache `.htaccess` (nginx users
  hand-write the rewrite rule, and nginx never reads a docroot file anyway).
- **`.env.example` is kept** — it stays the canonical reference for every env
  var once the user wants to add SMTP or change `APP_URL` later.
- **MySQL 5.7+ / MariaDB 10.3+ required** (native JSON columns) — an older
  server surfaces as a migration failure, not a clear upfront check.

## Related

`references/upgrade.md` picks up from `.velk-version` to move an install forward.
`references/theme-convert.md` is the natural next step once login works.
