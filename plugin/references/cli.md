# CLI — `bin/velk`

Velk's command-line tool. Run it from the **project root** (where `index.php`
and `bin/` live); it reads DB config from `.env`. Invoke as `./bin/velk <cmd>`
(make it executable once with `chmod +x bin/velk` if needed).

Almost everything the admin panel does, the CLI can do too — which is what lets
you script content, run migrations on a server, or drive Velk from another
tool or skill.

## Setup & schema

| Command | What it does |
|---|---|
| `install` | Full first-time install: ensures the DB exists, runs migrations, creates the initial admin user, copies per-project files. Flags `--email` / `--password` / `--name` override the `INITIAL_USER_*` in `.env`. |
| `migrate` | Apply pending migrations. |
| `migrate:status` | Show which migrations are pending. |
| `schema:validate` | Validate `theme/site.json`. Run this after every edit to it — it catches the mistakes that would otherwise only appear as a broken admin screen (and, v3.8.4+, a mistyped `security.csp` that would leave the site's CSP on `open`). |
| `page:sync` | Create/refresh `pages` rows from `site.json`. Run after adding or renaming a page. |
| `files:init` | Copy `.htaccess.example` / `robots.txt.example` into their live counterparts. |
| `user:create <email> <pw> <name>` | Create an admin user. |
| `serve [port]` | Start the built-in PHP dev server (default `:8080` → `http://localhost:8080`). |
| `cleanup:login-attempts` | Drop old `login_attempts` (`--days=30`). |
| `i18n:scan` | Scan theme + core for `t()` calls and register source strings. |
| `csp:check` | (v3.8.1+) What strict mode would block in the theme — `<script>` without a nonce, `on…=`, `javascript:`, a policy of the theme's own — plus problems in the CSP settings, and (v3.8.3+) a form or button posting to another site that nothing allows. Since v3.8.4 the settings are `security.csp` in `site.json`; it also lists an old `CSP_*` variable left in `.env`, which is no longer read. Its first line shows the mode in force. Run it on the server (`scripts/content/velk.sh --project . -- csp:check`) to read the real `.env` and `APP_URL`. Exit 1 on an error; no database needed. |
| `media:variants` | Backfill the `thumb` + every declared image variant for all images (`--regen` rebuilds existing files). Run after upgrading an existing site or changing a variant's dimensions. |

## Content — items (posts, cases, services, …)

| Command | What it does |
|---|---|
| `item:types` | List the item types defined in `site.json`. |
| `item:schema <type>` | Show a type's field schema. Read this to learn the fields **before** writing. |
| `item:list <type>` | List items. Filters: `--status`, `--search`, `--limit`. |
| `item:get <type> <slug-or-id>` | Get one item as JSON. |
| `item:create <type> --json=<JSON>` | Create an item (or `--json-stdin` to pipe the payload). |
| `item:update <type> <slug> --json=<JSON>` | Partial update — merges into `fields`. |
| `item:publish <type> <slug>` / `item:unpublish <type> <slug>` | Flip status (publish stamps `published_at`). |
| `item:delete <type> <slug> --confirm` | Delete (destructive — requires `--confirm`). |

## Content — pages (home, about, …)

| Command | What it does |
|---|---|
| `page:list` | List configured pages. |
| `page:schema <key>` | Show a page's field schema. |
| `page:get <key>` | Get a page's current data as JSON. |
| `page:update <key> --json=<JSON>` | Update page fields — merges. |

## Forms

| Command | What it does |
|---|---|
| `form:export <form-id>` | (v3.8.0+) Approved, completed submissions as CSV on stdout — the same file as the **Export** block on the form screen. By default only the form's fields; `--cols=name,email,@meta,@params` picks columns (`@meta` = id, date, IP, browser, referrer, e-mail status, recipients; `@params` = UTM and click IDs). `--from=`/`--to=YYYY-MM-DD`, `--sep=,` (default `;`), `--no-bom`. Errors go to stderr, so `form:export contato > leads.csv` is safe; any exit but 0 means the file is incomplete. |

## Common flags (content commands)

- `--format=json` — machine-readable output (default is human-readable text).
- `--dry-run` — validate without saving (create/update).
- `--json-stdin` — read the `--json` payload from stdin (avoids shell-quoting hell for rich content).

## Auto-migrate on web boot

An installed site applies pending migrations automatically on the first web
request after an upgrade (`AUTO_MIGRATE`, on by default) — so a shared host
without SSH finishes an upgrade just by uploading the new files. Concurrent
requests are serialized with a MySQL `GET_LOCK`. Set `AUTO_MIGRATE=false` in
`.env` to disable and manage migrations only via `bin/velk migrate`.
