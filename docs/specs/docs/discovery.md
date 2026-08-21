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
**data in one place** (`docs/hue-site.json`), and `manifest.json` becomes the
single source of truth the JS side reads instead of re-deciding.

## Site discovery (`DSC`)

| ID   | Requirement                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      | Status                                                                              | Traces to                                                                                                                                                             |
| ---- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| DSC1 | **Link-driven discovery.** `hue site` must derive the page set from the docs' markdown: scan `docs/**/*.md` (honoring `srcExclude` via the [sidebar schema](./site.md), `DOC8`) for links to repository files, expand a linked _directory_ to its renderable subtree, and apply the knobs from `docs/hue-site.json` — `extensions`, `maxFileSize`, `excludeDirs`/`excludeGlobs`, `linkRoots`. The descent and filtering reuse the document set (`DOC9`), so `.gitignore` and the glob precedence come from `sparkles:build-primitives`, not a skip-list.                                                                         | full (`525ffd23`)                                                                   | `site.discoverSite` over `sparkles.docs.source_set`/`glob_walk`                                                                                                       |
| DSC2 | **The manifest.** The run must emit `manifest.json` beside the pages: `files` (repo-relative path → site route), `dirs` (directory → its index route), and `skipped` (path + machine-readable reason: `size` / `ext` / `excluded`), so consumers can distinguish "no page" from "excluded on purpose". The manifest is the _only_ interface the VitePress side reads.                                                                                                                                                                                                                                                            | full (`84339000`)                                                                   | `sparkles.docs.site.manifestJson`; `app.executeSite`                                                                                                                  |
| DSC3 | **Route model.** Listing routes are `/src/<repo-relative-path>.html`, directory indexes `/src/<dir>/index.html`. The `/src/` prefix namespaces the listings (one `ignoreDeadLinks` regex, no collision with existing routes); the explicit `.html` sidesteps trailing-slash differences between Vite dev, `vitepress preview`, and static hosting.                                                                                                                                                                                                                                                                               | full (`84339000`)                                                                   | `sparkles.docs.site.listingRoute`/`directoryRoute`/`siteRoutePrefix`                                                                                                  |
| DSC4 | **Manifest-driven link rewriting.** The docs site rewrites a prose link to a listing **iff** the manifest maps it: `config.mts` reads `manifest.json` once at config eval and rewrites href → `files[p] ?? dirs[p] ?? null`; an absent manifest rewrites nothing and the build stays green. The on-disk existence of every emitted `/src/…` href is asserted by a build check — the manifest, not `ignoreDeadLinks`, is the guard.                                                                                                                                                                                               | full — existence holds by construction: the manifest lists only pages the run wrote | `docs/.vitepress/config.mts` (`rewrite-source-links`); `docs/scripts/build-source-listings.sh`                                                                        |
| DSC5 | **Site options.** The `SiteOptions` successor to `GalleryOptions` gains the whole-site knobs: the site base URL (which unlocks sidebar rendering, `DOC8`, and absolute forge links), the site chrome palette (`--chrome=site` supplying VitePress's `--vp-c-*`-derived values through the `DOC4` parameter), and the title/nav copy. When it lands, `sparkles.docs.options` renames the alias as its doc comment already records.                                                                                                                                                                                                | not started                                                                         | `options.SiteOptions`                                                                                                                                                 |
| DSC6 | **Twoslash on for D listings.** The site build runs the batch twoslash extraction ([`GAL13`](../hue/gallery.md)) for `.d` listings by default — measured at ~0.24 s/file parallel, ~90 s for the repo's 365 D files — with no allow-list. Caveat, recorded not hidden: twoslash payloads are **not byte-reproducible** (hover text on template instances depends on DMD instance-cache order, upstream in `sparkles:dmd-lsp`); either that is fixed upstream or the listing pages are accepted as non-reproducible.                                                                                                              | full (`525ffd23`)                                                                   | `app.executeSite` (extraction over the `.d` subset; a failure degrades to a plain listing)                                                                            |
| DSC7 | **Docs-sidebar augmentation.** A listing directory under `docs/` joins the VitePress sidebar group that owns that part of the docs tree — ownership by _direct_ links, so `docs/research/async-io/io-uring/examples` appears as `examples/ (source)` under "io_uring Reference", not under the top-level "Research" — immediate children only (deeper trees are reached through the listing's explorer, `DOC11`), root-owned dirs skipped as noise. Runtime augmentation at config eval, **never an edit to `sidebar.json`**: the data file stays the source of truth for pages and `ci --check-docs-sidebar` keeps checking it. | full                                                                                | `sparkles.docs.site.augmentWithListingDirs` (the listing pages' nested nav) + `docs/.vitepress/config.mts` `augmentSidebar` (the site) — one algorithm, both surfaces |

## Milestone D2 — verified

The 790-route superset criterion could not be checked literally — the parked
loader ran against a months-older tree (the OS-API research alone has added
hundreds of files since) — so the verification is against $(I today's) link
graph:

- `hue site` over this repository: **589 pages + 252 directory indexes** in
  2.4 s (plain) / one extraction pass over **347 `.d` files** (twoslash), with
  **27 skips**, each carrying its reason — including exactly the two files the
  parked loader's policy holes shipped (the 478 KB grounding `.txt` → `size`,
  the `.html.gz` → `ext`). Two deliberate set differences from the parked
  loader: `srcExclude`d pages' links no longer count, and the size/extension
  policy applies to directly-linked files (skipped, never silently published).
- `vitepress build docs` with the listings prebuilt: **121 s** at the 8 GiB
  heap `docs.yml` already exports, and VitePress builds no listing routes. A
  control build $(I without) listings and without the manifest OOMs at stock
  heap in exactly the same way ("Ineffective mark-compacts near heap limit")
  — the heap requirement is the site's own growth, pre-existing and unrelated
  to the listings. The old plan's V5 ("drop the `docs.yml` heap override,
  measure first") now has its measurement: the override is load-bearing.
- Every `/src/…` href in `dist` resolves to a file under `docs/public/src` —
  checked over the built dist, and guaranteed by construction thereafter (the
  rewrite consults the manifest, and the manifest lists only written pages).
