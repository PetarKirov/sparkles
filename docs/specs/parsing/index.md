# `sparkles:parsing` — Design Proposal

_Audience: contributors and coding agents evaluating whether/how to build a Sparkles
parsing toolkit. This document is a **proposal**, not a normative spec — it states what to
build and why, grounded in the [parsing survey](../../research/parsing/index.md). For the
milestoned delivery plan see [PLAN.md](./PLAN.md); for the cross-ecosystem evidence base see
the [survey](../../research/parsing/index.md), its [capstone][comparison], and the
[D-ecosystem landscape][d-landscape]._

## 1. Why

Sparkles already hand-parses several small languages — [version schemes][v-parsing], CLI
arguments, terminal VT sequences — each `@nogc`/`@safe`, each hand-rolled from scratch over
the [`sparkles.base.text`][base-text] readers. The [parsing survey](../../research/parsing/index.md)
was written to answer whether a **reusable** parsing layer would serve those cases better,
and what shape it should take. Its two load-bearing conclusions:

1. **The cross-ecosystem [design center][comparison]** for an allocation-conscious parser is
   **zero-copy, scannerless recursive descent** ([nom]/[winnow]) with **zero-allocation
   validators** ([flatparse]'s proof), a [Pratt][pratt] expression loop, and `Expected!(T, E)`
   results — _not_ SIMD ([yyjson] shows careful scalar wins), _not_ incremental (that earns
   its keep only under an editor re-parse contract), _not_ a table generator.
2. **The [D landscape][d-landscape] has a gap exactly there.** D has a compile-time PEG
   generator ([Pegged] — but GC-bound), a hand-written-RD tradition (dmd/libdparse/sdc — but
   D-specific), and a world-class `@nogc`/SIMD _serialization_ stack (mir-ion/asdf) — but **no
   maintained, `@nogc`, zero-copy ordered-choice combinator** and **no recovering parser**.

`sparkles:parsing` fills that gap: a small combinator layer over the existing `base.text`
readers, in the idiom the repo already uses.

## 2. What — the design center

Each decision below cites the prior-art page it reifies and the in-tree code it builds on.
None of it contradicts the [comparison's Sparkles-fit sketch][comparison] — it operationalises it.

- **Zero-copy, scannerless recursive descent over `const(char)[]`.** No separate lexer, no
  generated tables; the input slice _is_ the cursor. This is what [nom]/[winnow] do and what
  [`parseSemVerShaped`][v-parsing] already does in-tree. Parsers are values of the form
  `ParseResult!T function(ref scope const(char)[])` (advance-on-success), composing directly
  with the [`base.text.readers`][base-text] primitives (`readInteger`, `skipSpaces`,
  `tryConsume`, `readUntil`).
- **Ordered-choice combinators (a PEG-shaped internal DSL).** `seq`, `choice`/`alt` (first
  match wins — [PEG][peg] ordered choice, unambiguous by construction), `many`/`many1`,
  `opt`, `sepBy`, `map`, plus syntactic predicates (`peek`/`notFollowedBy`). Combinators are
  ordinary D values ([embedded-combinator interface][comparison-interface]); attributes
  **infer** so `@nogc`/`@safe`/`pure`/`nothrow` propagate from the caller's leaf parsers.
- **Zero-allocation by construction.** A parser returning `void`/a slice must run with **no
  heap allocation** — the property [flatparse] proves a combinator API can have and the one
  most relevant to Sparkles (validating a version string, a CLI token). `SmallBuffer`
  replaces `appender` where accumulation is unavoidable; **no packrat memoization by default**
  ([the space cost][peg] is the wrong default; reserve it for a measured hot spot).
- **A [Pratt][pratt] expression engine.** A table-free, `O(n)` binding-power loop for any
  operator/constraint grammar Sparkles needs (version constraints `>=1.2 <2.0 || ^3`, filter
  expressions). Drops into the recursive-descent shell exactly as the survey's
  [pratt-precedence][pratt] page describes.
- **`Expected!(T, ParseError, NoGcHook)` results, failure-vs-error split.** Reuse the
  existing [`errors.d`][base-text] vocabulary verbatim. The [flatparse]/[nom] **failure**
  (control-flow, backtrackable) vs **error** (unrecoverable, `cut`) distinction maps onto
  `Expected`: an ordinary parse miss is a recoverable `err`; a committed-path failure short-
  circuits. `parseOk`/`parseErr` are the constructors.
- **Error posture chosen per use, up front.** Fail-fast by default (validating a version
  string); opt-in [chumsky]-style **recovery** (a partial value + an error list) for the
  user-facing cases (config, a REPL) — an architecture decision made at parser-construction
  time, never retrofitted ([comparison §4][comparison-recovery]).

## 3. What it builds on (reuse, don't reinvent)

- [`sparkles.base.text.readers`][base-text] — the zero-copy cursor primitives are the leaf
  parsers; combinators are the glue. `readers.d` is documented as "mechanism, not policy" —
  this toolkit _is_ the policy layer.
- [`sparkles.base.text.errors`][base-text] — `ParseError`/`ParseErrorCode`/`ParseExpected`/
  `parseOk`/`parseErr`/`NoGcHook` already exist and are the result vocabulary.
- [`sparkles.base.smallbuffer`](../../libs/base/index.md) — the `@nogc` output range.
- The [`expected`](../../guidelines/idioms/expected/index.md) idiom — `Expected!(T, E)` chaining
  (`map`/`andThen`/`orElse`) is how parsers compose without exceptions.
- [`parseSemVerShaped`][v-parsing] — the existing scannerless-RD exemplar; the version schemes
  are the first real client and the migration test.

## 4. Non-goals (and why)

- **No SIMD by default.** [yyjson] reaches GB/s with careful scalar ANSI C and _no_ SIMD;
  [simdjson]-class vectorization is a measured optimization for large, hot, structured inputs
  (megabytes of JSON), which Sparkles does not parse. If such a need appears, the mir stack
  ([mir-ion]/[asdf]) already exists — depend on it, don't rebuild it.
- **No incremental / query machinery.** [tree-sitter]/[rust-analyzer]/[Roslyn]/[`rustc`][rustc]/[Lezer]
  earn their persistent-tree + dependency-graph overhead only under an **editor** contract
  (re-parse on every keystroke). Sparkles' inputs are parse-once. The one borrowable idea is a
  [red-green][incremental] lossless view — and only if a future use wants a re-serializable
  CST (a formatter); a plain AST is lighter otherwise. See [the incremental theory page][incremental].
- **No CTFE grammar DSL (à la [Pegged]).** A string-mixin grammar generator is powerful but
  GC-shaped and compile-time-heavy; the survey's evidence is that production parsers are
  hand-written RD ([top-down], and D's own dmd/libdparse/sdc). Reach for a grammar DSL only on
  a measured need for a large external grammar.
- **Not a replacement for `std.getopt`/mir/Pegged.** This is a small `@nogc` toolkit for
  Sparkles' own small languages, not a general parsing framework.

## 5. Prior-art map

Where each design decision comes from in the survey (the evidence, not re-derived here):

| Decision                                  | Prior art (survey page)                          | What to borrow                                               |
| ----------------------------------------- | ------------------------------------------------ | ------------------------------------------------------------ |
| Zero-copy scannerless RD over slices      | [nom] · [winnow]                                 | slice cursor, no allocator on the recognizer path            |
| Ordered-choice combinators (unambiguous)  | [PEG/packrat][peg] · [pest]                      | ordered choice `/`, predicates; skip packrat default         |
| Zero-allocation validators                | [flatparse]                                      | failure/error split; `()`-returning parsers allocate nothing |
| Pratt expression engine                   | [pratt-precedence][pratt]                        | binding-power loop for constraints                           |
| `Expected` results, fail-fast vs recover  | [flatparse] · [chumsky]                          | error posture as an up-front architecture choice             |
| Table-free hand-written lexer (if needed) | [Zig tokenizer][zig]                             | character-class state machine, zero-alloc                    |
| Stay batch (reject incremental)           | [incremental theory][incremental] · [comparison] | the editor-contract boundary                                 |
| Don't reach for SIMD                      | [yyjson] · [simdjson]                            | scalar-first; vectorize only measured hot paths              |

The milestones that build this — bottom-up, each reusing the `base.text` substrate — are in
[PLAN.md](./PLAN.md).

<!-- References -->

<!-- Survey pages -->

[survey]: ../../research/parsing/index.md
[comparison]: ../../research/parsing/comparison.md#where-a-sparkles-parser-would-fit
[comparison-interface]: ../../research/parsing/index.md#by-interface-model
[comparison-recovery]: ../../research/parsing/comparison.md
[d-landscape]: ../../research/parsing/d-landscape.md
[peg]: ../../research/parsing/theory/peg-packrat.md
[top-down]: ../../research/parsing/theory/top-down.md
[pratt]: ../../research/parsing/theory/pratt-precedence.md
[incremental]: ../../research/parsing/theory/incremental.md
[pest]: ../../research/parsing/pest.md
[nom]: ../../research/parsing/rust-nom.md
[winnow]: ../../research/parsing/rust-winnow.md
[flatparse]: ../../research/parsing/haskell-flatparse.md
[chumsky]: ../../research/parsing/rust-chumsky.md
[simdjson]: ../../research/parsing/simdjson.md
[yyjson]: ../../research/parsing/yyjson.md
[mir-ion]: ../../research/parsing/d-landscape.md#high-performance-json--serialization--the-mir-stack-asdf-jsoniopipe
[asdf]: ../../research/parsing/d-landscape.md#high-performance-json--serialization--the-mir-stack-asdf-jsoniopipe
[Pegged]: ../../research/parsing/d-landscape.md#compile-time-peg-generation--pegged
[zig]: ../../research/parsing/zig-tokenizer.md
[tree-sitter]: ../../research/parsing/tree-sitter.md
[rust-analyzer]: ../../research/parsing/rust-analyzer.md
[Roslyn]: ../../research/parsing/roslyn.md
[Lezer]: ../../research/parsing/lezer.md
[rustc]: ../../research/parsing/rustc-queries.md

<!-- In-tree Sparkles sources -->

[base-text]: https://github.com/PetarKirov/sparkles/blob/main/libs/base/src/sparkles/base/text/package.d
[v-parsing]: https://github.com/PetarKirov/sparkles/blob/main/libs/versions/src/sparkles/versions/schemes/semver.d
