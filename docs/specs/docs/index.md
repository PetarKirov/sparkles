# `sparkles:docs` — Feature Specification

_**Status:** living inventory · **Date:** 2026-08-21 · **Scope:** `libs/docs`
(`sparkles:docs`) — the markdown-based SSG-style documentation-site library —
plus the hue subcommands that drive it (`hue gallery` today; `hue site` and the
API doc generator to come)._

`sparkles:docs` is the repository's static documentation-site library: the
content-fragment builders, the VitePress-lookalike page shell (theme-derived
chrome, appearance toggle, breadcrumbs), the mirrored site tree with
per-directory indexes, the shared stylesheet assets, the document set, and the
docs-site sidebar data schema. It was extracted from hue's gallery — the code
shipped first, inside `apps/hue`, and moved to `libs/docs` byte-identically once
the roadmap made it a library three consumers want (`hue gallery`, the planned
`hue site`, and the API doc generator).

This spec is the requirement of record for the library and for the two efforts
that build on it. ID families, one per page: `DOC*` (the SSG surface), `DSC*`
(site discovery), `APD*` (the API doc generator), `FLW*` (flow-mode
`sparkles:ui` components). Status legend and traceability scheme: see the
[hue overview](../hue/index.md).

## Design & rationale

Three findings shaped this spec:

- **The SSG surface already exists — it was hue's gallery.** Everything a
  documentation site's _listing_ pages need (shell, chrome, breadcrumbs, dual
  themes, mirrored tree, shared stylesheet) shipped under
  [`gallery.md`](../hue/gallery.md) `GAL*` and
  [`feature-requirements.md`](../hue/feature-requirements.md) `HTM*`. This spec
  therefore **absorbs those requirements by reference, not renumbering**: a
  `DOC*` row cites the `GAL*`/`HTM*` rows it takes ownership of, and those IDs
  remain valid citations everywhere they appear.
- **The API doc generator is a resurrection, not a green field.** Branch
  `sparkles-docs-api-reference-v2`
  ([tip `f3f2477d`](https://github.com/PetarKirov/sparkles/tree/f3f2477d9fd395a1968cf8df96551651f03039f2))
  built a working two-stage generator (`apps/sparkle-docs`: D → JSON →
  VitePress/Vue) whose architecture — per-symbol routes, a flat search index, a
  type graph, route-collision resolution, a doc-coverage fixture package with
  golden files — survives intact. Its weak half, a `dmd -X` scraper with ~90
  lines of DDoc handling, is superseded wholesale by `sparkles:dmd-lsp`'s
  in-process semantic analysis and its DDoc → CommonMark engine
  ([dmd-lsp/ddoc.md](../dmd-lsp/ddoc.md)). The prose pipeline
  `renderDdoc → extractMarkdown → MdDoc → renderMarkdownHtml` exists end to end
  today; only the chrome around it is unbuilt.
- **Widget components and flowing prose are in tension — resolved as a
  hybrid.** `sparkles:ui`'s layout is integer cells by design
  ([ui/layout.md](../ui/layout.md) `LAY3`), and both HTML interpreters emit
  `ch`/`lh` monospace-grid markup — a _terminal-looking_ page, not proportional
  prose. So: prose renders through the semantic `MdDoc → renderMarkdownHtml`
  emitter (proportional, shipped); page chrome stays semantic HTML for now; and
  a **flow-mode HTML emitter** ([components.md](./components.md) `FLW*`)
  becomes the path by which doc components migrate onto `sparkles:ui` widgets
  without giving up browser-measured text.

## Documentation map

| Page                             | What it covers                                                                                                                                                                                               |
| -------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Overview** (this page)         | what `sparkles:docs` is · how the spec absorbs `GAL*`/`HTM*` · the milestone board                                                                                                                           |
| [SSG surface](./site.md)         | `DOC*` — the extracted library surface: fragments, page shell + appearance toggle, chrome palette, site tree, breadcrumbs, stylesheet assets, sidebar schema, the document set, and the escaping unification |
| [Site discovery](./discovery.md) | `DSC*` — `hue site`: link-driven page discovery from the docs' markdown, `manifest.json` as the contract with the VitePress build, the `/src/…` route model, and site-level twoslash                         |
| [API doc generator](./apidoc.md) | `APD*` — the D API reference generator on `sparkles:dmd-lsp`: the symbol model, the semantic walk, the DDoc prose pipeline, fixtures + goldens, route collisions, symbol pages, search index, type graph     |
| [Components](./components.md)    | `FLW*` — the flow-mode HTML emitter in `sparkles:ui` and the migration of doc-site chrome (nav, sidebar tree, breadcrumbs, toggle) onto widget-defined components                                            |

## Related specs

| Spec                                                          | Relation                                                                                                                                          |
| ------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| [hue/gallery.md](../hue/gallery.md)                           | `GAL*` — the shipped gallery requirements this spec absorbs by reference; hue's interactive half (`GAL5`, `GNV*`) stays hue's                     |
| [hue/feature-requirements.md](../hue/feature-requirements.md) | `HTM*`, `SRC*`, `CLI*` — the HTML sink, document acquisition and CLI rows the library implements                                                  |
| [hue/web-integration.md](../hue/web-integration.md)           | `PKG*`/`SHL*`/`FWK*` — the npm-package / shell-out integration surface; [discovery.md](./discovery.md) `DSC*` supersedes its site-generation half |
| [ui/backends.md](../ui/backends.md)                           | `TGT4`/`TGT9`, milestone `B2` — the HTML target the flow-mode emitter ([components.md](./components.md)) extends                                  |
| [dmd-lsp/ddoc.md](../dmd-lsp/ddoc.md)                         | the DDoc → CommonMark engine the API doc generator's prose pipeline starts from                                                                   |

## Milestones

| M   | Content                                                                                                     | Depends         | Status                            |
| --- | ----------------------------------------------------------------------------------------------------------- | --------------- | --------------------------------- |
| D0  | Extraction: `sparkles:docs` exists, `hue gallery` output byte-identical, sidebar schema shared with ci      | —               | **done** (PR #360)                |
| D1  | Spec landed; sidebar rendered on generated pages (`DOC8`); escaping unification (`DOC10`)                   | `DOC*`          | **done** (`b5ca0f09`, `dcf27941`) |
| D2  | `hue site`: link-driven discovery + `manifest.json`; VitePress link rewriting consumes it                   | `DSC*`          | not started                       |
| D3  | apidoc core: dmd-lsp semantic walk → symbol model; doc-coverage fixtures + goldens; route-collision cascade | `APD1`–`APD5`   | not started                       |
| D4  | apidoc pages: the DDoc prose pipeline inside the site shell — per-symbol pages                              | D2, D3          | not started                       |
| D5  | Search index + type graph                                                                                   | D4              | not started                       |
| D6  | Flow-mode adoption: doc components as `sparkles:ui` views                                                   | `FLW*`, ui `B2` | not started                       |
