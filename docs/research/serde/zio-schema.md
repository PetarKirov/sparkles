# zio-schema (Scala)

The purest reified-schema design in the survey: `Schema[A]` is not a type class but a **closed algebraic data type you can pattern-match on**, and every capability the library ships — codecs for six formats, diffing, patching, migration, optics, generators — is a fold over that value.

| Field         | Value                                                                                   |
| ------------- | --------------------------------------------------------------------------------------- |
| Language      | Scala 2.13 / 3 (cross-published, plus Scala.js and Scala Native)                        |
| License       | Apache-2.0                                                                              |
| Repository    | [zio/zio-schema][repo]                                                                  |
| Documentation | [zio.dev/zio-schema][docs] · [javadoc.io][javadoc]                                      |
| Category      | **Tier 3 — reified schema** (see [the three tiers][tiers])                              |
| Status        | Active; `v1.8.5` at the time of writing, part of the ZIO ecosystem                      |
| Reification   | `Schema[A]` is a `sealed trait` ADT; `MetaSchema` is its type-erased, serializable twin |
| Intermediate  | `DynamicValue` — a format-neutral value **carrying type witnesses** (not a JSON DOM)    |

---

## Overview

### What it solves

The problem zio-schema attacks is the one every tier-1 codegen library leaves on the table: a derived `Encoder`/`Decoder` pair is **two opaque functions**, so nothing downstream can ask a question about the type. You cannot emit a JSON Schema from it, cannot diff two values structurally, cannot ask whether version 2 of a record can read version 1's bytes, and cannot add a new wire format without re-deriving at every declaration site.

zio-schema's answer is to make the structure itself a first-class runtime value, then write every one of those capabilities as an interpreter over it. The declaration stays as short as `implicit val schema: Schema[Person] = DeriveSchema.gen` — a macro — but what the macro produces is data, not code.

### Design philosophy

From the project's own introduction ([zio.dev/zio-schema][docs]):

> _"It turns a compiled-time construct (the type of a data structure) into a runtime construct (a value that can be read, manipulated, and composed at runtime). A schema is a structure of a data type. ZIO Schema reifies the concept of structure for data types. It makes a high-level description of any data type and makes them first-class values."_

Two consequences run through the whole design:

1. **Structure stays inspectable; only functions are quarantined.** Exactly one ADT case (`Transform`) holds a Scala closure. Everything else is plain data, which is why `MetaSchema` (the schema with its type parameters erased) can be serialized and shipped.
2. **Capabilities are interpreters, not instances.** `ProtobufCodec` was written without knowing `Person` exists, and `Person` was declared without knowing protobuf exists. In tier 1 every (type × format) pair costs a derivation; here it costs nothing.

For the tier-2 alternative — a hand-written combinator value that also carries docs but not structure — see [the Haskell codec libraries][haskell]; for the tier-1 baseline this is reacting against, see [circe & aeson][circe] and [OCaml ppx & ATD][ocaml].

---

## How it works

A schema is built once per type, usually by the `DeriveSchema.gen` macro, and then handed to interpreters:

```scala
final case class Person(name: String, age: Int)

object Person {
  implicit val schema: Schema[Person] = DeriveSchema.gen
  val protobufCodec: BinaryCodec[Person] = ProtobufCodec.protobufCodec
}
// Person("John", 43) encodes to the protobuf bytes 0A044A6F686E102B
```

The user-facing surface of `Schema[A]` ([`Schema.scala`][schema-src]) is best read as a catalogue of what a reified schema buys you:

```scala
sealed trait Schema[A] {
  type Accessors[Lens[_, _, _], Prism[_, _, _], Traversal[_, _]]

  def annotations: Chunk[Any]
  def annotate(annotation: Any): Schema[A]

  def defaultValue: Either[String, A]
  def ordering: Ordering[A]
  def validate(value: A)(implicit s: Schema[A]): Chunk[ValidationError]

  def toDynamic(value: A): DynamicValue
  def fromDynamic(value: DynamicValue): Either[String, A]

  def diff(thisValue: A, thatValue: A): Patch[A]
  def patch(oldValue: A, diff: Patch[A]): Either[String, A]
  def migrate[B](newSchema: Schema[B]): Either[String, A => Either[String, B]]
  def coerce[B](newSchema: Schema[B]): Either[String, Schema[B]]

  def transform[B](f: A => B, g: B => A)(implicit loc: SourceLocation): Schema[B]
  def transformOrFail[B](f: A => Either[String, B],
                         g: B => Either[String, A])(implicit loc: SourceLocation): Schema[B]

  def optional: Schema[Option[A]]                 // plus repeated / zip / orElseEither

  def serializable: Schema[Schema[A]]
  def makeAccessors(b: AccessorBuilder): Accessors[b.Lens, b.Prism, b.Traversal]
}
```

`serializable: Schema[Schema[A]]` is the tell that the reification is genuine: **the schema of the schema**. A schema can be encoded with any of the shipped codecs, sent over a wire, and reconstructed on the far side — after which the receiver can decode data for a type its own compiler has never seen. Nothing in tier 1 or tier 2 can express that sentence.

---

## Schema model & bidirectionality

### The ADT cases

```scala
final case class Primitive[A](standardType: StandardType[A], annotations: Chunk[Any])
final case class Optional[A](schema: Schema[A], annotations: Chunk[Any])
final case class Fail[A](message: String, annotations: Chunk[Any])
final case class Tuple2[A, B](left: Schema[A], right: Schema[B], annotations: Chunk[Any])
final case class Sequence[Col, Elem, I](
  elementSchema: Schema[Elem],
  fromChunk: Chunk[Elem] => Col,
  toChunk: Col => Chunk[Elem],
  annotations: Chunk[Any],
  identity: I)
final case class Map[K, V](keySchema: Schema[K], valueSchema: Schema[V], annotations: Chunk[Any])
final case class Set[A](elementSchema: Schema[A], annotations: Chunk[Any])
final case class Either[A, B](left: Schema[A], right: Schema[B], annotations: Chunk[Any])
final case class Fallback[A, B](left: Schema[A], right: Schema[B],
                                fullDecode: Boolean, annotations: Chunk[Any])
final case class Dynamic(annotations: Chunk[Any]) extends Schema[DynamicValue]
final case class Lazy[A](private val schema0: () => Schema[A])
final case class Transform[A, B, I](
  schema: Schema[A],
  f: A => Either[String, B],
  g: B => Either[String, A],
  annotations: Chunk[Any],
  identity: I)
```

Two cases carry the design load.

**`Transform[A, B, I]` is the single quarantined opaque case.** It is the only place a Scala function hides inside a schema, and that is deliberate: everything structural stays walkable, and the one node an interpreter cannot see through is explicitly marked. Note the `identity: I` field — it exists purely so two `Transform`s can be compared for equality despite holding uncomparable closures. That is a workaround for closures being opaque at runtime, and a compile-time D design does not need it: a CTFE function symbol is comparable by its fully qualified name.

**`Lazy[A]` ties the recursion knot.** Any reified schema for a recursive type needs some way to represent a back-edge, and a thunk is the only option available to a language whose values are heap graphs. A D schema has a strictly better one: a flat `SchemaNode[]` arena with integer `ref(index)` nodes — the same pattern `sparkles:diff` already uses. It allocates nothing, evaluates under CTFE, represents cycles without a closure, and gives schema emitters the named node they need to emit a JSON Schema `$ref` instead of inlining forever.

### `Record` = product of lenses, `Enum` = sum of prisms

```scala
sealed trait Record[R] extends Schema[R] {
  val fields: Chunk[Field[R, _]]
  lazy val nonTransientFields: Chunk[Field[R, _]]
  val rejectExtraFields: Boolean
  def construct(fieldValues: Chunk[Any])(implicit unsafe: Unsafe): Either[String, R]
  def deconstruct(value: R)(implicit unsafe: Unsafe): Chunk[Option[Any]]
  def id: TypeId
}

sealed trait Field[R, A] {
  def name: Field
  def schema: Schema[A]
  def annotations: Chunk[Any]
  def validation: Validation[A]
  def get: R => A                       // the lens getter
  def set: (R, A) => R                  // the lens setter
  lazy val defaultValue: Option[A]
  val optional: Boolean
  val transient: Boolean
  val aliases: Set[String]              // decode-time alternates
}
```

`Field.get`/`Field.set` is a **lens pair carried per field, and that is what makes the schema bidirectional** — not a separate encoder value. `construct`/`deconstruct` is the same pair lifted to the record. Sums mirror it exactly:

```scala
sealed case class Case[R, A](
  id: String, schema: Schema[A],
  private val unsafeDeconstruct: R => A,
  construct: A => R,
  isCase: R => Boolean,
  annotations: Chunk[Any])
```

`Case` is a **prism** — a total constructor, a partial matcher, a destructor. Record = product of lenses, Enum = sum of prisms is the entire structural vocabulary of the library, and it is precisely the vocabulary D gets from `.tupleof` (lenses, free, in field order that cannot desync from the declaration) plus a `SumType` tag switch (prisms, generated). The same shape is independently rediscovered by Haskell's `BiMap`/`prism` — see [the invertible-syntax lineage][invertible].

### `DynamicValue` — the format-neutral intermediate

`toDynamic`/`fromDynamic` route every value through one untyped intermediate. It is genuinely not a JSON DOM ([`DynamicValue.scala`][dynamic-src]):

```scala
final case class Record(id: TypeId, values: ListMap[String, DynamicValue])
final case class Enumeration(id: TypeId, value: (String, DynamicValue))
final case class Sequence(values: Chunk[DynamicValue])
final case class Dictionary(entries: Chunk[(DynamicValue, DynamicValue)])
sealed  case class Primitive[A](value: A, standardType: StandardType[A])
final case class SomeValue(value: DynamicValue)
case object NoneValue
final case class LeftValue(value: DynamicValue)
final case class RightValue(value: DynamicValue)
final case class DynamicAst(ast: MetaSchema)          // a schema, as a value, inside a value
final case class Error(message: String)
```

The docs describe it as _"a way to describe the entire universe of possibilities for schema values… The structure of the data is baked into the data itself."_ ([Dynamic Data Representation][dynamic-doc])

Four concrete differences from aeson's `Value` or circe's `Json`:

1. **`Primitive[A](value, standardType)` carries the type witness alongside the value.** A JSON DOM's `Number` has already lost whether it was an `Int32`, a `Double`, or a `Duration`. `DynamicValue` has not — which is what makes it a legitimate intermediate for **binary** formats (protobuf field types, Avro schemas) and not only for JSON.
2. **`Record` carries a `TypeId` and `Enumeration` carries the case name.** Nominal identity survives the round trip, so a `DynamicValue` can be re-typed into a _different_ Scala type of the same shape without re-reading wire bytes.
3. **`DynamicAst(ast: MetaSchema)` embeds a schema as data inside a value.** Self-describing payloads — Avro's "schema in the header" trick — become expressible in the ordinary value language.
4. **`Error(message)` is a value, not a failure.** A partially broken dynamic value can be carried, migrated, and inspected rather than aborting the pipeline. This is the tier-3 analogue of error accumulation.

`Schema.Dynamic` closes the loop: because `Schema[DynamicValue]` exists, an ordinary case class can have a field typed `DynamicValue` — a **typed escape hatch for the subtree you deliberately do not model**. And because `DynamicValue.Record` retains _every_ key it was handed, the `toDynamic → transform → toTypedValue` pipeline preserves fields the target type never declares, right up to the final typing step. This is the only principled unknown-data answer in the survey; every other library either rejects unknown keys or silently drops them (see the [comparison][comparison]).

**D verdict: [(b)][tags] for the model, [(a)][tags] for the escape hatch — and this is the single highest-value thing to build.** A `SchemaNode` sum over `{primitive, record, sum, sequence, map, optional, transform, ref}` in a flat arena, produced in CTFE from `__traits(getAttributes)` plus `.tupleof`, is mechanical work with no research risk; everything in the rest of this page is then a walk over it. The lens half is free (`__traits(getMember, value, name)`), the prism half is a generated tag switch, and `Lazy` becomes an arena index. The cheap win to take first is the escape hatch: an `@extra DynValue[string] rest;` field that generated decoders fill with unmatched keys and encoders splice back costs one `static foreach` branch and beats every tier-1 and tier-2 library on unknown-field round-tripping.

---

## Naming, optionality & defaults

All of it is annotation-driven, and the annotations survive into the reified value ([`zio.schema.annotation`][annotation-src]):

| Annotation                        | Semantics                                                      | D mapping                                      |
| --------------------------------- | -------------------------------------------------------------- | ---------------------------------------------- |
| `@fieldName("user_name")`         | wire rename for one field                                      | UDA — [(a)][tags]                              |
| `@fieldNameAliases("uid", "_id")` | **read many, write one** — decode-time alternates              | UDA — [(a)][tags]                              |
| `@fieldDefaultValue(v)`           | value used when the key is absent                              | UDA, or just a field initializer — [(a)][tags] |
| `@optionalField`                  | absence is legal and yields `None`                             | `Nullable!T` — [(a)][tags]                     |
| `@transientField`                 | "make no effort to encode"; excluded from `nonTransientFields` | UDA — [(a)][tags]                              |
| `@rejectExtraFields`              | strict decoding for this record                                | UDA — [(a)][tags]                              |
| `@recordName` / `@caseName`       | rename the type / the sum case on the wire                     | UDA — [(a)][tags]                              |
| `@description("…")`               | doc string that feeds schema emission                          | UDA, or `__traits(docComment)` — [(a)][tags]   |
| `@validate(…)`                    | validation attached at the declaration                         | UDA — [(a)][tags]                              |

The `aliases` field on `Field` deserves calling out: a field can be **read** under several wire names but is always **written** under one. That asymmetry is a real feature — legacy key migration without a version bump — and one that a symmetric `Iso`-based design cannot express at all.

Note what zio-schema does _not_ separate: `@optionalField` and `@fieldDefaultValue` are independent flags rather than a designed matrix, and there is no per-field policy for "omit on write when equal to the default" or for whether an explicit JSON `null` counts as absence. Those distinctions are handled — when they are handled — inside each format's codec rather than in the schema. The libraries that got this right enumerate a 3×2 matrix ({required, optional, defaulted} × {null-is-absent, null-is-a-value}); [ATD's `?`/`~` trichotomy][ocaml] is the two-character version and [autodocodec's four optionality constructors][haskell] the exhaustive one.

**D verdict: [(a)][tags] across the board, and one item to get right that zio-schema did not.** Every row above is a UDA read in CTFE, and `@fieldDefaultValue` is _easier_ in D than in Scala — a struct field initializer is directly readable as `T.init.field`, where Scala needs a macro to recover default arguments. The thing to design rather than copy is the optionality matrix, which belongs in the schema layer, not in each backend.

---

## Sum types & discrimination

```scala
sealed trait Enum[Z] extends Schema[Z] {
  def cases: Chunk[Case[Z, _]]
  def caseOf(id: String): Option[Case[Z, _]]
  val discriminatorName: Option[String]
  val noDiscriminator: Boolean
}
```

The discrimination strategy is data on the schema node, chosen by annotation rather than hardcoded by the codec:

- `@discriminatorName("type")` — internally tagged: the case name is written as a field inside the case's own object.
- `@noDiscriminator` — untagged: encode the payload bare, decode by trying cases in order.
- `@caseName` / `@caseNameAliases` — rename cases, and accept legacy spellings on read.
- `@simpleEnum` — a sum whose cases all have zero fields collapses to a bare string.
- `@transientCase` — a case that is never encoded.
- `Fallback[A, B](left, right, fullDecode)` — a distinct ADT case from `Either`: try the left schema, fall back to the right, and with `fullDecode` retain **both** results when both parse.

Untagged decoding is the interesting hazard, and zio-schema takes the same position every untagged design does: cases are tried in declaration order and the first success wins. Nothing checks that the cases are mutually distinguishable. Neither aeson nor circe nor autodocodec can check it either — the best of them ([autodocodec's joint/disjoint `Union` tag][haskell]) merely makes the author _state_ whether the branches overlap so the emitted JSON Schema can say `oneOf` instead of `anyOf`.

Note also the intrinsic asymmetry every discriminated-union implementation has: **encoding is a fold** (given the value, find its case and write it) while **decoding is a dispatch** (given the tag, select the branch). `Case.isCase` supplies the fold side; `caseOf(id)` supplies the dispatch side.

**D verdict: [(b)][tags], with a capability no surveyed library has.** The tag switch is CTFE-generated from the `SumType` member list, and the discrimination strategy becomes a policy UDA exactly as it is here. The bonus is that for untagged sums D can **`static assert` disjointness**: compare the branches' key sets in CTFE and fail the build when two branches are ambiguous. aeson can only warn in prose; autodocodec can only ask the author to assert it; `wired` can prove it.

---

## Transformations & validation

### `Transform` and validation

`transform(f, g)` and `transformOrFail(f, g)` wrap a schema in an isomorphism (total, or fallible in both directions) — the standard newtype/smart-constructor lever, and the only place user code enters the schema. `validate` runs a `Validation[A]` attached at declaration and returns `Chunk[ValidationError]`, i.e. **validation accumulates** even though decoding does not. `defaultValue: Either[String, A]` derives a canonical zero value from the structure, and `ordering: Ordering[A]` a structural comparison — both being folds over a schema nobody had to hand-write.

### The migration algebra — the rarest capability in the survey

`Schema.migrate` is the user-facing door, and its type is the design:

```scala
def migrate[B](newSchema: Schema[B]): Either[String, A => Either[String, B]]
```

**Two failure levels, and the split is the point.** The _outer_ `Either` fails when the two schemas are structurally irreconcilable — no migration exists at all. The _inner_ `Either` fails when a particular value cannot be carried across — a required field was added and this row has no source for it. That is exactly the distinction between "your types are incompatible" and "this record is incompatible", and no other library in the survey draws it.

Underneath is an algebra of steps ([`meta/Migration.scala`][migration-src]):

```scala
sealed trait Migration {
  def path: NodePath
  def migrate(value: DynamicValue): Either[String, DynamicValue]
}

final case class AddNode(path: NodePath, node: MetaSchema)              extends Migration
final case class DeleteNode(path: NodePath)                             extends Migration
final case class AddCase(path: NodePath, node: MetaSchema)              extends Migration
final case class Relabel(path: NodePath, tranform: LabelTransformation) extends Migration
final case class ChangeType(path: NodePath, value: StandardType[_])     extends Migration
final case class Require(path: NodePath)                                extends Migration
final case class Optional(path: NodePath)                               extends Migration
final case class IncrementDimensions(path: NodePath, n: Int)            extends Migration
final case class DecrementDimensions(path: NodePath, n: Int)            extends Migration
final case class UpdateFail(path: NodePath, message: String)            extends Migration
final case class Recursive(path: NodePath, relativeNodePath: NodePath,
                           relativeMigration: Migration)                extends Migration
```

and a derivation over two erased schemas:

```scala
def derive(from: MetaSchema, to: MetaSchema): Either[String, Chunk[Migration]]
```

`derive` walks both `MetaSchema`s from the root, comparing subtree shapes (products, tuples, sums, eithers, list nodes, dictionaries, value nodes, references) and emitting a step per mismatch. It runs the walk **twice** — once ignoring references, once resolving them — then dedupes; that two-pass structure is what keeps recursive types from diverging. The manual form composes steps directly:

```scala
case class Person1(name: String, age: Int)
case class Person2(name: String)

val migrations: Chunk[Migration] = Chunk(DeleteNode(NodePath.root / "age"))
val person2 = DeriveSchema.gen[Person1]
  .toDynamic(Person1("John Doe", 42))
  .transform(migrations)
  .flatMap(_.toTypedValue[Person2])
```

Four properties are worth stealing outright:

1. **Migrations are `DynamicValue → DynamicValue`, not `A → B`.** As the docs put it, _"By having `DynamicValue` which its type information embedded in the data itself, we can perform migrations of the data easily by applying a sequence of migration steps to the data."_ ([Schema Migration][migration-doc]) Because they operate on the untyped intermediate, an arbitrarily old schema version can be described as a `MetaSchema` value **without keeping a dead `Person1` class alive in the codebase**. That is the killer property, and it is available only to tier 3.
2. **Steps are addressed by `NodePath`, not field index**, so deep nested edits compose and survive reordering.
3. **Steps are themselves data** — serializable, storable, diffable, reversible; `Patch` even has a `SchemaMigration(migrations)` case whose `invert` reverses the chunk.
4. **`IncrementDimensions`/`DecrementDimensions` model `T` ⇄ `List[T]`** as a first-class step, and `Require`/`Optional` model the required/optional flip. Those are the two most common real-world schema changes after rename, and nothing else in the survey models either.

> [!NOTE]
> ATD's [`atddiff`][ocaml] is the nearest competitor and is a **linter, not an algebra**: it tells you a change is unsafe (`Required field 'id' is new`) but will not transform v1 data into v2. Against this, the whole ppx/ATD lineage is strictly weaker.

### Diffing and patching

```scala
sealed trait Patch[A] {
  def zip[B](that: Patch[B]): Patch[(A, B)]
  def patch(a: A): Either[String, A]
  def invert: Patch[A]
  def isIdentical: Boolean
  def isComparable: Boolean
}
```

Eighteen cases ([`Patch.scala`][patch-src]); the informative ones:

| Case              | Fields                                   | Note                                                            |
| ----------------- | ---------------------------------------- | --------------------------------------------------------------- |
| `Identical[A]`    | —                                        | the no-op                                                       |
| `Number[A]`       | `distance: A`                            | **numeric diffs are deltas, not replacements**; invert = negate |
| `Temporal[A]`     | `distances: List[Long], tpe`             | the same idea for dates and times                               |
| `LCS[A]`          | `edits: Chunk[Edit[A]]`                  | longest-common-subsequence over sequences                       |
| `Record[R]`       | `differences: ListMap[String, Patch[_]]` | per-field, recursive                                            |
| `Transform[A,B]`  | `patch, f, g`                            | diffs through a transform                                       |
| `Total[A]`        | `value: A`                               | wholesale replacement — the fallback                            |
| `NotComparable`   | —                                        | honest failure rather than a bad diff                           |
| `SchemaMigration` | `migrations: Chunk[Migration]`           | **a schema change is a kind of patch**                          |

Every case implements `invert`, which makes patches a groupoid: `patch.invert.patch(patch.patch(a)) == a`. Undo/redo, operational transform, and CRDT-adjacent machinery all fall out of the reified schema for free.

**D verdict: [(b)][tags] in CTFE, [(c)][tags] only at the edges.** The honest split:

- **The compatibility check comes first and is [(b)][tags].** Emit a schema digest per type at compile time, snapshot it as a golden file — the repo already has `SPARKLES_UPDATE_GOLDENS` machinery — and diff old against new in CI. That is `atddiff` for a fraction of the cost and captures most of the practical value.
- **`derive(v1, v2)` is [(b)][tags] whenever both schemas are known at compile time.** `enum v1 = schemaOf!PersonV1;` and `enum v2 = schemaOf!PersonV2;` are compile-time constants, so the derivation can run in CTFE and emit the migration chunk as a static array. "Value-level" does not have to mean "runtime": CTFE authors the values.
- **Only genuinely dynamic schemas are [(c)][tags]** — one read from a `.proto`, a database catalogue, or a stored `MetaSchema` — and those need a runtime `DynValue` interpreter.
- **Diff/patch is [(b)][tags] and cheap here.** `Number`-as-delta and `LCS` over sequences are the two choices to copy, and `sparkles:diff` already has an LCS/Myers engine with the right `@safe pure nothrow @nogc` discipline over a flat arena, so the sequence case is close to free.

---

## Errors & context

This is the thinnest dimension of the design, and the thinness is itself a finding.

Decoding is **fail-fast**: `fromDynamic` returns `Either[String, A]`, a bare string with no structural path, and `migrate` returns `Either[String, _]` at both levels. There is no accumulating decoder mode and no cursor-history equivalent of circe's `List[CursorOp]`. `Schema.Fail[A](message)` lets a schema be a guaranteed failure at a position, which is useful for marking an unimplemented branch but is not diagnostics.

The places context _does_ exist are revealing about where the library's attention was:

- **`validate` accumulates** — it returns `Chunk[ValidationError]`, not the first failure — because validation is a fold over the whole structure with no early exit.
- **`Migration` is `NodePath`-addressed**, so migration steps and their failures are positioned in the tree even though decode failures are not.
- **`DynamicValue.Error(message)` is a value**, so a broken subtree can travel through a pipeline instead of aborting it — error-as-data rather than error-as-control-flow.

The structural lesson the survey keeps returning to is that accumulation requires an applicative and any monadic bind in the chain silently destroys it, and that manually attached paths are paths eventually forgotten. Both hazards dissolve in a generated design: every branch always runs, and the path is a compile-time string emitted unconditionally. The best-in-class shape to aim at is [unjson's accumulated errors plus a usable partial value][invertible], not this.

**D verdict: [(a)][tags] to [(b)][tags], and an area where D should beat the subject rather than copy it.** Field paths are compile-time string constants that the generated walker emits with no author effort, accumulation is a `SmallBuffer!(Anchored, N)` rather than a monad transformer, and the "partial value" story is natural because the decoder writes into a `T` that already holds its initializers.

---

## Metadata, derivations & extensibility

**`annotations: Chunk[Any]` sits on every schema node and survives into the reified value.** That is what makes the annotation vocabulary open-world: a JSON backend written later, by someone else, can read an annotation the schema author wrote without the schema library ever having heard of that backend. The cost of `Any` is that annotations are untyped and unnamespaced, which is why the project has a [long-running issue][issue-203] about canonicalizing them.

D's `__traits(getAttributes)` has the same open-world property and is **typed**, which additionally kills the namespacing ambiguity that `ppx_deriving` documents at length — an OCaml plugin named `eq` must recognize all of `compare`, `skip`, `eq.compare`, `eq.skip`, `deriving.eq.compare` and `deriving.eq.skip`, and must then ignore any attribute in a different namespace (see [the OCaml deep-dive][ocaml]).

The payoff of the whole architecture is the interpreter list. Against the _same_ `Schema[A]`, zio-schema ships codecs for **JSON, Protobuf, Avro, Thrift, BSON, and MessagePack**, plus derived non-codec artifacts: `Eq`, `Show`, `Ordering`, `defaultValue`, `Gen[A]` property-test generators, and optics via `makeAccessors(b: AccessorBuilder)` — where the `Accessors` type member is what lets a single schema hand back lenses, prisms, and traversals in whatever optics library the caller supplies.

The slogan worth carrying into the `wired` design is: **with per-format codegen you decide at the declaration which formats a type supports; with a reified schema you decide at the use site, including in code written later.** OCaml's `refl` states the same thing from the other end of the ecosystem — see [OCaml ppx & ATD][ocaml].

**D verdict: [(b)][tags], and this is the argument for building a schema layer at all.** [`sparkles:wired`][baseline] already wants to be format-generic. Routing every backend through a CTFE `Schema` value — rather than through a fresh per-format `static foreach` over `T.tupleof` — means a new backend is a new schema walker, not a new introspection pass, and the annotations ride along untouched. The CLI-args backend ([argv codecs][argv]) is the proof that it works, because argv is the format least like JSON that `wired` has to serve.

---

## Strengths

- **Genuinely reified.** `Schema[A]` is a pattern-matchable ADT and `serializable: Schema[Schema[A]]` proves it; schemas can be shipped and reconstructed.
- **Structure/opacity separation.** Exactly one case (`Transform`) holds a function; every interpreter knows precisely where it is blind.
- **The only real migration story in the survey.** A `NodePath`-addressed, invertible, serializable step algebra over `DynamicValue`, with automatic `derive(from, to)` and a principled two-level failure type.
- **A type-carrying intermediate.** `DynamicValue.Primitive` keeps its `StandardType`, so binary formats ride the same intermediate as JSON.
- **The only principled unknown-data answer.** `Schema.Dynamic` as a typed escape hatch plus `Record` retaining every key it was given.
- **Free diff/patch as a groupoid**, with numeric deltas and LCS over sequences, and `SchemaMigration` unifying "the data changed" with "the type changed".
- **Six wire formats and a pile of non-codec derivations** from one declaration, decided at the use site.
- **An annotation vocabulary that a survey can steal wholesale** — it is, one-for-one, a UDA set.

## Weaknesses

- **Macro plus runtime construction.** `DeriveSchema.gen` is a macro, and what it produces is a heap graph built at class-initialization time — cost paid per type, per process, whether or not anything walks it.
- **`annotations: Chunk[Any]` is untyped and unnamespaced.** No compiler help against a typo'd or duplicated annotation; hence the canonicalization issue that is still open.
- **Decode errors are bare strings with no path.** No accumulating decoder, no cursor history; only validation accumulates.
- **The optionality matrix is underspecified at the schema level** — `optional` and `defaultValue` are separate flags, and omit-on-write and null-as-absence are left to individual codecs.
- **Untagged sums are try-in-order with nothing asserting disjointness**, and no analogue of a joint/disjoint declaration to make the ambiguity visible in emitted schemas.
- **Heavy conceptual surface.** `Schema`, `MetaSchema`, `DynamicValue`, `Patch`, `Migration`, `StandardType`, `AccessorBuilder` are six vocabularies to learn before the first byte is encoded.

## Key design decisions and trade-offs

| Decision                                                     | Rationale                                                                                 | Trade-off                                                                                                 |
| ------------------------------------------------------------ | ----------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| `Schema[A]` is a sealed ADT value, not a type class          | Every capability becomes an interpreter; new formats cost nothing at the declaration site | Schema construction is a runtime cost, and the macro that builds it is a Scala 2/3 maintenance burden     |
| Exactly one opaque case (`Transform`)                        | Keeps the rest of the tree walkable and `MetaSchema` serializable                         | Any user logic must be squeezed through an isomorphism; interpreters go blind at that node                |
| `Lazy[A]` thunk for recursion, `identity: I` for equality    | The only representations available to a heap-graph value language with opaque closures    | Allocation, no structural equality, `$ref` names recovered separately, and a workaround in the public ADT |
| `annotations: Chunk[Any]` on every node                      | Open world — a backend written later reads annotations the library never knew about       | Untyped, unnamespaced, unvalidated                                                                        |
| `DynamicValue` carries type witnesses (not a JSON DOM)       | Makes one intermediate serve JSON, protobuf, Avro, Thrift, BSON and MsgPack               | A heavier intermediate than a DOM, and materializing it costs on the hot path                             |
| Migrations act on `DynamicValue`, not on `A => B`            | Old versions need no live runtime type; steps stay data, addressable and invertible       | Migration is untyped in the middle; type errors surface only at the final `toTypedValue`                  |
| Two-level `Either` from `migrate`                            | Separates "schemas irreconcilable" from "this value cannot cross"                         | An awkward nested type for callers, and a `Left` that is still just a `String`                            |
| `Patch` with `invert` on every case, numeric diffs as deltas | Patches become a groupoid, so undo/redo and operational transform fall out for free       | 18 cases to maintain; deltas need a group structure, so everything else falls back to `Total`             |
| Fail-fast `Either[String, A]` for decoding                   | Simple, cheap, uniform with the rest of ZIO's error surface                               | No path, no accumulation — the weakest dimension of an otherwise thorough design                          |

---

## Sources

- [zio/zio-schema — GitHub repository][repo] · [introduction and motivation][docs] · [Operations index][ops-doc]
- [ZIO Schema — Dynamic Data Representation][dynamic-doc] · [Schema Migration][migration-doc] · [Diffing and Patching][diff-doc]
- [`zio/schema/Schema.scala` — the ADT, lenses/prisms, the operation surface][schema-src]
- [`zio/schema/DynamicValue.scala` — the type-carrying intermediate][dynamic-src]
- [`zio/schema/meta/Migration.scala` — the migration step algebra and `derive`][migration-src]
- [`zio/schema/Patch.scala` — the 18 patch cases and `invert`][patch-src]
- [`zio/schema/annotation/` — the annotation package][annotation-src] · [Scaladoc][javadoc] · [issue #203, canonicalizing annotations][issue-203]
- Related in this catalog: [concepts][tiers] · [comparison][comparison] · [`sparkles:wired` baseline][baseline] · [Effect Schema][effect] · [Rust serde][serde] · [facet][facet] · [Pydantic][pydantic] · [msgspec & cattrs][msgspec] · [circe & aeson][circe] · [Haskell codec libraries][haskell] · [OCaml ppx & ATD][ocaml] · [invertible syntax][invertible] · [argv codecs][argv]

<!-- References -->

[repo]: https://github.com/zio/zio-schema
[docs]: https://zio.dev/zio-schema/
[ops-doc]: https://zio.dev/zio-schema/operations/
[dynamic-doc]: https://zio.dev/zio-schema/operations/dynamic-data-representation
[migration-doc]: https://zio.dev/zio-schema/operations/schema-migration/
[diff-doc]: https://zio.dev/zio-schema/operations/diffing-and-patching
[schema-src]: https://github.com/zio/zio-schema/blob/ce7c788a25b2d68fbcb834898d4e545834d80eac/zio-schema/shared/src/main/scala/zio/schema/Schema.scala
[dynamic-src]: https://github.com/zio/zio-schema/blob/ce7c788a25b2d68fbcb834898d4e545834d80eac/zio-schema/shared/src/main/scala/zio/schema/DynamicValue.scala
[migration-src]: https://github.com/zio/zio-schema/blob/ce7c788a25b2d68fbcb834898d4e545834d80eac/zio-schema/shared/src/main/scala/zio/schema/meta/Migration.scala
[patch-src]: https://github.com/zio/zio-schema/blob/ce7c788a25b2d68fbcb834898d4e545834d80eac/zio-schema/shared/src/main/scala/zio/schema/Patch.scala
[annotation-src]: https://github.com/zio/zio-schema/tree/ce7c788a25b2d68fbcb834898d4e545834d80eac/zio-schema/shared/src/main/scala/zio/schema/annotation
[javadoc]: https://javadoc.io/static/dev.zio/zio-schema_3/0.4.13/zio/schema/annotation.html
[issue-203]: https://github.com/zio/zio-schema/issues/203
[tags]: ./concepts.md#d-feasibility-tags
[tiers]: ./concepts.md#the-three-tiers
[comparison]: ./comparison.md
[baseline]: ./wired-baseline.md
[effect]: ./effect-schema.md
[serde]: ./serde.md
[facet]: ./facet.md
[pydantic]: ./pydantic.md
[msgspec]: ./msgspec-cattrs.md
[circe]: ./circe-aeson.md
[haskell]: ./haskell-codecs.md
[ocaml]: ./ocaml-atd.md
[invertible]: ./invertible-syntax.md
[argv]: ./argv-codecs.md
