# Parsing

A breadth-first survey of **parsing** — from the classical computer-science
fundamentals (formal-language theory and the LL/LR/Earley/PEG algorithm families),
through the modern functional-programming designs (parser combinators), to the
high-performance, low-level data-parallel and SIMD techniques used in C, C++, Rust,
and Zig, and the incremental, error-resilient parsers behind today's editors. The
goal is a grounded map of the state of the art across language ecosystems, to inform
an allocation-conscious (`@nogc`/`@safe`) parsing direction for Sparkles — the repo
already hand-parses version schemes ([`sparkles.versions.parsing`][v-parsing]), CLI
arguments ([`sparkles.core_cli.args`][cli-args]), and terminal VT sequences
(`sparkles:ghostty`), so the design space below is directly relevant.

This survey answers six questions:

1. **What are the classical results?** The Chomsky hierarchy, the automata that
   recognize each level, and the decidability/complexity walls that decide which
   parsing algorithms are even possible. See [formal-languages][formal] and the
   [theory subtree][theory].
2. **How do the deterministic algorithm families work?** Top-down (recursive
   descent, LL(k), ALL(\*)), bottom-up (LR/SLR/LALR/canonical-LR, GLR), and the
   expression-parsing engines (operator-precedence, Pratt). See [top-down][top-down],
   [bottom-up][bottom-up], and [pratt-precedence][pratt].
3. **How do you parse _any_ grammar?** General context-free parsing — Earley, CYK,
   GLL — and the derivative-based family. See [general-parsing][general] and
   [derivatives][derivatives].
4. **What is the PEG/packrat model**, and why did it become the default for new
   tooling? See [peg-packrat][peg].
5. **How do real ecosystems package these ideas?** Generators (ANTLR, Bison, Menhir,
   pest), functional combinators (Parsec, nom, chumsky), data-parallel SIMD
   (simdjson), and incremental/IDE-grade engines (tree-sitter). See the
   [master catalog](#systems-master-catalog).
6. **What does the field agree on, and where does it split?** The deterministic-vs-
   general, batch-vs-incremental, and throughput-vs-recovery trade-offs, and where a
   Sparkles parser would sit. See the [comparison][comparison].

> [!NOTE]
> **Scope: this is wave 1 — the foundation + flagship wave.** It establishes the
> theory subtree, the shared vocabulary, and nine flagship systems that anchor each
> category. A second wave will broaden each category: more combinators (winnow,
> combine, FastParse, parsley, cats-parse, FParsec, Angstrom, FlatParse), more
> high-performance/SIMD parsers (simd-json/sonic-rs, yyjson/RapidJSON, Hyperscan,
> Zig's tokenizer), more generators (LALRPOP, Lark/PLY, Peggy, Ragel/re2c), and the
> incremental/IDE cluster (Roslyn red-green trees, rust-analyzer/rowan, Lezer). Rows
> below that a future deep-dive will add are noted, not silently omitted.

**Last reviewed:** June 25, 2026

---

## Foundations (theory)

The classical results, each developed in its own deep-dive. Start with the
[concepts glossary][concepts] for the shared vocabulary, then the
[theory umbrella][theory] for the algorithmic spine.

| Topic                                    | What it pins down                                                                          | Canonical results                                                        | Link                       |
| ---------------------------------------- | ------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------ | -------------------------- |
| **Concepts & vocabulary**                | The operational glossary every deep-dive links to; the parser-landscape table              | —                                                                        | [concepts][concepts]       |
| **Formal languages & the parse problem** | The Chomsky hierarchy, grammar↔automaton pairing, decidability & the cubic complexity wall | Chomsky 1956; Valiant 1975 / Lee 2002 (BMM bound); ambiguity undecidable | [formal-languages][formal] |
| **Top-down parsing**                     | Recursive descent, FIRST/FOLLOW & LL(1), LL(k)/strong-LL, LL(\*)/ALL(\*)                   | Lewis & Stearns 1968; Rosenkrantz & Stearns 1970; Parr et al. 2011/2014  | [top-down][top-down]       |
| **Bottom-up parsing**                    | Shift-reduce, the LR(0) automaton, SLR/LALR/canonical-LR, GLR                              | Knuth 1965; DeRemer & Pennello 1982; Tomita 1985                         | [bottom-up][bottom-up]     |
| **General CF parsing**                   | Parsing _every_ CFG (ambiguous, left-recursive) — Earley, CYK, GLL, SPPFs                  | Earley 1970; CYK; Leo 1991; Scott & Johnstone (GLL); Marpa               | [general-parsing][general] |
| **PEG & packrat**                        | Recognition-based grammars, ordered choice, linear-time memoization, the space cost        | Ford 2002 (packrat) & 2004 (PEG); Warth 2008 (left recursion)            | [peg-packrat][peg]         |
| **Operator-precedence & Pratt**          | The linear-time expression engine recursive descent drops in                               | Floyd 1963; Pratt 1973; Crockford 2007; matklad                          | [pratt-precedence][pratt]  |
| **Parsing with derivatives**             | One self-similar operation from regex→DFA up to full CFG parsing                           | Brzozowski 1964; Owens et al. 2009; Might et al. 2011; Adams et al. 2016 | [derivatives][derivatives] |

---

## Systems master catalog

One row per surveyed system. **Algorithm / grammar class** is the formalism it
implements (cross-linked to the theory deep-dive that develops it). **Error
recovery** classifies the deepest tier reached: _fail-fast_ (stop at the first
error) → _panic-mode_ (skip to a synchronizing token and resume) → _diagnostic_
(good positioned messages, still one error) → _recovering_ (produce a partial
result + a list of errors) → _incremental/IDE_ (recover **and** re-parse edited
regions on every keystroke). **Performance posture** is the headline runtime model.

| System            | Ecosystem      | Category                 | Algorithm / grammar class                                       | Error recovery       | Performance posture                                          | Link                       |
| ----------------- | -------------- | ------------------------ | --------------------------------------------------------------- | -------------------- | ------------------------------------------------------------ | -------------------------- |
| **simdjson**      | C++            | SIMD / data-parallel     | Two-stage: vectorized structural index + pushdown state machine | Fail-fast (validate) | Branchless SIMD, ~ GB/s, zero-copy, runtime CPU dispatch     | [simdjson][simdjson]       |
| **tree-sitter**   | C              | Incremental / IDE-grade  | Table-driven [GLR][bottom-up]; lossless CST                     | **Incremental/IDE**  | Temporal: reuse unchanged subtrees per keystroke; no SIMD    | [tree-sitter][tree-sitter] |
| **ANTLR**         | Java (10 tgts) | Generator (LL / ALL(\*)) | [ALL(\*)][top-down] adaptive LL — any non-left-recursive CFG    | Recovering           | O(n⁴) worst, linear in practice via warm lookahead-DFA cache | [antlr][antlr]             |
| **GNU Bison**     | C (multi-tgt)  | Generator (LR)           | [LALR(1)][bottom-up] default; IELR/canonical; opt-in GLR        | Panic-mode (`error`) | Linear, table-driven, tiny constant; sequential              | [bison-yacc][bison]        |
| **Menhir**        | OCaml          | Generator (LR)           | Full [LR(1)][bottom-up] (Pager); opt-in canonical/LALR/GLR      | Recovering API¹      | Linear; resumable API powers Merlin/ocaml-lsp                | [menhir][menhir]           |
| **pest**          | Rust           | Generator (PEG)          | [PEG][peg] (non-memoizing recursive descent)                    | Diagnostic           | Scannerless, zero-copy leaves; super-linear on adversarial   | [pest][pest]               |
| **Parsec family** | Haskell        | Parser combinator        | Predictive [LL][top-down]-with-`try`; ordered choice            | Diagnostic / recov.² | Scalar; near-linear on LL(1); attoparsec streaming/zero-copy | [haskell-parsec][parsec]   |
| **nom**           | Rust           | Parser combinator        | [PEG][peg]-like ordered-choice recursive descent (scannerless)  | Fail-fast            | Zero-copy, byte/streaming, ~ handwritten-C; no memoization   | [rust-nom][nom]            |
| **chumsky**       | Rust           | Parser combinator        | Recursive-descent [PEG][peg]; opt-in left-rec + memoization     | **Recovering**       | Zero-copy 1.0 rewrite; no SIMD/streaming/incremental         | [rust-chumsky][chumsky]    |

<sub>¹ Menhir's incremental/inspection API is the substrate IDE tooling uses for
recovery and live parsing; unlike tree-sitter, it is not a built-in edit-local CST
reuse engine. ² attoparsec drops error book-keeping for speed; Megaparsec adds typed
errors, error bundles, and on-the-fly recovery.</sub>

> Categories deferred to wave 2: **Combinators** — winnow, combine (Rust),
> FastParse/parsley/cats-parse (Scala), FParsec (F#), Angstrom (OCaml), FlatParse
> (Haskell). **SIMD / data-parallel** — simd-json & sonic-rs (Rust), yyjson &
> RapidJSON (C/C++), Hyperscan/Vectorscan (regex SIMD), Zig's tokenizer. **Generators**
> — LALRPOP (Rust), Lark & PLY (Python), Peggy (JS), Ragel/re2c (state-machine
> lexers). **Incremental/IDE** — Roslyn red-green trees (C#), rust-analyzer/rowan,
> Lezer (CodeMirror).

---

## Taxonomy

### By parsing strategy

The single most load-bearing axis: _how_ the parser explores the grammar. Each family
is developed in the linked theory deep-dive.

| Strategy                              | The idea                                                                         | Theory                                      | Systems here                                                           |
| ------------------------------------- | -------------------------------------------------------------------------------- | ------------------------------------------- | ---------------------------------------------------------------------- |
| **Top-down (LL / recursive descent)** | Predict the rule from lookahead, expand from the root; leftmost derivation       | [top-down][top-down]                        | [ANTLR][antlr] (ALL(\*)), and every combinator below                   |
| **Bottom-up (LR family)**             | Shift tokens, reduce handles bottom-up; rightmost derivation in reverse          | [bottom-up][bottom-up]                      | [Bison][bison] (LALR), [Menhir][menhir] (LR(1))                        |
| **Generalized (GLR / GLL / Earley)**  | Pursue all live parses at once (graph-structured stack / chart); all CFGs        | [bottom-up][bottom-up] · [general][general] | [tree-sitter][tree-sitter] (GLR); Bison/Menhir GLR mode                |
| **PEG (ordered-choice recognition)**  | First-match-wins ordered choice + syntactic predicates; unambiguous, scannerless | [peg-packrat][peg]                          | [pest][pest], [nom][nom], [chumsky][chumsky], [Parsec][parsec] (-like) |
| **Operator-precedence / Pratt**       | A linear expression sub-engine driven by binding power                           | [pratt-precedence][pratt]                   | embedded in [chumsky][chumsky], [pest][pest] (`PrattParser`)           |
| **Derivative-based**                  | Differentiate the language by each input symbol; regex→DFA up to full CFG        | [derivatives][derivatives]                  | research-grade (derp); derivative lexers in ml-ulex                    |
| **SIMD / data-parallel**              | Classify the whole input with vector instructions, then a scalar second pass     | [formal-languages][formal]                  | [simdjson][simdjson]                                                   |

### By interface model

_How the grammar reaches the parser_ — the ergonomics axis.

| Interface model                         | What you write                                                   | Systems                                                                                                                                     |
| --------------------------------------- | ---------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| **Offline generator (external DSL)**    | A grammar file compiled to a parser ahead of time                | [ANTLR][antlr] (`.g4`), [Bison][bison] (`.y`), [Menhir][menhir] (`.mly`), [pest][pest] (`.pest`), [tree-sitter][tree-sitter] (`grammar.js`) |
| **Embedded combinators (internal DSL)** | Ordinary host-language values composed with combinator functions | [Parsec][parsec], [nom][nom], [chumsky][chumsky]                                                                                            |
| **Hand-written recursive descent**      | A procedure per rule, often + a [Pratt][pratt] expression loop   | the production norm (GCC/Clang/rustc/Go); the substrate the above reify                                                                     |
| **Library state machine (no grammar)**  | Direct two-stage SIMD pipeline, hand-tuned                       | [simdjson][simdjson]                                                                                                                        |

### By error-recovery posture

The modern differentiator (see the [comparison][comparison]). Recovery is what
separates a batch compiler back-end from an IDE-grade front-end.

| Posture                  | Behaviour on a syntax error                                       | Systems                                                                  |
| ------------------------ | ----------------------------------------------------------------- | ------------------------------------------------------------------------ |
| **Fail-fast / validate** | Stop at the first error; report position                          | [simdjson][simdjson], [nom][nom], [Bison][bison] (without `error` rules) |
| **Panic-mode**           | Skip to a synchronizing token and resume without a full tree      | [Bison][bison] (`error` rules), classic LL/LR parsers                    |
| **Diagnostic**           | Precise positioned message (expected-sets), still one error       | [pest][pest], [Parsec/Megaparsec][parsec] (base)                         |
| **Recovering**           | Produce a partial AST **and** a list of errors                    | [chumsky][chumsky], [ANTLR][antlr], Megaparsec, [Menhir][menhir] clients |
| **Incremental / IDE**    | Recover **and** re-parse only the edited region on each keystroke | [tree-sitter][tree-sitter]                                               |

---

## Milestones

A high-confidence timeline interleaving **theory/algorithm milestones** with
**tool/system milestones**. Per-result provenance lives in each deep-dive's `Sources`.

| Year        | Theory / algorithm milestone                                                                     | Tool / system milestone                                                    |
| ----------- | ------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------- |
| **1956**    | **Chomsky** — _Three Models for the Description of Language_ (the [hierarchy][formal])           | —                                                                          |
| 1959–1963   | Chomsky formal properties; **Floyd 1963** — [operator-precedence][pratt] parsing                 | —                                                                          |
| **1964**    | **Brzozowski** — [derivatives of regular expressions][derivatives]                               | —                                                                          |
| **1965**    | **Knuth** — _On the Translation of Languages from Left to Right_ ([LR parsing][bottom-up])       | CYK recognition (Cocke/Kasami/Younger, 1965–67)                            |
| 1968–1970   | **Lewis & Stearns** LL(k); **Earley 1970** — general [CF parsing][general]                       | —                                                                          |
| **1973**    | **Pratt** — _Top Down Operator Precedence_ ([TDOP][pratt])                                       | —                                                                          |
| **1975**    | **Valiant** — sub-cubic CF recognition via Boolean matrix mult.                                  | **yacc** (Johnson, Bell Labs) — LALR(1) generator ships on Unix            |
| 1977–1982   | **Pager 1977** minimal-state LR; **DeRemer & Pennello 1982** efficient [LALR(1)][bottom-up]      | **lex**/**flex** lexer generators                                          |
| **1985**    | **Tomita** — [GLR][bottom-up] (graph-structured stack) for natural language                      | **GNU Bison** released                                                     |
| 1986        | The **"Dragon Book"** (Aho, Sethi & Ullman) codifies the field                                   | **PCCTS**, Terence Parr's ANTLR predecessor (1989)                         |
| **1991**    | **Leo** — linear Earley on every LR(k) grammar                                                   | —                                                                          |
| 1998–2001   | **Hutton & Meijer 1998** _Monadic Parsing_; combinator theory matures                            | **Parsec** (Leijen & Meijer, 2001) — [Haskell combinators][parsec]         |
| **2002**    | **Ford** — [packrat parsing][peg] (linear-time PEG); **Lee** — BMM lower bound                   | **Aycock & Horspool** practical Earley                                     |
| **2004**    | **Ford** — [Parsing Expression Grammars][peg] (POPL)                                             | —                                                                          |
| 2006–2009   | **Warth 2008** PEG + left recursion; **Owens et al. 2009** [derivatives reexamined][derivatives] | **Menhir** (Pottier & Régis-Gianas, 2006); **attoparsec**                  |
| **2011**    | **Might, Darais & Spiewak** — [Parsing with Derivatives][derivatives]; **LL(\*)** (PLDI)         | **nom** development begins; **Marpa** (Kegler) — engineered Earley         |
| 2012–2014   | **CompCert** verified parser (ESOP 2012); **ALL(\*)** (Parr, Harwell & Fisher, OOPSLA 2014)      | **ANTLR 4** (2013, [ALL(\*)][top-down]); **nom** 1.0 (2015)                |
| 2015–2016   | **Megaparsec**; **Adams et al. 2016** — PWD is cubic, ~951× faster                               | Bison counterexample research (Isradisaikul & Myers, PLDI 2015)            |
| 2017–2018   | **Jourdan & Pottier 2017** — verified C11 LR parser (TOPLAS)                                     | **tree-sitter** (Brunsfeld/GitHub, 2018) — [incremental GLR][tree-sitter]  |
| **2019**    | —                                                                                                | **simdjson** (Langdale & Lemire, VLDB J.) — [SIMD JSON][simdjson]          |
| 2020–2021   | **CPython** adopts a [PEG][peg] parser (PEP 617)                                                 | **chumsky** (recovering combinators); **Bison 3.8** counterexamples        |
| 2023–2026\* | —                                                                                                | **winnow** forks nom; **chumsky 1.0** zero-copy; **Menhir** GLR back-end\* |

<sub>\* The Menhir GLR back-end is dated to the `20260122` release as observed in
this review; treat 2023–2026 tool entries as current-as-of-review.</sub>

---

## Quick navigation

### Suggested reading paths

- **"I want the classical theory first."** [concepts][concepts] → [formal-languages][formal]
  → [top-down][top-down] → [bottom-up][bottom-up] → [general-parsing][general].
- **"I want the PEG/combinator lineage."** [peg-packrat][peg] → [haskell-parsec][parsec]
  → [rust-nom][nom] → [rust-chumsky][chumsky] → [pest][pest].
- **"I want the high-performance story."** [formal-languages][formal] (the complexity
  wall) → [simdjson][simdjson] → [tree-sitter][tree-sitter] (incrementality as the
  _other_ way to be fast).
- **"I want production generators."** [bottom-up][bottom-up] → [bison-yacc][bison] →
  [menhir][menhir] → [top-down][top-down] → [antlr][antlr].
- **"I want expression parsing."** [pratt-precedence][pratt] → the `PrattParser` notes
  in [pest][pest] / [chumsky][chumsky].
- **"I'm designing the Sparkles parser."** [comparison][comparison] → [rust-nom][nom]
  (zero-copy, `@nogc`-shaped) + [rust-chumsky][chumsky] (recovery) → [peg-packrat][peg]
  (the space cost) → [pratt-precedence][pratt] (the expression engine).

### Synthesis

- **[Concepts & vocabulary][concepts]** — the shared glossary + the parser-landscape table.
- **[Theory umbrella][theory]** — the classical algorithm spine, end to end.
- **[Comparison][comparison]** — the head-to-head matrix, the consensus, the trade-offs, and where a Sparkles parser fits.

---

## Sources

Each deep-dive carries its own primary-source citations (papers, source trees, and
official docs); the authoritative artifacts behind this index's classifications are:

- **Foundational theory** — Chomsky 1956; Knuth 1965; Earley 1970; Ford 2002/2004;
  Valiant 1975 / Lee 2002; as cited in the [theory subtree][theory] and [concepts][concepts].
- **Per-system sources** — the project source trees, official docs, and papers cited in
  each linked deep-dive ([simdjson][simdjson], [tree-sitter][tree-sitter], [ANTLR][antlr],
  [Bison][bison], [Menhir][menhir], [pest][pest], [Parsec][parsec], [nom][nom],
  [chumsky][chumsky]).

<!-- References -->

<!-- Within-tree: foundations -->

[concepts]: ./concepts.md
[theory]: ./theory/index.md
[formal]: ./theory/formal-languages.md
[top-down]: ./theory/top-down.md
[bottom-up]: ./theory/bottom-up.md
[general]: ./theory/general-parsing.md
[peg]: ./theory/peg-packrat.md
[pratt]: ./theory/pratt-precedence.md
[derivatives]: ./theory/derivatives.md

<!-- Within-tree: systems -->

[simdjson]: ./simdjson.md
[tree-sitter]: ./tree-sitter.md
[antlr]: ./antlr.md
[bison]: ./bison-yacc.md
[menhir]: ./menhir.md
[pest]: ./pest.md
[parsec]: ./haskell-parsec.md
[nom]: ./rust-nom.md
[chumsky]: ./rust-chumsky.md

<!-- Within-tree: synthesis -->

[comparison]: ./comparison.md

<!-- Sparkles source -->

[v-parsing]: https://github.com/PetarKirov/sparkles/blob/main/libs/versions/src/sparkles/versions/parsing.d
[cli-args]: https://github.com/PetarKirov/sparkles/blob/main/libs/core-cli/src/sparkles/core_cli/args.d
