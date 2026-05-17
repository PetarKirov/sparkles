# CSS Normal Flow

The original CSS layout model — the substrate on which every later mechanism
(floats, positioning, flex, grid) is layered. Normal flow stacks block boxes
vertically inside a _block formatting context_ and arranges inline boxes
horizontally inside line boxes within an _inline formatting context_, governed
by the box model (content / padding / border / margin) and the margin-collapse
rules. Although surveys of layout systems often jump straight to Flexbox and
Grid, normal flow remains the default value of `display`, the fallback when
nothing else applies, and the only model the CSS engine reaches for when
rendering a paragraph of running text.

| Field           | Value                                                                                                                                                                                                                              |
| --------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Spec            | [CSS 2.2 Visual Formatting Model](https://www.w3.org/TR/CSS22/visuren.html), [CSS Display Module Level 3](https://www.w3.org/TR/css-display-3/), [CSS Box Model Module Level 3](https://www.w3.org/TR/css-box-3/)                  |
| Editors         | Bert Bos, Tantek Çelik, Ian Hickson, Håkon Wium Lie (CSS 2.2); Tab Atkins Jr., Elika J. Etemad (`fantasai`) for css-display-3 and css-box-3                                                                                        |
| Date            | CSS 1: 17 December 1996. CSS 2.1: 7 June 2011 (Recommendation). CSS 2.2: ongoing editorial maintenance. css-display-3: Candidate Recommendation Snapshot 30 March 2023. css-box-3: W3C Recommendation 11 April 2024.               |
| Implementations | Every modern browser engine (Blink/Chromium, Gecko/Firefox, WebKit/Safari, Servo, legacy Trident/EdgeHTML). HTML rendering engines in email clients (Outlook, Apple Mail). Embedded engines (Qt WebEngine, Electron, wkhtmltopdf). |

---

## Overview

### What It Solves

Normal flow is the layout model of _documents_. Its primary job is to render a
flowing stream of mixed block-level and inline content — headings, paragraphs,
lists, anchor links inside running prose — into a two-dimensional surface in a
way that mirrors what typewriters, printing presses, and word processors had
been doing for centuries. The author specifies the _content order_; the model
decides where every glyph lands.

The mechanism is decomposed into two complementary primitives:

- A **block formatting context (BFC)** in which boxes stack one after the other,
  vertically, each occupying the full width of the containing block (unless
  otherwise constrained). This is the model for "the body is a sequence of
  paragraphs."

- An **inline formatting context (IFC)** in which boxes flow horizontally, one
  after the other, breaking onto a new _line box_ whenever the current line is
  exhausted. This is the model for "a paragraph is a sequence of words and
  styled spans."

The box model unifies geometry across both contexts: every generated box has a
_content_ area surrounded by a _padding_ area, then a _border_ area, then a
_margin_ area, with the box-edge keywords (`content-box`, `padding-box`,
`border-box`, `margin-box`) used by other specs to refer to specific edges.

### Design Philosophy

The visual formatting model in [CSS 2.2 §9](https://www.w3.org/TR/CSS22/visuren.html)
encodes several deliberate choices that have aged surprisingly well:

- **Content order is layout order, by default.** No "constraint solver", no
  declarative ordering. The DOM tree (or any tree of _generated boxes_, after
  `display`, `::before`, `::after`, and CSS-generated content are accounted for)
  _is_ the layout, walked in document order.

- **Boxes know nothing about their siblings or descendants.** The block
  formatting context lays out children top-to-bottom without any "look-ahead"
  beyond the requirement that adjacent vertical margins collapse. This is what
  allows incremental, streaming, line-by-line rendering on a slow modem in 1996.

- **Inline content is text-first.** Line boxes are formed by the IFC algorithm
  to hold one line's worth of inline content; their height is the maximum of
  the contributing inline boxes' line heights. The model is literally a
  typesetter's notion of "set this line, then move down to the next baseline."

- **Geometry is local.** A box's position is computed from its containing
  block's edges. The containing block is, in most cases, the nearest
  block-level ancestor's content edge — a recursive, local computation that
  requires no global solver.

- **Layout falls back to the model.** Even when later mechanisms (floats,
  absolute positioning, flex, grid) take over, every page still has a root
  block formatting context, every paragraph still has an inline formatting
  context, and any box that escapes those contexts re-enters them at its
  position in the box tree.

### History

- **1990–1993: CSS prehistory.** Håkon Wium Lie proposes "Cascading HTML Style
  Sheets" while at CERN. Tim Berners-Lee's WorldWideWeb browser and the early
  Mosaic browser render HTML using ad-hoc layout rules that already resemble
  normal flow: blocks stack, inlines flow.

- **17 December 1996: CSS Level 1 Recommendation.** [CSS 1](https://www.w3.org/TR/CSS1/)
  codifies the box model (content, padding, border, margin), the `display`
  property (with values `block`, `inline`, `list-item`, `none`), and the basics
  of float-and-clear. It does not yet have a formal "formatting context"
  vocabulary — the model is described prosaically.

- **12 May 1998: CSS Level 2 Recommendation.** [CSS 2](https://www.w3.org/TR/REC-CSS2/)
  introduces the _visual formatting model_ as a named, structured concept,
  formalizing block and inline formatting contexts, the positioning schemes
  (`static`/`relative`/`absolute`/`fixed`), and `display: inline-block` and the
  `table-*` display values.

- **2002–2011: CSS 2.1 revisions.** The Working Group spends nearly a decade
  refining ambiguities in the original spec. [CSS 2.1](https://www.w3.org/TR/CSS21/)
  becomes a Recommendation on 7 June 2011, with substantially tightened
  formatting-context and margin-collapse rules.

- **CSS 2.2 (ongoing).** [CSS 2.2](https://www.w3.org/TR/CSS22/) is an
  editorial update of CSS 2.1; it preserves the same model with editorial
  clarifications and references to newer modules.

- **2012: CSS Flexbox** becomes a Candidate Recommendation. Flex is _not_ a
  replacement for normal flow — it is a _new inner display type_ selected by
  `display: flex`. Inside a flex container, flow rules are suspended; outside,
  the parent still lays the container out in normal flow.

- **2017: CSS Grid** ships in major browsers. Same story: `display: grid` opts
  the children in to a grid formatting context, but the grid container itself
  is positioned by whatever context its parent establishes (normal flow by
  default).

- **2018–2023: CSS Display Module Level 3.** [css-display-3](https://www.w3.org/TR/css-display-3/)
  factors the `display` property into two independent axes (_outer_ and
  _inner_), introduces `display: contents` (which makes an element disappear
  from the box tree while its children remain), and clarifies the
  blockification / inlinification rules used by abspos, flex, and grid.

- **2024: CSS Box Model Module Level 3.** [css-box-3](https://www.w3.org/TR/css-box-3/)
  becomes a W3C Recommendation, replacing the margin and padding definitions
  from CSS 2.1 with a cleaner specification, defining the box-edge keywords
  (`content-box`, `padding-box`, `border-box`, `margin-box`) used by other
  modules.

Throughout this evolution, the _default_ `display` value remains
flow-based — meaning that for a vast amount of real-world web content
(documentation sites, blog posts, news articles, MDN, Wikipedia, this very
page), normal flow does the bulk of the layout work. Flex and grid only
participate where opted in.

---

## Layout Model

### The Box Model

Every element in normal flow generates a _box_ with four concentric rectangular
areas:

```
+------- margin area -----------------------+
|                                           |
|  +---- border area --------------------+  |
|  |                                     |  |
|  |  +-- padding area --------------+   |  |
|  |  |                              |   |  |
|  |  |  +--- content area -------+  |   |  |
|  |  |  |                        |  |   |  |
|  |  |  |   (text, children)     |  |   |  |
|  |  |  |                        |  |   |  |
|  |  |  +------------------------+  |   |  |
|  |  |                              |   |  |
|  |  +------------------------------+   |  |
|  |                                     |  |
|  +-------------------------------------+  |
|                                           |
+-------------------------------------------+
```

Edges, from inside out, are: **content edge**, **padding edge**, **border
edge**, **margin edge**. Background colors and images are painted through the
border edge by default. The visual outline is the border edge.

Each side is controlled by individual longhand properties — `padding-top`,
`padding-right`, `padding-bottom`, `padding-left`, and analogous `margin-*` and
`border-*-width` properties — or by 1-to-4-value shorthand (`padding`,
`margin`, `border-width`).

```css
/* Two equivalent ways to give a card 16px padding top/bottom, 24px left/right */
.card {
  padding-top: 16px;
  padding-right: 24px;
  padding-bottom: 16px;
  padding-left: 24px;
}
.card {
  padding: 16px 24px;
} /* shorthand */
```

### `box-sizing`

A long-standing source of confusion: by default (`box-sizing: content-box`),
the `width` and `height` properties size the _content area only_. Padding and
border are added on top:

```css
.a {
  box-sizing: content-box;
  width: 200px;
  padding: 20px;
  border: 2px solid;
}
/* Total border-box width = 200 + 2*20 + 2*2 = 244px */
```

This is the original CSS 1 / CSS 2 behavior and matches the prose specification
of "width is the content width."

`box-sizing: border-box` (added in [CSS Backgrounds and Borders Level 3](https://www.w3.org/TR/css-backgrounds-3/))
inverts the relationship: `width` and `height` describe the border-box, and the
content area shrinks to accommodate padding and border:

```css
.b {
  box-sizing: border-box;
  width: 200px;
  padding: 20px;
  border: 2px solid;
}
/* Total border-box width = 200px; content area = 200 - 2*20 - 2*2 = 156px */
```

The `border-box` model matches Microsoft's pre-standards Internet Explorer
behavior and is widely considered the more intuitive default for app UI; many
codebases ship a universal reset:

```css
*,
*::before,
*::after {
  box-sizing: border-box;
}
```

### `display` and Formatting-Context Selection

The `display` property is the keystone of normal flow. Its value determines
both the _outer_ role of a box (how it participates in its parent's flow) and
the _inner_ model (how it lays out its own children).

[CSS Display Module Level 3](https://www.w3.org/TR/css-display-3/) introduces a
two-value syntax that makes the two axes explicit:

```css
display: block flow; /* the classic <p>, <div> default */
display: inline flow; /* the classic <span>, <em> default */
display: inline flow-root; /* equivalent to legacy `inline-block` */
display: block flex; /* a block-level flex container */
display: inline grid; /* an inline-level grid container */
```

The single-value keywords most authors still type today (`block`, `inline`,
`inline-block`, `flex`, `grid`, etc.) all map to canonical two-value pairs.

Legacy single values that still matter to normal flow:

- **`block`** — generates a block-level box. Children form a block formatting
  context (unless the block becomes a flex/grid container, etc.).
- **`inline`** — generates one or more inline-level boxes that flow inside an
  inline formatting context.
- **`inline-block`** — an _inline-level_ box on the outside (participates in
  line boxes) whose interior is an _independent_ block formatting context. The
  box is sized like a block but flows like an inline.
- **`list-item`** — generates a principal block-level box and a marker box
  (the bullet or number). Special-cased so that `<li>` retains its bullet
  regardless of what other display roles are layered on.
- **`run-in`** — a historically tricky value that merges a leading "lead-in"
  box into the following block. Marked at-risk in css-display-3; most engines
  do not implement it.
- **`none`** — generates _no box at all_; the element and all its descendants
  vanish from the box tree. Distinct from `visibility: hidden`, which still
  reserves space.
- **`contents`** — new in css-display-3. The element itself disappears, but
  its children are "promoted" to the parent's box tree as if the element were
  unwrapped. Replaced elements, form controls, and SVG/MathML elements compute
  `display: contents` to `display: none` instead. Useful for un-nesting a
  wrapper without removing it from the DOM.
- **`table`, `table-row`, `table-cell`, `table-row-group`, ...** — generates
  CSS table boxes. Their inner model is the table formatting context, which is
  not strictly normal flow but is part of the legacy display set.

### Block Formatting Context (BFC)

Inside a block formatting context, boxes are laid out one after another,
**vertically**, starting at the top of the containing block. The horizontal
position of each box is determined by the containing block's left content edge
(in left-to-right writing modes) — no horizontal stacking of siblings unless
floats intervene.

Key properties of a BFC:

- A block-level box's _width_ defaults to filling its containing block's
  content width. Set `width` to constrain it; use `margin: auto` (with an
  explicit width) to center it.
- A block-level box's _height_ defaults to "auto", meaning _fit-content_ — the
  smallest height that contains all in-flow children plus any cleared floats.
- Vertical margins between adjacent siblings _collapse_ (see below).
- Floats contained in a BFC participate in the layout of subsequent in-flow
  content unless cleared.

A BFC is _established_ by:

- The root element (the `<html>` element's principal box always establishes
  one).
- Floats (`float: left | right`).
- Absolutely positioned elements (`position: absolute | fixed`).
- Block containers that are inline-blocks, table-cells, table-captions, or
  flex/grid items (each item establishes an independent formatting context).
- Block boxes with `overflow` not equal to `visible` (a common trick for
  forcing a new BFC, e.g. `overflow: hidden` or `overflow: auto`).
- Block boxes with `display: flow-root` (the explicit, side-effect-free way to
  create a new BFC, added in css-display-3).

Establishing a new BFC has important side effects: floats inside it are
contained (no leakage to following siblings) and margins of children no longer
collapse with margins outside the new BFC.

### Inline Formatting Context (IFC)

Within an IFC, boxes are laid out _horizontally_, one after another, starting
at the top of the containing block. The horizontal direction is determined by
the writing mode (left-to-right for English, right-to-left for Arabic /
Hebrew). The vertical direction is determined by `writing-mode` (top-to-bottom
for most scripts).

The IFC algorithm groups consecutive inline-level content into **line boxes**.
A line box is a horizontal slice of the IFC, exactly tall enough to contain
the tallest inline content it holds (subject to `line-height`,
`vertical-align`, and the strut). When the inline content on a line exceeds
the containing block's width, the layout _breaks_ — typically at a permissible
break point such as a whitespace character — and the next inline box starts a
new line box below the previous one.

```html
<p>This is a <em>paragraph</em> with <strong>mixed</strong> styled spans.</p>
```

renders by:

1. Establishing a BFC for the document body containing the `<p>` element.
2. The `<p>` itself is a block box in that BFC, with its own (inner) IFC.
3. The inner IFC walks the inline children:
   - Anonymous inline box `"This is a "` (text run)
   - `<em>` inline box, containing inline text `"paragraph"`
   - Anonymous inline box `" with "` (text run)
   - `<strong>` inline box, containing inline text `"mixed"`
   - Anonymous inline box `" styled spans."` (text run)
4. Line boxes are formed at every break point; their heights are the max of
   the contained inline boxes' line heights.

If a block-level element appears inside an IFC, **anonymous block boxes** are
generated around the surrounding inline content to "block-ify" the local
layout — preserving the invariant that a BFC contains only block-level boxes
and that inline content always lives inside an IFC.

### Margin Collapsing

The single most surprising aspect of normal flow. _Adjacent vertical margins
collapse_ into a single margin equal to the maximum (for positive margins) or
minimum (for negative margins, by absolute value), or their sum (for mixed
signs). The rules apply in three configurations:

**1. Adjacent siblings.** The bottom margin of one block-level box and the top
margin of the next collapse:

```html
<style>
  p {
    margin: 16px 0;
  }
</style>
<p>First.</p>
<p>Second.</p>
```

The space between the two `<p>` elements is `16px`, not `32px`.

**2. Parent and first/last child.** If a parent has no `border`, no `padding`,
no inline content separating it from its first child, the first child's top
margin collapses _through_ the parent and out the top:

```html
<style>
  .outer {
    margin-top: 20px;
  }
  .inner {
    margin-top: 30px;
  }
</style>
<div class="outer"><div class="inner">Hello</div></div>
```

The visible top margin above `.inner` is `30px` from the outer container, not
`50px`. This is the source of countless "why is my margin escaping the parent"
bug reports. The fix is to establish a new BFC on `.outer` (e.g.
`overflow: hidden`, `display: flow-root`) or to add padding/border to block the
collapse.

**3. Empty blocks.** A block with no content, no padding, no border, and no
inline content has its top and bottom margins collapse with each other and with
adjacent siblings.

Margins **never collapse** for:

- Horizontal margins (only vertical, in horizontal writing modes — the
  collapse direction follows the _block axis_).
- Floats.
- Absolutely positioned elements.
- Inline-block elements.
- Elements with `overflow` other than `visible`.
- Flex / grid items.
- Anything that establishes a new block formatting context.

### Floats

`float: left` or `float: right` removes a box from normal flow, shifts it to
the left or right edge of the containing block, and lets subsequent inline
content flow _around_ it. Originally introduced for the "image with text
wrapping" pattern of magazine layout; widely repurposed (1998 – 2012) as a
poor-man's column-layout mechanism.

Float behavior in summary:

- A float is taken out of the normal block flow, but inline content (line
  boxes) shortens to make room for it.
- Subsequent block-level siblings still flow as if the float were not present
  (their boxes overlap the float's region), but their _line boxes_ shorten to
  avoid the float.
- The `clear` property (`left`, `right`, `both`) on a subsequent element
  forces its top margin to push past any floats on the specified side.
- Floats establish a new block formatting context for their own children.

```html
<style>
  .figure {
    float: left;
    width: 200px;
    margin: 0 16px 16px 0;
  }
  .caption {
    clear: left;
  }
</style>
<article>
  <img class="figure" src="..." alt="..." />
  <p>Lorem ipsum dolor sit amet, ... text wraps around the image.</p>
  <p class="caption">This caption appears below the image.</p>
</article>
```

A long-standing wart: a parent whose only in-flow content is floated has
`height: 0`, because the floats are not "in flow." This is the _collapsing
parent_ problem, traditionally solved with the **clearfix hack**:

```css
.clearfix::after {
  content: '';
  display: block;
  clear: both;
}
```

The modern equivalent is `display: flow-root` on the parent, which establishes
a new BFC and contains the floats cleanly.

### Positioning

The `position` property selects one of five **positioning schemes**, layered
on top of normal flow:

- **`static`** _(default)_ — the box is laid out in normal flow. `top`,
  `right`, `bottom`, `left`, and `z-index` have no effect.

- **`relative`** — the box is laid out in normal flow, _then_ visually offset
  by `top` / `right` / `bottom` / `left`. The box's _layout position_ is
  unchanged; surrounding boxes are unaffected. The offset is purely visual.
  Also establishes a containing block for absolutely positioned descendants.

- **`absolute`** — the box is removed from normal flow entirely and positioned
  relative to its **containing block**, which is the nearest ancestor with a
  `position` other than `static` (or, lacking such ancestor, the initial
  containing block, which is the viewport in continuous media). `top`,
  `right`, `bottom`, `left` describe offsets from the corresponding edges of
  the containing block.

- **`fixed`** — like `absolute`, but the containing block is always the
  viewport (or the page area in paginated media). Stays anchored as the page
  scrolls.

- **`sticky`** — a hybrid added in [CSS Positioned Layout Module Level 3](https://www.w3.org/TR/css-position-3/).
  The box is laid out in normal flow until its scroll-port edge would cross
  one of the specified offset thresholds, at which point it acts like a
  position-fixed element relative to its nearest scrollable ancestor.

The containing block rules are subtle:

| For a position with... | the containing block is...                                                    |
| ---------------------- | ----------------------------------------------------------------------------- |
| `static`, `relative`   | the nearest block-level ancestor's _content edge_                             |
| `absolute`             | the nearest ancestor with `position != static`, taken to its _padding edge_   |
| `fixed`                | the viewport (initial containing block)                                       |
| `sticky`               | same as `static`/`relative` for layout; nearest scroll container for sticking |

This recursion is the secret machinery of complex normal-flow-derived layouts:
a `position: relative` wrapper "captures" absolutely positioned descendants,
letting authors build popovers, tooltips, and overlays without leaving the
flow.

### Putting It Together: Annotated Walk-Through

Consider a simple page with a header, a paragraph containing a floated figure,
and a footer:

```html
<style>
  body {
    margin: 0;
  }
  header {
    background: #eef;
    padding: 16px;
  }
  main {
    padding: 16px;
  }
  .fig {
    float: right;
    width: 160px;
    margin: 0 0 12px 16px;
  }
  footer {
    background: #efe;
    padding: 16px;
  }
</style>
<header><h1>Title</h1></header>
<main>
  <img class="fig" src="..." alt="..." />
  <p>Lorem ipsum dolor sit amet ...</p>
</main>
<footer>Footer text.</footer>
```

Layout walk:

1. The root `<html>` element establishes the initial containing block, sized
   to the viewport, and the root BFC.
2. `<body>` is a block-level child of the BFC; its width is the viewport
   width, height is auto (computed from children).
3. `<header>`, `<main>`, `<footer>` stack vertically inside body's BFC. Each
   has its own internal layout.
4. Inside `<header>`, the `<h1>` establishes its own inline formatting
   context for "Title", laying down one line box.
5. Inside `<main>`:
   - The `<img class="fig">` is _floated right_. It is removed from normal
     flow, snapped to the right padding edge of `<main>`.
   - The `<p>` is a block-level box in `<main>`'s BFC. Its width is the full
     content width of `<main>`. Its IFC lays down line boxes for the
     paragraph text — but each line box _shortens_ to avoid the floated
     image's region, producing the classic wrap-around-image effect.
6. `<footer>` follows below `<main>`, vertically; its top margin would
   collapse with `<main>`'s bottom margin if both were nonzero.

No constraint solver runs. No second pass. The browser walks the tree once,
asking each box "what is your size?" and "where are you in your formatting
context?" and writes pixels.

---

## Strengths and Weaknesses

### For Document Layout (target domain)

**Strengths.** Normal flow is _exceptionally_ good at what it was designed
for: rendering long-form documents with mixed inline styling, where the author
specifies content order and the rendering engine handles line breaking,
hyphenation, justification, and the placement of figures alongside text. A
six-thousand-word article, a research paper, a long technical manual — these
are essentially direct expressions of normal flow's model. There are no
declared widths, no grid templates, no flex containers; the model adapts to
the viewport by reflowing line boxes.

The model also has remarkable algorithmic properties:

- **Single-pass.** A naive implementation can walk the box tree in one
  traversal, emitting pixels as it goes. Incremental rendering works "for
  free" — old dial-up browsers could display a partial page as bytes streamed
  in.
- **Composable.** Nested elements compose by establishing their own
  formatting contexts. Most authoring is a matter of "what do I want this
  container to be? block or inline?" with the model handling the rest.
- **Author-friendly.** The HTML defaults map naturally to normal flow: a
  `<p>` is a block, an `<em>` is inline. Authors who write semantic HTML
  often produce reasonable layouts with zero CSS.

### For Static One-Shot Rendering

Normal flow is well-suited to _batch_ rendering pipelines that generate static
output: PDF generation (via wkhtmltopdf, headless Chromium, Puppeteer),
email-template rendering, server-side React/Vue/Astro that emits HTML+CSS,
print stylesheets, ePub generation. The model's locality and single-pass
nature make it cheap to compute for a known viewport size, and the absence of
runtime interactivity is fine — the page renders once.

For sparkles-style **static, one-shot CLI output** (write a styled report to
stdout, exit), the _philosophy_ of normal flow carries over:

- A printed terminal "page" is fundamentally block-based: a sequence of lines.
- Inline styling within a line — colored spans, bold runs — is a perfect fit
  for IFC-style line boxes containing styled inline boxes.
- A "report" is a tree of blocks: section headers, paragraphs, tables, code
  blocks. Each is a block formatting context; their internal text is an
  inline formatting context.

The box-model concept (padding around content, margin between blocks) also
maps cleanly onto terminal-cell space, though border characters and margin
collapsing have to be re-implemented for the medium. Sparkles' `prettyPrint`
already inhabits this design space.

**Weaknesses for one-shot static output.**

- The model is _width-aware_ but not naturally _aligned-into-columns_. Lining
  two columns up by their first character requires inline-block / table /
  flex tricks.
- Vertical centering inside a block is famously awkward in normal flow.
- "Take the remaining space" is not expressible — block boxes are
  fit-content-tall by default; the parent can be `height: 100%`, but
  filling the parent requires positioning or flex.

### For App UIs

This is where normal flow shows its age. Application interfaces — toolbars,
side panels, tab strips, modal dialogs, resizable splitters, virtualized
lists — are _not_ sequences of paragraphs. They are 2-D arrangements of
panels with specific size relationships and alignment requirements. The
historical pain points include:

- **Two-column layouts.** Before flex / grid, the classic three-column
  "holy grail" layout required either floats with negative margins, or
  `display: table`, or absolutely-positioned columns. All three had failure
  modes (sticky footers, equal-height columns, source-order independence)
  that normal flow could not address natively.
- **Vertical centering.** "Center this box vertically in the viewport"
  required `position: absolute; top: 50%; transform: translateY(-50%)` or
  `display: table-cell; vertical-align: middle` — both feel like fighting the
  model.
- **Equal-height columns.** Block boxes are individually fit-content; making
  two sibling block boxes match each other's height for visual alignment
  required the _faux columns_ hack (background images) or, again, table
  display.
- **"Fill remaining height" sidebars.** Until flex/grid, this was unachievable
  in normal flow without absolute positioning and explicit math.
- **Source order vs. visual order.** Floats and absolute positioning gave
  some flexibility, but reordering blocks visually without changing the DOM
  required hacks.

It was precisely these app-UI pain points that drove the design of Flexbox
([css-flexbox.md](./css-flexbox.md)) and later CSS Grid
([css-grid.md](./css-grid.md)). Both are _inner display types_ that suspend
normal flow inside the container while remaining compatible with normal flow
outside it.

### Compared to Alternatives

| Aspect                           | Normal flow                                   | Flexbox                        | Grid                      | Constraint-based (e.g. Auto Layout, Cassowary) |
| -------------------------------- | --------------------------------------------- | ------------------------------ | ------------------------- | ---------------------------------------------- |
| Primary axis                     | Block (vertical for horizontal writing modes) | One-dimensional (configurable) | Two-dimensional           | Arbitrary linear constraints                   |
| Spec age                         | 1996 (CSS 1)                                  | 2012 (CR)                      | 2017 (Rec)                | Cassowary 1997, Auto Layout 2011               |
| Suited for                       | Documents, prose                              | App UI rows/columns            | 2-D app UI grids          | Complex IDE-like layouts                       |
| Reflow on resize                 | Excellent (single-pass)                       | Excellent                      | Excellent                 | Good (but solver cost)                         |
| "Fill remaining space"           | No (use `height: 100%` games)                 | `flex: 1`                      | `1fr`                     | Yes, with inequality constraints               |
| Vertical centering               | Hard                                          | `align-items: center`          | `align-items: center`     | Trivial                                        |
| Order-independent of source      | No                                            | `order` property               | Grid placement properties | Trivial                                        |
| Browsers / runtimes implementing | Universal                                     | Universal                      | Universal (since 2017)    | Native iOS/macOS, web via solvers like kasuari |

The most important point: **normal flow is not "obsolete."** Inside a flex
item or a grid cell, the _contents_ are laid out by whatever inner display
type the item itself selects — and by default, that is normal flow. A typical
modern web page uses a top-level grid or flex layout for the page chrome and
_normal flow_ for the actual content of each panel.

### When Normal Flow Wins

- **Rendering arbitrary HTML.** If you do not control the markup (RSS feed,
  Markdown-rendered docs, user-submitted comments), normal flow is what makes
  it look reasonable without ad-hoc styling.
- **Print and PDF.** Pagination and line-breaking are first-class concerns of
  the visual formatting model; flex and grid have weaker print stories.
- **Vertical streaming output.** Logs, REPLs, terminal output, transcript-style
  UIs — fundamentally "append a block at the bottom" interactions are direct
  expressions of a BFC.
- **Localizable content.** Reflow handles language-specific line-breaking,
  hyphenation, and writing-mode changes without author intervention.

### When Normal Flow Loses

- **Pixel-perfect 2-D layouts** with sibling alignment in both axes — use
  grid.
- **Variable-content rows** that need consistent vertical alignment of items
  with mixed sizes — use flexbox.
- **Dynamic resizing with min/max relationships** between siblings — use
  flexbox or constraint-based.
- **Source-order independent visual order** — use flex/grid's `order` /
  placement properties.

---

## References

### Primary Specifications

- **CSS 2.2 Visual Formatting Model.** <https://www.w3.org/TR/CSS22/visuren.html>
- **CSS 2.2 Box Model.** <https://www.w3.org/TR/CSS22/box.html>
- **CSS Display Module Level 3.** <https://www.w3.org/TR/css-display-3/>
- **CSS Box Model Module Level 3.** <https://www.w3.org/TR/css-box-3/>
- **CSS Positioned Layout Module Level 3.** <https://www.w3.org/TR/css-position-3/>
- **CSS Backgrounds and Borders Module Level 3.** <https://www.w3.org/TR/css-backgrounds-3/> (defines `box-sizing`).

### Earlier Versions

- **CSS Level 1 (W3C Recommendation, 17 December 1996).** <https://www.w3.org/TR/CSS1/>
- **CSS Level 2 (W3C Recommendation, 12 May 1998).** <https://www.w3.org/TR/REC-CSS2/>
- **CSS Level 2.1 (W3C Recommendation, 7 June 2011).** <https://www.w3.org/TR/CSS21/>

### Tutorials and Reference Material

- **MDN — Block formatting context.** <https://developer.mozilla.org/en-US/docs/Web/CSS/CSS_display/Block_formatting_context>
- **MDN — Inline formatting context.** <https://developer.mozilla.org/en-US/docs/Web/CSS/CSS_display/Inline_formatting_context>
- **MDN — Normal Flow.** <https://developer.mozilla.org/en-US/docs/Learn/CSS/CSS_layout/Normal_Flow>
- **MDN — Mastering margin collapsing.** <https://developer.mozilla.org/en-US/docs/Web/CSS/CSS_box_model/Mastering_margin_collapsing>
- **MDN — Floats.** <https://developer.mozilla.org/en-US/docs/Web/CSS/CSS_floating_floats>
- **MDN — Positioning.** <https://developer.mozilla.org/en-US/docs/Web/CSS/CSS_positioned_layout>
- **MDN — Containing block.** <https://developer.mozilla.org/en-US/docs/Web/CSS/CSS_display/Containing_block>

### Historical Context

- **Håkon Wium Lie, "Cascading HTML style sheets — a proposal" (1994).** <https://www.w3.org/People/howcome/p/cascade.html>
- **Bert Bos, "A brief history of CSS until 2016."** <https://www.w3.org/Style/CSS20/history.html>
- **Chris Coyier, "The Difficulties of Vertical Centering" (CSS-Tricks, 2013–2020).** <https://css-tricks.com/centering-css-complete-guide/>
- **PPK (Peter-Paul Koch), "CSS layout: an introduction" — quirksmode.org.** <https://www.quirksmode.org/css/>

### Adjacent Sparkles Research

- **Flexbox layout model (sibling doc):** [css-flexbox.md](./css-flexbox.md)
- **Grid layout model (sibling doc):** [css-grid.md](./css-grid.md)
- **TUI library that uses Yoga (a Flex implementation) on top of a normal-flow-shaped output stream:** [../tui-libraries/ink.md](../tui-libraries/ink.md)
- **TUI library with a constraint-based layout that does _not_ use normal flow:** [../tui-libraries/ratatui.md](../tui-libraries/ratatui.md)
- **Tk geometry managers (the proto-flex / proto-grid / proto-abspos of the GUI world, predating CSS):** [tk.md](./tk.md)
