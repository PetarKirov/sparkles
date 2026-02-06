# D Developer Guidelines: Interpolated Expression Sequences (IES)

## Overview

Interpolated expression sequences (IES) embed D expressions directly in string literals using `$(expr)` syntax. Unlike simple string interpolation in other languages, D's IES preserves **metadata** about each component—literal text segments and expression source code—enabling context-aware processing at compile time.

Key benefits:

- **Type safety** — Functions receive actual typed values, not stringified text
- **Metadata preservation** — Libraries can distinguish literals from dynamic values
- **Context-aware encoding** — Apply URL encoding, HTML escaping, or SQL parameterization based on context
- **Compile-time validation** — Validate structure (HTML tags, SQL syntax) before runtime
- **Zero overhead** — Compile-time string generation has no runtime cost

---

## Relationship to Other Guidelines

- **[Code Style][code-style]** — Formatting, naming, and syntax conventions
- **[Functional & Declarative Programming][functional-declarative]** — Range pipelines, output ranges, purity

---

## Quick Reference

```d
// IES is written with the i"..." prefix. It does NOT produce a string.
// It produces a compile-time sequence of typed segments.

import core.interpolation;  // auto-imported when IES is used, but explicit is clearer

string name = "Alice";
int count = 42;

// Convert to string explicitly
import std.conv : text;
string greeting = i"Hello, $(name)! You have $(count) items.".text;

// Pass directly to functions that accept IES (no allocation)
import std.stdio : writeln;
writeln(i"Hello, $(name)! You have $(count) items.");

// WRONG — IES does not implicitly convert to string
// string s = i"Hello, $(name)";  // COMPILE ERROR
```

---

## 1. IES Literal Syntax

IES has three literal forms. All use `$(expr)` for interpolation.

### Syntax Forms

| Form                           | Delimiter     | Escapes?                     | `$(...)` interpolation? |
| ------------------------------ | ------------- | ---------------------------- | ----------------------- |
| [`i"..."`](#double-quoted-ies) | Double quotes | Yes (`\n`, `\t`, `\$`, etc.) | Yes                     |
| [`` i`...` ``](#wysiwyg-ies)   | Backticks     | No                           | Yes                     |
| [`iq{...}`](#token-ies)        | `iq{` `}`     | No                           | Yes                     |

**Note:** IES literals do NOT support character width suffixes (no `i"..."w` or `i"..."d`).

### Double-Quoted IES {#double-quoted-ies}

Standard form. Supports escape sequences (`\n`, `\t`, `\\`, `\$`, etc.).

```d
string msg = i"Name:\t$(name)\nCount:\t$(count)".text;
// \$ produces a literal $ character
string price = i"Price: \$$(amount)".text;
```

A bare `$` NOT followed by `(` is treated as a literal `$` — no escape needed:

```d
string s = i"costs $5 but $(variable) is interpolated".text;
```

### Wysiwyg IES {#wysiwyg-ies}

Backtick-delimited. No escape sequences are recognized. What you type is what you get.

```d
string raw = i`no escapes here: \n is literal, $(expr) is interpolated`.text;
```

### Token IES {#token-ies}

Must contain valid D tokens. No escape sequences. Useful for embedding D code fragments.

```d
auto tokens = iq{$(expr) + $(other)};
```

---

## 2. Converting IES to a String {#converting-ies-to-a-string}

IES does not implicitly convert to `string`. This is a deliberate safety decision to prevent injection vulnerabilities.

### Using `std.conv.text` (Simple Cases)

```d
import std.conv : text;

string name = "Alice";
string result = i"Hello, $(name)!".text;
assert(result == "Hello, Alice!");
```

### Using `std.stdio.writeln` (Direct Output, No Allocation)

```d
import std.stdio : writeln;
writeln(i"Value: $(x)");  // No string allocation — writes segments directly
```

### @nogc Considerations

`.text` allocates via GC. For @nogc code, write to output ranges instead (see [Output Range Integration](#output-range-integration)).

**Rule:** Prefer passing IES directly to functions that accept it natively (like `writeln`) over converting to `string` first. This avoids unnecessary allocation and enables type-safe processing.

---

## 3. What IES Produces {#what-ies-produces}

An IES literal is **not a string**. The compiler transforms it into a **sequence** of typed segments. Every IES sequence has this structure:

```text
InterpolationHeader, ...segments..., InterpolationFooter
```

Each segment is one of:

| Segment Type                    | What It Represents                  | `toString()` Returns |
| ------------------------------- | ----------------------------------- | -------------------- |
| `InterpolationHeader`           | Start sentinel                      | `""` (empty)         |
| `InterpolatedLiteral!"text"`    | Literal string portion              | The literal text     |
| `InterpolatedExpression!"code"` | Source text of next expression      | `""` (empty)         |
| _(the actual value)_            | The runtime value of the expression | _(its own type)_     |
| `InterpolationFooter`           | End sentinel                        | `""` (empty)         |

### Concrete Expansion Example

```d
string name = "Alice";
int count = 3;
auto ies = i"$(name) has $(count) items.";

// The compiler expands this to a sequence equivalent to:
// (
//   InterpolationHeader(),
//   InterpolatedExpression!"name"(),   // source text of expression
//   name,                              // actual value: "Alice"
//   InterpolatedLiteral!" has "(),     // literal text between expressions
//   InterpolatedExpression!"count"(),  // source text of expression
//   count,                             // actual value: 3
//   InterpolatedLiteral!" items."(),   // trailing literal text
//   InterpolationFooter()
// )
```

### Key Properties

- `InterpolatedLiteral` carries its string as a **compile-time template parameter**, accessible via `.toString()` or `is` expression.
- `InterpolatedExpression` carries the source code of the expression as a **compile-time template parameter**, accessible via `.expression` enum.
- The actual runtime values appear **directly in the sequence** after their corresponding `InterpolatedExpression`.
- `core.interpolation` types are automatically imported when IES is used, but explicit `import core.interpolation;` is recommended for clarity in library code.
- None of these structs carry runtime state.

### Security: Why IES Does Not Convert to String Implicitly

This segment structure is the foundation of IES's security model. Because each segment carries its type, library functions can distinguish trusted literals from untrusted values.

The type system distinguishes between **literal text** (trusted, from source code) and **interpolated values** (untrusted, from variables). This is a critical safety property.

#### The Problem with Naive String Building

```d
// Dangerous: manual string concatenation has no type-level safety
string query = "SELECT * FROM users WHERE name = '" ~ userInput ~ "'";
// If userInput = "'; DROP TABLE users; --" -> SQL injection
```

#### The IES Advantage

A library function receiving an IES can inspect each segment's type at compile time:

```d
// The library sees:
//   InterpolatedLiteral!"SELECT * FROM users WHERE name = '"  -> trusted literal
//   InterpolatedExpression!"userInput"                         -> marker
//   userInput                                                  -> UNTRUSTED value: escape it!
//   InterpolatedLiteral!"'"                                    -> trusted literal
```

This enables the library to automatically apply context-appropriate escaping (SQL parameterization, HTML encoding, URL encoding, shell escaping) without any effort from the caller.

#### Use Cases Enabled by This Design

| Domain         | What the library does with interpolated values |
| -------------- | ---------------------------------------------- |
| SQL            | Parameterized queries (bind variables)         |
| HTML           | HTML-entity encoding                           |
| URLs           | Percent-encoding                               |
| Shell commands | Shell escaping                                 |
| Logging        | Structured field extraction                    |
| i18n/l10n      | Reorderable message parameters                 |

**Rule:** Library authors SHOULD provide IES-accepting overloads rather than requiring callers to use `.text`. This preserves safety and avoids unnecessary allocation.

**Rule:** Library authors MUST NOT `mixin()` the string from `InterpolatedExpression`. It comes from a different scope and will fail. The string is informational only.

---

## 4. Writing Functions That Accept IES {#writing-functions-that-accept-ies}

### Recommended Pattern: Variadic Template with Header/Footer Guards

```d
import core.interpolation;

void processIES(Sequence...)(
    InterpolationHeader,
    Sequence data,
    InterpolationFooter
)
{
    // Process `data` here.
    // `data` contains interleaved InterpolatedLiteral, InterpolatedExpression,
    // and actual values.
}

// Usage:
string name = "Alice";
processIES(i"Hello, $(name)!");
```

The `InterpolationHeader`/`InterpolationFooter` parameters act as type-level guards that ensure the function is only called with an IES, and they delimit the interpolation boundary.

### Iterating Over Segments at Compile Time

```d
import core.interpolation;
import std.array : appender;

string iesConcat(Sequence...)(InterpolationHeader, Sequence data, InterpolationFooter)
{
    import std.conv : to;
    auto result = appender!string;

    static foreach (item; data)
    {
        // InterpolatedLiteral — a literal string fragment
        static if (is(typeof(item) == InterpolatedLiteral!str, string str))
        {
            result ~= str;
        }
        // InterpolatedExpression — skip (it's metadata only)
        else static if (is(typeof(item) == InterpolatedExpression!code, string code))
        {
            // `code` contains the source text, e.g. "name"
            // Typically skip this; it's informational only.
        }
        // Actual runtime value
        else
        {
            result ~= to!string(item);
        }
    }
    return result[];
}
```

### Compile-Time Template Parameter Usage

IES can also be passed as template arguments, enabling compile-time processing including types:

```d
import core.interpolation;

template processAtCompileTime(InterpolationHeader header, Sequence...)
{
    static assert(Sequence[$ - 1] == InterpolationFooter());
    // Process Sequence at compile time...
}

alias result = processAtCompileTime!(i"Type is: $(int)");
```

### Output Range Integration

The patterns above use `appender!string` as the output sink. For `@nogc` contexts or streaming output, the same approach works with output ranges.

#### Writing to Output Ranges

```d
import core.interpolation;
import std.conv : to;
import std.range.primitives : isOutputRange, put;

void writeInterpolated(Writer, Args...)(
    ref Writer w,
    InterpolationHeader,
    Args args,
    InterpolationFooter
)
if (isOutputRange!(Writer, char))
{
    static foreach (arg; args)
    {
        static if (is(typeof(arg) == InterpolatedLiteral!str, string str))
            put(w, str);
        else static if (is(typeof(arg) == InterpolatedExpression!expr, string expr))
        {
            // Skip metadata
        }
        else
            put(w, arg.to!string);
    }
}
```

For a production implementation of this pattern, see the [`styled_template` module][styled-template-src], where [`writeStyled()`][styled-template-src] processes IES into styled terminal output via an output range.

#### @nogc with SmallBuffer

For @nogc contexts, use `SmallBuffer` and avoid `.to!string`:

```d
import core.interpolation;
import sparkles.core_cli.smallbuffer : SmallBuffer;

// Usage
SmallBuffer!(char, 256) buf;
// Custom @nogc IES processing with integer-to-string conversion
// that doesn't allocate...
```

---

## 5. Complete Patterns

The patterns in this section are adapted from Adam D. Ruppe's [interpolation-examples][interpolation-examples] repository, which demonstrates real-world IES use cases.

### Pattern: Safe SQL Query Builder

```d
import core.interpolation;

struct SafeQuery
{
    string sql;
    string[] params;
}

SafeQuery buildQuery(Sequence...)(InterpolationHeader, Sequence data, InterpolationFooter)
{
    import std.conv : to;
    import std.array : appender;

    auto sql = appender!string;
    string[] params;

    static foreach (item; data)
    {
        static if (is(typeof(item) == InterpolatedLiteral!str, string str))
        {
            sql ~= str;
        }
        else static if (is(typeof(item) == InterpolatedExpression!code, string code))
        {
            // skip expression metadata
        }
        else
        {
            sql ~= "?";
            params ~= to!string(item);
        }
    }

    return SafeQuery(sql[], params);
}

// Usage:
string userName = "Alice'; DROP TABLE users; --";
auto q = buildQuery(i"SELECT * FROM users WHERE name = $(userName)");
assert(q.sql == "SELECT * FROM users WHERE name = ?");
assert(q.params == ["Alice'; DROP TABLE users; --"]);
```

::: info Attribution
Adapted from [`lib/sql.d`][interpolation-examples-sql] in Adam D. Ruppe's interpolation-examples. The original uses compile-time query construction with `execi()` for a real SQLite binding.
:::

### Pattern: HTML Template with Auto-Escaping

```d
import core.interpolation;
import std.array : appender, replace;

string htmlEscape(string s)
{
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
            .replace("\"", "&quot;").replace("'", "&#39;");
}

string safeHtml(Sequence...)(InterpolationHeader, Sequence data, InterpolationFooter)
{
    auto result = appender!string;

    static foreach (item; data)
    {
        static if (is(typeof(item) == InterpolatedLiteral!str, string str))
        {
            result ~= str;  // Trusted literal: pass through
        }
        else static if (is(typeof(item) == InterpolatedExpression!code, string code))
        {
            // skip
        }
        else static if (is(typeof(item) : string))
        {
            result ~= htmlEscape(item);  // Untrusted value: escape!
        }
        else
        {
            import std.conv : to;
            result ~= htmlEscape(to!string(item));
        }
    }

    return result[];
}

// Usage:
string userInput = "<script>alert('xss')</script>";
string html = safeHtml(i"<p>Hello, $(userInput)!</p>");
// Result: <p>Hello, &lt;script&gt;alert(&#39;xss&#39;)&lt;/script&gt;!</p>
```

::: info Attribution
Adapted from [`lib/html.d`][interpolation-examples-html] in Adam D. Ruppe's interpolation-examples. The original includes compile-time HTML structure validation and returns a DOM `Element`.
:::

### Pattern: URL Encoding

```d
import core.interpolation;
import std.array : appender;
import std.conv : to;
import std.uri : encodeComponent;

string urlSafe(Args...)(InterpolationHeader, Args args, InterpolationFooter)
{
    auto result = appender!string;

    static foreach (arg; args)
    {
        static if (is(typeof(arg) == InterpolatedLiteral!str, string str))
            result ~= str;
        else static if (is(typeof(arg) == InterpolatedExpression!expr, string expr))
        {
            // Skip metadata
        }
        else
            result ~= encodeComponent(arg.to!string);
    }

    return result[];
}

// Usage
auto query = "hello world & goodbye";
auto url = urlSafe(i"https://example.com/search?q=$(query)");
// Result: "https://example.com/search?q=hello%20world%20%26%20goodbye"
```

::: info Attribution
Adapted from [`lib/url.d`][interpolation-examples-url] in Adam D. Ruppe's interpolation-examples. The original uses a state machine to apply context-appropriate encoding to different URL components.
:::

### Pattern: Structured Logging

```d
import core.interpolation;
import std.conv : to;
import std.array : appender;

void logStructured(Sequence...)(InterpolationHeader, Sequence data, InterpolationFooter)
{
    auto message = appender!string;
    string[string] fields;

    static foreach (idx, item; data)
    {
        static if (is(typeof(item) == InterpolatedLiteral!str, string str))
        {
            message ~= str;
        }
        else static if (is(typeof(item) == InterpolatedExpression!code, string code))
        {
            // The next element in the sequence is the actual value.
            // Store as a named field for structured logging.
            fields[code] = to!string(data[idx + 1]);
        }
        else
        {
            message ~= to!string(item);
        }
    }

    import std.stdio : writefln;
    writefln!"msg=%s fields=%s"(message[], fields);
}

// Usage:
string user = "Alice";
int latency = 42;
logStructured(i"Request from $(user) took $(latency)ms");
// Output: msg=Request from Alice took 42ms fields=["user": "Alice", "latency": "42"]
```

::: info Attribution
Inspired by the internationalization example ([`04-internationalization.d`][interpolation-examples-i18n]) in Adam D. Ruppe's interpolation-examples, which uses `InterpolatedExpression` to extract named parameters for reorderable message templates.
:::

### Real-World: `styled_template`

The sparkles [`styled_template`][styled-template-src] module applies the same IES patterns shown above to build a styled terminal output system. Its core function, `writeStyled()`, accepts IES and writes ANSI-styled text to any output range:

```d
void writeStyled(Writer, Args...)(
    ref Writer w,
    InterpolationHeader,
    Args args,
    InterpolationFooter
)
{
    import std.conv : to;
    import std.range.primitives : put;

    ParserContext ctx;

    static foreach (arg; args)
    {{
        alias T = typeof(arg);
        static if (is(T == InterpolatedLiteral!lit, string lit))
        {
            parseLiteral(w, lit, ctx);
        }
        else static if (is(T == InterpolatedExpression!code, string code))
        {
            // Skip expression metadata
        }
        else
        {
            // Output interpolated value - styles already active from block
            put(w, arg.to!string);
        }
    }}
}
```

The three-branch `static if` dispatch — literal, expression metadata, runtime value — is the same core pattern used in every example above. The difference is that `parseLiteral` interprets a `{style ...}` mini-language within literal segments to emit ANSI escape codes.

Consumer-side examples:

- [`libs/core-cli/examples/styled_template.d`][example-styled-template] — comprehensive demo of style syntax (colors, bold, nesting, negation)
- [`libs/core-cli/examples/box.d`][example-box] — box drawing with styled IES content
- [`libs/core-cli/examples/table.d`][example-table] — table rendering with styled headers
- [`scripts/run_md_examples.d`][run-md-examples] — CLI status and progress output using IES

---

## 6. When to Use IES vs Alternatives

### Use IES When

- Building user-facing messages with embedded values
- Context-aware encoding is needed (SQL, HTML, URLs)
- You want compile-time metadata about the template structure
- Passing to functions that process the sequence directly

### Use `std.format` / `writef` When

- You need format specifiers (`%08x`, `%.2f`, `%10s`)
- Building strings for `printf`-style APIs
- Maximum control over output formatting

### Decision Matrix

| Scenario                 | Recommendation            |
| ------------------------ | ------------------------- |
| CLI output messages      | IES with `writeln`        |
| SQL queries              | IES with parameterization |
| HTML generation          | IES with entity encoding  |
| Hex/binary formatting    | `std.format`              |
| Log messages with values | IES                       |
| @nogc string building    | IES with output ranges    |

---

## 7. Common Mistakes {#common-mistakes}

### Assigning IES Directly to a String

```d
string s = i"Hello, $(name)";  // COMPILE ERROR
```

**Fix:** Use `.text` or pass to an IES-accepting function:

```d
import std.conv : text;
string s = i"Hello, $(name)".text;
```

### Trying to Mixin an InterpolatedExpression

```d
// Inside a library function processing IES:
mixin(code);  // FAILS — wrong scope
```

**Fix:** Use the actual runtime value that follows the `InterpolatedExpression` in the sequence. Never mixin the expression string.

### Assuming IES is a Single Value

```d
auto x = i"Hello $(name)";
writeln(typeof(x).stringof);  // It's a sequence, not a string!
```

**Fix:** Understand that `x` is a sequence. Index it or pass it to a variadic function.

### Forgetting that `$` Without `(` is Literal

```d
string s = i"costs $5".text;     // Fine — bare $ is literal
string s = i"costs \$5".text;    // Also fine — \$ is explicit escape
string s = i"$(price) USD".text; // Interpolation with $(...)
```

### Not Handling Empty InterpolatedExpression

Library code should be robust against implementations that omit `InterpolatedExpression` or provide an empty string. Do not depend on it always being present:

```d
// Robust: handle both with and without InterpolatedExpression
else static if (is(typeof(item) == InterpolatedExpression!code, string code))
{
    // May be empty or missing entirely — handle gracefully
}
```

### IES Syntax in DDoc Comments

IES and DDoc both use `$(...)` syntax. When writing DDoc comments that mention IES, the `$(expr)` in prose text will be interpreted as a DDoc macro:

```d
/**
Use `i"Hello $(name)"` for interpolation.    ← $(name) vanishes!
Use `i"Hello $(DOLLAR)$(LPAREN)name$(RPAREN)"` instead.  ← renders correctly
*/
```

This does NOT affect actual IES code in function bodies or unittest bodies — only DDoc comment text. Inside `---` code blocks in DDoc comments, `$(...)` is preserved literally. See [DDoc Guidelines][ddoc-ies] for the full interaction rules.

---

## 8. Advanced Usage

The following topics cover less common but powerful IES capabilities for library authors and advanced use cases.

### Compile-Time Introspection

All IES segment types support compile-time inspection:

```d
string name = "Alice";
auto ies = i"Hello, $(name)!";

// Type checks
static assert(is(typeof(ies[0]) == InterpolationHeader));
static assert(is(typeof(ies[$ - 1]) == InterpolationFooter));

// Literal string access at compile time
static assert(ies[1].toString() == "Hello, ");

// Expression source text access at compile time
static assert(ies[2].expression == "name");

// Runtime value
assert(ies[3] == "Alice");
```

#### Building Format Strings at Compile Time

```d
import core.interpolation;

template makeFormatString(Args...)
{
    enum string makeFormatString = ()
    {
        string result;
        static foreach (arg; Args)
        {
            static if (is(arg == InterpolatedLiteral!str, string str))
                result ~= str;
            else static if (is(arg == InterpolatedExpression!expr, string expr))
            {
                // Skip
            }
            else static if (is(arg == InterpolationHeader) || is(arg == InterpolationFooter))
            {
                // Skip
            }
            else
                result ~= "%s";  // Placeholder for value
        }
        return result;
    }();
}

// Validate at compile time with static assert
enum fmt = makeFormatString!(typeof(i"Value: $(42)".expand));
static assert(fmt == "Value: %s");
```

### IES and Nesting

IES can nest. Each nested IES produces its own `InterpolationHeader`/`InterpolationFooter` pair. Library code processing IES should track nesting depth if it matters:

```d
auto nested = i"outer $(i"inner $(value)") end";
// This produces nested Header/Footer pairs
```

---

## 9. Quick-Reference Checklist

- [ ] **IES produces a sequence, not a string.** Never assign to `string` directly. [→ §3](#what-ies-produces)
- [ ] **Use `.text` for simple string conversion.** `import std.conv : text;` then `i"...".text`. [→ §2](#converting-ies-to-a-string)
- [ ] **Use `writeln` for direct output.** It accepts IES natively with zero allocation. [→ §2](#converting-ies-to-a-string)
- [ ] **Write IES-accepting functions** with the `(InterpolationHeader, Sequence data, InterpolationFooter)` signature pattern. [→ §4](#writing-functions-that-accept-ies)
- [ ] **Distinguish literals from values** using `static if` with `is(typeof(item) == InterpolatedLiteral!str, string str)`. [→ §4](#writing-functions-that-accept-ies)
- [ ] **Never mixin InterpolatedExpression.** The `.expression` member is informational only. [→ §7](#common-mistakes)
- [ ] **Escape interpolated values, not literals** in security-sensitive contexts (SQL, HTML, URLs). [→ §3](#security-why-ies-does-not-convert-to-string-implicitly)
- [ ] **Prefer IES-native overloads** over `.text` conversion in library APIs. [→ §3](#security-why-ies-does-not-convert-to-string-implicitly)
- [ ] **`core.interpolation` is auto-imported** when IES is used, but import explicitly in library code for clarity. [→ §3](#key-properties)
- [ ] **Handle missing/empty `InterpolatedExpression`** — don't assume it's always present. [→ §7](#common-mistakes)

---

## References

- [D Spec: Interpolation Expression Sequences][d-spec-ies] — Language specification
- [core.interpolation module][core-interpolation] — Runtime support types
- [DIP1036 — String Interpolation][dip1036] — Design rationale
- [Adam D. Ruppe's interpolation-examples][interpolation-examples] — Real-world IES use cases (SQL, HTML, URLs, i18n)

<!-- Guidelines -->

[code-style]: code-style.md
[functional-declarative]: functional-declarative-programming-guidelines.md
[ddoc]: ddoc.md
[ddoc-ies]: ddoc.md#ies--in-ddoc-comments

<!-- D language references -->

[d-spec-ies]: https://dlang.org/spec/istring.html
[core-interpolation]: https://dlang.org/phobos/core_interpolation.html
[dip1036]: https://github.com/dlang/DIPs/blob/master/DIPs/other/DIP1036.md

<!-- Adam D. Ruppe's interpolation-examples -->

[interpolation-examples]: https://github.com/adamdruppe/interpolation-examples
[interpolation-examples-sql]: https://github.com/adamdruppe/interpolation-examples/blob/master/lib/sql.d
[interpolation-examples-html]: https://github.com/adamdruppe/interpolation-examples/blob/master/lib/html.d
[interpolation-examples-url]: https://github.com/adamdruppe/interpolation-examples/blob/master/lib/url.d
[interpolation-examples-i18n]: https://github.com/adamdruppe/interpolation-examples/blob/master/04-internationalization.d

<!-- Sparkles source files -->

[styled-template-src]: ../../libs/core-cli/src/sparkles/core_cli/styled_template.d
[example-styled-template]: ../../libs/core-cli/examples/styled_template.d
[example-box]: ../../libs/core-cli/examples/box.d
[example-table]: ../../libs/core-cli/examples/table.d
[run-md-examples]: ../../scripts/run_md_examples.d
