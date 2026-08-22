# elm-ui — a layout language with no measurement seam at all

**Category:** purity as a forcing function on measurement.
**Last reviewed:** August 23, 2026. Pinned at [`acae8857`][rev].

The control experiment for this survey. `elm-ui` is a complete layout and
styling language whose host language cannot measure text — Elm has no FFI, no
synchronous JavaScript interop, and no metrics service — and which shipped a
production toolkit anyway. It is therefore the strongest available test of the
question underneath [friction §1][friction]: how much of layout genuinely needs
`measure`, as opposed to needing somewhere to _put_ `measure`.

| Field                | Value                                                                                    |
| -------------------- | ---------------------------------------------------------------------------------------- |
| **Language**         | Elm 0.19 (`0.19.0 <= v < 0.20.0`, per [`elm.json`][elmjson])                             |
| **License**          | BSD-3-Clause ([`elm.json`][elmjson])                                                     |
| **Repository**       | [`mdgriffith/elm-ui`][rev]                                                               |
| **Documentation**    | [`Element` module docs][pkgdocs] (package version `1.1.8`)                               |
| **Category**         | purity as a forcing function on measurement                                              |
| **Pinned revision**  | `acae8857a02e600cc4b4737ca2f70607228b4489`                                               |
| **Backends shipped** | exactly one — the browser, via `elm/virtual-dom` ([`elm.json`][elmjson] dependency list) |
| **Renderer seam**    | none: the output is DOM nodes plus a generated stylesheet                                |

> [!NOTE]
> The umbrella deliberately excludes "React/DOM-style retained trees where the
> backend is a browser". `elm-ui` is on the list for the opposite reason from
> the others: not for what its seam does, but for what its _absence_ proves
> about which layout decisions require measurement.

## Overview

### What it solves

`elm-ui` replaces CSS and HTML with a typed layout vocabulary — `Element`,
`row`, `column`, `el`, `paragraph`, and a `Length` type of `px` / `shrink` /
`fill` / `fillPortion` ([`src/Element.elm`][elementsrc]). Its stated goal is not
to abstract a renderer but to make a class of layout bugs unwritable:

> The high level goal of this library is to be a **design toolkit** that draws
> inspiration from the domains of design, layout, and typography, as opposed to
> drawing from the ideas as implemented in CSS and HTML.
>
> This means: […] Many layout errors (like you'd run into using CSS) **are just
> not possible to write** in the first place!
>
> — [`README.md`][readme]

### Design philosophy

The rewrite note from its predecessor states the invariant that makes the
no-measurement design tolerable:

> The key insight is that it's not so much the separation of layout and style
> that is important as it is that _properties affecting layout should all be in
> the view function_. […] **Everything should be explicit and in your view!**
>
> — [`notes/CHANGES-FROM-STYLE-ELEMENTS.md`][changes]

Everything that decides layout is a value the author wrote. Nothing that
decides layout is a number the toolkit obtained by asking a font. That is a
philosophical commitment in the source and a hard constraint of the language
simultaneously, and the two are indistinguishable from inside.

## How it works

There is no drawing seam to quote, because there is no drawing. `Element` is a
function to a `VirtualDom.Node`, and the "backend" is CSS:

```elm
type Element msg
    = Unstyled (LayoutContext -> VirtualDom.Node msg)
    | Styled
        { styles : List Style
        , html : EmbedStyle -> LayoutContext -> VirtualDom.Node msg
        }
    | Text String
    | Empty
```

— [`src/Internal/Model.elm` L120–L126][model-element]

Sizing is a five-constructor sum type, and every constructor lowers to a CSS
class rather than to a number:

```elm
type Length
    = Px Int
    | Content
    | Fill Int
    | Min Int Length
    | Max Int Length
```

— [`src/Internal/Model.elm` L341–L346][model-length]

`renderWidth` ([L1353][model-renderwidth]) is the whole of width resolution:
`Px n` emits `width: npx`; `Content` emits the class `wc`, whose rule is
`width: auto` ([`src/Internal/Style.elm` L1223][style-widthcontent]); `Fill n`
emits the class `wf`, whose rules give a child `width: 100%` and, for
`heightFill`, `flex-grow: 100000` ([`src/Internal/Style.elm`
L888–L894][style-fill]), plus, inside a row, `flex-grow: n * 100000` for a
`fillPortion`; `Min`/`Max` emit
`min-width` / `max-width` and recurse. Spacing is likewise a stylesheet rule —
`margin-left` on `any + any` inside a row, `margin-top` in a column, and, for a
`paragraph`, `line-height: calc(1em + Npx)`
([`src/Internal/Model.elm` L2743][model-spacing]).

The consequence is precise and worth stating plainly: **`elm-ui` computes no
extents.** It emits a constraint system — flexbox — and the browser solves it.
The toolkit never learns the answer, and neither does the program.

### Text

`Element.text` is `Internal.Text content` ([L549][element-text]), rendered as a
`div` carrying the classes `t wc hc`
([`textElement`, L2058][model-textelement]) whose rule is `white-space: pre;
display: inline-block` ([`src/Internal/Style.elm` L866][style-pre]). Its own
doc comment records the restriction:

> **Note** text does not wrap by default. In order to get text to wrap, check
> out `paragraph`!
>
> — [`src/Element.elm` L545][element-text-doc]

`paragraph` ([L1047][element-paragraph]) switches the subtree to `display:
block; white-space: normal; overflow-wrap: break-word`
([`src/Internal/Style.elm` L1626][style-paragraph]) — i.e. it hands wrapping
entirely to the browser's line breaker. The source is candid about the limit of
that arrangement:

```css
/* Inline block allows the width of the item to be set
   but DOES NOT like wrapping text in a standard, normal, sane way.
   We're sorta counting that if an exact width has been set,
   people aren't expecting proper text wrapping for this element */
```

— [`src/Internal/Style.elm` L1653–L1656][style-inlineblock]

### The one metrics channel: hand-measured font data

`elm-ui` does have vertical font metrics — supplied as _data by the author_,
never obtained by the toolkit:

```elm
type alias Adjustment =
    { capital : Float
    , lowercase : Float
    , baseline : Float
    , descender : Float
    }
```

— [`src/Element/Font.elm` L141–L146][font-adjustment]

`Font.with { name, adjustment, variants }` attaches those four fractions to a
typeface; `convertAdjustment` ([`src/Internal/Model.elm`
L3484][model-convertadjustment]) turns them into `line-height`,
`vertical-align` and `font-size` in `em`
([`fontAdjustmentRules`, L2518][model-adjustrules]), which is what makes
`Font.sizeByCapital` ([`src/Element/Font.elm` L161][font-sizebycapital]) able
to size text from cap-height to baseline.

Where do the four numbers come from? From a human dragging sliders over a
rendered specimen: [`experiments/font-adjustment/FontAdjustment.elm`][fontadj]
is an `elm-ui` application whose `Input.slider` ([L293][fontadj-slider])
positions dashed guide lines over sample text until they touch the ascender,
x-height, baseline and descender, and prints the fractions. Measurement is
real, necessary, and pushed entirely **out of the toolkit and out of the
program**, into a design-time tool and a literal in source.

### The escape hatch that proves the rule

Runtime measurement exists in Elm, and its shape is the point.
`Browser.Dom.getElement` returns a `Task`:

```elm
getElement : String -> Task Error Element
```

— [`elm/browser`, `src/Browser/Dom.elm` L356][dom-getelement], pinned at
[`1d28cd62`][dom-rev]

It is asynchronous, addressed by DOM `id`, resolved by
`getBoundingClientRect`, and available only _after_ the frame it describes has
been rendered ([doc comment, L347–L351][dom-getelement-doc]). It cannot inform
the layout that produced it. And `elm/browser` is not a dependency of `elm-ui`
at all — [`elm.json`][elmjson] lists only `elm/core`, `elm/html`, `elm/json`
and `elm/virtual-dom` — so the escape hatch is not merely unused by the
toolkit; it is out of the toolkit's reach by construction.

### How `elm-ui` verifies layout it cannot compute

The rendering test suite is the tell. `Testable.Found` carries a `bbox`, a
computed `style`, and `textMetrics`
([`tests-rendering/src/Testable.elm` L187–L201][testable-found]); the numbers
are gathered in JavaScript, by a harness page that calls
`element.getBoundingClientRect()` and `ctx.measureText(...)` on a `2d` canvas
context and ships the results back over a port
([`tests-rendering/automation/templates/gather-styles.html` L81,
L116][gather]), driven through Selenium against real Chrome, Firefox, Edge and
IE ([`tests-rendering/automation/run.js`][runjs]). A comment in `Testable.elm`
concedes the resulting metrics are approximate:

> The font metrics we currently have are `actual`, meaning for the text
> actually rendered, not the font as a whole. We also know the font size is 20,
> so we're just going to return 20.
>
> — [`tests-rendering/src/Testable.elm` L204–L210][testable-textheight]

So the project's own answer to "did the layout come out right" requires
measurement, a real browser, and a JS shim — none of which the library may
contain. The measurement seam did not disappear. It moved to the test harness
and became an out-of-process oracle.

## Q1 — measurement units, and who answers

**Nobody measures, and there is no unit.** `Length` never resolves to a number
inside `elm-ui`; `Content` (`shrink`) is spelled `width: auto` and answered by
the browser's intrinsic-sizing algorithm, `Fill` by flexbox. The only
extent-shaped values that cross the API are the author's own `px` literals and
the four `Adjustment` fractions.

This is the extreme end of [F1][comparison]. The four previously surveyed
subjects all agreed measurement does not belong on the painter; `elm-ui` shows
that a toolkit can be built where measurement does not belong _anywhere in the
toolkit_ — provided one backend, with a complete constraint solver, is willing
to finish the job. The condition is the finding: **you may delete `measure`
only if the seam is a constraint system rather than a command stream, and only
if every backend can solve it.** A `RecordingCanvas` cannot solve flexbox, and
neither can a terminal.

## Q2 — is the backend contract stated in one place?

Does not arise as a contract question, and the reason is instructive. There is
one backend and it is not pluggable: `Element.layout` returns `Html msg`
([`src/Element.elm` L444][element-layout]), and the "contract" is the
generated stylesheet in `src/Internal/Style.elm` — 1798 lines of CSS emitted as
Elm data. It _is_ stated in one place, exhaustively, because it is a single
implementation rather than an interface.

What the project pays instead is a browser-compatibility matrix: the
`tests-rendering` suite exists to catch the places where Chrome, Firefox,
Safari and IE disagree about the same CSS, and the case directory carries the
scars by name — `Layout/SafariBugIssue147.elm`,
`Layout/Columns/SafariTwo.elm`, `open/WeirdCentering.elm`. A single seam with
one implementation still had multiple backends; they were just not declared.

## Q3 — semantic widgets or primitives?

**Semantic all the way down, and the widget is the seam.** `row`, `column`,
`paragraph`, `table`, `Element.Input.slider`, `scrollbarY` are the vocabulary;
nothing below them is expressible. Two consequences bear directly on
[friction §3][friction]:

- **A scrollbar is not drawn.** `scrollbarX` / `scrollbarY` emit
  `overflow-x: auto` / `overflow-y: auto`
  ([`src/Internal/Style.elm` L1199–L1213][style-scrollbars]). The thumb's
  existence, size and position are computed by the browser from content
  extent — a quantity `elm-ui` cannot know. Our `DrawOp` carries
  `barContent` / `barViewport` / `barOffset` precisely so a backend can compute
  a thumb; `elm-ui` carries nothing because it delegates the sizing along with
  the drawing.
- **There is no ellipsis.** `text-overflow` appears nowhere in the source tree
  (verified: no match for `text-overflow` or `ellipsis` in `src/`). Truncation
  requires knowing that a string exceeds a box, which is exactly the fact the
  design forgoes. Clipping is available (`clip` → `overflow: hidden`,
  [L1214][style-clip]) because clipping needs no measurement; eliding needs
  measurement, and so it does not exist.

The pattern generalises: **an operation that only needs a constraint survives
delegation; an operation that needs an answer does not.** Fill, shrink, align,
space, clip, scroll all survive. Ellipsis, "wrap only if it doesn't fit",
content-sized thumbs and any layout that branches on a measured extent do not.

## Q4, Q5, Q6, Q7 — not answered here

These four questions presuppose a reified draw command with a payload, an
appearance and a coordinate. `elm-ui` has none, so the questions do not arise —
but the _reason_ they do not arise is a single fact worth recording once.

- **Q4 (command shape):** the output is `VirtualDom.Node`, diffed by
  `elm/virtual-dom`. There is no command stream to encode well or badly.
- **Q5 (sub-unit placement):** coordinates are continuous CSS pixels and
  fractional `em`s (`vertical-align` is emitted as a `Float` in `em`,
  [L2518][model-adjustrules]). Like Slint, Qt and egui, the sub-unit problem
  simply does not exist. This is now four of five surveyed subjects for whom
  [F5][comparison] holds trivially, which strengthens the reading that
  `RuleEdge` is an artifact of integer cell coordinates rather than a design
  choice anyone else faced.
- **Q6 (resolved or semantic styling):** semantic on the way in
  (`Background.color`, `Font.size`), resolved by CSS cascade on the way out.
  `elm-ui` never carries both, because the thing it hands over — a class name —
  _is_ the semantic token, and resolution happens in a layer it does not own.
  That is the HTML interpreter's position in our own tree, generalised to the
  whole toolkit.
- **Q7 (payload ownership):** immutable, garbage-collected, shared by default.
  A `String` in Elm cannot dangle and cannot be mutated, so borrowed-slice
  lifetime — [friction §7][friction] — is unrepresentable rather than solved.

## Q8 — extent query

**Absent by construction, and this is the survey's cleanest confirmation of
[F7][comparison].** The only extent query in the ecosystem is
`Browser.Dom.getElement`, which returns `scene`, `viewport` _and_ `element`
rectangles ([`src/Browser/Dom.elm` L367–L384][dom-element-type]) — i.e. the
surface declares its extent, and it does so post-hoc, asynchronously, from
outside the toolkit. Nothing derives an extent by scanning a display list,
because there is no display list.

The corollary for our [friction §8][friction]: a design that cannot ask "how
big is the scene" also cannot offer content-sized offscreen rendering. `elm-ui`
does not offer it, and no one appears to have demanded it — a data point for
scoping the layout query F7 recommends narrowly.

## What would survive in `sparkles:ui` if `measure` were deleted

The question the survey actually needs, answered against
[`libs/ui/src/sparkles/ui/layout.d`][layout]. Text measurement enters the
four-pass engine at exactly four call sites:

| Site                        | Pass                | What it decides                     |
| --------------------------- | ------------------- | ----------------------------------- |
| `tm.width(node.text)`       | 1, natural width    | a `text` node's intrinsic width     |
| `tm.width(span.text)`       | 1, natural width    | a `rich` node's intrinsic width     |
| `wrapLines(…, tm.width, …)` | 3, height for width | greedy line breaking of a `text`    |
| `wrapSpans(…, tm.width, …)` | 3, height for width | line breaking of a `rich` paragraph |

Everything else in 1053 lines is measurement-free: `SizeSpec` resolution
(`fit` / `fixed` / `grow` / `percent`), `distributeMain`'s leftover
distribution and overflow reclamation with exact `divmod` remainders,
`alignOffset`, padding and gap arithmetic, `stretch`, `Visibility.collapsed`
removal from flow, `clipX`/`clipY`, and the placement pass. Those are precisely
`elm-ui`'s surviving set — `fill`, `fillPortion`, `spacing`, `padding`,
alignment, `clip` — and the correspondence is not a coincidence: they are the
decisions expressible as constraints among siblings rather than as a function
of content.

What would break is equally precise: a `fit`/`shrink` box around text, and
wrapping. `elm-ui` keeps both by delegating them to a solver in the backend.
`sparkles:ui` has no such solver in either backend — a terminal grid cannot
line-break for us and neither can Skia's canvas — so **deletion is not
available to us; only relocation is.** That is the negative result this subject
was on the list to produce, and it is worth having stated with the four call
sites named.

> [!IMPORTANT]
> The survey's sharpest local finding is adjacent and uncomfortable.
> `sparkles:ui` **already** does what [F1][comparison] recommends: `layout` is
> parameterised on `isTextMeasure` and never touches a canvas
> ([`layout.d`, `isTextMeasure` / `CellMeasure`][layout]). Meanwhile
> `isCanvas!T` still demands `Size measure(const(char)[])`
> ([`canvas.d` L158–L169][canvas]) — and no interpreter call site calls it. A
> grep across `libs/` and `apps/` finds `.measure(` on a canvas only in
> `canvas.d`'s own concept and unittest and in `libs/skia`'s equivalent
> assertion — never in `interp/`. Backends do implement it
> (`GridCanvas.measure` is the grapheme-aware one), but **every in-tree call
> site of `layout` passes the default `CellMeasure`**, so no backend's answer
> has ever reached the engine; `grid_canvas.d` records the same thing as the
> open `LAY5`/`MIG5` measurement gap. `SkiaCanvas.measure` is therefore not a
> backend forced to lie so much as a member of a concept the painter never
> consults — and `sparkles:ui` is today, operationally, in `elm-ui`'s position
> without having chosen it.

## Strengths

- **The measurement question is not deferred, it is answered "no".** A design
  that cannot measure cannot accumulate measurement-dependent features by
  accident, and the API stays small for the same reason.
- **Layout is a constraint system, so it composes.** `fill` inside `fill`
  inside a `wrappedRow` needs no arbitration by the toolkit.
- **One authority for extents means no disagreement.** The class of bug where
  layout believes one advance and the painter draws another — the bug
  [friction §1][friction] warns about — is structurally impossible.
- **Metrics-as-data is a clean pattern.** `Font.Adjustment` shows that a
  toolkit can accept font metrics as declared values rather than as a query,
  which decouples the layout engine from the measuring subsystem entirely.

## Weaknesses

- **The forbidden set is large and popular.** No ellipsis, no measured
  truncation, no toolkit-side wrapping decisions, no content-sized scrollbar
  thumb, no "size this offscreen surface to its content".
- **Correctness is only verifiable out of process.** The rendering suite needs
  Selenium, four browsers, and JS `measureText`; nothing about layout can be
  asserted in a unit test.
- **Delegation reintroduces backend divergence under a different name.** The
  Safari- and IE-named test cases are backend-parity bugs in a project that
  believed it had one backend.
- **`px` is a leak.** The one absolute unit in the API is a device unit, so
  authorship is implicitly pinned to the browser's pixel — there is no
  `Length` a terminal could interpret.

## Key design decisions and trade-offs

| Decision                                                 | Rationale                                                                       | Trade-off                                                                                       |
| -------------------------------------------------------- | ------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| No text measurement anywhere in the library              | Elm is pure and total; a synchronous metrics query is not expressible           | Every measurement-dependent feature is unbuildable, including ellipsis and conditional wrapping |
| `Length` lowers to CSS classes, never to numbers         | The browser already has a constraint solver; duplicating it would only disagree | The toolkit cannot answer questions about its own layout, including for tests                   |
| Wrapping is a `paragraph` element, not a text property   | `white-space: normal` on a subtree is a delegation the browser can honour       | Wrapping is a structural choice made before any width is known; no fallback if it wraps badly   |
| Font metrics supplied as an author-declared `Adjustment` | Vertical rhythm needs real metrics; a design-time slider tool can produce them  | Metrics are per-typeface literals that silently rot when the font changes                       |
| Scrollbars are `overflow: auto`                          | Thumb geometry requires content extent, which is unavailable                    | No control over the thumb, its size, its styling, or its behaviour                              |
| One backend, undeclared                                  | Keeps the vocabulary small and the stylesheet exhaustive                        | Browser divergence resurfaces as a Selenium matrix instead of as a capability query             |

## Bearing on the proposal

1. **`measure` cannot be deleted from `sparkles:ui`, only relocated.** The four
   call sites in [`layout.d`][layout] are all text sizing or wrapping, and no
   `sparkles:ui` backend contains a line breaker willing to take them over.
   This closes the "maybe the seam does not need measurement at all" branch
   that [friction §1][friction] leaves implicitly open.
2. **The relocation F1 recommends is already done — and unfinished.** `layout`
   takes an injected `isTextMeasure`; `isCanvas` separately demands `measure`
   and nothing calls it. The concrete action is _removing_ `measure` from
   `isCanvas`, not designing a new font abstraction. This complicates F1's
   framing: the finding is right, the friction log's description of the harm
   ("the best measurer in the system must lie") overstates it, since the liar
   is a member no caller consults.
3. **Adopt metrics-as-data alongside metrics-as-query.** `Font.Adjustment` is a
   better fit for a terminal-first toolkit than a callback: a cell backend's
   metrics _are_ four constants. An `isTextMeasure` implementation that is a
   plain value, not a canvas reference, is what every in-tree call site already
   uses (`CellMeasure`), and formalising that keeps `layout` `@safe pure`.
4. **Contradicts F3's framing, mildly.** F3 says the real axis is "who
   degrades". `elm-ui` adds a third position — _nobody degrades, because the
   toolkit never names the thing_. Its scrollbar is not a semantic op that a
   backend degrades; it is an overflow policy. Reading `scrollbar` in
   `DrawOp` against that: our eight scrollbar fields exist because we compute
   thumb geometry and hand it over. A policy-shaped alternative
   ("this subtree scrolls") is available to us for the GPU backend and _not_
   available for the cell backend, which must draw the thumb itself — so
   [friction §3][friction] resolves toward keeping the semantics, and the fix
   is to stop shipping the derived geometry that `scrollbarThumb` already
   computes once.
5. **Confirms F7 from the far side.** A toolkit with no extent query shipped
   for years, and the ecosystem's only extent answer comes from the surface,
   asynchronously, after the fact ([`Browser.Dom.getElement`][dom-getelement]).
   Scope [friction §8][friction] to the offscreen sizing case and give it a
   layout query, not a display-list property.
6. **A warning about the "two seams" open question.** `elm-ui` is the case
   where a toolkit assumed one backend and got four (Chrome, Firefox, Safari,
   IE) with no capability vocabulary to describe their disagreement. Whichever
   way the terminal/GPU seam question resolves, the disagreements must be
   _nameable_; `elm-ui` shows what it costs when they are not.

## Sources

- [`mdgriffith/elm-ui` at `acae8857`][rev] — the pinned tree. Revision resolved
  with `gh api repos/mdgriffith/elm-ui/commits/master --jq .sha`; every cited
  path was fetched from `raw.githubusercontent.com` at that SHA and read.
- [`README.md`][readme] and [`notes/CHANGES-FROM-STYLE-ELEMENTS.md`][changes] —
  the stated goals and the "everything explicit and in your view" invariant.
- [`src/Element.elm`][elementsrc] — the public vocabulary (`Length`, `px`,
  `shrink`, `fill`, `fillPortion`, `text`, `row`, `column`, `paragraph`).
- [`src/Internal/Model.elm`][modelsrc] — `Element`, `Length`, `renderWidth`,
  `SpacingStyle`, `convertAdjustment`, `textElement`.
- [`src/Internal/Style.elm`][stylesrc] — the emitted stylesheet: `width: auto`,
  `flex-grow`, `overflow: auto`, `white-space`.
- [`src/Element/Font.elm`][fontsrc] and
  [`experiments/font-adjustment/FontAdjustment.elm`][fontadj] — metrics as
  author-declared data, and the human-in-the-loop tool that produces them.
- [`tests-rendering/`][testsrendering] — the out-of-process measurement oracle.
- [`elm/browser` at `1d28cd62`, `src/Browser/Dom.elm`][dom-getelement] — the
  asynchronous escape hatch.
- [`libs/ui/src/sparkles/ui/layout.d`][layout] and
  [`libs/ui/src/sparkles/ui/canvas.d`][canvas] — the local side.

<!-- References -->

[rev]: https://github.com/mdgriffith/elm-ui/tree/acae8857a02e600cc4b4737ca2f70607228b4489
[readme]: https://github.com/mdgriffith/elm-ui/blob/acae8857a02e600cc4b4737ca2f70607228b4489/README.md
[changes]: https://github.com/mdgriffith/elm-ui/blob/acae8857a02e600cc4b4737ca2f70607228b4489/notes/CHANGES-FROM-STYLE-ELEMENTS.md
[elmjson]: https://github.com/mdgriffith/elm-ui/blob/acae8857a02e600cc4b4737ca2f70607228b4489/elm.json
[elementsrc]: https://github.com/mdgriffith/elm-ui/blob/acae8857a02e600cc4b4737ca2f70607228b4489/src/Element.elm
[element-text]: https://github.com/mdgriffith/elm-ui/blob/acae8857a02e600cc4b4737ca2f70607228b4489/src/Element.elm#L549
[element-text-doc]: https://github.com/mdgriffith/elm-ui/blob/acae8857a02e600cc4b4737ca2f70607228b4489/src/Element.elm#L545
[element-paragraph]: https://github.com/mdgriffith/elm-ui/blob/acae8857a02e600cc4b4737ca2f70607228b4489/src/Element.elm#L1047
[element-layout]: https://github.com/mdgriffith/elm-ui/blob/acae8857a02e600cc4b4737ca2f70607228b4489/src/Element.elm#L444
[modelsrc]: https://github.com/mdgriffith/elm-ui/blob/acae8857a02e600cc4b4737ca2f70607228b4489/src/Internal/Model.elm
[model-element]: https://github.com/mdgriffith/elm-ui/blob/acae8857a02e600cc4b4737ca2f70607228b4489/src/Internal/Model.elm#L120-L126
[model-length]: https://github.com/mdgriffith/elm-ui/blob/acae8857a02e600cc4b4737ca2f70607228b4489/src/Internal/Model.elm#L341-L346
[model-renderwidth]: https://github.com/mdgriffith/elm-ui/blob/acae8857a02e600cc4b4737ca2f70607228b4489/src/Internal/Model.elm#L1353
[model-spacing]: https://github.com/mdgriffith/elm-ui/blob/acae8857a02e600cc4b4737ca2f70607228b4489/src/Internal/Model.elm#L2743
[model-textelement]: https://github.com/mdgriffith/elm-ui/blob/acae8857a02e600cc4b4737ca2f70607228b4489/src/Internal/Model.elm#L2058
[model-convertadjustment]: https://github.com/mdgriffith/elm-ui/blob/acae8857a02e600cc4b4737ca2f70607228b4489/src/Internal/Model.elm#L3484
[model-adjustrules]: https://github.com/mdgriffith/elm-ui/blob/acae8857a02e600cc4b4737ca2f70607228b4489/src/Internal/Model.elm#L2518
[stylesrc]: https://github.com/mdgriffith/elm-ui/blob/acae8857a02e600cc4b4737ca2f70607228b4489/src/Internal/Style.elm
[style-widthcontent]: https://github.com/mdgriffith/elm-ui/blob/acae8857a02e600cc4b4737ca2f70607228b4489/src/Internal/Style.elm#L1223
[style-fill]: https://github.com/mdgriffith/elm-ui/blob/acae8857a02e600cc4b4737ca2f70607228b4489/src/Internal/Style.elm#L888-L894
[style-pre]: https://github.com/mdgriffith/elm-ui/blob/acae8857a02e600cc4b4737ca2f70607228b4489/src/Internal/Style.elm#L866
[style-paragraph]: https://github.com/mdgriffith/elm-ui/blob/acae8857a02e600cc4b4737ca2f70607228b4489/src/Internal/Style.elm#L1626
[style-inlineblock]: https://github.com/mdgriffith/elm-ui/blob/acae8857a02e600cc4b4737ca2f70607228b4489/src/Internal/Style.elm#L1653-L1656
[style-scrollbars]: https://github.com/mdgriffith/elm-ui/blob/acae8857a02e600cc4b4737ca2f70607228b4489/src/Internal/Style.elm#L1199-L1213
[style-clip]: https://github.com/mdgriffith/elm-ui/blob/acae8857a02e600cc4b4737ca2f70607228b4489/src/Internal/Style.elm#L1214
[fontsrc]: https://github.com/mdgriffith/elm-ui/blob/acae8857a02e600cc4b4737ca2f70607228b4489/src/Element/Font.elm
[font-adjustment]: https://github.com/mdgriffith/elm-ui/blob/acae8857a02e600cc4b4737ca2f70607228b4489/src/Element/Font.elm#L141-L146
[font-sizebycapital]: https://github.com/mdgriffith/elm-ui/blob/acae8857a02e600cc4b4737ca2f70607228b4489/src/Element/Font.elm#L161
[fontadj]: https://github.com/mdgriffith/elm-ui/blob/acae8857a02e600cc4b4737ca2f70607228b4489/experiments/font-adjustment/FontAdjustment.elm
[fontadj-slider]: https://github.com/mdgriffith/elm-ui/blob/acae8857a02e600cc4b4737ca2f70607228b4489/experiments/font-adjustment/FontAdjustment.elm#L293
[testsrendering]: https://github.com/mdgriffith/elm-ui/tree/acae8857a02e600cc4b4737ca2f70607228b4489/tests-rendering
[testable-found]: https://github.com/mdgriffith/elm-ui/blob/acae8857a02e600cc4b4737ca2f70607228b4489/tests-rendering/src/Testable.elm#L187-L201
[testable-textheight]: https://github.com/mdgriffith/elm-ui/blob/acae8857a02e600cc4b4737ca2f70607228b4489/tests-rendering/src/Testable.elm#L204-L210
[gather]: https://github.com/mdgriffith/elm-ui/blob/acae8857a02e600cc4b4737ca2f70607228b4489/tests-rendering/automation/templates/gather-styles.html#L116
[runjs]: https://github.com/mdgriffith/elm-ui/blob/acae8857a02e600cc4b4737ca2f70607228b4489/tests-rendering/automation/run.js
[dom-rev]: https://github.com/elm/browser/tree/1d28cd625b3ce07be6dfad51660bea6de2c905f2
[dom-getelement]: https://github.com/elm/browser/blob/1d28cd625b3ce07be6dfad51660bea6de2c905f2/src/Browser/Dom.elm#L356
[dom-getelement-doc]: https://github.com/elm/browser/blob/1d28cd625b3ce07be6dfad51660bea6de2c905f2/src/Browser/Dom.elm#L347-L351
[dom-element-type]: https://github.com/elm/browser/blob/1d28cd625b3ce07be6dfad51660bea6de2c905f2/src/Browser/Dom.elm#L367-L384
[pkgdocs]: https://package.elm-lang.org/packages/mdgriffith/elm-ui/1.1.8/Element
[friction]: ../../specs/ui-skia/canvas-seam-friction.md
[comparison]: ./comparison.md
[layout]: ../../../libs/ui/src/sparkles/ui/layout.d
[canvas]: ../../../libs/ui/src/sparkles/ui/canvas.d
