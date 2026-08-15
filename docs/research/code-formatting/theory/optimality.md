# Optimality — What "Best" Means, and Whether You Can Have It

Greedy [combinators][combinators] pick the first layout that fits. This family asks the
question that provokes: _fits_ is a feasibility test, not a quality measure, so among the many
layouts that fit, which is best — and what does it cost to actually find it? Four papers give
four answers, and they do not agree on the objective, let alone the algorithm. The payoff for
a formatter designer is a precise vocabulary: **"optimal" is meaningless until you name the
objective**, and the three objectives in circulation — _lexicographic overflow_, _height_, and
_arbitrary cost_ — are genuinely different problems with genuinely different complexities.

## At a glance

| Dimension         | Where the optimal-layout family lands                                                                                                                          |
| ----------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Input**         | A `Doc`-like tree (or DAG) with **arbitrary choice** between alternatives, not just `group`'s binary flat/broken                                               |
| **Objective**     | Explicit and minimized, not implicit: minimum lines ([Bernardy][bernardy]), a linear cost ([Yelland][yelland]), or a user-supplied cost factory ([APEP][apep]) |
| **Decision rule** | Global — dynamic programming ([Yelland][yelland], [Podkopaev][apep]), Pareto frontiers ([Bernardy][bernardy]), or a measure-set DP ([APEP][apep])              |
| **Time**          | O(n̂^3/2) (Yelland) · O(nW⁶) (Bernardy) · O(nW⁴) (Π_e) — see [the complexity table](#the-field-in-one-table)                                                    |
| **Space**         | Superlinear in every member; none is streaming                                                                                                                 |
| **Alignment**     | **First-class** — the capability Wadler dropped and this family restores                                                                                       |
| **Verified?**     | Π_e's validity and optimality are machine-checked in **Lean** ([APEP][apep], Abstract) — the only formatter in this survey that is                             |
| **Ships in**      | `rfmt` (R, Google), `PrettyExpressive` → **Racket's `fmt`**, `dart_style`'s solver (independently), [clang-format][clang-format]'s A\* (independently)         |

> [!NOTE]
> This is the [theory tree][theory-index] entry for **exact** layout selection. Its sibling
> [cost & search][cost-search] covers the same objective pursued _approximately_ by shipping
> formatters — clang-format's Dijkstra, scalafmt's search, dfmt's capped best-first — and the
> budget each spends on incompleteness. Read [combinators][combinators] first: this page is
> largely a critique of it, and Wadler's narrow definition of "optimal" is the thing being
> argued with.

---

## Overview / motivation

### Three different things called "optimal"

The literature's most persistent confusion, and the one this page exists to dissolve.
[APEP][apep] supplies the taxonomy in its comparison table, naming each printer's
"minimization objective":

| Objective                  | Means                                                                                    | Held by                                                                                                     |
| -------------------------- | ---------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| **Lexicographic overflow** | Avoid overflowing the width limit whenever possible; among such layouts, nothing further | Oppen, Hughes, Wadler, Leijen, Chitil, Kiselyov — i.e. all of [combinators][combinators] and [Oppen][oppen] |
| **Height**                 | Among layouts with no overflow past `W`, minimize the number of lines                    | Swierstra, Podkopaev & Boulytchev, Bernardy                                                                 |
| **Cost**                   | Minimize a user-supplied cost function over the layout                                   | Yelland (a fixed linear cost), Π_e (a pluggable cost factory)                                               |

Wadler's own definition — "optimal if it chooses line breaks so as to avoid overflow whenever
possible" ([Wadler][wadler], §5) — is _exactly_ the first row, and APEP's name for it,
**lexicographic overflow**, is the precise formalization. Under that objective Wadler's greedy
printer is genuinely optimal. Under either of the other two it is not, and cannot be. Nothing
in the literature is wrong here; the word is simply overloaded, and every claim of optimality
must be read with its objective attached.

### Bernardy: the specification greed cannot meet

[Bernardy 2017][bernardy] states three principles and then shows that no greedy algorithm
satisfies them:

> "**Principle 1. Visibility** A pretty printer shall layout all its output within the width of
> the page.
> **Principle 2. Legibility** A pretty printer shall make appropriate use of layout, to make it
> easy for a human to recognize the hierarchical organization of data.
> **Principle 3. Frugality** A pretty printer shall minimize the number of lines used to display
> the data." — [Bernardy 2017][bernardy], §1

with a strict priority order — Visibility over Legibility over Frugality. The abstract states
the consequence bluntly:

> "This paper proposes a new specification of pretty printing which is stronger than the state
> of the art: we require the output to be the shortest possible, and we also offer the ability
> to align sub-documents at will. We argue that our specification **precludes a greedy
> implementation**. Yet, we provide an implementation which behaves linearly in the size of the
> output." — [Bernardy 2017][bernardy], Abstract

The argument is a crafted S-expression (`testData`, §3) printed at width 20. Hughes' library
produces a layout wasting vertical space, and Bernardy diagnoses it precisely — quoting
**Hughes' own justification for going greedy**:

> "Hughes states that 'it would be unreasonably inefficient for a pretty-printer to decide
> whether or not to split the first line of a document on the basis of the content of the
> last.' (sec. 7.4 of his paper). Therefore, he chooses a greedy algorithm, which processes the
> input line by line, trying to fit as much text as possible on the current line, without regard
> for what comes next." — [Bernardy 2017][bernardy], §3.1

and then generalizes the failure into the sentence that should be pinned above any formatter
designer's desk:

> "In our example, the algorithm can fit `(abcdefgh ((a` on the sixth line, but then it has
> committed to a very deep indentation level, which forces to display the remainder of the
> document in a narrow area, wasting vertical space. Such a waste occurs in many real examples:
> **any optimistic fitting on an early line may waste tremendous amount of space later on.**"
> — [Bernardy 2017][bernardy], §3.1

This is [Oppen's own §8 counterexample][oppen-limits] — indent the `cases` block less and the
`if…then…else` fits — restated 37 years later with a proof obligation attached. The
counterexample was never in dispute; what Bernardy adds is that it is _typical_, not exotic.

**The mechanism.** Bernardy keeps, for each sub-document, not one layout but the set of layouts
that are not dominated by another on (width, height) — the **Pareto frontier** (§5.4). Because
domination is a partial order, the frontier is usually small, and concatenation of frontiers is
cheap. This is the paper's real contribution: an exact method whose cost tracks how much genuine
choice the document contains rather than how many choices it syntactically offers.

### Yelland: an explicit cost function and plain dynamic programming

[Yelland 2016][yelland] comes at it from Google's R formatter, `rfmt`, and makes a different
move: rather than a lexicographic principle order, **one scalar cost**, minimized by DP.

> "rfmt … embodies a language-independent approach to source code layout that seeks an
> 'optimal' rendering of a program with respect to an intuitively-appealing notion of layout
> cost." — [Yelland 2016][yelland], §1

The key structural idea is that the cost of a sub-layout depends on **one parameter**: the
column it starts at. So each layout expression is associated with

> "Key to the use of dynamic programming in this application is the association of a layout
> expression with a function—call it the layout's **minimum cost function**—that maps a column
> to the minimum cost incurred by the layout when started at that column."
> — [Yelland 2016][yelland], §2

and these compose by induction over concatenation. The representation that makes it tractable
is the paper's engineering contribution: the minimum cost function is approximated by
**piecewise-constant "layout functions" defined on a set of _knots_** — "a positive integer
representing a starting column for a layout; the knots of a layout function represent starting
columns at which the value of the function changes" (§3). A function over 0…W collapses to a
handful of breakpoints, so the DP manipulates small objects.

Yelland is also unusually explicit about how his approach differs from the industrial
alternative, and the passage is the best available bridge between this page and
[cost & search][cost-search]:

> "Rather than assuming a fixed output width and optimizing layout cost conditional on
> satisfying the width restriction, here output width is constrained by the cost function
> itself, which affords us a greater degree of flexibility (such as the ability to insert a
> 'soft margin'). Finally, we use dynamic programming directly to optimize cost, instead of the
> more indirect approach taken by clang-format (Dijkstra's algorithm itself involving a form of
> dynamic programming)." — [Yelland 2016][yelland], §1.1

A **soft margin** — a cost that rises steeply past the limit rather than a hard constraint — is
only expressible because the width lives in the objective rather than in the feasible set. That
is a genuinely useful capability for a code formatter (a 101-column line is better than a
mangled layout) and it is unavailable to every printer whose objective is lexicographic
overflow.

### Π_e: pluggable objectives, machine-checked

[Porncharoenwase, Pombrio & Torlak 2023][apep] frames the whole design space as a three-way
trade-off and then claims to dominate it:

> "Pretty printers make trade-offs between the **expressiveness** of their pretty printing
> language, the **optimality objective** that they minimize when choosing between different ways
> to lay out a document, and the **performance** of their algorithm. This paper presents a new
> pretty printer, Π_e, that is strictly more expressive than all pretty printers in the
> literature and provably minimizes an optimality objective. Furthermore, the time complexity of
> Π_e is better than many existing pretty printers." — [APEP][apep], Abstract

Two things are new and both matter here. First, the **cost factory**: the objective is a
parameter, not a constant. "When choosing among different ways to lay out a document, Π*e
consults a user-supplied cost factory, which determines the optimality objective, giving Π_e a
unique degree of flexibility." Yelland made the cost explicit; Π_e makes it \_pluggable*, which
is what a formatter that wants configurable style actually needs.

Second, and unique in this entire survey: **the correctness proof is machine-checked.** "We use
the Lean theorem prover to verify the correctness (validity and optimality) of Π_e." No other
system surveyed here — academic or industrial — has a mechanized proof that its printer emits
an optimal layout.

The paper also reports real adoption: "PrettyExpressive … serves as a foundation of a code
formatter for Racket."

---

## The field in one table

[APEP][apep]'s Table 1 is the most useful single artifact in this literature — a uniform
comparison of every printer on expressiveness, objective, and complexity. Reproduced here
because it is the spine of this page (`n` = DAG size of the document, `n̂` = tree size, which
"in the worst case is exponential in `n`"; `W` = width limit):

| Printer                       | Choice    | Concatenation | Minimization objective       | Time complexity |
| ----------------------------- | --------- | ------------- | ---------------------------- | --------------- |
| Oppen [1980]                  | Group     | Unaligned     | Lexicographic overflow       | O(n)            |
| Hughes [1995]                 | Group     | Aligned       | Lexicographic overflow       | O(n²)           |
| Wadler [2003]                 | Group     | Unaligned     | Lexicographic overflow       | O(n²)           |
| Leijen [2000]                 | Group     | Both          | Lexicographic overflow       | O(n²)           |
| Chitil [2005]                 | Group     | Unaligned     | Lexicographic overflow       | O(n)            |
| Kiselyov et al. [2012]        | Group     | Unaligned     | Lexicographic overflow       | O(n)            |
| Swierstra et al. [1999]       | Arbitrary | Aligned       | Height †                     | Exp. in n       |
| Podkopaev & Boulytchev [2015] | Arbitrary | Aligned       | Height †                     | O(n̂W⁴)          |
| Yelland [2016]                | Arbitrary | Aligned       | Linear cost                  | O(n̂^3/2)        |
| Bernardy [2017]               | Arbitrary | Aligned       | Height †                     | O(nW⁶)          |
| **Π_e**                       | **Both**  | **Both**      | Cost (from the cost factory) | **O(nW⁴)**      |
| Π_e (aligned only)            | Both      | Aligned       | Cost (from the cost factory) | O(nW³)          |

<sub>† "only consider layouts without an overflow past W." — [APEP][apep], Table 1</sub>

Three readings worth extracting:

1. **The `group` → `Arbitrary` jump is where the cost is.** Everything in the top block is
   linear or quadratic; everything with arbitrary choice pays a `W`-power factor. Binary
   `group` is not a limitation the field failed to notice — it is what buys the complexity.
2. **Aligned concatenation is orthogonal to choice, and Wadler dropped it.** Hughes had it,
   Wadler traded it away for the single-monoid algebra ([combinators][combinators]), Leijen
   added it back, and every member of this family has it. It is not a luxury: it is `f(a,` /
   `      b)`.
3. **DAG vs tree is a real asymptotic difference.** Podkopaev & Boulytchev's `O(n̂W⁴)` uses the
   _tree_ size, which "could be exponentially larger than its DAG size"; Π_e's `O(nW⁴)` uses
   the DAG size. Same exponent, potentially exponentially different in practice.

### Podkopaev & Boulytchev, from the outside

> [!WARNING]
> **This paper is not held locally.** Podkopaev & Boulytchev 2015 is Springer-only (LNCS 8974,
> PSI 2014) with no located preprint. Everything this survey says about it is sourced from
> [APEP][apep]'s account, which is detailed and is itself a peer-reviewed primary source about
> it — but it is second-hand and is marked as such in this tree's internal ledger.

APEP's account: Swierstra's arbitrary-choice printers were exponential; "Podkopaev and
Boulytchev [2015] improved upon Swierstra et al.'s work by **formulating the problem as dynamic
programming**. This fixes the exponential blowup in the prior work, but treats the document as a
tree, making its time complexity O(n̂W⁴) … The paper acknowledges the problem and surmises that
memoization may be able to address it." So its place in the lineage is: _first to make
arbitrary-choice printing polynomial_, and the direct ancestor of both Yelland's and Π_e's DP
formulations.

### The Knuth–Plass delta

TeX's paragraph breaker is the obvious ancestor and Yelland names it: the approach "expanded
upon by Knuth and Plass (1981), uses dynamic programming to minimize the sum" of per-line
badness ([Yelland][yelland], §1.1). This survey does **not** re-derive it —
[`ui-layout/tex-knuth-plass.md`][knuth-plass] already covers the DP, badness and demerits in
detail. What matters here is only the delta, and it is sharper than it looks:

| Knuth–Plass (prose)                                       | Code layout                                                                                           |
| --------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| Break points are positions in a glue/box stream           | Break points are **structural** — determined by the tree, not by where whitespace happens to fall     |
| Glue stretches and shrinks; hyphenation adds break points | Neither exists; a token is a token                                                                    |
| Line cost depends only on that line's contents            | Line cost depends on the **indentation**, which depends on breaks chosen **earlier**                  |
| Optimal substructure holds ⇒ clean O(n·breakpoints) DP    | Optimal substructure **does not hold on line index alone** — the state must carry the starting column |

That last row is the whole story. Knuth–Plass can do a DP over "best way to reach breakpoint
`i`" because a line's badness is independent of the history. In code layout, choosing to break
early changes the indentation of everything after, so the sub-problem is "best layout of this
sub-document **starting at column c**" — which is exactly why Yelland's DP state is a _function
of the starting column_ and why every complexity in the table above carries a factor of `W`.
Knuth–Plass's optimal-substructure argument does not transfer; the `W` powers are the price of
repairing it.

---

## Power & limits

**What this family buys.** Layouts that greedy printers provably cannot reach, alignment as a
first-class operator, cost functions that can encode real style preferences (prefer breaking
before an operator; penalize a break inside a call's arguments; tolerate a soft margin), and —
in Π_e's case — a mechanized guarantee that the result is optimal for the stated objective.

**What it costs, and why almost nobody ships it.**

1. **Complexity in `W`.** `O(nW⁴)` at W=100 is a factor of 10⁸ against `n`. In practice these
   printers are fine (the constants are small, and Bernardy's Pareto frontiers stay tiny), but
   nobody can promise a latency bound, which is disqualifying for a formatter on the LSP
   keystroke path. This is the single strongest argument for greedy in an editor.
2. **Non-locality is a feature _and_ a defect.** An exact printer may re-lay-out a distant part
   of the document because of a change here. For a batch formatter that is correctness; for a
   version-controlled codebase it is [diff churn][diff-review], and for an incremental
   formatter it defeats [range formatting][spine] outright.
3. **Fragility of the sharing.** APEP's post-mortem of Bernardy is instructive: in the paper the
   width limit is hard-coded, which lets Haskell share computations across sub-documents; the
   real implementation makes it a parameter, and "this change destroys the shared computations,
   leading to exponential running time". Bernardy subsequently "abandoned the arbitrary-choice
   operator, noting that it could trigger the exponential behavior". The theory's guarantees are
   sensitive to implementation choices that look innocuous.
4. **Still silent on comments.** Every paper here inherits [Hughes' scope disclaimer][hughes-remark].
   Yelland is the only one who even acknowledges it, in a footnote (see below) — and then sets
   it aside.

**The one paper that notices the gap.** Yelland's footnote 1 is worth quoting in full, because
it is the sole point in the _theory_ literature where the code-formatting/pretty-printing
distinction is stated by someone building a real code formatter:

> "Hughes (1995) draws a distinction between between [sic] pretty printing, which he reserves for the legible
> rendering of internal data structures, and source code formatting—improving the readability of
> program text. As he observes, the latter involves considerations such as the proper placement
> of comments (which are regarded as extra-syntactic constructs in most languages). In this
> paper, we use the terms interchangeably, since the intent is to describe the layout algorithm
> used by the source code formatter rfmt." — [Yelland 2016][yelland], §1.1 n.1

"We use the terms interchangeably" is the field's standard move, and it is exactly the move a
real formatter cannot make.

---

## Performance & complexity

Beyond the table: what actually matters for choosing an engine is not the exponent but **where
the work goes**.

- **Bernardy** — work ∝ the size of the Pareto frontiers, which is data-dependent and usually
  far below the worst case. Excellent when the document offers few genuinely incomparable
  layouts; degenerate when it offers many.
- **Yelland** — work ∝ the number of knots, i.e. the number of columns at which the answer
  actually changes. Also data-dependent, and the knot representation is the cheapest of the
  three to implement.
- **Π_e** — work ∝ DAG size × W⁴, with sharing preserved by construction rather than by luck.
  The most robust bound, and the only one that survives making the width a parameter.
- **All three** are whole-document: no streaming, no bounded space, no partial output. Against
  [Oppen's O(w) space][oppen], that is the trade.

---

## Where it shows up in practice

| System                                  | Relationship                                                                                                                                   |
| --------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| **`rfmt`** (R, Google)                  | Yelland's algorithm, as published                                                                                                              |
| **`PrettyExpressive`** → Racket's `fmt` | Π_e, as published; "it serves as a foundation of a code formatter for Racket" ([APEP][apep], Abstract)                                         |
| **`dart_style` 3.x**                    | Independently arrived at an explicit `Solver` over a `Piece` tree with n-way constraints — see [its deep-dive][dart-style]                     |
| **[clang-format][clang-format]**        | Independently: Dijkstra over break states with a penalty model. Yelland classifies it as the "more indirect approach" to the same optimization |
| **[scalafmt][cost-search]**             | Independently: search with state dedup and a timeout — an _approximate_ member of this family                                                  |
| **prettier, rustfmt, gofmt, dfmt**      | Not members. All greedy or heuristic; see [combinators][combinators] and [cost & search][cost-search]                                          |

The pattern is worth naming: **the exact algorithms are published by academics and shipped by
almost no one, while the industrial systems that want the same result reinvent it approximately
and cap it with a timeout.** That gap is the subject of [cost & search][cost-search], and it is
the most decision-relevant fact on this page for [the D proposal][proposal].

---

## Strengths

- **Names the objective.** Even if you ship greedy, this literature forces you to say what you
  were approximating — and "lexicographic overflow" vs "height" vs "cost" is a real distinction
  that changes output.
- **Restores alignment** as a first-class operator, which `nest`-only algebras cannot express.
- **Soft margins and tunable style** become expressible once width lives in the objective
  rather than the constraint (Yelland; Π_e's cost factory).
- **Π_e is verified.** Validity and optimality are Lean-checked — unique in this survey.
- **Data-dependent, not worst-case, in practice.** Pareto frontiers and knot sets are small on
  real documents.

## Weaknesses

- **No latency bound worth stating.** `W`-power complexities are fine in batch and unsafe on a
  keystroke path.
- **Non-local output.** A local edit can re-lay-out distant code — churn, and hostile to range
  formatting.
- **Guarantees are implementation-fragile** (APEP's account of Bernardy's width parameter).
- **No streaming, no bounded space.** The whole document, always.
- **Comments and trivia still out of scope**, inherited from [the Hughes remark][hughes-remark];
  Yelland notes it and moves on.

---

## Key design decisions and trade-offs

| Decision                                                           | Rationale                                                                            | Trade-off                                                                              |
| ------------------------------------------------------------------ | ------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------- |
| **Arbitrary choice** instead of binary `group`                     | Expresses layouts `flatten x <\|> x` cannot, and makes alignment usable              | Every complexity in the table jumps by a `W` power; this is where the cost comes from  |
| State the objective **explicitly** (height, or a cost)             | Makes "optimal" a checkable claim rather than a word                                 | Commits you to one notion of prettiness — until Π_e makes it a parameter               |
| **Pareto frontiers** (Bernardy)                                    | Cost tracks genuine incomparability, not syntactic choice count                      | Worst case O(nW⁶); sharing is easy to destroy by parameterizing the width              |
| **Piecewise-constant cost-vs-column functions on knots** (Yelland) | A function over 0…W collapses to a few breakpoints; the DP manipulates small objects | Restricts the cost to shapes the knot representation can express                       |
| Width in the **objective**, not the constraint (Yelland, Π_e)      | Enables soft margins; a slightly-over line beats a mangled layout                    | Loses the hard guarantee that output never exceeds `W`                                 |
| A **cost factory** as a parameter (Π_e)                            | One printer serves many styles; the objective becomes configuration                  | The optimality theorem is now relative to a factory the user can get wrong             |
| **Mechanized proof** (Π_e, Lean)                                   | Optimality claims in this area are subtle and easy to get wrong                      | Large up-front cost; nobody else has paid it                                           |
| Documents as **DAGs**, not trees (Swierstra, Π_e)                  | Shared sub-documents are shared computations; `n` instead of `n̂`                     | Requires an explicit sharing construct in the language (a `let`), complicating the API |

---

## Sources

**Primary:**

- Jean-Philippe Bernardy, _A Pretty But Not Greedy Printer (Functional Pearl)_, PACM PL 1(ICFP),
  Article 6, September 2017, 22 pp. [`bernardy-2017-…-icfp.pdf`][bernardy]
- Phillip M. Yelland, _A New Approach to Optimal Code Formatting_, Google Inc., 2016.
  [`yelland-2016-…-google.pdf`][yelland]
- Sorawee Porncharoenwase, Justin Pombrio & Emina Torlak, _A Pretty Expressive Printer_,
  PACM PL 7(OOPSLA2), Article 261, October 2023, 34 pp. [`porncharoenwase-2023-…-oopsla.pdf`][apep]
- Philip Wadler, _A prettier printer_ — for the contrasting definition of "optimal". [`wadler-1998-…pdf`][wadler]

**Cited but not held locally:**

- Anton Podkopaev & Dmitri Boulytchev, _Polynomial-Time Optimal Pretty-Printing Combinators with
  Choice_, PSI 2014, LNCS 8974, pp. 257–265. Springer-only; **no preprint located**. All claims
  here are via [APEP][apep] §2 and Table 1. A companion implementation exists at
  [`prettyPrinting/format`][pp-format].

**Related deep-dives in this tree:**
[Oppen][oppen] · [Combinators][combinators] · [Cost & search][cost-search] ·
[Layout preservation][layout-preserving] · [Knuth–Plass (ui-layout)][knuth-plass] ·
[clang-format][clang-format] · [dart_style][dart-style] · [The proposal][proposal]

<!-- References -->

<!-- Papers & external -->

[bernardy]: https://jyp.github.io/pdf/Prettiest.pdf
[yelland]: https://static.googleusercontent.com/media/research.google.com/en//pubs/archive/44667.pdf
[apep]: https://arxiv.org/pdf/2310.01530
[wadler]: https://homepages.inf.ed.ac.uk/wadler/papers/prettier/prettier.pdf
[pp-format]: https://github.com/prettyPrinting/format

<!-- Sibling theory docs -->

[theory-index]: ./index.md
[oppen]: ./oppen.md
[oppen-limits]: ./oppen.md#power--limits
[combinators]: ./combinators.md
[hughes-remark]: ./combinators.md#the-remark-that-defines-this-surveys-gap
[cost-search]: ./cost-and-search.md
[layout-preserving]: ./layout-preserving.md

<!-- Tree-level docs -->

[spine]: ../index.md#taxonomies
[proposal]: ../dmd-fmt-proposal.md

<!-- System deep-dives -->

[clang-format]: ../clang-format.md
[dart-style]: ../dart-style.md

<!-- Other research trees -->

[knuth-plass]: ../../ui-layout/tex-knuth-plass.md
[diff-review]: ../../diff-review/index.md
