# Android ConstraintLayout

A flat-hierarchy, constraint-based layout manager for the Android View system that
replaced years of deeply-nested `LinearLayout` / `RelativeLayout` markup with a single
container whose children position themselves through declarative relationships to
siblings, the parent, virtual guides, and barriers. Internally backed by a solver
derived from the Cassowary linear-arithmetic constraint algorithm.

| Field             | Value                                                                       |
| ----------------- | --------------------------------------------------------------------------- |
| Vendor            | Google (Android / AndroidX)                                                 |
| Language          | Java (consumed from Kotlin and Java); Compose DSL written in Kotlin         |
| License           | Apache 2.0                                                                  |
| Maven coordinates | `androidx.constraintlayout:constraintlayout`                                |
| Compose package   | `androidx.constraintlayout:constraintlayout-compose`                        |
| Repository        | <https://androidx.tech/artifacts/constraintlayout/constraintlayout/>        |
| API reference     | <https://developer.android.com/reference/androidx/constraintlayout/widget/> |
| Version snapshot  | 2.2.1 (View system) / 1.1.1 (Compose, February 2025)                        |
| First release     | ConstraintLayout 1.0 (Google I/O 2017)                                      |

---

## Overview

`ConstraintLayout` is a [`ViewGroup`](https://developer.android.com/reference/android/view/ViewGroup)
introduced as part of [AndroidX](https://developer.android.com/jetpack/androidx) (formerly
Android Support Library) that lets developers express the position and size of every child
view as a set of **constraints** between anchors. An anchor is one of the four edges of a
view (`left`, `right`, `top`, `bottom`), the start/end RTL-aware variants (`start`, `end`),
or the text baseline. Each child must have **at least one horizontal and one vertical
constraint** in order to be positioned; otherwise it falls back to coordinate (0, 0) and the
designer surfaces a lint warning.

The library exists to solve a very specific historical problem on Android: the View system's
older layouts compose by **nesting**. To place three buttons in a row with one centred above
a header you wrote a `LinearLayout(vertical)` containing a `LinearLayout(horizontal)`
containing the buttons, plus another nested layout for the header. Each extra
`ViewGroup` adds a full measure / layout pass over its subtree. Pre-2017 Android codebases
routinely shipped layout XML 6-10 levels deep, with measurable jank during inflation and
scrolling. ConstraintLayout's design goal was to express the same UIs in a **single flat
container** where positioning is described by relationships rather than nesting.

### Where it sits among Android's layout managers

ConstraintLayout is the most recent member of a family of Android View-system layouts. To
understand its design choices it helps to know what came before:

- **`FrameLayout`** -- the simplest container. Children are all stacked on top of each
  other in the top-left corner; positioning is via `layout_gravity` only. Useful for
  single-child overlays (modals, toasts) but offers no real layout logic.
- **`LinearLayout`** -- the workhorse of pre-ConstraintLayout Android. `orientation` is
  either `vertical` or `horizontal`; children flow in that direction. Weights
  (`layout_weight`) distribute leftover space. Nesting (vertical-of-horizontals or
  horizontal-of-verticals) is how you build grids and forms, and that nesting is the
  performance problem ConstraintLayout was created to solve.
- **`RelativeLayout`** -- ConstraintLayout's direct predecessor. Children are positioned
  via attributes like `layout_below="@id/foo"`, `layout_toRightOf="@id/bar"`,
  `layout_alignParentBottom="true"`. The syntax is similar in spirit to ConstraintLayout
  ("position X relative to Y"), but the underlying solver is simpler -- it cannot
  express percent guides, barriers, ratios, or chains, and circular references silently
  fail. ConstraintLayout is essentially RelativeLayout reimagined with a proper
  constraint solver behind it.
- **`GridLayout`** -- a row/column grid container added in API 14. Useful but limited:
  rows and columns are fixed once defined, and `RecyclerView` / `GridLayoutManager` is
  now preferred for any scrolling grid.
- **`TableLayout`** -- a `LinearLayout(vertical)` of `TableRow` children. Mostly
  historical.

ConstraintLayout subsumes the use cases of `RelativeLayout`, most uses of `LinearLayout`,
and many uses of `GridLayout`, while letting you express layouts that none of those could
without nesting (e.g. "this label's left edge tracks whichever of these three labels is
widest"). The Android Studio Layout Editor was rewritten around it: the visual designer
drags constraints onto an anchor diagram and emits the corresponding XML, which made
ConstraintLayout the de facto default for new XML layouts almost immediately after its
release.

### History

- **2016, Google I/O preview.** ConstraintLayout demoed alongside the new Layout Editor.
- **2017, version 1.0.** First stable release. Constraints, guidelines, biases, ratios,
  chains.
- **2018, version 1.1.** Barriers, groups, placeholders, percent dimensions, circular
  positioning.
- **2020, version 2.0.** Major release. Added **MotionLayout** (a subclass that animates
  between `ConstraintSet`s), `Helper` classes (`Flow`, `Layer`), and the foundational
  rewrite that backs the Compose port.
- **2020-2021, ConstraintLayout for Compose.** A Compose DSL with `createRefs()` /
  `constrainAs { }` that exposes the same primitives in Kotlin.
- **2022 onwards.** Maintenance releases (2.1.x, 2.2.x) and continued investment in the
  Compose port (1.0.x -> 1.1.x).

The View-system library is in maintenance mode -- new Android UI development is steered
toward Jetpack Compose -- but ConstraintLayout (both XML and Compose flavours) remains
the recommended choice when constraint-based positioning fits the problem better than
linear flow.

---

## Layout Model

### Anchors and constraints

A constraint is a directional link from one anchor of view A to another anchor of view B
(where B is a sibling, the parent, a guideline, or a barrier). The XML attribute names
encode the source anchor on the left of `_to`, the target anchor on the right, and the
target view ID in the value:

```
app:layout_constraint<SourceEdge>_to<TargetEdge>Of="<targetId|parent>"
```

The full set of attribute pairs:

| Source        | Target attributes                                                                                                     |
| ------------- | --------------------------------------------------------------------------------------------------------------------- |
| `Left`        | `layout_constraintLeft_toLeftOf`, `layout_constraintLeft_toRightOf`                                                   |
| `Right`       | `layout_constraintRight_toLeftOf`, `layout_constraintRight_toRightOf`                                                 |
| `Top`         | `layout_constraintTop_toTopOf`, `layout_constraintTop_toBottomOf`                                                     |
| `Bottom`      | `layout_constraintBottom_toTopOf`, `layout_constraintBottom_toBottomOf`                                               |
| `Start` (RTL) | `layout_constraintStart_toStartOf`, `layout_constraintStart_toEndOf`                                                  |
| `End` (RTL)   | `layout_constraintEnd_toStartOf`, `layout_constraintEnd_toEndOf`                                                      |
| `Baseline`    | `layout_constraintBaseline_toBaselineOf`, `layout_constraintBaseline_toTopOf`, `layout_constraintBaseline_toBottomOf` |
| Circular      | `layout_constraintCircle`, `layout_constraintCircleRadius`, `layout_constraintCircleAngle` (since 1.1)                |

The `Start` / `End` family is **RTL-aware** and is preferred over `Left` / `Right` for
internationalised apps -- the runtime swaps the resolved edges when the layout direction
is right-to-left. `Baseline` aligns text baselines and is the right anchor for putting a
label next to an input field so their text rests on the same line regardless of the views'
heights.

A target value of `"parent"` constrains to the parent `ConstraintLayout`. Otherwise it is
`"@id/<viewId>"` of a sibling.

### Bias

When a view has **two opposing constraints** (e.g. `Start_toStartOf="parent"` and
`End_toEndOf="parent"`) and is sized smaller than the available space, the view is
**centred** by default in the constrained interval. The centre point can be moved using
the bias attribute, a float in `[0.0, 1.0]`:

```xml
app:layout_constraintHorizontal_bias="0.25"   <!-- 25% from the left -->
app:layout_constraintVertical_bias="0.75"     <!-- 75% from the top -->
```

A value of `0` pins to the start edge of the interval, `1` pins to the end, `0.5` centres
(the default).

### Dimension constraints

Each child's `android:layout_width` and `android:layout_height` may take one of three
fundamentally different values inside a `ConstraintLayout`:

- **fixed `dp`** -- a concrete size in density-independent pixels.
- **`wrap_content`** -- shrink to the natural intrinsic size of the content.
- **`0dp` (a.k.a. "match constraints")** -- expand to fill the space between the two
  opposing constraints on that axis. This is the dimension mode that unlocks
  ConstraintLayout's most expressive sizing behaviours.

When width or height is `0dp`, extra attributes control how the view fills the constrained
interval:

| Attribute                              | Meaning                                                                                                                                                  |
| -------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `layout_constraintWidth_default`       | `spread` (fill the entire interval, default), `wrap` (fit intrinsic content but still respect constraints), or `percent` (size as a fraction of parent). |
| `layout_constraintWidth_percent`       | A float in `(0, 1]`. With `default=percent`, the view's width is `percent * parent.width`.                                                               |
| `layout_constraintWidth_min`           | Minimum width in `dp` (only meaningful with `0dp` width).                                                                                                |
| `layout_constraintWidth_max`           | Maximum width in `dp`.                                                                                                                                   |
| `layout_constraintHeight_default` etc. | The same attributes mirrored for the vertical axis.                                                                                                      |

### Aspect ratio

Once **one** dimension is `0dp` (match-constraints) and the other is either fixed or
`wrap_content`, the flexible dimension can be derived from the fixed one via
`layout_constraintDimensionRatio`. The string is `"width:height"` or
`"<lockedSide>,width:height"`:

```xml
android:layout_width="0dp"
android:layout_height="wrap_content"
app:layout_constraintDimensionRatio="16:9"
```

If both dimensions are `0dp` the prefix `"W,..."` or `"H,..."` indicates which axis is
derived from the other.

### Guidelines

A [`Guideline`](https://developer.android.com/reference/androidx/constraintlayout/widget/Guideline)
is an invisible helper view that resolves to a single line at a fixed offset from the
parent's start/top, end/bottom, or as a percentage. Other views constrain to it as if it
were a sibling. The orientation determines whether it is a vertical line (positioned by an
x-offset) or a horizontal line (y-offset):

```xml
<androidx.constraintlayout.widget.Guideline
    android:id="@+id/start_quarter"
    android:layout_width="wrap_content"
    android:layout_height="wrap_content"
    android:orientation="vertical"
    app:layout_constraintGuide_percent="0.25" />
```

The three positioning attributes are mutually exclusive:

- `app:layout_constraintGuide_begin="200dp"` -- offset from the start/top edge.
- `app:layout_constraintGuide_end="80dp"` -- offset from the end/bottom edge.
- `app:layout_constraintGuide_percent="0.5"` -- fraction of the parent's size on that axis.

Guidelines do not render. They are conceptually the same as guides in a vector design
tool.

### Barriers

A [`Barrier`](https://developer.android.com/reference/androidx/constraintlayout/widget/Barrier)
is a virtual anchor that tracks the **extreme edge of a set of referenced views**. The
canonical use case is forms with right-aligned labels of varying widths: you want every
input field's left edge to sit just past the **widest** label, without knowing in advance
which label that is. A barrier pointed `end` and referencing the three labels resolves to
the maximum of their three end edges:

```xml
<androidx.constraintlayout.widget.Barrier
    android:id="@+id/labels_barrier"
    android:layout_width="wrap_content"
    android:layout_height="wrap_content"
    app:barrierDirection="end"
    app:constraint_referenced_ids="label_name,label_email,label_phone" />
```

`barrierDirection` is one of `start`, `end`, `left`, `right`, `top`, `bottom`. A barrier
with direction `bottom` over a set of views resolves to the maximum bottom edge of all
referenced views.

### Chains

A **chain** is a set of two or more views linked by **bidirectional constraints** along an
axis. View A points to view B with `End_toStartOf="B"`, and B points back with
`Start_toEndOf="A"`. Once linked, ConstraintLayout treats the chain as a unit and
distributes the space between the outer anchors among its members. The first view (the
"head") declares the chain style:

```xml
app:layout_constraintHorizontal_chainStyle="spread"
```

Styles:

- **`spread`** (default) -- distribute leftover space evenly **around** all members
  (equal gaps including outside the first and last).
- **`spread_inside`** -- pin the first and last views to the outer constraints; distribute
  leftover space evenly **between** the remaining views.
- **`packed`** -- pack all members together with no gaps; the resulting block is
  positioned within the outer interval according to the horizontal/vertical bias.

Combined with **weights** (`layout_constraintHorizontal_weight` /
`_vertical_weight`) on members whose dimension is `0dp`, chains additionally express
"this row of three buttons divides leftover space 2:1:1". This is the ConstraintLayout
analogue of `LinearLayout`'s `layout_weight`, but with finer control over the
distribution style.

### Groups

A [`Group`](https://developer.android.com/reference/androidx/constraintlayout/widget/Group)
is not a positioning helper -- it is a **visibility multiplexer**. It references a set of
view IDs and applies its own `android:visibility` to all of them. Useful for showing or
hiding a logical cluster of widgets (a form's "advanced options" section, an error
banner's icon + text + retry button) with a single property change:

```xml
<androidx.constraintlayout.widget.Group
    android:id="@+id/advanced_options"
    android:visibility="gone"
    app:constraint_referenced_ids="advanced_label,advanced_field,advanced_help" />
```

Groups have no size and no rendering -- they exist only to forward visibility changes.

### The solver

Under the hood, every constraint, guideline, barrier, chain, ratio, and bias is encoded
into a system of linear equations and inequalities and solved each measurement pass by a
custom **`LinearSystem`** in the `androidx.constraintlayout.core` package. The algorithm
is derived from the
[Cassowary](https://constraints.cs.washington.edu/cassowary/) linear-arithmetic constraint
solver -- the same algorithm family that powers Apple's Auto Layout and the
[`kasuari`](https://crates.io/crates/kasuari) crate used by [Ratatui](../tui-libraries/ratatui.md).
ConstraintLayout's implementation is **not a strict Cassowary port**: it is heavily
optimised for the specific shape of UI-layout problems (small number of variables, tight
real-time deadlines, repeated incremental solves across measure passes) and trades
generality for raw speed. The solver lives in the open-source AndroidX repo and can be
read independently of the View-system glue.

This is the deeper reason ConstraintLayout exists: the View system's `measure` /
`layout` callback contract is inherently top-down and recursive, but constraint-based UI
description is naturally a **whole-graph** problem. By owning the entire flat hierarchy
and solving it as one linear system, ConstraintLayout side-steps the recursive
measure-pass cost that nested layouts pay.

### MotionLayout

[`MotionLayout`](https://developer.android.com/reference/androidx/constraintlayout/motion/widget/MotionLayout)
(version 2.0, 2020) is a subclass of `ConstraintLayout` that **animates between two or
more `ConstraintSet` snapshots**. A `MotionScene` XML file defines the start/end
constraint sets and a `Transition` block describing the animation -- duration, interpolator,
and optional `KeyFrame`s that pin a view to a specific position or rotation at a fraction
of the transition. Because the solver already understands the steady-state layout at any
point in time, MotionLayout just feeds it intermediate `t` values and produces a smooth
interpolation "for free":

```xml
<MotionScene xmlns:motion="http://schemas.android.com/apk/res-auto">
    <Transition
        motion:constraintSetStart="@id/start"
        motion:constraintSetEnd="@id/end"
        motion:duration="800">
        <KeyFrameSet>
            <KeyPosition
                motion:framePosition="50"
                motion:motionTarget="@id/title"
                motion:keyPositionType="parentRelative"
                motion:percentY="0.2" />
        </KeyFrameSet>
    </Transition>

    <ConstraintSet android:id="@+id/start">
        <Constraint android:id="@id/title"
            app:layout_constraintTop_toTopOf="parent" />
    </ConstraintSet>

    <ConstraintSet android:id="@+id/end">
        <Constraint android:id="@id/title"
            app:layout_constraintBottom_toBottomOf="parent" />
    </ConstraintSet>
</MotionScene>
```

`MotionLayout` only animates **position and size** (the things the solver controls). Other
properties (colour, text, alpha) require `CustomAttribute` blocks or external animation
APIs.

### ConstraintLayout for Compose

Jetpack Compose has its own layout primitives (`Row`, `Column`, `Box` -- see
[`jetpack-compose.md`](../ui-layout/jetpack-compose.md)) but for layouts where constraint
relationships are clearer than nested rows and columns, the constraintlayout-compose
artifact provides a Kotlin DSL with the same primitives:

```kotlin
@Composable
fun ProfileCard() {
    ConstraintLayout(modifier = Modifier.fillMaxWidth()) {
        val (avatar, name, handle, bio) = createRefs()

        Image(
            painter = painterResource(R.drawable.avatar),
            contentDescription = null,
            modifier = Modifier
                .size(64.dp)
                .constrainAs(avatar) {
                    top.linkTo(parent.top, margin = 16.dp)
                    start.linkTo(parent.start, margin = 16.dp)
                },
        )

        Text(
            text = "Ada Lovelace",
            style = MaterialTheme.typography.titleMedium,
            modifier = Modifier.constrainAs(name) {
                top.linkTo(avatar.top)
                start.linkTo(avatar.end, margin = 12.dp)
            },
        )

        Text(
            text = "@ada",
            style = MaterialTheme.typography.bodySmall,
            modifier = Modifier.constrainAs(handle) {
                top.linkTo(name.bottom)
                start.linkTo(name.start)
            },
        )

        Text(
            text = "Mathematician and writer, chiefly known for her work on " +
                  "Charles Babbage's Analytical Engine.",
            modifier = Modifier.constrainAs(bio) {
                top.linkTo(avatar.bottom, margin = 16.dp)
                start.linkTo(parent.start, margin = 16.dp)
                end.linkTo(parent.end, margin = 16.dp)
                width = Dimension.fillToConstraints
            },
        )
    }
}
```

The DSL mirrors the XML attributes one-to-one: `linkTo` is the constraint, `width =
Dimension.fillToConstraints` is `0dp` / match-constraints, `Dimension.percent(0.5f)` is
`layout_constraintWidth_percent`, `Dimension.ratio("16:9")` is
`layout_constraintDimensionRatio`. Barriers, guidelines, chains, and groups all have
direct Compose builders (`createStartBarrier`, `createGuidelineFromTop`,
`createHorizontalChain`).

---

## Example: a login form (XML)

The following layout puts an app logo at the top, a username field aligned to a label,
a password field whose label aligns to the widest label, and a submit button stretched
across a chain. All without any nesting:

```xml
<?xml version="1.0" encoding="utf-8"?>
<androidx.constraintlayout.widget.ConstraintLayout
    xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:app="http://schemas.android.com/apk/res-auto"
    android:layout_width="match_parent"
    android:layout_height="match_parent"
    android:padding="24dp">

    <ImageView
        android:id="@+id/logo"
        android:layout_width="0dp"
        android:layout_height="wrap_content"
        android:src="@drawable/logo"
        android:contentDescription="@string/logo_desc"
        app:layout_constraintTop_toTopOf="parent"
        app:layout_constraintStart_toStartOf="parent"
        app:layout_constraintEnd_toEndOf="parent"
        app:layout_constraintWidth_default="percent"
        app:layout_constraintWidth_percent="0.5"
        app:layout_constraintDimensionRatio="W,3:1" />

    <TextView
        android:id="@+id/label_username"
        android:layout_width="wrap_content"
        android:layout_height="wrap_content"
        android:text="@string/username"
        app:layout_constraintTop_toBottomOf="@id/logo"
        app:layout_constraintBaseline_toBaselineOf="@id/field_username"
        app:layout_constraintStart_toStartOf="parent" />

    <TextView
        android:id="@+id/label_password"
        android:layout_width="wrap_content"
        android:layout_height="wrap_content"
        android:text="@string/password"
        app:layout_constraintBaseline_toBaselineOf="@id/field_password"
        app:layout_constraintStart_toStartOf="parent" />

    <androidx.constraintlayout.widget.Barrier
        android:id="@+id/labels_barrier"
        android:layout_width="wrap_content"
        android:layout_height="wrap_content"
        app:barrierDirection="end"
        app:constraint_referenced_ids="label_username,label_password" />

    <EditText
        android:id="@+id/field_username"
        android:layout_width="0dp"
        android:layout_height="wrap_content"
        android:inputType="text"
        android:layout_marginStart="12dp"
        app:layout_constraintTop_toBottomOf="@id/logo"
        app:layout_constraintStart_toEndOf="@id/labels_barrier"
        app:layout_constraintEnd_toEndOf="parent" />

    <EditText
        android:id="@+id/field_password"
        android:layout_width="0dp"
        android:layout_height="wrap_content"
        android:inputType="textPassword"
        android:layout_marginStart="12dp"
        android:layout_marginTop="8dp"
        app:layout_constraintTop_toBottomOf="@id/field_username"
        app:layout_constraintStart_toEndOf="@id/labels_barrier"
        app:layout_constraintEnd_toEndOf="parent" />

    <Button
        android:id="@+id/btn_cancel"
        android:layout_width="0dp"
        android:layout_height="wrap_content"
        android:text="@string/cancel"
        app:layout_constraintTop_toBottomOf="@id/field_password"
        app:layout_constraintStart_toStartOf="parent"
        app:layout_constraintEnd_toStartOf="@id/btn_submit"
        app:layout_constraintHorizontal_chainStyle="spread"
        app:layout_constraintHorizontal_weight="1" />

    <Button
        android:id="@+id/btn_submit"
        android:layout_width="0dp"
        android:layout_height="wrap_content"
        android:text="@string/sign_in"
        android:layout_marginStart="12dp"
        app:layout_constraintTop_toBottomOf="@id/field_password"
        app:layout_constraintStart_toEndOf="@id/btn_cancel"
        app:layout_constraintEnd_toEndOf="parent"
        app:layout_constraintHorizontal_weight="2" />
</androidx.constraintlayout.widget.ConstraintLayout>
```

The same UI written in nested `LinearLayout`s would be a five-deep tree with explicit
weight rows. The `Barrier` removes the need to hard-code label widths, the chain on the
two buttons splits the row 1:2 without an extra container, and the `ImageView` with a
`W,3:1` ratio adapts to any screen width without breaking the rest of the form.

---

## Example: a chain with weights (Compose)

The same chain-of-buttons pattern in Compose:

```kotlin
@Composable
fun SubmitRow(onCancel: () -> Unit, onSubmit: () -> Unit) {
    ConstraintLayout(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 24.dp),
    ) {
        val (cancel, submit) = createRefs()

        // 1:2 weighted horizontal chain across the parent.
        createHorizontalChain(
            cancel, submit,
            chainStyle = ChainStyle.Spread,
        )

        OutlinedButton(
            onClick = onCancel,
            modifier = Modifier.constrainAs(cancel) {
                start.linkTo(parent.start)
                end.linkTo(submit.start, margin = 12.dp)
                width = Dimension.fillToConstraints.atLeast(96.dp)
                horizontalChainWeight = 1f
            },
        ) { Text("Cancel") }

        Button(
            onClick = onSubmit,
            modifier = Modifier.constrainAs(submit) {
                start.linkTo(cancel.end)
                end.linkTo(parent.end)
                width = Dimension.fillToConstraints
                horizontalChainWeight = 2f
            },
        ) { Text("Sign in") }
    }
}
```

`createHorizontalChain` is the Compose equivalent of declaring chain attributes on the
first member. `horizontalChainWeight` corresponds to `layout_constraintHorizontal_weight`,
and `Dimension.fillToConstraints` is `0dp`.

---

## Example: an aspect-ratio media card

A common requirement is "video thumbnail at 16:9, title underneath, byline aligned to the
title baseline, all in a card-width chunk":

```xml
<androidx.constraintlayout.widget.ConstraintLayout
    xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:app="http://schemas.android.com/apk/res-auto"
    android:layout_width="match_parent"
    android:layout_height="wrap_content">

    <ImageView
        android:id="@+id/thumb"
        android:layout_width="0dp"
        android:layout_height="0dp"
        android:scaleType="centerCrop"
        app:layout_constraintTop_toTopOf="parent"
        app:layout_constraintStart_toStartOf="parent"
        app:layout_constraintEnd_toEndOf="parent"
        app:layout_constraintDimensionRatio="H,16:9" />

    <TextView
        android:id="@+id/title"
        android:layout_width="0dp"
        android:layout_height="wrap_content"
        android:layout_marginTop="8dp"
        android:maxLines="2"
        android:ellipsize="end"
        android:textAppearance="?textAppearanceTitleMedium"
        app:layout_constraintTop_toBottomOf="@id/thumb"
        app:layout_constraintStart_toStartOf="parent"
        app:layout_constraintEnd_toStartOf="@id/duration" />

    <TextView
        android:id="@+id/duration"
        android:layout_width="wrap_content"
        android:layout_height="wrap_content"
        app:layout_constraintBaseline_toBaselineOf="@id/title"
        app:layout_constraintEnd_toEndOf="parent" />

    <TextView
        android:id="@+id/byline"
        android:layout_width="0dp"
        android:layout_height="wrap_content"
        android:textAppearance="?textAppearanceBodySmall"
        app:layout_constraintTop_toBottomOf="@id/title"
        app:layout_constraintStart_toStartOf="parent"
        app:layout_constraintEnd_toEndOf="parent" />
</androidx.constraintlayout.widget.ConstraintLayout>
```

The `Baseline_toBaselineOf` constraint between `title` and `duration` keeps the duration
("3:42") sitting on the same text baseline as the first line of the title, regardless of
the two views' actual heights or font sizes. This is exactly the use case the baseline
anchor was designed for.

---

## Strengths and Weaknesses

### Strengths

- **Flat hierarchy, lower measure-pass cost.** A 30-child `ConstraintLayout` measures and
  lays out in a single solver pass over a flat list, where the equivalent nested
  `LinearLayout` design would recurse five layers deep with `weight` measurements
  performed twice per row. Production app teams reported double-digit percent
  improvements in frame timings just from flattening hierarchies during the 2017-2018
  migration wave.
- **Visual designer integration.** The Android Studio Layout Editor was rewritten around
  ConstraintLayout and is genuinely productive: dragging an anchor from one view to
  another emits the correct XML attribute, and the editor surfaces missing-constraint
  lint warnings live. For designer-developer workflows (and for non-Compose teams
  building static screens) this is the main productivity advantage.
- **Expressive primitives.** Guidelines (percent splits), barriers (max-of-set
  alignment), chains (weighted distribution with three distribution styles), ratios
  (`16:9`), and biases compose to handle nearly any positioning requirement without
  fighting the framework. Layouts that would require nesting in `LinearLayout` or
  `RelativeLayout` collapse to a single container.
- **Cassowary-family solver.** Numerically stable, incremental, fast. The same algorithm
  family used by Apple Auto Layout (proven on every iOS screen since 2012) and by
  modern TUI libraries like Ratatui via `kasuari`.
- **RTL-aware out of the box.** Using `Start` / `End` attributes instead of `Left` /
  `Right` makes layouts mirror correctly under right-to-left locales without code
  changes.
- **MotionLayout for "free" animations.** Because the solver already knows the steady
  state of every constraint set, interpolating between two sets is a single API call.
  Complex coordinated animations (a header collapsing, a button morphing, a label
  fading) that would require dozens of `ObjectAnimator` calls become a single XML
  scene.
- **Compose port preserves the model.** The same primitives transferred to the new UI
  toolkit with idiomatic Kotlin syntax (`createRefs`, `constrainAs`, `linkTo`). Teams
  who internalised the XML attribute names find the Compose DSL trivial to adopt.

### Weaknesses

- **XML verbosity.** A single child needs 4-6 `app:layout_constraint*` attributes just to
  position itself. Real-world XML routinely runs 80 characters wide and a hundred lines
  long for a moderate screen. The Layout Editor mitigates this for visual editing, but
  reviewing and merging XML diffs is painful.
- **Cognitive overhead vs simple flow.** For UI that genuinely is "a vertical list of
  three things, all the same width" a `LinearLayout(vertical)` or a Compose `Column` is
  far less code. ConstraintLayout shines when relationships between siblings matter;
  for trivially linear UIs it is overkill.
- **Implicit chain definition.** Chains are formed by **bidirectional constraints**
  without an explicit declaration. A typo on one end silently demotes a chain to two
  ordinary constraints and the layout breaks in subtle ways. The Compose DSL is better
  here because `createHorizontalChain` is an explicit call.
- **Solver behaviour is hard to predict.** When a constraint is over-determined or has
  conflicting requirements, the solver picks **a** solution but not necessarily the one
  a developer expected. Debugging a "this should be on the left, why is it stuck at
  x=0" problem often involves removing constraints one at a time until the broken one
  becomes obvious.
- **Performance trade-off vs Compose.** Compose's layout pipeline is its own thing --
  there is no View-system measure recursion at all -- and for new code, Compose layouts
  (`Row` / `Column` / `Box` / custom `Layout`) are generally preferred over
  ConstraintLayout-for-Compose unless the constraint shape is a genuinely better fit.
- **No equivalent of "flow" or "wrap to next line".** A row of N variable-width chips
  that needs to wrap to the next line when full has no first-class ConstraintLayout
  primitive (the `Flow` helper class in 2.0 partially addresses this but is less
  polished than Compose's `FlowRow`).

### Comparison to neighbours in this catalogue

- vs **Jetpack Compose layouts** ([../ui-layout/jetpack-compose.md](../ui-layout/jetpack-compose.md)) --
  Compose's `Row` / `Column` / `Box` are more declarative for **simple flow**;
  ConstraintLayout (and `ConstraintLayout` for Compose) wins for **complex inter-sibling
  relationships**.
- vs the underlying **Cassowary solver** ([../ui-layout/cassowary.md](../ui-layout/cassowary.md)) --
  ConstraintLayout uses a custom optimised variant rather than a faithful port, biased
  toward UI-shaped problems and incremental re-solves.
- vs **Apple Auto Layout** -- conceptually almost identical: constraints between view
  anchors, bias-equivalent (Auto Layout calls it "priority"), solver-backed. The biggest
  difference is that Auto Layout's constraints are typically built in code, while
  ConstraintLayout's are XML-first (with a strong visual editor).

---

## References

- **ConstraintLayout developer guide** -- <https://developer.android.com/develop/ui/views/layout/constraint-layout>
- **`ConstraintLayout` API reference** -- <https://developer.android.com/reference/androidx/constraintlayout/widget/ConstraintLayout>
- **`Guideline` API reference** -- <https://developer.android.com/reference/androidx/constraintlayout/widget/Guideline>
- **`Barrier` API reference** -- <https://developer.android.com/reference/androidx/constraintlayout/widget/Barrier>
- **`Group` API reference** -- <https://developer.android.com/reference/androidx/constraintlayout/widget/Group>
- **MotionLayout developer guide** -- <https://developer.android.com/develop/ui/views/animations/motionlayout>
- **`MotionLayout` API reference** -- <https://developer.android.com/reference/androidx/constraintlayout/motion/widget/MotionLayout>
- **ConstraintLayout for Compose** -- <https://developer.android.com/develop/ui/compose/layouts/constraintlayout>
- **Source code** -- <https://androidx.tech/artifacts/constraintlayout/constraintlayout/> (also mirrored at <https://android.googlesource.com/platform/frameworks/support/+/refs/heads/androidx-main/constraintlayout/>)
- **Cassowary algorithm overview** -- <https://constraints.cs.washington.edu/cassowary/>
- **Sample code** -- <https://github.com/android/views-widgets-samples/tree/2238cc873501f9cda63605051de11832bb736a8a/ConstraintLayoutExamples>
- **History of Android layout managers** -- "Build a Responsive UI with ConstraintLayout" tutorial archive, Google I/O 2017 talks
