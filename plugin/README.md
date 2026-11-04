# velk — Claude Code plugin

The official [Claude Code](https://claude.com/claude-code) plugin for working
with **[Velk](https://velkcms.com)** — a minimalist, schema-driven PHP/MySQL
CMS (no Composer, plain-PHP themes). It gives Claude the context and the
tested scripts to build, deploy, and maintain Velk sites.

One skill, every Velk scenario:

- **Build & customize** — `site.json` schema, custom fields, templates,
  helpers, media, forms, options, members, i18n.
- **Install** a fresh site · **upgrade** the engine.
- **Deploy** to a server over SSH · **work** on a live site from a full local copy.
- **Edit live content** over SSH · **convert** static HTML into a theme.
- **Back up** a site (files + database, downloaded locally).

## Install

### Claude Code

In a Claude Code session (2.1.275 or later):

```
/plugin install velk --marketplace elleven-digital/velk-skill
```

From a terminal (Claude Code 2.1.292 or later):

```bash
claude plugin install velk --marketplace elleven-digital/velk-skill
```

In the Claude app: **Customize → Plugins → Add → Add marketplace**, enter
`elleven-digital/velk-skill`, then add **velk**.

Start a new session, or run `/reload-plugins`. The skill loads by itself when
you work on a Velk project; to call it by name, use `/velk:velk`.

**Updates.** Each release raises the plugin version. Marketplaces added in the
Claude app update on their own. In Claude Code, turn auto-update on once in
`/plugin` → **Marketplaces** → **velk**, or update by hand with
`claude plugin update velk@velk`.

### Without the plugin

The same skill is published as a package at skill.velkcms.com. Ask Claude
Code:

```
Install the Velk skill from skill.velkcms.com into ~/.claude/skills/velk
```

Or do it by hand:

```bash
mkdir -p ~/.claude/skills/velk
curl -fsSL https://skill.velkcms.com/velk-skill-latest.tar.gz \
  | tar xz --strip-components=1 -C ~/.claude/skills/velk
```

Run the same command again to update.
`https://skill.velkcms.com/versions.json` lists every published version with
its `sha256`, if you need to pin one or verify a download.

**Moving to the plugin.** Once the plugin is installed, delete
`~/.claude/skills/velk`, so only the plugin's copy loads.

## What it runs and where it connects

The skill acts only when you ask. Everything that touches a server goes
through the scripts in `scripts/`, which you can read before running them:

- **Your servers, over SSH.** `ssh`, `scp` and `rsync` reach the server you
  describe in your project's `.deploy/ssh.json`: to deploy, publish a theme,
  edit content, copy a live site to your Mac and back it up.
- **Your databases.** `mysqldump` and `mysql` copy databases between your Mac
  and that server. Passwords go through option files, never on a command line.
- **Velk releases.** `curl` downloads the engine from `releases.velkcms.com`
  and checks its `sha256` before unpacking. After a deploy, it checks that
  your site answers.
- **Your Mac.** For a full local copy it can install PHP and MySQL with
  `brew install`. If Homebrew is missing, it gives you the official installer
  command to run yourself.

The skill sends no data to Elleven Digital or anyone else, and collects no
usage data.

## Privacy

What the plugin handles, where it stays and where it connects:
[privacy policy](PRIVACY.md).

## How it works

`SKILL.md` is a lean orientation + router — Claude reads it to understand Velk
and pick the right workflow. The depth for each scenario lives in
`references/`, loaded only when a task needs it (progressive disclosure):

| Scenario | Reference |
|---|---|
| Build / customize a site | `references/building.md` |
| Multi-language (i18n) | `references/i18n.md` |
| CLI (`bin/velk`) | `references/cli.md` |
| Fresh install | `references/install.md` |
| Upgrade the engine | `references/upgrade.md` |
| Deploy (SSH) | `references/deploy.md` |
| Versioned theme publish | `references/publish.md` |
| Access files · local or live mode · a full local copy | `references/access.md` |
| Edit live content (SSH) | `references/content.md` |
| Static HTML → theme | `references/theme-convert.md` |
| Backup (files + DB) | `references/backup.md` |

## Requirements

The SSH scripts run on **macOS 15 (Sequoia) or newer** with nothing to install:
they rely on what the system ships — `bash`, `perl`, `jq` (bundled since macOS
15), `rsync`, `diff3`, `ssh`. The server needs only what every Velk install
has: PHP and `rsync`. PHP and MySQL on the Mac are needed only for a full
local copy, and the skill offers to install them with Homebrew.

## Development

The tests, the release tooling and the maintainers' notes live in the
repository root, outside this folder:
https://github.com/elleven-digital/velk-skill

## Links

- Velk — https://velkcms.com
- Maintained by [Elleven Digital](https://github.com/elleven-digital)

## License

MIT — see [LICENSE](LICENSE).
