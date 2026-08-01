# Write `-betterC` (`@betterC`) tests

`@betterC` marks a test as runnable without druntime. Such tests run normally
under `dub test`, and `--better-c` additionally extracts them into a
standalone program compiled with `-betterC` and executes it:

```bash
dub test :base -- --better-c
```

```console
 > text.readers.readInteger.advancesOnSuccess [libs/base/src/sparkles/base/text/readers.d:122]
 ...
17 @betterC tests passed
```

A failing `assert` aborts with the original `file:line` (the generated code
carries `#line` directives):

```console
betterc_tests: libs/base/src/.../readers.d:124: Assertion `r.hasValue' failed.
```

## Wiring in the tested module

Import the attribute unconditionally (not under `version (unittest)`): the
compiler resolves unittest UDAs even in builds that skip the bodies.

```d
import sparkles.test_runner.attributes : betterC;

@("text.readers.tryConsume")
@betterC @safe pure nothrow @nogc
unittest { /* ... */ }
```

## What an extracted test can use

The generated program `import`s the test's module and re-emits the test body
as a named function, so the body can only reference:

- the module's **public** symbols (module-scope `private` imports are
  invisible — add body-local imports for anything else);
- **the test's own module**, which the runner compiles in by default
  (`-i=<module>`), so ordinary functions work and not only templates;
- non-template functions of **other** modules explicitly compiled in with
  `--include-import=<pattern>` (maps to the compiler's `-i=<pattern>`), e.g.
  a sibling module or `--include-import=std.ascii`.

Every module compiled in must be betterC-codegen-clean: no GC allocations,
exceptions, or TypeInfo in any of its non-template functions. That is why
only the test's own module is included automatically and nothing beyond it —
one blanket "include everything" would drag in the first transitively
imported module that touches `std.uni` and break the build.

## Tests in a module that is not betterC-clean

A module can be far from `-betterC`-compatible and still host a `@betterC`
test, as long as that test needs nothing from it. Say so on the attribute:

```d
@("extract.braceCounting.betterC")
@betterC(selfContained: true) @safe pure nothrow @nogc
unittest
{
    int depth;
    foreach (c; "{ { } }")
        depth += c == '{' ? 1 : c == '}' ? -1 : 0;
    assert(depth == 0);
}
```

`selfContained: true` keeps the module out of the generated program entirely,
so the body is limited to templates and CTFE-able code — and asserting that
self-containment is usually the point of such a test. The runner's own
dogfooding tests work exactly this way, since their modules import Phobos.

`--no-auto-include` applies the same strictness to a whole run, which is a
quick way to check whether a test really is self-contained.

## Toolchain

`--compiler=<dc>` (or `$DC`) picks the compiler; `ldc2` then `dmd` from
`$PATH` is the default. Import paths are derived from the discovered tests'
module/file pairs plus a best-effort `dub describe`; add unusual roots with
`-I`/`--import-path`. `--keep` preserves the generated program for
inspection.
