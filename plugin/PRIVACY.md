# Privacy policy — Velk plugin for Claude

Effective 4 November 2026. Published by Elleven Digital (https://elleven.digital).

## Summary

The Velk plugin collects nothing. It has no analytics or telemetry and sends no
data to Elleven Digital. It runs on your computer, only when you ask Claude for
a Velk task, and connects only to the servers you configure.

## What it handles, and where that stays

- **Connection settings.** A project's `.deploy/ssh.json` holds your server's
  address, user and paths and, when a deploy or a local copy needs them, the
  database passwords. It stays in that project folder on your computer and is
  kept out of git.
- **Your SSH key.** `ssh`, `scp` and `rsync` sign in to your server with your
  SSH key (by default `~/.ssh/id_ed25519`), as any SSH client does. The key
  never leaves your computer. If you have none, the plugin can create one
  there.
- **Site files, databases and backups.** When you ask, the plugin copies files
  and databases between your computer and your server. A backup is a full copy,
  so it can include personal data your site stores, such as form submissions
  and member accounts. It is saved on your computer and kept until you delete
  it. A local working copy leaves out users, members, orders and form
  submissions.
- **Access files.** An access file (`<domain>.velk`) carries only public
  settings — server, paths, URLs, names — never a password or a key.

## Where it connects

- **Your servers and databases**, over SSH, as you configure them.
- **`releases.velkcms.com`**, to download Velk releases (`versions.json` and the
  release archives). These are plain downloads: the plugin sends no account,
  site or personal data. The files are served through Cloudflare, which, like
  any web host, processes standard request data such as your IP address to
  deliver them.
- **Your own site's address**, to check that it answers after a deploy or a
  publish.
- **Homebrew**, only if you ask for a full local copy and agree to install PHP
  and MySQL with `brew install`.

## Claude

The plugin runs inside Claude. What you share in a conversation, and what Claude
reads while it works, is handled under Anthropic's privacy policy:
https://www.anthropic.com/legal/privacy.

## Children

The plugin is not intended for anyone under 18.

## Changes and contact

Changes to this policy are published in this file, and its history is in the
repository. For questions, open an issue at
https://github.com/elleven-digital/velk-skill/issues.
