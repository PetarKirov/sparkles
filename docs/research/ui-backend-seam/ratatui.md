# Ratatui — the seam is a grid, and only one of its ten methods draws

**Category:** cell-only. **Last reviewed:** August 23, 2026.
Pinned at [`a2ca2df5`][rev].

The terminal end of the range done deliberately. Ratatui's renderer seam is not
a drawing API at all: widgets write into a reified cell grid, and the
[`Backend`][backend] trait exists only to push the _difference_ between two such
grids at a terminal. Everything `canvas-seam-friction.md`'s eight entries argue
about — measurement, semantics, command shape, payload ownership — has been
answered by moving it above the seam, into the `Buffer`.

| Field                | Value                                                                                                              |
| -------------------- | ------------------------------------------------------------------------------------------------------------------ |
| **Language**         | Rust (`ratatui-core` is `#![no_std]` + `alloc` — [`lib.rs:1`][corelib])                                            |
| **License**          | MIT ([`LICENSE`][license])                                                                                         |
| **Repository**       | [`ratatui/ratatui`][repo]                                                                                          |
| **Documentation**    | [docs.rs/ratatui][docsrs], [ratatui.rs][site]                                                                      |
| **Category**         | cell-only                                                                                                          |
| **Pinned revision**  | [`a2ca2df5688772baffb743b494761f4ec82b3174`][rev]                                                                  |
| **Target range**     | character cells only — one target class, many terminal libraries                                                   |
| **Backends shipped** | `ratatui-crossterm`, `ratatui-termion`, `ratatui-termina`, `ratatui-termwiz`, plus `TestBackend` in the core crate |
| **The seam**         | `trait Backend` — 10 required methods, of which **one** carries content                                            |
| **The intermediate** | `Buffer` — a `Vec<Cell>` plus a `Rect`, not a command stream                                                       |

## Overview

### What it solves

A terminal application must turn a widget tree into the smallest possible byte
stream of cursor moves, SGR changes and printed graphemes, across four
incompatible terminal-library crates and one in-memory test target. Ratatui
splits that into two problems with a data structure between them.

### Design philosophy

Stated at the top of `Buffer` ([`buffer.rs`][buffer]):

> No widget in the library interacts directly with the terminal. Instead each of
> them is required to draw their state to an intermediate buffer. It is
> basically a grid where each cell contains a grapheme, a foreground color and a
> background color. This grid will then be used to output the appropriate escape
> sequences and characters to draw the UI as the user has defined it.

And, on the seam itself ([`backend.rs`][backend]):

> Most applications should not need to interact with the `Backend` trait
> directly as the `Terminal` struct provides a higher level interface for
> interacting with the terminal.

The seam is not a public authoring surface. It is a device driver, and the
authoring surface is the grid.

## How it works

`Widget` is the whole widget contract ([`widget.rs`][widget]):

```rust
pub trait Widget {
    fn render(self, area: Rect, buf: &mut Buffer)
    where
        Self: Sized;
}
```

A widget receives a `Rect` and a mutable grid. There is no painter, no clip
stack, no state object. Clipping _is_ the `Rect`: `Buffer::set_stringn` clamps
its remaining width to `self.area.right()`, and `Buffer::cell_mut` returns
`Option` rather than panicking outside the area ([`buffer.rs`][buffer]).

The backend seam is the other half ([`backend.rs`][backend]):

```rust
pub trait Backend {
    type Error: core::error::Error;

    fn draw<'a, I>(&mut self, content: I) -> Result<(), Self::Error>
    where
        I: Iterator<Item = (u16, u16, &'a Cell)>;

    fn hide_cursor(&mut self) -> Result<(), Self::Error>;
    fn show_cursor(&mut self) -> Result<(), Self::Error>;
    fn get_cursor_position(&mut self) -> Result<Position, Self::Error>;
    fn set_cursor_position<P: Into<Position>>(&mut self, position: P) -> Result<(), Self::Error>;
    fn clear(&mut self) -> Result<(), Self::Error>;
    fn clear_region(&mut self, clear_type: ClearType) -> Result<(), Self::Error>;
    fn size(&self) -> Result<Size, Self::Error>;
    fn window_size(&mut self) -> Result<WindowSize, Self::Error>;
    fn flush(&mut self) -> Result<(), Self::Error>;
    // + `append_lines`, defaulted to `Ok(())`; two deprecated cursor shims; and
    // + `scroll_region_up`/`_down` under `#[cfg(feature = "scrolling-regions")]`
}
```

Ten required methods; nine are terminal lifecycle. The single content method
takes an **iterator of positioned cell references**, not commands.

`Terminal` holds `buffers: [Buffer; 2]` and an index, and the render pass is
three lines of real work ([`terminal/buffers.rs`][tbuffers]):

```rust
pub fn flush(&mut self) -> Result<(), B::Error> {
    let previous_buffer = &self.buffers[1 - self.current];
    let current_buffer = &self.buffers[self.current];
    let updates = previous_buffer.diff_iter(current_buffer).inspect(/* track last pos */);
    self.backend.draw(updates)?;
    // ...
}

pub fn swap_buffers(&mut self) {
    self.buffers[1 - self.current].reset();
    self.current = 1 - self.current;
}
```

`Terminal::try_draw` is `autoresize` → build a `Frame` over the current buffer →
run the user callback → `apply_buffer_with_cursor` ([`terminal/render.rs`][render]).

A backend is then a peephole optimiser over that stream: the crossterm one keeps
`fg`/`bg`/`underline_color`/`modifier` plus `last_pos` as running registers,
emits `MoveTo` only when the cell is not horizontally adjacent to the previous
one, and emits SGR only on change ([`ratatui-crossterm/src/lib.rs`][crossterm]).

`BufferDiff` ([`buffer/diff.rs`][diff]) is a zero-allocation `Iterator` yielding
`(u16, u16, &Cell)`. Most of its complexity is not diffing but **terminal
physics**: a wide grapheme's trailing column is a cell the terminal painted but
the buffer models as blank, so shrinking a styled wide glyph must force-emit the
trailing cells or the old background lingers. Six regression tests in that file
pin that behaviour, including [issue #2585][issue2585].

## Q1 — measurement units, and who answers

Width is a **property of the string**, computed above the seam and never asked
of a backend. `Backend` has no measurement method at all.

The oracle is `trait CellWidth` ([`buffer/cell_width.rs`][cellwidth]):

```rust
pub trait CellWidth {
    fn cell_width(&self) -> u16;
}

impl CellWidth for str {
    fn cell_width(&self) -> u16 {
        if self.len() == 1 { /* ASCII fast path */ 1 }
        else {
            let width = self.width() as u16;               // unicode-width
            width.saturating_add(count_halfwidth_sound_marks(self))
        }
    }
}
```

Two details are worth taking. First, the unit is `u16` cells and nothing else —
Ratatui pays no cost for a unit it cannot use, which is exactly the trade
[Slint][slint] declines by making its length an associated type. Second,
the answer is **deliberately not** `unicode-width`'s: halfwidth katakana
dakuten/handakuten (`U+FF9E`/`U+FF9F`) are zero-width by the Unicode property
and one cell in practice, so `count_halfwidth_sound_marks` adds them back.
`unicode-width` is pinned `>=0.2.0` with a comment pointing at [issue #1271][issue1271]
([`Cargo.toml`][cargo]) — the width table is a compatibility hazard, tracked as
such.

> [!IMPORTANT]
> Ratatui carries **two** width functions and they can disagree.
> `Buffer::set_stringn` consumes width via `CellWidth::cell_width` (with the
> dakuten adjustment), while `Line::width` and `Span::width` return raw
> `UnicodeWidthStr::width` ([`text/line.rs:441`][line]) — so the layout-facing
> width of a line containing `U+FF9E` is one less than the number of cells
> writing it actually consumes. Even in a system that has exactly one unit,
> having exactly one width oracle turns out to be the harder half.

Finally, the per-cell override: `CellDiffOption::ForcedWidth(NonZeroU16)`
([`buffer/cell.rs`][cell]) lets a caller declare a width the symbol's text does
not imply, documented for escape-sequence payloads whose "computed width does
not match what is written to the screen". Measurement is a default, not a law.

## Q2 — is the contract stated in one place?

**Yes, and it is the strongest answer in the survey so far.** `Backend` is one
`trait` declaration; the required set is what has no body. There is no
`__traits(compiles)` probing, no optional-method discovery, and no capability
enum: implement the trait or you are not a backend.

Optionality is expressed three ways, each visible in the declaration:

| Mechanism                      | Example                                                             | What it means                                               |
| ------------------------------ | ------------------------------------------------------------------- | ----------------------------------------------------------- |
| **Default body**               | `append_lines` → `Ok(())`                                           | silently degrades to nothing                                |
| **Cargo feature on the trait** | `scroll_region_up` / `scroll_region_down` under `scrolling-regions` | the method set itself changes at compile time               |
| **`Self::Error`**              | any method                                                          | "this backend cannot do that" is a runtime `Err`, not a lie |

The associated `type Error` is the underrated one. Because the seam is generic
over its error type, a backend refuses rather than degrades — which is the
"refusable degrade" half of [F4][comparison],
obtained for free from the type rather than from a `NODEGRADE` flag.

The feature-gated methods are the interesting failure mode: enabling
`scrolling-regions` anywhere in the dependency graph adds two required methods
to the trait, so a third-party backend that compiled yesterday stops compiling.
A capability expressed as a cargo feature is global, not per-backend.

> [!WARNING]
> One documented capability does not match its declaration. `clear_region`'s doc
> comment says "This method is optional and may not be implemented by all
> backends. The default implementation calls `clear` if the `clear_type` is
> `ClearType::All` and returns an error otherwise" — but the declaration at
> [`backend.rs:302`][backend] has no body, so it is required. Even the survey's
> cleanest contract drifted from its own prose.

## Q3 — semantic operations, or primitives?

**Neither: the seam has no operations.** A backend is never told a scrollbar, a
border or a text input was intended, because by the time cells reach it there is
nothing left to know. `Scrollbar` is a `StatefulWidget` that resolves its own
geometry and writes strings ([`ratatui-widgets/src/scrollbar.rs:504`][scrollbarw]):

```rust
fn render(self, area: Rect, buf: &mut Buffer, state: &mut Self::State) {
    // ...
    let areas = area.columns().flat_map(Rect::rows);
    let bar_symbols = self.bar_symbols(area, state);
    for (area, bar) in areas.zip(bar_symbols) {
        if let Some((symbol, style)) = bar {
            buf.set_string(area.x, area.y, symbol, style);
        }
    }
}
```

Degradation that `sparkles:ui` puts in the backend, Ratatui puts in the
_widget's configuration_: `symbols::scrollbar::Set` is a four-field record
(`track`, `thumb`, `begin`, `end`) with named constants `VERTICAL`,
`DOUBLE_VERTICAL`, `DOUBLE_HORIZONTAL`, … ([`symbols/scrollbar.rs`][scrollbarsym]).
Choosing the glyph vocabulary is the application's decision, made once, above
everything.

This is the direct falsification of the premise behind
[friction §3][friction]: our `DrawOp` carries
eight scrollbar fields _so that each backend can re-derive the rail_. Ratatui
derives it once, in the widget, and ships cells. The reason we cannot simply
copy that is Q5 — but the eight fields are not the price of semantics, they are
the price of deferring the derivation.

Because the intermediate is a **readable** grid, widgets can also compose in a
way a command stream forbids. `MergeStrategy` ([`symbols/merge.rs`][merge])
merges box-drawing symbols against what is already in the cell:

```rust
assert_eq!(MergeStrategy::Replace.merge("│", "━"), "━");
assert_eq!(MergeStrategy::Exact.merge("│", "─"), "┼");
assert_eq!(MergeStrategy::Fuzzy.merge("┘", "╔"), "╬");
```

Two adjacent `Block`s collapse their shared border into `┼` because the second
widget can read the first widget's output. Read-back is a capability of the
grid model, not of the drawing model.

## Q4 — command shape

**There is no command.** This is the survey's cleanest alternative to `DrawOp`,
and it is not egui's sum type either: the reified thing is a **cell array**.

```rust
pub struct Buffer {
    pub area: Rect,
    pub content: Vec<Cell>,   // len == area.width * area.height
}
```

`Cell` is 5–6 live fields — `symbol: Option<CompactString>`, `fg`, `bg`, optional
`underline_color`, `modifier`, `diff_option` ([`buffer/cell.rs`][cell]) — and
every one is live for every cell. There is no tag, so there are no dead fields,
and the illegal-combination problem that `sparkles.input.events` rejects and
`DrawOp` inherits simply does not exist in this shape.

The properties `RecordingCanvas` exists to give us come along free, and better:

- **Comparable.** `Buffer` derives `PartialEq`/`Hash`; `Buffer::with_lines(["hello"])`
  builds a fixture from string literals ([`buffer.rs:92`][buffer]).
- **Diffable.** Comparison is not just possible, it is the _rendering algorithm_.
- **Compositable.** `Buffer::merge` unions two buffers' areas and overlays content.
- **Canonical for tests.** The `TestBackend` docs go out of their way to point
  past themselves ([`backend/test.rs`][testbackend]): "it is preferable to write
  unit tests for widgets directly against the buffer rather than using this
  backend."

That last line is the finding for us. Ratatui _has_ our `RecordingCanvas` — a
conforming in-memory backend used by the integration tests — and its own
documentation says the better assertion target is the intermediate, one level
up. An op stream records _what a widget did_; a grid records _what the user
sees_, and only the second is stable under a refactor that reorders drawing.

The cost is equally clear. A grid is `O(area)` whether or not anything changed,
cannot represent anything sub-cell, cannot represent overlap except by
destruction, and cannot carry a payload larger than a cell. That is not a
defect: it is what makes the model exactly the size of its target. A seam that
must also reach a GPU cannot reify a grid, which is why this answer does not
transfer wholesale.

## Q5 — sub-unit placement

Ratatui has our constraint — integer cells, no unit below one — and answers it
**entirely above the seam**, in the widget that wants the resolution.

`symbols::Marker` ([`symbols/marker.rs`][marker]) is a fidelity ladder as an
enum: `Dot`, `Block`, `Bar`, `Braille` (2×4), `HalfBlock` (1×2), `Quadrant`
(2×2), `Sextant` (2×3), `Octant` (2×4), `Custom(char)`. The `Canvas` widget maps
a marker to a `Grid` implementation whose `resolution()` is measured in dots
rather than cells ([`ratatui-widgets/src/canvas.rs`][canvasw]):

```rust
fn marker_to_grid(width: u16, height: u16, marker: Marker) -> Box<dyn Grid> {
    match marker {
        Marker::Braille  => Box::new(PatternGrid::<2, 4>::new(width, height, &BRAILLE)),
        Marker::HalfBlock => Box::new(HalfBlockGrid::new(width, height)),
        Marker::Quadrant => Box::new(PatternGrid::<2, 2>::new(width, height, &QUADRANTS)),
        Marker::Sextant  => Box::new(PatternGrid::<2, 3>::new(width, height, &SEXTANTS)),
        Marker::Octant   => Box::new(PatternGrid::<2, 4>::new(width, height, &OCTANTS)),
        // ...
    }
}
```

The sub-cell grid is resolved down to graphemes before a single `Cell` is
written, so the `Backend` never learns that a plot had 2×4 resolution.

Compare [Notcurses][notcurses], which puts the same ladder _in_ the seam as
a blitter. Ratatui and Notcurses agree on [F5][comparison]'s substance — name a
fidelity, not a position — and disagree on where it lives.
The deciding factor is visible in each design: Notcurses's blitter must be in
the seam because different _terminals_ support different blitters, so the
decision is a property of the device. Ratatui's marker is a property of the
_chart_, so it lives with the chart. `RuleEdge` is neither — it is a position,
chosen by the widget, resolved by the backend, and that split is the friction.

## Q6 — resolved or semantic styling

A `Cell` carries **one** appearance, not two. There is no `slot` beside a
`visual`; the widget resolved the style and the cell holds the result.

But the resolved vocabulary is itself deliberately unresolved at the bottom.
`Color` ([`style/color.rs`][color]) is `Reset`, the sixteen ANSI names,
`Indexed(u8)` and `Rgb(u8, u8, u8)` — so `Color::Red` is not a colour, it is a
_reference into the terminal's palette_, and the final resolution happens in the
terminal emulator, past every backend. `Color::Reset` is the same trick for "the
user's default". Ratatui pays for one style channel and still gets user-theme
re-resolution, because it inherited a vocabulary the device already speaks.

`Style` differs from `Cell`: it uses `Option<Color>` plus `add_modifier` /
`sub_modifier` so styles can be **patched** ([`style.rs:239`][style]), then
applied into the cell's non-optional fields. Partial styling is a
composition-time concept that does not survive to the seam.

This weakens the premise of our friction §6 (F6's neighbour in
[the synthesis][comparison]): carrying both `visual` and `slot` is not the only
way to serve a re-resolving backend. The alternative is a resolved vocabulary
whose leaves are _already_ symbolic — which is precisely what `Slot` would be if
`Visual` could name a palette entry instead of only an `RgbColor`.

## Q7 — payload ownership

**The grid owns everything, by value.** `Cell::symbol` is a
`Option<CompactString>` — a small-string type with inline storage, chosen so a
one-grapheme symbol never heap-allocates ([PR #601][pr601], cited in the field's
doc comment). `Buffer` is `Clone`, `Eq`, `Hash` and, under the `serde` feature,
`Serialize`/`Deserialize`. Nothing in the seam borrows from the widget that drew
it.

The only borrow in the whole pipeline is the diff iterator's `&'a Cell`, and its
lifetime is provably the buffer's: `Terminal::flush` borrows both buffers, calls
`Backend::draw`, and returns before `swap_buffers` resets anything. A backend
that wants to retain a symbol clones a `CompactString`.

This is a third answer beside F6's two (reference-count, or backend-owned
cache): **copy, because the payload is bounded**. It only works because a cell's
payload is one grapheme cluster. It is nonetheless the answer friction §7 is
looking for in the one case that matters most — `DrawOp.text` is a run of text
precisely because the toolkit chose runs over cells, and the borrow is the price
of that choice, not an independent defect.

For payloads that genuinely cannot fit in a cell — sixel/Kitty images, OSC 8
links — Ratatui does not extend the seam. It adds a **negative directive**:

```rust
pub enum CellDiffOption {
    None,
    Skip,          // "something else owns this cell; never write it"
    AlwaysUpdate,  // "another renderer may draw over this; always rewrite it"
    ForcedWidth(NonZeroU16),
}
```

`Skip` is documented for cells "covered by something from an escape sequence,
such as graphics or links"; `AlwaysUpdate` for when "another renderer may draw
over the same area, such as an external image pipeline" ([`buffer/cell.rs`][cell]).
Rather than teaching the seam about images, the seam learned to **cede
territory**. That is a genuinely transferable idea for a toolkit that will meet
the same problem.

## Q8 — extent query

**Answered three times over, at three different layers**, which is why this is
the least interesting question for Ratatui and the most instructive about
[F7][comparison].

| Layer              | Query                                  | Meaning                                     |
| ------------------ | -------------------------------------- | ------------------------------------------- |
| The device         | `Backend::size() -> Size`              | the terminal's cells                        |
| The device, richer | `Backend::window_size() -> WindowSize` | cells **and** pixels                        |
| The scene          | `Buffer::area() -> &Rect`              | the grid's own extent, always exact         |
| The viewport       | `Frame::area() -> Rect`                | "guaranteed not to change during rendering" |

The self-describing case is free: a `Buffer` _is_ its extent, because `content.len()`
must equal `area.width * area.height`. An offscreen consumer builds a buffer at
the size it wants, or uses `Buffer::with_lines`, which derives width from the
longest line and height from the count ([`buffer.rs:92`][buffer]) — the exact
"size a surface to content" operation `skia-canvas-render.d` had to hand-roll by
scanning ops.

`WindowSize` is worth a second look for the terminal↔GPU question. It reports
both units from one `TIOCGWINSZ`, with the pixel field documented as possibly
`0,0` because terminals do not have to fill it in. A seam that spans units can
carry both and mark one as best-effort; it does not have to pick.

## Strengths

- **The contract is the trait.** Ten methods, no probing, no capability enum, no
  side-channel. A backend author reads one declaration.
- **One content method.** All of "drawing" is `draw(impl Iterator<Item = (u16, u16, &Cell)>)`;
  the other nine are terminal state. Writing a fifth backend is a weekend.
- **The intermediate is a value.** Comparable, hashable, clonable, serialisable,
  mergeable, and constructible from string literals — every property a test
  harness wants, without a recorder type existing for that purpose.
- **Diffing is the render algorithm**, not an optimisation bolted on: correctness
  and minimal output are the same code path.
- **`type Error` makes refusal typed** without a negotiation protocol.
- **The seam cedes territory rather than growing.** `CellDiffOption::Skip` lets a
  foreign renderer own cells the toolkit will never touch.

## Weaknesses

- **Structurally single-target.** A `Vec<Cell>` cannot express a hairline, a
  glyph at a fractional advance, or overlapping translucent content. Nothing
  here scales to a GPU surface; the design is excellent _because_ it refused to.
- **Two width oracles.** `CellWidth::cell_width` and `UnicodeWidthStr::width`
  disagree on halfwidth dakuten, and layout uses the second while writing uses
  the first ([`text/line.rs`][line], [`buffer/cell_width.rs`][cellwidth]).
- **Terminal physics leak into the diff.** `BufferDiff` needs `TrailingState`,
  a `force` flag and a `VISIBLE_ON_BLANK` modifier set to model what terminals
  do to the trailing column of a wide glyph. The grid model is not quite the
  device model, and the gap is paid for in the diff ([`buffer/diff.rs`][diff]).
- **Feature-gated trait methods are global.** `scrolling-regions` changes the
  required method set for every backend in the graph.
- **`clear_region`'s documented default does not exist** ([`backend.rs:302`][backend]).
- **`O(area)` per frame regardless of change**, and a full second buffer of
  `Cell`s in memory.

## Key design decisions and trade-offs

| Decision                                                          | Rationale                                                                                               | Trade-off                                                                                                     |
| ----------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| Reify a **grid**, not a command stream                            | The target _is_ a grid; the intermediate can be exactly as expressive as the device, and no more        | Nothing sub-cell, nothing overlapping, nothing non-terminal is representable                                  |
| `Backend::draw` takes an **iterator of changed cells**            | Diffing is the algorithm; the backend never sees an unchanged cell                                      | The backend cannot batch by style or region — it gets cells in row order and must peephole                    |
| Widgets write cells; **no semantic ops at the seam**              | Degradation is chosen once, in widget config (`symbols::scrollbar::Set`), where the app can override it | A backend can never do better than the widget's glyph choice; no backend-specific rendering of a known widget |
| Sub-cell fidelity is a **widget option** (`Marker`)               | Resolution is a property of the chart, not of the device, for the terminals Ratatui targets             | A terminal with pixel protocols cannot upgrade a `Braille` plot; the widget already collapsed it              |
| `Cell` **owns** its symbol (`CompactString`, inline)              | Bounded payload ⇒ copying is cheap and every lifetime question disappears                               | Only viable because a payload is one grapheme; a text run or an image needs a different answer                |
| Foreign content handled by **`Skip`/`AlwaysUpdate`**, not new ops | Images and hyperlinks are other renderers' territory; the seam only has to stop overwriting it          | The toolkit has no idea what is there — no measurement, no layout participation, no z-order                   |
| Colour stays **symbolic at the leaf** (`Reset`, ANSI, `Indexed`)  | The device already resolves palettes against the user's theme; re-resolution is free                    | Toolkit-side effects (blending, contrast checks) are impossible on a named colour                             |
| `type Error` on the trait                                         | A backend refuses in its own error type instead of degrading silently                                   | Every call site is a `Result`; `Terminal`'s generic parameter propagates the error type everywhere            |
| Capability by **cargo feature** (`scrolling-regions`)             | Zero runtime cost, checked by the compiler                                                              | Global: enabling it anywhere adds required methods to every backend in the graph                              |

## Bearing on the proposal

1. **Reifying a grid is a live alternative to reifying commands — for the
   terminal half.** F2 concludes the reification is right and the fix is a sum
   type. Ratatui shows a third option F2 does not consider: reify the _result_,
   not the instructions. It yields everything `RecordingCanvas` yields, plus
   diffing and read-back composition, and it is what `sparkles:ui-tui` already
   produces one layer down. It does not scale to Skia — which sharpens the
   umbrella's [open question][openq]:
   if the terminal arm's natural seam is a grid and the GPU arm's is a command
   stream, the single-seam premise is what is under pressure, not `DrawOp`'s
   encoding.

2. **The assertion target should be the frame, not the op stream.** Ratatui ships
   a `RecordingCanvas` equivalent and its own docs recommend asserting against
   the `Buffer` instead ([`backend/test.rs`][testbackend]). An op stream is
   unstable under drawing-order refactors that leave the result identical; a
   grid is not.

3. **Friction §3's eight scrollbar fields are the cost of deferring, not of
   semantics.** Ratatui derives the rail once in the widget and configures
   degradation with a four-glyph `Set`. `scrollbarThumb` already computes the
   same geometry once ([`canvas.d`][canvas]). With F3, the resolution is: keep a
   semantic op where a backend can genuinely do better (a real box shadow),
   resolve to primitives where it cannot.

4. **Adopt a "cede territory" directive before adding an image op.**
   `CellDiffOption::Skip` / `AlwaysUpdate` solve foreign-renderer coexistence —
   sixel, Kitty graphics, OSC 8 — without the seam learning what an image is.
   `sparkles:ui` meets this with `sparkles:terminal-view` panes and image
   protocols, and it is cheaper than an op kind.

5. **`type Error` beats a capability query for refusal.** F4 asks for a refusable
   degrade; Ratatui gets it from the return type, at every call site, unforgettably.

6. **Contradicts F1's unanimity while confirming its conclusion by another
   route.** Ratatui agrees the painter must not measure, but does **not** put
   measurement behind an abstraction: `cell_width` is a free function over
   `str`, one unit, non-negotiable, with a per-cell escape hatch (`ForcedWidth`).
   For a single-unit toolkit a `TextShaper` trait is over-engineering. The
   transferable rule is narrower than F1 states: _measurement must not be a
   backend method_ — whether it must be an abstraction depends on whether the
   units genuinely differ.

7. **One unit is not one oracle.** Ratatui has exactly one unit and still ships
   two width functions that disagree on `U+FF9E`/`U+FF9F`
   ([`text/line.rs`][line] vs [`buffer/cell_width.rs`][cellwidth]). Whatever we
   do about friction §1, layout and painting must call the _same_ function —
   `cellsOf` does that accidentally today; a shaping-aware redesign must do it
   deliberately.

8. **Confirms F7 and adds the free case.** Extent is answered by the device
   (`Backend::size`, `window_size`) and by the surface (`Buffer::area`). The
   offscreen-sized-to-content case F7 leaves to "a layout query" is free when the
   intermediate is a grid, because a grid _is_ its extent.

## Sources

All paths verified to exist at [`a2ca2df5688772baffb743b494761f4ec82b3174`][rev]
via `git cat-file -e`; the local clone matches `origin/main` at that revision.

- The seam: [`ratatui-core/src/backend.rs`][backend] (the `Backend` trait, `ClearType`, `WindowSize`) and [`backend/test.rs`][testbackend] (`TestBackend`)
- The intermediate: [`buffer/buffer.rs`][buffer], [`buffer/cell.rs`][cell] (`Cell`, `CellDiffOption`), [`buffer/cell_width.rs`][cellwidth], [`buffer/diff.rs`][diff] (`BufferDiff`)
- The pipeline: [`terminal/buffers.rs`][tbuffers] (`flush`, `swap_buffers`), [`terminal/render.rs`][render], [`terminal/frame.rs`][frame], [`widgets/widget.rs`][widget]
- Vocabulary: [`symbols/marker.rs`][marker], [`symbols/merge.rs`][merge], [`symbols/scrollbar.rs`][scrollbarsym], [`style/color.rs`][color], [`style.rs`][style], [`text/line.rs`][line]
- Consumers: [`ratatui-crossterm/src/lib.rs`][crossterm], [`ratatui-widgets/src/scrollbar.rs`][scrollbarw], [`ratatui-widgets/src/canvas.rs`][canvasw]
- Context: [`ARCHITECTURE.md`][arch], [`Cargo.toml`][cargo], [`ratatui-core/src/lib.rs`][corelib], [`LICENSE`][license], [docs.rs/ratatui][docsrs], [ratatui.rs][site]

<!-- References -->

[arch]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ARCHITECTURE.md
[backend]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-core/src/backend.rs
[buffer]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-core/src/buffer/buffer.rs
[canvas]: ../../../libs/ui/src/sparkles/ui/canvas.d
[canvasw]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-widgets/src/canvas.rs
[cargo]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/Cargo.toml
[cell]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-core/src/buffer/cell.rs
[cellwidth]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-core/src/buffer/cell_width.rs
[color]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-core/src/style/color.rs
[comparison]: ./comparison.md
[corelib]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-core/src/lib.rs
[crossterm]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-crossterm/src/lib.rs
[diff]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-core/src/buffer/diff.rs
[docsrs]: https://docs.rs/ratatui/latest/ratatui/
[frame]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-core/src/terminal/frame.rs
[friction]: ../../specs/ui-skia/canvas-seam-friction.md
[issue1271]: https://github.com/ratatui/ratatui/issues/1271
[issue2585]: https://github.com/ratatui/ratatui/issues/2585
[license]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/LICENSE
[line]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-core/src/text/line.rs
[marker]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-core/src/symbols/marker.rs
[merge]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-core/src/symbols/merge.rs
[notcurses]: ./notcurses.md
[openq]: ./index.md#open-question-the-survey-may-not-settle
[pr601]: https://github.com/ratatui/ratatui/pull/601
[render]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-core/src/terminal/render.rs
[repo]: https://github.com/ratatui/ratatui
[rev]: https://github.com/ratatui/ratatui/tree/a2ca2df5688772baffb743b494761f4ec82b3174
[scrollbarsym]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-core/src/symbols/scrollbar.rs
[scrollbarw]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-widgets/src/scrollbar.rs
[site]: https://ratatui.rs/
[slint]: ./slint.md
[style]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-core/src/style.rs
[tbuffers]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-core/src/terminal/buffers.rs
[testbackend]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-core/src/backend/test.rs
[widget]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-core/src/widgets/widget.rs
