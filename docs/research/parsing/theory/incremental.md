# Incremental & Query-Based Parsing

How a parser stops being a one-shot function and becomes a **standing service** that a
text editor re-runs on every keystroke — by reusing the previous parse tree
([node reuse][ts]), by making trees cheap to share ([persistent / red-green trees][rg]),
and by lifting the whole compiler front-end into a graph of **memoized, demand-driven
queries** that recompute only what an edit invalidated. This is the theory subtree page
behind the [incremental / IDE-grade][comparison] systems in the survey — [tree-sitter],
[rust-analyzer], [Roslyn][roslyn], [Lezer][lezer], and the [`rustc` query system][rustc].

**Last reviewed:** July 3, 2026

---

## At a glance

| Question                                    | Answer                                                                                                                 |
| ------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| What contract does it target?               | The **editor contract** — parse a file that is _constantly half-typed_, on every keystroke, reusing old work           |
| Two distinct meanings of "incremental"      | Reuse the **tree** (subtree/node reuse) vs. reuse the **computation** (memoized queries) — orthogonal                  |
| Foundational result                         | Wagner & Graham 1997/1998 — **optimal** incremental LR parsing in `O(t + s·lg N)`, with a formal node-reuse definition |
| The data structure that makes reuse cheap   | **Persistent** trees with structural sharing; the **red/green** split (immutable core + positional wrappers)           |
| The architecture that makes recompute cheap | **Demand-driven queries**: pure `K → V` functions, memoized, with a dependency graph for invalidation                  |
| The theory that names it                    | Self-adjusting computation ([Adapton][adapton-ext]) and build systems ([_à la carte_][bs] — **early cutoff**)          |
| Cost                                        | Persistent structures + a dependency graph cost memory; the payoff is `~O(edit size)` re-parse, not `O(n)`             |

---

## Overview / motivation

### The batch contract vs. the editor contract

A compiler back-end parses a file **once**, from scratch, under a _batch_ contract:
input in, [AST][concepts] out, done. An IDE needs a different contract entirely. As the
[tree-sitter] introduction puts it, an editor parser must be _"Fast enough to parse on
every keystroke in a text editor"_ and _"Robust enough to provide useful results even in
the presence of syntax errors"_ ([`docs/src/index.md`][ts-index]). Three demands follow
that a batch parser never faces:

1. **The input is a moving target.** Between two parses the user typed one character. Re-running an `O(n)` parse over a 10,000-line file for a one-key edit is pure waste — the work should scale with the _edit_, not the file.
2. **The input is usually invalid.** Mid-keystroke the braces are unbalanced and the expression is half-written; the parser must still return a usable tree with the error localized, not bail out. That is the [error-recovery][comparison] ladder's top rung.
3. **Everything downstream re-runs too.** Syntax highlighting, completion, diagnostics, go-to-definition — all of them re-derive from the tree on every edit. Incrementality only pays off end-to-end if the _analyses_ are incremental as well, not just the parse.

The classical [LR][bottom-up] and [LL][top-down] generators ([Bison][bison],
[ANTLR][antlr]) can _recover_ from errors, but a keystroke still means re-running the
whole parser. Escaping that is what this page is about.

### Two kinds of "incremental" — reuse the tree vs. reuse the computation

The word "incremental" hides two orthogonal ideas, and the modern systems combine them:

- **Incremental parsing (reuse the _tree_).** Keep the previous parse tree; after an edit, re-parse only the region the edit touched and **splice in** the unchanged subtrees. This is Wagner & Graham's result and what [tree-sitter] and [Lezer][lezer] do. The unit of reuse is a **subtree / node**.
- **Incremental computation (reuse the _work_).** Model the compiler as a graph of pure functions ("queries") whose results are **memoized**; when an input changes, re-execute only the queries whose inputs actually changed. This is the [salsa][salsa]/[`rustc`][rustc] model. The unit of reuse is a **query result**.

The first is a parsing algorithm; the second is a whole-compiler architecture that a
parser plugs into. [rust-analyzer] is the clearest case of both at once: a lossless
[red-green][rg] tree ([rowan][rowan-ext]) sits _inside_ a [salsa][salsa] query graph.

> [!NOTE]
> **Incremental ≠ error-recovering, but they travel together.** Recovery
> ([comparison][comparison]) is about producing _a_ tree from broken input;
> incrementality is about producing the _next_ tree cheaply. An editor needs both, so
> the same systems (tree-sitter, Lezer, Roslyn, rust-analyzer) tend to implement both —
> but they are separate properties.

---

## How it works

### Incremental parsing: node reuse (Wagner & Graham)

The foundational treatment is Tim Wagner's 1997 Berkeley dissertation under Susan Graham,
_Practical Algorithms for Incremental Software Development Environments_
([`wagner-1997`][wagner]). Its parsing chapter frames the algorithm as an ordinary
[LR][bottom-up] parse whose _input alphabet is extended with nonterminals_:

> _"The input to the parser consists of both terminal and nonterminal symbols; the latter are a natural representation of the unmodified subtrees from the reference version of the parse tree."_ — [`wagner-1997`][wagner] §6.3

So an unchanged subtree from the old tree is fed to the LR automaton as a single
nonterminal symbol; only where the automaton's state disagrees with the old tree does it
"break down" that subtree (`right_breakdown`) into its children and re-parse. Wagner's
central contribution is making **node reuse** precise and optimal:

> _"We provide the first non-operational definition of optimal node reuse in the context of incremental parsing, and present optimal algorithms for retaining tokens and nodes during incremental lexing and parsing."_ — [`wagner-1997`][wagner], Preface

The optimal algorithm runs in **`O(t + s·lg N)`** for `t` terminals shifted, `s`
reused subtrees, and a tree of `N` nodes (§6.4) — i.e. work proportional to the edit
plus a logarithmic splice cost, not to the file. Incremental **lexing** gets the same
treatment (Ch. 5): a lookback/lookahead region around the edit is re-lexed and tokens
outside it are retained. [tree-sitter] is this lineage adapted to [GLR][general-parsing]
(so it also handles ambiguity and does not need an [LR][bottom-up]-clean grammar); its
`Subtree` is ref-counted precisely so unchanged nodes survive an edit
([`lib/src/subtree.h`][ts-subtree]).

### Persistent / red-green trees: making reuse cheap

Node reuse only helps if sharing a node between the old and new tree is nearly free. That
demands a **persistent** (immutable, structurally shared) tree — mutate by allocating a
new spine from the root to the edit and pointing everything else at the old nodes. The
obstacle is that immutable nodes cannot store the two things API users most want:
absolute source positions and parent pointers, because the _same_ node may sit at
different offsets under different parents after an edit.

The **red/green tree** resolves this. Microsoft's Roslyn documents the pattern verbatim:

> _"Green nodes: The internal, immutable representation. These nodes store only their syntactic kind, their width (character count), and their children. They do not store absolute text positions or parent pointers. Red nodes: The public-facing wrappers … combine a green node with positional and parental context."_ — Roslyn, [`Red-Green Trees.md`][roslyn-rg]

Because green nodes are position-free and parent-free, they are freely shareable — the
same `()` parameter-list node is reused across an entire solution, and Roslyn notes the
green structure is therefore _"a directed acyclic graph (DAG), not a tree"_
([`Red-Green Trees.md`][roslyn-rg]). Absolute positions and parents are computed lazily
on the **red** side, on demand, when you navigate. The payoff Roslyn reports: incremental
re-parses _"complete in microseconds with memory reuse approaching 99.99% for typical
edits."_ Rust's [`rowan`][rowan-ext] crate (the CST library under [rust-analyzer]) is a
direct port of this idea; [Lezer][lezer]'s trees are the same shape, deliberately kept as
minimal _"blobs with a start, end, tag, and set of child nodes"_ ([`@lezer/lr`
README][lezer-readme]) for compactness.

### Demand-driven queries: reusing the computation

Incremental parsing gives you the next _tree_ cheaply; a **query system** gives you the
next _analysis_ cheaply. The idea, from the [`rustc` dev-guide][rustc-query]:

> _"Instead of entirely independent passes (parsing, type-checking, etc.), a set of function-like queries compute information about the input source. … Query execution is memoized. The first time you invoke a query, it will go do the computation, but the next time, the result is returned from a hashtable."_ — [rustc-dev-guide `query.md`][rustc-query]

The compiler is inverted: rather than driving passes forward, one top-level `compile`
query **demands** its inputs, which demand theirs, "further and further back until we
wind up doing the actual parsing." [salsa][salsa] — extracted from rust-analyzer — is the
same model as a reusable library: _"a generic framework for on-demand, incrementalized
computation"_ where you define the program _"as a set of queries"_, split into **inputs**
(mutable base facts) and **functions** (pure, memoized derivations)
([salsa `README.md`][salsa-readme]). Salsa credits [Adapton][adapton-ext], glimmer, and
rustc's own query system as its ancestors.

The engine's job on an edit is **revalidation**: for each memoized query, decide whether
any input it read actually changed, and re-execute only if so.

### The build-systems connection: early cutoff and "à la carte"

A query engine _is_ a build system — same problem: given a graph of tasks with cached
results, rebuild the minimum after an input changes. Mokhov, Mitchell & Peyton Jones's
_Build Systems à la Carte_ ([`mokhov-2018`][bs], ICFP 2018) factors that design space
into two _orthogonal_ choices — _"the order in which tasks are built … and whether or not
a task is (re-)built"_ (§1) — and names the property that makes incrementality _minimal_
rather than merely correct: **early cutoff**. A task whose inputs changed but whose
_output_ came out identical must stop propagating, so downstream tasks are not rebuilt.
That is exactly what a good query engine and a good [red-green][rg] parser both do: Roslyn
reuses a green node when re-parsing yields an identical subtree; salsa stops revalidation
when a re-executed query returns an unchanged value. The self-adjusting-computation
lineage — [Adapton][adapton-ext] (Hammer et al., PLDI 2014) and Acar's work before it —
is the theory that first made demand-driven change-propagation precise.

### Invalidation in practice: durability, firewalls, cancellation

Naïve revalidation walks every query back to the base inputs on every edit — too slow.
Real engines add three refinements, visible in [salsa][salsa]'s source:

- **Durability** — a hint for how often an input changes. Salsa: _"We use durabilities to optimize the work of 'revalidating' a query after some input has changed. … if we know that the only changes were to inputs of low durability (the common case), and we know that the query only used inputs of medium durability or higher, then we can skip that enumeration."_ ([`src/durability.rs`][salsa-durability]). The file the user is typing in is `LOW`; library source and config are higher, so most of the graph is proven stale-free without traversal. This is a **firewall**: high-durability regions don't get revalidated against low-durability edits.
- **Early cutoff** (above) — a re-executed query that returns an unchanged value stops the change from propagating to its dependents ("[backdating][bs]").
- **Cancellation** — because the user may type again before the last parse finishes, an in-flight query must abort. Salsa models this as a thrown `Cancelled` whose variants include _"The query was operating on revision R, but there is a pending write to move to revision R+1"_ ([`src/cancelled.rs`][salsa-cancelled]) — i.e. a new keystroke cancels the stale computation.

---

## Where it shows up in practice

Every system below is surveyed in its own deep-dive; this is the incremental/query-based
cluster of the [master catalog][umbrella].

| System           | Tree reuse (incremental parse)                     | Computation reuse (queries)              | Tree shape                        |
| ---------------- | -------------------------------------------------- | ---------------------------------------- | --------------------------------- |
| [tree-sitter]    | **Yes** — GLR + ref-counted `Subtree` reuse        | No (parse only; host wires analyses)     | Lossless CST, inline small leaves |
| [Lezer][lezer]   | **Yes** — incremental GLR, editor-oriented         | No (CodeMirror wires analyses)           | Compact blob tree                 |
| [Roslyn][roslyn] | **Yes** — red/green subtree reuse (~99.99%)        | Partial (compilation-as-a-service model) | Red/green, full-fidelity          |
| [rust-analyzer]  | **Yes** — [rowan][rowan-ext] red/green CST         | **Yes** — [salsa][salsa] query graph     | Red/green (rowan), lossless       |
| [`rustc`][rustc] | Reuses on-disk query results, not a live edit tree | **Yes** — the demand-driven query system | AST/HIR/MIR behind queries        |

The two columns are the two "incrementals": [tree-sitter] and [Lezer][lezer] are pure
incremental _parsers_ (a host supplies the rest); [`rustc`][rustc] is a pure incremental
_computation_ engine (its front-end still batch-parses); [rust-analyzer] is the full
stack — a red-green incremental parse _inside_ a salsa query graph — and is the reference
design for a query-based compiler front-end.

---

## Strengths

- **Latency scales with the edit, not the file.** A keystroke re-parses a region and
  splices unchanged subtrees ([`O(t + s·lg N)`][wagner]); analyses re-run only where
  inputs changed. This is what makes on-keystroke tooling feel instant on large files.
- **Structural sharing bounds memory.** Persistent [red-green][rg] trees share unchanged
  nodes between successive versions (and across files/functions), so keeping history is
  cheap and "modify" is a root-to-edit spine allocation.
- **One architecture serves the whole IDE.** A [query graph][rustc] makes parse,
  name-resolution, types, and diagnostics all incremental and lazy under a single
  memoization/invalidation mechanism, instead of a bespoke cache per feature.
- **Laziness for free.** Demand-driven means work not asked for is never done — Roslyn's
  red nodes are created only for the parts of the tree you actually touch
  ([`Red-Green Trees.md`][roslyn-rg]).

## Weaknesses

- **Memory and bookkeeping overhead.** Persistent trees plus a dependency graph cost more
  memory than a throwaway [AST][concepts], and every query read must be recorded. For a
  one-shot batch parse this is pure overhead.
- **Implementation complexity.** Node-reuse correctness (Wagner's `right_breakdown` /
  optimality argument), red/green invariants, cycle handling, cancellation, and durability
  are genuinely hard — far more than a [recursive-descent][top-down] parser.
- **Grammar/engine constraints.** Incremental [GLR][general-parsing] wants a generated
  table and a lossless CST; it does not drop into a hand-written [recursive-descent][top-down]
  parser for free.
- **Not every workload is edit-driven.** Validating a config string once, or parsing a
  version number, gains nothing — the incremental machinery only earns its keep when the
  same input is re-parsed after small edits, repeatedly.

---

## Key design decisions and trade-offs

| Decision                                           | Rationale                                                                                         | Trade-off                                                                        |
| -------------------------------------------------- | ------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| Feed **nonterminals** (old subtrees) to the parser | Lets the LR/GLR automaton reuse whole subtrees, not just tokens ([Wagner][wagner])                | Needs a persistent old tree + break-down logic; only pays off on small edits     |
| **Position-free, parent-free** (green) nodes       | Makes nodes shareable across positions/parents → a reuse DAG ([Roslyn][roslyn-rg])                | Positions/parents must be recomputed lazily on the red side                      |
| Model the compiler as **memoized queries**         | Uniform incrementality + laziness for all analyses, not per-feature caches ([rustc][rustc-query]) | Everything must be pure `K → V`; side effects and cheap-clone returns are forced |
| **Durability** tiers on inputs                     | Skip revalidating stable regions against a hot edit ([salsa][salsa-durability])                   | A hint the author must set correctly; wrong tiers = stale results or wasted work |
| **Early cutoff** (backdate unchanged outputs)      | Stops change propagation at the first identical result ([_à la carte_][bs])                       | Requires comparing outputs for equality — cost, and a good `Eq`                  |
| **Cancellation** on new input                      | A fresh keystroke must abort the stale in-flight parse ([salsa][salsa-cancelled])                 | Query code must be unwind-safe / re-entrant                                      |

---

## Sources

- **[`wagner-1997`][wagner]** — T. Wagner, _Practical Algorithms for Incremental Software
  Development Environments_ (UC Berkeley Ph.D. thesis, 1997/1998; with S. Graham). The
  foundational incremental-lexing (Ch. 5) and incremental-parsing (Ch. 6, "Optimal
  Incremental Parsing", `O(t + s·lg N)`) treatment and the formal node-reuse definition.
- **[`mokhov-2018`][bs]** — A. Mokhov, N. Mitchell & S. Peyton Jones, _Build Systems à la
  Carte_ (Proc. ACM Program. Lang. 2, ICFP, Article 79). The task/rebuild framework and
  **early cutoff**.
- **[`hammer-2014`][adapton-ext]** — M. Hammer et al., _Adapton: Composable, Demand-Driven
  Incremental Computation_ (PLDI 2014). The self-adjusting-computation basis salsa cites.
- **Primary source trees** — Roslyn [`Red-Green Trees.md`][roslyn-rg]; [salsa][salsa-readme]
  `README.md` + `src/{durability,cancelled}.rs`; [rustc-dev-guide `query.md`][rustc-query];
  [`@lezer/lr` README][lezer-readme]; [tree-sitter] `docs/src/` + `lib/src/subtree.h`.
  Each system's own deep-dive carries the full citation set.

<!-- References -->

<!-- Same-tree theory siblings -->

[theory-index]: ./index.md
[formal]: ./formal-languages.md
[top-down]: ./top-down.md
[bottom-up]: ./bottom-up.md
[general]: ./general-parsing.md
[peg]: ./peg-packrat.md
[pratt]: ./pratt-precedence.md
[derivatives]: ./derivatives.md

<!-- Tree umbrella / concepts / comparison -->

[umbrella]: ../index.md
[concepts]: ../concepts.md
[comparison]: ../comparison.md

<!-- Library deep-dives -->

[ts]: ../tree-sitter.md
[tree-sitter]: ../tree-sitter.md
[antlr]: ../antlr.md
[bison]: ../bison-yacc.md
[rust-analyzer]: ../rust-analyzer.md
[roslyn]: ../roslyn.md
[lezer]: ../lezer.md
[rustc]: ../rustc-queries.md
[rg]: #persistent--red-green-trees-making-reuse-cheap
[salsa]: ../rust-analyzer.md#salsa-the-query-engine

<!-- Primary sources & external -->

[wagner]: https://www2.eecs.berkeley.edu/Pubs/TechRpts/1998/CSD-98-1017.pdf
[bs]: https://www.microsoft.com/en-us/research/uploads/prod/2018/03/build-systems.pdf
[adapton-ext]: http://matthewhammer.org/adapton/adapton-pldi2014.pdf
[roslyn-rg]: https://github.com/dotnet/roslyn/blob/main/docs/compilers/Design/Red-Green%20Trees.md
[salsa-readme]: https://github.com/salsa-rs/salsa/blob/master/README.md
[salsa-durability]: https://github.com/salsa-rs/salsa/blob/master/src/durability.rs
[salsa-cancelled]: https://github.com/salsa-rs/salsa/blob/master/src/cancelled.rs
[rustc-query]: https://rustc-dev-guide.rust-lang.org/query.html
[rowan-ext]: https://github.com/rust-analyzer/rowan
[lezer-readme]: https://lezer.codemirror.net/
[ts-index]: https://github.com/tree-sitter/tree-sitter/blob/master/docs/src/index.md
[ts-subtree]: https://github.com/tree-sitter/tree-sitter/blob/master/lib/src/subtree.h
