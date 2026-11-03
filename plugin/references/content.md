# Edit content on a deployed site (SSH)

Create, edit, and publish content — posts, services, pages, any type declared
in `theme/site.json` — on a site that's already live, without a full deploy.
Good for: "create a post about X on the live site," "publish all drafts,"
"change the hero text on the About page," "list this month's published
posts." Runs through `bin/velk item:*` / `page:*` over SSH — no rsync, no
`migrate`, no browser.

## What this is NOT for

- **Schema changes** — a new field, content type, or taxonomy is
  `theme/site.json`, edited locally and shipped via `deploy.md`. This skill
  only fills in content for types/fields that already exist; it never touches
  structure.
- **Template or theme code** — edit locally, ship with `deploy.md`.
- **Bulk media** — use the admin panel. This flow references images by
  URL/path; it doesn't upload files.

Reach for this over the admin UI for bulk ops ("publish every draft over a
week old") or to stay in the terminal mid-session — for one-off edits, media,
or heavy forms, the admin UI is still simpler.

## Setup: reuse, don't re-collect

Needs `.deploy/ssh.json` in the project — the same config `deploy.md`
(Phase 1) or an access file (`access.md`) produce. Missing?
Point the user at one of those instead of gathering SSH credentials yourself.
Also needs a remote Velk recent enough to expose `item:*`/`page:*` —
`./bin/velk item:types` erroring with "Unknown command" means the remote needs
`upgrade.md` + a deploy first.

## Schema-aware by design

Never assume a site has "posts," or that a field is named what you'd guess —
discover it. Two read-only calls, through the same transport as everything
else:

```bash
scripts/content/velk.sh --project . -- item:types     # every item type declared in site.json
scripts/content/velk.sh --project . -- page:list      # every configured page
```

and, for a single type's fields:

```bash
scripts/content/velk.sh --project . -- item:schema <type>
```

Use the schema to fill required fields, default optional ones sanely, and
shape JSON before it's ever sent.

## Scripts

All take `--project <dir>`.

| Script | Purpose |
|---|---|
| `scripts/content/velk.sh -- <bin/velk arguments…>` | Every read and every edit: runs that `bin/velk` command on the server, arguments intact. Adds `--format=json` to the content commands; forwards stdin only with `--json-stdin`; before a write that isn't a `--dry-run`, finishes or undoes an interrupted theme publish. |
| `scripts/content/backup.sh [--tables items,pages]` | Dumps the tables on the server, with its own `.env` credentials, to a file here only its owner can read (`backup_path`). Two tables by default — a full dump would drag in users and form submissions that content edits never touch. |
| `scripts/content/restore.sh --file <backup> --confirm` | Puts a backup back — replacing those tables whole. |

Prefer `velk.sh` over SSHing to `bin/velk` yourself: it routes JSON through
stdin (no quoting hell with richtext), resolves the SSH target and the
server's PHP from the config, and answers `{"ok": false, ...}` when the SSH
itself fails — `bin/velk` answers its own errors the same way under
`--format=json` — so the two never blur into one opaque non-zero exit.

## The flow

1. **Discover** — what types/pages/fields this specific site actually has.
2. **Plan** — map the request onto one operation (table below).
3. **Dry-run** — every create/update goes through `--dry-run --format=json`
   first, validating fields, types, and slug collisions before anything
   touches the DB.
4. **Confirm** — show the exact operation (changed fields, item count for
   batches), wait for a yes. Batch deletes: show the slugs, require explicit
   confirmation, not just "y".
5. **Backup** — `scripts/content/backup.sh` dumps the affected tables
   (`items`, `pages`) on the server, with the database credentials of the
   server's own `.env`, to a file here only its owner can read (the
   `backup_path` in its answer) before any write. Automatic, always — tell
   the user the path.
6. **Execute** — run the real command (`velk.sh --project . -- …`).
7. **Report** — what changed and the backup path. Putting it back:
   `scripts/content/restore.sh --project . --file <path> --confirm` (the
   `rollback_hint`), which imports on the server with the
   server's own credentials. Before the user's yes, say what it means: the
   backed-up tables are replaced whole, so every change made to them since
   the backup is lost — including edits anyone made in the admin panel.

Reads (`list`/`get`/`schema`) skip steps 3–6 — nothing to protect against.

## Commands this leans on

| Intent | Command |
|---|---|
| Create | `item:create <type> --json='{...}'` (or `--json-stdin` for long content) |
| Update | `item:update <type> <slug> --json='{...}'` |
| Publish / unpublish | `item:publish <type> <slug>` / `item:unpublish <type> <slug>` |
| Delete | `item:delete <type> <slug> --confirm` |
| List / read | `item:list <type> --status=draft`, `item:get <type> <slug>` |
| Edit a page | `page:update <key> --json='{"fields":{...}}'` |

All support `--format=json`; writes also support `--dry-run` and
`--json-stdin` (pipe JSON in instead of quoting it inline — safer for
richtext with quotes/newlines).

## Gotchas

- **A theme publish in progress doesn't block content.** Before a real edit
  (not a `--dry-run`), `velk.sh` finishes or undoes an interrupted theme
  publish (`references/publish.md`); someone else's publish lock is left alone
  and the edit goes on — content lives in the database, not in `theme/`.
- **Repeater fields** want an array of objects shaped like the inner schema —
  check `item:schema` before guessing.
- **Image fields** are a path/URL string, not a file. Uploads are out of
  scope; have the user upload via admin, then reference the URL.
- **Slug collisions** on create return a clear server error — offer a variant
  or ask, don't silently mutate it.
- **`mysqldump` or `mysql` missing from PATH** on some shared hosts: the
  backup, the restore (and the local copy) then fail with "command not
  found". Tell the person — the host's support knows where they live.
- **Network drop mid-write**: writes are single SQL statements, so don't
  auto-retry — a false-timeout retry can duplicate; the backup is the safety
  net, not a retry loop.
- **Theme blocks in a richtext (v3.9.0+)** are an empty marker in the HTML:
  `<div data-velk-block="key" data-velk-data='{"field":"value"}'></div>`,
  at the top level of the text. `data-velk-data` is a JSON object with the
  block's fields (an image is its media id); inside the attribute write `&`
  as `&amp;` and the delimiting quote as an entity (`&#39;`/`&quot;`) — a raw
  apostrophe in a single-quoted value breaks the tag. `item:create`,
  `item:update` and `page:update` refuse a marker that isn't an empty tag
  or whose data isn't a JSON object, naming the field and block.
- **Never invent a slug.** `item:create` auto-generates it; for updates it
  comes from the user — resolve via `item:list`/`item:get` if they only gave
  a description.
