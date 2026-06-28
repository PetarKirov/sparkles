# Top-Down Parsing: Recursive Descent, LL(k), and LL(\*)

Top-down parsing builds the parse tree from the root down, expanding the leftmost
nonterminal at each step by **predicting** which production to apply from a bounded
window of upcoming input. It is the family that gives you the parser you would write
by hand — one function per grammar rule — and the one that compiler courses teach
first because the generated code mirrors the grammar one-to-one. Its theory is the LL
hierarchy: `LL(1)`, `LL(k)`, strong-LL, `LL(*)`, and ANTLR's adaptive `ALL(*)`. This
doc is the top-down leaf of the [parsing theory subtree][theory-index]; its mirror
image, building the tree from the leaves up, is [bottom-up parsing][bottom-up].

## At a glance

| Dimension              | Top-down / LL                                                                                                                                |
| ---------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| Derivation produced    | **Leftmost** derivation, tree built **root → leaves** (the second `L` in `LL`)                                                               |
| Input scan             | **Left-to-right** (the first `L` in `LL`)                                                                                                    |
| Decision model         | **Predictive**: at each nonterminal, pick one production from `k` tokens of lookahead (`LL(k)`) or a regular/adaptive lookahead language     |
| Core data structure    | A `FIRST`/`FOLLOW`-derived **parse table** `M[A, a]`, or — equivalently — a set of mutually recursive **procedures** (recursive descent)     |
| Grammar class          | `LL(1)` ⊊ `LL(k)` ⊊ `LL(*)` ⊊ non-left-recursive CFG; strictly weaker than [`LALR`/`LR`][bottom-up] in the fixed-`k` regime                  |
| Hard structural limits | **No left recursion**; alternatives with common prefixes need **left-factoring**; fixed-`k` LL is a strict, undecidable-membership hierarchy |
| Time / space (fixed-k) | `O(n)` time, `O(d)` stack for input length `n` and nesting depth `d`                                                                         |
| Time (adaptive)        | `ALL(*)`: `O(n⁴)` worst case, **linear in practice** ([Parr, Harwell & Fisher 2014][allstar])                                                |
| Ambiguity              | Not handled: an LL grammar must be unambiguous; conflicts are a static table-construction error (or, in `ALL(*)`, resolved by rule order)    |
| Error recovery         | **Panic-mode** synchronization on `FOLLOW`/sync sets; precise error location at the failing token                                            |
| Canonical references   | [Lewis & Stearns 1968][lewis-stearns]; [Rosenkrantz & Stearns 1970][rs70]; [Dragon Book §4.4][dragon]; [Grune & Jacobs ch. 6, 8][gj]         |
| Real-world tools       | [ANTLR][antlr] (`ALL(*)`), [Parsec][parsec]/[nom][nom]/[chumsky][chumsky] (combinators), [pest][pest] (PEG), hand-written recursive descent  |

> [!NOTE]
> This page covers the **LL / predictive** branch of top-down parsing. The
> backtracking, ordered-choice branch — [PEG and packrat parsing][peg] — and the
> combinator libraries that implement it ([Parsec][parsec], [nom][nom],
> [chumsky][chumsky], [pest][pest]) are surveyed in their own deep-dives.
> [Operator-precedence / Pratt parsing][pratt] is the top-down technique specialized
> for expression grammars. The production `ALL(*)` system is detailed in
> [the ANTLR deep-dive][antlr]; this page summarizes the algorithm.

---

## Overview

### The core idea: predict and match

A top-down parser maintains a **prediction** for the rest of the input — a sentential
form with a marker at the leftmost unexpanded symbol — and advances it by exactly two
operations. [Grune & Jacobs][gj] state the whole model in one sentence (ch. 8,
"Deterministic top-down methods"):

> "in a top-down parser we have a prediction for the rest of the input, and that this
> prediction has either a terminal symbol in front, in which case we _match_, or a
> non-terminal, in which case we _predict_." — Grune & Jacobs, _Parsing Techniques_,
> §8

`match` is trivial: if the front of the prediction is a terminal, it must equal the
next input token (consume both) or the parse fails. The entire difficulty of top-down
parsing is the `predict` step:

> "The predict step consists of replacing a non-terminal by one of its right-hand
> sides, and if we have no means to decide which right-hand side to select, we have to
> try them all." — Grune & Jacobs, §8

Trying them all is backtracking (the realm of [PEG/packrat][peg]). **Deterministic**
top-down parsing — the LL family — is the discipline of restricting the grammar so
that the next few input tokens _uniquely_ determine the production, eliminating the
search:

> "in this chapter and the next we will concentrate on parsers that do not have to
> search: there will always be only one possibility to choose from. Parsers with this
> property are called deterministic. Deterministic parsers are much faster than
> non-deterministic ones, but there is a penalty: the class of grammars that the
> parsing method is suitable for … is more restricted." — Grune & Jacobs, §8

That penalty — power traded for speed and predictability — is the through-line of this
entire page. See [Power & limits](#power-limits).

### The name LL(k)

The class was named and characterized by **Lewis & Stearns** in
["Syntax-Directed Transduction"][lewis-stearns] (JACM, 1968), which defined `LL(k)`
grammars and showed how they drive syntax-directed translation, and by
**Rosenkrantz & Stearns** in ["Properties of Deterministic Top-Down
Grammars"][rs70] (1970), which is the deep theory: it gives a decision procedure for
whether a grammar is `LL(k)`, an ε-rule elimination procedure, a construction of a
deterministic pushdown recognizer, and the strictness of the hierarchy (below). The
mnemonic decomposes the runtime behaviour:

- **`L`** — scan the input **L**eft-to-right;
- **`L`** — produce a **L**eftmost derivation;
- **`(k)`** — using `k` tokens of **lookahead** to choose each production.

The dual is `LR(k)` — Left-to-right, **R**ightmost derivation in reverse, `k`
lookahead — which is [bottom-up parsing][bottom-up]. Every term here is defined in the
[parsing concepts glossary][concepts].

### Recursive descent: the grammar _is_ the program

The most important practical fact about LL parsing is that it has a structural
realization requiring no table at all. Each nonterminal becomes a procedure; the body
of the procedure follows the right-hand side, calling sibling procedures for
nonterminals and matching tokens for terminals. [Grune & Jacobs][gj] name the
correspondence precisely (§6.6):

> "This method is called recursive descent. Descent, because it operates top-down, and
> recursive, because each non-terminal is implemented as a procedure that can directly
> or indirectly (through other procedures) invoke itself." — Grune & Jacobs, §6.6

This one-to-one mapping — rule ↔ function, alternative ↔ `switch`/`if`, repetition ↔
loop, recursion ↔ recursion — is why top-down parsers are the easiest to write by
hand, to read, and to debug: a stack trace through the parser _is_ a partial parse
tree. It is the technique behind the reference compilers for many production languages
(the [ALL(\*) paper][allstar] notes the GCC and Clang C/C++ front-ends and the Java
compiler `javac` all use hand-written recursive descent), and the one
[combinator libraries][parsec] reify as composable values rather than emit as code.

---

## How it works

The two faces of LL parsing — the **table** (`M[A, a]`) and the **procedures**
(recursive descent) — are computed from the same two ingredients: the `FIRST` and
`FOLLOW` sets.

### FIRST and FOLLOW

For a grammar symbol sequence `α`, `FIRST(α)` is the set of terminals that can begin a
string derived from `α` (plus `ε` if `α` can derive the empty string). For a
nonterminal `A`, `FOLLOW(A)` is the set of terminals that can immediately follow `A` in
some sentential form (plus the end-marker `$` if `A` can be last). The standard
fixpoint rules (Dragon Book §4.4, Grune & Jacobs §8.2):

```text
FIRST(α):
  • if α = a β  (a terminal)        →  a ∈ FIRST(α)
  • if α = A β  (A nonterminal)     →  FIRST(A) ⊆ FIRST(α);
                                       if A ⇒* ε, also FIRST(β) ⊆ FIRST(α)
  • if every symbol of α derives ε  →  ε ∈ FIRST(α)

FOLLOW(A):
  • $ ∈ FOLLOW(S)                                     (S = start symbol)
  • for each rule  B → α A β:  FIRST(β)\{ε} ⊆ FOLLOW(A)
  • for each rule  B → α A β  with β ⇒* ε (or β empty):
                                      FOLLOW(B) ⊆ FOLLOW(A)
```

`FOLLOW` is needed only when the grammar has ε-productions: a nullable `A` can be
matched against the empty string, and the parser must know what may legitimately come
_after_ `A` to decide whether to take `A → ε`.

### Building the LL(1) parse table

The predictive parse table `M[A, a]` is indexed by nonterminal `A` and lookahead
terminal `a`. Its entry names the production to expand. Construction (Dragon Book §4.4
"Algorithm 4.31", Grune & Jacobs §8.2.1) — for each production `A → α`:

```text
for each terminal a ∈ FIRST(α):
    add  A → α  to  M[A, a]
if ε ∈ FIRST(α):
    for each terminal b ∈ FOLLOW(A):
        add  A → α  to  M[A, b]        # (and to M[A, $] if $ ∈ FOLLOW(A))
```

The table _is_ the parse, driven by an explicit pushdown stack: push `S$`; repeatedly,
if the stack top is a terminal, `match` it against the input; if it is a nonterminal
`A`, replace it with the right-hand side of `M[A, a]` for the current lookahead `a`;
an empty `M[A, a]` is a syntax error. [Grune & Jacobs][gj] describe the table-driven
loop and note that "the parser does not need the grammar any more" once `M` is built
(§8.1). The recursive-descent realization is the same logic with the stack implicit in
the call stack: the procedure for `A` does `switch (lookahead) { … }` over the same
`FIRST`/`FOLLOW` partition.

### The LL(1) condition

A grammar is **`LL(1)`** exactly when every cell of `M` holds at most one production —
i.e. table construction produces no conflict. Equivalently, for every nonterminal `A`
with productions `A → α | β`:

1. `FIRST(α)` and `FIRST(β)` are **disjoint** — the first token tells the two apart; and
2. at most one of `α`, `β` derives `ε`; and
3. if `β ⇒* ε`, then `FIRST(α)` is disjoint from `FOLLOW(A)` — a non-empty alternative
   never collides with the empty one.

A conflict (two productions in one cell) means the grammar is **not** `LL(1)`. Two
fixable causes of conflict are the structural restrictions covered next; an unfixable
one is genuine ambiguity (see [Ambiguity handling](#ambiguity-handling)).

### Structural restriction 1: no left recursion

A nonterminal `A` is **left-recursive** if `A ⇒+ A α` — it can derive a sentential form
starting with itself. A naive recursive-descent procedure for `A → A α | β` would call
`A()` as its very first action, with the input not advanced, and recurse forever; the
table-driven form loops because `A ∈ FIRST(A)`. [Grune & Jacobs][gj] flag it as the
fundamental barrier:

> "As left-recursion poses a major problem for any top-down parsing method, … "
> — Grune & Jacobs, §6.3.2

Left recursion comes in two forms — **immediate** (`A → A α`) and **indirect**
(`A → B α`, `B → A β`) — and a third, **hidden**, where a nullable prefix exposes it
(`A → B A`, `B → ε`, per the [ALL(\*) paper][allstar] footnote 2). The standard
transformation rewrites immediate left recursion into right recursion. For
`A → A α₁ | … | A αₙ | β₁ | … | βₘ` (no `αᵢ` or `βⱼ` equal to `ε`), Grune & Jacobs
§6.4 give:

```ebnf
A_head  → β1 | … | βm
A_tail  → α1 | … | αn
A_tails → A_tail A_tails | ε
A       → A_head A_tails
```

so `E → E '+' T | T` becomes `E → T E'`, `E' → '+' T E' | ε`. Indirect left recursion
is removed by first ordering the nonterminals `A₁ … Aₙ` and substituting forward, then
eliminating the immediate left recursion each substitution exposes (the algorithm in
Dragon Book §4.3). The transformation is **language-preserving but tree-distorting**:
the rewritten grammar accepts the same strings but yields a different (often
right-leaning) parse tree, and the natural left-associativity of `-`/`/` is lost unless
reconstructed by hand — which is exactly the pain that motivated
[Pratt/precedence parsing][pratt] and ANTLR 4's automatic left-recursion rewriting
(below).

### Structural restriction 2: left-factoring

Two alternatives that share a common prefix violate the disjoint-`FIRST` condition even
without recursion: `stmt → 'if' e 'then' s | 'if' e 'then' s 'else' s` has both
alternatives in `FIRST = {'if'}`, so one token of lookahead cannot choose. **Left
factoring** hoists the common prefix into a fresh nonterminal whose alternatives differ
at the decision point:

```ebnf
A → γ β1 | γ β2          ⇒        A  → γ A'
                                  A' → β1 | β2
```

`stmt` becomes `stmt → 'if' e 'then' s stmt'`, `stmt' → 'else' s | ε`. (The residual
dangling-else ambiguity is then resolved by convention — bind `else` to the nearest
`if` — exactly the kind of grammar-level disambiguation LL forces into the open.)

### The lookahead hierarchy: LL(k) and strong-LL

When one token is not enough but `k` are, the grammar is `LL(k)`: the parse table
becomes `M[A, x]` indexed by **`FIRST_k`** (the length-`k` prefixes derivable from each
alternative), and the disjointness condition is stated over `FIRST_k` sets. The formal
definition (Rosenkrantz & Stearns) is on _two leftmost derivations_: a grammar is
`LL(k)` iff whenever two leftmost derivations from `S` agree on the next nonterminal and
their next `k` input symbols agree, they must use the **same** production to expand that
nonterminal. The hierarchy is **strict** — Rosenkrantz & Stearns proved that for each
`k` there is an `LL(k+1)` language that is **not** `LL(k)`:

> "for each value of k there are LL(k+1) languages that are not LL(k) languages." —
> Rosenkrantz & Stearns 1970, summarized from the paper's results

There is a subtle but crucial split inside `LL(k)`:

| Variant            | Lookahead decision uses                                       | Power    | Who builds it                                                       |
| ------------------ | ------------------------------------------------------------- | -------- | ------------------------------------------------------------------- |
| **Strong-`LL(k)`** | only the next `k` tokens — independent of left context        | weaker   | The hand-written recursive-descent parser; a single table per `A`   |
| **Full-`LL(k)`**   | the next `k` tokens **and** the parse stack (which call site) | stronger | A context-aware decision — a different lookahead set per call stack |

The [ALL(\*) paper][allstar] is explicit that the parsers programmers write by hand are
in the weaker class:

> "Parsers that ignore the parser call stack for prediction are called Strong LL (SLL)
> parsers. The recursive-descent parsers programmers build by hand are in the SLL
> class. By convention, the literature refers to SLL as LL but we distinguish the terms
> since 'real' LL is needed to handle all grammars." — Parr, Harwell & Fisher 2014, §3.1

Its worked counterexample is `S → xB | yC`, `B → Aa`, `C → Aba`, `A → b | ε`: lookahead
`ba` must predict `A → b` when reached through `B` but `A → ε` when reached through `C`,
so no stack-_insensitive_ table can resolve it. The grammar is `LL(2)` but **not**
`SLL(k)` for any `k`; duplicating `A` per call site makes it `SLL(2)`. This SLL/full-LL
distinction is the same one that resurfaces, optimized, inside `ALL(*)` (below).

### The wall: fixed-k is not enough

Many real constructs need lookahead that is **not bounded by any constant `k`** — the
distinguishing token can be arbitrarily far away. The [LL(\*) paper][llstar]'s opening
example is a C-style declaration grammar where alternatives 3 and 4 differ only after
an unbounded run of `unsigned`:

```text
s : ID                       // 1: a label
  | ID '=' expr              // 2: an assignment
  | 'unsigned'* 'int' ID     // 3: int decl
  | 'unsigned'* ID  ID       // 4: user-type decl
  ;
```

No fixed `k` distinguishes 3 from 4, because the deciding token (`int` vs `ID`) follows
a `*`-loop of `unsigned`. **`LL(*)`** answers this by replacing the fixed-`k` lookahead
window with a **cyclic DFA** — a regular language over the remaining input:

> "The key idea behind LL(\*) parsers is to use regular-expressions rather than a fixed
> constant or backtracking with a full parser to do lookahead. The analysis constructs
> a deterministic finite automata (DFA) for each nonterminal in the grammar to
> distinguish between alternative productions." — Parr & Fisher 2011 (LL(\*)), §1

The DFA can loop (matching `unsigned*`) and uses the **minimum** lookahead per input
sequence, so `LL(*)` "parsers gracefully throttle up from conventional fixed `k ≥ 1`
lookahead to arbitrary lookahead and, finally, fail over to backtracking depending on
the complexity of the parsing decision" ([LL(\*)][llstar], §1). But `LL(*)` has a fatal
flaw, named in the [ALL(\*) paper][allstar]: the lookahead language of a recursive rule
is usually **context-free, not regular**, so the static analysis "sometimes fails to
find regular expressions that distinguish between alternative productions," and the
grammar condition is **statically undecidable** (§1). ANTLR 3 detected the danger and
fell back to backtracking, inheriting the `a | ab` ordered-choice quirk of [PEGs][peg].

### ALL(\*): move the analysis to parse time

`ALL(*)` ("Adaptive LL(\*)", the ANTLR 4 strategy) keeps the recursive-descent skeleton
but resolves each decision with a parse-time, GLR-like simulation instead of a
statically-built table. The headline claim from the [abstract][allstar]:

> "The critical innovation is to move grammar analysis to parse-time, which lets ALL(\*)
> handle any non-left-recursive context-free grammar. ALL(\*) is O(n⁴) in theory but
> consistently performs linearly on grammars used in practice, outperforming general
> strategies such as GLL and GLR by orders of magnitude." — Parr, Harwell & Fisher
> 2014, Abstract

Because the analysis sees only the **finite** set of input sequences actually
encountered, it sidesteps the undecidability of static `LL(*)`:

> "While static analysis must consider all possible input sequences, dynamic analysis
> need only consider the finite collection of input sequences actually seen." — §1.1

The machinery, in brief (the full account is in [the ANTLR deep-dive][antlr]):

- The grammar is represented as an **augmented transition network (`ATN`)** — a set of
  state machines, one per rule, that "closely mirror grammar structure … look just like
  syntax diagrams" (§3). Nonterminal edges are calls that push a return state onto a
  state call stack.
- Each decision point calls `adaptivePredict`, which "takes a nonterminal and parser
  call stack as parameters and returns the predicted production number" (§3). It
  launches one **subparser per alternative**; they "operate in pseudo-parallel," advance
  "in lockstep," and "die off as their paths fail to match the remaining input" until a
  **sole survivor** uniquely predicts a production at minimum lookahead depth (§1.1).
- Results are **memoized** as a per-decision **lookahead DFA** mapping seen lookahead
  phrases to production numbers, so "the parser can make future predictions at the same
  parser decision and lookahead phrase quickly by consulting the cache" (§1.1). This
  caching is "critical to performance" (§3).
- To keep the pseudo-parallel subparsers from going exponential, prediction shares a
  **graph-structured stack (`GSS`)**; the difference from GLR is that "ALL(\*) only
  predicts productions with such subparsers whereas GLR actually parses with them," so
  ALL(\*) "does not push terminals onto the GSS" (§1.1).

`ALL(*)` reuses the SLL/full-LL split as a performance optimization: **two-stage
parsing** tries the whole input in fast stack-insensitive **SLL** mode first, and only
re-parses in full stack-sensitive **LL** mode if SLL reports an error (Theorem 6.5
guarantees this is safe — "SLL either behaves like LL or gets a syntax error"). On a
123 MB Java corpus, two-stage parsing is "8x faster than one-stage optimized LL mode"
(§3.2).

### Power & limits

The grammar/language classes form a strict tower for fixed `k`, widening to the full
non-left-recursive CFG with adaptive lookahead:

| Class            | Grammar restriction                                                           | Decidable membership?           |
| ---------------- | ----------------------------------------------------------------------------- | ------------------------------- |
| `LL(1)`          | disjoint `FIRST` (and `FIRST`/`FOLLOW`) per alternative; no left recursion    | yes — table construction        |
| `LL(k)`, fixed k | disjoint `FIRST_k`; strict: `LL(k) ⊊ LL(k+1)` ([Rosenkrantz & Stearns][rs70]) | yes — Rosenkrantz–Stearns test  |
| strong-`LL(k)`   | decision stack-insensitive (⊆ full-`LL(k)`); what hand-written RD gives       | yes                             |
| `LL(*)`          | per-decision lookahead language is **regular**                                | **no** — statically undecidable |
| `ALL(*)`         | **any non-left-recursive CFG**                                                | n/a — analysis is at parse time |

The hard ceiling that no amount of LL cleverness lifts is **left recursion** (must be
removed by transformation) and, for the deterministic fixed-`k` variants, **any
language that is inherently non-`LL(k)`**. Crucially, `LL` is strictly weaker than `LR`
in the fixed-`k` regime: every `LL(k)` grammar is `LR(k)`, but not conversely
(e.g. grammars needing the suffix already parsed to choose a production are natural for
[`LR`][bottom-up] and impossible for fixed-`k` `LL`). This is the historical reason
top-down was considered the junior partner — see [Where it shows up](#where-it-shows-up-in-practice).

### Ambiguity handling

LL parsing **does not handle ambiguity** — an `LL(k)` grammar must be unambiguous, and a
genuine ambiguity manifests as a table conflict that no `FIRST`/`FOLLOW` refinement or
left-factoring can remove. This is usually framed as a feature for programming
languages, where "ambiguity is almost always an error" ([ALL(\*)][allstar], §1): the LL
discipline surfaces the ambiguity at grammar-construction time rather than producing a
parse forest at runtime (the [GLR/GLL/Earley][general] behaviour).

Where an ambiguity is _intentional_ (the dangling `else`), top-down parsers resolve it
by **ordering**. ANTLR's `ALL(*)` makes this explicit and deterministic: when multiple
subparsers survive, "the predictor announces an ambiguity and resolves it in favor of
the lowest production number associated with a surviving subparser" (§1.1) — productions
are numbered to express precedence, the same first-match rule [PEGs][peg] and Bison use.
**Semantic predicates** `{…}?` add a context-sensitive escape hatch: a side-effect-free
boolean that "render[s] the surrounding production nonviable, dynamically altering the
language generated by the grammar at parse-time" (§2), letting one grammar disambiguate
e.g. type names from identifiers in C.

### Error detection & recovery

Top-down parsing has the **viable-prefix / valid-prefix property**: it reports an error
at the first token that cannot continue any valid parse, so the error location is
precise and intuitive — the parser was, by construction, "expecting" a specific token
set. Detection is immediate: an empty parse-table cell `M[A, a]` (or a recursive-descent
procedure with no matching alternative and no matching token).

Recovery is classically **panic-mode synchronization**: on an error, skip input tokens
until one in a **synchronizing set** appears, then pop the stack to a state that can
consume it. The Dragon Book (§4.4) populates the table with `synch` markers drawn from
`FOLLOW(A)`: skip input until a token in `FOLLOW(A)` is seen, then pop `A` and resume.
Generated recursive-descent parsers do the same structurally — ANTLR wraps every rule
method in a `try/catch/finally` and calls a pluggable recovery strategy. From the ANTLR
[parser-rules documentation][antlr-parser-rules]:

> "When a syntax error occurs within a rule, ANTLR catches the exception, reports the
> error, attempts to recover (possibly by consuming more tokens), and then returns from
> the rule." — ANTLR 4 `parser-rules.md`

ANTLR's default strategy refines panic-mode with **single-token deletion/insertion**
(repair an isolated typo without resynchronizing) and `FOLLOW`-set-based resync for the
rest — a direct descendant of the Dragon Book technique. Recovery quality is one of
top-down parsing's enduring practical advantages: because the parser knows its
_expected_ set at every point, its diagnostics ("expected `;`") are more actionable than
an [LR][bottom-up] parser's state-number-based ones, and recovery is local.

### Performance & complexity

Deterministic fixed-`k` LL is **linear time**, `O(n)` for input length `n`: each token
is matched once and each prediction is a single table lookup or `switch`. Space is
`O(d)` for the explicit (or call-) stack, where `d` is the maximum nesting depth — not
`O(n)` — because the stack holds the unfinished sentential form, not the whole input.
This is the same `O(n)` ceiling as a deterministic [`LR`][bottom-up] parser, with a
smaller constant for the recursive-descent form (no driver loop, branch-predictable
calls), which is why hand-written RD front-ends remain competitive with generated LR.

Adaptive lookahead trades this guarantee for generality. `ALL(*)` is, by Theorem 6.3,
**`O(n⁴)`** in the worst case:

> "ALL(\*) parsing of n symbols has O(n⁴) time." — Parr, Harwell & Fisher 2014,
> Theorem 6.3

— "because in the worst-case, the parser must make a prediction at each input symbol and
each prediction must examine the entire remaining input; examining an input symbol can
cost `O(n²)`" (§6). The DFA cache and `GSS` (which has `O(n)` nodes, Theorem 6.4) make
this almost never bite: empirically ANTLR 4's `ALL(*)` parses a 12,920-file, 123 MB Java
corpus "only about 20% slower than the handbuilt parser in the Java compiler itself,"
~4.4× faster than the fastest GLR tool tested, and ~135× faster than the GLL tool (§7.1).

### Where it shows up in practice

| Tool / library                    | Top-down mechanism                                                                 | Deep-dive                     |
| --------------------------------- | ---------------------------------------------------------------------------------- | ----------------------------- |
| **ANTLR 4**                       | `ALL(*)` adaptive recursive descent; `ATN` + `adaptivePredict` + lookahead DFA     | [antlr.md][antlr]             |
| **Parsec / megaparsec** (Haskell) | Monadic combinators; `LL(1)`-style by default (no backtrack past consumed input)   | [haskell-parsec.md][parsec]   |
| **nom** (Rust)                    | Function/combinator recursive descent over byte/`&str` input                       | [rust-nom.md][nom]            |
| **chumsky** (Rust)                | Combinator recursive descent with first-class error recovery                       | [rust-chumsky.md][chumsky]    |
| **pest** (Rust)                   | PEG (ordered-choice top-down with backtracking); see the [PEG/packrat][peg] family | [pest.md][pest]               |
| **tree-sitter**                   | GLR (bottom-up) — included here as the _contrast_: incremental, generalized        | [tree-sitter.md][tree-sitter] |
| Hand-written recursive descent    | GCC/Clang C++ front-ends, `javac`, many production compilers                       | (this page)                   |

The LL/recursive-descent half of this catalog is the [ANTLR][antlr] and combinator
([Parsec][parsec], [nom][nom], [chumsky][chumsky]) deep-dives; the ordered-choice PEG
cousins ([pest][pest]) are in [PEG & packrat parsing][peg]; expression-focused top-down
is [Pratt/precedence parsing][pratt]; the generalized parsers that handle the grammars
LL cannot ([Earley/GLR/GLL][general], including [tree-sitter][tree-sitter]) and the
[bottom-up LR/LALR][bottom-up] generators ([Bison][bison], [Menhir][menhir]) are the
contrast cases. The capstone [comparison][comparison] places them all on one axis.

---

## Strengths

- **Intuitive and debuggable.** The generated (or hand-written) code mirrors the grammar
  rule-for-rule; a parser stack trace is a partial parse tree. This is the single
  biggest reason top-down parsing dominates teaching and hand-written front-ends.
- **No tooling required.** Recursive descent needs no parser generator — just a function
  per rule. This makes it the default for compilers that want full control of error
  messages and recovery (GCC, Clang, `javac`).
- **Excellent error messages and local recovery.** The valid-prefix property pinpoints
  the failing token, and the parser's _expected set_ at each point yields actionable
  diagnostics; panic-mode `FOLLOW`-set resync recovers locally.
- **Linear time, small constant (fixed-k).** `O(n)` time / `O(d)` stack with a table
  lookup or `switch` per decision; competitive with or faster than generated LR.
- **Composable.** Top-down decisions compose: combinator libraries turn parsers into
  first-class values, and `ALL(*)` languages are closed under union (Theorem 6.2),
  enabling grammar import/modularity.
- **`ALL(*)` removes the historical weakness.** ANTLR 4 accepts "any non-left-recursive
  context-free grammar," eliminating fixed-`k` contortions while staying top-down and
  generating readable recursive-descent code.

## Weaknesses

- **No left recursion.** The defining structural restriction; left-recursive rules must
  be transformed to right recursion, distorting the parse tree and breaking natural
  left-associativity (motivating [Pratt parsing][pratt] and ANTLR's auto-rewrite).
- **Left-factoring burden (fixed-k).** Alternatives with common prefixes must be hand-
  factored to satisfy disjoint-`FIRST`, obscuring the grammar.
- **Strictly weaker than LR in the fixed-k regime.** Every `LL(k)` grammar is `LR(k)` but
  not vice versa; constructs that need the right context already parsed are out of reach
  for fixed-`k` LL — the classic argument that bottom-up is "more powerful."
- **No ambiguity handling.** An LL grammar must be unambiguous; intentional ambiguity is
  resolved only by ordering or semantic predicates, never by producing a forest
  ([unlike GLR/GLL/Earley][general]).
- **Strong-LL vs full-LL gap.** Hand-written recursive descent is only `SLL`; some
  `LL(k)` grammars need stack-sensitive (full-LL) decisions a naive RD parser cannot make.
- **`ALL(*)` is `O(n⁴)` worst case** and pushes the burden of finding ambiguities onto
  test coverage, since "the LL(\*) grammar condition is statically undecidable" and
  `ALL(*)` defers analysis to parse time.

## Key design decisions and trade-offs

| Decision                                                          | Rationale                                                                                                       | Trade-off                                                                                                  |
| ----------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| Build the tree top-down, leftmost derivation                      | One function per rule; code mirrors grammar; trivially debuggable and hand-writable                             | Cannot decide a production from the right context already parsed — strictly weaker than [`LR`][bottom-up]  |
| Predict from `k` tokens of lookahead (fixed `k`)                  | Deterministic, linear-time, `O(d)` stack; a single table or `switch` per decision                               | Strict, undecidable-to-place hierarchy `LL(k) ⊊ LL(k+1)`; many constructs need unbounded lookahead         |
| Forbid left recursion; require left-factoring                     | Guarantees the `predict` step terminates and one token (or `k`) chooses an alternative                          | Grammar must be transformed; parse tree distorted; left-associativity lost without manual repair           |
| Strong-LL (stack-insensitive) decisions in hand-written RD        | One lookahead table per nonterminal; fast, simple, no per-call-site state                                       | Weaker than full-LL; some `LL(k)` grammars need stack-sensitive prediction (`SLL ⊊ LL`)                    |
| `LL(*)`: regular (cyclic-DFA) lookahead instead of fixed `k`      | Handles unbounded lookahead (`unsigned* int` vs `unsigned* ID`) while staying mostly deterministic              | Lookahead languages are often context-free, not regular → condition **statically undecidable**, backtracks |
| `ALL(*)`: move grammar analysis to **parse time**                 | Handles any non-left-recursive CFG; only the finite seen inputs are analyzed; DFA-cached and linear in practice | `O(n⁴)` worst case; ambiguity detection becomes a test-coverage problem, not a static guarantee            |
| Two-stage SLL-then-LL parsing (`ALL(*)`)                          | Most decisions are SLL; SLL-only is much faster and provably falls back safely (Theorem 6.5)                    | Pathological inputs are parsed (and re-parsed) twice; correctness leans on the two-stage theorem           |
| Resolve surviving-subparser conflicts by lowest production number | Deterministic, PEG/Bison-like; intentional ambiguity (dangling `else`) handled by rule order                    | Silently masks _unintended_ ambiguities unless the grammar author tests the conflicting input              |
| Panic-mode `FOLLOW`/sync-set recovery (+ single-token repair)     | Precise error location from the valid-prefix property; local, cheap resynchronization                           | Can skip large input regions; cascading spurious errors past a poorly-chosen sync point                    |

---

## Sources

- P. M. Lewis II & R. E. Stearns, ["Syntax-Directed Transduction"][lewis-stearns],
  _Journal of the ACM_ 15(3):465–488, 1968 — the paper that defined `LL(k)` grammars.
- D. J. Rosenkrantz & R. E. Stearns, ["Properties of Deterministic Top-Down
  Grammars"][rs70], _Information and Control_ 17(3):226–256, 1970 — `LL(k)` decision
  procedure, ε-rule elimination, decidable equivalence, and the strict `LL(k) ⊊ LL(k+1)`
  hierarchy.
- T. Parr, S. Harwell & K. Fisher, ["Adaptive LL(\*) Parsing: The Power of Dynamic
  Analysis"][allstar], OOPSLA 2014 — `ALL(*)`, the `ATN` / `adaptivePredict` / lookahead-
  DFA machinery, the `SLL`/full-LL distinction, two-stage parsing, complexity (`O(n⁴)`),
  and empirical results. (Tech-report PDF; quotes verified against a `pdftotext -layout`
  extraction.)
- T. Parr & K. Fisher, ["LL(\*): The Foundation of the ANTLR Parser Generator"][llstar],
  PLDI 2011 — `LL(*)` regular (cyclic-DFA) lookahead and the static-undecidability
  limitation.
- A. Aho, M. Lam, R. Sethi & J. Ullman, _Compilers: Principles, Techniques, and Tools_
  (the [Dragon Book][dragon]), §4.4 "Top-Down Parsing" — `FIRST`/`FOLLOW`, the `LL(1)`
  table-construction algorithm, and panic-mode error recovery.
- D. Grune & C. J. H. Jacobs, [_Parsing Techniques: A Practical Guide_][gj], 2nd ed.,
  ch. 6 "General Directional Top-Down" and ch. 8 "Deterministic Top-Down" — predict/match
  model, recursive-descent correspondence, left-recursion elimination, parse tables.
- [ANTLR 4 `parser-rules.md`][antlr-parser-rules] — generated recursive-descent error
  recovery (`try/catch`, `_errHandler.recover`).
- Related deep-dives: [ANTLR][antlr] · [Parsec][parsec] · [nom][nom] · [chumsky][chumsky]
  · [pest][pest] · [PEG & packrat][peg] · [Pratt/precedence][pratt] ·
  [bottom-up LR][bottom-up] · [general parsing][general] · [Bison][bison] ·
  [Menhir][menhir] · [tree-sitter][tree-sitter] · [comparison][comparison].

<!-- References -->

<!-- Same-tree theory siblings -->

[theory-index]: ./index.md
[bottom-up]: ./bottom-up.md
[general]: ./general-parsing.md
[peg]: ./peg-packrat.md
[pratt]: ./pratt-precedence.md

<!-- Tree umbrella / concepts / comparison -->

[concepts]: ../concepts.md
[comparison]: ../comparison.md

<!-- Library deep-dives -->

[antlr]: ../antlr.md
[parsec]: ../haskell-parsec.md
[nom]: ../rust-nom.md
[chumsky]: ../rust-chumsky.md
[pest]: ../pest.md
[bison]: ../bison-yacc.md
[menhir]: ../menhir.md
[tree-sitter]: ../tree-sitter.md

<!-- External primary sources -->

[lewis-stearns]: https://dl.acm.org/doi/10.1145/321466.321477
[rs70]: https://www.sciencedirect.com/science/article/pii/S0019995870904468
[allstar]: https://www.antlr.org/papers/allstar-techreport.pdf
[llstar]: https://www.antlr.org/papers/LL-star-PLDI11.pdf
[dragon]: https://web.archive.org/web/20260610070726/https://suif.stanford.edu/dragonbook/
[gj]: https://dickgrune.com/Books/PTAPG_2nd_Edition/
[antlr-parser-rules]: https://github.com/antlr/antlr4/blob/master/doc/parser-rules.md
