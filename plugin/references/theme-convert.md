# Converting static HTML/PHP into a Velk theme

## Scenario

User has a folder of static HTML/PHP — a downloaded template, a static site,
a design mockup — and wants it running as a Velk theme with admin already
populated from what was hardcoded in the source. Trigger phrases: "transforma
esse html em tema velk", "converte essa pasta pra velk", "tenho um site
estático e quero usar no velk cms". Not for: an already-converted theme,
`site.json` edits on an established project, or a bare install with nothing
to convert (`references/install.md`).

## The approach

Read every source file, extract what's shared, propose a schema, get it
approved, THEN generate. Two things set this apart from a normal "wire up a
CMS" job:

- **Plan before code.** The mapping — files → pages, blocks → fields,
  partials, options — is a document the user approves before anything gets
  written. Nothing is generated off an unapproved guess.
- **Seed, don't leave empty.** A theme with empty fields is a worse
  deliverable than the static site it replaced. A one-shot seed script
  copies the hardcoded content into the database, so admin opens already
  populated and the user refines instead of starting cold.
- **Never patch the engine to fit the source.** When the static site does
  something Velk doesn't (an odd URL shape, a layout no field covers), solve it
  in `theme/` — a `flexible` field, a block inside the text (`richtext_blocks`,
  v3.9.0+), a template, `theme/functions.php` — or note it as a request for
  Velk. An edit under `core/`, `config/`, `bin/` or
  `migrations/` vanishes on the next upgrade (SKILL.md).

## Phase 0 — locate self

The source is raw material, never part of the theme: it lives in its own
folder, `_source/` at the project root, and the theme is generated fresh
beside it. Nothing of the source is copied into `theme/` as-is — its root
ends with only `site.json`, `functions.php` and the theme's folders
(`templates/`, `partials/`, assets).

Check for `core/Bootstrap.php` (here or one level up). Found → Velk is
installed; put the source in `_source/` (moving it out of `theme/` if it was
dropped there). Not found → propose moving the source into `_source/` and
installing Velk in the root (`references/install.md`); get an explicit yes
first — destructive if the folder isn't actually a clean source tree.

**Why outside `theme/`:** the original pages (`index.php`, `header.php`,
`produto.php`…) are not templates — Velk never loads them — but anything in
`theme/` ships with every deploy and every publish. Kept there "for
comparison", they become dead code on the client's server that the next
person has to tell apart from the real theme.

## Phase 1 — analyze the source

Classify every file: page candidates (`*.html`/`*.php`), partials already
split out (`header.html`, `footer.php`…), assets (css/js/images/fonts),
junk (`node_modules/`, `.git/`). Then:

- **Partials** — diff markup across pages; near-identical `<header>`/
  `<footer>` blocks become `partials/header.php`/`footer.php`. Trust
  pre-split partials as-is, don't re-extract.
- **Pages vs. item types** — a page is one named destination (`sobre`); an
  item type is a repeatable kind sharing one template (`post`, `case`). A
  `post.html` referenced from a looping `blog.html` is the tell; ask rather
  than guess when it's genuinely ambiguous. Within a page, siblings sharing
  markup (3 testimonial cards, 6 stat blocks) are one repeater field, not N
  hand-copied fields.
- **Global vs. page-specific** — nav links and contact info become
  `option()` groups (`option('nav.links')`); hero copy and body content
  become page-level `field()`s (`hero_title`, `hero_lead`).
- **Content, not just structure** — capture the actual text/image hardcoded
  in every field, repeater row, item, term, and option. This is what the
  seed script needs; skip it here and content silently fails to migrate.

## Phase 2 — the plan

One document: files detected, partials, pages with fields, item types with
fields/taxonomies, options, asset moves, and a preview of what the seed will
populate (sample values, item counts, term lists). Flag ambiguity under
"manual review needed." Show it, generate nothing yet, wait for an explicit
go-ahead — the plan is the contract for both schema and seed content.

## Phase 3 — execute

1. **`theme/site.json`** — pages keyed by slug, `item_types` keyed by
   singular name, `options` for global groups. Bind templates by file name
   (`page-home.php`), never by slug. Skip a hand-rolled SEO field group —
   `Config::seoFields()` already covers paged content.
2. **Partials, templates, assets** — `partials/header.php`/`footer.php`
   pull nav from `option('nav.links', [])` and contact info from
   `option('contato.*')`. Page/item templates (`page-<key>.php`,
   `single-<type>.php`) wire in helpers: `e(field('x'))` plain text,
   `field('x') /* trusted */` richtext, `image_url($value, $size)` +
   `image_alt()` images, `url('/path')` links, all inside
   `with_context($page, function () { ... })`. CSS/JS concatenate into
   `theme/style.css`/`scripts.js`, images move to `theme/images/`.
3. **`theme/install/seed.php`** — one-shot script bootstrapped against
   `core/Bootstrap.php`, writing captured content in order: taxonomy terms
   (items attach to them), items (`'status' => 'published'` explicitly, or
   `items()` lists render empty), options, page fields. Image fields get the
   original relative path as a string, since `image_url()` accepts path
   strings and renders immediately without touching the media library.
   Read `core/Models/Page.php`, `Item.php`, `Term.php`, and grep for
   `Setting` first — don't guess the write API. Guard the top with an
   idempotency check so a re-run can't clobber admin edits.
4. **Validate** — `./bin/velk schema:validate`, `./bin/velk page:sync`, then
   `php theme/install/seed.php`. Stop on any error instead of building more
   on a broken foundation; the guard makes fix-and-rerun safe.

### The seed skeleton

`page:sync` creates the page records but leaves their `fields` empty — the
admin is structurally right and visually blank. The seed closes that gap. The
guard is the load-bearing part: without it, a re-run silently overwrites
whatever the editor has typed since.

```php
<?php
// One-shot seed: content migrated from the original source.
// Safe to re-run — the guard below bails once the seed has been applied.

require __DIR__ . '/../../core/Bootstrap.php';

use Velk\Models\Page;
use Velk\Models\Item;
use Velk\Models\Term;

// --- Idempotency guard ---
// A known field already populated means the seed ran. Bail rather than
// clobber edits made in admin since.
$home = Page::resolveByKey('home');
if ($home && !empty($home->field('hero_title'))) {
    fwrite(STDOUT, "Seed já aplicado (home.hero_title preenchido). Pulando.\n");
    exit(0);
}

// --- Order matters: terms, then items, then options, then page fields ---
$branding = Term::create(['taxonomy' => 'categoria', 'name' => 'Branding', 'slug' => 'branding']);

Item::create([
    'type'   => 'servico',
    'title'  => 'Identidade visual',
    'status' => 'published',   // explicit — items() lists render empty without it
    'fields' => ['resumo' => '...', 'capa' => 'images/capa.jpg'],
]);
```

Terms before items, always — `setTerms()` needs IDs that already exist. Image
fields take the original relative path as a plain string; `image_url()`
accepts path strings and renders immediately, no media-library round trip.

If you can't confidently find the options write API after a few minutes of
reading the models, seed pages/items/terms and tell the user options are
manual. Shipping a seed that silently no-ops is worse than shipping less.

## Phase 4 — report

What got generated, what's pre-populated (page/item/term/option counts),
and what's still manual: `_source/` to delete (or move out of the project)
once the user approves the result — `init.sh` uploads the whole project root
and stops while it is there —, image fields waiting for a real upload through
`/admin/media`, form
recipients to configure, third-party embeds to rewire through `tracking_*`
helpers, SEO fields left empty on purpose.

## Gotchas

- Map by structure, not markup — repeated cards mean an item type, not N
  separately-authored fields; forcing a one-off into a repeater (or the
  reverse) makes the admin harder to use than the source site was.
- Never hardcode a URL or path — `url()`, `asset()`, `image_url()` exist so
  a subdirectory install doesn't break. Terms before items, always —
  `setTerms()` needs IDs that already exist.
- Don't guess the write API — read the actual model files before the seed
  touches the database, and skip seeding options rather than ship a seed
  that silently no-ops.
