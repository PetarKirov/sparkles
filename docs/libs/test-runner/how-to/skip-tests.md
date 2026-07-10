# Skip tests at runtime

A test that needs an environment capability — hardware perf counters, a
readable tracefs, a toolchain binary on `PATH` — should **skip** when the
capability is missing, not silently pass: an early `return` counts a degraded
environment as green and masks the gap. Call `skipTest` from
`sparkles.test_runner.skip` (also re-exported by `sparkles.test_runner`):

```d
import sparkles.test_runner : skipTest;

@("perf.counters.smoke")
@system unittest
{
    auto g = PerfGroup.tryOpen(true);
    if (!g.available)
        skipTest("hardware counters unavailable (perf_event_paranoid?)");
    // … the real test …
}
```

The runner records the test as **skipped** — neither passed nor failed:

```console
 ⊘ pkg.perf perf.counters.smoke (hardware counters unavailable (perf_event_paranoid?))

Summary: 12 passed, 0 failed, 1 skipped in 4.1ms
```

- The `N skipped` summary segment appears only when something skipped, and a
  skip never fails the run — surfacing, not punishing, is the point.
- `skipTest` is `@safe pure nothrow @nogc` (it throws a recycled
  `TestSkipped : Error`), so the strictest test bodies can call it without
  relaxing their attributes.

## Caveats

- **Runtime only.** A `@ctfe` body is evaluated by the compile-time probe — a
  skip there is a compile error, not a skip. The extracted
  `--better-c`/`--wasm` programs have no druntime classes; guard those bodies
  by other means.
- **`@benchmark` bodies: prefer skipping at registration.** `skipTest` at the
  top of the body marks the whole benchmark skipped (a `⊘` line, no rows).
  Inside a deferred `benchIter`/`benchCase` closure it skips only that case —
  a yellow row in its table — while the rest of the matrix measures and the
  run stays green.
- The mode-level toolchain skips (`--better-c`/`--wasm`/`@ctfe` with no
  compiler) remain stderr notes with exit 0; `skipTest` is for per-test
  environment probes.
