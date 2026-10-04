/**
`sparkles:twoslash` — render twoslash type-annotation overlays over
`sparkles:syntax`, in HTML, ANSI, and as `sparkles:ui` widgets.

Consumes the twoslash node model as $(B opaque data)
($(MREF sparkles,twoslash,protocol) + $(MREF sparkles,twoslash,ingest), from
`sparkles:twoslash-protocol`, re-exported here) and overlays it on a
highlighted snippet: hover popups with re-highlighted type signatures, `^?`
queries, completion lists, compiler errors, highlighted spans, and `// @tag`
lines. The backend-agnostic planner ($(MREF sparkles,twoslash,overlay))
positions the decorations; the HTML ($(MREF sparkles,twoslash,render_html))
and ANSI ($(MREF sparkles,twoslash,render_ansi)) renderers and the widget view
($(MREF sparkles,twoslash,render_widgets)), which `apps/hue`'s GUI and
interactive terminal paint, consume it. The `.twoslash-*` HTML class contract
is styled by the ported stylesheet in $(MREF sparkles,twoslash,style).

Design: issue #123 (render-side 2/2 of the `sparkles:twoslash` umbrella, #120).
Payloads come from the TypeScript `twoslash` (the committed fixtures) or from
the D-native producer of issue #124 (`sparkles:twoslash-d` over
`sparkles:dmd-lsp`, run as `twoslash-extract`), which emits the same node
model; this package depends on neither.

This module only re-exports the feature modules — unittests live with the
features (the runner does not discover tests in `package.d`).
*/
module sparkles.twoslash;

public import sparkles.twoslash.protocol;
public import sparkles.twoslash.ingest;
public import sparkles.twoslash.overlay;
public import sparkles.twoslash.render_html;
public import sparkles.twoslash.render_ansi;
public import sparkles.twoslash.render_widgets;
public import sparkles.twoslash.style;
