# Sparkles Package Overview

Sparkles is a D monorepo for CLI applications and supporting libraries.
`sparkles:base` provides allocation-conscious foundation modules; `sparkles:core-cli`
builds on it with pretty-printing, UI components, CLI helpers, and process utilities.

## Table of Contents

- [Installation](#installation)
- [Terminal Styling](#terminal-styling)
- [Styled Templates (IES)](#styled-templates-ies)
- [Pretty Printing](#pretty-printing)
- [UI Components](#ui-components)
  - [Tables](#tables)
  - [Boxes](#boxes)
  - [Headers](#headers)
  - [OSC 8 Hyperlinks](#osc-8-hyperlinks)
- [Logger](#logger)
- [SmallBuffer (@nogc)](#smallbuffer-nogc)
- [Running Examples](#running-examples)

## Installation

Add the package you need as a dependency. Use `sparkles:base` for styling,
logging, `SmallBuffer`, lifetime helpers, and text readers/writers. Use
`sparkles:core-cli` when you also need pretty-printing, UI components, CLI
argument parsing, or process utilities.

::: code-group

```sdl [dub.sdl]
dependency "sparkles:base" version="*"
dependency "sparkles:core-cli" version="*"
```

```json [dub.json]
"dependencies": {
    "sparkles:base": "*",
    "sparkles:core-cli": "*"
}
```

:::

## Terminal Styling

The `term_style` module provides ANSI terminal colors and text attributes.

- **Source Code**: [`term_style.d`](../libs/core-cli/src/sparkles/core_cli/term_style.d)
- **Example**: [`color.d`](../libs/core-cli/examples/color.d)

### Style Enum

Available styles include:

- **Colors**: `red`, `green`, `yellow`, `blue`, `magenta`, `cyan`, `white`, `gray`
- **Bright colors**: `brightRed`, `brightGreen`, `brightYellow`, etc.
- **Background**: `bgRed`, `bgGreen`, `bgBlue`, etc.
- **Attributes**: `bold`, `dim`, `italic`, `underline`, `strikethrough`, `inverse`

### Basic Usage

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "styledemo"
    dependency "sparkles:base" version="*"
+/
import std.stdio : writeln;
import sparkles.base.term_style : Style, stylize;

void main()
{
    writeln("Error: ".stylize(Style.red) ~ "Something went wrong");
    writeln("Success: ".stylize(Style.green) ~ "Operation completed");
    writeln("Warning".stylize(Style.bold).stylize(Style.yellow));
}
```

```ansi
[31mError: [39mSomething went wrong
[32mSuccess: [39mOperation completed
[33m[1mWarning[22m[39m
```

### Compile-Time Builder

For CTFE-compatible styling, use `stylizedTextBuilder`:

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "builderdemo"
    dependency "sparkles:base" version="*"
+/
import std.stdio : writeln;
import sparkles.base.term_style : stylizedTextBuilder;

void main()
{
    // Chain multiple styles fluently
    enum styledText = "Important".stylizedTextBuilder.bold.underline.red;
    writeln(styledText);
}
```

```ansi
[31m[4m[1mImportant[22m[24m[39m
```

## Styled Templates (IES)

The `styled_template` module provides a template syntax for applying terminal styles using D's Interpolated Expression Sequences (IES).

- **Source Code**: [`styled_template.d`](../libs/core-cli/src/sparkles/core_cli/styled_template.d)
- **Example**: [`styled-template.d`](../libs/core-cli/examples/styled-template.d)

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "styledtemplatedemo"
    dependency "sparkles:base" version="*"
+/
import sparkles.base.styled_template;

void main()
{
    int cpu = 75;
    styledWriteln(i"CPU: {red $(cpu)%} Status: {green OK}");
}
```

```ansi
CPU: [31m75%[39m Status: [32mOK[39m
```

### Syntax Reference

::: v-pre

| Syntax                     | Description                          |
| -------------------------- | ------------------------------------ |
| `{red text}`               | Apply single style                   |
| `{bold.red text}`          | Chain multiple styles                |
| `{bold outer {red inner}}` | Nested blocks (inner inherits outer) |
| `{red text {~red normal}}` | Negation with `~` removes a style    |
| `#{`                       | Escaped literal `{`                  |
| `#}`                       | Escaped literal `}`                  |

:::

### Available Functions

| Function                      | Description                                  |
| ----------------------------- | -------------------------------------------- |
| `styledText(i"...")`          | Returns styled string                        |
| `styledWriteln(i"...")`       | Writes to stdout with newline                |
| `styledWrite(i"...")`         | Writes to stdout without newline             |
| `styledWritelnErr(i"...")`    | Writes to stderr with newline                |
| `styledWriteErr(i"...")`      | Writes to stderr without newline             |
| `styled(i"...")`              | Returns lazy wrapper for deferred processing |
| `writeStyled(writer, i"...")` | Writes to any output range                   |

### More Examples

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "styledexamples"
    dependency "sparkles:base" version="*"
+/
import sparkles.base.styled_template;

void main()
{
    // Chained styles
    styledWriteln(i"{bold.italic.green Bold italic green text}");

    // Nested with inheritance
    styledWriteln(i"{bold Bold {red bold+red} back to bold}");

    // Style negation
    styledWriteln(i"{bold.red Both {~red just bold} both again}");

    // Practical usage
    string file = "main.d";
    int errors = 3;
    styledWriteln(i"{dim $(file):} {red.bold $(errors) errors}");

    // Escaped braces for literals
    styledWriteln(i"Use #{style text#} syntax");
}
```

```ansi
[1m[3m[32mBold italic green text[39m[23m[22m
[1mBold [31mbold+red[39m back to bold[22m
[1m[31mBoth [39mjust bold[31m both again[39m[22m
[2mmain.d:[22m [31m[1m3 errors[22m[39m
Use {style text} syntax
```

## Pretty Printing

The `prettyprint` module formats any D type with syntax highlighting.

- **Source Code**: [`prettyprint.d`](../libs/core-cli/src/sparkles/core_cli/prettyprint.d)
- **Example**: [`prettyprint.d`](../libs/core-cli/examples/prettyprint.d)

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "prettyprintdemo"
    dependency "sparkles:base" version="*"
+/
import std.stdio : writeln;
import sparkles.base.prettyprint : prettyPrint, PrettyPrintOptions;

struct Server { string host; int port; bool ssl; }

void main()
{
    auto server = Server("localhost", 8080, true);
    writeln(prettyPrint(server));

    // Custom options
    int[] numbers = [1, 2, 3, 4, 5];
    writeln(prettyPrint(numbers, PrettyPrintOptions!void(useColors: false)));
}
```

```ansi
[35mServer[39m([96mhost[39m: [32m"localhost"[39m, [96mport[39m: [34m8080[39m, [96mssl[39m: [33mtrue[39m)
[1, 2, 3, 4, 5]
```

### PrettyPrintOptions

`PrettyPrintOptions` is a struct template parameterized on `SourceUriHook`:

```d
PrettyPrintOptions!void(...)              // default: file:// URIs
PrettyPrintOptions!(SchemeHook!"code")    // VS Code URIs
PrettyPrintOptions!EditorDetectHook       // auto-detect from $EDITOR/$VISUAL
```

| Option         | Default | Description                                            |
| -------------- | ------- | ------------------------------------------------------ |
| `indentStep`   | 2       | Spaces per indent level                                |
| `maxDepth`     | 8       | Maximum recursion depth                                |
| `maxItems`     | 32      | Max items shown for arrays/AAs                         |
| `softMaxWidth` | 80      | Try single-line if output fits (0 = always multi-line) |
| `useColors`    | true    | Enable ANSI colors                                     |
| `useOscLinks`  | false   | Wrap type names in OSC 8 hyperlinks to source location |

#### Source URI Hooks

The `SourceUriHook` template parameter controls the URI scheme for OSC 8 hyperlinks on type names. Available hooks from `sparkles.base.source_uri`:

| Hook                  | Description                                      |
| --------------------- | ------------------------------------------------ |
| `void` (default)      | `file://` URIs with absolute paths               |
| `SchemeHook!"code"`   | VS Code (`vscode://`) URIs                       |
| `SchemeHook!"cursor"` | Cursor editor URIs                               |
| `SchemeHook!"idea"`   | JetBrains IDE URIs                               |
| `SchemeHook!"subl"`   | Sublime Text URIs                                |
| `EditorDetectHook`    | Auto-detects from `$VISUAL`/`$EDITOR` at runtime |

Custom hooks implement `static void writeSourceUri(string path, size_t line, size_t col, Writer)(ref Writer w)` — source location is passed as template parameters for CTFE evaluation.

## UI Components

### Tables

Render data as ASCII tables with Unicode box-drawing characters.

- **Source Code**: [`table.d`](../libs/core-cli/src/sparkles/core_cli/ui/table.d)
- **Example**: [`table.d`](../libs/core-cli/examples/table.d)

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "tabledemo"
    dependency "sparkles:core-cli" version="*"
+/
import std.stdio : writeln;
import sparkles.core_cli.ui.table : drawTable;
import sparkles.base.term_style : Style, stylize;

void main()
{
    string[][] data = [
        ["Name".stylize(Style.bold), "Status".stylize(Style.bold)],
        ["web-01", "Running".stylize(Style.green)],
        ["web-02", "Stopped".stylize(Style.red)],
    ];
    writeln(drawTable(data));
}
```

```ansi
╭────────┬─────────╮
│ [1mName[22m   │ [1mStatus[22m  │
│ web-01 │ [32mRunning[39m │
│ web-02 │ [31mStopped[39m │
╰────────┴─────────╯
```

### Boxes

Draw bordered boxes around content with optional titles.

- **Source Code**: [`box.d`](../libs/core-cli/src/sparkles/core_cli/ui/box.d)
- **Example**: [`box.d`](../libs/core-cli/examples/box.d)

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "boxdemo"
    dependency "sparkles:core-cli" version="*"
+/
import std.stdio : writeln;
import sparkles.core_cli.ui.box : drawBox;

void main()
{
    writeln(["Line 1", "Line 2", "Line 3"].drawBox("My Box"));
}
```

```ansi
╭──╼ My Box ╾───╮
│ Line 1        │
│ Line 2        │
│ Line 3        │
╰───────────────╯
```

#### Box with Footer

Use `BoxProps` to add a footer to boxes:

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "boxfooterdemo"
    dependency "sparkles:core-cli" version="*"
+/
import std.stdio : writeln;
import sparkles.core_cli.ui.box : drawBox, BoxProps;

void main()
{
    writeln(["Processing..."].drawBox("Status", BoxProps(footer: "Press Q to cancel")));
}
```

```ansi
╭──╼ Status ╾──────────────╮
│ Processing...            │
╰──╼ Press Q to cancel ╾───╯
```

### Headers

Create section dividers and banners.

- **Source Code**: [`header.d`](../libs/core-cli/src/sparkles/core_cli/ui/header.d)
- **Example**: [`header.d`](../libs/core-cli/examples/header.d)

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "headerdemo"
    dependency "sparkles:core-cli" version="*"
+/
import std.stdio : writeln;
import sparkles.core_cli.ui.header : drawHeader, HeaderProps, HeaderStyle;

void main()
{
    // Divider style (default)
    writeln("Configuration".drawHeader);

    // Banner style
    writeln("Main Section".drawHeader(HeaderProps(
        style: HeaderStyle.banner,
        width: 30
    )));
}
```

```ansi
── Configuration ──
══════════════════════════════
         Main Section
══════════════════════════════
```

### OSC 8 Hyperlinks

Make text clickable in terminal emulators that support [OSC 8](https://gist.github.com/egmontkob/eb114294efbcd5adb1944c9f3cb5feda).

- **Source Code**: [`osc_link.d`](../libs/core-cli/src/sparkles/core_cli/ui/osc_link.d)
- **Example**: [`osc-link.d`](../libs/core-cli/examples/osc-link.d)

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "osclinkdemo"
    dependency "sparkles:core-cli" version="*"
+/
import std.stdio : writeln;
import sparkles.core_cli.ui.osc_link : oscLink;
import sparkles.base.term_style : Style;

void main()
{
    // Plain clickable link
    writeln(oscLink(text: "Example", uri: "https://example.com"));

    // Styled clickable link (blue text)
    writeln(oscLink(text: "D Language", uri: "https://dlang.org", style: Style.blue));
}
```

```ansi
]8;;https://example.comExample]8;;
]8;;https://dlang.org[34mD Language[39m]8;;
```

#### API

| Function                     | Description                       |
| ---------------------------- | --------------------------------- |
| `oscLink(text, uri)`         | Wrap text in an OSC 8 hyperlink   |
| `oscLink(text, uri, style)`  | Wrap styled text in an OSC 8 link |
| `oscLinkOpenSeq(uri, props)` | Opening escape sequence only      |
| `oscLinkCloseSeq(props)`     | Closing escape sequence only      |

Configure via `OscLinkProps`:

| Field        | Default             | Description                   |
| ------------ | ------------------- | ----------------------------- |
| `terminator` | `OscTerminator.bel` | BEL (`\x07`) or ST (`\x1b\\`) |
| `id`         | `null`              | Optional link id for grouping |

## Logger

The `sparkles.base.logger` module provides `CoreLogger`, a `std.logger.Logger`
base class with a Sparkles `@safe nothrow @nogc` logging path, plus
`DeltaTimeLogger`, a stderr logger that prints wall-clock time, elapsed time
since start, and elapsed time since the previous log entry.

- **Source Code**: [`logger.d`](../libs/core-cli/src/sparkles/core_cli/logger.d)
- **Example**: [`logger.d`](../libs/core-cli/examples/logger.d)

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "loggerdemo"
    dependency "sparkles:base" version="*"
+/
import std.logger : log, logf, LogLevel;
import sparkles.base.logger : initLogger;

void main()
{
    initLogger(LogLevel.trace);

    log(LogLevel.info, "Listening on port 8080");
    log(LogLevel.warning, "Disk usage above 80%");
    log(LogLevel.error, "Connection to database lost");
    log(LogLevel.critical, "Out of memory");

    immutable host = "db-01.prod";
    logf(LogLevel.info, "Reconnected to %s:%d", host, 5432);
}
```

<!-- md-example-expected
[ {{_}} | Δt {{_}} | Δtᵢ {{_}} | INF | loggerdemo.d:13 ]: Listening on port 8080
[ {{_}} | Δt {{_}} | Δtᵢ {{_}} | WRN | loggerdemo.d:14 ]: Disk usage above 80%
[ {{_}} | Δt {{_}} | Δtᵢ {{_}} | ERR | loggerdemo.d:15 ]: Connection to database lost
[ {{_}} | Δt {{_}} | Δtᵢ {{_}} | CRT | loggerdemo.d:16 ]: Out of memory
[ {{_}} | Δt {{_}} | Δtᵢ {{_}} | INF | loggerdemo.d:19 ]: Reconnected to db-01.prod:5432
-->

```ansi
[90m[ 22:24:12[39m | Δt [33m92.8µs[39m | Δtᵢ [33m92.8µs[39m | [32mINF[39m | [2mloggerdemo.d:13[22m ]: [1mListening on port 8080[22m
[90m[ 22:24:12[39m | Δt [33m185.2µs[39m | Δtᵢ [33m92.4µs[39m | [33mWRN[39m | [2mloggerdemo.d:14[22m ]: [1mDisk usage above 80%[22m
[90m[ 22:24:12[39m | Δt [33m225.5µs[39m | Δtᵢ [33m40.3µs[39m | [31mERR[39m | [2mloggerdemo.d:15[22m ]: [1mConnection to database lost[22m
[90m[ 22:24:12[39m | Δt [33m266.7µs[39m | Δtᵢ [33m41.1µs[39m | [1m[31mCRT[39m[22m | [2mloggerdemo.d:16[22m ]: [1mOut of memory[22m
[90m[ 22:24:12[39m | Δt [33m338.0µs[39m | Δtᵢ [33m71.3µs[39m | [32mINF[39m | [2mloggerdemo.d:19[22m ]: [1mReconnected to db-01.prod:5432[22m
```

### Features

- **Delta timestamps**: Each line shows `Δt` (total elapsed) and `Δtᵢ` (since previous entry) for quick performance profiling
- **Colored output**: Log levels are color-coded (green=info, yellow=warn, red=error, bold+red=critical/fatal) using `writeStyled` IES
- **Thread-safe**: Uses `core.atomic` for delta tracking, safe as a `shared` global logger
- **Human-friendly durations**: Automatically scales to ms, s, m, h, or d with one decimal place

### API

| Function / type       | Description                                                     |
| --------------------- | --------------------------------------------------------------- |
| `CoreLogger`          | `std.logger.Logger` base class with a Sparkles `@nogc` log path |
| `sharedCoreLog`       | Atomic process-wide Sparkles logger                             |
| `coreGlobalLogLevel`  | Atomic process-wide Sparkles log-level filter                   |
| `initLogger(level)`   | Install `DeltaTimeLogger` for both Phobos and Sparkles globals  |
| `writeLogPrefix(...)` | Write prefix to an output range (zero-allocation)               |

## SmallBuffer (@nogc)

A `@nogc` container with Small Buffer Optimization (SBO). Stores small data inline, automatically switches to heap when capacity is exceeded.

- **Source Code**: [`smallbuffer.d`](../libs/core-cli/src/sparkles/core_cli/smallbuffer.d)

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "smallbufferdemo"
    dependency "sparkles:base" version="*"
+/
import std.stdio : writeln;
import sparkles.base.smallbuffer : SmallBuffer;

void main()
{
    // 64 chars inline, heap if exceeded
    SmallBuffer!(char, 64) buf;

    buf ~= "Hello";
    buf ~= ' ';
    buf ~= "World";

    writeln(buf[]);  // "Hello World"
    writeln("On heap: ", buf.onHeap);  // false
}
```

```ansi
Hello World
On heap: false
```

### Key Features

- **@nogc @safe**: No garbage collector allocations in hot paths
- **Output range**: Works with `std.algorithm` and other range-based APIs
- **Automatic growth**: Switches to heap allocation when needed
- **Slicing**: Access elements via `buf[]` or `buf[start..end]`

## Running Examples

Examples in [`libs/base/examples/`](../libs/base/examples/) and [`libs/core-cli/examples/`](../libs/core-cli/examples/) are standalone runnable files:

```bash
# Run directly with dub
dub run --single libs/base/examples/logger.d
dub run --single libs/base/examples/prettyprint.d

# Or make executable and run
chmod +x libs/core-cli/examples/color.d
./libs/core-cli/examples/color.d
```

Available examples:

- [`color.d`](../libs/core-cli/examples/color.d) - Style and color palette showcase
- [`logger.d`](../libs/base/examples/logger.d) - Delta-time-prefixed logging
- [`prettyprint.d`](../libs/base/examples/prettyprint.d) - Type formatting demonstration
- [`styled-template.d`](../libs/core-cli/examples/styled-template.d) - IES-based template styling
- [`table.d`](../libs/core-cli/examples/table.d) - Table rendering variations
- [`box.d`](../libs/core-cli/examples/box.d) - Box layouts with nested content
- [`header.d`](../libs/core-cli/examples/header.d) - Header styles
- [`osc-link.d`](../libs/core-cli/examples/osc-link.d) - OSC 8 terminal hyperlinks
