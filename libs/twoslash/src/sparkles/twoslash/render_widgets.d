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

import sparkles.ui.geometry : Insets;
import sparkles.ui.style : Slot;
import sparkles.ui.widget : Builder, Widget, WidgetKind, WidgetTree;

import sparkles.twoslash.overlay : BelowBlock, errIsWarning, planTwoslash,
    TwoslashPlan, withoutQuickinfoPrefix;
import sparkles.twoslash.protocol : Completion, Node, NodeType, TwoslashReturn;
import sparkles.twoslash.icons : completionIconGlyph, tagIconGlyph;

@safe:

/// The hit id a widget derived from node `nodeIndex` carries (0 = none).
private size_t hitOf(size_t nodeIndex) pure nothrow @nogc => nodeIndex + 1;

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
WidgetTree viewBelowBlock(const TwoslashReturn tw, size_t nodeIndex)
in (nodeIndex < tw.nodes.length)
{
    auto b = Builder();
    const root = buildBelowBlock(b, tw.nodes[nodeIndex], nodeIndex);
    return b.finish(root);
}

/// One below-line block: a left-indented `column` of a caret row + payload.
private uint buildBelowBlock(ref Builder b, const Node node, size_t nodeIndex)
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
            return b.container(WidgetKind.column, [caret, msg], padding: indent);

        case NodeType.query:
            const caret = b.add(Widget(kind: WidgetKind.text,
                text: "^?", slot: Slot.caret, hitId: hit));
            const sig = b.add(Widget(kind: WidgetKind.text, text: node.text,
                slot: Slot.code, hitId: hit));
            return b.container(WidgetKind.column, [caret, sig], padding: indent);

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
            return b.container(WidgetKind.row, parts, gap: 1, padding: indent);

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
WidgetTree viewHoverPopup(const TwoslashReturn tw, size_t nodeIndex)
in (nodeIndex < tw.nodes.length)
{
    const node = tw.nodes[nodeIndex];
    const hit = hitOf(nodeIndex);
    auto b = Builder();

    uint[] rows;
    rows ~= b.add(Widget(kind: WidgetKind.text,
        text: withoutQuickinfoPrefix(node.text), slot: Slot.code, hitId: hit));

    if (node.docs.length)
        rows ~= b.add(Widget(kind: WidgetKind.text, text: node.docs,
            slot: Slot.docs, hitId: hit));

    foreach (ref const string[] tag; node.tags)
        rows ~= buildPopupTag(b, tag, hit);

    const col = b.container(WidgetKind.column, rows);
    const popup = b.container(WidgetKind.popup, [col],
        slot: Slot.surface, padding: Insets.all(1), paintBackground: true);
    return b.finish(popup);
}

/// A JSDoc tag row inside a hover popup: `@name` chip (`Slot.info`) + its text.
private uint buildPopupTag(ref Builder b, const string[] tag, size_t hit)
{
    const nameText = tag.length ? tagName(b, tag[0]) : tagName(b, "");
    uint[] parts;
    parts ~= b.add(Widget(kind: WidgetKind.text, text: nameText,
        slot: Slot.info, hitId: hit));
    if (tag.length > 1 && tag[1].length)
        parts ~= b.add(Widget(kind: WidgetKind.text, text: tag[1],
            slot: Slot.docs, hitId: hit));
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

@("render_widgets.viewTwoslash.errorBlock")
@safe unittest
{
    const tw = TwoslashReturn(
        code: "const b = a\n",
        nodes: [Node(type: NodeType.error, start: 6, length: 1, line: 0,
            character: 6, text: "Cannot find name 'a'.", level: "error", code: 2304)]);

    auto c = render(viewTwoslash(tw));

    // caret ("^") + message, both in the error color, indented to column 6.
    const err = RgbColor(0xd4, 0x56, 0x56);
    assert(c.ops.length == 2);
    assert(c.ops[0].kind == OpKind.textRun && c.ops[0].text == "^");
    assert(c.ops[0].visual.fg == err && c.ops[0].rect.x == 6);
    assert(c.ops[1].text == "Cannot find name 'a'." && c.ops[1].visual.fg == err);
    assert(c.ops[1].rect.x == 6);
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

@("render_widgets.viewHoverPopup.surfaceSignatureDocsTags")
@safe unittest
{
    const tw = TwoslashReturn(code: "wrap(1)\n",
        nodes: [Node(type: NodeType.hover, start: 0, length: 4, line: 0, character: 0,
            text: "(alias) function wrap<T>(value: T): Box<T>",
            docs: "Wraps a value in a Box.",
            tags: [["param", "value - the wrapped value"], ["returns", "a Box"]])]);

    auto c = render(viewHoverPopup(tw, 0));

    // A surface background fill comes first, then the signature (page fg),
    // the docs (muted), and the tag chips (info color).
    assert(c.ops[0].kind == OpKind.fillRect);
    assert(c.ops[0].visual.bg == RgbColor(0xf8, 0xf8, 0xf8));

    bool sawSig, sawDocs, sawTag;
    foreach (ref op; c.ops)
    {
        if (op.text == "function wrap<T>(value: T): Box<T>")
            sawSig = true; // quickinfo prefix "(alias) " stripped
        if (op.text == "Wraps a value in a Box." && op.visual.fg == RgbColor(0x88, 0x88, 0x88))
            sawDocs = true;
        if (op.text == "@param" && op.visual.fg == RgbColor(0x37, 0x72, 0xcf))
            sawTag = true;
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
