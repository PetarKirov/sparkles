# Write compile-time (`@ctfe`) tests

`@ctfe` moves a test from runtime to compile time.

```d
import sparkles.test_runner.attributes : ctfe;

@("caseFold.ascii")
@ctfe @safe pure nothrow @nogc
unittest
{
    assert(caseFold("MiXeD") == "mixed");
}
```

## How it runs

The test build itself only _typechecks_ `@ctfe` bodies. When the runner
executes (default mode or `--ctfe-trace`), it applies the `-i`/`-e` filters,
generates a probe program that imports the tests' modules and selects the
remaining `@ctfe` tests by reflection, and compiles it with
`$DC -o- -unittest` — semantic analysis only, so CTFE runs but nothing is
codegen'd or linked. Consequences:

- `-i`/`-e` control which `@ctfe` tests actually **execute**, exactly like
  runtime tests — excluded tests are never evaluated.
- `--help` and `--list` never evaluate any `@ctfe` test, and a failing one
  cannot break the test build.
- Bodies stay in their home modules, so private symbols work — nothing is
  extracted.
- A D compiler must be reachable at run time (`--compiler`, `$DC`, or
  `ldc2`/`dmd` on `PATH`); otherwise `@ctfe` tests are reported as skipped.

## Reading the results

- A passing test is reported as `⚙ … (compile time)`.
- A failing test is reported as `✗ … (compile time)`, preceded by the
  compiler's error for the failing assertion (with the full CTFE call
  stack); the closing `error instantiating` line names the test
  (`ctfePassed!(…, "caseFold.ascii")`).
- `__ctfeWrite` output from the tests is echoed.
- The body must be CTFE-able: no I/O, no `@system` pointer tricks, no
  runtime-only intrinsics. `-checkaction=context` assert messages work.
- A body that runs fine at runtime can still be rejected by CTFE — e.g.
  reading a `union` member other than the last one written
  (`reinterpretation through overlapped field … is not allowed in CTFE`),
  `void` initialization, or pointer casts. Such a test cannot be `@ctfe`;
  the error is deliberate, not a runner malfunction.

The attribute is named after — and is forward-compatible with — the `@__ctfe`
function attribute introduced in DMD 2.113 (which enforces "CTFE-only, no
codegen" at the compiler level).

## When to use it

- Pure algorithmic code you want verified under the CTFE interpreter, where
  downstream mixins/templates will actually evaluate it.
- Guarding CTFE-ability itself: an `@ctfe` test fails the moment the tested
  code stops being CTFE-compatible.

## Attribute compile-time cost to tests (`--ctfe-trace`)

CTFE time is compile time. To see what each `@ctfe` test costs, pass
`--ctfe-trace` (requires LDC): the probe is compiled with `-ftime-trace`,
the trace is written to the given file, and the cost is attributed per test:

```console
$ dub test :my-package -- --ctfe-trace build/trace.json
╭────────────────┬───────────────────┬───────────╮
│ @ctfe test     │ location          │ CTFE time │
│ caseFold.ascii │ src/my/text.d:148 │     6.0ms │
╰────────────────┴───────────────────┴───────────╯
total CTFE time attributed to @ctfe tests: 6.0ms
```
