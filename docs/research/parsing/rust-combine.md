# combine (Rust)

A [parser-combinator][concepts] library for Rust modelled directly on Haskell's [Parsec][parsec]: parsers are predictive [LL(1)][topdown] by default, track whether they have _consumed_ input, and opt in to arbitrary lookahead with an explicit `attempt` combinator — the Parsec design ported to Rust's trait system and generalised over arbitrary, resumable streams.

| Field           | Value                                                                                              |
| --------------- | -------------------------------------------------------------------------------------------------- |
| Language        | Rust (edition 2018; `#![no_std]`-capable via the `alloc` feature, `std` is default)                |
| License         | MIT                                                                                                |
| Repository      | [Marwes/combine][repo]                                                                             |
| Documentation   | [docs.rs/combine][docs] · [crates.io][crate] · [wiki tutorial][wiki]                               |
| Key author      | Markus Westerlind (`Marwes`) and contributors                                                      |
| Category        | [Parser combinator][concepts] (Rust; **Parsec-style**, `Stream`-based)                             |
| Algorithm class | Predictive [LL(1)][topdown] by default; opt-in arbitrary lookahead via `attempt` (Parsec's `try`)  |
| Input model     | Any `Stream` — `&str`, `&[u8]`, iterators, `Read`; **partial/streaming** input via `PartialStream` |
| Error posture   | Parsec-style **consumed/commit tracking** (`Commit`/`ParseResult`) + readable `easy::Errors`       |
| Zero-copy       | `range` parsers over a `RangeStream` return borrowed slices (`take`, `take_while`, `recognize`)    |
| Latest release  | `4.6.7` (local pin `203b76a`, 2026-02-03)                                                          |

> [!NOTE]
> combine is the **Parsec-lineage** data point in this survey's parser-combinator
> cluster. Where [`nom`][nom] and its fork [`winnow`][winnow] are byte-slice,
> [PEG][peg]-ish recognisers that _backtrack by default_, combine keeps Parsec's
> _commit-by-default-once-consumed_ discipline. Compare it against its inspiration
> [Haskell `parsec`][parsec], its sibling combinators [`angstrom`][angstrom] (OCaml),
> [`fparsec`][fparsec] (F#), and [`flatparse`][flatparse] (Haskell), and the
> recovery-first [`chumsky`][chumsky]. See the [comparison][comparison] capstone for
> the cross-subject synthesis.

---

## Overview

### What it solves

combine turns parsing into composition rather than code generation: you build a big
parser by gluing small ones together with higher-order functions. Its own `README.md`
frames the abstraction ([`README.md`][readme]):

> _"A parser combinator is, broadly speaking, a function which takes several parsers as
> arguments and returns a new parser, created by combining those parsers. For instance,
> the `many` parser takes one parser, `p`, as input and returns a new parser which
> applies `p` zero or more times."_

The crate root states its heritage and its defining constraint outright
([`src/lib.rs`][lib]):

> _"`combine` limits itself to creating LL(1) parsers (it is possible to opt-in to LL(k)
> parsing using the `attempt` combinator) which makes the parsers easy to reason about
> in both function and performance while sacrificing some generality. In addition to you
> being able to reason better about the parsers you construct `combine` the library also
> takes the knowledge of being an LL parser and uses it to automatically construct good
> error messages."_

That LL(1)-by-default posture — inherited from Parsec — is the single decision that
separates combine from the [`nom`][nom]/[`winnow`][winnow] branch of the Rust ecosystem
(which are effectively unbounded-backtracking [PEG][peg] engines). combine's `Cargo.toml`
summarises the value proposition in one line: _"Fast parser combinators on arbitrary
streams with zero-copy support."_ ([`Cargo.toml`][cargo]).

### Design philosophy

combine is a **faithful port of Parsec's model**, not merely "a Rust combinator
library." The crate documentation names its two Haskell ancestors ([`src/lib.rs`][lib]):
_"This crate contains parser combinators, roughly based on the Haskell libraries
`parsec` and `attoparsec`."_ The `README.md` is more specific about the semantics it
carries over ([`README.md`][readme]):

> _"An implementation of parser combinators for Rust, inspired by the Haskell library
> Parsec. As in Parsec the parsers are LL(1) by default but they can opt-in to arbitrary
> lookahead using the `attempt` combinator."_

Three commitments follow from that lineage, each visible in the source:

**Consumed-input tracking.** Every parse result records whether the parser _committed_
(consumed) any input. `choice`/`or` only tries an alternative when the previous one
failed **without** committing. This is Parsec's central mechanism — and precisely what
the [`nom`][nom]/[`winnow`][winnow]/[`flatparse`][flatparse] lineage drops in favour of
either unbounded backtracking (nom) or explicit cuts. See
[Error handling — the commit model](#error-handling--the-commit-model).

**Stream-genericity over anything.** A combine parser is generic over a `Stream`, so the
same grammar runs over `&str`, `&[u8]`, iterators, `Read` instances, or a custom stream —
including **partial** input that arrives in chunks ([`README.md`][readme]):

> _"Combine can parse anything from `&[u8]` and `&str` to iterators and `Read`
> instances. If none of the builtin streams fit your use case you can even implement a
> couple traits your self to create your own custom stream!"_

**Zero-copy where it can, allocation where you ask.** For in-memory data the `range`
parsers return borrowed sub-slices of the input, no copy ([`README.md`][readme]):
_"When parsing in memory data, combine can parse without copying. See the `range` module
for parsers specialized for zero-copy parsing."_

---

## How it works

### Core abstractions and types

| Concept                | Type / item                                                      | Role                                                                          |
| ---------------------- | ---------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| The parser abstraction | `Parser<Input: Stream>` trait                                    | `type Output`, `type PartialState`; all combinators hang off it               |
| Public entry point     | `parse(self, Input) -> Result<(Output, Input), Error>`           | Returns the value **and the remaining input** (Parsec convention)             |
| Flattened result       | `ParseResult<T, E>`                                              | `CommitOk` / `PeekOk` / `CommitErr` / `PeekErr` — success/failure × committed |
| Commit flag            | `Commit<T>`                                                      | `Commit(T)` (consumed) vs `Peek(T)` (not consumed) — gates backtracking       |
| Input abstraction      | `StreamOnce` + `ResetStream` + `Positioned` = `Stream`           | `uncons`, `checkpoint`/`reset`, `position`; makes a source parseable          |
| Zero-copy input        | `RangeStreamOnce` / `RangeStream`                                | `uncons_range`, `uncons_while` — yield borrowed ranges                        |
| Streaming input        | `PartialStream<S>` / `MaybePartialStream<S>`                     | Marks a stream as partial (EOF means "need more", not "wrong")                |
| Error contract         | `ParseError<Item, Range, Position>` + `StreamError<Item, Range>` | Composable error traits; a `ParseError` accumulates `StreamError`s            |
| Readable error         | `easy::Errors<T, R, P>` (via `easy_parse`)                       | `{ position, errors: Vec<easy::Error> }` — `Unexpected`/`Expected`/`Message`  |

### The `Parser` trait

Unlike [`nom`][nom] (where a parser is fundamentally a _function_ `Fn(I) -> IResult`),
combine's parser is a **trait**, `Parser<Input>`, with an associated `Output` and an
associated `PartialState` for resumable parsing ([`src/parser/mod.rs`][parsermod]):

```rust
// combine: src/parser/mod.rs (abridged)
pub trait Parser<Input: Stream> {
    type Output;
    type PartialState: Default;

    // Public entry point: value + *remaining input*, or an error.
    fn parse(&mut self, input: Input)
        -> Result<(Self::Output, Input), <Input as StreamOnce>::Error> { /* … */ }

    // The workhorse: a flattened ParseResult carrying the commit flag.
    fn parse_stream(&mut self, input: &mut Input)
        -> ParseResult<Self::Output, <Input as StreamOnce>::Error> { /* … */ }

    // Optimised path parsers implement instead of parse_stream.
    fn parse_lazy(&mut self, input: &mut Input) -> ParseResult<…> { /* … */ }
    // map, and_then, skip, with, or, … as provided combinator methods
}
```

The public `parse` returns `Ok((value, remaining_input))` — the value _and the leftover
input_, exactly Parsec's `(a, State)` convention (and the thing [`winnow`][winnow]
deliberately abandoned by mutating `&mut I` in place). The README's opening example makes
the shape concrete ([`README.md`][readme]):

```rust
// combine: README.md
let word = many1(letter());
let mut parser = sep_by(word, space())
    .map(|mut words: Vec<String>| words.pop());
let result = parser.parse("Pick up that word!");
// `parse` returns `Result` where `Ok` contains a tuple of the
// parser's output and any remaining input.
assert_eq!(result, Ok((Some("word".to_string()), "!")));
```

Combinators are ordinary generic structs implementing `Parser` (`Map<P, F>`, `Or<P1,
P2>`, `Try<P>`, …), so a fully-built parser is a deeply nested generic type. Because that
type is _"very large due to combine's trait based approach"_, the crate ships a `parser!`
macro (and supports `impl Parser` in return position) to name reusable parsers without
spelling the type — _"non-allocating, anonymous parsers on stable rust"_
([`src/lib.rs`][lib]). This type-name explosion is the ergonomic tax of the trait-based
design; it is the very friction that motivated Ed Page to prefer nom's _"toolbox model"_
over combine's _"framework model"_ when he forked [`winnow`][winnow] (quoted in the
[nom deep-dive][nom]).

### The `Stream` abstraction

A parseable source is not `&[u8]`; it is anything implementing the `Stream` trait
hierarchy ([`src/stream/mod.rs`][streammod]). Three traits compose into `Stream`:

- **`StreamOnce`** — `uncons()` pulls one `Token`; carries associated `Token`, `Range`,
  `Position`, and `Error` types, plus an `is_partial()` flag.
- **`ResetStream`** — `checkpoint()` / `reset()` let a parser save a position and rewind
  to it (the mechanism `or` and `attempt` use to backtrack).
- **`Positioned`** — `position()` so errors at different offsets aren't conflated.

```rust
// combine: src/stream/mod.rs
pub trait Stream: StreamOnce + ResetStream + Positioned {}
impl<Input> Stream for Input
where Input: StreamOnce + Positioned + ResetStream {}
```

`&str`, `&[T]`, `SliceStream`, and `IteratorStream` get `ResetStream` for free by cloning
(`clone_resetable!`). Custom sources implement the three traits and `Stream` follows
automatically. This is a strictly larger input abstraction than nom's `Input` trait: it
adds first-class **checkpoints** and **partial-input** signalling into the stream itself,
rather than modelling incompleteness as an `Err::Incomplete` return value the way nom
does.

### Zero-copy: the `range` parsers

The `range` module holds _"zero-copy parsers"_ that _"require the `RangeStream` bound
instead of a plain `Stream`"_ ([`src/parser/range.rs`][range]). `RangeStreamOnce` adds
`uncons_range(size)` and `uncons_while(pred)`, which yield a borrowed `Self::Range`
(a `&str`/`&[u8]` sub-slice) rather than a token at a time. `take(n)` is the headline:

```rust
// combine: src/parser/range.rs — "Zero-copy parser which reads a range of length `n`."
let mut parser = take(4);
let result = parser.parse("123abc");
assert_eq!(result, Ok(("123a", "bc")));   // "123a" borrows the input; no copy
```

`recognize(p)` (return the consumed range of any sub-parser), `take_while`/`take_while1`,
and `take_until_range` round out the set. As with nom, the borrow is enforced by Rust's
lifetimes: the output range is tied to the input buffer, so recognition allocates nothing.

### Partial / streaming parsing

combine parsers are **resumable**: a parse can stop mid-stream and continue when more
data arrives, without re-doing work ([`README.md`][readme]):

> _"Combine parsers can be stopped at any point during parsing and later be resumed
> without losing any progress. This makes it possible to start parsing partial data
> coming from an io device such as a socket without worrying about if enough data is
> present to complete the parse. If more data is needed the parser will stop and may be
> resumed at the same point once more data is available."_

The mechanism is the `Parser::PartialState` associated type plus a stream wrapped in
`PartialStream<S>` — _"Stream type which indicates that the stream is partial if end of
input is reached"_ ([`src/stream/mod.rs`][streammod]). When such a stream hits EOF, the
parser records where it stopped in its `PartialState` and returns; feed more input and
`parse_with_state` picks up exactly there. This is combine's answer to the same problem
nom solves with `Err::Incomplete(Needed)`, but modelled as **saved parser state** rather
than a re-run from a buffer boundary — closer to a coroutine than a retry. combine's
`decoder`/`buffered`/`buf_reader`/`tokio` stream adapters build async, chunked parsing on
top of it (the `async` example).

### Readable errors: `easy`

The bare `parse` uses a minimal error type; for human-readable diagnostics you call
`easy_parse`, which wraps the stream in `easy::Stream` and produces `easy::Errors`
([`src/stream/easy.rs`][easy]):

```rust
// combine: src/stream/easy.rs
pub struct Errors<T, R, P> {
    pub position: P,               // where the error occurred
    pub errors: Vec<Error<T, R>>,  // Unexpected / Expected / Message / Other
}
```

Because combine _knows_ it is an LL(1) parser, at a failure it can enumerate the set of
tokens it _expected_ at that position and the one it got, yielding messages like:

```text
Parse error at line: 1, column: 1
Unexpected `|`
Expected digit or letter
```

straight from the crate-root example ([`src/lib.rs`][lib]). One caveat surfaced in the
`README.md` FAQ: to keep overhead near zero, `&str`/`&[T]` streams _"do not carry any
extra position information"_ and compare raw pointers; to get line/column you wrap the
input in `State`/`position::Stream` or use `translate_position` ([`README.md`][readme]).

---

## Algorithm & grammar class

combine is a **predictive, recursive-descent [LL(1)][topdown]** engine over a token
stream. By default a parser inspects **one** token of lookahead to choose a branch;
`choice`/`or` commits to the first alternative that _consumes_ input and will not try
others once that happens. To exceed one token of lookahead you must explicitly opt in
with `attempt` ([`src/lib.rs`][lib], [`README.md`][readme]).

This is categorically different from the [`nom`][nom] model. nom's `alt` is [PEG][peg]
ordered choice with **unbounded backtracking by default**: an alternative may consume
arbitrarily far, fail, and the next alternative retries from the saved position for free
(commitment is the _opt-in_, via `cut`). combine inverts both defaults: **consumption is
commitment**, and **backtracking is the opt-in** (via `attempt`). The trade-off is the
classic Parsec one — predictable linear behaviour and precise "expected X" errors, at the
cost of the author having to place `attempt` wherever real multi-token lookahead is
needed. Like nom, combine does **no memoization**; it is not a [packrat][peg] parser, and
it has no built-in left-recursion support (a left-recursive parser loops forever), so
left-associative operators use `chainl1`/`sep_by`-style folds.

## Error handling — the commit model

combine's error handling _is_ its algorithm; the two are the same mechanism. The result
of the internal parse loop is a four-way flattened enum ([`src/error.rs`][error]):

```rust
// combine: src/error.rs
pub enum ParseResult<T, E> {
    CommitOk(T),        // success, input was consumed  → committed
    PeekOk(T),          // success, no input consumed    → not committed
    CommitErr(E),       // failure after consuming input → do NOT try alternatives
    PeekErr(Tracked<E>),// failure without consuming     → alternatives may be tried
}
```

The `Commit<T>` flag it flattens is documented as _"Enum used to indicate if a parser
committed any items of the stream it was given as an input … used by parsers such as `or`
and `choice` to determine if they should try to parse with another parser as they will
only be able to provide good error reporting if the preceding parser did not commit"_
([`src/error.rs`][error]). The `or` combinator's own doc example is the canonical
demonstration ([`src/parser/choice.rs`][choice]):

```rust
// combine: src/parser/choice.rs
let mut parser2 = or(string("two"), string("three"));
// Fails as the parser for "two" consumes the first 't' before failing
assert!(parser2.parse("three").is_err());

// Use 'attempt' to make failing parsers always act as if they have not committed
let mut parser3 = or(attempt(string("two")), attempt(string("three")));
assert_eq!(parser3.parse("three"), Ok(("three", "")));
```

`attempt(p)` _"behaves as `p` except it always acts as `p` peeked instead of committed on
its parse"_ — implemented by rewriting a `CommitErr` into a `PeekErr` so `or` will retry
([`src/parser/combinator.rs`][combinator]). It is a one-for-one port of Parsec's `try`,
and `look_ahead` mirrors Parsec's `lookAhead`. The escalating trait hierarchy behind the
errors — `StreamError<Item, Range>` (one primitive error: `unexpected_*`, `expected_*`,
`message_*`) composed into a `ParseError<Item, Range, Position>` that `add`s and `merge`s
them — is how the `easy` type accumulates "expected digit **or** letter" sets
([`src/error.rs`][error]).

> [!IMPORTANT]
> combine is a _parser_, not an _error-recovery framework_. Like [`nom`][nom] it stops at
> the first committed error; it has **no automatic multi-error recovery** and **no
> incremental reparsing** (those axes belong to [`chumsky`][chumsky] and
> [tree-sitter][concepts]). What combine _does_ carry that nom does not is Parsec's
> consumed-tracking, which buys sharper LL(1) diagnostics and predictable backtracking —
> a different axis from recovery. Its `PartialState` gives it _streaming_ resumption, the
> same axis as nom's `Incomplete`.

## Performance

combine's `Cargo.toml` sells it as _"Fast parser combinators on arbitrary streams"_, and
the mechanism is the same as nom's: parsers are concrete generic types, monomorphized and
inlined, so a tower of combinators collapses into straight-line code with no dynamic
dispatch on the hot path. The repository ships `criterion` benchmarks for `json`, `http`,
and `mp4` with `lto = true` / `codegen-units = 1` ([`Cargo.toml`][cargo]).

Two design points shape its performance envelope relative to [`nom`][nom]/[`winnow`][winnow]:

- **Zero-copy via `range`** keeps recognisers allocation-free (borrowed slices), matching
  nom's zero-copy property. Owned output (`String`, `Vec`) is built only where you
  `.map`/`collect`.
- **The trait/`ParseResult` machinery is heavier than nom's bare function signature.** Ed
  Page's public rationale for forking [`winnow`][winnow] cites combine by name — he found
  nom's _"toolbox model … worked much better for me than the framework model other parser
  libraries used like combine"_ — and winnow's headline speed came partly from shrinking
  the `Ok` payload and _"switching to imperative, rather than pure-functional parsing"_
  (see the [nom deep-dive][nom]). combine sits on the Parsec side of that split: richer
  model, more generic plumbing, larger parser types.

## Ecosystem & maturity

combine is an established, semver-stable crate (currently `4.6.7`, MIT-licensed, edition
2018, `no_std`-capable via `alloc`). Its `README.md` lists production users spanning
formats and languages: the `graphql-parser` crate (GraphQL, using a custom tokenizer as
input), `toml_edit` (before its move to winnow), `redis-rs` (using **partial** parsing),
the `ress` JavaScript lexer, Mozilla's `mentat` and `tantivy` query parsers, and
`diffx-rs` ([`README.md`][readme]). A companion crate, `combine-language`, provides
ready-made lexing/expression helpers for programming-language grammars. The library's
most consequential ecosystem footnote is comparative: `toml_edit` **migrated off
combine** onto what became [`winnow`][winnow], and the winnow author's framing of that
move (framework-vs-toolbox) is the clearest external articulation of combine's
design-space position.

---

## Strengths

- **Faithful Parsec model.** Consumed-input tracking, `attempt` (`try`), `look_ahead`,
  and LL(1)-by-default give predictable behaviour and precise "expected …" diagnostics
  for free — the thing the [`nom`][nom]/[`winnow`][winnow] branch trades away.
- **Truly stream-generic.** Parses `&str`, `&[u8]`, iterators, and `Read` through one
  `Stream` trait hierarchy; custom sources implement three small traits.
- **First-class partial/resumable parsing.** `PartialState` + `PartialStream` let a parse
  stop and resume across socket reads without a full re-parse — modelled as saved state,
  not buffer re-runs.
- **Zero-copy.** `range` parsers return borrowed slices; recognisers allocate nothing.
- **Readable errors out of the box.** `easy_parse` yields position + expected/unexpected
  sets with no extra wiring, exploiting the LL(1) guarantee.
- **Mature and stable.** Semver-disciplined, `no_std`-capable, proven in `graphql-parser`,
  `redis-rs`, `tantivy`, and others.

## Weaknesses

- **`attempt` is a foot-gun.** Because backtracking is opt-in, forgetting `attempt` where
  two alternatives share a prefix silently makes the second unreachable (the
  `or("two", "three")` trap) — the inverse of nom's "forgot to `cut`" mistake.
- **Type-name explosion.** The trait-based design produces enormous parser types; you
  need the `parser!` macro or `impl Parser` to name or recurse, which the README calls out
  directly.
- **Heavier model than nom/winnow.** The `ParseResult`/`Commit` plumbing and pure-
  functional style cost the ergonomic and performance headroom that motivated the winnow
  fork.
- **No error recovery, no incremental reparsing.** A parse stops at the first committed
  error — use [`chumsky`][chumsky] or [tree-sitter][concepts] for resilience.
- **No left recursion, no memoization.** Left-recursive grammars must be refactored into
  folds; overlapping `attempt`ed alternatives can backtrack super-linearly.
- **Positions cost extra.** Raw `&str`/`&[u8]` streams carry only pointer positions;
  line/column requires wrapping in `State`/`position::Stream`.

## Key design decisions and trade-offs

| Decision                                                            | Rationale                                                                                                                   | Trade-off                                                                                                             |
| ------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| LL(1) by default, lookahead opt-in via `attempt` (Parsec's `try`)   | Predictable linear behaviour; precise "expected X" errors; parsers easy to reason about                                     | Author must place `attempt` for multi-token lookahead; the `or("two","three")` unreachable-branch trap                |
| Keep Parsec's **consumed/commit tracking** (`Commit`/`ParseResult`) | Good LL(1) diagnostics; `choice` only retries un-committed branches — the opposite of [`nom`][nom]/[`flatparse`][flatparse] | Extra concept (committed vs peeked) pervades the whole API and every custom parser                                    |
| Parser as a **trait** (`Parser<Input>`), not a function             | Associated `Output`/`PartialState`; method-chaining combinators; monomorphized speed                                        | Enormous nested parser types → need `parser!`/`impl Parser`; the "framework model" winnow's author forked _away_ from |
| `parse` returns `(Output, remaining_input)`                         | Parsec's `(a, State)` convention; composable, pure                                                                          | Larger `Ok` payload than [`winnow`][winnow]'s `Fn(&mut I) -> O`; input must be resettable/cloneable                   |
| Generic over any `Stream` (+ `RangeStream`, `PartialStream`)        | One grammar over `&str`/`&[u8]`/iterators/`Read`; zero-copy and partial input are first-class                               | More trait bounds to satisfy; positions cost extra on raw slice streams                                               |
| Partial parsing via saved `PartialState`                            | Resume across socket reads without re-parsing; async/streaming decoders                                                     | Every combinator must thread a `PartialState`; more machinery than nom's `Incomplete` return                          |
| Minimal default error, opt-in `easy::Errors`                        | Keep the fast path cheap; readable errors when you ask (`easy_parse`)                                                       | Two error worlds to understand; good positions need a `State` wrapper                                                 |

---

## Sources

- [Marwes/combine — GitHub repository][repo] · [docs.rs/combine][docs] · [crates.io][crate]
- [`README.md` — Parsec inspiration, LL(1)+`attempt`, arbitrary-stream / zero-copy / partial-parsing features, users, position FAQ][readme]
- [`Cargo.toml` — version `4.6.7`, MIT, edition 2018, "Fast parser combinators on arbitrary streams with zero-copy support", `no_std`/`alloc` features, criterion benches][cargo]
- [`src/lib.rs` — crate-root docs: "roughly based on parsec and attoparsec", LL(1) rationale, `parser!` macro / type-name problem, `easy_parse` error example][lib]
- [`src/parser/mod.rs` — the `Parser<Input>` trait, `Output`/`PartialState`, `parse`/`parse_stream`/`parse_lazy`][parsermod]
- [`src/stream/mod.rs` — `StreamOnce`/`ResetStream`/`Positioned`/`Stream`, `RangeStreamOnce`/`RangeStream`, `PartialStream`][streammod]
- [`src/error.rs` — `ParseResult` four-way enum, `Commit` flag, `StreamError`/`ParseError` traits][error]
- [`src/parser/combinator.rs` — `attempt`/`Try` (CommitErr→PeekErr), `look_ahead`][combinator]
- [`src/parser/choice.rs` — `or`/`Or` commit-gated backtracking, the `attempt` doc example][choice]
- [`src/parser/range.rs` — zero-copy `take`/`take_while`/`recognize` over `RangeStream`][range]
- [`src/stream/easy.rs` — `easy::Errors`/`easy::Error` readable diagnostics][easy]
- Related deep-dives in this survey: [Haskell `parsec`][parsec] (its inspiration) · [`nom`][nom] / [`winnow`][winnow] (the byte-slice branch) · [`chumsky`][chumsky] · [`flatparse`][flatparse] · [`angstrom`][angstrom] · [`fparsec`][fparsec] · [LL / top-down theory][topdown] · [PEG / packrat theory][peg] · [combinator concepts][concepts] · [the comparison capstone][comparison]

<!-- References -->

[repo]: https://github.com/Marwes/combine
[docs]: https://docs.rs/combine
[crate]: https://crates.io/crates/combine
[wiki]: https://github.com/Marwes/combine/wiki
[readme]: https://github.com/Marwes/combine/blob/master/README.md
[cargo]: https://github.com/Marwes/combine/blob/master/Cargo.toml
[lib]: https://github.com/Marwes/combine/blob/master/src/lib.rs
[parsermod]: https://github.com/Marwes/combine/blob/master/src/parser/mod.rs
[streammod]: https://github.com/Marwes/combine/blob/master/src/stream/mod.rs
[error]: https://github.com/Marwes/combine/blob/master/src/error.rs
[combinator]: https://github.com/Marwes/combine/blob/master/src/parser/combinator.rs
[choice]: https://github.com/Marwes/combine/blob/master/src/parser/choice.rs
[range]: https://github.com/Marwes/combine/blob/master/src/parser/range.rs
[easy]: https://github.com/Marwes/combine/blob/master/src/stream/easy.rs
[nom]: ./rust-nom.md
[winnow]: ./rust-winnow.md
[parsec]: ./haskell-parsec.md
[chumsky]: ./rust-chumsky.md
[flatparse]: ./haskell-flatparse.md
[angstrom]: ./ocaml-angstrom.md
[fparsec]: ./fsharp-fparsec.md
[peg]: ./theory/peg-packrat.md
[topdown]: ./theory/top-down.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[umbrella]: ./index.md
