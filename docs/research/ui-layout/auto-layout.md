# Auto Layout (Apple UIKit / AppKit)

Apple's constraint-based layout system, in production on iOS since 2012 and macOS since 2011. Built on the Cassowary linear-arithmetic solver, refined through three major API
generations -- raw `NSLayoutConstraint`, the Visual Format Language, and the modern
`NSLayoutAnchor` fluent API -- and capped with `UIStackView` as the high-level wrapper
that most modern code uses.

| Field             | Value                                                                |
| ----------------- | -------------------------------------------------------------------- |
| Platform          | iOS 6+, iPadOS, macOS 10.7+, tvOS, watchOS, visionOS                 |
| Frameworks        | UIKit (iOS family), AppKit (macOS)                                   |
| Language          | Objective-C originally; Swift APIs since iOS 8 / Swift 1             |
| Underlying Solver | Cassowary (incremental linear-arithmetic solver)                     |
| First Released    | macOS 10.7 Lion (2011), iOS 6 (2012)                                 |
| Anchors API       | iOS 9 / macOS 10.11 (2015)                                           |
| UIStackView       | iOS 9 / macOS 10.11 (2015)                                           |
| Documentation     | <https://developer.apple.com/documentation/uikit/nslayoutconstraint> |
| Modern Successor  | SwiftUI (2019), built on a different layout model                    |

---

## Overview

Auto Layout is Apple's constraint-based layout system for UIKit and AppKit. Rather than
positioning views with explicit frames (`view.frame = CGRect(x:10, y:20, w:100, h:30)`)
or arranging them with parent-driven containers (AWT-style layout managers), Auto Layout
lets developers declare _relationships_ between view attributes: edges, centers,
dimensions, baselines. At runtime, a Cassowary-based solver finds frame values that
satisfy as many of the declared relationships as possible.

**What it solves.** A typical iOS or macOS app must work across many screen sizes, two
orientations, dynamic type, localization (right-to-left layouts, German strings that are
30 % longer than English), and split-screen multitasking. Hand-coded frame arithmetic
becomes a combinatorial nightmare. Auto Layout lets the developer describe the _intent_
("this button is 16 points below the label, horizontally centered, and at least 44 points
wide") and lets the system compute the actual frames.

**Design lineage.** Auto Layout productized the Cassowary algorithm published by
Badros, Borning, and Stuckey in 2001 (see `cassowary.md`). It joins a small set of
production deployments of Cassowary -- alongside the Mozilla XUL template engine, GTK's
EMMA constraint system, and more recently kiwi.js, Carthage's Cassowary.swift, and Apple's
own implementation. Until 2011 there was no widely-deployed constraint-solver-based
layout system in mainstream OS UI; Auto Layout changed that.

**Why this matters for a TUI / Sparkles.** Terminal cells are discrete and bounded, but
the _expressiveness_ of constraint-based layout still applies: "this panel is at least 20
columns wide", "the status bar's height equals the prompt's height", "this label is
centered in the dialog". A TUI layout engine that adopts the constraint vocabulary --
intrinsic content size, content hugging, compression resistance, priority-driven
satisfaction -- inherits 15 years of mobile-UI lessons about how to express robust,
locale-flexible layouts declaratively.

**History.**

- **2011** -- Auto Layout ships on macOS 10.7 Lion. `NSLayoutConstraint` is the only API;
  the Visual Format Language (VFL) is offered as a shorthand.
- **2012** -- iOS 6 brings Auto Layout to mobile. Storyboards introduce a graphical
  constraint editor in Xcode 4.5.
- **2014** -- Adaptive layout (`UITraitCollection`, size classes) lets storyboards declare
  device-class-specific constraints.
- **2015** -- iOS 9 / macOS 10.11 introduce `NSLayoutAnchor` (the fluent type-safe API)
  and `UIStackView` / `NSStackView` (a high-level wrapper for linear arrangements).
- **2019** -- SwiftUI launches with a fundamentally different layout model (size-pass,
  proposal-based, no constraint solver). Auto Layout remains in maintenance mode as the
  foundation for UIKit/AppKit.
- **2024** -- UIKit on visionOS continues to rely on Auto Layout; SwiftUI interop bridges
  the two systems.

---

## Layout Model

### The Constraint Equation

Every Auto Layout constraint is a linear relation between two view attributes:

```
item1.attribute1  <relation>  multiplier × item2.attribute2 + constant
```

where `<relation>` is one of `=`, `<=`, or `>=`. The system collects all constraints in a
view hierarchy and solves them with a Cassowary-style simplex algorithm to produce
concrete frame values.

**Concrete example.** "The red view's leading edge is 8 points after the blue view's
trailing edge":

```
red.leading = 1.0 × blue.trailing + 8.0
```

### Attributes

`NSLayoutConstraint.Attribute` enumerates the layout points a constraint can address:

**Size attributes** (no position; just a dimension):

- `.width`
- `.height`

**Horizontal position attributes:**

- `.leading` -- Leading edge (left in LTR locales, right in RTL).
- `.trailing` -- Trailing edge.
- `.left`, `.right` -- Literal left/right; avoid except when interacting with hardware.
- `.centerX`
- `.leadingMargin`, `.trailingMargin`, `.leftMargin`, `.rightMargin`, `.centerXWithinMargins`

**Vertical position attributes:**

- `.top`, `.bottom`
- `.centerY`
- `.firstBaseline`, `.lastBaseline` -- The text baseline of the first or last line.
- `.topMargin`, `.bottomMargin`, `.centerYWithinMargins`

**Special:**

- `.notAnAttribute` -- Used for "constant" constraints like `width >= 0 × _ + 40`.

### Relations

Three relation operators are supported:

- `NSLayoutRelation.equal` (`=`)
- `NSLayoutRelation.greaterThanOrEqual` (`>=`)
- `NSLayoutRelation.lessThanOrEqual` (`<=`)

Constraints are _not_ assignments. `a.width = b.width + 10` is a relation; the solver may
satisfy it by adjusting either side (or both) within the constraints of all _other_
constraints.

### Multiplier and Constant

- **Multiplier** -- A `CGFloat` applied to the right-hand attribute. Defaults to 1.0. Must
  be 1.0 for position attributes (you can't constrain `leading = 2 × trailing`). Required
  to be 0.0 when `attribute2 == .notAnAttribute`.
- **Constant** -- A `CGFloat` offset added to the right-hand side. Defaults to 0.

These two together let constraints express ratios (`width = 1.0 × height × 16/9` via
`view.widthAnchor.constraint(equalTo: view.heightAnchor, multiplier: 16.0/9.0)`) and
spacing (`top = superview.top + 20`).

### Priorities

Every constraint carries a `UILayoutPriority` (or `NSLayoutPriority`) in the range
`1...1000`:

| Constant                | Value | Meaning                                                   |
| ----------------------- | ----- | --------------------------------------------------------- |
| `.required`             | 1000  | Must be satisfied; failure produces "unsatisfiable" logs. |
| `.defaultHigh`          | 750   | Default compression resistance priority.                  |
| `.dragThatCanResize`    | 510   | Drag operation that can resize a window.                  |
| `.windowSizeStayPut`    | 500   | Keep window the same size during a drag.                  |
| `.dragThatCannotResize` | 490   | Drag that just moves without resizing.                    |
| `.defaultLow`           | 250   | Default content hugging priority.                         |
| `.fittingSizeLevel`     | 50    | Used by `systemLayoutSizeFitting`.                        |

The solver tries to satisfy constraints in priority order. _Required_ constraints (1000)
_must_ be satisfied; if they conflict, Auto Layout logs the famous "unsatisfiable
constraints" wall of text and breaks one. _Optional_ constraints (1-999) are honoured
when possible; otherwise they're relaxed, often acting as "pull" forces that influence
but do not dictate the layout.

This priority mechanism is what makes Auto Layout _expressive_ rather than _brittle_: a
view can say "I'd really like to be 200 points wide (priority 750), but I'd rather shrink
than be clipped by my neighbour (priority 1000)".

### Intrinsic Content Size

Views with natural sizes (`UILabel` based on its text, `UIImageView` based on its image,
`UIButton` based on its title and image) report a non-trivial value from
`intrinsicContentSize`. Auto Layout uses this value as the basis for _two_ generated
constraints per axis:

**Compression resistance** -- "I don't want to be squashed smaller than my intrinsic
size":

```
view.width  >= intrinsicContentSize.width    @ priority 750 (default)
view.height >= intrinsicContentSize.height   @ priority 750
```

**Content hugging** -- "I don't want to grow larger than my intrinsic size":

```
view.width  <= intrinsicContentSize.width    @ priority 250 (default)
view.height <= intrinsicContentSize.height   @ priority 250
```

The priorities are independently tunable _per axis_:

```swift
label.setContentHuggingPriority(.required, for: .horizontal)
label.setContentCompressionResistancePriority(.defaultHigh, for: .vertical)
```

This is the mechanism that lets two labels in a row decide which one shrinks when there
isn't enough space ("I have a higher horizontal compression resistance than you, so you
shrink first"). The tunability per-axis is the key feature: a label may resist
horizontal compression strongly (so its text doesn't truncate) while accepting vertical
compression freely.

### Generation 1: Raw NSLayoutConstraint

The original API was a single constructor with eight parameters:

```swift
let c = NSLayoutConstraint(
    item: button,
    attribute: .leading,
    relatedBy: .equal,
    toItem: view,
    attribute: .leading,
    multiplier: 1.0,
    constant: 16.0
)
c.priority = .required
c.isActive = true
```

Equivalent in Objective-C is even more verbose. A typical screen had dozens of
constraints; each was eight lines. This was the API that gave Auto Layout its reputation
for verbosity.

### Generation 2: Visual Format Language

To compress chains of edge-to-edge constraints, Apple introduced VFL: an ASCII-art
language inspired by ASCII window diagrams. Vertical bars are superviews, hyphens are
standard spacing, brackets are subviews, parentheses with numbers are dimensions:

```swift
let views = ["label": label, "field": field]
let metrics = ["margin": 16]

// "Horizontal: from superview leading, 16pt gap, label, standard gap, field,
//  16pt gap, to superview trailing"
NSLayoutConstraint.activate(NSLayoutConstraint.constraints(
    withVisualFormat: "H:|-margin-[label]-[field]-margin-|",
    options: [],
    metrics: metrics,
    views: views
))

// "Vertical: from superview top, 16pt gap, label, 8pt gap, field, no constraint to bottom"
NSLayoutConstraint.activate(NSLayoutConstraint.constraints(
    withVisualFormat: "V:|-margin-[label]-8-[field]",
    options: [],
    metrics: metrics,
    views: views
))
```

Useful for chains of adjacent views but limited: it can't express ratios, doesn't include
all the attributes (no baseline, no center), and the syntax is unforgiving (mis-paired
brackets are runtime errors). VFL is considered legacy code now.

### Generation 3: NSLayoutAnchor

Introduced in iOS 9 / macOS 10.11, [`NSLayoutAnchor`][anchor] is the modern type-safe
fluent API. Every view has a set of typed anchor properties:

- `view.leadingAnchor`, `view.trailingAnchor`, `view.centerXAnchor`, `view.leftAnchor`,
  `view.rightAnchor` -- All `NSLayoutXAxisAnchor`.
- `view.topAnchor`, `view.bottomAnchor`, `view.centerYAnchor`, `view.firstBaselineAnchor`,
  `view.lastBaselineAnchor` -- All `NSLayoutYAxisAnchor`.
- `view.widthAnchor`, `view.heightAnchor` -- `NSLayoutDimension`.

The type system prevents constraining a horizontal anchor to a vertical anchor at compile
time -- a class of error that was a runtime crash with the original `NSLayoutConstraint`
API.

Methods on each anchor:

```swift
anchor.constraint(equalTo: otherAnchor)                              // a = b
anchor.constraint(equalTo: otherAnchor, constant: c)                 // a = b + c
anchor.constraint(greaterThanOrEqualTo: otherAnchor, constant: c)    // a >= b + c
anchor.constraint(lessThanOrEqualTo: otherAnchor, constant: c)       // a <= b + c

// NSLayoutDimension also supports multipliers and constants:
dim.constraint(equalTo: otherDim, multiplier: m)                     // a = m × b
dim.constraint(equalTo: otherDim, multiplier: m, constant: c)        // a = m × b + c
dim.constraint(equalToConstant: 100)                                 // a = 100
dim.constraint(greaterThanOrEqualToConstant: 44)                     // a >= 44
```

Activation is per-constraint (`isActive = true`) or batched
(`NSLayoutConstraint.activate([...])` is significantly faster for big batches).

### UIStackView / NSStackView

Hand-writing dozens of anchor constraints for a simple row of buttons is still verbose.
[`UIStackView`][stack] (iOS 9) and `NSStackView` (macOS 10.11) wrap that pattern as a
single view that lays out its `arrangedSubviews` along an axis automatically. It is the
high-level wrapper that most modern iOS code uses.

Configuration:

- **`axis`** -- `.horizontal` or `.vertical` (called `orientation` on macOS).
- **`spacing`** -- `CGFloat` distance between arranged subviews (or use the
  `UIStackView.spacingUseSystem` constant for the system default).
- **`distribution`** -- How space is divided along the main axis:
  - `.fill` -- Each view at its intrinsic size; one resizable view absorbs slack
    (determined by compression resistance / hugging priorities).
  - `.fillEqually` -- All views made equal-size; intrinsic sizes are ignored.
  - `.fillProportionally` -- All views resized in proportion to their intrinsic sizes.
  - `.equalSpacing` -- Views at their intrinsic sizes; equal gaps between them.
  - `.equalCentering` -- Views at their intrinsic sizes; equal distance between centers.
- **`alignment`** -- Cross-axis alignment:
  - `.fill` -- Stretch to fill the cross dimension.
  - `.leading` / `.trailing` (or `.top` / `.bottom` for horizontal stacks).
  - `.center`
  - `.firstBaseline` / `.lastBaseline` (horizontal stacks only).
- **`isLayoutMarginsRelativeArrangement`** -- When `true`, the stack's content respects
  its `layoutMargins`; when `false`, content extends to the stack's edges.
- **`isBaselineRelativeArrangement`** (iOS) -- For vertical stacks, spacing is measured
  baseline-to-baseline.

Stacks compose: a vertical stack of horizontal stacks builds a table-like grid with
arbitrary alignment per row. Stacks also recognize `setCustomSpacing(_:after:)` for
exceptions to the default spacing -- useful for grouping ("more space after this
divider").

### Unsatisfiable Constraints

When the solver finds _required_ (priority 1000) constraints in conflict, it logs a wall
of text starting with "Unable to simultaneously satisfy constraints" followed by the list
of conflicting constraints and a chosen victim. Example:

```
2024-04-12 14:22:01.881 MyApp[12345:67890] Unable to simultaneously satisfy constraints.
    Probably at least one of the constraints in the following list is one you don't want.
    Try this:
        (1) look at each constraint and try to figure out which you don't expect;
        (2) find the code that added the unwanted constraint or constraints and fix it.
(
    "<NSLayoutConstraint:0x600000a01200 H:[UIButton'Login']-(8)-[UIButton'Cancel'] (active)>",
    "<NSLayoutConstraint:0x600000a01250 H:|-(16)-[UIButton'Login'] (active, names: '|':UIView:0x7f...)>",
    "<NSLayoutConstraint:0x600000a012a0 UIButton'Login'.width == 200 (active)>",
    "<NSLayoutConstraint:0x600000a012f0 UIButton'Cancel'.trailing == UIView:0x7f....trailing - 16 (active)>",
    "<NSLayoutConstraint:0x600000a01340 'UIView-Encapsulated-Layout-Width' UIView:0x7f.... width == 320 (active)>"
)
Will attempt to recover by breaking constraint
<NSLayoutConstraint:0x600000a012a0 UIButton'Login'.width == 200 (active)>
```

This output is famously hard to parse, especially when constraints lack identifiers.
Common debugging techniques include:

- Assigning `identifier` strings to constraints so they appear named in the logs.
- Using `UIView.exerciseAmbiguityInLayout()` to visualize ambiguous layouts.
- Setting a symbolic breakpoint on `UIViewAlertForUnsatisfiableConstraints`.
- Calling `view.constraintsAffectingLayout(for: .horizontal)` in the debugger to dump the
  constraints affecting a specific axis.

The unsatisfiability logs are widely cited as Auto Layout's weakest user experience.

### Performance

Auto Layout uses an _incremental_ Cassowary implementation that re-solves only the
constraints affected by a change. For most static screens, layout time is negligible.
However:

- **Adding many constraints at once** is faster via
  `NSLayoutConstraint.activate([...])` than activating them one-by-one (single solver pass
  rather than N).
- **`UITableViewCell` and `UICollectionViewCell`** with self-sizing cells run the solver
  for every visible cell on every reload; this can dominate scrolling performance.
- **Deep view hierarchies** with many cross-hierarchy constraints scale poorly. Apple's
  recommendation is to keep constraints within a single subtree where possible.
- **Animations** require care: animating constraints means re-solving every frame.
  Animating frames directly (and not Auto Layout) is sometimes preferable for transient
  effects.

These performance limits are part of why SwiftUI (which uses a simpler size-pass layout
model without a constraint solver) was developed: for very large or rapidly changing UIs,
the Cassowary overhead becomes measurable.

---

## Code Examples

### Example 1 -- Login Form with NSLayoutAnchor

```swift
import UIKit

class LoginViewController: UIViewController {
    private let usernameField = UITextField()
    private let passwordField = UITextField()
    private let signInButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        [usernameField, passwordField, signInButton, cancelButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }

        usernameField.placeholder = "Username"
        usernameField.borderStyle = .roundedRect
        passwordField.placeholder = "Password"
        passwordField.borderStyle = .roundedRect
        passwordField.isSecureTextEntry = true
        signInButton.setTitle("Sign In", for: .normal)
        cancelButton.setTitle("Cancel", for: .normal)

        let margins = view.layoutMarginsGuide
        NSLayoutConstraint.activate([
            // Username: top of safe area + 32, full margins width.
            usernameField.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor,
                constant: 32),
            usernameField.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            usernameField.trailingAnchor.constraint(equalTo: margins.trailingAnchor),

            // Password: 12 below username, same width.
            passwordField.topAnchor.constraint(
                equalTo: usernameField.bottomAnchor, constant: 12),
            passwordField.leadingAnchor.constraint(equalTo: usernameField.leadingAnchor),
            passwordField.trailingAnchor.constraint(equalTo: usernameField.trailingAnchor),

            // Sign In: 24 below password, trailing-aligned with the fields.
            signInButton.topAnchor.constraint(
                equalTo: passwordField.bottomAnchor, constant: 24),
            signInButton.trailingAnchor.constraint(equalTo: passwordField.trailingAnchor),

            // Cancel: aligned with Sign In's top, 16 to its left.
            cancelButton.firstBaselineAnchor.constraint(
                equalTo: signInButton.firstBaselineAnchor),
            cancelButton.trailingAnchor.constraint(
                equalTo: signInButton.leadingAnchor, constant: -16),

            // Minimum width on Sign In so short titles don't squash it.
            signInButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 88),
        ])
    }
}
```

Notes:

- `translatesAutoresizingMaskIntoConstraints = false` is required on every constrained
  view; forgetting it is one of the most common causes of unsatisfiable-constraints logs
  (the autoresizing constraints conflict with the explicit ones).
- `safeAreaLayoutGuide` and `layoutMarginsGuide` are pseudo-views with their own anchors;
  they make layouts naturally respect notches, the home indicator, and platform-standard
  insets.
- `firstBaselineAnchor` aligns the buttons' text baselines, not their bottom edges --
  visually superior when the buttons have different fonts.

### Example 2 -- Same Form with UIStackView

```swift
import UIKit

class LoginStackViewController: UIViewController {
    private let usernameField = UITextField()
    private let passwordField = UITextField()
    private let signInButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        usernameField.placeholder = "Username"
        usernameField.borderStyle = .roundedRect
        passwordField.placeholder = "Password"
        passwordField.borderStyle = .roundedRect
        passwordField.isSecureTextEntry = true
        signInButton.setTitle("Sign In", for: .normal)
        cancelButton.setTitle("Cancel", for: .normal)

        // Button row: horizontal stack, trailing-aligned.
        let buttonRow = UIStackView(arrangedSubviews: [cancelButton, signInButton])
        buttonRow.axis = .horizontal
        buttonRow.spacing = 16
        buttonRow.alignment = .firstBaseline
        buttonRow.distribution = .fill

        // Main column: vertical stack of fields and the button row.
        let column = UIStackView(arrangedSubviews: [
            usernameField,
            passwordField,
            buttonRow,
        ])
        column.axis = .vertical
        column.spacing = 12
        column.alignment = .fill
        column.setCustomSpacing(24, after: passwordField)   // bigger gap before buttons
        column.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(column)

        let margins = view.layoutMarginsGuide
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 32),
            column.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
        ])
    }
}
```

The stack view replaces about a dozen individual constraints with two stack
configurations. Cross-axis alignment (`.firstBaseline`) is a property of the stack rather
than per-button. Adding or removing fields means inserting into `arrangedSubviews`, not
re-running constraint math.

### Example 3 -- Self-Sizing Card via Intrinsic Content Size

```swift
import UIKit

class CardView: UIView {
    private let titleLabel = UILabel()
    private let bodyLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 12

        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.numberOfLines = 0
        bodyLabel.font = .preferredFont(forTextStyle: .body)
        bodyLabel.numberOfLines = 0
        bodyLabel.textColor = .secondaryLabel

        let stack = UIStackView(arrangedSubviews: [titleLabel, bodyLabel])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
        ])

        // Title should resist vertical compression even more than the default,
        // so when space is scarce, the body shrinks first.
        titleLabel.setContentCompressionResistancePriority(
            .required, for: .vertical)

        // Body hugs less strongly horizontally so it expands to fill width.
        bodyLabel.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, body: String) {
        titleLabel.text = title
        bodyLabel.text = body
    }
}
```

The card has no explicit width or height. Its size derives from the intrinsic content
sizes of the labels, propagated through the stack view and the four edge constraints.
When the card is placed in a parent with a width constraint, the labels wrap and the
card grows vertically as needed. This is the canonical "self-sizing" pattern that powers
`UITableViewCell` automatic heights.

### Example 4 -- Priority-Based Truncation

```swift
import UIKit

class TruncationDemo: UIViewController {
    private let leftLabel = UILabel()
    private let rightLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        leftLabel.text = "Filename:"
        rightLabel.text = "/Users/petar/some/very/long/filesystem/path/that-cannot-fit.txt"
        rightLabel.lineBreakMode = .byTruncatingMiddle

        // Left label should NEVER be truncated.
        leftLabel.setContentCompressionResistancePriority(
            .required, for: .horizontal)
        // Right label MAY be truncated when space is tight.
        rightLabel.setContentCompressionResistancePriority(
            .defaultLow, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [leftLabel, rightLabel])
        row.axis = .horizontal
        row.spacing = 8
        row.alignment = .firstBaseline
        row.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(row)

        let margins = view.layoutMarginsGuide
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 64),
            row.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
        ])
    }
}
```

In a constrained-width row, the solver decides which label gives way under pressure. The
left label has priority 1000 (`required`) on horizontal compression resistance, so the
stack cannot shrink it; the right label has the default low priority, so the path is
truncated. Reversing the priorities produces the opposite behaviour.

This is the clearest demonstration of priority-based satisfaction: there is no "which view
truncates first" property to set; it falls out naturally from per-view priority on a
universal sizing dimension.

---

## Strengths and Weaknesses

### Strengths

- **Genuinely declarative.** Constraints describe relations, not assignments. The same
  set of constraints adapts to portrait, landscape, split-screen, dynamic type, and RTL
  locales without explicit special-casing.
- **Type-safe modern API.** `NSLayoutAnchor` makes invalid relations (horizontal anchor
  to vertical anchor) compile-time errors.
- **Priorities are uniquely expressive.** Few other layout systems offer the
  per-constraint priority dial. Once internalized, content hugging and compression
  resistance solve a wide class of "who shrinks first" problems with no custom code.
- **UIStackView eliminates boilerplate.** For linear arrangements (which are most UIs),
  the stack view replaces dozens of constraints with three properties (`axis`, `spacing`,
  `distribution`).
- **Solid IDE support.** Storyboards and XIBs give a graphical constraint editor;
  Interface Builder catches conflicts at design time.
- **Incremental solver performance.** Most screens render in microseconds; the Cassowary
  re-solve cost is proportional to _changed_ constraints, not the total constraint count.
- **Used in production for over a decade.** Every iOS app since iOS 6 has had Auto
  Layout as an option; from iOS 8 onward it is the dominant approach.
- **Cross-platform within Apple.** The same vocabulary works on iOS, macOS, tvOS,
  watchOS, and visionOS, lowering the cost of multi-platform apps.

### Weaknesses

- **Verbose without anchors.** Pre-iOS-9 code (raw `NSLayoutConstraint` calls) is
  painfully long. Even with anchors, complex screens can have hundreds of constraints.
- **Unsatisfiable-constraints debugging is brutal.** The console output is famous for
  being inscrutable. Apple has not significantly improved it in over a decade.
- **`translatesAutoresizingMaskIntoConstraints` foot-gun.** Forgetting to set it to
  `false` is the most common Auto Layout bug; the autoresizing-translation constraints
  conflict with explicit ones at runtime.
- **Performance under stress.** Re-solving on every frame during scrolling of
  self-sizing cells can cost 5-15ms per frame, contributing to dropped frames on older
  devices. SwiftUI's simpler model often wins on raw layout throughput.
- **Hard to compose programmatically.** Reusable layouts are usually expressed as helper
  functions that return arrays of constraints; there is no first-class "layout component"
  abstraction below the level of a full `UIView` subclass.
- **Cassowary cost in interactive scrolling.** Self-sizing table cells, prior to the
  estimated-height optimizations introduced in iOS 11, could dominate scrolling
  performance. Still requires careful tuning today.
- **No first-class grid.** Two-dimensional grids must be built from nested stack views or
  hand-coded constraints; there is no `UIGridView` in UIKit (AppKit has `NSGridView`,
  but it is rarely used).
- **Versus box-flow systems (Flutter, Compose, SwiftUI):** Auto Layout is more flexible
  but harder to reason about. A SwiftUI body or Flutter `Column` is a single declarative
  expression; an Auto Layout view controller is a constructor plus dozens of constraint
  activations. SwiftUI traded expressiveness for predictability.

### Versus Other Layout Models

| Aspect                | Auto Layout                      | Flexbox (Ink/Yoga)               | Ratatui Constraints       |
| --------------------- | -------------------------------- | -------------------------------- | ------------------------- |
| Solver type           | Cassowary (linear arithmetic)    | Flexbox spec (greedy passes)     | Kasuari (Cassowary port)  |
| Constraint scope      | Cross-hierarchy                  | Parent-to-children only          | Single parent rectangle   |
| Priority system       | 1-1000 per constraint            | None (compile-time `flexGrow`)   | Implicit constraint order |
| Intrinsic size        | Yes (`intrinsicContentSize`)     | Yes (`minWidth`/`minHeight`)     | Implicit via Length       |
| Hand-coded ergonomics | Anchors are okay; raw API is bad | Excellent                        | Excellent (areas API)     |
| Designer tools        | Excellent (Interface Builder)    | None                             | None                      |
| Debugging             | Painful logs                     | React DevTools / Yoga playground | Manual                    |

The cross-hierarchy expressiveness is Auto Layout's distinguishing feature: a constraint
can relate a view to its great-grandparent or even an unrelated subtree (through a shared
ancestor). Flexbox and most TUI layout systems restrict relations to parent-child only,
which is simpler to reason about but less expressive.

### Lessons for a Sparkles TUI Layout

Auto Layout's vocabulary translates surprisingly well to terminal cells:

- **Anchors** map to `Edge` enums (top/bottom/leading/trailing/centerX/centerY).
- **`>=`, `<=`, `=` relations** map to D enum tags on a layout DSL.
- **Priorities** map to integer ranks; the solver picks the highest-priority satisfiable
  set. The same Cassowary algorithm runs on integers as well as floats.
- **Intrinsic content size** maps to widget-reported preferred sizes (the same idea as
  AWT's `getPreferredSize`).
- **Compression resistance / content hugging** map to per-widget per-axis growth weights,
  which is exactly Ratatui's `Constraint::Fill(weight)` model.
- **Stack view distribution modes** are a small enum with well-defined semantics; a
  similar abstraction (`distribute: .fill | .fillEqually | .equalSpacing`) would let
  Sparkles users avoid the constraint solver in the common case.

The takeaway: a TUI layout engine doesn't need full Cassowary expressiveness for typical
dashboard UIs (Ratatui demonstrates this), but the _priority vocabulary_ and the
_intrinsic-size / hugging / resistance_ trio are concepts worth importing even when the
solver underneath is simpler.

---

## References

- **Apple Documentation:**
  - [Auto Layout Guide (Apple Archive)](https://developer.apple.com/library/archive/documentation/UserExperience/Conceptual/AutolayoutPG/index.html)
  - [Anatomy of a Constraint](https://developer.apple.com/library/archive/documentation/UserExperience/Conceptual/AutolayoutPG/AnatomyofaConstraint.html)
  - [`NSLayoutConstraint`](https://developer.apple.com/documentation/uikit/nslayoutconstraint)
  - [`NSLayoutAnchor`][anchor]
  - [`NSLayoutXAxisAnchor`](https://developer.apple.com/documentation/uikit/nslayoutxaxisanchor)
  - [`NSLayoutYAxisAnchor`](https://developer.apple.com/documentation/uikit/nslayoutyaxisanchor)
  - [`NSLayoutDimension`](https://developer.apple.com/documentation/uikit/nslayoutdimension)
  - [`UIStackView`][stack]
  - [`NSStackView`](https://developer.apple.com/documentation/appkit/nsstackview)
  - [`UILayoutPriority`](https://developer.apple.com/documentation/uikit/uilayoutpriority)
  - [`UIView` intrinsicContentSize](https://developer.apple.com/documentation/uikit/uiview/1622600-intrinsiccontentsize)
- **WWDC sessions:**
  - WWDC 2012 Session 232 "Introduction to Auto Layout for iOS and OS X"
  - WWDC 2015 Session 218 "Mysteries of Auto Layout, Part 1"
  - WWDC 2015 Session 219 "Mysteries of Auto Layout, Part 2"
  - WWDC 2018 Session 220 "High Performance Auto Layout"
- **Related Sparkles research:**
  - Cassowary algorithm and incremental solver: `./cassowary.md`
  - Swing / MiG Layout (constraint strings in a different tradition): `./swing-mig.md`
  - SwiftUI (Auto Layout's successor with a different layout model): `./swiftui.md`
  - Ratatui's Cassowary-port-based constraint API: `../tui-libraries/ratatui.md`
  - Ink / Yoga Flexbox: `../tui-libraries/ink.md`
- **Algorithm:**
  - Badros, Borning, Stuckey, "The Cassowary linear arithmetic constraint solving
    algorithm", ACM Transactions on Computer-Human Interaction (2001).

[anchor]: https://developer.apple.com/documentation/uikit/nslayoutanchor
[stack]: https://developer.apple.com/documentation/uikit/uistackview
