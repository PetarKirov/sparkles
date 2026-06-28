# chumsky (Rust)

A Rust [parser-combinator][concepts] library built around first-class **error recovery** and rich diagnostics: a parser is an ordinary Rust value, but a failing parse yields a _partial_ AST **and** a list of errors rather than bailing on the first mistake — the property that makes it suited to building real language frontends and LSPs.

| Field                     | Value                                                                                                                             |
| ------------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| Language                  | Rust (`no_std`-capable)                                                                                                           |
| License                   | MIT                                                                                                                               |
| Repository                | [zesterer/chumsky][repo] (now primary on [Codeberg][codeberg]; GitHub mirror archived)                                            |
| Documentation             | [docs.rs/chumsky][docs] · [crates.io][crate] · [lib.rs][librs]                                                                    |
| Key authors               | Joshua Barretto ([zesterer]) and contributors                                                                                     |
| Category                  | Parser combinator (internal DSL, host-language-embedded)                                                                          |
| Algorithm / grammar class | Recursive-descent over **PEG** (ordered choice, no ambiguity); opt-in left-recursion + memoization; context-sensitive combinators |
| Lexing model              | Scannerless _or_ two-stage — generic over `Input`, so the same combinators run over `&str`, `&[u8]`, or a `&[Token]` slice        |
| Latest release            | `0.13.0` (published line; the `1.0.0-alpha.0` tag marks where the zero-copy rewrite incubated)                                    |

> [!NOTE]
> The published **`0.x`** line carries the **zero-copy rewrite** since [`0.10.0`][rel010] (2025-03-22), with `0.13.0` current in the cloned Codeberg source. The earlier `1.0.0-alpha.0` tag is where the rewrite incubated before landing in the published line. This deep-dive describes the **zero-copy** API — the [`Parser`][parser-trait] trait parameterised by an input lifetime `'src` — not the pre-rewrite `0.9.x` API, which differs substantially.

---

## Overview

### What it solves

A **parser generator** ([Bison][bison], [ANTLR][antlr], [Menhir][menhir], [tree-sitter][tree-sitter]) consumes a grammar in a separate DSL and emits parsing code. A **parser combinator** library — the [Parsec][parsec] lineage in Haskell, [`nom`][nom] and chumsky in Rust — takes the opposite stance: a parser is a first-class value of the host language, and bigger parsers are built from smaller ones with ordinary functions ("combinators"), so the full power of Rust is available _inside_ the grammar. chumsky's README states the goal plainly ([`README.md`][readme]):

> _"Chumsky is a parser library for Rust that makes writing expressive, high-performance parsers easy."_

What sets chumsky apart from its combinator siblings is the problem it makes _central_: **error recovery**. Most parsers — generated or hand-written, including the existing Rust combinator libraries — are designed to accept valid input and produce, in the words of the author, "either a syntax tree or a single error message", not both. chumsky's author Joshua Barretto argues in the library's founding blog post that this framing is backwards ([_Why can't error-tolerant parsers also be easy to write?_][blog]):

> _"Error reporting is, therefore, not simply an unusual deviation from the happy path: it **is** the happy path, and it is the one that we should prioritise thinking about when writing parsers."_

The motivation is the modern compiler / IDE workload ([blog][blog]):

> _"Modern software is complex and modern programming languages even more so. With rich static type systems and complex, heavyweight build systems, it's suddenly important that compilers can produce errors that can be fixed in batches to maintain developer productivity."_

A parser that gives up at the first syntax error forces a slow edit-compile-fix-recompile loop and produces no AST for later stages (name resolution, type-checking, autocomplete) to work on. chumsky instead encounters an error, **reports** it, **resynchronises** with the input, and **resumes** — so one run yields many errors and a best-effort AST. The crate's own recovery guide names those three steps and the payoff ([`guide::_03_error_and_recovery`][guide-recovery]):

> _"This approach yields significant benefits, it allows us to generate multiple errors per each run of our parser, which means less back and forth with the user."_

### Design philosophy

chumsky's thesis is that **declarative ergonomics and error resilience are not in tension** — that you should not have to choose between a terse combinator grammar and the hand-written, error-recovering parsers shipped by mature compilers (Rust's, Elm's). From the blog ([blog][blog]):

> _"I'm convinced that it's not only possible, but also practical, to write high-quality parsers that perform reliable error recovery using more declarative approaches to parser development."_

The key claim is that recovery costs almost nothing at the call site, because all the machinery — generating, recording, and selecting between error sets on different parse branches — is hidden behind the combinator API ([blog][blog]):

> _"Despite this fact, the logic that generates errors, records errors, performs recovery, and selects between error sets on different parse branches is all hidden behind the declarative parser API. … None of these features come with any significant syntax overhead, nor implementation complexity. The code required to perform error recovery in this JSON parser is just 3 lines, for example."_

Three further commitments shape the whole API:

1. **Generic over everything.** A chumsky parser is parameterised over its input, token, output, span, and error types. The README's first feature is _"Fully generic across input, token, output, span, and error types"_ ([`README.md`][readme]). The same combinators parse a scannerless `&str`, a byte slice, or a slice of pre-lexed tokens.
2. **Zero-copy by default.** Outputs can borrow directly from the input rather than copying it. The README: _"Zero-copy parsing minimises allocation by having outputs hold references/slices of the input"_ ([`README.md`][readme]). This is the headline of the [rewrite](#performance) that produced today's `Parser<'src, …>` trait.
3. **PEG semantics, no ambiguity.** chumsky's parsers are recursive-descent and accept [Parsing Expression Grammars][theory-peg] — ordered choice, deterministic, no parse forests — extended with explicit combinators for the context-sensitive constructs ([below](#context-sensitive-parsing-stateful-and-nested)) that a pure CFG cannot express.

chumsky's natural foils within this survey are [`nom`][nom] (the other major Rust combinator library, tuned for byte/streaming throughput) and the [Parsec lineage][parsec] (the functional ancestor of the model). The explicit chumsky-vs-`nom` contrast is drawn out [below](#chumsky-vs-nom).

---

## How it works

### The `Parser` trait and the zero-copy signature

Everything in chumsky is a value implementing the [`Parser`][parser-trait] trait. In the zero-copy API its signature carries four type parameters and an input lifetime ([`src/lib.rs`][lib]):

```rust
// chumsky::Parser (zero-copy line) — type parameters
pub trait Parser<'src, I, O, E = extra::Default>
where
    I: Input<'src>,            // the input stream (&str, &[u8], &[Token], …)
    E: ParserExtra<'src, I>,   // error type + parser State + Context
{
    // run the parser, producing BOTH an output and accumulated errors
    fn parse(&self, input: I) -> ParseResult<O, E::Error>
    where
        Self: Sized,
        E::State: Default,
        E::Context: Default;

    // "check-only" mode: validate without building the output (faster)
    fn check(&self, input: I) -> ParseResult<(), E::Error>
    where
        Self: Sized,
        O: 'src;
    // … plus the combinator methods below
}
```

| Type parameter   | Role                                                                                                   |
| ---------------- | ------------------------------------------------------------------------------------------------------ |
| `'src`           | Lifetime of the borrowed input — lets `O` hold references/slices into the input (zero-copy)            |
| `I: Input<'src>` | The input stream: `&str`, `&[u8]`, `&[T]` token slices, or a nested/streamed source                    |
| `O`              | The output the parser produces (an AST node, a token, a `Vec`, …)                                      |
| `E: ParserExtra` | A bundle of the **error** type, a mutable **`State`** (for arenas/interners), and a **`Context`** type |

The crucial return type is [`ParseResult<O, E::Error>`][parse-result]. Unlike a `Result<O, E>`, it carries an output **and** a list of errors at the same time — the type-level shape of "a partial AST plus a list of problems". This is what makes recovery a first-class outcome rather than an exceptional one.

`extra::Default` is the zero-config error/state bundle; a real language frontend swaps in a `Rich<'src, char>` error type (chumsky's batteries-included error that records spans, found/expected tokens, and labels) via `extra::Err<Rich<…>>`.

### Building parsers: the combinator surface

A parser is assembled from **primitives** (leaf parsers) wrapped in **combinator methods** (which take a parser and return a bigger one). The canonical leaf is [`just`][prim-just] — match a specific token/string — and the canonical combinators are methods on the `Parser` trait. The README's complete Brainfuck example shows the core surface in one screen ([`README.md`][readme]):

```rust
use chumsky::prelude::*;

#[derive(Clone)]
enum Instr {
    Left, Right,
    Incr, Decr,
    Read, Write,
    Loop(Vec<Self>),
}

fn brainfuck<'a>() -> impl Parser<'a, &'a str, Vec<Instr>> {
    recursive(|bf| choice((
        just('<').to(Instr::Left),
        just('>').to(Instr::Right),
        just('+').to(Instr::Incr),
        just('-').to(Instr::Decr),
        just(',').to(Instr::Read),
        just('.').to(Instr::Write),
        bf.delimited_by(just('['), just(']')).map(Instr::Loop),
    ))
        .repeated()
        .collect())
}

brainfuck().parse("--[>--->->->++>-<<<<<-------]>--.>---------.>--..+++.");
```

The combinators it touches generalise to every grammar:

| Combinator / primitive                                    | Meaning                                                                                    |
| --------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| [`just(x)`][prim-just]                                    | Match exactly token/string `x`                                                             |
| `any()`, `filter(pred)`                                   | Match any token / a token satisfying a predicate                                           |
| [`choice((a, b, …))`][prim-choice] / `a.or(b)`            | **Ordered choice**: try each in turn, take the first that succeeds                         |
| `a.then(b)` / `ignore_then` / `then_ignore`               | Sequence two parsers; keep both (tuple), or only the second / only the first               |
| `a.repeated()`                                            | Zero-or-more; an [`IterParser`][iterparser] you `.collect()` into a `Vec` (or fold)        |
| `a.separated_by(sep)`                                     | Repetition with a separator (commas, semicolons)                                           |
| `a.delimited_by(l, r)`                                    | Parse `a` between an opening and closing delimiter                                         |
| `a.or_not()`                                              | Optional — yields `Option<O>`                                                              |
| `a.map(f)` / `a.to(v)`                                    | Transform the output / replace it with a constant                                          |
| `a.foldl(b, f)`                                           | **Left-fold** a parser's repeated outputs — the idiom for left-associative operator chains |
| `a.labelled(name)`                                        | Attach a human name used in "expected …" error messages                                    |
| [`recursive`][prim-recursive] with a closure argument `p` | Tie a recursive knot so a grammar can refer to itself                                      |

`foldl` is worth singling out: a naive left-recursive rule (`expr := expr "+" term`) would loop forever in a recursive-descent parser, so chumsky expresses left association as `term.foldl(op.then(term).repeated(), …)` — parse one `term`, then fold each following `op term` into an accumulator. (For deep operator-precedence grammars chumsky also offers [Pratt parsing](#built-in-pratt-expression-parsing), which is more ergonomic still.)

> [!NOTE]
> Because a chumsky parser is built from generic methods over the `Input`/`Output` types, the resulting closure tree is monomorphised and inlined by `rustc`. The README credits an _"Internal optimiser leverages the power of GATs to optimise your parser for you"_ — generic associated types let the trait carry the borrowed-output lifetime through the whole combinator chain, which is what made the zero-copy rewrite possible.

### Error recovery: `recover_with` and the recovery strategies

The signature feature is [`recover_with`][parser-trait], a `Parser` method that wraps a parser with a **recovery `Strategy`** invoked only when the wrapped parser fails ([`src/lib.rs`][lib]):

```rust
// chumsky::Parser::recover_with
fn recover_with<S: Strategy<'src, I, O, E>>(self, strategy: S) -> RecoverWith<Self, S>;
```

When the inner parser fails, the strategy gets a chance to consume some input, synthesise a placeholder output (an `Expr::Error` node, say), and let the parse **continue** past the malformed region — so the error is recorded into `ParseResult` rather than aborting the parse. chumsky ships three built-in strategies, all in [`src/recovery.rs`][recovery]:

| Strategy                                                   | What it does                                                                                                                  |
| ---------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| [`via_parser(p)`][rec-via]                                 | Recover by running an arbitrary parser `p`; whatever `p` matches becomes the recovered region. The general-purpose primitive. |
| [`nested_delimiters(open, close, others, fb)`][rec-nested] | Skip a balanced bracketed region, respecting nesting, and substitute a fallback output                                        |
| [`skip_then_retry_until(skip, until)`][rec-skip]           | Skip tokens (one strategy) until a resync token (`until`) is seen, then retry the parser                                      |
| `skip_until(skip, until, fallback)`                        | Skip input until a resync token, then emit a fallback. The blunt last resort.                                                 |

`nested_delimiters` is the workhorse for language frontends — if an expression inside `(…)`/`[…]`/`{…}` is broken, it lets the parser swallow the whole balanced group and keep going on the tokens _after_ the closing bracket. Its verbatim doc comment ([`src/recovery.rs`][recovery]):

> _"A recovery parser that searches for a start and end delimiter, respecting nesting. … It is possible to specify additional delimiter pairs that are valid in the pattern's context for better errors. For example, you might want to also specify `[('[', ']'), ('{', '}')]` when recovering a parenthesized expression as this can aid in detecting delimiter mismatches. A function that generates a fallback output on recovery is also required."_

The blunter `skip_until` carries an explicit health warning in its own doc comment, codifying the recovery-quality trade-off ([`src/recovery.rs`][recovery]):

> _"A recovery parser that skips input until one of several inputs is found. This strategy is very 'stupid' and can result in very poor error generation in some languages. Place this strategy after others as a last resort, and be careful about over-using it."_

The recommended discipline is to **stack strategies specific-to-general** and to place recovery **high in the parser stack** so the real grammar gets every chance to parse before a fallback fires. From the [`recover_with`][lib] doc-comment:

> _"There is no silver bullet for error recovery, so this function allows you to specify one of several different strategies at the location of your choice. Prefer an error recovery strategy that more precisely mirrors valid syntax where possible to make error recovery more reliable."_

In practice a recovering expression parser reads:

```rust
// recover a broken parenthesised expression, then keep parsing
expr.recover_with(via_parser(nested_delimiters(
    '(', ')',
    [('[', ']'), ('{', '}')],   // sibling pairs, for mismatch detection
    |span| Expr::Error,         // fallback AST node for the bad region
)))
```

Because the recovered region becomes an `Expr::Error` node inside an otherwise-real AST, downstream stages keep working: the LSP can still offer completions in the _valid_ parts of a file with a syntax error in one function.

### Built-in Pratt expression parsing

Operator-precedence grammars are the classic pain point for recursive-descent parsers. chumsky bakes in a [Pratt parser][theory-pratt] via the [`pratt`][pratt-mod] module, whose doc opens _"Utilities for parsing expressions using Pratt parsing."_ ([`src/pratt.rs`][pratt-mod]). Operators are declared with `prefix`, `infix`, and `postfix` constructors, each carrying a **binding power** and (for infix) an associativity — `left(n)`, `right(n)`, or `none(n)`, higher `n` binding tighter ([`pratt` docs][pratt-mod]):

```rust
// chumsky::pratt — precedence-correct expression parsing in one combinator
let expr = atom.pratt((
    postfix(4, op('!'), |lhs, _, _| Expr::Factorial(Box::new(lhs))),
    infix(right(3), op('^'), |l, _, r, _| Expr::Pow(Box::new(l), Box::new(r))),
    prefix(2, op('-'), |_, rhs, _| Expr::Neg(Box::new(rhs))),
    infix(left(1), op('+'), |l, _, r, _| Expr::Add(Box::new(l), Box::new(r))),
));
```

This replaces the multi-level `foldl` precedence ladder a combinator parser would otherwise spell out by hand, parsing `-2 + 3 ^ 4!` with the conventional precedence (factorial > exponent > negation > addition) in a single declaration.

### Context-sensitive parsing: stateful and nested

Pure PEGs are not simply "context-free": [PEGs and CFGs are best treated as incomparable](./theory/peg-packrat.md), with deterministic CFLs as common ground and syntactic predicates pushing PEGs beyond CFGs in other directions. Some real syntaxes need still more state. chumsky's rewrite added dedicated combinators for those context-sensitive cases. The `0.10.0` changelog records both the context-sensitive support and the state mechanism ([`CHANGELOG.md`][changelog]):

> _"Support for parsing context-sensitive grammars such as Python-style indentation, Rust-style raw strings, and much more"_ … _"Support for manipulating shared state during parsing, elegantly allowing support for arena allocators, cstrees, interners, and much more"_

Two mechanisms underpin this:

- **`Context`** in the `ParserExtra` bundle lets an earlier parse result parameterise a later parser — e.g. read the `#` count of a Rust raw-string opener, then require exactly that many `#` to close it.
- **`State`** (the mutable `E::State`) threads a `&mut` value (an interner, an arena, an indentation stack) through the parse, accessed via `parse_with_state`.

chumsky also supports **nested inputs**: a parser can run over a `&[Token]` slice where some tokens are themselves _trees_ of tokens (Rust-style token trees), parsing the outer stream and recursing into bracketed groups without a separate flattening pass. The README lists _"Nested inputs such as token trees are fully supported both as inputs and outputs"_ ([`README.md`][readme]).

### Diagnostics: the `ariadne` sister crate

chumsky deliberately stops at producing `Rich` error values; **rendering** them as beautiful terminal diagnostics is the job of [`ariadne`][ariadne], the same author's companion crate, whose README opens _"A fancy compiler diagnostics crate."_ ([`ariadne` README][ariadne-readme]). The two are designed to complement each other without a hard dependency — ariadne is _"a sister project"_ to chumsky, inspired by [`codespan`][codespan] and modelled on `rustc`'s output. Given a `Rich` error's span and labels, ariadne renders multi-line, multi-file reports with colour-coded label arcs, overlap-avoiding layout heuristics, and Unicode/tab-aware column handling. The standard language-frontend pipeline is therefore: **chumsky** parses (recovering, accumulating `Rich` errors) → map each error to an `ariadne::Report` → ariadne prints it. This pairing is what gives a hobby language `rustc`-quality diagnostics for a few hours' work.

---

## Algorithm & grammar class

chumsky is a **recursive-descent** parser with **PEG** semantics: choice is **ordered** (`choice`/`or` take the first alternative that matches), so a chumsky grammar is unambiguous by construction — there are no parse forests and no GLR-style ambiguity to resolve, in contrast to the general parsers ([Earley/GLR][theory-general]). The README states the project's broad practical claim directly:

> _"Chumsky's parsers are recursive descent parsers and are capable of parsing parsing expression grammars (PEGs), which includes all known context-free languages. However, chumsky doesn't stop there: it also supports context-sensitive grammars via a set of dedicated combinators."_

Read that as an upstream capability claim, not as a settled formal theorem that PEGs strictly contain CFGs. This survey's [PEG theory deep-dive][theory-peg] follows Ford's more careful position: PEGs express all deterministic LR-class CFLs, can express some non-CFLs such as `aⁿbⁿcⁿ`, and are believed but not proven to be incomparable with CFGs overall. Two refinements push chumsky past textbook recursive descent in practice. First, **left recursion** — normally fatal to recursive descent — has **opt-in** support via memoization (the README: _"Left recursion and memoization have opt-in support"_), so a directly left-recursive rule can be written without the `foldl` rewrite. Second, the **context-sensitive** combinators ([above](#context-sensitive-parsing-stateful-and-nested)) handle indentation-sensitive and delimiter-counting syntaxes that a plain CFG cannot express. Ambiguity, the central concern of [bottom-up][theory-bottom-up] and [general][theory-general] parsing, simply does not arise here — ordered choice resolves every overlap by source order, the same determinism the [PEG/packrat theory][theory-peg] guarantees.

## Interface & composition model

chumsky is an **internal DSL**: the grammar is Rust code, composed from `Parser`-trait methods, with no external grammar file and no code-generation step (the [generator][antlr] camp's model). This buys the full power of Rust inside the grammar — closures in `map`, ordinary functions returning `impl Parser`, `recursive` for self-reference — and ordinary `cargo` tooling, at the cost (shared with all combinator libraries) that the grammar is opaque to static analysis: there is no separate artefact to lint for ambiguity or to generate a railroad diagram from a grammar file (though chumsky can emit railroad diagrams from the parser itself, per its feature list).

The **AST is built inline**: each combinator's `map`/`to`/`foldl`/Pratt fold constructs output nodes as it goes, and zero-copy means those nodes can _borrow_ slices of the input (identifiers, string literals) instead of allocating owned `String`s. Host-language integration is total — a chumsky parser is just a value of an `impl Parser<'src, I, O, E>` type, returnable from a function, storable, and (with the caching feature) build-once-reuse-many.

## Performance

chumsky's performance story is the **zero-copy rewrite**. The pre-`0.10` `0.9.x` line allocated owned outputs; the rewrite (incubated across the `1.0.0-alpha.x` line, shipped to stable in [`0.10.0`][rel010]) reworked the entire `Parser` trait around a borrowed input lifetime so outputs hold references into the input. The changelog's verdict is blunt — _"Performance has **radically** improved"_ ([`CHANGELOG.md`][changelog]) — and the README frames the target as parity with the throughput-focused libraries: chumsky has _"performance comparable to a hand-written parser"_ and stays competitive with [`nom`][nom] ([`README.md`][readme]). The enabling mechanisms:

- **Zero-copy outputs** — _"Zero-copy parsing minimises allocation by having outputs hold references/slices of the input"_ ([`README.md`][readme]) — eliminate the per-token `String` allocations that dominated the old line.
- **GAT-based internal optimiser** — the trait machinery monomorphises and inlines the combinator tree, so a chumsky parser compiles down to roughly the nested-`match` code a hand-written recursive-descent parser would be.
- **`check()` mode** — a second evaluation path that validates input _without_ constructing the output, for when you only need yes/no (the README: _"Check-only mode for fast verification of inputs"_). In the JSON example this is measurably faster than the full parse.
- **Opt-in memoization** — packrat-style caching is available where a grammar needs it (left recursion, heavy backtracking), but is _not_ paid by default, unlike a classic [packrat parser][theory-peg] that memoizes unconditionally.

Complexity is the usual recursive-descent profile: **linear** time on grammars without pathological backtracking, but PEG ordered choice can backtrack, so a poorly-factored grammar can degrade — memoization is the escape hatch. There is no SIMD/data-parallel path; that niche belongs to [`simdjson`][simdjson]. chumsky's `0.x` inputs are slice-based (not streaming/incremental like [`attoparsec`][parsec]'s `Partial`), so the whole input is in memory.

> [!IMPORTANT]
> chumsky's performance posture is "fast _enough_ to not need a separate lexer-generator, while keeping rich errors", not "fastest possible". For raw byte-shovelling throughput on machine formats, [`nom`][nom] (and certainly [`simdjson`][simdjson]) still win; chumsky's bet is that AST-building human-language frontends value error quality far more than the last increment of throughput — and that the rewrite closed enough of the gap to make that trade painless.

## Error handling & recovery

This is chumsky's reason to exist, and the dimension where it leads the field. Three layers:

1. **Rich errors by default.** The built-in `Rich` error type records the span, the token found, the set of tokens expected, and any `labelled` grammar-production names — enough to render a "found `}`, expected expression" message without hand-rolling an error type.
2. **Recovery as a first-class outcome.** [`recover_with`](#error-recovery-recover_with-and-the-recovery-strategies) plus the [`via_parser`][rec-via] / [`nested_delimiters`][rec-nested] / [`skip_then_retry_until`][rec-skip] strategies let the parser produce a **partial AST and a list of errors** in one run — the `ParseResult<O, E::Error>` return type encodes exactly that. This is what no other mainstream Rust combinator library does declaratively.
3. **IDE-readiness.** Because a syntax error in one function leaves the rest of the file's AST intact (recovery substitutes an `Error` node and continues), chumsky is well-suited to **LSP servers** and incremental compiler frontends, which must keep functioning on perpetually-incomplete, perpetually-invalid buffers. The author's own [Tao][tao] language uses chumsky for both lexer and parser specifically to surface many lexer, parser, and type errors in a single run.

What chumsky does **not** do is _incremental reparsing_ — re-parsing only the edited subtree of a previous parse, the way [tree-sitter][tree-sitter] does. A chumsky parse is whole-input each time; its IDE story is error-resilience and partial ASTs, not sub-linear edit reparsing. For an editor that needs both, the two are complementary, not competing.

## Ecosystem & maturity

chumsky is a **widely-adopted, single-maintainer-led** project (Joshua Barretto / [zesterer], with contributors) — among the two best-known Rust parser-combinator libraries alongside [`nom`][nom], and the default recommendation for **programming-language and DSL frontends** in Rust where errors matter. Its flagship production user is the author's own statically-typed functional language **[Tao][tao]**, used as the "dog food" project that drives the library's error-reporting work. It pairs with the sibling [`ariadne`][ariadne] diagnostics crate (also widely used independently). The maturity caveat is API churn around the post-`0.10` zero-copy redesign: the `0.13.0` published line is current, but the rewrite changed the trait shape substantially from `0.9.x` and the road to a final `1.0` remains visible in the old alpha tag and branch history. The project recently moved its primary home to [Codeberg][codeberg], with the GitHub repository archived as a mirror. Tooling beyond the core is light: railroad-diagram generation and parser debugging utilities are built in; there is no separate grammar-workbench or generator IDE (there is nothing to generate _from_).

---

## Strengths

- **Best-in-class declarative error recovery.** `recover_with` + `nested_delimiters` produce a partial AST _and_ a list of errors in one run, with (per the author) ~3 lines of recovery code for a JSON parser — no other mainstream Rust combinator library offers this.
- **Rich diagnostics for free.** The default `Rich` error plus the [`ariadne`][ariadne] sister crate give a hobby language `rustc`-grade terminal errors with spans, labels, and colour.
- **Genuinely generic.** One combinator set runs over `&str`, `&[u8]`, or `&[Token]` slices — scannerless or two-stage, your choice — and over your own span/error/output types.
- **Zero-copy outputs.** Borrowed slices in the AST cut allocation; the rewrite brought throughput into the same league as [`nom`][nom] for JSON-like inputs.
- **Built-in Pratt parsing** makes operator-precedence expression grammars a one-combinator declaration instead of a hand-coded precedence ladder.
- **Beyond pure PEG:** opt-in left recursion + memoization, and dedicated combinators for context-sensitive syntaxes (indentation, raw strings, token trees) and stateful parsing (arenas, interners).
- **`no_std`-capable**, so it runs in embedded environments.
- **IDE/LSP-friendly:** error-resilience and partial ASTs keep a frontend working on invalid, in-progress buffers.

## Weaknesses

- **API instability.** The recommended API is the post-`0.10` zero-copy line, but `1.0` is not yet finalised and the rewrite changed the trait shape substantially from `0.9.x`.
- **Compile-time and type complexity.** Deeply nested combinator types and the GAT-based machinery can produce intimidating type errors and non-trivial `rustc` build times — a known cost of the heavily-generic combinator approach.
- **No incremental reparsing.** Every parse is whole-input; unlike [tree-sitter][tree-sitter] it does not re-parse only the edited subtree, so for very large always-changing buffers it leans on full re-parse speed rather than edit-locality.
- **Not the throughput champion.** For machine/binary formats and maximum bytes/second, [`nom`][nom] and [`simdjson`][simdjson] remain faster; chumsky trades the last increment of speed for error quality.
- **Slice-based, not streaming.** The whole input must be in memory; there is no `attoparsec`-style incremental/`Partial` input.
- **Single-maintainer bus factor**, and a recent home move to Codeberg that downstreams must track.

## Key design decisions and trade-offs

| Decision                                                                                  | Rationale                                                                                          | Trade-off                                                                                                     |
| ----------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| Make **error recovery a first-class outcome** (`ParseResult` carries output _and_ errors) | "Error reporting … **is** the happy path"; language frontends/LSPs need partial ASTs + many errors | More machinery behind the API; recovery placement is a real grammar-design concern                            |
| **Combinator (internal DSL)**, no generator step                                          | Full Rust inside the grammar; `cargo`-native; rapid syntax iteration                               | Grammar opaque to static analysis; no external grammar artefact to lint for ambiguity                         |
| **PEG ordered choice**, unambiguous by construction                                       | Deterministic, no parse forests, predictable; simple mental model                                  | Source order silently resolves overlaps; pathological grammars can backtrack (memoization needed)             |
| **Generic over input/token/output/span/error**                                            | One library for scannerless `&str`, byte slices, and pre-lexed token streams                       | Heavy generics → complex types and longer compile times                                                       |
| **Zero-copy rewrite** (input lifetime `'src`, GAT optimiser)                              | Outputs borrow input → far less allocation; throughput competitive with `nom`                      | A breaking redesign of the trait; the long-lived `1.0.0-alpha` churn it caused                                |
| **Recovery strategies as opt-in, stacked specific→general**                               | Real grammar gets every chance before a fallback fires; quality stays high                         | `skip_until`-style fallbacks are "stupid" and degrade errors if over-used                                     |
| **Diagnostics split into the `ariadne` sister crate**                                     | Separation of concerns — parse vs render; ariadne is reusable independently                        | Two crates to wire together; an extra mapping step from `Rich` error → `ariadne::Report`                      |
| **Opt-in** left recursion / memoization (not packrat-by-default)                          | Don't pay packrat's memory cost unless the grammar needs it                                        | Left recursion / heavy backtracking need explicit opt-in; not automatically linear like a full packrat parser |
| **Slice input, no streaming/incremental**                                                 | Simpler, faster random access; fits whole-file compiler frontends                                  | Whole input in memory; no `Partial`-style streaming, no tree-sitter-style edit reparsing                      |

---

## Sources

- [`zesterer/chumsky` — repository][repo] · [primary home on Codeberg][codeberg] · [`README.md` (features, Brainfuck example, license)][readme]
- [chumsky on docs.rs][docs] · [crates.io][crate] · [lib.rs][librs]
- [`chumsky::Parser` trait — `parse`/`check`/`recover_with`/combinators][parser-trait] · [`src/lib.rs`][lib]
- [`chumsky::recovery` module — `via_parser`, `nested_delimiters`, `skip_then_retry_until`, `skip_until`][rec-mod] · [`src/recovery.rs`][recovery]
- [`chumsky::guide::_03_error_and_recovery` — report/resynchronise/resume][guide-recovery]
- [`chumsky::pratt` module — `infix`/`prefix`/`postfix`, `left`/`right`/`none`][pratt-mod]
- [`CHANGELOG.md` — `0.10.0` rewrite: zero-copy, context-sensitive, `IterParser`, pratt, state][changelog] · [`0.10.0` release notes][rel010]
- [Joshua Barretto, _Why can't error-tolerant parsers also be easy to write?_ — the founding error-recovery essay][blog]
- [`zesterer/ariadne` — sister diagnostics crate][ariadne] · [`ariadne` README][ariadne-readme]
- [Tao — statically-typed functional language; chumsky's "dog food" frontend][tao]
- Related deep-dives: [`nom` (Rust)][nom] · [Parsec/Megaparsec (Haskell)][parsec] · [tree-sitter][tree-sitter] · [`simdjson`][simdjson] · [Top-down & combinator parsing][theory-top-down] · [PEG & packrat][theory-peg] · [Pratt / precedence][theory-pratt] · [General parsing (GLR/Earley)][theory-general] · [the parsing umbrella][index] · [the comparison capstone][comparison]

<!-- References -->

[index]: ./index.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[theory-top-down]: ./theory/top-down.md
[theory-bottom-up]: ./theory/bottom-up.md
[theory-peg]: ./theory/peg-packrat.md
[theory-pratt]: ./theory/pratt-precedence.md
[theory-general]: ./theory/general-parsing.md
[nom]: ./rust-nom.md
[parsec]: ./haskell-parsec.md
[tree-sitter]: ./tree-sitter.md
[simdjson]: ./simdjson.md
[antlr]: ./antlr.md
[bison]: ./bison-yacc.md
[menhir]: ./menhir.md
[repo]: https://github.com/zesterer/chumsky
[codeberg]: https://codeberg.org/zesterer/chumsky
[readme]: https://raw.githubusercontent.com/zesterer/chumsky/main/README.md
[docs]: https://docs.rs/chumsky/latest/chumsky/
[crate]: https://crates.io/crates/chumsky
[librs]: https://lib.rs/crates/chumsky
[parser-trait]: https://docs.rs/chumsky/latest/chumsky/trait.Parser.html
[parse-result]: https://docs.rs/chumsky/latest/chumsky/struct.ParseResult.html
[lib]: https://github.com/zesterer/chumsky/blob/main/src/lib.rs
[recovery]: https://raw.githubusercontent.com/zesterer/chumsky/main/src/recovery.rs
[rec-mod]: https://docs.rs/chumsky/latest/chumsky/recovery/index.html
[rec-via]: https://docs.rs/chumsky/latest/chumsky/recovery/fn.via_parser.html
[rec-nested]: https://docs.rs/chumsky/latest/chumsky/recovery/fn.nested_delimiters.html
[rec-skip]: https://docs.rs/chumsky/latest/chumsky/recovery/fn.skip_then_retry_until.html
[guide-recovery]: https://docs.rs/chumsky/latest/chumsky/guide/_03_error_and_recovery/
[pratt-mod]: https://docs.rs/chumsky/latest/chumsky/pratt/index.html
[iterparser]: https://docs.rs/chumsky/latest/chumsky/trait.IterParser.html
[prim-just]: https://docs.rs/chumsky/latest/chumsky/primitive/fn.just.html
[prim-choice]: https://docs.rs/chumsky/latest/chumsky/primitive/fn.choice.html
[prim-recursive]: https://docs.rs/chumsky/latest/chumsky/recursive/fn.recursive.html
[changelog]: https://github.com/zesterer/chumsky/blob/main/CHANGELOG.md
[rel010]: https://github.com/zesterer/chumsky/releases/tag/0.10
[blog]: https://www.jsbarretto.com/blog/parser-combinators-and-error-recovery/
[ariadne]: https://github.com/zesterer/ariadne
[ariadne-readme]: https://raw.githubusercontent.com/zesterer/ariadne/main/README.md
[codespan]: https://github.com/brendanzab/codespan
[tao]: https://github.com/zesterer/tao
[zesterer]: https://github.com/zesterer
