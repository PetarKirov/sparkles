# `sparkles:wired` — Open specification issues

_Companion to [SPEC.md](./SPEC.md) and [PLAN.md](./PLAN.md). A running list of
behavioral questions surfaced during spec review that are **not yet resolved** in
the normative spec. Each entry records where it bites, the options, and any
current leaning. Resolve by folding a decision into SPEC.md, then delete the entry
here (and reference the commit)._

O1–O4 are lower-severity items deferred after the first review pass (which
resolved Optional support, `@WireOptional` encode omission, directly-nested
null-aware rejection, parameterized `@WireOptional` with `WireSkip`/`WireInvalid`,
fit-strict `char`/`wchar`/`dchar` mapping, `@WireConvert` × `@WireOptional`
ordering, and the configurable `SumType` decode strategy via `@(WireMatch)`).
O8, O10, and O11 come from a second, deeper review pass. (The other second-pass
items — O5 round-trip bug, O6 composed-wrapper reach, O7 static arrays, O9 atomic
writes, O12 enum-error candidates, O13 module table — have been resolved into
SPEC.md.)

## O1 — `SysTime` sub-second precision

**Where:** SPEC §4.4.

`SysTime` encodes as an ISO-8601 extended string. It is not stated whether the
fractional-second component (hectonanoseconds) is preserved on the round-trip, or
truncated to whole seconds / milliseconds. `SysTime.toISOExtString` /
`fromISOExtString` do carry fractional seconds, but the spec should pin the
guarantee (full hnsec fidelity vs. a documented truncation) so encode → decode is
predictable.

**Options:** (A) preserve full hnsec precision and state it normatively;
(B) document a fixed precision (e.g. milliseconds) and truncate on encode;
(C) leave to the format, with `@WireConvert` as the escape hatch for custom
precision.

**Leaning:** (A) — preserve what `std.datetime` round-trips, and say so.

## O2 — Self-referential / recursive aggregates

**Where:** SPEC §4.6.

A recursive type — e.g. a tree node with `Nullable!Node` or `Node[]` children —
is structurally supported per §4.6, but the spec does not say whether the
generated encoder/decoder terminates by construction (it does, since recursion is
data-driven, not type-driven) or whether any pathological shape causes infinite
compile-time template instantiation. Worth an explicit sentence that recursion
through a supported wrapper is fine, and calling out any shape that is not.

**Options:** (A) state that data-recursive aggregates are supported and terminate;
(B) additionally bound or reject a specific problematic shape if one exists.

**Leaning:** (A), pending a check that no wrapper combination self-instantiates.

## O3 — `JSONValue` passthrough of non-conforming data — RESOLVED (strict)

**Where:** SPEC §4.2 (`JSONValue` "passed through unchanged").

Resolved by the native-engine switch-over (SPEC §11.6): passthrough is the
$(I owned) generic-JSON escape hatch — decoding materializes the subtree,
encoding streams it with sorted keys — and a `NaN`/infinity inside a
passed-through value is an encode-stage `JsonError`, exactly like a typed
float field.

**Options:** (A) confirm passthrough is intentionally unchecked and document it as
the raw-JSON escape hatch; (B) apply the same scalar-validity checks (e.g. reject
`NaN`) even on passthrough.

**Leaning:** (A) — `JSONValue` is the "I know what I'm doing" hole; keep it raw,
document that no wired-level validation applies.

## O4 — Empty associative array vs missing vs `null`

**Where:** SPEC §4.5 (parallels the array/omission rules).

For a plain `V[K]` field, the spec covers missing (decode error unless
`@WireOptional`) and `null` (decode error for non-null-aware targets), but does
not explicitly address the empty-map wire shape (`{}`) or how it interacts with
`@WireOptional(WireSkip.whenDefault)` — an empty AA equals `(V[K]).init`, so
`whenDefault` would omit it on encode. Confirm the intended symmetry (empty `{}`
decodes to an empty map; `whenDefault` omits an empty map; a missing key without
`@WireOptional` is still an error).

**Options:** (A) state the empty-map rules explicitly and confirm the
`whenDefault` interaction; (B) add a dedicated skip-if-empty-collection nuance if
the `whenDefault` `== .init` rule proves too blunt for arrays/maps.

**Leaning:** (A) — the existing `whenDefault` rule already covers it; just make
the AA/array case explicit. `whenDefault` now compares against the field's
declared default (resolved O5), so the initializer interaction is symmetric.

## O8 — Numeric round-trip fidelity (unsigned range, float precision) — RESOLVED

**Where:** SPEC §4.3.

Resolved by the native engine: the reader classifies integer tokens as
`long` when they fit, `ulong` otherwise (the full `ulong` range
round-trips, range-checked at decode), and floats convert with
correctly-rounded parsing plus shortest-round-trip formatting
(`docs/specs/base/text/float-conv.md`) — `parse(format(x))` is bit-exact
for every finite `double`.

## O10 — No `deny-unknown-fields` strictness option

**Where:** SPEC §4.5 ("An unknown JSON object key is ignored").

Decoding silently ignores unknown object keys; there is no opt-in to make an
unexpected key a decode error (the analogue of serde's `deny_unknown_fields`).
Some callers want strict schemas that reject typos or extra data.

**Options:** (A) add an opt-in strict policy (a type/field UDA or a `fromJSON`
option) that rejects unknown keys; (B) keep lenient-only and document that unknown
keys are always ignored.

**Leaning:** defer — a real feature, but only if a use case appears; lenient by
default is defensible. Flagged so the omission is conscious.

## O11 — Built-in temporal and binary coverage

**Where:** SPEC §4.2, §4.4.

Only `SysTime` among `std.datetime` types is built in; `Date`, `TimeOfDay`,
`DateTime`, and `Duration` require `@WireConvert` (as the §8 example shows for
`Duration`). Separately, `ubyte[]`/`byte[]` fall under "non-character arrays" and
serialize as JSON **number arrays** (`[1,2,3]`), not base64 — surprising for
binary payloads.

**Options:** (A) add built-in mappings for the common `std.datetime` types and a
base64 mapping for byte arrays; (B) keep scope minimal (SysTime + converters) but
document these gaps with canonical `@WireConvert` recipes.

**Leaning:** (B) for now — document the recipes; revisit (A) if these recur.
