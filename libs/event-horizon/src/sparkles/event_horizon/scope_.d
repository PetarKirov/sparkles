/**
Structured concurrency (SPEC §8): `Scope` transcribes Eio's `Switch` /
Trio's nursery over the abstract fiber executor — the body counts as a
member, exit joins all children, the first failure cancels siblings (by
policy), daemons are reaped once only daemons remain, and the join itself is
uncancellable (outer cancellation reaches the children instead).

$(B Effects-side module): imports only `cause`, `capability`, and `errors` —
a mock executor makes every semantic here unit-testable with no ring.
*/
module sparkles.event_horizon.scope_;

import core.lifetime : move;
import core.stdc.errno : ECANCELED;
import core.time : Duration;

import expected : Expected;

import sparkles.event_horizon.capability : SpawnOptions, hasDeadlineTimer, isFiberExecutor;
import sparkles.event_horizon.cause;
import sparkles.event_horizon.errors : IoError, IoErrorStage, IoResult, NoGcHook, OpKind, ioErr, ioOk;

/// What the scope does when a child records a cause.
enum OnChildFailure : ubyte
{
    cancelSiblings, /// the first cause cancels every other child (the default)
    collect,        /// children run to completion; the first cause still wins
}

/// Per-scope options.
struct ScopeOptions
{
    OnChildFailure onFailure = OnChildFailure.cancelSiblings;
}

/**
A structured-concurrency scope (SPEC §8.1). Non-copyable and
address-pinned: children hold pointers into it for the whole of `withScope`
— sound because the join guarantees every child terminates before the frame
dies. Constructed only by `withScope`/`withDeadline`.
*/
/// The scope concept (SPEC §8.1): a structured-concurrency nursery carrying a
/// typed error channel, over which the tier-C drivers (`effect.run`) are
/// generic.
enum bool isScope(Sc) = is(Sc.ErrorType)
    && __traits(hasMember, Sc, "spawn")
    && __traits(hasMember, Sc, "fork")
    && __traits(hasMember, Sc, "cancel")
    && __traits(hasMember, Sc, "fail");

struct Scope(X, E = IoError)
if (isFiberExecutor!X)
{
    /// The typed-error channel this scope carries (for generic drivers).
    alias ErrorType = E;

    @disable this();
    @disable this(this);

    /// Spawns a child bound to this scope; its defect (escaped `Throwable`)
    /// feeds the failure policy as `Cause.die`. `body_` is an ordinary
    /// delegate (see `Sched.spawn` — a capturing closure's frame must
    /// outlive this call).
    void spawn(void delegate() body_)
    {
        spawnImpl(body_, SpawnOptions(daemon: false));
    }

    /// Spawns a daemon child: it does not keep the scope alive and is
    /// reaped with `InterruptKind.daemon` once only daemons remain.
    void spawnDaemon(void delegate() body_)
    {
        spawnImpl(body_, SpawnOptions(daemon: true));
    }

    /// Forks a child whose typed outcome is collected via `handle.join`
    /// (fail/die/interrupt travel to the join, not the scope policy).
    void fork(T)(ref JoinHandle!(T, E) handle,
        Expected!(T, E, NoGcHook) delegate() body_) @trusted
    {
        handle._body = body_;
        handle._scopeHook = &childExit;
        handle._scopeCtx = cast(void*) &this;
        handle._wakeFn = &wakeWaiter;
        handle._wakeCtx = cast(void*) _exec;
        auto child = _exec.spawnFiber(&node, SpawnOptions.init,
            &handle.runShell);
        if (child is null)
        {
            handle._cause = Cause!E.fromFailure(
                E(105 /* ENOBUFS */, OpKind.none, IoErrorStage.submit,
                    "fiber slab exhausted"));
            handle._isErr = true;
            handle._done = true;
            return;
        }
        child.onExitFn = &JoinHandle!(T, E).exitShim;
        child.onExitCtx = cast(void*) &handle;
        ++_childCount;
    }

    /// Requests cancellation of the subtree — idempotent, first reason
    /// wins; never blocks (children observe at checkpoints or via their
    /// in-flight cancel functions; the join collects them).
    void cancel(Interrupt reason = Interrupt(InterruptKind.cancelled)) @safe nothrow @nogc
    {
        cancelTree(&node, reason);
    }

    /// Records a failure (Eio's `Switch.fail`): the first cause wins and —
    /// under `cancelSiblings` — sweeps the subtree; later causes are counted.
    void fail(Cause!E cause) @safe nothrow @nogc
    {
        if (_failed)
        {
            ++_firstCause.suppressedCount;
            return;
        }
        _failed = true;
        _firstCause = cause;
        if (_opts.onFailure == OnChildFailure.cancelSiblings)
            cancelTree(&node, Interrupt(InterruptKind.cancelled));
    }

    /// LIFO cleanup hook, run at scope exit under `protect`. Fixed
    /// capacity (the open-issues storage question's simple arm); exceeding
    /// it is a defect.
    void onExit(scope void delegate() nothrow hook) @trusted
    in (_exitHookCount < _exitHooks.length, "onExit capacity exceeded")
    {
        _exitHooks[_exitHookCount++] = cast(void delegate() nothrow) hook;
    }

package:
    this(X* exec, ScopeOptions opts) @trusted nothrow @nogc
    {
        _exec = exec;
        _opts = opts;
    }

    void spawnImpl(void delegate() body_, SpawnOptions opts)
    {
        auto child = _exec.spawnFiber(&node, opts, body_);
        if (child is null)
        {
            fail(Cause!E.fromFailure(E(105 /* ENOBUFS */, OpKind.none,
                IoErrorStage.submit, "fiber slab exhausted")));
            return;
        }
        child.onExitFn = &childExit;
        child.onExitCtx = (() @trusted => cast(void*) &this)();
        ++_childCount;
        if (opts.daemon)
            ++_childDaemons;
    }

    /// Runs on each exiting child fiber (SPEC §8.6): accounting, defect
    /// routing, and the joiner wake.
    static void childExit(void* p, FiberContext* self, Throwable defect) nothrow
    {
        auto sc = (() @trusted => cast(Scope!(X, E)*) p)();
        if (self.cancelContext is &sc.node)
            sc.node.removeFiber(self);
        --sc._childCount;
        if (self.daemon)
            --sc._childDaemons;
        if (defect !is null)
            sc.fail(Cause!E.fromDefect(defect));
        if (sc._joinerWaiting
            && (sc._childCount == sc._childDaemons || sc._childCount == 0))
            sc._exec.wake(sc._joiner);
    }

    static void wakeWaiter(void* execPtr, FiberContext* waiter) nothrow @nogc
    {
        auto exec = (() @trusted => cast(X*) execPtr)();
        exec.wake(waiter);
    }

    /// The join protocol (SPEC §8.1): park until only daemons remain, reap
    /// them, park until empty, then run the exit hooks LIFO under protect.
    void joinPhase()
    {
        while (_childCount > _childDaemons)
        {
            _joinerWaiting = true;
            _exec.park();
            _joinerWaiting = false;
        }
        if (_childDaemons > 0)
        {
            for (auto f = node.firstFiber; f !is null; f = f.nextSibling)
                if (f.daemon)
                    interruptFiber(f, Interrupt(InterruptKind.daemon));
            while (_childCount > 0)
            {
                _joinerWaiting = true;
                _exec.park();
                _joinerWaiting = false;
            }
        }
        // Exit hooks: LIFO, shielded (SPEC §8.1).
        auto joiner = _exec.currentContext();
        ++joiner.protectDepth;
        scope (exit) --joiner.protectDepth;
        while (_exitHookCount > 0)
            _exitHooks[--_exitHookCount]();
    }

    CancelContext node;
    X* _exec;
    FiberContext* _joiner;
    bool _joinerWaiting;
    bool _failed;
    Cause!E _firstCause;
    uint _childCount;
    uint _childDaemons;
    ScopeOptions _opts;
    void delegate() nothrow[8] _exitHooks;
    ubyte _exitHookCount;
}

/**
A caller-owned result slot for `Scope.fork` (SPEC §8.1); lives on the
forker's frame. `join` parks until the forked fiber finishes and yields its
outcome exactly once. Interrupt latching is authoritative: a body that
swallows the `ECANCELED` error still joins as `Cause.interrupt` ("you
cannot silently drop a cancel", SPEC §8.4).
*/
struct JoinHandle(T, E = IoError)
{
    @disable this(this);

    /// Parks until the forked fiber finishes; the outcome, exactly once.
    Outcome!(T, E) join(X)(ref X exec) if (isFiberExecutor!X)
    {
        while (!_done)
        {
            _waiter = exec.currentContext();
            exec.park();
        }
        _waiter = null;
        if (_isErr)
            return outcomeErr!(T, E)(_cause);
        static if (is(T == void))
            return outcomeOk!E();
        else
            return outcomeOk!E(move(_value));
    }

package:
    /// The forked fiber's body: runs the stored delegate and records the
    /// typed outcome. (A member-function delegate over this handle — no
    /// closure allocation.)
    void runShell()
    {
        auto r = _body();
        if (r.hasError)
        {
            _cause = Cause!E.fromFailure(r.error);
            _isErr = true;
        }
        else
        {
            static if (!is(T == void))
                _value = move(r.value);
        }
        _resultStored = true;
    }

    /// The exit hook (runs after `runShell` on the child fiber): defect and
    /// interrupt routing, then the scope's own accounting.
    static void exitShim(void* p, FiberContext* self, Throwable defect) nothrow
    {
        auto h = (() @trusted => cast(JoinHandle!(T, E)*) p)();
        if (defect !is null)
        {
            h._cause = Cause!E.fromDefect(defect);
            h._isErr = true;
        }
        else if (self.interrupted)
        {
            // Latching is authoritative: a swallowed ECANCELED still joins
            // as an interrupt (SPEC §8.4).
            h._cause = Cause!E.fromInterrupt(self.pendingInterrupt);
            h._isErr = true;
        }
        else
            assert(h._resultStored, "runShell must have stored a result");
        h._done = true;
        if (h._waiter !is null)
            h._wakeFn(h._wakeCtx, h._waiter);
        h._scopeHook(h._scopeCtx, self, null); // accounting only
    }

    Expected!(T, E, NoGcHook) delegate() _body;
    static if (!is(T == void))
        T _value;
    Cause!E _cause;
    bool _isErr;
    ExitFn _scopeHook;
    void* _scopeCtx;
    void function(void*, FiberContext*) nothrow @nogc _wakeFn;
    void* _wakeCtx;
    FiberContext* _waiter;
    bool _done;
    bool _resultStored;
}

/**
Runs `fn(ref Scope)` with a fresh child scope (SPEC §8.1). The calling
fiber counts as a member for cancellation targeting (a deadline or cancel
sweeping the scope interrupts the body's own awaits); the join runs after
the body returns, and is itself uncancellable.

Returns `Outcome!(T, E)` where `T` is `fn`'s return type: the body's value,
or the scope's first cause.
*/
template withScope(alias fn, E = IoError)
{
    auto withScope(X)(ref X exec, ScopeOptions opts = ScopeOptions())
    if (isFiberExecutor!X)
        => runScope!(fn, E)(exec, Duration.max, opts);
}

/// ditto — with a deadline: "a deadline IS a cancel scope" (SPEC §8.3).
/// Expiry surfaces as `Cause.interrupt` with `InterruptKind.deadline`
/// (`outcome.error.isTimeout`).
template withDeadline(alias fn, E = IoError)
{
    auto withDeadline(X)(ref X exec, Duration timeout,
        ScopeOptions opts = ScopeOptions())
    if (isFiberExecutor!X && hasDeadlineTimer!X)
        => runScope!(fn, E)(exec, timeout, opts);
}

private template runScope(alias fn, E)
{
    auto runScope(X)(ref X exec, Duration timeout, ScopeOptions opts)
    {
        auto sc = Scope!(X, E)((() @trusted => &exec)(), opts);

        // The calling fiber joins the node for cancellation targeting;
        // membership is restored before the daemon reap.
        auto joiner = exec.currentContext();
        sc._joiner = joiner;
        auto outerNode = joiner.cancelContext;
        if (outerNode !is null)
        {
            outerNode.addChild(&sc.node);
            outerNode.removeFiber(joiner);
        }
        sc.node.addFiber(joiner);

        ulong deadlineToken;
        static if (hasDeadlineTimer!X)
            if (timeout != Duration.max)
                deadlineToken = exec.armDeadline(&sc.node, timeout);

        alias T = typeof(fn(sc));
        static if (is(T == void))
            fn(sc);
        else
            auto value = fn(sc);

        // Restore the joiner's membership before reaping/joining.
        sc.node.removeFiber(joiner);
        if (outerNode !is null)
            outerNode.addFiber(joiner);

        sc.joinPhase();

        static if (hasDeadlineTimer!X)
            if (deadlineToken != 0)
                exec.disarmDeadline(deadlineToken);

        if (outerNode !is null)
            outerNode.removeChild(&sc.node);
        sc.node.state = CancelContext.State.finished;

        // A deadline that swept the scope surfaces as its cause even when
        // no child recorded one.
        if (!sc._failed && sc.node.state == CancelContext.State.finished
            && sc.node.cause.kind == InterruptKind.deadline
            && joiner.interrupted
            && joiner.pendingInterrupt.kind == InterruptKind.deadline)
        {
            joiner.interrupted = false; // consumed by this scope
            return outcomeErr!(T, E)(
                Cause!E.fromInterrupt(Interrupt(InterruptKind.deadline)));
        }

        if (sc._failed)
            return outcomeErr!(T, E)(sc._firstCause);
        static if (is(T == void))
            return outcomeOk!E();
        else
            return outcomeOk!E(move(value));
    }
}

/// Shields the current fiber (Eio's `Cancel.protect`, SPEC §8.2): inside
/// `fn`, cancellation only latches — in-flight ops finish, and the pending
/// interrupt is delivered at the first checkpoint after `fn` returns.
template protect(alias fn)
{
    auto protect(X)(ref X exec) if (isFiberExecutor!X)
    {
        auto f = exec.currentContext();
        ++f.protectDepth;
        scope (exit) --f.protectDepth;
        return fn();
    }
}

/// An explicit cancellation checkpoint for CPU-bound loops: `ECANCELED`
/// when an interrupt is pending. Every I/O verb is implicitly one.
IoResult!void checkCancellation(X)(ref X exec) if (isFiberExecutor!X)
{
    if (interruptRequested(*exec.currentContext()))
        return ioErr!void(ECANCELED, OpKind.none, IoErrorStage.submit,
            "scope cancelled");
    return ioOk();
}

// ── the M5 gate: the cancellation/timeout/shutdown matrix ───────────────────
// Axes: park type (I/O / join / timer) × cancel source (explicit / deadline /
// sibling failure / shutdown) × race outcome (cancel wins / completion wins)
// × protect (inside / outside). Driven against the live Sched (SKIPs where
// io_uring is unavailable).

version (linux) version (unittest)
{
    import sparkles.event_horizon.sched : Sched;

    private bool schedOrSkip(ref Sched s) @trusted nothrow
        => !Sched.create(s).hasError;
}

@("scope.join.basicValueAndOrdering")
@safe
unittest
{
    Sched s;
    if (!schedOrSkip(s))
        return; // SKIP
    scope (exit) s.destroy();

    int children;
    auto r = s.run(() {
        auto outcome = withScope!((ref sc) {
            sc.spawn(() { ++children; });
            sc.spawn(() { ++children; });
            return 42;
        })(s);
        assert(!outcome.hasError);
        assert(outcome.value == 42);
        assert(children == 2, "exit joins all children");
    });
    assert(!r.hasError);
}

@("scope.siblingFailure.cancelsIoPark")
@safe
unittest
{
    import core.time : minutes;
    import sparkles.event_horizon.io : sleep;

    Sched s;
    if (!schedOrSkip(s))
        return; // SKIP
    scope (exit) s.destroy();

    int siblingErrno;
    auto r = s.run(() {
        auto outcome = withScope!((ref sc) {
            sc.spawn(() {
                // Parked on a one-minute timer: only the sibling's failure
                // sweep can end this quickly (cancel-wins race).
                auto slept = sleep(s, 1.minutes);
                assert(slept.hasError);
                siblingErrno = slept.error.errnoValue;
            });
            sc.spawn(() {
                sc.fail(Cause!IoError.fromFailure(
                    IoError(5, OpKind.none, IoErrorStage.completion, "boom")));
            });
        })(s);
        assert(outcome.hasError);
        assert(outcome.error.kind == Cause!IoError.Kind.fail);
        assert(outcome.error.failure.errnoValue == 5);
    });
    assert(!r.hasError);
    assert(siblingErrno == ECANCELED,
        "the sibling's in-flight op must observe -ECANCELED");
}

@("scope.explicitCancel.interruptsChildren")
@safe
unittest
{
    import core.time : minutes;
    import sparkles.event_horizon.io : sleep;

    Sched s;
    if (!schedOrSkip(s))
        return; // SKIP
    scope (exit) s.destroy();

    bool childInterrupted;
    auto r = s.run(() {
        auto outcome = withScope!((ref sc) {
            sc.spawn(() {
                childInterrupted = sleep(s, 1.minutes).hasError;
            });
            sc.cancel(Interrupt(InterruptKind.shutdown));
        })(s);
        // An explicit cancel is a request, not a failure (Eio): the scope's
        // own outcome stays ok unless someone recorded a cause.
        assert(!outcome.hasError);
    });
    assert(!r.hasError);
    assert(childInterrupted);
}

@("scope.deadline.timesOutAndDisarms")
@safe
unittest
{
    import core.time : MonoTime, minutes, msecs, seconds;
    import sparkles.event_horizon.io : sleep;

    Sched s;
    if (!schedOrSkip(s))
        return; // SKIP
    scope (exit) s.destroy();

    auto r = s.run(() {
        // Expiry: the joiner's own park is swept (the body counts as a
        // member) and the outcome is the timeout cause.
        const before = MonoTime.currTime;
        auto slow = withDeadline!((ref sc) {
            cast(void) sleep(s, 1.minutes);
        })(s, 10.msecs);
        assert(slow.hasError);
        assert(slow.error.isTimeout);
        assert(MonoTime.currTime - before < 10.seconds);

        // Disarm: a fast body under a long deadline stays clean.
        auto fast = withDeadline!((ref sc) => 7)(s, 1.minutes);
        assert(!fast.hasError && fast.value == 7);
    });
    assert(!r.hasError);
}

@("scope.race.completionWins")
@safe
unittest
{
    import core.time : msecs;
    import sparkles.event_horizon.io : sleep;

    Sched s;
    if (!schedOrSkip(s))
        return; // SKIP
    scope (exit) s.destroy();

    auto r = s.run(() {
        auto outcome = withScope!((ref sc) {
            JoinHandle!int h;
            sc.fork(h, () {
                cast(void) sleep(s, 1.msecs);
                return ioOk(99);
            });
            // Let the child finish, then cancel: completion won the race.
            cast(void) sleep(s, 30.msecs);
            sc.cancel();
            auto joined = h.join(s);
            assert(!joined.hasError, "a completed fork is untouched by cancel");
            assert(joined.value == 99);
        })(s);
        assert(!outcome.hasError);
    });
    assert(!r.hasError);
}

@("scope.race.cancelWinsAtJoinPark")
@safe
unittest
{
    import core.time : minutes;
    import sparkles.event_horizon.io : sleep;

    Sched s;
    if (!schedOrSkip(s))
        return; // SKIP
    scope (exit) s.destroy();

    auto r = s.run(() {
        auto outcome = withScope!((ref sc) {
            JoinHandle!int h;
            sc.fork(h, () {
                auto slept = sleep(s, 1.minutes);
                assert(slept.hasError); // swept below
                return ioErr!int(slept.error);
            });
            sc.cancel();
            // The join itself is uncancellable; it collects the interrupt.
            auto joined = h.join(s);
            assert(joined.hasError);
            assert(joined.error.kind == Cause!IoError.Kind.interrupt,
                "latching is authoritative over the swallowed ECANCELED");
        })(s);
        assert(!outcome.hasError);
    });
    assert(!r.hasError);
}

@("scope.protect.shieldsInFlightOp")
@safe
unittest
{
    import core.time : msecs;
    import sparkles.event_horizon.io : sleep;

    Sched s;
    if (!schedOrSkip(s))
        return; // SKIP
    scope (exit) s.destroy();

    bool sleptCleanly, sawPendingInterrupt;
    auto r = s.run(() {
        cast(void) withScope!((ref sc) {
            sc.spawn(() {
                cast(void) protect!(() {
                    // Cancelled while shielded: the op must run to
                    // completion (cancel only latches).
                    sleptCleanly = !sleep(s, 10.msecs).hasError;
                    return 0;
                })(s);
                // First checkpoint after the shield: delivery.
                sawPendingInterrupt = checkCancellation(s).hasError;
            });
            sc.cancel();
        })(s);
    });
    assert(!r.hasError);
    assert(sleptCleanly, "protect lets the in-flight op finish");
    assert(sawPendingInterrupt, "the latched interrupt lands after the shield");
}

@("scope.daemons.reapedAtExit")
@safe
unittest
{
    import core.time : minutes;
    import sparkles.event_horizon.io : sleep;

    Sched s;
    if (!schedOrSkip(s))
        return; // SKIP
    scope (exit) s.destroy();

    bool daemonInterrupted, workerRan;
    auto r = s.run(() {
        auto outcome = withScope!((ref sc) {
            sc.spawnDaemon(() {
                daemonInterrupted = sleep(s, 1.minutes).hasError;
            });
            sc.spawn(() { workerRan = true; });
        })(s);
        assert(!outcome.hasError, "daemon reaping is not a failure");
    });
    assert(!r.hasError);
    assert(workerRan);
    assert(daemonInterrupted, "daemons are reaped once only daemons remain");
}

@("scope.defect.becomesCauseDie")
@safe
unittest
{
    Sched s;
    if (!schedOrSkip(s))
        return; // SKIP
    scope (exit) s.destroy();

    auto r = s.run(() {
        auto outcome = withScope!((ref sc) {
            sc.spawn(() @trusted { throw new Exception("logic bug"); });
        })(s);
        assert(outcome.hasError);
        assert(outcome.error.kind == Cause!IoError.Kind.die);
        assert(outcome.error.defect.msg == "logic bug");
    })
    ;
    assert(!r.hasError);
}

@("scope.nested.outerCancelReachesInnerChildren")
@safe
unittest
{
    import core.time : minutes;
    import sparkles.event_horizon.io : sleep;

    Sched s;
    if (!schedOrSkip(s))
        return; // SKIP
    scope (exit) s.destroy();

    bool innerInterrupted;
    auto r = s.run(() {
        cast(void) withScope!((ref outer) {
            outer.spawn(() {
                cast(void) withScope!((ref inner) {
                    inner.spawn(() {
                        innerInterrupted = sleep(s, 1.minutes).hasError;
                    });
                })(s);
            });
            outer.cancel();
        })(s);
    });
    assert(!r.hasError);
    assert(innerInterrupted, "cancellation recurses through nested scopes");
}

@("scope.onExit.lifoUnderShield")
@safe
unittest
{
    Sched s;
    if (!schedOrSkip(s))
        return; // SKIP
    scope (exit) s.destroy();

    int[2] order;
    size_t i;
    auto r = s.run(() {
        cast(void) withScope!((ref sc) {
            sc.onExit(() nothrow { order[i++] = 1; });
            sc.onExit(() nothrow { order[i++] = 2; });
            sc.cancel(); // hooks still run, shielded
        })(s);
    });
    assert(!r.hasError);
    assert(i == 2 && order[0] == 2 && order[1] == 1, "LIFO");
}
