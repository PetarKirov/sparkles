/**
Capability seams and the effect row (SPEC §10). $(B Effects-side module):
imports only `cause` — never ring, loop, or scheduler code.

A capability is a plain struct value naming its row label (`capName`);
handlers are values — swapping a handler is passing a different one.
Dispatch is monomorphized: `ctx.clock.now()` is a constant-offset field
access plus a direct, inlinable call — the evidence lookup costs zero
instructions, and every capability operation is tail-resumptive by
construction (the only suspension is a fiber park inside an implementation,
a scheduler service, never a reified continuation).

The row is a $(B testability and least-authority convention, not an
enforcement boundary) — D has ambient authority; the row buys swappability,
auditability, and deterministic tests.
*/
module sparkles.event_horizon.capability;

import core.time : Duration;

import std.meta : allSatisfy, staticMap;

import sparkles.event_horizon.cause : CancelContext, FiberContext;

/// Per-spawn options.
struct SpawnOptions
{
    bool daemon = false; /// daemons don't keep their scope alive (SPEC §8.1)
}

/**
The fiber-executor concept (SPEC §10.3) — the exact expressions `scope_`
drives; the live implementation is `Sched`, and a mock makes every scope
semantic unit-testable with no ring:

$(LIST
    $(ITEM `currentContext()` — the running fiber's context (asserts off-fiber))
    $(ITEM `spawnFiber(node, opts, dg)` — child bound to `node`; enqueued,
        not run inline; `null` = slab exhausted)
    $(ITEM `park()` — suspend the current fiber until exactly one `wake`)
    $(ITEM `wake(f)` — make a parked fiber runnable (same-worker))
)
*/
enum bool isFiberExecutor(X) = __traits(compiles, (ref X x, CancelContext* cc) {
    FiberContext* cur = x.currentContext();
    FiberContext* child = x.spawnFiber(cc, SpawnOptions.init, delegate void() {});
    x.park();
    x.wake(child);
});

/**
Optional deadline-timer primitive (gates `withDeadline`, SPEC §8.3): arms a
one-shot timer whose expiry cancels `node`'s subtree; the token disarms it.
On `Sched` this is an in-ring `TIMEOUT`.
*/
enum bool hasDeadlineTimer(X) = __traits(compiles, (ref X x, CancelContext* cc) {
    ulong t = x.armDeadline(cc, Duration.zero);
    x.disarmDeadline(t);
});

/**
The minimal one-shot park/wake seam (SPEC §10.3) that lets effects-side
capabilities (`TestClock`, `SimNet`) suspend the current task without
importing the scheduler. Exactly one wake per prepared handle;
wake-before-park makes the park a no-op (the lost-wakeup guard).
*/
enum bool isWaker(W) = is(W.Handle) && __traits(compiles, (ref W w) {
    W.Handle h = w.prepare();
    w.park(h);
    w.wake(h);
});

// ── the capability row (SPEC §10.1–10.2) ────────────────────────────────────

/// A capability is any struct naming its row label. Two capability types
/// with the same `capName` are interchangeable handlers for the same effect
/// (`TestClock` for a live clock).
enum bool isCapability(C) = is(C == struct)
    && is(typeof(C.capName) : string) && C.capName.length > 0;

/// Index of the capability labelled `name` in `Caps`, or `-1`.
template capIndexOf(string name, Caps...)
{
    private ptrdiff_t find()
    {
        ptrdiff_t found = -1;
        static foreach (i, C; Caps)
            if (found == -1 && C.capName == name)
                found = i;
        return found;
    }

    enum ptrdiff_t capIndexOf = find();
}

private template labelsAreUnique(Caps...)
{
    private bool check()
    {
        static foreach (i, A; Caps)
            static foreach (j, B; Caps)
                static if (i < j)
                    if (A.capName == B.capName)
                        return false;
        return true;
    }

    enum bool labelsAreUnique = check();
}

/**
The evidence row (SPEC §10.2): a `Ctx!(Caps...)` is a plain struct with one
field per capability — the D analogue of an evidence vector, except every
index resolves at compile time.
*/
struct Ctx(Caps...)
if (Caps.length > 0 && allSatisfy!(isCapability, Caps) && labelsAreUnique!Caps)
{
    Caps caps; /// one field per capability, in row order

    /// Access by row label: `ctx.cap!"clock"`; compile error if absent.
    ref cap(string name)() inout return
    if (capIndexOf!(name, Caps) >= 0)
        => caps[capIndexOf!(name, Caps)];

    /// Sugar: `ctx.clock`, `ctx.net` — forwards to `cap!name`.
    ref opDispatch(string name)() inout return
    if (capIndexOf!(name, Caps) >= 0)
        => caps[capIndexOf!(name, Caps)];

    /// Row-subset projection by label, for non-template boundaries
    /// (template call chains project implicitly via `hasCaps`).
    /// Mutable-receiver only: an `inout` receiver cannot rebuild a row of
    /// pointer-holding capabilities.
    auto sub(names...)() scope
    {
        alias PickByName(string n) = Caps[capIndexOf!(n, Caps)];
        alias SubCaps = staticMap!(PickByName, names);
        Ctx!SubCaps r;
        static foreach (i, n; names)
            r.caps[i] = caps[capIndexOf!(n, Caps)];
        return r;
    }

    /// Row extension / handler override (innermost-handler-wins, lexically):
    /// a value with `c` added, or replacing the same-labelled capability.
    auto withCap(C)(C c) scope if (isCapability!C)
    {
        enum idx = capIndexOf!(C.capName, Caps);
        static if (idx >= 0)
        {
            alias ReplaceAt(size_t j) = typeof(Ctx.init.caps[j]);
            Ctx!(Caps[0 .. idx], C, Caps[idx + 1 .. $]) r;
            static foreach (j; 0 .. Caps.length)
            {
                static if (j == idx)
                    r.caps[j] = c;
                else
                    r.caps[j] = caps[j];
            }
            return r;
        }
        else
        {
            Ctx!(Caps, C) r;
            static foreach (j; 0 .. Caps.length)
                r.caps[j] = caps[j];
            r.caps[Caps.length] = c;
            return r;
        }
    }
}

/// Construction helper: `auto env = ctx(clock, net);`
auto ctx(Caps...)(Caps caps) if (allSatisfy!(isCapability, Caps))
{
    Ctx!Caps r;
    static foreach (i; 0 .. Caps.length)
        r.caps[i] = caps[i];
    return r;
}

/// Canonicalizing alias: sorts capabilities by label so `Ctx!(Net, Clock)`
/// and `Ctx!(Clock, Net)` are one instantiation (bounds template bloat —
/// open-issues O12). The blessed row constructor.
template CtxOf(Caps...)
{
    import std.meta : staticSort;

    enum labelLess(A, B) = A.capName < B.capName;
    alias CtxOf = Ctx!(staticSort!(labelLess, Caps));
}

/// Structural row check for template constraints:
/// `void f(C)(ref C ctx) if (hasCaps!(C, "net", "clock"))` — a callee
/// constrained on a subset accepts any superset row unchanged.
template hasCaps(C, names...)
{
    private bool check()
    {
        bool ok = true;
        static foreach (n; names)
            static if (!__traits(compiles, C.init.cap!n()))
                ok = false;
        return ok;
    }

    enum bool hasCaps = check();
}

/// The concrete capability type behind a label.
alias CapType(C, string name) = typeof(C.init.cap!name());

@("capability.ctx.rowAccessAndProjection")
@safe pure nothrow @nogc
unittest
{
    static struct FakeClock
    {
        enum string capName = "clock";
        int ticks;
        int now() @safe pure nothrow @nogc => ticks;
    }

    static struct FakeNet
    {
        enum string capName = "net";
        int connects;
    }

    auto env = ctx(FakeClock(42), FakeNet(7));
    assert(env.cap!"clock".now() == 42);
    assert(env.clock.now() == 42, "opDispatch sugar");
    assert(env.net.connects == 7);

    static assert(hasCaps!(typeof(env), "clock", "net"));
    static assert(!hasCaps!(typeof(env), "fs"));

    // Subset projection for non-template boundaries.
    auto only = env.sub!"clock"();
    static assert(hasCaps!(typeof(only), "clock"));
    static assert(!hasCaps!(typeof(only), "net"));
    assert(only.clock.now() == 42);

    // Handler override: innermost wins, the original row is untouched.
    auto swapped = env.withCap(FakeClock(1000));
    assert(swapped.clock.now() == 1000);
    assert(env.clock.now() == 42);

    // Row extension.
    static struct FakeFs
    {
        enum string capName = "fs";
    }

    auto wider = env.withCap(FakeFs());
    static assert(hasCaps!(typeof(wider), "clock", "net", "fs"));
}

@("capability.ctx.mutationThroughRef")
@safe pure nothrow @nogc
unittest
{
    static struct Counter
    {
        enum string capName = "counter";
        int hits;
        void bump() @safe pure nothrow @nogc
        {
            ++hits;
        }
    }

    auto env = ctx(Counter());
    env.counter.bump();
    env.cap!"counter".bump();
    assert(env.counter.hits == 2, "ref access mutates the row's value");
}
