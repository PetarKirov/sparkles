---
status: accepted
owner: sparkles:docs
reviewed: 2026-08-21
---

# `sparkles:docs` — Feature Specification

## Abstract

`sparkles:docs` is the D library that builds the static pages of the Sparkles
documentation site that a Markdown site generator cannot: highlighted source
listings, optionally annotated with compiler-verified types, and the API
reference of D packages. Each page sits in a shell that matches the rest of
the site, with its navigation, sidebar, breadcrumbs, and light and dark
appearance, and each directory gets an index page. The library decides which
repository files deserve a page by following the links the documentation's
Markdown actually makes, and it defines the data formats of the site's sidebar
and glossary. Its output is plain static files that the site serves as they
are.

## Introduction

The Sparkles documentation is mostly prose, written in Markdown and built into
a website by [VitePress](https://vitepress.dev/). Much of that prose points at
code: source files in the repository, samples whose types the D compiler
explains, and the public API of each D package. A JavaScript site generator is
the wrong place to highlight D, to ask the D compiler about a sample, or to
render hundreds of source files on every build. Those pages are better produced
by D programs that already have the highlighter and the compiler front end, and
written out as static HTML that the site only has to serve. Several programs
need the ability: the `gallery` and `site` commands of the hue code viewer
render pages, the repository's `ci` tool validates the site's data files, and
the API reference generator specified here renders symbol pages.

Pages built outside the site's own build must still read as one site. They need
the same chrome, theme and sidebar, and every link between the two halves must
resolve. When two builds each decide which files get pages, which routes exist,
or what the sidebar holds, any rule that lives in both copies eventually
drifts. Rendering adds a second tension. The `sparkles:ui` toolkit lays out in
whole [cells](../../glossary.md#cell), so its HTML output looks like a
terminal, while documentation needs proportional prose that the browser wraps.

The library is therefore the single D-side owner of everything a generated page
shares with the site. Small, pure builders render each document into a page
shell modeled on the site's theme, and a mirrored tree turns repository paths
into routes with an index page per directory. The site's data files have their
schemas here, so the site build, the generators and `ci` read one definition.
Which files get pages is decided once, by
[link-driven discovery](../../glossary.md#link-driven-discovery). The library
records that decision in a manifest listing every page and every file skipped
on purpose, and the site build reads the manifest instead of deciding again.
Prose always renders through a semantic Markdown-to-HTML emitter that leaves
text measurement to the browser. Page chrome, the navigation, sidebar and
breadcrumbs around the prose, is built as plain HTML until a
[flow mode](../../glossary.md#flow-mode) of `sparkles:ui` lets a widget subtree
emit no cell geometry; through that mode the chrome becomes toolkit widgets one
component at a time.

This specification covers the library with its page builders and data
schemas, the discovery and manifest that hue's `site` command drives, the API
reference generator built on [`sparkles:dmd-lsp`](../dmd-lsp/index.md), and the
conditions under which doc components migrate onto `sparkles:ui`. The VitePress site itself, with its
configuration, theme and Markdown pages, is out of scope: the library matches
its look and feeds it data but does not replace it. The flow-mode emitter's own
requirements belong to the toolkit's [backends page](../ui/backends.md), and
hue's interactive gallery navigation stays in [hue's gallery
spec](../hue/gallery.md). Highlighting belongs to `sparkles:syntax`, type
overlays to `sparkles:twoslash`, D semantic analysis to `sparkles:dmd-lsp`,
and gitignore-aware directory walking to `sparkles:build-primitives`.

[Design & rationale](#design-rationale) records the three findings the design
rests on, including why many requirements here take over hue's `GAL*` and
`HTM*` rows by citing them rather than renumbering them, so those IDs stay
valid wherever they appear. Each sibling page holds one requirement family:
[the static-site surface](./site.md) (`DOC*`), [site discovery](./discovery.md)
(`DSC*`), [the API doc generator](./apidoc.md) (`APD*`),
[flow-mode components](./components.md) (`FLW*`) and [the glossary's data
format](./glossary.md) (`GLS*`). The status legend and
traceability scheme are those of the [hue overview](../hue/index.md), and
[Milestones](#milestones) tracks delivery.

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
| [Glossary](./glossary.md)        | `GLS*` — the glossary's data format: the entry schema, ids and owners, how a page links a term, the rules `ci --check-glossary` enforces, and the glossary page, term lists and hover cards                  |

## Related specs

| Spec                                                          | Relation                                                                                                                                          |
| ------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| [hue/gallery.md](../hue/gallery.md)                           | `GAL*` — the shipped gallery requirements this spec absorbs by reference; hue's interactive half (`GAL5`, `GNV*`) stays hue's                     |
| [hue/feature-requirements.md](../hue/feature-requirements.md) | `HTM*`, `SRC*`, `CLI*` — the HTML sink, document acquisition and CLI rows the library implements                                                  |
| [hue/web-integration.md](../hue/web-integration.md)           | `PKG*`/`SHL*`/`FWK*` — the npm-package / shell-out integration surface; [discovery.md](./discovery.md) `DSC*` supersedes its site-generation half |
| [ui/backends.md](../ui/backends.md)                           | `TGT4`/`TGT9`, milestone `B2` — the HTML target the flow-mode emitter ([components.md](./components.md)) extends                                  |
| [dmd-lsp/ddoc.md](../dmd-lsp/ddoc.md)                         | the DDoc → CommonMark engine the API doc generator's prose pipeline starts from                                                                   |

## Milestones

| M   | Content                                                                                                                          | Depends         | Status                            |
| --- | -------------------------------------------------------------------------------------------------------------------------------- | --------------- | --------------------------------- |
| D0  | Extraction: `sparkles:docs` exists, `hue gallery` output byte-identical, sidebar schema shared with ci                           | —               | **done** (PR #360)                |
| D1  | Spec landed; sidebar rendered on generated pages (`DOC8`); escaping unification (`DOC10`)                                        | `DOC*`          | **done** (`36e7225b`, `100a10b1`) |
| D2  | `hue site`: discovery + `manifest.json` + link rewriting; UAT follow-up: explorer shell (`DOC11`), sidebar augmentation (`DSC7`) | `DSC*`          | **done** (`DSC5` open)            |
| D3  | apidoc core: dmd-lsp semantic walk → symbol model; doc-coverage fixtures + goldens; route-collision cascade                      | `APD1`–`APD5`   | not started                       |
| D4  | apidoc pages: the DDoc prose pipeline inside the site shell — per-symbol pages                                                   | D2, D3          | not started                       |
| D5  | Search index + type graph                                                                                                        | D4              | not started                       |
| D6  | Flow-mode adoption: doc components as `sparkles:ui` views                                                                        | `FLW*`, ui `B2` | not started                       |
