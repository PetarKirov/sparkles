/**
The panes of an embedder that hosts several terminals (`TSS6`, `TVW7`): each
a heap-pinned `TerminalView`, keyed by an id the embedder mints.

A `TerminalView` cannot move once open — its VT callbacks hold its address —
and it owns a pty and a child process. So the instances live here, behind
pointers that never change, and the embedder's own model (a tab strip, a dock
layout) holds only ids: the model stays a plain value it can copy, compare
and serialize, and the two meet only in the embedder's frame glue.
*/
module sparkles.terminal_view.pool;

import sparkles.terminal_view.component : TerminalView, TerminalViewOptions;

/// At most `capacity` panes, each behind a stable pointer.
struct TerminalPool(size_t capacity)
{
    private TerminalView*[capacity] slots;
    private uint[capacity] slotIds;

    /// The instance behind `id`, or null.
    TerminalView* byId(uint id) @safe pure nothrow @nogc
    {
        foreach (i, slotId; slotIds)
            if (slotId == id && id != 0)
                return slots[i];
        return null;
    }

    /**
    Allocates and pins a fresh instance for `id`, un-opened (only the caller
    knows the host's metrics), with `opts`. Null when the pool is full or
    `id` is 0 or taken.
    */
    TerminalView* create(uint id, TerminalViewOptions opts = TerminalViewOptions.init) @safe
    {
        if (id == 0 || byId(id) !is null)
            return null;
        foreach (i, ref slotId; slotIds)
            if (slotId == 0)
            {
                slotId = id;
                slots[i] = new TerminalView;
                slots[i].opts = opts;
                return slots[i];
            }
        return null;
    }

    /// Closes and releases `id`'s instance (hangs up and reaps its child).
    void closeFor(uint id) @system
    {
        foreach (i, ref slotId; slotIds)
            if (slotId == id && id != 0)
            {
                if (slots[i] !is null)
                    slots[i].close();
                slots[i] = null;
                slotId = 0;
                return;
            }
    }

    /// End of run: every child reaped, every handle freed.
    void closeAll() @system
    {
        foreach (i, ref slotId; slotIds)
        {
            if (slots[i] !is null)
                slots[i].close();
            slots[i] = null;
            slotId = 0;
        }
    }

    /// How many panes are live.
    size_t length() const @safe pure nothrow @nogc
    {
        size_t n;
        foreach (slotId; slotIds)
            n += slotId != 0;
        return n;
    }

    /// Every live pane, for the per-frame pump (`TSS7`).
    int opApply(scope int delegate(uint id, TerminalView* tv) dg)
    {
        foreach (i, slotId; slotIds)
            if (slotId != 0)
                if (const r = dg(slotId, slots[i]))
                    return r;
        return 0;
    }
}

@("terminal_view.pool.slotsMapByIdAndRecycle")
@safe unittest
{
    // Pointer bookkeeping only — no pty is opened, so this runs anywhere.
    TerminalPool!3 pool;
    assert(pool.byId(1) is null);

    auto a = pool.create(1);
    auto b = pool.create(2);
    assert(a !is null && b !is null && a !is b);
    assert(pool.byId(1) is a && pool.byId(2) is b);
    assert(pool.create(2) is null, "an id is one pane");
    assert(pool.create(0) is null, "0 is no id");
    assert(pool.length == 2);

    // An un-opened instance closes as a no-op and frees its slot for reuse.
    () @trusted { pool.closeFor(1); }();
    assert(pool.byId(1) is null);
    assert(pool.byId(2) is b, "closing one pane must not disturb another");
    assert(pool.create(3) !is null && pool.create(4) !is null);
    assert(pool.create(5) is null, "full");

    uint[] seen;
    () @trusted {
        foreach (id, tv; pool)
            seen ~= id;
    }();
    assert(seen.length == 3);

    () @trusted { pool.closeAll(); }();
    assert(pool.byId(2) is null && pool.length == 0);
}
