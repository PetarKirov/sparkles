/**
The immediate-mode interpreter for $(MREF sparkles,ui): $(LREF paint) walks a
$(REF DrawOp, sparkles,ui,canvas) stream once and dispatches each op to a
canvas's primitive. It is a $(B template) constrained by
$(REF isCanvas, sparkles,ui,canvas), so its `@safe`/`@nogc`/`nothrow` attributes
are inferred from the concrete canvas — a `@safe @nogc` recorder or a `@system`
raylib backend both drive the same code. Retained (cell-diff) and SSG/HTML
interpreters are later siblings under `interp/`.
*/
module sparkles.ui.interp.immediate;

import sparkles.ui.canvas : DrawOp, isCanvas, LineStyle, OpKind, RuleEdge,
    ruleEndpoints;
import sparkles.ui.geometry : Point;

/// Replays `ops` onto `canvas`, dispatching each $(REF DrawOp, sparkles,ui,canvas)
/// to the matching primitive. Backend-neutral: the display list carries resolved
/// `Visual`s, so the canvas only paints.
void paint(Canvas)(ref Canvas canvas, in DrawOp[] ops)
if (isCanvas!Canvas)
{
    foreach (ref op; ops)
    {
        final switch (op.kind) with (OpKind)
        {
            case fillRect:
                canvas.fillRect(op.rect, op.visual);
                break;
            case textRun:
                canvas.textRun(op.rect.origin, op.text, op.visual);
                break;
            case glyph:
                canvas.glyph(op.rect.origin, op.glyph, op.visual);
                break;
            case line:
                canvas.line(op.rect.origin, op.to, op.visual, op.lineStyle);
                break;
            case rule:
                // Sub-cell chrome is an OPTIONAL primitive (UIA2): a pixel
                // canvas draws the hairline where it belongs, and a canvas
                // without one gets the cell-aligned line along the same
                // edge rather than nothing.
                static if (__traits(compiles,
                    canvas.rule(op.rect, op.ruleEdge, op.visual)))
                    canvas.rule(op.rect, op.ruleEdge, op.visual);
                else
                {
                    Point rf, rt;
                    ruleEndpoints(op.rect, op.ruleEdge, rf, rt);
                    canvas.line(rf, rt, op.visual, LineStyle.solid);
                }
                break;
            case pushClip:
                // The clipping pair is an optional canvas capability: forward
                // when present, else paint unclipped (the display list already
                // culled fully-hidden subtrees).
                static if (__traits(compiles, canvas.pushClip(op.rect)))
                    canvas.pushClip(op.rect);
                break;
            case popClip:
                static if (__traits(compiles, canvas.popClip()))
                    canvas.popClip();
                break;
        }
    }
}

@("ui.interp.immediate.paintRoundTripsThroughRecorder")
@safe unittest
{
    import sparkles.ui.canvas : RecordingCanvas;
    import sparkles.ui.display_list : buildDisplayList;
    import sparkles.ui.geometry : Insets;
    import sparkles.ui.layout : layout;
    import sparkles.ui.style : defaultTwoslashPalette, Slot;
    import sparkles.ui.widget : Builder, Widget, WidgetKind;
    import sparkles.base.term_color : RgbColor;

    auto b = Builder();
    const t = b.add(Widget(kind: WidgetKind.text, text: "hi", slot: Slot.code));
    const popup = b.container(WidgetKind.popup, [t],
        slot: Slot.surface, padding: Insets.all(1), paintBackground: true);
    auto tree = b.finish(popup);

    const pal = defaultTwoslashPalette();
    auto ops = buildDisplayList(tree, layout(tree), pal,
        RgbColor(0, 0, 0), RgbColor(255, 255, 255));

    // Painting the display list into a recorder reproduces it op-for-op.
    RecordingCanvas c;
    paint(c, ops);
    assert(c.ops.length == ops.length);
    foreach (i; 0 .. ops.length)
    {
        assert(c.ops[i].kind == ops[i].kind);
        assert(c.ops[i].rect == ops[i].rect);
        assert(c.ops[i].visual == ops[i].visual);
    }
}

@("ui.interp.immediate.ruleFallsBackToTheCellAlignedLine")
@safe unittest
{
    import sparkles.ui.canvas : DrawOp, OpKind, RecordingCanvas, RuleEdge;
    import sparkles.ui.geometry : Rect;

    // A canvas with no sub-cell primitive still shows the hairline, at the
    // coarsest honest resolution: the line along the very same edge (UIA2).
    // Silence would be the wrong degradation — the chrome would vanish.
    auto rec = RecordingCanvas();
    DrawOp op = {kind: OpKind.rule, rect: Rect(2, 3, 10, 4),
        ruleEdge: RuleEdge.bottom};
    paint(rec, [op]);
    assert(rec.ops.length == 1);
    assert(rec.ops[0].kind == OpKind.line);
    assert(rec.ops[0].rect.origin == Point(2, 6));
    assert(rec.ops[0].to == Point(11, 6));
}

@("ui.canvas.ruleEndpointsByEdge")
@safe pure nothrow @nogc unittest
{
    import sparkles.ui.canvas : RuleEdge, ruleEndpoints;
    import sparkles.ui.geometry : Rect;

    const r = Rect(10, 20, 4, 6); // x 10..13, y 20..25
    Point f, t;
    ruleEndpoints(r, RuleEdge.top, f, t);
    assert(f == Point(10, 20) && t == Point(13, 20));
    ruleEndpoints(r, RuleEdge.right, f, t);
    assert(f == Point(13, 20) && t == Point(13, 25));
    ruleEndpoints(r, RuleEdge.centerX, f, t);
    assert(f == Point(12, 20) && t == Point(12, 25));
    ruleEndpoints(r, RuleEdge.centerY, f, t);
    assert(f == Point(10, 23) && t == Point(13, 23));

    // A degenerate rect must not index outside itself.
    ruleEndpoints(Rect(5, 5, 0, 0), RuleEdge.bottom, f, t);
    assert(f == Point(5, 5) && t == Point(5, 5));
}
