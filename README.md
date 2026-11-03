# velk-skill

The official [Claude Code](https://claude.com/claude-code) plugin for
**[Velk](https://velkcms.com)**, a minimalist, schema-driven PHP/MySQL CMS. It
gives Claude the context and the tested scripts to build, deploy and maintain
Velk sites.

## Install

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

What the plugin does, what it runs and where it connects:
[`plugin/README.md`](plugin/README.md).

## Repository layout

| Path | What it is |
|---|---|
| `plugin/` | The plugin, and the only folder that reaches users: `SKILL.md`, `references/`, `scripts/` and its manifest |
| `.claude-plugin/marketplace.json` | The `velk` marketplace, listing `plugin/` |
| `tests/` | The test suite for the scripts and the manifests |
| `tools/` | Release tooling: the package and page at skill.velkcms.com |
| `VERSION` | The release version, kept equal to `plugin/.claude-plugin/plugin.json` |
| `PUBLICAR.md` | Release steps (Portuguese) |

## Tests

```bash
bash tests/run.sh            # everything
bash tests/run.sh publish    # only tests/*publish*_test.sh
```

The server is a folder and the transport a fake `ssh` on `PATH` (`tests/bin/`),
so every script runs unmodified; the rest of `PATH` is a stock macOS. Tests
that stand in for the server need a `php` on the development machine and are
skipped without one.

To check the manifests: `claude plugin validate .` (the marketplace) and
`claude plugin validate plugin` (the plugin).

To try a change before releasing it, load the folder for one session:
`claude --plugin-dir ./plugin`.

## License

MIT — see [LICENSE](LICENSE).
