# pest (Rust)

An ergonomic [PEG][peg-packrat] parser generator for Rust: you write the grammar in a separate `.pest` file in PEG notation, attach it to a type with a `#[derive(Parser)]` macro, and at compile time pest generates a parser whose `parse` method returns `Pairs` — a flat, lazily-navigable stream of matched rules that you map onto your own AST.

| Field                     | Value                                                                                                                           |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| Language                  | Rust (MSRV 1.83 for the `pest` crate)                                                                                           |
| License                   | MIT OR Apache-2.0 (dual)                                                                                                        |
| Repository                | [`pest-parser/pest`][repo]                                                                                                      |
| Documentation             | [docs.rs/pest][docs] · [the pest book][book] · [pest.rs][site]                                                                  |
| Key authors               | Dragoș Tiselice (creator) and the pest contributors (with guidance from Prof. Marius Minea)                                     |
| Category                  | PEG parser generator (external DSL + derive macro)                                                                              |
| Algorithm / grammar class | Recursive-descent **PEG**: ordered choice, greedy possessive repetition, syntactic predicates — **non-memoizing** (not packrat) |
| Lexing model              | **Scannerless** — a single `.pest` grammar describes lexical and hierarchical syntax together; no separate token stream         |
| Output                    | `Pairs` / `Pair` — a flat-but-navigable token-pair stream over the source (a CST view), **not** a typed AST; you build the AST  |
| Latest release            | `pest`/`pest_derive` `2.8.x` (the `2.x` API is stable; `pest_derive 2.8.0` released 2025-03-25)                                 |

> [!NOTE]
> This deep-dive surveys the upstream `pest-parser/pest` workspace — the runtime crate `pest`, the `pest_derive` proc-macro, and the supporting `pest_meta` / `pest_generator` / `pest_vm` crates. Third-party companions in the ecosystem (`pest-ast`, `pest_consume`, `pest-test`, `pest_debugger`) are referenced where relevant but live in separate repositories.

---

## Overview

### What it solves

Hand-writing a recursive-descent parser in Rust is tedious and error-prone; using a [parser-combinator library][rust-nom] interleaves the grammar with Rust control flow, so the grammar exists only implicitly, scattered across combinator calls. pest takes the opposite stance: **the grammar is a first-class artifact**, written once in a dedicated PEG notation in its own `.pest` file, and the parser is _generated_ from it. From the crate root documentation ([`pest/src/lib.rs`][lib], echoed on [docs.rs][docs]):

> _"pest is a general purpose parser written in Rust with a focus on accessibility, correctness, and performance. It uses parsing expression grammars (or PEG) as input, which are similar in spirit to regular expressions, but which offer the enhanced expressivity needed to parse complex languages."_

The headline ergonomic decision is keeping grammar and code apart. The project [README][repo] states it directly:

> _"Grammars are saved in separate `.pest` files which are never mixed with procedural code. This results in an always up-to-date formalization of a language that is easy to read and maintain."_

A pest grammar is a [PEG][peg-packrat]: an ordered, recognition-based formalism that is **unambiguous by construction** and **[scannerless][concepts]** (lexical and hierarchical rules share one notation). The pest book summarizes the formalism's character — _"PEGs are eager, non-backtracking, ordered, and unambiguous"_ — and the book's PEG chapter spells out the consequence of ordered choice ([`grammars/peg.html`][peg-page]):

> _"The choice operator, written as a vertical line `|`, is ordered. The PEG expression `first | second` means 'try `first`; but if it fails, try `second` instead'."_

For the formal underpinnings — prioritized choice `/`, syntactic predicates `&`/`!`, the unambiguity result, and the packrat memoization that pest deliberately omits — see the [PEG & packrat theory entry][peg-packrat].

### Design philosophy

Three convictions, visible across the source tree and the book, shape the whole API:

1. **The grammar is the source of truth, separate from code.** The `.pest` file is parsed and validated at compile time by `pest_meta`, and `pest_derive` emits Rust from it. A grammar error is a _compile_ error, with a span into the `.pest` file — the grammar can never silently drift out of sync with the parser.

2. **Accessibility over raw speed.** pest optimizes for a grammar that a newcomer can read and a maintainer can trust. The README's stated focus is _"accessibility, correctness, and performance"_ — in that order. The cost (a non-memoizing PEG engine that can backtrack super-linearly on pathological grammars) is accepted in exchange for a small, predictable, code-free grammar artifact. See [Performance](#performance).

3. **A flat token stream, not a typed tree.** pest does not try to generate a typed AST for you. `Parser::parse` yields `Pairs` — an iterator over matched rules, each `Pair` exposing `as_rule`, `as_str`, `as_span`, and `into_inner`. Mapping that flat stream onto your own domain types is your job (libraries like `pest-ast` and `pest_consume` automate it). This keeps the generated code tiny and the runtime model uniform across every grammar.

Within [this survey][index], pest is the canonical **ergonomic external-DSL PEG generator** for Rust. Contrast it with the in-language [PEG-flavoured parser combinators][rust-nom] ([`chumsky`][rust-chumsky] too), with the incremental GLR engine [tree-sitter][tree-sitter], and with the [LL/ALL(\*)][antlr] and [LALR][bison-yacc] generators. The deepest single contrast is _packrat vs. not_: pest shares PEG _semantics_ with packrat parsers but **omits the memoization** that gives packrat its linear-time guarantee (see [Algorithm & grammar class](#algorithm--grammar-class)). The cross-cutting view is in the [comparison][comparison].

---

## How it works

### Core abstractions and types

The runtime surface is small. Almost everything a consumer touches lives in `pest`'s public API ([docs.rs][docs]); the grammar-to-Rust machinery is in `pest_derive`/`pest_generator`/`pest_meta`.

| Concept               | Type / item                                             | Role                                                                                                 |
| --------------------- | ------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| Generated parser      | `#[derive(Parser)]` on a unit struct                    | The derive (from `pest_derive`) reads `#[grammar = "…"]` and implements `Parser` at compile time     |
| Rule tag              | `Rule` enum (generated)                                 | One variant per named rule in the `.pest` file; the parse entry point names a `Rule`                 |
| Parser trait          | `pest::Parser`                                          | `fn parse(rule: R, input: &str) -> Result<Pairs<R>, Error<R>>`                                       |
| Match-pair stream     | `pest::iterators::Pairs<R>`                             | Lazy iterator over top-level matched rules; the result of a successful parse                         |
| One matched rule      | `pest::iterators::Pair<R>`                              | A spanned, named match; `as_rule`, `as_str`, `as_span`, `into_inner`                                 |
| Underlying tokens     | `pest::Token<R>` (`Start`/`End`)                        | A `Pair` is exactly a matching `Start`/`End` token couple; `Pairs::tokens()` exposes the flat stream |
| Position in input     | `pest::Position` / `pest::Span`                         | Byte offset + `line_col()`; a `Span` is a start/end `Position` pair over the source                  |
| Parser state (manual) | `pest::ParserState<R>`                                  | The state threaded through a parse: `position`, token `queue`, lookahead, the grammar `stack`        |
| Error                 | `pest::error::Error<R>`                                 | A positioned, formatted parse/grammar error (see [Error handling](#error-handling--recovery))        |
| Precedence engine     | `pest::pratt_parser::PrattParser<R>`                    | Pratt / precedence-climbing over a flat `Pairs` stream of operators and primaries                    |
| Grammar AST + checks  | `pest_meta` (`parser`, `validator`, `optimizer`, `ast`) | Parses, validates, and optimizes the `.pest` meta-grammar itself; shared by derive and VM            |
| Grammar interpreter   | `pest_vm::Vm`                                           | Runs a parsed grammar **without** code generation — the engine behind the online editor              |

### The `.pest` grammar and the derive

A pest parser is two artifacts: a grammar file and a tagged struct. The canonical example from the [README][repo] parses a space-separated identifier list. The grammar (`ident.pest`):

```ebnf
alpha = { 'a'..'z' | 'A'..'Z' }
digit = { '0'..'9' }

ident = { !digit ~ (alpha | digit)+ }

ident_list = _{ ident ~ (" " ~ ident)* }
```

Several PEG features are already visible: character ranges (`'a'..'z'`), [ordered choice][peg-packrat] (`|`), sequence (`~`, "followed by"), greedy repetition (`+`, `*`), the negative predicate (`!digit`, "not followed by a digit"), and a **silent** rule (`ident_list = _{ … }`, whose underscore-prefix means it produces no `Pair` of its own). The grammar is attached to a type by a derive macro:

```rust
use pest_derive::Parser;
use pest::Parser;

#[derive(Parser)]
#[grammar = "ident.pest"] // relative to the crate's `src/` directory
struct IdentParser;
```

`#[derive(Parser)]` expands at compile time into (a) a `Rule` enum with a variant per named rule and (b) a `Parser` impl whose `parse` drives the generated recursive-descent matcher. An inline form, `#[grammar_inline = "…"]`, embeds the grammar in the attribute instead of a file. Because `pest_meta` validates the grammar during expansion, an undefined rule reference or a malformed PEG operator is a Rust compile error pointing into the `.pest` source.

### The runtime API: `Pairs`, `Pair`, and the token stream

`Parser::parse` returns `Result<Pairs, Error>`. On success you iterate `Pairs`, and for each `Pair` you ask which rule matched, what text it spanned, and what it contains. From the README's runtime example:

```rust
// The generated IdentParser::parse returns Pairs (or an Error).
let pairs = IdentParser::parse(Rule::ident_list, "a1 b2")
    .unwrap_or_else(|e| panic!("{}", e));

for pair in pairs {
    // A pair is a combination of the rule that matched and a span of input.
    println!("Rule:    {:?}", pair.as_rule());
    println!("Span:    {:?}", pair.as_span());
    println!("Text:    {}", pair.as_str());

    // A pair can be converted to an iterator of the tokens it contains.
    for inner_pair in pair.into_inner() {
        match inner_pair.as_rule() {
            Rule::alpha => println!("Letter:  {}", inner_pair.as_str()),
            Rule::digit => println!("Digit:   {}", inner_pair.as_str()),
            _ => unreachable!(),
        };
    }
}
```

The data model is deliberately flat. The pest book ([`parser_api.html`][parser-api]) defines a `Pair` in terms of the underlying token stream:

> _"When a rule matches, two tokens are produced: one at the start of the text that the rule matched, and one at the end."_

A `Pair`, then, _"represents a matching pair of tokens, or, equivalently, the spanned text that a named rule successfully matched."_ Its three uses map exactly to its three accessors:

| Accessor       | Returns | Use                                                                       |
| -------------- | ------- | ------------------------------------------------------------------------- |
| `as_rule()`    | `Rule`  | Which named rule produced this match (dispatch on it with `match`)        |
| `as_str()`     | `&str`  | The exact source slice the rule matched (zero-copy borrow of the input)   |
| `as_span()`    | `Span`  | The start/end `Position`s; `Span::start_pos().line_col()` for diagnostics |
| `into_inner()` | `Pairs` | The sub-`Pair`s for the named rules nested inside this one                |

This is a _flat-but-navigable_ CST view, not a typed AST. `Pairs` is a forward iterator; `into_inner()` descends one level. There is no `pest`-provided typed tree — you walk the `Pairs` and construct your own types. Because `as_str()` borrows directly from the input `&str`, leaf extraction is **zero-copy**: a parsed identifier is a `&str` into the original buffer, not a fresh allocation.

### Implicit whitespace and comments

In a [scannerless][concepts] PEG there is no lexer to discard whitespace, so pest provides two special rule names that, _if defined_, are woven into the grammar automatically. From the book's syntax chapter ([`grammars/syntax.html`][syntax]):

> _"If either (or both) [`WHITESPACE` and `COMMENT`] are defined, they will be implicitly inserted at every sequence and between every repetition (except in atomic rules)."_

So `~` and `*`/`+` silently allow interspersed whitespace/comments once you supply the rules — typically one character or one comment at a time, since they run repeatedly:

```ebnf
WHITESPACE = _{ " " | "\t" | NEWLINE }
COMMENT    = _{ "/*" ~ (!"*/" ~ ANY)* ~ "*/" }
```

Crucially, _"implicit whitespace is not inserted at the beginning or end of rules"_ — only between sequence elements and between repetitions. This is the single feature that makes pest grammars read like a clean BNF rather than being littered with explicit "optional spaces" between every token.

### Atomic, silent, and non-atomic rules

A scannerless grammar needs a way to say "here, _do not_ skip whitespace, and treat this as one indivisible token." pest expresses rule _flavor_ with a sigil before the rule's `{`:

| Flavor          | Sigil  | Behaviour                                                                                                          |
| --------------- | ------ | ------------------------------------------------------------------------------------------------------------------ |
| Normal          | _none_ | Produces a `Pair`; implicit whitespace applies between sequence/repetition elements                                |
| Silent          | `_`    | _"do not produce pairs or tokens"_ — runs identically but leaves no trace in the output (e.g. `WHITESPACE`)        |
| Atomic          | `@`    | No implicit whitespace inside; **interior rules are silenced** — the whole match is one opaque token               |
| Compound atomic | `$`    | No implicit whitespace inside, but **inner rules still produce tokens** (you keep the structure, lose the spacing) |
| Non-atomic      | `!`    | Forces normal (whitespace-skipping) behaviour even when called from inside an atomic rule                          |

The book states the atomic contract precisely ([`grammars/syntax.html`][syntax]):

> _"Inside an atomic rule, the tilde `~` means 'immediately followed by'."_ — and — _"In an Atomic rule, interior matching rules are silent."_

Silent rules differ from atomic ones in an important way the book flags: _"Unlike atomic rules, silent rules are not cascading. A rule inside a silent rule will not be silent unless it's explicitly stated."_ Atomicity cascades down into called rules; silence does not.

### The stack: matching the same text, not the same pattern

pest carries a runtime **stack of matched strings** that the grammar manipulates with keywords, enabling context-sensitive constructs a pure PEG cannot express (matched delimiters, here-documents, indentation). The book's framing ([`grammars/syntax.html`][syntax]):

> _"Using the stack allows the exact same text to be matched multiple times, rather than the same pattern."_

| Keyword             | Effect                                                                               |
| ------------------- | ------------------------------------------------------------------------------------ |
| `PUSH(e)`           | Match `e`, and on success push the matched **text** onto the stack                   |
| `PUSH_LITERAL("…")` | _"never consumes any input, always matches, and pushes its argument to the stack"_   |
| `PEEK`              | Match the string currently on top of the stack (without removing it)                 |
| `POP`               | Match the top string and, on success, remove it from the stack                       |
| `PEEK_ALL`          | Match the concatenation of the whole stack (used for indentation-sensitive grammars) |
| `DROP`              | _"Remove the top string in the stack without matching against input."_               |

The classic use is a Rust-style raw-string delimiter, where the number of `#`s must match on both ends:

```ebnf
raw_string = {
    "r" ~ PUSH("#"*) ~ "\"" // push the opening run of '#'
    ~ (!("\"" ~ PEEK) ~ ANY)*
    ~ "\"" ~ POP             // require the same run of '#' to close
}
```

For **indentation-sensitive** grammars (Python-like), `PUSH` the leading whitespace of a block and use `PEEK_ALL` to require subsequent lines to begin with the same accumulated indentation — the stack is pest's answer to the off-side rule, which plain PEGs cannot capture.

### Precedence with `PrattParser`

A PEG expresses operator precedence by stratifying the grammar into a tower of rules (term, factor, …), which is verbose and bakes associativity into the grammar shape. pest instead lets you write a _flat_ expression rule and resolve precedence at the API level with `pratt_parser::PrattParser` ([docs.rs][pratt]) — the [Pratt / precedence-climbing][pratt-precedence] technique. The docs describe it as a:

> _"Struct containing operators and precedences, which can perform Pratt parsing on primary, prefix, postfix and infix expressions over Pairs."_

You declare operators in increasing precedence order, then fold the flat `Pairs` stream with per-shape closures:

```rust
let pratt = PrattParser::new()
    .op(Op::infix(Rule::add, Assoc::Left) | Op::infix(Rule::sub, Assoc::Left))
    .op(Op::infix(Rule::mul, Assoc::Left) | Op::infix(Rule::div, Assoc::Left))
    .op(Op::infix(Rule::pow, Assoc::Right))
    .op(Op::prefix(Rule::neg))
    .op(Op::postfix(Rule::fac));

let result = pratt
    .map_primary(|primary| /* leaf → AST node */)
    .map_prefix(|op, rhs| /* unary prefix */)
    .map_postfix(|lhs, op| /* unary postfix */)
    .map_infix(|lhs, op, rhs| /* binary */)
    .parse(pairs);
```

_"The order of precedence corresponds to the order in which `op` is called,"_ and operators of equal precedence are combined with `|`. `PrattParser` superseded the older `prec_climber`, which the crate docs now mark as deprecated and _"may be removed in a future major release."_

### Built-in rules

pest predefines a library of rules so common lexical classes need no hand-rolling: structural anchors `SOI` / `EOI` (start/end of input), `ANY` (any single Unicode character), `NEWLINE`, the `ASCII_*` family (`ASCII_DIGIT`, `ASCII_ALPHANUMERIC`, `ASCII_HEX_DIGIT`, …), and a large set of **Unicode property** rules (`LETTER`, `UPPERCASE_LETTER`, `NUMBER`, `XID_START`, `XID_CONTINUE`, `WHITE_SPACE`, script blocks like `LATIN`/`CYRILLIC`/`HAN`, …). These let a grammar say `ident = @{ XID_START ~ XID_CONTINUE* }` and get correct Unicode identifier matching for free.

### The meta-grammar, validator, and VM

pest is bootstrapped: pest's own `.pest` notation is itself parsed by `pest_meta`, which exposes a `parser` (grammar → AST), a `validator` (catches undefined rules, left recursion, repetition-of-nullable, and similar grammar bugs), and an `optimizer` (rewrites the grammar AST — e.g. factoring, skipping). `pest_generator` turns that AST into Rust; `pest_derive` is the thin proc-macro wrapper that the user actually invokes. The same AST feeds `pest_vm::Vm`, a tree-walking **interpreter** for grammars that runs a `.pest` file _without_ code generation — this is the engine behind the [online editor][editor] ("fiddle") on pest.rs, which lets you edit a grammar and see the parse tree update live in the browser without a Rust toolchain. The shared meta-grammar means the derive macro and the live editor accept exactly the same notation.

---

## Algorithm & grammar class

pest implements a **[PEG][peg-packrat]** by straightforward **recursive descent with backtracking**, and — the defining performance fact — **it does not memoize**, so it is _not_ a packrat parser.

- **Grammar class.** A pest grammar is a parsing expression grammar: ordered choice (`|`), sequence (`~`), greedy/possessive repetition (`*`, `+`, `?`), and the syntactic predicates `&` (positive lookahead) and `!` (negative lookahead). The book describes repetition as eager and committed: an expression _"runs that expression as many times as it can (matching 'eagerly', or 'greedily')"_, and once a choice or repetition commits, _"once `first` parses successfully, it has consumed some characters that will never come back"_ ([`grammars/peg.html`][peg-page]). This is the standard PEG semantics catalogued in the [theory entry][peg-packrat].

- **Ambiguity handling.** None is needed: PEGs are **unambiguous by construction**. Ordered choice resolves every alternative deterministically (first match wins), and possessive repetition removes the "give back characters" backtracking that makes CFGs ambiguous. There are no shift/reduce conflicts, no GLR forks, no disambiguation rules to write — a property pest shares with the whole [PEG family][peg-packrat] and not with the [LR][bottom-up] / [GLR][general-parsing] generators.

- **Backtracking, implemented by position save/restore.** The engine threads a `ParserState` carrying the current `position` and a token `queue`. A sequence saves the position and token index before its first element and, on any sub-failure, _restores the initial position and truncates the token queue_; a lookahead block saves and unconditionally restores the position; choice tries each alternative from the saved position. There is **no cache** keyed on `(rule, position)`: the `ParserState` ([`pest/src/parser_state.rs`][state]) holds `position`, `queue`, `lookahead`, the grammar `stack`, and `pos_attempts`/`neg_attempts` — and the attempt vectors exist purely for _error reporting_ (which rules failed where), not to avoid re-parsing. This is the structural difference from a packrat parser, whose memo table makes each `(rule, position)` cost amortized O(1).

> [!IMPORTANT]
> **pest is a non-memoizing PEG engine.** Packrat parsing (Ford 2002) guarantees linear time by caching every `(rule, position)` result; see [the PEG & packrat theory entry][peg-packrat]. pest omits that table. For the overwhelming majority of grammars this is fine — real input rarely triggers the pathological re-parsing — but a grammar with heavy shared backtracking across alternatives can degrade toward super-linear time, with no memo table to rescue it. The trade is less memory and simpler generated code in exchange for the linear-time _worst-case_ guarantee.

- **Left recursion is rejected.** Like a textbook recursive-descent PEG, pest cannot handle left recursion; `pest_meta`'s validator detects it at compile time and reports it as a grammar error rather than looping forever. Left-recursive operator grammars are expressed either by stratifying the grammar or, more idiomatically, by a flat rule fed to [`PrattParser`](#precedence-with-prattparser).

## Interface & composition model

pest's interface is an **external DSL plus a derive macro** — the opposite end of the spectrum from in-language [parser combinators][rust-nom].

- **Grammar expression.** The grammar is data in a `.pest` file, not Rust code. This is its central ergonomic claim: _"Grammars are saved in separate `.pest` files which are never mixed with procedural code"_ ([README][repo]). The grammar is therefore readable as a standalone language specification, diffable, and reusable across the `pest_vm` interpreter and the derive macro unchanged.

- **Host-language integration.** `#[derive(Parser)]` is a procedural macro: at compile time `pest_derive` reads the `#[grammar = "…"]` path, has `pest_meta` parse/validate/optimize it, and `pest_generator` emits a `Rule` enum and a `Parser` impl into your crate. Grammar errors surface as Rust compile errors. There is no build script and no separate codegen step — the macro _is_ the generator.

- **Composition.** pest grammars compose _within_ a file (rules reference rules) but pest has **no first-class grammar-import / inheritance** mechanism comparable to ANTLR's `import` or a combinator library's value-level composition: you cannot `use` another crate's `.pest` rules directly. Composition of _parsers_ happens at the value level, after parsing — you combine the `Pairs` streams of independently-parsed fragments in Rust. This is a real limitation relative to combinator libraries, where a parser is an ordinary value you can pass around and combine; in pest the grammar is a closed compile-time artifact.

- **Building the AST / CST.** pest hands you a **CST-shaped `Pairs` stream and stops there.** There is no typed tree; you write a function that walks `Pairs`, matches on `as_rule()`, reads `as_str()` / `into_inner()`, and constructs your own enums/structs. The ecosystem fills the gap: `pest-ast` derives an AST from `#[pest_ast(…)]` attributes, and `pest_consume` offers a structured, less-`unwrap`-heavy traversal. Compared with [tree-sitter][tree-sitter] (which owns a lossless CST you query) or a combinator library (where the parser _returns_ your AST directly), pest sits in between: a flat CST you must lower yourself.

## Performance

pest's performance posture follows from its design choices: **scannerless, zero-copy leaves, non-memoizing recursive descent.**

- **Time complexity.** A pest parse is recursive descent with backtracking. Without memoization the **worst case is super-linear** (exponential for adversarial grammars with deeply shared, repeatedly-retried alternatives), in contrast to a packrat parser's guaranteed **O(n)** (see [PEG & packrat][peg-packrat]). In practice most hand-written grammars parse in roughly linear time on real input, because the backtracking that would blow up rarely fires; the guarantee, however, is _not_ there. pest's own `pest_meta::optimizer` mitigates some of this by rewriting the grammar AST (the changelog records an optimizer fix for _"exponential … compile times in bigger grammars"_), but that is compile-time grammar optimization, not run-time memoization.

- **Space.** Because there is no memo table, steady-state space is the input plus the token `queue` plus the (usually shallow) recursion/stack — far less than a packrat parser, whose memo table is _"a possibly substantial constant multiple of the input size"_ ([Ford 2002][peg-packrat]). This is the deliberate other side of the no-memoization trade.

- **Zero-copy.** Leaf extraction is zero-copy: `Pair::as_str()` returns a `&str` borrowing the original input buffer; `Span`/`Position` are byte offsets into it. No string is copied to represent a matched token.

- **Streaming / SIMD / data-parallelism.** pest does **not** stream (it parses a complete `&str` in memory) and uses **no SIMD or data-parallelism** — both inapplicable to a sequential recursive-descent PEG. This is a sharp contrast with the SIMD, branch-free design of [simdjson][simdjson]; pest trades that raw throughput for grammar generality and ergonomics.

- **Published benchmarks — read with care.** pest historically advertised JSON-parsing benchmarks suggesting it was competitive with or faster than [`nom`][rust-nom]. nom's author Geoffroy Couprie rebutted this in _"No, pest is not faster than nom"_ ([unhandledexpression.com][nom-bench]): the comparison was not like-for-like — the fast pest figure was **validating the input and producing a flat token list**, while the nom and "pest custom AST" figures were **building typed Rust values**, so the cheap pest path was doing strictly less work. The honest reading is that pest is a fast, ergonomic generator whose raw throughput on AST construction is **below** hand-tuned combinator/SIMD parsers — which is exactly the accessibility-over-speed trade the project states up front.

## Error handling & recovery

pest's error story is one of its strongest selling points — but it is **error _reporting_, not error _recovery_.**

- **Good messages out of the box.** A failed `Parser::parse` returns a `pest::error::Error<Rule>` that, when `Display`ed, renders a caret-annotated message pointing at the exact line/column with the set of rules pest expected there. This falls out of the `pos_attempts`/`neg_attempts` bookkeeping in `ParserState`: pest records, for the furthest position it reached, which rules it was trying, and turns that into _"expected one of …"_. Because the grammar is named, the message is phrased in the grammar's own rule names, and `Position::line_col()` gives precise coordinates — all without the author writing any diagnostic code.

- **No automatic recovery.** Standard pest is a _recognizer that stops at the first failure_; it does not insert/delete tokens to resynchronize and continue, and it does not produce a partial tree with error nodes the way [tree-sitter][tree-sitter] does. To collect multiple errors or keep parsing past a mistake you must engineer it into the grammar (e.g. an explicit `error`-catching rule that consumes to a recovery point). Newer work adds a labelled-error / recovery facility, but the core model is fail-fast. This is the chief gap versus IDE-grade engines.

- **Incremental reparsing / IDE-readiness.** pest does **not** reparse incrementally — every `parse` call processes the whole input from scratch, and there is no edit-aware reuse of prior work. It is therefore **not IDE-grade** in the [tree-sitter][tree-sitter] sense (parse-on-every-keystroke, lossless editable tree). Where this dimension barely applies, that absence is the finding: pest is built for the batch contract (parse a file/string once, get a tree or an error), not the editor contract. Its tooling answer is the `pest_debugger` crate and the live online editor, which help author and debug grammars rather than serve a running IDE.

## Ecosystem & maturity

pest is a **mature, widely-adopted, stable** member of the Rust parsing ecosystem.

- **Adoption.** `pest` and `pest_derive` are among the most-downloaded parsing crates on crates.io (millions of downloads), used across compilers, config/DSL parsers, query languages, and teaching material. It is frequently the first parser-generator a Rust newcomer reaches for, precisely because of the separate-grammar-file ergonomics and the [book][book].

- **Stability.** The `2.x` line has held a stable API for years; the latest `pest`/`pest_derive` are in the `2.8.x` series (with `pest_derive 2.8.0` released 2025-03-25). The MSRV for the `pest` crate is Rust 1.83. The grammar notation has been stable enough that the `pest.rs` editor, the derive macro, and `pest_vm` all share one meta-grammar.

- **Tooling.** First-party: the [book][book], the [online editor][editor] (powered by `pest_vm`), and `pest_debugger`. Third-party (the `awesome-pest` list): `pest-ast` (grammar → typed AST via derive), `pest_consume` (ergonomic structured traversal), `pest-test` (snapshot grammar tests), and `pest_ascii_tree` (render a `Pairs` tree as ASCII).

- **Ports / lineage.** pest is the Rust standard-bearer for the **external-DSL PEG generator** pattern; its conceptual relatives across ecosystems include [LPeg][lpeg] (Lua), [PEG.js][pegjs]/Peggy (JavaScript), `Rats!` (Java), and the `peg` crate (Rust, an in-language `macro_rules!` PEG). Within the [PEG family][peg-packrat] pest is distinguished by the _separate `.pest` file + derive_ ergonomics; within Rust it is the external-DSL counterpart to the in-language combinator crates [`nom`][rust-nom] and [`chumsky`][rust-chumsky].

## Strengths

- **Grammar as a clean, separate artifact.** The `.pest` file reads as a language specification, is never tangled with Rust control flow, and is validated at compile time — _"an always up-to-date formalization of a language."_
- **Excellent ergonomics and on-ramp.** A polished [book][book], a live [online editor][editor], built-in Unicode/ASCII rule libraries, and great default error messages make the time-to-first-parser very short.
- **Scannerless, no lexer to write.** One grammar covers lexical and hierarchical syntax; `WHITESPACE`/`COMMENT` handle interstitial noise automatically.
- **Unambiguous by construction.** PEG ordered choice means no conflict diagnostics, no precedence-declaration files, no ambiguity to resolve.
- **Context-sensitive escapes built in.** The `PUSH`/`POP`/`PEEK`/`PEEK_ALL` stack handles matched delimiters and indentation — constructs pure CFGs and pure PEGs cannot.
- **Zero-copy leaves.** `as_str()` borrows the input; `Span`/`Position` are byte offsets — no per-token allocation.
- **First-class precedence.** `PrattParser` keeps expression grammars flat and resolves precedence/associativity at the API level.

## Weaknesses

- **Non-memoizing: no linear-time guarantee.** Unlike a [packrat][peg-packrat] parser, pest can backtrack super-linearly on adversarial grammars; you must structure the grammar to avoid pathological re-parsing.
- **You build the AST yourself.** `Pairs` is a flat CST stream; lowering it to typed values is manual (or relies on `pest-ast`/`pest_consume`), with `unwrap`-heavy traversal and rule-mismatch panics if the grammar and walker drift apart.
- **No error recovery, no incrementality.** Fail-fast at the first error; no partial trees, no error nodes, no edit-aware reparse — not IDE-grade like [tree-sitter][tree-sitter].
- **No left recursion.** Rejected at compile time; left-recursive grammars must be rewritten or pushed into `PrattParser`.
- **No grammar composition across files/crates.** A `.pest` grammar is a closed compile-time unit; you cannot import another crate's rules the way ANTLR or combinator parsers compose.
- **Raw throughput trails hand-tuned parsers.** Slower than [`nom`][rust-nom] for AST construction and far below [simdjson][simdjson]; accessibility is prioritized over peak speed.
- **Ordered choice is a footgun.** As with all PEGs, a poorly-ordered alternative or an unintended commit can silently match the wrong thing — the grammar author must reason about priority, not just structure.

## Key design decisions and trade-offs

| Decision                                                   | Rationale                                                                                 | Trade-off                                                                                           |
| ---------------------------------------------------------- | ----------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| Grammar in a separate `.pest` file, attached by derive     | Keeps the grammar a clean, diffable spec; validated at compile time; reusable by the VM   | Grammar is a closed compile-time artifact — no value-level parser composition or cross-crate import |
| PEG formalism (ordered choice, possessive repetition)      | Unambiguous by construction; scannerless; no conflict/precedence declarations to maintain | Ordered choice is order-sensitive (footgun); cannot express genuine ambiguity or left recursion     |
| **Non-memoizing** recursive descent (not packrat)          | Less memory, simpler generated code, fast on real grammars                                | Loses packrat's linear-time worst-case guarantee; adversarial grammars can backtrack super-linearly |
| Flat `Pairs`/`Pair` stream instead of a typed AST          | Uniform runtime model; tiny generated code; zero-copy `as_str()`                          | Caller must hand-write the CST→AST lowering (or pull in `pest-ast`/`pest_consume`)                  |
| Scannerless with special `WHITESPACE`/`COMMENT` rules      | One grammar for lexing + parsing; whitespace handling is declarative, not hand-coded      | No separate token stream to reuse; atomic-rule rules needed to opt _out_ of whitespace skipping     |
| Runtime stack (`PUSH`/`POP`/`PEEK`)                        | Adds context-sensitivity (matched delimiters, indentation) a pure PEG cannot express      | The grammar becomes stateful and harder to reason about as a pure formal description                |
| `PrattParser` for precedence (over grammar stratification) | Flat expression rules; precedence/associativity declared in Rust, easy to change          | Precedence logic lives outside the `.pest` file, splitting the grammar's "truth" across two places  |
| Error _reporting_ but not _recovery_                       | Precise, rule-named, positioned messages for free from the attempt bookkeeping            | No multi-error collection, no partial trees, no incremental reparse — not IDE-grade                 |

---

## Sources

- [`pest-parser/pest` — GitHub repository (README, workspace)][repo]
- [the pest book — `pest.rs/book`][book] (syntax, parser API, PEG, built-ins, precedence chapters)
- [`pest/src/lib.rs` — crate root docs (PEG description, `Parser` trait, `pest_derive`)][lib]
- [`pest/src/parser_state.rs` — `ParserState`: position/queue/stack, attempt tracking, no memo table][state]
- [docs.rs/pest — `Parser`, `Pairs`/`Pair`, `Token`, `Span`/`Position`, `error`][docs]
- [`pest::pratt_parser::PrattParser` — precedence climbing over `Pairs`][pratt]
- [the pest grammar syntax reference (atomic/silent rules, implicit whitespace, the stack)][syntax]
- [the pest parser API chapter (`Pair`/`Pairs`, tokens, spans)][parser-api]
- [the pest PEG chapter (eager/ordered/non-backtracking semantics)][peg-page]
- [`pest_meta` — meta-grammar parser, validator, optimizer (crates.io)][meta]
- [`pest_vm` — grammar virtual machine behind the online editor (lib.rs)][vm]
- [the pest online editor / fiddle][editor]
- [Geoffroy Couprie, "No, pest is not faster than nom" (benchmark critique)][nom-bench]
- Related: [PEG & packrat theory][peg-packrat] · [Pratt precedence][pratt-precedence] · [nom][rust-nom] · [chumsky][rust-chumsky] · [tree-sitter][tree-sitter] · [ANTLR][antlr] · [comparison][comparison]

<!-- References -->

[repo]: https://github.com/pest-parser/pest
[book]: https://pest.rs/book/
[site]: https://pest.rs/
[docs]: https://docs.rs/pest/latest/pest/
[lib]: https://github.com/pest-parser/pest/blob/master/pest/src/lib.rs
[state]: https://github.com/pest-parser/pest/blob/master/pest/src/parser_state.rs
[syntax]: https://pest.rs/book/grammars/syntax.html
[parser-api]: https://pest.rs/book/parser_api.html
[peg-page]: https://pest.rs/book/grammars/peg.html
[pratt]: https://docs.rs/pest/latest/pest/pratt_parser/struct.PrattParser.html
[meta]: https://crates.io/crates/pest_meta
[vm]: https://lib.rs/crates/pest_vm
[editor]: https://pest.rs/#editor
[nom-bench]: https://web.archive.org/web/20260413080622/http://unhandledexpression.com/general/2018/10/04/no-pest-is-not-faster-than-nom.html
[lpeg]: https://www.inf.puc-rio.br/~roberto/lpeg/
[pegjs]: https://pegjs.org/
[index]: ./index.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[peg-packrat]: ./theory/peg-packrat.md
[pratt-precedence]: ./theory/pratt-precedence.md
[bottom-up]: ./theory/bottom-up.md
[general-parsing]: ./theory/general-parsing.md
[tree-sitter]: ./tree-sitter.md
[antlr]: ./antlr.md
[bison-yacc]: ./bison-yacc.md
[rust-nom]: ./rust-nom.md
[rust-chumsky]: ./rust-chumsky.md
[simdjson]: ./simdjson.md
