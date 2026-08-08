# Effect Schema (TypeScript)

A bidirectional schema library in which one value simultaneously denotes a decoded type, an encoded type, the transformation between them, and every artifact derivable from that pair — validator, JSON Schema, property-test generator, equivalence, optic, and JSON patch differ.

| Field                | Value                                                                                                                                                                                              |
| -------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language             | TypeScript (5.x, `strict`)                                                                                                                                                                         |
| License              | [MIT][license]                                                                                                                                                                                     |
| Repository           | [Effect-TS/effect-smol][repo]                                                                                                                                                                      |
| Documentation        | [`packages/effect/SCHEMA.md`][schema-md] (7272 lines) · [effect.website][website]                                                                                                                  |
| Category             | tier-2/3 hybrid — a [value-level codec over a reified AST][tiers]                                                                                                                                  |
| Version surveyed     | `effect@4.0.0-beta.98` — the v4 "smol" rewrite, at commit `3a1128c7` (2026-07-14)                                                                                                                  |
| Core modules         | `Schema.ts` (15120 ln), `SchemaAST.ts` (4001), `SchemaRepresentation.ts` (3907), `SchemaGetter.ts` (1876), `SchemaTransformation.ts` (1857), `SchemaIssue.ts` (1176), `SchemaParser.ts` (1113)     |
| Bidirectional?       | Yes — `encode(schema) = decode(flip(schema))`, one parser run in two directions                                                                                                                    |
| Reflection mechanism | None. TypeScript has no compile-time reflection, so the schema is an ordinary runtime object and its precision is carried by **15 type parameters** ([`SCHEMA.md` § Model / line 6690][schema-md]) |

> [!NOTE]
> `effect-smol` was the staging repository for Effect V4; it is now archived and read-only, with the full V4 history merged into the canonical [`Effect-TS/effect`][effect-repo]. Every citation here is pinned to the archived tree at `3a1128c7`, which is the revision this survey read. Line numbers refer to that revision.

> [!IMPORTANT]
> This deep-dive is written for the [`sparkles:wired`][wired-baseline] redesign, so each analysis section closes with a **D verdict** carrying an [(a)/(b)/(c) feasibility tag][tags]. Effect is the survey's most expressive data point by a wide margin; it is also the one whose architecture D should copy the least, and the verdicts say which is which.

---

## Overview

### What it solves

Effect Schema answers "what is the relationship between the data on the wire and the data in my program" with a **single value that knows both ends**. A `Schema.Codec` carries a decoded type `T` and an encoded type `E` as independent type parameters, so `Schema.FiniteFromString` is a first-class value with `Type = number` and `Encoded = string`, and a struct built from it has both object types derived structurally ([`SCHEMA.md` lines 374–392][schema-md]). From that one declaration Effect derives a decoder, an encoder, a JSON Schema document, a [fast-check][fast-check] arbitrary, an `Equivalence`, a pretty-formatter, an [optic][optic] `Iso`, an [RFC 6902][rfc6902] JSON-patch differ, and a [Standard Schema][standard-schema] interop object.

The reason it needs to be a _value_ rather than a type is the whole story: **TypeScript has no compile-time reflection.** There is no `__traits(allMembers)`, no way to walk an `interface` at compile time, and no way to read a decorator off a field generically. So the shape must be written a second time, as data, and then the type system is asked to prove that the data and the type agree. That proof is what the 15 type parameters buy.

### Design philosophy

The architecture is stated plainly in the reference doc ([`SCHEMA.md` § Model / lines 6688–6690][schema-md]):

> _"A 'schema' is a strongly typed wrapper around an untyped AST (abstract syntax tree) node. … The base interface is `Bottom`, which sits at the bottom of the schema type hierarchy. In Schema v4, the number of tracked type parameters has increased to 15, allowing for more precise and flexible schema definitions."_

Two further commitments shape v4 specifically. Transformations became standalone values — _"In previous versions, transformations were directly embedded in schemas. In the current version, they are defined as independent values that can be reused across schemas"_ ([`SCHEMA.md` § Transformations as First-Class / line 3002][schema-md]) — which collapsed several v3 AST node kinds into two uniform fields on every node. And error formatting is opt-in by construction: _"Hooks are **required**. There is a default implementation that can be overridden only for demo purposes. This design helps keep the bundle size smaller by avoiding unused message formatting logic"_ ([`SCHEMA.md` § Hooks / line 6356][schema-md]).

Within this survey Effect is the maximal point of the [three tiers][tiers]: everything [serde][serde] does with codegen and everything [zio-schema][zio-schema] does with a reified AST, plus a transformation algebra neither has. Compare it against the [D baseline][wired-baseline] and the [cross-subject synthesis][comparison].

---

## How it works

### `Type`, `Encoded`, and two service sets

`Bottom` ([`SCHEMA.md` lines 6693–6739][schema-md]) is the base interface every schema extends:

```ts
export interface Bottom<
  out T, // decoded type
  out E, // encoded type
  out RD, // services required to DECODE
  out RE, // services required to ENCODE
  out Ast extends AST.AST,
  out RebuildOut extends Top, // what .annotate()/.check() returns
  out TypeMakeIn = T, // input type of the .make() constructor
  out Iso = T, // focus of the derived Optic.Iso
  in out TypeParameters extends ReadonlyArray<Top> = readonly [],
  out TypeMake = TypeMakeIn,
  out TypeMutability extends Mutability = 'readonly',
  out TypeOptionality extends Optionality = 'required',
  out TypeConstructorDefault extends ConstructorDefault = 'no-default',
  out EncodedMutability extends Mutability = 'readonly',
  out EncodedOptionality extends Optionality = 'required',
>
  extends Pipeable.Pipeable {
  readonly ast: Ast;
  readonly Type: T;
  readonly Encoded: E;
  readonly '~type.optionality': TypeOptionality;
  readonly '~encoded.optionality': EncodedOptionality;
  // annotate / annotateKey / check / make …
}
```

Optionality and mutability are tracked **independently per side**, which is what lets a field be required after decoding but optional on the wire. The documented cost is that widening destroys the extra parameters: `Top`, `Schema`, and `Codec` are _"constraints only, never annotations or return types"_ — a `const s: Schema.Codec<number, string> = FiniteFromString` annotation resets the other eleven, silently widening `"~type.mutability"` from `"readonly"` to `"readonly" | "mutable"` ([`SCHEMA.md` lines 6801–6838][schema-md]).

### The reified AST

Every AST node extends `Base` (`SchemaAST.ts:606`) with exactly four fields:

| Field         | Type                           | Holds                                                        |
| ------------- | ------------------------------ | ------------------------------------------------------------ |
| `annotations` | `Annotations`                  | `identifier`, `title`, `toCodecJson`, `toArbitrary`, …       |
| `checks`      | `readonly [Check, ...Check[]]` | validation, in evaluation order                              |
| `encoding`    | `readonly [Link, ...Link[]]`   | the transformation chain (a **list**, so codecs stack)       |
| `context`     | `Context \| undefined`         | per-property metadata: optionality, mutability, key defaults |

There are 20 node tags (`SchemaAST.ts:54–74`) and — the load-bearing v4 change — **no `Transformation` or `Refinement` node kind**. v3 had both; v4 folded them into `encoding` and `checks` present on every node. That is why `.check(...)` no longer erases the schema type: it returns `this["Rebuild"]`, so a filtered `Schema.Struct` still exposes `.fields` and `.make` ([`SCHEMA.md` lines 2490–2527][schema-md]).

`Context` (`SchemaAST.ts:546`) is where a _field's_ metadata lives, separate from its _type's_:

```ts
export class Context {
  readonly isOptional: boolean;
  readonly isMutable: boolean;
  readonly defaultValue: Encoding | undefined; // withConstructorDefault
  readonly annotations: Annotations.Key<unknown> | undefined;
}
```

### `flip`: encoding is decoding with a reversed AST

The doc states the invariant directly ([`SCHEMA.md` § Flipping Schemas / How it works, lines 3489–3494][schema-md]):

> _"All internal operations in the Schema AST are symmetrical. Encoding with a schema is equivalent to decoding with its flipped version: `encode(schema) = decode(flip(schema))`."_

The implementation is six lines (`SchemaAST.ts:3477`):

```ts
export const flip = memoize((ast: AST): AST => {
  if (ast.encoding) return flipEncoding(ast, ast.encoding);
  const out: any = ast;
  return out.flip?.(flip) ?? out.recur?.(flip) ?? out;
});
```

`flipEncoding` (`SchemaAST.ts:3441`) reverses the `Link` chain and flips each `Transformation` (which merely swaps its two `Getter`s). Composite nodes implement `flip(recur)` to swap `checks` against `encodingChecks` — see `Union.flip` (`SchemaAST.ts:2687`) and the `encodingChecks` field on `Objects` (`:2041`), `Arrays` (`:1614`), `Union` (`:2628`). Everything else falls out: `toEncoded = toType ∘ flip` (`SchemaAST.ts:3438`), and `Schema.flip(s).make` is a constructor for **encoded** values ([`SCHEMA.md` lines 3498–3520][schema-md]).

### `Getter` and `Transformation` as ordinary values

```ts
Transformation<T, E, RD, RE>;
decode: Getter<T, E, RD>; // E -> T during decoding
encode: Getter<E, T, RE>; // T -> E during encoding
```

A `Getter` (`SchemaGetter.ts:64`) has signature `Option<E> -> Effect<Option<T>, Issue, R>`. The `Option` wrapper **on both sides** is the design's quiet masterstroke: `None` in means "key absent", `None` out means "omit this key". Optionality and transformation are therefore one mechanism, which is why `SchemaGetter.omit()` (`:605`) and `transformOptional` (`:574`) are ordinary getters rather than special cases in the struct parser.

The built-in getter vocabulary is unusually operational for a schema library, and much of it is argv-relevant: `snakeToCamel`, `camelToSnake`, `split`, `splitKeyValue`/`joinKeyValue`, `parseJson`/`stringifyJson`, `encodeBase64`/`Url`/`Hex`, `encodeUriComponent`, `decodeFormData`/`encodeFormData`, `decodeURLSearchParams`/`encodeURLSearchParams`, `withDefault`, `required`, `trim`, `capitalize`.

---

## Schema model & bidirectionality

One schema projects into four artifacts, all annotation- or AST-driven:

| Operation              | Result                                   | Mechanism                                                                          | Cite                                  |
| ---------------------- | ---------------------------------------- | ---------------------------------------------------------------------------------- | ------------------------------------- |
| `Schema.flip(s)`       | decode/encode swapped                    | reverse the `Link` chain, flip each transformation, swap `checks`/`encodingChecks` | `Schema.ts:2617`, `SchemaAST.ts:3477` |
| `Schema.toType(s)`     | schema of the decoded side only          | strip `encoding`, merge `encodingChecks` back into `checks`                        | `Schema.ts:2514`, `SchemaAST.ts:3394` |
| `Schema.toEncoded(s)`  | schema of the encoded side only          | `toType(flip(ast))`                                                                | `Schema.ts:2556`, `SchemaAST.ts:3438` |
| `Schema.toCodecIso(s)` | codec between `Type` and the `Iso` focus | annotation-driven walk                                                             | `Schema.ts:13549`                     |

`flip` is an involution — `flip(flip(s))` short-circuits through a `FlipTypeId` marker and returns the original (`Schema.ts:2617–2621`). `toType` is what replaced v3's `validate*` family: validating an already-decoded value is `decodeSync(toType(s))` ([`migration/schema.md` lines 161–173][migration]). The showcase is the Elysia integration ([`SCHEMA.md` lines 7185–7206][schema-md]): `flip(toCodecJson(schema)).annotate({ direction: "encoding" })` yields the response encoder while `mapJsonSchema` re-flips on that annotation — **one schema, four artifacts**: request validator, response encoder, request JSON Schema, response JSON Schema.

Crucially, Effect never claims `encode ∘ decode = id`, and enumerates where it breaks: decoding defaults (`{}` decodes to `{a: 1}` and encodes to `{a: "1"}`); `SchemaGetter.omit()` and `tagDefaultOmit`, which deliberately drop a field on encode; lossy `transform`s; `onExcessProperty: "ignore"` (the default) dropping unknown keys; record key collisions after a key transformation ([`SCHEMA.md` lines 1641–1654][schema-md]); and `anyOf` first-match, where encode may pick a different member's representation than decode saw.

**D verdict — [(b)][tags], and this is the one place D needs real machinery.** Encode and decode are two CTFE-generated functions over one UDA set, so the symmetry is _structural_: D never needs `flipEncoding`, `memoize`, or a `FlipTypeId`. What D lacks is the ability to **name** the encoded side. `typeof schema.Encoded` is a usable TypeScript type; in D the equivalent must be _synthesised_ — a mixin emitting `struct UserEncoded { string userId; string accountName; }` from `User` plus its UDAs. That is genuine CTFE work, though mostly optional: only a user who wants to name the wire struct needs it, since the codec functions themselves walk the domain type. `toType` (validate an already-decoded value) is [(a)][tags] — run the checks without the converters. Reifying `flip(s)` as a value to pass around is [(b)][tags] via a `Flip!Codec` wrapper, and only worth building for the Elysia-shaped use case. The genuinely new opportunity: D can `static assert` what Effect can only document — a `WireRoundTrippable!T` compile-time predicate rejecting types with decode-only defaults, omit-on-encode fields, or unmarked lossy converters. That matters most for the [argv codec][argv], where `encode(decode(argv)) == argv` is a natural property test.

---

## Naming, optionality & defaults

Key naming splits cleanly in two, and Effect keeps the distinction that matters: `Struct.renameKeys({ a: "A" })` renames the **field**, while `Schema.encodeKeys({ userId: "user_id" })` renames only the **encoded representation**, leaving the field alone ([`SCHEMA.md` lines 952–982][schema-md], `Schema.ts:3549`; flagged experimental). Record-level key transformations go through the key schema itself: `Record(String.pipe(decode(snakeToCamel())), Number)` turns `{ a_b: 1 }` into `{ aB: 1 }`, and — the subtle part — _"when a key schema has a transformation, dynamic property selection is based on the **encoded** property names"_ ([`SCHEMA.md` line 1626][schema-md]).

v4's real contribution is decomposing v3's `optionalWith(schema, { exact, nullable, default, as })` options bag into orthogonal primitives: `optionalKey` (key may be absent, `undefined` not allowed), `optional` (absent **or** explicitly `undefined`), `NullOr`, `mutableKey`, plus the inverses `requiredKey` and `required` ([`SCHEMA.md` lines 329–392][schema-md]). At the AST level all of it is one boolean, `Context.isOptional`, plus whether the type AST `containsUndefined` (`SchemaAST.ts:548`, `:3486`).

Defaults then split across **two independent channels**, which is the single most under-appreciated idea in the library:

- **Decoding defaults** — a four-member family crossed from two axes ([`SCHEMA.md` lines 458–467][schema-md]): `Key` means "fires on absence only" versus "absence or `undefined`", and `Type` means the default is given in _decoded_ form and **bypasses the decoding transformation**. So for `FiniteFromString`, `withDecodingDefault(succeed("1"))` supplies the string and decodes it, while `withDecodingDefaultType(succeed(1))` supplies the number directly. Defaults are `Effect`s, not values or thunks, and they nest.
- **Constructor defaults** — `withConstructorDefault(effect)` applies to `.make()`, not to decoding, and is stored in its own `Context.defaultValue` chain (`SchemaAST.ts:550`). It is **re-executed per call** ([`SCHEMA.md` lines 2899–2915][schema-md] demonstrates successive `make({})` producing different `Date`s), nests inner-first, and may read services via `Effect.serviceOption`.

The consolidated matrix has sixteen distinct semantics generated by five orthogonal axes — key present, value nullable, value undefined-able, default channel, and omit-on-encode. Condensed to the rows that carry distinct meaning:

| Encoded shape        | Decoded shape                     | How                                                                         |
| -------------------- | --------------------------------- | --------------------------------------------------------------------------- |
| `a: E`               | `a: T`                            | plain field                                                                 |
| `a?: E`              | `a?: T`                           | `optionalKey`                                                               |
| `a?: E \| undefined` | `a?: T \| undefined`              | `optional` (`NullOr` adds the `null` variants of both rows)                 |
| `a?: E`              | `a: T`                            | `withDecodingDefaultKey` (the `\| undefined` variant is the non-`Key` form) |
| `a?: E`              | `a: T`, default bypasses decoding | `withDecodingDefaultTypeKey`                                                |
| `a: E`               | `a: T`, omittable in `.make()`    | `withConstructorDefault`                                                    |
| `a?: E`              | `a: Option<T>`                    | `OptionFromOptionalKey` (plus `OptionFromOptional`, `…NullOr`)              |
| `a?: E`              | `a: T`, **omitted on encode**     | `encodeTo(optionalKey(...), { decode: withDefault, encode: omit() })`       |
| `a?: E \| null`      | `a: T`                            | manual `transformOptional` + `Option.filter` + `orElseSome`                 |
| `a?: E`              | `a?: T`, `undefined` dropped      | `transformOptional(Option.filter(isNotUndefined))`                          |

Encode-side omission has three distinct spellings: `SchemaGetter.omit()` (requires the encoded side be `optionalKey`, else `MissingKey`), the packaged `Schema.tagDefaultOmit(literal)` for discriminators (`Schema.ts:6010`), and returning `Option.none()` from a `transformOptional` encode.

**D verdict — [(a)][tags] for the matrix, [(b)][tags] for presence-carrying converters.** The `undefined` axis has no D analogue and should be dropped outright: it exists only because JSON-in-JavaScript conflates absent and undefined. That collapses sixteen rows to roughly nine, and the remainder are plain UDAs — `@WireOptional`, `@WireDefault!(value)`, `@WireDefault!(fn)`, `@WireNullable`, `@WireOmitOnEncode`. The idea wired must import deliberately is the **decoding-default versus constructor-default split**, because for a CLI they are different defaults with different timing: "the flag was not passed, use this" versus "the programmer omitted this field when building the struct to render as argv". Conflate them and `encode(decode(argv))` emits flags the user never typed. Effect-valued defaults (lazily re-evaluated, possibly service-reading) are [(c)][tags] in general but [(b)][tags] for the useful subset — a `pure` function evaluated at decode time. The one structural consequence: wired's converter signature should be `Nullable!Wire -> Expected!(Nullable!Domain, Issue)` rather than `Wire -> Domain`, mirroring Effect's `Option`-on-both-sides `Getter`. Without presence in the signature, "omit on encode" and "default on absence" cannot be expressed by a converter at all and need bespoke UDAs for each case.

---

## Sum types & discrimination

`Schema.Union([A, B])` defaults to `mode: "anyOf"` — inclusive, members tried in order, first match wins ([`SCHEMA.md` lines 1797–1799][schema-md]) — with `mode: "oneOf"` demanding that exactly one member match, backed by a dedicated `OneOf` issue node (`SchemaIssue.ts:708`). On top sit `Schema.Literals`, `Schema.TaggedStruct("A", …)` (sugar for a `Schema.tag` literal field whose constructor default lets `.make` omit it), `Schema.TaggedUnion({ A: …, B: … })`, and `Schema.toTaggedUnion("type")` / `asTaggedUnion`, which **augment an existing union** with `.cases`, `.guards`, `.isAnyOf([…])`, and an exhaustive `.match({ … })`. The augmentation form is the interesting one: it changes nothing about the original schema, works on third-party schemas, lets you pick among several candidate tag fields, and handles unions containing nested unions ([`SCHEMA.md` lines 2018–2081][schema-md]).

The mechanism underneath is the most instructive implementation detail in the library: **discrimination is inferred, never declared.** A `Sentinel` (`SchemaAST.ts:2420`) is a `{ key, literal }` pair, and `collectSentinels` (`:2470`) harvests them automatically — any non-optional literal-typed property of an `Objects` node, any non-optional literal element of an `Arrays` node at its index, or an explicit `~sentinels` annotation on a `Declaration`. `getCandidates` (`:2567`) then builds an index mapping `(key, literalValue)` to a member set:

```ts
export function getCandidates(input, types) {
  const idx = getIndex(types);
  const runtimeType =
    input === null ? 'null' : Array.isArray(input) ? 'array' : typeof input;

  if (idx.bySentinel) {
    // 1. sentinel dispatch (most selective)
    const base = idx.otherwise?.[runtimeType] ?? [];
    if (runtimeType === 'object' || runtimeType === 'array') {
      const selected = new Set(base);
      for (const [k, m] of idx.bySentinel) {
        if (Object.hasOwn(input, k)) {
          const match = m.get(input[k]);
          if (match) for (const c of match) selected.add(c);
        }
      }
      return [...selected]
        .sort()
        .map(i => types[i])
        .filter(filterLiterals(input));
    }
    return base.map(i => types[i]);
  }
  return (idx.byType?.[runtimeType] ?? [])
    .map(i => types[i])
    .filter(filterLiterals(input)); // 2. typeof fallback
}
```

Several fields can act as sentinels at once; non-object inputs fall back to a `typeof`-keyed index; surviving candidates are tried in order and their issues accumulate into an `AnyOf` issue (`SchemaIssue.ts:650`). The payoff is error quality: excluding incompatible members means `Union([NonEmptyString, Number])` on `""` reports the _length_ failure rather than a union soup, and `Literals(["a","b"])` on `null` reports one `Expected "a" | "b", got null` instead of two per-literal errors ([`SCHEMA.md` lines 1801–1840][schema-md]).

**D verdict — [(a)][tags] for tagged unions, [(b)][tags] for sentinel inference.** A D tagged union plus `@WireTag!("kind")` dispatches through a compile-time `final switch` — no index build, no `Set`, no sort, no allocation. All of `getCandidates` exists because Effect must discover the discriminator at runtime; D knows it at compile time. The idea genuinely worth stealing is **automatic sentinel inference**: a CTFE scan of each member's fields for `enum`-typed or literal-constrained members, building the dispatch table without an annotation — which makes `@WireTag` optional rather than mandatory, and handles the multi-key case for free. Untagged try-in-order unions are [(b)][tags] and require a design commitment: each member's decoder must be side-effect-free until commit, so the output struct is never mutated before a member wins. `mode: "oneOf"` is [(a)][tags] — run all candidates and count successes — and it is precisely **mutually-exclusive option groups** for a CLI, just as sentinel dispatch is precisely **subcommands**. Runtime-type prefiltering is irrelevant in D, where the wire token type is statically known per format.

---

## Transformations & validation

The v4 rewrite made transformations reusable standalone values; the reference implementation of `trim` is two lines ([`SCHEMA.md` lines 3066–3074][schema-md]):

```ts
export function trim(): Transformation<string, string> {
  return new Transformation(Getter.trim(), Getter.passthrough());
}
```

Four verbs apply one: `decodeTo(target, transformation?)`, `encodeTo(target, …)`, `decode(transformation)`, `encode(transformation)`. `decodeTo` **with no transformation is schema composition** — `MilesFromMeters = KilometersFromMeters.pipe(decodeTo(MilesFromKilometers))` ([`SCHEMA.md` lines 3212–3240][schema-md]) — and transformations also compose directly with `.compose`, running both decodes forward and both encodes in reverse. Because `encoding` is a non-empty _list_ of `Link`s, chains stack: `StringFromBase64.pipe(decodeTo(fromJsonString(schema)))` is a base64 → JSON → struct pipeline in one field ([`SCHEMA.md` line 4541][schema-md]). Directionality of loss is declared at the type level by the passthrough family — `passthrough` (exact), `passthroughSubtype`, `passthroughSupertype`, and `passthrough({ strict: false })` when no relation holds ([`SCHEMA.md` lines 3244–3324][schema-md]) — while `transform` is total both ways and `transformOrFail` lets one direction be partial.

Validation moved from v3's overloaded `filter` to three intent-separated forms: `check(makeFilter(pred))`, `refine(typeGuard)`, and an effectful `SchemaGetter.checkEffect` ([`migration/schema.md` lines 51–75][migration]); all built-in filters gained an `is` prefix (`isMinLength`, `isPattern`, `isBetween`, `isMultipleOf`, `isUnique`, …). Five properties define its expressiveness:

1. **`FilterOutput` is a rich return protocol** ([`SCHEMA.md` lines 2438–2447][schema-md]): `undefined`/`true` succeeds; `false` fails generically; a `string` supplies the message; a `SchemaIssue.Issue` is the escape hatch; a `{ path, issue }` record **attaches the failure to a nested path** (this is what makes password/confirm-password validation report against the right field); an array reports several failures at once.
2. **Checks are shape-polymorphic values.** The same `isMinLength(3)` applies to a string, an array, and `Struct({ length: Number })` — it is structural on `.length` ([`SCHEMA.md` lines 2549–2571][schema-md]).
3. **`.abort()`** short-circuits remaining checks even under `errors: "all"`, and **structural filters** run in a separate pass so an array reports both "element 1 is empty" and "needs at least 3 items" ([`SCHEMA.md` lines 2597–2702][schema-md]).
4. **Checks survive encoding.** They live in two slots, `checks` and `encodingChecks`, which `flip` swaps — so a refinement is enforced in whichever direction _produces_ the refined value, and `toType` merges them back. `String.check(isMinLength(3)).pipe(decodeTo(…))` validates the string on decode-input and on encode-output without writing it twice.
5. **Filter factories** parameterise a whole family by an `Order`: the BigInt numeric filters are generated from `Order.BigInt` ([`SCHEMA.md` lines 209–243][schema-md]).

Two adjacent features round it out. `Schema.brand("UserId")` accumulates into a `brands` annotation and type-level-intersects a `Brand`; its constructor rule is context-sensitive — at the top level `make` accepts unbranded input, but nested in a struct it demands already-branded values ([`SCHEMA.md` lines 2807–2840][schema-md]). And `Schema.TemplateLiteralParser` goes beyond matching: `TemplateLiteralParser([String.check(isMinLength(2)), ":", Int])` has `Type = readonly [string, ":", number]` and decodes `"aa:1"` into `["aa", ":", 1]` with per-element error indices ([`SCHEMA.md` lines 289–317][schema-md]). Matching is semantic rather than regex-only: _"checks on string, number, and bigint schema parts are applied while matching each segment"_ ([`SCHEMA.md` line 255][schema-md]).

**D verdict — [(a)][tags] for the core, [(b)][tags] for chains and template parsing.** A `@WireConvert!(toWire, fromWire)` pair is strictly simpler than `pipe(decodeTo(T, Transformation.transformOrFail({ decode, encode })))`, and a D function is already a reusable named value — no `Getter` object, no allocation. Fallible conversions return `Expected!(T, WireIssue)`, [the house idiom][expected]. `passthroughSubtype`/`Supertype` become template constraints (`if (is(From : To))`) with better diagnostics. `FilterOutput`'s rich protocol maps onto a `SumType` over `{path, message}` and issue arrays. Shape-polymorphic checks become a template constrained on `hasLength!T` — textbook [Design by Introspection][dbi] and _more_ precise than the TypeScript version, because the constraint is actually checked rather than duck-typed. Brands are [(a)][tags] and far better: nominal typing is native to D, and the context-sensitive constructor rule is an artifact of TypeScript's structural typing that simply does not arise. Chained converters are [(b)][tags] — stack multiple `@WireConvert` UDAs and fold them at CTFE — and worth designing for explicitly, since the base64-then-JSON composition is genuinely useful. `.abort()` and the structural-versus-item ordering need a per-check marker plus a two-phase walk in the generated validator: cheap, [(b)][tags]. **`TemplateLiteralParser` is where D decisively wins**: a CTFE function taking `"{name}:{port:int}"` and populating a user struct is well-trodden D practice (cf. `std.format`'s compile-time checking), whereas TypeScript needs fragile variadic conditional types. It is also directly the answer for structured option values like `--addr host:port`.

---

## Errors & context

`SchemaIssue.Issue` (`SchemaIssue.ts:109`) is a discriminated union with six leaves — `InvalidType` (wrong shape), `InvalidValue` (right shape, wrong value), `MissingKey`, `UnexpectedKey`, `Forbidden`, `OneOf` — and five composites: `Pointer{path, issue}` attaching a path segment, `Composite` for several issues at one node, `AnyOf` carrying every failed union member's issue, `Filter{actual, filter, issue}` carrying the _AST filter node_ itself, and `Encoding` for a failed transformation step. Every issue's `toString()` delegates to the default formatter, so `String(issue)` is readable without ceremony.

Accumulation is a parse option, not a schema property: `ParseOptions.errors: "first" | "all"` (default `"first"`), alongside `onExcessProperty: "ignore" | "error" | "preserve"` — where `"preserve"` **keeps unknown keys in the output** ([`SCHEMA.md` lines 870–888][schema-md]) — plus `propertyOrder`, `disableChecks`, and `concurrency` (`SchemaAST.ts:458–520`).

Formatting is hook-driven by deliberate design (the bundle-size quote above). There are two hook kinds, `LeafHook = (issue: Leaf) => string` and `CheckHook = (issue: Filter) => string | undefined`, and the i18n example switches on `issue._tag` and, for checks, on `issue.filter.annotations?.meta._tag` ([`SCHEMA.md` lines 6456–6521][schema-md]). That makes **`meta` the stable machine-readable identity of a built-in check** — translation without string matching. Message precedence is specified rather than emergent: a type-level failure uses the schema's `identifier` as the expected label; a filter failure uses the filter's `message`, then `expected`, then a literal placeholder; and _"an `identifier` does not name a failed filter"_ ([`SCHEMA.md` lines 2409–2422][schema-md]). Per-site annotations beat hooks. The failure result itself has a schema (`Schema.StandardSchemaV1FailureResult`), so it can be sent over the wire.

Context is the other half. v4 split v3's single `R` into `RD` (decoding services) and `RE` (encoding services), tracked structurally — a struct's `RD` is the union of its fields' ([`SCHEMA.md` lines 6918–6933][schema-md]):

```ts
declare const User: Schema.Codec<
  { id: string; name: string },
  string,
  UserDatabase,
  never
>;

Schema.decodeEffect(User)('user-123'); // Effect<…, SchemaError, UserDatabase>
Schema.encodeEffect(User)({ id: 'user-123', name: 'John' }); // Effect<string, SchemaError, never>
```

Services enter through effectful filters (`.check(...)` filters are documented as **necessarily synchronous**, `SCHEMA.md:2706`), effectful transformations, effectful constructor defaults, and middleware — where `Schema.middlewareDecoding(Effect.provideService(…))` **discharges** a requirement, moving `RD` back to `never` ([`SCHEMA.md` lines 6644–6680][schema-md]).

**D verdict — [(a)][tags]/[(b)][tags] for errors, [(c)][tags] for the effect system.** The issue tree is a D `SumType` with a `SmallBuffer!(PathSegment, N)` path, and `Expected!(T, WireIssue)` is [already the house idiom][expected]. Accumulating under `errors: "all"` in `@nogc` code is [(b)][tags]: it needs a caller-supplied issue sink (an output range) rather than an allocated array, which is the natural sparkles shape anyway. Formatter hooks are [(a)][tags] and **strictly better** — the check's _type_ is its identity, so `isMinLength!3` is a distinct type carrying its parameter and a formatter pattern-matches it with `static if` instead of reading an untyped `meta` record. The design lesson worth importing wholesale is Effect's bundle-size argument turned into a compile-time one: make the formatter a template parameter defaulting to `void`, so a binary that never formats an error instantiates no formatting code at all — better than tree-shaking, because nothing is emitted to shake. Threading a caller-supplied context is [(b)][tags] via the familiar DbI hook shape (`walkGitRepository`'s hook, `PrettyPrintOptions!Hook`), and **separate decode-context and encode-context types are free in D**: two generated functions, two context parameters, each inferred by the CTFE walk exactly as Effect computes `RD` at the type level — and D can produce a tuple type rather than a union. Async decoding is [(c)][tags] and the recommendation is to refuse it: every leaf parser returning `Effect<Option<T>, Issue, R>` costs allocation and indirection on every field of every decode, to serve a feature almost no schema uses. Keep wired's core synchronous, and make async an opt-in escape hatch on individual converters via [`sparkles:event-horizon`][event-horizon]'s `Effect!T` tier.

---

## Metadata, derivations & extensibility

Annotations are a layered, typed vocabulary (`Schema.ts:14304–14545`). `Augment` applies to every node and maps onto JSON Schema fields (`expected`, `title`, `description`, `documentation`, `readOnly`, `writeOnly`, `format`, `contentEncoding`, `contentMediaType`). `Documentation<T>` adds `default` and `examples` **typed by the schema's own `T`**. `Key<T>` is attached with `annotateKey` and applies to a field's _position_ rather than its type. `Bottom` adds `message`, `identifier`, `meta`, `brands`, and `parseOptions`. `Declaration` adds the derivation hooks. Users extend the vocabulary by TypeScript declaration merging ([`SCHEMA.md` lines 6868–6895][schema-md]), and resolution has a specified precedence: _"if the schema has checks, the annotations are taken from the last check; otherwise from the base schema instance"_ ([`SCHEMA.md` lines 6840–6842][schema-md]).

Annotations exist to feed derivations, and the mapping is the library's real product:

| Derivation              | Entry point                                              | Annotations consumed                                                                                                                                |
| ----------------------- | -------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| JSON Schema (2020-12)   | `Schema.toJsonSchemaDocument` (`:13426`)                 | `title`, `description`, `default`, `examples`, `format`, `identifier` (as `$ref` names), check `meta` (as `minLength`, `pattern`, …), `toCodecJson` |
| Arbitrary (fast-check)  | `Schema.toArbitrary` (`:13079`)                          | `toArbitrary`, filter `arbitrary.constraint`, filter `arbitrary.candidate`                                                                          |
| Equivalence             | `Schema.toEquivalence` (`:13309`)                        | `toEquivalence`                                                                                                                                     |
| Optic / `Iso`           | `Schema.toIso` (`:13970`)                                | `toCodecIso`, the `Iso` type parameter                                                                                                              |
| JSON Patch differ       | `Schema.toDifferJsonPatch` (`:14069`)                    | (built on the JSON codec)                                                                                                                           |
| Canonical codecs        | `toCodecJson` (`:13478`), `toCodecStringTree` (`:13627`) | `toCodecJson`, `toCodec`, `toCodecStringTree`                                                                                                       |
| Portable repr / codegen | `SchemaRepresentation.fromAST`                           | JSON-primitive annotations only; `generation`                                                                                                       |
| Standard Schema interop | `Schema.toStandardSchemaV1` (`:1156`)                    | the `message*` family                                                                                                                               |

**The Arbitrary derivation is the most sophisticated and the most worth stealing.** Built-in checks _guide generation_ rather than only rejecting: `isMinLength`, `isPattern`, `isBetween`, `isInt`, `isUnique` feed the generator's construction so it does not rejection-sample, and `{ report: true }` returns warnings naming the filters that failed to guide ([`SCHEMA.md` lines 5581–5657][schema-md]). A custom filter attaches `arbitrary.constraint` from a fixed vocabulary (`minLength`/`maxLength`, `patterns`, `integer`, `noNaN`, `noInfinity`, `valid`, `unique`, `ordered`), or `arbitrary.candidate { weight, make }` — an _additional weighted generator source_ alongside the base one, still validated by all filters. Generic declarations receive **two** derivations per type parameter, `arbitrary` and `terminal`, the latter a finite generator that closes recursion.

The **canonical codec** system is the closest structural analogue to wired's `Format` marker. It is annotation-based, walks the AST to produce a new schema for the serialized form, and composes recursively ([`SCHEMA.md` lines 4771–4775][schema-md]). `toCodecJsonBase` (`Schema.ts:13478–13540`) shows three selection rules worth naming: an **annotation fallback chain** (`toCodecJson ?? toCodec` — format-specific overriding generic), **per-node-kind defaults** (`Number` has its own, `BigInt` falls back to the _StringTree_ strategy), and **graceful degradation to `null`** when a declared type has no representation. `applyToSelfOrLastLinkEncoding` makes explicit user encodings win: a field with an existing `encodeTo` keeps its custom epoch-millis encoding while a sibling gets the default ISO string. There are three canonical codecs — `toCodecJson` (JSON), `toCodecStringTree` (FormData, `URLSearchParams`, XML, **argv**), and `toCodecIso` — with `Schema.fromFormData` and `Schema.fromURLSearchParams` built on the second, both parsing bracket notation (`b[c]=2&b[d]=3`) into a nested tree before decoding. There is no registry and no dispatch: you choose by calling a different function, idiomatically packaged as a static member (`static readonly serializer = Schema.toCodecJson(this)`). The guarantee that matters is that **one annotation feeds both the runtime codec and the JSON Schema generator**, so the two cannot disagree.

Finally, projections. v4 removed the combinator zoo (`pick`, `omit`, `partial`, `extend`, `rename`) in favour of `mapFields` / `mapElements` / `mapMembers` over `Struct` and `Tuple` data modules: `mapFields(Struct.pick(["a"]))`, `mapFields(Struct.map(Schema.optionalKey))`, `mapFields(Struct.evolveKeys({ a: String.toUpperCase }))`, `mapElements(Tuple.renameIndices(["2","1","0"]))` (which _reorders_). `mapFields` **drops checks by default**, requiring `{ unsafePreserveChecks: true }` because _"the original refinement functions may no longer be valid or safe to apply to the transformed schema"_ ([`SCHEMA.md` lines 1109–1137][schema-md]). `keyof`, `pluck`, `withDefaults`, and `Data` were removed with no replacement.

**D verdict — [(a)][tags] for annotations, [(b)][tags] for derivations and projections.** UDAs _are_ typed annotations: open-world, user-extensible without declaration merging, readable at CTFE. D expresses Effect's `annotateKey`-versus-`annotate` distinction more naturally, since a UDA on a field is inherently key-level and one on the field's type is value-level — Effect needed a whole extra method. It also expresses `Filter.meta` better, because the check's type _is_ its machine identity. Two traps are worth importing as warnings rather than mechanisms: `annotateEncoded` exists because Effect never decided whether an annotation describes the domain field or the wire field, so wired should make that explicit up front (`@WireDoc` versus `@Doc`); and Effect's silent degradation — `toCodecJson` emitting `null` for an unrepresentable type, `mapFields` dropping checks — is exactly where D should `static assert` instead. **Constraint-guided arbitrary derivation is the highest-value item on this list**: [(b)][tags], and it would let `@Check!(isBetween!(1, 10))` hand `sparkles:test-runner`'s property generator its bounds at compile time, generating valid values by construction rather than by rejection; the `candidate { weight, make }` escape hatch and the recursion `terminal` generator are both directly portable. The projection algebra is the one axis where TypeScript is genuinely ahead and the honest tag is [(b)][tags]: a mapped type is one line and structurally compatible with everything, whereas D must mixin a generated struct and gets a _new nominal type_. The recommendation is not to chase it — `Pick`/`Omit`/`Partial`/`WithFields` as CTFE mixins is roughly 100 lines and covers 90% of real use. Two absences are themselves findings: `Schema.suspend` and the whole recursion apparatus **disappear in D**, because `struct Category { string name; Category[] children; }` just works and wired needs only a visited-type set in the CTFE walk; and `declareConstructor` disappears too, because `Box!T` is a template and instantiating it _is_ the parametric derivation, with the type-parameter codecs nameable directly in the body.

---

## Strengths

- **One declaration, many artifacts.** Validator, encoder, JSON Schema, arbitrary, equivalence, optic, and JSON-patch differ all derive from the same annotated AST, and cannot drift apart.
- **Genuinely bidirectional, with the asymmetries named.** `encode = decode ∘ flip` is an implementation fact, not an aspiration; the places where round-tripping fails are enumerated rather than hidden.
- **Transformations and checks as first-class composable values** — reusable, `.compose`-able, chainable as a list of `Link`s, and applicable across every node kind uniformly.
- **The optionality/default decomposition** is the most careful treatment in the survey: orthogonal primitives instead of an options bag, and decoding defaults kept separate from constructor defaults.
- **Inferred union discrimination** — any non-optional literal field becomes a sentinel, several at once, with a `typeof` fallback and a `oneOf` mode.
- **Errors designed for humans and machines**: a structured issue tree with paths, cross-field failures attachable to the right field, specified message precedence, and stable `meta` identities that make i18n possible without string matching.
- **Constraint-guided generation** — checks inform the property-test generator instead of merely rejecting its output.
- **Pay-for-what-you-use formatting**, with required hooks as a deliberate bundle-size decision.

## Weaknesses

- **15 type parameters** is the price of missing compile-time reflection, and it leaks: `Top`/`Schema`/`Codec` may be used as constraints only, because any annotation-position use silently widens the other parameters.
- **The shape is written twice** — once as a TypeScript type, once as a schema value — and the type system, not the compiler, holds them together.
- **Everything is `Effect`-valued**, so every leaf parser allocates through `Effect<Option<T>, Issue, R>` to serve async and service-dependent decoding that most schemas never use.
- **Runtime cost throughout**: AST allocation, `memoize` around `toType`/`toEncoded`/`flip`, a `Set`-and-sort candidate build per union decode.
- **Silent degradation** in two visible places: `toCodecJson` emits `null` for unrepresentable declared types, and `mapFields` drops checks unless explicitly told not to.
- **Stringly-typed annotation keys** with a hand-rolled fallback chain (`toCodecJson ?? toCodec`) instead of a compiler-checked resolution order.
- **`SchemaRepresentation` cannot represent transformations at all** — _"a transformation is user code (functions); JSON cannot store functions"_ — so the portable form loses custom predicates and non-JSON-primitive annotations.
- **Naming churn in v4**: variadic to array everywhere, `filter` to `check`, `*Either` to `*Exit`, `is` prefixes on every built-in filter, and a dropped `*FromSelf` suffix that **silently inverts several names**, most dangerously `Redacted` ([`migration/schema.md` lines 104–136][migration]).

## Key design decisions and trade-offs

| Decision                                                   | Rationale                                                                              | Trade-off                                                                                 |
| ---------------------------------------------------------- | -------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| Schema as a runtime value wrapping a reified AST           | TypeScript has no compile-time reflection; interpreters need something to walk         | Allocation and dispatch per decode; the shape is declared twice                           |
| 15 type parameters on `Bottom`                             | Recovers per-side optionality, mutability, make-input, and `Iso` focus at type level   | Widening destroys them, so the public types are constraints-only by documented rule       |
| `encode = decode ∘ flip`                                   | One parser, one code path, symmetry by construction                                    | Every node kind must implement `flip`/`recur`; `checks` needs a mirrored `encodingChecks` |
| `checks` and `encoding` as uniform fields on every node    | Killed the `Refinement`/`Transformation` node kinds; `.check()` stops erasing the type | Two check slots to keep in sync; filter applicability becomes structural, not checked     |
| `Getter` takes and returns `Option`                        | Key presence and value transformation become one mechanism                             | Every conversion pays an `Option` wrapper even when presence is irrelevant                |
| Everything returns `Effect`                                | Async, service-dependent, and fallible decoding are uniform                            | Allocation and indirection on every field; sync entry points must throw if async appears  |
| Split `R` into `RD` and `RE`                               | Decoding may need a database while encoding needs nothing                              | More type parameters; middleware needed to discharge a requirement                        |
| Sentinel discrimination inferred, not declared             | Works on third-party schemas, multiple keys, nested unions, without annotation         | An index build, a `Set`, and a sort per union decode                                      |
| Canonical codecs selected by annotation key                | One annotation feeds both the runtime codec and JSON Schema generation                 | A stringly-typed namespace with a hand-written fallback chain; `null` on degradation      |
| Formatter hooks required, default "for demo purposes only" | Message tables stay out of bundles that never format errors                            | Every real consumer must supply hooks before errors are readable                          |
| `mapFields` drops checks unless `unsafePreserveChecks`     | A refinement over removed fields may be unsound                                        | Silent loss in the common case where the check was still valid                            |

---

## Sources

- [Effect-TS/effect-smol — the archived V4 staging repository][repo] (development continues in [Effect-TS/effect][effect-repo])
- [`packages/effect/SCHEMA.md` — the 7272-line reference document read in full for this survey][schema-md]
- [`packages/effect/src/Schema.ts` — the public surface, annotations vocabulary, canonical codecs, derivations][schema-ts]
- [`packages/effect/src/SchemaAST.ts` — node kinds, `Base`/`Context`/`Link`, `flip`, sentinel collection and union candidate selection][ast]
- [`packages/effect/src/SchemaIssue.ts` — the issue tree and formatter hooks][issue]
- [`packages/effect/src/SchemaGetter.ts` — the `Getter` vocabulary][getter]
- [`packages/effect/src/SchemaTransformation.ts` — `Transformation` and its combinators][transformation]
- [`packages/effect/src/SchemaRepresentation.ts` — portable schema representation and code generation][representation]
- [`packages/effect/src/SchemaParser.ts` — the parse driver and `makeEffect`][parser]
- [`migration/schema.md` — the v3 to v4 delta, API renames, and removals][migration] · [`MIGRATION.md`][migration-top]
- [Effect Schema documentation on effect.website][website]
- Related in this survey: [umbrella][index] · [shared concepts][concepts] · [comparison][comparison] · [`sparkles:wired` baseline][wired-baseline] · [serde (Rust)][serde] · [Facet (Rust)][facet] · [Pydantic (Python)][pydantic] · [msgspec / cattrs (Python)][msgspec] · [ZIO Schema (Scala)][zio-schema] · [circe / aeson][circe] · [Haskell codecs][haskell] · [invertible syntax][invertible] · [ATD (OCaml)][atd] · [argv codecs][argv]

<!-- References -->

[repo]: https://github.com/Effect-TS/effect-smol
[effect-repo]: https://github.com/Effect-TS/effect
[license]: https://github.com/Effect-TS/effect-smol/blob/3a1128c7684e04d34d9f541f77adaac38a513056/LICENSE
[schema-md]: https://github.com/Effect-TS/effect-smol/blob/3a1128c7684e04d34d9f541f77adaac38a513056/packages/effect/SCHEMA.md
[schema-ts]: https://github.com/Effect-TS/effect-smol/blob/3a1128c7684e04d34d9f541f77adaac38a513056/packages/effect/src/Schema.ts
[ast]: https://github.com/Effect-TS/effect-smol/blob/3a1128c7684e04d34d9f541f77adaac38a513056/packages/effect/src/SchemaAST.ts
[issue]: https://github.com/Effect-TS/effect-smol/blob/3a1128c7684e04d34d9f541f77adaac38a513056/packages/effect/src/SchemaIssue.ts
[getter]: https://github.com/Effect-TS/effect-smol/blob/3a1128c7684e04d34d9f541f77adaac38a513056/packages/effect/src/SchemaGetter.ts
[transformation]: https://github.com/Effect-TS/effect-smol/blob/3a1128c7684e04d34d9f541f77adaac38a513056/packages/effect/src/SchemaTransformation.ts
[representation]: https://github.com/Effect-TS/effect-smol/blob/3a1128c7684e04d34d9f541f77adaac38a513056/packages/effect/src/SchemaRepresentation.ts
[parser]: https://github.com/Effect-TS/effect-smol/blob/3a1128c7684e04d34d9f541f77adaac38a513056/packages/effect/src/SchemaParser.ts
[migration]: https://github.com/Effect-TS/effect-smol/blob/3a1128c7684e04d34d9f541f77adaac38a513056/migration/schema.md
[migration-top]: https://github.com/Effect-TS/effect-smol/blob/3a1128c7684e04d34d9f541f77adaac38a513056/MIGRATION.md
[website]: https://effect.website/docs/schema/introduction/
[fast-check]: https://fast-check.dev/
[standard-schema]: https://standardschema.dev/
[optic]: https://github.com/Effect-TS/effect-smol/blob/3a1128c7684e04d34d9f541f77adaac38a513056/packages/effect/OPTIC.md
[rfc6902]: https://www.rfc-editor.org/rfc/rfc6902
[index]: ./index.md
[concepts]: ./concepts.md
[tags]: ./concepts.md#d-feasibility-tags
[tiers]: ./concepts.md#the-three-tiers
[comparison]: ./comparison.md
[wired-baseline]: ./wired-baseline.md
[serde]: ./serde.md
[facet]: ./facet.md
[pydantic]: ./pydantic.md
[msgspec]: ./msgspec-cattrs.md
[zio-schema]: ./zio-schema.md
[circe]: ./circe-aeson.md
[haskell]: ./haskell-codecs.md
[invertible]: ./invertible-syntax.md
[atd]: ./ocaml-atd.md
[argv]: ./argv-codecs.md
[expected]: ../../guidelines/idioms/expected/index.md
[dbi]: ../../guidelines/design-by-introspection-01-guidelines.md
[event-horizon]: ../../specs/event-horizon/SPEC.md
