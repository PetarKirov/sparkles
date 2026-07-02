# rust-analyzer (Rust)

The query-based LSP server and compiler front-end for Rust — a **lossless red-green
[CST][concepts]** ([rowan][rowan-repo]) sitting _inside_ a graph of **memoized,
demand-driven queries** ([salsa][salsa-readme]), so that typing a character re-derives
only the analyses that character actually invalidated. It is the reference design in
[this survey][umbrella] for a [query-based][incremental] compiler front-end, and the
system [salsa][salsa-readme] was extracted from.

| Field                     | Value                                                                                                                                                                                       |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language                  | Rust (a ~40-crate workspace under `crates/`)                                                                                                                                                |
| License                   | `MIT OR Apache-2.0` (dual)                                                                                                                                                                  |
| Repository                | [`rust-lang/rust-analyzer`][repo]                                                                                                                                                           |
| Documentation             | [rust-analyzer book — `dev/architecture.md`][arch] · [`dev/syntax.md`][syntax]                                                                                                              |
| Key authors               | Aleksey Kladov (**matklad**, creator), Lukas Wirth (**Veykril**), and a large contributor community                                                                                         |
| Category                  | Incremental / IDE-grade compiler front-end (**query-based**)                                                                                                                                |
| Algorithm / grammar class | Hand-written **recursive-descent + [Pratt][top-down]**, emitting a flat event stream that builds a **lossless red-green CST** via [rowan][rowan-repo]                                       |
| Lexing model              | **Separate lexer** (`rustc_lexer`-derived `LexedStr`); the `parser` crate itself contains _no lexer_ — it consumes an abstract token `Input`                                                |
| Output                    | **Lossless** red-green CST (`GreenNode` core + `SyntaxNode` cursors) with a generated typed `ast` layer on top                                                                              |
| Incrementality model      | **Two layers:** a rarely-used heuristic single-`{}`-block reparse of the tree, and a [salsa][salsa-readme] **memoized query graph** with durability firewalls + revision-based cancellation |
| Latest release            | Rolling **weekly** releases; shipped as a `rustup` component and bundled by the official VS Code extension (unversioned, `< 1.0`)                                                           |

> [!NOTE]
> This deep-dive surveys **rust-analyzer** together with the two libraries it is built
> on and gave rise to: [rowan][rowan-repo] (the lossless-CST library) and
> [salsa][salsa-readme] (the incremental query engine, extracted from rust-analyzer).
> The `rustc` on-disk query system — the same idea inside the batch compiler — is a
> [separate deep-dive][rustc]; the shared theory is on the [incremental page][incremental].

---

## Overview

### What it solves

A batch compiler parses each file once and runs its passes front-to-back. An IDE cannot:
the file is edited on every keystroke, is usually syntactically broken mid-edit, and
_every_ downstream feature — highlighting, completion, diagnostics, go-to-definition —
re-derives from the parse on each change. rust-analyzer is architected around that
[editor contract][incremental] end-to-end. From the architecture doc ([`dev/architecture.md`][arch]):

> _"On the highest level, rust-analyzer is a thing which accepts input source code from
> the client and produces a structured semantic model of the code. … The client can submit
> a small delta of input data (typically, a change to a single file) and get a fresh code
> model which accounts for changes. **The underlying engine makes sure that model is
> computed lazily (on-demand) and can be quickly updated for small modifications.**"_

Two mechanisms deliver that, and they are the whole story of the page: a **lossless,
persistent syntax tree** (so a re-parse can _share_ unchanged structure) and a **query
graph** (so an analysis re-runs only when an input it actually read has changed). The
first is [rowan][rowan-repo]; the second is [salsa][salsa-readme].

### Design philosophy

Three convictions, stated as **Architecture Invariants** in [`dev/architecture.md`][arch]
and visible throughout the crates, shape the system:

1. **Syntax is separate from, and independent of, semantics.** The `syntax` crate _"is
   completely independent from the rest of rust-analyzer. It knows nothing about salsa or
   LSP"_ ([`dev/architecture.md`][arch]). It is a **value type**: _"The tree is fully
   determined by the contents of its syntax nodes, it doesn't need global context (like an
   interner) and doesn't store semantic info."_ You can build useful tooling from the tree
   alone, without being able to _compile_ the code — which is exactly what makes an IDE
   robust to broken projects.

2. **Everything past the syntax tree is a query.** _"We use the salsa crate for
   incremental and on-demand computation. Roughly, you can think of salsa as a key-value
   store, but it can also compute derived values using specified functions"_
   ([`dev/architecture.md`][arch]). Name resolution, macro expansion, and type inference
   are all salsa queries over a base of **input** facts — _"everything else is strictly
   derived from those inputs."_

3. **Incrementality is a maintained invariant, not an afterthought.** The compiler crates
   _"explicitly care about being incremental. The core invariant we maintain is 'typing
   inside a function's body never invalidates global derived data'"_
   ([`dev/architecture.md`][arch]). An `ItemTree` deliberately _"condenses a single
   `SyntaxTree` into a 'summary' data structure, which is stable over modifications to
   function bodies"_ — a firewall so that editing one function body cannot cascade into
   re-checking the whole crate.

rust-analyzer's lineage is the query-based-compiler idea from **`rustc`'s** own query
system (see the [`rustc` deep-dive][rustc]) generalized into a reusable engine, plus the
red-green tree from **Roslyn** (see the [Roslyn deep-dive][roslyn]). Within [this
survey][umbrella] it is the canonical **full-stack** [incremental][incremental] data
point — the only catalogued system that is _both_ an incremental parser _and_ an
incremental-computation engine — contrasted with the parse-only incrementalists
([tree-sitter], [Lezer][lezer]) and the batch generators.

---

## How it works

### The syntax layers: green core, red cursors, typed AST

The tree is three layers, of which **only the bottom one holds data**. From
[`dev/syntax.md`][syntax]:

> _"The syntax tree consists of three layers: GreenNodes, SyntaxNodes (aka RedNode), AST.
> Of these, only GreenNodes store the actual data, the other two layers are (non-trivial)
> views into green tree. Red-green terminology comes from Roslyn and gives the name to the
> `rowan` library."_

| Layer            | Type ([rowan][rowan-repo] / `syntax`)   | Role                                                                                    |
| ---------------- | --------------------------------------- | --------------------------------------------------------------------------------------- |
| **Green** (data) | `GreenNode` / `GreenToken` (rowan)      | Immutable, position-free, parent-free; stores `SyntaxKind` + text-length + children     |
| **Red** (cursor) | `SyntaxNode` / `SyntaxToken` (rowan)    | A lazy cursor adding parent pointers + absolute offsets + identity (a [zipper][syntax]) |
| **AST** (typed)  | `FnDef`, `BlockExpr`, … (`syntax::ast`) | Generated newtypes over `SyntaxNode` giving a strongly-typed, all-fields-`Option` API   |

The **green node** is a purely-functional n-ary tree — conceptually `{ kind: SyntaxKind,
text_len, children: Vec<Arc<Node|Token>> }` — that stores _"only their syntactic kind,
their width (character count), and their children,"_ never absolute positions or parent
pointers ([Roslyn's red-green pattern][roslyn], ported by rowan). Because green nodes are
position-free, they are **freely shareable**, and rowan interns them so identical subtrees
are stored once. The interner's invariant, verbatim from [`src/green/node_cache.rs`][rowan-cache]:

> _"if the tree is interned, then all of its children are interned as well … we just *know*
> hashes of children, and we can re-use those."_

So in `1 + 1` there is _"a single token for `1` with ref count 2,"_ and in `(1 + 1) * (1 +
1)` the interior `1 + 1` node is shared too ([`dev/syntax.md`][syntax]) — the green level
is a **DAG, not a tree**, which is what makes keeping many versions cheap.

The **red node** (`SyntaxNode`) is the API users hold: it wraps a green node with an
absolute `offset` and a `parent` link, computed **lazily on traversal**. rust-analyzer's
red layer is a _cursor_, not a memoized node — _"cursors generally retain only a path to
the root,"_ which _"more than doubles the memory requirements"_ is the cost the memoized
(Roslyn/Swift) design pays and rowan avoids ([`dev/syntax.md`][syntax]). To keep traversal
allocation-free, rowan uses a thread-local free-list of red nodes, so a walk is _"TLS + rc
bump"_ rather than a `malloc` per step.

The **AST layer** reifies each `SyntaxKind` as a typed wrapper (`FnDef { syntax:
SyntaxNode }`) whose accessors linearly scan children for the right kind. Crucially, _"All
'fields' are optional, to accommodate incomplete and/or erroneous source code"_
([`dev/syntax.md`][syntax]) — an AST method returning `Option` _can_ be `None` even where
the grammar forbids it, because the tree is _"by design incomplete"_ and never enforces
well-formedness.

### Parsing: hand-written recursive-descent, tree-agnostic events

rust-analyzer does **not** use a parser generator. From [`dev/architecture.md`][arch], the
`parser` crate _"is a hand-written recursive descent parser, which produces a sequence of
events like 'start node X', 'finish node Y'."_ The algorithm, per [`dev/syntax.md`][syntax]:

> _"We use a boring hand-crafted recursive descent + pratt combination, with a special
> effort of continuing the parsing if an error is detected."_

The [Pratt][top-down] component handles expression precedence; the recursive descent
handles the rest. Two invariants make the parser reusable and resilient:

- **Tree- and token-agnostic.** _"the parser is independent of the particular tree
  structure and particular representation of the tokens. It transforms one flat stream of
  events into another flat stream of events"_ ([`dev/architecture.md`][arch]). The parser
  crate _"does not contain a lexer"_ ([`crates/parser/src/lib.rs`][parser-lib]) — it
  consumes an abstract token `Input`. A separate `LexedStr` (built on `rustc_lexer`) does
  lexing, and a glue layer feeds tokens in and drives a builder that emits the green tree.
  Token-independence is what lets the _same_ parser parse both source text and macro token
  trees.
- **Parsing never fails.** _"parsing never fails, the parser produces `(T, Vec<Error>)`
  rather than `Result<T, Error>`"_ ([`dev/architecture.md`][arch]). Errors are collected
  in a side vector, **not** stored in the tree; a missing mandatory node is simply absent,
  and stray input is wrapped in an `ERROR` node ([`dev/syntax.md`][syntax]).

---

## salsa: the query engine

Everything above the syntax tree is a [salsa][salsa-readme] query. salsa — _"a generic
framework for on-demand, incrementalized computation"_ ([`README.md`][salsa-readme]) — was
extracted _from_ rust-analyzer into a standalone crate, and it credits _"adapton, glimmer,
and rustc's query system"_ as its ancestors ([`README.md`][salsa-readme]; the
[`rustc`][rustc] and [Adapton][incremental] lineage is on the [theory page][incremental]).

### Inputs vs. derived queries

> _"The key idea of `salsa` is that you define your program as a set of **queries**. Every
> query is used like function `K -> V` … Queries come in two basic varieties:
> **Inputs**: the base inputs to your system. You can change these whenever you like.
> **Functions**: pure functions (no side effects) that transform your inputs into other
> values. The results of queries are memoized to avoid recomputing them a lot. When you
> make changes to the inputs, we'll figure out … when we can re-use these memoized values
> and when we have to recompute them."_ — [salsa `README.md`][salsa-readme]

In rust-analyzer the **inputs** are the file texts, the source roots, and the crate graph;
these are the _ground state_ the engine _"keeps … in memory and never does any IO"_
([`dev/architecture.md`][arch]). Everything else — the `ItemTree`, `DefMap`, type
inference — is a **derived function query**. Concretely, `base-db` declares the inputs with
salsa macros (`#[salsa::input]`, `#[salsa::interned]`, `#[salsa::tracked]`), and the
compiler crates read them:

```rust
// crates/base-db/src/lib.rs (abridged) — the base inputs are salsa inputs
#[salsa::input(singleton, debug)]
pub struct FileText { … }          // the text of one file — the thing you edit
// … derived queries (#[salsa::tracked]) read these and are memoized
```

### No passes, just queries — lazy and on-demand

There is no pass pipeline that walks the program top-to-bottom. A high-level request
(_"what is the type at this cursor?"_) **demands** the queries it needs, which demand
theirs, "further and further back until we wind up doing the actual parsing" (the
[`rustc` model][rustc-query] salsa generalizes). Work not asked for is never done; a query
touched for the first time computes and memoizes, and thereafter _"the result is returned
from a hashtable"_ ([rustc-dev-guide `query.md`][rustc-query]). The `hir` façade is
therefore _"a static, fully resolved view of the code"_ that _"from the outside, looks
like an inert data structure"_ ([`dev/architecture.md`][arch]), even though every field
access may be lazily driving a query.

### Cycle handling

Queries can form cycles (mutually-recursive types, for instance). salsa's default is
strict: _"if we encounter a cycle … we panic"_ ([`src/cycle.rs`][salsa-cycle]). A query may
_opt in_ to **fixpoint iteration** by setting `cycle_fn` + `cycle_initial`: the "cycle
head" seeds an initial value, participants compute **provisional** values tagged with their
cycle heads, and the head re-iterates _"until it converges"_ (bounded by `MAX_ITERATIONS =
200`). This keeps a cyclic dependency from bringing the whole engine down.

---

## Algorithm & grammar class

- **Formalism.** A **hand-written recursive-descent parser with a [Pratt][top-down]
  expression sub-parser** — not a generated table. It accepts the Rust grammar (informally
  specified; the `ungrammar` file drives `ast`/`SyntaxKind` codegen, not the parser logic).
  There is no [LR/LALR][bottom-up] table and no [GLR][general-parsing] forking; ambiguity is
  resolved by hand-coded lookahead and precedence, as in any recursive-descent front-end.
- **Grammar class.** Effectively whatever the hand-written parser accepts — Rust, including
  its context-sensitive corners (e.g. `<` as generics vs. less-than, disambiguated with
  lookahead and contextual keywords). The trade-off vs. a generator is the usual one:
  maximal control over error recovery and no grammar-class straitjacket, at the cost of the
  grammar living in code rather than a declarative file.
- **Lexing class.** A **separate** lexer (`LexedStr`, on `rustc_lexer`) tokenizes text;
  the parser is lexer-free and token-representation-agnostic, so it runs equally over source
  tokens and trivia-free macro token trees ([`dev/architecture.md`][arch]). Tokens can be
  _glued_ by the parser (two `>` → `>>`) via the event/`TreeSink` layer.
- **Output class.** A **lossless [CST][concepts]** (rowan) — every byte, including
  whitespace and comments, is present, so the source round-trips and every node maps to an
  exact `TextRange`. This is the same output class as [tree-sitter], [Lezer][lezer], and
  [Roslyn][roslyn]; the tree shape differs (rowan interns green nodes into a DAG; cursors,
  not memoized red nodes).

## Interface & composition model

- **Consumer API surface.** The public boundary is the `ide` crate — _"POD types with
  public fields … it talks about offsets and string labels rather than … definitions or
  types"_ ([`dev/architecture.md`][arch]). `AnalysisHost` holds the mutable salsa database;
  `Analysis` is an _immutable snapshot_ you query; edits arrive as a transactional
  `apply_change`. The LSP server crate is the only one that knows about LSP/JSON.
- **Grammar expression.** In **hand-written Rust code** (`crates/parser/src/grammar/`), not
  a DSL — the opposite end of the spectrum from [tree-sitter]'s `grammar.js` or a
  [`bison`][bottom-up] `.y`. The only generated artifact on the syntax side is the typed
  `ast` layer, produced from an `ungrammar` description.
- **CST construction.** **Top-down by the recursive-descent walk**, emitting `start_node` /
  `token` / `finish_node` events that a `GreenNodeBuilder` turns into interned green nodes
  bottom-up. Whitespace/comments are _not_ seen by the parser; they are re-attached to the
  tree by the builder/`TreeSink` layer ([`dev/syntax.md`][syntax]).
- **Composition across files & macros.** Each syntax tree is built for **one file**
  (_"to enable parallel parsing of all files"_, [`dev/architecture.md`][arch]); cross-file
  structure lives in the salsa graph (the `CrateGraph` input + `DefMap` queries), not in the
  trees. Macro expansion is modelled as token-tree → token-tree transforms (`mbe`/`tt`
  crates) that feed back into the same parser, with a token-identity mapping preserved for
  hygiene ([`dev/syntax.md`][syntax]).

## Incrementality model

This is the extra dimension that sets the [incremental / query-based][incremental] cluster
apart, and rust-analyzer implements it at **two independent granularities**:

- **Tree granularity (subtree reuse) — present but secondary.** rowan green trees are
  cheap to patch, and rust-analyzer has a heuristic incremental reparse: _"we try to contain
  a change to a single `{}` block, and reparse only this block,"_ upheld by the invariant
  that _"even for invalid code, curly braces are always paired correctly"_
  ([`dev/syntax.md`][syntax]). Notably, the authors judge this **not** to be the important
  lever:

  > _"In practice, incremental reparsing doesn't actually matter much for IDE use-cases,
  > parsing from scratch seems to be fast enough."_ — [`dev/syntax.md`][syntax]

  This is the sharpest contrast with [tree-sitter]/[Lezer][lezer], whose entire value is
  subtree-level incremental _parsing_. rust-analyzer instead banks incrementality one level
  up, in the query graph.

- **Query granularity (computation reuse) — the primary lever.** On an edit, salsa bumps a
  global **revision** counter and, for each memoized query, decides whether any input it read
  actually changed — re-executing only if so. Three refinements make that cheap:
  - **Durability firewalls.** Each input carries a [durability][salsa-durability] tier so
    stable regions are never revalidated against a hot edit: _"if we know that the only
    changes were to inputs of low durability (the common case), and we know that the query
    only used inputs of medium durability or higher, then we can skip that enumeration"_
    ([salsa `src/durability.rs`][salsa-durability]; inputs default `LOW`, interned values
    `NEVER_CHANGE`). rust-analyzer sets these deliberately — in [`base-db/src/change.rs`][change]
    a **library** file's text is `Durability::HIGH` and its source root `MEDIUM`, while
    **workspace** files are `LOW`:

    ```rust
    // crates/base-db/src/change.rs — durability tiers set the firewall
    fn source_root_durability(sr: &SourceRoot) -> Durability {
        if sr.is_library { Durability::MEDIUM } else { Durability::LOW }
    }
    fn file_text_durability(sr: &SourceRoot) -> Durability {
        if sr.is_library { Durability::HIGH } else { Durability::LOW }
    }
    ```

    So editing your own file (`LOW`) proves the entire `std`/dependency half of the graph
    stale-free **without traversing it** — the durability firewall in action.

  - **The body-vs-signature firewall.** The `ItemTree` summary is _"stable over
    modifications to function bodies"_ ([`dev/architecture.md`][arch]), so _"typing inside a
    function's body never invalidates global derived data"_ — the invalidation of a keystroke
    is contained to that one body's queries, not the crate.
  - **Cancellation on the next keystroke.** Because the user may type again before the last
    analysis finishes, an in-flight query must abort. salsa models this as a thrown
    `Cancelled`, whose variants include `PendingWrite` — _"The query was operating on
    revision R, but there is a pending write to move to revision R+1"_
    ([salsa `src/cancelled.rs`][salsa-cancelled]) — alongside `Local` and `PropagatedPanic`.
    rust-analyzer relies on unwinding for this: _"When applying a change, salsa bumps this
    counter and waits until all other threads using salsa finish. If a thread … notices that
    the counter is incremented, it panics with a special value … rust-analyzer requires
    unwinding,"_ and the `ide` crate catches it, turning it into a `Result<T, Cancelled>`
    ([`dev/architecture.md`][arch]).

## Performance

- **Latency scales with the edit, not the file.** A keystroke bumps the revision, cancels
  stale work, and re-runs only the queries whose inputs changed — for a body edit, just that
  body's queries (the [firewall](#incrementality-model) above). This is what makes
  completion/highlighting feel instant on multi-million-line workspaces. The parse itself is
  fast enough _from scratch_ that tree-level incremental parsing is deliberately underused
  ([`dev/syntax.md`][syntax]).
- **Structural sharing bounds memory.** rowan interns green nodes into a DAG, so identical
  subtrees (and identical whitespace/keyword tokens) are stored once; successive tree
  versions share their unchanged core. rust-analyzer pushes this further by treating trees as
  _"semi-transient"_ — it often stores only a `(FileId, Range)` and **re-parses on demand**
  rather than holding every file's tree in memory ([`dev/syntax.md`][syntax]).
- **Allocation behaviour.** Green construction allocates each `GreenNode` as a single
  `DST` (header + children in one allocation) and interns it; red-node traversal is
  allocation-free via a thread-local free list (_"TLS + rc bump"_); the salsa graph memoizes
  query outputs in per-query hash tables. The dominant cost is memory for the query graph and
  memo tables, traded for near-zero recompute.
- **Parallelism.** Syntax trees are per-file _"to enable parallel parsing of all files"_
  ([`dev/architecture.md`][arch]); the LSP main loop handles state-mutating/latency-critical
  requests on the main thread and dispatches the rest to a background pool. There is **no
  SIMD/data-parallel** parsing — like [tree-sitter], the win is _temporal_ (reuse across
  edits), not _spatial_ over the bytes (contrast [simdjson][comparison]).

## Error handling & recovery

- **Resilience is a design goal, not a mode.** From [`dev/syntax.md`][syntax]: parsing is
  _"lossless (even if the input is invalid, the tree produced by the parser represents it
  exactly)"_ and _"resilient (even if the input is invalid, parser tries to see as much
  syntax tree fragments in the input as it can)."_ The recursive-descent code makes _"a
  special effort of continuing the parsing if an error is detected."_
- **Error representation.** Broken input is localized structurally: _"If mandatory (grammar
  wise) node is missing from the input, it's just missing from the tree. If an extra
  erroneous input is present, it is wrapped into a node with `ERROR` kind, and treated just
  like any other node"_ ([`dev/syntax.md`][syntax]). The AST layer absorbs the rest by making
  **every field `Option`** — a half-typed `fn` still yields an `FnDef`, just with `None`
  where the body isn't there yet.
- **Errors live beside the tree, not in it.** _"Syntax errors are not stored directly in
  the tree … parser reports errors to an error sink, which stores them in a `Vec`"_
  ([`dev/syntax.md`][syntax]) — the `(T, Vec<Error>)` contract — because a tree may also be
  _assembled by refactorings_, not only produced by the parser. Some checks are deferred to a
  separate validation pass over the finished tree.
- **The whole engine is failure-tolerant.** Beyond syntax, _"various analysis compute `(T,
Vec<Error>)` rather than `Result<T, Error>`"_, each LSP request is wrapped in
  `catch_unwind`, and the server _"should be partially available even when the build is
  broken"_ ([`dev/architecture.md`][arch]). This is the IDE-readiness bar: a broken file
  never blanks out the features that don't depend on the broken part.

## Ecosystem & maturity

- **Origin.** Started by **Aleksey Kladov** (matklad) in 2018 as a from-scratch,
  IDE-first Rust front-end (the successor to the earlier "libsyntax2"/RLS-era efforts), and
  developed under the rust-lang org. Its "Explaining Rust Analyzer" video series and the
  `rust-analyzer.github.io/blog` posts (e.g. _"Three Architectures for a Responsive IDE"_,
  _"Challenging LR Parsing"_) document the design ([`dev/architecture.md`][arch]).
- **Adoption.** The de-facto Rust language server: shipped as a `rustup` component, bundled
  by the official `rust-lang.rust-analyzer` VS Code extension, and integrated by every major
  editor via LSP. Effectively every Rust developer runs it.
- **Spun-out libraries.** [rowan][rowan-repo] (lossless red-green CST) and
  [salsa][salsa-readme] (incremental query engine) are both published crates extracted from
  this work and reused far beyond Rust tooling; `ungrammar` (grammar → AST codegen) likewise.
  salsa is deliberately pre-`1.0` and undergoing an active rewrite (the "salsa 3.x" macro API
  — `#[salsa::input]` / `tracked` / `interned` — is what `base-db` uses today).
- **Stability posture.** rust-analyzer minimizes new stability guarantees, leaning on the
  stable LSP and Rust-language surfaces instead; the `ide` API is _explicitly unstable_, and
  `rowan` is _"deliberately kept under `1.0`"_ making semver-incompatible upgrades freely
  ([`dev/architecture.md`][arch]). Releases are **weekly and unversioned**.
- **Reach.** Beyond Rust, its architecture is the widely-cited template for query-based IDE
  back-ends, and salsa/rowan are borrowed by other language tools building the same
  red-green-tree-inside-a-query-graph stack.

---

## Strengths

- **Full-stack incrementality:** the only catalogued system that is _both_ an incremental
  parser (rowan structural sharing) _and_ an incremental-computation engine (salsa) — one
  memoization/invalidation mechanism serves parse, name-resolution, types, and diagnostics.
- **IDE-grade resilience:** parsing never fails, broken input is localized to `ERROR`/missing
  nodes, every AST field is `Option`, and the server stays partially available on a broken
  build.
- **Lossless & position-exact:** the rowan CST preserves every byte; each node maps to an
  exact `TextRange`, and the source round-trips.
- **Cheap history via structural sharing:** interned green nodes form a DAG; identical
  subtrees/tokens are stored once and shared across versions and files (~free "modify").
- **Durability firewalls give real isolation:** editing a workspace file proves the entire
  library/dependency half of the graph stale-free without traversal.
- **Reusable, battle-tested foundations:** rowan and salsa are extracted, published, and
  reused far beyond rust-analyzer — the design has been validated by adoption.
- **Hand-written parser = maximal control:** error recovery and context-sensitive
  disambiguation are coded directly, unconstrained by a grammar class.

## Weaknesses

- **Heavy memory / bookkeeping:** persistent trees plus a query graph with per-query memo
  tables cost far more memory than a throwaway AST; every query read must be recorded. Pure
  overhead for a one-shot batch parse.
- **Implementation complexity:** red-green invariants, salsa's revision/durability/cycle
  machinery, and unwinding-based cancellation are genuinely hard — orders of magnitude more
  than a plain [recursive-descent][top-down] parser.
- **Everything must be a pure query:** the salsa model forces side-effect-free `K → V`
  functions and cheap-clone return values; escaping that (e.g. non-deterministic proc-macros)
  needs special handling out-of-process.
- **Tree-level incremental parsing is underdeveloped** — deliberately, since "parse from
  scratch is fast enough" — so rust-analyzer is _not_ the reference for incremental _parsing_
  (that's [tree-sitter]/[Lezer][lezer]); its incrementality lives in the query graph.
- **Rust-specific:** unlike [tree-sitter]'s general grammar substrate, the whole stack
  targets one language; the reusable pieces are rowan and salsa, not the parser.
- **Durability tiers are a hand-set hint:** wrong tiers cause either stale results or wasted
  revalidation; correctness depends on the author classifying inputs correctly.

## Key design decisions and trade-offs

| Decision                                                                 | Rationale                                                                                           | Trade-off                                                                                          |
| ------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| **Red-green CST via [rowan][rowan-repo]** (green DAG + lazy red cursors) | Position-free green nodes are shareable → structural sharing across edits/files; lossless & exact   | Bigger than an AST; positions/parents recomputed lazily on the red side; complex invariants        |
| **Cursors, not memoized red nodes**                                      | Retain only a path-to-root; avoid _"more than doubles the memory"_ of realized red trees            | Traversal recomputes offsets/parents (mitigated by TLS free-list); no pointer-identity for free    |
| **Syntax crate knows nothing of salsa/LSP** (value-type tree)            | Tooling works from syntax alone, robust to un-buildable projects; parallel per-file parsing         | Cross-file/semantic info must live elsewhere (the query graph), not on the tree                    |
| **Everything past the tree is a [salsa][salsa-readme] query**            | One uniform memoization + on-demand + invalidation mechanism for all analyses; laziness for free    | All logic must be pure `K → V`; pervasive `db` argument; heavy memo-table memory                   |
| **Durability tiers** on inputs ([firewall][change])                      | Skip revalidating stable library/std regions against a hot workspace edit                           | A hint the author must set correctly; wrong tiers ⇒ stale results or wasted work                   |
| **`ItemTree` summary stable over bodies**                                | "Typing in a body never invalidates global data" — contains a keystroke's blast radius              | An extra IR to build and maintain; another layer between syntax and semantics                      |
| **Cancellation via thrown `Cancelled` + unwinding**                      | A new keystroke instantly aborts stale in-flight analysis; server stays responsive                  | Query code must be unwind-safe/re-entrant; relies on panics as control flow                        |
| **Hand-written recursive-descent + [Pratt][top-down]** (no generator)    | Full control over error recovery and Rust's context-sensitive disambiguation; token/tree-agnostic   | Grammar lives in code, not a declarative file; more parser code to maintain by hand                |
| **Tree-level incremental reparse kept minimal**                          | "Parse from scratch is fast enough"; bank incrementality in the query graph instead                 | Not a reference incremental _parser_; a single-`{}`-block heuristic rather than true subtree reuse |
| **Parsing never fails — `(T, Vec<Error>)`, errors beside the tree**      | Always yield a usable tree (also for refactor-assembled trees); localize errors to `ERROR`/`Option` | Well-formedness is not enforced by the tree; a separate validation pass is needed                  |

---

## Sources

- [`rust-lang/rust-analyzer` — GitHub repository][repo]
- [`docs/book/src/contributing/architecture.md` — bird's-eye view, crate map, Architecture Invariants, salsa/base-db, cancellation, error handling][arch]
- [`docs/book/src/contributing/syntax.md` — red/green/AST layers, green-node interning, cursors, recursive-descent + Pratt, incremental reparse heuristic, error representation][syntax]
- [`crates/parser/src/lib.rs` — the tree-/token-agnostic, lexer-free parser crate][parser-lib]
- [`crates/base-db/src/change.rs` — durability tiers (`HIGH`/`MEDIUM`/`LOW`) as the invalidation firewall][change]
- [salsa `README.md` — "on-demand, incrementalized computation"; inputs vs. functions; adapton/glimmer/rustc credits][salsa-readme]
- [salsa `src/durability.rs` — durability tiers; skip revalidation of high-durability inputs][salsa-durability]
- [salsa `src/cancelled.rs` — `Cancelled` variants `Local` / `PendingWrite` / `PropagatedPanic`][salsa-cancelled]
- [salsa `src/cycle.rs` — default panic-on-cycle; opt-in fixpoint iteration; `MAX_ITERATIONS`][salsa-cycle]
- [rowan — lossless red-green CST library (the tree under rust-analyzer)][rowan-repo]
- [rowan `src/green/node_cache.rs` — the green-node interner ("all children interned as well")][rowan-cache]
- [rustc-dev-guide `query.md` — the query-based compiler model salsa generalizes][rustc-query]
- Related deep-dives: [incremental & query-based theory][incremental] · [tree-sitter] · [Roslyn][roslyn] · [Lezer][lezer] · [`rustc` queries][rustc] · [bottom-up/LR][bottom-up] · [top-down/Pratt][top-down] · [the comparison][comparison]

<!-- References -->

<!-- Theory & tree-internal -->

[incremental]: ./theory/incremental.md
[bottom-up]: ./theory/bottom-up.md
[top-down]: ./theory/top-down.md
[general-parsing]: ./theory/general-parsing.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[umbrella]: ./index.md

<!-- Sibling deep-dives -->

[tree-sitter]: ./tree-sitter.md
[roslyn]: ./roslyn.md
[lezer]: ./lezer.md
[rustc]: ./rustc-queries.md

<!-- External primary sources -->

[repo]: https://github.com/rust-lang/rust-analyzer
[arch]: https://github.com/rust-lang/rust-analyzer/blob/master/docs/book/src/contributing/architecture.md
[syntax]: https://github.com/rust-lang/rust-analyzer/blob/master/docs/book/src/contributing/syntax.md
[parser-lib]: https://github.com/rust-lang/rust-analyzer/blob/master/crates/parser/src/lib.rs
[change]: https://github.com/rust-lang/rust-analyzer/blob/master/crates/base-db/src/change.rs
[salsa-readme]: https://github.com/salsa-rs/salsa/blob/master/README.md
[salsa-durability]: https://github.com/salsa-rs/salsa/blob/master/src/durability.rs
[salsa-cancelled]: https://github.com/salsa-rs/salsa/blob/master/src/cancelled.rs
[salsa-cycle]: https://github.com/salsa-rs/salsa/blob/master/src/cycle.rs
[rowan-repo]: https://github.com/rust-analyzer/rowan
[rowan-cache]: https://github.com/rust-analyzer/rowan/blob/master/src/green/node_cache.rs
[rustc-query]: https://rustc-dev-guide.rust-lang.org/query.html
