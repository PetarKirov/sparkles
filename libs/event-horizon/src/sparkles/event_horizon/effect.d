/**
Tier C — the `Effect!T` monadic veneer (SPEC §12): a lazy, typed
description of a fiber computation, for callers who prefer combinator
pipelines over direct style. Every combinator is defined in terms of the
tier-B verbs, and the interpreter is a $(B compile-time fold) (static
dispatch on node types, not a runtime instruction loop): `Pure`/`Mapped`/
`Chained` lower to nested inlined calls on the current fiber, and only
`Zipped`/`Retried`/`Deadlined` touch the scheduler — by calling
`sc.spawn`/`retry`/`timeout`. The veneer has no semantics of its own, so
parity with the direct core holds by construction (the M12 parity suite
enforces it).

There is deliberately no `R` (environment) parameter: the capability row is
the `Ctx` $(I type) supplied at `run`, checked at compile time via `hasCaps`
constraints and erased at run time (the Kyo lesson — ZIO's `R` generalizes
to an open row, and D's `Ctx` is that row, resolved statically).

$(B Effects-side module): imports only `cause`, `scope_`, `schedule`,
`clock`, `errors` — no ring/loop.
*/
module sparkles.event_horizon.effect;

import core.lifetime : move;
import core.time : Duration;

import sparkles.event_horizon.cause : Cause, InterruptKind, Interrupt, Outcome,
    outcomeErr, outcomeOk;
import sparkles.event_horizon.clock : isClock;
import sparkles.event_horizon.errors : IoError, NoGcHook;
import sparkles.event_horizon.schedule : isSchedule, retry, timeout;
import sparkles.event_horizon.scope_ : isScope, JoinHandle;

// ── the node types (a lazy description tree) ────────────────────────────────

/// The effect concept: a node exposes its `Value`/`Error` types.
enum bool isEffect(Eff) = is(Eff.Value) && is(Eff.Error);

/// A pure success value.
struct Pure(T, E = IoError)
{
    alias Value = T;
    alias Error = E;
    T value;
}

/// A pure failure.
struct Failed(T, E = IoError)
{
    alias Value = T;
    alias Error = E;
    E error;
}

/// Lifts a direct-style body `fn(ref Scope, ref Ctx)` returning
/// `Expected!(T, E, NoGcHook)`.
struct Lifted(alias fn, T, E = IoError)
{
    alias Value = T;
    alias Error = E;
}

/// `map`: transform the success value.
struct Mapped(Eff, alias f)
if (isEffect!Eff)
{
    alias Value = typeof(f(Eff.Value.init));
    alias Error = Eff.Error;
    Eff up;
}

/// `andThen`: sequence, feeding the value to a function returning an effect.
struct Chained(Eff, alias f)
if (isEffect!Eff)
{
    private alias Next = typeof(f(Eff.Value.init));
    static assert(isEffect!Next, "andThen's function must return an Effect");
    alias Value = Next.Value;
    alias Error = Eff.Error;
    Eff up;
}

/// `zipPar`: run two effects concurrently, pair their values.
struct Zipped(A, B)
if (isEffect!A && isEffect!B)
{
    import std.typecons : Tuple;

    alias Value = Tuple!(A.Value, B.Value);
    alias Error = A.Error;
    A a;
    B b;
}

/// `withRetry`: retry the effect per a schedule on the fail channel.
struct Retried(Eff, S)
if (isEffect!Eff && isSchedule!S)
{
    alias Value = Eff.Value;
    alias Error = Eff.Error;
    Eff up;
    S policy;
}

/// `withTimeout`: run under a deadline.
struct Deadlined(Eff)
if (isEffect!Eff)
{
    alias Value = Eff.Value;
    alias Error = Eff.Error;
    Eff up;
    Duration limit;
}

// ── constructors ────────────────────────────────────────────────────────────

/// A succeeding effect.
auto succeed(T, E = IoError)(T value) => Pure!(T, E)(value);

/// A failing effect.
auto fail(T, E = IoError)(E error) => Failed!(T, E)(error);

/**
Lifts a direct-style body. `fn` takes `(ref Scope, ref Ctx)` and returns an
`Expected!(T, E, NoGcHook)`; the `Value`/`Error` types are deduced from it.
*/
template effect(alias fn)
{
    auto effect(Sc, C)(ref Sc probeScope, ref C probeCtx)
    {
        // Only used for type deduction at the call site via the helper below.
        static assert(0, "call effectOf!fn instead");
    }
}

/// Lifts a body with explicit result types (the deduction-free form).
auto effectOf(alias fn, T, E = IoError)() => Lifted!(fn, T, E)();

/// `map` combinator.
auto map(alias f, Eff)(Eff e) if (isEffect!Eff) => Mapped!(Eff, f)(e);

/// `andThen` combinator.
auto andThen(alias f, Eff)(Eff e) if (isEffect!Eff) => Chained!(Eff, f)(e);

/// `zipPar` combinator.
auto zipPar(A, B)(A a, B b) if (isEffect!A && isEffect!B) => Zipped!(A, B)(a, b);

/// `withRetry` combinator.
auto withRetry(S, Eff)(Eff e, S policy)
if (isEffect!Eff && isSchedule!S) => Retried!(Eff, S)(e, policy);

/// `withTimeout` combinator.
auto withTimeout(Eff)(Eff e, Duration limit)
if (isEffect!Eff) => Deadlined!Eff(e, limit);

// ── the interpreter: a compile-time fold ────────────────────────────────────

/**
Runs `eff` against `sc` (a scope) and `ctx` (the capability row), returning
`Outcome!(Value, Error)`. Static dispatch on the node type recurses;
`Pure`/`Mapped`/`Chained` fuse into straight-line calls, and only the
scheduler-touching nodes call the tier-B drivers.
*/
Outcome!(Eff.Value, Eff.Error) run(Eff, Sc, C)(Eff eff, ref Sc sc, ref C ctx)
if (isEffect!Eff && isScope!Sc)
{
    static if (is(Eff == Pure!(V, F), V, F))
    {
        return outcomeOk!F(move(eff.value));
    }
    else static if (is(Eff == Failed!(U, F), U, F))
    {
        return outcomeErr!(U, F)(Cause!F.fromFailure(eff.error));
    }
    else static if (is(Eff == Lifted!(fn, U, F), alias fn, U, F))
    {
        auto r = fn(sc, ctx);
        if (r.hasError)
            return outcomeErr!(U, F)(Cause!F.fromFailure(r.error));
        static if (is(U == void))
            return outcomeOk!F();
        else
            return outcomeOk!F(move(r.value));
    }
    else static if (is(Eff == Mapped!(Up, f), Up, alias f))
    {
        auto inner = run(eff.up, sc, ctx);
        if (inner.hasError)
            return outcomeErr!(Eff.Value, Eff.Error)(inner.error);
        return outcomeOk!(Eff.Error)(f(move(inner.value)));
    }
    else static if (is(Eff == Chained!(Up, f), Up, alias f))
    {
        auto inner = run(eff.up, sc, ctx);
        if (inner.hasError)
            return outcomeErr!(Eff.Value, Eff.Error)(inner.error);
        return run(f(move(inner.value)), sc, ctx);
    }
    else static if (is(Eff == Zipped!(A, B), A, B))
    {
        // Concurrency: fork the second, run the first, join. The scope's
        // structured discipline reaps the fork on any failure path.
        JoinHandle!(B.Value, B.Error) hb;
        sc.fork(hb, () {
            auto rb = run(eff.b, sc, ctx);
            if (rb.hasError)
                return failToExpected!(B.Value, B.Error)(rb.error);
            static if (is(B.Value == void))
                return okExpected!(B.Value, B.Error)();
            else
                return okExpected!(B.Value, B.Error)(move(rb.value));
        });
        auto ra = run(eff.a, sc, ctx);
        auto rbJoined = hb.join(*sc._exec);
        if (ra.hasError)
            return outcomeErr!(Eff.Value, Eff.Error)(ra.error);
        if (rbJoined.hasError)
            return outcomeErr!(Eff.Value, Eff.Error)(rbJoined.error);
        import std.typecons : tuple;

        return outcomeOk!(Eff.Error)(tuple(move(ra.value), move(rbJoined.value)));
    }
    else static if (is(Eff == Retried!(Up, S), Up, S))
    {
        // Only defined when the row has a clock (retry needs one).
        static assert(__traits(hasMember, C, "clock") || hasClockCap!C,
            "withRetry needs a clock capability in the row");
        auto up = eff.up;
        auto policy = eff.policy;
        return retry(sc, clockOf(ctx), policy,
            () => runToExpected(up, sc, ctx));
    }
    else static if (is(Eff == Deadlined!Up, Up))
    {
        static assert(__traits(hasMember, C, "clock") || hasClockCap!C,
            "withTimeout needs a clock capability in the row");
        auto up = eff.up;
        return timeout(sc, clockOf(ctx), eff.limit,
            () => runToExpected(up, sc, ctx));
    }
    else
        static assert(0, "unhandled effect node: " ~ Eff.stringof);
}

// ── helpers (bridge Outcome ⇄ Expected for the driver callbacks) ────────────

private import expected : Expected;

private Expected!(T, E, NoGcHook) okExpected(T, E)()
if (is(T == void))
{
    import sparkles.event_horizon.errors : ioOk;

    return Expected!(void, E, NoGcHook)();
}

private Expected!(T, E, NoGcHook) okExpected(T, E)(T v)
if (!is(T == void))
{
    import expected : ok;

    return ok!(E, NoGcHook)(move(v));
}

private Expected!(T, E, NoGcHook) failToExpected(T, E)(Cause!E cause)
{
    import expected : err;

    // The drivers only look at the fail channel; a die/interrupt cause maps
    // to a synthetic error is avoided by carrying the fail payload through.
    return err!(T, NoGcHook)(cause.kind == Cause!E.Kind.fail
        ? cause.failure : E.init);
}

/// Runs a sub-effect and flattens its Outcome to the Expected the tier-B
/// drivers (`retry`/`timeout`) expect.
private auto runToExpected(Eff, Sc, C)(Eff eff, ref Sc sc, ref C ctx)
{
    auto o = run(eff, sc, ctx);
    if (o.hasError)
        return failToExpected!(Eff.Value, Eff.Error)(o.error);
    static if (is(Eff.Value == void))
        return okExpected!(Eff.Value, Eff.Error)();
    else
        return okExpected!(Eff.Value, Eff.Error)(move(o.value));
}

private enum bool hasClockCap(C) = __traits(compiles, C.init.cap!"clock"());

private ref auto clockOf(C)(ref C ctx)
{
    static if (__traits(hasMember, C, "clock"))
        return ctx.clock;
    else
        return ctx.cap!"clock"();
}

// ── tests: parity with the direct core (M12 gate) ───────────────────────────

version (linux)  :  // parity tests drive the live Sched

version (unittest)
{
    import sparkles.event_horizon.errors : IoResult, ioErr, ioOk, OpKind;
    import sparkles.event_horizon.sched : Sched;
    import sparkles.event_horizon.scope_ : withScope;
}

@("effect.parity.pureMapChain")
@safe
unittest
{
    Sched s;
    if (Sched.create(s).hasError)
        return; // SKIP
    scope (exit) s.destroy();

    static struct EmptyCtx { }

    auto r = s.run(() {
        cast(void) withScope!((ref sc) {
            EmptyCtx ctx;
            // succeed(2) |> map(*10) |> andThen(x => succeed(x+1)) == 21
            auto eff = succeed(2)
                .map!(x => x * 10)
                .andThen!(x => succeed(x + 1));
            auto outcome = run(eff, sc, ctx);
            assert(!outcome.hasError);
            assert(outcome.value == 21);

            // Direct-core equivalent, same result — parity.
            int direct = 2;
            direct = direct * 10;
            direct = direct + 1;
            assert(outcome.value == direct);
        })(s);
    });
    assert(!r.hasError);
}

@("effect.parity.failShortCircuits")
@safe
unittest
{
    Sched s;
    if (Sched.create(s).hasError)
        return; // SKIP
    scope (exit) s.destroy();

    static struct EmptyCtx { }

    auto r = s.run(() {
        cast(void) withScope!((ref sc) {
            EmptyCtx ctx;
            bool mapRan;
            auto eff = fail!int(IoError(5, OpKind.none))
                .map!((int x) { return x; });
            auto outcome = run(eff, sc, ctx);
            assert(outcome.hasError);
            assert(outcome.error.kind == Cause!IoError.Kind.fail);
            assert(outcome.error.failure.errnoValue == 5);
        })(s);
    });
    assert(!r.hasError);
}

@("effect.parity.liftedBodyMatchesDirect")
@safe
unittest
{
    Sched s;
    if (Sched.create(s).hasError)
        return; // SKIP
    scope (exit) s.destroy();

    static struct EmptyCtx { }

    // A lifted direct-style body: the veneer must produce the same outcome
    // as calling the body directly.
    static IoResult!int body_(Sc, C)(ref Sc sc, ref C ctx)
        => ioOk(7);

    auto r = s.run(() {
        cast(void) withScope!((ref sc) {
            EmptyCtx ctx;
            auto eff = effectOf!(body_, int)().map!(x => x + 1);
            auto outcome = run(eff, sc, ctx);
            assert(!outcome.hasError && outcome.value == 8);

            // Parity: the direct call.
            auto direct = body_(sc, ctx);
            assert(!direct.hasError && direct.value + 1 == outcome.value);
        })(s);
    });
    assert(!r.hasError);
}

@("effect.zipPar.runsBothAndPairs")
@safe
unittest
{
    Sched s;
    if (Sched.create(s).hasError)
        return; // SKIP
    scope (exit) s.destroy();

    static struct EmptyCtx { }

    auto r = s.run(() {
        cast(void) withScope!((ref sc) {
            EmptyCtx ctx;
            auto eff = zipPar(succeed(3), succeed(4));
            auto outcome = run(eff, sc, ctx);
            assert(!outcome.hasError);
            assert(outcome.value[0] == 3 && outcome.value[1] == 4);
        })(s);
    });
    assert(!r.hasError);
}
