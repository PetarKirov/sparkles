# Parsing Theory

The classical computer-science foundations under every parser in this survey, from
the [Chomsky hierarchy][formal] to the algorithm families that production tools
reify. This is the theory subtree of the [parsing survey][umbrella]; the
[concepts glossary][concepts] sits above it with the operational vocabulary, and the
[systems deep-dives][umbrella] (simdjson, ANTLR, Bison, …) are where these algorithms
ship. Where a deep-dive here names a real tool, it links to that tool's page.

**Last reviewed:** June 25, 2026

---

## The one organizing question: what grammars can you parse, and how fast?

Every parsing algorithm is a point on a trade-off between **generality** (which
grammars it accepts), **time/space cost**, and **determinism** (whether it commits to
one parse or pursues many). [Formal-language theory][formal] fixes the outer walls:

> [!IMPORTANT]
> **The cubic wall.** General context-free recognition is pinned to the complexity of
> Boolean matrix multiplication from _both_ sides — Valiant (1975) reduces parsing to
> BMM, and Lee (2002) proves the converse — so genuinely sub-cubic general parsing is
> effectively impossible. Every fast production parser escapes the wall the same way:
> by **restricting the grammar** to a deterministic subclass (LL, LR, PEG) that runs
> in linear time. See [formal-languages][formal].

The deep-dives split along the two classical descent directions plus the general and
expression-specific families:

- **Top-down** ([top-down][top-down]) — predict from the root downward; the LL family,
  recursive descent, and ANTLR's adaptive ALL(\*).
- **Bottom-up** ([bottom-up][bottom-up]) — shift and reduce upward; the LR family
  (SLR/LALR/canonical) and Tomita's generalized GLR.
- **General** ([general-parsing][general]) — parse _every_ CFG, ambiguity and all:
  Earley, CYK, GLL, and the shared-packed-parse-forest representation.
- **PEG & packrat** ([peg-packrat][peg]) — swap CFG nondeterminism for ordered choice;
  unambiguous and scannerless, linear-time by memoization.
- **Operator-precedence & Pratt** ([pratt-precedence][pratt]) — the linear expression
  sub-engine recursive descent embeds.
- **Derivatives** ([derivatives][derivatives]) — one self-similar operation from
  regex→DFA up to full CFG parsing.

---

## Catalog

| Deep-dive                               | Grammar class / scope                                               | Worst-case time             | Resolves ambiguity by                          | Representative tools                                                           |
| --------------------------------------- | ------------------------------------------------------------------- | --------------------------- | ---------------------------------------------- | ------------------------------------------------------------------------------ |
| [Formal languages][formal]              | Chomsky hierarchy; the parse/recognition problem & complexity walls | Θ(n³) general / O(n) det.   | (theory) — ambiguity is **undecidable**        | —                                                                              |
| [Top-down][top-down]                    | LL(1) ⊊ LL(k) ⊊ LL(\*) ⊊ non-left-recursive CFG                     | O(n) fixed-k; O(n⁴) ALL(\*) | First match / production order                 | [ANTLR][antlr], combinators ([Parsec][parsec], [nom][nom], [chumsky][chumsky]) |
| [Bottom-up][bottom-up]                  | LR(0) ⊊ SLR(1) ⊊ LALR(1) ⊊ LR(1); GLR = all CFGs                    | O(n) det.; O(n³) GLR        | Declared precedence; GLR keeps all parses      | [Bison][bison], [Menhir][menhir], [tree-sitter][tree-sitter] (GLR)             |
| [General parsing][general]              | **All** CFGs (ambiguous, left-recursive)                            | O(n³); O(n) on LR(k) (Leo)  | Returns a forest (SPPF) of all parses          | Marpa, nearley, NLTK; cf. [tree-sitter][tree-sitter]                           |
| [PEG & packrat][peg]                    | PEG — superset of LL/LR reaching some non-CFLs                      | O(n) packrat (O(n) space)   | **Ordered choice** — unambiguous by definition | [pest][pest], [nom][nom], [chumsky][chumsky]; LPeg, Peggy                      |
| [Operator-precedence & Pratt][pratt]    | Operator grammars (expressions only)                                | O(n)                        | Binding power (implicit, global)               | embedded in GCC/Clang, [chumsky][chumsky], [pest][pest]                        |
| [Parsing with derivatives][derivatives] | Regular (Brzozowski) up to **all** CFGs (PWD)                       | O(G·n³) PWD; O(n) lexers    | Returns a forest; nullability fixpoints        | ml-ulex (lexers); derp (research)                                              |

---

## Two cross-cutting splits

### Deterministic vs general

The decisive engineering choice. **Deterministic** parsers (LL, LR, PEG) commit to a
single parse and run in linear time, but reject grammars outside their subclass with a
_conflict_ at build time. **General** parsers (Earley, GLR, GLL, PWD) accept every CFG
and surface ambiguity as a runtime parse _forest_ — powerful for natural language,
ambiguous DSLs, and grammar prototyping, but with a cubic worst case and no static
determinism guarantee.

|                   | **Deterministic (LL / LR / PEG)**                              | **General (Earley / GLR / GLL / PWD)**                |
| ----------------- | -------------------------------------------------------------- | ----------------------------------------------------- |
| Grammars accepted | a decidable subclass; the rest is a build-time conflict        | every CFG (PWD/GLR also handle ambiguity & left-rec.) |
| Output            | one parse tree                                                 | a [shared packed parse forest][general] of all parses |
| Time              | **O(n)**                                                       | O(n³) worst; O(n)–O(n²) on tame grammars              |
| Ambiguity         | rejected as a conflict (LL/LR) or hidden (PEG)                 | reported as multiple derivations                      |
| Where it ships    | [Bison][bison], [Menhir][menhir], [ANTLR][antlr], [pest][pest] | [tree-sitter][tree-sitter] (GLR), Marpa, nearley      |

### Generated vs hand-written vs combinator

The same algorithm reaches code three ways: a [generator][bottom-up] compiles a grammar
file to tables ([Bison][bison], [Menhir][menhir], [ANTLR][antlr], [pest][pest]); a
**hand-written** [recursive-descent][top-down] parser codes one procedure per rule
(GCC, Clang, rustc) — usually with a [Pratt][pratt] expression loop; and a **combinator
library** ([Parsec][parsec], [nom][nom], [chumsky][chumsky]) reifies recursive descent
as composable host-language values. The comparison weighs these in the
[capstone][comparison].

---

## Suggested reading paths

- **"Ground up."** [concepts][concepts] → [formal-languages][formal] → [top-down][top-down]
  → [bottom-up][bottom-up] → [general-parsing][general].
- **"Why is everything PEG now?"** [peg-packrat][peg] → [top-down][top-down] (combinators
  as recursive descent) → the [comparison][comparison].
- **"Just the expression parser."** [pratt-precedence][pratt].
- **"The elegant outlier."** [derivatives][derivatives] → [general-parsing][general].

---

## Sources

Each deep-dive carries its own primary citations; the spine here rests on Chomsky 1956,
Knuth 1965 (LR), Lewis & Stearns 1968 (LL), Earley 1970, Pratt 1973, Valiant 1975 / Lee
2002 (the complexity wall), Ford 2002/2004 (packrat/PEG), and Might et al. 2011
(derivatives), together with the **Dragon Book** (Aho, Lam, Sethi & Ullman) and Grune &
Jacobs, _Parsing Techniques_. See the individual pages and the [concepts glossary][concepts].

<!-- References -->

[umbrella]: ../index.md
[concepts]: ../concepts.md
[comparison]: ../comparison.md
[formal]: ./formal-languages.md
[top-down]: ./top-down.md
[bottom-up]: ./bottom-up.md
[general]: ./general-parsing.md
[peg]: ./peg-packrat.md
[pratt]: ./pratt-precedence.md
[derivatives]: ./derivatives.md
[simdjson]: ../simdjson.md
[tree-sitter]: ../tree-sitter.md
[antlr]: ../antlr.md
[bison]: ../bison-yacc.md
[menhir]: ../menhir.md
[pest]: ../pest.md
[parsec]: ../haskell-parsec.md
[nom]: ../rust-nom.md
[chumsky]: ../rust-chumsky.md
