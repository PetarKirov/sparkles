/**
The tree-sitter inspector pane (`TSI` / `TVU2` / `INS6`) — hue's mount of the
generic inspector component over the CST adapter, shared by both hosts: one
state value, one `view`, one key/pointer step; the workspace and the GUI only
arrange, paint and route it.

The neovim-`:InspectTree` interaction set, pane-focused:

$(LIST
    * `j`/`k`/arrows move by visible row; `g`/`G` home/end; PgUp/PgDn page;
    * `h`/`←` is the universal two-step Left, `l`/`→` expands, Enter toggles;
    * `a` toggles anonymous nodes — a $(B rebuild), with the cursor preserved
        on the nearest named node (the reference's own trick);
    * `s` toggles hover sync (the header shows both toggles' state);
    * a click selects, a second click on the selected row toggles it.
)

The sync contract (`INS6`) is split with the hosts: this pane answers
"select the node at byte offset" ($(LREF InspectorPane.selectAt)) and "what
extent is selected" ($(LREF InspectorPane.selectedExtent)); the hosts feed
pointer-hover offsets in and paint the extent tint + off-screen-only
scroll-follow through $(REF ViewerModel.setInspectExtent, viewer_model).

Keys are handled pane-locally for now (like the explorer before `KEY1`); a
`Scope_.inspector` in the shared table — and with it the lantern guide —
lands when the pane's set stabilizes.
*/
module inspector_pane;

import sparkles.input : Event, EndOfInput, InputKey = Key, KeyEvent, match,
    Point, PointerEvent;
import sparkles.ui.components.inspector : DetailRow, InspectorAction,
    inspectorView;
import sparkles.ui.components.tree_view : treeActivate = activate,
    treeCollapseOrUp = collapseOrUp, TreeStep, TreeViewState;
import sparkles.ui.components.tree_widget : flatten, TreeGlyphs;
import sparkles.ui.state : DisclosureState;
import sparkles.ui.widget : Builder;

import ts_inspect : CstInspect, inspectCst;
import viewer_model : ViewerModel;

@safe:

/// The pane's hit-id base (its rows live in the hosts' one id space).
enum uint hitInspectorTree = 200_000;

/// ditto
struct InspectorPane
{
    /// The shared interaction layer, keyed by the CST arena index.
    TreeViewState!uint tv;
    /// The adapter's product for the current document (+ anonymous flag).
    CstInspect ci;
    bool showAnonymous;      ///
    bool syncHover = true;   /// the header's `[sync]` toggle
    bool focused;            ///
    /// The last hover offset a host synced from (dedupe: `selectAt` per
    /// pointer $(I move), not per frame).
    size_t lastSyncOffset = size_t.max;

    private const(char)[] builtFor;  // vm.source identity at last rebuild
    private bool builtAnon;

    /// Whether the built tree still matches the document (+ toggle state).
    bool fresh(ref ViewerModel vm) const @nogc nothrow pure
        => builtFor is vm.source && builtAnon == showAnonymous
            && ci.data.nodes.length != 0;

    /**
    (Re)builds the adapter tree from the document's retained layers. The
    disclosure resets to everything-open (the reference's presentation; a
    structural-path re-match across re-parses is the specced follow-up).
    */
    void rebuild(ref ViewerModel vm) @system
    {
        vm.ensureParsed();
        ci = inspectCst(vm.layers, vm.source, showAnonymous);
        tv.open = DisclosureState!uint.allOpen;
        refreshRows();
        if (tv.sel >= cast(long) tv.rows.length)
            tv.sel = 0;
        builtFor = vm.source;
        builtAnon = showAnonymous;
    }

    /// Re-flattens after a disclosure change. `contentCols` stays 0 on
    /// purpose: the pane clips long rows (no horizontal bar), which also
    /// keeps the shared pointer arm's h-bar zone dead.
    void refreshRows()
    {
        const open = tv.open;
        auto data = ci.data;
        tv.rows = flatten(data, (uint n) => open.isOpen(n));
        tv.clamp();
    }

    /// The sync contract's source→tree half: select (and reveal) the
    /// deepest node containing byte `offset`. Ancestors open as needed.
    void selectAt(size_t offset)
    {
        const n = ci.nodeAt(offset);
        if (n == uint.max)
            return;
        for (auto p = ci.data.nodes[n].parent; p != uint.max;
            p = ci.data.nodes[p].parent)
            tv.open = tv.open.opened(p);
        refreshRows();
        foreach (i, ref const r; tv.rows)
            if (r.node == n)
            {
                tv.sel = cast(long) i;
                break;
            }
        tv.clamp();
    }

    /// The tree→source half: the selected node's byte extent (`false` when
    /// nothing meaningful is selected).
    bool selectedExtent(out size_t start, out size_t end) const @nogc nothrow pure
    {
        const n = tv.selectedNode;
        if (n == uint.max)
            return false;
        ci.extentOf(n, start, end);
        return end > start;
    }

    /// `a`: rebuild with/without anonymous rows, keeping the cursor on the
    /// nearest named node across the arena change (re-found by extent+type).
    void toggleAnonymous(ref ViewerModel vm) @system
    {
        const cur = tv.selectedNode;
        const anchor = cur == uint.max ? uint.max : ci.nearestNamed(cur);
        size_t as, ae;
        string atype;
        if (anchor != uint.max)
        {
            ci.extentOf(anchor, as, ae);
            atype = ci.data.nodes[anchor].value.type;
        }
        showAnonymous = !showAnonymous;
        rebuild(vm);
        if (anchor != uint.max)
            foreach (i, ref const r; tv.rows)
            {
                ref const v = ci.data.nodes[r.node].value;
                if (v.startByte == as && v.endByte == ae && v.type == atype)
                {
                    tv.sel = cast(long) i;
                    break;
                }
            }
        tv.clamp();
    }

    /// The pane's view: the generic component over the adapter, details for
    /// the selection, both toggles in the header. `chromeRows` is derived
    /// from what the header + details actually take, so the tree window
    /// fills exactly the rest of the pane the host arranged.
    uint view(ref Builder b, int innerWidth) @system
    {
        auto details = ci.details(tv.selectedNode);
        tv.chromeRows = 2 + (details.length ? cast(int) details.length + 1 : 0);
        tv.clamp();
        const open = tv.open;
        auto data = ci.data;
        return inspectorView(b, data, tv,
            (uint n) => open.isOpen(n),
            focused ? "inspector·" : "inspector",
            [
                InspectorAction("sync", syncHover),
                InspectorAction("anon", showAnonymous),
            ],
            details, innerWidth, TreeGlyphs.init, hitInspectorTree);
    }

    /// One pane-local event. Returns `true` while the pane stays open
    /// (`q`/Escape close it, mirroring the explorer's quit intent).
    bool handle(in Event e, ref ViewerModel vm) @system
    {
        return e.match!(
            (in KeyEvent k) => key(k, vm),
            (in PointerEvent p) {
                // The component's body window starts one row lower than its
                // assumption (header + rule): shift into its space.
                const q = PointerEvent(action: p.action, button: p.button,
                    pos: Point(p.pos.x, p.pos.y - 1));
                if (tv.pointer(q) == TreeStep.activated)
                    activateSel();
                return true;
            },
            (in EndOfInput _) => false,
            _ => true,
        );
    }

    private bool key(in KeyEvent k, ref ViewerModel vm) @system
    {
        switch (k.key)
        {
            case InputKey.down: tv.moveSel(1); return true;
            case InputKey.up: tv.moveSel(-1); return true;
            case InputKey.pageDown: tv.moveSel(tv.bodyRows); return true;
            case InputKey.pageUp: tv.moveSel(-tv.bodyRows); return true;
            case InputKey.home: tv.selHome(); return true;
            case InputKey.end: tv.selEnd(); return true;
            case InputKey.left: collapseSel(); return true;
            case InputKey.right: expandSel(); return true;
            case InputKey.enter: activateSel(); return true;
            case InputKey.escape: return false;
            default: break;
        }
        if (k.key != InputKey.char_)
            return true;
        switch (k.ch)
        {
            case 'j': tv.moveSel(1); return true;
            case 'k': tv.moveSel(-1); return true;
            case 'g': tv.selHome(); return true;
            case 'G': tv.selEnd(); return true;
            case 'h': collapseSel(); return true;
            case 'l': expandSel(); return true;
            case 'a': toggleAnonymous(vm); return true;
            case 's': syncHover = !syncHover; return true;
            case 'q': return false;
            default: return true;
        }
    }

    private void collapseSel()
    {
        auto data = ci.data;
        if (treeCollapseOrUp(tv, data, (uint n) => n) == TreeStep.rebuild)
            refreshRows();
    }

    private void expandSel()
    {
        const n = tv.selectedNode;
        if (n != uint.max && ci.data.hasChildren(n) && !tv.open.isOpen(n))
        {
            tv.open = tv.open.opened(n);
            refreshRows();
        }
        else if (n != uint.max && ci.data.hasChildren(n))
            tv.moveSel(1); // already open: enter the subtree
    }

    private void activateSel()
    {
        auto data = ci.data;
        if (treeActivate(tv, data, (uint n) => n) == TreeStep.rebuild)
            refreshRows();
    }
}

// ---------------------------------------------------------------------------
// Tests (grammar-gated through the adapter's own helper).
// ---------------------------------------------------------------------------

version (unittest)
{
    import sparkles.syntax : builtinDark, LabelSet, resolveTheme, Theme;

    private ViewerModel vmForTest(string lang, string source) @system
    {
        import std.process : environment;
        import sparkles.syntax.ts.injection : TsConfigCache;
        import sparkles.syntax.ts.registry : GrammarRegistry;
        import sparkles.test_runner.skip : skipTest;

        if (environment.get("SPARKLES_TS_GRAMMAR_PATH", "").length == 0)
            skipTest("SPARKLES_TS_GRAMMAR_PATH not set (enter `nix develop`)");

        static GrammarRegistry registry;
        registry = GrammarRegistry.fromEnvironment();
        static TsConfigCache* cache;
        cache = new TsConfigCache;
        *cache = TsConfigCache.create(&registry, LabelSet.standard());

        static immutable Theme dark = builtinDark;
        ViewerModel vm;
        vm.themes = [dark];
        vm.names = ["dark"];
        vm.labels = LabelSet.standard();
        vm.cache = cache;
        vm.widthCols = 58;
        vm.applyTheme(0);
        import sparkles.syntax : HighlightEvent;

        vm.setDocument("t", "", source,
            [HighlightEvent.sourceSpan(0, source.length)],
            typeof(vm.preview).init, typeof(vm.tw).init, lang);
        return vm;
    }
}

@("inspector_pane.rebuildSyncAndExtent")
@system unittest
{
    const source = "{\"a\": [1, true]}\n";
    auto vm = vmForTest("json", source);

    InspectorPane pane;
    pane.tv.width = 30;
    pane.tv.height = 16;
    assert(!pane.fresh(vm));
    pane.rebuild(vm);
    assert(pane.fresh(vm));
    assert(pane.ci.data.nodes.length >= 5);

    // source→tree: the byte of `true` selects the deepest covering node…
    import std.string : indexOf;

    pane.selectAt(cast(size_t) source.indexOf("true"));
    assert(pane.ci.data.nodes[pane.tv.selectedNode].value.label == "true");

    // …and tree→source answers the extent the host will tint.
    size_t s, e;
    assert(pane.selectedExtent(s, e));
    assert(source[s .. e] == "true");

    // The host-side half: the extent lands as visual rects in the viewer.
    vm.setInspectExtent(s, e);
    assert(vm.inspectRects.length >= 1);
    assert(vm.inspectExtentVisible(16));
    vm.clearInspectExtent();
    assert(vm.inspectRects.length == 0);
}

@("inspector_pane.anonymousToggleKeepsTheAnchor")
@system unittest
{
    const source = "{\"a\": 1}\n";
    auto vm = vmForTest("json", source);

    InspectorPane pane;
    pane.tv.width = 30;
    pane.tv.height = 16;
    pane.rebuild(vm);

    // Select the pair, toggle anonymous on and off: the cursor stays on it.
    pane.selectAt(2);
    const before = pane.ci.data.nodes[pane.tv.selectedNode].value.type;
    assert(before.length, "something is selected");

    pane.toggleAnonymous(vm);
    assert(pane.showAnonymous);
    assert(pane.ci.data.nodes[pane.tv.selectedNode].value.type == before,
        "the anchor survived the rebuild");

    pane.toggleAnonymous(vm);
    assert(!pane.showAnonymous);
    assert(pane.ci.data.nodes[pane.tv.selectedNode].value.type == before);
}

@("inspector_pane.keysDriveTheSharedVerbs")
@system unittest
{
    import sparkles.input : KeyEvent;

    const source = "{\"a\": [1, 2]}\n";
    auto vm = vmForTest("json", source);

    InspectorPane pane;
    pane.tv.width = 30;
    pane.tv.height = 16;
    pane.rebuild(vm);
    assert(pane.tv.rows.length == pane.ci.data.nodes.length, "all open");

    // j moves; h on the root's subtree collapses (rebuild path).
    const rows0 = pane.tv.rows.length;
    assert(pane.handle(Event(KeyEvent(InputKey.char_, 'j')), vm));
    assert(pane.tv.sel == 1);
    assert(pane.handle(Event(KeyEvent(InputKey.char_, 'h')), vm));
    assert(pane.tv.rows.length < rows0, "collapse hid the subtree");

    // s toggles sync; q reports close intent.
    assert(pane.syncHover);
    pane.handle(Event(KeyEvent(InputKey.char_, 's')), vm);
    assert(!pane.syncHover);
    assert(!pane.handle(Event(KeyEvent(InputKey.char_, 'q')), vm));
}

@("inspector_pane.viewCarriesHeaderTogglesAndDetails")
@system unittest
{
    const source = "{\"a\": 1}\n";
    auto vm = vmForTest("json", source);

    InspectorPane pane;
    pane.tv.width = 30;
    pane.tv.height = 18;
    pane.rebuild(vm);
    pane.selectAt(1); // something selected → details exist

    auto b = Builder();
    auto tree = b.finish(pane.view(b, 28));

    bool sawSync, sawNode;
    foreach (ref n; tree.nodes)
        foreach (ref sp; n.spans)
        {
            sawSync |= sp.text == "[sync]";
            sawNode |= sp.text == "node";
        }
    assert(sawSync, "the header shows the sync toggle");
    assert(sawNode, "the details pane names the selection");
}
