# ANTLR (Java / multi-target)

The dominant LL-based parser generator: from one `.g4` grammar it generates a top-down parser whose run-time **ALL(\*)** (Adaptive LL-star) prediction launches pseudo-parallel subparsers and caches a lookahead DFA, "[combining] the simplicity, efficiency, and predictability of conventional top-down LL(k) parsers with the power of a GLR-like mechanism to make parsing decisions."

| Field                     | Value                                                                                                                      |
| ------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| Language                  | Tool in Java; runtimes in Java, C#, Python3, JavaScript, TypeScript, Go, C++, Swift, PHP, Dart                             |
| License                   | BSD-3-Clause                                                                                                               |
| Repository                | [`antlr/antlr4`][repo] (tool in [`tool/`][tool-dir], runtimes in [`runtime/`][runtime-dir])                                |
| Documentation             | [antlr.org][site] · [`doc/index.md`][doc-index] · _The Definitive ANTLR 4 Reference_ (Parr, 2013)                          |
| Key authors               | Terence Parr (project lead since 1989), Sam Harwell, Kathleen Fisher, Eric Vergnaud, and contributors                      |
| Category                  | Parser generator (external DSL → generated recursive-descent + ATN simulator), LL-based                                    |
| Algorithm / grammar class | **ALL(\*)** — Adaptive LL(\*); accepts any non-left-recursive CFG, with direct left-recursion handled by grammar rewriting |
| Lexing model              | **Separate lexer** (its own ALL(\*) recognizer); also supports combined grammars and, in principle, scannerless parsing    |
| Latest release            | `4.13.2` (August 2024)                                                                                                     |

> [!NOTE]
> ANTLR is the canonical _LL-based parser generator_ data point for this survey — the top-down counterpart to the [bottom-up / LR][bottom-up] generators [`bison`/`yacc`][bison] and [`menhir`][menhir]. Its distinguishing feature is that grammar analysis happens **at parse time**: rather than statically computing a fixed-_k_ lookahead table, an ALL(\*) parser simulates an augmented transition network over the actual input and memoizes the result. That choice is what lets it accept grammars that no static LL(k)/LL(\*) tool could. Compare it against the PEG-based [`pest`][pest] (ordered choice, packrat), the GLR-adjacent incremental [`tree-sitter`][tree-sitter], and the combinator libraries [`parsec`][parsec] / [`nom`][nom] / [`chumsky`][chumsky] in the [capstone comparison][comparison].

---

## Overview

### What it solves

A classic top-down [LL(k)][top-down] parser generator (`JavaCC`, ANTLR 2/3) forces the grammar author to phrase every rule so that _k_ tokens of fixed lookahead suffice to choose an alternative. Common, natural grammars violate this constantly: a statement that begins `expr '=' …` versus `expr ';' …` shares an unbounded common prefix (`expr`), so no fixed _k_ distinguishes the alternatives. The standard remedy — manual left-factoring, or the `LR`-style power of [LALR(1)][bottom-up] generators — either contorts the grammar or pushes the author into shift/reduce conflicts. ANTLR 3's `LL(*)` tried to push lookahead to arbitrary length using a static cyclic-DFA analysis, but, as the ALL(\*) paper notes, "the `LL(*)` grammar condition is statically undecidable and grammar analysis sometimes fails to find regular expressions that distinguish between alternative productions," forcing a backtracking fallback with the same quirks as a [PEG][peg].

ANTLR 4 replaces all of that with **ALL(\*)** (Adaptive `LL(*)`), introduced in the OOPSLA 2014 paper by [Parr, Harwell & Fisher][allstar]. The abstract states the thesis directly:

> _"This paper introduces the ALL(\*) parsing strategy that combines the simplicity, efficiency, and predictability of conventional top-down LL(k) parsers with the power of a GLR-like mechanism to make parsing decisions. The critical innovation is to move grammar analysis to parse-time, which lets ALL(\*) handle any non-left-recursive context-free grammar. ALL(\*) is O(n⁴) in theory but consistently performs linearly on grammars used in practice, outperforming general strategies such as GLL and GLR by orders of magnitude."_
> — [_Adaptive LL(\*) Parsing_, Abstract][allstar]

The practical payoff: a grammar author writes the grammar the way the language is naturally specified — including ambiguous-looking common prefixes — and ANTLR figures out, at run time and for the inputs actually seen, how much lookahead each decision needs. Because the parser commits to a single interpretation (it is _not_ a forest-producing general parser), embedded actions and parse trees behave predictably, and the result is fast enough that the same engine drives both the lexer and the parser.

### Design philosophy

Three convictions run through ANTLR 4, all visible in the paper and the source tree.

**1. Move analysis from compile time to parse time.** Static `LL(*)` analysis "must consider all possible input sequences"; dynamic analysis "need only consider the finite collection of input sequences actually seen" ([§1.1][allstar]). This sidesteps the undecidability of the static grammar condition and is the root cause of ALL(\*)'s acceptance power:

> _"Unlike LL(k) and LL(\*) parsers, ALL(\*) parsers always choose the first alternative that leads to a valid parse. All non-left-recursive grammars are therefore ALL(\*)."_
> — [_Adaptive LL(\*) Parsing_, §3][allstar]

**2. Separate the grammar from the actions.** The default workflow produces a **parse tree** (a concrete syntax tree) plus a generated **listener** or **visitor** interface; application logic lives in those callbacks, not interleaved into the grammar. The `antlr.org` description frames this as the headline feature:

> _"From a grammar, ANTLR generates a parser that can build parse trees and also generates a listener interface (or visitor) that makes it easy to respond to the recognition of phrases of interest."_
> — [`antlr/antlr4` README][repo]

This is the opposite of the [`yacc`][bison] tradition of embedding C reduction actions inside the grammar, and it is what makes a grammar reusable across the ten target languages: the `.g4` file is action-free, and each language gets its own generated listener/visitor.

**3. One grammar, many targets.** A single `.g4` grammar generates a parser in any of ANTLR's runtime targets. The README enumerates them: "C++, C#, Dart, Java, JavaScript, PHP, Python3, Swift, TypeScript, and Go" ([`runtime/`][runtime-dir]). The ATN that drives prediction is serialized into the generated code as a compact integer array and rehydrated at run time by the target's runtime library, so the algorithm is implemented once per language but the _grammar analysis_ is shared.

ANTLR's reach is the empirical argument for the design. From [`antlr.org/about.html`][about]:

> _"Twitter search uses ANTLR for query parsing, with over 2 billion queries a day. The languages for Hive and Pig, the data warehouse and analysis systems for Hadoop, both use ANTLR. … Oracle uses ANTLR within SQL Developer IDE and their migration tools. NetBeans IDE parses C++ with ANTLR. The HQL language in the Hibernate object-relational mapping framework is built with ANTLR."_
> — [About ANTLR][about]

---

## How it works

### Pipeline: grammar → ATN → generated parser → run-time prediction

```text
foo.g4  ──(ANTLR tool, Java)──►  FooLexer.java   FooParser.java   FooListener.java  FooVisitor.java
                                      │               │
                                      │               ├─ serialized ATN (int[])  ← the grammar, compiled
                                      ▼               ▼
                              token stream  ────►  recursive-descent methods (one per rule)
                                                       │
                                                       ├─ at each decision: adaptivePredict(...)
                                                       │      ├─ consult lookahead DFA cache  (fast path)
                                                       │      └─ else simulate ATN, extend DFA (slow path)
                                                       ▼
                                                  ParseTree (CST)  ──►  ParseTreeWalker + Listener
                                                                   └──►  Visitor (explicit visit calls)
```

The tool (`org.antlr.v4.Tool`, [`tool/`][tool-dir]) reads the `.g4`, rewrites left-recursive rules, builds an **ATN** (augmented transition network) for the whole grammar, and emits one recursive-descent method per parser rule. Each method body is essentially a `switch` over `adaptivePredict(...)`, exactly as the paper sketches:

```java
// Generated shape for rule `stat` (Adaptive LL(*) paper, §2.3)
void stat() {                       // parse according to rule stat
    switch (adaptivePredict("stat", call_stack)) {
        case 1:                     // predict production 1
            expr(); match('='); expr(); match(';'); break;
        case 2:                     // predict production 2
            expr(); match(';'); break;
    }
}
```

`adaptivePredict` is the entire game: the bodies are trivial recursive descent, and all the intelligence lives in choosing which `case` to take.

### Core abstractions

| Concept                  | Type / artifact                                       | Role                                                                                          |
| ------------------------ | ----------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| Grammar source           | `*.g4` (lexer / parser / combined)                    | The external DSL; rules, alternatives, labels, predicates, lexer commands                     |
| Augmented transition net | `ATN`, `ATNState`, `Transition`                       | NFA-like graph mirroring grammar structure; one submachine per rule (`RuleStartState` …)      |
| ATN config               | `ATNConfig` (`state`, `alt`, `context`, predicates)   | A subparser's position: ATN state × predicted alt × call-stack graph                          |
| Config set               | `ATNConfigSet`                                        | The set of all subparser positions reachable at a given lookahead depth = one DFA state       |
| Graph-structured stack   | `PredictionContext` (`SingletonPredictionContext`, …) | Shared call-stack graph (GSS) that keeps pseudo-parallel simulation from going exponential    |
| Lookahead DFA            | `DFA`, `DFAState` (per decision, `decisionToDFA[]`)   | Memoized map from lookahead phrase → predicted production; built incrementally at parse time  |
| Prediction engine        | `ParserATNSimulator` / `LexerATNSimulator`            | Runs SLL/LL simulation, `closure`, and the two-stage strategy; the heart of the runtime       |
| Prediction policy        | `PredictionMode.{SLL, LL, LL_EXACT_AMBIG_DETECTION}`  | Stack-insensitive vs full-context simulation; exact ambiguity reporting                       |
| Token stream             | `CommonTokenStream`, `Lexer`, `Token`                 | The lexer (itself an ALL(\*) recognizer) feeds buffered tokens, possibly on multiple channels |
| Parse tree (CST)         | `ParseTree`, `RuleContext`/`ParserRuleContext`        | The concrete syntax tree the parser builds by default                                         |
| Tree traversal           | `ParseTreeWalker` + `*Listener`; `*Visitor`           | Two action-separation patterns over the CST                                                   |
| Error strategy           | `ANTLRErrorStrategy`, `DefaultErrorStrategy`          | Single-token deletion/insertion, sync-set "panic-mode" recovery                               |

### The parsing algorithm as implemented

ALL(\*) simulates an **augmented recursive transition network**, not a flat NFA, because an ATN "closely mirror[s] grammar structure":

> _"Instead of an NFA, however, ALL(\*) simulates the actions of an augmented recursive transition network (ATN) [27] representation of the grammar since ATNs closely mirror grammar structure. (ATNs look just like syntax diagrams that can have actions and semantic predicates.)"_
> — [_Adaptive LL(\*) Parsing_, §3][allstar]

At a decision point (a nonterminal with multiple productions), `adaptivePredict` runs the mechanism the paper describes as **launching subparsers**:

> _"The idea behind the ALL(\*) prediction mechanism is to launch subparsers at a decision point, one per alternative production. The subparsers operate in pseudo-parallel to explore all possible paths. Subparsers die off as their paths fail to match the remaining input. The subparsers advance through the input in lockstep so analysis can identify a sole survivor at the minimum lookahead depth that uniquely predicts a production."_
> — [_Adaptive LL(\*) Parsing_, §1.1][allstar]

Three further mechanics make this efficient and well-defined:

**Graph-structured stack (GSS).** Naive pseudo-parallel subparsers would be exponential; ALL(\*) shares their call stacks in a GSS (the `PredictionContext` graph), the same device GLL/GLR use — "GLR uses essentially the same strategy except that ALL(\*) only predicts productions with such subparsers whereas GLR actually parses with them. Consequently, GLR must push terminals onto the GSS but ALL(\*) does not" ([§1.1][allstar]). That distinction — predict-only vs parse-with — is why ALL(\*) keeps a cheap linear parse stack while gaining GLR-like decision power.

**Lookahead DFA cache.** The results of simulation are memoized into a per-decision DFA. The first time a lookahead phrase is seen, the parser does the expensive ATN simulation and records the path; subsequent identical phrases hit the DFA:

> _"ALL(\*) parsers memoize analysis results, incrementally and dynamically building up a cache of DFA that map lookahead phrases to predicted productions. … Unfamiliar input phrases trigger the grammar analysis mechanism, simultaneously predicting an alternative and updating the DFA."_
> — [_Adaptive LL(\*) Parsing_, §1.1][allstar]

Crucially the lookahead languages are often context-free, yet a DFA (which can only encode a regular set) suffices, because "dynamic analysis only needs to consider the finite context-free language subsets encountered during a parse and any finite set is regular" ([§1.1][allstar]). The DFA is the warm cache that makes a theoretically-quartic algorithm run linearly in practice.

**Ambiguity resolution by production order.** When subparsers coalesce or hit EOF together, the decision is ambiguous; ALL(\*) resolves it deterministically by rule order, exactly as [PEG][peg] ordered choice and Bison do:

> _"If multiple subparsers coalesce together or reach the end of file, the predictor announces an ambiguity and resolves it in favor of the lowest production number associated with a surviving subparser. (Productions are numbered to express precedence … Bison also resolves conflicts by choosing the production specified first.)"_
> — [_Adaptive LL(\*) Parsing_, §1.1][allstar]

### SLL, full-context LL, and two-stage parsing

The runtime's `ParserATNSimulator` ([`runtime/Java/…/atn/ParserATNSimulator.java`][simulator]) implements two precision levels. Its class Javadoc opens:

> _"The embodiment of the adaptive LL(\*), ALL(\*), parsing strategy. The basic complexity of the adaptive strategy makes it harder to understand. We begin with ATN simulation to build paths in a DFA."_
> — [`ParserATNSimulator` class Javadoc][simulator]

- **SLL** ("Strong LL") prediction ignores the parser's actual call stack, so its DFA is reusable across all call sites — "we want to create a DFA that is not dependent upon the rule invocation stack when we do a prediction." This is what hand-written recursive-descent parsers effectively do, and it is fast.
- **Full-context LL** prediction is invoked only when SLL detects a stack-sensitive conflict: "When SLL yields a configuration set with conflict, we rewind the input and retry the ATN simulation, this time using full outer context without adding to the DFA" ([`ParserATNSimulator`][simulator]). Full LL is strictly more precise but does not populate the shared DFA (the result is stack-dependent).

These compose into the **two-stage parse** that ANTLR uses by default for speed — try the whole input in pure SLL mode, and only if it errors retry in LL mode:

> _"Sam pointed out that if SLL does not give a syntax error, then there is no point in doing full LL, which is slower. We only have to try LL if we get a syntax error. … two-stage parsing with the Java grammar (Section 7) is 8x faster than one-stage optimized LL mode to parse a 123M corpus."_
> — [`ParserATNSimulator` Javadoc][simulator] / [_Adaptive LL(\*)_, §3.2][allstar]

The strategy is sound because of Theorem 6.5 — "Two-stage parsing for non-left-recursive G recognizes sentence w iff w ∈ L(G)" — which rests on the fact that "SLL either behaves like LL or gets a syntax error" ([§3.2][allstar]). For maximum speed the recommended configuration is `parser.getInterpreter().setPredictionMode(PredictionMode.SLL)` paired with a `BailErrorStrategy`, then a re-parse with the default mode on failure.

### The `.g4` grammar format

A grammar is `grammar Name; …`, with rules separated lexically by case: **parser rules** start lowercase, **lexer rules** uppercase. A grammar can be **combined** (lexer + parser in one file), or **split** into a `lexer grammar` and a `parser grammar`. The paper's running example shows the yacc-like metalanguage, including a semantic predicate:

```text
// Adaptive LL(*) paper, Figure 1 (grammar Ex), abridged
stat : expr '=' expr ';'      // production 1
     | expr ';'               // production 2
     ;
expr : expr '*' expr
     | expr '+' expr
     | expr '(' expr ')'
     | id
     ;
id   : ID
     | {!enum_is_keyword}? 'enum'   // semantic predicate gates 'enum' as an identifier
     ;
```

Rule `stat`'s two alternatives share the prefix `expr`, which "is sufficient to render `stat` undecidable from an LL(\*) perspective" — yet ALL(\*) accepts it directly ([§2.1][allstar]).

**Alternative labels and element labels.** Suffixing an alternative with `# Name` generates a dedicated `NameContext` parse-tree node and dedicated `enterName`/`exitName`/`visitName` callbacks — "All alternatives within a rule must be labeled, or none of them" ([`doc/parser-rules.md`][parser-rules]). Element labels (`x=expr`, list labels `x+=expr`) "become fields in the appropriate parse tree node class," so actions reach sub-results by name rather than by tree position.

**Semantic predicates** `{ …boolean… }?` gate an alternative on host-language state evaluated at prediction time. The `Ex` grammar's `{!enum_is_keyword}?` "allows or disallows `enum` as a valid identifier according to the predicate at the moment of prediction" — "This example demonstrates how predicates allow a single grammar to describe subsets or variations of the same language" ([§2.1][allstar]). Because ALL(\*) does not speculate during the actual parse, predicates may freely reference earlier parse state — unlike packrat/PEG tools where "a lack of mutators reduces the generality of semantic predicates" ([§8][allstar]).

### Lexer: a second ALL(\*) recognizer, modes, and commands

ANTLR's lexer is not a regular-expression scanner bolted on — it is itself an ALL(\*) recognizer (`LexerATNSimulator`):

> _"ANTLR uses a variation of ALL(\*) for lexing that fully matches tokens instead of just predicting productions like ALL(\*) parsers do. After warm-up, the lexer will have built a DFA similar to what regular-expression based tools such as lex would create statically. The key difference is that ALL(\*) lexers are predicated context-free grammars not just regular expressions so they can recognize context-free tokens such as nested comments and can gate tokens in and out according to semantic context."_
> — [_Adaptive LL(\*) Parsing_, §2.2][allstar]

Lexer matching is **maximal munch**: the rule that matches the longest input wins, and ties break by grammar order (the earliest rule wins) — the standard `lex`-family disambiguation ([`doc/lexer-rules.md`][lexer-rules]). `fragment` rules are reusable sub-patterns that never produce a token of their own (`fragment DIGIT : [0-9] ; INT : DIGIT+ ;`).

**Lexer modes** turn one lexer into a stack of context-specific sub-lexers — "Modes allow you to group lexical rules by context, such as inside and outside of XML tags. It's like having multiple sublexers, one for each context. The lexer can only return tokens matched by entering a rule in the current mode" ([`doc/lexer-rules.md`][lexer-rules]). Modes are available only in `lexer grammar` files, not combined grammars. Transitions and token disposition are driven by **lexer commands** at the end of an alternative:

| Command       | Effect                                                                           |
| ------------- | -------------------------------------------------------------------------------- |
| `skip`        | Discard the matched text and fetch the next token                                |
| `more`        | Keep accumulating text into the next token (the last rule matched sets the type) |
| `type(T)`     | Override the emitted token type                                                  |
| `channel(C)`  | Route the token to a side channel (e.g. `HIDDEN` for whitespace/comments)        |
| `mode(M)`     | Replace the top of the mode stack                                                |
| `pushMode(M)` | Push a new mode                                                                  |
| `popMode`     | Pop back to the previous mode                                                    |

```text
// Lexer modes: switch to TAG mode inside angle brackets (XML-style)
OPEN  : '<'  -> pushMode(TAG) ;
TEXT  : ~'<'+ ;
mode TAG;
CLOSE : '>'  -> popMode ;
SLASH : '/' ;
NAME  : [a-zA-Z]+ ;
S     : [ \t\r\n] -> skip ;
```

### Direct left-recursion rewriting

ALL(\*) itself cannot handle left recursion, but ANTLR 4 rewrites **direct** left recursion before generating the parser:

> _"The ALL(\*) parsing strategy itself does not support left-recursion, but ANTLR supports direct left-recursion through grammar rewriting prior to parser generation. Direct left-recursion covers the most common cases, such as arithmetic expression productions, like E → E . id, and C declarators. We made an engineering decision not to support indirect or hidden left-recursion."_
> — [_Adaptive LL(\*) Parsing_, §2.4][allstar]

(Indirect left recursion is `A → B`, `B → A`; hidden left recursion is exposed through an empty production, `A → B A`, `B → ε` — both rejected.) The rewrite turns a left-recursive `expr` rule into a precedence-climbing form: ANTLR introduces a precedence parameter `expr[int _p]` and guards each alternative with a synthesized semantic predicate that compares the operator's precedence to `_p`, so "an expansion of `expr[pr]` can match only those subexpressions whose precedence meets or exceeds `pr`." Operator **precedence is just the textual order of the alternatives**, and associativity is per-alternative via `<assoc=right>` (e.g. for `^`). This is the same idea as a hand-written [Pratt / precedence-climbing parser][pratt], generated automatically:

```text
// Left-recursive expression rule: precedence = order; '^' is right-associative.
expr : expr '^'<assoc=right> expr   // highest precedence
     | expr ('*'|'/') expr
     | expr ('+'|'-') expr
     | INT
     | '(' expr ')'
     ;
```

### Parse trees, listeners, and visitors

By default a successful parse yields a **parse tree** (CST): each rule invocation produces a `RuleContext` node, each token a `TerminalNode`. Application logic is then attached with one of two action-separation patterns over that tree — the central distinction from the [`yacc`][bison] tradition of inline reduction actions.

- **Listener** — ANTLR generates a `FooListener` interface with `enterRule`/`exitRule` (and per-labelled-alternative) methods. A built-in `ParseTreeWalker` drives a depth-first traversal and fires the callbacks; the application never navigates the tree itself.
- **Visitor** — ANTLR generates a `FooVisitor`; each `visitX` method must explicitly recurse into children and may **return a value** and **control traversal order**.

The official docs state the difference crisply:

> _"The biggest difference between the listener and visitor mechanisms is that listener methods are called independently by an ANTLR-provided walker object, whereas visitor methods must walk their children with explicit visit calls."_
> — [`doc/listeners.md`][listeners]

```java
// Listener: traversal is automatic; you implement only the callbacks you care about.
ParseTreeWalker.DEFAULT.walk(myListener, tree);

// Visitor: you drive the walk and compute return values.
int result = new EvalVisitor().visit(tree);   // each visitX() calls visit(child) explicitly
```

Listeners suit passive work (symbol tables, validation, pretty-printing) where automatic full traversal is fine; visitors suit computed results (expression evaluation, translation) where you want return values and selective descent.

---

## Algorithm & grammar class

**Formalism.** ALL(\*) is a top-down, [LL][top-down]-family strategy that simulates an **augmented transition network** (a recursive transition network with actions and semantic predicates) over the input, with a **graph-structured stack** to share subparser call stacks and a **per-decision lookahead DFA** to memoize prediction results. Prediction is _dynamic_: there is no static lookahead table, and "no static grammar analysis is needed" ([§1.1][allstar]).

**Grammar class accepted.** Any **non-left-recursive context-free grammar** — "All non-left-recursive grammars are therefore ALL(\*)" ([§3][allstar]). This strictly exceeds LL(k), LL(\*), and LALR(1): there is no fixed-_k_ constraint, common prefixes need no manual factoring, and the only structural restriction is the ban on indirect/hidden left recursion. **Direct** left recursion is accepted via the precedence-rewrite above, so in practice expression grammars are written in their natural left-recursive form. The grammar class is therefore "the full CFG class minus indirect/hidden left recursion," which is broader than every other production data point in this survey except the genuinely general [GLR/GLL/Earley][general-parsing] families.

**Ambiguity handling.** ANTLR is a _single-parse_ engine, not a forest producer — a deliberate stance, since "for computer languages, ambiguity is almost always an error" ([§1][allstar]). Genuine ambiguity is resolved by **production order** (lowest-numbered surviving alternative wins), and `PredictionMode.LL_EXACT_AMBIG_DETECTION` plus an `ANTLRErrorListener` can _report_ ambiguities to the grammar author for diagnosis. Semantic predicates give the author a manual override to disambiguate by host-language state.

**Complexity bound.** ALL(\*) is **O(n⁴)** in the worst case (Theorem 6.3): "in the worst-case, the parser must make a prediction at each input symbol and each prediction must examine the entire remaining input; examining an input symbol can cost O(n²)" ([§1.1][allstar]). The contrived worst-case grammar `S → A $`, `A → aAA | aA | a` does exhibit quartic growth empirically ([§7.4][allstar]). This is "in line with the complexity of GLR," but the lookahead-DFA cache makes real grammars run linearly (next section).

## Interface & composition model

**External DSL, not a combinator library.** ANTLR is a code generator: grammars are written in a standalone `.g4` DSL and compiled by a Java tool into target-language source. This is the opposite pole from the in-language **combinator** approach of [`parsec`][parsec], [`nom`][nom], and [`chumsky`][chumsky] (where the parser _is_ host-language code), and a peer of the other generators [`bison`/`yacc`][bison], [`menhir`][menhir], and [`pest`][pest] (which is also an external DSL but [PEG][peg]-based). The trade is the classic generator one: a separate build step and generated artifacts, in exchange for a declarative grammar that is language-agnostic and analyzable.

**Host-language integration via runtime targets.** One `.g4` generates a parser for any of the ten runtime targets ([`runtime/`][runtime-dir]); the generated parser depends only on that language's ANTLR runtime library (`antlr4-runtime`), which carries the `ParserATNSimulator`, DFA cache, and tree types. The grammar itself is **action-free by convention** (the [`grammars-v4`][grammars-v4] repository requires it), so the same grammar drives a Java tool, a Go service, and a C++ application unchanged.

**CST construction and action separation.** The parser builds a concrete syntax tree automatically; the author does not write tree-building code. Computation is layered on top via the generated **listener** (push, walker-driven) or **visitor** (pull, value-returning) interfaces — see [Parse trees, listeners, and visitors](#parse-trees-listeners-and-visitors). For inline behavior, embedded actions `{ … }` and semantic predicates `{ … }?` are still available, but the dominant idiom keeps the grammar pure and the actions in generated callbacks. Element labels (`x=`, `x+=`) and alternative labels (`# Name`) shape the generated context classes so callbacks address sub-results by name.

## Performance

**Linear in practice despite the O(n⁴) bound.** The paper's headline benchmark parses the Java 6 library + compiler corpus — **12,920 files, 3.6M lines, 123 MB** — across 10 tools and 8 strategies ([§7.1, Figure 9][allstar]):

> _"ALL(\*) outperforms the other parser generators and is only about 20% slower than the handbuilt parser in the Java compiler itself. When comparing runs with tree construction …, ANTLR 4 is about 4.4x faster than Elkhound, the fastest GLR tool we tested, and 135x faster than GLL (Rascal). ANTLR 4's nondeterministic ALL(\*) parser was slightly faster than JavaCC's deterministic LL(k) parser and about 2x faster than Rats!'s PEG."_
> — [_Adaptive LL(\*) Parsing_, §7.1][allstar]

The pathological-input contrast is starker: on a single 3.2 MB Java file, "DParser's time jumped from a corpus time of 98s to 10.5 hours," Elkhound's from 7.65s to 3.35 minutes, while "ALL(\*) parses the 3.2M file in 360ms with tree construction using 8M" ([§7.1][allstar]) — general GLR/GLL parsers degrade unpredictably in time and space where ALL(\*) stays linear and low-memory.

**The DFA cache is the linearizer.** Reparsing the same corpus is 30% faster (3.73s) because every decision now hits a warm lookahead DFA; with the DFA disabled entirely, parse times explode. The paper's conclusion is explicit: "Memoizing analysis results with DFA is critical to such performance" ([§7.4][allstar]). The cache is _shared statically_ across all instances of a generated parser (each instance gets its own simulator but they share `decisionToDFA`), so a long-lived process amortizes warm-up across every parse.

**Two-stage SLL-first.** Default parsing runs the input in stack-insensitive SLL mode and only retries in full LL on error — measured at **8× faster** than one-stage LL on the 123 MB corpus ([§3.2][allstar]). Cold-start cost (building the DFA on first sight of each lookahead phrase) is the price; warm steady-state approaches hand-written recursive-descent speed ("within 20% of the Java compiler's hand-tuned recursive-descent parser," [Conclusion][allstar]).

**Allocation & streaming posture.** ANTLR is **not** a zero-copy or streaming parser. The default workflow buffers the entire token stream (`CommonTokenStream`) and builds a full in-memory CST; the paper itself notes that tree-building "fundamentally limit[s] parsing to input files whose trees fit in memory" ([§1][allstar]). There is no SIMD / data-parallelism — ALL(\*) is intrinsically character/token-at-a-time and decision-by-decision, the antithesis of [`simdjson`][simdjson]'s whole-input vector kernels. Memory pressure is dominated by the GSS during difficult predictions and the CST after; both are bounded and small for typical grammars (8 MB for the 3.2 MB Java file above).

## Error handling & recovery

Error handling is a first-class subsystem (`DefaultErrorStrategy`, [`runtime/Java/…/DefaultErrorStrategy.java`][error-strategy]), not an afterthought, and it is one of ANTLR's most polished practical features. The default strategy implements the classic Wirth-style recovery toolkit, automatically.

**Single-token deletion and insertion** handle the two most common typos in-line, _without_ aborting the rule:

> _"LA(1) is not what we are looking for. If LA(2) has the right token, however, then assume LA(1) is some extra spurious token and delete it. Then consume and return the next token."_ (single-token deletion)
> _"If current token (at LA(1)) is consistent with what could come after the expected LA(1) token, then assume the token is missing and use the parser's TokenFactory to create it on the fly."_ (single-token insertion)
> — [`DefaultErrorStrategy` Javadoc][error-strategy]

Deletion reports an "extraneous input" error and consumes the spurious token; insertion reports a "missing" token and fabricates one so the parse can continue, leaving an error node in the tree.

**Sync-set "panic-mode" recovery.** When inline repair is impossible, the parser resynchronizes by consuming tokens until it reaches one in a computed **recovery set** — the context-sensitive FOLLOW set assembled from the rule-invocation stack:

> _"During rule invocation, the parser pushes the set of tokens that can follow that rule reference on the stack; this amounts to computing FIRST of what follows the rule reference in the enclosing rule. … We need the combined set of all context-sensitive FOLLOW sets — the set of all tokens that could follow any reference in the call chain."_
> — [`DefaultErrorStrategy` block comment][error-strategy]

The `sync()` method additionally implements "Jim Idle's magic sync" — at the start of loops and optional subrules it pre-emptively consumes stray tokens so a single bad token inside a `(...)*` does not blow up the whole enclosing rule. Recovery emits structured `RecognitionException`s through an `ANTLRErrorListener`, and the default console listener prints `line L:C` diagnostics. A `BailErrorStrategy` is provided for the speed-first path (bail on first error, used with two-stage SLL parsing).

**Incremental reparsing / IDE-readiness.** ANTLR does **not** do incremental reparsing — there is no built-in mechanism to reuse a prior tree across edits (the deliberate IDE-grade incremental niche belongs to [`tree-sitter`][tree-sitter]). Its IDE story is instead "fast full reparse + good error recovery": warm-DFA reparse speed plus error nodes make it serviceable for editor tooling (NetBeans parses C++ with it; the ANTLRWorks/IntelliJ plugin uses it for grammar development), but a keystroke triggers a full reparse rather than a localized patch. This absence is a genuine architectural finding: ALL(\*)'s shared, append-only DFA cache and whole-token-stream buffering are tuned for repeated full parses, not for surgical tree edits.

## Ecosystem & maturity

**Adoption.** ANTLR is among the most-deployed parser generators in existence. Beyond the production users quoted above (Twitter query parsing at 2B+ queries/day, Hive, Pig, Oracle SQL Developer, Hibernate HQL, NetBeans), the modern data ecosystem leans on it heavily: **Trino/Presto, Apache Cassandra (CQL), Apache Spark SQL, and Groovy** all ship ANTLR grammars. The [`grammars-v4`][grammars-v4] repository — "a collection of formal grammars written for ANTLR v4 … with the expectation that the grammars are free of actions" — provides hundreds of ready grammars (Java, C/C++, C#, Python, Go, Rust, JavaScript/TypeScript, many SQL dialects, COBOL, Fortran, JSON, XML, YAML, and more), an enormous reuse surface no other generator matches.

**Tooling.** First-party: the `antlr4` command-line tool, the `TestRig`/`grun` parse-tree visualizer, and the IntelliJ ANTLR plugin (interactive parse-tree inspection, profiling, ambiguity highlighting). The `PredictionMode.LL_EXACT_AMBIG_DETECTION` mode and the runtime profiler surface decision costs and ambiguities for grammar tuning.

**Stability and maturity.** ANTLR has been continuously developed since 1989 ("Terence Parr is the maniac behind ANTLR and has been working on ANTLR since 1989," [About][about]); ANTLR 4 / ALL(\*) shipped January 2013, with the current `4.13.2` released August 2024 under the permissive **BSD-3-Clause** license. The tool is on every Linux and macOS distribution. The ten runtime targets are the canonical "many ports," but they are first-party — all generated from and validated against the same tool and test suite, not independent reimplementations.

**Notable derivatives & relatives.** The OOPSLA paper spawned formal follow-ups, notably **CoStar** (PLDI 2021), "a verified ALL(\*) parser" mechanized in Coq — an unusual mark of an algorithm rigorous enough to be machine-checked. ANTLR's lineage (ANTLR 2 → LL(k), ANTLR 3 → LL(\*), ANTLR 4 → ALL(\*)) and `tunnelvisionlabs/antlr4` (Sam Harwell's optimized fork) round out the family.

---

## Strengths

- **Accepts nearly any CFG without contortion**: no fixed-_k_ limit, no manual left-factoring, direct left recursion via precedence rewriting — "All non-left-recursive grammars are therefore ALL(\*)."
- **Grammar/action separation**: action-free `.g4` plus generated listener/visitor keeps grammars reusable across all ten targets; the [`grammars-v4`][grammars-v4] library is the dividend.
- **Linear, low-memory in practice**: warm DFA + two-stage SLL puts it within ~20% of hand-written recursive descent and orders of magnitude ahead of GLR/GLL on real grammars.
- **Excellent automatic error recovery**: single-token deletion/insertion plus FOLLOW-set sync gives useful diagnostics and continued parsing for free.
- **Ten production runtime targets** from one grammar, all first-party and co-tested.
- **Predictable single-parse semantics**: no parse forests; ambiguity resolved by rule order and reportable for diagnosis; arbitrary mutators/predicates are safe because there is no speculation during the real parse.
- **Vast ecosystem and longevity**: 35+ years of development, ubiquitous in data/query engines, rich IDE tooling, BSD-licensed.

## Weaknesses

- **No incremental reparsing**: a per-edit change triggers a full reparse; the IDE-grade incremental niche belongs to [`tree-sitter`][tree-sitter].
- **Not streaming / not zero-copy**: buffers the whole token stream and builds an in-memory CST, so input is bounded by available memory.
- **O(n⁴) worst case** is real (contrived grammars provoke it) and cold-start DFA construction costs latency on the first parse / first sight of each lookahead phrase.
- **No indirect or hidden left recursion**: must be refactored by hand.
- **No SIMD / data-parallelism**: intrinsically token-at-a-time and decision-by-decision — far from [`simdjson`][simdjson]-class throughput on simple structured formats.
- **Dynamic analysis shifts burden to testing**: ambiguities surface at parse time on specific inputs, so "programmers must cover as many grammar position and input sequence combinations as possible" ([§1.1][allstar]).
- **External-DSL ergonomics**: a separate generation step and generated artifacts, versus the no-codegen immediacy of combinator libraries.

## Key design decisions and trade-offs

| Decision                                                       | Rationale                                                                                     | Trade-off                                                                                       |
| -------------------------------------------------------------- | --------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| Move grammar analysis to **parse time** (ALL(\*))              | Sidesteps the undecidable static LL(\*) condition; accepts any non-left-recursive CFG         | O(n⁴) worst case; ambiguities surface dynamically on specific inputs, raising the testing bar   |
| Memoize predictions in a **lookahead DFA** cache               | Turns repeated quartic simulation into amortized-linear table lookups; warm reparse is fast   | Cold-start cost on first sight of each lookahead phrase; cache memory grows with seen phrases   |
| **Two-stage** SLL-then-LL parsing                              | SLL is stack-insensitive and ~8× faster; LL is only needed on actual conflicts                | Pathological inputs are parsed twice; needs sound SLL≡LL-or-error guarantee (Theorem 6.5)       |
| **Single parse**, ambiguity by production order (not a forest) | Computer languages treat ambiguity as an error; keeps actions/predicates predictable          | Cannot return all parses of a genuinely ambiguous grammar (no GLR-style forest)                 |
| **Separate grammar from actions** (listener/visitor + CST)     | Action-free grammars are reusable across ten targets and analyzable; clean app/grammar split  | Extra indirection vs inline actions; a full CST may be heavier than streaming reductions        |
| **Rewrite direct left recursion** to precedence-climbing form  | Lets authors write natural left-recursive expression grammars; precedence = alternative order | Indirect/hidden left recursion unsupported; generated rule shape is non-obvious                 |
| **Lexer is its own ALL(\*) recognizer** (with modes/commands)  | Context-free, predicated tokens (nested comments, mode stacks); same engine as the parser     | Heavier than a static DFA scanner; maximal-munch + rule-order ties can surprise grammar authors |
| **Code generation to 10 first-party runtimes**                 | One grammar, many languages; shared serialized ATN; co-tested targets                         | Build step + generated artifacts; runtime library dependency per target                         |

---

## Sources

- [`antlr/antlr4` — GitHub repository (tool + runtimes, BSD-3-Clause)][repo]
- [`tool/` — the ANTLR tool: grammar parsing, ATN construction, left-recursion rewrite, code generation][tool-dir]
- [`runtime/` — the ten runtime targets (Java, C#, Python3, JavaScript, TypeScript, Go, C++, Swift, PHP, Dart)][runtime-dir]
- [`runtime/Java/.../atn/ParserATNSimulator.java` — SLL/LL prediction, two-stage parsing, DFA cache][simulator]
- [`runtime/Java/.../DefaultErrorStrategy.java` — single-token deletion/insertion, sync-set recovery][error-strategy]
- [`doc/parser-rules.md` — parser rules, alternative/element labels][parser-rules]
- [`doc/lexer-rules.md` — lexer rules, fragments, modes, commands, maximal munch][lexer-rules]
- [`doc/left-recursion.md` — direct left-recursion rewriting and `<assoc=right>`][left-recursion]
- [`doc/listeners.md` — listener vs visitor traversal][listeners]
- [`antlr/grammars-v4` — hundreds of action-free ANTLR 4 grammars][grammars-v4]
- Terence Parr, Sam Harwell, Kathleen Fisher, [_Adaptive LL(\*) Parsing: The Power of Dynamic Analysis_, OOPSLA 2014][allstar] (also as the [ANTLR tech report PDF][allstar])
- [antlr.org][site] · [About ANTLR (production users, history)][about]
- Terence Parr, _The Definitive ANTLR 4 Reference_, Pragmatic Bookshelf, 2013 (ISBN 978-1-93435-699-9)
- Related: [umbrella][umbrella] · [concepts glossary][concepts] · [comparison][comparison] · [top-down / LL][top-down] · [bottom-up / LR][bottom-up] · [`bison`/`yacc`][bison] · [`menhir`][menhir] · [`pest`][pest] · [PEG & packrat][peg] · [Pratt precedence][pratt] · [general parsing (GLR/GLL/Earley)][general-parsing] · [`tree-sitter`][tree-sitter] · [`simdjson`][simdjson] · [`parsec`][parsec] · [`nom`][nom] · [`chumsky`][chumsky]

<!-- References -->

[repo]: https://github.com/antlr/antlr4
[tool-dir]: https://github.com/antlr/antlr4/tree/master/tool
[runtime-dir]: https://github.com/antlr/antlr4/tree/master/runtime
[simulator]: https://github.com/antlr/antlr4/blob/master/runtime/Java/src/org/antlr/v4/runtime/atn/ParserATNSimulator.java
[error-strategy]: https://github.com/antlr/antlr4/blob/master/runtime/Java/src/org/antlr/v4/runtime/DefaultErrorStrategy.java
[parser-rules]: https://github.com/antlr/antlr4/blob/master/doc/parser-rules.md
[lexer-rules]: https://github.com/antlr/antlr4/blob/master/doc/lexer-rules.md
[left-recursion]: https://github.com/antlr/antlr4/blob/master/doc/left-recursion.md
[listeners]: https://github.com/antlr/antlr4/blob/master/doc/listeners.md
[doc-index]: https://github.com/antlr/antlr4/blob/master/doc/index.md
[grammars-v4]: https://github.com/antlr/grammars-v4
[allstar]: https://www.antlr.org/papers/allstar-techreport.pdf
[site]: https://www.antlr.org/
[about]: https://www.antlr.org/about.html
[umbrella]: ./index.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[top-down]: ./theory/top-down.md
[bottom-up]: ./theory/bottom-up.md
[general-parsing]: ./theory/general-parsing.md
[peg]: ./theory/peg-packrat.md
[pratt]: ./theory/pratt-precedence.md
[bison]: ./bison-yacc.md
[menhir]: ./menhir.md
[pest]: ./pest.md
[tree-sitter]: ./tree-sitter.md
[simdjson]: ./simdjson.md
[parsec]: ./haskell-parsec.md
[nom]: ./rust-nom.md
[chumsky]: ./rust-chumsky.md
