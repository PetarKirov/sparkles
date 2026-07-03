# FParsec (F#)

The F#/.NET member of the [Parsec][parsec] lineage: a parser is again an ordinary host-language value — a function from an input stream to a reply — but FParsec re-engineers the model around a **mutable `CharStream`** for throughput and pairs it with the most carefully tuned **error-message machinery** of any combinator library, plus an embeddable, runtime-configurable [operator-precedence parser][pratt] component.

| Field                     | Value                                                                                                                        |
| ------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| Language                  | F# (with a C# performance core, `FParsecCS`)                                                                                 |
| License                   | Code: 2-clause BSD ("Simplified BSD"); docs: CC BY-NC 3.0; bundled Unicode data under the Unicode license                    |
| Repository                | [`stephan-tolksdorf/fparsec`][repo]                                                                                          |
| Documentation             | [quanttec.com/fparsec][site] (tutorial, user's guide, reference)                                                             |
| Key author                | Stephan Tolksdorf                                                                                                            |
| Category                  | Parser combinator (internal DSL, host-language-embedded), F#/.NET                                                            |
| Algorithm / grammar class | Recursive-descent **predictive LL(1)** with explicit opt-in backtracking (`attempt`); **infinite lookahead** on demand       |
| Error posture             | Rich `ErrorMessageList`; automatically generated, highly readable positional messages with expected/unexpected sets          |
| Expression engine         | Built-in `OperatorPrecedenceParser` — runtime-configurable prefix/infix/postfix/ternary operators with precedence + assoc.   |
| Stream / state model      | Mutable `CharStream<'u>` with a `StateTag`; threaded user state `'u`; three-valued `ReplyStatus` (`Ok`/`Error`/`FatalError`) |

> [!NOTE]
> Read [Parsec/Megaparsec/attoparsec][parsec] first — FParsec descends from Daan Leijen & Erik Meijer's Parsec and shares its core semantics (predictive LL, left-biased ordered choice, the consumed-vs-empty rule, expected-set error messages). This deep-dive concentrates on **what FParsec changed**: an imperative stream instead of an immutable functional state, `attempt` instead of `try`, a three-valued reply status, and a first-class operator-precedence component. Where Parsec's design decisions are unchanged they are noted briefly and cross-linked rather than re-derived.

---

## Overview

### What it solves

FParsec sets out to be Parsec for the .NET world, but with the two properties that matter most for real-world text parsing — **diagnostic quality** and **throughput** — pushed as far as the platform allows. The `readme.md` states the scope and the feature set plainly ([`readme.md`][repo-readme]):

> _"FParsec is a parser combinator library for F#. With FParsec you can implement recursive-descent text parsers for formal grammars."_

Its advertised feature list is a compact statement of its priorities ([`readme.md`][repo-readme]):

> _"FParsec's features include: support for context-sensitive, infinite look-ahead grammars, automatically generated, highly readable error messages, Unicode support, efficient support for very large files, an embeddable, runtime-configurable operator-precedence parser component, … an implementation thoroughly optimized for performance, … a permissive open source license."_

Every clause maps onto a concrete design decision covered below: **context-sensitive + infinite look-ahead** → threaded user state `'u` and `attempt`; **highly readable errors** → the `ErrorMessageList` machinery; **very large files** → the multi-block `CharStream`; **operator-precedence component** → `OperatorPrecedenceParser`; **optimized for performance** → the `FParsecCS` C# core and the mutable stream.

### Design philosophy

FParsec keeps Parsec's conceptual model — grammar-as-code, no external DSL, no generator — and re-implements it imperatively. Where the Parsec paper threads an **immutable** parser state and tags each result with a `Consumed`/`Empty` marker, FParsec passes a **single mutable `CharStream`** through every parser and records "did this parser consume input" by comparing a monotonically increasing `StateTag` before and after ([`CharStream.cs`][cs-charstream]):

> _"Any CharStream method or property setter increments this value when it changes the CharStream state. Backtracking to an old state also restores the old value of the StateTag."_

This is the load-bearing re-engineering. It buys the raw speed of pointer-walking a UTF-16 buffer while preserving the semantics that make Parsec's errors good — a parser that has advanced the `StateTag` is treated exactly as Parsec's "consumed input" case, so [`<|>`](#ordered-choice-and-the-consumed-input-rule) and [`attempt`](#attempt-explicit-opt-in-backtracking) behave identically to their Parsec counterparts while operating on mutable state. The cost is that backtracking is no longer free: FParsec must explicitly snapshot and restore stream indices, which is why `attempt` and the `?`-suffixed combinators exist as first-class primitives.

The second pillar is **error quality as a first-class engineering goal**, not a by-product. FParsec ships an entire C# subsystem (`ErrorMessageList`, `ErrorMessage`, `ParserError`, `Position`) devoted to accumulating, de-duplicating, sorting, and pretty-printing expected/unexpected sets with a source-line excerpt and a `^`-marker under the offending column.

---

## How it works

### The parser type: a function over a mutable stream

FParsec's parser type is deceptively close to Parsec's, but the difference is decisive ([`Primitives.fsi`][fsi-primitives]):

```fsharp
/// The type of the parser functions supported by FParsec combinators.
type Parser<'Result, 'UserState> = CharStream<'UserState> -> Reply<'Result>
```

A parser is a function from a **mutable** `CharStream<'u>` to a `Reply<'Result>`. Contrast Parsec, whose `ParsecT e s m a` threads an immutable `State s e` and returns it (or a saved copy) in each of four continuations. FParsec has no continuation-passing matrix: a parser simply advances (or does not advance) the shared stream and returns a small struct.

The `Reply<'T>` is a plain three-field value type — result, error list, and status ([`Reply.cs`][cs-reply]):

```csharp
public struct Reply<TResult> : IEquatable<Reply<TResult>> {
    public ErrorMessageList Error;
    public TResult     Result;
    public ReplyStatus Status;
}
```

`ReplyStatus` is **three-valued**, a refinement over Parsec's binary success/failure ([`Reply.cs`][cs-reply]):

```csharp
public enum ReplyStatus {
    Ok         =  1,
    Error      =  0,
    FatalError = -1
}
```

`FatalError` is FParsec's own addition: _"The parser failed and no error recovery (except after backtracking) should be tried."_ ([`Primitives.fsi`][fsi-primitives]). It lets a parser signal an unrecoverable error (via [`failFatally`](#error-handling--recovery)) that ordinary `<|>` choice will _not_ paper over — only an explicit `attempt`/backtracking construct will. This is the FParsec analogue of FlatParse's failure-vs-error split, folded into the reply status itself.

### Ordered choice and the consumed-input rule

`<|>` is left-biased ordered choice with exactly Parsec's consumed-input semantics, restated in terms of the mutable stream ([`Primitives.fsi`][fsi-primitives]):

> _"The parser `p1 <|> p2` first applies the parser `p1`. If `p1` succeeds, the result of `p1` is returned. If `p1` fails with a non-fatal error and *without changing the parser state*, the parser `p2` is applied. Note: The stream position is part of the parser state, so if `p1` fails after consuming input, `p2` will not be applied."_

"Without changing the parser state" is the `StateTag` check: if `p1` advanced the stream (bumped the tag) and then failed, `p1 <|> p2` fails outright — it does not rewind and try `p2`. This is [the single most important semantic fact of the whole lineage][parsec-consumed], reproduced faithfully. `choice ps` is the optimized _n_-ary form, and `<|>%` supplies a default value.

### `attempt`: explicit opt-in backtracking

Because the default is LL(1)-with-committed-choice, multi-token lookahead needs an explicit backtracking marker. FParsec calls it **`attempt`** (Parsec's `try`) ([`Primitives.fsi`][fsi-primitives]):

> _"The parser `attempt p` applies the parser `p`. If `p` fails after changing the parser state or with a fatal error, `attempt p` will backtrack to the original parser state and report a non-fatal error."_

Two things are notable. First, `attempt` catches **both** a consumed failure _and_ a `FatalError`, downgrading either to a plain backtrackable `Error` — so it is the one construct that overrides `failFatally`. Second, because backtracking on a mutable stream requires physically restoring saved indices, FParsec provides a family of **fused backtracking combinators** so users rarely wrap a whole parser in `attempt` ([`Primitives.fsi`][fsi-primitives]):

| Combinator  | Behaviour                                                                                             |
| ----------- | ----------------------------------------------------------------------------------------------------- |
| `p >>=? f`  | Like `p >>= f`, but backtracks to the start if the parser returned by `f` fails **without** consuming |
| `p >>? q`   | Like `p >>. q`, but backtracks to the start if `q` fails without consuming, even if `p` consumed      |
| `p .>>? q`  | Like `p .>> q` with the same conditional backtracking                                                 |
| `p .>>.? q` | Like `p .>>. q` with the same conditional backtracking                                                |

These express "commit only after the second parser has also matched" without discarding error position the way a coarse `attempt (p >>. q)` would — the FParsec answer to Parsec's ["`try` is a foot-gun; scope it tightly"][parsec-try] advice, baked into named operators. `followedBy`/`notFollowedBy`/`lookAhead` round out the zero-width lookahead set (`lookAhead p` parses `p` then restores the original state).

### Threaded user state for context-sensitive grammars

The `'u` type parameter is a **user state** carried _on the stream itself_. Parsec offers user state too, but FParsec's is a mutable field read and written in place ([`CharParsers.fsi`][fsi-charparsers]):

```fsharp
/// getUserState is equivalent to `fun stream -> Reply(stream.UserState)`.
val getUserState: Parser<'u,'u>
/// setUserState u is equivalent to `fun stream -> stream.UserState <- u; Reply(())`.
val setUserState: 'u -> Parser<unit,'u>
/// updateUserState f is equivalent to `fun stream -> stream.UserState <- f stream.UserState; Reply(())`.
val updateUserState: ('u -> 'u) -> Parser<unit,'u>
```

Combined with monadic sequencing (`>>=` / the `parse { … }` computation expression), this is what "context-sensitive grammars" in the feature list means: a later parser can branch on state accumulated by an earlier one (indentation stacks, symbol tables, mode flags). Because the state lives on the stream, backtracking correctly restores it — `attempt` and `lookAhead` rewind `UserState` along with the position.

### `ErrorMessageList`: the diagnostic engine

The reason FParsec's errors read well is a dedicated, immutable, singly-linked error structure with a rich message taxonomy. `ErrorMessage` carries a `Type` from a ten-way enum ([`ErrorMessage.cs`][cs-errormessage]):

```csharp
public enum ErrorMessageType {
    Expected, ExpectedString, ExpectedCaseInsensitiveString,
    Unexpected, UnexpectedString, UnexpectedCaseInsensitiveString,
    Message, NestedError, CompoundError, Other
}
```

Each variant is a subclass (`Expected` with a `Label`, `ExpectedString`, `NestedError` carrying a `Position` + `UserState` + nested `ErrorMessageList`, `CompoundError`, …). `ErrorMessageList` is a `Head`/`Tail` cons-list with a `Merge` that prepends one list onto another ([`ErrorMessageList.cs`][cs-errormessagelist]):

```csharp
public sealed class ErrorMessageList : IEquatable<ErrorMessageList> {
    public readonly ErrorMessage Head;
    public readonly ErrorMessageList Tail;

    public static ErrorMessageList Merge(ErrorMessageList list1, ErrorMessageList list2) { … }
}
```

Two design points give the "highly readable" output. First, comparison and printing go through `ToHashSet`/`ToSortedArray`, which **de-duplicate** the accumulated messages and sort them into a stable order before rendering — so an "expecting a, b or c" line never repeats an alternative or reorders it run-to-run ([`ErrorMessageList.cs`][cs-errormessagelist]). Second, the combinator vocabulary for building these lists is exposed directly (`expected`, `unexpected`, `messageError`, `nestedError`, `compoundError`, `mergeErrors` in [`Error.fsi`][fsi-error]), so labelling parsers (`<?>`, `<??>`) and custom `fail` messages slot into the same machinery. `<?>` replaces a non-consuming parser's expected-set with a single grammar-production label — exactly Parsec's `<?>`, here operating on the `ErrorMessageList`.

The user-facing payoff is `ParserError.ToString(streamWhereErrorOccurred)`, which augments each error position with _"the line of text surrounding the error position, together with a '^'-marker pointing to the exact location of the error in the input stream"_ ([`Error.fsi`][fsi-error]). The `run` functions return this pre-rendered ([`CharParsers.fsi`][fsi-charparsers]):

```fsharp
type ParserResult<'Result,'UserState> =
     | Success of 'Result * 'UserState * Position
     | Failure of string * ParserError * 'UserState   // string is the pretty-printed error
```

### The mutable `CharStream`

`CharStream<'u>` is the imperative heart. It _"Provides read-access to a sequence of UTF-16 chars"_ ([`CharStream.cs`][cs-charstream]) and, in the default (non-"Low-Trust") build, walks the buffer through **`unsafe` pointers** (`char* Ptr`) for speed. The `readme.md`'s "efficient support for very large files" is delivered here: the stream is **block-structured**, loading fixed-size blocks of a byte stream on demand with an overlap region for integrity checking, so a multi-gigabyte file is parsed without materializing it in memory. Positions are handed out as opaque `CharStreamIndexToken` values, and backtracking is a `Seek` back to a saved index that also restores the `StateTag`, line, and line-begin bookkeeping.

FParsec ships in two flavours, reflected in the parallel `FParsec.sln` / `FParsec-LowTrust.sln` solutions and the `#if !LOW_TRUST` blocks: the default pointer-based build, and a **Low-Trust** build (`CharStreamLT.cs`) that uses only verifiable managed code for environments that forbid `unsafe`, trading some speed for portability.

### The `FParsecCS` performance core

FParsec is a **two-assembly** design: the F# combinator surface (`FParsec/`, e.g. `Primitives.fs`, `CharParsers.fs`) sits on top of a C# core (`FParsecCS/`) that implements everything performance-critical — `CharStream`, `Reply`, the whole `ErrorMessage*` hierarchy, `OperatorPrecedenceParser`, the `NumberLiteral`/`HexFloat` scanners, `CharSet`, and identifier validation. The split is deliberate: C# gives precise control over struct layout, `unsafe` pointers, and low-level loops that F# does not express as cleanly, while the F# layer provides the ergonomic combinator DSL. The `readme.md` calls it _"an implementation thoroughly optimized for performance"_; this two-language architecture is the mechanism.

### The `OperatorPrecedenceParser` component

FParsec's headline extra over Parsec is a built-in, embeddable [operator-precedence / Pratt][pratt] expression engine. It is itself a parser — the class **is** a function from stream to reply ([`OperatorPrecedenceParser.cs`][cs-opp]):

```csharp
public class OperatorPrecedenceParser<TTerm, TAfterString, TUserState>
       : FSharpFunc<CharStream<TUserState>, Reply<TTerm>> {
    public FSharpFunc<CharStream<TUserState>, Reply<TTerm>> TermParser { get; set; }
    public FSharpFunc<CharStream<TUserState>, Reply<TTerm>> ExpressionParser { get { return this; } }
    public void AddOperator(Operator<TTerm, TAfterString, TUserState> op) { … }
}
```

You give it a `TermParser` (how to parse an atom/parenthesized sub-expression) and register operators; `ExpressionParser` is then a normal FParsec parser you compose like any other. Operators come in four shapes and carry precedence + associativity ([`OperatorPrecedenceParser.cs`][cs-opp]):

```csharp
public enum Associativity { None = 0, Left = 1, Right = 2 }
public enum OperatorType  { Infix = 0, Prefix = 1, Postfix = 2 }
// concrete: InfixOperator, PrefixOperator, PostfixOperator, TernaryOperator
```

Each `Operator` has an integer `Precedence` (validated `> 0`), an `Associativity`, an operator string, an "after-string" parser (for whitespace/trailing syntax), and a mapping function that builds the result term. The engine is **runtime-configurable**: `AddOperator`/`RemoveInfixOperator`/`RemovePrefixOperator`/… mutate the operator table of a live parser — the readme's _"embeddable, runtime-configurable operator-precedence parser component"_ ([`readme.md`][repo-readme]) — so a language with user-definable operators can register them as it parses.

Internally the parse loop is a classic [precedence-climbing / Pratt][pratt] driver: parse (prefix ops then) a term, peek the next operator, and recurse or return based on comparing the previous operator's precedence to the next's, with associativity breaking ties ([`OperatorPrecedenceParser.cs`][cs-opp]):

```csharp
reply = TermParser.Invoke(stream);          // parse the term
op = PeekOp(stream, RhsOps);                 // peek the following infix/postfix operator
// … then, comparing prevOp.Precedence to op.Precedence:
if (prevOp.Precedence > op.Precedence) goto Break;      // caller binds tighter — stop
if (prevOp.Precedence < op.Precedence) goto Continue;   // this op binds tighter — recurse
// equal precedence: associativity (Left → Break, Right → Continue) decides
```

Operators are bucketed into fixed-size arrays keyed by their first char (`c0 & (OpsArrayLength - 1)`, `OpsArrayLength = 128`) and sorted within a bucket, so operator lookup at each position is effectively O(1) — the table-driven, one-token-lookahead, `O(n)`-time hallmark of [operator-precedence parsing][pratt]. This is the component's key contribution: a hand-written recursive-descent grammar in FParsec can delegate its entire expression sub-language to a correct, fast, precedence-aware parser instead of hand-rolling `chainl1`/`chainr1` ladders (which FParsec also provides, for simpler needs).

---

## Algorithm & grammar class

FParsec is a **recursive-descent, top-down, ordered-choice** parser — see [top-down & combinator parsing][top-down]. The formalism is **predictive LL(1) by default**, escalated to **LL(∞) on demand** via `attempt`, with a **committed, left-biased `<|>`**. That places it, like the rest of the [Parsec lineage][parsec], conceptually adjacent to a [Parsing Expression Grammar][peg] (ordered choice, no ambiguity, scannerless) but **without packrat memoization**:

- **No ambiguity / no parse forests.** `<|>` returns the first success; ambiguous grammars resolve by source order. For all-parses enumeration use a general parser, not FParsec.
- **No left recursion.** As with every recursive-descent scheme, a left-recursive production loops forever; rewrite to right recursion, or use `chainl1`/`chainr1`, or delegate to the `OperatorPrecedenceParser`.
- **Context-sensitive power.** Monadic sequencing (`>>=`, the `parse { … }` builder) plus threaded, backtracking-aware user state `'u` means a later parser can depend on an earlier runtime result — the "context-sensitive grammars" of the feature list.
- **Scannerless by default.** The token is a UTF-16 `char`; there is no separate lexer phase. Whitespace/lexeme handling is the writer's job (`spaces`, `pstring`, `many1Satisfy`, the `numberLiteral` scanner), same as Megaparsec's `lexeme`/`symbol` layer.

Unlike a [packrat parser][peg], FParsec does **no memoization**, so an `attempt`-heavy grammar can revisit a position repeatedly; the mutable-stream design keeps the constant factor low but offers no linear-time guarantee.

## Interface & composition model

The interface is an **internal DSL**: no external grammar file, no generator. A grammar _is_ an F# value built from the operator vocabulary — `>>=`, `|>>`, `>>.`/`.>>`/`.>>.`, `pipe2`…`pipe5`, `<|>`/`choice`, `many`/`many1`/`sepBy`/`manyTill`, `<?>` — or written in `parse { … }` computation-expression (`do`-notation) syntax via the `ParserCombinator` builder. AST construction is explicit and host-native (map results with `|>>`/`pipe*`); there is no automatic CST, unlike [tree-sitter][concepts]. The `run`/`runParserOnString`/`runParserOnStream`/`runParserOnFile` functions ([`CharParsers.fsi`][fsi-charparsers]) drive a parser over a string, substring, `System.IO.Stream`, or file (with encoding + BOM detection), returning the `ParserResult` sum type. Streams larger than memory are handled transparently by the block-loading `CharStream`.

## Performance

Performance is the axis on which FParsec most visibly diverges from the Haskell lineage, and the divergence is architectural:

- **Mutable stream, no continuation stack.** A parser is one indirect call returning a small `struct Reply`; there is no four-continuation CPS matrix (Megaparsec) and no monad-transformer tower (the cost [FlatParse][flatparse] pays to avoid). Advancing the stream is a pointer bump.
- **`unsafe` pointer buffer.** The default build walks a pinned UTF-16 buffer via `char*` ([`CharStream.cs`][cs-charstream]); the Low-Trust build swaps in verified managed access at some speed cost.
- **Specialized scalar scanners.** `numberLiteral`/`NumberLiteral`, `HexFloat`, `CharSet`, and the `many*Satisfy` family are hand-tuned C# that scan spans of the buffer directly rather than char-by-char through the combinator layer — the analogue of Megaparsec's bulk `takeWhileP`.
- **The `FParsecCS` core** concentrates every hot path in C# for layout and loop control the F# compiler does not match.

There is **no SIMD / data-parallel scanning**; FParsec is a scalar, sequential, recursive-descent engine (for SIMD-accelerated parsing see [simdjson][concepts], a different design point). Its niche is being _the_ fast, ergonomic, general-purpose parser for .NET — the standard combinator choice in the F# ecosystem.

## Error handling & recovery

This is FParsec's signature strength, and it is a direct descendant of Parsec's consumed/empty design:

- **Precise positional errors with expected/unexpected sets.** The [`ErrorMessageList`](#errormessagelist-the-diagnostic-engine) accumulates and de-duplicates expected-set messages across same-position alternatives (the merge happens on non-consuming failures), and `<?>`/`<??>` lift low-level expectations to grammar-production labels. `ParserError.ToString(stream)` renders the offending source line with a `^`-marker — the "automatically generated, highly readable error messages" of the feature list, and generally regarded as **best-in-class**, on par with or ahead of [Megaparsec][parsec].
- **Three-valued status for controlled recovery.** `Ok`/`Error`/`FatalError` ([`Reply.cs`][cs-reply]) lets a parser distinguish a routine backtrackable failure from an unrecoverable one (`failFatally`) that ordinary `<|>` must not swallow — a finer-grained control than Parsec's binary reply, and the closest FParsec comes to a "cut".
- **`NestedError`/`CompoundError` for structured context.** `<??>` and `lookAhead` wrap inner error lists with their position and the surrounding context ([`Error.fsi`][fsi-error]), so a failure deep inside a construct can be reported _with_ the enclosing production's frame rather than as a bare low-level expectation.
- **No automatic error _recovery_ loop.** Unlike [Megaparsec's `withRecovery` + error bundles][parsec], FParsec's `run` returns on the **first** unrecovered error — there is no built-in multi-error collection; a parser writer who wants to continue past an error and gather several must build recovery points manually with `attempt`/`<|>`.
- **No incremental _reparsing_.** Like the whole combinator family, FParsec is a one-shot function from input to result with no persistent, position-indexed parse tree to patch across edits — **not IDE-grade** for edit-and-reparse workloads (contrast [tree-sitter][concepts]). The block-loading `CharStream` is incremental _input_ (large files), not incremental _editing_.

## Ecosystem & maturity

FParsec is the **de-facto standard parser-combinator library for F#/.NET**, mature and stable (its design dates to 2007; copyright lines run 2007-2022). It is distributed as NuGet packages (`FParsec`, and the pointer-based `FParsec.Big-Data-Edition` variant historically) and is the parsing engine behind a wide range of F# tools, DSLs, and configuration/format parsers across the .NET ecosystem. Its documentation — a full tutorial, user's guide, and per-module reference at [quanttec.com/fparsec][site] — is unusually thorough for a library of its size. As a Parsec descendant it is a sibling to the other combinator ports in this catalog: [`nom`][nom]/[`winnow`][winnow]/[`combine`][combine] (Rust), [`angstrom`][angstrom] (OCaml), and the [Haskell originals][parsec]; among these it is distinguished by the mutable-stream performance engineering and the built-in operator-precedence component.

---

## Strengths

- **Best-in-class error messages.** A dedicated `ErrorMessageList` subsystem with de-duplicated, sorted expected/unexpected sets, grammar-production labels, nested/compound context, and source-line-with-`^` rendering — "automatically generated, highly readable."
- **Fast for a combinator library.** Mutable `CharStream`, `unsafe` pointer buffer, a C# `FParsecCS` core, and specialized scalar scanners; no transformer tower or CPS matrix.
- **Built-in operator-precedence parser.** A correct, runtime-configurable [Pratt][pratt]-style `OperatorPrecedenceParser` for prefix/infix/postfix/ternary operators — expression sub-languages for free.
- **Very large files.** The block-loading `CharStream` parses inputs bigger than memory, with full Unicode support.
- **Context-sensitive by construction.** Monadic sequencing + threaded, backtracking-aware user state `'u`.
- **Finer failure control.** Three-valued `ReplyStatus` (`Ok`/`Error`/`FatalError`) distinguishes recoverable from fatal failures.
- **Grammar is ordinary F#.** No external DSL, no build-step generator; the whole host language is available inside the grammar.

## Weaknesses

- **No left recursion.** Left-recursive grammars loop forever; rewrite or route through `chainl1`/`chainr1`/`OperatorPrecedenceParser`.
- **No ambiguity / no parse forests.** Ordered choice commits to the first alternative; use a [GLR/Earley][concepts] tool to enumerate all parses.
- **`attempt` is still a foot-gun.** Mis-scoped backtracking degrades error position and can cause super-linear re-scanning (no memoization to bound it) — mitigated, not eliminated, by the fused `>>=?`/`>>?`/`.>>?` combinators.
- **No automatic multi-error recovery.** Stops at the first unrecovered error; gathering several errors is manual (cf. Megaparsec's error bundles).
- **No incremental reparsing.** One-shot; not IDE-grade for edit-and-reparse (cf. [tree-sitter][concepts]).
- **.NET/F#-bound.** The two-assembly F#-over-C# design is tied to the CLR; not a portable C library.
- **No SIMD.** Scalar recursive descent; not competitive with [simdjson][concepts]-class data-parallel parsers on bulk formats.

## Key design decisions and trade-offs

| Decision                                                                        | Rationale                                                                                           | Trade-off                                                                                     |
| ------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| Mutable `CharStream` + `StateTag` instead of immutable functional state         | Pointer-walking speed and very-large-file support while preserving consumed/empty semantics         | Backtracking must physically snapshot/restore state; needs explicit `attempt` + fused `?` ops |
| Predictive LL(1); `<                                                            | >` does **not** backtrack after input is consumed                                                   | Fixes space leaks and enables precise expected-set errors (inherited from [Parsec][parsec])   | Multi-token-lookahead decisions need explicit `attempt`; surprising to newcomers |
| `attempt` as explicit opt-in to arbitrary lookahead, plus fused `?`-combinators | Keeps backtracking local and visible; `>>=?`/`>>?` avoid discarding error position                  | Mis-scoped `attempt` still degrades errors/performance; no memoization to bound re-scanning   |
| Three-valued `ReplyStatus` (`Ok`/`Error`/`FatalError`)                          | Distinguish recoverable failure from unrecoverable (`failFatally`) that `<                          | >` must not swallow                                                                           | More states to reason about than Parsec's binary reply                           |
| A dedicated `ErrorMessageList` subsystem (de-dupe, sort, nested/compound)       | Automatically generated, highly readable, stable error messages — the library's signature feature   | Book-keeping cost on the error path; complexity in the C# core                                |
| A separate `FParsecCS` C# core                                                  | Struct layout, `unsafe` pointers, and tight loops the F# compiler doesn't express as well           | Two-language build; some logic lives outside the ergonomic F# surface                         |
| Built-in runtime-configurable `OperatorPrecedenceParser`                        | Correct precedence/associativity expression parsing without hand-rolled ladders; user-definable ops | Extra API surface; C#-generic ceremony (`TTerm`/`TAfterString`/`TUserState`)                  |
| Default `unsafe` build + a Low-Trust managed alternative                        | Maximum speed where allowed, portability where `unsafe` is forbidden                                | Two build configurations to maintain (`FParsec.sln` / `FParsec-LowTrust.sln`)                 |

---

## Sources

- [`readme.md`][repo-readme] — scope ("parser combinator library for F#"), feature list (context-sensitive/infinite-lookahead, highly readable errors, Unicode, very large files, operator-precedence component, optimized for performance), license summary
- [`FParsec/Primitives.fsi`][fsi-primitives] — `Parser<'Result,'UserState>`, `>>=`/`<|>`/`choice`, `attempt`, the fused `>>=?`/`>>?`/`.>>?`/`.>>.?` backtracking combinators, `<?>`/`<??>`, `fail`/`failFatally`, `many`/`sepBy`/`chainl1`/`chainr1`
- [`FParsec/CharParsers.fsi`][fsi-charparsers] — `run`/`runParserOn*`, `ParserResult`, `getUserState`/`setUserState`/`updateUserState`, `numberLiteral`/`NumberLiteral`
- [`FParsec/Error.fsi`][fsi-error] — `expected`/`unexpected`/`messageError`/`nestedError`/`compoundError`/`mergeErrors`, `ParserError.ToString(stream)` with the `^`-marker
- [`FParsecCS/Reply.cs`][cs-reply] — `struct Reply<TResult>` and the three-valued `ReplyStatus`
- [`FParsecCS/ErrorMessage.cs`][cs-errormessage] · [`FParsecCS/ErrorMessageList.cs`][cs-errormessagelist] — the `ErrorMessageType` taxonomy, the cons-list `Merge`, and the `ToHashSet`/`ToSortedArray` de-dup + sort
- [`FParsecCS/CharStream.cs`][cs-charstream] — the mutable UTF-16 stream, the `StateTag` backtracking counter, block-loading for large files, `#if !LOW_TRUST` pointer mode
- [`FParsecCS/OperatorPrecedenceParser.cs`][cs-opp] — `Associativity`/`OperatorType`, `Operator`/`InfixOperator`/`PrefixOperator`/`PostfixOperator`/`TernaryOperator`, `AddOperator`/`RemoveOperator`, the precedence-climbing `ParseExpression` loop
- [`Build/fparsec-license.txt`][repo] — the Simplified (2-clause) BSD license text
- Related deep-dives: [Parsec/Megaparsec/attoparsec][parsec] · [top-down & combinator parsing][top-down] · [PEG & packrat][peg] · [Pratt / operator precedence][pratt] · [`nom`][nom] · [`winnow`][winnow] · [`combine`][combine] · [`angstrom`][angstrom] · [FlatParse][flatparse] · [parsing concepts][concepts] · [the comparison capstone][comparison] · [the parsing umbrella][umbrella]

<!-- References -->

[parsec]: ./haskell-parsec.md
[parsec-consumed]: ./haskell-parsec.md#the-choice-operator-does-not-backtrack-once-input-is-consumed
[parsec-try]: ./haskell-parsec.md#the-try-combinator-restoring-arbitrary-lookahead
[pratt]: ./theory/pratt-precedence.md
[top-down]: ./theory/top-down.md
[peg]: ./theory/peg-packrat.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[umbrella]: ./index.md
[nom]: ./rust-nom.md
[winnow]: ./rust-winnow.md
[combine]: ./rust-combine.md
[flatparse]: ./haskell-flatparse.md
[angstrom]: ./ocaml-angstrom.md
[repo]: https://github.com/stephan-tolksdorf/fparsec
[repo-readme]: https://github.com/stephan-tolksdorf/fparsec/blob/master/readme.md
[site]: https://www.quanttec.com/fparsec/
[fsi-primitives]: https://github.com/stephan-tolksdorf/fparsec/blob/master/FParsec/Primitives.fsi
[fsi-charparsers]: https://github.com/stephan-tolksdorf/fparsec/blob/master/FParsec/CharParsers.fsi
[fsi-error]: https://github.com/stephan-tolksdorf/fparsec/blob/master/FParsec/Error.fsi
[cs-reply]: https://github.com/stephan-tolksdorf/fparsec/blob/master/FParsecCS/Reply.cs
[cs-errormessage]: https://github.com/stephan-tolksdorf/fparsec/blob/master/FParsecCS/ErrorMessage.cs
[cs-errormessagelist]: https://github.com/stephan-tolksdorf/fparsec/blob/master/FParsecCS/ErrorMessageList.cs
[cs-charstream]: https://github.com/stephan-tolksdorf/fparsec/blob/master/FParsecCS/CharStream.cs
[cs-opp]: https://github.com/stephan-tolksdorf/fparsec/blob/master/FParsecCS/OperatorPrecedenceParser.cs
