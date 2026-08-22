# libvaxis — the seam is a negotiation, and the negotiated answer rides in the cell

**Category:** cell-only with sub-cell escape hatches. **Last reviewed:** August 23, 2026.
Pinned at [`c060d314`][rev].

libvaxis has no backend type. There is exactly one target — a terminal — and the
variation between terminals, which every other cell library absorbs with a
terminfo lookup or a backend trait, is absorbed instead by a **runtime-negotiated
`Capabilities` struct** and by **per-cell escape hatches** that let a single cell
carry a pixel offset, a fractional scale factor, or an image placement. That
makes it the survey's second sub-cell datapoint after
[Notcurses](./notcurses.md), and — this is the finding — it does **not** reach
for Notcurses' fidelity ladder. It publishes the conversion factor instead.

| Field                | Value                                                                                                      |
| -------------------- | ---------------------------------------------------------------------------------------------------------- |
| **Language**         | Zig (`minimum_zig_version = "0.16.0"` — [`build.zig.zon`][zon])                                            |
| **License**          | MIT ([`LICENSE`][license], © 2023 Tim Culverhouse)                                                         |
| **Repository**       | [`rockorager/libvaxis`][repo]                                                                              |
| **Documentation**    | [rockorager.github.io/libvaxis][docs], [`README.md`][readme]                                               |
| **Category**         | cell-only with sub-cell escape hatches                                                                     |
| **Pinned revision**  | [`c060d314930c5552b99a89278a6a695baf0352da`][rev] (`version = "0.6.0"`)                                    |
| **Target range**     | terminals only — but stratified by protocol, from `wcwidth`+ASCII to Kitty graphics and OSC 66 text sizing |
| **Backends shipped** | none. One renderer, `Vaxis.render`, parameterised by a `Capabilities` value                                |
| **The low seam**     | `Screen` — a `[]Cell` grid; `Window` is a clipping view onto it                                            |
| **The high seam**    | `vxfw.Widget` — three function pointers; `draw` returns a `Surface`                                        |
| **Dependencies**     | `zigimg` (image decode), `uucode` (Unicode tables, `lazy = true`) — no libc, no terminfo, no curses        |

> [!NOTE]
> A breadth-first survey of libvaxis as a **TUI library** — event loop, widget
> catalogue, allocator discipline, Zig-to-D translation notes — already exists at
> [`docs/research/tui-libraries/libvaxis.md`](../tui-libraries/libvaxis.md). This
> page reads the same tree for one thing only: what its **renderer seam** decides,
> and what that means for [`isCanvas`][canvas]. Where the two disagree on a
> version number, this page is pinned and that one is not.

## Overview

### What it solves

A terminal application must reach modern protocol features — true colour, Kitty
graphics, the Kitty keyboard protocol, synchronized output, Unicode Core
(mode 2027), OSC 66 text sizing — on terminals that support an arbitrary subset
of them, without a static capability database that describes none of it.

### Design philosophy

Two sentences at the top of [`README.md`][readme] state the whole position:

> Libvaxis _does not use terminfo_. Support for vt features is detected through
> terminal queries.

That is a seam decision, not a portability detail. Terminfo is a **declared**
capability model consulted before drawing; a query is a **negotiated** one, whose
answer arrives asynchronously, mid-run, on the same input stream as the user's
keystrokes. Everything downstream — the width oracle, whether an image may be
sent at all, whether a grapheme is written raw or wrapped in OSC 66 — is a read
of the negotiated result.

## How it works

The reified thing is a grid of `Cell`, exactly as in [Ratatui](./ratatui.md), and
the render pass is a diff of two grids. What differs is that the two grids are
**different types**. `Screen` ([`src/Screen.zig`][screen]) is the writable one:

```zig
width: u16 = 0,
height: u16 = 0,
width_pix: u16 = 0,
height_pix: u16 = 0,
buf: []Cell = &.{},
cursor: Cursor = .{},
width_method: Method = .wcwidth,
```

`InternalScreen` ([`src/InternalScreen.zig`][internal]) is the retained one, and
its `InternalCell` replaces every borrowed slice with an arena-backed
`std.ArrayList(u8)`; `InternalScreen.writeCell` copies the grapheme, the URI and
the URI params in. See Q7.

`Window` ([`src/Window.zig`][window]) is not a painter — it is a **value**: an
offset, a size and a pointer to the screen.

```zig
x_off: i17,
y_off: i17,
/// relative horizontal offset, from parent window. This only accumulates if it is negative so that
/// we can clip the window correctly
parent_x_off: i17,
parent_y_off: i17,
width: u16,
height: u16,
screen: *Screen,
```

`Window.child` clamps the child's size into the parent and keeps only the
_negative_ part of the relative offset, so `writeCell` can reject a cell that
falls outside any ancestor with six comparisons and no clip stack. Clipping is
arithmetic on a value, not state on a painter.

`Vaxis.render` ([`src/Vaxis.zig`][vaxis]) walks the screen buffer once, skipping
any cell where `last.eql(cell)` and nothing forces a repaint, tracking `cursor:
Style` and `link: Hyperlink` as running registers and emitting SGR only on
change. The whole frame is bracketed in `ctlseqs.sync_set` / `sync_reset`
(mode 2026), and `errdefer` guarantees the reset even on a write failure.

The negotiation is the other half. `Vaxis.queryTerminalSend` writes one
concatenated batch of probes — `decrqm_sgr_pixels`, `decrqm_unicode`,
`decrqm_color_scheme`, `in_band_resize_set`, the two cursor-position tricks
described below, `xtversion`, `csi_u_query`, `kitty_graphics_query`,
`primary_device_attrs` — and `queryTerminal` then blocks on a futex until the DA1
reply arrives or the caller's timeout expires. Replies land as ordinary events in
`Loop.zig`, which sets the corresponding field:

```zig
.cap_kitty_graphics => {
    if (!vx.caps.kitty_graphics) {
        log.info("kitty graphics capability detected", .{});
        vx.caps.kitty_graphics = true;
    }
},
```

Two capabilities have no query of their own and are detected by **measuring the
terminal's own cursor**: `queryTerminalSend` homes the cursor, emits
`explicit_width_query` (`OSC 66;w=1` around a space), and asks for a cursor
position report. A terminal that honoured the width parameter has moved one
column; the reply parses as a shift-F3 keypress, and `Loop` reads that as
`caps.explicit_width = true`. The scaled-text probe is the same trick with
`s=2`, arriving as alt-F3. Capability detection here is not a lookup and not even
a protocol reply — it is an **observation of a side effect**.

## Q1 — measurement units, and who answers

The unit is one: `u16` cells, everywhere. The **oracle**, however, is
capability-dependent, and libvaxis ships three of them plus two overrides plus a
wire-level assertion. This is the richest Q1 answer in the survey and it does not
simplify into the earlier ones.

`gwidth` ([`src/gwidth.zig`][gwidth]) is a free function over a `Method`:

```zig
pub const Method = enum { unicode, wcwidth, no_zwj };
pub fn gwidth(str: []const u8, method: Method) u16
```

`.unicode` iterates real grapheme clusters and applies emoji rules — a
variation-selector-16 or an emoji-presentation codepoint forces width 2, two
regional indicators force 2, `U+FE0E` pins text presentation to 1. `.wcwidth`
walks bare codepoints. `.no_zwj` splits on `U+200D` first and sums. The library's
own tests pin the disagreement: `gwidth("👩‍🚀", …)` is **2** under `.unicode` and
**4** under both `.wcwidth` and `.no_zwj`.

The choice of method is a **capability**, not a configuration: `Capabilities`
declares `unicode: gwidth.Method = .wcwidth`, `Vaxis.resize` copies it into
`screen.width_method`, and `Loop`'s `.cap_unicode` handler flips it to `.unicode`
when the terminal answers mode 2027. `Window.gwidth(str)` is a one-line forward to
`gw.gwidth(str, self.screen.width_method)`.

Two escape hatches sit under that. First, a per-cell override, documented
verbatim in [`src/Cell.zig`][cell]:

```zig
pub const Character = struct {
    grapheme: []const u8 = " ",
    /// width should only be provided when the application is sure the terminal
    /// will measure the same width. This can be ensure by using the gwidth method
    /// included in libvaxis. If width is 0, libvaxis will measure the glyph at
    /// render time
    width: u8 = 1,
};
```

`width = 0` means _"I decline to answer; measure it for me later"_, and
`Vaxis.render` does exactly that, falling back to `@max(1, gwidth(…))`. Second,
when `caps.explicit_width` is set and the width exceeds one, the renderer stops
guessing and **tells** the terminal, via `ctlseqs.explicit_width` =
`OSC 66;w={d};{s}`. The measurement disagreement that friction §1 describes is
treated here as a _protocol_ problem with a protocol answer.

> [!IMPORTANT]
> There is also a measurement path that runs **through the painter**, which
> complicates [F1][comparison]. `Window.PrintOptions` carries a `commit` flag,
> documented "when true, print will write to the screen for rendering. When false,
> nothing is written. The return value describes the size of the wrapped text",
> and `print` returns `PrintResult { col, row, overflow }`. The library's own
> `print: grapheme` tests drive it with `.commit = false` purely to assert wrap
> geometry. Word wrapping cannot be answered by a width function alone — it needs
> the target rect — so the dry run is the honest place to put it. F1's "not the
> painter's job" holds for _advance_; it does not hold for _wrapped extent_.

At the framework level the oracle moves onto the draw context rather than either
the painter or the caller: `vxfw.DrawContext.stringWidth` ([`src/vxfw/vxfw.zig`][vxfw])
forwards to `gwidth` with a `var width_method` held on the type and initialised
once by `App` from `vx.screen.width_method`. Widgets measure; they never see the
screen.

## Q2 — is the contract stated in one place?

**Yes, and it is a value rather than a type.** The whole negotiable surface is one
struct in [`src/Vaxis.zig`][vaxis]:

```zig
pub const Capabilities = struct {
    kitty_keyboard: bool = false,
    kitty_graphics: bool = false,
    no_color: bool = false,
    rgb: bool = false,
    unicode: gwidth.Method = .wcwidth,
    sgr_pixels: bool = false,
    color_scheme_updates: bool = false,
    explicit_width: bool = false,
    scaled_text: bool = false,
    multi_cursor: bool = false,
};
```

Ten fields, every default the pessimistic one, and the field set is the contract.
This is the [Qt `PaintEngineFeature`](./qt-qpaintengine.md) model — a declared
capability set — with the declaration moved from the backend author to the
**target itself**, discovered at runtime. `sparkles:ui` has neither: `isCanvas`
names five methods, `OpKind` has eight members, and the remaining three are
discovered by `__traits(compiles)` at each call site, which is friction §2.

Three properties are worth taking separately.

**Refusal exists, but only for the expensive half.** Every image entry point
opens with `if (!self.caps.kitty_graphics) return error.NoGraphicsCapability;` —
`transmitLocalImagePath`, `transmitPreEncodedImage`, `transmitImage`, `loadImage`.
That is [F4][comparison]'s refusable degrade, obtained from the return type as in
Ratatui, without a `NODEGRADE` flag. Text fidelity gets no such treatment: the
renderer silently takes the lesser branch when `caps.explicit_width` is false, and
the caller is never told. So even here, refusal is granted where the fallback
would be expensive and withheld where it would be merely wrong — which is
precisely the asymmetry a golden test trips over.

**Negotiation has an override channel.** `enableDetectedFeatures` reads
`NO_COLOR`, `TERMUX_VERSION`, `VHS_RECORD`, `TERM_PROGRAM == "vscode"`,
`VAXIS_FORCE_LEGACY_SGR`, `VAXIS_FORCE_WCWIDTH` and `VAXIS_FORCE_UNICODE`, and
several of those _downgrade_ an already-detected capability (`VHS_RECORD` clears
`kitty_keyboard` and forces `.wcwidth`). No other subject surveyed lets an
operator pin the negotiated result. For a repository that ships golden GUI and
PTY oracles, that is the more interesting half of F4: a capability model needs a
**pin**, not only a refusal.

**Negotiation costs a blocking wait.** `queryTerminal` blocks on
`std.Io.futexWaitTimeout` until DA1 lands. A declared contract has no such
startup cost; that is what buying runtime truth costs.

## Q3 — semantic operations, or primitives?

**Neither, at either level.** The low seam has no operations at all, only
`writeCell`/`readCell`/`fill`/`print`, so a scrollbar reaches it as cells. The
whole low-level scrollbar is 33 lines ([`src/widgets/Scrollbar.zig`][scrollbar]),
and its degradation vocabulary is _one field_:

```zig
/// character to use for the scrollbar
character: vaxis.Cell.Character = .{ .grapheme = "▐", .width = 1 },
style: vaxis.Style = .{},
top: usize = 0,
total: usize,
view_size: usize,
```

The rail geometry — `bar_height`, `bar_top` — is derived once, in the widget,
from `win.height`. Compare `DrawOp`'s eight scrollbar fields, which exist so each
backend can re-derive the same rail. `sparkles:ui` pays eight fields on **every**
op, for every kind, to defer a computation that both Ratatui and libvaxis perform
once.

The framework's `ScrollBars` ([`src/vxfw/ScrollBars.zig`][scrollbars]) makes the
point sharper by going further in the same direction: it exposes **six**
configurable thumb cells — vertical and horizontal × idle, hover and drag — each
a whole `vaxis.Cell` with its own style, plus `estimated_content_height`/`_width`
for thumb sizing. Interaction state (`is_hovering_vertical_thumb`,
`is_dragging_horizontal_thumb`, `mouse_offset_into_thumb`) lives in the widget,
never in the seam. Our `expandPercent` and `barTrackLit` are that same state,
pushed down a layer.

This is the second independent falsification of the _necessity_ argument behind
friction §3 (Ratatui was the first): a cell target degrades a scrollbar perfectly
well without the drawing layer knowing what one is, because the _glyph set_ is a
widget parameter. It does not falsify [Slint](./slint.md)'s converse claim —
Slint's `draw_box_shadow` genuinely needs backend knowledge — but it does show
that a scrollbar is not that kind of operation.

## Q4 — command shape

**No commands.** As in Ratatui, the reified thing is a cell array, and `Cell` is a
tag-free product type — so the illegal-combination problem `sparkles.input.events`
rejects, and `DrawOp` inherits, cannot arise.

But libvaxis is the one cell subject where the tag-free shape still carries dead
fields, and it is instructive that it does:

```zig
char: Character = .{},
style: Style = .{},
link: Hyperlink = .{},
image: ?Image.Placement = null,
default: bool = false,
wrapped: bool = false,
scale: Scale = .{},
```

`image` is `null` for essentially every cell on screen; `scale` is the identity
for essentially every cell. They are cheap — `Scale` is a `packed struct` that
`eql` bitcasts to a `u13` — but they are the same trade `DrawOp` makes, and they
land here for the same reason: the escape hatches of Q5
have to be reachable from wherever content is expressed, and content is expressed
per cell. **Optional per-element payloads are what a sub-cell escape hatch costs,
in any shape.** The lesson for `DrawOp` is that a sum type removes the _illegal_
combinations, not the _rare_ ones.

## Q5 — sub-unit placement

The reason this subject is on the list, and the answer is **not** Notcurses'.
libvaxis never enumerates positions and never enumerates resolutions. It exposes
the **conversion factor** and defers sub-cell placement to a protocol, three
different ways.

**1. The cell's pixel size is a first-class layout input.** `Screen` carries
`width_pix`/`height_pix` from the `Winsize` ioctl beside `width`/`height`, and
`vxfw.DrawContext` hands every widget:

```zig
// Size of a single cell, in pixels
cell_size: Size,
```

computed in `App.doLayout` as `vx.screen.width_pix / vx.screen.width`. A cell
toolkit whose layout pass knows how many device pixels a cell is worth is not the
same thing as a toolkit with no unit below a cell. That is the cheapest available
answer to friction §5, and it requires no new vocabulary at all.

**2. Images place at pixel resolution inside a cell.** `Image.DrawOptions`
([`src/Image.zig`][image]) carries, with the constraint stated in the doc comment:

```zig
/// an offset into the top left cell, in pixels, with where to place the
/// origin of the image. These must be less than the pixel size of a single
/// cell
pixel_offset: ?struct { x: u16, y: u16 } = null,
z_index: ?i32 = null,
clip_region: ?struct { x: ?u16 = null, y: ?u16 = null, width: ?u16 = null, height: ?u16 = null } = null,
scale: enum { none, fill, fit, contain } = .none,
```

The placement is stored on a cell (`win.writeCell(0, 0, .{ .image = p })`) and
serialised in `render` as Kitty graphics `a=p` with `X=`/`Y=` sub-cell pixel
offsets, `x/y/w/h` clip parameters and a `z=` index. Sub-cell _and_ z-ordered,
inside a cell grid.

**3. Text can exceed and subdivide the cell.** `Cell.Scale` is the OSC 66
text-sizing protocol as a packed struct:

```zig
pub const Scale = packed struct {
    scale: u3 = 1,
    // The spec allows up to 15, but we limit to 7
    numerator: u4 = 1,
    denominator: u4 = 1,
    vertical_alignment: enum(u2) { top = 0, bottom = 1, center = 2 } = .top,
};
```

Gated on `caps.scaled_text`, `render` emits either `OSC 66;s={d}:w={d}` or the
fractional form `s:w:n:d:v`, and marks the covered cells `skip = true` in the
retained screen so the diff does not paint over the glyph. A **fraction** with a
vertical alignment is a strictly more expressive spelling of "where in the cell"
than `RuleEdge`'s six compass points, and it costs 13 bits rather than an
enumerator per new case.

Input is symmetric: `Vaxis.translateMouse` divides the SGR-pixel mouse
coordinates by the derived cell pitch and keeps the remainder as
`Mouse.xoffset`/`yoffset` ([`src/Mouse.zig`][mouse]) — sub-cell resolution on the
way in as well as on the way out, gated on `caps.sgr_pixels`.

> [!IMPORTANT]
> This is the survey's second cell-native sub-cell subject and it **does not
> generalise Notcurses' fidelity ladder** — which was the explicit hypothesis
> behind putting it on the list. Notcurses answers "how finely may I draw here?"
> with a named blitter; libvaxis answers "how many pixels is a cell?" with a
> number, and then routes anything finer through a negotiated protocol
> (Kitty graphics, OSC 66) that carries real device units. [F5][comparison]
> should be restated: the alternatives to naming positions are _at least two_ —
> name a fidelity, or publish the conversion factor and let a capability decide
> whether the fine path is available. The second requires no new toolkit
> vocabulary, which for a seam already carrying eighteen fields is the cheaper
> of the two.

## Q6 — resolved or semantic styling

**Resolved — but with one deliberate notch of deferral, and the re-resolver is
the target.** `Cell.Style` is concrete: `fg`, `bg`, `ul`, `ul_style` plus seven
SGR booleans. `Color`, however, is a sum type whose first two cases are _names_,
not values:

```zig
pub const Color = union(enum) {
    default,
    index: u8,
    rgb: [3]u8,
};
```

`.default` and `.index` are resolved by the **terminal**, against the user's
palette, after the seam. libvaxis carries a semantic role and a resolved value in
one four-byte union, and never pays for both, because the wire format already has
a vocabulary for the role.

The `no_color` capability then gates emission wholesale: every colour branch in
`render` is guarded by `if (!self.caps.no_color and …)`, so `NO_COLOR=1` produces
a frame with structure and no colour, decided at the writer rather than at
every call site.

The bearing on friction §6 is direct. `DrawOp` carries `visual` _and_ `slot`
because the HTML interpreter re-resolves into class names. libvaxis shows the
cheap version of the same hedge: make the resolved type _itself_ able to hold an
unresolved name, so the op carries one field, and let the backend that can
re-resolve read the name out of it. `Slot` is richer than a palette index, so
this does not transfer unchanged — but "one field that can be either" is a
different design point from "two fields, always both", and it is the one nobody
in the survey has paid for twice.

## Q7 — payload ownership

**Two cell types: one that borrows for the frame, one that owns across frames.**
`Cell.Character.grapheme` and `Cell.Hyperlink.uri` are `[]const u8` borrowed from
the caller — exactly `DrawOp.text`'s bargain, and exactly friction §7. What makes
it safe is that the retained screen is a _different type_:
`InternalScreen.InternalCell` holds `char`, `uri` and `uri_id` as
`std.ArrayList(u8)` allocated from an arena owned by the screen, and
`InternalScreen.writeCell` does `clearRetainingCapacity` + `appendSlice` on each.
The frame-local borrow is legal precisely because the only thing that outlives
the frame is a copy in a type that owns.

`GraphemeCache` ([`src/GraphemeCache.zig`][gcache]) plays the same role for key
text: `Loop` runs `mut_key.text = cache.put(text)` before enqueueing a key event,
because a `Key`'s text is borrowed from the parser's scratch buffer and must
survive the queue.

This is the third distinct answer to §7 in the survey, alongside reference
counting ([egui](./egui.md), Qt) and a backend-owned cache (Slint), and it is the
one that fits a `@nogc` toolkit best: it costs one extra type and one copy at the
retain boundary, needs no atomics, and makes "can this outlive the frame?" a
question the type system answers rather than a doc comment.

## Q8 — extent query

Answered at the framework level, and answered in the cheapest possible way: **the
paint call returns the extent.** `vxfw.Widget.draw` is
`fn (userdata, ctx: DrawContext) Allocator.Error!Surface`, and `Surface` opens
with its own size:

```zig
pub const Surface = struct {
    size: Size,
    widget: Widget,
    cursor: ?CursorState = null,
    /// Contents of this surface. Must be len == 0 or  len == size.width * size.height
    buffer: []vaxis.Cell,
    children: []SubSurface,
};
```

`App.render` then sizes the root window from the returned value —
`win.child(.{ .width = surface.size.width, .height = surface.size.height })` —
and `Surface.render` walks the child tree, sorting `children` by z-index and
making a child `Window` per subsurface. `Surface.trimHeight` re-slices a surface
to a smaller extent without redrawing.

So a scene here **is** self-describing about its extent, per node, and it costs
nothing extra because the number is the draw call's return value rather than a
separate query. That complicates [F7][comparison]: extent does belong to the
surface at the low level (`Screen` declares `width`/`height`/`width_pix`/
`height_pix`, as Qt's device does), but for the offscreen case F7 concedes —
sizing a surface to content — libvaxis shows the answer is not a new query on the
display list. It is **making paint return a size**, which `buildDisplayList` is
already in a position to do.

## Strengths

- **The contract is one value, and the target fills it in.** Ten fields, all
  pessimistic by default, negotiated at startup — a declared model whose
  declaration comes from the party that actually knows.
- **Sub-cell without new toolkit vocabulary.** `cell_size` in pixels, plus
  protocol-carried offsets/fractions, cover more ground than six compass points
  and add no enumerator.
- **Ownership is a type distinction, not a convention.** `Cell` borrows,
  `InternalCell` owns; the retain boundary is where the copy happens and the
  compiler knows it.
- **Refusal by return type** for the expensive capability (`error.NoGraphicsCapability`).
- **An override channel** over the negotiated result — the missing half of a
  capability model for anyone running golden tests.
- **Clipping is a value, not painter state**: `Window`'s four offsets make
  out-of-bounds a comparison, with no clip stack to push, pop or mismatch.

## Weaknesses

- **Refusal is asymmetric.** Images refuse; text fidelity degrades silently. A
  caller cannot ask for explicit width and be told no — the same gap friction §2
  records for `rule`.
- **Capability is global state.** `vxfw.DrawContext.width_method` is a `var` on
  the type, set once by `App.init`; two Vaxis instances with different terminals
  in one process share one width oracle.
- **The negotiated answer can arrive mid-frame.** Capabilities flip from the
  event loop thread while the app is drawing, so early frames may be measured by
  one oracle and later ones by another. `queryTerminal`'s futex wait exists to
  bound that, at the cost of a blocking startup.
- **Two width oracles reachable from one program** (`.unicode` vs `.wcwidth`,
  differing by 2 on a ZWJ sequence), with `Character.width` as a third,
  caller-supplied answer that the library explicitly declines to verify.
- **Detection by side effect is fragile**: the explicit-width and scaled-text
  probes are read out of a _cursor position report reinterpreted as an F3
  keypress_, which the code itself guards with a `queries_done` flag so it does
  not corrupt real F3 input.
- **No in-memory conforming target.** There is no `TestBackend` equivalent; tests
  assert against a `Screen` directly. Which is, per Ratatui, arguably the right
  assertion target anyway.

## Key design decisions and trade-offs

| Decision                                                      | Rationale                                                                                      | Trade-off                                                                                         |
| ------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| No terminfo; capabilities by runtime query                    | terminfo describes none of Kitty keyboard/graphics/OSC 66, and lies over SSH and in containers | blocking startup wait; capabilities mutate mid-run; two probes read as reinterpreted keypresses   |
| `Capabilities` as one struct with pessimistic defaults        | the negotiable surface is legible in one place                                                 | every renderer branch reads it — capability checks are scattered through `render` by construction |
| Width method is a capability, not a constant                  | mode 2027 changes what the terminal will do with a ZWJ sequence                                | two oracles disagree by 2 on real strings; a third (`Character.width`) is unverified              |
| Sub-cell via protocol payloads on the cell (`image`, `scale`) | reuses the terminal's own device units instead of inventing toolkit ones                       | two mostly-dead optional fields on every cell; the fine path vanishes without the capability      |
| Two cell types, borrowing and owning                          | frame-local borrows stay cheap; retention is explicit and localised                            | a copy per changed cell per frame, plus an arena per screen                                       |
| `Color` as `default \| index \| rgb`                          | the role/value hedge costs one union, and the terminal does the re-resolution                  | only works because the wire format already names roles; a richer `Slot` would not fit             |
| Widget `draw` returns a `Surface` carrying its own size       | extent is a result, not a query                                                                | every draw allocates a buffer (from an arena discarded each frame)                                |
| No backend abstraction at all                                 | there is one target class; variation is data, not a type                                       | a non-terminal target is inexpressible — the model cannot reach a GPU                             |

## Bearing on the proposal

1. **Take the capability struct, and let the backend fill it in** (friction §2,
   [F4][comparison]). A single `CanvasCaps` value — `hairline`, `clip`,
   `subCell`, `proportionalText` — is legible where `__traits(compiles)` at eight
   call sites is not, and it costs nothing that the DbI probe does not already
   cost: a backend can still _derive_ it at compile time from what it implements.
   libvaxis shows the negotiated version; ours would be the declared version, and
   the shape is the same.
2. **Add the override channel, not just the refusal.** F4 asked for a refusable
   degrade. libvaxis has `VAXIS_FORCE_WCWIDTH`/`VAXIS_FORCE_UNICODE` as well, and
   for a repository whose golden oracles are PTY and GUI recordings, _pinning_ a
   capability is the more valuable of the two. Refusal tells a test it cannot
   have fidelity; a pin makes two machines produce the same bytes.
3. **Publish the conversion factor instead of enumerating positions** (friction
   §5). This **complicates [F5][comparison]**, which generalised Notcurses'
   ladder into "name a fidelity, not a position". A second sub-cell cell library
   independently chose something else: hand layout the device size of a cell
   (`cell_size` in `DrawContext`) and let anything finer travel as real device
   units under a capability gate. For `sparkles:ui` that is a smaller change than
   a fidelity vocabulary — `GridCanvas` reports 1×1, `SkiaCanvas` and
   `RaylibCanvas` report their real cell pitch — and it dissolves the "two-pixel
   focus ring" case §5 records as unspellable.
4. **Reduce `visual` + `slot` to one field that can be either** (friction §6).
   `Color`'s `default | index | rgb` union is the pattern: a resolved type that
   can also hold an unresolved name. Whether `Slot` fits inside `Visual` is an
   open question, but "one sum-typed field" is strictly cheaper than "two fields,
   both always present", and no subject surveyed pays for both.
5. **Solve `DrawOp.text` with a second type, not an interner** (friction §7).
   `Cell` borrows; `InternalCell` owns; the copy happens once, at the retain
   boundary. That is the `@nogc`-friendliest of the three answers in the survey
   and it makes the lifetime question static.
6. **Make `paint` return an extent** (friction §8). This **complicates
   [F7][comparison]**, which concluded that extent belongs to the surface and the
   offscreen case wants a _layout_ query. `vxfw.Surface.size` shows a third
   option that is cheaper than either: the draw call already knows how much it
   covered, so it should say so. `skia-canvas-render.d`'s op-scan disappears
   without a new query being added anywhere.
7. **Do not conclude from Notcurses that a fidelity ladder is the cell answer.**
   Two cell libraries, two different sub-cell designs, neither of them a position
   enum — the shared finding is only the negative one: **`RuleEdge` is the outlier
   and integer-only geometry is what produced it.**
8. **A scrollbar is a widget parameter, not a seam operation** (friction §3).
   Second independent confirmation after Ratatui: libvaxis's low-level scrollbar
   is 33 lines with a single `character` field, and its framework version carries
   six configurable thumb cells — all above the seam. This narrows
   [F3][comparison]'s "semantic operations are legitimate" to the cases Slint
   actually justifies (a box shadow), and excludes ours.

## Sources

All paths verified to exist at [`c060d314930c5552b99a89278a6a695baf0352da`][rev];
the revision was resolved with `gh api repos/rockorager/libvaxis/commits/main --jq .sha`
and each file was read from `raw.githubusercontent.com` at that SHA.

- [`README.md`][readme] — the no-terminfo position, the feature list, the vxfw framing
- [`build.zig.zon`][zon] — version, minimum Zig, the two dependencies
- [`src/Vaxis.zig`][vaxis] — `Capabilities`, `queryTerminal`/`queryTerminalSend`, `enableDetectedFeatures`, `render`, the image transmit family, `translateMouse`
- [`src/Loop.zig`][loop] — capability events, the explicit-width/scaled-text keypress detection
- [`src/ctlseqs.zig`][ctlseqs] — `explicit_width_query`, `scaled_text`, the Kitty graphics preamble
- [`src/Cell.zig`][cell] — `Cell`, `Character` (the width contract), `Scale`, `Style`, `Color`
- [`src/Screen.zig`][screen] / [`src/InternalScreen.zig`][internal] — the two grids and the ownership split
- [`src/Window.zig`][window] — offsets, `child`, `writeCell` bounds, `PrintOptions.commit`
- [`src/gwidth.zig`][gwidth] — the three width methods and the tests that pin their disagreement
- [`src/unicode.zig`][unicode] — the grapheme iterator over `uucode`
- [`src/Image.zig`][image] — `DrawOptions`, `pixel_offset`, `cellSize`
- [`src/Mouse.zig`][mouse] — `xoffset`/`yoffset`
- [`src/GraphemeCache.zig`][gcache] — key-text retention
- [`src/vxfw/vxfw.zig`][vxfw] — `Widget`, `DrawContext`, `Surface`
- [`src/vxfw/App.zig`][app] — `doLayout`, `cell_size`, `render`
- [`src/vxfw/ScrollBars.zig`][scrollbars] and [`src/widgets/Scrollbar.zig`][scrollbar] — scrollbars above the seam

<!-- References -->

[rev]: https://github.com/rockorager/libvaxis/tree/c060d314930c5552b99a89278a6a695baf0352da
[repo]: https://github.com/rockorager/libvaxis
[docs]: https://rockorager.github.io/libvaxis/
[readme]: https://github.com/rockorager/libvaxis/blob/c060d314930c5552b99a89278a6a695baf0352da/README.md
[license]: https://github.com/rockorager/libvaxis/blob/c060d314930c5552b99a89278a6a695baf0352da/LICENSE
[zon]: https://github.com/rockorager/libvaxis/blob/c060d314930c5552b99a89278a6a695baf0352da/build.zig.zon
[vaxis]: https://github.com/rockorager/libvaxis/blob/c060d314930c5552b99a89278a6a695baf0352da/src/Vaxis.zig
[loop]: https://github.com/rockorager/libvaxis/blob/c060d314930c5552b99a89278a6a695baf0352da/src/Loop.zig
[ctlseqs]: https://github.com/rockorager/libvaxis/blob/c060d314930c5552b99a89278a6a695baf0352da/src/ctlseqs.zig
[cell]: https://github.com/rockorager/libvaxis/blob/c060d314930c5552b99a89278a6a695baf0352da/src/Cell.zig
[screen]: https://github.com/rockorager/libvaxis/blob/c060d314930c5552b99a89278a6a695baf0352da/src/Screen.zig
[internal]: https://github.com/rockorager/libvaxis/blob/c060d314930c5552b99a89278a6a695baf0352da/src/InternalScreen.zig
[window]: https://github.com/rockorager/libvaxis/blob/c060d314930c5552b99a89278a6a695baf0352da/src/Window.zig
[gwidth]: https://github.com/rockorager/libvaxis/blob/c060d314930c5552b99a89278a6a695baf0352da/src/gwidth.zig
[unicode]: https://github.com/rockorager/libvaxis/blob/c060d314930c5552b99a89278a6a695baf0352da/src/unicode.zig
[image]: https://github.com/rockorager/libvaxis/blob/c060d314930c5552b99a89278a6a695baf0352da/src/Image.zig
[mouse]: https://github.com/rockorager/libvaxis/blob/c060d314930c5552b99a89278a6a695baf0352da/src/Mouse.zig
[gcache]: https://github.com/rockorager/libvaxis/blob/c060d314930c5552b99a89278a6a695baf0352da/src/GraphemeCache.zig
[vxfw]: https://github.com/rockorager/libvaxis/blob/c060d314930c5552b99a89278a6a695baf0352da/src/vxfw/vxfw.zig
[app]: https://github.com/rockorager/libvaxis/blob/c060d314930c5552b99a89278a6a695baf0352da/src/vxfw/App.zig
[scrollbars]: https://github.com/rockorager/libvaxis/blob/c060d314930c5552b99a89278a6a695baf0352da/src/vxfw/ScrollBars.zig
[scrollbar]: https://github.com/rockorager/libvaxis/blob/c060d314930c5552b99a89278a6a695baf0352da/src/widgets/Scrollbar.zig
[canvas]: ../../../libs/ui/src/sparkles/ui/canvas.d
[comparison]: ./comparison.md
