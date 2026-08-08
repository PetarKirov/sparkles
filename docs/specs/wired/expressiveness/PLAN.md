# `sparkles:wired` — Expressiveness upgrade — Delivery plan

_Companion to [SPEC.md](./SPEC.md): the milestones that build the upgrade.
Each milestone is independently green (builds + tests + lints). E-numbers
continue independently of the base plan's M-numbers
([base PLAN](../PLAN.md)); the ordering encodes the dependency spine — the
schema first, everything else as walkers and axes over it. The
not-retrofittable API decisions (SPEC §5.2, §6.1, §6.5, §7.2) land in E1–E4,
**before** any `Cli` format work begins._

## E1 — Schema reification

`wireSchemaOf!(F, T)` → `WireSchema`/`SchemaNode` (SPEC §2.1) in a new
`sparkles.wired.schema` module, plus `wireSchemaDigest` (§2.3). The policy
snapshot per node is computed by the existing base-§5.2 resolvers;
`fieldPolicies` becomes a projection of the schema (kept as API).

Gate: `dub test :wired` — schema snapshots for representative types
(scalars, wrappers, AAs, `SumType`, recursion via `reference` nodes,
converter boundaries, unknown annotations preserved); digest stability
(unchanged type ⇒ unchanged digest; renamed key ⇒ changed digest; added
`@WireDoc` ⇒ unchanged digest); a CTFE `enum schema = wireSchemaOf!(Json, T)`
compiles for every type in the existing test suite.

## E2 — The schema-driven JSON walk

Re-express `decodeNative`/`encodeNative` as the generic walk over
`WireSchema` with JSON leaf I/O (SPEC §2.2). This **fixes by construction**
the three probe-documented divergences: static arrays (base §4.3),
slot-targeted and composed-wrapper policies (base §5.2), and sets up §3.4's
per-variant errors ([open-issues O14–O16](../open-issues.md)).

Gate: the full existing `dub test :wired` suite green with **byte-identical
output** for every non-divergent behaviour; new tests for `T[N]` exact-length
decode and the base-PLAN-M4 slot-policy list (`Nullable!(E[])`, `E[][]`,
`V[Mode][]`, `WireTarget.key` AA recasing); JSONTestSuite conformance
unchanged; runtime bench within the [bench-baseline](../bench-baseline.md)
gate (±10% of the standing snapshot); update the
[research baseline probes](../../../research/serde/wired-baseline.md) whose
`[Output]` blocks this milestone deliberately flips.

## E3 — Names: aliases and direction-split renames

`@WireAlias` (repeatable, decode-only) and `@WireName(encode:, decode:)`
(SPEC §4), with alias participation in the uniqueness asserts and in the
schema.

Gate: decode-accepts-alias / encode-emits-name round-trips; collision
asserts; digest unaffected by aliases.

## E4 — Presence, defaults, unknown fields

`@WireDefault` (value and `pure` callable forms), the
`whenDefault`-comparison rule, `Decoded!T` + `WireFieldSet`, and the
unknown-field knob (`@WireStrict`, `@WireExtra`) (SPEC §5). Resolves
[O10](../open-issues.md).

Gate: the §5.1 omission invariant (omit exactly what a missing key
restores) property-tested; `Decoded!T` presence bits for
absent / present-at-default / present-distinct; `@WireStrict` unknown-key
error naming the key; `@WireExtra` capture → re-emit round-trips unmodelled
keys; contradictory `@WireStrict`+`@WireExtra` rejected at compile time.

## E5 — Unions

`@WireUnion` with all four representations, `@WireOther`, sentinel
inference, the compile-time ambiguity proof, per-variant errors, and the
**breaking** default flip to `external` (SPEC §3).

Gate: four-representation round-trips for a three-variant union
(aggregate + scalar + unit shapes); internal-tag collision and
non-aggregate-variant compile errors; sentinel dispatch equivalence with
`exactlyOne`; the ambiguity `static assert` firing on a crafted ambiguous
pair and passing with a sentinel / `first` / a tagged repr; per-variant
error content; digest change on representation change; a migration note in
the changelog for the default flip.

## E6 — Checks, adapters, converter chains

`@WireCheck` with the four return protocols and the shipped typed factories
(`isOneOf`, `isBetween`), type-level cross-field checks with sub-paths,
`@WireAs` (`Same`, `Stringly`, `Elements`, `Entries`) desugaring to
`converted` nodes, converter chaining, and the presence-carrying
`WirePresent` converter forms (SPEC §6.1–§6.4).

Gate: checks enforce in both directions (invalid value never constructed);
check descriptors visible in the schema; adapter composition over
`T[]`/`V[K]`; chain inference across two links; a presence-carrying
converter expressing both "default on absence" and "omit on encode" without
`@WireOptional`.

## E7 — Accumulation and context

The error-sink decode overloads (all-failures-with-paths, first error in the
`Expected`, fixed-capacity overflow marker) and the `ref Ctx` threading with
`void` default, decode/encode independent (SPEC §7).

Gate: a six-bad-fields fixture yields six pathed errors in one pass, `@nogc`
with a `SmallBuffer` sink; context reaches a context-taking converter and
check on decode while encode instantiates context-free; zero codegen delta
when `Ctx == void` (compile-time-bench guarded).

## E8 — Hooks, metadata, round-trip predicate

`@WireHook` per the reserved signature, `@WireDoc`/`@WireExample`/
`@WireDeprecated` + opt-in ddoc harvesting, and `isWireRoundTrippable` +
`@WireIsomorphic` (SPEC §6.5, §8).

Gate: a retrying hook and an error-rewriting hook over one field; metadata
present in the schema and absent from the digest; the predicate rejects each
breaker class from SPEC §8.2 and accepts the five research example schemas'
wired equivalents.

## E9 — Reserved directions (design-only)

Sibling-field decode ordering, the string-tree intermediate (argv/env/URL),
and `DynValue` with type witnesses are **specified before implementation**
as part of the `Cli` format design (S2b), which is their first consumer.
Exit criterion: a SPEC revision, not code.

## E10 — Derivation emitters (with the `Cli` format)

JSON Schema and help-text emitters as folds over `WireSchema`, landing
alongside the `Cli` format so the first derivation has a consumer
(`--help`). Tracked in the S2b plan, not here.
