# Serde Expressiveness

A breadth-first survey of the most expressive (de)serialization frameworks
across languages — TypeScript, Rust, Python, Scala, Haskell, OCaml — to inform
the redesign of [`sparkles:wired`](./wired-baseline.md) as a state-of-the-art
serde framework in _expressive power_ (it already competes on JSON
performance), and to ground the plan of re-expressing CLI argument parsing as
a bidirectional wired format (`argv` ⇄ struct).

This survey answers five questions:

1. **What can the strongest schema systems express** — the full capability
   surface of [Effect Schema][effect-schema], [serde][serde] + its satellite
   ecosystem, [Pydantic v2][pydantic], and [zio-schema][zio-schema], axis by
   axis? See the [catalog](#master-catalog) and each deep-dive's
   [analysis spine](#the-analysis-spine).
2. **What does bidirectionality actually require** — how do one-declaration/
   two-directions designs work ([profunctor codecs][haskell-codecs],
   [partial isomorphisms][invertible-syntax], flipped-AST interpretation
   [in Effect][effect-schema]), and which laws can honestly be promised? See
   [concepts § round-trip laws][concepts-laws].
3. **Where does each declaration style hit its ceiling** — attributes/derives
   ([serde][serde], [OCaml ppx][ocaml-atd], [circe/aeson][circe-aeson]),
   value-level combinators ([Haskell codecs][haskell-codecs]), reified schemas
   ([zio-schema][zio-schema], [facet][facet])? See
   [concepts § the three tiers][concepts-tiers] and [comparison][comparison].
4. **Can argv be a serde format, bidirectionally** — what did clap,
   `serde_args`, `facet-args`, and `optparse-applicative` prove about parsing,
   and why has _nobody_ shipped the render half? See
   [argv as a codec][argv-codecs].
5. **What must `sparkles:wired` add** — measured against a probe-verified
   [baseline][wired-baseline], which capabilities close the gap, which are
   novel-to-D, and which API decisions are not retrofittable? See the
   [delta table][delta].

> **Scope note.** This is a survey of _expressiveness_, not performance —
> throughput comparisons appear only where they price a design choice (e.g.
> [facet][facet]'s reflection tax, tomland's interpretation-vs-codegen
> benchmark). The [Effect Schema][effect-schema] deep-dive was grounded in a
> local checkout of the v4 "smol" rewrite (pinned commit `3a1128c7`); the
> [wired baseline][wired-baseline] is grounded in runnable probes CI compiles
> and runs. The design decisions this survey feeds land in
> [`docs/specs/wired/`](../../specs/wired/SPEC.md) revisions, not here.

**Last reviewed:** August 9, 2026

---

## Master Catalog

One row per surveyed subject. **Tier** is the
[three-tier classification][concepts-tiers] by what artifact holds the
structural knowledge (1 = codegen-only, 2 = value-level codec, 3 = reified
schema). **Declaration surface** is what the user writes.

| Subject                                | Language(s)     | Tier | Declaration surface                         | Distinguishing capability                                                | Link                                      |
| -------------------------------------- | --------------- | :--: | ------------------------------------------- | ------------------------------------------------------------------------ | ----------------------------------------- |
| **Effect Schema** (v4 "smol")          | TypeScript      | 2/3  | value-level combinators over a reified AST  | one parser run in two directions (`flip`); annotation-driven derivations | [effect-schema.md][effect-schema]         |
| **serde** (+ `serde_with`, `schemars`) | Rust            |  1   | `#[derive]` + attributes                    | the universal-data-model architecture and its documented walls           | [serde.md][serde]                         |
| **facet**                              | Rust            |  3   | one derive → runtime `Shape` value          | reflection-as-data: one derive, N consumers                              | [facet.md][facet]                         |
| **Pydantic v2**                        | Python          |  3   | class annotations compiled to a core schema | wrap-hook middleware; presence provenance; callable discriminators       | [pydantic.md][pydantic]                   |
| **msgspec & cattrs**                   | Python          | 1/3  | annotated structs / converter objects       | strict schema-guided decode; policy-in-the-converter                     | [msgspec-cattrs.md][msgspec-cattrs]       |
| **zio-schema**                         | Scala           |  3   | derived `Schema[A]` value                   | migrations, diff/patch, `DynamicValue` — the full tier-3 payoff          | [zio-schema.md][zio-schema]               |
| **autodocodec, tomland & unjson**      | Haskell         |  2   | hand-written profunctor codecs              | self-documenting codecs; path-anchored accumulation; `update`            | [haskell-codecs.md][haskell-codecs]       |
| **circe & aeson**                      | Scala / Haskell |  1   | derived instances + options                 | the derivation-only ceiling, precisely mapped                            | [circe-aeson.md][circe-aeson]             |
| **Invertible syntax descriptions**     | theory          |  2   | partial-iso combinators                     | why codecs can't be monads; round-trip laws modulo equivalence           | [invertible-syntax.md][invertible-syntax] |
| **OCaml ppx & ATD**                    | OCaml           | 1/3  | `[@@deriving]` attributes / external `.atd` | the `?`/`~` field trichotomy; `atddiff`; a shipping D backend            | [ocaml-atd.md][ocaml-atd]                 |
| **argv as a codec**                    | cross-language  |  —   | clap/optparse/facet-args/serde_args         | why parse-only is the universal state of the art                         | [argv-codecs.md][argv-codecs]             |
| **`sparkles:wired`** (baseline)        | D               |  1+  | structs + `@Wire*!Format` UDAs              | format-generic CTFE policy table; probe-verified gaps                    | [wired-baseline.md][wired-baseline]       |

## The analysis spine

Every deep-dive analyses its subject through the same six dimensions, each
closed with a **D verdict** carrying a [feasibility tag][concepts-tags]:

1. **Schema model & bidirectionality** — what artifact holds the structure;
   how the two directions derive from it; round-trip guarantees.
2. **Naming, optionality & defaults** — renames, case conventions, aliases;
   the [presence problem][concepts-presence].
3. **Sum types & discrimination** — [representations][concepts-sums],
   discriminators, ambiguity handling.
4. **Transformations & validation** — converters/adapters, failure channels,
   refinements, cross-field rules.
5. **Errors & context** — error structure, paths, accumulation; context
   threading through the codec.
6. **Metadata, derivations & extensibility** — annotations beyond wire
   concerns; the artifacts one declaration yields; format genericity and
   unknown-field policy.

## Taxonomy

### By tier

| Tier                  | Subjects                                                                                                 | What the survey takes from them                              |
| --------------------- | -------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------ |
| 1 — codegen-only      | [serde][serde], [circe & aeson][circe-aeson], [OCaml ppx][ocaml-atd], [wired today][wired-baseline]      | the attribute vocabulary; the precisely-mapped ceiling       |
| 2 — value-level codec | [Haskell codecs][haskell-codecs], [invertible syntax][invertible-syntax], [Effect Schema][effect-schema] | non-drift by construction; docs/schema from the codec value  |
| 3 — reified schema    | [zio-schema][zio-schema], [facet][facet], [Pydantic][pydantic], [ATD][ocaml-atd]                         | N formats, migrations, diffing, generators from one artifact |

### By capability first proven there

| Capability                                        | Proven by                                |
| ------------------------------------------------- | ---------------------------------------- |
| Docs/schema that cannot drift from the codec      | [autodocodec][haskell-codecs]            |
| Migration algebra over a typed dynamic value      | [zio-schema][zio-schema]                 |
| Inferred union sentinels                          | [Effect Schema][effect-schema]           |
| Callable discriminators                           | [Pydantic][pydantic]                     |
| Wrap-hook codec middleware                        | [Pydantic][pydantic]                     |
| Type-shaped adapter composition                   | [serde_with][serde]                      |
| Presence provenance (`exclude_unset`)             | [Pydantic][pydantic]                     |
| Path-anchored accumulation + usable partial value | [unjson][haskell-codecs]                 |
| `update`/PATCH merge semantics                    | [unjson][haskell-codecs]                 |
| Reflection artifact feeding N consumers           | [facet][facet], [zio-schema][zio-schema] |
| Inspectable parser driving help/completions       | [optparse-applicative][argv-codecs]      |

## Milestones

| When      | Event                                                                                                                               |
| --------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| 2008      | Boomerang (POPL '08): string lenses with static round-trip guarantees ([invertible syntax][invertible-syntax])                      |
| 2010      | Rendel & Ostermann, _Invertible Syntax Descriptions_ — the parse/print duality theory                                               |
| 2017      | `serde` 1.0: the universal-data-model derive architecture stabilizes                                                                |
| 2019      | `tomland`: the profunctor-codec pattern stated cleanly for TOML                                                                     |
| 2021      | `autodocodec` (self-documenting codecs) and `zio-schema` (reified `Schema[A]`) land the tier-2/3 answers                            |
| Jun 2023  | Pydantic v2: the schema layer reified and compiled to Rust (`pydantic-core`)                                                        |
| ~2023     | ATD 2.13 ships `atdd` — a D backend for the schema-IDL-first approach                                                               |
| Feb 2025  | `eserde`: the Rust ecosystem retrofits error accumulation onto serde                                                                |
| 2025      | `facet`: reflection-as-data lands in Rust — one derive, N consumers, at a measured runtime cost                                     |
| 2025–2026 | Effect Schema v4 "smol" rewrite: transformations/checks become first-class values; canonical codecs (surveyed at commit `3a1128c7`) |

## Suggested reading paths

- **"I'm designing the wired upgrade (S2)"** — [wired-baseline][wired-baseline]
  → [comparison § delta table][delta] → [effect-schema][effect-schema] →
  [serde][serde] → [zio-schema][zio-schema].
- **"I'm designing the `Cli` format"** — [argv-codecs][argv-codecs] →
  [effect-schema][effect-schema] (string-tree IR, optionality matrix) →
  [invertible-syntax][invertible-syntax] (which round-trip law to promise) →
  [wired-baseline § the bespoke engine][wired-baseline].
- **"Give me the theory"** — [concepts][concepts] →
  [invertible-syntax][invertible-syntax] → [haskell-codecs][haskell-codecs] →
  [zio-schema][zio-schema].

## Sources

Each deep-dive carries its own primary-source block (official docs, pinned
source links, issues, papers). Cross-cutting grounding:

- The [Effect Schema][effect-schema] deep-dive reads the 7 272-line `SCHEMA.md`
  and the schema source of a local `effect-smol` checkout, pinned at commit
  `3a1128c7684e04d34d9f541f77adaac38a513056`.
- The [wired baseline][wired-baseline] embeds runnable probes (compiled and run
  by `ci --verify`) for its load-bearing claims.
- The survey's synthesis and delta live in [comparison.md][comparison]; shared
  vocabulary in [concepts.md][concepts].

<!-- References -->

[effect-schema]: ./effect-schema.md
[serde]: ./serde.md
[facet]: ./facet.md
[pydantic]: ./pydantic.md
[msgspec-cattrs]: ./msgspec-cattrs.md
[zio-schema]: ./zio-schema.md
[haskell-codecs]: ./haskell-codecs.md
[circe-aeson]: ./circe-aeson.md
[invertible-syntax]: ./invertible-syntax.md
[ocaml-atd]: ./ocaml-atd.md
[argv-codecs]: ./argv-codecs.md
[wired-baseline]: ./wired-baseline.md
[comparison]: ./comparison.md
[concepts]: ./concepts.md
[concepts-tiers]: ./concepts.md#the-three-tiers
[concepts-tags]: ./concepts.md#d-feasibility-tags
[concepts-laws]: ./concepts.md#bidirectionality-and-the-round-trip-laws
[concepts-presence]: ./concepts.md#the-presence-problem
[concepts-sums]: ./concepts.md#sum-type-representations
[delta]: ./comparison.md#the-delta-table
