# D API doc generator — on `sparkles:dmd-lsp`

_**Status:** design (D3–D5) · **Date:** 2026-08-21 · **Scope:** generating an
API reference for D packages — symbols, signatures, DDoc prose, examples,
search, type relationships — as pages of the `sparkles:docs` site._

## Design & rationale

This resurrects the `apps/sparkle-docs` effort (branch
`sparkles-docs-api-reference-v2`, tip
[`f3f2477d`](https://github.com/PetarKirov/sparkles/tree/f3f2477d9fd395a1968cf8df96551651f03039f2)),
which ran end to end — 20 modules, 266 symbols, 273 routes of `libs/core-cli`
rendered and deployed — and then stopped exactly where its parser ran out:
`dmd -X` JSON has no UDAs, no `static if` branches, thin template info, and the
effort's DDoc handling was ~90 lines (first paragraph = summary; no macros, no
sections). What is **kept** from it and what is **replaced**:

| Kept (architecture)                                                                                                                                                                           | Replaced (mechanism)                                                                                                 |
| --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| The symbol model — `Symbol`/`Parameter`/`TemplateParam`/`ParamDoc`, `SymbolKind`/`Protection` enums (designed for what a doc site _needs_, which is why the old parser left half of it empty) | `dmd -X` subprocess per file + the `/src/` import-path heuristic → `sparkles:dmd-lsp`'s in-process semantic analysis |
| The two-stage contract: generator → JSON (nested index / flat search / type graph) → renderer                                                                                                 | The mcl-copy JSON serde → `sparkles:wired`                                                                           |
| Route-collision resolution (D is case-sensitive; `cliOption` vs `CliOption` is real)                                                                                                          | ~90-line DDoc scrape → DMD's own DDoc engine via [dmd-lsp/ddoc.md](../dmd-lsp/ddoc.md)                               |
| The doc-coverage fixture package + golden files                                                                                                                                               | Raw `<pre>` example rendering → `sparkles:syntax` highlighting / twoslash                                            |
| The unittest-example attachment _policy_ (attach to the preceding documented symbol)                                                                                                          | Brace-counting source extraction → AST spans from the frontend                                                       |
| VitePress Vue components as _a_ renderer                                                                                                                                                      | JSON-fed Vue as _the_ renderer → `sparkles:docs` pages ([components.md](./components.md) for the widget path)        |

The prose pipeline needs no new engine — every stage is shipped:
`renderDdoc(sym)` → `DdocRendered{docs: CommonMark, tags}` →
`extractMarkdown` → `MdDoc` → `renderMarkdownHtml` (proportional HTML, with the
fence hook for highlighted code), or `viewMarkdownInto` for the widget targets.

## API doc generator (`APD`)

| ID   | Requirement                                                                                                                                                                                                                                                                                                                                                                                                                                          | Status      | Traces to                                                                    |
| ---- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | ---------------------------------------------------------------------------- |
| APD1 | **Symbol model.** A backend-neutral model of documented D symbols: qualified name, kind, protection, attributes, signature parts (parameters with storage classes/defaults, template params, constraints, return type), source location, DDoc-derived fields (summary/description as CommonMark, param docs, returns/throws/see-also/deprecated), members, and cross-references. Schema lifted from the old `model/symbol.d`, now fully populatable. | not started | proposed `sparkles.docs.apidoc.model`                                        |
| APD2 | **Semantic extraction.** The model is populated by a `sparkles:dmd-lsp` walk — one in-process analysis per module set, real resolved types, UDAs, attributes, template constraints — never by scraping compiler JSON or source text. Signature text comes from the frontend's own printing (`dmd_lsp.signature`), not string surgery.                                                                                                                | not started | proposed extractor over `sparkles:dmd-lsp`                                   |
| APD3 | **DDoc prose pipeline.** Symbol prose renders through `renderDdoc` → CommonMark → `extractMarkdown` → `renderMarkdownHtml`, so macros (`$(REF …)`, `$(LREF …)`, dlang.org vocabulary), sections (`Params:`/`Returns:`/`Throws:`/`See_Also:`/`Deprecated:`), tables and embedded markdown all render — the exact gap that stalled the old effort.                                                                                                     | not started | `sparkles.dmd_lsp.ddoc.renderDdoc`; `sparkles.syntax` markdown model/emitter |
| APD4 | **Fixtures + goldens.** The doc-coverage fixture package (nine modules deliberately covering enums, aliases, interfaces, dtors/postblits, invariants, templates, private symbols, and a deliberately broken module for fail-fast) is ported, and generator output is pinned by golden files — the harness that catches a regression in any of APD1–APD3.                                                                                             | not started | port of `apps/doc-coverage-fixture` + `test/data/doc_coverage/golden`        |
| APD5 | **Routes + collisions.** One page per symbol at a stable route derived from the qualified name; case-insensitive route collisions (filesystems, hosting) resolve deterministically — base → `--{kind}` → `--{kind}-{hash}` → counter — with prefix-conflict detection, per the old `generate-api-pages.mjs` cascade.                                                                                                                                 | not started | route builder in the generator                                               |
| APD6 | **Symbol pages in the site shell.** Symbol pages are `sparkles:docs` pages: the `DOC2`–`DOC7` shell (chrome, themes, breadcrumbs over the module path, sidebar), prose per APD3, signatures highlighted by `sparkles:syntax`, documented unittests attached to their preceding documented symbol (AST spans) and rendered as highlighted — optionally twoslash — examples.                                                                           | not started | `sparkles.docs.page_shell` + the generator                                   |
| APD7 | **Search index.** A flat index (qualified name, simple name, kind, summary, route) emitted beside the pages for client-side search; scoring/tokenization is the consumer's concern, the index's stability is the generator's.                                                                                                                                                                                                                        | not started | index emitter                                                                |
| APD8 | **Type graph.** Nodes + typed edges (`extends`, `implements`, `aliases`, `has-part`) over the extracted symbols, deduplicated, unresolved targets marked — the data behind hierarchy diagrams (mermaid or a widget view).                                                                                                                                                                                                                            | not started | graph emitter                                                                |
| APD9 | **Cross-reference linking.** A type or symbol mention links to its page when resolvable — semantically via dmd-lsp where possible, with the old effort's fallback policy for plain text: exact route hit → module-relative → _globally unambiguous_ simple name, never a guess.                                                                                                                                                                      | not started | linkifier in the page renderer                                               |

## Non-goals (v1)

- **Runnable examples** (the old `ExampleRunner.vue` / run.dlang.io idea) — a
  renderer concern, out of scope until the pages exist.
- **Multi-version docs** — one tree per build; versioning is deployment's
  problem.
- **dpldocs/adrdox compatibility** — the output is this site's pages, not a
  general doc-hosting format.
