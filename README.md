<p align="center">
  <h1 align="center">sparkles</h1>
  <p align="center">
    <strong>A small D library for CLI applications</strong>
  </p>
  <p align="center">
    Terminal styling, pretty-printing, UI components, and @nogc utilities
  </p>
  <p align="center">
    <em>Early stage (v0.0.1) -- API may change</em>
  </p>
  <p align="center">
    <a href="https://github.com/PetarKirov/sparkles/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/PetarKirov/sparkles/actions/workflows/ci.yml/badge.svg"></a>
    <a href="https://code.dlang.org/packages/sparkles"><img alt="Dub version" src="https://img.shields.io/dub/v/sparkles.svg"></a>
    <a href="https://code.dlang.org/packages/sparkles"><img alt="Dub downloads" src="https://img.shields.io/dub/dt/sparkles.svg"></a>
    <a href="https://sparkles-docs.pages.dev/"><img alt="Docs" src="https://img.shields.io/badge/docs-sparkles--docs.pages.dev-blue"></a>
    <a href="LICENSE"><img alt="BSL-1.0" src="https://img.shields.io/badge/license-BSL--1.0-blue.svg"></a>
  </p>
</p>

---

## Overview

**sparkles:core-cli** is a collection of utilities for building command-line interfaces in D, with a focus on `@safe`, `@nogc`, `pure`, and `nothrow` compatibility.

### What's Inside

- **Styled Templates** -- Apply ANSI styles using D's Interpolated Expression Sequences (IES) with a concise `{style text}` syntax
- **Pretty Printing** -- Colorized, type-aware formatting for any D type via compile-time introspection
- **UI Components** -- Tables, boxes, headers, and OSC 8 hyperlinks
- **Terminal Styling** -- ANSI color and text attribute support with a fluent builder API
- **SmallBuffer** -- A `@nogc` dynamic buffer with small buffer optimization (SBO)
- **@nogc Utilities** -- `recycledInstance`, text writers, and output range interfaces

## Quick Start

Add sparkles to your `dub.sdl`:

```sdl
dependency "sparkles:core-cli" version="~>0.0.1"
```

Or `dub.json`:

```json
"dependencies": {
    "sparkles:core-cli": "~>0.0.1"
}
```

## Modules

### Styled Templates

Apply terminal styles using D's Interpolated Expression Sequences.

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "readme_styled_templates"
    dependency "sparkles:core-cli" version="*"
+/

import sparkles.core_cli.styled_template;

void main()
{
    int cpu = 75;
    styledWriteln(i"CPU: {red $(cpu)%} Status: {green OK}");
    styledWriteln(i"{bold.red ERROR:} Connection refused");
    styledWriteln(i"{cyan Outer {bold.underline inner} just cyan}");
    styledWriteln(i"Press {bold.cyan q} to quit, {bold.cyan h} for help");
}
```

```
CPU: 75% Status: OK
ERROR: Connection refused
Outer inner just cyan
Press q to quit, h for help
```

Syntax at a glance:

| Syntax                      | Description                    |
| --------------------------- | ------------------------------ |
| `{red text}`                | Single style                   |
| `{bold.red text}`           | Chained styles                 |
| `{bold outer {red nested}}` | Nested blocks with inheritance |
| `{red text {~red normal}}`  | Style negation with `~`        |
| `{{` / `}}`                 | Escaped literal braces         |

### Pretty Printing

Format D values with syntax highlighting and structural indentation. Supports enums, booleans, strings, numerics, pointers, tuples, associative arrays, arrays, ranges, structs, and classes.

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "readme_pretty_printing"
    dependency "sparkles:core-cli" version="*"
+/

import std.stdio : writeln;

import sparkles.core_cli.prettyprint;

struct Server
{
    string name;
    string ip;
    int port;
}

struct Cluster
{
    string name;
    Server[] servers;
    bool active;
}

void main()
{
    auto cluster = Cluster(
        name: "Production",
        servers: [
            Server("web-01", "192.168.1.10", 80),
            Server("web-02", "192.168.1.11", 80),
            Server("db-01", "192.168.1.20", 5432),
        ],
        active: true,
    );

    writeln(prettyPrint(cluster, PrettyPrintOptions!void(useColors: false)));
}
```

```
Cluster(
  name: "Production",
  servers: [
    Server(name: "web-01", ip: "192.168.1.10", port: 80),
    Server(name: "web-02", ip: "192.168.1.11", port: 80),
    Server(name: "db-01", ip: "192.168.1.20", port: 5432)
  ],
  active: true
)
```

Options via `PrettyPrintOptions`:

```d
prettyPrint(value, PrettyPrintOptions!void(
    indentStep: 2,       // spaces per indent level
    maxDepth: 8,         // recursion limit
    maxItems: 32,        // max array/AA items shown
    softMaxWidth: 80,    // single-line threshold
    useColors: true,     // ANSI color output
    useOscLinks: false,  // OSC 8 hyperlinks on type names
));
```

The `SourceUriHook` template parameter controls the URI scheme for OSC 8 hyperlinks. Use `SchemeHook!"code"` for VS Code, `EditorDetectHook` for auto-detection from `$EDITOR`/`$VISUAL`, or implement a custom hook via [Design by Introspection](docs/guidelines/design-by-introspection-01-guidelines.md).

### Terminal Styling

ANSI colors and text attributes via `stylize` and a fluent `stylizedTextBuilder`. Both work at runtime and at compile time (CTFE).

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "readme_terminal_styling"
    dependency "sparkles:core-cli" version="*"
+/

import std.stdio : writeln;

import sparkles.core_cli.term_style;

void main()
{
    // Runtime styling
    writeln("Error: ".stylize(Style.red) ~ "something went wrong");

    // Compile-time styling via fluent builder
    enum title = "Important".stylizedTextBuilder(true).bold.underline.red;
    writeln(title);
}
```

```
Error: something went wrong
Important
```

### UI Components

#### Tables

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "readme_tables"
    dependency "sparkles:core-cli" version="*"
+/

import std.stdio : writeln;

import sparkles.core_cli.ui.table;

void main()
{
    drawTable([
        ["Name",    "Status",  "Load"],
        ["web-01",  "UP",      "23%"],
        ["web-02",  "UP",      "45%"],
        ["db-01",   "DOWN",    "0%" ],
    ]).writeln;
}
```

```
╭────────┬────────┬──────╮
│ Name   │ Status │ Load │
│ web-01 │ UP     │ 23%  │
│ web-02 │ UP     │ 45%  │
│ db-01  │ DOWN   │ 0%   │
╰────────┴────────┴──────╯
```

#### Boxes

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "readme_boxes"
    dependency "sparkles:core-cli" version="*"
+/

import std.stdio : writeln;

import sparkles.core_cli.ui.box;

void main()
{
    drawBox(
        ["Build started at 14:32:01",
         "Compiling 42 modules...",
         "Linking executable...",
         "Build completed in 3.2s"],
        "Build Log",
        BoxProps(footer: "Success"),
    ).writeln;
}
```

```
╭──╼ Build Log ╾────────────╮
│ Build started at 14:32:01 │
│ Compiling 42 modules...   │
│ Linking executable...     │
│ Build completed in 3.2s   │
╰──╼ Success ╾──────────────╯
```

#### Headers

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "readme_headers"
    dependency "sparkles:core-cli" version="*"
+/

import std.stdio : writeln;

import sparkles.core_cli.ui.header;

void main()
{
    // Divider style:  ── Section Title ──
    "Section Title".drawHeader.writeln;

    // Banner style
    "Main Title".drawHeader(HeaderProps(
        style: HeaderStyle.banner,
        lineChar: '═',
        width: 40,
    )).writeln;
}
```

```
── Section Title ──
════════════════════════════════════════
               Main Title
════════════════════════════════════════
```

#### OSC 8 Hyperlinks

Make text clickable in terminal emulators that support [OSC 8](https://gist.github.com/egmontkob/eb114294efbcd5adb1944c9f3cb5feda).

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "readme_osc_link"
    dependency "sparkles:core-cli" version="*"
+/

import std.stdio : writeln;

import sparkles.core_cli.ui.osc_link;
import sparkles.core_cli.term_style : Style;

void main()
{
    // Plain clickable link
    writeln(oscLink(text: "Example", uri: "https://example.com"));

    // Styled clickable link (blue text)
    writeln(oscLink(text: "D Language", uri: "https://dlang.org", style: Style.blue));
}
```

### SmallBuffer

A `@nogc` dynamic array with small buffer optimization. Stores data inline up to a configurable threshold, then falls back to the heap via `pureMalloc`.

```d
import sparkles.core_cli.smallbuffer;

@safe pure nothrow @nogc
unittest {
    SmallBuffer!(char, 64) buf;
    buf ~= "Hello";
    buf ~= ' ';
    buf ~= "World";
    assert(buf[] == "Hello World");
    assert(!buf.onHeap);  // still using inline storage
}
```

Works as an output range, so it composes with `std.algorithm`, `prettyPrint`, styled templates, and the rest of the library.

### @nogc Utilities

**`recycledInstance`** -- Reuse thread-local static instances for throwing errors in `@nogc` code:

```d
import sparkles.core_cli.lifetime;

@nogc void validate(int x) {
    if (x < 0)
        throw recycledInstance!Error("value must be non-negative");
}
```

**`text_writers`** -- Write integers, floats, escaped characters, and ANSI codes without GC allocation.

**`term_unstyle`** -- Strip ANSI escape sequences from styled text.

**`term_size`** -- Detect terminal window resizes via `SIGWINCH`.

## Examples

Runnable examples are in [`libs/core-cli/examples/`](libs/core-cli/examples/):

```bash
dub run --single libs/core-cli/examples/styled_template.d
dub run --single libs/core-cli/examples/prettyprint.d
dub run --single libs/core-cli/examples/table.d
dub run --single libs/core-cli/examples/box.d
dub run --single libs/core-cli/examples/header.d
dub run --single libs/core-cli/examples/osc_link.d
dub run --single libs/core-cli/examples/color.d
```

## Building & Testing

```bash
# Build
dub build :core-cli

# Run all tests
./scripts/run-tests.sh

# Test a specific sub-package
dub test :core-cli

# Run tests matching a pattern
dub test :core-cli -- -i "SmallBuffer"

# Verbose output with stack traces
dub test :core-cli -- -v
```

The project uses a **Nix development shell** for reproducible builds:

```bash
nix develop -c dub build :core-cli
nix develop -c ./scripts/run-tests.sh
```

## Documentation

Documentation (work in progress) is available at **[sparkles-docs.pages.dev](https://sparkles-docs.pages.dev/)**.

## License

[Boost Software License 1.0](LICENSE)
