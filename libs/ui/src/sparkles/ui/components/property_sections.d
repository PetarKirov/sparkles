/**
The property tree as a page of sections with inline controls (`PRT36`–`PRT40`,
terminal mockup G3): the touch presentation of the same rows
$(MREF sparkles,ui,components,property_view) draws as a keyboard tree.

$(UL
    $(LI $(B Sections) (`PRT36`): each section node (`PropertyNode.section`)
    is a header row — its heading, collapsible, a summary while collapsed —
    and its children follow in declaration order. There is no ordering
    table.)
    $(LI $(B Descriptions) (`PRT37`): a leaf's `@Description` sits under its
    label, muted.)
    $(LI $(B Inline editors by type) (`PRT38`, $(LREF inlineEditorFor)):
    toggle, segmented control, dropdown, stepper, swatch, text field, or a
    drill-in row previewing an aggregate or array.)
    $(LI $(B Changed marker and reset) (`PRT39`): a leaf off its default
    shows `●` (a glyph, not colour alone) and a `↺` reset.)
    $(LI $(B Provenance chips) (`PRT40`): the host's layer or note, as a
    chip.)
)

The module builds widgets and decodes hits; it never edits. A host turns a
hit ($(LREF decodeSectionHit)) into the settings pane's edits by path
(`SettingsPane.setAt`, `stepAt`, `resetAt`, `editTextAt`), so every control
commits through the one validated dispatch, with its refusal and undo.
*/
module sparkles.ui.components.property_sections;

import std.conv : text;

import sparkles.base.term_color : RgbColor;
import sparkles.ui.components.tree_widget : TreeData;
import sparkles.ui.geometry : cellsOf, Insets, SizeSpec;
import sparkles.ui.property_tree : LeafKind, PropertyNode, SearchRole;
import sparkles.ui.style : BorderStyle, Decoration, Slot, TextStyle;
import sparkles.ui.widget : Alignment, Builder, TextSpan, Widget, WidgetKind;
import sparkles.ui.wrap : TextWrap;

@safe:

// ─────────────────────────────────────────────────────────────────────────────
// What a row is.
// ─────────────────────────────────────────────────────────────────────────────

/// The inline editor a row carries (`PRT38`).
enum InlineEditor : ubyte
{
    none,      /// a status row
    toggle,    /// `bool`
    segmented, /// an enum of at most 4 members that fits
    dropdown,  /// a larger enum
    stepper,   /// a number: `−` value `+`, `@Range`'s step
    swatch,    /// a `@colorValue` text leaf
    text,      /// a text leaf: the line editor
    drillIn,   /// an aggregate or array: opens a level
    readOnly,  /// shown, not editable
}

/**
The editor a row gets, from its type and UDAs — never per call site
(`PRT38`). An enum of at most 4 members is a segmented control when its labels
fit `segmentCells` cells, a dropdown otherwise.
*/
InlineEditor inlineEditorFor(in PropertyNode n, int segmentCells = 32) pure
{
    if (n.synthetic)
        return InlineEditor.none;
    if (n.composite)
        return InlineEditor.drillIn;
    if (!n.editable)
        return InlineEditor.readOnly;
    final switch (n.kind)
    {
        case LeafKind.none:
        case LeafKind.opaque:
            return InlineEditor.readOnly;
        case LeafKind.boolean:
            return InlineEditor.toggle;
        case LeafKind.enumeration:
            return n.choices.length <= 4 && segmentsWidth(n) <= segmentCells
                ? InlineEditor.segmented : InlineEditor.dropdown;
        case LeafKind.integral:
        case LeafKind.floating:
            return InlineEditor.stepper;
        case LeafKind.text:
            return n.color ? InlineEditor.swatch : InlineEditor.text;
    }
}

/// The cells a segmented control over `n`'s choices takes.
int segmentsWidth(in PropertyNode n) pure
{
    int w;
    foreach (i; 0 .. n.choices.length)
        w += cast(int) cellsOf(choiceLabel(n, i)) + 2;
    return w;
}

/// Choice `i` as a person reads it: the wire spelling, words split.
string choiceLabel(in PropertyNode n, size_t i) pure
    => humanize(i < n.choiceLabels.length ? n.choiceLabels[i] : n.choices[i]);

/// A camel-case identifier as words: `promptOnFailure` → `prompt on failure`.
/// A string with a space or an upper-case run (`OSC 52`) is kept.
string humanize(string ident) pure
{
    import std.ascii : isLower, isUpper, toLower;

    foreach (c; ident)
        if (c == ' ')
            return ident;
    string s;
    foreach (i, c; ident)
    {
        if (isUpper(c) && i > 0 && isLower(ident[i - 1]))
            s ~= ' ';
        s ~= isUpper(c) && !(i + 1 < ident.length && isUpper(ident[i + 1]))
            && !(i > 0 && isUpper(ident[i - 1])) ? toLower(c) : c;
    }
    return s;
}

///
@("ui.property_sections.humanize.splitsCamelCase")
@safe pure unittest
{
    assert(humanize("promptOnFailure") == "prompt on failure");
    assert(humanize("auto") == "auto");
    assert(humanize("OSC 52") == "OSC 52");
    assert(humanize("iconText") == "icon text");
}

/// A label with its first letter capitalised: `follow system` → `Follow system`.
string sentenceCase(string s) pure
{
    import std.ascii : toUpper;

    return s.length && s[0] >= 'a' && s[0] <= 'z' ? toUpper(s[0]) ~ s[1 .. $] : s;
}

/// The value a text leaf's badge renders, without its quotes.
string unquoted(string badge) pure nothrow @nogc
    => badge.length >= 2 && badge[0] == '"' && badge[$ - 1] == '"'
        ? badge[1 .. $ - 1] : badge;

/// `#rrggbb` / `#rgb` as a colour; false for anything else (an empty entry).
bool swatchColor(string value, out RgbColor c) pure nothrow @nogc
{
    import sparkles.base.term_color : Color, parseHexColor;

    const(char)[] s = value;
    auto r = parseHexColor(s);
    if (r.hasError || s.length || r.value.kind != Color.Kind.rgb)
        return false;
    c = r.value.rgb;
    return true;
}

// ─────────────────────────────────────────────────────────────────────────────
// The rows of a level.
// ─────────────────────────────────────────────────────────────────────────────

/// One row of the page.
struct SectionItem
{
    /// ditto
    enum Kind : ubyte
    {
        header, /// a section header (`PRT36`)
        leaf,   /// a value with its inline editor
        drill,  /// an aggregate or array: a drill-in row
        status, /// a synthetic row ("No properties match")
    }

    Kind kind;     ///
    uint node;     /// the row's node in the tree data
    /// The label shown: the node's, prefixed by the levels a search result
    /// skipped (`font › size`).
    string label;
    /// For a header: whether it is collapsed.
    bool collapsed;
}

/**
The rows of one level of `data` (the tree built with every node open). At
the top (`root` empty) each section node is a header followed by its
children; a level below (`root` a path) is that node's header and children.
A nested aggregate or array is a drill-in row — except under a search, which
flattens: every matching leaf shows under its section, its label prefixed by
the levels between. `collapsed(path)` folds a header to itself.
*/
SectionItem[] sectionItems(ref const TreeData!PropertyNode data, string root, bool searching,
    scope bool delegate(string path) @safe collapsed = null)
{
    SectionItem[] items;

    void addChild(uint c, string prefix)
    {
        const n = &data.nodes[c].value;
        if (n.synthetic)
        {
            items ~= SectionItem(SectionItem.Kind.status, c, n.label);
            return;
        }
        const label = prefix ~ sentenceCase(n.label);
        if (!n.composite)
        {
            items ~= SectionItem(SectionItem.Kind.leaf, c, label);
            return;
        }
        // Under a search, a composite that is only context opens in place.
        if (searching && n.role != SearchRole.direct && data.nodes[c].firstChild != uint.max)
        {
            for (uint k = data.nodes[c].firstChild; k != uint.max; k = data.nodes[k].nextSibling)
                addChild(k, label ~ " › ");
            return;
        }
        items ~= SectionItem(SectionItem.Kind.drill, c, label);
    }

    void addSection(uint s)
    {
        const n = &data.nodes[s].value;
        const folded = !searching && collapsed !is null && collapsed(n.path);
        items ~= SectionItem(SectionItem.Kind.header, s, n.heading, folded);
        if (folded)
            return;
        for (uint k = data.nodes[s].firstChild; k != uint.max; k = data.nodes[k].nextSibling)
            addChild(k, null);
    }

    if (root.length)
    {
        foreach (i, ref nd; data.nodes)
            if (nd.value.path == root)
            {
                addSection(cast(uint) i);
                break;
            }
        return items;
    }
    for (uint r = data.firstRoot; r != uint.max; r = data.nodes[r].nextSibling)
    {
        if (data.nodes[r].value.section)
            addSection(r);
        else
            addChild(r, null);
    }
    return items;
}

// ─────────────────────────────────────────────────────────────────────────────
// Hits.
// ─────────────────────────────────────────────────────────────────────────────

/// What part of a row a hit is (`decodeSectionHit`).
enum SectionPart : uint
{
    row = 0,        /// the row itself: focus it, or open a drill-in / header
    reset = 1,      /// `↺` (`PRT39`)
    dec = 2,        /// the stepper's `−`
    inc = 3,        /// the stepper's `+`
    toggle = 4,     /// the toggle
    open = 5,       /// a dropdown, a swatch, a text field: open its editor
    accept = 6,     /// the line editor's ✓
    cancelEdit = 7, /// the line editor's ✕
    choice0 = 8,    /// a segment or a dropdown option: `choice0 + i`
}

private enum uint partsPerNode = 64;

/// The hit id of `part` of `node`'s row.
size_t sectionHit(size_t base, uint node, uint part) pure nothrow @nogc
    => base + cast(size_t) node * partsPerNode + part;

/// The node and part `id` names; false when it is not a row's.
bool decodeSectionHit(size_t base, size_t id, out uint node, out uint part)
    pure nothrow @nogc
{
    if (id < base)
        return false;
    node = cast(uint)((id - base) / partsPerNode);
    part = cast(uint)((id - base) % partsPerNode);
    return true;
}

///
@("ui.property_sections.sectionHit.roundTrips")
@safe pure nothrow @nogc unittest
{
    uint n, p;
    assert(decodeSectionHit(1000, sectionHit(1000, 17, SectionPart.choice0 + 2), n, p));
    assert(n == 17 && p == SectionPart.choice0 + 2);
    assert(!decodeSectionHit(1000, 999, n, p));
}

// ─────────────────────────────────────────────────────────────────────────────
// The view.
// ─────────────────────────────────────────────────────────────────────────────

/// The host's facts about one row.
struct RowState
{
    bool changed;     /// off its default (`PRT39`)
    string chip;      /// the provenance chip (`PRT40`); empty: none
    bool chipWarn;    /// the chip warns (an override note, a shadowing layer)
    bool focused;     /// the keyboard cursor is here
    bool open;        /// its dropdown is open
    bool editing;     /// the line editor is open on it
    string editText;  /// ditto: the text so far
    string refusal;   /// the edit's refusal, inline (`PRT21`)
}

/// Presentation knobs.
struct SectionsOptions
{
    /// Rows a control takes to be a touch target (`TOK7`).
    int targetRows = 1;
    /// Cells across.
    int width = 60;
    /// A touch screen: the line editor gets ✓ and ✕ buttons.
    bool touch;

    /// The cells a segmented control may take before an enum becomes a
    /// dropdown: what `inlineEditorFor` is asked with, by the view and by a
    /// host that acts on a hit alike.
    int segmentCells() const @safe pure nothrow @nogc => width * 2 / 5;
}

/// The slots this view references (design-system `TOK6`).
enum Slot[] propertySectionSlots = [Slot.chrome, Slot.chromeAccent, Slot.selection,
    Slot.muted, Slot.textPrimary, Slot.surfaceRaised, Slot.surfaceSunken, Slot.border,
    Slot.warn, Slot.error, Slot.accentPrimary, Slot.caret, Slot.code];

private SizeSpec atLeast(int rows) pure nothrow @nogc
    => SizeSpec(SizeSpec.Kind.fit, 0, rows > 1 ? rows : 0);

/// A small bordered pill around `text`: a chip, a segment, a button.
private uint pill(ref Builder b, string text, Slot slot, size_t hitId, bool filled,
    bool bold = false, int rows = 1)
{
    const t = b.add(Widget(kind: WidgetKind.text, text: text,
        slot: filled ? Slot.chromeAccent : slot, textStyle: TextStyle(bold: bold)));
    return b.add(Widget(kind: WidgetKind.panel, children: [t], padding: Insets(0, 1, 0, 1),
        height: rows > 1 ? SizeSpec.fixed(rows) : SizeSpec.fit_,
        alignY: Alignment.center, hitId: hitId,
        slot: filled ? Slot.chromeAccent : Slot.surfaceRaised, paintBackground: true,
        decoration: Decoration(borderRadius: 6)));
}

/**
A section's header row (`PRT36`): `▾ HEADING` on the band, `detail` (the
section's path, or a match count) on the right; collapsed, `▸` and the
summary. The whole row is `hitId`.
*/
uint sectionHeader(ref Builder b, string heading, string detail, bool collapsed,
    size_t hitId, in SectionsOptions opt)
{
    import std.uni : toUpper;

    const title = b.add(Widget(kind: WidgetKind.text,
        text: (collapsed ? "▸ " : "▾ ") ~ heading.toUpper, slot: Slot.chromeAccent,
        textStyle: TextStyle(bold: true), width: SizeSpec.grow()));
    const right = b.add(Widget(kind: WidgetKind.text, text: detail, slot: Slot.muted));
    return b.add(Widget(kind: WidgetKind.row, children: [title, right], gap: 1,
        width: SizeSpec.grow(), height: atLeast(opt.targetRows),
        padding: Insets(0, 1, 0, 1), alignY: Alignment.center, hitId: hitId,
        slot: Slot.chrome, paintBackground: true));
}

/// A collapsed section's one-line summary (`PRT36`): what it holds.
string sectionSummary(ref const TreeData!PropertyNode data, uint node)
{
    size_t values, levels;
    for (uint k = data.nodes[node].firstChild; k != uint.max; k = data.nodes[k].nextSibling)
    {
        if (data.nodes[k].value.synthetic)
            continue;
        if (data.nodes[k].value.composite)
            levels++;
        else
            values++;
    }
    string s = text(values, values == 1 ? " setting" : " settings");
    if (levels)
        s ~= text(" · ", levels, levels == 1 ? " group" : " groups");
    return s;
}

/**
One leaf or drill-in row of `data` (`PRT37`–`PRT40`): label, changed marker
and description on the left; the chip, the reset and the inline editor on
the right; an open dropdown's options, the line editor and a refusal under
it. Hit ids are $(LREF sectionHit)`(hitBase, item.node, part)`.
*/
uint sectionRow(ref Builder b, ref const TreeData!PropertyNode data, ref const SectionItem item,
    ref const RowState st, in SectionsOptions opt, size_t hitBase)
{
    const n = &data.nodes[item.node].value;
    size_t hit(uint part) => sectionHit(hitBase, item.node, part);

    if (item.kind == SectionItem.Kind.status)
        return b.add(Widget(kind: WidgetKind.text, text: item.label, slot: Slot.muted,
            padding: Insets(0, 2, 0, 2)));

    // The left: label, the changed marker, the description.
    uint[] left;
    {
        TextSpan[] spans = [TextSpan(text: item.label, slot: Slot.textPrimary)];
        if (st.changed)
            spans ~= TextSpan(text: " ●", slot: Slot.accentPrimary);
        left ~= b.add(Widget(kind: WidgetKind.rich, spans: spans));
        if (n.doc.length)
            left ~= b.add(Widget(kind: WidgetKind.text, text: n.doc, slot: Slot.muted,
                wrap: TextWrap.greedy, width: SizeSpec.grow()));
    }
    const leftCol = b.add(Widget(kind: WidgetKind.column, children: left,
        width: SizeSpec.grow(), clipX: true));

    uint[] parts = [leftCol];
    if (st.chip.length)
        parts ~= b.add(Widget(kind: WidgetKind.panel,
            children: [b.add(Widget(kind: WidgetKind.text, text: st.chip,
                slot: st.chipWarn ? Slot.warn : Slot.muted))],
            padding: Insets(0, 1, 0, 1),
            decoration: Decoration(borderStyle: BorderStyle.solid, borderWidth: Insets.all(1),
                borderSlot: st.chipWarn ? Slot.warn : Slot.border, borderRadius: 4)));
    if (st.changed && item.kind == SectionItem.Kind.leaf && n.editable)
        parts ~= pill(b, "↺", Slot.muted, hit(SectionPart.reset), false, false, 1);

    const rows = opt.targetRows;
    const editor = item.kind == SectionItem.Kind.drill ? InlineEditor.drillIn
        : inlineEditorFor(*n, opt.segmentCells);
    final switch (editor)
    {
        case InlineEditor.none:
            break;
        case InlineEditor.toggle:
        {
            const on = n.badge == "true";
            parts ~= pill(b, on ? "on ●" : "● off", on ? Slot.chromeAccent : Slot.muted,
                hit(SectionPart.toggle), on, on, 1);
            break;
        }
        case InlineEditor.segmented:
        {
            uint[] segs;
            foreach (i, c; n.choices)
                segs ~= pill(b, choiceLabel(*n, i), Slot.textPrimary,
                    hit(cast(uint)(SectionPart.choice0 + i)), c == n.badge, c == n.badge, 1);
            parts ~= b.add(Widget(kind: WidgetKind.row, children: segs,
                decoration: Decoration(borderStyle: BorderStyle.solid, borderWidth: Insets.all(1),
                    borderSlot: Slot.border, borderRadius: 6)));
            break;
        }
        case InlineEditor.dropdown:
        {
            string shown = n.badge;
            foreach (i, c; n.choices)
                if (c == n.badge)
                    shown = choiceLabel(*n, i);
            parts ~= pill(b, shown ~ (st.open ? " ▴" : " ▾"), Slot.textPrimary,
                hit(SectionPart.open), false, false, 1);
            break;
        }
        case InlineEditor.stepper:
        {
            const dec = pill(b, "−", Slot.textPrimary, hit(SectionPart.dec), false, false, 1);
            const val = b.add(Widget(kind: WidgetKind.text, text: n.badge, slot: Slot.code));
            const inc = pill(b, "+", Slot.textPrimary, hit(SectionPart.inc), false, false, 1);
            parts ~= b.add(Widget(kind: WidgetKind.row, children: [dec, val, inc], gap: 1,
                alignY: Alignment.center));
            break;
        }
        case InlineEditor.swatch:
        {
            const v = unquoted(n.badge);
            RgbColor c;
            const has = swatchColor(v, c);
            TextSpan[] spans;
            spans ~= TextSpan(text: has ? "   " : " ∅ ", slot: Slot.muted,
                bg: c, hasBg: has, paintBackground: has);
            spans ~= TextSpan(text: " " ~ (v.length ? v : "default"), slot: Slot.code);
            parts ~= b.add(Widget(kind: WidgetKind.rich, spans: spans,
                hitId: hit(SectionPart.open)));
            break;
        }
        case InlineEditor.text:
        {
            string v = unquoted(n.badge);
            const room = opt.width / 3 > 8 ? opt.width / 3 : 8;
            if (cellsOf(v) > room)
                v = clipCells(v, room - 1) ~ "…";
            parts ~= pill(b, (v.length ? v : "—") ~ " ✎", Slot.code, hit(SectionPart.open),
                false, false, 1);
            break;
        }
        case InlineEditor.drillIn:
            parts ~= drillPreview(b, data, item.node);
            parts ~= b.add(Widget(kind: WidgetKind.text, text: "›", slot: Slot.muted));
            break;
        case InlineEditor.readOnly:
            parts ~= b.add(Widget(kind: WidgetKind.text,
                text: clipCells(unquoted(n.badge), opt.width / 3) ~ " ⊘", slot: Slot.muted));
            break;
    }

    // The controls keep their width; the label and description wrap instead.
    foreach (p; parts[1 .. $])
        b.nodes[p].width = SizeSpec(SizeSpec.Kind.fit, 0, naturalCells(b, p));
    const main = b.add(Widget(kind: WidgetKind.row, children: parts, gap: 1,
        width: SizeSpec.grow(), height: atLeast(rows), alignY: Alignment.center,
        hitId: hit(SectionPart.row)));
    uint[] stack_ = [main];

    // An open dropdown's options, one touch target each.
    if (editor == InlineEditor.dropdown && st.open)
        foreach (i, c; n.choices)
        {
            const picked = c == n.badge;
            stack_ ~= b.add(Widget(kind: WidgetKind.row, children: [b.add(Widget(
                kind: WidgetKind.text, text: (picked ? "✓ " : "  ") ~ choiceLabel(*n, i),
                slot: picked ? Slot.chromeAccent : Slot.textPrimary,
                textStyle: TextStyle(bold: picked)))],
                width: SizeSpec.grow(), height: atLeast(rows), alignY: Alignment.center,
                padding: Insets(0, 2, 0, 2), hitId: hit(cast(uint)(SectionPart.choice0 + i)),
                slot: Slot.surfaceSunken, paintBackground: true));
        }

    // The line editor: the text so far, the caret, ✓ and ✕ on touch.
    if (st.editing)
    {
        uint[] field = [b.add(Widget(kind: WidgetKind.rich, spans: [
            TextSpan(text: st.editText, slot: Slot.code),
            TextSpan(text: "▏", slot: Slot.caret)], width: SizeSpec.grow(), clipX: true))];
        if (opt.touch)
        {
            field ~= pill(b, "✓", Slot.textPrimary, hit(SectionPart.accept), true, true, rows);
            field ~= pill(b, "✕", Slot.textPrimary, hit(SectionPart.cancelEdit), false, false,
                rows);
        }
        stack_ ~= b.add(Widget(kind: WidgetKind.row, children: field, gap: 1,
            width: SizeSpec.grow(), height: atLeast(rows), alignY: Alignment.center,
            padding: Insets(0, 1, 0, 1), slot: Slot.surfaceSunken, paintBackground: true,
            decoration: Decoration(borderStyle: BorderStyle.solid, borderWidth: Insets.all(1),
                borderSlot: Slot.accentPrimary, borderRadius: 6)));
    }

    if (st.refusal.length)
        stack_ ~= b.add(Widget(kind: WidgetKind.text, text: "⚠ " ~ st.refusal,
            slot: Slot.error));

    return b.add(Widget(kind: WidgetKind.column, children: stack_, width: SizeSpec.grow(),
        padding: Insets(0, 1, 0, 2),
        slot: st.focused ? Slot.selection : Slot.inherit, paintBackground: st.focused,
        decoration: Decoration(borderStyle: BorderStyle.solid, borderWidth: Insets(0, 0, 1, 0),
            borderSlot: Slot.border)));
}

/// The natural width of widget `id` in `b`, in cells: a text's run, a row's
/// children side by side, anything else its widest child — plus padding.
int naturalCells(ref Builder b, uint id) pure
{
    const w = b.nodes[id];
    int inner;
    switch (w.kind) with (WidgetKind)
    {
        case text:
            inner = cast(int) cellsOf(w.text);
            break;
        case rich:
            foreach (ref s; w.spans)
                inner += cast(int) cellsOf(s.text);
            break;
        case row:
            foreach (i, c; w.children)
                inner += naturalCells(b, c) + (i ? w.gap : 0);
            break;
        default:
            foreach (c; w.children)
            {
                const n = naturalCells(b, c);
                if (n > inner)
                    inner = n;
            }
            break;
    }
    return inner + w.padding.left + w.padding.right;
}

/**
A drill-in row's preview (`PRT38`): swatches for colours (up to five), else
the first values; then how many values the level holds.
*/
private uint drillPreview(ref Builder b, ref const TreeData!PropertyNode data, uint node)
{
    TextSpan[] spans;
    size_t leaves, swatches;
    string firsts;

    void visit(uint c)
    {
        for (uint k = data.nodes[c].firstChild; k != uint.max; k = data.nodes[k].nextSibling)
        {
            const v = &data.nodes[k].value;
            if (v.composite)
            {
                visit(k);
                continue;
            }
            leaves++;
            RgbColor col;
            if (v.color && swatchColor(unquoted(v.badge), col))
            {
                if (swatches++ < 5)
                    spans ~= TextSpan(text: "  ", bg: col, hasBg: true, paintBackground: true);
            }
            else if (!v.color && firsts.length < 16 && unquoted(v.badge).length)
                firsts ~= (firsts.length ? ", " : "") ~ unquoted(v.badge);
        }
    }

    visit(node);
    if (!swatches && firsts.length)
        spans ~= TextSpan(text: clipCells(firsts, 18), slot: Slot.muted);
    spans ~= TextSpan(text: text(spans.length ? " " : "", leaves), slot: Slot.muted);
    return b.add(Widget(kind: WidgetKind.rich, spans: spans));
}

/// `s` cut to at most `cells` cells.
private string clipCells(string s, size_t cells) pure
{
    size_t n, i;
    for (; i < s.length && n < cells; i++)
        if ((s[i] & 0xC0) != 0x80)
            n++;
    while (i < s.length && (s[i] & 0xC0) == 0x80)
        i++;
    return s[0 .. i];
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests.
// ─────────────────────────────────────────────────────────────────────────────

version (UiPropertyFixtures)
{
    import sparkles.metadata : colorValue, Description, Range, Section;

    private enum PsMode : ubyte
    {
        alpha,
        beta,
    }

    private enum PsMany : ubyte
    {
        one,
        two,
        three,
        four,
        five,
    }

    private struct PsColours
    {
        @colorValue string fg = "#cdd6f4";
        @colorValue string[] palette = ["#000000", "#ff0000", "#00ff00"];
    }

    private struct PsLook
    {
        @Description("Switch with the system.") bool follow = true;
        @Range(6, 72, 1) int size = 13;
        PsMode mode;
        PsMany many;
        string family = "monospace";
        PsColours colours;
    }

    private struct PsConfig
    {
        @Section("Appearance") PsLook look;
        PsLook other;
    }

    private struct PsFixture
    {
        import sparkles.ui.components.tree_view : TreeViewState;
        import sparkles.ui.property_tree : PropertyTree;

        PsConfig subject;
        PropertyTree!PsConfig tree;
        TreeViewState!string tv;

        void rebuild() @safe
        {
            tv.height = 40;
            tv.width = 80;
            tv.open = typeof(tv.open).allOpen;
            tree.rebuild(subject, tv);
        }
    }

    private uint nodeOf(in TreeData!PropertyNode d, string path) @safe
    {
        foreach (i, ref nd; d.nodes)
            if (nd.value.path == path)
                return cast(uint) i;
        assert(false, path);
    }
}

version (UiPropertyFixtures)
@("ui.property_sections.inlineEditorFor.byTypeAndUda")
@safe unittest
{
    PsFixture f;
    f.rebuild();
    auto ed(string p) => inlineEditorFor(f.tree.data.nodes[nodeOf(f.tree.data, p)].value);
    assert(ed("look.follow") == InlineEditor.toggle);
    assert(ed("look.size") == InlineEditor.stepper);
    assert(ed("look.mode") == InlineEditor.segmented);
    assert(ed("look.many") == InlineEditor.dropdown, "more than four members");
    assert(ed("look.family") == InlineEditor.text);
    assert(ed("look.colours.fg") == InlineEditor.swatch);
    assert(ed("look.colours") == InlineEditor.drillIn);
    assert(ed("look.colours.palette") == InlineEditor.drillIn);
    // A segmented control that does not fit becomes a dropdown.
    assert(inlineEditorFor(f.tree.data.nodes[nodeOf(f.tree.data, "look.mode")].value, 8)
        == InlineEditor.dropdown);
}

version (UiPropertyFixtures)
@("ui.property_sections.sectionItems.declarationOrderAndDrillIns")
@safe unittest
{
    PsFixture f;
    f.rebuild();
    const items = sectionItems(f.tree.data, null, false);
    string[] shown;
    foreach (ref it; items)
        shown ~= text(it.kind, ":", it.label);
    assert(shown[0 .. 7] == ["header:Appearance", "leaf:Follow", "leaf:Size", "leaf:Mode",
        "leaf:Many", "leaf:Family", "drill:Colours"], text(shown));
    assert(shown[7] == "header:other", "a top-level aggregate is a section by default");

    // A collapsed section folds to its header.
    const folded = sectionItems(f.tree.data, null, false, (string p) => p == "look");
    assert(folded[0].collapsed && folded[1].kind == SectionItem.Kind.header);
    assert(sectionSummary(f.tree.data, folded[0].node) == "5 settings · 1 group",
        sectionSummary(f.tree.data, folded[0].node));

    // A level: the drilled node's header and its own children.
    const level = sectionItems(f.tree.data, "look.colours", false);
    assert(level[0].kind == SectionItem.Kind.header && level[1].label == "Fg"
        && level[2].kind == SectionItem.Kind.drill);
}

version (UiPropertyFixtures)
@("ui.property_sections.sectionRow.controlsAreTouchTargets")
@safe unittest
{
    import std.algorithm.searching : canFind;

    import sparkles.ui.geometry : Constraints;
    import sparkles.ui.layout : layout;
    import sparkles.ui.state : hoverTargets;

    PsFixture f;
    f.subject.look.size = 16;
    f.rebuild();
    const node = nodeOf(f.tree.data, "look.size");
    Builder b;
    const item = SectionItem(SectionItem.Kind.leaf, node, "Size");
    const st = RowState(changed: true, chip: "overrides colors.properties", chipWarn: true);
    const root = sectionRow(b, f.tree.data, item, st,
        SectionsOptions(targetRows: 3, width: 60), 1000);
    auto tree = b.finish(root);
    auto frames = layout(tree, Constraints(maxW: 60));
    // The row is a 48 dp target (three rows here); its parts are hits.
    assert(frames[tree.root].rect.height >= 3);
    size_t[] ids;
    foreach (ref t; hoverTargets(tree, frames))
        ids ~= t.hitId;
    assert(ids.canFind(sectionHit(1000, node, SectionPart.dec))
        && ids.canFind(sectionHit(1000, node, SectionPart.inc))
        && ids.canFind(sectionHit(1000, node, SectionPart.reset)));

    // The changed marker is a glyph, and the chip carries the note.
    const(char)[] all;
    foreach (ref w; tree.nodes)
    {
        all ~= w.text;
        foreach (ref s; w.spans)
            all ~= s.text;
    }
    assert(all.canFind(" ●") && all.canFind("overrides colors.properties")
        && all.canFind("16"));
}

version (UiPropertyFixtures)
@("ui.property_sections.drillPreview.swatchesAndCount")
@safe unittest
{
    PsFixture f;
    f.rebuild();
    const node = nodeOf(f.tree.data, "look.colours");
    Builder b;
    const item = SectionItem(SectionItem.Kind.drill, node, "Colours");
    const st = RowState.init;
    const root = sectionRow(b, f.tree.data, item, st,
        SectionsOptions(width: 60), 1);
    auto tree = b.finish(root);
    size_t painted;
    string count;
    foreach (ref w; tree.nodes)
        foreach (ref s; w.spans)
        {
            if (s.hasBg && s.paintBackground)
                painted++;
            if (s.text == " 4")
                count = "4";
        }
    assert(painted == 4, "fg and the three palette entries");
    assert(count == "4", "four values in the level");
}
