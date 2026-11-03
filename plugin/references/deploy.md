# Deploying Velk over SSH

A Velk project needs to go live, or get updated, on a real server —
Hostinger, a cPanel host (Locaweb, HostGator, KingHost, A2, SiteGround,
Bluehost), DreamHost, a VPS (DigitalOcean, Linode, Hetzner, Vultr), or a
cloud VM (Lightsail, EC2, GCP, Azure) — anywhere with SSH + key auth +
MySQL/MariaDB. The only host-specific detail is the remote path.

The real logic lives in `scripts/`. Your job is to detect what state
the deploy is in, pick the right action (or ask), run the right script, and
report the outcome honestly.

## Three actions, split by what changes

Theme (`theme/site.json`, templates, partials, assets) and engine (`core/`,
`config/`, `bin/`, `migrations/`, root files) change on different schedules.
Production data (items, form submissions, uploaded media) lives in the remote
DB and `storage/uploads/`; no action may touch it but `init`.

| Action | Touches remotely | Refuses if |
|---|---|---|
| `init` | Everything: files + DB import + `storage/` + `.env` + `robots.txt` | Velk already exists at target |
| `update-cms` | Every path in `engine-manifest.json`. Runs `migrate` after | Velk does NOT exist at target |
| `update-theme` | `theme/` only — the versioned publish (`references/publish.md`): merges what changed live, stages, validates, swaps back on failure | Velk does NOT exist at target |

`storage/uploads/`, `.env`, and the live DB are **never** overwritten after
init.

## Phase 0 — Always inspect the target first

Before anything else, run `scripts/preflight.sh --project .`. It SSHes in,
looks for `<remote_path>/core/Bootstrap.php`, and answers `TARGET=EXISTS`,
`TARGET=EMPTY` (the folder, without Velk) or `TARGET=MISSING` (no folder —
`init` creates it); with Velk there it also checks the database with the
server's own `.env` (`DB=ok`). `STATUS=FAILED` names the check (`FAILED=`)
and why (`REASON=`).

```
config exists? ── no ──▶ first-time setup (Phase 1), then re-enter at Phase 2
       │
      yes
       ▼
TARGET ── EMPTY / MISSING ──▶ offer init (Phase 3)
       │
      EXISTS
       ▼
offer update-cms / update-theme. Refuse init.
```

This check is what stands between a routine deploy and a wiped database.
Never skip it, even when the user is sure of the target state. There is no
`--force` for `init` — a true clean slate means the user deletes the remote
directory themselves first. Say so plainly:

> "Velk já existe em `<path>`. `init` sobrescreveria o site em produção —
> bloqueado. Posso rodar `update-cms` ou `update-theme`."

## Phase 1 — First-time setup (only when config is missing)

Config lives at `.deploy/ssh.json` in the project root. Gather everything in
one batch, then save with `chmod 0600` and append `.deploy/` to `.gitignore`.

**SSH access** — pick ONE shape:
- `ssh.alias` — a Host alias from `~/.ssh/config` (cleanest). When set, the
  other `ssh.*` connection fields are ignored.
- OR `ssh.host` + `ssh.port` (default `22`; Hostinger uses `65002`) +
  `ssh.user` + `ssh.key_path` (default `~/.ssh/id_ed25519`).

If the user doesn't know whether SSH is available, point them at their host's
panel (cPanel → SSH Access, hPanel → Advanced → SSH Access). Most shared
plans Premium and up have it; basic plans usually don't. VPS/cloud always do.

**Remote path** — `ssh.remote_path`, the absolute path where Velk will live.
THE most important field, and it varies by host:

| Host | Typical path |
|---|---|
| Hostinger shared | `/home/uXXXX/domains/<domain>/public_html` |
| cPanel (HostGator, A2, SiteGround, Bluehost, Locaweb) | `/home/<user>/public_html[/<subdir>]` |
| KingHost | `/home/<user>/www` |
| DreamHost | `/home/<user>/<domain>` |
| VPS (DigitalOcean, Linode, Hetzner, Vultr) | `/var/www/<project>` or `/srv/<domain>` |
| AWS Lightsail / EC2 | `/var/www/html` or `/opt/bitnami/apache2/htdocs` |

If unsure, have the user SSH in and `pwd` from the web root, or check the
host panel's "Document Root".

**Site URL and subpath**
- `site.url` — canonical URL with scheme; drives `APP_URL`, the sitemap and
  `robots.txt`. E.g. `https://example.com`.
- `site.subpath` — only when the site lives under a subpath, e.g. `/blog`.
  Drives `APP_BASE_PATH`. Empty string means root domain.

Subpath and `remote_path` are independent: a site at
`https://example.com/blog/` might live at `/var/www/blog/` or at
`/home/user/public_html/blog/`. Never derive one from the other.

**Database, remote** — must already exist; Velk cannot create databases.
`db.name`, `db.user`, `db.password` exactly as the host panel created them
(hosts often prefix: Hostinger `u12345678_example`). `db.host` defaults to
`localhost` — override for a split DB host like an RDS endpoint. `db.*` is
read only by `init`, which turns it into the server's `.env`; every database
step after that (backups, the local copy, `preflight`) reads that `.env` on
the server.

**Database, local** — default to reading `DB_DATABASE`/`DB_USERNAME`/
`DB_PASSWORD` from the project's `.env`. This is what gets dumped on `init`
(through an option file: the password never sits on a command line).

### Config schema

With an SSH alias:

```json
{
  "ssh": {
    "alias": "my-server",
    "remote_path": "/var/www/example"
  },
  "site": {
    "url": "https://example.com",
    "subpath": ""
  },
  "db": {
    "host": "localhost",
    "name": "example_prod",
    "user": "example_app",
    "password": "***"
  },
  "local": {
    "db_host": "localhost",
    "db_name": "example",
    "db_user": "root",
    "db_password": "***"
  }
}
```

Without an alias, replace the `ssh` block with
`{"host": …, "port": 22, "user": …, "key_path": "~/.ssh/id_ed25519",
"remote_path": …}`. The scripts handle both shapes.

### Validate what you just wrote

`preflight.sh` reads the config from disk, so the order is: write
`.deploy/ssh.json`, check it, and don't move on until it passes:

- SSH connects — `SSH=ok`
- the target folder, with or without Velk — `TARGET=`
- the local database, for `init`'s dump — `LOCAL_DB=ok`, `MYSQLDUMP=ok`
- `site.url` parses and uses `https://` (warn on `http://`)

`scripts/preflight.sh --project . --local-db` runs the first three together
(the server's database is checked once Velk is there, from its own `.env` —
before `init` there is none). If any fails, surface the `REASON`, let the
user fix the config, run it again. A config that fails preflight is not
done — never leave one in place as if it were.

## Phase 2 — Pick the action

| User says | Action |
|---|---|
| "primeiro deploy", "subir pela primeira vez", "deploy inicial" | `init` (only if target is EMPTY) |
| "atualiza o cms", "push do core", "rodar migrations em prod" | `update-cms` |
| "atualiza o tema", "push do template", "mudanças do site.json" | `update-theme` |
| "deploy" (unqualified) + target EMPTY | confirm → `init` |
| "deploy" (unqualified) + target EXISTS | ask: "Mudou theme ou core?" |

When in doubt, ask. Better to confirm than to overwrite the wrong thing.

## Phase 3 — Execute

### `init` — first-time deploy

`scripts/deploy/init.sh --project .`

1. Re-checks the target is empty (refuses if Velk exists), that the local
   engine is its published release, and that no source of a theme-convert
   is left to ship: a PHP in the root of `theme/` other than
   `functions.php`, a `theme/includes/`, or a `_source/` not listed in
   `rsync.extra_excludes`. All of it before anything is sent — a refusal
   after the upload would leave a target init won't touch again.
2. Dumps the local DB (credentials through an option file, never on a
   command line) to a temporary file only its owner can read. On MySQL it
   adds `--set-gtid-purged=OFF`: a GTID-enabled server (Homebrew's) otherwise
   writes `SET @@SESSION.SQL_LOG_BIN`, which shared hosting refuses on import
3. `rsync -avz --delete-after` of project files, **excluding** `.env`,
   `.git/`, `.deploy/`, `.metrik/` (never uploaded), `node_modules/`, `tests/`, `docs/`,
   `storage/cache/*`, `storage/logs/*`. The whole `theme/` goes —
   `functions.php` included
4. Generates the remote `.env` from the config (`APP_URL`, `APP_BASE_PATH`,
   `DB_*`) — never from local `.env`, which would leak local credentials
5. Uploads and imports the SQL dump, then deletes it
6. Runs `php bin/velk migrate` on the remote
7. Writes `robots.txt` with the real `Sitemap: <site URL>/sitemap.xml` —
   `site.url` plus `site.subpath` —, replacing the `example.com` placeholder
   shipped in the repo. On a subdirectory install it warns: crawlers only read
   the host root's `robots.txt`, so the sitemap goes there or to Search Console
8. `chmod 0640 .env` (web server reads it; world doesn't)
9. Verifies with `curl -o /dev/null -w "%{http_code}"` on the site URL (subpath
   included; `update-cms` checks the same address) — expects 200. Any other
   code (404, 50x, `000` for no answer) is only a warning: the script still
   ends with `Init deploy complete.`, so read the `HTTP` line before
   reporting success

### `update-cms` — push engine changes only

`scripts/deploy/update-cms.sh --project . [--version vX.Y.Z]`

1. Verifies Velk exists at target (refuses if EMPTY)
2. Resolves which version to ship: `--version`, else whatever the local
   `.velk-version` says this install is on

> **Crossing versions here has the same requirements as a local upgrade.**
> `update-cms` moves the server's engine forward, so it hits the same
> destructive migrations and theme renames. Check
> `references/upgrade-notes.md` for every version between what the server
> runs and what you're shipping — some steps have to happen on the server
> **before** the files land, and this script won't do them for you.
3. Downloads that release's tarball and **verifies its sha256 before
   extracting** — a mismatch must never reach a client's server
4. Reads `engine_paths` from the tarball's manifest and rsyncs exactly those:
   directories with `--delete` scoped to themselves, root files without
5. Runs `php bin/velk migrate` on the remote
6. **Only if that succeeded**, removes the manifest's `post_install_cleanup`
   paths from the server — `migrations/` among them
7. Verifies the homepage still returns 200

Theme, storage and `.env` stay untouched. So do the live `.htaccess` and
`robots.txt` — only their `.example` templates are engine paths.

**The source is a published release, not the working copy**, and three things
follow from that. The server receives exactly a version that exists in
`versions.json`, so a local edit or an uncommitted change can't reach a client
site by accident. The manifest comes from the tarball, which always carries
one, so there is no hand-maintained fallback path list left to drift — an
earlier version of this script had one, and it silently stopped shipping
`config/` for two releases. And `migrations/` no longer has to survive in the
local install: it's deleted once applied, and the tarball brings it back
whenever a database actually needs to move.

> **Step 6 must never run when step 5 failed.** It deletes `migrations/`, and
> doing that against a half-applied schema leaves the site running new code on
> an old database with no files left to retry from.

One thing to know when debugging a live site later: with the files gone,
`bin/velk migrate:status` cannot distinguish "up to date" from "the files
aren't here" — both leave the pending list empty. The command says so
explicitly instead of claiming everything is applied, and points at
`.velk-version` and the `migrations` table for what actually ran.

### `update-theme` — push theme changes only

`scripts/theme/publish.sh run --project .`

The versioned publish, all of it in `references/publish.md`. It refuses a
server without Velk (`STATUS=NO_VELK`, exit 11 — the first deploy is
`init`). In short: whatever was published (or changed by hand)
on the server since this copy was taken is merged in, never overwritten; the
new theme is staged and checked on the server, swapped in with two renames,
validated live (`schema:validate`, `page:sync`, the home page not answering
a server error) and swapped back at once on any failure; only then is the
new version recorded.

When it needs a person — conflicts, live files it would delete — it stops
with that `STATUS`; continue with `publish.sh commit` or `abort` as
`references/publish.md` describes: for a stale lock (`STALE_LOCK`) run again
with `--take-over-stale`, and for a site already failing before the publish
(`LIVE_ALREADY_FAILING`, exit 10) with `--accept-live-failure` — both after
asking.

The first versioned publish of a project older than versioning has no
starting point: every theme file that differs from what's live stops as a
conflict (`added-both`, with markers). When this copy is the one to keep —
the usual case for the agency's own copy — settle each, after asking, with
`scripts/theme/publish.sh resolve --project . <path> local`, then run again.

`page:sync` creates a row for each page declared in `site.json` that has
none (title from its `label`, fields empty) and updates the title of a page
whose `label` changed. Pages have no draft or published state, so there is
nothing to publish afterwards. It never deletes a page or alters the fields
an editor typed in the admin.

## Scripts

Each takes `--project <dir>` (and `--config <file>` for a config kept
elsewhere), reads the config via `jq`, resolves the SSH command (alias OR
direct host/port/user/key), prints progress to stderr and its answer to
stdout, and exits non-zero on failure.

| Script | Purpose |
|---|---|
| `scripts/preflight.sh [--local-db]` | SSH, `TARGET=EXISTS\|EMPTY\|MISSING`, the server's database — and the local one, for `init`. Only looks. Run before anything else. |
| `scripts/deploy/init.sh` | Full first deploy. Refuses if the target has Velk. |
| `scripts/deploy/update-cms.sh [--version vX.Y.Z]` | Manifest-derived engine rsync + `migrate`. Refuses if empty. |
| `scripts/theme/publish.sh run` | The versioned theme publish. Refuses a server without Velk (`NO_VELK`). |

They share `scripts/ssh-lib.sh`. Read a script before invoking it — the
scripts, not this file, are the source of truth for what actually runs.

## Report back like this

```
✓ update-cms completo

Site:    https://example.com
Admin:   https://example.com/admin/login
Config:  .deploy/ssh.json (chmod 0600)

Resumo:
  - 47 arquivos sincronizados (rsync)
  - 2 migrations aplicadas: 2026_05_01_users_field, 2026_05_03_form_fields
  - HTTP 200 verificado em /
```

If a step failed, show which one and what to check. Don't keep going on a
broken foundation, and don't read empty output as success — confirm the
verification step actually passed before claiming it did.

## Gotchas

- **PHP not on PATH** — cPanel hosts often need the full binary path
  (`/opt/cpanel/ea-php82/root/usr/bin/php`); test with `ssh <host> "php -v"`.
  Set it as `remote.php_bin` in the config: every remote `bin/velk` call runs
  through it.
- **DB host isn't always `localhost`** — cloud setups (an RDS endpoint) put
  MySQL on a separate host from the one SSH connects to.
- **Key auth required** — the scripts use `BatchMode=yes`; password-only
  hosts need `ssh-copy-id` first.
- **Custom ports** — Hostinger uses `65002`; most others `22`.
- **rsync blocked** — rare, on locked-down jail shells. Symptom:
  `rsync: Failed to exec ssh`. Fallback: tar over ssh, extract remotely.
- **Subpath installs** — `APP_BASE_PATH` keeps URLs correct, but only if the
  theme goes through the helpers (`url()`, `asset()`, `image_url()`) instead
  of hardcoding paths.
- **Retries are safe, except a first deploy that stopped halfway** — rsync
  resumes; `migrate`, `page:sync` and the robots.txt overwrite are
  idempotent. The only non-idempotent step is `init`'s SQL import, guarded
  by the empty-target check, and that guard also stops a second `init` once
  the first one sent its files. After an `init` that failed, run preflight:
  - `TARGET=EMPTY` or `MISSING` — Velk never reached the server. Fix the
    cause and run `init` again.
  - `TARGET=EXISTS` — it failed after the files went up (late in rsync, or
    at `.env`, the dump import, `migrate`), and a second `init` refuses.
    Tell the user which step failed and why. Once the cause is fixed, the
    user empties (or deletes) `<remote_path>` themselves, as in Phase 0;
    then run preflight and `init` again. The database needs no cleanup: the
    dump drops and recreates each of its tables. Don't finish the steps by
    hand instead (say, `scripts/content/velk.sh --project . -- migrate` after
    init's `migrate` error): `robots.txt` would keep pointing at
    `example.com`, because only `init` writes the real one.

## Don't

- Run `init` against a target that already has Velk.
- Skip the target inspection because the user sounded certain.
- Push the project's local `.env` to the remote — it leaks local DB
  credentials.
- Guess `remote_path` from `site.url` — the on-disk path and the public URL
  are unrelated; always ask.
- Modify `.deploy/ssh.json` without consent. A wrong credential is a question
  for the user, not a silent edit.
- Run two actions in parallel against the same target.
- Do more than what was asked — "atualiza o tema" means `update-theme`, and
  nothing else.
- Edit theme files directly on the server. Always edit locally and publish:
  a server-side edit skips every check and becomes a "change made outside"
  for the next person who publishes.
