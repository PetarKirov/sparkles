/++
The scripted scenario: a deterministic, fully-materialized sequence of per-frame
state mutations that every renderer replays identically.

There is $(B no runtime RNG at replay time) — the generator (seeded by a fixed
constant per profile) bakes every value into a flat `Event` list up front, so all
D PoCs (and, once serialized to JSON, the cross-language engines) do byte-identical
work. A renderer is a pure replayer: apply a frame's events to the shared `model`,
render the `scene`, diff, emit.

The profile suite is the anti-rigging device (spec §Deliverable 2): each profile
stresses the renderer differently, and the findings report all of them
side-by-side. `sparse` favours cell-diff (few changed cells), `churn` favours
line-diff (clean full-line rewrites), `scroll` tests the scroll-region special
case, `resize` tests reflow + reallocation.
+/
module sparkles.tui_render_bench.scenario;

/// A workload character; each is reported side-by-side in the findings.
enum Profile : ubyte
{
    sparse, /// ~1–3% of cells change per frame (clock, spinners, selection)
    churn, /// most cells change per frame (fast log + counters + color sweep)
    scroll, /// the log fills the pane and scrolls every frame
    resize, /// periodic terminal-size changes among normal activity
    mixed, /// a realistic blend — the headline profile
    unicode, /// wide/emoji-heavy text (D-PoC-only; foreign width tables differ)
}

/// Stable lower-case names (row labels / env-subset keys).
immutable string[6] profileNames = [
    "sparse", "churn", "scroll", "resize", "mixed", "unicode",
];

/// A single scripted mutation. `a`/`b` are interpreted per `kind`.
enum EventKind : ubyte
{
    clock, /// advance the header clock by `a` seconds
    spinnerTick, /// advance every spinner one frame
    select, /// move the table selection to row `a`
    setCounter, /// set table row `a`'s counter column to `b`
    appendLog, /// append `logPool[a]` to the log viewport
    scroll, /// scroll the log viewport by `a` rows (+down)
    progress, /// set the progress bar to `a` (per-mille, 0..1000)
    toggleTree, /// toggle tree node `a`'s expanded state
    resize, /// resize the terminal to `a` cols × `b` rows
}

///
struct Event
{
    EventKind kind;
    int a;
    int b;
}

/// A complete, replayable scenario: dimensions, the per-frame event lists, and
/// the pool of log-line texts that `appendLog` events reference.
struct Scenario
{
    Profile profile;
    ushort cols;
    ushort rows;
    Event[][] frames; /// frames[i] = events applied before rendering frame i
    string[] logPool;

    /// Number of frames (the divisor for per-frame metrics).
    size_t frameCount() const @safe pure nothrow @nogc => frames.length;
}

/// Deterministic 64-bit splitmix — generator-time only, never at replay.
private struct SplitMix
{
    ulong s;
    ulong next() @safe pure nothrow @nogc
    {
        s += 0x9E3779B97F4A7C15;
        ulong z = s;
        z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9;
        z = (z ^ (z >> 27)) * 0x94D049BB133111EB;
        return z ^ (z >> 31);
    }

    uint upto(uint n) @safe pure nothrow @nogc => n == 0 ? 0 : cast(uint)(next() % n);
}

/// Number of table rows / tree nodes the scene shows (fixed content).
enum sceneTableRows = 8;
enum sceneTreeNodes = 12;

/// Build a deterministic scenario for `profile` at `cols`×`rows` over `nFrames`.
Scenario generateScenario(Profile profile, ushort cols, ushort rows, uint nFrames) @safe
{
    import std.format : format;

    auto rng = SplitMix(0xA5A5_0000_0000_0001UL + cast(uint) profile);

    // A realistic log-line pool. The `unicode` profile mixes in wide/emoji text.
    enum poolSize = 256;
    string[] pool;
    pool.reserve(poolSize);
    static immutable levels = ["INFO", "WARN", "DEBUG", "ERROR", "TRACE"];
    static immutable units = ["build", "deploy", "index", "sync", "verify", "cache"];
    static immutable wide = ["世界一の速度", "🚀 launch", "café ☕ ready", "naïve façade"];
    foreach (i; 0 .. poolSize)
    {
        const lvl = levels[rng.upto(levels.length)];
        const unit = units[rng.upto(units.length)];
        const ms = rng.upto(4000);
        if (profile == Profile.unicode && (i % 3 == 0))
            pool ~= format("%s %s %s (%sms)", lvl, unit, wide[rng.upto(wide.length)], ms);
        else
            pool ~= format("%s %s: task #%s finished in %sms", lvl, unit, 1000 + i, ms);
    }

    Event[][] frames;
    frames.reserve(nFrames);

    int clockT = 8 * 3600; // 08:00:00
    foreach (f; 0 .. nFrames)
    {
        Event[] ev;

        // Common: the header clock ticks every frame in every profile.
        clockT += 1;
        ev ~= Event(EventKind.clock, 1, 0);
        ev ~= Event(EventKind.spinnerTick, 0, 0);
        ev ~= Event(EventKind.progress, cast(int)((f * 1000) / nFrames), 0);

        final switch (profile)
        {
            case Profile.sparse:
                // Occasional selection move; nothing else churns.
                if (f % 7 == 0)
                    ev ~= Event(EventKind.select, rng.upto(sceneTableRows), 0);
                break;

            case Profile.churn:
                // A burst of log lines + every counter changes + selection sweeps.
                foreach (_; 0 .. 6)
                    ev ~= Event(EventKind.appendLog, rng.upto(poolSize), 0);
                foreach (r; 0 .. sceneTableRows)
                    ev ~= Event(EventKind.setCounter, r, rng.upto(100000));
                ev ~= Event(EventKind.select, f % sceneTableRows, 0);
                break;

            case Profile.scroll:
                ev ~= Event(EventKind.appendLog, rng.upto(poolSize), 0);
                ev ~= Event(EventKind.scroll, 1, 0);
                break;

            case Profile.resize:
                if (f % 20 == 10)
                    ev ~= Event(EventKind.resize, 80, 24);
                else if (f % 20 == 0)
                    ev ~= Event(EventKind.resize, cols, rows);
                ev ~= Event(EventKind.appendLog, rng.upto(poolSize), 0);
                break;

            case Profile.mixed:
            case Profile.unicode:
                if (f % 2 == 0)
                    ev ~= Event(EventKind.appendLog, rng.upto(poolSize), 0);
                if (f % 5 == 0)
                    ev ~= Event(EventKind.select, rng.upto(sceneTableRows), 0);
                if (f % 4 == 0)
                    ev ~= Event(EventKind.setCounter, rng.upto(sceneTableRows), rng.upto(100000));
                if (f % 11 == 0)
                    ev ~= Event(EventKind.toggleTree, rng.upto(sceneTreeNodes), 0);
                if (f % 3 == 0)
                    ev ~= Event(EventKind.scroll, 1, 0);
                break;
        }

        frames ~= ev;
    }

    return Scenario(profile, cols, rows, frames, pool);
}

@("scenario.generate.isDeterministic")
@safe
unittest
{
    auto a = generateScenario(Profile.mixed, 120, 40, 50);
    auto b = generateScenario(Profile.mixed, 120, 40, 50);
    assert(a.frames.length == 50);
    assert(a.logPool == b.logPool);
    // Same seed → identical scripted work (the cross-language identity contract).
    foreach (i; 0 .. a.frames.length)
        assert(a.frames[i] == b.frames[i]);
}

@("scenario.generate.profilesDiffer")
@safe
unittest
{
    auto sparse = generateScenario(Profile.sparse, 120, 40, 40);
    auto churn = generateScenario(Profile.churn, 120, 40, 40);
    size_t sparseEvents, churnEvents;
    foreach (fr; sparse.frames)
        sparseEvents += fr.length;
    foreach (fr; churn.frames)
        churnEvents += fr.length;
    assert(churnEvents > sparseEvents * 3); // churn genuinely does more work
}
