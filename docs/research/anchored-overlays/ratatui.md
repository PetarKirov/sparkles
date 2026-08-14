# Ratatui — `Clear` + manual rects (Rust, terminal cell grid)

Ratatui ships no anchored-overlay primitive at all: what it offers is a ten-line
widget that destroys a rectangle of cells, a `Rect` value type with `clamp` and
`intersection`, and the immediate-mode rule that a later `render_widget` call
overwrites an earlier one — which makes it this catalog's control group for what an
ecosystem does when the primitive is missing.

| Field             | Value                                                                                              |
| ----------------- | -------------------------------------------------------------------------------------------------- |
| Language          | Rust (`no_std` + `alloc` capable in `ratatui-core`)                                                |
| License           | MIT                                                                                                |
| Repository        | [ratatui/ratatui][repo]                                                                            |
| Documentation     | [ratatui.rs][docs] — plus the in-tree [`ARCHITECTURE.md`][src-architecture]                        |
| Category          | Terminal / cell grid                                                                               |
| Surface model     | In-canvas — one `Buffer`, one flat `Vec<Cell>`, no OS popup, no z-index, no layer                  |
| **Revision read** | [`a2ca2df5688772baffb743b494761f4ec82b3174`][repo-pin] (post-`0.30.2` workspace, dated 2026-07-20) |

> [!NOTE]
> This page is a source reading. Nothing was built or executed — the clone is
> read-only and `cargo` would have written to `target/` — so every behavioural
> statement is read off source plus the repository's own committed tests. GitHub
> issues and discussions were not reachable from the clone, so the referenced issue
> numbers (#617, #1892) are known only as strings in commit messages: no maintainer
> statement explaining why an overlay primitive was never added exists anywhere in
> the tree, and its absence is reported here as an absence, not paraphrased.

---

## Overview

### What it solves

Ratatui solves rendering a terminal application as a total function from application
state to a grid of cells, re-executed every frame and shipped to the terminal as a
cell diff. It does not solve overlays. The words `tooltip`, `dropdown`, `combobox`,
`context menu`, `modal`, `dialog`, `z-order` and `stacking` do not name anything in
its source; the nearest thing to an acknowledgement is a doc comment at the top of
the popup example pointing readers at two third-party crates,
`https://github.com/joshka/tui-popup` and
`https://github.com/sephiroth74/tui-confirm-dialog`
([`examples/apps/popup/src/main.rs:2-4`][src-example-popup]).

What exists instead is exactly three things:

1. `Clear` — a widget that resets a rectangle of cells so that whatever is drawn next
   is what is seen ([`ratatui-widgets/src/clear.rs`][src-clear]).
2. `Rect` — a `Copy + Eq + Hash` value of four `u16`s with `intersection`, `union`,
   `clamp`, `inner`, `outer` and `centered`
   ([`ratatui-core/src/layout/rect.rs`][src-rect]).
3. The painter's-algorithm convention that later calls win, stated in an example
   comment rather than in API ([`examples/apps/mouse-drawing/src/main.rs:97`][src-example-mouse]).

`Clear`'s module doc gives the entire justification for the only overlay-adjacent
widget in the library, in one line:

> ```rust
> //! The [`Clear`] widget allows you to clear a certain area to allow overdrawing (e.g. for popups).
> ```
>
> — [`ratatui-widgets/src/clear.rs:1`][src-clear-doc]

"Overdrawing" is the whole model. There is no compositing, no alpha and no layer: a
cell holds one grapheme and one style, so drawing on top can only mean writing the
same array index later, and `Clear` is the explicit admission that this requires
destroying what was there.

### Design philosophy

The frame is one flat array of `Cell`s and rendering is a total function from state
to that array. Three consequences follow, and together they explain why most of this
page records absences.

**No measurement protocol.** `Widget::render(self, area: Rect, buf: &mut Buffer)`
returns `()` ([`ratatui-core/src/widgets/widget.rs:73`][src-widget-render]). A widget
can never say how big it wants to be, and can never report where it actually landed.

**No clip stack.** `Frame::render_widget` does nothing but forward the call
([`frame.rs:106-108`][src-frame-render]), and `Buffer`'s indexing panics out of
bounds ([`buffer.rs:249`][src-buffer-index]), so clipping is opt-in, per widget, as a
repeated first statement.

**No input model.** Grepping `ratatui-core/src`, `ratatui/src` and
`ratatui-widgets/src` for `MouseEvent`, `KeyEvent` or `handle_event` returns only doc
comments that import `crossterm::event`. The backend crates exist to write bytes
_out_ — `ARCHITECTURE.md`'s crate table describes each backend as a terminal backend
implementation and assigns no input responsibility
([`ARCHITECTURE.md:54-60`][src-architecture]). Input arrives from the terminal crate
straight into `main`.

The second load-bearing quote is `Clear`'s own warning, which reveals that it is not
a paint operation but a _diff_ operation:

> ```rust
> /// This widget **cannot be used to clear the terminal on the first render** as `ratatui` assumes
> /// the render area is empty. Use `Terminal::clear` instead.
> ```
>
> — [`ratatui-widgets/src/clear.rs:8-9`][src-clear-first-render]

It writes `Cell::EMPTY` into the _next_ buffer. On frame 0 the previous buffer is
already empty, so the diff emits nothing and the terminal keeps whatever was on
screen. An overlay primitive on a diffing backend is entangled with the diff, not
only with paint order — a point this catalog's
[shared vocabulary][concepts] does not otherwise force anyone to confront.

---

## How it works

### The frame loop

`terminal.draw(|frame| …)` hands the closure a `Frame` wrapping the inactive
`Buffer`; after the closure returns, `Terminal::flush` diffs the two buffers and
writes only the changed cells, then `swap_buffers` **resets** the buffer that is
about to become current ([`buffers.rs:97`][src-buffers-flush],
[`:121`][src-buffers-swap]). Every frame therefore starts from an empty grid and is
rebuilt from scratch. There is no retained scene, no damage tracking above the cell
diff, and no partial invalidation.

### The canonical popup

The whole of ratatui's popup story fits in one example. It is a `bool`, a `Rect`, a
`Clear` and a `Block`:

```rust
// examples/apps/popup/src/main.rs:54-59
if show_popup {
    let popup_block = Block::bordered().title("Popup");
    let centered_area = area.centered(Constraint::Percentage(60), Constraint::Percentage(20));
    // clears out any background in the area before rendering the popup
    frame.render_widget(Clear, centered_area);
    let paragraph = Paragraph::new("Lorem ipsum").block(popup_block);
    frame.render_widget(paragraph, centered_area);
```

The flag is toggled by an application `match` arm —
`KeyCode::Char('p') => show_popup = !show_popup` ([`:33`][src-example-popup-toggle])
— on events the library never sees. `show_popup` is threaded into the render function
as a plain parameter ([`:24`][src-example-popup-flag],
[`:41`][src-example-popup-render]), and the example's own comment says "This could be
stored in an app struct if you have more state to manage than just this flag."

### `Clear` — destructive rect reset

```rust
// ratatui-widgets/src/clear.rs:38-50
impl Widget for &Clear {
    fn render(self, area: Rect, buf: &mut Buffer) {
        let area = area.intersection(*buf.area());
        if area.is_empty() {
            return;
        }
        for x in area.left()..area.right() {
            for y in area.top()..area.bottom() {
                buf[(x, y)].reset();
            }
        }
    }
}
```

`Cell::reset` assigns `Cell::EMPTY`, which is
`{ symbol: None, fg: Color::Reset, bg: Color::Reset, modifier: empty, diff_option: None }`
([`cell.rs:77-86`][src-cell-empty], [`:248`][src-cell-reset]). Two consequences a
naive reading misses: it paints the _terminal's_ default colours, not the theme's, so
a popup over a styled backdrop punches a hole to the raw terminal palette unless the
application immediately paints a styled `Block` over the same rect (which the `demo2`
example does: `RgbSwatch` background, then `Clear`, then a themed block —
[`tabs/email.rs:73`][src-demo2-email]); and, per the doc quoted above, it is a write
into the next buffer, not an erase of the screen.

### `Rect::clamp` — the entire collision engine

```rust
// ratatui-core/src/layout/rect.rs:387-393
pub fn clamp(self, other: Self) -> Self {
    let width = self.width.min(other.width);
    let height = self.height.min(other.height);
    let x = self.x.clamp(other.x, other.right().saturating_sub(width));
    let y = self.y.clamp(other.y, other.bottom().saturating_sub(height));
    Self::new(x, y, width, height)
}
```

Six lines of integer arithmetic: a size clamp followed by a shift-to-fit. The
ordering is load-bearing — size is reduced first so that the shift bound
`right - width` is well-defined when the rect is wider than the boundary. There is no
[anchor rect][concepts], no side, no [flip][concepts], and no policy parameter,
because there is nothing to anchor to.

The doc comment immediately above it names the [shift-versus-clip][concepts]
distinction explicitly and then leaves the choice to every caller:

> ```rust
> /// This is different from [`Rect::intersection`] because it will move this `Rect` to fit inside
> /// the other `Rect`, while [`Rect::intersection`] instead would keep this `Rect`'s position and
> /// truncate its size to only that which is inside the other `Rect`.
> ```
>
> — [`ratatui-core/src/layout/rect.rs:377-379`][src-rect-clamp-doc]

A 12-case `rstest` table pins the behaviour across all eight overflow directions plus
the degenerate cases ([`rect.rs:942-957`][src-rect-clamp-tests]):

```text
inside      (20,20,10,10)   -> (20, 20, 10, 10)
up_left     ( 5, 5,10,10)   -> (10, 10, 10, 10)
up_right    (105,5,10,10)   -> (100,10, 10, 10)
down_right  (105,105,10,10) -> (100,100,10, 10)
too_wide    ( 5,20,200,10)  -> (10, 20,100, 10)
too_tall    (20, 5,10,200)  -> (20, 10, 10,100)
too_large   ( 0, 0,200,200) -> (10, 10,100,100)
                              boundary = Rect::new(10, 10, 100, 100)
```

Note `too_wide`: an over-wide rect is _shrunk_ to the boundary rather than allowed to
overhang. That is a different choice from the one sparkles' `clampOrigin` currently
makes (see [`./sparkles-baseline.md`][baseline]), and the difference is deliberate on
both sides.

---

## The analysis spine

### 1. Anchor model

**Not applicable — there is no anchor concept.** The library's entire vocabulary for
"where a thing goes" is `Rect { x, y, width, height }` of `u16`
([`rect.rs:134-143`][src-rect]) and `Position { x, y }`. An overlay is not anchored:
the application computes a final absolute `Rect` and passes it to
`Frame::render_widget`. There is no element identity, no trigger/anchor distinction,
no anchor-to-screen conversion (everything is already in absolute terminal cells), no
text-range anchor, no multi-rect anchor, no [virtual anchor][concepts].

The positive finding is about the _shape_ of the geometry rather than the anchor.
`Rect` and `Position` are `Copy + Eq + Hash + Debug + Default`
([`rect.rs:132`][src-rect]), carry no lifetimes, allocate nothing, and are already
used as a hash-map key: the layout cache is literally
`type Cache = LruCache<(Rect, Layout), (Segments, Spacers)>`
([`layout.rs:37`][src-layout-cache]). So "can the geometry a placement pass consumes
be a plain comparable value?" is answered yes by a shipped implementation — which is
what a `@nogc` D toolkit needs.

The closest thing to anchor discovery in the tree is an example: `RightAlignedSquare`
implements `Widget for &mut Self` and stores `self.last_position` during `render`, so
a later frame can hit-test against it
([`examples/apps/advanced-widget-impl/src/main.rs:203`, `:218-224`][src-example-advanced]).
Anchors, where they exist at all, are recovered by remembering where you painted last
frame — the same discipline sparkles already relies on for event routing.

**Algorithm.** None. The application-side procedure is: obtain a `Rect` by any means
(usually `frame.area().centered(…)`), render `Clear` into it, render content into it.

**Where the behavior lives.** Nowhere in the library. The type that would carry an
anchor (`Rect`) lives in `ratatui-core/src/layout/rect.rs`; everything else is
application code.

**Degradation.** Total survival, because the model is already the maximally degraded
one. With no OS window, no hover, no script, no sub-cell precision and no key
release, a `Rect` of `u16` cells is unchanged — nothing here assumes any of those
capabilities, since no anchoring is performed.

### 2. Placement model

**Partial.** Two mechanisms exist, both caller-invoked, neither anchor-aware.

`Rect::clamp(other)` ([`:387`][src-rect-clamp]) is eight-direction shift-to-fit plus
a size clamp — floating-ui's `size` and `shift` middleware with zero configuration
surface (see [`./floating-ui.md`][floating-ui]). `Rect::centered_horizontally` /
`centered_vertically` / `centered` ([`:513`][src-rect-centered-h],
[`:531`][src-rect-centered-v], [`:551`][src-rect-centered]) landed on 2025-04-28 in
[`08b08cc4`][commit-centering] ("feat(rect): centering (#1814)", whose message says it
resolves issue #617), absorbing the helper that had lived in the popup example since 2020.

The implementation of `centered_horizontally` is startling for a placement primitive:

```rust
// ratatui-core/src/layout/rect.rs:513-516
pub fn centered_horizontally(self, constraint: Constraint) -> Self {
    let [area] = self.layout(&Layout::horizontal([constraint]).flex(Flex::Center));
    area
}
```

It runs the full kasuari (Cassowary) linear-constraint solver to centre one
rectangle. `Flex::Center` is expressed to the solver as: every interior spacer equals
`spacing`; the first and last spacer each get a `GROW`-strength constraint to equal
the whole area; and `first == last` at `SPACER_SIZE_EQ` strength
([`layout.rs:1084-1093`][src-layout-flex]). Results are memoised in a 500-entry LRU
([`:218`][src-layout-cache-size]) keyed on `(Rect, Layout)`, thread-local under
`std` and behind a `critical_section` mutex on `no_std`
([`:55-57`][src-layout-nostd]), returning `Rc<[Rect]>`.

Absent entirely: sides, alignment, logical-versus-physical axes, RTL, writing modes,
preferred-placement lists, auto placement, fallback ordering, flip, push,
[viewport padding][concepts], custom boundaries beyond "pass a different `Rect`",
safe-area insets, work areas, multi-monitor, and IME or virtual-keyboard avoidance.
There is nowhere to put a soft-keyboard inset; the application subtracts it from the
`Rect` it passes.

**Algorithm.** `clamp`: `w' = min(w, o.w); h' = min(h, o.h); x' = clamp(x, o.x, o.right - w'); y' = clamp(y, o.y, o.bottom - h')`,
with saturating subtraction. `centered`: build a one-constraint `Layout` with
`Flex::Center`, solve, take the single segment; `centered` composes the horizontal
then the vertical pass ([`:551-559`][src-rect-centered]).

**Where the behavior lives.** `ratatui-core/src/layout/rect.rs` for the clamp — pure
integer arithmetic; `ratatui-core/src/layout/layout.rs` for centring — solver, LRU
cache, and the `thread_local!` / `critical_section` split.

**Degradation.** `clamp` degrades to nothing: integer-only, allocation-free, needs no
window, no hover, no script and no timers, and is assertable headlessly (the repo
asserts it as ASCII buffer art in `ratatui-core/tests/rect.rs`). `centered` does not
degrade as well: it needs a thread-local or a `critical_section` mutex, allocates an
`Rc<[Rect]>`, and drags a linear-programming solver into what is arithmetically
`(outer - inner) / 2`.

### 3. Collision and geometry engine

**Partial.** The whole engine is `Rect::intersection` ([`:322`][src-rect-intersection])
plus a convention. There is no clipping-ancestor discovery, no scroll container, no
transform or DPR, no [top layer][concepts], no resize observation, no layout-shift
tracking, no polling and no frame callbacks — because the frame _is_ the callback:
`terminal.draw(|frame| …)` re-runs the whole view function every time.

The clipping convention is the sharp finding: **there is no clip stack, and clipping
is opt-in per widget.** `Frame::render_widget` forwards without interposition
([`frame.rs:106-108`][src-frame-render]), and `Buffer`'s `Index`/`IndexMut` panic via
`index_of` ([`buffer.rs:249-255`][src-buffer-index]). So a widget must remember to
write `let area = area.intersection(buf.area);` as its first statement. Grepping for
that guard finds eight call sites:

```text
ratatui-widgets/src/clear.rs:40        ratatui-core/src/text/line.rs:720
ratatui-widgets/src/fill.rs:101        ratatui-core/src/text/span.rs:426
ratatui-widgets/src/mascot.rs:138      ratatui-core/src/text/text.rs:770
ratatui-widgets/src/block.rs:807
ratatui-widgets/src/paragraph.rs:410
```

> [!WARNING]
> `Clear` — the popup primitive — was **not** among them until
> [`b5c08315`][commit-clear-panic] ("fix(widgets): avoid panic if Clear area is
> outside of buffer (#2368)", 2026-01-30). The widget had existed since
> [`7676d3c7`][commit-clear-added] (2020-03-22). For nearly six years, the one widget
> in the library whose entire job is to make popups possible would panic the
> application if the popup rect crossed the right or bottom edge — exactly the case
> an anchored overlay hits. The fix ships two regression tests,
> `render_partially_out_of_bounds` ([`clear.rs:78`][src-clear-tests]) and
> `render_fully_out_of_bounds` ([`:87`][src-clear-tests-full]). (Scope note: the
> eight-site list above comes from grepping for that specific guard; a widget not on
> it may clip by some other means, and no per-widget audit was performed.)

Cost model: `Clear` is O(w·h) cell resets; `Fill` likewise; `Shadow` is O(w·h) over
the offset rect with a `base_area.contains` test per cell
([`shadow.rs:346-360`][src-shadow-foreach]) rather than iterating the L-shape's
sub-rects.

**Algorithm.** `intersection` is `x1 = max(a.x, b.x); y1 = max(a.y, b.y); x2 = min(a.right, b.right); y2 = min(a.bottom, b.bottom)`
with saturating subtraction for the extents — which is what makes a disjoint pair come
back as an empty rect rather than underflowing. Clipping is every widget intersecting
its own `area` against `buf.area` and early-returning on `is_empty()`.

**Where the behavior lives.** `rect.rs:322` for the arithmetic; the _policy_ lives
redundantly at the top of each widget's `render`; the panic that enforces it lives in
`buffer.rs:249`.

**Degradation.** Already fully degraded and fully assertable headlessly —
`Buffer::with_lines([…])` plus `assert_eq!` is the repository's universal test idiom,
and `Clear`'s partially- and fully-out-of-bounds cases are asserted as ASCII art with
no tty, no window and no backend. Nothing here needs hover, script, sub-cell
precision or key release. The one thing that does not generalise off a cell grid is
the assumption that a clip is free and exact: on a pixel backend it is a scissor
rect, and `intersection` in cells has to be multiplied out.

### 4. Arrow / caret geometry

**Not applicable.** No arrow, caret, beak, tail or pointer geometry exists anywhere
in the library, and no widget exposes a side or alignment datum that a styling layer
could turn into one. The absence is total, and it follows from dimension 1: there is
no "which side of the anchor am I on", because there is no anchor.

Two nearest relatives are worth recording, because they answer "what _is_ an arrow
when the smallest unit is a cell":

- **Border-corner merging.** `Block::render_sides`
  ([`block.rs:824`][src-block-render-sides]) insets the first and last cell of each
  side when merging is enabled, so a corner glyph is chosen rather than a side glyph
  being overdrawn by a corner. At cell resolution you do not draw a triangle; you
  choose a different glyph for one cell, and the hard part is deciding which glyph
  where two runs meet.
- **`Shadow`.** The only directional decoration in the tree is a fixed `Offset`,
  defaulting to `(1, 1)` ([`shadow.rs:166`][src-shadow-default-offset]) — not derived
  from placement and not mirrored near an edge. A popup shifted left by `clamp` keeps
  a shadow pointing down-right.

INFERENCE: if arrow geometry were treated as data on this substrate, it would have to
be something like `(side, cellIndexAlongThatSide, glyphId)` — three integers,
computable before paint and assertable in a recording canvas. Ratatui emits none of
it, so this is a reading of what the substrate would permit, not an observation of
what it does.

**Algorithm.** None. The nearest in-tree algorithm is the border-corner inset
described above.

**Where the behavior lives.** Nowhere. Border glyph selection is in
`ratatui-widgets/src/block.rs` plus `ratatui-core/src/symbols`; the shadow offset is
in `ratatui-widgets/src/block/shadow.rs`.

**Degradation.** Nothing to degrade. The transferable observation is that a
cell-grid arrow survives all five removals — no window, no hover, no script, no
sub-cell, no key release — precisely because it is a glyph choice for one integer
cell rather than a transform.

### 5. Trigger semantics

**Not applicable — the library has no event types.** There is no hover, no focus, no
focus-visible, no click, no press, no touch, no long-press, no context menu, no
keyboard shortcut, no pointer-type distinction, no assistive-technology trigger and
no combination logic, because there is nothing to combine. Backends write bytes out;
input comes from `crossterm` / `termion` / `termwiz` / `termina` straight into
`main`.

The canonical popup is triggered by a `bool` toggled in a `match` on a key code
([`popup/src/main.rs:30-34`][src-example-popup-toggle]). Races of the kind this
dimension usually worries about are structurally impossible: input is drained
synchronously between frames (`event::read()` blocks, then `terminal.draw` runs), so
there is exactly one totally ordered stream and one writer.

INFERENCE — and this is the strongest structural argument the subject makes: because
ratatui declined to own input, it could not own overlays. An overlay primitive is
largely trigger, dismissal and focus policy, and a library with no `Event` type has
no surface to hang any of it on. A toolkit that _does_ own an input vocabulary
(`sparkles:input` — see the [input spec][spec-input]) has already paid that entry
price.

**Algorithm.** None in-library. Application-side: blocking `event::read()`, `match`,
mutate a `bool`, and the next `terminal.draw` re-renders from scratch.

**Where the behavior lives.** Application code plus the third-party terminal crate.
Explicitly outside the library: `ARCHITECTURE.md`'s backend-crate section describes
backends as terminal backend implementations and names no input responsibility
([`:54-60`][src-architecture]).

**Degradation.** Already fully degraded; there is nothing to lose. The transferable
point is that removing hover (Android), keyboard release (the TUI) or script (static
HTML) removes _trigger_ capability, not _placement_ capability — and ratatui is
direct evidence that the two are separable, since it shipped the placement half alone
for six years. Note the precise scope of the key-release constraint on sparkles: what
a terminal cannot deliver is a _keyboard_ release edge; pointer release is a distinct
capability the terminal does serve over SGR-1006 (see [`./concepts.md`][concepts] and
[`./sparkles-baseline.md`][baseline]).

### 6. Timing

**Not applicable.** No timers, no delays, no [warm-up][concepts] or
[cool-down][concepts], no skip-delay group, no singleton provider, no maximum display
duration, no toolbar-neighbour traversal. The library holds exactly one time-adjacent
value: `Frame::count()`, a monotonically increasing frame sequence number documented
for "animation, performance tracking, or debugging"
([`frame.rs:235`][src-frame-count]). Whether to block on `event::read()` or poll with
a timeout is the application's loop.

The absence isolates what a pure immediate-mode renderer contributes to this
dimension: nothing. A delay is state that must survive between frames, so it must
live in the application's model — or in a toolkit's retained interaction state — and
never in the render pass. Ratatui's shape for caller-owned retained state is
`StatefulWidget` ([`stateful_widget.rs:124`][src-stateful]), whose `State` is owned by
the caller and passed in by `&mut`.

**Algorithm.** None implemented. Ratatui implements only the open/closed bit, as an
application `bool`.

**Where the behavior lives.** Nowhere. `Frame::count` is in
`ratatui-core/src/terminal/frame.rs`.

**Degradation.** This is the dimension where the sparkles targets diverge hardest,
and ratatui contributes exactly one useful shape to it. A static-HTML emit has no
timers at all, so any delay must collapse into whatever CSS can express; a recording
canvas has no wall clock, so timing must be driven by an injected ordinal rather than
a clock read. `Frame::count()` is the right shape for the second case — a frame
ordinal, deterministic and assertable — and is the one piece of this dimension
ratatui gets right, arguably by accident.

### 7. Interactive hover / pointer travel

**Not applicable.** No [safe polygon][concepts], no pointer bridge, no menu-aim, no
trajectory heuristic, no debounce, no nested-surface tracking, no interactive-border
tolerance. There is no pointer in the library at all (dimension 5).

What the subject does contribute is the _unit_ such an algorithm would have to be
expressed in here. `Rect` is `u16` cells; `Offset` is `i32` cells
([`offset.rs:10-16`][src-offset]); `Position + Offset` saturates into `[0, u16::MAX]`
([`position.rs:120-132`][src-position-add]). At one-cell resolution, the _corridor_
between an anchor and an overlay placed with a zero- or one-row gap contains at most
one row of cells, so within that corridor a polygon and its own bounding rectangle
select the same whole cells and the corridor contributes no discrimination. That is a
statement about the corridor only: the safe polygons actually shipped by the web and
desktop subjects extend beyond it — over the anchor's own row and across the
overlay's area — and retain whole-cell discriminating power there (see
[`./concepts.md`][concepts] and [`./react-aria.md`][react-aria]).

INFERENCE: a cell-honest substitute for the corridor portion, using only primitives
that exist here, is `bridge = trigger.union(popup)` ([`rect.rs:305`][src-rect-union])
with hover retained while `bridge.contains(pointer)` — one union and one containment
test, both O(1) integer operations with no allocation. Nothing in this tree
implements it.

**Algorithm.** None in-tree.

**Where the behavior lives.** Nowhere.

**Degradation.** Removing hover (Android) deletes this dimension outright; removing
keyboard release is irrelevant to it; removing script leaves only CSS `:hover` over a
single element, so a bridge must be a DOM ancestor of both trigger and overlay rather
than a computed region. Removing sub-cell precision — already true here — is what
flattens the corridor.

### 8. Dismissal

**Not applicable as policy — but mechanically instructive.** No Escape handling, no
outside-press, no focus-out, no application-deactivation, no scroll-dismiss, no
anchor-hidden or anchor-removed detection, no navigation or resize dismissal, no
parent/child close ordering. Dismissal is `show_popup = false`.

The interesting part is what happens to the pixels. Because every frame rebuilds the
buffer from scratch and `swap_buffers` resets the incoming buffer before it becomes
current ([`buffers.rs:121-124`][src-buffers-swap]), omitting the popup next frame
means its cells are simply re-derived from whatever the underlying widgets paint
there. `BufferDiff` ([`diff.rs:11`][src-diff]) then emits only the changed cells. So
restoration on dismissal is free and exact — but only because the content underneath
is _recomputed_, never _saved and restored_. There is no backdrop capture anywhere in
the tree.

**Algorithm.** Erase-by-omission: the next frame's buffer starts all-`Cell::EMPTY`,
the view function repaints everything that should exist, the diff yields only cells
whose symbol or style differ, the backend writes those. No overlay-specific code path
exists or is needed.

**Where the behavior lives.** `ratatui-core/src/terminal/buffers.rs` (swap and reset)
and `ratatui-core/src/buffer/diff.rs` (the diff).

**Degradation.** Survives every removal — no window, no hover, no script, no
sub-cell, no key release — and a recording canvas gets it for free, since the
assertion is "render the frame without the overlay and compare". The one target where
erase-by-omission is not automatic is static HTML, where there is no second frame:
dismissal there must be a CSS state change, so the overlay must be present in the
document and merely hidden (see [`./popover-api.md`][popover-api] for what the
platform offers).

### 9. Focus

**Not applicable.** Grepping `focus` across `ratatui-core/src` and
`ratatui-widgets/src` returns only prose uses of the English word. There is no
initial or automatic focus, no restoration, no trap, no containment, no tab order, no
nested [focus scope][concepts], no modal bit, and no pointer-versus-keyboard-opened
distinction. Widgets that carry a _selection_ — `ListState`, `TableState`,
`ScrollbarState` — own an index, not focus; no arbiter decides which widget receives
keys, because the application's `match` does.

Consequently the tooltip / popover / menu / dialog distinction does not exist here
either: all four are "a `Rect`, a `Clear` and a `Block`". `demo2` uses `Clear` for
full-tab backgrounds ([`tabs/email.rs:73`][src-demo2-email],
[`tabs/recipe.rs:119`][src-demo2-recipe]) and the popup example uses it for a centred
box — the same primitive, with no semantic difference recorded anywhere.

INFERENCE: the four surfaces differ largely in focus and dismissal policy, and
ratatui suggests that once those are factored out what remains is thin enough that
naming it a surface _kind_ buys nothing. That is an argument for a placement-plus-
layering primitive with tooltip, menu and dialog remaining distinct components on
top, rather than modes of one type — see [`./proposal.md`][proposal].

**Algorithm.** None.

**Where the behavior lives.** Nowhere in the library; in application `match` arms.

**Degradation.** Ratatui offers no evidence here, and the absence is itself the data
point: a terminal grid can express focus only as "which widget the application routes
keys to", never as a queryable tree state.

### 10. Layering and portals

**Partial — and this is the dimension where ratatui has a real answer.** There is one
surface (`Buffer`), and layering is call order. No portal, no top layer, no root
overlay, no native child window, no compositor layer, no stacking context, no
z-index, no overlay tree and no ownership model. The rule is stated only in an
example comment:

> ```rust
>         // call order is important here as later elements are drawn on top of earlier elements
> ```
>
> — [`examples/apps/mouse-drawing/src/main.rs:97`][src-example-mouse]

Because a cell has no alpha, "on top" cannot mean "blended over"; it means "wrote to
the same index later". That forces `Clear` into existence: a bordered `Block` writes
only its border and title, so without first destroying the cells the popup's interior
shows the old content through.

Essentially everything here is public API rather than implementation detail:
`Buffer`, `Cell` and `Frame::buffer_mut()` — documented as "an escape hatch for
direct buffer manipulation" ([`frame.rs:207`][src-frame-buffer-mut]) — are all
exposed, so an application can and does reach past every abstraction. There is no
private layering machinery to hide.

The only surface multiplicity in the library is `Viewport::{Fullscreen, Inline(u16), Fixed(Rect)}`
([`viewport.rs:62`][src-viewport]) — a whole-application choice made at
`Terminal::with_options`, not a per-overlay one — plus `Terminal::insert_before`
([`inline.rs:109`][src-insert-before]), which scrolls content _above_ an inline
viewport. Neither is an overlay mechanism.

**Algorithm.** Painter's algorithm over a flat `Vec<Cell>` indexed `y * width + x`,
with destructive writes and no blending. An overlay is: compute a `Rect`; `Clear` it
to `Cell::EMPTY`; render content into the same `Rect`. Restoration is by full
re-render plus cell diff on the following frame.

**Where the behavior lives.** `ratatui-core/src/buffer/buffer.rs` (the single
surface), `frame.rs:106` (the ordering), `ratatui-widgets/src/clear.rs` (the
destructive step). The rule itself lives only in documentation and an example
comment — it is a convention, not an enforced invariant.

**Degradation.** Survives all five removals; it is the maximally degraded model
already. It is also why ratatui cannot escape a clipping ancestor: with no top layer,
a popup rendered inside a widget's `render` is subject to whatever that widget's
caller does afterwards, and the only fix is to render popups last from the top-level
view function — which every ratatui application does by hand.

### 11. Modality

**Not applicable as policy — with one genuinely useful paint algorithm.** No
modal/non-modal distinction, no [light dismiss][concepts], no focus containment, no
click-through policy, no background pointer or keyboard blocking, no accessibility
modal bit. Since input never enters the library, "blocking" is meaningless: an
application makes a popup modal by branching its own key handling on the flag.

The one scrim-adjacent facility is `Shadow`'s `Dimmed` effect:

```rust
// ratatui-widgets/src/block/shadow.rs:328-336
impl CellEffect for Dimmed {
    fn apply(&self, shadow_area: Rect, base_area: Rect, buf: &mut Buffer) {
        for_each_shadow_cell(shadow_area, base_area, buf, |x, y, buf| {
            buf[(x, y)].modifier.insert(Modifier::DIM);
            if let Color::Rgb(r, g, b) = buf[(x, y)].bg {
                buf[(x, y)].bg = Color::Rgb(r / 2, g / 2, b / 2);
            } else {
                buf[(x, y)].bg = Color::Black;
            }
        });
    }
}
```

This is an alpha-free scrim: read the destination cell, transform it, write it back —
and it is the one place in this tree where a paint operation reads what was already
there. Note the honest fallback: indexed and named colours cannot be halved, so they
collapse to `Color::Black`. A sparkles scrim on a 16-colour terminal faces exactly
this fork.

`Shadow` is applied only outside the base rect (`if base_area.contains(pos) { continue }`,
[`shadow.rs:308-310`][src-shadow-render] and [`:346-360`][src-shadow-foreach]), so it
never dims the popup itself. That is small but load-bearing if the L-shape is
generalised to a full-screen scrim, where the correct shape is `scrimArea` minus
`popupArea` as two-to-four sub-rects rather than a per-cell containment test.

**Algorithm.** For each cell in `shadow_area \ base_area`: set `Modifier::DIM`; if
`bg` is `Color::Rgb(r, g, b)` write `Rgb(r/2, g/2, b/2)`, else `Color::Black`. Cost
O(w·h) with one `Rect::contains` per cell.

**Where the behavior lives.** `ratatui-widgets/src/block/shadow.rs` — a widget-level
effect, not a framework concept, reached via `Block::shadow(…)`
([`block.rs:731`][src-block-shadow]).

**Degradation.** A read-modify-write scrim survives on any backend that can read back
its own destination cells, which the cell backends can and a GPU overlay pass
generally cannot (there, a scrim is an alpha quad instead). Static HTML expresses a
scrim as a positioned element with an `rgba` background and needs no read-back at
all. This is a dimension where three targets genuinely need three implementations of
one declared intent — and on sparkles' cell canvases specifically, background-only
blending leaves the foreground glyph at full brightness, which is a known parity gap
recorded in [`./sparkles-baseline.md`][baseline].

### 12. Adaptive presentation

**Not applicable.** No compact-size sheet promotion, no hover-to-long-press
substitution, no teaching tips, no keyboard-driven relocation. The library has one
presentation switch and it is application-wide and chosen at construction:
`Viewport::{Fullscreen, Inline(n), Fixed(Rect)}` ([`viewport.rs:62-118`][src-viewport]).
`Inline` anchors the UI at column 0 of the current cursor row and reserves _n_ rows;
`Fixed` renders into an arbitrary `Rect` in terminal coordinates and, as its own doc
says, "Ratatui does not keep this rectangle synchronized with backend resizes unless
you call `Terminal::resize` yourself" ([`:111-112`][src-viewport-fixed]).

The decision layer is the application, at `Terminal::with_options`, before any
rendering exists. There is no runtime adaptation and no capability query — the
library does not report whether the terminal supports mouse reporting; that is the
terminal crate's business.

INFERENCE worth carrying: `Viewport::Fixed` is the one place ratatui admits the
surface origin may be non-zero — `Frame::area()` ([`frame.rs:68`][src-frame-area])
returns the rect as-is, offset included — which means any placement arithmetic that
assumed origin `(0, 0)` is wrong under it. A primitive that takes a _boundary rect_
rather than a _size_ gets this right by construction, which both `Rect::clamp(other)`
and `Rect::centered` already do.

**Algorithm.** None.

**Where the behavior lives.** `ratatui-core/src/terminal/viewport.rs`, selected via
`Terminal::with_options`.

**Degradation.** Not exercised in-tree. The Android soft-keyboard inset that sparkles
needs as an input to placement maps cleanly onto ratatui's boundary-rect convention:
shrink the boundary `Rect` before calling `clamp`. Ratatui never _discovers_ a
boundary; it is always passed one.

### 13. Accessibility

**Not applicable — zero surface.** Grepping the tree (excluding `target/`) for
`accessib`, `screen reader`, `a11y` and `aria` returns no source hits, only
incidental substring matches in unrelated prose. No roles, no descriptions, no live
regions, no assistive-technology tree, no UI Automation / AT-SPI / VoiceOver /
TalkBack bridge, no WCAG consideration, no hover-only hazard mitigation.

Stated precisely for a cell grid: what this substrate emits is a stream of styled
characters at positions, and a screen reader attached to a terminal reads the
_screen_, not a widget tree. The only accessibility affordances a TUI overlay has are
that its text is written into cells in reading order and at a position a reader will
reach. `Clear`'s destructiveness helps here — because the popup's cells replace
rather than overlay, there is no hidden text underneath to be double-read.

The one channel beyond cells that this tree does expose is escape-sequence metadata:
the `hyperlink` example writes OSC 8 links into cell symbols
([`examples/apps/hyperlink/src/main.rs`][src-example-hyperlink]), and
`CellDiffOption::Skip` exists so the diff will not clobber cells owned by such a
sequence ([`cell.rs:12-31`][src-cell-diff-option]).

**Algorithm.** None.

**Where the behavior lives.** Nowhere.

**Degradation.** Every cell target degrades to the same floor. INFERENCE: static HTML
is the one sparkles backend where real semantics are cheap and expected, so a
primitive should carry a semantic tag as _data_ even though the cell and GPU backends
will drop it — otherwise the HTML emitter cannot recover it. Ratatui offers no
counter-evidence, only the demonstration that a cell backend needs nothing.
Compare [`./aria-apg.md`][apg] for what that tag would have to say.

### 14. Animation

**Not applicable — and the reason matters.** No animation system, no
[transform origin][concepts], no enter/exit transitions, no reposition during
animation, no springs, no reduced-motion handling, no arrow animation. Critically,
**no geometry metadata is emitted for a styling layer to consume**:
`Widget::render(self, area, buf)` returns `()` ([`widget.rs:73`][src-widget-render]),
the render pass produces cells and nothing else. There is no display list, no
side-or-align datum, and no "where did this actually end up" report. An application
that needs to know where a widget landed must store it itself during render, which is
what `advanced-widget-impl` demonstrates
([`main.rs:218-224`][src-example-advanced]).

The only animation affordance is `Frame::count()` ([`frame.rs:235`][src-frame-count])
plus the fact that a full re-render every frame makes animation trivially expressible
as "compute a different `Rect` this frame".

This is the sharpest contrast with the DOM overlay engines in this catalog, which
exist in part to publish `data-side` / `data-align` / `--transform-origin` so that
CSS can animate correctly (see [`./radix.md`][radix]). Ratatui publishes nothing,
because it has no consumer for it.

**Algorithm.** None. Application-side: `frame.count()` → a parameter → a `Rect` →
render.

**Where the behavior lives.** `ratatui-core/src/terminal/frame.rs:235`.

**Degradation.** Static HTML without script cannot animate on placement data it never
received; a recording canvas needs every frame to be a deterministic function of an
injected ordinal, which `Frame::count` is. INFERENCE for sparkles: because
`buildDisplayList()` is a real, inspectable stage — unlike ratatui's straight-to-cells
`render` — sparkles _can_ emit resolved placement (chosen side, applied shift, final
size) as data, which is the thing ratatui structurally cannot do.

### 15. State architecture

**Partial, and directly portable.** Two patterns, both value-semantic.

**Ad-hoc application state.** The canonical popup is `let mut show_popup = false;` in
`main`, threaded into the render function as a parameter
([`popup/src/main.rs:24`][src-example-popup-flag],
[`:41`][src-example-popup-render]). No reducer, no state machine, no controller, no
controlled/uncontrolled distinction — the popup _is_ a `bool` plus a `Rect` computed
on the spot.

**`StatefulWidget`.** `fn render(self, area, buf, state: &mut Self::State)`
([`stateful_widget.rs:124`][src-stateful]): the widget is a transient value
describing configuration, the state is a caller-owned struct passed by `&mut`
(`ListState`, `TableState`, `ScrollbarState`). This is the pattern that survives
translation: state is plain data owned by the caller, the widget is a temporary, and
rendering is the only place the two meet. `advanced-widget-impl` shows a third
variant — `impl Widget for &mut T`, where the widget stores its own render-time
results explicitly for later hit-testing.

Would it survive a non-DOM, `@nogc`, value-semantics toolkit? It already essentially
is one. `ratatui-core` is `no_std` + `alloc`, with a `critical_section`-guarded static
for its one piece of global state ([`layout.rs:55-57`][src-layout-nostd]);
`Rect`/`Position`/`Offset`/`Size`/`Style`/`Cell` are `Copy` or cheap plain data; and
the only allocation in the geometry path is the `Rc<[Rect]>` from `Layout::split` and
its cache — both of which exist because of the Cassowary solver, not because of the
model.

**Algorithm.** Immediate mode with caller-owned state: `view(&state) -> Buffer` every
frame; interaction mutates `state` between frames; nothing is retained across frames
except the previous `Buffer` (for diffing) and the layout LRU (for speed).

**Where the behavior lives.** `ratatui-core/src/widgets/stateful_widget.rs` (the
trait), application structs (the state), `ratatui-core/src/terminal/buffers.rs` (the
only framework-retained state).

**Degradation.** Survives every removal, and the recording-canvas requirement is met
natively: the repository's widget test idiom is "render into a `Buffer`, `assert_eq!`
against `Buffer::with_lines([…])`" — ASCII art as the golden — with no terminal, no
tty and no window ([`clear.rs:60-93`][src-clear-tests]). That test idiom is the single
most transferable practice in this subject.

### 16. Shared infrastructure

**Not applicable — there are no overlay components to share anything.**
`ratatui-widgets` ships `Block`, `Paragraph`, `List`, `Table`, `Tabs`, `Gauge`,
`LineGauge`, `Chart`, `BarChart`, `Sparkline`, `Scrollbar`, `Calendar`, `Canvas`,
`Clear`, `Fill`, `Logo` and `Mascot` — and none of `Tooltip`, `Popover`, `HoverCard`,
`Menu`, `ContextMenu`, `Select`, `Combobox`, `DatePicker`, `ColorPicker`,
`TeachingTip` or `Toast`. The only acknowledgement is the popup example's doc comment
naming two community crates ([`popup/src/main.rs:2-4`][src-example-popup]); neither
crate was examined, so whether either implements anchoring, flip or dismissal is
unknown here.

What the library _did_ factor out over roughly five years is instructive about what
can belong in one primitive when the input model is missing:

| Date       | Commit                           | What landed                                                                                       |
| ---------- | -------------------------------- | ------------------------------------------------------------------------------------------------- |
| 2020-03-22 | [`7676d3c7`][commit-clear-added] | `Clear` plus `examples/popup.rs`, carrying a hand-rolled `centered_rect(percent_x, percent_y, r)` |
| ~2024      | (`#904` era)                     | The example's helper is rewritten around `Flex::Center`                                           |
| 2025-04-28 | [`08b08cc4`][commit-centering]   | `Rect::centered_horizontally` / `centered_vertically` / `centered` land in `ratatui-core`         |
| 2026-01-30 | [`b5c08315`][commit-clear-panic] | `Clear` stops panicking when its rect leaves the buffer                                           |
| 2026-04-15 | [`74d6a846`][commit-shadow]      | `Block::shadow` plus `Shadow` / `CellEffect` / `Dimmed`                                           |

Two things were extracted — centring and a drop shadow — and both are pure geometry
and paint. Nothing about triggering, timing, dismissal, focus or layering was ever
extracted. INFERENCE: none of it could be, because each needs an input model the
library does not have.

The 2020 helper is worth one more line of detail, since it is the artefact the later
API replaced: it split the area vertically into
`[Percentage((100 - py) / 2), Percentage(py), Percentage((100 - py) / 2)]`, took index
1, and split that horizontally the same way — three constraints per axis with
integer-percentage rounding, so the middle band absorbs the rounding error and the
result is not exactly centred for odd remainders. Its final resting place — a method
on the geometry _value type_, not a widget and not a component — is the interesting
part.

**Algorithm.** None; the observed mechanism for reducing duplication is "helper in an
example, promoted to a method on the geometry type".

**Where the behavior lives.** `ratatui-core/src/layout/rect.rs` absorbed the
geometry; `clear.rs` and `block/shadow.rs` hold the paint; everything else is in
third-party crates outside this repository.

---

## Strengths

- The geometry type is exactly the right shape: `Rect` is
  `Copy + Eq + Hash + Debug + Default` over four `u16`s, with no lifetimes,
  saturating arithmetic throughout, and it is proven as a hash-map key by the layout
  LRU. That is the value-semantics, `@nogc`-friendly shape a D toolkit wants.
- `Rect::clamp` is a complete shift-to-fit with size clamping in six lines, pinned by
  a 12-case table covering all eight overflow directions plus too-wide, too-tall and
  too-large.
- The library names the shift-versus-clip distinction explicitly in `clamp`'s doc,
  contrasting it with `intersection` — the single most consequential placement choice,
  spelled out where a caller will read it.
- Everything is assertable headlessly: render into a `Buffer` and `assert_eq!`
  against `Buffer::with_lines([…])`. `Clear`'s out-of-bounds behaviour, `Shadow`'s
  effects and `Rect`'s arithmetic are all asserted as ASCII art with no tty and no
  backend.
- Layering is one rule with no exceptions — one surface, later wins — which is the
  model sparkles is committed to, here validated at ecosystem scale.
- The cell diff handles the wide-grapheme overdraw hazard, with forced trailing-cell
  repair and a distinct softer rule for VS16 emoji whose trailing column is visually
  covered.
- `Shadow` / `Dimmed` shows that a drop shadow and a scrim are expressible on a cell
  grid, via a caller-supplied shade glyph or in-place RGB halving with a documented
  fallback to black for non-RGB colours.
- `CellDiffOption::{Skip, AlwaysUpdate, ForcedWidth}` is a thoughtful seam for cells
  owned by an external renderer — image protocols, OSC 8 hyperlink runs.
- `ratatui-core` is `no_std` + `alloc` capable, with a `critical_section`-guarded
  static for its one piece of global state: evidence that the model survives an
  allocation-conscious environment.

## Weaknesses

- There is no overlay primitive, and the consequence is visible in the repository's
  own history: the `centered_rect` helper lived in an example from 2020 until it was
  absorbed into `Rect` in April 2025.
- `Clear`, the one widget whose purpose is popups, panicked the application if its
  rect crossed the right or bottom edge, from March 2020 until January 2026 — six
  years of the primitive being unusable in exactly the case that needs one.
- No measurement protocol. `Widget::render` returns `()`, so a widget can never
  report a desired size or a final geometry, and there is no way to size a tooltip to
  its content. Every popup extent in the examples is a percentage or a magic number.
- No clip stack: clipping is opt-in per widget via a repeated
  `area.intersection(buf.area)`, enforced only by a panic.
- No input model at all, so triggering, timing, interactive hover, dismissal, focus
  and modality are absent — and, as designed, unimplementable inside the library.
- Zero accessibility surface: no roles, no descriptions, no bridge, nothing.
- No resolved-geometry metadata is emitted anywhere, so a styling or animation layer
  has nothing to key on — no side, no alignment, no applied shift, no transform
  origin.
- `Rect::centered` routes a two-subtraction problem through a linear-constraint
  solver, an LRU cache and an `Rc` allocation.
- `Clear` resets to `Color::Reset` rather than any theme colour, so a popup over a
  styled backdrop shows the raw terminal default unless the application paints a
  styled `Block` immediately after. The documentation never says this.
- INFERENCE from reading the code, not reproduced by running it: `Block::render`
  clips `area` to `buf.area` ([`block.rs:807`][src-block-render]) _before_ calling
  `render_shadow(area, buf)` ([`:813`][src-block-render]), so a partially off-screen
  block appears to cast its shadow from the clipped edge rather than its true edge.
  No committed test covers a partially off-screen shadowed block.

---

## Key design decisions and trade-offs

| Decision                                                                                                                       | Rationale                                                                                                                                                                                                                                                                            | Trade-off                                                                                                                                                                                                                                                                                                                                                                                 |
| ------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Ship `Clear` — destroy the cells — instead of a z-ordered layer or an alpha channel.                                           | A cell holds one grapheme and one style; there is no alpha and no compositor, so "draw on top" can only mean "write the same array index later". `Clear` makes that honest in about ten lines, and its module doc says so in the first line.                                         | The application becomes responsible for _when_ to clear, _what rect_, and _what colour results_. `Clear` writes `Color::Reset`, so a popup over a themed backdrop reverts to the terminal default unless a styled `Block` follows — a silent visual bug. No widget can ever be composited semi-transparently, and overlays must be rendered last, from the top-level view, by convention. |
| Own no input model — no `Event` type, no focus, no hit testing — and let the terminal crate deliver events straight to `main`. | Keeps `ratatui-core` `no_std`-capable and backend-agnostic, and avoids picking a winner among `crossterm` / `termion` / `termwiz` / `termina`.                                                                                                                                       | INFERENCE: this is what made an overlay primitive unreachable. Spine dimensions 5–9 and 11–13 are input and semantics policy, and a library with no `Event` type has nowhere to put them. In roughly six years the only overlay-adjacent extractions were centring and a drop shadow — both pure geometry and paint.                                                                      |
| Clip per widget rather than in `Frame::render_widget` or a clip stack, and let `Buffer` indexing panic out of bounds.          | Preserves the escape hatch (`Frame::buffer_mut`, direct `buf[(x, y)]` writes) and keeps `Widget::render` a zero-overhead trait method with no framework interposition; a panic on out-of-bounds is the usual Rust bounds contract.                                                   | Eight copies of the same guard line across the widget set, and any widget that forgets it crashes rather than clipping. `Clear` forgot for nearly six years, so drawing a popup that touched the screen edge panicked the application — with no owner for "a surface near an edge", nobody clamped.                                                                                       |
| Implement centring by running the Cassowary solver (`Flex::Center`) behind a 500-entry LRU rather than as arithmetic.          | The solver was already present for the general layout engine; expressing centring as a one-constraint layout reuses tested code and keeps `Flex` semantics uniform across all placement in the library.                                                                              | An LP solve, a `Layout` hash, an LRU probe and an `Rc<[Rect]>` allocation to compute `(outer - inner) / 2`; on `no_std` it drags in a `critical_section` mutex around a static cache. For a placement primitive that runs per overlay per frame, this is the wrong cost curve — copy the API shape, not the machinery.                                                                    |
| Restore what is under a dismissed overlay by re-rendering the whole frame and cell-diffing, never by saving a backdrop.        | The renderer is already a total function from state to buffer, and `swap_buffers` clears the incoming buffer, so omitting a widget next frame suffices. The diff then emits only changed cells, so the wire cost of dismissal is proportional to the overlay's area, not the screen. | It works only because everything is recomputed every frame, which forecloses partial invalidation and makes any per-frame cost (such as `Rect::centered`'s solver) unconditional. It also does not fully solve erasure: the diff needed dedicated wide-grapheme trailing-cell logic, because narrower content over a double-width glyph leaves half a stale glyph on screen.              |
| Add a drop shadow (2026) as an L-shaped, read-modify-write decoration outside the block's own rect.                            | Popups look flat without one, and a cell grid can express depth with a shade glyph or by dimming the existing background in place — `Dimmed` halves each RGB channel of whatever was already there.                                                                                  | It is the only paint operation in the tree that _reads_ its destination, so it is unimplementable on backends that cannot sample their own target mid-frame. The shadow lands outside the `Clear`ed rect by design, so shadow and popup are two geometries the application must reason about — and see the pre-clipped-geometry inference under Weaknesses.                               |

---

## Implication for a sparkles primitive

Ratatui is the control group, and it argues from both directions.

**What it confirms.** The constraints sparkles accepts as costs are the constraints
ratatui chose on purpose and shipped at scale: one surface, no top layer,
later-in-the-list wins, integer cells, hit data recovered from the last painted
frame. `Rect` settles the value-semantics question — `Copy + Eq + Hash`, `u16`
fields, mostly `const fn`, usable as a hash key — and `Rect::clamp` is a complete
boundary-relative placement step in six lines, with a 12-case test matrix worth
copying verbatim.

**What it warns against.** Ratatui shipped `Clear` and `Rect` and then declined to
ship anything else, and the bill arrived twice in its own history: a placement helper
that lived in an example for five years before becoming a method, and a popup widget
that panicked on any rect touching the screen edge for nearly six. Sparkles is at the
same fork today with three independent `clampOrigin` call sites, one of them in
pixels rather than cells — see [`./sparkles-baseline.md`][baseline]. Three copies is
the right moment to extract.

**Three concrete cautions.** Do not route placement through a constraint solver;
placement runs per overlay per frame and must be integer arithmetic. Check that the
cell-diff layer force-repaints the trailing column when narrower content replaces a
double-width grapheme — ratatui needed dedicated `TrailingState { force }` logic plus
a softer VS16 rule for exactly this, and every overlay border landing mid-CJK hits it
([`diff.rs:29-47`][src-diff-trailing]). And fill the cleared rect with a theme slot's
background rather than a reset sentinel, or every overlay over a themed backdrop
punches a hole to the terminal default.

The encouraging finding is `Shadow` / `Dimmed`: "drop shadow dropped on the TUI" is a
choice, not a constraint. At cell resolution a shadow is a one-cell L of shade
glyphs, or a read-modify-write halving of the destination background — and a
recording canvas can assert all of it as ASCII art, which is exactly how ratatui
tests it.

---

## Sources

- Primary source, read at [`a2ca2df5688772baffb743b494761f4ec82b3174`][repo-pin]:
  - [`ratatui-widgets/src/clear.rs`][src-clear] — the whole overlay story: the module
    doc, the first-render warning, the clip guard, and the out-of-bounds regression
    tests.
  - [`ratatui-core/src/layout/rect.rs`][src-rect] — `Rect`, `intersection`, `union`,
    `clamp` and its 12-case table, `centered*`.
  - [`ratatui-core/src/layout/layout.rs`][src-layout-cache] — the Cassowary layout
    engine, `Flex::Center`'s constraints, and the LRU cache keyed on `(Rect, Layout)`.
  - [`ratatui-core/src/buffer/buffer.rs`][src-buffer-index],
    [`cell.rs`][src-cell-empty], [`diff.rs`][src-diff] — the single surface, the
    empty cell, `CellDiffOption`, and the wide-grapheme trailing-cell repair.
  - [`ratatui-core/src/terminal/frame.rs`][src-frame-render],
    [`buffers.rs`][src-buffers-flush], [`viewport.rs`][src-viewport],
    [`inline.rs`][src-insert-before] — render ordering, the buffer swap and flush, the
    viewport modes.
  - [`ratatui-widgets/src/block.rs`][src-block-render] and
    [`block/shadow.rs`][src-shadow-render] — the clip guard, border-side rendering,
    and the `Shadow` / `Dimmed` decoration.
  - [`ratatui-core/src/widgets/widget.rs`][src-widget-render] and
    [`stateful_widget.rs`][src-stateful] — the two render contracts.
  - Examples: [`popup`][src-example-popup], [`mouse-drawing`][src-example-mouse],
    [`advanced-widget-impl`][src-example-advanced],
    [`hyperlink`][src-example-hyperlink], and `demo2`'s
    [`email`][src-demo2-email] / [`recipe`][src-demo2-recipe] tabs.
  - [`ARCHITECTURE.md`][src-architecture] — the crate table and the backends'
    stated purpose.
  - Commits: [`7676d3c7`][commit-clear-added], [`08b08cc4`][commit-centering],
    [`b5c08315`][commit-clear-panic], [`74d6a846`][commit-shadow].
- Catalog context: the shared vocabulary in [`./concepts.md`][concepts], the umbrella
  [`./index.md`][index], the capstone [`./comparison.md`][comparison], the edge-case
  register in [`./features-people-forget.md`][forget], the proposal this feeds in
  [`./proposal.md`][proposal], and the cell-grid peers
  [`./textual.md`][textual], [`./notcurses.md`][notcurses],
  [`./neovim-floats.md`][nvim], [`./tmux-popup.md`][tmux],
  [`./turbo-vision.md`][tvision] and [`./helix.md`][helix]. For the middleware
  vocabulary `Rect::clamp` unknowingly implements, see
  [`./floating-ui.md`][floating-ui]; for what a resolved-side datum is _for_, see
  [`./radix.md`][radix] and [`./react-aria.md`][react-aria].
- Adjacent sparkles material: what the toolkit ships today in
  [`./sparkles-baseline.md`][baseline], plus the toolkit's own
  [UI spec index][spec-ui], [input spec][spec-input],
  [containers spec][spec-containers], [state-machines spec][spec-stm],
  [widgets spec][spec-widgets] and [backends spec][spec-backends]. The broader
  [ui-layout][ui-layout] and [window-system integration][wsi] research trees cover
  the layout and surface questions this page deliberately does not restate.

<!-- References -->

[repo]: https://github.com/ratatui/ratatui
[repo-pin]: https://github.com/ratatui/ratatui/tree/a2ca2df5688772baffb743b494761f4ec82b3174
[docs]: https://ratatui.rs
[src-clear]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-widgets/src/clear.rs
[src-clear-doc]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-widgets/src/clear.rs#L1
[src-clear-first-render]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-widgets/src/clear.rs#L8-L9
[src-clear-tests]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-widgets/src/clear.rs#L78
[src-clear-tests-full]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-widgets/src/clear.rs#L87
[src-rect]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-core/src/layout/rect.rs#L132
[src-rect-clamp]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-core/src/layout/rect.rs#L387
[src-rect-clamp-doc]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-core/src/layout/rect.rs#L377-L379
[src-rect-clamp-tests]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-core/src/layout/rect.rs#L942-L957
[src-rect-intersection]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-core/src/layout/rect.rs#L322
[src-rect-union]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-core/src/layout/rect.rs#L305
[src-rect-centered-h]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-core/src/layout/rect.rs#L513
[src-rect-centered-v]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-core/src/layout/rect.rs#L531
[src-rect-centered]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-core/src/layout/rect.rs#L551
[src-layout-cache]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-core/src/layout/layout.rs#L37
[src-layout-nostd]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-core/src/layout/layout.rs#L55-L57
[src-layout-cache-size]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-core/src/layout/layout.rs#L218
[src-layout-flex]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-core/src/layout/layout.rs#L1084-L1093
[src-frame-render]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-core/src/terminal/frame.rs#L106
[src-frame-buffer-mut]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-core/src/terminal/frame.rs#L207
[src-frame-count]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-core/src/terminal/frame.rs#L235
[src-frame-area]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-core/src/terminal/frame.rs#L68
[src-buffer-index]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-core/src/buffer/buffer.rs#L249
[src-cell-empty]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-core/src/buffer/cell.rs#L77
[src-cell-reset]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-core/src/buffer/cell.rs#L248
[src-cell-diff-option]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-core/src/buffer/cell.rs#L12-L31
[src-diff]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-core/src/buffer/diff.rs#L11
[src-diff-trailing]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-core/src/buffer/diff.rs#L29-L47
[src-buffers-flush]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-core/src/terminal/buffers.rs#L97
[src-buffers-swap]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-core/src/terminal/buffers.rs#L121
[src-viewport]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-core/src/terminal/viewport.rs#L62
[src-viewport-fixed]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-core/src/terminal/viewport.rs#L110-L118
[src-insert-before]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-core/src/terminal/inline.rs#L109
[src-widget-render]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-core/src/widgets/widget.rs#L73
[src-stateful]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-core/src/widgets/stateful_widget.rs#L124
[src-block-render]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-widgets/src/block.rs#L805-L815
[src-block-render-sides]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-widgets/src/block.rs#L824
[src-block-shadow]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-widgets/src/block.rs#L731
[src-shadow-render]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-widgets/src/block/shadow.rs#L302-L317
[src-shadow-default-offset]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-widgets/src/block/shadow.rs#L166
[src-shadow-foreach]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-widgets/src/block/shadow.rs#L346-L360
[src-example-popup]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/examples/apps/popup/src/main.rs#L2-L4
[src-example-popup-flag]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/examples/apps/popup/src/main.rs#L24
[src-example-popup-toggle]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/examples/apps/popup/src/main.rs#L30-L34
[src-example-popup-render]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/examples/apps/popup/src/main.rs#L41
[src-example-mouse]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/examples/apps/mouse-drawing/src/main.rs#L97
[src-example-advanced]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/examples/apps/advanced-widget-impl/src/main.rs#L218
[src-example-hyperlink]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/examples/apps/hyperlink/src/main.rs
[src-demo2-email]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/examples/apps/demo2/src/tabs/email.rs#L73
[src-demo2-recipe]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/examples/apps/demo2/src/tabs/recipe.rs#L119
[src-offset]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-core/src/layout/offset.rs#L10
[src-position-add]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-core/src/layout/position.rs#L120-L132
[src-architecture]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ARCHITECTURE.md#L54
[commit-clear-added]: https://github.com/ratatui/ratatui/commit/7676d3c7df1fcee3f11250c243c656613108a490
[commit-centering]: https://github.com/ratatui/ratatui/commit/08b08cc45b60274a48824d488127a014e083d95a
[commit-clear-panic]: https://github.com/ratatui/ratatui/commit/b5c083151818e2c46aac837004c476dd978df55b
[commit-shadow]: https://github.com/ratatui/ratatui/commit/74d6a846e1fab811fcdbcc09b09648cdca05c174
[index]: ./index.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[forget]: ./features-people-forget.md
[proposal]: ./proposal.md
[baseline]: ./sparkles-baseline.md
[textual]: ./textual.md
[notcurses]: ./notcurses.md
[nvim]: ./neovim-floats.md
[tmux]: ./tmux-popup.md
[tvision]: ./turbo-vision.md
[helix]: ./helix.md
[floating-ui]: ./floating-ui.md
[radix]: ./radix.md
[react-aria]: ./react-aria.md
[popover-api]: ./popover-api.md
[apg]: ./aria-apg.md
[ui-layout]: ../ui-layout/index.md
[wsi]: ../window-system-integration/index.md
[spec-ui]: ../../specs/ui/index.md
[spec-input]: ../../specs/ui/input.md
[spec-containers]: ../../specs/ui/containers.md
[spec-stm]: ../../specs/ui/state-machines.md
[spec-widgets]: ../../specs/ui/widgets.md
[spec-backends]: ../../specs/ui/backends.md
