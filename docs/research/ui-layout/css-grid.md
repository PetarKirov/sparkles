# CSS Grid (W3C Specification)

A two-dimensional, line-based layout model standardized by the W3C CSS Working
Group as the _CSS Grid Layout Module_. Grid lets authors carve a container into
named or numbered tracks, place children explicitly into rows and columns, and
distribute remaining space along _both_ axes simultaneously -- the feature that
sets it apart from flexbox.

| Field                        | Value                                                                                                                                                                                                      |
| ---------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Specification (Level 1)      | [CSS Grid Layout Module Level 1](https://www.w3.org/TR/css-grid-1/)                                                                                                                                        |
| Specification (Level 2)      | [CSS Grid Layout Module Level 2](https://www.w3.org/TR/css-grid-2/)                                                                                                                                        |
| Editor's Draft               | <https://drafts.csswg.org/css-grid/>                                                                                                                                                                       |
| Editors                      | Tab Atkins Jr. (Google), Elika J. Etemad / fantasai (Apple), Rossen Atanassov (Microsoft), Oriol Brufau (Igalia)                                                                                           |
| Former Editor (Level 1)      | Rachel Andrew (until 2017)                                                                                                                                                                                 |
| First public Working Draft   | _CSS Grid Layout Module_ -- 7 April 2011                                                                                                                                                                   |
| First Level 1 CR             | 9 September 2016                                                                                                                                                                                           |
| Level 1 became W3C Rec       | 18 December 2020                                                                                                                                                                                           |
| Current Level 2 (date)       | Candidate Recommendation Draft, 26 March 2025                                                                                                                                                              |
| Browser ship date            | March 2017 (Chrome 57, Firefox 52, Safari 10.1; Edge later)                                                                                                                                                |
| Reference Implementations    | Blink (Chromium), WebKit (Safari), Gecko (Firefox), Servo                                                                                                                                                  |
| Notable Non-browser Adoption | [Taffy](./taffy.md) (Rust -- among the few non-browser engines with practical Grid support), Servo's `layout_2020`, Mozilla's Stylo; partial support in some design tools (Webflow, Framer, Figma plugins) |

---

## Overview

### What It Solves

CSS Grid addresses a class of layout problems that _neither_ the original block
model _nor_ flexbox can express cleanly:

- **Two-dimensional alignment.** Items that need to line up _both_ with their
  row neighbours _and_ their column neighbours -- the canonical example being a
  data table or a card gallery with consistent row heights and column widths.
- **Page-level templates.** "Header at top, sidebar on the left, main in the
  middle, ads on the right, footer at the bottom" expressed as a single
  declaration rather than five nested containers.
- **Overlapping items.** Multiple grid items can occupy the same cell. Combined
  with `z-index`, this gives a clean alternative to absolutely-positioned
  overlay layouts.
- **Source-order independence.** A grid item can be placed at any cell
  regardless of its position in the DOM, with documented accessibility caveats.
- **Responsive track counts without media queries.** `repeat(auto-fill,
minmax(min, 1fr))` produces a layout that adapts the _number_ of columns to
  the container width.

The unifying theme is **first-class two-dimensional structure**: rows and
columns are explicit, line-named geometry that items refer to, rather than an
emergent property of how children happen to wrap.

### Design Philosophy

The specification frames CSS Grid as "a two-dimensional grid-based layout
system, optimized for user interface design." Several design principles
distinguish it from flexbox:

1. **Top-down sizing.** Where flexbox sizes the container around its content,
   Grid lets the _container_ dictate the track sizes (the explicit grid) and
   the items adjust. Authors can size tracks first, then assign items to them.
2. **Explicit and implicit tracks.** The author declares the _explicit_ grid;
   any items placed outside it cause the engine to materialize _implicit_
   tracks, sized by `grid-auto-rows` / `grid-auto-columns`.
3. **Line-based placement.** Items are positioned by _grid lines_, not by
   their siblings. A change in one item's source order has no effect on the
   layout of the others.
4. **Two-axis alignment.** Both `justify-self` and `align-self` are honoured
   for grid items -- unlike flexbox, where `justify-self` does nothing.
5. **Overlapping is a feature, not a bug.** Grid explicitly supports multiple
   items in one cell, and the auto-placement algorithm does the right thing
   when only some items are explicitly placed.

### History

CSS Grid is the third major attempt at a two-dimensional CSS layout model and
the first to ship interoperably.

- **`<table>` abuse (1996-2010).** Through the late 1990s and 2000s, most
  multi-column web layouts were built with HTML `<table>` elements used purely
  for presentation. This worked but was semantically incorrect, hostile to
  assistive technology, and inflexible (cells could not be reordered without
  rewriting markup).

- **CSS 2.1 `display: table-*` (2011).** CSS 2.1 codified table-cell layout as
  a `display` value, letting authors get table-like behaviour from `<div>`
  elements. This was an improvement on the markup hack but inherited all the
  layout inflexibility of real tables (no overlapping, no row-spanning across
  groups, no source-order independence).

- **XUL grids (Mozilla, 2002-2017).** Mozilla's XUL layout language, which
  powered Firefox's chrome until the late 2010s, supported a grid box model
  with named cells and explicit rows/columns. Several XUL ideas (named lines,
  named areas, explicit-vs-implicit grids) flowed into the W3C specification.

- **Silverlight `Grid` (Microsoft, 2008).** Silverlight, Microsoft's
  short-lived Flash competitor, included a `Grid` panel with `Grid.Row`,
  `Grid.Column`, `Grid.RowSpan`, `Grid.ColumnSpan`, and proportional sizing via
  the `*` unit. Phil Cupp at Microsoft drove much of this work and later
  brought it to the W3C as the _CSS Grid Layout Module_ in 2011, when
  Microsoft shipped an early `-ms-grid` implementation in IE 10.

- **`-ms-grid` (IE 10, 2012).** Internet Explorer 10 shipped the first
  browser-side implementation, prefixed and based on the early draft. It
  introduced track-list syntax with the proportional `fr`-equivalent (called
  `*` in `-ms-grid`) and named lines, but lacked named areas, subgrid, and
  most of the auto-placement algorithm. Many of its quirks persisted in Edge
  legacy until Edge switched to Blink in 2020.

- **CSS Grid Level 1 (2011-2017).** Rachel Andrew became the level's
  evangelist and an editor of the specification. Through the mid-2010s she
  ran [Grid by Example](https://gridbyexample.com/) and a series of
  conference talks; Jen Simmons (then at Mozilla) ran the _Layout Land_
  YouTube series and the _Resilient Web Design_ book chapter. Their advocacy
  drove rapid implementation in all major browsers, culminating in
  near-simultaneous shipping in **March 2017** (Chrome 57, Firefox 52, Safari
  10.1). Level 1 became a W3C Recommendation on 18 December 2020.

- **CSS Grid Level 2 -- subgrid (2018-).** Level 2 adds the `subgrid` keyword,
  letting a nested grid adopt the parent grid's lines along one or both axes.
  Firefox shipped subgrid in 2019; Safari followed in 2022; Chromium shipped
  it in late 2023 (Chrome 117). As of 2025, subgrid is Baseline Widely
  Available.

- **CSS Grid Level 3 -- masonry (proposed).** A separate Level 3 draft adds a
  _masonry_ track sizing keyword, modeled on Pinterest-style staggered
  layouts. The proposal was contested in 2024 (Apple and Google initially
  disagreed on whether to put masonry under `grid` or a new `display:
masonry`); the working group converged on a Grid-based syntax in early 2025
  and Safari shipped an experimental implementation. As of late 2025 it is
  not yet broadly interoperable.

---

## Layout Model

### Tracks, Lines, Cells, Areas

A grid container introduces a coordinate system over its child area:

- **Tracks** are the rows and columns themselves -- the _spaces_ between
  adjacent lines.
- **Lines** are the dividers between tracks. Lines are numbered starting at 1
  on the leading edge of the first track, and authors can name them.
- **Cells** are the intersection of a row track and a column track -- the
  smallest unit of the grid.
- **Areas** are rectangular regions of one or more cells, typically named via
  `grid-template-areas` and referenced by `grid-area`.

```
                   col-line 1    col-line 2    col-line 3    col-line 4
                       v             v             v             v
       row-line 1 ---> +-------------+-------------+-------------+
                       |  cell 1,1   |  cell 1,2   |  cell 1,3   |
                       |             |             |             |
       row-line 2 ---> +-------------+-------------+-------------+
                       |  cell 2,1   |  cell 2,2   |  cell 2,3   |
                       |             |             |             |
       row-line 3 ---> +-------------+-------------+-------------+

                       <-- col 1 --> <-- col 2 --> <-- col 3 -->
```

### Containers and Items

A grid container is established by `display: grid` (block-level) or
`display: inline-grid` (inline-level). In-flow children become _grid items_.

```css
.gallery {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  grid-template-rows: auto auto;
  gap: 1rem;
}
```

As in flexbox, several CSS features are suppressed inside grid containers:

- `float` and `clear` do not apply to grid items.
- `vertical-align` has no effect.
- Margin collapsing does not occur between grid items.
- `::first-line` / `::first-letter` do not apply to the grid container.

Inline grid items are blockified just as flex items are.

### Explicit vs Implicit Grid

The _explicit grid_ is the one declared by the author via
`grid-template-columns`, `grid-template-rows`, and/or `grid-template-areas`.

The _implicit grid_ is generated automatically by the engine when items are
placed outside the explicit grid (e.g., assigned to row 10 of a 3-row explicit
grid) or when there are more items than the explicit grid has cells to hold
them. The size of implicit tracks is controlled by `grid-auto-rows` and
`grid-auto-columns`; the direction in which new tracks are created is
controlled by `grid-auto-flow`.

```css
.gallery {
  display: grid;
  grid-template-columns: repeat(4, 1fr); /* explicit: 4 columns */
  grid-template-rows: 100px; /* explicit: 1 row */

  grid-auto-rows: 80px; /* implicit rows: 80px each */
  grid-auto-flow: row dense; /* fill row-by-row, dense packing */
}
```

`grid-auto-flow: dense` makes the auto-placement algorithm backfill earlier
holes when later items would fit, at the cost of decoupling visual order from
DOM order more aggressively.

---

## Sizing Model

Track sizing is where Grid's vocabulary is richest. Each track size accepts a
`<track-size>` value, which can be a length, percentage, `fr`, intrinsic
keyword, or a `minmax()` / `fit-content()` function.

### The `fr` Unit

The `fr` unit means _fraction of the remaining space_. After all non-flexible
track sizes are subtracted from the grid's inline (or block) size, what is
left is divided in proportion to each track's `fr` factor.

```css
.three-col {
  display: grid;
  grid-template-columns: 200px 1fr 2fr;
}
/* If container is 800px and gap is 0:
     col1 = 200px
     col2 = (800 - 200) * (1 / 3) = 200px
     col3 = (800 - 200) * (2 / 3) = 400px
*/
```

`fr` is _not_ a percentage. It does not interact with `box-sizing`. It is
unique to grid track sizing.

### Intrinsic Sizing Keywords

Grid track sizes accept the intrinsic keywords from [CSS Sizing
Level 3](https://www.w3.org/TR/css-sizing-3/):

- **`min-content`** -- the smallest size the track can take without overflowing,
  determined by the longest unbreakable token in the track's content.
- **`max-content`** -- the largest size the track would take if given infinite
  space.
- **`auto`** -- behaves like `minmax(auto, max-content)`; the track is sized to
  fit content but can shrink when there is not enough room.
- **`fit-content(<length-percentage>)`** -- equivalent to
  `minmax(auto, max-content)` clamped at the given limit.

### `minmax(min, max)`

Defines a track size with both a minimum and maximum. Either bound can be a
length, percentage, intrinsic keyword, or (for `max`) an `fr` value.

```css
.responsive {
  display: grid;
  grid-template-columns: repeat(3, minmax(0, 1fr));
  /* `minmax(0, 1fr)` is the standard "let me shrink below content" idiom;
     without the `0` minimum, fr tracks default to a min of auto/min-content. */
}
```

### `repeat()`, `auto-fill`, and `auto-fit`

The `repeat()` notation is the workhorse for non-trivial track lists:

```css
grid-template-columns: repeat(12, 1fr); /* fixed count */
grid-template-columns: repeat(2, 100px 1fr 100px); /* repeated pattern */
grid-template-columns: 20px repeat(6, 1fr) 20px; /* mixed with fixed */
```

For _responsive_ track counts -- letting the container decide how many
columns to draw -- `auto-fill` and `auto-fit` are essential:

```css
.card-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(220px, 1fr));
  gap: 1rem;
}
```

- **`auto-fill`** keeps track slots even when they are empty, producing a
  consistent column rhythm.
- **`auto-fit`** _collapses_ empty trailing tracks down to zero, allowing
  remaining tracks to grow into the space.

In a grid with three items and `minmax(220px, 1fr)`:

- With `auto-fill`, on a 1200 px container you get five 220 px slots, three
  filled, two empty but reserving space.
- With `auto-fit`, you get three items that each take ~400 px.

### Aspect Ratio

The `aspect-ratio` property applies to grid items the same way it applies to
flex items: an item with an aspect ratio and an indefinite size on one axis
derives the other axis from the ratio. This is widely used for media thumbnails
in card grids.

```css
.thumb {
  aspect-ratio: 1 / 1;
  width: 100%;
}
```

### Named Lines

Any track-list slot can carry a name in square brackets:

```css
.page {
  display: grid;
  grid-template-columns:
    [page-start] 1fr
    [content-start] 720px
    [content-end] 1fr
    [page-end];
}

article {
  grid-column: content-start / content-end;
}
```

A single line can have multiple names (`[a b c]`), which is occasionally
convenient for "this is both the end of column 2 and the start of column 3"
patterns.

### Named Areas (`grid-template-areas`)

`grid-template-areas` is one of the most distinctive parts of Grid. It defines
_and_ names a 2D template using ASCII art:

```css
.page {
  display: grid;
  grid-template-columns: 220px 1fr 220px;
  grid-template-rows: auto 1fr auto;
  grid-template-areas:
    'header  header  header'
    'nav     main    aside'
    'footer  footer  footer';
  min-height: 100vh;
}

header {
  grid-area: header;
}
nav {
  grid-area: nav;
}
main {
  grid-area: main;
}
aside {
  grid-area: aside;
}
footer {
  grid-area: footer;
}
```

Each token is an area name. A dot (`.`) marks an empty cell. Rules:

- All rows must have the same number of cells.
- Each named area must be rectangular (contiguous, no L shapes).
- Area names also create implicit named lines: `header-start` / `header-end`
  on both axes.

### Subgrid (Level 2)

A nested grid container with `grid-template-columns: subgrid` (or
`grid-template-rows: subgrid`) does _not_ create new track sizes -- it adopts
the parent grid's tracks across the cells it spans. This is the answer to a
long-standing pain point: in Level 1, a nested grid would establish its own
independent track sizes, breaking column alignment across nested cards.

```css
.cards {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: 1rem;
}

.card {
  display: grid;
  grid-template-rows: subgrid;
  grid-row: span 3; /* a card spans three rows of the outer grid */
  gap: 0.5rem;
}
```

Now the card's three inner rows align with the outer grid's row tracks,
keeping titles, bodies, and footers across cards on the same baselines.

As of 2025, subgrid is Baseline Widely Available (Firefox 71, Safari 16,
Chrome 117). It is the headline feature of Grid Level 2.

### Masonry (Level 3, in progress)

The proposed masonry feature would let one axis of a grid pack items
Pinterest-style (consecutive items flow into the shortest available column),
while the other axis retains regular track behaviour. The current 2025 syntax
proposal is:

```css
.feed {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(220px, 1fr));
  grid-template-rows: masonry;
}
```

Safari ships this experimentally; other browsers had not converged at the
time of writing.

---

## Alignment

Grid is _the_ layout module with the richest alignment support. It honours
both `justify-*` (inline axis) and `align-*` (block axis) at both container
and item levels.

### Item-level Alignment

```css
.item {
  justify-self: stretch | start | center | end | left | right | baseline;
  align-self: stretch | start | center | end | baseline;
}
```

- `justify-self` aligns the item within its grid area along the _inline_ axis.
- `align-self` aligns it along the _block_ axis.

Stretch (the default) makes the item fill its area; non-stretch values let
the item be smaller than its area and choose where in the area to sit.

### Container-level Item Alignment

```css
.grid {
  justify-items: stretch | start | center | end | left | right | baseline;
  align-items: stretch | start | center | end | baseline;
}
```

These set the default alignment for _all_ items in the container; per-item
`justify-self` / `align-self` override them.

### Track Alignment

When the explicit tracks do not consume all of the container's size, free
space is distributed by `justify-content` / `align-content`:

```css
.grid {
  justify-content: start | end | center | stretch | space-between | space-around
    | space-evenly;
  align-content: start | end | center | stretch | space-between | space-around |
    space-evenly;
}
```

Note that `stretch` only stretches tracks whose size is `auto`; `fr` tracks
already consume free space, so on an `fr`-heavy grid there is rarely
free space left for `justify-content` to redistribute.

### Shorthands

```css
.grid {
  place-self: <align-self> <justify-self>;
  place-items: <align-items> <justify-items>;
  place-content: <align-content> <justify-content>;
}
```

### Gaps

The `gap` property and its longhands work in grid containers the same way
they do in flex containers:

```css
.grid {
  display: grid;
  gap: 1rem 0.5rem; /* row-gap column-gap */
}
```

Gaps reduce the space available before track sizing, so a 3-column grid with
`grid-template-columns: repeat(3, 1fr)` and `gap: 16px` divides the
_post-gap_ free space into three equal fractions.

---

## Code Examples

### 1. Holy-Grail Page Layout in One Container

```html
<div class="page">
  <header>Header</header>
  <nav>Navigation</nav>
  <main>Main content</main>
  <aside>Sidebar</aside>
  <footer>Footer</footer>
</div>
```

```css
.page {
  display: grid;
  grid-template-columns: 200px 1fr 220px;
  grid-template-rows: auto 1fr auto;
  grid-template-areas:
    'header  header  header'
    'nav     main    aside'
    'footer  footer  footer';

  min-height: 100vh;
  gap: 1rem;
}

.page > header {
  grid-area: header;
}
.page > nav {
  grid-area: nav;
}
.page > main {
  grid-area: main;
}
.page > aside {
  grid-area: aside;
}
.page > footer {
  grid-area: footer;
}
```

The same layout in pre-Grid CSS required nested wrappers, floats, and
fragile width arithmetic. With Grid it is declarative and trivially
restructured -- swapping `nav` and `aside` in the template flips them on the
page without touching the DOM.

### 2. Responsive Card Grid (no media queries)

```html
<section class="cards">
  <article class="card">...</article>
  <article class="card">...</article>
  <article class="card">...</article>
  <!-- ...arbitrary number of cards... -->
</section>
```

```css
.cards {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(240px, 1fr));
  gap: 1rem;
}
```

On a 1280 px viewport this produces five 240+ px columns; at 800 px it falls
back to three columns; on a phone at 360 px it becomes a single column. No
breakpoints needed.

### 3. Aligned Card Internals via Subgrid

```html
<section class="cards">
  <article class="card">
    <h3>Title</h3>
    <p>Body text.</p>
    <a class="cta" href="#">Read more</a>
  </article>
  <!-- ... -->
</section>
```

```css
.cards {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(240px, 1fr));
  grid-template-rows: repeat(3, auto);
  gap: 1rem;
}

.card {
  display: grid;
  grid-template-rows: subgrid;
  grid-row: span 3; /* each card occupies three outer rows */
  gap: 0.5rem;
  padding: 1rem;
  border: 1px solid #ddd;
}
```

Titles, bodies, and CTAs across all cards now share row baselines without
any per-card sizing.

### 4. Explicit Two-Dimensional Placement with Overlapping

```html
<div class="dashboard">
  <div class="hero">Featured</div>
  <div class="kpi-a">Users</div>
  <div class="kpi-b">Revenue</div>
  <div class="kpi-c">Churn</div>
  <div class="badge">NEW</div>
</div>
```

```css
.dashboard {
  display: grid;
  grid-template-columns: repeat(4, 1fr);
  grid-template-rows: 200px 100px;
  gap: 1rem;
}

.hero {
  grid-column: 1 / 3;
  grid-row: 1 / 3;
}
.kpi-a {
  grid-column: 3;
  grid-row: 1;
}
.kpi-b {
  grid-column: 4;
  grid-row: 1;
}
.kpi-c {
  grid-column: 3 / 5;
  grid-row: 2;
}

.badge {
  grid-column: 1 / 2;
  grid-row: 1;
  justify-self: end;
  align-self: start;
  z-index: 2;
}
```

The `.badge` sits in the same cell as `.hero` and is anchored to the
top-right of the cell via `justify-self: end; align-self: start;`.

### 5. Named Lines for a Magazine-Style Article

```css
article {
  display: grid;
  grid-template-columns:
    [full-start] 1fr
    [wide-start] 2fr
    [content-start] minmax(0, 65ch) [content-end]
    2fr [wide-end]
    1fr [full-end];

  row-gap: 1rem;
}

article > * {
  grid-column: content-start / content-end;
}
article > .wide {
  grid-column: wide-start / wide-end;
}
article > .full-bleed {
  grid-column: full-start / full-end;
}
```

Most paragraphs default to a comfortable 65-character measure; `.wide`
elements break out one step; `.full-bleed` elements (background images,
oversized pull quotes) span the entire viewport. The named-line vocabulary
makes the intent legible to readers of the stylesheet.

---

## Interaction with Other Layout Modes

- **Grid items can themselves be flex containers** (and vice versa). The
  common combination is "Grid for page skeleton, Flexbox for the contents of
  each cell".
- **`position: absolute` grid items** participate in placement (their static
  position is determined by their grid area) but are removed from the
  in-flow layout, so they do not occupy a cell for the purpose of
  auto-placement.
- **Inline children of a grid container** are blockified, mirroring flexbox.
- **Floats and clear** have no effect on grid items.
- **Vertical writing modes** behave logically: `grid-template-rows` always
  refers to the block axis. The named-line convention follows the writing
  mode, so a layout authored for English LTR mostly works in Arabic RTL or
  Japanese vertical-rl, modulo content-specific adjustments.
- **Table layout inside a grid** retains its internal box model but
  participates externally as a single grid item.
- **The grid container has its own intrinsic sizing.** When sized by content,
  it asks each track for its `min-content` / `max-content` contribution, much
  as a flex container does.

---

## Strengths and Weaknesses

### For App Layout

**Strengths.** Grid is the strongest fit for two-dimensional UIs: dashboards,
page templates, settings screens with paired label/control rows that need to
line up across sections. Named areas turn the stylesheet into a readable
diagram; the responsive `repeat(auto-fill, minmax(...))` pattern eliminates
many media queries. Subgrid removes the last major reason to flatten DOM
hierarchies for alignment.

**Weaknesses.** The learning curve is real: track sizing, the auto-placement
algorithm, and intrinsic vs flexible sizing interact in subtle ways that take
practice. The masonry feature is not yet broadly interoperable, so masonry
layouts still require third-party libraries. Performance can suffer when the
implicit grid grows unexpectedly large (a misplaced `grid-row: 9999` is a
classic foot-gun).

### For Typography and Flowing Text

**Strengths.** Named lines give a clean way to express the magazine-style
"normal / wide / full-bleed" measure pattern that has become common in
long-form web design.

**Weaknesses.** Grid does not flow text _across_ tracks. Each grid item is an
independent block; multi-column text flow remains the job of [CSS
Multi-column](https://www.w3.org/TR/css-multicol-1/) (or, at much greater
cost, [CSS Regions](https://www.w3.org/TR/css-regions-1/), which is
effectively dead).

### For Static One-Shot Rendering (e.g., Embedding in a Terminal Renderer)

**Strengths.**

- The track model maps neatly to terminal coordinates: track sizes are
  integers in cell units, gaps are integer cell gutters, and `1fr` divides
  remaining cells via integer arithmetic.
- Named areas would be a fantastic match for TUI layout: `"header header
header" / "sidebar main main" / "footer footer footer"` is exactly how a
  developer would describe a TUI's regions on a whiteboard.
- The explicit/implicit grid distinction lets a small UI scale to many
  generated items (log lines, file lists, search results) without recomputing
  templates.

**Weaknesses.**

- The algorithm is substantially more complex than flexbox's. The
  auto-placement algorithm alone is several pages of normative prose, and a
  conforming implementation must handle `dense` packing, sparse cells, and
  named-area resolution.
- Intrinsic sizing in grid is more involved than in flex: tracks have a
  _base size_ and a _growth limit_ that are resolved in stages, with separate
  passes for `min-content`, `max-content`, and `fr` distribution.
- Subgrid adds another level of difficulty: a subgrid needs to coordinate
  with its parent across track-sizing passes.
- Few non-browser engines implement Grid. Where flexbox engines proliferate
  (Yoga, Stretch, Taffy, multiple TUI libraries), Grid implementations
  outside browsers are essentially limited to Taffy and Servo.

For terminal renderers, Grid Level 1 (without subgrid) is achievable but
costly; Grid Level 2 with subgrid raises the implementation budget
significantly. Most TUI libraries that want grid-like behaviour today either
fake it with nested flex or implement a much-restricted "table-with-spans"
primitive instead.

---

## Non-browser Implementations

Compared to flexbox, the universe of non-browser Grid implementations is
sparse:

- **[Taffy](./taffy.md)** -- A pure-Rust layout engine. Notable for being one
  of the very few non-browser engines with a _practical_ Grid implementation,
  spec-aligned for Grid Level 1 and adding subgrid support as the
  specification has stabilized. Taffy is used by the [Bevy](https://bevyengine.org/)
  game engine's UI system and by various Rust GUI experiments.

- **Servo's `layout_2020`** -- Servo's modern layout engine implements Grid
  Level 1 and Level 2; portions of it have been ported into Firefox via
  Mozilla's Stylo project.

- **[Stretch](./stretch.md)** -- Stretch's flexbox model has been extended in
  some forks with table-like behaviour, but it does not implement CSS Grid.

- **[Yoga](./yoga.md)** -- Yoga is _flexbox only_. There is no Grid mode and
  no announced plan to add one. Meta's UI frameworks (React Native, Litho)
  achieve grid-like layouts via nested flex.

- **[Ink](../tui-libraries/ink.md)** -- Ink relies on Yoga and so inherits
  Yoga's flex-only model. Grid-style layouts in Ink are flex hacks.

- **[Textual](../tui-libraries/textual.md)** -- Textual's CSS subset includes
  a Grid layout mode that closely tracks CSS Grid's vocabulary (rows,
  columns, fr units, named areas), making it a notable exception in the TUI
  space. It is one of the very few terminal frameworks that ships a
  legitimate Grid implementation.

- **Design tools (partial).** Webflow, Framer, and various Figma plugins
  expose subsets of CSS Grid in their layout panels. These are not
  general-purpose engines but are worth noting as evidence that Grid's
  vocabulary has begun to permeate non-browser design workflows.

The general pattern is that _Grid is hard_, _Grid is large_, and the
non-browser ecosystem has converged on "use flexbox or invent a bespoke
table primitive" for most applications.

---

## References

### Specifications

- [CSS Grid Layout Module Level 1](https://www.w3.org/TR/css-grid-1/) (W3C REC, 18 December 2020)
- [CSS Grid Layout Module Level 2](https://www.w3.org/TR/css-grid-2/) (W3C CR Draft, 26 March 2025)
- [CSS Grid Layout Editor's Draft](https://drafts.csswg.org/css-grid/) (CSSWG)
- [CSS Box Alignment Module Level 3](https://www.w3.org/TR/css-align-3/) -- alignment properties shared with Flexbox and Block
- [CSS Sizing Module Level 3](https://www.w3.org/TR/css-sizing-3/) and [Level 4](https://www.w3.org/TR/css-sizing-4/) -- intrinsic sizing keywords, `aspect-ratio`
- [CSS Writing Modes Module Level 4](https://www.w3.org/TR/css-writing-modes-4/) -- logical direction definitions

### MDN

- [CSS grid layout](https://developer.mozilla.org/en-US/docs/Web/CSS/CSS_grid_layout)
- [Basic concepts of grid layout](https://developer.mozilla.org/en-US/docs/Web/CSS/CSS_grid_layout/Basic_concepts_of_grid_layout)
- [Relationship of grid layout with other layout methods](https://developer.mozilla.org/en-US/docs/Web/CSS/CSS_grid_layout/Relationship_of_grid_layout_with_other_layout_methods)
- [Line-based placement with CSS grid](https://developer.mozilla.org/en-US/docs/Web/CSS/CSS_grid_layout/Grid_layout_using_line-based_placement)
- [Grid template areas](https://developer.mozilla.org/en-US/docs/Web/CSS/CSS_grid_layout/Grid_template_areas)
- [Layout using named grid lines](https://developer.mozilla.org/en-US/docs/Web/CSS/CSS_grid_layout/Layout_using_named_grid_lines)
- [Auto-placement in grid layout](https://developer.mozilla.org/en-US/docs/Web/CSS/CSS_grid_layout/Auto-placement_in_grid_layout)
- [Box alignment in grid layout](https://developer.mozilla.org/en-US/docs/Web/CSS/CSS_grid_layout/Box_alignment_in_grid_layout)
- [Grid layout and accessibility](https://developer.mozilla.org/en-US/docs/Web/CSS/CSS_grid_layout/Grid_layout_and_accessibility)
- [Subgrid](https://developer.mozilla.org/en-US/docs/Web/CSS/CSS_grid_layout/Subgrid)
- [Realizing common layouts using grids](https://developer.mozilla.org/en-US/docs/Web/CSS/CSS_grid_layout/Realizing_common_layouts_using_grids)

### Articles, Talks, and Resources

- Rachel Andrew, [Grid by Example](https://gridbyexample.com/) -- canonical
  pattern library for CSS Grid, maintained throughout the spec's
  pre-shipping period.
- Rachel Andrew, _The New CSS Layout_ (A Book Apart, 2017).
- Jen Simmons, [Layout Land](https://www.youtube.com/c/LayoutLand) -- YouTube
  series demystifying grid and intrinsic web design.
- Jen Simmons, talks: _Everything You Know About Web Design Just Changed_
  and _Designing Intrinsic Layouts_.
- Eric Meyer, _Generating `repeat()` `auto-fill` Patterns_ -- explorations on
  Meyer's blog.
- Chris House, [CSS Grid Cheatsheet](https://grid.malven.co/).
- Chris Coyier et al., _A Complete Guide to Grid_, CSS-Tricks (continuously
  updated).
- _CSS Grid Garden_ (game) -- interactive tutorial at cssgridgarden.com.

### Sister Documents in This Catalog

- [CSS Flexbox](./css-flexbox.md) -- one-dimensional sibling specification.
- [Yoga](./yoga.md) -- Meta's flexbox-only engine (no grid).
- [Taffy](./taffy.md) -- Rust engine with practical CSS Grid support.
- [Stretch](./stretch.md) -- earlier Rust port of Yoga, flexbox-only.
- [Ink](../tui-libraries/ink.md) -- Node.js TUI framework using Yoga (no grid).
- [Textual](../tui-libraries/textual.md) -- Python TUI framework whose CSS
  subset includes a grid layout mode.
