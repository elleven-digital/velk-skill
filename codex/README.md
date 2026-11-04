# Velk plugin for ChatGPT and Codex

Velk is a minimalist, schema-driven CMS in pure PHP (no Composer, plain-PHP
themes, the site's structure in `theme/site.json`). This plugin gives Codex the
context to build and change Velk sites, and tested scripts for the server side:
installing a site, upgrading the engine, deploying over SSH, publishing a
theme, editing live content, copying production to your computer and backing
up files and databases.

It is **desktop only**: the scripts run on your computer, in threads that run
locally, so install it from the ChatGPT desktop app.

## Use

The skill loads by itself when you work in a Velk project — a folder with
`core/Bootstrap.php` or `theme/site.json`. To call it by name, mention `$velk`.

Some things to ask:

- "Turn this static HTML into a Velk theme"
- "Add a gallery field to the post type in site.json"
- "Deploy this Velk site to my server over SSH"
- "Back up the production site to my computer"

## What it runs and where it connects

The skill acts only when you ask. Everything that touches a server goes through
the scripts in `skills/velk/scripts/`, which you can read before running them:

- **Your servers, over SSH.** `ssh`, `scp` and `rsync` reach the server you
  describe in your project's `.deploy/ssh.json`, signing in with your own SSH
  key: to deploy, publish a theme, edit content, copy a live site to your
  computer and back it up.
- **Velk's release server.** Installs and engine upgrades download the
  published engine from `releases.velkcms.com` and check its `sha256` before
  using it.

It sends nothing to Elleven Digital: no analytics, no telemetry. See
[PRIVACY.md](PRIVACY.md).

## Support

Issues and questions: https://github.com/elleven-digital/velk-skill/issues

The plugin for Claude is the same skill: https://github.com/elleven-digital/velk-skill
