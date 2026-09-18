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

import sparkles.ui.canvas : DrawOp, FillRect, Glyph, ImageDraw, isCanvas, Line,
    LineStyle, match, OpKind, PopClip, PushClip, Rule, RuleEdge, ruleSpan,
    Scrollbar, scrollbarCell, scrollbarCellCount, TextRun, visualOf;
import sparkles.ui.geometry : cellsOf, Point, Rect;
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
                    ruleSpan(r.rect, r.edge, rf, rt);
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
            (in ImageDraw i)
            {
                // Raster content is an OPTIONAL primitive. A canvas that can
                // draw it gets the op; one that cannot gets `IMG4`'s visible,
                // declared placeholder — never silence, which would leave a
                // hole in the layout with nothing to say what belonged there.
                const vis = visualOf(i);
                static if (__traits(compiles,
                    canvas.image(i.rect, i.handle, i.fit, i.alt, vis)))
                    canvas.image(i.rect, i.handle, i.fit, i.alt, vis);
                else
                    paintImagePlaceholder(canvas, i, vis);
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

/**
`IMG4`: what an image looks like on a canvas that cannot draw one.

A filled box the size the image was allocated — so the page keeps its shape —
with the alt text in brackets across it, truncated to what fits. Bracketed
because a placeholder must not read as content: `[a bar chart]` is visibly a
stand-in, where the bare words are just a label.
*/
private void paintImagePlaceholder(Canvas)(ref Canvas canvas,
    in ImageDraw img, in Visual vis)
{
    if (img.rect.width <= 0 || img.rect.height <= 0)
        return;

    canvas.fillRect(img.rect, vis);
    if (img.alt.length == 0)
        return;

    // Centre one line of `[alt]`, clipped to the box rather than spilling out
    // of it — the surrounding layout was sized for the image, not the words.
    const y = img.rect.y + (img.rect.height - 1) / 2;
    const(char)[] text = img.alt;
    int width = cast(int) cellsOf(text) + 2; // the brackets
    while (width > img.rect.width && text.length)
    {
        text = text[0 .. $ - 1];
        width = cast(int) cellsOf(text) + 2;
    }
    if (text.length == 0)
        return;

    const x = img.rect.x + (img.rect.width - width) / 2;
    canvas.textRun(Point(x, y), "[", vis);
    canvas.textRun(Point(x + 1, y), text, vis);
    canvas.textRun(Point(x + width - 1, y), "]", vis);
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
    // HALF-OPEN, so the rule's last cell is inside the span. This used to be
    // `ruleEndpoints`' inclusive `(11, 6)` handed straight to a `line` whose
    // own convention is exclusive, which drew every rule one cell short of
    // its rect — see `ruleSpan`.
    assert(rec.ops[0].to == Point(12, 6));

    // …and the vertical edge, which the cell backends were dropping outright.
    auto vrec = RecordingCanvas();
    paint(vrec, [ruleOp(Rect(2, 3, 10, 4), RuleEdge.left)]);
    assert(vrec.ops.length == 1);
    assert(vrec.ops[0].rect.origin == Point(2, 3));
    assert(vrec.ops[0].to == Point(2, 7));
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

@("ui.interp.immediate.imageFallsBackToTheAltPlaceholder")
@safe unittest
{
    import sparkles.ui.canvas : imageOp, OpKind, RecordingCanvas;
    import sparkles.ui.geometry : Rect;
    import sparkles.ui.image : ImageFit, ImageHandle;

    // A canvas with no raster primitive must still show that something was
    // there, and what (`IMG4`). Silence would leave a hole the layout already
    // reserved space for — the same wrong degradation `rule` used to have.
    // A minimal conforming canvas: the five required primitives and nothing
    // optional, so `image` genuinely is not there to forward to.
    static struct NoRasters
    {
        import sparkles.ui.canvas : DrawOp, fillRectOp, glyphOp, lineOp,
            textRunOp;
        import sparkles.ui.geometry : cellsOf, Size;
        import sparkles.ui.style : Slot;

        DrawOp[] ops;

    @safe nothrow:
        void fillRect(in Rect r, in Visual v) { ops ~= fillRectOp(r, Slot.inherit, v); }
        void textRun(in Point at, scope const(char)[] t, in Visual v)
        {
            ops ~= textRunOp(Rect(at.x, at.y, cast(int) cellsOf(t), 1),
                t.idup, Slot.inherit, v);
        }
        void glyph(in Point at, dchar g, in Visual v) { ops ~= glyphOp(at, g, Slot.inherit, v); }
        void line(in Point a, in Point b, in Visual v, LineStyle st) { ops ~= lineOp(a, b, st, Slot.inherit, v); }
        Size measure(scope const(char)[] t) const => Size(cast(int) cellsOf(t), 1);
    }

    static assert(isCanvas!NoRasters);
    static assert(!__traits(compiles, (ref NoRasters c) => c.image));

    NoRasters c;
    paint(c, [imageOp(Rect(2, 3, 15, 5), ImageHandle(1), ImageFit.contain,
        "a bar chart")]);

    assert(c.ops.length == 4, "a fill plus the bracketed alt");
    assert(c.ops[0].kind == OpKind.fillRect);
    assert(c.ops[0].rect == Rect(2, 3, 15, 5), "the box keeps its shape");
    assert(c.ops[1].text == "[");
    assert(c.ops[2].text == "a bar chart");
    assert(c.ops[3].text == "]");
    // Centred on the middle row of the box, and within it.
    assert(c.ops[1].rect.origin == Point(3, 5), "13 cells centred in 15");
    assert(c.ops[3].rect.origin == Point(15, 5));

    // Narrower than the alt: truncated to the box, never spilling past it.
    NoRasters narrow;
    paint(narrow, [imageOp(Rect(0, 0, 6, 1), ImageHandle(1), ImageFit.contain,
        "a bar chart")]);
    assert(narrow.ops[2].text == "a ba");
    assert(narrow.ops[3].rect.origin.x == 5);

    // A canvas that CAN draw rasters gets the op itself, not the placeholder.
    RecordingCanvas real_;
    paint(real_, [imageOp(Rect(2, 3, 12, 5), ImageHandle(1), ImageFit.cover,
        "a bar chart")]);
    assert(real_.ops.length == 1 && real_.ops[0].kind == OpKind.image);
    assert(real_.ops[0].imageFit == ImageFit.cover);
}
