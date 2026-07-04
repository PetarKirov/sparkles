# Comparison & Synthesis

The capstone of the [parsing survey][umbrella]: an at-a-glance matrix across the nine
flagship systems, a per-dimension head-to-head along the survey's
[five-dimension spine](#the-five-dimension-spine), the **consensus** the field has
converged on, the **architectural trade-offs** that remain genuinely open, and a light
note on **where a Sparkles parser would sit**. Terminology is defined in the
[concepts glossary][concepts]; the algorithm families are developed in the
[theory subtree][theory].

> [!NOTE]
> **Scope: wave 1 + three wave-2 clusters.** This synthesis covers the nine flagship
> systems, the theory spine, and the three wave-2 clusters now landed — **incremental /
> query-based** ([rust-analyzer], [Roslyn][roslyn], [Lezer][lezer], [`rustc`][rustc];
> see [`incremental`][incremental]), **SIMD / high-performance** ([simd-json], [sonic-rs],
> [yyjson], [RapidJSON][rapidjson], [Hyperscan][hyperscan], [Zig tokenizer][zig]), and
> **parser combinators** ([winnow], [flatparse], [combine], [Angstrom][angstrom],
> [FParsec][fparsec]). Only the **generators** cluster (LALRPOP, Lark/PLY, Peggy,
> Ragel/re2c) and a few JVM combinators remain. Conclusions below are stable for the
> families surveyed.

**Last reviewed:** July 3, 2026

---

## At-a-glance matrix

| System                     | Strategy                                        | Grammar reaches parser via  | Linear time?        | Error recovery        | Zero-copy       | Incremental    | Data-parallel  |
| -------------------------- | ----------------------------------------------- | --------------------------- | ------------------- | --------------------- | --------------- | -------------- | -------------- |
| [simdjson][simdjson]       | [SIMD two-stage][formal]                        | hand-tuned state machine    | ✅ (+SIMD)          | fail-fast (validate)  | ✅              | —              | ✅             |
| [simd-json]                | [SIMD two-stage][formal] (port)                 | hand-tuned (`&mut` in-situ) | ✅ (+SIMD)          | fail-fast (validate)  | ✅ (in-situ)    | —              | ✅             |
| [sonic-rs]                 | SIMD **on-demand**                              | lazy `get`-by-pointer       | ✅ (+SIMD)          | fail-fast (validate)  | ✅              | —              | ✅             |
| [yyjson]                   | **scalar** (no SIMD)                            | hand-tuned C reader         | ✅                  | fail-fast (err pos)   | ✅ (in-situ)    | —              | — (no SIMD)    |
| [RapidJSON][rapidjson]     | SAX + DOM, in-situ                              | hand-tuned C++              | ✅                  | fail-fast (offset)    | ✅ (in-situ)    | —              | ~ (whitespace) |
| [Hyperscan][hyperscan]     | [SIMD automata][formal] (regex)                 | compiled pattern DB         | ✅ (+SIMD)          | n/a — matcher⁴        | ✅ (in-place)   | — (streaming)  | ✅             |
| [Zig tokenizer][zig]       | hand-written **lexer**                          | hand-written                | ✅                  | invalid-token         | ✅ (ranges)     | —              | —              |
| [tree-sitter][tree-sitter] | [GLR][bottom-up], incremental                   | `grammar.js` generator      | ✅ det.; O(n³) amb. | **incremental/IDE**   | ✅ (CST)        | ✅ (subtree)   | —              |
| [rust-analyzer]            | [RD][top-down]→[red-green][incremental]+[salsa] | hand-written + query graph  | ✅                  | **incremental/IDE**   | ✅ (CST)        | ✅ (+queries)  | —              |
| [Roslyn][roslyn]           | [RD][top-down]→[red-green][incremental]         | hand-written parser         | ✅                  | **incremental/IDE**   | ✅ (CST)        | ✅ (subtree)   | —              |
| [Lezer][lezer]             | incremental [GLR][bottom-up]                    | `@lezer/generator`          | ✅ det.; O(n³) amb. | **incremental/IDE**   | ✅ (CST)        | ✅ (fragment)  | —              |
| [`rustc` queries][rustc]   | demand-driven [queries][incremental]            | queries over AST/HIR/MIR    | ✅                  | n/a (parser batch)³   | —               | ✅ (cross-run) | —              |
| [ANTLR][antlr]             | [ALL(\*)][top-down] top-down                    | `.g4` generator             | in practice         | recovering            | —               | —              | —              |
| [Bison][bison]             | [LALR(1)][bottom-up] bottom-up                  | `.y` generator              | ✅                  | panic-mode `error`    | —               | —              | —              |
| [Menhir][menhir]           | [LR(1)][bottom-up] bottom-up                    | `.mly` generator            | ✅                  | recovering API¹       | —               | API only¹      | —              |
| [pest][pest]               | [PEG][peg] generator                            | `.pest` generator           | ⚠️ no memo          | diagnostic            | ✅ (leaves)     | —              | —              |
| [Parsec][parsec]           | predictive [LL][top-down] combinator            | host-language values        | ~ on LL(1)          | diagnostic / recov.²  | ⚠️ attoparsec   | —              | —              |
| [nom][nom]                 | [PEG][peg]-like combinator                      | host-language values        | ⚠️ no memo          | fail-fast             | ✅              | —              | —              |
| [chumsky][chumsky]         | [PEG][peg] combinator                           | host-language values        | ⚠️ opt-in memo      | **recovering**        | ✅ (0.10+)      | —              | —              |
| [winnow]                   | [PEG][peg]-like combinator ([nom] fork)         | host-language values        | ⚠️ no memo          | fail-fast + `cut`     | ✅              | —              | —              |
| [flatparse]                | [PEG][peg]-like combinator                      | host-language values        | ⚠️ no memo          | fail-fast + errors    | ✅ (zero-alloc) | —              | —              |
| [combine]                  | [LL][top-down](1) + `attempt`                   | host-language values        | ~ on LL(1)          | diagnostic (commit)   | ✅ (`range`)    | — (streaming)  | —              |
| [Angstrom][angstrom]       | [PEG][peg]-like combinator                      | host-language values        | ⚠️ no memo          | backtrack + `commit`  | ✅ (bigstring)  | — (streaming)  | —              |
| [FParsec][fparsec]         | [LL][top-down] + backtrack combinator           | host-language values        | ~                   | **diagnostic** (best) | ⚠️ CharStream   | —              | —              |

<sub>¹ Menhir's _generator_ is batch; its incremental/inspection API is what IDE tools
(Merlin, ocaml-lsp) drive for live recovery and client-managed parsing. It is not a
built-in edit-local CST reuse engine like tree-sitter. ² attoparsec drops error
book-keeping for speed; Megaparsec adds typed errors, error bundles, and
`withRecovery`. ³ `rustc`'s incrementality is a **computation** engine (memoized
queries reused across whole compiles); its front-end lexer/parser is still batch, so the
recovery/zero-copy columns describe the query layer, not a live parse tree. ⁴ Hyperscan
is a multi-pattern regex **matcher**, not a parser — it reports matches via a callback and
builds no tree; the row describes its scanning engine.</sub>

Two orthogonal escapes from "parse the whole file, scalar, every time" now each fill a
cluster. **Data-parallel** is no longer simdjson-alone: [simd-json], [sonic-rs], and
[Hyperscan][hyperscan] all vectorize the byte scan ([RapidJSON][rapidjson] does so
narrowly, for whitespace) — while [yyjson] is the pointed **counter-example**, hitting
GB/s with careful _scalar_ C and **no SIMD at all**, proving vectorization is one road to
speed, not the only one. **Incrementality** is the other escape, and splits two ways:
reuse the **tree** (tree-sitter subtree reuse, Roslyn/rust-analyzer [red-green][incremental]
nodes, Lezer fragments) versus reuse the **computation** ([`rustc`][rustc]/[salsa] memoized
queries) — [rust-analyzer] does both at once. Menhir exposes a resumable API clients drive
for live parsing, but no edit-local tree reuse. The rest of the catalog is a scalar,
whole-input, single-pass parser distinguished
by _grammar class_ and _error posture_, not by raw mechanism.

---

## The five-dimension spine

Every deep-dive is written against the same five dimensions; here they are read across.

### 1. Algorithm & grammar class

Three lineages dominate, and the catalog shows the field has stopped treating them as
rivals:

- **Bottom-up LR** ([Bison][bison] LALR(1), [Menhir][menhir] LR(1)) accepts the largest
  _deterministic_ class with a tiny constant factor, at the cost of opaque
  shift/reduce conflicts. It is the compiler-back-end tradition.
- **Top-down LL** ([ANTLR][antlr]'s ALL(\*), and every combinator) is intuitive,
  debuggable, and — since ALL(\*) moved lookahead analysis to _parse time_ — now
  accepts essentially any non-left-recursive CFG without manual factoring. It is the
  tooling-and-frontend tradition.
- **PEG** ([pest][pest], [nom][nom], [chumsky][chumsky], and Parsec's `try`-gated
  ordered choice) replaces the CFG's nondeterministic choice with **ordered choice**,
  making grammars unambiguous _by construction_ and scannerless. It is the
  new-tooling default.

> [!IMPORTANT]
> **PEG ordered choice trades one problem for another.** An LR generator _reports_
> ambiguity as a conflict you must resolve; a PEG _silently_ resolves it by taking the
> first alternative, which can produce a valid-but-wrong parse with no diagnostic (the
> "longest-match vs first-match" surprise, [peg-packrat][peg]). Determinism-by-fiat is
> ergonomic but shifts the burden from the tool to the grammar author.

Generalized parsers ([tree-sitter][tree-sitter]'s GLR; Bison/Menhir GLR modes; Earley,
GLL, and [derivatives][derivatives] in [theory][general]) accept _every_ CFG and surface
ambiguity as a parse forest — the right tool for natural language, composed grammars,
and prototyping, bounded by the [cubic wall][formal]. [simdjson][simdjson] is the
outlier: a single fixed grammar (JSON) lets it skip grammar machinery entirely for a
hand-tuned two-stage SIMD pipeline.

### 2. Interface & composition model

| Model                     | Cost                                                                 | Benefit                                                                               | Systems                                                                                    |
| ------------------------- | -------------------------------------------------------------------- | ------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| Offline generator         | a build step, a separate grammar language, generated-code opacity    | static analysis (conflicts, unreachable rules), peak speed, action/grammar separation | [Bison][bison], [Menhir][menhir], [ANTLR][antlr], [pest][pest], [tree-sitter][tree-sitter] |
| Embedded combinators      | no whole-grammar static analysis; left recursion is a runtime hazard | grammars are first-class host values — composable, testable, typed, no build step     | [Parsec][parsec], [nom][nom], [chumsky][chumsky]                                           |
| Hand-written rec. descent | you write (and maintain) the parser                                  | total control, best errors, the production norm (GCC/Clang/rustc)                     | (the substrate the above reify)                                                            |
| Library state machine     | one grammar only, hand-tuned                                         | nothing between the bytes and the metal                                               | [simdjson][simdjson]                                                                       |

A clear sub-consensus: **separate the grammar from the semantic actions.** ANTLR's
action-free `.g4` + generated listener/visitor over a CST is the modern answer to
yacc's inline `$$ = $1 + $3` reductions; tree-sitter goes furthest, emitting a lossless
CST and leaving _all_ interpretation to queries and host code.

### 3. Performance

Asymptotic class is necessary but **not** sufficient — both [Bison][bison] and
[simdjson][simdjson] are O(n), yet simdjson is an order of magnitude faster on JSON
because of three constant-factor and architectural levers the rest of the catalog
mostly leaves on the table:

- **Constant factor / SIMD.** simdjson classifies 64-byte blocks branchlessly with
  `pclmulqdq` + `pshufb` and validates UTF-8 in parallel, hitting ~GB/s with runtime
  CPU dispatch. No other surveyed parser is data-parallel — a keystroke-driven parser
  has nothing to vectorize ([tree-sitter][tree-sitter]).
- **Incrementality.** [tree-sitter][tree-sitter] spends memory to reuse unchanged tree
  work across edits — fast where the _workload_ is "the same file, slightly changed,"
  which is the IDE workload. [Menhir][menhir]'s API exposes resumable checkpoints that
  clients can cache and resume, but the edit-reuse strategy lives in the client.
- **Zero-copy.** [nom][nom], [chumsky][chumsky] 0.10+, [pest][pest] leaves, [simdjson][simdjson],
  and tree-sitter's CST all hand back slices/views into the input rather than copying —
  the single most portable performance lever, and the one most relevant to a `@nogc`
  design.

> [!WARNING]
> **Packrat's space cost is real.** PEG's linear-time guarantee comes from memoizing
> every (rule, position) result — Ford measured hundreds of bytes of live heap _per
> input byte_ ([peg-packrat][peg]). That is why production PEG tools often **don't**
> memoize: [pest][pest] and [nom][nom] are non-memoizing recursive descent, trading the
> linear-time guarantee (super-linear on adversarial grammars) for bounded memory.
> [chumsky][chumsky] makes memoization opt-in. "PEG" does not imply "packrat."

### 4. Error handling & recovery

This is the dimension the field has moved on most, and it now cleanly stratifies:

1. **Fail-fast / validate** — stop at the first error ([simdjson][simdjson], [nom][nom],
   plain [Bison][bison] without `error` rules). Correct for data interchange and
   machine formats.
2. **Panic-mode** — skip to a synchronizing token and resume ([Bison][bison]'s `error`
   rules, classic LL/LR parsers). Useful for statement-level batch recovery, not enough
   for rich partial trees.
3. **Diagnostic** — precise positioned, expected-set messages, still one error
   ([pest][pest], base [Parsec][parsec]/Megaparsec). Bison 3.8's `-Wcounterexamples`
   belongs here for the _grammar author_: it synthesizes witness inputs for conflicts.
4. **Recovering** — produce a partial AST **and** a list of errors ([chumsky][chumsky],
   [ANTLR][antlr], Megaparsec's `withRecovery`, Menhir clients). Required to build a
   real language frontend.
5. **Incremental / IDE** — recover **and** re-parse only the edited region per keystroke
   ([tree-sitter][tree-sitter]). The bar for editor tooling.

The decisive insight: **recovery is an architecture, not a feature you bolt on.**
tree-sitter bakes it into a cost-minimizing GLR search (skip-char/skip-line/missing-tree
costs); chumsky designs its combinators around returning a partial result; Menhir
exposes the parser as a resumable state machine that IDE clients can drive. A fail-fast
parser cannot be retrofitted into an IDE-grade one without changing its core loop.

### 5. Ecosystem & maturity

| Tier                              | Systems                                                                                                                                                                                          |
| --------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Decades-deep, load-bearing**    | [Bison][bison]/yacc (50 yrs; Bash, PostgreSQL), [ANTLR][antlr] (since 1989; Hive, Trino, Spark SQL), [Parsec][parsec] (Cabal)                                                                    |
| **Modern standard for its niche** | [tree-sitter][tree-sitter] (Neovim/Helix/Zed/GitHub), [simdjson][simdjson] (Node.js, ClickHouse, Velox), [Menhir][menhir] (the OCaml toolchain, CompCert), [nom][nom] (576M downloads, Suricata) |
| **Ascendant / settling**          | [pest][pest] (stable 2.x), [chumsky][chumsky] (single-maintainer, 0.x + 1.0-alpha), winnow (now under Cargo via `toml_edit`)                                                                     |

Maturity does not track novelty: the oldest technology (LALR via yacc/Bison) and the
newest framing (GLR-incremental via tree-sitter) are _both_ production-load-bearing,
because they serve different masters — batch compilation versus interactive editing.

---

## The consensus standard

Across the catalog, the field broadly agrees on:

1. **Linear-time deterministic parsing for production; general parsing for problems that
   need it.** Restrict the grammar (LL/LR/PEG) to dodge the [cubic wall][formal]; reach
   for Earley/GLR/GLL only for ambiguity you genuinely have.
2. **Separate grammar from semantic action.** A grammar describes structure; a separate
   listener/visitor/query interprets the resulting tree.
3. **A lossless tree for tooling, an AST for compilation.** [tree-sitter][tree-sitter]'s
   CST and rust-analyzer-style red-green trees keep every byte for editors; compilers
   lower to an AST.
4. **Zero-copy by default.** Hand back slices into the input; copy only when you must.
5. **Recovery is the IDE differentiator.** The shift from "report the first error" to
   "return a partial tree + all errors + reparse on edit" is the defining modern move.
6. **Pratt for expressions.** Hand-written recursive descent + a [Pratt][pratt] binding-
   power loop is the dominant production architecture for the expression hot path; even
   combinator libraries ([chumsky][chumsky], [pest][pest]) expose it first-class.

---

## Architectural trade-offs (still genuinely open)

| Axis               | Option A                                    | Option B                                | Choose A when…                                            |
| ------------------ | ------------------------------------------- | --------------------------------------- | --------------------------------------------------------- |
| Grammar class      | Deterministic (LL/LR/PEG), O(n)             | General (Earley/GLR/GLL), O(n³)         | the grammar fits a deterministic class — almost always    |
| Ambiguity handling | Report as conflict (LR)                     | Resolve silently by order (PEG)         | you want the tool to catch grammar mistakes for you       |
| Interface          | Offline generator                           | Embedded combinators                    | you want whole-grammar static analysis & peak speed       |
| Lexing             | Separate lexer (Bison/Menhir/ANTLR)         | Scannerless (PEG/combinators/simdjson)  | the lexical grammar is regular and worth optimizing apart |
| Error posture      | Fail-fast / validate                        | Recovering / incremental                | you parse machine data, not human-edited source           |
| Speed lever        | Constant factor (SIMD)                      | Less work (incremental)                 | the input is large & static (vectorize) vs edited (reuse) |
| Memory             | Memoize for linear-time guarantee (packrat) | Don't memoize, accept super-linear tail | inputs are small or grammars are tame                     |

---

## Where a Sparkles parser would fit

A light tie-in (no concrete proposal yet). Sparkles already hand-parses several small
languages — [version schemes][v-parsing], [CLI arguments][cli-args], and terminal VT
sequences (`sparkles:ghostty`) — all in `@nogc`/`@safe`, allocation-conscious D. The
survey suggests the design center for an allocation-conscious D parsing toolkit:

- **Zero-copy, scannerless recursive descent** is the natural `@nogc` fit — it is what
  [nom][nom] and its fork [winnow] do in Rust (slices, no allocator on the recognizer
  path) and matches the repo's existing `@nogc` text readers in
  [`sparkles.base.text`][base-text]. A PEG-style ordered-choice combinator over
  `const(char)[]`/`SmallBuffer` slices would compose with the existing primitives.
- **A combinator API _can_ be zero-allocation — [flatparse] is the proof.** Its pure
  validators (parsers returning `()`) run with **zero heap allocation** via unboxed
  results; that is exactly the target for a `@nogc` D combinator, and its failure-vs-error
  split (control-flow backtracking vs unrecoverable error, like [nom]) maps cleanly onto
  `Expected!(T, E)`. [winnow]'s `&mut`-stream ergonomics and [combine]/[Angstrom][angstrom]'s
  streaming show the design space; flatparse shows the allocation floor.
- **Hand-write the lexer, table-free — [Zig's tokenizer][zig] is the model.** A
  character-class state machine emitting `(tag, byte-range)` tokens with no transition
  table and no heap is the smallest, most `@nogc`-shaped front end; prefer it to a
  generated lexer for Sparkles' small languages. And don't reach for [SIMD][simdjson]
  prematurely: [yyjson] hits GB/s with careful _scalar_ C, so SIMD is a measured
  optimization for large hot inputs, not a default.
- **Skip packrat memoization by default** — like [pest][pest] and [nom][nom] — to keep
  memory bounded and `@nogc`-friendly; reserve memoization for a measured hot spot. The
  [packrat space cost][peg] is the wrong default for a small-footprint library.
- **A [Pratt][pratt] expression loop** is the right, table-free, O(n) engine for any
  operator grammar Sparkles needs (e.g. version constraints) and is trivially `@nogc`.
- **Choose the error posture per use.** Validating a version string is fail-fast;
  parsing user-facing config or a REPL would want [chumsky][chumsky]-style recovery —
  but recovery is an architecture choice ([§4](#4-error-handling--recovery)) to make up
  front, not retrofit.
- **`Expected!(T, E)` is the natural result type** — the repo's [`expected`][expected]
  idiom already models fail-fast parse results without GC exceptions; a recovering
  variant would pair a partial value with an error list, exactly as chumsky's
  `ParseResult` does.
- **Stay batch — don't reach for [incremental / query-based][incremental] machinery.**
  The incremental cluster ([tree-sitter], [rust-analyzer], [Roslyn][roslyn], [Lezer][lezer],
  [`rustc`][rustc]) earns its keep only when the _same_ input is re-parsed after small
  edits, repeatedly, under an editor contract — and it costs persistent trees plus a
  dependency graph, the opposite of a small `@nogc` footprint. Sparkles' inputs (a
  version string, a CLI line, a VT sequence) are parse-once, so the [Wagner][incremental]
  node-reuse / [salsa]-query apparatus is pure overhead here. The one transferable idea
  is cheaper: a **[red-green][incremental]-style lossless view** (kind + width, positions
  computed on demand) is worth borrowing _only_ if a future Sparkles use wants a
  re-serializable CST (e.g. a formatter) — otherwise a plain AST is lighter. Incremental
  is an architecture to adopt deliberately for an editor, never to retrofit.

These design lessons are cashed in two follow-on documents: the **[D parsing
landscape][d-landscape]** surveys what D itself offers (Pegged, the dmd/libdparse/sdc
hand-written front-ends, mir-ion/asdf, pry) and pinpoints the gap — no maintained, `@nogc`,
zero-copy ordered-choice combinator — that a Sparkles toolkit fills; and the
**[`sparkles:parsing` proposal](../../specs/parsing/index.md)** (+ its
[milestones](../../specs/parsing/PLAN.md)) turns the sketch above into a concrete,
bottom-up design over the existing [`sparkles.base.text`][base-text] readers.

---

## Sources

This synthesis rests on the nine system deep-dives and the [theory subtree][theory];
each carries its own primary citations (papers, source trees, official docs). The
cross-cutting classifications — the deterministic/general split, the cubic wall, the
recovery ladder — trace to Knuth 1965, Earley 1970, Ford 2002/2004, Valiant 1975 / Lee
2002, and the modern tool sources cited per page.

<!-- References -->

[umbrella]: ./index.md
[concepts]: ./concepts.md
[theory]: ./theory/index.md
[formal]: ./theory/formal-languages.md
[top-down]: ./theory/top-down.md
[bottom-up]: ./theory/bottom-up.md
[general]: ./theory/general-parsing.md
[peg]: ./theory/peg-packrat.md
[pratt]: ./theory/pratt-precedence.md
[derivatives]: ./theory/derivatives.md
[incremental]: ./theory/incremental.md
[simdjson]: ./simdjson.md
[tree-sitter]: ./tree-sitter.md
[antlr]: ./antlr.md
[bison]: ./bison-yacc.md
[menhir]: ./menhir.md
[pest]: ./pest.md
[parsec]: ./haskell-parsec.md
[nom]: ./rust-nom.md
[chumsky]: ./rust-chumsky.md
[rust-analyzer]: ./rust-analyzer.md
[roslyn]: ./roslyn.md
[lezer]: ./lezer.md
[rustc]: ./rustc-queries.md
[salsa]: ./rust-analyzer.md#salsa-the-query-engine
[simd-json]: ./simd-json.md
[sonic-rs]: ./sonic-rs.md
[yyjson]: ./yyjson.md
[rapidjson]: ./rapidjson.md
[hyperscan]: ./hyperscan.md
[zig]: ./zig-tokenizer.md
[winnow]: ./rust-winnow.md
[flatparse]: ./haskell-flatparse.md
[combine]: ./rust-combine.md
[angstrom]: ./ocaml-angstrom.md
[fparsec]: ./fsharp-fparsec.md
[d-landscape]: ./d-landscape.md
[v-parsing]: https://github.com/PetarKirov/sparkles/blob/main/libs/versions/src/sparkles/versions/parsing.d
[cli-args]: https://github.com/PetarKirov/sparkles/blob/main/libs/core-cli/src/sparkles/core_cli/args.d
[base-text]: https://github.com/PetarKirov/sparkles/blob/main/libs/base/src/sparkles/base/text/package.d
[expected]: ../../guidelines/idioms/expected/index.md
