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

import sparkles.ui.canvas : DrawOp, isCanvas, OpKind;

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
