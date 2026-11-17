/**
Clipboard replies routed to the input that asked for them.

A host answers a clipboard read (`INP25`) later, as `PasteEvent` chunks
carrying the read's request. By then the input that asked may be gone: its
tab closed, its dialog dismissed, its palette reopened. $(LREF ClipboardRouter)
remembers, for every read it issued, an application-defined owner, joins the
reply's chunks, and hands the completed text only to an owner that is still
live.

The router is a shell with hooks (design by introspection): the application
keeps its owner type and its validity rules, and passes a hooks object that
answers three questions.

$(LIST
    * `bool valid(in Owner owner)` — $(B required.) Whether `owner` may still
        receive text. Asked before a read is issued, for every pending read
        each time a new one is issued (stale ones are dropped), and before
        every chunk of a reply.
    * `void deliver(in Owner owner, scope const(char)[] text)` — $(B required
        by `receive`.) The completed paste, for a live owner.
    * `Owner unsolicited()` — $(B optional.) The owner of a paste nobody asked
        for (`request == 0`, a terminal's bracketed paste), chosen when its
        first chunk arrives. Without it such pastes are dropped.
)
*/
module sparkles.ui_app.clipboard_router;

import sparkles.base.buffer : UniqueBuffer;
import sparkles.input : PasteEvent;

/// Why $(LREF ClipboardRouter.route) issued no request.
enum ClipboardRefusal : ubyte
{
    none,           /// A request was issued.
    invalidOwner,   /// The asking owner failed its own `valid` check.
    full,           /// Every slot holds a live pending read.
    exhausted,      /// The request identity space is used up.
}

/// The outcome of $(LREF ClipboardRouter.route): a host request, or the reason there is none.
struct ClipboardTicket
{
    /// The request to pass to `host.readClipboard`; 0 when refused.
    uint request;
    /// ditto
    ClipboardRefusal refusal;

    /// Whether a request was issued.
    bool opCast(T : bool)() const @safe pure nothrow @nogc => request != 0;
}

/// What one chunk fed to $(LREF ClipboardRouter.receive) did.
enum PasteOutcome : ubyte
{
    collecting, /// The chunk was retained; the paste is not complete yet.
    delivered,  /// The paste completed and its owner received it.
    dropped,    /// The reply has no pending owner (unknown, stale or unsolicited without a hook).
    cancelled,  /// The owner stopped being valid while its reply arrived; nothing was delivered.
}

/// Whether `Hooks` answers `valid` for `Owner`.
enum bool isClipboardValidity(Hooks, Owner) = __traits(compiles, (ref Hooks h, ref const Owner o) {
    bool live = h.valid(o);
});

/// Whether `Hooks` can receive a completed paste for `Owner`.
enum bool isClipboardDelivery(Hooks, Owner) = isClipboardValidity!(Hooks, Owner)
    && __traits(compiles, (ref Hooks h, ref const Owner o, scope const(char)[] text) {
        h.deliver(o, text);
    });

/// Whether `Hooks` names an owner for pastes nobody requested.
enum bool hasUnsolicitedOwner(Hooks, Owner) = __traits(compiles, (ref Hooks h) {
    Owner o = h.unsolicited();
});

/**
Pending clipboard reads, each retained with the `Owner` that asked, and the
reply being joined.

`capacity` bounds the reads outstanding at once; a new read first drops every
pending one whose owner is no longer valid. Request identities come from the
host's `allocateClipboardRequest()` when it offers one — the namespace shared
by every consumer of a native session — and otherwise from a counter of the
router's own.

Not copyable: the joined reply owns its bytes.
*/
struct ClipboardRouter(Owner, size_t capacity = 64)
if (capacity > 0)
{
    private static struct Pending
    {
        uint request;
        Owner owner;
    }

    private Pending[capacity] pending;
    private UniqueBuffer!char bytes;
    private Owner collectingOwner;
    private uint collectingRequest, nextRequest;
    private bool collecting;

    /// Reads issued and not yet answered or dropped.
    size_t pendingCount() const @safe pure nothrow @nogc
    {
        size_t count;
        foreach (ref slot; pending) count += slot.request != 0;
        return count;
    }

    /// Whether `request` is a read still waiting for its reply.
    bool isPending(uint request) const @safe pure nothrow @nogc
        => request != 0 && find(request) < capacity;

    /**
    Issue a read for `owner`, provided `hooks.valid(owner)`. Pending reads
    whose owners are no longer valid are dropped first. The returned request
    is what the caller passes to `host.readClipboard`; a refusal says why
    there is none.
    */
    ClipboardTicket route(Host, Hooks)(ref Host host, Owner owner, ref Hooks hooks)
    if (isClipboardValidity!(Hooks, Owner))
    {
        if (!hooks.valid(owner)) return ClipboardTicket(0, ClipboardRefusal.invalidOwner);
        size_t free = capacity;
        foreach (index, ref slot; pending)
        {
            if (slot.request && !hooks.valid(slot.owner)) slot = Pending.init;
            if (!slot.request && free == capacity) free = index;
        }
        if (free == capacity) return ClipboardTicket(0, ClipboardRefusal.full);
        uint request;
        static if (__traits(compiles, host.allocateClipboardRequest()))
            request = host.allocateClipboardRequest();
        else if (nextRequest != uint.max)
            request = ++nextRequest;
        if (!request) return ClipboardTicket(0, ClipboardRefusal.exhausted);
        pending[free] = Pending(request, owner);
        return ClipboardTicket(request);
    }

    /**
    Feed one paste chunk. Chunks of one reply are joined; a chunk of a
    different reply abandons the one being joined. The owner is checked before
    every chunk, and the completed text goes to `hooks.deliver` only while the
    owner is valid. A reply is consumed once: its request stops being pending
    when it completes, is cancelled, or is abandoned.
    */
    PasteOutcome receive(Hooks)(in PasteEvent chunk, ref Hooks hooks)
    if (isClipboardDelivery!(Hooks, Owner))
    {
        if (chunk.request && !isPending(chunk.request))
        {
            if (collecting && collectingRequest == chunk.request) stopCollecting();
            return PasteOutcome.dropped;
        }
        if (!collecting || chunk.request != collectingRequest)
        {
            if (collecting) forget(collectingRequest);
            bytes.clear();
            if (chunk.request) collectingOwner = pending[find(chunk.request)].owner;
            else
            {
                static if (hasUnsolicitedOwner!(Hooks, Owner))
                    collectingOwner = hooks.unsolicited();
                else
                {
                    collecting = false;
                    return PasteOutcome.dropped;
                }
            }
            collecting = true;
            collectingRequest = chunk.request;
        }
        if (!hooks.valid(collectingOwner))
        {
            forget(collectingRequest);
            stopCollecting();
            return PasteOutcome.cancelled;
        }
        bytes ~= chunk.text[];
        if (!chunk.last) return PasteOutcome.collecting;
        collecting = false;
        const request = collectingRequest;
        scope (exit)
        {
            bytes.clear();
            forget(request);
        }
        hooks.deliver(collectingOwner, bytes[]);
        return PasteOutcome.delivered;
    }

    private size_t find(uint request) const @safe pure nothrow @nogc
    {
        foreach (index, ref slot; pending)
            if (slot.request == request) return index;
        return capacity;
    }

    private void forget(uint request) @safe pure nothrow @nogc
    {
        if (!request) return;
        const index = find(request);
        if (index < capacity) pending[index] = Pending.init;
    }

    private void stopCollecting() @safe pure nothrow @nogc
    {
        collecting = false;
        bytes.clear();
    }
}

version (unittest)
{
    // A fake owner: a target and the epoch it was opened at.
    private struct FakeOwner
    {
        uint target;
        uint epoch;
    }

    private struct FakeHooks
    {
        uint[4] epochs = [1, 1, 1, 1];
        uint focus;
        string[4] received;

        bool valid(in FakeOwner owner) const @safe pure nothrow @nogc
            => owner.target < epochs.length && epochs[owner.target] == owner.epoch;
        void deliver(in FakeOwner owner, scope const(char)[] text) @safe pure nothrow
        { received[owner.target] ~= text; }
        FakeOwner unsolicited() const @safe pure nothrow @nogc => FakeOwner(focus, epochs[focus]);
    }

    private struct LocalHost {}

    private PasteOutcome feed(R)(ref R router, ref FakeHooks hooks, scope const(char)[] text, uint request)
    {
        import sparkles.input : Event, match, pasteChunks;
        PasteOutcome last;
        pasteChunks(text, (in Event event) {
            event.match!((in PasteEvent chunk) { last = router.receive(chunk, hooks); }, (in _) {});
        }, request);
        return last;
    }
}

/// A reply reaches the owner that asked, even when another owner asked later.
@("ui_app.clipboardRouter.deliversToTheAskingOwner")
@safe pure nothrow unittest
{
    ClipboardRouter!FakeOwner router;
    FakeHooks hooks;
    LocalHost host;
    const a = router.route(host, FakeOwner(0, 1), hooks);
    const b = router.route(host, FakeOwner(1, 1), hooks);
    assert(a && b && a.request != b.request && router.pendingCount == 2);
    assert(feed(router, hooks, "to b", b.request) == PasteOutcome.delivered);
    assert(feed(router, hooks, "to a", a.request) == PasteOutcome.delivered);
    assert(hooks.received[0] == "to a" && hooks.received[1] == "to b");
    assert(feed(router, hooks, "again", a.request) == PasteOutcome.dropped, "a reply counts once");
    assert(hooks.received[0] == "to a" && router.pendingCount == 0);
}

/// An owner that stops being valid never receives its late reply.
@("ui_app.clipboardRouter.staleOwnerIsCancelled")
@safe pure nothrow unittest
{
    ClipboardRouter!FakeOwner router;
    FakeHooks hooks;
    LocalHost host;
    const ticket = router.route(host, FakeOwner(2, 1), hooks);
    hooks.epochs[2] = 2; // the requester closed; its slot was reused
    assert(feed(router, hooks, "late", ticket.request) == PasteOutcome.cancelled);
    assert(!hooks.received[2].length && !router.isPending(ticket.request));
    assert(router.route(host, FakeOwner(2, 1), hooks).refusal == ClipboardRefusal.invalidOwner);
}

/// Chunks join into one delivery; an interleaved reply abandons the partial one.
@("ui_app.clipboardRouter.joinsChunks")
@safe pure nothrow unittest
{
    import sparkles.input : Event, match, pasteChunkBytes, pasteChunks;
    ClipboardRouter!FakeOwner router;
    FakeHooks hooks;
    LocalHost host;
    auto long_ = new char[pasteChunkBytes * 2 + 3];
    long_[] = 'x';
    const whole = router.route(host, FakeOwner(0, 1), hooks);
    assert(feed(router, hooks, long_, whole.request) == PasteOutcome.delivered);
    assert(hooks.received[0] == long_);

    const first = router.route(host, FakeOwner(1, 1), hooks);
    const second = router.route(host, FakeOwner(3, 1), hooks);
    PasteEvent part;
    pasteChunks("partial", (in Event event) {
        event.match!((in PasteEvent chunk) { part = chunk; }, (in _) {});
    }, first.request);
    part.last = false;
    assert(router.receive(part, hooks) == PasteOutcome.collecting);
    assert(feed(router, hooks, "whole", second.request) == PasteOutcome.delivered);
    assert(hooks.received[3] == "whole" && !router.isPending(first.request));
    part.last = true;
    assert(router.receive(part, hooks) == PasteOutcome.dropped && !hooks.received[1].length);
}

/// A paste nobody requested goes to the hooks' current owner, or nowhere without one.
@("ui_app.clipboardRouter.unsolicited")
@safe pure nothrow unittest
{
    ClipboardRouter!FakeOwner router;
    FakeHooks hooks;
    hooks.focus = 3;
    assert(feed(router, hooks, "typed", 0) == PasteOutcome.delivered);
    assert(hooks.received[3] == "typed");

    static struct Deaf
    {
        bool valid(in FakeOwner owner) const @safe pure nothrow @nogc => true;
        void deliver(in FakeOwner owner, scope const(char)[] text) @safe pure nothrow @nogc
        { assert(false); }
    }
    Deaf deaf;
    PasteEvent chunk;
    chunk.last = true;
    assert(router.receive(chunk, deaf) == PasteOutcome.dropped);
}

/// Stale reads make room for new ones; a full table of live ones refuses.
@("ui_app.clipboardRouter.capacity")
@safe pure nothrow unittest
{
    ClipboardRouter!(FakeOwner, 2) router;
    FakeHooks hooks;
    LocalHost host;
    assert(router.route(host, FakeOwner(0, 1), hooks) && router.route(host, FakeOwner(1, 1), hooks));
    assert(router.route(host, FakeOwner(2, 1), hooks).refusal == ClipboardRefusal.full);
    hooks.epochs[0] = 5;
    assert(router.route(host, FakeOwner(2, 1), hooks) && router.pendingCount == 2);
}

/// The host's shared namespace supplies identities when it has one; exhaustion refuses.
@("ui_app.clipboardRouter.hostIdentities")
@safe pure nothrow unittest
{
    static struct NativeHost
    {
        uint next = 40;
        uint allocateClipboardRequest() @safe pure nothrow @nogc => next == 42 ? 0 : ++next;
    }
    ClipboardRouter!FakeOwner router;
    FakeHooks hooks;
    NativeHost host;
    assert(router.route(host, FakeOwner(0, 1), hooks).request == 41);
    assert(router.route(host, FakeOwner(1, 1), hooks).request == 42);
    assert(router.route(host, FakeOwner(2, 1), hooks).refusal == ClipboardRefusal.exhausted);
}
