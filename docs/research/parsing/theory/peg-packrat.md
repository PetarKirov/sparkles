# Parsing Expression Grammars & Packrat Parsing

A _recognition-based_ syntactic foundation: a grammar formalism (PEGs) whose
**ordered choice** replaces the nondeterministic `|` of context-free grammars with a
prioritized, first-match-wins `/`, making the grammar **unambiguous by construction**
and **scannerless** (lexical + hierarchical syntax in one description); plus the
**packrat** parsing algorithm that runs any PEG in **linear time** by memoizing every
`(rule, position)` result. PEGs sit at the recursive-descent end of the
[parsing taxonomy][top-down], formalizing the backtracking that ad-hoc top-down
parsers do informally — and pinning down exactly when it is cheap.

## At a glance

| Dimension               | Where PEGs / packrat land                                                                                                                         |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Grammar class**       | Parsing Expression Grammars — a 4-tuple `(V_N, V_T, R, e_S)` of rules over the operators in [the operator table](#the-operators)                  |
| **Language class**      | Includes all deterministic `LR(k)` languages **and** some non-context-free languages (`aⁿbⁿcⁿ`); whether it covers all CFLs is open (see below)   |
| **Decision rule**       | _Prioritized choice_ `e₁ / e₂` — try `e₁`; only if it fails, try `e₂`. First match wins, unconditionally                                          |
| **Lookahead**           | Unbounded — syntactic predicates `&e` / `!e` can look ahead over arbitrary nonterminals, not just `k` terminals                                   |
| **Ambiguity**           | **None by construction** — `⇒_G` is a _function_; every string has at most one parse                                                              |
| **Canonical algorithm** | _Packrat parsing_ (Ford 2002): recursive descent + full memoization of `(rule, position) → result`                                                |
| **Worst-case time**     | **O(n)** with memoization; **exponential** for naive backtracking PEGs without it                                                                 |
| **Worst-case space**    | **O(n)** — the memo table is "a possibly substantial constant multiple of the input size" ([Ford 2002][packrat-icfp], §5.3)                       |
| **Left recursion**      | Naive packrat loops forever; supported via [Warth et al. 2008][warth-pepm] (seed-growing) or [Medeiros et al.][medeiros] (bounded left recursion) |
| **Theoretical roots**   | Birman & Ullman's `TS`/`TDPL` and `gTS`/`GTDPL` (c. 1970), to which any PEG reduces ([Ford 2004][peg-popl], §4)                                   |
| **Real-world tools**    | [`pest`][pest] (Rust), [`rust-peg`/`peg`][peg-crate], Lua's [LPeg][lpeg], [`PEG.js`][pegjs], `Rats!`, ANTLR's `&`/`!` predicates ([antlr][antlr]) |

> [!NOTE]
> This is the [theory-tree][theory-index] entry for the recognition-based / top-down-with-memoization
> family. The [`pest`][pest] deep-dive covers one production PEG engine in detail; the
> [parser-combinator][parsec] family (Parsec, `nom`, `chumsky`) shares PEG-like ordered
> choice but is CFG-flavoured and usually backtracks without memoization. The dual of
> packrat memoization on the _CFG_ side — Brzozowski derivatives — is [derivatives][derivatives].

---

## Overview / motivation

### The problem: CFGs over-promise ambiguity

Chomsky's context-free grammars were designed to _model natural language_, where the
power to express ambiguity is a feature. For machine-oriented languages — which are
designed to be precise and unambiguous — that same power is a liability. Ford's POPL
2004 paper opens on exactly this tension:

> "The power of generative grammars to express ambiguity is crucial to their original
> purpose of modelling natural languages, but this very power makes it unnecessarily
> difficult both to express and to parse machine-oriented languages using CFGs. Parsing
> Expression Grammars (PEGs) provide an alternative, recognition-based formal foundation
> for describing machine-oriented syntax, which solves the ambiguity problem by not
> introducing ambiguity in the first place." — [Ford 2004][peg-popl], Abstract

A **generative** system (a CFG, a regular expression) defines a language by _rules that
generate_ its strings. A **recognition-based** system defines a language by _rules that
decide_ whether a given string is in it. PEGs are recognition-based: a PEG _is_ a formal
description of a top-down parser. The single design move that makes the difference is the
**prioritized choice** operator `/`:

> "A key difference is that in place of the unordered choice operator `|` used to indicate
> alternative expansions for a nonterminal in EBNF, PEGs use a prioritized choice operator
> `/`. This operator lists alternative patterns to be tested in order, unconditionally
> using the first successful match." — [Ford 2004][peg-popl], §1

The consequence stated as an equation: the EBNF rules `A → a b | a` and `A → a | a b` are
_equivalent_ in a CFG, but the PEG rules `A ← a b / a` and `A ← a / a b` are _different_.
In the second PEG rule, the alternative `a b` "will never succeed because the first choice
is always taken if the input string to be recognized begins with `a`." Ordered choice is
a _commitment_: once an alternative matches, the others are silently discarded.

### Why this matters for parsing

Two properties fall out of recognition + ordered choice, and they are the reason PEGs are
attractive in practice:

1. **Unambiguous by construction.** There is never a question of "which of two parses is
   meant" — the grammar's `/` operators answer it deterministically. Ford proves the core
   relation `⇒_G` is a _function_ (a given expression on a given input yields exactly one
   outcome). The Medeiros et al. survey of PEGs restates this crisply: _"Unlike CFGs, PEGs
   are unambiguous by construction"_ ([Medeiros et al.][medeiros], §1).

2. **Scannerless.** Because the same operators express both greedy lexical rules (an
   identifier is "as many letter-characters as possible") and recursive hierarchical rules,
   a single PEG describes a whole language with no separate lexer:

   > "PEGs address frequently felt expressiveness limitations of CFGs and REs, simplifying
   > syntax definitions and making it unnecessary to separate their lexical and hierarchical
   > components." — [Ford 2004][peg-popl], Abstract

The cost — and PEGs do not hide it — is that ordered choice makes the _language_ a PEG
describes harder to reason about than a CFG's: the grammar author "should be closer to the
mindset of the programmer of a hand-written parser than the mindset of a grammar writer"
([Medeiros et al.][medeiros], §1). See [Power & limits](#power--limits) for the
longest-match-vs-first-match surprise that follows.

### The packrat half: linear time, despite backtracking

A PEG is "a formal description of a top-down parser" — and the natural way to run a
top-down parser with ordered choice is **backtracking recursive descent**. That is simple
and powerful, but "backtracking parsers … can exhibit exponential runtime"
([Ford 2002][packrat-icfp], §1), because the same parse function gets called on the same
input position over and over while different alternatives are tried. _Packrat parsing_ is
the fix:

> "Packrat parsing provides the simplicity, elegance, and generality of the backtracking
> model, but eliminates the risk of super-linear parse time, by saving all intermediate
> parsing results as they are computed and ensuring that no result is evaluated more than
> once." — [Ford 2002][packrat-icfp], §1

The theoretical foundations were "worked out in the 1970s" (Birman & Ullman's `TDPL`/`GTDPL`)
"but the linear-time version was apparently never put in practice due to the limited memory
sizes of computers at that time." Packrat trades **space for time**: it remembers
everything. The rest of this doc works through both halves precisely.

---

## How it works

### The operators

A PEG is the 4-tuple `G = (V_N, V_T, R, e_S)`: nonterminals `V_N`, terminals `V_T`, a rule
set `R` (a _function_ assigning each `A ∈ V_N` exactly one expression, so there are no
"undefined references"), and a start expression `e_S` ([Ford 2004][peg-popl], §3.1). The
parsing expressions are built from these operators (precedence high → low):

| Operator        | Name                   | Meaning                                                                         |
| --------------- | ---------------------- | ------------------------------------------------------------------------------- |
| `' '` `[ ]` `.` | primary                | literal string, character class, any-character                                  |
| `(e)`           | grouping               | precedence override                                                             |
| `e?`            | optional               | match `e` if present, else succeed consuming nothing — **greedy**               |
| `e*`            | zero-or-more           | match `e` as many times as possible — **greedy**, never backtracks a repetition |
| `e+`            | one-or-more            | `e e*`                                                                          |
| `&e`            | **and-predicate**      | succeed iff `e` matches here, but **consume nothing** (syntactic lookahead)     |
| `!e`            | **not-predicate**      | succeed iff `e` **fails** here, consuming nothing (negative lookahead)          |
| `e₁ e₂`         | sequence               | match `e₁` then `e₂`; backtrack to the start if either fails                    |
| `e₁ / e₂`       | **prioritized choice** | try `e₁`; if it fails, try `e₂` from the same position — **first match wins**   |

The abstract syntax needs only seven of these; the rest are _syntactic sugar_
([Ford 2004][peg-popl], §3.2): `e?` desugars to `e / ε`, `e+` to `e e*`, and crucially the
and-predicate `&e` desugars to `!(!e)` — the not-predicate `!` is the primitive, and `&` is
double negation. The four primitive operators with semantic weight are **sequence**,
**ordered choice** `/`, **greedy repetition** `*`, and the **not-predicate** `!`.

The `*`, `+`, `?` operators "behave as in common regular expression syntax, except that
they are 'greedy' rather than nondeterministic" — they "always consume as many successive
matches of `e` as possible," and that decision is _committed_, never reconsidered. Ford's
sharp illustration: _"The expression `a* a` for example can never match any string"_
([Ford 2004][peg-popl], §2), because `a*` greedily eats every `a`, leaving none for the
trailing `a`. This is the most common PEG footgun and a direct consequence of
no-backtracking-into-a-repetition.

### Syntactic predicates: unbounded lookahead

The predicates `&e` and `!e` "provide much of the practical expressive power of PEGs"
([Ford 2004][peg-popl], §2). They _match without consuming_:

> "The expression `&e` attempts to match pattern `e`, then unconditionally backtracks to the
> starting point, preserving only the knowledge of whether `e` succeeded or failed to match.
> Conversely, the expression `!e` fails if `e` succeeds, but succeeds if `e` fails."
> — [Ford 2004][peg-popl], §2

Two canonical uses from Ford's self-describing grammar:

```ebnf
# A comment runs to (but not over) the end of line:
Comment    <- '#' (!EndOfLine .)* EndOfLine
# An Identifier on a rule's RHS must not be the LHS of the next Definition:
Primary    <- Identifier !LEFTARROW / OPEN Expression CLOSE / ...
```

In `(!EndOfLine .)*`, the not-predicate `!EndOfLine` guards the any-character `.`: "matches
any single character as long as the nonterminal `EndOfLine` does not match starting at the
same position." The `Identifier !LEFTARROW` lookahead lets a token-level rule peek at
_grammatical structure_ ("is this followed by a `<-`?"), which a `k`-token lexer cannot do.
Predicates "can involve arbitrary parsing expressions requiring any amount of 'lookahead.'"

### The formal semantics in one relation

Ford defines a relation `(e, x) ⇒ (n, o)`: parsing expression `e` on input string `x` takes
`n` steps and produces outcome `o`, where `o` is either the consumed prefix (success) or the
distinguished symbol `f` (failure). The ordered-choice rules are the heart of it
([Ford 2004][peg-popl], §3.3):

> "**Alternation (case 1):** If `(e₁, xy) ⇒ (n₁, x)`, then `(e₁/e₂, xy) ⇒ (n₁+1, x)`.
> Alternative `e₁` is first tested, and if it succeeds, the expression `e₁/e₂` succeeds
> without testing `e₂`.
> **Alternation (case 2):** If `(e₁, x) ⇒ (n₁, f)` and `(e₂, x) ⇒ (n₂, o)`, then
> `(e₁/e₂, x) ⇒ (n₁+n₂+1, o)`. If `e₁` fails, then `e₂` is tested and its result is used
> instead." — [Ford 2004][peg-popl], §3.3

That `⇒_G` is provably a **function** ("If `(e, x) ⇒ (n₁, o₁)` and `(e, x) ⇒ (n₂, o₂)`, then
`n₁ = n₂` and `o₁ = o₂`") is the formal statement of "unambiguous by construction." There is
exactly one outcome, full stop.

A second key theorem is the **`*`-loop condition**: a repetition `e*` does _not_ handle any
input on which `e` succeeds while consuming nothing (it would loop forever). This is why a
PEG that is _well-formed_ — no left recursion, no nullable repetition — is _complete_ (it
either succeeds or fails on every input). Well-formedness is a checkable structural property
that guarantees termination.

### Packrat parsing: recursive descent + a memo table

The packrat algorithm starts from an ordinary backtracking recursive-descent parser: one
function per nonterminal, each taking the input position and returning success (with the
remainder) or failure. For Ford's arithmetic grammar:

```text
Additive  ← Multitive '+' Additive | Multitive
Multitive ← Primary '*' Multitive | Primary
Primary   ← '(' Additive ')' | Decimal
Decimal   ← '0' | ... | '9'
```

the function `pAdditive` first tries `Multitive '+' Additive`; on failure it backtracks and
tries `Multitive` alone. The redundancy is immediate: on a bare multiplicative expression,
`pMultitive` is called twice at the same position — once in the failing first alternative,
once in the second. Compound this across nesting and you get exponential blow-up. Ford
names the cause precisely:

> "The basic reason the backtracking parser can take super-linear time is because of
> redundant calls to the same parse function on the same input substring, and these
> redundant calls can be eliminated through memoization." — [Ford 2002][packrat-icfp], §2.3

The fix is a **result matrix**: one row per parse function, one column per input position.
For input of length `n` there are only `n+1` distinct positions and a fixed number `k` of
nonterminals, so at most `k(n+1)` distinct results exist. Fill each cell once; on a repeat
call, look it up:

> "We can avoid computing any of these intermediate results multiple times by storing them
> in a table. … By the time we compute the result for a given cell, the results of all
> would-be recursive calls in the corresponding parse function will already have been
> computed and recorded elsewhere in the table; we merely need to look up and use the
> appropriate results." — [Ford 2002][packrat-icfp], §2.3

The **forward-pointer** trick is what gives unbounded lookahead at constant per-cell cost: a
success result stores _which column_ the remainder starts at, so consuming a `(3+4)`
sub-expression is one lookup that jumps from column C3 to column C7. "This ability to skip
ahead arbitrary distances while making parsing decisions is the source of the algorithm's
unlimited lookahead capability."

### The "lazy" implementation: a self-referential `Derivs`

Ford's "functional pearl" packs the matrix into a recursive Haskell data structure — one
`Derivs` record per input position, with one field per nonterminal plus a `dvChar` field for
the raw character. Each field is the (lazily evaluated) parse result at that position:

```haskell
data Derivs = Derivs {
    dvAdditive  :: Result Int,
    dvMultitive :: Result Int,
    dvPrimary   :: Result Int,
    dvDecimal   :: Result Int,
    dvChar      :: Result Char }

data Result v = Parsed v Derivs   -- value + remainder (a *later* Derivs)
              | NoParse
```

A parse function takes a `Derivs` and reads sibling/forward fields instead of recursing
directly; the top-level `parse` ties the knot, building exactly `n+1` `Derivs` instances and
referring to itself. Laziness _is_ the memoization: "once a result is computed for the first
time, it is stored for future use by subsequent calls," and a given cell "will never be
evaluated twice." No hash table, no array — "ordinary algebraic data types"
([Ford 2002][packrat-icfp], §2.4).

### Complexity analysis

**Time — O(n).** The top-level function creates exactly `n+1` `Derivs` instances; each parse
function "examines at most a fixed number of other cells while computing a given result";
the lazy evaluator ensures "each cell is evaluated at most once." A constant amount of work
per cell × `O(n)` cells = `O(n)`. The Birman–Ullman insight is that this linearity needs
**no prediction and no grammar restriction** — unlike `LL(k)`/`LR(k)`, which buy linearity
by restricting the grammar class.

> [!WARNING]
> The linear-time guarantee is fragile in one specific way: it assumes each cell costs
> `O(1)`. Ford's own combinator library warns that _iterative_ combinators (a hand-written
> `many` loop inside a parse function) "effectively create 'hidden' recursion whose
> intermediate results are not memoized in the result matrix, potentially making the parser
> run in super-linear time" ([Ford 2002][packrat-icfp], §3.3). Memoize at the rule
> granularity, or the guarantee leaks.

**Space — O(n), and that is the headline cost.** Packrat's defining tradeoff:

> "The main disadvantage of packrat parsing is its space consumption. Although its asymptotic
> worst-case bound is the same as those of conventional algorithms—linear in the size of the
> input—its space utilization is directly proportional to input size rather than maximum
> recursion depth, which may differ by orders of magnitude." — [Ford 2002][packrat-icfp], §1

A packrat parser "literally squirrels away everything it has ever computed about the input
text, including the entire input text itself" (§5.3). `LL(k)`/`LR(k)` and plain backtracking
parsers can run in space proportional to nesting _depth_ (often orders of magnitude smaller).
Ford's measurements on Java source: a fully-monadic packrat parser used **695 bytes of live
heap per input byte**, a hybrid parser 301 — "a possibly substantial constant multiple of the
input size" but tolerable on modern machines for typical 10–100 KB source files. For
flat, machine-generated data (XML streams) where the lookahead power is wasted, "its storage
cost would not be justified."

### The grammar-class hierarchy this family occupies

Packrat recognizes **a strict superset of `LL(k)` and `LR(k)`** in linear time:

> "Any language defined by an `LL(k)` or `LR(k)` grammar can be recognized by a packrat
> parser, in addition to many languages that conventional linear-time algorithms do not
> support." — [Ford 2002][packrat-icfp], Abstract

The extra power is the unbounded lookahead. Ford's example grammar — `S ← A | B`,
`A ← x A y | x z y`, `B ← x B y y | x z y y` — "is not `LR(k)` for any `k`" because an
`LR` parser must commit to `A` vs `B` after seeing `z` and one `y`, before it has counted the
`y`s. A packrat parser "essentially operates in a speculative fashion, producing derivations
for nonterminals `A` and `B` in parallel," deciding only at the end which succeeded. This is
why packrat grammars **compose**: substituting a nonterminal for a terminal never "breaks"
the parser, since lookahead can range over nonterminals — the property that makes
[`pest`][pest]-style scannerless grammars and extensible syntax practical.

---

## Power & limits

### What PEGs can express that CFGs cannot

PEGs reach **outside** the context-free languages. Ford's proof uses the canonical
non-context-free language `aⁿbⁿcⁿ`:

> "The classic example language `aⁿbⁿcⁿ` is not context-free, but we can recognize it with a
> PEG" — [Ford 2004][peg-popl], §3.4

```ebnf
A ← a A b / ε          # matches aⁿbⁿ
B ← b B c / ε          # matches bⁿcⁿ
D ← &(A !b) a* B !.    # both, with the input fully consumed
```

The `&`-predicate intersects two languages — `&(A !b)` asserts the input starts with `aⁿbⁿ`,
then `a* B` consumes `aⁿ` and matches `bⁿcⁿ`, and `!.` (end-of-input) forces a full match. The
**intersection** and **complement** that and/not-predicates provide are exactly what take PEGs
beyond CFGs: parsing expression languages are "closed under union, intersection, and
complement" (§3.4) — CFLs are not closed under intersection or complement.

### What PEGs (probably) cannot express — and the open question

The relationship runs the other way too: it is _suspected_ but **not proven** that there are
CFLs no PEG can recognize. Ford is candid:

> "These properties strongly suggest that CFGs and PEGs define incomparable language classes,
> although a formal proof that there are context-free languages not expressible via PEGs
> appears surprisingly elusive." — [Ford 2004][peg-popl], §1

What _is_ known: Birman proved `TS`/`gTS` simulate any deterministic pushdown automaton, so
PEGs express **every deterministic `LR`-class CFL**; "there is informal evidence, however,
that a much larger class of CFGs might be recognizable with PEGs" (§5). The honest summary is
that PEGs and CFGs are believed incomparable, the deterministic CFLs are common ground, and
the exact boundary remains an open problem more than two decades on.

### The longest-match-vs-first-match surprise

Ordered choice does not just _remove_ ambiguity — it _silently resolves_ what would have been
CFG ambiguity, and the resolution is **first-match**, not **longest-match**. The two differ.
A choice `"a" | "ab"` on input `"abc"` matches just `"a"` and leaves `"bc"` unparsed, because
the first alternative wins even though the second would consume more. The
[`pest` book][pest-peg] states the discipline directly:

> "The choice operator, written as a vertical line `|`, is ordered. The PEG expression
> `first | second` means 'try `first`; but if it fails, try `second` instead.'" — [pest book][pest-peg]

And on commitment: "If it succeeds, the next step is performed as usual. But if it fails, the
whole expression fails. The engine will not back up and try again." This is a double-edged
sword. It eliminates the dangling-`else` problem cleanly — `IF Cond THEN S ELSE S / IF Cond
THEN S` binds the `ELSE` to the nearest `IF` automatically ([Ford 2004][peg-popl], §2.3) — but
it also means a misordered choice can _hide a productive alternative forever_ (the
`A ← a / a b` case), and there is no guarantee that this greedy matching will find the
globally longest match. The grammar author, not the formalism, owns disambiguation. As Ford
puts it, the challenge is no longer "are these two CFG alternatives ambiguous?" but the
"analogous challenge of determining whether two alternatives in a `/` expression can be
reordered without affecting the language" — which "is undecidable in general."

### Statelessness and determinism

Packrat's memoization "assumes that the parsing function for each nonterminal depends only on
the input string, and not on any other information accumulated during the parsing process"
([Ford 2002][packrat-icfp], §5.2). Languages needing a symbol table mid-parse (C/C++
distinguishing `typedef` names) break this: "the parser must start building a new result
matrix each time the parsing state changes," so stateful packrat "may be impractical if state
changes occur frequently." Likewise packrat is for _deterministic_ parsers — "parsers that can
produce at most one result"; it cannot return a parse forest for a genuinely ambiguous natural
language (use a [general parser][general] for that).

## Ambiguity handling

There is no ambiguity to handle: **PEGs are unambiguous by construction.** This is the
formalism's central selling point and follows from `⇒_G` being a function. Where a CFG-based
generator (`yacc`/`bison`, see [bison-yacc][bison]) reports shift/reduce and reduce/reduce
conflicts that the grammar author must understand and resolve, a PEG simply commits to the
first matching alternative — "there are no ambiguities and no shift-reduce/reduce-reduce
conflicts, which can be difficult to resolve" ([Warth et al. 2008][warth-pepm], §1). The
flip side, restated for emphasis: the disambiguation is _arbitrary unless the author orders
the choices deliberately_. A PEG never _warns_ you that two alternatives overlap; it just
picks the first. Tools cannot in general decide whether a `/` is order-sensitive (it is
"undecidable in general"), though conservative analyses for the common cases are an open
research direction Ford explicitly flags.

## Error detection & recovery

Error reporting is a genuine **weakness** of vanilla packrat. Because backtracking is
pervasive and silent, a failed parse backtracks all the way out and typically reports failure
at the _start_ position, not at the point of maximal progress — the parser tried many
alternatives and "the engine will not back up and try again" once a committed step fails, so
the most informative failure (the furthest the parser got) is easily lost. Production engines
bolt on heuristics: track the **farthest failure position** across all attempts and report
that, the approach popularized by Parsec-style combinators and adopted by [`pest`][pest]
(which surfaces the set of rules expected at the farthest position). Recovery — resynchronizing
after an error to keep parsing — is not part of the PEG/packrat model and must be added with
explicit error-productions or sentinel rules. Contrast this with `LR` parsers, whose
single-left-to-right scan localizes errors naturally, and with [tree-sitter][tree-sitter],
whose incremental `GLR`-derived engine is built around error recovery for IDE use.

## Performance & complexity

The numbers, consolidated:

| Quantity                    | Packrat (memoized)                                                 | Naive backtracking PEG        | `LL(k)` / `LR(k)`          |
| --------------------------- | ------------------------------------------------------------------ | ----------------------------- | -------------------------- |
| **Worst-case time**         | **O(n)**                                                           | **exponential** in worst case | O(n)                       |
| **Worst-case space**        | **O(n)** (full memo table)                                         | O(depth)                      | O(depth) (O(n) worst case) |
| **Lookahead**               | unbounded (terminals **and** nonterminals)                         | unbounded                     | constant `k` terminals     |
| **Per-cell cost**           | O(1) — _if_ rules are the memo granularity                         | n/a                           | O(1)                       |
| **Constant factor (space)** | ~300–700 bytes/input-byte measured ([Ford 2002][packrat-icfp], §6) | tiny                          | tiny                       |

The linear-time result is **constructive and grammar-class-free**: any PEG, reduced to
`GTDPL` form, parses in linear time on a RAM machine ([Ford 2004][peg-popl], §4.4.1, Corollary).
That is the qualitative win over general CFG parsing, which "is inherently super-linear" — at
best `O(n³)` in general, and tied to boolean matrix multiplication lower bounds (Lee 2002). The
qualitative win over `LL`/`LR` is the lookahead and composability; the loss is the space
constant and the absence of left recursion in the base algorithm (next section).

## Left recursion

The one structural rule a PEG must obey is **no left recursion**, and it is the same reason
every top-down parser shares: `A ← A a / a` says "to recognize `A`, first recognize `A`," a
degenerate loop. Ford bans it at the grammar level — a _well-formed_ PEG "contains no directly
or mutually left-recursive rules" ([Ford 2004][peg-popl], §3.6) — and a naive packrat parser
that ignores the ban "would simply [retrieve] the previous result" of a not-yet-computed cell,
"create a circular data dependency," and fail (or, in an imperative implementation, recurse
until the stack overflows). Warth et al. quote the folklore directly: _"like other recursive
descent parsers, packrat parsers cannot support left-recursion"_ ([Warth et al.][warth-pepm], §1).

The classic workaround is **left-recursion elimination** — rewrite `A ← A a / b` as
`A ← b a*` — which `Pappy` and `Rats!` do automatically for _direct_ recursion. But it is
"overly simplistic": a correct transform "must preserve the left-associativity of the parse
trees … as well as the meaning of the original rule's semantic actions," and crucially it does
not handle **indirect** (mutual) left recursion, which "does in fact arise in real-world
grammars" — Java's `Primary` rule is indirectly left-recursive through five others.

### Warth–Douglass–Millstein: seed-growing (PEPM 2008)

The first algorithm to support direct _and_ indirect left recursion in a packrat parser
without rewriting the grammar modifies the memo mechanism itself:

> "This paper presents a modification to the memoization mechanism used by packrat parser
> implementations that makes it possible for them to support (even indirectly or mutually)
> left-recursive rules." — [Warth et al. 2008][warth-pepm], Abstract

The mechanism, in two moves:

1. **Plant a failing seed.** Before evaluating a rule's body, `APPLY-RULE` stores a `FAIL`
   result for `(R, P)` in the memo table. A left-recursive re-entry now _finds_ that `FAIL`
   and aborts the left-recursive alternative instead of looping — so the rule first matches via
   a _non_-left-recursive path. That non-recursive match is the **seed parse**.

2. **Grow the seed.** `GROW-LR` re-evaluates the rule's body repeatedly, each time
   backtracking to `P` but with the previous (now-successful) result in the memo table, so the
   left-recursive alternative can fire and consume _more_ input each iteration. The loop stops
   when an iteration makes no progress ("`ans = FAIL or Pos ≤ M.pos`"):

   > "We refer to this iterative process as growing the seed … Each time the rule's body is
   > evaluated, the parser must backtrack to `P`. … At the start of each iteration, `M` contains
   > the last successful result of the left recursion." — [Warth et al.][warth-pepm], §3.2

Indirect recursion needs more bookkeeping: a **rule invocation stack** identifies the **head**
rule of a left-recursion loop and the set of rules **involved** in it (the `LR`, `HEAD`,
`involvedSet`/`evalSet` structures, §3.4). While growing the head's seed, "we bypass the
memo table and re-evaluate the body of any rule involved in the left recursion" ([Warth et
al.][warth-pepm], §3.3). Warth et al. are upfront about the cost: a packrat parser with
their modification "to yield super-linear parse times for some left-recursive grammars,"
though "this is not the case for typical uses of left recursion."

### Medeiros–Mascarenhas–Ierusalimschy: bounded left recursion

A later, more declarative account gives left recursion a clean _semantics_ rather than an
algorithmic patch — **bounded left recursion**:

> "Intuitively, bounded left recursion is a use of a non-terminal where we limit the number of
> left-recursive uses it may have. … We use the notation `Aⁿ` to mean a non-terminal where we
> can have less than `n` left-recursive uses, with `A⁰` being an expression that always fails."
> — [Medeiros et al.][medeiros], §3

For `E ← E + n / n` the bounds unfold as a progression: `E⁰ ← fail`, `E¹ = n`,
`E² = n + n / n`, `E³ = (n + n / n) + n / n`, … Matching tries increasing bounds and **keeps
the bound that matches the longest prefix**:

> "It is sufficient to increase the bound until the size of the matched prefix stops
> increasing." — [Medeiros et al.][medeiros], §3

The formalization adds rules `lvar.1`–`lvar.4` and a memo table `L`: the first left-recursive
use of `A` matches `A¹` (production with all left-recursive uses failing via `lvar.3`); if it
succeeds the result is stored and a bigger bound is tried (`lvar.1`), iterating to a fixed
point. Indirect and even mutual left-and-right recursion "is not a problem, as the bounds are
on left-recursive _uses_ of a non-terminal, which are a property of the proof tree, and not of
the structure of the PEG." The paper proves the extension **conservative** (non-left-recursive
PEGs behave identically) and that it "work[s] with any left-recursive PEG" — and extends a
low-level _parsing machine_ to execute it, the route by which `LPeg`-style engines and CPython's
new PEG parser support left recursion in production.

> [!NOTE]
> The two approaches converge on the same observed behaviour for ordinary left-associative
> operators but differ in spirit: Warth et al. patch the _memoization algorithm_; Medeiros et
> al. give a _denotational semantics_ (`Aⁿ`) and prove properties about it. A subtle
> consequence of the bounded semantics is that increasing the bound can sometimes match a
> _shorter_ prefix (the ordered-choice surprise again), which is exactly why the "grow until
> the prefix stops growing" rule is needed rather than a naive fixed point.

## Where it shows up in practice

| Tool / engine                   | Language      | Role                                                                                                                                               |
| ------------------------------- | ------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`pest`][pest]                  | Rust          | The flagship Rust PEG generator; derives a parser from a `.pest` grammar — see the [deep-dive][pest]                                               |
| `rust-peg` / [`peg`][peg-crate] | Rust          | `peg!{}` macro PEG generator; ordered choice, `&`/`!` predicates                                                                                   |
| [LPeg][lpeg]                    | Lua           | Roberto Ierusalimschy's PEG library; compiles PEGs to a parsing machine (the Medeiros et al. target)                                               |
| [PEG.js][pegjs] / Peggy         | JavaScript    | Browser/Node PEG generators                                                                                                                        |
| `Rats!`, `Pappy`                | Java, Haskell | Early packrat generators with automatic direct-left-recursion elimination ([Warth][warth-pepm], §1)                                                |
| CPython `pegen`                 | Python        | Since 3.9, CPython's grammar is parsed by a PEG parser (PEP 617) with left-recursion support                                                       |
| [ANTLR][antlr]                  | Java (multi)  | Not packrat, but its and-predicate `&` was Parr's contribution that Ford adopted; the not-predicate `!` was new in Ford ([peg-popl][peg-popl], §6) |

> [!IMPORTANT]
> Be careful not to conflate PEGs with **parser combinators** ([Parsec][parsec], [`nom`][nom],
> [`chumsky`][chumsky]). Combinators share ordered choice (`<|>` / `alt`) and run top-down, but
> they are CFG-flavoured, usually **do not memoize** (so are not linear-time in general), and
> often restrict backtracking by default (Parsec's `try`). A combinator library _can_ be made
> packrat (Ford's own combinator library is one), but most are not. The defining packrat
> property is the `(rule, position)` memo table, not the combinator surface syntax.

---

## Strengths

- **Unambiguous by construction.** No conflicts, no parse forests, no disambiguation
  meta-rules; the grammar _is_ the disambiguation. `⇒_G` is a function.
- **Linear time for any PEG** with packrat memoization — no grammar-class restriction, no
  prediction tables, no `LR`-conflict wrangling.
- **Unbounded lookahead over nonterminals** via `&`/`!`, expressing followed-by /
  not-followed-by / longest-match directly — idioms that are awkward or impossible in `LL(k)`/`LR(k)`.
- **Scannerless / unified grammars.** One grammar covers lexical and hierarchical syntax;
  greedy `*`/`+` give the "maximal-munch" identifier rule for free, and tokens may have
  recursive structure (nestable comments, expressions inside string escapes).
- **Composable.** Substituting a nonterminal for a terminal never breaks the parser, because
  lookahead ranges over nonterminals — ideal for extensible / embedded syntax.
- **More powerful than `LR`** in language class (deterministic CFLs **plus** some
  non-context-free languages like `aⁿbⁿcⁿ`).
- **Simple to implement and reason about** — "the same simplicity and elegance as recursive
  descent parsing" ([Ford 2002][packrat-icfp], Abstract).

## Weaknesses

- **Space-intensive.** O(n) memory, with a large constant (hundreds of bytes per input byte
  measured) — the defining tradeoff. Unsuitable for huge, flat inputs (e.g. XML streams).
- **No left recursion in the base algorithm.** Naive packrat loops or fails; left recursion
  needs the [Warth][warth-pepm] or [Medeiros][medeiros] extensions, which can reintroduce
  super-linear time for pathological grammars.
- **First-match, not longest-match.** A misordered `/` can silently swallow a productive
  alternative; the formalism never warns you, and order-sensitivity is undecidable in general.
- **Poor default error messages.** Pervasive silent backtracking loses the point of maximal
  progress; usable diagnostics require bolt-on farthest-failure tracking.
- **Stateless by assumption.** Context-sensitive features (a live symbol table) break memoization
  unless the matrix is rebuilt on each state change — impractical if state changes often.
- **Deterministic only.** Cannot produce the multiple parses a genuinely ambiguous (natural-language)
  grammar needs — that is the province of [general parsers][general].
- **Harder to reason about the language.** Author "mindset" is that of a hand-written-parser
  programmer, not a grammar writer; whether `L(G₁) = L(G₂)` is undecidable.

## Key design decisions and trade-offs

| Decision                                              | Rationale                                                                                              | Trade-off                                                                                                  |
| ----------------------------------------------------- | ------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------- |
| **Prioritized choice `/`** (vs. unordered CFG choice) | Removes ambiguity at the source; `⇒_G` is a function; dangling-`else` "just works"                     | First-match ≠ longest-match; a misordered `/` silently hides an alternative; order-sensitivity undecidable |
| **Recognition-based, scannerless**                    | One grammar for lexical + hierarchical syntax; greedy `*` gives maximal-munch; tokens can be recursive | Greedy `*` never backtracks (`a* a` matches nothing); "more rope" for the careless designer                |
| **Syntactic predicates `&` / `!`**                    | Unbounded lookahead over nonterminals; followed-by / not-followed-by; intersection & complement        | Pushes PEGs past CFGs; makes language-equivalence and emptiness undecidable                                |
| **Full `(rule, position)` memoization** (packrat)     | Turns exponential backtracking into guaranteed O(n); unbounded lookahead at O(1) per cell              | O(n) space with a large constant — "everything it has ever computed," ~300–700 B/input-byte                |
| **Lazy / data-recursive memo (`Derivs`)**             | Memoization "for free" in a non-strict language; no hash tables; compute only what's needed            | Needs a lazy host (or an explicit table); iterative combinators leak the O(1)-per-cell assumption          |
| **Ban left recursion** (well-formedness requirement)  | Guarantees termination; well-formedness is a cheap structural check implying completeness              | Left-associative operators need rewriting or the seed-growing / bounded-recursion extensions               |
| **Statelessness assumption**                          | Lets memoization be sound and lookahead cheap                                                          | Context-sensitive grammars (C `typedef`) force matrix rebuilds; impractical under frequent state change    |

---

## Sources

**Seminal papers**

- Bryan Ford, **"Parsing Expression Grammars: A Recognition-Based Syntactic Foundation"**,
  POPL 2004 — the PEG formalism: operators, the `⇒_G` semantics, `aⁿbⁿcⁿ`, the
  `TDPL`/`GTDPL` reduction, undecidability results. [PDF][peg-popl].
- Bryan Ford, **"Packrat Parsing: Simple, Powerful, Lazy, Linear Time"**, ICFP 2002 —
  the linear-time memoized algorithm, `Derivs`, the space tradeoff, the `LL`/`LR` comparison.
  [PDF][packrat-icfp].
- Bryan Ford, **"Packrat Parsing: a Practical Linear-Time Algorithm with Backtracking"**, MIT
  master's thesis, Sept. 2002 — the full development. Index: [bford.info/packrat][packrat-home].
- Alessandro Warth, James R. Douglass, Todd Millstein, **"Packrat Parsers Can Support Left
  Recursion"**, PEPM 2008 — the seed-growing memoization modification for direct and indirect
  left recursion. [PDF][warth-pepm].
- Sérgio Medeiros, Fabio Mascarenhas, Roberto Ierusalimschy, **"Left Recursion in Parsing
  Expression Grammars"**, Science of Computer Programming 96 (2014) / SBLP 2012 — bounded left
  recursion as a conservative semantic extension; the parsing-machine implementation.
  [arXiv:1207.0443][medeiros].

**Tools & docs**

- [`pest` — the Rust PEG parser generator][pest] · [the pest book, "Parsing Expression Grammars"][pest-peg]
- [Bryan Ford's Packrat Parsing & PEGs page][packrat-home]
- Dick Grune & Ceriel J.H. Jacobs, _Parsing Techniques — A Practical Guide_ — the standard
  textbook context for the "library of parsing algorithms with diverse capabilities and
  trade-offs" Ford situates PEGs within ([Ford 2004][peg-popl], §1, ref. [9]).

**Related deep-dives in this tree:** [top-down parsing][top-down] · [bottom-up / `LR`][bottom-up] ·
[general parsing][general] · [Brzozowski derivatives][derivatives] · [`pest`][pest] ·
[parser combinators (Parsec)][parsec] · [`nom`][nom] · [`chumsky`][chumsky] · [ANTLR][antlr] ·
[`bison`/`yacc`][bison] · [tree-sitter][tree-sitter] · [the theory index][theory-index] ·
[the parsing umbrella][umbrella] · [concepts glossary][concepts] · [comparison][comparison].

<!-- References -->

<!-- Papers & external -->

[peg-popl]: https://bford.info/pub/lang/peg.pdf
[packrat-icfp]: https://bford.info/pub/lang/packrat-icfp02.pdf
[packrat-home]: https://bford.info/packrat/
[warth-pepm]: https://web.cs.ucla.edu/~todd/research/pepm08.pdf
[medeiros]: https://arxiv.org/abs/1207.0443
[pest-peg]: https://pest.rs/book/grammars/peg.html
[peg-crate]: https://crates.io/crates/peg
[pegjs]: https://web.archive.org/web/20260530055107/https://pegjs.org/
[lpeg]: https://www.inf.puc-rio.br/~roberto/lpeg/

<!-- Sibling theory docs -->

[theory-index]: ./index.md
[top-down]: ./top-down.md
[bottom-up]: ./bottom-up.md
[general]: ./general-parsing.md
[derivatives]: ./derivatives.md

<!-- Tree-level docs -->

[umbrella]: ../index.md
[concepts]: ../concepts.md
[comparison]: ../comparison.md

<!-- Library deep-dives -->

[pest]: ../pest.md
[parsec]: ../haskell-parsec.md
[nom]: ../rust-nom.md
[chumsky]: ../rust-chumsky.md
[antlr]: ../antlr.md
[bison]: ../bison-yacc.md
[tree-sitter]: ../tree-sitter.md
