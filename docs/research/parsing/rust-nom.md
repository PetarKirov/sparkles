# nom (Rust)

A byte-oriented, zero-copy, streaming [parser-combinator][concepts] library for Rust whose parsers are ordinary functions of the form `Input -> IResult<Input, Output, Error>`, assembled bottom-up from small reusable pieces.

| Field           | Value                                                                                                       |
| --------------- | ----------------------------------------------------------------------------------------------------------- |
| Language        | Rust (the library is `#![no_std]`-capable; `std` is the default feature)                                    |
| License         | MIT                                                                                                         |
| Repository      | [rust-bakery/nom][repo]                                                                                     |
| Documentation   | [docs.rs/nom][docs] · [crates.io][crate] · [`doc/` design notes][docdir]                                    |
| Key authors     | Geoffroy Couprie (original author) and contributors; org maintainers at `rust-bakery`                       |
| Category        | [Parser combinator][concepts] (recursive-descent, scannerless)                                              |
| Algorithm class | Hand-rolled top-down / [recursive descent][topdown] with ordered choice; **not** a generated table parser   |
| Lexing model    | **Scannerless** — parsers consume `&[u8]`/`&str` directly; no separate lexer or token stream                |
| Grammar class   | Effectively [PEG][peg]-like (ordered choice, no built-in left-recursion, unbounded lookahead via the input) |
| Latest release  | `8.0.0` (2025-01-25)                                                                                        |

> [!NOTE]
> nom is the canonical _byte-oriented binary/network_ parser-combinator in the Rust
> ecosystem. It is the data point against which the [Haskell `parsec`][parsec]
> lineage, the [`chumsky`][chumsky] error-recovery library, and the modern fork
> [`winnow`][winnow] (covered below) are compared in this survey. See the
> [comparison][comparison] capstone for the cross-subject synthesis.

---

## Overview

### What it solves

A parser combinator turns parsing from a code-generation problem into a _composition_
problem. Where [`yacc`/`bison`][bison] and [ANTLR][antlr] take a grammar in a separate
DSL and emit a table-driven state machine, nom asks you to write tiny Rust functions —
"take 5 bytes", "recognize the word `HTTP`" — and glue them together with higher-order
combinators. The crate-root documentation states the contrast directly
([`src/lib.rs`][lib]):

> _"Parser combinators are an approach to parsers that is very different from software
> like lex and yacc. Instead of writing the grammar in a separate syntax and generating
> the corresponding code, you use very small functions with very specific purposes,
> like 'take 5 bytes', or 'recognize the word HTTP', and assemble them in meaningful
> patterns."_

The library's stated goal ([`README.md`][readme]) is narrow and performance-led:

> _"nom is a parser combinators library written in Rust. Its goal is to provide tools
> to build safe parsers without compromising the speed or memory consumption."_

nom's design centre of gravity is **binary and network formats**: it is byte-oriented
and bit-oriented first, string-oriented second. It was created by Geoffroy Couprie to
write _safe_ replacements for the kind of memory-unsafe C parsers that historically
sit at the root of security vulnerabilities — the thesis of the LangSec/SSTIC paper
_"Writing parsers like it is 2017"_ ([Chifflier & Couprie][langsec]), whose nom-based
parsers shipped into [Suricata][rusticata] (the IDS/IPS engine, Rust parsers since
Suricata 4.0) and were prototyped against media formats in VLC.

### Design philosophy

Three properties define nom, each a verbatim claim from its own documentation.

**Zero-copy.** A nom parser never duplicates the bytes it recognizes; recognized spans
are returned as _slices_ that borrow the original input ([`README.md`][readme]):

> _"If a parser returns a subset of its input data, it will return a slice of that
> input, without copying."_

This falls directly out of Rust's borrow checker: a `&[u8]` or `&str` output is tied by
lifetime to the input buffer, so "parse" for a span-shaped result is just pointer +
length, allocation-free.

**Streaming-correct by construction.** nom distinguishes _"I cannot decide yet, give me
more bytes"_ from _"this input is wrong"_ ([`README.md`][readme]):

> _"nom has been designed for a correct behaviour with partial data: If there is not
> enough data to decide, nom will tell you it needs more instead of silently returning
> a wrong result."_

That signal is the `Err::Incomplete(Needed)` variant (see [Algorithm & grammar
class](#algorithm--grammar-class)), the feature that makes nom suitable for parsing a
network byte stream as it arrives rather than only a fully-buffered message.

**Speed competitive with handwritten C.** Because each combinator monomorphizes into a
concrete function with no dynamic dispatch on the hot path, the optimizer collapses a
tower of combinators into tight code ([`README.md`][readme]):

> _"Benchmarks have shown that nom parsers often outperform many parser combinators
> library like Parsec and attoparsec, some regular expression engines and even
> handwritten C parsers."_

Couprie summarizes the family resemblance in [`src/lib.rs`][lib]: parsers are _"small
and easy to write"_, _"easy to reuse"_, _"easy to test separately"_, and _"the parser
combination code looks close to the grammar you would have written"_.

---

## How it works

### Core abstractions and types

| Concept                | Type / item                                             | Role                                                                          |
| ---------------------- | ------------------------------------------------------- | ----------------------------------------------------------------------------- |
| Parser result          | `IResult<I, O, E = Error<I>>`                           | `Result<(I, O), Err<E>>` — remaining input + output, or an error/`Incomplete` |
| Error wrapper          | `Err<E>`                                                | Three-way: `Incomplete(Needed)`, `Error(E)`, `Failure(E)`                     |
| The parser abstraction | `Parser<Input>` trait                                   | Anything callable as a parser; all combinators and methods hang off it        |
| Input abstraction      | `Input` trait (8.x; was `InputIter`/`InputTake`/…)      | What makes `&[u8]`, `&str`, `&[T]`, and custom types parseable                |
| Error contract         | `ParseError<I>`, `ContextError<I>`, `FromExternalError` | Lets a user error type plug into every combinator                             |
| Concrete error types   | `Error<I>` (default), `VerboseError<I>`                 | The minimal error vs. the diagnostic, context-accumulating error              |
| Error tag              | `ErrorKind`                                             | Which combinator failed (`Tag`, `Alt`, `Many1`, …)                            |
| Insufficiency          | `Needed::{Unknown, Size(NonZeroUsize)}`                 | How many more bytes a streaming parser wants                                  |

### Parsers are functions

The foundational idea is that a parser is _just a function_ from input to an `IResult`
([`doc/making_a_new_parser_from_scratch.md`][scratch]):

> _"nom parsers are functions that use the `nom::IResult` type everywhere. … a parser
> taking a byte slice `&[u8]` and returning a 32 bits unsigned integer `u32` would have
> this signature: `fn parse_u32(input: &[u8]) -> IResult<&[u8], u32>`."_

`IResult` is a thin alias over the standard library's `Result`:

```rust
// nom: src/internal.rs
pub type IResult<I, O, E = Error<I>> = Result<(I, O), Err<E>>;

pub enum Err<E> {
    /// There was not enough data
    Incomplete(Needed),
    /// The parser had an error (recoverable)
    Error(E),
    /// The parser had an unrecoverable error
    Failure(E),
}
```

The success arm carries `(I, O)` — the **remaining input** alongside the **output** —
so a caller (or the next combinator) resumes exactly where the previous parser stopped.
This "thread the leftover input through" convention is the spine of the whole library,
and is the single design point that [`winnow`][winnow] later inverted (it returns the
leftover by mutating a `&mut I` instead; see [The winnow fork](#the-winnow-fork-the-modern-successor)).

### Combinators: parsers that take parsers

Building blocks are assembled _bottom-up_ ([`doc/making_a_new_parser_from_scratch.md`][scratch]):
_"Parsers are usually built from the bottom up, by first writing parsers for the
smallest elements, then assembling them in more complex parsers by using
combinators."_ A combinator is a function that **generates** a parser; the crate root
gives the canonical signature ([`src/lib.rs`][lib]):

> _"nom is based on functions that generate parsers, with a signature like this:
> `(arguments) -> impl Fn(Input) -> IResult<Input, Output, Error>`. The arguments of a
> combinator can be direct values (like `take` which uses a number of bytes or
> character as argument) or even other parsers."_

The post-`5.0` API is **functions**, not the macros nom originally shipped (see
[Interface & composition model](#interface--composition-model)). The frequently-used
combinators, grouped by purpose ([docs.rs/nom][docs]):

| Group           | Combinators                                                            | Meaning                                         |
| --------------- | ---------------------------------------------------------------------- | ----------------------------------------------- |
| Basic elements  | `tag`, `take`, `take_while`, `take_until`, `char`, `one_of`            | Recognize literals / spans / single tokens      |
| Numbers         | `be_u16`, `le_u32`, `u8`, … (in `number::{streaming,complete}`)        | Fixed-width big/little-endian integers          |
| Sequence        | `preceded`, `terminated`, `delimited`, `separated_pair`, tuples        | Run parsers in order, keep some/all results     |
| Choice          | `alt`                                                                  | Ordered choice — first child that succeeds wins |
| Repetition      | `many0`, `many1`, `many_m_n`, `separated_list0`, `fold_many0`          | Apply a parser repeatedly, collecting results   |
| General-purpose | `opt`, `map`, `map_res`, `value`, `verify`, `recognize`, `cut`, `peek` | Transform, validate, commit, or look ahead      |

A small, representative example — recognizing `#rrggbb` hex colors — straight from the
nom `README.md` ([`README.md`][readme]):

```rust
// nom: README.md
fn hex_color(input: &str) -> IResult<&str, Color> {
  let (input, _) = tag("#")(input)?;
  let (input, (red, green, blue)) =
      (hex_primary, hex_primary, hex_primary).parse(input)?;

  Ok((input, Color { red, green, blue }))
}
```

Several conventions are on display at once: `tag("#")` returns a parser that is
immediately called on `input`; the `?` operator short-circuits on `Err`; the threaded
`input` is rebound at each step; and a **tuple of parsers is itself a parser** (run in
sequence, output is the tuple of outputs). A length-prefixed binary read shows the
byte-oriented side ([`doc/making_a_new_parser_from_scratch.md`][scratch]):

```rust
// nom: doc/making_a_new_parser_from_scratch.md
pub fn length_value(input: &[u8]) -> IResult<&[u8], &[u8]> {
    let (input, length) = be_u16(input)?;
    take(length)(input)          // returns a *slice* of `input` — zero-copy
}
```

`take(length)(input)` returns a `&[u8]` borrowing the original buffer: no allocation,
no copy. That is the zero-copy property made concrete.

### The `Parser` trait and the 8.0 rewrite

From the start every combinator was duck-typed as "a function returning `IResult`", but
nom also exposes a `Parser` trait so combinators can be invoked as methods. `nom 8.0`
(2025-01-25) re-founded the library on this trait. The `8.0` `CHANGELOG`
([`CHANGELOG.md`][changelog]) describes it as _"a significant refactoring of nom to
reduce the amount of code generated by parsers, and reduce the API surface"_, merging
the old menagerie of input traits — _"`InputIter`, `InputTakeAtPosition`, `InputLength`,
`InputTake` and `Slice` are now merged in the `Input` trait"_ — and switching the
idiomatic call style: _"Instead of writing `combinator(arg)(input)`, we now write
`combinator(arg).parse(input)`."_

The trait's required method became mode-parametric, so a single parser body can be
compiled in different "output modes" (produce the value, or just check that it matches)
([docs.rs `Parser`][parsertrait]):

```rust
// nom 8.0: src/internal.rs (Parser trait, abridged)
pub trait Parser<Input> {
    type Output;
    type Error: ParseError<Input>;

    fn process<OM: OutputMode>(
        &mut self,
        input: Input,
    ) -> PResult<OM, Input, Self::Output, Self::Error>;

    // provided combinator methods:
    fn parse(&mut self, input: Input) -> IResult<Input, Self::Output, Self::Error> { /* … */ }
    // map, and_then, flat_map, map_res, map_opt, and, or, …
}
```

The `OutputMode` type parameter is nom's answer to the "parse modes" optimization (run
the same grammar in a value-producing mode vs. a recognize-only mode without building
outputs) — the same idea `chumsky` realizes with GATs and `winnow` deliberately
side-steps. It is the deepest internal change in nom's history and the reason `8.x` is a
breaking release.

### Streaming vs complete

For every primitive that can run out of input, nom ships **two** versions in parallel
modules — `nom::bytes::streaming` / `nom::bytes::complete`,
`nom::character::streaming` / `…::complete`, `nom::number::streaming` / `…::complete`.
The crate docs state the difference precisely ([docs.rs/nom][docs]):

> _"A streaming parser assumes that we might not have all of the input data. This can
> happen with some network protocol or large file parsers, where the input buffer can be
> full and need to be resized or refilled. … A complete parser assumes that we already
> have all of the input data. This will be the common case with small files that can be
> read entirely to memory."_

The behavioural fork is at end-of-input. Ask `take(4)` for four bytes when only two
remain: the **streaming** parser returns `Err::Incomplete(Needed::Size(2))` (buffer more,
retry); the **complete** parser returns `Err::Error(..)` (this input genuinely ends
here). Picking the wrong module is the most common nom bug — a `complete` parser fed a
half-message reports a spurious syntax error; a `streaming` parser fed a finished buffer
asks forever for bytes that will never come.

---

## Algorithm & grammar class

nom is a **scannerless, hand-rolled [recursive-descent][topdown]** engine. There is no
grammar compilation step, no parse table, and no separate tokenizer — combinators consume
the raw `&[u8]`/`&str` directly, so lexing and parsing are one fused pass. Operationally
it behaves like a [PEG][peg]: `alt` is **ordered choice** (it tries children left to
right and commits to the first success), there is no built-in support for
left-recursion (a left-recursive combinator simply recurses forever), and there is no
declarative grammar to analyze for ambiguity — _the order you write the alternatives in
**is** the disambiguation_. Lookahead is unbounded but explicit: `peek` parses without
consuming, and a child of `alt` may consume arbitrarily far before failing and being
retried from the saved input position.

The streaming model is the genuinely distinctive algorithmic feature. The three-way
`Err` (`Incomplete` / `Error` / `Failure`) lets a parser be a _partial function over a
growing prefix_: `Incomplete(Needed)` is a first-class result meaning "this prefix is
consistent with a valid parse but underdetermined", which is precisely what a byte-stream
protocol decoder needs and what a `Result<T, E>`-only design (or a fully-buffered
combinator library) cannot express without conflating "need more" with "wrong".

> [!NOTE]
> nom does **not** memoize. Unlike a [packrat PEG][peg] parser, a child of `alt` that
> consumes a long prefix and then fails is simply re-run from the saved position by the
> next alternative; there is no per-position result cache. In practice nom grammars are
> written to factor out common prefixes (or to `cut` early) so that pathological
> backtracking does not arise, trading the linear-time guarantee of packrat for lower
> constant factors and zero cache memory.

## Interface & composition model

The grammar is expressed as **host-language Rust code** — an internal, embedded DSL of
combinator functions, not an external grammar file. This is the defining contrast with
the generator family ([`bison`/`yacc`][bison], [ANTLR][antlr], [Menhir][menhir]): there
is no `.y`/`.g4` file and no build-time code-generation step; a parser is a normal `fn`
you can name, document, unit-test, and `#[inline]`. Composition is by ordinary function
application and the higher-order combinators above.

The **AST/CST is whatever the closures build.** nom imposes no tree type. A combinator's
output is produced by `map`/`map_res` closures, so you assemble your own domain structs as
you go (the `Color { red, green, blue }` above), or — exploiting zero-copy — keep outputs
as borrowed `&str`/`&[u8]` slices into the source and defer interpretation. There is no
generic CST and no notion of trivia/whitespace preservation; nom is firmly an
_AST-building_ tool, not a lossless-syntax-tree tool like [tree-sitter][treesitter].

A note on API history: nom **originally shipped a macro DSL** (`named!`, `tag!`,
`alt!`, `do_parse!`). The `5.0` release (2019) rewrote the internals around functions —
the `CHANGELOG` describes it as _"a complete rewrite of nom internals to use functions
as a base for parsers, instead of macros"_, with the old macros kept as thin shims —
and `7.0` (2021) was _"the first release without the macros that were used since nom's
beginning"_ ([`CHANGELOG.md`][changelog]). New code uses the function/method API
exclusively; the macro era is the most common source of stale tutorials.

Input genericity is achieved through the `Input` trait (and its `8.x` predecessors). A
parser written against `I: Input` runs over `&[u8]`, `&str`, `&[T]`, or any user type
implementing the trait — the mechanism third-party crates like [`nom_locate`][nomlocate]
(line/column-tracking spans) and [`bytes`] integrations exploit.

## Performance

Performance is nom's headline and its principal reason for existing. The characteristics:

- **Time complexity** is that of the grammar you write — typically linear in input for
  well-factored grammars, but with **no memoization** an `alt` with overlapping,
  back-tracking alternatives can be super-linear in the worst case (the same trap as any
  unmemoized [PEG][peg]). Mitigations are factoring and `cut` (commit to a branch,
  converting `Error` to `Failure` so `alt` stops retrying).
- **Zero-copy** outputs (`&[u8]`/`&str` slices borrowing the input) mean a recognizer
  allocates nothing; allocation happens only where _you_ build owned structures
  (`Vec`, `String`) in a `map`.
- **Monomorphization, no dynamic dispatch.** Each combinator is a concrete generic; the
  compiler inlines the tower into straight-line code, which is why the README can claim
  parity with handwritten C.
- **Bit-level and SIMD-adjacent.** nom has dedicated bit parsers (`nom::bits`) and a
  `bitvec` integration (added in 6.0, split out to the `nom-bitvec` crate in 7.0). It does not itself vectorize, but it is the
  glue layer often paired with hand-vectorized primitives; it is not a data-parallel
  engine like [`simdjson`][simdjson].
- **Published benchmarks.** The README's "outperform … even handwritten C parsers"
  claim is backed by [`rust-bakery/parser_benchmarks`][benchmarks]. The most
  illuminating external numbers come from the [`winnow`][winnow] fork's author, Ed Page,
  who benchmarked nom against its successors on chumsky's JSON benchmark
  ([Winnow 0.5 blog][epage5]): **nom 7.1.3 at 341.28 µs**, chumsky (zero-copy) at
  191.06 µs, winnow 0.3.6 at 125.54 µs, winnow 0.5.0 at 97.328 µs. nom is fast, but the
  fork demonstrated headroom nom's pure-function signature left on the table (below).

## Error handling & recovery

nom's error story has two layers: a **control-flow** layer and a **diagnostics** layer.

**Control flow — the three-way error.** The `Err` enum is the mechanism
([`doc/error_management.md`][errormgmt]). `Error(E)` is _"a normal parser error"_ and is
**recoverable**: inside `alt` it makes the combinator _"try another child parser."_
`Failure(E)` is _"an error from which we cannot recover"_ and is **unrecoverable**:
_"the `alt` combinator will not try other branches if a child parser returns
`Failure`."_ The bridge between them is the `cut()` combinator, which _"transform[s] an
`Error` into `Failure`"_ once _"we know we were in the right branch"_ — the standard way
to turn "try the next alternative" into "this is definitely an `if`-statement, so a
parse error here is a real syntax error, report it." `Incomplete` is the third arm,
orthogonal to the other two (see [streaming](#streaming-vs-complete)).

**Diagnostics — `VerboseError` and `context`.** The default `Error<I>` is minimal (an
input position + an `ErrorKind` tag) for speed. For human-readable messages nom offers
`VerboseError<I>`, which _accumulates_ a `Vec` of `(input, VerboseErrorKind)` frames as
the error unwinds the call stack, where `VerboseErrorKind` is `Context(&'static str)`,
`Char(char)`, or `Nom(ErrorKind)` ([`doc/error_management.md`][errormgmt]). The
`context("…")` combinator pushes a named frame, so the final error reads like a
breadcrumb trail ("while parsing _array_, while parsing _value_, expected `]`"). Custom
error types plug in through three traits: `ParseError<I>` (the core contract:
`from_error_kind`, `append`, `from_char`, `or`), `ContextError<I>` (adds `add_context`
for the `context` combinator), and `FromExternalError` (wraps a foreign error surfaced
by `map_res`). The popular [`nom-supreme`] crate builds richer, ready-made error trees
on these traits.

> [!IMPORTANT]
> nom is a _parser_, not an _error-recovery framework_. Its model is "fail fast with a
> good message", not "synthesize a placeholder node and keep going to report many errors
> at once." There is **no automatic error recovery** and **no incremental reparsing**:
> a nom parse is a single pass that stops at the first `Failure`. For multi-error
> recovery, IDE-grade resilience, or incremental editing, the relevant tools in this
> survey are [`chumsky`][chumsky] (recovery-first combinators) and
> [tree-sitter][treesitter] (incremental, error-tolerant CSTs). nom's `Incomplete` gives
> it _streaming_ resumption, which is a different axis from _edit_ resumption.

## Ecosystem & maturity

nom is one of the most-depended-upon non-trivial crates in the Rust ecosystem. As of
this review crates.io reports **576,482,486 total downloads** for `nom` and **2,531
reverse dependencies** ([crates.io][crate]). It is battle-tested in security-sensitive
production: the [`rusticata`][rusticata] family of protocol parsers (`tls-parser`,
`der-parser`, `x509-parser`, `asn1-rs`, `ipsec-parser`, …) is built on nom and is shipped
inside [Suricata][rusticata] (Rust parsers since Suricata 4.0); the video encoder
[`rav1e`], the C-expression parser [`cexpr`] used by `bindgen`, `iso8601`,
`hdrhistogram`, and `unsigned-varint` are all direct dependents visible in nom's
reverse-dependency list. The library is mature and stable, released under the
permissive **MIT** license, `#![no_std]`-capable, and still actively maintained by the
`rust-bakery` org after Couprie's original authorship.

Its most consequential derivative is **[`winnow`][winnow]** (next section) — a hard fork
that is itself now enormously adopted (it is the parser under
[`toml_edit`][tomledit]/`toml`, and therefore under Cargo's manifest parsing). Other
notable companions are [`nom_locate`][nomlocate] (span/line-column tracking) and
[`nom-supreme`] / [`nom-language`] (better errors and language-oriented helpers, the
latter extracted as its own crate in `8.0`).

---

## The winnow fork (the modern successor)

[`winnow`][winnow] is Ed Page's fork of nom, created to back the [`toml_edit`][tomledit]
crate (it began life as Page's private `nom8` fork before becoming a standalone library).
It keeps nom's combinator philosophy but changes the foundational types for ergonomics
and speed. Page's own framing ([Winnow 0.5 blog][epage5]):

> _"Winnow started as a fork of nom as I had found its toolbox model of parsers worked
> much better for me than the framework model other parser libraries used like combine.
> The original goals for the fork were to improve the developer experience and to remove
> a corner case that had a performance cliff you could fall off of."_

The four substantive differences a nom user must understand when migrating
([winnow `_topic::nom`][winnowmig], [winnow `_topic::why`][winnowwhy]):

| Axis                | nom                                                | winnow                                                                 |
| ------------------- | -------------------------------------------------- | ---------------------------------------------------------------------- |
| Parser signature    | `Fn(I) -> IResult<I, O, E>` (returns leftover `I`) | `Fn(&mut I) -> Result<O, E>` (advances `I` in place, by mutation)      |
| Why                 | thread the remaining input through every call      | _"Cleaner code … No forgetting to chain `i` … `I` need not be `Copy`"_ |
| Error/backtracking  | `Err::{Error, Failure, Incomplete}`                | `ErrMode::{Backtrack, Cut, Incomplete}` (modality, made _optional_)    |
| Commit combinator   | `cut(...)` (`Error` → `Failure`)                   | `cut_err(...)` (`Backtrack` → `Cut`)                                   |
| Streaming           | separate `streaming`/`complete` modules            | one set of parsers; partiality is a property of the `Partial<I>` input |
| Sequence of parsers | tuple `(a, b, c)` / `tuple((a, b, c))`             | `seq!` macro / `(a, b, c)`                                             |

The signature change is the heart of it ([winnow `_topic::nom`][winnowmig]): _"`winnow`
switched from pure-function parser (`Fn(I) -> (I, O)` to `Fn(&mut I) -> O`)"_, on the
grounds of _"Cleaner code: Removes need to pass `i` everywhere"_, _"Correctness: No
forgetting to chain `i` through a parser"_, _"Flexibility: `I` does not need to be `Copy`
or even `Clone`"_, and _"Performance: `Result::Ok` is smaller without `i`"_. On error,
the mutated input is _"left pointing at where the error happened"_, which simplifies
error reporting. winnow also folds `Incomplete` into an _optional_ modality: if you use
neither `cut_err` nor `Partial`, you can drop `ErrMode` entirely and parse with a plain
`winnow::Result<O>`.

The fork is **faster** on the same benchmarks (the JSON numbers above show winnow 0.5.0
at 97 µs vs. nom 7.1.3 at 341 µs), partly from the smaller `Ok` payload, partly from
_"sprinkling some `#[inline]`s"_, removing a `&str` token-set implementation that was
_"7x slower"_, and _"switching to imperative, rather than pure-functional parsing"_
([Winnow 0.5 blog][epage5]). winnow also pulls the ecosystem in-house — span tracking,
better errors, and tutorials live in the one crate rather than across `nom_locate` /
`nom-supreme`, aiming (per its docs) to _"include all the fundamentals for parsing to
ensure the experience is cohesive and high quality."_

> [!NOTE]
> **Which to reach for.** nom and winnow are siblings, not rivals with a clear winner.
> nom is the long-established, MIT-licensed, byte-oriented incumbent with the larger
> reverse-dependency graph and the `rusticata` security pedigree. winnow is the
> ergonomics-and-speed-forward successor, now load-bearing under Cargo via
> [`toml_edit`][tomledit]. The migration guide notes that _"where names diverge, a doc
> alias exists"_, so porting is mostly mechanical. For a green-field Rust parser in 2025,
> winnow is the more actively-evolving choice; for an existing nom codebase or one in the
> security-parser ecosystem, nom remains fully supported.

---

## Strengths

- **Zero-copy, allocation-free recognition.** Recognized spans are borrowed `&[u8]`/`&str`
  slices; a pure recognizer allocates nothing.
- **First-class streaming.** `Err::Incomplete(Needed)` cleanly separates "need more
  bytes" from "wrong input" — exactly right for network protocols and large-file
  decoders; very few combinator libraries model this.
- **Byte/bit-oriented.** Big/little-endian integers, bit-level parsers, and a `bitvec`
  integration make binary formats first-class, not an afterthought.
- **Fast.** Monomorphized, inlined combinators reach handwritten-C territory on the
  project's own benchmarks.
- **Safe.** All the speed lives inside Rust's memory-safety guarantees — the entire
  reason nom was created (replacing unsafe C parsers in security-critical paths).
- **Composable and testable.** Each parser is an ordinary, individually-unit-testable
  function; the grammar lives in normal Rust with full IDE/`rustc` support, no codegen
  step.
- **Battle-tested.** 576M+ downloads, 2,531 reverse deps, shipping inside Suricata via
  `rusticata`.

## Weaknesses

- **No memoization → backtracking foot-guns.** Overlapping `alt` branches can be
  super-linear; the author must factor common prefixes or `cut` deliberately.
- **No left recursion.** Like any [PEG][peg]-style engine, left-recursive grammars must
  be rewritten (e.g. with `many0`/`fold_many0` for left-associative operators).
- **No error recovery, no incremental reparsing.** A parse stops at the first `Failure`;
  there is no resynchronization to collect multiple errors and no edit-incremental mode —
  use [`chumsky`][chumsky] or [tree-sitter][treesitter] for those.
- **`streaming` vs `complete` is a sharp edge.** Choosing the wrong module silently
  changes end-of-input behaviour; a perennial source of confusion.
- **Error ergonomics are opt-in.** Good messages require `VerboseError` + `context` (or
  `nom-supreme`); the default `Error<I>` is terse by design.
- **API churn across majors.** The macro→function (`5.0`/`7.0`) and the `8.0`
  `OutputMode`/`.parse()` rewrite mean tutorials rot; much online material targets the
  dead macro API.

## Key design decisions and trade-offs

| Decision                                                     | Rationale                                                                         | Trade-off                                                                                                                          |
| ------------------------------------------------------------ | --------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| Parser = `Fn(I) -> IResult<I, O, E>` (thread leftover)       | Pure functions: trivially composable, testable, no hidden state                   | Caller must chain `i` everywhere; larger `Ok` payload; `I` must be `Copy`/`Clone` — the precise points [`winnow`][winnow] inverted |
| Zero-copy slice outputs borrowing the input                  | No allocation for recognizers; speed parity with C                                | Output lifetimes tie results to the input buffer; owned data needs an explicit `map`                                               |
| Three-way `Err` (`Error`/`Failure`/`Incomplete`)             | Separates recoverable, committed, and "need more data" — enables true streaming   | Extra concept to learn; `streaming` vs `complete` module split is easy to get wrong                                                |
| Ordered choice (`alt`), no ambiguity analysis                | Determinism and speed; no grammar-compilation phase                               | Author owns disambiguation; no left recursion; unmemoized backtracking can be quadratic                                            |
| Function-combinator API (post-`5.0`), macros retired (`7.0`) | First-class IDE/type support, readable errors, no macro magic                     | Two API generations of churn; legacy macro tutorials are misleading                                                                |
| `8.0` `Parser` trait + `OutputMode`                          | Recognize-only vs value-producing modes; less generated code, smaller API surface | Breaking release; advanced trait signatures (`process<OM>`) are harder to read                                                     |
| Minimal default `Error<I>`, opt-in `VerboseError`            | Keep the fast path allocation-free and small                                      | Human-readable diagnostics require extra wiring (`context`, `VerboseError`, `nom-supreme`)                                         |

---

## Sources

- [rust-bakery/nom — GitHub repository][repo]
- [nom on docs.rs (8.0.0)][docs] · [crates.io download stats][crate]
- [`src/lib.rs` — crate-root docs: combinator model, function-generating-parser signature, streaming vs complete][lib]
- [`README.md` — zero-copy / streaming / performance claims, `hex_color` example][readme]
- [`doc/making_a_new_parser_from_scratch.md` — parsers as functions, `IResult`, `length_value`][scratch]
- [`doc/error_management.md` — `Err` three-way model, `cut`, `VerboseError`, `context`, error traits][errormgmt]
- [`CHANGELOG.md` — `5.0` macro→function rewrite, `7.0` macro removal, `8.0` `Parser`/`OutputMode` refactor][changelog]
- [`Parser` trait — docs.rs (8.0 `process<OM: OutputMode>`)][parsertrait]
- [`rust-bakery/parser_benchmarks` — the project's own benchmark suite][benchmarks]
- [Chifflier & Couprie, _"Writing parsers like it is 2017"_ (LangSec/SSTIC) — security motivation, VLC/Suricata][langsec]
- [`rusticata` — nom-based protocol parsers shipped in Suricata][rusticata]
- [winnow-rs/winnow — the fork][winnow] · [winnow `_topic::why`][winnowwhy] · [winnow `_topic::nom` migration guide][winnowmig]
- [Ed Page, _"Winnow 0.5: The Fastest Rust Parser-Combinator Library?"_ — fork rationale + benchmarks][epage5]
- Related deep-dives in this survey: [PEG / packrat theory][peg] · [top-down / recursive descent][topdown] · [`chumsky`][chumsky] · [Haskell `parsec`][parsec] · [`simdjson`][simdjson] · [tree-sitter][treesitter] · [the comparison capstone][comparison]

<!-- References -->

[repo]: https://github.com/rust-bakery/nom
[docs]: https://docs.rs/nom/latest/nom/
[crate]: https://crates.io/crates/nom
[docdir]: https://github.com/rust-bakery/nom/tree/51c3c4e44fa78a8a09b413419372b97b2cc2a787/doc
[lib]: https://github.com/rust-bakery/nom/blob/51c3c4e44fa78a8a09b413419372b97b2cc2a787/src/lib.rs
[readme]: https://github.com/rust-bakery/nom/blob/51c3c4e44fa78a8a09b413419372b97b2cc2a787/README.md
[scratch]: https://github.com/rust-bakery/nom/blob/51c3c4e44fa78a8a09b413419372b97b2cc2a787/doc/making_a_new_parser_from_scratch.md
[errormgmt]: https://github.com/rust-bakery/nom/blob/51c3c4e44fa78a8a09b413419372b97b2cc2a787/doc/error_management.md
[changelog]: https://github.com/rust-bakery/nom/blob/51c3c4e44fa78a8a09b413419372b97b2cc2a787/CHANGELOG.md
[parsertrait]: https://docs.rs/nom/latest/nom/trait.Parser.html
[benchmarks]: https://github.com/rust-bakery/parser_benchmarks
[langsec]: http://spw17.langsec.org/papers/chifflier-parsing-in-2017.pdf
[rusticata]: https://github.com/rusticata/rusticata
[nomlocate]: https://github.com/fflorent/nom_locate
[nom-supreme]: https://crates.io/crates/nom-supreme
[nom-language]: https://crates.io/crates/nom-language
[rav1e]: https://crates.io/crates/rav1e
[cexpr]: https://crates.io/crates/cexpr
[bytes]: https://crates.io/crates/bytes
[winnow]: https://github.com/winnow-rs/winnow
[winnowwhy]: https://docs.rs/winnow/latest/winnow/_topic/why/index.html
[winnowmig]: https://docs.rs/winnow/latest/winnow/_topic/nom/index.html
[epage5]: https://epage.github.io/blog/2023/07/winnow-0-5-the-fastest-rust-parser-combinator-library/
[tomledit]: https://crates.io/crates/toml_edit
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[peg]: ./theory/peg-packrat.md
[topdown]: ./theory/top-down.md
[parsec]: ./haskell-parsec.md
[chumsky]: ./rust-chumsky.md
[simdjson]: ./simdjson.md
[treesitter]: ./tree-sitter.md
[bison]: ./bison-yacc.md
[antlr]: ./antlr.md
[menhir]: ./menhir.md
