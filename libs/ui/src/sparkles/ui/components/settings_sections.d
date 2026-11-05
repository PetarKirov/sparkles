/**
Section-oriented settings interaction shared by applications. The pane owns
validation, preview transactions and history; this value owns section
navigation, inline editor routing and captured numeric drags. Applications
may insert their own rows without copying property editing behavior.
*/
module sparkles.ui.components.settings_sections;

import std.conv : to;

import sparkles.input.events : Key, KeyEvent, PointerAction, PointerButton, PointerEvent;
import sparkles.ui.components.editor : EditorViewOptions, editorLineSpans;
import sparkles.ui.components.property_sections : decodeSectionHit, inlineEditorFor,
    InlineEditor, RowState, sectionHeader, sectionHit, SectionItem, sectionItems,
    SectionPart, sectionRow, SectionsOptions, sectionSummary;
import sparkles.ui.components.property_view : refusalText;
import sparkles.ui.components.range_slider : RangeSlider, SliderDomain;
import sparkles.ui.components.settings_pane : SettingsResult;
import sparkles.ui.geometry : Rect, Size;
import sparkles.ui.state : hoverTargets, hitAt;
import sparkles.ui.layout : Frame;
import sparkles.ui.property_tree : EditValue, LeafKind, PropertyNode, readValueAt;
import sparkles.ui.style : Slot;
import sparkles.ui.widget : Builder, Widget, WidgetKind, WidgetTree;

/// State beside a settings pane, independent of placement and persistence.
struct SettingsSections
{
    string[] levels; /// drill-in paths
    bool[string] folded; /// collapsed section paths
    string openDropdown; /// the currently expanded choice editor
    size_t focus; /// application-visible row focus
    bool wantsKeyboard; /// a numeric or text editor was opened
    RangeSlider drag; /// press-time geometry and numeric domain
    string dragPath; /// stable path for the captured interaction
    LeafKind dragKind; /// numeric representation accepted by dispatch
    private bool dragFloat;
    private bool pendingTouch;
    private PointerEvent pressed;
    private Rect pendingTrack;
    private SliderDomain pendingDomain;
    private double pendingBefore;
    private struct CachedLeaf
    {
        bool valid;
        PropertyNode node;
        SectionItem item;
        RowState state;
        SectionsOptions options;
        size_t base;
        WidgetTree tree;
    }
    private CachedLeaf[] cachedLeaves;

    // Graft owned row nodes, rebasing children without mutating the retained
    // subtree. Payload text stays borrowed from the retained row's snapshot.
    private static uint appendRow(ref Builder b, WidgetTree row) @safe
    {
        const offset = cast(uint)b.nodes.length;
        foreach (w; row.nodes)
        {
            w.children = w.children.dup;
            foreach (ref child; w.children) child += offset;
            w.spans = w.spans.dup;
            b.add(w);
        }
        return row.root + offset;
    }

    /// Visible section rows at the current level.
    auto items(P)(ref P pane, bool flatten = false)
    {
        auto closed = folded;
        return sectionItems(pane.tree.data, levels.length ? levels[$ - 1] : null,
            pane.tree.searching, (string p) => (p in closed) !is null, flatten);
    }

    /// Toggles a section without changing its values.
    void toggleFold(string path) @safe
    {
        if (path in folded)
            folded.remove(path);
        else
            folded[path] = true;
    }

    /// Returns to the enclosing level.
    bool back() @safe
    {
        if (!levels.length)
            return false;
        levels = levels[0 .. $ - 1];
        focus = 0;
        openDropdown = null;
        return true;
    }

    /// Shared changed/default, provenance, editor and refusal presentation.
    RowState rowState(P)(ref P pane, string path, bool focused)
    {
        RowState st;
        st.focused = focused;
        st.changed = !pane.atDefault(path);
        const pv = pane.provenance(path);
        if (pv.note.length)
        {
            st.chip = pv.shadowed ? pv.layer : pv.note;
            st.chipWarn = true;
        }
        else if (pv.layer.length && pv.layer != "default" && pv.layer != pane.fileLayer)
            st.chip = pv.layer;
        st.open = openDropdown == path;
        st.editing = pane.textEditing && pane.textPath == path;
        if (st.editing)
        {
            EditorViewOptions view;
            view.textSlot = Slot.code;
            st.editSpans = editorLineSpans(pane.textField.state, 0, view);
        }
        const rf = pane.edits.refusalFor(path);
        if (rf.refused)
            st.refusal = refusalText(rf);
        return st;
    }

    /// Builds a section row using the same controller state on every host.
    uint row(P)(ref Builder b, ref P pane, in SectionItem item,
        bool focused, in SectionsOptions opt, size_t base)
    {
        auto n = &pane.tree.data.nodes[item.node].value;
        if (item.kind == SectionItem.Kind.header)
            return sectionHeader(b, n.heading,
                item.collapsed ? sectionSummary(pane.tree.data, item.node) : n.path,
                item.collapsed, sectionHit(base, item.node, SectionPart.row), opt);
        auto st = rowState(pane, n.path, focused);
        if (item.kind == SectionItem.Kind.leaf && !n.composite && !n.synthetic)
        {
            // Scalar rows depend on their projected node and interaction
            // state. Aggregates remain uncached because they may inspect
            // child rows (for example a palette's swatches or a summary).
            if (!cachedLeaves.length) cachedLeaves = new CachedLeaf[128];
            auto cached = &cachedLeaves[item.node % cachedLeaves.length];
            if (!cached.valid || cached.node != *n || cached.item != item
                || cached.state != st || cached.options != opt || cached.base != base)
            {
                Builder row;
                cached.tree = row.finish(sectionRow(row, pane.tree.data, item, st, opt, base));
                cached.node = *n;
                cached.node.choices = n.choices.dup;
                cached.node.choiceLabels = n.choiceLabels.dup;
                cached.node.labelSpans = n.labelSpans.dup;
                cached.node.badgeSpans = n.badgeSpans.dup;
                cached.item = item;
                cached.state = st;
                cached.options = opt;
                cached.base = base;
                cached.valid = true;
            }
            return appendRow(b, cached.tree);
        }
        return sectionRow(b, pane.tree.data, item, st, opt, base);
    }

    /// Activates a generated control; custom rows remain the application's.
    SettingsResult activate(P)(ref P pane, uint node, uint part,
        in SectionsOptions opt, bool header = false, bool tap = true)
    {
        if (node >= pane.tree.data.nodes.length)
            return SettingsResult.init;
        const n = pane.tree.data.nodes[node].value;
        switch (part)
        {
            case SectionPart.reset: return pane.resetAt(n.path);
            case SectionPart.dec: return pane.stepAt(n.path, -1);
            case SectionPart.inc:
            case SectionPart.toggle: return pane.stepAt(n.path, 1);
            case SectionPart.accept: return pane.handleKey(KeyEvent(Key.enter));
            case SectionPart.cancelEdit: return pane.handleKey(KeyEvent(Key.escape));
            case SectionPart.row:
            case SectionPart.open:
                if (n.synthetic)
                    break;
                if (header)
                    toggleFold(n.path);
                else if (n.composite)
                {
                    levels ~= n.path;
                    focus = 0;
                    openDropdown = null;
                }
                else switch (inlineEditorFor(n, opt.segmentCells))
                {
                    case InlineEditor.slider:
                        if (part == SectionPart.open)
                        {
                            wantsKeyboard = true;
                            return pane.editTextAt(n.path);
                        }
                        break;
                    case InlineEditor.toggle: return pane.stepAt(n.path, 1);
                    case InlineEditor.segmented:
                        if (!tap) return pane.stepAt(n.path, 1);
                        break;
                    case InlineEditor.dropdown:
                        if (!tap) return pane.stepAt(n.path, 1);
                        openDropdown = openDropdown == n.path ? null : n.path;
                        break;
                    case InlineEditor.text:
                    case InlineEditor.number:
                    case InlineEditor.swatch:
                        wantsKeyboard = true;
                        return pane.editTextAt(n.path);
                    default: break;
                }
                break;
            default:
                if (part >= SectionPart.choice0 && part < SectionPart.slider
                    && part - SectionPart.choice0 < n.choices.length)
                {
                    openDropdown = null;
                    return pane.setAt(n.path, EditValue.ofEnum(n.choices[part - SectionPart.choice0]));
                }
                break;
        }
        return SettingsResult.init;
    }

    /// Cancels capture and rolls back its preview before closing or switching.
    SettingsResult cancel(P)(ref P pane)
    {
        pendingTouch = false;
        if (!drag.active)
            return SettingsResult.init;
        drag.cancel();
        return pane.cancelInteraction();
    }

    /// Whether a slider interaction holds pointer capture.
    bool capturing() const @safe pure nothrow @nogc => drag.active || pendingTouch;

    /// Frames use layout cells; cellPixels converts pixel pointers to those
    /// cells (defaults to identity). Hits include fractional viewport shifts
    /// and clipping. Capture owns subsequent moves/releases outside the track.
    bool pointer(P)(ref P pane, in PointerEvent p, in WidgetTree tree,
        scope const(Frame)[] frames, size_t base, out SettingsResult result, bool touch = false,
        Size cellPixels = Size(1, 1))
    {
        result = SettingsResult.init;
        const cw = cellPixels.width > 0 ? cellPixels.width : 1;
        const ch = cellPixels.height > 0 ? cellPixels.height : 1;
        const slop = (cw > ch ? cw : ch) / 4 + 1;
        if (pendingTouch)
        {
            if (p.pointerId != pressed.pointerId)
                return false;
            const dx = p.pos.x - pressed.pos.x;
            const dy = p.pos.y - pressed.pos.y;
            const ax = dx < 0 ? -dx : dx, ay = dy < 0 ? -dy : dy;
            if (p.action == PointerAction.release || p.action == PointerAction.leave)
            {
                pendingTouch = false;
                return false;
            }
            if (ay > ax && ay >= slop)
            {
                pendingTouch = false;
                return false;
            }
            if (ax < slop || ax <= ay)
                return false;
            pendingTouch = false;
            drag.begin(pendingTrack, pendingDomain, pendingBefore, p.pos.x);
            result = pane.previewAt(dragPath, numeric(drag.value));
            return true;
        }
        if (drag.active)
        {
            if (p.pointerId != pressed.pointerId)
                return true;
            if (p.action == PointerAction.drag || p.action == PointerAction.move)
                result = pane.previewAt(dragPath, numeric(drag.move(p.pos.x)));
            else if (p.action == PointerAction.release)
            {
                drag.move(p.pos.x);
                result = pane.setAt(dragPath, numeric(drag.finish()));
            }
            return true;
        }
        if (p.action != PointerAction.press || p.button != PointerButton.left)
            return false;
        const targets = hoverTargets(tree, frames);
        const hit = targets.hitAt(p.pos.x / cast(float) cw, p.pos.y / cast(float) ch);
        foreach_reverse (i, ref const widget; tree.nodes)
        {
            if (i >= frames.length || !hit || widget.hitId != hit)
                continue;
            uint node, part;
            if (!decodeSectionHit(base, widget.hitId, node, part)
                || part != SectionPart.slider || node >= pane.tree.data.nodes.length)
                continue;
            const n = pane.tree.data.nodes[node].value;
            EditValue before;
            if (!n.hasRange || !readValueAt(*pane.subject, n.path, before))
                return false;
            dragPath = n.path;
            dragKind = n.kind;
            dragFloat = n.typeName == "float";
            pressed = p;
            Rect track = frames[i].rect;
            float dx = 0, dy = 0;
            foreach (ref target; targets)
                if (target.hitId == hit) { dx = target.dx; dy = target.dy; }
            track = Rect(cast(int)((track.x + dx) * cw), cast(int)((track.y + dy) * ch),
                track.width * cw, track.height * ch);
            if (touch)
            {
                pendingTouch = true;
                pendingTrack = track;
                pendingDomain = SliderDomain(n.lo, n.hi, n.step, n.splitLo, n.splitFrac, n.splitW);
                pendingBefore = before.kind == EditValue.Kind.integral ? before.i : before.f;
                return false;
            }
            drag.begin(track, SliderDomain(n.lo, n.hi, n.step, n.splitLo, n.splitFrac, n.splitW),
                before.kind == EditValue.Kind.integral ? before.i : before.f, p.pos.x);
            result = pane.previewAt(dragPath, numeric(drag.value));
            return true;
        }
        return false;
    }

    private EditValue numeric(double value) const @safe pure nothrow @nogc
        => dragKind == LeafKind.integral ? EditValue.of(cast(long) value)
            : EditValue.of(dragFloat ? cast(double) cast(float) value : value);
}

/// Pixel pointers use the painted position of a fractionally scrolled track,
/// and cannot start capture in the clipped part of the same track.
@("ui.settings_sections.pixelPointerUnderFractionalScroll")
@system unittest
{
    import sparkles.ui.components.settings_pane : SettingsPane;
    import sparkles.ui.property_tree : NumericInput, PreferredInput, Range;
    import sparkles.ui.geometry : Constraints, Point, SizeSpec;
    import sparkles.ui.layout : layout;

    struct Subject
    {
        @Range(0, 1) @PreferredInput(NumericInput.slider) double value = 0.5;
    }
    Subject subject;
    SettingsPane!Subject pane;
    pane.open(&subject, subject);
    SettingsSections sections;
    Builder b;
    const row = sections.row(b, pane, sections.items(pane)[0], false,
        SectionsOptions(width: 40, targetRows: 3), 1000);
    const root = b.add(Widget(kind: WidgetKind.column, children: [row], clipY: true,
        height: SizeSpec.fixed(6), childOffsetFracY: 0.5));
    const tree = b.finish(root);
    const frames = layout(tree, Constraints(maxW: 40));
    Rect track;
    foreach (i, widget; tree.nodes)
        if (widget.hitId == sectionHit(1000, 0, SectionPart.slider)) track = frames[i].rect;
    assert(track.height == 3);
    SettingsResult result;
    const at = Point((track.x + 1) * 10, track.y * 20 - 5);
    assert(sections.pointer(pane, PointerEvent(PointerAction.press, PointerButton.left, at),
        tree, frames, 1000, result, false, Size(10, 20)),
        "the top half row is painted above its integer frame");
    const first = subject.value;
    cast(void) sections.pointer(pane, PointerEvent(PointerAction.drag, PointerButton.left,
        Point(at.x + 1, at.y)), tree, frames, 1000, result, false, Size(10, 20));
    assert(subject.value > first, "single-pixel motion changes a continuous value");
    cast(void) sections.cancel(pane);
    assert(!sections.pointer(pane, PointerEvent(PointerAction.press, PointerButton.left,
        Point(at.x, 6 * 20)), tree, frames, 1000, result, false, Size(10, 20)),
        "the viewport's lower edge cannot capture");
}

/// Retained scalar rows match a fresh projection after dynamic metadata,
/// values, focus and viewport changes, including rebased child indices.
@("ui.settings_sections.retainedRowsMatchFreshProjection")
@system unittest
{
    import sparkles.base.term_color : RgbColor;
    import sparkles.ui.canvas : BoxChrome, FillRect;
    import sparkles.ui.components.settings_pane : SettingsPane;
    import sparkles.ui.display_list : buildDisplayList;
    import sparkles.ui.geometry : Constraints;
    import sparkles.ui.layout : layout;
    import sparkles.ui.property_tree : hidden, NumericInput, PreferredInput, Range;
    import sparkles.ui.style : Palette;
    import std.typecons : tuple;
    import std.sumtype : match;

    static struct Subject
    {
        @hidden double minimum = 100, maximum = 900;
        @hidden bool locked;
        @PreferredInput(NumericInput.slider) double weight = 400;
        Range propRange(string field) const @safe pure nothrow @nogc
            => Range(minimum, maximum, 1);
        bool propReadOnly(string field) const @safe pure nothrow @nogc => locked;
    }
    Subject subject;
    SettingsPane!Subject pane;
    pane.open(&subject, subject);
    SettingsSections sections;
    SectionsOptions options;
    bool focused;
    auto project(bool cached) {
        Builder b;
        b.add(Widget(kind: WidgetKind.text, text: "preceding node"));
        const item = sections.items(pane)[0];
        const state = sections.rowState(pane, "weight", focused);
        const root = cached ? sections.row(b, pane, item, focused, options, 1000)
            : sectionRow(b, pane.tree.data, item, state, options, 1000);
        const tree = b.finish(root);
        auto ops = buildDisplayList(tree, layout(tree, Constraints(maxW: options.width)),
            Palette.init, RgbColor.init, RgbColor.init);
        BoxChrome[] chrome;
        foreach (ref op; ops)
            op.payload.match!((ref FillRect fill) {
                chrome ~= fill.chrome is null ? BoxChrome.init : *fill.chrome;
                fill.chrome = null;
            }, (ref other) {});
        return tuple(ops, chrome);
    }
    assert(project(true) == project(false));
    const retained = sections.cachedLeaves[0].tree.nodes;
    assert(project(true) == project(false));
    assert(retained.ptr == sections.cachedLeaves[0].tree.nodes.ptr);
    foreach (step; 0 .. 4)
    {
        if (step == 0) subject.maximum = 700;
        if (step == 1) subject.weight = 650;
        if (step == 2) subject.locked = true;
        if (step == 3) { options.width = 40; focused = true; }
        pane.refresh();
        assert(project(true) == project(false), "retained controls must match the fresh projection");
    }
}

/// Preview dispatch, release grouping, numeric entry and cancellation share
/// the same settings subject and undo history.
@("ui.settings_sections.sliderTransactionsAndNumberEntry")
@system unittest
{
    import sparkles.ui.components.settings_pane : SettingsPane;
    import sparkles.ui.property_tree : NumericInput, PreferredInput, Range;
    import sparkles.ui.geometry : Constraints, Point;
    import sparkles.ui.layout : layout;
    import sparkles.input.events : charEvent;

    struct Subject
    {
        @Range(100, 700, 1) @PreferredInput(NumericInput.slider) double weight = 400;
        @Range(0, 1, 0.01) @PreferredInput(NumericInput.slider) float contrast = 0.25f;
    }
    Subject subject;
    SettingsPane!Subject pane;
    pane.open(&subject, subject);
    SettingsSections sections;
    Builder b;
    auto items = sections.items(pane);
    uint[] ids;
    foreach (item; items)
        ids ~= sections.row(b, pane, item, true, SectionsOptions.init, 1000);
    auto tree = b.finish(b.container(WidgetKind.column, ids));
    auto frames = layout(tree, Constraints(maxW: 60));
    Rect track;
    foreach (i, widget; tree.nodes)
        if (widget.hitId == sectionHit(1000, 0, SectionPart.slider))
            track = frames[i].rect;
    assert(track.width > 1);
    SettingsResult result;
    assert(sections.pointer(pane, PointerEvent(PointerAction.press, PointerButton.left,
        Point(track.x, track.y)), tree, frames, 1000, result));
    assert(subject.weight == 100 && pane.edits.undo.length == 0);
    assert(sections.pointer(pane, PointerEvent(PointerAction.release, PointerButton.left,
        Point(track.x + track.width + 10, track.y)), tree, frames, 1000, result));
    assert(subject.weight == 700 && pane.edits.undo.length == 1);
    cast(void) sections.pointer(pane, PointerEvent(PointerAction.press, PointerButton.left,
        Point(track.x, track.y)), tree, frames, 1000, result);
    cast(void) sections.cancel(pane);
    assert(subject.weight == 700 && pane.edits.undo.length == 1);
    cast(void) sections.activate(pane, 0, SectionPart.open, SectionsOptions.init);
    assert(pane.textEditing && pane.textBuf == "700");
    cast(void) pane.handleKey(KeyEvent(Key.escape));
    cast(void) pane.editTextAt("contrast");
    pane.textBuf = "0.35";
    cast(void) pane.handleKey(KeyEvent(Key.enter));
    assert(subject.contrast == 0.35f);
    cast(void) pane.stepAt("contrast", 1);
    assert(subject.contrast == 0.36f);
}
