# The Sparkles baseline — what this repository can express today

The survey's "before" picture. Every other page in [this catalog][index] reads outward,
at systems that place tooltips, popovers, menus and hovercards; this one reads inward, at
`sparkles:ui` and its two applications, and answers one question with citations rather
than impressions: **what part of an anchored overlay does this repository already own,
and what does it merely name?** The vocabulary it uses — anchor, boundary, side, flip,
slide, safe area, top layer, light dismiss — is defined once in [`concepts.md`][concepts].

The short answer is that Sparkles owns the _appearance_ of a floating panel, one
axis of one collision rule, and a handful of composable machines that were built for
other purposes and happen to fit. It owns no anchor, no placement policy, no top
layer, no dismissal, and no overlay state. Where an overlay works today — hue's
twoslash hover popup, the gallery's `?` sheet — an **application** wrote the missing
parts, three times, differently.

**Last reviewed:** August 14, 2026

> [!NOTE]
> Citations in this document are **repo-relative paths with line numbers**, read
> against the working tree at the time of review. Claims about the surveyed field are
> deferred to their deep-dives rather than restated; where this page names an external
> system it links to that page and stops.

---

## 1. `WidgetKind.popup` — a look, not a behavior

The toolkit's widget vocabulary already has a `popup` alternative
(`libs/ui/src/sparkles/ui/widget.d:56`):

```d
popup,  /// a `panel` that floats (shadow, detached from flow)
```

The doc comment promises two things. The first — a shadow — is real, though it comes
from the view's `Decoration`, not from the kind. The second — "detached from flow" —
is not implemented anywhere. Grepping the toolkit for the identifier finds it only
ever _grouped with its neighbours_:

| Walk                    | Site                                                 | How `popup` is handled                   |
| ----------------------- | ---------------------------------------------------- | ---------------------------------------- |
| natural width           | `libs/ui/src/sparkles/ui/layout.d:296`               | `case column, stack, panel, popup:`      |
| natural height          | `libs/ui/src/sparkles/ui/layout.d:410`               | `case stack, panel, popup:`              |
| placement               | `libs/ui/src/sparkles/ui/layout.d:511`               | `case stack, panel, popup:`              |
| display-list emission   | `libs/ui/src/sparkles/ui/display_list.d:187`         | `case row, column, stack, panel, popup:` |
| HTML (inline-style)     | `libs/ui/src/sparkles/ui/interp/html.d:178`          | `case row, column, stack, panel, popup:` |
| HTML (semantic classes) | `libs/ui/src/sparkles/ui/interp/html_semantic.d:153` | `case row, column, stack, panel, popup:` |

There is no `case popup:` anywhere in `libs/ui/src`. A `popup` is laid out by the same
box-flow walk as a `stack`, at the position its parent gives it, contributing to its
parent's extent like any other child. Even the semantic HTML target emits it as
`position:relative` (`libs/ui/src/sparkles/ui/interp/html_semantic.d:52`), i.e. still
in flow.

So the kind carries, today:

- **no anchor** — nothing on `Widget` names another widget or a rect;
- **no placement** — no side, no gravity, no offset, no fallback;
- **no dismissal** — no cause, no reason, no outside-press notion;
- **no state** — no open/closed, no presence phase belonging to the surface;
- **no top-layer participation** — nothing raises it in the display list or in the
  derived hit lists (`INP10`'s "hit identity survives the pipeline" is implemented for
  ordinary widgets; the top-layer rung is `DCK13`, and it is empty — §7);
- **no arrow geometry** — the arrow is a `Decoration` field a view sets by hand (§2).

`WidgetKind.popup` is therefore `panel` plus a shadow the view asks for, plus a CSS
class name. **The floating is the caller's job**, and three callers do it three ways
(§3).

### What the gallery already shows

`apps/ui-gallery` — the catalog that is supposed to demonstrate every widget kind
across every backend — has fourteen pages (`apps/ui-gallery/src/registry.d:111-134`)
and **none of them is a popup page**. `WidgetKind.popup` appears twice in the app:

- as a **static specimen** on the Primitives page
  (`apps/ui-gallery/src/pages/primitives.d:88`), a box captioned "floats, with / a
  shadow" that does not float;
- as the `?` **help sheet** (`apps/ui-gallery/src/gallery.d:1238`), which is the more
  interesting one.

The help sheet is a genuine overlay and it works — but look at how. The view wraps the
_entire_ root in a `WidgetKind.stack` when `s.helpOpen`
(`apps/ui-gallery/src/gallery.d:256-261`), and the sheet is centred by giving a
full-surface `column` `alignX`/`alignY` of `Alignment.center`
(`apps/ui-gallery/src/gallery.d:1251-1259`) — the comment says so outright: "Centred by
the layout engine's own alignment over a full-surface column, so nothing here measures
a label or divides a width." Modality is an early `return` in the key handler
(`apps/ui-gallery/src/gallery.d:376-383`), and it is _tested_
(`apps/ui-gallery/src/gallery.d:1397`, `:1413` — keys under the sheet do not reach the
page; the first Escape closes the sheet, the second quits).

That is a complete, tested, keyboard-modal overlay with a dismissal chain. It exists
because the one thing it does not need is an **anchor**: a screen-centred surface can
be expressed with the layout engine alone. The moment an overlay must sit _next to
something_, the toolkit runs out and the application starts writing arithmetic.

---

## 2. The `Palette` popup metrics — the right shape, unfinished

`libs/ui/src/sparkles/ui/style.d` already models popup chrome as **theme data**, which
is the correct posture and the one the placement work should extend:

| Metric                                             | Line      | Note                                                                                  |
| -------------------------------------------------- | --------- | ------------------------------------------------------------------------------------- |
| `popupRadius = 4`                                  | `212`     | px in the GPU/HTML targets, ignored on cells                                          |
| `popupPadX = 1` / `popupPadY = 1`                  | `213-214` | cells                                                                                 |
| `popupMaxWidth = 120`                              | `220`     | "the backend narrows this further to the room actually left at the popup's anchor"    |
| `docsMaxWidth = 56`                                | `225`     | handed to layout as `Widget.width.max`                                                |
| `popupMinWidth = 24`                               | `233`     | "a backend with less room than this shifts the popup instead of shrinking it further" |
| `borderWidth = 1`                                  | `239`     | hairline                                                                              |
| `shadowDx = 0` / `shadowDy = 1` / `shadowBlur = 4` | `241-243` | authored against `twoslash.css`                                                       |
| `arrowSize = 6`                                    | `247`     | px square                                                                             |

Two of those doc comments are worth reading as **specification text that has no
implementation**. `popupMaxWidth` states the narrowing policy — cap to the room at the
anchor — and `popupMinWidth` states the shift-don't-shrink rule. Both are policies about
_placement_, written into the theme; the toolkit implements neither. Three applications
implement them, via two helper functions that live in a different package (§3).

### The arrow is already declared as data, with nothing computing it

`Decoration` (`libs/ui/src/sparkles/ui/style.d:177-178`) and its resolved form `Visual`
(`:156-157`) both carry:

```d
bool arrow;       /// draw a popup arrow/tail (backends place it)
int arrowOffset;  /// arrow horizontal offset from the left, in cells
```

This is exactly the seam an anchored-overlay primitive wants: the _decision_ is a value
in the widget model, and the _rendering_ is the backend's. Four backends consume it:

| Backend      | Site                                                            | Where it puts the arrow                        |
| ------------ | --------------------------------------------------------------- | ---------------------------------------------- |
| TUI grid     | `libs/ui-tui/src/sparkles/ui_tui/grid_canvas.d:371-372`         | `setc(x0 + 1 + v.arrowOffset, y0, '┴')`        |
| cells interp | `libs/ui/src/sparkles/ui/interp/cells.d:346-347`                | `setc(x0 + 1 + v.arrowOffset, y0, '┴')`        |
| HTML         | `libs/ui/src/sparkles/ui/interp/html.d:248-256`                 | `left: arrowOffset + 1` in `ch`, `top:-4px`    |
| raylib       | `libs/ui-raylib/src/sparkles/ui_raylib/raylib_canvas.d:329-347` | apex at `boxX + arrowOffset*cellW + cellW*0.5` |

Three observations, all of which the primitive must retire:

1. **The top edge is hard-coded in all four.** There is no `Side` value anywhere under
   `libs/ui/src` — not on `Widget`, not in the display list, not on `Visual` — so a
   popup placed _above_ its anchor would still grow a notch out of its top edge.
2. **The four do not agree on the column.** The two cell backends and the HTML emitter
   write `1 + arrowOffset`; the raylib backend writes `arrowOffset` (plus a half-cell
   centring term) — one cell left of the others for an identical `Visual` and `Rect`.
   The HTML agreement holds only under the mapping "a 1px CSS border occupies no cell".
3. **Nothing clamps `arrowOffset` against the box.** The only guard on any of these
   writes is the canvas-level `inBounds` check
   (`libs/ui-tui/src/sparkles/ui_tui/grid_canvas.d:129-137`,
   `libs/ui/src/sparkles/ui/interp/cells.d:149-151`) — the surface rect plus whatever
   clip happens to be pushed, never the box. Because the arrow `setc` runs _after_ the
   corner `setc`s, an `arrowOffset` at or beyond `width - 2` overwrites the box's corner
   glyph, and larger values paint into whatever is next to it.

And the offset is never computed at all. The sole production call site is
`libs/twoslash/src/sparkles/twoslash/render_widgets.d:626`, which builds the hover
popup with `surfaceDeco(arrow: true)` — and `surfaceDeco`'s signature (`:67`) defaults
`arrowOffset = 1`. **The arrow always points at the popup's second column**, while
`clampOrigin` is free to slide the popup arbitrarily far from the anchor (§3). The
notch is decorative; it points at the anchor only when the popup did not have to move.

---

## 3. `clampOrigin` / `effectivePopupWidth` — the whole placement engine

Two pure functions in `libs/twoslash/src/sparkles/twoslash/render_widgets.d`, both
`@safe pure nothrow @nogc`, both unit-tested (`:437`, `:447`). They are the entire
placement capability of the repository — and they live in the twoslash render library,
not in `sparkles:ui`.

```d
int clampOrigin(int anchor, int width, int extent) @safe pure nothrow @nogc
{
    const over = anchor + width - extent;
    const shifted = over > 0 ? anchor - over : anchor;
    return shifted < 0 ? 0 : shifted;
}
```

(`libs/twoslash/src/sparkles/twoslash/render_widgets.d:430-435`.)

That is **shift, on one axis, in one direction, against one scalar extent**. Its doc
comment argues the shift-vs-shrink choice explicitly, and argues it well — "a popup
narrowed to fit under a token near the right edge would wrap its signature into a column
two words wide, which reads worse than the same popup slid left" — which is a real
placement decision, already made, worth carrying forward. `effectivePopupWidth` (`:413`)
is its companion: the theme's ceiling, narrowed to the room reported at the anchor, with
`popupMinWidth` as a floor.

What is absent from both:

- **flip** — there is no above/below (or left/right) decision anywhere in the repository;
- **the vertical axis** — `clampOrigin` is called on `x` only, at every site;
- **a boundary concept** — the third parameter is a bare `int`, and the _floor_ is
  hard-wired to `0`;
- **the anchor as a rect** — the first parameter is an `int`, so an anchor has no
  extent, no side, and no second row;
- **the overlay's own preferred side** — there is nothing to prefer;
- **arrow math** — see §2.

### The three call sites, and how they disagree

| Site                              | Anchor passed          | Unit  | `extent` passed              | Vertical placement      | Clips? |
| --------------------------------- | ---------------------- | ----- | ---------------------------- | ----------------------- | ------ |
| `apps/hue/src/gui.d:2900`         | `cast(int) x` (window) | px    | `x + availCells * cellW`     | `hy + cellH` at `:2537` | no     |
| `apps/hue/src/tui.d:654`          | `rs[0].x` (pane-local) | cells | `width` (pane width)         | `rs[0].y - top + 2`     | yes    |
| `apps/hue/src/twoslash_tui.d:267` | `padCols + r.x` (grid) | cells | `grid.cols` (whole terminal) | `r.y - scrollRow + 1`   | no     |

Read the columns carefully, because the honest reading is sharper than the obvious one.

**The boundaries genuinely differ — three ideas of "inside".** `gui.d` measures an
anchor-relative px edge derived from `availCells = (screenW - rightPad - hx) / cellW`
(`:2528`); `tui.d` uses the document pane's width, computed as `width - rs[0].x - 1`
(`:626`); `twoslash_tui.d` uses the whole terminal, `grid.cols - anchor` (`:242`). The
third can therefore place a popup across a pane divider that the second would have
clamped. This is the _clipping ancestor / boundary_ concept the field settled long ago
(see [`floating-ui`][floating-ui] and [`angular-cdk`][angular-cdk]), missing here.

**The coordinate spaces differ, and `clampOrigin`'s `0` floor is only right in one of
them.** The function clamps to the **surface origin**, not to the boundary's start. In
`tui.d` the rect is pane-local, so `0` is the pane's left edge and the clamp is correct.
In `gui.d` the anchor is in window px, so a popup wider than the document pane starts at
the _window's_ left edge, over the gutter. In `twoslash_tui.d` the anchor includes
`padCols`, so the clamp lands inside the left pad. A boundary that does not begin at the
origin is exactly the case a scalar `extent` cannot express.

**The vertical literals differ, but the result does not — and that is worth stating
precisely.** `+cellH`, `+2` and `+1` look like three policies; they are one policy
expressed against three pane origins. `tui.d` paints the document at row `1 - top`
(`:548`), so `rs[0].y - top + 2` is the row immediately below the anchor;
`twoslash_tui.d` paints at `-scrollRow` (`:233`), so `r.y - scrollRow + 1` is likewise
the next row; and `hy + cellH` is the next row in px. **All three place the overlay
flush below the anchor row, with a zero gap** — which is, per
[the interactive-hover work][floating-ui], the right answer for keeping a pointer
travelling from anchor to overlay. What none of them does is _choose_ that side: there
is no measurement of the room below, so a popup opened near the bottom of the viewport
is truncated by the pane clip (TUI) or cut by the window edge (GUI). **Nothing in the
repository flips.**

**Only one site clips.** `tui.d:656` passes `Rect(-ox, -oy, width, height)` so the popup
cannot spill across the divider into the explorer; the other two rely on the surface
edge.

**One site is not a live host.** `apps/hue/src/twoslash_tui.d` is now only the headless
frame-capture renderer for the QA harness — its own header says the interactive
twoslash TUI moved into the workspace viewer pane (`:1-6`). So the live divergence is
two hosts, with a third copy kept alive by the screenshot harness. It also lays the
popup tree out twice: once at `:265` and again inside `paintTree` at `:277`.

This is [`PRN8`][principles] in miniature — one semantic behavior ("where does this
overlay go"), three independently written implementations, divergent results — and it
is the strongest in-repo argument for the primitive.

---

## 4. `HoverPopup` — per-application overlay state, GUI-only

`apps/hue/src/gui_state.d:315-325`:

```d
struct HoverPopup
{
    size_t hotNode = 0;
    PixelRect hotPopup;
    bool havePopup = false;
    ExpandedRegions expandedRegions;
    KeyTarget[] popupKeys;
    size_t popupNode = size_t.max;
    Timeline fade;
    int forceHover = -1; // HUE_GUI_HOVER=<n>: force the Nth popup (goldens)
}
```

Five things to take from it.

**It already composes a toolkit machine.** `Timeline` (`STM6`,
`libs/ui/src/sparkles/ui/state.d:1190`) drives the fade. That is the right instinct and
a proof that the composed-machine posture works for overlays — the presence half of
the problem is already solved by something the toolkit owns.

**`hotPopup` is a hand-rolled, degenerate safe area.** It stores the popup's _drawn_
rect in pixels, and the comment at `apps/hue/src/gui.d:2910-2912` explains why: "the
drawn rect, not the anchor, or the pointer leaves a shifted popup the moment it moves
onto it." The keep-open test is a zero-tolerance containment check against that rect
(`apps/hue/src/gui.d:2468-2471`). Combined with the zero-gap placement of §3, hue's GUI
ships a correct answer for the **anchor→overlay travel** problem — the same problem
[`floating-ui`][floating-ui]'s `safePolygon` and [`react-aria`][react-aria]'s safe area
solve — discovered independently and solved with a rectangle. Its defects are that it is
per-application, GUI-only, outside the shared hit list, and expressed in pixels rather
than in `sparkles:input`'s cells.

**`popupKeys` is a private hit list.** The popup hit-tests itself
(`apps/hue/src/gui.d:2152-2158`): a manual bounds check against `hotPopup`, then
`keyAt` over the popup's own `KeyTarget[]`, entirely outside
`hoverTargets`/`keyTargets` routing — because there is no top layer to register with
(§7). Note the comment: "The popup's geometry is last frame's, which is what the reader
aimed at."

**It is GUI-only.** The TUI has no equivalent value: `apps/hue/src/tui.d`'s popup is
painted from `hoverSel` / `hoverNodes` / `hoverExpanded` locals
(`apps/hue/src/tui.d:600-612`). Two hosts, two state shapes, one behavior.

**`forceHover` exists so the golden harness can pin a popup.** `HUE_GUI_HOVER` forces
the Nth popup open for screenshot comparison. An overlay whose state is only reachable
by an environment-variable back door is an overlay whose state is not reachable from the
normal event path — which is precisely what a recording-canvas-assertable primitive
would fix.

---

## 5. `DCK5` — a finished overlay view with nowhere to live

The dock container's drag-to-redock hint is **done on the toolkit side**:

- `dockZoneAt` (`libs/ui/src/sparkles/ui/dock.d:738`) — the pointer's zone, with fixed
  edge bands and nearest-edge corners so the hint cannot flicker;
- `dockHintRect` (`libs/ui/src/sparkles/ui/dock.d:802`) — the exact region the drop will
  fill;
- `DockContainer.dragHint()` (`libs/ui/src/sparkles/ui/dock.d:983`) — the pane, target,
  zone and rect a host paints;
- the `dockHint` component (`libs/ui/src/sparkles/ui/components/chrome.d:382`) — a
  toolkit-owned **view** built from the same `DockDrag`, with a test
  (`:687`) asserting it shows the drop and nothing otherwise.

`docs/specs/ui/containers.md:90` states the remainder in as many words:

> `DCK5` is complete on the container side; what remains is **a host positioning that
> overlay on its top layer**

A finished, tested, toolkit-owned overlay view that no toolkit-owned mechanism can
place. The gap is not hypothetical, and the existing spec already names it.

---

## 6. The waiting consumers

| Consumer                                                       | Status                 | What it needs from a primitive                                                                                                                                                                       |
| -------------------------------------------------------------- | ---------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `DEF10` / [`docs/specs/hue/notifier.md`][notifier] (`NTF*`)    | researched/not-started | snacks.nvim-style titled floating panels that stack in a corner, collapse to an icon, carry action buttons — across GUI, TUI **and** static HTML. Explicitly "a shared UI primitive, not a one-off". |
| [`OVL1`][overlays] — the uniform `OverlayModel`                | researched/not-started | its **fourth decoration channel** is "hover popups (rich content anchored at an offset)". Note the anchor is already conceived as an _offset_ — a text position, not a rect.                         |
| `WGT16` — Toast / notification (`docs/specs/ui/widgets.md:83`) | not started            | "view over `STM6`" — a screen-anchored surface that shares the placement solve but not the anchoring.                                                                                                |
| `UIA7` (`docs/specs/ui/feature-requirements.md:17`)            | not started            | the toolkit must be "presentation-complete for a real application … and containers (panels, **popups**, scroll views)".                                                                              |
| `apps/ui-gallery`                                              | shipping               | the cross-backend demonstration surface. Fourteen pages, no popup page; the one overlay it has is screen-centred (§1).                                                                               |

`DEF10` is the most demanding of these, because it names **static HTML** as a target —
which is where an overlay design either survives or is quietly redefined (§8.3).

---

## 7. Open defects this work must retire

| Defect         | Where                                                          | What it says                                                                                                                                                                               |
| -------------- | -------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `IXR26`        | `docs/specs/ui/interaction-review.md:71`                       | "PARTLY RESOLVED (`IXB10`): all four scrollbars expand by `ScrollbarState.expanded(caps)`; **the twoslash popup still assumes hover**"                                                     |
| `DCK5` tail    | `docs/specs/ui/containers.md:90`                               | the hint overlay awaits "a host positioning that overlay on its top layer"                                                                                                                 |
| `DCK13` rung   | `docs/specs/ui/containers.md:98`                               | routing precedence reads "pointer capture (`STM11`) first, then the gesture owner mid-recognition, **then top layers (popups/overlays, tested front-to-back)**, then the positional query" |
| `UI-O3`/`INP9` | `docs/specs/ui/open-issues.md:57`, `docs/specs/ui/input.md:62` | no native pointer grab: a drag leaving the window loses motion and release                                                                                                                 |

`DCK13` is the sharpest of the four. The precedence order is already **written** and
already **implemented** in `DockContainer.handle` — with nothing occupying the
top-layers rung. The spec's job is to fill a slot that is reserved and empty, not to
argue for a new one.

`IXR26` is the one with a shipped counter-example: the substitution pattern it asks for
already exists (`ScrollbarState.expanded(in InputCapabilities)`), so the overlay case is
a duplication gap rather than a missing mechanism.

`UI-O3` is the one that **cannot** be retired by this work — it is a windowing-system
concern owned by the adapter. What the primitive owes it is a placement and dismissal
model that does not _assume_ a grab, so that acquiring one later is an improvement
rather than a precondition.

---

## 8. The per-target constraint list

The judging criterion for every proposal in this catalog: **what may an overlay not
assume, per target?** Derived from `docs/specs/ui/backends.md`'s degradation inventory
(`:47-62`), `docs/specs/ui/input.md`'s capability axes, and `LAY3`.

### 8.0 Cross-cutting — true on every current target

1. **There is no top layer.** Every backend paints into **one surface**. No OS popup
   window, no compositor, no z-index, no stacking context. An overlay is visible only
   because something painted it last. Contrast the native subjects
   ([`gtk4`][gtk4], [`qt-widgets`][qt-widgets], [`xdg-positioner`][xdg-positioner]),
   whose entire dismissal and grab story is a surface the OS owns; the in-canvas
   subjects ([`gpui`][gpui], [`imgui`][imgui], [`flutter`][flutter],
   [`textual`][textual]) are the relevant peers.
2. **No native grab** (`UI-O3`). Nothing can guarantee delivery of a pointer event that
   leaves the surface.
3. **Layout is integer cells** (`LAY3`, `docs/specs/ui/layout.md:66`): "No
   floating-point value may enter layout." A pixel backend may _position_ sub-pixel
   (`TGT9`), but every number upstream of the canvas is an `int` cell.
4. **Hit order is reverse paint order.** There is no z coordinate to sort by, so
   "front-to-back" means "later in the display list"
   (`libs/ui/src/sparkles/ui/state.d:55-56`).
5. **Events route against the last painted frame's hit data** (`DCK13`), so an
   overlay's hit rect is one frame stale by construction — a property the field's
   retained-mode subjects do not share, and one that makes a _stable_ placement
   (no per-frame oscillation) a correctness concern rather than a polish concern.

### 8.1 TUI — `GridCanvas` over `sparkles:tui`

- **No sub-cell pointer**: `backends.md` declares it **absent** ("whole cells").
- **No key release at all** (`INP16`, default **absent**). Pointer release _is_
  available — `PointerAction.release` is a distinct capability the terminal serves over
  SGR-1006 — so a tap or a pointer long-press is expressible; what is not is any
  keyboard press-and-hold ("hold a modifier to peek").
- **Bare motion is opt-in and off by default**: `RunConfig.motion`
  (`libs/ui-app/src/sparkles/ui_app/host.d:81`) defaults to `false`, so a host that has
  not asked for it receives no hover motion at all. Hover-intent machinery must be a
  _declared_ capability, not an assumed one.
- **One pointer** (`multiPointer: absent`).
- **No frame clock**: `TuiHost.frameSeconds()` returns a literal `0`
  (`libs/ui-app/src/sparkles/ui_app/tui_loop.d:109`), so anything advanced by
  `step(state, dtMs)` — `Timeline` included — never advances. `apps/ui-gallery` already
  works around this by observation: `s.hasFrameClock = dtMs > 0`
  (`apps/ui-gallery/src/gallery.d:134`) selects a `holdUntilDismissed` config
  (`apps/ui-gallery/src/state.d:456`) and dismisses the toast on the next key instead.
  **Any timing behavior — warm-up, cool-down, auto-hide — must degrade to an
  event-scoped equivalent here, or it does not exist on this target.**
- **Dropped chrome**: corner radius (box-drawing corners instead), drop shadow
  (**dropped outright**), single-side accent border, font role/scale.
- Hover **is** served (`cellPointer`), once motion is on.
- ⇒ An arrow is at best one character cell; a shadow does not exist; any "safe polygon"
  quantizes to whole cells.

### 8.2 GUI — `RaylibCanvas`, one OS window

- **One window, no native popup surface.** An overlay is clipped to the window; there is
  no second surface to escape into.
- **No pointer grab** (`UI-O3`): a drag leaving the window loses motion and release.
- Radius and shadow are _approximated_; **font scale is dropped** (single-size font),
  so a "smaller tooltip text" style is not available.
- Hover served (mouse); sub-cell pointer served.

### 8.3 HTML — `interp/html` and `interp/html_semantic`

- **No script.** `backends.md` declares tier-1 input **unavailable**. `TGT4` requires
  tier-0 interactivity in **pure CSS**: `:hover`, `:focus-within`, `:checked`,
  `<details>`/`<summary>`.
- ⇒ **No drag, no timers, no measurement, no collision detection at emit time.** A
  warm-up or cool-down delay cannot exist as a decision; at most it can be _emitted_ as
  a CSS `transition-delay` the viewer's engine applies. Anything conditioned on
  _measured_ overflow cannot exist unless CSS itself performs the measurement.
- Radius, shadow, border and dash are all native — this is simultaneously the **most**
  capable target visually and the **least** capable behaviorally.
- It emits no ARIA of any kind today; the semantic emitter carries a
  `details.spk-disclosure > summary` rule and nothing role-shaped.

### 8.4 Android — `RaylibCanvas` in an APK

- **No hover at all**: `backends.md` declares hover "**absent** (touch)". This is
  `IXR26`'s home.
- Touch only; multi-pointer served.
- The system back key is already unified with Escape in the vocabulary (`INP13`,
  `sparkles.input.events.isDismiss`), so "dismiss" is one equivalence and not a
  per-platform branch.
- The soft keyboard steals the bottom of the screen. That inset must be an **input** to
  placement, not something placement discovers — see [`compose`][compose] and
  [`slint`][slint] for the two sides of that mistake.
- `longPress` is already spent on this target: hue uses it to start a text selection, so
  "long-press to reveal" is not a free default.

### 8.5 recording — `RecordingCanvas`

- No window, no tty, a fixed `frameSeconds = 1.0f / 60`
  (`libs/ui-app/src/sparkles/ui_app/record.d:69`).
- **Every behavior specified must be assertable here.** That single constraint forces
  the shape of the answer: placement must be a pure function over values, and dismissal
  must be a value the harness can read — not an effect it must observe.

---

## 9. The geometry vocabulary a `place()` must be built from

`libs/ui/src/sparkles/ui/geometry.d` already supplies what a placement engine needs, and
its shape constrains the answer:

- **`Rect`** (`:47`) is `Point origin` + `Size size`, with `contains` (`:84`),
  `deflate(Insets)` (`:88`), `empty` (`:97`), `intersection` (`:100`) and
  `right`/`bottom` — all `@safe pure nothrow @nogc`. A boundary, an anchor rect and a
  content rect are expressible **today**, with no new type.
- **`Insets`** (`:119`, CSS order) covers viewport padding, reserved chrome and
  safe-area/soft-keyboard insets, with `all` and `symmetric` constructors and
  `horizontal`/`vertical` totals.
- Everything is **`int` cells**, and positions **may legitimately be negative** — the
  module says so at `:28-30`: "a laid-out position may be **negative** for content
  scrolled above or left of the viewport". A placement result must therefore not assume
  non-negative coordinates, and clamping to `0` — which `clampOrigin` does today — is
  wrong for any boundary that does not start at the surface origin (§3). The web and
  desktop subjects hit the same class of bug; see [`avalonia`][avalonia] for the
  canonical `bounds.Width` vs `bounds.Right` confusion.
- `Rect` is Regular: `Vector.opEquals` compares the backing components, so `==` works
  and a `Placement` result can be snapshotted, diffed and property-tested (`STM12`,
  `PRN11`).

> [!WARNING]
> **`Point` and `Size` are `Vector`-backed unions, so a named-field read is not
> available in CTFE.** `libs/ui/src/sparkles/ui/geometry.d:35-37` states it: "these are
> `union`-backed (`Vector` overlays named fields on a `T[N] data` array), so a
> named-field read is **not** available in CTFE — geometry is a runtime vocabulary."
>
> Consequence for the spec: a `place()` function can be `@safe pure nothrow @nogc` and
> covered by property-based tests, but it **cannot be a `@ctfe` test** while it reads
> `.x` / `.width`. Placement must be verified on the recording canvas and by runtime
> property tests, not by compile-time evaluation. **Do not write a requirement that
> promises CTFE placement.**

---

## 10. The delta table

Each capability the survey found in the field, against where this repository stands.
Statuses:

| Status                       | Meaning                                                                                         |
| ---------------------------- | ----------------------------------------------------------------------------------------------- |
| `present`                    | the toolkit owns it and an overlay can use it as-is                                             |
| `partial`                    | a toolkit-owned piece exists but does not reach the overlay case                                |
| `application responsibility` | it demonstrably works somewhere in the repo, but an application wrote it — often more than once |
| `absent`                     | no code and no vocabulary                                                                       |

"Exemplified by" names **one** subject whose implementation is the clearest instance of
the capability; it is not a claim about the rest of the corpus. Where the field is split,
the deep-dive says so. The table lists capabilities the survey found _named_ somewhere;
the ones nobody names until they ship a bug are collected separately in
[`features-people-forget.md`][forgotten].

### Anchor & placement

| Capability                                               | Exemplified by                     | Sparkles today | Evidence                                                                                                                                  |
| -------------------------------------------------------- | ---------------------------------- | -------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| Anchor reduced to one integer rect before any arithmetic | [`xdg-positioner`][xdg-positioner] | `partial`      | `selectionRects`/`keyedRects`/`hoverTargets` all produce cell `Rect`s; the one placement function takes an `int` (`render_widgets.d:430`) |
| Multi-rect anchor for a wrapped inline run               | [`floating-ui`][floating-ui]       | `partial`      | `selectionRects` (`state.d:415`) returns one rect per wrapped row; every call site uses `rs[0]`                                           |
| Clip-aware anchor resolution (hidden when scrolled out)  | [`css-anchor`][css-anchor]         | `partial`      | `hoverTargets` (`state.d:64`) and `keyTargets` (`:105`) walk with a clip; `keyedRects` (`:504`) and `selectionRects` (`:415`) do not      |
| A named anchor with a scoping/collision rule             | [`css-anchor`][css-anchor]         | `absent`       | `Widget.key` exists (`widget.d:109`) but has no namespace or uniqueness rule                                                              |
| Anchor-edge × gravity flip                               | [`xdg-positioner`][xdg-positioner] | `absent`       | no flip anywhere; all three call sites place below unconditionally (§3)                                                                   |
| Slide/shift along the free axis                          | [`gtk4`][gtk4]                     | `partial`      | `clampOrigin` — one axis, one direction, scalar extent, floor pinned to `0`                                                               |
| Shrink / resize-to-fit as a third strategy               | [`gtk4`][gtk4]                     | `partial`      | `effectivePopupWidth` caps width only; never height, never as a post-flip fallback                                                        |
| Ordered candidate list as data                           | [`angular-cdk`][angular-cdk]       | `absent`       | —                                                                                                                                         |
| Boundary as an explicit parameter                        | [`compose`][compose]               | `absent`       | each of the three call sites derives its own (§3)                                                                                         |
| Per-side viewport padding / safe-area insets             | [`floating-ui`][floating-ui]       | `absent`       | `Insets` exists (`geometry.d:119`); nothing feeds it to placement                                                                         |
| Placement result carries the resolved side               | [`gtk4`][gtk4]                     | `absent`       | no `Side`/`placement` symbol under `libs/ui/src`                                                                                          |
| Arrow cell derived from the anchor                       | [`floating-ui`][floating-ui]       | `absent`       | `arrowOffset` is fixed at the `surfaceDeco` default `1` (`render_widgets.d:67`, `:626`)                                                   |
| Arrow clamped away from the corners                      | [`tippy`][tippy]                   | `absent`       | no clamp against the box in any of the four renderers (§2)                                                                                |

### Layering & routing

| Capability                                           | Exemplified by               | Sparkles today | Evidence                                                                                                    |
| ---------------------------------------------------- | ---------------------------- | -------------- | ----------------------------------------------------------------------------------------------------------- |
| A top layer that paint _and_ hit-testing both honour | [`popover-api`][popover-api] | `absent`       | `DCK13`'s rung is reserved and empty (`containers.md:98`); hue's popup hit-tests itself (`gui.d:2152-2158`) |
| Overlay tree / parent link for cascading behaviour   | [`angular-cdk`][angular-cdk] | `absent`       | —                                                                                                           |
| Overlay excluded from its host's content extent      | [`flutter`][flutter]         | `absent`       | `popup` contributes to its parent's natural size like any child (`layout.d:296`, `:410`)                    |
| Named z-bands rather than a free integer priority    | [`textual`][textual]         | `absent`       | paint order is the only ordering (`interp/cells.d:12`)                                                      |

### Triggers, timing & hover intent

| Capability                                                  | Exemplified by               | Sparkles today               | Evidence                                                                                                           |
| ----------------------------------------------------------- | ---------------------------- | ---------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| Trigger set declared as data, resolved against capabilities | [`zag`][zag]                 | `partial`                    | the pattern ships — `ScrollbarState.expanded(in InputCapabilities)` (`IXB10`) — but no overlay reads it (`IXR26`)  |
| Warm-up (open delay)                                        | [`wpf`][wpf]                 | `absent`                     | `Timeline.fadeIn` already reports `visible() == true` (`state.d:1245`), so it cannot host a delay                  |
| Cool-down / skip-delay shared across a group                | [`react-aria`][react-aria]   | `absent`                     | —                                                                                                                  |
| Max display duration / persist-until-dismissed              | [`wpf`][wpf]                 | `partial`                    | `Timeline`'s `holdMs` + `holdUntilDismissed` are the shape; on the TUI the clock is `0` (§8.1)                     |
| A frame clock on every target                               | —                            | `partial`                    | `TuiHost.frameSeconds()` returns `0` (`tui_loop.d:109`); the gallery detects this by observation (`gallery.d:134`) |
| Hover intent / safe area between trigger and content        | [`floating-ui`][floating-ui] | `application responsibility` | hue's GUI hand-rolls a rectangle (`gui_state.d:318`, `gui.d:2468-2471`); the TUI has none                          |
| Bare-motion pointer reporting                               | —                            | `partial`                    | `RunConfig.motion` defaults `false` (`host.d:81`)                                                                  |
| Pointer-type distinction (mouse / touch / pen)              | [`compose`][compose]         | `absent`                     | `PointerEvent` carries `{action, button, pos, mods, pointerId}` and no device kind                                 |

### Dismissal, focus & modality

| Capability                                      | Exemplified by                           | Sparkles today               | Evidence                                                                                                                                                    |
| ----------------------------------------------- | ---------------------------------------- | ---------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Reason-tagged dismissal as a value              | [`zag`][zag]                             | `absent`                     | —                                                                                                                                                           |
| Two-phase outside-press identity test           | [`popover-api`][popover-api]             | `partial`                    | `PressState` (`STM10`, `state.d:1393`) implements press-arms / release-over-same-target; nothing uses it for dismissal                                      |
| Escape ≡ platform back, one equivalence         | [`apple`][apple]                         | `present`                    | `INP13` full — `sparkles.input.events.isDismiss`                                                                                                            |
| A dismissal chain an application can order      | —                                        | `application responsibility` | the gallery's Escape ladder (`gallery.d:1413`) is hand-written per app                                                                                      |
| Light-dismiss vs modal declared per surface     | [`winui`][winui]                         | `absent`                     | —                                                                                                                                                           |
| Pointer modality (an overlay that blocks below) | [`qt-quick-controls`][qt-quick-controls] | `absent`                     | `HoverState` has no notion of a blocking layer                                                                                                              |
| Keyboard modality                               | [`imgui`][imgui]                         | `application responsibility` | the gallery's early `return` (`gallery.d:376-383`), tested at `:1397`                                                                                       |
| Focus containment / trap                        | [`react-aria`][react-aria]               | `absent`                     | `FocusState` (`state.d:1316`) is one `size_t` traversed over a **caller-supplied** order array; there is no `focusTargets` and no focusable bit on `Widget` |
| Focus restoration guarded by "still inside"     | [`blink`][blink]                         | `absent`                     | —                                                                                                                                                           |
| Scrim / dimming layer                           | [`qt-quick-controls`][qt-quick-controls] | `partial`                    | `fillRect` with `bgAlpha` composites, but the cell canvases blend background only, so glyphs stay at full brightness                                        |
| Pointer grab for outside-surface events         | [`qt-widgets`][qt-widgets]               | `absent`                     | `UI-O3` / `INP9`, open                                                                                                                                      |

### Presentation, adaptation & accessibility

| Capability                                           | Exemplified by             | Sparkles today | Evidence                                                                                                           |
| ---------------------------------------------------- | -------------------------- | -------------- | ------------------------------------------------------------------------------------------------------------------ |
| Enter/exit presence machine                          | [`radix`][radix]           | `present`      | `Timeline` (`STM6`, `state.d:1190`), already used for the hover fade                                               |
| Reduced-motion as an input                           | [`aria-apg`][aria-apg]     | `absent`       | no `prefers-reduced-motion` path anywhere; on static HTML it could be _emitted_ rather than discovered             |
| Adaptive form ladder (popover → sheet → inline)      | [`apple`][apple]           | `absent`       | —                                                                                                                  |
| Declared degradation instead of silent drop          | —                          | `partial`      | `TGT5` — input axes declared and consumed (`IXB10`); the chrome half is still prose (`backends.md:42`)             |
| Accessibility role / name / description relation     | [`aria-apg`][aria-apg]     | `absent`       | no backend emits any role, name, description or announcement; note `Slot` already claims the word "role" for style |
| A published substitution when a reveal is suppressed | [`react-aria`][react-aria] | `absent`       | `IXR26`'s popup simply assumes hover and offers nothing on Android                                                 |

---

## 11. What the evidence says the split is

Two independent readings agree. `backends.md`'s degradation inventory and §3's table
arrive at the same line from opposite directions: the parts of an anchored overlay that
survive on **every** current target are the ones expressible as **arithmetic over
Regular values** — anchor rect, content size, boundary, policy → geometry. The parts
that do not survive are the ones that need a **surface** (a grab, an OS top layer,
compositor-owned dismissal) or a **clock** (warm-up, cool-down, auto-hide).

That suggests — and this is an inference from the baseline, to be tested against the
corpus in [`comparison.md`][comparison] and settled in [`proposal.md`][proposal], not a
conclusion drawn here — that the surface-independent core is a candidate for a pure
`place()` returning a value, and the surface-specific remainder is a candidate for a
**declared capability** (`TGT5` / `InputCapabilities`) rather than for prose in a spec.
[`xdg-positioner`][xdg-positioner] is the strongest external witness for the first half
(a placement algebra evaluated in another process, out of ~40 bytes of POD); the static
HTML target is the sharpest test of the second.

The three concrete things this baseline says the primitive must retire, independent of
which design wins:

1. **One placement definition**, in `sparkles:ui`, consuming an anchor **rect** and a
   boundary **rect** in one named coordinate space — replacing two helpers in
   `sparkles:twoslash` called three ways (`PRN8`).
2. **A top layer occupying `DCK13`'s reserved rung**, so an overlay's hit targets join
   the shared derived lists instead of each host keeping a private one — which is what
   `DCK5`'s finished hint view is waiting for.
3. **A resolved `Side` in the placement result**, so the four arrow renderers stop
   hard-coding the top edge and the notch can point at the thing it names.

---

## Sources

**In this repository** (read at review time):

- `libs/ui/src/sparkles/ui/widget.d`, `style.d`, `geometry.d`, `layout.d`,
  `display_list.d`, `state.d`, `dock.d`, `components/chrome.d`, `interp/{cells,html,html_semantic}.d`
- `libs/ui-tui/src/sparkles/ui_tui/grid_canvas.d`,
  `libs/ui-raylib/src/sparkles/ui_raylib/raylib_canvas.d`
- `libs/ui-app/src/sparkles/ui_app/{host,tui_loop,record}.d`
- `libs/twoslash/src/sparkles/twoslash/render_widgets.d`
- `apps/hue/src/{gui,gui_state,tui,twoslash_tui}.d`
- `apps/ui-gallery/src/{gallery,state,registry}.d`, `src/pages/primitives.d`
- `docs/specs/ui/{principles,layout,widgets,state-machines,input,containers,backends,interaction-review,open-issues,feature-requirements}.md`
- `docs/specs/hue/{notifier,overlays,feature-requirements}.md`

**Sibling research trees** that own the questions this page defers:

- [Window-system integration][wsi] — `xdg_popup` grab semantics versus X11
  override-redirect, the in-canvas fork, and the end-to-end windowing harness that would
  validate `UI-O3`.
- [Platform UI guidelines][platform-ui] — the appearance side of the same surfaces.
- [UI layout][ui-layout] — the box-flow engine every placement here runs after.
- [Sean Parent's talks][sean-parent] — the value-semantics and local-reasoning arguments
  behind `PRN8`, `PRN11` and `STM12`.

<!-- References -->

[angular-cdk]: ./angular-cdk.md
[apple]: ./apple.md
[aria-apg]: ./aria-apg.md
[avalonia]: ./avalonia.md
[blink]: ./blink.md
[comparison]: ./comparison.md
[compose]: ./compose.md
[concepts]: ./concepts.md
[css-anchor]: ./css-anchor.md
[floating-ui]: ./floating-ui.md
[flutter]: ./flutter.md
[forgotten]: ./features-people-forget.md
[gpui]: ./gpui.md
[gtk4]: ./gtk4.md
[imgui]: ./imgui.md
[index]: ./index.md
[popover-api]: ./popover-api.md
[proposal]: ./proposal.md
[qt-quick-controls]: ./qt-quick-controls.md
[qt-widgets]: ./qt-widgets.md
[radix]: ./radix.md
[react-aria]: ./react-aria.md
[slint]: ./slint.md
[textual]: ./textual.md
[tippy]: ./tippy.md
[winui]: ./winui.md
[wpf]: ./wpf.md
[xdg-positioner]: ./xdg-positioner.md
[zag]: ./zag.md
[notifier]: ../../specs/hue/notifier.md
[overlays]: ../../specs/hue/overlays.md
[principles]: ../../specs/ui/principles.md
[platform-ui]: ../platform-ui-guidelines/index.md
[sean-parent]: ../sean-parent/index.md
[ui-layout]: ../ui-layout/index.md
[wsi]: ../window-system-integration/index.md
