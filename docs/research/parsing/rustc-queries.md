# rustc queries (Rust compiler)

The demand-driven, memoized **query engine** and **red-green incremental
compilation** at the heart of `rustc` — a whole-compiler architecture that inverts
the classic pass pipeline into a graph of pure `K → V` functions and, across
separate compiler runs, reuses on-disk results for everything an edit did not
actually change.

| Field                | Value                                                                                                                                            |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| System               | The `rustc` query system + on-disk incremental compilation                                                                                       |
| Language             | Rust                                                                                                                                             |
| License              | Dual **MIT / Apache-2.0** (`rust-lang/rust` and `rust-lang/rustc-dev-guide` both ship `LICENSE-MIT` + `LICENSE-APACHE`)                          |
| Repository           | [`rust-lang/rust`][repo] (compiler); guide [`rust-lang/rustc-dev-guide`][guide-repo]                                                             |
| Documentation        | [rustc-dev-guide.rust-lang.org][docs]                                                                                                            |
| Key authors          | Niko Matsakis (query/red-green design) and the `rust-lang/compiler` team; incremental via the ["Red/Green" dependency-tracking effort][redgreen] |
| Category             | Query-based compiler / incremental compilation                                                                                                   |
| Model                | **Demand-driven, memoized queries** — a top-level `compile` query pulls its inputs backward until it reaches parsing                             |
| Incrementality model | **On-disk red-green `DepGraph`** reused across compiler sessions; per-query `DepNode` granularity; `Fingerprint`-based early cutoff              |
| Granularity          | One **`DepNode`** per query invocation (query key + provider), not per token or per subtree                                                      |

> [!NOTE]
> This deep-dive is about the **production `rustc` query system** and its
> cross-session on-disk incremental compilation. The reusable-library form of the
> same idea — [salsa][salsa] and the live in-memory query graph a language server
> runs — is covered in the [rust-analyzer] deep-dive. The two are close cousins
> (`rustc`'s own query system is one of salsa's ancestors), but they differ on the
> axis that matters here: `rustc` **serializes query results to disk and reloads
> them on the next `cargo build`**, whereas rust-analyzer keeps a salsa graph
> **live in memory** across keystrokes. See [Incrementality model](#incrementality-model).

---

## Overview

### What it solves

A traditional compiler is a sequence of **passes**: lex, parse, resolve names,
type-check, borrow-check, codegen — each pass running to completion over the whole
crate before the next begins. That structure is simple but has two costs the Rust
team wanted to escape: it does no better than `O(whole crate)` when a user changes
one line and recompiles, and it forces every downstream fact to be computed
whether or not anyone asked for it.

The query system replaces the pipeline with a **demand-driven** organization. From
the [dev-guide's `query.md`][rustc-query]:

> _"Instead of entirely independent passes (parsing, type-checking, etc.), a set of
> function-like queries compute information about the input source. For example,
> there is a query called `type_of` that, given the `DefId` of some item, will
> compute the type of that item and return it to you."_ — [rustc-dev-guide `query.md`][rustc-query]

Each query is memoized, and — the payoff — its result can be **reloaded from a
previous compilation instead of recomputed**:

> _"Query execution is memoized. The first time you invoke a query, it will go do
> the computation, but the next time, the result is returned from a hashtable.
> Moreover, query execution fits nicely into incremental computation; the idea is
> roughly that, when you invoke a query, the result may be returned to you by
> loading stored data from disk."_ — [rustc-dev-guide `query.md`][rustc-query]

So the batch pipeline becomes a graph of cached functions, and a recompile after a
small edit re-runs only the queries an edit actually invalidated. This is the
[incremental / query-based][incremental] cluster of [this survey][umbrella]; within
it `rustc` is the **purest production "query-based compiler"** data point — the
computation-reuse column, as opposed to [tree-sitter]'s tree-reuse column.

### Design philosophy

The organizing idea, from the [overview][overview], is that the compiler is **not**
a series of sequential passes:

> _"The Rust compiler is not organized as a series of passes over the code which
> execute sequentially. The Rust compiler does this to make incremental compilation
> possible — that is, if the user makes a change to their program and recompiles, we
> want to do as little redundant work as possible to output the new binary."_ —
> [rustc-dev-guide `overview.md`][overview]

Three convictions follow, all visible in the dev-guide:

1. **Compilation is pull, not push.** Rather than driving passes forward, one
   top-level `compile` query **demands** what it needs, starting from the _end_ of
   compilation and working backward: _"The `compile` query might demand … the list
   of codegen-units … computing the list of codegen-units would invoke some subquery
   … That query in turn would invoke something asking for the HIR … This keeps going
   further and further back until we wind up doing the actual parsing"_
   ([`query.md`][rustc-query]). Only what is reachable from the demanded output is
   ever computed.

2. **A query must be a pure function of its key.** The whole scheme rests on two
   properties stated verbatim in [`incremental-compilation-in-detail.md`][incr-detail]:
   _"queries are pure functions — given the same inputs, a query will always yield
   the same result"_, and _"the query model structures compilation in an acyclic
   graph that makes dependencies between individual computations explicit."_ Purity
   is what makes a cached result substitutable for a recomputation; the explicit DAG
   is what makes invalidation tractable.

3. **Incrementality is an extension of the query system, not a bolted-on cache.**
   The dev-guide frames it exactly that way: the incremental scheme is _"in essence,
   a surprisingly simple extension to the overall query system"_
   ([`incremental-compilation.md`][incr-basic]). Get the query graph right and
   incrementality is (mostly) recording that graph and diffing it.

Honest scope: **parsing itself is _not_ query-driven and _not_ incremental here.**
The front-end is a hand-written recursive-descent lexer/parser, and — as of the
dev-guide's own date-check — _"lexing, parsing, name resolution, and macro expansion
are done all at once for the whole program"_ ([`overview.md`][overview]); the queries
kick in from the AST/HIR onward. So `rustc` is a query-based **compiler** whose
_parser_ is batch; contrast [tree-sitter]/[Lezer][lezer], which are incremental
_parsers_ with no query graph. See [Incrementality model](#incrementality-model).

---

## How it works

### Queries as memoized `K → V` functions

Abstractly, the compiler treats its knowledge of a crate as a lazily-filled
**database**, and a query is a question asked of it. From
[`query-evaluation-model-in-detail.md`][query-model], a query is four things:

> _"A name that identifies the query … A 'key' that specifies what we want to look
> up … A result type that specifies what kind of result it yields … A 'provider'
> which is a function that specifies how the result is to be computed if it isn't
> already present in the database."_ — [rustc-dev-guide `query-evaluation-model-in-detail.md`][query-model]

For `type_of`, the key is a `DefId`, the result is `Ty<'tcx>`, and the provider
computes the item's type. Three soundness restrictions are imposed so that a cached
result is genuinely substitutable for a fresh computation: _"The key and result must
be immutable values. The provider function must be a pure function … for the same
key it must always yield the same result. The only parameters a provider function
takes are the key and a reference to the 'query context'."_ ([`query-model`][query-model]).

Queries are invoked as methods on the **`TyCtxt`** ("type context"), the giant
interned struct at the center of the compiler; `let ty = tcx.type_of(some_def_id);`
is a full query invocation ([`query.md`][rustc-query]). Because results are cloned
out of the cache on each hit, the dev-guide warns that query result types _"should …
be cheaply cloneable; insert an `Rc` if necessary."_

### Providers: plain function tables, not traits

On a cache miss the engine calls a **provider**. Providers are not resolved through
Rust's trait machinery — they are function pointers in a macro-generated struct:

> _"A provider is a function implemented in a specific module and manually
> registered into either the `Providers` struct (for local crate queries) or the
> `ExternProviders` struct (for external crate queries) during compiler
> initialization. The macro system generates both structs, which act as function
> tables for all query implementations, where each field is a function pointer to
> the actual provider."_ — [rustc-dev-guide `query.md`][rustc-query]

The dev-guide is emphatic that these are _"**not** Rust traits, but plain structs
with function pointer fields."_ Every provider shares one signature —
`fn provider<'tcx>(tcx: TyCtxt<'tcx>, key: QUERY_KEY) -> QUERY_RESULT` — taking only
the context and the key, and returning the result.

There are **two** provider tables, split by which crate a query targets: `Providers`
for the **local crate** being compiled, `ExternProviders` for **external crates**
(dependencies), the latter mostly routed through the [`rustc_metadata`][metadata]
crate that decodes `.rmeta` files. Crucially, _"what determines the crate that a
query is targeting is not the kind of query, but the key"_ ([`query.md`][rustc-query]):
`tcx.type_of(def_id)` is a local or an external query depending only on whether
`def_id.krate == LOCAL_CRATE`. This is what lets incremental reuse cross crate
boundaries — an unchanged dependency is answered from its metadata, never recompiled.

### The dependency graph: `DepNode`s and the query DAG

Because every query-to-query access goes through `TyCtxt`, the engine can **record**
each access and build the dependency graph by instrumentation. From
[`incremental-compilation-in-detail.md`][incr-detail]:

> _"Since every access from one query to another has to go through the query context,
> we can record these accesses and thus actually build this dependency graph in
> memory. With dependency tracking enabled, when compilation is done, we know which
> queries were invoked (the nodes of the graph) and for each invocation, which other
> queries or input has gone into computing the query's result (the edges of the
> graph)."_ — [rustc-dev-guide `incremental-compilation-in-detail.md`][incr-detail]

The unit is a **`DepNode`**: one node per _query invocation_ (a query key together
with its provider), and an edge `Q1 → Q2` whenever computing `Q1` read `Q2`. Because
queries cannot depend on themselves, the result is a **DAG** (cycles are an
irrecoverable "cycle error", [`query-model`][query-model]). The graph tracks not just
_which_ queries a query read but the **order** in which it read them, because a
control-flow branch (`if subquery1() { subquery2() } else { subquery3() }`) means a
changed early input can send the re-execution down a different path
([`incremental-compilation.md`][incr-basic]).

### The red-green algorithm

Incrementality is _"a surprisingly simple extension to the overall query system"_
([`incremental-compilation.md`][incr-basic]). After each run, `rustc` saves the query
results (or their hashes) **and** the query DAG. On the next run, every `DepNode` is
assigned a **color**:

> _"If a query is colored red, that means that its result during this compilation has
> changed from the previous compilation. If a query is colored green, that means that
> its result is the same as the previous compilation."_ —
> [rustc-dev-guide `incremental-compilation.md`][incr-basic]

Two insights drive it. First, **if all of a query's inputs are green, the query must
produce the same value and need not run at all** (or the compiler would be
non-deterministic). Second — and this is what makes it _accurate_ rather than merely
correct — **even a query with a changed input may still produce an identical result**,
so after re-running it the engine compares outputs and can _still_ mark it green.
That second rule is the fix for the "false positive" problem the naïve algorithm
suffers: a change to `IntValue(x)` from `1000` to `2000` need not invalidate a
`sign_of(x)` that returns `+` either way, and interleaving change-detection with
re-evaluation stops that spurious change from propagating
([`incremental-compilation-in-detail.md`][incr-detail]).

The mechanism is **try-mark-green**, which colors a `DepNode` without necessarily
running it. Paraphrasing the dev-guide's reference pseudocode
([`incremental-compilation-in-detail.md`][incr-detail]):

- Fetch the node's dependencies (its out-edges in the _previous_ graph).
- For each dependency: if already **green**, continue; if **red**, bail — the current
  node cannot be green without re-running. If **unknown**, recurse into
  `try_mark_green` on it; if that fails, **force the query** (re-run it), which
  colors it red or green, and act on the outcome.
- If every dependency comes back green, mark the current node green — **without ever
  running its provider or loading its value**.

That last property is the whole win: _"if all of Q's inputs are green, then we can
conclude that Q must be green without re-executing it or inspecting its value at all
… this allows us to avoid deserializing the result from disk when we don't need it"_
([`incremental-compilation-in-detail.md`][incr-detail]).

### Fingerprints and early cutoff

To decide whether a _re-run_ query changed, the engine must compare the new result
to the old one — without loading the old one from disk, and without storing every
result. It uses **`Fingerprint`s**:

> _"Each time a new query result is computed, the query engine will compute a 128 bit
> hash value of the result. We call this hash value 'the `Fingerprint` of the query
> result'."_ — [rustc-dev-guide `incremental-compilation-in-detail.md`][incr-detail]

Fingerprints are stored **alongside** the dependency graph (cheap — "just bytes to be
copied"), so red-green marking compares an already-loaded previous fingerprint to the
new result's fingerprint. When they match, the re-run query is marked green and the
change **stops propagating** to its dependents — this is [**early cutoff**][incremental]
(the build-systems term), the property that makes incrementality _minimal_ rather than
merely correct. The residual risks the dev-guide names honestly: a negligible 128-bit
hash-collision chance, and that _"computing fingerprints is quite costly … the main
reason why incremental compilation can be slower than non-incremental compilation."_

### Cross-session persistence: stability and the two `DepGraph`s

`rustc` exits after each compile, so — unlike an in-memory salsa graph — its cache and
graph must survive to disk and be reloadable. Two hard problems follow
([`incremental-compilation-in-detail.md`][incr-detail]):

- **ID stability.** Numeric IDs like `DefId` are assigned from a sequential counter and
  shift when source moves (add a function mid-file and everything after renumbers). The
  on-disk cache therefore cannot store a raw `DefId`; it stores a **`DefPath`** (a
  path like `std::collections::HashMap`, unaffected by unrelated edits) or its 128-bit
  `DefPathHash`, mapping back to a current-session `DefId` on load. Fingerprints are
  computed over these _stable_ equivalents (the `StableHash` infrastructure) so that
  fingerprints from two sessions are comparable at all.
- **Two graphs at once.** A session loads the _previous_ dep-graph as immutable data,
  then builds a _new_ one. try-mark-green really operates on the **previous** graph;
  `DepNode`s are identified by a fingerprint of the query key, so a current-session key
  can locate its previous-session node. When a node is marked green, _"we copy the node
  and the edges to its dependencies from the old graph into the new graph"_ — because
  the tracking system only records edges while _running_ a query, which is exactly what
  green nodes avoid. At session end the new graph is serialized out to become the next
  session's "previous" graph.

A subtle consequence is **cache promotion**: a chain `input(A) ← intermediate(B) ←
leaf(C)` can mark `C` green and load `C`'s result while never loading `B`'s, so `B`
would be absent from the newly-written cache and have to be recomputed next time. To
prevent that, _"before emitting the new result cache it will walk all green dep-nodes
and make sure that their query result is loaded into memory"_ ([`incr-detail`][incr-detail]).

---

## Evaluation model & query class

- **Formalism.** Not a grammar formalism at all — an **incremental computation** model.
  The compiler is a lazily-materialized database of memoized pure functions whose
  invocations form a **directed acyclic graph** ([`query-model`][query-model]). Parsing
  is _outside_ this model (batch recursive descent); the query DAG spans HIR → type-check
  → borrow-check → MIR → codegen.
- **Query anatomy.** `query name(key: K) -> V { <modifiers> }`, declared in one big
  `rustc_queries!` macro invocation; the key must implement `QueryKey` (defining, e.g.,
  which crate it targets), the result must be immutable and cheaply cloneable
  ([`query.md`][rustc-query]).
- **Purity as the load-bearing constraint.** Memoization is only sound because providers
  are pure: _"Memoization is one of the main reasons why query providers have to be pure
  functions. If calling a provider function could yield different results for each
  invocation … then we could not memoize the result."_ ([`query-model`][query-model]).
- **Escape hatches, controlled.** `Steal<T>` results may be moved out of the cache once
  (a perf optimization for values too costly to clone, e.g. a function's MIR), guarded so
  a later access ICEs rather than silently reading stolen data ([`query-model`][query-model]).
  `eval_always` queries may read files/global state and are re-run unconditionally,
  sitting deliberately outside the pure-function contract ([`incr-detail`][incr-detail]).

## Interface & composition model

- **How a query is expressed.** As a macro entry, not a hand-written function table:
  authors add a line to `rustc_queries!` (name, key, result, `desc`, modifiers) and a
  provider; the macros generate the `Providers`/`ExternProviders` structs, the `TyCtxt`
  methods, and the dep-node plumbing ([`query.md`][rustc-query]).
- **Providers wired at init.** `util::Providers` is filled during compiler initialization
  from `DEFAULT_QUERY_PROVIDERS`; each `rustc_*` crate exposes a `provide` function that
  assigns its function pointers into the table ([`query.md`][rustc-query]). Providers are
  a **plain struct of `fn` pointers**, deliberately not a trait — a data-oriented dispatch
  table rather than dynamic dispatch.
- **Composition across crates.** The local/extern split _is_ the composition model: a
  query keyed on an external `DefId` is answered by `rustc_metadata` decoding that crate's
  `.rmeta`, so _"this approach avoids recompiling external crates … and enables incremental
  compilation to work across crate boundaries"_ ([`query.md`][rustc-query]). Making a query
  cross-crate is explicit work: add it to `rustc_queries!`, implement a local provider, and
  add a `provide_extern` provider with metadata encode/decode.
- **The backend is integrated, not query-fied.** LLVM codegen isn't itself written as
  queries; the compiler tracks which queries a codegen-unit reads, forms a `DepNode` for the
  CGU, and try-mark-greens it — if green, the on-disk object/bitcode files are reused; if
  not, the whole CGU is recompiled ([`incr-detail`][incr-detail]). Fingerprinting opaque C++
  LLVM modules isn't feasible, so this is a deliberate manual bridge.

## Incrementality model

This is the dimension the [siblings][incremental] are compared on, and where `rustc` sits
apart from the editor parsers.

- **Unit of reuse: a query result.** Reuse is keyed on the **`DepNode`** — one per query
  invocation. Contrast [tree-sitter]'s unit (a ref-counted `Subtree`) and [Roslyn][roslyn]'s
  (a green node): those reuse **tree** fragments; `rustc` reuses **computations**.
- **Marking: red-green with early cutoff.** try-mark-green proves a node green when all
  inputs are green (no re-run, no disk load); a re-run node is re-fingerprinted and marked
  green if its value is unchanged, cutting off propagation. Accuracy comes from interleaving
  change-detection with re-evaluation ([`incr-detail`][incr-detail]).
- **Persistence: across compiler _invocations_, on disk.** This is the defining contrast.
  tree-sitter reuses subtrees **within a live session** as the user edits; [rust-analyzer]
  keeps a **live in-memory** salsa graph across keystrokes; `rustc` **serializes the graph
  and result cache to disk** and reloads them on the _next_ `cargo build`. Its incrementality
  is between separate OS processes, which forces the whole stability apparatus (`DefPath` /
  `DefPathHash` / `StableHash` / `Fingerprint`) that an in-memory engine never needs.
- **Firewalls via the projection pattern.** A monolithic query (e.g. the indexed HIR) that
  changes on nearly any edit is shielded by small **projection queries** (`hir_owner`) that
  read one item out of it; even when the monolith goes red, most projections stay green, so
  their dependents are spared ([`incr-detail`][incr-detail]). `no_hash` + `eval_always`
  modifiers tune this: `no_hash` makes the monolith unconditionally red (skipping redundant
  hashing) while the projections _"act as a 'firewall', shielding their dependents."_
- **Parsing is _not_ incremental.** The lexer/parser/name-resolution/macro-expansion front
  end runs batch, whole-program, on every invocation ([`overview.md`][overview]). `rustc`'s
  incrementality begins at HIR. So a one-character edit still re-lexes and re-parses the
  whole crate; the savings are entirely in the _analysis and codegen_ that red-green marking
  lets it skip. Position this honestly: `rustc` is the query-based-compiler exemplar, **not**
  an incremental-parsing one.

## Performance

- **Best case.** A recompile after a small edit re-runs only the queries whose transitive
  fingerprints changed; large subgraphs are marked green in bulk without running providers or
  even deserializing their results ([`incr-detail`][incr-detail]). On real crates this turns a
  one-line change from an `O(whole crate)` analysis+codegen into work proportional to what the
  edit reached.
- **The fingerprint tax.** Incrementality is not free: _"Computing fingerprints is quite
  costly. It is the main reason why incremental compilation can be slower than non-incremental
  compilation"_ ([`incr-detail`][incr-detail]) — a good, expensive 128-bit stable hash is
  computed for every result, and inputs must be mapped to their stable forms first. A clean
  full build can be _faster_ with incremental disabled.
- **Whole-file rewrite overhead.** The engine cannot update the on-disk cache or dep-graph
  **in place**; it _"has to rewrite each file entirely in each compilation session,"_ costing
  _"a few percent of total compilation time"_ ([`incr-detail`][incr-detail]).
- **Cross-crate reuse.** Because an external-keyed query is served from `.rmeta` metadata,
  unchanged dependencies are never recompiled — the dominant real-world win on a large
  workspace where you edit one crate ([`query.md`][rustc-query]).
- **Memoization within a session.** Even non-incrementally, the in-`TyCtxt` cache means a
  query computed for one caller (`type_of(bar)` during `type_check_item(foo)`) is free for the
  next ([`query-model`][query-model]).

## Error handling & recovery

- **Not an IDE error-recovery story.** Unlike [tree-sitter] — whose defining trait is
  producing a usable tree from broken input — `rustc`'s query layer is a _batch_ compiler
  stage; syntactic error recovery lives in the (non-query) parser, and the query system's
  concern is soundness of _caching_, not tolerance of malformed source.
- **Cycles are fatal.** The query DAG must stay acyclic; the engine detects cyclic
  invocations with the same key and _"because cycles are an irrecoverable error, will abort
  execution with a 'cycle error' message"_ ([`query-model`][query-model]). An earlier "cycle
  recovery" facility was **removed** because its interaction with incremental compilation was
  unclear — a deliberate simplification.
- **Correctness guards around the escape hatches.** The unsound-looking optimizations are
  fenced: a stolen `Steal<T>` result ICEs on later access rather than returning garbage
  ([`query-model`][query-model]); a `no_hash` node is _conservatively_ assumed changed so
  nothing silently reuses a stale value ([`incr-detail`][incr-detail]); and try-mark-green
  visits reads **in original order** so a changed branch condition can't reuse a query from a
  no-longer-taken path ([`incremental-compilation.md`][incr-basic]).
- **Determinism as the safety net.** The entire scheme is only sound because providers are
  pure and deterministic; a hash collision (128-bit, negligible) is the sole acknowledged way
  a changed result could be mistaken for unchanged ([`incr-detail`][incr-detail]).

## Ecosystem & maturity

- **Origin.** The query system was **retrofitted** into a compiler originally built as
  sequential passes; the transition is ongoing ([`query.md`][rustc-query], [`overview.md`][overview]).
  The incremental design traces to Niko Matsakis's [on-demand / incremental design
  doc][design-doc] and the long-running ["Red/Green" dependency-tracking issue][redgreen]; a
  footnote in the dev-guide records that the red-green algorithm was almost named "the Salsa
  algorithm" (_"I have long wanted to rename it to the Salsa algorithm, but it never caught on.
  —@nikomatsakis"_, [`incremental-compilation.md`][incr-basic]).
- **Reach.** It is the compilation engine every stable Rust toolchain ships; incremental
  compilation has been the default for debug builds since the [2016 announcement][announce] and
  its subsequent stabilization. As of the dev-guide's date-checks, the query-fied region spans
  **HIR → LLVM-IR**; lexing, parsing, name resolution, and macro expansion remain whole-program
  batch stages ([`overview.md`][overview]).
- **Relationship to salsa.** [salsa][salsa] generalized these ideas into a reusable library and
  cites `rustc`'s query system among its ancestors; it powers [chalk] and [rust-analyzer], but —
  per the dev-guide's own note — _"it is not used directly in rustc"_ and there are _"no medium
  or long-term concrete plans to integrate it into the compiler"_ ([`salsa.md`][salsa-doc]). So
  `rustc` and [rust-analyzer] are convergent designs sharing a lineage, not the same engine.
- **Maturity.** A large, actively-maintained system under `rust-lang/compiler`, documented in
  depth in the [rustc-dev-guide][docs] — the authoritative and continuously-updated reference
  this deep-dive is grounded in.

---

## Strengths

- **Uniform incrementality for the whole middle-end.** One memoization + red-green mechanism
  makes type-checking, borrow-checking, MIR, and codegen all incremental and lazy, instead of a
  bespoke cache per phase.
- **Demand-driven laziness.** Only work reachable from a demanded output is computed; the
  top-level `compile` query pulls exactly what it needs ([`query.md`][rustc-query]).
- **Accurate change detection (early cutoff).** Comparing result fingerprints stops a changed
  input from cascading when the output is unchanged — the projection-query "firewall" pattern
  keeps most of the graph green even when a monolithic input churns ([`incr-detail`][incr-detail]).
- **Reuse survives process exit and crate boundaries.** On-disk results + stable `DefPathHash`
  identities let a fresh `cargo build` reuse the prior build, and untouched dependencies are
  served from `.rmeta` rather than recompiled.
- **Data-oriented dispatch.** Providers are plain function-pointer tables, not trait objects —
  simple, fast, macro-generated ([`query.md`][rustc-query]).

## Weaknesses

- **Enormous engineering surface.** Stable IDs, two synchronized dep-graphs, fingerprinting,
  cache promotion, and per-query modifiers are genuinely hard; the dev-guide devotes a long
  "how persistence makes everything complicated" section to it ([`incr-detail`][incr-detail]).
- **Purity is a straitjacket.** Every query must be a pure `K → V` with an immutable, cheaply
  cloneable result; side effects and expensive-to-clone values need escape hatches
  (`eval_always`, `Steal<T>`, `Rc`) that carry their own hazards.
- **The fingerprint tax.** Hashing every result with an expensive stable hash can make
  incremental builds _slower_ than clean ones ([`incr-detail`][incr-detail]).
- **On-disk cache is rewritten wholesale.** No in-place update; each session rewrites the cache
  and graph files, a few percent of build time ([`incr-detail`][incr-detail]).
- **Parsing is not incremental.** The front end re-lexes and re-parses the whole crate on every
  invocation; `rustc` buys nothing for editor-latency parsing — that is [tree-sitter]/[rust-analyzer]
  territory ([`overview.md`][overview]).
- **Cache-invalidation subtlety.** Ordered reads, false-positive avoidance, and stolen-result
  guards are correctness-critical and easy to get wrong; a missed dependency edge is a silent
  miscompile risk mitigated only by determinism + a wide hash.

## Key design decisions and trade-offs

| Decision                                                             | Rationale                                                                                                 | Trade-off                                                                                       |
| -------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| **Demand-driven memoized queries** (not sequential passes)           | Compute only what a demanded output needs; make the whole middle-end incremental under one mechanism      | Every step must become a pure `K → V`; a large retrofit still incomplete (parsing stays batch)  |
| **Providers as plain `fn`-pointer tables** (`Providers`, not traits) | Simple, fast, macro-generated dispatch; local/extern split keyed on the query _key_                       | Manual registration wiring; two tables + metadata plumbing to make a query cross-crate          |
| **Red-green marking with output comparison**                         | Accurate incrementality — a changed input that yields an unchanged result doesn't cascade (early cutoff)  | Must re-run to compare, and must hash outputs; interleaving change-detection adds complexity    |
| **128-bit `Fingerprint`s over stable (`DefPath`) forms**             | Compare results without loading old values; make hashes comparable across sessions despite ID renumbering | Fingerprinting is expensive — the top reason incremental can be slower than a clean build       |
| **On-disk `DepGraph` + result cache across sessions**                | Reuse work between separate `cargo build` invocations, and across crate boundaries via `.rmeta`           | The whole stability apparatus (`DefPath`/`StableHash`) + wholesale file rewrite each session    |
| **Two dep-graphs (previous immutable + new)**                        | try-mark-green reads the old graph; green nodes are copied forward without re-running to record edges     | Cache promotion needed so unloaded intermediate results aren't lost from the new cache          |
| **Projection-query firewalls** (`no_hash` + `eval_always`)           | A volatile monolithic input (indexed HIR) doesn't invalidate everything downstream                        | Author must structure queries into monolith + projections and set modifiers correctly           |
| **Cycles are a fatal error** (recovery removed)                      | Keep the model a clean DAG; avoid unclear interactions between cycle-recovery and incrementality          | Certain invalid inputs abort with a cycle error instead of degrading gracefully                 |
| **Parser left batch / non-query**                                    | Front-end speed is adequate whole-program; querying lexing/parsing wasn't worth the retrofit yet          | No incremental-parsing / editor-latency benefit; that role falls to tree-sitter / rust-analyzer |

---

## Sources

- [rustc-dev-guide — `query.md` (demand-driven compilation, memoization, providers)][rustc-query]
- [rustc-dev-guide — `queries/incremental-compilation.md` (the red-green basic algorithm, try-mark-green)][incr-basic]
- [rustc-dev-guide — `queries/incremental-compilation-in-detail.md` (red-green in depth, fingerprints, stability, two dep-graphs, cache promotion, query modifiers)][incr-detail]
- [rustc-dev-guide — `queries/query-evaluation-model-in-detail.md` (query anatomy, memoization, cycles, `Steal`)][query-model]
- [rustc-dev-guide — `queries/salsa.md` (how salsa relates; not used in `rustc` itself)][salsa-doc]
- [rustc-dev-guide — `overview.md` (Queries section; parsing/name-res/macro-expansion done whole-program)][overview]
- [Niko Matsakis — on-demand & incremental design doc][design-doc]
- ["Red/Green" dependency-tracking tracking issue (`rust-lang/rust` #42293)][redgreen]
- [Incremental compilation announcement (Rust blog, 2016)][announce]
- Local source trees: [`rust-lang/rustc-dev-guide`][guide-repo] (SHA `646dd8e`) · [`rust-lang/rust`][repo]
- Related deep-dives: [incremental & query-based theory][incremental] · [rust-analyzer (salsa, in-memory)][rust-analyzer] · [tree-sitter (incremental parsing)][tree-sitter] · [Roslyn][roslyn] · [Lezer][lezer] · [top-down / recursive descent][top-down] · [the comparison][comparison]

<!-- References -->

<!-- Same-tree siblings, theory, umbrella -->

[incremental]: ./theory/incremental.md
[top-down]: ./theory/top-down.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[umbrella]: ./index.md
[tree-sitter]: ./tree-sitter.md
[rust-analyzer]: ./rust-analyzer.md
[roslyn]: ./roslyn.md
[lezer]: ./lezer.md
[salsa]: ./rust-analyzer.md#salsa-the-query-engine

<!-- External primary sources -->

[repo]: https://github.com/rust-lang/rust
[guide-repo]: https://github.com/rust-lang/rustc-dev-guide
[docs]: https://rustc-dev-guide.rust-lang.org/
[rustc-query]: https://rustc-dev-guide.rust-lang.org/query.html
[incr-basic]: https://rustc-dev-guide.rust-lang.org/queries/incremental-compilation.html
[incr-detail]: https://rustc-dev-guide.rust-lang.org/queries/incremental-compilation-in-detail.html
[query-model]: https://rustc-dev-guide.rust-lang.org/queries/query-evaluation-model-in-detail.html
[salsa-doc]: https://rustc-dev-guide.rust-lang.org/queries/salsa.html
[overview]: https://rustc-dev-guide.rust-lang.org/overview.html
[metadata]: https://doc.rust-lang.org/nightly/nightly-rustc/rustc_metadata/index.html
[design-doc]: https://github.com/nikomatsakis/rustc-on-demand-incremental-design-doc/blob/e08b00408bb1ee912642be4c5f78704efd0eedc5/0000-rustc-on-demand-and-incremental.md
[redgreen]: https://github.com/rust-lang/rust/issues/42293
[announce]: https://blog.rust-lang.org/2016/09/08/incremental.html
[chalk]: https://rust-lang.github.io/chalk/book/what_is_chalk.html
