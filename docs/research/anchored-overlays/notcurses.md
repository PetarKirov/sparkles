# Notcurses (C / terminal cell grid)

A rendered-mode terminal library whose only surface abstraction is the _plane_ — an arbitrarily
positioned, arbitrarily sized, independently owned buffer of character cells living in a totally
ordered z-axis — which makes it a primary source for what an overlay stack looks like when there
is no compositor, no [top layer][concepts], no OS popup and no sub-cell precision, and which
correspondingly contains almost no [placement][concepts] engine at all.

| Field         | Value                                                                                                                                                                                                                           |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language      | C (C17); the test suite is C++ (doctest)                                                                                                                                                                                        |
| License       | Apache-2.0                                                                                                                                                                                                                      |
| Repository    | [`dankamongmen/notcurses`][repo]                                                                                                                                                                                                |
| Documentation | In-repo man pages under [`doc/man/`][man] — `notcurses_plane.3.md`, `notcurses_pile.3.md`, `notcurses_render.3.md`, `notcurses_menu.3.md`. Every claim below is an implementation reading unless it explicitly cites a man page |
| Category      | Terminal / cell grid                                                                                                                                                                                                            |
| Surface model | in-canvas. One framebuffer, one terminal. There is no OS popup of any kind anywhere in the tree; a "popup" is a plane whose rectangle happens to overlap another plane's                                                        |
| Version       | 3.0.17 (`CMakeLists.txt:2`)                                                                                                                                                                                                     |
| Revision read | `b26048eebc74d5d254717d3332fa484718f9efe6`                                                                                                                                                                                      |

> [!NOTE]
> Nothing was built or executed. The clone is read-only and no compilation, test run or binary
> invocation happened; every behavioural statement below is a source reading at the pinned
> revision. Where a statement is an inference from structure rather than an observation, it is
> marked as such in the prose.

## Overview

### What it solves

Notcurses solves _composition_ for a character grid: many independently owned rectangles of cells,
freely overlapping, freely reordered, rasterized into one terminal with a minimal byte stream. The
model is stated in five sentences at the top of `src/lib/internal.h`, and the last of them is the
one that matters for an overlay toolkit:

> A plane is memory for some rectilinear virtual window, plus current cursor state for that
> window, and part of a pile. Each pile has a total order along its z-axis. Functions update these
> virtual planes over a series of API calls. Eventually, notcurses_render() is called. We then do a
> depth buffer blit of updated cells. A cell is updated if the topmost plane including that cell
> updates it, not simply if any plane updates it.
>
> — [`src/lib/internal.h:62-67`][internal-model]

"The topmost plane including that cell" is exactly the invariant a display-list toolkit needs when
_front to back_ means _later in the list_. Everything the library does about overlays follows from
it, and everything it does **not** do follows from what that sentence leaves unsaid: nothing about
what a plane is anchored to, nothing about what happens when it does not fit.

### Design philosophy

Three separations characterise the design.

**Order is not ownership.** Each plane sits simultaneously in a flat doubly-linked z list
(`above`/`below`) and in a binding forest (`boundto`/`blist`/`bnext`/`bprev`), and the two are
independent structures over the same nodes ([`internal.h:91-104`][internal-links]). The tree
governs coordinate translation, resize cascade, family moves and destruction; the list alone
governs paint.

**Composition is per-attribute.** For each screen cell the glyph, the foreground channel and the
background channel are resolved by three separate, independently terminating descents of the
z-axis, so one cell's content may originate from three different planes
([`render.c:302`, `:328`, `:359`][render-paint]).

**Translucency is a mode, not a fraction.** Four alpha modes occupy two bits of an existing channel
word, ordered so that `alpha > NCALPHA_OPAQUE` is the entire "still searching" predicate:

```c
// background cannot be highcontrast, only foreground
#define NCALPHA_HIGHCONTRAST    0x30000000ull
#define NCALPHA_TRANSPARENT     0x20000000ull
#define NCALPHA_BLEND           0x10000000ull
#define NCALPHA_OPAQUE          0x00000000ull
```

— [`include/notcurses/notcurses.h:104-108`][alpha-modes]

There is no opacity value anywhere in the API. `NCALPHA_BLEND` is an equal-weight running mean over
every contributing plane down to the first opaque one, not a src-over composite.

What the library deliberately lacks is equally instructive, and most of this page's sixteen
dimensions record an absence: there is no anchor concept, no side/fallback placement engine beyond
one clamp, no clipping ancestors, no arrow, no timers, no focus, no modality, no hide flag, no
accessibility layer and no animation. The widgets (`ncmenu`, `ncselector`, `ncreader`) are thin,
click-on-**release**, chain-of-responsibility consumers of one undirected input stream.

## How it works

A `notcurses` context owns one or more **piles**; each pile owns a totally ordered stack of
**planes**; each plane owns a heap `nccell* fb` plus an `egcpool` for extended grapheme clusters,
and stores its origin as terminal-absolute integers:

```c
nccell* fb;            // "framebuffer" of character cells
int absx, absy;        // origin of the plane relative to the pile's origin
unsigned lenx, leny;   // size of the plane, [0..len{x,y}) is addressable
struct ncplane* above; // plane above us, NULL if we're on top
struct ncplane* below; // plane below us, NULL if we're on bottom
struct ncplane* boundto;// plane to which we are bound (ourself for roots)
```

— condensed from [`src/lib/internal.h:77-104`][internal-links]

A frame is two phases. **Render** (`ncpile_render_internal`, [`render.c:1496`][render-pile])
allocates one `struct crender` accumulator per screen cell, initialises it to
`fg = bg = NCALPHA_TRANSPARENT`, `blends = 0`, `p = NULL` (`init_rvec`,
[`render.c:405`][render-init]), then walks the pile from `top` to `bottom` calling `paint()` on
each plane with the destination rect always set to the **whole pile viewport**:

```c
paint(pl, rvec, p->dimy, p->dimx, 0, 0, ...);
```

— [`src/lib/render.c:1502`][render-pile]

**Postpaint** ([`render.c:501`][render-postpaint]) then walks the solved accumulator, resolves
deferred `NCALPHA_HIGHCONTRAST`, substitutes the terminal default for anything still transparent,
and compares each cell against `nc->lastframe`; only a genuine difference sets `crender->s.damaged`
([`render.c:448`][render-postcell]). Rasterization emits escape sequences for damaged cells only.
Both phases run without a tty: `ncpile_render_to_buffer`
([`render.c:1597`][render-to-buffer]) and `ncpile_render_to_file` execute the identical pipeline
into memory — the recording-canvas property, present and exercised.

Because paint is a full walk of every plane every frame and damage is a post-hoc whole-frame diff,
_moving_ an overlay costs nothing at composition time: `ncplane_move_yx` mutates two integers and
DFS-applies the same delta to the bound subtree ([`notcurses.c:2417`][move-yx]). The price is paid
at output, and only for cells that actually changed.

## The analysis spine

### 1. Anchor model

_Partial — there is no anchor abstraction._ A plane's position **is** `int absx, absy`, absolute in
the pile's (terminal's) frame ([`internal.h:83`][internal-links]). Parent-relative coordinates are
derived at query time: `ncplane_y()` returns `absy` for a root plane and `absy - boundto->absy`
otherwise. The "anchor" is therefore a plain comparable value pair and the parent link is a plain
pointer; a plane does not know what it points **at**, only what it is bound **to**, and binding
carries no positional intent.

**Algorithm.** `anchor := (absy, absx)`, the plane's own origin. Query relative:
`rel = abs - boundto.abs` (root: `rel = abs`). Move: compute `(dy, dx) = target - current` in the
chosen frame, apply to self, then DFS over `blist` applying the same delta
(`move_bound_planes`, [`notcurses.c:2405`][move-yx]). Translate a point from frame A to frame B:
`p += A.abs - B.abs` — which is all `ncplane_translate` does. Alignment
(`NCPLANE_OPTION_HORALIGNED` / `VERALIGNED`) is a one-shot solve into an absolute origin at plane
creation; the align mode is retained only so `ncplane_resize_realign` can re-solve on demand.

Anchor-follows-parent is maintained by **mutation, not by a constraint re-solved at render**, so it
costs `O(descendants)` at move time and exactly zero per frame. Absolute is the source of truth and
the derived relative offset may go negative: `src/tests/piles.cpp:283` (`ReparentUpdatePos`)
reparents a plane at absolute `(10,10)` under one at `(20,20)` and asserts the absolute position is
unchanged while the relative becomes `(-10,-10)`.

There is no element / rect / text-range / multi-rect / [virtual anchor][concepts] vocabulary, no
detached-trigger-versus-anchor distinction, and no many-triggers-one-popup relation.

**Where it lives.** The plane data structure plus three small library functions. Nothing
platform-level.

**Degradation.** Survives every degradation axis unchanged: pure integer arithmetic, involving no
OS window, no hover, no script, no key release and no sub-cell precision.

### 2. Placement model

_Partial, and this is the subject's weakest dimension._ There is no side list, no preferred/fallback
ordering, no [flip][concepts] and no gravity. Three unrelated pieces exist.

1. `notcurses_align(availu, align, u)` returns `0`, `(avail-u)/2` or `avail-u` for LEFT / CENTER /
   RIGHT, where TOP and BOTTOM are `#define` aliases of LEFT and RIGHT. It is evaluated against a
   parent plane's dimension, once, at creation.
2. `ncplane_resize_placewithin` ([`notcurses.c:2686`][placewithin]) is the only shift-into-bounds
   primitive in the library. It pulls the bottom and right edges inside the boundary first and the
   top and left afterwards, so an oversized child pins to the top-left — the source says so:
   _"this will prefer upper-left material if the child plane is larger than the parent"_.
3. `ncmenu_unroll` clamps its drop-down against the right edge and nothing else
   ([`menu.c:473-475`][menu-clamp]):

   ```c
   if(xpos + width >= (int)dimx){
     xpos = dimx - (width + 2);
   }
   ```

   A [shift][concepts], never a flip; no lower clamp at column 0; an unexplained two-cell inset.
   The vertical side is a static policy bit (`ncm->bottom`), never computed.

> [!WARNING]
> `ncplane_resize_placewithin` compares `ncplane_abs_y(n)` — a **terminal-absolute** origin —
> against `ncplane_dim_y(n->boundto)`, the boundary plane's **size** rather than its extent
> ([`notcurses.c:2693`, `:2701`][placewithin]). Read literally, that is correct only when the
> boundary plane's own origin is `(0,0)`. This is a reading-level claim: the sole in-tree caller
> binds to the standard plane (`src/demo/hud.c:435`), which masks the difference, and `grep` finds
> no test exercising it, so it was not confirmed empirically.

**Algorithm.**

```text
align(avail, u, mode) = { 0 | (avail-u)/2 | avail-u }

placewithin(n):
    if abs.y + dim.y > parent.dim.y: move_rel(-(abs.y+dim.y-parent.dim.y), 0)
    if abs.x + dim.x > parent.dim.x: move_rel(0, parent.dim.x-(abs.x+dim.x))
    if abs.y < 0:                    move_rel(-abs.y, 0)
    if abs.x < 0:                    move_rel(0, -abs.x)

menu:
    xpos = section.xoff  (or dimx + xoff - 2 when right-aligned)
    if xpos + width >= dimx: xpos = dimx - (width + 2)
    ypos = bottom ? dimy - height - 1 : 1
```

Nothing exists for RTL, writing modes, viewport padding, safe-area insets, work areas, multiple
monitors or IME/virtual-keyboard avoidance. Terminal margins (`nc->margin_t/b/l/r`) exist but only
shrink the standard plane at initialisation ([`render.c:80`][render-margins]) and are invisible to
every placement site.

**Where it lives.** Entirely in the library — and notably, `ncplane_resize_placewithin` is exposed
as a **resize callback** the application hangs off a plane, so placement policy is a function
pointer invoked by the resize cascade, never a per-frame solve.

**Degradation.** Everything here is integer arithmetic with no measurement API and no hover, so it
survives every target. The instructive gap is the Android soft-keyboard inset: notcurses has no
concept of a viewport boundary that is not the terminal edge, which is precisely why a sparkles
design must make insets an **input** to placement rather than something the solver discovers.

### 3. Collision & geometry engine

_Partial, and inverted relative to the DOM subjects: there are **no clipping ancestors**._ Every
plane is painted against the whole pile viewport ([`render.c:1502`][render-pile]); a bound child is
**not** clipped by its parent, and the terminal is the only [clipping boundary][concepts].
Overflow "detection" is consequently not a phase at all — `paint()`'s per-row and per-column
guards simply drop out-of-range cells (`if(absy >= dstleny || absy < 0) break;`,
[`render.c:283-296`][render-paint]).

There are no scroll containers as clip regions, no transforms, no zoom, no device pixel ratio, no
fractional coordinates, and no observer / polling / frame-callback tracking of any kind: geometry
is re-read from `absy`/`absx`/`leny`/`lenx` on every render.

**Algorithm.** The composition kernel, from [`render.c:236`][render-paint]:

```text
render(pile):
  rvec[dimy*dimx] := { fg=bg=TRANSPARENT, blends=0, p=NULL }
  for pl := pile.top downto pile.bottom:
    for each cell (y,x) of pl intersecting [0,dimy) x [0,dimx):
      if acc.fgalpha > OPAQUE: acc.fg := blend(acc.fg, src.fg, fgblends)
      if acc.bgalpha > OPAQUE: acc.bg := blend(acc.bg, src.bg, bgblends)
      if acc.p == NULL and src.gcluster != 0:
          acc.glyph/style/width := src ; acc.p := pl
  postpaint: resolve HIGHCONTRAST, substitute terminal default for TRANSPARENT,
             diff against lastframe, mark damage
```

The cost is `O(Σ on-screen area of every plane)` per frame, **not** `O(cells × depth-to-opaque)`:
there is no early exit when a cell is fully solved and none when the whole accumulator is solved.
Per-cell work is skipped only by the three cheap predicates above. (This is a structural reading of
the loop shape at [`render.c:1496-1512`][render-pile] and `paint()`, not a measurement.)

The part that generalises off the substrate is a byproduct: `crender->p` records **which plane
supplied the glyph** for each screen cell ([`render.c:392`][render-paint]), and wide-glyph
continuation cells are attributed too. Painting therefore produces a complete per-cell owner map
for free — the same "flat derived hit list in reverse paint order" a canvas toolkit needs, obtained
without a second structure that could disagree with what was painted.

**Where it lives.** The framework kernel: `src/lib/render.c` — `paint()`,
`ncpile_render_internal()`, `postpaint()`. Nothing in the platform, nothing in the terminal.

**Degradation.** The whole pipeline runs with no tty at all via `ncpile_render_to_buffer`
([`render.c:1597`][render-to-buffer]) and `ncpile_render_to_file`, so composition and geometry are
assertable headlessly.

### 4. Arrow / caret geometry

_Not applicable — there is no arrow, tail, beak, pointer or drop shadow in the tree._ A
case-insensitive `grep` for "shadow" over the `.c`, `.h` and `.md` sources returns zero hits, and
no widget draws a connector: `ncmenu` paints its unrolled body as a plain rounded box
(`ncplane_rounded_box_sized`, [`menu.c:479`][menu-clamp]) with no visual link back to the header
that opened it.

The cell-grid substitute is not a triangle, it is a **border-glyph swap**. `ncselector`, whose
title "riser" sits atop the body, patches box-drawing junction glyphs at the seam so the two
rectangles read as one connected shape — `┤` where the riser meets the right wall, `┬` where the
body starts under the riser, `┴` where the riser is narrower than the body — with ASCII fallbacks
(`|`, `-`) chosen per site by `notcurses_canutf8` ([`selector.c:121-142`][selector-riser]).

**Algorithm.** Given two rects sharing an edge, emit for each cell on that edge the box-drawing
character whose stroke set is the union of the strokes the two rects require there; fall back to
`-` / `|` when UTF-8 is unavailable. It is computed inline inside the draw routine and is **not**
exposed as data: no side, offset or size value is emitted for a styling layer, and no arrow offset
is ever fed back into placement.

**Where it lives.** Per-widget draw code (`selector.c`), hand-written. There is no shared junction
solver; sparkles' own procedural `drawBox` in `sparkles:raylib-text` is a closer analogue than
anything here.

**Degradation.** An arrow is meaningless at cell granularity, so the absence costs nothing. The
junction-glyph technique needs no hover, no script, no key release and no sub-cell precision, and
degrades to `-` / `|` on ASCII-only terminals.

### 5. Trigger semantics

_Partial._ `ncmenu` is the only anchored-surface trigger machine in the library, and it recognises
exactly three things ([`menu.c:707-752`][menu-input]): BUTTON1 **release** on a section header
(toggle), BUTTON1 release anywhere else (roll up), and a section shortcut matched with
`ncinput_equal_p`. Every other event whose `evtype == NCTYPE_RELEASE` is rejected by an early
`return false` at [`menu.c:739`][menu-input].

Hover cannot be a trigger here, structurally: a pure motion report is decoded as
`id = NCKEY_MOTION` with `evtype = NCTYPE_RELEASE` ([`in.c:612-617`][in-motion]), so motion is
discarded by that same early bail.

> [!IMPORTANT]
> Two documented `ncmenu` features have no implementation at this revision. The header lists
> _"mouse movement over a hidden menu"_ among the inputs `ncmenu_offer_input` handles
> ([`notcurses.h:4183`][menu-doc]), and `NCMENU_OPTION_HIDING` is defined as _"hide the menu when
> not unrolled"_ ([`notcurses.h:4132`][menu-hiding]) — but that flag appears exactly once in
> `src/lib/menu.c`, inside a flag-range warning, and there is no motion handling at all.

There are no focus or focus-visible triggers (there is no focus), no long press, no context-menu
trigger, no pointer-type distinction and no AT-initiated opening. Modifier matching is exact rather
than lenient: since 3.0.7 a section shortcut must declare its expected modifiers or
`ncmenu_create` fails (`NEWS.md`).

**Algorithm.** Multiple triggers are combined by **total ordering, not arbitration**. Each widget
exposes `bool X_offer_input(X*, const ncinput*)` returning "consumed", and the application calls
them in a fixed sequence, stopping at the first `true`. With a single input stream
(`notcurses_get`), one pointer and no concurrency, races are structurally impossible rather than
resolved.

**Where it lives.** Widget code (`menu.c`) for the semantics, `src/lib/in.c` for the decode, and
the **application** for dispatch order.

**Degradation.** Release-only clicking is what a terminal already delivers, so nothing is lost.
Hover is absent by construction, so a no-hover target loses nothing notcurses had. Key releases
arrive only under the Kitty keyboard protocol ([`in.c`][in-motion] decode path) and no overlay
widget consumes them, so nothing here depends on key release. On a script-free static-HTML tier the
toggle-on-click semantics map onto `<details>` / `:checked`; the shortcut-key path does not.

### 6. Timing

_Not applicable — and the absence is the finding._ There is no timing layer anywhere in the overlay
path: no initial delay, no close delay, no [warm-up][concepts], no [cool-down][concepts] or
skip-delay group, no shared provider, no singleton, no re-entry grace and no maximum display
duration. `menu.c`, `selector.c`, `reader.c` and the multiselector contain no clock call of any
kind; the only `clock_gettime` uses in the library are stats instrumentation around render and
raster, plus the input timeout inside `notcurses_get`.

Opening and closing are instantaneous, synchronous and caller-driven: `ncmenu_unroll` erases and
redraws in the calling thread and returns.

**Algorithm.** The implied machine has two states and no timers: `CLOSED` (`unrolledsection == -1`)
and `OPEN(i)`, with the item highlight folded into a second small integer per section
(`itemselected`, `-1` for none). Transitions: header click or shortcut → `OPEN(i)`; header click
while `OPEN(i)` → `CLOSED`; click elsewhere → `CLOSED`; `ESC` → `CLOSED`; LEFT/RIGHT while open →
`OPEN(next enabled)` via `ncmenu_prevsection`/`ncmenu_nextsection`
([`menu.c:563`][menu-nextsection], which skip disabled sections and wrap); UP/DOWN steps
`itemselected`; disabling the last enabled item of the open section → `CLOSED`. Every transition
re-runs the draw from that one integer.

**Where it lives.** Nowhere — unimplemented. Any delay or debounce policy would have to be the
application's, layered above `ncmenu_offer_input`.

**Degradation.** Trivially survives every target because it does nothing. For a script-free HTML
target that is the forced answer anyway; for TUI and GUI it means notcurses offers no reusable
timing design, and a sparkles anchored-overlay primitive must invent its own.

### 7. Interactive hover

_Not applicable, and the structural reason is more interesting than the absence._ There are no
hover triggers (dimension 5) and — decisively — **there are no submenus**: `struct ncmenu_item` is

```c
struct ncmenu_item {
  const char* desc;     // utf-8 menu item, NULL for horizontal separator
  ncinput shortcut;     // shortcut, all should be distinct
};
```

— [`include/notcurses/notcurses.h:4119-4122`][menu-item]

with no nested item list. `ncmenu` is exactly two levels — a bar plus one flat body — and a `NULL`
`desc` is only a horizontal separator. There is therefore no [safe polygon][concepts], no pointer
bridge, no diagonal menu-aim, no trajectory heuristic, no debounce and no nested-surface tolerance.

More usefully: **the unrolled body is drawn into the same plane as the menu bar.** `ncmenu_create`
sizes one plane to the full parent width and to the worst-case section height computed up front,
gives it a fully transparent base cell so the unused area shows whatever lies beneath, and
`ncmenu_unroll` simply draws the box and items into that same buffer
([`menu.c:466-500`][menu-clamp]). Trigger and content share one rectangle.

**Algorithm.** Not applicable. The travel cost in whole cells is **zero** because the geometry is
degenerate: header row and body are contiguous rows of one plane, and the item region begins at the
row after the box top.

**Where it lives.** Designed away by the single-plane menu layout in `menu.c`.

**Degradation.** Nothing to degrade. The single-surface trick transfers directly: reserving the
worst-case popup extent inside the trigger's own surface removes the safe-polygon problem entirely,
at the cost of a construction-time maximum size.

### 8. Dismissal

_Partial, but the implemented parts are clean._ Everything lives inside `ncmenu_offer_input` and
`ncmenu_rollup` ([`menu.c:707-810`][menu-input]):

- **Escape** rolls up.
- **Trigger re-activation** is a toggle: `if(i < 0 || i == n->unrolledsection) ncmenu_rollup(n);`.
- **Click outside**, defined as any BUTTON1 release that is neither a valid item hit nor on the
  header row.
- **Child-closes-parent unified**: `ncmenu_unroll` begins with `ncmenu_rollup(n)`
  ([`menu.c:453`][menu-clamp]), so "open", "switch section" and "close then open" are literally one
  code path.
- **State-driven dismissal**: disabling the last enabled item of the open section rolls it up.
- **Resize does not dismiss.** `resize_menu` ([`menu.c:361-375`][menu-resize]) resizes the plane,
  erases it and re-unrolls the same section — reposition-on-resize, not close-on-resize.

Not implemented: focus-outside (there is no focus), window or application deactivation, scroll,
anchor-hidden, anchor-removed, navigation, touch-outside, and parent-closing cascades.

**Algorithm.** `dismiss-on-outside` := on BUTTON1 release, translate the absolute `(y,x)` into the
overlay plane's frame with `ncplane_translate_abs`; if that fails (outside the rect) **or** the
point lands outside the item sub-rect **and** outside the header row, roll up. No capture, no
[grab][concepts], no global outside-listener — a rectangle test performed by the widget on an event
the application handed it.

> [!NOTE]
> Every dismissal and selection in the library keys on **release**, never on press and never on a
> press/release pair ([`menu.c:678`][menu-input], [`menu.c:710`][menu-input], `selector.c:525`).
> `src/lib/selector.c:538` carries the standing admission: _"we probably only want to consider it a
> click if both the release and the depress happened to be on us. for now, just check release."_ A
> drag beginning outside and ending inside therefore counts as a click.

**Where it lives.** Widget code, using exactly one library geometry primitive
(`ncplane_translate_abs`). No platform involvement.

**Degradation.** Because dismissal is a rectangle test on an ordinary event rather than a pointer
grab, it needs only events that never leave the surface — the situation a single-surface toolkit is
already in. Release-only means it works where press/release pairing is unavailable. On Android a
system back key slots exactly where `ESC` does. On static HTML the toggle survives; outside-click
does not.

### 9. Focus

_Not applicable — notcurses has no focus concept._ There is no focused-plane pointer in
`struct notcurses`, no tab order, no [focus scope][concepts], no trap, no containment, no
restoration and no distinction whatsoever between tooltip, popover, menu and dialog: there is one
mechanism (a plane) and all four are it, wearing different content.

Keyboard input is a single undirected stream from `notcurses_get`; which widget sees it is decided
by the application's call order into the `*_offer_input` functions. The only focus-adjacent state is
the terminal's hardware cursor — `notcurses_cursor_enable(nc, y, x)` records a desired absolute
position replayed after every rasterization ([`render.c:1740`][render-cursor]),
`notcurses_cursor_disable` clears it, and `ncreader` drives it as its text caret.

There is also no pointer-opened versus keyboard-opened difference: `ncmenu_unroll` behaves
identically for a click and for a shortcut, and both auto-select the first enabled item
(`if(sec->itemselected < 0){ sec->itemselected = i; }`, [`menu.c:490-491`][menu-clamp]). Initial
highlight is unconditionally the first enabled item, never suppressed for a pointer open.

**Algorithm.** Not applicable. The de-facto rule is "whoever the application asks first gets the
key"; auto-highlight on open is "first item with `!disabled`".

**Where it lives.** The application, deliberately — the library performs no event routing.

**Degradation.** Nothing to lose. But this is the subject's clearest gap against the brief: keeping
tooltip, popover, menu and dialog distinct is exactly what notcurses declines to do, and its widgets
consequently cannot express modal or focus-containing behaviour at all.

### 10. Layering & portals

_Yes — the core contribution._ Two independent structures over the same nodes.

**The z-axis.** Per pile, a flat doubly-linked total order via `above`/`below`
([`internal.h:91-93`][internal-links]) with `top`/`bottom` anchors on the pile. The public API is
`ncplane_move_above(n, target)` and `ncplane_move_below(n, target)`, each a splice-out/splice-in
where a `NULL` target sentinel means "the far end" — which is why `ncplane_move_top(n)` is
_literally_ `ncplane_move_below(n, NULL)` and `ncplane_move_bottom` is `ncplane_move_above(n, NULL)`
([`notcurses.h:1951-1962`][move-top]). New planes always land on top; cross-pile moves are refused.

**The binding forest.** `boundto` (self for roots), `blist`, `bnext`, `bprev`
([`internal.h:98-104`][internal-links]). Binding governs coordinate translation, resize cascade,
family moves and cascading destruction — **and nothing else**. It has zero effect on paint order.

**Reconciliation.** `ncplane_move_family_above` / `_below` move the root, then re-splice every plane
for which `ncplane_descendant_p` holds, preserving mutual order. The header states the exact
outcome, and note that the parent lands **above** its children:

> // Splice ncplane 'n' and its bound planes out of the z-buffer, and reinsert
> // them above or below 'targ'. Relative order will be maintained between the
> // reinserted planes. For a plane E bound to C, with z-ordering A B C D E,
> // moving the C family to the top results in C E A B D, while moving it to
> // the bottom results in A B D C E.
>
> — [`include/notcurses/notcurses.h:1964-1968`][move-family]

`NEWS.md` records that this looped forever until 3.0.9 — evidence that reconciling a tree with a
flat order is genuinely fiddly, and the debug dumper carries explicit consistency assertions for
both link sets.

**Piles** exist for concurrency, not layering — _"completely distinct with regards to
thread-safety"_ ([`internal.h:298-301`][internal-links]) — and only one is rasterized at a time:

> Piles are collections of **ncplane**s, independent from one another for purposes of rendering and
> also thread-safety. While only one pile can be rasterized (written to the display) at a time,
> arbitrary concurrent actions can be safely performed on distinct piles. Piles do not compose:
> rasterizing a pile destroys any overlapping material.
>
> — [`doc/man/man3/notcurses_pile.3.md:26-30`][pile-man]

`ncpile` is not exported; it is reachable only through a member plane.

**The consequence.** There is no `ncplane_hide()`. Visibility is pile membership, and the idiom is
`ncplane_reparent(p, p)` to detach into a private pile, then `ncplane_reparent(p, stdplane)` plus
`ncplane_move_top(p)` to reattach — the round trip does **not** preserve z-order, so the caller must
re-assert it ([`src/demo/hud.c:211-217`][hud-hide]).

Absent: z-index numbers, stacking contexts, clipping escape (there is nothing to escape, see
dimension 3) and a top layer — because there is only ever one framebuffer.

**Algorithm.**

```text
move_above(n, t):
    if t == NULL: splice n to pile.bottom
    else: unlink n (repairing pile.top/bottom), relink between t and t.above

move_family_above(n, t):
    remember n's old above/below
    move_above(n, t); targ := n
    walk upward from old-above: for each d with descendant_p(d, n): move_above(d, targ); targ := d
    walk downward from old-below: same, stopping at the topmost plane placed by pass 1
```

**Where it lives.** Library kernel — the z-splice functions in `src/lib/notcurses.c` plus the data
model in `src/lib/internal.h`. Public: the move/query functions and the plane pointer.
Implementation detail: `ncpile` itself, the `above`/`below` links, `crender`, and the render order.

**Degradation.** Everything here works with no OS window, no compositor and no hover — it never used
any of them. A complete z-model needs nothing but a linked list and a paint loop. The one thing that
does not transfer is piles-as-concurrency-domains, which presuppose a threaded renderer; for a
single-threaded canvas toolkit a pile collapses to "the one display list" and "in a private pile"
collapses to "not in the display list".

### 11. Modality

_Not applicable._ There is no modal flag, no [light dismiss][concepts] policy, no scrim or dim
primitive, no background pointer or keyboard blocking, no click-through control and no accessibility
modal bit. The structural reason is that **the library performs no event routing**: `notcurses_get`
hands the application one event, and no plane can intercept, block or consume anything on another
plane's behalf. A plane can occlude _visually_ — an opaque plane at the top of the pile wins the
z-walk for every cell it covers — but occlusion has no input consequence whatsoever.

The nearest available scrim is a full-screen glyph-free plane with `NCALPHA_BLEND` channels, which
averages the whole screen toward the scrim colour; `src/demo/hud.c:444` does exactly this with
`ncplane_set_bg_alpha(n, NCALPHA_BLEND)` to get a see-through panel. That is dimming-as-composition,
and for a cell grid it is a genuinely correct primitive.

**Algorithm.** Not applicable as policy. Visual dim := place a glyph-free plane with background
alpha `BLEND` above the content; every covered cell's background becomes the mean of the scrim
colour and the layers beneath ([`internal.h:1342`][blend]).

**Where it lives.** Nowhere as policy; the visual half lives in the compositor's alpha model.

**Degradation.** Since there is no pointer grab and no routing to begin with, none of this depends
on an OS window — and none of it exists to lose. The warning for a plane-shaped design is that
modality and input blocking are the one dimension a plane model contributes nothing to; they must be
built entirely in the hit-test layer.

### 12. Adaptive presentation

_Partial, at a lower level than the brief asks about._ Nothing adapts a popover into a sheet, a
hover into a long-press, or a tooltip into a teaching tip; no such layer exists. But notcurses owns
a large, disciplined capability-adaptation layer **one level down**, and the owning layer is
unambiguous: the render/raster layer, keyed off terminal capabilities probed once at initialisation
into `tinfo` (`src/lib/termdesc.c`) — never the widget, never the layout.

Widgets consult capabilities only to pick a **glyph**, never to change geometry:
[`selector.c:121-142`][selector-riser] chooses `┤`/`┬`/`┴` versus `|`/`-` on `notcurses_canutf8`,
and the test suite branches its own expectations on the same predicate rather than assuming one
answer (`src/tests/stacking.cpp:72-80` runs a `notcurses_canutf8` conditional over the composited
read-back). The capability ladder
below is rich — quadrants, sextants, the octant blitter `NCBLIT_4x2` gated by
`notcurses_canoctant()`, sixel, Kitty graphics — and `NCBLIT_DEFAULT` resolves differently per
terminal.

**Algorithm.** At init, probe the terminal into `tinfo` (encoding, quadrant/sextant/octant support,
bitmap protocol, mouse protocol, colour depth). At draw time each site asks a boolean predicate
(`notcurses_canutf8`, `notcurses_canoctant`, …) and selects between glyph sets of **equal cell
footprint**. Geometry is computed once, independent of the answer.

**Where it lives.** `src/lib/termdesc.c` for the probe, per-call-site predicates in widget draw
routines. There is no separate "adaptive" layer.

**Degradation.** This dimension already _is_ the degradation pattern a multi-backend toolkit wants:
hold layout fixed in cells and vary only the glyph and attribute vocabulary per backend. What
notcurses does not provide is the higher-level touch / hover / compact adaptation the brief asks
about — that decision would sit in a view layer above anything notcurses models.

### 13. Accessibility

_Not applicable as an API, but not empty._ There is no role, no name/description distinction, no
semantic tree, no AT-SPI / UIA / VoiceOver / TalkBack bridge and no WCAG-facing timing policy. What
a terminal grid can honestly expose is the rendered text itself, and notcurses exposes it queryably:
`notcurses_at_yx(nc, y, x, &stylemask, &channels)` returns a heap copy of the **solved** extended
grapheme cluster at any screen cell, in `O(1)`, out of `nc->lastframe`
([`render.c:1627`][render-atyx]) — and returns the glyph even for the secondary column of a
wide character, as `notcurses_render.3.md` documents. `ncplane_at_yx` does the same per plane.

Because a terminal screen reader consumes the emitted character stream, correctness of the
rasterized text _is_ the whole accessibility story here. The one genuinely accessibility-shaped
primitive is `NCALPHA_HIGHCONTRAST`: foreground-only (enforced at
[`notcurses.h:368`][alpha-enforce]) and deliberately resolved **late** — after the entire z-walk, in
`lock_in_highcontrast` ([`render.c:418`][render-hc]) — against the **final composited background**.

**Algorithm.**

```c
if(r + g + b < 320){
  ncchannel_set(&conrgb, 0xffffff);
}else{
  ncchannel_set(&conrgb, 0);
}
```

— [`src/lib/render.c:159-163`][render-hc-fn]

The contrast colour is then blended against the current foreground at weight 3:1, after which the
saved pre-highcontrast foreground is re-blended with its original blend count, so foreground shading
contributed by planes **above** the highcontrast declaration is not lost. A legibility guarantee
expressed as a per-cell composition mode is something no theme-time rule can provide, because at
theme time you do not know what the overlay will land on.

**Where it lives.** The rendering kernel — `highcontrast()` / `lock_in_highcontrast` for the
guarantee, `notcurses_at_yx` for read-back. Nothing anywhere else.

**Degradation.** Both pieces are pure functions of the composited frame, so they survive with no
window, no hover, no script and no key release. `notcurses_at_yx` combined with
`ncpile_render_to_buffer` is precisely the assertion surface a recording canvas needs. What a grid
cannot honestly expose — role, modality, live-region semantics — notcurses correctly does not
pretend to.

### 14. Animation

_Not applicable._ There is no animation system, no enter/exit transition, no [transform
origin][concepts], no spring and no reduced-motion respect. To the question the brief asks
directly: **no geometry metadata is emitted for a styling layer.** The compositor produces solved
cells and a damage map and publishes no side, alignment or placement fact about any plane to anyone.

The only time-varying visual primitive is `src/lib/fade.c`, which steps a whole plane's channels
between two colour states over a caller-supplied duration by rewriting cells and re-rendering —
content animation, not presentation. Animation is cheap but absent for an architectural reason:
`ncplane_move_yx` mutates two integers plus a DFS over bound children
([`notcurses.c:2417`][move-yx]) and recomposition happens next frame anyway, so sliding an overlay
costs nothing and any application can animate with move-plus-render in a loop. The library simply
declines to own the loop.

**Algorithm.** Not applicable. Move-per-frame animation is
`ncplane_move_yx(p, y(t), x(t)); ncpile_render(p); ncpile_rasterize(p);` — `O(Σ plane areas)` for
render plus `O(changed cells)` for raster, per tick.

**Where it lives.** `src/lib/fade.c` for colour fades; otherwise the application.

**Degradation.** Nothing to degrade. The relevant negative is that, emitting no placement metadata,
notcurses is no guide for the "expose side and alignment so the styling layer can set a transform
origin" pattern. The structure suggests the honest cell-grid equivalent would be emitting the
resolved integer rect together with which edge it was clamped against — but that is an inference
from the shape of the compositor, not something the source does.

### 15. State architecture

_Partial: ad-hoc per-widget C structs, uncontrolled, mutated in place — with one property worth
stealing._ **The entire open/closed condition is one integer.** `ncmenu.unrolledsection` is `-1` for
closed and a section index otherwise ([`menu.c:29`][menu-state]), and the highlight is a second
small integer per section (`itemselected`, `-1` for none). There are no reducers, no state-machine
library, no event-driven controller and no controlled/uncontrolled split.

The rendering discipline is the interesting part: the plane is a **retained** buffer, but it is
**re-derived from the state value on every change**. `ncmenu_unroll` rolls up (erase plus redraw
header) then repaints the whole body from scratch, and `resize_menu` implements resize as literally
`ncplane_erase(n); ncmenu_unroll(menu, unrolled);` ([`menu.c:369-375`][menu-resize]). That is a view
function of a tiny state, re-run on change, into a retained target — the same shape as sparkles'
`view() → layout() → buildDisplayList()`.

Ownership is enforced: `ncplane_set_widget(plane, w, destructor)`
([`internal.h:461`][set-widget]) permits exactly one widget per plane and hangs a destructor off it,
so destroying either side tears down both.

Would this survive a value-semantics `@nogc` D toolkit? The **state** would, trivially — every
widget's presentation state is a handful of `int`s, a POD struct with no allocation. The **buffer**
would not: each plane owns a heap `nccell* fb` plus an `egcpool`
([`internal.h:77-87`][internal-links]), and the model is pointer-identity-based throughout — planes
are compared by address (`crender->p`), spliced by pointer, reparented by pointer. Porting means
replacing "plane = identity plus owned buffer" with "overlay = a value describing a rect, a z
position and a content source", letting the display list own the cells.

**Algorithm.** `state := { int unrolledsection; per-section int itemselected; }`. On every mutating
call: erase the target region, re-run the draw from state. There is no diffing at the widget level;
diffing happens once, globally, at postpaint against `lastframe`.

**Where it lives.** Per-widget structs in `src/lib/{menu,selector,reader,reel,tabbed}.c`; the
ownership contract in `internal.h`.

**Degradation.** The one-integer state and the re-derive-on-change discipline survive every target
including a recording canvas, since the draw is a pure function of state plus geometry and
`ncpile_render_to_buffer` makes the result assertable with no tty. Pointer identity and owned heap
buffers are what a value-semantics port must give up.

### 16. Shared infrastructure

_Partial._ There is no shared overlay base type and no common Tooltip/Popover/Menu abstraction — and
the code does not obviously suffer for it, because everything such a base type would share is
already shared by all of them being planes.

Genuinely common across `ncmenu` / `ncselector` / `ncmultiselector` / `ncreader` / `ncreel` /
`nctabbed` / `nctree` / `ncprogbar`:

- the plane itself — buffer, absolute position, z-order, clip-to-screen;
- `ncplane_set_widget(plane, w, destructor)` — the one-widget-per-plane contract with a destructor
  hook, so plane teardown and widget teardown are one operation ([`internal.h:461`][set-widget]);
- the convention `bool X_offer_input(X*, const ncinput*)` returning "consumed", which is the whole
  event architecture ([`menu.c:707`][menu-input], `selector.c:523`, `reader.c:371`);
- the `resizecb` function pointer as the only re-layout hook, with four ready-made policies shipped
  (`ncplane_resize_maximize`, `_marginalized`, `_realign`, `_placewithin`);
- `ncplane_translate_abs` as the universal — and only — hit test.

What merely looks common and correctly stays apart is **surface ownership**. `ncmenu` creates its
own plane, sized once to the worst-case unrolled section and never resized for content;
`ncselector` / `ncmultiselector` / `nctabbed` / `ncreader` are handed a plane and resize it
(`ncplane_resize_simple`), with `ncselector` refusing the standard plane outright — _"won't use the
standard plane, would fail later on resize"_ (`selector.c:281-284`); `ncreel` creates one plane per
tablet. Three incompatible lifecycles, deliberately not unified. Placement policy stays apart too:
the menu hardcodes its clamp, the selector never places itself at all, and only the demo HUD uses
`placewithin`.

**Algorithm.** Not applicable. The factoring rule the subject demonstrates is: share the **surface**
(rect, z, buffer, hit test, resize hook, input-offer convention); do not share **construction**,
**placement policy** or **lifecycle**.

**Where it lives.** `src/lib/internal.h` (`ncplane_set_widget`, translate helpers) plus the plane
API. Everything else is per widget.

**Degradation.** That shared core — rect, z, hit test, resize hook, "did you consume this event" —
needs no window, no hover, no timers, no script and no sub-cell precision. It is the intersection
that survives all of sparkles' targets, which is evidence that an anchored-overlay primitive can be
that small.

## Strengths

- The plane model is a clean primary source for _arbitrary rect + z-order + retained cell buffer,
  moved in `O(1)` without redrawing content_ — demonstrably sufficient with no compositor, no top
  layer and no OS popup.
- Decoupling the flat z-order from the binding tree is a strong idea, and the header documents the
  reconciliation rule with a worked example rather than leaving it implicit.
- The alpha model is small, total and honest about what a cell grid can do: four modes in two bits,
  an ordered encoding making "still searching" one comparison, transparent layers excluded from the
  blend divisor, and a documented admission that terminal-default colours cannot be blended.
- Resolving glyph, foreground and background as three **independent** z-descents is what makes a
  transparent-background overlay show the text beneath it while still tinting the background.
- `NCALPHA_HIGHCONTRAST` is a contrast guarantee expressed as a composition mode resolved against
  the final background — legibility a theme-time rule cannot provide.
- Blitted quadrants deliver correct sub-cell composition for semigraphic layers at four bits per
  cell, with tests pinning both stacking orders (`src/tests/stacking.cpp:84`, `:129`).
- `ncpile_render_to_buffer` / `ncpile_render_to_file` make the whole composition pipeline runnable
  and assertable with no tty.
- Damage is a post-hoc whole-frame diff against a retained `lastframe`, so overlay movement is free
  at composition time and costs only the genuinely changed cells at output time.
- `src/lib/sprite.h` contains an unusually rigorous specification of the overlay-over-bitmap
  problem, including protocol-specific impossibilities.
- Capability variance is absorbed at glyph-selection time with layout held fixed, so one layout
  serves UTF-8, ASCII, quadrant, sextant and octant terminals.

## Weaknesses

- No anchor abstraction: an overlay does not know what it is anchored to, so nothing can re-place it
  when its trigger moves except a manual parent-relative move.
- Placement is essentially unimplemented — one align helper, one shift-into-bounds callback and a
  single hardcoded right-edge clamp in the menu. No flip, no fallback ordering, no preferred sides,
  no insets.
- `ncplane_resize_placewithin` compares a terminal-absolute origin against the boundary plane's size
  rather than its extent, so on a literal reading it is correct only for boundaries at `(0,0)`; the
  sole in-tree caller masks it and no test covers it.
- Two `ncmenu` features are documented and unimplemented: `NCMENU_OPTION_HIDING` and "mouse movement
  over a hidden menu".
- No focus model at all, so tooltip, popover, menu and dialog cannot be distinguished, and no
  modality, scrim policy or input blocking exists.
- No timing layer anywhere, so the subject offers no reusable design for the hover-tooltip problem.
- The compositor computes a per-cell owner (`crender->p`) during paint but the library ships no
  z-order-aware hit test; every widget hand-rolls a single-rectangle test.
- Hiding a plane by reparenting it into its own pile overloads a structural operation with a
  presentational meaning, destroys and creates piles as a side effect, and loses z-order across the
  round trip; there is no way to ask whether a plane is visible.
- Selection is release-only everywhere with press/release pairing explicitly unimplemented
  (`selector.c:538`), so a drag beginning outside and ending inside counts as a click.
- Blend counters are 8-bit bitfields (`internal.h:287-288`); more than 255 contributors over one
  cell would wrap the divisor. INFERENCE — this is arithmetic from the bitfield width, not an
  observed failure; no 256-plane scenario was constructed.
- No accessibility surface beyond reading back rendered text, and no geometry metadata for a styling
  layer.
- Widget surface ownership is inconsistent across the library, with no shared contract.

## Key design decisions and trade-offs

| Decision                                                                                                                                                            | Rationale                                                                                                                                                                                                                                                                                  | Trade-off                                                                                                                                                                                                                                                                                                                                                  |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Separate the **z-order** (a flat total order per pile) from the **ownership tree** (the binding forest), as two independent structures over the same plane objects. | Ownership and paint order answer different questions. The tree must govern coordinate translation, resize cascade, family moves and cascading destruction; the order must govern only who wins each cell. Coupling them would force "a child always paints above its parent".              | Two structures to keep consistent, and the reconciliation operation is genuinely hard: it shipped with an infinite loop fixed only in 3.0.9, and the debug dumper carries explicit consistency assertions for both link sets. The alternative — deriving paint order from a pre-order walk — is less flexible but cannot desynchronise.                    |
| Express translucency as a two-bit **mode** per channel and implement `BLEND` as an equal-weight running mean, rather than adding an opacity value.                  | A character cell has one foreground and one background colour, with nowhere to store an alpha channel and no compositor to honour it. A mode fits in spare bits of an existing 32-bit channel word and makes "am I still searching" one ordered comparison.                                | Fractional opacity is inexpressible: `n` stacked `BLEND` layers each contribute exactly `1/n`, so a 30% scrim cannot be served and a drop shadow has no representation. Terminal-default colours also cannot participate, since their RGB is unknown — recorded as a standing BUG in `notcurses_render.3.md`.                                              |
| Do not clip a plane to its parent — clip only to the pile viewport — and walk every plane fully on every render.                                                    | Clipping ancestors would need a clip stack and per-plane intersection tests, and would make "a popup that escapes its container" impossible without a portal mechanism. Making the terminal the only boundary means there is nothing to escape from, so the portal problem disappears.     | Cost is `O(Σ plane areas)` per frame regardless of occlusion; a large opaque plane on top does not stop the walk beneath it. A widget that _wants_ containment must implement it by sizing its own plane, and "clip to this ancestor" is inexpressible.                                                                                                    |
| Provide no hide flag; make visibility a consequence of pile membership, with `ncplane_reparent(p, p)` as the hide idiom.                                            | Piles already exist for concurrency, only one is rasterized at a time, and a plane in another pile is therefore already invisible — "hidden" required no new state and no new branch in the render loop.                                                                                   | The weakest decision here. It overloads a structural operation with presentation, silently destroys and recreates piles, does not preserve z-order (so every caller must re-assert `ncplane_move_top` on unhide), and leaves no way to ask whether a plane is visible.                                                                                     |
| Give the menu **one** plane sized to the worst-case unrolled section, with a transparent base cell, and draw the drop-down into it.                                 | With one surface and no top layer, allocating a second plane per open menu would mean creating and destroying a plane on every click and re-solving its z position. Reserving the maximum extent once makes open/close a pure draw, hit testing one rectangle test, and travel zero cells. | The popup's maximum size becomes a construction-time constant, and the plane permanently occupies (and hit-tests) the worst-case rectangle even when closed. The transparent base cell keeps it invisible, but a naive outside-click test would wrongly treat the reserved area as "inside" — which is why the header row must be checked explicitly.      |
| Route no events; expose `bool X_offer_input(X*, const ncinput*)` and let the application call widgets in a fixed order.                                             | With no focus model and one input stream, a total ordering makes trigger arbitration structurally race-free and keeps the library free of any policy about which widget "owns" a click.                                                                                                    | Every cross-cutting behaviour in this survey's spine — modality, focus trap, light dismiss across widgets, dismiss-on-deactivate, parent-closes-child cascades — becomes the application's problem and is therefore implemented nowhere. The library also ships no z-order-aware hit test, despite the renderer computing a per-cell owner as a byproduct. |

## Sources

Primary sources, all read at `b26048eebc74d5d254717d3332fa484718f9efe6`:

- [`src/lib/internal.h`][internal-model] — the model comment (`:62-67`); the `ncplane` structure
  (`:77-104`: `fb`, `absx`/`absy`, `lenx`/`leny`, `above`/`below`, `bnext`/`bprev`/`blist`/
  `boundto`); `struct crender` and its 8-bit blend counters (`:267`, `:287-292`); the `ncpile`
  comment and typedef (`:296-319`); `channels_blend` (`:1342`, the transparent early-out at `:1344-1345`, the mean at
  `:1380-1382`, alpha propagation at `:1385`); `cell_blittedquadrants` (`:1269`) and
  `cell_set_blitquadrants` (`:1281`); `ncplane_set_widget` (`:461`).
- [`src/lib/render.c`][render-paint] — `highcontrast()` (`:143`, the luminance threshold at
  `:159-163`); `paint_sprixel` (`:169`) and its wipe branch (`:198-206`); `paint()` (`:236`), the
  offscreen guards (`:283-296`), the three attribute gates (`:302`, `:328`, `:359`), the wide-glyph
  degradation (`:377-388`), `crender->p = p` (`:392`, `:394`); `init_rvec` (`:405`);
  `lock_in_highcontrast` (`:418`); `postpaint_cell` (`:448`) and `postpaint` (`:501`);
  `ncpile_render_internal` (`:1496`, the whole-viewport `paint()` call at `:1502`);
  `notcurses_at_yx` (`:1627`); `notcurses_cursor_enable` (`:1740`);
  `ncpile_render_to_buffer` (`:1597`); the margin subtraction at `:80`.
- [`src/lib/notcurses.c`][move-family-impl] — `ncplane_move_above` (`:1584`),
  `ncplane_move_below` (`:1631`), `ncplane_move_family_above` (`:1677`) / `_below` (`:1711`);
  `move_bound_planes` (`:2405`), `ncplane_move_yx` (`:2417`), `ncplane_y` (`:2440`);
  `ncplane_translate_abs` (`:2595`), `ncplane_translate` (`:2618`);
  `ncplane_resize_placewithin` (`:2686`, the abs-versus-dim comparisons at `:2693` and `:2701`, the
  upper-left preference comment at `:2709-2710`); the alignment one-shot solve in
  `ncplane_new_internal` (`:629`).
- [`src/lib/menu.c`][menu-state] — `unrolledsection` (`:29`); worst-case section height (`:255`)
  consumed by the plane geometry (`:398-412`); `resize_menu` (`:361-375`); the transparent base cell
  (`:422-427`); `ncmenu_unroll` (`:452`, the leading `ncmenu_rollup` at `:453`, the right-edge clamp
  at `:473-475`, `ncplane_rounded_box_sized` at `:479`, auto-select at `:490-491`);
  `ncmenu_nextsection` (`:563`); the release-only gate (`:678`); `ncmenu_offer_input` (`:707`), the
  BUTTON1-release branch (`:710`), the toggle/outside rollup (`:729-737`), the early bail on other
  releases (`:739`), `ESC` (`:775-778`), the state-driven rollup (`:804-807`).
- [`src/lib/selector.c`][selector-riser] — riser junction patching with UTF-8/ASCII fallbacks
  (`:121-142`); the standard-plane refusal (`:281-284`); `ncplane_resize_simple` on a caller-supplied
  plane (`:369-371`); `ncselector_offer_input` (`:523`) and the release-only click (`:525`); the
  press/release pairing FIXME (`:538`).
- [`include/notcurses/notcurses.h`][alpha-modes] — the alpha modes (`:104-108`) and their
  background enforcement (`:368`); the alignment aliases (`:87-88`); the stock resize callbacks
  (`:1497-1506`); `ncplane_move_top`/`_bottom` as `NULL`-sentinel splices (`:1951-1962`); the
  family-move worked example (`:1964-1968`); `notcurses_align` (`:2096`);
  `struct ncmenu_item` (`:4119-4122`); `NCMENU_OPTION_HIDING` (`:4132`); the documented-but-absent
  motion input (`:4183`).
- [`src/lib/in.c`][in-motion] — motion synthesised as `NCKEY_MOTION` with `NCTYPE_RELEASE`
  (`:612-617`); the Kitty keyboard-protocol release path.
- [`src/lib/sprite.h`][sprite] — the sprixel/TAM state machine (`:29-113`) and the Sixel
  irreducibility note (`:41-47`).
- [`src/demo/hud.c`][hud-hide] — hide-by-reparent and the required `ncplane_move_top` on unhide
  (`:209-217`); `resizecb = ncplane_resize_placewithin` (`:435`); the `NCALPHA_BLEND` see-through
  panel (`:444`).
- [`src/tests/piles.cpp`][piles-test] — `ReparentUpdatePos` (`:283-300`, absolute preserved and
  relative going negative) and `RemoveParentUpdatePos` (`:206-249`).
- [`src/tests/stacking.cpp`][stacking-test] — the design note naming the originating issue
  (`:1-14`), the `notcurses_canutf8`-branched read-back assertions (`:72-80`),
  `LowerAtopUpperWhite` (`:84`) and `UpperAtopLowerWhite` (`:129`).
- [`doc/man/man3/notcurses_pile.3.md`][pile-man] — piles as concurrency domains that do not compose
  (`:26-30`); [`doc/man/man3/notcurses_render.3.md`][render-man] — `notcurses_at_yx` on wide-glyph
  secondary columns (`:96-98`) and the standing BUG on blending terminal-default colours.
- [`NEWS.md`][news] — the `ncplane_move_family_*` infinite loop fixed in 3.0.9; the exact-modifier
  requirement for menu shortcuts since 3.0.7; `notcurses_canoctant` / `NCBLIT_4x2`.

Umbrella and capstone: [`./index.md`](./index.md), [`./concepts.md`](./concepts.md),
[`./comparison.md`](./comparison.md), [`./features-people-forget.md`](./features-people-forget.md),
[`./sparkles-baseline.md`](./sparkles-baseline.md), [`./proposal.md`](./proposal.md). Nearest
siblings: [`./turbo-vision.md`](./turbo-vision.md), [`./textual.md`](./textual.md),
[`./ratatui.md`](./ratatui.md), [`./tmux-popup.md`](./tmux-popup.md),
[`./neovim-floats.md`](./neovim-floats.md), [`./nui.md`](./nui.md),
[`./nvim-completion.md`](./nvim-completion.md), [`./helix.md`](./helix.md),
[`./emacs-posframe.md`](./emacs-posframe.md), [`./imgui.md`](./imgui.md),
[`./gpui.md`](./gpui.md). Sibling research trees:
[`../ui-layout/index.md`](../ui-layout/index.md),
[`../window-system-integration/index.md`](../window-system-integration/index.md),
[`../platform-ui-guidelines/index.md`](../platform-ui-guidelines/index.md),
[`../sean-parent/index.md`](../sean-parent/index.md). Toolkit specs:
[`../../specs/ui/index.md`](../../specs/ui/index.md),
[`../../specs/ui/input.md`](../../specs/ui/input.md),
[`../../specs/ui/containers.md`](../../specs/ui/containers.md),
[`../../specs/ui/state-machines.md`](../../specs/ui/state-machines.md),
[`../../specs/ui/backends.md`](../../specs/ui/backends.md),
[`../../specs/ui/widgets.md`](../../specs/ui/widgets.md).

<!-- References -->

[repo]: https://github.com/dankamongmen/notcurses/tree/b26048eebc74d5d254717d3332fa484718f9efe6
[man]: https://github.com/dankamongmen/notcurses/tree/b26048eebc74d5d254717d3332fa484718f9efe6/doc/man/man3
[concepts]: ./concepts.md
[internal-model]: https://github.com/dankamongmen/notcurses/blob/b26048eebc74d5d254717d3332fa484718f9efe6/src/lib/internal.h#L62
[internal-links]: https://github.com/dankamongmen/notcurses/blob/b26048eebc74d5d254717d3332fa484718f9efe6/src/lib/internal.h#L77
[blend]: https://github.com/dankamongmen/notcurses/blob/b26048eebc74d5d254717d3332fa484718f9efe6/src/lib/internal.h#L1342
[set-widget]: https://github.com/dankamongmen/notcurses/blob/b26048eebc74d5d254717d3332fa484718f9efe6/src/lib/internal.h#L461
[alpha-modes]: https://github.com/dankamongmen/notcurses/blob/b26048eebc74d5d254717d3332fa484718f9efe6/include/notcurses/notcurses.h#L104
[alpha-enforce]: https://github.com/dankamongmen/notcurses/blob/b26048eebc74d5d254717d3332fa484718f9efe6/include/notcurses/notcurses.h#L368
[move-top]: https://github.com/dankamongmen/notcurses/blob/b26048eebc74d5d254717d3332fa484718f9efe6/include/notcurses/notcurses.h#L1951
[move-family]: https://github.com/dankamongmen/notcurses/blob/b26048eebc74d5d254717d3332fa484718f9efe6/include/notcurses/notcurses.h#L1964
[menu-item]: https://github.com/dankamongmen/notcurses/blob/b26048eebc74d5d254717d3332fa484718f9efe6/include/notcurses/notcurses.h#L4119
[menu-hiding]: https://github.com/dankamongmen/notcurses/blob/b26048eebc74d5d254717d3332fa484718f9efe6/include/notcurses/notcurses.h#L4132
[menu-doc]: https://github.com/dankamongmen/notcurses/blob/b26048eebc74d5d254717d3332fa484718f9efe6/include/notcurses/notcurses.h#L4183
[render-paint]: https://github.com/dankamongmen/notcurses/blob/b26048eebc74d5d254717d3332fa484718f9efe6/src/lib/render.c#L236
[render-hc-fn]: https://github.com/dankamongmen/notcurses/blob/b26048eebc74d5d254717d3332fa484718f9efe6/src/lib/render.c#L143
[render-init]: https://github.com/dankamongmen/notcurses/blob/b26048eebc74d5d254717d3332fa484718f9efe6/src/lib/render.c#L405
[render-hc]: https://github.com/dankamongmen/notcurses/blob/b26048eebc74d5d254717d3332fa484718f9efe6/src/lib/render.c#L418
[render-postcell]: https://github.com/dankamongmen/notcurses/blob/b26048eebc74d5d254717d3332fa484718f9efe6/src/lib/render.c#L448
[render-postpaint]: https://github.com/dankamongmen/notcurses/blob/b26048eebc74d5d254717d3332fa484718f9efe6/src/lib/render.c#L501
[render-pile]: https://github.com/dankamongmen/notcurses/blob/b26048eebc74d5d254717d3332fa484718f9efe6/src/lib/render.c#L1496
[render-to-buffer]: https://github.com/dankamongmen/notcurses/blob/b26048eebc74d5d254717d3332fa484718f9efe6/src/lib/render.c#L1597
[render-atyx]: https://github.com/dankamongmen/notcurses/blob/b26048eebc74d5d254717d3332fa484718f9efe6/src/lib/render.c#L1627
[render-cursor]: https://github.com/dankamongmen/notcurses/blob/b26048eebc74d5d254717d3332fa484718f9efe6/src/lib/render.c#L1740
[render-margins]: https://github.com/dankamongmen/notcurses/blob/b26048eebc74d5d254717d3332fa484718f9efe6/src/lib/render.c#L80
[move-yx]: https://github.com/dankamongmen/notcurses/blob/b26048eebc74d5d254717d3332fa484718f9efe6/src/lib/notcurses.c#L2405
[placewithin]: https://github.com/dankamongmen/notcurses/blob/b26048eebc74d5d254717d3332fa484718f9efe6/src/lib/notcurses.c#L2686
[move-family-impl]: https://github.com/dankamongmen/notcurses/blob/b26048eebc74d5d254717d3332fa484718f9efe6/src/lib/notcurses.c#L1677
[menu-state]: https://github.com/dankamongmen/notcurses/blob/b26048eebc74d5d254717d3332fa484718f9efe6/src/lib/menu.c#L29
[menu-resize]: https://github.com/dankamongmen/notcurses/blob/b26048eebc74d5d254717d3332fa484718f9efe6/src/lib/menu.c#L361
[menu-clamp]: https://github.com/dankamongmen/notcurses/blob/b26048eebc74d5d254717d3332fa484718f9efe6/src/lib/menu.c#L473
[menu-nextsection]: https://github.com/dankamongmen/notcurses/blob/b26048eebc74d5d254717d3332fa484718f9efe6/src/lib/menu.c#L563
[menu-input]: https://github.com/dankamongmen/notcurses/blob/b26048eebc74d5d254717d3332fa484718f9efe6/src/lib/menu.c#L707
[selector-riser]: https://github.com/dankamongmen/notcurses/blob/b26048eebc74d5d254717d3332fa484718f9efe6/src/lib/selector.c#L121
[in-motion]: https://github.com/dankamongmen/notcurses/blob/b26048eebc74d5d254717d3332fa484718f9efe6/src/lib/in.c#L612
[sprite]: https://github.com/dankamongmen/notcurses/blob/b26048eebc74d5d254717d3332fa484718f9efe6/src/lib/sprite.h#L29
[hud-hide]: https://github.com/dankamongmen/notcurses/blob/b26048eebc74d5d254717d3332fa484718f9efe6/src/demo/hud.c#L209
[piles-test]: https://github.com/dankamongmen/notcurses/blob/b26048eebc74d5d254717d3332fa484718f9efe6/src/tests/piles.cpp#L283
[stacking-test]: https://github.com/dankamongmen/notcurses/blob/b26048eebc74d5d254717d3332fa484718f9efe6/src/tests/stacking.cpp#L84
[pile-man]: https://github.com/dankamongmen/notcurses/blob/b26048eebc74d5d254717d3332fa484718f9efe6/doc/man/man3/notcurses_pile.3.md#L26
[render-man]: https://github.com/dankamongmen/notcurses/blob/b26048eebc74d5d254717d3332fa484718f9efe6/doc/man/man3/notcurses_render.3.md#L96
[news]: https://github.com/dankamongmen/notcurses/blob/b26048eebc74d5d254717d3332fa484718f9efe6/NEWS.md
