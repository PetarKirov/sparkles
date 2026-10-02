/**
The settings page (`TSP5`–`TSP8`, mockups G3 and G4): the shared settings
pane over `TerminalConfig` (`settings_store`), laid out as sections with
inline controls (`sparkles.ui.components.property_sections`) and a keys
section edited by capture (`sparkles.ui.components.chord_capture`).

$(UL
    $(LI $(B Where:) a full-screen page on a touch screen, a modal panel on
    the desktop (`TSP6`); a tap outside the panel closes it.)
    $(LI $(B Order:) every section starts expanded, sections and leaves in
    `TerminalConfig`'s declaration order (`TSP7`); an aggregate or array is a
    drill-in level, and Back (`Esc`, `q`) pops a level before it closes.)
    $(LI $(B Edits) go through the pane's edits by path, so they are
    range-checked, refusable inline, undoable and autosaved (`TSP2`,
    `TSP3`); each commit hands its apply bits to the embedder, which applies
    them to the running panes (`TCF8`). The toast at the bottom names the
    change and offers Undo — the property tree's history.)
    $(LI $(B Keys) (`TSP8`): a row per binding of the merged table; activating
    one captures the new chord (each key in turn for a sequence); a conflict
    offers Swap, Bind both or Cancel; a reserved key is refused with the
    reason; the result is the `keys` overlay (`TKM8`). A binding's undo is
    the overlay before it.)
)

The keyboard: arrows or `j`/`k` move, `←`/`→` (`h`/`l`, `-`/`+`) step or
cycle, Enter acts, `/` filters, `r` resets, `u` undoes; Ctrl, Alt and Super
chords are declined to the table, and so are `Esc`/`q`/Enter outside a text
field (the `Surface` contract).
*/
module settings_page;

import core.time : MonoTime, seconds;

import std.conv : text;

import sparkles.input.events : Key, KeyAction, KeyEvent;
import sparkles.ui.components.chord_capture : CaptureConflict, CaptureHit, CapturePhase,
    CaptureResolution, ChordCapture, chordCaptureView, pathLabel;
import sparkles.ui.components.property_sections : choiceLabel, decodeSectionHit,
    inlineEditorFor, InlineEditor, RowState, sectionHeader, sectionHit, SectionItem,
    sectionItems, SectionPart, sectionRow, SectionsOptions, sectionSummary, sentenceCase,
    naturalCells, unquoted;
import sparkles.ui.components.settings_pane : LeafProvenance, SettingsResult, SettingsToast;
import sparkles.ui.geometry : Constraints, Insets, Point, SizeSpec;
import sparkles.ui.keymap : acceptsTyped, Chord, ShiftReq;
import sparkles.ui.layout : layout;
import sparkles.ui.property_tree : EditValue, LeafKind, PropertyNode;
import sparkles.ui.style : BorderStyle, Decoration, Slot, TextStyle;
import sparkles.ui.widget : Alignment, Builder, TextSpan, Widget, WidgetKind, WidgetTree;

import keymap : Binding, isReserved, KeysConfig, leaderChord, leaderMark, TermCommand,
    TermScope, terminalBindings;
import settings : TerminalConfig;
import settings_store : TerminalApply, TerminalSettingsPane, TerminalSettingsStore;
import surfaces : Placement, Scrollable, Surface, SurfaceContext;

// Hit ids: the page's own, the capture's, the bindings', the property rows'.
private enum size_t hitScrim = 0x5E70_0001, hitPanel = 0x5E70_0002, hitBack = 0x5E70_0003,
    hitFilter = 0x5E70_0004, hitFilterClear = 0x5E70_0005, hitUndo = 0x5E70_0006,
    hitKeysHeader = 0x5E70_0007;
private enum size_t captureBase = 0x5E70_0100;
private enum size_t bindingBase = 0x5E71_0000;
private enum size_t sectionBase = 0x6000_0000;

/// The `keys` field: the page shows the bindings in its place.
private enum keysPath = "keys";

/// One binding of the merged table, as the keys section lists it.
struct BindingRow
{
    TermScope scope_;   ///
    TermCommand cmd;    ///
    Chord[] path;       /// as the table has it, the leader substituted
    string label;       /// what it does ("Split right")
    string defaultPath; /// the command's default chord, for the subtitle
    bool changed;       /// the path is the user's, not the defaults'
}

/**
The bindings the keys section lists: every command row of the pane and the
exit prompt — not prefixes, not the overlays' universal keys (`KBD1`), not
ranged rows (`1`–`9`) — in table order.
*/
BindingRow[] bindingRows(TerminalConfig c, out Chord leader) @safe
{
    import sparkles.ui.components.chord_capture : pathLabelOf = pathLabel;

    string[] ignored;
    leader = leaderChord(c.lantern.leader, ignored);
    const table = terminalBindings(leader, c.keys, ignored);
    const defaults = terminalBindings(leader, KeysConfig.init, ignored);
    BindingRow[] rows;
    foreach (ref b; table)
    {
        if (b.group.length || b.cmd == TermCommand.none)
            continue;
        if (b.scope_ != TermScope.pane && b.scope_ != TermScope.prompt)
            continue;
        bool ranged;
        foreach (i; 0 .. b.depth)
            ranged |= b.path[i].chEnd != 0;
        if (ranged)
            continue;
        BindingRow r = {scope_: b.scope_, cmd: b.cmd, path: b.path[0 .. b.depth].dup,
            label: sentenceCase(b.desc)};
        bool inDefaults;
        foreach (ref d; defaults)
        {
            if (d.group.length || d.scope_ != b.scope_ || d.cmd != b.cmd)
                continue;
            if (samePath(d.path[0 .. d.depth], r.path))
                inDefaults = true;
            if (!r.defaultPath.length)
                r.defaultPath = pathLabelOf(d.path[0 .. d.depth], leader);
        }
        r.changed = !inDefaults;
        rows ~= r;
    }
    return rows;
}

private bool samePath(in Chord[] a, in Chord[] b) @safe pure nothrow @nogc
{
    if (a.length != b.length)
        return false;
    foreach (i; 0 .. a.length)
        if (!acceptsTyped(a[i], b[i]) && !acceptsTyped(b[i], a[i]))
            return false;
    return true;
}

/// `path` in the overlay's wire form: the leader spelled as the placeholder.
private auto wirePath(in Chord[] path, in Chord leader) @safe pure nothrow @nogc
{
    import sparkles.ui.keymap_config : ChordPathOf;

    ChordPathOf!leaderMark p;
    p.depth = cast(ubyte) path.length;
    foreach (i, ref c; path)
        p.path[i] = acceptsTyped(leader, c) ? Chord(key: Key.char_, ch: leaderMark) : c;
    return p;
}

/// A deep copy of an overlay: the page never edits the running value's AAs.
private KeysConfig copyKeys(KeysConfig k) @safe
{
    KeysConfig r;
    foreach (s, inner; k)
        r[s] = inner.dup;
    return r;
}

/**
The overlay that binds `row`'s command to `path` (`TKM8`): `replace` unbinds
the old path, `swap` gives it the command `path` ran, `both` keeps it.
*/
KeysConfig rebind(KeysConfig keys, in BindingRow row, in Chord[] path,
    CaptureResolution how, TermCommand displaced, in Chord leader) @safe
{
    import std.typecons : Nullable, nullable;

    auto r = copyKeys(keys);
    const neu = wirePath(path, leader), old = wirePath(row.path, leader);
    if (neu == old)
        return r;
    if (row.scope_ !in r)
        r[row.scope_] = null;
    const TermCommand cmd = row.cmd;
    r[row.scope_][neu] = nullable(cast() cmd);
    final switch (how)
    {
        case CaptureResolution.replace:
            r[row.scope_][old] = Nullable!TermCommand.init;
            break;
        case CaptureResolution.swap:
            r[row.scope_][old] = nullable(displaced);
            break;
        case CaptureResolution.both:
            break;
    }
    return r;
}

/// The page.
final class SettingsPage : Surface, Scrollable
{
    /// The store the page edits; the embedder applies what it says.
    TerminalSettingsStore* store;
    /// ditto
    TerminalSettingsPane* pane;
    /// A text field took focus on a touch screen: the embedder raises the
    /// soft keyboard and clears it.
    bool wantsKeyboard;
    /// The page left the stack.
    bool closed;

    private void delegate(uint apply) @system applyFn;
    private string[] levels;           // the drill-in path, outermost first
    private bool[string] folded;       // collapsed sections
    private string openDropdown;
    private Item[] items;
    private size_t focus;
    private bool focusMoved;
    private int scrollCells, maxScroll, bodyRows;
    private BindingRow[] bindings;
    private Chord leader;
    private ChordCapture capture;
    private size_t captureRow = size_t.max;
    private KeysConfig[] keysUndo;
    private Toast toast;
    private bool touch;
    private SectionsOptions opts; // the last build's, so a hit reads the row as drawn

    private static struct Item
    {
        enum Kind : ubyte { section, keysHeader, binding }
        Kind kind;
        SectionItem si;
        size_t binding;
    }

    private static struct Toast
    {
        string text;
        bool undo;     // the property tree's
        bool keysUndo; // the overlay before a binding edit
        MonoTime until;
    }

    /// Opens over `store`; `apply` receives every commit's `TerminalApply`
    /// bits once the running value holds it.
    this(TerminalSettingsStore* store, void delegate(uint apply) @system apply) @system
    {
        this.store = store;
        applyFn = apply;
        pane = new TerminalSettingsPane;
        store.mount(*pane);
        // Every section starts expanded (`TSP7`): the whole tree is built.
        pane.tv.open = typeof(pane.tv.open).allOpen;
        pane.refresh();
        bindings = bindingRows(store.resolved, leader);
    }

    // ── Surface ─────────────────────────────────────────────────────────────

    Placement placement() const @safe => Placement.page;

    WidgetTree build(in SurfaceContext ctx, int cols) @trusted
    {
        touch = ctx.touch;
        const rows = ctx.cellH > 0 ? ctx.area.height / ctx.cellH : 24;
        // A phone: the whole area. The desktop: a modal panel (`TSP6`).
        int w = cols, h = rows;
        if (!touch)
        {
            w = cols - 4 < 96 ? cols - 4 : 96;
            if (w < 40)
                w = cols;
            h = rows - 2 > 12 ? rows - 2 : rows;
        }
        if (toast.text.length && MonoTime.currTime > toast.until)
            toast = Toast.init;
        items = buildItems();
        if (focus >= items.length)
            focus = items.length ? items.length - 1 : 0;

        Builder b;
        uint[] itemIds;
        opts = SectionsOptions(targetRows: ctx.targetRows, width: w - 2, touch: touch);
        const opt = opts;
        foreach (i, ref it; items)
            itemIds ~= itemWidget(b, i, it, opt);
        const body_ = b.add(Widget(kind: WidgetKind.column, children: itemIds,
            width: SizeSpec.grow(), height: SizeSpec.grow(), clipX: true, clipY: true));

        uint[] page = [titleBar(b, ctx), filterRow(b, ctx), body_];
        if (!touch)
            page ~= b.add(Widget(kind: WidgetKind.text, slot: Slot.muted,
                text: "↑↓ move · ←→ change · ↵ act · / filter · r reset · u undo · Esc back",
                padding: Insets(0, 1, 0, 1), height: SizeSpec.fixed(1), clipX: true));
        const column_ = b.add(Widget(kind: WidgetKind.column, children: page,
            width: SizeSpec.fixed(w), height: SizeSpec.fixed(h)));
        uint[] layers = [column_];
        if (toast.text.length)
            layers ~= toastLayer(b, w, h, ctx.targetRows);
        const panel = b.add(Widget(kind: WidgetKind.stack, children: layers,
            width: SizeSpec.fixed(w), height: SizeSpec.fixed(h), hitId: hitPanel,
            slot: Slot.surface, paintBackground: true,
            decoration: touch ? Decoration.init : Decoration(borderStyle: BorderStyle.solid,
                borderWidth: Insets.all(1), borderSlot: Slot.border, borderRadius: 6)));
        const root = b.add(Widget(kind: WidgetKind.column, children: [panel],
            width: SizeSpec.fixed(cols), height: SizeSpec.fixed(rows),
            alignX: Alignment.center, alignY: Alignment.center,
            hitId: touch ? 0 : hitScrim));
        auto tree = b.finish(root);

        // Measure unscrolled, keep the focused row in view, then scroll.
        auto frames = layout(tree, Constraints(maxW: cols, maxH: rows));
        const view = frames[body_].rect;
        bodyRows = view.height;
        int contentBottom = view.y;
        foreach (id; itemIds)
            contentBottom = frames[id].rect.y + frames[id].rect.height;
        maxScroll = contentBottom - view.y - view.height;
        if (maxScroll < 0)
            maxScroll = 0;
        if (focusMoved && focus < itemIds.length)
        {
            const r = frames[itemIds[focus]].rect;
            const top = r.y - view.y, bottom = top + r.height;
            if (top < scrollCells)
                scrollCells = top;
            else if (bottom > scrollCells + view.height)
                scrollCells = bottom - view.height;
            focusMoved = false;
        }
        if (scrollCells > maxScroll)
            scrollCells = maxScroll;
        if (scrollCells < 0)
            scrollCells = 0;
        tree.nodes[body_].childOffset = Point(0, scrollCells);
        return tree;
    }

    bool activate(size_t id) @system
    {
        if (id == hitScrim)
            return close();
        if (id == hitPanel)
            return false;
        if (id == hitBack)
        {
            if (levels.length)
                popLevel();
            else
                return close();
            return false;
        }
        if (id == hitFilter)
        {
            if (!pane.tv.searching)
            {
                pane.tv.filterStart();
                pane.refresh();
            }
            wantsKeyboard = touch;
            return false;
        }
        if (id == hitFilterClear)
        {
            if (pane.tv.searching || pane.tv.filterQuery.length)
            {
                pane.tv.filterStart();
                cast(void) pane.tv.filterKey(KeyEvent(Key.escape));
                pane.refresh();
            }
            return false;
        }
        if (id == hitUndo)
        {
            undo();
            return false;
        }
        if (id == hitKeysHeader)
        {
            toggleFold(keysPath);
            return false;
        }
        if (id >= captureBase && id < captureBase + 16)
        {
            captureButton(cast(CaptureHit)(id - captureBase));
            return false;
        }
        if (id >= bindingBase && id < sectionBase)
        {
            const row = (id - bindingBase) / 4;
            focusOnBinding(row);
            startCapture(row);
            return false;
        }
        uint node, part;
        if (decodeSectionHit(sectionBase, id, node, part))
            sectionPart(node, part);
        return false;
    }

    bool confirm() @system
    {
        primary();
        return false;
    }

    void cancel() @system
    {
        cast(void) close();
    }

    bool key(in KeyEvent k) @system
    {
        if (k.action == KeyAction.release)
            return capture.open || pane.textEditing || pane.tv.searching;

        // The capture owns every key, chords and Esc included (`TSP8`).
        if (capture.listening)
        {
            const ph = capture.feed(k, (in Chord c) => reservedReason(c),
                (in Chord[] p) => conflictOf(p));
            settleCapture(ph);
            return true;
        }
        if (capture.phase == CapturePhase.conflict)
        {
            if (k.key == Key.escape || k.key == Key.back)
                captureButton(CaptureHit.cancel);
            else if (k.key == Key.enter)
                captureButton(CaptureHit.swap);
            return true;
        }

        // A text field owns the keys while open.
        if (pane.textEditing)
        {
            if (k.mods.ctrl || k.mods.alt || k.mods.super_)
                return false;
            note(pane.handleKey(k));
            return true;
        }
        if (pane.tv.searching)
        {
            if (k.key == Key.down || k.key == Key.up)
            {
                cast(void) pane.tv.filterKey(KeyEvent(Key.enter));
                return key(k);
            }
            if (k.mods.ctrl || k.mods.alt || k.mods.super_)
                return false;
            if (k.key == Key.back)
                cast(void) pane.tv.filterKey(KeyEvent(Key.escape));
            else
                cast(void) pane.tv.filterKey(k);
            pane.refresh();
            focus = 0;
            scrollCells = 0;
            return true;
        }

        if (k.mods.ctrl || k.mods.alt || k.mods.super_)
            return false;
        switch (k.key)
        {
            case Key.escape:
            case Key.back:
                if (openDropdown.length)
                    openDropdown = null;
                else if (levels.length)
                    popLevel();
                else if (pane.tv.filterQuery.length)
                {
                    pane.tv.filterStart();
                    cast(void) pane.tv.filterKey(KeyEvent(Key.escape));
                    pane.refresh();
                }
                else
                    return false; // closes, through the table
                return true;
            case Key.down:
                moveFocus(1);
                return true;
            case Key.up:
                moveFocus(-1);
                return true;
            case Key.pageDown:
                moveFocus(8);
                return true;
            case Key.pageUp:
                moveFocus(-8);
                return true;
            case Key.home:
                moveFocus(-cast(int) items.length);
                return true;
            case Key.end:
                moveFocus(cast(int) items.length);
                return true;
            case Key.left:
                stepFocused(-1);
                return true;
            case Key.right:
                stepFocused(1);
                return true;
            case Key.char_:
                switch (k.ch)
                {
                    case 'j':
                        moveFocus(1);
                        return true;
                    case 'k':
                        moveFocus(-1);
                        return true;
                    case 'h':
                    case '-':
                        stepFocused(-1);
                        return true;
                    case 'l':
                    case '+':
                    case '=':
                        stepFocused(1);
                        return true;
                    case '/':
                        pane.tv.filterStart();
                        pane.refresh();
                        return true;
                    case 'r':
                        if (auto n = focusedLeaf())
                            note(pane.resetAt(n.path));
                        return true;
                    case 'u':
                        undo();
                        return true;
                    case 'U':
                        note(pane.handleKey(k));
                        return true;
                    case ' ':
                        primary();
                        return true;
                    default:
                        return false;
                }
            default:
                return false;
        }
    }

    // ── Scrollable ──────────────────────────────────────────────────────────

    void scroll(int dy) @system
    {
        scrollCells += dy;
        if (scrollCells > maxScroll)
            scrollCells = maxScroll;
        if (scrollCells < 0)
            scrollCells = 0;
    }

    // ── the rows ────────────────────────────────────────────────────────────

    private Item[] buildItems() @trusted
    {
        Item[] r;
        const searching = pane.tree.searching;
        auto self = this;
        const sec = sectionItems(pane.tree.data, levels.length ? levels[$ - 1] : null,
            searching, (string p) => (p in self.folded) !is null);
        bool keysPlaced;
        foreach (ref s; sec)
        {
            if (pane.tree.data.nodes[s.node].value.path == keysPath)
            {
                keysPlaced = true;
                r ~= keysItems();
                continue;
            }
            r ~= Item(Item.Kind.section, s);
        }
        // The bindings match a query by their own words (the tree's search
        // sees only the overlay as a whole).
        if (!keysPlaced && !levels.length && searching)
            r ~= keysItems();
        return r;
    }

    private Item[] keysItems() @safe
    {
        import std.algorithm.searching : canFind;
        import std.uni : toLower;

        Item[] r;
        const q = pane.tv.filterQuery.idup.toLower;
        size_t[] shown;
        foreach (i, ref row; bindings)
            if (!q.length || row.label.toLower.canFind(q)
                || pathLabel(row.path, leader).toLower.canFind(q))
                shown ~= i;
        if (q.length && !shown.length)
            return r;
        r ~= Item(Item.Kind.keysHeader);
        if ((keysPath in folded) !is null && !q.length)
            return r;
        foreach (i; shown)
            r ~= Item(Item.Kind.binding, SectionItem.init, i);
        return r;
    }

    private uint itemWidget(ref Builder b, size_t index, ref Item it, in SectionsOptions opt)
        @trusted
    {
        const focused = index == focus && !touch;
        final switch (it.kind)
        {
            case Item.Kind.keysHeader:
            {
                size_t n;
                foreach (ref x; items)
                    n += x.kind == Item.Kind.binding;
                const q = pane.tv.filterQuery.length;
                return sectionHeader(b, "Keys", q ? text("keys · ", n, " matches") : "keys",
                    (keysPath in folded) !is null && !q, hitKeysHeader, opt);
            }
            case Item.Kind.binding:
                return bindingWidget(b, it.binding, focused, opt);
            case Item.Kind.section:
                break;
        }
        const n = &pane.tree.data.nodes[it.si.node].value;
        if (it.si.kind == SectionItem.Kind.header)
        {
            // Collapsed, the header summarises what it holds (`PRT36`).
            const detail = it.si.collapsed
                ? sectionSummary(pane.tree.data, it.si.node) : n.path;
            return sectionHeader(b, n.heading, detail, it.si.collapsed,
                sectionHit(sectionBase, it.si.node, SectionPart.row), opt);
        }
        RowState st;
        st.focused = focused;
        if (it.si.kind == SectionItem.Kind.leaf && !n.synthetic)
        {
            st.changed = !pane.atDefault(n.path);
            const pv = pane.provenance(n.path);
            if (pv.note.length)
            {
                st.chip = pv.shadowed ? pv.layer : pv.note;
                st.chipWarn = true;
            }
            else if (pv.layer.length && pv.layer != "default" && pv.layer != pane.fileLayer)
                st.chip = pv.layer;
            st.open = openDropdown == n.path;
            st.editing = pane.textEditing && pane.textPath == n.path;
            if (st.editing)
                st.editText = pane.textBuf;
            const rf = pane.edits.refusalFor(n.path);
            if (rf.refused)
            {
                import sparkles.ui.components.property_view : refusalText;

                st.refusal = refusalText(rf);
            }
        }
        return sectionRow(b, pane.tree.data, it.si, st, opt, sectionBase);
    }

    private uint bindingWidget(ref Builder b, size_t i, bool focused, in SectionsOptions opt)
        @safe
    {
        const row = &bindings[i];
        const path = pathLabel(row.path, leader);
        string sub = text(row.scope_, " scope");
        if (row.changed && row.defaultPath.length)
            sub ~= " · default " ~ row.defaultPath;
        TextSpan[] title = [TextSpan(text: row.label, slot: Slot.textPrimary)];
        if (row.changed)
            title ~= TextSpan(text: " ●", slot: Slot.accentPrimary);
        const left = b.add(Widget(kind: WidgetKind.column, children: [
            b.add(Widget(kind: WidgetKind.rich, spans: title)),
            b.add(Widget(kind: WidgetKind.text, text: sub, slot: Slot.muted))],
            width: SizeSpec.grow(), clipX: true));
        const chip = b.add(Widget(kind: WidgetKind.panel, children: [b.add(Widget(
            kind: WidgetKind.text, text: path, slot: Slot.code))],
            padding: Insets(0, 1, 0, 1), slot: Slot.surfaceRaised, paintBackground: true,
            decoration: Decoration(borderRadius: 4)));
        const edit = b.add(Widget(kind: WidgetKind.panel, children: [b.add(Widget(
            kind: WidgetKind.text, text: "✎", slot: Slot.textPrimary))],
            padding: Insets(0, 1, 0, 1), hitId: bindingBase + i * 4 + 1,
            height: opt.targetRows > 1 ? SizeSpec.fixed(opt.targetRows) : SizeSpec.fit_,
            alignY: Alignment.center));
        foreach (p; [chip, edit])
            b.nodes[p].width = SizeSpec(SizeSpec.Kind.fit, 0, naturalCells(b, p));
        const main = b.add(Widget(kind: WidgetKind.row, children: [left, chip, edit], gap: 1,
            width: SizeSpec.grow(),
            height: SizeSpec(SizeSpec.Kind.fit, 0, opt.targetRows > 1 ? opt.targetRows : 0),
            alignY: Alignment.center, hitId: bindingBase + i * 4));
        uint[] kids = [main];
        if (capture.open && captureRow == i)
            kids ~= chordCaptureView(b, capture, leader, captureBase, opt.targetRows, touch);
        const capturing = capture.open && captureRow == i;
        return b.add(Widget(kind: WidgetKind.column, children: kids, gap: capturing ? 1 : 0,
            width: SizeSpec.grow(), padding: Insets(0, 1, capturing ? 1 : 0, 2),
            slot: focused || capturing ? Slot.selection : Slot.inherit,
            paintBackground: focused || capturing,
            decoration: Decoration(borderStyle: BorderStyle.solid, borderWidth: Insets(0, 0, 1, 0),
                borderSlot: Slot.border)));
    }

    private uint titleBar(ref Builder b, in SurfaceContext ctx) @safe
    {
        string title = "Settings";
        foreach (p; levels)
            if (auto n = pane.nodeAt(p))
                title ~= " › " ~ sentenceCase(n.label);
        const back = b.add(Widget(kind: WidgetKind.panel, children: [b.add(Widget(
            kind: WidgetKind.text, text: "←", slot: Slot.textPrimary))],
            padding: Insets(0, 1, 0, 1), hitId: hitBack,
            height: ctx.targetRows > 1 ? SizeSpec.fixed(ctx.targetRows) : SizeSpec.fit_,
            alignY: Alignment.center));
        const name = b.add(Widget(kind: WidgetKind.text, text: title, slot: Slot.textPrimary,
            textStyle: TextStyle(bold: true), width: SizeSpec.grow()));
        return b.add(Widget(kind: WidgetKind.row, children: [back, name], gap: 1,
            width: SizeSpec.grow(),
            height: SizeSpec.fixed(ctx.targetRows > 1 ? ctx.targetRows : 1),
            alignY: Alignment.center, slot: Slot.chrome,
            paintBackground: true));
    }

    private uint filterRow(ref Builder b, in SurfaceContext ctx) @trusted
    {
        const q = pane.tv.filterQuery.idup;
        TextSpan[] spans = [TextSpan(text: "⌕ ", slot: Slot.muted)];
        if (q.length)
            spans ~= TextSpan(text: q, slot: Slot.textPrimary);
        else if (!pane.tv.searching)
            spans ~= TextSpan(text: "Filter · e.g. colour, exit, keys", slot: Slot.muted);
        if (pane.tv.searching)
            spans ~= TextSpan(text: "▏", slot: Slot.caret);
        if (pane.tree.filterError.length)
            spans ~= TextSpan(text: "  ⚠ " ~ pane.tree.filterError, slot: Slot.error);
        uint[] kids = [b.add(Widget(kind: WidgetKind.rich, spans: spans, width: SizeSpec.grow(),
            clipX: true))];
        if (q.length || pane.tv.searching)
            kids ~= b.add(Widget(kind: WidgetKind.text, text: " ✕ ", slot: Slot.muted,
                hitId: hitFilterClear));
        const fieldRows = ctx.targetRows > 1 ? ctx.targetRows : 1;
        const field = b.add(Widget(kind: WidgetKind.row, children: kids,
            width: SizeSpec.grow(),
            height: SizeSpec.fixed(fieldRows),
            alignY: Alignment.center, padding: Insets(0, 1, 0, 1), hitId: hitFilter,
            slot: Slot.surfaceSunken, paintBackground: true,
            decoration: Decoration(borderStyle: BorderStyle.solid, borderWidth: Insets.all(1),
                borderSlot: pane.tv.searching ? Slot.accentPrimary : Slot.border,
                borderRadius: 6)));
        return b.add(Widget(kind: WidgetKind.column, children: [field],
            width: SizeSpec.grow(), height: SizeSpec.fixed(fieldRows + (touch ? 2 : 0)),
            padding: Insets(touch ? 1 : 0, 1, touch ? 1 : 0, 1)));
    }

    private uint toastLayer(ref Builder b, int w, int h, int targetRows) @safe
    {
        uint[] kids = [b.add(Widget(kind: WidgetKind.text, text: toast.text,
            slot: Slot.textPrimary, width: SizeSpec.grow(), clipX: true))];
        if (toast.undo || toast.keysUndo)
            kids ~= b.add(Widget(kind: WidgetKind.text, text: "↶ UNDO", slot: Slot.textPrimary,
                textStyle: TextStyle(bold: true), hitId: hitUndo, padding: Insets(0, 1, 0, 1)));
        const bar = b.add(Widget(kind: WidgetKind.row, children: kids, gap: 1,
            width: SizeSpec.grow(), height: SizeSpec.fixed(targetRows > 1 ? targetRows : 1),
            alignY: Alignment.center, padding: Insets(0, 1, 0, 1), slot: Slot.chromeAccent,
            paintBackground: true, decoration: Decoration(borderRadius: 8)));
        return b.add(Widget(kind: WidgetKind.column, children: [bar],
            width: SizeSpec.fixed(w), height: SizeSpec.fixed(h), alignY: Alignment.end,
            padding: Insets(0, 1, 1, 1)));
    }

    // ── acting ──────────────────────────────────────────────────────────────

    private bool close() @system
    {
        pane.close();
        closed = true;
        return true;
    }

    private void popLevel() @safe
    {
        levels = levels[0 .. $ - 1];
        focus = 0;
        scrollCells = 0;
        openDropdown = null;
    }

    private void toggleFold(string path) @safe
    {
        if (path in folded)
            folded.remove(path);
        else
            folded[path] = true;
    }

    private void moveFocus(int by) @safe
    {
        if (!items.length)
            return;
        long f = cast(long) focus + by;
        if (f < 0)
            f = 0;
        if (f >= cast(long) items.length)
            f = items.length - 1;
        focus = cast(size_t) f;
        focusMoved = true;
    }

    private void focusOnBinding(size_t row) @safe
    {
        foreach (i, ref it; items)
            if (it.kind == Item.Kind.binding && it.binding == row)
                focus = i;
    }

    /// The focused row's leaf node, or null.
    private const(PropertyNode)* focusedLeaf() @trusted
    {
        if (focus >= items.length || items[focus].kind != Item.Kind.section)
            return null;
        const si = items[focus].si;
        if (si.kind != SectionItem.Kind.leaf)
            return null;
        return &pane.tree.data.nodes[si.node].value;
    }

    /// Enter (or a tap on the row): what the row is for.
    private void primary() @system
    {
        if (focus >= items.length)
            return;
        auto it = items[focus];
        final switch (it.kind)
        {
            case Item.Kind.keysHeader:
                toggleFold(keysPath);
                return;
            case Item.Kind.binding:
                startCapture(it.binding);
                return;
            case Item.Kind.section:
                break;
        }
        rowPrimary(it.si.node, false);
    }

    /// A row's primary action; `tap` is a pointer on the row itself.
    private void rowPrimary(uint node, bool tap) @system
    {
        const n = &pane.tree.data.nodes[node].value;
        foreach (i, ref it; items)
            if (it.kind == Item.Kind.section && it.si.node == node)
                focus = i;
        if (n.section && !n.composite)
            return;
        if (n.synthetic)
            return;
        bool header;
        foreach (ref it; items)
            header |= it.kind == Item.Kind.section && it.si.node == node
                && it.si.kind == SectionItem.Kind.header;
        if (header)
        {
            toggleFold(n.path);
            return;
        }
        if (n.composite)
        {
            levels ~= n.path;
            focus = 0;
            scrollCells = 0;
            openDropdown = null;
            return;
        }
        final switch (inlineEditorFor(*n, opts.segmentCells))
        {
            case InlineEditor.toggle:
                note(pane.stepAt(n.path, 1));
                break;
            case InlineEditor.segmented:
                if (!tap)
                    note(pane.stepAt(n.path, 1));
                break;
            case InlineEditor.dropdown:
                if (tap)
                    openDropdown = openDropdown == n.path ? null : n.path;
                else
                    note(pane.stepAt(n.path, 1));
                break;
            case InlineEditor.swatch:
            case InlineEditor.text:
                note(pane.editTextAt(n.path));
                wantsKeyboard = touch;
                break;
            case InlineEditor.stepper:
            case InlineEditor.drillIn:
            case InlineEditor.readOnly:
            case InlineEditor.none:
                break;
        }
    }

    /// `←`/`→`: a stepper's ±, the previous or next choice, a toggle.
    private void stepFocused(int dir) @system
    {
        if (auto n = focusedLeaf())
            if (n.editable && (n.kind == LeafKind.integral || n.kind == LeafKind.floating
                || n.kind == LeafKind.enumeration || n.kind == LeafKind.boolean))
                note(pane.stepAt(n.path, dir));
    }

    private void sectionPart(uint node, uint part) @system
    {
        if (node >= pane.tree.data.nodes.length)
            return;
        const n = &pane.tree.data.nodes[node].value;
        switch (part)
        {
            case SectionPart.row:
                rowPrimary(node, true);
                return;
            case SectionPart.reset:
                note(pane.resetAt(n.path));
                return;
            case SectionPart.dec:
                note(pane.stepAt(n.path, -1));
                return;
            case SectionPart.inc:
            case SectionPart.toggle:
                note(pane.stepAt(n.path, 1));
                return;
            case SectionPart.open:
                rowPrimary(node, true);
                return;
            case SectionPart.accept:
                note(pane.handleKey(KeyEvent(Key.enter)));
                return;
            case SectionPart.cancelEdit:
                note(pane.handleKey(KeyEvent(Key.escape)));
                return;
            default:
                const i = part - SectionPart.choice0;
                if (i < n.choices.length)
                    note(pane.setAt(n.path, EditValue.ofEnum(n.choices[i])));
                openDropdown = null;
                return;
        }
    }

    /// A pane result: apply what it obliges, and say so in the toast.
    private void note(SettingsResult r) @system
    {
        if (r.apply && applyFn !is null)
            applyFn(r.apply);
        if (r.kind == SettingsResult.Kind.saved || pane.toast.kind == SettingsToast.Kind.failed)
            sayCommitted();
    }

    private void sayCommitted() @system
    {
        if (pane.toast.kind == SettingsToast.Kind.failed)
        {
            showToast("✗ not saved: " ~ pane.toast.message, false, false);
            return;
        }
        const n = pane.nodeAt(pane.lastCommitted);
        if (n is null)
        {
            showToast("✓ Saved", pane.toast.offersUndo, false);
            return;
        }
        showToast(text("✓ ", sentenceCase(n.label), " ", shownValue(*n), " · saved"),
            pane.toast.offersUndo, false);
    }

    private static string shownValue(ref const PropertyNode n) @safe
    {
        switch (n.kind)
        {
            case LeafKind.boolean:
                return n.badge == "true" ? "on" : "off";
            case LeafKind.enumeration:
                foreach (i, c; n.choices)
                    if (c == n.badge)
                        return choiceLabel(n, i);
                return n.badge;
            case LeafKind.text:
                return unquoted(n.badge);
            default:
                return n.badge;
        }
    }

    private void showToast(string t, bool undo, bool keysUndo) @safe
    {
        toast = Toast(t, undo, keysUndo, MonoTime.currTime + 6.seconds);
    }

    private void undo() @system
    {
        if (toast.keysUndo && keysUndo.length)
        {
            const prev = keysUndo[$ - 1];
            keysUndo = keysUndo[0 .. $ - 1];
            writeKeys((() @trusted => cast(KeysConfig) prev)(), "✓ Binding restored", false);
            return;
        }
        note(pane.undoLast());
        if (pane.toast.kind == SettingsToast.Kind.saved)
            showToast("↶ Undone · saved", pane.edits.undo.length > 0, false);
    }

    // ── the capture (`TSP8`) ────────────────────────────────────────────────

    private void startCapture(size_t row) @safe
    {
        if (row >= bindings.length)
            return;
        captureRow = row;
        capture.begin(bindings[row].path.length);
        focusMoved = true;
    }

    private string reservedReason(in Chord c) @safe
    {
        if (captureRow < bindings.length && bindings[captureRow].scope_ == TermScope.prompt)
            return null; // the exit prompt's Ctrl+C: no program to send it to
        return isReserved(c)
            ? pathLabel([c]) ~ " belongs to the program — Ctrl+C, Ctrl+Z, Ctrl+S, Ctrl+Q "
                ~ "and Ctrl+\\ are reserved (KBD3)"
            : null;
    }

    /// What `path` does now in the captured row's scope.
    private CaptureConflict conflictOf(in Chord[] path) @safe
    {
        if (captureRow >= bindings.length)
            return CaptureConflict.init;
        const target = &bindings[captureRow];
        string[] ignored;
        const table = terminalBindings(leader,
            (() @trusted => cast(KeysConfig) store.resolved.keys)(), ignored);
        foreach (ref b; table)
        {
            if (b.scope_ != target.scope_)
                continue;
            const rp = b.path[0 .. b.depth];
            const n = rp.length < path.length ? rp.length : path.length;
            if (!samePath(rp[0 .. n], path[0 .. n]))
                continue;
            if (rp.length == path.length)
            {
                if (b.group.length)
                    return CaptureConflict(pathLabel(path, leader) ~ " opens the "
                        ~ b.group ~ " keys", false, true);
                if (b.cmd == target.cmd && samePath(rp, target.path))
                    continue; // itself
                return CaptureConflict(b.desc);
            }
            if (rp.length > path.length)
                return CaptureConflict(pathLabel(path, leader) ~ " opens other keys", false,
                    true);
            if (!b.group.length)
                return CaptureConflict(pathLabel(rp, leader) ~ " already runs “"
                    ~ b.desc ~ "”", true);
        }
        return CaptureConflict.init;
    }

    private void captureButton(CaptureHit h) @system
    {
        final switch (h)
        {
            case CaptureHit.cancel:
                capture.cancel();
                break;
            case CaptureHit.both:
                capture.resolve(CaptureResolution.both);
                break;
            case CaptureHit.swap:
                capture.resolve(CaptureResolution.swap);
                break;
            case CaptureHit.done:
                cast(void) capture.finish((in Chord[] p) => conflictOf(p));
                break;
        }
        settleCapture(capture.phase);
    }

    private void settleCapture(CapturePhase ph) @system
    {
        if (ph == CapturePhase.cancelled)
        {
            capture.reset();
            captureRow = size_t.max;
            return;
        }
        if (ph != CapturePhase.done || captureRow >= bindings.length)
            return;
        const row = bindings[captureRow];
        const path = capture.path.dup;
        // The command the path ran, for a swap.
        TermCommand displaced;
        foreach (ref b; bindings)
            if (b.scope_ == row.scope_ && samePath(b.path, path))
                displaced = b.cmd;
        const how = capture.resolution;
        capture.reset();
        captureRow = size_t.max;
        keysUndo ~= copyKeys((() @trusted => cast(KeysConfig) store.resolved.keys)());
        const keys = rebind((() @trusted => cast(KeysConfig) store.resolved.keys)(), row,
            path, how, displaced, leader);
        writeKeys((() @trusted => cast(KeysConfig) keys)(),
            text("✓ ", row.label, " → ", pathLabel(path, leader), " · saved"), true);
    }

    private void writeKeys(KeysConfig keys, string said, bool undoable) @system
    {
        const failure = store.bindKeys(*pane, keys);
        bindings = bindingRows(store.resolved, leader);
        if (applyFn !is null)
            applyFn(TerminalApply.keys);
        if (failure.length)
            showToast("✗ not saved: " ~ failure, false, false);
        else
            showToast(said, false, undoable && keysUndo.length > 0);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// What every embedder applies the same way.
// ─────────────────────────────────────────────────────────────────────────────

/**
The part of a live apply (`TCF8`) every embedder shares: the host's chrome
settings and exit policy, and every pane's protocol policy and scrollback.
Colours, the font, the key table and the extra keys are the embedder's.
*/
void applyToWorkspace(H)(ref H host, TerminalConfig c) @system
{
    import cli : protocolPolicyFrom;

    host.onExit = c.behaviour.onExit;
    host.labels = c.ui.buttonLabels;
    host.overlayStyle = c.ui.overlayStyle;
    host.tabsOpener = c.ui.tabsOpener;
    host.paneChrome = c.ui.paneChrome;
    const policy = protocolPolicyFrom(c);
    const limit = c.behaviour.scrollback < 0 ? size_t.max : cast(size_t) c.behaviour.scrollback;
    foreach (id, tv; host.pool)
    {
        tv.opts.policy = policy;
        tv.opts.scrollbackLimit = limit;
    }
    host.invalidate();
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests.
// ─────────────────────────────────────────────────────────────────────────────

version (unittest)
{
    import std.path : buildPath;

    import sparkles.input.events : Mods;
    import sparkles.test_utils.tmpfs : TmpFS;

    import settings_load : loadTerminalConfig;

    /// The file with its layout whitespace gone.
    private string squeezed(string file) @safe
    {
        import std.algorithm.iteration : joiner, map;
        import std.array : replace;
        import std.conv : to;
        import std.file : readText;
        import std.string : lineSplitter, strip;

        return readText(file).lineSplitter.map!strip.joiner.to!string.replace(`": `, `":`);
    }

    private const(char)[] allText(in WidgetTree t) @safe
    {
        const(char)[] s;
        foreach (ref n; t.nodes)
        {
            s ~= n.text;
            s ~= "\n";
            foreach (ref sp; n.spans)
                s ~= sp.text;
        }
        return s;
    }

    private final class PageFixture
    {
        string file;
        TerminalSettingsStore* store;
        SettingsPage page;
        uint applied;

        this(string dir) @system
        {
            file = buildPath(dir, "config.json");
            store = new TerminalSettingsStore;
            *store = TerminalSettingsStore.from(loadTerminalConfig(file, null));
        }

        void open() @system
        {
            page = new SettingsPage(store, (uint m) { applied |= m; });
        }
    }

    private SurfaceContext phone() @safe
    {
        import sparkles.ui.geometry : Rect;

        SurfaceContext c = {area: Rect(0, 0, 450, 1600), cellW: 10, cellH: 20, targetRows: 3,
            touch: true};
        return c;
    }

    /// The hit id of the first target whose id decodes to `path`'s `part`.
    private size_t hitFor(SettingsPage p, string path, uint part) @system
    {
        foreach (i, ref nd; p.pane.tree.data.nodes)
            if (nd.value.path == path)
                return sectionHit(sectionBase, cast(uint) i, part);
        assert(false, path);
    }
}

@("settings_page.build.sectionsInDeclarationOrderAllExpanded")
@system unittest
{
    import std.algorithm.searching : canFind, countUntil;

    auto fs = TmpFS.create();
    auto f = new PageFixture(fs.dir);
    f.open();
    const shown = allText(f.page.build(phone(), 45));
    // `TSP7`: every section open, in the struct's order, keys in place.
    const order = ["APPEARANCE", "KEYBOARD", "WHEN A PROGRAM EXITS", "LINKS", "PASTE",
        "CLIPBOARD", "NOTIFICATIONS", "KEY GUIDE", "INTERFACE", "OPENING FILES", "KEYS"];
    ptrdiff_t at = -1;
    foreach (h; order)
    {
        const i = shown.countUntil("▾ " ~ h);
        assert(i > at, h);
        at = i;
    }
    // Leaves carry their descriptions and controls; a scheme is a drill-in.
    assert(shown.canFind("Follow system") && shown.canFind("Switch between the dark"));
    assert(shown.canFind("● off") || shown.canFind("on ●"));
    assert(shown.canFind("Split right") && shown.canFind("␣ p v"));
}

@("settings_page.activate.controlsCommitApplyAndSave")
@system unittest
{
    import std.algorithm.searching : canFind;
    import std.file : exists, readText;

    auto fs = TmpFS.create();
    auto f = new PageFixture(fs.dir);
    f.open();
    cast(void) f.page.build(phone(), 45);

    // The stepper: one tap, one committed, saved, applied edit.
    f.page.activate(hitFor(f.page, "appearance.font.size", SectionPart.inc));
    assert(f.store.resolved.appearance.font.size == 14);
    assert(f.applied & TerminalApply.font);
    assert(f.file.exists && squeezed(f.file).canFind(`"size":14`), squeezed(f.file));
    // The toast names it and offers Undo; Undo is the tree's history.
    const toasted = allText(f.page.build(phone(), 45));
    assert(toasted.canFind("✓ Size 14 · saved") && toasted.canFind("UNDO"));
    f.page.activate(hitUndo);
    assert(f.store.resolved.appearance.font.size == 13);

    // A segment, then the per-row reset.
    f.page.activate(hitFor(f.page, "extraKeys.visible", SectionPart.choice0 + 2));
    assert(f.store.resolved.extraKeys.visible == f.store.resolved.extraKeys.visible.never);
    assert(f.applied & TerminalApply.extraKeys);
    cast(void) f.page.build(phone(), 45);
    f.page.activate(hitFor(f.page, "extraKeys.visible", SectionPart.reset));
    assert(f.store.resolved.extraKeys.visible == f.store.resolved.extraKeys.visible.automatic);
    // On a phone a three-member enum that does not fit is a dropdown: a tap
    // on its row opens it, as drawn.
    f.page.activate(hitFor(f.page, "extraKeys.visible", SectionPart.row));
    assert(allText(f.page.build(phone(), 45)).canFind("✓ auto"));
    f.page.activate(hitFor(f.page, "extraKeys.visible", SectionPart.row));

    // A dropdown opens in place; a choice commits and closes it.
    f.page.activate(hitFor(f.page, "behaviour.onExit", SectionPart.open));
    assert(allText(f.page.build(phone(), 45)).canFind("✓ prompt on failure"));
    f.page.activate(hitFor(f.page, "behaviour.onExit", SectionPart.choice0 + 3));
    assert(f.store.resolved.behaviour.onExit == f.store.resolved.behaviour.onExit.hold);
    assert(f.applied & TerminalApply.behaviour);
}

@("settings_page.activate.drillInAndBackPopTheLevel")
@system unittest
{
    import std.algorithm.searching : canFind;

    auto fs = TmpFS.create();
    auto f = new PageFixture(fs.dir);
    f.open();
    cast(void) f.page.build(phone(), 45);
    f.page.activate(hitFor(f.page, "appearance.colors.dark", SectionPart.row));
    const level = allText(f.page.build(phone(), 45));
    assert(level.canFind("Settings › Dark") && level.canFind("#cdd6f4"));
    // Back pops the level; it does not close the page.
    assert(f.page.key(KeyEvent(Key.back)));
    assert(!allText(f.page.build(phone(), 45)).canFind("Settings › Dark"));
    // At the top, Back is declined — the table's `dismiss` closes the page.
    assert(!f.page.key(KeyEvent(Key.back)));
    f.page.cancel();
    assert(f.page.closed);
}

@("settings_page.capture.rebindsWritesTheOverlayAndUndoes")
@system unittest
{
    import std.algorithm.searching : canFind;
    import std.file : readText;

    auto fs = TmpFS.create();
    auto f = new PageFixture(fs.dir);
    f.open();
    cast(void) f.page.build(phone(), 45);
    size_t row = size_t.max;
    foreach (i, ref b; f.page.bindings)
        if (b.cmd == TermCommand.splitDown)
            row = i;
    assert(row != size_t.max);

    // A reserved key is refused with the reason; the capture keeps listening.
    f.page.activate(bindingBase + row * 4);
    assert(f.page.key(KeyEvent(Key.char_, 'c', Mods(ctrl: true))));
    assert(f.page.capture.refusal.canFind("reserved"));
    // A three-key path: each key in turn; `␣ p` then `d`.
    const leader = KeyEvent(Key.char_, ' ', Mods(ctrl: true, shift: true));
    assert(f.page.key(leader) && f.page.key(KeyEvent(Key.char_, 'p'))
        && f.page.key(KeyEvent(Key.char_, 'd')));
    assert(!f.page.capture.open, "a free path settles at once");
    assert(f.applied & TerminalApply.keys);
    assert(squeezed(f.file).canFind(`"space p d":"splitDown"`), squeezed(f.file));
    assert(squeezed(f.file).canFind(`"space p s":null`));

    // A bound chord asks; Swap trades the two.
    size_t right = size_t.max;
    foreach (i, ref b; f.page.bindings)
        if (b.cmd == TermCommand.splitRight)
            right = i;
    f.page.activate(bindingBase + right * 4);
    assert(f.page.key(leader) && f.page.key(KeyEvent(Key.char_, 'p'))
        && f.page.key(KeyEvent(Key.char_, 'd')));
    assert(f.page.capture.phase == CapturePhase.conflict);
    assert(f.page.capture.conflict == "split down");
    f.page.activate(captureBase + CaptureHit.swap);
    const text_ = squeezed(f.file);
    assert(text_.canFind(`"space p d":"splitRight"`) && text_.canFind(`"space p v":"splitDown"`),
        text_);

    // Esc cancels a capture rather than binding Esc.
    f.page.activate(bindingBase + right * 4);
    assert(f.page.key(KeyEvent(Key.escape)) && !f.page.capture.open);

    // The toast's Undo puts the overlay back.
    f.page.undo();
    assert(squeezed(f.file).canFind(`"space p d":"splitDown"`));
}
