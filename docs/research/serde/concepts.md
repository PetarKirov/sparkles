# Concepts & vocabulary

Shared vocabulary for the [serde-expressiveness survey](./index.md). Every term is
defined once here and referenced from the deep-dives; each definition links to the
subject that exemplifies it best.

**Last reviewed:** August 9, 2026

---

## The three tiers

Every surveyed library sits in one of three architectural tiers, distinguished by
**what artifact holds the structural knowledge** of a type:

| Tier                     | Artifact                          | Members                                                                                                                | Unlocks                                                                          | Costs                                                                     |
| ------------------------ | --------------------------------- | ---------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------- | ------------------------------------------------------------------------- |
| **1. Codegen-only**      | nothing — two generated functions | [serde][serde], [aeson/circe derived][circe-aeson], [OCaml ppx][ocaml-atd]                                             | one format, both directions, zero ceremony                                       | no docs, no migrations, no diffing; encoder/decoder can drift             |
| **2. Value-level codec** | a runtime combinator value        | [autodocodec, tomland, unjson][haskell-codecs], [invertible syntax][invertible-syntax], [Effect Schema][effect-schema] | both directions **plus** docs/schema from one value, guaranteed non-drift        | hand-written per type; arity/composition tax; runtime interpretation      |
| **3. Reified schema**    | a first-class schema **value**    | [zio-schema][zio-schema], [facet][facet], [pydantic-core][pydantic], [ATD][ocaml-atd] (external file)                  | everything in tier 2, plus N formats, diff/patch, migrations, optics, generators | schema construction cost; usually macro-derived to hide the authoring tax |

The strategic observation driving this survey: **D's `struct` + UDAs + CTFE is a
tier-1 syntax that can synthesize a tier-3 artifact at compile time** — a reified
schema as a compile-time constant, with no runtime construction and no macro
system. No other surveyed language occupies that position: Scala pays macros plus
runtime value construction, OCaml needs an external `.atd` file or a `repr` value,
Rust's [facet][facet] pays 3–6× throughput to recover reflection at runtime, and
TypeScript's [Effect Schema][effect-schema] pays 15 phantom type parameters for
information D has in `__traits`.

## D-feasibility tags

Every deep-dive in this tree closes each analysis dimension with a **D verdict**
carrying one of three tags:

- **(a) — trivially expressible as D struct + UDA.** The capability maps onto a
  plain attribute plus the existing compile-time walk; often the D form is
  _simpler_ than the original because the original mechanism exists to compensate
  for missing reflection.
- **(b) — expressible with CTFE effort.** Real design or codegen work: a mixin
  that synthesizes a type, a compile-time schema arena, a two-phase walk. No
  research risk, but not free.
- **(c) — fundamentally needs value-level composition.** The capability requires
  runtime schema values or opaque function composition that compile-time
  reflection cannot recover (e.g. migrating live data of an unknown old schema
  version, or choosing among many concrete renderings of one abstract value).

The tags come from the underlying research reports and are deliberately coarse —
they answer "does this belong in `sparkles:wired`'s UDA surface, its CTFE layer,
or a runtime escape hatch?"

## Bidirectionality and the round-trip laws

A **bidirectional codec** derives both `decode : Wire → T` and `encode : T → Wire`
from one declaration, so the two cannot drift. The mechanisms differ per tier:
tier 1 generates both functions from the same type; tier 2 holds both directions
in one value (a [profunctor codec](#partial-isomorphisms-prisms-lenses)); tier 3
interprets one schema in both directions ([Effect Schema][effect-schema] literally
runs _one_ parser over a flipped AST: `encode(schema) = decode(flip(schema))`).

The round-trip **laws** are asymmetric, and the asymmetry is a finding of
[invertible syntax descriptions][invertible-syntax]:

- `decode(encode(x)) == x` — the law worth stating, _modulo a chosen equivalence_
  (floating-point transforms, omitted-when-default fields).
- `encode(decode(s)) == s` — **never promise this.** Concrete syntax admits many
  spellings of one value (`--port 8080` vs `--port=8080`; reordered JSON keys);
  the encoder must canonicalize.

Known round-trip breakers, enumerated across the corpus: decode-only defaults,
omit-on-encode fields, lossy transforms, dropped unknown fields, union first-match
overlap, and key-transformations that collapse keys. A D design can turn this
checklist into a compile-time predicate over the schema — something no surveyed
library offers.

## Partial isomorphisms, prisms, lenses

The FP lineage's settled taxonomy of "functions that run backwards"
(see [invertible syntax][invertible-syntax] for the full treatment):

| Shape                | Signature                          | Serialization role                            | D answer                                                                 |
| -------------------- | ---------------------------------- | --------------------------------------------- | ------------------------------------------------------------------------ |
| **Partial iso**      | `a → Maybe b`, `b → Maybe a`       | parse ⇄ print of one construct                | generated per constructor; value-level escape hatch for custom spellings |
| **Prism**            | `s → Maybe a`, `a → s`             | sum-branch selection                          | `SumType` tag switch, CTFE-generated                                     |
| **Lens**             | `s → a`, `a → s → s`               | field access; **`update`/PATCH** semantics    | `.tupleof` (a `ref` field _is_ a lens)                                   |
| **Profunctor codec** | `Codec ctx i o` + `lmap` accessors | supplying the encode direction field-by-field | `__traits(getMember)` supplies `lmap` free                               |

The recurring result: each shape exists at the value level to recover, at run
time, structure the host language's type system erased. D never erases it, so the
_interpretations_ these shapes enable (both directions, docs, schema emission)
survive while the combinator machinery disappears.

## The presence problem

Field "optionality" is at least three independent questions, and every library
that conflates them has a documented bug class
(the [Haskell codecs][haskell-codecs] enumerate the matrix most explicitly;
[Effect Schema][effect-schema] expresses 16 distinct semantics from five axes):

1. **Wire presence** — was the key/flag present at all? Distinct from carrying an
   explicit `null`. ATD's `?field` (absent → `None`) vs `~field` (absent →
   default, type stays plain) is the minimal statement
   ([OCaml ppx & ATD][ocaml-atd]).
2. **Default channels** — a _decoding default_ ("the flag was not passed, use
   this") is different from a _constructor default_ ("the programmer omitted this
   field when building the value"), with different timing. A bidirectional argv
   codec must keep them separate or `encode(decode(argv))` emits flags the user
   never typed ([Effect Schema][effect-schema]).
3. **Provenance / unset-tracking** — "was this field _set_, or does it merely
   equal its default?" [Pydantic][pydantic] stores this in a side channel
   (`model_fields_set`) and exposes `exclude_unset`; config layering
   (defaults ⊕ file ⊕ env ⊕ argv) is unimplementable without it. In D the
   presence mask must live _outside_ the value type (a `Decoded!T` pair), or it
   destroys POD-ness and equality.

**Encode-side omission** is the mirror image: emit the shortest wire form that
reads back identically (`skip_serializing_if`, `omitNothingFields`,
`@omitIfDefault`) — the minimality half of round-tripping.

## Sum-type representations

The four wire encodings of a tagged union, named as in [serde][serde] (the
concrete table with JSON examples is in [circe & aeson][circe-aeson]):

| Representation        | Wire shape                   | Needs [self-describing](#self-describing-formats) input? | Notes                                                      |
| --------------------- | ---------------------------- | -------------------------------------------------------- | ---------------------------------------------------------- |
| **Externally tagged** | `{"Variant": {…}}`           | no                                                       | the only form that works without buffering                 |
| **Internally tagged** | `{"type": "Variant", …}`     | yes                                                      | tag-field collision hazard; no tuple variants              |
| **Adjacently tagged** | `{"t": "Variant", "c": {…}}` | yes                                                      | handles every variant shape, tag stays explicit            |
| **Untagged**          | `{…}` (bare)                 | yes                                                      | declaration-order trial; ambiguity + error-quality hazards |

A **discriminator** is the tag field/value that selects the branch. Three
escalating designs appear in the corpus: _declared_ discriminators
(`#[serde(tag = "type")]`), _inferred_ **sentinels** (Effect Schema harvests any
non-optional literal field as a discriminant automatically), and _callable_
discriminators ([Pydantic][pydantic]'s `Discriminator(fn)` — the tag is whatever
a function extracts from the wire form, which is exactly how a subcommand name in
`argv[0]` selects a command struct; see [argv as a codec][argv-codecs]).
[autodocodec][haskell-codecs] adds the **joint vs disjoint** distinction: the
author states whether untagged branches may overlap, and the statement changes
the emitted schema (`anyOf` vs `oneOf`). A compile-time _disjointness proof_ —
rejecting ambiguous untagged unions at build time — is expressible in D and in no
surveyed library.

## Self-describing formats

A **self-describing** format (JSON, YAML, MessagePack) carries enough structure
to parse without knowing the target type; a **non-self-describing** format
(bincode, postcard, protobuf-without-schema) is meaningful only against the
schema. The split decides which features can exist at all: untagged unions,
`flatten`, and internal tagging all require buffering self-described input
([serde][serde] §How it works). Argv is a third category the Rust ecosystem has
no name for — **key-describing but type-blind**: `--name` is a key, but its value
is untyped text and a bare word may be positional ([argv as a codec][argv-codecs]).

## Format-neutral intermediates: DOM vs `DynamicValue` vs string tree

Three different "untyped middle" designs, easily conflated:

- A **DOM** (aeson `Value`, circe `Json`, a JSON arena) describes a _document_ —
  it has erased what type the data had (`Number Scientific` no longer knows it
  was an `Int32` or a `Duration`). Fine as a parse target; wrong as a codec
  interop point ([circe & aeson][circe-aeson]).
- A **typed dynamic value** ([zio-schema][zio-schema]'s `DynamicValue`) carries
  _type witnesses alongside the data_ — primitives keep their `StandardType`,
  records keep their `TypeId`, enum cases keep their names. That is what makes it
  a legitimate intermediate for binary formats, migrations, and re-typing without
  re-reading bytes, and it is the only principled unknown-data escape hatch in
  the corpus.
- A **string tree** ([Effect Schema][effect-schema]'s `toCodecStringTree`) is the
  all-leaves-are-strings intermediate shared by FormData, URL search params, env
  vars — and argv. Structure is preserved; non-string leaves are recovered by the
  schema on the way in.

## Converters vs adapters

Two shapes for "represent this field differently on the wire":

- A **converter** is function-shaped: `to : T → Wire`, `from : Wire → T`
  (wired's `@WireConvert`, serde's `with =`). Functions don't compose over
  container structure — `Duration` as seconds says nothing about
  `Duration[]` as seconds.
- An **adapter** is type-shaped ([serde_with][serde]'s `SerializeAs` shadow
  traits): the annotation mirrors the _type's_ structure with an identity hole
  (`BTreeMap<_, DisplayFromStr>`), and blanket rules make adapters compose
  recursively. Attaching representation choice to a type expression rather than
  a function is the design lesson; D templates state it even more directly
  (`@WireAs!(Map!(Same, DisplayFromStr))`).

Two related upgrades recur: converter signatures that **carry presence**
(Effect's `Getter` maps `Option → Option` on both sides, so "omit on encode" and
"default on absence" are ordinary transformations), and **wrap middleware**
([Pydantic][pydantic]'s `fn(value, next)` hooks, where a hook receives the rest
of the pipeline and can retry, fall back, or rewrite errors around it —
before/after hooks are its degenerate cases).

## Unknown-field policy

Three-valued, per type: **ignore** (decode what you model, drop the rest —
everyone's default), **forbid** (`deny_unknown_fields`, `extra="forbid"` — the
right CLI default: unknown flag is an error), **preserve** (capture unmatched
keys into a catch-all field and splice them back on encode — Pydantic's
`model_extra`, zio-schema's `Schema.Dynamic`). Preservation is the rarest:
**no tier-1 or tier-2 library in the survey round-trips unmodelled data**, which
makes it a cheap differentiator.

## Error accumulation and paths

Two independent qualities of a decode error:

- **A path** to the failing element (`$.groups[1].name`, `--server.port`) —
  attached automatically by generated walks; attached _manually_ in combinator
  designs and therefore forgettable (aeson's `(<?>)`;
  [serde][serde] needs a wrapper crate to answer "which field?").
- **Accumulation** — reporting all failures, not the first. Requires every branch
  to run, which `Applicative` composition guarantees and monadic bind silently
  destroys (circe's documented `flatMap`-kills-accumulation trap). A generated
  walk is structurally immune, and [unjson][haskell-codecs] shows the strongest
  target: all problems, each path-anchored, _plus a usable partial value_.

<!-- References -->

[serde]: ./serde.md
[facet]: ./facet.md
[effect-schema]: ./effect-schema.md
[pydantic]: ./pydantic.md
[zio-schema]: ./zio-schema.md
[circe-aeson]: ./circe-aeson.md
[haskell-codecs]: ./haskell-codecs.md
[invertible-syntax]: ./invertible-syntax.md
[ocaml-atd]: ./ocaml-atd.md
[argv-codecs]: ./argv-codecs.md
