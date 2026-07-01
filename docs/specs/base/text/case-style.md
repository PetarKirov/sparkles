# `sparkles.base.text.case_style` — Specification

_Audience: developers and coding agents building against `sparkles:base`. This
document is normative and self-contained — it states how the module splits an
identifier into words and rejoins it in a chosen case style. It is a
format-agnostic text primitive with no serialization or UDA concerns; the
[`sparkles:wired`](../../wired/SPEC.md) policy layer is one consumer. For the
library overview see [`sparkles:base`](../../../libs/base/index.md)._

## 1. Overview

`sparkles.base.text.case_style` provides a `CaseStyle` enumeration and a
compile-time-evaluable `convertCase` that renames a single identifier from one
convention (e.g. `fastPath`) into another (e.g. `fast_path`, `FAST_PATH`,
`FastPath`). It carries no opinion about where identifiers come from; callers pass
in a `string` and get a `string` back.

| Identifier      | Value                               |
| --------------- | ----------------------------------- |
| Dub sub-package | `sparkles:base`                     |
| Source root     | `libs/base/src/sparkles/base/text/` |
| Module          | `sparkles.base.text.case_style`     |

## 2. API surface

```d
enum CaseStyle { original, camelCase, pascalCase, snakeCase, kebabCase, screamingSnakeCase }

// Writer form — the primitive: recase `ident` into an output range, no allocation.
void writeConvertedCase(CaseStyle style, Writer, R)(ref Writer w, R ident)
if (isOutputRange!(Writer, char) && isForwardRange!R && isSomeChar!(ElementType!R));

// Convenience — allocate and return the recased identifier.
string convertCase(CaseStyle style)(string ident);   // CTFE-compatible
```

`style` is a template parameter, not a runtime argument, so both overloads can be
instantiated and evaluated during CTFE (§5).

`writeConvertedCase` is the underlying primitive. It takes the input identifier as
any forward range of character elements (a `string` and `const(char)[]` both
qualify) and writes the recased result into the output range `w` element by
element, allocating nothing of its own — suitable for `@nogc` paths that emit
directly into a `SmallBuffer` or a serializer's writer (§7).

`convertCase` is the allocating convenience wrapper: it builds the recased
identifier into a fresh `string` and returns it, except for `CaseStyle.original`,
which returns `ident` unchanged. It is defined in terms of `writeConvertedCase`
over a string-building output range, so both forms produce identical text for the
same `style` and identifier.

## 3. Word boundaries

`convertCase` first splits `ident` into words. A word boundary occurs at:

1. a lowercase or digit immediately followed by an uppercase — `fastPath` splits
   into `fast`, `Path`;
2. an uppercase that begins a new word after an acronym run — an uppercase
   followed by an uppercase-then-lowercase — `JSONValue` splits into `JSON`,
   `Value`;
3. an explicit separator (`_`, `-`, or space), which is consumed and produces no
   word of its own.

Rules 1 and 2 keep acronym runs together (`JSON`, `XML`) while still separating
the acronym from a following capitalized word. Rule 3 lets already-delimited
identifiers (`fast_path`, `fast-path`, `fast path`) round-trip through the word
splitter.

## 4. Rejoining per style

Once split into words, `convertCase` rejoins them per `style`:

| `CaseStyle`          | Transform                                                  | `fromXMLToJSON` →  |
| -------------------- | ---------------------------------------------------------- | ------------------ |
| `original`           | the identifier is returned unchanged (no split/rejoin)     | `fromXMLToJSON`    |
| `camelCase`          | lowercase the first word; title-case the rest; concatenate | `fromXmlToJson`    |
| `pascalCase`         | title-case every word; concatenate                         | `FromXmlToJson`    |
| `snakeCase`          | lowercase every word; join with `_`                        | `from_xml_to_json` |
| `kebabCase`          | lowercase every word; join with `-`                        | `from-xml-to-json` |
| `screamingSnakeCase` | uppercase every word; join with `_`                        | `FROM_XML_TO_JSON` |

Title-casing a word capitalizes its first letter and lowercases the rest, so an
acronym folds to title case: `JSON` → `Json`, `XML` → `Xml`. `camelCase` and
`pascalCase` differ only in the first word (`jsonValue` vs `JsonValue`).

## 5. Compile-time evaluation

`convertCase` must be usable during CTFE so that consumers can derive names at
compile time without requiring the identifier itself to be a template argument
(for example, deriving an enum member's wire name from `__traits(identifier, …)`
inside a `static foreach`). The implementation must include `static assert`
coverage for every `CaseStyle`, including acronym, digit, and explicit-separator
cases.

## 6. Examples

Every style for a handful of identifiers, including acronym runs:

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "case_style_table"
    dependency "sparkles:base" version="*"
+/
import std.stdio : writefln;
import sparkles.base.text.case_style : CaseStyle, convertCase;

void main()
{
    static foreach (id; ["fastPath", "parsedJSON", "JSONValue", "fromXMLToJSON"])
        writefln("%s -> snake:%s kebab:%s scream:%s pascal:%s",
            id,
            convertCase!(CaseStyle.snakeCase)(id),
            convertCase!(CaseStyle.kebabCase)(id),
            convertCase!(CaseStyle.screamingSnakeCase)(id),
            convertCase!(CaseStyle.pascalCase)(id));
}
```

```ansi
fastPath -> snake:fast_path kebab:fast-path scream:FAST_PATH pascal:FastPath
parsedJSON -> snake:parsed_json kebab:parsed-json scream:PARSED_JSON pascal:ParsedJson
JSONValue -> snake:json_value kebab:json-value scream:JSON_VALUE pascal:JsonValue
fromXMLToJSON -> snake:from_xml_to_json kebab:from-xml-to-json scream:FROM_XML_TO_JSON pascal:FromXmlToJson
```

`original` returns the identifier verbatim, while `camelCase` lowercases only the
leading word:

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "case_style_camel"
    dependency "sparkles:base" version="*"
+/
import std.stdio : writefln;
import sparkles.base.text.case_style : CaseStyle, convertCase;

void main()
{
    static foreach (id; ["fastPath", "JSONValue", "fromXMLToJSON"])
        writefln("%s -> original:%s camel:%s", id,
            convertCase!(CaseStyle.original)(id),
            convertCase!(CaseStyle.camelCase)(id));
}
```

```ansi
fastPath -> original:fastPath camel:fastPath
JSONValue -> original:JSONValue camel:jsonValue
fromXMLToJSON -> original:fromXMLToJSON camel:fromXmlToJson
```

## 7. Writer form

`writeConvertedCase` recases directly into an output range without allocating an
intermediate `string`, so it composes with the `@nogc` writers of
`sparkles.base.text` and with a `SmallBuffer` sink. The recasing call itself is
`@safe pure nothrow @nogc`:

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "case_style_writer"
    dependency "sparkles:base" version="*"
+/
import std.stdio : writeln;
import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.base.text.case_style : CaseStyle, writeConvertedCase;

void main()
{
    SmallBuffer!(char, 64) buf;
    writeConvertedCase!(CaseStyle.snakeCase)(buf, "fromXMLToJSON");
    buf ~= ' ';
    writeConvertedCase!(CaseStyle.pascalCase)(buf, "parsedJSON");
    writeln(buf[]);
}
```

```ansi
from_xml_to_json ParsedJson
```

Because it accepts any forward range of characters, the input need not be a
`string` literal; a slice, a `const(char)[]`, or another character range works
too. `convertCase!style(ident)` (§2) is exactly this writer targeting a
string-building range, so the two never disagree.

---

→ [`sparkles.base.text` cell-splitting & width spec](./index.md) — the sibling text spec
→ [`sparkles:wired`](../../wired/SPEC.md) — a policy layer that consumes `convertCase`
→ [`sparkles:base`](../../../libs/base/index.md) — the library overview
