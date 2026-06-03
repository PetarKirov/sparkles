# Agent Guidelines for Sparkles

This document provides instructions for AI agents working on the `sparkles` codebase.

## Project Overview

`sparkles` is a D library providing utilities for building CLI applications. It consists of:

- **core-cli** - Core CLI utilities: terminal styling, pretty-printing, small buffer optimization, process utilities
- **test-utils** - Testing utilities: diff tools, temp filesystem helpers

## Guidelines

Detailed guidelines are in `docs/guidelines/`:

- **[Code Style](./code-style.md)** — Formatting, naming, module layout, imports
- **[Functional & Declarative Programming](./functional-declarative-programming-guidelines.md)** — Range pipelines, UFCS, purity, lazy evaluation
- **[Design by Introspection](./design-by-introspection-01-guidelines.md)** — Capability traits, optional primitives, shell-with-hooks pattern
- **[Interpolated Expression Sequences](./interpolated-expression-sequences.md)** — IES syntax, metadata processing, context-aware encoding
- **[DDoc](./ddoc.md)** — Documentation comments, sections, macros, cross-referencing

## Building and Testing

```bash
# Build a specific sub-package
dub build :core-cli

# Run all tests
ci --test

# Test specific sub-package
dub test :core-cli

# Run tests matching a pattern
dub test :core-cli -- -i "SmallBuffer"
```

## Module Layout

See [Code Style Guide](./code-style.md#module-layout) for module organization and import conventions.

## Code Style Philosophy

### Functional Style with UFCS

Prefer **functional style** with UFCS using `std.algorithm` and `std.range`:

```d
auto result = items
    .filter!(a => a.isValid)
    .map!(a => a.name)
    .array;
```

See [Functional & Declarative Programming Guidelines](./functional-declarative-programming-guidelines.md) for comprehensive patterns including lazy evaluation, purity, and composable abstractions.

### Safety Attributes

Strive for maximum safety. Apply attributes at module or scope level when possible:

```d
@safe pure nothrow:

// Functions here inherit these attributes

@nogc:
// Additional @nogc section

@trusted:
// Functions requiring @trusted for low-level operations
```

### Preview Flags

The project uses D preview features. These are configured in `dub.sdl`:

```
dflags "-preview=in" "-preview=dip1000"
```

- `-preview=in` - Enables `in` parameters as `scope const`
- `-preview=dip1000` - Enables improved scope semantics for `@safe` code

### Contract Programming

Use expression-based `in` contracts for preconditions:

```d
void popBack()
in (_length > 0, "Cannot pop from empty buffer")
{
    _length--;
}
```

See [Code Style Guide](./code-style.md#expression-based-contracts-dip1009) for the full pattern including `out` contracts.

### Named Arguments

Use named arguments for struct initialization (see [Code Style Guide](./code-style.md#named-arguments-dip1030)):

```d
auto opts = PrettyPrintOptions!void(
    indentStep: 2,
    maxDepth: 8,
    maxItems: 32,
    softMaxWidth: 80,
    useColors: true,
);
```

### @nogc Code

For @nogc contexts, use:

- `SmallBuffer` for dynamic arrays without GC allocation
- `pureMalloc`/`pureFree` from `core.memory` for manual allocation
- Static arrays when size is known at compile time

```d
@safe pure nothrow @nogc
unittest
{
    SmallBuffer!(char, 256) buf;
    buf ~= "Hello";
    buf ~= ' ';
    buf ~= "World";
    assert(buf[] == "Hello World");
}
```

## Unit Tests

### Test Placement

- Every public function should have a unit test following it
- Functions should have at least one public/Ddoc-ed unit test (`///` comment at minimum)

### Test Attributes

All unit tests must have explicit safety attributes:

- Use `@safe` or `@system` - never omit the safety attribute
- `@trusted unittest` is bad practice - tests should verify safety, not bypass it
- Add `pure`, `nothrow`, and `@nogc` when possible

```d
@("SmallBuffer.basic.creation")
@safe pure nothrow @nogc
unittest
{
    SmallBuffer!(int, 4) buf;
    assert(buf.length == 0);
    assert(buf.empty);
}
```

### @nogc nothrow Testing

For `@nogc nothrow` unit tests, use:

- `recycledErrorInstance` for throwing exceptions without GC allocation
- `SmallBuffer` as an output range instead of `appender`

```d
@("prettyPrint.integers")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.lifetime : recycledErrorInstance;
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    SmallBuffer!(char, 1024) buf;
    prettyPrint(42, buf);

    if (buf[] != "42")
        throw recycledErrorInstance!AssertError("Mismatch");
}
```

### Testing Output-Range `toString` Methods

For types that expose `void toString(Writer)(ref Writer w)`, prefer
`checkToString` from `sparkles.core_cli.smallbuffer` over hand-rolling a
`SmallBuffer` + `recycledErrorInstance` dance. It renders into a `SmallBuffer`
so the test stays `@safe pure nothrow @nogc`, and reports the expected/actual
diff via a recycled `AssertError` on mismatch.

```d
@("MyType.toString.basic")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : checkToString;

    checkToString(MyType(42), "MyType(42)");
}
```

### Silly Test Runner

This project uses the `silly` test runner. Use UDA-based test names:

```d
@("ModuleName.functionName.testCase")
@safe pure nothrow @nogc
unittest
{
    // Test implementation
}
```

#### Test Options

```
-i, --include    Run tests matching regex
-e, --exclude    Skip tests matching regex
-v, --verbose    Show full stack traces and durations
-t, --threads    Number of worker threads (0 = auto)
--no-colours     Disable colored output
```

#### Examples

```bash
# Run tests matching "SmallBuffer"
dub test :core-cli -- -i "SmallBuffer"

# Run tests with verbose output
dub test :core-cli -- -v

# Exclude slow tests
dub test :core-cli -- -e "slow"

# Single-threaded execution
dub test :core-cli -- -t 1
```

## File Structure

```
sparkles/
├── .github/workflows/
│   └── ci.yml                     # GitHub Actions CI
├── apps/
│   └── ci/                         # CI helper sub-package (tests, examples, link maintenance)
│       ├── src/app.d
│       ├── dub.sdl
│       └── dub.selections.json     # Local dub-resolved versions
├── libs/
│   ├── core-cli/
│   │   ├── src/sparkles/core_cli/
│   │   │   ├── logger.d           # Delta-time-prefixed logger
│   │   │   ├── prettyprint.d      # Colorized pretty-printing
│   │   │   ├── process_utils.d    # Process execution
│   │   │   ├── smallbuffer.d      # @nogc dynamic buffer
│   │   │   ├── styled_template.d  # IES-based styled text processing
│   │   │   ├── term_size.d        # Terminal size detection
│   │   │   ├── term_style.d       # Terminal styling/colors
│   │   │   ├── text_writers.d     # @nogc text writing utilities
│   │   │   └── ...
│   │   └── dub.sdl
│   └── test-utils/
│       ├── src/sparkles/test_utils/
│       │   ├── diff_tools.d       # Diff utilities for tests
│       │   ├── tmpfs.d            # Temp filesystem helpers
│       │   └── ...
│       └── dub.sdl
├── nix/
│   ├── dub-lock.json              # Nix-format lockfile shared by `ci` + examples (buildDubPackage)
│   └── shells/default.nix         # Nix dev shell
└── dub.sdl                        # Root package config
```

## Development Environment

The project uses a Nix development shell. New dependencies can be added to `nix/shells/default.nix`.

Run commands within the devshell:

```bash
nix develop -c dub build :core-cli
nix develop -c ci --test
```

## CI/CD

[GitHub Actions CI](../../.github/workflows/ci.yml) runs on both Linux and macOS:

1. Lint checks via reusable workflow
2. `nix flake check` for Nix validation
3. `ci --test --fail-fast` to test all sub-packages

## Commit Message Convention

Follow the conventional commits format:

```
<type>(<scope>): <description>
```

### Types

- `feat` - New feature
- `fix` - Bug fix
- `refactor` - Code refactoring
- `chore` - Maintenance tasks
- `build` - Build system changes
- `ci` - CI/CD changes
- `docs` - Documentation changes

### Scopes

- `core-cli` - For core-cli package changes
- `test-utils` - For test-utils package changes
- `dub` - For dub configuration changes
- `nix` - For Nix configuration changes
- `guidelines` - For documentation guidelines changes

### Examples

```
feat(core-cli): Add SmallBuffer with small buffer optimization
fix(core-cli): Handle edge case in prettyPrint for empty arrays
refactor(core-cli): Rename staticInstance to recycledInstance
chore(nix): Update flake inputs
```

## Common Patterns

### Output Ranges

Many utilities work with output ranges for flexibility:

```d
ref Writer prettyPrint(T, Writer, Hook)(
    in T value,
    return ref Writer writer,
    in PrettyPrintOptions!Hook opt = PrettyPrintOptions!void()
)
{
    prettyPrintImpl(value, writer, opt, 0);
    return writer;
}

// Use with any output range
import std.array : appender;
auto w = appender!string;
prettyPrint(myValue, w);
string result = w[];
```

### Compile-Time Computation

Leverage D's CTFE for compile-time computation:

```d
// Computed at compile time
enum string formattedText = "Format me"
    .stylizedTextBuilder(true)
    .bold
    .underline
    .blue;
```

### Template Constraints

Use template constraints for type safety:

```d
string numToString(T)(T value)
if (__traits(isUnsigned, T))
{
    // Implementation
}
```

For complex capability detection patterns (traits, optional primitives, fallback paths), see [Design by Introspection Guidelines](./design-by-introspection-01-guidelines.md).

For `@nogc nothrow` error handling, see the [Expected Error Handling Idioms](./idioms/expected/index.md) guide which provides patterns on transforming, chaining, and flattening expected values, alongside comparisons for developers coming from Rust.

## Debugging Tips

1. **Use verbose test output**: `dub test :core-cli -- -v` shows full stack traces
2. **Test single functions**: Use `-i "functionName"` to isolate tests
3. **Check @nogc compatibility**: Ensure tests compile with `@nogc` attribute
4. **Use `check` helper**: In tests, use the `check` function for pretty error messages with diffs

## Documenting New Features

When adding a new feature to sparkles, add a runnable example to `README.md` as a dub single-file program inside a fenced `d` code block:

````markdown
```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "readme_my_feature"
    dependency "sparkles:core-cli" version="*"
+/

import sparkles.core_cli.my_module;

void main()
{
    // Example usage
}
```
````

Follow the code block with a `[Output]`-labelled fenced block showing the expected output:

````markdown
```[Output]
Expected output here
```
````

The `[Output]` label is the required convention: `--verify` only treats `[Output]` fences as expected output (a bare ` ``` ` fence is ignored). It renders as a labelled "Output" panel under VitePress and as a plain block on GitHub.

### Verifying README Examples

Use `nix run .#ci -- ...` to verify that runnable markdown examples compile and produce correct output:

```bash
# Verify all examples match their expected output
nix run .#ci -- --verify --files README.md

# Update output blocks with actual output (golden snapshot update)
nix run .#ci -- --update --files README.md

# Just run examples and display results
nix run .#ci -- --files README.md
```

<div v-pre>

### Dynamic Output with `<!-- md-example-expected -->`

When an example produces dynamic output (timestamps, file paths, durations, etc.), add a `<!-- md-example-expected -->` HTML comment directive between the code block and the output block. The directive contains a wildcard pattern used by `--verify`, while the literal output block below it is preserved for readers. Use `{{_}}` as a wildcard that matches any non-empty text:

````markdown
<!-- md-example-expected
[ {{_}} | info | {{_}} ]: Server started
-->

```[Output]
[ 14:32:01 | info | app.d:12 ]: Server started
```
````

The HTML comment is invisible in rendered markdown, so readers see the nice hardcoded values. The `--verify` mode uses the wildcard pattern instead of the literal block for comparison.

</div>

## Dub Dependency Paths

Internal files that live inside the repository must reference sibling sub-packages with a
**relative `path`** to the repo root instead of `version="*"`:

```sdl
dependency "sparkles:core-cli" path="../../.."
```

The exact `path` value depends on the file's location relative to the repo root (where the
root `dub.sdl` lives). For example:

| File location                | `path` value |
| ---------------------------- | ------------ |
| `libs/core-cli/dub.sdl`      | `../..`      |
| `libs/core-cli/examples/*.d` | `../../..`   |
| `docs/guidelines/*.d`        | `../..`      |

This applies to **all** in-repo files: `dub.sdl` configs, single-file example scripts, and
guideline runnable snippets.

**Exception — public documentation (`README.md`):** README examples are intended to be
copy-pasted by end-users who don't have the repo layout, so they must keep
`version="*"`.

## Dependencies

- `silly` - Test runner (dev dependency)
- `delta` - Diff tool for test comparisons (system dependency via Nix)

All D dependencies are managed via `dub.sdl` and system dependencies via Nix flake.
