/**
The property view (`PRT12`–`PRT13`, `PRT21`, `PRT26`, `PRT32`–`PRT33`): the
presentation half of $(MREF sparkles,ui,property_tree), composed with the
shared tree machinery. It borrows the per-rebuild `TreeData!PropertyNode`
snapshot and the host's `TreeViewState!string`/`PropertyEditState` values and
emits ordinary widgets — no edit can route around the generated dispatch from
here, because this module never mutates anything.

One semantic definition serves every target (`PRT26`): the widget view for
raylib/TUI/HTML and $(LREF writePropertyText) for the plain-text target render
the same rows, the same disclosure meaning (through `nodeExpandable`), the
same value affordances, and the same color-independent match/status markers.
*/
module sparkles.ui.components.property_view;

import std.conv : text;

import sparkles.ui.components.tree_view : TreeViewState;
import sparkles.ui.components.tree_widget : FlatTreeRow, Guide, nodeExpandable,
    TreeData, TreeGlyphs;
import sparkles.ui.geometry : cellsOf, SizeSpec;
import sparkles.ui.property_tree : ByteSpan, LeafKind, MatchedField,
    PropertyEditState, PropertyNode, Refusal, RefusalKind, SearchRole;
import sparkles.ui.style : Slot, TextStyle;
import sparkles.ui.widget : Builder, TextSpan, Widget, WidgetKind;

@safe:

/// Presentation knobs; all data, no behavior.
struct PropertyViewOptions
{
    /// The column where values start (labels/guides are padded up to it).
    int valueColumn = 28;
    /// Cells of range-slider track for `@Range` numeric leaves.
    int rangeBarCells = 8;
    /// Marker for string leaves until the shared editor ships (`PRT13`).
    string needsEditorMarker = "needs EDT";
    TreeGlyphs glyphs; ///
}

/// The color-independent semantic marker for a row's search role (`PRT33`).
string roleMarker(SearchRole role) pure nothrow @nogc
{
    final switch (role)
    {
        case SearchRole.none: return "";
        case SearchRole.direct: return "● ";
        case SearchRole.context: return "· ";
        case SearchRole.status: return "";
    }
}

/// Which fields matched, as accessibility text (`PRT33`).
string matchedFieldsText(MatchedField m) pure nothrow
{
    string s;
    void add(string name) pure nothrow
    {
        s = s.length ? s ~ "+" ~ name : name;
    }

    if (m & MatchedField.label) add("label");
    if (m & MatchedField.path) add("path");
    if (m & MatchedField.value) add("value");
    if (m & MatchedField.doc) add("doc");
    return s;
}

/// The value affordance for one row, as plain text — shared by the widget
/// view and the text target so no backend invents its own (`PRT26`).
string valueText(ref const PropertyNode n, in PropertyViewOptions opt) pure
{
    if (n.synthetic)
        return "";
    if (n.composite)
        return n.badge;
    final switch (n.kind)
    {
        case LeafKind.none:
            return n.badge;
        case LeafKind.boolean:
            return (n.badge == "true" ? "[x] " : "[ ] ") ~ n.badge;
        case LeafKind.enumeration:
            return n.editable ? "◂ " ~ n.badge ~ " ▸" : n.badge;
        case LeafKind.integral:
        case LeafKind.floating:
            return n.hasRange && n.editable
                ? n.badge ~ "  " ~ rangeBar(n, opt.rangeBarCells) : n.badge;
        case LeafKind.text:
            return n.badge ~ "  ⟨" ~ opt.needsEditorMarker ~ "⟩";
        case LeafKind.opaque:
            return n.badge;
    }
}

/// A tiny `▰▱` track for a ranged numeric value.
private string rangeBar(ref const PropertyNode n, int cells) pure
{
    import std.conv : to;

    if (cells <= 0 || !(n.hi > n.lo))
        return "";
    double v;
    // The badge is the rendered value; re-parse it rather than re-reading the
    // subject, so the bar can never disagree with the printed number.
    try
        v = n.badge.to!double;
    catch (Exception)
        return "";
    auto frac = (v - n.lo) / (n.hi - n.lo);
    if (frac < 0) frac = 0;
    if (frac > 1) frac = 1;
    const filled = cast(int) (frac * cells + 0.5);
    string bar;
    foreach (i; 0 .. cells)
        bar ~= i < filled ? "▰" : "▱";
    return bar;
}

/// Splits `body_` into plain/matched spans along the canonical witness byte
/// ranges (`PRT33`); matched spans take `Slot.matched` + bold.
private void emphasized(ref TextSpan[] spans, string body_,
    in ByteSpan[] marks, Slot baseSlot) pure nothrow
{
    size_t at;
    foreach (ref const m; marks)
    {
        if (m.start >= body_.length || m.start < at || m.end > body_.length
            || m.end <= m.start)
            continue;
        if (m.start > at)
            spans ~= TextSpan(body_[at .. m.start], baseSlot);
        auto hit = TextSpan(body_[m.start .. m.end], Slot.matched);
        hit.textStyle = TextStyle(bold: true);
        spans ~= hit;
        at = m.end;
    }
    if (at < body_.length)
        spans ~= TextSpan(body_[at .. $], baseSlot);
}

/**
The interactive rows for the `[top .. top + bodyRows)` window of the visible
rows, one widget row per tree row — plus, directly below an addressed row,
its current refusal (`PRT21`). Returns the column's widget index.
*/
uint propertyView(ref Builder b, in TreeData!PropertyNode data,
    in TreeViewState!string s, in PropertyEditState edits,
    PropertyViewOptions opt = PropertyViewOptions.init, uint hitBase = 1)
{
    const first = cast(size_t)(s.top < 0 ? 0 : s.top);
    const last = first + s.bodyRows > s.rows.length ? s.rows.length
        : first + s.bodyRows;
    uint[] rowIds;

    foreach (ref const row; s.rows[first < last ? first : last .. last])
    {
        ref const n = data.nodes[row.node].value;
        TextSpan[] spans;
        int used;

        foreach (g; row.guides)
        {
            final switch (g) with (Guide)
            {
                case space: spans ~= TextSpan(opt.glyphs.space, Slot.gutter); break;
                case continueBar:
                    spans ~= TextSpan(opt.glyphs.continueBar, Slot.gutter); break;
                case fork: spans ~= TextSpan(opt.glyphs.fork, Slot.gutter); break;
                case end: spans ~= TextSpan(opt.glyphs.end, Slot.gutter); break;
            }
            used += 3;
        }
        const marker = nodeExpandable(data, row.node)
            ? (s.open.isOpen(n.path) || (s.searching && s.searchFold.isOpen(n.path))
                ? opt.glyphs.open : opt.glyphs.closed)
            : opt.glyphs.leaf;
        spans ~= TextSpan(marker, Slot.gutter);
        used += cast(int) cellsOf(marker);

        const rm = roleMarker(n.role);
        if (rm.length)
        {
            auto ms = TextSpan(rm,
                n.role == SearchRole.direct ? Slot.matched : Slot.muted);
            spans ~= ms;
            used += cast(int) cellsOf(rm);
        }

        // The label, with witness emphasis on a search projection.
        const labelSlot = n.synthetic ? Slot.muted
            : n.role == SearchRole.context ? Slot.muted
            : n.composite ? Slot.chromeAccent : Slot.inherit;
        if (n.labelSpans.length)
            emphasized(spans, n.label, n.labelSpans, labelSlot);
        else
        {
            auto ls = TextSpan(n.label, labelSlot);
            if (n.synthetic)
                ls.textStyle = TextStyle(italic: true);
            spans ~= ls;
        }
        used += cast(int) cellsOf(n.label);

        // Read-only / pending affordances precede the value column.
        if (!n.synthetic && !n.composite && !n.editable)
        {
            spans ~= TextSpan(" ⊘", Slot.muted);
            used += 2;
        }
        if (edits.pendingActive && edits.pendingPath == n.path)
        {
            spans ~= TextSpan(" ✎", Slot.chromeAccent);
            used += 2;
        }

        const vt = valueText(n, opt);
        if (vt.length)
        {
            auto pad = opt.valueColumn - used;
            if (pad < 1)
                pad = 1;
            string padding;
            foreach (i; 0 .. pad)
                padding ~= ' ';
            spans ~= TextSpan(padding, Slot.inherit);
            const valueSlot = n.synthetic || n.role == SearchRole.context
                ? Slot.muted : Slot.code;
            if (n.badgeSpans.length && !n.composite
                && n.kind != LeafKind.boolean && n.kind != LeafKind.enumeration)
                emphasized(spans, vt, n.badgeSpans, valueSlot);
            else
                spans ~= TextSpan(vt, valueSlot);
        }

        // A path/doc-only hit explains itself with one bounded snippet.
        if (n.snippet.length)
        {
            spans ~= TextSpan("  ⟨", Slot.muted);
            spans ~= TextSpan(n.snippet, Slot.muted);
            spans ~= TextSpan("⟩", Slot.muted);
        }

        const selected = row.node == s.selectedNode;
        rowIds ~= b.add(Widget(kind: WidgetKind.rich, spans: spans,
            hitId: n.synthetic ? 0 : hitBase + row.node,
            paintBackground: selected, stretch: selected,
            slot: selected ? Slot.selection : Slot.inherit));

        // The refusal, inline at the addressed row (`PRT21`).
        const r = edits.refusalFor(n.path);
        if (!n.synthetic && n.path.length && r.refused)
        {
            TextSpan[] rs;
            string indent;
            foreach (i; 0 .. used)
                indent ~= ' ';
            rs ~= TextSpan(indent, Slot.inherit);
            rs ~= TextSpan("⚠ " ~ refusalText(r), Slot.error);
            rowIds ~= b.add(Widget(kind: WidgetKind.rich, spans: rs));
        }
    }

    const rowsCol = b.add(Widget(kind: WidgetKind.column, children: rowIds));

    // The scroll frame (`SCV10`): the rows clip to the frame's content box and
    // the machine-driven bar sits in the gutter the state reserved — the one
    // composition every scrolling pane emits, so a property tree and a file
    // tree cannot look different while scrolling. Rows are already sliced to
    // the window, so the box takes no child offset.
    import sparkles.ui.components.chrome : hBar, scrollBox, vBar;

    return scrollBox(b, rowsCol, s.scrollFrame(),
        vBar(s.scroll, s.top), hBar(s.scroll, s.hsb.offset));
}

/// The refusal's presented text — one vocabulary for every target.
string refusalText(in Refusal r) pure
{
    string what;
    final switch (r.kind)
    {
        case RefusalKind.none: return "";
        case RefusalKind.malformedPath: what = "malformed path"; break;
        case RefusalKind.noSuchPath: what = "no such path"; break;
        case RefusalKind.nullTraversal: what = "null along the path"; break;
        case RefusalKind.readOnlyField: what = "read-only"; break;
        case RefusalKind.readOnlyPolicy: what = "read-only (policy)"; break;
        case RefusalKind.typeMismatch: what = "type mismatch"; break;
        case RefusalKind.outOfRange: what = "out of range"; break;
        case RefusalKind.staleHistory: what = "stale history"; break;
        case RefusalKind.staleInteraction: what = "stale interaction"; break;
        case RefusalKind.editInProgress: what = "another edit is in progress"; break;
        case RefusalKind.duplicateKey: what = "duplicate element key"; break;
        case RefusalKind.emptyHistory: what = "nothing to replay"; break;
    }
    return r.detail.length ? what ~ ": " ~ r.detail : what;
}

/**
The plain-text target (`PRT12`, `PRT26`, `INS5`): the same rows, disclosure
markers (open/closed/leaf through `nodeExpandable`), values, and semantic
match/status markers, as indented text. Refusals render inline below their
row, exactly like the widget view.
*/
void writePropertyText(Writer)(ref Writer w, in TreeData!PropertyNode data,
    in FlatTreeRow[] rows, in TreeViewState!string s,
    in PropertyEditState edits,
    in PropertyViewOptions opt = PropertyViewOptions.init)
{
    foreach (ref const row; rows)
    {
        ref const n = data.nodes[row.node].value;
        int used;
        foreach (g; row.guides)
        {
            final switch (g) with (Guide)
            {
                case space: w.put(opt.glyphs.space); break;
                case continueBar: w.put(opt.glyphs.continueBar); break;
                case fork: w.put(opt.glyphs.fork); break;
                case end: w.put(opt.glyphs.end); break;
            }
            used += 3;
        }
        const marker = nodeExpandable(data, row.node)
            ? (s.open.isOpen(n.path) || (s.searching && s.searchFold.isOpen(n.path))
                ? opt.glyphs.open : opt.glyphs.closed)
            : opt.glyphs.leaf;
        w.put(marker);
        used += cast(int) cellsOf(marker);
        const rm = roleMarker(n.role);
        w.put(rm);
        used += cast(int) cellsOf(rm);
        w.put(n.label);
        used += cast(int) cellsOf(n.label);
        if (!n.synthetic && !n.composite && !n.editable)
        {
            w.put(" ⊘");
            used += 2;
        }
        const vt = valueText(n, opt);
        if (vt.length)
        {
            auto pad = opt.valueColumn - used;
            if (pad < 1)
                pad = 1;
            foreach (i; 0 .. pad)
                w.put(" ");
            w.put(vt);
        }
        if (n.role == SearchRole.direct && n.matched != MatchedField.none)
        {
            w.put("  (matched: ");
            w.put(matchedFieldsText(n.matched));
            w.put(")");
        }
        if (n.snippet.length)
        {
            w.put("  ⟨");
            w.put(n.snippet);
            w.put("⟩");
        }
        w.put("\n");
        const r = edits.refusalFor(n.path);
        if (!n.synthetic && n.path.length && r.refused)
        {
            foreach (i; 0 .. used)
                w.put(" ");
            w.put("⚠ ");
            w.put(refusalText(r));
            w.put("\n");
        }
    }
}

/// ditto — as one `string`.
string propertyText(in TreeData!PropertyNode data, in FlatTreeRow[] rows,
    in TreeViewState!string s, in PropertyEditState edits,
    in PropertyViewOptions opt = PropertyViewOptions.init)
{
    import std.array : appender;

    auto w = appender!string;
    writePropertyText(w, data, rows, s, edits, opt);
    return w[];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (UiPropertyFixtures)
{
    import sparkles.ui.property_tree : Doc, Edit, editProperty, EditValue,
        Label, PropertyTree, Range, readOnly;

    private enum Cap : ubyte { butt, round }

    private struct Stroke
    {
        @Range(0, 4, 0.5) double width = 1;
        Cap cap;
    }

    private struct Shape
    {
        @Label("name") @Doc("shown in the shape list") string name = "rect";
        bool visible = true;
        Stroke stroke;
        @readOnly ulong id = 7;
    }

    private struct Fixture
    {
        Shape subject;
        PropertyTree!Shape pt;
        TreeViewState!string tv;
        PropertyEditState es;

        void build(string query = null) @safe
        {
            import sparkles.input : Key, KeyEvent;

            tv.width = 72;
            tv.height = 30;
            tv.open = tv.open.opened("stroke");
            if (query.length)
            {
                tv.filterStart();
                foreach (dchar c; query)
                    tv.filterKey(KeyEvent(Key.char_, c));
            }
            pt.rebuild(subject, tv);
        }
    }
}

version (UiPropertyFixtures)
@("ui.property_view.valueAffordancesFollowTheLeafKind")
@safe unittest
{
    Fixture f;
    f.build();

    string rowText(string path) @safe
    {
        foreach (ref const nd; f.pt.data.nodes)
            if (nd.value.path == path)
                return valueText(nd.value, PropertyViewOptions.init);
        return null;
    }

    assert(rowText("visible") == "[x] true", "bool renders a checkbox");
    assert(rowText("stroke.cap") == "◂ butt ▸", "enum renders a picker");
    const w = rowText("stroke.width");
    assert(w.length > 1 && w[0] == '1', "numeric shows the value");
    import std.algorithm.searching : canFind;
    assert(w.canFind("▰") || w.canFind("▱"), "@Range adds the slider track");
    assert(rowText("name").canFind("needs EDT"),
        "strings carry the editor gate marker (PRT13)");
    assert(rowText("id") == "7", "a read-only leaf is a plain readout");
}

version (UiPropertyFixtures)
@("ui.property_view.refusalRendersInlineBelowItsRow")
@safe unittest
{
    Fixture f;
    f.build();
    // A refused edit lands its message under the addressed row (PRT21).
    assert(!editProperty(f.subject, Edit("stroke.width", EditValue.of(9.0)),
        f.es).ok);

    auto b = Builder();
    const col = propertyView(b, f.pt.data, f.tv, f.es);
    auto wt = b.finish(col);

    // Walk the whole tree: the view root is the scroll-framed row
    // (content column + the vertical bar) whenever the state reserves the
    // default gutter.
    bool sawRefusal;
    foreach (ref const node; wt.nodes)
        foreach (ref const sp; node.spans)
            sawRefusal |= sp.slot == Slot.error
                && sp.text.length > 2 && sp.text[0 .. 3] == "⚠";
    assert(sawRefusal);

    // The plain-text target shows the same refusal (PRT26).
    import std.algorithm.searching : canFind;

    const txt = propertyText(f.pt.data, f.tv.rows, f.tv, f.es);
    assert(txt.canFind("⚠ out of range"));

    // Success clears it everywhere.
    assert(editProperty(f.subject, Edit("stroke.width", EditValue.of(2.0)),
        f.es).ok);
    f.pt.rebuild(f.subject, f.tv);
    assert(!propertyText(f.pt.data, f.tv.rows, f.tv, f.es)
        .canFind("out of range"));
}

version (UiPropertyFixtures)
@("ui.property_view.searchDecorationIsColorIndependent")
@safe unittest
{
    import std.algorithm.searching : canFind;

    Fixture f;
    f.build("width");

    // The widget view emphasizes the canonical witness…
    auto b = Builder();
    const col = propertyView(b, f.pt.data, f.tv, f.es);
    auto wt = b.finish(col);
    bool sawMatchSpan, sawMarker;
    foreach (ref const node; wt.nodes)
        foreach (ref const sp; node.spans)
        {
            sawMatchSpan |= sp.slot == Slot.matched && sp.textStyle.bold
                && sp.text == "width";
            sawMarker |= sp.text == "● ";
        }
    assert(sawMatchSpan && sawMarker);

    // …and the text target says WHICH field matched, without color (PRT33).
    const txt = propertyText(f.pt.data, f.tv.rows, f.tv, f.es);
    assert(txt.canFind("● "), "direct-match marker");
    assert(txt.canFind("(matched: label)"), "accessibility text");
    assert(txt.canFind("▾ "),
        "the text target carries the same disclosure meaning (PRT12)");
}

version (UiPropertyFixtures)
@("ui.property_view.scrollFrameEmitsTheAnimatedBar")
@safe unittest
{
    // A sized state with the default vertical gutter frames the rows and
    // emits the semantic scrollbar leaf — the same machine-driven bar (and
    // hover-expand easing) every tree view paints, driven by the SAME
    // ScrollView the pointer routing eases (SCV1).
    Fixture f;
    f.build();
    f.tv.height = 6; // a window far shorter than the rows: the bar is live
    f.pt.rebuild(f.subject, f.tv);
    f.tv.scrollBy(2);
    f.tv.scroll.vAnim.percent = 40; // mid-easing, as a hover would leave it

    auto b = Builder();
    const root = propertyView(b, f.pt.data, f.tv, f.es);
    auto wt = b.finish(root);

    assert(wt.nodes[root].kind == WidgetKind.row, "content + bar, framed");
    bool sawBar;
    foreach (ref const node; wt.nodes)
        if (node.kind == WidgetKind.scrollbar)
        {
            sawBar = true;
            assert(node.barContent == cast(long) f.tv.rows.length);
            assert(node.barViewport == f.tv.bodyRows);
            assert(node.barOffset == f.tv.top, "the bar tracks the window");
            assert(node.barExpandPercent == 40, "the easing reaches the leaf");
        }
    assert(sawBar);

    // No reserved gutter — an embedded listing — keeps the bare column.
    f.tv.scrollGutterV = 0;
    f.pt.rebuild(f.subject, f.tv);
    auto b2 = Builder();
    const bare = propertyView(b2, f.pt.data, f.tv, f.es);
    auto wt2 = b2.finish(bare);
    assert(wt2.nodes[bare].kind == WidgetKind.column);
    foreach (ref const node; wt2.nodes)
        assert(node.kind != WidgetKind.scrollbar);
}
