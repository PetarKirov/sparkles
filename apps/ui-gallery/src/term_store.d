/**
The non-copyable half of the Terminal page's tabs.

$(REF TermsState, state) is the tab strip as a Regular value — what a pure
page view may read. A $(REF TerminalView, sparkles,terminal_view,component)
is the opposite of that: non-copyable, pointer-pinned (the VT effects hold a
pointer into the instance), owning a pty and a child process. So the
instances live here, heap-pinned and keyed by the tab's minted id, and the
two structures meet only in `Gallery`'s frame glue — the page never sees a
pointer, the store never sees a widget.
*/
module term_store;

import sparkles.terminal_view : ExitBehavior, TerminalView, TerminalViewOptions;

import state : maxTerms;

/// ditto
struct TerminalStore
{
    private TerminalView*[maxTerms] slots;
    private uint[maxTerms] slotIds;

    /// The instance behind tab `id`, or null.
    TerminalView* byId(uint id) @safe pure nothrow @nogc
    {
        foreach (i, slotId; slotIds)
            if (slotId == id && id != 0)
                return slots[i];
        return null;
    }

    /**
    Allocates and pins a fresh instance for tab `id`, un-opened — only the
    caller knows the host's metrics. `exitBehavior: hold` always: the
    component must never decide to quit the gallery; the exit policy (and
    its toggle) is the tab model's.
    */
    TerminalView* create(uint id) @safe
    {
        foreach (i, ref slotId; slotIds)
            if (slotId == 0)
            {
                slotId = id;
                slots[i] = new TerminalView;
                slots[i].opts = TerminalViewOptions(
                    exitBehavior: ExitBehavior.hold,
                    // The gallery draws its own bar beside the pane.
                    internalScrollbar: false);
                return slots[i];
            }
        return null;
    }

    /// Closes and releases tab `id`'s instance (reaps the child).
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
}

@("ui_gallery.term_store.slotsMapByIdAndRecycle")
@safe unittest
{
    // Pointer bookkeeping only — no pty is opened, so this runs anywhere.
    TerminalStore store;
    assert(store.byId(1) is null);

    auto a = store.create(1);
    auto b = store.create(2);
    assert(a !is null && b !is null && a !is b);
    assert(store.byId(1) is a && store.byId(2) is b);

    // An un-opened instance closes as a no-op and frees its slot for reuse.
    () @trusted { store.closeFor(1); }();
    assert(store.byId(1) is null);
    assert(store.byId(2) is b, "closing one tab must not disturb another");
    assert(store.create(3) !is null);

    () @trusted { store.closeAll(); }();
    assert(store.byId(2) is null && store.byId(3) is null);
}
