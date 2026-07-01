# `sparkles:wired` — Specification

_Audience: developers and coding agents building against the library. This
document is normative and self-contained — it states what the library
provides, not why. For the delivery plan, see [PLAN.md](./PLAN.md); for the
library overview, see [`sparkles:base`](../../libs/base/index.md)._

## 1. Overview

`sparkles:wired` maps D values to and from a serialized representation across
pluggable **formats**. A format is selected at the call site; **JSON** ships as
the first concrete format, built on `std.json`.

The mapping is derived by structural introspection — no schema, no registration,
no code generation — and is configurable per format with a small family of
`@Wire*` user-defined attributes (§5). Encoding, decoding, and JSON file helpers
are [`Expected`](#9-errors)-based; there are no throwing wrapper functions.

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "wired_overview"
    dependency "sparkles:wired" version="*"
+/
import std.stdio : writeln;
import sparkles.wired : toJSON, fromJSON;

struct Server { string host; ushort port; string[] tags; }

void main()
{
    auto s = Server("localhost", 8080, ["web", "edge"]);
    auto json = s.toJSON;                       // value → Expected!(JSONValue, Exception)
    writeln(json.value.toString);               // object keys emitted sorted
    auto roundTrip = json.value.fromJSON!Server;
    writeln(roundTrip.value == s);              // JSONValue → value (round-trips)
}
```

```ansi
{"host":"localhost","port":8080,"tags":["web","edge"]}
true
```

## 2. Package and module layout

| Identifier      | Value                            |
| --------------- | -------------------------------- |
| Dub sub-package | `sparkles:wired`                 |
| Source root     | `libs/wired/src/sparkles/wired/` |
| Package module  | `sparkles.wired`                 |

| Module                  | Contents                                                                                                              |
| ----------------------- | --------------------------------------------------------------------------------------------------------------------- |
| `sparkles.wired`        | Public re-exports (`package.d`)                                                                                       |
| `sparkles.wired.policy` | `AnyFormat`, `Repr`, the `@Wire*` UDAs (`WireName`, `WireCase`, `WireRepr`, `WireOptional`, `WireConvert`), resolvers |
| `sparkles.wired.json`   | `struct Json {}` (the JSON format marker) + the JSON backend (`toJSON`, `fromJSON`, `readJSONFile`, `writeJSONFile`)  |

Each format module owns its own marker type (§3); there is no central format
registry.

**Foundation in `sparkles:base`** — the format-agnostic text primitives live in
`base`, not in `wired`:

| Module                          | Provides                                                                           |
| ------------------------------- | ---------------------------------------------------------------------------------- |
| `sparkles.base.text.case_style` | `CaseStyle`, `convertCase!style(ident)` — CTFE-compatible case conversion (§6)     |
| `sparkles.base.text.enums`      | `enumMemberName!style(value)`, `enumFromValue!E(v)` — enum name ⇄ value primitives |
| `sparkles.base.text.errors`     | `ParseError {code, offset, context}`, `ParseErrorCode`, `ParseExpected!T`          |

## 3. The Format concept

A **format** is a marker type. The library ships `struct Json {}` (in
`sparkles.wired.json`). A new format is just a new type — anyone, including a
third-party package, may define one:

```d
struct Json {}        // shipped, in sparkles.wired.json
struct Toml {}        // a user- or library-defined marker

struct AnyFormat {}   // the sentinel: an untagged @Wire* UDA applies to all formats
```

Every `@Wire*` UDA (§5) is format-aware and defaults to `AnyFormat`. A value is
(de)serialized **under** one format — `toJSON` operates under `Json` — and policy
is resolved relative to that format: the most format-specific UDA wins, falling
back to the `AnyFormat` form, then to the built-in default.

## 4. The JSON backend

`sparkles.wired.json` (re-exported from `sparkles.wired`) serializes under the
`Json` format. Its surface:

| Symbol                                                                          | Description                                                                |
| ------------------------------------------------------------------------------- | -------------------------------------------------------------------------- |
| `toJSON(value) → Expected!(JSONValue, Exception)`                               | Encode without throwing; a failure is captured as the `Exception` payload. |
| `fromJSON!T(JSONValue) → Expected!(T, Exception)`                               | Decode without throwing; a failure is captured as the `Exception` payload. |
| `readJSONFile!T(string path) → Expected!(T, Exception)`                         | Read, parse, and decode a file without throwing.                           |
| `writeJSONFile(value, path, bool compact = false) → Expected!(void, Exception)` | Encode and write a file without throwing.                                  |

### 4.1 File helpers

`readJSONFile!T(path)` reads UTF-8 text from `path`, parses it with
`std.json.parseJSON`, then decodes with `fromJSON!T`. It performs no path
expansion and uses no search paths.

Failures are returned as `Expected!(T, Exception)` errors. The error message
identifies the failing stage (read, parse, or decode) and preserves the original
exception as the cause where one exists.

`writeJSONFile(value, path, compact = false)` encodes `value` with `toJSON`,
creates the parent directory when `path` has one, and writes UTF-8 text to
`path`, overwriting any existing file.

- `compact == false` renders with
  `json.toPrettyString(JSONOptions.doNotEscapeSlashes)`.
- `compact == true` renders with `json.toString(JSONOptions.doNotEscapeSlashes)`.
- Both modes append exactly one final Unix newline (`\n`) after the rendered JSON
  text.

Failures are returned as `Expected!(void, Exception)` errors. The error message
identifies the failing stage (encode, create parent directory, or write) and
preserves the original exception as the cause where one exists.

### 4.2 Supported types

Encoding and decoding cover, in both directions:

- **Scalars** — `bool`, `string`, `char`, integral and floating-point types.
- **Enums** — by member name or underlying value, per the policy of §5/§7.
- **Arrays / slices** — of any supported element type.
- **Associative arrays** — keyed by `string` or by an enum; enum keys follow
  the enum representation rules of §7.
- **Aggregates** (`struct`) — field by field, under their resolved field keys
  (§5.3).
- **`SumType`** — encoded as its active variant; decoding succeeds only when
  exactly one variant matches (§4.7).
- **`Nullable!T`** — JSON `null` ⇄ the empty value.
- **`Ternary`** — JSON `null` / `true` / `false`.
- **`SysTime`** — a UTC ISO-8601 extended string with an explicit UTC marker or
  offset (§4.4).
- **`JSONValue`** — passed through unchanged.

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "wired_showcase"
    dependency "sparkles:wired" version="*"
+/
import std.stdio : writefln;
import std.sumtype : SumType;
import std.typecons : Nullable, Ternary;
import sparkles.wired : fromJSON, toJSON;

enum Suit { spades, hearts }
struct Card { Suit suit; int rank; }
alias Cell = SumType!(int, string);

void show(T)(string label, T value)
{
    auto json = value.toJSON.value;     // encode
    auto back = json.fromJSON!T.value;  // decode again
    writefln("%-12s %-28s round-trips=%s", label, json.toString, back == value);
}

void main()
{
    show("int",         42);
    show("double",      3.5);
    show("bool",        true);
    show("string",      "hi");
    show("enum",        Suit.hearts);
    show("enum[]",      [Suit.spades, Suit.hearts]);
    show("int[string]", ["a": 1, "b": 2]);
    show("int[Suit]",   [Suit.spades: 1, Suit.hearts: 2]);
    show("struct",      Card(Suit.hearts, 10));
    show("SumType",     Cell("text"));
    show("Nullable",    Nullable!int(7));
    show("Ternary",     Ternary.unknown);
}
```

```ansi
int          42                           round-trips=true
double       3.5                          round-trips=true
bool         true                         round-trips=true
string       "hi"                         round-trips=true
enum         "hearts"                     round-trips=true
enum[]       ["spades","hearts"]          round-trips=true
int[string]  {"a":1,"b":2}                round-trips=true
int[Suit]    {"hearts":2,"spades":1}      round-trips=true
struct       {"rank":10,"suit":"hearts"}  round-trips=true
SumType      "text"                       round-trips=true
Nullable     7                            round-trips=true
Ternary      null                         round-trips=true
```

JSON object keys are emitted in sorted order (a `std.json` property), so struct
fields and AA keys appear alphabetically regardless of declaration order.

### 4.3 Scalar and array mapping

JSON decoding is strict about the JSON value kind. There is no implicit
string-to-number, number-to-string, bool-to-number, or number-to-bool coercion.

Scalar mapping:

- `bool` ⇄ a JSON boolean.
- `string` ⇄ a JSON string.
- `char`, `wchar`, and `dchar` ⇄ a JSON string containing exactly one decoded
  character.
- Integral types ⇄ JSON integer numbers; decoding checks that the JSON number is
  integral and within the destination type's range.
- Floating-point types ⇄ JSON numbers; decoding accepts both integer and
  floating JSON numbers. `NaN` and infinity are rejected unless a future policy
  explicitly opts into them.

Array and slice mapping:

- Character arrays and slices (`char[]`, `wchar[]`, `dchar[]`, plus immutable
  string aliases) encode as JSON strings and decode from JSON strings.
- Non-character arrays and slices encode as JSON arrays and decode only from
  JSON arrays.

### 4.4 `SysTime` mapping

`SysTime` encodes as a JSON string containing an ISO-8601 extended timestamp.
Encoding normalizes the value to UTC before formatting, and the emitted string
must include an explicit UTC marker or numeric UTC offset.

Decoding accepts only JSON strings accepted by `SysTime.fromISOExtString` that
also include an explicit UTC marker or numeric UTC offset. Offsetless timestamp
strings are rejected rather than interpreted in a local timezone or assumed to be
UTC. Decoded values are normalized to UTC.

### 4.5 Aggregate fields, missing keys, and `null`

Aggregate encoding includes every serializable field by default, even when the
field value is `T.init`, `Nullable!T.init`, or `Ternary.unknown`. Null-aware
values are encoded as explicit JSON `null`; no field is omitted by default.

Aggregate decoding distinguishes a missing field from an explicit JSON `null`:

- A missing aggregate field is a decode error by default.
- A missing `Nullable!T` field decodes to the empty nullable value.
- A missing `Ternary` field decodes to `Ternary.unknown`.
- A field annotated with `@WireOptional` is allowed to be missing; the field is
  left at the aggregate's D default value, including any field initializer.
- An unknown JSON object key is ignored.
- JSON `null` decodes successfully only for null-aware targets:
  - `Nullable!T` becomes the empty nullable value;
  - `Ternary` becomes `Ternary.unknown`;
  - `JSONValue` is preserved unchanged as JSON `null`.
- JSON `null` for any other target type is a decode error, including scalar
  roots and non-nullable aggregate fields.

These rules apply recursively. For example, decoding `{"port": null}` into a
field `ushort port` fails instead of silently producing `0`; omitting `port`
also fails unless the field is annotated with `@WireOptional`.

### 4.6 Aggregate field set and construction

Structural aggregate support covers `struct` instance storage fields:

- Static fields are ignored.
- Methods, properties, aliases, nested types, and `alias this` are ignored.
- Field declaration order is used for policy resolution, collision checks, and
  diagnostics; JSON output still sorts object keys when rendered by `std.json`.

Visibility is respected. A field is serializable only when the backend's
generated code can legally access it through D's normal visibility rules from
the instantiation context. If any required structural field cannot be legally
accessed, the aggregate is compile-time unsupported unless a `@WireConvert`
maps it to a supported wire type.

Structural decoding creates `T result = T.init;` and assigns fields directly.
Types that cannot be default-initialized, or fields that cannot be assigned
during decoding, are compile-time unsupported unless a `@WireConvert` maps the
aggregate to a decodable wire type. Structural encoding uses the same supported
field set as decoding so default structural support remains round-trip oriented.

### 4.7 `SumType` decoding

`SumType` uses an untagged representation: encoding writes the active variant
exactly as that variant would be encoded on its own.

Decoding validates every variant in declaration order:

- If exactly one variant decodes successfully, the result is that variant.
- If no variant decodes successfully, decoding fails with an error listing the
  candidate variant types and their nested failure summaries.
- If more than one variant decodes successfully, decoding fails with an
  ambiguity error listing the matching variant types.

Variant order is not a disambiguation mechanism. For example, JSON `1` is
ambiguous for `SumType!(int, long)`, and JSON `"on"` is ambiguous for
`SumType!(string, Mode)` when `Mode.on` is a valid enum member. Users who need a
stable discriminator should use `@WireConvert` to map the `SumType` to an
explicit tagged wire shape.

## 5. Policy UDAs

Five user-defined attributes configure (de)serialization. Each is
**format-aware** and defaults to `AnyFormat`; `WireName`, `WireCase`,
`WireRepr`, and `WireOptional` take the format as their template parameter,
while `WireConvert` takes it as an optional trailing template argument (§8).
They may be stacked: format-specific overrides sit alongside an `AnyFormat`
default on the same symbol.

| UDA                                    | Attaches to                       | Effect                                                  |
| -------------------------------------- | --------------------------------- | ------------------------------------------------------- |
| `@WireName!F("text")`                  | an enum member or aggregate field | the serialized member/field name under `F`              |
| `@WireCase!F(CaseStyle)`               | an enum/aggregate type or a field | recase every member/field name under `F` (§6)           |
| `@WireRepr!F(Repr)`                    | an enum **type** or a **field**   | serialize by member name vs underlying value (§7)       |
| `@WireOptional!F`                      | an aggregate field                | allow the field key to be absent on decode              |
| `@WireConvert!(toWire, fromWire[, F])` | a **field** or **type**           | apply an arbitrary value transform at the boundary (§8) |

```d
enum Repr { name, value }
```

### 5.1 Accepted UDA forms

The untagged forms are aliases for `AnyFormat`; the format-specific forms apply
only under the named format:

```d
@WireName("wire-name")                  // AnyFormat
@WireName!Json("wire-name")             // Json only

@WireCase(CaseStyle.snakeCase)          // AnyFormat
@WireCase!Json(CaseStyle.snakeCase)     // Json only

@WireRepr(Repr.value)                   // AnyFormat
@WireRepr!Json(Repr.value)              // Json only

@WireOptional                           // AnyFormat
@WireOptional!Json                      // Json only

@WireConvert!(toWire)                   // serialize-only, AnyFormat
@WireConvert!(toWire, fromWire)         // AnyFormat
@WireConvert!(toWire, fromWire, Json)   // Json only
@WireConvert!(toWire, void, Json)       // serialize-only, Json only
```

`WireConvert` is the only `@Wire*` UDA whose format tag is a trailing template
argument. All other `@Wire*` UDAs take the format as their first template
argument when a format-specific policy is needed.

### 5.2 Resolution sites and precedence

A policy may be declared at the **type** (the type definition — the default for
every use of that type) or at a **field** (the use site — overriding the type
default for that field). Enum policies (`WireCase`, `WireRepr`, and enum-member
`WireName`) reach the field's enum **and one wrapper level** (`E[]`, `V[K]`,
`Nullable!E`); they do not descend into enums nested inside a sub-`struct`.
Aggregate naming policies (`WireCase` on an aggregate type or aggregate-valued
field, plus field `WireName`) follow the same shape for aggregate field keys
(§5.3). `WireConvert` applies to the exact annotated type or to the whole
annotated field value (§8).

Each axis resolves independently. Writing `F` for the active format and `Any` for
`AnyFormat`, the first match wins:

| Axis                  | Precedence                                                                     |
| --------------------- | ------------------------------------------------------------------------------ |
| `repr`                | field `!F` → field `!Any` → type `!F` → type `!Any` → `Repr.name`              |
| `case`                | field `!F` → field `!Any` → type `!F` → type `!Any` → `CaseStyle.original`     |
| `convert`             | field `!F` → field `!Any` → type `!F` → type `!Any` → no transform             |
| `optional`            | field `!F` → field `!Any` → absent                                             |
| enum member `name`    | member `@WireName!F` → member `@WireName!Any` → `convertCase!case(identifier)` |
| aggregate field `key` | field `@WireName!F` → field `@WireName!Any` → `convertCase!case(identifier)`   |

Each axis resolves independently, but a resolved `WireConvert` is outermost: it
receives the source value before other policies inspect the transformed wire
value (§8). An explicit `@WireName` is used verbatim — it is never recased by
`@WireCase`.

### 5.3 Aggregate field names

Aggregate field keys are resolved like enum member names:

- `@WireCase!F(style)` on an aggregate type recases every field key of that
  aggregate under format `F`.
- `@WireCase!F(style)` on an aggregate-valued field is a use-site override for
  that field's aggregate value and one wrapper level (`S[]`, `S[K]`,
  `Nullable!S`); it does not rename the containing field itself.
- `@WireName!F("text")` on an aggregate field gives that field an explicit key
  under format `F`, overriding the aggregate's case policy.

Field `@WireName` renames only the field in its containing aggregate. It is not a
use-site policy for the field's value. An explicit field name is used verbatim
and is never recased by `@WireCase`. When resolving an aggregate field key, the
`case` in the `aggregate field key` row of §5.2 is the case policy resolved for
the aggregate currently being encoded or decoded.

### 5.4 Optional aggregate fields

`@WireOptional!F` is a decode-only policy for aggregate fields. Under format `F`,
if the field key is absent, decoding leaves the field at the aggregate's D
default value, including any field initializer. It does not affect encoding:
optional fields are still emitted like any other serializable field.

`@WireOptional` is not implied by a D field initializer. A field initializer only
defines the value used when an explicitly optional field is absent.

### 5.5 Name and value uniqueness

For a type used with `wired`, enum declared underlying values must be unique. D
does not preserve which declared member produced a duplicate runtime value, so a
duplicate-valued enum is ambiguous even when serialized by `Repr.name`.

Resolved textual names must also be unique for the active format:

- Enum member names under `Repr.name` must be unique after `WireName` and
  `WireCase` resolution.
- Aggregate field keys must be unique after field `WireName` and aggregate
  `WireCase` resolution.

These checks are per active format. Names that collide under `Json` do not imply
a collision under another format unless that format resolves the same duplicate
names.

Collisions are unsupported at compile time when the relevant encoder or decoder
is instantiated. Implementations may rely on generated `switch` / `final switch`
statements to let the D compiler reject duplicate `case` labels, or may use an
equivalent CTFE uniqueness check.

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "wired_policy"
    dependency "sparkles:wired" version="*"
+/
import std.stdio : writeln;
import sparkles.wired : toJSON, WireName, WireCase, CaseStyle, Json;

struct Toml {}   // a marker for another format; tags below are inert under Json

@WireCase!Json(CaseStyle.snakeCase)            // JSON: recase every member
enum Mode
{
    fastPath,                                  // → "fast_path"
    @WireName!Json("turbo")                    // JSON: explicit name (beats the recase)
    @WireName!Toml("warp")                     // ignored when serializing under Json
    boostMode,
}

void main()
{
    writeln([Mode.fastPath, Mode.boostMode].toJSON.value.toString);
}
```

```ansi
["fast_path","turbo"]
```

## 6. Case styles

`sparkles.base.text.case_style` (re-exported from `sparkles.wired`) provides:

```d
enum CaseStyle { original, camelCase, pascalCase, snakeCase, kebabCase, screamingSnakeCase }

string convertCase(CaseStyle style)(string ident);   // CTFE-compatible
```

`convertCase` splits `ident` into words, then rejoins per `style`. Word
boundaries are:

1. a lowercase or digit immediately followed by an uppercase (`fastPath` →
   `fast`,`Path`);
2. an uppercase that begins a new word after an acronym run — an uppercase
   followed by an uppercase-then-lowercase (`JSONValue` → `JSON`,`Value`);
3. an explicit separator (`_`, `-`, or space), which is consumed.

`original` returns the identifier unchanged. `camelCase`/`pascalCase` lowercase
each word and capitalize its first letter (acronyms fold to title case:
`JSON` → `Json`), differing only in the first word. `snakeCase`/`kebabCase` join
lowercased words with `_`/`-`. `screamingSnakeCase` joins uppercased words with `_`.

`convertCase` must be usable during CTFE so policy resolution can derive enum
member names at compile time without requiring the identifier itself to be a
template argument. The implementation must include `static assert` coverage for
every `CaseStyle`, including acronym, digit, and explicit-separator cases.

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "wired_case_styles"
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

## 7. Enum representation

`@WireRepr` selects between two representations:

- `Repr.name` (default) — the member's serialized name (§5/§6), honoring any
  `@WireName` override.
- `Repr.value` — the underlying value. The underlying value is taken via
  `OriginalType!E`, so non-integer-backed enums work too: encoding delegates to
  `toJSON(cast(OriginalType!E) value)` and propagates any error.

Decoding by name matches the resolved candidate names; an unknown token fails with
an `"expected one of: …"` context. Decoding by value first decodes an
`OriginalType!E`, then rejects any underlying value that is not equal to a
declared enum member. Encoding an enum value that is not a declared member is an
encode error.

For JSON object keys where the key type is an enum:

- `Repr.name` uses the resolved member name as the key text.
- `Repr.value` uses the scalar JSON representation as key text: string
  underlying values use the unescaped string itself; character underlying values
  use the one-character string itself; bool and numeric underlying values use
  the JSON literal text produced by successfully encoding
  `cast(OriginalType!E) value`. Decoding parses that key text back to
  `OriginalType!E`, then applies the same declared-member validation as value
  decoding.

For example, `enum Priority { low = 1, high = 5 }` as an associative-array key
under `Repr.value` uses JSON keys `"1"` and `"5"`, while
`enum Mode : string { fast = "fast-path" }` uses the JSON key `"fast-path"`.

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "wired_enum_repr"
    dependency "sparkles:wired" version="*"
+/
import std.stdio : writeln;
import sparkles.wired : toJSON, fromJSON, WireRepr, Repr, Json;

@WireRepr!Json(Repr.value)
enum Priority { low = 1, high = 5 }

void main()
{
    auto json = Priority.high.toJSON.value;     // serialized under Json → by value
    writeln(json.toString);
    writeln(json.fromJSON!Priority.value == Priority.high);
}
```

```ansi
5
true
```

## 8. Value transforms

`@WireConvert!(toWire, fromWire)` applies an arbitrary transform at the wire
boundary. It applies to any type, not only enums — `@WireRepr(Repr.value)` is the
enum-specific special case of the same idea (`toWire = cast to OriginalType`).

Accepted forms:

```d
@WireConvert!(toWire, fromWire)        // AnyFormat
@WireConvert!(toWire, fromWire, Json)  // Json only
@WireConvert!(toWire)                  // serialize-only, AnyFormat
@WireConvert!(toWire, void, Json)      // serialize-only, Json only
```

Resolution follows the `convert` axis in §5.2; exactly one converter applies.
Field-level converters apply to the whole field value, not to elements inside
wrappers. Type-level converters apply whenever that exact annotated type is
encoded or decoded.

On encode, the backend calls `toWire(value)` and then encodes the returned wire
value normally under the active format. On decode, the backend infers the wire
type from the first parameter of `fromWire`, decodes into that type, then returns
`fromWire(raw)`. A serialize-only converter (`fromWire` omitted or `void`) makes
decoding that site or type unsupported at compile time.

`WireConvert` owns the boundary it is attached to. Field `WireCase` and
`WireRepr` policies are not forwarded through a converter to the transformed
wire value; the transformed value is encoded or decoded according to its own
type policies and the active format.

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "wired_convert"
    dependency "sparkles:wired" version="*"
+/
import core.time : Duration, msecs;
import std.stdio : writeln;
import sparkles.wired : toJSON, fromJSON, WireConvert;

struct Timer
{
    @WireConvert!(d => d.total!"msecs", ms => msecs(ms))
    Duration timeout;
}

void main()
{
    auto t = Timer(1500.msecs);
    auto json = t.toJSON.value;
    writeln(json.toString);                 // Duration encoded as its millisecond count
    writeln(json.fromJSON!Timer.value == t); // round-trips back to a Duration
}
```

```ansi
{"timeout":1500}
true
```

## 9. Errors

Encoding, decoding, and file I/O are `Expected`-based. The error vocabulary is
generic and lives in `sparkles.base.text.errors`; the JSON backend's `toJSON`,
`fromJSON`, `readJSONFile`, and `writeJSONFile` carry failures as `Exception`
payloads. The JSON backend does not provide throwing wrapper functions.

Decode error messages must include enough context to identify the failing value:

- the target type being decoded;
- a compact JSON kind/value summary;
- the path from the root JSON value to the failing location;
- the reason for the failure.

Encode error messages must include enough context to identify the failing value:

- the source type being encoded;
- the path from the root D value to the failing location;
- the reason for the failure.

Error paths use this syntax:

- `$` for the root value;
- `.fieldName` for aggregate fields, using the resolved wire key;
- `[0]` for array and slice elements;
- `["key"]` for associative-array entries, using the JSON object key text.

Missing required fields report the path to the missing field, such as
`$.server.port`. `SumType` variant diagnostics list candidate or matching
variant type names, but the path remains at the same JSON location. Unknown enum
values include the resolved candidate names (`expected one of: ...`).

Exact full message strings are not part of the contract, but those path and
reason fragments are. For example:

```text
Cannot decode ushort at $.server.port from JSON null: null is not allowed for non-nullable fields
```

`readJSONFile` decode-stage failures and `writeJSONFile` encode-stage failures
prepend file context while preserving the nested error path.

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "wired_errors"
    dependency "sparkles:wired" version="*"
+/
import std.json : parseJSON;
import std.stdio : writeln;
import sparkles.wired : fromJSON;

enum Mode { off, on, automatic }

void main()
{
    // fromJSON never throws — it returns Expected!(T, Exception).
    auto good = parseJSON(`"on"`).fromJSON!Mode;
    writeln("value: ", good.hasValue, " ", good.value);

    auto bad = parseJSON(`"sideways"`).fromJSON!Mode;
    writeln("error: ", bad.hasError);
    writeln("       ", bad.error.msg);
}
```

```ansi
value: true on
error: true
       Cannot decode Mode at $ from JSON string "sideways": expected one of: off, on, automatic
```

## 10. Public API surface

A consumer of one format imports the package module:

```d
import sparkles.wired;   // toJSON, fromJSON, readJSONFile, writeJSONFile, Json,
                         // AnyFormat, WireName, WireCase, WireRepr,
                         // WireOptional, WireConvert, Repr, CaseStyle
```

A type author annotates enum members and fields with the `@Wire*` UDAs; no base
class or registration is involved — the annotations are read at compile time when
the value is (de)serialized.

A **format author** — defining a new wire format — declares a marker type and
implements that format's backend; the `@Wire*` UDAs already accept it as a tag:

```d
struct Toml {}

@WireCase!Toml(CaseStyle.kebabCase)   // members render kebab-case under Toml,
@WireCase!Json(CaseStyle.snakeCase)   // snake_case under Json,
enum Mode { fastPath, slowPath }      // and as-written under any other format
```

---

→ [PLAN.md](./PLAN.md) — delivery milestones
→ [`sparkles:base`](../../libs/base/index.md) — the text/case primitives this builds on
