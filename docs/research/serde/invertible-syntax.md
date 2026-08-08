# Invertible syntax descriptions (theory)

The paper under every bidirectional codec in this catalog: why a parser and a printer cannot be described by the same `Functor`, let alone the same `Monad`, and what has to change about the category the combinators live in before one description can serve both directions.

| Field           | Value                                                                                                                                                                        |
| --------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Paper           | _Invertible Syntax Descriptions: Unifying Parsing and Pretty Printing_ ([PDF][paper], [project page][project])                                                               |
| Authors         | Tillmann Rendel, Klaus Ostermann (University of Marburg)                                                                                                                     |
| Venue           | Haskell Symposium 2010                                                                                                                                                       |
| Implementations | [`partial-isomorphisms`][partial-iso] · [`invertible-syntax`][inv-syntax] · [`roundtrip`][roundtrip] (Wehr's fork) · [`invertible`][invertible-pkg] · [`semi-iso`][semi-iso] |
| Adjacent line   | [Boomerang (POPL '08)][boomerang-paper] — resourceful lenses for string data · [`boomerang`][boomerang-hackage] on Hackage · [`web-routes-boomerang`][web-routes]            |
| Category        | **Theory** — the substrate under [tier 2][tiers]; not a library to adopt                                                                                                     |

> [!NOTE]
> This page is deliberately theory-first, and several of the catalog's analysis dimensions apply only partially to it — a paper about grammars has no opinion about JSON `null`. Where a dimension does not apply, the section says so and says why; the absence is itself a finding about what the invertible-syntax line does and does not solve. The libraries that apply it are [`./haskell-codecs.md`][haskell]; the CLI-side consequences are [`./argv-codecs.md`][argv].

---

## Overview

### What it solves

A parser and a pretty-printer for the same grammar are two programs that must agree. Keeping them in step by hand is the classic source of drift: the printer emits something the parser rejects, or the parser accepts something the printer can never produce. The obvious fix — describe the syntax once, derive both — runs immediately into a type-level obstruction, and the paper's contribution is to locate that obstruction precisely and then route around it.

The obstruction bites **one level below `Monad`**, at `Functor`. With `type Printer α = α → Doc`, the type variable _"occurs in a contravariant position, to the left of a function arrow"_, so the two directions want incompatible mapping functions:

```haskell
(<$>) :: (α → β) → Parser  α → Parser  β      -- the parser wants a forward function
(<$>) :: (β → α) → Printer α → Printer β      -- the printer wants a backward function
```

No single `f` types both. `Applicative` inherits the problem, and `Monad` fails for two _further_ and independent reasons:

1. **The continuation is opaque.** In `m >>= k`, `k :: a -> m b` is a function; there is nothing to run backwards.
2. **The grammar shape becomes value-dependent.** Once the rest of the syntax depends on a parsed value, the description can no longer be _inspected_ without being _run_.

> [!IMPORTANT]
> The second reason is the one with the widest practical reach. It is exactly why [`optparse-applicative` stops at `Applicative`][argv]: a `Parser` that is only applicative can be walked to render `--help`, usage lines, and completions without any input, and the moment a `BindP` appears in the tree the right-hand branch becomes a closure invisible until a value exists. The same fact reappears in Scala as [`circe`'s `Decoder`-is-a-`Monad`/`Encoder`-is-a-`Contravariant` asymmetry][circe-aeson] — one theorem, three ecosystems.

### Design philosophy

The fix is not to weaken the interface but to **change the category the functor comes from**. Instead of mapping with functions, map with partial isomorphisms:

```haskell
data Iso α β = Iso (α → Maybe β) (β → Maybe α)

inverse :: Iso α β → Iso β α
instance Category Iso where
  g . f = Iso (apply f >=> apply g) (unapply g >=> unapply f)
  id    = Iso Just Just

class IsoFunctor     f where (<$>) :: Iso α β → (f α → f β)
class ProductFunctor f where (<*>) :: f α → f β → f (α, β)     -- pairing, NOT currying
class Alternative    f where { (<|>) :: f α → f α → f α ; empty :: f α }

class (IsoFunctor δ, ProductFunctor δ, Alternative δ) ⇒ Syntax δ where
  pure  :: Eq α ⇒ α → δ α      -- Eq so the printer can check the value it discards
  token :: δ Char
```

Two details in that listing carry most of the weight.

**`<*>` is deliberately uncurried.** The paper is explicit that this is not a cosmetic choice: _"for normal functors, the pairing variant and the currying variant of `<*>` are inter-derivable […] but for Iso functors it makes a real difference."_ Currying hides one of the two components behind a function arrow, which is precisely the position an isomorphism cannot see into.

**`pure` demands `Eq`.** In the print direction, `pure x` produces no output and must therefore _check_ that the value it is discarding is the one it expected. A constraint appearing on `pure` is the clearest single signal that this is not the ordinary `Applicative`.

---

## How it works

### Why the isomorphisms must be partial

`Iso` returns `Maybe`, not a total value, for two reasons that are both essential rather than defensive.

**Each constructor of a sum type is only a partial isomorphism onto the whole type.** `cons :: Iso (α, List α) (List α)` yields `Nothing` when applied backwards to `Nil`. That partiality is what lets `<|>` assemble a total description **one constructor at a time**, rather than forcing the author to _"specify a monolithic syntax description"_. Partiality is the mechanism by which sums decompose.

**Some relations are deliberately lossy.** `ignore x = Iso (const (Just ())) (const (Just x))` throws information away in one direction and reinvents it in the other; `skipSpace` maps any run of blanks to `()` and back to exactly one blank. These are not failures of the abstraction — they are the point of it, and they are why the round-trip law has to be stated carefully.

### The law, stated modulo an equivalence

The paper states its laws informally and says so: _"We will generally not be very strict with the invariant stated above."_ The round-trip property holds **modulo a programmer-chosen equivalence**, and — critically — in one direction only:

```text
parse (render x) == x          -- always the law
render (parse s) == s          -- never the law: whitespace, quoting, formatting all differ
```

**This is the single most transferable idea in the paper.** Any bidirectional design that tries to state the string-direction law will either fail on the first `skipSpace` or contort its printer into preserving input it has no business remembering. The value-direction law is the one that is both true and useful.

### The priority trick

The worked expression-language example shows how much a partial isomorphism can carry:

```haskell
data Expression = Variable String | Literal Integer
                | BinOp Expression Operator Expression
                | IfZero Expression Expression Expression
data Operator = AddOp | MulOp
$(defineIsomorphisms ''Expression); $(defineIsomorphisms ''Operator)

expression = exp 2 where
  exp 0 = literal <$> integer <|> variable <$> identifier <|> ifZero <$> ifzero
        <|> parens (skipSpace *> expression <* skipSpace)
  exp 1 = chainl1 (exp 0) spacedOps (binOpPrio 1)
  exp 2 = chainl1 (exp 1) spacedOps (binOpPrio 2)
  binOpPrio n = binOp . subset (λ(x,(op,y)) → priority op == n)

> print expression (BinOp (BinOp (Literal 7) AddOp (Literal 8)) MulOp (Literal 9))
Just "(7 + 8) * 9"
```

`binOpPrio` does double duty from a single definition. Rejecting a low-priority operator while **parsing** forces backtracking up to the enclosing precedence level; rejecting the same operator while **printing** forces the printer down to `exp 0`, which is the level that inserts parentheses — so the parentheses in `(7 + 8) * 9` are produced by the _same_ constraint that consumes them. The paper's summary: _"This way, correct round trip behavior is automatically guaranteed."_

### Boomerang, two different things

The name covers two distinct pieces of work, and conflating them loses the interesting distinction.

**(i) The POPL '08 language** (Bohannon, Foster, Pierce, Pilkiewicz, Schmitt), _Boomerang: Resourceful Lenses for String Data_ — a standalone bidirectional programming language over **asymmetric lenses**:

```text
get :: S → V
put :: V → S → S
```

`put` takes the **original source**, so a lens is _not_ an isomorphism: it is an update translator that preserves information the view discarded. The contributions are string-lens combinators over regular transducers, a type system based on regular expressions (so well-typedness statically implies the round-trip laws), and _dictionary lenses_ with reorderable keyed chunks.

**(ii) The Hackage `boomerang` package** (Shaw, Odenhall) is the invertible-syntax lineage with a **stack-passing** encoding instead of tuples:

```haskell
data a :- b = a :- b   infixr 8

data Boomerang e tok a b = Boomerang
  { prs :: Parser e tok (a → b)
  , ser :: b → [(tok → tok, a)] }

xpure :: (a → b) → (b → Maybe a) → Boomerang e tok a b
val   :: Parser e tok a → (a → [tok → tok]) → Boomerang e tok r (a :- r)
```

Both directions thread a heterogeneous stack `r`, so ordinary function composition `(.)` sequences grammar fragments with no tuple reassociation; `makeBoomerangs` (Template Haskell) generates the stack-shaped constructor isomorphisms. Its flagship consumer is [`web-routes-boomerang`][web-routes]: one grammar yields both URL-to-route parsing and route-to-URL printing, so **a dead link becomes a type error**.

The `ser` field is the piece worth studying: `b → [(tok → tok, a)]` is a **difference-list output with nondeterminism** — the cleanest formulation in the literature of "printing can fail, and can backtrack".

---

## Schema model & bidirectionality

This is the dimension the paper exists to answer, and its answer is the sharpest in the survey: **the syntax description _is_ the artifact**, and it is bidirectional because the mapping arrows are invertible by construction rather than by convention. A `Syntax δ ⇒ δ α` is simultaneously a parser and a printer; there is no pair to keep in step, and no `Codec.from(d, e)` accepting a mismatched pair.

What the description is _not_ is a **reified schema**. `δ α` is abstract — it is a type-class-polymorphic value interpreted by whichever instance you run it in (`Parser`, `Printer`), not a data structure you can pattern-match on. You cannot walk it to emit documentation the way [`autodocodec` walks its `Codec` GADT][haskell] or [`zio-schema` walks its `Schema` ADT][zio-schema]. Interpretations are added by writing a new _instance_, which is open in the same way but gives no access to structure the instance does not consume.

### The settled taxonomy

Rendel's §7.3 draws the boundary between the shapes precisely, and the passage is worth quoting in full because the distinction is routinely blurred:

> _"functional lenses […] can be described as functions which can be run backwards. However, functional lenses and partial isomorphisms use different notions of 'running backwards'. Running a lens forwards projects a part of a data structure […] Running it backwards combines a possibly altered version of the alternative format **with the original structure** […] This is different from partial isomorphisms, where running backwards is not dependent on some original version of data."_

With that line drawn, the four shapes and their serialization roles settle out:

| Shape            | Signature                    | Serialization role                   | D answer                                                           |
| ---------------- | ---------------------------- | ------------------------------------ | ------------------------------------------------------------------ |
| Partial iso      | `a → Maybe b`, `b → Maybe a` | parse ⇄ print                        | [(a)][tags] for constructors; [(c)][tags] for lossy/priority cases |
| Prism            | `s → Maybe a`, `a → s`       | sum-branch selection                 | [(a)][tags] — a tagged union plus a CTFE switch                    |
| Lens             | `s → a`, `a → s → s`         | `update`/PATCH ([`unjson`][haskell]) | [(a)][tags] — a `ref` field _is_ a lens                            |
| Profunctor codec | `Codec ctx i o` plus `lmap`  | field access in the print direction  | [(a)][tags] — reflection supplies `lmap`                           |

The table is the practical payoff of the theory: it says which abstraction to reach for per problem, and it says that three of the four are compile-time-derivable in D rather than hand-written values.

**D verdict: [(a)][tags] for the shapes, and the abstraction itself is the thing _not_ to adopt.** `Iso!(A, B)` as a value is trivially expressible — better as a compile-time pair of function symbols so it stays `@nogc` and CTFE-evaluable — but adopting `Iso`/`IsoFunctor` as the **spine** of a D design means paying Haskell's tax without Haskell's reason. The abstraction exists to recover, at the value level, structure that Haskell's type system had already erased; D never erases it. Keep a small `Iso!(A, B)` escape hatch for custom scalar spellings, unit suffixes, and enum aliases, and let `.tupleof` be the spine.

---

## Naming, optionality & defaults

**Largely not applicable, and the reason is structural.** An invertible syntax description is a grammar over a token stream, not a record over named keys. There is no field to rename, no key that can be absent, and no default to supply — `token`, `text`, and `<|>` are the whole vocabulary at this level. The optionality matrix that [`autodocodec` enumerates in four constructors][haskell] simply has no referent here.

Two constructs are the nearest analogues, and both are about the _print_ direction rather than the read direction:

- **`pure x` with its `Eq` constraint** is the closest thing to a default: it contributes no tokens and, when printing, verifies that the value it drops is the expected one.
- **`skipSpace` / `optSpace` / `sepSpace`** encode a three-way distinction the paper calls _allowed_ versus _desired_ versus _required_ whitespace. Parsing treats all three permissively; printing picks the canonical rendering. That is a **canonicalization policy**, and it is the same problem a CLI printer faces when `--port 8080`, `--port=8080`, and `-p8080` all parse identically — see [`./argv-codecs.md`][argv].

**D verdict: [(a)][tags], by inheriting nothing.** The dimension is empty here because the paper works one abstraction level below records; a D design gets names, optionality, and defaults from `.tupleof` and UDAs and owes this line of work nothing except the canonicalization insight — which is really the round-trip law again: assert `parse(render(x)) == x`, never the string direction.

---

## Sum types & discrimination

This is where the theory is at its strongest, and the mechanism is the partiality itself. Because each constructor's isomorphism is partial — `cons` fails on `Nil` — `<|>` can assemble a total description of a sum **one constructor at a time**, instead of requiring a monolithic description that knows about every branch at once. Each alternative is, in the taxonomy above, a **prism**.

What the theory does _not_ provide is any notion of **discrimination**. `<|>` is ordered, untagged, first-match-wins; there is no tag field, no discriminator key, and no way to record that the branches are disjoint. Every hazard that untagged decoding carries elsewhere in the catalog — [`aeson`'s `UntaggedValue` keeping only the last error][circe-aeson], [`tomland`'s `<|>` chains][haskell] — is inherited directly from this level, because none of those libraries added anything above it. [`autodocodec`'s joint-versus-disjoint `Union` tag][haskell] is the one place in the survey where the omission is repaired, and even there it is a declaration rather than a check.

`boomerang`'s `makeBoomerangs` and Rendel's `defineIsomorphisms` both exist for the same reason: **constructor pattern-matching is what a compiler knows and a value-level library does not**, so the prisms have to be generated by a macro.

**D verdict: [(b)][tags] for the machinery, and the macro disappears.** The branch list comes from the tagged union, so a prism is a generated tag check rather than a Template Haskell splice, and D can go one step past the whole lineage by checking in CTFE what `<|>` merely assumes: `static assert` that untagged branches are mutually distinguishable, so an ambiguous sum fails the build rather than the round trip.

---

## Transformations & validation

Transformation is the abstraction, so this dimension is fully populated: `iso`, `inverse`, and composition in the `Iso` `Category` are the vocabulary, and the interesting members are the ones that are deliberately not bijections.

- **`subset (λx → p x)`** — a filter that must hold in _both_ directions. This is where validation lives, and its two-directional nature is the elegant part: a predicate that rejects bad input also prevents the printer from emitting a value the parser would refuse.
- **`ignore x`** — the total loss of information in one direction, reconstructed by fiat in the other.
- **`element`** — a literal, the analogue of [`autodocodec`'s `EqCodec`][haskell].
- **The priority mechanism** shown above, in which `subset` on a precedence predicate generates parentheses in the print direction.

**D verdict: [(c)][tags] — and this is the only genuine value-level residue in the survey.** `subset`, `ignore`, `element`, and priority-driven printing encode a **choice among many concrete renderings of one abstract value**, and no amount of struct reflection recovers that choice: the information is not in the type, it is in the author's intent about output. A D design should provide a small value-level escape hatch for exactly this and no more — which is a far narrower commitment than adopting `Iso` as the spine.

---

## Errors & context

**Thin, and the thinness is instructive.** `Iso α β = Iso (α → Maybe β) (β → Maybe α)` reports failure as `Nothing`: no reason, no position, no path. For a paper that is the right choice — the contribution is the algebra, not the diagnostics — but it means the theory as published cannot say _why_ a parse failed, and a printer that fails says nothing at all.

Every usable descendant fixes this the same way, by giving the failure a payload:

- [`tomland`'s `BiMap e a b`][haskell] replaces `Maybe` with `Either e` and carries a `TomlBiMapError` — the same partial isomorphism, now able to explain itself. That upgrade is most of the distance between a theory paper and a library, and it is the same choice `sparkles:base` made with [`Expected!(T, E)`][expected].
- `boomerang`'s `Boomerang e tok a b` carries an error parameter `e` in the type, and its `ser :: b → [(tok → tok, a)]` makes the print direction's failure and backtracking explicit rather than implicit.

Nothing at this level has **paths** or **accumulation**; those arrive only when a library adds a record structure to anchor them to, which is why [`unjson`'s `Anchored Path`][haskell] is the strongest error model in the catalog and it is a serialization library rather than a syntax framework.

**D verdict: [(a)][tags] for the fix, which is already the house style.** `Expected!(T, E)` is `BiMap`'s `Either e` with a name; the difference-list-with-backtracking shape of `ser` maps onto an `Expected` result plus an output-range sink. Paths and accumulation come from the record walk, not from here.

---

## Metadata, derivations & extensibility

There is **no metadata channel and no documentation story**. A syntax description carries a grammar and nothing else: no doc strings, no annotations, no schema emission. This is the clearest structural difference between the theory line and the [tier-2 libraries built on it][haskell], where documentation is a constructor (`CommentCodec`) precisely so an interpreter can find it.

Derivation appears only as **Template Haskell compensating for missing reflection**. `defineIsomorphisms ''Expression` `reify`s a type declaration and emits one partial isomorphism per constructor; `makeBoomerangs` does the same in the stack-passing shape. Neither generates a codec — they generate the plumbing that a hand-written codec then composes.

Extensibility is by **instance**, and its payoff is real: `web-routes-boomerang` obtains routing and URL generation from one grammar, so a link that no route can produce fails to compile. That is the same non-drift argument the whole catalog turns on, applied to URLs instead of JSON.

One warning from §7 deserves to outlive the paper. Rendel critiques Alimarine et al.'s `BiArrow`s (Haskell '05) for making `BiArrow` a **subclass of `Arrow`** and then calling `error` in the methods that cannot be implemented invertibly:

> [!WARNING]
> An interface that advertises a capability it cannot honour pushes the failure from compile time to run time, for every client. This is a live hazard for [design-by-introspection][dbi] trait design: a D capability trait should describe what a type _does_ support, checked with `__traits(compiles, …)` and `static assert`, rather than declaring a broad interface with `assert(0)` bodies for the parts a given backend cannot provide.

**D verdict: [(a)][tags] for replacing the macros, [(b)][tags] for the extensibility the theory lacks.** `.tupleof` plus `__traits(allMembers)` gives constructor-to-tuple isomorphisms with no macro system at all — the Template Haskell in this lineage exists purely to compensate for reflection Haskell does not have. The metadata channel the theory lacks entirely is where a D design should invest instead: `__traits(getAttributes)` is open and typed, so a backend written later reads annotations the schema layer never heard of. See [`./comparison.md`][comparison] for how that lands against the rest of the survey.

---

## Strengths

- **It locates the obstruction exactly.** The failure is at `Functor`, not `Monad`, and the paper proves it in two lines of type signature.
- **The fix is minimal and principled**: keep the combinator shapes, change the category the mapping arrows come from.
- **Partiality does real work.** It is what lets `<|>` build a sum description constructor by constructor instead of monolithically.
- **The round-trip law is stated correctly** — modulo an equivalence, in the value direction only. Everything downstream that states it the other way is wrong.
- **The priority trick shows the abstraction's reach**: one predicate generates and consumes parentheses, with correctness by construction rather than by testing.
- **The lens-versus-isomorphism boundary (§7.3) is the definitive statement**, and it is what makes the four-shape taxonomy usable as a design tool.
- **`boomerang`'s `ser` difference list** is the cleanest published formulation of a failing, backtracking printer.
- **`web-routes-boomerang` demonstrates the payoff outside serialization** — dead links as type errors.

## Weaknesses

- **The description is abstract, not reified.** It cannot be walked, so no documentation, schema, or migration can be derived from it — the whole tier-3 capability set is out of reach by construction.
- **No error payload.** `Maybe` failure carries no reason, no position, no path, and no accumulation.
- **No metadata channel** — no annotations, no doc strings, nothing for a downstream interpreter to read.
- **Sum discrimination is absent**: ordered, untagged, first-match-wins `<|>`, with no way to state or check disjointness.
- **Records are below the level of abstraction**, so naming, optionality, and defaults have no vocabulary at all.
- **The constructor isomorphisms need Template Haskell**, which is a macro system standing in for reflection.
- **Uncurried `<*>` costs ergonomics**: nested tuples must be reassociated by hand, which is exactly the pain `boomerang`'s stack encoding was invented to relieve.
- **`BiArrow`-style over-generalization is an easy trap** in this space, as the paper itself documents.

## Key design decisions and trade-offs

| Decision                                                      | Rationale                                                                                      | Trade-off                                                                                        |
| ------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| Map with partial isomorphisms instead of functions            | A function has no backward direction; an `Iso` does, so one description serves both directions | Every mapping must be written as a pair, and the pair's coherence is the author's responsibility |
| Partial (`Maybe`) rather than total isomorphisms              | Constructors are partial onto their sum; lossy relations (`ignore`, `skipSpace`) are wanted    | Failure carries no reason — descendants all had to add an error payload                          |
| Uncurried `ProductFunctor` `<*>`                              | Currying hides a component behind an arrow, where an isomorphism cannot reach                  | Nested tuples, manual reassociation; `boomerang` reinvents the shape as a stack                  |
| Stop at `Alternative`; no `Monad`                             | Keeps the description inspectable and invertible; value-dependent grammars are excluded        | Context-sensitive syntax is out of scope — the same ceiling `optparse-applicative` sits at       |
| `pure` constrained by `Eq`                                    | The printer must check the value it emits no tokens for                                        | An unusual constraint that breaks drop-in compatibility with the standard `Applicative`          |
| Round-trip law modulo an equivalence, value-direction only    | Whitespace, quoting, and formatting differences make the string direction unstateable          | The law is weaker than it looks; the equivalence is chosen by the programmer, not checked        |
| `defineIsomorphisms` via Template Haskell                     | Constructor prisms are mechanical and tedious; the compiler already knows them                 | A macro dependency that exists solely because the language lacks reflection                      |
| `boomerang`'s `a :- b` stack instead of tuples                | Ordinary composition sequences fragments with no reassociation                                 | An extra encoding to learn, and it exists only to compose curried constructors                   |
| Asymmetric lenses (`put` takes the source) as a separate line | Update translation genuinely needs the original source to preserve discarded information       | Not an isomorphism, so it does not unify with parse/print — a different tool for a different job |

---

## Sources

- [Rendel & Ostermann, _Invertible Syntax Descriptions_ (Haskell Symposium 2010, PDF)][paper] · [project page][project]
- [`partial-isomorphisms` — the `Iso` type and `defineIsomorphisms`][partial-iso] · [`invertible-syntax` — the `Syntax` class and combinators][inv-syntax]
- [`roundtrip` (Wehr's fork, with `roundtrip-string`/`-xml`/`-aeson`)][roundtrip] · [`invertible` — total bijections plus Template Haskell][invertible-pkg] · [`semi-iso`][semi-iso]
- [Bohannon, Foster, Pierce, Pilkiewicz & Schmitt, _Boomerang: Resourceful Lenses for String Data_ (POPL '08, PDF)][boomerang-paper]
- [`boomerang` on Hackage][boomerang-hackage] · [`Text.Boomerang.Prim` — `Boomerang`, `prs`/`ser`, `xpure`, `val`][boomerang-prim] · [`web-routes-boomerang` — one grammar for routing and URL generation][web-routes]
- [`profunctor-monad` (Li-yao Xia) — recovering `do`-notation by making the codec a profunctor over the source record][profunctor-monad]
- Related in this catalog: [autodocodec, tomland & unjson — the theory applied][haskell] · [circe & aeson — the same theorem as a variance mismatch][circe-aeson] · [argv codecs — the `Applicative` ceiling and unparsing][argv] · [zio-schema — reification instead of abstraction][zio-schema] · [Concepts][concepts] · [Comparison][comparison]

<!-- References -->

[paper]: https://www.informatik.uni-marburg.de/~rendel/unparse/rendel10invertible.pdf
[project]: https://www.informatik.uni-marburg.de/~rendel/unparse/
[partial-iso]: https://hackage.haskell.org/package/partial-isomorphisms
[inv-syntax]: https://hackage.haskell.org/package/invertible-syntax
[roundtrip]: https://hackage.haskell.org/package/roundtrip
[invertible-pkg]: https://hackage.haskell.org/package/invertible
[semi-iso]: https://hackage.haskell.org/package/semi-iso
[boomerang-paper]: https://www.cs.cornell.edu/~jnfoster/papers/boomerang.pdf
[boomerang-hackage]: https://hackage.haskell.org/package/boomerang
[boomerang-prim]: https://hackage.haskell.org/package/boomerang-1.4.5.5/docs/Text-Boomerang-Prim.html
[web-routes]: https://hackage.haskell.org/package/web-routes-boomerang
[profunctor-monad]: https://hackage.haskell.org/package/profunctor-monad
[expected]: ../../guidelines/idioms/expected/index.md
[dbi]: ../../guidelines/design-by-introspection-01-guidelines.md
[tags]: ./concepts.md#d-feasibility-tags
[tiers]: ./concepts.md#the-three-tiers
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[haskell]: ./haskell-codecs.md
[circe-aeson]: ./circe-aeson.md
[zio-schema]: ./zio-schema.md
[argv]: ./argv-codecs.md
