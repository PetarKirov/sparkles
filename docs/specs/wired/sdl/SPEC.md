# `sparkles.wired.sdl` — Specification

_Audience: developers and coding agents implementing or consuming the SDL
backend. This document is normative and self-contained for SDL-specific
behaviour. It extends the [`sparkles:wired` base specification](../SPEC.md) and
the [expressiveness specification](../expressiveness/SPEC.md); where this
document is silent, those contracts stand. For delivery order and gates, see
[PLAN.md](./PLAN.md)._

## 1. Scope and prerequisites

`sparkles.wired.sdl` is the full Simple Declarative Language (SDL) backend for
`sparkles:wired`. It provides:

- a complete UTF-8 SDL lexer and parser;
- an owning, ordered arena document and borrowed node/scalar views;
- schema-driven conversion between SDL and D values;
- explicit field-role UDAs for SDL's values, attributes, and child tags;
- a deterministic semantic writer and atomic file helpers.

This is not a YAML-shaped adapter and does not flatten SDL into a string-keyed
mapping. The following distinctions are load-bearing and survive parsing:

- a tag's ordered positional values;
- its ordered, repeatable, optionally namespaced attributes;
- its ordered, repeatable, optionally namespaced child tags;
- the scalar kind (`int` versus `long`, `float` versus `double`, and so on);
- source spans for tags, names, values, attributes, and delimiters.

### 1.1 Shared-schema prerequisite

The backend depends on the reified schema and schema-driven walk specified by
[expressiveness §2](../expressiveness/SPEC.md#2-the-reified-schema). Its schema
is `wireSchemaOf!(Sdl, T)`. SDL roles and qualified names are resolved into that
schema once; codecs must not independently repeat aggregate introspection or
policy resolution.

Implementation may begin with the syntax/document milestones in
[PLAN](./PLAN.md), but typed `fromSDL`/`writeSDL` does not land until the shared
schema can represent format annotations and a format walker can consume them.
Any missing schema capability is fixed in the shared layer first. A private
SDL-only shadow schema is forbidden.

## 2. Modules and public surface

| Module                        | Contents                                                         |
| ----------------------------- | ---------------------------------------------------------------- |
| `sparkles.wired.sdl`          | Public re-exports, `Sdl` marker, typed codec and file helpers    |
| `sparkles.wired.sdl.policy`   | SDL role UDAs, role resolver, compile-time role/shape validation |
| `sparkles.wired.sdl.document` | Ordered arena, scalar model, borrowed views and iteration ranges |
| `sparkles.wired.sdl.reader`   | Lexer/parser, read options and parse result                      |
| `sparkles.wired.sdl.writer`   | Canonical scalar/document writer and write options               |
| `sparkles.wired.sdl.error`    | `SdlError`, stages, codes, paths, spans and rendering            |

The package module re-exports this consumer surface:

```d
import sparkles.wired.sdl :
    Sdl,
    SdlAttribute, SdlChild, SdlExtra, SdlTagName, SdlTagNamespace, SdlTagValue,
    SdlDocument, SdlNode, SdlScalar, SdlScalarKind, SdlQualifiedName, SdlSpan,
    SdlDateTime, SdlZonedDateTime, SdlExtras, SdlExtraMember,
    SdlParseResult, SdlParserConfig, SdlScalarFeatures, SdlSyntaxFeatures,
    SdlSyntaxCompatibility, sdlFull, sdlDubCompat, sdlDubRecipe,
    SdlWriteOptions,
    SdlError, SdlErrorCode, SdlErrorStage, SdlString,
    parseSdlDocument, validateSDL, writeSdlDocument,
    fromSDL, writeSDL, toSDL, readSDLFile, writeSDLFile;
```

`sparkles.wired` may re-export the typed convenience API and policy UDAs, as it
does for JSON. Document-engine names remain available from
`sparkles.wired.sdl` without requiring the package-wide import.

## 3. SDL language accepted

### 3.1 Compile-time dialects

SDL is a family of syntax profiles, not one runtime-maximal parser. Parser
configuration is a compile-time value: every combination specializes the lexer
and parser, and disabled scalar/syntax kernels are neither instantiated nor
linked. The semantic token and document types remain profile-independent.

```d
enum SdlSyntaxCompatibility : ubyte
{
    sparkles,
    dub5efed360,
}

struct SdlScalarFeatures
{
    bool nulls;
    bool booleans;
    bool strings;
    bool characters;
    bool integers;
    bool longIntegers;
    bool floats;
    bool doubles;
    bool decimals;
    bool binary;
    bool dates;
    bool dateTimes;
    bool zonedDateTimes;
    bool durations;
}

struct SdlSyntaxFeatures
{
    bool rawStrings;
    bool unicodeIdentifiers;
    bool unicodeWhitespace;
    bool unicodeNewlines;
    bool hashComments;
    bool slashComments;
    bool dashComments;
    bool blockComments;
    bool continuations;
    bool semicolonTerminators;
    bool anonymousTags;
}

struct SdlParserConfig
{
    SdlScalarFeatures scalars;
    SdlSyntaxFeatures syntax;
    SdlSyntaxCompatibility compatibility = SdlSyntaxCompatibility.sparkles;
    bool validateUtf8 = true;
    uint maxDepth = 1024;
}
```

Boolean fields default to `false`: a custom profile opts into every accepted
feature deliberately, and adding a future feature cannot silently widen an
existing profile. Shared scanners do not imply accepted scalar kinds. For
example, a date-time profile may instantiate a digit kernel without accepting a
standalone integer token.

Three named profiles are normative:

| Profile        | Contract                                                                                                                                                                                       |
| -------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `sdlFull`      | Every scalar and syntax feature in this specification, with deterministic Sparkles semantics. This is the public default.                                                                      |
| `sdlDubCompat` | Every feature, with accepted spellings, token boundaries, continuation behavior, and scalar interpretation pinned to DUB's bundled SDLang lexer at `5efed360e1c9342453bc5dd19339c75981526d83`. |
| `sdlDubRecipe` | The DUB compatibility behavior and complete structural/trivia/string syntax, but only string and boolean scalar values: the types consumed by known `dub.sdl` recipe fields.                   |

`sdlDubRecipe` is intentionally not acceptance-equivalent to DUB's generic SDL
front end. Pinned DUB constructs a full SDL DOM before ignoring unknown recipe
tags and attributes, so an extension may contain any scalar. Callers that must
accept or preserve arbitrary extensions use `sdlDubCompat`; a known-schema
reader may use `sdlDubRecipe` and reject an extension carrying a disabled scalar.

The profiles retain all structural grammar needed by their contract. In
particular, `sdlDubRecipe` keeps namespaces, attributes, child blocks, repeated
tags, regular and raw string spellings, all DUB comment forms, continuations,
Unicode names/whitespace/newlines, and semicolon terminators. Custom profiles
may remove those syntax features too.

When the source begins with a recognizable spelling of a disabled scalar
family, the lexer returns `unsupportedFeature` over the whole candidate span. It
must not reinterpret the source as shorter identifiers or punctuation. This
rule both gives deterministic diagnostics and leaves the disabled semantic
conversion kernel absent. There is no opaque-token fallback in v1.

The compatibility selector governs syntax and scalar interpretation only. All
profiles retain Sparkles' structured errors, original-source byte spans,
allocator ownership, and host-independent named-zone representation. In
particular, a token after a UTF-8 BOM starts at original byte offset 3 even in
`sdlDubCompat`, rather than reproducing DUB's internally rebased offset 0.

The full profiles resolve the previously ambiguous historical behavior as
follows:

| Behavior                | `sdlFull`                                                                                                                           | `sdlDubCompat`                                                                       |
| ----------------------- | ----------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| Date-time clock fields  | civil ranges                                                                                                                        | DUB rollover/normalization                                                           |
| Date-time fractions     | 1-3 decimal digits; `HH:MM.f` means zero seconds plus the fraction                                                                  | pinned DUB millisecond interpretation, including longer fractions                    |
| Duration fractions      | 1-7 decimal digits (hectonanoseconds)                                                                                               | pinned DUB millisecond interpretation                                                |
| Duration components     | overflow components normalize; leading `-` negates the whole value                                                                  | same accepted component ranges as pinned DUB                                         |
| Date/clock input widths | variable, range-checked                                                                                                             | pinned DUB widths                                                                    |
| Named-zone terminator   | whitespace, newline, `;`, `{`, or `}`                                                                                               | pinned DUB token boundary (whitespace only)                                          |
| GMT offset              | `GMT[+-]HH[:MM]`, range-checked; malformed `GMT+`/`GMT-` forms are errors                                                           | pinned DUB's Java-compatible forms                                                   |
| Continuation            | backslash, enabled horizontal trivia/comments, then a required logical newline; repeated continuations require repeated backslashes | pinned DUB behavior, including one backslash consuming multiple blank physical lines |

Named zones remain host-independent in both profiles. `sdlDubCompat` reproduces
whether DUB accepts and how it lexically interprets a GMT spelling, but it does
not consult a host time-zone database or replace an unknown spelling with a
platform-dependent instant.

### 3.2 Document grammar

`sdlDubCompat` accepts the complete language represented by DUB's bundled
SDLang implementation, subject to the profile-independent error/span/ownership
rules above. `sdlFull` accepts the deterministic Sparkles dialect. In compact
form, their shared structural grammar is:

```text
document   := terminator* tag* EOF
tag        := qualified-name? value+ attribute* children? terminator
           | qualified-name value* attribute* children? terminator
children   := "{" terminator tag* "}"
attribute  := qualified-name "=" value
qualified-name := identifier (":" identifier)?
terminator := newline | ";" | EOF-at-document-end
```

An unnamed tag must have at least one value. A named tag may have no values.
The synthetic document root has only child tags: it has no name, namespace,
values, or attributes. A `{` must be followed by a newline or semicolon before
its first child. `}` closes the current child block; the containing tag does not
use the brace itself as a terminator. A newline or semicolon must follow, except
that EOF may immediately follow the outermost closing brace.

Identifiers begin with `_` or a Unicode alphabetic character. Remaining
characters may additionally be Unicode numeric characters, `-`, `_`, `.`, or
`$`. The keywords `true`, `false`, `on`, `off`, and `null` are scalar tokens
when used in value position and therefore are not unquoted identifiers there.
Names are case-sensitive. A qualified name has at most one namespace prefix.

### 3.3 Whitespace, continuation, comments, and encoding

- Input is UTF-8. A UTF-8 BOM is accepted and excluded from the first token's
  span. UTF-16 and UTF-32 BOMs are rejected.
- Newlines are LF, CR, CRLF, U+2028, or U+2029. Line and column reporting counts
  each logical newline once; columns count Unicode scalar values, with a tab
  counting as one column.
- `#`, `//`, and `--` start line comments. `/* ... */` is a non-nesting block
  comment. An unterminated block comment is a syntax error at its opening span.
- A backslash followed only by horizontal whitespace/comments and then a
  newline continues the current logical line. Several continued physical lines
  are allowed. A continuation without a following newline is an error.
- Comments and insignificant whitespace are not retained by the semantic
  document. Their byte ranges remain covered by surrounding/full source spans
  where applicable, but the canonical writer does not reproduce them.

### 3.4 Scalar syntax and D representation

`SdlScalar` is a discriminated value. The parser must retain the exact kind in
the following table rather than converting every scalar through text:

| SDL scalar       | Accepted syntax                                                    | `SdlScalarKind` / D payload          |
| ---------------- | ------------------------------------------------------------------ | ------------------------------------ |
| null             | `null`                                                             | `null_` / no payload                 |
| boolean          | `true`, `on`, `false`, `off`                                       | `boolean` / `bool`                   |
| string           | `"..."`, raw `` `...` ``                                           | `string_` / decoded UTF-8            |
| character        | `'x'`, including supported escapes                                 | `character` / `dchar`                |
| 32-bit integer   | decimal digits with optional `-`, no suffix                        | `integer` / `int`                    |
| 64-bit integer   | integer followed by `L` or `l`                                     | `longInteger` / `long`               |
| 32-bit float     | decimal number followed by `F` or `f`                              | `float_` / `float`                   |
| 64-bit float     | decimal number, optionally followed by `D` or `d`                  | `double_` / `double`                 |
| extended decimal | decimal number followed by `BD` (case-insensitive)                 | `decimal` / `real`                   |
| binary           | `[` standard Base64 with optional whitespace `]`                   | `binary` / `const(ubyte)[]`          |
| date             | `year/month/day`                                                   | `date` / `Date`                      |
| local date-time  | date, time, optional seconds and 1-3 fractional decimal digits     | `dateTime` / `SdlDateTime`           |
| zoned date-time  | local date-time followed by `-` and a zone name or GMT offset      | `zonedDateTime` / `SdlZonedDateTime` |
| duration         | `[days"d":]hours:minutes:seconds[.fraction]`, optional leading `-` | `duration` / `Duration`              |

The numeric grammar deliberately follows SDL, not JSON: exponent notation and
integer digit separators are rejected. A leading zero before the decimal point
is optional for floating values. Integer and date components are range-checked;
malformed suffixes are errors rather than trailing identifiers.

Regular strings decode `\n`, `\r`, `\t`, `\"`, and `\\`. A backslash followed
by whitespace and a newline is a continuation and contributes no character.
Other backslash uses are rejected. Raw strings preserve all bytes between their
backticks except that the delimiters are removed. Character literals contain
exactly one Unicode scalar and support `\n`, `\r`, `\t`, `\'`, and `\\`.

Binary literals use standard padded Base64. Whitespace is ignored inside the
brackets. Invalid characters, invalid padding, or a non-multiple-of-four encoded
length are syntax errors.

`SdlDateTime` stores the civil date/time plus fractional hectonanoseconds and
records that no zone was supplied. `SdlZonedDateTime` stores the same civil
value, the original zone spelling, and an optional resolved UTC offset. Parsing
does not depend on the host time-zone database: unknown named zones remain valid
SDL values. Conversion to `SysTime` succeeds only when an offset is known;
`GMT+HH[:MM]` and `GMT-HH[:MM]` are resolved directly.

## 4. Ordered arena document

`parseSdlDocument` returns an owning, movable, non-copyable `SdlDocument` backed
by contiguous arenas. `SdlNode`, `SdlAttributeView`, and `SdlScalar` are small,
copyable borrowed views whose lifetime cannot exceed the document under
`-preview=dip1000`.

```d
struct SdlDocument(Allocator = Mallocator)
{
    bool valid() const;
    SdlNode root() return scope const;
    const(char)[] sourceName() return scope const;
}

struct SdlNode
{
    SdlQualifiedName qualifiedName() const;
    SdlSpan span() const;
    size_t valueCount() const;
    size_t attributeCount() const;
    size_t childCount() const;
    SdlValueRange byValue() return scope const;
    SdlAttributeRange byAttribute() return scope const;
    SdlChildRange byChild() return scope const;
}
```

The arena stores nodes in source preorder. Each node records contiguous extents
into value, attribute, and direct-child-index arenas; the child-index arena is
needed because descendants occur between direct siblings in node preorder.
Strings and binary data live in owned pools. There are no parent pointers or
per-node GC allocations. Repeated qualified names are separate entries and are
never collapsed into an associative array.

Order is normative within every channel:

- `byValue` follows source order;
- `byAttribute` follows source order, including duplicate qualified names;
- `byChild` follows source order, including repeated tags and mixed namespaces.

Lookup conveniences may return a range filtered by `SdlQualifiedName`, but may
not return only the first occurrence or reorder matches. A wildcard namespace
is a query option, not a representable SDL namespace.

### 4.1 Spans

```d
struct SdlPosition { size_t byteOffset; uint line; uint column; }
struct SdlSpan { SdlPosition start; SdlPosition end; }
```

Offsets are zero-based UTF-8 byte offsets; lines and columns are one-based for
display. `end` is exclusive. Every tag, qualified name, scalar, and attribute
has a span. A tag span covers its complete semantic declaration, including its
child block when present. Synthetic root and EOF spans are zero-width. Parsed
strings point at decoded storage, while their span still points at the original
literal.

## 5. Typed SDL roles

SDL has three independent payload channels, so an aggregate field's role must
be schema data. The backend ships distinct UDA types rather than an untyped
string or integer role code:

```d
@SdlTagValue(0) string packageName;
@SdlAttribute() bool optional;
@SdlChild() Dependency[] dependencies;
@SdlTagName() string name;
@SdlTagNamespace() string namespace;
@SdlExtra() SdlExtras extras;
```

| UDA                   | Field role                                                              |
| --------------------- | ----------------------------------------------------------------------- |
| `@SdlTagValue(index)` | Positional tag value beginning at zero-based `index`                    |
| `@SdlAttribute()`     | Named attribute; key resolves through `@WireName!Sdl` / `@WireCase!Sdl` |
| `@SdlChild()`         | Named child tag; sequences represent repeated sibling tags              |
| `@SdlTagName()`       | Dynamic local name of the containing tag                                |
| `@SdlTagNamespace()`  | Dynamic namespace of the containing tag                                 |
| `@SdlExtra()`         | Ordered unmatched values, attributes, and children (§8)                 |

All are format-specific by type: they have no effect under JSON and do not take
a format argument. Parentheses are mandatory, making UDA values uniform in the
schema. Each role UDA is preserved in the schema's open annotation list and is
also projected into the SDL format annotation consumed by the walker.

### 5.1 Default role and name resolution

An unannotated serializable aggregate field has role `SdlChild`. This makes a
plain struct naturally represent a document or tag containing named child tags.
`@WireName!Sdl` overrides the field's qualified SDL name. Otherwise the local
name is resolved through the shared case policy; the namespace is empty.

An explicit name containing `:` is split once into namespace and local name.
Empty halves and additional colons are compile-time errors. Dynamic
`@SdlTagName` and `@SdlTagNamespace` override the containing occurrence's static
identity and are data fields, not emitted payload fields.

### 5.2 Shape rules

- A scalar `SdlChild` field emits one child named for the field, with the scalar
  as value 0. An aggregate emits one named child whose body is that aggregate.
- A sequence `SdlChild` field with scalar-convertible elements emits one child
  whose positional values are the elements. Decode accepts repeated matching
  children and appends every positional value from each occurrence in source
  order; this covers both `authors "a" "b"` and a later `authors "c"`. A
  sequence with aggregate elements instead emits one sibling child per element,
  all with the resolved qualified name, and decode appends one aggregate per
  occurrence. Static scalar arrays use the scalar-sequence form and require the
  exact total value count.
- An associative array `SdlChild` field requires string or enum keys. Each entry
  is one child; the key is its local tag name and the field's resolved namespace
  is retained. Encode sorts by canonical encoded key for determinism; decode
  rejects duplicate keys because an AA cannot preserve them.
- An `SdlAttribute` field must be scalar-convertible. A sequence means repeated
  attributes with the same qualified name and preserves their order. An empty
  sequence emits none. Nested aggregates and maps are compile-time unsupported.
- `SdlTagValue` accepts a scalar-convertible field or a sequence/static array of
  scalar-convertible elements. Scalar positions must be unique. At most one
  dynamic sequence may consume a suffix, and it must have the greatest declared
  index. Static arrays occupy exactly their known number of positions.
- There may be at most one `SdlTagName`, one `SdlTagNamespace`, and one
  `SdlExtra` field per aggregate. Tag-name and namespace fields are `string` or
  name-represented enums. They are forbidden on the synthetic document root.
- A role whose selected shape cannot be represented is rejected when
  `wireSchemaOf!(Sdl, T)` is instantiated. The diagnostic names the aggregate,
  field, role, and required shape.

`@WireConvert`, `@WireAs`, checks, defaults, optionality, aliases, and metadata
apply at the same schema sites and with the same precedence as in the
expressiveness contract. Role selection happens outside conversion: conversion
changes the field's payload shape but not whether it is a value, attribute, or
child.

## 6. Typed mapping and repetitions

The root value for ordinary typed APIs must be an aggregate. Its child-role
fields consume top-level tags. `fromSDL!T` starts from `T.init`, applies shared
defaults/presence/conversion/check rules, and then fills fields from their role
channels.

For a non-root aggregate represented by a tag:

- values match by position, not by textual name;
- attributes match by full `(namespace, localName)` identity;
- children match by full identity and occurrence order;
- one scalar/aggregate child field requires exactly one occurrence unless it is
  optional/defaulted;
- a sequence child field accepts zero or more occurrences;
- repeated input for a singular field is a decode error at the second
  occurrence, never last-one-wins;
- an omitted required positional value, attribute, or singular child is a
  decode error at the containing tag's closing/terminating span.

Null maps only to null-aware targets and passthrough scalar values. SDL has no
container literal: arrays are represented through repeated values, attributes,
or child tags according to role. `SumType` uses the shared union policy; tagged
representations map their tag to a child/tag identity, not to a fabricated SDL
object. Each representation must be specified as an SDL schema annotation
before implementation; untagged trial decode remains available and retains
per-variant errors.

## 7. Errors and source context

All public operations return `Expected`; no throwing convenience API is
provided. `SdlError` is a plain value with:

- `SdlErrorStage` (`lex`, `parse`, `decode`, `encode`, `fileRead`, `fileWrite`);
- a stable `SdlErrorCode` suitable for tests and callers;
- source name and `SdlSpan` when input caused the failure;
- the D value path and SDL role path;
- source/target type and expected/actual kind where applicable;
- a bounded human-readable reason.

The stable code set includes at least `invalidUtf8`, `unsupportedBom`,
`unexpectedCharacter`, `unexpectedToken`, `unexpectedEof`, `unterminatedString`,
`unterminatedComment`, `invalidEscape`, `invalidIdentifier`, `invalidNumber`,
`numberOutOfRange`, `invalidBase64`, `invalidDate`, `invalidDateTime`,
`invalidDuration`, `depthExceeded`, `missingRole`, `duplicateRole`,
`unexpectedKind`, `valueOutOfRange`, `unknownMember`, `conversionFailed`,
`checkFailed`, `unsupportedFeature`, `allocationFailed`, `fileReadFailed`, and
`fileWriteFailed`.
Adding a code is source-compatible; changing the meaning of an existing code or
collapsing two listed classes into an unstructured message is not.

SDL role paths extend the base `$` path notation:

- `$<value[2]>` for positional value 2 of the root/current tag;
- `$.dependency[1]` for the second matching child occurrence;
- `$@optional` for an unnamespaced attribute;
- `$@x:platform` for a namespaced attribute;
- `$<name>` and `$<namespace>` for dynamic identity fields.

Nested paths compose, for example
`$.dependency[1]@version` or `$.configuration[0]<value[0]>`. Diagnostics render
source as `path(line:column)` followed by the role/value path. Parse errors point
at the offending token; unexpected EOF and missing closing braces point at the
zero-width EOF span while retaining the opening construct's span as secondary
context.

Errors from converters and checks are wrapped at the current role path without
discarding their reason. Error accumulation and caller context follow
[expressiveness §7](../expressiveness/SPEC.md#7-errors-accumulation-and-context).

## 8. Unknown fields and passthrough

Unknown handling is per aggregate and follows the shared three-way policy:

- **ignore** (default): unmatched values, attributes, and children are skipped;
- **forbid** (`@WireStrict!Sdl`): the first unmatched occurrence is an error;
- **preserve** (`@SdlExtra`): unmatched occurrences are captured and re-emitted.

`SdlExtras` is SDL-specific because an associative array cannot represent
duplicate names, namespaces, positional values, or source order. It stores
`SdlExtraMember` entries with channel (`value`, `attribute`, or `child`), the
channel ordinal, qualified name where present, scalar/node payload, and span.
Borrowed extras are valid only with their source document; an owned form is used
when extras must outlive it.

On encode, extras are merged into their original channel ordinal. Declared
members occupy their schema positions; a collision between an extra and a
declared singular value/attribute/child is an encode error. Repeated child or
attribute extras remain repeated. `@WireStrict!Sdl` and `@SdlExtra` on the same
aggregate are a compile-time contradiction.

The generic `@WireExtra` shape from the JSON contract is not silently reused for
SDL. A future shared extra protocol may subsume `@SdlExtra`, but only if it can
express this ordered, duplicate-preserving model without compatibility loss.

## 9. Canonical semantic writer

The writer is semantic, not lossless. It does not preserve comments, quote
choice, boolean aliases, numeric suffix case, continuation layout, or incidental
whitespace. `writeSdlDocument` and typed `writeSDL` produce one canonical form:

- UTF-8 without BOM;
- LF newlines and exactly one final LF for a non-empty document;
- four ASCII spaces per nesting level by default;
- one tag declaration per logical line;
- local/qualified names exactly as resolved by the schema;
- positional values first, then attributes, then children, each in model order;
- one ASCII space between adjacent values/attributes;
- the tag head followed by ` {` and LF for a child block, and `}` on its own
  indented line;
- no semicolons, comments, blank lines, or continuation backslashes.

Strings always use double quotes and escape `\`, `"`, LF, CR, and tab.
Characters use single quotes and the analogous character escapes. Booleans are
`true`/`false`; null is `null`; binary is one unbroken standard-Base64 literal.
Integers use decimal and `L` for `long`. Finite floats use shortest
round-tripping decimal text plus `F`, `D`, or `BD` for their kind. Non-finite
floating values are encode errors because SDL has no portable literal for them.
Dates, date-times, zones, and durations use fixed-width two-digit clock fields,
the shortest fractional precision that preserves the stored value, and the
stored zone spelling (canonical `GMT±HH:MM` when only an offset is available).

`SdlWriteOptions` may select another non-empty indentation string and whether an
empty document gets a final newline. It may not change scalar spelling, member
order, or semantic shape. Typed aggregate fields emit in declaration order;
sequence occurrences retain element order; AA entries sort lexicographically by
their canonical encoded key.

## 10. Round-trip laws

Three different laws are explicit:

1. **Document semantic law:** for every accepted document `s`,
   `parse(write(parse(s))) == parse(s)`, ignoring spans and source names.
2. **Canonical idempotence:** for every accepted document `s`,
   `write(parse(write(parse(s)))) == write(parse(s))` byte for byte.
3. **Typed value law:** when `isWireRoundTrippable!(Sdl, T)` is true,
   `fromSDL!T(toSDL(value)) == value`, modulo the asymmetries already declared
   by the shared schema contract.

Textual identity with the input is not promised. The writer may turn `on` into
`true`, a raw string into a quoted string, comments into nothing, and semicolons
into newlines. Unknown ignored input cannot satisfy a typed text round-trip;
`@SdlExtra` is required when preservation is part of the type's law.

## 11. Reader, writer, and file APIs

```d
struct SdlWriteOptions
{
    string indent = "    ";
    bool newlineForEmptyDocument = false;
}
```

`SdlParserConfig` is the compile-time value from §3.1. Disabling its
`validateUtf8` skips a separate validation pass but does not permit
invalid UTF-8 in identifiers, strings, characters, or source-location scanning;
encountering invalid input while decoding one of those remains an error.
`config.maxDepth == 0` permits root tags but no child block. The parser checks
depth before allocating a deeper node.

```d
SdlParseResult!Allocator parseSdlDocument(
    SdlParserConfig config = sdlFull,
    Allocator = Mallocator,
)(
    scope const(char)[] text,
    scope const(char)[] sourceName = null,
);

Expected!(void, SdlError) validateSDL(
    SdlParserConfig config = sdlFull,
)(
    scope const(char)[] text,
    scope const(char)[] sourceName = null,
);

Expected!(void, SdlError) writeSdlDocument(Document, Writer)(
    return scope const ref Document document,
    ref Writer writer,
    SdlWriteOptions options = SdlWriteOptions.init,
);

Expected!(T, SdlError) fromSDL(T,
    SdlParserConfig config = sdlParserConfigFor!T)(scope const(char)[] text);
Expected!(T, SdlError) fromSDL(T)(return scope SdlNode node);
Expected!(void, SdlError) writeSDL(T, Writer)(scope const ref T value, ref Writer writer);
Expected!(SdlString, SdlError) toSDL(T)(scope const ref T value);
Expected!(T, SdlError) readSDLFile(T)(scope const(char)[] path);
Expected!(void, SdlError) writeSDLFile(T)(scope const ref T value, scope const(char)[] path);
```

`SdlParseResult!Allocator` is `Expected!(SdlDocument!Allocator, SdlError)` (or a
layout-equivalent named wrapper exposing the same `Expected` operations). A
successful parse owns all decoded strings/binary data and does not borrow
`text`; this lets callers release the input while retaining the document.

`SdlString` is `SmallBuffer!(char, 256)`. Writer templates infer safety and
allocation attributes from the supplied writer. The default allocator path for
the document engine is `@safe pure nothrow @nogc` after allocation is expressed
through the allocator protocol; file helpers necessarily perform I/O and are
not `pure`.

`readSDLFile` reads bytes without path expansion, uses the path as source name,
parses, then decodes. `writeSDLFile` canonicalizes first, recursively creates
missing parent directories, writes a temporary file in the destination
directory, and atomically renames it over the target. It appends exactly one LF
to non-empty typed output. Failure leaves an existing target unchanged and
removes the temporary file where the platform permits.

## 12. Compatibility, provenance, and licensing

The syntax and conformance baseline for `sdlDubCompat` is DUB's bundled SDLang code under
`source/dub/internal/sdlang/`, especially `lexer.d`, `parser.d`, `token.d`, and
`ast.d`. DUB's `source/dub/recipe/sdl.d` supplies real-world evidence for
namespaces, repeated tags, positional values, attributes, nested tags, and
semantic read/write round-trips. `source/dub/internal/configy/` supplies design
evidence for typed structural filling, strict unknown-key handling, defaults,
source locations, and format-neutral node boundaries.

Those sources are evidence, not the target architecture. This backend uses
`Expected`, an ordered flat arena, borrowed views, the shared wired schema, and
no throwing class DOM. Compatibility means accepting the same valid SDL
language for enabled features and preserving its semantic distinctions; it does
not mean matching DUB's internal classes, source-coordinate rebasing, host
time-zone lookup, or exact exception strings. SDLite at
`b33048bf2d0c6b5df1b3b4b18e6cd83cb2f7aa81` supplies comparative evidence for
the borrowed forward-range and deferred-scalar architecture, but its accepted
language is not a conformance oracle.

DUB is MIT-licensed. Any source or test substantially ported from DUB must keep
the applicable MIT copyright and permission notice in the destination file or
the repository's third-party notices, and the test name/comment must identify
the DUB source path and upstream revision. Tests independently derived from the
published grammar or from black-box input/output cases must still include a
short attribution comment when the case selection came from DUB. No code may be
copied without completing that attribution/licensing step.

Configy's files identify the BOSAGORA Foundation (2019-2022) under MIT; copied
logic or tests from `configy/` require that notice as well. The implementation
plan therefore separates clean native design from explicitly attributed test
ports and includes a license audit before the backend is declared complete.
