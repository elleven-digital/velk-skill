# Upgrade notes — versions that need more than swapping files

Most Velk upgrades are: fetch the tarball, replace the engine paths, run
migrations, done. **The versions on this page are not.** Each one needs
something the file swap can't do for you — data preserved before a column is
dropped, a function renamed in the theme, a config key set.

## How to use this

Before running an upgrade, work out the range: **every version greater than
the install's current one, up to and including the target.** Then read each
section in that range, oldest first, and do what it says.

Sections are ordered newest at the top, like a changelog — so "oldest first"
means starting at the bottom of your range and working up.

Two of these steps run at different times and mixing them up is the whole
risk:

- **Before** — must happen while the OLD schema still exists. Once the
  migration runs, the data it needed is gone and there is no going back.
- **After** — safe to do once the new engine is in place.

If the install's version is unknown (no `.velk-version`, no `core/VERSION`),
treat every section here as in range. Doing a preservation step that turns out
unnecessary costs a temporary table; skipping a needed one costs the data.

---

## v3.9.0 — no migration; a theme function named `richtext` breaks the site ⚠️ CHECK THE THEME BEFORE UPGRADING

### Before: a `richtext()` in the theme

The core now declares `richtext()` (it prints a richtext field with the
theme's blocks). A theme that declares its own is a fatal error on every
page; one behind `function_exists` is silently replaced by the core's. In the
local copy of the theme:

```bash
grep -rniE "function\s+richtext\s*\(" theme/
```

Nothing found: go on. Found: rename it — and its calls — in the theme, and
publish the theme **before** the file swap.

### After: what a multilingual site shows differently

Single-language sites: nothing below applies. On a site with i18n on, tell
the client:

- **Content without a translated slug now opens in every language**, at its
  default slug: `/en/sobre` used to be a 404 and now opens; once the English
  slug is filled, only `/en/about` answers. The sitemap, the language
  switcher and `hreflang` list those URLs too. Where one record's translated
  slug is another's slug, the translated one keeps the address (a published
  item always beats a draft) and the other has none in that language — the
  admin now warns about it on save.
- **A translated richtext saved blank now shows the default text.** The old
  admin stored an empty `<p></p>` for every untouched translation tab, and
  the translated page printed it. Open a few translated pages after the
  upgrade: a body that was empty now shows the default language's text.
- **The canonical and `hreflang` tags change** — they used to repeat the
  language prefix (`/en/en/…`). Nothing to do; worth knowing if the client
  watches Search Console.

### After: on any site

- `schema:validate` may print **"Warnings:"** — a template declared in
  `site.json` that the theme doesn't have, with no `page.php`/`single.php`/
  `taxonomy.php` to fall back on. Those URLs are a 404 (they used to be a
  500 error page). The site is still valid; fix the theme when convenient.
- `item:create`, `item:update` and `page:update` now refuse a block marker
  whose data isn't a JSON object or that has content inside — see
  `references/content.md`.

**Don't roll back once a text has blocks.** The editor before v3.9.0
doesn't know the block marker and drops it when the text is saved again.

---

## v3.8.4 — no migration; the CSP moves from `.env` to `site.json` ⚠️ SITES WITH `CSP_*` IN `.env`: MOVE THEM FIRST

The public site's policy now lives in the theme's `site.json`
(`security.csp`). Only `CSP_REPORT_URI` stays in `.env`: the other `CSP_*`
variables of v3.8.1–v3.8.3 are no longer read. A site that never set them
(`open`, the default) changes nothing: a file swap.

To know, read only those lines of the server's `.env`, never the whole file,
and leave `CSP_REPORT_URI` out (its URL can carry a key):

```bash
grep -E '^[[:space:]]*(export[[:space:]]+)?CSP_(MODE|ALLOW_EVAL|FRAME_ANCESTORS|SCRIPT_SRC|CONNECT_SRC|IMG_SRC|FRAME_SRC|FORM_ACTION)[[:space:]]*=' .env
```

A variable the hosting panel or `SetEnv` sets doesn't show there. So also
read the live header — nothing secret in it:

```bash
curl -sIL https://<site>/ | grep -iE '^(HTTP/|content-security-policy)'
```

Read the last answer, and only if it is a `200`: a redirect (a members-only
home) carries no CSP.
- `script-src 'nonce-…'` in `Content-Security-Policy` itself means
  `strict`; in a `Content-Security-Policy-Report-Only` header, `report`.
- No CSP header, or only one that isn't Velk's (Velk's always has
  `frame-ancestors` and `base-uri 'self'`), means `off`.
- A `frame-ancestors` with more than `'self'` means `CSP_FRAME_ANCESTORS`,
  in any mode.
- In the header with `script-src`: `'unsafe-eval'` means `allow_eval`;
  `'self'` and hosts without `'strict-dynamic'` mean `CSP_SCRIPT_SRC`; the
  hosts of `connect-src`, `img-src`, `frame-src` and `form-action` are the
  lists in force. Leave out `'self'`, `data:`, and what the core adds on its
  own: `challenges.cloudflare.com`, `checkout.stripe.com`,
  `billing.stripe.com`.

No line, only the old defaults (`CSP_MODE="open"`, `CSP_ALLOW_EVAL="0"`,
empty lists) and a plain `open` header: nothing to move. Otherwise the site
changes on the upgrade, in any mode, until the block is in `site.json`:
- `strict` and `report` fall back to `open`, silently for visitors;
- `off` starts sending the `open` header on top of the CDN's own policy;
- the `CSP_FRAME_ANCESTORS` domains can no longer frame the site.

The order matters. The theme with the block has to reach the server before
the new engine does, or the site runs `open` in between. And the local copy
must already run the new engine, because `publish.sh` validates the theme
with the local one:

1. **Upgrade the local copy** (`references/upgrade.md`). The server is
   untouched.
2. **Write the block** in the theme's `site.json` with the values of those
   variables. Each list goes into what the theme already declares under
   `security.csp.allow`: on the old engine the list in force was both.

   | `.env` (v3.8.1–v3.8.3) | `site.json` → `security.csp` |
   |---|---|
   | `CSP_MODE="strict"` | `"mode": "strict"` |
   | `CSP_ALLOW_EVAL="1"` | `"allow_eval": true` |
   | `CSP_FRAME_ANCESTORS="https://a.com https://b.com"` | `"frame_ancestors": ["https://a.com", "https://b.com"]` |
   | `CSP_CONNECT_SRC`, `CSP_IMG_SRC`, `CSP_FRAME_SRC` | `"allow": {"connect": […], "img": […], "frame": […]}` |
   | `CSP_FORM_ACTION` | `"allow": {"form": […]}` |
   | `CSP_SCRIPT_SRC` | nothing: strict always runs on the nonce plus `'strict-dynamic'` (see below) |

   Delete `security.csp.allow.script` (a v3.8.1–v3.8.3 key) if the theme has
   it: the new `schema:validate` rejects it. With `CSP_SCRIPT_SRC` in the
   server's `.env`, first add the key's domains to that variable, so the old
   engine's script list stays the same until the swap.
3. **Publish the theme** — `php bin/velk schema:validate` (it now checks the
   block), then `scripts/theme/publish.sh`. The old engine on the server
   ignores `mode`, `allow_eval` and `frame_ancestors`, and treats the lists
   as before.
4. **Upgrade the server:** `update-cms`.
5. **After:** delete those lines from the server's `.env`, keeping
   `CSP_REPORT_URI` (and from the local `.env`, if it has them); a value set
   in the hosting panel or with `SetEnv` goes there. While one is set to
   anything but the old default, the PHP error log names it on every page. Run the check on the server,
   `scripts/content/velk.sh --project . -- csp:check`: its first line shows
   the mode in force, and it lists any variable left behind. The `curl`
   above shows the header now sent.

**In live mode** there is no local copy: skip step 1, write the block in the
workspace (`scripts/theme/workspace.sh open`) and publish it. Nothing checks
it yet — the server's old engine ignores `security.csp`. Run
`update-cms --version v3.8.4`, and in step 5 run `schema:validate` and
`csp:check` on the server (`scripts/content/velk.sh --project . -- …`): they
are the block's first check.

Three things behave differently from the `.env` days:

- **A list in `security.csp.allow` now counts by itself.** Before, a theme's
  `connect`, `img` or `frame` list only joined a list turned on in `.env`. A
  site in `strict` whose theme declared one while the `.env` list stayed
  empty gets that restriction after the upgrade: delete the list, or make
  sure it names everything the site loads for that resource (an editor's
  embed included).
- **The block is the same wherever the theme is deployed.** A site that ran
  `strict` only in production now runs it locally and in staging too.
- **No script list.** A site that used `CSP_SCRIPT_SRC` loses its host
  restriction on scripts, and two things the list's `'self'` and hosts let
  through are now blocked: a same-origin script inserted without the nonce
  (Cloudflare's Email Address Obfuscation, `/cdn-cgi/…/email-decode.min.js`)
  and a script that a snippet pasted in the admin writes with
  `document.write`. On such a site, write the block with `"mode": "report"`
  in step 2, read the reports after the upgrade, then set `"mode": "strict"`
  and publish again. A `report` run on the old engine rehearses the old
  policy, not this one.

**A strict site coming from v3.8.2 or older** also goes through the v3.8.3
steps (`report` first, form destinations), in `site.json` instead of `.env`:
write the block with `"mode": "report"` in step 2 above, list what the check
and the reports show in `allow.form`, then set `"mode": "strict"` and publish
the theme again.

---

## v3.8.3 — no migration; only sites in `CSP_MODE=strict` or `report` change ⚠️ STRICT SITES: `report` FIRST

> Going to v3.8.4 or later? There the policy is in `site.json`: read the
> v3.8.4 section first, and use `security.csp` wherever these steps say
> `.env`.

Nothing changes on a site in `CSP_MODE=open` (the default) — a file swap.
To know the mode, read that one line on the server — `grep '^CSP_MODE=' .env`,
never the whole file; no line means `open` — or the first line `csp:check`
prints (`CSP_MODE: …`). On a site in `strict`, forms get a new restriction;
in `report` the same rule is only reported.

### A form can only send to the site itself — in `strict` ⚠️ SWITCH A STRICT SITE TO `report` BEFORE UPGRADING

The strict policy gains `form-action`: `'self'`; Stripe's checkout, when
subscriptions or the store are configured, and the member portal, with
subscriptions — the core adds these on its own; `CSP_FORM_ACTION` in `.env`;
and `security.csp.allow.form` in `site.json` (counted even with the `.env`
list empty — unlike the other lists). Chrome applies it to **every redirect after a form is sent**, not
only to the form's address; other engines have differed, so list the
destinations either way. On a strict site, these stop working until listed:

- a theme form posting straight to another site (a newsletter form to an
  e-mail provider), or a button's `formaction`;
- a form pasted in the admin or built by a script that posts elsewhere;
- a POST the site answers with a redirect to another site — a
  `member_require_plan()` fallback to an external checkout, a
  `member_require()` login URL on another site, a route of the theme's, a
  Stripe custom domain for Checkout or the portal.

The checks that find these only exist from v3.8.3 on — on the old engine
`csp:check` sees no forms and `report` has no `form-action` — so the order
matters:

1. **Before** the file swap: set `CSP_MODE=report` in the server's `.env`.
   While in `report` the whole strict policy is only reported — the site
   keeps just the `open` protections until step 5; tell the client.
2. Upgrade.
3. **After:** run the check on the server, where the real `.env` and
   `APP_URL` are — `scripts/content/velk.sh --project . -- csp:check`. It
   flags theme forms and buttons whose address is written in the template,
   and unknown keys under `security.csp.allow`. It reads templates as text,
   so the other cases above only show up in the browser: browse the site
   and read the reports. Submitting a form on a live site creates a real
   lead, e-mail and ad conversion — send one clearly marked test entry per
   form with the client's OK and delete it afterwards, or leave the site in
   `report` on real traffic for a few days. The violation names the
   address the form was sent to, not the redirect's destination — a
   violation naming the site's own `/member/login` or `/forms/…` means the
   answer redirected somewhere not allowed. In `report` the page moves on,
   so read it through `CSP_REPORT_URI` or with DevTools' *Preserve log*.
4. List the destinations in `CSP_FORM_ACTION`, or in the theme's
   `security.csp.allow.form`; run `csp:check` again (it also prints a source
   dropped as invalid) and repeat the test that failed.
5. Set `CSP_MODE=strict` again.

---

## v3.8.2 — no action needed; the admin's forms only post to the site

No migration, no config, no theme work. The admin's policy gains
`form-action 'self'` — every admin form already posts to the admin, so
nothing visible changes. One edge case worth knowing: an admin behind a
gateway (Cloudflare Access, an OAuth proxy) that answers an expired
session's POST with a redirect to its own login gets that redirect refused,
and "save" looks like a no-op until the page is reloaded.

---

## v3.8.1 — no migration; every public page starts sending a CSP ⚠️ CHECK THE THEME BEFORE UPGRADING

> Going to v3.8.4 or later? There the settings named below (`CSP_MODE`,
> `CSP_FRAME_ANCESTORS`, the lists) are in `site.json` → `security.csp`: see
> the v3.8.4 section, and write them there instead of in `.env`.

No migration, no config change, no theme work on a typical site: a file swap.
But every site starts sending new headers, and four situations need a look
**before** the upgrade — one of them is a fatal error.

What every site sends after the upgrade:

- Every public HTML page: `Content-Security-Policy: frame-ancestors 'self';
  base-uri 'self'` (plus `upgrade-insecure-requests` over HTTPS). That is
  `CSP_MODE=open`, the default: it restricts no script, image or connection,
  and `frame-ancestors 'self'` is the same rule as the `X-Frame-Options:
  SAMEORIGIN` the server examples already send.
- Every admin response: `X-Robots-Tag: noindex, nofollow`. The admin also
  stops allowing inline JavaScript (`script-src 'self'`) — invisible unless
  the site sits behind Cloudflare with JavaScript detections on, where the
  admin's console shows Cloudflare's script refused (nothing is enforced
  unless a WAF rule uses the detection's result).

### Check before upgrading ⚠️

1. **A theme function named `json_script`, `csp_nonce` or
   `csp_nonce_scripts`.** The core now declares them first, so the theme's
   declaration becomes a fatal error on every page and in `bin/velk migrate`.
   `grep -rnE "function\s+(json_script|csp_nonce|csp_nonce_scripts)\s*\(" theme/`
   — rename before upgrading.
2. **The site is shown inside another domain's iframe** (a partner portal, a
   landing-page builder): add that domain to `CSP_FRAME_ANCESTORS` in `.env`,
   or the embed goes blank.
3. **The theme sends its own `Content-Security-Policy`** with `header()` in
   `functions.php`: it keeps it, and the core sends none — `CSP_MODE` has no
   effect until it is removed. A `<meta http-equiv="Content-Security-Policy">`
   in a template applies *together* with the core's; remove it.
   `php bin/velk csp:check` flags both.
4. **The hosting panel or the CDN already sends a CSP**: both apply. If they
   disagree, set `CSP_MODE=off`.

### After: `robots.txt` can drop the admin lines

Sites deployed with this skill up to v1.3.0 have `Disallow: /admin` and
`Disallow: /admin/` in `robots.txt`. It is a user path, so the upgrade leaves
it alone. `Disallow` only stops the visit — the address can still be indexed
from a link — and with those lines a crawler never fetches the admin, so it
never sees the new `noindex`. And `robots.txt` is public: it gives away an
admin path that was changed. Remove the two lines (tell the client if they edit the
file themselves). `init.sh` no longer writes them.

### Only when a client asks: the strict mode

`CSP_MODE=strict` removes `'unsafe-inline'` — the finding security scanners
report — and runs only scripts carrying the page's nonce. Before turning it
on:

- `php bin/velk csp:check`, and fix what it lists: every `<script>` in the
  theme needs `nonce="<?= csp_nonce() ?>"`; no `on…=`, no `javascript:`.
- A while in `CSP_MODE=report`, reading what the browser reports: a script a
  CDN inserts at the edge (Cloudflare's Email Address Obfuscation) never
  passes through Velk, and `csp:check` can't see it.
- **Not with edge caching** (`CACHE_TTL` above 0): a cached page hands every
  visitor the same nonce.

Everything else — the domain lists for an IT team, `security.csp.allow` in
`site.json`, `report`, `off` — is in the project's `AGENTS.md` → "Content
Security Policy (public site)", and `references/building.md` has the theme
side.

---

## v3.8.0 — no action needed; two visible changes to warn a client about

No migration, no theme work, no config. A plain file swap.

### The submission card lost the IP ⚠️ TELL THE CLIENT BEFORE THEY ASK

A closed submission card showed the IP next to the date, under the title. It
is gone from the card — still in the export's metadata columns. The new,
optional `forms.<id>.preview_subtitle_field` names a field to show there
instead (the company under the lead's name, say); `schema:validate` rejects a
name that isn't a field of the form.

### Exporting submissions as CSV — new

The form screen gains an **Export** block, and `php bin/velk form:export
<form-id>` writes the same file to stdout (see `references/cli.md`). **By
default the file has only the form's fields**; the metadata block (date, IP,
browser, e-mail status…) and the tracking block (UTM, click IDs) are opt-in.
Only approved, completed submissions go out — never spam, never a multi-step
lead still in progress. A client who asks for "a planilha dos leads" now has a
button.

### Admin details

The admin works on a phone (a top bar, fields stacked, tables scrolling
sideways); single-line fields and buttons share one height; logging in goes
back to the full address you asked for, query string included. Admin-only.

---

## v3.7.7 — no migration; one gate change can switch payments OFF ⚠️ CHECK `.env` ON SITES WITH STRIPE

No migration, no config change for a site without Stripe, no theme work
unless the site uses subscriptions or the store. A plain file swap — **except
for one thing**: a site that has `STRIPE_SECRET_KEY` in `.env` and no webhook
secret will find subscriptions and the store *off* after the upgrade. Read
the first section before upgrading any site with Stripe keys.

### Payments only turn on with their webhook secret ⚠️ CHECK BEFORE UPGRADING A SITE WITH STRIPE

Before, `STRIPE_SECRET_KEY` alone lit up both features. Now subscriptions
also need `STRIPE_WEBHOOK_SECRET`, and the store needs
`STRIPE_STORE_WEBHOOK_SECRET`. Without its secret a feature is **off**: the
checkout routes answer 404, `member_plans()` returns `[]`, `item_sellable()`
is `false`, and a theme that checks them hides its buttons.

Why: with the key alone the checkout opened and Stripe **charged**, but every
webhook arrived unsigned and was rejected with 400 — the member paid and
never got access; the order sat in `pending` forever. Half-configured now
looks off, not broken.

What to do, on every site with a Stripe key:

1. `php bin/velk schema:validate` — it names the missing secret and the
   endpoint to create (`/member/stripe-webhook`, `/store/stripe-webhook`).
2. Create the endpoint(s) in the Stripe dashboard, subscribe the events
   listed in AGENTS.md → "Subscriptions and the store — setting Stripe up",
   and set the secret in `.env`.

No Velk site runs payments in production yet — that is why the flows were
reviewed now — so in practice nothing switches off. Check anyway.

### Two `site.json` decisions, both defaulting to "as before" — with one visible tightening

- **`members.multiple_plans`** (default `false`): one active subscription per
  member. The default was never *enforced* before; now a second `subscribe`
  from a member who already has one answers **`already_subscribed`** and
  never reaches Stripe. Themes that map `member_status()` codes should add
  it (`docs/messages.md`). With `true`, a member can hold several — **one
  per plan** — and the theme gets `member_subscriptions()`,
  `member_subscribed_plans()` and `member_can_subscribe($key)` for the
  button. If you turn it on, switch plan switching **off** in the Stripe
  Customer Portal: a switch there is the same-plan-twice the guard cannot
  see.
- **`item_types.<type>.repeat_purchase`** (default `true`). With `false`, a
  logged-in member who already has the item in a paid order is not charged
  again — the line drops from the cart, and if nothing is left the checkout
  answers **`already_purchased`** (status `info`, `store_status()`);
  quantity is always 1 for those types; guests are not tracked.
  `item_purchasable($item)` is the "show the buy button?" helper.

One behaviour changed in existing helpers: `member_on_plan()` and
`member_require_plan()` now pass when **any** active subscription matches.
For a member with one active subscription — every member on a site that
never set `multiple_plans` — that is identical to before. It differs only
for a member who somehow holds two, who used to be judged by the most recent
one alone.

The admin members list now shows every active subscription per member and
marks with a red `!` anyone holding more than the rule allows; the webhook
logs the same anomaly as a line starting with `[Velk] ATENÇÃO:` (again on
every event for that member until it is resolved in Stripe). The engine
never cancels or refunds on its own.

### Post-submit redirects only follow a same-host Referer ⚠️ FORMS POSTED FROM ANOTHER HOST

After a form POST — public forms, the member area, the store — the engine
redirected to `HTTP_REFERER` as received. It now does so only when the
referer's host is the site's own host (port and case ignored); anything else
lands on the site root.

Where a site could notice: a Velk form embedded on **another domain**, or a
form whose `action` is an absolute URL on a different hostname than the page
(`www.` on one side and the bare domain on the other, when both serve the
site). Themes with relative actions on the site's own pages are unaffected.

### Uploaded SVGs are served with `Content-Security-Policy: sandbox`

Only matters if a theme embeds an uploaded SVG through `<object>`, `<iframe>`
or a direct link and expects scripts or same-origin access from it.
`<img src="…">` never executed scripts and is untouched. The uploader already
sanitised SVGs; the header is the net under the sanitiser.

### `schema:validate` is stricter about payment configuration

Plans need a non-empty `name`; `intervals` only `month`/`year`; `features` a
list of strings; `sellable`, `multiple_plans` and `repeat_purchase` booleans;
`repeat_purchase` only next to `sellable: true`; `store.currency` a 3-letter
ISO code. A pipeline that runs `schema:validate` as a gate may start failing
on a `site.json` it previously accepted — the file was wrong; fix the file.

### Admin: a term opened under the wrong taxonomy is a 404

`/admin/taxonomies/tag/42` with a `categoria` term used to open it on the tag
screen. An old bookmark like that now 404s. Nothing else changes.

### Under the hood, no action

The Customer Portal `return_url` is absolute (Stripe refused the relative
one); concurrent webhooks for the same object apply with compare-and-swap;
Stripe create calls carry an `Idempotency-Key`.

---

## v3.7.6 — no action needed; one visible change to warn a client about

No migration, no theme work, no config. A plain file swap. Three things
changed, and only one of them is likely to reach a client's eyes.

### E-mails lost the header block ⚠️ TELL THE CLIENT BEFORE THEY ASK

Every e-mail the engine sent — form submissions and password resets — opened
with a black square containing the letter **E**, next to the site's real name.

The initial was **hardcoded in the template**. It was not derived from
`$siteName`, so it was not an initial at all: on a site called "Padaria do
João" the header read **E · Padaria do João**, a stranger's initial on
someone else's mail. Every Velk install whose name did not start with E had
this.

The whole brand row is gone from both templates. The site name stays in the
footer, where it already was.

Worth a heads-up to any client who reads their own notification e-mails:
after this upgrade they start arriving without the little logo block at the
top. That is the fix, not a regression — but "my e-mails changed" is exactly
the kind of thing that comes back as a support message a week later.

### Marking spam by hand — new, and only where `keep_spam` is on

Forms that keep spam (see the v3.7.2 section below for the whole feature) now
show a discreet **"É spam"** link next to Delete on each submission. It moves
the row to the spam list with `blocked_by = 'manual'` — a third origin next
to `honeypot` and `turnstile` — and the existing "Não é spam" button brings it
back.

The point is that deleting **destroys** the lead while marking preserves it,
and the spam list becomes the record of what the automatic filters let
through. Because it is reversible in one click, it asks for no confirmation,
unlike Delete.

Two behaviours worth knowing before a client asks:

- **The link needs `keep_spam` actually on.** It does not appear merely
  because old spam exists — that case only keeps the "Spam" link visible so
  already-collected personal data stays deletable from the panel.
- **An already-blocked row is never re-marked.** A `honeypot` catch stays
  `honeypot`; the origin is what the spam list exists to record.

The e-mail already went out and the conversion event already fired, at submit
time. Marking spam afterwards undoes neither, and is not meant to.

### The mobile menu close button moved

On phones, the button that opens the sidebar is fixed at the top-left and
swaps its icon for an X when open. The drawer slides in **underneath** it, so
the X landed on top of the site's mark and name. With the menu open it now
sits at the drawer's right edge.

Admin-only, no theme impact.

---

## v3.7.5 — runs two migrations despite the patch number ⚠️ SCHEMA CHANGE

Two unrelated things shipped together here: a honeypot fix every site wants,
and manual ordering, which is opt-in and does nothing until you turn it on.

**Read this before upgrading a large site.** The patch number says "file
swap"; it isn't one.

### The migrations

Adds `items.sort_order` and `terms.sort_order` (`INT NOT NULL DEFAULT 0`),
each with a supporting index. Both are additive and idempotent — they check
`SHOW COLUMNS` / `SHOW INDEX` first — and no existing row changes value or
order. They run in the normal migration step.

The caveat is size, not correctness. On **MySQL 8.0.12+** an `ADD COLUMN`
with a default at the end of the table is INSTANT — metadata only. On
**MySQL 5.7**, which is still the declared floor, it rebuilds the table: on a
large `items` table that is real downtime and real disk. And the
`AutoMigrator` serves the maintenance page to every request while it runs.

For a big site, take it out of the request cycle:

```bash
# .env
AUTO_MIGRATE=false
```

```bash
php bin/velk migrate      # in a quiet window, over SSH
```

Small sites: nothing to do, the normal upgrade handles it.

### The honeypot fix — no action needed, one thing worth checking

`form_honeypot()` now emits a small script alongside the field that **empties
it in the browser**. Browser autofill was filling the hidden field and
sending real people to spam: Chrome ignores `autocomplete="off"` for profile
fill and classifies a meaningless field like `_hp` by its **position** in the
form, so a honeypot rendered first gets filled as if it were the name field.
Password managers write straight into the DOM, where `autocomplete` is never
consulted at all.

Themes need no change, and with JavaScript disabled the behaviour is exactly
what it was.

**Worth checking while you're in there:** if the theme prints
`form_honeypot()` as the form's first input, move it below the real fields,
just before the submit button. The script already stops the false positives;
moving it removes the thing that caused them.

### Manual ordering — opt-in, and it changes nothing until it isn't

`"manual_order": true` on an item type or a taxonomy in `site.json` swaps
publish-date/alphabetical ordering for an order the client drags in the
admin. A type or taxonomy that never sets it behaves exactly as before.

```json
"item_types": { "produto":   { "manual_order": true, ... } },
"taxonomies": { "categoria": { "manual_order": true, ... } }
```

**The theme needs no change** — `items()` and `terms()` start returning the
panel order on their own.

Four things that will otherwise come back as bug reports:

- **An explicit `order` in the theme still wins.** A template calling
  `items('produto', ['order' => 'title ASC'])` keeps ordering by title, flag
  or no flag. This is the first thing anyone reports as "the drag does
  nothing" — the fix is removing the `order` from that call.
- **`the_terms()` is unaffected.** The per-item helper that lists an item's
  terms always sorts by name. Category badges on an item page stay
  alphabetical even with the flag on for that taxonomy.
- **The taxonomy archive page** (`/categoria/x`) only follows the manual
  order when that taxonomy belongs to exactly **one** item type. Shared
  between two types, it stays on publish date — each type has its own
  sequence starting at 1, and interleaving two of them means nothing.
- **The admin list is still paginated at 50**, and dragging moves a row
  within its page. You cannot drag from page 3 to the top.

Turning the flag on does **not** reshuffle the site: the first time that
admin list opens, the order already on screen is written into the column, and
the client drags from there.

---

## v3.7.4 — fixes a silent save failure on multi-language sites ⚠️ CHECK THESE

No action needed to upgrade — no migration, no theme work. But **if you
maintain a multi-language site, upgrade it.**

### The bug

On a site with i18n enabled, any field marked `required` also rendered as
required inside the **hidden** translation panels. The browser refused the
submit, could not focus the offending field to explain why, and gave up — so
the Save button did nothing at all. No error on screen, no message. The only
trace was in the browser console:

```
An invalid form control with name='fields_translations[en][cliente]'
is not focusable.
```

Affects items, pages, terms and options — anywhere with translation tabs and
at least one required field.

### Why it matters beyond the fix

The failure is **silent**, so a client may have been unable to save for weeks
without reporting it — people assume they did something wrong before they
assume the tool is broken. When upgrading a multi-language site, it is worth
asking whether anyone had trouble saving, and checking that recent edits
actually landed.

### Workaround, if a site cannot be upgraded yet

Fill the required field in every language tab (any text works, and it can be
deleted afterwards). That satisfies the browser and lets the form submit.

---

## v3.7.3 — no action needed; two admin buttons moved

Listed only so the changes are not a surprise. Nothing to do, no migration,
no theme work.

### "Not spam"

A submission the anti-spam blocked now has a button in its detail panel that
clears the flag and returns it to the normal submissions list. Only appears
where a blocked submission exists — a site without `keep_spam` sees nothing
new.

Recovering fires no email and no webhook, deliberately: they would run weeks
after the submission. If a client asks why the recovered lead did not reach
the CRM, that is the answer, and forwarding it is a manual step.

### Two buttons moved in the admin

Worth knowing before a client asks "where did the button go":

- **Bulk delete** left the page header on item and term lists. It is now a
  trash icon, to the left of the status filter on items, still in the header
  on terms (which has no filter bar).
- **The submissions filter button** grew to full height, matching the
  recipients "Add" button beside it.

Neither changes behaviour.

---

## v3.7.2 — runs a database migration; the feature itself is optional

**No theme work required.** A site that never sets `keep_spam` sees no
difference at all. This section exists for the migration, and to record the
cron job the feature needs from anyone who does turn it on.

### The migration

Adds `form_submissions.blocked_by` (VARCHAR(20) NULL) plus an index.
Idempotent — it checks `SHOW COLUMNS` and `SHOW INDEX` first — and additive:
nothing is dropped, no existing row changes. It runs in the normal migration
step of the upgrade. Worth knowing only because a patch that touches the
schema is not a pure file swap.

### The feature, when the client wants it

`keep_spam: true` on a form in `site.json` makes a submission rejected by the
honeypot or by Turnstile get stored and flagged instead of discarded. A
"Spam" link then appears on that form's screen in the admin.

```json
"forms": {
  "contato": {
    "keep_spam": true,
    "fields": [ ... ]
  }
}
```

Per form, not global. `true` unquoted — `schema:validate` rejects the string,
because in PHP `"false"` is also truthy and the site would keep storing spam
while the owner believed it was off.

The point is recovering false positives: browser autofill fills the hidden
field, and Turnstile rejects real people on blocked JS or a bad connection.
Before this, the lead vanished with nobody knowing there had been a person on
the other side.

### If you turn it on, schedule the cleanup

```
0 3 * * *  cd /var/www/<project> && php bin/velk cleanup:spam-submissions
```

Not optional hygiene. A form under attack writes thousands of rows a day, and
what gets stored is personal data belonging to people the system classified as
bots — without their consent and without their knowledge. The retention window
(`--days`, default 30) is what makes the feature defensible under LGPD/GDPR.
The command only touches `blocked_by IS NOT NULL`; approved leads are never
deleted by age.

**Ask the client before enabling it.** Retaining that data is their call, not
the agency's.

### One behaviour that avoids a scare

Turning `keep_spam` off after collecting does NOT hide what is already in the
database: the link stays while any spam remains, and disappears when the last
row is deleted. Deliberate — personal data invisible and undeletable from the
panel would be the worst outcome.

## v3.7.1 — the engine returns message codes ⚠️ PATCH NUMBER, BREAKING FOR THEMES

**Do not let the version number fool you.** This is a patch because nothing in
the database or the schema moved — but the theme work below is mandatory, and
a `.1` upgrade applied blind will break messages on the site.

**Affects every theme that renders a form, login, cadastro, password reset or
cart message.** That is nearly every theme. Skipping this leaves blank boxes
where messages used to be — no error, no log line, just silence where the
site used to say "Mensagem enviada".

### What changed

`form_status()`, `member_status()`, `store_status()` and the JSON bodies used
to carry a finished sentence in `message`. They now carry a **code**:

```php
// v3.7 and earlier
['status' => 'error', 'message' => 'Incorrect email or password.']
$r['errors']['email']   // => 'Invalid email.'

// v3.7.1
['status' => 'error', 'code' => 'invalid_credentials']
$r['errors']['email']   // => ['code' => 'invalid_email']
```

There is no legacy `message` fallback — it was cut deliberately. The one
exception is a form's `success_message` from `site.json`, which still arrives
as `message` because it is theme copy, not engine copy.

### Why (so you can explain it to the site owner)

The old sentences were English and unfixable from most sites: the translation
screen only appears on multi-language installs, so a Portuguese site displayed
English with no way out. Field errors and upload failures were worse —
hardcoded Portuguese that never passed through `t()`, invisible to
`i18n:scan` and unreachable from the panel, and they were the most-read
messages in the system.

### After — what to do in the theme

**1. Find every place that reads `message` or a field error.**

```bash
grep -rn "\['message'\]\|'message'\]\|errors\[" theme/templates theme/partials
```

Typical hits: `page-contato`, `page-entrar`, `page-cadastro`,
`page-esqueci-senha`, `page-nova-senha`, and any newsletter block.

**2. Add a message map to `theme/functions.php`** (create it if absent — Velk
loads it at boot). Skeleton, with `tema_` renamed to something specific to
this theme:

```php
<?php
/** @return array<string,string> */
function tema_mensagens(): array
{
    return [
        'submitted'           => 'Recebido — retornamos em breve.',
        'validation_failed'   => 'Verifique os campos destacados.',
        'session_expired'     => 'A página ficou aberta tempo demais. Recarregue e tente de novo.',
        'invalid_credentials' => 'Email ou senha incorretos.',
        'rate_limited'        => 'Muitas tentativas. Tente de novo em {minutes} minuto(s).',
        // …um por código que este site usa. Lista completa em docs/messages.md.
    ];
}

/** @return array<string,string> */
function tema_erros_de_campo(): array
{
    return [
        'required'      => 'Campo obrigatório.',
        'max_length'    => 'Use no máximo {max} caracteres.',
        'invalid_email' => 'Email inválido.',
        'too_large'     => 'Arquivo maior que {max_mb} MB.',
        // …
    ];
}

function tema_texto(?array $retorno, ?string $padrao = null): string
{
    if ($retorno === null) return (string) $padrao;

    // `message` só chega quando o formulário declara success_message no
    // site.json — texto de quem montou o site, tem precedência.
    $escrito = $retorno['message'] ?? null;
    if (is_string($escrito) && $escrito !== '') return $escrito;

    $texto = tema_mensagens()[(string) ($retorno['code'] ?? '')] ?? null;
    return $texto === null
        ? (string) $padrao
        : tema_preencher($texto, (array) ($retorno['params'] ?? []));
}

function tema_erro_de_campo(array $erro): string
{
    $texto = tema_erros_de_campo()[(string) ($erro['code'] ?? '')] ?? 'Confira este campo.';
    return tema_preencher($texto, (array) ($erro['params'] ?? []));
}

function tema_preencher(string $texto, array $params): string
{
    foreach ($params as $k => $v) {
        $texto = str_replace('{' . $k . '}', (string) $v, $texto);
    }
    return $texto;
}
```

Write the texts **in the site's language, matching its existing voice** — read
the surrounding templates first. The skeleton above is Portuguese because most
Velk sites are; a site in another language gets that language. Do not
translate an existing site's copy by reflex.

**3. Rewrite the call sites.**

```php
// before
<?= e($status['message']) ?>
<?= e($r['errors']['name']) ?>

// after — always with a fallback, or an unmapped code prints raw on screen
<?= e(tema_texto($status, 'Não foi possível concluir.')) ?>
<?= e(tema_erro_de_campo($r['errors']['name'])) ?>
```

**4. If the theme submits by AJAX**, update the JS too — it reads
`data.message` today and must read `data.code` and map it, or read a
`data-*` map rendered by PHP.

**5. Check `params`.** Two codes carry data the sentence needs and nothing
else knows: `rate_limited` has `minutes`, `max_length` has `max`, `too_large`
has `max_mb`, `type_not_accepted` has `accepted`. Use `{placeholder}`
substitution, as the demo theme does.

**6. If the theme caught `RuntimeException` around uploads**, it still works —
`FormUploadException` extends it — but the message is now a code. Read
`$e->errorCode` and `$e->params`. (The property is `errorCode`, not `code`,
because `Exception::$code` already exists as an int.)

### The vocabulary

The complete list — every code, its params, when it fires — ships with the
engine at `docs/messages.md`. **Read it from the install being upgraded**, not
from memory: it is the authority, and it grows.

Grouped roughly:

- **Forms:** `submitted`, `validation_failed`, `captcha_failed`,
  `session_expired`, `form_not_found`, `file_too_large`
- **Field errors:** `required`, `max_length` (`max`), `invalid_email`,
  `invalid_url`, `invalid_number`, `invalid_option`
- **Upload:** `too_large` (`max_mb`), `type_not_accepted` (`accepted`),
  `type_not_allowed`, `empty_file`, `no_file`, `incomplete_upload`,
  `invalid_upload`, `invalid_svg`, `store_failed`, `upload_failed`
- **Members:** `signed_in`, `signed_out`, `credentials_missing`,
  `invalid_credentials`, `rate_limited` (`minutes`), `session_expired`,
  `registered`, `email_taken`, `invalid_email`, `password_too_short`,
  `invalid_member_type`, `registration_failed`, `password_reset_sent`,
  `password_updated`, `reset_link_invalid`, `account_not_found`,
  `otp_sent`, `otp_resent`, `otp_invalid`, `otp_resend_wait`,
  `otp_rate_limited`, `otp_send_failed`, `otp_session_expired`,
  `plan_unavailable`, `checkout_failed`, `no_subscription`, `portal_failed`,
  `subscription_paid`, `subscription_cancelled`
- **Store:** `cart_empty`, `cart_invalid`, `checkout_failed`,
  `session_expired`, `order_paid`, `purchase_cancelled`

Note `otp_sent` arrives with `status` `two_factor`, not `success` — it is a
step, not a conclusion. A theme that branches only on `success`/`error` will
show nothing there.

### Verify

Submit the contact form with an empty required field and a malformed email.
Both messages must appear, in the site's language. Then try logging in with a
wrong password. If any box renders empty, a code is unmapped.

---

## v3.7.0 — `consent.enabled` is required for the consent UI to appear

**Only affects a theme that declared `consent.categories`.** The feature
shipped in v3.6.0, so in practice this is a handful of sites at most — but
`schema:validate` will fail on them until the key is added.

```json
"consent": {
  "enabled": true,
  "categories": { ... }
}
```

Without `enabled`, the consent area vanishes from the admin — no column in the
scripts list, no "requires consent" checkbox — and every script is treated as
necessary. That is the point: Velk ships no banner, and a theme without one was
previously able to mark a script as opt_in, leaving it inert forever with
nothing on screen to explain why.

`categories` remains optional. `enabled` alone gives an all-or-nothing banner;
categories are what let it say "Marketing" instead of "Optional".

### One behaviour worth knowing before you flip it off

A script may carry a category from when the theme had a banner. With the
mechanism off, that script **loads** — the emission clears the category, and
"no consent mechanism" means everything is necessary. So switching `enabled`
from true to false on a configured site turns previously-gated scripts back on.
Review the scripts list before doing that on a live site.

---

## v3.6.3 — engine messages are English now ⚠️ PORTUGUESE SITES SHOW ENGLISH

> **Superseded by v3.7.1.** If the target version is 3.7.1 or later, skip this
> section entirely — those strings no longer exist in the engine, so there is
> nothing to translate. Do the v3.7.1 work instead. The remedy below only
> applies when upgrading to something in the 3.6.3–3.7.0 range, and even then
> it only works on multi-language sites: the theme-strings screen is hidden
> when `i18n` is off, which is exactly why v3.7.1 replaced the whole approach.

Affects any site whose visitors use **forms, the member area, or checkout**.
A site that is only content pages is unaffected.

### What changed

41 visitor-facing strings in the engine were literal Portuguese — "Mensagem
enviada.", "Email ou senha incorretos.", "Código reenviado." and so on. They
are English now. Until they are translated, a Portuguese site will answer in
English at exactly those moments.

Nothing else changes: content, fields, admin panel and theme strings are
untouched.

### AFTER the upgrade — translate them, it takes minutes

```bash
php bin/velk i18n:scan
```

That registers every `t()` source string the engine and theme use. Then open
the theme-strings screen in the admin and fill the Portuguese column. There
are **35 unique strings**, and one of them ("Your session expired…") covers ten
places on its own.

**This only works on a multi-language site.** `ThemeStringController` gates on
`isI18nEnabled()`, so a single-language install has no translation screen and
no way to reach these strings from the panel. On such a site in this version
range the English is stuck. Upgrading to 3.7.1 is the fix.

Do this **before handing the site back**, not after: nobody submits a form
right after an upgrade, so the English messages surface days later, to a
client.

### Why there is no automatic migration

Deliberate. A seed would have to guess the site's language and write into a
table the site owner also edits. Running the scan is the same flow used for
every other translated string in Velk, and it leaves the owner in control.

### The part that would have been a silent trap

`t()` used to return the source text whenever the visitor's language equalled
the **site default**. With Portuguese sources and `pt-BR` defaults that was
invisible. With English sources it would have meant a `pt-BR` site receiving
raw English *and the translation registered in the panel never being read* —
no error, no fix available from the admin.

The shortcut now asks whether the current language is the **source** language
(`en`). So translating to `pt-BR` works, which is what makes the paragraph
above possible at all. If you are on 3.6.3 or later and a translation seems
ignored, that is no longer the cause.

One consequence: a non-English site loads the string catalog once per request
where it previously skipped it. Memoized for the rest of the request, and a
failed read degrades to the English source rather than an error.

---

## v3.6.2 — anonymous pages stop setting a session cookie

**Nothing to do.** Listed because the change is invisible until someone is
debugging something else, and then it looks like a bug.

The session used to open on every request. It now opens only when the request
already carries the session cookie, or when something writes — so a page that
neither reads nor writes emits **no `Set-Cookie`** at all. Two consequences
worth recognising:

- A visitor browsing content pages no longer gets a session, and no session
  file is created for them. On a site that took a traffic spike, that is a lot
  of files that no longer accumulate — but it also means "no session file"
  stops being evidence that something is broken.
- `$_SESSION` is not populated on those requests. Nothing in core or in any
  theme we know of reads it directly (everything goes through `Velk\Session`),
  but custom code that does will now find it empty on anonymous page views.
  The fix is to read through the class, which opens the session on demand.

Edge caching is **off unless you turn it on**: `CACHE_TTL` defaults to `0`,
and with it unset no `Cache-Control` header is emitted and behaviour is
identical to before. Setting it makes responses that opened no session
cacheable at the edge (`s-maxage`), and everything else `private, no-store`.

A page with a form is never cacheable — `csrf_field()` writes the token, and a
per-visitor secret cannot live in a page that is byte-identical for everyone.
Expected, not a limitation.

**If you do enable it, check the theme before believing the numbers.** A
`csrf_field()` inside a global partial — a newsletter form in the footer — makes
every page write a session, and nothing caches, with no error anywhere. Set
`APP_DEBUG=true` and read the `X-Velk-Cache` header page by page.

---

## v3.6.0 — tracking scripts moved to their own screen ⚠️ EVERY SITE, COPY FIRST

**Every site with anything in the tracking fields is affected**, whether or
not it wants consent. The three textareas are gone; scripts are now rows in
`/admin/scripts`.

### BEFORE anything — copy the three fields out

```
/admin/options/tracking
```

Copy **Scripts no `<head>`**, **início do `<body>`** and **final do `<body>`**
somewhere outside the panel first. A text file, a note, anything.

**Why first, and not after.** `Option::setGroup()` stores the whole group as
one JSON blob and a save only collects fields present in the current schema.
After the upgrade those three are no longer in any schema, so **the first save
of anything in that group drops them.** They survive in the database until
then, and not a moment longer. And the new screen's conversion form saves that
same group — so opening `/admin/scripts` and saving the conversion accordion
is enough to lose them.

There is no automatic migration, deliberately: a pasted block can hold three
snippets from different services, and only you know which category each
belongs to.

### AFTER the upgrade — recreate the rows

`/admin/scripts` → one row per snippet, with its position. Split a pasted
block into one row per service; that's the whole point of the change.

**Leave "requires consent" unchecked on the first pass.** Unchecked means
"always loads", which reproduces exactly today's behaviour. Getting the site
working again and classifying for consent are two jobs, and doing them at once
is how a client's tracking goes dark without anyone noticing.

### AFTER — only if you want consent gating

Tick *"this script requires consent"* on the rows that need it. Without
`consent.categories` in `theme/site.json` the select offers two implicit
options (optional on/off by default) and the banner approves or refuses
everything at once. Declaring categories is what lets the banner say
"Marketing" instead of "Optional":

```json
"consent": {
  "categories": {
    "analise":   { "label": "Análise",   "mode": "opt_out" },
    "marketing": { "label": "Marketing", "mode": "opt_in" }
  }
}
```

**Velk ships no banner.** Until the theme calls `velkConsent.set()` from
something a visitor can click, every `opt_in` row stays inert forever.
`velkConsent.answered()` decides whether to show it.

Three things that cost the most time when they surprise you:

- **A gated `<noscript>` never renders.** With JS on the browser doesn't parse
  its contents; with JS off the runtime never runs. GTM's `<noscript>` iframe
  is dead weight in a gated row — correct, not a gap, since a visitor without
  JS can't be shown a banner either.
- **Snippets of one service must share a category**, or you install half a GTM.
- **Renaming a category key in `site.json` silently disables every row still
  pointing at the old name** — those rows emit nothing at all. The scripts
  table flags them in red, but `schema:validate` can't: the rows live in the
  database, not in `site.json`.

---

## v3.6.0 — `i18n.default_label` is required on multi-language sites

Only affects sites with `i18n.enabled: true`. A single-language site renders
no language label anywhere and needs nothing.

### BEFORE the upgrade — check whether the site is multi-language

```bash
grep -A3 '"i18n"' theme/site.json
```

If `enabled` is `false` or the block is absent, skip the rest of this section.

### AFTER the upgrade — add the key, or the label becomes a raw code

The default language's display name used to come from a fixed map inside
`core/I18n.php` covering thirteen codes. That map is gone: naming a language
is the site's decision, and the map made the default's name unchangeable —
there was no way to show `Brasil` or `PT` instead of `Português (Brasil)`.

Add it to `theme/site.json`:

```json
"i18n": {
  "enabled": true,
  "default": "pt-BR",
  "default_label": "Português (Brasil)"
}
```

Use whatever the switcher should read. Copying the old map's wording keeps
the site looking identical — that's the zero-surprise choice, not a
requirement.

**`schema:validate` fails until you do**, deliberately: the alternative is
`pt-BR` appearing in the live language switcher and on every language tab in
the admin. Catching it at deploy beats a client noticing it.

```bash
php bin/velk schema:validate
```

Additional languages are unaffected — their names live in `/admin/languages`
and were never in the map.

---

## v3.5.2 — migration files are deleted after being applied

**Nothing to do on upgrade.** Listed so the change isn't a surprise later.

From this version on, an installed site does not keep `migrations/` — it's in
`post_install_cleanup`. Two consequences worth knowing when debugging:

- `bin/velk migrate:status` can no longer tell "up to date" from "the files
  aren't here". It says so explicitly rather than claiming everything applied.
- Copying an installed site's *files* onto an **empty** database no longer
  self-installs, because `Installer::run()` builds the schema from those
  files. Copy the database too (which is what moving a site means), or run a
  fresh install.

`update-cms` also changed: it now deploys a **published release** fetched by
version, not the local working copy. Nothing to do, but a stale local checkout
will now be *refused* as a downgrade instead of silently shipping.

---

## v3.5.0 — UTM/click IDs merged into `params` ⚠️ DESTRUCTIVE

Three things, and the first one is the one you cannot redo later.

### BEFORE the upgrade — preserve the attribution data

The migration drops `utm_source`, `utm_medium`, `utm_campaign`,
`utm_content`, `utm_term` and `click_ids` from `form_submissions` **without
backfilling**. Run this first, while those columns still exist:

```sql
CREATE TABLE form_submissions_params_backup AS
SELECT id, utm_source, utm_medium, utm_campaign, utm_content, utm_term, click_ids
FROM form_submissions
WHERE utm_source IS NOT NULL OR utm_medium   IS NOT NULL
   OR utm_campaign IS NOT NULL OR utm_content IS NOT NULL
   OR utm_term   IS NOT NULL OR click_ids   IS NOT NULL;
```

Check it caught something before continuing — an empty backup on a site that
ran campaigns means you queried the wrong database:

```sql
SELECT COUNT(*) FROM form_submissions_params_backup;
```

### AFTER the upgrade — write it into the new column

`params` is one JSON object per submission, holding only the keys that
actually had a value. `JSON_OBJECTMERGE` isn't portable enough across
MySQL/MariaDB versions, so build it with `JSON_OBJECT` + `JSON_REMOVE` of the
nulls:

```sql
UPDATE form_submissions s
JOIN form_submissions_params_backup b ON b.id = s.id
SET s.params = JSON_REMOVE(
    JSON_OBJECT(
        'utm_source',   b.utm_source,
        'utm_medium',   b.utm_medium,
        'utm_campaign', b.utm_campaign,
        'utm_content',  b.utm_content,
        'utm_term',     b.utm_term
    ),
    IF(b.utm_source   IS NULL OR b.utm_source   = '', '$.utm_source',   '$.__keep'),
    IF(b.utm_medium   IS NULL OR b.utm_medium   = '', '$.utm_medium',   '$.__keep'),
    IF(b.utm_campaign IS NULL OR b.utm_campaign = '', '$.utm_campaign', '$.__keep'),
    IF(b.utm_content  IS NULL OR b.utm_content  = '', '$.utm_content',  '$.__keep'),
    IF(b.utm_term     IS NULL OR b.utm_term     = '', '$.utm_term',     '$.__keep')
)
WHERE s.params IS NULL;
```

Then fold the click IDs in, which were already JSON:

```sql
UPDATE form_submissions s
JOIN form_submissions_params_backup b ON b.id = s.id
SET s.params = JSON_MERGE_PATCH(COALESCE(s.params, '{}'), b.click_ids)
WHERE b.click_ids IS NOT NULL;
```

Then normalise away the empties. A row whose only attribution was an empty
string ends up as `{}`, and Velk's convention is that `params` is NULL when
nothing was captured — never `[]` or `{}`:

```sql
UPDATE form_submissions SET params = NULL
WHERE params IS NOT NULL AND JSON_LENGTH(params) = 0;
```

Verify, then drop the backup **only once you've looked**:

```sql
SELECT id, params FROM form_submissions WHERE params IS NOT NULL LIMIT 5;
SELECT COUNT(*) FROM form_submissions WHERE JSON_LENGTH(params) = 0;  -- must be 0
-- DROP TABLE form_submissions_params_backup;
```

Leave the backup table in place if anything looks off. It costs nothing and
it's the only copy.

### AFTER the upgrade — rename in the theme

`utm_params()` no longer exists. Find and replace:

```bash
grep -rn "utm_params" theme/
```

| Old | New |
|---|---|
| `utm_params()` | `tracking_params()` |

The **return shape changed too**, and a blind rename leaves a subtle bug:
`utm_params()` always returned all five UTM keys with `null` for unset ones,
so `$utm['utm_source']` was always defined. `tracking_params()` returns only
the keys actually captured. Any code doing `if ($utm['utm_source'])` now hits
an undefined index on a direct visit — use `!empty($p['utm_source'])`.

### AFTER the upgrade — rename in webhook handlers

```bash
grep -rnE "context\[.(utm|click_ids)." theme/
```

Quote-agnostic on purpose: `$context['utm']` and `$context["utm"]` are both
common, and a pattern hardcoding one silently misses the other.

| Old | New |
|---|---|
| `$context['utm']['utm_source']` | `$context['params']['utm_source']` |
| `$context['click_ids']['gclid']` | `$context['params']['gclid']` |

### AFTER the upgrade — the GTM container

Not code, but it breaks silently and nobody notices until a client asks why
conversions stopped. The `velk_form_success` dataLayer payload changed:

| Old path | New path |
|---|---|
| `utm.utm_source` | `params.utm_source` |
| `click_ids.gclid` | `params.gclid` |

Update the data layer variables in every container pointed at this site.

### Not reversible

This is Velk's first non-additive migration. Until v3.5.0 the schema only ever
ran *ahead* of older code, and an unknown column is simply ignored — so
`upgrade --version=<older>` was safe. Downgrading across this point finds code
looking for columns that no longer exist. **One-way door.**

---

## v3.4.0 — conversion events land in the dataLayer

**Nothing required.** Purely additive: forms and member registration start
pushing `velk_form_success` / `velk_signup_success`, and public forms gain a
JSON response mode behind `Accept: application/json`. Themes that send no such
header behave exactly as before.

Worth doing though: if the site tracks form conversions with a GTM trigger on
"Page URL contains /obrigado", **replace it** with a custom-event trigger on
`velk_form_success`. The URL trigger counts refreshes, bookmarks, direct
visits and bots that crawl the thank-you page — including bots the honeypot
caught, since they're redirected there too. Expect the numbers to *drop* after
switching; that's the inflation going away.

---

## v3.2.2 — image variants need a one-time backfill

Variants are generated **at upload time**, deliberately — the older lazy
generation was removed because it was unreliable. The consequence on upgrade:
every image already in the library predates the feature and has no `thumb`.

Nothing breaks. `Media::url()` falls back to the original file when a variant
is missing, so the admin and the theme keep rendering — they just serve the
full-size original everywhere a thumbnail was intended. It's silent, and the
symptom is a slow media library and heavy pages, never an error.

### AFTER the upgrade — backfill

```bash
./bin/velk media:variants
```

It walks the library in batches, skips SVG and non-images, and reports
`Generated / Skipped / Failed`. Safe to re-run — existing variant files are
skipped unless you pass `--regen`.

Two things to check before trusting a clean run:

- **`ext-gd` must be present**, or the command exits 1 without generating
  anything. Worth confirming on the target host, since the admin never
  needed GD before this version.
- A non-zero **Failed** count lists each file — usually a corrupt upload or
  a row whose file vanished from disk (those are skipped, not failed).

Also relevant if the theme declares per-field `variants` in `site.json`: add
the declaration first, then run the backfill, or the new sizes won't exist for
existing images.

---

## v3.2.0 — admin language and button labels

### Set `ADMIN_LOCALE` on Portuguese installs

The default flipped to English. An existing Brazilian site will show an
English admin panel — and English 2FA/reset emails to members — until:

```
ADMIN_LOCALE=pt
```

goes in `.env`.

### Check the store/subscription button labels

`member_subscribe_button()`, `member_portal_button()` and
`store_checkout_button()` used to default to Portuguese labels; they now
default to English via `t()`. A theme calling them bare renders "Subscribe"
where it used to render "Assinar".

```bash
grep -rn "member_subscribe_button\|member_portal_button\|store_checkout_button" theme/
```

Either pass the label explicitly — `store_checkout_button($cart, 'Comprar')` —
or add the strings to the theme's `t()` catalog.

---

## v3.0.0 — Plooma → Velk ⚠️ RENAMES THE NAMESPACE

The engine was renamed four times. Any install predating v3.0.0 runs under an
older namespace, and the theme is on its own — the rename commit says so
outright: *"Not touched: theme/ (author adjusts)"*.

| Era | Namespace | CLI | Version file |
|---|---|---|---|
| ≤ v1.6.0 | `Nano\` | `bin/nano` | — |
| v2.0.0 | `Ellev\` | `bin/ellev` | — |
| v2.1.0 – v2.4.0 | `Plooma\` | `bin/plooma` | `.plooma-version` |
| **v3.0.0 +** | `Velk\` | `bin/velk` | `.velk-version` |

### First: the upgrade tool won't recognise the install

`.plooma-version` became `.velk-version`, so an upgrade run against a Plooma
site finds no version file and falls into the "unknown → latest" path. That
still works, but confirm the starting version yourself before trusting the
report — check `core/VERSION`, or the old file:

```bash
cat .velk-version 2>/dev/null || cat .plooma-version 2>/dev/null || cat core/VERSION
```

### AFTER the upgrade — the theme references

Helper *names* did not change: `field()`, `item()`, `media()`, `url()` and
friends work exactly as before. What breaks is a theme reaching for an engine
class directly.

```bash
grep -rnE '(\\|use )(Nano|Ellev|Plooma)\\' theme/
```

The `use ` alternative matters: an import written `use Plooma\Models\Item;`
has no leading backslash, so a pattern anchored on one misses it — and that
is the most common way a theme references an engine class.

Replace the vendor segment, keeping everything after it:

| Old | New |
|---|---|
| `\Plooma\Mailer::fromEnv()` | `\Velk\Mailer::fromEnv()` |
| `\Plooma\Models\Item` | `\Velk\Models\Item` |
| `use Plooma\...;` | `use Velk\...;` |

Same substitution for `\Ellev\` and `\Nano\` on older sites.

### AFTER the upgrade — the media-picker callback

A theme or custom admin field that hooks the media picker used a global JS
callback whose name carried the brand:

```bash
grep -rn "__ploomaPickerCallback\|__ellevPickerCallback\|__nanoPickerCallback" theme/
```

→ `__velkPickerCallback`. This one fails silently: the picker opens and
selecting an image simply does nothing.

### Everyone gets logged out, and that's expected

The session cookie changed (`plooma_session` → `velk_session`), so every
admin and every logged-in member is signed out the moment the new engine
lands. Nothing is lost — but tell the client before they call you about it.

### Scripts and cron

Anything calling the old binary breaks. Cron entries are the usual casualty
because nobody looks at them:

```bash
crontab -l | grep -E "bin/(nano|ellev|plooma)"
```

→ `bin/velk`. Deploy scripts, CI, and `.deploy/` helpers too.

### Not the same as the *skill* rename

`plooma:install`, `plooma:ssh-deploy` and the rest are a separate, older
plugin. Renaming the engine did not touch them, and they are not part of this
upgrade — the current tooling is the single `velk` skill.

---

## v2.1.0 — Ellev → Plooma · v2.0.0 — Nano CMS → Ellev

Same shape as v3.0.0, one era earlier: namespace, CLI binary and cookie all
carry the old brand. If you are moving a site from this far back, do the
substitution straight to `Velk\` rather than walking each rename — the
intermediate names are only useful for recognising what you're looking at.

Treat a site this old as "version unknown" and read every section on this
page, oldest first.

## Adding to this page

A version belongs here when a correct upgrade needs something beyond swapping
files: data to preserve, a rename in `theme/`, a backfill to run, a config key,
a container to re-point.

It also belongs here when the upgrade **silently changes behaviour** that
someone will later debug — v3.5.2 and v3.4.0 are on the page for that reason,
even though neither requires an action. The test isn't "was there work to do",
it's "would someone be surprised afterwards".

What to leave out: releases that are purely additive, including features that
only need theme work *if you adopt them*. v3.3.0's `file` field needs
`enctype="multipart/form-data"`, but only in a theme that adds a file input —
an upgrade alone never breaks. A page padded with those stops being read.

State clearly whether each step runs **before** or **after** the file swap.
That distinction is the reason this file exists.

**Provenance.** `CHANGELOG.md` only goes back to v3.1.0. Everything on this
page for v3.0.0 and earlier was reconstructed from git history and commit
messages, so treat it as a good-faith reading of the diffs rather than as
release notes — verify against the actual install when the stakes are a
one-way migration.
