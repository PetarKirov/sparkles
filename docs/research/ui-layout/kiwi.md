# Kiwi

An efficient C++ reimplementation of the [Cassowary](./cassowary.md) linear arithmetic
constraint solving algorithm, with hand-rolled Python bindings. Originally written by
Chris Colbert at Nucleic for the Enaml GUI framework, Kiwi traded the original
Cassowary's lexicographic strength comparison for floating-point scalar weights —
sacrificing a corner-case theoretical guarantee in exchange for a 10×–500× speedup. It
is now the de-facto constraint solver in the Python scientific stack, powering
**Matplotlib**'s `constrained_layout`, **Enaml**, and a long tail of Python UI work.
Ports exist for Java, JavaScript, and TypeScript; the JavaScript port underpins
Apple-Visual-Format-Language layout libraries on the web.

| Field                       | Value                                                                                                                                             |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| Domain                      | Incremental linear arithmetic constraint solving for UI layout and scientific plotting                                                            |
| Authors                     | Chris Colbert (original C++); Nucleic Project maintainers (current); Sébastien Galland and many others                                            |
| Algorithmic Basis           | [Cassowary](./cassowary.md) (Badros, Borning, Stuckey 2001) — incremental simplex, Phase I / Phase II, dual simplex for edit variables            |
| First Released              | 2013 (initial C++ release alongside Enaml)                                                                                                        |
| License                     | BSD 3-Clause                                                                                                                                      |
| Repository                  | <https://github.com/nucleic/kiwi>                                                                                                                 |
| Python Package              | `kiwisolver` on PyPI — <https://pypi.org/project/kiwisolver/>                                                                                     |
| Documentation               | <https://kiwisolver.readthedocs.io/>                                                                                                              |
| Notable Adoption            | Matplotlib (since 2.0, 2017, for `tight_layout` and `constrained_layout`); Enaml; many downstream Python UI frameworks; autolayout.js via kiwi-js |
| Reference for the algorithm | See [cassowary.md](./cassowary.md)                                                                                                                |

---

## Overview

### What It Solves

Kiwi solves the same problem as Cassowary: given a system of linear equality and
inequality constraints — some required, some preferred — find an assignment of values to
variables that satisfies the required ones exactly and minimizes the weighted violation
of the preferred ones. The constraint set may be updated incrementally: adding,
removing, or suggesting a new value for a variable runs in time proportional to the
local change to the system, not its total size.

Unlike Cassowary, which was conceived in a UI-research context and presented as a
self-contained algorithm with a paper to read, Kiwi exists as **a production-grade
library**. The README is short; the documentation is mostly API reference; the C++
header is the spec. Kiwi is built for embedding into other systems — Enaml, Matplotlib,
JavaScript layout engines — where the user does not interact with the solver directly,
but with a domain wrapper (a layout box, a plot axis) that constructs constraints on
their behalf.

The motivating use case at Nucleic was **Enaml**, a declarative Python/Qt GUI framework
where every widget's position is expressed as a set of constraints over its container
and siblings. The original CassowaryJS-style Python solver could not keep up with the
size and update rate Enaml needed, and rebuilding from scratch in optimized C++ was the
practical answer.

### Design Philosophy

Kiwi reflects three philosophical choices that diverge from the original Cassowary:

1. **Strengths are floating-point scalars, not symbolic lexicographic vectors.** The
   TOCHI paper proves that exact strength comparison requires multi-component symbolic
   weights, because otherwise a sufficiently large number of low-strength constraints
   can outweigh a single higher-strength one. Kiwi assigns concrete numbers — `required
= 1000 * (1000² + 1000 + 1) = 1,001,001,000`, `strong = 1000²`, `medium = 1000`,
   `weak = 1` — and uses ordinary floating-point arithmetic. The numbers are spaced so
   that several thousand weak constraints can be summed before they outweigh a medium,
   which is more than enough headroom for any real UI. The simplification is the single
   biggest source of Kiwi's speedup.

2. **Stay constraints are gone.** Where Cassowary uses weak stays to disambiguate
   under-constrained systems (every variable gets a weak stay at its current value),
   Kiwi expects the application to add explicit constraints for variables it wants to
   pin. The reasoning is twofold: the cost of auto-inserting stays for every variable
   is non-trivial; and well-designed constraint systems (Enaml's, Matplotlib's)
   typically constrain every variable explicitly already, making implicit stays
   redundant.

3. **Performance over theoretical correctness in corner cases.** Several details — the
   strength scheme, the choice of `AssocVector` (from Andrei Alexandrescu's Loki
   library) over `std::map` or `std::unordered_map`, the compact symbol representation,
   the inlined symbol comparisons — sacrifice elegance or formal correctness for cache-
   friendly hot paths. The documented Kiwi philosophy is _"in some rare corner cases, a
   large number of weak constraints may outweigh a medium constraint. We believe this
   trade-off is acceptable for the performance gains it provides."_

### History

Kiwi began in early **2013** when Chris Colbert, lead developer of Enaml at Nucleic
Project, needed a faster constraint solver. The existing options were:

- The original Cassowary C++ implementation from U. Washington — accurate but slow on
  modern hardware (the codebase predated modern C++, modern allocators, and modern
  CPU cache hierarchies by a decade).

- `cassowary.py`, a pure-Python translation — far too slow for an interactive GUI
  framework.

Colbert rewrote the algorithm from scratch in C++11, applying performance techniques
learned from his graphics and quant-finance work. The first public release shipped as
part of Enaml. A standalone PyPI package, `kiwisolver`, followed shortly, distributing
the C++ core as a binary wheel with thin Python bindings.

The pivotal moment was **2017**: Matplotlib 2.0 introduced `tight_layout` and, later,
`constrained_layout`, both of which use Kiwi to align subplots, colorbars, titles, and
suptitles. Matplotlib is one of the most-downloaded Python packages in existence — by
making `kiwisolver` a transitive dependency, the Matplotlib team gave Kiwi
distribution into nearly every scientific Python environment.

In parallel, the JavaScript ecosystem produced **kiwi-js**, a TypeScript reimplementation
of Kiwi by Hein Rutjes (later maintained as part of the lume organization), which
became the solver underneath **autolayout.js** — a JavaScript implementation of Apple's
Visual Format Language. Alex Birkett then ported Kiwi line-for-line to Java
(**kiwi-java**) in January 2015, with later bug fixes from yonsunCN and Sam Twidale.

Kiwi continues to be maintained under the **Nucleic** organization on GitHub. Recent
work has focused on Python 3.13 / 3.14 wheel support, removing deprecated APIs, and
fine-tuning the build system for cross-platform reproducibility.

---

## Architecture

This section covers Kiwi's internal architecture: the data structures, the divergences
from Cassowary, and the optimizations that produce its speedup. For the algorithmic
foundation, see the [Cassowary doc](./cassowary.md#algorithm); this section assumes
familiarity with the simplex tableau, basic-feasible-solved form, and edit variables.

### Symbol Encoding

The most idiomatic Kiwi optimization is in how internal variables are represented. Every
variable in the simplex tableau is encoded as a **`Symbol`**, a wrapper around a single
`long long`. The low bits encode a discriminator tag and the rest encode a unique
identifier. The tags are:

- **`v`** (external) — variables created by the application via `Variable(name)`.
- **`s`** (slack) — variables added when normalizing inequality constraints.
- **`e`** (error) — variables added for non-required constraints, paired (`eₚ`, `eₙ`).
- **`d`** (dummy) — added for required equalities; constrained to zero, used to track
  row provenance for `removeConstraint`.
- **`i`** (invalid) — sentinel for missing/empty values.

Because a symbol fits in a CPU register, comparing two symbols is one instruction;
storing a coefficient table indexed by symbol is a flat vector; copying a row of the
tableau is a `memcpy` over contiguous memory. The whole tableau row often fits in one
or two cache lines, which is why hot operations like `addConstraint` and
`suggestValue` are tens of nanoseconds on modern x86.

Compare this to the original Cassowary C++, which used `std::map<Variable*,
LinearExpression*>` for row coefficients: each access was a tree traversal with three
or four pointer chases per node, and most coefficients lived in scattered heap
allocations.

### Internal Classes

The internal C++ structure is small and consistent:

```cpp
class Variable;       // external variable, holds a name and a current value
class Term;           // {Variable, coefficient} pair
class Expression;     // sum of Terms + constant
class Constraint;     // {Expression, RelationalOperator, strength}
class Strength;       // floating-point scalar
class Solver;         // the main interface; owns the tableau

// Internal-only:
class Symbol;         // {discriminator, id} packed into a long long
class Row;            // coefficients indexed by Symbol, plus a constant
class EditInfo;       // tracks an edit variable's marker symbols and current value
```

The user-facing types overload arithmetic and comparison operators, so a constraint can
be written naturally in C++:

```cpp
kiwi::Variable x("x"), y("y");
kiwi::Constraint c = (x + 2 * y >= 10) | kiwi::strength::strong;
```

### AssocVector for Hot Tables

Internally, Kiwi maintains a few mappings:

- `rows`: `Symbol -> Row` (the tableau itself, indexed by basic variable)
- `vars`: `Variable -> Symbol` (which symbol represents each external variable)
- `edits`: `Variable -> EditInfo` (per-edit-variable metadata)
- `infeasible_rows`: a list of rows whose basic variable currently has a negative value

These were initially `std::map`s, then `std::unordered_map`s. The current implementation
uses **`AssocVector`** — a sorted-vector–backed associative container from Andrei
Alexandrescu's Loki library, which Kiwi vendors. The choice is documented as a "2x
speedup" over `std::map` in their benchmarks. The reasoning is straightforward: maps
small enough to fit in L1 cache pay more in pointer chasing than they save in
asymptotic complexity. For the sizes typical in UI layout (tens to hundreds of
constraints per panel), a sorted vector wins.

### Simplex Operations

The simplex operations themselves mirror the [Cassowary algorithm](./cassowary.md#algorithm)
closely. The main entry points on `Solver` are:

- **`addConstraint(Constraint)`** — Phase I for required constraints; Phase II for non-
  required. Throws `UnsatisfiableConstraint` if a required constraint conflicts.
- **`removeConstraint(Constraint)`** — Locates the row originating from the constraint
  (via marker symbols stored at addition time), pivots if needed to make the marker
  basic, drops the row, then runs Phase II to restore optimality.
- **`addEditVariable(Variable, Strength)`** — Adds an internal constraint `v = c` at
  the requested strength and records the variable as editable.
- **`suggestValue(Variable, double)`** — Updates the constant on the edit constraint,
  then runs **dual simplex** to restore feasibility. Cheap; designed for interactive
  mouse-move callbacks.
- **`updateVariables()`** — Reads the current basic-feasible-solved-form and writes
  each external variable's value into its `Variable` object. Decoupled from solving so
  that batches of suggestions can be made before a single value-update sweep.

Internally, the solver also exposes `dump()` / `dumps()` for debugging, which prints
the current tableau in a human-readable form.

### Constraint Validation: A Deliberate Omission

When a constraint is removed, Kiwi does **not** check whether the variables in the
constraint are still referenced by other constraints. The user can hold a `Variable`
object whose name is in the tableau, but if every constraint referencing it has been
removed, the solver simply forgets about it. Re-adding a constraint with the same
`Variable` re-introduces it. This is an intentional choice — validating reuse on every
removal would require a reference-count pass that is expensive relative to the removal
itself, and the cost of getting it wrong is small.

### Differences from Cassowary, Summary

| Aspect                           | Original Cassowary                             | Kiwi                                                              |
| -------------------------------- | ---------------------------------------------- | ----------------------------------------------------------------- |
| Strength representation          | Symbolic 4-tuple (required, strong, med, weak) | Floating-point scalar; values widely spaced                       |
| Strength comparison              | Lexicographic                                  | Numeric                                                           |
| Stay constraints                 | First-class operation                          | Removed; application must encode explicitly                       |
| Tableau row storage              | `std::map<Variable*, ...>` or similar          | `AssocVector` over `Symbol` (sorted vector of pairs)              |
| Internal variable representation | `Variable*` (pointer per coefficient)          | `Symbol` = `long long` (one register)                             |
| Edit-variable plumbing           | Manual `addEditVar` / `beginEdit` / `endEdit`  | Single `addEditVariable` + `suggestValue` calls                   |
| Removal validation               | Validates variable references                  | Does not validate (faster, but mild footgun)                      |
| Languages                        | C++, Smalltalk, Java + bindings                | C++ core, Python (hand-rolled CPython API), with downstream ports |

The cumulative effect, on the benchmarks Kiwi's authors report, is **10× to 500× speedup
over original Cassowary**, with typical use cases (Enaml-style GUI constraint systems)
landing around **40×**. Memory use is similarly improved — Kiwi reports **5× or more**
reduction in working-set size.

---

## Constraint Language

The constraint language is the same as Cassowary's — equalities and inequalities over
linear expressions with strengths — and the Python binding lifts it to a natural
operator-overloaded form. This section concentrates on Kiwi-specific surface details.

### Variables

```python
from kiwisolver import Variable

x = Variable("x")
y = Variable("y")
```

A `Variable` carries a name (for debugging) and an updateable double-precision value.
The application reads `x.value()` after `solver.updateVariables()` to get the current
assignment.

### Expressions

Expressions are built using overloaded arithmetic operators:

```python
expr = 2 * x + 3 * y - 5
```

The result is an `Expression` — a sum of terms (variable, coefficient) and a constant.
Multiplication by another variable raises an exception: linearity is enforced at the
operator-overload level.

### Constraints

Constraints come from comparison operators:

```python
c1 = x + y == 10       # equality
c2 = x >= 0            # inequality
c3 = 2 * x - y <= 100  # inequality on a compound expression
```

In Python, the `__eq__` / `__le__` / `__ge__` operators on `Variable` and `Expression`
return `Constraint` objects, not booleans. (This is the standard Cassowary trick; it
means you cannot use a `Variable` as a dictionary key with `==` semantics without
care.)

### Strengths

Kiwi exposes four named strength constants plus the ability to construct custom
strengths from component weights:

```python
from kiwisolver.strength import required, strong, medium, weak, create

# Built-in:
#   required ≈ 1.001e9      (overwhelmingly dominant)
#   strong   ≈ 1.0e6
#   medium   ≈ 1.0e3
#   weak     ≈ 1.0

# Custom strength with explicit components:
custom = create(1.0, 0.5, 2.0)   # strong=1, medium=0.5, weak=2 → 1,000,502
```

The pipe operator `|` attaches a strength to a constraint:

```python
soft_constraint = (x == 100) | "weak"
also_soft = (x == 100) | weak
multiplied = (x == 100) | (strong * 2)   # strong with weight 2
```

A constraint without an explicit strength is **required**.

### Edit Variables

The edit-variable workflow:

```python
solver.addEditVariable(x, "strong")
solver.suggestValue(x, 42.0)
solver.updateVariables()
print(x.value())   # → 42.0 (if no stronger constraint disagrees)
```

`addEditVariable` may only be called once per variable. `suggestValue` may be called
any number of times after that. `removeEditVariable` retires the edit.

### Operator Summary

| Operator | On                                  | Produces     | Meaning                      |
| -------- | ----------------------------------- | ------------ | ---------------------------- |
| `+`, `-` | `Var`/`Expr`                        | `Expression` | Linear combination           |
| `*`      | `Var` / scalar                      | `Expression` | Scaling by a constant        |
| `/`      | `Var` / scalar                      | `Expression` | Scaling by `1/k`             |
| `==`     | `Expr`/`Expr`                       | `Constraint` | Required-by-default equality |
| `<=`     | `Expr`/`Expr`                       | `Constraint` | Less-than-or-equal           |
| `>=`     | `Expr`/`Expr`                       | `Constraint` | Greater-than-or-equal        |
| `\|`     | `Constraint` / strength             | `Constraint` | Attach strength              |
| `\|`     | `Constraint` / `(strength, weight)` | `Constraint` | Scaled strength              |

---

## Code Examples

The examples below use the Python binding (`kiwisolver` on PyPI), which is by far the
most-used surface. Equivalent C++ uses the same API names with `kiwi::` namespace
prefixes.

### Example 1: Centered Element Inside a Container

A common layout: a child element should be horizontally centered inside its parent
container, with both edges respecting a minimum margin.

```python
from kiwisolver import Variable, Solver

solver = Solver()

# Variables
parent_left  = Variable("parent.left")
parent_right = Variable("parent.right")
child_left   = Variable("child.left")
child_right  = Variable("child.right")

# Required: parent is anchored at 0, with width 200
solver.addConstraint(parent_left == 0)
solver.addConstraint(parent_right == 200)

# Required: minimum 10-pixel margin on each side
solver.addConstraint(child_left  >= parent_left + 10)
solver.addConstraint(child_right <= parent_right - 10)

# Required: child must have positive width
solver.addConstraint(child_right >= child_left)

# Strong: child is centered in parent
solver.addConstraint(
    (child_left + child_right == parent_left + parent_right) | "strong"
)

# Medium: child prefers its intrinsic width of 80
solver.addConstraint((child_right - child_left == 80) | "medium")

solver.updateVariables()
print(f"child: [{child_left.value()}, {child_right.value()}]")
# child: [60.0, 140.0]
```

The interplay of strengths drives the result: the required constraints set up the
boundary conditions; the strong centering constraint says "if you can center it,
center it"; the medium intrinsic-width constraint says "and prefer to be 80 wide".
Both are satisfiable simultaneously here, so both win. If the parent shrank to a width
of 30, the required margins would force the child to fit in 10 pixels, both `strong`
and `medium` constraints would yield, and the solver would minimize their combined
weighted error.

### Example 2: Mid-Point Variable (Classic Cassowary Demo)

A faithful reproduction of the example in Kiwi's own README — three variables on a
number line, with a midpoint constrained to lie at the average of two endpoints.

```python
from kiwisolver import Variable, Solver

solver = Solver()

x1 = Variable("x1")
x2 = Variable("x2")
xm = Variable("xm")

# Required: x1 stays non-negative; x2 stays bounded; xm sits between
solver.addConstraint(x1 >= 0)
solver.addConstraint(x2 <= 100)
solver.addConstraint(x2 >= x1 + 10)
solver.addConstraint(xm == (x1 + x2) / 2)

# Weak: prefer x1 to be 40 (a soft hint)
solver.addConstraint((x1 == 40) | "weak")

# Edit variable: we'll drag xm interactively
solver.addEditVariable(xm, "strong")
solver.suggestValue(xm, 60)
solver.updateVariables()

print(f"x1={x1.value()}, x2={x2.value()}, xm={xm.value()}")
# x1=40.0, x2=80.0, xm=60.0  (the weak hint succeeds)

# Now drag xm further right; x1 will be pushed away from its weak preference
solver.suggestValue(xm, 90)
solver.updateVariables()
print(f"x1={x1.value()}, x2={x2.value()}, xm={xm.value()}")
# x1=80.0, x2=100.0, xm=90.0  (x2 hits its ceiling, weak hint yields)
```

This example shows the canonical "interactive drag with soft preferences" workflow.
The `weak` constraint on `x1` is a hint that the solver honors when there is room, but
yields when stronger constraints (the inequality `x2 <= 100`) would otherwise be
violated. Each `suggestValue` runs a dual-simplex repair, which is cheap regardless of
tableau size.

### Example 3: Equal-Spacing of a Row of Items

A horizontal toolbar of `n` buttons, evenly distributed across a container width.
Box-flow systems express this with `space-between`; Cassowary expresses it as a
constraint.

```python
from kiwisolver import Variable, Solver, strength

def setup_toolbar(n_buttons, container_width):
    solver = Solver()
    container = Variable("container")
    solver.addConstraint(container == container_width)

    buttons = []
    for i in range(n_buttons):
        left  = Variable(f"btn{i}.left")
        right = Variable(f"btn{i}.right")
        buttons.append((left, right))
        # Required: each button has a fixed width of 60
        solver.addConstraint(right - left == 60)

    # Required: first button against left edge, last against right edge
    solver.addConstraint(buttons[0][0] == 0)
    solver.addConstraint(buttons[-1][1] == container)

    # Required: each gap is equal to the previous gap
    gaps = []
    for i in range(n_buttons - 1):
        gap = buttons[i + 1][0] - buttons[i][1]   # left of next minus right of this
        gaps.append(gap)
    for i in range(len(gaps) - 1):
        solver.addConstraint(gaps[i] == gaps[i + 1])

    # Weak: prefer non-negative gaps (helps when over-constrained)
    for gap in gaps:
        solver.addConstraint((gap >= 0) | strength.weak)

    solver.updateVariables()
    return [(l.value(), r.value()) for (l, r) in buttons]

print(setup_toolbar(5, 400))
# [(0.0, 60.0), (85.0, 145.0), (170.0, 230.0), (255.0, 315.0), (340.0, 400.0)]
```

With five buttons of width 60 in a 400-wide container, the total button width is 300
and the remaining 100 splits into four 25-pixel gaps. The constraint system encodes
"every gap equals every other gap" rather than computing the gap directly. As
`container` changes, a single `addEditVariable(container, "strong")` plus
`suggestValue` calls would re-flow the toolbar with one dual-simplex repair per pixel.

### Example 4: Matplotlib-Style Subplot Alignment

A simplified version of what Matplotlib's `constrained_layout` does internally:
align two subplots so that their inner axes start at the same x-coordinate,
regardless of how wide their tick labels are.

```python
from kiwisolver import Variable, Solver, strength

solver = Solver()

# Subplot 1: outer bounding box and inner axes box
sp1_left  = Variable("sp1.outer.left")
sp1_axes_left = Variable("sp1.axes.left")
sp1_tick_label_width = 30  # measured from rendered text

# Subplot 2: same
sp2_left  = Variable("sp2.outer.left")
sp2_axes_left = Variable("sp2.axes.left")
sp2_tick_label_width = 45  # wider y-tick labels

# Required: each axes box is offset from its outer box by the tick label width
solver.addConstraint(sp1_axes_left == sp1_left + sp1_tick_label_width)
solver.addConstraint(sp2_axes_left == sp2_left + sp2_tick_label_width)

# Required: subplot 1's outer left is the figure left
solver.addConstraint(sp1_left == 0)

# Required: subplot 2 sits to the right of subplot 1 with a 50px gap
sp1_right = Variable("sp1.outer.right")
solver.addConstraint(sp1_right == 200)
solver.addConstraint(sp2_left == sp1_right + 50)

# STRONG: prefer the two axes boxes to start at the same offset within their subplot
# (Equivalent to "align the y-axes")
solver.addConstraint(
    (sp1_axes_left - sp1_left == sp2_axes_left - sp2_left) | "strong"
)

solver.updateVariables()

print(f"sp1: outer.left={sp1_left.value()}, axes.left={sp1_axes_left.value()}")
print(f"sp2: outer.left={sp2_left.value()}, axes.left={sp2_axes_left.value()}")
```

In this scenario the **strong** axes-alignment constraint will be **violated**, because
the tick label widths differ and the required positions of the outer boxes are fixed.
Kiwi's solver reports the optimal solution — minimum weighted violation — and the
application can render with the offsets as computed.

If the application wanted the alignment to win at the cost of subplot positioning, the
strengths would flip: make alignment `required` and the gap-between-subplots `strong`.
This is how Matplotlib's `constrained_layout` handles the choice: by making layout
constraints `required` and aesthetic constraints `strong` or `medium`, it gets
deterministic alignment with graceful degradation under tight space.

---

## Bindings / Implementations

Kiwi proper is **C++ + Python**, distributed as the `kiwisolver` package on PyPI. The
package ships pre-built wheels for Linux, macOS, and Windows across Python 3.9 through
3.14, eliminating compilation from the dependency-installation path. This is the
overwhelming majority of Kiwi installations: pulled in transitively by Matplotlib,
which itself is on the order of 30+ million monthly downloads.

| Implementation     | Language               | Notes                                                                                                                                                    |
| ------------------ | ---------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Kiwi (core)        | C++ 11                 | <https://github.com/nucleic/kiwi> — header-only, BSD-3-Clause. Embeds in any C++ project.                                                                |
| `kiwisolver`       | Python via CPython API | <https://pypi.org/project/kiwisolver/> — hand-rolled CPython binding (not `pybind11`/`cython`).                                                          |
| `kiwi-js`          | TypeScript             | <https://github.com/IjzerenHein/kiwi.js> — TypeScript port; foundation of autolayout.js. Now maintained as `lume/kiwi`.                                  |
| `autolayout.js`    | JavaScript             | <https://github.com/lume/autolayout> — Apple Visual Format Language on top of kiwi-js. Hein Rutjes.                                                      |
| `kiwi-java`        | Java                   | <https://github.com/alexbirkett/kiwi-java> — line-for-line Java port. Alex Birkett, with fixes from yonsunCN and Sam Twidale.                            |
| Various Rust ports | Rust                   | The Rust ecosystem mostly uses `cassowary-rs` / `kasuari` (port of original Cassowary, not Kiwi). [Ratatui](../tui-libraries/ratatui.md) uses `kasuari`. |

The C++ core is **header-only** in the sense that the entire solver compiles as a small
set of templates and headers; the Python binding adds a thin CPython-extension layer.
There is no shared library to link against — `#include <kiwi/kiwi.h>` and you have the
solver.

### Notable Adopters (Python Ecosystem)

- **Matplotlib** (since 2.0, 2017) — uses Kiwi for `tight_layout` and the more general
  `constrained_layout` to position axes, colorbars, titles, suptitles, and legends.
  This is the most widely distributed adoption: nearly every scientific Python
  installation has `kiwisolver` installed transitively.

- **Enaml** — Nucleic's declarative GUI framework. The original motivating use case.
  Every Enaml widget's geometry is a constraint system; Kiwi solves it on every layout
  pass.

- **Atom (text editor)** had an Enaml prototype, indirectly using Kiwi.

- **Conda / mamba** ship `kiwisolver` as a dependency of `matplotlib` in the default
  scientific channel.

### Notable Adopters (JavaScript Ecosystem)

- **autolayout.js / lume/autolayout** — implements Apple's Visual Format Language
  layout for web/JavaScript, using kiwi-js under the hood. Used by various Famo.us-
  successor and node-graph UI projects.

- **GSS (Grid Style Sheets)** — historically used CassowaryJS, but later iterations
  experimented with kiwi-js for performance.

---

## Strengths and Weaknesses

### For UI Layout

**Strengths.**

- **Performance.** The 10×–500× speedup over original Cassowary turns the constraint
  solver from a measurable cost into invisible plumbing. Matplotlib's
  `constrained_layout` is fast enough to enable by default; Enaml supports thousands
  of widgets without layout lag.

- **Production-grade.** Kiwi has been in continuous production at Nucleic since 2013
  and as a Matplotlib dependency since 2017, debugged across millions of layout
  scenarios. Edge cases that fresh Cassowary implementations stumble on are well-worn.

- **Predictable.** Same constraint set, same insertion order → same solution. The
  floating-point strength scheme is _technically_ less robust than symbolic
  lexicographic comparison, but in practice the strength values are spaced so widely
  that the documented corner case (thousands of `weak` outweighing one `medium`)
  occurs only in synthetic stress tests.

- **Easy embedding.** Header-only C++ with no external dependencies. The CPython
  binding is a single shared library wheel per platform/version, fast to import, no
  compilation needed for users.

- **BSD license.** Permissive; safe to vendor into proprietary projects.

**Weaknesses.**

- **No stay constraints.** This is the single biggest gotcha for developers porting
  from Cassowary or Auto Layout. An under-constrained Kiwi system has _no_ preferred
  resting state; values can land anywhere consistent with the constraints. Applications
  must add explicit `(v == current_value) | weak` constraints to pin variables, which
  amounts to reimplementing stays themselves.

- **Floating-point strength corner case.** Mathematically, a `medium` constraint
  should beat any number of `weak` constraints; in Kiwi, with strength values
  `medium = 1000` and `weak = 1`, summing ~1000+ weak violations equals one medium.
  The documentation acknowledges this. Real UI layouts never hit it, but a synthetic
  benchmark or pathological auto-generated constraint set could.

- **Edit-variable lifecycle is manual.** Forgetting to `addEditVariable` before
  `suggestValue` raises an exception. Forgetting to `removeEditVariable` when the
  interactive operation ends leaves the soft constraint in place, possibly subtly
  distorting future layouts.

- **Removal does not validate variable references.** As described in
  [Architecture](#architecture), removing a constraint does not check whether other
  constraints still reference the variables. A removed variable that re-emerges later
  via a new constraint is treated as a fresh introduction — usually fine, but
  surprising if you assumed `Variable` identity preserved internal state across
  removal cycles.

- **No debugging tools beyond `dump()`.** Like Cassowary, Kiwi inherits the
  "unsatisfiable constraints" debugging problem. The `dump()` method prints the
  current tableau, which is useful for solver implementers but rarely actionable for
  layout authors trying to figure out which constraint pair is in conflict. (Auto
  Layout's runtime debugging messages are themselves famously hard to read; this is a
  Cassowary-family problem, not a Kiwi-specific one.)

### For Static One-Shot Rendering

For one-shot layouts, Kiwi is **excellent** — possibly even more so than original
Cassowary. The fixed overhead of building the tableau is small enough that
`constrained_layout` runs it for every Matplotlib figure render without noticeable
cost. Matplotlib explicitly uses Kiwi this way: there is no interactive dragging in
plot rendering; the solver runs once per `savefig` or `draw`.

The incremental machinery is unused in this case, but pays no penalty: the algorithm
_is_ the incremental algorithm, run once on an empty initial state. There is no
"batch solve" mode to switch into.

### Compared to Box-Flow Systems

| Aspect                         | Box-flow (CSS / Yoga / [Ratatui](../tui-libraries/ratatui.md))                             | Kiwi                                               |
| ------------------------------ | ------------------------------------------------------------------------------------------ | -------------------------------------------------- |
| **API surface**                | Layout-specific (`flex`, `align`, `padding`)                                               | Generic (variables, expressions, constraints)      |
| **Cross-hierarchy alignment**  | Awkward or impossible                                                                      | Single equality constraint                         |
| **Speed (single layout)**      | O(n) tree pass                                                                             | Few-microseconds simplex on small tableau          |
| **Speed (incremental update)** | O(touched subtree)                                                                         | O(touched constraints) via dual simplex            |
| **Footprint**                  | Often zero extra deps (built into [Ink](../tui-libraries/ink.md), Yoga, etc.)              | One `kiwisolver` import                            |
| **Programming model**          | Declarative widget tree                                                                    | Imperative constraint addition                     |
| **Best for**                   | Hierarchical layouts: dashboards, lists, forms                                             | Non-hierarchical alignment, plotting, complex DAGs |
| **Used by**                    | Browsers, [Ink](../tui-libraries/ink.md), [Ratatui (partial)](../tui-libraries/ratatui.md) | Matplotlib, Enaml, autolayout.js                   |

The defining feature of Kiwi-style layout is that **the constraint system is not tied
to the widget tree**. Two views in different parents can be aligned by adding one
equality constraint; in a box-flow system, the same effect requires restructuring the
tree or introducing a coordinating widget. The cost is the imperative API — Kiwi gives
you a `Solver` to mutate, not a tree to declare.

For terminal UIs where the layout maps naturally onto a tree (header / body / footer;
sidebar / content), box-flow is the right tool —
[Ratatui's `Layout`](../tui-libraries/ratatui.md#layout-system) (which itself wraps a
slimmed-down Cassowary in `kasuari`, never exposing the constraint API) and
[Ink's Flexbox](../tui-libraries/ink.md#layout-system) suffice. For terminal layouts
where, say, a status bar item needs to line up with a column header three panels over,
embedding Kiwi directly is the cleaner answer than weaving alignment-through-the-tree
helpers.

---

## References

### Project and Source

- Kiwi repository: <https://github.com/nucleic/kiwi>
- Kiwi documentation: <https://kiwisolver.readthedocs.io/>
- `kiwisolver` on PyPI: <https://pypi.org/project/kiwisolver/>
- Nucleic Project umbrella: <https://github.com/nucleic>

### Documentation Pages

- Basic concepts and API: <https://kiwisolver.readthedocs.io/en/latest/basis/basic_systems.html>
- Solver internals: <https://kiwisolver.readthedocs.io/en/latest/basis/solver_internals.html>
- Getting started (installation, basics): <https://kiwisolver.readthedocs.io/en/latest/basis/index.html>

### Algorithmic Foundations

- See [cassowary.md](./cassowary.md) for the algorithm Kiwi implements, including the
  TOCHI paper and related work.
- Badros, Borning, Stuckey, _"The Cassowary Linear Arithmetic Constraint Solving
  Algorithm"_, ACM TOCHI Vol. 8 No. 4, 2001:
  <https://constraints.cs.washington.edu/solvers/cassowary-tochi.pdf>

### Notable Adopters

- Matplotlib: <https://matplotlib.org/>
  - `constrained_layout` guide: <https://matplotlib.org/stable/users/explain/axes/constrainedlayout_guide.html>
  - The `tight_layout` and `constrained_layout` code paths in `lib/matplotlib/_constrained_layout.py` exercise Kiwi extensively.
- Enaml: <https://github.com/nucleic/enaml>
- autolayout.js: <https://github.com/lume/autolayout>

### Ports

- kiwi-js / TypeScript: <https://github.com/IjzerenHein/kiwi.js>
- kiwi-java: <https://github.com/alexbirkett/kiwi-java>

### Related Documents in This Catalog

- [Cassowary](./cassowary.md) — the algorithm Kiwi implements, with full algorithmic
  detail.
- [Apple Auto Layout](./auto-layout.md) — the production Cassowary at the foundation of
  iOS / macOS UI; uses a different implementation (Apple's own) but the same algorithm.
- [Ratatui](../tui-libraries/ratatui.md) — uses `kasuari`, a Cassowary port, for
  terminal layout; an interesting comparison point for what a slimmed-down Cassowary
  looks like in a different ecosystem.
- [Ink](../tui-libraries/ink.md) — uses Flexbox (Yoga) instead, illustrating the
  box-flow alternative to constraint-based layout.
