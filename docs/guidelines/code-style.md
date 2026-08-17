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

See [DDoc](ddoc.md) for documentation comment syntax and conventions.

### Imports

Group imports in this order, separated by a single empty line between groups:

1. `core.*` modules (DRuntime)
2. `std.*` modules (Phobos)
3. External dependencies
4. Modules from other sub-packages of this project
5. Modules from the same sub-package

```d
import core.memory : pureMalloc, pureFree;

import std.range.primitives : put, empty, front, popFront;
import std.traits : isSomeChar, isSomeString, isNumeric;

import sparkles.base.term_style : Style, stylize;
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

## Expression-Based Contracts ([DIP1009](https://github.com/dlang/DIPs/blob/90490da522d8209c7940071a4a58c5b4d7e8938e/DIPs/accepted/DIP1009.md))

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

## Expression-Based Functions ([DIP1043](https://github.com/dlang/DIPs/blob/90490da522d8209c7940071a4a58c5b4d7e8938e/DIPs/accepted/DIP1043.md))

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

## Copy Constructors ([DIP1018](https://github.com/dlang/DIPs/blob/90490da522d8209c7940071a4a58c5b4d7e8938e/DIPs/accepted/DIP1018.md))

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

## Named Arguments ([DIP1030](https://github.com/dlang/DIPs/blob/90490da522d8209c7940071a4a58c5b4d7e8938e/DIPs/accepted/DIP1030.md))

Use named arguments for clarity at call sites:

```d
auto result = createWidget(
    width: 100,
    height: 200,
    visible: true,
    resizable: false,
);
```

### Forcing Named Arguments

Force external callers to use named arguments by adding a `private`-typed
sentinel with a default value as the first parameter. Callers outside the
module cannot construct the private type, so positional calls fail at compile
time while named calls skip past the sentinel via its default:

```d
private struct NamedOnly {}

void draw(NamedOnly _ = NamedOnly.init, int x = 0, int y = 0, int width = 0, int height = 0)
{
    // ...
}

// From another module:
draw(x: 10, y: 20, width: 100, height: 200); // ✅
draw(10, 20, 100, 200);                       // ❌ compile error
```

The same technique applies to struct fields. For the function-parameter
variant the sentinel is zero-cost — it produces identical assembly to a plain
function. See [Forcing Named Arguments](idioms/forced-named-arguments/) for
the full write-up including ABI analysis, struct caveats, and alternative
techniques that were evaluated.

### Expected Error Handling

To support `@nogc nothrow` code paths, the project uses the [`github:tchaloupka/expected`][expected] library. This allows functions to return either a valid payload or a structured error, without allocating on the garbage collected heap.

See [Expected Error Handling](idioms/expected/) for comprehensive guidelines on how to chain, transform, and flatten `Expected` values, with handy comparisons for developers coming from Rust.

## Multi-Line and Embedded Literals

When a literal holds a _block_ — a test fixture, a sample program, a shader, a
query, a golden file — use a delimited form rather than a chain of quoted
lines. `"line one\n" ~ "line two\n"` hides its structure, and a dropped `\n`
in the middle of such a chain is silent: nothing fails, the content is just
subtly wrong.

### D code → token strings (`q{…}`)

```d
enum sample = q{
int add(int a, int b)
{
    return a + b;
}
};
```

The payoff is that the compiler **lexes** the contents. A stray character, an
unbalanced brace or an unterminated literal is a build error rather than a
fixture that quietly describes something other than what you meant:

```
Error: unterminated token string constant
```

It is a real lex, not a brace scan, so a `}` inside a string, a comment or a
character literal does not close the token string:

```d
enum tricky = q{
void f()
{
    auto closing = "}";   // does not end the literal
}
};
```

**The newline after `q{` is part of the string** — which matters whenever the
content's line numbers do. Don't strip it by hand; see
[Dedenting](#dedenting) below.

### Everything else → delimited strings (`q"IDENT … IDENT"`)

For content that is _not_ D — `q{…}` would try to lex it — use the
[identifier-delimited](https://dlang.org/spec/lex#delimited_strings) form,
naming the delimiter after the language or format:

```d
enum script = q"JS
export function add(a, b) {
    return a + b;
}
JS";
```

The text is taken verbatim, so there are no escapes to get wrong. Two rules:

- The newline **after** the opening identifier is not part of the string; the
  one **before** the closing identifier is. The literal is therefore
  byte-for-byte what a file would contain — which matters when something
  addresses that content by byte offset.
- The closing identifier must **start a line**. It cannot be indented to match
  the surrounding code; an indented one is a compile error.

For content with backslashes but no backticks (JSON, regexes), a wysiwyg
backtick string is equally good and needs no delimiter:

```d
enum payload = `{"path":"C:\\tmp","re":"\d+"}`;
```

### Dedenting

A block written at its natural indentation reads better than one dropped to
column 0 mid-function, so write it where it belongs and strip the indentation
at use. `outdent` from `sparkles.test_utils.string` does that, and folds in
the leading-newline problem above:

```d
import sparkles.test_utils.string : outdent;

void f()
{
    enum sample = q{
        int add(int a, int b)
        {
            return a + b;
        }
}.outdent(2);   // two levels deep; closing brace flush left — see below
}
```

Three things to get right:

- **The level count must match the literal's own depth.** It is not inferred,
  and getting it wrong scrambles the block rather than shifting it: the strip
  is a prefix match, so a line indented at least that deep loses exactly that
  prefix while a shallower one is left untouched. Passing `3` above yields
  `return a + b;` at column 0 with its enclosing braces still at 8. Nothing
  fails — you just get a different fixture.
- **Put the token string's closing `}` at column 0.** Aligning it with the
  block leaves that line's indentation in the literal, and it is the one line
  `outdent` cannot strip (there is no newline after it), so the result ends in
  four stray spaces. Ugly in the source, correct in the bytes.
- **A heredoc's closing identifier must be flush left anyway**, so the same
  shape applies there — the body indents, the terminator does not.

For a literal already at column 0, pass `0`: that skips the indent work and
leaves only the leading-newline strip.

It is CTFE-clean, so `enum` and module-level `immutable` fixtures work.

Phobos has `std.string.outdent`, which infers the common indentation instead of
taking a level count — convenient, but it leaves a token string's leading
newline in place, so prefer the in-repo one for `q{}`. Note that
`sparkles:test-utils` is a test-scope dependency; reach for the Phobos one in
shipping code.

### The indentation constraint

`editorconfig-checker` sees the file's lines, not D's parse, so **a delimited
literal's body is checked like any other code**: every line's indentation must
be a multiple of 4. Dedenting does not buy you out of this — the check runs on
what is written, not on what the literal evaluates to. Since the block's own
depth is already a multiple of 4, the content's _internal_ indentation has to
be one independently. Re-indent embedded source to 4 spaces, which is valid in
essentially every language; 2-space JavaScript fails the hook at either depth:

```
Wrong amount of left-padding spaces(want multiple of 4)
```

Where the leading whitespace is **payload at a width you do not control**, no
depth satisfies the rule and you should keep the quoted form. A DMD `.lst`
counter column is 7 characters wide and a `gcov` one is 9; neither is
negotiable, because the width is the format. In the listing below the lines
carry 6 and 0 spaces of payload, so shifting the whole block by `n` would need
`n ≡ 2` and `n ≡ 0 (mod 4)` at once:

```d
// Correct as-is: the spaces are inside the quotes, on a properly indented line
enum listing = "      5|    return a + b;\n"
    ~ "0000000|    return a * 2;\n"
    ~ "src/math.d is 50% covered\n";
```

`apps/hue/tools/gen-coverage-fixtures.d` uses all three forms side by side —
a token string for its D sample, a delimited string for its JavaScript one,
and quoted concatenation for the fixed-column artifacts it emits.

## Interpolated Expression Sequences ([DIP1036](https://github.com/dlang/DIPs/blob/90490da522d8209c7940071a4a58c5b4d7e8938e/DIPs/other/DIP1036.md))

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

[expected]: https://github.com/tchaloupka/expected
