# core-cli Package Overview

A D library providing utilities for building CLI applications with terminal styling, pretty-printing, UI components, and @nogc support.

## Table of Contents

- [Installation](#installation)
- [Terminal Styling](#terminal-styling)
- [Styled Templates (IES)](#styled-templates-ies)
- [Pretty Printing](#pretty-printing)
- [UI Components](#ui-components)
  - [Tables](#tables)
  - [Boxes](#boxes)
  - [Headers](#headers)
- [SmallBuffer (@nogc)](#smallbuffer-nogc)
- [Running Examples](#running-examples)

## Installation

Add `sparkles:core-cli` as a dependency:

::: code-group

```sdl [dub.sdl]
dependency "sparkles:core-cli" version="*"
```

```json [dub.json]
"dependencies": {
    "sparkles:core-cli": "*"
}
```

:::

## Terminal Styling

The `term_style` module provides ANSI terminal colors and text attributes.

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
    dependency "sparkles:core-cli" version="*"
+/
import std.stdio : writeln;
import sparkles.core_cli.term_style : Style, stylize;

void main()
{
    writeln("Error: ".stylize(Style.red) ~ "Something went wrong");
    writeln("Success: ".stylize(Style.green) ~ "Operation completed");
    writeln("Warning".stylize(Style.bold).stylize(Style.yellow));
}
```

### Compile-Time Builder

For CTFE-compatible styling, use `stylizedTextBuilder`:

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "builderdemo"
    dependency "sparkles:core-cli" version="*"
+/
import std.stdio : writeln;
import sparkles.core_cli.term_style : stylizedTextBuilder;

void main()
{
    // Chain multiple styles fluently
    enum styledText = "Important".stylizedTextBuilder.bold.underline.red;
    writeln(styledText);
}
```

## Styled Templates (IES)

The `styled_template` module provides a template syntax for applying terminal styles using D's Interpolated Expression Sequences (IES).

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "styledtemplatedemo"
    dependency "sparkles:core-cli" version="*"
+/
import sparkles.core_cli.styled_template;

void main()
{
    int cpu = 75;
    styledWriteln(i"CPU: {red $(cpu)%} Status: {green OK}");
}
```

### Syntax Reference

::: v-pre

| Syntax                     | Description                          |
| -------------------------- | ------------------------------------ |
| `{red text}`               | Apply single style                   |
| `{bold.red text}`          | Chain multiple styles                |
| `{bold outer {red inner}}` | Nested blocks (inner inherits outer) |
| `{red text {~red normal}}` | Negation with `~` removes a style    |
| `{{`                       | Escaped literal `{`                  |
| `}}`                       | Escaped literal `}`                  |

:::

### Available Functions

| Function                      | Description                                  |
| ----------------------------- | -------------------------------------------- |
| `styledText(i"...")`          | Returns styled string                        |
| `styledWriteln(i"...")`       | Writes to stdout with newline                |
| `styledWrite(i"...")`         | Writes to stdout without newline             |
| `styled(i"...")`              | Returns lazy wrapper for deferred processing |
| `writeStyled(writer, i"...")` | Writes to any output range                   |

### More Examples

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "styledexamples"
    dependency "sparkles:core-cli" version="*"
+/
import sparkles.core_cli.styled_template;

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
    styledWriteln(i"Use {{style text}} syntax");
}
```

## Pretty Printing

The `prettyprint` module formats any D type with syntax highlighting.

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "prettyprintdemo"
    dependency "sparkles:core-cli" version="*"
+/
import std.stdio : writeln;
import sparkles.core_cli.prettyprint : prettyPrint, PrettyPrintOptions;

struct Server { string host; int port; bool ssl; }

void main()
{
    auto server = Server("localhost", 8080, true);
    writeln(prettyPrint(server));

    // Custom options
    int[] numbers = [1, 2, 3, 4, 5];
    writeln(prettyPrint(numbers, PrettyPrintOptions(useColors: false)));
}
```

### PrettyPrintOptions

| Option         | Default | Description                                            |
| -------------- | ------- | ------------------------------------------------------ |
| `indentStep`   | 2       | Spaces per indent level                                |
| `maxDepth`     | 8       | Maximum recursion depth                                |
| `maxItems`     | 32      | Max items shown for arrays/AAs                         |
| `softMaxWidth` | 80      | Try single-line if output fits (0 = always multi-line) |
| `useColors`    | true    | Enable ANSI colors                                     |

## UI Components

### Tables

Render data as ASCII tables with Unicode box-drawing characters.

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "tabledemo"
    dependency "sparkles:core-cli" version="*"
+/
import std.stdio : writeln;
import sparkles.core_cli.ui.table : drawTable;
import sparkles.core_cli.term_style : Style, stylize;

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

Output:

```text
╭────────┬─────────╮
│ Name   │ Status  │
├────────┼─────────┤
│ web-01 │ Running │
│ web-02 │ Stopped │
╰────────┴─────────╯
```

### Boxes

Draw bordered boxes around content with optional titles.

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

Output:

```text
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

Output:

```text
╭──╼ Status ╾──────────────╮
│ Processing...            │
╰──╼ Press Q to cancel ╾───╯
```

### Headers

Create section dividers and banners.

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

Output:

```text
── Configuration ──

══════════════════════════════
         Main Section
══════════════════════════════
```

## SmallBuffer (@nogc)

A `@nogc` container with Small Buffer Optimization (SBO). Stores small data inline, automatically switches to heap when capacity is exceeded.

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "smallbufferdemo"
    dependency "sparkles:core-cli" version="*"
+/
import std.stdio : writeln;
import sparkles.core_cli.smallbuffer : SmallBuffer;

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

### Key Features

- **@nogc @safe**: No garbage collector allocations in hot paths
- **Output range**: Works with `std.algorithm` and other range-based APIs
- **Automatic growth**: Switches to heap allocation when needed
- **Slicing**: Access elements via `buf[]` or `buf[start..end]`

## Running Examples

Examples in `libs/core-cli/examples/` are standalone runnable files:

```bash
# Run directly with dub
dub run --single libs/core-cli/examples/prettyprint.d

# Or make executable and run
chmod +x libs/core-cli/examples/color.d
./libs/core-cli/examples/color.d
```

Available examples:

- `color.d` - Style and color palette showcase
- `prettyprint.d` - Type formatting demonstration
- `styled_template.d` - IES-based template styling
- `table.d` - Table rendering variations
- `box.d` - Box layouts with nested content
- `header.d` - Header styles
