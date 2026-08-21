# `hue site` — link-driven discovery & the site manifest

_**Status:** design (D2) · **Date:** 2026-08-21 · **Scope:** the subcommand
that turns the docs' markdown link graph into a set of source-listing pages,
and `manifest.json` — the contract between that D-side build step and the
VitePress site._

## Design & rationale

The docs site links source files from prose. The parked VitePress
implementation (branch `parked/vitepress-source-listings`) proved the shape —
a **link-driven** scan, not a blanket repository walk: only files the docs
actually reference (plus recursive expansion of referenced directories) get
pages, which kept the set at 790 pages instead of every file in the tree. It
also proved the costs: +222 % docs-build time and an 8 GiB Node OOM, which is
why the pages move to hue-rendered static HTML under `docs/public/` and
VitePress never SSRs them.

Porting the discovery into D (per the repo's D-over-scripting rule) also kills
a real defect class: the extension allow-list and size cap were duplicated
between the paths loader and the link rewriter and had already drifted (a
478 KB grounding `.txt` and an `.html.gz` slipped through). Here they become
**data in one place** (`docs/hue-site.toml`), and `manifest.json` becomes the
single source of truth the JS side reads instead of re-deciding.

## Site discovery (`DSC`)

| ID   | Requirement                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              | Status      | Traces to                                                      |
| ---- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | -------------------------------------------------------------- |
| DSC1 | **Link-driven discovery.** `hue site` must derive the page set from the docs' markdown: scan `docs/**/*.md` (honoring `srcExclude` via the [sidebar schema](./site.md), `DOC8`) for links to repository files, expand a linked _directory_ to its renderable subtree, and apply the knobs from `docs/hue-site.toml` — `extensions`, `maxFileSize`, `excludeDirs`/`excludeGlobs`, `linkRoots`. The descent and filtering reuse the document set (`DOC9`), so `.gitignore` and the glob precedence come from `sparkles:build-primitives`, not a skip-list. | not started | proposed `apps/hue/src/site.d` over `sparkles.docs.source_set` |
| DSC2 | **The manifest.** The run must emit `manifest.json` beside the pages: `files` (repo-relative path → site route), `dirs` (directory → its index route), and `skipped` (path + machine-readable reason: `size` / `ext` / `excluded`), so consumers can distinguish "no page" from "excluded on purpose". The manifest is the _only_ interface the VitePress side reads.                                                                                                                                                                                    | not started | proposed `sparkles.docs.site` manifest writer                  |
| DSC3 | **Route model.** Listing routes are `/src/<repo-relative-path>.html`, directory indexes `/src/<dir>/index.html`. The `/src/` prefix namespaces the listings (one `ignoreDeadLinks` regex, no collision with existing routes); the explicit `.html` sidesteps trailing-slash differences between Vite dev, `vitepress preview`, and static hosting.                                                                                                                                                                                                       | not started | route computation in the manifest writer                       |
| DSC4 | **Manifest-driven link rewriting.** The docs site rewrites a prose link to a listing **iff** the manifest maps it: `config.mts` reads `manifest.json` once at config eval and rewrites href → `files[p] ?? dirs[p] ?? null`; an absent manifest rewrites nothing and the build stays green. The on-disk existence of every emitted `/src/…` href is asserted by a build check — the manifest, not `ignoreDeadLinks`, is the guard.                                                                                                                       | not started | `docs/.vitepress/config.mts`; a verify script over `dist`      |
| DSC5 | **Site options.** The `SiteOptions` successor to `GalleryOptions` gains the whole-site knobs: the site base URL (which unlocks sidebar rendering, `DOC8`, and absolute forge links), the site chrome palette (`--chrome=site` supplying VitePress's `--vp-c-*`-derived values through the `DOC4` parameter), and the title/nav copy. When it lands, `sparkles.docs.options` renames the alias as its doc comment already records.                                                                                                                        | not started | `options.SiteOptions`                                          |
| DSC6 | **Twoslash on for D listings.** The site build runs the batch twoslash extraction ([`GAL13`](../hue/gallery.md)) for `.d` listings by default — measured at ~0.24 s/file parallel, ~90 s for the repo's 365 D files — with no allow-list. Caveat, recorded not hidden: twoslash payloads are **not byte-reproducible** (hover text on template instances depends on DMD instance-cache order, upstream in `sparkles:dmd-lsp`); either that is fixed upstream or the listing pages are accepted as non-reproducible.                                      | not started | `hue gallery --twoslash --jobs` (shipped); site wiring open    |

## Milestone D2 exit criteria

- `hue site` emits a page set ⊇ the 790 routes the parked loader produced, with
  every removal traceable to a `skipped` reason in the manifest.
- `npm run docs:build` with listings prebuilt stays at the no-listings
  baseline (~110–130 s, < 4 GiB), because VitePress builds no listing routes.
- Every `/src/…` href in `dist` resolves to a file under `docs/public/src`.
