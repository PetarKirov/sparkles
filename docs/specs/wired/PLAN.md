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

- `sparkles.base.text.case_style` — `CaseStyle`, the CTFE-compatible
  `convertCase!style(ident)` word-splitter, and its `@nogc` writer form
  `writeConvertedCase!style(w, ident)` (`convertCase` is the allocating wrapper
  over it) ([case-style spec](../base/text/case-style.md); SPEC §6).
- `sparkles.base.text.enums` — `enumMemberName!style(value)` (value → cased member
  name, selecting a compile-time literal) and `enumFromValue!E(v)`
  (membership-checked value → enum, via `OriginalType`).
- `sparkles.base.text.readers` / `.writers` — `readEnumString` gains a `CaseStyle`;
  `writeEnumMemberName` / `writeEnumValue` output-range primitives.

Gate: `dub test :base` — `convertCase` runtime cases plus `static assert` CTFE
coverage (incl. acronym/digit boundaries), `writeConvertedCase` into a
`SmallBuffer` matching `convertCase` for every style (and a `@nogc` case), the
enum primitives, and a non-integer-backed enum; plus
`nix run .#ci -- --verify --files docs/specs/base/text/case-style.md`.

## M3 — policy (`sparkles.wired.policy`)

`AnyFormat`, `Repr`, `WireSkip`, `WireInvalid`, `WireMatch`, the `@Wire*` UDA
structs supporting the exact source forms from SPEC §5.1, and the per-axis
resolvers implementing the precedence lattice (SPEC §5), plus the per-member /
per-field name dispatchers and uniqueness checks.

## M4 — JSON backend (`sparkles.wired.json`)

`struct Json {}`, `toJSON` / `fromJSON` / `readJSONFile` / `writeJSONFile`, the
supported-type mapping (SPEC §4.2), and the enum /
aggregate-field / AA-key wiring that consults the policy under the `Json` tag.
Re-export the public surface from `sparkles.wired` (`package.d`). `Optional!T`
support adds the `optional` package as a `sparkles:wired` dependency (with the
matching `dub.selections.json` / `nix/dub-lock.json` entries).

Gate: `dub test :wired` — Expected-returning file helpers with final newlines,
atomic writes (temp + rename) and recursive parent-directory creation,
strict scalar kind/range checks, character-as-string mapping with fit/validity
rejection (non-ASCII `char`, astral `wchar`, out-of-range `dchar`), static-array
(`T[N]`) exact-length decode, UTC `SysTime`
round-trips with offsetless-string rejection, per-axis and per-format
resolution, explicit `WireTarget.all` defaults, field overrides reaching through
composed wrapper chains (`Nullable!(E[])`, `E[][]`, `V[Mode][]`) down to the
first enum/aggregate on each branch, `WireTarget.key` / `WireTarget.value` branch
selection (including aggregate and nullable/optional value-slot casing, and
key-branch enums), directly-nested null-aware rejection, enum value/name
collision rejection, aggregate
field `@WireName` / `@WireCase`, required-field handling, `@WireOptional`
decode-tolerance across `WireInvalid.reject` / `useDefault` plus `WireSkip`
encode-omission (`whenEmpty` / `whenDefault` / `never`), aggregate key
collision rejection, unsupported aggregate
field/construction shapes, `@WireConvert` return-type inference and round-trips,
`SumType` zero-match and ambiguity errors under `WireMatch.exactlyOne` plus
`WireMatch.first` order-based selection, nothrow and `Expected`-returning
converter failures, decode errors with nested path diagnostics including escaped
object-key path segments, and nested-struct isolation.

## M5 — docs & verification

The `docs/libs/wired/` guide; the VitePress sidebar entry for this spec; and
`nix run .#ci -- --verify` over [SPEC.md](./SPEC.md) and the guide.

Gate: every spec example runs and matches; `npm run docs:build` is clean.

## M6–M15 — the native JSON engine (SPEC §11)

Replaces `std.json` with wired's own scalar engine (yyjson-class; the
performance case is [bench-baseline.md](./bench-baseline.md); SIMD is a
later iteration). Prep: M6a spec (§11), M6b `ParseErrorCode` additions,
M6c JSONTestSuite pin. Reusable primitives in `sparkles:base` (A1–A6):
tiered decimal→double conversion (unrolled digit loop, pow10 fast path,
Eisel–Lemire, bigint fallback), Schubfach shortest-round-trip double
formatting, branchlut integer formatting, scalar UTF-8 validation, and the
`float-conv` spec page.

Engine milestones, each independently green:

- **M7** — split `sparkles.wired.json` into a package (pure move).
- **M8** — arena document model (`JsonDocument`/`JsonValue`,
  allocator-generic per the composable-allocators guideline).
- **M9** — strict RFC 8259 reader. Gate: JSONTestSuite clean + number pins.
- **M10** — `wired-native` row in the runtime bench. Gate: twitter parse
  ≥ 1 GB/s, fingerprints match every corpus.
- **M11** — streaming writer (+ bench serialize op, round-trip invariants).
- **M12** — native decode/encode walks (`JsonError`-based) + text-level
  API. Gate: twitter decode ≥ 1 GB/s, compile-time bench not regressed.
- **M13** — **breaking** switch-over to the native surface and `JsonError`
  (SPEC §11.6); `ci --verify` over the revised examples.
- **M14** — retire the `std.json` walk; port the test suite.
- **M15+** — optimization rounds (in progress; checkpoint in
  [bench-baseline.md](./bench-baseline.md)). Landed: the pointer number
  kernel, single-`i128`-mul Eisel–Lemire, masked UTF-8 sequence checks,
  frequency-ordered dispatch, the levelled-allocator bench field, and
  `validateJson` (the text-level validate op). Standing: twitter parse
  1755 / decode 1518 MB/s vs yyjson 3930 / 3450 — decode is 9.7× the
  retired std.json pipeline. Exit gate: `wired-native` parse **and**
  decode within ±10% of the yyjson rows on the runtime bench.
