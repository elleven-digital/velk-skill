# Access files — connecting a site without the technical setup

An access file (`<domain>.velk`) lets an agency hand a client what's needed to
work on a site, and lets the client's Claude set everything up: config, SSH
key, working mode, local environment. It carries **no secret** — access only
exists once someone authorizes the public key of the client's Mac — so it can
travel by WhatsApp or email.

Platform: macOS 15 or newer, the first to ship `jq`. Anywhere else, stop
before doing anything and say so.

## Generate — "crie um arquivo de acesso desse site" (agency side)

Needs the site's `.deploy/ssh.json`. Nothing to ask: whoever has access to the
hosting authorizes the client's key, and the file doesn't say who.

1. `scripts/access/generate.sh --project .`
2. Hand over the file (the `ACCESS_FILE=` line) with a message to forward:

   > Abra o Claude, na aba **Code**, numa pasta nova, anexe este arquivo e diga: **conecte esse site**.

The file is assembled field by field from an allowlist — never copied from the
config, which holds the production database password — and re-read before it
is kept. An unexpected key, or any config value outside the public ones
(server, paths, URLs, names) found anywhere in it, deletes the file and fails
with exit 3, naming the config *paths* involved, never their values. An SSH
alias is resolved to the real host, port and user with `ssh -G`: the client
doesn't have the agency's `~/.ssh/config`. The server's `remote.php_bin` and
`rsync.theme_extra_excludes` travel too, so both sides run the same PHP and
the same theme filters; a config value the client would refuse (below) stops
the generation with exit 2.

## Connect — "conecte esse site" (client side)

In the folder the client opened, which becomes the project folder:

1. `scripts/access/connect.sh platform` → `STATUS=OK`, or stop:
   `MACOS_TOO_OLD` / `UNSUPPORTED_OS`.
2. `scripts/access/connect.sh inspect <file>` → show `SITE`, `SERVER` and
   `CREATED_BY`, and ask for confirmation — which also guards against a forged
   file pointing at someone else's server. `STATUS=INVALID` → the file is
   damaged or was altered (`REASON` names the field); ask for a new one.
   Every field must have the one shape it can have — a host or user that ssh
   could read as an option, a quote or `$` in a path, a control character in
   a name: the file arrives by WhatsApp or email, and is checked as such.
3. Ask the person's name (suggest the Mac account's full name). It becomes
   `identity`: in the comment of a key created here, in the publish lock, in
   "published by".
4. `scripts/access/connect.sh setup <file> --project . --identity "<name>"` —
   writes `.deploy/ssh.json` (0600, no database section: this machine never
   gets the production password) and keeps `.deploy/` out of git.
5. `scripts/access/connect.sh key --project .`
   - `STATUS=AUTHORIZED` → access already works: go to 7.
   - `STATUS=NEEDS_AUTHORIZATION` → show `PUBLIC_KEY` in a code block,
     followed by exactly this and nothing else:

     > Autorize essa chave SSH na sua hospedagem.

   - `UNREACHABLE`, `HOST_KEY_CHANGED` or `FAILED` → as in step 6: authorizing
     a key wouldn't help, and none is shown. Once it's sorted out, run step 5
     again.

   The key is the Mac's own: the one this project already uses, else
   `~/.ssh/id_ed25519`, `~/.ssh/id_rsa` or a `~/.ssh/velk_ed25519` made here
   before — as long as it opens without a passphrase (with one, every
   non-interactive `ssh` fails without saying why). With none, the script
   creates `~/.ssh/id_ed25519`, or `~/.ssh/velk_ed25519` when something else
   already sits there (a key with a passphrase, a lone `.pub`): it never
   writes over a file it didn't create. A key created here is commented
   `velk <name> <date>`, so it's easy to spot on the server. The same key
   serves every site this Mac connects to: a second site only needs it
   authorized on that hosting.
6. Once they say it's done: `scripts/access/connect.sh test --project .`

   | STATUS | Tell the person |
   |---|---|
   | `AUTHORIZED` | connected |
   | `NOT_AUTHORIZED` | the key isn't authorized yet — or was pasted incomplete, or the file names the wrong user |
   | `UNREACHABLE` | the server didn't answer — address, port or network |
   | `HOST_KEY_CHANGED` | the server's identity changed: stop and confirm with the agency first — it can be a server move, or someone impersonating it. Only once the agency confirms a move: `ssh-keygen -R '[<host>]:<port>'` (plain `<host>` on port 22; both in `.deploy/ssh.json`), then step 5 again |
   | `FAILED` | show `DETAIL` |

7. Ask the working mode.

## Working modes

Ask by intent, not by jargon:

> "Se você vai criar páginas ou mudar o visual do site, vale ter uma cópia
> completa no seu Mac — é como você vê o que está fazendo antes de ir pro ar.
> Se vai fazer ajustes pontuais, dá pra editar direto no site."

`scripts/access/connect.sh mode local|live --project .` records the choice.
The person can switch any time ("quero rodar o site localmente", "quero editar
direto no ar").

### live — straight on the site

Nothing gets installed. **Every request that changes the theme** runs:

1. `scripts/theme/workspace.sh open --project .` — a fresh copy of the live
   theme in `.deploy/workspace/` (hidden in Finder), with its starting point.
   An old workspace is always discarded, never reused: for a merge, a file
   deleted by accident looks exactly like one deleted on purpose. Someone
   else publishing stops it with `STATUS=BUSY` or `STALE_LOCK` (exit 5):
   handle it as `references/publish.md` says — a stale lock is taken over,
   after asking, with `--take-over-stale`.
2. Edit inside `.deploy/workspace/theme/`.
3. `scripts/theme/publish.sh run --project .deploy/workspace` —
   `references/publish.md`.
4. `scripts/theme/workspace.sh close --project .` — whether it published or
   the person gave up.

- "Editing live" never means editing files **on** the server. It is always
  download, edit, publish: a server-side edit skips every check and turns
  into a "change made outside" for the next person who publishes.
- A new page under construction gets its own CSS file, loaded only by its
  template, so iterating on it can't break the rest of the site. A one-off
  change to an existing rule edits the rule where it lives.
- When someone starts iterating visually on a new page — publish, look,
  tweak, publish again — suggest switching to `local`.
- Content-only requests (a post's text, a page built from existing blocks)
  don't touch the theme: the admin panel, or `references/content.md`.

### local — a full copy on the Mac

For whoever builds or restyles pages. PHP + MySQL; no Apache (`bin/velk
serve` is PHP's built-in server).

1. `scripts/local/env.sh check --project .`
   - `STATUS=READY` → step 2.
   - `STATUS=NEEDS_INSTALL` → say what's missing (the PHP `FORMULA`, MySQL)
     and ask; on yes, `scripts/local/env.sh install --project .`.
     `WARN=PHP_VERSION_MISMATCH` means Homebrew has no PHP matching
     production: say which differs, and that code may still behave
     differently on the server.
   - `STATUS=NEEDS_BREW` → Homebrew's installer asks for the Mac's password,
     which only the person can type, in Terminal: hand them the
     `INSTALL_COMMAND`, or offer to go on in `live` mode.

   PHP must match production's major.minor: code that runs on the Mac's newer
   PHP can be a fatal error on the server's (`array_find`, for one, is 8.4+).
2. `scripts/local/content.sh --project .` builds the copy. Running it again
   refreshes it. It stops the same way when someone else is publishing
   (`BUSY`/`STALE_LOCK`, exit 5; `--take-over-stale`) — and, when the theme
   here has changes not yet published (against its starting point, or against
   what is live when it has none), with `STATUS=LOCAL_CHANGES` and a
   `LOCAL_CHANGE=` line per file (exit 4): a refresh would overwrite them.
   Publish them first, or — after asking — run it with
   `--discard-theme-changes`.
3. Report `URL`, the local-only admin (`ADMIN_EMAIL`, `ADMIN_PASSWORD`) and how
   to start the site (`SERVE`).

| The local copy gets | It never gets |
|---|---|
| the engine from the published release the server runs — it passes `check-engine` by construction | anything copied from the server's engine |
| the live theme, with its starting point for the next publish | |
| `storage/uploads/` | `storage/form-uploads/` (lead attachments) |
| the data of `items`, `item_term`, `terms`, `pages`, `media`, `settings`, `languages`, `config_translations`, `theme_strings`, `form_settings` | users, members, orders, form submissions, login/OTP/reset/rate-limit rows; `form_recipients` (a local test never emails the real recipient); `tracking_scripts` (localhost never fires the client's pixels) — and form conversion snippets are cleared for the same reason |
| a `.env` with the server's public settings (`APP_NAME`, `APP_TIMEZONE`, `ADMIN_LOCALE`, `ADMIN_PREFIX`) | any secret: not the production database, SMTP, Stripe or Turnstile |

The content dump runs **on the server**, reading the credentials from the
server's own `.env` into a temporary file only its owner can read: the
production database password never reaches the Mac.

A site that came neither from an access file nor from a deploy made here —
the agency's own copy of an older site, say — needs its `.deploy/ssh.json`
written by hand first (`references/deploy.md`, Phase 1: `ssh.*` with
`remote_path`, and `site.*`; `db.*` is only for `init`, which turns it into
the server's `.env` — every database step after that reads the `.env` on the
server). Two things to say before the first copy: `storage/uploads/` comes
whole, and can be large; and no `.git/` comes from the server — the copy has
no history.

Publishing from local mode: `scripts/theme/publish.sh run --project .`
(`references/publish.md`).
