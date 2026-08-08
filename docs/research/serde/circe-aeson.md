# circe & aeson — derivation-only codecs and their ceiling

The two most-deployed JSON libraries in Scala and Haskell, and the clearest statement of what **tier 1** can and cannot do: one declaration, two generated functions, no artifact in between — so no schema, no migrations, no diffing, and an encoder and decoder that are free to drift apart.

| Field         | Value                                                                                                                        |
| ------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| Language      | `circe` — Scala 2.13/3 · `aeson` — Haskell (GHC 9.x)                                                                         |
| License       | `circe` Apache-2.0 · `aeson` BSD-3-Clause                                                                                    |
| Repository    | [circe/circe][circe-repo] · [circe/circe-generic-extras][extras-repo] · [haskell/aeson][aeson-repo]                          |
| Documentation | [circe.github.io][circe-docs] · [`Data.Aeson`][aeson-docs] · [`Data.Aeson.Types`][aeson-types] · [`Data.Aeson.TH`][aeson-th] |
| Category      | **Tier 1 — codegen-only** (see [the three tiers][tiers])                                                                     |
| Status        | `circe` 0.14.x, the Scala default · `aeson-2.3.1.0`, the Haskell default; both mature and heavily depended upon              |

> [!NOTE]
> These two libraries are surveyed as the **baseline to beat**, not as designs to copy. Where they get something right (`circe-generic-extras`' two-level annotation split, `aeson`'s enumeration of sum encodings) it is called out explicitly; where the shape is a trap (`aeson`'s closed `Options` record) that is called out too. The tier-2 response is [`./haskell-codecs.md`][haskell]; the tier-3 response is [`./zio-schema.md`][zio-schema].

---

## Overview

### What it solves

Both libraries answer one question extremely well: **given an ordinary data type, produce JSON in and out with no ceremony.** `circe` does it with an implicit `Codec[A]`, `aeson` with a `ToJSON`/`FromJSON` instance pair, and in both ecosystems the derived form is a one-liner that covers the overwhelming majority of real use.

They differ in how much control they hand back. `circe` (through `circe-generic-extras`) has a per-field annotation and a per-type configuration; `aeson` has a single global `Options` record and nothing per-field at all. Both are otherwise the same architecture: derivation compiles the structure of the type into a pair of closures, and after that the structure is gone.

### Design philosophy

`circe` is a Cats-idiomatic library: `Decoder` is a `MonadError` and a `SemigroupK`, `Encoder` is a `Contravariant`, and the derivation is implicit-driven. `aeson` is a performance-first library with a deliberately closed configuration surface: one `Options` value drives Template Haskell and `Generic` derivation alike, and per-type escape hatches mean writing the instance by hand.

Both are candid in their own documentation about the consequences. On `aeson`'s default sum encoding, the Haddock for `TaggedObject` warns:

> _"make sure that your record doesn't have a field with the same label as the `tagFieldName`. Otherwise the tag gets overwritten."_

and on the untagged form:

> _"JSON encodings have to be disjoint for decoding to work properly"_ … _"only the last error is kept when decoding."_

Those two sentences are the tier's position in miniature: the hazards are real, they are known, and the only available remedy is prose in the documentation — because there is no artifact left to check them against.

---

## How it works

### `circe`: two type classes, one bundle

```scala
trait Encoder[A] { def apply(a: A): Json
                   def contramap[B](f: B => A): Encoder[B] }

trait Decoder[A] { def apply(c: HCursor): Either[DecodingFailure, A]
                   def decodeAccumulating(c: HCursor): ValidatedNel[DecodingFailure, A]
                   def map[B](f: A => B): Decoder[B]
                   def flatMap[B](f: A => Decoder[B]): Decoder[B]
                   def emap[B](f: A => Either[String, B]): Decoder[B] }

trait Codec[A] extends Decoder[A] with Encoder[A] {
  def iemap[B](f: A => Either[String, B])(g: B => A): Codec[B]
}
```

Derivation comes in three flavours: `semiauto` (`deriveCodec[Foo]` bound to a named `val`, one derivation per type), `auto` (an implicit `def` re-derived at every call site), and the explicit `forProductN` family. `circe-generic-extras` adds the annotation layer.

### `aeson`: one `Options` record, three derivation tiers

```haskell
data Options = Options
  { fieldLabelModifier     :: String -> String   -- id
  , constructorTagModifier :: String -> String   -- id
  , allNullaryToStringTag  :: Bool               -- True
  , omitNothingFields      :: Bool               -- False
  , allowOmittedFields     :: Bool               -- True
  , sumEncoding            :: SumEncoding        -- defaultTaggedObject
  , unwrapUnaryRecords     :: Bool               -- False
  , tagSingleConstructors  :: Bool               -- False
  , rejectUnknownFields    :: Bool               -- False
  }

$(deriveJSON defaultOptions{fieldLabelModifier = drop 4} ''D)   -- Template Haskell
mkToJSON, mkParseJSON :: Options -> Name -> Q Exp               -- generate the body only
```

Nine knobs, applied uniformly to the whole type. Everything a program wants to say about serialization must be expressible as one of those nine, or the type drops out of derivation entirely.

---

## Schema model & bidirectionality

**There is no schema.** `Encoder[A]` is an opaque `A => Json`; `ToJSON a` is an opaque method. After derivation, the structure of `A` has been compiled into closures and is unrecoverable.

The bidirectionality story is worse than merely absent — it is **provably impossible to unify** in this design. `circe`'s variance makes the theorem visible:

- `Decoder[A] ≈ Json => A` is covariant in `A`, so `map` and `flatMap` exist. Reading a discriminator and _then_ choosing a sub-decoder is a legitimate monadic operation.
- `Encoder[A] ≈ A => Json` is contravariant in `A`, so there is nothing to `flatMap` over. It gets `contramap` and stops there.

This is precisely the result [Rendel & Ostermann prove][invertible]: a bidirectional codec cannot be a `Monad`, because the continuation `a -> m b` of a bind is an opaque, uninvertible function. Scala's type system surfaces it as a variance mismatch; Haskell's as a missing class instance. **Two languages, one theorem.**

`Codec[A] extends Decoder[A] with Encoder[A]` bundles the pair without unifying it: `Codec.from(d, e)` accepts any unrelated decoder and encoder, and nothing anywhere checks that `decode ∘ encode = id`. The one place `circe` gets closer is `iemap[B](f: A => Either[String, B])(g: B => A)` — fallible forward, total backward, which is a **partial isomorphism** rediscovered under a third name (`tomland` calls it [`BiMap`][haskell], Rendel calls it `Iso`).

`aeson`'s `Value` is the parallel gap on the Haskell side, and it is worth being precise about what kind of gap:

```haskell
data Value = Object Object | Array Array | String Text
           | Number Scientific | Bool Bool | Null
```

**`Value` is a DOM, not a schema.** It describes a _document_; it says nothing about the type `A`, cannot enumerate `A`'s fields, and cannot serve a format whose shape is not JSON's (protobuf field numbers, Avro schemas). Its cost is visible in `aeson`'s own API surface: `toJSON` and `toEncoding` both exist _because_ materializing a `Value` only to serialize it is wasteful — two methods, per type, that can disagree with each other.

What the missing schema forecloses, concretely:

1. **No JSON Schema, OpenAPI, or documentation output.** The Scala ecosystem's answer is `tapir`'s `Schema[A]`, derived **separately** from the codec — two derivations over the same type that can silently drift apart. That drift is exactly what [`autodocodec` was built to eliminate][haskell].
2. **No field enumeration without running the codec** — and running it requires an inhabitant of `A`, and even then cannot reveal absent optional fields or untaken sum branches.
3. **No migrations.** Every schema change is a hand edit in at least two places.
4. **No structural diff or patch.** `Json`-level diffing exists; the types are gone by then.
5. **No format-neutral reuse.** `Encoder[A]` is hardwired to `Json`; protobuf or Avro require a parallel class hierarchy and a re-derivation per format.
6. **No generators, optics, ordering, or defaults** from the same declaration.

**D verdict: [(b)][tags] to build the schema, and this is the argument for building it at all.** A `SchemaNode[]` arena produced in CTFE from `__traits(getAttributes)` and `.tupleof` is mechanical work with no research risk, and it is what separates a D `wired` from a faster `circe`. The variance problem that forces two declarations does not arise: D's reflection supplies both directions from one field walk, so there is no `Encoder`/`Decoder` split to reconcile and no `Codec.from` accepting a mismatched pair. Keep the DOM and the schema as **distinct concepts** — a compile-time `Schema` per type, a runtime `DynValue` per document — rather than letting one `Value` type invite the conflation.

---

## Naming, optionality & defaults

**`circe-generic-extras` gets the shape right.** It splits metadata across two levels:

```scala
final case class JsonKey(value: String) extends StaticAnnotation      // per field

final case class Configuration(                                        // per type
  transformMemberNames: String => String,
  transformConstructorNames: String => String,
  useDefaults: Boolean,
  discriminator: Option[String],
  strictDecoding: Boolean = false)
// .withSnakeCaseMemberNames / .withKebabCaseMemberNames / .withDefaults
// .withDiscriminator(d) / .withStrictDecoding
```

`@JsonKey` names one field; `Configuration` sets the type-wide policy that individual fields deviate from. That is exactly the shape a UDA design wants, and it is the one thing in this page worth copying wholesale.

**`aeson` gets it wrong in an instructive way.** `Options` has **no per-field control at all**. Renaming a single field means either writing a `fieldLabelModifier` lambda that string-matches on the one name (fragile, and an opaque `String -> String` the library can neither inspect nor invert) or abandoning derivation for the entire type. There is no per-field default, no per-field documentation, and no per-field format.

> [!WARNING]
> `fieldLabelModifier` being an opaque runtime closure has a second consequence that is easy to miss: **`aeson` cannot report a type's wire names.** It can only apply the function to a name it already has. Any tooling that wants the wire vocabulary — a schema emitter, a migration linter, a completion source — is locked out by the choice of representation.

The supplied name transformer is `camelTo2 '_'` (`camelTo2 '_' "CamelAPICase" == "camel_api_case"`; the older `camelTo` got acronyms wrong and was superseded rather than fixed — a rename policy, once shipped, is a wire contract).

Optionality is thinner than the [3×2 matrix `autodocodec` enumerates][haskell]:

| Knob                  | Effect                                                                  |
| --------------------- | ----------------------------------------------------------------------- |
| `omitNothingFields`   | Encoding only — omit `Nothing` rather than writing `null`               |
| `allowOmittedFields`  | Decoding only — whether an absent key may be filled from `omittedField` |
| `rejectUnknownFields` | Reject rather than silently drop keys the type does not declare         |

`aeson-2.2` generalized `omitNothingFields` beyond `Maybe` via an `omitField` class method, which makes omission a per-**type** decision — an improvement, and still not per-field. `circe`'s `useDefaults` covers the defaulted case by reading Scala's default arguments, which requires a macro.

**D verdict: [(a)][tags] for both levels of the annotation split, and defaults are _easier_ than in either language.** Per-field UDAs with a struct-level `@jsonOptions` default is strictly more expressive than `aeson`'s nine global knobs at the same syntactic cost, and it is `circe-generic-extras`' two-level design with a typed annotation channel instead of `StaticAnnotation`. `useDefaults` needs no macro at all: a struct field initializer is readable as `T.init.field`. And a D UDA holding a `string function(string) pure` renaming policy is **CTFE-evaluated**, so wire names are compile-time constants — enumerable, table-invertible, and embeddable in a generated schema, which is exactly what `fieldLabelModifier` forecloses ([(b)][tags] for the emitted table, same syntax).

---

## Sum types & discrimination

`aeson` is the best enumeration of the design space in the survey, so it is worth reproducing concretely. For

```haskell
data D = Nullary | Unary Int | Product String Char Int
       | Record { testOne :: Double, testTwo :: Bool }
```

| Encoding                                    | `Nullary`           | `Unary 1`                      | `Product "a" 'b' 3`                        | `Record 1.0 True`                               |
| ------------------------------------------- | ------------------- | ------------------------------ | ------------------------------------------ | ----------------------------------------------- |
| `TaggedObject "tag" "contents"` _(default)_ | `{"tag":"Nullary"}` | `{"tag":"Unary","contents":1}` | `{"tag":"Product","contents":["a","b",3]}` | `{"tag":"Record","testOne":1.0,"testTwo":true}` |
| `ObjectWithSingleField`                     | `{"Nullary":[]}`    | `{"Unary":1}`                  | `{"Product":["a","b",3]}`                  | `{"Record":{"testOne":1.0,"testTwo":true}}`     |
| `TwoElemArray`                              | `["Nullary",[]]`    | `["Unary",1]`                  | `["Product",["a","b",3]]`                  | `["Record",{"testOne":1.0,"testTwo":true}]`     |
| `UntaggedValue`                             | `"Nullary"`         | `1`                            | `["a","b",3]`                              | `{"testOne":1.0,"testTwo":true}`                |

Two behaviours in that table bite in production:

- **`TaggedObject` has two structurally different layouts under one name.** It _unpacks_ a record constructor's fields into the tag object, but _wraps_ non-record contents under `contentsFieldName`. Whether your wire format nests depends on whether the constructor happens to be a record — and the tag key then shares a namespace with the record's own fields, which is the collision the Haddock warns about. `circe`'s `withDiscriminator("type")` produces the same flat `{"i": 1000, "type": "Foo"}` shape with the same documented hazard.
- **`UntaggedValue` decodes by trying constructors in declaration order, first success wins.** Disjointness is the author's unchecked responsibility, nullary-versus-string is ambiguous by construction, and _"only the last error is kept when decoding"_ — so a mis-shaped document reports whichever branch happened to be tried last rather than the one it was closest to matching.

`circe`'s default (without a discriminator) is the wrapper-object form `{"Foo": {"i": 100}}`, equivalent to `ObjectWithSingleField`.

**D verdict: [(a)][tags] for selection, [(b)][tags] for untagged machinery — plus a fifth variant D should add.** `@sumEncoding(TaggedObject("kind", "value"))` is a plain UDA. `UntaggedValue`'s ordered trial decoding needs a rewindable reader and `static foreach` backtracking, which is real but bounded work. The addition worth making is **internally-tagged with a compile-time disjointness proof**: compare the branches' key-sets in CTFE and `static assert` when two are ambiguous. `aeson` can only warn in prose and [`autodocodec` can only ask the author to declare it][haskell]; a CTFE walk can decide it.

---

## Transformations & validation

The transformation vocabulary is thin on both sides, and the thinness is the finding.

`circe` offers `Decoder.map`, `Decoder.emap` (fallible, `A => Either[String, B]`), `Decoder.flatMap`, `Encoder.contramap`, and `Codec.iemap` (the paired form). `aeson` offers whatever you write inside a hand-written `parseJSON`, using `Parser`'s `MonadFail`.

Neither has a **validation vocabulary at all**. There is no bounds constructor, no `@validate` annotation, nothing that a schema emitter could render as `minLength` or `maximum` — because there is no emitter and no node to hang it on. Compare [`autodocodec`, where `StringBounds` and `Bounds Integer` are fields of the primitive constructors][haskell] and therefore appear in the JSON Schema automatically. In `circe` and `aeson`, validation is `emap`/`fail` inside the decoding function: it runs, it produces an error, and it is invisible to everything else.

`flatMap` is worth one more note, because it is where the two design faults meet. It is genuinely useful — read a discriminator, then choose a branch decoder — and it is the exact operation that breaks accumulation (next section) and that [makes a codec impossible to invert][invertible]. Tier 1 can afford it precisely because it never intended to be bidirectional or inspectable.

**D verdict: [(a)][tags] for the transformations, [(b)][tags] for making validation visible.** `emap`/`iemap` map onto `Expected!(T, E)` conversions attached to a field. The improvement over both libraries is not the transformation itself but its _visibility_: a `@validate` UDA read by the same CTFE walk that emits the schema means the constraint is enforced at decode time **and** rendered into the emitted schema from one declaration — the non-drift property tier 1 structurally cannot have.

---

## Errors & context

`circe` has two modes and one trap.

```scala
sealed abstract class DecodingFailure(val reason: Reason) extends Error {
  def history: List[CursorOp]
  def pathToRootString: Option[String]      // ".foo.bar[3]"
}
```

Fail-fast `decode` returns `Either` and short-circuits through the `Monad`; `decodeAccumulating` returns a `ValidatedNel` and collects every independent failure through the `Applicative`.

> [!WARNING]
> **Any `flatMap` in a decoder destroys accumulation downstream** — `Validated` has no `Monad`, so a monadic step collapses back to first-failure. This is not theoretical: `circe` issues [#837][circe-837] and [#2062][circe-2062] are ADT decoders discarding errors for exactly this reason. Accumulation in `circe` is therefore **conventional, not compositional** — it holds only as long as every decoder in the chain avoids one specific combinator.

The path story is also weaker than it looks: `history` is a **reconstructed cursor log**, not a schema path, which is why `circe` messages historically read `DownField(bar),DownField(foo)` rather than `.foo.bar`. `pathToRootString` renders it after the fact.

`aeson` is strictly weaker still: **fail-fast only, with no accumulating mode at all.** Paths are attached _manually_:

```haskell
(<?>) :: Parser a -> JSONPathElement -> Parser a
```

The `.:` combinator inserts one for you; a hand-written parser that forgets `(<?>)` produces a pathless error, and nothing warns about it.

**D verdict: [(b)][tags], and D can beat both libraries on both axes.** The error path should be the **schema path** — known at compile time, sliceable as a static string — which is cheaper and more accurate than a reconstructed `List[CursorOp]`, and unconditional rather than an annotation the author can forget. And because a D field walk is _generated_ rather than composed from monadic combinators, the "`flatMap` kills accumulation" hazard structurally cannot arise: accumulate into a `SmallBuffer!(DecodeError, N)` and every branch always runs. The model to target is [`unjson`'s `Result a Problems`][haskell] — every problem, each anchored, plus a partial value you can still read.

---

## Metadata, derivations & extensibility

**`aeson`'s three tiers.** Template Haskell (`$(deriveJSON …)`) splices concrete code — fastest to compile and to run, but requires the `TemplateHaskell` extension, breaks cross-compilation, and is constrained by splice ordering. `Generic` goes through the `Rep a` tower of `:+:`/`:*:`/`M1` and relies on inlining to specialize away — portable, but with compile-time blowup on wide records. Hand-written instances are the only place per-field control exists at all.

**`circe`'s auto-versus-semiauto is a compile-time pathology, not a runtime one.** `semiauto` runs shapeless `LabelledGeneric` derivation once per type at a named `val`. `io.circe.generic.auto._` instead supplies an implicit **def** that is re-derived at every call site, with superlinear `HList`/`Coproduct` implicit search behind it. The consequences are documented in the issue tracker under titles that need no gloss: [_"Automatic Decoder derivation hangs when used across files"_ (#204)][circe-204] and [_"Slow codec automatic derivation"_ (#2051)][circe-2051]. Runtime performance is identical between the two; the entire distinction is compile-time economics, and `circe-derivation` exists as a third route specifically to escape shapeless.

**`forProductN` is the manual middle ground**, and it shows what tier 1 costs when you take the control back:

```scala
final def forProduct2[A, A0, A1](nameA0: String, nameA1: String)(f: (A0, A1) => A)(g: A => (A0, A1))(
  implicit decodeA0: Decoder[A0], decodeA1: Decoder[A1],
           encodeA0: Encoder[A0], encodeA1: Encoder[A1]): Codec.AsObject[A]

implicit val userCodec: Codec.AsObject[User] =
  Codec.forProduct3("id", "first_name", "last_name")(User.apply)(u => (u.id, u.firstName, u.lastName))
```

Keys are stated once — good — but the constructor `f` and the destructor `g` are both written by hand, and the whole family is machine-generated for arities 1 through 22 by [`project/Boilerplate.scala`][boilerplate]. Twenty-two is a hard ceiling: a 23-field case class simply has no `forProductN`.

**D verdict: [(a)][tags], and two of tier 1's structural costs disappear rather than shrink.** The derivation tiers **collapse**: `static foreach` codegen has Template Haskell's output with `Generic`'s ergonomics — no `Rep` tower to inline away, no splice ordering, no cross-compilation hazard, and the generated code _is_ the specialized code. And **the auto/semiauto distinction does not exist in D**, because there is no implicit search: a template instantiation is memoized by the compiler and keyed by type, so you get auto's ergonomics at semiauto's cost, unconditionally. `forProductN` has no analogue to need — the field list already _is_ the shared spine, so both directions are generated from it and there is no arity cap. See [`./wired-baseline.md`][baseline] for where `sparkles:wired` starts from.

---

## Strengths

- **Unbeatable ergonomics for the common case.** One derived instance covers the overwhelming majority of JSON work in both ecosystems, and both are fast and battle-tested.
- **`aeson` enumerates the sum-encoding design space** better than any other library surveyed, with a concrete, documented table of four layouts.
- **`circe-generic-extras`' two-level split** — `@JsonKey` per field, `Configuration` per type — is the correct shape for annotation-driven metadata.
- **`circe`'s `decodeAccumulating` exists at all**, which puts it ahead of `aeson`, whose only mode is fail-fast.
- **`Codec.iemap` recognizes the partial isomorphism**, even without naming it as such.
- **`circe`'s `useDefaults`** recovers Scala's default arguments, so defaults are declared once.
- **`aeson`'s honesty about hazards** — the tag-collision and untagged-disjointness warnings are in the Haddock, not folklore.

## Weaknesses

- **No reified schema, and everything that follows from it**: no JSON Schema or OpenAPI, no field enumeration, no migrations, no structural diff, no multi-format reuse, no generators or optics.
- **The encoder and decoder are independent artifacts.** `Codec.from(d, e)` accepts any pair; nothing checks that they round-trip.
- **`aeson`'s `Options` is nine global knobs with no per-field control** — one field's rename costs a fragile string-matching lambda or the whole type's derivation.
- **`fieldLabelModifier` is an opaque closure**, so the library cannot report or invert a type's own wire names.
- **`Value` conflates a document DOM with a type description**, and pays for it with the `toJSON`/`toEncoding` split — two methods per type that can disagree.
- **`TaggedObject` emits two different layouts** depending on whether a constructor is a record, and shares a key namespace with the record's fields.
- **`UntaggedValue` is ordered, unchecked, and reports only the last branch's error.**
- **`circe`'s error accumulation is defeated by one `flatMap`** anywhere in the decoder chain — issues [#837][circe-837] and [#2062][circe-2062].
- **`aeson` paths are manual** (`(<?>)`), so hand-written parsers routinely produce pathless errors.
- **`circe`'s `auto` derivation is a compile-time hazard** — [#204][circe-204], [#2051][circe-2051] — with no runtime benefit to show for it.
- **`forProductN` caps at 22 fields** and requires both the constructor and destructor by hand.
- **Unknown fields are dropped silently** unless `rejectUnknownFields`/`strictDecoding` is on, in which case they are rejected; neither library round-trips them.

## Key design decisions and trade-offs

| Decision                                                 | Rationale                                                                         | Trade-off                                                                                           |
| -------------------------------------------------------- | --------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| Two independent type classes (`Encoder`/`Decoder`)       | Each gets the strongest interface its variance allows; `Decoder` can be a `Monad` | The pair is never unified; nothing checks round-tripping; a `Codec` bundle only co-locates them     |
| `Decoder` as `MonadError` with `flatMap`                 | Discriminator-then-branch decoding is expressible directly                        | Destroys error accumulation downstream and makes the codec structurally non-invertible              |
| `aeson`'s single closed `Options` record                 | One value drives both TH and `Generic` derivation; small, predictable surface     | No per-field control at all; a single rename can cost the type its derivation                       |
| `fieldLabelModifier` as `String -> String`               | Maximum flexibility in one field of the record                                    | Opaque and uninvertible — the library cannot enumerate the wire names it produces                   |
| `Value` as the JSON DOM                                  | Simple, universal, easy to manipulate ad hoc                                      | Describes documents, not types; forces the `toJSON`/`toEncoding` split to avoid materializing it    |
| Four `sumEncoding` variants, author's choice             | Covers the real wire formats people actually receive                              | `TaggedObject` changes layout by constructor kind; `UntaggedValue` is unchecked and order-sensitive |
| `auto` derivation via implicit `def`                     | Zero-import ergonomics — no `val` to declare per type                             | Superlinear implicit search re-run per call site; multi-minute compiles, documented as hangs        |
| `forProductN` generated for arities 1–22                 | Explicit key names with no macro or implicit search                               | Hand-written constructor and destructor, positional coupling, and a hard 22-field ceiling           |
| Accumulation as a separate method (`decodeAccumulating`) | Opt-in cost; the fail-fast path stays fast                                        | Only holds if no decoder in the chain uses `flatMap`; conventional rather than compositional        |

---

## Sources

- [circe/circe][circe-repo] · [circe documentation][circe-docs] · [`Codec.scala` — the bundled pair and `iemap`][circe-codec] · [`Decoder.scala` — `MonadError`, `decodeAccumulating`, `emap`][circe-decoder] · [`Encoder.scala` — `Contravariant`][circe-encoder] · [`project/Boilerplate.scala` — `forProductN` generation, arities 1–22][boilerplate]
- [circe semiauto derivation guide][circe-semiauto] · [`circe-generic-extras` `Configuration.scala`][extras-config] · [circe/circe-generic-extras][extras-repo]
- [circe #204 — automatic decoder derivation hangs across files][circe-204] · [#2051 — slow codec automatic derivation][circe-2051] · [#837][circe-837] and [#2062][circe-2062] — accumulation lost in ADT decoders
- [Error-accumulating decoders in circe (Travis Brown)][plasm]
- [`Data.Aeson` — `Options`, `SumEncoding`, `camelTo2`][aeson-docs] · [`Data.Aeson.Types` — `Parser`, `(<?>)`, `JSONPathElement`][aeson-types] · [`Data.Aeson.TH` — `deriveJSON`, `mkToJSON`, `mkParseJSON`][aeson-th] · [haskell/aeson][aeson-repo]
- Related in this catalog: [autodocodec, tomland & unjson — the tier-2 answer][haskell] · [Invertible syntax descriptions — why a codec cannot be a monad][invertible] · [zio-schema — the tier-3 answer][zio-schema] · [Concepts][concepts] · [Comparison][comparison] · [`wired` baseline][baseline]

<!-- References -->

[circe-repo]: https://github.com/circe/circe
[circe-docs]: https://circe.github.io/circe/
[circe-semiauto]: https://circe.github.io/circe/codecs/semiauto-derivation.html
[circe-codec]: https://github.com/circe/circe/blob/2fb611bb49619e4287b6ac048d2283c2781f4943/modules/core/shared/src/main/scala/io/circe/Codec.scala
[circe-decoder]: https://github.com/circe/circe/blob/2fb611bb49619e4287b6ac048d2283c2781f4943/modules/core/shared/src/main/scala/io/circe/Decoder.scala
[circe-encoder]: https://github.com/circe/circe/blob/2fb611bb49619e4287b6ac048d2283c2781f4943/modules/core/shared/src/main/scala/io/circe/Encoder.scala
[boilerplate]: https://github.com/circe/circe/blob/2fb611bb49619e4287b6ac048d2283c2781f4943/project/Boilerplate.scala
[extras-repo]: https://github.com/circe/circe-generic-extras
[extras-config]: https://github.com/circe/circe-generic-extras/blob/f6741cda0dd832b4eb2e50eea3e72dac72c16286/generic-extras/src/main/scala/io/circe/generic/extras/Configuration.scala
[circe-204]: https://github.com/circe/circe/issues/204
[circe-2051]: https://github.com/circe/circe/issues/2051
[circe-837]: https://github.com/circe/circe/issues/837
[circe-2062]: https://github.com/circe/circe/issues/2062
[plasm]: https://meta.plasm.us/posts/2015/12/17/error-accumulating-decoders-in-circe/
[aeson-repo]: https://github.com/haskell/aeson
[aeson-docs]: https://hackage-content.haskell.org/package/aeson-2.3.1.0/docs/Data-Aeson.html
[aeson-types]: https://hackage-content.haskell.org/package/aeson-2.3.1.0/docs/Data-Aeson-Types.html
[aeson-th]: https://hackage-content.haskell.org/package/aeson-2.3.1.0/docs/Data-Aeson-TH.html
[tags]: ./concepts.md#d-feasibility-tags
[tiers]: ./concepts.md#the-three-tiers
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[baseline]: ./wired-baseline.md
[haskell]: ./haskell-codecs.md
[invertible]: ./invertible-syntax.md
[zio-schema]: ./zio-schema.md
