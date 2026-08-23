# imtui — geometry retargeted to cells, and the fork that cost

**Category:** cross-target — the natural experiment. **Last reviewed:** August 23, 2026.
Pinned at [`b7c08877`][rev]; its Dear ImGui submodule at [`d413be8c`][imgui-rev].

Dear ImGui's renderer seam is `ImDrawData` — command lists of vertices and
indices. imtui points that seam at a character grid: the same command stream
that drives every GPU backend in the ImGui ecosystem, driving a target it
manifestly does not fit. It is this survey's price list for pushing a seam all
the way down to geometry.

| Field            | Value                                                                                         |
| ---------------- | --------------------------------------------------------------------------------------------- |
| Language         | C++                                                                                           |
| License          | MIT                                                                                           |
| Repository       | [`ggerganov/imtui`][repo]                                                                     |
| Documentation    | [`README.md`][readme] — the repository's only prose                                           |
| Category         | cross-target — the natural experiment                                                         |
| Pinned revision  | [`b7c08877e2a43549d2fccc5f78d43ea32153b72a`][rev]                                             |
| Upstream toolkit | Dear ImGui v1.81, via the **fork** [`ggerganov/imgui`][imgui-repo] at [`d413be8c`][imgui-rev] |
| Seam consumed    | `ImDrawData` → `ImDrawList` → `ImDrawCmd` + `ImDrawVert` (`pos`, `uv`, `col`)                 |
| Backends shipped | `imtui-impl-text` (geometry → cells), `imtui-impl-ncurses`, `imtui-impl-emscripten`           |
| Target range     | ANSI-256 terminal cells; a browser canvas simulating a console                                |

> [!IMPORTANT]
> The premise that imtui retargets an **unmodified** ImGui seam is false, and
> that is the most useful thing it teaches. The vendored ImGui is a fork on a
> branch named `imtui` ([`.gitmodules`][gitmodules]), three commits ahead of
> v1.81, editing `imgui.cpp`, `imgui.h`, `imgui_draw.cpp`, `imgui_internal.h`,
> `imgui_tables.cpp` and `imgui_widgets.cpp`. The seam was not retargeted; it
> was bypassed, by rewriting the widget layer above it.

## Overview

### What it solves

Running Dear ImGui's whole widget vocabulary in a terminal without writing a
widget layer:

> This library is 99.9% based on the popular [Dear ImGui](https://github.com/ocornut/imgui) library. ImTui simply provides an [ncurses](https://en.wikipedia.org/wiki/Ncurses) interface in order to draw and interact with widgets in the terminal. The entire Dear ImGui interface is available out-of-the-box.
>
> — [`README.md`][readme]

That holds at the API surface: [`examples/ncurses0/main.cpp`][ncurses0] calls
`ImGui::Begin`, `ImGui::Text`, `ImGui::SliderFloat` and `ImGui::Button` with no
terminal-specific vocabulary at all.

### Design philosophy

Two moves, both stated in code. **A cell is one pixel** — the atlas is built at
one pixel per glyph and the ncurses backend feeds `io.DisplaySize` from
`getmaxyx`, so ImGui's layout arithmetic runs unchanged, in cells:

```cpp
ImFontConfig fontConfig;
fontConfig.GlyphMinAdvanceX = 1.0f;
fontConfig.SizePixels = 1.00;
ImGui::GetIO().Fonts->AddFontDefault(&fontConfig);
```

— [`src/imtui-impl-text.cpp`][text]

And **the character travels in the alpha channel**, because `ImDrawVert` is
`pos`, `uv`, `col` and has no field for a code point ([`imgui.h`][imgui-h]):

```cpp
col &= 0x00FFFFFF;
col |= (c << 24);
```

— the forked `ImFont::RenderText`, [`imgui_draw.cpp`][imgui-draw]

One line is the entire text channel: a side channel smuggled through an
existing field, because a fixed 20-byte vertex shared with every other ImGui
backend cannot be extended.

## How it works

The seam is a tag-free uniform record — one kind of command plus one escape
hatch:

```cpp
struct ImDrawCmd
{
    ImVec4          ClipRect;
    ImTextureID     TextureId;
    unsigned int    VtxOffset;
    unsigned int    IdxOffset;
    unsigned int    ElemCount;   // multiple of 3, rendered as triangles
    ImDrawCallback  UserCallback;
    void*           UserCallbackData;
};
```

— [`imgui.h`][imgui-h]

`ImTui_ImplText_RenderDrawData(ImDrawData*, ImTui::TScreen*)` is the whole
backend contract ([`imtui-impl-text.h`][text-h]). It walks every triangle and
must **reconstruct** what the widget layer knew.

**The discriminant is a UV comparison.** Untextured triangles share the atlas's
white-pixel UV, so degenerate UVs mean "fill" and varying UVs mean "glyph" —
after which the backend _assumes_ the next three indices complete the quad:

```cpp
if (uv0.x != uv1.x || uv0.x != uv2.x || uv1.x != uv2.x ||
    uv0.y != uv1.y || uv0.y != uv2.y || uv1.y != uv2.y) {
    /* … glyph: read the next triangle too … */   i += 3;
} else {
    drawTriangle(pos0, pos1, pos2, rgbToAnsi256(col0, true), screen);
}
```

**A glyph's position is a centroid**, with a collision rule standing in for
advance: the six vertex positions are averaged, and if the result lands within
half a cell of the previous glyph it is bumped one column right
(`x = lastCharX + 1.0f`). A text _run_ does not exist at this seam; it is
re-derived one character at a time.

**Fills are scanline-rasterised into cells.** `drawTriangle` walks the edges
into a per-row x-range table and writes each covered cell, where a `TCell` is a
`uint32_t` packed `0x0000FFFF` char / `0x00FF0000` fg / `0xFF000000` bg
([`imtui.h`][imtui-h]):

```cpp
cell &= 0x00FF0000;                   // keep the foreground byte
cell |= ' ';                          // erase the character
cell |= ((ImTui::TCell)(col) << 24);  // set the background
```

Glyph writes are the mirror (`cell &= 0xFF000000`). So z-order does not
survive: a fill emitted after a glyph **erases the glyph**, and correct output
depends on ImGui happening to emit backgrounds before text. Colour is quantised
to the xterm-256 cube per triangle by `rgbToAnsi256`, which for fills
pre-multiplies alpha — compositing against black, not against the destination.

Downstream, [`imtui-impl-ncurses`][ncurses] treats `TScreen` as a retained
buffer: `DrawScreen` diffs it row-by-row against `screenPrev`, allocates colour
pairs lazily, and batches runs of equal `(fg, bg)` into one `addstr`. That half
is a conventional, well-behaved cell compositor — the same shape as
`sparkles:tui`'s `Screen`, and good _because_ `TScreen` is a semantic-free
raster. All the damage is upstream of it.

## Q1 — measurement units, and who answers

**imtui does not move measurement off the painter; it collapses the unit space
so the painter cannot be wrong.** ImGui measures through `ImFont`
(`CalcTextSize` / `ImFont::CalcTextSizeA`, [`imgui.h`][imgui-h]), and imtui
makes that honest with `SizePixels = 1.00` plus `GlyphMinAdvanceX = 1.0f` —
whose own documentation reads:

> `GlyphMinAdvanceX;  // 0  // Minimum AdvanceX for glyphs, set Min to align font icons, set both Min/Max to enforce mono-space font`
>
> — [`imgui.h`][imgui-h]

Note imtui sets only `Min`, so the documented monospace guarantee is not the
one actually used. Uniformity is imposed by the fork instead, which discards
each glyph's metrics in `ImFont::RenderText` and emits a fixed quad —
`x1 = x`, `x2 = x + 1.0`, `y1 = y2 = y - 0.5f`, where upstream v1.81 uses
`glyph->X0 * scale` and friends ([`imgui_draw.cpp`][imgui-draw]). Every glyph
is one unit wide and **zero units tall**: a degenerate quad whose only job is
to survive as six vertices carrying a code point and a colour.

Consequences, all structural: a proportional font is inexpressible, exactly as
in [friction §1][friction] and for the same reason — one unit serves both the
layout grid and the glyph advance. Wide and combining characters are equally
inexpressible, since `ImTui::TChar` is `unsigned char` ([`imtui.h`][imtui-h])
and the ncurses writer stages cells into a `std::vector<uint8_t>`; a cell is
one byte, with no grapheme concept anywhere in the stack. What _is_ right is
the direction of flow: unit and extent originate at the device
(`getmaxyx` → `io.DisplaySize`) and propagate up.

This is the strongest confirmation of [F1][comparison] arrived at from the
opposite direction. Thirty-five of thirty-eight subjects put measurement
somewhere other than the painter; imtui leaves it there and survives only by
making every unit degenerate.

## Q2 — is the contract stated?

**There is nothing to state, and that is the problem.** The contract is four
free functions with no capability surface:

```cpp
bool ImTui_ImplText_Init();
void ImTui_ImplText_Shutdown();
void ImTui_ImplText_NewFrame();
void ImTui_ImplText_RenderDrawData(ImDrawData * drawData, ImTui::TScreen * screen);
```

— [`include/imtui/imtui-impl-text.h`][text-h], the file in full

Triangles are the floor of any GPU backend, so as with [egui](./egui.md) there
is nothing to decline. But imtui is not a GPU backend, and genuinely cannot
draw rounded corners, anti-aliased edges, circles or sub-cell strokes. With no
channel to say so, the refusals migrate upward twice over:

1. **Into style, at init.** `ImTui_ImplText_Init` zeroes every `*Rounding` and
   `*BorderSize` and sets `AntiAliasedLines = false` / `AntiAliasedFill = false`
   — a capability declaration written as style assignments the producer is
   trusted to honour.
2. **Into the fork, permanently.** Where style could not suppress the geometry,
   the widget code was edited — the resize grip's `PathArcToFast` +
   `PathFillConvex` becomes `AddText(…, "+")`; a close button's hover circle
   becomes `AddCircleFilled(center, 0.1f, col, 12)`, a circle of radius one
   tenth of a cell, drawn to be invisible ([`imgui_widgets.cpp`][imgui-widgets]).

That is [F5][comparison] at maximum cost — a floor with no defaulted tier above
it and no refusable one below it, so what the backend cannot do is settled by
editing the producer. Its price is not a worse-looking
frame; it is a **permanently unmergeable fork**, because every edit is a
terminal-specific regression for every other backend.

## Q3 — semantic operations, and where degradation lives

**Nothing semantic survives the seam, so nothing can degrade in the backend —
and degradation relocates into the widget layer.** Geometry alone supports only
two recoveries: "a filled area" and "a character". Everything else was replaced
upstream:

| What the widget meant | Upstream geometry                          | Fork's replacement                                                   |
| --------------------- | ------------------------------------------ | -------------------------------------------------------------------- |
| a direction arrow     | `AddTriangleFilled` / three-point path     | `AddText(center, col, "<" / ">" / "^" / "v")`                        |
| a check mark          | three `PathLineTo` + `PathStroke`          | `AddText(pos, col, symbol)`, `symbol` defaulting to `"X"`            |
| a bullet              | `AddCircleFilled`                          | `AddText(..., "B")`                                                  |
| a close button        | two crossing `AddLine`s                    | `AddText(center, cross_col, "[X]")`                                  |
| a radio button's dot  | `AddCircleFilled(center, radius - pad, …)` | `AddText(center, col, "x")`                                          |
| a slider grab         | `AddRectFilled(grab_bb.Min, grab_bb.Max)`  | `AddText(mid, col, "I")`                                             |
| a table border        | `AddLine` / `AddRect`                      | `for` loops of one `AddText` pipe character per row                  |
| a window border       | (none upstream)                            | a new `ImGuiStyle::WindowBorderAscii` flag, one box character a cell |
| horizontal separators | `AddLine`                                  | commented out, or guarded with `&& false`                            |

Sources: [`imgui_draw.cpp`][imgui-draw] (`RenderArrow`, `RenderBullet`,
`RenderCheckMark`, `RenderArrowPointingAt`), [`imgui_widgets.cpp`][imgui-widgets]
(`CloseButton`, `RadioButton`, `SliderScalar`, `SeparatorEx`),
[`imgui_tables.cpp`][imgui-tables] (`TableDrawBorders`, `TableEndRow`),
[`imgui.cpp`][imgui-cpp] / [`imgui.h`][imgui-h] (`WindowBorderAscii`).

Every entry in the left column is a semantic operation `sparkles:ui` spells as
a named op. `isCanvas` carries `rule` and `scrollbar` as optional primitives for
exactly this reason: a cell backend degrades a scrollbar differently from a
pixel backend, so the semantics have to survive the seam.

> [!IMPORTANT]
> [Friction §3][friction] records the consequence of that choice — "draw" and
> "what a scrollbar is" end up the same layer, and a cell backend's own answer
> (`trackGlyph`, `thumbGlyph`) rides in the drawing vocabulary past every
> backend that will never read it. imtui is the counter-experiment: a seam with
> **zero** semantic operations does not remove the layering problem, it inverts
> it. Instead of the drawing seam knowing what a scrollbar is, the scrollbar has
> to know what the drawing target is — and that is not pluggable. A second cell
> backend with different capabilities would need a second fork.

Two further losses are invisible at the API. Because a fill blanks any glyph
under it, the fork rewrites table row and cell backgrounds to a
degenerate-height rect (`AddRectFilled(min, ImVec2(max.x, min.y), col)`) so the
fill covers exactly the intended row ([`imgui_tables.cpp`][imgui-tables]). And
ImGui's CPU fine-clipping trims a glyph quad's UVs to a partial rectangle,
which is meaningless when the quad is only a carrier — so it is disabled with
`if (false && cpu_fine_clip)` ([`imgui_draw.cpp`][imgui-draw]).

## Q4 — command shape

`ImDrawCmd` has **one shape because it has no variants**. That is uniform stride
with no widest-payload cost, which is the half of [friction §4][friction] a
fixed-size `DrawOp` pays: every operation is as wide as the widest payload, so a
`PopClip` that carries nothing costs what a `TextRun` costs. It is worth saying
why the trade is not one to take.

The discriminant does not disappear; it moves into the **data**, recovered by
the UV heuristic rather than read from a case. A heuristic can be wrong; a
closed sum's arms cannot. The `i += 3` quad assumption is an unchecked invariant
about how the _producer_ tessellates — a far tighter coupling than anything
`DrawOp` states, and entirely undocumented at the seam. `UserCallback` is the
only door out, and imtui never uses it.

The other half of §4 imtui simply does not have. `VtxOffset` and `IdxOffset` are
indices into buffers the context owns, not pointers into them, so a command is
plain data all the way down: no indirection to make assignment `@system`, and
nothing for a lifetime analysis to confine. That property is bought by having no
payload worth pointing at.

So imtui and [egui](./egui.md) bracket [F3][comparison]: egui reifies into named
cases and gets values that can be culled, replayed and compared; ImGui reifies
into an untagged buffer and gets values whose _meaning_ must be guessed. F3
leaves the encoding open between a closed sum and variable-stride per-op
records; imtui prices a third option that is neither, and it is the worst of the
three — the stride saving is real, and it is paid for in the one property
reification exists to provide.

## Q5 — sub-unit placement

**imtui is [F6][comparison]'s extreme case.** ImGui's coordinates are
continuous floats and its device unit is a cell — and the sub-unit problem does
not dissolve. It becomes untypeable, and is answered with scattered constants:
`ScrollbarSize = 0.5f` and `GrabMinSize = 0.1f` ([`imtui-impl-text.cpp`][text]);
`RenderFrame` shifted by `p_min + ImVec2(1.0, 0.0)` and shrunk by
`p_max - ImVec2(+0.1, 0.1)`, a title bar's clip rect narrowed by `- 2.1f`, a
tooltip grown by `+ ImVec2(1.5f, 0.0f)` ([`imgui.cpp`][imgui-cpp]); a text
cursor drawn as a zero-length `AddLine` offset by `ImVec2(0.6f, -0.5f)`
([`imgui_widgets.cpp`][imgui-widgets]).

Those numbers are not geometry, they are rounding steering — nudges chosen so a
float truncates to the intended cell. F6 concludes that continuous coordinates
relocate the sub-unit problem rather than dissolving it, and imtui is where the
relocation is easiest to see: over a discrete device the problem moves out of
the vocabulary and into per-call-site constants, which is strictly worse than
`RuleEdge`'s six finite, named, greppable enumerators. F6's answer — a named
fidelity plus a queried device unit, [Notcurses'](./notcurses.md) move — is
unavailable here, because a fidelity is a semantic concept and this seam carries
none. Floating the coordinates buys `sparkles:ui` the same nothing unless the
fidelity is named alongside them.

## Q6 — resolved or semantic styling

**Fully resolved, then resolved again at the seam, and the role destroyed twice
over.** A vertex carries `ImU32 col` and nothing else, quantised per triangle
to the xterm-256 cube. imtui therefore pays for neither of the two things
[friction §6][friction] has a `DrawOp` carry — the resolved fields the primitive
paints from, and the `Slot` that says what the operation _is_ — and cannot
theme: colours are absolute cube indices, so a light-background terminal still
gets ImGui's dark greys, and the emscripten backend inherits the quantisation
even though a browser canvas has 24-bit colour. Which is [F9][comparison]'s
asymmetry seen from the losing end: resolved colour cannot be run backwards into
a role, so the target that keeps only the resolved half keeps the half that
cannot be recovered.

The sharper observation is that the alpha byte means _alpha_ for a fill and _a
code point_ for a glyph, which is why `rgbToAnsi256` needs a `doAlpha`
parameter to know which reading applies. A discriminant problem manufactured
entirely by having no field to put the character in.

## Q7, Q8 — payload ownership and extent

**Q7: borrowed for exactly one frame, stated in the header** — `ImDrawData`'s
`Valid` is documented "Only valid after `Render()` is called and before the next
`NewFrame()` is called", and its `ImDrawList` objects "are owned by
ImGuiContext and only pointed to from here" ([`imgui.h`][imgui-h]). That is the
same shape as [friction §7][friction]'s: a `DrawOp`'s bytes live in a frame
arena, and the rule stated on the type is that an operation is valid while the
buffer that built it is alive and unreset. Stating it is what makes it
enforceable — ImGui states it in a header comment, `sparkles:ui` states it on
the type — and in neither case does the statement let the value cross a thread
or outlive the frame.

imtui's answer is **borrow the frame, own the raster**: rasterise into a
backend-owned `TScreen`, after which the draw data can be discarded and the
terminal writer runs entirely off the raster. Transferable, with a boundary —
it works because a cell grid is tiny, fixed-size and self-contained
(`nx*ny*4` bytes). It would not work for a payload that must stay _unresolved_,
which is exactly why §7 bites `DrawOp.text` and not `DrawOp.rect`. There is no
text payload here to own: a character is four bytes of vertex colour, once, at
rasterisation time.

**Q8: the surface question is answered by the device, decisively.** `TScreen`
declares `nx`/`ny`, resized from `io.DisplaySize`, which came from `getmaxyx` —
terminal → toolkit → clipping, every frame, resize handled for free. On
[F7][comparison]'s three questions imtui answers surface extent at construction
and never asks the other two, which is the cheapest position on that axis and
available only because the target is a fixed grid. The one place imtui derives
anything by scanning geometry is `drawTriangle`'s bounding box, and even that
line carries a live copy-paste error, seeding the minimum with `screen->size()`
— the cell **count**, `nx*ny` — where `screen->ny` was meant. It is harmless
only because `nx*ny` always exceeds any on-screen `y`, so the seed never wins.
A small illustration of the larger point: a derived-by-scan extent is easy to
get subtly wrong and hard to notice. [Friction §8][friction] is the same
mistake with teeth — an offscreen surface sized by a guess cropped its own
text, and the golden pinned the crop.

## Strengths

- **The producer needs no port.** An ImGui application runs in a terminal with
  a changed init and a changed present call.
- **Unit and extent flow device → toolkit.** Nothing above the seam guesses.
- **Borrow the frame, own the raster** is a clean answer to a frame-lifetime
  display list.
- **The cell compositor below `TScreen` is exemplary and separable** — row
  diffing, lazy colour pairs, run batching.

## Weaknesses

- **The seam cannot express the target, so the target rewrote the toolkit** —
  six upstream files, structurally unmergeable.
- **Primitive kind is inferred, not declared**, and the quad assumption is
  unchecked.
- **A text run is reconstructed from centroids**; order, identity and shaping
  are gone before the backend sees anything.
- **One byte per cell** — a hard ceiling on Unicode, not a missing feature.
- **Z-order is not representable**; correctness depends on producer emission
  order.
- **Sub-cell intent is expressed as magic constants** spread through widgets.

## Key design decisions and trade-offs

| Decision                                                   | Rationale                                                                   | Trade-off                                                                                            |
| ---------------------------------------------------------- | --------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| Consume `ImDrawData` unchanged rather than add a text seam | Keeps the whole ImGui API with no widget layer of imtui's own               | Semantics must be re-inferred from geometry; what cannot be inferred is patched into a fork          |
| Declare one cell = one pixel (`SizePixels = 1.0`)          | ImGui's pixel layout arithmetic then produces correct cell layout           | Proportional fonts, wide characters and sub-cell fidelity become inexpressible, not just unsupported |
| Smuggle the code point in the vertex colour's alpha byte   | `ImDrawVert` is fixed at 20 bytes and shared with every ImGui backend       | Eight bits mean two things depending on a UV test; glyph alpha blending is lost                      |
| Discriminate glyph vs. fill by UV equality                 | The only signal the vertex format carries                                   | An untagged heuristic coupled to the producer's tessellation order                                   |
| Suppress unrenderable geometry via `ImGuiStyle` at init    | Capability refusal without a capability channel                             | A style block is not a contract; whatever style cannot reach requires a source edit                  |
| Rasterise into a backend-owned `TScreen`, then diff rows   | Decouples the frame-lifetime display list from output; minimal terminal I/O | The raster is the only retained artifact, so nothing downstream can re-resolve colour or role        |

## Bearing on the proposal

1. **The extreme [friction §3][friction] gestures at is measured here, and it
   is expensive.** Removing semantics from the drawing seam does not remove the
   need to lower; it moves the lowering into the widget layer, where it is not
   pluggable. Keep semantic ops — [F4][comparison] already finds them legitimate
   — and spend the argument on _where_ the lowering sits, which for `scrollbar`
   is the live question `trackGlyph` and `thumbGlyph` answer badly.
2. **A seam that carries no semantics forces a fork of the producer**: six
   ImGui files, +157/−91 lines, unmergeable upstream. That is the price list
   for "push the seam down to primitives", to be weighed against `DrawOp`'s
   eight kinds.
3. **[F6][comparison] gets its extreme case.** Continuous coordinates dissolve
   §5 only when the _device_ is continuous. Over a cell device they relocate the
   problem into per-call-site rounding constants — worse than `RuleEdge`. Float
   the coordinates only together with a named fidelity and a queried device
   unit; floating them alone buys nothing.
4. **[F3][comparison] gains its lower bound.** The alternative to a closed sum
   is not "no discriminant": an untagged buffer moves the discriminant into a
   heuristic over the data, and the uniform stride it buys is not worth values
   whose meaning has to be guessed. The live encoding trade stays between the
   closed sum and variable-stride records.
5. **Confirms [F5][comparison] at maximum cost, and prices [F7][comparison]'s
   cheapest answer** — refusals with nowhere to go become source edits; a
   surface extent taken from the device costs nothing, and the one bound this
   subject derives by scanning carries a bug nothing catches.
6. **Steal "borrow the frame, own the raster" for [friction §7][friction], with
   a boundary.** Right when the retained form is small and self-contained
   (`RecordingCanvas`, a golden surface); it does not answer `DrawOp.text`,
   whose retain boundary — crossing a thread, outliving the frame — is what
   [F8][comparison]'s stronger form, an offset pair in place of a slice,
   addresses and `UI-O4` leaves open.
7. **`ImDrawCmd::UserCallback` is a third independent sighting of a single
   escape hatch**, after egui's `Shape::Callback` and Qt's fallback path —
   worth adopting alongside the named cases.

> [!NOTE]
> The README calls imtui "99.9% based on" Dear ImGui. Measured at the seam
> rather than at the API, the missing 0.1% is not glue: it is the widget layer
> being taught what a terminal is, one `AddText` at a time.

## Sources

- [`ggerganov/imtui`][repo] at [`b7c08877e2a43549d2fccc5f78d43ea32153b72a`][rev] — pinned with `gh api repos/ggerganov/imtui/commits/master --jq .sha`; every cited path fetched from `raw.githubusercontent.com` at that SHA.
- [`src/imtui-impl-text.cpp`][text] — `ScanLine`, `drawTriangle`, `rgbToAnsi256`, `ImTui_ImplText_RenderDrawData`, `ImTui_ImplText_Init`.
- [`include/imtui/imtui.h`][imtui-h] — `TChar`, `TColor`, the packed `TCell`, `TScreen`.
- [`include/imtui/imtui-impl-text.h`][text-h] — the entire backend contract.
- [`src/imtui-impl-ncurses.cpp`][ncurses] — input mapping, `getmaxyx` → `io.DisplaySize`, the row-diffing `DrawScreen`.
- [`examples/ncurses0/main.cpp`][ncurses0] — the unmodified-ImGui application surface.
- [`README.md`][readme] and [`.gitmodules`][gitmodules] — the positioning claim, and the submodule pointing at a **fork**.
- [`ggerganov/imgui`][imgui-repo] at [`d413be8c79826bdd708bf4ba9ae7a83180bd55e8`][imgui-rev], resolved with `gh api repos/ggerganov/imtui/contents/third-party/imgui/imgui`: [`imgui.h`][imgui-h], [`imgui.cpp`][imgui-cpp], [`imgui_draw.cpp`][imgui-draw], [`imgui_widgets.cpp`][imgui-widgets], [`imgui_tables.cpp`][imgui-tables]. Divergence from upstream `v1.81` read via the GitHub compare API: 3 commits ahead, 6 files, +157/−91.
- [`canvas-seam-friction.md`][friction] and [`comparison.md`][comparison] — the local claims this page tests.

<!-- References -->

[repo]: https://github.com/ggerganov/imtui
[rev]: https://github.com/ggerganov/imtui/tree/b7c08877e2a43549d2fccc5f78d43ea32153b72a
[readme]: https://github.com/ggerganov/imtui/blob/b7c08877e2a43549d2fccc5f78d43ea32153b72a/README.md
[gitmodules]: https://github.com/ggerganov/imtui/blob/b7c08877e2a43549d2fccc5f78d43ea32153b72a/.gitmodules
[text]: https://github.com/ggerganov/imtui/blob/b7c08877e2a43549d2fccc5f78d43ea32153b72a/src/imtui-impl-text.cpp
[text-h]: https://github.com/ggerganov/imtui/blob/b7c08877e2a43549d2fccc5f78d43ea32153b72a/include/imtui/imtui-impl-text.h
[imtui-h]: https://github.com/ggerganov/imtui/blob/b7c08877e2a43549d2fccc5f78d43ea32153b72a/include/imtui/imtui.h
[ncurses]: https://github.com/ggerganov/imtui/blob/b7c08877e2a43549d2fccc5f78d43ea32153b72a/src/imtui-impl-ncurses.cpp
[ncurses0]: https://github.com/ggerganov/imtui/blob/b7c08877e2a43549d2fccc5f78d43ea32153b72a/examples/ncurses0/main.cpp
[imgui-repo]: https://github.com/ggerganov/imgui
[imgui-rev]: https://github.com/ggerganov/imgui/tree/d413be8c79826bdd708bf4ba9ae7a83180bd55e8
[imgui-h]: https://github.com/ggerganov/imgui/blob/d413be8c79826bdd708bf4ba9ae7a83180bd55e8/imgui.h
[imgui-cpp]: https://github.com/ggerganov/imgui/blob/d413be8c79826bdd708bf4ba9ae7a83180bd55e8/imgui.cpp
[imgui-draw]: https://github.com/ggerganov/imgui/blob/d413be8c79826bdd708bf4ba9ae7a83180bd55e8/imgui_draw.cpp
[imgui-widgets]: https://github.com/ggerganov/imgui/blob/d413be8c79826bdd708bf4ba9ae7a83180bd55e8/imgui_widgets.cpp
[imgui-tables]: https://github.com/ggerganov/imgui/blob/d413be8c79826bdd708bf4ba9ae7a83180bd55e8/imgui_tables.cpp
[friction]: ../../specs/ui-skia/canvas-seam-friction.md
[comparison]: ./comparison.md
