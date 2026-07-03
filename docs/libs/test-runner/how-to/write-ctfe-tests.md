# Write compile-time (`@ctfe`) tests

`@ctfe` moves a test from runtime to compile time: the runner forces the test
through CTFE with a `static assert` while the test build compiles.

```d
import sparkles.test_runner.attributes : ctfe;

@("caseFold.ascii")
@ctfe @safe pure nothrow @nogc
unittest
{
    assert(caseFold("MiXeD") == "mixed");
}
```

- A failing assertion is a **compile error** pointing into the test body,
  with the full CTFE call stack.
- A passing test is reported by `dub test` as `⚙ … (compile time)` — it is
  not executed again at runtime.
- The body must be CTFE-able: no I/O, no `@system` pointer tricks, no
  runtime-only intrinsics. `-checkaction=context` assert messages work.

The attribute is named after — and is forward-compatible with — the `@__ctfe`
function attribute introduced in DMD 2.113 (which enforces "CTFE-only, no
codegen" at the compiler level).

## When to use it

- Pure algorithmic code you want verified on every compile, even of
  non-test builds of downstream mixins/templates.
- Guarding CTFE-ability itself: marking a test `@ctfe` fails the build the
  moment the tested code stops being CTFE-compatible.

## Attribute compile-time cost to tests (`--ctfe-trace`)

CTFE time is compile time. To see what each `@ctfe` test costs, build the
test configuration with LDC's `-ftime-trace` and hand the trace to the
runner:

```sdl
configuration "unittest" {
    dflags "-ftime-trace" "-ftime-trace-file=$PACKAGE_DIR/build/trace.json" \
        "--ftime-trace-granularity=0" platform="ldc"
}
```

```console
$ dub test :my-package -- --ctfe-trace build/trace.json
╭───────────────────┬───────────────────────┬───────────╮
│ @ctfe test        │ location              │ CTFE time │
│ caseFold.ascii    │ src/my/text.d:148     │ 6.0ms     │
╰───────────────────┴───────────────────────┴───────────╯
total CTFE time attributed to @ctfe tests: 6.0ms
```

> [!WARNING]
> Add the flags in `dub.sdl`, not via the `DFLAGS` environment variable —
> `DFLAGS` replaces dub's build-type flags including `-unittest` itself, so
> the test build silently stops being a test build.
