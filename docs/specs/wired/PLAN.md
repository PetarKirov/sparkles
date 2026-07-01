# `sparkles:wired` — Delivery plan

_Companion to [SPEC.md](./SPEC.md): the milestones that build the library to the
specification. Each milestone is independently green (builds + tests + lints)._

## M1 — Specification

[SPEC.md](./SPEC.md) — the normative surface: the format concept (§3), the JSON
backend and supported types (§4), the `@Wire*` policy and its resolution lattice
(§5), case styles (§6), enum representation (§7), value transforms (§8), errors
(§9), and the public API (§10). Every code block is a runnable example with a
checked output; the implementation milestones make them pass under
`nix run .#ci -- --verify`.

## M2 — base text primitives (`sparkles:base`)

Format-agnostic, no policy:

- `sparkles.base.text.case_style` — `CaseStyle` and the CTFE-compatible
  `convertCase!style(ident)` word-splitter (SPEC §6).
- `sparkles.base.text.enums` — `enumMemberName!style(value)` (value → cased member
  name, selecting a compile-time literal) and `enumFromValue!E(v)`
  (membership-checked value → enum, via `OriginalType`).
- `sparkles.base.text.readers` / `.writers` — `readEnumString` gains a `CaseStyle`;
  `writeEnumMemberName` / `writeEnumValue` output-range primitives.

Gate: `dub test :base` — `convertCase` runtime cases plus `static assert` CTFE
coverage (incl. acronym/digit boundaries), the enum primitives, and a
non-integer-backed enum.

## M3 — policy (`sparkles.wired.policy`)

`AnyFormat`, `Repr`, the `@Wire*` UDA structs supporting the exact source forms
from SPEC §5.1, and the per-axis resolvers implementing the precedence lattice
(SPEC §5), plus the per-member / per-field name dispatchers and uniqueness
checks.

## M4 — JSON backend (`sparkles.wired.json`)

`struct Json {}`, `toJSON` / `fromJSON` / `readJSONFile` / `writeJSONFile`, the
supported-type mapping (SPEC §4.2), and the enum /
aggregate-field / AA-key wiring that consults the policy under the `Json` tag.
Re-export the public surface from `sparkles.wired` (`package.d`).

Gate: `dub test :wired` — Expected-returning file helpers with final newlines,
strict scalar kind/range checks, character-as-string mapping, UTC `SysTime`
round-trips with offsetless-string rejection, per-axis and per-format
resolution, field overrides over one wrapper level, enum value/name collision
rejection, aggregate field `@WireName` / `@WireCase`, required-field and
`@WireOptional` decode behavior, aggregate key collision rejection, unsupported
aggregate field/construction shapes, `@WireConvert` round-trips, `SumType`
zero-match and ambiguity errors, decode errors with nested path diagnostics, and
nested-struct isolation.

## M5 — docs & verification

The `docs/libs/wired/` guide; the VitePress sidebar entry for this spec; and
`nix run .#ci -- --verify` over [SPEC.md](./SPEC.md) and the guide.

Gate: every spec example runs and matches; `npm run docs:build` is clean.
