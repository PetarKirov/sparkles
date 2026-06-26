# Menhir (OCaml)

A modern LR(1) parser generator for OCaml whose distinguishing features are human-readable conflict explanations, parameterized grammar rules, a reversible incremental API exposing the parser as a pure state machine, and a [Rocq/Coq](#error-handling--recovery) back-end that emits a formally verified parser.

| Field                     | Value                                                                                                                         |
| ------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| Language                  | OCaml (generator and runtime), plus a Rocq/Coq library                                                                        |
| License                   | GPL v2 (generator); LGPL v2 (runtime library `MenhirLib`); LGPL v3+ (Coq library `coq-menhirlib`)                             |
| Repository                | [`gitlab.inria.fr/fpottier/menhir`][repo]                                                                                     |
| Documentation             | [Menhir Reference Manual][manual] · [project page][home]                                                                      |
| Key authors               | François Pottier and Yann Régis-Gianas (Jacques-Henri Jourdan — Rocq back-end; Frédéric Bour, Thomas Refis — incremental API) |
| Category                  | Generator (LR), external `.mly` DSL, table- or code-based back-end                                                            |
| Algorithm / grammar class | LR(1); Pager's minimal-state construction by default, with optional canonical-LR(1) and LALR(1) modes; optional GLR back-end  |
| Lexing model              | Separate lexer (typically [`ocamllex`][ocamllex]); a `Lexing.lexbuf -> token` function — **not** scannerless                  |
| AST/CST construction      | User-written OCaml semantic actions; values built bottom-up on reduction                                                      |
| Latest release            | `20260209` (date-stamped release line; `--GLR` first shipped in `20260112`)                                                   |

> [!NOTE]
> Menhir uses **date-stamped** version numbers (`20231231`, `20240715`, `20260122`, `20260209`, …) rather than SemVer. The upstream repository lives on Inria's GitLab; a read-only GitHub mirror exists at [`savonet/mehnir`][mirror]. This deep-dive cites the upstream source and the dated reference manual.

---

## Overview

### What it solves

A parser generator turns a declarative grammar — productions decorated with code fragments that build the result — into an efficient deterministic parser. OCaml's traditional tool is [`ocamlyacc`][ocamllex], a near-direct port of Berkeley `yacc`: it builds an **LALR(1)** automaton, reports conflicts only as opaque state numbers, uses a single mutable global parser, and offers no facilities for parameterized rules, error-message engineering, or incremental use. Menhir is the modern replacement. From the [reference manual][manual] introduction:

> _"Menhir is a parser generator. It turns high-level grammar specifications, decorated with semantic actions expressed in the OCaml programming language, into parsers, again expressed in OCaml. It is based on Knuth's LR(1) parser construction technique. It is strongly inspired by its precursors: yacc, ML-Yacc, and ocamlyacc, but offers a large number of minor and major improvements that make it a more modern tool."_ — [Menhir Reference Manual, §1][manual]

Menhir keeps the `yacc` family's strengths — a declarative external [grammar DSL](#interface--composition-model), bottom-up [LR parsing](./theory/bottom-up.md) with the linear-time guarantee, deterministic conflict resolution by precedence — while fixing the historical pain points the `yacc` lineage is notorious for:

1. **Conflicts are explained in grammatical terms.** `--explain` produces a `.conflicts` file with example sentences and partial derivation trees, not a raw automaton dump (see [Algorithm & grammar class](#algorithm--grammar-class)).
2. **Boilerplate is abstracted away.** [Parameterized rules](#interface--composition-model) plus a [standard library](#interface--composition-model) (`option`, `list`, `separated_list`, …) eliminate the hand-written recursive list rules that bloat `yacc` grammars.
3. **Two run modes.** A traditional _monolithic_ entry point compatible with `ocamlyacc`, and an [_incremental_ API](#interface--composition-model) that inverts control and exposes the parser as a pure, suspendable state machine — the substrate for [Merlin](#error-handling--recovery) and `ocaml-lsp`.
4. **Syntax-error messages can be engineered offline.** `--list-errors` enumerates every error state; a `.messages` file maps each to a custom diagnostic that `--compile-errors` bakes into OCaml (see [Error handling](#error-handling--recovery)).
5. **The parser can be formally verified.** The `--rocq` (historically `--coq`) back-end emits a parser _plus a machine-checked proof_ that it is correct and complete with respect to the grammar — the technology behind [CompCert](#error-handling--recovery)'s front end.

### Design philosophy

Menhir's stance is that an LR generator should be _more powerful and more humane_ than `yacc` without abandoning the LR formalism. It accepts strictly more grammars than `ocamlyacc` because it builds **LR(1)** automata rather than **LALR(1)** ones, and it spends its complexity budget on _explaining_ the residual conflicts rather than hiding them. The [Real World OCaml][rwo] chapter on parsing states the practical conclusion bluntly:

> _"Menhir is an alternative parser generator that is generally superior to the venerable `ocamlyacc` … The biggest advantage of Menhir is that its error messages are generally more human-comprehensible … We recommend that any new code you develop should use Menhir instead of `ocamlyacc`."_ — [Real World OCaml, "Parsing with OCamllex and Menhir"][rwo]

Three commitments shape the rest of the tool. First, **the grammar is the specification**: parameterized rules and `%inline` let a grammar be factored like a functional program, and the `.conflicts`/`.automaton`/`.messages` files are all expressed back in terms of that grammar. Second, **the parser is a value, not a global**: generated parsers are reentrant, and the incremental back-end makes a parser _state_ a first-class persistent data structure — exactly the property an editor needs. Third, **correctness is auditable**: rather than trust a complex generator, Menhir's verified mode emits a certificate that an independently proved validator checks, so the _generator_ never has to be trusted (see [Error handling](#error-handling--recovery)).

Within this survey Menhir is the canonical _modern, usable LR_ data point. Contrast it with its `yacc`-family predecessor [Bison/yacc](./bison-yacc.md); with the [ANTLR](./antlr.md) ALL(\*) top-down generator; with [tree-sitter](./tree-sitter.md), the other production _incremental_ parser (GLR with a separate context-aware lexer) used by editors; and with the combinator and PEG families ([nom](./rust-nom.md), [chumsky](./rust-chumsky.md), [Parsec](./haskell-parsec.md), [pest](./pest.md)). The [theory of bottom-up parsing](./theory/bottom-up.md) underpins everything here; the [comparison capstone](./comparison.md) places Menhir against the field.

---

## How it works

### The grammar file and the pipeline

A Menhir grammar lives in a `.mly` file with three sections separated by `%%`: a _header_ of OCaml declarations, a _declarations_ block (`%token`, `%start`, `%type`, precedence), and the _rules_. Each production carries an OCaml **semantic action** in braces that computes the nonterminal's value from its components. A minimal calculator (after the manual's running example):

```ocaml
(* parser.mly *)
%token <int> INT
%token PLUS TIMES LPAREN RPAREN EOL
%start <int> main
%left PLUS          (* lowest precedence *)
%left TIMES         (* higher precedence *)
%%
main:
| e = expr; EOL                 { e }
expr:
| i = INT                       { i }
| LPAREN; e = expr; RPAREN      { e }
| a = expr; PLUS;  b = expr     { a + b }
| a = expr; TIMES; b = expr     { a * b }
```

Menhir compiles this to `parser.ml`/`parser.mli`. Note the use of **named** semantic values (`e = expr`) — Menhir supports both the `yacc` positional `$1`/`$2` form and named bindings, the latter being the idiomatic style. The `%left` declarations disambiguate the two genuinely conflicting productions (`expr PLUS expr` and `expr TIMES expr`) by [precedence](./theory/pratt-precedence.md), the classic `yacc` mechanism.

### Lexing model — a separate scanner

Menhir is **not** scannerless. It consumes a stream of tokens produced by a separate lexer, conventionally generated by [`ocamllex`][ocamllex], and the two communicate through the `%token` declarations and the generated `token` type. The monolithic entry point has the `ocamlyacc`-compatible signature ([reference manual][manual]):

```ocaml
val main: (Lexing.lexbuf -> token) -> Lexing.lexbuf -> int
```

That is, the generated `main` function _"expects two arguments, namely: a lexer, which typically is produced by `ocamllex` and has type `Lexing.lexbuf -> token`; and a lexing buffer."_ ([§ on the monolithic API][manual]). Splitting lexing from parsing is the classical division of labour: regular tokenization happens in a DFA, and only the context-free structure reaches the LR automaton. The downside — token/parser feedback for languages like C (the "[lexer hack](#error-handling--recovery)") — Menhir addresses through its incremental API rather than scannerless parsing.

### Core abstractions

| Concept                | Type / construct                           | Role                                                                             |
| ---------------------- | ------------------------------------------ | -------------------------------------------------------------------------------- |
| Grammar symbol         | `%token`, nonterminal rules                | Terminals (with optional carried OCaml type `<int>`) and nonterminals            |
| Start symbol           | `%start <ty> main`                         | An entry nonterminal; generates a typed entry function returning `ty`            |
| Semantic action        | `{ ... OCaml expr ... }`                   | Bottom-up value construction, run on each reduction                              |
| Parameterized rule     | `rule(X, Y): ...`                          | A rule abstracted over symbols; instantiated by substitution at compile time     |
| Inlinable rule         | `%inline rule(...)`                        | Macro-expanded into call sites (avoids spurious conflicts, fuses actions)        |
| Precedence             | `%left` / `%right` / `%nonassoc` / `%prec` | Conflict resolution by token precedence level and associativity                  |
| Monolithic parser      | `Parser.main`                              | The `ocamlyacc`-style "give me a lexer, get a tree" entry point                  |
| Incremental parser     | `MenhirInterpreter.checkpoint`             | A suspendable parser state (see [the step model](#interface--composition-model)) |
| Inspection state       | `'a lr1state`, `element`, `xsymbol`        | Runtime introspection of automaton states and the typed value stack              |
| Error-message database | `.messages` file + `--compile-errors`      | Maps error states to human diagnostics                                           |

### The LR automaton, as actually built

Menhir realizes Knuth's canonical LR(1) construction but, by default, **merges states** to keep the table small using Pager's algorithm — the same minimal-state technique modern LR generators reach for. The construction mode is a command-line choice ([manpage][manpage]):

| Flag          | Construction                                                                               |
| ------------- | ------------------------------------------------------------------------------------------ |
| _(default)_   | Minimal LR(1) via Pager's weak-compatibility state merging                                 |
| `--canonical` | _"Construct a canonical Knuth LR(1) automaton."_ — no state merging, no default reductions |
| `--lalr`      | _"Construct an LALR(1) automaton."_ — `ocamlyacc`-compatible, weaker                       |
| `--GLR`       | Generalized LR back-end (new in `20260112`) for ambiguous grammars                         |

Pager's algorithm is cited in the manual to David Pager, _"A practical general method for constructing LR(k) parsers,"_ Acta Informatica 7:249–268, 1977. The key property: the default automaton recognizes the **full LR(1)** class (strictly larger than LALR(1)), so grammars that provoke spurious reduce/reduce conflicts under `ocamlyacc` are accepted unchanged under Menhir. `--dump` writes the resulting automaton to `basename.automaton` for inspection.

When the grammar is genuinely ambiguous, Menhir resolves conflicts the `yacc` way and warns. The manual is explicit that the defaults mirror `ocamlyacc`:

> _"It is unspecified how severe conflicts are resolved. Menhir attempts to mimic `ocamlyacc`'s specification, that is, to resolve shift/reduce conflicts in favour of shifting, and to resolve reduce/reduce conflicts in favour of the production that textually appears earliest in the grammar specification."_ — [Menhir Reference Manual][manual]

---

## Algorithm & grammar class

**Formalism.** Menhir is a [bottom-up, shift-reduce LR parser generator](./theory/bottom-up.md). It builds a deterministic pushdown automaton whose action (shift or reduce) is chosen from the current state and **one** token of lookahead. The accepted class is **LR(1)** by default — the largest class a deterministic single-lookahead bottom-up parser can handle — narrowing to LALR(1) under `--lalr` or widening to the full canonical LR(1) under `--canonical`. As of `20260112`, an optional `--GLR` back-end lifts the determinism requirement entirely, splitting the parse stack to explore ambiguous alternatives in parallel (the [general-parsing](./theory/general-parsing.md) regime that [tree-sitter](./tree-sitter.md) also inhabits).

**Ambiguity handling.** A non-LR(1) grammar yields _conflicts_. Menhir distinguishes _benign_ conflicts (resolved by precedence/associativity declarations, silently) from _severe_ ones (resolved by the default shift/earliest-production rule, with a warning). `--strict` promotes warnings to errors so a grammar cannot accidentally ship with unexplained conflicts.

**The headline feature: human-readable conflict explanations.** This is what most sharply separates Menhir from `yacc`/`ocamlyacc`. With `--explain`, Menhir writes a `basename.conflicts` file. Crucially, from the manual:

> _"Not all conflicts are explained in this file: instead, only one conflict per automaton state is explained."_ … _"there is also a way of understanding conflicts in terms of the grammar, rather than in terms of the automaton."_ — [Menhir Reference Manual, §6.2][manual]

For each conflicted state the file shows a _conflict string_ (a concrete sequence of symbols that reaches the state), the _conflict token_, and two **partial derivation trees** — one justifying each candidate action — so a grammar author sees an actual example sentence that exposes the ambiguity and can reason in their own grammar's terms. `yacc`'s `y.output` gives only item sets and state numbers; Menhir's `.conflicts` reads like a worked proof. (Compare [Bison's](./bison-yacc.md) counterexample generator, a later convergent feature, and contrast with [PEG](./theory/peg-packrat.md) tools like [pest](./pest.md) that sidestep conflicts by _ordered choice_ — making ambiguity silently disappear rather than diagnosable.)

---

## Interface & composition model

**External DSL, generator model.** Grammars are an external `.mly` language compiled ahead of time, the opposite of the embedded-combinator model of [nom](./rust-nom.md), [chumsky](./rust-chumsky.md), or [Parsec](./haskell-parsec.md). The host-language integration is tight: semantic actions are arbitrary OCaml, the carried token types are OCaml types, and (with `--infer`) Menhir _"invoke[s] `ocamlc` to do type inference"_ ([manpage][manpage]) so action code is type-checked against the rest of the program.

**AST/CST construction** is fully under user control: each reduction runs its semantic action, building values bottom-up. There is no implicit parse tree — the action that fires for `a = expr; PLUS; b = expr` returns whatever the user writes (`a + b`, or a `BinOp` AST node). This is the same "you build the tree" philosophy as [Bison](./bison-yacc.md) and the inverse of [tree-sitter](./tree-sitter.md), which always materializes a concrete syntax tree.

**Parameterized rules and the standard library.** Menhir's most loved ergonomic feature is _rules abstracted over symbols_, instantiated by substitution at generation time. The bundled `standard.mly` ships the combinators that every `yacc` grammar otherwise re-implements by hand. Verbatim from the [standard library source][stdlib]:

```ocaml
%public option(X):
  /* nothing */
    { None }
| x = X
    { Some x }

%public list(X):
  /* nothing */
    { [] }
| x = X; xs = list(X)
    { x :: xs }

%public separated_nonempty_list(separator, X):
  x = X
    { [ x ] }
| x = X; separator; xs = separated_nonempty_list(separator, X)
    { x :: xs }

%public %inline separated_list(separator, X):
  xs = loption(separated_nonempty_list(separator, X))
    { xs }
```

The library also provides `nonempty_list`, `ioption`/`boption`/`loption`, `pair`, `separated_pair`, `preceded`, `terminated`, and `delimited`, plus the postfix sugar `X?` ≡ `option(X)`, `X*` ≡ `list(X)`, `X+` ≡ `nonempty_list(X)`. A grammar can therefore write `separated_list(COMMA, expr)` instead of a hand-rolled left/right-recursive pair of rules — eliminating an entire genus of `yacc` boilerplate and the subtle empty-list bugs that come with it. `%inline` (verbatim from the manual: _"causes all references to … its definition"_ to be replaced) macro-expands a rule into its call sites, which both fuses semantic actions and _removes spurious conflicts_ that the indirection would otherwise create.

**Two run modes.** The same grammar can be compiled to either of two parser interfaces:

1. **Monolithic** — the default, `ocamlyacc`-compatible: one call, `Parser.main lexer lexbuf`, drives lexing and parsing to completion and returns the tree (or raises `Parser.Error`).

2. **Incremental** — selected with `--table`, the parser becomes a **pure, suspendable state machine**. The manual's framing is that "control is inverted": the parser _does not_ pull tokens from a lexer; instead it hands control back to the caller each time it needs input. The interface is the `'a checkpoint` algebraic type, verbatim from the manual:

   ```ocaml
   type 'a checkpoint = private
     | InputNeeded of 'a env
     | Shifting of 'a env * 'a env * bool
     | AboutToReduce of 'a env * production
     | HandlingError of 'a env
     | Accepted of 'a
     | Rejected
   ```

   The driver advances the machine with two functions:

   ```ocaml
   val offer:  'a checkpoint -> token * position * position -> 'a checkpoint
   val resume: 'a checkpoint -> 'a checkpoint
   ```

   `offer` feeds the next `(token, start, end)` triple when the checkpoint is `InputNeeded`; `resume` continues across the internal `Shifting`/`AboutToReduce`/`HandlingError` steps. For callers that don't need the fine-grained steps, `loop`, `loop_handle`, and `loop_handle_undo` wrap a token _supplier_ into a `yacc`-like loop — and `loop_handle_undo` notably hands the caller _both_ the error checkpoint **and** the last `InputNeeded` checkpoint, the hook for backtracking-based error recovery.

   Because semantic values are immutable, a `checkpoint` is a **persistent data structure**: it can be stored, resumed multiple times, and diffed — the enabling property for caching and "live parsing" while a buffer is edited (see [Error handling](#error-handling--recovery)).

**The inspection API** (`--inspection`, which requires `--table`) adds a typed view of the automaton and stack. It exposes a GADT-typed state and stack element, verbatim:

```ocaml
type element =
  | Element : 'a lr1state * 'a * position * position -> element
val top:    'a env -> element option
val number: _ lr1state -> int
```

`lr1state` is the type of an automaton state _indexed by the OCaml type of the semantic value it holds_; `top`/`pop` walk the stack returning `element`s whose existential `'a` recovers each value's true type. This is what lets tooling fetch the AST fragment around the cursor, print its location, or implement a _contextual scanner_ (a lexer indexed by parser state) as a pure function of the parser stack rather than via mutable global state.

---

## Performance

**Time and space.** Like every [LR parser](./theory/bottom-up.md), a Menhir parser runs in **O(n)** time in the input length, with a constant number of stack operations per token — no [backtracking](./theory/top-down.md), no [memoization](./theory/peg-packrat.md), no exponential blow-up. There is no SIMD or data-parallel angle (that is the province of [simdjson](./simdjson.md)); the LR automaton is inherently sequential, one token of one-symbol lookahead at a time. Memory is the parse stack plus the user's growing AST.

**Two back-ends with different trade-offs.** Menhir can emit the automaton as either:

- **Code back-end** (default for the monolithic API): the automaton states become OCaml functions. This produces the fastest parser but a larger module, and it does _not_ support the incremental/inspection APIs.
- **Table back-end** (`--table`): the automaton is encoded as compact data tables interpreted by the runtime `MenhirLib`. This is _required_ for the incremental and inspection APIs, yields much smaller generated code, and is typically a small constant factor slower than the code back-end.

**Allocation and zero-copy.** Token positions are `Lexing.position` records threaded from the lexer; Menhir itself does not copy input text (it never sees the bytes — only tokens), so "zero-copy" is really a property of how the _lexer_ and the _user's actions_ are written. There is no streaming input model beyond the pull-based lexer interface; the incremental API streams _tokens_, not bytes.

**Published performance data.** The most-cited hard number comes from the verified-parser line of work: replacing CompCert's unverified `ocamlyacc` LALR parser with Menhir's Rocq-verified parser made the front end _"about 5 times slower than the old one, increasing overall compilation times by about 20%"_ (from the [Validating LR(1) Parsers][validating-blog] work). That figure is the cost of the _verified interpreter_, not of ordinary Menhir parsers — the standard code back-end is competitive with `ocamlyacc`. For _incremental_ re-parsing performance in an editor setting, see [tree-sitter](./tree-sitter.md), whose design target is sub-millisecond keystroke reparsing; Menhir's incremental API gives the _mechanism_ (resumable persistent states) but leaves the reparsing strategy to the client (Merlin).

---

## Error handling & recovery

This dimension is where Menhir most clearly defines the state of the art in usable LR tooling — it attacks error _messages_, error _recovery_, and _verification_ on three separate fronts.

**1. Engineered syntax-error messages (the `.messages` mechanism).** Rather than a generic `"syntax error"`, Menhir lets you attach a _specific_ diagnostic to every error state. The workflow uses two flags ([manpage][manpage]): `--list-errors` _"produce[s] a list of erroneous inputs"_ — one minimal input sentence per reachable error state, in the `.messages` format — and `--compile-errors` _"compile[s] a `.messages` file to OCaml code."_ You fill in a human message for each enumerated state once; `--compile-errors` turns the database into a function `message : int -> string` keyed on the automaton state number. Auxiliary flags (`--compare-errors`, `--merge-errors`, `--update-errors`) keep the message database in sync as the grammar evolves, so a message can never silently drift away from the state it describes. This is the technique behind the OCaml compiler's and many production parsers' precise syntax diagnostics.

**2. Resumable error recovery via the incremental API.** When the incremental parser reaches `HandlingError env`, the _entire parser state is in the caller's hands_ as a persistent value — including, via `loop_handle_undo`, the last good `InputNeeded` checkpoint. A client can inspect the stack (inspection API), synthesize a plausible token, and `resume`, or roll back and retry. This is exactly how [Merlin][merlin], the OCaml language server, achieves error-tolerant parsing of half-written code. The [Merlin experience report][merlin] records the lineage and the design:

> _"The Merlin authors developed an incremental parsing interface for Menhir, a parsing generator that is compatible with OCamlyacc's grammars; it is implemented in OCaml rather than C, so more convenient to develop and extend."_ … _"The work on an incremental Menhir interface started within Merlin in December 2013. It was adapted by François Pottier and merged in the upstream Menhir code in December 2014."_ — [Bour, Refis & Scherer, "Merlin: A Language Server for OCaml"][merlin]

Merlin annotates its grammar with `[@cost n]` and `[@recovery v]` attributes that tell a Menhir extension how cheaply to _synthesize_ a missing token or supply a default semantic value, letting the parser fabricate a well-typed partial AST past an error. The same report notes the broader payoff — that this turns recovery into a _parser-agnostic_ capability: _"it is easy to add recovery capabilities to a parser, for any language, written using the Menhir parser generator."_ The persistent-state property is what makes editor "live parsing" feasible: a `checkpoint` is immutable, so intermediate parser states can be cached and partially re-used as the buffer changes. Merlin and [`ocaml-lsp`][ocamllsp] are the production consumers; the [Reason][reason] toolchain reuses the same machinery.

**3. Formal verification (the Rocq/Coq back-end).** Menhir can emit, instead of OCaml, a parser written in the [Rocq](https://rocq-prover.org/) proof assistant (Coq's successor; the flag was `--coq`, now `--rocq`). From the manual:

> _"When the 'Rocq' back-end is used, the semantic actions are fragments of Rocq code, and the parser produced by Menhir is a piece of Rocq code that contains not only a parser, but also a proof that this parser is correct and complete with respect to the grammar."_ — [Menhir Reference Manual, §12][manual]

The architecture is _a-posteriori validation_, not a verified generator. As the designer describes it ([Gagallium blog][validating-blog]): Menhir _"generates a Coq version of the Grammar, together with an LR(1)-like automaton and a certificate for this automaton,"_ and _"a validator, written in Coq, checks that this certificate is valid."_ The advantage is that the complex generator never has to be trusted — only the much simpler validator is proved once and for all. The guarantees are _soundness_ (an accepted input's returned value is valid for the grammar) **and** _completeness_ (every input with a semantic value is accepted) — though, per the manual, the completeness proof _"is possible only if the grammar has no conflict (not even a benign one)."_ This work was first published as **Jourdan, Pottier & Leroy, "Validating LR(1) Parsers" (ESOP 2012)**, whose abstract states:

> _"We present a validator which, when applied to a context-free grammar G and an automaton A, checks that A and G agree. … The validation process is independent of which technique was used to construct A. The validator is implemented and proved correct using the Coq proof assistant. As an application, we build a formally-verified parser for the C99 language."_ — [Jourdan, Pottier & Leroy, "Validating LR(1) Parsers"][validating-pdf]

This verified parser is the front end of the **[CompCert][compcert]** verified C compiler, replacing its earlier unverified `ocamlyacc` LALR automaton. The follow-on **Jourdan & Pottier, "A Simple, Possibly Correct LR Parser for C11" (TOPLAS 2017)** ([DOI 10.1145/3064848][c11-doi]) extends the approach to C11's notorious ambiguities, combining an LR parser with _lexical feedback_ (the typedef/identifier "lexer hack"). Its abstract is candid about the limit of the technique — the title's "Possibly Correct" is literal:

> _"Our solution employs the well-known technique of combining an LALR(1) parser with a 'lexical feedback' mechanism. … Although not formally verified, our parser avoids several pitfalls that other implementations have fallen prey to."_ — [Jourdan & Pottier, "A Simple, Possibly Correct LR Parser for C11"][c11-abstract]

> [!IMPORTANT]
> The two strands are distinct. The **ESOP 2012 validator** gives a _machine-checked_ parser (used in CompCert). The **TOPLAS 2017 C11 parser** is _engineered for correctness but not formally verified_ — "possibly correct" — because the lexer-feedback interaction with `scope` lies outside the validated automaton. Menhir provides the verified-LR _mechanism_; whether a particular real-world parser is fully verified depends on whether everything (lexer included) is inside the proof.

**IDE-readiness.** Between the inspection API (typed stack access), the incremental API (resumable persistent states), the `.messages` mechanism (precise diagnostics), and the recovery extension, Menhir is exceptionally well-suited to editor tooling — the reason it, not `ocamlyacc`, underpins the entire modern OCaml IDE stack.

---

## Ecosystem & maturity

**Adoption.** Menhir is the _de facto_ parser generator of the OCaml ecosystem. It is the recommended choice over `ocamlyacc` in [Real World OCaml][rwo], is packaged as the `menhir` opam package (with `menhirLib` and `menhirSdk` companions), and is integrated as a first-class rule in the `dune` build system. Production users include the **OCaml compiler family** and tooling around it, **[Merlin][merlin]** and **[`ocaml-lsp`][ocamllsp]** (incremental + recovery), **[CompCert][compcert]** (Rocq back-end), **[Reason][reason]**, **[Coq/Rocq][compcert]** itself for some front ends, and a long tail of language implementations. Frédéric Bour also maintains a [`LexiFi/menhir`][lexifi] fork tracking the incremental-recovery features.

**Stability and tooling.** The tool is mature (development since the mid-2000s; Pottier & Régis-Gianas' design paper dates to 2006) and actively maintained, with dated releases through `20260209`. The ecosystem around it includes `menhirLib` (runtime tables), the `menhirSdk` (the "[Menhir development kit][merlin]" exposing serialized grammar and automaton for third-party annotation processors — what powers Merlin's recovery as an _external_ tool), the `.automaton`/`.conflicts`/`.messages` artifacts, and `coq-menhirlib` for the verified back-end. The newest direction remains the `--GLR` back-end introduced in `20260112`, which moves Menhir beyond deterministic LR into [generalized parsing](./theory/general-parsing.md) for naturally ambiguous grammars.

**Notable derivatives and relatives.** The incremental + recovery features began as Merlin's fork and were partly upstreamed; the verified back-end seeded a line of formally verified front-end work (CompCert, and the C11 parser). In the broader field, Menhir's _conflict-explanation_ idea later converged with [Bison's](./bison-yacc.md) counterexample generation, and its _incremental editor parser_ role overlaps with [tree-sitter](./tree-sitter.md) (which takes the GLR + context-aware-lexer route instead). For the LR formalism Menhir implements, see the [bottom-up parsing theory deep-dive](./theory/bottom-up.md); for where it sits among all surveyed tools, the [comparison](./comparison.md).

---

## Strengths

- **More powerful than `ocamlyacc`**: full **LR(1)** (and optionally canonical LR(1)) accepts grammars that LALR(1) rejects with spurious conflicts; `--lalr` remains for compatibility.
- **Best-in-class conflict diagnostics**: `--explain`'s `.conflicts` file shows example sentences and partial derivation trees _in terms of the grammar_, not automaton state numbers.
- **Boilerplate-free grammars**: parameterized rules + the `option`/`list`/`separated_list` standard library + `%inline` + `?`/`*`/`+` sugar replace hand-written list recursion.
- **Incremental API**: the parser as a pure, suspendable, _persistent_ state machine — the substrate for Merlin/`ocaml-lsp` error recovery and live parsing.
- **Typed inspection API**: GADT-indexed `lr1state`/`element` give type-safe access to the parser stack, enabling cursor-aware tooling and a pure contextual scanner.
- **Engineered error messages**: `--list-errors` + `.messages` + `--compile-errors` give a maintainable database of precise, state-specific diagnostics.
- **Formal verification path**: the Rocq/Coq back-end emits a _certified_ parser via a-posteriori validation, used in CompCert.
- **Reentrant, host-integrated**: generated parsers are values (not globals), type-inferred against the program via `--infer`, and packaged cleanly through opam/dune.

## Weaknesses

- **Not scannerless**: a separate lexer is required, and lexer↔parser feedback (the C "lexer hack") must be handled out-of-band (via the incremental API or mutable state) rather than through a scannerless grammar or a [tree-sitter](./tree-sitter.md)-style context-aware lexer.
- **LR conflicts are still LR conflicts**: ambiguous or non-LR(1) grammars require precedence hacks or grammar refactoring; the diagnostics are excellent but the _constraint_ remains (contrast the always-unambiguous [ordered choice](./theory/peg-packrat.md) of PEGs, which trades the problem for silent disambiguation).
- **Verified back-end has a real cost**: the Rocq-validated parser ran ~5× slower in CompCert; completeness proofs require a _conflict-free_ grammar.
- **OCaml-only**: the generator targets OCaml (and Rocq); it is not a cross-language tool like [ANTLR](./antlr.md).
- **Incremental/inspection features need the table back-end** (`--table`), forgoing the fastest code back-end and adding the `menhirLib` runtime dependency.
- **Date-stamped versioning** (`20260209`) gives no SemVer signal about breaking changes; the rich feature surface (`--explain`, `.messages`, incremental, inspection, Rocq) has a learning curve beyond plain `yacc`.

## Key design decisions and trade-offs

| Decision                                                        | Rationale                                                                                             | Trade-off                                                                                                 |
| --------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| Build full **LR(1)** (Pager minimal states) by default          | Accept strictly more grammars than `ocamlyacc`'s LALR(1); avoid spurious conflicts                    | Larger automaton than LALR(1); `--canonical` larger still; still a _deterministic_ (conflict-prone) class |
| Explain conflicts **in grammar terms** with example sentences   | A grammar author can debug in their own vocabulary, not automaton state numbers                       | Only one conflict per state is explained; doesn't _remove_ the conflict, only diagnoses it                |
| Parameterized rules + standard library + `%inline`              | Factor grammars like functional programs; delete hand-rolled list recursion and its empty-list bugs   | A layer of abstraction between grammar text and automaton; `%inline` sometimes needed to dodge conflicts  |
| Offer **both** a monolithic and an incremental API              | Keep `ocamlyacc` compatibility _and_ enable editor tooling from one grammar                           | Incremental/inspection require the slower table back-end + `menhirLib` runtime                            |
| Incremental parser as a **pure persistent state machine**       | Inverts control so editors own the loop; states are cacheable/resumable for recovery and live parsing | More complex client code than "call parser, get tree"; recovery logic lives in the client (Merlin)        |
| GADT-typed inspection (`lr1state`, `element`)                   | Type-safe stack access enables cursor-aware tooling and pure contextual scanning                      | Requires OCaml GADTs (≥ 4.00) and the table back-end; an advanced API                                     |
| `.messages` database compiled by `--compile-errors`             | Precise, maintainable, state-specific syntax errors that can't silently drift from the grammar        | One-time and ongoing effort to author/maintain a message per error state                                  |
| Verify by **a-posteriori validation**, not a verified generator | Only a small validator must be proved; the complex generator stays untrusted; technique-independent   | Verified parser ~5× slower; completeness needs a conflict-free grammar; lexer feedback stays unverified   |
| Separate lexer (`ocamllex`), not scannerless                    | Clean regular/context-free separation; classic, fast tokenization                                     | Lexer↔parser feedback (C typedefs) needs the incremental API or mutable state, not a built-in mechanism   |

---

## Sources

- [Menhir Reference Manual][manual] — the authoritative reference (conflicts/`--explain`, incremental & inspection APIs, Rocq back-end, `.messages`)
- [`gitlab.inria.fr/fpottier/menhir`][repo] — upstream source; [GitHub mirror][mirror]; [`src/standard.mly`][stdlib] — the parameterized standard library
- [Menhir project page][home] and [`menhir(1)` manpage][manpage] — command-line flags (`--canonical`, `--lalr`, `--list-errors`, `--compile-errors`, `--rocq`, `--infer`, `--GLR`)
- François Pottier & Yann Régis-Gianas — Menhir's original design (the 2006 typed-LR work referenced by the Merlin report)
- [F. Bour, T. Refis & G. Scherer, "Merlin: A Language Server for OCaml (Experience Report)," ICFP 2018][merlin] — the incremental API, recovery annotations, and "live parsing"
- [J.-H. Jourdan, F. Pottier & X. Leroy, "Validating LR(1) Parsers," ESOP 2012][validating-pdf] and the [Gagallium blog on the verified back-end][validating-blog]
- [J.-H. Jourdan & F. Pottier, "A Simple, Possibly Correct LR Parser for C11," TOPLAS 39(4), 2017][c11-doi] ([abstract][c11-abstract])
- [CompCert verified C compiler][compcert] — production user of the verified parser
- [Real World OCaml — "Parsing with OCamllex and Menhir"][rwo] — the practical Menhir-vs-`ocamlyacc` case
- Related deep-dives: [bottom-up / LR theory][bottom-up] · [Bison & yacc][bison] · [tree-sitter][treesitter] · [ANTLR][antlr] · [general parsing / GLR][general] · [the comparison capstone][comparison]

<!-- References -->

[manual]: https://gallium.inria.fr/~fpottier/menhir/manual.html
[home]: https://gallium.inria.fr/~fpottier/menhir/
[repo]: https://gitlab.inria.fr/fpottier/menhir
[mirror]: https://github.com/savonet/mehnir
[stdlib]: https://gitlab.inria.fr/fpottier/menhir/-/blob/master/src/standard.mly
[manpage]: https://www.mankier.com/1/menhir
[ocamllex]: https://ocaml.org/manual/lexyacc.html
[rwo]: https://dev.realworldocaml.org/parsing-with-ocamllex-and-menhir.html
[merlin]: https://arxiv.org/abs/1807.06702
[ocamllsp]: https://github.com/ocaml/ocaml-lsp
[reason]: https://reasonml.github.io/
[lexifi]: https://github.com/LexiFi/menhir
[validating-pdf]: http://gallium.inria.fr/~fpottier/publis/jourdan-leroy-pottier-validating-parsers.pdf
[validating-blog]: http://gallium.inria.fr/blog/verifying-a-parser-for-a-c-compiler/
[c11-doi]: https://dl.acm.org/doi/10.1145/3064848
[c11-abstract]: https://jhjourdan.mketjh.fr/publications_abstracts.html
[compcert]: https://compcert.org/
[bottom-up]: ./theory/bottom-up.md
[bison]: ./bison-yacc.md
[treesitter]: ./tree-sitter.md
[antlr]: ./antlr.md
[general]: ./theory/general-parsing.md
[comparison]: ./comparison.md
