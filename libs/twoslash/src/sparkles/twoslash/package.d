/**
`sparkles:twoslash` — render twoslash type-annotation overlays over
`sparkles:syntax`, in HTML, ANSI, and (via `apps/hue --gui`) raylib.

Consumes the TypeScript `twoslash` node model as $(B opaque data)
($(MREF sparkles,twoslash,protocol) + $(MREF sparkles,twoslash,ingest)) and
overlays it on a highlighted snippet: hover popups with re-highlighted type
signatures, `^?` queries, completion lists, compiler errors, highlighted
spans, and `// @tag` lines. The backend-agnostic planner
($(MREF sparkles,twoslash,overlay)) positions the decorations; the HTML
($(MREF sparkles,twoslash,render_html)) and ANSI
($(MREF sparkles,twoslash,render_ansi)) renderers, plus the raylib GUI in
`apps/hue`, consume it. The `.twoslash-*` HTML class contract is styled by the
ported stylesheet in $(MREF sparkles,twoslash,style).

Design: issue #123 (render-side 2/2 of the `sparkles:twoslash` umbrella, #120).
The semantic backend (`sparkles:dmd-lsp`) that will one day replace TypeScript
`twoslash` as the data source is issue #124 — it slots in behind the proven
node model here.

This module only re-exports the feature modules — unittests live with the
features (the runner does not discover tests in `package.d`).
*/
module sparkles.twoslash;

public import sparkles.twoslash.protocol;
// ingest, overlay, render_html, render_ansi, style re-exports land with their
// modules in the following commits.
