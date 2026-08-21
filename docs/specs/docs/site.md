# `sparkles:docs` SSG surface — Feature Requirements

_**Status:** shipped (extraction) + two open rows · **Date:** 2026-08-21 ·
**Scope:** the library surface extracted from hue's gallery — one module per
concern under `libs/docs/src/sparkles/docs/`._

> [!NOTE]
> Most rows here **absorb by reference**: the normative text lives in the
> shipped [`gallery.md`](../hue/gallery.md) / [hue
> feature-requirements](../hue/feature-requirements.md) rows each cites, and
> this table records which `sparkles:docs` module owns it now. New normative
> content appears only in `DOC8` and `DOC10`.

## Design & rationale

The extraction (milestone D0) moved code, not behavior: `hue gallery` output is
byte-identical before and after, which is the property that let the move happen
as one reviewable refactor. What the library adds over the app-internal version
is _shareability_ — `ci` reads the sidebar schema from it, hue renders with it,
and the [discovery](./discovery.md) and [apidoc](./apidoc.md) efforts build on
it — plus a real package, which finally gives the shared helpers (`escapeInto`,
the options vocabulary) a home that isn't "public because root-level modules
have no `package` visibility".

The module split follows the import graph: `options` at the bottom (plain data

- pure builders), `fragment`/`breadcrumbs`/`site_tree` above it, `page_shell`
  on top, `source_set` and `sidebar` beside them, `assets` for the stylesheet
  files.

## SSG surface (`DOC`)

| ID    | Requirement                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     | Status                             | Traces to                                                                                            |
| ----- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------- | ---------------------------------------------------------------------------------------------------- |
| DOC1  | **Content fragments.** One document renders to a `<style>` + `<pre class="syn-root"><code>` fragment (plain or twoslash), with the physical-line gutter available fragment-side for shell-less pages. Owns [`HTM1`](../hue/feature-requirements.md)'s fragment half, [`HTM4`](../hue/feature-requirements.md), [`GAL4`](../hue/gallery.md).                                                                                                                                                                                                                                     | full                               | `fragment.plainFragment`/`twoslashFragment`/`relayoutGutter`/`withLineNumbers`                       |
| DOC2  | **Page shell.** The full page around a fragment: nav header (prev/next disabled-not-omitted, index link), one scroll container, selection domains. Owns [`GAL3`](../hue/gallery.md), [`GAL6`](../hue/gallery.md), [`GAL7`](../hue/gallery.md), [`HTM7`](../hue/feature-requirements.md), [`HTM8`](../hue/feature-requirements.md).                                                                                                                                                                                                                                              | full                               | `page_shell.pageShell`                                                                               |
| DOC3  | **Dual themes + appearance toggle.** Light and dark from one rendering, the toggle writing VitePress's own `localStorage['vitepress-theme-appearance']` key, a no-flash `<head>` script, everything gated on a two-theme run. Owns [`HTM10`](../hue/feature-requirements.md).                                                                                                                                                                                                                                                                                                   | full                               | `page_shell.pageShell` (toggle + script); `assets.themeStylesheet`                                   |
| DOC4  | **Chrome palette.** The whole surround (page, header, rule, nav, gutter) derives from the rendering theme's default bg/fg — `themeChrome` — so pane and chrome are one surface by construction; the palette is a _parameter_ (`GalleryOptions.chrome`), so a site can substitute its own (`--chrome=site`, [`DSC5`](./discovery.md)). Owns [`GAL6`](../hue/gallery.md)'s theme-sourcing half.                                                                                                                                                                                   | full                               | `options.ChromePalette`/`themeChrome`/`themeBackground`                                              |
| DOC5  | **Mirrored site tree.** A recursive set renders `<out>/<rel-path>.html` plus an `index.html` in every directory, page-relative hrefs throughout, depth-rebased asset hrefs; a flat set keeps the flat layout byte for byte. Owns [`GAL12`](../hue/gallery.md), [`HTM6`](../hue/feature-requirements.md)'s mirrored half.                                                                                                                                                                                                                                                        | full                               | `site_tree.buildSiteTree`/`directoryIndex`; `page_shell.writeGallery`/`pageHref`/`depthAdjustedHref` |
| DOC6  | **Breadcrumbs.** Per-segment directory-index links that work from `file://`, copy-path controls, forge links under `--repo-url`/`--repo-prefix`, VitePress `Breadcrumbs.vue` markup/class parity. Owns [`GAL14`](../hue/gallery.md).                                                                                                                                                                                                                                                                                                                                            | full                               | `breadcrumbs.breadcrumbsFor`/`renderBreadcrumbs`/`breadcrumbCss`                                     |
| DOC7  | **Stylesheet assets.** A page set leaves theme rules to one shared stylesheet — self-hosted `assets/hue.css`, `--stylesheet` link, `--emit-stylesheet` write — carrying both theme scopes and the chrome/twoslash/markdown blocks. Owns [`GAL11`](../hue/gallery.md), [`HTM1`](../hue/feature-requirements.md)'s shared-sheet half.                                                                                                                                                                                                                                             | full                               | `assets.themeStylesheet`/`writeStylesheetAsset`/`writeStylesheetFile`                                |
| DOC8  | **Sidebar.** The docs-site sidebar/`srcExclude` data (`docs/.vitepress/sidebar.json`, `docs-config.json`) has one D schema, in this library, consumed by the site config, by `ci --check-docs-sidebar` / `--audit-fences`, **and by generated pages**: a listing page must be able to render the same sidebar tree the docs site shows, its links resolved against the site base URL, so a reader crossing between a VitePress page and a listing keeps the same navigation. Rendering requires the site base URL, so it ships with `--chrome=site` ([`DSC5`](./discovery.md)). | schema full; rendering not started | `sidebar.SidebarItem`/`loadSidebar`/`loadDocsConfig`/`sidebarLinks`                                  |
| DOC9  | **Document set.** The ordered, filtered, summarized file list every mode consumes, with the recursive `.gitignore`-aware descent delegated to `sparkles:build-primitives`' glob walk. Owns [`GAL1`](../hue/gallery.md)/[`GAL8`](../hue/gallery.md) and the library half of [`SRC5`/`SRC6`/`SRC9`](../hue/feature-requirements.md).                                                                                                                                                                                                                                              | full                               | `source_set.SourceSet`/`collectSources`/`isRenderable`; `sparkles.build_primitives.glob_walk`        |
| DOC10 | **Escaping unification.** `options.escapeInto` (4 entities) must fold into `sparkles.base.text.html.writeHtmlEscaped` (5 entities — it also escapes `'`), so the repository has one HTML-escaping implementation. This is a **deliberate byte change** for any name/summary containing an apostrophe: it lands with a golden update, after the D0 byte-identity guarantee has served its purpose — never silently.                                                                                                                                                              | not started (D1)                   | `options.escapeInto`; `sparkles.base.text.html.writeHtmlEscaped`                                     |

## Non-goals

- **Interactive navigation** (`GAL5`, `GNV*`) stays hue's: the library renders
  static pages; sessions are the app's concern.
- **Serving.** The library writes files. Dev servers, deployment, and CI wiring
  are the consumer's ([discovery.md](./discovery.md) `DSC4` and the docs-site
  build scripts).
