# OCaml ppx & ATD

The closest ecosystem to D's position: OCaml has no runtime reflection, so serialization is done by **code generation from an annotated declaration** — either a `ppx` rewriter over the type definition itself, or ATD, an external schema language that generates types and codecs for seven target languages (one of which is already D).

| Field         | Value                                                                                                              |
| ------------- | ------------------------------------------------------------------------------------------------------------------ |
| Language      | OCaml (ATD targets: OCaml, Python, TypeScript, Java, Scala, C++, **D**)                                            |
| License       | MIT (`ppx_deriving_yojson`, `ppx_yojson_conv`, `ppx_deriving`) · BSD-3-Clause (`atd`, `atdd`)                      |
| Repository    | [ocaml-ppx/ppx_deriving_yojson][ppxdy] · [janestreet/ppx_yojson_conv][ppxjs] · [ahrefs/atd][atd-repo]              |
| Documentation | [atd.readthedocs.io][atd-docs] · [`atdd` on ocaml.org][atdd-pkg]                                                   |
| Category      | **Tier 1 — codegen-only**, with tier-3 add-ons bolted on (`repr`, `refl`, `typerep`); see [the three tiers][tiers] |
| Status        | Active; `atd` `4.2.0` at the time of writing, the D backend having landed in ATD 2.13.0                            |
| Artifact      | ppx: two generated functions, nothing reified. ATD: an external `.atd` file — the schema _is_ the source of truth  |

---

## Overview

### What it solves

OCaml's type declarations are erased; there is no `.tupleof`, no `__traits(allMembers)`, no runtime record layout to walk. Everything a serializer needs must therefore be recovered at the syntax level, by a preprocessor that sees the declaration's AST and emits functions beside it. That constraint produces a design that is startlingly close to what D would write with UDAs — and a set of ceilings that show exactly where the analogy stops.

ATD attacks the same problem from the opposite end: rather than annotate an OCaml type, write the schema first in a small ML-flavoured language and generate the types _and_ the codecs from it, in every language that has to speak the protocol.

### Design philosophy

`ppx_deriving_yojson` is the minimal statement of the attribute model — one declaration, two functions, asymmetric error types (encoding is total, decoding is not):

```ocaml
val ty_of_yojson : Yojson.Safe.t -> (ty, string) Result.result
val ty_to_yojson : ty -> Yojson.Safe.t

type geo = { lat : float [@key "Latitude"]; lon : float [@key "Longitude"] } [@@deriving yojson]
type units = Metric [@name "metric"] | Imperial [@name "imperial"] [@@deriving yojson]
type pagination = { pages : int; current : (int [@default 0]) } [@@deriving yojson]
```

ATD's philosophy is stated by its file layout: one `.atd` source generates a _types_ module that has no codec dependency, and separate codec modules per format.

```bash
atdgen -t example.atd   # example_t.ml  — types only, no format dependency
atdgen -j example.atd   # example_j.ml  — JSON
atdgen -b example.atd   # example_b.ml  — biniou (binary)
atdgen -v example.atd   # example_v.ml  — validators
```

**The `_t`/`_j` split is the idea to copy**: types must not depend on the codec. A library that exposes its data types can be consumed by callers that never link a serializer, and a second format is a second module rather than a second set of attributes on the same declaration.

---

## How it works

A `ppx_deriving` plugin is, precisely, **a function from type declarations to structure items** — the OCaml spelling of `__traits(allMembers)` plus `mixin`. The rewriter runs at the declaration site, reads the attributes attached to fields and constructors, and appends the generated functions to the same module.

ATD instead runs `atdgen` (or `atdd`, `atdpy`, `atdts`, …) as a build step over a `.atd` file. `atdcat` is the schema-level utility: it can check syntax, reformat, expand inherited definitions, and **export to JSON Schema** — which is the one place the ATD toolchain admits a reified artifact exists.

Here is the ATD source and the D that `atdd` generates from it, showing the field trichotomy landing in D exactly where a D programmer would put it by hand ([`everything.atd`][atd-input] → [`everything_atd.d`][atdd-out]):

```ocaml
type root = {
  id <json name="ID">: string;
  ~float_with_default <dlang default="0.1">: float;
  ?maybe: int option;
  ~extras: int list;
  ~answer <dlang default="42">: int;
}
```

```d
struct Root {
    string id;
    float float_with_default = 0.1;
    Nullable!int maybe;
    int[] extras = [];
    int answer = 42;
}
```

---

## Schema model & bidirectionality

**In the ppx lineage there is no schema.** The two generated functions are the entire artifact; nothing downstream can ask a question about the type. The only reification `ppx_deriving_yojson` offers is the `{ meta = true }` deriver option, which emits a module containing _just the JSON key names_ — a list of strings, not a structure.

Bidirectionality is by construction rather than by proof: the same attribute set drives both emitted functions, so they agree as long as the generator is correct. The per-field escape hatches break that guarantee, deliberately — see Transformations & validation below.

**In ATD the schema is the source of truth and lives outside the program.** That is the strongest form of the tier-1 bargain: because the `.atd` file is the artifact, it is diffable (`atddiff`), convertible (`atdcat -jsonschema <root type name>`, targeting draft-2020-12), and shareable across every ATD backend. Because it is a _file_ rather than a value, nothing in the running program can walk it; migration, diffing, and dynamic re-typing are all out of reach.

The gap was noticed inside OCaml, and the fix is additive rather than a redesign — three separate derivers that generate a **runtime representation value** and then rebuild everything else as ordinary functions over it:

- **`repr`** — `[@@deriving repr]` generates a value of type `ty Repr.t` from combinators (`record`/`field`/`sealr`, `variant`/`case1`/`sealv`, `mu` for recursion). One `Repr.t` then yields JSON encode/decode, a binary codec, `pp`, `compare`, `equal`, `size_of`, and random generation.
- **`refl`** — explicitly a _"one size fits all"_ deriving plugin.
- **`ppx_typerep_conv`** — Jane Street's `[@@deriving typerep]`, producing a `Typerep.t`.

`refl`'s README states the payoff better than anything else in the survey:

> _"instead of having to decide which derivers to use at the type declaration point, it is sufficient to derive only `refl`, and then this type can be used with all functions operating on such runtime representations, even functions that are defined after the type declaration."_

That the OCaml ecosystem grew a tier-3 layer _on top of_ a codegen layer is the important structural fact: the two designs compose rather than compete. [zio-schema][zio] says the same sentence from the other end, having started at tier 3.

**D verdict: [(b)][tags], and the ceiling is exactly the one to break.** D can occupy both positions at once — the ppx-style declaration ergonomics _and_ the `refl`-style reified artifact — because CTFE can build a `Schema` value from `__traits` introspection with no user-visible ceremony at all, not even a `[@@deriving]` marker. Forcing it into an `enum` makes it a compile-time constant, so zero-cost paths still specialize against it.

---

## Naming, optionality & defaults

**ATD's field trichotomy is the best single idea in this lineage.** Where most libraries have two cases, ATD has three, distinguished by a one-character sigil:

```ocaml
type profile = {
  id : string;                 (* required *)
  ?real_name : string option;  (* optional: absent -> None, program must branch *)
  ~about_me : string list;     (* defaulted: absent -> [], field is plain *)
}
```

The tutorial's phrasing is exact: _"`~x` means that field `x` supports a default value. Since we do not specify the default value ourselves, the built-in default is used, which is 0."_ ([atdgen tutorial][atd-tut]). The distinction that matters is not "has a default" but **what the consuming program sees**: `?field` yields an option the program is forced to handle; `~field` yields a _plain_ field filled from a default, so downstream code never branches. Conflating the two is how a codebase ends up threading `Option` through call sites that have no opinion about absence.

ATD also forces a conscious decision about `null`, and documents the default: _"Null JSON fields by default are treated as if the field was missing. They can be made meaningful with the `keep_nulls` flag."_ ([atdgen reference][atd-ref])

The ppx side covers naming and defaults but is thinner on omission. `ppx_deriving_yojson`'s vocabulary:

| Attribute               | Effect                                                               |
| ----------------------- | -------------------------------------------------------------------- |
| `[@key "Latitude"]`     | rename a record field on the wire                                    |
| `[@name "metric"]`      | rename a variant constructor on the wire                             |
| `[@default 0]`          | field may be absent; **omitted on output when equal to the default** |
| ``[@encoding `string]`` | encode `int64`/`nativeint` as a JSON string                          |
| `{ strict = false }`    | deriver option: ignore unknown keys (default is strict)              |

Two of these are worth taking verbatim. First, the default policy: _"Fields with default values are not required to be present in inputs and will not be emitted in outputs."_ ([README][ppxdy-readme]) — that is omit-on-write bound to the same annotation that supplies the default, rather than a second independent flag. Second, ``[@encoding `string]``: very large `int64` and `nativeint` values wrap when decoded by a runtime that represents all numbers as doubles (JavaScript, Lua), so the annotation switches them to a string encoding. **D has exactly the same `long`-in-JSON problem and should steal this one unchanged.**

`ppx_yojson_conv` (Jane Street) adds the omission vocabulary `ppx_deriving_yojson` lacks:

| Attribute                      | Effect                                     |
| ------------------------------ | ------------------------------------------ |
| `[@yojson.option]`             | optional field, omitted rather than `null` |
| `[@yojson_drop_default (=)]`   | omit when equal to the default             |
| `[@yojson_drop_if pred]`       | omit when a predicate holds                |
| `[@yojson.allow_extra_fields]` | ignore unknown keys                        |
| `[@yojson.opaque]`             | do not convert; emit `"<opaque>"`          |

Between the two libraries and ATD, the whole 3×2 matrix — {required, optional, defaulted} × {null-is-absent, null-is-a-value} — is covered, but by no single implementation. [autodocodec is the one library that enumerates all of it in one place][haskell].

**D verdict: [(a)][tags] throughout, with the trichotomy as a day-one design decision.** Every attribute above is a UDA read in CTFE. `?field` maps to `Nullable!T` and `~field` to a plain field with an initializer — which is precisely what `atdd` already emits — and `wired` should make that distinction _explicit_ rather than overloading `Nullable!T` to mean both. Getting this wrong is the one mistake in this area that cannot be fixed later without breaking every caller.

---

## Sum types & discrimination

`ppx_deriving_yojson` hardcodes a single, positional encoding: a variant becomes an array whose head is the constructor name.

```ocaml
[A; B 42; C (42, "foo")]   (* ⟶ *)   [["A"], ["B", 42], ["C", 42, "foo"]]
X { v = 0 }                (* ⟶ *)   ["X", {"v": 0}]
```

Regular and polymorphic variants encode identically, and the implicit tuple in a polymorphic variant is flattened. There is no discriminator-field mode, no untagged mode, and no per-type choice — the strategy is a property of the _generator_, not of the declaration.

ATD is more flexible in one direction and equally rigid in the other. Its native encoding is the same tagged-array shape, but two annotations widen it:

- `<json open_enum>` — _"Where an enum (finite set of strings) is expected, this flag allows unexpected strings to be kept under a catch-all constructor rather than producing an error."_ ([atdgen reference][atd-ref]) So `` `Chinese `` round-trips as itself and an unrecognised `"French"` lands in `Other "French"` rather than aborting the decode. This is the one place in the whole ppx/ATD lineage where unmodelled data survives a round trip.
- **Adapters** (below) cover internally-tagged and adjacently-tagged shapes without teaching the generator about either.

**D verdict: [(b)][tags], and the tagging strategy must be a policy UDA rather than a hardcoded scheme.** The generated tag switch over a `SumType` is mechanical; what this lineage gets wrong is baking one wire shape into the generator, so a legacy internally-tagged payload has to be routed through an adapter that the type system cannot check. `open_enum` is worth adopting directly — [(a)][tags], a catch-all case carrying the unrecognised string — and it composes with the `@extra`-field approach to unknown _record_ keys discussed under [zio-schema][zio].

---

## Transformations & validation

### Per-field escape hatches, and a defect worth not repeating

`ppx_deriving_yojson` lets a field override the generated conversion:

```ocaml
type page = { number : int [@to_yojson fun i -> `Int (i + 1)]
                           [@of_yojson fun j -> Ok (to_int j - 1)]
            } [@@deriving yojson]
```

**`[@to_yojson]` and `[@of_yojson]` are two separate attributes, and nothing enforces that they are inverses.** A field can be given a forward conversion and no backward one, or a pair that quietly disagrees; the compiler is content either way, and the failure surfaces as data corruption on the next round trip. A D design should do better: **one UDA naming a type that carries both directions, with a `static assert` on the pair** — the same shape as tomland's `BiMap` or circe's `iemap`, but checked at compile time rather than trusted (see [invertible syntax][invertible]).

### JSON adapters — the sharpest idea in ATD, and the one to adopt

An adapter is a **pre/post pass on the JSON itself**, declared on a type and supplied as a module with two functions:

```ocaml
sig
  (** Convert from original json to ATD-compatible json *)
  val normalize : Yojson.Safe.t -> Yojson.Safe.t

  (** Convert from ATD-compatible json to original json *)
  val restore : Yojson.Safe.t -> Yojson.Safe.t
end
```

attached as `<json adapter.ocaml="Atdgen_runtime.Json_adapter.Type_field">`, with a ready-made `normalize_type_field "type"` / `restore_type_field "type"` pair for the common internally-tagged case.

This is **bidirectionality at the value level, bolted onto a codegen design** — and it is exactly the right escape hatch. Internally-tagged, adjacently-tagged, and arbitrary legacy encodings become expressible without the generator learning about any of them, and the pairing of `normalize`/`restore` in one module signature makes the inverse relationship at least _stated_, which the `[@to_yojson]`/`[@of_yojson]` split does not.

### Validation

ATD has a dedicated validator backend (`atdgen -v`) that generates checking functions from `<ocaml valid="...">` annotations, kept separate from both the types module and the codec modules. Nothing in the ppx lineage has an equivalent; validation there is the caller's problem.

### Schema evolution: a linter, not an algebra

ATD's guidance turns on polarity, and its own how-to states the rule better than a paraphrase can:

> _"you'll find that the logic for product types (records/objects) is the inverse of sum types (e.g. enums). For example, a server upgrade resulting in a response object with a new field will not break older clients. However, a server response that contains an enum cannot add a new case without breaking older clients."_ ([How to change a JSON interface safely?][atd-upgrade])

The compressed form: **products are safe to extend, sums are safe to shrink.** `atddiff` mechanises the check — it takes two revisions of a `.atd` file, knows the language, and reports only meaningful differences:

```text
$ atddiff example_old.atd example_new.atd
Backward incompatibility:
File "example_new.atd", line 2, characters 2-12
Required field 'id' is new.
The following types are affected:
  response
```

with `--backward` / `--forward` to select a direction, `--types foo,bar` to scope it, `--output-format json` for machine consumption, and a `git difftool -x atddiff example.atd` invocation for reviewing a change in place. The suggested fix in the example above is to make the field `?id : string option` — i.e. the trichotomy doing evolution work.

> [!IMPORTANT]
> **`atddiff` detects; it does not transform.** ATD will tell you a change is unsafe and will not migrate v1 data into v2 — and no ppx does either. Measured against [zio-schema's `Migration` algebra][zio], this entire lineage is strictly weaker on evolution.

**D verdict: [(a)][tags] for the adapter pair, [(b)][tags] for an `atddiff` equivalent, [(c)][tags] for the algebra it lacks.** The `normalize`/`restore` pair is a UDA naming a type with two `static` functions — cheap, and it keeps legacy wire shapes out of the generator entirely. The compatibility linter is the high-value, low-cost half of evolution: emit a schema digest per type in CTFE, snapshot it as a golden file using the repo's existing `SPARKLES_UPDATE_GOLDENS` machinery, and diff it in CI. Do that before contemplating a migration algebra.

---

## Errors & context

This dimension is genuinely thin across the whole lineage, and the thinness is a finding rather than an omission in this write-up.

`ppx_deriving_yojson` decodes into `(ty, string) Result.result` — **fail-fast, one error, a bare string**. There is no accumulation, no structured path, and no partial value; `{ exn = true }` merely adds a variant that raises `Failure err` instead of returning `Error err`. Encoding has no error type at all, on the assumption that every OCaml value of the type is representable. ATD's generated readers raise on malformed input, with `atdd`'s D output funnelling everything through a single `AtdException` carrying a formatted message.

What the generated string _does_ contain is a manually assembled path fragment, which is the same trap circe and aeson fall into: a path attached by hand is a path eventually forgotten. Compare [unjson's accumulating errors with a usable partial value][invertible], which is the best-in-class shape.

**D verdict: [(a)][tags] to [(b)][tags], and an easy win.** Both hazards dissolve in a generated design: every field's branch always runs, so accumulation costs nothing structural, and the field path is a compile-time string constant the walker emits unconditionally. Accumulate into a `SmallBuffer!(Anchored, N)` rather than a monadic transformer, and the partial value comes free because the decoder is writing into a `T` that already holds its initializers.

---

## Metadata, derivations & extensibility

### Attributes are untyped, and the namespacing rule proves it

`ppx_deriving` has to legislate attribute lookup because attributes are just names in a shared syntactic space. From its README:

> _"In case of a plugin named `eq` and attributes named `compare` and `skip`, the plugin must recognize all of `compare`, `skip`, `eq.compare`, `eq.skip`, `deriving.eq.compare` and `deriving.eq.skip` annotations. However, if it detects that at least one namespaced … attribute is present, it must not look at any attributes located within a different namespace."_ ([ppx_deriving README][ppxd-readme])

**D's UDAs are typed values, so this entire ambiguity class vanishes for free.** `@wireName("x")` is a symbol resolved by the ordinary module system; two libraries cannot collide on a name they did not import.

### `ppx_import` exists only because of a limitation D does not have

A ppx deriver runs **at the declaration site**, which means you cannot derive for a type you do not own. `ppx_import` is the workaround: it pulls a type declaration back out of a compiled `.cmi` interface so a deriver can be applied to it locally. The cost is visible in its own documentation — it needs compiled interfaces, it must run _before_ any deriving plugin (hence Dune's `staged_pps`), and object-oriented features are simply not implemented.

In D, `__traits(allMembers, T)` works on **any type, from any module, at any point in the program**. `wired` can therefore serialize third-party and Phobos types without cooperation from their authors — and, because it can, it _should_ support **external side-table annotations**: a registration elsewhere in the program (`@serializable!(Foo, [...])`) that supplies the metadata the type's own author never wrote. That capability has no ppx analogue at all.

### One schema, many languages — including D already

ATD's feature-support matrix enumerates eight backends across seven languages: `atdml` and `atdgen` (OCaml), `atdpy` (Python), `atdts` (TypeScript), `atdj` (Java), `atds` (Scala), `atdcpp` (C++), and **`atdd` (D)**. The D output is worth reading directly, because it is the field-tested answer to "what does generated D serialization look like":

```d
struct Shape{ SumType!(Circle, Square, Point) _data; alias _data this;
@safe this(T)(T init) {_data = init;} @safe this(Shape init) {_data = init._data;}}

@trusted Shape fromJson(T : Shape)(JSONValue x) { /* … */ }
@trusted JSONValue toJson(T : Shape)(T x) {
    return x.match!(
    (Circle v) => v.toJson!(Circle),
    (Square v) => v.toJson!(Square),
    (Point v) => v.toJson!(Point)
    );
}
```

Two takeaways. `SumType` plus `alias this` is the encoding for variants that already survives contact with a real generator. And the blanket `@trusted` on every codec function is a **smell `wired` should beat outright** — see the [`sparkles:wired` baseline][baseline] for where the repository stands today. A generated codec should be `@safe` by construction; if it is not, the generator is doing something the type system could have checked.

**D verdict: [(a)][tags] for the annotation vocabulary, [(b)][tags] for the reified layer that makes it pay.** The whole ppx attribute vocabulary is directly expressible as UDAs, and the fact that `ppx_sexp_conv` is the identical shape for S-expressions is evidence the pattern is **format-parametric** — which argues for keeping `wired`'s UDA vocabulary format-neutral and its backends pluggable, exactly as ATD's `_t`/`_j` split does at the module level.

---

## Strengths

- **The attribute vocabulary is directly portable to UDAs** — `[@key]`, `[@name]`, `[@default]`, and the omission attributes map one-for-one, with no translation loss.
- **ATD's `?`/`~` trichotomy** distinguishes optional-as-`Option` from defaulted-as-plain in two characters, and gets the distinction right where most libraries collapse it.
- ``[@encoding `string]`` names and solves the 64-bit-integer-in-JSON problem at the field level.
- **The `_t`/`_j` module split** keeps types free of any codec dependency, so a second format is a second module.
- **JSON adapters (`normalize`/`restore`)** are a clean value-level escape hatch for legacy wire shapes that never contaminates the generator.
- **`atddiff` is a real compatibility linter** with backward/forward direction selection and a `git difftool` workflow.
- **One schema, seven target languages** — and the D backend already exists and works.
- **`repr`/`refl`/`typerep` show codegen and reification compose**, rather than being alternatives.

## Weaknesses

- **No schema in the ppx lineage.** `{ meta = true }` emits a list of key names; that is the entire reification story.
- **No migration story anywhere.** `[@default]` and `?field` are the whole of versioning; `atddiff` detects but never transforms.
- **No unknown-field round-trip.** `strict = false` _ignores_ unknown keys and drops them on re-encode; `[@yojson.allow_extra_fields]` "silently ignores"; ATD drops too, with `<json open_enum>` the single exception, and it covers enum cases only.
- **`[@to_yojson]`/`[@of_yojson]` are two unrelated attributes** — nothing enforces they are inverses.
- **Attributes are untyped and namespace-ambiguous**, requiring the six-spelling recognition rule, and **derivers cannot touch types they do not own**, forcing `ppx_import` with its staged-preprocessing and `.cmi` requirements.
- **Variant encoding is hardcoded by the generator**, so anything else needs an adapter the type system cannot check.
- **Errors are fail-fast bare strings** with hand-assembled paths and no accumulation.
- **ATD costs an external file and a separate toolchain** — a build-step dependency and a second language to learn.

## Key design decisions and trade-offs

| Decision                                                       | Rationale                                                                       | Trade-off                                                                                  |
| -------------------------------------------------------------- | ------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| Generate two functions, reify nothing                          | Minimal machinery; the generated code is as fast as hand-written                | No schema emission, no diffing, no migration; every capability costs a new deriver         |
| Attributes carried on the declaration itself                   | Metadata sits where the programmer already looks                                | Untyped and unnamespaced; a six-spelling lookup rule to avoid cross-plugin interference    |
| `[@to_yojson]` / `[@of_yojson]` as independent attributes      | Each direction can be overridden alone                                          | Nothing checks the pair is an inverse; silent round-trip corruption                        |
| Derive at the declaration site                                 | The rewriter needs the declaration's AST, which exists only there               | Cannot derive for foreign types; `ppx_import` and staged preprocessing exist to patch this |
| ATD: schema as an external file, not an annotated type         | One source of truth across seven languages; diffable and JSON-Schema-exportable | A separate language and build step; nothing in the running program can walk it             |
| ATD: `?field` vs `~field` as distinct sigils                   | Separates "the program must handle absence" from "absence has an answer"        | A second concept to teach, and the `~z : int option` mis-spelling is an easy trap          |
| ATD: JSON adapters as a `normalize`/`restore` module           | Legacy and tag-shaped encodings expressible without touching the generator      | Adapters are unchecked OCaml code operating on untyped JSON — the generator's blind spot   |
| ATD: nulls treated as absent unless `<json keep_nulls>`        | Matches the common case where `null` and missing mean the same thing            | Silently loses an explicit `null` where a protocol distinguishes the two                   |
| `atddiff` as a linter rather than a migration engine           | Catches the 90% case (compatibility) for a fraction of an algebra's cost        | Cannot move data across versions; every real migration stays hand-written                  |
| `repr`/`refl`/`typerep` add reification on top, not underneath | Existing derivers keep working; reification is opt-in per type                  | Two parallel ecosystems; a type must opt into the reified world to benefit from it         |

---

## Sources

- [ocaml-ppx/ppx_deriving_yojson — repository][ppxdy] · [README — attribute vocabulary, strict mode, defaults][ppxdy-readme]
- [janestreet/ppx_yojson_conv — repository][ppxjs] · [README — omission attributes][ppxjs-readme]
- [ocaml-ppx/ppx_deriving — README, the plugin contract and attribute namespacing rule][ppxd-readme]
- [ocaml-ppx/ppx_import — README, the foreign-type limitation and `staged_pps`][ppxi-readme]
- [ahrefs/atd — repository][atd-repo] · [documentation][atd-docs] · [the language reference (`?`/`~`, annotations)][atd-lang]
- [`atdgen` reference — `keep_nulls`, `open_enum`, JSON adapters][atd-ref] · [`atdgen` tutorial — optional fields and default values][atd-tut]
- [ATD — How to change a JSON interface safely? (`atddiff`, product/sum polarity)][atd-upgrade]
- [`atdd` — the D backend, on ocaml.org][atdd-pkg] · [`atdd` documentation][atdd-docs] · [ATD feature-support matrix — the eight backends][atd-matrix]
- [`atdd/test/atd-input/everything.atd` — the input fixture][atd-input] → [`atdd/test/dlang-expected/everything_atd.d` — the generated D][atdd-out]
- [`repr` — `[@@deriving repr]` documentation][repr] · [thierry-martinez/refl — the "one size fits all" argument][refl] · [janestreet/ppx_typerep_conv][typerep]
- Related in this catalog: [concepts][tiers] · [comparison][comparison] · [`sparkles:wired` baseline][baseline] · [zio-schema][zio] · [Effect Schema][effect] · [Rust serde][serde] · [facet][facet] · [Pydantic][pydantic] · [msgspec & cattrs][msgspec] · [circe & aeson][circe] · [Haskell codec libraries][haskell] · [invertible syntax][invertible] · [argv codecs][argv]

<!-- References -->

[ppxdy]: https://github.com/ocaml-ppx/ppx_deriving_yojson
[ppxdy-readme]: https://github.com/ocaml-ppx/ppx_deriving_yojson/blob/1a4b06d2045ed91f30d72cdd8cce7d002c3c2503/README.md
[ppxjs]: https://github.com/janestreet/ppx_yojson_conv
[ppxjs-readme]: https://github.com/janestreet/ppx_yojson_conv/blob/eb5a681411da60c1912be7adf1c8bb0e1b8dea2c/README.org
[ppxd-readme]: https://github.com/ocaml-ppx/ppx_deriving/blob/39303d86dcf5150b692599b88d774345d124d225/README.md
[ppxi-readme]: https://github.com/ocaml-ppx/ppx_import/blob/e7ff3012b87dc16be1b058b0f480f944c8d1a165/README.md
[atd-repo]: https://github.com/ahrefs/atd
[atd-docs]: https://atd.readthedocs.io/en/latest/
[atd-lang]: https://atd.readthedocs.io/en/latest/atd-language.html
[atd-ref]: https://atd.readthedocs.io/en/latest/atdgen-reference.html
[atd-tut]: https://atd.readthedocs.io/en/latest/atdgen-tutorial.html
[atd-upgrade]: https://atd.readthedocs.io/en/latest/atd-howto-protocol-upgrades.html
[atdd-pkg]: https://ocaml.org/p/atdd/latest
[atdd-docs]: https://atd.readthedocs.io/en/latest/atdd.html
[atd-matrix]: https://github.com/ahrefs/atd/blob/c714a585771bfe7a6eb414a3ebefed30e0611c66/doc/support-matrix.rst
[atd-input]: https://github.com/ahrefs/atd/blob/c714a585771bfe7a6eb414a3ebefed30e0611c66/atdd/test/atd-input/everything.atd
[atdd-out]: https://github.com/ahrefs/atd/blob/c714a585771bfe7a6eb414a3ebefed30e0611c66/atdd/test/dlang-expected/everything_atd.d
[repr]: https://ocaml.org/p/repr/latest/doc/README_PPX.html
[refl]: https://github.com/thierry-martinez/refl/blob/e79345b0d315757d203386da590ec92b0911ee1b/README.md
[typerep]: https://github.com/janestreet/ppx_typerep_conv
[tags]: ./concepts.md#d-feasibility-tags
[tiers]: ./concepts.md#the-three-tiers
[comparison]: ./comparison.md
[baseline]: ./wired-baseline.md
[zio]: ./zio-schema.md
[effect]: ./effect-schema.md
[serde]: ./serde.md
[facet]: ./facet.md
[pydantic]: ./pydantic.md
[msgspec]: ./msgspec-cattrs.md
[circe]: ./circe-aeson.md
[haskell]: ./haskell-codecs.md
[invertible]: ./invertible-syntax.md
[argv]: ./argv-codecs.md
