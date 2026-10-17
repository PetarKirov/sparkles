/**
The model platform and its explorer: oracle 1 of
$(LINK2 ../../../../docs/specs/base/sync/testing.md, testing.md).

The parking lot and every primitive are written over a platform policy
(`sparkles.base.sync.platform`). `ModelPlatform` implements that policy as
scheduling points of a deterministic scheduler. Simulated threads run as
fibers on the calling thread; the explorer re-runs a scenario from scratch
for every schedule, depth-first over its choices, as CHESS and loom do:

- **Schedules.** At each scheduling point the explorer chooses the next
    thread. Dynamic partial-order reduction adds a backtrack point only where
    two threads' operations conflict without being ordered, and a preemption
    bound limits the search.
- **Weak memory.** Each atomic location keeps a bounded history of stores
    with vector clocks. A relaxed or acquire load branches over every store
    the D and C++20 memory models let it read; a read–modify–write reads the
    latest store and continues its release sequence. Plain data a scenario
    protects (`ModelCell`) is checked by vector clock, so a read or write that
    no release–acquire edge orders after a conflicting access is a race.
- **The environment.** The seam's `wait` may return spuriously, a deadline
    expires when the explorer advances the virtual clock, and the test parker's
    sleep may be cancelled, each within a per-execution budget.
- **Checks.** Every execution checks the scenario's own assertions, that no
    thread is left blocked forever (a lost wakeup or a deadlock), that no system
    call or suspension happens with a bucket locked (SYP10), and that no
    delivery touches a record whose park has returned (SYK8).

Seeded faults (`Fault`) break the parking lot or a primitive on purpose; each
scenario family's broken variant must be reported (testing.md, oracle 1).

Scenarios too large for exhaustive search run under a randomized priority
scheduler (PCT) instead, with recorded seeds.
*/
module sparkles.base.sync.model;

import core.thread : Fiber;
import std.traits : functionAttributes, functionLinkage, FunctionAttribute,
    isDelegate, isFunctionPointer, SetFunctionAttributes;

import sparkles.base.sync.parker;
import sparkles.base.sync.platform : Order;
import sparkles.base.sync.seam : Deadline, SeamResult, WakeCount;

/// Simulated threads per execution.
enum uint maxThreads = 4;

/// A vector clock over the simulated threads.
alias Clock = uint[maxThreads];

/// Stores an atomic location remembers (older ones can no longer be read).
enum uint historyLength = 6;

/// Consecutive stale reads of one location a thread may make.
enum uint maxStaleReads = 2;

/// Deliberately broken variants, which the explorer must report.
enum Fault : ubyte
{
    none,
    /// An unlock that skips the wake (its delivery).
    unlockSkipsWake,
    /// Validation outside the bucket lock.
    validateOutsideLock,
    /// A timeout that ignores a committed token.
    timeoutIgnoresToken,
    /// A release store weakened to relaxed: the thread parker's commit.
    commitRelaxed,
    /// A delivery through the record.
    deliveryThroughRecord,
    /// A bucket unlock that skips the wake of a bucket waiter.
    bucketUnlockSkipsWake,
    /// A primitive's release store weakened to relaxed (S2: mutex unlock).
    releaseRelaxed,
    /// The mutex's starvation bound never hands off (SYM8).
    noHandoff,
    /// An unlock that wakes despite a pending designated waker (SYM6).
    wakeDespiteDesignation,
}

/// How the explorer chooses.
enum Strategy : ubyte
{
    /// Exhaustive within the bound, with partial-order reduction.
    exhaustive,
    /// Randomized priority scheduling (PCT), for large scenarios.
    pct,
}

/// What one exploration may do.
struct ModelOptions
{
    uint preemptionBound = 2;
    /// Spurious seam returns per execution.
    uint spurious;
    /// Cancellations of test-parker sleeps per execution.
    uint cancels;
    /// Executions before the explorer gives up (reported, not a failure).
    ulong maxExecutions = 500_000;
    /// Scheduling points in one execution before it is a livelock.
    uint maxSteps = 50_000;
    Fault fault;
    Strategy strategy;
    /// PCT: runs, bug depth, and the seed of the first run.
    uint pctRuns = 2_000;
    uint pctDepth = 3;
    ulong seed = 1;
}

/// What an exploration found.
struct ModelReport
{
    ulong executions;
    /// The exhaustive search finished within `maxExecutions`.
    bool complete;
    /// The first failing execution, if any.
    bool failed;
    string failure;
    string trace;
}

// ---------------------------------------------------------------------------
// The platform.

/// The model policy: every operation is a scheduling point.
struct ModelPlatformT(bool portable)
{
    enum bool isModel = true;
    enum bool portableThreadParker = portable;

    alias Atomic(T) = ModelAtomic!T;
    alias PortableSleeper = ModelPortableSleeper;
    alias Fault = .Fault;

static:
    // `A` is a `ModelAtomic!T`, possibly `shared` or `const`.
    ValueOf!A load(Order o = Order.seqCst, A)(ref A a) @trusted nothrow @nogc
        => cast(ValueOf!A) nogc(&modelLoad!(ValueOf!A))(cast(void*) &a, o);

    /// Reads a location the caller's bucket lock protects: no scheduling point.
    ValueOf!A peek(A)(ref A a) @trusted nothrow @nogc
        => cast(ValueOf!A) nogc(&modelPeek!(ValueOf!A))(cast(void*) &a);

    void store(Order o = Order.seqCst, A, V)(ref A a, V v) @trusted nothrow @nogc
        => nogc(&modelStore!(ValueOf!A))(cast(void*) &a, o, cast(ValueOf!A) v);

    bool cas(Order s = Order.seqCst, Order f = failureOrder!s, A, T)(ref A a, ref T expected,
        T desired) @trusted nothrow @nogc
    {
        ulong e = expected;
        const ok = nogc(&modelCas!(ValueOf!A))(cast(void*) &a, s, f, e, cast(ValueOf!A) desired);
        expected = cast(T) e;
        return ok;
    }

    ValueOf!A exchange(Order o = Order.seqCst, A, V)(ref A a, V v) @trusted nothrow @nogc
        => cast(ValueOf!A) nogc(&modelRmw!(ValueOf!A))(cast(void*) &a, o, Rmw.exchange, cast(ValueOf!A) v);

    ValueOf!A fetchAdd(Order o = Order.seqCst, A, V)(ref A a, V v) @trusted nothrow @nogc
        => cast(ValueOf!A) nogc(&modelRmw!(ValueOf!A))(cast(void*) &a, o, Rmw.add, cast(ValueOf!A) v);

    ValueOf!A fetchOr(Order o = Order.seqCst, A, V)(ref A a, V v) @trusted nothrow @nogc
        => cast(ValueOf!A) nogc(&modelRmw!(ValueOf!A))(cast(void*) &a, o, Rmw.or, cast(ValueOf!A) v);

    ValueOf!A fetchAnd(Order o = Order.seqCst, A, V)(ref A a, V v) @trusted nothrow @nogc
        => cast(ValueOf!A) nogc(&modelRmw!(ValueOf!A))(cast(void*) &a, o, Rmw.and, cast(ValueOf!A) v);

    long now() @trusted nothrow @nogc => nogc(&modelNow)();

    size_t bucketOf(size_t key) @trusted nothrow @nogc => nogc(&modelBucketOf)(key);

    void parkReturned(const(void)* record) @trusted nothrow @nogc => nogc(&modelParkReturned)(record);

    void pause() @trusted nothrow @nogc => nogc(&modelYield)();

    void yieldThread() @trusted nothrow @nogc => nogc(&modelYield)();

    ThreadState!(ModelPlatformT!portable)* thread() @trusted nothrow @nogc
        => cast(ThreadState!(ModelPlatformT!portable)*) nogc(&modelThreadState)(portable);

    SeamResult seamWait(A)(ref A word, uint expected, Deadline d) @trusted nothrow @nogc
        => nogc(&modelSeamWait)(cast(void*) &word, expected, d);

    void seamWake(A)(ref A word, WakeCount count) @trusted nothrow @nogc
        => nogc(&modelSeamWake)(cast(size_t) &word, count);

    void seamWakeAddress(size_t word, WakeCount count) @trusted nothrow @nogc
        => nogc(&modelSeamWake)(word, count);

    void bucketLocked() @trusted nothrow @nogc => nogc(&modelBucketHeld)(+1);

    void bucketUnlocked() @trusted nothrow @nogc => nogc(&modelBucketHeld)(-1);

    void recordTouched(const(void)* record) @trusted nothrow @nogc
        => nogc(&modelRecordTouched)(record);

    bool faultActive(Fault f) @trusted nothrow @nogc => nogc(&modelFaultActive)(f);
}

/// The model platform with the native-seam thread parker.
alias ModelPlatform = ModelPlatformT!false;
/// The model platform with the portable fallback's thread parker (SYF2).
alias PortableModelPlatform = ModelPlatformT!true;

/// The value type of a (qualified) `ModelAtomic`.
template ValueOf(A)
{
    import std.traits : Unqual;

    alias ValueOf = Unqual!(typeof(A.initial));
}

/// Casts away `@nogc`: the model allocates, and only tests run it.
private auto nogc(T)(T fn) @trusted if (isFunctionPointer!T || isDelegate!T)
{
    enum attrs = functionAttributes!T | FunctionAttribute.nogc | FunctionAttribute.nothrow_;
    return cast(SetFunctionAttributes!(T, functionLinkage!T, attrs)) fn;
}

/**
An atomic location of the model. `.init` is a valid location holding
`T.init` (SYA6); it registers with the running execution on first use.
*/
struct ModelAtomic(T)
{
    private uint epoch;
    private uint id;
    /// The value it was constructed with, before its first store.
    T initial;

    this(T v) @safe pure nothrow @nogc
    {
        initial = v;
    }
}

/**
Plain memory a scenario protects with a primitive: every access is checked
against the vector clocks, so an access that no release–acquire edge orders
after a conflicting one fails as a data race.
*/
struct ModelCell(T)
{
    private T value;
    private uint lastWriter = uint.max;
    private uint lastWriteTime;
    private Clock reads;

    /// The value, unchecked: for a final check, once every thread has finished.
    T peek() const @safe pure nothrow @nogc => value;

    /// Reads, checking that the last write happens before this read.
    T get() @trusted
    {
        auto t = current();
        checkOrdered(lastWriter, lastWriteTime, t, "read");
        t.mem[t.id]++;
        reads[t.id] = t.mem[t.id];
        return value;
    }

    /// Writes, checking that every earlier access happens before it.
    void set(T v) @trusted
    {
        auto t = current();
        checkOrdered(lastWriter, lastWriteTime, t, "write");
        foreach (i, r; reads)
            if (i != t.id && r != 0 && r > t.mem[i])
                fail("data race: a write is not ordered after a read by thread " ~ itoa(i));
        t.mem[t.id]++;
        lastWriter = t.id;
        lastWriteTime = t.mem[t.id];
        reads = Clock.init;
        value = v;
    }

    private static void checkOrdered(uint writer, uint time, SimThread t, string what)
    {
        if (writer != uint.max && writer != t.id && t.mem[writer] < time)
            fail("data race: a " ~ what ~ " is not ordered after the write by thread "
                ~ itoa(writer) ~ " (a stale read under weak memory)");
    }
}

// ---------------------------------------------------------------------------
// Simulated threads.

private enum ThreadStatus : ubyte
{
    runnable,
    blocked,
    finished,
}

private enum BlockKind : ubyte
{
    none,
    seam,
    testParker,
    portableMutex,
    portableCond,
    await,
}

private final class SimThread
{
    uint id;
    Fiber fiber;
    ThreadStatus status;
    /// The operation it will perform when next scheduled.
    Op pending;
    /// The previous step was a yield, so switching away is no preemption.
    bool yielded;

    /// The memory-model clock (happens-before) and the partial-order clock.
    Clock mem, dpor;
    /// Per location: the newest store index this thread has seen (coherence).
    uint[uint] seen;
    /// Per location: consecutive stale reads, bounded so stores become visible.
    uint[uint] staleRun;

    // Blocking.
    BlockKind blockKind;
    size_t blockKey;
    Deadline blockDeadline;
    bool blockInterruptible;
    /// Set by a wake; `resultReason` says how the block ended.
    BlockEnd blockEnd;

    // Parker state.
    ThreadState!ModelPlatform tsNative;
    ThreadState!PortableModelPlatform tsPortable;
    TestParker testParker;
    bool usesTestParker;

    /// Locked buckets (SYP10).
    int bucketsHeld;
}

private enum BlockEnd : ubyte
{
    none,
    woken,
    spurious,
    timedOut,
    cancelled,
}

private enum OpKind : ubyte
{
    start,
    read,
    write,
    rmw,
    local,
    blockReturn,
}

private struct Op
{
    OpKind kind;
    size_t loc;
    /// A second location the operation writes: the clock, for a timeout.
    size_t loc2;

    bool conflicts(in Op o) const pure @safe nothrow @nogc
    {
        if (kind == OpKind.local || o.kind == OpKind.local)
            return false;
        const bothRead = kind == OpKind.read && o.kind == OpKind.read;
        return !bothRead && ((loc != 0 && (loc == o.loc || loc == o.loc2))
            || (loc2 != 0 && (loc2 == o.loc || loc2 == o.loc2)));
    }
}

// ---------------------------------------------------------------------------
// Memory.

private struct StoreEntry
{
    ulong value;
    uint thread;
    uint time;
    /// The clock an acquiring read joins: the release clock, carried along the release sequence.
    Clock sync;
    bool hasSync;
}

private final class Location
{
    uint id;
    size_t addr;
    StoreEntry[] stores;
    /// Absolute index of `stores[0]`.
    uint base;
    /// Partial-order clocks: of the last write and of the reads since.
    Clock dporWrite, dporReads;

    uint latest() const @safe pure nothrow @nogc => base + cast(uint) stores.length - 1;

    ref StoreEntry at(uint index) return @safe pure nothrow @nogc => stores[index - base];
}

private enum Rmw : ubyte
{
    exchange,
    add,
    or,
    and,
}

// ---------------------------------------------------------------------------
// The explorer's path.

private enum NodeKind : ubyte
{
    schedule,
    value,
}

private struct Node
{
    NodeKind kind;
    // Schedule nodes.
    ubyte enabled, backtrack, done, chosen;
    ubyte prevThread = ubyte.max;
    bool prevYielded;
    uint preemptions;
    Op op;
    Clock dporClock;
    // Value nodes.
    uint n, choice;
}

private final class Execution
{
    ModelOptions options;
    SimThread[] threads;
    Location[] locations;
    uint epoch;
    long clock;
    uint spuriousLeft, cancelsLeft;
    SimThread current;
    uint steps;
    string[] trace;
    bool traceOn;
    void delegate()[] finals;
    size_t[size_t] buckets;
    // Path replay.
    Node[] path;
    size_t depth;
    bool divergent;
    // PCT.
    bool pct;
    ulong rng;
    uint[maxThreads] priority;
    uint[] changePoints;
    uint pctStep;
}

// Per test thread: explorations on different threads are independent.
private Execution exec;
private uint nextEpoch = 1;

private SimThread current() @trusted
{
    assert(exec !is null && exec.current !is null, "a model operation outside a model execution");
    return exec.current;
}

private noreturn fail(string message) @trusted
{
    throw new ModelFailure(message);
}

/// A failed model check.
class ModelFailure : Error
{
    this(string msg) @safe pure nothrow
    {
        super(msg);
    }
}

private string itoa(size_t v) @safe pure nothrow
{
    if (v == 0)
        return "0";
    char[20] buf;
    size_t i = buf.length;
    while (v)
    {
        buf[--i] = cast(char)('0' + v % 10);
        v /= 10;
    }
    return buf[i .. $].idup;
}

// ---------------------------------------------------------------------------
// Scheduling points.

/// Announces `op` and gives the scheduler its choice of the next thread.
private void point(Op op) @trusted
{
    auto t = current();
    t.pending = op;
    Fiber.yield();
}

private void note(lazy string s) @trusted
{
    if (exec.traceOn)
        exec.trace ~= "T" ~ itoa(current().id) ~ ": " ~ s;
}

private Location location(T)(void* atomic) @trusted
{
    auto a = cast(ModelAtomic!T*) atomic;
    if (a.epoch != exec.epoch)
    {
        auto l = new Location;
        l.stores = [StoreEntry(cast(ulong) a.initial, uint.max, 0)];
        exec.locations ~= l;
        l.id = cast(uint) exec.locations.length;
        l.addr = cast(size_t) atomic;
        a.epoch = exec.epoch;
        a.id = l.id;
    }
    return exec.locations[a.id - 1];
}

/// The DPOR clock join of an access to `l` by `t`.
private void dporAccess(SimThread t, Location l, bool write) @safe
{
    join(t.dpor, l.dporWrite);
    if (write)
    {
        join(t.dpor, l.dporReads);
        l.dporWrite = t.dpor;
        l.dporReads = Clock.init;
    }
    else
        join(l.dporReads, t.dpor);
}

private void join(ref Clock a, in Clock b) @safe pure nothrow @nogc
{
    foreach (i; 0 .. maxThreads)
        if (b[i] > a[i])
            a[i] = b[i];
}

private bool acquires(Order o) @safe pure nothrow @nogc
    => o == Order.acquire || o == Order.acqRel || o == Order.seqCst;

private bool releases(Order o) @safe pure nothrow @nogc
    => o == Order.release || o == Order.acqRel || o == Order.seqCst;

private ulong modelLoad(T)(void* atomic, Order o) @trusted
{
    auto l = location!T(atomic);
    point(Op(OpKind.read, cast(size_t) atomic));
    auto t = current();
    t.mem[t.id]++;
    // Coherence: never older than a store this thread has seen, nor than a
    // store that happens before this load.
    uint floor = t.seen.get(l.id, l.base);
    if (floor < l.base)
        floor = l.base;
    foreach (i; floor .. l.latest + 1)
    {
        const e = l.at(i);
        if (e.thread == uint.max || t.mem[e.thread] >= e.time)
            floor = i;
    }
    uint index = l.latest;
    // A sequentially consistent load reads the latest store (an
    // under-approximation of the model, as in loom).
    // Stores become visible within a bounded number of reads ("a reasonable
    // amount of time"), so a spin on a stale value terminates.
    if (o != Order.seqCst && floor < l.latest && t.staleRun.get(l.id, 0) < maxStaleReads)
        index = l.latest - chooseValue(l.latest - floor + 1);
    if (index == l.latest)
        t.staleRun.remove(l.id);
    else
        t.staleRun[l.id] = t.staleRun.get(l.id, 0) + 1;
    const e = l.at(index);
    t.seen[l.id] = index;
    if (acquires(o) && e.hasSync)
        join(t.mem, e.sync);
    dporAccess(t, l, false);
    note("load " ~ itoa(e.value) ~ (index != l.latest ? " (stale)" : ""));
    return e.value;
}

private ulong modelPeek(T)(void* atomic) @trusted
{
    auto l = location!T(atomic);
    return l.at(l.latest).value;
}

private void appendStore(SimThread t, Location l, ulong v, bool release, const(StoreEntry)* prev) @trusted
{
    t.mem[t.id]++;
    StoreEntry e = StoreEntry(v, t.id, t.mem[t.id]);
    if (release)
    {
        e.sync = t.mem;
        e.hasSync = true;
    }
    if (prev !is null && prev.hasSync)
    {
        // A read–modify–write continues the release sequence it reads.
        join(e.sync, prev.sync);
        e.hasSync = true;
    }
    l.stores ~= e;
    // A store may satisfy a scenario thread awaiting this location.
    cast(void) wakeBlocked(BlockKind.await, l.addr, uint.max);
    if (l.stores.length > historyLength)
    {
        l.stores = l.stores[1 .. $].dup;
        ++l.base;
    }
    t.seen[l.id] = l.latest;
    dporAccess(t, l, true);
}

private void modelStore(T)(void* atomic, Order o, T v) @trusted
{
    auto l = location!T(atomic);
    point(Op(OpKind.write, cast(size_t) atomic));
    appendStore(current(), l, v, releases(o), null);
    note("store " ~ itoa(v));
}

private bool modelCas(T)(void* atomic, Order s, Order f, ref ulong expected, T desired) @trusted
{
    auto l = location!T(atomic);
    point(Op(OpKind.rmw, cast(size_t) atomic));
    auto t = current();
    t.mem[t.id]++;
    const e = l.at(l.latest);
    if (cast(T) e.value != cast(T) expected)
    {
        if (acquires(f) && e.hasSync)
            join(t.mem, e.sync);
        t.seen[l.id] = l.latest;
        dporAccess(t, l, false);
        expected = e.value;
        note("cas failed, read " ~ itoa(e.value));
        return false;
    }
    if (acquires(s) && e.hasSync)
        join(t.mem, e.sync);
    const prev = e;
    appendStore(t, l, desired, releases(s), &prev);
    note("cas " ~ itoa(prev.value) ~ " -> " ~ itoa(desired));
    return true;
}

private ulong modelRmw(T)(void* atomic, Order o, Rmw op, T v) @trusted
{
    auto l = location!T(atomic);
    point(Op(OpKind.rmw, cast(size_t) atomic));
    auto t = current();
    t.mem[t.id]++;
    const e = l.at(l.latest);
    if (acquires(o) && e.hasSync)
        join(t.mem, e.sync);
    const old = cast(T) e.value;
    T nv;
    final switch (op)
    {
    case Rmw.exchange: nv = v; break;
    case Rmw.add: nv = cast(T)(old + v); break;
    case Rmw.or: nv = cast(T)(old | v); break;
    case Rmw.and: nv = cast(T)(old & v); break;
    }
    const prev = e;
    appendStore(t, l, nv, releases(o), &prev);
    note("rmw " ~ itoa(old) ~ " -> " ~ itoa(nv));
    return old;
}

private enum size_t clockLoc = 1;

/**
A key's bucket under the model. Heap addresses differ between executions, so
hashing them would change which keys collide from one schedule to the next;
the model gives them buckets in order of first use instead. The small
synthetic keys collision scenarios choose keep the real hash (SYP1).
*/
private size_t modelBucketOf(size_t key) @trusted
{
    import sparkles.base.sync.parking_lot : bucketIndex, parkingBuckets;

    if (key < syntheticKeys)
        return bucketIndex(key);
    if (auto p = key in exec.buckets)
        return *p;
    // Spread from the top, away from the synthetic keys' buckets.
    const b = parkingBuckets - 1 - exec.buckets.length;
    exec.buckets[key] = b;
    return b;
}

/// Keys below this are synthetic: hashed as in production.
enum size_t syntheticKeys = 0x100_0000;

private long modelNow() @trusted
{
    point(Op(OpKind.read, clockLoc));
    return exec.clock;
}

private void modelYield() @trusted
{
    current().yielded = true;
    point(Op(OpKind.local, 0));
}

private void* modelThreadState(bool portable) @trusted
{
    auto t = current();
    return portable ? cast(void*) &t.tsPortable : cast(void*) &t.tsNative;
}

private bool modelFaultActive(Fault f) @trusted => exec.options.fault == f;

private void modelBucketHeld(int delta) @trusted
{
    current().bucketsHeld += delta;
    assert(current().bucketsHeld >= 0);
}

private void checkNoBucketHeld(string what) @trusted
{
    if (current().bucketsHeld > 0)
        fail(what ~ " with a bucket locked (SYP10)");
}

// ---------------------------------------------------------------------------
// Blocking: the seam, the test parker, the portable sleeper.

/// Blocks the current thread until a wake, or an environment event the explorer chooses.
private BlockEnd block(BlockKind kind, size_t key, Deadline d, bool interruptible) @trusted
{
    auto t = current();
    t.blockKind = kind;
    t.blockKey = key;
    t.blockDeadline = d;
    t.blockInterruptible = interruptible;
    t.blockEnd = BlockEnd.none;
    t.status = ThreadStatus.blocked;
    t.pending = Op(OpKind.blockReturn, key);
    Fiber.yield();
    // Resumed: woken, or the explorer picked an environment event.
    t.status = ThreadStatus.runnable;
    t.blockKind = BlockKind.none;
    const r = t.blockEnd;
    if (r == BlockEnd.timedOut && t.blockDeadline.ticks > exec.clock)
        exec.clock = t.blockDeadline.ticks;
    return r;
}

/// Wakes threads blocked on `key`: the first `count` of them, or all.
private uint wakeBlocked(BlockKind kind, size_t key, uint count) @trusted
{
    uint woke;
    foreach (t; exec.threads)
        if (t.status == ThreadStatus.blocked && t.blockKind == kind && t.blockKey == key
            && t.blockEnd == BlockEnd.none)
        {
            t.blockEnd = BlockEnd.woken;
            t.status = ThreadStatus.runnable;
            if (++woke == count)
                break;
        }
    return woke;
}

private SeamResult modelSeamWait(void* word, uint expected, Deadline d) @trusted
{
    checkNoBucketHeld("a seam wait");
    auto l = location!uint(word);
    point(Op(OpKind.rmw, cast(size_t) word));
    auto t = current();
    t.mem[t.id]++;
    // The kernel compares the current value; a futex carries no
    // happens-before edge (SYF1), so nothing is joined.
    const v = cast(uint) l.at(l.latest).value;
    // A read of the latest store: later loads cannot read an older one (coherence).
    t.seen[l.id] = l.latest;
    t.staleRun.remove(l.id);
    dporAccess(t, l, true);
    if (v != expected)
    {
        note("seam wait: value differs");
        return SeamResult.woken;
    }
    if (d.passed(exec.clock))
        return SeamResult.timedOut;
    note("seam wait: sleeps");
    const r = block(BlockKind.seam, cast(size_t) word, d, false);
    note("seam wait: returns " ~ (r == BlockEnd.timedOut ? "timed out" : "woken"));
    return r == BlockEnd.timedOut ? SeamResult.timedOut : SeamResult.woken;
}

private void modelSeamWake(size_t word, WakeCount count) @trusted
{
    checkNoBucketHeld("a seam wake");
    point(Op(OpKind.rmw, word));
    auto t = current();
    t.mem[t.id]++;
    const n = wakeBlocked(BlockKind.seam, word, count == WakeCount.one ? 1 : uint.max);
    note("seam wake: " ~ itoa(n));
}

private void modelRecordTouched(const(void)* record) @trusted
{
    // A record is touched by an unpark only while its park is in progress or
    // its registration is live; a test parker's record knows which.
    foreach (t; exec.threads)
        if (cast(const(void)*) &t.testParker.record is record && t.testParker.returned
            && !t.testParker.record.registered && !t.testParker.record.queued)
            fail("a delivery or unpark touched a record whose park has returned (SYK8)");
}

// ---------------------------------------------------------------------------
// The test parker: a fiber-like parker whose sleep the explorer may cancel,
// whose bucket wait yields (SYP13), and whose wakes are not exact.

/// Counters a scenario reads after an execution.
struct TestParkerStats
{
    uint settles;
    uint prepares;
    uint commits;
    uint deliveries;
    uint parks;
}

private struct TestParker
{
    WaitRecord!ModelPlatform record;
    uint generation;
    /// The generation a wake was committed for; deliveries name it.
    uint committedGeneration;
    bool returned = true;
    bool protectedRegion;
    TestParkerStats stats;
}

private __gshared immutable ParkerVtbl!ModelPlatform testParkerVtbl = ParkerVtbl!ModelPlatform(
    &tpkRecord, &tpkPrepare, &tpkSleep, &tpkCommit, &tpkBucketWait, &tpkRelax, &tpkSettle,
    &tpkProtected, exactWake: false, deliveryTouchesRecord: false);

private TestParker* tpk(void* ctx) @trusted nothrow @nogc => cast(TestParker*) ctx;

private WaitRecord!ModelPlatform* tpkRecord(void* ctx) @trusted nothrow @nogc
{
    auto p = tpk(ctx);
    p.returned = false;
    ++p.stats.parks;
    return &p.record;
}

private void tpkPrepare(void* ctx, WaitRecord!ModelPlatform* rec) @trusted nothrow @nogc
{
    auto p = tpk(ctx);
    ++p.generation;
    ++p.stats.prepares;
}

private SleepResult tpkSleep(void* ctx, WaitRecord!ModelPlatform* rec, Deadline d, bool interruptible)
    @trusted nothrow @nogc
    => nogc(&tpkSleepImpl)(ctx, d, interruptible);

private SleepResult tpkSleepImpl(void* ctx, Deadline d, bool interruptible) @trusted
{
    checkNoBucketHeld("a fiber suspension");
    auto p = tpk(ctx);
    if (p.committedGeneration == p.generation)
        return SleepResult.woken; // already committed and delivered
    const r = block(BlockKind.testParker, cast(size_t) ctx, d, interruptible && !p.protectedRegion);
    final switch (r)
    {
    case BlockEnd.none:
    case BlockEnd.woken:
    case BlockEnd.spurious:
        return SleepResult.woken;
    case BlockEnd.timedOut:
        return SleepResult.timedOut;
    case BlockEnd.cancelled:
        return SleepResult.cancelled;
    }
}

private WakeHandle tpkCommit(void* ctx, WaitRecord!ModelPlatform* rec) @trusted nothrow @nogc
{
    auto p = tpk(ctx);
    p.committedGeneration = p.generation;
    ++p.stats.commits;
    // The handle names scheduler storage (the simulated thread), never the
    // record (SYK8) — unless the seeded fault delivers through it.
    if (nogc(&modelFaultActive)(Fault.deliveryThroughRecord))
        return WakeHandle(&tpkDeliverThroughRecord, cast(size_t) rec, p.generation);
    return WakeHandle(&tpkDeliver, cast(size_t) ctx, p.generation);
}

private void tpkDeliver(size_t ctx, size_t generation) @trusted nothrow @nogc
    => nogc(&tpkDeliverImpl)(ctx, generation);

private void tpkDeliverImpl(size_t ctx, size_t generation) @trusted
{
    checkNoBucketHeld("a loop post");
    point(Op(OpKind.rmw, ctx));
    auto p = tpk(cast(void*) ctx);
    ++p.stats.deliveries;
    // A delivery for an earlier generation is at most a spurious return of a
    // later sleep (SYK8), which the parking lot absorbs (SYP4).
    cast(void) wakeBlocked(BlockKind.testParker, ctx, 1);
}

private void tpkDeliverThroughRecord(size_t rec, size_t generation) @trusted nothrow @nogc
    => nogc(&tpkDeliverThroughRecordImpl)(rec, generation);

private void tpkDeliverThroughRecordImpl(size_t rec, size_t generation) @trusted
{
    point(Op(OpKind.rmw, rec));
    modelRecordTouched(cast(void*) rec);
    foreach (t; exec.threads)
        if (cast(size_t) &t.testParker.record == rec)
            cast(void) wakeBlocked(BlockKind.testParker, cast(size_t) &t.testParker, 1);
}

private void tpkBucketWait(void* ctx, ref ModelAtomic!uint word, uint expected) @trusted nothrow @nogc
    => nogc(&modelYield)();

private void tpkRelax(void* ctx, uint step) @trusted nothrow @nogc => nogc(&modelYield)();

private void tpkSettle(void* ctx, WaitRecord!ModelPlatform* rec) @trusted nothrow @nogc
{
    ++tpk(ctx).stats.settles;
}

private bool tpkProtected(void* ctx) @trusted nothrow @nogc => tpk(ctx).protectedRegion;

/// Marks the end of a park, for the SYK8 check of the test parker's records.
private void modelParkReturned(const(void)* record) @trusted
{
    auto t = current();
    if (cast(const(void)*) &t.testParker.record is record)
        t.testParker.returned = true;
}

// ---------------------------------------------------------------------------
// The portable fallback's sleeper, modelled: a mutex, a condition variable
// and a flag, with every step a scheduling point (SYF2).

/// The model's portable sleeper.
struct ModelPortableSleeper
{
    private bool mutexHeld;
    private bool flag;
    private uint deliveriesInFlight;

    void prepare() @trusted nothrow @nogc => nogc(&portablePrepare)(&this);

    bool sleep(Deadline d) @trusted nothrow @nogc => nogc(&portableSleep)(&this, d);

    void deliver() @trusted nothrow @nogc => nogc(&portableDeliver)(&this);
}

private void portableLock(ModelPortableSleeper* s) @trusted
{
    point(Op(OpKind.rmw, cast(size_t) s));
    while (s.mutexHeld)
    {
        cast(void) block(BlockKind.portableMutex, cast(size_t) s, Deadline.never, false);
        point(Op(OpKind.rmw, cast(size_t) s));
    }
    s.mutexHeld = true;
}

private void portableUnlock(ModelPortableSleeper* s) @trusted
{
    point(Op(OpKind.rmw, cast(size_t) s));
    s.mutexHeld = false;
    cast(void) wakeBlocked(BlockKind.portableMutex, cast(size_t) s, 1);
}

private void portablePrepare(ModelPortableSleeper* s) @trusted
{
    portableLock(s);
    s.flag = false;
    portableUnlock(s);
}

private bool portableSleep(ModelPortableSleeper* s, Deadline d) @trusted
{
    portableLock(s);
    while (!s.flag)
    {
        if (d.passed(exec.clock))
        {
            portableUnlock(s);
            return false;
        }
        // Condition wait: release, block, reacquire.
        s.mutexHeld = false;
        cast(void) wakeBlocked(BlockKind.portableMutex, cast(size_t) s, 1);
        cast(void) block(BlockKind.portableCond, cast(size_t) s, d, false);
        portableLock(s);
    }
    portableUnlock(s);
    if (s.deliveriesInFlight)
        fail("the portable waiter returned before its delivery released the mutex (SYF2)");
    return true;
}

private void portableDeliver(ModelPortableSleeper* s) @trusted
{
    ++s.deliveriesInFlight;
    portableLock(s);
    s.flag = true;
    cast(void) wakeBlocked(BlockKind.portableCond, cast(size_t) s, 1);
    s.mutexHeld = false;
    --s.deliveriesInFlight;
    point(Op(OpKind.rmw, cast(size_t) s));
    cast(void) wakeBlocked(BlockKind.portableMutex, cast(size_t) s, 1);
}

// ---------------------------------------------------------------------------
// Choices.

/// Chooses one of `n` values (n > 1), as the path or the strategy says.
private uint chooseValue(uint n) @trusted
{
    assert(n > 1);
    if (exec.pct)
        return cast(uint)(nextRandom() % n);
    if (exec.depth < exec.path.length)
    {
        auto node = &exec.path[exec.depth++];
        if (node.kind != NodeKind.value || node.n != n)
            fail("the scenario is not deterministic: a replayed choice diverged");
        return node.choice;
    }
    Node node;
    node.kind = NodeKind.value;
    node.n = n;
    exec.path ~= node;
    ++exec.depth;
    return 0;
}

private ulong nextRandom() @trusted
{
    // xorshift64*
    auto x = exec.rng;
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    exec.rng = x;
    return x * 0x2545_F491_4F6C_DD1DUL;
}

/// Whether thread `t` can take a step: runnable, or blocked with an environment event available.
private bool canStep(SimThread t) @trusted
{
    if (t.status == ThreadStatus.runnable)
        return true;
    if (t.status != ThreadStatus.blocked)
        return false;
    return environmentEvents(t) != 0;
}

/// The environment events that could end `t`'s block, as a bit set of BlockEnd.
private uint environmentEvents(SimThread t) @trusted
{
    uint events;
    if (!t.blockDeadline.isNever)
        events |= 1 << BlockEnd.timedOut;
    if (exec.spuriousLeft && (t.blockKind == BlockKind.seam || t.blockKind == BlockKind.testParker))
        events |= 1 << BlockEnd.spurious;
    if (exec.cancelsLeft && t.blockKind == BlockKind.testParker && t.blockInterruptible)
        events |= 1 << BlockEnd.cancelled;
    return events;
}

/// Ends a blocked thread's block by an environment event, choosing which.
private void takeEnvironmentEvent(SimThread t) @trusted
{
    const events = environmentEvents(t);
    BlockEnd[3] options;
    uint n;
    foreach (e; [BlockEnd.timedOut, BlockEnd.spurious, BlockEnd.cancelled])
        if (events & (1 << e))
            options[n++] = e;
    const pick = n > 1 ? options[chooseValue(n)] : options[0];
    if (pick == BlockEnd.spurious)
        --exec.spuriousLeft;
    if (pick == BlockEnd.cancelled)
        --exec.cancelsLeft;
    t.blockEnd = pick;
}

// ---------------------------------------------------------------------------
// The scenario interface.

/// What a scenario sets up for each execution.
struct Scenario
{
    private Execution e;

    /// Adds a simulated thread running `body`; `testParker` installs the test parker.
    void thread(void delegate() body, bool testParker = false) @trusted
    {
        assert(e.threads.length < maxThreads, "at most maxThreads simulated threads");
        auto t = new SimThread;
        t.id = cast(uint) e.threads.length;
        t.usesTestParker = testParker;
        t.pending = Op(OpKind.start, 0);
        t.fiber = new Fiber({
            if (t.usesTestParker)
            {
                t.tsNative.current = Parker!ModelPlatform(&testParkerVtbl, cast(void*) &t.testParker);
            }
            body();
        }, 64 * 1024);
        e.threads ~= t;
    }

    /**
    Calls `body(i)` for `i` in `[0, n)`, each call with its own frame: a
    closure created in a `foreach` body shares the loop variable (D issue 2043),
    so threads spawned there would all see its last value.
    */
    void each(uint n, scope void delegate(uint i) body) @trusted
    {
        foreach (i; 0 .. n)
            body(i);
    }

    /// Runs `check` after every thread has finished.
    void finally_(void delegate() check) @trusted
    {
        e.finals ~= check;
    }
}

/// The test parker's counters for simulated thread `id`, in the running execution.
TestParkerStats testParkerStats(uint id) @trusted => exec.threads[id].testParker.stats;

/// Sets whether simulated thread `id`'s test parker is in a protected region (SYI4).
void setProtectedRegion(bool on) @trusted
{
    current().testParker.protectedRegion = on;
}

/// The id of the running simulated thread.
uint threadId() @trusted => current().id;

/// The model's virtual clock now (no scheduling point).
long virtualNow() @trusted => exec.clock;

/// A deadline `ticks` after the start of the execution's virtual time.
Deadline virtualDeadline(long ticks) @safe pure nothrow @nogc => Deadline(ticks);

/// Records a line in the trace a failure prints.
void traceNote(string s) @trusted
{
    if (exec !is null && exec.traceOn)
        exec.trace ~= "T" ~ itoa(current().id) ~ ": " ~ s;
}

// ---------------------------------------------------------------------------
// The explorer.

/**
Explores `setup`'s scenario: runs it once per schedule, depth-first, until
every schedule within the bound has run, a check fails, or `maxExecutions`
is reached. The first failure is reported with its schedule.
*/
ModelReport explore(ModelOptions o, void delegate(ref Scenario) setup) @trusted
{
    import sparkles.base.sync.parking_lot : resetTable;

    ModelReport report;
    Node[] path;
    ulong pctSeed = o.seed;
    while (true)
    {
        exec = new Execution;
        exec.options = o;
        exec.epoch = nextEpoch++;
        exec.spuriousLeft = o.spurious;
        exec.cancelsLeft = o.cancels;
        exec.path = path;
        exec.pct = o.strategy == Strategy.pct;
        if (exec.pct)
            exec.rng = pctSeed | 1;
        resetTable!ModelPlatform();
        resetTable!PortableModelPlatform();

        auto s = Scenario(exec);
        setup(s);
        if (exec.pct)
            initPct();
        string failure = runExecution();
        ++report.executions;
        if (failure !is null)
        {
            // Re-run the same schedule with the trace on, for the report.
            report.failed = true;
            report.failure = failure;
            report.trace = replayTrace(o, setup, exec.path[0 .. exec.depth].dup, pctSeed);
            exec = null;
            return report;
        }
        if (exec.pct)
        {
            pctSeed = pctSeed * 6_364_136_223_846_793_005UL + 1_442_695_040_888_963_407UL;
            if (report.executions >= o.pctRuns)
            {
                report.complete = true;
                break;
            }
            continue;
        }
        path = nextPath(exec.path[0 .. exec.depth]);
        if (path is null)
        {
            report.complete = true;
            break;
        }
        if (report.executions >= o.maxExecutions)
            break;
    }
    exec = null;
    return report;
}

/// Runs one execution to its end; returns the failure, or null.
private string runExecution() @trusted
{
    try
    {
        while (true)
        {
            if (++exec.steps > exec.options.maxSteps)
                fail("no progress within " ~ itoa(exec.options.maxSteps)
                    ~ " scheduling points (a livelock)");
            auto t = pickThread();
            if (t is null)
            {
                foreach (th; exec.threads)
                    if (th.status != ThreadStatus.finished)
                        fail("thread " ~ itoa(th.id)
                            ~ " is blocked forever: a lost wakeup or a deadlock");
                break;
            }
            if (t.status == ThreadStatus.blocked)
                takeEnvironmentEvent(t);
            exec.current = t;
            t.yielded = false;
            t.fiber.call();
            exec.current = null;
            if (t.fiber.state == Fiber.State.TERM)
                t.status = ThreadStatus.finished;
        }
        foreach (f; exec.finals)
            f();
    }
    catch (Throwable e)
    {
        exec.current = null;
        return e.msg.length ? e.msg.idup : typeid(e).name;
    }
    return null;
}

/// The next thread to step, recording or replaying the schedule node.
private SimThread pickThread() @trusted
{
    ubyte enabled;
    foreach (t; exec.threads)
        if (canStep(t))
            enabled |= cast(ubyte)(1 << t.id);
    if (enabled == 0)
        return null;

    // The previous step's thread, for preemption counting.
    ubyte prev = ubyte.max;
    bool prevYielded;
    uint preemptions;
    foreach_reverse (ref n; exec.path[0 .. exec.depth])
        if (n.kind == NodeKind.schedule)
        {
            prev = n.chosen;
            preemptions = n.preemptions + ((n.prevThread != ubyte.max && n.prevThread != n.chosen
                && !n.prevYielded && (n.enabled & (1 << n.prevThread))) ? 1 : 0);
            break;
        }
    if (prev != ubyte.max)
        prevYielded = exec.threads[prev].yielded || exec.threads[prev].status != ThreadStatus.runnable;
    // Fairness (as in CHESS): a thread that just yielded is not chosen again
    // while another can run, so a spin cannot starve the thread it waits for.
    if (prev != ubyte.max && exec.threads[prev].yielded && (enabled & ~(1 << prev)))
        enabled &= cast(ubyte) ~(1 << prev);

    ubyte chosen;
    if (exec.pct)
        chosen = pctChoose(enabled);
    else if (exec.depth < exec.path.length)
    {
        auto node = &exec.path[exec.depth];
        if (node.kind != NodeKind.schedule || !(node.enabled & (1 << node.chosen)))
            fail("the scenario is not deterministic: a replayed schedule diverged");
        chosen = node.chosen;
    }
    else
        chosen = defaultChoice(enabled, prev, prevYielded);

    auto t = exec.threads[chosen];
    // Record the event this step performs, and run DPOR's analysis.
    Node node;
    if (!exec.pct && exec.depth < exec.path.length)
        node = exec.path[exec.depth];
    else
    {
        node.kind = NodeKind.schedule;
        node.enabled = enabled;
        node.chosen = chosen;
        node.backtrack = cast(ubyte)(1 << chosen);
        node.prevThread = prev;
        node.prevYielded = prevYielded;
        node.preemptions = preemptions;
    }
    // A blocked thread's step is an environment event: it ends the block (the
    // key) and, for a timeout, advances the clock.
    node.op = t.status == ThreadStatus.blocked ? Op(OpKind.rmw, t.blockKey, clockLoc) : t.pending;
    if (!exec.pct)
        dporBacktrack(exec.depth, chosen, node.op, t);
    t.dpor[chosen]++;
    node.dporClock = t.dpor;
    if (exec.pct)
    {
        ++exec.pctStep;
        return t;
    }
    if (exec.depth < exec.path.length)
        exec.path[exec.depth] = node;
    else
        exec.path ~= node;
    ++exec.depth;
    return t;
}

private ubyte defaultChoice(ubyte enabled, ubyte prev, bool prevYielded) @safe pure nothrow @nogc
{
    if (prev != ubyte.max && !prevYielded && (enabled & (1 << prev)))
        return prev;
    // Round robin after a yield, so spinning threads let the others run.
    const start = prev == ubyte.max ? 0 : prev + 1;
    foreach (k; 0 .. maxThreads)
    {
        const i = (start + k) % maxThreads;
        if (enabled & (1 << i))
            return cast(ubyte) i;
    }
    assert(0);
}

/**
Classic DPOR (Flanagan and Godefroid 2005): the step `k` by thread `p`
conflicts with the last earlier step of another thread that it is not
ordered after; that step gets `p` as an alternative, or every thread enabled
there if `p` was not.
*/
private void dporBacktrack(size_t k, ubyte p, Op op, SimThread t) @trusted
{
    if (op.loc == 0 || op.kind == OpKind.local || op.kind == OpKind.start)
        return;
    foreach_reverse (j; 0 .. k)
    {
        auto n = &exec.path[j];
        if (n.kind != NodeKind.schedule || n.chosen == p || !n.op.conflicts(op))
            continue;
        if (n.dporClock[n.chosen] <= t.dpor[n.chosen])
            continue; // ordered before this step already
        const preempting = n.prevThread != ubyte.max && !n.prevYielded
            && (n.enabled & (1 << n.prevThread));
        const add = (n.enabled & (1 << p)) ? cast(ubyte)(1 << p) : n.enabled;
        foreach (q; 0 .. maxThreads)
            if (add & (1 << q))
            {
                const isPreemption = preempting && q != n.prevThread;
                if (isPreemption && n.preemptions >= exec.options.preemptionBound)
                    continue;
                n.backtrack |= cast(ubyte)(1 << q);
            }
        break;
    }
}

/// The path of the next execution, or null when the search is done.
private Node[] nextPath(Node[] path) @trusted
{
    while (path.length)
    {
        auto n = &path[$ - 1];
        if (n.kind == NodeKind.value)
        {
            if (n.choice + 1 < n.n)
            {
                ++n.choice;
                return path;
            }
        }
        else
        {
            n.done |= cast(ubyte)(1 << n.chosen);
            const todo = n.backtrack & ~n.done & n.enabled;
            if (todo)
            {
                foreach (q; 0 .. maxThreads)
                    if (todo & (1 << q))
                    {
                        n.chosen = cast(ubyte) q;
                        break;
                    }
                return path;
            }
        }
        path = path[0 .. $ - 1];
    }
    return null;
}

private void initPct() @trusted
{
    // Distinct random priorities, and d - 1 priority change points.
    foreach (i; 0 .. maxThreads)
        exec.priority[i] = cast(uint)(nextRandom() % 1_000_000) + exec.options.pctDepth + 10;
    exec.changePoints.length = 0;
    foreach (i; 0 .. exec.options.pctDepth - 1)
        exec.changePoints ~= cast(uint)(nextRandom() % 400);
}

private ubyte pctChoose(ubyte enabled) @trusted
{
    foreach (i, cp; exec.changePoints)
        if (cp == exec.pctStep)
        {
            // Lower the running thread's priority below every initial one.
            foreach (t; exec.threads)
                if (t.status != ThreadStatus.finished && exec.priority[t.id] == maxPriority(enabled))
                {
                    exec.priority[t.id] = cast(uint) i + 1;
                    break;
                }
        }
    ubyte best = ubyte.max;
    foreach (i; 0 .. maxThreads)
        if ((enabled & (1 << i)) && (best == ubyte.max || exec.priority[i] > exec.priority[best]))
            best = cast(ubyte) i;
    return best;
}

private uint maxPriority(ubyte enabled) @trusted
{
    uint m;
    foreach (i; 0 .. maxThreads)
        if ((enabled & (1 << i)) && exec.priority[i] > m)
            m = exec.priority[i];
    return m;
}

/// Re-runs a failing schedule with tracing on and returns the trace.
private string replayTrace(ModelOptions o, void delegate(ref Scenario) setup, Node[] path, ulong seed) @trusted
{
    import sparkles.base.sync.parking_lot : resetTable;

    exec = new Execution;
    exec.options = o;
    exec.epoch = nextEpoch++;
    exec.spuriousLeft = o.spurious;
    exec.cancelsLeft = o.cancels;
    exec.path = path;
    exec.traceOn = true;
    exec.pct = o.strategy == Strategy.pct;
    if (exec.pct)
        exec.rng = seed | 1;
    resetTable!ModelPlatform();
    resetTable!PortableModelPlatform();
    auto s = Scenario(exec);
    setup(s);
    if (exec.pct)
        initPct();
    const f = runExecution();
    string out_;
    foreach (line; exec.trace)
        out_ ~= line ~ "\n";
    out_ ~= "=> " ~ (f is null ? "(the replay passed)" : f) ~ "\n";
    return out_;
}

/**
Explores and asserts that no check failed and the search completed; the
failure's trace is in the message.
*/
void exploreAll(ModelOptions o, void delegate(ref Scenario) setup, string file = __FILE__,
    size_t line = __LINE__) @trusted
{
    const r = explore(o, setup);
    if (r.failed)
        throw new ModelFailure("model check failed after " ~ itoa(r.executions)
            ~ " executions: " ~ r.failure ~ "\n" ~ r.trace);
    assert(r.complete || o.strategy == Strategy.pct, "the exploration did not finish within maxExecutions ("
        ~ itoa(r.executions) ~ ")");
}

/// Explores a seeded-fault variant and asserts that the explorer reports it.
void exploreExpectingFailure(ModelOptions o, void delegate(ref Scenario) setup) @trusted
{
    const r = explore(o, setup);
    assert(r.failed, "the explorer missed a seeded fault after " ~ itoa(r.executions) ~ " executions");
}

/// `explore` for a scenario written as a function.
ModelReport explore(ModelOptions o, void function(ref Scenario) setup) @trusted
{
    import std.functional : toDelegate;

    return explore(o, toDelegate(setup));
}

/// `exploreAll` for a scenario written as a function.
void exploreAll(ModelOptions o, void function(ref Scenario) setup) @trusted
{
    import std.functional : toDelegate;

    exploreAll(o, toDelegate(setup));
}

/// `exploreExpectingFailure` for a scenario written as a function.
void exploreExpectingFailure(ModelOptions o, void function(ref Scenario) setup) @trusted
{
    import std.functional : toDelegate;

    exploreExpectingFailure(o, toDelegate(setup));
}

/**
Blocks the running simulated thread until `word` holds `v`, without spinning:
a scenario's "wait until" that adds one scheduling point per store to the
word, not one per spin. `o` is the order of the satisfying read.
*/
void awaitValue(Order o = Order.acquire, T)(ref ModelAtomic!T word, T v) @trusted
{
    auto l = location!T(&word);
    while (true)
    {
        point(Op(OpKind.read, cast(size_t) &word));
        auto t = current();
        t.mem[t.id]++;
        const e = l.at(l.latest);
        if (cast(T) e.value == v)
        {
            t.seen[l.id] = l.latest;
            if (acquires(o) && e.hasSync)
                join(t.mem, e.sync);
            dporAccess(t, l, false);
            return;
        }
        cast(void) block(BlockKind.await, cast(size_t) &word, Deadline.never, false);
    }
}
