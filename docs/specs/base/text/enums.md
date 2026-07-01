# `sparkles.base.text.enums` — Specification

_Audience: developers and coding agents building against `sparkles:base`. This
document is normative and self-contained — it states how the module maps an enum
to and from its textual name and its underlying value. It is a format-agnostic
text primitive with **no serialization or UDA policy**; a policy layer such as
[`sparkles:wired`](../../wired/SPEC.md) is one consumer. For the library overview
see [`sparkles:base`](../../../libs/base/index.md)._

## 1. Overview

`sparkles.base.text.enums` provides the two directions of enum ↔ text/value
conversion that higher layers build on:

- **name** — an enum value's serialized member name, optionally recased by a
  [`CaseStyle`](./case-style.md);
- **value** — an enum's underlying value, taken via `OriginalType` so that
  non-integer-backed enums work too.

The module is unopinionated: it applies no per-member name overrides (those are a
policy concern for a layer like `@WireName` in `sparkles:wired`). It only knows
how to render a declared member's identifier — optionally recased — and how to
validate an underlying value back into a declared member.

| Identifier      | Value                               |
| --------------- | ----------------------------------- |
| Dub sub-package | `sparkles:base`                     |
| Source root     | `libs/base/src/sparkles/base/text/` |
| Module          | `sparkles.base.text.enums`          |

## 2. API surface

```d
// value → its member name, recased per `style` (a compile-time string literal).
string enumMemberName(CaseStyle style = CaseStyle.original, E)(in E value)
if (is(E == enum));

// membership-checked underlying value → enum.
ParseExpected!E enumFromValue(E)(OriginalType!E value)
if (is(E == enum));
```

`CaseStyle` and `convertCase` come from
[`sparkles.base.text.case_style`](./case-style.md); `ParseExpected` and
`ParseError` from [`sparkles.base.text.errors`](./index.md). `style` is a template
parameter, so both the member name and its recasing are compile-time constants
(§4).

The inverse directions live in the sibling reader/writer modules and share this
policy:

- `readEnumString!(E, CaseStyle style = CaseStyle.original)`
  (`sparkles.base.text.readers`) — the name → enum reader, matching each member's
  `enumMemberName!style` text.
- `writeEnumMemberName!style` / `writeEnumValue`
  (`sparkles.base.text.writers`) — the output-range writers for the name and
  value directions.

## 3. Name and value semantics

### 3.1 `enumMemberName`

`enumMemberName!style(value)` returns the recased identifier of the declared
member equal to `value`:

- The member identifier is recased with `convertCase!style` (§ [case
  styles](./case-style.md)). `CaseStyle.original` returns the identifier verbatim.
- The result is a compile-time string literal selected by a `final switch` over
  the enum's members, so the call allocates nothing and is `@safe pure nothrow
@nogc`.
- `value` must be a declared member of `E`. A value that is not a declared member
  (for example a cast-in out-of-range value) is a programming error, not a
  recoverable outcome.

Because a `final switch` requires each member to map to a distinct `case`, an
enum with duplicate underlying values is rejected at compile time when
`enumMemberName` is instantiated for it.

### 3.2 `enumFromValue`

`enumFromValue!E(value)` validates an underlying value back into an enum:

- The parameter type is `OriginalType!E`, so an `enum : string`, `enum : char`,
  or any non-integer-backed enum is supported, not only integral enums.
- If `value` equals the underlying value of a declared member, the result is
  `parseOk` of that member.
- Otherwise the result is a `ParseError` with code
  `ParseErrorCode.unknownValue` and an `"expected one of: …"` context listing the
  declared underlying values.

`enumFromValue` never throws and never allocates; a failure is carried in the
returned `ParseExpected`.

## 4. Compile-time evaluation

`enumMemberName` must be usable during CTFE so a consumer can derive an enum's
wire names at compile time — for instance, building a `switch` of member-name
cases without making the identifier a template argument. Both primitives select
their results from the enum's declared members, so no runtime table is built.

## 5. Examples

Rendering a member name, recased, and reading a member back from its underlying
value:

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "enums_name_and_value"
    dependency "sparkles:base" version="*"
+/
import std.stdio : writeln;
import sparkles.base.text.case_style : CaseStyle;
import sparkles.base.text.enums : enumFromValue, enumMemberName;

enum Priority { lowPriority = 1, highPriority = 5 }

void main()
{
    // value → member name, recased
    writeln(enumMemberName!(CaseStyle.snakeCase)(Priority.highPriority));

    // underlying value → enum (membership-checked)
    auto ok = enumFromValue!Priority(1);
    writeln(ok.hasValue, " ", ok.value == Priority.lowPriority);

    auto bad = enumFromValue!Priority(2);
    writeln(bad.hasValue, " ", bad.error.context);
}
```

```ansi
high_priority
true true
false expected one of: 1, 5
```

A non-integer-backed enum round-trips through its underlying value:

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "enums_non_integer"
    dependency "sparkles:base" version="*"
+/
import std.stdio : writeln;
import sparkles.base.text.enums : enumFromValue, enumMemberName;

enum Mode : string { fast = "fast-path", slow = "slow-path" }

void main()
{
    writeln(enumMemberName(Mode.fast));          // default CaseStyle.original
    writeln(enumFromValue!Mode("slow-path").value == Mode.slow);
    writeln(enumFromValue!Mode("nope").hasValue);
}
```

```ansi
fast
true
false
```

---

→ [`sparkles.base.text.case_style` spec](./case-style.md) — the case conversion this recasing uses
→ [`sparkles.base.text` cell-splitting & width spec](./index.md) — the sibling text spec
→ [`sparkles:wired`](../../wired/SPEC.md) — a policy layer that consumes these primitives
→ [`sparkles:base`](../../../libs/base/index.md) — the library overview
