# `sparkles:test-runner`

`sparkles:test-runner` is the monorepo's general-purpose `unittest` runner
(the successor of the third-party `silly` runner). It keeps silly's CLI
(`-i`/`-e`/`-v`/`-t`/`--no-colours`, parallel execution, `@("name")` UDAs) and
adds opt-in attributes that run tests in environments plain `unittest` blocks
cannot reach:

```d
import sparkles.test_runner.attributes : benchmark, betterC, ctfe, wasm;

@("readInteger.basic")
@betterC @safe pure nothrow @nogc
unittest { /* also compiled & run without druntime via --better-c */ }

@("levenshtein.ct")
@ctfe @safe
unittest { /* evaluated during compilation — a failure is a compile error */ }

@("sort.bench")
@benchmark @safe
unittest { /* measured with auto-scaling iterations via --bench */ }
```

## The whole runner on one page

New here, or want a single reference to keep open? **[The guide](./guide.md)**
covers integration, writing tests, running and filtering, every attribute, and
the full CLI — end to end, on one page.

## How this documentation is organised

The rest of these docs follow the [Diátaxis](https://diataxis.fr/) framework.

### [Tutorial](./tutorial/getting-started.md)

_Learning-oriented._ Wire the runner into a package and write one test of
each kind.

- [Getting started](./tutorial/getting-started.md)

### How-to guides

_Task-oriented._ Short recipes for common jobs.

- [Run and filter tests](./how-to/run-and-filter-tests.md)
- [Write compile-time (`@ctfe`) tests](./how-to/write-ctfe-tests.md)
- [Write `-betterC` (`@betterC`) tests](./how-to/write-betterc-tests.md)
- [Write WebAssembly (`@wasm`) tests](./how-to/write-wasm-tests.md)
- [Benchmark with `@benchmark`](./how-to/benchmark.md)
- [Skip tests at runtime](./how-to/skip-tests.md)

### Reference

_Information-oriented._ Precise descriptions of the moving parts.

- [Command-line options](./reference/cli.md)
- [Attributes](./reference/attributes.md)

### Explanation

_Understanding-oriented._ Why the runner is built the way it is.

- [Design](./explanation/design.md)
