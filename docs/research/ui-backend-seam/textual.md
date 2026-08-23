# Textual — the seam is the rendered result, not a drawing API

**Category:** cross-target — a cell toolkit that grew a second target.
**Last reviewed:** August 23, 2026. Pinned at [`06dbeef4`][rev].

Textual is the mirror image of `sparkles:ui`'s problem: a terminal-native
toolkit that acquired an SVG target and a browser target after the fact. It
solved that by never having a drawing seam to port. A widget produces a list of
`Strip`s — styled runs of text measured in cells — and every target consumes
that same reified result. There is no `Canvas`, no `DrawOp`, and no backend
that draws anything.

> [!NOTE]
> This deep-dive is about the **backend seam only**. Textual's widget model,
> CSS layer, event system and ecosystem are covered in
> [`docs/research/tui-libraries/textual.md`](../tui-libraries/textual.md) and
> are not repeated here.

| Field                | Value                                                                                            |
| -------------------- | ------------------------------------------------------------------------------------------------ |
| **Language**         | Python (>= 3.9)                                                                                  |
| **License**          | MIT ([`LICENSE`][license])                                                                       |
| **Repository**       | [`Textualize/textual`][repo]                                                                     |
| **Documentation**    | [textual.textualize.io][docs]                                                                    |
| **Category**         | cross-target cell toolkit                                                                        |
| **Pinned revision**  | [`06dbeef4bb70fb718236aa418ed658ef4667a126`][rev] (2026-07-11, version `8.2.8`)                  |
| **Target range**     | character cells only — every target is a cell grid                                               |
| **Targets shipped**  | terminal (`LinuxDriver`, `WindowsDriver`, inline), headless, web relay (`WebDriver`), SVG export |
| **Reified artifact** | `Strip` — an immutable list of `Segment(text, style, control)`                                   |

## Overview

### What it solves

A widget renders one line at a time. [`Widget.render_line(y)`][widget] returns a
[`Strip`][strip]; [`Widget.render_lines(crop)`][widget] returns a list of them.
The [`Compositor`][compositor] cuts those strips at widget boundaries, keeps the
frontmost, and joins them back into one strip per screen line. That joined result
is then encoded — to ANSI for a terminal, to ANSI framed in a length-prefixed
packet for the browser relay, or to SVG `<rect>` and `<text>` elements for a
screenshot. The encoding step is the only thing that differs between targets.

### Design philosophy

The [Line API guide][guide] states the model without ceremony:

> A [Strip][textual.strip.Strip] is a container for a number of segments
> covering a single _line_ (or row) in the Widget.

and, on the unit:

> Note that the cell length parameter is _not_ the total number of characters in
> the string. It is the number of terminal "cells". Some characters (such as
> Asian language characters and certain emoji) take up the space of two Western
> alphabet characters.

The cell is the toolkit's only unit, and it is a property of the **string**, not
of a font, a device or a backend. Every target inherits that decision; the SVG
exporter does not get a vote.

## How it works

The seam that every target implements is [`Driver`][driver], and its output half
is one method:

```python
class Driver(ABC):
    @abstractmethod
    def write(self, data: str) -> None:
        """Write data to the output device.

        Args:
            data: Raw data.
        """
```

That is the whole drawing contract: a string of already-encoded terminal
sequences. `App._display` calls `CompositorUpdate.render_segments(console)` to
build that string and hands it to `self._driver.write(terminal_sequence)`
([`app.py`][app]). The `WebDriver` overrides `write` to frame the identical
bytes — `b"D" + length + utf8` — for `textual-web` / `textual-serve`
([`web_driver.py`][webdriver]); `HeadlessDriver.write` discards them
([`headless_driver.py`][headless]). Neither ever sees a widget, a rectangle or a
colour.

The artifact those bytes come from is the `Strip`, which encodes **itself**:

```python
def render(self, console: Console) -> str:
    """Render the strip into terminal sequences."""
    if self._render_cache is None:
        color_system = console._color_system or ColorSystem.TRUECOLOR
        render = self.render_style
        self._render_cache = "".join(...)
    return self._render_cache
```

`Strip.render_ansi` performs the colour degradation inline —
`color.downgrade(color_system)` — and caches the resulting SGR string in an
`lru_cache(maxsize=16384)` keyed on `(style, color_system)` ([`strip.py`][strip]).

Above the strip sits a second, genuinely abstract seam: [`Visual`][visual], an
ABC with exactly three abstract methods.

```python
class Visual(ABC):
    @abstractmethod
    def render_strips(self, width: int, height: int | None,
                      style: Style, options: RenderOptions) -> list[Strip]: ...
    @abstractmethod
    def get_optimal_width(self, rules: RulesMap, container_width: int) -> int: ...
    @abstractmethod
    def get_height(self, rules: RulesMap, width: int) -> int: ...
```

Note what that is: **rendering and measurement in one contract, both denominated
in cells, and neither of them a painter.** A `Visual` is a piece of content that
knows how to produce cells and how many cells it wants. `Content`
([`content.py`][content]) and `RichVisual` are the two implementations that
matter.

## Q1 — measurement unit, and who answers

Cells, always, and the answer comes from a **free function over the string**.
[`textual/_cells.py`][cells] is four lines of substance:

```python
cell_len: Callable[[str], int]
try:
    from rich.cells import cached_cell_len as cell_len
except ImportError:
    from rich.cells import cell_len
```

`rich.cells.cell_len` is a pure `str -> int` binary search over a Unicode width
table, with a fast path for a frozen set of known-single-cell ranges and an
explicit ZWJ / VS16 pass ([`rich/cells.py`][richcells]). No font, no device, no
injection point, no backend parameter. `Strip.cell_length` is `sum(cell_len(...))`
over its segments, computed on demand and memoised.

This lands somewhere uncomfortable for **F1**. F1 concludes that measurement does
not belong on the painter — Textual agrees, emphatically, and goes further: it
does not belong on anything that a backend can substitute. But placement is only
the first of the six decisions [**F2**](./comparison.md) separates out, and
Textual answers the next one — the unit — the other way: a shaping backend never
gets to reply in its own. The SVG exporter — the one target with real pixels — is
handed cells and made to comply:

```python
char_height = 20
char_width = char_height * font_aspect_ratio   # default 0.61, Fira Code
...
text_group.append(make_tag("text", escape_text(text), ...,
                           x=x * char_width,
                           textLength=char_width * len(text), ...))
x += cell_len(text)
```

([`rich/console.py`][richconsole], `Console.export_svg`.) The pixel target derives
its advance from a **constant aspect ratio** and pins each run's rendered width
with SVG's `textLength` attribute, which forces the renderer to stretch or
compress real glyph advances onto the grid. This is `SkiaCanvas.measure` returning
`cellsOf(text)` — [friction §1][friction] — adopted deliberately, as policy,
by a shipped second backend.

> [!WARNING]
> The two width computations in that loop disagree: `textLength` is
> `char_width * len(text)` (code points) while the pen advances by
> `cell_len(text)` (cells). For a run containing a double-width character the
> forced text length is narrower than the cell span it occupies. Visible in the
> source at the pinned revision; not something the project documents.

## Q2 — is the contract stated in one place?

Yes, three times, and each time as a small complete ABC with no optional members
and no probing:

| Seam         | Abstract members                                                            | File                  |
| ------------ | --------------------------------------------------------------------------- | --------------------- |
| `Driver`     | `write`, `start_application_mode`, `disable_input`, `stop_application_mode` | [`driver.py`][driver] |
| `Visual`     | `render_strips`, `get_optimal_width`, `get_height`                          | [`visual.py`][visual] |
| `LineFilter` | `apply(segments, background)`                                               | [`filter.py`][filter] |

There is no `hasFeature`, no capability enum, and nothing resembling
`__traits(compiles)`. Optionality is expressed as **non-abstract methods with
defaults** — `Driver.flush`, `Driver.close`, `Driver.suspend_application_mode`,
and the `is_headless` / `is_inline` / `is_web` / `can_suspend` properties that
each default to `False`. A caller asks "are you inline?", never "can you do X?".

That is a stronger position than **F5** allows for. Textual has neither a
declared floor nor a refusable degrade, and does not appear to want one, because
the seam is narrow enough that there is nothing to negotiate: everyone can write
a string. The lesson for [friction §2][friction] — where four optional primitives
are probed with `__traits(compiles)` at each interpreter call site rather than
named in the concept — is not "declare your capabilities" but "a seam small
enough not to need capability declaration is available, if the reified artifact
carries the work instead."

## Q3 — semantic widgets at the seam

They never reach it. A scrollbar in Textual is an ordinary
[`Widget`][scrollbarpy] whose `render()` returns a Rich renderable;
`ScrollBarRender.render_bar` computes thumb geometry and emits `Segment`s
directly. By the time anything is composited, a scrollbar is indistinguishable
from a paragraph of text.

This is the opposite of Slint's answer, and it is the priced example of the
**widget** camp in [**F4**](./comparison.md)'s enumeration of the places a
lowering can live: **the widget degrades, in the toolkit's own vocabulary, before
any target exists.** `ScrollBarRender` reaches 1/8-cell resolution by choosing
among eight block glyphs, and `ScrollBar.validate_position` documents the
consequence:

```python
def validate_position(self, position: float) -> float:
    """Position has a granulatory of 1/8 of a cell."""
    return int(position * 8) / 8
```

Because every target is a cell grid, a degradation decided once is correct
everywhere. `sparkles:ui` cannot copy this wholesale — its GPU target could do
better than eight steps — but it shows that the fourteen fields of `DrawOp`'s
`Scrollbar` payload buy backend-specific degradation that Textual simply does not
need. F4's distinction survives the comparison: a semantic scrollbar operation is
legitimate, and what [friction §3][friction] objects to is narrower — the cell
backend's own answer, `trackGlyph` and `thumbGlyph`, riding past every backend
that will never read it.

## Q4 — command shape

Textual reifies, but it reifies the **result**, not the commands. The unit is
`rich.segment.Segment`, a three-field `NamedTuple`:

```python
class Segment(NamedTuple):
    text: str
    style: Optional[Style] = None
    control: Optional[Sequence[ControlCode]] = None
```

One variant. No tag. The trade [**F3**](./comparison.md) frames — a closed sum
whose every value costs the widest arm, against variable-stride per-op records
that pay only for what each one uses — does not arise, because there is only one
kind of thing a widget can produce.

Two observations bear on that trade. First, even a one-variant record grew a
tag-shaped field: `control` is `None` for every drawing segment, `is_control`
exists to test it, and both `get_line_length` and `Console.export_svg` must
filter control segments out (`Segment.filter_control`) before they can measure or
export. Dead fields appear the moment two unlike things share a type, regardless
of how few variants there are — which is the argument for `sparkles:ui` deriving
`OpKind` from the arm that answers rather than storing a tag beside the payload.

Second, and more importantly, reifying the _result_ buys properties that
reifying _commands_ does not. A `Strip` is immutable and therefore cacheable, and
it supports `crop`, `divide`, `join`, `simplify`, `apply_filter`, `apply_style`,
`extend_cell_length` and `text_align` — each returning a new `Strip`, each backed
by its own `FIFOCache` on the instance ([`strip.py`][strip]). The compositor's
whole algorithm is expressed in those operations: `cuts()` computes every column
where a widget starts or ends, `_render_chops` divides each widget's strip at
those cuts and keeps the first (frontmost) occupant of each chop, and
`render_strips` joins the survivors. None of that is expressible over a
`DrawOp[]` without first rasterising it.

**F3 stands but narrows:** the reified stream is worth keeping, and the sharpest
choice is not how one operation is encoded but "commands versus results".
`sparkles:ui` reifies commands because a canvas is the thing it abstracts;
Textual reifies results because a cell is.

## Q5 — sub-unit placement

No seam concept exists, and two mechanisms cover the ground instead.

**Glyph vocabulary in the widget** — the eighth-blocks above, and Textual's
horizontal equivalent `["▉", "▊", "▋", "▌", "▍", "▎", "▏", " "]`.

**Accumulated join state, resolved late** — [`textual/canvas.py`][canvas] keeps,
per cell, a `Quad` (`tuple[int, int, int, int]`, one line-weight per compass
direction) alongside the character array, and primitives `combine_quads` into it.
Only at `Canvas.render` is each quad looked up in the hand-authored
[`BOX_CHARACTERS`][boxdrawing] table and turned into a glyph:

```python
for box, line in zip(self.box, self.lines):
    for offset, quad in box.items():
        line[offset] = get_box(quad)
```

That is a better shape than `RuleEdge` for the same problem. `RuleEdge` names one
edge of one rect on one op, so two ops touching the same cell cannot agree; a
`Quad` is a per-cell accumulator, so they compose by construction and the glyph
choice happens once, after everything has been said. It does not give sub-cell
_offsets_ — nothing in Textual does — but it dissolves the specific failure
[friction §5][friction] describes, where each new sub-cell need demands a new
enumerator.

## Q6 — resolved appearance, semantic role, or both

Both, split by who consumes them, and resolved through an **injected resolver**
rather than carried per-op.

`Content` stores `Span(start, end, style: Style | str)` — a span's style may be a
component-class _name_ ([`content.py`][content]). Resolution happens in
`Content.render_strips`, which is handed `options.get_style`, a callable supplied
by the widget (`Widget._get_style` walks `ancestors_with_self` looking for a
matching component class). By the time a `Strip` exists, every style is resolved.

But the semantic half does not vanish: `textual.style.Style` carries
`_meta: bytes | None`, an opaque pickled payload ([`style.py`][style]). The
scrollbar puts `{"@mouse.down": "grab"}` there; `Compositor.get_style_at(x, y)`
re-renders the line under the cursor and walks segments accumulating
`segment.cell_length` until it passes `x`, then returns that segment's style
([`_compositor.py`][compositor]). **The reified result is also the hit-test
structure.**

That is the honest answer to [friction §6][friction]. Carrying appearance _and_
semantics on the same artifact is not a hedge; the semantics pay for themselves
by making the display list queryable. What Textual does differently is that the
semantic payload is opaque to the drawing path — no target reads `_meta` — and
it rides on the `Style`, which is interned and shared, not on every op. That is
one of the cheaper encodings [**F9**](./comparison.md) counts: the role travels
on a shared value, and the resolved appearance each cell paints from is produced
from it on the way out.

## Q7 — payload ownership

`Segment.text` is a Python `str`: immutable, reference-counted, shared freely.
`Strip` is documented as "like an immutable list of Segments. The immutability
allows for effective caching" ([`strip.py`][strip]), and every derived operation
returns a new `Strip` that shares the same underlying `str` objects. Styles are
shared the same way, with `lru_cache` on `monochrome_style`, `render_ansi` and
`Segment._split_cells`.

Nothing is borrowed across a frame, so nothing has a lifetime problem: strips
outlive the frame by design, and `_StylesCache` keeps them per line across
frames, invalidating only dirty lines ([`_styles_cache.py`][stylescache]). This
is **F8**'s refcounting mechanism, in the language where it is cheapest — worth
noting, because in D reference-counting a text payload is not free.
`sparkles:ui` sits in F8's other camp: `CmdBuffer.textRun` copies each run into a
frame arena, which is what makes a `scope` source safe to draw from, and the rule
stated on the type is that an operation is valid while the buffer that built it
is alive and unreset. The transferable half of Textual's answer is the _shape_:
an immutable, self-measuring, splittable line object owned by a per-widget cache,
rather than a slice borrowed from a per-frame arena — the retain boundary
[friction §7][friction] describes and `UI-O4` leaves open.

## Q8 — extent query

Textual separates two of **F7**'s three extent questions and never meets the
third: surface extent comes from the driver, layout extent is a query on the
content, and ink extent has no meaning on a grid.

`Compositor.render_strips(size)` takes the size; `App.export_screenshot` reads
`width, height = self.size`, which the driver derives from the terminal
([`app.py`][app]). Nothing scans the result to discover how big it is.

Independently, `Visual.get_optimal_width(rules, container_width)`,
`get_minimal_width(rules)` and `get_height(rules, width)` answer "how big does
this content want to be" without rendering it — a content-sizing query on the
content, not on the painter and not on the display list. Both answers are
maintained or queried, never derived by scanning a built result: Textual sits at
one pole of F7's axis, and `skia-canvas-render.d`'s op-scan
([friction §8][friction]) at the other.

## The second and third targets, concretely

Worth stating plainly because it is the whole reason this subject is on the list.

**SVG is not a backend.** `App.export_screenshot` builds a throwaway
`rich.Console(width, height, record=True, force_terminal=True,
color_system="truecolor")`, prints the compositor's full update into it, and
calls `console.export_svg` ([`app.py`][app]). Recording captures the same
`Segment` list the terminal would have received (`Console._record_buffer: List[Segment]`),
and the SVG generator walks it emitting one `<rect>` per styled background and
one `<text>` per run. Its entire job is **coordinate scaling plus style
translation**: cell `(x, y)` becomes `(x * char_width, y * line_height)`, and a
`Style` becomes a CSS rule string, deduplicated into numbered classes.

**The web target is not a backend either.** `WebDriver.write` takes the finished
ANSI string, UTF-8 encodes it, and frames it. Rendering in the browser is
`xterm.js`'s problem, not Textual's.

**The SVG path is the test oracle.** 448 `.svg` files under
[`tests/snapshot_tests/__snapshots__/test_snapshots/`][snapshots] at the pinned
revision are golden snapshots compared by `pytest-textual-snapshot`. Textual's
equivalent of `RecordingCanvas` is its second target — the artifact that proves
the toolkit is correct is the same artifact a user exports.

## Strengths

- **The seam is one method taking a string.** A new target costs an encoder, not
  a painter. This is why SVG and the browser were addable at all.
- **The reified result is a rich value.** Cacheable, croppable, divisible,
  filterable, joinable, and queryable for hit-testing — one structure serving
  compositing, incremental repaint, mouse routing and export.
- **Measurement is a pure function of the string.** No injection, no per-backend
  disagreement, no possibility of layout and paint measuring differently.
- **Degradation is a pipeline stage, not a backend decision.** `LineFilter`
  transforms `list[Segment] -> list[Segment]` after rendering; `Monochrome`,
  `NoColor`, `DimFilter` and `ANSIToTruecolor` compose in a list built once at
  `App` construction.
- **Content sizing is separate from rendering** and answered by the content.

## Weaknesses

- **Structurally unable to reach a pixel target honestly.** The SVG export is a
  scaled cell grid with `textLength` forcing glyph advances onto it. Proportional
  fonts, sub-pixel positioning and real shaping are not merely unimplemented —
  they are inexpressible, exactly as [friction §1][friction] describes for us.
- **No capability negotiation of any kind.** Colour-system downgrade is decided
  by `rich` and an env var (`TEXTUAL_COLOR_SYSTEM`); a caller cannot ask for
  truecolor and be told no.
- **The one-variant record still grew a dead field.** `Segment.control` is
  `None` on every drawing segment and must be filtered before measuring or
  exporting.
- **Filters run over every strip of every rendered line**, keyed into a
  four-entry `FIFOCache` per strip — a cost paid per frame for a decision
  (`NO_COLOR` is set) that is fixed for the process lifetime.
- **Hit-testing re-renders.** `get_style_at` calls `widget.render_lines` for the
  line under the pointer rather than consulting a stored composition.

## Key design decisions and trade-offs

| Decision                                         | Rationale                                                                          | Trade-off                                                                          |
| ------------------------------------------------ | ---------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| Reify the **result** (`Strip`), not the commands | Compositing, cropping, caching and hit-testing are all strip operations            | The scene cannot be re-rendered at a different fidelity; the cell grid is baked in |
| Backend seam is `Driver.write(str)`              | Adding a target costs an encoder; the terminal encoding is already the wire format | Every target must accept ANSI semantics, so a non-cell target is out of reach      |
| `cell_len` as a pure function of the string      | Layout and paint can never disagree; measurement needs no backend                  | The pixel target must distort glyph advance to match                               |
| One `Segment` variant with an optional `control` | Simplicity; control codes travel with the text they precede                        | Dead field on every drawing segment; explicit filtering before measure/export      |
| Degradation as a post-render `LineFilter` list   | Composable, target-independent, testable in isolation                              | Runs per line per frame for a process-lifetime decision                            |
| Sub-cell fidelity chosen by the widget as glyphs | Correct on every target at once, since every target is a cell grid                 | A better target cannot do better; 1/8 cell is the ceiling forever                  |
| Semantic payload as opaque `Style._meta`         | Makes the composited result the hit-test structure                                 | Pickled bytes in a hot, hashed, cached value                                       |
| SVG export as the golden-snapshot oracle         | The test artifact and the user-facing export are the same code path                | A rendering bug and a snapshot bug are indistinguishable                           |

## Bearing on the proposal

1. **`SkiaCanvas.measure` returning `cellsOf(text)` is defensible, not
   necessarily an error.** Textual's pixel target does the same thing on purpose
   and ships it. [**F1**](./comparison.md) is confirmed — measurement is not on
   the painter — but the argument actually sits in [**F2**](./comparison.md): of
   its six decisions Textual agrees on _placement_ and answers the _unit_ against
   ever letting a shaping backend reply in pixels. The real decision behind
   [friction §1][friction] is whether `sparkles:ui` wants a proportional-font
   future at all. If it does not, cells everywhere is coherent.
2. **Consider reifying the result rather than the commands.** Every property
   `RecordingCanvas` and the op-stream parity harness exist to provide falls out
   of a reified _result_, and compositing, incremental repaint and hit-testing
   fall out too. This is a genuine alternative to both encodings
   [**F3**](./comparison.md) weighs against each other, and the one that would
   let the HTML interpreter, the golden tests and the terminal share one
   artifact. It satisfies [**F12**](./comparison.md)'s condition too — a `Strip`
   is as inspectable a value as a `DrawOp`, so the parity oracle survives the
   move. What it gives up is re-rendering the same scene at a different
   fidelity.
3. **Replace `RuleEdge` with a per-cell accumulator, not more enumerators.**
   `combine_quads` over a `Quad` per cell composes where an edge-per-op cannot,
   and resolves to a glyph once. This is a concrete mechanism for
   [**F6**](./comparison.md)'s conclusion that a float seam only relocates the
   sub-unit problem, and that the answer is a named fidelity rather than a
   position — cheaper than it sounds, and already half-present where
   `GridCanvas` picks a box-drawing glyph for a border.
4. **The scrollbar's lowering could sit one layer higher.** Textual keeps the
   scrollbar entirely above the seam and degrades it to eighth-blocks inside the
   widget — [**F4**](./comparison.md)'s widget camp, chosen deliberately and
   priced. `sparkles:ui` is closer to that than [friction §3][friction] suggests:
   `scrollbarThumb` in `sparkles.ui.state` is the one formula every backend
   renders, and `canvas.d` re-exports the lowerings built on it —
   `scrollbarCellCount` and `scrollbarCell` for a cell track, `ruleEndpoints` for
   a hairline. What crosses the seam without needing to is the cell answer:
   `trackGlyph` and `thumbGlyph` on a payload a pixel backend never reads.
5. **Carry the semantic role, but on the shared style, not on every op.**
   `Style._meta` makes the composited result queryable for hit-testing, which is
   a use `DrawOp.slot` does not have. `Slot` rides on six of the eight payloads
   beside the resolved fields each primitive paints from; before
   [friction §6][friction] decides which half the seam keeps, check whether the
   semantic half could pay for itself the way `_meta` does.
   [**F9**](./comparison.md) points the same way — a role plus a theme yields an
   appearance, and Textual carries the role on an interned value rather than on
   every operation.
6. **Confirms [**F8**](./comparison.md), and answers two of
   [**F7**](./comparison.md)'s three extent questions — one from the surface, one
   from the scene.** Payloads are immutable and refcounted, never borrowed across
   a frame; surface extent comes from the driver, and layout extent is a separate
   query on the content
   (`get_optimal_width` / `get_height`). Both are maintained or queried rather
   than derived by scanning — the opposite pole from the op-scan in
   [friction §8][friction].
7. **A capability declaration may be unnecessary rather than missing.** Textual
   ships a wide target set with zero capability negotiation because its seam is
   one method. Before building the floor-plus-refusable answer
   [**F5**](./comparison.md) recommends, ask whether a narrower seam would make
   [friction §2][friction] moot.

## Sources

- [`src/textual/strip.py`][strip] — `Strip`, `cell_length`, `crop` / `divide` /
  `join` / `simplify` / `apply_filter`, `render`, `render_ansi`.
- [`src/textual/_compositor.py`][compositor] — `cuts`, `_get_renders`,
  `_render_chops`, `render_strips`, `get_style_at`, `render_segments`.
- [`src/textual/visual.py`][visual] — the `Visual` ABC and `Visual.to_strips`.
- [`src/textual/widget.py`][widget] — `render`, `_render_content`,
  `render_line`, `render_lines`, `_get_style`.
- [`src/textual/driver.py`][driver], [`drivers/web_driver.py`][webdriver],
  [`drivers/headless_driver.py`][headless] — the `Driver` ABC and two targets.
- [`src/textual/app.py`][app] — `_display`, `export_screenshot`, `_filters`.
- [`src/textual/filter.py`][filter], [`src/textual/_styles_cache.py`][stylescache]
  — `LineFilter` and where it is applied.
- [`src/textual/scrollbar.py`][scrollbarpy] — `render_bar`, the block-glyph
  ladders, `validate_position`.
- [`src/textual/canvas.py`][canvas], [`src/textual/_box_drawing.py`][boxdrawing]
  — the `Quad` accumulator and `BOX_CHARACTERS`.
- [`src/textual/content.py`][content], [`src/textual/style.py`][style] — late
  style resolution; `Style._meta`.
- [`src/textual/_cells.py`][cells], [`rich/cells.py`][richcells] — measurement.
- [`rich/segment.py`][richsegment], [`rich/console.py`][richconsole] — `Segment`
  and `Console.export_svg`.
- [`docs/guide/widgets.md`][guide] — the Line API guide.
- [`tests/snapshot_tests/__snapshots__/test_snapshots/`][snapshots] — 448 SVG
  goldens.

Textual is pinned by `git rev-parse HEAD` on a local clone at
`06dbeef4bb70fb718236aa418ed658ef4667a126`; `rich` is pinned at
`9d8f9a372cc5916fd4781fec207ced7ddac2f08f`, resolved via the GitHub API, because
Textual depends on `rich >= 14.2.0` by version range rather than by revision.

<!-- References -->

[rev]: https://github.com/Textualize/textual/tree/06dbeef4bb70fb718236aa418ed658ef4667a126
[repo]: https://github.com/Textualize/textual
[docs]: https://textual.textualize.io/
[license]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/LICENSE
[strip]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/strip.py
[compositor]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/_compositor.py
[visual]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/visual.py
[widget]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/widget.py
[driver]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/driver.py
[webdriver]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/drivers/web_driver.py
[headless]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/drivers/headless_driver.py
[app]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/app.py
[filter]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/filter.py
[stylescache]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/_styles_cache.py
[scrollbarpy]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/scrollbar.py
[canvas]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/canvas.py
[boxdrawing]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/_box_drawing.py
[content]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/content.py
[style]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/style.py
[cells]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/_cells.py
[guide]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/docs/guide/widgets.md
[snapshots]: https://github.com/Textualize/textual/tree/06dbeef4bb70fb718236aa418ed658ef4667a126/tests/snapshot_tests/__snapshots__/test_snapshots
[richsegment]: https://github.com/Textualize/rich/blob/9d8f9a372cc5916fd4781fec207ced7ddac2f08f/rich/segment.py
[richcells]: https://github.com/Textualize/rich/blob/9d8f9a372cc5916fd4781fec207ced7ddac2f08f/rich/cells.py
[richconsole]: https://github.com/Textualize/rich/blob/9d8f9a372cc5916fd4781fec207ced7ddac2f08f/rich/console.py
[friction]: ../../specs/ui-skia/canvas-seam-friction.md
