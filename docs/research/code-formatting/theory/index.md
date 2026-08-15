# Foundations — The Theory of Code Layout

Five families, forty-five years, and one question.

## The one organizing question: given a tree and a width, which of the exponentially many layouts do you pick, and how much do you pay to pick well?

Every algorithm below is an answer. [Oppen][oppen] answers _greedily, in one pass, in bounded
space_ and proves it. The [combinator][combinators] line answers _the same way, but through an
algebra you can compose_ — and spends three papers recovering Oppen's bound after giving it up.
[Optimality][optimality] answers _properly, by naming an objective and minimizing it_, and pays
a power of the page width for the privilege. [Cost & search][cost-search] answers _properly if
we can afford it, approximately when we cannot_ — which is what every shipping formatter
actually does. And [layout preservation][layout-preserving] answers a different question
entirely, the one a **code** formatter is really asked: _given a tree, a width, and the text the
tree came from, which layout?_

**Last reviewed:** August 15, 2026

> [!IMPORTANT]
> **The literature does not solve code formatting.** [Hughes 1995 explicitly excludes
> it][hughes-remark] — "not the harder problem of improving the layout of an existing text, such
> as a program … How should we handle comments? Such problems are outside the scope of this
> chapter" — and the combinator and optimality families inherit the exclusion without
> re-examining it. The word count is stark. Across the seven [combinator][combinators] and
> [optimality][optimality] papers held locally, the string "comment" appears **zero** times in
> Lindig, Chitil 2005, Chitil 2006 and Bernardy; **only in the acknowledgements** of Wadler and
> Swierstra & Chitil; and substantively in exactly two — [Yelland][optimality], in a footnote
> setting them aside, and [APEP][optimality], in an extensions section adding two primitives
> (`reset`, `full`) that exist _because_ comments break layout. Both of those two were written
> by people shipping a real code formatter.
> The half of the problem that a formatter spends most of its code on lives in
> [one small, under-cited family][layout-preserving] published in a different community.
> This gap is the survey's central finding and the reason [the D proposal][proposal] sequences
> trivia before layout.

---

## The catalog

| Family                                   | The objective it pursues                            | Time                     | Space  | Lookahead      | Alignment | Comments | Ships in                                                |
| ---------------------------------------- | --------------------------------------------------- | ------------------------ | ------ | -------------- | --------- | -------- | ------------------------------------------------------- |
| [Oppen one-pass][oppen]                  | Lexicographic overflow (avoid overflow if possible) | O(n)                     | O(w)   | ≤ one line     | —         | —        | `rustc_ast_pretty`, OCaml `Format`, Ruby `prettyprint`  |
| [Combinators][combinators]               | Lexicographic overflow, through a `Doc` algebra     | O(n)–O(n²)               | O(doc) | ≤ one line     | partial   | —        | **prettier**, Haskell `pretty`, `google-java-format`    |
| [Optimality][optimality]                 | Height, or an explicit/pluggable cost               | O(n̂^3/2)–O(nW⁶)          | > O(n) | whole document | ✅        | —        | `rfmt`, `PrettyExpressive` → Racket `fmt`               |
| [Cost & search][cost-search]             | A penalty sum, minimized approximately              | **exponential** (capped) | varies | whole line     | ✅        | ~        | **clang-format**, scalafmt, `dart_style`, **dfmt**      |
| [Layout preservation][layout-preserving] | **Preservation** — `CONSTRTEXT(PARSE(s)) = s`       | —                        | O(doc) | n/a            | ✅        | **✅**   | ASF+SDF/Spoofax, topiary, Roslyn, every IDE refactoring |

`n` = document size (DAG), `n̂` = tree size, `w`/`W` = page width. Complexities for the first
four rows are as tabulated by [APEP][optimality]; the fifth is not a layout algorithm and is not
comparable on the same axis.

## Two cross-cutting splits

**Exact vs heuristic.** Only [optimality][optimality] gets the right answer and publishes a
bound. [Oppen][oppen] and [combinators][combinators] are greedy by design and honest about it.
[Cost & search][cost-search] _wants_ to be exact and gives up under a hard-coded budget —
`Count > 50'000`, `tries < 10_00`, a 32-token window — usually without telling anyone. The
practical consequence: **three of the five families produce output that is not optimal for any
stated objective, and only one of those three says so.**

**Streaming vs whole-document.** [Oppen][oppen] alone can format an unbounded stream in bounded
memory, and the [Chitil/Swierstra sub-line][combinators] recovers that property functionally.
Everything else holds the document. For a formatter this is nearly irrelevant — the file is
already in memory — which is why the theoretically elegant bounded-space results are the least
deployed work in the tree.

---

## The distinction everyone rediscovers

Three research lines, no coordination, same two-valued flag on a group: **break all of these, or
break only as needed.**

| Source                                | "Break all of them"  | "Break only as needed" |
| ------------------------------------- | -------------------- | ---------------------- |
| [Oppen 1980][oppen-cons]              | `consistent`         | `inconsistent`         |
| [Box 1996][box-ops]                   | `HOV`                | `HV`                   |
| prettier / [combinators][combinators] | `group`              | `fill`                 |
| `rustc_ast_pretty`                    | `Breaks::Consistent` | `Breaks::Inconsistent` |

That it was invented three times independently is the strongest evidence in the survey that it
is a real feature of the problem rather than an artifact of one design. The full cross-naming of
every layout primitive is in [concepts][concepts-ir].

---

## Reading paths

**If you want to understand the field:** [Oppen][oppen] → [combinators][combinators] →
[optimality][optimality]. Three papers deep and you have the whole argument.

**If you are building a formatter:** [layout preservation][layout-preserving] **first** — it is
the only page about your actual problem — then [combinators][combinators] for the engine you
will probably write, then [cost & search][cost-search] for what you are choosing not to do and
why.

**If you are choosing an algorithm for D:** [cost & search][cost-search]'s
[incompleteness budget][budget] and [layout preservation][layout-preserving]'s
[three-layer architecture][three-layer] are the two sections that decide it. Then
[the substrate baseline][baseline].

**If you only read one thing:** [the Hughes remark][hughes-remark]. Four sentences, 1995, and it
predicted the shape of every formatter codebase written since.

---

## Milestones

| Year   | Milestone                                                                                                                         |
| ------ | --------------------------------------------------------------------------------------------------------------------------------- |
| 1973   | Goldstein surveys LISP pretty-printers; the "recursive re-predictor" — limited-lookahead search                                   |
| 1979   | Oppen's Stanford TR (STAN-CS-79-770); Karlton's Mesa implementation in the appendix                                               |
| 1980   | **[Oppen, TOPLAS][oppen]** — O(n) time, O(m) space, consistent/inconsistent, the producer/printer split                           |
| 1981   | Knuth & Plass — DP line breaking for prose ([covered in `ui-layout`][knuth-plass])                                                |
| 1995   | **[Hughes][combinators]** — the combinator library, and the [scope disclaimer][hughes-remark]                                     |
| 1996   | **[van den Brand & Visser][layout-preserving]** — Box; formatters generated from a grammar; comments by position                  |
| 1998   | **[Wadler][combinators]** — one associative concatenation; `group = flatten x <\|> x`                                             |
| 2000   | **[Lindig][combinators]** — the strict transcription; `Flat`/`Break` modes. _This is what prettier ships_                         |
| 2005   | **[Chitil][combinators]** — Oppen's bound, purely, via two lazy dequeues                                                          |
| 2009   | **[Swierstra & Chitil][combinators]** — linear, bounded, functional                                                               |
| 2011   | **[de Jonge & Visser][layout-preserving]** — text patching, origin tracking, the comment patterns                                 |
| 2013\* | clang-format ships — Dijkstra over break states, in production, cited by no paper                                                 |
| 2015   | Podkopaev & Boulytchev — arbitrary choice made polynomial by DP                                                                   |
| 2016   | **[Yelland][optimality]** (`rfmt`, explicit cost + DP over knots) · **[Geirsson][cost-search]** (scalafmt thesis)                 |
| 2017   | **[Bernardy][optimality]** — the specification greed cannot meet; Pareto frontiers · prettier 1.0                                 |
| 2023   | **[Porncharoenwase, Pombrio & Torlak][optimality]** — Π_e; pluggable cost factory; **Lean-verified**                              |
| 2024\* | `dart_style` 3.0.0 "tall style" — "the formatter was almost completely rewritten", from search onto an explicit constraint solver |

<sub>Dates are of publication, not of the work. Oppen 1980's algorithm is the 1979 tech report's;
Wadler's chapter circulated from 1998 and was published in _The Fun of Programming_ (2003); the
JFP 19(1) Swierstra & Chitil paper appeared as a Utrecht TR in 2004 under a different title.
**\* Unverified against a local artifact.** `llvm-project` and `dart_style` are pinned as
depth-1 clones, so neither carries the history needed to date its own release; both years are
from general knowledge and are marked accordingly. The `dart_style` 3.0.0 CHANGELOG entry is
quoted and verified — only its date is not.</sub>

---

## Sources

Each deep-dive carries its own primary citations and a
internal grounding ledger. The papers themselves are archived under
`$REPOS/papers/code-formatting/` (17 of the 20 cited; Podkopaev & Boulytchev and the two Mi
readability papers are paywalled and marked 🌐 wherever used).

**Related deep-dives in this tree:**
[Oppen][oppen] · [Combinators][combinators] · [Optimality][optimality] ·
[Cost & search][cost-search] · [Layout preservation][layout-preserving]

**Tree-level:** [Umbrella][umbrella] · [Concepts][concepts] · [Comparison][comparison] ·
[Verification][verification] · [The D landscape][d-landscape] · [The proposal][proposal]

<!-- References -->

<!-- Sibling theory docs -->

[oppen]: ./oppen.md
[oppen-cons]: ./oppen.md#consistent-vs-inconsistent-breaking
[combinators]: ./combinators.md
[hughes-remark]: ./combinators.md#the-remark-that-defines-this-surveys-gap
[optimality]: ./optimality.md
[cost-search]: ./cost-and-search.md
[budget]: ./cost-and-search.md#the-incompleteness-budget
[layout-preserving]: ./layout-preserving.md
[box-ops]: ./layout-preserving.md#box-a-layout-algebra-generated-from-a-grammar
[three-layer]: ./layout-preserving.md#text-patching-stop-unparsing

<!-- Tree-level docs -->

[umbrella]: ../index.md
[concepts]: ../concepts.md
[concepts-ir]: ../concepts.md#the-layout-ir-cross-naming-table
[comparison]: ../comparison.md
[verification]: ../verification.md
[d-landscape]: ../d-landscape.md
[baseline]: ../dmd-lsp-baseline.md
[proposal]: ../dmd-fmt-proposal.md

<!-- Other research trees -->

[knuth-plass]: ../../ui-layout/tex-knuth-plass.md
