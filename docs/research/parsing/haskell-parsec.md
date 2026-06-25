# Parsec, Megaparsec & attoparsec (Haskell)

The canonical functional [parser-combinator][concepts] lineage: a parser is an ordinary host-language value — a function from input to a result — and the `Monad`/`Applicative`/`Alternative` type-class instances supply sequencing, choice, and repetition, so grammars are written directly in Haskell with no external generator.

| Field                     | Value                                                                                                                                    |
| ------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| Language                  | Haskell                                                                                                                                  |
| License                   | `parsec` BSD-2-Clause · `megaparsec` BSD-2-Clause · `attoparsec` BSD-3-Clause · `flatparse` MIT                                          |
| Repository                | [haskell/parsec][parsec-repo] · [mrkkrp/megaparsec][mega-repo] · [haskell/attoparsec][atto-repo] · [AndrasKovacs/flatparse][flat-repo]   |
| Documentation             | [parsec][parsec-hackage] · [megaparsec][mega-hackage] · [attoparsec][atto-hackage] · [flatparse][flat-hackage] on Hackage                |
| Key authors               | Daan Leijen, Erik Meijer (Parsec); Mark Karpov (Megaparsec); Bryan O'Sullivan, Ben Gamari (attoparsec); András Kovács (FlatParse)        |
| Category                  | Parser combinator (internal DSL, host-language-embedded)                                                                                 |
| Algorithm / grammar class | Recursive-descent **PEG-like predictive LL** with explicit backtracking; the choice operator is **left-biased / ordered**, not ambiguous |
| Lexing model              | Scannerless by default (token = `Char`/byte/`Token s`); optional combinator-built lexer layer (`Text.Megaparsec.Char.Lexer`)             |
| Latest release            | `parsec` 3.1.18.0 · `megaparsec` 9.8.1 · `attoparsec` 0.14.4 · `flatparse` 0.5.x                                                         |

> [!NOTE]
> This deep-dive treats four libraries as one lineage because they share a model and differ along one axis — **error quality vs. raw speed** ([summarised here](#design-philosophy)). **Parsec** is the 2001 original; **Megaparsec** is the modern, error-rich rewrite ([custom errors & bundles](#megaparsec-custom-errors-and-error-bundles)); [attoparsec](#attoparsec-incremental-and-fast) trades error messages for speed and incremental input; [FlatParse](#flatparse-forgoing-the-transformer-stack) drops the monad-transformer machinery entirely for bytestring throughput. All four descend from [monadic parsing][theory-top-down] as set out by Hutton & Meijer.

---

## Overview

### What it solves

A **parser generator** (`yacc`/[Bison][bison], [ANTLR][antlr], [Menhir][menhir]) consumes a grammar in a separate DSL and emits parsing code in a build step. A **parser combinator** library takes the opposite stance: there is no separate grammar language and no code-generation step. A parser is a first-class value of the host language; bigger parsers are built from smaller ones with ordinary functions ("combinators"), so the full power of Haskell — `let`, recursion, higher-order functions, type classes — is available _inside_ the grammar. Hutton & Meijer open their tutorial on exactly this point ([`monparsing.pdf` §1][hutton-meijer]):

> _"In functional programming, a popular approach to building recursive descent parsers is to model parsers as functions, and to define higher-order functions (or combinators) that implement grammar constructions such as sequencing, choice, and repetition. … the method has the advantage over functional parser generators such as Ratatosk … and Happy … that one has the full power of a functional language available to define new combinators for special applications."_

Leijen & Meijer's Parsec paper frames the production problem the combinators had to solve. Earlier combinator libraries were elegant but unusable at scale — they leaked space and gave useless errors ([`parsec-paper-letter.pdf`, Abstract][parsec-paper]):

> _"Despite the long list of publications on parser combinators, there does not yet exist a monadic parser combinator library that is applicable in real world situations. In particular naive implementations of parser combinators are likely to suffer from space leaks and are often unable to report precise error messages in case of parse errors. The Parsec parser combinator library described in this paper, utilizes a novel implementation technique for space and time efficient parser combinators that in case of a parse error, report both the position of the error as well as all grammar productions that would have been legal at that point in the input."_

The two named problems — **space leaks** and **bad errors** — are solved by one design decision: restrict the default to **predictive LL parsing with one-token lookahead** and make backtracking _opt-in_. That decision (the `try` combinator, [below](#the-try-combinator-restoring-arbitrary-lookahead)) is the conceptual heart of the whole lineage.

### Design philosophy

The lineage starts from the **list-of-successes** model and then deliberately narrows it. Hutton & Meijer define a parser as a function returning _all_ ways the input can be parsed ([`monparsing.pdf` §2.1][hutton-meijer]):

> _"a parser might fail on its input string. Rather than just reporting a run-time error if this happens, we choose to have parsers return a list of pairs … with the convention that the empty list denotes failure of a parser, and a singleton list denotes success … Returning a list of results opens up the possibility of returning more than one result if the input string can be parsed in more than one way, which may be the case if the underlying grammar is ambiguous."_

```haskell
-- Hutton & Meijer 1996, the canonical combinator-parser type:
type Parser a = String -> [(a, String)]
```

Parsec **rejects** that generality. A list-of-successes parser is non-deterministic and gives no useful error, because "the parsers can always look arbitrarily far ahead in the input (they are LL(∞)) and it becomes hard to decide what the error message should be" ([§2.4][parsec-paper]). Parsec instead commits to one parse, left-biased, with limited lookahead ([§2.4][parsec-paper]):

> _"It is for the two reasons above that in Parsec we restrict ourselves to predictive parsers with limited lookahead. The `<|>` combinator is left-biased and will return the first succeeding parse tree (i.e. even if the grammar is ambiguous only one parse tree is returned). The Parsec combinators will report all possible causes of an error."_

This places the family squarely in the **ordered-choice, predictive, recursive-descent** camp — conceptually adjacent to [PEG / packrat parsers][theory-peg] (ordered choice, no ambiguity, scannerless), but _without_ packrat memoization, and _with_ a uniquely careful error-message machinery built on the consumed/empty distinction. The members then make different trade-offs along the single axis of **error quality vs. throughput**:

| Member         | Stance                                                             | Sweet spot                                                         |
| -------------- | ------------------------------------------------------------------ | ------------------------------------------------------------------ |
| **Parsec**     | The original; good errors, `String`/`Text`/`ByteString`            | General-purpose; the baseline everyone learned                     |
| **Megaparsec** | Modern rewrite; **best** errors, custom error types, error bundles | Source code & human-readable text where error quality matters most |
| **attoparsec** | Drops errors for speed + **incremental** input                     | Network protocols, log/binary formats, streaming partial input     |
| **FlatParse**  | Drops the transformer stack for raw bytestring throughput          | Lexers/parsers where every nanosecond and allocation counts        |

Megaparsec states the balance explicitly in its synopsis ([`megaparsec.cabal` / Hackage][mega-hackage]):

> _"This is an industrial-strength monadic parser combinator library. Megaparsec is a feature-rich package that tries to find a nice balance between speed, flexibility, and quality of parse errors."_

---

## How it works

### The parser as a function from input to result

Every member begins from the same idea: a parser is a function from an input state to a result. The naive Hutton–Meijer type (`String -> [(a, String)]`) is a list-of-successes; Parsec's production type wraps the result in a **consumption tag** so the choice operator can be made predictive. From the paper ([§3][parsec-paper]):

```haskell
-- Parsec paper §3 (simplified core; the real library is parameterised
-- over the input type and a user-definable state):
type Parser a   = String -> Consumed a

data Consumed a = Consumed (Reply a)     -- input was consumed
                | Empty    (Reply a)      -- no input consumed

data Reply a    = Ok a String            -- success: value + remaining input
                | Error                   -- failure
```

The `Consumed`/`Empty` distinction is the load-bearing invention. "A parser has either `Consumed` input or returned a value without consuming input, `Empty`" ([§3][parsec-paper]). It is what lets the choice operator decide, in O(1), whether it is allowed to backtrack.

### Core abstractions and types

| Concept               | Parsec / Megaparsec                                                        | Role                                                                   |
| --------------------- | -------------------------------------------------------------------------- | ---------------------------------------------------------------------- |
| The parser type       | `ParsecT e s m a` (monad transformer); `Parsec e s = ParsecT e s Identity` | A parser over stream `s`, custom-error `e`, base monad `m`, result `a` |
| Sequencing            | `>>=` (`Monad`), `<*>` (`Applicative`), `do`-notation                      | Run one parser, then the next; bind threads the result through         |
| Ordered choice        | <code>&lt;&#124;&gt;</code> (`Alternative`)                                | Try the left parser; on _empty_ failure, try the right                 |
| Lookahead / backtrack | `try`, `lookAhead`, `notFollowedBy`                                        | `try p` makes `p`'s consumed-failure look like an empty failure        |
| Repetition            | `many`, `some`, `manyTill`, `sepBy`, `count`                               | Kleene star/plus and friends, all derived from choice                  |
| Labelling             | `<?>` / `label`                                                            | Replace low-level "expected" sets with a grammar-production name       |
| Single token          | `satisfy`, `token`, `char`, `anySingle`                                    | Consume one token if a predicate holds                                 |
| Custom failure        | `fail`, `customFailure`, `fancyFailure`, `region`                          | Inject domain errors into the error type `e`                           |
| Error value           | `ParseError s e`, `ParseErrorBundle s e`                                   | A position + expected/unexpected sets, or a bundle of many             |

### The choice operator does not backtrack once input is consumed

This is the single most important — and most surprising — semantic fact about the lineage. By default, `p <|> q` runs `q` **only if `p` failed without consuming any input**. If `p` consumed input and _then_ failed, the whole `p <|> q` fails. From the paper ([§3][parsec-paper]):

> _"An LL(1) parser has a lookahead of a single token – it can always decide which alternative to take based on the current input character. In practice this means that the parser `(p <|> q)` never tries parser `q` whenever parser `p` has consumed any input."_

Megaparsec's tutorial makes the consequence concrete ([Karpov, _Megaparsec tutorial_][mega-tutorial]):

> _"An important detail here is that `(<|>)` did not even try `bar` because `foo` has consumed some input! … This is done for performance reasons and because it would make no sense to run `bar` feeding it leftovers of `foo` anyway."_

The mechanism is visible directly in Megaparsec's continuation-passing implementation. `ParsecT` is a newtype taking **four continuations** — one for each cell of the consumed×success matrix ([`Text.Megaparsec.Internal`][mega-internal]):

```haskell
newtype ParsecT e s m a = ParsecT
  { unParser ::
      forall b. State s e
      -> (a -> State s e -> Hints (Token s) -> m b)  -- consumed-ok
      -> (ParseError s e -> State s e -> m b)        -- consumed-error
      -> (a -> State s e -> Hints (Token s) -> m b)  -- empty-ok
      -> (ParseError s e -> State s e -> m b)        -- empty-error
      -> m b
  }
```

The `Alternative` instance (`pPlus`) wires the second branch in **only as the first branch's `empty-error` continuation** ([`Text.Megaparsec.Internal`, `pPlus`][mega-internal]):

```haskell
pPlus m n = ParsecT $ \s cok cerr eok eerr ->
  let meerr err ms =
        let ncerr err' s' = cerr (err' <> err) (longestMatch ms s')
            neok x s' hs   = eok x s' (toHints (stateOffset s') err <> hs)
            neerr err' s'  =
              let combinedErr = combineErrors (stateOffset s) err err'
               in eerr combinedErr (longestMatch ms s')
         in unParser n s cok ncerr neok neerr
   in unParser m s cok cerr eok meerr
```

Note that `m` (the left parser) is run with the _original_ `cerr` (consumed-error) continuation, so a consumed failure of `m` propagates straight out — `n` is reached only through `meerr`, the empty-error path. This is the CPS realisation of the paper's case analysis, where `Empty Error -> (q input)` but `consumed -> consumed` ([§3][parsec-paper]).

### The `try` combinator: restoring arbitrary lookahead

Because the default is LL(1), a grammar that genuinely needs to look two or more tokens ahead at a decision point cannot use a bare `<|>`. The remedy is `try`, which the paper introduces as the _dual_ of the cut combinators in earlier work — instead of marking where lookahead is _not_ needed, it marks where arbitrary lookahead _is_ allowed ([§3.4][parsec-paper]):

> _"The `(try p)` parser behaves exactly like parser `p` but pretends it hasn't consumed any input when `p` fails. … Consider the parser `(try p <|> q)`. Even when parser `p` fails while consuming input (`Consumed Error`), the choice operator will try the alternative `q` since the `try` combinator has changed the `Consumed` constructor into `Empty`. Indeed, if you put `try` around all parsers you will have an LL(∞) parser again!"_

In Megaparsec's CPS encoding, `pTry` simply re-routes the consumed-error continuation to the empty-error continuation **and resets the state to the saved `s`** ([`Text.Megaparsec.Internal`, `pTry`][mega-internal]):

```haskell
pTry :: ParsecT e s m a -> ParsecT e s m a
pTry p = ParsecT $ \s cok _ eok eerr ->
  let eerr' err _ = eerr err s
   in unParser p s cok eerr' eok eerr'
```

The classic motivating example is a keyword-vs-identifier clash. Parsing `"letter"` with `string "let" *> ... <|> identifier` fails, because `string "let"` consumes `l`, `e`, `t` before discovering that what follows is not what `let` expected; the consumed failure forbids the `identifier` branch. `try (string "let")` fixes it ([§3.5][parsec-paper]):

```haskell
-- §3.5: without `try`, "letter" fails on the `let` branch having consumed "let".
expr =   do{ try (string "let"); whiteSpace; letExpr }
     <|> identifier
```

> [!IMPORTANT]
> `try` is the family's defining ergonomic trade-off. It restores the expressive power of unlimited lookahead, but **overusing it destroys both performance and error quality**: a `try` that wraps a large parser discards all the consumed-input progress (and its accumulated error position) on failure, so errors revert to the start of the `try`. Megaparsec's docs and Karpov's tutorial repeatedly advise wrapping `try` as tightly as possible — ideally around a single token or keyword.

### How good error messages emerge from consumed/empty

The consumed/empty machinery is also what makes the errors good. The paper extends `Reply` so that **even successful (`Ok`) replies carry an error message** — the message that _would_ have been reported had this branch not succeeded — so the choice operator can merge "expected" sets across alternatives that all start at the same position ([§4][parsec-paper]):

```haskell
data Reply a = Ok a State Message    -- success STILL carries the would-be error
             | Error Message

data Message = Message Pos String [String]  -- position, unexpected input, expected (first-set)
```

> _"To dynamically compute the first set, not only `Error` replies but also `Ok` replies should carry an error message. Within the `Ok` reply, the message represents the error that would have occurred if this successful alternative wasn't taken."_ ([§4][parsec-paper])

The `<?>` (label) combinator then rewrites a parser's _empty_ "expected" set to a single grammar-production name, but — crucially — only when no input was consumed, "since otherwise it wouldn't be something that is expected after all" ([§4.2][parsec-paper]). The result is messages like:

```text
parse error at (line 1,column 1):
unexpected "@"
expecting letter, digit or '_'
```

Megaparsec keeps the same model but reifies it into a real error _type_ with a custom slot. Its internal result is a clean three-part record ([`Text.Megaparsec.Internal`][mega-internal]):

```haskell
data Reply e s a = Reply (State s e) Consumption (Result s e a)
data Consumption = Consumed | NotConsumed
data Result s e a = OK (Hints (Token s)) a | Error (ParseError s e)
```

### Megaparsec: custom errors and error bundles

Megaparsec's two headline improvements over Parsec both live in the error type. First, **custom error components**: the `e` type parameter of `ParsecT e s m a` is an "extension slot" for arbitrary domain errors, injected via `fancyFailure`/`customFailure` and rendered via the `ShowErrorComponent` class ([Karpov, _Megaparsec tutorial_][mega-tutorial]):

> _"The `ErrorCustom` is a sort of an 'extension slot' which allows to embed arbitrary data into the `ErrorFancy` type. … `customFailure = fancyFailure . E.singleton . ErrorCustom`"_

Second, **parse-error bundles**: every top-level run returns a `ParseErrorBundle`, which can hold _several_ `ParseError`s (the basis of error recovery, below) and is pretty-printed by one pass over the input so each error is shown with its offending source line ([Karpov, _Megaparsec tutorial_][mega-tutorial]):

> _"All parser-running functions return `ParseErrorBundle` with a correctly set `bundlePosState` and a collection [of] `ParseError`s inside. … `errorBundlePretty` allows efficient display by doing a single pass over the input stream."_

### attoparsec: incremental and fast

attoparsec keeps the combinator model but **throws out the consumed/empty error machinery** and **adds incremental input**. Its result type is a three-way `IResult` whose `Partial` constructor is a continuation awaiting more input ([`Data.Attoparsec.ByteString`][atto-bytestring]):

```haskell
data IResult i r
  = Fail i [String] String       -- unconsumed input, contexts, message
  | Partial (i -> IResult i r)   -- feed more input to resume; "" means EOF
  | Done i r                     -- unconsumed input, result

parse :: Parser a -> ByteString -> Result a
feed  :: Monoid i => IResult i r -> i -> IResult i r
```

The design target is streaming network/file data, where the whole input is not in memory at once ([`Data.Attoparsec.ByteString`][atto-bytestring]):

> _"attoparsec supports incremental input, meaning that you can feed it a bytestring that represents only part of the expected total amount of data to parse. If your parser reaches the end of a fragment of input and could consume more input, it will suspend parsing and return a `Partial` continuation. … To indicate that you have no more input, supply the `Partial` continuation with an empty bytestring."_

The second deliberate divergence is backtracking: **attoparsec alternatives always backtrack**. There is no consumed/empty distinction, so the `try` combinator exists only for source-compatibility and is a no-op ([`Data.Attoparsec.ByteString`][atto-bytestring]):

> _"This combinator is provided for compatibility with Parsec. attoparsec parsers always backtrack on failure."_

That is the trade attoparsec makes for speed — and it openly admits the cost in error quality ([`Data.Attoparsec.ByteString`][atto-bytestring]):

> _"Parsec parsers can produce more helpful error messages than attoparsec parsers. This is a matter of focus: attoparsec avoids the extra book-keeping in favour of higher performance."_

### FlatParse: forgoing the transformer stack

[FlatParse][flat-repo] is the throughput extreme. It keeps ordered-choice combinators but abandons the `ParsecT`-style monad-transformer representation; it parses **raw machine addresses into a pinned, contiguous strict `ByteString`**, returns results unboxed, and avoids intermediate allocation. Its failure/error split mirrors Parsec's consumed/empty distinction but states it as two _separate_ notions ([`README.md`][flat-readme]):

> _"The idea is that parser failure is distinguished from parsing error. The former is used for control flow, and we can backtrack from it. The latter is used for unrecoverable errors, and by default it's propagated to the top."_

It ships two flavours: `FlatParse.Basic` (no built-in state) and `FlatParse.Stateful` (a built-in `Int` of state plus a custom reader environment, for indentation-sensitive parsing) ([`README.md`][flat-readme]). It claims, and benchmarks, a 2–10× edge:

> _"On microbenchmarks, flatparse is 2-10 times faster than attoparsec or megaparsec."_ ([`README.md`][flat-readme])

---

## Algorithm & grammar class

All four are **recursive-descent, top-down, ordered-choice** parsers — see [Top-down & combinator parsing][theory-top-down]. The formalism is **predictive LL parsing with one token of lookahead by default**, escalated to **LL(∞) on demand** via `try`. Crucially, the choice operator is _committed and left-biased_, so the practical grammar class is closer to a [Parsing Expression Grammar][theory-peg] than to a classical context-free grammar:

- **No ambiguity.** Because `<|>` returns the first success and never enumerates all parses, ambiguous grammars simply resolve to whichever alternative is written first. The paper makes this an explicit non-goal: "In practice however, you hardly ever need to deal with ambiguous grammars. In fact it is often more a nuisance than a help." ([§2.3][parsec-paper]). Contrast [GLR/Earley general parsers][theory-general], which _do_ return parse forests.
- **No left recursion.** Like every recursive-descent scheme, a left-recursive production loops forever: "The first thing a left-recursive parser would do is to call itself, resulting in an infinite loop." ([§2.2][parsec-paper]). Left recursion must be rewritten to right recursion or captured by `chainl`/`makeExprParser`.
- **Context-sensitive power.** Because sequencing is **monadic** (`>>=`), the second parser can depend on the _runtime result_ of the first, so the combinators parse context-sensitive languages — strictly more than the arrow/applicative style, which "can at most parse languages that can be described by a context-free grammar." ([§2.1][parsec-paper]). The textbook example is closing an XML tag with the name read from its open tag.
- **Scannerless by default.** The token type is the stream element (`Char`, a byte, or a user `Token s`); there is no separate lexer phase. A lexer _layer_ is optional and itself built from combinators (`Text.Megaparsec.Char.Lexer`'s `lexeme`/`space`/`symbol`). This is the same scannerless stance as [PEG tools][theory-peg] and [tree-sitter][tree-sitter], and unlike the two-phase [Bison/flex][bison] or [ANTLR][antlr] pipelines.

Unlike [packrat parsers][theory-peg], the lineage performs **no memoization**: a `try`-heavy grammar can revisit the same input position many times, giving worst-case super-linear behaviour. This is a deliberate trade — packrat's linear-time guarantee costs O(n) memory, whereas Parsec's predictive default is near-linear in practice while staying allocation-frugal.

## Interface & composition model

The interface is an **internal DSL** — there is no external grammar file and no generator. A grammar _is_ a Haskell value, composed with the standard type-class operators:

```haskell
-- A Megaparsec expression parser, written entirely in host Haskell.
pTerm :: Parser Expr
pTerm = choice
  [ parens pExpr
  , IntLit <$> integer
  , Var    <$> identifier
  ] <?> "term"

pExpr :: Parser Expr
pExpr = makeExprParser pTerm operatorTable   -- precedence climbing, from a table
```

- **AST/CST construction is explicit and host-native.** There is no implicit tree; the parser writer maps results into their own data types with `<$>`/`<*>`/`do`. This is maximally flexible (build any value, including effectful actions in the base monad `m`) but means **no tree is produced for free**, unlike [tree-sitter][tree-sitter]'s automatic CST.
- **Host-language integration is total.** Parsers are values: stored in lists, generated by functions, parameterised over other parsers, abstracted behind type classes. `makeExprParser` (operator-precedence parsing, see [Pratt / precedence climbing][theory-pratt]) is itself just a combinator that consumes a table of operators.
- **Repetition and choice are derived, not primitive.** `many`, `some`, `sepBy`, `manyTill`, `optional` are all defined in terms of `<|>` and `>>=`; a user can write new ones the same way. This open-endedness is the combinator model's central selling point ([Hutton & Meijer §1][hutton-meijer]).
- **Streams are abstracted by a type class.** Megaparsec's `Stream` class lets `String`, strict/lazy `Text`, strict/lazy `ByteString`, and custom token streams all be parsed by the same combinators; attoparsec specialises to `ByteString`/`Text`; FlatParse specialises to strict `ByteString`.

## Performance

The lineage's performance story is the consumed/empty design plus laziness. The paper's core claim is that the `Consumed` constructor is returned _eagerly_ (before the final reply value is known), so the choice combinator can commit and **release the input it was holding** — fixing the space leak that sank earlier libraries ([§3.1][parsec-paper]):

> _"Due to laziness, a parser `(p >>= f)` directly returns with a `Consumed` constructor if `p` consumes input. The computation of the final reply value is delayed. This 'early' returning is essential for the efficient behavior of the choice combinator. … It no longer holds on to the original input, fixing the space leak of the previous combinators."_

- **Time complexity.** Near-linear on LL(1)-shaped grammars (each token examined O(1) times). `try`-heavy grammars degrade toward the cost of the backtracking they request; there is **no packrat memoization** to bound re-scanning, so a pathological grammar can be super-linear.
- **Bulk combinators.** Megaparsec adds `tokens`, `takeWhileP`, `takeWhile1P`, `takeP` that operate on whole spans of the stream rather than token-by-token. The Hackage description quantifies it: `tokens` is "about 100 times faster than matching a string token by token" and the `takeWhile` family "about 150 times faster" ([Hackage][mega-hackage]).
- **attoparsec's posture.** attoparsec is the speed/streaming choice in the Parsec family: zero-copy `ByteString` slicing, no error book-keeping, and incremental `Partial` continuations make it the standard for network protocols and large file formats ([synopsis][atto-hackage]: _"aimed particularly at dealing efficiently with network protocols and complicated text/binary file formats"_).
- **FlatParse and the transformer cost.** FlatParse's published microbenchmarks (GHC 9.10, `-O2 -fllvm`) put hard numbers on the overhead the `ParsecT` transformer stack carries ([`README.md`][flat-readme]):

  | benchmark      | FlatParse Basic | FlatParse Stateful | attoparsec | megaparsec | parsec  |
  | -------------- | --------------- | ------------------ | ---------- | ---------- | ------- |
  | `sexp`         | 1.80 ms         | 1.25 ms            | 10.2 ms    | 6.92 ms    | 39.9 ms |
  | `long keyword` | 0.054 ms        | 0.062 ms           | 0.308 ms   | 0.687 ms   | 3.50 ms |
  | `numeral csv`  | 0.540 ms        | 0.504 ms           | 3.17 ms    | 1.09 ms    | 13.8 ms |

  On `sexp`, FlatParse Basic is ~3.8× faster than Megaparsec and ~5.7× faster than attoparsec; on `long keyword` the gap to Parsec is ~65×. FlatParse achieves this by parsing raw machine addresses with no transformer indirection and returning unboxed results — "pure validators … in flatparse are not difficult to implement with zero heap allocation." ([`README.md`][flat-readme]).

- **No SIMD / data-parallelism.** None of the four uses SIMD or data-parallel scanning; they are scalar, sequential, recursive-descent engines. For SIMD-accelerated parsing see [simdjson][simdjson] — a different point in the design space entirely.

## Error handling & recovery

This is the dimension that most separates the members, and it traces directly back to the consumed/empty design.

- **Parsec / Megaparsec: precise positional errors with expected-sets.** As [shown above](#how-good-error-messages-emerge-from-consumedempty), the choice operator merges "expected" first-sets across same-position alternatives, and `<?>`/`label` lifts them to grammar-production names. Megaparsec adds typed custom errors (`e`), `errorBundlePretty` with source-line context, and multi-error bundles.
- **Error recovery (Megaparsec only).** Megaparsec can **recover from a parse error and keep going**, collecting several errors per run via `withRecovery` and the `ParseErrorBundle`. Its Hackage description states: _"Megaparsec can recover from parse errors 'on the fly' and continue parsing."_ ([Hackage][mega-hackage]). This is real, but coarse compared with a [GLR][theory-general] or [tree-sitter][tree-sitter] error-recovery node; the parser writer must place recovery points explicitly.
- **Incremental reparsing — essentially absent.** None of the four does **incremental \_re_parsing** (re-using a prior parse tree across edits) the way [tree-sitter][tree-sitter] does. attoparsec's `Partial`/`feed` is incremental _input_ (streaming bytes), not incremental _editing_; feeding more input resumes a suspended parse, it does not patch a tree. So for IDE-grade, edit-and-reparse workloads the lineage is **not IDE-ready** — a finding, not an omission: the model is a one-shot function from input to result, with no persistent, position-indexed parse state to mutate.
- **attoparsec: deliberately weak errors.** As quoted [above](#attoparsec-incremental-and-fast), attoparsec trades error quality for throughput; its `Fail` carries only a context stack and a flat message string, with no expected-set merging.
- **FlatParse: errors as control flow.** FlatParse's failure/error split ([above](#flatparse-forgoing-the-transformer-stack)) gives the parser writer manual control: cheap, backtrackable _failure_ for control flow, and explicit _error_ for unrecoverable conditions propagated to the top — but the library provides no automatic expected-set machinery.

## Ecosystem & maturity

The lineage is among the **most battle-tested parsing infrastructure in any language ecosystem**, and the only realistic choice for parsing in Haskell.

- **Parsec** is distributed with GHC's boot libraries and underpins much of the Haskell toolchain itself: the **Cabal** package-description parser (`Cabal-syntax`, `ghc-lib-parser`) is built on it, and it has decades of reverse-dependencies on Hackage.
- **Megaparsec** is the modern default for new code and is the parsing engine behind a striking roster of production languages and tools: the **Dhall** configuration language, the **Idris** dependently-typed language (which migrated from Trifecta to Megaparsec for better errors and fewer dependencies), **hnix** (a Haskell reimplementation of the Nix language), the **hledger** accounting suite, **hadolint** (Dockerfile linter), and `language-docker`/`language-puppet`/`mmark`, among many others.
- **attoparsec** is the standard for high-throughput binary/text parsing in Haskell — used pervasively in `aeson`'s JSON parsing lineage, network-protocol libraries, and log/data ingestion where speed and streaming dominate.
- **FlatParse** is newer and more niche — the choice when raw throughput is paramount (compilers' lexers, hot-path data formats) and the parser writer is willing to forgo Megaparsec's ergonomics. Its author, András Kovács, uses it in dependently-typed-language prototypes where lexer speed matters.
- **Stability & ports.** All four are mature and actively maintained; Megaparsec in particular is meticulously versioned and documented (Karpov's tutorial is the de-facto manual). The combinator model itself is the most widely _ported_ idea in this whole catalog: it is the direct ancestor of [Rust's `nom`][rust-nom] and [`chumsky`][rust-chumsky], Scala's FastParse/cats-parse, Python's `parsy`, and dozens more — the "monadic parser combinator" is a cross-language design pattern that this Haskell lineage canonicalised.

---

## Strengths

- **Grammar is ordinary code.** No external DSL, no build-step generator; the full host language (recursion, `let`, higher-order functions, type classes) is available _inside_ the grammar.
- **Context-sensitive by construction.** Monadic `>>=` lets a later parser depend on an earlier result (the XML-tag example), exceeding the power of pure applicative/arrow combinators.
- **Excellent errors (Megaparsec).** Positional errors with merged expected-sets, custom typed error components, multi-error bundles, and source-line context — best-in-class for human-readable input.
- **Predictable, frugal default.** LL(1)-with-`try` keeps the common path near-linear and allocation-light; the consumed/empty design fixed the historical space leak.
- **Streaming + speed (attoparsec).** Incremental `Partial` input and zero-copy `ByteString` make it ideal for network protocols and large files.
- **Raw throughput (FlatParse).** 2–10× over attoparsec/Megaparsec by dropping the transformer stack and returning unboxed results.
- **The most-ported model in parsing.** Directly ancestral to `nom`, `chumsky`, FastParse, parsy, and many others.

## Weaknesses

- **No left recursion.** Left-recursive grammars loop forever and must be manually rewritten or routed through `chainl`/`makeExprParser`.
- **No ambiguity / no parse forests.** Ordered choice silently commits to the first alternative; you cannot enumerate all parses (use a [GLR/Earley][theory-general] tool for that).
- **`try` is a foot-gun.** Mis-scoped `try` silently breaks error messages (errors revert to the `try`'s start) and can cause exponential re-scanning; there is no memoization to bound it.
- **No incremental _reparsing_.** Not IDE-grade for edit-and-reparse; the model is a one-shot function with no persistent, mutable parse state (cf. [tree-sitter][tree-sitter]).
- **attoparsec's errors are poor.** A flat message + context stack, by design — unsuitable when humans must read the diagnostics.
- **Performance cliffs from laziness.** Naive use can still reintroduce space leaks (e.g. lazy accumulation in `many`); the careful `seq`-ing the paper relies on is easy to undo.
- **Manual AST construction.** No CST is produced for free; every node must be mapped by hand.

## Key design decisions and trade-offs

| Decision                                                                                | Rationale                                                                                                            | Trade-off                                                                                      |
| --------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| Predictive LL(1) default; <code>&lt;&#124;&gt;</code> does **not** backtrack on consume | Fixes the space leak and makes precise errors possible (no LL(∞) ambiguity about what was "expected")                | Multi-token-lookahead decisions need explicit `try`; surprising to newcomers                   |
| `try` as an explicit opt-in to arbitrary lookahead                                      | Keeps backtracking local and visible; lexer libraries can wrap each token in `try`                                   | Mis-scoped `try` degrades errors and performance; no memoization to bound re-scanning          |
| Monadic sequencing (`>>=`), not just applicative                                        | Enables context-sensitive grammars (parse depends on prior result)                                                   | Cannot statically analyse the grammar; precludes generator-style optimisation                  |
| `Ok` replies carry their would-be error message                                         | Lets <code>&lt;&#124;&gt;</code> merge expected-sets across same-position alternatives → rich "expecting …" messages | Extra book-keeping on the success path (the cost attoparsec refuses to pay)                    |
| Ordered, left-biased choice (no parse forests)                                          | Determinism, good errors, no exponential ambiguity blow-up                                                           | Ambiguous grammars resolve by source order; no all-parses enumeration                          |
| Scannerless by default, optional combinator lexer                                       | One language, no lexer/parser split; lexer is just more combinators                                                  | No automatic tokenisation; whitespace/keyword handling is the writer's job (`lexeme`/`symbol`) |
| Megaparsec: typed custom error component `e` + error bundles                            | Domain errors and multi-error recovery without abandoning the model                                                  | More type-machinery; slightly slower than attoparsec's bare path                               |
| attoparsec: drop errors, add `Partial`/incremental input                                | Maximum throughput + streaming for protocols/files                                                                   | Poor diagnostics; `try` is a no-op (always backtracks)                                         |
| FlatParse: abandon the `ParsecT` transformer stack                                      | 2–10× speed; unboxed results; near-zero allocation for validators                                                    | `ByteString`-only, little-endian, fewer ergonomics; manual error handling                      |

---

## Sources

- [`parsec-paper-letter.pdf` — Leijen & Meijer, _Parsec: Direct Style Monadic Parser Combinators For The Real World_ (2001)][parsec-paper] — the consumed/empty model, `try`, error-message machinery (§§2–4 quoted above)
- [`monparsing.pdf` — Hutton & Meijer, _Monadic Parsing in Haskell / Monadic Parser Combinators_ (1996)][hutton-meijer] — the list-of-successes `type Parser a = String -> [(a, String)]` model and the parser monad
- [`parsec` on Hackage][parsec-hackage] · [haskell/parsec source tree][parsec-repo]
- [`megaparsec` on Hackage][mega-hackage] · [mrkkrp/megaparsec source tree][mega-repo]
- [`Text.Megaparsec.Internal` — `ParsecT`, `pPlus`, `pTry`, `pLabel`, `Reply`/`Consumption`/`Result`][mega-internal]
- [Mark Karpov, _Megaparsec tutorial_ — consumed-vs-empty, `try`, custom errors, error bundles, lexer helpers][mega-tutorial]
- [`attoparsec` on Hackage][atto-hackage] · [`Data.Attoparsec.ByteString` — `IResult`, `parse`/`feed`, incremental input, "always backtrack"][atto-bytestring] · [haskell/attoparsec source tree][atto-repo]
- [`flatparse` on Hackage][flat-hackage] · [AndrasKovacs/flatparse `README.md` — failure-vs-error, benchmarks, Basic vs Stateful][flat-readme] · [source tree][flat-repo]
- Related deep-dives: [Top-down & combinator parsing][theory-top-down] · [PEG & packrat][theory-peg] · [Pratt / precedence][theory-pratt] · [General parsing (GLR/Earley)][theory-general] · [`nom` (Rust)][rust-nom] · [`chumsky` (Rust)][rust-chumsky] · [tree-sitter][tree-sitter] · [the parsing umbrella][index] · [the comparison capstone][comparison]

<!-- References -->

[index]: ./index.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[theory-top-down]: ./theory/top-down.md
[theory-peg]: ./theory/peg-packrat.md
[theory-pratt]: ./theory/pratt-precedence.md
[theory-general]: ./theory/general-parsing.md
[rust-nom]: ./rust-nom.md
[rust-chumsky]: ./rust-chumsky.md
[tree-sitter]: ./tree-sitter.md
[simdjson]: ./simdjson.md
[antlr]: ./antlr.md
[bison]: ./bison-yacc.md
[menhir]: ./menhir.md
[parsec-paper]: https://www.microsoft.com/en-us/research/wp-content/uploads/2016/02/parsec-paper-letter.pdf
[hutton-meijer]: https://people.cs.nott.ac.uk/pszgmh/monparsing.pdf
[parsec-hackage]: https://hackage.haskell.org/package/parsec
[parsec-repo]: https://github.com/haskell/parsec
[mega-hackage]: https://hackage.haskell.org/package/megaparsec
[mega-repo]: https://github.com/mrkkrp/megaparsec
[mega-internal]: https://hackage.haskell.org/package/megaparsec-9.7.0/docs/Text-Megaparsec-Internal.html
[mega-tutorial]: https://markkarpov.com/tutorial/megaparsec.html
[atto-hackage]: https://hackage.haskell.org/package/attoparsec
[atto-repo]: https://github.com/haskell/attoparsec
[atto-bytestring]: https://hackage.haskell.org/package/attoparsec-0.14.4/docs/Data-Attoparsec-ByteString.html
[flat-hackage]: https://hackage.haskell.org/package/flatparse
[flat-repo]: https://github.com/AndrasKovacs/flatparse
[flat-readme]: https://raw.githubusercontent.com/AndrasKovacs/flatparse/master/README.md
