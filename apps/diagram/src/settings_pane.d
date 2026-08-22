/**
The board's modal settings pane (`SET1`–`SET6`).

A $(REF PropertyTree, sparkles,ui,property_tree) over
$(REF DiagramSettings, settings), presented with the toolkit's own
$(REF propertyView, sparkles,ui,components,property_view) and framed as one
widget tree — so `--tui` and `--gui` show the same pane for the same reason the
board does: nothing here names a canvas (`DIA1`, `DIA2`).

$(B It holds no pointer to the subject.) Every entry point takes `ref
DiagramSettings`, which is `PRT2`'s rule and also the honest reading of the
frame model: the settings are whatever $(MREF world) owns this frame, and an
edit lands in the running board rather than in a copy waiting to be written
back (`SET3`).

$(B Modality is the keymap, not a chain of ifs.) Keys resolve through
$(REF commandFor, keymap) in the `settings` scope, which is terminal and hides
the board's — so an unbound key is spent here instead of panning the camera
underneath the dialog. The only `if` is the one in
$(REF DiagramApp.handle, diagram_app) that decides who receives the event.

Generic over the subject so its behaviour is testable against a fixture struct
with no board, no world and no host; $(LREF SettingsPane) pins it to the real
one.
*/
module settings_pane;

import std.conv : text;

import sparkles.input.events : Event, Key, KeyEvent, PointerAction,
    PointerButton, PointerEvent, WheelEvent;
import std.sumtype : match;

import sparkles.ui.components.property_view : propertyView,
    PropertyViewOptions;
import sparkles.ui.components.tree_view : treeActivate = activate,
    treeCollapseOrUp = collapseOrUp, TreeStep, TreeViewState;
import sparkles.ui.geometry : Constraints, Insets, Point, Size,
    SizeSpec;
import sparkles.ui.layout : layout;
import sparkles.ui.property_tree : Edit, EditPhase, editProperty, EditValue,
    finishPending, LeafKind, PropertyEditState, PropertyNode, PropertyTree,
    readValueAt, redoProperty, undoProperty;
import sparkles.ui.style : BorderStyle, Decoration, Slot, TextStyle;
import sparkles.ui.widget : Alignment, Builder, TextSpan, Widget, WidgetKind,
    WidgetTree;

import keymap : commandFor, DiagramCommand, DiagramContext;
import settings : applyPreset, DiagramSettings, gridPresetCount;

// ─────────────────────────────────────────────────────────────────────────────
// The host contract.
// ─────────────────────────────────────────────────────────────────────────────

/**
What the caller must do with a handled event.

`saveRequested` is the one thing this component cannot do for itself: where
the file lives is `main`'s answer (`--config-file`, or the platform config
dir), and writing it is I/O. So the pane finishes any pending drag, says
`saveRequested`, and the caller writes the file and reports back through
$(LREF SettingsPaneT.status) — which keeps the component free of `std.file`
and testable with no filesystem at all.
*/
enum PaneOutcome : ubyte
{
    consumed,      /// nothing for the caller to do
    closed,        /// the pane closed; the board takes the keyboard back
    saveRequested, /// persist the subject, then set `status` to the outcome
}

/**
Frame-stable overlay geometry, derived from the viewport alone.

Selection, filtering and editing never move a border — the same rule the key
guide follows, and the reason a reader's eye can stay on one row while the
rows beneath it change.
*/
struct PaneGeometry
{
    int cols = 72; ///
    int rows = 24; ///
    int x;         /// top-left, centred in the viewport
    int y;         /// ditto

    /// Whether a surface cell falls inside the panel — the modal hit test.
    bool contains(in Point cell) const @safe pure nothrow @nogc
        => cell.x >= x && cell.x < x + cols
            && cell.y >= y && cell.y < y + rows;
}

/// ditto
PaneGeometry paneGeometryFor(in Size viewport) @safe pure nothrow @nogc
{
    int cols = viewport.width - 8;
    if (cols > 88)
        cols = 88;
    if (cols < 40)
        cols = viewport.width > 42 ? viewport.width - 2 : 40;
    int rows = viewport.height - 4;
    if (rows > 28)
        rows = 28;
    if (rows < 8)
        rows = 8;
    const x = viewport.width > cols ? (viewport.width - cols) / 2 : 0;
    const y = viewport.height > rows ? (viewport.height - rows) / 2 : 0;
    return PaneGeometry(cols, rows, x, y);
}

// ─────────────────────────────────────────────────────────────────────────────
// The component.
// ─────────────────────────────────────────────────────────────────────────────

/// Tree rows' hit ids start here (`node + hitBase`).
private enum uint hitBase = 1;

/// ditto
struct SettingsPaneT(T)
{
    /// The per-rebuild row snapshot and the ranked filter (`PRT29`).
    PropertyTree!T tree;
    /// Cursor, viewport, opened set and filter query (`PRT1`).
    TreeViewState!string tv;
    /// Undo/redo and the pending preview group (`PRT17`).
    PropertyEditState edits;
    /// A `v` preview session is live (`PRT19`).
    bool previewing;
    /// Footer line: the save outcome, the preset note.
    string status;

    private bool _built;
    private PaneGeometry _geom;

    /**
    First-use build plus a rebuild; idempotent, so the caller may say it every
    frame rather than tracking whether the pane was opened yet.
    */
    void ensure(ref T subject, in PaneGeometry g) @safe
    {
        if (!_built || g != _geom)
        {
            _geom = g;
            // Borders + title + the filter line + the footer.
            tv.width = g.cols - 6;
            tv.height = g.rows - 5;
            tv.chromeRows = 0;
            tv.scrollGutterV = 1;
            tv.scrollGutterH = 0;
            _built = true;
        }
        refresh(subject);
    }

    /// Rebuild rows from the subject, pinning a pending edit's path (`PRT34`).
    void refresh(ref T subject) @safe
    {
        tree.rebuild(subject, tv,
            edits.pendingActive ? edits.pendingPath : null);
    }

    /**
    Close: the session's edits stay in the board, nothing is written.

    A live preview drag commits first, so no half-drag is abandoned in
    retained state (`PRT19`'s commit-boundary rule).
    */
    void close(ref T subject) @safe
    {
        if (previewing)
        {
            cast(void) finishPending(subject, edits, tree.policy);
            previewing = false;
        }
        if (tv.searching)
            cast(void) tv.filterKey(KeyEvent(Key.escape));
        status = null;
    }

    // ── keys ────────────────────────────────────────────────────────────────

    /// ditto
    PaneOutcome handleKey(ref T subject, in KeyEvent k) @safe
    {
        // The live filter has first refusal (`SET6`): typed text is the
        // query, and anything it declines still resolves — so Down moves the
        // cursor while a query is being typed.
        if (tv.searching)
        {
            const st = tv.filterKey(k);
            if (st == TreeStep.rebuild)
            {
                refresh(subject);
                return PaneOutcome.consumed;
            }
            if (st != TreeStep.none)
                return PaneOutcome.consumed;
        }

        const kc = commandFor(k, DiagramContext(settingsOpen: true));
        switch (kc.cmd)
        {
            case DiagramCommand.settingsClose:
                close(subject);
                return PaneOutcome.closed;
            case DiagramCommand.settingsDown:
                tv.moveSel(1);
                break;
            case DiagramCommand.settingsUp:
                tv.moveSel(-1);
                break;
            case DiagramCommand.settingsPageDown:
                tv.moveSel(tv.bodyRows > 1 ? tv.bodyRows - 1 : 1);
                break;
            case DiagramCommand.settingsPageUp:
                tv.moveSel(-(tv.bodyRows > 1 ? tv.bodyRows - 1 : 1));
                break;
            case DiagramCommand.settingsHome:
                tv.selHome();
                break;
            case DiagramCommand.settingsEnd:
                tv.selEnd();
                break;
            case DiagramCommand.settingsExpand:
                return expandSel(subject);
            case DiagramCommand.settingsCollapse:
                return collapseSel(subject);
            case DiagramCommand.settingsActivate:
                return activateSel(subject);
            case DiagramCommand.settingsInc:
                return stepEdit(subject, 1);
            case DiagramCommand.settingsDec:
                return stepEdit(subject, -1);
            case DiagramCommand.settingsPreview:
                return togglePreview(subject);
            case DiagramCommand.settingsUndo:
                cast(void) undoProperty(subject, edits, tree.policy);
                refresh(subject);
                break;
            case DiagramCommand.settingsRedo:
                cast(void) redoProperty(subject, edits, tree.policy);
                refresh(subject);
                break;
            case DiagramCommand.settingsReset:
                return resetSel(subject);
            case DiagramCommand.settingsFilter:
                tv.filterStart();
                refresh(subject);
                break;
            case DiagramCommand.settingsMatchNext:
                tree.jumpMatch(tv, 1);
                break;
            case DiagramCommand.settingsMatchPrev:
                tree.jumpMatch(tv, -1);
                break;
            case DiagramCommand.settingsReveal:
                if (tree.searching)
                {
                    tree.revealInBase(subject, tv);
                    refresh(subject);
                }
                break;
            case DiagramCommand.settingsSave:
                return save(subject);
            case DiagramCommand.gridPreset:
                return usePreset(subject, kc.arg);
            default:
                // Modal: an unbound key is spent here, never a board command
                // beneath (`SET2`).
                break;
        }
        return PaneOutcome.consumed;
    }

    // ── pointer ─────────────────────────────────────────────────────────────

    /// Routes a pane-local event (the caller already translated it).
    PaneOutcome handleOverlay(ref T subject, in Event e) @safe
    {
        PaneOutcome outcome = PaneOutcome.consumed;
        auto self = (() @trusted => &this)();
        e.match!(
            (in WheelEvent w) {
                tv.top += w.dy * 3;
                tv.clampBounds();
            },
            (in PointerEvent p) {
                if (p.action != PointerAction.press
                    || p.button != PointerButton.left)
                    return;
                import sparkles.ui.state : hoverTargets;

                auto view = self.buildView();
                auto frames = layout(view, Constraints(maxW: self._geom.cols));
                foreach (t; hoverTargets(view, frames))
                {
                    if (t.hitId < hitBase || !t.rect.contains(p.pos))
                        continue;
                    const node = cast(uint)(t.hitId - hitBase);
                    foreach (i, ref const r; self.tv.rows)
                        if (r.node == node)
                        {
                            // A click on the selected row activates it; a
                            // click elsewhere selects first, so no value
                            // changes under a pointer that was only aiming.
                            if (self.tv.sel == cast(long) i)
                                outcome = self.activateSel(subject);
                            else
                            {
                                self.tv.sel = cast(long) i;
                                self.tv.clamp();
                            }
                            return;
                        }
                }
            },
            (e2) {},
        );
        return outcome;
    }

    // ── the edit engine ─────────────────────────────────────────────────────

    private const(PropertyNode)* selectedNode() @safe
    {
        const node = tv.selectedNode;
        if (node == uint.max || node >= tree.data.nodes.length)
            return null;
        return (() @trusted => &tree.data.nodes[node].value)();
    }

    private PaneOutcome expandSel(ref T subject) @safe
    {
        if (const n = selectedNode())
            if (n.expandable)
            {
                if (tree.searching)
                    tv.searchFold = tv.searchFold.opened(n.path);
                else
                    tv.open = tv.open.opened(n.path);
                refresh(subject);
            }
        return PaneOutcome.consumed;
    }

    private PaneOutcome collapseSel(ref T subject) @safe
    {
        auto self = (() @trusted => &this)();
        if (tree.searching)
        {
            // Folding under a query is the transient overlay: visibility
            // only, discarded with the query (`PRT29`).
            if (const n = selectedNode())
                if (n.expandable)
                {
                    tv.searchFold = tv.searchFold.closed(n.path);
                    refresh(subject);
                }
            return PaneOutcome.consumed;
        }
        if (treeCollapseOrUp(tv, tree.data,
                (uint node) => self.tree.keyOf(node)) == TreeStep.rebuild)
            refresh(subject);
        return PaneOutcome.consumed;
    }

    /// Enter: descend a composite, or cycle a bool/enum leaf.
    private PaneOutcome activateSel(ref T subject) @safe
    {
        const n = selectedNode();
        if (n is null)
            return PaneOutcome.consumed;
        if (n.expandable && !tree.searching)
        {
            auto self = (() @trusted => &this)();
            if (treeActivate(tv, tree.data,
                    (uint node) => self.tree.keyOf(node)) == TreeStep.rebuild)
                refresh(subject);
            return PaneOutcome.consumed;
        }
        if (n.kind == LeafKind.boolean || n.kind == LeafKind.enumeration)
            return stepEdit(subject, 1);
        return PaneOutcome.consumed;
    }

    /// One `+`/`-` step through the generated dispatch (`SET3`).
    private PaneOutcome stepEdit(ref T subject, int dir) @safe
    {
        const n = selectedNode();
        if (n is null || n.synthetic || n.composite)
            return PaneOutcome.consumed;

        Edit e;
        e.path = n.path;
        e.phase = previewing ? EditPhase.preview : EditPhase.commit;
        EditValue cur;
        final switch (n.kind)
        {
            case LeafKind.none:
            case LeafKind.opaque:
                return PaneOutcome.consumed;
            case LeafKind.text:
                // `GridConfig` has no string leaves, so no line editor exists
                // to go stale (`SET7`); one appearing renders read-only.
                return PaneOutcome.consumed;
            case LeafKind.boolean:
                e.value = EditValue.of(n.badge != "true");
                break;
            case LeafKind.enumeration:
                if (n.choices.length == 0)
                    return PaneOutcome.consumed;
                size_t at;
                foreach (i, c; n.choices)
                    if (c == n.badge)
                        at = i;
                const count = n.choices.length;
                e.value = EditValue.ofEnum(
                    n.choices[(at + count + (dir < 0 ? count - 1 : 1)) % count]);
                break;
            case LeafKind.integral:
                if (!readValueAt(subject, n.path, cur))
                    return PaneOutcome.consumed;
                const stepI = n.hasRange && n.step > 0 ? cast(long) n.step : 1L;
                e.value = EditValue.of(cur.i + dir * stepI);
                break;
            case LeafKind.floating:
                if (!readValueAt(subject, n.path, cur))
                    return PaneOutcome.consumed;
                const stepF = n.hasRange && n.step > 0 ? n.step : 0.1;
                e.value = EditValue.of(cur.f + dir * stepF);
                break;
        }
        cast(void) editProperty(subject, e, edits, tree.policy);
        refresh(subject);
        return PaneOutcome.consumed;
    }

    private PaneOutcome togglePreview(ref T subject) @safe
    {
        if (previewing)
        {
            // The commit boundary: one history entry for the whole drag.
            cast(void) finishPending(subject, edits, tree.policy);
            previewing = false;
        }
        else
            previewing = true;
        refresh(subject);
        return PaneOutcome.consumed;
    }

    /// `r`: the selected leaf back to its compiled default, written through
    /// the same dispatch — so it is range-checked, refusable and undoable.
    private PaneOutcome resetSel(ref T subject) @safe
    {
        const n = selectedNode();
        if (n is null || n.composite || n.synthetic)
            return PaneOutcome.consumed;
        T defaults;
        EditValue dv;
        if (!readValueAt(defaults, n.path, dv))
            return PaneOutcome.consumed;
        cast(void) editProperty(subject, Edit(n.path, dv, EditPhase.commit),
            edits, tree.policy);
        refresh(subject);
        return PaneOutcome.consumed;
    }

    /**
    `1`–`3`: a named fixture (`SET4`).

    A preset rewrites the whole grid, which is the structural edit the
    property tree deliberately does not model (`PRT22`) — it has no inverse to
    record. So the history is cleared rather than left holding entries whose
    `before` value no longer exists: `PRT18`'s precondition would refuse on
    them at the next undo, silently, and the reader would have no way to see
    why. The footer says what happened.
    */
    private PaneOutcome usePreset(ref T subject, uint which) @safe
    {
        static if (is(T == DiagramSettings))
        {
            import sparkles.ui.components.grid_backdrop : GridPreset;

            if (which >= gridPresetCount)
                return PaneOutcome.consumed;
            if (previewing)
            {
                cast(void) finishPending(subject, edits, tree.policy);
                previewing = false;
            }
            applyPreset(subject, cast(GridPreset) which);
            edits = PropertyEditState.init;
            status = text("grid fixture ", which + 1, " applied — history cleared");
            refresh(subject);
        }
        return PaneOutcome.consumed;
    }

    /// `s`: ask the caller to persist (`SET5`).
    ///
    /// A pending preview drag commits first, so what reaches the file is a
    /// settled value rather than whatever the drag happened to be showing.
    private PaneOutcome save(ref T subject) @safe
    {
        if (previewing)
        {
            cast(void) finishPending(subject, edits, tree.policy);
            previewing = false;
            refresh(subject);
        }
        status = null;
        return PaneOutcome.saveRequested;
    }

    // ── the view ────────────────────────────────────────────────────────────

    /// The whole pane as one widget tree, built at the origin.
    WidgetTree buildView() @safe
    {
        Builder b;
        uint[] body_;

        body_ ~= b.add(Widget(kind: WidgetKind.rich, spans: filterSpans(),
            width: SizeSpec.grow()));

        auto opt = PropertyViewOptions(
            valueColumn: _geom.cols > 60 ? 30 : 20,
            rangeBarCells: _geom.cols > 50 ? 8 : 4,
        );
        const treeCol = propertyView(b, tree.data, tv, edits, opt, hitBase);
        body_ ~= b.add(Widget(kind: WidgetKind.column, children: [treeCol],
            clipX: true, clipY: true, width: SizeSpec.grow(),
            height: SizeSpec.grow()));

        body_ ~= b.add(Widget(kind: WidgetKind.rich, spans: footerSpans(),
            width: SizeSpec.grow()));

        const content = b.add(Widget(kind: WidgetKind.column, children: body_,
            width: SizeSpec.grow(), height: SizeSpec.grow(),
            clipX: true, clipY: true));
        const boxed = b.add(Widget(kind: WidgetKind.panel, children: [content],
            padding: Insets(1, 2, 1, 2),
            slot: Slot.surface, paintBackground: true,
            decoration: Decoration(borderWidth: Insets.all(2),
                borderStyle: BorderStyle.solid, borderRadius: 6,
                borderSlot: Slot.highlightBorder),
            width: SizeSpec.fixed(_geom.cols),
            height: SizeSpec.fixed(_geom.rows)));
        const titleText = b.add(Widget(kind: WidgetKind.text,
            text: " Settings ", slot: Slot.chromeAccent,
            textStyle: TextStyle(bold: true)));
        const titleRow = b.add(Widget(kind: WidgetKind.row,
            children: [titleText], width: SizeSpec.fixed(_geom.cols),
            alignX: Alignment.center));
        const root = b.add(Widget(kind: WidgetKind.stack,
            children: [boxed, titleRow],
            width: SizeSpec.fixed(_geom.cols),
            height: SizeSpec.fixed(_geom.rows)));
        return b.finish(root);
    }

    private TextSpan[] filterSpans() @safe
    {
        TextSpan[] spans;
        if (!tv.searching && tv.filterQuery.length == 0)
        {
            spans ~= TextSpan(text: "/ filter · ⏎ open · +/- value · v drag "
                ~ "· u undo · r reset · 1-3 fixture · s save · Esc close",
                slot: Slot.muted);
            return spans;
        }
        spans ~= TextSpan(text: "/", slot: Slot.chromeAccent);
        spans ~= TextSpan(text: tv.filterQuery.length
            ? tv.filterQuery.idup : "type to search…",
            slot: tv.filterQuery.length ? Slot.code : Slot.muted);
        if (tv.searching)
            spans ~= TextSpan(text: "▏", slot: Slot.caret);
        if (tree.filterError.length)
            spans ~= TextSpan(text: text("  ⚠ ", tree.filterError),
                slot: Slot.error);
        else if (tree.searching)
        {
            spans ~= TextSpan(text: text("  ", tree.matchCount, " matches"),
                slot: Slot.info);
            if (tree.omittedMatches)
                spans ~= TextSpan(text: text("  ", tree.omittedMatches,
                    " omitted"), slot: Slot.muted);
            if (tree.searchIncomplete)
                spans ~= TextSpan(text: "  incomplete", slot: Slot.warn);
        }
        return spans;
    }

    private TextSpan[] footerSpans() @safe
    {
        TextSpan[] spans;
        spans ~= TextSpan(text: text("undo ", edits.undo.length, " · redo ",
            edits.redo.length), slot: Slot.muted);
        if (previewing)
            spans ~= TextSpan(text: "  preview", slot: Slot.chromeAccent);
        if (const n = selectedNode())
        {
            const r = edits.refusalFor(n.path);
            if (r.refused)
                spans ~= TextSpan(text: text("  ✗ ", r.kind), slot: Slot.error);
        }
        if (status.length)
            spans ~= TextSpan(text: text("  ", status), slot: Slot.info);
        return spans;
    }
}

/// The pane over the board's real subject (`SET4`).
alias SettingsPane = SettingsPaneT!DiagramSettings;

// ---------------------------------------------------------------------------
// Tests — the component against a fixture subject, and the real board's one.
// No world, no host, no window; keys resolve through the real
// $(MREF keymap), so what these drive is what a reader's fingers reach.
// ---------------------------------------------------------------------------

version (unittest)
{
    import sparkles.input.events : Mods;
    import sparkles.ui.property_tree : Range, RefusalKind;

    private enum FixMark : ubyte
    {
        lines,
        dots,
    }

    private struct FixStyle
    {
        FixMark mark;
        @Range(1, 16, 1) int thickness = 1;
    }

    private struct Fixture
    {
        bool visible = true;
        @Range(1, 64, 1) int interval = 8;
        FixStyle style;
    }

    private alias FixPane = SettingsPaneT!Fixture;

    private enum PaneGeometry testGeom = PaneGeometry(72, 20, 0, 0);

    /// Puts the cursor on a known row, so a test names a property rather than
    /// counting keystrokes to reach it.
    private bool selectPath(P)(ref P pane, string path) @safe
    {
        foreach (i, ref const r; pane.tv.rows)
            if (pane.tree.data.nodes[r.node].value.path == path)
            {
                pane.tv.sel = cast(long) i;
                pane.tv.clamp();
                return true;
            }
        return false;
    }

    private PaneOutcome key(P, S)(ref P pane, ref S subject, dchar c) @safe
        => pane.handleKey(subject, KeyEvent(Key.char_, c));

    private PaneOutcome named(P, S)(ref P pane, ref S subject, Key k) @safe
        => pane.handleKey(subject, KeyEvent(k));
}

@("diagram.settings_pane.editsLandInTheSubjectImmediately")
@safe unittest
{
    // `SET3`: there is no copy to write back — the value the pane edits is the
    // one the caller passed by reference.
    Fixture f;
    FixPane pane;
    pane.ensure(f, testGeom);

    assert(selectPath(pane, "visible"));
    cast(void) named(pane, f, Key.enter);
    assert(!f.visible, "Enter cycled the boolean in place");

    assert(selectPath(pane, "interval"));
    cast(void) key(pane, f, '+');
    assert(f.interval == 9, "`+` stepped by the @Range step");
    cast(void) key(pane, f, '-');
    cast(void) key(pane, f, '-');
    assert(f.interval == 7);
}

@("diagram.settings_pane.rangeIsEnforcedBeforeTheWriteAndShownOnTheRow")
@safe unittest
{
    // The refusal is the property tree's (`PRT15`/`PRT21`); what this asserts
    // is that the pane routes through the dispatch rather than assigning, so
    // the check cannot be bypassed by the presentation.
    Fixture f;
    f.interval = 64; // the declared maximum
    FixPane pane;
    pane.ensure(f, testGeom);

    assert(selectPath(pane, "interval"));
    cast(void) key(pane, f, '+');
    assert(f.interval == 64, "the value is untouched");
    assert(pane.edits.refusalFor("interval").kind == RefusalKind.outOfRange);
}

@("diagram.settings_pane.aPreviewDragIsOneHistoryEntry")
@safe unittest
{
    // `PRT19` through the pane's `v`: many steps, one undo.
    Fixture f;
    FixPane pane;
    pane.ensure(f, testGeom);
    assert(selectPath(pane, "interval"));

    cast(void) key(pane, f, 'v');
    assert(pane.previewing);
    foreach (_; 0 .. 4)
        cast(void) key(pane, f, '+');
    assert(f.interval == 12);
    assert(pane.edits.undo.length == 0, "a live drag records nothing yet");

    cast(void) key(pane, f, 'v'); // the commit boundary
    assert(!pane.previewing);
    assert(pane.edits.undo.length == 1, "the whole drag is one entry");

    cast(void) key(pane, f, 'u');
    assert(f.interval == 8, "undo goes back to before the drag, not one step");
}

@("diagram.settings_pane.undoAndRedoWalkTheSameHistory")
@safe unittest
{
    Fixture f;
    FixPane pane;
    pane.ensure(f, testGeom);
    assert(selectPath(pane, "visible"));

    cast(void) named(pane, f, Key.enter);
    assert(!f.visible);
    cast(void) key(pane, f, 'u');
    assert(f.visible);
    // Ctrl-R redoes: the one chord in the pane's table, because `r` is reset.
    cast(void) pane.handleKey(f, KeyEvent(Key.char_, 'r', Mods(ctrl: true)));
    assert(!f.visible);
}

@("diagram.settings_pane.resetReturnsALeafToItsCompiledDefault")
@safe unittest
{
    // `r` reads the default from a fresh `T.init` and writes it through the
    // dispatch — so it is range-checked and undoable like any other edit.
    Fixture f;
    f.interval = 40;
    FixPane pane;
    pane.ensure(f, testGeom);

    assert(selectPath(pane, "interval"));
    cast(void) key(pane, f, 'r');
    assert(f.interval == 8);
    cast(void) key(pane, f, 'u');
    assert(f.interval == 40, "…and the reset itself is undoable");
}

@("diagram.settings_pane.descendingReachesANestedLeaf")
@safe unittest
{
    Fixture f;
    FixPane pane;
    pane.ensure(f, testGeom);

    // A nested leaf is not addressable until its parent is open — the
    // disclosure-driven walk (`PRT4`), visible from the pane's side.
    assert(!selectPath(pane, "style.thickness"));
    assert(selectPath(pane, "style"));
    cast(void) named(pane, f, Key.right);
    assert(selectPath(pane, "style.thickness"));

    cast(void) key(pane, f, '+');
    assert(f.style.thickness == 2);
}

@("diagram.settings_pane.filteringIsASearchResultAndClearingRestoresTheTree")
@safe unittest
{
    // `SET6`: the filter is the property tree's own ranked projection, and it
    // takes first refusal — the typed characters are the query, not commands.
    Fixture f;
    FixPane pane;
    pane.ensure(f, testGeom);
    const baseRows = pane.tv.rows.length;

    cast(void) key(pane, f, '/');
    foreach (c; "thickness")
        cast(void) key(pane, f, c);
    assert(pane.tree.searching);
    assert(pane.tree.matchCount >= 1);
    assert(pane.tv.rows.length < baseRows, "the tree narrowed");
    // `v` went into the query, not into a preview drag.
    assert(!pane.previewing);

    cast(void) named(pane, f, Key.escape);
    pane.refresh(f);
    assert(!pane.tree.searching);
    assert(pane.tv.rows.length == baseRows, "clearing restores the tree");
}

@("diagram.settings_pane.saveFinishesTheDragAndAsksTheCaller")
@safe unittest
{
    // `SET5`: the component cannot write a file, and says so as a value —
    // after settling any live drag, so what the caller persists is a
    // committed value rather than mid-drag scenery.
    Fixture f;
    FixPane pane;
    pane.ensure(f, testGeom);
    assert(selectPath(pane, "interval"));

    cast(void) key(pane, f, 'v');
    cast(void) key(pane, f, '+');
    assert(pane.previewing);

    assert(key(pane, f, 's') == PaneOutcome.saveRequested);
    assert(!pane.previewing);
    assert(pane.edits.undo.length == 1);
}

@("diagram.settings_pane.escapeClosesAndSettlesAPendingDrag")
@safe unittest
{
    Fixture f;
    FixPane pane;
    pane.ensure(f, testGeom);
    assert(selectPath(pane, "interval"));

    cast(void) key(pane, f, 'v');
    cast(void) key(pane, f, '+');
    assert(named(pane, f, Key.escape) == PaneOutcome.closed);
    assert(!pane.previewing, "no half-drag left pending in retained state");
    assert(pane.edits.undo.length == 1);
}

@("diagram.settings_pane.aFixtureRewritesTheGridAndClearsTheHistory")
@safe unittest
{
    // `SET4`: a preset is structural, so it has no inverse to record — the
    // history is cleared rather than left holding entries that would refuse
    // as stale at the next undo (`PRT18`), silently.
    import sparkles.ui.components.grid_backdrop : MarkKind;

    DiagramSettings s;
    SettingsPane pane;
    pane.ensure(s, testGeom);

    assert(selectPath(pane, "board"));
    cast(void) named(pane, s, Key.right); // a child is addressable once open
    assert(selectPath(pane, "board.minimap"));
    cast(void) named(pane, s, Key.enter);
    assert(!s.board.minimap);
    assert(pane.edits.undo.length == 1);

    cast(void) key(pane, s, '3'); // dot paper
    assert(s.grid.minorStyle.markKind == MarkKind.dots);
    assert(pane.edits.undo.length == 0, "no inverse survives a structural write");
    assert(pane.status.length > 0, "…and the footer says why");
    assert(!s.board.minimap, "a GRID fixture leaves the board half alone");
}

@("diagram.settings_pane.theWholeGridConfigIsReachable")
@safe unittest
{
    // The point of reflecting `GridConfig` instead of listing three fixtures:
    // every knob `GRD2`-`GRD5` specifies has a row. Walking to one of the
    // deepest — a stripe brush's slot — proves the tree, not the pane, is
    // what decides that.
    DiagramSettings s;
    SettingsPane pane;
    pane.ensure(s, testGeom);
    pane.tv.open = typeof(pane.tv.open).allOpen;
    pane.refresh(s);

    static foreach (path; ["grid.minorLattice.interval", "grid.minorStyle.markKind",
        "grid.minorStyle.stroke", "grid.minorStyle.thickness",
        "grid.brushes.x[0].slot", "grid.brushes.yCount", "board.minimap"])
        assert(selectPath(pane, path), "unreachable: " ~ path);
}

@("diagram.settings_pane.theGeometryIsCentredAndFrameStable")
@safe pure nothrow @nogc
unittest
{
    import sparkles.ui.geometry : Point;

    const g = paneGeometryFor(Size(120, 40));
    assert(g.x * 2 + g.cols == 120 || g.x * 2 + g.cols == 119);
    assert(g.contains(Point(g.x, g.y)));
    assert(!g.contains(Point(g.x - 1, g.y)));
    assert(!g.contains(Point(g.x, g.y + g.rows)));

    // A viewport too small for the preferred size still yields a usable panel
    // rather than a negative one.
    const tiny = paneGeometryFor(Size(20, 6));
    assert(tiny.cols > 0 && tiny.rows > 0);
    assert(tiny.x >= 0 && tiny.y >= 0);
}

@("diagram.settings_pane.theViewIsOneWidgetTreeWithTheRowsInIt")
@safe unittest
{
    import sparkles.ui.widget : WidgetKind;

    DiagramSettings s;
    SettingsPane pane;
    pane.ensure(s, testGeom);
    auto tree = pane.buildView();

    assert(tree.nodes.length > 0);
    bool panel;
    foreach (ref n; tree.nodes)
        panel |= n.kind == WidgetKind.panel;
    assert(panel, "the pane is a framed surface, not loose rows");
}
