/**
The board's state (`WLD1`–`WLD4`, `DIA5`): entities, their components, the
edges between them, and every piece of interaction the frame carries.

$(B Dense indices, columnar components.) An entity is a `uint` into parallel
columns rather than a pointer to an object, so a render pass walks `bounds`
contiguously instead of chasing a heap of nodes, and an entity id is a plain
value a scripted test can name. Freed slots go on a free list and are reused,
which is why $(LREF alive) exists: an index alone does not say whether anything
is there.

$(B One value holds everything.) Not only the board — the tool, the drag in
progress, the selection, the menu, the label edit, the capture owner. That is
`WLD4`, and it is what makes a scripted session assertable: a test drives
events through the component and then inspects $(I one) struct, rather than
reaching into four systems that each kept a little state of their own.

$(B Fixed capacity, no allocation.) Columns are static arrays sized by
compile-time caps and labels live in fixed `char` slots, so a steady-state
frame allocates nothing (`DIA5`). A full board refuses to spawn rather than
growing — an infinite canvas is unbounded in coordinates, not in content.
*/
module world;

import lantern : LanternState;
import sparkles.base.unique : makeUnique, Unique;
import settings : DiagramSettings;
import sparkles.ui.components.grid_backdrop : GridConfig;
import sparkles.ui.geometry : Point, Rect;

/// The board's caps. A few thousand nodes is past what a diagram stays
/// readable at, and the whole world is then a couple of hundred kilobytes —
/// small enough to live in one value the frame passes around.
enum size_t entityCap = 4096;
/// ditto
enum size_t edgeCap = 8192;
/// ditto — a selection larger than this is a marquee over the whole board,
/// which the MVP does not need to hold element-wise.
enum size_t selectionCap = 512;
/// ditto — one line of label per node, which is what fits in a box.
enum size_t labelCap = 64;

/// An entity handle: an index into the columns. `noEntity` is the absence of
/// one — deliberately not `0`, which is a perfectly good first entity.
alias Entity = uint;
/// ditto
enum Entity noEntity = Entity.max;

/// A group handle. `0` is "no group", which is why grouping counts up from 1.
alias GroupId = uint;

/// Which tool the pointer is driving (`IXN2`).
enum Tool : ubyte
{
    select,  /// click, Shift-toggle, marquee
    rect,    /// drag out a new box
    connect, /// click two entities to join them
}

/// What currently owns the drag. One owner at a time, which is the whole
/// point: the toolkit's capture rule expressed for this board (`IXN1`).
enum Capture : ubyte
{
    none,
    create,       /// dragging out a new rectangle
    marquee,      /// dragging a selection rectangle
    move,         /// dragging the selection
    pan,          /// dragging the camera
    minimapScrub, /// dragging the viewport around the overview
}

/**
The whole board and the whole interaction.

Copyable by value — it is a few hundred kilobytes of static arrays with no
indirection, so a test can snapshot one and compare.
*/
/**
The passkey that makes $(LREF World.create) the only constructor — `private`
to this module, so no other module can name it. The constructor cannot be
`private` itself: $(REF makeUnique, sparkles,base,unique) builds the value in
its own module, where a private constructor is not visible.
*/
private struct WorldKey {}

struct World
{
    /// No stack instances: a `World` is ~442 KiB of dense columns, and a
    /// non-main thread's stack is 512 KiB on macOS. `create` is the way in.
    @disable this();

    /// The real constructor — unreachable without a $(LREF WorldKey).
    this(WorldKey) @safe pure nothrow @nogc {}

    /// A board on the malloc heap, owned by the returned handle.
    static Unique!World create() @safe pure nothrow @nogc
        => makeUnique!World(WorldKey.init);

    // ── entity columns (`WLD1`) ─────────────────────────────────────────────

    /// Each entity's rectangle in $(B world) cells. The board's only geometry.
    Rect[entityCap] bounds;
    /// Paint order within the board stream; ties break by entity index.
    int[entityCap] zOrder;
    /// The group each entity belongs to (`0` = none, `WLD2`).
    GroupId[entityCap] group;
    /// Label text, in fixed slots — `labelLen` is how much of one is live.
    char[labelCap][entityCap] label;
    /// ditto
    ubyte[entityCap] labelLen;
    /// Whether the slot holds an entity at all.
    private bool[entityCap] _alive;

    /// How far the columns have ever been used. Everything above this is
    /// untouched, so a walk stops here rather than at `entityCap`.
    private uint _high;
    /// Freed slots, newest first.
    private Entity[entityCap] _free;
    private uint _freeCount;
    /// The next group id to stamp (`WLD2`); never `0`.
    private GroupId _nextGroup = 1;

    // ── edges (`WLD3`) ──────────────────────────────────────────────────────

    private Entity[edgeCap] _edgeFrom;
    private Entity[edgeCap] _edgeTo;
    private uint _edgeCount;

    // ── interaction (`WLD4`) ────────────────────────────────────────────────

    Tool tool;                       /// the active tool
    Capture capture;                 /// who owns the drag, if anyone
    Point dragStart;                 /// where the drag began (unit depends on capture)
    Point dragNow;                   /// …and where it is now
    Entity hovered = noEntity;       /// the entity under the pointer
    Entity connectFrom = noEntity;   /// the connect tool's pending half
    bool menuOpen;                   /// the context menu is up (`IXN5`)
    Point menuAt;                    /// …anchored here, in screen cells
    Entity editing = noEntity;       /// the entity whose label is being edited
    /**
    In-progress label text (`IXN5`). Same contract as the toolkit's
    $(REF LineEditState, sparkles,ui,state) — type / erase / accept / cancel —
    but over a fixed slot so the frame stays allocation-free (`DIA5`).
    */
    char[labelCap] editBuf;
    /// ditto
    ubyte editLen;
    /**
    Everything the settings pane edits (`SET4`): the backdrop configuration
    (`GRD7`) and the board preferences that are also runtime toggles.

    $(B One value, not a copy the pane edits and writes back.) The pane is a
    $(REF PropertyTree, sparkles,ui,property_tree) over exactly this field, so
    a committed edit lands in the running board immediately (`SET3`) and there
    is no second declaration of any setting to drift. `gridConfig` and
    `minimapVisible` remain as `ref` accessors below, so the systems that read
    them never learned this moved.
    */
    DiagramSettings settings;
    /**
    The key guide's machine (`LTN`): which chords are pending and whether the
    panel shows. Interaction state like every other field here (`WLD4`) — the
    render side reads it, and a scripted test can assert on it.
    */
    LanternState lantern;
    /**
    The settings pane is up (`SET2`).

    Only the flag lives here: it is what $(REF DiagramContext, keymap) reads to
    reach the modal scope, and what the render side tests. The pane's own
    machinery — the property tree, its rows, its edit history — is GC state on
    the app, deliberately outside this `@nogc` world (`DIA5`).
    */
    bool settingsOpen;
    /**
    Space is down (or sticky-armed on a target without key releases).

    The pan binding is Space+LMB (`IXN3`), and a terminal cannot report a key
    up (`INP16`). On a target that can, this tracks the hold; on one that
    cannot, a Space press arms it and the pan's release (or a second Space)
    clears it — same binding, a route that does not need a release.
    */
    bool spaceDown;

    /// The selection, as a capped list of live entities.
    Entity[selectionCap] selection;
    /// ditto
    uint selectionCount;

@safe pure nothrow @nogc:

    // ── entities ────────────────────────────────────────────────────────────

    /// The highest slot ever used — the bound of every column walk.
    uint highWater() const scope => _high;

    /// The backdrop configuration (`GRD7`), where the pane keeps it (`SET4`).
    ref inout(GridConfig) gridConfig() inout return => settings.grid;

    /// Whether the minimap shows (`IXN4`); `m` toggles it, and so does the pane.
    ref inout(bool) minimapVisible() inout return => settings.board.minimap;

    /// Whether `e` names a live entity. An index alone cannot say: slots are
    /// recycled, so a stale handle points at somebody else's rectangle.
    bool alive(Entity e) const scope => e < _high && _alive[e];

    /// How many entities are live.
    uint count() const scope
    {
        uint n;
        foreach (e; 0 .. _high)
            if (_alive[e])
                ++n;
        return n;
    }

    /**
    Creates an entity covering `r`. Returns `noEntity` when the board is full.

    Refusing beats growing: the columns are what make the frame allocation-free
    (`DIA5`), and a board at four thousand nodes has a content problem rather
    than a capacity one.
    */
    Entity spawn(in Rect r) scope
    {
        Entity e;
        if (_freeCount > 0)
            e = _free[--_freeCount];
        else if (_high < entityCap)
            e = _high++;
        else
            return noEntity;

        _alive[e] = true;
        bounds[e] = r;
        zOrder[e] = cast(int) e;
        group[e] = 0;
        labelLen[e] = 0;
        return e;
    }

    /**
    Removes `e` and every edge touching it (`WLD3`).

    The cascade is the point: an edge to a slot that has been recycled would
    draw a connector to whatever entity landed there next, which is worse than
    a dangling pointer because it looks deliberate.
    */
    void despawn(Entity e) scope
    {
        if (!alive(e))
            return;
        _alive[e] = false;
        labelLen[e] = 0;
        group[e] = 0;
        _free[_freeCount++] = e;
        removeEdgesTouching(e);
        deselect(e);
        if (hovered == e) hovered = noEntity;
        if (connectFrom == e) connectFrom = noEntity;
        if (editing == e)
        {
            editing = noEntity;
            editLen = 0;
        }
    }

    /// Sets `e`'s label, truncated to the slot.
    void setLabel(Entity e, scope const(char)[] text) scope
    {
        if (!alive(e))
            return;
        const n = text.length > labelCap ? labelCap : text.length;
        label[e][0 .. n] = text[0 .. n];
        labelLen[e] = cast(ubyte) n;
    }

    /// `e`'s label, or an empty slice.
    const(char)[] labelOf(Entity e) const scope return
        => alive(e) ? label[e][0 .. labelLen[e]] : null;

    // ── label edit (`IXN5`) ─────────────────────────────────────────────────

    /// Whether a label edit is in progress.
    bool isEditing() const scope => editing != noEntity;

    /// The live edit buffer, or empty when not editing.
    const(char)[] editText() const scope return
        => isEditing ? editBuf[0 .. editLen] : null;

    /**
    Opens a label edit on `e`, seeding the buffer from its current label.

    Closes any prior edit without committing — switching targets mid-edit
    discards the draft, which matches a cancelled LineEditState.
    */
    void beginEdit(Entity e) scope
    {
        if (!alive(e))
            return;
        editing = e;
        editLen = labelLen[e];
        if (editLen)
            editBuf[0 .. editLen] = label[e][0 .. editLen];
    }

    /// Appends a printable code point (ASCII for the MVP slot). Controls ignored.
    void editType(dchar c) scope
    {
        if (!isEditing || c < 0x20 || c == 0x7f || c > 0x7e)
            return;
        if (editLen >= labelCap)
            return;
        editBuf[editLen++] = cast(char) c;
    }

    /// Backspace: drops the last byte (ASCII labels only in the MVP).
    void editErase() scope
    {
        if (!isEditing || editLen == 0)
            return;
        --editLen;
    }

    /// Enter: commit the buffer to the entity's label slot and stop editing.
    void editCommit() scope
    {
        if (!isEditing)
            return;
        setLabel(editing, editBuf[0 .. editLen]);
        editing = noEntity;
        editLen = 0;
    }

    /// Esc / cancel: discard the draft and stop editing.
    void editCancel() scope
    {
        editing = noEntity;
        editLen = 0;
    }

    // ── groups (`WLD2`) ─────────────────────────────────────────────────────

    /**
    Stamps a fresh group id on the selection. Returns `0` when there is
    nothing (or only one thing) to group.

    Flat by design: a group id is a column value, not a tree. Nesting is a
    non-goal for the MVP, and a flat id makes "move every member" a single
    column scan instead of a traversal.
    */
    GroupId groupSelection() scope
    {
        if (selectionCount < 2)
            return 0;
        const g = _nextGroup++;
        foreach (i; 0 .. selectionCount)
            group[selection[i]] = g;
        return g;
    }

    /// Clears the group of every selected entity.
    void ungroupSelection() scope
    {
        foreach (i; 0 .. selectionCount)
            group[selection[i]] = 0;
    }

    /// Moves `e` by a world-cell delta — and every member of its group with
    /// it (`WLD2`), which is what makes a group one thing to drag.
    void moveBy(Entity e, int dx, int dy) scope
    {
        if (!alive(e))
            return;
        const g = group[e];
        if (g == 0)
        {
            shift(e, dx, dy);
            return;
        }
        foreach (other; 0 .. _high)
            if (_alive[other] && group[other] == g)
                shift(cast(Entity) other, dx, dy);
    }

    /**
    Moves every selected entity by a world-cell delta, once per group.

    `moveBy` already fans out to group members, so walking the selection
    naively would double-move any group that had two members selected. This
    is the drag's one-step: each ungrouped entity once, each group once.
    */
    void moveSelectionBy(int dx, int dy) scope
    {
        if (dx == 0 && dy == 0)
            return;
        // Groups already applied this step. 0 is "no group", and is never
        // written here — ungrouped entities always go through.
        GroupId[selectionCap] seen;
        uint seenN;
        foreach (i; 0 .. selectionCount)
        {
            const e = selection[i];
            if (!alive(e))
                continue;
            const g = group[e];
            if (g != 0)
            {
                bool already;
                foreach (j; 0 .. seenN)
                    if (seen[j] == g)
                    {
                        already = true;
                        break;
                    }
                if (already)
                    continue;
                if (seenN < selectionCap)
                    seen[seenN++] = g;
            }
            moveBy(e, dx, dy);
        }
    }

    private void shift(Entity e, int dx, int dy) scope
    {
        bounds[e] = Rect(bounds[e].x + dx, bounds[e].y + dy,
            bounds[e].width, bounds[e].height);
    }

    // ── edges (`WLD3`) ──────────────────────────────────────────────────────

    /// How many edges exist.
    uint edgeCount() const scope => _edgeCount;
    /// The endpoints of edge `i`.
    Entity edgeFrom(uint i) const scope => _edgeFrom[i];
    /// ditto
    Entity edgeTo(uint i) const scope => _edgeTo[i];

    /**
    Joins two live, distinct entities. Returns `false` when it refused —
    full, dead, self-directed, or already joined.

    Duplicates are refused rather than drawn twice: a second identical
    connector is invisible and would only ever surprise on delete.
    */
    bool connect(Entity from, Entity to) scope
    {
        if (!alive(from) || !alive(to) || from == to || _edgeCount >= edgeCap)
            return false;
        foreach (i; 0 .. _edgeCount)
            if (_edgeFrom[i] == from && _edgeTo[i] == to)
                return false;
        _edgeFrom[_edgeCount] = from;
        _edgeTo[_edgeCount] = to;
        ++_edgeCount;
        return true;
    }

    /// Drops every edge with `e` at either end. Order is not preserved —
    /// nothing reads it, and swap-remove keeps this O(n).
    private void removeEdgesTouching(Entity e) scope
    {
        uint i;
        while (i < _edgeCount)
            if (_edgeFrom[i] == e || _edgeTo[i] == e)
            {
                --_edgeCount;
                _edgeFrom[i] = _edgeFrom[_edgeCount];
                _edgeTo[i] = _edgeTo[_edgeCount];
            }
            else
                ++i;
    }

    // ── selection (`WLD4`) ──────────────────────────────────────────────────

    /// Whether `e` is selected.
    bool selected(Entity e) const scope
    {
        foreach (i; 0 .. selectionCount)
            if (selection[i] == e)
                return true;
        return false;
    }

    /// Adds `e` if it is live and not already there (and there is room).
    void select(Entity e) scope
    {
        if (!alive(e) || selected(e) || selectionCount >= selectionCap)
            return;
        selection[selectionCount++] = e;
    }

    /// Removes `e` from the selection, if it is there.
    void deselect(Entity e) scope
    {
        foreach (i; 0 .. selectionCount)
            if (selection[i] == e)
            {
                --selectionCount;
                selection[i] = selection[selectionCount];
                return;
            }
    }

    /// Adds or removes `e` — what a Shift-click does.
    void toggleSelect(Entity e) scope
    {
        if (selected(e))
            deselect(e);
        else
            select(e);
    }

    /// ditto
    void clearSelection() scope { selectionCount = 0; }

    /// Selects exactly `e`.
    void selectOnly(Entity e) scope
    {
        clearSelection();
        select(e);
    }

    /// Deletes every selected entity, edges and all.
    void deleteSelection() scope
    {
        // Copied out first: `despawn` deselects, which rewrites the list
        // underneath a walk over it.
        Entity[selectionCap] doomed;
        const n = selectionCount;
        doomed[0 .. n] = selection[0 .. n];
        foreach (i; 0 .. n)
            despawn(doomed[i]);
        clearSelection();
    }

    // ── queries the systems ask ─────────────────────────────────────────────

    /**
    The topmost live entity containing `world`, or `noEntity`.

    Topmost by `zOrder`, ties by index — the same order the board paints in,
    so what a click finds is what a user sees on top.
    */
    Entity pick(in Point world) const scope
    {
        Entity best = noEntity;
        int bestZ = int.min;
        foreach (e; 0 .. _high)
        {
            if (!_alive[e] || !bounds[e].contains(world))
                continue;
            if (best == noEntity || zOrder[e] >= bestZ)
            {
                best = cast(Entity) e;
                bestZ = zOrder[e];
            }
        }
        return best;
    }

    /// Selects every live entity intersecting `area` — the marquee's commit.
    void selectWithin(in Rect area) scope
    {
        foreach (e; 0 .. _high)
            if (_alive[e] && !bounds[e].intersection(area).empty)
                select(cast(Entity) e);
    }

    /// The drag rectangle so far, normalized so a drag in any direction is a
    /// rectangle rather than a negative size.
    Rect dragRect() const scope
    {
        const x0 = dragStart.x < dragNow.x ? dragStart.x : dragNow.x;
        const y0 = dragStart.y < dragNow.y ? dragStart.y : dragNow.y;
        const x1 = dragStart.x > dragNow.x ? dragStart.x : dragNow.x;
        const y1 = dragStart.y > dragNow.y ? dragStart.y : dragNow.y;
        return Rect(x0, y0, x1 - x0 + 1, y1 - y0 + 1);
    }
}

/// Every live entity's rectangle, into `sink` — what `contentBounds` and the
/// minimap measure. Returns how many were written.
size_t liveBounds(ref const World w, scope Rect[] sink) @safe pure nothrow @nogc
{
    size_t n;
    foreach (e; 0 .. w.highWater)
    {
        if (n == sink.length)
            break;
        if (w.alive(cast(Entity) e))
            sink[n++] = w.bounds[e];
    }
    return n;
}

// ---------------------------------------------------------------------------
// Tests. Runtime, like the camera's — `Rect` is union-backed geometry.
// ---------------------------------------------------------------------------

@("diagram.world.spawnRecyclesFreedSlots")
@safe pure nothrow @nogc
unittest
{
    // `WLD1`: a free list, so a board churning through nodes does not walk
    // further every time. The recycled index is the same one — which is also
    // why `alive` has to exist.
    auto wOwner = World.create();
    ref World w() => wOwner.get();
    const a = w.spawn(Rect(0, 0, 4, 2));
    const b = w.spawn(Rect(9, 9, 4, 2));
    assert(a == 0 && b == 1 && w.count == 2 && w.highWater == 2);

    w.despawn(a);
    assert(!w.alive(a) && w.count == 1);
    assert(w.highWater == 2, "the column high-water mark does not shrink");

    const c = w.spawn(Rect(1, 1, 2, 2));
    assert(c == a, "the freed slot came back");
    assert(w.count == 2 && w.highWater == 2);
    assert(w.bounds[c] == Rect(1, 1, 2, 2), "and was re-initialized");
}

@("diagram.world.spawnRefusesRatherThanGrowing")
@safe pure nothrow @nogc
unittest
{
    // `DIA5`: fixed columns are what make the frame allocation-free, so a
    // full board says no. Growing would move the whole design.
    auto wOwner = World.create();
    ref World w() => wOwner.get();
    foreach (_; 0 .. entityCap)
        assert(w.spawn(Rect(0, 0, 1, 1)) != noEntity);
    assert(w.spawn(Rect(0, 0, 1, 1)) == noEntity);
    assert(w.count == entityCap);
}

@("diagram.world.despawnCascadesToEdges")
@safe pure nothrow @nogc
unittest
{
    // `WLD3`, and the reason it is not optional: slots are recycled, so an
    // edge to a dead entity would draw a connector to whoever lands there
    // next — worse than a dangling pointer, because it looks deliberate.
    auto wOwner = World.create();
    ref World w() => wOwner.get();
    const a = w.spawn(Rect(0, 0, 2, 2));
    const b = w.spawn(Rect(8, 0, 2, 2));
    const c = w.spawn(Rect(0, 8, 2, 2));
    assert(w.connect(a, b) && w.connect(b, c) && w.connect(c, a));
    assert(w.edgeCount == 3);

    w.despawn(b);
    assert(w.edgeCount == 1, "both edges touching b are gone");
    assert(w.edgeFrom(0) == c && w.edgeTo(0) == a);

    // The recycled slot inherits nothing.
    const d = w.spawn(Rect(4, 4, 2, 2));
    assert(d == b && w.edgeCount == 1);
}

@("diagram.world.connectRefusesTheDegenerateCases")
@safe pure nothrow @nogc
unittest
{
    auto wOwner = World.create();
    ref World w() => wOwner.get();
    const a = w.spawn(Rect(0, 0, 2, 2));
    const b = w.spawn(Rect(8, 0, 2, 2));

    assert(!w.connect(a, a), "an entity does not connect to itself");
    assert(!w.connect(a, noEntity));
    assert(w.connect(a, b));
    assert(!w.connect(a, b), "a duplicate would be invisible and surprise on delete");
    assert(w.connect(b, a), "…but the other direction is a different edge");
    assert(w.edgeCount == 2);
}

@("diagram.world.groupMovesTogether")
@safe pure nothrow @nogc
unittest
{
    // `WLD2`: a flat id, so "move every member" is a column scan.
    auto wOwner = World.create();
    ref World w() => wOwner.get();
    const a = w.spawn(Rect(0, 0, 4, 2));
    const b = w.spawn(Rect(10, 0, 4, 2));
    const loose = w.spawn(Rect(20, 0, 4, 2));

    w.select(a);
    w.select(b);
    const g = w.groupSelection();
    assert(g != 0 && w.group[a] == g && w.group[b] == g);
    assert(w.group[loose] == 0);

    // Dragging one member drags the group, and nothing else.
    w.moveBy(a, 3, -1);
    assert(w.bounds[a] == Rect(3, -1, 4, 2));
    assert(w.bounds[b] == Rect(13, -1, 4, 2));
    assert(w.bounds[loose] == Rect(20, 0, 4, 2));

    // Ungrouped, they move apart again.
    w.ungroupSelection();
    w.moveBy(a, 1, 0);
    assert(w.bounds[a] == Rect(4, -1, 4, 2));
    assert(w.bounds[b] == Rect(13, -1, 4, 2), "no longer a member");
}

@("diagram.world.groupNeedsTwo")
@safe pure nothrow @nogc
unittest
{
    // A group of one is a node with extra state and an outline nobody asked
    // for; a group of none is nothing at all.
    auto wOwner = World.create();
    ref World w() => wOwner.get();
    const a = w.spawn(Rect(0, 0, 2, 2));
    assert(w.groupSelection() == 0, "nothing selected");
    w.select(a);
    assert(w.groupSelection() == 0, "one is not a group");
    assert(w.group[a] == 0);
}

@("diagram.world.selectionIsASetAndSurvivesDeletion")
@safe pure nothrow @nogc
unittest
{
    auto wOwner = World.create();
    ref World w() => wOwner.get();
    const a = w.spawn(Rect(0, 0, 2, 2));
    const b = w.spawn(Rect(4, 0, 2, 2));

    w.select(a);
    w.select(a);
    assert(w.selectionCount == 1, "a set, not a list");

    w.toggleSelect(b);
    assert(w.selectionCount == 2 && w.selected(b));
    w.toggleSelect(b);
    assert(w.selectionCount == 1 && !w.selected(b));

    // Deleting a selected entity takes it out of the selection too —
    // otherwise the next group or move would name a recycled slot.
    w.select(b);
    w.despawn(b);
    assert(!w.selected(b) && w.selectionCount == 1);

    w.selectOnly(a);
    assert(w.selectionCount == 1 && w.selected(a));
}

@("diagram.world.deleteSelectionWalksACopy")
@safe pure nothrow @nogc
unittest
{
    // `despawn` deselects, which rewrites the list underneath a walk over it.
    // The bug this guards is silent: a swap-remove during iteration skips
    // whichever entity was moved into the vacated slot.
    auto wOwner = World.create();
    ref World w() => wOwner.get();
    Entity[8] made;
    foreach (i; 0 .. 8)
    {
        made[i] = w.spawn(Rect(cast(int) i * 4, 0, 3, 2));
        w.select(made[i]);
    }
    assert(w.selectionCount == 8);

    w.deleteSelection();
    assert(w.selectionCount == 0);
    assert(w.count == 0, "every one of them, not every other one");
    foreach (e; made)
        assert(!w.alive(e));
}

@("diagram.world.pickAnswersTheTopmost")
@safe pure nothrow @nogc
unittest
{
    // What a click finds must be what the board painted on top, or the two
    // disagree and every overlap becomes a coin flip.
    auto wOwner = World.create();
    ref World w() => wOwner.get();
    const under = w.spawn(Rect(0, 0, 10, 6));
    const over = w.spawn(Rect(2, 2, 4, 2));

    assert(w.pick(Point(0, 0)) == under);
    assert(w.pick(Point(3, 3)) == over, "the later entity paints over");
    assert(w.pick(Point(50, 50)) == noEntity);

    // z-order beats index.
    w.zOrder[under] = 10;
    assert(w.pick(Point(3, 3)) == under);
}

@("diagram.world.marqueeSelectsIntersecting")
@safe pure nothrow @nogc
unittest
{
    // Intersecting, not contained: a marquee that only took fully-enclosed
    // nodes would refuse to select a node bigger than the screen.
    auto wOwner = World.create();
    ref World w() => wOwner.get();
    const inside = w.spawn(Rect(2, 2, 2, 2));
    const touching = w.spawn(Rect(9, 9, 6, 6));
    const outside = w.spawn(Rect(40, 40, 2, 2));

    w.selectWithin(Rect(0, 0, 12, 12));
    assert(w.selected(inside) && w.selected(touching) && !w.selected(outside));
}

@("diagram.world.dragRectNormalizesEveryDirection")
@safe pure nothrow @nogc
unittest
{
    // A drag up-and-left is a rectangle, not a negative size — and both ends
    // are inclusive, so a click that never moved is one cell rather than none.
    auto wOwner = World.create();
    ref World w() => wOwner.get();
    w.dragStart = Point(10, 10);
    w.dragNow = Point(4, 4);
    assert(w.dragRect == Rect(4, 4, 7, 7));

    w.dragNow = Point(10, 10);
    assert(w.dragRect == Rect(10, 10, 1, 1));
}

@("diagram.world.liveBoundsSkipsFreedSlots")
@safe pure nothrow @nogc
unittest
{
    // What the minimap and fit-all measure. A freed slot keeps its stale
    // rectangle in the column, so a walk that trusted the column would fit
    // the camera to a node that is not there.
    auto wOwner = World.create();
    ref World w() => wOwner.get();
    const a = w.spawn(Rect(0, 0, 4, 4));
    const b = w.spawn(Rect(100, 100, 4, 4));
    w.despawn(b);
    const c = w.spawn(Rect(-20, 8, 2, 2));
    assert(c == b, "the slot was recycled…");

    Rect[8] sink;
    const n = liveBounds(w, sink[]);
    assert(n == 2);

    import camera : contentBounds;

    assert(contentBounds(sink[0 .. n]) == Rect(-20, 0, 24, 10));
    assert(w.alive(a) && w.alive(c));
}

@("diagram.world.labelEditCommitAndCancel")
@safe pure nothrow @nogc
unittest
{
    // `IXN5`: LineEditState contract over a fixed slot — type, erase, accept,
    // cancel — without allocating.
    auto wOwner = World.create();
    ref World w() => wOwner.get();
    const e = w.spawn(Rect(0, 0, 8, 2));
    w.setLabel(e, "ab");
    w.beginEdit(e);
    assert(w.isEditing && w.editText == "ab");
    w.editType('c');
    w.editErase(); // drop c
    w.editType('x');
    w.editCommit();
    assert(!w.isEditing && w.labelOf(e) == "abx");

    w.beginEdit(e);
    w.editType('z');
    w.editCancel();
    assert(!w.isEditing && w.labelOf(e) == "abx", "cancel discards the draft");
}

@("diagram.world.moveSelectionByMovesEachGroupOnce")
@safe pure nothrow @nogc
unittest
{
    // The drag's one-step: `moveBy` fans out to group members, so a naive
    // walk over the selection would double-move any group with two members
    // selected.
    auto wOwner = World.create();
    ref World w() => wOwner.get();
    const a = w.spawn(Rect(0, 0, 2, 2));
    const b = w.spawn(Rect(4, 0, 2, 2));
    const loose = w.spawn(Rect(20, 0, 2, 2));
    w.select(a);
    w.select(b);
    w.select(loose);
    assert(w.groupSelection() != 0);

    w.moveSelectionBy(3, 1);
    assert(w.bounds[a] == Rect(3, 1, 2, 2));
    assert(w.bounds[b] == Rect(7, 1, 2, 2), "group moved once, not twice");
    assert(w.bounds[loose] == Rect(23, 1, 2, 2));
}
