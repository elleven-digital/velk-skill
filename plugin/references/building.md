# Building & customizing a Velk site

`theme/site.json` is the schema for the whole site — pages, item types,
taxonomies, fields, options, forms, members. Templates and helpers read that
schema back out to render the site. This file covers all of it.

> **Never edit the engine** (`core/`, `config/`, `bin/`, `migrations/` and the
> other engine paths): an upgrade replaces them wholesale and the change
> silently disappears. Everything here happens in `theme/` and
> `theme/functions.php`; when the engine lacks something, ask for it in Velk.
> A custom block in the rich-text editor, for example, is a theme block
> declared in `site.json` ([Richtext blocks](#richtext-blocks-v390), v3.9.0+) —
> never an edit to `core/Admin/assets/js/tiptap.js`. See SKILL.md.

## Contents

- [site.json — the core schema](#sitejson--the-core-schema)
- [Field types](#field-types)
- [Templates](#templates)
- [Helpers](#helpers)
- [Database](#database)
- [URL conventions](#url-conventions)
- [Media library](#media-library)
- [Options pages](#options-pages)
- [Forms](#forms)
- [Richtext blocks](#richtext-blocks-v390)
- [Site members](#site-members)

## site.json — the core schema

Top-level keys:

| Key | Shape |
|---|---|
| `site` | `name`, `language`. Deploy URL is NOT here — it's `APP_URL` in `.env` (read by the sitemap, `absolute_url()`), keeping the theme portable across projects. |
| `field_groups` | Reusable field bundles, referenced elsewhere as `{"group": "contato"}` and inlined at render time. |
| `pages` | Structural pages keyed by page key (e.g. `home`): `label`, `template`, optional `url` (default `/` for `home`, `/{key}` otherwise), `fields`. |
| `page_templates` | Templates for admin-created pages (the "+ Criar página" flow): `label`, `file`, `fields`. The row lives in the DB, not this JSON — URL is `/{slug}`, set in the admin. |
| `item_types` | Content types keyed by type (e.g. `post`): `label`, `label_singular`, `slug` (URL prefix), `template`, `taxonomies`, `templates` (alternate per-item layouts), `fields`, optional `has_page`, optional `manual_order` (v3.7.5+, see Manual ordering). No archive page: see Templates. |
| `taxonomies` | Keyed (e.g. `categoria`): `label`, `label_singular`, `slug`, `hierarchical`, `template`, optional `manual_order` (v3.7.5+, see Manual ordering), optional `has_page` (default `true`; `false` 404s `/<slug>/<term>`, skips the sitemap, `Term::url()` → `''` — terms still exist and stay assignable in admin). |

**Templates bind by file name, never by slug** — rename a slug freely, the
binding stays intact. **No built-in `content` or `thumbnail`** — declare
them as custom fields; every site decides what it needs. Per-item custom
templates go under `item_types.{type}.templates` (`{key, label, file}`
entries), adding a Template dropdown to that item's admin editor.

**Image variants are per-field, not a top-level key.** `image`/`gallery`
fields declare their own `variants` array — see Field types below and
Media library for the full schema and generation semantics. There's no
site-wide `image_sizes` key.

**Built-in SEO fields — do not redeclare.** Velk auto-attaches `meta_title`
(text), `meta_description` (textarea), `og_image` (image) to every page and
every item type with `has_page: true` (`Config::seoFields()`), rendered as
the admin's own "SEO & compartilhamento" section. Read them like any other
field — `field('meta_title')`, `image_url(field('og_image'))` — never
declare a custom `seo` field group or `meta_title`/`og_image` fields; that
duplicates the built-in block.

## Field types

| Type | Notes |
|---|---|
| `text` | Single-line input. |
| `textarea` | Multi-line plain text. |
| `richtext` | TipTap WYSIWYG (+ quote, inline code, code block, simple tables); saves HTML. Output unescaped, commented `/* trusted */`. Quote and table styling on the front is the theme's job. Optional `blocks: ["key", …]` — theme blocks the author can insert (v3.9.0+, see Richtext blocks). |
| `image` | One media reference, stored as an **integer id**. Resolve with `image_url()`. Optional `variants` array declares extra sized versions (`name`, `width`/`height`, `fit`) — see Media library. |
| `gallery` | Ordered list of media references, stored as **array of integer ids** — pass each through `image_url()`. Same optional `variants` support as `image`. |
| `file` | One media library entry of any kind (video, audio, document, zip, image), stored as an **integer id** (v2.4.0+). Optional `accept` lists the categories the picker shows (`image`, `video`, `audio`, `document`, `archive`). Resolve with `file_url()`; `media($id)` gives name, mime and size. Forms have their own `file` field (see Forms). |
| `select` | Dropdown; define `options` as `{value: label}`. |
| `boolean` | Checkbox. |
| `number` | Numeric input. |
| `email`, `url`, `date` | HTML5 input variants. |
| `repeater` | Repeating group of subfields; define `fields` on the field. Optional `title_field` labels each collapsed row (see below). |
| `flexible` | Repeater where each row picks a `layout` from a named set (`layouts: {key: {label, fields}}`). Saved rows carry `_layout` (reserved name) so the theme can switch on it — ACF Flexible Content equivalent. |
| `link` | Composite `{title, url, new_tab}` (or `null` when blank). Blank URL never blocks a save; no scheme whitelist — allows `mailto:`, `#anchor`, relative paths. Render with `link_tag(field('cta'))`. |
| `item` | Reference to another item, via searchable combobox — picker only offers **published** items of the target type. Define `item_type` (target slug). Stored as **integer id** like `image`. Resolve with `item(field('name'))` → `Item` or `null`. |
| `group` | Organizational only — collapsible box in the admin UI (`label` + `fields`, collapsed by default, `"open": true` to expand). Storage is flat, no wrapper key. |
| `tabs` | Organizational only — tab strip (`tabs: [{label, fields}, ...]`). Same flat storage; two tabs can't reuse a field name (`schema:validate` catches it). |

Common options on any field: `name` (required), `label`, `help`, `required`,
`placeholder`. `field('name')` returns the raw stored shape — scalar for
simple types, array for `gallery`/`repeater`/`flexible`. `group`/`tabs` are
invisible to storage — read children by their own name regardless of nesting.

**`show_if`** hides a field until a sibling matches:

```json
{"name": "cta_url", "type": "url", "show_if": {"field": "tem_cta", "equals": true}}
{"name": "coords",  "type": "text", "show_if": {"field": "tipo", "in": ["mapa","video"]}}
```

Two operators (`equals`, `in`); comparison is loose so `"equals": true` works
against a checkbox whatever form the value arrives in. A hidden field drops its
`required` (an invisible required field blocks submit with nothing on screen)
and gets it back when shown. Scope is the flat values array — siblings plus
`group`/`tabs` children; a repeater row is its own scope and `schema:validate`
rejects conditions crossing it. Malformed conditions leave the field visible.
Rendered server-side, kept in sync by admin.js.

**`repeater.title_field`** labels collapsed rows with a subfield's value
instead of `ITEM 01`:

```json
{ "name": "links", "type": "repeater", "title_field": "rotulo",
  "fields": [{"name": "rotulo", "type": "text"}, {"name": "destino", "type": "link"}] }
```

Allowed types are the ones whose value already reads as text: `text`, `email`,
`url`, `tel`, `number`, `textarea`, `select`, `link` — `schema:validate`
rejects anything else and lists the valid set. `select` shows the option
*label*, `link` shows the title and falls back to the URL. An empty value
falls back to the number, which is a CSS counter and therefore renumbers
itself on reorder/delete. The subfield may sit inside a `group`/`tabs`. Only
`repeater` — `flexible` rows are already labelled by their layout name.

## Templates

Bound **by file name** in `site.json`, never by slug. Resolution order:

1. Page (`pages`): `template` → fallback `page.php`.
2. Admin page (`page_templates`): chosen entry's `file` → fallback `page.php`.
3. Item single: item's own template if in `item_types.{type}.templates` →
   else the type's `template` → fallback `single.php`.
4. Taxonomy archive: taxonomy's `template` → fallback `taxonomy.php`.

Item types have no archive: `/{item-type-slug}` alone is not a route, and an
`archive_template` key is ignored. A list like `/blog` is a page declared at
that URL whose template calls `items('post')` (published items only).

```php
<?php \with_context($item, function () {
    get_header(); ?>
    <h1><?= e(the_title()) ?></h1>
    <div><?= field('content') /* trusted */ ?></div>
    <?php get_footer();
}); ?>
```

A `richtext` field that accepts blocks prints through
`richtext(field('content'))` instead (v3.9.0+), or its blocks never show —
see [Richtext blocks](#richtext-blocks-v390).

**Object form, without `with_context()`.** `Item`, `Page` and `Term` expose
`field()`, `url()` and a title accessor (`title()`; `name()` on `Term`), all
resolving the active language via `fieldIn()`/`titleIn()` — which fall back to
the default-language value, so an untranslated field (a price) reads the same
either way.

```php
<?php foreach (items('post') as $post): ?>
    <a href="<?= e($post->url()) ?>"><?= e($post->title()) ?></a>
<?php endforeach; ?>
```

Ambient helpers stay the default for templates (terse, and a `partial()` reads
the record without it being threaded in). Prefer the object form outside
templates — `functions.php`, webhook handlers — where `field()` would return
its default silently for lack of context.

`with_context()` lets `field()`/`the_title()`/etc. work without threading
the record through every call. Each template type gets one `TemplateContext`
variable:

| Template type | Variable | Shape |
|---|---|---|
| `page-*.php` | `$page` | `->record` is `Page` |
| `single-*.php` | `$item` | `->record` is `Item` |
| `taxonomy-*.php` | `$term` | `->record` is `Term`, `->records` is `list<Item>` |

There is no `archive-*.php` template or `$archive` variable: item types have
no archive (see Templates).

### CSS and JS: always a version in the URL

Velk's `.htaccess` lets browsers keep CSS and JS for a month, and `asset()`
adds no version. Without one, a change "doesn't show up" — and a returning
visitor can get new HTML with old CSS. Add the file's modification time:

```php
<link rel="stylesheet" href="<?= e(asset('theme/style.css') . '?v=' . filemtime(dirname(__DIR__) . '/style.css')) ?>">
<script src="<?= e(asset('theme/app.js') . '?v=' . filemtime(dirname(__DIR__) . '/app.js')) ?>" defer></script>
```

(`dirname(__DIR__)` is `theme/` when the tag sits in `theme/partials/`.) The
versioned publish warns when CSS or JS changes and the theme loads them without
it.

On engine v3.8.1+, every `<script>` also carries the page's nonce —
`<script nonce="<?= csp_nonce() ?>" src="…" defer>` — so the site works if the
client ever turns on the strict CSP. See
[Content Security Policy](#content-security-policy-v381) below; on an older
engine `csp_nonce()` doesn't exist, so leave it out there.

A **new page under construction** gets its own CSS file, loaded only by its
template: iterating on it can't break the rest of the site. A one-off change to
an existing rule edits the rule where it lives.

## Helpers

All in `core/helpers.php`, globally available in templates.

**Output** — `e($value)` escape-by-default, use everywhere except trusted
richtext HTML; `dd(...$values)` debug dump and exit.

**Context** — `current_context()`; `with_context($context, fn)`;
`field($name, $default = null)`; `the_title()`, `the_slug()`, `the_url()`.

**Items / terms** — `items($type, $args = [])` (`limit`, `offset`, `status`
default `published`, `term`, `order`); `terms($taxonomy)`;
`the_terms($taxonomy)`; `item($id)` → `Item` or `null`.

**URLs / media** — all prepend the install base path, so links keep working
in a subdirectory install; never hardcode a root path.
- `url($path = '/')` — navigation links.
- `absolute_url($path = '/')` — full scheme+host from `app.url`; canonical
  tags, og:url, sitemap.
- `admin_url()`, `asset($path)`, `base_path()`.
- `image_url($value, $size = 'full')` — resolves id/URL/path/array to a URL,
  `''` when missing. `$size` names an image variant (`'thumb'`, or a
  field's declared `variants` name) — pure disk check, falls back to the
  original file when that variant wasn't generated. Check for `''` before
  rendering an `<img>`.
- `image_alt($value, $fallback = '')` — i18n-aware alt text.
- `media($id)` — the `Media` model (width/height/mime).
- `file_url($value)` — URL of a `file` field's media, same resolution as
  `image_url()`.
- `link_tag($link, $text = null, $attrs = [])` — safe `<a>` for a `link`
  field; adds `target="_blank" rel="noopener noreferrer"` when `new_tab`.

**Forms (admin only)** — `csrf_token()`, `csrf_field()`; always include
`csrf_field()` in admin forms.

**Layout** — `get_header()`, `get_footer()` (include
`theme/partials/{header,footer}.php`); `partial($name, $data = [])`.

**Misc** — `slugify($string)`; `config($key)` / `site($key)` (dot notation).

## Database

| Table | Holds |
|---|---|
| `users` | Admin users |
| `pages` | One row per `pages.{key}` |
| `items` | Every post/case/etc; `fields` is JSON |
| `terms` | Taxonomy terms; `fields` is JSON |
| `item_term` | N:N item↔term relation |
| `media` | Uploaded files |
| `settings` | Key/value JSON store (options pages live here) |
| `migrations` | Applied migration log |

`fields` columns are native MySQL JSON — query inside with
`->>'$.field_name'`. Full schema is in `migrations/` (removed by the
installer after applying, but still the source of truth in the repo).

## URL conventions

Relative to the install root — prepend the base path if Velk is mounted at
`/velk/`.

- `/` → home page
- `/{page-key}` → other structural pages (or an explicit `url`)
- `/{item-type-slug}/{item-slug}` → single item (`/{item-type-slug}` alone
  answers only when a page is declared at that URL)
- `/{taxonomy-slug}/{term-slug}` → taxonomy term archive
- `/admin` → admin panel · `/uploads/...` → media · `/theme/...` → static
  theme assets only (no PHP)

Base path auto-detects from `$_SERVER['SCRIPT_NAME']`; if that fails on a
host, set it explicitly: `'base_path' => '/velk'` in `config/env.php` (`''`
for root, `null` to autodetect).

Always go through the URL helpers (`url()`, `asset()`, `admin_url()`,
`image_url()`, `Item::url()`, `Term::url()`, `Page::pageUrl()`) — a
hardcoded `/blog` breaks the moment the site moves into a subdirectory.

## Media library

Lives at `/admin/media`.

- Upload — POST `/admin/media/upload` (JSON response). Limits per category
  (v2.4.0+): images (jpeg, png, gif, webp, svg) and documents (pdf, docx,
  xlsx, pptx) up to 25 MB, audio (mp3, m4a, ogg, wav) up to 50 MB, zip up to
  100 MB, video (mp4, webm, mov) up to 200 MB. PHP's `upload_max_filesize` /
  `post_max_size` can lower any of them. Content points at a non-image
  through a `file` field.
- Detail panel — alt text, copy URL, delete (cleans up sized variants).
- Picker mode (`/admin/media?picker=1`) — the iframe view an image field
  opens; selecting an item calls `window.parent.__velkPickerCallback(data)`.

```
storage/uploads/{filename}.{ext}                          original — always served for 'full'
storage/uploads/_variants/thumb/{filename}.{ext}           global thumb, generated at upload
storage/uploads/_variants/{variant-name}/{filename}.{ext}  per-field variants, generated at content save
```

Every raster upload (jpeg/png/gif/webp — never svg) gets a global `thumb`
at upload: 400px box, `contain`, downscale-only. `image`/`gallery` fields
can declare their own `variants: [{name, width?, height?, fit?}]` (`fit`:
`contain` default = scale-to-fit, `cover` = scale-to-fill, `crop` = exact
`width`×`height` via center-crop — all downscale-only, never upscale).
SVG uploads are exempt — already scalable, so `image_url()` on one just
returns the SVG itself. Generation is always write-time (upload for
`thumb`, content save for field variants), never lazy at render —
`image_url()` does a pure disk check and falls back to the original when
a variant is missing, never a 404. Backfill/rebuild with `bin/velk
media:variants [--regen]`. Filenames are slugified (`Foo Bar.JPG` →
`foo-bar.jpg`); collisions get a `-1`, `-2`, … suffix.

## Options pages

Site-wide global fields — contact info, footer text, social links — under
`site.json → options`. Each entry becomes a sidebar link and a fields-only
form (no slug, URL, or list view) — ACF Options Pages, basically.

```json
"options": {
  "contato": {"label": "Contato",
    "fields": [{"name": "phone", "type": "text", "label": "Telefone"}]}
}
```

Same field types and `{"group": "contato"}` groups as elsewhere. Read with
`option($path, $default = null)` — dot path, first segment is the page key
(`option('contato.phone')`), reaching into groups and repeater rows too
(`option('contato.social.0.url')`). `options($key)` returns a page's full
values array. Storage: one `settings` row per page (`setting_key =
"options.{key}"`, value = JSON), cached in-process — 50 `option()` calls in
a template cost one query.

## Forms

Declared under `site.json → forms`, rendered manually in templates — the
form id connects JSON to markup.

```json
"forms": {
  "contato": {
    "label": "Contato",
    "subject": "Novo contato: {{name}}",
    "success_message": "Mensagem enviada.",
    "fields": [{"name": "name", "type": "text", "label": "Nome", "required": true}]
  }
}
```

Field types: `text`, `email`, `tel`, `url`, `number`, `textarea`, `checkbox`,
`hidden`, `select`, `file` (`required`, `maxlength`); `subject` supports
`{{field_name}}` placeholders from the submission.

**`preview_field`** names which field labels the collapsed card in
`/admin/forms/{id}`. Omitted, the label falls back to the first non-empty text
value — which works only by accident of ordering (data is stored in field
declaration order), so reordering fields for layout used to change the list
silently. The named field still falls back when empty or when it's a `file`
(metadata array, not a string); a name that isn't a field of that form is
caught by `schema:validate` rather than silently ignored at runtime.

**`file` fields** (`{"name": "cv", "type": "file", "accept": ["pdf","docx"], "max_size": 5}`):
one file per field; `accept` narrows the built-in whitelist (`pdf`, `jpg`,
`png`, `webp`, `gif`, `docx`, `xlsx`, `pptx`, `zip` — no video/audio; `svg`
only with explicit `"accept": ["svg"]`), `max_size` in MB (default 10).
Uploads are stored **outside the media library** (no `Media` row) under
`storage/form-uploads/`, private, downloadable only from the admin. The saved
value is a metadata array (`_file`, `path`, `name`, `size`, `mime`), not a
string — webhook handlers get that shape. **The `<form>` must carry
`enctype="multipart/form-data"`** or the file silently never arrives.

**Attribution is automatic** (v4+). `Velk\Params` captures UTM **and** ad
click IDs (`gclid`, `gbraid`, `wbraid`, `fbclid`, `msclkid`, `ttclid`,
`li_fat_id`, `twclid`) from any GET query string into the session — surviving
navigation — and saves them on the submission in one `params` JSON column,
which is also the webhook `$context` key. Nothing to declare in `site.json`;
don't build hidden fields for this.

The whitelist is closed and the loop walks IT, never the query string, so
`?cpf=...` can never be captured. Last-touch is **per group**: arriving with
only a click ID does NOT wipe the UTM already attributed. Themes read the
current set with `tracking_params()` (only captured keys; `[]` on a direct
visit). Adding a parameter is one whitelist entry — no migration, since the
storage is JSON. No admin filter for any of it: UTM belongs in GA4/Ads, and a
click ID is unique per click.

Theme writes the HTML: `form_url($id)` for `action`, `csrf_field()` +
`form_honeypot()` + `form_captcha()` for spam protection, `form_status($id)` for the prior
flash (`status`, `message`, `values`, `errors`). Lifecycle: POST
`/forms/{id}` validates CSRF + honeypot + fields, saves to
`form_submissions` (JSON `data`), emails the recipients set at
`/admin/forms/{id}`, redirects to the referrer — a failed email still saves
the submission. `/admin/forms` lists forms with submission counts.

**Webhook**: `forms.<id>.webhook` (string or list) calls a
`theme/functions.php` function AFTER save+email:
`function(string $formId, array $values, array $context): void`. `$context`
= `submission_id`, `ip`, `user_agent`, `referer`, `params` (captured keys only),
`created_at`. Missing/throwing handler → `error_log`, never breaks the
submission.

**AJAX submission** (v3.4+): send `Accept: application/json` and the response
is a JSON body — `{status, message, errors?, values?, event?}`, `200` on
success, `422` on failure — instead of flash-and-redirect. Additive; a plain
`<form>` POST is unchanged. Never `fetch()` WITHOUT that header: fetch follows
the 302, the fetched render consumes the flash (`form_status()` is get +
forget), and the message vanishes silently.

## Richtext blocks (v3.9.0+)

Structured blocks (big numbers, a testimonial, a video) the author drops
between paragraphs of a `richtext` field. Declare once at the top of
`site.json`, list on each field that accepts it:

```json
"richtext_blocks": {
  "bignumbers": { "label": "Big numbers", "file": "bignumbers.php",
    "fields": [ { "name": "itens", "type": "repeater", "fields": [
      { "name": "valor", "type": "text" }, { "name": "rotulo", "type": "text" } ] } ] }
}
```
```json
{ "name": "content", "type": "richtext", "blocks": ["bignumbers"] }
```

- Key: lowercase, digits, `_`, starting with a letter. `label`, `file`,
  non-empty `fields` required; any field type works. No blocks inside a
  block.
- `file` is a file name only, always in `theme/partials/richtext/` — bound by
  the declaration, never by the key. Each top-level field becomes a variable
  in the partial (so a valid PHP variable name); a missing field arrives
  empty (`null`, `false`, `[]`), so print with `e()` and cast before string
  functions.
- Print the field through the helper, or blocks never show:
  `<?= richtext(field('content')) /* trusted */ ?>`. A block that can't be
  printed prints nothing (reason in the log with `APP_DEBUG`).
- `schema:validate` checks the declaration, the partials and the helper call.
- Stored as an empty marker in the HTML:
  `<div data-velk-block="key" data-velk-data='{"…":"…"}'></div>` — see
  `references/content.md` when writing content outside the admin.

## Sortable tables (v3.6+)

Any admin table whose rows are DB records with their own order can be made
drag-reorderable — the mechanism is generic, built for `/admin/scripts` and
meant for the item tables next.

```html
<tbody data-sortable-table
       data-sortable-endpoint="<?= e(admin_url('scripts/reorder')) ?>"
       data-csrf="<?= e(csrf_token()) ?>">
  <tr draggable="true" data-sortable-id="<?= (int) $row->id ?>">…</tr>
</tbody>
```

The endpoint receives `ids[]` in the new order plus `_csrf`, and answers JSON;
a non-ok response reloads the page rather than leaving the screen showing an
order the database doesn't have. Model side, mirror
`TrackingScript::applyOrder()`: unknown ids ignored, absent ids left alone —
the call comes from a browser whose list may be stale.

**One `<tbody>` per independently-ordered group.** The scripts screen uses one
per position, which also stops a row being dragged into a group it doesn't
belong to; with a single tbody the row would snap back on the next load with
no explanation.

Reuses `makeRowsSortable`, which the repeater and flexible widgets already
share — the only thing this adds is persistence.

## Manual ordering (v3.7.5+)

Every item type comes out newest-first and every taxonomy alphabetically.
Right for a blog, wrong for a product grid, a team page, a FAQ. Set
`manual_order` and the client drags the order in the admin:

```json
"item_types": { "produto":   { "manual_order": true, ... } },
"taxonomies": { "categoria": { "manual_order": true, ... } }
```

Absent or `false` = today's behaviour, byte for byte. `true` unquoted —
`schema:validate` rejects the string, and only a literal `true` turns it on,
so a hand-edited `"true"` cannot enable it by accident.

**The theme needs no change.** `items('produto')` and `terms('categoria')`
start returning the panel order on their own. Turning the flag on does not
reshuffle the site either: the first time that admin list opens, the order
already on screen is written into a `sort_order` column, and the client drags
from there.

Backed by the same `data-sortable-table` contract as tracking scripts (see
Sortable tables above) — the endpoints are
`POST /admin/items/{type}/reorder` and
`POST /admin/taxonomies/{taxonomy}/reorder`, both 404 when the flag is off.

### Four things that get reported as bugs

- **An explicit `order` still wins.** `items('produto', ['order' => 'title
  ASC'])` keeps ordering by title. This is the one people hit: "I turned it
  on and the drag does nothing." Remove the `order` from that call.
- **`the_terms()` is unaffected** — the per-item term list always sorts by
  name, so category badges on an item page stay alphabetical.
- **The taxonomy archive** (`/categoria/x`) follows the manual order only
  when that taxonomy belongs to exactly **one** item type. Shared between
  two, it stays on publish date: each type has its own sequence starting at
  1, and interleaving them means nothing.
- **The admin list is still paginated at 50.** Dragging moves a row within
  its page — you cannot drag from page 3 to the top. Search and status
  filters stay usable, and reorder only permutes the visible rows among
  themselves; a row hidden by the filter, sitting between two you moved,
  stays where it was.

`sort_order` is also a valid column in the theme's `order` argument for any
type, flag or no flag.

## Sessions & edge caching (v3.7+)

The session opens **on demand** — when the request carries the session cookie,
or on the first write. A page nobody reads from or writes to emits no
`Set-Cookie`, which is what lets a CDN cache it.

`Response::send()` sets `Cache-Control` accordingly: `public, s-maxage=CACHE_TTL`
when no session opened, `private, no-store` when one did. **`CACHE_TTL=0` (the
default) turns it all off.**

A page with a form is never cached — `csrf_field()` writes the token, and a
per-visitor secret can't live in a page identical for everyone. Expected, not a
limitation.

**Watch the theme, not the engine.** `csrf_field()` in a global partial (footer
newsletter) makes every page write a session and nothing cache, silently. Set
`APP_DEBUG=true` and read `X-Velk-Cache` to see which pages are cacheable and
why the others aren't.

## Tracking scripts & consent (v3.6+)

Scripts live at **`/admin/scripts`** — one row each: name, position
(`head`/`body_start`/`body_end`), on/off, drag order, and an optional consent
category. `tracking_head()` / `tracking_body_start()` / `tracking_body_end()`
emit them; themes call the same three helpers as always. The old three
textareas in options are gone (see `upgrade-notes.md` — the values are **not**
migrated).

**Consent is off per script.** No category = always loads, which is the default
and covers GTM, verification tags, error monitors. Ticking "requires consent"
reveals a category select.

Categories are the theme's:

```json
"consent": {
  "enabled": true,
  "categories": {
    "analise":   { "label": "Análise",   "mode": "opt_out" },
    "marketing": { "label": "Marketing", "mode": "opt_in" }
  }
}
```

**`enabled` is what makes the consent area exist at all** — it is the theme
stating it has a banner. Without it the admin shows no consent column and no
checkbox, and every script is necessary. Velk ships no banner, so offering the
option on a theme without one would invite marking a script that never loads.
`categories` is optional: `enabled` alone means all-or-nothing.

`required` always loads; `opt_out` until refused; `opt_in` only after
acceptance. Without the block the select offers two implicit options
(optional on/off) and the banner is all-or-nothing — declaring categories is
what makes it readable to a visitor.

Granted rows are emitted raw at their position (a returning visitor touches no
JS); non-granted go out inert as
`<script type="text/plain" data-velk-consent="…">` with a base64 payload
(pasted snippets routinely contain `</script>`), activated by `velkConsent`
without a reload. A row pointing at an undeclared category emits **nothing**.

**Velk ships no banner.** Build it against `velkConsent.categories() /
.state() / .answered() / .set() / .acceptAll() / .rejectAll()` and the
`velkconsent` event. Until something calls `set()`, `opt_in` rows stay inert
forever.

Gotchas: a gated `<noscript>` never renders (correct — no-JS visitors can't
consent either); snippets of one service must share a category; renaming a
category key silently disables every row still pointing at the old one.

## Content Security Policy (v3.8.1+; in `site.json` since v3.8.4)

The core sends the public site a CSP declared in the theme's `site.json`
(`security.csp`; up to v3.8.3 it came from `.env` — see
`references/upgrade-notes.md`). The default, `open` (also with no block),
restricts no script: only `frame-ancestors 'self'`, `base-uri 'self'` and,
over HTTPS, `upgrade-insecure-requests`. `strict` runs without
`'unsafe-inline'` — the finding security scanners report — and executes only
scripts that carry the page's nonce; `report` rehearses it without blocking.
Only the report collector, `CSP_REPORT_URI`, stays in `.env`. Full reference:
the project's `AGENTS.md` → "Content Security Policy (public site)".

```json
"security": { "csp": {
    "mode": "open",
    "allow": {
        "frame": ["https://www.youtube.com"],
        "form": ["https://*.list-manage.com"]
    }
} }
```

**Build every theme ready for `strict`**, even while the site runs `open` —
the day a client's scanner asks, only `mode` changes:

- `nonce="<?= csp_nonce() ?>"` on every `<script>`, `src=` ones included. The
  core already puts it on everything it prints (antispam, Turnstile, consent,
  the scripts registered in the admin, conversion events). What those scripts
  load inherits the trust (`'strict-dynamic'`), so there is no script list.
- No `on…=` attributes and no `javascript:` links — a listener in a script
  file. No `eval()` / `new Function()` (they need `"allow_eval": true`).
- Third-party HTML the theme prints from a field (an Instagram embed with its
  own `<script>`) goes through `csp_nonce_scripts($html)`.
- A policy of the theme's own — `header('Content-Security-Policy…')` in
  `functions.php`, or a `<meta http-equiv>` — is wrong now: use
  `security.csp`.
- Domain lists (`allow.connect`, `allow.img`, `allow.frame`) are optional. A
  declared list restricts that resource, in `strict` and `report`, to the
  site and the list: name everything the templates load for it (a YouTube
  iframe, an API), an editor's embed included, or leave the key out and the
  resource stays free.
- (v3.8.3+) In `strict` a form only sends to the site itself (`form-action`).
  A theme form that posts straight to another site (a newsletter form to an
  e-mail provider) gets that destination in `allow.form`. The same goes for a
  button's `formaction`, and for a redirect to another site after a POST (a
  `member_require_plan()` fallback to an external checkout): Chrome checks
  every redirect after a form is sent (other engines have differed — list
  the destinations either way). Stripe's checkout, and the portal with
  subscriptions, are added by the core on their own.

`php bin/velk csp:check` lists what strict would block in the theme, and
problems in the block (exit 1 on an error) — run it before handing a theme
over; `schema:validate` checks the block too (v3.8.4+). It reads templates as
text: an address built in PHP, or a redirect the site answers a form with,
only shows up in the browser (run `report` first).

`json_script($id, $data)` is the way to hand data to the theme's JS: a JSON
block the browser never executes.

## Conversion events (v3.4+)

Recorded submissions push `velk_form_success` to `window.dataLayer`; completed
member registrations push `velk_signup_success`. Always on, emitted from inside
`tracking_head()` (so any theme that calls it already works), consumed
one-shot. The traffic manager wires conversions in GTM off these triggers —
never in the theme.

```js
window.velkFormSuccess = {
  form_id: "orcamento", submission_id: 1234,
  params: {utm_source: "google", gclid: "…"},
  user_data: {email: "…", phone_number: "…"}   // only what the panel maps
};
```

Signup uses `window.velkSignupSuccess` with `member_id` + `type`. The variable
is the event name in camelCase.

**Never fires** for a honeypot catch (the branch returns before the enqueue —
structural, not a check), a validation/CSRF failure, or a repeat render. **Does
fire** when email or webhook dispatch failed: a lead is a lead.

The name is fixed, not configurable — it's the dataLayer trigger name, not the
GA4/Ads conversion name, and a fixed name is what lets one GTM container be
reused across every Velk site. Discriminate two forms by `form_id`, not by
renaming the event.

Configured in the panel (`/admin/forms/{id}`, and a section of *Scripts &
rastreamento* for signup): which field is the email, which is the phone
(nothing mapped by default — plain text, hashed by the Google tag in the
browser), plus an optional raw snippet for sites without a tag manager. The
snippet runs beside the push in its own `<script>` block and reads
`window.velkFormSuccess`; it is NOT executed on the AJAX path. A theme that
runs `event.snippet` itself creates a `<script>` element with the text —
never `eval` — and copies the page's nonce into it through the `nonce`
property (engine v3.8.1+; see AGENTS.md → Content Security Policy).

## Payment webhook

Global hook, same pattern as the forms webhook, fired when a Stripe event is
CONFIRMED. Top-level `site.json` key, string or list:

```json
"payment_webhook": ["deliver_ebook", "notify_crm"]
```

Handler in `theme/functions.php`, filters on `$event`:

```php
function studioweb_payment_event(string $event, array $data, array $context): void
```

- **Orders** — `order.paid` / `order.failed` / `order.expired`. Fires only
  on a real status TRANSITION (Stripe retries, byte-identical replays, or a
  second event confirming the same outcome do NOT re-fire).
  `$data = ['order' => ['id','member_id'(nullable),'email','status','currency','total_amount','stripe_session_id','stripe_payment_intent','created_at'], 'items' => [['item_id','item_type','title','unit_amount','quantity'], ...]]`
  `$context = ['stripe_event','event_ts','session_id','payment_intent']`
- **Subscriptions** — `subscription.<status>` (status verbatim from Stripe:
  `active`/`canceled`/`past_due`/`trialing`/`unpaid`/`incomplete`…). Fires
  when applied AND (status changed OR event ts strictly advanced) —
  renewals (same status, later period end) DO fire, filter with
  `$data['previous_status']`; tie replays don't. Note: a same-status re-fire
  isn't necessarily a renewal (`cancel_at_period_end` toggles, or
  `checkout.session.completed` landing after `customer.subscription.created`,
  also re-fire with `previous_status` equal) — for TRUE renewals compare
  `current_period_end` across events.
  `$data = ['member_id','plan_key','status','previous_status','billing_interval','current_period_end','cancel_at_period_end']`
  `$context = ['stripe_event','event_ts','stripe_subscription_id','stripe_customer_id']`

Handlers run SYNCHRONOUSLY in the Stripe webhook request — keep them fast,
queue/defer heavy work yourself. Missing/throwing handler →
`error_log('[Velk payment_webhook] ...')`, never breaks webhook processing.
`schema:validate` errors if `payment_webhook` isn't a non-empty string or a
non-empty list of non-empty strings.

Example — deliver a digital product on `order.paid`:

```php
function studioweb_payment_event(string $event, array $data, array $context): void
{
    if ($event !== 'order.paid') {
        return;
    }
    foreach ($data['items'] as $item) {
        if ($item['item_type'] === 'ebook') {
            \Velk\Mailer::fromEnv()->send(
                $data['order']['email'],
                'Seu ebook está pronto',
                '<p>Baixe seu ebook: https://example.com/download/...</p>'
            );
        }
    }
}
```

`\Velk\Mailer::fromEnv()->send($to, $subject, $htmlBody, $textBody = null)`
is the engine's own mailer (SMTP or `mail()` fallback) — `core/` is
autoloaded by namespace, so theme code can call `Velk\*` classes directly.
Note: `\Velk\Mailer` is internal engine code (wholesale-replaced on upgrade,
no compatibility contract) — works today, but a stabilized `mail()` theme
helper may formalize this later.

**Anti-bot** (v3.5.1+). `form_honeypot()` is always there and free — a caught
bot gets a deliberate FAKE success, so the author never learns the trap
exists; nothing is stored, no conversion event fires. Since **v3.7.5** it
also emits a script that empties the field in the browser, because autofill
was sending real people to spam — Chrome ignores `autocomplete="off"` for
profile fill and classifies a meaningless field by its POSITION in the form.
Themes need no change, but **print it after the real fields**, just before
the submit button, not as the form's first input. `form_captcha()` adds
Cloudflare Turnstile and turns on purely by the presence of
`TURNSTILE_SITE_KEY` + `TURNSTILE_SECRET_KEY` in `.env` (same pattern as the
store and `STRIPE_SECRET_KEY`); with no keys it returns `''`, so print it
unconditionally. No theme JS needed — the widget injects the token itself, so
plain POST and `fetch()`+`FormData` both work. Widget mode is set in the
Cloudflare dashboard; the domain does NOT need Cloudflare DNS.

Turnstile and not reCAPTCHA because reCAPTCHA sends data to Google under its
own purposes, making every form an LGPD consent question — and a captcha
gated behind a cookie banner protects nothing. Two deliberate behaviours: a
rejected captcha is an **honest error** (unlike the honeypot's lie, since
real humans fail sometimes), and verification **fails OPEN** when Cloudflare
is unreachable — the honeypot still runs, and losing real leads to someone
else's outage costs more than a few minutes of spam.

## Site members

End-user accounts for the public site — separate from admin `users` (own
tables, auth, sessions, reset tokens). No predefined roles; each site
defines its own `types`, and the theme decides what each can access.

```json
"members": {
  "enabled": true,
  "types": {"lead": {"label": "Lead", "fields": [{"name": "company", "type": "text"}]}},
  "routes": {"login": "/entrar"}
}
```

- `enabled: false` (or omitted) hides the feature entirely.
- `public_registration: false` (default) — only admins create accounts.
- `types` optional (omit for one flat member list); top-level `fields`
  apply to all members, each type can add more.
- `routes` overrides the default `/member/*` paths.

Theme builds its own login/register/password-reset forms against the POST
endpoints Velk exposes (every POST needs `csrf_field()`):

```php
member_enabled()               // is the feature on?
member_check()                 // logged in?
member()                       // Member|null
member_field('phone')          // current member's custom field
member_is('client')            // type check
member_route('login')          // resolves to /entrar (or the default)
member_require()               // gate the page; redirects to login
member_require_type('client')  // gate by type; redirects to /
member_status()                // read-and-clear last flash message
```

"Membros" appears in the admin sidebar when enabled — members are content
to manage, not admin-panel users. Kept separate from `users` so a problem
in one realm can't reach the other.

### Stripe setup (subscriptions and store)

Two integrations, one secret key, **two webhook endpoints with two signing
secrets** — and a feature only turns on when its own webhook secret is set:

| Feature | Declared by | Endpoint | Secret |
|---|---|---|---|
| Subscriptions | `members.plans` | `POST /member/stripe-webhook` | `STRIPE_WEBHOOK_SECRET` |
| Store | `item_types.<t>.sellable: true` | `POST /store/stripe-webhook` | `STRIPE_STORE_WEBHOOK_SECRET` |

With `STRIPE_SECRET_KEY` alone, checkout would charge and nothing would be
delivered; the engine treats that as *off*, and `schema:validate` names the
missing secret. Prices, the active flag and the currency live in the panel
(`/admin/options/subscriptions`), not in `site.json`. One active subscription
per member by default — `members.multiple_plans: true` allows several, one per
plan (`already_subscribed` otherwise; `member_can_subscribe($key)` hides the
button before the click). Keep plan switching off in the Customer Portal when
`multiple_plans` is on — a switch there is the same-plan-twice the guard cannot
see; the webhook only logs it. `item_types.<t>.repeat_purchase: false` stops a
logged-in member from buying the same item twice (`already_purchased`;
`item_purchasable($item)` for the button). The success page grants nothing — the
webhook does, usually a few seconds later, so don't render "not subscribed"
there. Full detail and the event list: AGENTS.md → "Subscriptions and the store
— setting Stripe up".
