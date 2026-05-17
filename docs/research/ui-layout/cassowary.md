# Cassowary

An incremental linear arithmetic constraint solving algorithm designed for interactive user
interface layout. Cassowary takes a system of linear equalities and inequalities — some
required, some preferred at varying strengths — and finds an assignment of values to
variables that satisfies the required constraints while minimizing violations of the
preferred ones. It is the algorithm that powers Apple's
[Auto Layout](./auto-layout.md), as well as a long tail of constraint-based UI
toolkits.

| Field                     | Value                                                                                                                                                                                                                             |
| ------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Domain                    | Linear arithmetic constraint solving for interactive UI layout                                                                                                                                                                    |
| Authors                   | Greg J. Badros, Alan Borning, Peter J. Stuckey                                                                                                                                                                                    |
| First Published           | 1997 (PhD thesis); 1998 tech report; canonical 2001 ACM TOCHI paper                                                                                                                                                               |
| Algorithmic Basis         | Incremental simplex (primal for `addConstraint`, dual for `resolve`/edit suggestions), Phase I / Phase II, basic-feasible-solved form                                                                                             |
| Reference Implementations | Original C++, Smalltalk, and Java distributions from U. Washington; [`kiwi`](./kiwi.md) (modern C++ reimplementation); `cassowary.py`; CassowaryJS                                                                                |
| Notable Adoption          | Apple Auto Layout (OS X Lion 10.7, 2011; iOS 6, 2012); Matplotlib's `constrained_layout` (via Kiwi); Enaml; GSS / Constraint CSS; Scwm window manager; the Rust `cassowary-rs` / `kasuari` crates used by Ratatui's layout engine |
| Project Home              | <https://constraints.cs.washington.edu/cassowary/>                                                                                                                                                                                |

---

## Overview

### What It Solves

User interface layout is naturally expressed as a system of relationships: this column is
twice as wide as that one; this label sits 8 pixels above that text field; this panel
must be at least 200 pixels tall but should be 400 if it can. Some of these are
non-negotiable; others are preferences that should be honored when there is room. As
the window resizes, the dragged splitter moves, or the user types into a field that grows
its surrounding container, the system must continuously find values that respect the
non-negotiable constraints and best satisfy the preferences.

Box-flow systems like Flexbox, CSS block layout, and Ratatui's percentage/length
constraints handle a useful slice of this problem by composing primitives that each have
a deterministic, local layout rule. They are fast and predictable, but expressing
non-hierarchical relationships — "align the baseline of these two labels living in
different parents" or "the gap between A and B should equal the gap between C and D" —
either requires gymnastics or is outright impossible.

Cassowary takes the more general approach: let the application describe layout as a
**system of linear constraints** and solve the system. The constraint set can include any
linear relationship between variables, regardless of where those variables live in the
view hierarchy. The solver finds an assignment that satisfies all required constraints
exactly while minimizing the weighted sum of violations across non-required constraints,
where each non-required constraint carries a **strength** that determines how it competes
with its peers.

Crucially, the algorithm is **incremental**: adding or removing a single constraint, or
suggesting a new value for an "edit" variable, runs in time proportional to the work
needed to repair the existing solution rather than re-solving from scratch. This is what
makes Cassowary practical for interactive UIs — when the user drags a splitter, the
solver does not re-derive the entire layout; it propagates the change through the system
in a few simplex pivots.

### Design Philosophy

Cassowary is built around three commitments that, together, explain almost every design
choice in the algorithm:

1. **Linear arithmetic only.** Constraints are restricted to linear equalities and
   inequalities over real-valued variables. This excludes products of variables, absolute
   values, conditionals, and disjunctions. The restriction is what makes incremental
   simplex applicable and what keeps the solver tractable. UI layout problems are
   overwhelmingly linear (positions, sizes, gaps, ratios), so the constraint is
   acceptable in practice.

2. **Strengths form a strict hierarchy.** Constraints carry one of four strengths —
   `required`, `strong`, `medium`, `weak` — and any number of `required` violations can
   never be tolerated to satisfy lower-strength preferences. Among non-required
   constraints, a single `strong` outweighs any finite combination of `medium` plus
   `weak`, and a single `medium` outweighs any combination of `weak`. The hierarchy is
   implemented by giving each strength a symbolic weight (lexicographic comparison) so
   that floating-point round-off cannot collapse the ordering. This guarantees that the
   solution is unambiguous and predictable: a designer can layer constraints knowing the
   strong ones will always win.

3. **The solver is interactive, not batch.** Cassowary maintains the simplex tableau
   between operations. `addConstraint`, `removeConstraint`, and `suggestValue` each
   perform a small amount of incremental work to restore the basic-feasible-solved-form
   invariant, then return. Edit variables — variables flagged as the "current mouse x" or
   "current splitter position" — get special-cased so that interactive dragging can fire
   thousands of `suggestValue` calls per second without rebuilding the tableau.

The algorithm is also deliberately deterministic: given the same constraint set and the
same insertion order, it produces the same solution. There is no randomized pivot
selection; ties are broken by a fixed lexicographic rule. This matters because UI
layouts are inspected visually, and any non-determinism — a button shifting by a pixel
between renders — is immediately noticeable and a debugging nightmare.

### History

Cassowary's lineage runs back through three decades of constraint-based UI research at
the University of Washington and elsewhere. Alan Borning's **ThingLab** (1979) was an
early constraint-based simulation environment; **DeltaBlue** (Sannella, Maloney, Freeman-
Benson, Borning, 1993) introduced multi-way constraints over user interface variables
using a local-propagation algorithm. **SkyBlue** generalized DeltaBlue to cyclic
constraint graphs. **Indigo** added inequality constraints. **QOCA** (Marriott, Chok,
Finlay) brought a quadratic optimizing constraint algorithm into the same problem space.

Cassowary itself emerged from Greg Badros's PhD work at U. Washington (advised by Alan
Borning), completed in **1997**. The first public description of the algorithm appeared
in:

- Borning, Marriott, Stuckey, and Xiao, _"Solving Linear Arithmetic Constraints for User
  Interface Applications"_, ACM UIST 1997.

A more thorough treatment followed as a U. Washington tech report:

- Badros and Borning, _"The Cassowary Linear Arithmetic Constraint Solving Algorithm:
  Interface and Implementation"_, Technical Report UW-CSE-98-06-04, 1998.

The canonical reference is the longer 2001 journal version:

- Badros, Borning, Stuckey, _"The Cassowary Linear Arithmetic Constraint Solving
  Algorithm"_, ACM Transactions on Computer-Human Interaction, Vol. 8, No. 4, pp.
  267–306, December 2001.

The original distribution shipped implementations in **Smalltalk**, **C++**, and
**Java**, plus bindings for **GNU Guile**, **Python**, and **STk**. Two contemporary
projects gave Cassowary an immediate audience: the **Amulet** and **Garnet** UI
toolkits from CMU experimented with constraint-based layout, and the **Scwm** (Scheme
Constraints Window Manager) used Cassowary to let users lay out X11 windows by
constraint expressions.

The algorithm's broad public visibility arrived in **2011**, when Apple shipped
[Auto Layout](./auto-layout.md) in OS X 10.7 Lion and, the following year, in iOS 6.
Auto Layout is a Cassowary solver in production: developers describe view layouts as
linear constraints with priorities (Apple's term for strengths), and the system solves
the same kind of tableau Badros described, scaled to entire screenfuls of UIKit views.
The Auto Layout API exposes the same primitives — equalities, inequalities, priorities,
edit-like behavior for the resizing root view — under different names.

After Auto Layout, Cassowary's ideas escaped the desktop. **Grid Style Sheets (GSS)**
and **Constraint Cascading Style Sheets (CCSS)** were attempts to expose constraint
layout to the web. **CassowaryJS** by Alex Russell brought the algorithm to browsers.
And in **2013**, Chris Colbert at Nucleic released [Kiwi](./kiwi.md), a C++
reimplementation that traded the original's exact lexicographic strengths for
floating-point weights in exchange for a 10×–500× speedup; Kiwi is now the de-facto
backend for **Matplotlib**'s `constrained_layout` and `tight_layout`, **Enaml**, and a
long tail of Python UI work. Rust ports (`cassowary-rs`, `casuarius`, `kasuari`) brought
the algorithm to **Ratatui**'s [layout engine](../tui-libraries/ratatui.md).

---

## Algorithm

This section describes the algorithm at the level of detail needed to understand how
Cassowary works, what its operations cost, and why specific design choices were made. It
is not a substitute for the TOCHI paper, but it covers enough that an implementer could
write a from-scratch version and understand a reference one.

### The Simplex Method, in One Paragraph

The simplex algorithm solves linear programs: maximize (or minimize) a linear objective
function over a set of variables subject to linear inequality constraints. It does so by
representing the constraint system as a **tableau** — a matrix of coefficients — and
performing **pivot operations** that exchange a _basic_ (currently solved-for) variable
with a _non-basic_ (currently zero or at a bound) variable. Each pivot preserves the
constraints while moving along an edge of the feasible polytope. The pivot rule is
designed so that the objective function improves (or at least does not worsen) at every
step. The algorithm terminates when no improving pivot exists, at which point the
current vertex is optimal. The worst-case complexity is exponential, but in practice
the simplex method is famously fast on the constraint shapes that arise in real
applications.

Cassowary uses simplex twice over: a **Phase I** simplex finds any feasible solution
(satisfying the inequalities), and a **Phase II** simplex then minimizes a quasi-linear
objective representing the violations of non-required constraints. The novel piece is
that both phases are performed _incrementally_: the algorithm preserves the tableau
across constraint additions, removals, and suggestions, doing only the local pivoting
needed to repair feasibility or optimality.

### Variables, Slack, Error, and Dummy

The solver works with three classes of internal variables beyond the user-facing
**external** variables that the application creates and reads:

- **Slack variables**, introduced one per inequality. The inequality `x + y ≤ 10` is
  rewritten as the equality `x + y + s = 10` with `s ≥ 0`. Slacks are _non-basic_ in
  the initial tableau and only allowed to take non-negative values.

- **Error variables**, introduced for non-required constraints. A non-required equality
  `x = 100` (at some strength `w`) is rewritten as `x - eₚ + eₙ = 100` with
  `eₚ, eₙ ≥ 0`, and the objective is modified to include `w · (eₚ + eₙ)`. A
  non-required inequality `x ≤ 100` becomes `x - eₚ + eₙ + s = 100` with `s ≥ 0` and
  `w · eₙ` in the objective (only the violating direction is penalized). At the
  optimal solution, either `eₚ = 0` or `eₙ = 0`, and the magnitude reflects how far
  the constraint is violated.

- **Dummy variables**, introduced for required equalities. A required equality `x = y`
  becomes `x - y + d = 0` with `d` constrained to zero. Dummies live in the tableau
  to keep equality constraints in normalized form and to track which required
  constraints originated each row, which is needed for `removeConstraint`.

The tableau is then a system of equalities in **basic-feasible-solved form**: every
basic variable appears in exactly one row with coefficient 1, and every non-basic
variable is currently at its bound (0 for slacks, errors, and dummies). The values of
the basic variables are the constants on the right-hand side of their rows. Reading off
a solution is simply: each external variable is either basic (its value is the row's
constant) or non-basic (its value is its bound, almost always 0).

### Strengths as Symbolic Weights

Cassowary represents strengths as 4-tuples of weights — one component per strength level
plus required — compared lexicographically. The strength `strong(w_s)` corresponds to
the vector `(0, w_s, 0, 0)` (interpreting the components as `required`, `strong`,
`medium`, `weak`), `medium(w_m)` to `(0, 0, w_m, 0)`, and so on. The error variables
in the objective function are multiplied by these symbolic strengths, and the simplex
method's pivot rule compares them lexicographically. This guarantees that:

- Any positive amount of `strong` violation is worse than any finite sum of `medium` and
  `weak` violations.
- Any positive amount of `medium` violation is worse than any finite sum of `weak`
  violations.
- Within a single strength level, violations are weighted by an ordinary scalar.

The TOCHI paper proves that under this scheme, the optimal solution has the **error-
hierarchy** property: at the optimum, no non-required constraint can be improved by
worsening only constraints of equal or lower strength. The hierarchy is _strict_:
floating-point arithmetic on a single scalar weight cannot achieve this property
exactly, which is why the original Cassowary uses symbolic 4-vectors. (Kiwi famously
abandons this for floating-point scalars in exchange for a speedup; see
[Kiwi](./kiwi.md).)

### Required Constraints: `addConstraint`, Phase I

Adding a required constraint runs a small **Phase I** simplex:

1. Rewrite the constraint into normal form: introduce slack/dummy as needed, multiply
   through to make all coefficients explicit.

2. Substitute out any external variables that are currently basic. After substitution,
   the new row mentions only non-basic variables on the right-hand side.

3. If the constant on the right is non-negative, the constraint is already feasible
   given current values; add the row to the tableau with a slack/dummy as the new basic
   variable, and we are done.

4. Otherwise the row is infeasible. Introduce an **artificial variable** `a` as the
   initial basic variable for this row (so the row reads `a = ...`), and run Phase I:
   minimize `a` by pivoting it out of the basis. If `a` can be driven to zero, the
   constraint is satisfiable and we are done. If `a` cannot be driven below some
   positive value, the system is over-constrained — the new required constraint
   conflicts with the existing ones. Cassowary throws a `RequiredFailure` exception.

The cost of `addConstraint` is dominated by the number of pivots Phase I needs, which is
small in practice — most additions either fall into case 3 (no pivots needed) or
resolve in one or two pivots.

### Non-Required Constraints: `addConstraint`, Phase II

A non-required constraint adds its error variables to the objective function with the
appropriate symbolic weights, then proceeds as a required constraint over the augmented
system. Since the error variables can absorb any infeasibility (they are unbounded
above), Phase I always succeeds. **Phase II** simplex then minimizes the weighted error
sum by pivoting error variables out of the basis where possible. Pivots proceed until
no improving pivot exists, at which point the optimum has been reached and the basic-
feasible-solved-form is restored.

### Edit Variables and `suggestValue`

Edit variables are the algorithm's interactive workhorse. An application calls
`addEditVar(v, strength)` to mark `v` as a variable whose value will be repeatedly
suggested — typically because the user is dragging it. Cassowary responds by adding two
**edit constraints**: `v = c⁺` and `v = c⁻` (effectively, `v = c`) at the requested
strength, where `c` is a placeholder constant initialized to `v`'s current value. The
constraint introduces a pair of error variables `eₚ, eₙ` that absorb the difference
between the suggested value and the value the rest of the system wants `v` to take.

A subsequent `suggestValue(v, c_new)` is implemented as a **dual simplex** step. The
algorithm updates the row's constant from `c` to `c_new`, which may render the row
infeasible (a basic variable now has a negative value). Rather than re-running Phase I,
Cassowary performs **dual pivots**: it selects the infeasible basic variable to leave
the basis and the entering variable that preserves dual feasibility (the objective
remains optimal). After a small number of pivots — typically one or two — the tableau
is restored to basic-feasible-solved form. The cost is independent of the size of the
constraint system, only proportional to the local rearrangement.

The result is that `suggestValue` is fast enough to call at interactive frame rates.
Auto Layout uses precisely this mechanism for window-resize: the window's width and
height are edit variables, and each pixel of resize fires `suggestValue` calls that
propagate through the entire view hierarchy in microseconds.

### Stay Constraints

A complementary mechanism, **stay constraints**, addresses the under-constrained case.
Suppose the user clicks a button to "lay out the window" with a partial set of
constraints — say, only constraints relating relative positions but nothing absolute.
The system has many solutions; which should it pick? Cassowary's answer: add a `stay`
constraint at `weak` strength for every variable, fixing it to its current value. The
simplex method then finds the solution that minimizes the total displacement from the
current state. Stays are added implicitly during interactive dragging too: every
non-edit external variable gets a weak stay, so that values that _can_ remain at their
current values _do_.

(Notably, Kiwi drops stay constraints in favor of a different strategy — see the Kiwi
doc — but the original Cassowary treats them as a first-class operation.)

### `removeConstraint`

Removing a constraint is conceptually straightforward but mechanically delicate. The
row originating from the constraint must be expunged, but the row may have been pivoted
many times since its addition — its current basic variable may bear no obvious
relationship to the original constraint. Cassowary tracks each constraint's markers
(slack, error, or dummy variables introduced at addition time) so it can find the row
that originated with the constraint. If the marker is currently basic, the row is
simply dropped. If the marker is non-basic, the algorithm pivots the marker into the
basis first (using a carefully-chosen leaving variable to preserve feasibility), then
drops the row. After removal, the objective may no longer be optimal — Phase II is
re-run incrementally.

The trickiest case is **removing a constraint whose marker has been substituted away
entirely** during prior pivots. The implementation searches the tableau for a row
mentioning the marker as a basic variable, or, failing that, picks any row containing
the marker as a non-basic variable, pivots to make the marker basic, and proceeds.

### Complexity, in Practice

The TOCHI paper reports empirical measurements on layout problems with thousands of
constraints. The key observations:

- `addConstraint` averaged a few microseconds on 1998-era hardware. Hot operations were
  dominated by hash-table lookups, not by simplex pivots.

- `suggestValue` was sub-microsecond once the tableau was built — fast enough that the
  bottleneck for interactive dragging became the redraw, not the constraint solve.

- Worst-case behavior was exponential (it is simplex, after all), but the worst-case
  inputs were artificial. Real layouts never approached the worst case.

On modern hardware with [Kiwi](./kiwi.md)'s implementation choices (compact tableaux,
flat arrays instead of hash maps, floating-point strengths), the same operations run
10×–500× faster, putting `suggestValue` in the tens of nanoseconds.

---

## Constraint Language

Cassowary's constraint language is small but expressive. Every concept maps directly to
a piece of the simplex tableau.

### Variables

A **variable** is a real-valued unknown. The application creates variables and hands
them to the solver. After every solve, the solver writes the optimal value back into
each variable. Variables have stable identity — two references to the same variable
participate in the same column of the tableau.

In practice, applications wrap variables in domain objects: a UIKit `NSLayoutAnchor`
points to a variable representing one edge of a view; a Matplotlib `LayoutBox` wraps
four variables (left, right, top, bottom).

### Expressions

An **expression** is a linear combination of variables plus a constant: `a₁·x₁ + a₂·x₂ +
... + aₙ·xₙ + c`. Expressions support the usual arithmetic operators:

- `e₁ + e₂` — sum
- `e₁ - e₂` — difference
- `k · e` or `e · k` — scaling by a scalar
- `e / k` — scaling by `1/k` (division by a non-zero scalar)

Multiplication of two variables is **not** linear and is rejected. Expressions are
typically built using operator overloading or builder methods in whatever host language
the implementation lives in.

### Constraints

A **constraint** is a comparison between two expressions:

- `e₁ == e₂` — equality
- `e₁ <= e₂` — less-than-or-equal
- `e₁ >= e₂` — greater-than-or-equal

Internally, these are normalized to `e == 0` (with slack variables) or `e >= 0` (with a
negated slack). Strict inequalities are not directly supported — linear programming
solves over closed feasibility regions.

### Strengths

Every constraint carries a strength:

- **`required`** — must hold exactly. Infeasibility causes `addConstraint` to fail.
- **`strong`** — should hold; violated only if a higher-strength constraint forces it.
- **`medium`** — should hold; violated only to satisfy `strong` or `required`.
- **`weak`** — a hint; violated freely to satisfy anything stronger.

Strengths may optionally carry a **scalar weight** within their level (`strong(2.0)` vs
`strong(1.0)`), allowing a finer ordering among constraints of the same strength. The
weights are multiplied into the error variable's contribution to the objective.

A typical UI-layout encoding uses `required` for non-negotiable structure (sizes don't
go negative, child fits inside parent), `strong` for designer intent (this section is
60% wide), `medium` for soft sizing hints (preferred width), and `weak` for stays
(prefer to keep current values).

### Edit and Stay Constraints

Two specialized constraint kinds bridge interactive UI patterns:

- **Edit constraints**, attached via `addEditVar(v, strength)`. Each one creates an
  internal `v = c` constraint whose right-hand side can be cheaply updated by
  `suggestValue(v, c_new)`.

- **Stay constraints**, attached via `addStay(v, strength)`. Pins `v` to its current
  value at the given strength (usually `weak`).

Both are syntactic sugar over ordinary constraints, but their dedicated APIs let the
solver use the fast incremental paths.

### Example Encoding

To express "labelA is left-aligned with labelB, and both fit inside their parent panel,
with at least 8 pixels of padding on each side":

```
required: labelA.left == labelB.left
required: labelA.left >= panel.left + 8
required: labelA.right <= panel.right - 8
required: labelB.left  >= panel.left + 8
required: labelB.right <= panel.right - 8
strong:   labelA.width == labelA.intrinsicWidth
strong:   labelB.width == labelB.intrinsicWidth
```

The `required` rows enforce the structural relationships; the `strong` rows express the
labels' content-determined width as a preference that yields if the parent becomes too
narrow.

---

## Code Examples

These examples show how the constraint language expresses common UI layout problems.
Syntax is drawn from the original Cassowary C++ API and Kiwi's Python bindings — see
[Kiwi](./kiwi.md) for runnable code in modern syntax.

### Example 1: Two Views Side-by-Side, Equal Width

The classic split-pane: two children of a parent, occupying its full width with no gap
between them, each consuming exactly half.

```python
# Variables
parent_left  = Variable("parent.left")
parent_right = Variable("parent.right")
a_left  = Variable("a.left")
a_right = Variable("a.right")
b_left  = Variable("b.left")
b_right = Variable("b.right")

# Required: A pinned to parent's left edge
solver.addConstraint(a_left == parent_left)
# Required: B pinned to parent's right edge
solver.addConstraint(b_right == parent_right)
# Required: A and B meet in the middle (no gap)
solver.addConstraint(a_right == b_left)
# Required: equal widths
solver.addConstraint(a_right - a_left == b_right - b_left)

# Strong: parent occupies the window's width
solver.addConstraint((parent_right - parent_left == window_width) | "strong")
solver.addConstraint(parent_left == 0)
```

With six variables and five required equality constraints, the system has one degree of
freedom (the parent's width). The `strong` constraint resolves it: parent gets the
window's width, A gets the left half, B gets the right half.

When the window resizes, the application updates `window_width` and calls
`suggestValue`; Cassowary's dual simplex propagates the change in O(constraints
touching `window_width`) time — a handful of pivots regardless of how big the tableau is.

### Example 2: Sibling Alignment Across Different Parents

A constraint Flexbox cannot easily express: two text fields that live in different
parent containers should have aligned baselines, regardless of how their parents resize.

```python
# Field A is inside containerA, Field B is inside containerB.
# Both containers grow and shrink with the window, possibly at different rates.

containerA_top = Variable("cA.top")
containerB_top = Variable("cB.top")
fieldA_baseline = Variable("fA.baseline")
fieldB_baseline = Variable("fB.baseline")

# Each field is positioned relative to its container.
# The 'baseline_offset' is the typographic baseline from the field's top.
solver.addConstraint(
    fieldA_baseline == containerA_top + a_padding_top + a_baseline_offset
)
solver.addConstraint(
    fieldB_baseline == containerB_top + b_padding_top + b_baseline_offset
)

# The cross-hierarchy alignment is a single required constraint.
solver.addConstraint(fieldA_baseline == fieldB_baseline)
```

If `containerA` and `containerB` resize independently, Cassowary will adjust whichever
variables have the most flexibility (those without strong constraints) to keep the
baselines aligned. If the alignment cannot be achieved without breaking a stronger
constraint, the violation falls on the weakest competing constraint, predictably.

Box-flow systems handle this either by introducing a virtual "alignment group" widget
(Yoga's `alignSelf`, Auto Layout's [`UILayoutGuide`](./auto-layout.md)) or by
pre-computing offsets in user code. Cassowary expresses it as a single equality.

### Example 3: Intrinsic Content Size with Compression Resistance

A `UILabel`-style widget has a natural width that depends on its text content. It would
prefer to be exactly that wide, but it must shrink before it pushes its parent off the
screen — and it must shrink before its sibling, which carries critical information.

```python
# Two labels in a row that must fit in a fixed-width container.
container_width = Variable("container.width")
labelA_width = Variable("labelA.width")
labelB_width = Variable("labelB.width")

# Required: labels and a 4-pixel gap fit exactly in the container.
solver.addConstraint(labelA_width + labelB_width + 4 == container_width)

# Strong: each label prefers its intrinsic content width.
solver.addConstraint((labelA_width == labelA_intrinsic) | "strong")
solver.addConstraint((labelB_width == labelB_intrinsic) | "strong")

# Strong with higher scalar weight: labelB is critical; resist its compression more.
solver.addConstraint((labelB_width == labelB_intrinsic) | strong(weight=2.0))

# Required: neither label can go negative.
solver.addConstraint(labelA_width >= 0)
solver.addConstraint(labelB_width >= 0)
```

When the container is wide enough, both labels get their intrinsic width only if those
preferred widths are compatible with the required equality. If the container width differs
from `labelA_intrinsic + labelB_intrinsic + 4`, the contradiction is resolved by the
`strong` constraints yielding and the solver picks values that minimize the weighted
violation.

When the container is too narrow, both `strong` constraints can't be satisfied, and the
solver minimizes total weighted error: labelB (weight 2.0) shrinks less than labelA
(weight 1.0). This is the **compression resistance priority** that Auto Layout exposes
as `setContentCompressionResistancePriority:`.

### Example 4: Interactive Splitter Drag

A vertical splitter sits between two panels. The user can drag it left or right; both
panels resize to fill the available space. The minimum width of each panel is enforced.

```python
left_edge = Variable("left")
splitter  = Variable("splitter")
right_edge = Variable("right")

# Required: panels are bounded by the window edges and meet at the splitter.
solver.addConstraint(left_edge == 0)
solver.addConstraint(right_edge == window_width)
solver.addConstraint(splitter >= left_edge + 100)   # min 100 for left panel
solver.addConstraint(splitter <= right_edge - 100)  # min 100 for right panel

# Mark splitter as an edit variable for interactive dragging.
solver.addEditVariable(splitter, "strong")

# Initial position
solver.suggestValue(splitter, 400)
solver.updateVariables()

# In the mouse-move handler:
def on_mouse_move(x):
    solver.suggestValue(splitter, x)
    solver.updateVariables()
    # Read updated values; redraw.
    redraw(splitter.value())
```

The dual-simplex path in `suggestValue` makes the mouse-move handler cheap — a handful
of pivots per pixel of drag. The required inequality constraints are enforced by the
solver itself: dragging past the boundary clamps to it automatically (the violation
falls on the edit constraint, which has finite strength, rather than on the required
clamp). This kind of "constraint-driven clamping" is far cleaner than the imperative
`max(min(x, lim), 0)` arithmetic typical of hand-coded layout code.

---

## Bindings / Implementations

Cassowary has been ported to virtually every UI ecosystem. The most notable
implementations:

| Implementation               | Language                    | Notes                                                                                                                                                                                                             |
| ---------------------------- | --------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Original Cassowary           | C++, Smalltalk, Java        | Reference implementations from the U. Washington group, distributed with the TOCHI paper. Includes Guile, Python, STk bindings.                                                                                   |
| Apple Auto Layout            | C / Objective-C / Swift     | Production Cassowary inside UIKit and AppKit since 2011. See [auto-layout.md](./auto-layout.md).                                                                                                                  |
| [Kiwi](./kiwi.md)            | C++ + Python                | Modern reimplementation by Chris Colbert (Nucleic). 10×–500× faster than original Cassowary. Distributed via PyPI as `kiwisolver`. Used by Matplotlib's `constrained_layout`, Enaml, and most current Python UIs. |
| `cassowary.py`               | Pure Python                 | Direct Python translation of the original; mostly historical.                                                                                                                                                     |
| CassowaryJS                  | JavaScript                  | Port by Alex Russell, foundation of Grid Style Sheets (GSS).                                                                                                                                                      |
| `kiwi-js`                    | TypeScript                  | Modern JavaScript port of Kiwi by lume; used by `autolayout.js`.                                                                                                                                                  |
| `autolayout.js`              | JavaScript                  | Hein Rutjes; implements Apple's Visual Format Language (VFL) atop kiwi-js. Now maintained as `lume/autolayout`.                                                                                                   |
| `kiwi-java`                  | Java                        | Alex Birkett's line-for-line Java port of Kiwi C++.                                                                                                                                                               |
| `cassowary-rs` / `casuarius` | Rust                        | Pure-Rust implementations of the original Cassowary, mostly archived.                                                                                                                                             |
| `kasuari`                    | Rust                        | Currently used by [Ratatui](../tui-libraries/ratatui.md) for its `Layout` engine. A `cassowary-rs` fork with bug fixes.                                                                                           |
| Dart `cassowary`             | Dart                        | The Flutter team prototyped a Dart port; ultimately superseded by Flutter's own layout system.                                                                                                                    |
| .NET / C# Cassowary          | C#                          | Multiple community ports of varying maturity.                                                                                                                                                                     |
| Babelsberg                   | Smalltalk, JavaScript, Ruby | Research language integrating Cassowary as a first-class object-constraint feature; Felgentreff et al.                                                                                                            |
| GSS / Constraint CSS         | JavaScript                  | Layout DSL that compiled CSS-like syntax to Cassowary constraints.                                                                                                                                                |
| Scwm                         | Scheme                      | Constraint-based X11 window manager, an early adopter (Badros, Borning).                                                                                                                                          |

The single most-deployed Cassowary in the world is Auto Layout, running in every iOS
and macOS app. The single most-imported Cassowary is Kiwi via `kiwisolver` on PyPI,
which is a transitive dependency of Matplotlib and thus of much of the Python
scientific-computing world.

---

## Strengths and Weaknesses

### For UI Layout

**Strengths.**

- **Expressiveness.** Any linear relationship between layout variables is one
  `addConstraint` call away. Cross-hierarchy alignment, ratio-based sizing, distributed
  spacing, baseline alignment, intrinsic-size with priorities — all natural.

- **Composable.** Constraints can be added and removed independently. A view's layout
  rules are local to the view; combining views combines their constraints. This makes
  Cassowary a good fit for component-based UI frameworks.

- **Predictable conflict resolution.** The strength hierarchy gives designers a clear
  mental model: "stronger always wins". No mystery about which constraint a layout
  engine "chose" — the math determines it.

- **Interactive performance.** `suggestValue` is fast enough for 60fps dragging on
  hardware several decades old. With Kiwi's optimizations, it is fast enough for
  multiple thousands of variables and constraints in real time.

- **Resilient under-determination.** Stays (and the implicit weak stay on every
  variable) keep the layout stable when the constraint set leaves slack: variables
  don't randomly move.

**Weaknesses.**

- **Linearity restriction.** No quadratic constraints, no products of variables, no
  conditional logic. Useful patterns like "centered if there's room, otherwise
  left-aligned" require workarounds (multiple priority levels) or fall outside the
  algorithm.

- **Debuggability is famously poor.** When the solver reports "unable to satisfy
  constraints", finding the offending pair (or triple, or n-tuple) of conflicting
  constraints is hard. Auto Layout's runtime errors of the form _"the constraints
  cannot be simultaneously satisfied"_ are an industry meme. Production solvers
  typically have to hand-craft error reporting because the simplex tableau, mid-pivot,
  is not a useful debugging artifact.

- **Implementation complexity.** A correct Cassowary is a few thousand lines of
  meticulous code: the tableau, the pivot logic, the marker tracking for
  `removeConstraint`, the symbolic strengths. Bugs in implementation are subtle and
  produce ghost layout glitches.

- **Edit-variable plumbing is fiddly.** Forgetting to `addEditVariable` before
  `suggestValue` is a common source of `Failure` exceptions. Production code wraps
  this in higher-level APIs.

### For Static One-Shot Rendering

Cassowary is, in some sense, **overkill** for static rendering — for a single layout
that will not be updated, you do not need incremental updates, you do not need dual
simplex, you do not need edit variables. A batch LP solver would do the same job in
roughly the same time, possibly faster because it can choose the entire pivot order
optimally.

However, even for one-shot rendering, Cassowary's _constraint language_ is valuable:
expressing a complex layout as a system of equalities and inequalities is often easier
than threading it through a box-flow system. The cost of overkill is a few microseconds
per layout — easily affordable.

The reverse case is more interesting: if your layouts will be re-solved many times
(window resize, animation, scrolling reflow), the incremental architecture turns
Cassowary's per-update cost from O(constraints) into O(touched-constraints), which can
be orders of magnitude faster.

### Compared to Box-Flow Systems

| Aspect                        | Box-flow (CSS, Flexbox, Yoga, Ratatui constraints)     | Cassowary                                                             |
| ----------------------------- | ------------------------------------------------------ | --------------------------------------------------------------------- |
| **Expressiveness**            | Limited to hierarchical, axis-aligned flows            | Any linear relation                                                   |
| **Cross-hierarchy alignment** | Requires explicit mechanism (grids, layout guides)     | Natural — single equality                                             |
| **Speed (cold)**              | O(n), single tree traversal                            | O(n) Phase I + Phase II simplex                                       |
| **Speed (incremental)**       | O(subtree of changed node)                             | O(touched constraints) — often less                                   |
| **Cognitive load**            | Low; reuses CSS knowledge                              | Medium; new mental model                                              |
| **Debuggability**             | Generally easy — local rules                           | Generally hard — non-local conflicts                                  |
| **Determinism**               | Strict by definition                                   | Strict by design but harder to predict                                |
| **Production scale**          | All web browsers, [Ink](../tui-libraries/ink.md), Yoga | Auto Layout (billions of devices), Matplotlib (millions of dev users) |

The two approaches are not mutually exclusive. Many modern systems mix them: SwiftUI
uses constraint-style intent expression but compiles to a custom solver that exploits
box-flow when possible; Matplotlib's `constrained_layout` uses Kiwi to handle the
non-trivial alignment cases that the basic grid cannot. Ratatui's percentage-based
`Layout` uses a stripped-down Cassowary solver (`kasuari`) but pre-filters constraints
to keep the hot path linear.

The right tool depends on the layout's complexity. For a header / sidebar / body /
footer dashboard, [Ratatui's box constraints](../tui-libraries/ratatui.md#layout-system)
or [Ink's Flexbox](../tui-libraries/ink.md#layout-system) suffice. For a layout where
a button's right edge aligns with a chart's tick mark, Cassowary earns its keep.

---

## References

### Primary Sources

- Badros, Borning, Stuckey. _"The Cassowary Linear Arithmetic Constraint Solving
  Algorithm."_ ACM Transactions on Computer-Human Interaction (TOCHI), Vol. 8, No. 4,
  pp. 267–306, December 2001.
  <https://constraints.cs.washington.edu/solvers/cassowary-tochi.pdf>

- Badros, Borning. _"The Cassowary Linear Arithmetic Constraint Solving Algorithm:
  Interface and Implementation."_ University of Washington Technical Report
  UW-CSE-98-06-04, 1998.

- Borning, Marriott, Stuckey, Xiao. _"Solving Linear Arithmetic Constraints for User
  Interface Applications."_ ACM Symposium on User Interface Software and Technology
  (UIST '97), 1997.

- Badros, Greg J. _"Extending Interactive Graphical Applications with Constraints."_
  PhD Thesis, University of Washington, 2000.

### Predecessor and Related Work

- Sannella, Maloney, Freeman-Benson, Borning. _"Multi-way versus One-way Constraints
  in User Interfaces: Experience with the DeltaBlue Algorithm."_ Software — Practice
  and Experience, 23(5), 1993.

- Borning. _"The Programming Language Aspects of ThingLab, a Constraint-Oriented
  Simulation Laboratory."_ ACM TOPLAS, 3(4), 1981.

- Marriott, Chok, Finlay. _"A Tableau Based Constraint Solving Toolkit for Interactive
  Graphical Applications."_ International Logic Programming Symposium, 1998. (QOCA)

### Project Home and Online Resources

- Cassowary Constraint Solving Toolkit project page:
  <https://constraints.cs.washington.edu/cassowary/>

- Overconstrained — index of Cassowary implementations:
  <https://overconstrained.io/>

- Wikipedia article: <https://en.wikipedia.org/wiki/Cassowary_(software)>

### Notable Implementations

- Kiwi (C++): <https://github.com/nucleic/kiwi> — see [kiwi.md](./kiwi.md).
- kiwisolver (Python via Kiwi): <https://kiwisolver.readthedocs.io/>
- CassowaryJS: <https://github.com/slightlyoff/cassowary.js>
- kiwi-js: <https://github.com/IjzerenHein/kiwi.js>
- autolayout.js: <https://github.com/lume/autolayout>
- kiwi-java: <https://github.com/alexbirkett/kiwi-java>
- kasuari (Rust, used by Ratatui): <https://github.com/joshka/kasuari>
- cassowary-rs: <https://github.com/dylanede/cassowary-rs>

### Related Documents in This Catalog

- [Apple Auto Layout](./auto-layout.md) — Cassowary's most-deployed production user.
- [Kiwi](./kiwi.md) — the modern C++ reimplementation that dominates Python and other
  ecosystems.
- [Ratatui](../tui-libraries/ratatui.md) — uses a Cassowary variant (`kasuari`) for its
  terminal layout engine.
- [Ink](../tui-libraries/ink.md) — uses Yoga's Flexbox instead, illustrating the
  box-flow alternative.
