/**
Fiber-outcome and cancellation-tree vocabulary (SPEC §8.2, §9.2).

$(B Effects-side module): imports only `expected` and `errors` — never ring,
loop, or scheduler code — so the future `sparkles:effects` split stays
mechanical. The scheduler participates through plain function pointers
(`CancelFn`) and by embedding `FiberContext` by value in its task type.
*/
module sparkles.event_horizon.cause;

import expected : Expected, err, ok;

import sparkles.event_horizon.errors : IoError, NoGcHook;

/// Why an interrupt was delivered.
enum InterruptKind : ubyte
{
    cancelled, /// explicit `Scope.cancel` or the sibling-failure policy
    deadline,  /// a scope deadline expired
    raceLost,  /// a `race` contender lost to the winner
    shutdown,  /// loop/group shutdown (root-scope cancel)
    daemon,    /// only daemon fibers remained; the scope reaps them
}

/// The payload delivered to a cancelled fiber.
struct Interrupt
{
    InterruptKind kind;
}

/**
Three-way fiber-outcome cause (ZIO's `Cause`, flattened for `@nogc` — no
`Then`/`Both` tree; the first cause wins and later ones are counted,
[open-issues](../../../../../docs/specs/event-horizon/open-issues.md) O10):

$(LIST
    $(ITEM `fail` — the typed, expected error `E`: the body returned it — retryable)
    $(ITEM `die` — a defect: a `Throwable` escaped the fiber body — never retried)
    $(ITEM `interrupt` — the fiber was cancelled — never retried)
)
*/
struct Cause(E = IoError)
{
    /// Which channel this cause travels on.
    enum Kind : ubyte
    {
        fail,      /// typed failure (`failure` valid)
        die,       /// defect (`defect` valid)
        interrupt, /// cancellation (`interrupt` valid)
    }

    Kind kind;               /// the channel
    E failure;               /// valid when `kind == fail`
    /// valid when `kind == die` — borrowed, often a recycled instance;
    /// never owned here
    Throwable defect;
    Interrupt interrupt;     /// valid when `kind == interrupt`
    ushort suppressedCount;  /// causes observed after the first one

    /// Constructs the typed-failure cause.
    static Cause fromFailure(E e) @safe pure nothrow @nogc
    {
        Cause c = {kind: Kind.fail, failure: e};
        return c;
    }

    /// Constructs the defect cause.
    static Cause fromDefect(Throwable t) @safe pure nothrow @nogc
    {
        Cause c = {kind: Kind.die, defect: t};
        return c;
    }

    /// Constructs the interrupt cause.
    static Cause fromInterrupt(Interrupt i) @safe pure nothrow @nogc
    {
        Cause c = {kind: Kind.interrupt, interrupt: i};
        return c;
    }

    /// `true` for a deadline-born interrupt (Trio: "a deadline IS a cancel
    /// scope"; SPEC §8.3).
    bool isTimeout() const @safe pure nothrow @nogc
        => kind == Kind.interrupt && interrupt.kind == InterruptKind.deadline;
}

/// What `Scope`/`JoinHandle` joins yield: a value, or the `Cause` that ended
/// the fiber. (`IoResult` is the op-level currency; `Outcome` is the
/// fiber-level one — `die` and `interrupt` are not `IoError`s.)
alias Outcome(T, E = IoError) = Expected!(T, Cause!E, NoGcHook);

/// Constructs a successful $(LREF Outcome); attributes infer (move-only
/// payloads must not be rejected).
Outcome!(T, E) outcomeOk(E = IoError, T)(auto ref T value)
{
    import core.lifetime : forward;

    return ok!(Cause!E, NoGcHook)(forward!value);
}

/// ditto — success with no payload.
Outcome!(void, E) outcomeOk(E = IoError)() @safe pure nothrow @nogc
    => ok!(Cause!E, NoGcHook)();

/// Constructs a failed $(LREF Outcome) from a cause.
Outcome!(T, E) outcomeErr(T, E)(Cause!E cause)
    => err!(T, NoGcHook)(cause);

/// Lifts an op-level result into the fiber-level channel: the error (if
/// any) becomes a `fail` cause.
Outcome!(T, E) widen(T, E, Hook)(Expected!(T, E, Hook) r)
{
    import core.lifetime : move;

    if (r.hasError)
        return outcomeErr!(T, E)(Cause!E.fromFailure(r.error));
    static if (is(T == void))
        return outcomeOk!E();
    else
        return outcomeOk!E(move(r.value));
}

// ── the cancellation tree (SPEC §8.2; Eio's cancel.ml shape) ────────────────

/**
One-shot cancellation callback, installed by whatever parked the fiber: an
I/O park installs "submit `ASYNC_CANCEL` for my op"; a join park installs
"wake me now". A plain function pointer + context — `@nogc`, betterC-shaped,
and the effects/scheduler seam stays closure-free.
*/
alias CancelFn = void function(void* ctx, Interrupt reason) nothrow @nogc;

/// Fiber-exit hook (SPEC §8.6): the executor's shell calls it after the
/// body ends — `defect` carries an escaped `Throwable`, null on a clean
/// return. Scopes install it to run their accounting on the child fiber.
alias ExitFn = void function(void* ctx, FiberContext* self, Throwable defect) nothrow;

/**
Per-fiber, effects-visible state. Embedded $(B by value) in the scheduler's
task type; the effects layer only ever holds pointers to it.
*/
struct FiberContext
{
    CancelContext* cancelContext; /// innermost node this fiber runs under
    CancelFn cancelFn;            /// one-shot; null when not cancellably parked
    void* cancelCtx;              /// context for `cancelFn`
    ExitFn onExitFn;              /// scope accounting hook (SPEC §8.6)
    void* onExitCtx;              /// context for `onExitFn`
    void* taskBacklink;           /// the executor's task object (for `wake`)
    bool interrupted;             /// latched once; observed at checkpoints
    Interrupt pendingInterrupt;   /// valid when `interrupted`
    bool daemon;                  /// daemon fibers don't keep a scope alive
    uint protectDepth;            /// > 0 defers cancel-fn firing (`protect`)
    FiberContext* prevSibling;    /// intrusive membership list links
    FiberContext* nextSibling;    /// ditto
}

/**
A node in the cancellation tree; every `Scope` owns exactly one, and
`protect` pushes a $(I protected) child that parent cancellation does not
descend into.
*/
struct CancelContext
{
    /// Node states.
    enum State : ubyte
    {
        on,         /// live
        cancelling, /// a cancellation is sweeping (or swept) this subtree
        finished,   /// the owning scope has exited
    }

    State state = State.on;   /// current state
    bool isProtected;         /// parent cancellation stops at this node
    Interrupt cause;          /// valid when `state == cancelling`
    CancelContext* parent;    /// enclosing node (null at a root)
    CancelContext* firstChild;    /// intrusive child list
    CancelContext* prevSibling;   /// ditto
    CancelContext* nextSibling;   /// ditto
    FiberContext* firstFiber;     /// intrusive member-fiber list
    uint fiberCount;              /// live member fibers (incl. daemons)
    uint daemonCount;             /// live daemon members

    /// Links `child` under this node. (`@trusted`: the intrusive tree
    /// stores addresses of scope-frame-pinned nodes — the owning scope's
    /// join guarantees every child outlives its links, SPEC §8.1.)
    void addChild(scope CancelContext* child) return @trusted nothrow @nogc
    in (child.parent is null)
    {
        child.parent = &this;
        child.nextSibling = firstChild;
        if (firstChild !is null)
            firstChild.prevSibling = child;
        firstChild = child;
        // A node attached under an already-cancelling parent is swept
        // immediately — late attachment must not dodge the cancellation.
        if (state == State.cancelling && !child.isProtected)
            cancelTree(child, cause);
    }

    /// Unlinks `child`.
    void removeChild(scope CancelContext* child) @trusted nothrow @nogc
    in (child.parent is &this)
    {
        if (child.prevSibling !is null)
            child.prevSibling.nextSibling = child.nextSibling;
        else
            firstChild = child.nextSibling;
        if (child.nextSibling !is null)
            child.nextSibling.prevSibling = child.prevSibling;
        child.parent = null;
        child.prevSibling = child.nextSibling = null;
    }

    /// Links a member fiber. (Same pinning contract as `addChild`.)
    void addFiber(scope FiberContext* f) return @trusted nothrow @nogc
    {
        f.cancelContext = &this;
        f.nextSibling = firstFiber;
        if (firstFiber !is null)
            firstFiber.prevSibling = f;
        firstFiber = f;
        ++fiberCount;
        if (f.daemon)
            ++daemonCount;
        // Same late-attachment rule as addChild.
        if (state == State.cancelling)
            interruptFiber(f, cause);
    }

    /// Unlinks a member fiber.
    void removeFiber(scope FiberContext* f) @trusted nothrow @nogc
    in (f.cancelContext is &this)
    {
        if (f.prevSibling !is null)
            f.prevSibling.nextSibling = f.nextSibling;
        else
            firstFiber = f.nextSibling;
        if (f.nextSibling !is null)
            f.nextSibling.prevSibling = f.prevSibling;
        f.cancelContext = null;
        f.prevSibling = f.nextSibling = null;
        --fiberCount;
        if (f.daemon)
            --daemonCount;
    }
}

/**
Cancels a subtree (SPEC §8.2): marks non-protected nodes `cancelling`,
latches the interrupt on every member fiber, and fires each fiber's cancel
function $(B exactly once) — the function is swapped to null $(I before) it
runs (Eio's one-shot discipline: the complete-vs-cancel race is impossible
by construction). Idempotent; the first reason wins.
*/
void cancelTree(scope CancelContext* root, Interrupt reason) @trusted nothrow @nogc
{
    if (root is null || root.state != CancelContext.State.on)
        return;
    root.state = CancelContext.State.cancelling;
    root.cause = reason;

    for (auto f = root.firstFiber; f !is null; f = f.nextSibling)
        interruptFiber(f, reason);

    for (auto c = root.firstChild; c !is null; c = c.nextSibling)
        if (!c.isProtected)
            cancelTree(c, reason);
}

/// Latches the interrupt on one fiber and fires its one-shot cancel
/// function (if any). A `protect`ed fiber (SPEC §8.2) only latches — the
/// interrupt is delivered at its first checkpoint after the shield exits,
/// and an op it is parked on is allowed to finish.
void interruptFiber(scope FiberContext* f, Interrupt reason) @trusted nothrow @nogc
{
    if (!f.interrupted)
    {
        f.interrupted = true;
        f.pendingInterrupt = reason;
    }
    if (f.protectDepth > 0)
        return;
    const fn = f.cancelFn;
    if (fn is null)
        return;
    f.cancelFn = null; // one-shot: swap before calling
    auto ctx = f.cancelCtx;
    f.cancelCtx = null;
    (() @trusted => fn(ctx, reason))();
}

/// Should this fiber observe an interrupt at its next checkpoint?
/// (A `protect`ed fiber observes nothing until the shield exits.)
bool interruptRequested(in FiberContext f) @safe pure nothrow @nogc
    => f.protectDepth == 0
        && (f.interrupted
            || (f.cancelContext !is null
                && f.cancelContext.state == CancelContext.State.cancelling));

// ── tests (pure data-structure semantics; no scheduler, no ring) ────────────

@("cause.Cause.channels")
@safe pure nothrow @nogc
unittest
{
    auto f = Cause!IoError.fromFailure(IoError(11));
    assert(f.kind == Cause!IoError.Kind.fail);
    assert(f.failure.errnoValue == 11);
    assert(!f.isTimeout);

    auto i = Cause!IoError.fromInterrupt(Interrupt(InterruptKind.deadline));
    assert(i.kind == Cause!IoError.Kind.interrupt);
    assert(i.isTimeout);
}

@("cause.widen.liftsFailChannel")
@safe pure nothrow @nogc
unittest
{
    import sparkles.event_horizon.errors : IoResult, ioErr, ioOk;
    import sparkles.event_horizon.errors : OpKind;

    auto good = widen(ioOk(7));
    assert(!good.hasError && good.value == 7);

    auto bad = widen(ioErr!int(104, OpKind.recv));
    assert(bad.hasError);
    assert(bad.error.kind == Cause!IoError.Kind.fail);
    assert(bad.error.failure.errnoValue == 104);
}

@("cause.cancelTree.oneShotAndProtect")
@safe nothrow @nogc
unittest
{
    static struct Fired
    {
        int count;
        Interrupt last;
    }

    static void onCancel(void* p, Interrupt reason) nothrow @nogc
    {
        auto fired = cast(Fired*) p;
        ++fired.count;
        fired.last = reason;
    }

    CancelContext root;
    CancelContext child;
    CancelContext shielded;
    root.addChild(&child);
    root.addChild(&shielded);
    shielded.isProtected = true;

    Fired a, b, c;
    FiberContext fa, fb, fc;
    fa.cancelFn = &onCancel;
    fa.cancelCtx = (() @trusted => cast(void*) &a)();
    fb.cancelFn = &onCancel;
    fb.cancelCtx = (() @trusted => cast(void*) &b)();
    fc.cancelFn = &onCancel;
    fc.cancelCtx = (() @trusted => cast(void*) &c)();
    root.addFiber(&fa);
    child.addFiber(&fb);
    shielded.addFiber(&fc);

    cancelTree(&root, Interrupt(InterruptKind.cancelled));

    assert(a.count == 1 && b.count == 1, "members and children are swept");
    assert(c.count == 0, "protected subtrees are not descended into");
    assert(fa.interrupted && fb.interrupted && !fc.interrupted);
    assert(fa.cancelFn is null, "cancel functions are one-shot");

    // Idempotent: a second sweep fires nothing.
    cancelTree(&root, Interrupt(InterruptKind.shutdown));
    assert(a.count == 1 && b.count == 1);
    assert(root.cause.kind == InterruptKind.cancelled, "first reason wins");
}

@("cause.membership.linksUnlink")
@safe nothrow @nogc
unittest
{
    CancelContext node;
    FiberContext f1, f2;
    f2.daemon = true;
    node.addFiber(&f1);
    node.addFiber(&f2);
    assert(node.fiberCount == 2 && node.daemonCount == 1);

    node.removeFiber(&f2);
    assert(node.fiberCount == 1 && node.daemonCount == 0);
    node.removeFiber(&f1);
    assert(node.fiberCount == 0 && node.firstFiber is null);
}
