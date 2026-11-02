/**
`PRF21`: what recording a frame costs — timing its phases, keeping it in a
history and noting it in the statistics.
*/
module sparkles.profiling.bench_test;

import sparkles.test_runner.attributes : benchmark;

@("profiling.recordOneFrame")
@benchmark @system
unittest
{
    import sparkles.profiling;
    import sparkles.test_runner.bench : benchIter, blackBox;

    // Static: a benchmark body runs after the unittest returns.
    static FrameTimer timer;
    static FrameHistory!256 history;
    static FrameStats stats;
    timer.clock = FrameClock.monotonic;
    benchIter({
        timer.begin();
        timer.lap(FramePhase.build);
        timer.lap(FramePhase.acquire);
        timer.lap(FramePhase.record);
        timer.lap(FramePhase.present);
        const f = timer.end();
        history.add(f);
        stats.note(f);
        blackBox(stats.frames);
    }, ["record": "timer+history+stats"]);
}
