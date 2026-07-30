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
import sparkles.syntax.event : byStyledLine, HighlightEvent;
import sparkles.syntax.theme : ResolvedTheme;
import sparkles.ui.geometry : cellsOf, Insets;
import sparkles.ui.style : BorderStyle, Decoration, FontRole, Palette, Slot, TextStyle;
import sparkles.ui.widget : Builder, TextSpan, Widget, WidgetKind, WidgetTree;
import sparkles.ui.wrap : TextWrap;

import sparkles.twoslash.overlay : BelowBlock, errIsWarning,
    highlightSignature, planTwoslash, TwoslashPlan, withoutQuickinfoPrefix;
import sparkles.twoslash.protocol : Completion, Node, NodeType, TwoslashReturn;
import sparkles.twoslash.icons : completionIconGlyph, tagIconGlyph;

import sparkles.syntax.md.model : extractMarkdown, MdBlock, MdBlockKind, MdDoc,
    MdInline, MdInlineKind, Span;
import sparkles.syntax.ts.injection : TsConfigCache;
import sparkles.syntax.ts.registry : GrammarRegistry;
import sparkles.base.term_style : UnderlineStyle;

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
    import sparkles.base.smallbuffer : SmallBuffer;
    import sparkles.syntax.event : byStyledSpan;

    if (!sig.length)
        return null;
    SmallBuffer!HighlightEvent ev;
    highlightSignature(cache, language, sig, ev);
    TextSpan[] spans;
    foreach (sp; byStyledSpan(ev[]))
    {
        const spec = (*theme)[sp.label];
        spans ~= TextSpan(sig[sp.start .. sp.end], Slot.code,
            TextStyle.init, fg: toRgb(spec.fg, pageFg), hasFg: true);
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
WidgetTree viewTwoslashDocument(const TwoslashReturn tw,
    const(HighlightEvent)[] events, scope const(ResolvedTheme)* theme,
    RgbColor pageFg, TsConfigCache* cache = null)
{
    import sparkles.ui.canvas : LineStyle;
    import sparkles.ui.geometry : Point, SizeSpec;

    auto plan = planTwoslash(tw);
    auto b = Builder();

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
        const code = b.add(Widget(kind: WidgetKind.rich, spans: spans,
            slot: Slot.code));

        // Overlay decorations for this line: tints under the text (added
        // first ⇒ painted first), squiggles over it.
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
            else if (d.kind == NodeType.error)
            {
                const n = tw.nodes[d.node];
                const slot = errIsWarning(n.level) ? Slot.warn : Slot.error;
                const wavy = b.add(Widget(kind: WidgetKind.line, slot: slot,
                    lineStyle: LineStyle.wavy, lineTo: Point(cols, 0)));
                over ~= b.container(WidgetKind.column, [wavy], padding: at);
            }
        }

        rows ~= under.length || over.length
            ? b.container(WidgetKind.stack, under ~ code ~ over)
            : code;

        foreach (ref const blk; plan.belowBlocks)
            if (blk.line == line)
                rows ~= buildBelowBlock(b, tw.nodes[blk.node], blk.node,
                    sigSpans(tw.nodes[blk.node]));
    }

    return b.finish(b.container(WidgetKind.column, rows));
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
WidgetTree viewBelowBlock(const TwoslashReturn tw, size_t nodeIndex)
in (nodeIndex < tw.nodes.length)
{
    auto b = Builder();
    const root = buildBelowBlock(b, tw.nodes[nodeIndex], nodeIndex);
    return b.finish(root);
}

/// One below-line block: a left-indented `column` of a caret row + payload.
/// `sigSpans` (when non-empty) replaces a query signature's single-color text
/// with resolved syntax-colored spans.
private uint buildBelowBlock(ref Builder b, const Node node, size_t nodeIndex,
    TextSpan[] sigSpans = null)
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
            const sig = sigSpans.length
                ? b.add(Widget(kind: WidgetKind.rich, spans: sigSpans,
                    slot: Slot.code, hitId: hit))
                : b.add(Widget(kind: WidgetKind.text, text: node.text,
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
WidgetTree viewHoverPopup(const TwoslashReturn tw, size_t nodeIndex,
    TextSpan[] sigSpans = null)
in (nodeIndex < tw.nodes.length)
{
    auto b = Builder();
    const node = tw.nodes[nodeIndex];
    const hit = hitOf(nodeIndex);
    // No grammar registry ⇒ docs render as plain newline-split lines (JSDoc `\n`
    // must not reach a backend as a literal control char). The `registry` overlay
    // below renders them as full markdown.
    uint[] docsRows = node.docs.length ? plainDocsRows(b, node.docs, hit) : null;
    uint[] tagRows;
    foreach (ref const string[] tag; node.tags)
        tagRows ~= buildPopupTag(b, tag, hit);
    return finishHoverPopup(b, node, hit, docsRows, tagRows, sigSpans);
}

/**
As above, but renders the JSDoc `docs` as $(B markdown) (bold / italic / inline
code / links / lists / fenced code, wrapped to the popup width) via the
`sparkles:syntax` `MdDoc` model driven by `registry` — the same markdown seam the
HTML backend uses. Falls back to plain newline-split lines when the markdown
grammars are unavailable, so docs never vanish. `@system` (the tree-sitter parse).
*/
WidgetTree viewHoverPopup(const TwoslashReturn tw, size_t nodeIndex,
    ref GrammarRegistry registry, TextSpan[] sigSpans = null) @system
in (nodeIndex < tw.nodes.length)
{
    auto b = Builder();
    const node = tw.nodes[nodeIndex];
    const hit = hitOf(nodeIndex);
    uint[] docsRows = node.docs.length ? markdownDocsRows(b, registry, node.docs, hit) : null;
    uint[] tagRows;
    foreach (ref const string[] tag; node.tags)
        tagRows ~= buildPopupTagMd(b, registry, tag, hit);
    return finishHoverPopup(b, node, hit, docsRows, tagRows, sigSpans);
}

/// Assembles the popup shell shared by both `viewHoverPopup` overloads: three
/// full-width sections — the signature (code face), the description (`docsRows`),
/// and the JSDoc tags (`tagRows`) — each separated by a horizontal divider (a top
/// border spanning border-to-border, CSS `.twoslash-popup-docs border-top`), all
/// inside the floating surface (border/radius/shadow/arrow). The popup carries no
/// horizontal padding so the dividers reach the edges; each section pads its own.
private WidgetTree finishHoverPopup(ref Builder b, const Node node, size_t hit,
    uint[] docsRows, uint[] tagRows, TextSpan[] sigSpans = null)
{
    // Signature (CSS `.twoslash-popup-code`): the code face at 1em — as
    // resolved syntax-colored spans when the caller supplied them
    // (signatureSpans), so no backend re-highlights over the painted popup.
    const sigStyle = TextStyle(fontRole: FontRole.code,
        fontScale: M.codeFontScale);
    const sig = sigSpans.length
        ? b.add(Widget(kind: WidgetKind.rich, spans: sigSpans, slot: Slot.code,
            hitId: hit, textStyle: sigStyle))
        : b.add(Widget(kind: WidgetKind.text,
            text: withoutQuickinfoPrefix(node.text), slot: Slot.code,
            hitId: hit, textStyle: sigStyle));

    uint[] sections = [popupSection(b, [sig], divider: false)];
    if (docsRows.length)
        sections ~= popupSection(b, docsRows, divider: true);
    if (tagRows.length)
        sections ~= popupSection(b, tagRows, divider: true);

    const col = b.container(WidgetKind.column, sections);
    const popup = b.add(Widget(kind: WidgetKind.popup, slot: Slot.surface,
        padding: Insets(1, 0, 1, 0), paintBackground: true,
        decoration: surfaceDeco(arrow: true), children: [col], hitId: hit));
    return b.finish(popup);
}

/// A full-width popup section: a `stretch` column with its own horizontal padding
/// (`6px 8px` in the CSS) and, when `divider`, a 1px top border that — because the
/// section stretches to the popup width and the popup has no horizontal padding —
/// spans border-to-border as the section separator.
private uint popupSection(ref Builder b, uint[] rows, bool divider)
    => b.add(Widget(kind: WidgetKind.column, children: rows, stretch: true,
        padding: Insets(0, 1, 0, 1),
        decoration: divider
            ? Decoration(borderWidth: Insets(M.borderWidth, 0, 0, 0),
                borderStyle: BorderStyle.solid, borderSlot: Slot.border) : Decoration.init));

// ── JSDoc docs → widget rows (markdown, wrapped) ───────────────────────────

/// The popup docs width *maximum*, in cells — a style metric handed to the
/// layout engine (`Widget.width.max`), which wraps the rich run itself
/// (`LAY10`: no packing loop in the view).
private enum docsMaxWidth = 56;

/// Renders `docs` (JSDoc markdown) into wrapped, inline-styled widget rows via the
/// `sparkles:syntax` `MdDoc` model. Empty parse (no grammar) ⇒ plain-line fallback.
private uint[] markdownDocsRows(ref Builder b, ref GrammarRegistry registry,
    const(char)[] docs, size_t hit) @system
{
    import sparkles.syntax.md.render_widgets : MdViewOptions, viewMarkdownInto;

    MdDoc doc = extractMarkdown(registry, docs);
    if (doc.root.children.length == 0)
        return plainDocsRows(b, docs, hit);
    // The shared composable markdown view — "JSDoc renders through the same
    // markdown view" — with the popup's docs face/slot/width and hit identity.
    return [viewMarkdownInto(b, doc, MdViewOptions(
        maxWidth: docsMaxWidth, hitId: hit,
        baseStyle: docsBase(), proseSlot: Slot.docs))];
}
/// Docs fallback (no markdown grammar): the raw text split on newlines into rows,
/// so a `\n` reads as a line break instead of a tofu glyph.
private uint[] plainDocsRows(ref Builder b, const(char)[] docs, size_t hit)
{
    uint[] rows;
    size_t start = 0;
    foreach (i, char c; docs)
        if (c == '\n')
        {
            rows ~= docsLine(b, docs[start .. i], hit);
            start = i + 1;
        }
    rows ~= docsLine(b, docs[start .. $], hit);
    return rows;
}

private uint docsLine(ref Builder b, const(char)[] text, size_t hit)
    => b.add(Widget(kind: WidgetKind.text, text: text.length ? text : " ",
        slot: Slot.docs, hitId: hit,
        textStyle: TextStyle(fontRole: FontRole.docs, fontScale: M.docsFontScale)));

private TextStyle docsBase() pure nothrow @nogc
    => TextStyle(fontRole: FontRole.docs, fontScale: M.docsFontScale);


/// `src[span]` guarded against a malformed range.
private const(char)[] sliceOf(const(char)[] src, in Span s) @safe
    => s.start <= s.end && s.end <= src.length ? src[s.start .. s.end] : "";

/// A JSDoc tag row inside a hover popup: a `@name` pill (`Slot.chip` — muted text
/// on a grey fill, like the HTML `.twoslash-popup-docs-tag-name`) + its text.
private uint buildPopupTag(ref Builder b, const string[] tag, size_t hit)
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
        parts ~= b.add(Widget(kind: WidgetKind.text, text: tag[1],
            slot: Slot.docs, hitId: hit,
            textStyle: TextStyle(fontRole: FontRole.docs, fontScale: M.docsFontScale)));
    return b.container(WidgetKind.row, parts, gap: 1);
}

/// As `buildPopupTag`, but the tag $(I value) renders as inline markdown (a `@see`
/// value's `[label](url)` becomes an underlined link, `` `code` `` a pill, etc.),
/// via the grammar `registry`. `@system` (the tree-sitter parse).
private uint buildPopupTagMd(ref Builder b, ref GrammarRegistry registry,
    const string[] tag, size_t hit) @system
{
    const nameText = tag.length ? tagName(b, tag[0]) : tagName(b, "");
    uint[] parts;
    parts ~= b.add(Widget(kind: WidgetKind.text, text: nameText,
        slot: Slot.chip, hitId: hit, paintBackground: true,
        decoration: Decoration(borderRadius: M.popupRadius),
        textStyle: TextStyle(fontRole: FontRole.code, fontScale: M.tagFontScale)));

    if (tag.length > 1 && tag[1].length)
    {
        import sparkles.syntax.md.render_widgets : inlinesToSpans, pushProse;

        TextSpan[] spans;
        spans ~= TextSpan(" ", Slot.docs, docsBase()); // gap after the chip
        MdDoc doc = extractMarkdown(registry, tag[1]);
        if (doc.root.children.length)
            foreach (ref const blk; doc.root.children)
                inlinesToSpans(blk.inlines, tag[1], docsBase(), Slot.docs, spans);
        else
            pushProse(tag[1], docsBase(), Slot.docs, spans);

        // The value on one unwrapped rich run (tag values are short).
        parts ~= b.add(Widget(kind: WidgetKind.rich, slot: Slot.docs, hitId: hit,
            spans: spans, textStyle: docsBase(),
            decoration: Decoration(borderRadius: M.popupRadius)));
    }
    return b.container(WidgetKind.row, parts, gap: 0);
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
    foreach (ref op; c.ops)
    {
        // Signature: the code face at 1em.
        if (op.text == "function wrap<T>(value: T): Box<T>")
            sawSig = op.visual.fontRole == FontRole.code && op.visual.fontScale == 100;
        // Docs: the sans face at 0.8em, muted.
        if (op.text == "Wraps a value in a Box." && op.visual.fg == RgbColor(0x88, 0x88, 0x88))
            sawDocs = op.visual.fontRole == FontRole.docs && op.visual.fontScale == 80;
        // The `@param` chip: a rounded grey pill in the code face at 0.92em.
        if (op.text == "@param" && op.visual.fg == RgbColor(0x88, 0x88, 0x88)
            && op.visual.hasBg && op.visual.borderRadius == 4
            && op.visual.fontRole == FontRole.code && op.visual.fontScale == 92)
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

@("render_widgets.docs.markdownInlineStyling")
@safe unittest
{
    import sparkles.base.term_style : TextAttr;

    import sparkles.syntax.md.render_widgets : MdViewOptions, viewMarkdownInto;

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
