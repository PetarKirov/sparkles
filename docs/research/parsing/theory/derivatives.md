# Parsing with Derivatives

A family of parsing algorithms built on **one operation** — the _derivative_ of a language
with respect to an input symbol — applied repeatedly, symbol by symbol, until the input is
consumed. [Brzozowski's 1964 derivative][brz] turns a regular expression directly into a
deterministic automaton; [Might, Darais & Spiewak's 2011 extension][pwd] lifts the very same
operation to **arbitrary context-free grammars**, yielding a parser that is a few dozen lines
of pure functional code yet handles ambiguity, left recursion, and every other CFG pathology
with no grammar massaging. It is the most _compositional_ point in the [parsing design
space][formal]: a parser is a value, the derivative is a function on values, and parsing is
`foldl derivative`.

> [!NOTE]
> This page spans two layers that share one idea. **Brzozowski/Owens/Antimirov derivatives**
> operate on _regular_ expressions and build lexers / DFAs — the lower half. **Parsing with
> derivatives (PWD)** operates on _context-free_ grammars and builds full parse forests — the
> upper half, and the reason this technique sits in the general-parsing neighbourhood next to
> [Earley, CYK, and GLL][general]. Where derivatives compete with [PEG/packrat][peg] (both are
> "the parser _is_ a recursive value, parsing walks it") the contrast is drawn in
> [Ambiguity handling](#ambiguity-handling) and [Where it shows up in practice](#where-it-shows-up-in-practice).

---

## At a glance

| Dimension               | Parsing with derivatives                                                                                                                                                                               |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Core operation          | The **derivative** `Dᵤ(L) = { w : uw ∈ L }` — "strip a leading `u` from every string of `L`"; computed recursively over the grammar with [smart constructors](#how-it-works)                           |
| Grammar class (regex)   | All **regular** languages, _plus_ Boolean closure (intersection `&`, complement `¬`) almost for free — [Owens, Reppy & Turon 2009][owens]                                                              |
| Grammar class (CFG)     | **Every** context-free grammar — ambiguous, left-recursive, right-recursive, cyclic — no normal form required ([PWD][pwd])                                                                             |
| Output                  | A recogniser (regex DFA / nullability test) or a full **parse forest** (PWD), shared via memoised graph nodes                                                                                          |
| Memory model            | No tables, charts, or item sets: the _grammar itself_ is the state, mutated in place into successive derivatives; a memo table ties recursive knots                                                    |
| Worst-case time (regex) | DFA constructed in finitely many steps — [Brzozowski's finite-derivatives theorem][brz] guarantees termination                                                                                         |
| Worst-case time (CFG)   | `O(G·n³)` (cubic), proven by [Adams, Hollenbeck & Might 2016][adams] — _not_ exponential; `O(n·G)` in practice with [compaction](#compaction-taming-the-blowup)                                        |
| Worst-case space (CFG)  | `O(G·n³)` grammar nodes constructed without compaction; near-constant residual grammar size _with_ compaction                                                                                          |
| Canonical algorithms    | [Brzozowski 1964][brz] (regex→DFA); [Antimirov 1996][anti] (partial derivatives → NFA); [Owens et al. 2009][owens] (lexers, Unicode); [PWD 2011][pwd] (CFGs); [Adams et al. 2016][adams] (cubic, fast) |
| Representative tools    | [`ml-ulex`][mlulex] / SML/NJ lexer generator (Owens); [`derp`/`derp-3`][derp3] (Racket); [`re2c`][re2c]-style derivative lexers; instaparse (GLL, derivative-adjacent); Rust/Scala/Haskell PWD ports   |

The deterministic alternatives — where the grammar permits — are [LL / recursive descent][top-down],
[LR / LALR][bottom-up], [PEG / packrat][peg], and [Pratt][pratt]; the general-CFG peers are
[Earley, CYK, and GLL][general]. The [comparison capstone][comparison] places derivatives
against all of them.

---

## Overview / motivation

### The core idea: one operation, applied n times

Every parsing method needs a way to ask "given what I've matched so far, what can come next?"
Most answer with auxiliary machinery — `FIRST`/`FOLLOW` sets and a [predictive table][top-down],
an [LR automaton and viable-prefix DFA][bottom-up], an [Earley chart of dotted items][general].
Derivative-based parsing answers with a single, self-similar operation. The **derivative** of a
language `L` with respect to a symbol `c` is the language of _suffixes_ obtained by stripping a
leading `c` — Brzozowski's [Definition 3.1][brz]:

> "Given a set `R` of sequences and a finite sequence `s`, the derivative of `R` with respect
> to `s` is denoted by `D_s R` and is `D_s R = {t | st ∈ R}`." — Brzozowski, _Derivatives of
> Regular Expressions_, Definition 3.1 (JACM 1964)

[PWD][pwd] gives the same definition in the parser's idiom:

> "the derivative of a language `L` with respect to a character `c` is a new language that has
> been 'filtered' and 'chopped' … First, retain only the strings that start with the character
> `c`. Second, chop that first character off every string." — Might, Darais & Spiewak, §3

To recognise a string `c₁c₂…cₙ`, take the derivative with respect to `c₁`, then with respect to
`c₂`, and so on; when the input is exhausted, ask whether the residual language contains the
empty string `ε` (the **nullability** test — see [concepts: nullable][concepts]). Brzozowski's
[Theorem 4.2][brz] is the whole
recogniser: "A sequence `s` is contained in a regular expression `R` if and only if `λ` is
contained in `D_s R`." Membership of `λ` (the empty word) is decided by the **characteristic
function** `δ` ([Definition 3.2][brz]): `δ(R) = λ` if `R` contains the empty word, `δ(R) = ∅`
otherwise. That is the entire algorithm: `recognises(L, w) = δ(foldl D L w)`.

### Why this is appealing

The pitch — made in [PWD's][pwd] abstract — is that the equational theory transliterates almost
verbatim into pure code:

> "The derivative of regular expressions, if gently tempered with laziness, memoization and
> fixed points, acts immediately as a pure, functional technique for generating parse forests
> from arbitrary context-free grammars. Despite—even because of—its simplicity, the derivative
> transparently handles ambiguity, left-recursion, right-recursion, ill-founded recursion or
> any combination thereof." — Might, Darais & Spiewak, _Parsing with Derivatives_, abstract

There is **no parser-generation phase** and **no forbidden grammar**. As [Adams et al.][adams]
summarise the appeal: it "handles arbitrary context-free grammars while being both easy to
understand and simple to implement … It transparently handles language ambiguity and recursion
and is easy to implement and understand." The reference Racket implementation is, in
[Might's][mightblog] words, able to be "generating parse forests for _any_ CFG—left recursive,
right recursive or even infinitely recursive" in "a couple hundred lines of code". For the
regular-language layer, [Owens, Reppy & Turon][owens] make the parallel case for lexers:

> "Regular-expression derivatives are an old, but elegant, technique for compiling regular
> expressions to deterministic finite-state machines … it easily supports extending the
> regular-expression operators with boolean operations, such as intersection and complement."
> — Owens, Reppy & Turon, _Regular-expression derivatives reexamined_, abstract

### Why it was forgotten, then revived

Brzozowski published derivatives in 1964, three years before [Younger's CYK][general] and six
before [Earley][general]; yet the technique vanished. Owens et al. open with the lament:

> "Unfortunately, RE derivatives have been lost in the sands of time, and few computer
> scientists are aware of them. A quick survey of several standard compiler texts does not turn
> up any description of them." — Owens, Reppy & Turon, §1 (and footnote 1)

[Thompson's 1968 NFA construction][owens] and the [McNaughton–Yamada / Dragon-book][owens]
marked-symbol algorithm became the textbook path from regex to automaton, and derivatives were
relegated to an exercise in Aho & Ullman's _Theory of Parsing_. The 2000s revival came in two
waves: Owens, Reppy & Turon (2009) rebuilt **lexer generators** ([`ml-ulex`][mlulex]) on
derivatives and solved the Unicode-alphabet problem; Might, Darais & Spiewak (2011) lifted the
operation to **context-free** grammars. Adams, Hollenbeck & Might (2016) then closed the
performance question that had dogged the 2011 work.

---

## How it works

### The regular-expression derivative (Brzozowski)

Derivatives are defined by structural recursion over the regex syntax. The two ingredients are
the **nullability** function `δ`/`ν` and the **derivative** recurrence `Dᵤ`. Owens et al. state
the nullability helper `ν(r)` — `ε` if `r` is nullable, `∅` otherwise — by cases:

```text
ν(ε)     = ε              ν(∅)     = ∅
ν(a)     = ∅              ν(r·s)   = ν(r) & ν(s)
ν(r*)    = ε              ν(r + s) = ν(r) + ν(s)
ν(r & s) = ν(r) & ν(s)    ν(¬r)    = ε if ν(r)=∅ else ∅
```

and then the derivative `∂ₐ` (Brzozowski's rules, Owens §3.1):

```text
∂ₐ ε      = ∅
∂ₐ a      = ε
∂ₐ b      = ∅                       (b ≠ a)
∂ₐ ∅      = ∅
∂ₐ (r·s)  = ∂ₐr · s  +  ν(r) · ∂ₐs      ← the pivotal rule
∂ₐ (r*)   = ∂ₐr · r*
∂ₐ (r + s) = ∂ₐr + ∂ₐs
∂ₐ (r & s) = ∂ₐr & ∂ₐs                  ← Boolean ops, almost free
∂ₐ (¬r)   = ¬(∂ₐr)
```

The **concatenation rule** is where all the subtlety lives, and it is identical in every
incarnation of derivatives below. To differentiate `r·s` you differentiate `r` and keep `s` —
_unless_ `r` can match the empty string, in which case the symbol might have been consumed by
`s`, so you must _also_ differentiate `s`. The `ν(r)` factor is exactly the guard "is `r`
nullable?": if not, `ν(r) = ∅` annihilates the second term; if so, `ν(r) = ε` lets it through.
Brzozowski wrote this in 1964 as `Dₐ(PQ) = (DₐP)Q + δ(P)DₐQ` ([Theorem 3.1][brz]).

> [!IMPORTANT]
> The Boolean rows (`∂ₐ(r & s)`, `∂ₐ(¬r)`) are the reason derivatives beat [Thompson's
> NFA construction][owens] for extended regex. Intersection and complement are not closed
> under the marked-symbol/NFA construction, but the derivative of `r & s` is just
> `∂ₐr & ∂ₐs`, and `∂ₐ(¬r) = ¬(∂ₐr)`. Owens et al. note their lexer language gets "extended
> REs almost for free", with the closure `Σ* \ L[[r]]` defined directly.

### From derivative to DFA

To build a recogniser, you do not recompute derivatives per input; you precompute, for every
symbol, the derivative of each residual regex, and the residuals become **DFA states**. Owens
et al. give the construction (their Fig. 1): states are regex equivalence classes, the
transition function is `δ(q, [a]) = [∂ₐ(q)]`, accepting states are the **nullable** ones, and
the error state is `∅`. The fixed point of "differentiate by every symbol, add new residuals as
new states" is the DFA. Their worked example for `a·b + a·c`:

```text
q0 = ab + ac
∂ₐ q0 = b + c                  → q1   (new)
∂ₐ q1 = ∅                      → q2   (the dead state)
∂_b q1 = (ε + ∅) ≡ ε           → q3   (new; ν(q3)=ε so q3 is accepting)
∂_b q0 = ∂_c q0 = ∅            → q2
```

This terminates because of Brzozowski's central result — the engine of the whole technique:

> "Every regular expression `R` has a finite number `d_R` of types of derivatives." —
> Brzozowski, Theorem 4.3(a) (JACM 1964)

"Types" means _up to language equivalence_. A regex has only finitely many _distinct_
residual languages, so the DFA has finitely many states (and is minimal when equivalence is
tested exactly — the [Myhill–Nerode][formal] connection).

### Similarity: keeping the state set finite in practice

Theorem 4.3 is about languages; an _implementation_ compares **syntax**, and syntactically the
derivative of `r·s` keeps growing. Brzozowski's fix is **similarity**: quotient the residuals by
a cheap set of syntactic identities so two residuals that are obviously the same regex are
recognised as the same state. Owens et al. make this the crux of practical construction. The
similarity relation `≈` is the congruence generated by associativity, commutativity, and
idempotence (**ACI**) of `+`/`&`, plus identity/annihilator laws:

```text
r + r ≈ r          r & r ≈ r          (r*)* ≈ r*
r + s ≈ s + r      r & s ≈ s & r      ε* ≈ ε
∅ + r ≈ r          ∅ & r ≈ ∅          ∅·r ≈ ∅
…(r+s)+t ≈ r+(s+t)  ε·r ≈ r           ¬(¬r) ≈ r
```

> "Brzozowski proved that a notion of RE similarity including only the [associativity, commutativity, idempotence] rules … is enough to ensure that every RE has only a finite number of dissimilar derivatives. Hence, DFA construction is guaranteed to terminate if we use similarity as an approximation for equivalence." — Owens, Reppy & Turon, §4.1

In Owens et al.'s implementation the laws are enforced by **smart constructors** that build a
canonical form, so structural equality decides similarity:

> "we maintain the invariant that all REs are in `≈`-canonical form and use structural equality
> to identify equivalent REs … Each RE operator has an associated smart-constructor function
> that checks its arguments for the applicability of the `≈` equations." — Owens et al., §4.1

This smart-constructor discipline reappears, unchanged, as the **compaction** of [PWD](#compaction-taming-the-blowup).

### Derivative classes: surviving Unicode

Brzozowski's Fig.-1 DFA construction iterates over every symbol of `Σ`. For ASCII that is fine;
for **Unicode** (1.1M code points) it is fatal. Owens et al.'s practical contribution is
**derivative classes**: partition `Σ` into the equivalence classes `a ≃ᵣ b ⟺ ∂ₐr ≡ ∂_b r`, so
that one derivative is computed _per class_, not per symbol.

> "Let `S₁, …, Sₙ` be a partition of `Σ` such that whenever `a, b ∈ Sᵢ`, we have
> `δ(q, a) = δ(q, b)` … we would only need to calculate one derivative per `Sᵢ` when computing
> the transitions from `q`." — Owens et al., §4.2

A structural-recursion function `C : RE → 2^(2^Σ)` over-approximates these classes, and Lemma
4.1 shows the classes compose through every operator. Empirically the approximation is nearly
exact and the payoff is large: "If we assume the 7-bit ASCII character set … our algorithm
computes only 2–4% of the possible derivatives" (Owens et al., §5). This is what makes a
derivative-based lexer like [`ml-ulex`][mlulex] competitive with table-driven generators.

### Antimirov's partial derivatives: an NFA, no normalization

Brzozowski derivatives need the ACI normalization to stay finite, and they build a _DFA_.
[Valentin Antimirov's 1996][anti] **partial derivatives** take a different tack: the derivative
of `r` with respect to `a` is a **set** of regexes, whose _union_ is Brzozowski's derivative.
Each element is a state of a small **NFA**, and the finiteness is structural, not up-to-ACI:

> "the number of syntactically distinct partial derivatives of `e` is provably linear in the
> size of `e` … the obtained [automaton] is, in general non-deterministic." — _On the Space
> Complexity of Partial Derivatives_ (2025), §1, summarising Antimirov 1996

Because the count of distinct partial derivatives is **linear in `|r|`**, "after a single
partial derivative is generated at each rewriting step, there is no need to simplify it in order
to keep the size of partial derivatives bounded" (ibid., §3) — Antimirov sidesteps the
similarity machinery entirely at the cost of nondeterminism. This is the derivative analogue of
the DFA↔NFA trade: Brzozowski gives a minimal **DFA** after normalization; Antimirov gives a
linear-size **NFA** with none.

### Lifting to context-free grammars (PWD)

The leap of [Might, Darais & Spiewak][pwd] is the observation in their abstract: "If we consider
context-free grammars as recursive regular expressions, Brzozowski's equational theory extends
without modification." A CFG is just a regular expression whose alternation/concatenation nodes
may **refer back to themselves** — a cyclic graph rather than a tree. The grammar-node algebra
(from the reference Racket [`dparse.rkt`][dparse]) is exactly the regex algebra plus a
**reduction** node that attaches a semantic action:

```racket
; dparse.rkt — the grammar-node structs
(define-struct (empty language) ())            ; ∅   — the empty language
(define-struct (eps   language) ())            ; ε   — the null/empty-string language
(define-struct (token language) (pred class))  ; c   — a terminal
(define-struct (union         compound-language) (this that))  ; L₁ ∪ L₂
(define-struct (concatenation compound-language) (left right)) ; L₁ ◦ L₂
(define-struct (reduction     compound-language) (lang reduce)); L → f  (semantic action)
(define-struct (eps* eps) (tree-set))          ; ε that carries a *set of parse trees*
```

The `reduction` node (`L ↪ f` in [Adams et al.][adams]) is what turns a _recogniser_ into a
_parser_: it carries a function `f` applied to the sub-parse, and `eps*` is the parser-world
analogue of `ε` — a null parser that yields a finite set of accumulated parse trees. The
nullability function carries over verbatim:

```racket
; dparse.rkt — nullability as a least fixed point over the boolean lattice
(define/fix (nullable? l)
  #:bottom #f
  (match l
    [(empty)      #f]
    [(eps)        #t]
    [(token _ _)  #f]
    [(orp  l1 l2) (or  (nullable? l1) (nullable? l2))]
    [(seqp l1 l2) (and (nullable? l1) (nullable? l2))]
    [(redp l1 _)  (nullable? l1)]))
```

And so does the derivative — note the `seqp`/concatenation clause, the same nullable-left-child
guard as Brzozowski's `Dₐ(PQ) = (DₐP)Q + δ(P)DₐQ`:

```racket
; dparse.rkt — the context-free derivative
(define/memoize (parse-derive c l)
  #:order ([l #:eq] [c #:equal])
  (match l
    [(empty)       (empty)]
    [(eps)         (empty)]
    [(token pred class)            (if (pred c) (eps* (set c)) (empty))]
    [(orp l1 l2)                   (alt (parse-derive c l1) (parse-derive c l2))]
    [(seqp (and (nullablep?) l1) l2)            ; L₁ is nullable: differentiate BOTH
     (alt (cat (eps* (parse-null l1)) (parse-derive c l2))
          (cat (parse-derive c l1) l2))]
    [(seqp l1 l2)                  (cat (parse-derive c l1) l2)]  ; L₁ not nullable
    [(redp l f)                    (red (parse-derive c l) f)]))
```

### The three modifications: laziness, memoization, fixed points

A CFG node refers to itself, so naïvely differentiating `L = (L ◦ {x}) ∪ ε` recurs forever:
`Dₓ L = (Dₓ L ◦ {x}) ∪ ε` needs `Dₓ L` to define `Dₓ L`. PWD's central move — the "three small,
surgical modifications to the implementation (but not the theory)" — fixes this with tools
familiar to functional programmers:

1. **Laziness.** The `left`/`right`/`this`/`that`/`lang` fields of the compound nodes are
   `delay`ed (the `cat`/`alt`/`red` macros wrap their arguments in `(delay …)`), so a
   self-referential derivative is _suspended_ until forced. This turns the infinite descent into
   a finite, lazily-explored graph.
2. **Memoization.** `parse-derive` is `define/memoize`d, keyed first by **pointer identity** of
   the node (`#:eq`) and then by the token. When differentiation re-encounters a node it has
   already started, it returns the in-progress (knot-tying) node instead of recurring. As PWD
   puts it, memoization lets the derivative "_'tie the knot'_ when it re-encounters a language it
   has already seen."
3. **Fixed points.** Nullability "isn't looking for a structure; it's looking for a single
   answer", so laziness alone cannot break its self-dependence (`δ(L) = (δ(L) ◦ ∅) ∪ ε`). It is
   computed as a **least fixed point** over the boolean lattice via `define/fix`, ascending from
   `#:bottom #f` by Kleene iteration until no node's nullability changes.

> [!IMPORTANT]
> The `define/memoize` (`#:eq` then `#:equal`) and `define/fix` (`#:bottom`) abstractions are
> the entire trick. They hide the only impure parts — a memo table and an iterative
> least-fixed-point loop — behind a purely functional surface, so the equational rules above
> _are_ the code. PWD reports the recogniser fits "in less than 30 lines of code"; the full
> parser is the reduction-node variant of the same functions.

### Producing the parse forest

Recognition only needs `nullable?` at the end. **Parsing** needs the set of parse trees of the
final residual grammar — `parse-null`, again a least fixed point, this time over **sets of parse
trees** (`#:bottom (set)`):

```racket
; dparse.rkt — extract the parse forest of the residual grammar
(define/fix (parse-null l)
  #:bottom empty-tree-set
  (match l
    [(empty)      empty-tree-set]
    [(eps* S)     S]                                    ; carries accumulated trees
    [(eps)        (set l)]
    [(token _ _)  empty-tree-set]
    [(orp l1 l2)  (set-union (parse-null l1) (parse-null l2))]
    [(seqp l1 l2) (for*/set ([t1 (parse-null l1)] [t2 (parse-null l2)]) (cons t1 t2))]
    [(redp l1 f)  (for/set ([t (parse-null l1)]) (f t))]))
```

The top-level loop is the whole parser: `foldl` the derivative over the input, then run
`parse-null` on the residual.

```racket
; dparse.rkt — the parse loop: derive per token, compact, then extract the forest
(define (parse l s #:compact [compact (lambda (x) x)] …)
  (cond
    [(stream-null? s) (parse-null l)]
    [else (let* ([c (stream-car s)] [dl/dc (parse-derive c l)] [l* (compact dl/dc)])
            (parse l* (stream-cdr s) #:compact compact))]))
```

### Compaction: taming the blowup

The naïve PWD is _correct_ but, in its own words, "awful": a Python 3.1 parser took "just under
three minutes to parse a (syntactically valid) 31-line input." The villain is the concatenation
rule. Each derivative can **double** the grammar (the nullable-left case produces two children),
and "much of the new structure inflicted by the derivative is either dead on arrival, or it dies
after the very next derivative." **Compaction** is a second equational theory that prunes this
debris — `∅` is the annihilator of `◦` and the identity of `∪`, `ε` is the identity of `◦`, and
reductions compose:

```text
∅ ◦ p ⇒ ∅            ∅ ∪ p ⇒ p             (ε↓{t₁}) ◦ p ⇒ p → λt₂.(t₁,t₂)
p ◦ ∅ ⇒ ∅            p ∪ ∅ ⇒ p             (p → f) → g ⇒ p → (g ∘ f)
```

Crucially, compaction must be **deep and memoized**, not merely top-level:

> "When simplification is deeply recursive and memoized, we term it compaction. If the algorithm
> compacts after every derivative, then the time to parse the 31-line Python file drops from
> three minutes to two seconds." — PWD, §8

PWD is candid about the danger: "With mere top-level simplification in lieu of memoization and
deep recursive simplification, the grammar still grows with each derivative, and the cost of
parsing the 31-line example explodes from two seconds to one minute." The same residual-grammar
plot in [Might's blog][mightblog] shows the grammar stabilising at ~17 nodes across 120+
derivatives _with_ compaction versus 330,000+ nodes without it.

---

### Power & limits

**Regular layer.** Brzozowski/Owens derivatives recognise exactly the **regular** languages —
and, because closure under Boolean operations is built into the recurrence, the _extended_ regex
with intersection and complement, which the [Thompson NFA construction][owens] does not handle
natively. The cost is that deciding exact equivalence of extended regexes is non-elementary, so
implementations use the [similarity approximation](#similarity-keeping-the-state-set-finite-in-practice).

**Context-free layer.** PWD recognises and parses **every context-free language** — the same
maximal class as [Earley, CYK, GLR, and GLL][general]. PWD's related-work section places it
precisely: "Derivative-based parsing shares full coverage of all context-free grammars with GLR,
CYK and Earley." It does _not_ extend to context-sensitive or [PEG][peg] languages: there is no
ordered-choice or syntactic-predicate construct, and the union node is genuinely commutative
(unlike PEG's `/`).

Where does PWD sit in the top-down/bottom-up taxonomy? Neither, cleanly. PWD reports a
correspondent's observation: "when the grammar is in Greibach Normal Form (GNF), the algorithm
acquires a 'parallel' top-down flavor. For grammars outside GNF … one sees what appears to be a
pushdown stack emerge inside the grammar." Derivatives carry the parse state _in the grammar
structure itself_ rather than in an explicit stack or chart.

### Ambiguity handling

Ambiguity is handled **natively and exhaustively** — this is the headline selling point. The
`union` node is a set-theoretic alternation, so a derivative simply propagates into _both_
branches; `parse-null` unions the parse-tree sets of both. An ambiguous input yields a parse
_forest_ containing every derivation, shared through the memoised graph (and through `eps*`'s
tree-sets and ambiguity nodes). PWD: the derivative "transparently handles ambiguity … or any
combination thereof."

The catch is the same one [Earley and GLR][general] face: the _number_ of distinct parse trees
can be exponential (or infinite, for cyclic grammars), even though the _shared_ representation is
polynomial. [Adams et al.][adams] are explicit that their cubic bound holds **only** under
shared-forest representation:

> "we assume that ASTs use ambiguity nodes and a potentially cyclic graph representation. This is
> a common and widely used assumption when analyzing parsing algorithms … algorithms like GLR
> and Earley are considered cubic, but only when making such assumptions." — Adams et al., §3.1

Enumerating all trees of `S → S S | a | b` is exponential; representing them with ambiguity
nodes is not.

### Error detection & recovery

Derivative parsers are **precise recognisers** with weak recovery, much like [PEG/packrat][peg].
Detection is exact and incremental: the moment the residual grammar compacts to `∅` (the empty
language), no suffix can complete the parse, and the failing token is the error position —
Brzozowski's regex matcher already "reach[es] a derivative that is the RE `∅`, and stop[s]"
(Owens §3.2). For the CFG layer, a derivative that yields `(empty)` for the only live branch is
the analogous signal.

What the literature does **not** provide is built-in error _recovery_ (resynchronisation,
error productions, partial-tree construction). There is no equivalent of LR's
[panic-mode `FOLLOW`-set recovery][bottom-up] or Earley's error productions in the seminal PWD
work; recovery would have to be layered on top (e.g. inserting error-tolerant alternatives into
the grammar). This is a genuine gap relative to mature [`LALR` generators][bison] and
[ANTLR][antlr]'s automatic recovery.

### Performance & complexity

The performance story is the most dramatic arc in this subtree. **PWD (2011)** itself reported a
discouraging bound and worse practice. Its cost model — `(#derivatives) × (cost of derivative) +
(cost of final fixed point)` — with a grammar that can double per derivative gives:

> "the worst-case complexity of parsing a grammar of size `G` over an input of length `n` is
> `O(2²ⁿ G²)`." — PWD, §7

PWD conjectured, but did not prove, an `O(n·G)` average case, and the folklore — including
[Russ Cox][cox] and Daniel Spiewak — hardened into a belief that PWD was _fundamentally_
exponential. **Adams, Hollenbeck & Might (2016)** overturned this:

> "We have discovered that it is not exponential but, in fact, cubic. Moreover, simple (though
> perhaps not obvious) modifications to the implementation … lead to an implementation that is
> not only easy to understand but also highly performant in practice." — Adams et al., abstract

The proof is a counting argument. The total running time is `O(G + g)` where `g` is the number
of grammar nodes constructed (Lemmas 1–3, Theorem 4): each of `nullable?`, `derive`, and
`parse-null` does `O(1)` non-cached work per node, with memoisation ensuring each node is
computed once. The whole result then reduces to **bounding `g`**. Adams et al. assign each node a
**unique name** that records which initial node it descended from and which input substring drove
the derivation (Definition 5), then prove two combinatorial facts:

- Each name is `N·w` or `N·u•v` where `N` is one of `G` initial nodes and `w`, `uv` are
  **substrings of the input** — of which there are `O(n²)` (Lemma 6, citing Flaxman et al.).
- Each name contains **at most one** `•` marker (Lemma 7) — the duplication caused by a nullable
  `◦` node "is never involved in another duplication" — contributing one more factor of `O(n)`.

Multiplying: `G × O(n²) × O(n) = O(G·n³)` nodes (Theorem 8), hence:

> "The running time of parse is `O(Gn³)`." — Adams et al., Theorem 9

This puts PWD's asymptotics **on par with Earley and GLR**. The proof does not even assume
compaction; compaction "only ever reduces the number of nodes constructed."

The _practical_ speedups came from three engineering fixes Adams et al. profiled out:

| Improvement                  | What changed                                                                                                                                                                               | Effect                                                       |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------ |
| **Accelerated fixed points** | Replace re-traverse-until-stable nullability with [Kildall][adams] data-flow that revisits only dependents; distinguish "definitely-not-nullable" from "assumed-not-nullable" across calls | `nullable?` calls fall to **1.5%** of the original           |
| **Improved compaction**      | Add overlooked rules (`∅ ↪ f ⇒ ∅`), canonicalise chains of sequence nodes, float reductions out, and compact _inside_ `derive` instead of as a separate pass                               | avoids double traversal per token                            |
| **Single-entry memoisation** | Store one memo key/value in **fields on each node** instead of nested hash tables (hash access is up to 30× slower than field access in Racket)                                            | **2.04×** faster on average; only +4.2% extra `derive` calls |

The cumulative result, benchmarked on the Python 3.4.3 standard library (663 files, up to 26,125
tokens):

> "our improved parser runs on average 951 times faster than that by Might et al. (2011). It even
> runs 64.6 times faster than the parser that uses the `parser-tools/cfg-parser` library
> [Earley] … our implementation ran slower than the Bison-based parser, but by only a factor of
> 25.2." — Adams et al., §4.1

A ~1000× speedup over the original, **64×** faster than a Racket Earley parser, and within ~25×
of C-based [Bison/GLR][bison] despite being interpreted Racket — and "the core code is 62 lines
of Racket code with an additional 76 lines of code for helpers" ([`derp-3`][derp3]).

> [!WARNING]
> The cubic bound and the practical speed both hinge on **deep, memoised compaction** plus
> shared-forest output. Drop compaction and the grammar grows unboundedly (space blowup,
> minutes per file); drop the shared-forest assumption and tree _enumeration_ is exponential for
> ambiguous grammars. Derivatives are tiny and elegant, but they are **not** turnkey-fast — the
> 2011→2016 gap is entirely about the constant factors and the representation.

### Where it shows up in practice

- **Lexer generators.** [`ml-ulex`][mlulex] (the SML/NJ scanner generator) and Owens'
  PLT-Scheme lexer are production derivative-based tools; their generated scanners are "often
  optimal in the number of states and … uniformly better than those produced by previous tools"
  (Owens §7). Derivative lexers also underpin Unicode-aware tokenizers via
  [derivative classes](#derivative-classes-surviving-unicode).
- **Reference CFG parsers.** Matt Might's [`derp`/`derp-3`][derp3] (Racket) is the canonical
  PWD implementation; `derp-3` is the [Adams et al.][adams] cubic-and-fast version. PWD has been
  independently ported to Haskell, Scala, Java, Common Lisp, Python, and Rust (the `barre` /
  `Barre` project), per PWD §9 and the [Adams et al. bibliography][adams].
- **Adjacent general parsers.** [`instaparse`][general] (Clojure, GLL-based) is frequently
  grouped with derivative parsers as a "drop in the grammar, parse any CFG" tool; the broader
  general-CFG family — [Earley, CYK, GLL, and GLR][general] — shares PWD's cubic ceiling and
  parse-forest output. The contrast with linear-time, single-tree [PEG/packrat][peg] is the
  sharpest in this subtree: both make "the parser is a recursive value" concrete, but PEG commits
  to ordered choice and linear time while derivatives keep full ambiguity at cubic cost.
- **Regex engines and runtime verification.** Derivatives (Brzozowski and Antimirov) underpin
  several modern regex matchers with intersection/complement/lookaround (e.g. the `RE#` and
  symbolic-derivative lines of work) and rewriting-based runtime-verification monitors, where
  Antimirov's linear partial-derivative bound is the key resource guarantee.

---

## Strengths

- **Minimal, compositional, purely functional.** A complete CFG recogniser is ~30 lines; a full
  parser ~140. The parser _is_ a value; the derivative _is_ a function; parsing _is_ a fold. No
  generator, no build step, no table format.
- **Every CFG, no massaging.** Left recursion, right recursion, ambiguity, ε-rules, and cyclic
  grammars all "just work" — the cycles in the grammar graph are first-class, handled by laziness
  - memoisation, with no grammar rewriting (unlike [LL][top-down]) and no conflict resolution
    (unlike [LR][bottom-up]).
- **Extended regex for free (regular layer).** Intersection and complement fall straight out of
  the derivative recurrence, which [Thompson construction][owens] cannot do natively — a decisive
  win for lexer specifications.
- **Native, exhaustive ambiguity.** Produces a shared parse _forest_ of all derivations, like
  [Earley/GLR][general], with no extra mechanism.
- **Cubic, after all.** [Adams et al.][adams] proved `O(G·n³)`, matching the best general-CFG
  parsers, and demonstrated near-Bison practical speed — dispelling the exponential folklore.
- **Incremental and online-friendly.** State advances one symbol at a time, so the technique is
  naturally streaming and a good fit for incremental/interactive settings.

## Weaknesses

- **Space blowup without compaction.** The concatenation rule can double the grammar each step;
  correctness is trivial but performance demands **deep, memoised compaction**, which is the
  hard, easy-to-get-wrong part.
- **Fast only with serious engineering.** The 2011 implementation was ~1000× slower than the
  2016 one for the _same algorithm_. Naïve derivatives are pedagogically beautiful and
  operationally sluggish.
- **No built-in error recovery.** Detection is precise (residual `∅`), but there is no
  panic-mode, error-production, or partial-tree machinery in the seminal work — a real gap versus
  [Bison][bison]/[ANTLR][antlr].
- **Tree enumeration is exponential.** The cubic bound is for building the _shared_ forest;
  enumerating all parse trees of an ambiguous grammar is exponential (an inherent property of the
  problem, shared with [Earley/GLR][general], not a flaw unique to derivatives).
- **Memoisation/identity-sensitive.** Correctness leans on **pointer-identity** memoisation
  (`#:eq`) and fixed-point convergence; these are subtle to port to languages without cheap
  identity hashing or with eager evaluation.
- **Niche tooling.** Outside research implementations there is no mainstream, battle-hardened
  derivative-based CFG parser generator with IDE integration, diagnostics, and a large grammar
  ecosystem (contrast [ANTLR][antlr], [Bison][bison], [tree-sitter][tree-sitter]).

## Key design decisions and trade-offs

| Decision                                                                          | Rationale                                                                                              | Trade-off                                                                                             |
| --------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------- |
| One operation (`Dᵤ`) applied symbol-by-symbol                                     | The entire equational theory transliterates into ~30 lines; no `FIRST`/`FOLLOW`, tables, or charts     | The grammar _is_ the state and mutates into successive derivatives — opaque to step-through debugging |
| Concatenation rule guards on nullability (`δ(P)` factor)                          | Correctly handles the case where the leading symbol is consumed by the second factor                   | This is the _only_ duplicating rule; it is the source of the size blowup and the `n³` factor          |
| Grammar-as-cyclic-graph + laziness + memoisation                                  | Lets a regular-expression engine handle _recursive_ (context-free) definitions unchanged               | Depends on pointer-identity (`#:eq`) memo keys and delayed fields — fragile to port                   |
| Nullability / parse-null as least fixed points                                    | Cyclic self-dependence (`δ(L)` needs `δ(L)`) has no structural-recursion answer; Kleene iteration does | Each fixed point is per-derivative work; the naïve iterate-to-stable version is quadratic             |
| Similarity (regex) / compaction (CFG) via **smart constructors**                  | Keeps the residual finite/small so structural equality decides state identity and parsing stays cubic  | Must be deep + memoised to work; top-level-only simplification still blows up (PWD §8)                |
| Brzozowski DFA (normalize, deterministic) vs Antimirov NFA (linear, no normalize) | DFA is minimal and table-ready; partial-derivative NFA is linear-size with zero simplification         | DFA needs costly ACI/similarity normalization; NFA defers nondeterminism cost to matching time        |
| Shared parse forest with ambiguity nodes                                          | Makes ambiguity representation polynomial and the `O(G·n³)` bound achievable                           | Enumerating individual trees is still exponential; the bound is on the _forest_, not the trees        |
| Output a recogniser (`δ`) or a parser (`reduction` nodes)                         | The same derivative engine serves lexing, recognition, and parsing by swapping the leaf algebra        | Parse-forest extraction (`parse-null`) adds a final fixed point over tree-sets                        |

---

## Sources

- J. A. Brzozowski, ["Derivatives of Regular Expressions"][brz], _Journal of the ACM_
  11(4):481–494, 1964 — the origin: Definition 3.1 (derivative `D_s R = {t | st ∈ R}`),
  Definition 3.2 (characteristic function `δ`), Theorem 3.1 (the derivative recurrence including
  `Dₐ(PQ) = (DₐP)Q + δ(P)DₐQ`), Theorem 4.2 (membership ⇔ `λ ∈ D_s R`), Theorem 4.3 (finite number
  of derivative types), Theorem 5.2 (finite dissimilar derivatives), and §5 state-diagram
  construction. (Quotes verified against a `pdftotext -layout` extraction of the open-access scan.)
- V. M. Antimirov, ["Partial derivatives of regular expressions and finite automaton
  constructions"][anti], _Theoretical Computer Science_ 155(2):291–319, 1996 — partial
  derivatives as a _set_ of regexes, the linear bound on distinct partial derivatives, and the
  linear-size NFA construction. (Linearity facts cross-checked against [_On the Space Complexity
  of Partial Derivatives_][antishuffle], 2025, which restates Antimirov's results.)
- S. Owens, J. Reppy & A. Turon, ["Regular-expression derivatives reexamined"][owens], _Journal
  of Functional Programming_ 19(2):173–190, 2009 — the lexer-generation revival: nullability `ν`,
  the derivative rules with Boolean operators, similarity `≈` (§4.1), derivative classes for
  large alphabets (§4.2), and the `ml-ulex` experience. (Quotes verified against a
  `pdftotext -layout` extraction.)
- M. Might, D. Darais & D. Spiewak, ["Parsing with Derivatives: A Functional Pearl"][pwd],
  _ICFP '11_, pp. 189–195 — the context-free extension: the laziness/memoization/fixed-point
  trio, the parser/parser-combinator derivative, `parse-null`, the `O(2²ⁿ G²)` naïve bound (§7),
  and compaction (§8). (Quotes verified against a `pdftotext -layout` extraction.)
- M. D. Adams, C. Hollenbeck & M. Might, ["On the Complexity and Performance of Parsing with
  Derivatives"][adams], _PLDI '16_, pp. 224–236 — the `O(G·n³)` proof (Definition 5, Lemmas 1–7,
  Theorems 8–9), accelerated fixed points, improved compaction, single-entry memoisation, and the
  ~951× / 64.6× / 25.2× benchmarks (§4.1). (Quotes verified against the [arXiv 1604.04695][adams]
  `pdftotext` extraction.)
- M. Might, ["Yacc is dead: An update"][mightblog] and the reference Racket source
  [`dparse.rkt`][dparse] — the grammar-node structs, `define/memoize`, `define/fix`, the
  derivative/`parse-null`/compaction code, and the residual-grammar-size plots. Code excerpts
  quoted verbatim from the source.
- Implementations: [`ml-ulex`][mlulex] (SML/NJ derivative lexer); [`derp-3`][derp3] (the cubic
  Racket PWD); [`re2c`][re2c] (a derivative-influenced lexer generator).
- Related deep-dives: [theory index][theory-index] · [parsing umbrella][umbrella] ·
  [concepts glossary][concepts] · [general parsing (Earley/CYK/GLL)][general] ·
  [PEG & packrat][peg] · [top-down/LL][top-down] · [bottom-up/LR & GLR][bottom-up] ·
  [Pratt][pratt] · [formal-language hierarchy][formal] · [ANTLR][antlr] · [Bison/Yacc][bison] ·
  [Menhir][menhir] · [tree-sitter][tree-sitter] · combinator libraries
  [Parsec][parsec]/[nom][nom]/[chumsky][chumsky]/[pest][pest] · [comparison][comparison].

<!-- References -->

<!-- Same-tree theory siblings -->

[theory-index]: ./index.md
[formal]: ./formal-languages.md
[top-down]: ./top-down.md
[bottom-up]: ./bottom-up.md
[general]: ./general-parsing.md
[peg]: ./peg-packrat.md
[pratt]: ./pratt-precedence.md

<!-- Tree umbrella / concepts / comparison -->

[umbrella]: ../index.md
[concepts]: ../concepts.md
[comparison]: ../comparison.md

<!-- Library deep-dives -->

[antlr]: ../antlr.md
[bison]: ../bison-yacc.md
[tree-sitter]: ../tree-sitter.md
[menhir]: ../menhir.md
[parsec]: ../haskell-parsec.md
[nom]: ../rust-nom.md
[chumsky]: ../rust-chumsky.md
[pest]: ../pest.md

<!-- Primary sources & external -->

[brz]: https://dl.acm.org/doi/10.1145/321239.321249
[anti]: https://www.sciencedirect.com/science/article/pii/0304397595001824
[antishuffle]: https://arxiv.org/pdf/2508.17451
[owens]: https://www.khoury.northeastern.edu/home/turon/re-deriv.pdf
[pwd]: https://david.darais.com/assets/papers/parsing-with-derivatives/pwd.pdf
[adams]: https://arxiv.org/abs/1604.04695
[mightblog]: https://matt.might.net/articles/parsing-with-derivatives/
[dparse]: https://matt.might.net/articles/parsing-with-derivatives/code/dparse.rkt
[derp3]: https://github.com/adamsmd/derp-3
[mlulex]: https://web.archive.org/web/20260525131512/http://smlnj.org/doc/ML-Lex/manual.html
[re2c]: https://re2c.org/
[cox]: https://research.swtch.com/yaccalive
