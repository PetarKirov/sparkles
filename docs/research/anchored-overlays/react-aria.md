# React Aria (TypeScript / React)

React Aria is a headless behavior layer — no rendering, no styling, no compositor — whose overlay stack pairs a hand-written ~850-line placement engine with a document-global tooltip warm-up machine, and treats "modal" as three independent switches rather than one platform state.

| Field            | Value                                                                                                                        |
| ---------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| Language         | TypeScript                                                                                                                   |
| License          | Apache-2.0                                                                                                                   |
| Repository       | <https://github.com/adobe/react-spectrum>                                                                                    |
| Documentation    | <https://react-spectrum.adobe.com/react-aria/>                                                                               |
| Category         | Web / headless behavior                                                                                                      |
| Package versions | `react-aria` 3.51.0, `react-stately` 3.49.0, `react-aria-components` 1.20.0                                                  |
| Surface model    | In-canvas: a React portal into `document.body`. No OS popup and no browser top layer — no `<dialog>`, no `popover` attribute |
| Revision read    | `7c0765468a1d161ab9ac88ca9f1b54d3603a275c`                                                                                   |
| Reading method   | Source read only — no builds, no test runs, no browser observation                                                           |

---

## Overview

### What it solves

React Aria supplies the _behavior_ of an anchored overlay and nothing else: where
the surface goes, when it opens, when it closes, who holds focus, and what an
assistive technology sees. Rendering is the caller's problem; the hooks return
prop bags that the component spreads onto its own DOM.

Positioning is a hand-written engine ([`calculatePosition.ts`][calc], 849 lines)
that is deliberately independent of [Floating UI](./floating-ui.md) and
deliberately narrower in scope. There is exactly one flip candidate (the 180°
opposite on the main axis), exactly one shift (cross-axis only), and a
`maxHeight` clamp where other engines shift on the main axis. There is no
middleware pipeline, no fallback-placement list, no auto-placement. See
[concepts.md](./concepts.md) for the shared vocabulary — _anchor rect_,
_placement_, _constraint adjustment_, _flip/shift/slide/resize_, _clipping
boundary_, _light dismiss_, _safe polygon_, _warm-up_, _focus scope_,
_virtual anchor_, _transform origin_ — used throughout below.

The flip rule is comparative rather than a fit test, and the source says so in
one line (`calculatePosition.ts:494`):

> ```
> // If the available space for the flipped position is greater than the original available space, flip.
> ```

Accessibility is the layer's real product. [`ariaHideOutside.ts`][hide] — a
ref-counted `aria-hidden`/`inert` tree walker over a stack of
`MutationObserver`s — and not any compositor, is what makes an overlay
"modal" here.

### Design philosophy

Three choices shape everything else.

**Positioning is a pure function wrapped in a measurement shell.**
`calculatePositionInternal` (`calculatePosition.ts:417`) takes 18 plain
arguments — all records and scalars, no DOM — and returns a plain
`PositionResult`. `calculatePosition` (`:646`) is the adapter that measures
rects, containing blocks, margins and the visual viewport and calls it.

**Re-anchoring is refused.** There is no `requestAnimationFrame` loop, no
`IntersectionObserver`, no `autoUpdate` equivalent. An overlay repositions on
mount, on prop change, on `window` resize, on a `ResizeObserver` for the overlay
and for the target, and on visual-viewport resize/scroll. Anything else either
locks scrolling (modal) or closes the overlay (non-modal).

**Timing is global, not per-widget.** Tooltips share module-level
`globalWarmedUp` / `globalWarmUpTimeout` / `globalCooldownTimeout` plus a
registry of every mounted tooltip's hide function, which is what produces
"the first tooltip waits, its neighbours appear instantly, warmth decays".
The rule is six lines (`useTooltipTriggerState.ts:172-181`):

> ```
> globalWarmUpTimeout = setTimeout(() => {
>   globalWarmUpTimeout = null;
>   globalWarmedUp = true;
>   // First tooltip in a sequence: animate in.
>   showTooltip(false);
> }, delay);
> } else if (!isOpen) {
>   // Already warmed up: appear instantly without an animation.
>   showTooltip(true);
> }
> ```

A fourth, quieter principle: **the library refuses to unify tooltip and
popover.** `useTooltipTrigger` never calls `useOverlay`, and the non-modal
escape hatch on `usePopover` carries an explicit warning
(`usePopover.ts:44-49`):

> ```
> * Most popovers should not use this option as it may negatively impact the screen
> * reader experience. Only use with components such as combobox, which are designed
> * to handle this situation carefully.
> ```

---

## How it works

The overlay pipeline is four independent hooks that a component composes with
`mergeProps`. `usePopover` is the canonical composition; `useTooltipTrigger` is
the deliberate non-composition.

```text
usePopover (usePopover.ts:87-151)
  ├─ useOverlay            → dismissal: outside-interaction, Escape, focus-outside, scroll
  ├─ useOverlayPosition    → geometry: measure → calculatePosition → PositionResult
  ├─ usePreventScroll      → scroll modality (ref-counted, global)
  ├─ ariaHideOutside       → AT modality (ref-counted, stack of MutationObservers)
  └─ useFocusWithin        → focus-outside close

useTooltipTrigger (useTooltipTrigger.ts:48-160)
  ├─ useHover + useFocusable   → two boolean latches, isHovered / isFocused
  ├─ document-capture Escape   → close from anywhere
  └─ (the component separately calls useOverlayPosition)
```

The geometry pass itself is two rounds of the same arithmetic, because the
`maxHeight` clamp changes the size that the arithmetic consumes:

```text
calculatePositionInternal (calculatePosition.ts:417-640)
  pass 1  position  = computePosition(placement)            # :265
          space     = getAvailableSpace(placement)          # :379
          if flip && overlay[mainSize] > space:
              flipped = computePosition(FLIPPED_DIRECTION)  # :465
              if getAvailableSpace(flipped) > space: adopt  # :495
  pass 2  position.cross += getDelta(crossAxis)             # :180
          maxHeight  = getMaxHeight(...)                    # :321
          overlaySize[size] = min(overlaySize[size], maxHeight)
          position  = computePosition(...)   # redo with shrunken height
          position.cross += getDelta(crossAxis)             # redo
  arrow   clamp inside the anchor, then clamp inside the overlay   # :573-613
  meta    triggerAnchorPoint from the arrow and the facing edge    # :615-639
```

`PositionResult` (`calculatePosition.ts:69-76`) is six fields: `position`,
`arrowOffsetLeft?`, `arrowOffsetTop?`, `triggerAnchorPoint`, `maxHeight`,
`placement`. There is no `maxWidth`.

Dismissal is a module-global array plus a two-phase pointer test:

```text
useOverlay.ts:61   const visibleOverlays: RefObject<Element | null>[] = []
useOverlay.ts:94   onHide() fires onClose only if visibleOverlays[last] === ref
useInteractOutside.ts:44  pointerdown (capture) validates + latches isPointerDown
useInteractOutside.ts:70  click       (capture) confirms and dismisses
```

---

## The analysis spine

### 1. Anchor model

The public anchor is a `RefObject<Element>` (`targetRef`), but internally
everything collapses to one record `Offset {top, left, width, height}` named
`childOffset`, expressed in the _containing block's_ coordinate system. Two
overrides produce the same record: `getTargetRect(target)`
(`useOverlayPosition.ts:151`) for text ranges and arbitrary sub-regions, and
`state.point` on `OverlayTriggerState`
(`useOverlayTriggerState.ts:42`), which `usePopover` converts with
`new DOMRect(x, y, 0, 0)` (`usePopover.ts:125`) — a cursor anchor is a
**zero-size rect** and nothing more. There is no virtual-element interface, no
multi-rect anchor, and no moving-anchor concept.

Trigger and anchor are already detached: `targetRef` need not be the pressed
element. Many-triggers-one-popup is not modelled — each trigger owns its own
state hook.

**Algorithm.** `anchorRect := overrideRect ?? getBoundingClientRect(target)`.
`getOffset`/`getPosition` (`:762`, `:777`) then subtract the containing block's
border and scroll and the node's own margins; when the containing block is the
document element they add `scrollTop`/`scrollLeft` and subtract
`clientTop`/`clientLeft` instead, and `position: fixed` nodes skip the
document-scroll step. `getContainingBlock` (`:805`) re-implements the CSS
containing-block rules because `offsetParent` is wrong for fixed positioning and
for `transform` / `filter` / `contain: paint` / `backdrop-filter` ancestors
(`isContainingBlock`, `:839`).

A context-menu point is captured _target-relative_ in `useContextMenu` and
re-absolutised at `useMenuTrigger.ts:155` (`rect.x + e.x`), so the point survives
the target moving between the event and the open.

**Where the behavior lives.** Library only: `calculatePosition.ts:646-747`
(shell) and `:762-849` (coordinate conversion). The point lives in
`react-stately`.

**Degradation.** The model survives every constraint intact: it is four numbers,
already a comparable value, and entirely surface-relative — no OS window, no
sub-cell precision and no key release are involved anywhere. The one hazard is
the degenerate cross-axis clamp discussed in dimension 4: the interval
`[minPosition, maxPosition]` at `calculatePosition.ts:298-303` narrows by the
anchor's cross extent, so a zero-extent anchor brings it closer to inversion —
though inversion requires `2 * (arrowSize + arrowBoundaryOffset)` to exceed
_anchor cross extent + overlay cross extent_, which a normally sized overlay does
not reach. Where it does invert, `clamp` (`number.ts:17`, `min(max(v, min), max)`)
silently returns `max`. This appears not to bite in practice because React Aria
Components' context menus render no arrow — an inference from the component
sources, not an observed failure.

### 2. Placement model

Twenty-two placement strings (`useOverlayPosition.ts:22-44`): four physical sides
plus `start`/`end`, each optionally carrying a cross alignment.
`translateRTL` (`:425`) is a _string replace_ performed before parsing —
`start` → `left`/`right`, `end` → `right`/`left` by locale direction. That is the
only logical-property support: no writing modes, no vertical text.

`parsePlacement` (`:246`) splits on a space and derives
`{placement, crossPlacement, axis, crossAxis, size, crossSize}` through four
constant tables (`AXIS`, `FLIPPED_DIRECTION`, `CROSS_AXIS`, `AXIS_SIZE`, from
`:78`), memoised in a module-global `PARSED_PLACEMENT_CACHE`. An unknown main
placement defaults to `right`; an unknown cross alignment defaults to `center`.

There is **no preferred-placement list and no fallback ordering**. Cross-axis
alignment is never flipped. Main-axis overflow is resolved by shrinking, not by
shifting. Viewport padding is `containerPadding` (default `12`,
`useOverlayPosition.ts:187`) applied uniformly on all four sides. The custom
boundary is `boundaryElement` (default `document.body`, `:189`), which is
distinct from the _containing block_; the engine carries a three-case
reconciliation between them (`containerOffsetWithBoundary`,
`calculatePosition.ts:698-724`).

**Algorithm.**

```text
placement := parse(translateRTL(input, direction))
axis      := {top,bottom} → 'top'; {left,right} → 'left'
main:  if placement == axis                       # i.e. 'top' or 'left'
           position[FLIPPED_DIRECTION[axis]] = floor(containerSize - child[axis] + offset)
       else
           position[axis] = floor(child[axis] + child[size] + offset)
cross: start  → child[crossAxis]
       center → + (child[crossSize] - overlay[crossSize]) / 2
       end    → + (child[crossSize] - overlay[crossSize])
       + crossOffset
       then clamp to keep ≥ arrowSize + arrowBoundaryOffset of overlap with the anchor
```

The `top`/`left` branch pins the overlay's _far_ CSS edge so the box grows away
from the anchor; that is a CSS artifact of not knowing the overlay's final height
before the clamp.

Multi-monitor and work areas do not apply — the coordinate space is one document.
Safe-area (notch) insets are **absent**: a grep for `safe-area-inset` across
`react-aria`, `react-aria-components` and the S2 design system returns nothing.
Virtual-keyboard avoidance _is_ handled, but by re-running the whole computation
on `visualViewport` resize behind a 500 ms `isResizing` window that also
suppresses close-on-scroll (`useOverlayPosition.ts:347-375`).

**Where the behavior lives.** Library: the tables and `parsePlacement` in
`calculatePosition.ts`, the RTL translation in `useOverlayPosition.ts`.

**Degradation.** The parse tables and the 6-field record are compile-time
friendly; in a cell-space toolkit they would be an enum plus a `static immutable`
table with no cache. The pinned-far-edge branch and the whole
`isContainerPositioned` / `TOTAL_SIZE` reconciliation exist only because CSS
`bottom`/`right` are relative to a container — with one surface and one
coordinate system a port computes `y = anchor.top - height - offset` directly.
The keyboard inset only ever enters the algorithm as `boundaryDimensions`, so
supplying it as an _input_ rather than discovering it from a viewport event
changes nothing else in the arithmetic.

### 3. Collision & geometry engine

Overflow detection is arithmetic over two `Dimensions` records, never
hit-testing. `getAvailableSpace` (`:379`) computes free main-axis space on one
side of the anchor; `getDelta` (`:180`) computes the cross-axis correction.

`getDelta`'s asymmetry is the notable part: if the start edge overflows it
returns the full start correction; if the end edge overflows it returns
`Math.max(endCorrection, startCorrection)` — so when the overlay is _larger_
than the boundary, the start edge is pinned and the end is allowed to overflow.

Clipping-ancestor discovery does not exist. There is one `boundaryElement`
supplied by the caller plus the visual viewport; scroll containers are handled by
_closing_ (dimension 8), not by clipping.

Transforms and zoom get two specific answers. `getRect(node, ignoreScale)`
(`:749`) deliberately reads `offsetWidth`/`offsetHeight` instead of the bounding
rect when `ignoreScale` is set, so a CSS `scale()` on the overlay does not
corrupt its measured size. Pinch-zoom is handled by _freezing_:

> ```
> if (visualViewport?.scale !== lastScale.current) {
>   return;
> }
> ```
>
> — `useOverlayPosition.ts:245-247`

plus a WebKit-specific correction that zeroes `body.scrollTop`/`scrollLeft` and
switches to `visualViewport.pageTop`/`pageLeft`
(`calculatePosition.ts:152-165`).

Fractional pixels: only the **main** axis is floored (`:314`, `:316`); the cross
axis and the arrow offset stay fractional.

There is no top layer. The overlay is `position: absolute` with a hard-coded
`zIndex: 100000` (`useOverlayPosition.ts:397`) whose comment says it must match
`ModalTrigger`'s.

Tracking is five discrete sources: a layout effect over a large dependency array,
`window` resize, `ResizeObserver` on the overlay, `ResizeObserver` on the target,
and `visualViewport` resize/scroll (`:328-375`). Anchor _movement without a
resize_ is therefore not tracked at all.

**Where the behavior lives.** `calculatePositionInternal` (`:417`) is DOM-free;
`calculatePosition` (`:646`) is the measurement shell; tracking is in
`useOverlayPosition.ts` over `useResizeObserver`.

**Degradation.** This dimension is the most portable part of the subject: the
core is already a pure function of records. It is worth noting that although
`calculatePositionInternal` is exported, its only call site is its own DOM shell
— the placement tests go through `calculatePosition` with mocked
`getBoundingClientRect` (`test/overlays/calculatePosition.test.ts`), so the pure
core is not exercised as a pure core. What would not carry over:
`getContainingBlock`, `getMargins`, the WebKit pinch-zoom correction, the
`zIndex`, and the `containerOffsetWithBoundary` reconciliation — roughly the
portion of the file that exists because a document has many coordinate systems.
Integer cells remove the floor-one-axis-only inconsistency for free.

### 4. Arrow / caret geometry

Arrow geometry here is **data, and it is bidirectional**: within this source tree
the arrow's requirements constrain the popup's position rather than being
computed afterwards as decoration.

Inputs are `arrowSize` (explicit, or measured as
`getRect(arrowRef.current, true).width`, `useOverlayPosition.ts:289`) and
`arrowBoundaryOffset` (the arrow's minimum distance from the overlay's edge).
Outputs are `arrowOffsetLeft` / `arrowOffsetTop` — only the cross-axis one is
defined — plus the resolved `placement`.

Three constraint layers:

1. The overlay's own cross position is clamped so at least
   `arrowSize + arrowBoundaryOffset` of it overlaps the anchor
   (`calculatePosition.ts:298-303`):

   > ```
   > const minPosition =
   >   childOffset[crossAxis] - overlaySize[crossSize] + arrowSize + arrowBoundaryOffset;
   > const maxPosition =
   >   childOffset[crossAxis] + childOffset[crossSize] - arrowSize - arrowBoundaryOffset;
   > position[crossAxis] = clamp(position[crossAxis]!, minPosition, maxPosition);
   > ```

2. The arrow's preferred position is the anchor's centre expressed in
   overlay-local coordinates (`origin = child.cross - pos.cross - margin`, then
   `+ 0.5 * childCrossSize`, `:580`), clamped to stay inside the anchor inset by
   `arrowSize / 2` (`:584`).
3. Clamped again to stay inside the overlay inset by
   `arrowSize / 2 + arrowBoundaryOffset` (`:604`).

When the two ranges are disjoint the second clamp wins: the arrow detaches from
the anchor but never leaves the overlay. **There is no hide-the-arrow behavior
and no detachment flag** — a caller cannot tell that the arrow stopped pointing
at anything.

Corner avoidance is configuration, not knowledge inside the engine: the design
system measures its own computed `border-radius` at ref time and feeds it in
(`@react-spectrum/s2/src/Tooltip.tsx:183`, `:206` — `arrowBoundaryOffset={borderRadius}`).
The arrow's main-axis cost is likewise the caller's job — the same file passes
`offset={4 + 5} // 4px offset + 5px arrow height` (`:209`).

**Where the behavior lives.** Library, inside `calculatePositionInternal`
(`:573-613`). Shape and rendering are entirely in the component layer
(`react-aria-components/src/OverlayArrow.tsx`), which adds
`position: absolute`, `style[placement] = '100%'` and a 50% translate on the
perpendicular axis.

**Degradation.** In whole cells an arrow is one cell carrying a directional glyph
(`▲▼◀▶` or a box-drawing junction), so `arrowSize == 1` and `arrowSize / 2`
degenerates to zero; both clamps would collapse into "the arrow cell must lie in
the intersection of the anchor's span and the overlay's span inset by
`arrowBoundaryOffset`, otherwise pin to the overlay edge". `arrowBoundaryOffset`
becomes 1 when the overlay has a box border and 0 otherwise — which is exactly
the semantics S2 derives from a border radius. Constraint (1) is the part worth
keeping verbatim: at one-cell granularity it reads "never place the popup so that
none of its cells is adjacent to the anchor". With no script, the arrow can be a
static decoration on a fixed side, since nothing is measured at emit time.

> [!WARNING]
> The engine computes arrow detachment implicitly and discards it. Any port that
> wants a "hide the caret when it no longer points at the anchor" behavior has to
> add the flag; it is not recoverable downstream from `PositionResult`.

### 5. Trigger semantics

Triggers are separate hooks composed with `mergeProps`, and the races between
them are resolved by a **global modality oracle plus per-trigger boolean
latches**, never by event ordering.

`useFocusVisible` maintains module-global `currentModality ∈ {keyboard, pointer, virtual}`
and `currentPointerType` (`useFocusVisible.ts:45-46`), driven by capture-phase
document listeners on `keydown`/`keyup`/`click`/`pointerdown`/`pointermove`/
`pointerup` plus window focus/blur. It also patches `HTMLElement.prototype.focus`
so that programmatic focus sets `hasEventBeforeFocus` (`:178`) and therefore does
_not_ switch modality. A focus event with no preceding user event promotes the
modality to `virtual` (`:130`) — screen reader, or iOS form navigation.
`isFocusVisible()` is `currentModality !== 'pointer'` (`:292`).

`useTooltipTrigger` keeps two refs, `isHovered` and `isFocused`, and every path
recomputes `if (isHovered || isFocused) open() else close()`. The Chrome
re-fires-hover-when-an-obscuring-element-disappears race is fixed by consulting
the oracle inside `onHoverStart` (`useTooltipTrigger.ts:89`):
`isHovered.current = (getInteractionModality() === 'pointer')`. `onFocus`
(`:118`) latches only if `isFocusVisible()`. Focus opens _immediately_
(`state.open(isFocused.current)`, `:52`); hover opens through warm-up.

`useHover` refuses `pointerType === 'touch'` outright (`useHover.ts:111`) and
keeps a global 500 ms `globalIgnoreEmulatedMouseEvents` window (`:38-54`) after
any touch `pointerup`, to swallow iOS's synthetic mouse-enter.

Menus differentiate further: `useMenuTrigger` opens on press-start for
mouse/keyboard but on press (up) for touch; `trigger='longPress'` routes through
`useLongPress`; `trigger='contextMenu'` routes through `useContextMenu`, which
normalises right-click, macOS Ctrl+click, Shift+F10, and an iOS long press
(`useContextMenu.ts:60`, `:81`) because iOS never fires `contextmenu`.

**Algorithm.**

```text
handleShow()          : if (isHovered || isFocused) state.open(immediate := isFocused)
handleHide(immediate) : if (!isHovered && !isFocused) state.close(immediate)
onHoverStart : isHovered := (globalModality == 'pointer'); handleShow()
onHoverEnd   : isFocused = isHovered = false; handleHide()
onFocus      : if isFocusVisible() { isFocused = true; handleShow() }
onBlur       : both latches false; handleHide(true)
onPressStart : both latches false; handleHide(true)
```

**Where the behavior lives.** `useTooltipTrigger.ts:48-160` (latches),
`useFocusVisible.ts` (modality), `useHover.ts` (emulated-mouse suppression),
`useContextMenu.ts` (cross-platform normalisation).

**Degradation.** The two-latch + global-modality pattern needs nothing from the
DOM. With no key release, nothing here is lost: every overlay trigger is
keydown-driven, and only `usePress`'s click activation consults key-up. With no
hover, the machinery is structurally unreachable — and React Aria's answer is a
_different hook_ (`useLongPress`, `usePreviewTrigger`), i.e. it concedes that a
hover trigger has no touch equivalent and substitutes a long press at the
component layer. With no script, only tier-0 `:hover`/`:focus-within` survive:
the modality oracle cannot exist, so pointer-versus-keyboard distinctions vanish
and hover and focus must behave identically. Modality is a settable global
(`setInteractionModality`), which is what makes the whole thing testable.

### 6. Timing

The warm-up machine is about sixty lines of module-global state and it is the
most transferable behavior in the subject.

Globals (`useTooltipTriggerState.ts:74-78`): `tooltips` (id → hide function),
an id counter, `globalWarmedUp`, `globalWarmUpTimeout`, `globalCooldownTimeout`.
Per-instance: `isOpen`, `shouldSkipAnimation`, `closeTimeout`, `id`. Constants:
`TOOLTIP_DELAY = 1500`, `TOOLTIP_COOLDOWN = 500` (`:53-54`).

Non-obvious rules, each readable in the source:

- **(a)** The cooldown is armed only `if (globalWarmedUp)` (`:149`), so
  abandoning a hover mid-warm-up leaves the system _cold_ and the next hover pays
  the full delay again. A test in the design-system suite is named for exactly
  this case (`TooltipTrigger.test.js:710`).
- **(b)** `hideTooltip` unconditionally clears `globalWarmUpTimeout` (`:145-148`),
  so leaving trigger A cancels A's pending warm-up even though A never opened.
- **(c)** The cooldown duration is `Math.max(TOOLTIP_COOLDOWN, closeDelay)`
  (`:159`) — the 500 ms floor is hard-coded and _not_ derived from `delay`.
- **(d)** `open(immediate)` routes to `warmupTooltip()` only when
  `!immediate && delay > 0 && !closeTimeout.current` (`:203`), so re-hovering a
  tooltip that has a pending close re-shows instantly.
- **(e)** `showTooltip` calls `closeOpenTooltips()` (`:99`), which invokes every
  _other_ registered tooltip's `hide(immediate, instant)` and unregisters it —
  the singleton guarantee is enforced by a registry, not by a provider.
- **(f)** `shouldSkipAnimation` is a **third channel** orthogonal to open/close:
  during a warm swap both the outgoing and incoming tooltips receive
  `instant = true`, so neither animates.

**Algorithm.**

```text
open(immediate=false):
    if !immediate && delay > 0 && closeTimeout == null  → warmup()
    else                                                → show(instant := globalWarmedUp)

warmup():
    closeOthers(); register()
    if !isOpen && !globalWarmedUp:
        clear(gWarm); gWarm := after(delay) { gWarm := null; globalWarmedUp := true; show(instant=false) }
    else if !isOpen:
        show(instant=true)

show(instant):
    clear(own closeTimeout); closeOthers(); register()
    shouldSkipAnimation := instant; globalWarmedUp := true; isOpen := true
    clear(gWarm); clear(gCool)

hide(immediate=false, instant=false):
    shouldSkipAnimation := instant
    if immediate || closeDelay <= 0 { clear(own); close() }
    else if own == null           { own := after(closeDelay) { close() } }
    clear(gWarm)
    if globalWarmedUp: restart gCool := after(max(500, closeDelay)) { unregister(id); globalWarmedUp := false }
```

`usePreviewTrigger` / RAC `PreviewTrigger` reuse the same machine with different
constants (`delay: 600, closeDelay: 200`, `PreviewTrigger.tsx:47-48`) and forward
`shouldSkipAnimation` into `Popover`. Submenus use a separate 200 ms open timer
with no global warmth (`useSubmenuTrigger.ts:98`, `:252`). There is no max
display duration and no provider scoping of any kind — warmth is document-global.

**Where the behavior lives.** `react-stately/src/tooltip/useTooltipTriggerState.ts:74-214`.
Nothing DOM-dependent except `setTimeout`; the events and ARIA live in a separate
file.

**Degradation.** This is pure logic over a timer source and an id → callback
registry. In a value-semantics port the registry collapses into a single owner
holding `activeId`, `warmedUp` and two deadlines — a callback map is unnecessary
once the owner decides who is open. Driving it from a frame clock rather than
`setTimeout` would make every transition assertable by stepping a virtual clock;
React Aria's own state test file drains the leaked global in an `afterEach`
(`useTooltipTriggerState.test.js:80-88`). With no timers at all (static HTML), a
CSS `transition-delay` on `:hover` reproduces the initial delay and nothing else
— there is no way to express warmth. With no hover, the machine is unreachable
and the long-press substitute opens with `state.open(true)`, bypassing timing
entirely.

### 7. Interactive hover

React Aria ships **two different travel algorithms**, developed independently and
never reconciled — which is itself the finding.

**(A) `useSafeArea`** (`useSafeArea.ts`, used by `PreviewTrigger`): pad the anchor
and overlay rects by `PADDING = 8` (`:43`), short-circuit if the pointer is inside
either padded rect, otherwise take the eight padded corners, compute the convex
hull by Andrew's monotone chain (`:123`) and ray-cast the pointer against it
(`:155`):

> ```
> // Otherwise, check whether the point is within the convex hull connecting the two rects.
> let hull = convexHull([...rectCorners(triggerRect), ...rectCorners(overlayRect)]);
> return hull.length >= 3 && isPointInPolygon(point, hull);
> ```
>
> — `useSafeArea.ts:95-97`

It is placement-agnostic and diagonal-safe by construction, samples on every
window `pointermove` with no throttle, ignores `pointerType === 'touch'` (`:62`),
and listens for `pointerleave` on the document element to force "not safe".

**(B) `useSafelyMouseToSubmenu`** (menus only): no polygon. It compares the
_angle of the movement delta_ against the angles from the previous pointer
position to the submenu's near corners, widened by `ANGLE_PADDING = π/12`:

> ```
> let isMovingTowardsSubmenu = anglePointer < angleTop && anglePointer > angleBottom;
> ```
>
> — `useSafelyMouseToSubmenu.ts:143`

Samples are throttled to one per 50 ms; a counter clamped to `[0, 2]`
(`ALLOWED_INVALID_MOVEMENTS`, `:20`) increments on "towards" and decrements
otherwise, and only at 2 does it set `pointer-events: none` on the **parent
menu** so the underlying items stop receiving hover (`:149`). It cancels if the
pointer leaves the parent menu's rect, and arms a 1000 ms watchdog that resets
and then synthesises a `pointerover` at the last cursor position 100 ms later so
the menu can close naturally (`:159-173`). The same guard swallows capture-phase
`pointerdown` so a click during the grace period cannot focus something behind
the menu.

**(C)** The plain tooltip has **no bridge at all**. The gap is covered _in time_,
by the 500 ms `closeDelay`, plus `useTooltip` attaching `useHover` to the tooltip
element itself (`useTooltip.ts:38-41`, `onHoverStart → state.open(true)`), which
cancels the pending close if the pointer actually lands on the tooltip.

**Algorithm.**

```text
(A) inSafeArea(p):
      if p ∈ pad(anchorRect, 8)  → true
      if p ∈ pad(overlayRect, 8) → true
      hull := monotoneChain(corners(pad(anchor,8)) ∪ corners(pad(overlay,8)))
      return |hull| ≥ 3 ∧ rayCast(p, hull)

(B) every ≥ 50 ms:
      toward  := (side == 'right') ? submenu.left - prev.x : prev.x - submenu.right
      angTop  := atan2(prev.y - submenu.top,    toward) + π/12
      angBot  := atan2(prev.y - submenu.bottom, toward) - π/12
      angMove := atan2(prev.y - cur.y, ±(cur.x - prev.x))
      moving  := angBot < angMove < angTop
      count   := clamp(count ± 1, 0, 2)
      parentMenu.pointerEvents := (count ≥ 2) ? 'none' : ''
```

**Where the behavior lives.** Library: `useSafeArea.ts:51-169`,
`useSafelyMouseToSubmenu.ts:20-193`, `useTooltip.ts:38-41`.

**Degradation.** (A) is eight input points, at most eight hull vertices, and on
the order of thirty integer operations per sample with no allocation; the cross
products of integer-cell rects are exact, so a cell-space port needs no floating
point if the ray-cast is written as a cross-product sign test. The 8 px padding
becomes one cell. (B) fares worse: three `atan2` per sample, and — this is an
inference about a hypothetical port, not an observation of this codebase —
angular resolution appears to collapse at cell granularity, since a one-cell
diagonal step in an 8×16 px cell yields very few distinct directions for a ±15°
cone to discriminate. The parts of (B) that look robust regardless of resolution
are the two-step hysteresis counter, the throttle, the leave-the-parent-rect
bail-out and the watchdog. (B) also depends on `pointer-events: none`, which has
no equivalent outside CSS; the analogue is suppressing the parent menu's entries
in a derived hit list for the duration. Both algorithms are disabled at the
source for touch, which is the honest answer when there is no hover. With no
script, neither survives; the only tier-0 safe area is making the gap part of the
hoverable element via a transparent padding band.

### 8. Dismissal

Dismissal spans four mechanisms over one module-global stack.

`useOverlay` keeps `const visibleOverlays: RefObject<Element | null>[] = []`
(`useOverlay.ts:61`), and `onHide()` (`:94`) fires `onClose` only when
`visibleOverlays[last] === ref`, so outside-click and Escape close only the
topmost.

Outside interaction is **two-phase**: capture-phase `pointerdown` validates and
latches `isPointerDown` (`useInteractOutside.ts:44-49`), and only a subsequent
capture-phase `click` triggers the close (`:70-74`). A drag that starts inside
and ends outside therefore does not dismiss, and the Android Chrome `pointerup`
bug that a naive implementation would hit is sidestepped. `isValidEvent`
(`:120`) rejects `button > 0` (so right-click never light-dismisses), targets
detached from the document, and anything inside `[data-react-aria-top-layer]`
(`:132`); it walks `composedPath()` so shadow DOM works.

`useOverlay` adds `onInteractOutsideStart` (`:100`), which records which overlay
was topmost _at pointerdown_ and closes only if that is still this overlay — a
guard against the stack changing between down and click.

Escape has two forms. A popover uses `useKeyboard` on the overlay element (a
bubbling handler, so focus must be inside). A tooltip instead installs a
**document-level capture** `keydown` while open (`useTooltipTrigger.ts:63-77`),
calls `stopPropagation()` and closes immediately — so Escape kills a tooltip from
anywhere.

Focus-outside uses `useFocusWithin({onBlurWithin})` (`useOverlay.ts:148`) and
closes unless `relatedTarget` is null or lies inside a child focus scope:

> ```
> if (!e.relatedTarget || isElementInChildOfActiveScope(e.relatedTarget)) {
> ```
>
> — `useOverlay.ts:160`

A null `relatedTarget` means a tab-switch or a known VoiceOver/Chrome bug rather
than a real departure; the child-scope test is why a menu opening inside a dialog
does not close the dialog.

Scroll: `useCloseOnScroll` (`useCloseOnScroll.ts:40`, `:64`) listens capture-phase
for `scroll` on the trigger's propagation targets and closes if the scroll target
_contains_ the trigger, ignoring `input`/`textarea` (the combobox caret case).
Modal popovers pass `onClose: null`, which disables close-on-scroll entirely
because they lock scrolling instead. The 500 ms `isResizing` window suppresses the
scroll-close a virtual keyboard would otherwise cause.

Right-clicking outside a context menu closes it (`useMenuTrigger.ts:162-172`) by
checking that the mousedown target is `document.body` — which works _because_
everything else has been made inert, a composition of two mechanisms.

Anchor removed, anchor hidden, navigation, parent closing: **not handled by the
primitive**. There is no `IntersectionObserver` and no hide detection; the owning
component unmounting is the only path.

**Algorithm.**

```text
stack := global array of open overlay refs (push on mount, splice on unmount)
pointerdown(capture): if valid(e) { record topOfStack; if top == self stopPropagation; latch }
click(capture)      : if latched ∧ valid(e) { if top == self stopPropagation
                                              if recordedTop == self close() }
Escape (bubble)     : if top == self ∧ !keyboardDismissDisabled close()
blurWithin          : if relatedTarget ≠ null ∧ ¬inChildScope(relatedTarget) close()
scroll (capture)    : if target contains trigger ∧ target ∉ {input, textarea} ∧ !isResizing close()
```

**Where the behavior lives.** `useOverlay.ts:61-171`,
`useInteractOutside.ts:37-135`, `useCloseOnScroll.ts:33-66`,
`useTooltipTrigger.ts:63-77`.

**Degradation.** The stack plus the "only topmost" rule and the two-phase
down/up test are plain data and plain latches. The two-phase test in particular
fails _closed_ where there is no native pointer grab: an event sequence that
leaves the surface between down and up simply never completes the dismissal. No
dismissal path here needs a key release — the keyboard paths are keydown-only and
the pointer path uses pointer down/up. A system back button maps onto `onHide()`
at the top of the stack. With no script, only re-activating the trigger can
close a surface. What does _not_ carry over is close-on-scroll: outside a
document there are no ancestor scroll containers to listen to, and the natural
substitute — "the anchor's rect changed between frames" — is a capability React
Aria explicitly declines to build (see the re-anchoring decision below).

### 9. Focus

Tooltip, popover, menu and dialog are kept genuinely distinct.

- **Tooltip**: no focus management whatsoever. No focus scope, no autofocus,
  focus never enters it; it is described by `aria-describedby` only.
- **Popover (non-modal)**: `Overlay` still wraps it in
  `<FocusScope restoreFocus contain={...}>` (`Overlay.tsx:78`) but with
  containment off unless the popover is acting as a dialog.
- **Popover-as-dialog**: focuses the popover element itself on mount unless focus
  is already inside, and explicitly skips that for `SubmenuTrigger` under a
  pointer modality (so hovering a submenu keeps focus on the trigger) and for
  `PreviewTrigger` (`Popover.tsx:368`, `:390`).
- **Modal**: `useModalOverlay` calls `useOverlayFocusContain()`
  (`useModalOverlay.ts:69`), which sets a context flag turning containment on.

Containment and restoration are separate flags on the same `FocusScope`. The
scope system is a **tree** (`focusScopeTree`) with a module-global `activeScope`
(`FocusScope.tsx:76`); a child scope may become active, an ancestor may not steal
it back.

Restoration is unusually careful. `nodeToRestore` is captured during _render_
(`:633`, with a comment saying this is so it precedes a child's `autoFocus`); on
unmount the tree is **cloned** and the restore deferred to a
`requestAnimationFrame` (`:787-788`), performed only if focus actually landed on
`document.body`; it walks the cloned tree for the first still-connected
`nodeToRestore`, and failing that focuses the first element of the nearest
surviving ancestor scope. The whole path is guarded by "is focus still inside
this scope" (`isElementInChildScope`, `FocusScope.tsx:780-784`). Restoration is
dispatched as a **cancelable** `react-aria-focus-scope-restore` CustomEvent
(`:826-830`), so virtualised collections — and `usePreviewTrigger`, which uses it
to suppress a re-open — can intercept it.

Tab-out-of-scope with `restoreFocus` but no containment is emulated: a Tab
keydown computes the next tabbable after `nodeToRestore` and jumps there
(`:720-728`).

Pointer- versus keyboard-opened differences are real: `useMenuTrigger`
auto-focuses the first item only for `pointerType === 'virtual'`, and
`usePreviewTrigger` moves focus into the popover only when opened by long press.

**Algorithm.**

```text
scope tree + global activeScope
contain : on focusin outside the scope while containing → pull focus back to first/last (wrap on Tab)
restore : nodeToRestore := activeElement captured at render
          on unmount: if focus is in a child scope, or is body and we should restore →
              clone tree; rAF; if activeElement === body:
                  walk ancestors for a connected nodeToRestore
                  dispatch RESTORE_FOCUS_EVENT (cancelable); if not cancelled, focus it
              else focus the first element of the nearest surviving scope
```

**Where the behavior lives.** `FocusScope.tsx` (scope tree, containment,
restoration), `Overlay.tsx:78`, `useModalOverlay.ts:69`, `Popover.tsx`.

**Degradation.** A tree of scopes plus one "active scope" pointer is pure data;
what it needs from the platform is only "what is focusable", which a widget arena
answers directly. The rAF-deferred, tree-cloned restoration exists because React
unmounts asynchronously and focus transiently lands on `document.body`; a
synchronous immediate-mode toolkit would restore at close and skip the whole
apparatus. The cancelable restore event is worth keeping in some form, so a
recycling list can veto a restore. Focus movement is entirely keydown-driven, so
no key release is required. With no script, `:focus-within` gives an opening
mechanism with neither containment nor restoration.

### 10. Layering & portals

There is no browser top layer here: React Aria Components uses neither `<dialog>`
nor the [Popover API](./popover-api.md). Layering is `ReactDOM.createPortal` into
`document.body` (`Overlay.tsx:92`, overridable through `UNSAFE_PortalProvider`)
plus the hard-coded `zIndex: 100000` on the positioned overlay
(`useOverlayPosition.ts:397`).

`data-react-aria-top-layer` is a **marker attribute, not a layer**: it opts an
element out of `ariaHideOutside` (kept visible), out of `useInteractOutside`
(never counts as outside, `useInteractOutside.ts:132`), and out of focus
containment. Toasts use it.

Overlay _trees_ are explicit and there are five of them:

| Structure                                         | Shape                       | Purpose                                                     |
| ------------------------------------------------- | --------------------------- | ----------------------------------------------------------- |
| `visibleOverlays` (`useOverlay.ts:61`)            | flat array                  | dismissal precedence — only the last element dismisses      |
| `focusScopeTree` (`FocusScope.tsx`)               | tree with parent links      | focus containment and restoration                           |
| `observerStack` (`ariaHideOutside.ts:39`)         | stack of `MutationObserver` | only the top is connected; popping re-`observe()`s the next |
| `PopoverGroupContext` (`Popover.tsx:157`)         | context + container ref     | a submenu chain portals into one `display: contents` div    |
| `expandedKeysStack` (`useMenuTriggerState.ts:54`) | `Key[]` by depth            | the open submenu chain                                      |

The group container is the interesting one: a root popover renders an extra
`display: contents` div (`Popover.tsx:375`) and every submenu or subdialog
portals _into it_ (`:376`), so the whole cluster counts as one node for
outside-interaction and aria-hiding (`usePopover.ts:109` passes
`groupRef ?? popoverRef`).

`expandedKeysStack` is the submenu chain as an array of keys indexed by depth
(`useMenuTriggerState.ts:75`, `:85`), so opening and closing a level are array
slices.

Public API versus implementation detail is a deliberate line: `Overlay`,
`UNSAFE_PortalProvider`, `DismissButton`, `ariaHideOutside` and `keepVisible` are
exported; `visibleOverlays`, `observerStack`, `focusScopeTree`,
`PARSED_PLACEMENT_CACHE`, the ref-count map and the tooltip globals are all
module-private. The library's position is that ordering and ownership are
implementation details, and only the tree shape you _declare_ (`groupRef`,
`portalContainer`) is API.

**Algorithm.**

```text
openSubmenu(key, level)  = level > len(stack) ? stack : [...stack.slice(0, level), key]
closeSubmenu(key, level) = stack[level] === key ? stack.slice(0, level) : stack
dismissal precedence     = last element of a push/splice array
aria-hiding precedence   = a stack of observers where only the top is connected
```

**Where the behavior lives.** `Overlay.tsx`, `PortalProvider.tsx`,
`useOverlay.ts`, `ariaHideOutside.ts`, `Popover.tsx`, `useMenuTriggerState.ts`.

**Degradation.** React Aria has no top layer, no stacking context it trusts, and
no compositor ordering — it emulates all three with a portal, one `z-index`, and
explicit data structures. A toolkit where "later in the display list is in front"
is the same model with the emulation removed: the four data structures are plain
values and carry over unchanged, and `expandedKeysStack` in particular makes the
whole nested-menu state one comparable value. The portal itself and the
top-layer marker do not carry over; the marker's semantics ("paint after
everything, exclude from the outside hit test") would become a flag on the
overlay record.

### 11. Modality

"Modal" here is not a platform state; it is three independent switches, and the
library's contribution is showing that they _are_ independent.

1. **Assistive-technology modality** — `ariaHideOutside([popover], {shouldUseInert: true})`,
   which sets `inert` where supported and `aria-hidden='true'` otherwise
   (`ariaHideOutside.ts:64`) on every element outside the targets.
2. **Pointer modality** — `useOverlay({isDismissable})` plus, for real modals, an
   explicit `div` underlay rendered by RAC `Popover` when the popover is not
   non-modal (`Popover.tsx:373`, `position: fixed; inset: 0`). `underlayProps`
   from `useOverlay` is currently an empty object — an extension point.
3. **Scroll modality** — `usePreventScroll`, ref-counted globally
   (`usePreventScroll.ts:32`), with a standard branch (`overflow: hidden` plus
   `scrollbar-gutter: stable` or a compensating `padding-right`) and a long
   mobile-WebKit branch (`:100`) that prevents default on non-scrollable
   `touchmove`, injects an `overscroll-behavior: contain` style layer, and
   patches `HTMLElement.prototype.focus` to use `preventScroll: true` plus a
   manual centre-scroll.

Light dismiss is `isDismissable`. Modeless-but-focus-containing is expressible.
Click-through is **not** expressible except via `shouldCloseOnInteractOutside`
returning false, which stops the dismissal but not the click. Keyboard blocking
outside is not done at all except as a consequence of focus containment.

`keepVisible(element)` (`ariaHideOutside.ts:299`) is the escape hatch: it adds an
element to the current top observer's visible set, so a non-modal popover inside
a modal is not hidden.

**Algorithm.**

```text
modal    := ariaHideOutside(targets) ∧ preventScroll() ∧ underlay ∧ focus containment
nonModal := keepVisible(target) ∧ nothing else

ariaHideOutside refcount (hide n):
    c := refCount[n] ?? 0
    if hidden(n) ∧ c == 0: return          # respect a pre-existing author aria-hidden
    if c == 0: setHidden(n, true)
    refCount[n] := c + 1
revert:
    for each hidden n: c == 1 ? unhide + delete : refCount[n] := c - 1
```

**Where the behavior lives.** `ariaHideOutside.ts:50-297`,
`usePreventScroll.ts:40-231`, `useModalOverlay.ts`, plus the older
`useModal.tsx` counting scheme, still exported.

**Degradation.** Where there is no scroll to prevent and no parallel semantic
tree to hide, switches (1) and (3) have nothing to act on and only (2) remains:
modality reduces to a predicate on the hit list ("stop reverse-order hit testing
at the modal overlay; optionally paint a dim fill beneath it") plus a
key-routing predicate. The ref-counting discipline in `ariaHideOutside` is still
worth borrowing in shape for nested modals — a depth counter deciding where hit
testing stops — and `keepVisible` maps onto "this overlay is exempt from the
topmost modal's barrier", which is what a toast needs. Because such a barrier is
a hit-list predicate rather than a platform state, it is directly assertable,
unlike React Aria's modality, which is observable only through DOM attributes.

### 12. Adaptive presentation

**The decision does not live in `react-aria`.** The behavior hooks contain no
device or viewport branching for presentation. The switch lives in the design
system: `useIsMobileDevice.ts:15` is a constant, `MOBILE_SCREEN_WIDTH = 700`,
compared against `window.screen.width` — not a media query and not a
pointer-capability query — and `ComboBox.tsx:158` branches on it to return a
_different component tree_ (`MobileComboBox`), not a variant of the same overlay.
`SubmenuTrigger`, `MenuTrigger`, `ContextualHelpTrigger`, `Picker`,
`SearchAutocomplete` and `DialogTrigger` follow the same pattern. In the S2
system the tray strategy is currently commented out
(`@react-spectrum/s2/src/Popover.tsx:77`):

> ```
> // mobileType?: 'modal' | 'fullscreen' | 'fullscreenTakeover' // TODO: add tray back in
> ```

The _hover → touch_ adaptation is likewise a component decision, but part of it
leaks into the hooks: `usePreviewTrigger.ts:196` enables long press only when
`'ontouchstart' in window` and the modality is compatible, and only then attaches
the localized "long press" accessibility description (`:206`) — so a keyboard
user is never told to long press. `useContextMenu.ts:81` branches on iOS to
substitute a long press for the missing `contextmenu` event.

**Algorithm.**

```text
isMobile := window.screen.width <= 700            # evaluated once; SSR fallback false
component chooses a different subtree
shouldLongPress := (modality ∈ {pointer, virtual, null}) ∧ ('ontouchstart' in window)
```

**Where the behavior lives.** The design-system layer, not the behavior layer.
Only the touch-substitution half appears in `usePreviewTrigger.ts:195-213` and
`useContextMenu.ts:81`.

**Degradation.** The architectural boundary — the primitive stays
presentation-agnostic and the component chooses sheet versus popover — is the
transferable part. The probe is not: `window.screen.width <= 700` ignores
rotation, split screen and desktop touch, is evaluated once with no subscription,
and reads the screen rather than the window. A capability record the backend can
answer honestly (has hover, pointer count, surface size) is the substitute. With
no hover the primitive needs long press as a _first-class trigger_ rather than an
adaptation, and the soft-keyboard inset needs to be a placement input rather than
something discovered from a viewport event. With no script, no adaptation is
possible at all, so the emitted form has to be the no-hover form.

### 13. Accessibility

Role assignment is per-component; the primitive supplies only the wiring.

`useTooltip` returns `role: 'tooltip'` plus filtered labelable props.
`useTooltipTrigger` returns `aria-describedby` (`:149`) — a description, never a
label — and, notably, `tabIndex: undefined` (`:155`), explicitly refusing to make
the trigger focusable.

`useOverlayTrigger` emits `aria-haspopup` only for `type === 'menu'` (as `true`)
and `'listbox'` (`useOverlayTrigger.ts:53-61`), with a source comment noting that
ARIA 1.1's other values are mis-announced by screen readers, plus `aria-expanded`
and `aria-controls`.

RAC `Popover` promotes itself to `role='dialog'` with `tabIndex={-1}`
(`Popover.tsx:340-341`) when it is acting as a dialog, decided in a layout effect
after querying its own subtree (`:276-296`). Context-menu triggers strip
`aria-haspopup` / `aria-expanded` / `aria-controls` entirely
(`useMenuTrigger.ts:185-191`), because `aria-haspopup` promises that _activating_
the element opens a menu, which is false for a right-click target.

`DismissButton` is a visually hidden, `tabIndex={-1}`, 1×1 px button with a
localized label (`DismissButton.tsx:43-45`), rendered both **before and after**
the popover content (`Popover.tsx:353`, `:357`) — the only way iOS VoiceOver's
swipe navigation can reach a dismiss action from either direction.

Against WCAG 1.4.13: dismissible is satisfied (document-capture Escape),
persistent is satisfied (the 500 ms `closeDelay` plus `useHover` on the tooltip
element), and hoverable is satisfied for the tooltip's own content — but there is
no pointer bridge across the gap, so with a large `offset` the close delay is
doing all the work.

Whether tooltip content may be interactive: the answer is no, and the response is
a _separate component_. `usePreviewTrigger.ts:245` puts `aria-haspopup: 'dialog'`
on the trigger (the hook itself sets no `role`; the `role='dialog'` comes from
RAC `Popover`), with Tab-into-popover handling and long-press-then-focus for
touch screen readers.

Screen-reader timing is first class: `getInteractionModality() === 'virtual'` is
a real state, and a focus event with no preceding input event is classified as
virtual.

**Algorithm.**

```text
trigger      : aria-describedby := isOpen ? tooltipId : undefined
haspopup     := type == 'menu' ? true : type == 'listbox' ? 'listbox' : undefined
popover role := actingAsDialog ∧ ¬subtreeAlreadyHasDialog ? 'dialog' : none
dismiss      := two 1×1 visually-hidden buttons bracketing the content
```

**Where the behavior lives.** `useTooltip.ts`, `useTooltipTrigger.ts:143-156`,
`useOverlayTrigger.ts:53-73`, `DismissButton.tsx`, `Popover.tsx:276-341`,
`useMenuTrigger.ts:182-191`.

**Degradation.** This dimension does not apply in the same form where there is no
accessibility tree, and the absence is itself the finding: everything
`ariaHideOutside`, `DismissButton` and the role machinery exist to do becomes
unnecessary, which removes several hundred lines of the subject's most bug-prone
code. What survives is the _distinction the roles encode_: description versus
label (a tooltip annotates, it never names), and "tooltip content is never
interactive — interactive content is a different primitive". Those belong as a
type-level split between widget kinds rather than a runtime role string. A
terminal has no assistive-technology surface at all, so the honest analogue is
that a tooltip's text must also be reachable another way. Static HTML is the one
target where the roles _do_ apply and can be emitted with no runtime cost:
`role="tooltip"` and `aria-describedby` are free at emit time.

> [!IMPORTANT]
> `aria-describedby` on the trigger, never `aria-labelledby`: the tooltip
> annotates the control, it does not name it. `useTooltipTrigger` also returns
> `tabIndex: undefined` rather than `0` — the trigger must already be focusable
> for its own reasons.

### 14. Animation

Geometry metadata is emitted _specifically_ to enable animation, and
`triggerAnchorPoint` (`calculatePosition.ts:627-630`) is the one field of
`PositionResult` that exists for no other reason. It is the anchor's origin
expressed in the **overlay's** local coordinate system: on the cross axis it is
the arrow's clamped position when there is an arrow (so a scale animation grows
out of the arrow tip, `:615`), otherwise the anchor edge or centre per the cross
alignment; on the main axis it is `overlaySize[size]` for `left`/`top`
placements (the overlay's far edge, i.e. the side facing the anchor) and `0`
otherwise.

Both RAC `Popover` (`:327`) and `Tooltip` (`:236`) publish it as the CSS custom
property `--trigger-anchor-point`, ready for `transform-origin`. `Popover` also
publishes `--trigger-width` (`:331`), kept live by a `ResizeObserver`, so a
listbox can match its trigger, plus `data-placement` / `data-entering` /
`data-exiting`.

Enter and exit run on the Web Animations API rather than timers
(`utils/animation.ts:17`, `:48`, reading `element.getAnimations()`), and the entry
animation is **gated on the position having been computed**:
`useEnterAnimation(props.tooltipRef, !!placement)` (`Tooltip.tsx:210`). The hook
also cancels any transition that started before geometry was known
(`animation.ts:29-38`). `shouldSkipAnimation` from the timing machine is threaded
all the way through (`Tooltip.tsx:176`, `:211`; `Popover.tsx:174`, `:253`), so a
warm swap animates neither out nor in.

Reposition during animation: focus containment is disabled while the overlay is
exiting so focus can leave a dying surface; position keeps updating.

Reduced motion is **absent from the overlay path** — it is handled by the design
system's CSS media queries, not by these hooks. Arrow animation: none; the arrow
simply moves with `left`/`top`.

**Algorithm.**

```text
origin     := arrowSize ? arrowPos[crossAxis]
                        : (crossPlacement == 'right'  ? origin + childCross
                        :  crossPlacement == 'center' ? origin + childCross / 2
                        :  origin)
crossOrigin := (placement ∈ {left, top}) ? overlay[mainSize] : 0
anchorPoint := { x: placement ∈ {top, bottom} ? origin : crossOrigin,
                 y: placement ∈ {left, right} ? origin : crossOrigin }
```

**Where the behavior lives.** `calculatePosition.ts:615-639` (metadata),
`utils/animation.ts` (enter/exit), `Popover.tsx` and `Tooltip.tsx`
(publication as CSS variables).

**Degradation.** `triggerAnchorPoint` is two numbers derived from arithmetic the
engine has already done, so it is free to compute and free to emit; a GPU backend
can use it as a scale origin and a cell backend can use it to choose the
direction of a two- or three-frame reveal. The gating rule generalises beyond
CSS: never animate before geometry exists, or the surface flies in from the
origin — in an immediate-mode toolkit the equivalent is "the first frame after
open paints at rest, animation starts on frame 2". `shouldSkipAnimation` as a
third channel next to open/close is the piece most implementations omit and
belongs in the returned state. With no timers, only a CSS transition delay is
expressible and the anchor point cannot be computed at emit time. Because
entering/exiting are observable here only through the Web Animations API,
animation behavior is not assertable as data — a port that keeps the flags in
state is strictly better off.

### 15. State architecture

Ad-hoc controllers over React hooks: no reducers, no statechart, no event bus.

`useOverlayTriggerState` is the base —
`{isOpen, setOpen, open, close, toggle, point, setPoint}` built on
`useControlledState`, so every overlay is controlled-or-uncontrolled by the same
mechanism (the presence of `props.isOpen` decides). Everything else _extends the
returned object_: `useTooltipTriggerState` wraps `open`/`close` with the timing
machine and adds `shouldSkipAnimation`; `useMenuTriggerState` adds
`focusStrategy` and `expandedKeysStack`.

The state objects are recreated every render — object literals over closures —
so their identity is unstable, which is why every consumer takes `state` as a
parameter instead of storing it.

The genuinely value-shaped parts are `point: {x, y} | null`,
`expandedKeysStack: Key[]`, `focusStrategy`, `placement`, and the whole
`PositionResult`. The genuinely non-value parts are three module-level mutable
globals (tooltip warmth, `visibleOverlays`, `activeScope`), several `WeakMap`s
(the aria-hide ref counts, `onCloseMap`), and a pile of `useRef` latches.

Notably, **timing state is entirely outside React**: `globalWarmedUp` and the
timeout handles are plain module variables, deliberately not state, because they
must be shared across component instances that know nothing about each other.

**Algorithm.**

```text
controlled/uncontrolled: value := props.value !== undefined ? props.value : internal
                         setter always calls onChange, writes internal only when uncontrolled
state extension by spread: {...base, open(strategy) { setStrategy(strategy); base.open() }}
```

**Where the behavior lives.** `react-stately/src/overlays/useOverlayTriggerState.ts`,
`react-stately/src/tooltip/useTooltipTriggerState.ts`,
`react-stately/src/menu/useMenuTriggerState.ts`, `utils/useControlledState.ts`.

**Degradation.** The _logic_ would survive a non-DOM, value-semantics port; the
_packaging_ would not. The logic is small enough to be plain data — an open flag
plus an optional anchor point, a timing record of deadlines and a warmed-up flag,
and a `Key[]` submenu chain. The three module globals would become one owner
value held by the application shell, so "timing is global" becomes "the manager
owns warmth, widgets ask it" — which is also more testable, since a mutable
global cannot be isolated between parallel tests (the state test file drains it
in an `afterEach` and says why). Closures over `setState` do not survive and
would become explicit calls against the manager. The controlled/uncontrolled
duality needs no machinery: it is "the view takes state by reference; the caller
may own it". Injecting the clock is what makes every timing behavior assertable.

### 16. Shared infrastructure

The factoring is explicit enough to read as a taxonomy.

**Shared.** One positioner (`useOverlayPosition`, used by tooltip, popover, and —
through popover — menu, select, combobox, date picker, colour picker, submenu,
subdialog and preview). One dismissal stack (`useOverlay`). One
assistive-technology modality (`ariaHideOutside`). One scroll lock
(`usePreventScroll`). One open/close state (`useOverlayTriggerState`). One
timing machine (`useTooltipTriggerState`), reused verbatim by `PreviewTrigger`
with different constants — which is the strongest in-tree evidence that
warm-up/cool-down belongs to "hover-opened surface" rather than to "tooltip".

**Deliberately apart.**

- `usePopover` composes position + overlay + scroll lock + aria-hide
  (`usePopover.ts:100-132`), while `useTooltipTrigger` composes _none_ of that
  and only the component calls `useOverlayPosition`. A tooltip is not a light
  popover; it is a different composition.
- The two travel algorithms of dimension 7 were never unified.
- Submenus get `isNonModal: true` plus a `groupRef`, their own 200 ms timer, and
  `shouldCloseOnInteractOutside: target => target !== trigger`
  (`useSubmenuTrigger.ts:304`) — none of which a plain popover has.
- Toast opts out of the entire overlay system via the top-layer marker.
- Adaptive presentation lives in the design system.
- Context-menu ARIA is stripped rather than shared.

`mergeProps` is the universal glue: it chains event handlers and merges
`className`/`id`, which is what lets `useHover`, `useFocusable` and `useLongPress`
coexist on one element.

**Algorithm.**

```text
composition by prop merge, not inheritance:
    usePopover        = useOverlay ⊕ useOverlayPosition ⊕ usePreventScroll ⊕ ariaHideOutside ⊕ useFocusWithin
    useTooltipTrigger = useHover ⊕ useFocusable ⊕ document-capture Escape
    shared kernel     = { geometry, dismissal stack, open state }
```

**Where the behavior lives.** `usePopover.ts:87-151` (the composition),
`utils/mergeProps.ts` (the glue).

**Degradation.** Reading the split as a recommendation: a single anchored-overlay
primitive would own the anchor rect (point as a small rect), the placement value
and the flip/cross-shift/clamp arithmetic, the arrow constraint pair plus the
emitted arrow cell and `triggerAnchorPoint`, the open state with
`shouldSkipAnimation` as a third channel, the overlay stack with "only topmost
dismisses" and the two-phase outside test, and the boundary and padding inputs.
What the subject's own factoring argues should stay outside it: the warm-up
machine (hover-opened surfaces only — a click-opened menu must open instantly),
the safe-area travel test (interactive content or a non-zero gap only), focus
containment and initial focus (menu and dialog only), the modality barrier
(dialog and menu only), and the sheet-versus-popover decision (application
layer). The tempting-but-refused design is "one overlay with flags":
`useTooltipTrigger` does not call `useOverlay` at all, and that refusal is the
most reusable judgement in the subject.

---

## Strengths

- The positioning core is already a pure function of plain records
  (`calculatePositionInternal`, 18 arguments, no DOM), with the measurement shell
  cleanly separated behind it.
- The warm-up / cool-down / instant-swap machine is precise on the edge cases
  that are easy to miss: abandoning a hover mid-warm-up leaves the system cold;
  the cool-down floor is independent of the caller's `delay`; `shouldSkipAnimation`
  is a third channel so a warm swap animates neither out nor in.
- Arrow geometry is bidirectional data — `arrowSize` and `arrowBoundaryOffset`
  constrain the popup's placement, and the design system feeds the measured
  `border-radius` in, so corner avoidance is configuration rather than knowledge
  baked into the engine.
- `triggerAnchorPoint` is computed from arithmetic already performed and
  published specifically to make placement-aware scale animations possible.
- Two-phase outside dismissal (pointerdown latches, click confirms, plus a
  topmost-at-pointerdown guard) fails closed under exactly the conditions a
  toolkit without a pointer grab faces.
- `ariaHideOutside` is ref-counted, stack-ordered, respects author-set
  `aria-hidden`, survives out-of-order reverts, re-walks mutations, and encodes a
  specific iOS VoiceOver `role=row` bug in its tree filter.
- Trigger races are resolved by a global modality oracle plus boolean latches
  rather than by event ordering — `isHovered = (modality === 'pointer')` fixes
  the obscured-element hover race in one line.
- The submenu chain is `Key[]` indexed by depth, so opening and closing levels
  are array slices over a comparable value.
- Tooltip and popover are kept apart at the hook level, and the answer to
  "interactive tooltip" was a new component rather than a flag.
- `useSafeArea`'s convex-hull bridge is placement-agnostic, diagonal-safe, and
  needs nothing but two rects and a point.

## Weaknesses

- No auto-placement and no fallback list: exactly one alternative (the 180° flip)
  is ever considered, and the cross alignment never flips, so a corner placement
  cannot rotate to an adjacent side.
- No `maxWidth` — `PositionResult` constrains height only, so a left/right-placed
  overlay wider than its boundary overflows with nothing to stop it.
- No re-anchoring: anchor movement without a resize is undetectable, and there is
  no anchor-hidden or anchor-removed handling anywhere in the overlay code.
- Arrow detachment is silent: when the two clamps conflict, the arrow stays on
  the overlay and stops pointing at the anchor, with no flag and no hide behavior
  exposed.
- Tooltip timing is document-global mutable state, unscopable and not isolable
  between parallel tests; the state test file drains it in an `afterEach`.
- Two unreconciled hover-travel algorithms — an eight-point convex hull for
  previews and a ±15° `atan2` cone with hysteresis for submenus — solving the
  same problem with different failure modes.
- `calculatePositionInternal` is exported but has no call site other than its own
  DOM shell, so the pure core is not tested as a pure function; the placement
  tests mock `getBoundingClientRect`.
- The cross-axis clamp can invert (`minPosition > maxPosition`) when
  `2 * (arrowSize + arrowBoundaryOffset)` exceeds the anchor's plus the overlay's
  cross extent, and `clamp` then silently returns `max` with no diagnostic.
- `usePreventScroll`'s iOS branch patches `HTMLElement.prototype.focus` globally
  and injects a style element — an invasive workaround shipped from a
  positioning-adjacent hook.
- Adaptive presentation keys off `window.screen.width <= 700`, evaluated once,
  ignoring rotation, split screen and desktop touch, while the S2 tray path is
  commented out with a TODO.
- Reduced motion is absent from the overlay path, and enter/exit state is
  observable only through the Web Animations API.
- No safe-area (notch) inset support; the virtual-keyboard answer is to discover
  the inset from `visualViewport` and re-run, behind a 500 ms heuristic window.

## Key design decisions and trade-offs

| Decision                                                                                                                                                                              | Rationale                                                                                                                                                                                                                                                                                                              | Trade-off                                                                                                                                                                                                                                                                                                                              |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Hand-write a ~850-line placement engine with exactly one flip candidate, one cross-axis shift, and no main-axis shift.                                                                | Every case the Spectrum components need is a side plus an alignment with at most a 180° fallback; a middleware pipeline with fallback lists would add configuration surface the design system never uses. Main-axis overflow is answered by shrinking, because a scrollable menu beats a menu shifted off its trigger. | A corner placement can only flip to the opposite corner, never rotate to an adjacent side, so a `bottom` popup in a short-but-wide gap becomes a very short scrolling popup instead of moving to `right`. Width is never constrained at all.                                                                                           |
| Refuse to re-anchor: no rAF loop, no `IntersectionObserver`; scrolling either is locked (modal) or closes the overlay (non-modal).                                                    | Continuous tracking costs a layout read per frame and still lags on transformed or scrolled ancestors. Closing is semantically honest: if the anchor scrolled away, the popup's referent is gone.                                                                                                                      | Anchor movement _without_ a resize — a sibling appearing above it, an animated layout — is invisible to the engine and strands the overlay. And `useCloseOnScroll` firing on any ancestor scroll makes overlays feel fragile inside scrollable panes, which is why modals must lock scrolling and drag in the whole iOS WebKit branch. |
| Make tooltip timing a document-global singleton (module-level `globalWarmedUp` plus a registry of hide functions) rather than provider-scoped or per-widget.                          | The behavior users want — first tooltip slow, neighbours instant — is a property of the _pointer's_ recent history, not of any component subtree. A provider would force app authors to place it correctly and would break across portals.                                                                             | Not isolable between parallel tests and it leaks between them; the suite drains it in an `afterEach`. Two independent widget trees share warmth whether or not that is wanted, and there is no way to scope or disable it.                                                                                                             |
| Let the arrow's requirements constrain the popup: clamp the cross position so at least `arrowSize + arrowBoundaryOffset` of the overlay overlaps the anchor.                          | An arrow that has detached from its anchor is worse than a slightly misaligned popup; guaranteeing overlap means the arrow can always be drawn pointing at something real.                                                                                                                                             | The clamp interval can invert for a small anchor and a large arrow allowance, and `clamp` silently returns `max`. And when the boundary shift later pushes the overlay past the anchor anyway, the arrow's second clamp wins and it detaches with no signal to the caller.                                                             |
| Refuse to unify tooltip and popover: `useTooltipTrigger` never calls `useOverlay`, and interactive hover content became a new component rather than an `isInteractive` flag.          | A tooltip must never take focus, never contain interactive content, must be described-by rather than controlled-by, and must be dismissible from anywhere. A popover is the opposite on each axis. Sharing an implementation would produce a flag matrix where most combinations are accessibility bugs.               | Real duplication: two hover-travel algorithms solving the same problem, two Escape mechanisms (bubbling shortcut versus document capture), two dismissal styles. A reader must know which family a component belongs to before any behavior is predictable.                                                                            |
| Emit geometry metadata (`triggerAnchorPoint`, `--trigger-width`, `data-placement`) purely so the styling layer can animate, and gate the entry animation on placement being computed. | The engine is the only thing that knows where the anchor sits in the overlay's local coordinates; CSS cannot recompute it. Gating on `!!placement` prevents the "popup flies in from the corner" bug, because the overlay renders at the origin before its first measurement.                                          | Ties the animation contract to CSS custom properties and the Web Animations API, so enter/exit state is not observable as data — it cannot be asserted without a real browser — and reduced motion is punted to the design system's media queries.                                                                                     |
| Put adaptive presentation (popover → tray/fullscreen, hover → long press) in the design-system layer using a `window.screen.width <= 700` probe.                                      | The behavior layer should not hold opinions about form factor; a tray is a different component with different focus and dismissal semantics, not a styled popover.                                                                                                                                                     | The probe ignores rotation, split screen, desktop touch, and window versus screen size; it is evaluated once with no subscription; and the S2 tray path is currently commented out — so the adaptation story is crude and in flux even though the architectural boundary is right.                                                     |

---

## Sources

Primary sources, all read at `7c0765468a1d161ab9ac88ca9f1b54d3603a275c`:

- [`packages/react-aria/src/overlays/calculatePosition.ts`][calc] — the placement
  engine: `parsePlacement`, [`computePosition`][calc-compute],
  [`getDelta`][calc-delta], [`getAvailableSpace`][calc-space],
  [`getMaxHeight`][calc-maxheight], [`calculatePositionInternal`][calc-internal],
  the [flip decision][calc-flip], the [arrow-overlap clamp][calc-clamp], the
  [arrow position][calc-arrow], [`triggerAnchorPoint`][calc-anchor],
  the [DOM shell][calc-shell], [`getRect`][calc-getrect],
  [`getContainingBlock`][calc-cb].
- [`packages/react-aria/src/overlays/useOverlayPosition.ts`][uop] — the
  [`Placement` vocabulary][uop-placement], [`getTargetRect`][uop-target],
  [`translateRTL`][uop-rtl], the [scale freeze][uop-scale], the
  [previous-output reset][uop-reset], [scroll-anchor restoration][uop-scroll],
  the [`isResizing` window][uop-resizing], the [hard-coded `zIndex`][uop-zindex].
- [`packages/react-aria/src/overlays/useOverlay.ts`][use-overlay] — the
  [overlay stack][overlay-stack], [`onHide`][overlay-onhide],
  [`onInteractOutsideStart`][overlay-start], the [blur guard][overlay-blur].
- [`packages/react-aria/src/interactions/useInteractOutside.ts`][interact] — the
  [pointerdown latch][interact-down], the [click confirmation][interact-click],
  [`isValidEvent`][interact-valid], the [top-layer marker][interact-marker].
- [`packages/react-aria/src/overlays/useCloseOnScroll.ts`][scroll] and
  [`packages/react-aria/src/overlays/usePreventScroll.ts`][prevent-scroll].
- [`packages/react-aria/src/overlays/ariaHideOutside.ts`][hide] — the
  [observer stack][hide-stack], [`setHidden`][hide-set], the
  [`role=row` filter exception][hide-row], the [ref count][hide-count],
  [`keepVisible`][hide-keep].
- [`packages/react-aria/src/overlays/usePopover.ts`][use-popover] — the
  [composition][popover-compose], the [group ref][popover-group], the
  [point-to-rect conversion][popover-point], the
  [non-modal warning][popover-nonmodal].
- [`packages/react-stately/src/tooltip/useTooltipTriggerState.ts`][tt-state] —
  the [module globals][tt-globals], [`closeOpenTooltips`][tt-close-others],
  [`showTooltip`][tt-show], [`hideTooltip`][tt-hide], the
  [warm-only cool-down][tt-cool], [`warmupTooltip`][tt-warmup], the
  [public `open`][tt-open].
- [`packages/react-aria/src/tooltip/useTooltipTrigger.ts`][tt-trigger],
  [`useTooltip.ts`][use-tooltip], [`useSafeArea.ts`][safe-area],
  [`usePreviewTrigger.ts`][preview].
- [`packages/react-aria/src/menu/useSafelyMouseToSubmenu.ts`][safely-mouse],
  [`useMenuTrigger.ts`][menu-trigger], [`useSubmenuTrigger.ts`][submenu].
- [`packages/react-aria/src/interactions/useFocusVisible.ts`][focus-visible],
  [`useHover.ts`][use-hover], [`useContextMenu.ts`][context-menu].
- [`packages/react-aria/src/focus/FocusScope.tsx`][focus-scope] — the
  [active scope][fs-active], [`nodeToRestore` captured at render][fs-noderestore],
  the [cloned-tree deferred restore][fs-clone], the
  [cancelable restore event][fs-event].
- [`packages/react-aria/src/overlays/Overlay.tsx`][overlay-tsx],
  [`useOverlayTrigger.ts`][use-overlay-trigger],
  [`useModalOverlay.ts`][use-modal], [`DismissButton.tsx`][dismiss-button],
  [`utils/animation.ts`][animation], [`utils/mergeProps.ts`][merge-props].
- [`packages/react-stately/src/overlays/useOverlayTriggerState.ts`][ots] and
  [`packages/react-stately/src/menu/useMenuTriggerState.ts`][mts]
  ([`expandedKeysStack`][mts-stack]).
- [`packages/react-aria-components/src/Popover.tsx`][rac-popover]
  ([group context][rac-group], [`--trigger-anchor-point`][rac-anchor-var],
  [`role='dialog'`][rac-dialog], [the underlay][rac-underlay],
  [the bracketing dismiss buttons][rac-dismiss]),
  [`Tooltip.tsx`][rac-tooltip] ([the entry gate][rac-gate]),
  [`PreviewTrigger.tsx`][rac-preview], [`OverlayArrow.tsx`][rac-arrow].
- [`packages/@react-spectrum/s2/src/Tooltip.tsx`][s2-tooltip]
  ([`arrowBoundaryOffset={borderRadius}`][s2-abo]) and
  [`Popover.tsx`][s2-popover] ([the `mobileType` TODO][s2-mobile]).
- [`packages/@adobe/react-spectrum/src/utils/useIsMobileDevice.ts`][is-mobile]
  and [`combobox/ComboBox.tsx`][combobox].
- Tests read as authored intent, not as observed passes:
  [`TooltipTrigger.test.js`][tooltip-test] (warm-up abandonment),
  [`useTooltipTriggerState.test.js`][tt-state-test] (the global-state drain),
  [`ariaHideOutside.test.js`][hide-test] (out-of-order revert),
  [`calculatePosition.test.ts`][calc-test] (mocked rects).

Catalog cross-references: [index][index] · [concepts][concepts] ·
[comparison][comparison] · [features people forget][forget] ·
[sparkles baseline][baseline] · [proposal][proposal]. Nearest neighbours in this
catalog: [Floating UI][floating-ui] (the middleware engine this one declines to
use), [Radix][radix], [Base UI][base-ui], [Ariakit][ariakit],
[Headless UI][headlessui], [Zag][zag], [Angular CDK][angular-cdk],
[Tippy][tippy], [Floating Vue][floating-vue], and the platform baselines
[Popover API][popover-api], [CSS anchor positioning][css-anchor],
[Blink][blink] and [the ARIA APG][aria-apg]. Adjacent research trees:
[window-system integration][wsi], [platform UI guidelines][pug],
[UI layout][ui-layout], [Sean Parent][sean-parent]. Toolkit specs:
[ui][spec-ui], [input][spec-input], [containers][spec-containers],
[state machines][spec-state], [backends][spec-backends], [widgets][spec-widgets].

<!-- References -->

[calc]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/overlays/calculatePosition.ts
[calc-compute]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/overlays/calculatePosition.ts#L265
[calc-delta]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/overlays/calculatePosition.ts#L180
[calc-space]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/overlays/calculatePosition.ts#L379
[calc-maxheight]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/overlays/calculatePosition.ts#L321
[calc-internal]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/overlays/calculatePosition.ts#L417
[calc-flip]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/overlays/calculatePosition.ts#L465
[calc-clamp]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/overlays/calculatePosition.ts#L298
[calc-arrow]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/overlays/calculatePosition.ts#L573
[calc-anchor]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/overlays/calculatePosition.ts#L627
[calc-shell]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/overlays/calculatePosition.ts#L646
[calc-getrect]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/overlays/calculatePosition.ts#L749
[calc-cb]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/overlays/calculatePosition.ts#L805
[uop]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/overlays/useOverlayPosition.ts
[uop-placement]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/overlays/useOverlayPosition.ts#L22
[uop-target]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/overlays/useOverlayPosition.ts#L151
[uop-rtl]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/overlays/useOverlayPosition.ts#L425
[uop-scale]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/overlays/useOverlayPosition.ts#L245
[uop-reset]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/overlays/useOverlayPosition.ts#L269
[uop-scroll]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/overlays/useOverlayPosition.ts#L316
[uop-resizing]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/overlays/useOverlayPosition.ts#L347
[uop-zindex]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/overlays/useOverlayPosition.ts#L397
[use-overlay]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/overlays/useOverlay.ts
[overlay-stack]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/overlays/useOverlay.ts#L61
[overlay-onhide]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/overlays/useOverlay.ts#L94
[overlay-start]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/overlays/useOverlay.ts#L100
[overlay-blur]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/overlays/useOverlay.ts#L160
[interact]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/interactions/useInteractOutside.ts
[interact-down]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/interactions/useInteractOutside.ts#L44
[interact-click]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/interactions/useInteractOutside.ts#L70
[interact-valid]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/interactions/useInteractOutside.ts#L120
[interact-marker]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/interactions/useInteractOutside.ts#L132
[scroll]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/overlays/useCloseOnScroll.ts
[prevent-scroll]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/overlays/usePreventScroll.ts
[hide]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/overlays/ariaHideOutside.ts
[hide-stack]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/overlays/ariaHideOutside.ts#L39
[hide-set]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/overlays/ariaHideOutside.ts#L64
[hide-row]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/overlays/ariaHideOutside.ts#L108
[hide-count]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/overlays/ariaHideOutside.ts#L147
[hide-keep]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/overlays/ariaHideOutside.ts#L299
[use-popover]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/overlays/usePopover.ts
[popover-compose]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/overlays/usePopover.ts#L100
[popover-group]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/overlays/usePopover.ts#L109
[popover-point]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/overlays/usePopover.ts#L125
[popover-nonmodal]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/overlays/usePopover.ts#L44
[tt-state]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-stately/src/tooltip/useTooltipTriggerState.ts
[tt-globals]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-stately/src/tooltip/useTooltipTriggerState.ts#L74
[tt-close-others]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-stately/src/tooltip/useTooltipTriggerState.ts#L99
[tt-show]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-stately/src/tooltip/useTooltipTriggerState.ts#L110
[tt-hide]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-stately/src/tooltip/useTooltipTriggerState.ts#L130
[tt-cool]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-stately/src/tooltip/useTooltipTriggerState.ts#L149
[tt-warmup]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-stately/src/tooltip/useTooltipTriggerState.ts#L164
[tt-open]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-stately/src/tooltip/useTooltipTriggerState.ts#L203
[tt-trigger]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/tooltip/useTooltipTrigger.ts
[use-tooltip]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/tooltip/useTooltip.ts
[safe-area]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/tooltip/useSafeArea.ts
[preview]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/tooltip/usePreviewTrigger.ts
[safely-mouse]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/menu/useSafelyMouseToSubmenu.ts
[menu-trigger]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/menu/useMenuTrigger.ts
[submenu]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/menu/useSubmenuTrigger.ts
[focus-visible]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/interactions/useFocusVisible.ts
[use-hover]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/interactions/useHover.ts
[context-menu]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/interactions/useContextMenu.ts
[focus-scope]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/focus/FocusScope.tsx
[fs-active]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/focus/FocusScope.tsx#L76
[fs-noderestore]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/focus/FocusScope.tsx#L633
[fs-clone]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/focus/FocusScope.tsx#L787
[fs-event]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/focus/FocusScope.tsx#L830
[overlay-tsx]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/overlays/Overlay.tsx
[use-overlay-trigger]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/overlays/useOverlayTrigger.ts
[use-modal]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/overlays/useModalOverlay.ts
[dismiss-button]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/overlays/DismissButton.tsx
[animation]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/utils/animation.ts
[merge-props]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/utils/mergeProps.ts
[ots]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-stately/src/overlays/useOverlayTriggerState.ts
[mts]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-stately/src/menu/useMenuTriggerState.ts
[mts-stack]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-stately/src/menu/useMenuTriggerState.ts#L54
[rac-popover]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria-components/src/Popover.tsx
[rac-group]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria-components/src/Popover.tsx#L157
[rac-anchor-var]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria-components/src/Popover.tsx#L327
[rac-dialog]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria-components/src/Popover.tsx#L340
[rac-underlay]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria-components/src/Popover.tsx#L373
[rac-dismiss]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria-components/src/Popover.tsx#L353
[rac-tooltip]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria-components/src/Tooltip.tsx
[rac-gate]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria-components/src/Tooltip.tsx#L210
[rac-preview]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria-components/src/PreviewTrigger.tsx#L47
[rac-arrow]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria-components/src/OverlayArrow.tsx
[s2-tooltip]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/%40react-spectrum/s2/src/Tooltip.tsx
[s2-abo]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/%40react-spectrum/s2/src/Tooltip.tsx#L206
[s2-popover]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/%40react-spectrum/s2/src/Popover.tsx
[s2-mobile]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/%40react-spectrum/s2/src/Popover.tsx#L77
[is-mobile]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/%40adobe/react-spectrum/src/utils/useIsMobileDevice.ts#L15
[combobox]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/%40adobe/react-spectrum/src/combobox/ComboBox.tsx#L158
[tooltip-test]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/%40adobe/react-spectrum/test/tooltip/TooltipTrigger.test.js#L710
[tt-state-test]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-stately/test/tooltip/useTooltipTriggerState.test.js#L84
[hide-test]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/test/overlays/ariaHideOutside.test.js#L424
[calc-test]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/test/overlays/calculatePosition.test.ts
[index]: ./index.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[forget]: ./features-people-forget.md
[baseline]: ./sparkles-baseline.md
[proposal]: ./proposal.md
[floating-ui]: ./floating-ui.md
[radix]: ./radix.md
[base-ui]: ./base-ui.md
[ariakit]: ./ariakit.md
[headlessui]: ./headlessui.md
[zag]: ./zag.md
[angular-cdk]: ./angular-cdk.md
[tippy]: ./tippy.md
[floating-vue]: ./floating-vue.md
[popover-api]: ./popover-api.md
[css-anchor]: ./css-anchor.md
[blink]: ./blink.md
[aria-apg]: ./aria-apg.md
[wsi]: ../window-system-integration/index.md
[pug]: ../platform-ui-guidelines/index.md
[ui-layout]: ../ui-layout/index.md
[sean-parent]: ../sean-parent/index.md
[spec-ui]: ../../specs/ui/index.md
[spec-input]: ../../specs/ui/input.md
[spec-containers]: ../../specs/ui/containers.md
[spec-state]: ../../specs/ui/state-machines.md
[spec-backends]: ../../specs/ui/backends.md
[spec-widgets]: ../../specs/ui/widgets.md
