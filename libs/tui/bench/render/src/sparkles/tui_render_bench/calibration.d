/++
Cross-language codegen calibration: the same `cell_grid` algorithm in D and C.

M1–M2 established the _relative_ ordering of D approaches; this answers whether the
_absolute_ D numbers are competitive or inflated by LDC codegen. `shim_c.c` is a
byte-identical C port of the `cell_grid` renderer; both are timed over the same
precomputed target-grid sequence (so the measurement isolates renderer diff+emit,
not scene computation), and their output is asserted byte-identical.

If D ≈ C here, the D PoC numbers are trustworthy and the architecture conclusion
holds. (Actual TUI frameworks — Ratatui, Notcurses — render subtly different
pictures and can't be grid-matched cheaply; this same-algorithm comparison is the
rigorous, achievable calibration.) Fixed 120×40, no-resize profiles (the flat C ABI
assumes a constant frame stride).
+/
module sparkles.tui_render_bench.calibration;

import sparkles.test_runner.attributes : benchmark;
import sparkles.test_runner.bench : benchCase, blackBox, Metric, Unit;

import sparkles.tui_render_bench.cell : Grid;
import sparkles.tui_render_bench.model : apply, initModel, Model;
import sparkles.tui_render_bench.pocs.cell_grid : CellGrid;
import sparkles.tui_render_bench.scenario : generateScenario, Profile, profileNames, Scenario;
import sparkles.tui_render_bench.scene : renderScene;
import sparkles.tui_render_bench.sink : Sink;

// C ABI for the byte-identical C port in `shim_c.c` (dub compiles it as a source
// object; declaring `extern(C)` here — rather than ImportC-importing — is what
// links its code). The struct layout matches the C `TuiCell` field-for-field.
struct TuiCell
{
    uint cp;
    ubyte width;
    ubyte fg_kind, fr, fg_, fb;
    ubyte bg_kind, br, bg_, bb;
    ubyte attrs;
}

extern (C) size_t tui_cellgrid_render(const(TuiCell)* frames, int nframes, int cols,
    int rows, char* outbuf, size_t outcap) @nogc nothrow;

private enum uint calibFrames = 300;
private enum ushort calibCols = 120;
private enum ushort calibRows = 40;
private immutable Profile[] calibProfiles = [
    Profile.sparse, Profile.mixed, Profile.churn, Profile.scroll,
];

private struct Frames
{
    Grid[] grids; // for the D renderer
    TuiCell[] flat; // nframes × cols × rows, for the C shim
    int nframes;
    int cols;
    int rows;
}

/// Precompute the target-grid sequence once (untimed): the scene is shared, so
/// timing only the renderer over these grids isolates diff+emit.
private Frames precompute(in Scenario scn)
{
    Model m;
    initModel(m, scn);
    Frames fr;
    fr.cols = scn.cols;
    fr.rows = scn.rows;
    Grid target;
    foreach (const ref ev; scn.frames)
    {
        foreach (const ref e; ev)
            apply(m, e);
        renderScene(m, target);

        Grid g;
        g.copyFrom(target);
        fr.grids ~= g;

        foreach (ushort y; 0 .. target.rows)
            foreach (ushort x; 0 .. target.cols)
            {
                const c = target.at(x, y);
                TuiCell t;
                t.cp = c.codepoint;
                t.width = c.width;
                t.fg_kind = cast(ubyte) c.style.fg.kind;
                t.fr = c.style.fg.a;
                t.fg_ = c.style.fg.b;
                t.fb = c.style.fg.c;
                t.bg_kind = cast(ubyte) c.style.bg.kind;
                t.br = c.style.bg.a;
                t.bg_ = c.style.bg.b;
                t.bb = c.style.bg.c;
                t.attrs = cast(ubyte)(c.style.attrs & 0x1F);
                fr.flat ~= t;
            }
    }
    fr.nframes = cast(int) fr.grids.length;
    return fr;
}

/// D cell_grid over precomputed grids, accumulating the full byte stream.
private void renderD(ref CellGrid r, in Grid[] grids, ref Sink sink) @safe nothrow
{
    r.reset(grids[0].cols, grids[0].rows);
    sink.reset();
    foreach (const ref g; grids)
        r.renderFrame(g, sink);
}

/// C cell_grid over the flat frames; returns the byte count.
private size_t renderC(in Frames fr, ref char[] buf) @trusted nothrow
{
    if (buf.length == 0)
        buf.length = 1 << 22;
    return tui_cellgrid_render(fr.flat.ptr, fr.nframes, fr.cols, fr.rows, buf.ptr, buf.length);
}

@("calibration.cCellGrid.byteIdenticalToD")
@system
unittest
{
    auto fr = precompute(generateScenario(Profile.mixed, calibCols, calibRows, 60));
    CellGrid r;
    Sink sink;
    renderD(r, fr.grids, sink);
    char[] cbuf;
    const n = renderC(fr, cbuf);
    assert(n <= cbuf.length, "C output truncated");
    assert(sink.frame == cbuf[0 .. n], "C cell_grid diverged from the D byte stream");
}

@("render-calibration")
@benchmark
@system
unittest
{
    foreach (p; calibProfiles)
    {
        registerD(p);
        registerC(p);
    }
}

private void registerD(Profile p)
{
    static struct St
    {
        Frames fr;
        CellGrid r;
        Sink sink;
    }

    auto st = new St;
    st.fr = precompute(generateScenario(p, calibCols, calibRows, calibFrames));
    const K = st.fr.nframes;

    benchCase(
        name: "cell_grid",
        timed: () { renderD(st.r, st.fr.grids, st.sink); blackBox(st.sink.length); },
        after: () {},
        metrics: [Metric(Unit("frame"), cast(double) K, Metric.Mode.rate)],
        labels: ["profile": profileNames[p], "lang": "D"],
    );
}

private void registerC(Profile p)
{
    static struct St
    {
        Frames fr;
        char[] buf;
    }

    auto st = new St;
    st.fr = precompute(generateScenario(p, calibCols, calibRows, calibFrames));
    st.buf.length = 1 << 22;
    const K = st.fr.nframes;

    benchCase(
        name: "cell_grid_c",
        timed: () {
        const n = tui_cellgrid_render(st.fr.flat.ptr, st.fr.nframes, st.fr.cols, st.fr.rows,
            st.buf.ptr, st.buf.length);
        blackBox(n);
    },
        after: () {},
        metrics: [Metric(Unit("frame"), cast(double) K, Metric.Mode.rate)],
        labels: ["profile": profileNames[p], "lang": "C"],
    );
}
