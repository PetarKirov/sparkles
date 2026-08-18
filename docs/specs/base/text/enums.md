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
  non-integer-backed enums work too;
- **prefix** — the leading text every member name of an enum shares, so that an
  enum translated from C can be rendered without repeating its own type name.

The name direction comes in two forms because enums arriving from C break the
assumptions of the direct one. A `.h` translated by ImportC routinely declares
several members with the same underlying value (an extension enumerator promoted
to core keeps its former spelling as an alias), and a value read back from a C
library need not be a declared member at all — a newer library may report an
enumerator postdating the header this was built against.

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

// the same, tolerating duplicate values and values that are not declared members,
// and optionally dropping affixes from the member identifier before recasing.
string enumMemberNameOr(CaseStyle style = CaseStyle.original, string prefix = "",
    string suffix = "", E)
    (in E value, string fallback)
if (is(E == enum));

// the prefix every member name shares, cut back to the last `_`.
// An eponymous value template, so it can be passed straight to `enumMemberNameOr`.
template enumCommonPrefix(E)
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
`enumMemberName` is instantiated for it. Use §3.2 for such an enum.

### 3.2 `enumMemberNameOr`

`enumMemberNameOr!style(value, fallback)` is the total, duplicate-tolerant form.
It is specified as a sequence of equality tests over the declared members in
declaration order, not as a `final switch`, and therefore:

- **Duplicate underlying values are permitted**, and the **first declared**
  matching member supplies the name. For a C-derived enum this is the required
  rule rather than an arbitrary tie-break: the header declares the core
  enumerator before the alias retaining the pre-promotion spelling.
- **A value equal to no declared member yields `fallback`**, which the caller
  supplies. It is not a programming error, so nothing asserts.
- Recasing is by `convertCase!style`, identical to §3.1, and each candidate name
  is a compile-time string literal, so nothing is allocated.
- **`prefix` and `suffix` are removed from the member identifier before
  recasing**, and a member not carrying one is left whole. The ordering is
  normative: `convertCase` to a style that drops separators does not preserve
  length, so a caller slicing the _recased_ name by the raw affix's length would
  cut it in the wrong place. An affix that would consume the identifier entirely
  is not applied.
- **`fallback` is returned verbatim** — never stripped, never recased. It is the
  caller's own string and carries no member affix. This asymmetry is the reason
  stripping is specified here rather than left to the call site, where slicing
  the result would run past the end of a fallback shorter than the prefix.

Where both forms are usable they return the same name. The trade is that this
one is a linear scan where §3.1 permits a jump table.

### 3.3 `enumCommonPrefix`

`enumCommonPrefix!E` is the longest common prefix of every declared member
identifier, truncated to end at the last `_` it contains:

- The truncation keeps the result a whole word. Members sharing `VK_FORMAT_R`
  yield `VK_FORMAT_`, so the rendered names read `R8_UNORM` and `R16_SFLOAT`
  rather than `8_UNORM` and `16_SFLOAT`.
- An enum whose members share no leading text, whose common prefix contains no
  `_`, or which declares **fewer than two members** yields `""`. The last case is
  degenerate rather than an error: a lone member is entirely its own prefix, so
  stripping it would leave nothing to render.
- The result is a compile-time constant, so it can be a template argument (§4).

`enumCommonPrefix` only reports. Whether to drop the prefix is the caller's
choice, expressed by passing it to §3.2 rather than by slicing a returned
string — see that section for why the difference matters.

### 3.4 `enumFromValue`

`enumFromValue!E(value)` validates an underlying value back into an enum. Like
§3.2 and unlike §3.1 it is a scan over the declared members, so a duplicate-valued
enum is accepted and the first declared match wins:

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

An enum as ImportC delivers one — duplicate values from a promoted extension,
and every member carrying the type's name — rendered without either problem:

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "enums_c_derived"
    dependency "sparkles:base" version="*"
+/
import std.stdio : writeln;
import sparkles.base.text.case_style : CaseStyle;
import sparkles.base.text.enums : enumCommonPrefix, enumMemberNameOr;

// `_KHR` was promoted to core; the old spelling survives as an alias.
enum PresentMode
{
    VK_PRESENT_MODE_IMMEDIATE = 0,
    VK_PRESENT_MODE_MAILBOX = 1,
    VK_PRESENT_MODE_MAILBOX_KHR = 1,
}

string render(PresentMode m)
    => enumMemberNameOr!(CaseStyle.kebabCase, enumCommonPrefix!PresentMode)(m, "unknown");

void main()
{
    writeln(enumCommonPrefix!PresentMode);
    writeln(render(PresentMode.VK_PRESENT_MODE_IMMEDIATE));
    writeln(render(PresentMode.VK_PRESENT_MODE_MAILBOX_KHR)); // first declaration wins
    writeln(render(cast(PresentMode) 7));                     // not a declared member
}
```

```ansi
VK_PRESENT_MODE_
immediate
mailbox
unknown
```

---

→ [`sparkles.base.text.case_style` spec](./case-style.md) — the case conversion this recasing uses
→ [`sparkles.base.text` cell-splitting & width spec](./index.md) — the sibling text spec
→ [`sparkles:wired`](../../wired/SPEC.md) — a policy layer that consumes these primitives
→ [`sparkles:base`](../../../libs/base/index.md) — the library overview
