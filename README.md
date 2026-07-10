<p align="center">
  <h1 align="center">sparkles</h1>
  <p align="center">
    <strong>A small D library for CLI applications</strong>
  </p>
  <p align="center">
    Base utilities, terminal styling, pretty-printing, UI components, and @nogc support
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

`sparkles` is a D monorepo of utilities for building command-line applications
and supporting libraries. `sparkles:base` provides allocation-conscious
foundation modules with a focus on `@safe`, `@nogc`, `pure`, and `nothrow`
compatibility; `sparkles:core-cli` builds on it with higher-level CLI tools.

### What's Inside

- **Base** -- `SmallBuffer`, lifetime helpers, text readers/writers, terminal styling, styled templates, terminal control sequences, and logging
- **Styled Templates** -- Apply ANSI styles using D's Interpolated Expression Sequences (IES) with a concise `{style text}` syntax
- **Pretty Printing** -- Colorized, type-aware formatting for any D type via compile-time introspection
- **UI Components** -- Tables (spans, alignment, titles, streaming), boxes, headers, trees, meters/progress bars, key-value lists, horizontal layout, and OSC 8 hyperlinks
- **Live Rendering** -- Repaint-in-place live regions and task-list checklists with bounded output tails (nix/bazel-style), degrading to a plain transition log when piped
- **Interactive Prompts** -- `select`/`confirm`/`textInput` with a uniform non-interactive policy for `--auto` flags and piped stdin
- **Terminal Capabilities** -- One-shot tty/color/unicode/size detection (`detectTermCaps`) and a theme layer with ASCII fallbacks
- **Semantic Versioning** -- SemVer parsing, normalization, and precedence comparison
- **Test Runner** -- Parallel `unittest` runner with compile-time (`@ctfe`), `-betterC` (`@betterC`), WebAssembly (`@wasm`), and benchmark (`@benchmark`) modes

## Quick Start

Add the package you need to your `dub.sdl`:

```sdl
dependency "sparkles:base" version="~>0.0.1"
dependency "sparkles:core-cli" version="~>0.0.1"
```

Or `dub.json`:

```json
"dependencies": {
    "sparkles:base": "~>0.0.1",
    "sparkles:core-cli": "~>0.0.1"
}
```

## Modules

### Base

`sparkles:base` contains the shared low-level modules used by the rest of the
monorepo: `SmallBuffer`, `recycledInstance`, `recycledErrorInstance`, `@nogc`
text parsing/formatting, terminal styling, styled IES rendering, and the
`CoreLogger` logging interface. See the [base documentation](docs/libs/base/index.md)
for the tutorial, how-to guides, and API index.

### Versions

`sparkles:versions` is an ecosystem-aware version library: it parses,
compares, and constrains the version strings of many package ecosystems
(SemVer, PEP 440/PyPI, Maven, Debian, CalVer, …) and interoperates with
pURL and VERS. Each ecosystem is a hand-written struct conforming to a
small compile-time concept; cross-scheme comparison does not compile.

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "readme_versions"
    dependency "sparkles:versions" version="*"
+/

import std.stdio : writeln;
import sparkles.versions.schemes.semver : SemVer;
import sparkles.versions.operations : satisfies;

void main()
{
    auto current = SemVer.parse("1.2.3").value;
    auto next = SemVer.parse("1.3.0-beta.1").value;
    writeln(current);
    writeln(next > current);

    // Loose parsing accepts a leading `v` and partial versions.
    writeln(SemVer.parseLoose("v1.2").value);

    // Range membership.
    auto range = SemVer.parseNativeRange("^1.2.0").value;
    writeln(current.satisfies(range));
}
```

```[Output]
1.2.3
true
1.2.0
true
```

For the full tour — comparing and sorting, ranges, VERS/pURL interop, the
eleven shipped schemes, and adding your own — see the
[versions documentation](docs/libs/versions/index.md).

### Styled Templates

Apply terminal styles using D's Interpolated Expression Sequences.

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "readme_styled_templates"
    dependency "sparkles:base" version="*"
+/

import sparkles.base.styled_template;

void main()
{
    int cpu = 75;
    styledWriteln(i"CPU: {red $(cpu)%} Status: {green OK}");
    styledWriteln(i"{bold.red ERROR:} Connection refused");
    styledWriteln(i"{cyan Outer {bold.underline inner} just cyan}");
    styledWriteln(i"Press {bold.cyan q} to quit, {bold.cyan h} for help");
}
```

```[Output]
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
| `#{` / `#}`                 | Escaped literal braces         |

### Pretty Printing

Format D values with syntax highlighting and structural indentation. Supports enums, booleans, strings, numerics, pointers, tuples, associative arrays, arrays, ranges, structs, and classes.

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "readme_pretty_printing"
    dependency "sparkles:base" version="*"
+/

import std.stdio : writeln;

import sparkles.base.prettyprint;

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

    writeln(prettyPrint(cluster, PrettyPrintOptions!void(colored: false)));
}
```

```[Output]
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
    colored: true,     // ANSI color output
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
    dependency "sparkles:base" version="*"
+/

import std.stdio : writeln;

import sparkles.base.term_style;

void main()
{
    // Runtime styling
    writeln("Error: ".stylize(Style.red) ~ "something went wrong");

    // Compile-time styling via fluent builder
    enum title = "Important".stylizedTextBuilder(true).bold.underline.red;
    writeln(title);
}
```

```[Output]
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

```[Output]
╭────────┬────────┬──────╮
│ Name   │ Status │ Load │
│ web-01 │ UP     │ 23%  │
│ web-02 │ UP     │ 45%  │
│ db-01  │ DOWN   │ 0%   │
╰────────┴────────┴──────╯
```

Cells can span columns and rows, columns can be aligned (including
`Align.decimal`, which lines a numeric column up on its dot) with per-cell
overrides, frames can carry a title/footer like `drawBox`'s, and separators and
glyphs are configurable (`TableProps` / the `stylePresets` registry) — including
`headerRows` / `headerCols` for a distinct rule setting off the header rows and
the stub (row-header) column. Both the dense `Cell[][]` form and a sparse
`Placement[]` form are accepted, and `drawTableLines` / `drawTableChunks` /
the writer overload emit the same bytes lazily for live regions and paced
output:

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "readme_table_spans"
    dependency "sparkles:core-cli" version="*"
+/

import std.stdio : write;

import sparkles.core_cli.ui.table;
import sparkles.base.text.width : Align;

void main()
{
    drawTable([
        [Cell("Quarterly Sales", colSpan: 3)],
        [Cell("Region"), Cell("Q1"), Cell("Q2")],
        [Cell("North"), Cell("1200"), Cell("1350")],
        [Cell("South"), Cell("98"), Cell("110")],
    ], TableProps(
        columnAligns: [Align.left, Align.right, Align.right],
        headerRows: 2, // banner + column-label row
        headerCols: 1, // the Region stub column
    )).write;
}
```

```[Output]
╭──────────────────────╮
│ Quarterly Sales      │
│ Region ┃   Q1 │   Q2 │
┝━━━━━━━━╋━━━━━━┿━━━━━━┥
│ North  ┃ 1200 │ 1350 │
│ South  ┃   98 │  110 │
╰────────┸──────┴──────╯
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

```[Output]
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

```[Output]
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
import sparkles.base.term_style : Style;

void main()
{
    // Plain clickable link
    writeln(oscLink(text: "Example", uri: "https://example.com"));

    // Styled clickable link (blue text)
    writeln(oscLink(text: "D Language", uri: "https://dlang.org", style: Style.blue));
}
```

```[Output]
Example
D Language
```

#### Meters & Progress

Proportional bars with eighth-cell precision, plus composed `done/total`
progress lines:

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "readme_meters"
    dependency "sparkles:core-cli" version="*"
+/

import std.stdio : writeln;

import sparkles.core_cli.ui.meter : meter, ProgressBar;

void main()
{
    writeln("|", meter(0.33, 16), "|");
    writeln("|", meter(7, 9, 16), "|");
    writeln(ProgressBar(done: 5, total: 40, barWidth: 16));
}
```

```[Output]
|█████▎          |
|████████████▌   |
██                5/40
```

#### Tree Views

Trees render from flat, pre-ordered `(label, depth)` nodes — no recursive node
objects, so any depth-first walk displays directly (and the guides compose as a
table's first column):

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "readme_tree"
    dependency "sparkles:core-cli" version="*"
+/

import std.stdio : writeln;

import sparkles.core_cli.ui.tree : renderTree, TreeNode;

void main()
{
    foreach (line; renderTree([
        TreeNode("apps", 0),
        TreeNode("ci", 1),
        TreeNode("release", 1),
        TreeNode("src", 2),
        TreeNode("libs", 0),
    ]))
        writeln(line);
}
```

```[Output]
apps
├─ ci
└─ release
   └─ src
libs
```

#### Live Task Lists

`LiveRegion` repaints a block of lines in place at the bottom of normal
scrollback (frames wrapped in DEC 2026 synchronized-output markers, completed
lines graduating into the scrollback above); `TaskReporter` drives a checklist
through it, with each running task's child-process output streaming into a
bounded tail pane (`runStreaming`). On piped output only the transition log
remains — no escape codes. The row renderers are pure and theme-driven:

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "readme_tasklist"
    dependency "sparkles:core-cli" version="*"
+/

import std.stdio : writeln;

import sparkles.core_cli.ui.tasklist : renderTaskList, TaskItem, TaskStatus;
import sparkles.core_cli.ui.theme : Theme;

void main()
{
    // The pure renderer (a real app drives TaskReporter over a LiveRegion —
    // see libs/core-cli/examples/live-tasklist.d for the animated version).
    auto items = [
        TaskItem(label: "fetch dependencies", status: TaskStatus.ok),
        TaskItem(label: "build", status: TaskStatus.running,
            tail: ["compiling module 11", "compiling module 12"]),
        TaskItem(label: "publish", status: TaskStatus.pending),
    ];
    foreach (line; renderTaskList(items, Theme(colors: false)))
        writeln(line);
}
```

```[Output]
⠋ build
  compiling module 11
  compiling module 12
○ publish
```

#### Layout Helpers

`kvList` renders aligned label/value lines; `hjoin` zips pre-rendered blocks
side by side (padded by visible width, so styled/CJK content lines up):

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "readme_layout"
    dependency "sparkles:core-cli" version="*"
+/

import std.stdio : writeln;

import sparkles.core_cli.ui.box : BoxProps, drawBox;
import sparkles.core_cli.ui.layout : hjoin, kvList;

void main()
{
    auto receipt = kvList([
        ["tag", "v0.6.0 (annotated)"],
        ["pushed", "origin ✔"],
    ]);
    writeln(hjoin([
        drawBox(receipt, "released", BoxProps(footer: "next: publish")),
        "notes:\n2 feats\n1 fix",
    ]));
}
```

```[Output]
╭──╼ released ╾──────────────╮  notes:
│ tag     v0.6.0 (annotated) │  2 feats
│ pushed  origin ✔           │  1 fix
╰──╼ next: publish ╾─────────╯
```

#### Interactive Prompts

Line-based `select` / `confirm` / `textInput`, each with a `PromptPolicy` so
`--auto` runs and piped stdin resolve to defaults (or fail) uniformly. EOF is
an error, never an accidental default:

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "readme_prompts"
    dependency "sparkles:core-cli" version="*"
+/

import std.stdio : writefln;

import sparkles.core_cli.prompts;
import sparkles.core_cli.term_caps : isTerminal, StdStream;

void main()
{
    // Interactive on a terminal; silently takes the defaults when piped
    // (which is how this example runs under CI).
    const policy = isTerminal(StdStream.stdin)
        ? PromptPolicy.interactive : PromptPolicy.takeDefault;
    auto io = stdioPromptIo();

    auto bump = select("Version bump:", [
        SelectOption("patch", "v0.5.0 → v0.5.1"),
        SelectOption("minor", "v0.5.0 → v0.6.0  (suggested)"),
        SelectOption("major", "v0.5.0 → v1.0.0"),
    ], 1, policy, io);
    auto go = confirm("Push to origin?", defaultYes: true, policy, io);
    writefln!"bump=%s push=%s"(bump.value + 1, go.value);
}
```

```[Output]
bump=2 push=true
```

### Logger

Delta-time-prefixed logging via `DeltaTimeLogger`, a `std.logger.Logger` subclass. Each log line shows wall-clock time, elapsed time since start, and delta since the previous entry.

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "readme_logger"
    dependency "sparkles:base" version="*"
+/

import std.logger : log, LogLevel;

import sparkles.base.logger : initLogger;

void main()
{
    initLogger(LogLevel.trace);

    log(LogLevel.info, "Listening on port 8080");
    log(LogLevel.warning, "Disk usage above 80%");
    log(LogLevel.error, "Connection to database lost");
}
```

<!-- md-example-expected
[ {{_}} | Δt {{_}} | Δtᵢ {{_}} | INF | {{_}} ]: Listening on port 8080
[ {{_}} | Δt {{_}} | Δtᵢ {{_}} | WRN | {{_}} ]: Disk usage above 80%
[ {{_}} | Δt {{_}} | Δtᵢ {{_}} | ERR | {{_}} ]: Connection to database lost
-->

```[Output]
[ 12:42:19 | Δt 128.5µs | Δtᵢ 128.5µs | INF | readme_logger.d:15 ]: Listening on port 8080
[ 12:42:19 | Δt 240.7µs | Δtᵢ 112.1µs | WRN | readme_logger.d:16 ]: Disk usage above 80%
[ 12:42:19 | Δt 280.7µs | Δtᵢ 40.0µs | ERR | readme_logger.d:17 ]: Connection to database lost
```

The colored output uses `writeStyled` IES for ANSI styling -- log levels are color-coded (green for info, yellow for warnings, red for errors, bold+red for critical/fatal), durations are highlighted, and file locations are dimmed.

### SmallBuffer

A `@nogc` dynamic array with small buffer optimization. Stores data inline up to a configurable threshold, then falls back to the heap via `pureMalloc`.

```d
import sparkles.base.smallbuffer;

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
import sparkles.base.lifetime;

@nogc void validate(int x) {
    if (x < 0)
        throw recycledInstance!Error("value must be non-negative");
}
```

**`text_writers`** -- Write integers, floats, escaped characters, and ANSI codes without GC allocation. Includes `writeValue` for best-effort `@nogc` conversion of any type, and `writeStyledValue` for hook-controlled styled output.

**`term_unstyle`** -- Strip ANSI escape sequences from styled text. This lives in
`sparkles:core-cli`.

**`term_caps`** -- Query the terminal size (`terminalSize`) and detect window resizes via `SIGWINCH`. This lives in
`sparkles:core-cli`.

### Test Runner

`sparkles:test-runner` runs a package's `unittest`s in parallel (add it to
`configuration "unittest"` and use `dub test` as usual), with marker
attributes that opt individual tests into extra environments: `@ctfe` tests
run while the build compiles (a failure is a compile error), `@betterC` and
`@wasm` tests are additionally extracted and executed without druntime /
on `wasm32` (`--better-c` / `--wasm`), and `@benchmark` tests are measured
with auto-scaling iteration counts (`--bench`). See the
[test-runner documentation](docs/libs/test-runner/index.md).

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "readme_test_runner"
    dependency "sparkles:test-runner" version="*"
+/
import sparkles.test_runner.attributes : benchmark, betterC, ctfe;
import sparkles.test_runner.bench : blackBox, computeStats;

@("digits.parity")
@betterC @safe pure nothrow @nogc
unittest // runs under `dub test` — and without druntime via `--better-c`
{
    int parity;
    foreach (c; "12345")
        parity ^= c - '0';
    assert(parity == 1);
}

@("digits.parity.ct")
@ctfe @safe pure nothrow @nogc
unittest // runs while the test build compiles; never at runtime
{
    assert((1 ^ 2 ^ 3 ^ 4 ^ 5) == 1);
}

void main()
{
    import std.stdio : writefln;

    // The statistics `--bench` reports, over hand-made ns/iter samples so
    // this example's output is deterministic:
    const stats = computeStats("demo", 1000, [22.0, 18.0, 20.0]);
    writefln!"median=%.0fns/iter min=%.0f max=%.0f over %s samples"(
        stats.nsPerIterMedian, stats.nsPerIterMin, stats.nsPerIterMax,
        stats.samples);

    // blackBox is the optimizer barrier used inside @benchmark tests.
    assert(blackBox(21) * 2 == 42);
}
```

```[Output]
median=20ns/iter min=18 max=22 over 3 samples
```

## Examples

Runnable examples are in [`libs/base/examples/`](libs/base/examples/) and
[`libs/core-cli/examples/`](libs/core-cli/examples/):

```bash
dub run --single libs/base/examples/logger.d
dub run --single libs/base/examples/prettyprint.d
dub run --single libs/base/examples/text-fields.d
dub run --single libs/base/examples/term-control.d

dub run --single libs/core-cli/examples/styled-template.d
dub run --single libs/core-cli/examples/table.d
dub run --single libs/core-cli/examples/box.d
dub run --single libs/core-cli/examples/header.d
dub run --single libs/core-cli/examples/osc-link.d
dub run --single libs/core-cli/examples/color.d
dub run --single libs/core-cli/examples/theme.d
dub run --single libs/core-cli/examples/meter.d
dub run --single libs/core-cli/examples/tree.d
dub run --single libs/core-cli/examples/layout.d
dub run --single libs/core-cli/examples/prompts.d       # interactive
dub run --single libs/core-cli/examples/live-tasklist.d # animated
dub run --single libs/core-cli/examples/term-caps.d
```

## Building & Testing

```bash
# Build
dub build :base
dub build :core-cli

# Run all tests
dub run :ci -- --test

# Test a specific sub-package
dub test :base
dub test :core-cli

# Run tests matching a pattern
dub test :base -- -i "SmallBuffer"

# Verbose output with stack traces
dub test :core-cli -- -v

# Special test-runner modes (see docs/libs/test-runner/)
dub test :base -- --bench       # measure @benchmark tests
dub test :base -- --better-c    # run @betterC tests without druntime
dub test :base -- --wasm        # run @wasm tests on wasm32
```

The project uses a **Nix development shell** for reproducible builds:

```bash
nix develop -c dub build :core-cli
nix run .#ci -- --test
```

## Documentation

Documentation (work in progress) is available at **[sparkles-docs.pages.dev](https://sparkles-docs.pages.dev/)**.

## License

[Boost Software License 1.0](LICENSE)
