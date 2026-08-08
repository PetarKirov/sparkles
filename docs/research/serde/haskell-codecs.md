# autodocodec, tomland & unjson (Haskell)

Three Haskell libraries in which a codec is a **runtime value** rather than a pair of generated functions — the tier-2 school where one combinator tree decodes, encodes, _and_ documents, and cannot drift because there is only one artifact.

| Field         | Value                                                                                                                                      |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| Language      | Haskell (GHC 9.x)                                                                                                                          |
| License       | `autodocodec` MIT · `tomland` MPL-2.0 · `unjson` BSD-3-Clause (`toml-parser`, the tier-1 foil, is ISC)                                     |
| Repository    | [NorfairKing/autodocodec][autodocodec-repo] · [kowainik/tomland][tomland-repo] · [scrive/unjson][unjson-repo]                              |
| Documentation | [`Autodocodec.Codec`][autodocodec-codec] · [`Toml.Codec.Types`][toml-types] · [`Data.Unjson`][unjson-docs]                                 |
| Category      | **Tier 2 — value-level codec** (see [the three tiers][tiers])                                                                              |
| Status        | `autodocodec-0.6.0.0`, `tomland-1.3.3.3`, `unjson-0.15.4` on Hackage; all three maintained and production-deployed (Scrive ships `unjson`) |

> [!NOTE]
> This page covers the **value-level** Haskell lineage. The tier-1 Haskell/Scala wall — `aeson` and `circe` — is [`./circe-aeson.md`][circe-aeson]; the theory these libraries are an application of is [`./invertible-syntax.md`][invertible]; the tier-3 reified-schema answer is [`./zio-schema.md`][zio-schema].

---

## Overview

### What it solves

A tier-1 derivation (`aeson`'s `Generic`, `circe`'s `deriveCodec`, `serde`'s `#[derive]`) emits two independent functions. Nothing ties them together: the encoder and decoder can disagree, and neither carries structure a third party can read, so documentation, a JSON Schema, or an OpenAPI description must be produced by a **separate** derivation that can silently drift out of step.

The tier-2 answer is to make the codec one inspectable value and interpret it several ways. `autodocodec`'s pitch is the sharpest statement of the payoff: a single `HasCodec` instance yields `ToJSON` (both `toJSON` and `toEncoding`), `FromJSON`, a `ToYaml` instance, a JSON Schema, a colourized human-readable YAML schema, a Swagger2 schema, and an OpenAPI3 schema — all through `DerivingVia`:

```haskell
data Example = Example { ... }
  deriving stock (Show, Eq)
  deriving (FromJSON, ToJSON, Swagger.ToSchema, OpenAPI.ToSchema)
    via (Autodocodec Example)
```

The author's stated motivation, from [the announcement post][autodocodec-post], is a design argument rather than a feature list: an `aeson` CVE prompted rethinking parsing, and there was _"a pressing need for good, definitely-correct documentation for the formats that we use."_ The correctness claim is **structural** — if the docs and the codec are read off one value, they cannot disagree. He also records that the idea _"has been discovered independently a few more times"_, and credits [`tomland`][tomland-repo] with solving the architectural problem first.

### Design philosophy

All three libraries pay the same tax and buy the same thing.

- **The codec is hand-written.** `autodocodec` rejects both derivation routes explicitly: _"both generic programming and Template Haskell are more complex than necessary for this task."_ That is the tier-2 authoring cost, deliberately accepted.
- **The applicative structure is the record structure.** `<$>`/`<*>` over field codecs assemble the decode direction; a record accessor supplies the encode direction for the same field. There is no separate declaration of "the fields".
- **Bidirectionality lives in the type, not in a convention.** `tomland`'s `Codec i o` and `autodocodec`'s `Codec context input output` carry a contravariant `input` and a covariant `output`; the diagonal (`input ~ output`) is the codec a user actually installs.

`tomland`'s own docs are refreshingly candid about how that is achieved: _"Type parameter `i` is fictional. Here some trick is used"_ ([`Toml.Codec.Types`][toml-types]) — `i` never appears in the read direction, so all the `Functor`/`Applicative`/`Alternative` instances are over `o` with `i` held fixed. That is precisely what lets a chain of field codecs all read from the _same_ record.

---

## How it works

### One shape, three spellings

```haskell
-- autodocodec: a profunctor codec, indexed by the context it lives in
type ValueCodec         = Codec Value
type ObjectCodec        = Codec Object
type JSONCodec a        = ValueCodec  a a          -- the diagonal
type JSONObjectCodec a  = ObjectCodec a a

-- tomland: read is a Validation-returning function, write is stateful
data Codec i o = Codec
  { codecRead  :: TomlEnv o           -- TOML -> Validation [TomlDecodeError] o
  , codecWrite :: i -> TomlState o    -- newtype TomlState a = TomlState (TOML -> (Maybe a, TOML))
  }
type TomlCodec a = Codec a a

-- unjson: a plain inspectable GADT, Applicative over the output
data UnjsonDef a   -- ObjectUnjsonDef | ArrayUnjsonDef | DisjointUnjsonDef
                   -- | UnionUnjsonDef | MapUnjsonDef | TupleUnjsonDef | SimpleUnjsonDef
```

`tomland`'s write side is **stateful** for a concrete reason: encoding a field must _insert_ into a growing `TOML` table, so `TomlState a` is morally `MaybeT (State TOML) a`. Decoding uses `Validation`, not `Either`, so errors accumulate (see [Errors & context](#errors--context)).

### The three canonical instances

```haskell
-- autodocodec
instance HasCodec Example where
  codec = object "Example" $ Example
    <$> requiredField "text" "a text"                          .= exampleText
    <*> requiredField "bool" "a bool"                          .= exampleBool
    <*> optionalField "optional" "an optional text"            .= exampleOptional
    <*> optionalFieldOrNull "optional-or-null" "…"             .= exampleOptionalOrNull
    <*> optionalFieldWithDefault "optional-with-default" "foobar" "…" .= exampleOptionalWithDefault
    <*> optionalFieldWithOmittedDefault "optional-with-null-default" [] "…" .= exampleOptionalWithNullDefault
    <*> optionalFieldWithOmittedDefaultWith "single-or-list" (singleOrListCodec codec) [] "…" .= exampleSingleOrList

-- tomland
settingsCodec :: TomlCodec Settings
settingsCodec = Settings
    <$> Toml.diwrap (Toml.int  "server.port")       .= settingsPort
    <*> Toml.text              "server.description" .= settingsDescription
    <*> Toml.arrayOf Toml._Int "server.codes"       .= settingsCodes
    <*> Toml.table mailCodec   "mail"               .= settingsMail
    <*> Toml.list  userCodec   "user"               .= settingsUsers

-- unjson
unjsonExample :: UnjsonDef Example
unjsonExample = objectOf $ pure Example
  <*> field      "name"           exampleName     "Name used for example"
  <*> fieldDefBy "array_of_ints" [] exampleArray   "Array of integers, optional, defaults to empty"
                 (arrayOf unjsonDef)
  <*> fieldOpt   "optional_bool"  exampleOptional "Optional boolean"
```

Read the first two structurally: `<$>`/`<*>` build the **decode** direction (apply the constructor to parsed fields), and `.= accessor` supplies the **encode** direction for that same field. `unjson` folds the accessor into the field combinator itself (`field "name" exampleName`), which is the same mechanism with one fewer operator.

### `(.=)` is the whole mechanism

```haskell
-- autodocodec
(.=) :: ObjectCodec oldInput output -> (newInput -> oldInput) -> ObjectCodec newInput output

-- tomland, in full
(.=) :: Codec field a -> (object -> field) -> Codec object a
codec .= getter = codec { codecWrite = codecWrite codec . getter }
```

Precompose the write side with the record accessor. That is the entire operator, and the record accessor `exampleText :: Example -> Text` _is_ the contravariant half of the codec. Everything the tier-2 school achieves through `lmap` and profunctors, it achieves in order to obtain **a function from the record to one field, paired with the field's name** — which is exactly what `__traits(getMember, value, name)` hands a D program for free.

---

## Schema model & bidirectionality

**`autodocodec` — the `Codec` GADT.** `Codec context input output` has two value parameters: `input` (contravariant, what you encode _from_) and `output` (covariant, what you decode _into_). Selected constructors, verbatim from [`Autodocodec.Codec`][autodocodec-codec]:

```haskell
NullCodec     :: (Coercible input (), Coercible output ()) => Codec Value input output
BoolCodec     :: (Coercible input Bool, Coercible output Bool) => Maybe Text -> Codec Value input output
StringCodec   :: (Coercible input Text, Coercible output Text)
              => Maybe Text -> StringBounds -> Codec Value input output
IntegerCodec  :: (Coercible input Integer, Coercible output Integer)
              => Maybe Text -> Bounds Integer -> Codec Value input output
ArrayOfCodec  :: Maybe Text -> ValueCodec input1 output1 -> Codec Value input output
ObjectOfCodec :: Maybe Text -> ObjectCodec input output -> Codec Value input output
EqCodec       :: (Show value, Eq value, Coercible input value, Coercible output value)
              => value -> JSONCodec value -> Codec Value input output
CommentCodec   :: Text -> ValueCodec input output -> Codec Value input output
ReferenceCodec :: Text -> ~(ValueCodec input output) -> Codec Value input output
PureCodec :: output -> Codec (KeyMap Value) input output
ApCodec   :: ObjectCodec input (output1 -> output) -> ObjectCodec input output1
          -> Codec (KeyMap Value) input output
```

Four structural observations:

1. **Documentation is a constructor, not metadata hanging off the side.** `CommentCodec :: Text -> ValueCodec i o -> Codec Value i o` puts the doc string at a _node in the tree_, so every interpreter (JSON Schema, Swagger, the YAML pretty-printer) sees it at exactly the right structural position. The infix forms are `(<?>) :: ValueCodec i o -> Text -> ValueCodec i o` and `(<??>) :: ValueCodec i o -> [Text] -> ValueCodec i o`.
2. **`PureCodec` + `ApCodec` are the free applicative, reified.** Making the applicative _structure_ into data is the trick that supports "one declaration, N interpreters": the chain can be walked without being run.
3. **`ReferenceCodec :: Text -> ~(ValueCodec i o) -> ...` is a _named_, _lazy_ node.** The laziness ties recursion; the name is what lets a JSON Schema emitter write `$ref: "#/definitions/Foo"` instead of inlining forever. Any schema emitter needs this, and it is the requirement that is easiest to forget until a recursive type hangs the emitter.
4. **`EqCodec` is the literal node** — a codec that accepts exactly one value. Discriminators are then built out of ordinary pieces rather than special-cased.

**`tomland` — the two-layer split.** `tomland`'s architectural contribution, and the one `autodocodec` credits, is separating **type conversion** from **key matching**:

```haskell
type TomlBiMap  = BiMap TomlBiMapError    -- Haskell type <-> TOML value
type TomlCodec a = Codec a a              -- ... plus key matching

data BiMap e a b = BiMap { forward :: a -> Either e b, backward :: b -> Either e a }

invert :: BiMap e a b -> BiMap e b a
iso    :: (a -> b) -> (b -> a) -> BiMap e a b
prism  :: (field -> object) -> (object -> Either error field) -> BiMap error object field
```

`Toml.match` lifts a `TomlBiMap` into a `TomlCodec`. The naming convention makes the layering visible: `TomlBiMap`s are capitalized with a leading underscore (`Toml._Int`, `Toml._Text`), codecs are lowercase (`Toml.int`, `Toml.text`).

`BiMap` is [Rendel's `Iso`][invertible] with `Either e` in place of `Maybe` — the same partial isomorphism, but **carrying a reason for failure**. That single upgrade is most of the distance between a theory paper and a usable library, and it is the same choice `sparkles:base` already made with [`Expected!(T, E)`][expected]. Note too that `prism` (a total constructor plus a fallible matcher) is exactly [`zio-schema`'s `Case[R, A]`][zio-schema] written in Haskell: two libraries, two languages, one rediscovered primitive.

**`unjson` — the same GADT, plus a documentation walk.** `UnjsonDef a` is a plain inspectable sum whose cases mirror the JSON shapes, and `render`/`renderDoc` walk it to produce human-readable schema documentation from the same value that parses.

**D verdict: [(b)][tags] for the node tree, [(a)][tags] for the bidirectionality mechanism.** The `Codec` GADT maps onto a flat `SchemaNode[]` arena built in CTFE (the pattern `sparkles:diff` already uses), with a `ref(index)` node and a name table standing in for `ReferenceCodec` — that part is real but mechanical work. The `input`/`output` profunctor machinery, however, does not need porting at all: it exists to recover a per-field accessor that D's reflection supplies directly, and `ApCodec` exists to re-reify a product that `T.tupleof` never lost. Documentation is [(a)][tags] and strictly better in D — `@description("…")` as a UDA, plus `__traits(docComment)`, which reads the ddoc a programmer already wrote where they already write it.

---

## Naming, optionality & defaults

`autodocodec` is the reference statement of the optionality problem, because it enumerates the cases instead of collapsing them:

| Constructor                          | Absent on decode | Written on encode           |
| ------------------------------------ | ---------------- | --------------------------- |
| `RequiredKeyCodec`                   | error            | always                      |
| `OptionalKeyCodec`                   | `Nothing`        | only when `Just`            |
| `OptionalKeyWithDefaultCodec`        | the default      | **always**, even at default |
| `OptionalKeyWithOmittedDefaultCodec` | the default      | omitted when equal to it    |

Cross that with the `orNull` variants — `optionalFieldOrNull` treats an explicit JSON `null` as absence — and the result is a **3×2 matrix**: {required, optional, defaulted} × {null-is-absent, null-is-a-value}.

> [!IMPORTANT]
> Every library in this survey with fewer distinctions than that matrix has a known bug class. [ATD][atd]'s `?field` versus `~field` is the same distinction spelled in two characters; `ppx_yojson_conv`'s `[@yojson_drop_default]`/`[@yojson_drop_if]` is the omit-on-write half only; [`aeson`][circe-aeson]'s `omitNothingFields` is one global boolean for the whole program.

`tomland` has only `Toml.dioptional`, which wraps a codec to `Maybe` and then interacts awkwardly with defaults — the matrix rediscovered as friction. `unjson` lands in between with three field combinators: `field` (required), `fieldOpt` (optional), and `fieldDefBy` (defaulted, with the default supplied at the use site).

Two smaller pieces of naming vocabulary worth recording:

- **`Toml.diwrap`** — automatic newtype (un)wrapping, a `Coercible`-driven `dimap`, so a `newtype Port = Port Int` costs nothing at the codec site.
- **`singleOrListCodec`** — "an optional list that can also be specified as a single element", the classic YAML/CI-config affordance, expressed as an ordinary combinator rather than a special case in the generator.

Note what is _absent_ across all three: there is no rename vocabulary, because there is nothing to rename. The wire key is a string literal the author typed; the record accessor is separate. Renaming a field in Haskell does not touch the wire name, and renaming a wire key does not touch the Haskell field. That decoupling is free here and must be bought explicitly in a reflection-driven design.

**D verdict: [(a)][tags], and this is a "get it right on day one" item.** The 3×2 matrix maps onto `Nullable!T` versus a field with an initializer versus `@omitIfDefault`, with an explicit stated policy for JSON `null` — the distinctions cost nothing to encode as UDAs and are expensive to retrofit once wire formats are in the field. `singleOrListCodec` is a `@scalarOrArray` UDA; `diwrap` is a single-field struct or `alias this`. Defaults are _easier_ in D than in any surveyed language: a struct field initializer is directly readable as `T.init.field`, where Scala needs a macro to recover default arguments and Haskell needs the default written a second time at the codec site.

---

## Sum types & discrimination

`autodocodec` offers the fullest vocabulary:

```haskell
eitherCodec         :: Codec ctx i1 o1 -> Codec ctx i2 o2 -> Codec ctx (Either i1 i2) (Either o1 o2)
disjointEitherCodec :: Codec ctx i1 o1 -> Codec ctx i2 o2 -> Codec ctx (Either i1 i2) (Either o1 o2)
matchChoiceCodec    :: Codec ctx i o -> Codec ctx i' o -> (newInput -> Either i i') -> Codec ctx newInput o
matchChoicesCodec   :: [(input -> Maybe input, Codec ctx input output)] -> Codec ctx input output
                    -> Codec ctx input output
discriminatedUnionCodec
  :: Text
  -> (input -> (Discriminator, ObjectCodec input ()))
  -> HashMap Discriminator (Text, ObjectCodec Void output)
  -> ObjectCodec input output
```

**The joint/disjoint distinction is the most economical piece of design in the library.** `eitherCodec` and `disjointEitherCodec` are the _same_ constructor with a different `Union` tag (`PossiblyJointUnion` versus `DisjointUnion`). The tag **does not change decoding** — it changes the emitted schema: a joint union becomes JSON Schema `anyOf`, a disjoint union becomes `oneOf`. The author is thereby forced to _state_ whether the branches overlap, and the statement becomes documentation. Untagged sums that leave the fact unstated ([`aeson`'s `UntaggedValue`][circe-aeson], [ATD][atd]'s implicit ordering) are exactly the ones with bad diagnostics.

**`discriminatedUnionCodec` exposes an asymmetry that is intrinsic, not incidental.** The encode side is a function `input -> (Discriminator, ObjectCodec input ())` — given a value, tell me its tag and how to write it. The decode side is a `HashMap Discriminator (Text, ObjectCodec Void output)` — a table from tag to branch. **Encoding is a fold; decoding is a dispatch.** Every discriminated-union implementation has this shape, whether or not it names it.

`tomland` is where the tier-2 sum-type pain is visible in the small:

```haskell
matchGuest :: User -> Maybe Integer
matchGuest = \case { Guest i -> Just i; _ -> Nothing }

matchRegistered :: User -> Maybe RegisteredUser
matchRegistered = \case { Registered u -> Just u; _ -> Nothing }

userCodec :: TomlCodec User
userCodec =
        Toml.dimatch matchGuest      Guest      (Toml.integer "guestId")
    <|> Toml.dimatch matchRegistered Registered registeredUserCodec
```

Three problems, all intrinsic to the tier:

1. **`dimatch` needs a hand-written prism per constructor.** Constructor pattern-matching is exactly what a compiler knows and a value-level library does not. [Rendel's answer was Template Haskell][invertible] — `defineIsomorphisms` `reify`s the type and generates these — which is a macro system compensating for missing reflection.
2. **`<|>` is ordered, untagged, first-match-wins**, with all the ambiguity hazards of an untagged encoding and nowhere to record that the branches are disjoint (contrast `autodocodec`'s `Union` tag).
3. **The decode direction backtracks; the encode direction does not.** `dimatch` reverses the matching logic for writing, so the two halves are authored in opposite styles and can silently disagree about which branch is "first".

A fourth, cutting across every tier-2 library: **arity and order coupling.** `<$>`/`<*>` positions must match the constructor's field order exactly, and when they do not, the compiler's error is a type mismatch reported three fields away from the mistake. [`circe`'s `forProductN`][circe-aeson] has the same defect plus a hard 22-arity cap.

**D verdict: [(b)][tags] for the machinery, with a bonus no surveyed library can claim.** The tag switch is CTFE-generated; the branch list comes from the tagged union, so the prism is a generated tag check rather than a hand-written matcher; the field order comes from `.tupleof`, so it cannot desync; and there is no arity ceiling. The bonus is **compile-time disjointness**: for an untagged sum, compare the branches' key-sets in CTFE and `static assert` when two are ambiguous. `aeson` can only warn in prose and `autodocodec` can only ask the author to assert it — `wired` can _prove_ it.

---

## Transformations & validation

The profunctor family is the transformation vocabulary, and `autodocodec` spells out all four directions:

```haskell
dimapCodec :: (oldOutput -> newOutput) -> (newInput -> oldInput)
           -> Codec ctx oldInput oldOutput -> Codec ctx newInput newOutput
bimapCodec :: (oldOutput -> Either String newOutput) -> (newInput -> oldInput)
           -> Codec ctx oldInput oldOutput -> Codec ctx newInput newOutput
rmapCodec  :: (oldOutput -> newOutput) -> Codec ctx input oldOutput -> Codec ctx input newOutput
lmapCodec  :: (newInput -> oldInput) -> Codec ctx oldInput output -> Codec ctx newInput output
```

`bimapCodec` is the validating form: the forward direction may fail with a `String`, the backward direction is total. That asymmetry (fallible read, total write) is the recurring signature of a **partial isomorphism**, and it shows up again as `tomland`'s `BiMap` and as [`circe`'s `iemap`][circe-aeson].

Validation _bounds_ also live on the primitive nodes rather than in a separate pass: `StringCodec :: Maybe Text -> StringBounds -> …` and `IntegerCodec :: Maybe Text -> Bounds Integer -> …`. Because the bounds are constructor fields, the schema emitter can render them as JSON Schema `minLength`/`maximum` without the validator and the documentation being two separate declarations — the same non-drift argument as `CommentCodec`.

### `unjson`'s `update` — the asymmetric-lens `put`, in a serialization library

```haskell
parse  ::      UnjsonDef a -> Value -> Result a
update :: a -> UnjsonDef a -> Value -> Result a
```

`update` merges a **partial** JSON document into an **existing value** — PATCH semantics. Array updates can even match old against new elements by an extractable primary key. This is the `put` of an [asymmetric lens][invertible] (`put :: V -> S -> S`, taking the original source) smuggled into a serialization library, and **no other library in this survey has it**.

> [!IMPORTANT]
> `update` is exactly the shape a configuration system needs. Defaults ⊕ config file ⊕ environment ⊕ argv is `update` composed four times over one declaration — one mechanism instead of four bespoke merge passes. Compare [`./argv-codecs.md`][argv], where the same layering problem is approached from the CLI side.

**D verdict: [(a)][tags] for `update`, and it is _easier_ in D than in Haskell.** Haskell needs a lens because its records are immutable; D writes `foreach (i, ref f; dst.tupleof) if (src.has(name!i)) parseInto(f);` — a literal partial in-place update over mutable fields. `bimapCodec`-style fallible conversions map onto `Expected!(T, E)`; bounds map onto a `@validate` UDA read by the same CTFE walk that emits the schema. The one genuine value-level residue is a small `Iso!(A, B)` escape hatch for custom scalar spellings (unit suffixes, enum aliases, legacy date formats) — worth having, not worth making the spine.

---

## Errors & context

The three libraries occupy three different points, and `unjson` is the one to beat.

**`tomland` accumulates, with a typed conversion error.** `TomlEnv a = TOML -> Validation [TomlDecodeError] a` — `Validation`, not `Either`, so independent field failures all survive. The `BiMap` layer contributes its own error type, and it is deliberately small:

```haskell
data TomlBiMapError
  = WrongConstructor Text Text
  | WrongValue MatchError
  | ArbitraryError Text

wrongConstructor :: Show a => Text -> a -> Either TomlBiMapError b
prettyBiMapError :: TomlBiMapError -> Text
```

**`autodocodec` is fail-fast**, inheriting `aeson`'s `Either String` — the least developed dimension of the library, and a fair trade for what it spends its budget on.

**`unjson` is the most complete error model in the survey:**

```haskell
data Result a  = Result a Problems
type Problem   = Anchored Text
data Anchored a = Anchored Path a
data Path      = Path [PathElem]
data PathElem  = PathElemKey Text | PathElemIndex Int
```

Three properties compound:

1. **All problems at once.** Being `Applicative` and not `Monad` is what pays here: independent branches all run, so nothing short-circuits the walk. (Contrast [`circe`, where a single `flatMap` silently destroys accumulation downstream][circe-aeson].)
2. **Every problem is anchored to a path** — `array_of_ints[1]`, built from `PathElemKey`/`PathElemIndex` rather than reconstructed from a cursor log.
3. **A usable partial value comes back with the errors.** `Result a Problems` gives you an `a`: touching a field that failed throws, but every field that parsed is available. That is the difference between "your document is invalid" and "your document is invalid _here_, and here is everything else it said".

**D verdict: [(a)][tags] for the model, [(b)][tags] for making the paths free.** `Result a Problems` is a `SmallBuffer!(Anchored, N)` plus a `PathElem[]` breadcrumb threaded through a generated walk — no allocation, and the accumulation hazard structurally cannot arise because a generated `static foreach` always visits every branch. The path itself should be better than any library here: it is the **schema path**, known at compile time and sliceable as a static string, so it is emitted unconditionally rather than being an annotation the author of a hand-written parser can forget to attach.

---

## Metadata, derivations & extensibility

**None of the three derives anything.** That is the tier's defining cost, and it is a deliberate choice, not an oversight — `autodocodec` explicitly declines Generics and Template Haskell as _"more complex than necessary for this task"_. What the tier buys instead is that the one hand-written value supports arbitrarily many interpreters, including ones written later by someone else: `autodocodec-schema`, `autodocodec-swagger2`, and `autodocodec-openapi3` are separate packages that read a `Codec` the type's author never customized for them, and `unjson`'s `render`/`renderDoc` are the same trick for human-readable docs.

The metadata channel is positional: a doc string is a `CommentCodec` node, bounds are constructor fields, joint-versus-disjoint is a `Union` tag. There is no open annotation set — a downstream interpreter can only read metadata the codec type has a constructor for.

### The tier-2 tax is authoring cost, not runtime cost

`toml-parser` is the tier-1 foil: `FromValue`/`ToValue`/`ToTable` classes with a `Matcher` monad for decoding and Generic-derived instances ([`Toml.Schema.FromValue`][toml-parser-docs]). It is the fastest Haskell TOML library and it is fast **because it is unidirectional-by-pair** — two independent class instances, no shared value, no guarantee they agree. `tomland`'s own benchmark table makes the trade visible:

| Library            | parse (`Text` → AST) | transform (AST → Haskell) |
| ------------------ | -------------------- | ------------------------- |
| `tomland`          | 305.5 μs             | **1.280 μs**              |
| `toml-parser`      | 164.6 μs             | **1.101 μs**              |
| `htoml`            | 852.8 μs             | 33.37 μs                  |
| `htoml-megaparsec` | 295.0 μs             | 33.62 μs                  |

The **transform** column is the one that matters for the tier question: interpreting `tomland`'s codec _value_ costs 1.28 μs against `toml-parser`'s generated 1.101 μs — within noise — and 26× less than the `aeson`-mediated libraries. Whatever tier 2 costs, it is not interpretation speed; it is the accessor per field, the prism per constructor, and the arity-coupled applicative chain.

**D verdict: [(b)][tags], and the survey's benchmark removes the usual objection.** A schema-interpretation architecture is not a performance concession: `tomland` pays under 200 ns per record against generated code, and D's schema is a CTFE constant that LDC can specialize against, which the Haskell version is not. The extensibility model should go further than any library here — `__traits(getAttributes)` is an **open, typed** annotation channel, so a backend written later can read a UDA the schema layer never heard of, without a constructor being added for it. See [`./wired-baseline.md`][baseline] for where `sparkles:wired` stands today and [`./comparison.md`][comparison] for the cross-library synthesis.

---

## Strengths

- **Non-drift by construction.** Docs, JSON Schema, Swagger, and OpenAPI are interpretations of the same value that parses and prints; they cannot disagree with the codec, which is the entire reason `autodocodec` exists.
- **Optionality is enumerated, not approximated.** Four distinct key constructors plus `orNull` variants cover the full {required, optional, defaulted} × {null-is-absent, null-is-a-value} matrix.
- **Overlap is stated, not assumed.** The joint/disjoint `Union` tag forces the author to declare whether sum branches can both match, and turns the declaration into schema output.
- **`tomland`'s two-layer split is good architecture in any language** — scalar conversion (`BiMap`) and key matching (`Codec`) are genuinely different concerns, and separating them keeps custom scalar spellings out of the structural layer.
- **`BiMap` carries a failure reason** (`Either e`, not `Maybe`), which is what makes the partial-isomorphism idea usable rather than merely correct.
- **`unjson`'s error model is best in class**: accumulated, path-anchored, and accompanied by a partial value you can still read.
- **`unjson`'s `update` is unique in the survey** — real PATCH/merge semantics from the same declaration used for parsing.
- **Interpretation is cheap.** The benchmark shows a codec-value walk within noise of generated code.

## Weaknesses

- **Every codec is hand-written.** One accessor per field, one prism per constructor, and a chain whose argument order must match the constructor's — with no compiler assistance when it does not.
- **Arity and order coupling** produces type errors reported far from the mistake.
- **Sum types are the weak point.** `tomland` has no applicative story for choice at all: ordered, untagged, first-match-wins `<|>`, with the encode and decode halves written in opposite styles.
- **The metadata channel is closed.** Only what a `Codec` constructor models can reach an interpreter; there is no open annotation set for a backend nobody has written yet.
- **No migration story.** `optionalFieldWithDefault` is the entire versioning answer; nothing transforms v1 data into v2 (contrast [`zio-schema`][zio-schema]).
- **Unknown fields are dropped.** None of the three round-trips data the type does not model.
- **`autodocodec`'s errors are fail-fast**, strictly weaker than `tomland`'s accumulation and far weaker than `unjson`'s.
- **The wire name and the field name are decoupled by hand**, so there is no rename or alias vocabulary — only string literals typed at the codec site.

## Key design decisions and trade-offs

| Decision                                                               | Rationale                                                                                  | Trade-off                                                                                    |
| ---------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------- |
| Codec as a runtime value, not generated functions                      | One artifact, many interpreters — docs and schema provably match the codec                 | Hand-written per type; the authoring tax the whole tier pays                                 |
| Reject Generics and Template Haskell (`autodocodec`)                   | _"More complex than necessary for this task"_; keeps the library small and debuggable      | No escape from writing the codec; no path to auto-derivation later                           |
| Two value parameters (`input`/`output`) with a diagonal alias          | Lets one applicative chain read from the whole record while each field contributes a part  | Type signatures carry a parameter users never instantiate off-diagonal                       |
| `(.=)` as `lmap` with the record accessor                              | The accessor _is_ the encode direction; no `Iso`, no Template Haskell, no separate table   | The accessor must be written by hand, and nothing checks it matches the applicative position |
| Documentation as a constructor (`CommentCodec`)                        | Docs land at the right structural node for every interpreter                               | Doc strings sit at the codec site, not where the programmer defined the type                 |
| Joint versus disjoint `Union` tag that changes only the emitted schema | Forces the author to state branch overlap; turns an assumption into documentation          | Purely declarative — nothing verifies the claim                                              |
| Split `TomlBiMap` (conversion) from `Codec` (key matching)             | Two genuinely different concerns; custom scalar spellings stay out of the structural layer | Two vocabularies and two naming conventions to learn                                         |
| `Validation`/`Result` accumulation instead of `Either`                 | Report every problem in one pass; `unjson` additionally returns a usable partial value     | Requires staying `Applicative`; any monadic bind in the chain silently destroys accumulation |
| `update` alongside `parse` (`unjson`)                                  | Partial merge over an existing value — config layering as one mechanism                    | Doubles the interpreter surface; needs a key extractor to merge arrays sensibly              |

---

## Sources

- [`autodocodec` on Hackage][autodocodec-hackage] · [`Autodocodec.Codec` — the `Codec` GADT][autodocodec-codec] · [`Autodocodec.Class` — `HasCodec`][autodocodec-class] · [`autodocodec-schema`][autodocodec-schema]
- [Announcing autodocodec (cs-syd.eu) — the motivation and the rejection of Generics/TH][autodocodec-post] · [NorfairKing/autodocodec][autodocodec-repo]
- [`tomland` on Hackage][tomland-hackage] · [`Toml.Codec.Types` — `Codec`, `TomlEnv`, `TomlState`, the "fictional `i`" note][toml-types] · [`Toml.Codec.BiMap` — `BiMap`, `iso`, `prism`, `TomlBiMapError`][toml-bimap] · [`Toml.Codec.Combinator.Common` — `match`][toml-common] · [kowainik/tomland — README, worked example, benchmarks][tomland-repo]
- [glguy/toml-parser — the tier-1 foil][toml-parser-repo] · [`Toml.Schema.FromValue`][toml-parser-docs]
- [`Data.Unjson` — `UnjsonDef`, `Result`/`Anchored`/`Path`, `parse`/`update`, `render`/`renderDoc`][unjson-docs] · [scrive/unjson][unjson-repo]
- [`codec` (Li-yao Xia) — `FieldInfo` evaluated three ways: schema, print, parse][codec-hackage] · [`profunctor-monad` — monadic bidirectional programming][profunctor-monad]
- [Applicative bidirectional serialization combinators (Jasper Van der Jeugt)][jaspervdj]
- Related in this catalog: [circe & aeson — the tier-1 wall][circe-aeson] · [Invertible syntax descriptions (theory)][invertible] · [zio-schema — the tier-3 answer][zio-schema] · [ATD & the OCaml lineage][atd] · [argv codecs][argv] · [Concepts][concepts] · [Comparison][comparison]

<!-- References -->

[autodocodec-hackage]: https://hackage.haskell.org/package/autodocodec
[autodocodec-codec]: https://hackage-content.haskell.org/package/autodocodec-0.6.0.0/docs/Autodocodec-Codec.html
[autodocodec-class]: https://hackage-content.haskell.org/package/autodocodec-0.6.0.0/docs/Autodocodec-Class.html
[autodocodec-schema]: https://hackage.haskell.org/package/autodocodec-schema
[autodocodec-post]: https://cs-syd.eu/posts/2021-11-19-autodocodec
[autodocodec-repo]: https://github.com/NorfairKing/autodocodec
[tomland-hackage]: https://hackage.haskell.org/package/tomland
[tomland-repo]: https://github.com/kowainik/tomland
[toml-types]: https://hackage.haskell.org/package/tomland-1.3.3.3/docs/Toml-Codec-Types.html
[toml-bimap]: https://hackage.haskell.org/package/tomland-1.3.3.3/docs/Toml-Codec-BiMap.html
[toml-common]: https://hackage.haskell.org/package/tomland-1.3.3.3/docs/Toml-Codec-Combinator-Common.html
[toml-parser-repo]: https://github.com/glguy/toml-parser
[toml-parser-docs]: https://hackage-content.haskell.org/package/toml-parser-2.0.2.0/docs/Toml-Schema-FromValue.html
[unjson-docs]: https://hackage.haskell.org/package/unjson-0.15.4/docs/Data-Unjson.html
[unjson-repo]: https://github.com/scrive/unjson
[codec-hackage]: https://hackage.haskell.org/package/codec
[profunctor-monad]: https://hackage.haskell.org/package/profunctor-monad
[jaspervdj]: https://jaspervdj.be/posts/2012-09-07-applicative-bidirectional-serialization-combinators.html
[expected]: ../../guidelines/idioms/expected/index.md
[tags]: ./concepts.md#d-feasibility-tags
[tiers]: ./concepts.md#the-three-tiers
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[baseline]: ./wired-baseline.md
[circe-aeson]: ./circe-aeson.md
[invertible]: ./invertible-syntax.md
[zio-schema]: ./zio-schema.md
[atd]: ./ocaml-atd.md
[argv]: ./argv-codecs.md
