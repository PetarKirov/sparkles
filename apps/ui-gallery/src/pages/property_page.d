/**
The Property page: one D value, reflected — `sparkles.ui.property_tree`
end to end.

The page owns nothing the component does not hand it: the subject, the
`PropertyTree` snapshot, the `TreeViewState!string` and the
`PropertyEditState` live in `GalleryState` as one `PropertyDemo` value, every
mutation goes through `editProperty`'s generated dispatch (so `@readOnly`,
`@Range`, type/width checks and the read-only policy are enforced where no
view can route around them), and every keystroke ends in a rebuild from
`ref subject` — the frame model, live.

What to try (the status bar lists the keys):

$(LIST
    * `Enter`/`→`/`←` — disclose; a closed composite still toggles (the
        shared `nodeExpandable` projection).
    * `+`/`-` — edit the selected leaf: bools toggle, enums cycle, numerics
        step by their `@Range` step, refused edits render inline below the
        row.
    * `v` — a preview "drag": further `+`/`-` mutate without history; `v`
        again commits ONE undo entry from the pre-preview value.
    * `u`/`U` — undo/redo, with total-equality preconditions: press `e`
        (an external write, bypassing history) first and watch them refuse
        with `stale history` instead of replaying blindly.
    * `/` then typing — the ranked fuzzy filter: matches + their ancestor
        closure, witness emphasis, honest omitted/incomplete rows; `n`/`N`
        cycle matches, `z` folds a subtree transiently, `b` reveals the
        match in the base tree; `Esc` restores disclosure and the anchor.
    * `O` — open all: the `linked` self-cycle runs into `⋯ (capped)`.
    * `p` — flip `PropertyTreePolicy(readOnly)`: every edit refuses.
)
*/
module pages.property_page;

import std.conv : text;

import sparkles.input : Key, KeyEvent;
import sparkles.ui.components.property_view : matchedFieldsText, propertyText,
    propertyView, PropertyViewOptions, refusalText, valueText;
import sparkles.ui.components.tree_view : treeActivate = activate,
    treeCollapseOrUp = collapseOrUp, TreeStep;
import sparkles.ui.geometry : SizeSpec;
import sparkles.ui.property_tree : Edit, editProperty, EditPhase, EditValue,
    finishPending, LeafKind, PropertyNode, readValueAt, redoProperty,
    SearchRole, undoProperty;
import sparkles.ui.style : Slot, TextStyle;
import sparkles.ui.widget : Builder, Widget, WidgetKind;

import kit;
import keymap : GalleryCommand;
import property_subject : DemoLayer, PropertyDemo;
import state : GalleryState;

// registry imports this module, so the index is re-declared here by value
// via a lazy lookup to avoid the circular import.
private size_t registry_propertyPageIndex() @safe
{
    import registry : propertyPageIndex;

    return propertyPageIndex;
}

@safe:

/// The tree rows' hit ids start here (`node + hitBase`).
private enum uint hitBase = 1;

/// The selected row's node value, or `null`.
private const(PropertyNode)* selectedNode(ref const PropertyDemo d)
{
    const node = d.tv.selectedNode;
    if (node == uint.max || node >= d.tree.data.nodes.length)
        return null;
    return (() @trusted => &d.tree.data.nodes[node].value)();
}

/// ditto
uint view(ref Builder b, in GalleryState s)
{
    const w = s.contentWidth;
    // `in` makes the whole state scope, but `s.prop` is persistent app state
    // that outlives every frame by construction; un-scope one reference so
    // borrowed row text can ride the widget tree the way every page's does.
    ref const PropertyDemo d =
        *(() @trusted => cast(const(PropertyDemo)*) &s.prop)();

    uint[] body_;
    body_ ~= heading(b, "Property tree · one value, reflected");
    body_ ~= spacer(b);
    body_ ~= para(b,
        "PropertyTree!T reflects the subject below at compile time — no "
        ~ "registry, no base class — and rebuilds one flat row snapshot from "
        ~ "ref subject on every change. Disclosure, selection, the filter, "
        ~ "and the undo/redo history are host-owned values beside it.", w);
    body_ ~= spacer(b);

    if (!d.built)
    {
        // The very first paint (or --render's single frame) arrives before
        // any input: show the real tree from a fresh local build. The frame
        // step / first key builds the persistent one.
        PropertyDemo fresh;
        fresh.ensure();
        builtSections(b, body_, fresh, w);
        return column(b, body_);
    }
    builtSections(b, body_, d, w);
    return column(b, body_);
}

/// Everything below the intro, over a built demo.
private void builtSections(ref Builder b, ref uint[] body_,
    ref const PropertyDemo d, int w)
{

    // ── the filter line ─────────────────────────────────────────────────────
    {
        uint[] items;
        if (d.tv.searching || d.tv.filterQuery.length)
        {
            items ~= label(b, "/", Slot.chromeAccent, TextStyle(bold: true));
            items ~= label(b, d.tv.filterQuery.length
                ? d.tv.filterQuery : "type to search…",
                d.tv.filterQuery.length ? Slot.code : Slot.muted);
            if (d.tv.searching)
                items ~= label(b, "▏", Slot.chromeAccent);
            if (d.tree.filterError.length)
                items ~= label(b, "⚠ " ~ d.tree.filterError, Slot.error);
            else if (d.tree.searching)
            {
                items ~= label(b, text(d.tree.matchCount, " matches"),
                    Slot.info);
                if (d.tree.omittedMatches)
                    items ~= label(b,
                        text(d.tree.omittedMatches, " omitted"), Slot.muted);
                if (d.tree.searchIncomplete)
                    items ~= label(b, "incomplete", Slot.warn);
            }
        }
        else
            items ~= label(b, "/ starts the ranked fuzzy filter", Slot.muted);
        body_ ~= row(b, items);
    }
    body_ ~= spacer(b);

    // ── the tree ────────────────────────────────────────────────────────────
    auto opt = PropertyViewOptions(
        valueColumn: w > 44 ? 26 : 18,
        rangeBarCells: w > 50 ? 8 : 4,
    );
    const treeCol = propertyView(b, d.tree.data, d.tv, d.edits, opt, hitBase);
    // Wide rows clip inside the pane rather than overflowing it.
    const clipped = b.add(Widget(kind: WidgetKind.column,
        children: [treeCol], clipX: true, width: SizeSpec.grow()));
    body_ ~= section(b, "the live tree", [clipped]);
    body_ ~= spacer(b);

    // ── the selected row ────────────────────────────────────────────────────
    if (const n = selectedNode(d))
    {
        uint[] rows_;
        rows_ ~= kv(b, "path", n.path.length ? n.path : "—", 12,
            Slot.chromeAccent);
        rows_ ~= kv(b, "type", n.typeName, 12);
        rows_ ~= kv(b, "kind", n.composite ? "composite" : text(n.kind), 12);
        if (n.doc.length)
            rows_ ~= kv(b, "doc", n.doc, 12, Slot.docs);
        if (n.hasRange)
            rows_ ~= kv(b, "range", text(n.lo, " … ", n.hi,
                n.step > 0 ? text(" step ", n.step) : ""), 12);
        if (n.choices.length)
            rows_ ~= kv(b, "choices", text(n.choices), 12);
        if (n.editor.length)
            rows_ ~= kv(b, "@Editor", n.editor, 12);
        rows_ ~= kv(b, "editable", n.editable ? "yes"
            : d.tree.policy.readOnly ? "no (policy)" : "no", 12,
            n.editable ? Slot.info : Slot.muted);
        if (n.role != SearchRole.none)
        {
            rows_ ~= kv(b, "match", n.role == SearchRole.direct
                ? text("direct · score ", n.score)
                : n.role == SearchRole.context ? "ancestor context"
                : "status row", 12,
                n.role == SearchRole.direct ? Slot.matched : Slot.muted);
            if (n.matched)
                rows_ ~= kv(b, "fields", matchedFieldsText(n.matched), 12);
        }
        const r = d.edits.refusalFor(n.path);
        if (r.refused)
            rows_ ~= kv(b, "refusal", refusalText(r), 12, Slot.error);
        body_ ~= section(b, "selected row", rows_);
        body_ ~= spacer(b);
    }

    // ── the transaction ─────────────────────────────────────────────────────
    {
        uint[] rows_;
        uint[] chips;
        chips ~= chip(b, "read-only policy", d.tree.policy.readOnly);
        chips ~= chip(b, "preview session", d.previewing);
        chips ~= chip(b, d.tree.wasCapped ? "capped" : "under budget",
            d.tree.wasCapped);
        rows_ ~= row(b, chips);
        if (d.edits.pendingActive)
            rows_ ~= kv(b, "pending", text(d.edits.pendingPath, ": ",
                d.edits.pendingBefore.toText, " → ",
                d.edits.pendingLast.toText), 12, Slot.chromeAccent);
        rows_ ~= kv(b, "undo", historyLine(d.edits.undo), 12);
        rows_ ~= kv(b, "redo", historyLine(d.edits.redo), 12);
        if (d.externalPokes)
            rows_ ~= kv(b, "external", text(d.externalPokes,
                " direct writes bypassed history — try u"), 12, Slot.warn);
        body_ ~= section(b, "transaction & history", rows_);
    }
}

private string historyLine(in typeof(PropertyDemo.edits.undo) stack)
{
    if (stack.length == 0)
        return "—";
    auto top = stack[$ - 1];
    return text(stack.length, stack.length == 1 ? " entry" : " entries",
        " · top: ", top.path, " ", top.before.toText, " → ",
        top.after.toText);
}

// ---------------------------------------------------------------------------
// Interaction
// ---------------------------------------------------------------------------

/// The frame step: builds the persistent demo the first time the page is
/// live, so the interactive app never shows a placeholder — and advances the
/// scrollbar hover-expand easing (the bar animates exactly as the tree
/// views' do).
void step(ref GalleryState s, int dtMs)
{
    if (s.page != registry_propertyPageIndex)
        return;
    if (!s.prop.built)
        s.prop.ensure();
    import core.time : msecs;
    import sparkles.input.capability : mousePointer;

    s.prop.tv.tick(mousePointer, dtMs / 1000.0f);
}

/// The live filter's typed-text seam: the shell offers every key here while
/// the filter is active; `true` means the editor consumed it.
bool handleFilterKey(ref GalleryState s, in KeyEvent k)
{
    auto d = &s.prop;
    if (!d.built || !d.tv.searching)
        return false;
    const st = d.tv.filterKey(k);
    if (st == TreeStep.none)
        return false;
    if (st == TreeStep.rebuild)
        d.refresh();
    return true;
}

/// One `+`/`-` (or Enter-on-a-leaf) edit through the generated dispatch.
private void stepEdit(ref PropertyDemo d, int dir)
{
    const n = selectedNode(d);
    if (n is null || n.synthetic || n.composite)
        return;

    Edit e;
    e.path = n.path;
    e.phase = d.previewing ? EditPhase.preview : EditPhase.commit;
    EditValue cur;
    final switch (n.kind)
    {
        case LeafKind.none:
            return;
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
            if (!readValueAt(d.subject, n.path, cur))
                return;
            const stepI = n.hasRange && n.step > 0
                ? cast(long) n.step : 1L;
            e.value = EditValue.of(cur.i + dir * stepI);
            break;
        case LeafKind.floating:
            if (!readValueAt(d.subject, n.path, cur))
                return;
            const stepF = n.hasRange && n.step > 0 ? n.step : 0.1;
            e.value = EditValue.of(cur.f + dir * stepF);
            break;
        case LeafKind.text:
        case LeafKind.opaque:
            // Deliberately a wrong-kind edit: the inline refusal IS the demo
            // (strings wait for the editor spec; opaque is never assignable).
            e.value = EditValue.of(cast(long) dir);
            break;
    }
    cast(void) editProperty(d.subject, e, d.edits, d.tree.policy);
    d.refresh();
}

/// ditto
bool handleCommand(ref GalleryState s, GalleryCommand cmd, ubyte arg)
{
    auto d = &s.prop;

    switch (cmd)
    {
        case GalleryCommand.propDown:
            d.ensure();
            d.tv.moveSel(1);
            return true;
        case GalleryCommand.propUp:
            d.ensure();
            d.tv.moveSel(-1);
            return true;
        case GalleryCommand.propExpand:
        {
            d.ensure();
            const n = selectedNode(*d);
            if (n !is null && n.expandable)
            {
                if (d.tree.searching)
                    d.tv.searchFold = d.tv.searchFold.opened(n.path);
                else
                    d.tv.open = d.tv.open.opened(n.path);
                d.refresh();
            }
            return true;
        }
        case GalleryCommand.propCollapse:
        {
            d.ensure();
            const n = selectedNode(*d);
            if (d.tree.searching)
            {
                // Folding in the search projection is the transient overlay:
                // visibility only, discarded with the query (PRT29).
                if (n !is null && n.expandable)
                {
                    d.tv.searchFold = d.tv.searchFold.closed(n.path);
                    d.refresh();
                }
                return true;
            }
            auto self = &s.prop;
            if (treeCollapseOrUp(d.tv, d.tree.data,
                (uint node) => self.tree.keyOf(node)) == TreeStep.rebuild)
                d.refresh();
            return true;
        }
        case GalleryCommand.propActivate:
        {
            d.ensure();
            const n = selectedNode(*d);
            if (n is null)
                return true;
            if (n.expandable && !d.tree.searching)
            {
                auto self = &s.prop;
                if (treeActivate(d.tv, d.tree.data,
                    (uint node) => self.tree.keyOf(node)) == TreeStep.rebuild)
                    d.refresh();
                return true;
            }
            if (n.kind == LeafKind.boolean || n.kind == LeafKind.enumeration)
                stepEdit(*d, 1);
            return true;
        }
        case GalleryCommand.propInc:
            d.ensure();
            stepEdit(*d, 1);
            return true;
        case GalleryCommand.propDec:
            d.ensure();
            stepEdit(*d, -1);
            return true;
        case GalleryCommand.propPreview:
            d.ensure();
            if (d.previewing)
            {
                // The commit boundary: the group finishes with its last
                // previewed value — one history entry per drag (PRT19).
                cast(void) finishPending(d.subject, d.edits, d.tree.policy);
                d.previewing = false;
            }
            else
                d.previewing = true;
            d.refresh();
            return true;
        case GalleryCommand.propUndo:
            d.ensure();
            cast(void) undoProperty(d.subject, d.edits, d.tree.policy);
            d.refresh();
            return true;
        case GalleryCommand.propRedo:
            d.ensure();
            cast(void) redoProperty(d.subject, d.edits, d.tree.policy);
            d.refresh();
            return true;
        case GalleryCommand.propFilter:
            d.ensure();
            d.tv.filterStart();
            d.refresh();
            return true;
        case GalleryCommand.propMatchNext:
            d.ensure();
            d.tree.jumpMatch(d.tv, 1);
            return true;
        case GalleryCommand.propMatchPrev:
            d.ensure();
            d.tree.jumpMatch(d.tv, -1);
            return true;
        case GalleryCommand.propReveal:
            d.ensure();
            if (d.tree.searching)
                d.tree.revealInBase(d.subject, d.tv);
            return true;
        case GalleryCommand.propPolicy:
            d.ensure();
            d.tree.policy.readOnly = !d.tree.policy.readOnly;
            d.refresh();
            return true;
        case GalleryCommand.propExternal:
            // A write that bypasses the edit path entirely: the next
            // same-path preview refuses staleInteraction, undo/redo refuse
            // staleHistory — instead of replaying over foreign state.
            d.ensure();
            d.externalPokes++;
            d.subject.fill.opacity = 0.11 * ((d.externalPokes % 9) + 1);
            d.refresh();
            return true;
        case GalleryCommand.propOpenAll:
            d.ensure();
            d.tv.open = typeof(d.tv.open).allOpen;
            d.refresh();
            return true;
        case GalleryCommand.propCloseAll:
            d.ensure();
            d.tv.open = typeof(d.tv.open).allClosed;
            d.refresh();
            return true;
        case GalleryCommand.propReset:
            s.prop = PropertyDemo.init;
            s.prop.ensure();
            return true;
        default:
            return false;
    }
}

/// A completed press on a tree row: select it; a press on the already
/// selected row activates (the same meaning as Enter).
bool handleActivate(ref GalleryState s, size_t id)
{
    auto d = &s.prop;
    if (!d.built || id < hitBase)
        return false;
    const node = cast(uint)(id - hitBase);
    if (node >= d.tree.data.nodes.length)
        return false;
    foreach (i, ref const r; d.tv.rows)
        if (r.node == node)
        {
            if (d.tv.sel == cast(long) i)
                return handleCommand(s, GalleryCommand.propActivate, 0);
            d.tv.sel = cast(long) i;
            d.tv.clamp();
            return true;
        }
    return false;
}

// ---------------------------------------------------------------------------
// Tests — the page drives the component exactly as the shell does.
// ---------------------------------------------------------------------------

version (unittest)
{
    import keymap : commandFor, GalleryContext, GalleryScope;

    private bool key(ref GalleryState s, in KeyEvent k) @safe
    {
        if (handleFilterKey(s, k))
            return true;
        const r = commandFor(k, GalleryContext(
            pageScope: GalleryScope.pageProperty, contentRegion: true));
        return handleCommand(s, r.cmd, r.arg);
    }

    private void select(ref GalleryState s, string path) @safe
    {
        foreach (i, ref const r; s.prop.tv.rows)
            if (s.prop.tree.data.nodes[r.node].value.path == path)
                s.prop.tv.sel = cast(long) i;
        s.prop.tv.clamp();
    }
}

@("ui_gallery.pages.propertyEditsGoThroughTheDispatch")
@safe unittest
{
    GalleryState s;
    key(s, KeyEvent(Key.down)); // any key builds
    s.prop.tv.open = s.prop.tv.open.opened("fill");
    s.prop.refresh();

    // A bool toggles; the subject actually changed.
    select(s, "visible");
    key(s, KeyEvent(Key.char_, '+'));
    assert(s.prop.subject.visible == false);

    // A ranged double steps by its @Range step and records history.
    select(s, "fill.opacity");
    key(s, KeyEvent(Key.char_, '-'));
    assert(s.prop.subject.fill.opacity == 0.95);
    assert(s.prop.edits.undo.length == 2);

    // Undo restores through the same dispatch.
    key(s, KeyEvent(Key.char_, 'u'));
    assert(s.prop.subject.fill.opacity == 1.0);

    // The read-only policy refuses everything, inline (PRT16/PRT21).
    key(s, KeyEvent(Key.char_, 'p'));
    key(s, KeyEvent(Key.char_, '-'));
    assert(s.prop.subject.fill.opacity == 1.0);
    assert(s.prop.edits.refusalFor("fill.opacity").refused);
    key(s, KeyEvent(Key.char_, 'p'));
}

@("ui_gallery.pages.propertyPreviewSessionIsOneUndoEntry")
@safe unittest
{
    GalleryState s;
    key(s, KeyEvent(Key.down));
    s.prop.tv.open = s.prop.tv.open.opened("fill");
    s.prop.refresh();
    select(s, "fill.opacity");

    key(s, KeyEvent(Key.char_, 'v')); // preview session on
    foreach (i; 0 .. 4)
        key(s, KeyEvent(Key.char_, '-'));
    import std.math : isClose;
    assert(isClose(s.prop.subject.fill.opacity, 0.8));
    assert(s.prop.edits.undo.length == 0, "previews add no history");
    assert(s.prop.edits.pendingActive);

    key(s, KeyEvent(Key.char_, 'v')); // commit boundary
    assert(s.prop.edits.undo.length == 1, "one entry per drag");
    assert(s.prop.edits.undo[0].before == EditValue.of(1.0));

    key(s, KeyEvent(Key.char_, 'u'));
    assert(s.prop.subject.fill.opacity == 1.0, "one undo per drag");
    // (exact: the entry's before was captured, not re-derived)
}

@("ui_gallery.pages.propertyExternalWriteMakesHistoryStale")
@safe unittest
{
    GalleryState s;
    key(s, KeyEvent(Key.down));
    s.prop.tv.open = s.prop.tv.open.opened("fill");
    s.prop.refresh();
    select(s, "fill.opacity");
    key(s, KeyEvent(Key.char_, '-'));
    assert(s.prop.edits.undo.length == 1);

    key(s, KeyEvent(Key.char_, 'e')); // foreign write, no history
    key(s, KeyEvent(Key.char_, 'u'));
    assert(s.prop.edits.undo.length == 1,
        "undo refused staleHistory instead of replaying");
    assert(s.prop.edits.refusalFor("fill.opacity").refused
        || s.prop.subject.fill.opacity != 0.95);
}

@("ui_gallery.pages.propertyFilterFlowsThroughTheShellSeam")
@safe unittest
{
    GalleryState s;
    key(s, KeyEvent(Key.down));

    key(s, KeyEvent(Key.char_, '/'));
    assert(s.prop.tv.searching);
    foreach (dchar c; "opacity")
        assert(key(s, KeyEvent(Key.char_, c)), "typed text goes to the filter");
    assert(s.prop.tree.searching && s.prop.tree.matchCount >= 1);

    // Down still moves while filtering (the editor declines it).
    const before = s.prop.tv.sel;
    key(s, KeyEvent(Key.down));
    assert(s.prop.tv.sel != before || s.prop.tv.rows.length == 1);

    // Esc restores the disclosure projection.
    key(s, KeyEvent(Key.escape));
    assert(!s.prop.tree.searching);
}

@("ui_gallery.pages.propertyOpenAllMeetsTheCaps")
@safe unittest
{
    GalleryState s;
    key(s, KeyEvent(Key.down));
    key(s, KeyEvent(Key.char_, 'O'));
    assert(s.prop.tree.wasCapped,
        "the linked self-cycle runs into ⋯ (capped)");
    key(s, KeyEvent(Key.char_, 'C'));
    assert(!s.prop.tree.wasCapped);
}
