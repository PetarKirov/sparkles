/**
 * The tests of `sparkles.profiling.counters.perf_group`. They use the harness
 * (`skipTest`, the benchmark layer), which depends on the counters, so
 * they live in the harness rather than self-hosting it in the counters'
 * package (build graph BGR8).
 */
module sparkles.test_runner.counters_test.perf_group;

import sparkles.profiling.counters.perf_group;

version (linux)
{
    @("perf_group.projectPerIter.keepsRareEvents")
    @safe pure nothrow @nogc
    unittest
    {
        assert(projectPerIter(1, 1.0, 10_000) == 1e-4); // a 3-decimal round floors this to 0
        assert(projectPerIter(3370, 1.0, 1000) == 3.37);
    }

    @("perf_group.unreliableScale")
    @safe pure nothrow @nogc
    unittest
    {
        assert(unreliableScale(2_000_000, 580_000), "the probe's 0.58 ms case");
        assert(!unreliableScale(580_000, 580_000), "exact short pass is fine");
        assert(!unreliableScale(10_000_000, 5_000_000), "≥1 ms scaled is a labeled estimate");
        assert(!unreliableScale(1_000_000, 0), "never-ran is its own state");
        assert(!unreliableScale(0, 0));
    }

    @("perf_group.groupNeverRan")
    @safe pure nothrow @nogc
    unittest
    {
        assert(groupNeverRan(1000, 0));
        assert(!groupNeverRan(1000, 1)); // any PMU time → scaled estimate
        assert(!groupNeverRan(0, 0)); // nothing enabled: empty, not starved
    }

    @("perf_group.scaledRatio")
    @safe pure nothrow @nogc
    unittest
    {
        assert(scaledRatio(0, 0) == 1.0);
        assert(scaledRatio(1000, 1000) == 1.0);
        assert(scaledRatio(2000, 1000) == 2.0);
        assert(scaledRatio(0, 1000) == 1.0); // degenerate: never enabled
        // The correction depends only on the pass's deltas — identical passes
        // yield identical ratios regardless of how much history preceded them.
        assert(scaledRatio(2000, 1000) == scaledRatio(2_000_000, 1_000_000));
    }

    @("perf_group.windowDeltas.gates")
    @safe pure nothrow @nogc
    unittest
    {
        static GroupSnapshot edge(ulong enabled, ulong running,
            ulong v0, ulong v1, bool ok = true)
        {
            GroupSnapshot s;
            s.enabled = enabled;
            s.running = running;
            s.values[0] = v0;
            s.values[1] = v1;
            s.n = 2;
            s.ok = ok;
            return s;
        }

        double scale = 123;
        double[2] vals = [-1, -1];

        // Failed edge read → no result, nothing touched.
        assert(!windowDeltas(edge(0, 0, 0, 0, false), edge(9, 9, 9, 9), scale, vals[]));
        assert(scale == 123 && vals[0] == -1);

        // Never enabled across the window → no result (zeros would be
        // fabricated), nothing touched.
        assert(!windowDeltas(edge(5000, 5000, 10, 20), edge(5000, 5000, 10, 20),
                scale, vals[]));
        assert(scale == 123 && vals[0] == -1);

        // Enabled but never scheduled → the kernel's <not counted>: scale 0.
        assert(!windowDeltas(edge(0, 0, 0, 0), edge(5000, 0, 0, 0), scale, vals[]));
        assert(scale == 0 && vals[0] == -1);

        // Multiplexed with under 1 ms of PMU time → unreliable: the true
        // ratio is reported, the values are rejected.
        scale = 123;
        assert(!windowDeltas(edge(0, 0, 0, 0), edge(2_000_000, 580_000, 100, 200),
                scale, vals[]));
        assert(scale == 0.29 && vals[0] == -1);

        // Clean window → totals, scale 1.
        assert(windowDeltas(edge(1000, 1000, 10, 20), edge(2_001_000, 2_001_000, 110, 220),
                scale, vals[]));
        assert(scale == 1 && vals[0] == 100 && vals[1] == 200);

        // Multiplexed ≥ 1 ms → scaled totals, labeled scale.
        assert(windowDeltas(edge(0, 0, 0, 0), edge(4_000_000, 2_000_000, 100, 200),
                scale, vals[]));
        assert(scale == 0.5 && vals[0] == 200 && vals[1] == 400);
    }

}
