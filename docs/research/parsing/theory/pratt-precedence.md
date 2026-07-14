# Operator-Precedence & Pratt Parsing

Expression grammars are the one place where the clean rule-↔-function discipline of
[recursive descent][top-down] breaks down: `1 + 2 * 3` and `2 ^ 3 ^ 4` cannot be parsed
correctly without encoding **precedence** (which operator binds tighter) and
**associativity** (which way equal-precedence operators group), and the naïve grammar
that expresses them — `E → E + E | E * E | …` — is both ambiguous and left-recursive,
the two things an LL parser cannot touch. This family of algorithms solves exactly that
sub-problem: a small, table-driven engine that parses operator expressions in linear
time and slots into an otherwise [recursive-descent][top-down] parser as its
**expression engine**. It runs from [Floyd's 1963 operator-precedence grammars][floyd]
(bottom-up, table-of-relations) through **precedence climbing** to
[Pratt's 1973 "Top Down Operator Precedence"][pratt-paper] (top-down, binding-power
driven) — three faces of one idea. This is the operator-expression leaf of the
[parsing-theory subtree][theory-index].

## At a glance

| Dimension                | Operator-precedence / Pratt parsing                                                                                                                                |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Problem solved           | Parsing **operator expressions** with precedence + associativity, where a plain CFG is ambiguous and left-recursive                                                |
| Grammar class            | **Operator grammars** (Floyd): no two adjacent nonterminals on any RHS, no ε-productions — a restricted, _non-hierarchical_ subset of [CFGs][formal]               |
| Two algorithm families   | **Bottom-up**: Floyd operator-precedence (precedence-relation matrix + shift/reduce). **Top-down**: Pratt / precedence climbing (binding power + one loop)         |
| Core idea                | Attach a numeric **binding power** (precedence) to each operator token; associativity = a deliberate **asymmetry** between left and right binding power            |
| Lookahead / memory       | `1` token of lookahead; `O(d)` stack for nesting depth `d`; no parse table beyond the per-operator precedence map                                                  |
| Time / space             | `O(n)` time, `O(d)` space — strictly linear, no backtracking, no memoization                                                                                       |
| Driving handlers (Pratt) | **`nud`** (null denotation — atoms, prefix ops) and **`led`** (left denotation — infix, postfix ops), keyed per token                                              |
| Ambiguity                | _Resolved by construction_: the precedence/associativity table makes every input unambiguous; non-associative operators can be made a parse error                  |
| Error detection          | Immediate, at the offending token (it's recursive descent); recovery is the host parser's panic-mode                                                               |
| Canonical references     | [Floyd 1963][floyd]; [Pratt 1973][pratt-paper]; [Norvell (precedence climbing)][norvell]; [Crockford 2007][crockford]; [matklad 2020][matklad]                     |
| Real-world tools         | GCC & Clang C/C++ front-ends; V8/JSLint ([Crockford][crockford]); [chumsky `pratt`][chumsky] & [pest `pratt_parser`][pest]; Lua, rustc, Go, Zig expression parsers |

> [!NOTE]
> This page is the expression-parsing specialization of [top-down parsing][top-down].
> Pratt parsing **is** recursive descent — it is the technique a hand-written
> recursive-descent parser reaches for the moment it hits an expression — so read
> [top-down][top-down] first for the surrounding parser, and [bottom-up][bottom-up] for
> the `LR` machinery that Floyd's operator-precedence method is a degenerate, restricted
> case of. Every term here (precedence, associativity, handle, shift/reduce) is defined
> in the [parsing concepts glossary][concepts].

---

## Overview

### The expression problem

Write the obvious grammar for arithmetic and you get something both **ambiguous** and
**left-recursive**:

```ebnf
E → E "+" E | E "*" E | "(" E ")" | num
```

For `1 + 2 * 3` this grammar admits two parse trees — `(1 + 2) * 3` and `1 + (2 * 3)` —
and only the second is arithmetically intended. The textbook fix is to **stratify** the
grammar into one nonterminal per precedence level, recursing on the next-tighter level
and using the right form of recursion to fix associativity:

```ebnf
expr   → term   (("+" | "-") term)*
term   → factor (("*" | "/") factor)*
factor → num | "(" expr ")"
```

This _works_ — it is unambiguous, non-left-recursive, and `LL(1)` — but it has two
costs that motivate the whole family below. First, the structure no longer reads like
the operator table: adding an operator or a precedence level means surgically inserting
a new nonterminal and rewriting two existing rules. Second, every expression pays the
descent through _every_ precedence level even when no operator at that level is present —
`factor` calls `term` calls `expr` for a bare `num`. [Pratt][pratt-paper] opens his paper
by naming this dissatisfaction with grammar-shaped expression parsing directly:

> "BNF grammars alone do not deal adequately with either of these issues, and so they
> are stretched in some directions to increase generality and shrunk in others to
> improve efficiency." — [Pratt, _Top Down Operator Precedence_, POPL 1973][pratt-paper]

His thesis is that **precedence and associativity are data, not grammar** — a number
per operator — and that a single loop driven by those numbers replaces the whole
stratified grammar.

### The core idea: precedence as a number, associativity as an asymmetry

Every algorithm in this family rests on one move: assign each operator a numeric
**precedence** (Pratt's **binding power**), and decide _where the next operand belongs_
by comparing the binding power of the operator on the left against the operator on the
right. [matklad][matklad] frames the intuition that makes the whole thing click:

> "The key idea is that each operator has a _binding power_ — a number. When you have an
> ambiguity, the operator with the higher binding power wins." — [Kladov, _Simple but
> Powerful Pratt Parsing_][matklad]

The subtle, beautiful part is associativity. To make `+` **left-associative**
(`a + b + c` ⇒ `(a + b) + c`) you do _not_ need a second mechanism — you give `+` a
binding power that is slightly **asymmetric**, a hair stronger on the right than on the
left, so when the parser reaches the second `+` the already-built left side wins:

```text
expr:    a       +       b       +       c
power:       1       2       1       2       1
```

[matklad][matklad] visualizes exactly this — the right binding power is "pumped" up so
the left `+` holds its right operand tighter than the next `+` can pull it away. Right
associativity (`a ^ b ^ c` ⇒ `a ^ (b ^ c)`, assignment `a = b = c`) is the mirror
asymmetry: bind tighter on the _left_. That single trick — encode associativity as the
_direction_ of the precedence asymmetry — is what lets one loop handle both directions,
and it is the unifying observation behind Pratt, precedence climbing, and the shunting
yard alike.

### Three faces of one idea

The family has three historically distinct presentations that turn out to be the same
algorithm seen from different sides:

| Presentation                             | Direction | Mechanism                                                                 | Origin                                      |
| ---------------------------------------- | --------- | ------------------------------------------------------------------------- | ------------------------------------------- |
| **Operator-precedence parsing**          | Bottom-up | precedence-relation matrix (`⋖ ≐ ⋗`) + shift/reduce on a stack            | [Floyd 1963][floyd]                         |
| **Precedence climbing**                  | Top-down  | recursive `Exp(p)` with a minimum-precedence argument                     | [Clarke 1986][norvell] / [Norvell][norvell] |
| **Pratt / Top-Down Operator Precedence** | Top-down  | `nud`/`led` per token + an `expression(rbp)` loop driven by binding power | [Pratt 1973][pratt-paper]                   |

Precedence climbing and Pratt parsing are _literally_ the same algorithm
([see below](#the-equivalence-precedence-climbing-pratt)); Floyd's bottom-up method is
their stack-based dual, restricted to operator grammars. The rest of this page works
through each in turn, then shows the equivalence and where each shows up in practice.

---

## How it works

### Floyd 1963: operator-precedence grammars and the precedence matrix

[Floyd's 1963 paper][floyd] introduced **operator grammars** and the
**precedence-relation** method that the whole family descends from. An _operator
grammar_ is a CFG with two restrictions ([Floyd 1963][floyd]):

1. **no ε-productions**, and
2. **no two adjacent nonterminals** on any right-hand side.

Arithmetic-expression grammars satisfy both: between any two operands there is always an
operator terminal, so terminals are never "hidden" behind a nonterminal boundary. That
property is what lets Floyd define precedence _between terminals_ and parse by looking
only at the terminal pair straddling the parser's current position.

Floyd defined three **precedence relations** between terminal symbols — note these are
_relations between operators_, not numbers, and need not be symmetric:

| Relation | Read as                               | Meaning for the handle                                         |
| -------- | ------------------------------------- | -------------------------------------------------------------- |
| `a ⋖ b`  | `a` **yields precedence** to `b`      | the right end of a handle has not been reached — keep shifting |
| `a ≐ b`  | `a` and `b` have **equal precedence** | `a` and `b` belong to the _same_ handle (e.g. `(` ≐ `)`)       |
| `a ⋗ b`  | `a` **takes precedence** over `b`     | the left operator's handle is complete — **reduce**            |

These are tabulated in a **precedence-relation matrix** — one cell per ordered pair of
terminals. Parsing is then a stack-based shift/reduce loop driven entirely by the
matrix: between the terminal on top of the stack and the incoming terminal, look up the
relation, then

- on `⋖` or `≐` → **shift** (the handle continues), and
- on `⋗` → **reduce** (the most recent handle, bracketed by a `⋖ … ⋗` pair, is reduced).

A `⋖ … ⋗` window in the relation stream brackets exactly one **handle** — the substring
to reduce — so a higher-precedence operator like `*` sitting between two lower `+`
operators is recognized as `+ ⋖ * ⋗ +` and reduced first. The relations are
_precomputed_ from the operator precedences, so the inner loop is a single table lookup:
the parse is `O(n)`. This is the bottom-up specialization of [LR parsing][bottom-up],
and it is the engine that compiler-generated parsers embed to accelerate expressions
(see [Where it shows up](#where-it-shows-up-in-practice)).

> [!NOTE]
> The relation symbols `⋖ ≐ ⋗` _look like_ `< = >` but are **not** an ordering on
> numbers — `a ⋖ b` and `b ⋖ a` can both hold or both fail. They encode the
> handle-boundary decision, not arithmetic comparison. The numeric binding-power view
> (precedence climbing / Pratt) is the _function_ representation that makes the common
> case — operators that _do_ totally order by precedence — trivial to specify; the
> matrix is the more general but more laborious representation.

Floyd's method has a sharp limit that the top-down reformulations inherit and the
matrix shows starkly: a terminal that is **both** unary and binary — the classic
example is `-`, prefix negation vs. infix subtraction — wants two different precedences
in the same matrix cell, which a single-relation table cannot express. Floyd 1963 already
flagged this — the unary and binary signs satisfy _different_ precedence relations:

> "The difference between the precedence relations of the unary and binary plus and minus
> signs occurs because the unary signs are introduced in the definition of factor, rather
> than in that of simple arithmetic expression." — [Floyd 1963][floyd]

The top-down formulations dodge this cleanly by keying on _position_ — a `-` seen with
no expression to its left is prefix (a `nud`), with an expression to its left is infix
(a `led`) — which is the next refinement.

### Precedence climbing: the recursive minimum-precedence loop

**Precedence climbing** (the name is [Norvell's][norvell], crediting Clarke's 1986 _The
Top-Down Parsing of Expressions_) folds the entire stratified grammar into a _single_
recursive function parameterized by a **minimum precedence** `p`. [Norvell's][norvell]
canonical pseudocode is worth reproducing exactly, because every later Pratt
presentation is a renaming of it:

```text
Exp( p ) is
    var t : Tree
    t := P
    while next is a binary operator and prec(binary(next)) >= p
       const op := binary(next)
       consume
       const q := case associativity(op)
                  of Right: prec( op )
                     Left:  1 + prec( op )
       const t1 := Exp( q )
       t := mkNode( op, t, t1 )
    return t

P is
    if next is a unary operator
         const op := unary(next); consume
         const t := Exp( prec(op) ); return mkNode( op, t )
    else if next = "("
         consume; const t := Exp( 0 ); expect ")"; return t
    else if next is a value v
         consume; return mkLeaf( v )
    else error
```

Read the loop carefully — it is the whole algorithm:

- `Exp(p)` parses a maximal expression whose operators all have precedence **≥ `p`**;
  it returns the moment it sees a weaker operator, handing control back to the caller
  that owns that weaker level.
- `P` (the **atom** parser) handles the leaf cases: a primary value, a parenthesized
  sub-expression (`Exp(0)` — re-enter at the lowest precedence inside brackets), or a
  prefix unary operator.
- The **recursive call's argument `q` encodes associativity**, and this is the entire
  subtlety. For a **left**-associative operator, `q = 1 + prec(op)`: the recursive call
  refuses any operator of _equal_ precedence, so equal-precedence operators are _not_
  consumed by the recursion and instead fold left in the loop. For a **right**-associative
  operator, `q = prec(op)`: the recursive call _accepts_ equal precedence, so the chain
  builds rightward. [Norvell][norvell] states the rule plainly:

> "if the binary operator is left associative, `q` = the precedence of the operator + 1,
> [and] if the binary operator is right associative, `q` = the precedence of the
> operator." — [Norvell, _Parsing Expressions by Recursive Descent_][norvell]

[Eli Bendersky's][bendersky] equivalent presentation names the same quantity
`next_min_prec` and tabulates the operators in an `OPINFO` map of `(precedence,
associativity)` — e.g. `'+': (1, LEFT)`, `'^': (3, RIGHT)` — confirming that the only
per-operator data the algorithm needs is one integer and one bit.

### Pratt 1973: nud, led, and binding power

[Pratt's 1973 paper][pratt-paper] generalizes precedence climbing by making the
_token itself_ responsible for parsing, via two methods. Pratt's own definitions:

> "We will call the code denoted by a token with (without) a preceding expression its
> _left (null) denotation_ or _led (nud)_." — [Pratt, POPL 1973][pratt-paper]

- A **`nud`** (_null denotation_) is invoked when a token appears with **no expression
  to its left** — i.e. it _starts_ an expression. Atoms (literals, identifiers),
  parenthesized groups, and **prefix** operators have a `nud`.
- A **`led`** (_left denotation_) is invoked when a token appears **with an expression
  to its left** — i.e. it _continues_ one. **Infix** and **postfix/suffix** operators
  have a `led`.

[Crockford][crockford] crystallizes the distinction:

> "A `nud` does not care about the tokens to the left. A `led` does. A `nud` method is
> used by values (such as variables and literals) and by prefix operators. A `led`
> method is used by infix operators and suffix operators." — [Crockford, _Top Down
> Operator Precedence_][crockford]

Each token also carries a **left binding power** `lbp` (how strongly it pulls on the
expression to its left). The engine is one function, `expression(rbp)`, that takes a
**right binding power** controlling how greedily it consumes to its right. Crockford's
JavaScript implementation is the canonical 11-line form:

```javascript
var expression = function (rbp) {
  var left;
  var t = token;
  advance();
  left = t.nud(); // parse the start of the expression
  while (rbp < token.lbp) {
    // while the next op binds tighter than our caller's...
    t = token;
    advance();
    left = t.led(left); // ...let it consume `left` as its left operand
  }
  return left;
};
```

The loop condition `rbp < token.lbp` is the binding-power comparison from the
[core idea](#the-core-idea-precedence-as-a-number-associativity-as-an-asymmetry): keep
extending `left` as long as the upcoming operator binds tighter than what the caller
demanded; stop the moment it binds _looser_ and return, letting an outer call take over.
Pratt frames the stop condition identically in the paper — "to return to `q0` we
require `rbp < lbp`" ([Pratt 1973][pratt-paper]).

Associativity falls out of how each operator's `led` re-invokes `expression`:

| Operator kind                  | `led` recurses with  | Effect                                                         |
| ------------------------------ | -------------------- | -------------------------------------------------------------- |
| **Left-associative** `+`       | `expression(bp)`     | next equal-precedence op stops the recursion → folds left      |
| **Right-associative** `^`, `=` | `expression(bp - 1)` | next equal-precedence op continues the recursion → folds right |

[Crockford][crockford] states the rule directly: "we can also make right associative
operators … by reducing the right binding power" — i.e. `infixr` calls
`expression(bp - 1)` where `infix` calls `expression(bp)`. This is exactly Norvell's
`q = prec(op)` vs. `q = 1 + prec(op)`, written from the other side of the comparison.

Pratt's structural innovation over precedence climbing is the **per-token dispatch
table**: rather than a fixed `unary / binary / atom` case analysis in one `P`/`Exp`
function, every token _type_ owns its `nud` and `led`, so the parser is _extensible_ —
new syntax is a new token object, not an edit to the core loop. [Bob Nystrom][nystrom]
reifies this as the **parselet** abstraction (`PrefixParselet` ≈ `nud`,
`InfixParselet` ≈ `led`) and notes the practical payoff of separate tables:

> "Having separate tables for prefix and infix expressions is important because we
> sometimes have both a prefix and infix parselet for the same `TokenType`." —
> [Nystrom, _Pratt Parsers: Expression Parsing Made Easy_][nystrom]

That separation is precisely what makes the unary/binary `-` that defeated Floyd's
matrix trivial: the same `-` token registers a prefix `nud` _and_ an infix `led`, and
which fires is decided by _whether `expression` is at the start of a sub-expression or
in its loop_ — i.e. by position, for free.

### Prefix, infix, postfix, and mixfix in one loop

The single `nud`/`led` loop handles the full operator zoo without special cases.
[matklad's][matklad] Rust reference threads all four through `expr_bp(lexer, min_bp)`
(his `min_bp` is Pratt's `rbp`, Norvell's `p`):

```rust
fn expr_bp(lexer: &mut Lexer, min_bp: u8) -> S {
    let mut lhs = match lexer.next() {
        Token::Atom(it) => S::Atom(it),                 // nud: atom
        Token::Op('(') => {                             // nud: parenthesized (mixfix)
            let lhs = expr_bp(lexer, 0);
            assert_eq!(lexer.next(), Token::Op(')'));
            lhs
        }
        Token::Op(op) => {                              // nud: prefix operator
            let ((), r_bp) = prefix_binding_power(op);
            let rhs = expr_bp(lexer, r_bp);
            S::Cons(op, vec![rhs])
        }
        t => panic!("bad token: {:?}", t),
    };
    loop {
        let op = match lexer.peek() {
            Token::Eof => break,
            Token::Op(op) => op,
            t => panic!("bad token: {:?}", t),
        };
        if let Some((l_bp, ())) = postfix_binding_power(op) {  // led: postfix / index
            if l_bp < min_bp { break; }
            lexer.next();
            lhs = /* … e.g. `a!`, or `a[i]` with a closing `]` (mixfix) … */ lhs;
            continue;
        }
        if let Some((l_bp, r_bp)) = infix_binding_power(op) {  // led: infix
            if l_bp < min_bp { break; }
            lexer.next();
            let rhs = expr_bp(lexer, r_bp);
            lhs = S::Cons(op, vec![lhs, rhs]);
            continue;
        }
        break;
    }
    lhs
}
```

The encoding of each operator class as a binding-power _shape_ is the elegant core:

| Operator class                          | Binding power shape                                          | Why                                                                           |
| --------------------------------------- | ------------------------------------------------------------ | ----------------------------------------------------------------------------- |
| **Atom**                                | `nud`, no bp                                                 | self-delimiting; nothing binds                                                |
| **Prefix** `-x`                         | `((), r_bp)` — right only                                    | binds nothing on the left; greedily takes a right operand at `r_bp`           |
| **Infix** `a + b`                       | `(l_bp, r_bp)` — both                                        | `l_bp` decides whether the caller keeps it; `r_bp`'s asymmetry sets assoc.    |
| **Postfix** `a!`                        | `(l_bp, ())` — left only                                     | binds its left operand; consumes no right operand, so the loop just continues |
| **Mixfix** `a ? b : c`, `a[i]`, `( e )` | `led`/`nud` with an inner `expression(0)` to a closing token | the inner call resets to the lowest precedence inside the brackets            |

[matklad][matklad] handles the C ternary `?:` as an infix operator whose `led` parses a
middle expression at precedence `0` up to the `:` then a right operand at `r_bp` — a
mixfix operator expressed entirely as one `led` with two recursive calls, no grammar
edit. The same shape gives function calls (`a(args)`), array indexing (`a[i]`), and
parenthesized grouping. **This is the headline result**: prefix, infix, postfix, and
bracketed mixfix syntax, with arbitrary precedence and either associativity, all fall
out of a _single_ loop comparing one integer.

### Power & limits

**What it handles.** Any **operator grammar** in [Floyd's][floyd] sense — expressions
built from prefix/infix/postfix/mixfix operators over self-delimiting atoms, where
every operand pair is separated by an operator terminal. That is precisely the
expression sub-language of essentially every programming language, which is why the
technique is ubiquitous _inside_ otherwise-recursive-descent parsers.

**What it cannot handle.** Operator grammars are a **restricted, non-hierarchical**
subset of [context-free grammars][formal] — they are _not_ a level in the
Chomsky hierarchy, but a side-condition (no adjacent nonterminals, no ε). The technique
parses _expressions_, not whole languages: statement structure, declarations, and
block nesting are the job of the surrounding [recursive-descent][top-down] parser, which
_calls_ the Pratt loop wherever an expression is expected. Two adjacent operands with no
operator between them (e.g. ML/Haskell **juxtaposition** application `f x y`) violate
the operator-grammar condition; a Pratt parser handles it only by treating juxtaposition
as an invisible infix operator with its own binding power — a known idiom, but it shows
the boundary. Genuinely context-dependent or ambiguous _non_-expression structure is out
of scope by construction.

**Where it sits.** Within the [parsing hierarchy][formal]: Floyd operator-precedence is
a strict, restricted **case of [`LR`/bottom-up][bottom-up]** parsing (linear, but for a
far smaller grammar class than `LALR`); Pratt / precedence climbing is the **top-down**
dual and a specialization of [recursive descent][top-down] for expressions. All three
are `O(n)` and use bounded lookahead, sitting _below_ the general parsers
([Earley, GLR, GLL][general]) in power and _far below_ them in cost — exactly the trade
a production compiler wants for the hot path of expression parsing.

### Ambiguity handling

The defining feature of this family is that **ambiguity is resolved by construction, not
discovered at parse time**. The ambiguous grammar `E → E + E | E * E` is _never built_;
instead the precedence/associativity table assigns each `(operator, operator)` decision
a single outcome, so for any input there is exactly one parse the engine can produce.
There is no ambiguity report, no conflict, no GLR-style forest — the table _is_ the
disambiguation. Three knobs cover the cases real languages need:

- **Precedence** (binding power) disambiguates _different_ operators: `*` > `+` makes
  `1 + 2 * 3` parse as `1 + (2 * 3)`.
- **Associativity** (the binding-power asymmetry) disambiguates _repeated_ operators of
  equal precedence: left for `-`, right for `^`/`=`.
- **Non-associativity** rejects chaining outright. [chumsky's][chumsky] `none(prec)`
  associativity does exactly this — "`a < b < c` will produce an error" — turning an
  ambiguous-or-meaningless chain into a clean parse error rather than an arbitrary
  grouping.

The cost of this convenience is that the disambiguation is _global and implicit_: the
grouping of an expression is not visible in any grammar rule but distributed across the
binding-power table, which is why every serious treatment ([Pratt][pratt-paper],
[Norvell][norvell], [matklad][matklad]) leads with the table.

### Error detection & recovery

Because a Pratt parser _is_ recursive descent, **error detection is immediate and
precise**: an unexpected token surfaces exactly where the `nud`/`led` dispatch fails (no
handler registered for this token in this position) or where a mixfix close-token is
missing — matklad's reference simply `assert_eq!(lexer.next(), Token::Op(')'))`, and a
real parser raises a diagnostic at that token's source span. There is no deferred
failure, no backtracking to unwind, and the offending token is named directly. This is a
direct inheritance from [top-down parsing][top-down]: a stack trace through the parser is
a partial parse tree, so the _position_ of the error is the position in the input.

**Recovery**, by contrast, is _not_ part of the algorithm — it belongs to the host
recursive-descent parser. The standard technique is the same **panic-mode**
synchronization used in LL parsers ([Dragon Book §4.4][dragon]): on an expression error,
discard tokens until a synchronizing token (`;`, `)`, a statement keyword) and resume.
The Pratt loop's binding-power discipline actually _helps_ here — it returns cleanly to a
known precedence level on any token it does not recognize as a continuation, so the host
parser regains control at a well-defined point rather than mid-handle.

### Performance & complexity

The algorithm is **strictly linear**: each token is consumed exactly once (the
`advance()` / `lexer.next()` calls march monotonically forward), the inner decision is a
single comparison against a per-operator binding power (an array or hash lookup, `O(1)`),
and the recursion depth is bounded by the _expression nesting depth_ `d`, not the input
length. Hence:

- **Time:** `O(n)` for input length `n` — no backtracking, no memoization (unlike
  [packrat/PEG][peg]'s `O(n)`-with-a-large-constant memo table), no chart (unlike
  [Earley/GLL][general]'s `O(n³)`/`O(n)` chart).
- **Space:** `O(d)` for the recursion/operand stack, `O(1)` per-operator table — the
  smallest memory footprint of any parsing family in this catalog. No parse table is
  _generated_; the "table" is the hand-written binding-power map.

This combination — linear time, minimal space, immediate errors, and trivial
implementation — is why it is the universal choice for the expression hot path even in
parsers that are otherwise grammar-generated.

### Where it shows up in practice

Operator-precedence and Pratt parsing are everywhere expressions are parsed by hand or
on a hot path:

- **GCC and Clang** parse C/C++ with hand-written recursive descent but accelerate
  _expressions_ with an embedded operator-precedence/precedence-climbing routine.
  [Wikipedia's operator-precedence article][wiki-opp] records it: "GCC's C and C++
  parsers, which are hand-coded recursive descent parsers, are both sped up by an
  operator-precedence parser that can quickly examine arithmetic expressions" — and
  Clang's `ParseExpression` is a textbook precedence-climbing loop ([Bendersky][bendersky]).
- **Compiler-compiler output** embeds it too: "Operator-precedence parsers are also
  embedded within compiler-compiler-generated parsers to noticeably speed up the
  recursive descent approach to expression parsing" ([Wikipedia][wiki-opp]).
- **JavaScript tooling**: [Crockford][crockford] built the JSLint/JSHint parser (and
  influenced V8's early parser) directly on Pratt's technique — his 2007 essay is the
  most-cited modern exposition.
- **Parser-combinator libraries expose Pratt as a first-class helper** — the strongest
  cross-link from this page. [chumsky's `pratt` module][chumsky] lets you write an
  expression parser declaratively from `infix`/`prefix`/`postfix` builders with
  `left`/`right`/`none` associativity (see [the chumsky deep-dive][chumsky]):

  ```rust
  let expr = atom.pratt((
      postfix(4, op('!'), |lhs, _, _| Expr::Factorial(Box::new(lhs))),
      infix(right(3), op('^'), |l, _, r, _| Expr::Pow(Box::new(l), Box::new(r))),
      prefix(2, op('-'), |_, rhs, _| Expr::Neg(Box::new(rhs))),
      infix(left(1), op('+'), |l, _, r, _| Expr::Add(Box::new(l), Box::new(r))),
      infix(left(1), op('-'), |l, _, r, _| Expr::Sub(Box::new(l), Box::new(r))),
  ));
  ```

  chumsky's own docs name the lineage precisely: "Unlike precedence climbing, which
  defines operator precedence by structurally composing parsers of decreasing
  precedence, Pratt parsing defines precedence through a numerical 'binding power'" —
  and "Higher numbers should be used for higher precedence operators"
  ([`chumsky::pratt`][chumsky]). [pest][pest] ships an analogous `pratt_parser` module
  for post-processing a flat operator sequence into a tree.

- **Production language front-ends**: Lua (`subexpr` with a `priority` table), rustc
  (`parser::expr` with binding-power-style precedence), Go, and Zig all use a
  precedence-climbing/Pratt loop for expressions inside hand-written recursive descent.

The recurring pattern is the same: a [recursive-descent][top-down] parser owns statement
and declaration structure, and _delegates the expression_ to a Pratt / precedence-climbing
loop. That division of labor — [top-down][top-down] for structure, Pratt for expressions —
is the single most common architecture for production hand-written parsers, and it is the
reference point the [cross-family comparison][comparison] uses when weighing hand-written
parsers against the generator-based families.

---

## The equivalence: precedence climbing ⇔ Pratt

The two top-down presentations are **the same algorithm**. [Andy Chu (oilshell)][oilshell]
made the identification explicit, and [Norvell][norvell] now states it in his own notes:

> "It turns out that precedence climbing is a special case of a more flexible technique
> called Pratt parsing." — [Norvell][norvell]

The dictionary between them is mechanical:

| Precedence climbing ([Norvell][norvell])     | Pratt / TDOP ([Pratt][pratt-paper] / [Crockford][crockford]) |
| -------------------------------------------- | ------------------------------------------------------------ |
| `Exp(p)` — parse with **min precedence** `p` | `expression(rbp)` — parse with **right binding power** `rbp` |
| `P` — the atom / prefix / paren case         | the **`nud`** dispatch                                       |
| loop body — consume a binary operator        | the **`led`** dispatch                                       |
| `prec(op) >= p` — keep going                 | `rbp < token.lbp` — keep going                               |
| `q = 1 + prec(op)` (left-assoc)              | `led` calls `expression(bp)`                                 |
| `q = prec(op)` (right-assoc)                 | `led` calls `expression(bp - 1)`                             |

Precedence climbing is the _special case_ in which every token's role
(atom / unary / binary / paren) is decided by a fixed `if`-cascade inside `P`/`Exp`;
Pratt _generalizes_ it by moving that decision into a **per-token dispatch table**
(`nud`/`led` keyed by token type), which is what buys extensibility and lets a single
token (the unary/binary `-`) carry two roles. The numeric core — "consume operators
tighter than the threshold; recurse with `prec` or `prec+1` to set associativity" — is
identical. [Floyd's][floyd] bottom-up operator-precedence method is the _third_ face: the
same `prec(left) vs prec(right)` comparison, but resolved on an explicit stack with the
`⋖ ≐ ⋗` matrix instead of via the call stack. As [matklad shows][from-pratt], you can
even mechanically transform the recursive Pratt loop into Dijkstra's iterative
shunting-yard, completing the circle: **recursion ⇔ explicit stack** is the only real
difference across the whole family.

---

## Strengths

- **Tiny and transparent.** The core is ~15 lines ([Crockford][crockford],
  [matklad][matklad]); it can be written from memory, audited at a glance, and debugged
  with an ordinary stack trace. [Pratt][pratt-paper] himself sold it as "very simple to
  understand, trivial to implement, easy to use, extremely efficient in practice."
- **Linear time, minimal space.** `O(n)` time, `O(d)` stack, no generated tables, no
  memoization — the cheapest expression parser in this catalog.
- **Precedence/associativity as data.** Adding an operator or precedence level is a _new
  table row_, not a grammar rewrite — the [stratified-grammar][top-down] approach demands
  surgery on multiple nonterminals for the same change.
- **Extensible per token** (Pratt's `nud`/`led` / [Nystrom's][nystrom] parselets). New
  syntax is a new token handler; the core loop never changes. A single token can be both
  prefix and infix (the unary/binary `-`) without conflict.
- **One loop for the whole operator zoo.** Prefix, infix, postfix, and bracketed mixfix
  (ternary, indexing, calls, grouping) all reduce to binding-power shapes over one loop.
- **Composes with recursive descent.** It is _the_ expression engine to drop into a
  hand-written parser — structure handled top-down, expressions handled by Pratt.

## Weaknesses

- **Expressions only.** It parses operator expressions, not whole languages; it must be
  embedded in a surrounding parser for statements, declarations, and blocks.
- **Implicit, global disambiguation.** The grouping of an expression lives in the
  binding-power table, not in any readable grammar rule — easy to get subtly wrong, and
  the parser will silently produce a _valid but wrong_ tree rather than report a conflict
  (unlike an [`LALR`][bottom-up] generator, which flags a shift/reduce conflict).
- **No built-in ambiguity _detection_.** A genuinely ambiguous design is not caught;
  it is silently resolved by whatever the table happens to say.
- **Floyd's matrix is laborious and brittle.** The bottom-up relation-matrix form is
  `O(t²)` cells in the terminal count and chokes on operators that are both unary and
  binary — the reason the numeric top-down forms supplanted it for hand-written parsers.
- **Recovery is bolted on.** Error _detection_ is immediate, but error _recovery_ is the
  host parser's panic-mode job; the algorithm itself has none.
- **Juxtaposition / no-operator adjacency is awkward.** Languages with operator-free
  application (`f x y`) fit only by inventing an invisible infix operator.

---

## Key design decisions and trade-offs

| Decision                                                                | Rationale                                                                                      | Trade-off                                                                                                        |
| ----------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| **Precedence as a number** (binding power), not grammar                 | Adding/retuning an operator is a one-line table edit; one loop replaces a stratified grammar   | Disambiguation is implicit and global; the parse tree's shape is not visible in any single rule                  |
| **Associativity as binding-power asymmetry** (`+1` / `-1`)              | One mechanism (a direction of asymmetry) handles both left and right associativity             | Off-by-one in the asymmetry silently flips associativity — a classic, hard-to-spot bug                           |
| **Per-token `nud`/`led` dispatch** (Pratt) vs. fixed cascade (climbing) | Extensible: new syntax = new token handler; one token can be both prefix and infix (`-`)       | More machinery than precedence climbing's single `if`-cascade; the dispatch table is another thing to get right  |
| **Top-down recursion** (Pratt) vs. **bottom-up matrix** (Floyd)         | Recursion reuses the call stack and keys on _position_, killing the unary/binary-`-` problem   | Loses the explicit, inspectable handle stack; bottom-up is what compiler-compilers embed for generated parsers   |
| **Embed in recursive descent**, not a standalone parser                 | Best-of-both: structure top-down, expressions via Pratt — the dominant production architecture | Two sub-parsers to keep coherent; the boundary (where descent calls `expression(0)`) must be placed carefully    |
| **Resolve ambiguity by table**, not detect it                           | Zero parse-time ambiguity cost; `none`-associativity can turn illegal chains into clean errors | A genuinely ambiguous design is silently resolved, never reported — no conflict diagnostic like an `LALR` tool's |

---

## Sources

- R. W. Floyd, ["Syntactic Analysis and Operator Precedence"][floyd], _Journal of the
  ACM_ 10(3):316–333, 1963 — operator grammars, the `⋖ ≐ ⋗` precedence relations, the
  precedence-relation matrix as a bottom-up shift/reduce parser, and the unary/binary-sign
  precedence limitation.
- V. R. Pratt, ["Top Down Operator Precedence"][pratt-paper], _Proceedings of the 1st ACM
  SIGACT-SIGPLAN Symposium on Principles of Programming Languages (POPL)_, 1973, pp.
  41–51 — `nud`/`led`, left/right binding power, and the `expression(rbp)` loop;
  the critique of BNF-shaped expression parsing.
- T. Norvell, ["Parsing Expressions by Recursive Descent"][norvell] — the canonical
  **precedence climbing** pseudocode (`Exp(p)` / `P`, `q = prec` vs. `1 + prec`), the
  coining of the name, and the note that it is a special case of Pratt parsing.
- D. Crockford, ["Top Down Operator Precedence"][crockford] (2007) — the most-cited
  modern exposition; the verbatim `expression(rbp)` function, the `nud`/`led` definitions,
  and `infix`/`infixr` (associativity via `expression(bp)` vs. `expression(bp - 1)`).
- A. Kladov (matklad), ["Simple but Powerful Pratt Parsing"][matklad] (2020) — binding
  power as a left/right integer pair, associativity as asymmetry, and the Rust
  `expr_bp(lexer, min_bp)` reference handling prefix/infix/postfix/mixfix in one loop;
  and ["From Pratt to Dijkstra"][from-pratt] for the Pratt ⇔ shunting-yard transform.
- A. Chu (oilshell), ["Pratt Parsing and Precedence Climbing Are the Same
  Algorithm"][oilshell] (2016) — the explicit identification of precedence climbing as a
  special case of Pratt parsing.
- E. Bendersky, ["Parsing expressions by precedence climbing"][bendersky] (2012) and
  ["Top-Down operator precedence (Pratt) parsing"][bendersky-tdop] (2010) — the
  `compute_expr(min_prec)` / `OPINFO` presentation and Clang's use of precedence climbing.
- B. Nystrom, ["Pratt Parsers: Expression Parsing Made Easy"][nystrom] (2011) — the
  `PrefixParselet`/`InfixParselet` (parselet) reframing of `nud`/`led`.
- A. Aho, M. Lam, R. Sethi & J. Ullman, _Compilers: Principles, Techniques, and Tools_,
  2nd ed. (the [Dragon Book][dragon]), §4.4 "Top-Down Parsing" — panic-mode error recovery
  for expression parsing. (Operator-precedence parsing and the unary-minus remark are
  1st-edition material: Aho, Sethi & Ullman, 1986, §4.6 "Operator-Precedence Parsing".)
- [chumsky `pratt` module docs][chumsky] and [`src/pratt.rs`][chumsky-src] — a production
  parser-combinator library exposing Pratt parsing as `infix`/`prefix`/`postfix` builders
  with `left`/`right`/`none` associativity (see [the chumsky deep-dive][chumsky-deep]).
- [Wikipedia, "Operator-precedence parser"][wiki-opp] — the GCC/Clang and Crockford/JSLint
  usage notes and the Pratt/precedence-climbing/shunting-yard relationships.

<!-- References -->

<!-- Same-tree theory siblings -->

[theory-index]: ./index.md
[top-down]: ./top-down.md
[bottom-up]: ./bottom-up.md
[formal]: ./formal-languages.md
[general]: ./general-parsing.md
[peg]: ./peg-packrat.md

<!-- Tree umbrella / concepts / comparison -->

[concepts]: ../concepts.md
[comparison]: ../comparison.md

<!-- Library deep-dives -->

[chumsky-deep]: ../rust-chumsky.md
[pest]: ../pest.md

<!-- External primary sources -->

[floyd]: https://dl.acm.org/doi/10.1145/321172.321179
[pratt-paper]: https://dl.acm.org/doi/10.1145/512927.512931
[norvell]: https://www.engr.mun.ca/~theo/Misc/exp_parsing.htm
[crockford]: https://www.crockford.com/javascript/tdop/tdop.html
[matklad]: https://matklad.github.io/2020/04/13/simple-but-powerful-pratt-parsing.html
[from-pratt]: https://matklad.github.io/2020/04/15/from-pratt-to-dijkstra.html
[oilshell]: https://www.oilshell.org/blog/2016/11/01.html
[bendersky]: https://eli.thegreenplace.net/2012/08/02/parsing-expressions-by-precedence-climbing
[bendersky-tdop]: https://eli.thegreenplace.net/2010/01/02/top-down-operator-precedence-parsing/
[nystrom]: https://journal.stuffwithstuff.com/2011/03/19/pratt-parsers-expression-parsing-made-easy/
[dragon]: https://web.archive.org/web/20260610070726/https://suif.stanford.edu/dragonbook/
[chumsky]: https://docs.rs/chumsky/latest/chumsky/pratt/index.html
[chumsky-src]: https://github.com/zesterer/chumsky/blob/4879268c589b18927df6ec21331e66d7fb56df86/src/pratt.rs
[wiki-opp]: https://en.wikipedia.org/wiki/Operator-precedence_parser
