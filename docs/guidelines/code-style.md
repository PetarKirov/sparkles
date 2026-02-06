# D Code Style Guide

Follow the [official DStyle](https://dlang.org/dstyle.html) (local copy: [dstyle.md](dstyle.md)). Key points:

- **Whitespace:** 4-space indentation, one statement per line
- **Braces:** Own line for functions and type definitions
- **Naming:** `camelCase` for constants/enum members/variables/functions/UDAs, `PascalCase` for types, `snake_case` for modules, if a name would conflict with a keyword append `_`, e.g., `class_`, all letters in acronyms should have the same case, e.g., `xmlLoad`, `parseXML`

## Module Layout

Organize D modules in this order:

1. **Module-level Ddoc** - Documentation for the entire module
2. **Module declaration** - `module sparkles.core_cli.example;`
3. **Imports** - Grouped as described below
4. **Ddoc-ed module-level unit tests** - Usage examples for the module as a whole
5. **Public API** - Most important user-facing items first (public aliases, types, functions)
6. **Implementation details** - Private aliases, types, functions
7. **Non-Ddoc module-level unit tests** - Integration tests using multiple module members

Unit tests for a specific function or type should follow that declaration directly.

### Imports

Group imports in this order:

1. `core.*` modules (DRuntime)
2. `std.*` modules (Phobos)
3. External dependencies
4. Modules from other sub-packages of this project
5. Modules from the same sub-package

```d
import core.memory : pureMalloc, pureFree;

import std.range.primitives : put, empty, front, popFront;
import std.traits : isSomeChar, isSomeString, isNumeric;

import sparkles.core_cli.term_style : Style, stylize;
```

#### Import Best Practices

- **Always use selective imports** - Import only the symbols you need, not entire modules
- **Prefer local (scoped) imports** - Use function-level or type-level imports for clarity, similar to how variables should have the smallest possible scope. Bonus: templates with scoped imports that are never instantiated won't trigger the import
- **Use renamed imports** to avoid name clashes or improve clarity:

```d
import std.file : writeFile = write;  // Avoid clash with std.stdio.write
```

## Eponymous Templates

Use short eponymous template syntax:

```d
// Good
enum isSpecial(T) = is(T == int) || is(T == long);

// Avoid
template isSpecial(T)
{
    enum isSpecial = is(T == int) || is(T == long);
}
```

## Expression-Based Contracts ([DIP1009](https://github.com/dlang/DIPs/blob/master/DIPs/accepted/DIP1009.md))

```d
// Good
int divide(int a, int b)
in (b != 0)
out (r; r * b == a)
{
    return a / b;
}

// Avoid
int divide(int a, int b)
in
{
    assert(b != 0);
}
out (r)
{
    assert(r * b == a);
}
do
{
    return a / b;
}
```

## Expression-Based Functions ([DIP1043](https://github.com/dlang/DIPs/blob/master/DIPs/accepted/DIP1043.md))

For simple functions, use `=>` syntax:

```d
// Good
int square(int x) => x * x;

// Avoid
int square(int x)
{
    return x * x;
}
```

## Static Foreach

Use `static foreach` over tuples and `AliasSeq`:

```d
// Good
static foreach (T; AliasSeq!(int, long, float))
{
    pragma(msg, T.stringof);
}

// Avoid
foreach (T; AliasSeq!(int, long, float))
{
    pragma(msg, T.stringof);
}
```

## Copy Constructors ([DIP1018](https://github.com/dlang/DIPs/blob/master/DIPs/accepted/DIP1018.md))

Use copy constructors instead of postblit:

```d
struct S
{
    int* ptr;

    // Good
    this(ref return scope const S another)
    {
        ptr = new int(*another.ptr);
    }

    // Avoid
    // this(this) { ptr = new int(*ptr); }
}
```

## Input Parameters

Use `in` for read-only parameters (implies `const scope`):

```d
// Good
void process(in Config config) { ... }

// Avoid
void process(const ref Config config) { ... }
```

Note: `in` may be omitted for primitive types and `immutable(T)[]` slices (e.g., `string`).

## Named Arguments ([DIP1030](https://github.com/dlang/DIPs/blob/master/DIPs/accepted/DIP1030.md))

Use named arguments for clarity at call sites:

```d
auto result = createWidget(
    width: 100,
    height: 200,
    visible: true,
    resizable: false,
);
```

## Interpolated Expression Sequences ([DIP1036](https://github.com/dlang/DIPs/blob/master/DIPs/other/DIP1036.md))

Use IES (`i"..."`) when interspersing string literals with expressions. Preference order:

1. **IES** — Type-safe, enables context-aware encoding
2. **`std.format`** — When format specifiers are needed (`%08x`, `%.2f`)
3. **Manual concatenation** — Avoid

```d
import std.conv : text;
import std.stdio : writeln;

string name = "Alice";
int count = 42;

// Good: IES with writeln (no allocation)
writeln(i"Hello, $(name)! Count: $(count)");

// Good: IES converted to string
string msg = i"Hello, $(name)! Count: $(count)".text;

// Good: std.format when format specifiers needed
import std.format : format;
string hex = format!"Value: 0x%08X"(count);

// Avoid: manual concatenation
string bad = "Hello, " ~ name ~ "! Count: " ~ count.to!string;
```

**Key rules:**

- IES produces a tuple, not a string — use `.text` or pass to IES-accepting functions
- Prefer `writeln(i"...")` over `writeln(i"...".text)` to avoid allocation
- For security-sensitive contexts (SQL, HTML, URLs), use dedicated IES-processing functions that escape interpolated values

See [Interpolated Expression Sequences](interpolated-expression-sequences.md) for complete patterns including safe SQL queries, HTML templates, and structured logging.
