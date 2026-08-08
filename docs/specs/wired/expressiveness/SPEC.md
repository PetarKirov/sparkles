# `sparkles:wired` — Expressiveness upgrade (S2a) — Specification

_Audience: developers and coding agents building against the library. This
document is normative for the **expressiveness upgrade** of `sparkles:wired`:
the reified schema layer, the schema-driven walk, and the new policy axes. It
extends the [base specification](../SPEC.md) without renumbering it — every
"base §N" reference below points there. For the delivery plan see
[PLAN.md](./PLAN.md); for the evidence base see the
[serde-expressiveness research catalog](../../../research/serde/index.md),
especially the [capability delta table](../../../research/serde/comparison.md#the-delta-table)
this spec closes._

> [!NOTE]
> Code blocks in this document are illustrative declarations, not yet runnable
> single-file examples. As each [PLAN](./PLAN.md) milestone lands, its examples
> are promoted to verified `[Output]` form here and in
> [`docs/libs/wired/`](../../../libs/base/index.md), matching how the base
> spec's examples preceded their implementation (base PLAN M1).

## 1. Overview and design principles

The upgrade turns wired from a per-format codegen library with a flat policy
table into a **schema-interpreted** library: one compile-time schema value per
(format, type), from which every codec, check, and derivation is generated.
The declaration surface stays structs + `@Wire*` UDAs; nothing here adds a
registration step or a runtime construction phase.

Five principles, distilled from the [research
corpus](../../../research/serde/comparison.md) and binding on every section
below:

1. **The schema is data, and attributes are data.** Every policy axis a
   generator might print (defaults, constraints, docs, enum values) is stored
   as a value in the schema, never only as an opaque callable
   ([schemars' leak](../../../research/serde/serde.md)). Callables remain
   where behaviour is genuinely code (converters, checks) — but each carries a
   declarative descriptor alongside when one exists.
2. **No silent degradation.** Where the base implementation today produces
   wrong-but-quiet output (base §5.2 slot policies on composed wrappers) or
   silently lacks a specified feature (base §4.3 static arrays), this spec
   requires either correct behaviour or a compile-time error naming the type,
   the format, and the unsupported shape. `static assert` is the failure mode
   of choice throughout.
3. **Open data model.** The schema's node vocabulary has a fixed structural
   core plus format-extensible annotations, so a format can contribute axes
   (a CLI format's positional/counter roles) without the core learning about
   them ([the fixed-29-types trap](../../../research/serde/serde.md)).
4. **Synchronous, `Expected`-based core.** No effect-shaped plumbing; context
   and accumulation are opt-in parameters that cost nothing when unused
   ([what not to copy](../../../research/serde/effect-schema.md)).
5. **Both directions from one schema, with an honest law.** The promised
   round-trip law is `decode(encode(x)) == x` modulo declared asymmetries —
   never the text direction
   ([round-trip laws](../../../research/serde/concepts.md#bidirectionality-and-the-round-trip-laws)).

### 1.1 Supersessions

This spec supersedes the base spec in exactly these places; everything else in
the base spec stands:

| Base section           | Change                                                                                                                                  |
| ---------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| §4.7 `SumType` decode  | Untagged trial decode remains one mode of §3 below; the default representation changes (§3.1)                                           |
| §5 policy table        | Gains the new UDAs of §§3–8; resolution lattice unchanged                                                                               |
| §5.2 slot-target reach | Semantics unchanged, but now **implemented via the schema walk** — divergence becomes a defect class that cannot recur (§2.4)           |
| §8 value transforms    | `@WireConvert` unchanged; gains presence-carrying and context-taking forms (§6), chaining (§6.2), and the `@WireAs` adapter peer (§6.3) |
| §9 errors              | `JsonError` unchanged as the per-failure value; gains an accumulation mode (§7) and per-variant union reporting (§3.4)                  |

## 2. The reified schema

### 2.1 `wireSchemaOf`

```d
enum WireSchema schema = wireSchemaOf!(F, T);
```

`wireSchemaOf!(F, T)` is a CTFE function producing the complete schema of `T`
under format `F` as a plain value: a **flat arena** of nodes with integer
references — no pointers, no thunks, no allocation at run time when stored in
an `enum`/`static immutable`.

```d
struct WireSchema
{
    SchemaNode[] nodes;       // node 0 is the root
    string[] names;           // interned identifiers / wire keys / docs
}

enum NodeKind
{
    scalar,        // integrals, floats, bool, char kinds, strings, SysTime
    enumeration,   // an enum: members carry resolved wire names and values
    aggregate,     // struct: fields
    unionType,     // SumType: variants + representation (§3)
    sequence,      // T[] and InputRange-shaped
    staticArray,   // T[N] — with N recorded
    map,           // V[K]
    nullAware,     // Nullable / Optional / Ternary wrapper
    converted,     // a @WireConvert / @WireAs boundary: wire-side child + descriptor
    passthrough,   // JSONValue-style raw hole
    reference,     // ref(index) — closes recursion
}
```

Load-bearing properties:

- **Recursion is a `reference` node** (index into `nodes`), so recursive types
  reify without thunks and schema emitters can produce named `$ref`s — the
  requirement every schema emitter eventually hits
  ([the `ReferenceCodec` lesson](../../../research/serde/haskell-codecs.md)).
- **Every node carries its resolved policy snapshot** — wire key, aliases,
  case, repr, optionality, default channel, checks, metadata — i.e. the base
  §5.2 lattice is resolved **once, into the schema**, not re-queried per walk
  site. `FieldPolicy` (the current flat table) becomes a projection of this.
- **Every node carries an open annotation list**: UDAs the core does not
  recognize are preserved (type + CTFE value where evaluable), so a later
  backend can read annotations the schema layer never heard of
  ([zio-schema's `annotations: Chunk[Any]`](../../../research/serde/zio-schema.md)).
- The schema is **per (format, type)** and computed on demand; there is no
  global registry (base §3 stands).

### 2.2 The schema-driven walk

Codecs are **walkers over `WireSchema`**. The library provides one generic
walk skeleton (dispatch over `NodeKind`, recursion via node indices, policy
application per node); a format supplies the leaf I/O — how a scalar, a key,
a sequence delimiter is read/written. The JSON backend (base §4) is
re-expressed as the first walker with **byte-identical output** for every
behaviour the base spec pins, gated by the existing conformance suite and
[bench baseline](../bench-baseline.md).

Consequences, normative:

- A policy axis the walk does not implement for some shape is a **compile-time
  error**, not silently-default output. The two known divergences (base §4.3
  static arrays; base §5.2 slot-targeted and composed-wrapper policies —
  probe-documented in the
  [research baseline](../../../research/serde/wired-baseline.md#probe-verified-spec-divergences))
  are fixed **structurally** by this milestone: the schema resolves the policy
  per node, so the walker cannot skip it.
- `T[N]` (`staticArray`) encodes as a JSON array and decodes with exact-length
  checking, as base §4.3 always specified.
- A second format implements leaf I/O only; it inherits the walk, the policy
  application, the error paths, and the accumulation mode.

### 2.3 Schema digest

```d
enum string digest = wireSchemaDigest!(F, T);   // stable content hash
```

A stable digest of the schema's wire-visible surface (keys, kinds, reprs,
optionality, union tags — not docs). Its purpose is the
[atddiff-style](../../../research/serde/ocaml-atd.md) compatibility gate: a
consumer snapshots digests as goldens and CI fails when a type's wire surface
changes unintentionally. The digest ignores annotations that do not affect
bytes on the wire.

### 2.4 What the schema is not (deferred)

The runtime-schema features — a `DynValue` with type witnesses, the
string-tree intermediate for argv/env/URL formats, `derive`-based migrations,
and `Pick`/`Omit`/`Partial` projections — are specified only as reserved
directions here; see [PLAN](./PLAN.md) E9+ and the
[research delta rows 16–20](../../../research/serde/comparison.md#the-delta-table).
Nothing in §2.1's shape precludes them.

## 3. Sum types: representations and discrimination

### 3.1 `@WireUnion` and the four representations

```d
enum UnionRepr { external, internal, adjacent, untagged }

@WireUnion()                                // external — the new default
@WireUnion!F()                              // per-format
@WireUnion(tag: "kind")                     // internal
@WireUnion(tag: "t", content: "c")          // adjacent
@WireUnion(UnionRepr.untagged)              // untagged (base §4.7 semantics)
```

`@WireUnion` attaches to a `SumType` **field** or to a type-level alias
carrying the union; resolution follows the base §5.2 `match` axis (field `!F` →
field `!Any` → type `!F` → type `!Any` → default).

| Representation | Wire shape (JSON)              | Notes                                                                                                 |
| -------------- | ------------------------------ | ----------------------------------------------------------------------------------------------------- |
| `external`     | `{"variantName": {…}}`         | **Default.** No buffering needed; variant known before content.                                       |
| `internal`     | `{"kind": "variantName", …}`   | Compile-time error if any variant is a non-aggregate, or if a variant field collides with the tag key |
| `adjacent`     | `{"t": "variantName", "c": …}` | Every variant shape allowed                                                                           |
| `untagged`     | the bare variant value         | Trial decode per base §4.7; `@(WireMatch.…)` still selects the strategy                               |

**Breaking change:** the default for `SumType` moves from untagged trial
decode to `external`. The old behaviour is one annotation away
(`@WireUnion(UnionRepr.untagged)`); the migration is mechanical and the
[digest](#23-schema-digest) makes it visible. Untagged-by-default is the
weakest union story in every surveyed library
([representations](../../../research/serde/concepts.md#sum-type-representations)),
and a subcommand — the CLI format's core shape — is an externally-tagged
union.

**Variant names.** A variant's wire name is its type's unqualified identifier,
recased by the governing `@WireCase`; `@WireName` on the variant's type
declaration overrides it verbatim. Resolved variant names must be unique
(compile-time assert, matching base §5's key-uniqueness rule).

`@WireOther` marks at most one variant (of aggregate or unit shape) as the
catch-all for an unrecognized tag under `internal`/`adjacent`/`external` —
the forward-compatibility fallback
([cattrs' unknown-tag `default`](../../../research/serde/msgspec-cattrs.md)).
Without it, an unrecognized tag is a decode error listing the known tags.

### 3.2 Sentinel inference (untagged)

Under `untagged`, before trial decode, the schema builder computes each
variant's **sentinel set**: fields that are required and enum- or
literal-typed with disjoint value sets across variants. When every variant has
a distinguishing sentinel, decode dispatches on it directly — no trial, no
per-variant work — and the schema records the dispatch table
([Effect's inferred sentinels](../../../research/serde/effect-schema.md)).
Sentinel dispatch is an optimization with identical semantics to
`WireMatch.exactlyOne`; it never changes which variant matches.

### 3.3 Compile-time ambiguity proof (untagged)

Under `untagged` + `WireMatch.exactlyOne`, the schema builder proves at
compile time that no two variants are **structurally ambiguous** — that for
every pair, some wire input is accepted by both (same scalar kind, or
aggregates where one's required-key set is a subset of the other's accepted
keys with compatible types) only if a sentinel separates them. A failed proof
is a `static assert` naming the two variants and the overlapping shape.
`WireMatch.first` waives the proof — declaration order is then the documented
tie-break, as in base §4.7. No surveyed library can state this guarantee
([delta row 5](../../../research/serde/comparison.md#the-delta-table)).

### 3.4 Union decode errors

A failed union decode reports **per-variant reasons**: under any tagged
representation, the error names the tag and the failing variant's nested
error; under `untagged exactlyOne`, the error carries each candidate
variant's own failure (bounded to the schema's variant count), replacing
today's bare "no variant matched" (the loss is probe-documented in the
[research baseline](../../../research/serde/wired-baseline.md)).

## 4. Names: aliases and direction-split renames

```d
@WireName!F("name")                          // both directions (base §5, unchanged)
@WireName!F(encode: "new", decode: "old")    // direction-split
@WireAlias!F("legacy")                       // decode-only, repeatable
@WireAlias("legacy2") @WireAlias("legacy3")  // accepted in addition to the name
```

- Decode accepts the resolved name **plus every alias**; encode emits exactly
  the resolved (encode-side) name. Read-many/write-one is the correct
  asymmetry for wire-name migration and for CLI short/long spellings
  ([serde's `alias`](../../../research/serde/serde.md)).
- Aliases participate in the uniqueness assert: no alias may collide with any
  resolved field name or other alias of the same aggregate under the same
  format.
- `@WireAlias` never affects the [digest](#23-schema-digest)'s encode surface
  but is recorded in the schema (a schema emitter may publish it as
  deprecated-name metadata).

## 5. Presence, defaults, and `Decoded!T`

### 5.1 The two default channels

The base spec has one default source — the field initializer. This spec
splits the axis ([the presence
problem](../../../research/serde/concepts.md#the-presence-problem)):

- **Constructor default** — the D field initializer. What a missing field
  restores when no decoding default is declared. Unchanged.
- **Decoding default** — `@WireDefault!F(value)` or `@WireDefault!F(fn)`
  (a `pure` nullary callable evaluated per decode): the value a **missing
  wire key** supplies. When declared, it implies missing-tolerance (no
  separate `@WireOptional` needed for the missing case).

`WireSkip.whenDefault` (base §5.4) compares against **the decoding default
when one is declared, else the initializer** — preserving the invariant that
an omitted field round-trips: omit exactly the value a missing key restores.
A `@WireDefault!(fn)` whose value varies makes `whenDefault` on the same
field a compile-time error (the omission test would be unstable).

### 5.2 Presence provenance: `Decoded!T`

```d
struct Decoded(T)
{
    T value;
    WireFieldSet present;    // one bit per top-level field of T
    alias value this;
}

Expected!(Decoded!Server, JsonError) r = fromJSON!(Decoded!Server)(text);
if (!r.value.present.has!"httpPort") { /* flag was defaulted, not given */ }
```

Requesting `Decoded!T` instead of `T` makes the decoder record, per top-level
field, whether the wire supplied it — distinguishing _absent-and-defaulted_
from _explicitly equal to the default_. The bitset lives **outside `T`**:
`T` stays a plain value with unchanged `==`, hashing, and layout; `Decoded!T`
costs one word and is recognized structurally by the decoder (nesting
`Decoded` inside a field is unsupported at compile time). This is the
provenance primitive config layering (defaults ⊕ file ⊕ env ⊕ argv) and
faithful argv re-rendering require, and it is deliberately in the first
milestone because it shapes decoder output types — the one axis flagged
un-retrofittable across the corpus
([delta row 9](../../../research/serde/comparison.md#the-delta-table)).

### 5.3 Unknown-field policy

Resolves open issue [O10](../open-issues.md):

```d
@WireStrict!F struct Config { … }        // unknown key → decode error (with key name)
struct Config { @WireExtra JSONValue[string] rest; … }   // capture + re-emit
```

Three-valued, per aggregate type: **ignore** (default, unchanged), **forbid**
(`@WireStrict` — the right posture for config files and CLI flags), or
**preserve** (`@WireExtra` on exactly one AA-of-passthrough field: unmatched
keys decode into it, and encode splices them back, after the declared
fields). `@WireStrict` and `@WireExtra` on the same type are contradictory —
compile-time error. Preservation makes wired round-trip unmodelled data,
which no surveyed tier-1/2 library does
([unknown-field policy](../../../research/serde/concepts.md#unknown-field-policy)).

## 6. Converters, adapters, checks

### 6.1 Presence- and context-aware converters

`@WireConvert` (base §8) is unchanged in its plain form. Two additional
callable shapes are recognized by introspection, in either direction:

- **Presence-carrying:** the callable's parameter/return uses
  `WirePresent!X` (a one-field maybe: `absent` or a value). A
  presence-carrying `fromWire` is invoked even when the key is missing
  (receiving `absent`), and may return `absent` to mean "leave the field at
  its default"; a presence-carrying `toWire` may return `absent` to omit the
  key. This subsumes "default on absence" and "omit on encode" as ordinary
  transformations — the [`Getter`
  lesson](../../../research/serde/effect-schema.md).
- **Context-taking:** a trailing `ref Ctx` parameter (§7.2) receives the
  caller's context.

### 6.2 Converter chains

Multiple `@WireConvert` on one site compose **outermost-first in declaration
order**: encode applies `toWire` top-to-bottom (domain → … → wire), decode
applies `fromWire` bottom-to-top. Each link's wire type feeds the next link's
inference exactly as base §8 infers a single link. The schema records the
chain as nested `converted` nodes.

### 6.3 `@WireAs` adapters

The compositional, type-shaped peer of `@WireConvert`
([the serde_with lesson](../../../research/serde/serde.md)):

```d
@WireAs!(Stringly)                  ushort port;        // "8080" on the wire
@WireAs!(Elements!Stringly)         ushort[] ports;     // ["80","443"]
@WireAs!(Entries!(Same, Stringly))  uint[string] limits; // values stringified
```

An **adapter** is a type with static `toWire`/`fromWire` (the `@WireConvert`
contract) — or a _structural_ adapter (`Same`, `Elements!A`, `Entries!(K,V)`)
that recurses over the field type's shape applying inner adapters, with
`Same` as the identity hole. Adapters compose where converters (functions)
cannot; the shipped set is deliberately small (`Same`, `Stringly`,
`Elements`, `Entries`), and user adapters are ordinary types. An adapter
site desugars into `converted` schema nodes, so downstream machinery sees no
new concept.

### 6.4 Validation: `@WireCheck`

```d
@WireCheck!(p => p >= 1 && p <= 65_535)       ushort port;
@WireCheck!(isOneOf!("json", "text"))         string format;   // shipped check
@WireCheck!(v => v.start < v.end, "start must precede end")    // type-level, cross-field
struct Range { int start; int end; }
```

Checks run **inside** decode (after conversion; an invalid value is never
constructed into the result) and inside encode (before conversion) — the
refinement is enforced in whichever direction produces the refined value.
A check callable returns one of, by introspection:

| Return               | Meaning                                            |
| -------------------- | -------------------------------------------------- |
| `bool`               | pass/fail with a generated message                 |
| `string`             | `null`/empty = pass; otherwise the failure message |
| `Expected!(void, E)` | failure carries the payload's message              |
| `WireCheckFailure[]` | several failures, each with an optional sub-path   |

A type-level check sees the whole (decoded) aggregate — cross-field rules are
ordinary checks, with failures attributable to a named field via the
sub-path form ([the FilterOutput
protocol](../../../research/serde/effect-schema.md)). Checks carrying a
declarative descriptor (`isOneOf`, `isBetween` — shipped as typed check
factories) record it in the schema, so a help/schema emitter can print the
constraint rather than a function name (principle 1). Validation lives in the
same vocabulary and error channel as decoding — the
[serde split](../../../research/serde/serde.md) is explicitly rejected.

### 6.5 Hooks (reserved signature)

The middleware shape is **reserved now** because it is breaking to retrofit
([wrap hooks](../../../research/serde/pydantic.md)), implemented later
([PLAN](./PLAN.md) E8):

```d
@WireHook!(hook) field;
// Expected!(T, JsonError) hook(In, Next)(In wireView, scope Next next, ref Ctx ctx);
// where next(wireView) runs the remainder of the pipeline for this site.
```

`before`/`after` transformations are degenerate hooks; only the wrap form can
retry, substitute, or rewrite errors around the rest of the pipeline. No
other hook signature will be added.

## 7. Errors: accumulation and context

### 7.1 Accumulation

Fail-fast `Expected`-based decoding (base §9) remains the default. New:
every decode entry point accepts an **error sink** — any output range of
`JsonError`:

```d
SmallBuffer!(JsonError, 16) issues;
auto r = fromJSON!Config(text, issues);   // r: Expected!(Config, JsonError)
// r.hasError ⇒ issues holds ALL failures, each with its own path; r.error is the first
```

With a sink, the struct/sequence walks visit **every** field/element,
recording each failure and substituting the field's default (or `.init`) so
the walk can continue; the returned `Expected` still fails (carrying the
first error) — the sink adds completeness, not success. Because the walk is
generated, accumulation cannot be silently lost by composition (the
[`flatMap` trap](../../../research/serde/circe-aeson.md) cannot arise), and
paths are attached unconditionally. `@nogc` callers supply a fixed-capacity
sink; overflow drops excess errors, recorded by a final overflow marker.

### 7.2 Context

Decode/encode entry points accept an optional `ref Ctx` (any user type)
threaded to every context-taking converter, check, and hook. `Ctx` is a
template parameter defaulting to `void` — absent, the context plumbing
compiles away entirely. Decode and encode contexts are independent template
instantiations, so a type whose decode needs a service encodes context-free
([Effect's RD/RE split](../../../research/serde/effect-schema.md)). Sibling
field access during decode is deliberately **not** in this revision: its
ordering questions (declaration-order vs wire-order arrival) are deferred
with the string-tree IR ([PLAN](./PLAN.md) E9).

## 8. Metadata and the round-trip predicate

### 8.1 Metadata UDAs

```d
@WireDoc("Listening port for the public API")
@WireExample(8080)
ushort port;

@WireDeprecated("use httpPort")  // paired naturally with @WireAlias
```

`@WireDoc`, `@WireExample!F(value)` (typed by the field), and
`@WireDeprecated` attach to any type, field, or enum member; they never
affect bytes on the wire and are excluded from the [digest](#23-schema-digest),
but are recorded in the schema for derivations (help text, JSON Schema,
deprecation warnings). When a symbol has no `@WireDoc`, a schema consumer may
opt in to harvesting the symbol's ddoc comment via `__traits(docComment)` —
the doc string a programmer already wrote
([facet keeps doc comments](../../../research/serde/facet.md)). Derivation
_emitters_ (JSON Schema, `--help`) are consumers of this metadata and land
with the CLI format ([PLAN](./PLAN.md) E10) — this spec only guarantees the
metadata survives into the schema.

### 8.2 `isWireRoundTrippable`

```d
static assert(isWireRoundTrippable!(Json, Config));
```

A compile-time predicate over the schema: `true` iff no field carries an
asymmetry that breaks `decode(encode(x)) == x` — a serialize-only converter,
a presence-carrying converter that can drop information, a `@WireDefault`
differing from the omission comparison value, an `untagged` union that failed
sentinel inference under `WireMatch.first`, or an `ignore`-policy type that
was asked to preserve. Converters may assert their own invertibility with
`@WireIsomorphic`, which the predicate trusts. The predicate is the
machine-checkable form of the corpus's round-trip-breaker checklist
([delta row 18](../../../research/serde/comparison.md#the-delta-table)) and
is the property the CLI format's `parse(render(x)) == x` tests build on.

## 9. Compatibility

- **Source-compatible:** every base-spec program without `SumType` fields
  keeps its behaviour and its wire bytes; the JSON walker re-expression is
  gated on byte-identical output (§2.2).
- **Breaking:** the `SumType` default representation (§3.1) — annotate
  `@WireUnion(UnionRepr.untagged)` to keep old bytes; the compile-time
  ambiguity proof (§3.3) may reject previously-accepted ambiguous untagged
  unions (the fix is a sentinel, `WireMatch.first`, or a tagged
  representation).
- **Fixed, not flagged:** base §4.3 static arrays and base §5.2 slot-target
  reach now behave as always specified; code relying on the divergent
  behaviour (there is none in-tree) was relying on a defect.

The three divergences and their resolution are cross-referenced from
[open-issues.md](../open-issues.md) (O14–O16).
