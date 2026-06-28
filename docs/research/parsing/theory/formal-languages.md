# Formal Languages & the Parsing Problem

The theoretical floor under every parser in this catalog: the [Chomsky hierarchy][chomsky-hierarchy]
of grammars, the [automata][automata] that recognize each level, and the decidability and
complexity walls that decide _which_ parsing algorithms are even possible. This is the doc
that defines _what a grammar is_, _what parsing computes_, and _why_ the practical families —
[top-down][top-down], [bottom-up][bottom-up], [general][general], [PEG/packrat][peg], — exist
and where they sit. Read it before any algorithm deep-dive; it is the shared vocabulary the
rest of the [theory tree][theory-index] assumes.

---

## At a glance

The four levels of the Chomsky hierarchy, the grammar restriction that defines each, the
machine that recognizes it, and where in this catalog the level actually shows up. The
membership column is the cost of answering "is this string in the language?" — the question
parsing generalizes.

| Type  | Grammar class                         | Production form (`A` nonterminal; `α`,`β`,`γ` strings) | Recognizer                                 | Membership cost                                  | Where it shows up in this catalog                                                                                                                      |
| ----- | ------------------------------------- | ------------------------------------------------------ | ------------------------------------------ | ------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **3** | [Regular][regular]                    | `A → a` or `A → aB` (right-linear)                     | DFA / NFA (no memory beyond state)         | `O(n)`, `O(1)` space                             | Lexers / tokenizers feeding every parser; the SIMD stage-1 classifier in [simdjson][simdjson]                                                          |
| **2** | [Context-free][cfg] (CFG)             | `A → γ` (single nonterminal LHS, any RHS)              | Nondeterministic [pushdown automaton][pda] | `O(n³)` general; `O(n)` for deterministic subset | The backbone of every parser here: [Bison/yacc][bison], [ANTLR][antlr], [Menhir][menhir], [tree-sitter][ts]                                            |
| **1** | [Context-sensitive][csl] (CSG)        | `αAβ → αγβ`, `γ ≠ ε` (rewrite `A` _in context_)        | Linear-bounded automaton (LBA)             | `PSPACE`-complete (decidable)                    | Not used as a parsing formalism; the "context-sensitive patches" real languages bolt onto a CFG ([below](#why-real-languages-are-mostly-context-free)) |
| **0** | Unrestricted (recursively enumerable) | `γ → α`, `γ ≠ ε` (any rewrite)                         | Turing machine                             | Undecidable in general                           | Out of scope — equivalent to general computation                                                                                                       |

> [!NOTE]
> Parsing theory lives almost entirely in **Type 2 and Type 3**. Type 1 is a foil — it
> bounds what a grammar _could_ express but is too costly to parse with, so real languages
> stay context-free and handle the few genuinely context-sensitive constructs out-of-band
> (the [lexer hack](#the-lexer-hack-typedef-vs-identifier), [significant indentation](#significant-indentation-and-the-off-side-rule),
> here-docs). Type 0 is general computation and never a parsing target.

---

## Overview / motivation

A **grammar** is a finite set of rewrite rules that _generates_ a (usually infinite) set of
strings — its **language**. **Parsing** is the inverse: given a string, recover the structure
the grammar would have used to generate it. Grune & Jacobs open _Parsing Techniques_ with the
definition this whole catalog inherits:

> "Parsing is the process of structuring a linear representation in accordance with a given
> grammar." — Grune & Jacobs, _Parsing Techniques: A Practical Guide_ ([source][grune])

The "linear representation" is the input (a token stream, a byte stream); the "structure" is a
[parse tree][parse-tree] (or the actions/AST a parser builds while walking it implicitly). The
hierarchy that ranks grammars by expressive power is Noam Chomsky's, introduced in 1956 to
argue that no _finite-state_ device suffices for natural language. Chomsky's abstract states
the negative result that motivates everything above Type 3:

> "We find that no finite-state Markov process that produces symbols with transition from
> state to state can serve as an English grammar." — Chomsky, "Three models for the
> description of language" (1956) ([source][chomsky56])

The same negative result reappears, transposed, for programming languages: a regular language
(Type 3) cannot count nesting depth, so it cannot match `(`/`)` or `if`/`end` — you need at
least a stack, i.e. a [pushdown automaton][pda] and a context-free grammar. But you do _not_
want to climb higher than you must: Type 1 (context-sensitive) recognition is `PSPACE`-complete
and Type 0 is undecidable. The art of practical parsing is staying in Type 2, carving out the
_deterministic_ subset of Type 2 that parses in linear time, and patching the handful of
constructs that genuinely escape it.

The Dragon Book frames syntax analysis around exactly this choice — context-free grammars are
the formalism because they are expressive enough for nesting yet cheap enough to parse:

> "By design, every programming language has precise rules that prescribe the syntactic
> structure of well-formed programs. … The syntax of programming language constructs can be
> specified by context-free grammars or BNF (Backus-Naur Form) notation." — Aho, Lam, Sethi &
> Ullman, _Compilers: Principles, Techniques, and Tools_, 2nd ed. ([Dragon Book][dragon])

This doc unpacks that sentence: what the grammar classes are, which machine recognizes each,
what they can and cannot express (closure + pumping lemmas), what is undecidable, what general
CF parsing costs (the [Valiant][valiant] / [Lee][lee] matrix-multiplication frontier), and why
"context-free" is an _almost_-truth that every production parser has to patch.

---

## How it works

### Grammars formally — the four-tuple

A grammar is a 4-tuple `G = (N, Σ, P, S)`: a finite set of **nonterminals** `N` (syntactic
variables), a finite set of **terminals** `Σ` (the alphabet — tokens, for a programming
language), a finite set of **productions** `P` (rewrite rules `α → β`), and a distinguished
**start symbol** `S ∈ N`. The grammar's language `L(G)` is every terminal string derivable
from `S` by repeated rewriting:

```text
L(G) = { w ∈ Σ*  |  S ⇒* w }
```

where `⇒*` is the reflexive-transitive closure of the single-step rewrite `⇒`. The four
Chomsky types are exactly four restrictions on the _shape_ of the productions in `P`, ordered
by strictly decreasing expressive power.

### The Chomsky hierarchy, level by level

**Type 3 — regular.** Every production is `A → a` or `A → aB` (right-linear; the mirror,
left-linear, is equally regular but you cannot mix the two). One nonterminal on the left, at
most one on the right, always in the same position. This restriction is exactly what lets a
recognizer get away with _no memory but its current state_: a [finite automaton][regular]. The
canonical example of a language that is _not_ regular is `{ aⁿbⁿ | n ≥ 0 }` — matching the
count of `a`s to `b`s needs unbounded memory a DFA does not have.

**Type 2 — context-free.** Every production is `A → γ`: a _single_ nonterminal on the left,
any string `γ ∈ (N ∪ Σ)*` on the right. The "context-free" name is literal — `A` rewrites to
`γ` regardless of what surrounds `A`. This is the level at which nesting becomes expressible
(`S → ( S ) | ε` generates balanced parentheses) and the level every parser in this catalog
targets. The recognizing machine is the [pushdown automaton][pda] — a finite control plus a
single unbounded **stack**, which is precisely the memory needed to track nesting depth.

```bnf
; A grammar of balanced parentheses — context-free, not regular.
S ::= "(" S ")" S
    | ε
```

**Type 1 — context-sensitive.** Every production is `αAβ → αγβ` with `γ` nonempty: you may
rewrite `A` to `γ`, but only _in the context_ `α … β`. (Equivalently, no production shrinks the
string — `|αAβ| ≤ |αγβ|` — which is why these are also called "noncontracting" grammars.) This
is what it takes to express the cross-serial dependency `{ aⁿbⁿcⁿ | n ≥ 1 }` that the
[context-free pumping lemma](#the-pumping-lemmas-the-non-membership-tools) rules out for Type 2.
The recognizer is a **linear-bounded automaton** — a Turing machine whose tape is bounded to a
constant multiple of the input length. Kuroda's theorem identifies the context-sensitive
languages with `NSPACE(n)` exactly ([Wikipedia: context-sensitive language][csl-wiki]).

**Type 0 — unrestricted.** Productions `γ → α` with `γ` nonempty and _no other constraint_.
This is full rewriting; the language class is the **recursively enumerable** sets and the
recognizer is an unrestricted **Turing machine**. Membership is only semi-decidable.

The containment is strict at every step: regular ⊊ context-free ⊊ context-sensitive ⊊
recursively enumerable. Each `⊊` is witnessed by a separating language — `{aⁿbⁿ}` separates
regular from CF, `{aⁿbⁿcⁿ}` separates CF from CS — and each separation is proved with a
**pumping lemma**.

### Derivations, parse trees, and ambiguity

A **derivation** is a sequence of rewrites `S ⇒ … ⇒ w`. For a CFG, a derivation induces a
**parse tree**: `S` at the root, each interior node a nonterminal whose children are the RHS of
the production applied, leaves spelling out `w` left to right. A **leftmost derivation** always
expands the leftmost nonterminal first; it is in bijection with parse trees, so "two parse
trees" and "two leftmost derivations" are the same phenomenon. A grammar is **ambiguous** when
some string has more than one parse tree:

> "[An ambiguous grammar is] a context-free grammar for which there exists a string that can
> have more than one … parse tree." — [Wikipedia: ambiguous grammar][ambig-wiki]

The textbook ambiguous grammar is unparenthesized arithmetic, which leaves operator precedence
and associativity unresolved:

```bnf
; Ambiguous: "1 - 2 - 3" has two parse trees,
;   (1 - 2) - 3   and   1 - (2 - 3),  with different values.
E ::= E "-" E
    | digit
```

The fix is to encode precedence/associativity into the grammar's _shape_ (left-recursive rules
for left-associative operators, a rule layer per precedence level) — the bread and butter of
[bottom-up][bottom-up] and [Pratt/precedence][pratt] parsers — or to resolve it with a
disambiguation rule outside the grammar.

### The membership/recognition problem and the CF parsing bound

The decision problem "given grammar `G` and string `w`, is `w ∈ L(G)`?" is the **recognition
problem**; producing the witnessing parse tree is the **parsing problem**. For a general CFG,
the dynamic-programming recognizer is **CYK** (Cocke–Younger–Kasami), which fills an `O(n²)`
table of which nonterminals derive which substring, in:

> "the worst case running time of CYK is `O(n³ · |G|)`" — over a grammar in Chomsky normal
> form, with `O(n²)` space. — [Wikipedia: CYK algorithm][cyk-wiki]

[Earley's algorithm][earley] (1970) recognizes any CFG directly (no normal-form rewrite, and it
tolerates left recursion and ε-rules) with the _same_ `O(n³)` worst case but better behavior on
well-behaved grammars — `O(n²)` for unambiguous grammars and `O(n)` on the deterministic class
that covers most programming languages. Earley's own abstract states the three-tier bound:

> "[It has] a time bound proportional to n³ … in general; … n² for unambiguous grammars, and
> linear time on a large class of grammars." — Earley, "An efficient context-free parsing
> algorithm" (1970) ([CACM 13(2)][earley-cacm])

Both algorithms are charted in [general-parsing][general]. The cubic wall is not laziness —
it is fundamental. Valiant showed in 1975 that CF recognition reduces to **Boolean matrix
multiplication**, dragging the asymptotic exponent down to the matrix-multiply exponent `ω`:

> "Valiant showed that Boolean matrix multiplication can be used for parsing context-free
> grammars (CFGs), yielding the asymptotically fastest (although not practical) CFG parsing
> algorithm known." — Lee, "Fast context-free grammar parsing requires fast Boolean matrix
> multiplication" ([JACM][lee])

Plugging in fast matrix multiplication gives `O(n^2.38 · |G|)` ([CYK/Valiant][cyk-wiki]); with
the current record `ω < 2.371339` ([Quanta, 2024][quanta]) the exponent edges lower still — but
every such algorithm is **galactic**: the hidden constant makes it slower than cubic CYK on any
real input. The frontier is two-sided. Lee proved the _converse_ — a sub-cubic CF parser would
_imply_ a sub-cubic Boolean matrix multiply:

> "any CFG parser with time complexity `O(gn^(3-ε))` … can be efficiently converted into an
> algorithm to multiply `m`-by-`m` Boolean matrices in time `O(m^(3-ε/3))`. … we thus explain
> why there has been little progress in developing practical, substantially sub-cubic general
> CFG parsers." — Lee ([JACM][lee])

This is _why_ the practical world abandons "general CFG" almost everywhere: a parser that runs
in linear time can only do so by restricting the grammar to a deterministic subclass (LL, LR,
LALR, [PEG][peg]) — which is exactly what [top-down][top-down] and [bottom-up][bottom-up]
parsing are. General CFG parsing is reserved for cases where the grammar genuinely needs it
(natural language, ambiguous tooling grammars) and is delivered by [Earley][earley] or
[GLR][bison].

### The grammar-class hierarchy this family occupies

```text
                          recognizing machine          parsing-this-catalog
  Type 0  recursively enumerable  ── Turing machine          (out of scope)
            ⊋
  Type 1  context-sensitive       ── linear-bounded automaton (foil; "patches")
            ⊋
  Type 2  context-free            ── pushdown automaton       ← THE parsing level
            │   ⊋ deterministic CF (DPDA) ── LR(1)/LALR/LL    ← linear-time subset
            ⊋
  Type 3  regular                 ── finite automaton         ← lexers, SIMD classifier
```

The single most important practical fact is the split _inside_ Type 2: the **deterministic
context-free languages** (those a deterministic pushdown automaton accepts) are exactly the
languages with an `LR(1)` grammar (Knuth, 1965), and they parse in `O(n)`. Everything in
[top-down][top-down] and [bottom-up][bottom-up] is a strategy for staying in — or near — that
deterministic subset.

---

## Power & limits

What each level can and cannot express is pinned down by **closure properties** (which language
operations keep you inside the class) and **pumping lemmas** (the tools that prove a language is
_not_ in a class).

### Closure properties

| Operation                 | Regular (Type 3) |      Context-free (Type 2)      |
| ------------------------- | :--------------: | :-----------------------------: |
| Union `L₁ ∪ L₂`           |        ✅        |               ✅                |
| Concatenation `L₁L₂`      |        ✅        |               ✅                |
| Kleene star `L*`          |        ✅        |               ✅                |
| Intersection `L₁ ∩ L₂`    |        ✅        | ❌ (e.g. `{aⁿbⁿcᵐ} ∩ {aᵐbⁿcⁿ}`) |
| Complement `L̄`            |        ✅        |               ❌                |
| ∩ with a regular language |        ✅        |               ✅                |

Regular languages are closed under _all_ Boolean operations — union, intersection, and
complement ([Wikipedia: regular language][regular-wiki]) — which is why a lexer specified as a
union of token patterns is still regular and still recognizable by a single DFA. Context-free
languages are closed under union, concatenation, and star, but **not** under intersection or
complement ([closure properties][cfl-closure]). The failure of intersection closure is the
formal reason you cannot just "intersect a few context-free constraints" to express
`{aⁿbⁿcⁿ}` — each pairwise count is context-free, their conjunction is not.

> [!IMPORTANT]
> CF closure under **intersection with a _regular_ language** is the one closure property
> parsers exploit constantly: it means you can run a regular lexer in front of a context-free
> parser and the composite is still context-free. The token stream is a regular projection of
> the source; the parser consumes that projection. This is the theoretical license for the
> universal **lexer → parser** pipeline.

### The pumping lemmas — the non-membership tools

A pumping lemma says every _sufficiently long_ string in the class contains a substring you can
repeat ("pump") and stay in the language. Contrapositively, exhibit a long string with no such
substring and you have proved the language is _outside_ the class.

**Regular (pumping lemma for regular languages).** Every regular `L` has a pumping length `p`;
every `s ∈ L` with `|s| ≥ p` splits as `s = xyz` with `|y| ≥ 1`, `|xy| ≤ p`, and
`xyⁱz ∈ L` for all `i ≥ 0`. Applied to `{aⁿbⁿ}`: the pumpable `y` falls entirely within the
`a`-block, so pumping changes the `a`-count without the `b`-count — out of the language. Hence
`{aⁿbⁿ}` is **not regular**, and a DFA-only parser cannot match nesting.

**Context-free (Bar-Hillel / uvwxy lemma).** Every CFL `L` has a `p`; every `s ∈ L` with
`|s| ≥ p` splits as `s = uvwxy` with `|vx| ≥ 1`, `|vwx| ≤ p`, and `uvⁱwxⁱy ∈ L` for all
`i ≥ 0` ([Wikipedia: CF pumping lemma][cf-pump]). Applied to `{aⁿbⁿcⁿ}`: any short `vwx`
straddles at most two of the three letter-blocks, so pumping cannot keep all three counts equal:

> "`uvⁱwxⁱy` does not contain equal numbers of each letter for any `i ≠ 1`." —
> [Wikipedia: CF pumping lemma][cf-pump]

So `{aⁿbⁿcⁿ}` is **not context-free** — and that single language is the prototype of every
genuinely context-sensitive feature in a real programming language (see
[below](#why-real-languages-are-mostly-context-free)).

### Ambiguity handling

Ambiguity is a property of a _grammar_; **inherent ambiguity** is a property of a _language_ —
one for which _every_ grammar is ambiguous. The classic witness is the union

```text
L = { aⁿbⁿcᵐdᵐ | n,m > 0 }  ∪  { aⁿbᵐcᵐdⁿ | n,m > 0 }
```

> "No context-free grammar for this union language can unambiguously parse strings of form
> `aⁿbⁿcⁿdⁿ`." — [Wikipedia: ambiguous grammar][ambig-wiki]

The string `aⁿbⁿcⁿdⁿ` qualifies for membership under _both_ halves of the union, and no single
grammar can avoid offering two derivations for it. Inherent ambiguity matters because it tells
you _no amount of grammar rewriting_ will buy a deterministic parser — the language itself
forks. How the algorithm families cope:

- **Deterministic parsers** ([LL][top-down], [LR/LALR][bottom-up]) _reject_ ambiguity at
  construction time: a shift/reduce or reduce/reduce conflict in the table is the generator
  telling you the grammar is not in its deterministic class. [Bison/yacc][bison] resolves such
  conflicts with precedence declarations or a default (shift), trading a clean error for a
  silent choice.
- **PEG/packrat** ([peg-packrat][peg]) _dissolves_ ambiguity by fiat: its ordered choice `/`
  commits to the first alternative that matches, so a PEG is unambiguous _by definition_ — at
  the cost of possibly hiding the alternative you wanted.
- **General parsers** ([Earley][earley], [GLR][bison]) _embrace_ ambiguity: they return a
  **parse forest** (a shared-packed representation of all parse trees) rather than one tree,
  which is the only honest answer for an inherently ambiguous or deliberately ambiguous grammar.

### Error detection & recovery

Recognition is a yes/no decision, but a usable parser must localize and recover from the "no."
The theory gives one strong guarantee and several practical consequences:

- **Viable-prefix property (LR).** A deterministic [bottom-up][bottom-up] parser detects an
  error at the _earliest_ point where the consumed prefix can no longer be extended to any valid
  string — it never reads past the first offending token before reporting. This is a direct
  consequence of building the parser from the DFA of viable prefixes. [LL][top-down] parsers
  have an analogous early-detection property for their lookahead class.
- **Decidable emptiness ⇒ reachability checks.** Because CFG emptiness is decidable
  ([below](#performance--complexity)), a generator can statically flag unreachable or
  non-productive nonterminals — dead rules that can never appear in any parse — before the
  parser ever runs.
- **Recovery is heuristic, not theoretical.** Panic-mode (skip to a synchronizing token),
  error productions, and [tree-sitter][ts]'s error nodes are engineering responses; the theory
  only guarantees _where_ the error is, not how to continue past it. Incremental/IDE parsers
  ([tree-sitter][ts]) invest heavily here because they must produce a tree for syntactically
  broken, mid-edit source.

### Performance & complexity

| Problem (over CFG `G`, string `w`)              | Status                           | Note                                                                       |
| ----------------------------------------------- | -------------------------------- | -------------------------------------------------------------------------- |
| Membership `w ∈ L(G)` (general CFG)             | `O(n³ · grammar-size)` decidable | CYK / Earley; sub-cubic only galactically ([Valiant][valiant], [Lee][lee]) |
| Membership, deterministic CF (LR(1) grammar)    | `O(n)` decidable                 | The linear-time sweet spot all production parsers chase                    |
| Emptiness `L(G) = ∅?`                           | **decidable**                    | Mark productive/reachable nonterminals; linear in grammar size             |
| Finiteness `L(G)` finite?                       | **decidable**                    | Cycle test on the productive-nonterminal graph                             |
| Equivalence `L(G₁) = L(G₂)?`                    | **undecidable**                  | Reduces from the Post Correspondence Problem (PCP)                         |
| Ambiguity "is `G` ambiguous?"                   | **undecidable**                  | Equivalent to PCP ([ambiguous grammar][ambig-wiki])                        |
| Inherent ambiguity "is `L(G)` inherently amb.?" | **undecidable**                  | —                                                                          |
| Universality `L(G) = Σ*?` / inclusion           | **undecidable**                  | From PCP undecidability                                                    |

The decidability cliff is the practical headline: **emptiness and finiteness are decidable**
(so generators can validate grammars), but **equivalence and ambiguity are undecidable**
([undecidable problems for CFGs][cfg-undec]). The undecidability of ambiguity is why no parser
generator can warn you "your grammar is ambiguous" in general — [Bison][bison] reports
_conflicts_ (a decidable, grammar-class-specific symptom) rather than ambiguity (the
undecidable property). The undecidability of equivalence is why you cannot mechanically prove
two grammars describe the same language, which is why grammar refactoring is tested, not proved.

Context-sensitive (Type 1) recognition stays _decidable_ — every CSL is recursive — but the
membership problem is `PSPACE`-complete ([context-sensitive language][csl-wiki]), far outside
the linear-time budget a compiler front-end can spend per token. That single complexity fact is
why no production language is parsed as a Type-1 language.

### Where it shows up in practice

Every deep-dive in this catalog is an instance of the choices this doc frames — which grammar
class, which automaton, which point on the determinism/generality/complexity trade-off:

| Theory choice                                       | Realized by                                                                                         |
| --------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| Regular (Type 3) front-end / classifier             | The SIMD stage-1 structural classifier in [simdjson][simdjson]                                      |
| Deterministic CF, bottom-up (LALR/LR)               | [Bison/yacc][bison], [Menhir][menhir] (LR(1))                                                       |
| Deterministic CF, top-down (LL / recursive descent) | [ANTLR][antlr] (ALL(\*)), hand-written recursive descent, [nom][nom]/[chumsky][chumsky] combinators |
| PEG / ordered-choice (Type 2-ish, unambiguous)      | [pest][pest], [Parsec][parsec]-style combinators, [packrat][peg]                                    |
| General CF (parse forests, ambiguity-tolerant)      | [Earley][earley]/[GLR][bison]; [tree-sitter][ts]'s GLR-based incremental engine                     |
| Pratt / operator-precedence (precedence climbing)   | [Pratt parsing][pratt] inside many of the above                                                     |

The capstone [comparison][comparison] places each subject on these axes side by side.

---

## Strengths

- **Predictive power.** The hierarchy tells you, _before_ you write a parser, the cheapest
  machine that can possibly recognize your language — and the pumping lemmas prove when you must
  climb a level. No empirical tuning required.
- **A complexity floor and ceiling.** The Valiant/Lee result fixes the asymptotic cost of
  general CF parsing at the Boolean-matrix-multiply exponent from _both_ sides, so you know
  there is no clever sub-cubic general parser waiting to be discovered.
- **Compositionality.** CF closure under union/concatenation/star, and under intersection with
  a regular language, is what makes grammars _modular_ (combine sub-grammars) and the
  lexer→parser split _sound_.
- **Decidable validation.** Emptiness and finiteness being decidable lets generators catch dead
  and non-productive rules statically.

## Weaknesses

- **The cubic wall for generality.** Any parser that handles _arbitrary_ CFGs pays `O(n³)`;
  escaping it means restricting the grammar (losing generality) — there is no free lunch
  ([Lee][lee]).
- **Undecidability of the questions you most want to ask.** "Is my grammar ambiguous?" and "do
  these two grammars agree?" are both undecidable, so tooling can only approximate them.
- **Context-free is not enough for real languages.** The clean theory stops at the lexer/parser
  boundary; type-name disambiguation, indentation, and here-docs all leak context-sensitivity
  into a nominally context-free pipeline ([below](#why-real-languages-are-mostly-context-free)).
- **The model ignores the leaves.** The hierarchy classifies grammars but says nothing about the
  _lexical_ layer's cost, error messages, or incremental re-parsing — the things that dominate a
  real parser's engineering.

---

## Why real languages are "mostly context-free"

Production languages are advertised as context-free but are not, quite. The grammar is
context-free in the large — nesting, declarations, expressions — with a small number of
**context-sensitive patches** where membership genuinely depends on context that a CFG cannot
carry. Each patch is a tiny instance of the `{aⁿbⁿcⁿ}` phenomenon: a constraint the parser
cannot express as a production and must enforce out-of-band, by feeding information from a side
table (the symbol table) or from a context-aware lexer back into the context-free core.

### The lexer hack (typedef vs identifier)

In C, the very same token `AA` is a _type name_ or an _ordinary identifier_ depending on
whether a `typedef` for it is in scope — and that decision changes the parse:

> "the nasty _typedef-name_ problem that makes the grammar of C ambiguous and requires a hack
> in the lexer." — Eli Bendersky, "The context sensitivity of C's grammar, revisited"
> ([source][bendersky])

The textbook collision is `(A) * B`: a _cast_ of `*B` to type `A` if `A` is a typedef, or a
_multiplication_ `A * B` otherwise. No context-free grammar can decide this, because the
deciding fact (is `A` a typedef?) lives in the [semantic][semantic] symbol table, not in the
token stream. The classic fix — the **lexer hack** — wires a backchannel from semantic analysis
into the lexer:

> "feeding contextual information backwards from the parser to the lexer. … rather than
> functioning as a pure one-way pipeline from the lexer to the parser, there is a backchannel
> from semantic analysis back to the lexer." — [Wikipedia: lexer hack][lexer-hack]

This deliberately breaks the clean recognition→parsing→semantics layering. Clang's modern
alternative keeps the lexer ignorant (`AA` is just an identifier) and disambiguates in the
parser using the semantic library — relocating the context-sensitivity rather than eliminating
it ([lexer hack][lexer-hack]). [Bison][bison] grammars for C either embed the lexer hack or use
GLR to keep both parses alive until a semantic pass prunes one.

### Significant indentation and the off-side rule

Python's block structure is carried by _indentation_, which is not context-free: the validity of
a `DEDENT` depends on the stack of all enclosing indentation levels. Python resolves this in the
lexer, emitting synthetic tokens so the _grammar_ proper can stay context-free:

> "The indentation levels of consecutive lines are used to generate `INDENT` and `DEDENT`
> tokens, using a stack … At the beginning of each logical line, the line's indentation level is
> compared to the top of the stack. If it is larger, it is pushed on the stack, and one `INDENT`
> token is generated. If it is smaller … for each number popped off a `DEDENT` token is
> generated." — [Python Language Reference, §2.1.8 Indentation][python-indent]

The _stack_ in that description is precisely the pushdown power a CFG lacks for this dimension;
moving it into the lexer (an explicit stack the regular machine does not normally have) lets the
parser see a brace-like `INDENT`/`DEDENT` token pair and parse a context-free language over the
augmented token stream. This is Landin's **off-side rule** ([Wikipedia: off-side rule][offside])
mechanized. Haskell's layout rule is the same idea with a more intricate (and famously
non-context-free) resolution.

### Here-documents and other escapes

A Perl/Ruby/shell **here-document** (`<<END … END`) delimits a block by a programmer-chosen
terminator that must reappear verbatim later — the lexer must remember an unbounded,
runtime-chosen string and scan for it, which no fixed regular or context-free rule can express.
Like the typedef and indentation cases, it is handled by a stateful lexer that carries the
pending delimiter as side data. The common shape across all three patches:

> [!WARNING]
> **The patch is always the same move: push the context-sensitive bit out of the grammar and
> into a stateful lexer or a semantic side-table, so the _core grammar stays context-free_.**
> This is why "is language X context-free?" is the wrong question — the engineered _pipeline_ is
> context-free by construction, with the genuinely context-sensitive constraints handled before
> or after the CF parse. A surveyed parser's quality is largely how cleanly it accommodates
> these patches: [tree-sitter][ts] uses external scanners, [ANTLR][antlr] uses semantic
> predicates, [Menhir][menhir]/[Bison][bison] lean on the lexer hack.

### Recognition vs parsing vs semantic analysis

The three patches above clarify a distinction the rest of this catalog assumes:

| Stage                 | Question answered                                  | Machine / data                               | Decidable / cost                                        |
| --------------------- | -------------------------------------------------- | -------------------------------------------- | ------------------------------------------------------- |
| **Recognition**       | _Is `w ∈ L(G)`?_ (yes/no)                          | PDA; CYK/Earley table                        | `O(n³)` general, `O(n)` det.                            |
| **Parsing**           | _What structure did `G` use?_ (parse tree/forest)  | PDA + tree builder; [parse tree][parse-tree] | same asymptotics as recognition                         |
| **Semantic analysis** | _Is `w` well-formed beyond syntax?_ (types, scope) | symbol table, attribute eval — _not_ a CFG   | language-specific; this is where the typedef hack lives |

Recognition is the membership decision; parsing additionally _builds the witness_; semantic
analysis enforces the constraints (declaration-before-use, type agreement, the typedef
disambiguation) that the context-free layer provably cannot — the residue of every
context-sensitive patch ends up here. Keeping the three separate is the architecture the lexer
hack deliberately violates and Clang deliberately restores.

---

## Key design decisions and trade-offs

| Decision                                                     | Rationale                                                                                                                      | Trade-off                                                                                              |
| ------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------ |
| Target **Type 2 (context-free)**, not Type 1                 | CF is the cheapest level expressing nesting; recognizable by a PDA (a stack), parseable in `O(n³)` or `O(n)` deterministically | Cannot express cross-serial/counting constraints (`{aⁿbⁿcⁿ}`); real languages need out-of-band patches |
| Restrict further to **deterministic CF** (LR/LL)             | Buys `O(n)` parsing and early error detection — the only viable budget for a compiler front-end                                | Rejects ambiguous and many natural grammars; shift/reduce conflicts force grammar contortion           |
| Split into **regular lexer → CF parser**                     | Licensed by CF closure under ∩ with a regular language; lexing is `O(n)` and isolates token noise                              | The lexer becomes the dumping ground for context-sensitivity (the lexer hack, indentation, here-docs)  |
| Use a **general parser** (Earley/GLR) when needed            | Handles _any_ CFG incl. ambiguity; returns a parse forest — the honest answer for ambiguous grammars                           | Pays the cubic wall ([Valiant][valiant]/[Lee][lee]); forests are harder to consume than a single tree  |
| Accept **undecidable ambiguity**; report conflicts instead   | Ambiguity is undecidable, but grammar-class conflicts are decidable and locally fixable                                        | Conflict reports are class-specific artifacts, not the true property; default resolutions hide bugs    |
| Push context-sensitivity into **lexer/semantic side tables** | Keeps the core grammar context-free and the parser fast and standard                                                           | Breaks clean layering (recognition→parsing→semantics); couples lexer to symbol table                   |

---

## Sources

Primary literature and authoritative references behind the claims above:

- **Chomsky, N.** (1956). "Three Models for the Description of Language." _IRE Transactions on
  Information Theory_ 2(3):113–124 — the paper that introduces the hierarchy and proves
  finite-state grammars inadequate. ([Semantic Scholar record][chomsky56])
- **Aho, Lam, Sethi & Ullman.** _Compilers: Principles, Techniques, and Tools_ (the "Dragon
  Book"), 2nd ed., chs. 2–4 — context-free grammars as the formalism for programming-language
  syntax. ([PDF][dragon])
- **Grune, D. & Jacobs, C.** _Parsing Techniques: A Practical Guide_, 2nd ed. — the operational
  definition of parsing and a survey of every algorithm family. ([1st-ed. PDF][grune])
- **Hopcroft, Motwani & Ullman.** _Introduction to Automata Theory, Languages, and Computation_
  — the canonical reference for the automata, closure properties, pumping lemmas, and
  decidability results.
- **Earley, J.** (1970). "An Efficient Context-Free Parsing Algorithm." _CACM_ 13(2):94–102 —
  the `O(n³)`/`O(n²)`/`O(n)` general chart parser. ([ACM DL][earley-cacm])
- **Valiant, L. G.** (1975). "General context-free recognition in less than cubic time." _JCSS_
  10(2):308–315 — CF recognition reduced to Boolean matrix multiplication. ([PDF][valiant])
- **Lee, L.** (2002). "Fast context-free grammar parsing requires fast Boolean matrix
  multiplication." _JACM_ 49(1):1–15 — the converse: sub-cubic parsing implies sub-cubic BMM.
  ([abstract][lee])
- **Reference encyclopedia entries** (definitions/statements cross-checked): Chomsky hierarchy,
  context-free grammar, CYK algorithm, Earley parser, pumping lemma (CF), ambiguous grammar,
  context-sensitive language, regular language, lexer hack, off-side rule.
- **Language-specific patches**: Python Language Reference §2.1.8 (indentation/`INDENT`/`DEDENT`)
  ([docs][python-indent]); Eli Bendersky, "The context sensitivity of C's grammar, revisited"
  ([blog][bendersky]).

<!-- References -->

<!-- In-tree -->

[theory-index]: ./index.md
[top-down]: ./top-down.md
[bottom-up]: ./bottom-up.md
[general]: ./general-parsing.md
[peg]: ./peg-packrat.md
[pratt]: ./pratt-precedence.md
[comparison]: ../comparison.md
[concepts]: ../concepts.md
[simdjson]: ../simdjson.md
[ts]: ../tree-sitter.md
[antlr]: ../antlr.md
[bison]: ../bison-yacc.md
[parsec]: ../haskell-parsec.md
[nom]: ../rust-nom.md
[chumsky]: ../rust-chumsky.md
[pest]: ../pest.md
[menhir]: ../menhir.md

<!-- Same-doc anchors used as glossary stand-ins -->

[chomsky-hierarchy]: #how-it-works
[automata]: #the-chomsky-hierarchy-level-by-level
[regular]: #the-chomsky-hierarchy-level-by-level
[cfg]: #grammars-formally--the-four-tuple
[csl]: #the-chomsky-hierarchy-level-by-level
[pda]: #the-chomsky-hierarchy-level-by-level
[parse-tree]: #derivations-parse-trees-and-ambiguity
[earley]: #the-membershiprecognition-problem-and-the-cf-parsing-bound
[valiant]: #the-membershiprecognition-problem-and-the-cf-parsing-bound
[semantic]: #recognition-vs-parsing-vs-semantic-analysis

<!-- External primary sources -->

[chomsky56]: https://www.semanticscholar.org/paper/Three-models-for-the-description-of-language-Chomsky/6e785a402a60353e6e22d6883d3998940dcaea96
[dragon]: https://faculty.sist.shanghaitech.edu.cn/faculty/songfu/cav/Dragon-book.pdf
[grune]: https://dickgrune.com/Books/PTAPG_1st_Edition/BookBody.pdf
[earley-cacm]: https://dl.acm.org/doi/10.1145/362007.362035
[lee]: https://www.cs.cornell.edu/home/llee/papers/bmmcfl-jacm.home.html
[valiant]: http://theory.stanford.edu/~virgi/cs367/papers/valiantcfg.pdf
[cyk-wiki]: https://en.wikipedia.org/wiki/CYK_algorithm
[cf-pump]: https://en.wikipedia.org/wiki/Pumping_lemma_for_context-free_languages
[ambig-wiki]: https://en.wikipedia.org/wiki/Ambiguous_grammar
[csl-wiki]: https://en.wikipedia.org/wiki/Context-sensitive_language
[regular-wiki]: https://en.wikipedia.org/wiki/Regular_language
[cfl-closure]: https://www.cs.unc.edu/~plaisted/comp455/slides/cfl3.5.pdf
[cfg-undec]: https://liacs.leidenuniv.nl/~hoogeboomhj/second/codingcomputations.pdf
[lexer-hack]: https://en.wikipedia.org/wiki/Lexer_hack
[bendersky]: https://eli.thegreenplace.net/2011/05/02/the-context-sensitivity-of-cs-grammar-revisited
[python-indent]: https://docs.python.org/3/reference/lexical_analysis.html
[offside]: https://en.wikipedia.org/wiki/Off-side_rule
[quanta]: https://www.quantamagazine.org/new-breakthrough-brings-matrix-multiplication-closer-to-ideal-20240307/
