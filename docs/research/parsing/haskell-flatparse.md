# flatparse (Haskell)

A high-performance, **zero-allocation** [parser-combinator][concepts] library for strict `ByteString` input: parsers are GHC values built from unboxed-tuple primitives, choice is ordered [PEG][peg]-style backtracking, and the failure/error split is modelled directly on Rust's [`nom`][nom] rather than the [Parsec][parsec] consumed/empty machinery. It is the survey's clearest proof that a combinator API can allocate _nothing_ on the parse path.

| Field                     | Value                                                                                            |
| ------------------------- | ------------------------------------------------------------------------------------------------ |
| Language                  | Haskell (GHC; unboxed tuples + primops, `-fllvm` recommended)                                    |
| License                   | MIT (`LICENSE`: _"Copyright 2021 András Kovács … Permission is hereby granted, free of charge"_) |
| Repository                | [AndrasKovacs/flatparse][flat-repo] (SHA `df7e978`, `flatparse-0.5.3.1`)                         |
| Documentation             | [`flatparse` on Hackage][flat-hackage] · [`README.md`][flat-readme]                              |
| Key author                | András Kovács                                                                                    |
| Category                  | Parser combinator (Haskell; low-level, zero-alloc)                                               |
| Algorithm / grammar class | PEG-like ordered-choice recursive descent; **failure/error split** (no consumed/empty tracking)  |
| Input                     | **Strict `ByteString` only** (pinned, contiguous; parsed as a raw `Addr#`)                       |
| Incrementality            | **None** — an explicit non-feature (contrast [attoparsec's `Partial`][parsec])                   |
| Performance               | 2–10× `attoparsec`/`megaparsec` on microbenchmarks; zero heap allocation for pure validators     |
| Notes                     | Two flavours — `FlatParse.Basic` (no state) vs `FlatParse.Stateful` (`Int` state + reader env)   |

> [!NOTE]
> flatparse sits at the throughput extreme of the Haskell combinator field surveyed in the [Parsec/Megaparsec/attoparsec deep-dive][parsec]. Where that lineage descends from monadic parsing with a careful `Consumed`/`Empty` error model, flatparse **deliberately discards** consumed-input tracking and the monad-transformer stack, keeping only ordered choice, a three-way result, and hand-tuned unboxed primitives. Read it against [`nom`][nom] (the backtracking model it names as its closest relative) and against the [Parsec lineage][parsec] (the ergonomics it trades away).

---

## Overview

### What it solves

flatparse answers a narrow question: _how fast, and how allocation-free, can a combinator parser be in Haskell?_ It keeps the combinator programming model — a parser is a first-class value, grammars are ordinary functions composed with `>>=`/`<*>`/`<|>` — but rebuilds the representation from the ground up for machine throughput. The `README` states the dual meaning of the name ([`README.md`][flat-readme]):

> _"`flatparse` is a high-performance parsing library… The 'flat' in the name refers to the `ByteString` parsing input, which has pinned contiguous data, and also to the library internals, which avoids indirections and heap allocations whenever possible. `flatparse` is generally lower-level than `parsec`-style libraries, but it is possible to build higher-level features (such as source spans, hints, indentation parsing) on top of it, without making any compromises in performance."_

The design target is stated plainly: on microbenchmarks it beats the incumbents by an order of magnitude, and validator-style parsers cost nothing on the heap ([`README.md`][flat-readme]):

> _"On microbenchmarks, `flatparse` is 2-10 times faster than `attoparsec` or `megaparsec`. … `flatparse` internals make liberal use of unboxed tuples and GHC primops. As a result, pure validators (parsers returning `()`) in `flatparse` are not difficult to implement with zero heap allocation."_

### Design philosophy

The philosophy is _low-level primitives, no batteries_. flatparse ships fast source-position handling, indentation state, and the raw materials for error messages, but leaves the ergonomic surface for the user to assemble — because, in the author's experience, the bundled machinery in higher-level libraries carries unavoidable overhead ([`README.md`][flat-readme]):

> _"`flatparse` provides a low-level interface to these. Batteries are not included, but it should be possible for users to build custom solutions, which are more sophisticated, but still as fast as possible. In my experience, the included batteries in other libraries often come with major unavoidable overheads…"_

The most consequential decision is the backtracking model, which flatparse frames as a repudiation of Parsec's consumed/empty bookkeeping in favour of `nom`'s failure/error split ([`README.md`][flat-readme]):

> _"The backtracking model of `flatparse` is different to parsec libraries, and is more close to the [nom] library in Rust. The idea is that parser failure is distinguished from parsing error. The former is used for control flow, and we can backtrack from it. The latter is used for unrecoverable errors, and by default it's propagated to the top. `flatparse` does not track whether parsers have consumed inputs."_

That last clause is the crux. In the [Parsec lineage][parsec], `<|>` refuses to backtrack once the left branch consumed input; the semantics turn on whether input was touched. flatparse throws that distinction out — every failure backtracks freely, and only an _explicit_ error (via `err`/`cut`) short-circuits. The author argues this is the distinction that actually matters ([`README.md`][flat-readme]): _"in `parsec` or `megaparsec` the consumed/non-consumed separation is often muddled and discarded in larger parser implementations."_ The cost is that grammar authors must place errors by hand ([`README.md`][flat-readme]): _"`flatparse` users have to be mindful about grammar, and explicitly insert errors where it is known that the input can't be valid."_

---

## How it works

### The parser is an unboxed function over a raw address

A flatparse parser is a `newtype` wrapping a function from raw machine pointers into an unboxed result. From [`src/FlatParse/Basic/Parser.hs`][flat-repo]:

```haskell
newtype ParserT (st :: ZeroBitType) e a =
    ParserT { runParserT# :: ForeignPtrContents -> Addr# -> Addr# -> st -> Res# st e a }
```

The two `Addr#` arguments are the **end-of-buffer pointer** (`eob`) and the **current position** (`s`) into the pinned `ByteString`; `ForeignPtrContents` keeps the buffer alive; `st` is a zero-width state token (below). There is no boxed input, no stream type class, no transformer layer — the parser is a bare pointer-threading function that GHC inlines aggressively.

### The three-way unboxed result

The result type is an **unboxed tuple wrapping an unboxed sum of three cases** — the whole reason validators allocate nothing ([`src/FlatParse/Basic/Parser.hs`][flat-repo]):

```haskell
type Res# (st :: ZeroBitType) e a = (# st, ResI# e a #)

type ResI# e a =
  (# (# a, Addr# #)   -- OK#   : value + pointer to the rest of the input
   | (# #)            -- Fail# : recoverable failure, carries nothing
   | (# e #)          -- Err#  : unrecoverable error, carries the error value
   #)
```

The three bidirectional pattern synonyms `OK#` / `Fail#` / `Err#` name the cases; a `{-# complete OK#, Fail#, Err# #-}` pragma tells GHC the match is total. Because the sum is unboxed, a success returns the value and the advanced pointer **without constructing a heap cell** — a parser returning `()` (the pure-validator case) reduces to pointer arithmetic and control flow.

The user-facing boxed counterpart, returned only once at the top by `runParser`, mirrors the three cases ([`src/FlatParse/Basic.hs`][flat-repo]):

```haskell
data Result e a =
    OK a !(B.ByteString)  -- return value + unconsumed input
  | Fail                  -- recoverable-by-default failure
  | Err !e                -- unrecoverable-by-default error
```

`runParser` itself pins the `ByteString`, computes the end pointer, and runs the raw function under `unsafePerformIO` ([`src/FlatParse/Basic.hs`][flat-repo]):

```haskell
runParser (ParserT f) b@(B.PS (ForeignPtr _ fp) _ (I# len)) = unsafePerformIO $
  B.unsafeUseAsCString b \(Ptr buf) -> do
    let end = plusAddr# buf len
    pure case f fp end buf proxy# of
      OK# _st a s -> let offset = minusAddr# s buf in OK a (B.drop (I# offset) b)
      Err# _st e -> Err e
      Fail# _st  -> Fail
```

### Failure vs error: backtrack, or short-circuit

Ordered choice is defined directly on the three-way result. `<|>` retries the right branch **only on `Fail#`** and propagates `Err#` (and success) unchanged ([`src/FlatParse/Basic/Parser.hs`][flat-repo]):

```haskell
(<|>) (ParserT f) (ParserT g) = ParserT \fp eob s st ->
  case f fp eob s st of
    Fail# st' -> g fp eob s st'   -- recoverable: try the alternative
    x         -> x                -- OK# or Err#: commit / propagate
```

This is the exact mirror of [`nom`][nom]'s `Err::Error` (recoverable, `alt` retries) vs `Err::Failure` (unrecoverable, `alt` gives up). The bridging operations live in [`src/FlatParse/Basic/Base.hs`][flat-repo]:

| Operation                         | Effect                                                                    | `nom` analogue           |
| --------------------------------- | ------------------------------------------------------------------------- | ------------------------ | -------------- |
| `failed` / `empty`                | Produce `Fail#` (backtrackable)                                           | `Err::Error`             |
| `err :: e -> ParserT st e a`      | Produce `Err#` — short-circuits past `<                                   | >` to the top            | `Err::Failure` |
| `try`                             | Convert an `Err#` **back** into a `Fail#` (make it recoverable)           | (no direct nom equiv.)   |
| `cut :: ParserT st e a -> e -> …` | Convert a `Fail#` **into** an `Err#` — commit to this branch              | `cut()`                  |
| `cutting`                         | Like `cut`, but merges a new error into an existing one via `e -> e -> e` | error-accumulating `cut` |

```haskell
err  e = ParserT \_fp _eob _s st -> Err# st e         -- throw an unrecoverable error
try (ParserT f) = ParserT \fp eob s st -> case f fp eob s st of
  Err# st' _ -> Fail# st'  ; x -> x                    -- error → failure
cut (ParserT f) e = ParserT \fp eob s st -> case f fp eob s st of
  Fail# st' -> Err# st' e  ; x -> x                    -- failure → error
```

Note the direction is **opposite** to Parsec's `try`: Parsec's `try` turns a _consumed failure_ into a _backtrackable_ one to widen lookahead, whereas flatparse's `try` demotes a thrown _error_ to a failure. flatparse has no lookahead-widening problem to solve because every failure already backtracks; instead the author's discipline is to promote failures to errors with `cut` once a branch is committed — exactly `nom`'s "we know we were in the right branch, so a parse error here is real" idiom.

### Two flavours, three modes

flatparse ships two parser flavours, each parameterised by a zero-width **state token** that selects the effect mode ([`README.md`][flat-readme]):

> _"`flatparse` comes in two flavors: `FlatParse.Basic` and `FlatParse.Stateful`. Both support a custom error type. Also, both come in three modes, where we can respectively run `IO` actions, `ST` actions, or no side effects. The modes are selected by a state token type parameter on the parser types."_

The token is a phantom of kind `ZeroBitType`, so it costs nothing at runtime ([`src/FlatParse/Common/Parser.hs`][flat-repo]):

```haskell
type PureMode = Proxy# Void        -- pure:  Parser
type IOMode   = State# RealWorld   -- IO:    ParserIO
type STMode s = State# s           -- ST:    ParserST
```

`FlatParse.Stateful` adds a **built-in `Int` of mutable state and a reader environment `r`**, threaded through the same closure, for indentation parsing ([`README.md`][flat-readme] · [`src/FlatParse/Stateful/Parser.hs`][flat-repo]):

```haskell
newtype ParserT (st :: ZeroBitType) r e a =        -- note the extra r
  ParserT { runParserT# :: ForeignPtrContents -> r -> Addr# -> Addr# -> Int# -> st -> Res# st e a }
```

with `get`/`put`/`modify` over the `Int#` and `ask`/`local` over `r` ([`src/FlatParse/Stateful.hs`][flat-repo]). The `README` notes a "moderate overhead in performance and code size compared to `Basic`"; the object-file sizes it reports (71 KB `fpbasic` vs 74 KB `fpstateful`, against 403 KB `megaparsec`) put both flavours an order of magnitude below the incumbents.

### Source positions, spans, and machine integers

Position handling is a first-class low-level primitive rather than a bundled battery. `getPos`/`setPos` read and write the raw `Addr#` as a `Pos`; `spanOf`/`withSpan` capture the `Span` a sub-parser consumed; `posLineCols` resolves a batch of positions to line/column pairs in a single pass ([`src/FlatParse/Basic.hs`][flat-repo]). For binary formats, `FlatParse.Basic.Integers` provides native-order machine-integer parsers (`anyWord8`…`anyWord64`, `anyInt*`) **and** explicit-endianness variants (`anyWord16le`/`anyWord16be`, …) plus CPS versions (`withAnyWord8`, …) that avoid boxing the result — necessary because the host machine itself is little-endian-only (below).

### `switch`: literal branching compiled to a trie

For keyword-heavy grammars flatparse offers `switch`, a Template Haskell macro that overloads `case` on string literals and compiles the alternatives to a decision trie ([`src/FlatParse/Basic/Switch.hs`][flat-repo]):

```haskell
$(switch [| case _ of
    "foo" -> pure True
    "bar" -> pure False |])
```

The macro documentation describes the payoff: branching is "compiled to a trie of primitive parsing operations, which has optimized control flow, vectorized reads and grouped checking for needed input bytes", with longest-match semantics independent of case order. `switchWithPost` threads a post-action (e.g. whitespace skipping) after each match — the idiom the bundled lambda-calculus example uses to build a lexer ([`src/FlatParse/Examples/BasicLambda/Lexer.hs`][flat-repo]).

---

## Algorithm & grammar class

flatparse is a **recursive-descent, top-down, ordered-choice** parser — the same [top-down combinator][top-down] family as the [Parsec lineage][parsec] and [`nom`][nom], and conceptually adjacent to [PEG][peg] (ordered choice, no ambiguity, scannerless). The differences from Parsec are subtractions:

- **No consumed/empty tracking.** The grammar class is governed purely by the failure/error split. `<|>` always backtracks on `Fail#`, so there is no LL(1)-by-default restriction and no `try`-to-widen-lookahead foot-gun; the price is that there is no automatic "expected set" merging, and errors are whatever the author threads with `cut`.
- **No left recursion.** As with every recursive-descent scheme, a left-recursive production loops forever; iteration is expressed with the fold-style `chainl`/`chainr` (which the source explicitly notes are _"not the usual `chainl` from the parsec libraries"_ — they are `foldl`/`foldr` over repeated elements) or with `many`/`some`/`skipMany`.
- **No ambiguity / no parse forest.** Ordered choice commits to the first success; there is no enumeration of all parses (use a [general GLR/Earley parser][general] for that).
- **Context-sensitive via monadic bind.** `>>=` threads the runtime result, so later parsers can depend on earlier ones; `FlatParse.Stateful`'s `Int` state + reader env extend this to indentation-sensitive grammars.
- **Scannerless by default.** The token is a byte or a UTF-8 `Char`; there is no separate lexer phase, though `switch` + a whitespace post-action builds a fast lexer layer by hand.

Unlike [packrat parsers][peg] there is **no memoization** — a backtracking-heavy grammar can rescan input, with no linear-time guarantee. This is the same trade `nom` and Parsec make, and here it is doubled down on for raw speed.

## Interface & composition model

The interface is an **internal DSL**: a grammar is a Haskell value assembled from the standard type-class operators (`Functor`/`Applicative`/`Monad`/`Alternative`) plus flatparse's own combinators. There is no external grammar file and no generator. AST construction is explicit and host-native — the parser writer maps results into their own types with `<$>`/`<*>`/`do`, exactly as in the [Parsec lineage][parsec]. The distinguishing surface features are the CPS-style combinators (`withOption`, `withSpan`, `withByteString`, `withAnyWord*`) that hand their result to a continuation instead of boxing it into a `Maybe`/tuple — the source repeatedly notes these are "more efficient, because the result is more eagerly unboxed by GHC" ([`src/FlatParse/Basic.hs`][flat-repo]). The composition model is otherwise the canonical combinator one; what changes is that every primitive is written against the raw `Addr#`/`Res#` representation.

## Performance

Performance is the whole point, and it comes from three structural choices: parsing a **pinned, contiguous `ByteString` as a raw `Addr#`** (no bounds-checked indexing, no stream abstraction), returning an **unboxed three-way result** (no heap cell per step), and **no monad-transformer stack** (unlike [`ParsecT`][parsec]). The `README`'s own benchmarks (GHC 9.10.2, `-O2 -fllvm`, `flatparse-0.5.3.1`, AMD 9800X3D) quantify the gap ([`README.md`][flat-readme]):

| benchmark      | fp Basic | fp Stateful | attoparsec | megaparsec | parsec  |
| -------------- | -------- | ----------- | ---------- | ---------- | ------- |
| `sexp`         | 1.80 ms  | 1.25 ms     | 10.2 ms    | 6.92 ms    | 39.9 ms |
| `long keyword` | 0.054 ms | 0.062 ms    | 0.308 ms   | 0.687 ms   | 3.50 ms |
| `numeral csv`  | 0.540 ms | 0.504 ms    | 3.17 ms    | 1.09 ms    | 13.8 ms |
| `lambda term`  | 1.52 ms  | 1.56 ms     | 4.94 ms    | 5.35 ms    | 17.7 ms |

On `sexp`, Basic is ~5.7× faster than attoparsec and ~3.8× faster than megaparsec; on `long keyword` the gap to megaparsec is ~13×. The `README` adds that compile times and executable sizes are "significantly better" too, backed by the object-file table (fpbasic 71 KB vs megaparsec 403 KB).

**Allocation model — zero for validators.** The unboxed `Res#` is what lets a parser returning `()` run without touching the heap ([`README.md`][flat-readme]): _"pure validators (parsers returning `()`) in `flatparse` are not difficult to implement with zero heap allocation."_ This is the property no other combinator library in the survey guarantees, and the one most directly relevant to Sparkles (below). LLVM codegen adds a further 20–40% per the `README`; none of the engine uses SIMD or data-parallel scanning — it is a scalar, sequential recursive-descent core.

## Error handling & recovery

flatparse's error posture is **failure-as-control-flow plus explicit errors plus fast spans** — and no bundled diagnostics.

- **Failure is cheap and silent.** A `Fail#` carries nothing; it is pure control flow that `<|>` consumes. By default a parser can only fail, never error ([`README.md`][flat-readme]): _"basic `flatparse` parsers can fail but can not throw errors, with the exception of the specifically error-throwing operations."_
- **Errors are explicit and typed.** `err`/`cut`/`cutting` inject a value of the user's custom error type `e` (the second type parameter of `ParserT`), which propagates to the top unless caught by `try`/`withError`. There is **no automatic expected-set machinery** as in [Megaparsec][parsec]; the author must decide where a failure becomes an error.
- **Positions are first-class and fast.** `getPos`/`Span`/`posLineCols` give byte-accurate source locations at primitive cost, the raw material for messages.
- **Batteries are the user's job.** The bundled lambda-calculus example ([`src/FlatParse/Examples/BasicLambda/Lexer.hs`][flat-repo]) shows the intended pattern: a hand-rolled `Error` type distinguishing `Precise`/`Imprecise` errors, a `merge` that prefers inner (more-consumed) and precise errors, `cut`/`cut'` wrappers that attach expected-items, and a `prettyError` that renders the offending source line with a caret. It is "decently informative" — but every bit of it is written by the user, not provided.
- **No recovery, no incrementality.** There is no `withRecovery`/error-bundle equivalent, and — the headline non-feature — no incremental parsing ([`README.md`][flat-readme]): _"No incremental parsing, and only strict `ByteString` is supported as input."_ flatparse is a one-shot function from a whole buffer to a result; it is not IDE-grade for edit-and-reparse, and unlike [attoparsec][parsec] it cannot suspend on partial input.

## Ecosystem & maturity

flatparse is younger and more niche than the [Parsec lineage][parsec] — the choice when raw throughput is paramount and the author will forgo Megaparsec's ergonomics. It is actively maintained (`0.5.3.1`, tested against GHC 8.6 through 9.8 per `flatparse.cabal`), MIT-licensed, and authored by András Kovács, who uses it in dependently-typed-language prototypes where lexer/parser speed dominates. Two constraints bound its applicability, both stated as non-features:

- **Strict `ByteString` only.** `Text`/`String` must be converted first; the `README` argues the conversion cost is usually repaid by the speed.
- **Little-endian host only** ([`README.md`][flat-readme]): _"Only little-endian systems are currently supported as the host machine."_ (Explicit-endianness integer parsers exist for the _data_, but the host must be little-endian.)

---

## Strengths

- **Zero-allocation parse path.** The unboxed `Res#` makes pure validators heap-free — unique in this survey among combinator libraries.
- **Order-of-magnitude speed.** 2–10× attoparsec/megaparsec on microbenchmarks, with far smaller code and faster compiles.
- **Simple, honest backtracking model.** Failure (backtrack) vs error (propagate), no consumed/empty subtlety to reason about — the [`nom`][nom] model, which many find clearer at scale.
- **Low-level position/span/integer primitives** for building fast, custom error messages and binary parsers, plus `switch` for trie-compiled keyword branching.
- **Three effect modes** (pure/`IO`/`ST`) selected by a zero-cost state token; `Stateful` adds `Int` state + reader env for indentation parsing without a transformer.
- **Still an ordinary combinator DSL** — grammars are Haskell values, context-sensitive via monadic bind.

## Weaknesses

- **No incremental parsing** and **strict `ByteString` only** — unsuitable for streaming input or non-byte streams without up-front conversion.
- **Little-endian host only** — a portability restriction absent from every other library here.
- **Batteries not included** — expected-sets, error recovery, indentation helpers, and pretty-printing are all the user's responsibility; the low-level interface is deliberately spartan.
- **No memoization / no left recursion / no parse forests** — the standard recursive-descent limits, with no packrat linear-time guarantee.
- **`unsafePerformIO` + raw `Addr#` internals** — the speed comes from unsafe machinery; misusing `setPos`/`skipBack`/`anyCStringUnsafe` can crash rather than fail.
- **Manual error discipline** — because failures are silent by default, forgetting a `cut` yields an unhelpful top-level `Fail` where a real diagnostic was wanted.

## Key design decisions and trade-offs

| Decision                                                            | Rationale                                                                              | Trade-off                                                                                |
| ------------------------------------------------------------------- | -------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- | ----------------------------------------------------------------------- |
| Parse strict `ByteString` as a raw `Addr#`, under `unsafePerformIO` | No bounds-checked indexing, no stream abstraction — maximal throughput                 | `Text`/`String` need conversion; unsafe internals; crash-not-fail on misuse              |
| Unboxed three-way result (`OK#`/`Fail#`/`Err#`)                     | No heap cell per step → zero allocation for pure validators                            | Requires `UnboxedTuples`/primops; results must be forced/CPS'd to stay unboxed           |
| Failure/error split (à la `nom`), **not** Parsec's consumed/empty   | Simpler, clearer model that scales; `<                                                 | >` always backtracks on failure                                                          | No automatic expected-set errors; author must place `cut`/`err` by hand |
| Drop the `ParsecT` monad-transformer stack                          | Removes indirection the benchmarks attribute the 2–10× gap to                          | Fewer ergonomics; effects handled via the zero-cost state-token modes instead            |
| Zero-width state token selects pure/`IO`/`ST` mode                  | One parser type serves three effect regimes at no runtime cost                         | `ZeroBitType`/`Proxy#` machinery; `runParser` is `noinline` to keep coercions sound      |
| `Basic` vs `Stateful` split                                         | Pay for `Int` state + reader env only when indentation parsing needs it                | Two APIs to learn; moderate overhead when `Stateful` is used                             |
| Low-level primitives, "batteries not included"                      | Bundled batteries elsewhere carry unavoidable overhead; users build faster custom ones | Expected-sets, recovery, indentation, pretty errors are all user-written                 |
| `switch` via Template Haskell → decision trie                       | Keyword branching with vectorized reads and grouped input checks; longest-match        | Requires TH; stage restriction (a `switch'` helper can't be used in its defining module) |

## Sparkles relevance

flatparse is the survey's **existence proof for a `@nogc` combinator API**. Every other combinator library here allocates on the parse path; flatparse shows that with an unboxed result and a raw-buffer input, a combinator parser returning `()` can run with **zero heap allocation** — precisely the target for a D combinator written against `SmallBuffer`/`@nogc` text primitives rather than the GC. Three mappings are direct:

- **Failure/error split ↔ `Expected!(T, E)`.** flatparse's `Fail#` (backtrackable control flow) vs `Err#` (propagate-to-top) is the same shape as fail-fast-and-retry vs a real error in the [`expected`](../../guidelines/idioms/expected/index.md) idiom — a recoverable empty result the caller can `orElse` past, versus an error value that short-circuits. `cut`/`try` are the `Fail# ↔ Err#` conversions a D API would expose as "commit" / "recover".
- **Zero-alloc validators ↔ version-string validation.** The `()`-returning validator is exactly the [`sparkles:versions`](../../libs/versions/index.md) parse/validate use case: check that a version string is well-formed in a hot loop without touching the heap — flatparse demonstrates the representation (unboxed three-way result over a raw buffer) that makes this possible.
- **Low-level primitives + user-built batteries ↔ the Sparkles house style.** flatparse's "fast primitives, no batteries" stance matches building on `@nogc` `readers`/`writers` and layering ergonomics above, rather than importing a heavyweight framework.

---

## Sources

- [AndrasKovacs/flatparse `README.md`][flat-readme] — features/non-features, failure-vs-error model, benchmarks, Basic vs Stateful, "batteries not included" (all quoted above)
- [`src/FlatParse/Basic/Parser.hs`][flat-repo] — `ParserT`, the unboxed `Res#`/`ResI#` result, `OK#`/`Fail#`/`Err#`, `<|>`
- [`src/FlatParse/Basic/Base.hs`][flat-repo] — `err`, `try`, `cut`, `cutting`, `withError`, `withOption`, `branch`, `chainl`/`chainr`, `eof`, `take`, `ensure`, `isolate`
- [`src/FlatParse/Basic.hs`][flat-repo] — boxed `Result`, `runParser` (raw `Addr#` under `unsafePerformIO`), `getPos`/`Span`/`spanOf`/`posLineCols`
- [`src/FlatParse/Basic/Integers.hs`][flat-repo] — native + explicit-endianness machine-integer parsers, CPS `withAny*`
- [`src/FlatParse/Basic/Switch.hs`][flat-repo] — Template Haskell `switch` → trie with vectorized reads
- [`src/FlatParse/Stateful/Parser.hs`][flat-repo] + [`src/FlatParse/Stateful.hs`][flat-repo] — reader-env + `Int#`-state parser, `get`/`put`/`modify`/`ask`/`local`
- [`src/FlatParse/Examples/BasicLambda/Lexer.hs`][flat-repo] — user-built `Error` type, `merge`, `cut`/`cut'`, `prettyError` (the "batteries you write yourself" pattern)
- [`flatparse.cabal`][flat-repo] — `license: MIT`, `version: 0.5.3.1`, tested GHC 8.6–9.8
- Related deep-dives: [Parsec / Megaparsec / attoparsec][parsec] (the higher-level Haskell lineage) · [`nom`][nom] (the failure/error backtracking model) · combinator siblings [`winnow`][winnow] · [`chumsky`][chumsky] · [`combine`][combine] · [`angstrom`][angstrom] · theory: [top-down & combinator parsing][top-down] · [PEG & packrat][peg] · [general parsing][general] · [the parsing umbrella][umbrella] · [the comparison capstone][comparison]

<!-- References -->

[umbrella]: ./index.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[top-down]: ./theory/top-down.md
[peg]: ./theory/peg-packrat.md
[general]: ./theory/general-parsing.md
[parsec]: ./haskell-parsec.md
[nom]: ./rust-nom.md
[winnow]: ./rust-winnow.md
[chumsky]: ./rust-chumsky.md
[combine]: ./rust-combine.md
[angstrom]: ./ocaml-angstrom.md
[flat-repo]: https://github.com/AndrasKovacs/flatparse
[flat-hackage]: https://hackage.haskell.org/package/flatparse
[flat-readme]: https://raw.githubusercontent.com/AndrasKovacs/flatparse/df7e978f710a96f4ed3366b89be67a8b8550b948/README.md
