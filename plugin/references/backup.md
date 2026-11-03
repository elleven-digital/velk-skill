# Backup — snapshot files + database, downloaded locally

A backup is a **point-in-time archive kept off the server**: the project files
plus a full dump of the database, zipped and pulled to your computer. It's your
rollback safety net and your "move this site elsewhere" kit.

**Backup ≠ local copy.** The local copy (`references/access.md`, local mode)
is a working copy of the site for building — the engine from its release,
the theme, the content — and gets refreshed. A backup is a **frozen archive**
you store and don't touch. Use the local copy to *work* on the site; use
backup to *keep a copy safe*.

## What a restorable backup needs

The content, the config, and the uploads. The engine itself is
re-downloadable from `releases.velkcms.com`, so it's optional in the archive:

- **Database** — a `mysqldump` of the whole DB (items, pages, terms, media,
  users, settings, the migrations log). This is the content.
- **`storage/uploads/`** — the media files. Without them, `image_url()`
  returns broken links after a restore.
- **`theme/`** — `site.json` (the schema) + templates. The site's structure
  and design.
- **`.env`, `.htaccess`, `robots.txt`, `.velk-version`** — config + the
  version marker. `.env` holds secrets, so keep the archive private.
- Skip `storage/cache/` (regenerated on demand).

## Backing up a LOCAL install

From the project root — dump the DB (credentials come from `.env`:
`DB_HOST`, `DB_PORT`, `DB_DATABASE`, `DB_USERNAME`, `DB_PASSWORD`), then zip
everything with the dump included:

```bash
mysqldump -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USERNAME" -p"$DB_PASSWORD" "$DB_DATABASE" > db-backup.sql
zip -r "velk-backup-$(date +%Y%m%d).zip" . -x './storage/cache/*' './.git/*'
```

It's already on your machine — done. (`tar czf archive.tgz …` works too.)

## Backing up a REMOTE (deployed) site

Reuse the SSH details in `.deploy/ssh.json` if the project has them. SSH in,
build the dump + archive **on the server**, then pull the single archive down:

```bash
# on the server, in the install dir:
mysqldump -u USER -pPASS DBNAME > db-backup.sql
zip -r /tmp/velk-backup.zip . -x './storage/cache/*'
# from your machine:
scp user@host:/tmp/velk-backup.zip "./velk-backup-$(date +%Y%m%d).zip"
```

On a **no-SSH shared host**: export the DB from phpMyAdmin (Export → SQL) and
download the files over FTP — at minimum `theme/`, `storage/uploads/`, `.env`.

## Restoring

1. Put the files on a PHP 8.2+ / MySQL host (unzip the archive).
2. Create a database and import the dump:
   `mysql -u USER -pPASS NEWDB < db-backup.sql`.
3. Point `.env` at the new DB and set `APP_URL` to the new origin.
4. Load the site. The migrations are already in the dump, so nothing to re-run.

## Gotchas

- **Dump and files must be from the same moment.** A DB from today with an
  older `theme/site.json` can reference fields the schema no longer declares —
  snapshot both together.
- **Keep the archive private** — `.env` carries DB credentials and app secrets.
- **Big uploads → big archive.** For a heavy media library, back up
  `storage/uploads/` separately/incrementally instead of in every zip.
- For a real safety net, automate it with a cron: `mysqldump` + `zip` +
  rotate old archives.
