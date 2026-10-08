/**
The display-list stage of $(MREF sparkles,ui): $(LREF buildDisplayList) walks a
laid-out $(REF WidgetTree, sparkles,ui,widget) and emits a flat
$(REF DrawOp, sparkles,ui,canvas) stream, resolving each node's
$(REF Slot, sparkles,ui,style) to a concrete $(REF Visual, sparkles,ui,style)
against the palette and page colors. This is the last backend-neutral, GL-free
stage — the boundary a painter ($(MREF sparkles,ui,interp,immediate)) or an
SSG/ANSI backend consumes without ever touching a widget or a palette again.
*/
module sparkles.ui.display_list;

import sparkles.ui.canvas : DrawOp, OpKind;
import sparkles.ui.cmd_buffer : CmdBuffer, GcCmdBuffer;
import sparkles.ui.geometry : Point, Rect;
import sparkles.ui.layout : CellMeasure, childClipOf, clipsX, clipsY, Frame,
    measureWidth, unclipped, spanStyle;
import sparkles.ui.style : Palette, resolveVisual, Slot, StateSet, TextStyle, ThumbFamily, Visual;
import sparkles.ui.widget : Visibility, Widget, WidgetKind, WidgetTree;
import sparkles.base.term_color : RgbColor;
import sparkles.base.text.width : codepointWidth;

@safe:

/**
Builds the display list for `tree` (already positioned into `frames`), resolving
every slot against `pal` and the page `pageFg`/`pageBg`. Containers paint their
background (when `paintBackground`) before recursing, so children draw on top.

Allocates the returned array. For a per-frame rebuild that must not, see
$(LREF buildDisplayListInto).
*/
DrawOp[] buildDisplayList(TM = CellMeasure)(in WidgetTree tree, in Frame[] frames,
    in Palette pal, in RgbColor pageFg, in RgbColor pageBg, TM tm = TM.init)
{
    GcCmdBuffer buf;
    buildDisplayListInto(tree, frames, pal, pageFg, pageBg, buf, tm);
    return buf.ops.dup;
}

/**
Builds the display list into a caller-supplied sink — the `@nogc` path
([`NFR2`](../../../../docs/specs/ui/feature-requirements.md)).

`Sink` is anything that accepts `~= DrawOp`, so a
$(REF SharedBuffer, sparkles,base,buffer) the caller reuses across frames
works, and a plain `DrawOp[]` still works. Attributes are $(B inferred) from the
sink: with a `SharedBuffer` this whole path is `@nogc`, which a function
returning an array can never be.

$(B The operations live in `ops`.) The sink owns them; each `textRun` $(I copies)
its UTF-8 into the op, so the widget tree need not outlive the list for text
content. A caller that stores a display list past the scope that built it
therefore stores the $(I sink), not a
slice of it. This is the ownership question
[`UI-O4`](../../../../docs/specs/ui/open-issues.md#ui-o4) records.
*/
void buildDisplayListInto(Sink, TM = CellMeasure)(in WidgetTree tree, in Frame[] frames,
    in Palette pal, in RgbColor pageFg, in RgbColor pageBg, ref Sink ops,
    TM tm = TM.init)
if (__traits(compiles, (ref Sink s) {
    s.fillRect(Rect.init);
    s.textRun(Rect.init, "x");
    s.pushClip(Rect.init);
    s.popClip();
}))
{
    emit(tree, tree.root, frames, pal, pageFg, pageBg, unclipped(), false, ops, tm);
}

/+
`text` cut at an owned whole-grapheme boundary to fit `cells` as `tm`
measures it in `style`. Interface faces retain their proportional metrics;
cell targets use the owned terminalKitty fitting policy.
+/
private const(char)[] fitCells(TM)(ref TM tm, return scope const(char)[] text,
    int cells, in TextStyle style)
{
    import sparkles.base.text.grapheme : cellFit = fitCells, GraphemeBreakState;
    import sparkles.ui.layout : isStyledTextMeasure;

    const capacity = cells > 0 ? cells : 0;
    static if (isStyledTextMeasure!TM)
    {
        if (measureWidth(tm, text, style) <= capacity)
            return text;
        import sparkles.base.text.ansi : escapeLength;
        import sparkles.base.text.utf : decodeToken, UtfMode;

        GraphemeBreakState breaks;
        size_t position, fittedEnd;
        bool pending;
        while (position < text.length)
        {
            if (text[position] == '\x1b')
            {
                position += escapeLength(text[position .. $]);
                continue;
            }
            const start = position;
            const decoded = decodeToken(text[position .. $], UtfMode.replacement);
            position += decoded.result.consumed;
            if (breaks.push(decoded.token.scalar) && pending)
            {
                if (measureWidth(tm, text[0 .. start], style) > capacity)
                    return text[0 .. fittedEnd];
                fittedEnd = start;
            }
            pending = true;
        }
        return text[0 .. fittedEnd];
    }
    else
        return text[0 .. cellFit(text, cast(size_t) capacity).bytes];
}

/+
`overflowX`: whether a rich row here may run past its frame — it may when
something on the way down contains it on x: an ancestor that clips on that
axis (a viewport, or a bordered box — `LAY15`), or one whose host does
(`scrollsX`). Otherwise it is cut like a plain run (`LAY16`).
+/
private void emit(Sink, TM)(in WidgetTree tree, uint idx, in Frame[] frames,
    in Palette pal, in RgbColor pageFg, in RgbColor pageBg, in Rect clip,
    bool overflowX, ref Sink ops, ref TM tm)
{
    ref const node = tree.nodes[idx];
    const rect = frames[idx].rect;

    // `hidden` occupies its frame but paints nothing; `collapsed` was already
    // removed from flow by layout (LAY11). Either way the subtree emits no ops.
    if (node.visibility != Visibility.visible)
        return;

    // Cull a subtree that lies fully outside the effective clip (scrolled off
    // a viewport). Zero-sized frames are kept — a border-only box measures 0×0.
    if (!rect.empty && rect.intersection(clip).empty)
        return;

    // The node-level syntax channel: resolved colors from the content's theme
    // override the slot resolution (the widget twin of `TextSpan.fg`).
    static void applyOverrides(ref Visual vis, in Widget node)
    {
        if (node.hasFgOverride)
            vis.fg = node.fgOverride;
        if (node.hasBgOverride)
        {
            vis.bg = node.bgOverride;
            vis.hasBg = true;
        }
        if (node.hasBorderOverride)
            vis.border.color = node.borderOverride;
    }
    // `EFX5`: the bracket is emitted HERE, by the display list, so every
    // consumer of the op stream — the GPU painter, the cell grid, the HTML
    // emitters, the headless `--render` target — sees the same structure.
    // A backend deriving it for itself is how the CRT ended up outside the
    // pipeline in the first place.
    //
    // It wraps the node's own background too, not just its children: an
    // effect on a panel that left the panel's fill untreated would be
    // treating "the subtree" as something other than what it looks like.
    const bracketed = node.effect.valid;
    if (bracketed)
        ops.pushEffect(rect, node.effect);

    Visual vis = resolveVisual(pal, node.slot, node.decoration, node.textStyle, pageFg,
        pageBg, node.states);
    applyOverrides(vis, node);

    // The background fill is gated by `paintBackground`; a border/shadow/arrow rides
    // the decoration independently (a box can have a border but no fill — the
    // `.twoslash-hover` dotted underline). Mask `hasBg` so the op means exactly
    // "fill this bg", then emit the decorated box first (children paint over it).
    vis.hasBg = node.paintBackground && vis.hasBg;
    if (vis.hasBg || vis.border.any || vis.shadow.any || vis.arrow)
        ops.fillRect(rect, node.slot, vis);

    final switch (node.kind) with (WidgetKind)
    {
        case text:
            // A painter takes a run's advance from the text itself, so a run
            // longer than the width layout gave it would paint over whatever
            // lies beside it — a border, a scrollbar, the next cell of a row.
            // Layout shrinks an overfull row's text below its natural width;
            // the cut to that width happens here, once, for every backend.
            const lines = frames[idx].lines;
            if (lines.length == 0)
            {
                const fitted = fitCells(tm, node.text, rect.width, node.textStyle);
                ops.textRun(Rect(rect.x, rect.y,
                    measureWidth(tm, fitted, node.textStyle), frames[idx].lineRows),
                    fitted, node.slot, vis);
                break;
            }
            // A wrapped run: one op per broken line, stacked down the frame.
            const inner = rect.deflate(node.padding);
            // A line in a face taller than the cell takes `lineRows` rows.
            const pitch = frames[idx].lineRows;
            foreach (li, ln; lines)
            {
                const fitted = fitCells(tm, ln, inner.width, node.textStyle);
                ops.textRun(
                    Rect(inner.x, inner.y + cast(int) li * pitch,
                        measureWidth(tm, fitted, node.textStyle), pitch),
                    fitted, node.slot, vis);
            }
            break;
        case rich:
            // A retained projection owns grapheme boundaries and cell advances.
            // Styled pieces crossing one grapheme paint once with its leading
            // brush; exact paint-only styles/source relations remain in Frame.
            //
            // A rich row is a content line, and one wider than its pane is
            // meant to be scrolled into view — so inside something that
            // contains it on x (a viewport, a bordered box, a host-scrolled
            // document: hue's raw view sizes its horizontal bar from exactly
            // this overflow) its spans keep their full width. Anywhere else
            // nothing would stop them painting over the row's neighbours, and
            // they are cut to the frame like a plain run (`LAY16`).

            import sparkles.ui.widget : TextSpan;
            import sparkles.base.text.wrap_plan : ProvenanceKind;

            const inner = rect.deflate(node.padding);
            const pitch = frames[idx].lineRows;
            import sparkles.ui.wrap : sameSpanBrush, spanPaintAdvance;

            void emitSpanRow(scope const TextSpan[] spans, int y, int xOff = 0)
            {
                int x = inner.x + xOff;
                size_t i;
                while (i < spans.length)
                {
                    ref const span = spans[i];
                    if (span.formatting) { ++i; continue; }
                    size_t end = i + 1;
                    long advance = spanPaintAdvance(span);
                    while (end < spans.length && span.wrapPlan !is null
                        && spans[end].wrapPlan is span.wrapPlan
                        && spans[end].wrapLine == span.wrapLine
                        && span.logicalGroup != ulong.max
                        && spans[end].logicalGroup == span.logicalGroup)
                        advance += spanPaintAdvance(spans[end++]);
                    size_t logicalEnd = span.logicalEnd;
                    // Coalesce only complete adjacent clusters with the same
                    // leading brush, without copying their committed source.
                    while (end < spans.length && span.wrapPlan !is null
                        && span.clusterTextBorrowed
                        && spans[end].clusterTextBorrowed
                        && spans[end].wrapPlan is span.wrapPlan
                        && spans[end].wrapLine == span.wrapLine
                        && spans[end].logicalStart == logicalEnd
                        && sameSpanBrush(span, spans[end]))
                    {
                        ref const next = spans[end];
                        size_t nextEnd = end + 1;
                        long nextAdvance = spanPaintAdvance(next);
                        while (nextEnd < spans.length
                            && spans[nextEnd].wrapPlan is next.wrapPlan
                            && spans[nextEnd].wrapLine == next.wrapLine
                            && next.logicalGroup != ulong.max
                            && spans[nextEnd].logicalGroup == next.logicalGroup)
                            nextAdvance += spanPaintAdvance(spans[nextEnd++]);
                        advance += nextAdvance;
                        logicalEnd = next.logicalEnd;
                        end = nextEnd;
                    }
                    const(char)[] text = span.clusterText;
                    if (span.clusterTextBorrowed)
                        text = span.wrapPlan.source.bytes[span.logicalStart .. logicalEnd];
                    if (span.projectionRelation == ProvenanceKind.omission)
                    {
                        i = end;
                        continue;
                    }
                    const w = cast(int) advance;
                    const slot = span.slot == Slot.inherit ? node.slot : span.slot;
                    const style = spanStyle(span, node.textStyle);
                    i = end;
                    // A span that inherits the node's slot inherits its states
                    // too; one that names its own slot is its own role, at rest
                    // — a selected row's `gutter` guides are not a selected tab
                    // label (D46).
                    auto vis = resolveVisual(pal, slot, node.decoration, style,
                        pageFg, pageBg,
                        span.slot == Slot.inherit ? node.states : StateSet.init);
                    vis.styleBits = cast(ushort)(vis.styleBits | span.ansiAttributes);
                    if (span.hasFg) // the syntax channel: a resolved color
                        vis.fg = span.fg;
                    vis.hasBg = span.paintBackground && vis.hasBg;
                    if (span.hasBg) // resolved bg (pre-styled ANSI content)
                    {
                        vis.bg = span.bg;
                        vis.hasBg = true;
                    }
                    vis.linkId = span.linkId; // the terminal hyperlink channel
                    const r = Rect(x, y, w, pitch);
                    if (vis.hasBg)
                        ops.fillRect(r, slot, vis);
                    ops.textRun(r, text, slot, vis);
                    x += w;
                }
            }

            foreach (li, line; frames[idx].paintSpanLines)
                emitSpanRow(line, inner.y + cast(int) li * pitch,
                    li ? node.hangIndent : 0);
            break;
        case glyph:
            if (codepointWidth(node.glyph) <= rect.width)
                ops.glyph(rect.origin, node.glyph, node.slot, vis);
            break;
        case image:
            // The node's `text` is the alt text, which the buffer interns —
            // so a backend without rasters has something to show (`IMG4`)
            // without the painter ever consulting a registry.
            ops.image(rect, node.image, node.imageFit, node.text, node.slot,
                vis);
            break;
        case line:
            ops.line(rect.origin,
                Point(rect.x + node.lineTo.x, rect.y + node.lineTo.y),
                node.lineStyle, node.slot, vis);
            break;
        case scrollbar:
            static int barInt(long value) pure nothrow @nogc
                => value < int.min ? int.min
                    : value > int.max ? int.max : cast(int) value;
            // A bar that owns its rule IS a border, so it resolves the border
            // slot (`SCV11`). `Slot.track` exists to dim a hover affordance
            // sitting under a thumb; a panel edge is not that, and resolving
            // it there paints the fence's bottom border two shades light.
            auto trackVis = resolveVisual(pal,
                node.barPaintsIdleTrack ? Slot.border : Slot.track,
                node.decoration, node.textStyle, pageFg, pageBg);
            auto thumbVis = resolveVisual(pal, Slot.thumb, node.decoration,
                node.textStyle, pageFg, pageBg, node.states);
            if (node.hasBarTrackFgOverride)
                trackVis.fg = node.barTrackFgOverride;
            if (node.hasFgOverride)
                thumbVis.fg = node.fgOverride;
            ops.scrollbar(rect, node.barEdge,
                barInt(node.barContent), barInt(node.barViewport),
                barInt(node.barOffset), Slot.thumb, thumbVis,
                trackColor: trackVis.fg, trackAlpha: trackVis.fgAlpha,
                trackLit: node.barTrackLit,
                expandPercent: node.barExpandPercent,
                trackGlyph: thumbFamilyGlyph(pal.glyphs.thumb, node.barTrackGlyph, false),
                thumbGlyph: thumbFamilyGlyph(pal.glyphs.thumb, node.barThumbGlyph, true),
                paintsIdleTrack: node.barPaintsIdleTrack);
            break;
        case box:
            break; // background (if any) already emitted
        case row, column, stack, panel, popup:
            // A clipping container brackets its children in scissor ops. The
            // pushed rect is this node's padded content box on each clipped
            // axis, already intersected with the ancestor clip by
            // `childClipOf` — so the ops a display list emits are always
            // pre-intersected.
            //
            // That is a property of THESE ops, not a licence for a canvas to
            // replace rather than intersect (`TGT1`/`TGT12`). A canvas also
            // receives clips pushed by hand — hue's base viewport, diagram's
            // board clip — which are not pre-intersected against anything, and
            // a canvas that replaces loses the ancestor on exactly those. The
            // contract a canvas implements is the one stated on `pushClip`:
            // nested clips intersect.
            const clips = clipsX(node) || clipsY(node);
            const childClip = childClipOf(node, rect, clip);
            if (clips)
                ops.pushClip(childClip);
            foreach (child; node.children)
                emit(tree, child, frames, pal, pageFg, pageBg, childClip,
                    overflowX || node.scrollsX || clipsX(node), ops, tm);
            if (clips)
                ops.popClip();
            break;
    }

    if (bracketed)
        ops.popEffect();
}

@("ui.display_list.hoverPopup.surfaceThenText")
@safe unittest
{
    import sparkles.ui.widget : Builder;
    import sparkles.ui.geometry : Insets;
    import sparkles.ui.layout : layout;
    import sparkles.ui.style : defaultTwoslashPalette;

    // popup(surface) → column(signature code run, docs run)
    auto b = Builder();
    const sig = b.add(Widget(kind: WidgetKind.text, text: "title: string", slot: Slot.code));
    const docs = b.add(Widget(kind: WidgetKind.text, text: "The title.", slot: Slot.docs));
    const col = b.container(WidgetKind.column, [sig, docs]);
    const popup = b.container(WidgetKind.popup, [col],
        slot: Slot.surface, padding: Insets.all(1), paintBackground: true);
    auto tree = b.finish(popup);

    const pal = defaultTwoslashPalette();
    const pageFg = RgbColor(0x22, 0x22, 0x22);
    const pageBg = RgbColor(0xff, 0xff, 0xff);
    auto ops = buildDisplayList(tree, layout(tree), pal, pageFg, pageBg);

    // surface fill, then two text runs (code inherits page fg, docs is muted).
    assert(ops.length == 3);
    assert(ops[0].kind == OpKind.fillRect && ops[0].slot == Slot.surface);
    assert(ops[0].visual.hasBg && ops[0].visual.bg == RgbColor(0xf8, 0xf8, 0xf8));

    assert(ops[1].kind == OpKind.textRun && ops[1].text == "title: string");
    assert(ops[1].visual.fg == pageFg); // code inherits page fg

    assert(ops[2].kind == OpKind.textRun && ops[2].text == "The title.");
    assert(ops[2].visual.fg == RgbColor(0x88, 0x88, 0x88)); // docs muted
}

@("ui.display_list.nodeStatesSelectTheThemeOverlay")
@safe unittest
{
    import sparkles.base.term_color : Color, RgbColor;
    import sparkles.ui.layout : layout;
    import sparkles.ui.style : defaultTwoslashPalette, InteractionState, StateSet;
    import sparkles.ui.widget : Builder, Widget, WidgetKind;

    // TOK4 at the display-list boundary: the node carries its states, the
    // palette carries the overlay, and the op's resolved visual is the
    // meeting point — with no overlay a hovered node paints exactly as rest.
    const fg = RgbColor(0xee, 0xee, 0xee), bg = RgbColor(0x11, 0x11, 0x11);
    auto pal = defaultTwoslashPalette();

    auto b = Builder();
    const rest = b.add(Widget(kind: WidgetKind.text, text: "a", slot: Slot.thumb));
    const hovered = b.add(Widget(kind: WidgetKind.text, text: "b", slot: Slot.thumb,
        states: StateSet.of(InteractionState.hover)));
    const tree = b.finish(b.add(Widget(kind: WidgetKind.column, children: [rest, hovered])));
    const frames = layout(tree);

    const plain = buildDisplayList(tree, frames, pal, fg, bg);
    assert(plain.length == 2 && plain[0].visual.fg == plain[1].visual.fg,
        "no overlay ⇒ hover paints as rest");

    pal.overlay(InteractionState.hover).fg[Slot.thumb] = Color.fromRgb(0x00, 0xcc, 0xff);
    const lit = buildDisplayList(tree, frames, pal, fg, bg);
    assert(lit[0].visual.fg == plain[0].visual.fg, "the rest node is untouched");
    assert(lit[1].visual.fg == RgbColor(0x00, 0xcc, 0xff), "the hovered node took the overlay");
}

@("ui.display_list.errorWavyUnderlineAndMessage")
@safe unittest
{
    import sparkles.ui.widget : Builder;
    import sparkles.ui.canvas : LineStyle;
    import sparkles.ui.geometry : Point;
    import sparkles.ui.layout : layout;
    import sparkles.ui.style : defaultTwoslashPalette;

    // A wavy underline spanning 5 cells, then an error-slot message row.
    auto b = Builder();
    const wavy = b.add(Widget(kind: WidgetKind.line, slot: Slot.error,
        lineStyle: LineStyle.wavy, lineTo: Point(5, 0)));
    const msg = b.add(Widget(kind: WidgetKind.text, text: "Type error", slot: Slot.error));
    const col = b.container(WidgetKind.column, [wavy, msg]);
    auto tree = b.finish(col);

    const pal = defaultTwoslashPalette();
    auto ops = buildDisplayList(tree, layout(tree), pal,
        RgbColor(0, 0, 0), RgbColor(255, 255, 255));

    assert(ops.length == 2);
    assert(ops[0].kind == OpKind.line && ops[0].lineStyle == LineStyle.wavy);
    assert(ops[0].visual.fg == RgbColor(0xd4, 0x56, 0x56));
    assert(ops[0].to == Point(5, 0)); // origin (0,0) + lineTo (5,0)
    assert(ops[1].kind == OpKind.textRun && ops[1].visual.fg == RgbColor(0xd4, 0x56, 0x56));
}

@("ui.display_list.styledMeasure.uiRunsStepAndAdvanceByTheirFace")
@safe unittest
{
    import sparkles.ui.geometry : Constraints;
    import sparkles.ui.widget : Builder;
    import sparkles.ui.layout : layout, StyledMeasure;
    import sparkles.ui.style : defaultTwoslashPalette, FontRole, TypeStep;
    import sparkles.ui.wrap : TextSpan, TextWrap;

    // `GLY10`: on a target with an interface face, a title's lines step by
    // its rows, and a rich line's spans advance by their measured width.
    const title = TextStyle(fontRole: FontRole.ui, typeStep: TypeStep.title);
    auto b = Builder();
    const t = b.add(Widget(kind: WidgetKind.text, text: "aa bb", textStyle: title,
        wrap: TextWrap.greedy));
    const r = b.add(Widget(kind: WidgetKind.rich, spans: [
        TextSpan(text: "a", textStyle: TextStyle(fontRole: FontRole.ui)),
        TextSpan(text: "cd")]));
    const col = b.container(WidgetKind.column, [t, r]);
    auto tree = b.finish(col);

    StyledMeasure m;
    const frames = layout(tree, Constraints(maxW: 4), m);
    auto ops = buildDisplayList(tree, frames, defaultTwoslashPalette(),
        RgbColor(0, 0, 0), RgbColor(255, 255, 255), m);

    assert(ops.length == 4);
    assert(ops[0].rect == Rect(0, 0, 4, 2) && ops[0].text == "aa");
    assert(ops[1].rect == Rect(0, 2, 4, 2) && ops[1].text == "bb", "a title line is two rows");
    assert(ops[2].rect == Rect(0, 4, 2, 1) && ops[2].text == "a", "a ui span is twice as wide");
    assert(ops[3].rect == Rect(2, 4, 2, 1) && ops[3].text == "cd");
}

@("ui.display_list.styledMeasure.cutKeepsWholeGraphemes")
@safe unittest
{
    import sparkles.ui.geometry : Constraints, SizeSpec;
    import sparkles.ui.widget : Builder;
    import sparkles.ui.layout : layout, StyledMeasure;
    import sparkles.ui.style : defaultTwoslashPalette, FontRole;

    // The text-presentation heart would fit after stripping VS16, but the
    // authored emoji cluster does not. Fitting must retain only the first cluster.
    auto b = Builder();
    const t = b.add(Widget(kind: WidgetKind.text, text: "é❤️ab",
        textStyle: TextStyle(fontRole: FontRole.ui), width: SizeSpec.fixed(5)));
    auto tree = b.finish(t);

    StyledMeasure m;
    auto ops = buildDisplayList(tree, layout(tree, Constraints.init, m),
        defaultTwoslashPalette(), RgbColor(0, 0, 0), RgbColor(255, 255, 255), m);
    assert(ops.length == 1 && ops[0].text == "é");
}

@("ui.display_list.styledMeasure.escapeInsideGraphemeKeepsWholeBoundary")
@safe unittest
{
    import sparkles.ui.layout : StyledMeasure;
    import sparkles.ui.style : FontRole;
    import sparkles.base.text.ansi : byAnsiToken;

    StyledMeasure tm;
    const style = TextStyle(fontRole: FontRole.ui);
    const fitted = fitCells(tm, "e\x1b[31m\u0301\x1b[0mb", 2, style);
    string visible;
    foreach (part; byAnsiToken(fitted))
        if (!part.isEscape) visible ~= part.slice;
    assert(visible == "e\u0301" && measureWidth(tm, fitted, style) == 2,
        "escapes are zero-width, and fitting never leaves the combining mark behind");
}

@("ui.display_list.decoratedBoxAndStyledText")
@safe unittest
{
    import sparkles.ui.widget : Builder;
    import sparkles.ui.geometry : Insets;
    import sparkles.ui.layout : layout;
    import sparkles.ui.style : BorderStyle, Decoration, defaultTwoslashPalette,
        FontRole, TextStyle;
    import sparkles.base.term_style : TextAttr;

    // A popup surface (fill + 1px solid border + radius 4 + shadow) over a docs run
    // (sans face, 0.8em, italic).
    auto b = Builder();
    const docs = b.add(Widget(kind: WidgetKind.text, text: "The title.", slot: Slot.docs,
        textStyle: TextStyle(fontRole: FontRole.docs, fontScale: 80, italic: true)));
    const popup = b.container(WidgetKind.popup, [docs],
        slot: Slot.surface, padding: Insets.all(1), paintBackground: true,
        decoration: Decoration(borderWidth: Insets.all(1), borderStyle: BorderStyle.solid,
            borderRadius: 4, shadow: true));
    auto tree = b.finish(popup);

    const pal = defaultTwoslashPalette();
    auto ops = buildDisplayList(tree, layout(tree), pal,
        RgbColor(0x22, 0x22, 0x22), RgbColor(0xff, 0xff, 0xff));

    // The box op carries fill + border + radius + shadow in one resolved Visual.
    assert(ops[0].kind == OpKind.fillRect && ops[0].visual.hasBg);
    assert(ops[0].visual.border.any && ops[0].visual.border.style == BorderStyle.solid);
    assert(ops[0].visual.borderRadius == 4 && ops[0].visual.shadow.any);

    // A bordered box keeps its content inside it (`LAY15`): the children sit
    // in a clip of the padded box, one cell in from the border.
    assert(ops[1].kind == OpKind.pushClip && ops[1].rect == ops[0].rect.deflate(Insets.all(1)));
    assert(ops[$ - 1].kind == OpKind.popClip);

    // The text op carries the resolved font role/scale + the packed italic bit.
    const t = ops[$ - 2];
    assert(t.kind == OpKind.textRun && t.text == "The title.");
    assert(t.visual.fontRole == FontRole.docs && t.visual.fontScale == 80);
    assert((t.visual.styleBits & TextAttr.italic.bits) != 0);
}

@("ui.display_list.wrappedTextEmitsOneRunPerLine")
@safe unittest
{
    import sparkles.ui.widget : Builder;
    import sparkles.ui.geometry : Constraints;
    import sparkles.ui.layout : layout;
    import sparkles.ui.style : defaultTwoslashPalette;
    import sparkles.ui.wrap : TextWrap;

    auto b = Builder();
    Widget para = Widget(kind: WidgetKind.text,
        text: "the quick brown fox", slot: Slot.docs, wrap: TextWrap.greedy);
    const t = b.add(para);
    const col = b.container(WidgetKind.column, [t]);
    auto tree = b.finish(col);

    const pal = defaultTwoslashPalette();
    auto ops = buildDisplayList(tree, layout(tree, Constraints(maxW: 10)), pal,
        RgbColor(0, 0, 0), RgbColor(255, 255, 255));

    // One run per broken line, stacked one row apart, same resolved visual.
    assert(ops.length == 2);
    assert(ops[0].kind == OpKind.textRun && ops[0].text == "the quick");
    assert(ops[1].kind == OpKind.textRun && ops[1].text == "brown fox");
    assert(ops[0].rect.y == 0 && ops[1].rect.y == 1);
    assert(ops[0].visual == ops[1].visual);
}

@("ui.display_list.viewportClipsScrollsAndCulls")
@safe unittest
{
    import sparkles.ui.widget : Builder;
    import sparkles.ui.geometry : SizeSpec;
    import sparkles.ui.layout : layout;
    import sparkles.ui.style : defaultTwoslashPalette;

    // A 2-row viewport over 5 rows, scrolled down by one: rows 1..2 visible,
    // rows 0/3/4 culled, and the children bracketed in scissor ops.
    auto b = Builder();
    uint[] rows;
    foreach (t; ["zero", "one", "two", "three", "four"])
        rows ~= b.add(Widget(kind: WidgetKind.text, text: t));
    Widget viewW = Widget(kind: WidgetKind.column, children: rows,
        height: SizeSpec.fixed(2), clipY: true, childOffset: Point(0, 1));
    const view = b.add(viewW);
    auto tree = b.finish(view);

    const pal = defaultTwoslashPalette();
    auto frames = layout(tree);
    assert(frames[rows[0]].rect.y == -1); // scrolled above the viewport
    assert(frames[rows[1]].rect.y == 0);

    auto ops = buildDisplayList(tree, frames, pal,
        RgbColor(0, 0, 0), RgbColor(255, 255, 255));

    // pushClip, the two visible rows, popClip — nothing else.
    assert(ops.length == 4);
    assert(ops[0].kind == OpKind.pushClip);
    // Only y is clipped: the rect covers rows 0..2 and stays unbounded on x.
    assert(ops[0].rect.y == 0 && ops[0].rect.height == 2);
    assert(ops[0].rect.x < -1_000_000 && ops[0].rect.width > 1_000_000);
    assert(ops[1].kind == OpKind.textRun && ops[1].text == "one");
    assert(ops[2].kind == OpKind.textRun && ops[2].text == "two");
    assert(ops[3].kind == OpKind.popClip);
}

@("ui.display_list.textIsCutToTheWidthLayoutGaveIt")
@safe unittest
{
    import sparkles.ui.widget : Builder;
    import sparkles.ui.wrap : TextWrap;
    import sparkles.ui.geometry : SizeSpec;
    import sparkles.ui.layout : layout;
    import sparkles.ui.style : defaultTwoslashPalette;

    // An overfull row — a label and a value in 12 cells that want 18 — and
    // a wrapped run with a word longer than its line. Layout shrinks the
    // value and lets the word overflow; neither op may paint past its frame,
    // or it lands on whatever is beside it (the gallery's panel border).
    auto b = Builder();
    const label = b.add(Widget(kind: WidgetKind.text, text: "tier  "));
    const value = b.add(Widget(kind: WidgetKind.text, text: "interactive!"));
    const row = b.add(Widget(kind: WidgetKind.row, children: [label, value],
        width: SizeSpec.fixed(12)));
    const para = b.add(Widget(kind: WidgetKind.text, text: "a unbreakable",
        wrap: TextWrap.greedy, width: SizeSpec.fixed(6)));
    auto tree = b.finish(b.add(Widget(kind: WidgetKind.column,
        children: [row, para])));

    auto frames = layout(tree);
    auto ops = buildDisplayList(tree, frames, defaultTwoslashPalette(),
        RgbColor(0, 0, 0), RgbColor(255, 255, 255));

    import sparkles.base.text.grapheme : visibleWidth;

    foreach (ref op; ops)
        if (op.kind == OpKind.textRun)
            assert(visibleWidth(op.text) <= op.rect.width, op.text);
    const v = frames[value].rect;
    assert(v.width < visibleWidth("interactive!"), "the row was overfull");
}

@("ui.display_list.aRichRowStaysInItsFrameUnlessSomethingContainsIt")
@safe unittest
{
    import sparkles.ui.widget : Builder, TextSpan;
    import sparkles.base.text.grapheme : visibleWidth;
    import sparkles.ui.geometry : SizeSpec;
    import sparkles.ui.layout : layout;
    import sparkles.ui.style : defaultTwoslashPalette;

    // Twelve cells of spans in an eight-cell column, beside a neighbour.
    static DrawOp[] build(bool clipX, bool scrollsX, out Rect frame)
    {
        auto b = Builder();
        const line = b.add(Widget(kind: WidgetKind.rich, spans: [
            TextSpan(text: "hello "), TextSpan(text: "world!")]));
        const col = b.add(Widget(kind: WidgetKind.column, children: [line],
            width: SizeSpec.fixed(8), clipX: clipX, scrollsX: scrollsX));
        const next = b.add(Widget(kind: WidgetKind.text, text: "|"));
        auto tree = b.finish(b.add(Widget(kind: WidgetKind.row,
            children: [col, next])));
        auto frames = layout(tree);
        frame = frames[line].rect;
        return buildDisplayList(tree, frames, defaultTwoslashPalette(),
            RgbColor(0, 0, 0), RgbColor(255, 255, 255));
    }

    static int rightmost(in DrawOp[] ops, string skip)
    {
        int r;
        foreach (ref op; ops)
            if (op.kind == OpKind.textRun && op.text != skip)
            {
                const e = op.rect.x + cast(int) visibleWidth(op.text);
                r = e > r ? e : r;
            }
        return r;
    }

    // Nothing contains it: the spans are cut where the frame ends, as a plain
    // run is (`LAY14`), so the neighbour's cell stays the neighbour's.
    Rect f;
    auto ops = build(false, false, f);
    assert(f.width == 8, "the column bounds the row");
    assert(rightmost(ops, "|") == f.x + 8, "cut at the frame");

    // A viewport, and a host-scrolled document, keep the whole line: that
    // overflow is what their scrollbars are sized from.
    foreach (clipX, scrollsX; [false: true, true: false])
    {
        ops = build(clipX, scrollsX, f);
        assert(rightmost(ops, "|") == f.x + 12, "the full width survives");
    }
}


@("ui.display_list.borderOnlyBoxStillEmits")
@safe unittest
{
    import sparkles.ui.widget : Builder;
    import sparkles.ui.geometry : Insets;
    import sparkles.ui.layout : layout;
    import sparkles.ui.style : BorderStyle, Decoration, defaultTwoslashPalette;

    // The `.twoslash-hover` token: a bottom-only dotted border, no background fill,
    // `paintBackground` false — the decorated box op must still be emitted.
    auto b = Builder();
    const tok = b.add(Widget(kind: WidgetKind.box, slot: Slot.code,
        decoration: Decoration(borderWidth: Insets(0, 0, 1, 0),
            borderStyle: BorderStyle.dotted, borderSlot: Slot.code)));
    auto tree = b.finish(tok);

    const pal = defaultTwoslashPalette();
    auto ops = buildDisplayList(tree, layout(tree), pal,
        RgbColor(0x22, 0x22, 0x22), RgbColor(0xff, 0xff, 0xff));

    assert(ops.length == 1 && ops[0].kind == OpKind.fillRect);
    assert(!ops[0].visual.hasBg); // border-only, no fill
    assert(ops[0].visual.border.any && ops[0].visual.border.style == BorderStyle.dotted);
    assert(ops[0].visual.border.width == Insets(0, 0, 1, 0));
}

@("ui.display_list.buildIntoASinkMatchesTheArray")
@safe
unittest
{
    import sparkles.base.buffer : SharedBuffer;
    import sparkles.ui.geometry : Insets;
    import sparkles.ui.layout : layout;
    import sparkles.ui.style : defaultTwoslashPalette, Slot;
    import sparkles.ui.widget : Builder, Widget, WidgetKind;

    auto b = Builder();
    const t = b.add(Widget(kind: WidgetKind.text, text: "hi", slot: Slot.code));
    const box = b.container(WidgetKind.popup, [t], slot: Slot.surface,
        padding: Insets.all(1), paintBackground: true);
    auto tree = b.finish(box);

    const pal = defaultTwoslashPalette();
    const fg = RgbColor(255, 255, 255), bg = RgbColor(0, 0, 0);
    auto frames = layout(tree);

    // The sink path is the same walk: op for op, the two agree.
    auto viaArray = buildDisplayList(tree, frames, pal, fg, bg);

    CmdBuffer viaSink;
    buildDisplayListInto(tree, frames, pal, fg, bg, viaSink);

    assert(viaSink.length == viaArray.length);
    foreach (i; 0 .. viaArray.length)
    {
        assert(viaSink.ops[i].kind == viaArray[i].kind);
        assert(viaSink.ops[i].rect == viaArray[i].rect);
        assert(viaSink.ops[i].visual == viaArray[i].visual);
        assert(viaSink.ops[i].text == viaArray[i].text);
    }

    // A reused sink is the point: reset and refilled, it yields the same
    // frame again without allocating a second array — and its text is the new
    // frame's, interned afresh into the same arena bytes.
    viaSink.reset();
    buildDisplayListInto(tree, frames, pal, fg, bg, viaSink);
    assert(viaSink.length == viaArray.length);
    assert(viaSink.ops[$ - 1].text == viaArray[$ - 1].text);
}

@("ui.display_list.sinkPathIsNogc")
@safe
unittest
{
    // The requirement `NFR2` actually states, proved at compile time: with a
    // `CmdBuffer` sink the whole walk allocates nothing — text included, which
    // is new. A function that returns an array can never satisfy this, which
    // is why the sink form exists rather than a flag on the old one.
    static assert(__traits(compiles, () @nogc {
        WidgetTree tree;
        Frame[] frames;
        Palette pal;
        CmdBuffer ops;
        buildDisplayListInto(tree, frames, pal,
            RgbColor(0, 0, 0), RgbColor(0, 0, 0), ops);
    }), "the CmdBuffer sink path must be @nogc");

    // And it stays `@safe` — the seam is a sink, not a pointer.
    static assert(__traits(compiles, () @safe {
        WidgetTree tree;
        Frame[] frames;
        Palette pal;
        CmdBuffer ops;
        buildDisplayListInto(tree, frames, pal,
            RgbColor(0, 0, 0), RgbColor(0, 0, 0), ops);
    }));
}

@("ui.display_list.anOwnedRuleResolvesTheBorderSlot")
@safe unittest
{
    // `SCV11`: a bar that owns its rule IS a border, so its track resolves
    // `Slot.border`; one in a reserved lane resolves `Slot.track`, which
    // exists to dim a hover affordance sitting under a thumb.
    //
    // The two were not merely different shades — they were a BACKEND
    // DISAGREEMENT. The cell target paints a bar's track glyph
    // unconditionally, so it overpainted the fence's border run and showed the
    // track colour; the pixel target painted no idle track at all, so it
    // showed the border run underneath. One fence, two colours, depending on
    // where you looked at it.
    import std.sumtype : match;

    import sparkles.ui.canvas : Scrollbar;
    import sparkles.ui.layout : layout;
    import sparkles.ui.style : Decoration, Palette, resolveVisual, TextStyle;
    import sparkles.ui.widget : Builder, Widget, WidgetKind;

    static RgbColor trackFgOf(bool owned)
    {
        auto b = Builder();
        const bar = b.add(Widget(kind: WidgetKind.scrollbar,
            barContent: 100, barViewport: 10, barPaintsIdleTrack: owned));
        auto tree = b.finish(bar);
        auto ops = buildDisplayList(tree, layout(tree), Palette.init,
            RgbColor(0, 0, 0), RgbColor(255, 255, 255));
        RgbColor found;
        bool seen;
        foreach (op; ops)
            op.match!((in Scrollbar s) { found = s.trackColor; seen = true; },
                (in _) {});
        assert(seen, "the bar emitted no scrollbar operation");
        return found;
    }

    const pal = Palette.init;
    const border = resolveVisual(pal, Slot.border, Decoration.init,
        TextStyle.init, RgbColor(0, 0, 0), RgbColor(255, 255, 255)).fg;
    const track = resolveVisual(pal, Slot.track, Decoration.init,
        TextStyle.init, RgbColor(0, 0, 0), RgbColor(255, 255, 255)).fg;

    assert(trackFgOf(true) == border, "an owned rule is border-coloured");
    assert(trackFgOf(false) == track, "a lane bar keeps the track slot");
}

@("ui.displayList.image.laysOutAsABoxAndEmitsOneOp")
@safe unittest
{
    import std.algorithm : filter;
    import std.array : array;
    import sparkles.ui.image : defaultCellPixels, ImageFit, ImageRegistry;
    import sparkles.ui.geometry : Size;
    import sparkles.ui.layout : layout;
    import sparkles.ui.style : defaultTwoslashPalette;
    import sparkles.ui.widget : Builder;

    // The view registers once; the tree it rebuilds carries a handle (`IMG3`).
    ImageRegistry reg;
    const chart = reg.register(null, Size(64, 48), "quarterly revenue");

    auto b = Builder();
    const img = b.add(Widget(
        kind: WidgetKind.image,
        image: chart,
        imagePixels: reg.sizeOf(chart),
        imageFit: ImageFit.contain,
        text: "quarterly revenue",
    ));
    const caption = b.add(Widget(kind: WidgetKind.text, text: "Fig. 1"));
    const col = b.container(WidgetKind.column, [img, caption]);
    auto tree = b.finish(col);

    const frames = layout(tree);

    // `IMG2`: an ordinary box, sized from pixels through the cell metrics —
    // 64x48 over an 8x16 cell is 8x3, and the caption sits below it rather
    // than on top of it, which is the whole of "participates in layout".
    assert(defaultCellPixels == Size(8, 16));
    assert(frames[img].rect == Rect(0, 0, 8, 3));
    assert(frames[caption].rect.y == 3);
    // The column is as wide as the image, not as the six-cell caption.
    assert(frames[col].rect.width == 8);

    const pal = defaultTwoslashPalette();
    auto ops = buildDisplayList(tree, frames, pal,
        RgbColor(0, 0, 0), RgbColor(255, 255, 255));

    const images = ops.filter!(o => o.kind == OpKind.image).array;
    assert(images.length == 1);
    assert(images[0].rect == Rect(0, 0, 8, 3));
    assert(images[0].imageHandle == chart);
    assert(images[0].imageFit == ImageFit.contain);
    assert(images[0].imageAlt == "quarterly revenue",
        "the node's text is the alt, interned by the buffer");
}

@("ui.displayList.effect.bracketsTheSubtreeAndNeverMovesIt")
@safe unittest
{
    import std.algorithm : filter, map;
    import std.array : array;
    import sparkles.ui.effect : Builtin, EffectRegistry;
    import sparkles.ui.layout : layout;
    import sparkles.ui.style : defaultTwoslashPalette;
    import sparkles.ui.widget : Builder;

    EffectRegistry reg;
    alias builtin = Builtin;

    uint[] build(ref Builder b, bool withEffect)
    {
        const a = b.add(Widget(kind: WidgetKind.text, text: "alpha"));
        const c = b.add(Widget(kind: WidgetKind.text, text: "beta"));
        const inner = b.container(WidgetKind.column, [a, c]);
        Widget panelW = Widget(kind: WidgetKind.panel, children: [inner],
            slot: Slot.surface, paintBackground: true);
        if (withEffect)
            panelW.effect = builtin.dim;
        const panel = b.add(panelW);
        const after = b.add(Widget(kind: WidgetKind.text, text: "outside"));
        return [b.add(Widget(kind: WidgetKind.column, children: [panel, after]))];
    }

    auto plainB = Builder();
    auto plainTree = plainB.finish(build(plainB, false)[0]);
    auto fxB = Builder();
    auto fxTree = fxB.finish(build(fxB, true)[0]);

    // `EFX6`: turning an effect on cannot reflow the page. The geometry is
    // decided before the effect is known, so every frame must be identical.
    const plainFrames = layout(plainTree);
    const fxFrames = layout(fxTree);
    assert(plainFrames.length == fxFrames.length);
    foreach (i; 0 .. plainFrames.length)
        assert(plainFrames[i].rect == fxFrames[i].rect);

    const pal = defaultTwoslashPalette();
    auto plainOps = buildDisplayList(plainTree, plainFrames, pal,
        RgbColor(0, 0, 0), RgbColor(255, 255, 255));
    auto fxOps = buildDisplayList(fxTree, fxFrames, pal,
        RgbColor(0, 0, 0), RgbColor(255, 255, 255));

    // `EFX5`: the bracket is emitted by the display list, so every consumer
    // sees it — exactly one pair, and only in the effected tree.
    assert(plainOps.filter!(o => o.kind == OpKind.pushEffect).empty);
    const pushes = fxOps.filter!(o => o.kind == OpKind.pushEffect).array;
    const pops = fxOps.filter!(o => o.kind == OpKind.popEffect).array;
    assert(pushes.length == 1 && pops.length == 1);
    assert(pushes[0].effectId == builtin.dim);

    // It carries the subtree's own rect, and brackets the node's OWN
    // background too — a dimmed panel whose fill stayed bright would not be
    // treating the subtree as what it looks like.
    const panelRect = pushes[0].rect;
    const bracketed = fxOps
        .filter!(o => o.kind != OpKind.pushEffect && o.kind != OpKind.popEffect)
        .array;
    assert(bracketed.length == plainOps.length,
        "the bracket adds ops, it does not change them");
    foreach (i; 0 .. plainOps.length)
        assert(bracketed[i].kind == plainOps[i].kind
            && bracketed[i].rect == plainOps[i].rect);

    // The "outside" run is emitted after the pop, not inside the bracket.
    size_t popAt, outsideAt;
    foreach (i, ref o; fxOps)
    {
        if (o.kind == OpKind.popEffect)
            popAt = i;
        if (o.kind == OpKind.textRun && o.text == "outside")
            outsideAt = i;
    }
    assert(outsideAt > popAt, "a sibling must not inherit the bracket");
    assert(panelRect.width > 0);
}

@("ui.display_list.richClustersShareLayoutPaintAndHitGeometry")
unittest
{
    import std.array : appender;
    import std.algorithm.searching : canFind;
    import sparkles.base.text.grapheme : visibleWidth;
    import sparkles.base.text.wrap_plan : WrapAffinity;
    import sparkles.ui.widget : Builder, TextSpan;
    import sparkles.ui.layout : layout;
    import sparkles.ui.style : defaultTwoslashPalette;
    import sparkles.ui.interp.cells : CellGrid;
    import sparkles.ui.interp.immediate : paint;
    import sparkles.ui.state : sourceOffsetAt, selectionRects;

    string longCluster = "a";
    foreach (_; 0 .. 48) longCluster ~= "\u0301";
    const expected = "界e\u0301🇺🇸👩‍💻" ~ longCluster;
    auto b = Builder();
    const id = b.add(Widget(kind: WidgetKind.rich, spans: [
        TextSpan("界e", Slot.code, srcStart: 0, srcEnd: 4),
        TextSpan("\u0301🇺", Slot.error, srcStart: 4, srcEnd: 10),
        TextSpan("🇸👩", Slot.docs, srcStart: 10, srcEnd: 18),
        TextSpan("\u200D💻", Slot.warn, srcStart: 18, srcEnd: 25),
        TextSpan(longCluster, Slot.code, srcStart: 25, srcEnd: expected.length),
    ]));
    const tree = b.finish(id);
    const frames = layout(tree);
    assert(frames[id].rect.width == 8);
    const ops = buildDisplayList(tree, frames, defaultTwoslashPalette(),
        RgbColor(255, 255, 255), RgbColor(0, 0, 0));
    auto emitted = appender!string();
    size_t advance;
    foreach (ref const op; ops)
        if (op.kind == OpKind.textRun)
        {
            emitted.put(op.text);
            assert(op.rect.width == visibleWidth(op.text));
            advance += op.rect.width;
        }
    assert(emitted.data == expected && advance == 8);
    auto grid = CellGrid(8, 1, RgbColor(255, 255, 255), RgbColor(0, 0, 0));
    paint(grid, ops);
    auto ansi = appender!string();
    grid.writeAnsi(ansi);
    assert(visibleWidth(ansi.data) == 8);
    foreach (cluster; ["界", "e\u0301", "🇺🇸", "👩‍💻", longCluster])
        assert(ansi.data.canFind(cluster));
    assert(sourceOffsetAt(tree, frames, Point(1, 0), WrapAffinity.before) == 0);
    assert(sourceOffsetAt(tree, frames, Point(1, 0), WrapAffinity.after) == 3);
    assert(sourceOffsetAt(tree, frames, Point(4, 0), WrapAffinity.before) == 6);
    assert(sourceOffsetAt(tree, frames, Point(4, 0), WrapAffinity.after) == 14);
    assert(selectionRects(tree, frames, 4, 6) == [Rect(2, 0, 1, 1)]);
}

@("ui.display_list.transformedSourceRelationDoesNotSplitRichFlag")
unittest
{
    import sparkles.base.text.wrap_plan : ProvenanceKind, WrapAffinity;
    import sparkles.ui.widget : Builder, TextSpan;
    import sparkles.ui.layout : layout;
    import sparkles.ui.style : defaultTwoslashPalette;
    import sparkles.ui.state : sourceOffsetAt, selectionRects;
    auto b = Builder();
    const id = b.add(Widget(kind: WidgetKind.rich, spans: [
        TextSpan("🇺", Slot.code, srcStart: 100, srcEnd: 120,
            sourceRelation: ProvenanceKind.replacement),
        TextSpan("🇸", Slot.warn, srcStart: 120, srcEnd: 140,
            sourceRelation: ProvenanceKind.replacement),
    ]));
    const tree = b.finish(id);
    const frames = layout(tree);
    const ops = buildDisplayList(tree, frames, defaultTwoslashPalette(),
        RgbColor(255, 255, 255), RgbColor(0, 0, 0));
    assert(ops.length == 1 && ops[0].text == "🇺🇸" && ops[0].rect.width == 2);
    assert(sourceOffsetAt(tree, frames, Point(1, 0), WrapAffinity.before) == 100);
    assert(sourceOffsetAt(tree, frames, Point(1, 0), WrapAffinity.after) == 140);
    assert(selectionRects(tree, frames, 110, 130) == [Rect(0, 0, 2, 1)]);
}

@("ui.display_list.wideGlyphExtentAndNarrowClipping")
unittest
{
    import sparkles.ui.widget : Builder;
    import sparkles.ui.layout : layout;
    import sparkles.ui.geometry : SizeSpec;
    import sparkles.ui.style : defaultTwoslashPalette;
    auto b = Builder();
    const glyph = b.add(Widget(kind: WidgetKind.glyph, glyph: '界'));
    const next = b.add(Widget(kind: WidgetKind.text, text: "x"));
    auto tree = b.finish(b.container(WidgetKind.row, [glyph, next]));
    auto frames = layout(tree);
    assert(frames[glyph].rect.width == 2 && frames[next].rect.x == 2);
    auto ops = buildDisplayList(tree, frames, defaultTwoslashPalette(),
        RgbColor(255, 255, 255), RgbColor(0, 0, 0));
    assert(ops[0].rect.width == 2 && ops[1].rect.x == 2);
    auto narrow = Builder();
    const wide = narrow.add(Widget(kind: WidgetKind.glyph, glyph: '界'));
    tree = narrow.finish(narrow.add(Widget(kind: WidgetKind.column,
        children: [wide], width: SizeSpec.fixed(1))));
    frames = layout(tree);
    ops = buildDisplayList(tree, frames, defaultTwoslashPalette(),
        RgbColor(255, 255, 255), RgbColor(0, 0, 0));
    foreach (ref const op; ops) assert(op.kind != OpKind.glyph);
}

@("ui.display_list.unwrappedTextHonorsMandatoryRowsAndZeroCapacity")
unittest
{
    import sparkles.ui.widget : Builder;
    import sparkles.ui.layout : layout;
    import sparkles.ui.geometry : Constraints;
    import sparkles.ui.style : defaultTwoslashPalette;
    auto b = Builder();
    const id = b.add(Widget(kind: WidgetKind.text, text: "界\n\ne\u0301"));
    const tree = b.finish(id);
    auto frames = layout(tree);
    assert(frames[id].rect.width == 2 && frames[id].rect.height == 3);
    auto ops = buildDisplayList(tree, frames, defaultTwoslashPalette(),
        RgbColor(255, 255, 255), RgbColor(0, 0, 0));
    assert(ops[0].text == "界" && ops[0].rect.width == 2);
    assert(ops[1].text == "" && ops[1].rect.y == 1);
    assert(ops[2].text == "e\u0301" && ops[2].rect.y == 2);
    frames = layout(tree, Constraints(maxW: 0));
    ops = buildDisplayList(tree, frames, defaultTwoslashPalette(),
        RgbColor(255, 255, 255), RgbColor(0, 0, 0));
    foreach (ref const op; ops)
        if (op.kind == OpKind.textRun) assert(op.text == "" && op.rect.width == 0);
}

/**
The scrollbar glyph the theme's thumb family draws (`GLY1`): a widget that set its
own glyph keeps it; one that left the default (`█` over `│`) takes the family's.
*/
private dchar thumbFamilyGlyph(ThumbFamily family, dchar widgetGlyph, bool thumb)
    @safe pure nothrow @nogc
{
    if (widgetGlyph != (thumb ? '█' : '│'))
        return widgetGlyph;
    final switch (family)
    {
        case ThumbFamily.block: return thumb ? '█' : '│';
        case ThumbFamily.shade: return thumb ? '▓' : '░';
        case ThumbFamily.line:  return thumb ? '┃' : '│';
    }
}

@("ui.display_list.thumbFamilyDrawsDefaultsOnly")
@safe pure nothrow @nogc unittest
{
    assert(thumbFamilyGlyph(ThumbFamily.block, '█', true) == '█');
    assert(thumbFamilyGlyph(ThumbFamily.shade, '█', true) == '▓');
    assert(thumbFamilyGlyph(ThumbFamily.shade, '│', false) == '░');
    assert(thumbFamilyGlyph(ThumbFamily.line, '█', true) == '┃');
    assert(thumbFamilyGlyph(ThumbFamily.shade, '■', true) == '■', "a widget's own glyph wins");
}
