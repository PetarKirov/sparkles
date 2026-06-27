# Parsing: Concepts & Vocabulary

The shared glossary for the parsing catalog — the page every deep-dive and theory
leaf links back to for definitions. It fixes the load-bearing terms — _grammar_,
_terminal_/_nonterminal_, _derivation_, _recognition_ vs _parsing_, _parse tree_ /
_AST_ / _CST_, _lexing_ vs _scannerless_, _ambiguity_ and _disambiguation_,
_lookahead_ / _backtracking_ / _determinism_, _memoization_ / _incrementality_ /
_error recovery_ — and grounds each in a textbook, a seminal paper, or a real source
tree, so the algorithm deep-dives ([top-down][top-down], [bottom-up][bottom-up],
[general][general], [PEG/packrat][peg], [Pratt][pratt], [derivatives][deriv]) and the
tool deep-dives can use the words without re-defining them. The deep theoretical
development — the [Chomsky hierarchy][formal], automata, pumping lemmas, decidability,
and the cubic complexity wall — lives one level down in
[Formal Languages & the Parsing Problem][formal]; this page is the practitioner's
vocabulary that sits on top of it. The whole field is laid out side-by-side in the
[at-a-glance landscape table](#the-parser-landscape-at-a-glance) at the bottom, and
synthesized in the [capstone comparison][comparison].

> [!NOTE]
> Two companion glossaries. This file defines the _operational_ vocabulary a reader
> needs to follow any deep-dive; [`theory/formal-languages.md`][formal] develops the
> _formal_ machinery (the four-tuple `G = (N, Σ, P, S)`, the recognizing automata, the
> Valiant/Lee `O(n³)` frontier, the closure and pumping lemmas). Where a term has a
> precise theoretical home, this page links there rather than re-deriving it. The
> [theory index][theory-index] is the map of that lower level.

---

## Grammars and the Chomsky hierarchy

A **grammar** is a finite set of rewrite rules (productions) that _generates_ a
(usually infinite) set of strings — its **language**. **Parsing** is the inverse
problem: given a string, recover the structure the grammar would have used to generate
it. Grune & Jacobs open _Parsing Techniques_ with the definition this whole catalog
inherits:

> "Parsing is the process of structuring a linear representation in accordance with a
> given grammar." — Grune & Jacobs, _Parsing Techniques: A Practical Guide_, 2nd ed.
> ([source][grune])

Grammars are ranked by expressive power along the **Chomsky hierarchy**, Noam
Chomsky's 1956 classification of four nested grammar classes, each defined by a
restriction on the _shape_ of its productions and each recognized by a strictly weaker
machine ([Chomsky 1956][chomsky56]; full development in [formal-languages][formal]).
The four levels, from most to least restrictive:

| Type  | Grammar class                          | Production form                        | Recognizer                       | Membership cost                       | Role in parsing                                                  |
| ----- | -------------------------------------- | -------------------------------------- | -------------------------------- | ------------------------------------- | ---------------------------------------------------------------- |
| **3** | **Regular**                            | `A → a`, `A → aB` (right-linear)       | finite automaton (DFA/NFA)       | `O(n)`, `O(1)` space                  | the **lexer** layer; the SIMD classifier in [simdjson][simdjson] |
| **2** | **Context-free** (CFG)                 | `A → γ` (one nonterminal LHS, any RHS) | pushdown automaton (a **stack**) | `O(n³)` general, `O(n)` deterministic | the **backbone** of every parser here                            |
| **1** | **Context-sensitive** (CSG)            | `αAβ → αγβ`, `γ ≠ ε`                   | linear-bounded automaton         | `PSPACE`-complete                     | a foil — too costly to parse with; handled out-of-band           |
| **0** | **Unrestricted** (recursively enumer.) | `γ → α`, any rewrite                   | Turing machine                   | undecidable in general                | out of scope (general computation)                               |

Practical parsing lives almost entirely in **Type 2 and Type 3**. A regular language
cannot count nesting depth — it has "no memory but its current state" — so it cannot
balance `(`/`)` or `if`/`end`; that demands at least a stack, i.e. a context-free
grammar parsed by a [pushdown automaton][formal]. But you do not climb higher than you
must: Type 1 recognition is `PSPACE`-complete and Type 0 is undecidable. The Dragon
Book frames syntax analysis around precisely this choice — context-free grammars are
expressive enough for nesting yet cheap enough to parse:

> "Every programming language has rules that prescribe the syntactic structure of
> well-formed programs. … These rules can be expressed by a context-free grammar." —
> Aho, Lam, Sethi & Ullman, _Compilers: Principles, Techniques, and Tools_ (the
> "Dragon Book"), 2nd ed. ([source][dragon])

The single most consequential fact for this catalog is the split _inside_ Type 2: the
**deterministic context-free languages** (those a deterministic pushdown automaton
accepts) are exactly the languages with an `LR(1)` grammar (Knuth, 1965), and they
parse in **`O(n)`**. Every [top-down][top-down] and [bottom-up][bottom-up] technique is
a strategy for staying in — or near — that linear-time deterministic subset; the
[general parsers][general] are what you reach for when the grammar genuinely escapes
it. The grammar classes the real families occupy:

```text
                          recognizing machine          parsing in this catalog
  Type 0  recursively enumerable  ── Turing machine          (out of scope)
            ⊋
  Type 1  context-sensitive       ── linear-bounded automaton (foil; "context-sensitive patches")
            ⊋
  Type 2  context-free            ── pushdown automaton       ← THE parsing level
            │   ⊋ deterministic CF (DPDA) ── LR(1)/LALR/LL    ← linear-time subset
            ⊋
  Type 3  regular                 ── finite automaton         ← lexers, the SIMD classifier
```

> [!IMPORTANT]
> "Context-free" is an _almost_-truth for real languages. Production grammars are
> context-free in the large but carry a few **context-sensitive patches** — C's
> typedef-vs-identifier ambiguity (the [lexer hack][formal]), Python's significant
> indentation (`INDENT`/`DEDENT`), here-documents — each a tiny instance of the
> `{aⁿbⁿcⁿ}` phenomenon a CFG provably cannot express. The universal move is to push
> the context-sensitive bit into a **stateful lexer or a semantic side-table** so the
> _core grammar stays context-free_; the gory details are in [formal-languages][formal].

---

## Terminals, nonterminals, and derivations

Formally a grammar is a 4-tuple `G = (N, Σ, P, S)` ([formal-languages][formal]):

- **Terminals** (`Σ`) — the alphabet of atomic symbols the grammar's strings are made
  of. For a programming language these are the **tokens** the lexer emits (`if`, `+`,
  an identifier, a number literal), _not_ raw characters. They are "terminal" because
  no production rewrites them; they are the leaves of every [parse tree](#parse-trees-asts-and-csts).
- **Nonterminals** (`N`) — the syntactic _variables_ (`Expr`, `Statement`, `Decl`).
  Each names a sub-language and appears on the left-hand side of one or more
  productions. By convention nonterminals are capitalized or angle-bracketed
  (`<expr>`), terminals quoted or lowercase.
- **Productions** (`P`) — the rewrite rules `A → γ`. A context-free production has a
  single nonterminal on the left and any string of terminals and nonterminals on the
  right.
- **Start symbol** (`S ∈ N`) — the distinguished nonterminal a whole input must reduce
  to (`CompilationUnit`, `Program`).

A grammar of balanced parentheses, written in `bnf`, has one nonterminal (`S`), two
terminals (`(`, `)`), and a recursive production plus an empty alternative:

```bnf
; Context-free, not regular: matching depth needs a stack.
S ::= "(" S ")" S
    | ε                ; the empty string (epsilon)
```

A **derivation** is a sequence of rewrites `S ⇒ … ⇒ w` that produces a terminal string
`w` by repeatedly replacing a nonterminal with the right-hand side of one of its
productions. The grammar's language is every string so derivable: `L(G) = { w ∈ Σ* | S ⇒* w }`
where `⇒*` is the reflexive-transitive closure of the single-step rewrite.

Two derivation _orders_ name the two great algorithm families:

- A **leftmost derivation** always expands the leftmost remaining nonterminal first.
  This is the order a **top-down** / [recursive-descent][top-down] / `LL` parser
  follows — the first `L` in `LL` stands for the **L**eftmost derivation it traces.
- A **rightmost derivation** expands the rightmost nonterminal first. A **bottom-up**
  / `LR` parser builds a rightmost derivation _in reverse_ — the `R` in `LR` is the
  **R**ightmost derivation it reconstructs as it reduces handles back to `S`.

Leftmost derivations are in bijection with parse trees, so "two leftmost derivations"
and "two parse trees" are the same phenomenon — the formal definition of [ambiguity](#ambiguity-and-disambiguation).

> [!NOTE]
> **EBNF, BNF, and the metasyntax.** Grammars in this catalog are written in **BNF**
> (Backus–Naur Form: `::=`, `|`, recursion) or **EBNF** (Extended BNF, which adds
> regular-expression sugar — `?` optional, `*`/`+` repetition, `( )` grouping). The
> sugar is _convenience_, not extra power: an EBNF rule desugars to plain BNF
> productions. Each parser-generator deep-dive ([Bison][bison], [ANTLR][antlr],
> [Menhir][menhir], [pest][pest]) defines its own concrete grammar DSL on top of this
> shared metasyntax.

---

## Recognition vs parsing

Two questions hide under the word "parse", and keeping them apart is the first
discipline of the field:

| Stage           | Question answered                     | Output                                                                       | Cost (CFG)                   |
| --------------- | ------------------------------------- | ---------------------------------------------------------------------------- | ---------------------------- |
| **Recognition** | _Is `w ∈ L(G)`?_ (yes / no)           | a boolean                                                                    | `O(n³)` general, `O(n)` det. |
| **Parsing**     | _What structure did `G` use for `w`?_ | a [parse tree](#parse-trees-asts-and-csts) (or actions/AST built on the fly) | same asymptotics             |

**Recognition** is the membership decision: does the string belong to the language at
all? **Parsing** additionally _builds the witness_ — the tree (or the sequence of
semantic actions) that shows _how_ the grammar generated the string. Many algorithms
are first specified as recognizers and then extended to parsers: [CYK][general] fills a
table of which nonterminals derive which substrings (recognition) and reconstructs the
tree by back-pointers (parsing); a regex matcher recognizes without ever building a
tree. The asymptotic cost is the same either way — building the tree is not the
expensive part; deciding membership is.

A third, distinct stage sits beyond parsing: **semantic analysis** answers _is `w`
well-formed beyond syntax?_ (types agree, names are declared before use). This is
where the context-sensitive constraints a CFG provably cannot express — the
`typedef`-vs-identifier decision, declaration-before-use — are enforced, via a symbol
table and attribute evaluation rather than a grammar. The clean layering
**recognition → parsing → semantics** is the architecture the [lexer hack][formal]
deliberately violates (it feeds the symbol table backwards into the lexer) and Clang
deliberately restores.

> [!NOTE]
> "Parser" in tool names is loose. A "JSON parser" like [simdjson][simdjson] both
> validates (recognizes) and produces a navigable document (parses); a "validator"
> recognizes only. When a deep-dive says a tool is `O(n³)`, that is the
> _recognition_ bound — the parse-tree construction never costs more asymptotically.

---

## Parse trees, ASTs, and CSTs

Three tree shapes, distinguished by _how much of the concrete syntax they keep_:

- A **parse tree** (a.k.a. **concrete syntax tree**, **CST**, **derivation tree**) is
  the direct image of a derivation: `S` at the root, every interior node a nonterminal
  whose children are exactly the right-hand side of the production applied, leaves
  spelling out the input terminals left to right. It records _every_ token, including
  punctuation and grouping. A **lossless** CST additionally retains whitespace and
  comments — the property [tree-sitter][tree-sitter] needs to round-trip and re-render
  edited source.
- An **abstract syntax tree** (**AST**) is the parse tree with the syntactic noise
  stripped out — the shape a compiler back-end actually consumes. Wikipedia's
  definition pins the distinction:

  > "An abstract syntax tree (AST) … does not represent every detail appearing in the
  > real syntax, but rather just the structural or content-related details. For
  > instance, grouping parentheses are implicit in the tree structure, so these do not
  > have to be represented as separate nodes. … Compared to the source code, an AST
  > does not include nonessential punctuation and delimiters (braces, semicolons,
  > parentheses, etc.). … This distinguishes abstract syntax trees from concrete
  > syntax trees, traditionally designated parse trees." — [Wikipedia: AST][ast-wiki]

The contrast, on the same input `(1 + 2)`:

```text
  CST / parse tree                    AST
  ----------------                    ---
  Expr                                  (+)
  └─ "(" Expr ")"                       ├─ 1
       └─ Expr "+" Expr                 └─ 2
            ├─ Num "1"
            └─ Num "2"
  (keeps the parens and the            (parens implied by structure;
   Expr-wrapping nonterminals)          only the operator and operands)
```

Which one a tool builds is a defining design choice. Most parser-generators
([Bison][bison], [Menhir][menhir], [ANTLR][antlr]) let _semantic actions_ build an AST
**directly during the parse**, never materializing a full CST. Parser combinators
([nom][nom], [Parsec][parsec], [chumsky][chumsky]) return whatever value the
combinator code constructs — usually an AST, since the combinator _is_ the
tree-builder. [tree-sitter][tree-sitter] is the outlier: it deliberately produces a
**lossless CST** because an editor must re-render and incrementally re-parse the exact
bytes, comments and all. General parsers ([Earley][general], [GLR][general]) facing an
[ambiguous](#ambiguity-and-disambiguation) grammar return not one tree but a **parse
forest** — a shared, packed representation of _all_ trees (an SPPF; see [general
parsing][general]).

---

## Lexing vs scannerless parsing

The classical pipeline splits syntax analysis into two phases: a **lexer** (a.k.a.
**scanner**, **tokenizer**) first chops the raw character stream into a stream of
**tokens** using a _regular_ (Type 3) grammar, then a **parser** consumes that token
stream with a context-free grammar. The lexer is a finite automaton; the parser is a
pushdown automaton. The split is licensed by a closure property — a context-free
language intersected with a regular language is still context-free — so running a
regular lexer in front of a CF parser keeps the composite context-free
([formal-languages][formal]). The Dragon Book gives three reasons to separate them:

> "There are several reasons for separating the analysis phase of compiling into lexical analysis and parsing. **1. Simplicity of design** … **2. Compiler efficiency is improved** [a specialized buffering technique for reading characters speeds up the compiler] … **3. Compiler portability is enhanced** [input-device-specific peculiarities can be restricted to the lexical analyzer]." — Dragon Book, §3.1 ([source][dragon])

The lexer's job is more than splitting: it classifies each token (keyword? operator?
literal?), discards whitespace and comments, and resolves the **longest-match** /
**maximal-munch** rule (`>=` is one token, not `>` then `=`). Crucially, it is also
where the [context-sensitive patches][formal] are smuggled in — Python's
indentation-driven `INDENT`/`DEDENT` tokens, C's typedef back-channel, here-document
terminators — precisely because a stateful lexer can carry side data a pure CFG cannot.

**Scannerless** parsing collapses the two phases: there is no separate token stream;
the parser works directly over **characters** (or bytes), with the lexical rules folded
into the same grammar as the syntactic rules. This is the natural mode for **parser
combinators** ([nom][nom] is byte-oriented and scannerless; [Parsec][parsec],
[chumsky][chumsky]) and for **PEG** tools ([pest][pest]), where the ordered-choice
operator and the absence of a separate lexical grammar make a single unified grammar
both possible and idiomatic. [simdjson][simdjson] is scannerless in a different sense —
its SIMD stage-1 classifies _bytes_ directly into structural and non-structural roles
with no token objects at all.

| Axis                      | Lexer + parser (two-phase)                                      | Scannerless (one phase)                                                                   |
| ------------------------- | --------------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| Lexical grammar           | separate (regular); a `flex`/hand-written scanner               | folded into the main grammar                                                              |
| Parser sees               | a stream of tokens                                              | raw characters / bytes                                                                    |
| Whitespace & comments     | discarded by the lexer before the parser                        | matched explicitly in the grammar (a recurring chore)                                     |
| Token disambiguation      | maximal-munch in the lexer; keyword tables                      | handled by [ordered choice](#ambiguity-and-disambiguation) / longest-match in the grammar |
| Typical homes             | [Bison][bison], [Menhir][menhir], [ANTLR][antlr], classic LR/LL | [nom][nom], [Parsec][parsec], [pest][pest], [chumsky][chumsky] (PEG/combinators)          |
| Context-sensitive patches | smuggled into the stateful lexer                                | expressed via predicates / context-sensitive combinators                                  |

> [!WARNING]
> Scannerless parsing **re-introduces lexical ambiguity into the parser**: without a
> separate maximal-munch lexer, the grammar must itself ensure that `interface` is a
> keyword and not the identifier `inter` followed by `face`, and must thread whitespace
> handling through every rule. PEG's [ordered choice](#ambiguity-and-disambiguation) and
> greedy repetition make this tractable (try the keyword alternative first); plain CFG
> combinators rely on the author's discipline. The convenience of one grammar is paid
> for in vigilance over token boundaries.

---

## Ambiguity and disambiguation

A grammar is **ambiguous** when some string has more than one [parse tree](#parse-trees-asts-and-csts)
(equivalently, more than one leftmost derivation):

> "[An ambiguous grammar is] a context-free grammar for which there exists a string
> that can have more than one … parse tree." — [Wikipedia: ambiguous grammar][ambig-wiki]

The textbook witness is unparenthesized arithmetic, which leaves operator
**precedence** and **associativity** unresolved:

```bnf
; Ambiguous: "1 - 2 - 3" has two parse trees —
;   (1 - 2) - 3  and  1 - (2 - 3) — with different values.
E ::= E "-" E
    | digit
```

Two finer distinctions matter. **Grammar ambiguity** is a property of the _grammar_ and
is often fixable by rewriting. **Inherent ambiguity** is a property of the _language_:
one for which _every_ grammar is ambiguous — no rewriting can help, so no deterministic
parser exists for it ([formal-languages][formal]). And, decisively for tooling,
"is this grammar ambiguous?" is **undecidable** in general (it reduces to the Post
Correspondence Problem) — which is why no generator can warn you definitively; it can
only report grammar-class-specific _conflicts_ ([formal-languages][formal]).

The three families cope with ambiguity in fundamentally different ways:

- **Deterministic parsers reject it at construction time.** An [LL][top-down] or
  [LR/LALR][bottom-up] generator that finds two viable actions for the same state
  reports a **shift/reduce** or **reduce/reduce conflict** — its way of saying "your
  grammar is not in my deterministic class." [Bison][bison] resolves such conflicts via
  **precedence and associativity declarations** (`%left`, `%right`, `%prec`) or a
  default (shift), trading a clean error for a silent choice.
- **PEG / ordered-choice parsers dissolve it by fiat.** A [PEG][peg]'s choice operator
  `e1 / e2` is _prioritized_: it commits to the first alternative that matches. So a PEG
  is unambiguous **by definition** — at the cost of possibly hiding the alternative you
  meant. Ford's contrast:

  > "Unlike CFGs, PEGs cannot be ambiguous; a string has exactly one valid parse tree or
  > none." — [Wikipedia: parsing expression grammar][peg-wiki], on Ford's PEG
  > ([POPL 2004][ford-peg])

- **General parsers embrace it.** [Earley][general] and [GLR][general] return a **parse
  forest** — all trees at once — which is the only honest answer for an inherently or
  deliberately ambiguous grammar (natural language, tooling grammars). [tree-sitter][tree-sitter]
  is GLR-based and resolves residual ambiguity with static `prec` rules and a runtime
  error-cost metric.

**Disambiguation** is the act of choosing _one_ tree. The principled techniques, in
roughly increasing intrusiveness:

| Technique                                    | Where it lives                              | Example                                                                     |
| -------------------------------------------- | ------------------------------------------- | --------------------------------------------------------------------------- |
| **Encode precedence in grammar shape**       | the grammar itself (a rule layer per level) | one nonterminal for `+`/`-`, one for `*`/`/`; left-recursive for left-assoc |
| **Precedence/associativity declarations**    | generator directives                        | [Bison][bison] `%left '+'`; [Menhir][menhir] `%left`                        |
| **[Pratt / precedence climbing][pratt]**     | the parser's expression core                | a binding-power number per operator; the dominant hand-written technique    |
| **Ordered choice (`/`)**                     | [PEG][peg] grammars                         | "try the keyword rule before the identifier rule"                           |
| **Semantic predicates / dynamic precedence** | parse-time guards                           | [ANTLR][antlr] `{...}?` predicates; tree-sitter `prec.dynamic`              |

> [!IMPORTANT]
> The **dangling-else** is the canonical ambiguity every language designer meets:
> in `if a then if b then s1 else s2`, does the `else` bind to the inner or outer
> `if`? The grammar is genuinely ambiguous; the universal resolution ("`else` binds
> to the nearest unmatched `then`") is imposed by a disambiguation rule — a Bison
> shift-default, a PEG ordered choice, or a grammar rewrite — not by the bare CFG.

---

## Lookahead, backtracking, and determinism

Three intertwined notions decide _how_ a parser chooses its next move and _how much it
can see or undo_ while choosing.

**Lookahead** is how many tokens of upcoming input the parser may inspect before
committing to a production. The classical classes are named by it:

- `LL(k)` / `LR(k)` — **fixed** _k_ tokens of lookahead. `LL(1)` and `LALR(1)` (one
  token) are the workhorses: a parse decision is a table lookup keyed on the current
  state and the next token. The `LL` family is developed in [top-down][top-down], the
  `LR` family in [bottom-up][bottom-up].
- `LL(*)` / `ALL(*)` — **unbounded but regular** lookahead. ANTLR's `ALL(*)` does a
  mini-DFA simulation _at parse time_ to choose among alternatives that share an
  arbitrarily long common prefix — the central trick of [ANTLR][antlr]:

  > "The critical innovation is to move grammar analysis to parse-time … ALL(\*) is
  > O(n⁴) in theory but consistently performs linearly on grammars used in practice." —
  > Parr, Harwell & Fisher, "Adaptive LL(\*) Parsing" (OOPSLA 2014) ([source][allstar])

**Backtracking** is the parser's ability to _undo_ a wrong choice — abandon a partially
matched alternative and try the next. Deterministic LL/LR parsers do **not** backtrack:
the table tells them the one correct move, so they never speculate. **PEG / packrat**
parsers ([peg][peg]) and most **parser combinators** ([nom][nom], [Parsec][parsec])
_do_ backtrack: ordered choice `e1 / e2` tries `e1`, and on failure rewinds the input
and tries `e2`. Backtracking buys unbounded lookahead and a simpler grammar at the risk
of exponential blowup — which is exactly the cost **packrat** [memoization](#memoization-incrementality-and-error-recovery)
exists to defuse.

> [!WARNING]
> **Backtracking in combinators is opt-in, and getting it wrong silently breaks the
> parser.** In Parsec, choice `p <|> q` only tries `q` if `p` consumed _no_ input;
> once `p` consumes a token it commits, and you must wrap it in `try p` to make the
> alternative reachable. This "consumed-input" rule is what keeps Parsec near-linear
> by default, but it makes accidental commitment a classic bug — see [Parsec][parsec].

**Determinism** is the property that the parser's next action is uniquely determined by
its state and bounded lookahead — no speculation, no backtracking, no parallel parses.
A **deterministic** parser runs in `O(n)` and detects errors at the earliest possible
token (the **viable-prefix property** for LR; an analogous early-detection property for
LL). The deterministic CF languages are exactly the `LR(1)` languages (Knuth 1965), and
chasing that linear-time sweet spot is what the whole LL/LR enterprise is about. When a
grammar is _not_ deterministic, you have three escapes, each trading the determinism for
something:

| Escape from determinism                  | Buys                                            | Pays                                                      | Realized by                                            |
| ---------------------------------------- | ----------------------------------------------- | --------------------------------------------------------- | ------------------------------------------------------ |
| **Backtracking + ordered choice**        | a simpler grammar; unbounded lookahead          | exponential time without memoization; hidden alternatives | [PEG][peg], combinators ([nom][nom], [Parsec][parsec]) |
| **Parse-time analysis** (`ALL(*)`)       | any non-left-recursive CFG, no manual factoring | `O(n⁴)` worst case (linear in practice)                   | [ANTLR][antlr]                                         |
| **Generalized parsing** (GLR/GLL/Earley) | _any_ CFG, ambiguity and all                    | `O(n³)` worst case; a forest, not a tree                  | [GLR][bottom-up], [Earley/GLL][general]                |

---

## Memoization, incrementality, and error recovery

Three engineering concerns that separate a textbook algorithm from a production parser.

**Memoization** caches the result of "did nonterminal `A` match at position `i`?" so a
backtracking parser never re-evaluates the same `(rule, position)` pair twice. This is
the heart of **packrat** parsing: it turns a [PEG][peg]'s exponential-in-the-worst-case
backtracking into **guaranteed linear time** by trading time for a memo table. Ford's
functional pearl introduced it:

> "Packrat parsing is a novel technique for implementing parsers in a lazy functional
> programming language. Packrat parsers provide the power and flexibility of top-down
> parsing with backtracking and unlimited lookahead, but nevertheless guarantee linear
> parse time." — Ford, "Packrat Parsing: Simple, Powerful, Lazy, Linear Time" (ICFP 2002) ([source][packrat])

The trade is space: the memo table is `O(n × |grammar|)`, so packrat parsers use far
more memory than a streaming LL/LR parser — which is exactly why [pest][pest]
deliberately does **not** memoize (it is a "non-packrat" PEG), and why nom/chumsky make
memoization opt-in. The same `(rule, position)` table reappears, transposed, as the
chart in [Earley][general] and the GSS in [GLL/GLR][general] — memoization is the single
idea that tames every backtracking or generalized parser.

**Incrementality** is the ability to re-parse a small edit in time proportional to the
edit, not to the whole file — the contract an editor demands. The batch contract
("parse once, abort on the first error") is wrong for a buffer that is _constantly
half-typed_ and re-parsed on every keystroke. [tree-sitter][tree-sitter] is the canonical
incremental parser; its self-description states the contract directly:

> "Tree-sitter is a parser generator tool and an incremental parsing library. It can
> build a concrete syntax tree for a source file and efficiently update the syntax tree
> as the source file is edited." — [tree-sitter documentation][ts-docs]

Incrementality requires keeping the [CST](#parse-trees-asts-and-csts) around between
edits (you re-use unchanged subtrees), which is one reason tree-sitter produces a
lossless CST rather than a throwaway AST.

**Error recovery** is producing a useful result _despite_ a syntax error rather than
aborting at the first one — the difference between a compiler (which may stop) and an
IDE (which must not). The theory guarantees only _where_ the first error is (the
viable-prefix property); _how to continue past it_ is heuristic engineering:

| Recovery strategy           | Mechanism                                                       | Where it lives                                            |
| --------------------------- | --------------------------------------------------------------- | --------------------------------------------------------- |
| **Panic mode**              | skip tokens until a **synchronizing token** (`;`, `}`) is found | classic LL/LR; [Bison][bison]                             |
| **Error productions**       | grammar rules that match common mistakes and emit a diagnostic  | [Bison][bison] `error` token; [Menhir][menhir]            |
| **Error nodes in the tree** | insert/skip tokens and record an `ERROR` node, keep parsing     | [tree-sitter][tree-sitter] (GLR error cost)               |
| **Partial-AST recovery**    | a failed parse yields a partial AST _plus_ a list of errors     | [chumsky][chumsky] (recovery is a first-class combinator) |
| **Formal/verified parsing** | a machine-checked correctness proof of the parser itself        | [Menhir][menhir]'s Coq/Rocq back-end                      |

> [!NOTE]
> Error recovery and incrementality are why the catalog's two most "modern" tools —
> [tree-sitter][tree-sitter] and [chumsky][chumsky] — exist at all. A 1970s LALR
> generator was built for the batch compiler contract: one pass, first error fatal,
> AST or nothing. The shift toward IDE/LSP tooling re-prioritized _tolerance_ and
> _incrementality_ over raw single-pass throughput, and the algorithm choices (GLR,
> recovering combinators) follow from that contract change. The opposite extreme —
> maximal throughput, no recovery — is [simdjson][simdjson].

---

## The parser landscape at a glance

Every family this catalog surveys, mapped to its typical grammar class, worst-case time
(for **recognition** — see [recognition vs parsing](#recognition-vs-parsing)), how it
handles [ambiguity](#ambiguity-and-disambiguation), its
[error-recovery](#memoization-incrementality-and-error-recovery) posture, and a
representative tool. Each family links to the theory deep-dive that develops it; the
[capstone comparison][comparison] places these side-by-side on shared axes.

| Family                                                 | Typical grammar class                            | Worst-case time                            | Ambiguity handling                                   | Error-recovery posture                                  | Representative tool                               |
| ------------------------------------------------------ | ------------------------------------------------ | ------------------------------------------ | ---------------------------------------------------- | ------------------------------------------------------- | ------------------------------------------------- |
| **Recursive descent / LL(k)** ([top-down][top-down])   | `LL(k)` deterministic CF                         | `O(n)`                                     | rejected at construction (conflict) or by rule order | panic-mode; hand-written recovery is easy and local     | hand-written RD; many compilers                   |
| **LL(\*) / ALL(\*)** ([top-down][top-down])            | non-left-recursive CF (adaptive lookahead)       | `O(n⁴)` (linear in practice)               | not handled; resolved by alternative order           | single-token recovery + sync sets                       | [ANTLR][antlr]                                    |
| **LR(0) / SLR / LALR(1)** ([bottom-up][bottom-up])     | deterministic CF (subsets of `LR(1)`)            | `O(n)`                                     | rejected as shift/reduce or reduce/reduce conflict   | panic-mode; error productions; `error` token            | [Bison / yacc][bison]                             |
| **Canonical LR(1)** ([bottom-up][bottom-up])           | full deterministic CF (the `LR(1)` languages)    | `O(n)`                                     | rejected as a conflict (fewer than LALR)             | error productions; verified recovery option             | [Menhir][menhir]                                  |
| **GLR (generalized LR)** ([bottom-up][bottom-up])      | _any_ CFG (ambiguous included)                   | `O(n³)` (cubic)                            | embraced — splits the stack, returns a parse forest  | error cost + tree error nodes (tree-sitter)             | [tree-sitter][tree-sitter]; [Bison][bison] `%glr` |
| **Earley** ([general][general])                        | _any_ CFG                                        | `O(n³)`; `O(n²)` unambig.; `O(n)` LR-class | embraced — chart yields a parse forest               | chart survives errors; recovery is grammar-driven       | Marpa; `nearley.js`                               |
| **CYK** ([general][general])                           | _any_ CFG (Chomsky normal form)                  | `O(n³ · grammar-size)`                     | embraced — table records all derivations             | mostly a recognizer; recovery is bolt-on                | teaching / NLP toolkits                           |
| **GLL** ([general][general])                           | _any_ CFG (generalized recursive descent)        | `O(n³)`                                    | embraced — GSS + shared packed parse forest          | descends well into partial input; tooling-dependent     | instaparse                                        |
| **PEG / packrat** ([PEG/packrat][peg])                 | PEG (ordered choice; CF-incomparable)            | `O(n)` packrat; `O(n)`/exp. non-memo       | dissolved — unambiguous by fiat (first match wins)   | by construction continues; recovery is the weak spot    | [pest][pest] (non-packrat PEG)                    |
| **Parser combinators** ([top-down][top-down])          | PEG-like / predictive `LL` with backtracking     | `O(n)`–exponential (opt-in memo)           | dissolved via left-biased ordered choice             | first-class recovering combinators ([chumsky][chumsky]) | [nom][nom], [Parsec][parsec], [chumsky][chumsky]  |
| **Parsing with derivatives** ([derivatives][deriv])    | _any_ CFG (Brzozowski derivative, lifted)        | `O(n³)` (cubic, w/ compaction)             | embraced — produces a parse forest                   | research-grade; not a recovery-focused technique        | Adams/Might `parsing-with-derivatives`            |
| **Pratt / operator-precedence** ([Pratt][pratt])       | operator grammars (expression sublanguage)       | `O(n)`                                     | resolved by binding power (precedence as a number)   | local; pairs with a host recursive-descent recovery     | embedded in many hand-written parsers             |
| **SIMD / ad-hoc data-parallel** ([simdjson][simdjson]) | one fixed grammar (regular stage-1 + CF stage-2) | `O(n)` (branchless, vectorized)            | n/a — a single unambiguous grammar (JSON)            | validate-or-reject (no partial recovery)                | [simdjson][simdjson]                              |

> [!NOTE]
> The "worst-case time" column is the **asymptotic recognition** bound, not the
> constant factor. [simdjson][simdjson] and a `LALR(1)` parser are both `O(n)`, yet
> simdjson is often an order of magnitude faster in wall-clock terms because it is
> _branchless and vectorized_ — it processes 64 bytes per step instead of one token
> per table lookup. Conversely a cubic-worst-case [Earley][general] or [GLR][general]
> parser runs in _linear_ time on the deterministic grammars that dominate real
> languages; the cubic wall only bites on genuinely ambiguous input. Asymptotic class
> is necessary but never sufficient for picking a parser — see the
> [comparison][comparison] for the constant-factor and ergonomics axes.

The families are not disjoint. [Parser combinators](#lookahead-backtracking-and-determinism)
are _recursive descent_ expressed as composable host-language values, so they share
top-down's grammar class while adopting PEG's ordered choice. [GLR][bottom-up] is
[LR][bottom-up] with the determinism requirement dropped, so it sits in both the
bottom-up and the general-parsing families. [Pratt parsing][pratt] is an _expression
sublanguage_ technique embedded _inside_ a recursive-descent or LR parser, not a
standalone family. And [tree-sitter][tree-sitter] layers _incrementality_ and _error
recovery_ on top of GLR — a reminder that the [memoization / incrementality / error
recovery](#memoization-incrementality-and-error-recovery) concerns cut across the
algorithm taxonomy rather than partitioning it.

---

## Sources

The definitions above are grounded in the field's primary literature and authoritative
references; the deep theory is developed in [formal-languages][formal], which carries
its own citations.

- **Aho, Lam, Sethi & Ullman.** _Compilers: Principles, Techniques, and Tools_ (the
  "Dragon Book"), 2nd ed. — CFGs as the formalism for programming-language syntax (§4),
  the lexer/parser separation rationale (§3.1). ([PDF][dragon])
- **Grune, D. & Jacobs, C.** _Parsing Techniques: A Practical Guide_, 2nd ed. — the
  operational definition of parsing and a survey of every algorithm family.
  ([1st-ed. PDF][grune])
- **Hopcroft, Motwani & Ullman.** _Introduction to Automata Theory, Languages, and
  Computation_ — the canonical reference for the Chomsky hierarchy, automata, and
  decidability.
- **Chomsky, N.** (1956). "Three Models for the Description of Language." — introduces
  the hierarchy. ([Semantic Scholar record][chomsky56])
- **Ford, B.** (2004). "Parsing Expression Grammars: A Recognition-Based Syntactic
  Foundation." POPL — PEGs, ordered choice, syntactic predicates, unambiguity by
  construction. ([paper][ford-peg])
- **Ford, B.** (2002). "Packrat Parsing: Simple, Powerful, Lazy, Linear Time." ICFP —
  memoization → linear-time backtracking. ([PDF][packrat])
- **Parr, Harwell & Fisher.** (2014). "Adaptive LL(\*) Parsing: The Power of Dynamic
  Analysis." OOPSLA — `ALL(*)`, parse-time grammar analysis. ([paper][allstar])
- **Reference encyclopedia entries** (definitions cross-checked): abstract syntax tree,
  ambiguous grammar, parsing expression grammar, parser combinator.
- **In-tree deep-dives** carry the per-tool primary sources: [tree-sitter][tree-sitter],
  [simdjson][simdjson], [ANTLR][antlr], [Bison/yacc][bison], [Menhir][menhir],
  [Parsec][parsec], [nom][nom], [chumsky][chumsky], [pest][pest].

<!-- References -->

<!-- In-tree: umbrella, synthesis, theory -->

[index]: ./index.md
[comparison]: ./comparison.md
[theory-index]: ./theory/index.md
[formal]: ./theory/formal-languages.md
[top-down]: ./theory/top-down.md
[bottom-up]: ./theory/bottom-up.md
[general]: ./theory/general-parsing.md
[peg]: ./theory/peg-packrat.md
[pratt]: ./theory/pratt-precedence.md
[deriv]: ./theory/derivatives.md

<!-- In-tree: tool deep-dives -->

[simdjson]: ./simdjson.md
[tree-sitter]: ./tree-sitter.md
[antlr]: ./antlr.md
[bison]: ./bison-yacc.md
[menhir]: ./menhir.md
[parsec]: ./haskell-parsec.md
[nom]: ./rust-nom.md
[chumsky]: ./rust-chumsky.md
[pest]: ./pest.md

<!-- External primary sources -->

[dragon]: https://faculty.sist.shanghaitech.edu.cn/faculty/songfu/cav/Dragon-book.pdf
[grune]: https://dickgrune.com/Books/PTAPG_1st_Edition/BookBody.pdf
[chomsky56]: https://www.semanticscholar.org/paper/Three-models-for-the-description-of-language-Chomsky/6e785a402a60353e6e22d6883d3998940dcaea96
[ford-peg]: https://bford.info/pub/lang/peg/
[packrat]: https://bford.info/pub/lang/packrat-icfp02.pdf
[allstar]: https://www.antlr.org/papers/allstar-techreport.pdf
[ast-wiki]: https://en.wikipedia.org/wiki/Abstract_syntax_tree
[ambig-wiki]: https://en.wikipedia.org/wiki/Ambiguous_grammar
[peg-wiki]: https://en.wikipedia.org/wiki/Parsing_expression_grammar
[ts-docs]: https://tree-sitter.github.io/tree-sitter/
