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
import sparkles.ui.geometry : Rect;
import sparkles.ui.layout : Frame;
import sparkles.ui.property_tree : EditValue, LeafKind, readValueAt;
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
        const n = &pane.tree.data.nodes[item.node].value;
        if (item.kind == SectionItem.Kind.header)
            return sectionHeader(b, n.heading,
                item.collapsed ? sectionSummary(pane.tree.data, item.node) : n.path,
                item.collapsed, sectionHit(base, item.node, SectionPart.row), opt);
        const st = rowState(pane, n.path, focused);
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

    /// Pointer coordinates and frames must use the same space. Capture owns
    /// subsequent moves/releases, including positions outside the track.
    bool pointer(P)(ref P pane, in PointerEvent p, in WidgetTree tree,
        scope const(Frame)[] frames, size_t base, out SettingsResult result, bool touch = false)
    {
        result = SettingsResult.init;
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
            if (ay > ax && ay >= 1)
            {
                pendingTouch = false;
                return false;
            }
            if (ax < 1 || ax <= ay)
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
        foreach_reverse (i, ref const widget; tree.nodes)
        {
            if (i >= frames.length || !frames[i].rect.contains(p.pos))
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
            if (touch)
            {
                pendingTouch = true;
                pendingTrack = frames[i].rect;
                pendingDomain = SliderDomain(n.lo, n.hi, n.step);
                pendingBefore = before.kind == EditValue.Kind.integral ? before.i : before.f;
                return false;
            }
            drag.begin(frames[i].rect, SliderDomain(n.lo, n.hi, n.step),
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
