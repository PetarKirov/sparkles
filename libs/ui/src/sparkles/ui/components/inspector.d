/**
The inspector component (`INS`, [docs/specs/ui/inspector.md]) — an interactive
tree of nodes over a $(B subject), with a details pane for the selected node
and a selection contract that lets the host highlight the selected node's
extent $(I in) the subject.

The shape is the one every structure inspector shares — Chromium's Elements
panel, Visual Studio's Live Visual Tree, neovim's `:InspectTree` — and the
component is deliberately generic over it:

$(LIST
    * an $(B adapter) supplies the node model (a
        $(REF TreeData, sparkles,ui,components,tree_widget) whose `T` carries
        the view's DbI capabilities — `label`, `slot`, `badge`, …) and, by
        presence, a `details(node)` capability for the details pane;
    * the $(B tree) is the shared interactive component
        ($(MREF sparkles,ui,components,tree_view)) — cursor, disclosure,
        viewport, the works;
    * the $(B selection contract) is one value: the host reads
        `state.tree.selectedNode` and asks its adapter what extent that node
        covers (a layout rect for a widget tree, a byte range for a syntax
        tree) — the component never learns what an extent is;
    * the $(B header) carries the title and a row of host-supplied toggle
        actions (hover-sync on/off, anonymous nodes, …) as data, hit-testable
        by the ids the host minted.
)

$(LREF inspectWidgets) is the first adapter: the toolkit looking at itself.
Any `sparkles:ui` application can mount an inspector over its own widget tree
and layout — the Live-Visual-Tree capability, natively.

$(LREF writeTreeText) is the plain-text target: the same flattened rows as
indented text with guide rails, for logging, golden tests, and terminals with
no interactivity at all.
*/
module sparkles.ui.components.inspector;

import std.conv : text;

import sparkles.ui.components.tree_view : TreeViewState, viewSlice;
import sparkles.ui.components.tree_widget : FlatTreeRow, flatten, Guide,
    TreeData, TreeGlyphs;
import sparkles.ui.geometry : SizeSpec;
import sparkles.ui.layout : Frame;
import sparkles.ui.style : Slot, TextStyle;
import sparkles.ui.widget : Builder, TextSpan, Visibility, Widget, WidgetKind,
    WidgetTree;

@safe:

/// One header toggle, supplied by the host as data: the label renders in
/// brackets, accented while active, and carries the host's hit id.
struct InspectorAction
{
    string label;   ///
    bool active;    ///
    uint hitId;     /// 0 = not interactive
}

/// One row of the details pane.
struct DetailRow
{
    string key;               ///
    string value;             ///
    Slot slot = Slot.code;    /// the value's slot (the key is muted)
}

/**
The inspector's view: header (title + actions) · the interactive tree ·
the selected node's details, as one fixed-width column.

`innerWidth` is the content width the panel actually has — fixed rather than
`grow`, because an inspector typically lives inside a scroll viewport, where
`grow` collapses to natural width. The tree window is `state.bodyRows` tall
(set `state.width`/`height`, `chromeRows` and `headerRows` from the pane the
host arranged).

The details pane exists when the adapter has one: pass the selected node's
`DetailRow`s (or an empty slice for none). Reading them $(I from) an adapter
is one line — `node == uint.max ? [] : adapter.details(node)` — and keeping
that line in the host is what keeps this view free of the adapter's type.
*/
uint inspectorView(Key, T)(ref Builder b, in TreeData!T data,
    in TreeViewState!Key state, scope bool delegate(uint) @safe isOpen,
    string title, in InspectorAction[] actions, in DetailRow[] details,
    int innerWidth, TreeGlyphs glyphs = TreeGlyphs.init, uint hitBase = 1)
{
    uint[] rows;

    // Header: the title, then the action toggles as bracketed segments.
    TextSpan[] hdr = [TextSpan(title, Slot.chromeAccent)];
    foreach (ref const a; actions)
    {
        hdr ~= TextSpan(" ", Slot.chrome);
        hdr ~= TextSpan(text("[", a.label, "]"),
            a.active ? Slot.chromeAccent : Slot.gutter);
    }
    rows ~= b.add(Widget(kind: WidgetKind.rich, spans: hdr,
        textStyle: TextStyle(bold: true)));
    rows ~= rule(b, innerWidth);

    // The tree body and both bars consume the SAME frame as pointer routing:
    // content first, H below its remainder, V at the right owning the corner.
    // The stable vertical gutter stays present when dormant; the semantic op
    // simply paints nothing while the rows fit.
    {
        import sparkles.ui.components.chrome : scrollbar, ScrollbarGlyphs;

        const frame = state.scrollFrame();
        const treeCol = b.add(Widget(kind: WidgetKind.column,
            children: [viewSlice(b, data, state, isOpen, glyphs,
                hitBase: hitBase)],
            width: SizeSpec.fixed(frame.content.width),
            height: SizeSpec.fixed(frame.content.height),
            clipX: true, clipY: true));

        uint body = treeCol;
        if (frame.hTrack.height > 0)
        {
            const hbar = scrollbar(b, state.hsb,
                frame.hExtents.content, frame.hExtents.viewport,
                frame.hExtents.track, ScrollbarGlyphs('━', '─'),
                expandPercent: cast(ubyte) state.scroll.hAnim.percent,
                gutter: frame.hTrack.height,
                trackLit: state.hsb.hovered || state.hsb.dragging);
            body = b.add(Widget(kind: WidgetKind.column,
                children: [treeCol, hbar],
                width: SizeSpec.fixed(frame.hTrack.width),
                height: SizeSpec.fixed(frame.vTrack.height)));
        }

        if (frame.vTrack.width > 0)
        {
            const vbar = scrollbar(b, state.sb.scrolledTo(state.top),
                frame.vExtents.content, frame.vExtents.viewport,
                frame.vExtents.track, ScrollbarGlyphs('█', '░'),
                expandPercent: cast(ubyte) state.scroll.vAnim.percent,
                gutter: frame.vTrack.width,
                trackLit: state.sb.hovered || state.sb.dragging);
            rows ~= b.add(Widget(kind: WidgetKind.row,
                children: [body, vbar],
                width: SizeSpec.fixed(innerWidth),
                height: SizeSpec.fixed(frame.vTrack.height)));
        }
        else
            rows ~= body;
    }

    // The details pane, when the adapter supplied rows for the selection.
    if (details.length)
    {
        rows ~= rule(b, innerWidth);
        foreach (ref const d; details)
            rows ~= b.add(Widget(kind: WidgetKind.rich, spans: [
                TextSpan(d.key, Slot.gutter),
                TextSpan(" ", Slot.gutter),
                TextSpan(d.value, d.slot),
            ]));
    }

    return b.add(Widget(
        kind: WidgetKind.column,
        children: rows,
        width: SizeSpec.fixed(innerWidth),
        clipX: true,
    ));
}

/**
The header's hit geometry (`INS3`): which action `x` lands on in the row
$(LREF inspectorView) paints, or `-1` for none.

The chips are laid out by the same rule in both directions — title, then
`" [label]"` per action — so a host hit-tests its own header without
retaining a frame or minting per-chip hit ids. `x` is pane-local, in cells,
on the header row (row 0 of the component's column).
*/
int actionAt(string title, in InspectorAction[] actions, int x)
{
    import sparkles.ui.geometry : cellsOf;

    int at = cast(int) cellsOf(title);
    foreach (i, ref const a; actions)
    {
        const lo = at + 1; // the separating space belongs to nobody
        const hi = lo + 2 + cast(int) cellsOf(a.label); // "[" label "]"
        if (x >= lo && x < hi)
            return cast(int) i;
        at = hi;
    }
    return -1;
}

/// A fixed-width rule (`grow` collapses inside a scroll viewport).
private uint rule(ref Builder b, int width)
    => b.add(Widget(
        kind: WidgetKind.box,
        slot: Slot.border,
        width: SizeSpec.fixed(width),
        height: SizeSpec.fixed(1),
        paintBackground: true,
        stretch: true,
    ));

// ---------------------------------------------------------------------------
// The widget-tree adapter: the toolkit looking at itself.
// ---------------------------------------------------------------------------

/// A widget-tree node as the inspector's tree sees it: the kind as the
/// label, the resolved size as a trailing badge, a text node's content
/// remembered for the details pane.
struct WidgetInspectNode
{
    string label;      /// widget kind (+ `#key` when the widget carries one)
    string badge;      /// `W×H` from the resolved frame
    Slot slot = Slot.code; ///
    uint widget = uint.max; /// the subject node this row describes
}

/// The widget-tree adapter's product: the tree data plus what the host
/// needs to honor the selection contract (`details`, `extentOf`).
struct WidgetInspect
{
    TreeData!WidgetInspectNode data; ///

    // The subject by value: the arena is a heap slice, so this borrows the
    // same nodes the caller laid out — no lifetime coupling to a local.
    private WidgetTree subject;
    private const(Frame)[] frames;

    /// The details rows for a tree node (`uint.max` → none).
    DetailRow[] details(uint node) scope const
    {
        if (node == uint.max || node >= data.nodes.length)
            return null;
        const w = data.nodes[node].value.widget;
        const r = frames[w].rect;
        DetailRow[] rows = [
            DetailRow("kind", text(subject.nodes[w].kind)),
            DetailRow("rect", text(r.width, "×", r.height, " at ",
                r.x, ",", r.y)),
        ];
        if (subject.nodes[w].text.length)
            rows ~= DetailRow("text", subject.nodes[w].text.idup, Slot.docs);
        if (subject.nodes[w].key)
            rows ~= DetailRow("key", text("#", subject.nodes[w].key),
                Slot.info);
        if (subject.nodes[w].hitId)
            rows ~= DetailRow("hit", text(subject.nodes[w].hitId));
        if (subject.nodes[w].slot != Slot.inherit)
            rows ~= DetailRow("slot", text(subject.nodes[w].slot));
        return rows;
    }

    /// The selection contract: the layout rect the selected tree node
    /// covers in the subject — what a host tints to say "this one".
    auto extentOf(uint node) scope const
        => node != uint.max && node < data.nodes.length
            ? frames[data.nodes[node].value.widget].rect
            : typeof(frames[0].rect).init;
}

/**
Builds the inspector's tree from a laid-out widget tree — one inspector node
per (visible) subject node, labelled `kind`, badged with its resolved size.
The mapping is index-parallel walk order, so the adapter can answer details
and extents for any selection without a search.
*/
WidgetInspect inspectWidgets(WidgetTree subject, const(Frame)[] frames)
{
    WidgetInspect wi;
    wi.subject = subject;
    wi.frames = frames;

    void walk(uint w, uint parent)
    {
        const n = &subject.nodes[w];
        if (n.visibility == Visibility.collapsed)
            return;
        auto label = text(n.kind);
        if (n.key)
            label ~= text(" #", n.key);
        const r = frames[w].rect;
        const idx = wi.data.add(WidgetInspectNode(
            label: label,
            badge: text(r.width, "×", r.height),
            slot: n.children.length ? Slot.code : Slot.docs,
            widget: w,
        ), parent);
        foreach (c; n.children)
            walk(c, idx);
    }

    walk(subject.root, uint.max);
    return wi;
}

// ---------------------------------------------------------------------------
// The plain-text target.
// ---------------------------------------------------------------------------

/**
The flattened tree as indented text with guide rails — the inspector's
ANSI/file/logging target. One line per row: guides, the label, and (when the
node carries one) the badge after two spaces. Ends with a newline.
*/
void writeTreeText(Writer, T)(ref Writer w, in TreeData!T data,
    in FlatTreeRow[] rows, in TreeGlyphs glyphs = TreeGlyphs.init)
{
    foreach (ref const r; rows)
    {
        foreach (d, g; r.guides)
        {
            final switch (g) with (Guide)
            {
                case space: w.put(glyphs.space); break;
                case continueBar: w.put(glyphs.continueBar); break;
                case fork: w.put(glyphs.fork); break;
                case end: w.put(glyphs.end); break;
            }
        }
        ref const v = data.nodes[r.node].value;
        static if (__traits(compiles, { const(char)[] s = v.label; }))
            w.put(v.label);
        else
            w.put(v);
        static if (__traits(compiles, { const(char)[] s2 = v.badge; }))
            if (v.badge.length)
            {
                w.put("  ");
                w.put(v.badge);
            }
        w.put("\n");
    }
}

/// ditto — as one `string`.
string treeText(T)(in TreeData!T data, in FlatTreeRow[] rows,
    in TreeGlyphs glyphs = TreeGlyphs.init)
{
    import std.array : appender;

    auto w = appender!string;
    writeTreeText(w, data, rows, glyphs);
    return w[];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest)
{
    import sparkles.ui.geometry : Constraints;
    import sparkles.ui.layout : layout;

    // A little subject: a column of a bold text and a keyed box.
    private WidgetTree subjectTree(ref Builder b) @safe
    {
        const t = b.add(Widget(kind: WidgetKind.text, text: "hello",
            textStyle: TextStyle(bold: true)));
        const bx = b.add(Widget(kind: WidgetKind.box, key: 99,
            width: SizeSpec.fixed(4), height: SizeSpec.fixed(2), hitId: 7));
        return b.finish(b.add(Widget(kind: WidgetKind.column,
            children: [t, bx])));
    }
}

@("ui.inspector.widgetAdapterMirrorsTheSubject")
@safe unittest
{
    auto sb = Builder();
    auto subject = subjectTree(sb);
    auto frames = layout(subject, Constraints(maxW: 40));

    auto wi = inspectWidgets(subject, frames);
    // One inspector node per subject node, in walk order: column, text, box.
    assert(wi.data.nodes.length == 3);
    assert(wi.data.nodes[0].value.label == "column");
    assert(wi.data.nodes[1].value.label == "text");
    assert(wi.data.nodes[2].value.label == "box #99");
    assert(wi.data.nodes[2].value.badge == "4×2");

    // Details answer from the SAME frames the subject was laid out with.
    const det = wi.details(1);
    assert(det[0].key == "kind" && det[0].value == "text");
    bool sawText;
    foreach (ref const d; det)
        sawText |= d.key == "text" && d.value == "hello";
    assert(sawText);

    // The selection contract: a tree node maps to its subject extent.
    assert(wi.extentOf(2).width == 4 && wi.extentOf(2).height == 2);
    assert(wi.extentOf(uint.max).width == 0, "no selection, no extent");
}

@("ui.inspector.viewRendersHeaderTreeAndDetails")
@safe unittest
{
    import sparkles.ui.state : DisclosureState;

    auto sb = Builder();
    auto subject = subjectTree(sb);
    auto frames = layout(subject, Constraints(maxW: 40));
    auto wi = inspectWidgets(subject, frames);

    TreeViewState!uint s;
    s.width = 28;
    s.height = 12;
    s.chromeRows = 0;
    s.open = DisclosureState!uint.allOpen;
    auto open = s.open;
    s.rows = flatten(wi.data, (uint n) => open.isOpen(n));
    s.sel = 2;

    auto b = Builder();
    const col = inspectorView(b, wi.data, s, (uint) @safe => true,
        "inspector", [InspectorAction("sync", true, 42)],
        wi.details(s.selectedNode), 28);
    auto wt = b.finish(col);

    bool sawTitle, sawAction, sawKind;
    foreach (ref n; wt.nodes)
        foreach (ref sp; n.spans)
        {
            sawTitle |= sp.text == "inspector";
            sawAction |= sp.text == "[sync]" && sp.slot == Slot.chromeAccent;
            sawKind |= sp.text == "box";
        }
    assert(sawTitle && sawAction && sawKind);
}

@("ui.inspector.headerChipsAreHitTestable")
@safe unittest
{
    // The same layout the view paints: "insp" then " [⌕]" then " [anon]".
    const actions = [InspectorAction("⌕", false), InspectorAction("anon", true)];
    assert(actionAt("insp", actions, 0) == -1, "the title is not a chip");
    assert(actionAt("insp", actions, 4) == -1, "nor the separating space");
    assert(actionAt("insp", actions, 5) == 0, "[");
    assert(actionAt("insp", actions, 6) == 0, "the glyph, one cell wide");
    assert(actionAt("insp", actions, 7) == 0, "]");
    assert(actionAt("insp", actions, 8) == -1);
    assert(actionAt("insp", actions, 9) == 1);
    assert(actionAt("insp", actions, 14) == 1);
    assert(actionAt("insp", actions, 15) == -1, "past the last chip");
}

@("ui.inspector.textTargetCarriesGuidesLabelsAndBadges")
@safe unittest
{
    import std.algorithm.searching : canFind;

    auto sb = Builder();
    auto subject = subjectTree(sb);
    auto frames = layout(subject, Constraints(maxW: 40));
    auto wi = inspectWidgets(subject, frames);
    auto rows = flatten(wi.data, (uint) => true);

    const dump = treeText(wi.data, rows);
    assert(dump.canFind("└─ box #99  4×2"), dump);
    assert(dump.canFind("├─ text"), dump);
    assert(dump[$ - 1] == '\n');
}

@("ui.inspector.overflowGrowsAVerticalBar")
@safe unittest
{
    import sparkles.ui.state : DisclosureState;

    auto sb2 = Builder();
    auto subject = subjectTree(sb2);
    auto frames = layout(subject, Constraints(maxW: 40));
    auto wi = inspectWidgets(subject, frames);

    TreeViewState!uint s;
    s.width = 28;
    s.height = 4; // two header rows + bodyRows = 2 < 3 rows: overflow
    s.chromeRows = 2;
    s.headerRows = 2;
    s.scrollGutterV = 2;
    s.open = DisclosureState!uint.allOpen;
    auto open = s.open;
    s.rows = flatten(wi.data, (uint n) => open.isOpen(n));
    assert(cast(long) s.rows.length > s.bodyRows);

    auto b = Builder();
    const col = inspectorView(b, wi.data, s, (uint) @safe => true,
        "inspector", null, null, 28);
    auto wt = b.finish(col);

    // The tree region is a row of [windowed tree, one semantic bar].
    bool sawBarRow, sawBar;
    foreach (ref n; wt.nodes)
    {
        sawBarRow |= n.kind == WidgetKind.row && n.children.length == 2;
        sawBar |= n.kind == WidgetKind.scrollbar
            && n.barContent == cast(long) s.rows.length
            && n.barViewport == s.bodyRows;
    }
    assert(sawBarRow && sawBar, "an overflowing tree grows one semantic scrollbar");

    import sparkles.base.term_color : RgbColor;
    import sparkles.ui.canvas : OpKind;
    import sparkles.ui.display_list : buildDisplayList;
    import sparkles.ui.style : defaultTwoslashPalette;

    const laid = layout(wt);
    const ops = buildDisplayList(wt, laid, defaultTwoslashPalette(),
        RgbColor(255, 255, 255), RgbColor(0, 0, 0));
    bool emitted;
    foreach (ref op; ops)
        if (op.kind == OpKind.scrollbar)
        {
            emitted = true;
            assert(op.rect == s.scrollFrame().vTrack,
                "paint consumes the tree state's one resolved track");
        }
    assert(emitted, "the inspector bar reaches the backend-specific painter");

    import sparkles.input : Point, PointerAction, PointerButton, PointerEvent;
    import sparkles.ui.state : CaptureState;

    CaptureState capture;
    const frame = s.scrollFrame();
    s.pointer(PointerEvent(action: PointerAction.press,
        button: PointerButton.left,
        pos: Point(frame.vTrack.x, frame.vTrack.bottom - 1)), capture, 40);
    assert(s.top == 1 && s.sb.dragging,
        "a press on the painted rect drives that same bar");
}
