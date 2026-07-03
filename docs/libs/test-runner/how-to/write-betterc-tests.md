# Write `-betterC` (`@betterC`) tests

`@betterC` marks a test as runnable without druntime. Such tests run normally
under `dub test`, and `--better-c` additionally extracts them into a
standalone program compiled with `-betterC` and executes it:

```bash
dub test :base -- --better-c \
    --include-import=sparkles.base.text --include-import=std.ascii
```

```console
 > text.readers.readInteger.advancesOnSuccess [libs/base/src/sparkles/base/text/readers.d:122]
 ...
7 @betterC tests passed
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
- **templates and CTFE-able code** by default — non-template functions live
  in object code that is not linked in;
- non-template functions of modules explicitly compiled in with
  `--include-import=<pattern>` (maps to the compiler's `-i=<pattern>`).
  Included modules must be betterC-codegen-clean: no GC allocations,
  exceptions, or TypeInfo in any of their non-template functions.

There is deliberately no blanket "include everything" default: the moment any
transitively imported module is not betterC-clean (e.g. anything touching
`std.uni`), a blanket include breaks the build. Opt modules in precisely.

## Toolchain

`--compiler=<dc>` (or `$DC`) picks the compiler; `ldc2` then `dmd` from
`$PATH` is the default. Import paths are derived from the discovered tests'
module/file pairs plus a best-effort `dub describe`; add unusual roots with
`-I`/`--import-path`. `--keep` preserves the generated program for
inspection.
