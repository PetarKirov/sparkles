/**
`PRF21`: what recording a frame costs — timing its phases, keeping it in a
history and noting it in the statistics.
*/
module sparkles.profiling.bench_test;

import sparkles.test_runner.attributes : benchCases;

@("profiling.recordOneFrame")
@benchCases @system
unittest
{
    import sparkles.profiling;
    import sparkles.test_runner.bench : BenchTiming, benchCase, blackBox;

    // The recorder's parts, on the heap: the history is ~190 KiB, and the
    // timer's clock holds a delegate, which a case may not hold itself.
    static struct Recorder
    {
        FrameTimer timer;
        FrameHistory!256 history;
        FrameStats stats;
    }

    static struct RecordOneFrame
    {
        enum timing = BenchTiming.batched;
        Recorder* recorder;

        void setup()
        {
            recorder = new Recorder;
            recorder.timer.clock = FrameClock.monotonic;
        }

        void timed()
        {
            with (recorder)
            {
                timer.begin();
                timer.lap(FramePhase.build);
                timer.lap(FramePhase.acquire);
                timer.lap(FramePhase.record);
                timer.lap(FramePhase.present);
                const f = timer.end();
                history.add(f);
                stats.note(f);
                blackBox(stats.frames);
            }
        }
    }

    benchCase(RecordOneFrame(), labels: ["record": "timer+history+stats"]);
}
