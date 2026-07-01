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

| Module                          | Provides                                                                                                             |
| ------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| `sparkles.base.text.case_style` | `CaseStyle`, `convertCase!style(ident)`, `writeConvertedCase!style(w, ident)` — CTFE-compatible case conversion (§6) |
| `sparkles.base.text.enums`      | `enumMemberName!style(value)`, `enumFromValue!E(v)` — enum name ⇄ value primitives                                   |
| `sparkles.base.text.errors`     | `ParseError {code, offset, context}`, `ParseErrorCode`, `ParseExpected!T`                                            |

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
- **`Optional!T`** — JSON `null` ⇄ the empty (`none`) value; from the `optional`
  package (a dependency of `sparkles:wired`). Treated identically to `Nullable!T`:
  a maybe-value, never as the range/array it structurally resembles.
- **`Ternary`** — JSON `null` / `true` / `false`.
- **`SysTime`** — a UTC ISO-8601 extended string with an explicit UTC marker or
  offset (§4.4).
- **`JSONValue`** — passed through unchanged.

A `Nullable!T` or `Optional!T` must not **directly** wrap another null-aware type.
`Nullable`, `Optional`, or `Ternary` as the immediate contained type — for
example `Optional!(Nullable!int)`, `Nullable!Ternary`, or `Optional!(Optional!T)`
— is compile-time unsupported, because both the outer empty and an inner empty
would encode to JSON `null` and could not round-trip. A non-null-aware type in
between is fine (`Optional!(SomeStruct)` where `SomeStruct` has a `Nullable!int`
field), and `@WireConvert` (§8) can map an intentionally multi-state value to an
unambiguous wire shape.

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "wired_showcase"
    dependency "sparkles:wired" version="*"
+/
import std.stdio : writefln;
import std.sumtype : SumType;
import std.typecons : Nullable, Ternary;
import optional : Optional, some;
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
    show("Optional",    some(7));
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
Optional     7                            round-trips=true
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
- `char`, `wchar`, and `dchar` ⇄ a JSON string holding exactly one character
  that fits the target's single code unit: `char` holds one UTF-8 code unit
  (`U+0000`–`U+007F`), `wchar` one UTF-16 code unit (a BMP scalar, no lone
  surrogate), and `dchar` any one Unicode scalar value. Decoding requires the
  string to contain exactly one such scalar; an empty string, more than one
  character, or a character too wide for the target (a non-ASCII character into
  `char`, an astral character into `wchar`) is a decode error. Encoding a value
  that is not a valid standalone scalar (a non-ASCII `char` byte, a lone-surrogate
  `wchar`, or an out-of-range `dchar`) is an encode error — never a substituted
  placeholder. A field wanting a fallback instead of a hard failure on decode uses
  `@WireOptional(onInvalid: WireInvalid.useDefault)` (§5.4).
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
field value is `T.init`, an empty `Nullable!T`/`Optional!T`, or `Ternary.unknown`;
null-aware empties are encoded as explicit JSON `null`, not omitted. The
exception is a `@WireOptional` field, whose `WireSkip` policy (§5.4) can omit the
key entirely: the default `whenEmpty` omits an empty null-aware value instead of
writing `null`, and `whenDefault` omits any field value equal to `T.init`.

Aggregate decoding distinguishes a missing field from an explicit JSON `null`:

- A missing aggregate field is a decode error by default.
- A missing `Nullable!T` field decodes to the empty nullable value.
- A missing `Optional!T` field decodes to the empty (`none`) value.
- A missing `Ternary` field decodes to `Ternary.unknown`.
- A field annotated with `@WireOptional` is allowed to be missing; the field is
  left at the aggregate's D default value, including any field initializer.
- An unknown JSON object key is ignored.
- JSON `null` decodes successfully only for null-aware targets:
  - `Nullable!T` becomes the empty nullable value;
  - `Optional!T` becomes the empty (`none`) value;
  - `Ternary` becomes `Ternary.unknown`;
  - `JSONValue` is preserved unchanged as JSON `null`.
- JSON `null` for any other target type is a decode error, including scalar
  roots and non-nullable aggregate fields.
- A present field value that fails to decode as its type is a decode error by
  default; a field annotated `@WireOptional(onInvalid: WireInvalid.useDefault)`
  instead falls back to its default value (§5.4).

These rules apply recursively. For example, decoding `{"port": null}` into a
field `ushort port` fails instead of silently producing `0`; omitting `port`
also fails unless the field is annotated with `@WireOptional`. (Under
`@WireOptional(onInvalid: WireInvalid.useDefault)`, that `null` would instead
leave `port` at its default.)

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

Decoding attempts every variant in declaration order; how a tie is resolved is
selected per field by a `@(WireMatch.…)` attribute (§5), defaulting to
`WireMatch.exactlyOne`:

- `WireMatch.exactlyOne` (default) — if exactly one variant decodes successfully,
  the result is that variant; if none decode, decoding fails with an error listing
  the candidate variant types and their nested failure summaries; if more than one
  decodes, decoding fails with an ambiguity error listing the matching variant
  types.
- `WireMatch.first` — the result is the first variant that decodes successfully in
  declaration order; a later match is not consulted, so declaration order is the
  tie-breaker. If none decode, decoding fails with the same no-variant-matched
  error.

Under the default `exactlyOne`, variant order is not a disambiguation mechanism,
and **overlapping variants are ambiguous by construction — often not merely in
rare corners**. JSON `1` is ambiguous for `SumType!(int, long)`; any integer JSON
is ambiguous for `SumType!(int, double)`; JSON `"on"` is ambiguous for
`SumType!(string, Mode)` when `Mode.on` is a valid enum member; and two aggregates
where one's JSON object also satisfies the other are mutually ambiguous. For such
a type, either annotate the field with `@(WireMatch.first!F)` to take the first
variant in order, or use `@WireConvert` to map the `SumType` to an explicit tagged
wire shape when a stable discriminator is required.

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "wired_variant_match"
    dependency "sparkles:wired" version="*"
+/
import std.json : parseJSON;
import std.stdio : writeln;
import std.sumtype : SumType, match;
import sparkles.wired : fromJSON, WireMatch;

struct Row
{
    @(WireMatch.first)                 // integer JSON picks int, the first arm
    SumType!(int, double) cell;        // (exactlyOne would report an ambiguity)
}

void main()
{
    auto r = parseJSON(`{"cell": 42}`).fromJSON!Row.value;
    r.cell.match!(
        (int i)    => writeln("int ", i),
        (double d) => writeln("double ", d),
    );
}
```

```ansi
int 42
```

## 5. Policy UDAs

The `@Wire*` user-defined attributes configure (de)serialization. Each is
**format-aware** and defaults to `AnyFormat`; most `@Wire*` UDAs accept an
optional leading format template parameter, while `WireConvert` takes it as an
optional trailing template argument (§8) and `WireMatch` as a template argument on
the chosen strategy (§4.7). They may be stacked: format-specific overrides sit
alongside an `AnyFormat` default on the same symbol.

| UDA                                      | Attaches to                       | Effect                                                                 |
| ---------------------------------------- | --------------------------------- | ---------------------------------------------------------------------- |
| `@WireName!F("text")`                    | an enum member or aggregate field | the serialized member/field name under `F`                             |
| `@WireCase!F(CaseStyle[, WireTarget])`   | an enum/aggregate type or a field | recase every member/field name under `F` (§6)                          |
| `@WireRepr!F(Repr[, WireTarget])`        | an enum **type** or a **field**   | serialize by member name vs underlying value (§7)                      |
| `@WireOptional!F(WireSkip, WireInvalid)` | an aggregate field                | tune field absence, encode omission, and invalid-value handling (§5.4) |
| `@WireConvert!(toWire, fromWire[, F])`   | a **field** or **type**           | apply an arbitrary value transform at the boundary (§8)                |
| `@(WireMatch.strategy!F)`                | a `SumType` field                 | choose the `SumType` decode strategy (§4.7)                            |

```d
enum Repr { name, value }
enum WireTarget { all, key, value }
enum WireSkip { never, whenEmpty, whenDefault }
enum WireInvalid { reject, useDefault }
```

### 5.1 Accepted UDA forms

The untagged forms are aliases for `AnyFormat`; the format-specific forms apply
only under the named format:

```d
@WireName("wire-name")                  // AnyFormat
@WireName!Json("wire-name")             // Json only

@WireCase(CaseStyle.snakeCase)          // AnyFormat
@WireCase!Json(CaseStyle.snakeCase)     // Json only
@WireCase!Json(CaseStyle.snakeCase, WireTarget.all) // Json only, explicit default
@WireCase(CaseStyle.snakeCase, WireTarget.value) // AnyFormat, value slot only
@WireCase!Json(CaseStyle.snakeCase, WireTarget.key) // Json only, AA key slot only

@WireRepr(Repr.value)                   // AnyFormat
@WireRepr!Json(Repr.value)              // Json only
@WireRepr!Json(Repr.value, WireTarget.all) // Json only, explicit default
@WireRepr(Repr.value, WireTarget.value) // AnyFormat, value slot only
@WireRepr!Json(Repr.value, WireTarget.key) // Json only, AA key slot only

@WireOptional                           // AnyFormat; whenEmpty, reject (the defaults)
@WireOptional!Json                      // Json only
@WireOptional(WireSkip.whenDefault)     // omit any field at T.init on encode
@WireOptional(WireSkip.never)           // always emit; still missing-tolerant on decode
@WireOptional(onInvalid: WireInvalid.useDefault) // present-but-invalid → field default
@WireOptional(WireSkip.whenDefault, WireInvalid.useDefault)
@WireOptional!Json(WireSkip.never)      // Json only

@WireConvert!(toWire)                   // serialize-only, AnyFormat
@WireConvert!(toWire, fromWire)         // AnyFormat
@WireConvert!(toWire, fromWire, Json)   // Json only
@WireConvert!(toWire, void, Json)       // serialize-only, Json only

@(WireMatch.exactlyOne)                 // AnyFormat, explicit default
@(WireMatch.exactlyOne!Json)            // Json only
@(WireMatch.first)                      // AnyFormat
@(WireMatch.first!Json)                 // Json only
```

Most `@Wire*` UDAs take the format as their first template argument when a
format-specific policy is needed. The two exceptions are `WireConvert`, whose
format tag is a trailing template argument, and `WireMatch`, whose format tag is a
template argument on the chosen strategy (`WireMatch.first!Json`).

### 5.2 Resolution sites and precedence

A policy may be declared at the **type** (the type definition — the default for
every use of that type) or at a **field** (the use site — overriding the type
default for that field). Enum policies (`WireCase`, `WireRepr`, and enum-member
`WireName`) reach the field's enum **and one wrapper level** (`E[]`, `V[K]`,
`Nullable!E`, `Optional!E`); they do not descend into enums nested inside a
sub-`struct`.
Aggregate naming policies (`WireCase` on an aggregate type or aggregate-valued
field, plus field `WireName`) follow the same shape for aggregate field keys
(§5.3). `WireConvert` applies to the exact annotated type or to the whole
annotated field value (§8).

`WireTarget` selects which slot a field-level `WireCase` or `WireRepr` applies
to. `WireTarget.all` is also valid anywhere `WireCase` or `WireRepr` is
otherwise valid, including type declarations, because it is the explicit spelling
of the default.

- `WireTarget.all` is the default and keeps the broad field-level behavior:
  every eligible enum or aggregate reached at the field value and one wrapper
  level is affected. For `V[K]`, that includes both `K` and `V`.
- `WireTarget.key` targets only the key slot of an associative-array field.
- `WireTarget.value` targets only the value slot of an associative-array field
  (`V[K]`), the element slot of an array/slice field (`E[]`), or the contained
  value slot of a nullable or optional field (`Nullable!T`, `Optional!T`).

Slot-targeted `WireCase` / `WireRepr` forms (`WireTarget.key` or
`WireTarget.value`) are compile-time unsupported on type declarations, on fields
with no matching target slot, or when the selected slot has no supported policy
target (`WireRepr` targets enums; `WireCase` targets enums and aggregates).

When a broad field-level policy and a targeted field-level policy both apply,
the targeted policy wins for its slot:

```d
@WireRepr!Json(Repr.name)
@WireRepr!Json(Repr.value, WireTarget.key)
Status[Mode] states;  // Mode keys by value; Status values by name
```

To target both associative-array slots explicitly, use one targeted UDA per
slot:

```d
@WireRepr!Json(Repr.value, WireTarget.key)
@WireRepr!Json(Repr.name, WireTarget.value)
Status[Mode] states;  // Mode keys by value; Status values by name
```

Each axis resolves independently. Writing `F` for the active format and `Any` for
`AnyFormat`, the first match wins:

| Axis                  | Precedence                                                                                                                           |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| `repr`                | targeted field `!F` → targeted field `!Any` → broad field `!F` → broad field `!Any` → type `!F` → type `!Any` → `Repr.name`          |
| `case`                | targeted field `!F` → targeted field `!Any` → broad field `!F` → broad field `!Any` → type `!F` → type `!Any` → `CaseStyle.original` |
| `convert`             | field `!F` → field `!Any` → type `!F` → type `!Any` → no transform                                                                   |
| `optional`            | field `!F` → field `!Any` → absent                                                                                                   |
| `match` (`SumType`)   | field `@(WireMatch.x!F)` → field `@(WireMatch.x!Any)` → `WireMatch.exactlyOne`                                                       |
| enum member `name`    | member `@WireName!F` → member `@WireName!Any` → `convertCase!case(identifier)`                                                       |
| aggregate field `key` | field `@WireName!F` → field `@WireName!Any` → `convertCase!case(identifier)`                                                         |

Each axis resolves independently, but a resolved `WireConvert` is outermost: it
receives the source value before other policies inspect the transformed wire
value (§8). An explicit `@WireName` is used verbatim — it is never recased by
`@WireCase`.

### 5.3 Aggregate field names

Aggregate field keys are resolved like enum member names:

- `@WireCase!F(style)` on an aggregate type recases every field key of that
  aggregate under format `F`. `WireTarget.all` is allowed as an explicit
  spelling of the default. `WireTarget.key` and `WireTarget.value` are
  field-only selectors, so they are unsupported on aggregate type declarations.
- `@WireCase!F(style)` or `@WireCase!F(style, WireTarget.all)` on an
  aggregate-valued field is a use-site override for that field's aggregate value
  and one wrapper level (`S[]`, `S[K]`, `Nullable!S`, `Optional!S`); it does not
  rename the containing field itself.
- `@WireCase!F(style, WireTarget.value)` targets aggregate values in the
  associative-array value slot, array/slice element slot, or nullable/optional
  contained value slot. For example, on `Config[string] configs`, it recases the
  fields inside each `Config` value; on `Nullable!Config config` or
  `Optional!Config config`, it recases the fields inside the present `Config`
  value.
- `@WireCase!F(style, WireTarget.key)` does not target aggregate field-key
  casing. Aggregate values are not supported JSON object keys (§4.2), so there
  is no aggregate key slot to recase; the form is unsupported unless it applies
  to an enum key target under the enum policy rules.
- `@WireName!F("text")` on an aggregate field gives that field an explicit key
  under format `F`, overriding the aggregate's case policy.

Field `@WireName` renames only the field in its containing aggregate. It is not a
use-site policy for the field's value. An explicit field name is used verbatim
and is never recased by `@WireCase`. When resolving an aggregate field key, the
`case` in the `aggregate field key` row of §5.2 is the case policy resolved for
the aggregate currently being encoded or decoded.

### 5.4 Optional aggregate fields

`@WireOptional!F` marks an aggregate field as optional under format `F` and tunes
both edges of that field's (de)serialization through two independent parameters:

```d
enum WireSkip { never, whenEmpty, whenDefault }   // encode omission
enum WireInvalid { reject, useDefault }            // present-but-invalid decode

@WireOptional                                  // whenEmpty, reject (the defaults)
@WireOptional(WireSkip.whenDefault)
@WireOptional(WireSkip.never)
@WireOptional(onInvalid: WireInvalid.useDefault)
@WireOptional(WireSkip.whenDefault, WireInvalid.useDefault)
```

The defaults (`WireSkip.whenEmpty`, `WireInvalid.reject`) reproduce plain
`@WireOptional`: omit an empty null-aware value on encode, reject a malformed
present value on decode.

**Decode — absence.** Regardless of parameters, if the field key is absent,
decoding leaves the field at the aggregate's D default value, including any field
initializer.

**Decode — present but invalid.** `onInvalid` governs a present JSON value that
fails to decode as the field type:

- `WireInvalid.reject` (default) — the failure is a decode error, propagated with
  its nested path and reason.
- `WireInvalid.useDefault` — the field is left at the same default a missing key
  would produce (empty for a null-aware field, otherwise `T.init` or the field
  initializer). This also absorbs an explicit JSON `null` given for a
  non-null-aware field.

**Encode — omission.** `skip` governs when the field key is omitted from the
object entirely instead of being written:

- `WireSkip.whenEmpty` (default) — omit only when the field holds an empty
  null-aware value (empty `Nullable!T`/`Optional!T` or `Ternary.unknown`); every
  other field, including `@WireOptional int count;`, is emitted as specified.
- `WireSkip.whenDefault` — omit whenever the field value equals `T.init` (by
  `==`). For null-aware fields this coincides with `whenEmpty`; it additionally
  omits plain defaults such as `int` `0`, an empty `string` or array, and a
  `struct` at `.init`.
- `WireSkip.never` — always emit the field, even an empty null-aware value (which
  is then written as JSON `null`).

An omitted field round-trips because the same `@WireOptional` tolerates the
resulting missing key on decode.

`@WireOptional` is not implied by a D field initializer. A field initializer only
defines the value used when an optional field is absent — or, under
`WireInvalid.useDefault`, when its present value fails to decode.

Even without `@WireOptional`, a null-aware field (`Nullable!T`, `Optional!T`,
`Ternary`) is tolerated as missing on decode (§4.5) and is emitted as explicit
JSON `null` on encode. `@WireOptional` is distinct from the field's type: it adds
encode omission and `onInvalid` handling, and extends missing-tolerance to fields
of any type.

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

`@WireCase` and the default member/field naming (§5) select a case with the
`CaseStyle` enum, re-exported from `sparkles.wired`:

```d
enum CaseStyle { original, camelCase, pascalCase, snakeCase, kebabCase, screamingSnakeCase }
```

Names are recased by `convertCase!style(identifier)` from
`sparkles.base.text.case_style`, which splits an identifier into words (on
lower/digit→upper transitions, acronym-run boundaries, and explicit `_`/`-`/space
separators) and rejoins them in the chosen style — `fastPath` becomes
`fast_path`, `FAST_PATH`, or `FastPath`. `original` leaves the identifier
unchanged. The word-splitting and per-style rejoining rules, the CTFE contract,
and a full conversion table are the normative
[`sparkles.base.text.case_style` specification](../base/text/case-style.md).

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
value normally under the active format. If `toWire` returns
`Expected!(Value, Exception)`, the wire type is `Value`; otherwise, the wire type
is the plain return type of `toWire`.

On decode, the backend infers the wire type from `toWire` for the annotated
source type, decodes into that type, then returns `fromWire(raw)`. `fromWire` is
checked for callability with the inferred wire type; its parameter type is not
used for inference, so a generic lambda such as `ms => msecs(ms)` is valid. A
serialize-only converter (`fromWire` omitted or `void`) makes decoding that site
or type unsupported at compile time.

Converter functions must expose ordinary failures without throwing. A `toWire`
or `fromWire` callable is supported only if either:

- the selected call is `nothrow` and returns a plain value; or
- it returns `Expected!(Value, Exception)`.

An `Expected`-returning converter is unwrapped by the backend. Success continues
with `Value`; failure is propagated as the enclosing `toJSON` or `fromJSON`
error at the converter's current path. A converter call that is neither
`nothrow` nor `Expected`-returning is compile-time unsupported. Returned
`Expected` types whose error payload is not `Exception` are also unsupported.
Throwing converters are not a supported failure mechanism.

`WireConvert` owns the boundary it is attached to. Field `WireCase` and
`WireRepr` policies are not forwarded through a converter to the transformed
wire value; the transformed value is encoded or decoded according to its own
type policies and the active format.

When a field carries both `@WireConvert` and `@WireOptional`, the converter is
innermost to optionality — `@WireOptional` governs the field, the converter only
shapes a field that is actually present:

- On encode, `WireSkip` inspects the **source** field value (null-aware emptiness
  for `whenEmpty`; `value == T.init` for `whenDefault`), not the transformed wire
  value. If the field is omitted, `toWire` is not called; otherwise `toWire` runs
  and its result is emitted.
- On decode, `WireInvalid` wraps the **entire** field decode, including both the
  wire-type decode and `fromWire`. `WireInvalid.reject` propagates the first
  failure; `WireInvalid.useDefault` falls back to the field's default without
  invoking `fromWire`. An absent key likewise yields the field default and does
  not invoke the converter.

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
- `[0]` for array and slice elements;
- `.name` for object-key segments whose key text is identifier-safe
  (`[A-Za-z_][A-Za-z0-9_]*`);
- `["key"]` for all other object-key segments, using JSON string escaping.

Missing required fields report the path to the missing field, such as
`$.server.port`. Aggregate fields use the resolved wire key as the object-key
segment; associative-array entries use the JSON object key text. A resolved key
such as `server.port` is therefore reported as `$["server.port"]`, not
`$.server.port`, and a key requiring string escaping is reported with JSON
string escapes, such as `$["quote\"key"]`. `SumType` variant diagnostics list
candidate or matching variant type names, but the path remains at the same JSON
location. Unknown enum values include the resolved candidate names
(`expected one of: ...`).

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
                         // WireTarget, WireOptional, WireConvert, WireMatch,
                         // Repr, CaseStyle, WireSkip, WireInvalid
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
