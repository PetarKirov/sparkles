# D Developer Guidelines: DDoc

## Introduction

DDoc is D's built-in documentation generator. It extracts specially formatted comments from source code and produces formatted output (typically HTML). Unlike external tools such as Doxygen or Javadoc, DDoc is integrated into the D compiler itself and invoked via `dmd -D`.

DDoc's design goals favor documentation that reads well in source code, requires minimal markup, avoids repeating information the compiler already knows, and does not depend on embedded HTML.

This document establishes guidelines for writing effective DDoc comments across D projects. It covers comment syntax, section conventions, formatting features, macro usage, cross-referencing, and common pitfalls.

---

## Complete Example

Before diving into the details, here is a fully documented module showing all the key elements in context — module-level documentation, function documentation with all standard sections, cross-references, and a documented unittest:

```d
/**
Spatial utility functions for 2D geometry.

This module provides distance and proximity calculations
for points in two-dimensional Euclidean space.

See_Also:
    $(MREF geometry, threedim) for 3D equivalents

Source: $(SRC geometry/twodim.d)
Copyright: © 2025 Project Authors
License: $(HTTP boost.org/LICENSE_1_0.txt, Boost License 1.0)
Authors: $(HTTP example.com, Jane Developer)

Macros:
    SRC = $(LINK2 https://github.com/example/geom/blob/main/$0, $0)
*/
module geometry.twodim;

import std.math : sqrt, isClose;

/**
Computes the Euclidean distance between two points in 2D space.

Uses the standard distance formula: `sqrt((x2-x1)² + (y2-y1)²)`.
Returns `0.0` when the two points are identical.

Params:
    x1 = x-coordinate of the first point
    y1 = y-coordinate of the first point
    x2 = x-coordinate of the second point
    y2 = y-coordinate of the second point

Returns: The Euclidean distance as a `double`.

Throws: Nothing.

See_Also: $(LREF manhattanDistance)
*/
@safe pure nothrow @nogc
double euclideanDistance(double x1, double y1, double x2, double y2)
{
    return sqrt((x2 - x1) * (x2 - x1) + (y2 - y1) * (y2 - y1));
}

///
@safe pure nothrow @nogc
unittest
{
    assert(euclideanDistance(0, 0, 3, 4).isClose(5.0));
    assert(euclideanDistance(1, 1, 1, 1).isClose(0.0));
}

/**
Computes the Manhattan distance between two points.

Params:
    x1 = x-coordinate of the first point
    y1 = y-coordinate of the first point
    x2 = x-coordinate of the second point
    y2 = y-coordinate of the second point

Returns: The sum of absolute differences along each axis.

See_Also: $(LREF euclideanDistance)
*/
@safe pure nothrow @nogc
double manhattanDistance(double x1, double y1, double x2, double y2)
{
    import std.math : abs = fabs;
    return abs(x2 - x1) + abs(y2 - y1);
}

/// ditto
@safe pure nothrow @nogc
double manhattanDistance(int x1, int y1, int x2, int y2)
{
    import std.math : abs;
    return abs(x2 - x1) + abs(y2 - y1);
}

///
@safe pure nothrow @nogc
unittest
{
    assert(manhattanDistance(1.0, 1.0, 4.0, 5.0).isClose(7.0));
    assert(manhattanDistance(0, 0, 3, 4) == 7);
}
```

The rest of this document explains each element shown above in detail.

Note how the module comment defines a `SRC` macro so that `Source:` links use a short, readable invocation. In practice, define such project-level macros in a shared `.ddoc` file passed on the command line (e.g., `project.ddoc`) rather than repeating the definition in every module.

---

## Comment Forms

DDoc recognizes three comment forms:

```d
/// Single-line documentation comment.

/** Multi-line block documentation comment. */

/++ Multi-line nesting block documentation comment. +/
```

**Guideline:** Prefer block comments (`/**` or `/++`) for multi-line documentation. Use `///` only for `ditto` comments or very short annotations. Do not use more than two leading `*` or `+` characters in the opening delimiter.

```d
// ✅ Good
/**
This function returns the sum of two integers.
*/
int sum(int a, int b) { return a + b; }

/// ditto
int sum(long a, long b) { return cast(int)(a + b); }

// ❌ Bad — excessive opening stars
/***********************************
 * Don't do this in new code.
 */
```

### Leading Margin Characters

Extra `*` or `+` characters on the left margin are stripped automatically and are not part of the documentation. The D Style recommends that documentation comments should **not** have leading stars on each line. Phobos enforces this, and it is good practice in all D code:

```d
// ✅ Good — no leading stars
/**
Checks whether a number is positive.
Zero is not considered positive.
*/

// ❌ Avoid
/**
 * Checks whether a number is positive.
 * Zero is not considered positive.
 */
```

---

## Comment Placement and Association

Each documentation comment is associated with a declaration. The rules are:

1. A comment on its own line (or with only whitespace to the left) documents the **next** declaration.
2. A comment on the same line to the **right** of a declaration documents that declaration.
3. Multiple comments applying to the same declaration are concatenated.
4. A comment preceding the `module` declaration documents the entire module.
5. A declaration with **no** documentation comment may be omitted from output entirely. Add an empty comment (`///`) to force inclusion.

```d
/// Documentation for `a`. `b` has no documentation and may not appear.
int a;
int b;

/** Documentation for both `c` and `d`. */
int c;
/** ditto */
int d;

int e; /// Documentation for `e`.
```

### The `ditto` Keyword

If a documentation comment consists solely of the word `ditto`, it reuses the documentation of the previous declaration at the same scope. This is useful for overloads and closely related symbols:

```d
/// Converts the value to a string representation.
string toString(int value) { /* ... */ }
/// ditto
string toString(float value) { /* ... */ }
```

### When Not to Use DDoc Comments

Do not use DDoc comments for overrides unless the overriding function does something different (as far as the caller is concerned) than the overridden function. DDoc comment blocks are also overkill for nested functions and function literals — use ordinary comments for those instead.

---

## Section Structure

A DDoc comment is divided into a sequence of sections. Sections are identified by a name followed by a colon (`:`) as the first non-blank content on a line. Section names are case-insensitive.

Note: Section names starting with `http://` or `https://` are not recognized as section names. This was a historical source of bugs (fixed in DMD 2.076) where bare URLs at the start of a line could be mistakenly parsed as section headers.

### Summary

The first section is the **Summary** — the first paragraph up to the first blank line or named section. Keep it to one line when possible. The Summary is optional but strongly recommended.

### Description

Everything after the Summary and before the first named section is the **Description**. It consists of one or more paragraphs. A Description requires a Summary to precede it.

```d
/**
Brief one-line summary of what this function does.

More detailed description follows after the blank line.
This can span multiple paragraphs.

Second paragraph of description.
*/
```

### Named Sections

Named sections follow the Summary and Description. None are required, but certain sections are expected by convention.

---

## Standard Sections

These sections are recognized by DDoc and have conventional meanings:

| Section       | Purpose                                                    |
| ------------- | ---------------------------------------------------------- |
| `Params:`     | Documents function parameters (special syntax — see below) |
| `Returns:`    | Describes the return value                                 |
| `Throws:`     | Lists exceptions thrown and under what conditions          |
| `See_Also:`   | References to related symbols or URLs                      |
| `Examples:`   | Usage examples (prefer documented unittests instead)       |
| `Bugs:`       | Known bugs or limitations                                  |
| `Deprecated:` | Explanation and migration path for deprecated symbols      |
| `Authors:`    | Author(s) of the declaration                               |
| `License:`    | License information                                        |
| `Standards:`  | Applicable standards or specifications                     |
| `History:`    | Revision history                                           |
| `Version:`    | Current version of the declaration                         |
| `Date:`       | Date of the current revision                               |
| `Copyright:`  | Copyright notice (special behavior on module declarations) |

### Params Section

The `Params:` section uses special syntax. Each parameter starts on a new line with the parameter name followed by `=`:

```d
/**
Computes the weighted average.

Params:
    values = the input array of values
    weights = corresponding weights for each value;
              must have the same length as `values`

Returns: The weighted arithmetic mean.

Throws: `RangeError` if `values` is empty.

See_Also: $(LREF simpleAverage), $(LREF geometricMean)
*/
double weightedAverage(double[] values, double[] weights) { /* ... */ }
```

**Guideline:** Text in sections that spans more than one line should be indented by one additional level relative to the section header.

**Warning:** The compiler will issue a warning if a `Params:` section lists a parameter name that does not match any actual function parameter. It also warns if the format `param = description` is not followed. Pay attention to these warnings — they indicate documentation/code drift.

---

## Documentation Requirements

### Minimum Coverage

Every public declaration should have a documentation comment. At minimum, every public function should have:

1. A **Summary** line
2. A **`Params:`** section (if the function takes parameters)
3. A **`Returns:`** section (if the function returns non-`void`)

Do not redundantly document a `void` return. Phobos enforces these requirements via CI; adopting them in your own projects is strongly recommended.

```d
/**
Checks whether a number is positive.
`0` is not considered positive.

Params:
    number = the number to check

Returns: `true` if the number is positive, `false` otherwise.

See_Also: $(LREF isNegative)
*/
bool isPositive(int number)
{
    return number > 0;
}
```

### Module-Level Documentation

The documentation comment preceding the `module` declaration documents the entire module. Use this to describe the module's purpose, provide usage guidance, and set module-level macros or copyright information.

```d
/**
Provides mathematical utility functions for statistical analysis.

This module contains functions for computing means, variances,
and other descriptive statistics.

Copyright: © 2025 Project Authors
License: $(HTTP boost.org/LICENSE_1_0.txt, Boost License 1.0)
Authors: $(HTTP example.com, Jane Developer)
*/
module stats.descriptive;
```

When the `Copyright:` section appears on a module declaration, its content is assigned to the `COPYRIGHT` macro for use elsewhere in the documentation.

---

## Embedded Code

### Code Blocks

Delimit D code examples with at least three hyphens (`---`), backticks (`` ` ``), or tildes (`~`). The code receives automatic syntax highlighting. Use exactly three dashes (`---`) as the conventional delimiter:

```d
/**
Sorts the range in ascending order.

Examples:
---
auto arr = [3, 1, 2];
arr.sort();
assert(arr == [1, 2, 3]);
---
*/
```

To embed code in another language without D syntax highlighting, add a language identifier after the opening delimiter:

````d
/++
Interoperates with C++ containers.

``` cpp
#include <vector>
std::vector<int> v = {1, 2, 3};
````

+/

````

Note: When your code block needs to contain `/* ... */` comments, use the `/++ ... +/` comment form so the block comment inside the code does not prematurely close the documentation comment.

### Inline Code

Use backticks for inline code references, similar to Markdown:

```d
/// Returns `true` if `a == b`.
bool equal(int a, int b) { return a == b; }
````

Text inside backticks is wrapped in the `$(DDOC_BACKQUOTED)` macro and rendered as an inline code span. Macros are still expanded inside backticks. To include a literal backtick, use the `$(BACKTICK)` macro.

**Warning:** Because macros are expanded inside backticks, writing `` `i"Hello $(name)"` `` in DDoc prose will cause `$(name)` to be processed as a macro and silently vanish. To show IES syntax literally in inline code, escape the dollar sign: `` `i"Hello $(DOLLAR)$(LPAREN)name$(RPAREN)"` ``. Alternatively, use a `---` code block where no macro expansion occurs.

---

## Documented Unit Tests

DDoc can extract unit test bodies as usage examples. A documented unittest is a `unittest` block immediately preceded by a `///` comment:

```d
/**
Returns the absolute value of `x`.

Params:
    x = input value

Returns: The absolute value.
*/
int myAbs(int x)
{
    return x < 0 ? -x : x;
}

///
unittest
{
    assert(myAbs(-5) == 5);
    assert(myAbs(3) == 3);
    assert(myAbs(0) == 0);
}
```

The compiler inserts the unittest body into the `Examples:` section of the preceding declaration's documentation. This approach is strongly preferred over manually written `Examples:` sections because the examples are compiled and tested, preventing documentation from drifting out of sync with the code.

### Best Practices for Documented Unittests

Write documented unittests so they are self-contained: include any required `import` statements inside the unittest block rather than relying on module-level imports. This ensures the examples remain valid when extracted for documentation.

Annotate unittest blocks with appropriate attributes to verify the documented function's attribute compliance:

```d
///
@safe pure nothrow @nogc
unittest
{
    assert(myFunc(42) == expected);
}
```

Avoid placing unittest blocks inside templates. They generate a new unittest for each instantiation, which wastes compilation time and can produce confusing test output. Place tests outside of the template instead.

### IES in Documented Unittests

IES `$(expr)` syntax inside `i"..."` string literals is **safe** in documented unittests. The compiler's lexer tokenizes `i"..."` as a string literal before DDoc processes the source text, so `$(expr)` inside IES is preserved literally in the generated Examples section — it is not expanded as a DDoc macro.

However, `$(...)` in the `///` comment text preceding the unittest IS processed as a DDoc macro. Use `$(DOLLAR)$(LPAREN)...$(RPAREN)` escaping there.

```d
/// This documented unittest uses IES safely.
/// Note: `$(DOLLAR)$(LPAREN)name$(RPAREN)` in this comment must be escaped,
/// but inside the unittest body it needs no escaping.
@safe
unittest
{
    string name = "Alice";
    auto greeting = i"Hello, $(name)!".text;  // $(name) preserved in docs
    assert(greeting == "Hello, Alice!");
}
```

---

## Formatting Features

### Text Emphasis

Wrap text in `*` for emphasis and `**` for strong emphasis:

```d
/// This is *emphasized* and this is **strongly emphasized**.
```

Underscores (`_`) are **not** used for emphasis in DDoc (unlike Markdown) because they conflict with `snake_case` identifiers and underscore prefix processing.

### Identifier Emphasis

DDoc automatically emphasizes identifiers that are function parameters or names in scope at the associated declaration. To prevent unintended emphasis, prefix an identifier with `_` (the underscore is stripped from output):

```d
/**
The _function parameter `x` is documented here.
Mentioning `x` in the description highlights it automatically.
*/
void compute(int x) { }
```

Be careful with identifiers beginning with underscores in code examples within documentation comments — they can trigger unintended emphasis or DDoc errors.

### Headings

Use `#` characters (one to six) to create headings within long documentation sections:

```d
/**
# Overview
General description.

## Details
More specific information.
*/
```

### Links

DDoc supports four link styles:

```d
/**
1. Reference links: [Object] or [ref]
2. Inline links: [D Language](https://dlang.org)
3. Bare URLs: https://dlang.org
4. Images: ![alt text](https://dlang.org/images/d3.png)

[ref]: https://dlang.org "The D Language Website"
*/
```

Reference links that match a D symbol in scope generate hyperlinks to that symbol's documentation automatically. If a reference label matches both a D symbol and an explicit reference definition, the explicit definition takes precedence.

### Lists

Start ordered lists with a number and period. Start unordered lists with `-`, `*`, or `+`:

```d
/**
Steps:
1. Initialize the buffer
2. Process each element
3. Flush results

Features:
- Fast allocation
- Cache-friendly layout
*/
```

**Caveat:** Inside `/** ... */` comments, a leading `*` on a line is consumed as part of the comment delimiter. Use `-` for unordered lists inside `/** ... */` comments, or use double `**` if the list marker must be an asterisk. The same caveat applies to `+` inside `/++ ... +/` comments.

### Tables

Tables follow a Markdown-like syntax with header, delimiter, and data rows separated by `|`:

```d
/**
| Type    | Size   |
| ------- | -----: |
| `int`   | 4      |
| `long`  | 8      |
*/
```

Use `:` in the delimiter row for alignment: left (`---`), right (`---:`), or center (`:---:`).

### Block Quotes

Prefix lines with `>` for quoted material:

```d
/**
> Design is not just what it looks like.
> Design is how it works.
*/
```

Lines directly following a quoted line are considered part of the quote. Insert a blank line to end the quote.

---

## Cross-Referencing with Macros

Effective cross-referencing is critical for usable documentation. DDoc and the standard library define a set of macros for linking between symbols and modules.

### Intra-Module Links

Use `$(LREF symbol)` to link to another symbol in the same module:

```d
/**
See_Also: $(LREF isNegative), $(LREF abs)
*/
```

`LREF` generates an anchor link within the current page: `<a href="#symbol">symbol</a>`.

### Cross-Module Links

Use `$(REF symbol, package, module)` to link to a symbol in another module. Arguments after the first form the module path, passed as comma-separated segments:

```d
/**
See_Also: $(REF writeln, std, stdio)
*/
```

The `REF` macro generates a link like `std_stdio.html#.writeln`. The argument order (symbol first, then module segments) may seem inverted but is dictated by DDoc's macro processing and the link format.

For linking to a member of a type in another module, use dotted notation for the first argument:

```d
/**
See_Also: $(REF File.writeln, std, stdio)
*/
```

### Module Links

Use `$(MREF std, module)` to link to a module itself (rather than a symbol within it):

```d
/**
For I/O operations, see $(MREF std, stdio).
*/
```

### External Links

For links to external URLs, use `$(LINK2 url, display text)` or `$(LINK url)`:

```d
/**
See the $(LINK2 https://dlang.org/spec/ddoc.html, DDoc specification).
*/
```

For links to Phobos source files, use `$(PHOBOSSRC path)`:

```d
/**
Source: $(PHOBOSSRC std/algorithm/searching.d)
*/
```

### Linking Pitfalls

Several recurring issues involve malformed DDoc links:

- **Broken `LINK2` URLs**: Long URLs split across lines inside macros can break because DDoc treats line breaks inside macro arguments inconsistently. Keep URLs on a single line when possible.
- **Wrong anchor format**: When using `REF` to link to a nested symbol (e.g., a struct member), use dots, not module segments: `$(REF MyStruct.myMethod, std, mymodule)`, not separate arguments for each level.
- **`DOC_ROOT_` macros for external packages**: When linking to symbols in packages outside the current root package, DDoc prepends a `$(DOC_ROOT_pkg)` macro. Define these macros if you need cross-package links.

---

## Macros

DDoc includes a text macro preprocessor. Macros are invoked with `$(NAME)` or `$(NAME arguments)` syntax.

### Defining Macros

Macros can be defined in a `Macros:` section at the end of a documentation comment, in `.ddoc` files passed on the command line, or in the compiler configuration file:

```d
/**
Macros:
    MYLINK = <a href="$1">$2</a>
    RED = <span style="color:red">$0</span>
*/
module mymodule;
```

### Macro Arguments

| Syntax      | Meaning                              |
| ----------- | ------------------------------------ |
| `$0`        | All argument text                    |
| `$1` … `$9` | Individual comma-separated arguments |
| `$+`        | All arguments after the first        |

### Escaping Commas in Arguments

If an argument itself contains commas, they must be escaped. Two approaches work:

1. Backslash-escape: `$(FOO one, two\, three, four)` — here `$2` is `two, three`.
2. Wrapper macro: Define `ARGS=$0` and use `$(FOO one, $(ARGS two, three), four)`.

### Key Predefined Macros

DDoc provides predefined macros for formatting. Some frequently used ones:

| Macro                | Purpose                          |
| -------------------- | -------------------------------- |
| `$(B text)`          | Bold                             |
| `$(I text)`          | Italic                           |
| `$(D code)`          | Inline D code formatting         |
| `$(LINK url)`        | Clickable link                   |
| `$(LINK2 url, text)` | Clickable link with display text |
| `$(DDOC)`            | Overall output template          |
| `$(BODY)`            | Generated document body          |
| `$(TITLE)`           | Module name                      |

### Standard Library Macros

The Phobos documentation system defines additional macros (in `std.ddoc` and `dlang.org.ddoc`) that are available when building with the standard `.ddoc` files. These are commonly used in D projects beyond just Phobos itself:

| Macro                     | Purpose                           |
| ------------------------- | --------------------------------- |
| `$(LREF symbol)`          | Link to symbol in the same module |
| `$(REF symbol, pkg, mod)` | Link to symbol in another module  |
| `$(MREF pkg, mod)`        | Link to a module                  |
| `$(HTTP url, text)`       | HTTP link (shorthand)             |
| `$(PHOBOSSRC path)`       | Link to Phobos source on GitHub   |
| `$(BUGZILLA id)`          | Link to a Bugzilla issue          |

### Macro Precedence

Macro definitions are resolved in this order (later definitions override earlier ones):

1. Predefined macros
2. Definitions from `DDOCFILE` in compiler configuration
3. Definitions from `.ddoc` files on the command line
4. Runtime definitions generated by DDoc
5. Definitions from `Macros:` sections in source

Macro names beginning with `D_` and `DDOC_` are reserved.

---

## Special Characters and Escaping

### Character Entities

Replace characters that have special meaning to the DDoc processor:

| Character | Entity  |
| --------- | ------- |
| `<`       | `&lt;`  |
| `>`       | `&gt;`  |
| `&`       | `&amp;` |

This is not necessary inside code sections or when the character is not followed by `#` or a letter.

### Punctuation Escapes

Escape ASCII punctuation with a backslash (`\`). Some characters produce predefined macros:

| Character | Escape result     |
| --------- | ----------------- |
| `(`       | `$(LPAREN)`       |
| `)`       | `$(RPAREN)`       |
| `,`       | `$(COMMA)`        |
| `$`       | `$(DOLLAR)`       |
| `\\`      | Literal backslash |

Backslashes inside code blocks are not treated as escapes. Backslashes before non-punctuation characters are included as-is (e.g., `C:\dmd2\bin` doesn't need escaping).

---

## Common Pitfalls

These issues are recurring sources of bugs in D documentation. The compiler now warns about some of them, but awareness helps avoid surprises.

### Unmatched Parentheses

**This is the single most common DDoc issue.** DDoc's macro system depends on properly nested parentheses. An unmatched `)` or `(` in documentation text will corrupt the macro expansion of the entire section, potentially producing garbled output for the whole module page.

The compiler will warn: `Ddoc: Stray ')'. This may cause incorrect Ddoc output. Use $(RPAREN) instead for unpaired right parentheses.`

**Fix:** Use `$(LPAREN)` and `$(RPAREN)` for literal parentheses that are not matched, or backslash-escape them with `\(` and `\)`:

```d
/**
The function signature is: `void foo$(LPAREN)$(RPAREN)`.
Alternatively: `void foo\(\)`.
*/
```

This also applies inside code examples if they are not properly delimited with `---` fences. Code between `---` delimiters is handled correctly; the issue arises when parentheses appear in running prose or in un-fenced code references.

### Dollar Signs

A bare `$` followed by `(` is interpreted as a macro invocation. To include a literal `$(`, escape the dollar sign: `\$(` or use `$(DOLLAR)`.

Note: IES uses `\$` to produce a literal dollar sign inside `i"..."` strings. This is a lexer-level escape, independent of DDoc's `$(DOLLAR)` macro. The two mechanisms operate at different stages and do not interfere with each other.

### Macro Expansion Limits

DDoc has a recursion limit for macro expansion. If your documentation triggers more expansions than the limit (configurable but typically generous), the compiler will error: `DDoc macro expansion limit exceeded`. This usually indicates a circular macro definition or an extremely deeply nested set of macros. Simplify the macro hierarchy if this occurs.

### Section Names Colliding with URLs

Avoid starting a line with a URL that could be parsed as a section name. For instance, the text `https:` at the start of a line was historically parsed as a section header called `https`. Since DMD 2.076, `http://` and `https://` prefixes are correctly excluded from section name detection, but earlier compilers may still have this issue.

### Asterisks and Plus Signs in List Items

Inside `/** ... */` comments, leading `*` on any line is consumed as part of the comment delimiter. This means `* List item` becomes ` List item` (no bullet). Use `-` for unordered lists in `/** */` comments. The same applies to `+` in `/++ +/` comments.

### Identifier Auto-Highlighting Surprises

DDoc automatically emphasizes any identifier in documentation text that matches a parameter name or a symbol in scope. This can produce unexpected highlighting for common words that happen to be parameter names (e.g., a parameter named `value` or `result`). Prefix with `_` to suppress: `_value`.

### IES `$(...)` in DDoc Comments

IES and DDoc both use `$(...)` syntax. Their interaction depends on context:

| Context                     | `$(...)` treated as                        | Safe for IES? |
| --------------------------- | ------------------------------------------ | :-----------: |
| `---` code block            | Literal code                               |      Yes      |
| Documented unittest body    | Literal code (string literal token)        |      Yes      |
| DDoc prose (no backticks)   | DDoc macro                                 |      No       |
| Backtick inline code        | DDoc macro                                 |      No       |
| Function body (not in DDoc) | N/A — DDoc never processes function bodies |      Yes      |

When mentioning IES syntax in DDoc prose, always escape: write `$(DOLLAR)$(LPAREN)expr$(RPAREN)` to render as `$(expr)`. Inside `---` code blocks and documented unittest bodies, no escaping is needed.

See [IES and DDoc Interaction](ddoc_ies_interaction.d) for the test program that verified these behaviors.

---

## General-Purpose Documentation with DDoc

DDoc can also be used to process standalone documentation files (not D source code). If a `.d` file starts with the string `Ddoc`, it is treated as a documentation file rather than source code. The text from immediately after `Ddoc` to the end of the file (or any `Macros:` section) forms the document body. No automatic syntax highlighting is applied except within `---` delimited code blocks. Only macro processing occurs.

Much of the dlang.org website itself is written this way — `.dd` files that start with `Ddoc` and use macros from `.ddoc` theme files for layout and styling.

---

## Appendix: IES and DDoc Interaction Test

The file [ddoc_ies_interaction.d](ddoc_ies_interaction.d) tests 8 scenarios where IES `$(expr)` and DDoc `$(MACRO)` syntax could collide. Run it to verify behavior with your compiler version:

```bash
# Runtime verification
dub run --single docs/guidelines/ddoc_ies_interaction.d

# Generate DDoc HTML and inspect
ldc2 -D -Dd=build/docs -preview=in -preview=dip1000 \
  docs/guidelines/ddoc_ies_interaction.d
```

Key findings:

| #   | Scenario                           | `$(...)` preserved? | Notes                                                                       |
| --- | ---------------------------------- | :-----------------: | --------------------------------------------------------------------------- |
| 1   | IES in documented unittest body    |         Yes         | `i"Hello $(name)"` in unittest code renders intact                          |
| 2   | IES in `---` code block            |         Yes         | No macro expansion inside code fences                                       |
| 3   | IES in backtick inline code        |         No          | `$(name)` inside backticks is macro-expanded and vanishes                   |
| 4   | Bare `$(name)` in DDoc prose       |         No          | Undefined macros expand to empty string                                     |
| 5   | DDoc macros + IES in function body |       Coexist       | DDoc never processes function bodies                                        |
| 6   | Dollar escaping                    |        Works        | IES `\$` and DDoc `$(DOLLAR)` are independent mechanisms                    |
| 7   | Chained/nested IES                 |         Yes         | Multiple `$(...)` in string literals all preserved                          |
| 8   | Variables named `B`, `D`, `I`      |    In code: Yes     | IES `$(B)` in string literals is safe; `$(B)` in DDoc prose renders as bold |

---

## References

- [DDoc Language Specification](https://dlang.org/spec/ddoc.html) — The authoritative reference for all DDoc syntax and processing rules.
- [The D Style](https://dlang.org/dstyle.html) — Official coding and documentation style conventions for D.
- [Documented Unit Tests](https://dlang.org/spec/unittest.html#documented-unittests) — Specification for auto-generated examples from unittests.
- [Predefined Macro Definitions (source)](https://github.com/dlang/dmd/blob/master/compiler/src/dmd/res/default_ddoc_theme.ddoc) — Reference implementation of all predefined DDoc macros.
- [Standard Library Macros (std_consolidated.ddoc)](https://github.com/dlang/dlang.org/blob/master/std_consolidated.ddoc) — Macro definitions for `LREF`, `REF`, `BUGZILLA`, and other standard library macros.
- [dlang.org Macros (dlang.org.ddoc)](https://github.com/dlang/dlang.org/blob/master/dlang.org.ddoc) — Site-wide macro definitions including `REF`, `MREF`, and layout macros.
