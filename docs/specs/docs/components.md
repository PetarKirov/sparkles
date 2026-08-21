# Doc components on `sparkles:ui` — the flow-mode path

_**Status:** design (D6) · **Date:** 2026-08-21 · **Scope:** how doc-site
components (nav, sidebar tree, breadcrumbs, toggle, symbol-page sections)
migrate from hand-built HTML strings onto `sparkles:ui` widget definitions —
and the `sparkles:ui` emitter capability that migration is gated on._

## Design & rationale

`sparkles:ui` is the repository's single UI stack, and doc components _should_
be widget-defined — one `view` rendering on GUI, TUI and HTML, the way
`viewMarkdownInto` and the twoslash views already do. What blocks it today is
measured, not assumed:

- The layout engine is **integer cells** by requirement
  ([ui/layout.md](../ui/layout.md) `LAY3`); the one width authority counts one
  column per codepoint. Proportional text has no integer column count.
- Both HTML interpreters (`interp/html.d`, `interp/html_semantic.d`,
  [ui/backends.md](../ui/backends.md) `TGT4`) emit `ch`/`lh` geometry with
  `white-space:pre` monospace text — deliberately, as the cell-grid parity
  oracle. A docs page rendered through them is a terminal screenshot, not
  flowing prose.
- The repository has already routed around this twice: hue's markdown and DSV
  `--html` arms go through the semantic `MdDoc → renderMarkdownHtml` emitter
  (hue `HUE-O5`), and the gallery's breadcrumbs are hand-written HTML.

The resolution is **hybrid now, flow emitter later**: prose always renders
through the semantic markdown emitter (`FLW4`); chrome stays string-built until
`sparkles:ui` gains a third HTML mode in which a designated subtree emits _no_
cell geometry and lets the browser measure (`FLW1`); then components migrate
one at a time (`FLW2`/`FLW3`). The emitter itself is a `sparkles:ui`
capability — its normative requirements will land in
[ui/backends.md](../ui/backends.md) beside `TGT4`/`B2` when designed in
earnest; this page owns the docs-side adoption criteria.

## Flow-mode components (`FLW`)

| ID   | Requirement                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      | Status            | Traces to                                                                         |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------- | --------------------------------------------------------------------------------- |
| FLW1 | **Flow-mode HTML emission.** `sparkles:ui` must be able to emit a designated widget subtree as a _flow container_: semantic elements with class-based styling, **no** `ch`/`lh` geometry, no `white-space:pre`, no fixed integer widths — the browser measures and wraps. Cell-grid subtrees and flow subtrees must compose in one page. The mode is declared in the widget vocabulary (a subtree flag), respecting [`TGT9`](../ui/backends.md): the model keeps intent, the target realizes it. | not started       | extends `interp/html_semantic.d`; requirement of record to land in ui/backends.md |
| FLW2 | **Chrome as views.** The doc-site chrome — nav header, sidebar tree, breadcrumbs, appearance toggle, symbol-page section scaffolding — is expressed as `sparkles:ui` views (`viewXInto(ref Builder, …)` composable form), styled by `Slot`s, rendered to the page through the flow-mode emitter; the sidebar tree reuses the toolkit's existing tree components rather than a bespoke one.                                                                                                       | not started       | `sparkles.ui.components.*`; the `sparkles.docs` views to be                       |
| FLW3 | **Migration, not big-bang.** Each component migrates independently, gated on byte-diffable acceptance: the widget-rendered component replaces its string-built twin only when a rendered-page A/B shows equivalent markup semantics (classes, structure, accessibility attributes) — the same discipline the D0 extraction used. The string builders are deleted per component, not kept as fallbacks.                                                                                           | not started       | per-component A/B harness                                                         |
| FLW4 | **Prose stays semantic.** Body prose — markdown documents, DDoc-derived docs ([`APD3`](./apidoc.md)) — renders through `MdDoc → renderMarkdownHtml` on the HTML target regardless of FLW1's fate; the widget markdown view (`viewMarkdownInto`) remains the GUI/TUI twin. One model, two targets, per the existing `md/render_html.d` / `md/render_widgets.d` sibling contract.                                                                                                                  | standing decision | `sparkles.syntax.md.render_html` / `md.render_widgets`                            |

## Ordering

`FLW1` is the gate; nothing else here starts before it exists in `sparkles:ui`
(milestone `B2` territory). Until then the `DOC*` string builders are the
shipped implementation, and any new chrome (e.g. the `DOC8` sidebar) is written
as one more string builder — small, tested, and slated for FLW3 migration —
rather than blocking on the emitter.
