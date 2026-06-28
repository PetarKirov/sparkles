# General Context-Free Parsing: Earley, CYK, and GLL

The algorithms that parse **arbitrary** context-free grammars — every CFG, including the
ambiguous and the left-recursive — and return _all_ derivations of the input, in polynomial
time and space. This is the maximally-general corner of the [parsing design space][formal]:
where [LL][top-down] and [LR][bottom-up] insist the grammar be deterministic (one viable
derivation, decidable with finite lookahead), the general algorithms drop that requirement
entirely. They are the tools of natural-language parsing, grammar prototyping, ambiguous
DSLs, and any setting where the grammar is given and cannot be rewritten to fit a
deterministic class.

> [!NOTE]
> This doc covers the _general_ CFG algorithms — **CYK**, **Earley** (with the Leo and
> Aycock–Horspool refinements), and **GLL**. Their bottom-up sibling **GLR/Tomita** lives in
> [bottom-up parsing][bottom-up] (it is "generalised LR"); the deterministic families it
> generalises are in [top-down][top-down] and [bottom-up][bottom-up]. For why "general"
> means "handles ambiguity at the cost of cubic worst-case time", see
> [Power & limits](#power--limits) and the [formal-language hierarchy][formal].

---

## At a glance

| Aspect                    | What the general-CFG family does                                                                                                                                                                                                                                         |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Grammar class handled** | _Every_ context-free grammar — ambiguous, left-recursive, right-recursive, cyclic, ε-ridden; no normal form or determinism required (CYK is the lone exception: it needs [CNF](#cyk-the-cnf-recognition-matrix))                                                         |
| **Strategy**              | CYK: bottom-up dynamic programming over substrings. Earley: chart of dotted items, top-down prediction + bottom-up completion. GLL: generalised recursive descent with a shared call stack                                                                               |
| **Lookahead / memory**    | No fixed lookahead. State is a 2-D chart/table of size `O(n²)` (Earley sets `S(0..n)`; CYK triangular table); GLL adds a graph-structured stack and a parse forest                                                                                                       |
| **Worst-case time**       | `O(n³)` (cubic) for general/ambiguous grammars; `O(n²)` unambiguous; `O(n)` for LR(k)/LR-regular grammars (Earley+Leo). Theoretical floor: `O(n^ω)` via [Valiant](#valiants-matrix-multiplication-bound)                                                                 |
| **Worst-case space**      | `O(n²)` for the chart/table; `O(n³)` for an [SPPF](#shared-packed-parse-forests) that records every derivation                                                                                                                                                           |
| **Output**                | A recogniser (yes/no) or a [**Shared Packed Parse Forest**](#shared-packed-parse-forests) compactly encoding _all_ parse trees                                                                                                                                           |
| **Canonical algorithms**  | [CYK][cyk-w] (Cocke / [Younger 1967][younger] / [Kasami 1965][kasami]); [Earley 1970][earley70]; [Leo 1991][leo] (linear right-recursion); [Aycock & Horspool 2002][ah] (nullable fix); [GLL][gll] (Scott & Johnstone)                                                   |
| **Representative tools**  | [Marpa][marpa] (Earley+Leo+Aycock–Horspool), [`nearley.js`][nearley] (Earley+Leo), [NLTK][nltk] (Earley/chart), instaparse (GLL), [tree-sitter](../tree-sitter.md) & [Bison][bison] (GLR), [ANTLR](../antlr.md) (`ALL(*)`, a related but distinct adaptive-LL technique) |

The deterministic alternatives — where you _should_ stay if your grammar permits — are
[LL / recursive descent][top-down], [LR / LALR][bottom-up], [PEG / packrat][peg], and
[Pratt][pratt]. The [comparison capstone][comparison] places this family against all of
them.

---

## Overview / motivation

A context-free grammar can be **ambiguous**: a single input string may have many distinct
derivation trees (`1 + 2 * 3` under an un-disambiguated arithmetic grammar; almost every
natural-language sentence). It can be **left-recursive** (`Expr → Expr '+' Term`), which
loops a naïve recursive-descent parser forever. It can require **unbounded lookahead** to
decide between alternatives. The deterministic parsing classes — `LL(k)`, `LR(k)`,
[`PEG`][peg] — each carve out a _subset_ of CFGs they can handle, and reject (or silently
mis-parse) the rest. The general algorithms make the opposite bargain: **accept the entire
class of context-free languages**, and pay for it in worst-case time.

The watershed is [Earley's 1970 CACM paper][earley70], the first algorithm to parse an
_unrestricted_ CFG efficiently without requiring a normal form. Earley's own framing of the
result:

> "A parsing algorithm which seems to be the most efficient general context-free algorithm
> known is described. It is similar to both Knuth's LR(k) algorithm and the familiar
> top-down algorithm. It has a time bound proportional to `n³` (where n is the length of the
> string being parsed) in general; it has an `n²` bound for unambiguous grammars; and it runs
> in linear time on a large class of grammars, which seems to include most practical
> context-free programming language grammars." — Earley, _An Efficient Context-Free Parsing
> Algorithm_, CACM 13(2), 1970 ([abstract][earley70])

Two things in that sentence are decisive and recur throughout this family:

1. **The grammar is used as-is.** Earley parses "the grammar" directly — no transformation
   to a normal form, no left-factoring, no left-recursion elimination, no determinism
   requirement. This is the practitioner's appeal: _"Earley parsers are very appealing for a
   practitioner because they can use any context-free grammar for parsing a string"_
   ([Gopinath, _Earley Parsing_][gopinath]). The one exception is **CYK**, which _does_
   demand [Chomsky Normal Form](#cyk-the-cnf-recognition-matrix) — a transformation that
   distorts the tree shape and is the reason Earley, not CYK, is the practical default.

2. **The complexity is grammar-adaptive, not fixed.** The same algorithm runs in cubic time
   only on the genuinely hard (ambiguous) grammars; on unambiguous grammars it is quadratic,
   and on a large class of grammars it is linear — _"linear results on grammars of
   bounded-state"_ (the [bounded-state class][formal] that includes all deterministic
   grammars; note plain Earley is still `O(n²)` on right-recursive grammars until the
   [Leo][leo] fix — see [below](#joop-leos-right-recursion-optimisation)). General
   parsing is thus a strict super-set capability that degrades to deterministic-parser speed
   exactly when the grammar is deterministic.

[Grune & Jacobs][grune] place this family at the top of the parsing lattice: every
deterministic technique is a specialisation of general CFG parsing that trades coverage for
speed. The textbook taxonomy is _directional_ (top-down vs bottom-up) crossed with
_search discipline_ (deterministic vs general); the four general algorithms here populate
the "general" row:

| Direction     | Deterministic (one path)             | General (all paths)                                  |
| ------------- | ------------------------------------ | ---------------------------------------------------- |
| **Top-down**  | [LL(k)][top-down], recursive descent | **Earley** (predict/complete), **GLL**               |
| **Bottom-up** | [LR(k)][bottom-up], LALR             | **CYK**, **GLR/Tomita** (see [bottom-up][bottom-up]) |

Earley is hard to pin to one direction — it is **top-down in prediction, bottom-up in
completion** — which is exactly why it is the most widely re-implemented general algorithm.

---

## How it works

Three algorithms, one problem. We take them in historical order — CYK (the dynamic-program
that makes the cubic bound concrete), Earley (the chart algorithm that does without a normal
form), then GLL (the top-down generalisation of recursive descent) — and finish with the
shared output representation ([SPPF](#shared-packed-parse-forests)) and the theoretical
floor ([Valiant](#valiants-matrix-multiplication-bound)).

### CYK: the CNF recognition matrix

The **Cocke–Younger–Kasami** algorithm (independently arrived at by John Cocke,
[Daniel Younger (1967)][younger], and [Tadao Kasami (1965)][kasami]) is the canonical
demonstration that general CFG recognition is cubic. It is a textbook **dynamic program**:
fill a triangular table where each cell records which non-terminals can derive a given
substring, building from length-1 substrings up to the whole input.

CYK's one demand is that the grammar be in **Chomsky Normal Form** (CNF):

> "The standard version of CYK operates only on context-free grammars given in Chomsky
> normal form (CNF)." — [CYK algorithm, Wikipedia][cyk-w]

In CNF every production is either `A → B C` (two non-terminals) or `A → a` (one terminal),
with an optional `S → ε`. Any CFG can be mechanically converted to CNF, but the conversion
introduces fresh non-terminals and **binarises** the tree, so the parse tree CYK recovers is
_not_ the tree of the original grammar — a real ergonomic cost.

Given CNF, the recurrence is a window over splits. Let `P[l, s, A]` be true when
non-terminal `A` derives the length-`l` substring starting at position `s`. The base case
seeds each terminal; the inductive case tries every split point `p` and every binary rule:

```text
# CYK recurrence (P[length, start, nonterminal])
for each terminal position s:                          # length-1 substrings
    for each rule  A → a   with input[s] == a:  P[1, s, A] = true

for l in 2 .. n:                                        # longer substrings, bottom-up
  for s in 0 .. n-l:
    for p in 1 .. l-1:                                  # the split point
      for each rule  A → B C:
        if P[p, s, B] and P[l-p, s+p, C]:
          P[l, s, A] = true                             # (record back-pointer (p,B,C) for trees)

accept  ⇔  P[n, 0, S]                                   # whole input derivable from start symbol
```

The three nested loops over `(l, s, p)` are each `O(n)`, and the inner rule scan is `O(|G|)`,
giving the famous bound:

> "The worst case running time of CYK is `O(n³·|G|)`, where `n` is the length of the parsed
> string and `|G|` is the size of the CNF grammar." — [CYK algorithm, Wikipedia][cyk-w]

Space is `O(n²)` for the triangular table. **Ambiguity** is handled for free: a cell can hold
the same non-terminal via several `(p, B, C)` splits — storing those back-pointers turns the
table into a [parse forest](#shared-packed-parse-forests) of every derivation.

> [!WARNING]
> CYK's CNF requirement is its defining liability. The grammar transformation is invisible
> to the input but **mangles the parse tree** (binary internal nodes, synthetic
> non-terminals), so practical parsers reach for **Earley** — which runs the _raw_ grammar —
> and keep CYK as the clean pedagogical model of the cubic bound. CYK is still preferred in
> some NLP weighted/probabilistic settings, where the dense table maps cleanly onto a
> max-product (Viterbi) or inside–outside dynamic program.

### Earley: the chart of dotted items

[Earley's algorithm][earley70] dispenses with the normal form. Its unit of work is an
**Earley item** (a "state" in Earley's terms): a grammar production with a **dot** marking how
far it has been recognised, plus the **input position where this production started**. Written
`X → α • β, i`:

> "Each state is a tuple `(X → α • β, i)`, consisting of the production currently being matched
> (`X → α β`), the current position in that production (visually represented by the dot `•`),
> [and] the position `i` in the input at which the matching of this production began." —
> [Earley parser, Wikipedia][earley-w]

Items live in **Earley sets** `S(0), S(1), …, S(n)` — one set per gap between input tokens,
collectively the **chart**. `S(0)` is seeded with the start production, dot at the front; the
algorithm fills each `S(k)` in turn by repeatedly applying three operations until no new item
appears (the sets are kept deduplicated, which is what tames left recursion and guarantees
termination):

| Operation      | When                                                 | Effect                                                                                                       |
| -------------- | ---------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| **Prediction** | dot before a non-terminal `Y` (`… • Y …`)            | for every production `Y → γ`, add `Y → • γ, k` to **`S(k)`** — top-down expansion of what could come next    |
| **Scanning**   | dot before a terminal `a` (`… • a …`), input matches | add `X → α a • β, j` to **`S(k+1)`** — consume one input token                                               |
| **Completion** | dot at the end (`Y → γ •, j`)                        | for every `X → α • Y β, i` in **`S(j)`**, add `X → α Y • β, i` to **`S(k)`** — bottom-up "this `Y` finished" |

Quoting the operations precisely ([Earley parser, Wikipedia][earley-w]):

> "**Prediction**: For every state in `S(k)` of the form `(X → α • Y β, j)`, add `(Y → • γ, k)`
> to `S(k)` for every production in the grammar with `Y` on the left-hand side."
>
> "**Scanning**: If `a` is the next symbol in the input stream, for every state in `S(k)` of the
> form `(X → α • a β, j)`, add `(X → α a • β, j)` to `S(k+1)`."
>
> "**Completion**: For every state in `S(k)` of the form `(Y → γ •, j)`, find all states in
> `S(j)` of the form `(X → α • Y β, i)` and add `(X → α Y • β, i)` to `S(k)`."

The input is accepted iff `S(n)` contains a completed start item that began at `0`
(`S → γ •, 0`). Prediction is the **top-down** half (expanding goals); completion is the
**bottom-up** half (reducing finished sub-parses against the goals that predicted them) —
the hybrid that makes Earley both natural to write and grammar-agnostic.

A worked seed, for grammar `S → A B`, `A → a`, `B → b` on input `ab`:

```text
S(0):  S → • A B, 0      (init: start symbol, dot at front)
       A → • a, 0        (prediction: dot was before A)
S(1):  A → a •, 0        (scanning: consumed 'a')
       S → A • B, 0      (completion: A finished, advance the S item that wanted A)
       B → • b, 1        (prediction: dot now before B)
S(2):  B → b •, 1        (scanning: consumed 'b')
       S → A B •, 0      (completion: B finished — completed start item ⇒ accept)
```

**Why no normal form is needed**: prediction handles arbitrary right-hand sides directly, and
the set-deduplication makes left recursion (`A → A α`) merely add `A → • A α, k` once. The
chart is `O(n²)` items in the worst case; processing them is `O(n³)` general, `O(n²)`
unambiguous. The complexity is grammar-adaptive exactly as the abstract promised.

#### The nullable problem and the Aycock–Horspool fix

Earley's original completer has a famous bug with **nullable** non-terminals — those that can
derive the empty string (`A → ε`, or `A → B C` where both `B` and `C` are nullable). When a
nullable `Y` is _predicted_ in `S(k)`, it can also be _completed_ in the very same `S(k)` (it
matched zero input), and that completion must retroactively advance items that have not been
added yet — Earley's single left-to-right pass over the set can miss them. As the field
recorded it: _"In 1972, Alfred Aho and Jeffrey Ullman fix the empty-rule bug in Earley's
algorithm, but their solution makes the algorithm even more costly to run"_; and _"In 2002,
John Aycock and R. Nigel Horspool … solve the empty-rule problem of Earley's algorithm without
increasing its cost"_ ([Earley parser, Wikipedia][earley-w]).

[Aycock & Horspool's _Practical Earley Parsing_][ah] (The Computer Journal 45(6), 2002)
precomputes the **nullable set** of the grammar and patches the **predictor** so that a
predicted nullable is _immediately advanced over_ in the same set. The mechanism, from a
faithful implementation ([Gopinath][gopinath]):

> "for `alt` in `self._grammar[sym]`: `col.add(self.create_state(sym, tuple(alt), 0, col))`
> if `sym in self.epsilon`: `col.add(state.advance())`" — when the predicted symbol `sym` is
> nullable (`sym in self.epsilon`), the predictor _also_ advances the predicting item, "effectively
> treating the nullable symbol as already-satisfied" ([Gopinath][gopinath]).

That one extra `advance()` during prediction restores correctness without the Aho–Ullman cost
blow-up. Aycock & Horspool go further, compiling the grammar into a **split LR(0) automaton**
("split ε-DFA") so that each Earley set advances a DFA state rather than a soup of individual
items — fewer items per set, a meaningful constant-factor speed-up while preserving the
`O(n³)`/`O(n²)`/`O(n)` profile. This pre-processed automaton is what modern Earley engines
([Marpa][marpa], [`nearley`][nearley]) build on.

#### Joop Leo's right-recursion optimisation

Plain Earley is `O(n²)` on **right-recursive** grammars even when they are unambiguous and
deterministic — e.g. `A → a A | a` parsing `aaaa…`. The problem is the completer: each `A`
that finishes triggers a chain of completions back up the right-recursive spine, and those
chains stack up to quadratically many items. [Joop Leo's 1991 paper][leo] — titled, with
precision, _A general context-free parsing algorithm running in **linear time on every LR(k)
grammar** without using lookahead_ — fixes this.

Leo's insight: when an Earley set contains a **single** item that would be completed in a
deterministic (right-recursive) chain, install a **transitive / "Leo" item** that short-circuits
the whole chain to its topmost ancestor in one step, instead of walking it link by link. This
collapses the quadratic completion cascade to linear:

> "The paper presents a new general context-free parsing algorithm which runs in linear time
> and space on every LR(k) grammar without using any lookahead … For some natural right
> recursive grammars both the time and space complexity will be improved from `O(n²)` to
> `O(n)`." — [Leo 1991, abstract][leo-uu]

The combination — Earley's chart, Aycock–Horspool's nullable fix and split-DFA, and Leo's
linear right-recursion — is the state of the practical art, and is exactly what
[Marpa](#marpa-earley--leo--aycockhorspool-engineered) assembles.

### Marpa: Earley + Leo + Aycock–Horspool, engineered

[Marpa][marpa] (Jeffrey Kegler) is the reference engineering of the combined algorithm.
Kegler's own statement of what Marpa unites:

> "Marpa is a practical and fully implemented algorithm for the recognition, parsing and
> evaluation of context-free grammars. The Marpa recognizer is the first to unite the
> improvements to Earley's algorithm found in Joop Leo's 1991 paper to those in Aycock and
> Horspool's 2002 paper." — [Kegler, _Marpa, A practical general parser: the recognizer_][marpa-arxiv]

Because the engine tracks the _complete_ parse state at every position, it can tell the caller
exactly which symbols are acceptable next — which Kegler turns into two superpowers:

> "Marpa tracks the full state of the parse, as it proceeds, in a form convenient for the
> application. This greatly improves error detection and enables event-driven parsing." —
> [Kegler][marpa-arxiv]

The most distinctive of these is **Ruby Slippers parsing**, Marpa's error-recovery technique
([Error detection & recovery](#error-detection--recovery)):

> "In Ruby Slippers parsing, the parser imagines ('wishes') that the language it is parsing is
> easier to parse than it actually is." … "the lexer asks the parser what it would like to see
> instead. Marpa always knows exactly what it is looking for, so that it is no problem for the
> lexer to invent an input that makes the parser happy." — [Kegler, _Marpa and the Ruby
> Slippers_][ruby-slippers]

### GLL: generalised recursive descent

[**GLL** (Generalised LL)][gll], by Elizabeth Scott and Adrian Johnstone, is the **top-down**
general algorithm — the recursive-descent counterpart to the bottom-up [GLR/Tomita][bottom-up].
Where ordinary [recursive descent][top-down] is an LL technique that diverges on left recursion
and cannot handle ambiguity, GLL keeps the recursive-descent _shape_ — the parser code follows
the grammar's structure one-to-one — while admitting **every** CFG:

> "the fully general GLL parsing technique which is recursive descent-like" with "the property
> that the parse follows closely the structure of the grammar rules" — [GLL, parsing.stereobooster][gll-sb]

Two data structures make this possible — both borrowed from / shared with GLR:

- **Graph-Structured Stack (GSS)** — Tomita's structure (from GLR) repurposed to share the
  _recursive-descent call stacks_ of the many simultaneous parse attempts. When several
  derivations would push the same return context, the GSS merges them into one node, so the
  set of all live "call stacks" is a graph rather than exponentially many linear stacks.
- **Shared Packed Parse Forest (SPPF)** — the compact [all-parses representation](#shared-packed-parse-forests),
  identical to GLR's output.

GLL drives the work with a worklist of **descriptors** — records `(grammar slot, GSS node,
input position, SPPF node)` of "places still to explore". A set `R` holds pending descriptors,
`U` records which have ever been created (so no descriptor is processed twice — the
left-recursion / non-termination guard), and `P` records completed GSS pops. The recogniser
runs in **worst-case cubic time** for arbitrary CFGs, the same bound as Earley and GLR. GLL is
the algorithm behind tools like instaparse (Clojure), GoGLL, and the ART/Iguana research
parsers; tree-sitter and Bison instead use the bottom-up GLR cousin
([tree-sitter](../tree-sitter.md), [Bison][bison]).

> [!NOTE]
> GLL, GLR, and Earley are three routes to the same destination (all CFGs, cubic worst case,
> an SPPF of all parses). They differ in _direction and packaging_: GLL is top-down and
> recursive-descent-shaped (easy to read and debug, grammar-faithful); GLR is bottom-up and
> table-driven (fast on near-deterministic input); Earley is the hybrid chart. Choose by which
> mental model and tooling you prefer — see the [comparison][comparison].

### Shared Packed Parse Forests

An ambiguous grammar can give an input **exponentially many** parse trees (think balanced
bracketings: the Catalan numbers). Enumerating them is hopeless, so every general parser that
returns _all_ parses emits a **Shared Packed Parse Forest (SPPF)** — a DAG that factors the
forest into polynomial space by two kinds of sharing:

- **Sharing** — sub-trees common to many derivations are stored once and pointed at from
  multiple parents (a node is keyed by `(symbol, start, end)`, so identical spans coincide).
- **Packing** — a node ambiguous between several derivations holds a set of **packed nodes**,
  one per alternative, instead of being duplicated.

With **binarisation** (introducing intermediate nodes so every packed node has ≤ 2 children),
the SPPF is bounded by `O(n³)` in size, matching the parse time. CYK's back-pointer table,
Earley's completed-item links, and GLL/GLR's explicit SPPF are three encodings of the same
idea: the chart/table _already is_ a packed forest; you just read the trees back out of it.
See [concepts: parse forest][concepts] for the cross-algorithm definition.

### Valiant's matrix-multiplication bound

Is cubic the true cost of general CFG parsing? [Leslie Valiant's 1975 result][valiant] says no
in theory: CFG recognition reduces to **Boolean matrix multiplication**, inheriting its
sub-cubic exponent.

> "In 1975, Valiant showed that Boolean matrix multiplication can be used for parsing
> context-free grammars (CFGs), yielding the asymptotically fastest (although not practical)
> CFG parsing algorithm known." — [Lee, _Fast context-free grammar parsing requires fast
> Boolean matrix multiplication_][lee-jacm]

With the best known matrix-multiplication exponent `ω ≈ 2.37`, this gives `O(n^ω) ≈ O(n^2.37)`
recognition — sub-cubic, but with a constant so large it is never used in practice. The result
is two-directional: [Lillian Lee (JACM 2002)][lee-jacm] proved the **converse**, that fast CFG
parsing _requires_ fast Boolean matrix multiplication —

> "any CFG parser with time complexity `O(g·n^(3−ε))` … can be efficiently converted into an
> algorithm to multiply `m`-by-`m` Boolean matrices in time `O(m^(3−ε/3))`." — [Lee][lee-jacm]

— which explains the field's failure to find a _practical_ sub-cubic general parser: doing so
would be a breakthrough in matrix multiplication. **Cubic is the practical floor**; the Valiant
bound is the theoretical asterisk, important for context and citation, irrelevant to real
implementations.

### Power & limits

| Capability                   | General CFG family                                                                                               |
| ---------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| Languages recognised         | Exactly the **context-free languages** — the full class, the ceiling of CFG parsing ([formal-languages][formal]) |
| Ambiguous grammars           | **Yes** — returns all derivations (the central capability); CYK/Earley/GLL/GLR all do                            |
| Left recursion               | **Yes** — Earley (set dedup), GLL (GSS + descriptor `U` set), CYK (CNF removes it); deterministic LL cannot      |
| Right recursion              | Yes; linear with [Leo's optimisation](#joop-leos-right-recursion-optimisation), else `O(n²)` in plain Earley     |
| Unbounded lookahead          | Yes — no fixed `k`; the chart/forest explores all alternatives in parallel                                       |
| Context-sensitive / `aⁿbⁿcⁿ` | **No** — strictly bounded by the CFG ceiling; needs PEG semantic predicates, attributes, or a hand-written pass  |
| Per-grammar speed            | Adaptive: `O(n)` LR(k), `O(n²)` unambiguous, `O(n³)` ambiguous                                                   |

The hard limit is the **context-free ceiling** itself: these algorithms recognise every CFL and
nothing beyond. Languages requiring context sensitivity (`aⁿbⁿcⁿ`, indentation, declared-before-use
typing) fall outside, and need either a more powerful formalism ([PEG][peg] with predicates,
attribute grammars) or a post-parse pass. See [formal languages][formal] for where CFLs sit in the
Chomsky hierarchy.

### Ambiguity handling

This is the family's _raison d'être_ and its sharpest double edge. Because they explore all
derivations, the general algorithms **detect ambiguity at runtime** and can report _every_
ambiguous point — invaluable for grammar prototyping and debugging. The SPPF _is_ the set of all
parses, ready for a post-hoc disambiguation policy (priorities, semantic filtering, weighted/PCFG
selection in NLP).

The flip side, sharpened by [Laurence Tratt][tratt]: ambiguity surfaces only when an _input_
exercises it, never statically, and a "valid but ambiguous" verdict is bewildering to users —

> "I did not encounter a user who was happy with, or anything other than startled by,
> ambiguity errors: it is rather odd to be told that your input is valid but can't be parsed."
> — [Tratt, _Which Parsing Approach?_][tratt]

There is no general decision procedure to certify a CFG unambiguous (it is undecidable), so a
general parser cannot promise at build time that an ambiguity will never arise — the opposite of
an [LR/LALR][bottom-up] generator, which rejects an ambiguous grammar up front with a
shift/reduce or reduce/reduce conflict. The trade is **coverage and honest ambiguity reporting**
versus **a static guarantee of determinism**.

### Error detection & recovery

A chart/forest parser holds, at every input position, the _complete_ set of partially-recognised
items — which is precisely the information a good error message needs: **exactly which tokens
were expected here**. Marpa makes this its headline feature ("Marpa always knows exactly what it
is looking for", [Kegler][ruby-slippers]).

The standout technique is Marpa's **Ruby Slippers**: on a parse failure, the parser is asked what
token it _would_ have accepted, and the lexer **synthesises** that token to keep going — turning
expectation tracking into recovery and even into liberal/defective-input parsing (Marpa::HTML
inserting missing tags). It is the inverse of [panic-mode recovery][bottom-up]: instead of
discarding input until the parser re-synchronises, the parser _invents_ input to satisfy itself.
GLL/GLR error recovery is comparatively less developed and usually grafts on a separate strategy;
Earley/Marpa's full-state chart is the natural fit for precise diagnostics.

### Performance & complexity

| Grammar shape                 | Earley (+Leo, +Aycock–Horspool) | CYK                    | GLL / GLR       | Notes                                                                  |
| ----------------------------- | ------------------------------- | ---------------------- | --------------- | ---------------------------------------------------------------------- |
| Ambiguous / general CFG       | `O(n³)` time, `O(n²)` chart     | `O(n³ · grammar-size)` | `O(n³)`         | SPPF output up to `O(n³)`                                              |
| Unambiguous CFG               | `O(n²)`                         | `O(n³)`                | `O(n²)`–`O(n³)` | Earley's adaptive `O(n²)` is a real advantage over CYK                 |
| `LR(k)` / deterministic       | **`O(n)`** (with Leo)           | `O(n³)`                | near-linear     | Earley degrades to linear when the grammar is deterministic            |
| Right-recursive deterministic | `O(n)` with Leo, else `O(n²)`   | `O(n³)`                | `O(n)`          | the specific case [Leo 1991][leo] cures for Earley                     |
| Theoretical floor             | `O(n^ω) ≈ O(n^2.37)`            | `O(n^ω)`               | `O(n^ω)`        | [Valiant](#valiants-matrix-multiplication-bound); impractical constant |

The practical reading: **Earley with Leo is the general algorithm that "pays only for what you
use"** — linear on the deterministic grammars that deterministic parsers handle, quadratic on
merely-unambiguous ones, cubic only on genuinely ambiguous ones. CYK's flat `O(n³)` regardless of
grammar (and CNF requirement) is why it is mostly pedagogical / NLP-weighted; GLL/GLR shine when
the grammar is near-deterministic (the table-driven core runs almost linearly) but degrade to
cubic on ambiguity. None beats cubic in practice — the [Valiant/Lee][lee-jacm] reduction says
that would require a matrix-multiplication breakthrough.

### Where it shows up in practice

| Tool / system                    | Algorithm                                           | Use                                                                                                        |
| -------------------------------- | --------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| [Marpa][marpa]                   | Earley + Leo + Aycock–Horspool                      | General-purpose parser toolkit (Perl/C); Ruby Slippers recovery                                            |
| [`nearley.js`][nearley]          | Earley + Leo                                        | JS parser toolkit; "effectively linear-time for LL(k) grammars"                                            |
| [NLTK][nltk]                     | Earley / chart parsing                              | Natural-language parsing; ambiguous PCFG grammars                                                          |
| CYK (textbook / NLP)             | CYK over CNF                                        | PCFG decoding (Viterbi / inside–outside); teaching the cubic bound                                         |
| instaparse, GoGLL, ART/Iguana    | GLL                                                 | Grammar prototyping, language workbenches, composed grammars                                               |
| [tree-sitter](../tree-sitter.md) | GLR (bottom-up general)                             | Incremental editor parsing of real, occasionally-ambiguous grammars                                        |
| [Bison][bison] (`%glr-parser`)   | GLR                                                 | Generalised mode for grammars with unbounded-lookahead conflicts                                           |
| [ANTLR](../antlr.md)             | `ALL(*)` (adaptive LL — _related, not general CFG_) | Practical near-general top-down; resolves with runtime lookahead, but no left recursion and not all-parses |

> [!IMPORTANT]
> [ANTLR](../antlr.md)'s `ALL(*)` is _adjacent_ to this family, not in it. It uses arbitrary
> **runtime** lookahead (a GLR-like sub-parse over the alternatives) to pick a _single_
> production, so it accepts a strict super-set of LL but is **not** a general all-parses CFG
> parser: it does not return a forest and does not natively handle left recursion (ANTLR
> rewrites direct left recursion away first). Treat it as the high-water mark of _deterministic_
> top-down, not as Earley/GLL/GLR. See the [ANTLR deep-dive](../antlr.md).

The deterministic families you would prefer when the grammar permits — [recursive descent /
LL][top-down], [LR / LALR][bottom-up] ([Bison][bison], [Menhir][menhir]), [PEG / packrat][peg]
([`pest`][pest], [`nom`][nom], [Parsec][parsec], [`chumsky`][chumsky]), [Pratt][pratt] — trade
this generality for linear time and static guarantees. The data-parallel [`simdjson`](../simdjson.md)
sits at the far opposite end: a single fixed, unambiguous grammar exploited with SIMD, the antithesis
of general parsing.

---

## Strengths

- **Maximal coverage.** Parses _any_ context-free grammar — ambiguous, left/right-recursive,
  cyclic, ε-ridden — with no determinism requirement and (Earley/GLL/GLR) no normal form.
- **Grammar used as written.** Earley and GLL run the grammar directly: no left-factoring, no
  left-recursion elimination, no CNF; the recovered tree matches the author's grammar.
- **All parses, compactly.** The [SPPF](#shared-packed-parse-forests) encodes every derivation in
  `O(n³)` space — the natural substrate for ambiguity reporting and post-hoc disambiguation.
- **Adaptive cost (Earley+Leo).** Linear on `LR(k)`/right-recursive deterministic grammars,
  quadratic on unambiguous, cubic only on genuinely ambiguous input — you pay for the ambiguity
  you actually have.
- **Excellent diagnostics.** The full-state chart knows exactly which tokens are expected at each
  position — the basis of Marpa's precise errors and [Ruby Slippers recovery](#error-detection--recovery).
- **Rapid grammar prototyping.** Write the grammar, parse, and let the algorithm _report_ the
  ambiguities — no up-front conflict-resolution chess as with [LALR][bottom-up].

## Weaknesses

- **Cubic worst case.** `O(n³)` on ambiguous grammars; the [Valiant/Lee bound][lee-jacm] says no
  practical sub-cubic general parser exists. Pathological grammars are genuinely slow on large input.
- **Ambiguity is a runtime hazard.** "Valid but ambiguous" surfaces only on triggering input, never
  statically ([Tratt][tratt]); there is no build-time guarantee of determinism, unlike LR's conflicts.
- **Heavier constants & memory.** The chart/GSS/SPPF machinery imposes far larger per-token constants
  and memory than a [recursive-descent][top-down] or [LR table][bottom-up] parser; rarely the choice
  for a high-throughput production language.
- **CYK's CNF tax.** CYK alone needs Chomsky Normal Form, distorting the parse tree and forcing a
  conversion step — the reason Earley supplants it in practice.
- **Subtle correctness corners.** Nullable rules ([Aycock–Horspool](#the-nullable-problem-and-the-aycockhorspool-fix))
  and right-recursion blow-up ([Leo](#joop-leos-right-recursion-optimisation)) are non-obvious traps
  a naïve implementation gets wrong.
- **Disambiguation is your job.** Returning all parses is only half the battle; selecting _the_ tree
  needs an added priority/semantic/weighting layer the algorithm does not supply.

## Key design decisions and trade-offs

| Decision                                                                                     | Rationale                                                                                       | Trade-off                                                                                       |
| -------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| Accept _all_ CFGs (no determinism requirement)                                               | Parse grammars as written; never reject for a conflict; handle ambiguous/NL grammars            | Cubic worst case; ambiguity detected only at runtime; large constants                           |
| Chart of dotted items (Earley) vs CNF table (CYK)                                            | Earley runs the raw grammar and recovers the author's tree; adaptive `O(n)`–`O(n³)`             | CYK is simpler/denser but needs CNF and is flat `O(n³)`; Earley's bookkeeping is heavier        |
| [Leo transitive items](#joop-leos-right-recursion-optimisation)                              | Collapse right-recursive completion chains → linear on every `LR(k)` grammar                    | Extra per-set machinery; correctness subtlety in detecting the deterministic single-item chains |
| [Aycock–Horspool nullable fix + split-DFA](#the-nullable-problem-and-the-aycockhorspool-fix) | Correct ε-handling at no asymptotic cost; fewer items per set via an LR(0) automaton            | A grammar pre-compilation step; more implementation complexity than naïve Earley                |
| [SPPF](#shared-packed-parse-forests) for output                                              | Represent exponentially-many parses in `O(n³)` via sharing + packing + binarisation             | The forest is a DAG, not a tree — consumers must walk packed nodes and apply disambiguation     |
| Top-down (Earley predict / GLL) vs bottom-up (CYK / GLR)                                     | Top-down follows grammar structure (readable, great errors); bottom-up is fast near-determinism | Same cubic ceiling either way; choice is about tooling, debuggability, and input shape          |
| [Ruby Slippers](#error-detection--recovery) error recovery                                   | Exploit full-state chart: invent the expected token to continue / parse liberal input           | Recovery policy is application-specific; can mask genuine errors if over-eager                  |

---

## Sources

**Seminal papers**

- Jay Earley, _An Efficient Context-Free Parsing Algorithm_, Communications of the ACM 13(2),
  1970, pp. 94–102 — [ACM DL][earley70]. The chart, predict/scan/complete, and the
  `O(n³)`/`O(n²)`/`O(n)` complexity profile.
- Daniel H. Younger, _Recognition and parsing of context-free languages in time n³_, Information
  and Control 10(2), 1967 — [DOI][younger]; Tadao Kasami, technical report, 1965 — [reference][kasami].
  The CYK dynamic program.
- Joop M. I. M. Leo, _A general context-free parsing algorithm running in linear time on every
  LR(k) grammar without using lookahead_, Theoretical Computer Science 82(1), 1991, pp. 165–176 —
  [ScienceDirect][leo] · [Utrecht abstract][leo-uu]. Linear right-recursion via transitive items.
- John Aycock & R. Nigel Horspool, _Practical Earley Parsing_, The Computer Journal 45(6), 2002,
  pp. 620–630 — [Oxford Academic][ah] · [PDF][ah-pdf]. The nullable fix and split-LR(0) automaton.
- Elizabeth Scott & Adrian Johnstone, _GLL Parsing_, ENTCS 253(7), 2010 — [PDF][gll]. The top-down
  general algorithm, GSS, SPPF, descriptors.
- Leslie G. Valiant, _General context-free recognition in less than cubic time_, J. Computer and
  System Sciences 10(2), 1975, pp. 308–315 — [PDF][valiant]. Reduction to Boolean matrix multiplication.
- Lillian Lee, _Fast context-free grammar parsing requires fast Boolean matrix multiplication_,
  JACM 49(1), 2002 — [arXiv][lee-jacm]. The converse lower bound.

**Engineered tools & documentation**

- Jeffrey Kegler, _Marpa, A practical general parser: the recognizer_, 2019 — [arXiv:1910.08129][marpa-arxiv];
  _Marpa and the Ruby Slippers_ — [Ocean of Awareness][ruby-slippers]; [Marpa site][marpa].
- [`nearley.js`][nearley] — JS Earley+Leo toolkit. [NLTK][nltk] — Earley/chart parsing for NLP.

**Secondary / reference**

- [Earley parser][earley-w] and [CYK algorithm][cyk-w], Wikipedia — operation definitions and
  complexity statements quoted above.
- Rahul Gopinath, _Earley Parsing_ — [blog][gopinath]. Worked nullable/Leo implementation.
- Dick Grune & Ceriel J. H. Jacobs, _Parsing Techniques: A Practical Guide_, 2nd ed., Springer
  2008 — [book site][grune]. The general-parsing taxonomy.
- Laurence Tratt, _Which Parsing Approach?_, 2020 — [tratt.net][tratt]. When (not) to reach for
  generalised parsing.

**Related docs in this catalog:** [formal languages & the hierarchy][formal] · [top-down (LL,
recursive descent, GLL's deterministic base)][top-down] · [bottom-up (LR, LALR, GLR)][bottom-up] ·
[PEG & packrat][peg] · [parsing-with-derivatives][derivatives] · [Pratt / precedence][pratt] ·
[concepts glossary][concepts] · [theory index][theory-index] · [parsing umbrella][umbrella] ·
[comparison capstone][comparison].

<!-- References -->

[umbrella]: ../index.md
[concepts]: ../concepts.md
[comparison]: ../comparison.md
[theory-index]: ./index.md
[formal]: ./formal-languages.md
[top-down]: ./top-down.md
[bottom-up]: ./bottom-up.md
[peg]: ./peg-packrat.md
[pratt]: ./pratt-precedence.md
[derivatives]: ./derivatives.md
[antlr]: ../antlr.md
[tree-sitter]: ../tree-sitter.md
[bison]: ../bison-yacc.md
[menhir]: ../menhir.md
[parsec]: ../haskell-parsec.md
[nom]: ../rust-nom.md
[chumsky]: ../rust-chumsky.md
[pest]: ../pest.md
[simdjson]: ../simdjson.md
[earley70]: https://dl.acm.org/doi/10.1145/362007.362035
[earley-w]: https://en.wikipedia.org/wiki/Earley_parser
[cyk-w]: https://en.wikipedia.org/wiki/CYK_algorithm
[younger]: https://doi.org/10.1016/S0019-9958(67)80007-X
[kasami]: https://en.wikipedia.org/wiki/CYK_algorithm#cite_note-kasami-2
[leo]: https://www.sciencedirect.com/science/article/pii/030439759190180A
[leo-uu]: https://research-portal.uu.nl/en/publications/a-general-cf-parsing-algorithm-running-in-linear-time-on-every-lr/
[ah]: https://academic.oup.com/comjnl/article-abstract/45/6/620/429185
[ah-pdf]: https://webhome.cs.uvic.ca/~nigelh/Publications/PracticalEarleyParsing.pdf
[gll]: https://dotat.at/tmp/gll.pdf
[gll-sb]: https://parsing.stereobooster.com/gll/
[valiant]: https://github.com/luka-mikec/valiant-parsing
[lee-jacm]: https://arxiv.org/abs/cs/0112018
[marpa]: https://jeffreykegler.github.io/Marpa-web-site/
[marpa-arxiv]: https://arxiv.org/abs/1910.08129
[ruby-slippers]: https://jeffreykegler.github.io/Ocean-of-Awareness-blog/individual/2011/11/marpa-and-the-ruby-slippers.html
[nearley]: https://nearley.js.org/
[nltk]: https://www.nltk.org/
[gopinath]: https://rahul.gopinath.org/post/2021/02/06/earley-parsing/
[grune]: https://dickgrune.com/Books/PTAPG_2nd_Edition/
[tratt]: https://tratt.net/laurie/blog/2020/which_parsing_approach.html
