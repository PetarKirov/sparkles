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

import sparkles.ui.canvas : DrawOp, FillRect, Glyph, isCanvas, Line, LineStyle,
    match, OpKind, PopClip, PushClip, Rule, RuleEdge, ruleEndpoints, Scrollbar,
    scrollbarCell, scrollbarCellCount, TextRun, visualOf;
import sparkles.ui.geometry : Point;
import sparkles.ui.style : Visual;

/**
Replays `ops` onto `canvas`, dispatching each $(REF DrawOp, sparkles,ui,canvas)
to the matching primitive. Backend-neutral: the display list carries resolved
`Visual`s, so the canvas only paints.

$(B `auto ref`, not plain `ref`.) Live hosts return a by-value canvas handle
each frame (a cheap pointer pair into the session); the recorder exposes the
canvas as a field. Plain `ref` would reject the temporary; a local copy of the
recorder would discard the capture. `auto ref` binds an lvalue by reference and
an rvalue by value, so `.paint(h.canvas, ops)` is correct on every host.
*/
void paint(Canvas)(auto ref Canvas canvas, in DrawOp[] ops)
if (isCanvas!Canvas)
{
    foreach (ref op; ops)
        op.payload.match!(
            (in FillRect f) { canvas.fillRect(f.rect, visualOf(f)); },
            (in TextRun t)
            {
                // `t.text` borrows the arena that interned it — valid for as
                // long as the buffer holding these operations is, which is
                // longer than this call. Backends take `scope const(char)[]`.
                canvas.textRun(t.rect.origin, t.text, visualOf(t.ink));
            },
            (in Glyph g) { canvas.glyph(g.at, g.glyph, visualOf(g.ink)); },
            (in Line l) { canvas.line(l.from, l.to, visualOf(l.ink), l.style); },
            (in Rule r)
            {
                // Sub-cell chrome is an OPTIONAL primitive (UIA2): a pixel
                // canvas draws the hairline where it belongs, and a canvas
                // without one gets the cell-aligned line along the same edge
                // rather than nothing.
                const vis = visualOf(r.ink);
                static if (__traits(compiles, canvas.rule(r.rect, r.edge, vis)))
                    canvas.rule(r.rect, r.edge, vis);
                else
                {
                    Point rf, rt;
                    ruleEndpoints(r.rect, r.edge, rf, rt);
                    canvas.line(rf, rt, vis, LineStyle.solid);
                }
            },
            (in Scrollbar s)
            {
                // A semantic sub-cell band is optional like `rule`. Pixel
                // canvases resolve it continuously; cell canvases get the
                // shared one/two-cell degradation with STM2's thumb.
                static if (__traits(compiles, canvas.scrollbar(s)))
                    canvas.scrollbar(s);
                else
                    paintScrollbarCells(canvas, s);
            },
            (in PushClip c)
            {
                // The clipping pair is an optional canvas capability: forward
                // when present, else paint unclipped (the display list already
                // culled fully-hidden subtrees).
                static if (__traits(compiles, canvas.pushClip(c.rect)))
                    canvas.pushClip(c.rect);
            },
            (in PopClip _)
            {
                static if (__traits(compiles, canvas.popClip()))
                    canvas.popClip();
            },
        );
}

private void paintScrollbarCells(Canvas)(ref Canvas canvas, in Scrollbar bar)
{
    bool vertical;
    final switch (bar.edge) with (RuleEdge)
    {
        case left: case right: case centerX:
            vertical = true;
            break;
        case top: case bottom: case centerY:
            vertical = false;
            break;
    }

    const track = vertical ? bar.rect.height : bar.rect.width;
    const available = vertical ? bar.rect.width : bar.rect.height;
    int breadth = scrollbarCellCount(bar.expandPercent);
    if (breadth > available)
        breadth = available;
    if (track <= 0 || breadth <= 0)
        return;

    int cross;
    final switch (bar.edge) with (RuleEdge)
    {
        case left: case top:
            cross = vertical ? bar.rect.x : bar.rect.y;
            break;
        case right:
            cross = bar.rect.x + bar.rect.width - breadth;
            break;
        case bottom:
            cross = bar.rect.y + bar.rect.height - breadth;
            break;
        case centerX:
            cross = bar.rect.x + (bar.rect.width - breadth) / 2;
            break;
        case centerY:
            cross = bar.rect.y + (bar.rect.height - breadth) / 2;
            break;
    }

    foreach (at; 0 .. track)
    {
        const thumb = scrollbarCell(bar.content, bar.viewport, bar.offset,
            track, at);
        Visual visual = visualOf(bar);
        if (!thumb)
            visual.fg = bar.trackColor;
        foreach (across; 0 .. breadth)
        {
            const p = vertical
                ? Point(cross + across, bar.rect.y + at)
                : Point(bar.rect.x + at, cross + across);
            canvas.glyph(p, thumb ? bar.thumbGlyph : bar.trackGlyph, visual);
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
    import sparkles.ui.canvas : DrawOp, OpKind, RecordingCanvas, ruleOp,
        RuleEdge;
    import sparkles.ui.geometry : Rect;

    // A canvas with no sub-cell primitive still shows the hairline, at the
    // coarsest honest resolution: the line along the very same edge (UIA2).
    // Silence would be the wrong degradation — the chrome would vanish.
    auto rec = RecordingCanvas();
    const op = ruleOp(Rect(2, 3, 10, 4), RuleEdge.bottom);
    paint(rec, [op]);
    assert(rec.ops.length == 1);
    assert(rec.ops[0].kind == OpKind.line);
    assert(rec.ops[0].rect.origin == Point(2, 6));
    assert(rec.ops[0].to == Point(11, 6));
}

@("ui.interp.immediate.scrollbarFallsBackToCells")
@safe unittest
{
    import sparkles.ui.canvas : DrawOp, RecordingCanvas, RuleEdge, Scrollbar;
    import sparkles.ui.geometry : Rect;
    import sparkles.base.term_color : RgbColor;

    auto rec = RecordingCanvas();
    const op = DrawOp(Scrollbar(
        rect: Rect(2, 3, 2, 4),
        content: 8,
        viewport: 4,
        fg: RgbColor(4, 5, 6),
        trackColor: RgbColor(1, 2, 3),
        expandPercent: 50,
        edge: RuleEdge.right,
        trackGlyph: '│',
        thumbGlyph: '█',
    ));
    paint(rec, [op]);
    assert(rec.ops.length == 8); // four rows × two expanded columns
    assert(rec.ops[0].rect.origin == Point(2, 3));
    assert(rec.ops[0].glyph == '█' && rec.ops[1].glyph == '█');
    assert(rec.ops[4].glyph == '│' && rec.ops[4].visual.fg == RgbColor(1, 2, 3));
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
