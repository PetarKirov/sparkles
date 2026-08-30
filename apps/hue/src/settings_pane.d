/**
The modal settings pane (`SET*`): `PropertyTree` over the running
configuration, shared by both hosts the way the picker is — one component
value, one `buildView` widget tree, one key/pointer dispatch, mounted by the
workspace and the window alike.

Semantics (user-decided): $(B live-apply + explicit save). Every committed
edit mutates the running config immediately through the property tree's
generated dispatch (validated, refusable, undoable — `PropertyEditState` is
the history); a Save writes the $(B file draft) through the config core's
sparse writer; closing without saving keeps the session's runtime state and
persists nothing.

The CFG11 rule is structural here: the pane mirrors every commit into
`fileDraft` (seeded from defaults + the user file only — $(I below) env and
CLI) and records the touched paths, so an env/CLI-shadowed value the user
never touched can never leak into the file, while a touched one saves with
the toggled value, not the flag's. When the selected leaf is shadowed by a
higher layer, the footer says so.

Generic over the subject so the component's whole behavior is unit-tested
against a fixture struct; `SettingsPane` pins it to `HueConfig`.
*/
module settings_pane;

import std.conv : text;

import core.time : Duration;

import sparkles.base.term_control : PointerShape;

import sparkles.input.capability : InputCapabilities, mousePointer;
import sparkles.input.events : Event, Key, KeyEvent, Point, PointerAction,
    PointerButton, PointerEvent, WheelEvent;
import std.sumtype : match;

import sparkles.ui.components.property_view : propertyView,
    PropertyViewOptions;
import sparkles.ui.components.tree_view : treeActivate = activate,
    treeCollapseOrUp = collapseOrUp, TreeStep, TreeViewState;
import sparkles.ui.geometry : Constraints, Insets, Rect, SizeSpec;
import sparkles.ui.layout : Frame, layout;
import sparkles.ui.state : CaptureState;
import sparkles.ui.property_tree : applyEdit, Edit, EditPhase, editProperty,
    EditValue, finishPending, LeafKind, PropertyEditState, PropertyNode,
    PropertyTree, readValueAt, redoProperty, undoProperty;
import sparkles.ui.style : BorderStyle, Decoration, Slot, TextStyle;
import sparkles.ui.widget : Alignment, Builder, TextSpan, Widget, WidgetKind,
    WidgetTree;

import keymap : Command, commandFor, InputMode, KeyContext;

// ─────────────────────────────────────────────────────────────────────────────
// The host contract.
// ─────────────────────────────────────────────────────────────────────────────

/// What the host must do with a handled event.
struct SettingsResult
{
    /// ditto
    enum Kind : ubyte
    {
        consumed, /// nothing for the host beyond `apply`
        closed,   /// the pane closed; return the keyboard
        saved,    /// a save succeeded (the status line already says so)
    }

    Kind kind;

    /// Actions the host performs NOW — application is host-specific (the
    /// TUI resolves a theme name into its cycle, the window reloads fonts).
    ApplyMask apply;
}

/// ditto
enum ApplyMask : ubyte
{
    none = 0,
    theme = 1,  /// theme / background changed — re-resolve and repaint
    font = 2,   /// a font face or size changed — GUI reloads, TUI ignores
    layout = 4, /// pane geometry changed — re-arrange the dock
}

/// One live-apply rule: the longest matching prefix's mask is returned from
/// a committed edit. The host supplies the table at `open` (the generic
/// component knows no config paths).
struct ApplyRule
{
    string prefix;
    ApplyMask mask;
}

/// Frame-stable overlay geometry, from the screen size alone (`INP10`):
/// selection, filtering and editing never move a border.
struct SettingsGeometry
{
    int panelCols = 72;
    int panelRows = 24;
}

/// ditto
SettingsGeometry settingsGeometryFor(int screenCols, int screenRows)
    @safe pure nothrow @nogc
{
    int cols = screenCols - 8;
    if (cols > 96)
        cols = 96;
    if (cols < 44)
        cols = screenCols > 46 ? screenCols - 2 : 44;
    int rows = screenRows - 4;
    if (rows > 30)
        rows = 30;
    if (rows < 10)
        rows = 10;
    return SettingsGeometry(cols, rows);
}

// ─────────────────────────────────────────────────────────────────────────────
// The component.
// ─────────────────────────────────────────────────────────────────────────────

/// The tree rows' hit ids start here (`node + hitBase`).
private enum uint hitBase = 1;

/// The tree area's widget key (pointer routing finds its rect by it) and
/// the capture-id base the scrollbar grabs claim.
private enum size_t settingsTreeKey = 0x5e77_ba55;
/// ditto
private enum size_t captureBase = 0x5e77_ba00;

/// ditto
struct SettingsPaneT(T)
{
    // The property-tree bundle (the gallery page's shape, subject by
    // pointer: the config outlives the pane and `editProperty` takes `ref`).
    T* subject;                  ///
    PropertyTree!T tree;         ///
    TreeViewState!string tv;     ///
    PropertyEditState edits;     ///
    bool previewing;             /// a `v` preview session is live (`PRT19`)
    bool active;                 ///

    // Persistence (the CFG11 rule, structurally).
    T fileDraft;                 /// defaults + user file + this session's commits
    T savedDraft;                /// at open / last save; `dirty` compares
    string[] touched;            /// paths committed this session
    /// The save seam: returns `null` on success, a rendered refusal
    /// otherwise (the config core's `saveUserConfig` behind an adapter).
    string delegate(ref const T draft, const(string)[] touched) doSave;
    /// Optional provenance lookup (`CFG10`'s machinery): non-empty for a
    /// path whose effective value came from env/CLI — the shadow warning.
    string delegate(string path) @safe originOf;

    ApplyRule[] applyRules;      ///

    // The string-leaf line editor (`Scope_.input` owns the keys while open).
    bool textEditing;            ///
    string textPath;             ///
    string textBuf;              ///

    string status;               /// footer line: saves, refusals, apply notes

    /// The scrollbar-grab capture and the pointer profile the hover-expand
    /// easing follows (`SCV1` — the same machine the tree views ease with).
    CaptureState capture;
    /// ditto
    InputCapabilities caps = mousePointer;

    private SettingsGeometry geom;

    /// Opens over the shared config. `fileValue` seeds the save draft:
    /// defaults + user file only, BELOW env and CLI (`CFG11`).
    void open(T* cfg, T fileValue, SettingsGeometry g = SettingsGeometry())
    {
        subject = cfg;
        fileDraft = fileValue;
        savedDraft = fileValue;
        touched = null;
        status = null;
        active = true;
        resize(g);
        refresh();
    }

    /// Re-derives the row window from a (possibly changed) geometry.
    void resize(SettingsGeometry g)
    {
        geom = g;
        tv.width = g.panelCols - 6;
        tv.height = g.panelRows - 6; // borders + title + filter + footer
        tv.chromeRows = 0;
        tv.scrollGutterV = 1;
        tv.scrollGutterH = 0;
        if (subject !is null)
            refresh();
    }

    /// Close: the session's runtime state stays, nothing persists. A live
    /// preview drag commits first so no half-drag is left pending.
    void close()
    {
        if (subject is null)
            return;
        if (previewing)
        {
            cast(void) finishPending(*subject, edits, tree.policy);
            previewing = false;
        }
        textEditing = false;
        if (tv.searching)
            cast(void) tv.filterKey(KeyEvent(Key.escape));
        active = false;
    }

    /// Unsaved committed edits since open / the last save.
    bool dirty() const => fileDraft != savedDraft;

    /// The context the keymap resolves against while the pane is open.
    KeyContext keyContext() const @safe pure nothrow @nogc
        => KeyContext(settingsActive: true,
            mode: textEditing ? InputMode.settingsText : InputMode.normal);

    /// Rebuild rows from the subject, pinning a pending edit's path.
    void refresh() @safe
    {
        tree.rebuild(*subject, tv,
            edits.pendingActive ? edits.pendingPath : null);
    }

    /// Advances the scrollbar hover-expand easings; hosts call it once per
    /// frame while the pane is open — the same cadence the guide ticks at.
    void tickAnims(Duration elapsed) @safe pure nothrow @nogc
    {
        tv.tick(caps, cast(float) elapsed.total!"hnsecs" / 10_000_000.0f);
    }

    /**
    This pane's claim on the frame's one pointer shape (`DCK15`) — its bar
    machine's, `ns-resize` over or grabbing the bar, default elsewhere.

    Being closed is $(B not) a special case: an inactive pane claims
    `default_`, which composes away. That is the point. The modal used to be a
    branch in each host — `settingsPane.active ? settingsPane.pointerShape() :
    …` — which is `MDL1`'s warning about caching stack-derived blocking as a
    flag, in its smallest form: two hosts each testing the same `active` bit to
    decide whether the pane's answer counts. A claim that is simply quiet while
    closed needs neither test.
    */
    PointerShape shapeClaim() const @safe pure nothrow @nogc
        => active ? tv.scroll.shape() : PointerShape.default_;

    // ── keys ────────────────────────────────────────────────────────────────

    /// ditto
    SettingsResult handleKey(in KeyEvent k)
    {
        // 1. The string editor owns the keyboard entirely while open.
        if (textEditing)
            return handleTextKey(k);

        // 2. The live filter has first refusal (typed text is the query;
        //    anything it declines still resolves — Down moves while typing).
        if (tv.searching)
        {
            const st = tv.filterKey(k);
            if (st == TreeStep.rebuild)
            {
                refresh();
                return consumed();
            }
            if (st != TreeStep.none)
                return consumed();
        }

        // 3. Command dispatch over the settings scope; a modal surface
        //    swallows what it does not bind.
        const kc = commandFor(k, keyContext());
        switch (kc.cmd)
        {
            case Command.settingsClose:
                close();
                return SettingsResult(SettingsResult.Kind.closed);
            case Command.settingsDown:
                tv.moveSel(1);
                return consumed();
            case Command.settingsUp:
                tv.moveSel(-1);
                return consumed();
            case Command.settingsPageDown:
                tv.moveSel(tv.height > 2 ? tv.height - 2 : 1);
                return consumed();
            case Command.settingsPageUp:
                tv.moveSel(-(tv.height > 2 ? tv.height - 2 : 1));
                return consumed();
            case Command.settingsHome:
                tv.selHome();
                return consumed();
            case Command.settingsEnd:
                tv.selEnd();
                return consumed();
            case Command.settingsExpand:
            {
                const n = selectedNode();
                if (n !is null && n.expandable)
                {
                    if (tree.searching)
                        tv.searchFold = tv.searchFold.opened(n.path);
                    else
                        tv.open = tv.open.opened(n.path);
                    refresh();
                }
                return consumed();
            }
            case Command.settingsCollapse:
                return collapseSel();
            case Command.settingsActivate:
                return activateSel();
            case Command.settingsInc:
                return stepEdit(1);
            case Command.settingsDec:
                return stepEdit(-1);
            case Command.settingsPreview:
                if (previewing)
                {
                    // The commit boundary: one history entry per drag
                    // (PRT19), funneled like every commit.
                    const a = finishPending(*subject, edits, tree.policy);
                    previewing = false;
                    if (a.ok)
                        return committed(edits.undo.length
                            ? edits.undo[$ - 1].path : null);
                    refresh();
                }
                else
                    previewing = true;
                return consumed();
            case Command.settingsUndo:
            {
                const a = undoProperty(*subject, edits, tree.policy);
                return a.ok ? committed(a.inverse.path) : consumedRefresh();
            }
            case Command.settingsRedo:
            {
                const a = redoProperty(*subject, edits, tree.policy);
                return a.ok ? committed(a.inverse.path) : consumedRefresh();
            }
            case Command.settingsFilter:
                tv.filterStart();
                refresh();
                return consumed();
            case Command.settingsMatchNext:
                tree.jumpMatch(tv, 1);
                return consumed();
            case Command.settingsMatchPrev:
                tree.jumpMatch(tv, -1);
                return consumed();
            case Command.settingsReveal:
                if (tree.searching)
                {
                    tree.revealInBase(*subject, tv);
                    refresh();
                }
                return consumed();
            case Command.settingsOpenAll:
                tv.open = typeof(tv.open).allOpen;
                refresh();
                return consumed();
            case Command.settingsCloseAll:
                tv.open = typeof(tv.open).allClosed;
                refresh();
                return consumed();
            case Command.settingsReset:
                return resetSel();
            case Command.settingsSave:
                return save();
            default:
                // Modal: an unbound key is spent, never a command beneath.
                return consumed();
        }
    }

    // ── pointer ─────────────────────────────────────────────────────────────

    /**
    Routes an overlay-local event (the host already translated it) through
    the tree machine: a press on the scrollbar is a grab that owns the
    pointer, hover feeds the bar's expand easing, a wheel notch scrolls
    leaving the cursor behind, and a press on a row selects (a second press
    activates) — the same routing every tree view has.
    */
    SettingsResult handleOverlay(in Event e, SettingsGeometry g)
    {
        auto view = buildView(g);
        auto frames = layout(view, Constraints(maxW: g.panelCols));
        const area = treeArea(view, frames);

        SettingsResult result = consumed();
        e.match!(
            (in WheelEvent w) {
                tv.scrollBy(w.dy * 3);
            },
            (in PointerEvent p) {
                // Tree-local coordinates: the machine's frame is (0,0)-based
                // at the tree area's origin — the SAME frame the paint pass
                // laid the bar out from, so hit and paint cannot disagree.
                PointerEvent local = p;
                local.pos = Point(p.pos.x - area.x, p.pos.y - area.y);
                if (tv.pointer(local, capture, captureBase)
                    == TreeStep.activated)
                    result = activateSel();
            },
            (e2) {},
        );
        return result;
    }

    /// The tree area's laid-out rect, found by its widget key.
    private static Rect treeArea(in WidgetTree view,
        scope const(Frame)[] frames) @safe pure nothrow @nogc
    {
        foreach (i, ref const node; view.nodes)
            if (node.key == settingsTreeKey && i < frames.length)
                return frames[i].rect;
        return Rect.init;
    }

    // ── the edit engine ─────────────────────────────────────────────────────

    private const(PropertyNode)* selectedNode() @safe
    {
        const node = tv.selectedNode;
        if (node == uint.max || node >= tree.data.nodes.length)
            return null;
        return (() @trusted => &tree.data.nodes[node].value)();
    }

    private SettingsResult consumed() @safe pure nothrow @nogc
        => SettingsResult(SettingsResult.Kind.consumed);

    private SettingsResult consumedRefresh()
    {
        refresh();
        return consumed();
    }

    /// One `+`/`-` (or Enter-on-a-leaf) edit through the generated dispatch.
    private SettingsResult stepEdit(int dir)
    {
        const n = selectedNode();
        if (n is null || n.synthetic || n.composite)
            return consumed();

        Edit e;
        e.path = n.path;
        e.phase = previewing ? EditPhase.preview : EditPhase.commit;
        EditValue cur;
        final switch (n.kind)
        {
            case LeafKind.none:
                return consumed();
            case LeafKind.boolean:
                e.value = EditValue.of(n.badge != "true");
                break;
            case LeafKind.enumeration:
                size_t at;
                foreach (i, c; n.choices)
                    if (c == n.badge)
                        at = i;
                const nn = n.choices.length;
                e.value = EditValue.ofEnum(
                    n.choices[(at + nn + (dir < 0 ? nn - 1 : 1)) % nn]);
                break;
            case LeafKind.integral:
                if (!readValueAt(*subject, n.path, cur))
                    return consumed();
                const stepI = n.hasRange && n.step > 0
                    ? cast(long) n.step : 1L;
                e.value = EditValue.of(cur.i + dir * stepI);
                break;
            case LeafKind.floating:
                if (!readValueAt(*subject, n.path, cur))
                    return consumed();
                const stepF = n.hasRange && n.step > 0 ? n.step : 0.1;
                e.value = EditValue.of(cur.f + dir * stepF);
                break;
            case LeafKind.text:
                // Strings edit through the line editor, not a step.
                return openTextEditor(n.path);
            case LeafKind.opaque:
                return consumed();
        }
        const a = editProperty(*subject, e, edits, tree.policy);
        if (a.ok && e.phase == EditPhase.commit)
            return committed(e.path);
        refresh();
        return consumed();
    }

    /// Enter: descend a composite, toggle/cycle a bool/enum, edit a string.
    private SettingsResult activateSel()
    {
        const n = selectedNode();
        if (n is null)
            return consumed();
        if (n.expandable && !tree.searching)
        {
            // The un-scoped self-reference the delegate needs: `this` is
            // persistent host state, alive for every frame the pane shows.
            auto self = (() @trusted => &this)();
            if (treeActivate(tv, tree.data,
                (uint node) => self.tree.keyOf(node)) == TreeStep.rebuild)
                refresh();
            return consumed();
        }
        if (n.kind == LeafKind.boolean || n.kind == LeafKind.enumeration)
            return stepEdit(1);
        if (n.kind == LeafKind.text && n.editable)
            return openTextEditor(n.path);
        return consumed();
    }

    private SettingsResult collapseSel()
    {
        const n = selectedNode();
        if (tree.searching)
        {
            // Folding under a query is the transient overlay: visibility
            // only, discarded with the query (PRT29).
            if (n !is null && n.expandable)
            {
                tv.searchFold = tv.searchFold.closed(n.path);
                refresh();
            }
            return consumed();
        }
        auto self = (() @trusted => &this)();
        if (treeCollapseOrUp(tv, tree.data,
            (uint node) => self.tree.keyOf(node)) == TreeStep.rebuild)
            refresh();
        return consumed();
    }

    /// `r`: the selected leaf back to its compiled default — read from a
    /// fresh `T.init`, written through the dispatch (range-checked,
    /// refusable, undoable).
    private SettingsResult resetSel()
    {
        const n = selectedNode();
        if (n is null || n.composite || n.synthetic)
            return consumed();
        T defaults;
        EditValue dv;
        if (!readValueAt(defaults, n.path, dv))
            return consumed();
        const a = editProperty(*subject,
            Edit(n.path, dv, EditPhase.commit), edits, tree.policy);
        if (a.ok)
            return committed(n.path);
        refresh();
        return consumed();
    }

    /**
    Every successful COMMIT funnels here: mirror the subject's value at
    `path` into the file draft (resync-by-read — also correct after
    undo/redo, whose replayed value is already in the subject), record the
    touched path, and answer the host's apply mask.
    */
    private SettingsResult committed(string path)
    {
        if (path.length)
        {
            EditValue v;
            if (readValueAt(*subject, path, v))
                cast(void) applyEdit(fileDraft, Edit(path, v), tree.policy);
            noteTouched(path);
        }
        refresh();
        return SettingsResult(SettingsResult.Kind.consumed, applyFor(path));
    }

    private void noteTouched(string path) @safe
    {
        foreach (t; touched)
            if (t == path)
                return;
        touched ~= path;
    }

    private ApplyMask applyFor(string path) @safe pure nothrow @nogc
    {
        import std.algorithm.searching : startsWith;

        ApplyMask best = ApplyMask.none;
        size_t bestLen;
        foreach (ref r; applyRules)
            if (path.startsWith(r.prefix) && r.prefix.length >= bestLen)
            {
                best = r.mask;
                bestLen = r.prefix.length;
            }
        return best;
    }

    // ── the string-leaf line editor ─────────────────────────────────────────

    private SettingsResult openTextEditor(string path)
    {
        EditValue cur;
        if (!readValueAt(*subject, path, cur))
            return consumed();
        textPath = path;
        textBuf = cur.s.idup;
        textEditing = true;
        return consumed();
    }

    private SettingsResult handleTextKey(in KeyEvent k)
    {
        const kc = commandFor(k, keyContext());
        switch (kc.cmd)
        {
            case Command.inputAccept:
            {
                textEditing = false;
                const a = editProperty(*subject,
                    Edit(textPath, EditValue.ofText(textBuf),
                        EditPhase.commit), edits, tree.policy);
                return a.ok ? committed(textPath) : consumedRefresh();
            }
            case Command.inputCancel:
                textEditing = false;
                return consumed();
            case Command.inputBackspace:
                if (textBuf.length)
                {
                    // Pop one code point, not one byte.
                    size_t cut = textBuf.length - 1;
                    while (cut > 0 && (textBuf[cut] & 0xC0) == 0x80)
                        cut--;
                    textBuf = textBuf[0 .. cut];
                }
                return consumed();
            default:
                if (k.key == Key.char_ && k.ch >= ' ')
                    textBuf ~= text(k.ch);
                return consumed();
        }
    }

    // ── the save ────────────────────────────────────────────────────────────

    /// `s` / Ctrl-S: a pending drag commits first, then the draft persists.
    private SettingsResult save()
    {
        if (previewing)
        {
            cast(void) finishPending(*subject, edits, tree.policy);
            previewing = false;
            refresh();
        }
        if (doSave is null)
        {
            status = "no save target wired";
            return consumed();
        }
        const failure = doSave(fileDraft, touched);
        if (failure.length)
        {
            status = failure;
            return consumed();
        }
        savedDraft = fileDraft;
        status = "saved";
        return SettingsResult(SettingsResult.Kind.saved);
    }

    // ── the view ────────────────────────────────────────────────────────────

    /// ditto
    WidgetTree buildView(SettingsGeometry g)
    {
        Builder b;

        uint[] body_;

        // The filter line.
        {
            TextSpan[] spans;
            if (tv.searching || tv.filterQuery.length)
            {
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
                    spans ~= TextSpan(text: text("  ", tree.matchCount,
                        " matches"), slot: Slot.info);
                    if (tree.omittedMatches)
                        spans ~= TextSpan(text: text("  ",
                            tree.omittedMatches, " omitted"), slot: Slot.muted);
                    if (tree.searchIncomplete)
                        spans ~= TextSpan(text: "  incomplete",
                            slot: Slot.warn);
                }
            }
            else
                spans ~= TextSpan(text: "/ filter · Enter edit · +/- step " ~
                    "· u undo · s save · Esc close", slot: Slot.muted);
            body_ ~= b.add(Widget(kind: WidgetKind.rich, spans: spans,
                width: SizeSpec.grow()));
        }

        // The tree body, clipped inside the frame.
        auto opt = PropertyViewOptions(
            valueColumn: g.panelCols > 60 ? 30 : 20,
            rangeBarCells: g.panelCols > 50 ? 8 : 4,
            needsEditorMarker: "⏎ edit",
        );
        // The framed tree (rows + the machine-driven animated bar) carries
        // its own fixed size now; the keyed wrapper is what pointer routing
        // finds its origin by.
        const treeCol = propertyView(b, tree.data, tv, edits, opt, hitBase);
        body_ ~= b.add(Widget(kind: WidgetKind.column, children: [treeCol],
            key: settingsTreeKey, width: SizeSpec.grow(),
            height: SizeSpec.grow()));

        // The line editor, while open.
        if (textEditing)
            body_ ~= b.add(Widget(kind: WidgetKind.rich, spans: [
                TextSpan(text: textPath, slot: Slot.chromeAccent),
                TextSpan(text: ": ", slot: Slot.muted),
                TextSpan(text: textBuf.idup, slot: Slot.code),
                TextSpan(text: "▏", slot: Slot.caret),
            ], width: SizeSpec.grow()));

        // The footer: history depth, shadow warning, status.
        {
            TextSpan[] spans;
            spans ~= TextSpan(text: text("undo ", edits.undo.length,
                " · redo ", edits.redo.length), slot: Slot.muted);
            if (previewing)
                spans ~= TextSpan(text: "  preview", slot: Slot.chromeAccent);
            if (const n = selectedNode())
            {
                const r = edits.refusalFor(n.path);
                if (r.refused)
                    spans ~= TextSpan(text: text("  ✗ ", r.kind),
                        slot: Slot.error);
                if (originOf !is null && n.path.length)
                {
                    const org = originOf(n.path);
                    if (org.length)
                        spans ~= TextSpan(text: text("  ⚑ ", org,
                            " overrides this at next launch"),
                            slot: Slot.warn);
                }
            }
            if (status.length)
                spans ~= TextSpan(text: text("  ", status), slot: Slot.info);
            body_ ~= b.add(Widget(kind: WidgetKind.rich, spans: spans,
                width: SizeSpec.grow()));
        }

        // The framed panel with the title on the border (the picker's look).
        const content = b.add(Widget(kind: WidgetKind.column, children: body_,
            width: SizeSpec.grow(), height: SizeSpec.grow(),
            clipX: true, clipY: true));
        const boxed = b.add(Widget(kind: WidgetKind.panel,
            children: [content],
            padding: Insets(1, 2, 1, 2),
            slot: Slot.surface, paintBackground: true,
            decoration: Decoration(borderWidth: Insets.all(2),
                borderStyle: BorderStyle.solid, borderRadius: 6,
                borderSlot: Slot.highlightBorder),
            width: SizeSpec.fixed(g.panelCols),
            height: SizeSpec.fixed(g.panelRows)));
        const titleText = b.add(Widget(kind: WidgetKind.text,
            text: dirty ? " Settings ● " : " Settings ",
            slot: Slot.chromeAccent, textStyle: TextStyle(bold: true)));
        const titleRow = b.add(Widget(kind: WidgetKind.row,
            children: [titleText],
            width: SizeSpec.fixed(g.panelCols), alignX: Alignment.center));
        const root = b.add(Widget(kind: WidgetKind.stack,
            children: [boxed, titleRow],
            width: SizeSpec.fixed(g.panelCols),
            height: SizeSpec.fixed(g.panelRows)));
        return b.finish(root);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests — the component against a fixture subject, keys resolved through
// hue's real keymap (the settings scope), no host and no window.
// ─────────────────────────────────────────────────────────────────────────────

version (unittest)
{
    import sparkles.input.events : Mods;
    import sparkles.ui.property_tree : Doc, Range, readOnly;

    private enum FixMode : ubyte
    {
        alpha,
        beta,
        gamma,
    }

    private struct FixNested
    {
        @Range(0, 10, 1) int depth = 3;
    }

    private struct Fixture
    {
        bool dark = true;
        @Range(6, 72, 1) int size = 18;
        @Doc("blend") @Range(0, 1, 0.1) double opacity = 0.5;
        FixMode mode = FixMode.alpha;
        string name = "start";
        @readOnly int locked = 7;
        FixNested nested;
    }

    private KeyEvent kch(dchar c, Mods m = Mods()) @safe pure nothrow @nogc
        => KeyEvent(Key.char_, c, m);
    private KeyEvent knk(Key k) @safe pure nothrow @nogc => KeyEvent(k, 0);

    /// Puts the selection on the row whose node path is `path`.
    private void selectPath(P)(ref P p, string path)
    {
        foreach (i, ref const r; p.tv.rows)
            if (p.tree.data.nodes[r.node].value.path == path)
            {
                p.tv.sel = cast(long) i;
                p.tv.clamp();
                return;
            }
        assert(false, "no visible row for " ~ path);
    }
}

@("settings_pane.editMirrorsDraftAndDirty")
@system unittest
{
    auto cfg = new Fixture;
    SettingsPaneT!Fixture p;
    p.open(cfg, Fixture.init);
    assert(p.active && !p.dirty);

    // Toggle the bool through the real key path.
    selectPath(p, "dark");
    cast(void) p.handleKey(kch('+'));
    assert(cfg.dark == false, "live-apply: the subject changed");
    assert(p.fileDraft.dark == false, "the commit mirrored into the draft");
    assert(p.dirty);
    assert(p.touched == ["dark"]);

    // Step the ranged int; the @Range step is 1.
    selectPath(p, "size");
    cast(void) p.handleKey(kch('+'));
    assert(cfg.size == 19);
    assert(p.fileDraft.size == 19);

    // Undo follows into the draft — undoing back to the seed clears dirty.
    cast(void) p.handleKey(kch('u'));
    assert(cfg.size == 18 && p.fileDraft.size == 18);
    cast(void) p.handleKey(kch('u'));
    assert(cfg.dark == true && p.fileDraft.dark == true);
    assert(!p.dirty, "undone to the saved seed");

    // Redo replays and re-dirties.
    cast(void) p.handleKey(kch('u', Mods(shift: true)));
    assert(cfg.dark == false && p.dirty);
}

@("settings_pane.refusalAndEnumAndModal")
@system unittest
{
    auto cfg = new Fixture;
    SettingsPaneT!Fixture p;
    p.open(cfg, Fixture.init);

    // @readOnly refuses inline; nothing changes, nothing touched.
    selectPath(p, "locked");
    cast(void) p.handleKey(kch('+'));
    assert(cfg.locked == 7);
    assert(p.edits.refusalFor("locked").refused);
    assert(p.touched.length == 0);

    // Enter cycles an enum exactly like `+`.
    selectPath(p, "mode");
    cast(void) p.handleKey(knk(Key.enter));
    assert(cfg.mode == FixMode.beta);
    cast(void) p.handleKey(kch('-'));
    assert(cfg.mode == FixMode.alpha);

    // A modal surface swallows unbound keys; the subject is untouched.
    const before = *cfg;
    const r = p.handleKey(kch('!'));
    assert(r.kind == SettingsResult.Kind.consumed);
    assert(*cfg == before);

    // Escape closes; runtime state (the enum cycle above) is kept.
    const closed = p.handleKey(knk(Key.escape));
    assert(closed.kind == SettingsResult.Kind.closed && !p.active);
    assert(cfg.mode == FixMode.alpha);
}

@("settings_pane.textEditorFlow")
@system unittest
{
    auto cfg = new Fixture;
    SettingsPaneT!Fixture p;
    p.open(cfg, Fixture.init);

    // Enter on a string leaf opens the line editor seeded with the value.
    selectPath(p, "name");
    cast(void) p.handleKey(knk(Key.enter));
    assert(p.textEditing && p.textPath == "name" && p.textBuf == "start");
    assert(p.keyContext().mode == InputMode.settingsText);

    // Typed printables append; Backspace pops a code point; letters that
    // are commands at rest (j, u, s) are text here.
    cast(void) p.handleKey(kch('-'));
    cast(void) p.handleKey(kch('j'));
    cast(void) p.handleKey(knk(Key.backspace));
    cast(void) p.handleKey(kch('u'));
    cast(void) p.handleKey(kch('s'));
    assert(p.textBuf == "start-us", p.textBuf);

    // Enter commits through the validated dispatch: subject, draft, history.
    cast(void) p.handleKey(knk(Key.enter));
    assert(!p.textEditing);
    assert(cfg.name == "start-us");
    assert(p.fileDraft.name == "start-us");
    assert(p.edits.undo.length == 1);

    // Escape cancels without a write.
    cast(void) p.handleKey(knk(Key.enter));
    cast(void) p.handleKey(kch('x'));
    cast(void) p.handleKey(knk(Key.escape));
    assert(!p.textEditing && cfg.name == "start-us");
}

@("settings_pane.saveCapturesTheCfg11Rule")
@system unittest
{
    // The launch situation CFG11 protects: a CLI flag set size=99 (visible
    // in the running config), while the user FILE said 18 — the seed.
    auto cfg = new Fixture;
    cfg.size = 99;
    Fixture fileValue; // size = 18

    SettingsPaneT!Fixture p;
    Fixture savedDraft;
    const(string)[] savedTouched;
    bool saved;
    p.doSave = (ref const Fixture draft, const(string)[] touched) {
        savedDraft = draft;
        savedTouched = touched.dup;
        saved = true;
        return null;
    };
    p.open(cfg, fileValue);

    // The user toggles dark but never touches size.
    selectPath(p, "dark");
    cast(void) p.handleKey(kch('+'));

    const r = p.handleKey(kch('s'));
    assert(r.kind == SettingsResult.Kind.saved && saved);
    assert(savedTouched == ["dark"]);
    assert(savedDraft.dark == false, "the toggled value");
    assert(savedDraft.size == 18,
        "the FILE's value — the CLI's 99 was never baked in");
    assert(!p.dirty && p.status == "saved");

    // A refused save surfaces and keeps dirty. (Not size: stepping from
    // the CLI's out-of-range 99 is itself refused by @Range — correctly.)
    selectPath(p, "opacity");
    cast(void) p.handleKey(kch('+'));
    p.doSave = (ref const Fixture d, const(string)[] t) {
        return "config.json carries comments hue would destroy";
    };
    const r2 = p.handleKey(kch('s'));
    assert(r2.kind == SettingsResult.Kind.consumed);
    assert(p.dirty && p.status.length && p.status != "saved");
}

@("settings_pane.applyMaskAndPreview")
@system unittest
{
    auto cfg = new Fixture;
    SettingsPaneT!Fixture p;
    p.applyRules = [
        ApplyRule("dark", ApplyMask.theme),
        ApplyRule("nested.", ApplyMask.layout),
    ];
    p.open(cfg, Fixture.init);

    selectPath(p, "dark");
    assert(p.handleKey(kch('+')).apply == ApplyMask.theme);
    selectPath(p, "size");
    assert(p.handleKey(kch('+')).apply == ApplyMask.none);

    // A preview drag: mutations live, ONE history entry and ONE apply on
    // the commit boundary (PRT19).
    selectPath(p, "opacity");
    cast(void) p.handleKey(kch('v'));
    assert(p.previewing);
    cast(void) p.handleKey(kch('+'));
    cast(void) p.handleKey(kch('+'));
    assert(cfg.opacity > 0.65 && cfg.opacity < 0.75, "previews mutate live");
    const undoBefore = p.edits.undo.length;
    cast(void) p.handleKey(kch('v'));
    assert(!p.previewing);
    assert(p.edits.undo.length == undoBefore + 1, "one entry per drag");
    assert(p.fileDraft.opacity == cfg.opacity, "the drag reached the draft");
}

@("settings_pane.filterFlowAndGolden")
@system unittest
{
    import std.algorithm.searching : canFind;
    import sparkles.ui.components.property_view : propertyText;

    auto cfg = new Fixture;
    SettingsPaneT!Fixture p;
    p.open(cfg, Fixture.init);

    // `/` opens the filter; typed keys are the query; Down still navigates.
    cast(void) p.handleKey(kch('/'));
    assert(p.tv.searching);
    cast(void) p.handleKey(kch('o'));
    cast(void) p.handleKey(kch('p'));
    cast(void) p.handleKey(kch('a'));
    assert(p.tv.filterQuery == "opa");
    assert(p.tree.searching && p.tree.matchCount >= 1);
    cast(void) p.handleKey(knk(Key.down));

    // Escape restores the base projection.
    cast(void) p.handleKey(knk(Key.escape));
    assert(!p.tv.searching);

    // The plain-text twin renders the same rows both canvases paint — the
    // affordances the pane relies on are visible in it.
    const textView = propertyText(p.tree.data, p.tv.rows, p.tv, p.edits);
    assert(textView.canFind("dark"), textView);
    assert(textView.canFind("[x]") || textView.canFind("[ ]"), textView);
    assert(textView.canFind("⏎ edit") || textView.canFind("needs EDT")
        || textView.canFind("start-us") || textView.canFind("start"),
        textView);
}

@("settings_pane.scrollMachineRoutesTheOverlay")
@system unittest
{
    import core.time : msecs;
    import sparkles.ui.widget : WidgetKind;

    auto cfg = new Fixture;
    SettingsPaneT!Fixture p;
    p.open(cfg, Fixture.init);
    const g = SettingsGeometry(60, 12); // a short pane: the bar is live
    p.resize(g);
    // Open the nested section so the rows outgrow the window.
    selectPath(p, "nested");
    cast(void) p.handleKey(knk(Key.right));
    assert(p.tv.rows.length > p.tv.bodyRows, "content outgrows the window");

    // The built view carries the semantic scrollbar leaf — the same
    // machine-driven bar every tree view paints.
    auto view = p.buildView(g);
    bool sawBar;
    foreach (ref const n; view.nodes)
        sawBar |= n.kind == WidgetKind.scrollbar;
    assert(sawBar);

    // A wheel notch scrolls the viewport and leaves the cursor behind.
    p.tv.selHome();
    p.tv.clamp();
    const selBefore = p.tv.sel;
    WheelEvent w;
    w.dy = 1;
    cast(void) p.handleOverlay(Event(w), g);
    assert(p.tv.top > 0, "a notch scrolls (3 rows, clamped)");
    assert(p.tv.sel == selBefore, "…and leaves the cursor behind");
    p.tv.selHome();
    p.tv.clamp(); // re-couple: the later halves assert against row 0

    // A press on the bar's gutter is a grab, never a row click: the frame
    // routes it to the machine, the selection stays, and the drag scrolls.
    auto frames = layout(view, Constraints(maxW: g.panelCols));
    const area = SettingsPaneT!Fixture.treeArea(view, frames);
    const fr = p.tv.scrollFrame();
    const barX = area.x + fr.vTrack.x;
    PointerEvent press;
    press.action = PointerAction.press;
    press.button = PointerButton.left;
    press.pos = Point(barX, area.y + fr.vTrack.y);
    cast(void) p.handleOverlay(Event(press), g);
    assert(p.tv.sel == 0, "a bar press never selects a row");
    assert(p.tv.sb.dragging || p.tv.sb.hovered, "the machine owns the bar");
    PointerEvent release = press;
    release.action = PointerAction.release;
    cast(void) p.handleOverlay(Event(release), g);

    // The easing advances through the host tick — the animation the hue
    // explorer's bars run on.
    PointerEvent hover;
    hover.action = PointerAction.move;
    hover.pos = Point(barX, area.y + fr.vTrack.y + 1);
    cast(void) p.handleOverlay(Event(hover), g);
    const pctBefore = p.tv.scroll.vAnim.percent;
    p.tickAnims(50.msecs);
    assert(p.tv.scroll.vAnim.percent >= pctBefore,
        "the hover-expand easing ticks");

    // Over the bar the machine wants ns-resize — the pane claims it, and the
    // frame's one composition takes the claim, like every other bar.
    assert(p.shapeClaim() == PointerShape.nsResize);
    PointerEvent away = hover;
    away.pos = Point(area.x + 2, area.y + 2);
    cast(void) p.handleOverlay(Event(away), g);
    assert(p.shapeClaim() == PointerShape.default_,
        "off the bar the shape returns to default");

    // A press on a row selects it; pressing the selected row activates.
    PointerEvent rowPress = press;
    rowPress.pos = Point(area.x + fr.content.x + 1, area.y + fr.content.y);
    cast(void) p.handleOverlay(Event(rowPress), g);
    assert(p.tv.sel == p.tv.top, "the pressed row is selected");
}
