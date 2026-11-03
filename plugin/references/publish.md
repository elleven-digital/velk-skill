# Publishing theme changes — versioned, never overwriting

Several people can work on one theme: each publish first takes in whatever the
others published, and a publish only ever adds a version on top of what is
live. In `references/deploy.md`, "update-theme" is this same flow.

## The model

- The server records what is live in `.velk-theme.json`, next to
  `.velk-version`: a version number, who published it and when, and a sha256
  per theme file. The version goes up by one per publish — only on a publish.
- The local copy remembers where it started: `.deploy/theme-base.json` (the
  version and file hashes it was taken from) and `.deploy/theme-base/` (an
  untouched copy of those files). Downloads, workspaces and every successful
  publish refresh it.
- Publishing compares, file by file, three things — that starting point, the
  local copy, and what is live — and merges.
- "The theme" is decided by rsync with one set of filters, everywhere: sending,
  downloading, hashing on either side. `install/seed.php`, `storage/`, `*.bak`,
  `.DS_Store`, `*.swp`, root `*.php` except `functions.php`, plus the config's
  `rsync.theme_extra_excludes`, are never part of it.

Example: live is v3; you and João both start from v3. João publishes: the
server still matches his starting point → v4. You publish: the server moved
past yours, so your copy takes in João's changes and gets checked → v5.

## Running it

`scripts/theme/publish.sh run --project <dir>` does it all when nothing needs
a person; otherwise it stops with a status. Handle it, then
`scripts/theme/publish.sh commit --project <dir>` — or `abort`. `<dir>` is
the project in local mode, `.deploy/workspace` in live mode. When `run` gets
as far as commit, the `STATUS` is commit's, and the prepare half's
`GONE_FROM_SERVER`, `WARN` and `RECOVERED` lines follow it.

When a script can't reach the server at all, `scripts/access/connect.sh test
--project .` says why — a key removed from the hosting shows as
`NOT_AUTHORIZED`.

| STATUS (exit) | Means | Do |
|---|---|---|
| `PUBLISHED` (0) | live as `VERSION` | report (below) |
| `UP_TO_DATE` (0) | nothing in this copy differs from what's live | say so; `TOOK_THEIRS` lines came in from the server, `GONE_FROM_SERVER` lines were deleted there (so here too), and any `WARN` still stands |
| `ABORTED` (0) | `abort` put the theme files and their starting point back | say so |
| `NO_PLAN` (2) | `commit` found no plan: the prepare half stopped before writing one, or never ran | `run` again |
| `CONFLICTS` (3) | the same lines — or the same file — changed on both sides | see Conflicts |
| `UNRESOLVED_CONFLICTS` (3) | conflict markers are still in a `CONFLICT_FILE`, or a `CONFLICT` that leaves no marker still waits for a decision | finish resolving (see Conflicts) |
| `NEEDS_CONFIRMATION` (4) | the publish deletes live files (`DELETE` lines) | list them and ask; yes → `commit --confirm-deletions` (only `commit` takes it) |
| `DELETIONS_CHANGED` (4) | the local copy changed after the list was shown | run again and show the new list |
| `BUSY` (5) | someone is publishing right now — possibly another session of this same person (`OWNER`; `AGE` in seconds; `PID`, its process on `OWNER`'s machine) | "A Maria está publicando agora — tento de novo em um minuto?" — yes → `run` again |
| `STALE_LOCK` (5) | a publish died 15+ minutes ago (`OWNER`, `AGE`) | explain and ask; yes → run again with `--take-over-stale` |
| `BASE_AHEAD` (6) | this copy claims to start from a version the server never reached (server restored from a backup, its record deleted; `SERVER_VERSION=none` when there is no record) | explain; if the person confirms the server is the truth, delete `.deploy/theme-base.json` and `.deploy/theme-base/` and run again — every difference then becomes a question |
| `LOCAL_INVALID` (7) | local checks failed (`PHP_LINT`, `SCHEMA`) | fix and run again — nothing reached the server |
| `SOURCE_LEFTOVERS` (7) | the local theme still holds pages of a converted site's source (`LEFTOVER` lines): a PHP in the theme's root other than `functions.php`, or `theme/includes/` — the same rule `init` applies. Checked before anything touches the server, again at `commit` | they aren't the theme (references/theme-convert.md keeps the source in `_source/`): after the person's OK, delete them and run again |
| `STALE_PLAN` (8) | someone published between prepare and commit | run again: their publish gets merged too |
| `STAGING_INVALID` (9) | the server's checks refused the staged theme (`DETAIL`) | fix and run again — it never went live |
| `LIVE_INVALID` (9) | it went live, failed validation (`FAILURE`) and was swapped back at once | fix and run again — the version didn't change |
| `LIVE_ALREADY_FAILING` (10) | before anything was sent to the server, the live site already fails `schema:validate` or its home page answers a server error — one `FAILURE` line each, and `DETAIL` lines with what `schema:validate` said. This copy may already hold the server's changes: the usual `TOOK_THEIRS`, `GONE_FROM_SERVER`, `MERGED` and `CONFLICT` lines follow | tell the person what fails now, not because of this publish, and report the merge lines as usual (a `CONFLICT` still needs resolving — see Conflicts). To publish anyway (a fix, say), after their OK run again with `--accept-live-failure`: those failures then only warn (`WARN=STILL_FAILING …`), any other still swaps back — a recovery after a crash judges by the same rules |
| `NO_VELK` (11) | the server has no Velk at `remote_path` | say so; nothing was sent — the first deploy is `init` (`references/deploy.md`) |

## What happens

**prepare** — apart from step 1, takes no lock and never writes to the server.
It first refuses a local theme with source leftovers (`SOURCE_LEFTOVERS`).

1. Finishes or undoes an interrupted publish (below).
2. Reads the server's record and hashes what is live. PHPs in the live
   theme's root other than `functions.php` are outside every manifest — a
   publish can neither see nor delete them —, so they come back as
   `WARN=SERVER_LEFTOVERS <paths>`: tell the person; removing them is by hand.
3. Decides:

   | Situation | `DECISION` |
   |---|---|
   | live still matches this copy's starting point | `fast` — nothing to merge |
   | live moved on: someone published, or changed files by hand (`WARN=CHANGED_OUTSIDE_THE_SKILL`) | `merge` |
   | no starting point, or the server's record is unreadable (`WARN=SERVER_RECORD_UNREADABLE`) | `two-way` — a file on both sides that differs becomes a question; nothing is joined silently. A file on one side only is kept, or brought in (`TOOK_THEIRS`) — so one deleted here comes back. The retry right after, with nothing new live, doesn't ask again |

4. Merge: downloads what's live, backs up the local theme files (what
   `abort` restores; files outside the theme are never touched), merges into
   the local theme. A file the server deleted leaves this copy too
   (`GONE_FROM_SERVER`). The starting point becomes what's live — so a retry
   never merges the same changes twice.
5. Local checks, in local mode only: `php -l` on every theme PHP file and
   `schema:validate`; warns when the local PHP differs from production's.
   Opening the pages you changed in `bin/velk serve` and looking at them is
   yours to do before `commit` (SKILL.md, "Verifying a change actually
   works").
6. `WARN=CACHE_BUSTING` when CSS or JS changed and the theme loads CSS/JS
   through `asset()` without a version in the URL.

**commit** — holds the lock:

1. Copies the local theme as it is now. That copy is what gets checked, sent
   and recorded — except the local `schema:validate`, which the engine runs on
   `theme/` itself: a file saved while the publish runs waits for the next one.
2. Takes `.velk-theme.lock/`; a fresh lock of someone else means `BUSY`.
3. Checks the server is still exactly what prepare saw — else `STALE_PLAN`.
4. Copies the live theme to `.velk-theme-staging/` and sends only the
   differences.
5. Checks the staged copy with plain PHP: `php -l` on every theme PHP file,
   `site.json` decodes.
6. Swaps: `theme/` → `.velk-theme-previous/`, staging → `theme/` — two renames,
   instant.
7. Validates live: `schema:validate` and `page:sync` by exit code, and the
   home page (`site.url` + `subpath`, asked past any page cache) not answering
   a server error (5xx) or nothing at all. Another code — 401 behind a
   password, 403 from a firewall — says nothing about the theme: it only warns
   (`WARN=HOME_PAGE_ANSWERED_<code>`), unless the home answered 2xx just before
   the publish: then any other answer fails. Any failure swaps back immediately, and
   `page:sync` runs again so page titles follow the theme that went back.
8. Records the new version from what is live, removes the previous copy,
   releases the lock. The local starting point becomes what was published.
   Once the version is recorded the publish stands: a failure after that is
   a warning, and the next action cleans up.

## Conflicts

For each `CONFLICT` line, show the person in plain words what the file was at
the starting point, what they changed, what the other side changed, and the
combination you propose. Nothing goes live without their OK.

| Kind | The local file now holds | Resolve by |
|---|---|---|
| `text` | both versions between `<<<<<<< local`, `\|\|\|\|\|\|\| base`, `=======` and `>>>>>>> server` | writing the agreed combination, markers gone — or `resolve <path> local\|server` to keep one side whole |
| `added-both` | the same markers — both sides created the file | the same |
| `invalid-json` | a clean line-by-line merge of `site.json` that isn't valid JSON (both added a last item to one list, say) | fixing the JSON — it counts as settled once `site.json` is valid |
| `binary` | this copy's version | `resolve <path> local` keeps it; `resolve <path> server` takes the live one |
| `changed-here-deleted-there` | this copy's version | `resolve <path> local` keeps it; `resolve <path> server` deletes it |
| `deleted-here-changed-there` | the server's version | `resolve <path> server` keeps it; `resolve <path> local` deletes it |

Every conflict is recorded until it is settled: one with markers once its
markers are gone, `site.json` once it is valid JSON, and any of them with
`scripts/theme/publish.sh resolve --project <dir> <path> local|server`, which
answers `STATUS=RESOLVED` (with `PATH`, `KEPT`), or `STATUS=NOT_OPEN` (2) when
nothing waits on that path. Until then, prepare and commit stop with
`UNRESOLVED_CONFLICTS` and one `CONFLICT` line per file.

Then `commit`. If the person gives up, `abort` puts the local theme files and
their starting point back exactly as they were before the first prepare.

## Interrupted publishes

Everything that touches the site — publish, download, content edits — first
runs `scripts/theme/recover.sh`. It acts only when the lock is free; stale —
and then only with `--take-over-stale`, after asking; or the person's own
(same identity and machine) left by a process that is gone. The lock records
which process holds it, so another session of the same person that is still
publishing counts as someone else: `BUSY`.

| Left behind | It |
|---|---|
| a staging copy | removes it |
| the new theme swapped in, not recorded | validates what's live by the publish's own rules (the failures it accepted, the home's answer before it): passes → records it, finishing the publish, with its `WARN` lines; fails → swaps back |
| the same, with the server's record unreadable | validates; passes → keeps the theme without guessing a version (the next publish rewrites the record) |
| the new theme swapped in and recorded | only cleans up — a version is never counted twice |
| `theme/` missing, the previous copy there | puts the previous theme back |
| the rejected theme of a swap-back (`.velk-theme-failed/`) | removes it |

A fresh lock of someone else is a publish in progress: nothing of it is
touched. Content edits go on anyway — content lives in the database, not in
`theme/` — while downloads wait.

## CSS and JS: always a version in the URL

Velk's `.htaccess` lets browsers keep CSS and JS for a month, and `asset()`
adds no version: a new color "doesn't show up", and a returning visitor can
get new HTML with old CSS. Load them with the file's modification time:

```php
<link rel="stylesheet" href="<?= e(asset('theme/style.css') . '?v=' . filemtime(dirname(__DIR__) . '/style.css')) ?>">
```

(`dirname(__DIR__)` assumes the tag sits in a file under `theme/partials/`.)

## Report

```
✓ Publicado como v5.
Juntei as mudanças que o João publicou na v4 — 2 arquivos, sem conflito.
```

Mention any `WARN`, and each `GONE_FROM_SERVER` file (deleted on the server,
so removed here too). Never report success from anything but
`STATUS=PUBLISHED`.

## On the server

| Path | Exists | Purpose |
|---|---|---|
| `.velk-theme.json` | always | version, who, when, a hash per file |
| `.velk-theme.lock/` | during a publish | the lock — `mkdir` is atomic; who holds it, which process, since when |
| `.velk-theme-staging/` | during a publish | the new theme before it goes live |
| `.velk-theme-previous/` | during a publish | the theme that was live, for the swap-back |
| `.velk-theme-failed/` | during a swap-back | the rejected theme, on its way out |
| `.velk-theme-check` | during a publish | the live check's rules for it — the failures the person accepted, the home's answer before — so a recovery judges by the same rules |

All of them sit beside `theme/` — same filesystem, so the swap is a rename —
and `theme/` itself must be a real folder: a publish refuses a link, which it
would write through. Velk's `.htaccess`/`nginx.conf.example` refuse dot-paths
on the web. No copy of the theme stays on the server after a publish. A site whose
`.htaccess` came from an older template may lack that rule — check once:
`curl -sI https://<site>/.velk-theme-staging/probe` must answer 403, the rule
at work. A 404 (the request fell through to Velk) or a 200 means it's
missing: the site's `.htaccess` — or, on nginx, the server config — needs the
dot-path rule of Velk's current `.htaccess.example` / `nginx.conf.example`.
Tell the person.
