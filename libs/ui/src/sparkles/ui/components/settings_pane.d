/**
The modal settings pane: a $(REF PropertyTree, sparkles,ui,property_tree) over
an application's running configuration, with live-apply editing, a sparse
save and per-leaf provenance — one component every app mounts (terminal
`TSP1`, lifted from hue's `SET1`–`SET8`).

$(B Generic over the subject and the keys.) The component knows no config
paths and no command enum. Keys resolve through `resolveKey`, a template
argument the host supplies — hue binds it to its own configurable keymap, a
host with none takes $(LREF defaultSettingsCommand) over
$(LREF defaultSettingsBindings) — and the live-apply obligations come back as
the host's own bit mask, looked up in the longest-prefix $(LREF ApplyRule)
table the host hands in. Everything else (selection, the fuzzy filter, the
edit dispatch, undo/redo, preview drags, the string line editor) is the
component's, so every host behaves the same.

$(B Live-apply + a file draft.) Every committed edit mutates the running
subject at once through the property tree's generated dispatch (validated,
refusable, undoable — `PropertyEditState` is the history), and is mirrored
into `fileDraft`: the value seeded from every layer $(I below) the config file
and the file itself, never from the layers above it (environment, command
line). Only the paths the user touched are ever persisted, so a value a
higher layer supplied but the user never touched cannot leak into the file
(hue `CFG11`, terminal `TSP3`).

$(B One process, one owner per array.) `open` gives the subject and both
drafts their own copies of every array, so an in-place element edit can never
write through into a value another layer — or the schema's `.init` — still
shares.
*/
module sparkles.ui.components.settings_pane;

import std.conv : text;
import std.traits : isDynamicArray, isSomeString, isStaticArray;

import core.time : Duration;

import sparkles.base.term_control : PointerShape;

import sparkles.input.capability : InputCapabilities, mousePointer;
import sparkles.input.events : Event, Key, KeyEvent, Point, PointerEvent,
    WheelEvent;
import std.sumtype : match;

import sparkles.ui.components.property_view : propertyView,
    PropertyViewOptions;
import sparkles.ui.components.tree_view : treeActivate = activate,
    treeCollapseOrUp = collapseOrUp, TreeStep, TreeViewState;
import sparkles.ui.geometry : Constraints, Insets, Rect, SizeSpec;
import sparkles.ui.keymap : Binding, bind, chord, Chord, commandFor,
    hidesLaterScopes, ShiftReq, terminalScope;
import sparkles.ui.layout : Frame, layout;
import sparkles.ui.state : CaptureState;
import sparkles.ui.property_tree : applyEdit, Edit, EditPhase, editProperty,
    EditValue, finishPending, LeafKind, PropertyEditState, PropertyNode,
    PropertyTree, readValueAt, redoProperty, undoProperty;
import sparkles.ui.style : BorderStyle, Decoration, Slot, TextStyle;
import sparkles.ui.widget : Alignment, Builder, TextSpan, Widget, WidgetKind,
    WidgetTree;

// ─────────────────────────────────────────────────────────────────────────────
// The key vocabulary.
// ─────────────────────────────────────────────────────────────────────────────

/**
What a key does in the pane. A host's `resolveKey` maps its own key table
onto these; `none` (the `init`) is "not bound", which a modal surface spends.
*/
enum SettingsCommand : ubyte
{
    none,      ///
    close,     /// `Esc` / `q` / Back — close, keeping the runtime state
    down,      ///
    up,        ///
    pageDown,  ///
    pageUp,    ///
    home,      ///
    end,       ///
    expand,    ///
    collapse,  ///
    activate,  /// Enter — descend, toggle a bool, cycle an enum, edit a string
    inc,       /// `+` — step the selected leaf up
    dec,       /// `-` — step it down
    preview,   /// `v` — a preview drag, one undo entry at its commit
    undo,      ///
    redo,      ///
    filter,    /// `/` — the fuzzy filter
    matchNext, ///
    matchPrev, ///
    reveal,    /// reveal the current match in the unfiltered tree
    openAll,   ///
    closeAll,  ///
    reset,     /// the selected leaf back to its compiled default
    save,      /// persist the file draft
    textAccept,    /// the line editor: commit the text
    textCancel,    /// the line editor: discard it
    textBackspace, /// the line editor: erase one code point
}

/// The default table's scopes: the line editor, while open, owns the
/// keyboard; otherwise the pane does. Both are terminal (the pane is modal).
enum SettingsScope : ubyte
{
    @terminalScope @hidesLaterScopes text, ///
    @terminalScope @hidesLaterScopes pane, ///
}

/// The default table's context: which of the two scopes is live.
struct SettingsKeyContext
{
    bool textEditing; ///

    /// ditto
    bool reachable(SettingsScope s) const @safe pure nothrow @nogc
        => (s == SettingsScope.text) == textEditing;
}

/// The default binding table — hue's settings keys, for a host with no
/// keymap of its own. Data, so a key guide can list it.
immutable Binding!(SettingsCommand, SettingsScope)[] defaultSettingsBindings = [
    bind(SettingsScope.text, chord(Key.enter), SettingsCommand.textAccept, "accept"),
    bind(SettingsScope.text, chord(Key.escape), SettingsCommand.textCancel, "cancel"),
    bind(SettingsScope.text, chord(Key.back), SettingsCommand.textCancel, "cancel"),
    bind(SettingsScope.text, chord(Key.backspace), SettingsCommand.textBackspace, "erase"),

    bind(SettingsScope.pane, chord(Key.down), SettingsCommand.down, "down"),
    bind(SettingsScope.pane, chord('j'), SettingsCommand.down, "down"),
    bind(SettingsScope.pane, chord(Key.up), SettingsCommand.up, "up"),
    bind(SettingsScope.pane, chord('k'), SettingsCommand.up, "up"),
    bind(SettingsScope.pane, chord(Key.pageDown), SettingsCommand.pageDown, "page down"),
    bind(SettingsScope.pane, chord(Key.pageUp), SettingsCommand.pageUp, "page up"),
    bind(SettingsScope.pane, chord(Key.home), SettingsCommand.home, "first row"),
    bind(SettingsScope.pane, chord('g', ShiftReq.no), SettingsCommand.home, "first row"),
    bind(SettingsScope.pane, chord(Key.end), SettingsCommand.end, "last row"),
    bind(SettingsScope.pane, chord('g', ShiftReq.yes), SettingsCommand.end, "last row"),
    bind(SettingsScope.pane, chord(Key.right), SettingsCommand.expand, "expand"),
    bind(SettingsScope.pane, chord('l'), SettingsCommand.expand, "expand"),
    bind(SettingsScope.pane, chord(Key.left), SettingsCommand.collapse, "collapse"),
    bind(SettingsScope.pane, chord('h'), SettingsCommand.collapse, "collapse"),
    bind(SettingsScope.pane, chord(Key.enter), SettingsCommand.activate, "edit"),
    bind(SettingsScope.pane, chord('+'), SettingsCommand.inc, "increase"),
    bind(SettingsScope.pane, chord('='), SettingsCommand.inc, "increase"),
    bind(SettingsScope.pane, chord('-'), SettingsCommand.dec, "decrease"),
    bind(SettingsScope.pane, chord('v'), SettingsCommand.preview, "preview drag"),
    bind(SettingsScope.pane, chord('u', ShiftReq.no), SettingsCommand.undo, "undo"),
    bind(SettingsScope.pane, chord('u', ShiftReq.yes), SettingsCommand.redo, "redo"),
    bind(SettingsScope.pane, chord('/'), SettingsCommand.filter, "filter"),
    bind(SettingsScope.pane, chord('n', ShiftReq.no), SettingsCommand.matchNext, "next match"),
    bind(SettingsScope.pane, chord('n', ShiftReq.yes), SettingsCommand.matchPrev, "previous match"),
    bind(SettingsScope.pane, chord('b'), SettingsCommand.reveal, "reveal match"),
    bind(SettingsScope.pane, chord('o', ShiftReq.yes), SettingsCommand.openAll, "open all"),
    bind(SettingsScope.pane, chord('c', ShiftReq.yes), SettingsCommand.closeAll, "close all"),
    bind(SettingsScope.pane, chord('r'), SettingsCommand.reset, "reset to default"),
    bind(SettingsScope.pane, chord('s', ShiftReq.no), SettingsCommand.save, "save"),
    bind(SettingsScope.pane, Chord(key: Key.char_, ch: 's', ctrl: true),
        SettingsCommand.save, "save"),
    bind(SettingsScope.pane, chord(Key.escape), SettingsCommand.close, "close"),
    bind(SettingsScope.pane, chord('q'), SettingsCommand.close, "close"),
    bind(SettingsScope.pane, chord(Key.back), SettingsCommand.close, "close"),
];

/// Resolves `k` through $(LREF defaultSettingsBindings) — the `resolveKey`
/// a host with no keymap of its own mounts the pane with.
SettingsCommand defaultSettingsCommand(in KeyEvent k, bool textEditing) @safe
    => commandFor(defaultSettingsBindings, k,
        SettingsKeyContext(textEditing)).cmd;

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

    Kind kind; ///

    /// The host's live-apply bits for a committed edit — whatever its
    /// $(LREF ApplyRule) table says the edited path obliges it to do now
    /// (re-resolve a theme, reload a font, re-arrange a dock).
    uint apply;
}

/// One live-apply rule: the longest matching prefix's mask is returned from
/// a committed edit. The host supplies the table (the component knows no
/// config paths); the bits are the host's own vocabulary.
struct ApplyRule
{
    string prefix; ///
    uint mask;     ///
}

/// Frame-stable overlay geometry, from the screen size alone: selection,
/// filtering and editing never move a border.
struct SettingsGeometry
{
    int panelCols = 72; ///
    int panelRows = 24; ///
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

///
@("ui.settings_pane.settingsGeometryFor.clampsBothWays")
@safe pure nothrow @nogc
unittest
{
    assert(settingsGeometryFor(200, 80) == SettingsGeometry(96, 30));
    assert(settingsGeometryFor(80, 24) == SettingsGeometry(72, 20));
    assert(settingsGeometryFor(30, 6) == SettingsGeometry(44, 10));
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

/**
The pane over a subject `T`, with keys resolved by `resolveKey(KeyEvent,
bool textEditing)` returning a $(LREF SettingsCommand).
*/
struct SettingsPane(T, alias resolveKey = defaultSettingsCommand)
{
    // The property-tree bundle (subject by pointer: the config outlives the
    // pane and `editProperty` takes `ref`).
    T* subject;                  ///
    PropertyTree!T tree;         ///
    TreeViewState!string tv;     ///
    PropertyEditState edits;     ///
    bool previewing;             /// a `v` preview session is live (`PRT19`)
    bool active;                 ///

    // Persistence (the CFG11 rule, structurally).
    T fileDraft;                 /// the file seed + this session's commits
    T savedDraft;                /// at open / last save; `dirty` compares
    string[] touched;            /// paths committed this session
    /// The save seam: returns `null` on success, a rendered refusal
    /// otherwise (the host's sparse writer behind an adapter).
    string delegate(ref const T draft, const(string)[] touched) doSave;
    /// Optional provenance lookup: non-empty for a path whose effective
    /// value came from a layer above the file — the shadow warning.
    string delegate(string path) @safe originOf;

    ApplyRule[] applyRules;      ///

    // The string-leaf line editor (owns the keys while open).
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

    /**
    Opens over the shared config. `fileValue` seeds the save draft: every
    layer up to and including the file, none above it. The subject and the
    drafts each get their own arrays (see the module header).
    */
    void open(T* cfg, T fileValue, SettingsGeometry g = SettingsGeometry())
    {
        subject = cfg;
        *subject = ownedCopy(*subject);
        fileDraft = ownedCopy(fileValue);
        savedDraft = ownedCopy(fileValue);
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

    /// Rebuild rows from the subject, pinning a pending edit's path.
    void refresh() @safe
    {
        tree.rebuild(*subject, tv,
            edits.pendingActive ? edits.pendingPath : null);
    }

    /// Advances the scrollbar hover-expand easings; hosts call it once per
    /// frame while the pane is open.
    void tickAnims(Duration elapsed) @safe pure nothrow @nogc
    {
        tv.tick(caps, cast(float) elapsed.total!"hnsecs" / 10_000_000.0f);
    }

    /// The pointer shape the bar machine wants — ns-resize while hovering
    /// or grabbing the bar, default elsewhere.
    PointerShape pointerShape() const @safe pure nothrow @nogc
        => tv.scroll.shape();

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

        // 3. Command dispatch; a modal surface swallows what it does not bind.
        final switch (resolveKey(k, false))
        {
            case SettingsCommand.close:
                close();
                return SettingsResult(SettingsResult.Kind.closed);
            case SettingsCommand.down:
                tv.moveSel(1);
                return consumed();
            case SettingsCommand.up:
                tv.moveSel(-1);
                return consumed();
            case SettingsCommand.pageDown:
                tv.moveSel(tv.height > 2 ? tv.height - 2 : 1);
                return consumed();
            case SettingsCommand.pageUp:
                tv.moveSel(-(tv.height > 2 ? tv.height - 2 : 1));
                return consumed();
            case SettingsCommand.home:
                tv.selHome();
                return consumed();
            case SettingsCommand.end:
                tv.selEnd();
                return consumed();
            case SettingsCommand.expand:
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
            case SettingsCommand.collapse:
                return collapseSel();
            case SettingsCommand.activate:
                return activateSel();
            case SettingsCommand.inc:
                return stepEdit(1);
            case SettingsCommand.dec:
                return stepEdit(-1);
            case SettingsCommand.preview:
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
            case SettingsCommand.undo:
            {
                const a = undoProperty(*subject, edits, tree.policy);
                return a.ok ? committed(a.inverse.path) : consumedRefresh();
            }
            case SettingsCommand.redo:
            {
                const a = redoProperty(*subject, edits, tree.policy);
                return a.ok ? committed(a.inverse.path) : consumedRefresh();
            }
            case SettingsCommand.filter:
                tv.filterStart();
                refresh();
                return consumed();
            case SettingsCommand.matchNext:
                tree.jumpMatch(tv, 1);
                return consumed();
            case SettingsCommand.matchPrev:
                tree.jumpMatch(tv, -1);
                return consumed();
            case SettingsCommand.reveal:
                if (tree.searching)
                {
                    tree.revealInBase(*subject, tv);
                    refresh();
                }
                return consumed();
            case SettingsCommand.openAll:
                tv.open = typeof(tv.open).allOpen;
                refresh();
                return consumed();
            case SettingsCommand.closeAll:
                tv.open = typeof(tv.open).allClosed;
                refresh();
                return consumed();
            case SettingsCommand.reset:
                return resetSel();
            case SettingsCommand.save:
                return save();
            case SettingsCommand.none:
            case SettingsCommand.textAccept:
            case SettingsCommand.textCancel:
            case SettingsCommand.textBackspace:
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
    static Rect treeArea(in WidgetTree view,
        scope const(Frame)[] frames) @safe pure nothrow @nogc
    {
        foreach (i, ref const node; view.nodes)
            if (node.key == settingsTreeKey && i < frames.length)
                return frames[i].rect;
        return Rect.init;
    }

    // ── the edit engine ─────────────────────────────────────────────────────

    /// The node under the cursor, or `null`.
    const(PropertyNode)* selectedNode() @safe
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
                if (n.choices.length == 0)
                    return consumed();
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

    private uint applyFor(string path) @safe pure nothrow @nogc
    {
        import std.algorithm.searching : startsWith;

        uint best;
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
        switch (resolveKey(k, true))
        {
            case SettingsCommand.textAccept:
            {
                textEditing = false;
                const a = editProperty(*subject,
                    Edit(textPath, EditValue.ofText(textBuf),
                        EditPhase.commit), edits, tree.policy);
                return a.ok ? committed(textPath) : consumedRefresh();
            }
            case SettingsCommand.textCancel:
                textEditing = false;
                return consumed();
            case SettingsCommand.textBackspace:
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
        savedDraft = ownedCopy(fileDraft);
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
        // its own fixed size; the keyed wrapper is what pointer routing finds
        // its origin by.
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

/**
`v` with every array it reaches duplicated (recursively), so the result shares
no mutable element storage with `v` — what lets an in-place element edit on
one copy stay out of every other. Strings are immutable and kept; associative
arrays, pointers and classes are kept (the tree never edits through them).
*/
T ownedCopy(T)(T v)
{
    static if (isSomeString!T)
        return v;
    else static if (isDynamicArray!T)
    {
        static if (is(typeof(v[0]) == immutable))
            return v;
        else
        {
            auto r = v.dup;
            foreach (ref e; r)
                e = ownedCopy(e);
            return r;
        }
    }
    else static if (isStaticArray!T)
    {
        foreach (ref e; v)
            e = ownedCopy(e);
        return v;
    }
    else static if (is(T == struct))
    {
        foreach (ref f; v.tupleof)
            static if (__traits(compiles, f = ownedCopy(f)))
                f = ownedCopy(f);
        return v;
    }
    else
        return v;
}

///
@("ui.settings_pane.ownedCopy.sharesNoArrayStorage")
@safe pure nothrow unittest
{
    static struct Inner { string[] list; }
    static struct Outer { Inner inner; int[] numbers; string name; }

    Outer a = Outer(Inner(["x", "y"]), [1, 2], "n");
    auto b = ownedCopy(a);
    assert(b == a);
    b.inner.list[0] = "changed";
    b.numbers[1] = 9;
    assert(a.inner.list[0] == "x" && a.numbers[1] == 2,
        "an element edit on the copy stays out of the original");
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests — the component against a fixture subject, keys resolved through the
// default table, no host and no window. (Fixtures sit under the library's
// fixture version, not `unittest`: a consumer's `-unittest` build analyses
// this module too.)
// ─────────────────────────────────────────────────────────────────────────────

version (UiSettingsFixtures)
{
    import sparkles.input.events : Mods, PointerAction, PointerButton;
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
        string[] list = ["one", "two"];
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

version (UiSettingsFixtures)
@("ui.settings_pane.defaultSettingsCommand.textScopeOwnsTheKeys")
@safe unittest
{
    assert(defaultSettingsCommand(kch('j'), false) == SettingsCommand.down);
    assert(defaultSettingsCommand(kch('j'), true) == SettingsCommand.none,
        "a letter is text while the line editor is open");
    assert(defaultSettingsCommand(knk(Key.escape), false) == SettingsCommand.close);
    assert(defaultSettingsCommand(knk(Key.escape), true) == SettingsCommand.textCancel);
    assert(defaultSettingsCommand(kch('u', Mods(shift: true)), false)
        == SettingsCommand.redo);
}

version (UiSettingsFixtures)
@("ui.settings_pane.editMirrorsDraftAndDirty")
@system unittest
{
    auto cfg = new Fixture;
    SettingsPane!Fixture p;
    p.open(cfg, Fixture.init);
    assert(p.active && !p.dirty);

    selectPath(p, "dark");
    cast(void) p.handleKey(kch('+'));
    assert(cfg.dark == false, "live-apply: the subject changed");
    assert(p.fileDraft.dark == false, "the commit mirrored into the draft");
    assert(p.dirty);
    assert(p.touched == ["dark"]);

    selectPath(p, "size");
    cast(void) p.handleKey(kch('+'));
    assert(cfg.size == 19 && p.fileDraft.size == 19);

    // Undo follows into the draft — undoing back to the seed clears dirty.
    cast(void) p.handleKey(kch('u'));
    cast(void) p.handleKey(kch('u'));
    assert(cfg.dark && cfg.size == 18 && !p.dirty);

    cast(void) p.handleKey(kch('u', Mods(shift: true)));
    assert(cfg.dark == false && p.dirty);
}

version (UiSettingsFixtures)
@("ui.settings_pane.refusalEnumAndModal")
@system unittest
{
    auto cfg = new Fixture;
    SettingsPane!Fixture p;
    p.open(cfg, Fixture.init);

    selectPath(p, "locked");
    cast(void) p.handleKey(kch('+'));
    assert(cfg.locked == 7 && p.edits.refusalFor("locked").refused);
    assert(p.touched.length == 0);

    selectPath(p, "mode");
    cast(void) p.handleKey(knk(Key.enter));
    assert(cfg.mode == FixMode.beta);
    cast(void) p.handleKey(kch('-'));
    assert(cfg.mode == FixMode.alpha);

    const before = *cfg;
    assert(p.handleKey(kch('!')).kind == SettingsResult.Kind.consumed);
    assert(*cfg == before, "a modal surface spends an unbound key");

    assert(p.handleKey(knk(Key.escape)).kind == SettingsResult.Kind.closed);
    assert(!p.active);
}

version (UiSettingsFixtures)
@("ui.settings_pane.textEditorFlow")
@system unittest
{
    auto cfg = new Fixture;
    SettingsPane!Fixture p;
    p.open(cfg, Fixture.init);

    selectPath(p, "name");
    cast(void) p.handleKey(knk(Key.enter));
    assert(p.textEditing && p.textBuf == "start");
    foreach (c; "-j")
        cast(void) p.handleKey(kch(c));
    cast(void) p.handleKey(knk(Key.backspace));
    foreach (c; "us")
        cast(void) p.handleKey(kch(c));
    assert(p.textBuf == "start-us", p.textBuf);
    cast(void) p.handleKey(knk(Key.enter));
    assert(!p.textEditing && cfg.name == "start-us" && p.fileDraft.name == "start-us");

    cast(void) p.handleKey(knk(Key.enter));
    cast(void) p.handleKey(kch('x'));
    cast(void) p.handleKey(knk(Key.escape));
    assert(!p.textEditing && cfg.name == "start-us");
}

version (UiSettingsFixtures)
@("ui.settings_pane.arrayElementEditsStayInTheirOwner")
@system unittest
{
    // The edit writes an element in place; without `ownedCopy` at open it
    // would land in the seed and the schema's `.init` alike.
    auto cfg = new Fixture;
    Fixture seed;
    SettingsPane!Fixture p;
    p.open(cfg, seed);

    selectPath(p, "list");
    cast(void) p.handleKey(knk(Key.right));
    selectPath(p, "list[0]");
    cast(void) p.handleKey(knk(Key.enter));
    cast(void) p.handleKey(kch('!'));
    cast(void) p.handleKey(knk(Key.enter));

    assert(cfg.list[0] == "one!" && p.fileDraft.list[0] == "one!");
    assert(seed.list[0] == "one" && p.savedDraft.list[0] == "one");
    assert(Fixture.init.list[0] == "one", "the schema's init is untouched");
    assert(p.touched == ["list[0]"]);
}

version (UiSettingsFixtures)
@("ui.settings_pane.applyRulesAndPreview")
@system unittest
{
    enum : uint { theme = 1, layout = 2 }

    auto cfg = new Fixture;
    SettingsPane!Fixture p;
    p.applyRules = [ApplyRule("dark", theme), ApplyRule("nested.", layout)];
    p.open(cfg, Fixture.init);

    selectPath(p, "dark");
    assert(p.handleKey(kch('+')).apply == theme);
    selectPath(p, "size");
    assert(p.handleKey(kch('+')).apply == 0);

    selectPath(p, "opacity");
    cast(void) p.handleKey(kch('v'));
    cast(void) p.handleKey(kch('+'));
    cast(void) p.handleKey(kch('+'));
    assert(cfg.opacity > 0.65 && cfg.opacity < 0.75, "previews mutate live");
    const undoBefore = p.edits.undo.length;
    cast(void) p.handleKey(kch('v'));
    assert(p.edits.undo.length == undoBefore + 1, "one entry per drag");
    assert(p.fileDraft.opacity == cfg.opacity);
}

version (UiSettingsFixtures)
@("ui.settings_pane.scrollMachineRoutesTheOverlay")
@system unittest
{
    auto cfg = new Fixture;
    SettingsPane!Fixture p;
    p.open(cfg, Fixture.init);
    const g = SettingsGeometry(60, 12);
    p.resize(g);
    selectPath(p, "nested");
    cast(void) p.handleKey(knk(Key.right));
    selectPath(p, "list");
    cast(void) p.handleKey(knk(Key.right));
    assert(p.tv.rows.length > p.tv.bodyRows, "content outgrows the window");

    auto view = p.buildView(g);
    bool sawBar;
    foreach (ref const n; view.nodes)
        sawBar |= n.kind == WidgetKind.scrollbar;
    assert(sawBar);

    p.tv.selHome();
    p.tv.clamp();
    WheelEvent w;
    w.dy = 1;
    cast(void) p.handleOverlay(Event(w), g);
    assert(p.tv.top > 0 && p.tv.sel == 0, "a notch scrolls, the cursor stays");
    p.tv.selHome();
    p.tv.clamp();

    auto frames = layout(view, Constraints(maxW: g.panelCols));
    const area = SettingsPane!Fixture.treeArea(view, frames);
    const fr = p.tv.scrollFrame();
    PointerEvent press;
    press.action = PointerAction.press;
    press.button = PointerButton.left;
    press.pos = Point(area.x + fr.vTrack.x, area.y + fr.vTrack.y);
    cast(void) p.handleOverlay(Event(press), g);
    assert(p.tv.sel == 0, "a bar press never selects a row");
}
