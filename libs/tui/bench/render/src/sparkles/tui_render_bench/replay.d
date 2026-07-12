/++
The replay driver: the timed body core.

A renderer is any type with `reset(ushort cols, ushort rows)` and
`renderFrame(in Grid, ref Sink)`. `replayScenario` applies each frame's scripted
events to the model, recomputes the target grid, and hands it to the renderer,
which emits this frame's bytes into the reused sink. The optional per-frame hook
lets the correctness gate feed those bytes through the VT oracle and compare grid
fingerprints — it is `null` during timing so it adds no overhead.
+/
module sparkles.tui_render_bench.replay;

import sparkles.tui_render_bench.cell : Grid;
import sparkles.tui_render_bench.model : apply, initModel, Model;
import sparkles.tui_render_bench.scenario : Scenario;
import sparkles.tui_render_bench.scene : renderScene;
import sparkles.tui_render_bench.sink : Sink;

/// Per-frame observer: `(target grid, this frame's emitted bytes, frame index)`.
alias FrameHook = void delegate(in Grid target, scope const(char)[] frameBytes, size_t frameIndex);

/// Replay `s` through `renderer`, emitting into `sink`. The renderer holds its
/// own prev-frame state; the sink accumulates `bytesTotal`/counters across the
/// whole scenario while `frame()` holds just the latest frame (for the hook).
void replayScenario(R, Hook = typeof(null))(ref R renderer, in Scenario s, ref Sink sink, scope Hook onFrame = null)
{
    Model m;
    initModel(m, s);
    Grid target;
    renderer.reset(s.cols, s.rows);
    foreach (fi, const frameEvents; s.frames)
    {
        foreach (const ref e; frameEvents)
            apply(m, e);
        renderScene(m, target); // resizes target to the model's current dims
        sink.reset();
        renderer.renderFrame(target, sink);
        static if (!is(Hook == typeof(null)))
            if (onFrame !is null)
                onFrame(target, sink.frame(), fi);
    }
}
