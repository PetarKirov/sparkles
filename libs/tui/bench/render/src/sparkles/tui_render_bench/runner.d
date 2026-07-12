/++
The `@benchmark` matrix: renderer × profile × terminal-size.

`name` is the renderer (the varying dimension compared per row); `profile` and
`size` are labels (`--group-by=profile,size` gives one table per group). Each case
times a whole scenario replay — a diffing renderer's per-frame cost is inherently
inter-frame-dependent, so one iteration = one scenario. Per-scenario setup (pool
`dup`, initial model) is in the untimed `setup`/`resetModelState`, so the timed
body is allocation-free in steady state — the property that most discriminates the
architectures for a GC'd library.

Metrics per row: frames/s (`Unit("frame")` rate) and bytes/frame (`Unit("B")`
level); `--perf` adds instructions/frame + IPC. Subset with `$TUI_BENCH_POCS`,
`$TUI_BENCH_PROFILES`, `$TUI_BENCH_SIZES` (comma lists; empty = all). Run:

    dub test -b bench --root=libs/tui/bench/render -- --bench --perf --group-by=profile,size
+/
module sparkles.tui_render_bench.runner;

import std.meta : AliasSeq;

import sparkles.test_runner.attributes : benchmark;
import sparkles.test_runner.bench : benchCase, blackBox, Metric, Unit;

import sparkles.tui_render_bench.cell : Grid;
import sparkles.tui_render_bench.model : apply, initModel, Model, resetModelState;
import sparkles.tui_render_bench.pocs.cell_grid : CellGrid;
import sparkles.tui_render_bench.pocs.line_diff : LineDiff;
import sparkles.tui_render_bench.pocs.reference_fullpaint : ReferenceFullpaint;
import sparkles.tui_render_bench.scenario : generateScenario, Profile, profileNames, Scenario;
import sparkles.tui_render_bench.scene : renderScene;
import sparkles.tui_render_bench.sink : Sink;

private enum uint benchFrames = 300;

private alias Renderers = AliasSeq!(ReferenceFullpaint, LineDiff, CellGrid);

// Correctness is oracle-verified on the width-1 profiles; `unicode` (wide cells)
// is excluded until the PoCs' wide-cell handling is verified (spec follow-up).
private immutable Profile[] benchProfiles = [
    Profile.sparse, Profile.churn, Profile.scroll, Profile.resize, Profile.mixed,
];

private struct SizeSpec
{
    ushort cols;
    ushort rows;
    string label;
}

private immutable SizeSpec[] sizes = [
    SizeSpec(120, 40, "120x40"),
    SizeSpec(80, 24, "80x24"),
];

@("render")
@benchmark
@system
unittest
{
    bool any;
    static foreach (R; Renderers)
        if (envAllows("TUI_BENCH_POCS", R.label))
            foreach (p; benchProfiles)
                if (envAllows("TUI_BENCH_PROFILES", profileNames[p]))
                    foreach (const ref sz; sizes)
                        if (envAllows("TUI_BENCH_SIZES", sz.label))
                        {
                            registerCase!R(p, sz);
                            any = true;
                        }
    if (!any)
        benchCase(name: "(filtered out)", timed: () {}, after: () {});
}

private void registerCase(R)(Profile p, in SizeSpec sz)
{
    // Per-case state on the heap so the deferred timed/setup closures share it.
    static struct St
    {
        Scenario scn;
        Model m;
        Grid target;
        Sink sink;
        R renderer;
    }

    auto st = new St;
    st.scn = generateScenario(p, sz.cols, sz.rows, benchFrames);
    const K = st.scn.frameCount;
    const bytesPerFrame = measureBytesPerFrame!R(st.scn);

    benchCase(
        name: R.label,
        timed: () {
        resetModelState(st.m, st.scn);
        st.renderer.reset(st.scn.cols, st.scn.rows);
        foreach (const ref fr; st.scn.frames)
        {
            foreach (const ref e; fr)
                apply(st.m, e);
            renderScene(st.m, st.target);
            st.sink.reset();
            st.renderer.renderFrame(st.target, st.sink);
        }
        blackBox(st.sink.length);
    },
        after: () {},
        metrics: [
        Metric(Unit("frame"), cast(double) K, Metric.Mode.rate),
        Metric(Unit("B"), cast(double) bytesPerFrame, Metric.Mode.level),
    ],
        labels: ["profile": profileNames[p], "size": sz.label],
        setup: () { initModel(st.m, st.scn); },
    );
}

/// Replay once (untimed, registration-time) to get the deterministic byte output.
private size_t measureBytesPerFrame(R)(in Scenario scn)
{
    Model m;
    initModel(m, scn);
    R r;
    r.reset(scn.cols, scn.rows);
    Grid target;
    Sink sink;
    foreach (const ref fr; scn.frames)
    {
        foreach (const ref e; fr)
            apply(m, e);
        renderScene(m, target);
        sink.reset();
        r.renderFrame(target, sink);
    }
    return cast(size_t)(sink.bytesTotal / scn.frameCount);
}

private bool envAllows(string var, string name) @safe
{
    import std.algorithm : canFind, splitter;
    import std.process : environment;

    const v = environment.get(var, "");
    return v.length == 0 || v.splitter(',').canFind(name);
}
