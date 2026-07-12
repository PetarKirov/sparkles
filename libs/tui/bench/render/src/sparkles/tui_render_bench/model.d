/++
The shared dashboard state every renderer replays against.

`apply` mutates the model per scripted `Event`; it is O(1) and allocation-free in
steady state (the log is a fixed-capacity ring), so the model cost is equal across
renderers and never dominates the measurement. `scene.d` turns a `Model` into the
target grid; the renderers turn a sequence of target grids into bytes.
+/
module sparkles.tui_render_bench.model;

import sparkles.tui_render_bench.scenario : Event, EventKind, Scenario, sceneTableRows, sceneTreeNodes;

/// Capacity of the log ring (older lines scroll out of scrollback).
enum logRingCap = 1024;

/// The full dashboard state.
struct Model
{
    ushort cols;
    ushort rows;
    const(string)[] logPool;

    // Log viewport: a ring of indices into `logPool`, plus a scroll offset.
    int[logRingCap] logRing;
    int logCount; /// total appended (may exceed the ring capacity)
    int logScroll; /// rows scrolled up from the bottom

    // Table: fixed rows, a selection highlight, a per-row counter column.
    int[sceneTableRows] counters;
    int selection;

    // Tree: a bitset of expanded nodes.
    uint treeExpanded;

    // Footer.
    int spinnerFrame;
    int progressMille; /// 0..1000

    // Header clock, in seconds since midnight.
    int clockSecs;

    /// The log index at ring slot `i` counted back from the newest (0 = newest).
    int logAt(int fromNewest) const scope @safe pure nothrow @nogc
    in (fromNewest >= 0 && fromNewest < visibleLogCount)
    {
        const idx = (logCount - 1 - fromNewest) % logRingCap;
        return logRing[idx < 0 ? idx + logRingCap : idx];
    }

    /// How many log lines are currently retained in the ring.
    int visibleLogCount() const scope @safe pure nothrow @nogc
        => logCount < logRingCap ? logCount : logRingCap;
}

/// Initialise the model for a scenario: dimensions, pool, and a non-empty
/// initial screen (seed log lines + counters) so frame 0 is a realistic full paint.
void initModel(ref Model m, in Scenario s) @safe pure nothrow
{
    m.cols = s.cols;
    m.rows = s.rows;
    // Own a copy so the model's lifetime doesn't couple to the scenario's (this
    // runs in untimed setup, so the copy never touches the measured frame loop).
    m.logPool = s.logPool.dup;
    m.logCount = 0;
    m.logScroll = 0;
    m.selection = 0;
    m.treeExpanded = 0b0000_0000_0011; // first couple of nodes expanded
    m.spinnerFrame = 0;
    m.progressMille = 0;
    m.clockSecs = 8 * 3600;
    foreach (r; 0 .. sceneTableRows)
        m.counters[r] = 100 * (r + 1);

    // Seed enough log lines to fill a viewport.
    if (s.logPool.length)
        foreach (i; 0 .. 40)
            appendLog(m, cast(int)(i % s.logPool.length));
}

/// Apply one scripted event to the model.
void apply(ref Model m, in Event e) @safe pure nothrow @nogc
{
    final switch (e.kind)
    {
        case EventKind.clock:
            m.clockSecs += e.a;
            break;
        case EventKind.spinnerTick:
            m.spinnerFrame++;
            break;
        case EventKind.select:
            if (e.a >= 0 && e.a < sceneTableRows)
                m.selection = e.a;
            break;
        case EventKind.setCounter:
            if (e.a >= 0 && e.a < sceneTableRows)
                m.counters[e.a] = e.b;
            break;
        case EventKind.appendLog:
            appendLog(m, e.a);
            break;
        case EventKind.scroll:
            m.logScroll += e.a;
            if (m.logScroll < 0)
                m.logScroll = 0;
            break;
        case EventKind.progress:
            m.progressMille = e.a;
            break;
        case EventKind.toggleTree:
            if (e.a >= 0 && e.a < sceneTreeNodes)
                m.treeExpanded ^= (1u << e.a);
            break;
        case EventKind.resize:
            m.cols = cast(ushort) e.a;
            m.rows = cast(ushort) e.b;
            break;
    }
}

private void appendLog(ref Model m, int poolIdx) @safe pure nothrow @nogc
{
    m.logRing[m.logCount % logRingCap] = poolIdx;
    m.logCount++;
}

@("model.apply.logRingAndCounters")
@safe pure nothrow
unittest
{
    import sparkles.tui_render_bench.scenario : generateScenario, Profile;

    // (generateScenario allocates; run it in a @system helper is unnecessary —
    // just exercise apply directly here.)
    Model m;
    Scenario s;
    s.cols = 40;
    s.rows = 10;
    s.logPool = ["a", "b", "c"];
    initModel(m, s);
    const before = m.logCount;

    apply(m, Event(EventKind.appendLog, 1, 0));
    assert(m.logCount == before + 1);
    assert(m.logAt(0) == 1);

    apply(m, Event(EventKind.setCounter, 2, 777));
    assert(m.counters[2] == 777);

    apply(m, Event(EventKind.select, 3, 0));
    assert(m.selection == 3);

    apply(m, Event(EventKind.toggleTree, 0, 0));
    assert((m.treeExpanded & 1) == 0); // node 0 started expanded → toggled off
}
