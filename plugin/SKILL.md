---
name: velk
description: >-
  Work with Velk, a minimalist schema-driven PHP/MySQL CMS (no Composer,
  plain-PHP themes, structure in theme/site.json). Use for ANY task inside a
  Velk project or about Velk: how it works; building or customizing a site
  (site.json schema, fields, templates, helpers, i18n, media, forms, options,
  members); installing a site; upgrading the engine; deploying over SSH;
  pulling production to local; editing live content; converting static HTML
  into a theme; backing up a site. Its bundled scripts run ssh, rsync and
  mysqldump against the servers the user configures, only when asked. Trigger
  on phrases like "como faço X no velk", "adiciona um campo", "cria um
  template", "instala o velk aqui", "sobe o velk na hostinger", "atualiza o
  core do velk", "baixa o site de produção", "faz um backup do velk",
  "converte esse html em tema velk", "edita o conteúdo do painel", their
  English equivalents, or any task in a folder with core/Bootstrap.php or
  theme/site.json.
---

# Velk

Velk is a **minimalist, schema-driven CMS in pure PHP 8.2+** — no Composer, no
build step, runs on cheap shared hosting. It's for developers (and AI agents)
who want WordPress-level convenience without the WordPress weight.

Read this file to orient, then open the matching file in `references/` for the
depth a given task needs. Don't guess field types, helper names, or CLI
commands from memory — they're all listed in `references/building.md` and
`references/cli.md`.

## The rule that is never negotiable: don't touch the engine

Never create, edit or delete anything under an engine path. The list is
`engine_paths` in the release's `engine-manifest.json` — `check-engine.sh`
reads it from the published tarball, because an install deletes its own copy.
As of v3.7 it is: `core/`, `config/`, `bin/`, `migrations/`, `index.php`,
`.htaccess.example`, `nginx.conf.example`, `robots.txt.example`,
`.env.example`, `README.md`, `AGENTS.md`, `CHANGELOG.md`, `docs/messages.md`,
`LICENSE`, `engine-manifest.json`. (The engine ships a `.gitignore` too, but an
install removes it: the project's own `.gitignore` is the project's.)

**Why:** an upgrade replaces every one of those paths wholesale. An edit there
vanishes on the next upgrade without a warning — and until then the local copy
quietly differs from production, so whatever it "fixed" is broken on a server
nobody is looking at.

**Instead:** everything a site needs lives in `theme/` — `site.json`,
templates, partials, assets — and load-time PHP goes in `theme/functions.php`.
When the engine doesn't offer something, that's a feature request for Velk,
not a local patch.

**Example:** a client wants a custom block inside the rich-text editor. The
answer is a theme block: declared under `richtext_blocks` in `site.json` and
drawn by a partial in `theme/partials/richtext/` (v3.9.0+; on an older engine,
a `flexible` field beside the text) — never an edit to
`core/Admin/assets/js/tiptap.js`.

`scripts/check-engine.sh --project .` compares the local engine with its
published release, file by file (`ENGINE_OK`, or one `CHANGED`/`ADDED`/
`MISSING` line per difference). `init` runs it first and refuses to deploy an
edited engine.

## The mental model (internalize this first)

Five ideas explain almost everything:

1. **`theme/site.json` is the source of truth for structure.** Pages, item
   types (posts, cases, services…), taxonomies, custom fields, forms, options,
   members — all declared there. The admin panel is *generated* from it. To
   change what the site can hold, you edit this JSON, not the database.

2. **The theme is plain PHP, and it's a separate package.** `theme/` holds
   `.php` templates that print content using **helper functions** (`field()`,
   `image_url()`, `url()`, `e()`…). No template DSL, no hooks/filters. The
   theme is the project; ship a different theme per client.

3. **The engine is a dependency — see the rule above.** `core/`, `config/`,
   `bin/`, `migrations/` and the other engine paths are Velk itself, replaced
   wholesale on upgrade. All customization lives in `theme/` (and
   `theme/functions.php` for load-time PHP).

4. **Content lives in MySQL; custom fields are JSON columns.** No
   `wp_postmeta`. `bin/velk` is the CLI; the admin panel is the UI. Title,
   slug and publish date are the only built-in fields — everything else is a
   custom field you declared in `site.json`.

5. **Velk is installed from a tarball, not git.** The engine is downloaded
   from `releases.velkcms.com` (a versioned `versions.json` + tarballs).
   Upgrades replace only the engine paths and preserve `theme/`, `storage/`,
   `.env`. The installed version is recorded in `.velk-version`.

## Golden rules (why they matter)

- **Escape output with `e()` everywhere.** `<?= e($value) ?>`. The single
  exception is trusted richtext HTML — and you comment it (`/* trusted */`).
  Skipping this is how stored-XSS gets into a client's site.
- **Never bind templates to slugs.** Templates are bound *by file name* in
  `site.json`. Slugs are content and change; template bindings are code.
- **Go through helpers for every URL/asset/image** (`url()`, `asset()`,
  `admin_url()`, `image_url()`, `Item::url()`…). They prepend the install base
  path, so the site keeps working in a subdirectory install. Never hardcode
  `/blog`.
- **Never build SQL with string interpolation** — the engine uses PDO
  prepared statements throughout; stay on that path.
- **After editing `site.json`, run `bin/velk schema:validate`.** It catches
  the mistakes (bad field shape, missing template, duplicate names) that would
  otherwise only surface as a broken admin screen.
- **Customize in `theme/`, extend in `theme/functions.php`** (load-time only).
  There is no plugin system by design.
- **CSS and JS URLs carry a version** — `asset('theme/style.css') . '?v=' .
  filemtime(…)`. Velk's `.htaccess` lets browsers keep them for a month and
  `asset()` adds no version: without it a change "doesn't show up", and a
  returning visitor gets new HTML with old CSS (`references/publish.md`).

## Which scenario are you in?

Pick the task; read the reference; follow it. Each reference is
self-contained and explains the *why*, not just the steps.

| You want to… | Read |
|---|---|
| Understand Velk / build or customize a site (schema, fields, templates, helpers, media, forms, options, members) | **`references/building.md`** |
| Make a site multi-language (URL prefixes, per-content translation, fallbacks) | **`references/i18n.md`** |
| Know the CLI (`bin/velk`) commands | **`references/cli.md`** |
| Install a fresh Velk in an empty folder | **`references/install.md`** |
| Upgrade the engine to a newer version | **`references/upgrade.md`** |
| Know what a specific version needs beyond swapping files (data to preserve before a destructive migration, a renamed theme function) | **`references/upgrade-notes.md`** |
| Deploy the project to a server (SSH) | **`references/deploy.md`** |
| Publish theme changes — versioned, safe with several people on one theme | **`references/publish.md`** |
| Connect to a site from an access file ("conecte esse site"), or generate one for a client ("crie um arquivo de acesso") | **`references/access.md`** |
| Switch between a full local copy and editing the live site | **`references/access.md`** |
| Work on a live site from a full local copy (engine, theme, content — nothing personal) | **`references/access.md`**, local mode |
| Create/edit content on a deployed site (SSH) | **`references/content.md`** |
| Turn a folder of static HTML/PHP into a Velk theme | **`references/theme-convert.md`** |
| Back up a site (zip files + DB, download locally) | **`references/backup.md`** |

If you're unsure whether a folder is a Velk project: it is if it has
`core/Bootstrap.php` (installed engine) or `theme/site.json` (the schema).

## The SSH actions ship real scripts

Deploy, the local copy and remote content aren't prose to improvise — they
run tested shell in `${CLAUDE_SKILL_DIR}/scripts/` (the `scripts/` folder next to
this file):

```
scripts/ssh-lib.sh          shared transport: config, ssh, rsync, bin/velk on the server
scripts/preflight.sh        before touching a server: SSH, what the target holds, its database
scripts/check-engine.sh     local engine == its published release?
scripts/deploy/             init · update-cms (the first deploy; the engine)
scripts/theme/              publish · recover · download-theme · workspace
scripts/access/             generate · connect
scripts/local/              env · content (the local copy for "local" mode)
scripts/content/            velk (any bin/velk command on the server) · backup · restore
scripts/remote/db.sh        what's read from the server's .env: every database step, public settings
```

Every script takes `--project <dir>` — the project, whose config is
`<dir>/.deploy/ssh.json` (`--config <file>` for one elsewhere) — prints
progress to stderr and answers on stdout: stable `KEY=value` lines, `STATUS=`
first when there is more than one outcome (the content scripts, one line of
JSON; `init` and `update-cms`, a report). The two `connect.sh` steps that run
before there is a project, `platform` and `inspect <file>`, are the exception:
they take no `--project`. None of them prompts: put the answers in the user's
words, and ask the questions yourself between two calls. Read a script before
invoking it — the script, not the reference, is the source of truth for what
actually runs. Install, upgrade and theme-convert have no scripts; they're
procedures you carry out step by step.

The destructive ones self-guard — `init` refuses a target that already has
Velk; `update-cms` and a publish refuse one without it — but the guard only
helps if you run `scripts/preflight.sh` first. Do that before anything else,
every time.

## The everyday loop (building/customizing)

Most work is this cycle — the details are in `references/building.md`:

1. Edit `theme/site.json` — add a field, a type, a taxonomy, a page.
2. `./bin/velk schema:validate` — verify the JSON.
3. `./bin/velk page:sync` — seed page rows if you added/renamed pages.
4. `./bin/velk migrate` — only if new migration files were added (rare; that's
   engine work, not theme work).
5. Edit/create the template in `theme/templates/`, printing content with
   helpers. Bind it by file name in `site.json`.
6. Use the admin panel to fill content. Locally, `./bin/velk serve` runs a dev
   server (default `http://localhost:8080`).

## Verifying a change actually works

Don't declare a change done from a green lint alone — *look at it*:

- Schema change → `bin/velk schema:validate` must pass, then open the admin
  screen (or `serve` locally) and confirm the field renders and saves.
- Template change → load the page (dev server or the live URL) and confirm it
  renders, in every language if the site is multi-language.
- Deploy/upgrade/backup → verify against the produced artifact (the live URL,
  the new `.velk-version`, the downloaded archive) — see each reference's
  "verify" step.

## Deployment shapes to keep in mind

Velk runs anywhere with PHP 8.2+ and MySQL/MariaDB:

- **Shared hosting without SSH** (cPanel, etc.): upload files by FTP; the
  engine **auto-migrates on the first web request** (`AUTO_MIGRATE`, on by
  default) so no CLI step is needed to finish an upgrade.
- **SSH hosts / VPS / cloud**: use the deploy, publish and content flows in
  `references/`.
- **Subdirectory installs** (`site.com/velk/`): work automatically because the
  helpers prepend the base path — provided the theme always uses them.

## Two ways to work on a live site

A site connected from an access file is worked on in one of two modes, chosen
at setup and switchable any time (`references/access.md`):

- **local** — a full copy on the Mac (engine, theme, content — nothing
  personal), for building and restyling pages. Publish with
  `scripts/theme/publish.sh run --project .`.
- **live** — nothing installed. Every request that changes the theme opens a
  throwaway copy of the live theme (`scripts/theme/workspace.sh open`), edits
  it, publishes it versioned, and closes it. Nothing of the theme stays on the
  Mac between requests.

In both: **never edit files on the server directly** — always download, edit,
publish. A server-side edit skips every check and becomes a "change made
outside" for the next person. Content-only requests (a post, a page built from
existing blocks) don't touch the theme at all: `references/content.md`.
