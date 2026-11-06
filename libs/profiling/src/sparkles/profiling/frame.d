/**
One frame, recorded: when it started, where its CPU time went, what the
device did in it, and what happened to it (`PRF1`, `PRF2`). A fixed-size
value, so a history of them allocates nothing per frame.

The time source is a $(LREF FrameClock) (`PRF4`): `MonoTime` by default, any
function a test supplies otherwise, so recorded durations can be exact.
*/
module sparkles.profiling.frame;

import core.time : Duration, MonoTime;

import sparkles.profiling.zones : FrameZones;

/// Where a frame's CPU time goes. A program records the phases it has.
enum FramePhase : ubyte
{
    wait,    /// for the frame slot's previous submit (its fence)
    build,   /// the application's frame: input, layout, its draw list
    acquire, /// the swapchain image
    record,  /// the command buffer
    submit,  /// the queue submit
    present, /// the queue present
    rebuild, /// the swapchain and its targets, before the frame
}

/// How many $(LREF FramePhase)s there are.
enum size_t phaseCount = FramePhase.max + 1;

/// What happened to a frame; a frame may carry several.
enum FrameFlags : ushort
{
    none = 0,                 ///
    rebuilt = 1 << 0,         /// the swapchain was rebuilt before it
    suboptimal = 1 << 1,      /// acquire or present said suboptimal
    outOfDate = 1 << 2,       /// acquire or present said out of date
    skipped = 1 << 3,         /// built, not presented
    pipelineCompiled = 1 << 4, /// a pipeline was compiled during it
    deviceLost = 1 << 5,      ///
    firstFrame = 1 << 6,      /// the first frame of a surface
}

/// How many flag bits $(LREF FrameFlags) has, `none` aside.
enum size_t flagCount = 7;

/// The name of flag bit `bit`, as a summary and a trace spell it.
string flagName(size_t bit) @safe pure nothrow @nogc
{
    static immutable string[flagCount] names = [
        "rebuilt", "suboptimal", "out-of-date", "skipped", "compiled", "device-lost", "first",
    ];
    return bit < flagCount ? names[bit] : "?";
}

/// The most GPU scopes one frame records.
enum size_t maxGpuScopes = 16;

/// One named piece of a frame's device work (`PRF10`).
struct GpuScope
{
    ubyte name;      /// an index into the profiler's scope names
    ubyte depth;     /// nesting: 0 for a top-level scope
    bool calibrated; /// `start` is on the CPU's timeline (`PRF11`)
    Duration start;  /// from the run's origin when calibrated; else from the frame's first scope
    Duration took;   ///
}

/// A phase's place in its frame.
struct PhaseSpan
{
    Duration start; /// from the frame's start
    Duration took;  /// ditto, summed if the phase ran more than once
}

/// ditto
struct FrameRecord
{
    ulong number;             /// monotonic over the run
    Duration start;           /// from the run's origin
    Duration cpu;             /// the frame's whole CPU time
    PhaseSpan[phaseCount] phases; ///
    Duration gpu;             /// the device's time for the frame, where measured
    GpuScope[maxGpuScopes] gpuScopes; ///
    ubyte gpuScopeCount;      ///
    bool shownKnown;          /// `shown` is set (`PRF13`)
    FrameFlags flags;         ///
    Duration shown;           /// when it reached the display, from the run's origin
    FrameZones zones;         /// its named CPU zones (`PRF22`)

@safe pure nothrow @nogc:

    /// The duration of phase `p`.
    Duration opIndex(FramePhase p) const => phases[p].took;

    /// Whether every flag in `f` is set.
    bool has(FrameFlags f) const => (flags & f) == f;

    /// The scopes recorded.
    inout(GpuScope)[] scopes() inout return => gpuScopes[0 .. gpuScopeCount];

    /// Adds a GPU scope; past `maxGpuScopes` the rest are dropped.
    void addGpuScope(in GpuScope s)
    {
        if (gpuScopeCount < maxGpuScopes)
            gpuScopes[gpuScopeCount++] = s;
    }

    /// The time from the frame's start to its display, where known (`PRF14`).
    bool latency(out Duration d) const
    {
        if (!shownKnown || shown < start)
            return false;
        d = shown - start;
        return true;
    }
}

static assert(FrameRecord.sizeof <= 768, "PRF1: a record stays small");

/**
The time a frame is measured by (`PRF4`): from the run's origin, through a
function a test supplies or `MonoTime`.
*/
struct FrameClock
{
    private MonoTime origin;
    private Duration delegate() @safe nothrow @nogc source;

    /// A clock reading `MonoTime` from now.
    static FrameClock monotonic() @safe nothrow @nogc
    {
        FrameClock c;
        c.origin = MonoTime.currTime;
        return c;
    }

    /// A clock reading `MonoTime` from `origin`.
    static FrameClock since(MonoTime origin) @safe pure nothrow @nogc
    {
        FrameClock c;
        c.origin = origin;
        return c;
    }

    /// A clock reading `source`, a time since the run's origin.
    static FrameClock using(Duration delegate() @safe nothrow @nogc source) @safe nothrow @nogc
    {
        FrameClock c;
        c.source = source;
        return c;
    }

    /// The time since the run's origin.
    Duration now() const @safe nothrow @nogc
        => source !is null ? source() : MonoTime.currTime - origin;

    /// The run's origin as a `MonoTime`, for a calibrated device clock.
    MonoTime originTime() const @safe pure nothrow @nogc => origin;
}

/**
Times one frame at a time on a $(LREF FrameClock): `begin`, then a `lap` at
the end of each phase (which credits the time since the previous lap), then
`end`. Between `begin` and `end` the calling thread's CPU zones
(`sparkles.profiling.zones`) collect into the frame.
*/
struct FrameTimer
{
    FrameClock clock; ///
    private FrameRecord current;
    private Duration mark;
    private ulong next;

@safe nothrow @nogc:

    /// Starts frame `next`, carrying `flags`.
    void begin(FrameFlags flags = FrameFlags.none)
    {
        current = FrameRecord.init;
        current.number = next++;
        current.start = mark = clock.now;
        current.flags = flags;
        () @trusted { FrameZones.current = &current.zones; }();
    }

    /// Credits the time since the last lap (or the start) to `phase`.
    void lap(FramePhase phase)
    {
        const at = clock.now;
        auto span = &current.phases[phase];
        if (span.took == Duration.zero)
            span.start = mark - current.start;
        span.took += at - mark;
        mark = at;
    }

    /// Skips the time since the last lap: it belongs to no phase.
    void skip() { mark = clock.now; }

    /// Sets `flags` on the frame.
    void flag(FrameFlags flags) { current.flags |= flags; }

    /// The frame so far, to add device times to.
    ref FrameRecord frame() return => current;

    /// Ends the frame and returns it.
    ref FrameRecord end() return
    {
        current.cpu = clock.now - current.start;
        release();
        return current;
    }

    ~this() { release(); }

    // Stops collecting zones, if this timer's frame collects them.
    private void release() @trusted
    {
        if (FrameZones.current is &current.zones)
            FrameZones.current = null;
    }
}

///
@("profiling.frame.timerLapsPhases")
@safe nothrow unittest // the test clock is a closure
{
    import core.time : msecs;

    Duration t;
    auto timer = FrameTimer(FrameClock.using(() => t));
    timer.begin(FrameFlags.firstFrame);
    t = 2.msecs;
    timer.lap(FramePhase.build);
    t = 3.msecs;
    timer.lap(FramePhase.acquire);
    t = 7.msecs;
    timer.skip();
    t = 9.msecs;
    timer.lap(FramePhase.present);
    const f = timer.end();
    assert(f.number == 0 && f.has(FrameFlags.firstFrame));
    assert(f[FramePhase.build] == 2.msecs && f[FramePhase.acquire] == 1.msecs);
    assert(f.phases[FramePhase.present].start == 7.msecs && f[FramePhase.present] == 2.msecs);
    assert(f.cpu == 9.msecs);
    timer.begin();
    assert(timer.end().number == 1);
}

@("profiling.frame.latencyAndScopes")
@safe pure nothrow @nogc unittest
{
    import core.time : msecs;

    FrameRecord r;
    r.start = 10.msecs;
    Duration d;
    assert(!r.latency(d));
    r.shown = 35.msecs;
    r.shownKnown = true;
    assert(r.latency(d) && d == 25.msecs);
    foreach (i; 0 .. maxGpuScopes + 3)
        r.addGpuScope(GpuScope(name: cast(ubyte) i));
    assert(r.scopes.length == maxGpuScopes);
    assert(flagName(4) == "compiled" && flagName(99) == "?");
}
