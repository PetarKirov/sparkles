# Bottom-Up Parsing: LR, SLR, LALR, Canonical LR, and GLR

The **bottom-up** family parses a string by discovering the rightmost derivation _in
reverse_ — it scans left to right, recognises **handles** (the right-hand side that was
substituted last), and reduces them, building the parse tree from the leaves up to the
root. Its deterministic members — `LR(0)`, `SLR(1)`, `LALR(1)`, and **canonical** `LR(1)`
— recognise exactly the [deterministic context-free languages](./formal-languages.md) with
a finite-state control over a stack, and dominate the parser-generator tradition
([yacc][yacc-doc]/[Bison](../bison-yacc.md), [Menhir](../menhir.md)). Its generalized
member — **GLR** (Tomita) — drops the determinism requirement and parses _any_ context-free
grammar, ambiguous or not, in worst-case cubic time, and underlies modern incremental
engines such as [Tree-sitter](../tree-sitter.md). This document is the bottom-up leaf of
the [parsing theory](./index.md) survey; its dual is [top-down parsing](./top-down.md)
(`LL`, recursive descent), and the ambiguity-tolerant chart algorithms it competes with
are covered in [general parsing](./general-parsing.md).

## At a glance

| Property                       | Deterministic LR (`LR(0)`/`SLR(1)`/`LALR(1)`/`LR(1)`)                                        | Generalized LR (GLR / Tomita)                                                                 |
| ------------------------------ | -------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| Grammar class handled          | the corresponding LR subclass; together, the **deterministic** (`LR(k)`) grammars            | **all** context-free grammars (ambiguous & nondeterministic included)                         |
| Languages recognised           | deterministic context-free (a `DPDA` accepts them)                                           | all context-free languages                                                                    |
| Direction / derivation         | left-to-right scan, **r**ightmost derivation in reverse — the **R** in `LR`                  | same, but exploring all rightmost derivations at once                                         |
| Lookahead                      | `k` terminals (`k = 1` in practice; `LR(0)` uses none for the decision)                      | `k` per split; conflicts spawn parallel parsers instead of being decided                      |
| Control / memory model         | a `DFA` over **viable prefixes** driving a stack of states (the **parse table**)             | a **graph-structured stack** (`GSS`) + a **shared packed parse forest** (`SPPF`)              |
| Worst-case time                | `O(n)` (linear)                                                                              | `O(n^{p+1})` (Tomita Alg. 1, `p` = longest RHS); `O(n^3)` for the cubic variants              |
| Worst-case space               | `O(n)` stack; table size fixed by the grammar                                                | `O(n^2)` GSS / `O(n^3)` forest in the ambiguous limit                                         |
| Conflicts                      | **shift/reduce** and **reduce/reduce** — a static defect of the grammar+method               | not a defect: both alternatives are pursued, results packed or merged                         |
| Canonical algorithms           | Knuth `LR(k)` item-set construction; DeRemer `LALR`; DeRemer & Pennello lookahead            | Tomita Algorithms 0–4; Farshi/Nozohoor-Farshi & Scott–Johnstone cubic fixes                   |
| Representative implementations | [yacc][yacc-doc]/[Bison](../bison-yacc.md) (`LALR`/`IELR`), [Menhir](../menhir.md) (`LR(1)`) | [Bison](../bison-yacc.md) `%glr-parser`, [Tree-sitter](../tree-sitter.md) (GLR + incremental) |

> [!NOTE]
> "Bottom-up" and "`LR`" are used interchangeably here, but the family is broader than the
> `LR` _methods_: it includes the weaker precedence and operator-precedence techniques
> (the ancestor of [Pratt parsing](./pratt-precedence.md)) and the generalized `GLR`
> variant. This document concentrates on the `LR` item-set methods and `GLR`, the two that
> a practitioner actually meets in a parser generator.

---

## Overview / motivation

The core idea is **shift-reduce** parsing. The parser maintains a stack; at each step it
either **shifts** the next input terminal onto the stack, or, when the top of the stack
matches the right-hand side of a production, **reduces** that right-hand side to the
production's left-hand nonterminal. [Bison][bison-algo]'s manual states the mechanism
plainly:

> "As Bison reads tokens, it pushes them onto a stack along with their semantic values.
> The stack is called the _parser stack_. Pushing a token is traditionally called
> _shifting_. … When the last `n` tokens and groupings shifted match the components of a
> grammar rule, they can be combined according to that rule. This is called _reduction_. …
> The parser tries, by shifts and reductions, to reduce the entire input down to a single
> grouping whose symbol is the grammar's start-symbol … This kind of parser is known in
> the literature as a _bottom-up_ parser." — [Bison §5, _The Bison Parser Algorithm_][bison-algo]

The hard part is deciding _when_ a stack top is a genuine **handle** worth reducing, and
_which_ production to reduce by. Donald Knuth's 1965 paper [_On the Translation of
Languages from Left to Right_][knuth-pdf] both named the problem and solved it for the
widest practical class. Knuth defines a _handle_ as the leftmost complete branch of the
derivation tree, then frames parsing as **handle pruning**:

> "Let us define the _handle_ of a tree to be the leftmost set of adjacent leaves forming
> a complete branch … This process of pruning the handle at each step corresponds exactly
> to [the rightmost] derivation in reverse. The reader may easily verify, in fact, that
> 'handle pruning' always produces, in reverse, the derivation obtained by replacing the
> _rightmost_ intermediate character at each step." — [Knuth 1965, p. 610][knuth-pdf]

The decisive question is whether the handle can be recognised by a finite amount of
left context plus a bounded lookahead. Knuth's `LR(k)` condition answers exactly this,
and he gives its intuitive reading:

> "This definition of an `LR(k)` grammar coincides with the intuitive notion of
> translation from left to right looking `k` characters ahead. Assume at some stage of
> translation we have made all possible reductions to the left of `Xn`; by looking at the
> next `k` characters `Xn+1 … Xn+k`, we want to know if a reduction on `Xr+1 … Xn` is to be
> made, regardless of what follows `Xn+k`. In an `LR(k)` grammar we are able to decide
> without hesitation whether or not such a reduction should be made." — [Knuth 1965, p. 611][knuth-pdf]

Knuth's central structural insight — the one that makes `LR` parsing _mechanisable_ — is
that the set of stack contents that can precede a handle is a **regular** language:

> "When `k` is given … it is possible to decide if a grammar is `LR(k)` or not. The
> essential reason behind this [is] that the possible configurations of a tree below its
> handle may be represented by a regular (finite automaton) language." — [Knuth 1965, p. 611][knuth-pdf]

That regular language is the language of **viable prefixes**, and the finite automaton
recognising it is the `LR(0)` **item-set automaton**, the data structure every `LR` method
is built on. Knuth also fixes the family's expressive ceiling: he proves `LR(k)` grammars
are unambiguous, and connects them to the deterministic languages —

> "An `LR(k)` grammar is clearly unambiguous, since the definition implies every derivation
> tree must have the same handle … the `LR(k)` condition may be regarded as the most
> powerful general test for nonambiguity that is now available." — [Knuth 1965, p. 611][knuth-pdf]

The motivation for **GLR**, twenty years later, is the inverse: many real grammars
(natural language above all, but also C's typedef/expression overlap and many DSLs) are
_not_ `LR(k)` for any `k`, yet we still want LR-style efficiency on the common
deterministic case. Masaru Tomita's 1985 _Efficient Parsing for Natural Language_
generalizes the `LR` stack into a graph so that conflicts need not be resolved — the
parser simply pursues every alternative simultaneously, sharing work so that the cost
stays polynomial.

---

## How it works

The deterministic `LR` methods share one engine and differ only in **how they decide
reductions**. We build the engine first, then layer the four lookahead disciplines
(`LR(0)`, `SLR(1)`, `LALR(1)`, `LR(1)`) on top, then the conflict story, then `GLR`.

### Items, viable prefixes, and the LR(0) automaton

An **`LR(0)` item** is a production with a dot marking how much of the right-hand side has
been seen, e.g. `A → α • B β`. The dot before a symbol means "we expect to see this next";
the dot at the far right, `A → α •`, is a **complete item** signalling that `α` is a handle
ready to reduce to `A`. A **viable prefix** is any prefix of a right-sentential form that
does not extend past the handle — exactly the stack contents that can legally arise. The
`LR(0)` automaton is the `DFA` whose states are sets of items and whose language is the set
of viable prefixes; reaching a state tells the parser precisely which items are _valid_ for
the stack so far.

Two functions build the automaton. **`CLOSURE`** completes an item set: if `A → α • B β` is
in the set and `B` is a nonterminal, every production `B → • γ` is added (we are about to
start matching some `B`), repeating to a fixpoint. **`GOTO(I, X)`** computes the successor
state: advance the dot past `X` in every item of `I` that has the dot before `X`, then take
the closure. Standard treatments (the [Dragon Book][dragon] ch. 4.6) phrase `GOTO` as:
`GOTO(I, X)` is the closure of `{ A → α X • β | A → α • X β ∈ I }`, and prove that if `I`
is the set of valid items for viable prefix `γ`, then `GOTO(I, X)` is the set of valid
items for `γX`. The full set of states reachable from the start item's closure is the
**canonical collection** `C`.

```text
Augmented grammar:  S' → S        productions of an example expression grammar:
                    S  → E              E → E + T | T
                                        T → T * F | F
                                        F → ( E ) | id

CLOSURE({S' → • S}) =
    S' → • S
    S  → • E             ← added because the dot precedes nonterminal S, then E …
    E  → • E + T
    E  → • T
    T  → • T * F
    T  → • F
    F  → • ( E )
    F  → • id

GOTO(I0, E) advances the dot past E in every item that has • E :
    S → E •              ← a complete-ish item (here, accept after lookahead)
    E → E • + T          ← still expecting '+' T
```

The `DFA` so constructed is the **handle recogniser**: a path spelling a viable prefix ends
in a state, and that state's complete items name the candidate handles. The whole `LR`
family runs the **same driver** over this automaton — a stack of states, a **parse table**
with an `ACTION` part (shift `s`, reduce by rule `r`, accept, or error, keyed by state ×
terminal) and a `GOTO` part (state × nonterminal → state). The four methods differ only in
how the `ACTION` table decides between _shift_ and _reduce_ in a state that has both a
shiftable terminal and a complete item.

### LR(0): reduce on every complete item

The weakest method ignores lookahead entirely: in any state containing a complete item
`A → α •`, reduce by `A → α` on _every_ terminal. This works only if no state ever holds a
complete item alongside a shift or a second complete item. Grammar (7) in Knuth, `S → aAc,
A → Abb, A → b`, is `LR(0)`; grammar (6), `S → aAc, A → bAb, A → b`, is _not_ `LR(k)` for
any `k`, because given `ab^m` no amount of lookahead reveals which `b` to reduce until the
closing `c` is seen ([Knuth 1965, p. 612][knuth-pdf]). `LR(0)` is the theoretical floor;
real grammars almost always need lookahead to separate a reduce from a shift.

### SLR(1): resolve with FOLLOW

**Simple `LR`** (SLR, Frank DeRemer's 1971 simplification) keeps the `LR(0)` automaton but
reduces by `A → α •` only when the lookahead terminal is in **`FOLLOW(A)`** — the set of
terminals that can appear immediately after `A` in any sentential form. This is the
cheapest useful lookahead: it is a property of the _nonterminal_ `A` alone, computed once
globally, ignoring the state the reduction occurs in. The weakness is precisely that
globality: `FOLLOW(A)` lumps together every context in which `A` can appear, so it admits
lookaheads that are valid for `A` _somewhere_ but not in _this_ state, producing spurious
conflicts on grammars that are otherwise easily parsed.

### LALR(1): per-state lookahead by merging LR(1) states

**Look-Ahead `LR`** (LALR, DeRemer 1969) closes the SLR gap without paying for full `LR(1)`.
Conceptually it builds the canonical `LR(1)` automaton (next section) and then **merges any
two states that have the same set of `LR(0)` cores** (the same items ignoring lookahead),
unioning their lookaheads. This keeps the `LR(0)`-sized state count — the property that made
it deployable — while giving each reduction a lookahead set computed _for the state it
occurs in_, not for the nonterminal globally. DeRemer & Pennello's later paper frames the
core LALR object as a per-state, per-production **lookahead set** `LA(q, A → ω)` and ties
the whole method to the `LR(0)` automaton's consistency:

> "DeRemer defined a grammar to be `LALR(1)` when each inconsistent state `q` can be
> augmented with look-ahead sets that resolve the conflict and result in a correct,
> deterministic or 'consistent' parser. … When the parser is in state `q` and the symbol
> at the head of the input is in `LA(q, A → ω)`, … [the handle] must be reduced to `A`.
> Thus the look-ahead sets in `q` must be mutually disjoint and not contain any of the
> symbols that could be read from `q`." — [DeRemer & Pennello 1982, §1.1][deremer-pdf]

The naïve way to get those sets — actually build `LR(1)` and merge — is expensive. The
landmark contribution of DeRemer & Pennello 1982, _Efficient Computation of `LALR(1)`
Look-Ahead Sets_, is to compute `LA` directly on the `LR(0)` automaton via four relations
over its **nonterminal transitions** `(p, A)` (state `p` with a transition on nonterminal
`A`). Their abstract states the payoff:

> "Two relations that capture the essential structure of the problem of computing `LALR(1)`
> look-ahead sets are defined, and an efficient algorithm is presented to compute the sets
> in time linear in the size of the relations. In particular, for a PASCAL grammar, the
> algorithm performs fewer than 15 percent of the set unions performed by the popular
> compiler-compiler `YACC`." — [DeRemer & Pennello 1982, abstract][deremer-pdf]

The four relations decompose `LA` into a pipeline, "in reverse order of computation":
`LA` ← `Follow` ← `Read` ← `Direct Read` ([DeRemer & Pennello §1.1][deremer-pdf]). Their
verbatim definitions (for an `LR(0)` parser with nonterminal transition `(p, A)`):

| Relation / set                                                           | Definition (DeRemer & Pennello 1982, §3–4)             | Meaning                                                       |
| ------------------------------------------------------------------------ | ------------------------------------------------------ | ------------------------------------------------------------- |
| `DR(p, A)` (Direct Read)                                                 | terminals `t` such that `p —A→ r —t→` for some `r`     | terminals labelling terminal transitions just past `(p, A)`   |
| `(p, A) reads (r, C)`                                                    | `p —A→ r —C→` and `C ⇒* ε`                             | a nullable nonterminal follows, so its reads carry over       |
| `Read(p, A) = DR(p, A) ∪ ⋃{Read(r, C) : (p, A) reads (r, C)}`            | (Theorem ACROSS)                                       | terminals readable before any phrase including `A` is reduced |
| `(p, A) includes (p', B)`                                                | `B → β A γ`, `γ ⇒* ε`, and `p' —β→ p`                  | `A`'s follow context is inherited from `B`'s                  |
| `Follow(p, A) = Read(p, A) ∪ ⋃{Follow(p', B) : (p, A) includes (p', B)}` | (Theorem UP)                                           | terminals that can follow `A` out of state `p`                |
| `(q, A → ω) lookback (p, A)`                                             | `p —ω→ q` (the path spelling `ω` from `p` ends at `q`) | which transitions' follow sets feed this reduction            |
| `LA(q, A → ω) = ⋃{Follow(p, A) : (q, A → ω) lookback (p, A)}`            | (Theorem UNION)                                        | the final lookahead set for reducing `A → ω` in `q`           |

The crucial efficiency move is to recognise that `Read` and `Follow` are each the least
solution of a union-recurrence over a relation, i.e. each set is the union of the initial
set with the sets of everything reachable in the relation's **digraph**. That is computed
by a single strongly-connected-components traversal, their `algorithm Digraph` (adapted
from Eve & Kurki-Suonio), which they prove linear:

> "THEOREM LINEARITY. Algorithm `Digraph` is order `|Vertices| + |Edges|` of the digraph
> induced by relation `R`, that is, linear in the 'size' of `R`." — [DeRemer & Pennello 1982, §4.2][deremer-pdf]

`Digraph` does one set-union per edge while finding SCCs:

```text
algorithm Digraph:                                  # F x ← F' x at entry; unions on each edge
  input  R (relation on X),  F' (X → sets)
  output F (X → sets), least solution of  F x = F' x ∪ ⋃{ F y | x R y }
  for x ∈ X with N x = 0 do Traverse(x)
  recursive Traverse(x):
    push x; d ← Depth(S); N x ← d;   F x ← F' x
    for y with x R y:
      if N y = 0 then Traverse(y)
      N x ← Min(N x, N y);            F x ← F x ∪ F y      # propagate along the edge
    if N x = d then                                        # x roots an SCC
      repeat  N(Top S) ← ∞;  F(Top S) ← F x  until Pop S = x
```

A bonus of the relational formulation is **grammar debugging**: a nontrivial SCC in the
`reads` digraph, or one in the `includes` digraph with a nonempty `Read` set, certifies the
grammar is **not `LR(k)` for any `k`**:

> "THEOREM READS-SCC. If the digraph induced by the `reads` relation contains a nontrivial
> SCC, then the corresponding grammar is not `LR(k)` for any `k`." — [DeRemer & Pennello 1982, §4.3][deremer-pdf]

`LALR(1)` is the method that **dominated** [yacc][yacc-doc] and [Bison](../bison-yacc.md):
it produces `LR(0)`-sized tables (no state-count blow-up), accepts essentially every
practical programming-language grammar, and — after 1982 — is cheap to construct. Bison
still builds `LALR(1)` by default for historical reasons, while noting the cost: "LALR does
not possess the full language-recognition power of LR. As a result, the behavior of parsers
employing LALR parser tables is often mysterious" ([Bison §5.8.1][bison-lr]).

### Canonical LR(1): lookahead baked into the item

The full method (Knuth's original) attaches a lookahead terminal to every item: an `LR(1)`
item is `[A → α • β, a]`, read as "after recognising `β`, reduce `A → αβ` only if the next
terminal is `a`." `CLOSURE` propagates lookaheads: closing `[A → α • B β, a]` adds
`[B → • γ, b]` for every `b ∈ FIRST(β a)`. Because the lookahead is carried _per item_,
two stacks that reach the same `LR(0)` core but with different viable left contexts become
**different** `LR(1)` states — which is exactly the information `LALR(1)` discards when it
merges. The price is state-count explosion: canonical `LR(1)` tables can be an order of
magnitude larger than `LALR(1)`. Bison exposes all three via `%define lr.type`:

> "Specify the type of parser tables within the LR(1) family. The accepted values for
> `type` are: `lalr` (default), `ielr`, `canonical-lr`." — [Bison §5.8.1, _LR Table Construction_][bison-lr]

`IELR(1)` (Inadequacy-Elimination LR, Denny & Malloy) is the modern middle ground Bison
recommends: "given any grammar (LR or non-LR), parsers using IELR or canonical LR parser
tables always accept exactly the same set of sentences. However, like LALR, IELR merges
parser states … so that the number of parser states is often an order of magnitude less
than for canonical LR" ([Bison §5.8.1][bison-lr]). [Menhir](../menhir.md), by contrast,
constructs **Pager's** minimal `LR(1)` automaton directly, giving full `LR(1)` power
without the canonical blow-up.

### Conflicts and their resolution

A state is **inconsistent** (has a conflict) when the chosen lookahead discipline cannot
pick a single action. Two kinds, named by DeRemer & Pennello and by every generator:

- **shift/reduce** — the state has both a shiftable terminal and a complete item whose
  lookahead includes that terminal; the parser cannot tell whether to read more input or
  reduce now. The archetype is the **dangling else**.
- **reduce/reduce** — two complete items have overlapping lookahead; the parser cannot tell
  _which_ rule to reduce by.

These are defects of the _grammar paired with the method_, not necessarily of the language.
A generator resolves them in one of two ways. The default tie-breaks: Bison "is designed to
resolve these conflicts by choosing to shift, unless otherwise directed by operator
precedence declarations," and uses exactly this to attach `else` to the innermost `if`:

> "This situation, where either a shift or a reduction would be valid, is called a
> _shift/reduce conflict_. … Since the parser prefers to shift the 'else', the result is to
> attach the else-clause to the innermost if-statement … This particular ambiguity was
> first encountered in the specifications of Algol 60 and is called the 'dangling else'
> ambiguity." — [Bison §5.2, _Shift/Reduce Conflicts_][bison-sr]

The principled tool is **precedence and associativity declarations**. In yacc/Bison,
`%left`, `%right`, and `%nonassoc` assign precedence levels and associativity to terminals
(later declarations bind tighter); a shift/reduce conflict between a rule and an incoming
terminal is then resolved by comparing the rule's precedence (that of its rightmost
terminal, or an explicit `%prec`) with the terminal's. Higher-precedence operator wins;
equal precedence is broken by associativity — `%left` reduces, `%right` shifts, `%nonassoc`
errors. This single mechanism collapses the dozen-state ambiguity of a binary-operator
expression grammar into a handful of states without rewriting the grammar, and is the
declarative cousin of the binding-power numbers in [Pratt parsing](./pratt-precedence.md).

### Generalized LR: the graph-structured stack

`GLR` (Tomita 1985) removes the requirement that the table be conflict-free. When a state
has multiple actions, the parser does **all of them**. Bison describes the runtime shape:

> "When faced with unresolved shift/reduce and reduce/reduce conflicts, GLR parsers use the
> simple expedient of doing both, effectively cloning the parser to follow both
> possibilities. Each of the resulting parsers can again split, so that at any given time,
> there can be any number of possible parses being explored. The parsers proceed in
> lockstep; that is, all of them consume (shift) a given input symbol before any of them
> proceed to the next. Each of the cloned parsers eventually meets one of two possible
> fates: either it runs into a parsing error, in which case it simply vanishes, or it
> merges with another parser, because the two of them have reduced the input to an
> identical set of symbols." — [Bison §1.5, _Writing GLR Parsers_][bison-glr]

Naïvely cloning the whole stack is exponential. Tomita's two data structures keep it
polynomial:

**Graph-structured stack (`GSS`).** Instead of duplicating the stack, share its common
parts. The stack becomes a directed acyclic graph: when two parses agree on a prefix they
share those nodes (the bottom), and only the divergent tops are distinct; conversely, when
two distinct tops reach the **same state at the same input position**, they are merged into
one node. A reference treatment puts it:

> "Instead of duplicating a stack when a non-deterministic point in the parse is reached,
> the space required can be reduced by only splitting the necessary part of the stack. …
> When the tops of two or more stacks contain the same state, a single state is shared
> between each stack. This prevents duplicate parses of the same input being done." —
> [_Generalised LR parsing_, ch. 4][glr-book]

**Shared packed parse forest (`SPPF`).** Producing a forest of all parse trees would also
be exponential; Tomita shares it. Identical subtrees are shared, and where two derivations
of the same substring differ ("local ambiguity"), they are collapsed under a single
**packing node** rather than duplicated:

> "Local ambiguity occurs when there is a reduce/reduce conflict … The parent nodes are
> merged into a new node and a packing node is made the parent of each of the subtrees. …
> If two trees have the same subtree for a substring `a_j…a_i` then that subtree can be
> shared." — [_Generalised LR parsing_, ch. 4][glr-book]

These structures bound the cost. Tomita's recogniser Algorithm 1 already runs much faster
than general chart parsers on near-deterministic input, but its reduction search is
`O(n^{p})` in the longest right-hand side `p`; the variants of Farshi (Nozohoor-Farshi),
and later Scott & Johnstone's `RNGLR`/`BRNGLR`, repair both the **hidden-left-recursion /
ε-rule non-termination** bug in Tomita's original and the super-cubic bound, achieving
worst-case **`O(n^3)`** — the same cubic ceiling as [Earley and CYK](./general-parsing.md),
but with `LR`-table-driven _linear_ behaviour on the deterministic majority of the input.

### Complexity and the grammar-class hierarchy

The deterministic `LR` driver visits each input symbol a bounded number of times and does
`O(1)` table-lookup work per shift/reduce, so it is **`O(n)`** in time and **`O(n)`** in
stack space; the table is fixed by the grammar (state count: `LR(0)`/`SLR`/`LALR` share the
`LR(0)` size; canonical `LR(1)` can be an order of magnitude larger). The methods form a
**strict** power hierarchy by the set of grammars each handles:

```text
LR(0)  ⊊  SLR(1)  ⊊  LALR(1)  ⊊  LR(1)  ⊆  LR(k)        (grammar classes; all ⊊ unambiguous CFG)
                                    │
   all four recognise exactly the   ⊊   deterministic context-free LANGUAGES
   deterministic CF languages       │   ⊊  context-free LANGUAGES  ← GLR / Earley / CYK reach here
```

Each containment is **strict at the grammar level**: there are `SLR(1)` grammars that are
not `LR(0)`, `LALR(1)` grammars that are not `SLR(1)`, and `LR(1)` grammars that are not
`LALR(1)` (the classic witness is a grammar whose `LALR` state-merge unions two lookahead
sets into a reduce/reduce conflict that canonical `LR(1)` keeps apart). At the **language**
level the picture flattens: Knuth proved every `LR(k)` language is already `LR(1)`, and all
of `SLR(1)`/`LALR(1)`/`LR(1)` recognise exactly the deterministic context-free languages —
so the hierarchy is about which _grammars_ you may write, not which _languages_ you may
recognise. Against [top-down `LL(k)`](./top-down.md): `LR(k)` is strictly more powerful than
`LL(k)` (every `LL(k)` grammar is `LR(k)`, but not conversely — `LR` decides the production
_after_ seeing its whole right-hand side, `LL` must commit at the start), and `LR` admits
left recursion that `LL`/recursive descent cannot.

### Power & limits

Deterministic `LR` recognises **exactly** the deterministic context-free languages — those
accepted by a deterministic pushdown automaton — and the `LR(1)` _grammar_ class is the
largest of the four for which a conflict-free one-symbol-lookahead table exists. It cannot
handle inherently ambiguous languages, nor non-`LR(k)` grammars such as Knuth's `S → aAc,
A → bAb, A → b` (no finite lookahead locates the handle). `GLR` lifts both limits: it
parses **every** context-free grammar, ambiguous or not, returning the `SPPF` of all
derivations. What no member of the family escapes is context sensitivity — neither `LR` nor
`GLR` decides `a^n b^n c^n` or C's typedef-name/identifier overlap without a side channel
(GLR _explores_ the ambiguity, but a semantic predicate or post-pass must still choose).

### Ambiguity handling

For deterministic `LR`, ambiguity surfaces as a **conflict** at table-construction time —
a compile-time defect resolved by precedence/associativity declarations, by `%expect`-style
suppression, or by rewriting the grammar (see [§ Conflicts](#conflicts-and-their-resolution)).
For `GLR`, ambiguity is **not** an error: every alternative is pursued, and where two parses
reduce to the same symbol over the same span they are **packed** into one `SPPF` node. Bison
lets the grammar author either resolve statically with precedence, or supply a `%merge`
function called on the competing semantic values when the last two parsers reunite ([Bison
§1.5][bison-glr]). [Tree-sitter](../tree-sitter.md) takes the same two-tier stance:
ambiguity is resolved "at compile-time via precedence annotations, and at run-time via the
GLR algorithm."

### Error detection & recovery

`LR` parsers have the **viable-prefix property**: the parser announces an error at the
_first_ terminal that cannot extend the stack to a viable prefix — i.e. as early as any
left-to-right parser possibly can. This crisp, immediate detection is a signature advantage
over backtracking [top-down](./top-down.md) and [PEG/packrat](./peg-packrat.md) parsers,
which can consume far past the real error before failing. Canonical `LR(1)` is the gold
standard here — "for every left context of every canonical LR state, the set of tokens
accepted by that state is guaranteed to be the exact set of tokens that is syntactically
acceptable in that left context" ([Bison §5.8.1][bison-lr]) — whereas `LALR`/`SLR`, having
broader lookahead sets, may perform a few **erroneous reductions** before detecting the
error (they never shift a wrong token, but they may reduce on a lookahead that is valid for
the merged state but not the true context). Recovery is the family's weak spot: yacc-style
generators rely on an explicit `error` token and synchronisation symbols, a coarse mechanism
compared with the principled recovery that motivated [Menhir's](../menhir.md) and
[Tree-sitter's](../tree-sitter.md) designs.

### Performance & complexity

Deterministic `LR` is the **fastest** general parsing technique: linear time, a small
constant per token (one table lookup and a stack push/pop), and no backtracking. The
[DeRemer & Pennello][deremer-pdf] construction made even the _build_ step cheap — linear in
the relations, "fewer than 15 percent of the set unions performed by … `YACC`." `GLR` pays
only where the grammar is genuinely nondeterministic: it runs in **linear time on the
deterministic parts** of the input (the `GSS` never splits) and degrades to at worst cubic
where ambiguity proliferates. This "pay for what you use" profile is why `GLR` underpins
incremental tooling — [Tree-sitter](../tree-sitter.md) combines a `GLR` core with Wagner &
Graham's incremental algorithm to re-parse only the edited region of a file.

### Where it shows up in practice

| Tool                                         | Method                                                   | Notes                                                                                 |
| -------------------------------------------- | -------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| [yacc][yacc-doc] / [Bison](../bison-yacc.md) | `LALR(1)` (default), `IELR(1)`, canonical `LR(1)`, `GLR` | the reference generator; precedence declarations; `%glr-parser` for nondeterminism    |
| [Menhir](../menhir.md)                       | full `LR(1)` (Pager's minimal automaton)                 | OCaml; richer conflict explanations, `.messages` error catalogues                     |
| [Tree-sitter](../tree-sitter.md)             | `GLR` + incremental (Wagner–Graham)                      | LR(1) grammars, compile-time precedence + runtime GLR; editor/IDE incremental reparse |

These are surveyed in their own deep-dives; this document is the theory behind them.

---

## Strengths

- **Maximal deterministic power.** `LR(1)` accepts the largest natural grammar class
  parseable left-to-right with one symbol of lookahead — strictly more than `LL(k)`, and it
  swallows left recursion that recursive descent cannot.
- **Linear time, small constant.** One table lookup per shift/reduce; no backtracking, no
  memoisation table. The fastest general technique.
- **Earliest possible error detection** via the viable-prefix property — errors are
  flagged at the exact offending token.
- **Mechanical generation.** The `LR(0)` automaton and `LALR` lookaheads are computed by
  closure/`GOTO` and the `Digraph` SCC pass; a generator turns a grammar into a table with
  no hand-tuning.
- **Declarative conflict control.** Precedence/associativity declarations collapse operator
  ambiguity without rewriting the grammar.
- **GLR generality.** The same machinery, ungated, parses _any_ CFG in cubic time while
  staying linear on the deterministic majority — and supports incremental reparsing.

## Weaknesses

- **Conflicts are opaque.** A shift/reduce or reduce/reduce conflict reported on a state
  number is notoriously hard to trace back to the offending grammar interaction; `LALR`
  merges make some conflicts "mysterious" ([Bison §5.8.1][bison-lr]). Counterexample
  generators and [Menhir](../menhir.md)'s explanations exist precisely to mitigate this.
- **Grammar must be massaged.** Many readable grammars are not `LALR(1)`; getting them
  conflict-free demands factoring or precedence hacks, an expertise barrier.
- **Table size vs power trade-off.** Canonical `LR(1)` tables can be an order of magnitude
  larger than `LALR(1)`; you choose between full power and compactness.
- **Poor built-in error recovery.** The classic `error`-token mechanism is crude next to
  modern approaches.
- **No semantics during a GLR split.** While multiple `GLR` parsers are live, actions are
  deferred and may be discarded — side-effecting actions are unsafe until the split resolves
  ([Bison §1.5][bison-glr]).
- **Not human-writable.** Unlike recursive descent, `LR` tables are machine artefacts; you
  debug the grammar, never the parser.

---

## Key design decisions and trade-offs

| Decision                                                             | Rationale                                                                                                       | Trade-off                                                                                                             |
| -------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| Recognise the **rightmost derivation in reverse** via handle pruning | Lets a `DFA` over viable prefixes locate handles; decision deferred until the whole RHS is seen → maximal power | Decisions are postponed, so error blame and conflict diagnosis are less local than top-down's                         |
| Use the **`LR(0)` automaton** as the shared engine                   | One closure/`GOTO` construction drives every method; viable prefixes are regular ([Knuth][knuth-pdf])           | The automaton alone (`LR(0)`) is too weak; every practical method bolts lookahead onto it                             |
| **`SLR(1)`: FOLLOW-set lookahead**                                   | Cheapest possible — one global set per nonterminal                                                              | Global context conflates left contexts → spurious conflicts on many real grammars                                     |
| **`LALR(1)`: merge same-core `LR(1)` states**                        | Keeps `LR(0)` state count (deployable) while giving per-state lookahead; the [yacc][yacc-doc] sweet spot        | Merging can union lookaheads into a reduce/reduce conflict a true `LR(1)` would avoid — "mysterious" conflicts        |
| Compute `LALR` lookaheads by **relations + `Digraph` SCC**           | Linear in the relations; far fewer set-unions than naïve LR(1)-and-merge ([DeRemer & Pennello][deremer-pdf])    | Indirection: the four relations (`reads`, `includes`, `lookback`, `DR`) are subtle to implement and to teach          |
| **Canonical `LR(1)`: lookahead per item**                            | Full deterministic power; exact-context error detection                                                         | State explosion — tables an order of magnitude larger; `IELR`/Pager exist to recover compactness                      |
| Resolve conflicts with **precedence/associativity**                  | Declarative, keeps the grammar readable, collapses operator ambiguity to a few states                           | Hides genuine ambiguity behind a silent default; misuse masks real grammar bugs                                       |
| **GLR: pursue all actions on a `GSS`, pack into an `SPPF`**          | Parses any CFG; linear on deterministic input, cubic worst case; enables incremental reparsing                  | Polynomial (not linear) worst case; deferred/ambiguous semantics; original Tomita Alg. loops on hidden left recursion |

---

## Sources

- **Donald E. Knuth (1965)**, _On the Translation of Languages from Left to Right_,
  _Information and Control_ 8(6):607–639 — the paper that defines `LR(k)`, handle pruning,
  viable prefixes as a regular language, and the connection to deterministic languages.
  [DOI / ScienceDirect][knuth-sd]; [PDF][knuth-pdf].
- **Frank DeRemer & Thomas Pennello (1982)**, _Efficient Computation of `LALR(1)`
  Look-Ahead Sets_, _ACM TOPLAS_ 4(4):615–649 — the `reads`/`includes`/`lookback`/`DR`
  relations, the `LA`/`Follow`/`Read`/`DR` decomposition, the linear `Digraph` algorithm,
  and the not-`LR(k)` SCC diagnostics. [ACM DL][deremer-acm]; [PDF][deremer-pdf]. (LALR
  itself: DeRemer's 1969 MIT Ph.D. thesis, _Practical Translators for `LR(k)` Languages_.)
- **Masaru Tomita (1985)**, _Efficient Parsing for Natural Language: A Fast Algorithm for
  Practical Systems_, Kluwer — the graph-structured stack and shared packed parse forest;
  Algorithms 0–4. [Springer][tomita-book]. Reference exposition: [_Generalised LR
  parsing_][glr-book].
- **Aho, Lam, Sethi & Ullman**, _Compilers: Principles, Techniques, and Tools_ ("the
  [Dragon Book][dragon]"), ch. 4.5–4.9 — items, `CLOSURE`/`GOTO`, the canonical collection,
  `SLR`/`LALR`/canonical `LR` tables, and the viable-prefix theorem.
- **Grune & Jacobs**, _Parsing Techniques: A Practical Guide_ (2nd ed.), chs. 9–11 —
  deterministic bottom-up parsing, the `LR` family, and the generalized (`GLR`/Tomita)
  algorithms, with the cubic-time variants.
- **GNU Bison manual** — the deployed view: the shift-reduce [algorithm][bison-algo],
  [shift/reduce conflicts][bison-sr] and the dangling-else, [LR table construction][bison-lr]
  (`lalr`/`ielr`/`canonical-lr`), and [GLR parsing][bison-glr]. See [Bison](../bison-yacc.md).

<!-- References -->

[knuth-pdf]: https://harrymoreno.com/assets/greatPapersInCompSci/2.5_-_On_the_translation_of_languages_from_left_to_right-Donald_E._Knuth.pdf
[knuth-sd]: https://www.sciencedirect.com/science/article/pii/S0019995865904262
[deremer-pdf]: http://3e8.org/pub/scheme/doc/parsing/Efficient%20Computation%20of%20LALR(1)%20Look-Ahead%20Sets.pdf
[deremer-acm]: https://dl.acm.org/doi/10.1145/69622.357187
[tomita-book]: https://link.springer.com/book/10.1007/978-1-4757-1885-0
[glr-book]: https://xrtero.github.io/glr_book/4%20Generalised%20LR%20parsing.html
[dragon]: https://www.pearson.com/en-us/subject-catalog/p/compilers-principles-techniques-and-tools/P200000003472
[yacc-doc]: https://pubs.opengroup.org/onlinepubs/9699919799/utilities/yacc.html
[bison-algo]: https://www.gnu.org/software/bison/manual/html_node/Algorithm.html
[bison-sr]: https://www.gnu.org/software/bison/manual/html_node/Shift_002fReduce.html
[bison-lr]: https://www.gnu.org/software/bison/manual/html_node/LR-Table-Construction.html
[bison-glr]: https://www.gnu.org/software/bison/manual/html_node/GLR-Parsers.html
