# facet (Rust)

Reflection for Rust as **data rather than code**: one `#[derive(Facet)]` emits a static `Shape` constant describing the type — fields, offsets, attributes, doc comments — which serialization, pretty-printing, diffing, CLI parsing and schema generation all walk at runtime.

| Field         | Value                                                                                            |
| ------------- | ------------------------------------------------------------------------------------------------ |
| Language      | Rust (derive built on `unsynn` rather than `syn`)                                                |
| License       | MIT OR Apache-2.0 (dual)                                                                         |
| Repository    | [facet-rs/facet][repo]                                                                           |
| Documentation | [facet.rs guide][why] · [docs.rs/facet][docs] · [docs.rs/facet-args][args-docs]                  |
| Category      | Runtime-reflection framework — one derive, `N` consumers (see [the three tiers][tiers])          |
| Key author    | Amos Wenger (`fasterthanlime`)                                                                   |
| First release | 2025, [introduced on fasterthanli.me][article]                                                   |
| Status        | Pre-1.0 and explicitly in flux; CLI/config work increasingly routed to a separate crate, `figue` |

> [!IMPORTANT]
> facet is the most **philosophically relevant** project in this survey, because it is Rust reconstructing at runtime what D's `__traits` already provide at compile time. Read it as a specification of what a reflection-carrying schema buys — and of what it costs when the host language makes you pay for it at runtime. The costs are real: see [Weaknesses](#weaknesses).

---

## Overview

### What it solves

[serde][serde] solves _one_ problem — moving values to and from formats — and solves it by generating code. Everything else a program might want to know about a type is unavailable afterwards. facet's framing of that gap ([Why facet?][why]) is blunt:

> _"The only way to answer questions about a type is to run a serializer against it."_

You cannot ask whether a field carries an attribute, what its doc comment says, or what the field list even is. Each adjacent need therefore spawns another derive with another attribute vocabulary: [`schemars`][schemars] for schemas, `validator`/`garde` for validation, `clap` for argv, a `Debug`-alike for redacted printing. Nothing cross-checks them, and the same fact gets written three times.

facet's thesis is **derive once, get everything**.

### Design philosophy

`#[derive(Facet)]` does not generate `Serialize`/`Deserialize` code. It generates a single associated constant — a **`Shape`** — describing the type as data. Consumers are then written once, generically, against `Shape`, and vary only in the data they walk. That inverts serde's economics: serde monomorphizes a walker per type, facet compiles the walker once and multiplies the data.

Three consequences shape the whole design:

1. **Attributes and doc comments survive into the artifact.** They are fields on the emitted structure, not tokens consumed at expansion time.
2. **Access is type-erased.** Each field records a byte `offset`, so a consumer navigates values through raw pointers plus a per-type vtable rather than through generics.
3. **Consumers are independent crates.** `facet-json`, `facet-pretty`, `facet-diff`, `facet-args`, plus TOML/YAML/MessagePack/CSV/XML/ASN.1/XDR/urlencoded/SQLite/axum integrations all read **the same** constant, and build concurrently.

---

## How it works

The derive emits a recursive description of the type graph. The shape of the shape is the whole story:

```rust
pub struct StructType<'shape> {
    pub repr: Repr,
    pub kind: StructKind,
    pub fields: &'shape [Field<'shape>],
}

pub struct Field<'shape> {
    pub name: &'shape str,
    pub shape: &'shape Shape<'shape>,                   // recursive: the whole type graph
    pub offset: usize,                                  // for type-erased pointer access
    pub flags: FieldFlags,
    pub attributes: &'shape [FieldAttribute<'shape>],   // attributes SURVIVE
    pub doc: &'shape [&'shape str],                     // doc comments SURVIVE
    pub vtable: &'shape FieldVTable,
    pub flattened: bool,
}
```

A `Shape` carries kind (struct, enum, tuple, list, map, scalar), layout (size and alignment), fields with byte offsets, doc comments, arbitrary attributes, and a vtable of type-specific operations. `Def` is the companion tree classifying what a shape _is_, for generic traversal. Because `Field.shape` is itself a `&Shape`, a consumer holding the root constant can walk the entire reachable type graph without the compiler's help — which is precisely the cross-type knowledge [serde's proc macro cannot reach][serde-structural].

---

## Schema model & bidirectionality

The `Shape` constant _is_ the schema, and it is format-neutral rather than format-shaped: `facet_value::Value` has first-class bytes and datetimes, unlike the JSON-shaped `serde_json::Value`. Both directions read the same constant, so bidirectionality is structural rather than a property of paired derives — there is no way for the serialize and deserialize views of a type to drift, because there is only one view.

Two consequences follow that serde cannot reach. **Flatten is lossless**: facet resolves it by "building possibility spaces rather than buffering intermediate representations" ([Why facet?][why]) — i.e. against the known shapes of the flattened members rather than serde's untyped `Content` buffer. That is independently the same fix [serde's flatten collision][serde-flatten] needs. And **schema generation is not a second derive**, because the schema is already the artifact.

**D verdict — [(b)][tags]:** wired should **emit a static `Shape` table anyway**. It is cheap in CTFE, and it unlocks exactly the runtime-introspection consumers serde structurally cannot have — help rendering, schema dump, structural diffing, redaction. Make it opt-in so `@nogc` binaries do not pay for it. The important difference is _when_ it is consumed: facet must walk it at runtime, whereas wired can consume the same table at compile time and emit specialized code, giving facet's expressiveness at serde's speed.

---

## Naming, optionality & defaults

This dimension is where facet is deliberately **thin**, and the thinness is the finding. facet does not ship a large naming/presence vocabulary as its product; its product is the _representation_ — `Field.attributes` is an open list that any consumer may interpret, so the vocabulary belongs to the consumer crate rather than to facet. `facet-args` contributes `args::positional`, `args::named`, `args::short`, and `args::counted`; `facet-pretty` contributes `#[facet(sensitive)]`, which redacts a field in pretty-printed and logged output while still serializing it normally.

That is a genuinely different architecture from serde's fixed `#[serde(...)]` grammar: facet does not have to anticipate every attribute, because attributes are payload, not syntax.

**D verdict — [(a)][tags]:** UDAs already _are_ an open, consumer-interpreted attribute list, so D gets facet's extensibility here for free — `__traits(getAttributes, member)` is `Field.attributes`. The concrete steal is `#[facet(sensitive)]`: a `@WireSensitive` that redacts in pretty-print and log output while still serializing is a real feature for a CLI/config library, and it is only expressible because the attribute survives to a consumer that is not the codec.

---

## Sum types & discrimination

`Shape`/`Def` model enums as first-class kinds, so the reflection layer describes discrimination fine. The finding is one level up, in the consumers: **`facet-args` parses to a struct only — no enums, and therefore no subcommands** ([facet-args docs][args-docs]). A reflection vocabulary rich enough to describe an enum does not automatically give a consumer a strategy for _decoding into_ one, and facet-args has not shipped that strategy.

**D verdict — [(a)][tags] for describing sum types, and the facet-args gap is the warning:** wired must design the enum-to-subcommand mapping **first**, because that is the entire point of the CLI-subcommands work. A schema layer that can describe a sum type but whose argv consumer cannot decode one is a half-built feature, and facet is the worked example.

---

## Transformations & validation

Barely applicable, and that is the point: facet does not host transformations or validation itself, because a `Shape` is a description, not a pipeline. Validation is a separate consumer, `facet-validate`, in the same way that [`eserde`][eserde] and `garde` are separate from serde. The improvement over serde is only that a facet validator and a facet codec read the **same** annotations, so the constraint is written once instead of being restated for the schema generator and the validator — the fourth of [the five costs of serde's validation split][serde-validation].

**D verdict — [(a)][tags]/[(b)][tags]:** the lesson transfers as "one UDA vocabulary, many consumers", not as a mechanism. wired should go one step further than facet and run `@WireValidate` **inside** the codec, so an invalid value is never constructed at all, while still emitting the constraint into the shape so `--help` and a JSON Schema can render it.

---

## Errors & context

This is one of facet's clearer wins over serde and it follows directly from shapes being data. Because a shape carries names and the walker always knows where it is in the graph, facet stores byte offsets and shape pointers and formats errors **lazily**, including did-you-mean suggestions for misspelled fields. Compare serde, where the failing context lives on the call stack inside a `Visitor` method and the `Error` trait has nowhere to put it, so a whole wrapper crate exists to recover the field path.

Context threading is not something the report found facet solving better than serde; it is simply less painful, because a runtime walker holds its own state rather than needing serde's un-derivable `DeserializeSeed`.

**D verdict — [(a)][tags]:** the mechanism is identical in D and cheaper — a generated codec knows the field name _statically_ at every recursion step, so a `WireError` carrying a field path, a byte offset and the expected shape costs nothing at runtime. facet pays for good errors with a runtime walk; wired does not have to.

---

## Metadata, derivations & extensibility

This is facet's raison d'être and the section the rest of the page exists to set up.

- **One derive, `N` consumers.** Serialization, deserialization, pretty-printing with redaction, structural diffing, CLI parsing and schema generation all come from one annotation.
- **Attributes and docs survive into the artifact,** so a consumer can ask questions of a type instead of running a serializer at it.
- **A compile-time win by avoiding monomorphization.** serde instantiates `to_string_pretty::<T>` per type; facet compiles the walker once and varies the data. The derive uses lightweight `unsynn` rather than `syn`, and the consumer crates build concurrently.
- **Better errors** and a **richer dynamic value**, as above.
- **Lossless flatten** by resolving against known shapes instead of buffering.

### `facet-args` — CLI from the same derive

```rust
#[derive(Facet)]
struct Args {
    #[facet(args::positional)] path: String,
    #[facet(args::named, args::short = 'v')] verbose: bool,
    #[facet(args::named, args::short = 'j')] concurrency: usize,
    #[facet(args::counted)] debug: u8,
}
let args: Args = facet_args::from_slice(&argv)?;
```

Its [documented limitations][args-docs] are informative because wired will meet the same ones: it parses **to a struct only** (no enums, hence no subcommands); values are always owned, never borrowed; fields lacking `positional`/`named` are silently ignored; and a `positional` `Vec` **greedily soaks up all positionals**, starving any positional declared after it. Behaviour is described as still in flux.

**D verdict — [(a)][tags]/[(b)][tags], and this is the survey's central strategic finding: D gets facet's benefits without facet's costs.** facet is reconstructing D's `__traits` in Rust at runtime, paying binary size and 3–6× throughput for it. In D, "shape as data" is what CTFE already gives you, and wired can consume it at **compile time** to emit specialized code. Concretely: keep "one UDA set, many consumers" as the architecture, and name the attributes so they read as _shape_ facts rather than _JSON_ facts; emit the opt-in `Shape` table for the runtime consumers; and learn from facet-args' two documented failures. The first — no subcommands, because it cannot parse into an enum — says design the enum mapping before anything else. The second — a greedy variadic positional starving later positionals — is not a bug wired needs to reproduce and then fix: **a variadic positional followed by another positional is detectable from the field list at compile time and should be a `static assert`.**

---

## Strengths

- **One annotation feeds every consumer,** removing the multi-derive, multi-vocabulary, no-cross-checking situation that serde's ecosystem settles into.
- **Attributes and doc comments are queryable,** which is the single capability serde structurally lacks.
- **Errors are good by default** — byte offsets, shape pointers, lazy formatting, did-you-mean suggestions — with no wrapper crate.
- **Compile-time and code-size scaling is flat in the number of types,** since the walker is compiled once; `unsynn` keeps derive cost low and consumer crates build in parallel.
- **Lossless flatten** resolved against known shapes rather than an untyped buffer.
- **A format-neutral dynamic value** with first-class bytes and datetimes.

## Weaknesses

- **Larger binaries** — 2.1 MB against serde's 884 KB on the introductory article's benchmark, roughly 2.4×.
- **3–6× slower JSON** than `serde_json`. The author calls both costs unoptimized rather than inherent, but the direction is structural: runtime data walking loses to monomorphized code on throughput.
- **Type-erased pointer access** means the safety argument lives in the framework rather than the type system.
- **Pre-1.0 and in flux,** with CLI/config work being re-homed into `figue` — an unstable target to build on today.
- **`facet-args` is materially incomplete:** no enums and therefore no subcommands, no borrowing, silently-ignored unannotated fields, and a greedy variadic-positional bug.
- **Ecosystem gravity is serde's,** so facet consumers largely re-implement integrations that already exist.

## Key design decisions and trade-offs

| Decision                                                 | Rationale                                                                               | Trade-off                                                                            |
| -------------------------------------------------------- | --------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| Emit a `Shape` constant instead of codec code            | One derive serves every consumer; the type becomes queryable                            | Consumers walk data at runtime — 3–6× slower JSON, 2.4× binary                       |
| Type-erased access via field byte `offset` plus a vtable | A single generic walker works for all types without monomorphization                    | Safety is enforced by the framework, not the compiler; `unsafe` internals            |
| Attributes as an open payload list, not a fixed grammar  | Consumer crates (`facet-args`, `facet-pretty`) add vocabulary without touching the core | No central cross-checking of attribute spellings; the core cannot validate them      |
| Doc comments preserved in `Field.doc`                    | Help text and generated documentation come from the source of truth                     | Enlarges the emitted constant, contributing to binary size                           |
| Flatten resolved against shapes ("possibility spaces")   | Lossless, and no untyped intermediate buffer                                            | Requires the full type graph in the artifact — the thing serde's macro cannot obtain |
| `unsynn` rather than `syn` for the derive                | Much cheaper derive compilation; consumer crates build concurrently                     | A less-standard macro parsing stack to maintain                                      |
| Consumers as independent crates                          | Pay only for what you use; integrations evolve separately                               | Capability is uneven — `facet-args` lags far behind `facet-json`                     |

---

## Sources

- [Introducing facet: reflection for Rust][article] — the introductory article, with the binary-size and throughput measurements
- [Why facet?][why] — facet's own framing of serde's reflection gap and the flatten approach
- [facet-rs/facet][repo] · [docs.rs/facet][docs] · [docs.rs/facet-args][args-docs]
- Related deep-dives: [serde][serde] · [argv codecs][argv] · [`sparkles:wired` baseline][baseline]
- Catalog: [index][index] · [concepts][concepts] · [comparison][comparison]

<!-- References -->

[repo]: https://github.com/facet-rs/facet
[docs]: https://docs.rs/facet/latest/facet/
[args-docs]: https://docs.rs/facet-args/latest/facet_args/
[why]: https://facet.rs/guide/why/
[article]: https://fasterthanli.me/articles/introducing-facet-reflection-for-rust
[schemars]: https://docs.rs/schemars/latest/schemars/
[eserde]: https://mainmatter.com/blog/2025/02/13/eserde/
[serde]: ./serde.md
[serde-structural]: ./serde.md#the-one-structural-difference-that-drives-everything
[serde-flatten]: ./serde.md#flatten-and-the-deny_unknown_fields-collision
[serde-validation]: ./serde.md#validation-and-the-cost-of-the-split
[argv]: ./argv-codecs.md
[index]: ./index.md
[concepts]: ./concepts.md
[tags]: ./concepts.md#d-feasibility-tags
[tiers]: ./concepts.md#the-three-tiers
[comparison]: ./comparison.md
[baseline]: ./wired-baseline.md
