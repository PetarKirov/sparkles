# CSS Flexbox (W3C Specification)

A one-dimensional, content-aware layout model standardized by the W3C CSS Working
Group as the _CSS Flexible Box Layout Module_. Flexbox provides a coordinate-free
way to distribute, align, and reorder a sequence of boxes along a _main axis_ and a
perpendicular _cross axis_, with first-class support for growing and shrinking
items to fit a container.

| Field                        | Value                                                                                                                                                                                                                               |
| ---------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Specification                | [CSS Flexible Box Layout Module Level 1](https://www.w3.org/TR/css-flexbox-1/)                                                                                                                                                      |
| Editor's Draft               | <https://drafts.csswg.org/css-flexbox/>                                                                                                                                                                                             |
| Editors                      | Tab Atkins Jr. (Google), Elika J. Etemad / fantasai (Apple), Rossen Atanassov (Microsoft)                                                                                                                                           |
| Former Editors               | Alex Mogilevsky, L. David Baron, Neil Deakin, Ian Hickson, David Hyatt                                                                                                                                                              |
| First Working Draft          | _CSS3 Flexible Box Module_ -- 23 July 2009 (using `display: box`)                                                                                                                                                                   |
| Modern syntax                | `display: flex` -- introduced in the 22 March 2012 Working Draft revision                                                                                                                                                           |
| Candidate Recommendation     | 18 September 2012; reinstated to CR with major revisions through 2014-2018                                                                                                                                                          |
| Current Level (date)         | Candidate Recommendation Draft, 14 October 2025                                                                                                                                                                                     |
| Reference Implementations    | Blink (Chromium), WebKit (Safari), Gecko (Firefox), Servo                                                                                                                                                                           |
| Notable Non-browser Adoption | [Yoga](./yoga.md) (Meta), [Taffy](./taffy.md) (Rust), [Stretch](./stretch.md), React Native, [Ink](../tui-libraries/ink.md), [Textual](../tui-libraries/textual.md) (CSS subset), Flutter (`Flex`/`Row`/`Column`), Qt Quick Layouts |

---

## Overview

### What It Solves

Flexbox addresses a category of layout problems that the original CSS 2 box model
made awkward at best and impossible at worst:

- **Distributing free space.** Given a row of items and a container, how is the
  surplus or deficit space divided among them?
- **Centering along two axes.** Vertically centering a block of unknown height
  inside another block of unknown height was the canonical CSS koan for over a
  decade.
- **Reordering visual content independently of source order.** The `order`
  property lets visual presentation diverge from DOM order without scripting
  (with carefully documented accessibility caveats).
- **Equal-height columns.** Two side-by-side blocks whose heights track each
  other regardless of content length.
- **Sticky footers, holy-grail layouts, navigation bars.** Patterns that were
  routinely implemented with floats, negative margins, table-cell hacks, or
  `position: absolute` arithmetic.

The unifying theme is **direction-agnostic, content-aware distribution of space
along a single axis**, with a secondary alignment axis. Where the legacy block
model expressed layout in terms of physical edges (`top`, `left`, `margin-right`,
clearing floats), flexbox expresses it in terms of logical roles -- _main start_,
_main end_, _cross start_, _cross end_ -- that adapt to writing mode and
direction.

### Design Philosophy

The specification frames flexbox as "a CSS box model optimized for user interface
design." Three design principles stand out:

1. **One dimension at a time.** Flexbox is deliberately a _one-dimensional_
   model. A flex container lays out children along a single axis; multi-line
   wrap is supported, but the cross axis is for alignment, not for independent
   sizing of rows and columns. For two-dimensional layout, the working group
   later produced CSS Grid (see [css-grid.md](./css-grid.md)).

2. **Content-aware sizing with explicit overrides.** Each flex item carries an
   intrinsic _hypothetical main size_ derived from its content (and from the
   `flex-basis` property). The flex algorithm then redistributes free space
   according to per-item `flex-grow` and `flex-shrink` factors. The author
   controls _how flexible_ each item is, not _what size_ it is.

3. **Logical, writing-mode-aware.** Flexbox was the first widely adopted CSS
   layout module to model start/end edges rather than left/right. A
   `flex-direction: row` container in an Arabic (`dir="rtl"`) document
   automatically reverses its main axis. Similarly, `flex-direction: column`
   follows the block axis of the document.

### History

Flexbox is the third generation of CSS "box" specifications and bears scars from
all three:

- **CSS 2 / CSS 2.1 (1998-2011).** Visual formatting was based on block boxes,
  inline boxes, floats, and absolute positioning. None of these were designed
  for application UI. Vertical centering was a recurring pain point; equal-height
  columns required `display: table-cell`, faux backgrounds, or scripting.

- **`display: box` -- the XUL-flavoured draft (2009).** The first
  CSS3 Flexible Box draft, published 23 July 2009, used `display: box` with
  `box-orient`, `box-direction`, `box-flex`, `box-pack`, and `box-align`
  properties. This vocabulary was inherited from Mozilla's XUL layout language
  (which had powered Firefox's chrome since 2002) and from analogous primitives
  in Microsoft's Silverlight `StackPanel`. Browsers shipped vendor-prefixed
  implementations (`-webkit-box`, `-moz-box`, `-ms-box`) that are still
  occasionally encountered when supporting very old browsers.

- **`display: flexbox` -- the abandoned middle (2011).** A brief intermediate
  syntax with two-value `flex()` notation. It never shipped to stable browsers
  but generated enough churn that the working group's "tweener" syntax remains
  in some legacy support tables.

- **`display: flex` -- the modern syntax (2012-present).** The 22 March 2012
  Working Draft introduced the current property names: `flex-direction`,
  `flex-wrap`, `flex-flow`, `justify-content`, `align-items`, `align-self`,
  `align-content`, `flex-grow`, `flex-shrink`, `flex-basis`, and the `flex`
  shorthand. The specification reached W3C Candidate Recommendation in
  September 2012 and has remained at CR through several editorial revisions.
  The most recent CR Draft is dated 14 October 2025.

- **Box Alignment Module (2016-).** The alignment properties
  (`justify-content`, `align-items`, etc.) were generalized into the [CSS Box
  Alignment Module Level 3](https://www.w3.org/TR/css-align-3/), which now
  defines them for flexbox, grid, and block layout. Flexbox is therefore both a
  consumer and a historical source of those properties.

---

## Layout Model

### Containers and Items

A flex container is established by

```css
.container {
  display: flex; /* block-level flex container */
}

.inline-container {
  display: inline-flex; /* inline-level flex container */
}
```

Direct in-flow children of the container become _flex items_. Anonymous flex
items are generated to wrap runs of text or inline content that appear directly
inside a flex container.

```html
<div class="container">
  Some text becomes an anonymous flex item.
  <div>Element children become flex items.</div>
  <span>This too.</span>
</div>
```

Within a flex container, several CSS features have no effect or behave
differently:

- `float` and `clear` do not apply to flex items.
- `vertical-align` has no effect on flex items (cross-axis alignment is
  controlled by the alignment properties).
- Margins on adjacent flex items do not collapse.
- `::first-line` and `::first-letter` pseudo-elements do not apply to flex
  containers.

### Main Axis vs Cross Axis

Every flex container has two axes:

- The **main axis** is the axis along which items are laid out, determined by
  `flex-direction`.
- The **cross axis** is perpendicular to the main axis.

Each axis has a _start_ and _end_ edge, named logically:

```
flex-direction: row;                     flex-direction: column;
                                         (LTR writing mode)
   main-start ----------> main-end             cross-start
                                                   |
   +------+  +------+  +------+                +-------+
   | item |  | item |  | item |   <- cross   ^ |  item | <- main
   +------+  +------+  +------+      end     | +-------+    end
                                             | +-------+
   <- cross-start                       main | |  item |
                                       start | +-------+
                                             | +-------+
                                             | |  item |
                                             v +-------+
                                                cross-end
```

The four `flex-direction` keywords --- `row`, `row-reverse`, `column`,
`column-reverse` --- pick which physical edge of the container is _main-start_
in a given writing mode. In a left-to-right English document, `row` puts
main-start on the left; in a right-to-left Arabic document, `row` puts
main-start on the right.

### Lines

If `flex-wrap` is not `nowrap`, the container can produce multiple _flex lines_.
Each line lays out its own items along the main axis; lines themselves are
stacked along the cross axis. Single-line containers are by far the most common
case; multi-line flex containers approach the territory where Grid is usually
the better answer.

---

## Sizing Model

### Hypothetical Main Size

Before flexibility is resolved, each flex item is assigned a _hypothetical main
size_. This is derived from:

1. `flex-basis` -- if non-`auto`, this is used directly.
2. Otherwise the main-size property (`width` for row containers, `height` for
   column containers).
3. Otherwise the item's `max-content` size.

`flex-basis: content` (formally specified, supported in modern browsers) forces
the algorithm to use `max-content` regardless of any explicit main-size
property.

### Flexibility: grow, shrink, basis

The three flexibility longhands control how an item responds to surplus or
deficit space:

```css
.item {
  flex-grow: <number>; /* default 0; share of positive free space */
  flex-shrink: <number>; /* default 1; share of negative free space */
  flex-basis: <length-percentage> | auto | content;
}
```

If the sum of hypothetical main sizes is less than the container's main size,
the surplus is distributed in proportion to each item's `flex-grow`. If the sum
exceeds the container, the deficit is distributed in proportion to each item's
`flex-shrink`, scaled by its hypothetical main size (so larger items shrink
more, which gives more intuitive behaviour).

The `flex` shorthand collapses these into a single declaration. The reserved
keywords are:

| Keyword         | Expansion  | Behaviour                                         |
| --------------- | ---------- | ------------------------------------------------- |
| `flex: initial` | `0 1 auto` | Default. Size from content; can shrink, not grow. |
| `flex: auto`    | `1 1 auto` | Size from content; grows and shrinks.             |
| `flex: none`    | `0 0 auto` | Size from content; rigid.                         |
| `flex: 1`       | `1 1 0%`   | Equal share of container; ignores content size.   |
| `flex: 2`       | `2 1 0%`   | Twice the share of a sibling with `flex: 1`.      |

The distinction between `flex: 1` (basis `0`) and `flex: auto` (basis `auto`)
is a frequent source of confusion. `flex: 1` produces _equal-width columns_
because the basis is `0`; `flex: auto` produces _content-proportional columns_
because the basis is the items' content size.

### Intrinsic Sizing

Flex items respect their content's minimum size by default. A `min-width: auto`
or `min-height: auto` flex item refuses to shrink below its `min-content` size
(roughly: the widest unbreakable token or longest indivisible piece of
content). This prevents overflow in the common case but can produce surprises
when a long unbroken string of text refuses to let its container narrow.

The fix is explicit: set `min-width: 0` (for row containers) or `min-height: 0`
(for column containers).

### Aspect Ratio

The `aspect-ratio` property (from [CSS Sizing Level 4](https://www.w3.org/TR/css-sizing-4/))
interacts with flexbox: a flex item with an aspect ratio and an indefinite
cross size derives its cross size from its resolved main size. This is most
useful for media that needs to scale proportionally inside a flex container.

```css
.thumb {
  aspect-ratio: 16 / 9;
  flex: 1 1 200px;
}
```

---

## Alignment

The alignment properties live in the [CSS Box Alignment
Module](https://www.w3.org/TR/css-align-3/), but flexbox was the layout module
that drove their design. They split naturally into main-axis vs cross-axis and
container-level vs item-level.

### Main-Axis Alignment (`justify-content`)

`justify-content` distributes free space along the main axis. It is a
container-level property; in flexbox there is _no_ `justify-self` for
individual items (Grid does support `justify-self`).

```css
.container {
  display: flex;
  justify-content: flex-start /* default */ | flex-end | center | space-between
    /* first/last flush to edges */ | space-around
    /* half-size gutters on the outside */ | space-evenly
    /* full-size gutters everywhere */;
}
```

### Cross-Axis Alignment (`align-items` / `align-self`)

`align-items` aligns _all_ items along the cross axis; `align-self` overrides
it for a single item.

```css
.container {
  align-items: stretch;
} /* default: items fill cross axis */
.container {
  align-items: flex-start;
}
.container {
  align-items: center;
}
.container {
  align-items: baseline;
} /* aligns text baselines */

.special-item {
  align-self: flex-end;
}
```

The `baseline` value is particularly useful for aligning rows of form
controls or text-and-icon pairings; it inspects the dominant baseline of each
item's content.

### Multi-Line Alignment (`align-content`)

When a container has multiple flex lines (i.e., `flex-wrap: wrap` is in
effect), `align-content` distributes the lines themselves along the cross axis,
analogously to how `justify-content` distributes items along the main axis.

```css
.container {
  flex-wrap: wrap;
  align-content: stretch /* default */ | flex-start | center | space-between |
    space-around | space-evenly;
}
```

`align-content` has no effect on single-line flex containers.

### Shorthands

The Box Alignment module defines two shorthands. They are accepted in flexbox
contexts:

```css
.container {
  place-content: <align-content> <justify-content>;
  place-items: <align-items> <justify-items>;
}
```

Note that `justify-items` has no effect on flex items (flexbox does not honor
per-item `justify-self`), so `place-items` in a flex container is effectively
just `align-items`.

### Gaps

The `gap` property (and its longhands `row-gap` / `column-gap`) applies to flex
containers, adding minimum gutters between adjacent items and between adjacent
lines:

```css
.container {
  display: flex;
  flex-wrap: wrap;
  gap: 1rem 0.5rem; /* row-gap, column-gap */
}
```

This was originally a Grid feature; it was promoted to flex containers in 2018
and has wide browser support today.

---

## Code Examples

### 1. Centering an Element

The textbook example, finally a one-liner:

```html
<div class="centered">
  <p>Centered both ways.</p>
</div>
```

```css
.centered {
  display: flex;
  justify-content: center;
  align-items: center;
  min-height: 100vh;
}
```

### 2. Navigation Bar with Logo and Action Group

```html
<nav class="topbar">
  <a class="logo" href="/">Sparkles</a>
  <ul class="links">
    <li><a href="/docs">Docs</a></li>
    <li><a href="/blog">Blog</a></li>
    <li><a href="/contact">Contact</a></li>
  </ul>
  <button class="cta">Sign in</button>
</nav>
```

```css
.topbar {
  display: flex;
  align-items: center;
  gap: 1rem;
  padding: 0.75rem 1.25rem;
}

.topbar .links {
  display: flex;
  gap: 0.75rem;
  list-style: none;
  margin: 0;
  padding: 0;

  margin-inline-start: auto; /* push links and CTA to the end */
}
```

The `margin-inline-start: auto` idiom consumes all free space on the main
axis and so pushes the element (and everything after it) to the end. It
predates `justify-content: space-between` but remains the most flexible way
to split a flex row into "stuck to start" and "stuck to end" groups.

### 3. Sticky Footer

A footer that hugs the bottom of the viewport when content is short, and is
pushed below the content when it is long.

```html
<body class="layout">
  <header>Header</header>
  <main>...page content...</main>
  <footer>Footer</footer>
</body>
```

```css
.layout {
  display: flex;
  flex-direction: column;
  min-height: 100vh;
}

.layout > main {
  flex: 1; /* 1 1 0 -- main grows to fill remaining space */
}
```

### 4. Equal-Height Cards

A row of cards where each card grows to fill available width and the row's
height is determined by the tallest card.

```html
<div class="cards">
  <article class="card">
    <h3>First</h3>
    <p>Short.</p>
  </article>
  <article class="card">
    <h3>Second</h3>
    <p>Quite a bit longer body...</p>
  </article>
  <article class="card">
    <h3>Third</h3>
    <p>Medium-length body.</p>
  </article>
</div>
```

```css
.cards {
  display: flex;
  gap: 1rem;
  align-items: stretch; /* default; cards stretch to row height */
}

.card {
  flex: 1 1 0; /* equal width regardless of content */
  display: flex;
  flex-direction: column;
  padding: 1rem;
  border: 1px solid #ddd;
  border-radius: 8px;
}

.card p {
  flex: 1; /* push card footer to bottom if present */
}
```

### 5. Wrapped Tag List with Responsive Reflow

```html
<ul class="tags">
  <li>typescript</li>
  <li>rust</li>
  <li>flexbox</li>
  <li>css-grid</li>
  <li>terminal-ui</li>
  <li>layout-engines</li>
</ul>
```

```css
.tags {
  display: flex;
  flex-wrap: wrap;
  gap: 0.5rem;

  list-style: none;
  margin: 0;
  padding: 0;
}

.tags li {
  padding: 0.25rem 0.5rem;
  background: #eef;
  border-radius: 999px;
  white-space: nowrap;
}
```

When the viewport narrows, items wrap onto additional lines automatically
without media queries.

---

## Interaction with Other Layout Modes

- **Inline children of flex containers** are _blockified_: an inline element
  that becomes a flex item is treated as if its `display` were the corresponding
  block-level value.
- **`position: absolute` flex items** are removed from the flow as in any
  layout mode; their static position is determined by their alignment
  properties.
- **`float` and `clear`** have no effect on flex items.
- **Tables inside flex containers** retain their own internal layout but
  participate as a single flex item.
- **Grid items can also be flex containers** and vice versa. The common pattern
  is a Grid page-level skeleton with flex-laid rows inside each named area.
- **Block containers can adopt flex semantics for their children** simply by
  changing `display: block` to `display: flex` -- there is no requirement to
  restructure the markup.
- **Vertical-writing-mode interactions:** under `writing-mode: vertical-rl`,
  the `row` main axis becomes physically vertical. This is by design but is
  occasionally a source of confusion when porting layouts to Japanese or
  Mongolian content.

---

## Strengths and Weaknesses

### For App Layout

**Strengths.** Flexbox excels at the _components_ of an application UI: tool
bars, button groups, side-by-side panels with one fixed and one elastic side,
sticky footers, vertically-centred dialogs. The alignment vocabulary is direct
and matches how designers describe interfaces ("space these out", "centre this
on the cross axis"). `flex: 1` gives an immediately readable "this part fills
the rest" semantics that legacy CSS could not approach.

**Weaknesses.** Flexbox is one-dimensional. As soon as a layout needs _both_
columns and rows to line up (a table-like data grid, a magazine-style page
template, an album cover gallery with consistent row heights), the model
strains. Authors often nest flex containers to fake two-dimensional behaviour,
but the result is fragile -- changing the content of one cell in column 2 will
not affect column 3 as a 2D model would expect.

The minimum-content default (`min-width: auto`) catches authors off-guard. The
`order` property is widely useful but has well-documented accessibility
pitfalls because screen-reader and keyboard navigation order follows DOM order,
not visual order.

### For Typography and Flowing Text

**Strengths.** Baseline alignment makes flex containers good for rows of mixed
content where text must align by baseline (an icon next to a label, a numeric
field next to its unit). The `gap` property gives consistent spacing without
margin-collapsing surprises.

**Weaknesses.** Flexbox does not flow text _between_ items. There is no
multi-column text layout, no equivalent of CSS columns, no automatic
hyphenation across boxes. Multi-line flex containers wrap _items_, not
content within items. For long-form prose, block layout (or [CSS
Multi-column](https://www.w3.org/TR/css-multicol-1/)) remains the right tool.

### For Static One-Shot Rendering (e.g., Embedding in a Terminal Renderer)

This is the angle most relevant to Sparkles. Several non-browser engines
implement a flexbox subset for _headless_ rendering -- computing geometry once
and emitting either ANSI cells, a native view tree, or a printable image.

**Strengths.**

- The algorithm is well-defined and produces deterministic output for a given
  tree, container size, and writing mode.
- Most CLI/TUI layouts are one-dimensional in practice: a header row, a body
  region split horizontally, a footer row. Flexbox maps naturally.
- Content-aware sizing is exactly what a terminal wants: text has a measurable
  cell width, and `min-content` is "the longest token".
- `flex-grow` / `flex-shrink` provide the same expressiveness as Ratatui's
  constraint solver (`Length`, `Min`, `Max`, `Fill`) but with a more familiar
  vocabulary.

**Weaknesses.**

- The full algorithm is large. A faithful implementation (Yoga, Taffy) is on
  the order of 5-10 KLoC, and a fair share of it deals with edge cases that
  rarely matter for terminal output (`writing-mode`, `aspect-ratio` plus
  intrinsic ratios, baseline of unrelated rows).
- Percentages depend on definite containing-block sizes, which interacts
  awkwardly with content-measured widths in terminals.
- Float, absolute positioning, and inline layout interactions are
  underspecified for non-browser use; implementers either reject those
  features outright (Yoga, Taffy) or approximate them.
- The performance characteristics assume a tree that mostly fits in cache;
  for very deep trees, each level can require two passes (one for
  hypothetical sizes, one for resolved sizes plus alignment).

---

## Non-browser Implementations

A short tour of the most influential non-browser flexbox engines:

- **[Yoga](./yoga.md)** -- Meta's C++ flexbox engine, originally extracted from
  React Native's iOS bridge. Used by React Native, the original Litho, and
  several JavaScript runtimes (notably [Ink](../tui-libraries/ink.md), which
  uses `yoga-layout` to lay out terminal output). Yoga implements a flexbox
  subset plus a handful of useful extensions (`PositionType.Absolute` without
  CSS box-generation rules, `MeasureFunc` callbacks for content-measured
  nodes).

- **[Taffy](./taffy.md)** -- A pure-Rust layout engine implementing flexbox,
  Grid (Level 1), and a "block" mode for nested containers. Used by the
  [Bevy](https://bevyengine.org/) game engine for UI and by various Rust GUI
  toolkits. Taffy is notable for being one of the few engines to ship a
  practical Grid implementation outside browsers.

- **[Stretch](./stretch.md)** -- An earlier Rust port of Yoga. No longer
  actively maintained; Taffy is its de facto successor.

- **Servo's `layout_2020`** -- Servo's experimental layout engine includes a
  flexbox implementation that has been ported into Firefox via Stylo.

- **[Ink](../tui-libraries/ink.md)** -- A React renderer for terminals that
  embeds Yoga. Box elements participate in flex layout, and the resulting
  geometry drives ANSI cell emission. See the Ink research note for details
  of the embedding.

- **[Textual](../tui-libraries/textual.md)** -- A Python TUI framework that
  implements a _subset of CSS_, including flexbox-style alignment via its own
  layout algorithm. Not a literal flexbox engine, but it borrows the
  vocabulary and the mental model.

- **Flutter** -- The `Row` / `Column` / `Flex` widgets implement a model
  closely modeled on flexbox, with `MainAxisAlignment`, `CrossAxisAlignment`,
  `flex` factors on `Expanded`, and intrinsic-sizing-aware `Flexible` widgets.

- **Qt Quick Layouts (`RowLayout`, `ColumnLayout`)** -- Qt's QML layout
  primitives also borrow the flexbox vocabulary, with `Layout.fillWidth`,
  `Layout.preferredWidth`, and alignment enumerations.

---

## References

### Specifications

- [CSS Flexible Box Layout Module Level 1](https://www.w3.org/TR/css-flexbox-1/) (W3C CR)
- [CSS Flexible Box Layout Editor's Draft](https://drafts.csswg.org/css-flexbox/) (CSSWG)
- [CSS Box Alignment Module Level 3](https://www.w3.org/TR/css-align-3/) -- alignment properties shared with Grid and Block
- [CSS Sizing Module Level 3](https://www.w3.org/TR/css-sizing-3/) and [Level 4](https://www.w3.org/TR/css-sizing-4/) -- `min-content`, `max-content`, `fit-content`, `aspect-ratio`
- [CSS Writing Modes Module Level 4](https://www.w3.org/TR/css-writing-modes-4/) -- logical direction definitions

### MDN

- [CSS flexible box layout](https://developer.mozilla.org/en-US/docs/Web/CSS/CSS_flexible_box_layout)
- [Basic concepts of flexbox](https://developer.mozilla.org/en-US/docs/Web/CSS/CSS_flexible_box_layout/Basic_concepts_of_flexbox)
- [Aligning items in a flex container](https://developer.mozilla.org/en-US/docs/Web/CSS/CSS_flexible_box_layout/Aligning_items_in_a_flex_container)
- [Controlling ratios of flex items along the main axis](https://developer.mozilla.org/en-US/docs/Web/CSS/CSS_flexible_box_layout/Controlling_ratios_of_flex_items_along_the_main_axis)
- [Ordering flex items](https://developer.mozilla.org/en-US/docs/Web/CSS/CSS_flexible_box_layout/Ordering_flex_items)
- [Mastering wrapping of flex items](https://developer.mozilla.org/en-US/docs/Web/CSS/CSS_flexible_box_layout/Mastering_wrapping_of_flex_items)
- [Typical use cases of flexbox](https://developer.mozilla.org/en-US/docs/Web/CSS/CSS_flexible_box_layout/Typical_use_cases_of_flexbox)
- [Relationship of flexbox to other layout methods](https://developer.mozilla.org/en-US/docs/Web/CSS/CSS_flexible_box_layout/Relationship_of_flexbox_to_other_layout_methods)

### Articles and Talks

- Rachel Andrew, _Flexbox: don't forget about old browsers_, Smashing Magazine (2016).
- Rachel Andrew, _The Difference Between Width and Flex-Basis_ -- 24ways.org / Smashing Magazine.
- Jen Simmons, _The Layout Layer_ -- talk discussing flexbox, grid, and their complementary roles.
- Chris Coyier et al., _A Complete Guide to Flexbox_, CSS-Tricks (continuously updated since 2013).
- Tab Atkins Jr., personal blog posts on the evolution of flexbox and the
  alignment module (`xanthir.com`).

### Sister Documents in This Catalog

- [CSS Grid](./css-grid.md) -- two-dimensional sibling specification.
- [Yoga](./yoga.md) -- Meta's reference flexbox-subset engine.
- [Taffy](./taffy.md) -- Rust flexbox+grid engine.
- [Stretch](./stretch.md) -- earlier Rust port of Yoga.
- [Ink](../tui-libraries/ink.md) -- Node.js TUI framework embedding Yoga.
- [Textual](../tui-libraries/textual.md) -- Python TUI framework with a CSS subset.
