# Cost & Search — Layout as Shortest Path, and the Incompleteness Budget

The **industrial answer** to [optimality][optimality]. Model the layout decision as a weighted
directed graph — nodes are partial formatting states, edges are "break here" / "don't break
here", edge weights are penalties — and run a shortest-path search. clang-format, scalafmt,
`dart_style` and dfmt all independently arrived here. And all four then discovered the same
thing: **the search is exponential in the worst case, and the worst case occurs in real code**.
So every one of them caps it.

That cap is what this page is actually about. The interesting content of this family is not
"they use Dijkstra" — it is **what each system gives up when the search gets too expensive, and
how silently**. Call it the incompleteness budget. It is invisible in the papers, explicit in
the source, and it is the single most transferable finding in this survey for anyone shipping a
formatter.

## At a glance

| Dimension           | Where the search family lands                                                                                                                  |
| ------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| **Input**           | A token stream annotated with structure; states are _partial layouts_, not documents                                                           |
| **Objective**       | Minimize a **penalty sum** over chosen breaks + overflow — an explicit cost, as in [Yelland][optimality], but reached by search rather than DP |
| **Decision rule**   | Best-first / Dijkstra over the state graph, with a priority queue keyed on accumulated penalty                                                 |
| **Time**            | **Exponential in the worst case**, in every member. Linear-ish in the good case                                                                |
| **Completeness**    | **None of them are complete.** All four cap the search and fall back — see [the budget table](#the-incompleteness-budget)                      |
| **Alignment**       | Yes — states carry a column, so alignment is natural (contrast [combinators][combinators])                                                     |
| **Configurability** | Very high: a penalty per token class is a knob. clang-format exposes ~10 `Penalty*` options directly                                           |
| **Ships in**        | [clang-format][clang-format], [scalafmt][scalafmt-thesis], [`dart_style`][dart-style], [dfmt][dfmt], SDC's `sdfmt`                             |

> [!NOTE]
> This is the [theory tree][theory-index] entry for **approximate** exact-layout selection.
> [Optimality][optimality] covers the algorithms that get the right answer and publish a bound;
> this page covers the systems that want the same answer, cannot afford it, and buy an
> approximation. Read that page first — the objectives vocabulary (lexicographic overflow /
> height / cost) is defined there.

---

## Overview / motivation

### The formulation

All four systems describe it the same way. clang-format's is the most explicit, in a comment
above the function that does it:

> "Analyze the entire solution space starting from `InitialState`. This implements a variant of
> Dijkstra's algorithm on the graph that spans the solution space (`LineState`s are the nodes).
> The algorithm tries to find the shortest path (the one with lowest penalty) from
> `InitialState` to a state where all tokens are placed. Returns the penalty."
> — [`UnwrappedLineFormatter.cpp`][clang-uf], `analyzeSolutionSpace`

Geirsson's scalafmt thesis, arrived at independently, describes the same object:

> "The `Decision`s from the `Router` produce a directed weighted graph … To find the optimal
> formatting layout, our challenge is to find the cheapest path from the first token to the last
> token. The best-first search algorithm is an excellent fit for the task."
> — [Geirsson 2016][geirsson], §3.3.2

and records that scalafmt "then switched to Dijkstra's shortest path algorithm" (§2). The
generative step is uniformly binary: from a state, produce the successor that breaks before the
next token and the one that does not. clang-format:

```cpp
FormatDecision LastFormat = Node->State.NextToken->getDecision();
if (LastFormat == FD_Unformatted || LastFormat == FD_Continue)
  addNextStateToQueue(Penalty, Node, /*NewLine=*/false, &Count, &Queue);
if (LastFormat == FD_Unformatted || LastFormat == FD_Break)
  addNextStateToQueue(Penalty, Node, /*NewLine=*/true, &Count, &Queue);
```

— [`UnwrappedLineFormatter.cpp`][clang-uf]

That is `2^tokens` reachable states before any pruning, which is the whole problem.

### Why it degenerates, precisely

The naive search is not slow on hard-to-format code in general. It is slow on one specific
situation, and both scalafmt and dfmt hit it. Geirsson's example is three lines:

```scala
// Column 60                                               |
a + b + c + d + e + f + g + h + i + j + k + l +
m + n + o + p + q + r + s + t + v + w + y +
// This comment exceeds column limit, no matter what path is chosen.
z
```

> "Algorithm 1 is exponential in the worst case. For example, listing 31 shows a tiny input that
> triggers the search to explore over 8 million states. … Even if we could visit 1 state per
> microsecond the search will take almost 1 second to complete. This is unacceptable performance
> to format only 2 lines of code." — [Geirsson 2016][geirsson], §3.3.2

The trigger is **unavoidable overflow**. When some line must exceed the limit no matter what,
every path incurs the overflow penalty, so no path dominates, so the frontier never prunes and
the search enumerates the space. A footnote records the real rate: "Benchmarks reveal the
best-first search visits on average one state per 10 microseconds" — so 8 million states is
about 80 seconds, not one.

This is the _same_ failure that [APEP reports for Bernardy][optimality] — "the paper does not
handle unavoidable overflow" — showing up as a performance cliff instead of a correctness gap.
An over-long comment or a 200-character string literal is not an exotic input; it is Tuesday.
**Any search-based formatter must answer "what happens when nothing fits" before it ships.**

---

## The incompleteness budget

Here is the finding. Every shipping search formatter caps its search, and the caps are
hard-coded constants, undocumented in the user-facing manual, and different in kind:

| System           | Budget                                                                            | What happens at the cap                                                                                                                                                                                                                 |
| ---------------- | --------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **clang-format** | `if (Count > 50'000) Node->State.IgnoreStackForComparison = true;`                | **Silently becomes approximate.** States that differ only in their indentation stack are merged, so the search may return a non-optimal layout — and never says so                                                                      |
| **clang-format** | `if (Count > 25'000'000) return 0;`                                               | **Gives up entirely**, returning penalty 0. Also: `if (Queue.empty()) { // We were unable to find a solution, do nothing. // FIXME: Add diagnostic? }`                                                                                  |
| **dfmt**         | `private enum ALGORITHMIC_COMPLEXITY_SUCKS = uint.sizeof * 8;`                    | Only the **first 32 tokens** of a line are considered — breaks are a `uint` bitmask, `tokensEnd = min(tokens.length, 32)`. Beyond that the line is not searched at all                                                                  |
| **dfmt**         | `while (!open.empty && tries < 10_00)`                                            | After **1000 queue pops**, return the cheapest state seen — `solved` or not: `if (open[].front < lowest) return … else return genRetVal(lowest.breaks, index);`                                                                         |
| **scalafmt**     | `dequeueOnNewStatements` — empty the whole queue on reaching a statement boundary | Commits irrevocably to the layout of the preceding statement. Sound in principle ("the formatting layout for each statement is independent"), but **needed a patch**: "never run `dequeueOnNewStatements` inside a pair of parentheses" |

Three observations, and they generalize:

1. **The budget is a hard-coded integer, not a policy.** `50'000`, `25'000'000`, `32`, `10_00`.
   None is exposed as an option; none is documented where a user would find it. dfmt's is named
   `ALGORITHMIC_COMPLEXITY_SUCKS`, which is at least honest.
2. **Degradation is silent.** clang-format's first cap changes the answer without any signal.
   dfmt returns its best-so-far even when `_solved` is false — i.e. even when it _knows_ the
   line still exceeds `max_line_length`. A user cannot distinguish "this is the optimal layout"
   from "this is what we had when the budget ran out".
3. **The sound optimizations still need unsound patches.** `dequeueOnNewStatements` is
   _correct_ — statements really are independent — yet Geirsson had to disable it inside
   parentheses because a `case` inside an argument list is a statement start whose optimal
   prefix is not actually independent. His own summary: "some optimizations are rather ad-hoc
   and require creative workarounds" (§3.4).

For [the D proposal][proposal] this is the decisive input. Search buys layouts greedy cannot
reach, and it costs an unbounded worst case that you then have to bound by hand, in a way your
users cannot see. If a D formatter runs on the LSP keystroke path (see [the substrate
baseline][baseline]), that trade is very hard to justify for v1 — which is why the proposal's
M2 is a greedy `Doc` engine and search is deferred to M9 behind a flag, with latency measured
before it is committed to.

---

## How it works: the cost models

The graph is the same everywhere; the **penalties** are where the style actually lives, and
they are startlingly ad hoc.

### dfmt: two constants and a token-pair table

dfmt's entire cost model is 60 lines. The constants are literal:

```d
immutable int remainingCharsMultiplier = 25;
immutable int newlinePenalty = 480;
```

— [`src/dfmt/wrapping.d`][dfmt-wrapping], `State.this`

Overflow past the _soft_ limit costs `(length - soft_max) * 25`; each break costs
`480 + breakCost(prevType, currentType) * depthFactor`, where `depthFactor` is `abs(depths[i])`
doubled — so breaking deep inside nested parentheses is penalized more than breaking at the top
level. Exceeding the _hard_ `max_line_length` sets `_solved = false` rather than adding cost, so
the hard limit is a feasibility constraint and the soft limit is a cost — precisely the
soft-margin design [Yelland argued for][optimality], reached independently and much more
crudely.

The state is identified **by its break bitmask alone**:

```d
bool opEquals(ref const State other) const pure nothrow @safe
{
    return other.breaks == breaks;
}

size_t toHash() const pure nothrow @safe
{
    return breaks;
}
```

which is what makes the 32-token window structural rather than incidental: the state _is_ a
`uint`, so the window cannot exceed 32 without changing the representation.

### clang-format: penalties as user-facing options

clang-format's model is the elaborate end. Penalties are assigned per token by
`TokenAnnotator::splitPenalty`, adjusted by `ContinuationIndenter`, and roughly ten of them are
exposed as style options (`PenaltyBreakAssignment`, `PenaltyBreakBeforeFirstCallParameter`,
`PenaltyReturnTypeOnItsOwnLine`, `PenaltyExcessCharacter`, …). This is the most tunable layout
engine in the survey and also the least predictable: the options interact through a shortest-path
search, so the effect of changing one is not local. The full treatment is in
[its deep-dive][clang-format].

The queue is ordered on a `(penalty, insertion count)` pair, and the tie-break is deliberate:

> "A pair of `<penalty, count>` that is used to prioritize the BFS on. In case of equal
> penalties, we want to prefer states that were inserted first. During state generation we make
> sure that we insert states first that break the line as late as possible."
> — [`UnwrappedLineFormatter.cpp`][clang-uf]

"Break as late as possible" among equal-cost layouts is a _style_ decision smuggled into a tie-break
rule. Every search formatter has a few of these, and they are invisible to the option surface.

### scalafmt: `Router` → `Decision` → `Split`

scalafmt separates the two concerns cleanly, and this is the most reusable idea on this page:
a **`Router`** maps a token position to a set of legal `Split`s (each with a penalty and a
`Policy` constraining later decisions), and the **search** is generic over whatever the Router
produced. The language knowledge lives in the Router; the optimizer never learns Scala. That is
[Oppen's producer/printer split][oppen] applied to a search engine, and it is why the thesis can
claim "language-agnostic algorithms".

---

## Power & limits

**What search buys over greedy:**

- Layouts requiring a locally-worse choice — precisely [Bernardy's counterexample][optimality].
- A real cost model, so style preferences ("prefer breaking before `.`", "never split a return
  type onto its own line unless it saves 3 lines") become expressible as numbers.
- Alignment for free, because a state already carries a column.
- Graceful behaviour under overflow, _if_ the cost model distinguishes soft and hard limits
  (dfmt does; clang-format does via `PenaltyExcessCharacter`).

**What it costs:**

1. **No latency bound.** The worst case is exponential and is triggered by ordinary inputs.
   Everything else on this list follows from patching that.
2. **Silent incompleteness** (above). The user gets a layout that may be arbitrarily far from
   optimal with no indication.
3. **Non-local, unpredictable option semantics.** A penalty change propagates through a search;
   there is no way to reason about it except by running the formatter over a corpus.
4. **Non-local output.** Same objection as [optimality][optimality]: a small edit can re-lay-out
   a wide region, which is [diff churn][diff-review] and is hostile to range formatting.
5. **The optimizations are the product.** clang-format's search is ~1,800 lines; the annotation
   pass that feeds it (`TokenAnnotator.cpp`) is ~6,800. The search is the easy part.

**What it does not address**, same as everything else in this tree: comments and trivia. Note
though that the search family is the _only_ one that handles them semi-gracefully by accident —
because the cost model already has a notion of "this line overflows and there is nothing to be
done", a long comment degrades cost rather than breaking the algorithm. It just does so at
catastrophic speed, which is Geirsson's listing 31.

---

## Performance & complexity

| System           | Best case                                                                           | Worst case                                              | Observed rate                                                                                                 |
| ---------------- | ----------------------------------------------------------------------------------- | ------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| **scalafmt**     | "runs in linear time" when "the search always chooses the cheapest splits" (§3.3.2) | Exponential — "over 8 million states" on a 3-line input | "one state per 10 microseconds" ([Geirsson][geirsson], §3.4 n.6)                                              |
| **clang-format** | Linear-ish per unwrapped line                                                       | Bounded only by the 25M-state cap                       | Not published; the two caps are the operative bounds                                                          |
| **dfmt**         | ≤ 1000 pops per line                                                                | ≤ 1000 pops per line                                    | Bounded by construction — dfmt is the only one with a _hard_ bound, bought by giving up completeness outright |

dfmt is the instructive outlier: by capping at 1000 pops over a 32-token window it obtains a
genuine constant-time-per-line bound, at the price of never finding a good layout for a long
line. That is a defensible engineering choice for a batch formatter and a bad one for an
editor — and it is the concrete quality gap [a new D formatter would be measured against][d-landscape].

---

## Where it shows up in practice

| System                       | Search                                                                       | Notes                                                                                               |
| ---------------------------- | ---------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| [clang-format][clang-format] | Dijkstra variant over `LineState`, `std::priority_queue`                     | Two caps; `reconstructPath` walks the `StateNode` chain back                                        |
| [scalafmt][scalafmt-thesis]  | Best-first over `Router` splits                                              | `dequeueOnNewStatements` + further domain optimizations                                             |
| [`dart_style`][dart-style]   | Originally best-first; 3.x rewritten onto a `Piece` tree + explicit `Solver` | Geirsson describes the 2016 version as "a minor variant of the shortest path search in ClangFormat" |
| [dfmt][dfmt]                 | Best-first over a `uint` break bitmask, `RedBlackTree` frontier              | 32-token window; 1000 pops                                                                          |
| **SDC `sdfmt`**              | `rulevalues.d` + `writer.d` — a solver over rule assignments                 | See [the D landscape][d-landscape]                                                                  |

> [!WARNING]
> **The scalafmt material on this page is from the 2016 thesis, not from current source.**
> `$REPOS/scala/scalafmt` is cloned but unread; scalafmt has had a decade of development since.
> Treat every scalafmt claim here as a description of the algorithm _as designed and published
> in 2016_. The same caveat applies to Geirsson's description of `dartfmt`, which `dart_style`
> 3.x has since replaced wholesale — see [its deep-dive][dart-style].

Note the convergence: **five systems, five independent arrivals at the same formulation.**
clang-format's search predates Yelland 2016 and Bernardy 2017 outright. This is the strongest
evidence in the survey that shortest-path-over-break-decisions is the natural formulation once
you want an explicit cost — and it is hard to escape the impression that the literature and the
practice were not reading each other.

---

## Strengths

- **Expressive cost models.** Style preferences become numbers, and awkward cases get a penalty
  rather than a special case in the printer.
- **Alignment and column-dependence are free** — the state already knows its column.
- **The Router/search split** (scalafmt) keeps the optimizer language-agnostic while the
  language knowledge stays in one place.
- **Degrades rather than fails on overflow** — a too-long line costs more, it does not break the
  algorithm.
- **Proven at scale.** clang-format formats LLVM; scalafmt formats the Scala ecosystem. Whatever
  the theoretical objections, these systems work.

## Weaknesses

- **Exponential worst case, triggered by ordinary inputs** (unavoidable overflow).
- **Silently incomplete.** Every member caps the search; none tells the user when the cap bites.
- **Penalty tuning is empirical.** There is no way to predict the effect of a penalty change
  except by running a corpus — which is why these projects all have enormous regression suites.
- **Non-local output**, hostile to minimal diffs and to range formatting.
- **The search is the small part.** Annotation and split generation dominate the code, so
  "we'll just use Dijkstra" badly understates the work.

---

## Key design decisions and trade-offs

| Decision                                               | Rationale                                                                                    | Trade-off                                                                                            |
| ------------------------------------------------------ | -------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| Model layout as **shortest path over break decisions** | Directly expresses "minimize total penalty"; standard algorithms apply                       | State space is `2^tokens`; needs pruning that is not sound in general                                |
| **Explicit penalties** per token class                 | Style becomes data, not code                                                                 | Penalties interact through the search — non-local, empirically tuned, hard to document               |
| **Soft vs hard limit** (dfmt: cost vs `_solved`)       | An unavoidably long line should still get the best available layout                          | Two thresholds to explain, and the hard one still produces unsolved output at the cap                |
| A **hard-coded search budget** (all four)              | Bounds the worst case with one line of code                                                  | Silently non-optimal output; the constant is invisible to users                                      |
| clang-format: **degrade the comparison** at 50k states | Keeps searching rather than aborting, by merging states that differ only in the indent stack | The result may be wrong in exactly the cases the search was needed for                               |
| dfmt: **state = a `uint` bitmask**                     | `opEquals`/`toHash` are free; the frontier is a cheap `RedBlackTree`                         | Hard-caps the window at 32 tokens — a representation choice that became a quality ceiling            |
| scalafmt: **clear the queue at statement boundaries**  | Statements are genuinely independent; turns a global search into per-statement searches      | Not actually sound inside parentheses; required a hand-written exception                             |
| scalafmt: **`Router` / search separation**             | The optimizer never learns the language                                                      | Requires the Router to emit "well-behaved splits"; a bad Router makes the search fail, not just slow |
| clang-format: tie-break **prefers breaking late**      | Deterministic output among equal-cost layouts                                                | A style decision hidden in a queue comparator, unreachable from the option surface                   |

---

## Sources

**Primary — source trees:**

- `clang/lib/Format/UnwrappedLineFormatter.cpp` (1,797 lines) — `analyzeSolutionSpace`,
  `OrderedPenalty`, `StateNode`, `reconstructPath`, and both caps.
  [llvm-project][clang-uf] @ `73802c2e`
- `src/dfmt/wrapping.d` (182 lines) — `State`, `remainingCharsMultiplier`, `newlinePenalty`,
  `ALGORITHMIC_COMPLEXITY_SUCKS`, `chooseLineBreakTokens`, `validMoves`.
  [dfmt][dfmt-wrapping] @ `c65d1c8a` (`v0.15.2-5-g…`)

**Primary — papers:**

- Ólafur Páll Geirsson, _scalafmt: opinionated code formatter for Scala_, MSc thesis, EPFL,
  June 2016 (advisor M. Odersky, supervisor E. Burmako). §§2–4.
  [`geirsson-2016-scalafmt-thesis-epfl.pdf`][geirsson]

**Related deep-dives in this tree:**
[Oppen][oppen] · [Combinators][combinators] · [Optimality][optimality] ·
[clang-format][clang-format] · [dfmt][dfmt] · [dart_style][dart-style] ·
[The D landscape][d-landscape] · [The proposal][proposal]

<!-- References -->

<!-- Papers & external -->

[geirsson]: https://geirsson.com/assets/olafur.geirsson-scalafmt-thesis.pdf
[clang-uf]: https://github.com/llvm/llvm-project/blob/73802c2e9d102a4fb646bc039754779fca3ea476/clang/lib/Format/UnwrappedLineFormatter.cpp
[dfmt-wrapping]: https://github.com/dlang-community/dfmt/blob/c65d1c8a9cd2d784ded4cc7517c2cdd42c0c5c76/src/dfmt/wrapping.d

<!-- Sibling theory docs -->

[theory-index]: ./index.md
[oppen]: ./oppen.md
[combinators]: ./combinators.md
[optimality]: ./optimality.md

<!-- Tree-level docs -->

[d-landscape]: ../d-landscape.md
[baseline]: ../dmd-lsp-baseline.md
[proposal]: ../dmd-fmt-proposal.md

<!-- System deep-dives -->

[clang-format]: ../clang-format.md
[dfmt]: ../dfmt.md
[dart-style]: ../dart-style.md
[scalafmt-thesis]: ../long-tail.md#scalafmt

<!-- Other research trees -->

[diff-review]: ../../diff-review/index.md
