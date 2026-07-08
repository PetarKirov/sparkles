# Getting started

This tutorial wires `sparkles:test-runner` into a package and writes one test
of each kind. At the end you will have run tests at runtime, at compile time,
without druntime, and as a benchmark.

## 1. Wire the runner into a package

Both external projects and most in-tree sub-packages add one dependency to
`configuration "unittest"` — a thin shim compiles in and links the prebuilt
implementation library, so `dub test` stays close to a vanilla build:

```sdl
configuration "unittest" {
    dependency "sparkles:test-runner" version="*"   # in-tree: path="../.."

    dflags "-checkaction=context" "-allinst"
}
```

The exception is `base`, `core-cli`, and `test-utils`: they are in the
implementation library's dependency closure, so they cannot depend on it and
source-include both packages instead (see
[Design](../explanation/design.md) for why):

```sdl
importPaths "src" "../test-runner/src" "../test-runner-impl/src"

configuration "unittest" {
    sourcePaths "../test-runner/src" "../test-runner-impl/src"
}
```

## 2. Write a plain test

Nothing changes relative to silly — a string UDA names the test:

```d
@("area.rectangle")
@safe pure nothrow @nogc
unittest
{
    assert(3 * 4 == 12);
}
```

```console
$ dub test :my-package
 ✓ my.geometry area.rectangle

Summary: 1 passed, 0 failed in 0.2ms
```

## 3. Move a pure test to compile time

If the test body is CTFE-able, `@ctfe` runs it while the test build compiles
— it never executes (or even exists) at runtime, and a failure becomes a
compile error pointing at the failing assertion:

```d
import sparkles.test_runner.attributes : ctfe;

@("area.rectangle.ct")
@ctfe @safe pure nothrow @nogc
unittest
{
    assert(3 * 4 == 12);
}
```

```console
$ dub test :my-package
 ⚙ my.geometry area.rectangle.ct (compile time)

Summary: 0 passed, 0 failed, 1 compile-time in 0.1ms
```

## 4. Run a test without druntime

Mark a self-sufficient test `@betterC` and ask the runner to extract, compile
(with `-betterC`, no druntime), and execute it:

```d
import sparkles.test_runner.attributes : betterC;

@("area.rectangle.bc")
@betterC @safe pure nothrow @nogc
unittest
{
    assert(3 * 4 == 12);
}
```

```console
$ dub test :my-package -- --better-c
 > area.rectangle.bc [src/my/geometry.d:12]
1 @betterC tests passed
```

`@betterC` tests also run in the normal `dub test` pass — the mode is an
_additional_ environment, not a replacement. The same applies to `@wasm`
(see the [how-to](../how-to/write-wasm-tests.md)).

## 5. Benchmark something

`@benchmark` tests are skipped by `dub test` and measured by `--bench`:

```d
import sparkles.test_runner.attributes : benchmark;
import sparkles.test_runner.bench : benchIter, blackBox;

@("area.polygon.bench")
@benchmark @safe
unittest
{
    auto vertices = makePolygon(1000); // setup — not measured
    benchIter({ blackBox(area(blackBox(vertices))); }); // measured
}
```

```console
$ dub test :my-package -- --bench
╭────────────────────┬───────┬─────────────┬────────┬────────┬────────╮
│ benchmark          │ iters │ median/iter │   ±dev │    min │    max │
│ area.polygon.bench │  8192 │    512.40ns │ 3.10ns │ 508.11 │ 530.02 │
╰────────────────────┴───────┴─────────────┴────────┴────────┴────────╯
```

## Where to go next

- [Run and filter tests](../how-to/run-and-filter-tests.md) for the everyday
  CLI.
- The [attribute reference](../reference/attributes.md) for exact semantics
  and constraints of each attribute.
