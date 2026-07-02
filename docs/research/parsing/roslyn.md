# Roslyn (C#)

The **.NET Compiler Platform** — Microsoft's open-source C# and Visual Basic compiler — built on **immutable red/green syntax trees**, **incremental reparse** with near-total subtree reuse, and a **compiler-as-a-service** API surface. Roslyn is the design that took the red-green [persistent-tree][incremental] model and the "the compiler is a queryable platform, not a black box" stance from research into a mainstream, production compiler that ships in every Visual Studio.

| Field                     | Value                                                                                                                      |
| ------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| Language                  | C# and Visual Basic (the compilers are themselves written in C#/VB)                                                        |
| License                   | MIT (`License.txt`: _"The MIT License (MIT) … Copyright (c) .NET Foundation and Contributors"_)                            |
| Repository                | [`dotnet/roslyn`][repo]                                                                                                    |
| Documentation             | [learn.microsoft.com — _Work with syntax_][work-with-syntax]; in-repo `docs/compilers/Design/`                             |
| Key authors               | Microsoft — the .NET Foundation and Contributors (the C#/VB compiler team)                                                 |
| Category                  | Incremental / IDE-grade compiler platform                                                                                  |
| Algorithm / grammar class | Hand-written **recursive descent**, _"mostly context-free"_, producing a full-fidelity red/green tree                      |
| Lexing model              | Hand-written lexer feeding the parser through the **blender** (token/node supply from the old tree or the lexer)           |
| Output                    | **Full-fidelity** red/green syntax tree; a **DAG** at the green (immutable) level, a lazy tree at the red (public) level   |
| Incrementality model      | Subtree reuse keyed on the `TextChange`; unchanged green nodes are reused by literal object identity — ~**99.99%** typical |
| Notes                     | The parser is _syntax only_; declaration/binding/emit are separate phases exposed as their own API layers                  |

> [!NOTE]
> This deep-dive surveys the **C# compiler front-end and its syntax model** as documented in `dotnet/roslyn`'s design notes (`docs/compilers/Design/Red-Green Trees.md`, `Incremental Parser.md`) and the .NET Compiler Platform overview. The full platform (semantic model, symbols, workspaces, analyzers, scripting) is referenced where it frames the parser, but the syntax layer is the subject. Visual Basic shares the same red/green infrastructure and is mentioned only where it differs.

---

## Overview

### What it solves

A traditional compiler is a batch pipeline: text in, assembly out, and every intermediate understanding it built is _"promptly forgotten after the translated output is produced"_ ([`Roslyn-Overview.md`][overview]). An IDE cannot live with that. IntelliSense, refactoring, "Find all references", live squiggles, and go-to-definition all need the compiler's syntactic and semantic knowledge, continuously, over a file that is **being typed into**. Roslyn's stated mission is to invert the black box:

> _"Traditionally, compilers are black boxes — source code goes in one end, magic happens in the middle, and object files or assemblies come out the other end. … This is the core mission of Roslyn: opening up the black boxes and allowing tools and end users to share in the wealth of information compilers have about our code. Instead of being opaque source-code-in and object-code-out translators, through Roslyn, compilers become platforms — APIs that you can use for code related tasks in your tools and applications."_ — [`Roslyn-Overview.md`][overview]

Two demands follow from serving an editor rather than a build, and both shape the syntax model:

1. **Reparse must scale with the _edit_, not the file.** A keystroke in one method of a 100,000-line file must not reallocate the whole tree. Roslyn's incremental parser reuses the previous tree so a _"typical edit allocates only bytes: a handful of new parent nodes and some pointers"_ ([`Incremental Parser.md`][roslyn-inc]).
2. **The tree must be immutable, thread-safe, and shareable.** Many IDE features analyze the same tree concurrently; a snapshot that _"never changes"_ can be read _"on multiple threads, without locks or duplication"_ ([`Roslyn-Overview.md`][overview]).

The reconciliation of "immutable and shareable" with "exposes absolute positions and parent pointers" is the **red/green tree**, the heart of this page and the pattern Roslyn popularized (Rust's [`rowan`][rowan] under [rust-analyzer], and [Lezer]'s tree, are later descendants — see [incremental & query-based parsing][rg-section]).

### Design philosophy

The syntax layer rests on three convictions, each documented and each traceable to a concrete mechanism:

1. **Immutability is the enabler, not the obstacle.** Green nodes are _"fully immutable. Once created, a green node never changes"_ ([`Red-Green Trees.md`][roslyn-rg]), which buys thread-safety, predictability, and — the payoff — free structural sharing. "Modifying" a tree via `WithXxx`/`SyntaxFactory` allocates only the root-to-edit spine and reuses everything else.
2. **Separate the immutable core from the positional view.** The two things API users most want — absolute `Span` and `Parent` — are exactly the two things an immutable, shared node _cannot_ store (the same node sits at different offsets under different parents). So they are split out onto lazy **red** wrappers computed on demand.
3. **Full fidelity is non-negotiable.** _"Every character from the source file is represented somewhere in the tree … Concatenating all tokens and trivia in order reproduces the original source exactly"_ ([`Red-Green Trees.md`][roslyn-rg]). This is what lets refactorings rewrite one node while preserving the user's formatting everywhere else, and what lets the incremental parser treat nodes as an exact proxy for their source text.

Within [this survey][umbrella] Roslyn is the **production compiler platform** data point in the incremental/query-based cluster: contrast the editor-first parser generators [tree-sitter] and [Lezer] (parse only; a host wires the analyses), the query-graph-native [rust-analyzer] ([salsa] over [`rowan`][rowan]), and the demand-driven [`rustc` query system][rustc]. Roslyn's incrementality is concentrated in the _parse_ (red/green subtree reuse); its higher phases reuse work through immutable `Compilation` snapshots and the workspace model rather than a general memoized-query engine. See the [comparison][comparison].

---

## How it works

### Core types: the red side vs. the green side

Every public API type has an internal green counterpart; the public struct/class is a thin facade over the shared green object ([`Red-Green Trees.md`][roslyn-rg], [`Roslyn-Overview.md`][overview]):

| Public (red) type | Kind             | Role                                                                               | Green counterpart                                      |
| ----------------- | ---------------- | ---------------------------------------------------------------------------------- | ------------------------------------------------------ |
| `SyntaxTree`      | class (abstract) | A whole parse tree; `CSharpSyntaxTree.ParseText` produces one; immutable snapshot  | owns the root `GreenNode`                              |
| `SyntaxNode`      | **class**        | Non-terminal construct (declaration/statement/clause/expression); `Span`, `Parent` | a `GreenNode` subclass (kind + width + children slots) |
| `SyntaxToken`     | **struct**       | Terminal (keyword/identifier/literal/punctuation); value-typed, no heap on access  | a heap green token (specialized: identifier/keyword)   |
| `SyntaxTrivia`    | **struct**       | Whitespace/comments/directives; attached as leading/trailing trivia of a token     | a heap green trivia node (pre-cached common patterns)  |
| `SyntaxList<T>`   | **struct**       | An ordered child list; `null`/singleton/`WithTwoChildren`/array at green level     | `null`, a bare child, a `WithNChildren`, or an array   |
| `SemanticModel`   | class            | The **bound** view — identifiers resolved to `ISymbol`s (a separate phase)         | (not a syntax node — the binding layer)                |

A green node stores exactly **kind, width, children (by integer slot), and diagnostics** — and pointedly _not_ absolute position or parent. The red wrapper supplies position and parent by computing them lazily from the green width tree as you navigate. Green nodes are walked generically by slot index (uniform traversal) _or_ by strongly-typed properties (e.g. a `BinaryExpressionSyntax`'s `Left`/`OperatorToken`/`Right`).

### The red/green split

There are two parallel representations of the same structure ([`Red-Green Trees.md`][roslyn-rg]):

> _"**Green nodes**: The internal, immutable representation. These nodes store only their syntactic *kind*, their *width* (character count), and their *children*. They do not store absolute text positions or parent pointers. **Red nodes**: The public-facing wrappers. These provide the familiar API with properties like `Span`, `Parent`, and strongly-typed child accessors."_ — [`Red-Green Trees.md`][roslyn-rg]

The rationale is stated as a fundamental tension:

> _"This split exists because immutability and efficient navigation are fundamentally at odds. An immutable node cannot store a parent pointer (since the same node might have different parents in different contexts). But users need parent navigation. The red/green pattern solves this: green nodes are immutable and shareable, while red nodes provide the navigation API by computing positions and parents on demand."_ — [`Red-Green Trees.md`][roslyn-rg]

A green node stores **kind + width + children (via integer slots) + diagnostics**, and crucially _not_ absolute positions or parents. Because it is position-free, _"a method declaration that was at position 10,000 can be reused at position 10,050 after an earlier edit. The green node is identical; only the red wrapper's computed position changes"_ ([`Red-Green Trees.md`][roslyn-rg]).

### It's a DAG, not a tree

Position-freedom and parent-freedom make green nodes freely shareable — the _same_ object can appear in many places. The empty parameter list `()` _"appears in thousands of methods across a large solution … the *same* green node object can be shared across all of them"_, and even within one file _"if a file contains ten methods that all have empty parameter lists `()`, all ten can point to the same `ParameterList` green node"_. Hence Roslyn's own caveat:

> _"This means 'green tree' is actually a misnomer. The green structure is a **directed acyclic graph** (DAG), not a tree. Multiple parents can share the same child."_ — [`Red-Green Trees.md`][roslyn-rg]

The red layer hides the DAG: _"Each red node appears to be a distinct object with its own unique parent and position, even though the underlying green nodes may be shared."_

### Everything is a node at the green level (and red wrappers are nearly free)

The public API distinguishes `SyntaxNode` (a class), `SyntaxToken`, `SyntaxTrivia`, and `SyntaxList<T>` (structs). At the green level _"all of these are heap-allocated node objects. There are no structs. Every green token, every piece of green trivia, every green list is a `GreenNode` subclass"_ — because a struct cannot be shared by reference, and sharing is the whole point. That choice makes red wrappers minimal. A red `SyntaxToken` struct is just _"a pointer to the parent red node, an integer position, and a pointer to the underlying green token node"_ — so _"no heap allocation occurs when you access a token."_ The impact:

> _"Since tokens, lists, and trivia typically constitute **75% or more** of a syntax tree's elements, this design avoids the vast majority of allocations that would otherwise occur when traversing a tree."_ — [`Red-Green Trees.md`][roslyn-rg]

### Green-node caching and the specialization tricks

Because green nodes are internal, Roslyn can specialize their storage aggressively — the freedom the immutable/object design was chosen to buy:

- **Green node cache.** When the parser builds a green node it first checks a cache of common nodes and reuses an equivalent one. To bound combinatorial blow-up, _"only nodes with **3 or fewer children** are eligible for caching. The cache itself holds **65,536** entries. Despite these limitations, analysis of parsing the Roslyn codebase itself shows a **55% cache hit rate** for cacheable nodes"_ ([`Red-Green Trees.md`][roslyn-rg]). This cache is what turns the theoretical shareability of `()` into _actual_ sharing.
- **List optimizations.** An empty list is `null` (no allocation); a singleton list is _"the parent green node points directly to the single child element"_ (no list node); lists of **2, 3, 4** get specialized subclasses (`WithTwoChildren`, `WithThreeChildren`, …) that store children in fields, not an array; **5+** use an array. This is tuned to reality: _"**90% or more of lists contain 4 elements or fewer**."_
- **Token storage.** Identifier tokens store a text pointer (width derives from string length); keyword tokens store _only_ their kind (a `return` token infers text `"return"` and width `6`); and Roslyn _"pre-computes and caches every keyword token without trivia, as well as variants with common leading and trailing whitespace patterns"_ (e.g. `void ` with a trailing space) and common trivia (single space, newline, indentation runs) — so the parser _"doesn't allocate anything — it just returns the pre-cached node."_

### Lazy, cached red nodes

Red nodes are built _"on-demand when you traverse the syntax tree. If you never access a particular node, its red wrapper is never created."_ For red `SyntaxNode` (a class) creation is cached, because nodes have reference identity — _"users expect that accessing the same child twice returns the same object"_; the parent atomically writes the child into its field, so _"whichever thread wins the race sets the pointer that all subsequent reads will see."_ The struct types (`SyntaxToken`/`SyntaxTrivia`/`SyntaxList<T>`) need no caching — value semantics make two structs over the same green node at the same position equal. Certain large red lists (currently member/accessor blocks) even hold their children by **weak reference**, letting the GC reclaim red memory that nothing else observes, since a red node is _"purely a cache over immutable green structure."_

### Incremental reparse: the blender

A batch parse is `Parse: Text → SyntaxTree`. An incremental parse takes more inputs ([`Incremental Parser.md`][roslyn-inc]):

```text
IncrementalParse: (NewText, OldTree, TextChange) → NewSyntaxTree
```

The engine that makes this work is the **blender** (`Blender.cs`, `Blender.Reader.cs`), which supplies tokens to the recursive-descent parser _"drawing them either from the old tree (when safe) or from the lexer (when necessary)."_ It maintains a **cursor** into the old tree and a `_changeDelta` — the cumulative length difference between old and new text up to the current position. Before the edit the delta is zero and positions coincide; after the edit, an old-tree position is mapped to new text by adding the delta. The parser always knows its exact new-text position (it starts at 0 and accumulates each node/token's width), and mapping back to the old text is _"trivial"_ via the delta.

Reuse is decomposed into two granularities:

- **Token reuse.** For each requested token the blender checks: is the cursor synchronized with an old token, does that token fall entirely outside the edited region, and does it pass the reusability checks — if so it returns the old token _"with no lexing required."_
- **Node reuse via "crumbling".** The real win. The blender keeps a queue seeded with the old root; a node that intersects the edit (or is otherwise ineligible) is **crumbled** — removed and replaced by its children — until tokens surface. _"This lazy crumbling means we only break down the parts of the tree we actually need to examine. Huge subtrees that are entirely before or after the edit remain intact."_ Whole `MethodDeclarationSyntax` or statement nodes are grabbed from the old tree wholesale.

The decisive property is _literal_ reuse:

> _"When we say a node is 'reused,' we mean the new tree points to the exact same object in memory. An enormous subtree from one parse can be used *as is* in the next tree with zero copying. The only new allocations are the parent nodes along the path from the root to the edit location."_ — [`Incremental Parser.md`][roslyn-inc]

### Reuse only at strategic points — and never expressions

Node reuse is attempted only in the loops that parse **lists of high-level constructs** — compilation-unit members, type members, and statements — via `TryReuseStatement` and `CanReuseMemberDeclaration`, each gated by `IsIncrementalAndFactoryContextMatches`. These points are natural list boundaries _and_ chosen because they are free of lookahead hazards. **Expressions are deliberately never reused:**

> _"Expression parsing in C# involves significant lookahead, lookbehind, and context sensitivity: Is `<` the start of a generic argument list or a less-than operator? Is `(` a cast, a parenthesized expression, a tuple, a lambda, a deconstruction …? … An edit *after* an expression might retroactively change how that expression should have been parsed. Rather than building elaborate (and error-prone) logic … Roslyn takes the conservative approach: expressions are always reparsed."_ — [`Incremental Parser.md`][roslyn-inc]

The bet is that expressions are small and cheap to reparse, while the large wins (arbitrarily big statements and members) sit exactly at the reuse points. The [Caveats](#weaknesses) call out where the bet fails (million-element array initializers, giant interpolated strings).

### Worked example: one keystroke in a huge class

The incremental-parser notes trace a concrete edit ([`Incremental Parser.md`][roslyn-inc]). In a class with a thousand methods, inside `Method500`'s body, the user changes `var x = 1;` to `var x = true;` — a 1-character span replaced by 4, so the change delta is **+3**:

1. **Descend to the edit.** The blender walks from the root; `CompilationUnitSyntax` spans the edit, so it **crumbles** into its children.
2. **Reuse unaffected members.** Methods 0–499 don't intersect the edit; the type-member loop calls `CanReuseMemberDeclaration` for each and reuses them wholesale — no reparsing of their bodies.
3. **Crumble the hit method.** `Method500` intersects the edit, so it crumbles into modifiers, return type, name, parameters, body.
4. **Reuse unaffected statements.** Inside the body, statements 0–99 don't intersect the edit; `TryReuseStatement` reuses each.
5. **Reparse the hit statement.** `var x = 1` intersects the edit and is reparsed token by token (tokens before the edit within it may still be reused).
6. **Resync past the edit.** Statements 101–200 follow the edit; the blender adds the +3 delta, resynchronizes with the old tree, and reuses them.
7. **Reuse the tail.** Methods 501–1000 are reused with position adjustment via the delta.

_"Out of potentially thousands of nodes and tens of thousands of tokens, only a handful are actually reparsed."_ The counter-example is instructive: typing `/*` in `Method250` when a `*/` sits in `Method750` makes the lexer produce _"a single enormous multi-line comment token"_ swallowing Methods 251–749, which then cannot be reused as members — yet the blender still resyncs after the `*/` and reuses Methods 751–1000, so even this high-impact edit stays bounded by the full-reparse cost.

### Full fidelity and immutable edits

Every character lives in the tree — tokens carry **leading and trailing trivia** (whitespace, comments, preprocessor directives), a node's `Span` excludes trivia while its `FullSpan` includes it, and concatenating all tokens+trivia reproduces the source byte-for-byte ([`Roslyn-Overview.md`][overview], [`Red-Green Trees.md`][roslyn-rg]). Editing is persistent: _"you get a new tree that shares as much structure as possible with the old tree. Only the nodes along the path from the root to the modification point are newly allocated; everything else is reused"_ ([`Red-Green Trees.md`][roslyn-rg]) — the same root-to-edit-spine allocation that [persistent red-green trees][rg-section] give in the abstract.

---

## Algorithm & grammar class

- **Formalism.** A **hand-written recursive-descent** parser (`LanguageParser.cs`), _"mostly context-free, meaning that language productions like `ClassDeclaration`, `MethodDeclaration`, `Statement`, and `Expression` correspond directly to parsing functions"_ ([`Incremental Parser.md`][roslyn-inc]). This is the [top-down][top-down] family — not a generated [LR][bottom-up] table like [Bison][bison]/[tree-sitter] — chosen for control over error recovery, precise diagnostics, and the context tracking C# needs.
- **The "mostly" qualifier.** C# has context-sensitive tokens: `await` is a keyword only inside an `async` method; `field` only inside a property accessor. The parser tracks these via **bit flags** on nodes, _"and the overall design strives to minimize context sensitivity to maximize incremental reuse potential"_ — because a node parsed under one flag set cannot be reused under another (see [Incrementality model](#incrementality-model)).
- **Expression precedence.** Handled inside the recursive-descent expression parser (precedence-climbing style), not by a grammar's declared precedence table — the flip side of hand-writing the parser.
- **Lexing.** A hand-written lexer produces tokens on demand, mediated by the blender so that an incremental parse pulls tokens from the old tree when synchronized and only invokes the lexer across the edited region. Some tokens are **synthesized by the parser** rather than the lexer — the canonical case is `>>`, which is either a right-shift operator or two closing brackets in `List<List<int>>`; such tokens _"can't simply be reused from the old tree because their interpretation depends on parsing context."_

## Interface & composition model

- **The tree as the interface.** The public surface is the **Syntax API**: `SyntaxTree` (parse with `CSharpSyntaxTree.ParseText`), `SyntaxNode`, `SyntaxToken`, `SyntaxTrivia`, `SyntaxList<T>` ([`Getting-Started-C#-Syntax-Analysis.md`][syntax-analysis]). A parse is one call:

  ```csharp
  SyntaxTree tree = CSharpSyntaxTree.ParseText(sourceText);
  var root = (CompilationUnitSyntax)tree.GetRoot();
  var firstMember = root.Members[0];
  ```

- **Layered pipeline, each phase an API.** Roslyn mirrors the classic pipeline as separate, individually queryable components ([`Roslyn-Overview.md`][overview]): **parse** → syntax tree; **declaration** → hierarchical symbol table; **bind** → the `SemanticModel` (identifiers matched to `ISymbol`s); **emit** → IL. Above the compiler layer sits the **Workspaces** layer (`Workspace`/`Solution`/`Project`/`Document`), the entry point for whole-solution analysis and refactoring. The parser produces only the _syntactic_ layer; semantics live in the **bound tree**, whose design principle is that its _"shape … should correspond to the shape of the program's static semantics"_ and that a bound node should _"capture all semantic information embedded in the syntax"_ ([`Bound Node Design.md`][bound]).
- **Construction direction.** The green tree is built **top-down** by recursive descent (a parse function calls into sub-productions and assembles their green results), with green-node caching and list specialization applied as nodes are created; red nodes are then materialized **lazily top-down** from the root as consumers navigate.
- **Immutable snapshots as the composition unit.** There is no mutation API; every "change" (`WithXxx`, `SyntaxFactory`, a new `Compilation`, a new `Solution`) produces a new immutable snapshot sharing structure with the old. This is how Roslyn composes edits over time without a general query engine — the sharing _is_ the incrementality.

## Incrementality model

- **Unit of reuse.** The **green subtree**, reused by literal object identity — statements and member declarations at the strategic reuse points, individual tokens elsewhere, never expressions.
- **What triggers reparse (invalidation granularity).** The `TextChange` region plus wherever the blender cannot resynchronize. A node/token is ineligible for reuse when it **intersects the edit**, **carries diagnostics**, contains **skipped** or **missing** tokens, was parsed under a **different context flag** (`IsIncrementalAndFactoryContextMatches` fails), or is a context-dependent **synthetic token** like `>>` (see [Error handling & recovery](#error-handling--recovery)). Everything else is spliced in untouched.
- **Reuse ratio.** For the common case Roslyn reports _"incremental parses complete in *microseconds* with memory reuse approaching **99.99%**"_; worst case (e.g. typing `/*` that swallows half the file into one comment token) _"degenerates to the same cost as a full reparse. Incremental parsing is never appreciably worse than full parsing, while it is normally much better"_ ([`Incremental Parser.md`][roslyn-inc]). The cost is _"commensurate with the *impact* of the edit, not just its size."_
- **Higher-phase incrementality.** Beyond the parse, Roslyn reuses at the granularity of **immutable `Compilation`/`Solution` snapshots** (create a new one specifying a delta), not a general memoized dependency graph. This is the axis where [rust-analyzer]/[salsa] and [`rustc`][rustc] go further, memoizing name-resolution, types, and diagnostics as demand-driven [queries][rg-section]; Roslyn's binding is recomputed per-compilation and cached at the semantic-model level rather than as a fine-grained query DAG. The syntax layer, though, is a textbook [persistent red-green incremental parser][rg-section].
- **Allocation posture.** A typical edit _"allocates only bytes"_; combined with lazy red creation and the 75%-no-red-allocation property, the syntax layer _"allocates very little under normal usage patterns."_

## Performance

- **Time.** A cold parse is linear in input via recursive descent. The headline is the incremental path: work proportional to the edited region plus the root-to-edit spine, so reparse latency tracks edit impact, not file size — the same asymptotic story as [Wagner & Graham's `O(t + s·lg N)`][incremental].
- **Memory / allocation.** Four compounding wins, all above: green nodes shared within and across trees (DAG + 65,536-entry cache, 55% hit rate); tokens/lists/trivia (75%+ of the tree) incur **no red allocation**; red nodes are lazy and sometimes weakly held; and incremental reuse means a keystroke allocates a handful of parent nodes rather than the tens of megabytes a from-scratch parse of a large file would.
- **Concurrency.** Full immutability makes every tree, `Compilation`, and `Solution` a lock-free snapshot readable from many threads — a first-class performance property for an IDE, not an afterthought.
- **Published figures.** The concrete numbers (99.99% reuse, microsecond reparse, 55% cache hit, 75%/90% distributions) come from Roslyn's own design notes analyzing the parse of the Roslyn codebase itself; treat them as the project's measured claims for _typical_ C# editing, not adversarial worst cases (which the docs explicitly bound to "no worse than a full reparse").

## Error handling & recovery

- **Full-fidelity recovery.** A malformed or half-typed file still yields a complete, round-trippable tree ([`Roslyn-Overview.md`][overview]). The parser uses two techniques: insert a **missing token** (an expected token with an _empty span_ and `IsMissing == true`) where one was required but absent, or **skip tokens** it cannot incorporate, attaching them as `SkippedTokens` trivia to preserve the fidelity invariant. Both are queryable, so IDE features can localize the error precisely.
- **Recovery and incrementality interact — conservatively.** Nodes that carry the artifacts of recovery are **never reused**: skipped tokens (_"their presence indicates the parser encountered something unexpected, and that situation may have changed due to the edit"_), missing nodes/tokens (_"synthetic artifacts of the parsing process, not representations of actual source text"_), and any node with **other diagnostics** ([`Incremental Parser.md`][roslyn-inc]). A method with a stray `#` is crumbled and reparsed even when the edit was in a _sibling_ method, because an edit elsewhere might, via lookahead, resolve the earlier error. This costs some extra reparsing, but _"parse errors tend to be rare … so this only marginally increases the parsing cost in practice."_
- **IDE-readiness.** This is the dimension Roslyn was built for and it scores at the top: a broken file always parses to a navigable tree with errors localized to missing/skipped artifacts; positions are exact; edits are `O(impact)`; and the immutable snapshot feeds IntelliSense, squiggles, and refactoring concurrently. Where [tree-sitter] delivers this for _many_ languages generically, Roslyn delivers it for C#/VB with a full semantic model behind it.

## Ecosystem & maturity

- **Origin & scope.** Roslyn is Microsoft's ground-up rewrite of the C# and VB compilers (the "compiler-as-a-service" project), open-sourced under the .NET Foundation and MIT-licensed. It ships in every Visual Studio, the .NET SDK (`csc`), Visual Studio Code / C# Dev Kit, and Rider's C# tooling; it is the reference implementation of the C# language.
- **What it powers.** The **Syntax API** and **Semantic/Workspace** layers underpin IntelliSense, refactorings, "Find all references", Edit-and-Continue, source generators, the **analyzer + code-fix** ecosystem (StyleCop, `.editorconfig`-driven analyzers, Roslyn analyzers shipped in NuGet packages), C# scripting/REPL, and LINQ-style code transformation. _"To ensure that the public Compiler APIs are sufficient for building world-class IDE features, the language services … have been rebuilt using them"_ ([`Roslyn-Overview.md`][overview]) — Roslyn eats its own API.
- **Influence.** Roslyn is where the [red/green pattern][rg-section] became mainstream engineering practice. Rust's [`rowan`][rowan] CST library (the tree under [rust-analyzer]) is an explicit port of the idea; [Lezer]'s compact tree and [tree-sitter]'s ref-counted `Subtree` are the same persistent-reuse principle from the parser-generator side. Roslyn's own incremental-parser notes cite Neal Gafter's educational [`Toy-Incremental-Parser`][toy] as a companion reference for the technique.
- **Maturity & stability.** More than a decade in production, versioned with the C#/VB language and the .NET SDK, with public design docs (`docs/compilers/Design/`) and an active contributor community. It is the most battle-tested subject in this catalog's incremental cluster.

---

## Strengths

- **Immutable, thread-safe, shareable trees:** one snapshot analyzed concurrently by every IDE feature, no locks — the property most IDE architectures retrofit painfully, here foundational.
- **Near-total incremental reuse:** ~99.99% green-node reuse on typical edits; a keystroke allocates bytes, and reparse cost tracks edit _impact_, never worse than a full reparse.
- **Aggressive, invisible memory optimization:** DAG-level green sharing, a 65,536-entry cache (55% hit rate), list-size specialization (`WithTwoChildren`…), keyword/trivia pre-caching, and 75%+ of the tree needing no red allocation.
- **Full fidelity:** every byte — whitespace, comments, directives, even malformed spans — is in the tree and round-trippable, so refactorings preserve formatting exactly.
- **Compiler-as-a-service:** the parser is one layer of a queryable platform (declaration, binding, emit, workspaces, analyzers, scripting) — not a black box.
- **Hand-written parser = precise control:** bespoke error recovery, high-quality diagnostics, and the context tracking (`await`/`field`) C# genuinely needs.
- **Production-grade and reference-quality:** it _is_ the C#/VB compiler, exhaustively tested, with published internal design notes.

## Weaknesses

- **Expressions are never reused:** giant expressions (million-element array initializers, massive interpolated strings) get only token reuse, causing high CPU/memory churn on edit — an explicit design trade-off, not a bug.
- **Conservative recovery widens reparse:** a node with skipped/missing tokens or diagnostics is reparsed even when the edit was in a sibling, so error-dense files reuse little.
- **Not a general query engine:** incrementality is concentrated in the parse and in coarse immutable `Compilation`/`Solution` snapshots; fine-grained demand-driven memoization of semantics is [rust-analyzer]/[`rustc`][rustc] territory, not Roslyn's.
- **C#/VB only:** the syntax model is not a language-agnostic parser generator — you cannot point it at a new grammar the way you can [tree-sitter] or [Lezer].
- **Two-representation complexity:** the red/green split, slot-based access, list/token specialization, and blender bookkeeping are genuinely intricate — the docs exist precisely because the internals are non-obvious.
- **Certain pathologies degrade it:** deeply nested brace-less constructs, files opened as C# that aren't, and (notably) Razor's regenerate-every-keystroke model, which _"are fully reparsed each time rather than incrementally parsed."_

## Key design decisions and trade-offs

| Decision                                                             | Rationale                                                                                                         | Trade-off                                                                                        |
| -------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| **Red/green split** (immutable green core + lazy red wrappers)       | Reconcile immutability/sharing with the `Span`/`Parent` API users need — positions/parents computed on demand     | Two representations to reason about; red-node caching + identity rules add implementation weight |
| **Position-free, parent-free green nodes**                           | Nodes become shareable across positions/parents → cross-tree + intra-tree reuse (a DAG, ~99.99% incremental)      | Absolute positions and parents must be recomputed lazily on the red side                         |
| **Everything is a heap object at green level** (no green structs)    | Structs can't be shared by reference; objects enable specialization/inheritance and the caches                    | More green allocations up front — repaid by caching, sharing, and lazy red creation              |
| **Green-node cache** (≤3 children, 65,536 entries)                   | Turn theoretical shareability into _actual_ shared instances; 55% hit rate parsing Roslyn itself                  | Bounded to small nodes to avoid combinatorial explosion; a fixed-size cache with misses          |
| **List specialization** (`null`/singleton/`WithTwoChildren`/array)   | 90%+ of lists have ≤4 elements — avoid array allocation + indirection for the common case                         | A family of specialized subclasses; a uniform red `SyntaxList<T>` must paper over all forms      |
| **Hand-written recursive descent** (not a generated LR table)        | Precise error recovery, high-quality diagnostics, context tracking (`await`/`field`), full control                | No declarative grammar; the parser is large hand code; precedence lives in the parser            |
| **Incremental reuse only at member/statement boundaries**            | These points are lookahead-safe and are the natural large-reuse units                                             | Expressions are always reparsed — pathological for giant expressions                             |
| **Never reuse skipped/missing/diagnostic/context-mismatched nodes**  | Correctness: an edit may, via lookahead/context, change how a previously-broken or flag-sensitive region parses   | Extra reparsing near errors and context-sensitive tokens; conservative over minimal              |
| **Full-fidelity trees** (every byte, round-trippable)                | Formatting-preserving refactoring; nodes act as an exact proxy for source, enabling precise incremental reasoning | Bigger trees than an AST; trivia bookkeeping on every token                                      |
| **Immutable snapshots, no mutation API** (`WithXxx`/`SyntaxFactory`) | Thread-safe concurrent analysis; structural sharing makes "edit" a spine allocation                               | "Modifying" always allocates a new spine; no general memoized-query reuse above the parse        |

---

## Sources

- [`docs/compilers/Design/Red-Green Trees.md` — the green/red split, DAG sharing, green-node cache (65,536 / 55%), list & token specialization, 75%/90% figures, full fidelity][roslyn-rg]
- [`docs/compilers/Design/Incremental Parser.md` — the blender, crumbling, `_changeDelta`, strategic reuse points, "expressions are always reparsed", 99.99%/microseconds, correctness constraints][roslyn-inc]
- [`docs/compilers/Design/Bound Node Design.md` — the bound (semantic) tree's design principles][bound]
- [`docs/wiki/Roslyn-Overview.md` — compiler-as-a-service mission, pipeline/API layers, full-fidelity & immutability, missing/skipped-token recovery][overview]
- [`docs/wiki/Getting-Started-C#-Syntax-Analysis.md` — the public Syntax API (`SyntaxTree`/`SyntaxNode`/`SyntaxToken`/`SyntaxTrivia`), `ParseText`][syntax-analysis]
- [`License.txt` — MIT, © .NET Foundation and Contributors][repo]
- [learn.microsoft.com — _Work with syntax_ (official public syntax-model docs)][work-with-syntax]
- [Neal Gafter, `Toy-Incremental-Parser` — the educational reference the incremental-parser notes cite][toy]
- Related deep-dives: [incremental & query-based parsing theory][incremental] · [tree-sitter] · [rust-analyzer] · [Lezer][lezer] · [`rustc` queries][rustc] · [top-down/recursive descent][top-down] · [the comparison][comparison]

<!-- References -->

[repo]: https://github.com/dotnet/roslyn
[roslyn-rg]: https://github.com/dotnet/roslyn/blob/main/docs/compilers/Design/Red-Green%20Trees.md
[roslyn-inc]: https://github.com/dotnet/roslyn/blob/main/docs/compilers/Design/Incremental%20Parser.md
[bound]: https://github.com/dotnet/roslyn/blob/main/docs/compilers/Design/Bound%20Node%20Design.md
[overview]: https://github.com/dotnet/roslyn/blob/main/docs/wiki/Roslyn-Overview.md
[syntax-analysis]: https://github.com/dotnet/roslyn/blob/main/docs/wiki/Getting-Started-C%23-Syntax-Analysis.md
[work-with-syntax]: https://learn.microsoft.com/en-us/dotnet/csharp/roslyn-sdk/work-with-syntax
[toy]: https://github.com/gafter/Toy-Incremental-Parser/blob/main/README.md
[rowan]: https://github.com/rust-analyzer/rowan
[incremental]: ./theory/incremental.md
[rg-section]: ./theory/incremental.md#persistent--red-green-trees-making-reuse-cheap
[bottom-up]: ./theory/bottom-up.md
[top-down]: ./theory/top-down.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[umbrella]: ./index.md
[tree-sitter]: ./tree-sitter.md
[rust-analyzer]: ./rust-analyzer.md
[salsa]: ./rust-analyzer.md#salsa-the-query-engine
[lezer]: ./lezer.md
[rustc]: ./rustc-queries.md
[bison]: ./bison-yacc.md
