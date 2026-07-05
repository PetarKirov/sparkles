/**
Schedules as values and the retry/repeat/timeout/race drivers (SPEC §10.4).

Schedule values are immutable PODs: all mutability (attempt counters, jitter
RNG) lives in a separate `State`, the step is pure, and composition is by
expression template — `enum policy = exponential(100.msecs) & recurs(5);`
folds at CTFE. Composition uses `&` (both continue, max delay) and `|`
(either continues, min delay); D does not permit overloading `&&`/`||`.

The drivers are ordinary functions over scopes and a clock capability —
sleeps ride the passed clock, so `TestClock` virtualizes backoff and
deadlines. $(B Effects-side module).
*/
module sparkles.event_horizon.schedule;

import core.time : Duration, MonoTime, msecs;

import expected : Expected;

import sparkles.event_horizon.capability : isFiberExecutor;
import sparkles.event_horizon.cause;
import sparkles.event_horizon.clock : isClock;
import sparkles.event_horizon.errors : IoError, NoGcHook;
import sparkles.event_horizon.scope_ : Scope, ScopeOptions, withScope;

/// One step's verdict.
struct Decision
{
    bool cont;      /// keep going?
    Duration delay; /// sleep before the next attempt (zero = immediately)
}

/// Facts handed to `next`. Schedules never do I/O or read clocks — time
/// comes in, decisions come out (pure, CTFE-composable, test-trivial).
struct StepInfo
{
    size_t attempt; /// completed attempts so far (0 on the first failure)
    MonoTime now;   /// current (possibly virtual) time
    MonoTime start; /// when the retry/repeat loop began
}

/// The schedule concept: a `State` type plus a pure step.
enum bool isSchedule(S) = is(S.State) && __traits(compiles, (ref S s) {
    S.State st = s.initialState();
    Decision d = s.next(st, StepInfo.init);
});

/// Composition operators for every schedule (see the module note on `&`/`|`).
mixin template ScheduleOps()
{
    /// `a & b`: continue iff both continue; delay = max.
    auto opBinary(string op : "&", B)(B rhs) const if (isSchedule!B)
        => Intersect!(typeof(this), B)(this, rhs);

    /// `a | b`: continue if either continues; delay = min of continuing.
    auto opBinary(string op : "|", B)(B rhs) const if (isSchedule!B)
        => Union!(typeof(this), B)(this, rhs);
}

/// Continue for at most `n` attempts, without delay.
struct Recurs
{
    mixin ScheduleOps;

    size_t n; /// attempt budget

    /// No per-run state.
    static struct State
    {
    }

    State initialState() const @safe pure nothrow @nogc => State();

    /// ditto
    Decision next(ref State, in StepInfo si) const @safe pure nothrow @nogc
        => Decision(si.attempt < n, Duration.zero);
}

/// ditto
Recurs recurs(size_t n) @safe pure nothrow @nogc => Recurs(n);

/// A fixed interval between attempts, forever.
struct Spaced
{
    mixin ScheduleOps;

    Duration interval; /// the fixed delay

    /// No per-run state.
    static struct State
    {
    }

    State initialState() const @safe pure nothrow @nogc => State();

    /// ditto
    Decision next(ref State, in StepInfo) const @safe pure nothrow @nogc
        => Decision(true, interval);
}

/// ditto
Spaced spaced(Duration interval) @safe pure nothrow @nogc => Spaced(interval);

/// Exponential backoff: `base × factor^attempt`, saturating at `cap`.
struct Exponential
{
    mixin ScheduleOps;

    Duration base;             /// first delay
    double factor = 2.0;       /// growth per attempt
    Duration cap = Duration.max; /// saturation

    /// No per-run state (the attempt index drives the exponent).
    static struct State
    {
    }

    State initialState() const @safe pure nothrow @nogc => State();

    /// ditto
    Decision next(ref State, in StepInfo si) const @safe pure nothrow @nogc
    {
        double d = base.total!"hnsecs";
        foreach (_; 0 .. si.attempt)
        {
            d *= factor;
            if (d >= cast(double) cap.total!"hnsecs")
                return Decision(true, cap);
        }
        import core.time : hnsecs;

        return Decision(true, (cast(long) d).hnsecs);
    }
}

/// ditto
Exponential exponential(Duration base, double factor = 2.0) @safe pure nothrow @nogc
    => Exponential(base, factor);

/// Multiplies the inner delay by a deterministic pseudo-random factor in
/// `[lo, hi]`; the xorshift state lives in `State`, so runs are
/// reproducible by construction.
struct Jittered(S)
if (isSchedule!S)
{
    mixin ScheduleOps;

    S inner;           /// the wrapped schedule
    double lo = 0.8;   /// lower factor bound
    double hi = 1.2;   /// upper factor bound
    ulong seed = 0x9E3779B97F4A7C15; /// RNG seed

    /// Inner state + the RNG word.
    static struct State
    {
        S.State inner;
        ulong rng;
    }

    State initialState() const
        => State(inner.initialState(), seed);

    /// ditto
    Decision next(ref State st, in StepInfo si) const
    {
        auto d = inner.next(st.inner, si);
        if (!d.cont || d.delay <= Duration.zero)
            return d;
        // xorshift64*
        st.rng ^= st.rng >> 12;
        st.rng ^= st.rng << 25;
        st.rng ^= st.rng >> 27;
        const unit = ((st.rng * 0x2545F4914F6CDD1D) >> 11) / cast(double) (1UL << 53);
        const factor = lo + (hi - lo) * unit;
        import core.time : hnsecs;

        d.delay = (cast(long) (d.delay.total!"hnsecs" * factor)).hnsecs;
        return d;
    }
}

/// ditto
auto jittered(S)(S s, double lo = 0.8, double hi = 1.2, ulong seed = 0)
if (isSchedule!S)
    => Jittered!S(s, lo, hi, seed != 0 ? seed : 0x9E3779B97F4A7C15);

/// Stops once the total elapsed time exceeds `limit`.
struct UpTo(S)
if (isSchedule!S)
{
    mixin ScheduleOps;

    S inner;        /// the wrapped schedule
    Duration limit; /// total-elapsed budget

    /// Inner state only.
    static struct State
    {
        S.State inner;
    }

    State initialState() const => State(inner.initialState());

    /// ditto
    Decision next(ref State st, in StepInfo si) const
    {
        if (si.now - si.start > limit)
            return Decision(false, Duration.zero);
        return inner.next(st.inner, si);
    }
}

/// ditto
auto upTo(S)(S s, Duration limit) if (isSchedule!S) => UpTo!S(s, limit);

/// `a & b` (see `ScheduleOps`).
struct Intersect(A, B)
if (isSchedule!A && isSchedule!B)
{
    mixin ScheduleOps;

    A a; /// left operand
    B b; /// right operand

    /// Both operands' states.
    static struct State
    {
        A.State a;
        B.State b;
    }

    State initialState() const => State(a.initialState(), b.initialState());

    /// ditto
    Decision next(ref State st, in StepInfo si) const
    {
        const da = a.next(st.a, si);
        const db = b.next(st.b, si);
        return Decision(da.cont && db.cont,
            da.delay > db.delay ? da.delay : db.delay);
    }
}

/// `a | b` (see `ScheduleOps`).
struct Union(A, B)
if (isSchedule!A && isSchedule!B)
{
    mixin ScheduleOps;

    A a; /// left operand
    B b; /// right operand

    /// Both operands' states.
    static struct State
    {
        A.State a;
        B.State b;
    }

    State initialState() const => State(a.initialState(), b.initialState());

    /// ditto
    Decision next(ref State st, in StepInfo si) const
    {
        const da = a.next(st.a, si);
        const db = b.next(st.b, si);
        if (da.cont && db.cont)
            return Decision(true, da.delay < db.delay ? da.delay : db.delay);
        if (da.cont)
            return da;
        if (db.cont)
            return db;
        return Decision(false, Duration.zero);
    }
}

// ── the drivers (SPEC §10.4) ────────────────────────────────────────────────

/**
Retries `op` per `policy`, sleeping between attempts on `clock` —
`TestClock` virtualizes the backoff. Only the `fail` channel is retried; a
defect or an interrupt terminates immediately (retrying a logic bug or a
cancellation is always wrong).
*/
Outcome!(T, E) retry(S, Clk, Sc, T, E)(ref Sc sc, ref Clk clock, S policy,
    Expected!(T, E, NoGcHook) delegate() op)
if (isSchedule!S && isClock!Clk)
{
    import core.lifetime : move;

    auto state = policy.initialState();
    const start = clock.now();
    size_t attempt;
    for (;;)
    {
        auto r = op();
        if (!r.hasError)
        {
            static if (is(T == void))
                return outcomeOk!E();
            else
                return outcomeOk!E(move(r.value));
        }
        if (interruptedHere(sc))
            return outcomeErr!(T, E)(Cause!E.fromInterrupt(
                pendingHere(sc)));

        const d = policy.next(state, StepInfo(attempt, clock.now(), start));
        ++attempt;
        if (!d.cont)
            return outcomeErr!(T, E)(Cause!E.fromFailure(r.error));
        if (d.delay > Duration.zero)
        {
            auto slept = clock.sleep(d.delay);
            if (slept.hasError || interruptedHere(sc))
                return outcomeErr!(T, E)(Cause!E.fromInterrupt(pendingHere(sc)));
        }
    }
}

/// The mirror image: repeats a $(I succeeding) `op` per `policy`; the last
/// success (or the first failure) is the outcome.
Outcome!(T, E) repeat(S, Clk, Sc, T, E)(ref Sc sc, ref Clk clock, S policy,
    Expected!(T, E, NoGcHook) delegate() op)
if (isSchedule!S && isClock!Clk)
{
    import core.lifetime : move;

    auto state = policy.initialState();
    const start = clock.now();
    size_t attempt;
    for (;;)
    {
        auto r = op();
        if (r.hasError)
            return outcomeErr!(T, E)(Cause!E.fromFailure(r.error));

        const d = policy.next(state, StepInfo(attempt, clock.now(), start));
        ++attempt;
        if (!d.cont)
        {
            static if (is(T == void))
                return outcomeOk!E();
            else
                return outcomeOk!E(move(r.value));
        }
        if (d.delay > Duration.zero)
        {
            auto slept = clock.sleep(d.delay);
            if (slept.hasError || interruptedHere(sc))
                return outcomeErr!(T, E)(Cause!E.fromInterrupt(pendingHere(sc)));
        }
    }
}

/**
Runs `body_` under a deadline enforced through `clock` (SPEC §8.3 by way of
a watchdog daemon, so `TestClock` virtualizes it): expiry cancels the
subtree and surfaces as `Cause.interrupt` with `InterruptKind.deadline`
(`outcome.error.isTimeout`).
*/
Outcome!(T, E) timeout(Clk, Sc, T, E)(ref Sc sc, ref Clk clock, Duration limit,
    Expected!(T, E, NoGcHook) delegate() body_)
if (isClock!Clk)
{
    import core.lifetime : move;

    alias X = typeof(*sc._exec);

    static struct Slot
    {
        bool done;
        bool isErr;
        static if (!is(T == void))
            T value;
        E err;
    }

    Slot slot;
    auto outcome = withScope!((ref inner) {
        inner.spawnDaemon({
            cast(void) clock.sleep(limit);
            if (!slot.done)
                inner.cancel(Interrupt(InterruptKind.deadline));
        });
        auto r = body_();
        slot.done = true;
        if (r.hasError)
        {
            slot.isErr = true;
            slot.err = r.error;
        }
        else
        {
            static if (!is(T == void))
                slot.value = move(r.value);
        }
    }, E)(*sc._exec);

    if (outcome.hasError)
        return outcomeErr!(T, E)(outcome.error);
    if (interruptedHere(sc))
        return outcomeErr!(T, E)(Cause!E.fromInterrupt(pendingHere(sc)));
    if (slot.isErr)
        return outcomeErr!(T, E)(Cause!E.fromFailure(slot.err));
    static if (is(T == void))
        return outcomeOk!E();
    else
        return outcomeOk!E(move(slot.value));
}

/**
Races the contenders: the first to reach a terminal state wins; the rest
are cancelled (`InterruptKind.raceLost`) and joined. If every contender
fails, the last failure wins. (Both-can-win races drop the straggler's
result — the Eio caveat.)
*/
auto race(Sc, Bodies...)(ref Sc sc, Bodies contenders)
if (Bodies.length >= 2)
{
    import core.lifetime : move;
    import std.traits : ReturnType, TemplateArgsOf;

    alias R = ReturnType!(Bodies[0]);
    alias Args = TemplateArgsOf!R; // Expected!(T, E, NoGcHook)
    alias T = Args[0];
    alias E = Args[1];
    alias X = typeof(*sc._exec);

    static struct RaceState
    {
        bool done;
        bool anyWinner;
        size_t finished;
        bool isErr;
        static if (!is(T == void))
            T value;
        E err;
    }

    RaceState state;
    auto outcome = withScope!((ref inner) {
        static foreach (i; 0 .. Bodies.length)
            inner.spawn({
                auto r = contenders[i]();
                if (state.anyWinner)
                    return; // a straggler: result dropped
                ++state.finished;
                if (!r.hasError)
                {
                    state.anyWinner = true;
                    state.done = true;
                    static if (!is(T == void))
                        state.value = move(r.value);
                    inner.cancel(Interrupt(InterruptKind.raceLost));
                }
                else if (state.finished == Bodies.length)
                {
                    state.done = true;
                    state.isErr = true;
                    state.err = r.error;
                }
            });
    }, E)(*sc._exec);

    if (outcome.hasError)
        return outcomeErr!(T, E)(outcome.error);
    if (state.anyWinner)
    {
        static if (is(T == void))
            return outcomeOk!E();
        else
            return outcomeOk!E(move(state.value));
    }
    if (state.isErr)
        return outcomeErr!(T, E)(Cause!E.fromFailure(state.err));
    return outcomeErr!(T, E)(Cause!E.fromInterrupt(pendingHere(sc)));
}

private bool interruptedHere(Sc)(ref Sc sc)
    => sc._exec.currentContext().interrupted;

private Interrupt pendingHere(Sc)(ref Sc sc)
{
    auto f = sc._exec.currentContext();
    return f.interrupted ? f.pendingInterrupt : Interrupt(InterruptKind.cancelled);
}

@("schedule.values.composeAtCtfe")
@safe pure nothrow @nogc
unittest
{
    enum policy = exponential(10.msecs) & recurs(3);
    auto st = policy.initialState();

    auto d0 = policy.next(st, StepInfo(0, MonoTime.zero, MonoTime.zero));
    assert(d0.cont && d0.delay == 10.msecs);
    auto d1 = policy.next(st, StepInfo(1, MonoTime.zero, MonoTime.zero));
    assert(d1.cont && d1.delay == 20.msecs);
    auto d3 = policy.next(st, StepInfo(3, MonoTime.zero, MonoTime.zero));
    assert(!d3.cont, "recurs(3) stops the intersection");

    enum eager = spaced(50.msecs) | recurs(1);
    auto st2 = eager.initialState();
    auto e0 = eager.next(st2, StepInfo(0, MonoTime.zero, MonoTime.zero));
    assert(e0.cont && e0.delay == Duration.zero, "union takes the min delay");
    auto e5 = eager.next(st2, StepInfo(5, MonoTime.zero, MonoTime.zero));
    assert(e5.cont && e5.delay == 50.msecs, "spaced continues alone");
}

@("schedule.jittered.deterministic")
@safe pure nothrow @nogc
unittest
{
    auto a = jittered(spaced(100.msecs), 0.5, 1.5, 42);
    auto b = jittered(spaced(100.msecs), 0.5, 1.5, 42);
    auto sa = a.initialState();
    auto sb = b.initialState();
    foreach (i; 0 .. 4)
    {
        const da = a.next(sa, StepInfo(i, MonoTime.zero, MonoTime.zero));
        const db = b.next(sb, StepInfo(i, MonoTime.zero, MonoTime.zero));
        assert(da.delay == db.delay, "same seed, same jitter");
        assert(da.delay >= 50.msecs && da.delay <= 150.msecs);
    }
}
