# winnow (Rust)

A byte-oriented, zero-copy [parser-combinator][concepts] library for Rust — the actively-maintained **fork of [`nom`][nom]** — whose parsers advance the input by mutating a `&mut I` reference (`Fn(&mut I) -> Result<O, E>`) instead of threading the leftover through a tuple return.

| Field           | Value                                                                                                          |
| --------------- | -------------------------------------------------------------------------------------------------------------- |
| Language        | Rust (the library is `#![no_std]`-capable; `std` is a default feature)                                         |
| License         | MIT ([`Cargo.toml`][cargo] `license.workspace = true` → `license = "MIT"`)                                     |
| Repository      | [winnow-rs/winnow][repo]                                                                                       |
| Documentation   | [docs.rs/winnow][docs] · [crates.io][crate] · in-tree [`_topic/`][topicdir] & [`_tutorial/`][tutorialdir]      |
| Key authors     | Ed Page (`epage`) and contributors; a fork of Geoffroy Couprie's [`nom`][nom]                                  |
| Category        | [Parser combinator][concepts] (Rust; **`nom` fork**) — recursive-descent, scannerless                          |
| Algorithm class | Hand-rolled top-down / [recursive descent][top-down] with ordered choice; **not** a generated table parser     |
| Lexing model    | **Scannerless** by default — parsers consume `&[u8]`/`&str` directly; separate lex/parse phases are _optional_ |
| Grammar class   | Effectively [PEG][peg]-like (ordered choice, no built-in left-recursion, unbounded lookahead via checkpoints)  |
| Zero-copy       | Yes — recognized spans are returned as `Stream::Slice` borrows of the input                                    |
| Error posture   | Fail-fast; opt-in commit (`cut_err`) and opt-in multi-error **recovery** (`unstable-recover`)                  |
| MSRV            | Rust `1.65.0` ([`Cargo.toml`][cargo]); policy is "last 6 months of rust releases" ([`src/lib.rs`][lib])        |
| Latest release  | `1.0.3` (2026-05-14); `1.0.0` was 2026-03-17 ([`CHANGELOG.md`][changelog])                                     |

> [!NOTE]
> winnow is the [`nom`][nom] fork this survey pairs directly with its parent: read
> [`nom`][nom] first for the shared combinator model and the zero-copy/streaming
> lineage, then this page for the deltas. winnow is now load-bearing under Cargo
> (it is the parser under `toml_edit`). Its siblings here are the other
> combinator libraries — [`chumsky`][chumsky], Haskell's [`parsec`][parsec] and
> [`flatparse`][flatparse], and [`combine`][combine] — catalogued in the
> [survey umbrella][umbrella] and synthesized in the [comparison][comparison] capstone.

---

## Overview

### What it solves

winnow solves the same problem [`nom`][nom] does — turning parsing from a
code-generation problem into a _composition_ problem — but re-optimizes the API for
the parsers _yet to be written_ rather than for existing `nom` users. Its own framing
positions it not against `lex`/`yacc` but against the **hand-written parser**
([`src/_topic/why.rs`][why]):

> _"Unlike traditional programming language parsers that use lex or yacc, you can
> think of `winnow` as a general version of the helpers you would create along the way
> to writing a hand-written parser."_

The `why.rs` topic frames the trade-off a hand-rolled parser buys you — and the cost
that motivates reaching for a combinator toolbox instead ([`why.rs`][why]):

> _"Typically, a hand-written parser gives you the flexibility to get — Fast parse
> performance / Fast compile-time / Small binary sizes / High quality error message /
> Fewer dependencies to audit. However, this comes at the cost of doing it all
> yourself…"_

including "Being aware of, familiar with, and correctly implement the relevant
algorithms" — cited with matklad's remark that even a compiler author forgets his own
[Pratt parser][pratt] ([`why.rs`][why]):

> _"I've implemented a production-grade Pratt parser once, but I no longer immediately
> understand that code :-)"_

The library's stated aspiration is deliberately broad ([`src/lib.rs`][lib]):

> _"`winnow` aims to be your 'do everything' parser, much like people treat regular
> expressions."_

### Design philosophy — why fork `nom`?

winnow keeps `nom`'s _toolbox_ philosophy but shifts three priorities. The `why.rs`
topic states the split against `nom` directly ([`why.rs`][why]):

> _"`winnow` is a fork of the venerable `nom`. The difference between them is largely
> in priorities. `nom` prioritizes: — Lower churn for existing users while `winnow` is
> trying to find ways to make things better for the parsers yet to be written. — Having
> a small core, relying on external crates like `nom-locate` and `nom-supreme` …
> while `winnow` aims to include all the fundamentals for parsing to ensure the
> experience is cohesive and high quality."_

So the fork rationale is **(1) willingness to churn** the API for a better model,
**(2) batteries-included** (span tracking, richer errors, tutorials live in the one
crate rather than across `nom_locate`/`nom-supreme`), and **(3) an imperative-friendly
`&mut` model** (below). Crucially, "batteries-included" is _not_ "framework": winnow
explicitly contrasts itself with [`chumsky`][chumsky] on exactly this axis
([`why.rs`][why]):

> _"In contrast, `winnow` is an introspectable toolbox that can easily be customized at
> any level."_

where `chumsky` is characterized as feeling "more like a framework" you must "re-frame
everything to fit within". winnow inherits `nom`'s zero-copy and streaming DNA verbatim
— the `Cargo.toml` description is still _"A byte-oriented, zero-copy, parser combinators
library"_ ([`Cargo.toml`][cargo]) — and the README closes by crediting its parent
([`README.md`][readme]):

> _"winnow is the fruit of the work of many contributors over the years, many thanks
> for your help! In particular, thanks to Geal for the original `nom` crate."_

---

## How it works

### The `&mut Stream` model (the central fork)

The single most important difference from [`nom`][nom] is the parser signature. Where
`nom` parsers are `Fn(I) -> IResult<I, O, E>` — returning the **remaining input**
alongside the output so the caller must thread `i` forward — a winnow parser _mutates_
the input in place and returns only the output. The `Parser` trait's required method is
([`src/parser.rs`][parser]):

```rust
// winnow: src/parser.rs (Parser trait, abridged)
pub trait Parser<I, O, E> {
    /// Take tokens from the Stream, turning it into the output
    ///
    /// On error, `input` will be left pointing at the error location.
    fn parse_next(&mut self, input: &mut I) -> Result<O, E>;
}
```

The migration topic states the change and its justification verbatim
([`src/_topic/nom.rs`][nommig]):

> _"`winnow` switched from pure-function parser (`Fn(I) -> (I, O)` to `Fn(&mut I) ->
O`). On error, `i` is left pointing at where the error happened."_

with the benefits enumerated ([`nom.rs`][nommig]):

> _"Cleaner code: Removes need to pass `i` everywhere … Correctness: No forgetting to
> chain `i` through a parser. Flexibility: `I` does not need to be `Copy` or even
> `Clone`. … Performance: `Result::Ok` is smaller without `i`, reducing the risk that
> the output will be returned on the stack, rather than the much faster CPU registers."_

For the cases that genuinely want `nom`'s return-the-leftover shape — testing, or
driving one parser from another during migration — winnow keeps a `parse_peek(input:
I) -> Result<(I, O), E>` method that "returns a copy of the `Stream` advanced to the
next location" ([`src/parser.rs`][parser]); the docs flag it as "primarily intended
for: Migrating from older versions / `nom`, Testing". The `#rrggbb` color parser
that is `hex_color` in `nom`'s README is the same grammar in winnow's `css` example,
now written with the `seq!` macro over `&mut &str` ([`examples/css/parser.rs`][css]):

```rust
// winnow: examples/css/parser.rs
pub(crate) fn hex_color(input: &mut &str) -> Result<Color> {
    seq!(Color {
        _: '#',
        red: hex_primary,
        green: hex_primary,
        blue: hex_primary
    })
    .parse_next(input)
}

fn hex_primary(input: &mut &str) -> Result<u8> {
    take_while(2, |c: char| c.is_ascii_hexdigit())
        .try_map(|input| u8::from_str_radix(input, 16))
        .parse_next(input)
}
```

Note what has vanished relative to the `nom` version: there is no `let (input, _) =
tag("#")(input)?;` rebinding — `input` is threaded implicitly by `&mut`, and the
[`seq!`][seqmacro] macro (winnow's answer to `nom`'s tuple-of-parsers) names each
field. To save and restore a position for manual backtracking, winnow exposes
`Stream::checkpoint` and `Stream::reset` instead of the copy-the-input trick `nom`
relies on ([`nom.rs`][nommig]).

### The unified `Stream` trait

`nom 8.0` collapsed its menagerie of input traits (`InputIter`, `InputTake`,
`InputLength`, …) into a single `Input` trait; winnow reached the same conclusion
earlier and generalized further with the **`Stream`** trait, which is the one
abstraction every combinator is written against ([`src/stream/mod.rs`][stream]):

```rust
// winnow: src/stream/mod.rs (abridged)
pub trait Stream: Offset<<Self as Stream>::Checkpoint> + core::fmt::Debug {
    type Token: core::fmt::Debug;      // smallest unit: u8 for &[u8], char for &str
    type Slice: core::fmt::Debug;      // a run of Tokens returned by parsers
    type Checkpoint: Offset + Clone + core::fmt::Debug;

    fn next_token(&mut self) -> Option<Self::Token>;
    fn checkpoint(&self) -> Self::Checkpoint;   // save a parse position
    fn reset(&mut self, checkpoint: &Self::Checkpoint);  // backtrack to one
    // iter_offsets, eof_offset, next_slice, offset_for, offset_at, …
}
```

Two design points matter. First, the associated **`Slice`** type: winnow parsers
return `Stream::Slice`, _not_ `Stream`. The migration guide explains why this beats
`nom`'s "return the same input type" convention ([`nom.rs`][nommig]):

> _"In `nom`, parsers like `take_while` parse a `Stream` and return a `Stream`. When
> wrapping the input, like with `Stateful`, you have to unwrap the input … and it
> requires `Stream` to be `Clone` (which requires `RefCell` for mutable external state
> and can be expensive). Instead, `Stream::Slice` was added to track the intended type
> for parsers to return."_

Second, `checkpoint`/`reset` make backtracking an explicit, cheap operation on the
mutated stream rather than an implicit consequence of holding an old `Copy` of the
input. This is what lets `I` avoid the `Copy`/`Clone` bound that `nom`'s signature
forces. Concrete `Stream` impls ship for `&[u8]`, `&str` (aliased [`Str`][docs]),
[`Bytes`][docs]/[`BStr`][docs] (binary/text debug views), [`LocatingSlice`][docs]
(span tracking — the in-house replacement for `nom_locate`), [`Stateful`][docs]
(thread `&mut S` state through parsers), and [`Partial`][docs] (streaming, below).

### `ErrMode` — modality made optional

`nom`'s three-way `Err` (`Error`/`Failure`/`Incomplete`) becomes winnow's **`ErrMode`**
([`src/error.rs`][error]):

```rust
// winnow: src/error.rs
pub enum ErrMode<E> {
    Incomplete(Needed),  // partial input: buffer more and retry (only for Partial<I>)
    Backtrack(E),        // recoverable (nom's Error): alt tries the next branch
    Cut(E),              // unrecoverable (nom's Failure): alt stops, report to user
}
```

The rename is deliberate — `Backtrack`/`Cut` _name the behaviour_ (do we retry another
branch, or bail?) rather than `nom`'s `Error`/`Failure`. `alt` is "an
`if-not-error-else` ladder" ([`nom.rs`][nommig]) that retries on `Backtrack`; the
[`cut_err`][core] combinator "Transforms an `ErrMode::Backtrack` (recoverable) to
`ErrMode::Cut` (unrecoverable)" ([`src/combinator/core.rs`][core]), the exact analogue
of `nom`'s `cut()`. The decisive ergonomic win is that **`ErrMode` is optional**
([`nom.rs`][nommig]):

> _"As this isn't needed in every parser, it was made optional. `ModalResult` is a
> convenience type for using `ErrMode`."_

A parser that uses neither `cut_err` nor `Partial` can be written with a plain
`winnow::Result<O>` (`= Result<O, ContextError>`), dropping the `ErrMode` wrapper
entirely; reach for `ModalResult<O> = Result<O, ErrMode<ContextError>>` only when you
need modality ([`src/error.rs`][error]). This is winnow's answer to a perennial `nom`
complaint — that `Err::{Error,Failure,Incomplete}` is a tax every parser pays.

### Context errors and `dispatch!`

The default error type is **`ContextError`**, which accumulates a `Vec` of context
frames as an error unwinds the call stack — the in-house equivalent of `nom`'s
`VerboseError` + `nom-supreme` ([`src/error.rs`][error]):

```rust
// winnow: src/error.rs
pub struct ContextError<C = StrContext> {
    context: alloc::vec::Vec<C>,
    cause: Option<Box<dyn std::error::Error + Send + Sync + 'static>>,  // std only
}
```

The [`Parser::context`][parser] method (doc-aliased `labelled`) pushes a named
`StrContext` frame — `digit1.context(StrContext::Expected(…))` — so a failure reads
like a breadcrumb trail, exactly as `nom`'s `context("…")` does but with a structured
`StrContext`/`StrContextValue` payload rather than a bare `&'static str`
([`src/parser.rs`][parser]).

For choice, winnow ships the [`dispatch!`][dispatchmacro] macro alongside `alt` — a
`match` over parsers that beats `alt`'s linear ladder when the alternatives have unique
prefixes ([`src/macros/dispatch.rs`][dispatchmacro]):

```rust
// winnow: src/macros/dispatch.rs
dispatch! {take(2usize);
    "0b" => take_while(1.., '0'..='1').try_map(|s| u64::from_str_radix(s, 2)),
    "0o" => take_while(1.., '0'..='7').try_map(|s| u64::from_str_radix(s, 8)),
    "0x" => take_while(1.., ('0'..='9','a'..='f','A'..='F')).try_map(|s| u64::from_str_radix(s, 16)),
    _ => fail::<_, u64, _>,
}
```

It "offers better performance over `alt` though it might be at the cost of duplicating
parts of your grammar" ([`dispatch.rs`][dispatchmacro]) — the performance topic lists
"When enough cases of an `alt` have unique prefixes, prefer `dispatch`" as a headline
tuning tip ([`src/_topic/performance.rs`][performance]).

### Streaming: `Partial<I>` instead of parallel modules

`nom`'s sharpest edge is that every streaming-capable primitive exists **twice** — in
a `streaming` and a `complete` module — and picking the wrong one silently changes
end-of-input behaviour. winnow eliminates the split: there is **one** set of parsers,
and partiality is a _property of the input type_. Wrap the stream in [`Partial<I>`][docs]
and the same parsers report `Incomplete` ([`src/_topic/partial.rs`][partial]):

> _"By wrapping a stream, like `&[u8]`, with `Partial`, parsers will report when the
> data is `Incomplete` and more input is `Needed`, allowing the caller to stream-in
> additional data to be parsed."_

with a documented caveat that distinguishes winnow's approach from a resumable
coroutine ([`partial.rs`][partial]):

> _"`winnow` takes the approach of re-parsing from scratch. Chunks should be relatively
> small to prevent the re-parsing overhead from dominating."_

The `nom 8.0` rewrite instead back-propagates a `parse_complete` flag through GATs to
select `complete` behaviour; winnow's `Partial<I>` tag reaches the same goal without
that machinery (next section).

---

## Algorithm & grammar class

Like [`nom`][nom], winnow is a **scannerless, hand-rolled [recursive-descent][top-down]**
engine that behaves operationally as a [PEG][peg]: `alt` is **ordered choice** (first
branch to succeed wins, `Backtrack` triggers the next), there is no built-in
left-recursion (a left-recursive parser recurses forever — left-associative operators
are written with `repeat`/`fold` instead), and there is no declarative grammar to
analyze for ambiguity — _the order you write alternatives in is the disambiguation_.
Lookahead is unbounded but explicit via `peek` (parse without consuming) and the
`checkpoint`/`reset` pair. Scannerless is the _default_, not a mandate: `src/lib.rs`
lists "separate lexing and parsing phases" as a first-class supported mode
([`src/lib.rs`][lib]), and the [`_topic::lexing`][topicdir] topic documents it.

> [!NOTE]
> winnow, like `nom`, does **not** memoize — it is not a [packrat][peg] parser. A
> branch of `alt` that consumes a long prefix and then `Backtrack`s is re-run from the
> saved `checkpoint` by the next branch, with no per-position cache. Well-factored
> grammars stay linear; overlapping back-tracking branches can be super-linear, and the
> mitigations are the same as `nom`'s: factor common prefixes, prefer `dispatch!` on
> unique prefixes, or `cut_err` to commit.

## Interface & composition model

The grammar is **host-language Rust code** — an embedded DSL of combinator functions
and a few macros (`seq!`, `dispatch!`), never an external `.y`/`.g4` grammar file and
no build-time codegen. A parser is a normal `fn(&mut I) -> Result<O, E>` you can name,
document, `#[inline]`, and unit-test. winnow never shipped `nom`'s original `named!`
macro era, so there is no dead-macro tutorial-rot to wade through; free functions are
the idiom, reinforced by the design principle that "Grammar-level `Parser`s should be
free functions" ([`DESIGN.md`][design]).

The **AST/CST is whatever the closures build** — winnow imposes no tree type, no trivia
model, no generic CST; outputs are produced by `map`/`try_map`/`seq!` and can be kept
as zero-copy `Stream::Slice` borrows into the source (deferring interpretation) or
mapped into owned domain structs. It is an _AST-building_ toolkit, not a lossless-syntax
tool like [tree-sitter][treesitter].

## Performance

winnow's origin story is a performance one: it began as Ed Page's private `nom8` fork to
remove a performance cliff and shrink the hot-path types. The `&mut` model is itself a
performance argument — a smaller `Result::Ok` (no leftover `I`) and a smaller
`Result::Err` (the error need not carry `i` to point at the failure) keep results in
registers ([`nom.rs`][nommig]). The concrete tuning levers, from the performance topic
([`performance.rs`][performance]):

- **`simd` feature.** `cargo add winnow -F simd` pulls in `memchr`; "For some it offers
  significant performance improvements" ([`performance.rs`][performance]).
- **`dispatch!` over `alt`** when branches have unique prefixes (avoids the retry ladder).
- **Parse as bytes, not `char`s** where possible ("`BStr` can make debugging easier").
- **Watch return-type size** — large tuples chaining parsers bloat the `Ok` payload;
  and returning `impl Trait` from a combinator factory hurts _build_ time, so wrap
  chained combinators in a closure to simplify the type.

winnow deliberately forgoes the deepest optimization `nom 8.0` and [`chumsky`][chumsky]
both adopt — **"parse modes" via GATs**, which let a downstream parser tell an upstream
one that output/errors will be discarded so it can skip allocations. winnow's rationale
is _predictability_ over peak throughput ([`nom.rs`][nommig]):

> _"With GATs, seemingly innocuous changes like choosing to hand write a parser using
> idiomatic function parsers (`fn(&mut I) -> Result<O>`) can cause surprising slow downs
> because these functions sever the back-propagation from GATs."_

Instead of GATs, winnow recovers most of the wins with plainer machinery: the
[`Accumulate`][docs] trait lets `repeat` build a `Vec`, a `usize` count, or `()`
(no-op) depending on how its result is used; `dispatch!` sidesteps `alt`'s error
overhead; and a low-overhead `ContextError` keeps the error path cheap
([`nom.rs`][nommig], [`why.rs`][why]). The upshot is fewer monomorphized copies of each
parser ("parsers only need to be generated for one mode, not up to 8") — faster builds
and smaller binaries — at the cost of the last few percent of runtime a GAT-tailored
`nom 8` parser can reach. The cross-library JSON benchmark numbers behind winnow's
speed claims are quoted in the [`nom` deep-dive][nom] (winnow `0.5.0` at ~97 µs vs.
`nom 7.1.3` at ~341 µs, from Ed Page's Winnow 0.5 write-up).

## Error handling & recovery

winnow's error story has the same two layers as `nom` — **control flow** (`ErrMode`'s
`Backtrack`/`Cut`, driven by `cut_err`) and **diagnostics** (`ContextError` +
`context`) — described above. The genuinely new axis is **error recovery**, which `nom`
lacks entirely. Behind the `unstable-recover` feature, winnow provides a `Recoverable<I,
E>` stream wrapper and a `RecoverableParser::recoverable_parse` method that returns
_both_ a partial output and the collected errors ([`src/parser.rs`][parser]):

```rust
// winnow: src/parser.rs
fn recoverable_parse(&mut self, input: I) -> (I, Option<O>, Vec<R>);
```

so a parse can skip a malformed region, synthesize past it, and keep going to report
multiple errors — the resilience mode that makes [`chumsky`][chumsky] and
[tree-sitter][treesitter] suited to IDEs.

> [!IMPORTANT]
> winnow's recovery is real but **`unstable-recover`-gated** and `std`-only — it is not
> the whole-library, recovery-first posture of [`chumsky`][chumsky]. Out of the box
> winnow is still a _fail-fast_ parser like `nom`: a plain parse stops at the first
> `Cut`. What winnow adds over `nom` is that multi-error recovery is now _possible
> in-crate_ (opt-in) rather than absent, and that streaming is a property of the input
> (`Partial<I>`) rather than a `streaming`/`complete` module choice. For edit-incremental
> reparsing, the tool in this survey remains [tree-sitter][treesitter].

## Ecosystem & maturity

winnow is mature and load-bearing: it is the parser under [`toml_edit`][tomledit] and
therefore under Cargo's own manifest parsing, and it reached `1.0.0` on 2026-03-17
(the `CHANGELOG` notes v1 "is more a reflection of the rate of churn in Winnow's API
than … any statement against future breaking changes" ([`CHANGELOG.md`][changelog])).
The project's release cadence is codified in [`DESIGN.md`][design] (major every 6–9
months, deprecate-rather-than-break, `unstable-<name>` feature gates for large
features), and the MSRV policy is "the last 6 months of rust releases"
([`src/lib.rs`][lib]), pinned at `1.65.0` in [`Cargo.toml`][cargo]. It is MIT-licensed
and `#![no_std]`-capable (feature-gated: `std` → `alloc` → core), with `ascii`,
`binary`, and `parser` feature flags added at `1.0` to cut build time. Downstream, the
`gitoxide` project migrated its `gix-config`/`gix-protocol` parsers from `nom` to
winnow, and `typos` and `git-conventional` are among the documented ports
([`nom.rs`][nommig]).

---

## Strengths

- **`&mut Stream` ergonomics.** No manual `i`-threading, no forgetting to chain the
  leftover, and `I` need not be `Copy`/`Clone` — cleaner code than `nom`'s tuple return.
- **Optional `ErrMode`.** Simple parsers use a plain `Result<O, ContextError>`; modality
  (`Backtrack`/`Cut`/`Incomplete`) is opt-in via `ModalResult`, not a universal tax.
- **Batteries included, still a toolbox.** Span tracking (`LocatingSlice`), rich errors
  (`ContextError`), stateful streams (`Stateful`), tutorials, and `dispatch!`/`seq!` all
  in one crate — without `chumsky`'s framework lock-in.
- **Streaming without the module split.** `Partial<I>` tags the input; one set of
  parsers, no `streaming`/`complete` foot-gun.
- **Opt-in error recovery.** `unstable-recover` collects multiple errors — a resilience
  axis `nom` does not offer at all.
- **Zero-copy and fast.** Inherits `nom`'s slice-borrowing recognizers and monomorphized
  inlining; smaller `Ok`/`Err` payloads and `dispatch!` add headroom over `nom`.
- **Predictable performance.** No GAT parse-modes means no surprise cliffs from writing
  a parser imperatively; faster builds and smaller binaries as a bonus.

## Weaknesses

- **No memoization → backtracking foot-guns.** Same as `nom`: overlapping `alt` branches
  can be super-linear; factor prefixes, `dispatch!`, or `cut_err`.
- **No left recursion.** [PEG][peg]-style; left-associative operators need `repeat`/`fold`.
- **Recovery is unstable and partial.** `unstable-recover` is `std`-only and feature-gated;
  winnow is not a recovery-first library like [`chumsky`][chumsky], and has no
  edit-incremental mode ([tree-sitter][treesitter]'s domain).
- **Streaming re-parses from scratch.** `Partial<I>` chunks must be kept small or the
  re-parse overhead dominates — it is not a resumable coroutine.
- **`&mut` + lifetimes add annotation noise.** Returning a borrowed slice needs an
  explicit lifetime, and closures inside `alt` need `|i: &mut _|` type annotations
  ([`nom.rs`][nommig]).
- **API churn by design.** winnow deliberately breaks compatibility often (0.3→0.4→0.5→
  0.7→1.0); the deprecate-then-remove policy eases it, but tutorials still drift.

## Key design decisions and trade-offs

| Decision                                                                 | Rationale                                                                                   | Trade-off                                                                                                           |
| ------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| Parser = `Fn(&mut I) -> Result<O, E>` (advance in place)                 | No `i`-threading; `I` need not be `Copy`/`Clone`; smaller `Ok`/`Err` in registers           | Borrowed outputs need explicit lifetimes; closures need `\|i: &mut _\|` annotations — the precise cost `nom` avoids |
| Single `Stream` trait with associated `Slice`/`Checkpoint`               | One input abstraction; cheap explicit backtracking; no `Clone`/`RefCell` for stateful input | More associated types to understand than `nom`'s (pre-8) many input traits                                          |
| `ErrMode` made **optional** (`Result` vs `ModalResult`)                  | Simple parsers pay nothing; modality only where `cut_err`/`Partial` are used                | Two result types to learn; choosing wrong forces a later refactor                                                   |
| `Partial<I>` input tag instead of `streaming`/`complete` modules         | One set of parsers; partiality is a property of the input, not a per-primitive choice       | Re-parses from scratch — chunks must stay small; `repeat` over-reports `Incomplete`                                 |
| **Reject** GAT parse-modes (which `nom 8` adopted)                       | Predictable performance; faster builds; built-ins double as idiomatic examples              | Forgoes the last few % of runtime a GAT-tailored parser reaches; needs `Accumulate`/`dispatch!` work-arounds        |
| Batteries-included core (spans, errors, tutorials in-crate)              | Cohesive, high-quality experience; no `nom_locate`/`nom-supreme` version-skew               | Larger crate surface; more to maintain than `nom`'s deliberately small core                                         |
| Opt-in recovery behind `unstable-recover`                                | Multi-error resilience `nom` lacks, without destabilizing the default fail-fast path        | `std`-only, unstable API; still not `chumsky`-grade recovery-first                                                  |
| Break compatibility often, deprecate-then-remove ([`DESIGN.md`][design]) | Improve the model for future parsers rather than freeze it for current users                | Frequent migrations; online tutorials rot across 0.3→1.0                                                            |

---

## Sources

- [winnow-rs/winnow — GitHub repository][repo] · [docs.rs/winnow][docs] · [crates.io][crate]
- [`src/lib.rs` — "do everything" aspiration, MSRV policy, feature/module layout][lib]
- [`README.md` — crate summary and the credit to `nom`/Geal][readme]
- [`Cargo.toml` — MIT license, `1.0.3` version, MSRV `1.65.0`, `simd`/`unstable-recover` features][cargo]
- [`src/_topic/why.rs` — hand-written-vs-toolbox trade-offs, `nom`/`chumsky` positioning, matklad Pratt quote][why]
- [`src/_topic/nom.rs` — the `nom` migration guide: `&mut I` rationale, `Stream::Slice`, `ErrMode`, GATs rejected][nommig]
- [`src/_topic/performance.rs` — `simd`, `dispatch!`, byte-vs-`char`, return-type-size tuning][performance]
- [`src/_topic/partial.rs` — `Partial<I>` streaming model and the re-parse-from-scratch caveat][partial]
- [`src/parser.rs` — `Parser` trait (`parse_next`/`parse_peek`), `context`, `recoverable_parse`][parser]
- [`src/stream/mod.rs` — the `Stream` trait (`Token`/`Slice`/`Checkpoint`, `next_token`, `checkpoint`/`reset`)][stream]
- [`src/error.rs` — `ErrMode` (`Incomplete`/`Backtrack`/`Cut`), `ContextError`, `ModalResult`/`Result`][error]
- [`src/combinator/core.rs` — `cut_err` (`Backtrack`→`Cut`)][core]
- [`src/macros/dispatch.rs` — the `dispatch!` match-over-parsers macro][dispatchmacro]
- [`examples/css/parser.rs` — `hex_color` via `seq!` (the `nom` `hex_color` counterpart)][css]
- [`CHANGELOG.md` — release history: `0.4` (2023-03-18), `0.5` (2023-07-13), `1.0.0` (2026-03-17)][changelog]
- [`DESIGN.md` — release cadence, deprecate-then-break policy, free-function principle][design]
- Related deep-dives in this survey: [`nom` (the parent)][nom] · [PEG / packrat theory][peg] · [top-down / recursive descent][top-down] · [Pratt precedence][pratt] · [`chumsky`][chumsky] · [`combine`][combine] · [Haskell `parsec`][parsec] · [`flatparse`][flatparse] · [shared concepts][concepts] · [the comparison capstone][comparison]

<!-- References -->

[repo]: https://github.com/winnow-rs/winnow
[docs]: https://docs.rs/winnow
[crate]: https://crates.io/crates/winnow
[lib]: https://github.com/winnow-rs/winnow/blob/7539ec0fc27144bfdcf9a68b0dbbec48bd0d5bae/src/lib.rs
[readme]: https://github.com/winnow-rs/winnow/blob/7539ec0fc27144bfdcf9a68b0dbbec48bd0d5bae/README.md
[cargo]: https://github.com/winnow-rs/winnow/blob/7539ec0fc27144bfdcf9a68b0dbbec48bd0d5bae/Cargo.toml
[why]: https://github.com/winnow-rs/winnow/blob/7539ec0fc27144bfdcf9a68b0dbbec48bd0d5bae/src/_topic/why.rs
[nommig]: https://github.com/winnow-rs/winnow/blob/7539ec0fc27144bfdcf9a68b0dbbec48bd0d5bae/src/_topic/nom.rs
[performance]: https://github.com/winnow-rs/winnow/blob/7539ec0fc27144bfdcf9a68b0dbbec48bd0d5bae/src/_topic/performance.rs
[partial]: https://github.com/winnow-rs/winnow/blob/7539ec0fc27144bfdcf9a68b0dbbec48bd0d5bae/src/_topic/partial.rs
[parser]: https://github.com/winnow-rs/winnow/blob/7539ec0fc27144bfdcf9a68b0dbbec48bd0d5bae/src/parser.rs
[stream]: https://github.com/winnow-rs/winnow/blob/7539ec0fc27144bfdcf9a68b0dbbec48bd0d5bae/src/stream/mod.rs
[error]: https://github.com/winnow-rs/winnow/blob/7539ec0fc27144bfdcf9a68b0dbbec48bd0d5bae/src/error.rs
[core]: https://github.com/winnow-rs/winnow/blob/7539ec0fc27144bfdcf9a68b0dbbec48bd0d5bae/src/combinator/core.rs
[dispatchmacro]: https://github.com/winnow-rs/winnow/blob/7539ec0fc27144bfdcf9a68b0dbbec48bd0d5bae/src/macros/dispatch.rs
[seqmacro]: https://github.com/winnow-rs/winnow/blob/7539ec0fc27144bfdcf9a68b0dbbec48bd0d5bae/src/macros/seq.rs
[css]: https://github.com/winnow-rs/winnow/blob/7539ec0fc27144bfdcf9a68b0dbbec48bd0d5bae/examples/css/parser.rs
[changelog]: https://github.com/winnow-rs/winnow/blob/7539ec0fc27144bfdcf9a68b0dbbec48bd0d5bae/CHANGELOG.md
[design]: https://github.com/winnow-rs/winnow/blob/7539ec0fc27144bfdcf9a68b0dbbec48bd0d5bae/DESIGN.md
[topicdir]: https://github.com/winnow-rs/winnow/tree/7539ec0fc27144bfdcf9a68b0dbbec48bd0d5bae/src/_topic
[tutorialdir]: https://github.com/winnow-rs/winnow/tree/7539ec0fc27144bfdcf9a68b0dbbec48bd0d5bae/src/_tutorial
[tomledit]: https://crates.io/crates/toml_edit
[nom]: ./rust-nom.md
[peg]: ./theory/peg-packrat.md
[top-down]: ./theory/top-down.md
[pratt]: ./theory/pratt-precedence.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[umbrella]: ./index.md
[chumsky]: ./rust-chumsky.md
[parsec]: ./haskell-parsec.md
[flatparse]: ./haskell-flatparse.md
[combine]: ./rust-combine.md
[treesitter]: ./tree-sitter.md
