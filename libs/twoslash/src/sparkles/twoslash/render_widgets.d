/**
The $(MREF sparkles,ui) view of a twoslash overlay — the bridge from the
backend-agnostic node model ($(REF TwoslashReturn, sparkles,twoslash,protocol))
to a $(REF WidgetTree, sparkles,ui,widget) every canvas backend (raylib GUI,
interactive TUI, and eventually SSG HTML) can lay out and paint identically.

Two views, both `@safe`:

$(LIST
    * $(LREF viewTwoslash) — the $(B below-line meta overlay): a column of
        per-node blocks (error message, `^?` query signature, completion list,
        `// @tag` line), each indented to its source column and carrying the
        semantic $(REF Slot, sparkles,ui,style). This is the shared model behind
        the ANSI meta-lines and the GUI's below-code chrome.
    * $(LREF viewHoverPopup) — a floating $(B hover/query popup): a surfaced
        panel with the (prefix-stripped) type signature over its JSDoc `docs`
        and `@tag`s.
)

Every widget derived from node $(D i) carries `hitId == i + 1` (0 means
"not hit-testable"), so $(REF HoverState, sparkles,ui,state) maps a pointer back
to the originating node. Colors are $(I not) chosen here — a widget names a slot,
and the palette ($(REF defaultTwoslashPalette, sparkles,ui,style)) resolves it,
so the GUI/TUI/HTML share one source of truth. Type-signature re-highlighting
(per-token color) stays a backend concern; the widget model carries the raw
signature text under $(D Slot.code).
*/
module sparkles.twoslash.render_widgets;

import sparkles.base.term_color : RgbColor, toRgb;
import sparkles.base.term_style : UnderlineStyle;
import sparkles.source_view.code : applyTints, CodeViewOptions;
import sparkles.source_view.markdown : FenceScroll, MdViewTheme;
import sparkles.syntax.event : byStyledLine, HighlightEvent;
import sparkles.syntax.md.model : extractMarkdown, MdBlock, MdBlockKind, MdDoc,
    MdInline, MdInlineKind, Span;
import sparkles.syntax.theme : ResolvedTheme;
import sparkles.syntax.ts.injection : TsConfigCache;
import sparkles.syntax.ts.registry : GrammarRegistry;
import sparkles.twoslash.overlay : BelowBlock, errIsWarning,
    highlightSignature, planTwoslash, TwoslashPlan, withoutQuickinfoPrefix;
import sparkles.twoslash.protocol : Completion, Effects, Node, NodeType,
    SignatureLayout, TwoslashReturn;
import sparkles.twoslash.signature_layout : ExpandedRegions;
import sparkles.twoslash.icons : completionIconGlyph, tagIconGlyph;
import sparkles.ui.geometry : cellsOf, Insets, Point, Rect, Size, SizeSpec;
import sparkles.ui.layout : Frame;
import sparkles.ui.overlay.anchor : AnchorRect;
import sparkles.ui.overlay.place : Align, OverlayGeometry, place, Placement, Side;
import sparkles.ui.style : BorderStyle, BoxSide, Decoration, FontRole,
    opposite, Palette, Slot, TextStyle;
import sparkles.ui.widget : Builder, TextSpan, Widget, WidgetKind, WidgetTree;
import sparkles.ui.wrap : TextWrap;

@safe:

/// The canonical twoslash chrome metrics (border widths, radius, font scales,
/// arrow) — the palette's scalar defaults, read at compile time so the views
/// author the exact `twoslash.css` values without a runtime palette or literal
/// duplication. The CSS-lockstep test (W4) guards these against the stylesheet.
private enum M = Palette.init;

/// The hit id a widget derived from node `nodeIndex` carries (0 = none).
private size_t hitOf(size_t nodeIndex) pure nothrow @nogc => nodeIndex + 1;

/// A popup/surface decoration: a hairline border (`Slot.border`), the `4px`
/// corner radius, and a drop shadow — the shared chrome behind the hover popup,
/// the `^?` query line, and the completion list (all one surface rule in the CSS).
private Decoration surfaceDeco(bool arrow, int arrowOffset = 1) pure nothrow @nogc
    => Decoration(
        borderWidth: Insets.all(M.borderWidth),
        borderStyle: BorderStyle.solid,
        borderSlot: Slot.border,
        borderRadius: M.popupRadius,
        shadow: true,
        arrow: arrow,
        arrowOffset: arrowOffset,
    );

/// The always-on hover marker: a `1px dotted` bottom-only border colored from
/// `Slot.hoverUnderline` — the `.twoslash-hover` underline, on a border-only
/// (unfilled) box so it rides under the code text without tinting it.
private Decoration hoverUnderlineDeco() pure nothrow @nogc
    => Decoration(
        borderWidth: Insets(0, 0, M.borderWidth, 0),
        borderStyle: BorderStyle.dotted,
        borderSlot: Slot.hoverUnderline,
    );

/// A left accent bar (`3px solid`) — the `.twoslash-error-line` / `-tag-line`
/// marker, colored from `slot`. The block's translucent background comes from the
/// same slot via `paintBackground`.
private Decoration accentDeco(Slot slot) pure nothrow @nogc
    => Decoration(
        borderWidth: Insets(0, 0, 0, M.accentBorder),
        borderStyle: BorderStyle.solid,
        borderSlot: slot,
    );

/**
A type signature as resolved syntax-colored spans (`WGT6`): with a grammar
cache the widget model carries the per-token color itself, so no backend
overpaints the toolkit's output to re-highlight it — the hover popup and the
`^?` query line share this one mapping.
*/
TextSpan[] signatureSpans(ref TsConfigCache cache, scope const(char)[] language,
    scope const(ResolvedTheme)* theme, RgbColor pageFg,
    const(char)[] sig) @system
{
    import sparkles.base.buffer : SharedBuffer;
    import sparkles.syntax.event : byStyledSpan;

    if (!sig.length)
        return null;
    SharedBuffer!HighlightEvent ev;
    highlightSignature(cache, language, sig, ev);
    TextSpan[] spans;
    foreach (sp; byStyledSpan(ev[]))
    {
        const spec = (*theme)[sp.label];
        // The byte range is stamped, not left at `size_t.max`: the producer's
        // break offsets index this same text, so slicing a span by them needs
        // the two to share one coordinate system — and it is the identity
        // channel selection and copy already ride on.
        spans ~= TextSpan(sig[sp.start .. sp.end], Slot.code,
            TextStyle.init, fg: toRgb(spec.fg, pageFg), hasFg: true,
            srcStart: sp.start, srcEnd: sp.end);
    }
    return spans;
}

/**
The $(B whole) twoslash document as one widget tree (the `D11` composition
target): every source line is a rich run of resolved-color spans (the theme's
syntax channel, with the identity channel's byte offsets), inline decorations
are fused in as stacked overlays (a highlight's background tint under the
text, an error's wavy underline over it), and each below-line meta block sits
directly under its code line. Hover needs no extra machinery: nodes are
source-anchored (`Node.start`/`length`), so a backend maps a pointer to a node
through $(REF sourceOffsetAt, sparkles,ui,state) and gets the token's on-screen
geometry from $(REF selectionRects, sparkles,ui,state).
*/
/**
Layers one source line's inline decorations onto an already-built code row,
returning the row to place in the document (the row itself when the line has
no decorations, else a `stack` with tints and hover underlines beneath it and
error squiggles above).

This is the **line-source-agnostic seam** (`OVL8`): the caller supplies a row
widget and says which line of `tw.code` it shows, so an overlay is no longer
tied to "the twoslash document is the whole document". `viewTwoslashDocument`
is one caller; hue's diff view is the other, where a row shows one side of one
file.

Decorations are positioned in the row's $(I own) coordinates — a `stack` child
shares its parent's origin, so a caller that puts chrome beside the row makes
the layout engine move both together. This used to take a `columnOffset` that
every caller had to compute and thread, which is a layout concern leaking into
a view; the chrome is a sibling widget now
($(REF withGutter, sparkles,ui,components,gutter)) and the offset is gone.

Params:
    b = the builder the row was added to
    code = the row widget the decorations layer onto
    tw = the payload the plan came from (error levels are read from its nodes)
    plan = `planTwoslash(tw)`, hoisted by the caller so a multi-row render
        plans once
    line = the 0-based line of `tw.code` this row shows
*/
uint decorateCodeRow(ref Builder b, uint code, const TwoslashReturn tw,
    const ref TwoslashPlan plan, size_t line)
{
    import sparkles.ui.canvas : LineStyle;
    import sparkles.ui.geometry : Point, SizeSpec;

    uint[] under, over;
    foreach (ref const d; plan.inlineDecorations)
    {
        if (d.line != line)
            continue;
        const cols = cast(int) cellsOf(tw.code[d.start .. d.end]);
        const at = Insets(0, 0, 0, cast(int) d.character);
        if (d.kind == NodeType.highlight)
        {
            const tint = b.add(Widget(kind: WidgetKind.box,
                slot: Slot.highlight, paintBackground: true,
                width: SizeSpec.fixed(cols), height: SizeSpec.fixed(1)));
            under ~= b.container(WidgetKind.column, [tint], padding: at);
        }
        else if (d.kind == NodeType.hover)
        {
            // Discoverability: a hoverable token is marked by a permanent
            // dotted underline (the CSS `.twoslash-hover` bottom border),
            // baked into the prebuilt display list rather than drawn on
            // pointer motion. A border-only box paints no fill, so the code
            // text above it is untouched; the TUI degrades the bottom-only
            // dotted border to a dotted cell underline.
            const rule = b.add(Widget(kind: WidgetKind.box,
                slot: Slot.hoverUnderline, paintBackground: false,
                decoration: hoverUnderlineDeco(),
                width: SizeSpec.fixed(cols), height: SizeSpec.fixed(1)));
            under ~= b.container(WidgetKind.column, [rule], padding: at);
        }
        else if (d.kind == NodeType.error)
        {
            const n = tw.nodes[d.node];
            const slot = errIsWarning(n.level) ? Slot.warn : Slot.error;
            const wavy = b.add(Widget(kind: WidgetKind.line, slot: slot,
                lineStyle: LineStyle.wavy, lineTo: Point(cols, 0)));
            over ~= b.container(WidgetKind.column, [wavy], padding: at);
        }
    }

    return under.length || over.length
        ? b.container(WidgetKind.stack, under ~ code ~ over)
        : code;
}

/**
The whole twoslash document: code lines as resolved spans, fused decorations,
and the interleaved below-line blocks.

`decorations` carries the same per-line gutter and byte-range tint channels
$(REF viewCodeDocument, sparkles,syntax,render,widgets) takes, so an overlay
attached to the source survives the switch to this view. Live D types turn it
on asynchronously — a payload lands a second or two after the file opens — and
before this the coverage gutter simply disappeared at that moment, because the
two producers rendered the same file and only one of them knew about it.
*/
WidgetTree viewTwoslashDocument(const TwoslashReturn tw,
    const(HighlightEvent)[] events, scope const(ResolvedTheme)* theme,
    RgbColor pageFg, TsConfigCache* cache = null, int maxWidth = 0,
    CodeViewOptions decorations = CodeViewOptions.init)
{
    auto b = Builder();
    return b.finish(viewTwoslashDocumentInto(b, tw, events, theme, pageFg,
        cache, maxWidth, decorations));
}

/**
As $(LREF viewTwoslashDocument), but appended to an existing builder — so a
caller can compose around the document after laying it out (a file gutter is
built from the rows, which do not exist until then).
*/
uint viewTwoslashDocumentInto(ref Builder b, const TwoslashReturn tw,
    const(HighlightEvent)[] events, scope const(ResolvedTheme)* theme,
    RgbColor pageFg, TsConfigCache* cache = null, int maxWidth = 0,
    CodeViewOptions decorations = CodeViewOptions.init)
{
    import sparkles.ui.canvas : LineStyle;
    import sparkles.ui.geometry : Point, SizeSpec;

    auto plan = planTwoslash(tw);

    // With a grammar cache, a `^?` query's type signature renders as resolved
    // syntax-colored spans — the widget model carries the color, so no backend
    // overpaints the toolkit's output to re-highlight it (`WGT6`).
    TextSpan[] sigSpans(const Node n) @trusted
        => cache is null || n.type != NodeType.query ? null
            : signatureSpans(*cache, tw.effectiveLanguage, theme, pageFg, n.text);

    // Styled runs bucketed per source line, as identity-carrying spans.
    size_t total = 1;
    foreach (ch; tw.code)
        if (ch == '\n')
            ++total;
    auto spansByLine = new TextSpan[][](total);
    foreach (ls; byStyledLine(tw.code, events))
    {
        if (ls.line >= total)
            continue;
        const spec = (*theme)[ls.span.label];
        spansByLine[ls.line] ~= TextSpan(
            tw.code[ls.span.start .. ls.span.end], Slot.code,
            TextStyle.init, fg: toRgb(spec.fg, pageFg), hasFg: true,
            srcStart: ls.span.start, srcEnd: ls.span.end);
    }

    uint[] rows;
    foreach (line; 0 .. total)
    {
        auto spans = spansByLine[line].length ? spansByLine[line]
            : [TextSpan(" ")];
        spans = applyTints(spans, decorations.tintedRanges);
        const code = b.add(Widget(kind: WidgetKind.rich, spans: spans,
            slot: Slot.code));

        // Nothing here knows how far the code sits from the left edge, and
        // nothing needs to: the decorations are `stack` children of the code
        // row, `withGutter` makes that row a child of a `row`, and the layout
        // engine places both. A below-line block is its own row and takes a
        // blank strip of the same width, so its caret stays under the token.
        rows ~= decorateCodeRow(b, code, tw, plan, line);

        foreach (ref const blk; plan.belowBlocks)
            if (blk.line == line)
                rows ~= buildBelowBlock(b, tw.nodes[blk.node], blk.node,
                    sigSpans(tw.nodes[blk.node]), maxWidth);
    }

    return b.container(WidgetKind.column, rows);
}

/**
Builds the below-line meta overlay for `tw`: a `column` of per-node blocks in
plan order (by source line, then node order), each indented to its source
column. Mirrors the ANSI renderer's below-line blocks, so the GUI and TUI grow
the same chrome from one model.
*/
WidgetTree viewTwoslash(const TwoslashReturn tw)
{
    auto plan = planTwoslash(tw);
    auto b = Builder();

    uint[] blocks;
    foreach (ref const blk; plan.belowBlocks)
        blocks ~= buildBelowBlock(b, tw.nodes[blk.node], blk.node);

    // A childless column is a well-formed empty overlay.
    const col = b.container(WidgetKind.column, blocks);
    return b.finish(col);
}

/**
Builds a single below-line block (node `nodeIndex`) as its own `WidgetTree` — the
error message, `^?` query, completion list, or `// @tag` line, indented to its
source column. Used by an interleaved renderer (the interactive terminal overlay)
that places each block directly under its code line instead of stacking them all.
*/
WidgetTree viewBelowBlock(const TwoslashReturn tw, size_t nodeIndex,
    int maxWidth = 0)
in (nodeIndex < tw.nodes.length)
{
    auto b = Builder();
    const root = buildBelowBlock(b, tw.nodes[nodeIndex], nodeIndex,
        maxWidth: maxWidth);
    return b.finish(root);
}

/// One below-line block: a left-indented `column` of a caret row + payload.
/// `sigSpans` (when non-empty) replaces a query signature's single-color text
/// with resolved syntax-colored spans.
///
/// Indented to its source column and nothing else. The caller gives the block
/// a blank gutter strip of the same width as the code rows above, so the caret
/// lands under its token without this knowing what that width is.
private uint buildBelowBlock(ref Builder b, const Node node, size_t nodeIndex,
    TextSpan[] sigSpans = null, int maxWidth = 0)
{
    const indent = Insets(0, 0, 0, cast(int) node.character);
    const hit = hitOf(nodeIndex);

    final switch (node.type)
    {
        case NodeType.error:
            const slot = errIsWarning(node.level) ? Slot.warn : Slot.error;
            const width = node.length ? node.length : 1;
            const caret = b.add(Widget(kind: WidgetKind.text,
                text: repeatCaret(width), slot: slot, hitId: hit));
            const msg = b.add(Widget(kind: WidgetKind.text, text: node.text,
                slot: slot, hitId: hit));
            // The message sits in an accent block: a 3px left bar + a translucent
            // background tint (CSS `.twoslash-error-line` / `-warn-line`).
            const block = b.add(Widget(kind: WidgetKind.panel, slot: slot,
                paintBackground: true, decoration: accentDeco(slot),
                padding: Insets.symmetric(0, 1), children: [msg], hitId: hit));
            return b.container(WidgetKind.column, [caret, block], padding: indent);

        case NodeType.query:
            const caret = b.add(Widget(kind: WidgetKind.text,
                text: "^?", slot: Slot.caret, hitId: hit));
            // The query line breaks like the popup does — the same signature,
            // shown in place instead of floating. What it has is the room left
            // to the right of its own indent.
            auto qWidth = SizeSpec.fit_;
            const avail = maxWidth - cast(int) node.character;
            if (maxWidth > 0 && avail > 0)
                qWidth.max = avail;
            auto rows = signatureBlock(b, node, hit,
                HoverViewOptions(maxWidth: avail > 0 ? avail : 0, sigSpans: sigSpans),
                TextStyle.init, qWidth,
                maxWidth > 0 ? TextWrap.greedy : TextWrap.none);
            return b.container(WidgetKind.column, caret ~ rows, padding: indent);

        case NodeType.completion:
            uint[] rows;
            rows ~= b.add(Widget(kind: WidgetKind.text,
                text: "^", slot: Slot.caret, hitId: hit));
            foreach (ref const Completion c; node.completions)
                rows ~= buildCompletionRow(b, c, node.completionsPrefix, hit);
            return b.container(WidgetKind.column, rows, padding: indent);

        case NodeType.tag:
            uint[] parts;
            // A tag-kind icon (⌗ log, ⚠ warn, ✗ error, ✎ annotate) then the `@name`
            // chip — mirroring the HTML `// @tag` line's icon.
            parts ~= b.add(Widget(kind: WidgetKind.text,
                text: tagIconGlyph(node.name), slot: Slot.info, hitId: hit));
            parts ~= b.add(Widget(kind: WidgetKind.text,
                text: tagName(b, node.name), slot: Slot.info, hitId: hit));
            if (node.text.length)
                parts ~= b.add(Widget(kind: WidgetKind.text, text: node.text,
                    slot: Slot.docs, hitId: hit));
            const row = b.container(WidgetKind.row, parts, gap: 1);
            // An accent block: a 3px left bar + bg tint (CSS `.twoslash-tag-line`).
            const block = b.add(Widget(kind: WidgetKind.panel, slot: Slot.info,
                paintBackground: true, decoration: accentDeco(Slot.info),
                padding: Insets.symmetric(0, 1), children: [row], hitId: hit));
            return b.container(WidgetKind.column, [block], padding: indent);

        case NodeType.hover:
        case NodeType.highlight:
            // Not below-line blocks (planTwoslash never emits them here); a bare
            // indented column keeps the switch total.
            return b.container(WidgetKind.column, [], padding: indent);
    }
}

/// A completion candidate row: a `-` marker then the name split into its matched
/// prefix (`Slot.matched`) and unmatched remainder (`Slot.unmatched`).
private uint buildCompletionRow(ref Builder b, const Completion c,
    scope const(char)[] prefix, size_t hit)
{
    const matchedLen = c.name.length >= prefix.length
        && c.name[0 .. prefix.length] == prefix ? prefix.length : 0;

    uint[] parts;
    // A per-kind completion icon (◰ class, ƒ method, ▪ property, …), matching the
    // HTML overlay's icon column; unknown kinds fall back to `•`.
    parts ~= b.add(Widget(kind: WidgetKind.text, text: completionIconGlyph(c.kind),
        slot: Slot.muted, hitId: hit));
    if (matchedLen)
        parts ~= b.add(Widget(kind: WidgetKind.text, text: c.name[0 .. matchedLen],
            slot: Slot.matched, hitId: hit));
    if (matchedLen < c.name.length)
        parts ~= b.add(Widget(kind: WidgetKind.text, text: c.name[matchedLen .. $],
            slot: Slot.unmatched, hitId: hit));
    return b.container(WidgetKind.row, parts, gap: 1);
}

/**
Builds a floating hover/query popup for node `nodeIndex` of `tw`: a `popup` panel
(surface background) over a `column` of the prefix-stripped signature, the JSDoc
`docs`, and any `@tag`s. The caller positions it (anchored above/below the
hovered token) — the tree is laid out at the origin.
*/
/**
The size $(B bound) to build a hover popup within — the theme's ceilings,
narrowed to the boundary the popup must live inside, floored at the theme's
minimums.

A bound, not a size: the popup's real extent comes from `layout()` working
inside this, so a view still never invents a width (`LAY10`). It is derived from
the $(B boundary) alone, deliberately — the room left at the anchor is the
solve's business, and the three hosts each computing their own `available`
(`grid.cols - anchor`, `width - rect.x - 1`, an anchor-relative pixel edge) is
half of the divergence `PLC4` retires.
*/
Size popupBound(in Palette pal, in Rect boundary) @safe pure nothrow @nogc
{
    static int fit(int ceiling, int room, int floor)
    {
        const capped = room < ceiling ? room : ceiling;
        return capped < floor ? floor : capped;
    }

    return Size(
        fit(pal.popupMaxWidth, boundary.width, pal.popupMinWidth),
        fit(pal.popupMaxHeight, boundary.height, pal.popupMinHeight));
}

/**
Where a twoslash hover popup goes — the placement policy, spelled $(B once).

This is what replaced `clampOrigin`, and the replacement is the point. That
function was one axis, one direction, against one scalar extent, clamped to `0`,
called from three sites that disagreed about the boundary (the whole grid, the
pane width, an anchor-relative pixel edge), about the vertical offset and about
whether to clip at all. Three applications were each guessing at a behavior the
toolkit did not define — `PRN8` violated in the most expensive way.

The clamp is to `boundary`, never to zero (`PLC4`). Zero is only correct when
the boundary starts at the surface origin, which a pane in a split does not.

$(B On `PLC9`.) The side is chosen here from the $(I measured) content rather
than from a bound. That is honest for today's popup, whose height is whatever
its content measures — there is no height budget to hand `layout()` yet, so a
decide-then-measure pass would have nothing to decide. It becomes load-bearing
when the popup body scrolls, and the two-pass shape is already expressible:
solve once against $(LREF popupBound), lay out inside the result, then solve
again with `lastGoodSide` pinned so the second pass cannot re-collide.
*/
OverlayGeometry placeHoverPopup(in Palette pal, in AnchorRect anchor,
    in Size content, in Rect boundary) @safe pure nothrow @nogc
    => place(popupPlacement(pal, boundary), anchor, content, boundary);

/// ditto — the second pass, with the budget pass's side pinned so it cannot
/// re-collide and cannot oscillate between two sides that each fit only the
/// other's measurement.
OverlayGeometry placeHoverPopup(in Palette pal, in AnchorRect anchor,
    in Size content, in Rect boundary, in OverlayGeometry budget)
    @safe pure nothrow @nogc
{
    auto req = popupPlacement(pal, boundary);
    req.lastGoodSide = budget.side;
    req.haveLastGood = budget.paintable;
    return place(req, anchor, content, boundary);
}

/// The popup's placement request, spelled once for both passes.
private Placement popupPlacement(in Palette pal, in Rect boundary)
    @safe pure nothrow @nogc
{
    auto req = Placement.init;
    req.minSize = Size(pal.popupMinWidth, pal.popupMinHeight);
    req.maxSize = popupBound(pal, boundary);
    // A hover popup hangs directly below the token it describes, with no gap
    // of its own: `TRG12` makes zero cells the default precisely so the pointer
    // can travel into the popup without crossing a corridor that belongs to
    // nobody. The caret's one cell of clearance is not such a corridor — it is
    // part of the popup, and the solve folds it in before testing the fit.
    req.side = Side.bottom;
    req.alignment = Align.start;
    req.arrow = true;
    return req;
}

/**
The room the popup may claim, decided $(B before) it is built (`PLC9`).

Ask the solve where a popup of the largest permitted size would go: whatever it
answers is the room this anchor actually has, on the side it actually has it.
Building the view at $(LREF popupBound) instead — the boundary's own size —
overstates the room whenever the anchor sits low in the pane, and the surplus
does not vanish quietly. The tree is laid out taller than the box the solve
later hands back, so the tail is clipped away unreachably, the viewport
measurement counts rows nobody can see, and the bar beside it runs off the
bottom edge describing a viewport that is not there.

Feed $(LREF OverlayGeometry.rect)'s size to `HoverViewOptions.maxWidth` /
`maxHeight`, then place the laid-out tree with the $(B five)-argument
$(LREF placeHoverPopup) so the second pass keeps this pass's side.
*/
OverlayGeometry popupBudget(in Palette pal, in AnchorRect anchor,
    in Rect boundary) @safe pure nothrow @nogc
    => placeHoverPopup(pal, anchor, popupBound(pal, boundary), boundary);

@("render_widgets.popupBudget.theRoomIsTheAnchorsNotThePanes")
@safe pure nothrow @nogc unittest
{
    const pal = Palette.init;
    const pane = Rect(0, 0, 80, 24);

    // High in the pane: everything below the token, less its caret's row.
    const high = popupBudget(pal,
        AnchorRect(primary: Rect(4, 0, 6, 1), live: true), pane);
    assert(high.paintable);
    assert(high.rect.height <= popupBound(pal, pane).height);
    assert(high.rect.bottom <= pane.bottom);

    // Low in the pane: it may not, and the difference is exactly the rows a
    // view built against `popupBound` would have laid out into nothing.
    const low = popupBudget(pal,
        AnchorRect(primary: Rect(4, 18, 6, 1), live: true), pane);
    assert(low.paintable);
    assert(low.rect.height < high.rect.height, "the room is the anchor's");
    assert(low.rect.bottom <= pane.bottom, "and it stays inside the pane");
}

@("render_widgets.popupBound.ceilingRoomAndFloor")
@safe pure nothrow @nogc unittest
{
    const pal = Palette.init;
    const wide = popupBound(pal, Rect(0, 0, 500, 400));
    assert(wide.width == pal.popupMaxWidth, "the ceiling holds");
    assert(wide.height == pal.popupMaxHeight);

    const narrow = popupBound(pal, Rect(0, 0, 40, 10));
    assert(narrow.width == 40, "room narrower than the ceiling wins");
    assert(narrow.height == 10);

    const tiny = popupBound(pal, Rect(0, 0, 3, 1));
    assert(tiny.width == pal.popupMinWidth, "never below the floor");
    assert(tiny.height == pal.popupMinHeight);
}

@("render_widgets.placeHoverPopup.clampsToThePaneNotToColumnZero")
@safe pure nothrow @nogc unittest
{
    // The regression `clampOrigin` could not express. In a split, the viewer
    // pane does not start at column 0 — and `clampOrigin(anchor, w, extent)`
    // clamped to `0`, so a popup wider than the room jumped across the divider
    // and painted over the explorer. Three call sites, three boundaries, one
    // shared bug.
    const pal = Palette.init;
    const pane = Rect(30, 0, 50, 24);          // the viewer, right of a divider
    const anchor = AnchorRect(primary: Rect(74, 4, 4, 1), live: true);

    const g = placeHoverPopup(pal, anchor, Size(60, 6), pane);
    assert(g.rect.x >= pane.x, "it stays inside the pane");
    assert(g.rect.x != 0, "column 0 is in the EXPLORER, not the viewer");
    // One row below the token's own row, plus the caret's clearance. `TRG12`
    // forbids an invented corridor between anchor and popup; the caret's row
    // is not one, since it is part of the popup and the solve folds it in
    // before testing the fit.
    assert(g.rect.y == 6, "below the token, with room for its caret");
    assert(g.arrowVisible, "and the caret points back at what it describes");

    // The old rule, reproduced, so the difference is visible rather than
    // described. `clampOrigin` took the far edge as a bare scalar and floored
    // at `0`: it has no way to express a boundary whose LEFT edge is 30, so it
    // slides the popup to column 20 — inside the explorer, across the divider.
    const over = 74 + 60 - 80;
    const oldRule = 74 - over < 0 ? 0 : 74 - over;
    assert(oldRule == 20 && oldRule < pane.x, "the old rule left the pane");
    assert(g.rect.x == pane.x, "the solve stops at the boundary it was given");
}

/**
What a backend knows about a hover popup that the view cannot work out for
itself.

Replaces the trailing `sigSpans` parameter rather than joining it: both
overloads already end in a defaulted argument, so a second one would make a
two-argument call ambiguous.
*/
struct HoverViewOptions
{
    /// Effective content width in cells; 0 leaves the popup unbounded, which
    /// is what every caller got before this existed. The backend passes
    /// `min(Palette.popupMaxWidth, room at the anchor)` — the view never
    /// invents a width (`LAY10`).
    int maxWidth = 0;

    /**
    The rows the placement solve granted this popup; `0` leaves it unbounded,
    which is what every caller got before this existed.

    A ddoc-heavy hover measures whatever it measures, and an unbounded popup
    simply runs off the surface — the reader loses the end of the sentence and
    has no way to reach it. Bounded, the body scrolls instead.
    */
    int maxHeight = 0;

    /// The body's vertical scroll offset, in rows. The HOST owns the machine
    /// (`SCV1`); the view only reads the offset, so one value serves a cell
    /// backend and a pixel one unchanged.
    long scrollOffset;

    /// The body's $(B horizontal) offset, in cells, for content that neither
    /// wraps nor scrolls itself — a wide table, say.
    long scrollOffsetX;

    /**
    How far every fenced code block in this popup is scrolled sideways.

    A fence is its OWN horizontal viewport: it clips its long lines rather than
    overflowing its parent, which is right for a document and is why the body's
    own horizontal offset never reaches one. So the offset has to go where the
    clip is, and $(LREF markdownDocsRows) hands it to each fence it finds.

    One offset for every fence in the popup, not one per fence: a hover shows
    one example at a time, and per-fence state would need hit-testing rows the
    host does not keep between frames — for a surface that is rebuilt whenever
    the pointer moves.
    */
    int fenceScrollX;

    /**
    Last frame's measurement, so this frame can draw bars.

    The extents come from `layout`, and the bars are part of the tree `layout`
    measures — so a bar can only ever describe the frame before it. That is the
    same one-frame lag every hit rect already has, and the reason a host feeds
    the numbers back rather than the view discovering them.
    */
    long barContent;
    long barViewport;   /// ditto
    long barContentX;   /// ditto — the widest fence, and the room it has
    long barViewportX;  /// ditto
    long barOffsetX;    /// ditto — the fence offset the thumb reports

    /**
    Whether to reveal the close affordance — the host says so when the pointer
    is over the popup.

    Its column is reserved $(B always), so revealing it does not reflow the
    signature the reader is looking at. That is the bargain the gallery's
    terminal tab list already makes for its own ✕, and the reason a
    hover-revealed control can sit inside content at all.
    */
    bool showClose;

    /// The signature as resolved syntax-colored spans (`signatureSpans`).
    TextSpan[] sigSpans;

    /// Whether the target can render non-ASCII marks. The theme states a
    /// preference (`GlyphSet.unicode`); a terminal that cannot render them
    /// overrides it, which is the backend's call, not the view's.
    bool unicode = true;

    /// Which collapsible runs of the signature are showing in full, by index
    /// into `Node.signature.abbrevs`. Absent means collapsed.
    ExpandedRegions expanded;

    /// Identity base for the expandable regions, so a click can name one.
    /// Distinct per popup; see `abbrevKey`.
    size_t nodeKey;

    /// Markdown chrome for the docs section: the document view's resolved
    /// colours and the fence-body highlighter. Without them a popup's ddoc
    /// renders as raw markdown — `### Examples` and the fence markers as
    /// literal text — while the same document renders it properly one pane
    /// over. Absent (`theme.present == false`) keeps the plain look.
    MdViewTheme mdTheme;

    /// ditto
    TextSpan[][] delegate(const(char)[] infoLang, const(char)[] body_) @safe
        fenceRenderer;
}

/// The key a collapsible region carries as its `Widget.key`, unique across the
/// popups a frame may hold.
size_t abbrevKey(size_t nodeKey, size_t region) @safe pure nothrow @nogc
    => ((nodeKey + 1) << 20) | (region + 1);

/**
The region reserved for the popup's own close affordance.

A click on the ✕ resolves through the $(B same) `Widget.key` channel a collapsed
run does, so a backend decodes one lookup rather than growing a second way for a
click inside a popup to mean something.
*/
private enum size_t closeRegion = 0xF_FFFE;

/// The key the close affordance carries.
size_t popupCloseKey(size_t nodeKey) @safe pure nothrow @nogc
    => abbrevKey(nodeKey, closeRegion);

/// Whether `key` names a close affordance rather than a collapsible run.
bool isPopupCloseKey(size_t key) @safe pure nothrow @nogc
    => key != 0 && abbrevRegion(key) == closeRegion;

/// ditto — the popup's own scrollbars, which a host must be able to grab.
private enum size_t vBarRegion = 0xF_FFFD;
private enum size_t hBarRegion = 0xF_FFFC;   /// ditto

/**
Which of the popup's scrollbars a `Widget.key` names, if either.

A bar is a $(B control), not decoration: a reader who can see that a popup
scrolls reaches for its thumb. Naming the bars through the same key channel the
✕ and the collapsed runs already use means a host decodes one lookup for every
click inside a popup, and gets the bar's rect from the same `keyTargets` list —
which is what a grab needs, because a thumb drag is track-relative.
*/
enum PopupBar : ubyte
{
    none,       /// the key names something else
    vertical,   /// the body's rows
    horizontal, /// the fences' columns
}

/// ditto
PopupBar popupBarOf(size_t key) @safe pure nothrow @nogc
{
    if (key == 0)
        return PopupBar.none;
    const r = abbrevRegion(key);
    return r == vBarRegion ? PopupBar.vertical
        : r == hBarRegion ? PopupBar.horizontal : PopupBar.none;
}

/// ditto — the key a given bar carries.
size_t popupBarKey(size_t nodeKey, PopupBar bar) @safe pure nothrow @nogc
in (bar != PopupBar.none)
    => abbrevKey(nodeKey,
        bar == PopupBar.vertical ? vBarRegion : hBarRegion);

/// The region a `Widget.key` names, undoing `abbrevKey`. Backends resolve a
/// click to a key and index `ExpandedRegions` — which is per signature — with
/// this; `abbrevNode` says which popup the key belonged to.
size_t abbrevRegion(size_t key) @safe pure nothrow @nogc
in (key != 0)
    => (key & 0xF_FFFF) - 1;

/// ditto
size_t abbrevNode(size_t key) @safe pure nothrow @nogc
in (key != 0)
    => (key >> 20) - 1;

@("render_widgets.abbrevKey.roundTrips")
@safe pure nothrow @nogc unittest
{
    // A key must name exactly one (popup, region) pair: the GUI resolves a
    // click to a key and has to get the region back out of it.
    foreach (node; 0 .. 4)
        foreach (region; 0 .. 4)
        {
            const k = abbrevKey(node, region);
            assert(abbrevNode(k) == node);
            assert(abbrevRegion(k) == region);
            assert(k != 0, "0 is reserved for `no key`");
        }
    assert(abbrevKey(0, 1) != abbrevKey(1, 0), "distinct pairs, distinct keys");
}

WidgetTree viewHoverPopup(const TwoslashReturn tw, size_t nodeIndex,
    HoverViewOptions opts = HoverViewOptions.init)
in (nodeIndex < tw.nodes.length)
{
    auto b = Builder();
    const node = tw.nodes[nodeIndex];
    if (!node.text.length && !node.docs.length && !node.tags.length)
        return WidgetTree.init; // lazy span: nothing to pop up (yet)
    const hit = hitOf(nodeIndex);
    // No grammar registry ⇒ docs render as plain newline-split lines (JSDoc `\n`
    // must not reach a backend as a literal control char). The `registry` overlay
    // below renders them as full markdown.
    const inner = popupInterior(opts.maxWidth);
    uint[] docsRows = node.docs.length
        ? plainDocsRows(b, node.docs, hit, inner) : null;
    uint[] tagRows;
    foreach (ref const string[] tag; node.tags)
        tagRows ~= buildPopupTag(b, tag, hit, inner);
    return finishHoverPopup(b, node, hit, docsRows, tagRows, opts);
}

/**
As above, but renders the JSDoc `docs` as $(B markdown) (bold / italic / inline
code / links / lists / fenced code, wrapped to the popup width) via the
`sparkles:syntax` `MdDoc` model driven by `registry` — the same markdown seam the
HTML backend uses. Falls back to plain newline-split lines when the markdown
grammars are unavailable, so docs never vanish. `@system` (the tree-sitter parse).
*/
WidgetTree viewHoverPopup(const TwoslashReturn tw, size_t nodeIndex,
    ref GrammarRegistry registry, HoverViewOptions opts = HoverViewOptions.init) @system
in (nodeIndex < tw.nodes.length)
{
    auto b = Builder();
    const node = tw.nodes[nodeIndex];
    if (!node.text.length && !node.docs.length && !node.tags.length)
        return WidgetTree.init; // lazy span: nothing to pop up (yet)
    const hit = hitOf(nodeIndex);
    const inner = popupInterior(opts.maxWidth);
    uint[] docsRows = node.docs.length
        ? markdownDocsRows(b, registry, node.docs, hit, inner, opts) : null;
    uint[] tagRows;
    foreach (ref const string[] tag; node.tags)
        tagRows ~= buildPopupTagMd(b, registry, tag, hit, inner);
    return finishHoverPopup(b, node, hit, docsRows, tagRows, opts);
}

/// Assembles the popup shell shared by both `viewHoverPopup` overloads: three
/// full-width sections — the signature (code face), the description (`docsRows`),
/// and the JSDoc tags (`tagRows`) — each separated by a horizontal divider (a top
/// border spanning border-to-border, CSS `.twoslash-popup-docs border-top`), all
/// inside the floating surface (border/radius/shadow/arrow). The popup carries no
/// horizontal padding so the dividers reach the edges; each section pads its own.
private WidgetTree finishHoverPopup(ref Builder b, const Node node, size_t hit,
    uint[] docsRows, uint[] tagRows, HoverViewOptions opts)
{
    // Signature (CSS `.twoslash-popup-code`): the code face at 1em — as
    // resolved syntax-colored spans when the caller supplied them
    // (signatureSpans), so no backend re-highlights over the painted popup.
    const sigStyle = TextStyle(fontRole: FontRole.code,
        fontScale: M.codeFontScale);
    // Capping the popup alone does not reflow an unwrappable child, so the
    // signature carries the cap itself. Breaking at spaces is a placeholder:
    // it keeps a 200-cell D signature inside the window today, and the
    // structural breaking that replaces it knows where the parameters are.
    auto sigWidth = SizeSpec.fit_;
    if (opts.maxWidth > 0)
        sigWidth.max = opts.maxWidth - 2 * M.popupPadX;
    const sigWrap = opts.maxWidth > 0 ? TextWrap.greedy : TextWrap.none;
    // With the producer's structure the signature breaks where D would break;
    // without it (a TypeScript payload, or a node predating the field) it is
    // one run and the space-wrapping above is all there is.
    const structured = node.signature != SignatureLayout.init;
    uint[] sigRows = signatureBlock(b, node, hit, opts, sigStyle, sigWidth, sigWrap);

    // The HEADER is the signature plus, for a function, the effect chips that
    // qualify it. `@safe pure nothrow @nogc` is part of what the signature SAYS
    // — a reader scrolled past it has lost half the declaration — so the two
    // are pinned together and the rule goes after them, not between them.
    uint[] header = [popupHeaderRow(b, sigRows, opts)];
    if (structured && node.signature.effects != Effects.init)
        header ~= popupSection(b,
            effectChips(b, node.signature.effects, hit, opts.unicode));

    // Everything below the header, each section preceded by its own rule.
    uint[] rest;
    if (docsRows.length)
        rest ~= popupSection(b, docsRows);
    if (tagRows.length)
    {
        if (rest.length)
            rest ~= popupRule(b);   // examples above, `@returns` below
        rest ~= popupSection(b, tagRows);
    }

    // The cap is a clamp on a `fit` box, so the popup still shrinks to its
    // content — it just stops growing past the room the backend reported.
    auto width = SizeSpec.fit_;
    if (opts.maxWidth > 0)
        width.max = opts.maxWidth;

    // The header never scrolls. It is the thing the reader anchored on, and
    // scrolling it out of view is the same failure as overflowing the surface —
    // the popup is still on screen and still useless. So the shell splits: a
    // pinned header, its rule, and everything else inside a viewport.
    // What the header costs the body: its rows, the rule under it, and the
    // popup's own vertical padding. Counted rather than assumed, because the
    // effect chips add a row only for a function.
    const headerRows = cast(int) header.length + (rest.length ? 1 : 0) + 2;
    const bodyRows = popupBodyRows(opts, headerRows);
    auto body = popupBody(b, rest, opts, bodyRows);
    if (body != invalidNode)
        body = withScrollbars(b, body, opts, bodyRows);
    uint[] stack = header;
    if (rest.length)
        stack ~= popupRule(b);
    stack ~= body == invalidNode ? rest : [body];
    const col = b.container(WidgetKind.column, stack);

    auto height = SizeSpec.fit_;
    if (opts.maxHeight > 0)
        height.max = opts.maxHeight;
    const popup = b.add(Widget(kind: WidgetKind.panel, slot: Slot.surface,
        width: width, height: height, padding: Insets(1, 0, 1, 0),
        paintBackground: true, decoration: surfaceDeco(arrow: true),
        children: [col], hitId: hit));
    return b.finish(popup);
}

/**
The header's first row: the signature, and the close affordance beside it.

The ✕ sits in the popup's top-right corner and its column is reserved whether or
not it shows, so revealing it on hover cannot reflow the declaration underneath.
It carries a `Widget.key` rather than a hit id because a click inside a popup is
already decoded through keys, and one channel is enough.
*/
private uint popupHeaderRow(ref Builder b, uint[] sigRows,
    in HoverViewOptions opts)
{
    const sig = b.add(Widget(kind: WidgetKind.column, children: sigRows,
        width: SizeSpec.grow(), stretch: true));
    const lane = opts.showClose
        ? b.add(Widget(kind: WidgetKind.text, text: "✕", slot: Slot.muted,
            key: popupCloseKey(opts.nodeKey)))
        : b.add(Widget(kind: WidgetKind.box, width: SizeSpec.fixed(1)));
    return b.add(Widget(kind: WidgetKind.row, children: [sig, lane],
        width: SizeSpec.grow(), stretch: true, gap: 1,
        padding: Insets(0, 1, 0, 1)));
}

/**
Points the popup's caret at what it describes.

The view declares that it $(I wants) a caret; where that caret goes is the
solve's answer, because it depends on which side the popup was placed on and how
far along that edge the anchor fell. So the tree is built first, placed, and
then told — between `layout` and the display list, which is the only window in
which both facts exist.

Without this a popup's caret sits wherever its `Decoration` was authored — cell
one of the top edge, always — so it pointed at the popup's own left corner
rather than at the token the reader was hovering.
*/
void applyPopupArrow(ref WidgetTree tree, in OverlayGeometry g)
    @safe pure nothrow @nogc
{
    if (!tree.nodes.length)
        return;
    auto n = &tree.nodes[tree.root];
    n.decoration.arrow = g.arrowVisible;
    // The OPPOSITE edge. `OverlayGeometry.side` names the edge of the ANCHOR
    // the popup attached to; `Decoration.arrowSide` names the edge of the BOX
    // the caret hangs off, and a popup hanging BELOW its anchor wears its
    // caret on its own TOP edge. Passing the side through unchanged points
    // every caret at the wrong edge, silently — the two enums are the same
    // type, so nothing complains.
    n.decoration.arrowSide = g.side.opposite;
    n.decoration.arrowOffset = g.arrowCell;
}

/// Not a node index any builder can return.
private enum uint invalidNode = uint.max;

/**
`view` with the bars its scrollable axes call for (`SCV`).

$(B A container that scrolls says so.) A viewport with no bar gives a reader no
way to know there is more, and no way to tell how much — which is the whole
complaint a clipped surface answers. The rows are the caller's measurement from
the previous frame, because the extents come from `layout` and the bars are
built before it; a first frame therefore shows none, and every frame after it
shows the truth.

The vertical bar rides a one-column gutter beside the body; the horizontal one a
one-row gutter beneath it. Both are $(B reserved unconditionally) while their
axis can scroll, so the body does not reflow as the reader moves through it.
*/
private uint withScrollbars(ref Builder b, uint view, in HoverViewOptions opts,
    int bodyRows)
{
    import sparkles.ui.components.chrome : scrollbar, ScrollbarSpec;
    import sparkles.ui.state : ScrollAxis;

    uint out_ = view;

    if (opts.barContent > opts.barViewport && bodyRows > 0)
    {
        // The track is the BODY's rows, which is what the bar stands beside.
        // A zero here is not a default — `scrollbar` reads it as the widget's
        // extent along its own axis, so the bar laid out one column wide and
        // zero rows tall: present in the tree, absent from the screen, and
        // absent from `keyTargets` too, because an empty rect is not hittable.
        const bar = scrollbar(b, ScrollbarSpec(
            content: opts.barContent, viewport: opts.barViewport,
            offset: opts.scrollOffset, axis: ScrollAxis.vertical,
            paintsIdleTrack: true,
            key: popupBarKey(opts.nodeKey, PopupBar.vertical)), bodyRows);
        out_ = b.add(Widget(kind: WidgetKind.row, children: [out_, bar],
            width: SizeSpec.grow()));
    }

    if (opts.barContentX > opts.barViewportX)
    {
        const bar = scrollbar(b, ScrollbarSpec(
            content: opts.barContentX, viewport: opts.barViewportX,
            offset: opts.barOffsetX, axis: ScrollAxis.horizontal,
            paintsIdleTrack: true,
            key: popupBarKey(opts.nodeKey, PopupBar.horizontal)), 1);
        // Its track is the popup's INTERIOR WIDTH, which no one knows before
        // layout: the shell is a `fit` box that shrinks to its content and
        // only caps at `maxWidth`. So the bar is told to grow instead, and the
        // width it ends up with is the one the display list paints and the one
        // a grab measures against — the same rect, by construction.
        b.nodes[bar].width = SizeSpec.grow();
        out_ = b.add(Widget(kind: WidgetKind.column, children: [out_, bar],
            width: SizeSpec.grow()));
    }
    return out_;
}

/**
How many rows the body gets: the cap, less the pinned header and the popup's own
padding. Zero when nothing capped the popup, which is also "there is no
viewport".

Computed $(B once) and handed to both the viewport and its bar. They must agree
on it exactly — the bar stands beside the body and a track of a different length
is a thumb that lies about where it is.
*/
private int popupBodyRows(in HoverViewOptions opts, int headerRows)
    @safe pure nothrow @nogc
{
    if (opts.maxHeight <= 0)
        return 0;
    // A floor of one keeps the viewport representable on a surface too short to
    // be useful, where the solve has already reported `refused` or `shrunk`.
    return opts.maxHeight - headerRows > 1 ? opts.maxHeight - headerRows : 1;
}

/**
The popup's scrolling body: everything below the signature, inside a clipped
viewport with a bar beside it.

Returns $(LREF invalidNode) when there is nothing to scroll — an unbounded
popup, or one whose whole content is its signature — so the caller keeps the
flat shell it had. A viewport that can never scroll is a gutter of wasted
columns and a clip nobody needs.

The engine does the arithmetic: a clipped axis keeps its children $(B natural)
(`layout`'s `noShrink` rule), so after one `layout()` the viewport's own frame
is the viewport and its child's frame is the full content extent. Neither is
guessed, and neither costs a second pass.
*/
private uint popupBody(ref Builder b, uint[] rest, in HoverViewOptions opts,
    int rows)
{
    if (rows <= 0 || rest.length == 0)
        return invalidNode;

    const content = b.container(WidgetKind.column, rest);
    // Clipped on BOTH axes. The vertical clip is what makes the body a
    // viewport; the horizontal one is what makes wide content that does not
    // clip itself reachable instead of merely truncated.
    const view = b.add(Widget(
        kind: WidgetKind.column,
        children: [content],
        height: SizeSpec.fixed(rows),
        width: SizeSpec.grow(),
        clipX: true,
        clipY: true,
        childOffset: Point(cast(int) opts.scrollOffsetX,
            cast(int) opts.scrollOffset),
    ));
    return view;
}

/**
What the popup's body can scroll over, read off the laid-out tree.

Deliberately not a `Widget.key`: `keyTargets` is the channel a click uses to
name a collapsed signature run, and keying the shell would put two more entries
in it — so "which run did I click" would stop meaning what it says. The body is
found structurally instead, as the one clipped container the shell builds.

`content` is the natural extent of what is inside the viewport and `viewport`
is the rows it shows, both straight from `frames`: a clipped axis keeps its
children natural (`layout`'s `noShrink` rule), so one `layout()` answers both
and neither is guessed.
*/
struct PopupScroll
{
    long content;   /// rows the body would need
    long viewport;  /// rows it has
    long contentX;  /// cells its widest row would need
    long viewportX; /// cells it has
    /// The widest fenced code block, and the room it has. A fence clips its own
    /// long lines rather than overflowing the body, so its overflow is
    /// invisible to the pair above and has to be reported separately.
    long fenceContentX;
    /// ditto
    long fenceViewportX;

@safe pure nothrow @nogc const:

    /// Whether there is anything to scroll vertically — the test a host makes
    /// before spending a gutter column on a bar.
    bool live() => content > viewport;
    /// Whether the BODY overflows sideways. Prose wraps and a fence clips
    /// itself, so this is about the rest: a wide table, mostly.
    bool liveX() => contentX > viewportX;
    /// Whether a fence overflows sideways — the usual reason a hover needs a
    /// horizontal bar at all.
    bool liveFenceX() => fenceContentX > fenceViewportX;
    /// The furthest a fence may be scrolled.
    long maxFenceX() => liveFenceX ? fenceContentX - fenceViewportX : 0;
}

/// ditto
PopupScroll popupScrollExtents(in WidgetTree tree, in Frame[] frames)
    @safe pure nothrow @nogc
in (frames.length == tree.nodes.length,
    "frames must be the layout of exactly this tree")
{
    PopupScroll sc;

    // The body is at a KNOWN position — the shell builds it as the last child
    // of the popup's column — so it is found structurally rather than by a
    // `Widget.key`. Keying it would add an entry to `keyTargets`, which is the
    // channel a click uses to name a collapsed signature run, and "which run
    // did I click" would stop meaning what it says.
    //
    // $(B Through the gutters.) Once the body scrolls, `withScrollbars` wraps
    // it — a row beside the vertical bar, a column above the horizontal one —
    // so the column's last child is a wrapper, not the viewport. Both wrappers
    // carry the viewport as their FIRST child, so the descent finds it either
    // way. Stopping at the wrapper is what made the measurement collapse to
    // zero on every frame a bar was up, which unbuilt the bar on the next one:
    // the popup flickered between having a bar and having none, and a fence's
    // sideways extent went with it.
    const root = tree.nodes[tree.root];
    uint body_ = uint.max;
    if (root.children.length == 1)
    {
        const col = tree.nodes[root.children[0]];
        if (col.children.length)
        {
            uint at = col.children[$ - 1];
            // At most the two gutters, so a malformed tree cannot loop.
            foreach (_; 0 .. 3)
            {
                if (tree.nodes[at].clipY && tree.nodes[at].children.length == 1)
                {
                    body_ = at;
                    break;
                }
                if (tree.nodes[at].children.length == 0)
                    break;
                at = tree.nodes[at].children[0];
            }
        }
    }
    if (body_ != uint.max)
    {
        const inner = tree.nodes[body_].children[0];
        sc.content = frames[inner].rect.height;
        sc.viewport = frames[body_].rect.height;
        sc.contentX = frames[inner].rect.width;
        sc.viewportX = frames[body_].rect.width;
    }

    // Every other clipping node is content that scrolls itself — a fence, a
    // table. The widest overflow is what a horizontal bar would represent.
    //
    // A fence's viewport holds ONE CHILD PER LINE, not a single content node:
    // its extent is the widest of them. Demanding a lone child (which is what
    // the popup body happens to have) matched no fence at all, so the sideways
    // extent read zero and a fence that plainly ran off the edge reported
    // nothing to scroll.
    foreach (i, ref const n; tree.nodes)
    {
        if (i == body_ || !n.clipX || n.children.length == 0)
            continue;
        const have = frames[i].rect.width;
        int want;
        foreach (c; n.children)
            if (frames[c].rect.width > want)
                want = frames[c].rect.width;
        if (want - have > sc.fenceContentX - sc.fenceViewportX)
        {
            sc.fenceContentX = want;
            sc.fenceViewportX = have;
        }
    }
    return sc;
}

/// The signature as rows: structural breaking when the producer described this
/// one, a single (optionally space-wrapped) run otherwise. Shared by the hover
/// popup and the `^?` query line so both break the same way.
private uint[] signatureBlock(ref Builder b, const Node node, size_t hit,
    HoverViewOptions opts, TextStyle sigStyle, SizeSpec sigWidth,
    TextWrap sigWrap)
{
    if (node.signature != SignatureLayout.init)
        return signatureRows(b, node, hit, opts, sigStyle, sigWidth, sigWrap);
    // A TypeScript payload, a node predating the field, or a tip whose text is
    // not a signature at all: one run, and the space-wrapping is all there is.
    return [opts.sigSpans.length
        ? b.add(Widget(kind: WidgetKind.rich, spans: opts.sigSpans, slot: Slot.code,
            hitId: hit, textStyle: sigStyle, width: sigWidth, wrap: sigWrap))
        : b.add(Widget(kind: WidgetKind.text,
            text: withoutQuickinfoPrefix(node.text), slot: Slot.code,
            hitId: hit, textStyle: sigStyle, width: sigWidth, wrap: sigWrap))];
}

/**
The signature as one widget per broken row, or a single row when it fits.

Slices the caller's styled spans by the producer's break offsets rather than
re-highlighting each row: a fragment like `ref T value,` parses differently
from a declaration, so per-row highlighting would change a token's colour with
the window width, and the staging tries several candidate layouts per frame.
Slicing also keeps `srcStart`/`srcEnd` exact, since `[s,k)` and `[k,e)` tile
the span they came from.
*/
private uint[] signatureRows(ref Builder b, const Node node, size_t hit,
    HoverViewOptions opts, TextStyle sigStyle, SizeSpec sigWidth,
    TextWrap sigWrap)
{
    import sparkles.twoslash.signature_layout : effectFreeRange, layoutSignature,
        SigRow;
    import sparkles.ui.geometry : cellsOf;

    const text = withoutQuickinfoPrefix(node.text);
    // The effect words are drawn as chips, so the rows stop at the body.
    const body_ = effectFreeRange(text, node.signature);
    const laid = layoutSignature(text, node.signature, opts.maxWidth,
        M.sigIndent, (scope const(char)[] s) => cast(int) cellsOf(s), body_,
        opts.expanded);

    uint[] rows;
    foreach (row; laid.rows)
    {
        // The indent is padding, not leading spaces: spaces would enter the
        // identity channel and land in a selection or a copy.
        const pad = Insets(0, row.indent, 0, 0);
        if (row.isLiteral)
        {
            rows ~= b.add(Widget(kind: WidgetKind.text, text: row.literal,
                slot: Slot.code, hitId: hit, textStyle: sigStyle,
                padding: pad, width: sigWidth, wrap: sigWrap));
            continue;
        }
        auto pieces = rowPieces(sliceSpans(opts.sigSpans, row.start, row.end),
            node.signature, opts, row.start, row.end);

        // The common case: nothing hidden on this row, so it is one run.
        if (pieces.length == 1 && pieces[0].marker.length == 0)
        {
            rows ~= pieces[0].spans.length
                ? b.add(Widget(kind: WidgetKind.rich, spans: pieces[0].spans,
                    slot: Slot.code, hitId: hit, textStyle: sigStyle,
                    padding: pad, width: sigWidth, wrap: sigWrap))
                : b.add(Widget(kind: WidgetKind.text,
                    text: text[pieces[0].from .. pieces[0].to], slot: Slot.code,
                    hitId: hit, textStyle: sigStyle, padding: pad,
                    width: sigWidth, wrap: sigWrap));
            continue;
        }

        uint[] parts;
        foreach (piece; pieces)
        {
            if (piece.marker.length)
            {
                parts ~= b.add(Widget(kind: WidgetKind.text, text: piece.marker,
                    slot: Slot.muted, hitId: hit, textStyle: sigStyle,
                    key: abbrevKey(opts.nodeKey, piece.region)));
                continue;
            }
            // Without a grammar cache there are no spans to slice, so the
            // piece falls back to its own range — never the row's, or the
            // collapse would be silently undone.
            parts ~= piece.spans.length
                ? b.add(Widget(kind: WidgetKind.rich, spans: piece.spans,
                    slot: Slot.code, hitId: hit, textStyle: sigStyle))
                : b.add(Widget(kind: WidgetKind.text,
                    text: text[piece.from .. piece.to], slot: Slot.code,
                    hitId: hit, textStyle: sigStyle));
        }
        rows ~= b.add(Widget(kind: WidgetKind.row, children: parts,
            padding: pad, hitId: hit));
    }
    return rows;
}

/**
One row's content, split where a collapsed run interrupts it.

A collapsed `…` has to be addressable on its own — a click must name the region
under the pointer, not the popup — and identity in this toolkit lives on a
widget (`Widget.key`), not on a span. So a row containing collapsed runs
becomes a horizontal row of widgets rather than one styled run. Rows without
any stay a single run, which is every row of a signature that has nothing worth
hiding.
*/
private struct RowPiece
{
    TextSpan[] spans;  /// visible text, when this is not a marker
    string marker;     /// the short form, when it is
    size_t region;     /// index into `abbrevs`, for the marker's key
    uint from;         /// the piece's own range — the fallback slices by this,
    uint to;           /// not by the row's, or a collapse would be undone
}

/// ditto
private RowPiece[] rowPieces(TextSpan[] spans, in SignatureLayout sig,
    HoverViewOptions opts, uint rowStart, uint rowEnd) @safe pure
{
    import sparkles.twoslash.signature_layout : isRegionExpanded;

    RowPiece[] out_;
    uint at = rowStart;
    foreach (i, a; sig.abbrevs)
    {
        if (isRegionExpanded(opts.expanded, i))
            continue;
        const from = a.offset, to = a.offset + a.length;
        if (to <= rowStart || from >= rowEnd)
            continue;

        if (from > at)
            out_ ~= RowPiece(spans: sliceSpans(spans, at, from), from: at, to: from);
        if (a.shortText.length)
            out_ ~= RowPiece(marker: a.shortText, region: i, from: from, to: to);
        at = to > rowEnd ? rowEnd : to;
    }
    if (at < rowEnd)
        out_ ~= RowPiece(spans: sliceSpans(spans, at, rowEnd), from: at, to: rowEnd);
    return out_;
}

/// The part of `spans` covering `[start, end)`, colours and identity intact.
private TextSpan[] sliceSpans(const(TextSpan)[] spans, uint start, uint end) @safe pure
{
    TextSpan[] out_;
    foreach (sp; spans)
    {
        if (sp.srcEnd <= start || sp.srcStart >= end)
            continue;
        const from = sp.srcStart >= start ? 0 : start - sp.srcStart;
        const to = sp.srcEnd <= end ? sp.text.length : end - sp.srcStart;
        if (from >= to)
            continue;
        TextSpan piece = sp;
        piece.text = sp.text[from .. to];
        piece.srcStart = sp.srcStart + from;
        piece.srcEnd = sp.srcStart + to;
        out_ ~= piece;
    }
    return out_;
}

/**
The effect attributes as chips: what the function $(I is not), as legibly as
what it is.

Memory safety is a tri-state, not a checkbox, so the reported `@safe` /
`@trusted` / `@system` is one always-present chip; `pure`, `nothrow` and
`@nogc` are a checked/unchecked trio, because "this is not `pure`" is as much
of an answer as the reverse.

An uninstantiated template is the case that would otherwise lie: its
attributes are inferred per instantiation, so a cross would claim the compiler
decided something it has not. Those render unmarked instead.
*/
private uint[] effectChips(ref Builder b, in Effects effects, size_t hit,
    bool unicode)
{
    uint[] chips;

    if (effects.trust.length)
        // A fresh copy, not a borrow: the widget outlives this frame's view of
        // the node.
        chips ~= chipWidget(b, effects.trust.idup, Slot.chip, hit);

    static struct Flag { string name; bool on; }
    const flags = [
        Flag("pure", effects.isPure),
        Flag("nothrow", effects.isNothrow),
        Flag("@nogc", effects.isNogc),
    ];
    foreach (f; flags)
    {
        const mark = effects.inferred
            ? (unicode ? "· " : "? ")
            : (f.on ? (unicode ? "✓ " : "+ ") : (unicode ? "✗ " : "- "));
        chips ~= chipWidget(b, mark ~ f.name,
            effects.inferred || !f.on ? Slot.muted : Slot.chip, hit);
    }
    return [b.container(WidgetKind.row, chips, gap: 1)];
}

/// The rounded pill `buildPopupTag` draws, shared with the effect row.
private uint chipWidget(ref Builder b, string text, Slot slot, size_t hit)
    => b.add(Widget(kind: WidgetKind.text, text: text, slot: slot, hitId: hit,
        paintBackground: slot != Slot.muted,
        decoration: Decoration(borderRadius: M.popupRadius),
        textStyle: TextStyle(fontRole: FontRole.code, fontScale: M.tagFontScale)));

/// A full-width popup section: a `stretch` column with its own horizontal padding
/// (`6px 8px` in the CSS) and, when `divider`, a 1px top border that — because the
/// section stretches to the popup width and the popup has no horizontal padding —
/// spans border-to-border as the section separator.
private uint popupSection(ref Builder b, uint[] rows)
    => b.add(Widget(kind: WidgetKind.column, children: rows, stretch: true,
        padding: Insets(0, 1, 0, 1)));

/**
A full-width horizontal rule — the popup's section divider.

$(B A one-row box with a BOTTOM border), which is the only spelling a cell
backend can draw: a cell has an underline attribute and no overline, so a
top-only border renders as nothing at all there. The dividers were top borders
on the following section, so they had never appeared in the terminal — only in
the GUI and HTML, where a top border is a real edge. This is the same widget
$(REF viewMarkdownInto, sparkles,source_view,markdown) emits for a `---`
thematic break, for the same reason.
*/
private uint popupRule(ref Builder b)
    => b.add(Widget(kind: WidgetKind.box, stretch: true,
        height: SizeSpec.fixed(1),
        decoration: Decoration(borderWidth: Insets(0, 0, M.borderWidth, 0),
            borderStyle: BorderStyle.solid, borderSlot: Slot.border)));

// ── JSDoc docs → widget rows (markdown, wrapped) ───────────────────────────

/**
Every fence in `doc`, at one shared horizontal offset.

A fence clips its own long lines, so the offset must reach the fence's viewport
rather than the popup's — and the view addresses fences by their body's source
start, which only the parsed document knows.
*/
private FenceScroll[] fenceScrollsOf(in MdDoc doc, int x) @safe
{
    if (x == 0)
        return null;   // the common case allocates nothing

    FenceScroll[] out_;
    void walk(in MdBlock blk)
    {
        if (blk.kind == MdBlockKind.codeFence)
            out_ ~= FenceScroll(bodyStart: blk.codeBody.start, x: x);
        foreach (ref const c; blk.children)
            walk(c);
    }

    walk(doc.root);
    return out_;
}

/// Renders `docs` (JSDoc markdown) into wrapped, inline-styled widget rows via the
/// `sparkles:syntax` `MdDoc` model. Empty parse (no grammar) ⇒ plain-line fallback.
private uint[] markdownDocsRows(ref Builder b, ref GrammarRegistry registry,
    const(char)[] docs, size_t hit, int maxWidth,
    HoverViewOptions opts = HoverViewOptions.init) @system
{
    import sparkles.source_view.markdown : MdViewOptions, viewMarkdownInto;

    MdDoc doc = extractMarkdown(registry, docs);
    if (doc.root.children.length == 0)
        return plainDocsRows(b, docs, hit);
    // The shared composable markdown view — "JSDoc renders through the same
    // markdown view" — with the popup's docs face/slot/width and hit identity.
    //
    // ONE wrap width for the whole popup. `docsMaxWidth` is a readable prose
    // measure and it used to narrow this section further, so the description
    // wrapped at 56 columns while the `@tag` rows beside it took the popup's
    // full interior — two measures in one surface, which reads as a bug rather
    // than as typography. The metric now caps a popup nobody sized (the
    // unbounded path); a popup the solve sized wraps everything to it.
    const docsWidth = maxWidth > 0 ? maxWidth : M.docsMaxWidth;
    return [viewMarkdownInto(b, doc, MdViewOptions(
        maxWidth: docsWidth, hitId: hit,
        baseStyle: docsBase(), proseSlot: Slot.docs,
        theme: opts.mdTheme, fenceRenderer: opts.fenceRenderer,
        fenceScrolls: fenceScrollsOf(doc, opts.fenceScrollX)))];
}
/// Docs fallback (no markdown grammar): the raw text split on newlines into rows,
/// so a `\n` reads as a line break instead of a tofu glyph.
private uint[] plainDocsRows(ref Builder b, const(char)[] docs, size_t hit,
    int maxWidth = 0)
{
    uint[] rows;
    size_t start = 0;
    foreach (i, char c; docs)
        if (c == '\n')
        {
            rows ~= docsLine(b, docs[start .. i], hit, maxWidth);
            start = i + 1;
        }
    rows ~= docsLine(b, docs[start .. $], hit, maxWidth);
    return rows;
}

private uint docsLine(ref Builder b, const(char)[] text, size_t hit,
    int maxWidth = 0)
{
    // A ddoc line is prose of any length; without the cap it paints straight
    // through the popup's right border (`SIG1`).
    auto width = SizeSpec.fit_;
    if (maxWidth > 0)
        width.max = maxWidth;
    return b.add(Widget(kind: WidgetKind.text, text: text.length ? text : " ",
        slot: Slot.docs, hitId: hit, width: width,
        wrap: maxWidth > 0 ? TextWrap.greedy : TextWrap.none,
        textStyle: TextStyle(fontRole: FontRole.docs, fontScale: M.docsFontScale)));
}

/// The cells a popup's content has: the cap less its border and section
/// padding. `0` (unbounded) stays unbounded.
private int popupInterior(int maxWidth) @safe pure nothrow @nogc
{
    const inner = maxWidth - 2 * M.borderWidth - 2;
    return maxWidth > 0 && inner > 0 ? inner : 0;
}

private TextStyle docsBase() pure nothrow @nogc
    => TextStyle(fontRole: FontRole.docs, fontScale: M.docsFontScale);


/// `src[span]` guarded against a malformed range.
private const(char)[] sliceOf(const(char)[] src, in Span s) @safe
    => s.start <= s.end && s.end <= src.length ? src[s.start .. s.end] : "";

/// A JSDoc tag row inside a hover popup: a `@name` pill (`Slot.chip` — muted text
/// on a grey fill, like the HTML `.twoslash-popup-docs-tag-name`) + its text.
private uint buildPopupTag(ref Builder b, const string[] tag, size_t hit,
    int maxWidth = 0)
{
    const nameText = tag.length ? tagName(b, tag[0]) : tagName(b, "");
    uint[] parts;
    // The `@name` chip: a rounded grey pill in the code face at 0.92em (CSS
    // `.twoslash-popup-docs-tag-name` — `border-radius: 4px; font-size: 0.92em`).
    parts ~= b.add(Widget(kind: WidgetKind.text, text: nameText,
        slot: Slot.chip, hitId: hit, paintBackground: true,
        decoration: Decoration(borderRadius: M.popupRadius),
        textStyle: TextStyle(fontRole: FontRole.code, fontScale: M.tagFontScale)));
    if (tag.length > 1 && tag[1].length)
    {
        // The value gets what the chip and the gap leave. Without that the row
        // overflows and the layout squeezes the *chip* to fit, which is how
        // `@returns` used to render as `@ret`.
        auto width = SizeSpec.fit_;
        const room = maxWidth - cast(int)(nameText.length + 1);
        if (maxWidth > 0 && room > 0)
            width.max = room;
        parts ~= b.add(Widget(kind: WidgetKind.text, text: tag[1],
            slot: Slot.docs, hitId: hit, width: width,
            wrap: width.max > 0 ? TextWrap.greedy : TextWrap.none,
            textStyle: TextStyle(fontRole: FontRole.docs, fontScale: M.docsFontScale)));
    }
    return b.container(WidgetKind.row, parts, gap: 1);
}

/// As `buildPopupTag`, but the tag $(I value) renders as inline markdown (a `@see`
/// value's `[label](url)` becomes an underlined link, `` `code` `` a pill, etc.),
/// via the grammar `registry`. `@system` (the tree-sitter parse).
private uint buildPopupTagMd(ref Builder b, ref GrammarRegistry registry,
    const string[] tag, size_t hit, int maxWidth = 0) @system
{
    const nameText = tag.length ? tagName(b, tag[0]) : tagName(b, "");
    uint[] parts;
    parts ~= b.add(Widget(kind: WidgetKind.text, text: nameText,
        slot: Slot.chip, hitId: hit, paintBackground: true,
        decoration: Decoration(borderRadius: M.popupRadius),
        textStyle: TextStyle(fontRole: FontRole.code, fontScale: M.tagFontScale)));

    if (tag.length > 1 && tag[1].length)
    {
        import sparkles.source_view.markdown : inlinesToSpans, pushProse;

        // The gap belongs to the row, not to the text: a leading space span is
        // the first thing greedy wrapping drops, which ran `@returns` straight
        // into its value.
        TextSpan[] spans;
        MdDoc doc = extractMarkdown(registry, tag[1]);
        if (doc.root.children.length)
            foreach (ref const blk; doc.root.children)
                inlinesToSpans(blk.inlines, tag[1], docsBase(), Slot.docs, spans);
        else
            pushProse(tag[1], docsBase(), Slot.docs, spans);

        // Tag values are usually short, but `@see`/`@returns` are not: wrap to
        // what the chip leaves, rather than overflow the row and let the layout
        // squeeze the chip instead.
        auto width = SizeSpec.fit_;
        const room = maxWidth - cast(int) nameText.length;
        if (maxWidth > 0 && room > 0)
            width.max = room;
        parts ~= b.add(Widget(kind: WidgetKind.rich, slot: Slot.docs, hitId: hit,
            spans: spans, textStyle: docsBase(), width: width,
            wrap: width.max > 0 ? TextWrap.greedy : TextWrap.none,
            decoration: Decoration(borderRadius: M.popupRadius)));
    }
    return b.container(WidgetKind.row, parts, gap: 1);
}

/// `"^" * n` from a small static pool (avoids per-node allocation for the common
/// widths); falls back to a fresh string for very long spans.
private const(char)[] repeatCaret(size_t n) pure nothrow
{
    static immutable string carets =
        "^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^";
    if (n <= carets.length)
        return carets[0 .. n];
    auto s = new char[](n);
    s[] = '^';
    return s;
}

/// Prepends `@` to a bare tag `name`, reusing `b`'s arena discipline by
/// materializing a fresh slice (tag names are short and few).
private const(char)[] tagName(ref Builder b, scope const(char)[] name) pure nothrow
{
    auto s = new char[](name.length + 1);
    s[0] = '@';
    s[1 .. $] = name[];
    return s;
}

// ---------------------------------------------------------------------------

version (unittest)
{
    import sparkles.ui.canvas : LineStyle, OpKind, RecordingCanvas;
    import sparkles.ui.display_list : buildDisplayList;
    import sparkles.ui.interp.immediate : paint;
    import sparkles.ui.layout : layout;
    import sparkles.ui.style : defaultTwoslashPalette, Visual;
    import sparkles.base.term_color : RgbColor;

    // Paints a view through the pure pipeline into a RecordingCanvas — the
    // GL-free proof the U1 plan calls for.
    /// The furthest cell any op paints to — how wide the popup really is,
    /// as opposed to how wide it was asked to be.
    private int rightEdge(in RecordingCanvas c) @safe pure nothrow
    {
        int max;
        foreach (op; c.ops)
            if (op.rect.x + op.rect.width > max)
                max = op.rect.x + op.rect.width;
        return max;
    }

    private RecordingCanvas render(in WidgetTree tree)
    {
        const pal = defaultTwoslashPalette();
        auto ops = buildDisplayList(tree, layout(tree), pal,
            RgbColor(0x22, 0x22, 0x22), RgbColor(0xff, 0xff, 0xff));
        RecordingCanvas c;
        paint(c, ops);
        return c;
    }
}

@("render_widgets.viewTwoslashDocument.codeOverlaysAndBlocks")
@safe unittest
{
    import sparkles.syntax : builtinDark, HighlightEvent, LabelSet, resolveTheme;
    import sparkles.ui.canvas : LineStyle, OpKind;
    import sparkles.ui.geometry : Rect;

    // Two lines: a highlight on "x" (line 0) and an error on "a" (line 1,
    // col 10) with its below-line message block.
    const code = "let x = 1\nconst b = a\n";
    const tw = TwoslashReturn(code: code, nodes: [
        Node(type: NodeType.highlight, start: 4, length: 1, line: 0, character: 4),
        Node(type: NodeType.error, start: 20, length: 1, line: 1,
            character: 10, text: "Cannot find name 'a'.", level: "error"),
    ]);
    const ev = [HighlightEvent.sourceSpan(0, code.length)];

    const labels = LabelSet.standard();
    const rt = resolveTheme(builtinDark, labels);
    auto tree = viewTwoslashDocument(tw, ev,
        (() @trusted => &rt)(), RgbColor(0xcc, 0xcc, 0xcc));

    // The code lines are identity-carrying rich spans.
    bool sawLine0, sawLine1;
    foreach (ref const n; tree.nodes)
        if (n.kind == WidgetKind.rich)
            foreach (ref const s; n.spans)
            {
                if (s.text == "let x = 1" && s.srcStart == 0)
                    sawLine0 = true;
                if (s.text == "const b = a" && s.srcStart == 10)
                    sawLine1 = true;
            }
    assert(sawLine0 && sawLine1);

    auto c = render(tree);
    const err = RgbColor(0xd4, 0x56, 0x56);
    bool sawWavy, sawTint, sawMsg;
    size_t wavyAt, codeAt = size_t.max;
    foreach (i, ref op; c.ops)
    {
        if (op.kind == OpKind.line && op.lineStyle == LineStyle.wavy
            && op.visual.fg == err && op.rect.x == 10 && op.rect.y == 1)
        {
            sawWavy = true;
            wavyAt = i;
        }
        if (op.kind == OpKind.fillRect && op.rect == Rect(4, 0, 1, 1))
            sawTint = true;
        if (op.kind == OpKind.textRun && op.text == "Cannot find name 'a'.")
            sawMsg = true; // the below block, directly under its line
        if (op.kind == OpKind.textRun && op.text == "const b = a")
            codeAt = i;
    }
    assert(sawWavy && sawTint && sawMsg);
    assert(codeAt < wavyAt, "the squiggle paints over its code line");
}

@("render_widgets.viewTwoslashDocument.hoverUnderline")
@safe unittest
{
    import sparkles.syntax : builtinDark, HighlightEvent, LabelSet, resolveTheme;
    import sparkles.ui.canvas : OpKind;
    import sparkles.ui.geometry : Rect;

    // A hover on `x` (line 0, col 6) — no below-line block, but the token must
    // still be discoverable: an always-on dotted underline under its cells.
    const code = "const x = 1\n";
    const tw = TwoslashReturn(code: code, nodes: [
        Node(type: NodeType.hover, start: 6, length: 1, line: 0, character: 6,
            text: "const x: 1"),
    ]);
    const ev = [HighlightEvent.sourceSpan(0, code.length)];

    const labels = LabelSet.standard();
    const rt = resolveTheme(builtinDark, labels);
    auto tree = viewTwoslashDocument(tw, ev,
        (() @trusted => &rt)(), RgbColor(0xcc, 0xcc, 0xcc));

    // The display list carries the semantic slot; the recorded canvas ops carry
    // only the resolved Visual (a canvas primitive never sees a slot).
    auto ops = buildDisplayList(tree, layout(tree), defaultTwoslashPalette(),
        RgbColor(0x22, 0x22, 0x22), RgbColor(0xff, 0xff, 0xff));
    bool sawSlot;
    foreach (ref op; ops)
        if (op.kind == OpKind.fillRect && op.slot == Slot.hoverUnderline)
            sawSlot = true;
    assert(sawSlot, "the underline names Slot.hoverUnderline");

    auto c = render(tree);
    size_t ruleAt = size_t.max, codeAt = size_t.max;
    foreach (i, ref op; c.ops)
    {
        // Border-only (no fill), 1px dotted along the bottom of the token's one
        // cell, in the faint palette grey Slot.hoverUnderline resolves to.
        if (op.kind == OpKind.fillRect && op.visual.border.style == BorderStyle.dotted)
        {
            assert(!op.visual.hasBg);
            assert(op.visual.border.width == Insets(0, 0, 1, 0));
            assert(op.visual.border.color == RgbColor(0x88, 0x88, 0x88));
            assert(op.visual.border.alpha == 0x55);
            assert(op.rect == Rect(6, 0, 1, 1));
            ruleAt = i;
        }
        if (op.kind == OpKind.textRun && op.text == "const x = 1")
            codeAt = i;
    }
    assert(ruleAt != size_t.max, "a hover span gets an always-on underline");
    assert(ruleAt < codeAt, "the underline paints under its code line");
}

@("render_widgets.viewTwoslash.errorBlock")
@safe unittest
{
    const tw = TwoslashReturn(
        code: "const b = a\n",
        nodes: [Node(type: NodeType.error, start: 6, length: 1, line: 0,
            character: 6, text: "Cannot find name 'a'.", level: "error", code: 2304)]);

    auto c = render(viewTwoslash(tw));

    // caret ("^") + an accent block (bg tint + 3px left bar) + message, all in the
    // error color, indented to column 6.
    const err = RgbColor(0xd4, 0x56, 0x56);
    bool sawCaret, sawAccent, sawMsg;
    foreach (ref op; c.ops)
    {
        if (op.kind == OpKind.textRun && op.text == "^"
            && op.visual.fg == err && op.rect.x == 6)
            sawCaret = true;
        if (op.kind == OpKind.fillRect && op.visual.hasBg
            && op.visual.border.any && op.visual.border.color == err)
            sawAccent = true;
        if (op.kind == OpKind.textRun && op.text == "Cannot find name 'a'."
            && op.visual.fg == err)
            sawMsg = true;
    }
    assert(sawCaret && sawAccent && sawMsg);
}

@("render_widgets.viewTwoslash.warningUsesWarnSlot")
@safe unittest
{
    const tw = TwoslashReturn(code: "x\n",
        nodes: [Node(type: NodeType.error, start: 0, length: 1, line: 0,
            character: 0, text: "deprecated", level: "warning")]);

    auto c = render(viewTwoslash(tw));
    assert(c.ops[0].visual.fg == RgbColor(0xc3, 0x7d, 0x0d)); // warn, not error
}

@("render_widgets.viewTwoslash.completionMatchedUnmatched")
@safe unittest
{
    const tw = TwoslashReturn(code: "a.m\n",
        nodes: [Node(type: NodeType.completion, start: 3, length: 0, line: 0,
            character: 2, completions: [Completion(name: "map"), Completion(name: "filter")],
            completionsPrefix: "m")]);

    auto c = render(viewTwoslash(tw));

    // The completion icon (kindless ⇒ `•`) appears, and "map" splits into matched
    // "m" + unmatched "ap" with the two completion slots.
    bool sawMarker, sawMatched, sawUnmatched;
    foreach (ref op; c.ops)
    {
        if (op.kind == OpKind.textRun && op.text == "•")
            sawMarker = true;
        if (op.kind == OpKind.textRun && op.text == "m"
            && op.visual.fg == RgbColor(0x22, 0x22, 0x22)) // matched inherits page fg
            sawMatched = true;
        if (op.kind == OpKind.textRun && op.text == "ap"
            && op.visual.fg == RgbColor(0x88, 0x88, 0x88)) // unmatched muted
            sawUnmatched = true;
    }
    assert(sawMarker && sawMatched && sawUnmatched);
}

@("render_widgets.viewHoverPopup.maxWidthCapsThePopup")
@safe unittest
{
    // A D signature can measure 200+ cells. Uncapped the popup grows to match
    // and walks off the window; the cap is what a backend hands it after
    // measuring the room at the anchor.
    // Short tokens throughout, so wrapping alone can honour the cap — the
    // unbreakable-token case is the test below.
    enum long_ = "int wrap(int first, int second, int third, int fourth, "
        ~ "int fifth, int sixth, int seventh, int eighth)";
    const tw = TwoslashReturn(code: "f()\n",
        nodes: [Node(type: NodeType.hover, start: 0, length: 1, line: 0,
            character: 0, text: long_)]);

    auto wide = render(viewHoverPopup(tw, 0));
    auto capped = render(viewHoverPopup(tw, 0, HoverViewOptions(maxWidth: 40)));

    import std.conv : text;

    assert(rightEdge(wide) > 60, "the corpus stopped being a wide case");
    assert(rightEdge(capped) <= 40,
        text("painted to ", rightEdge(capped), " past a cap of 40"));
}

@("render_widgets.viewHoverPopup.structuredSignatureBreaksAtItsParameters")
@safe unittest
{
    // What S4 could not do: the token with nowhere to break is a parameter
    // list, and the producer said so, so the popup breaks there instead of
    // overhanging.
    import std.string : indexOf, lastIndexOf;

    import sparkles.twoslash.protocol : BreakGroup, BreakPoint;

    enum text = "FilterResult!(Lambda, MapResult) filter(int first, int second)";

    // Computed, not counted by hand: an off-by-one here would test the wrong
    // break points and still look plausible.
    const tOpen = cast(uint) text.indexOf("!(") + 1;
    const tClose = cast(uint) text.indexOf(")");
    const rOpen = cast(uint) text.indexOf("filter(") + 6;
    const rClose = cast(uint) text.lastIndexOf(")");

    auto sig = SignatureLayout(
        groups: [BreakGroup(rOpen, rClose, 0), BreakGroup(tOpen, tClose, 1)],
        breaks: [
            BreakPoint(cast(uint) text.indexOf("int first"), 0),
            BreakPoint(cast(uint) text.indexOf("int second"), 0),
            BreakPoint(cast(uint) text.indexOf("Lambda"), 1),
            BreakPoint(cast(uint) text.indexOf("MapResult"), 1),
        ]);

    const tw = TwoslashReturn(code: "f()\n",
        nodes: [Node(type: NodeType.hover, start: 0, length: 1, line: 0,
            character: 0, text: text, signature: sig)]);

    auto capped = render(viewHoverPopup(tw, 0, HoverViewOptions(maxWidth: 40)));

    import std.algorithm.searching : canFind;
    import std.array : join;
    import std.conv : text_ = text;

    assert(rightEdge(capped) <= 40,
        text_("painted to ", rightEdge(capped), " past a cap of 40"));

    // Broken at the parameters, not mid-word: each parameter is its own row.
    string[] painted;
    foreach (op; capped.ops)
        if (op.text.length)
            painted ~= op.text.idup;
    const all = painted.join("|");
    assert(painted.canFind!(t => t.canFind("int first,")), all);
    assert(painted.canFind!(t => t.canFind("int second")), all);
}

@("render_widgets.viewHoverPopup.maxWidthZeroStaysUnbounded")
@safe unittest
{
    // The default is what every caller got before the option existed, so a
    // backend that cannot work out its room changes nothing.
    const tw = TwoslashReturn(code: "f()\n",
        nodes: [Node(type: NodeType.hover, start: 0, length: 1, line: 0,
            character: 0, text: "int aVeryLongSignature(int first, int second, int third)")]);

    auto implicit = render(viewHoverPopup(tw, 0));
    auto explicit = render(viewHoverPopup(tw, 0, HoverViewOptions(maxWidth: 0)));
    assert(implicit.ops.length == explicit.ops.length);
    foreach (i, op; implicit.ops)
        assert(op.rect == explicit.ops[i].rect && op.text == explicit.ops[i].text);
}

@("render_widgets.viewHoverPopup.collapsedRegionsShrinkTheSignature")
@safe unittest
{
    // The reason abbreviation exists: a qualified, nested type is most of the
    // width and almost none of the answer.
    import std.algorithm.searching : canFind;
    import std.array : join;

    import sparkles.twoslash.protocol : Abbrev;
    import std.string : indexOf;

    enum text = "std.range.iota!(int, int).Result f(int n)";
    const qualifier = cast(uint) text.indexOf("std.range.");

    auto sig = SignatureLayout(abbrevs: [
        Abbrev(qualifier, 10, null, "module"),          // elide `std.range.`
        Abbrev(cast(uint) text.indexOf("int, int"), 8, "…", "template"),
    ]);
    const tw = TwoslashReturn(code: "f()\n",
        nodes: [Node(type: NodeType.hover, start: 0, length: 1, line: 0,
            character: 0, text: text, signature: sig)]);

    string[] painted(HoverViewOptions o)
    {
        string[] out_;
        foreach (op; render(viewHoverPopup(tw, 0, o)).ops)
            if (op.text.length)
                out_ ~= op.text.idup;
        return out_;
    }

    const collapsed = painted(HoverViewOptions(maxWidth: 60));
    assert(collapsed.canFind("…"), collapsed.join("|"));
    assert(!collapsed.canFind!(t => t.canFind("std.range.")), collapsed.join("|"));

    // Expanding one region shows it again, and only it.
    ExpandedRegions open;
    open[1] = true;
    const opened = painted(HoverViewOptions(maxWidth: 60, expanded: open));
    assert(opened.canFind!(t => t.canFind("int, int")), opened.join("|"));
    assert(!opened.canFind!(t => t.canFind("std.range.")), "region 0 stays hidden");
}

@("render_widgets.viewHoverPopup.collapsedMarkerKeepsTheFullRange")
@safe unittest
{
    // The reader hid the text from view; they did not delete it. Selection and
    // copy still resolve to what the `…` stands for.
    import sparkles.twoslash.protocol : Abbrev;
    import std.string : indexOf;

    enum text = "Foo!(Bar, Baz) f()";
    const inner = cast(uint) text.indexOf("Bar, Baz");
    auto sig = SignatureLayout(abbrevs: [Abbrev(inner, 8, "…", "template")]);
    const tw = TwoslashReturn(code: "f()\n",
        nodes: [Node(type: NodeType.hover, start: 0, length: 1, line: 0,
            character: 0, text: text, signature: sig)]);

    auto tree = viewHoverPopup(tw, 0, HoverViewOptions(maxWidth: 60, nodeKey: 3));

    bool sawMarker;
    foreach (w; tree.nodes)
        if (w.text == "…")
        {
            sawMarker = true;
            assert(w.key == abbrevKey(3, 0), "the marker must name its region");
        }
    assert(sawMarker, "the collapsed run must render a marker");
}

@("render_widgets.viewHoverPopup.docsAndTagsStayInsideTheBox")
@safe unittest
{
    // The cap has to reach the docs and the tag values too. Before it did, a
    // ddoc paragraph painted straight through the popup's right border, and an
    // overflowing tag row made the layout squeeze the *chip* instead — which is
    // how `@returns` rendered as `@ret`.
    import std.algorithm.searching : canFind;
    import std.array : join;

    const tw = TwoslashReturn(code: "f()\n",
        nodes: [Node(type: NodeType.hover, start: 0, length: 1, line: 0,
            character: 0, text: "void f()",
            docs: "The predicate is passed to unaryFun, and can be either a"
                ~ " string, or any callable that can be executed via pred.",
            tags: [["returns", "An input range that contains the filtered"
                ~ " elements, in the order they were seen."]])]);

    enum cap = 40;
    auto c = render(viewHoverPopup(tw, 0, HoverViewOptions(maxWidth: cap)));
    assert(rightEdge(c) <= cap, "the popup overflowed its cap");

    // The chip keeps its own width — nothing was stolen from it to make room.
    string[] painted;
    foreach (op; c.ops)
        if (op.text.length)
            painted ~= op.text.idup;
    assert(painted.canFind("@returns"), painted.join("|"));
}

@("render_widgets.viewBelowBlock.queryLineStaysInsideThePane")
@safe unittest
{
    // A `^?` line is the same signature shown in place instead of floating, so
    // it gets the same treatment — otherwise a 200-cell D type runs off the
    // right edge of the pane it is drawn in (`SIG2`).
    import sparkles.twoslash.protocol : Abbrev;
    import std.string : indexOf;

    enum text = "sample.squares.MapResult!(__lambda_L6_C25, Result) tenSquares";
    auto sig = SignatureLayout(abbrevs: [
        Abbrev(cast(uint) text.indexOf("sample.squares."), 15, null, "module"),
    ]);
    const tw = TwoslashReturn(code: "auto tenSquares = squares(10);\n",
        nodes: [Node(type: NodeType.query, start: 5, length: 10, line: 0,
            character: 5, text: text, signature: sig)]);

    // Unbounded, the query line is one row as wide as its text.
    assert(rightEdge(render(viewBelowBlock(tw, 0))) > 40);

    // Given the pane's width it stays inside it — indent included, since the
    // block is padded to its source column.
    enum pane = 40;
    const bounded = rightEdge(render(viewBelowBlock(tw, 0, pane)));
    assert(bounded <= pane, "query line overflowed the pane");
}

@("render_widgets.viewHoverPopup.clickingAMarkerNamesItsRegion")
@safe unittest
{
    // The whole point of stamping keys: a pointer lands on a `…`, and the
    // backend has to learn *which* run it means without knowing anything
    // about signature layout.
    import std.algorithm.searching : canFind;
    import std.array : join;
    import std.string : indexOf;

    import sparkles.twoslash.protocol : Abbrev;
    import sparkles.ui.geometry : Point;
    import sparkles.ui.layout : layout;
    import sparkles.ui.state : keyAt, keyTargets;

    enum text = "Map!(Filter!(Pred, Range)) f(int n)";
    auto sig = SignatureLayout(abbrevs: [
        Abbrev(cast(uint) text.indexOf("Pred, Range"), 11, "…", "template"),
    ]);
    const tw = TwoslashReturn(code: "f()\n",
        nodes: [Node(type: NodeType.hover, start: 0, length: 1, line: 0,
            character: 0, text: text, signature: sig)]);

    enum nodeKey = 1; // as a backend numbers the popup: node index + 1
    auto opts = HoverViewOptions(maxWidth: 60, nodeKey: nodeKey);
    auto tree = viewHoverPopup(tw, 0, opts);
    const targets = keyTargets(tree, layout(tree));
    assert(targets.length == 1, "one collapsed run, one target");

    // Aim at the marker's own cell, the way a click would.
    const k = keyAt(targets, Point(targets[0].rect.x, targets[0].rect.y));
    assert(k == abbrevKey(nodeKey, 0));
    assert(abbrevNode(k) == nodeKey, "the key says which popup it came from");

    // Feeding the decoded region back in expands that run and nothing else.
    ExpandedRegions open;
    open[abbrevRegion(k)] = true;
    string[] painted;
    foreach (op; render(viewHoverPopup(tw, 0,
            HoverViewOptions(maxWidth: 60, nodeKey: nodeKey, expanded: open))).ops)
        if (op.text.length)
            painted ~= op.text.idup;
    assert(painted.canFind!(t => t.canFind("Pred, Range")), painted.join("|"));
    assert(!painted.canFind("…"), "nothing left collapsed: " ~ painted.join("|"));
}

@("render_widgets.viewHoverPopup.effectChipsShowAbsenceToo")
@safe unittest
{
    // The point of the row: "not `pure`" is as much of an answer as "`pure`".
    import std.algorithm.searching : canFind;
    import std.array : join;

    import sparkles.twoslash.protocol : EffectSpan, Effects;

    enum text = "int f(int x) pure @safe";
    auto sig = SignatureLayout(effects: Effects(trust: "@safe", isPure: true,
        spans: [EffectSpan(12, 5), EffectSpan(17, 6)]));
    const tw = TwoslashReturn(code: "f()\n",
        nodes: [Node(type: NodeType.hover, start: 0, length: 1, line: 0,
            character: 0, text: text, signature: sig)]);

    auto c = render(viewHoverPopup(tw, 0, HoverViewOptions(maxWidth: 60)));

    string[] painted;
    foreach (op; c.ops)
        if (op.text.length)
            painted ~= op.text.idup;
    const all = painted.join("|");

    assert(painted.canFind("@safe"), all);
    assert(painted.canFind("✓ pure"), all);
    assert(painted.canFind("✗ nothrow"), all);
    assert(painted.canFind("✗ @nogc"), all);

    // And the words they replaced are gone from the signature itself.
    assert(painted.canFind("int f(int x)"), all);
    assert(!painted.canFind!(t => t.canFind("int f(int x) pure")), all);
}

@("render_widgets.viewHoverPopup.inferredEffectsAreUnknownNotDenied")
@safe unittest
{
    // An uninstantiated template infers its attributes, so a cross would claim
    // the compiler decided something it has not.
    import std.algorithm.searching : canFind;
    import std.array : join;

    import sparkles.twoslash.protocol : Effects;

    auto sig = SignatureLayout(effects: Effects(inferred: true));
    const tw = TwoslashReturn(code: "f()\n",
        nodes: [Node(type: NodeType.hover, start: 0, length: 1, line: 0,
            character: 0, text: "T twice(T)(T x)", signature: sig)]);

    auto c = render(viewHoverPopup(tw, 0, HoverViewOptions(maxWidth: 60)));

    string[] painted;
    foreach (op; c.ops)
        if (op.text.length)
            painted ~= op.text.idup;
    const all = painted.join("|");

    assert(painted.canFind("· pure"), all);
    assert(!painted.canFind("✗ pure"), all);
}

@("render_widgets.viewHoverPopup.noEffectRowWithoutStructure")
@safe unittest
{
    // A TypeScript payload — or any node predating the field — must render
    // exactly as it always did.
    const tw = TwoslashReturn(code: "wrap(1)\n",
        nodes: [Node(type: NodeType.hover, start: 0, length: 4, line: 0,
            character: 0, text: "(alias) function wrap<T>(value: T): Box<T>")]);

    auto c = render(viewHoverPopup(tw, 0));
    foreach (op; c.ops)
        assert(!op.text.length || op.text != "@safe", "no chips without effects");
}

@("render_widgets.viewHoverPopup.surfaceSignatureDocsTags")
@safe unittest
{
    const tw = TwoslashReturn(code: "wrap(1)\n",
        nodes: [Node(type: NodeType.hover, start: 0, length: 4, line: 0, character: 0,
            text: "(alias) function wrap<T>(value: T): Box<T>",
            docs: "Wraps a value in a Box.",
            tags: [["param", "value - the wrapped value"], ["returns", "a Box"]])]);

    auto c = render(viewHoverPopup(tw, 0));

    // The surface fill comes first and now carries the popup chrome: a 1px border,
    // a 4px radius, a drop shadow, and an arrow tail.
    assert(c.ops[0].kind == OpKind.fillRect);
    assert(c.ops[0].visual.bg == RgbColor(0xf8, 0xf8, 0xf8));
    assert(c.ops[0].visual.border.any && c.ops[0].visual.borderRadius == 4);
    assert(c.ops[0].visual.shadow.any && c.ops[0].visual.arrow);
    assert(c.ops[0].visual.border.color == RgbColor(0x88, 0x88, 0x88));

    bool sawSig, sawDocs, sawTag;
    foreach (i, ref op; c.ops)
    {
        // Signature: the code face at 1em.
        if (op.text == "function wrap<T>(value: T): Box<T>")
            sawSig = op.visual.fontRole == FontRole.code && op.visual.fontScale == 100;
        // Docs: the sans face at 0.8em, muted.
        if (op.text == "Wraps a value in a Box." && op.visual.fg == RgbColor(0x88, 0x88, 0x88))
            sawDocs = op.visual.fontRole == FontRole.docs && op.visual.fontScale == 80;
        // The `@param` chip: a rounded grey pill in the code face at 0.92em.
        // The pill is the fill emitted just before the run — that is the op a
        // backend rounds and fills, while the run carries the face. (They used
        // to be asserted on one op because every op carried a whole `Visual`;
        // a run's radius was never painted from.)
        if (op.text == "@param" && op.visual.fg == RgbColor(0x88, 0x88, 0x88)
            && op.visual.hasBg
            && op.visual.fontRole == FontRole.code && op.visual.fontScale == 92)
        {
            const pill = c.ops[i - 1];
            sawTag = pill.kind == OpKind.fillRect && pill.visual.hasBg
                && pill.visual.borderRadius == 4
                && pill.visual.bg == op.visual.bg;
        }
    }
    assert(sawSig && sawDocs && sawTag);
}

@("render_widgets.viewTwoslash.emptyOverlayIsWellFormed")
@safe unittest
{
    const tw = TwoslashReturn(code: "ok\n", nodes: []);
    auto c = render(viewTwoslash(tw)); // no below-blocks
    assert(c.ops.length == 0);
}

@("render_widgets.docs.markdownInlineStyling")
@safe unittest
{
    import sparkles.base.term_style : TextAttr;

    import sparkles.source_view.markdown : MdViewOptions, viewMarkdownInto;

    // A hand-built paragraph "x b c" where "b" is strong and "c" is a code
    // span — the SHARED markdown view under the popup's docs options ("JSDoc
    // renders through the same markdown view"). No grammar bundle needed.
    const src = "x b c";
    MdInline[] inls = [
        MdInline(kind: MdInlineKind.text, span: Span(0, 2)), // "x "
        MdInline(kind: MdInlineKind.strong, span: Span(2, 3),
            children: [MdInline(kind: MdInlineKind.text, span: Span(2, 3))]), // "b"
        MdInline(kind: MdInlineKind.text, span: Span(3, 4)), // " "
        MdInline(kind: MdInlineKind.codeSpan, span: Span(4, 5)), // "c"
    ];
    const doc = MdDoc(MdBlock(kind: MdBlockKind.document, children: [
        MdBlock(kind: MdBlockKind.paragraph, inlines: inls)]), src);

    auto b = Builder();
    const root = viewMarkdownInto(b, doc, MdViewOptions(
        hitId: 1, baseStyle: docsBase(), proseSlot: Slot.docs));
    auto c = render(b.finish(root));

    bool sawBold, sawChip;
    foreach (ref op; c.ops)
    {
        if (op.text == "b" && (op.visual.styleBits & TextAttr.bold.bits))
            sawBold = true;
        // The code span is a mono pill: its own background + code face.
        if (op.text == "c" && op.visual.hasBg && op.visual.fontRole == FontRole.code)
            sawChip = true;
    }
    assert(sawBold && sawChip);
}

@("render_widgets.docs.plainNewlinesSplitIntoRows")
@safe unittest
{
    // The no-grammar fallback: a `\n` in docs must become a row break, never a
    // literal control char (which a backend would draw as tofu).
    const tw = TwoslashReturn(code: "x\n", nodes: [
        Node(type: NodeType.hover, start: 0, length: 1, line: 0, character: 0,
            text: "const x: 1", docs: "first line\nsecond line"),
    ]);
    auto c = render(viewHoverPopup(tw, 0));

    bool sawFirst, sawSecond, sawNewlineGlyph;
    foreach (ref op; c.ops)
    {
        if (op.text == "first line")
            sawFirst = true;
        if (op.text == "second line")
            sawSecond = true;
        if (op.text == "first line\nsecond line")
            sawNewlineGlyph = true; // the OLD single-run bug
    }
    assert(sawFirst && sawSecond && !sawNewlineGlyph);
}

@("render_widgets.viewTwoslashDocument.tintsTheInlineChannel")
@safe unittest
{
    import sparkles.syntax : builtinDark, HighlightEvent, LabelSet, resolveTheme;
    import sparkles.source_view.code : TintedRange;
    import sparkles.ui.style : Slot;

    // The inline channel is still this view's business: a byte range of the
    // *source* washed with a slot. The gutter is not — that is chrome beside
    // the document, composed by whoever owns the document.
    const code = "int a;\nint b;\n";
    const tw = TwoslashReturn(code: code);
    const ev = [HighlightEvent.sourceSpan(0, code.length)];
    const labels = LabelSet.standard();
    const rt = resolveTheme(builtinDark, labels);

    auto tree = viewTwoslashDocument(tw, ev, (() @trusted => &rt)(),
        RgbColor(0xcc, 0xcc, 0xcc), null, 0,
        CodeViewOptions(
            tintedRanges: [TintedRange(start: 7, end: 13, slot: Slot.covUncovered)]));

    bool sawTint;
    foreach (ref const n; tree.nodes)
        if (n.kind == WidgetKind.rich)
            foreach (ref const sp; n.spans)
                if (sp.slot == Slot.covUncovered && sp.srcStart != size_t.max)
                    sawTint = true;
    assert(sawTint, "the second line is washed");

    // Without decorations the view is exactly what it was.
    auto plain = viewTwoslashDocument(tw, ev, (() @trusted => &rt)(),
        RgbColor(0xcc, 0xcc, 0xcc));
    foreach (ref const n; plain.nodes)
        if (n.kind == WidgetKind.rich)
            foreach (ref const sp; n.spans)
                assert(sp.slot != Slot.covUncovered, "no tint unless asked for");
}

@("render_widgets.viewTwoslashDocument.decorationsSitAtTheirOwnColumn")
@safe unittest
{
    import sparkles.syntax : builtinDark, HighlightEvent, LabelSet, resolveTheme;
    import sparkles.ui.canvas : OpKind;
    import sparkles.ui.style : Slot;

    // A decoration is positioned by source column in the row's *own*
    // coordinates, and stops there. Whatever a caller puts beside the row, the
    // layout moves the row and the decoration together — which is why this
    // view no longer takes, computes or threads an offset.
    const code = "const x = 1\n";
    const tw = TwoslashReturn(code: code, nodes: [
        Node(type: NodeType.hover, start: 6, length: 1, line: 0, character: 6,
            text: "const x: 1"),
    ]);
    const ev = [HighlightEvent.sourceSpan(0, code.length)];
    const labels = LabelSet.standard();
    const rt = resolveTheme(builtinDark, labels);

    auto tree = viewTwoslashDocument(tw, ev, (() @trusted => &rt)(),
        RgbColor(0xcc, 0xcc, 0xcc));
    auto ops = buildDisplayList(tree, layout(tree), defaultTwoslashPalette(),
        RgbColor(0x22, 0x22, 0x22), RgbColor(0xff, 0xff, 0xff));

    foreach (ref op; ops)
        if (op.kind == OpKind.fillRect && op.slot == Slot.hoverUnderline)
        {
            assert(op.rect.x == 6, "the underline sits at the token's column");
            return;
        }
    assert(false, "no hover underline was drawn");
}

@("render_widgets.viewHoverPopup.aLongDdocIsBoundedAndScrolls")
@safe unittest
{
    // The failure this fixes: a ddoc-heavy hover measured whatever it measured
    // and ran off the surface, so the reader lost the end of the sentence with
    // no way to reach it. Bounded, the body scrolls — and the SIGNATURE does
    // not, because scrolling away the thing the reader anchored on is the same
    // failure wearing a different hat.
    import sparkles.ui.layout : layout;

    string docs;
    foreach (i; 0 .. 60)
        docs ~= "A paragraph of documentation that goes on for a while.\n\n";
    const tw = TwoslashReturn(code: "x", nodes: [
        Node(type: NodeType.hover, start: 0, length: 1,
            text: "int veryDocumented(int a)", docs: docs),
    ]);

    // Unbounded: the popup is as tall as its content, which is the bug.
    const tall = viewHoverPopup(tw, 0, HoverViewOptions(maxWidth: 48));
    auto tallFrames = layout(tall);
    const tallRows = tallFrames[tall.root].rect.height;
    assert(tallRows > 40, "an unbounded popup grows without limit");
    assert(!popupScrollExtents(tall, tallFrames).live,
        "and has no viewport, so there is nothing to scroll");

    // Bounded: capped at the budget, with the overflow inside a viewport.
    const capped = viewHoverPopup(tw, 0,
        HoverViewOptions(maxWidth: 48, maxHeight: 12));
    auto frames = layout(capped);
    assert(frames[capped.root].rect.height == 12, "capped at the budget");

    const sc = popupScrollExtents(capped, frames);
    assert(sc.live, "there is more body than viewport");
    // The budget less what the header costs it: one signature row, the rule
    // under it, and the popup's own two rows of vertical padding. (No effect
    // chips here — this node carries no `SignatureLayout`.)
    assert(sc.content > sc.viewport && sc.viewport == 12 - 4,
        "the viewport is the budget less the header, its rule and the padding");

    // The signature is still on the FIRST row of the surface, at every offset:
    // it is outside the viewport, so scrolling cannot take it away.
    const scrolled = viewHoverPopup(tw, 0,
        HoverViewOptions(maxWidth: 48, maxHeight: 12, scrollOffset: 20));
    auto sf = layout(scrolled);
    assert(sf[scrolled.root].rect.height == 12, "still capped");
    const sc2 = popupScrollExtents(scrolled, sf);
    assert(sc2.content == sc.content && sc2.viewport == sc.viewport,
        "the offset moves the body; it does not resize it");
}

@("render_widgets.viewHoverPopup.theRuleIsARowEveryBackendCanDraw")
@safe unittest
{
    // A cell has an underline attribute and NO overline, so a top-only border
    // draws nothing at all in a terminal. The section dividers were top borders
    // on the following section, so they had never appeared there — only in the
    // GUI and HTML, where a top border is a real edge. A rule is a one-row box
    // with a BOTTOM border, which every backend can draw.
    import sparkles.ui.layout : layout;

    const tw = TwoslashReturn(code: "x", nodes: [
        Node(type: NodeType.hover, start: 0, length: 1,
            text: "int f(int a)", docs: "Some prose.\n",
            tags: [["returns", "a number"]]),
    ]);
    const t = viewHoverPopup(tw, 0, HoverViewOptions(maxWidth: 44));
    auto f = layout(t);

    size_t rules, topOnly;
    foreach (i, ref const n; t.nodes)
    {
        const w = n.decoration.borderWidth;
        if (w.bottom > 0 && w.top == 0 && w.left == 0 && w.right == 0
            && n.decoration.borderStyle == BorderStyle.solid)
        {
            ++rules;
            assert(f[i].rect.height == 1, "a rule is one row");
        }
        if (w.top > 0 && w.left == 0 && w.right == 0 && w.bottom == 0)
            ++topOnly;
    }
    assert(topOnly == 0, "no divider may be a top border: cells cannot draw one");
    // One under the header, one between the docs and the `@tag` rows.
    assert(rules == 2, "a rule under the header, and one before the tags");
}

@("render_widgets.viewHoverPopup.theHeaderIsTheSignatureAndItsAttributes")
@safe unittest
{
    // `@safe pure nothrow @nogc` is part of what the signature SAYS — a reader
    // who has scrolled past it has lost half the declaration — so the chips are
    // pinned with it and the rule goes AFTER them.
    import sparkles.ui.layout : layout;

    string docs;
    foreach (i; 0 .. 40)
        docs ~= "A paragraph that runs on for a while.\n\n";
    SignatureLayout sig;
    sig.effects = Effects(trust: "@safe", isPure: true);
    const tw = TwoslashReturn(code: "x", nodes: [
        Node(type: NodeType.hover, start: 0, length: 1,
            text: "int f(int a)", docs: docs, signature: sig),
    ]);

    // The rule's row is fixed while the body scrolls under it, and it sits
    // BELOW the chips rather than between them and the signature.
    static int ruleRow(in WidgetTree t, in Frame[] f)
    {
        int found = -1;
        foreach (i, ref const n; t.nodes)
        {
            const w = n.decoration.borderWidth;
            if (w.bottom > 0 && w.top == 0 && w.left == 0 && w.right == 0
                && n.decoration.borderStyle == BorderStyle.solid
                && (found < 0 || f[i].rect.y < found))
                found = f[i].rect.y;
        }
        return found;
    }

    int firstRow = -1;
    foreach (off; [0, 4, 11, 30])
    {
        const t = viewHoverPopup(tw, 0,
            HoverViewOptions(maxWidth: 44, maxHeight: 14, scrollOffset: off));
        auto f = layout(t);
        const row = ruleRow(t, f);
        assert(row > 1, "the rule is below BOTH header rows");
        if (firstRow < 0)
            firstRow = row;
        assert(row == firstRow, "and does not move as the body scrolls");
        assert(popupScrollExtents(t, f).live,
            "…while the body under it really is scrolling");
    }
}


@("render_widgets.viewHoverPopup.everySectionWrapsToOneWidth")
@safe unittest
{
    // The description used to be narrowed to `docsMaxWidth` while the `@tag`
    // rows beside it took the popup's full interior, so one surface showed two
    // wrap widths — which reads as a bug rather than as typography.
    import sparkles.ui.layout : layout;

    // Prose and a tag, both long enough to wrap at any sane width.
    enum long_ = "one two three four five six seven eight nine ten eleven "
        ~ "twelve thirteen fourteen fifteen sixteen seventeen eighteen";
    const tw = TwoslashReturn(code: "x", nodes: [
        Node(type: NodeType.hover, start: 0, length: 1,
            text: "int f(int a)", docs: long_ ~ "\n",
            tags: [["returns", long_]]),
    ]);

    // A popup far wider than the old 56-column prose measure.
    const t = viewHoverPopup(tw, 0, HoverViewOptions(maxWidth: 96));
    auto f = layout(t);

    // The widest laid-out row of each section, which is what a reader compares.
    int docsRight, tagRight;
    foreach (i, ref const n; t.nodes)
    {
        if (n.kind != WidgetKind.text && n.kind != WidgetKind.rich)
            continue;
        const r = f[i].rect.right;
        // The `@returns` row is the one carrying the tag's own name run.
        if (n.text == "returns")
            tagRight = tagRight > r ? tagRight : r;
    }
    foreach (i, ref const n; t.nodes)
        if (n.wrap != TextWrap.none && f[i].rect.width > docsRight)
            docsRight = f[i].rect.width;

    assert(docsRight > 56,
        "prose is no longer clamped to the standalone docs measure");
    assert(docsRight <= 96, "and still fits the popup the solve sized");
}

@("render_widgets.viewHoverPopup.theRuleActuallyPaintsInATerminal")
@safe unittest
{
    // The bug this whole shape fixes: the dividers were TOP borders, which a
    // cell backend cannot draw at all — a cell has an underline attribute and
    // no overline — so the terminal showed a popup with no separators while
    // the GUI showed them. Asserting the widget tree is not enough; the rule
    // has to reach a grid.
    import sparkles.base.term_color : RgbColor;
    import sparkles.ui.display_list : buildDisplayList;
    import sparkles.ui.interp.cells : CellGrid;
    import sparkles.ui.interp.immediate : paint;
    import sparkles.ui.layout : layout;
    import sparkles.ui.style : defaultTwoslashPalette, schemeForBackground;

    const tw = TwoslashReturn(code: "x", nodes: [
        Node(type: NodeType.hover, start: 0, length: 1,
            text: "int f(int a)", docs: "Some prose about it.\n",
            tags: [["returns", "a number"]]),
    ]);
    const t = viewHoverPopup(tw, 0, HoverViewOptions(maxWidth: 40));
    auto f = layout(t);

    const bg = RgbColor(0x1a, 0x1b, 0x26), fg = RgbColor(0xc0, 0xc0, 0xc0);
    const pal = defaultTwoslashPalette(schemeForBackground(bg));
    auto grid = CellGrid(48, cast(int) f[t.root].rect.height + 2, fg, bg);
    paint(grid, buildDisplayList(t, f, pal, fg, bg));

    // Count rows made of the box-drawing horizontal — the rule's glyph.
    size_t ruleRows;
    foreach (y; 0 .. grid.height)
    {
        size_t run;
        foreach (x; 0 .. grid.width)
            if (grid.cells[y * grid.width + x].glyph == '─')
                ++run;
        if (run >= 8)
            ++ruleRows;
    }
    // The popup's own top and bottom border, plus the two internal rules.
    assert(ruleRows >= 4,
        "the section dividers must reach the grid, not only the widget tree");
}

@("render_widgets.viewHoverPopup.aScrollableBodyShowsItsBars")
@safe unittest
{
    // `SCV`: a container that scrolls says so. A viewport with no bar gives a
    // reader no way to know there is more and no way to tell how much, which
    // is the whole complaint a clipped surface answers.
    import sparkles.ui.layout : layout;
    import sparkles.ui.widget : WidgetKind;

    string docs;
    foreach (i; 0 .. 40)
        docs ~= "A paragraph that runs on for a while.\n\n";
    const tw = TwoslashReturn(code: "x", nodes: [
        Node(type: NodeType.hover, start: 0, length: 1,
            text: "int f(int a)", docs: docs),
    ]);

    static size_t bars(in WidgetTree t)
    {
        size_t n;
        foreach (ref const w; t.nodes)
            if (w.kind == WidgetKind.scrollbar)
                ++n;
        return n;
    }

    // Frame one: the host has measured nothing yet, so there is no bar to draw
    // — the extents come from `layout`, and the bars are part of what it
    // measures. One frame of lag, the same every hit rect already has.
    const first = viewHoverPopup(tw, 0,
        HoverViewOptions(maxWidth: 44, maxHeight: 12));
    assert(bars(first) == 0);

    // Frame two, with last frame's measurement fed back.
    auto f1 = layout(first);
    const sc = popupScrollExtents(first, f1);
    assert(sc.live, "the body does overflow");

    const second = viewHoverPopup(tw, 0, HoverViewOptions(maxWidth: 44,
        maxHeight: 12, barContent: sc.content, barViewport: sc.viewport));
    assert(bars(second) == 1, "a vertical bar, because the body scrolls");

    // And it REACHES THE GRID. A bar in the widget tree is not a bar a reader
    // can see: this one laid out one column wide and zero rows tall, because
    // `scrollbar`'s track argument is the widget's extent along its own axis
    // and the shell passed nothing. It was in the tree, in the display list,
    // and nowhere on the screen — which is exactly how it was reported.
    import sparkles.base.term_color : RgbColor;
    import sparkles.ui.display_list : buildDisplayList;
    import sparkles.ui.interp.cells : CellGrid;
    import sparkles.ui.interp.immediate : paint;
    import sparkles.ui.style : defaultTwoslashPalette, schemeForBackground;

    auto f3 = layout(second);
    const bg = RgbColor(0x1a, 0x1b, 0x26), fg = RgbColor(0xc0, 0xc0, 0xc0);
    const pal = defaultTwoslashPalette(schemeForBackground(bg));
    auto grid = CellGrid(60, cast(int) f3[second.root].rect.height + 2, fg, bg);
    paint(grid, buildDisplayList(second, f3, pal, fg, bg));

    size_t thumbCells;
    foreach (ref const c; grid.cells)
        if (c.glyph == '\u2588')   // the default thumb block
            ++thumbCells;
    assert(thumbCells > 0, "the bar must be painted, not merely built");

    // A popup that fits shows none: a gutter spent on a bar nobody can use is
    // a column stolen from the text.
    const short_ = TwoslashReturn(code: "x", nodes: [
        Node(type: NodeType.hover, start: 0, length: 1,
            text: "int f(int a)", docs: "One line.\n"),
    ]);
    const fits = viewHoverPopup(short_, 0,
        HoverViewOptions(maxWidth: 44, maxHeight: 12));
    auto f2 = layout(fits);
    assert(!popupScrollExtents(fits, f2).live);
    assert(bars(fits) == 0);
}

@("render_widgets.viewHoverPopup.theCloseLaneIsReservedAndRevealed")
@safe unittest
{
    // The gallery's terminal tab list makes this bargain and it is the reason a
    // hover-revealed control can sit inside content at all: the column is
    // reserved WHETHER OR NOT the ✕ shows, so revealing it cannot reflow the
    // declaration the reader is looking at.
    import sparkles.ui.layout : layout;
    import sparkles.ui.state : keyAt, keyTargets;

    const tw = TwoslashReturn(code: "x", nodes: [
        Node(type: NodeType.hover, start: 0, length: 1,
            text: "int reduce(int[] r)", docs: "Some prose.\n"),
    ]);

    const idle = viewHoverPopup(tw, 0,
        HoverViewOptions(maxWidth: 44, nodeKey: 1));
    const hot = viewHoverPopup(tw, 0,
        HoverViewOptions(maxWidth: 44, nodeKey: 1, showClose: true));
    auto fi = layout(idle), fh = layout(hot);

    assert(fi[idle.root].rect == fh[hot.root].rect,
        "revealing the ✕ must not move or resize the popup");

    // It is clickable through the SAME key channel a collapsed run uses, so a
    // backend decodes one lookup rather than growing a second.
    const targets = keyTargets(hot, fh);
    size_t found;
    foreach (t; targets)
        if (isPopupCloseKey(t.key))
            found = t.key;
    assert(found == popupCloseKey(1));
    assert(!isPopupCloseKey(abbrevKey(1, 0)),
        "and a collapsed run is not mistaken for it");

    // Idle, there is nothing to click.
    foreach (t; keyTargets(idle, fi))
        assert(!isPopupCloseKey(t.key));

    // It sits in the top-right corner: the popup's first content row, at its
    // right edge rather than after the signature text.
    foreach (t; targets)
        if (isPopupCloseKey(t.key))
        {
            assert(t.rect.y == fh[hot.root].rect.y + 1, "the top row");
            assert(t.rect.right >= fh[hot.root].rect.right - 2,
                "hard against the right edge");
        }
}

@("render_widgets.applyPopupArrow.pointsAtTheTokenNotAtTheCorner")
@safe unittest
{
    // The caret must point at what the popup describes. Left to the view's own
    // `Decoration` it sat at cell one of the top edge, always — aimed at the
    // popup's left corner, wherever the token actually was.
    import sparkles.ui.canvas : arrowCellOf, arrowFits;
    import sparkles.ui.layout : layout;
    import sparkles.ui.style : BoxSide, defaultTwoslashPalette,
        schemeForBackground;
    import sparkles.base.term_color : RgbColor;

    const pal = defaultTwoslashPalette(
        schemeForBackground(RgbColor(0x1a, 0x1b, 0x26)));
    const tw = TwoslashReturn(code: "x", nodes: [
        Node(type: NodeType.hover, start: 0, length: 1,
            text: "int reduce(int[] r)", docs: "Some prose.\n"),
    ]);

    // The same popup against three anchors at different columns. The caret
    // must move with the anchor, not stay put.
    int[] cells;
    foreach (ax; [4, 30, 60])
    {
        auto tree = viewHoverPopup(tw, 0, HoverViewOptions(maxWidth: 40));
        auto f = layout(tree);
        const anchor = AnchorRect(primary: Rect(ax, 3, 6, 1), live: true);
        const g = placeHoverPopup(pal, anchor, f[tree.root].rect.size,
            Rect(0, 0, 100, 30));
        assert(g.paintable && g.arrowVisible);
        applyPopupArrow(tree, g);

        const deco = tree.nodes[tree.root].decoration;
        assert(deco.arrow && deco.arrowSide == BoxSide.top,
            "it hangs below, so its caret is on its own top edge");

        // The caret's absolute cell is the anchor's centre, or as near as the
        // edge allows — never the corner.
        const box = Rect(g.rect.x, g.rect.y, g.rect.width, g.rect.height);
        assert(arrowFits(box, deco.arrowSide, deco.arrowOffset));
        const at = arrowCellOf(box, deco.arrowSide, deco.arrowOffset);
        const centre = ax + 3;
        assert(at.x >= box.x + 1 && at.x <= box.right - 2, "inside the edge");
        assert(at.x == centre || at.x == box.x + 1 || at.x == box.right - 2,
            "the anchor's centre, or the nearest legal cell to it");
        cells ~= at.x;
    }

    // The ABSOLUTE cell tracks the anchor. The overlay-local offset does not
    // have to: a start-aligned popup moves WITH its anchor, so the caret keeps
    // the same distance from the popup's left edge — which is the anchor's
    // centre, correctly.
    assert(cells[0] < cells[1] && cells[1] < cells[2]);

    // Where the popup cannot follow — an anchor near the right edge slides it
    // left — the local offset moves instead, and still lands on the anchor.
    auto tree = viewHoverPopup(tw, 0, HoverViewOptions(maxWidth: 40));
    auto f = layout(tree);
    const edge = AnchorRect(primary: Rect(90, 3, 6, 1), live: true);
    const g = placeHoverPopup(pal, edge, f[tree.root].rect.size,
        Rect(0, 0, 100, 30));
    assert(g.paintable && g.arrowVisible);
    applyPopupArrow(tree, g);
    const box = Rect(g.rect.x, g.rect.y, g.rect.width, g.rect.height);
    const at = arrowCellOf(box, tree.nodes[tree.root].decoration.arrowSide,
        tree.nodes[tree.root].decoration.arrowOffset);
    assert(box.x < 90, "the popup slid left to stay inside");
    assert(at.x == 93 || at.x == box.right - 2,
        "and the caret stayed on the token, not on the popup's edge");
}

@("render_widgets.applyPopupArrow.theCaretReachesTheGridAboveItsAnchor")
@safe unittest
{
    // Through a real grid, because the last two caret defects were both
    // invisible in the widget tree: the offset was right and the EDGE was
    // wrong, which type-checks because both are `BoxSide`.
    import sparkles.base.term_color : RgbColor;
    import sparkles.ui.display_list : buildDisplayList;
    import sparkles.ui.interp.cells : CellGrid;
    import sparkles.ui.interp.immediate : paint;
    import sparkles.ui.layout : layout;
    import sparkles.ui.style : defaultTwoslashPalette, schemeForBackground;

    const bg = RgbColor(0x1a, 0x1b, 0x26), fg = RgbColor(0xc0, 0xc0, 0xc0);
    const pal = defaultTwoslashPalette(schemeForBackground(bg));
    const tw = TwoslashReturn(code: "x", nodes: [
        Node(type: NodeType.hover, start: 0, length: 1,
            text: "int reduce(int[] r)", docs: "Some prose.\n"),
    ]);

    auto tree = viewHoverPopup(tw, 0, HoverViewOptions(maxWidth: 40));
    auto f = layout(tree);
    const anchor = AnchorRect(primary: Rect(20, 2, 6, 1), live: true);
    const g = placeHoverPopup(pal, anchor, f[tree.root].rect.size,
        Rect(0, 0, 80, 30));
    assert(g.paintable);
    applyPopupArrow(tree, g);

    auto grid = CellGrid(80, 30, fg, bg);
    paint(grid, buildDisplayList(tree, f, pal, fg, bg));

    // The tree lays out at the ORIGIN; only the host translates it to where
    // the solve put it. So the caret is checked against the tree's own frame,
    // and the anchor-tracking is the previous test's job.
    const box = f[tree.root].rect;
    const off = tree.nodes[tree.root].decoration.arrowOffset;

    size_t found;
    foreach (y; 0 .. grid.height)
        foreach (x; 0 .. grid.width)
            if (grid.cells[y * grid.width + x].glyph == '┴')
            {
                ++found;
                assert(y == box.y, "on the popup's own top row — the edge "
                    ~ "facing the anchor; `┬` would be the opposite one");
                assert(x == box.x + off, "at the cell the solve chose");
            }
    assert(found == 1, "exactly one caret");

    // And translated by the host, that cell lands on the token.
    assert(g.rect.x + off >= 20 && g.rect.x + off <= 26);
}

@("render_widgets.popupScrollExtents.theBarSurvivesTheFrameThatDrawsIt")
@safe unittest
{
    // The measurement and the bar are a FEEDBACK LOOP: the bar is built from
    // last frame's extents, and the extents are read off this frame's layout.
    // A measurement that only works while the bar is absent therefore unbuilds
    // the bar it just caused — the popup flickers, and on a terminal that
    // repaints per event the reader simply never sees one.
    //
    // Two frames prove nothing here. The loop has period two, and the second
    // frame is exactly the one that looked right.
    import sparkles.ui.layout : layout;
    import sparkles.ui.widget : WidgetKind;

    string docs;
    foreach (i; 0 .. 40)
        docs ~= "A paragraph that runs on for a while.\n\n";
    const tw = TwoslashReturn(code: "x", nodes: [
        Node(type: NodeType.hover, start: 0, length: 1,
            text: "int f(int a)", docs: docs),
    ]);

    static size_t bars(in WidgetTree t)
    {
        size_t n;
        foreach (ref const w; t.nodes)
            if (w.kind == WidgetKind.scrollbar)
                ++n;
        return n;
    }

    PopupScroll sc;
    foreach (frame; 0 .. 6)
    {
        const t = viewHoverPopup(tw, 0, HoverViewOptions(maxWidth: 44,
            maxHeight: 12, barContent: sc.content, barViewport: sc.viewport));
        auto f = layout(t);
        const now = popupScrollExtents(t, f);
        if (frame > 0)
        {
            assert(bars(t) == 1, "the bar must survive its own frame");
            assert(now.live, "and the measurement must survive the bar");
            // Not merely live: STILL THE SAME. A gutter costs the body a
            // column, never a row, so the vertical extents may not drift.
            assert(now.content == sc.content && now.viewport == sc.viewport,
                "a settled popup must measure the same every frame");
        }
        sc = now;
    }
}

@("render_widgets.popupScrollExtents.aFenceReportsItsSidewaysOverflow")
@system unittest
{
    // A fence's viewport holds ONE CHILD PER LINE. Reading its content extent
    // as "the width of its only child" matched no fence at all, so a code
    // block that plainly ran off the popup's edge reported nothing to scroll
    // — and a sideways wheel notch fell through to the document underneath.
    import sparkles.ui.layout : layout;
    import std.process : environment;

    // The fence only becomes a viewport once markdown has parsed it, which
    // needs the grammar bundle.
    if (environment.get("SPARKLES_TS_GRAMMAR_PATH", "").length == 0)
    {
        import sparkles.test_runner.skip : skipTest;
        skipTest("SPARKLES_TS_GRAMMAR_PATH unset");
        return;
    }
    auto registry = GrammarRegistry.fromEnvironment();

    // MORE THAN ONE LINE, deliberately: a one-line fence has a one-child
    // viewport and would pass under the very rule this test exists to reject.
    const wide = "auto x = someFunction(withArguments, thatGoOn, andOn, forever);";
    const tw = TwoslashReturn(code: "x", nodes: [
        Node(type: NodeType.hover, start: 0, length: 1, text: "int f(int a)",
            docs: "Prose.\n\n```d\nvoid main()\n{\n    " ~ wide
                ~ "\n}\n```\n"),
    ]);

    auto t = viewHoverPopup(tw, 0, registry, HoverViewOptions(maxWidth: 44,
        maxHeight: 12));
    auto f = layout(t);
    const sc = popupScrollExtents(t, f);
    assert(sc.liveFenceX, "the fence is wider than the popup lets it be");
    assert(sc.maxFenceX > 0);
    // The reported extent is the LINE's, not the viewport's: a bar built from
    // it must describe how far the code actually runs.
    assert(sc.fenceContentX >= cast(long) wide.length - 4,
        "the widest line, not the room it was given");
}

@("render_widgets.popupBarOf.theBarsAreNamedAndDistinct")
@safe unittest
{
    // A bar is a control, so a host must be able to say "the press landed on
    // the vertical thumb" — and must NOT mistake it for a collapsed run,
    // which is what an unnamed bar in a key-decoded surface becomes.
    import sparkles.ui.layout : layout;
    import sparkles.ui.state : keyTargets;
    import sparkles.ui.widget : WidgetKind;

    string docs;
    foreach (i; 0 .. 40)
        docs ~= "A paragraph that runs on for a while.\n\n";
    const tw = TwoslashReturn(code: "x", nodes: [
        Node(type: NodeType.hover, start: 0, length: 1,
            text: "int f(int a)", docs: docs),
    ]);

    const first = viewHoverPopup(tw, 0,
        HoverViewOptions(maxWidth: 44, maxHeight: 12, nodeKey: 7));
    auto f1 = layout(first);
    const sc = popupScrollExtents(first, f1);
    const t = viewHoverPopup(tw, 0, HoverViewOptions(maxWidth: 44,
        maxHeight: 12, nodeKey: 7,
        barContent: sc.content, barViewport: sc.viewport));

    foreach (ref const w; t.nodes)
        if (w.kind == WidgetKind.scrollbar)
            assert(popupBarOf(w.key) == PopupBar.vertical,
                "the bar must name itself");

    // And through the channel a host actually reads: a rect, so a grab can be
    // track-relative, from the same list the ✕ comes out of.
    auto targets = keyTargets(t, layout(t));
    bool sawBar;
    foreach (ref const kt; targets)
        if (popupBarOf(kt.key) == PopupBar.vertical)
        {
            sawBar = true;
            assert(kt.rect.height > 1, "a track has rows to grab along");
        }
    assert(sawBar, "the bar reaches keyTargets");

    // The three reserved meanings stay apart: a bar is not the ✕, and neither
    // is a collapsed run — the host's fallback arm toggles a region for any
    // key it does not recognise, so an overlap silently expands a signature.
    assert(!isPopupCloseKey(popupBarKey(7, PopupBar.vertical)));
    assert(!isPopupCloseKey(popupBarKey(7, PopupBar.horizontal)));
    assert(popupBarOf(popupCloseKey(7)) == PopupBar.none);
    assert(popupBarOf(abbrevKey(7, 0)) == PopupBar.none);
    assert(popupBarKey(7, PopupBar.vertical)
        != popupBarKey(7, PopupBar.horizontal));
}
