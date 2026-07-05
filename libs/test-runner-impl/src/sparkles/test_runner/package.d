/**
 * `sparkles:test-runner` — a general-purpose `unittest` runner.
 *
 * Add it to a package's `configuration "unittest"` and run `dub test`; the
 * runner registers itself as druntime's module unit tester. See
 * $(MREF sparkles,test_runner,attributes) for the `@ctfe`, `@betterC`,
 * `@wasm`, and `@benchmark` opt-in attributes and
 * $(MREF sparkles,test_runner,bench) for the in-test benchmarking API.
 */
module sparkles.test_runner;

public import sparkles.test_runner.attributes : benchmark, betterC, ctfe, wasm;
public import sparkles.test_runner.bench : benchIter, blackBox;
