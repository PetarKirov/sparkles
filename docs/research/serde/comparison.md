# Comparison & synthesis

The capstone of the [serde-expressiveness survey](./index.md): the surveyed
systems side by side, the per-dimension consensus, the architectural trade-offs
— and the delta table mapping each modern capability to where
[`sparkles:wired` stands today](./wired-baseline.md).

**Last reviewed:** August 9, 2026

---

## At a glance

[Tier][tiers] is the artifact holding structural knowledge; **Render argv**
asks whether anything in the ecosystem produces a command line _from_ a value
(the survey's motivating question — see [argv as a codec][argv-codecs]).

| System                                           | Tier | Bidirectional               | Reified schema            | Validation   | Error accumulation    | Unknown-field preserve | Migrations       | Render argv       |
| ------------------------------------------------ | :--: | --------------------------- | ------------------------- | ------------ | --------------------- | ---------------------- | ---------------- | ----------------- |
| [serde][serde] (Rust)                            |  1   | ✅ per-type derives         | ❌ (hence [facet][facet]) | ❌ split off | ❌ (bolt-on `eserde`) | ◐ `flatten` map hack   | ❌               | ❌                |
| [facet][facet] (Rust)                            |  3   | ✅                          | ✅ runtime `Shape`        | ◐ nascent    | ◐                     | ◐                      | ❌               | ◐ parse-only args |
| [Effect Schema][effect-schema] (TS)              | 2/3  | ✅ one parser, flipped AST  | ✅ runtime AST            | ✅ checks    | ✅ `errors: "all"`    | ◐ `preserve` option    | ❌               | ❌                |
| [Pydantic v2][pydantic] (Python)                 |  3   | ✅                          | ✅ core schema (Rust)     | ✅ built-in  | ✅ error list         | ✅ `model_extra`       | ❌               | ❌                |
| [msgspec & cattrs][msgspec-cattrs]               | 1/3  | ✅                          | ◐                         | ✅ Meta      | ❌ fail-fast          | ◐                      | ❌               | ❌                |
| [zio-schema][zio-schema] (Scala)                 |  3   | ✅ lens/prism pairs         | ✅ pattern-matchable ADT  | ✅           | ◐                     | ✅ `DynamicValue`      | ✅ **algebra**   | ❌                |
| [autodocodec / tomland / unjson][haskell-codecs] |  2   | ✅ profunctor codecs        | ✅ inspectable GADT       | ◐            | ✅ (tomland, unjson)  | ❌                     | ❌               | ❌                |
| [circe & aeson][circe-aeson]                     |  1   | ✅ paired instances (drift) | ❌                        | ❌           | ◐ circe (fragile)     | ❌                     | ❌               | ❌                |
| [OCaml ppx & ATD][ocaml-atd]                     | 1/3  | ✅                          | ◐ external `.atd`         | ◐ `_v.ml`    | ❌                    | ◐ `open_enum` only     | ◐ `atddiff` lint | ❌                |
| [clap / optparse-applicative][argv-codecs]       |  —   | ❌ parse-only               | ✅ inspectable parser     | ✅ runtime   | ◐                     | ◐ trailing args        | ❌               | ❌                |
| [**wired today**][wired-baseline]                |  1+  | ✅                          | ◐ flat field table        | ❌           | ❌                    | ❌                     | ❌               | ❌ (goal)         |

## Per-dimension consensus

For each [analysis-spine](./index.md#the-analysis-spine) dimension: what the
strongest surveyed design does, and who sets the bar.

### Schema model & bidirectionality

The consensus among the strongest systems is **schema-as-data interpreted in
both directions**: Effect runs one parser over a flipped AST; zio-schema holds
a lens per field and a prism per case; pydantic-core compiles a schema value.
Tier-1 systems generate both directions but can answer no _questions_ about the
type afterwards — the ceiling [circe & aeson][circe-aeson] document as "no
docs, no field enumeration, per-format re-derivation". [facet][facet] is the
proof the ceiling hurts enough that Rust rebuilt reflection at runtime.
**Bar-setter:** [zio-schema][zio-schema] (`serializable: Schema[Schema[A]]`).
**D's position:** the reified value can be a _compile-time constant_ —
tier-3 capability at tier-1 cost, unoccupied anywhere else.

### Naming, optionality & defaults

Consensus vocabulary: per-symbol rename + per-type case convention +
**read-many/write-one aliases** + direction-split renames
([serde][serde] has all four). On [presence][presence], the strongest designs
separate wire-presence, default channels, and provenance:
[Effect][effect-schema]'s decoding-default vs constructor-default split,
[Pydantic][pydantic]'s `model_fields_set` + `exclude_unset`, ATD's `?`/`~`
trichotomy, autodocodec's four optionality constructors. Every library with
fewer distinctions has a documented bug class.
**Bar-setter:** [Pydantic][pydantic] (provenance) + [Effect][effect-schema]
(the full matrix).

### Sum types & discrimination

Consensus: all [four representations][sum-reprs] declaratively selectable
([serde][serde], [aeson][circe-aeson]), with three escalating discriminator
designs — declared tags, [Effect][effect-schema]'s _inferred sentinels_ (any
non-optional literal field discriminates, no annotation needed), and
[Pydantic][pydantic]'s _callable_ discriminators (the tag is what a function
extracts — which is exactly a subcommand name in `argv[0]`).
[autodocodec][haskell-codecs] adds the joint/disjoint declaration that changes
the emitted schema. Untagged error quality is bad everywhere
(serde's "did not match any variant", aeson keeping only the last error).
**Nobody proves disjointness at compile time — D can.**

### Transformations & validation

Consensus: fallible, direction-paired transformations as reusable values
([Effect][effect-schema]'s `Transformation`, tomland's `BiMap`-with-reasons),
plus a **type-shaped adapter layer** for representation choice
([serde_with][serde]'s `SerializeAs` — the composition lesson), plus
**validation inside the codec** with constraint _metadata_ feeding schema and
docs ([Pydantic][pydantic], Effect checks with `meta`). serde's
validation-as-a-separate-crate split is the corpus's named mistake: two
vocabularies, forgettable second call, errors that don't unify, constraints
invisible to the schema. [Pydantic][pydantic]'s wrap validators show the hook
signature to standardize on: `fn(value, next)`.

### Errors & context

Consensus: structured errors with an **automatically attached path** and an
**accumulation mode** — [unjson][haskell-codecs] sets the bar (all problems,
path-anchored, plus a usable partial value). The two structural hazards are
manual path attachment (forgettable — aeson) and monadic composition silently
killing accumulation (circe #837/#2062); a generated walk is immune to both.
On context: [Effect][effect-schema] splits decode-services from
encode-services at the type level; [Pydantic][pydantic] threads an untyped
context object; serde's `DeserializeSeed` shows the cost of bolting it on
late. D can infer two typed `Ctx` parameters, `void` and free when unused.

### Metadata, derivations & extensibility

Consensus among tier-2/3: **one declaration, N artifacts** — JSON Schema,
docs, generators, equality, diffing ([Effect][effect-schema]'s annotation→
derivation table; [zio-schema][zio-schema]'s codec-per-format;
autodocodec's docs-as-a-constructor). The load-bearing rule, learned from
schemars' leaks: **attributes must be data, not function pointers**, or every
generator goes blind exactly where the schema gets interesting. On unknown
fields, only [zio-schema][zio-schema] (via `DynamicValue`) and
[Pydantic][pydantic] (`model_extra`) round-trip unmodelled data — no tier-1/2
library does. Constraint-guided test-data generation
([Effect][effect-schema]'s Arbitrary) is the highest-value derivation to copy.

## Architectural trade-offs

| Trade-off                         | Position A                                                           | Position B                                                         | The D resolution                                                         |
| --------------------------------- | -------------------------------------------------------------------- | ------------------------------------------------------------------ | ------------------------------------------------------------------------ |
| Where structure lives             | compiled away (tier 1: fast, unanswerable)                           | runtime value (tier 2/3: derivable, slower/hand-written)           | CTFE constant: derivable _and_ compiled away                             |
| Data model                        | fixed universal model (serde's 29 types — round-trip trap #1556)     | per-format vocabulary (no shared policy)                           | open core + format-declared extensions via DbI                           |
| Async/effects in the core         | every leaf effect-valued ([Effect][effect-schema] — uniform, costly) | sync-only (serde — fast, no context)                               | sync `@nogc` core; typed `Ctx`; async as per-converter escape hatch      |
| Representation choice attachment  | on the type (newtypes — serde `try_from`)                            | at the use site (adapters, converter objects — serde_with, cattrs) | both: UDAs on fields + a `Policy` parameter for types you don't own      |
| Degradation on unsupported shapes | silent (`toCodecJson` → `null`; projections drop checks)             | hard error                                                         | `static assert` with a sentence of explanation                           |
| Unparsing/render direction        | discard the mapping (clap), nominal hacks (`reverse_argparse`)       | —                                                                  | named struct fields are nominal by construction — render is a third fold |

## The delta table

Each capability row: the bar-setter, wired today (from the
[baseline][wired-baseline]), and the [D-feasibility tag][tags]. Rows marked
**⚠ not retrofittable** constrain API decisions that must precede the CLI
format.

| #   | Capability                                                        | Bar-setter                             | wired today                      | Feas. | Notes                                                         |
| --- | ----------------------------------------------------------------- | -------------------------------------- | -------------------------------- | :---: | ------------------------------------------------------------- |
| 1   | Reified schema tree (arena, annotations on every node, ref-nodes) | zio-schema, facet, pydantic-core       | ◐ flat one-level `FieldPolicy[]` |  (b)  | everything below walks it                                     |
| 2   | Schema-driven generic walk (new format = new walker)              | zio-schema codecs                      | ✘ hand-written JSON ladders      |  (b)  | root cause of the probe-verified divergences                  |
| 3   | Four tagged-union representations + `@WireOther`                  | serde, aeson                           | ✘ untagged only                  |  (a)  | blocks subcommands                                            |
| 4   | Inferred sentinels + callable discriminators                      | Effect, Pydantic                       | ✘                                |  (b)  | subcommands stop being a parser special case                  |
| 5   | Compile-time untagged-ambiguity proof                             | **nobody**                             | ✘                                |  (b)  | novel capability                                              |
| 6   | Metadata axis + derivations (help, JSON Schema, generators)       | Effect annotations, autodocodec        | ✘                                |  (a)  | attributes-as-data rule; `__traits(docComment)`               |
| 7   | Validation in-codec, cross-field, constraint metadata             | Pydantic, Effect checks                | ✘                                |  (a)  | avoid serde's split                                           |
| 8   | Error accumulation + partial value, paths unconditional           | unjson                                 | ✘ fail-fast, one slot            | (a/b) | sink-based for `@nogc`                                        |
| 9   | Presence tri-state + `wasSet` provenance (`Decoded!T`)            | Pydantic                               | ✘ collapsed by design            |  (b)  | **⚠ not retrofittable**; required for layering & argv render  |
| 10  | Decoding-default vs constructor-default channels                  | Effect                                 | ✘ one channel                    |  (a)  | **⚠** — else `encode(decode(argv))` invents flags             |
| 11  | Aliases (read-many/write-one) + direction-split renames           | serde                                  | ✘ one name per (symbol, format)  |  (a)  | also the short-flag mechanism                                 |
| 12  | Unknown-field knob + `@WireExtra` preservation                    | Pydantic, zio-schema                   | ◐ ignore only                    |  (a)  | beats every tier-1/2 library for one branch of work           |
| 13  | Presence-carrying converters, chains, `@WireAs` adapters          | Effect `Getter`, serde_with            | ◐ bare `Wire→Domain`             | (a/b) | **⚠** converter ABI                                           |
| 14  | Typed decode/encode contexts + sibling-field access               | Effect `RD`/`RE`; nobody has siblings  | ✘                                |  (b)  | **⚠** hook ABI; "D can, serde can't" headline                 |
| 15  | Wrap-hook middleware `fn(value, next)`                            | Pydantic                               | ✘                                |  (b)  | **⚠** hook ABI                                                |
| 16  | `update`/partial-merge (config layering)                          | unjson                                 | ✘                                |  (a)  | defaults ⊕ file ⊕ env ⊕ argv as one mechanism                 |
| 17  | Typed `DynValue` + string-tree IR                                 | zio-schema; Effect `toCodecStringTree` | ✘ JSON arena only                |  (b)  | the argv intermediate representation                          |
| 18  | `WireRoundTrippable!T` compile-time predicate                     | **nobody**                             | ✘                                |  (b)  | encode the corpus's round-trip-breaker checklist              |
| 19  | Schema digest golden → (later) migration algebra                  | ATD `atddiff` → zio-schema             | ✘                                | (b/c) | digest first; CTFE-derived migrations when both schemas known |
| 20  | Projections `Pick`/`Omit`/`Partial`/`WithFields`                  | Effect/TS mapped types                 | ✘                                |  (b)  | the 90% four; skip the full algebra                           |

Also owed regardless of the redesign: the three
[probe-verified divergences](./wired-baseline.md#probe-verified-spec-divergences)
(static arrays, slot-targeted policies, per-variant union errors).

## What deliberately not to copy

Convergent across the deep-dives:

- **serde's fixed 29-type data model and the Visitor pattern** — keep the model
  open; argv needs vocabulary (count, arity, positional) no fixed model hosts.
- **An effect-shaped core** — Effect pays allocation on every field for async
  almost no schema uses.
- **A runtime AST** — D's compile-time type graph is the AST.
- **Silent degradation** anywhere (unrepresentable → `null`, projections
  dropping checks, flatten forcing `deserialize_any`) — `static assert` instead.
- **aeson's closed global `Options` record**; the full projection algebra;
  smart-union exactness scoring; stringly-typed annotation keys; `BiArrow`-style
  capability interfaces that declare methods they `error` on.

## Consequence for the CLI-on-wired plan

The delta table's ⚠ rows (9, 10, 13, 14, 15) are API-shaping and precede any
`Cli` format work; rows 1–8 are what make the format a _walker_ rather than a
second bespoke engine. The resulting sequencing — wired core upgrade first
(with the JSON conformance suite and bench baseline as the regression gate),
then the `Cli` format as the second walker (with the five example CLIs and
their `--help` goldens as the oracle) — replaces the original "desugar the CLI
UDAs onto today's six `@Wire*` attributes" plan, which would have recreated
the bespoke engine under a different name. The competitive headlines all sit
in the novel-capability rows: 5, 14 (sibling access), 18, and the render half
of [argv][argv-codecs] itself.

<!-- References -->

[serde]: ./serde.md
[facet]: ./facet.md
[effect-schema]: ./effect-schema.md
[pydantic]: ./pydantic.md
[msgspec-cattrs]: ./msgspec-cattrs.md
[zio-schema]: ./zio-schema.md
[haskell-codecs]: ./haskell-codecs.md
[circe-aeson]: ./circe-aeson.md
[ocaml-atd]: ./ocaml-atd.md
[argv-codecs]: ./argv-codecs.md
[wired-baseline]: ./wired-baseline.md
[tiers]: ./concepts.md#the-three-tiers
[tags]: ./concepts.md#d-feasibility-tags
[presence]: ./concepts.md#the-presence-problem
[sum-reprs]: ./concepts.md#sum-type-representations
