# libvaxis (Zig)

Cell-level OSC 66 scaling exposes both the usefulness of terminal-sized text and
the retained-screen obligations that an escape-sequence encoder cannot satisfy.

**Last reviewed:** September 14, 2026.

| Field                | Value                                                                        |
| -------------------- | ---------------------------------------------------------------------------- |
| Language             | Zig; the pinned README targets Zig 0.16.0                                    |
| License              | MIT, copyright 2023 Tim Culverhouse; verified in [LICENSE][license]          |
| Repository           | [rockorager/libvaxis][repo]                                                  |
| Documentation        | [Pinned README][readme] and [API documentation][api]                         |
| Category             | Cell-grid TUI library with the higher-level `vxfw` framework                 |
| Revision inspected   | `f37c42a3b324131c131d066767968e1f5b976453`                                   |
| Text-sizing surface  | `Cell.Scale`, explicit-width output, integer/fractional scale output         |
| Capability mechanism | Terminal queries; separate `explicit_width` and `scaled_text` flags          |
| Evidence level       | Local source inspection; no terminal reproduction or upstream test execution |

## Overview

### What it solves

libvaxis gives applications a screen of styled graphemes rather than requiring
them to manage cursor movement and escape sequences directly. Its low-level
interface exposes individual cells; `vxfw` adds a runtime, focus, mouse handling,
and widgets. The [backend-seam survey][backend] covers that broader architecture.
This page isolates the path from a sized cell to retained state and terminal bytes.

The important distinction is between **explicit advance** and **visual scaling**.
An application can ask the terminal to honor a grapheme's chosen cell width
without making it taller. Scaling adds a multi-row footprint and potentially a
fractional glyph size inside it. See the shared [concepts][concepts] for those
separate quantities; neither is equivalent to ordinary bold or a global font zoom.

At the inspected revision, libvaxis is more than an explicit-width encoder:
`Cell.Scale` reaches production rendering. However, that does not establish a
complete scale-aware layout, clipping, diff, or interaction contract. The source
contains concrete gaps between the public cell and the remembered terminal image.

### Design philosophy

The [README][readme] states, verbatim:

> Libvaxis _does not use terminfo_. Support for vt features is detected through
> terminal queries.

The same README describes the low-level interface as giving applications
"full control over each cell on the screen." Both statements explain the design:
capability discovery belongs to the library, while detailed cell placement can
belong to the caller. Neither statement promises automatic typographic reflow.

There is also a documentation/source distinction worth preserving. The README's
feature list labels explicit width as "width modifiers only". The inspected
[cell model][cell] and [renderer][render] already contain scale and fraction
emission. The implementation, not that shorter feature bullet, is the evidence
for the richer low-level API described here.

## How it works

The relevant path is short enough to audit end to end:

1. The application creates a [`Cell`][cell] with `char`, `style`, and `scale`.
2. [`Window.writeCell`][window] checks the anchor and writes into the screen.
3. [`Vaxis.render`][render] compares that cell with the previous internal cell.
4. A changed scaled cell marks covered locations as skipped for this render pass.
5. The renderer emits OSC 66 and updates its local cursor estimate.
6. [`InternalScreen.writeCell`][internal] remembers the emitted cell's contents.

The public scale representation is this excerpt from [`Cell.zig`][cell]:

```zig
pub const Scale = packed struct {
    scale: u3 = 1,
    // The spec allows up to 15, but we limit to 7
    numerator: u4 = 1,
    // The spec allows up to 15, but we limit to 7
    denominator: u4 = 1,
    vertical_alignment: enum(u2) {
        top = 0,
        bottom = 1,
        center = 2,
    } = .top,
```

This is a source excerpt, not a standalone sample or a validated application.
The comments and field types should not be conflated: `u4` can represent 0 through
15 despite the adjacent comments saying "limit to 7". The scale field is `u3`.
The type alone does not enforce every protocol-valid combination.

[`ctlseqs.zig`][sequences] defines the output forms verbatim:

```zig
pub const scaled_text = "\x1b]66;s={d}:w={d};{s}\x1b\\";
pub const scaled_text_with_fractions = "\x1b]66;s={d}:w={d}:n={d}:d={d}:v={d};{s}\x1b\\";
```

For denominator 1, the renderer chooses the first form. Other nonzero denominators
choose the fractional form; denominator 0 reaches `unreachable`. The ordinary
explicit-width branch is later, after the scaled branch's early `continue`.

## Protocol and API

[`Cell.Character`][cell] holds grapheme bytes and an unscaled `width: u8`.
`Cell.Scale` is separate from `Style`, so scaling is not an SGR decoration.
Its `eql` compares the packed value, but that helper's existence does not mean the
screen diff uses it. The distinction becomes decisive in retained rendering.

The implemented sizing vocabulary includes integer `s`, explicit `w`, fraction
`n`/`d`, and vertical alignment `v`. There is no horizontal-alignment member in
this public scale structure. Treat it as the subset exposed by this library,
not as a claim that every OSC 66 option has a corresponding application field.

[`Cell.Segment`][cell], the contiguous styled-text input, contains `text`, `style`,
and `link`, but not `scale`. Consequently, the low-level sized-cell surface is
not interchangeable with a scale-bearing rich-text run API. An application that
uses segments needs an additional sizing/placement layer rather than merely a
new style value.

The [example][example] assigns `.scale = .{ .scale = scale }` and places each
ASCII character at `i * scale`. This is useful evidence that application code
reserves horizontal space deliberately. It is not evidence that general text
measurement automatically multiplies line heights or that all widgets accept it.

## Measurement and geometry

[`Window.gwidth`][window] delegates to [`gwidth`][gwidth] with the screen's selected
width method. The methods include `unicode`, `wcwidth`, and `no_zwj`, allowing
different terminal interpretations of grapheme sequences. That measurement is
about terminal columns before scaling, not pixel font metrics.

`Character.width` documents zero as a request to measure at render time. The
scaled footprint branch separately asserts `cell.char.width > 0` and computes
its columns from that field. A caller must not assume that deferred ordinary
width measurement satisfies this scaled-cell precondition.

The source uses two related but distinct calculations:

| Quantity                | Calculation in the inspected renderer   | Consequence                                 |
| ----------------------- | --------------------------------------- | ------------------------------------------- |
| Reserved columns        | `cell.scale.scale * cell.char.width`    | Needs a known base width                    |
| Reserved rows           | `cell.scale.scale`                      | Scaling occupies more than the anchor row   |
| Output width parameter  | Computed `w`                            | Sent alongside the scale parameters         |
| Estimated next column   | `col + (w * scale.scale)`               | Integer footprint, not fractional ink width |
| Fractional glyph sizing | `numerator` and `denominator` in OSC 66 | Does not reduce the reserved rectangle      |

That separation is valuable: a fraction describes rendering inside a cell
allocation, not permission for later content to reuse its space. The missing
piece is a common geometry object consumed by measurement, painting, clipping,
and hit testing. The inspected functions recompute or assume parts of that model.

## Capability and fallback

The [query strings][sequences] draw an explicit-width space and a scaled space,
with cursor-position requests used to observe the resulting advance. The
[`Loop`][loop] recognizes the replies through parser output that is also shaped
like modified F3 key events: Shift for explicit width and Alt for scaling.

Both recognition branches require `!vx.queries_done.load(.unordered)`. This is a
query-window guard, not a permanent listener accepting such keys at any time.
The explicit-width branch also selects Unicode width measurement. Scaling and
explicit-width capability remain separately represented.

This parser reuse exposes an ambiguity, not an authenticated response channel:
a colliding key sequence during discovery can resemble the expected reply.
Source inspection establishes the guard and aliasing; it does not demonstrate
how often a real user can trigger a false positive. The [OpenTUI study][opentui]
provides related, but implementation-specific, upstream evidence about correlation.

Without `scaled_text`, the scale-emission and footprint-skip branches are not
taken. The renderer falls through to explicit-width output when supported and
`w > 1`, otherwise to raw grapheme bytes. That is an output fallback, not a layout
fallback: caller-reserved gaps and extra rows are not automatically repacked.

For Sparkles, the useful policy is to resolve support before layout and choose
either scaled geometry or an intentional ordinary-text alternative. Silently
dropping scale only at emission can leave a technically readable but badly
spaced interface. The [proposal][proposal] should make that policy explicit.

## Layout and clipping

[`Window.writeCell`][window] rejects anchors beyond the window dimensions and
anchors translated to negative coordinates. It does not validate the full
rectangle implied by `scale * width` and `scale` rows. An in-bounds anchor is
therefore weaker than an in-bounds scaled placement.

The [renderer][render] marks covered positions using a linear index:

```zig
const skipped_i = (@as(usize, @intCast(skipped_row + row)) * self.screen_last.width) + (skipped_col + col);
self.screen_last.buf[skipped_i].skip = true;
```

The surrounding loops range over the entire computed footprint; this block has
no column clipping, row clipping, or buffer-length guard. At the right edge a
linear index can refer to the next row instead of the intended column. At the
bottom edge it can exceed the allocated screen. Child-window boundaries are an
additional concern even when the overall screen rectangle would still fit.

> [!WARNING]
> These are source-derived bounds and footprint risks, not reproduced crashes or
> terminal corruption observed in this survey. The conclusion is that the shown
> path lacks a complete footprint check, not that every scaled cell fails.

The ordinary out-of-bounds test in [`InternalScreen.zig`][internal] protects its
coordinate-based read/write methods. It does not cover the direct buffer access
above. A passing anchor test would not establish multi-cell placement safety.

For an adoptable design, choose and test a clipping policy before emitting bytes:
reject partial placement, substitute ordinary text, or represent clipped pieces
explicitly if the backend supports them. Relying on terminal clipping after
marking an unclipped retained footprint makes the two screen models disagree.

## Retained state and interaction

[`InternalCell`][internal] declares `scale: Cell.Scale = .{}`, but `eql` compares
only grapheme bytes, style, URI, and URI parameters after its default-cell fast
path. `writeCell` copies text, links, style, and `default`, but does not copy
scale; `readCell` does not restore it either. The field is present without the
storage/equality behavior a retained scale property requires.

The renderer performs that equality check before marking the new footprint.
A scale-only change can therefore be considered unchanged when other compared
properties match and no refresh forces output. The source establishes the
omission; an executable two-frame test is still needed to characterize the exact
visible outcome, including prior skip state and surrounding repaint activity.

`skip` is a per-pass marker reset before the render traversal. It prevents later
cells in the same pass from painting over a newly emitted scaled cell. It is not
a persistent ownership map identifying the anchor responsible for every covered
cell, nor a record of the old rectangle to erase when scaling shrinks or moves.

That matters for interaction as well as damage. [`Window.showCursor`][window]
accepts ordinary cell coordinates; no inverse scaled-glyph mapping is supplied
by `Cell.Scale`. The low-level application must keep its input and layout model
consistent. Do not infer scale-aware selection or mouse targeting merely from
`vxfw` providing general focus and mouse management.

The transferable invariant is that a placement owns its whole allocation.
Resizing it damages the union of old and new allocations, and every covered
coordinate resolves consistently for clipping, cursor placement, and selection.
The [validation plan][validation] is the place to turn that into independent tests.

## Safety and evidence

This review read the local checkout at the exact revision in the metadata.
The quoted README text, field declarations, emission strings, equality/storage
omissions, and direct footprint indexing were checked against those files.
No Zig build, upstream unit suite, PTY session, or terminal screenshot was run.

The strongest positive evidence is a complete source path from public scale
fields to emitted OSC 66. The strongest negative evidence is likewise concrete:
scale is omitted from retained comparison/copying and full-footprint bounds are
not checked at the shown direct indexing site. Neither requires inventing a
runtime result, but neither should be presented as a reproduced failure.

High-value follow-up cases are scale-only changes, shrink/grow at a fixed anchor,
movement across a child clip, right/bottom-edge placements, and unknown width.
Run each with scaling supported and unsupported, and compare a fresh full frame
with incremental repaint. Fractions and vertical alignment need independent
assertions because successful integer scaling does not validate those fields.

## Strengths

- A compact public scale value reaches actual rendering, not only a capability flag.
- Width forcing remains distinct from multi-row visual scaling.
- Fractional parameters and vertical alignment are visible in the encoder.
- Capability-gated output preserves an ordinary-text path.
- The small cell-to-terminal path makes retained-state omissions directly auditable.

## Weaknesses

- Scale is declared but not compared, copied, or restored in `InternalScreen`.
- Anchor clipping does not establish footprint safety; direct skip indexing is unbounded.
- Deferred base-width measurement conflicts with the scaled footprint precondition.
- Segment printing and general cursor coordinates do not form a sized-text layout API.
- Query-shaped key ambiguity and scale-only damage need runtime validation.

## Key design decisions and trade-offs

| Decision                              | Rationale                                          | Trade-off                                                     |
| ------------------------------------- | -------------------------------------------------- | ------------------------------------------------------------- |
| Put scale on `Cell`                   | Expose terminal geometry at the low-level API      | Every retained cell operation must preserve it                |
| Keep scale separate from style        | Sizing changes allocation, not just appearance     | Existing styled segments cannot carry it directly             |
| Probe terminal behavior               | Avoid a static terminal-name database              | Replies need correlation and an input ambiguity policy        |
| Skip covered cells during emission    | Prevent same-pass overpainting                     | Temporary flags do not retain placement ownership             |
| Send explicit base width with scaling | Keep terminal advance aligned with chosen geometry | Caller and renderer must agree on the unscaled width          |
| Fall back to ordinary output          | Keep unsupported terminals usable                  | Layout must separately decide whether to reserve scaled space |

The [comparison][comparison] should classify libvaxis as implemented low-level
scale emission with incomplete retained-footprint evidence, not as either
"unsupported" or a proven end-to-end typography system.

## Sources

- [README][readme] and [LICENSE][license]: positioning, verbatim quote, license.
- [`Cell.zig`][cell] and [`ctlseqs.zig`][sequences]: data model and wire forms.
- [`Vaxis.zig`][render] and [`InternalScreen.zig`][internal]: emission and retention.
- [`Window.zig`][window], [`gwidth.zig`][gwidth], and [`Loop.zig`][loop]: geometry and discovery.
- [`examples/main.zig`][example]: caller-controlled scale placement; inspected, not run.
- [Concepts][concepts], [comparison][comparison], [validation][validation], and [Sparkles proposal][proposal].

<!-- References -->

[repo]: https://github.com/rockorager/libvaxis
[api]: https://rockorager.github.io/libvaxis/
[readme]: https://github.com/rockorager/libvaxis/blob/f37c42a3b324131c131d066767968e1f5b976453/README.md
[license]: https://github.com/rockorager/libvaxis/blob/f37c42a3b324131c131d066767968e1f5b976453/LICENSE
[cell]: https://github.com/rockorager/libvaxis/blob/f37c42a3b324131c131d066767968e1f5b976453/src/Cell.zig
[sequences]: https://github.com/rockorager/libvaxis/blob/f37c42a3b324131c131d066767968e1f5b976453/src/ctlseqs.zig
[render]: https://github.com/rockorager/libvaxis/blob/f37c42a3b324131c131d066767968e1f5b976453/src/Vaxis.zig
[internal]: https://github.com/rockorager/libvaxis/blob/f37c42a3b324131c131d066767968e1f5b976453/src/InternalScreen.zig
[window]: https://github.com/rockorager/libvaxis/blob/f37c42a3b324131c131d066767968e1f5b976453/src/Window.zig
[gwidth]: https://github.com/rockorager/libvaxis/blob/f37c42a3b324131c131d066767968e1f5b976453/src/gwidth.zig
[loop]: https://github.com/rockorager/libvaxis/blob/f37c42a3b324131c131d066767968e1f5b976453/src/Loop.zig
[example]: https://github.com/rockorager/libvaxis/blob/f37c42a3b324131c131d066767968e1f5b976453/examples/main.zig
[backend]: ../../ui-backend-seam/libvaxis.md
[opentui]: ./opentui.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[validation]: ./validation.md
[proposal]: ./sparkles-proposal.md
