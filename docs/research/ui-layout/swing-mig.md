# Swing AWT Layout Managers and MiG Layout (Java)

A survey of Java's desktop GUI layout heritage: the `LayoutManager`/`LayoutManager2`
interfaces that AWT introduced in 1995, the built-in managers that Swing inherited
(BorderLayout, FlowLayout, GridLayout, CardLayout, BoxLayout, GridBagLayout, GroupLayout,
SpringLayout), and the third-party MiG Layout that became the de-facto default for
hand-coded layout because the built-ins each have rough edges.

| Field             | Value                                                                   |
| ----------------- | ----------------------------------------------------------------------- |
| Language          | Java (Swing/AWT in the JDK; MiG Layout 3rd-party)                       |
| First Released    | AWT 1.0 (1995), Swing 1.0 (1998), MiG Layout 1.0 (2007)                 |
| Distribution      | `java.awt`, `javax.swing` (bundled with the JDK); MiG via Maven Central |
| MiG License       | BSD or GPL (dual)                                                       |
| MiG Repository    | <https://github.com/mikaelgrev/miglayout>                               |
| MiG Documentation | <https://www.miglayout.com/>                                            |
| MiG Latest        | 11.x (2024); also published as `MigPane` for JavaFX                     |
| MiG Author        | Mikael Grev                                                             |

---

## Overview

Java's Abstract Window Toolkit (AWT) shipped with version 1.0 of the JDK in January 1996.
Among its design decisions was a deliberate refusal to bake any single layout policy into
the toolkit. Instead, `java.awt.Container` delegated layout to a pluggable
[`LayoutManager`][lm] object. Application code, look-and-feel implementations, and IDE
visual designers could all swap in different managers to get radically different sizing
behaviour without changing the component tree.

Swing (1998) reused this architecture wholesale. Every `JComponent` is a `Container`, and
every container has a layout manager (default `FlowLayout` for `JPanel`, `BorderLayout` for
`JFrame`'s content pane, etc.). Two decades later the contract is unchanged: any class
implementing `LayoutManager` (or the constraint-aware `LayoutManager2`) can drive Swing.

**The catch.** The built-in managers each solve one slice of the layout problem. A complex
form needs a combination of nested `BoxLayout`, `BorderLayout`, and the notoriously
complex `GridBagLayout`. The official tutorial spends entire pages on `GridBagConstraints`
with its eleven independently-tunable fields. This pain motivated the constraint-string
DSL approach of MiG Layout: a single manager whose declarative constraint strings subsume
nearly every built-in.

**Why this matters for a TUI / Sparkles.** Terminals are a constrained layout problem:
discrete integer cells, no fractional pixels, a small finite grid. Swing's layout
contracts (preferred / minimum / maximum sizes; vertical and horizontal alignment;
baselines) map cleanly into terminal cells. The conceptual vocabulary -- "this widget
hugs its content; this one fills the remaining space; this one has a fixed minimum;
columns are aligned along baselines" -- is exactly what a polished TUI layout engine
needs.

**History timeline.**

- **1995** -- AWT 1.0 with `LayoutManager`, `BorderLayout`, `FlowLayout`, `GridLayout`,
  `CardLayout`, `GridBagLayout`.
- **1998** -- Swing 1.0 inherits the AWT layout model; adds `BoxLayout` and `OverlayLayout`.
- **2005** -- `GroupLayout` lands in Java 6, paired with NetBeans' Matisse GUI builder.
- **2007** -- MiG Layout 3.0 released by Mikael Grev; the constraint-string approach
  rapidly displaces hand-coded `GridBagLayout` for new Swing code.
- **2013** -- `MigPane` published for JavaFX, bringing the same syntax to the new
  scene-graph toolkit.
- **Today** -- Swing/AWT remain in long-term maintenance; MiG Layout is still maintained
  and widely used in business desktop applications.

---

## Layout Model

### The LayoutManager Interface

[`java.awt.LayoutManager`][lm] is a five-method interface that every classical AWT layout
manager implements:

```java
public interface LayoutManager {
    void addLayoutComponent(String name, Component comp);
    void removeLayoutComponent(Component comp);
    Dimension preferredLayoutSize(Container parent);
    Dimension minimumLayoutSize(Container parent);
    void layoutContainer(Container parent);
}
```

Semantics of each method:

- **`addLayoutComponent(name, comp)`** -- Invoked when a component is added with a
  _string_ constraint (e.g. `panel.add(button, "North")` for `BorderLayout`). The manager
  is free to record this association in its own data structures.
- **`removeLayoutComponent(comp)`** -- Invoked when a component is removed; the manager
  drops any stored constraints for it.
- **`preferredLayoutSize(parent)`** -- The container's _ideal_ size, computed by querying
  each child's `getPreferredSize()`. The layout manager combines them according to its
  own rules. Returned `Dimension` is in pixels (width, height).
- **`minimumLayoutSize(parent)`** -- The smallest size at which the layout can still
  function. Used when the container is shrunk below its preferred size.
- **`layoutContainer(parent)`** -- The actual layout pass: read the parent's current
  bounds, then call `setBounds(x, y, w, h)` on each child to position and size it. This
  method is the only one that performs side effects.

### LayoutManager2 -- Constraint Objects, Alignment, Maximum Size

[`java.awt.LayoutManager2`][lm2] (introduced in JDK 1.1) extends the interface with
five more methods:

```java
public interface LayoutManager2 extends LayoutManager {
    void addLayoutComponent(Component comp, Object constraints);
    Dimension maximumLayoutSize(Container target);
    float getLayoutAlignmentX(Container target);
    float getLayoutAlignmentY(Container target);
    void invalidateLayout(Container target);
}
```

The headline addition is the _object_-typed constraint. Where the original
`addLayoutComponent` only accepted a `String` (severely limiting expressiveness),
`LayoutManager2` accepts any `Object`. `GridBagLayout` uses `GridBagConstraints`,
`BorderLayout` accepts its `NORTH`/`SOUTH`/`EAST`/`WEST`/`CENTER` string constants (or
the equivalent constant fields), `BoxLayout` takes nothing, and MiG Layout accepts
either a `String` constraint or a `CC` (component constraints) object.

`maximumLayoutSize` matters for `BoxLayout`-style alignment: a component with a finite
maximum is centered within any extra space; a component with `Integer.MAX_VALUE`
maximum grows to fill it.

`getLayoutAlignmentX/Y` return values in `[0.0f, 1.0f]` indicating where this container
prefers to be anchored within its allotted space along each axis (0 = left/top,
0.5 = center, 1 = right/bottom).

`invalidateLayout(target)` is called when something the manager has cached should be
discarded -- typically when constraints change or components are added/removed.

### Sizing Contract

Every Swing/AWT component participates in a three-tier sizing contract:

```
component.getMinimumSize()     -> Dimension  // can't go below this without breaking
component.getPreferredSize()   -> Dimension  // ideal size (e.g. text + insets)
component.getMaximumSize()     -> Dimension  // can grow no larger
```

The layout manager calls these and combines results to produce
`preferredLayoutSize`/`minimumLayoutSize`/`maximumLayoutSize` for the _container_. A
top-level window typically asks the root pane for its preferred size, then sizes itself
to match (via `pack()`).

### Built-in Layout Managers

#### FlowLayout

The simplest manager: lay components out left-to-right at their preferred size, wrap to a
new row when they run past the right edge. Default for `JPanel`. Parameters:
`alignment` (LEFT/CENTER/RIGHT/LEADING/TRAILING), `hgap`, `vgap`.

#### BorderLayout

Five regions: `NORTH`, `SOUTH`, `EAST`, `WEST`, `CENTER`. Each region holds at most one
component. NORTH/SOUTH stretch full width and take their preferred height; EAST/WEST take
their preferred width and stretch full height minus the N/S strips; CENTER fills the
remaining rectangle. Default for `JFrame`/`JDialog` content panes.

```java
JFrame frame = new JFrame("Editor");
frame.setLayout(new BorderLayout());
frame.add(new JToolBar(), BorderLayout.NORTH);
frame.add(new JScrollPane(textArea), BorderLayout.CENTER);
frame.add(statusBar, BorderLayout.SOUTH);
```

#### GridLayout

Splits the container into a fixed grid of _identical_ cells; every component gets one
cell. Specified as rows x columns; one dimension can be zero meaning "compute from the
component count". All cells are the same size, so this manager is appropriate for tiled
button panels or chessboard-like grids, not free-form forms.

```java
JPanel keypad = new JPanel(new GridLayout(4, 3, 2, 2)); // 4 rows, 3 cols, 2px gaps
for (String label : new String[]{"1","2","3","4","5","6","7","8","9","*","0","#"})
    keypad.add(new JButton(label));
```

#### CardLayout

Holds multiple components in the same slot; only one is visible at a time. Switched via
`first()`, `next()`, `previous()`, `last()`, `show(parent, name)`. Effectively a stack:
useful for wizard pages, tabbed panels (`JTabbedPane` uses a similar idea), or
state-driven views.

#### BoxLayout

Single-axis arrangement (X_AXIS, Y_AXIS, LINE_AXIS, PAGE_AXIS where the latter two
respect text orientation). Each component is placed at its preferred size along the main
axis; perpendicular axis is aligned according to `getAlignmentX/Y`. The Box class
provides `glue` (expanding empty space) and `struts` (fixed-size spacers):

```java
JPanel row = new JPanel();
row.setLayout(new BoxLayout(row, BoxLayout.LINE_AXIS));
row.add(new JLabel("Name:"));
row.add(Box.createHorizontalStrut(8));   // 8px fixed gap
row.add(nameField);
row.add(Box.createHorizontalGlue());     // expanding spacer
row.add(saveButton);
```

#### GridBagLayout -- The Knob-Heavy One

The most flexible of the built-in managers and the running joke of Swing programming.
Components are added with a [`GridBagConstraints`][gbc] object whose fields independently
control:

- `gridx`, `gridy` -- The component's cell origin (or `RELATIVE` to mean "next in row").
- `gridwidth`, `gridheight` -- Cells spanned (or `REMAINDER` to mean "to end of row").
- `weightx`, `weighty` -- Share of extra space this column/row receives when the
  container grows beyond its preferred size. A column with weight 0 stays fixed; a column
  with weight 1.0 takes all the slack (or splits it proportionally with other weighted
  columns).
- `fill` -- `NONE`, `HORIZONTAL`, `VERTICAL`, `BOTH`. Whether the component grows to fill
  its cell.
- `anchor` -- Where the component anchors when smaller than its cell. Compass directions
  (`NORTH`, `NORTHEAST`, ...) plus baseline anchors (`BASELINE`, `BASELINE_LEADING`, ...).
- `insets` -- External padding around the component (top, left, bottom, right).
- `ipadx`, `ipady` -- Internal padding added to the component's preferred size.

A typical form row in `GridBagLayout`:

```java
JPanel form = new JPanel(new GridBagLayout());
GridBagConstraints g = new GridBagConstraints();
g.insets = new Insets(2, 4, 2, 4);

g.gridx = 0; g.gridy = 0;
g.anchor = GridBagConstraints.LINE_END;
form.add(new JLabel("Username:"), g);

g.gridx = 1;
g.fill = GridBagConstraints.HORIZONTAL;
g.weightx = 1.0;
g.anchor = GridBagConstraints.LINE_START;
form.add(userField, g);

g.gridx = 0; g.gridy = 1;
g.fill = GridBagConstraints.NONE;
g.weightx = 0;
form.add(new JLabel("Password:"), g);

g.gridx = 1;
g.fill = GridBagConstraints.HORIZONTAL;
g.weightx = 1.0;
form.add(passField, g);
```

That's a lot of mutation of a single constraints object for two label/field pairs. Most
programmers wrote helper methods to compress the boilerplate; the cottage industry of
those helpers led to MiG Layout.

#### GroupLayout

Introduced in Java 6, designed primarily as the _output_ of NetBeans' Matisse GUI
builder, not as a hand-coded layout. Specifies horizontal and vertical layouts
_independently_ through nested `SequentialGroup` (one after another) and `ParallelGroup`
(side by side / overlapping) hierarchies. The resulting code is verbose but the model is
clean -- it ensures every component appears in exactly one horizontal and one vertical
group, eliminating the contradictions that plague hand-coded `GridBagLayout`.

```java
GroupLayout layout = new GroupLayout(panel);
panel.setLayout(layout);
layout.setAutoCreateGaps(true);
layout.setAutoCreateContainerGaps(true);

layout.setHorizontalGroup(
    layout.createSequentialGroup()
        .addGroup(layout.createParallelGroup(GroupLayout.Alignment.TRAILING)
            .addComponent(userLabel)
            .addComponent(passLabel))
        .addGroup(layout.createParallelGroup(GroupLayout.Alignment.LEADING)
            .addComponent(userField)
            .addComponent(passField))
);

layout.setVerticalGroup(
    layout.createSequentialGroup()
        .addGroup(layout.createParallelGroup(GroupLayout.Alignment.BASELINE)
            .addComponent(userLabel)
            .addComponent(userField))
        .addGroup(layout.createParallelGroup(GroupLayout.Alignment.BASELINE)
            .addComponent(passLabel)
            .addComponent(passField))
);
```

The baseline-aligned parallel group is the key feature: text in the label and text in the
field line up on their typographic baseline, not on the component's top edge.

#### SpringLayout

A constraint-based manager that predates iOS Auto Layout by a decade. Each component edge
(N, S, E, W) is a node in a graph; the graph is connected by `Spring` values that express
_minimum / preferred / maximum_ offsets between edges. The layout pass solves the spring
network for equilibrium. Specified by `putConstraint`:

```java
SpringLayout sl = new SpringLayout();
JPanel panel = new JPanel(sl);
panel.add(label); panel.add(field);

// label.west = container.west + 5
sl.putConstraint(SpringLayout.WEST, label, 5, SpringLayout.WEST, panel);
// label.north = container.north + 5
sl.putConstraint(SpringLayout.NORTH, label, 5, SpringLayout.NORTH, panel);
// field.west = label.east + 5
sl.putConstraint(SpringLayout.WEST, field, 5, SpringLayout.EAST, label);
// field.north = label.north
sl.putConstraint(SpringLayout.NORTH, field, 0, SpringLayout.NORTH, label);
```

The same edge-relation idea reappears as Auto Layout `NSLayoutConstraint` and again as
CSS Grid's named lines. SpringLayout was conceptually ahead of its time but the API was
cumbersome and never developed a community of converts.

### MiG Layout

[MiG Layout][mig] is a single layout manager that subsumes most use cases of the built-ins
through a declarative _constraint string_ language. The same engine drives Swing
(`MigLayout` extends `LayoutManager2`), JavaFX (`MigPane` extends `Pane`), and SWT.

Three string slots configure a `MigLayout`:

1. **Layout constraints** -- container-wide options (overall direction, wrapping behaviour,
   debug visualization, insets, gaps).
2. **Column constraints** -- one entry per logical column (default width, growth weights,
   alignment).
3. **Row constraints** -- one entry per logical row (default height, growth weights,
   alignment).

Then each component is added with a fourth string of **component constraints**
(per-component cell, span, alignment, growth, dock).

```java
import net.miginfocom.swing.MigLayout;

JPanel form = new JPanel(new MigLayout(
    "wrap 2, insets 10, gapx 8",          // layout constraints
    "[right][grow,fill]",                  // column constraints
    "[]10[]10[]"                           // row constraints
));

form.add(new JLabel("Username:"));
form.add(userField);
form.add(new JLabel("Password:"));
form.add(passField);
form.add(new JLabel("Notes:"), "top");
form.add(new JScrollPane(notesArea), "grow, height 100:200:");
form.add(saveButton, "skip, split 2, tag ok");
form.add(cancelButton, "tag cancel");
```

Key syntax elements:

- **`wrap N`** -- After every N components, advance to the next row. Removes the need for
  manual row tracking.
- **`[]`** -- A column or row marker. `[100]` sets a fixed width; `[grow]` lets the column
  take extra space; `[100:200:300]` sets minimum:preferred:maximum; `[fill]` means
  components fill the column; `[right]` aligns components to the column's right edge.
- **Numbers between `[]`** -- Gaps in pixels (or units like `8mm`, `2cm`, `2%`).
- **`grow`, `growx`, `growy`** -- Component grows to fill its cell along the given axis.
- **`span N`, `spany N`** -- Component spans multiple cells.
- **`skip N`** -- Leave N empty cells before placing the next component.
- **`split N`** -- Place the next N components within the _same_ cell as a sub-row.
- **`dock north`/`south`/`east`/`west`** -- Component attaches to the named edge,
  consuming the full cross dimension (BorderLayout-style overlay).
- **`align <h>,<v>`** -- Anchor within the cell.
- **`gap top|left|right|bottom|push N`** -- Per-side gap, including `push` which is an
  expanding gap (BoxLayout-glue equivalent).
- **`hidemode N`** -- Behaviour when the component is hidden: 0 = keep slot, 1 = zero size
  but keep gaps, 2 = zero size and zero gaps, 3 = skip entirely in size calculations.
- **`sizegroup name`** -- All components with the same `sizegroup` are sized to the
  largest in the group. Useful for aligning button widths across a dialog.
- **`tag ok|cancel|help|apply|...`** -- Standard button roles. MiG knows the platform's
  conventions (Windows puts OK on the left, macOS on the right) and reorders accordingly.
- **`debug`** -- A layout-level flag that draws colored overlays showing cells and gaps;
  invaluable for diagnosing why something isn't where it should be.

A docking example illustrates how MiG subsumes `BorderLayout`:

```java
JFrame frame = new JFrame("IDE");
frame.setLayout(new MigLayout("fill, insets 0, gap 0"));
frame.add(menuBar,     "dock north");
frame.add(toolBar,     "dock north");
frame.add(statusBar,   "dock south");
frame.add(sidePanel,   "dock west, width 200");
frame.add(propertiesPanel, "dock east, width 250");
frame.add(editorArea,  "grow, push");      // fills remaining center
```

The whitepaper at <https://www.miglayout.com/whitepaper.html> describes the design goals:
one layout manager to learn; cell-grid foundations with first-class docking; constraint
strings to keep declarations close to the components; an API form (`CC`, `AC`, `LC`
objects) for programmatic construction. The current implementation lives in
<https://github.com/mikaelgrev/miglayout>.

#### Component-Form API

Constraint strings are convenient but not type-checked. MiG provides an equivalent
Java-object API:

```java
import net.miginfocom.layout.*;

LC layoutConstraints = new LC().wrapAfter(2).insets("10").gridGapX("8");
AC columnConstraints  = new AC().align("right", 0).grow(1.0f, 1).fill(1);
AC rowConstraints     = new AC().gap("10");

JPanel form = new JPanel(new MigLayout(layoutConstraints, columnConstraints, rowConstraints));

CC labelCC = new CC().alignX("right");
CC fieldCC = new CC().growX().pushX();
form.add(new JLabel("Username:"), labelCC);
form.add(userField, fieldCC);
```

Builders are more verbose than strings, but they survive refactorings and IDE rename
operations.

---

## Code Examples

### Example 1 -- Login Dialog with GridBagLayout

```java
import java.awt.*;
import javax.swing.*;

public class GridBagLogin {
    public static void main(String[] args) {
        JFrame frame = new JFrame("Sign In");
        frame.setDefaultCloseOperation(JFrame.EXIT_ON_CLOSE);

        JPanel form = new JPanel(new GridBagLayout());
        GridBagConstraints g = new GridBagConstraints();
        g.insets = new Insets(4, 6, 4, 6);

        // Row 0: Username
        g.gridx = 0; g.gridy = 0;
        g.anchor = GridBagConstraints.LINE_END;
        g.fill = GridBagConstraints.NONE;
        g.weightx = 0;
        form.add(new JLabel("Username:"), g);

        g.gridx = 1;
        g.anchor = GridBagConstraints.LINE_START;
        g.fill = GridBagConstraints.HORIZONTAL;
        g.weightx = 1.0;
        form.add(new JTextField(20), g);

        // Row 1: Password
        g.gridx = 0; g.gridy = 1;
        g.fill = GridBagConstraints.NONE;
        g.weightx = 0;
        g.anchor = GridBagConstraints.LINE_END;
        form.add(new JLabel("Password:"), g);

        g.gridx = 1;
        g.fill = GridBagConstraints.HORIZONTAL;
        g.weightx = 1.0;
        g.anchor = GridBagConstraints.LINE_START;
        form.add(new JPasswordField(20), g);

        // Row 2: Buttons (spanning both columns, right-anchored)
        g.gridx = 0; g.gridy = 2;
        g.gridwidth = 2;
        g.fill = GridBagConstraints.NONE;
        g.anchor = GridBagConstraints.LINE_END;
        g.weightx = 0;
        JPanel buttons = new JPanel(new FlowLayout(FlowLayout.RIGHT, 6, 0));
        buttons.add(new JButton("Cancel"));
        buttons.add(new JButton("Sign In"));
        form.add(buttons, g);

        frame.setContentPane(form);
        frame.pack();
        frame.setLocationRelativeTo(null);
        frame.setVisible(true);
    }
}
```

Note how the same `GridBagConstraints` object is repeatedly mutated; the order of
mutations is significant, and forgetting to reset `gridwidth` or `weightx` between rows is
a common bug source.

### Example 2 -- Same Login Dialog with MiG Layout

```java
import javax.swing.*;
import net.miginfocom.swing.MigLayout;

public class MigLogin {
    public static void main(String[] args) {
        JFrame frame = new JFrame("Sign In");
        frame.setDefaultCloseOperation(JFrame.EXIT_ON_CLOSE);

        JPanel form = new JPanel(new MigLayout(
            "wrap 2, insets 10, gapx 6, gapy 4",
            "[right][grow,fill]",
            "[][]push[]"
        ));

        form.add(new JLabel("Username:"));
        form.add(new JTextField(20));

        form.add(new JLabel("Password:"));
        form.add(new JPasswordField(20));

        form.add(new JButton("Cancel"), "skip, split 2, tag cancel");
        form.add(new JButton("Sign In"), "tag ok");

        frame.setContentPane(form);
        frame.pack();
        frame.setLocationRelativeTo(null);
        frame.setVisible(true);
    }
}
```

Half as many lines and reads top-to-bottom in the order the form is visually arranged.
The `tag ok` / `tag cancel` decorations let MiG reorder the buttons to match the host
platform's convention (Windows: OK then Cancel; macOS: Cancel then OK).

### Example 3 -- IDE-Style Docked Layout (MiG)

```java
import javax.swing.*;
import net.miginfocom.swing.MigLayout;

public class MigIDE {
    public static void main(String[] args) {
        JFrame frame = new JFrame("MigIDE");
        frame.setDefaultCloseOperation(JFrame.EXIT_ON_CLOSE);
        frame.setLayout(new MigLayout("fill, insets 0, gap 0"));

        frame.add(buildMenuBar(),    "dock north");
        frame.add(buildToolBar(),    "dock north");
        frame.add(buildStatusBar(),  "dock south");
        frame.add(buildProjectTree(),"dock west, width 200!");
        frame.add(buildPropertyPanel(), "dock east, width 250!");
        frame.add(buildEditorTabs(), "grow, push");

        frame.setSize(1024, 768);
        frame.setLocationRelativeTo(null);
        frame.setVisible(true);
    }

    private static JComponent buildMenuBar() { return new JMenuBar(); }
    private static JComponent buildToolBar() {
        JToolBar tb = new JToolBar();
        tb.add(new JButton("Open"));
        tb.add(new JButton("Save"));
        return tb;
    }
    private static JComponent buildStatusBar() {
        JLabel l = new JLabel(" Ready"); l.setOpaque(true); l.setBackground(java.awt.Color.LIGHT_GRAY);
        return l;
    }
    private static JComponent buildProjectTree() {
        return new JScrollPane(new JTree());
    }
    private static JComponent buildPropertyPanel() {
        return new JScrollPane(new JTable(5, 2));
    }
    private static JComponent buildEditorTabs() {
        JTabbedPane t = new JTabbedPane();
        t.addTab("Main.java", new JScrollPane(new JTextArea()));
        t.addTab("README.md", new JScrollPane(new JTextArea()));
        return t;
    }
}
```

The `width 200!` syntax is a _strong_ size constraint -- MiG enforces it even at the cost
of clipping a neighbour, distinguishing it from `width 200` (preferred). The `push`
keyword on the editor tabs ensures the center component absorbs all remaining slack
regardless of what the docked panels request.

### Example 4 -- BoxLayout with Struts and Glue

```java
import java.awt.*;
import javax.swing.*;

public class BoxButtonRow {
    public static void main(String[] args) {
        JFrame frame = new JFrame("Dialog");
        frame.setDefaultCloseOperation(JFrame.EXIT_ON_CLOSE);

        JPanel content = new JPanel(new BorderLayout(0, 10));
        content.setBorder(BorderFactory.createEmptyBorder(10, 10, 10, 10));

        content.add(new JLabel("Are you sure you want to continue?"), BorderLayout.CENTER);

        JPanel buttons = new JPanel();
        buttons.setLayout(new BoxLayout(buttons, BoxLayout.LINE_AXIS));
        buttons.add(new JButton("Help"));
        buttons.add(Box.createHorizontalGlue());           // pushes remaining buttons right
        buttons.add(new JButton("Cancel"));
        buttons.add(Box.createHorizontalStrut(6));         // small fixed gap
        buttons.add(new JButton("OK"));
        content.add(buttons, BorderLayout.SOUTH);

        frame.setContentPane(content);
        frame.pack();
        frame.setLocationRelativeTo(null);
        frame.setVisible(true);
    }
}
```

`Box.createHorizontalGlue()` returns an invisible component with zero preferred width and
`Integer.MAX_VALUE` maximum width; `BoxLayout` distributes any extra space to it. This is
the classic "Help on the left, OK/Cancel on the right" dialog footer pattern.

---

## Strengths and Weaknesses

### LayoutManager Interface

**Strengths.**

- **Pluggable contract.** Any class implementing `LayoutManager` can drive any container.
  Look-and-feel implementations, IDE designers, and third-party libraries all coexist.
- **Clean sizing model.** The three-tier minimum/preferred/maximum contract is universal
  across the toolkit and maps cleanly to any sizing problem -- including terminal cells.
- **30 years of stability.** Code written against the AWT 1.0 LayoutManager API still
  compiles and runs on modern JVMs.
- **Reflectively introspectable.** The constraint slots and named regions are
  string-based, which makes UI builders straightforward to implement.

**Weaknesses.**

- **String-typed constraints in the original interface** were limiting; `LayoutManager2`
  was a clear retrofit a year later.
- **Mutable Dimension objects.** `preferredLayoutSize` returns a `Dimension` that callers
  must treat as immutable by convention; the interface doesn't enforce this.
- **Pixel-only coordinates.** The contract doesn't accommodate logical units or HiDPI
  scaling; that has to be handled per-manager.
- **No baseline support in the original.** Baseline alignment was added later via
  `Component.getBaseline` (Java 6) and only some managers (`GroupLayout`, `GridBagLayout`)
  actually use it.

### Built-in Managers

**Strengths.**

- **Cover the common cases.** Most simple UIs can be built from BorderLayout + FlowLayout
  - occasional GridLayout without ever touching the harder managers.
- **CardLayout is unique.** No third-party manager improves meaningfully on its
  one-at-a-time semantics.
- **GroupLayout's independent H/V groups** are mathematically sound and produce layouts
  that scale and translate cleanly.

**Weaknesses.**

- **GridBagLayout is the canonical "too many knobs" case study.** Eleven independently
  tunable fields per component, mutation-based API, no error reporting when constraints
  conflict.
- **BoxLayout's reliance on `getMaximumSize`** is fragile; many Swing components
  return `Integer.MAX_VALUE` by default, making layout decisions unpredictable.
- **SpringLayout's API never grew a community** despite its useful constraint model.
- **GroupLayout is verbose** when hand-coded; it's really designed for tools to emit.

### MiG Layout

**Strengths.**

- **One manager subsumes most others.** Forms, grids, docked panels, button rows, tabbed
  switches -- all expressible without nesting different managers.
- **Constraint strings are concise and readable** once learned. The syntax is the most
  popular dialect for Swing UI in the last 15 years.
- **Built-in platform conventions.** The `tag ok`/`tag cancel`/`tag apply` button roles
  make MiG dialogs reorder automatically to match host conventions.
- **Sizegroup makes button rows trivial.** Aligning button widths across a dialog is one
  property per button, not custom sizing code.
- **Debug mode** draws colored overlays showing cells, gaps, and constraint failures.
- **Cross-toolkit.** Same syntax on Swing, JavaFX (`MigPane`), and SWT.

**Weaknesses.**

- **Strings are untyped.** Typos surface only at runtime; misspelled keywords are
  silently ignored or produce confusing error messages.
- **Discoverability is poor.** New developers must consult the cheat sheet; the constraint
  vocabulary is large.
- **Third-party dependency.** Not in the JDK, has to be brought in via Maven.
- **JavaFX adoption.** The official JavaFX team prefers their own `GridPane`/`HBox`/`VBox`
  hierarchy; `MigPane` is a community choice rather than a default.
- **Same model limits.** Like all rectangle-cell layouts, it can't express overlapping or
  z-ordered widgets without falling back to manual positioning.

### Mapping to Terminal Layouts

Swing's layout heritage maps surprisingly well onto a terminal:

- **`preferredLayoutSize`/`minimumLayoutSize` -> intrinsic widget sizes in cells.** A
  paragraph widget has a preferred width (its longest line) and a minimum (some
  reasonable wrap point). A scrollbar has a fixed 1-cell width.
- **`maximumLayoutSize` -> "fill" semantics.** A widget with effectively infinite max grows
  to fill available cells; one with a finite max keeps its preferred size and lets the
  layout center it.
- **Baseline alignment is irrelevant** in a fixed-grid terminal -- all text already shares
  a baseline -- but the _concept_ of aligning label/field rows survives.
- **`GridBagConstraints.fill` / `anchor` / `weightx` translate directly** to TUI grid
  systems like Ratatui's `Constraint::Fill(weight)`, gtk-rs's `expand`/`align`, or Ink's
  `flexGrow`/`alignItems`.
- **MiG's `dock` keyword** is exactly Ratatui's edge-anchored layout pattern, and matches
  the BorderLayout regions one-to-one.

For a Sparkles TUI layout module, the lesson is that _one_ small layout DSL based on
column constraints, row constraints, and per-component cell specifications can subsume
the most common use cases. MiG demonstrates that the constraint-string approach scales;
the design-by-introspection approach in D could lift that DSL into compile-time-checked
templates (so `wrap 2` and `[grow,fill]` become type-checked operations rather than
string parsing).

---

## References

- **Java SE API documentation:**
  - [`java.awt.LayoutManager`][lm]
  - [`java.awt.LayoutManager2`][lm2]
  - [`java.awt.BorderLayout`](https://docs.oracle.com/en/java/javase/21/docs/api/java.desktop/java/awt/BorderLayout.html)
  - [`java.awt.FlowLayout`](https://docs.oracle.com/en/java/javase/21/docs/api/java.desktop/java/awt/FlowLayout.html)
  - [`java.awt.GridLayout`](https://docs.oracle.com/en/java/javase/21/docs/api/java.desktop/java/awt/GridLayout.html)
  - [`java.awt.CardLayout`](https://docs.oracle.com/en/java/javase/21/docs/api/java.desktop/java/awt/CardLayout.html)
  - [`java.awt.GridBagLayout`](https://docs.oracle.com/en/java/javase/21/docs/api/java.desktop/java/awt/GridBagLayout.html)
  - [`java.awt.GridBagConstraints`][gbc]
  - [`javax.swing.BoxLayout`](https://docs.oracle.com/en/java/javase/21/docs/api/java.desktop/javax/swing/BoxLayout.html)
  - [`javax.swing.GroupLayout`](https://docs.oracle.com/en/java/javase/21/docs/api/java.desktop/javax/swing/GroupLayout.html)
  - [`javax.swing.SpringLayout`](https://docs.oracle.com/en/java/javase/21/docs/api/java.desktop/javax/swing/SpringLayout.html)
- **Official Swing tutorial:**
  - [A Visual Guide to Layout Managers](https://docs.oracle.com/javase/tutorial/uiswing/layout/visual.html)
  - [Using Layout Managers](https://docs.oracle.com/javase/tutorial/uiswing/layout/using.html)
  - [How to Use GridBagLayout](https://docs.oracle.com/javase/tutorial/uiswing/layout/gridbag.html)
- **MiG Layout:**
  - Main site: <https://www.miglayout.com/>
  - White paper: <https://www.miglayout.com/whitepaper.html>
  - Quick start cheat sheet: <https://www.miglayout.com/QuickStart.pdf>
  - GitHub repository: <https://github.com/mikaelgrev/miglayout>
  - `MigPane` for JavaFX: same repository, `miglayout-javafx` module
- **Related Sparkles research:**
  - Ratatui's `Constraint` model: `../tui-libraries/ratatui.md`
  - Ink / Yoga Flexbox: `../tui-libraries/ink.md`
  - Cassowary constraint solver: `./cassowary.md`
  - Apple Auto Layout: `./auto-layout.md`

[lm]: https://docs.oracle.com/en/java/javase/21/docs/api/java.desktop/java/awt/LayoutManager.html
[lm2]: https://docs.oracle.com/en/java/javase/21/docs/api/java.desktop/java/awt/LayoutManager2.html
[gbc]: https://docs.oracle.com/en/java/javase/21/docs/api/java.desktop/java/awt/GridBagConstraints.html
[mig]: https://www.miglayout.com/
