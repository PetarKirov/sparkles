# Angular CDK Overlay (TypeScript / Angular)

An overlay _manager_ that owns exactly four things — where a floating box goes, what happens when the page moves under it, where it lives in the render tree, and how document-level keys and pointers reach a _stack_ of open surfaces — and deliberately owns nothing else.

| Field             | Value                                                                                                                                                                                                                                                                        |
| ----------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language          | TypeScript (+ SCSS)                                                                                                                                                                                                                                                          |
| License           | MIT (Copyright 2026 Google LLC)                                                                                                                                                                                                                                              |
| Repository        | [`angular/components`][repo]                                                                                                                                                                                                                                                 |
| Documentation     | [`src/cdk/overlay/overlay.md`][overlay-md] (in-tree guide)                                                                                                                                                                                                                   |
| Category          | Web / enterprise overlay manager                                                                                                                                                                                                                                             |
| Surface model     | both — the legacy path paints into ONE in-page container `div` (`.cdk-overlay-container`, `z-index: 1000`); as of v22 the default is the browser [top layer][concepts] via `popover="manual"` + `showPopover()`, chosen by the feature test `'showPopover' in document.body` |
| **Revision read** | [`f3e6276c969f33e527b616ef8bf7b0404685721d`][repo-sha] (package version `22.2.0-next.0`)                                                                                                                                                                                     |

Source-derived, not docs-derived: every claim below is read from the package
sources and specs at that revision. Where a statement is an inference from
control flow rather than an observed or test-pinned behaviour, it says so
explicitly.

> [!IMPORTANT]
> No spec was executed for this reading (no Bazel/Karma run). Behavioural claims
> come from reading implementation source and test source, not from observing
> execution. Where a test is cited, it is cited as evidence that the behaviour is
> _pinned_, not that it was seen to pass here.

## Overview

### What it solves

`@angular/cdk/overlay` is not a tooltip, a menu or a popover component. It is the
substrate four such component families in the same repository sit on
(`cdk/menu`, `cdk/dialog`, `cdk/listbox`, `material/*`), and its scope is
unusually narrow for a package of its age:

1. **Where the floating box goes** — a swappable `PositionStrategy` object.
2. **What happens when the page scrolls or resizes under it** — a swappable
   `ScrollStrategy` _value_ stored in the config.
3. **Where the box lives in the render tree** — an injectable `OverlayContainer`
   service; since v22, by default, the browser's top layer.
4. **How document-level keyboard and pointer events reach a stack of open
   overlays** — two singleton dispatchers with one capture-phase listener each.

Triggers, delays, hover intent, focus, ARIA, arrows and modality are all outside
the primitive. They live in `cdk/menu`, `cdk/a11y`, `cdk/dialog`, `material/*`,
and — newest of all — an overlay-free behaviour package under `src/aria/` whose
combobox, menu and listbox implementations contain no reference to the overlay
package at all (a repo-wide grep for `overlay` under `src/aria/` matches two
spec files and the two `BUILD.bazel` entries carrying their test deps, and no
implementation module).

### Design philosophy

**Strategies as objects, geometry as arithmetic.** The placement policy is
stated in full in a four-bullet doc comment above `apply()`, and what it does
_not_ contain is as informative as what it does: no flip, no shift, no
auto-placement, no boundary element. The fallback objective is **visible area**,
not overflow distance.

> ```text
> // src/cdk/overlay/position/flexible-connected-position-strategy.ts:222-229
>  * The selection of a position goes as follows:
>  *  - If any positions fit completely within the viewport as-is,
>  *      choose the first position that does so.
>  *  - If flexible dimensions are enabled and at least one satisfies the given minimum width/height,
>  *      choose the position with the greatest available size modified by the positions' weight.
>  *  - If pushing is enabled, take the position that went off-screen the least and push it
>  *      on-screen.
>  *  - If none of the previous criteria were met, use the position that goes off-screen the least.
> ```

**Measure once, then decide with pure arithmetic.** The separation is not
implicit — it is written down and enforced by comment on the one helper that
would be tempting to make measure:

> ```text
> // src/cdk/overlay/position/flexible-connected-position-strategy.ts:833-834
>    * This method does no measuring and applies no styles so that we can cheaply compute the
>    * bounds for all positions and choose the best fit based on these results.
> ```

**Route events by stack recency, not by hit-testing the target.** The keyboard
dispatcher's comment is the clearest statement in the package of why a flat,
recency-ordered stack beats a positional test — and of why a non-participating
overlay must be transparent rather than a blocker:

> ```text
> // src/cdk/overlay/dispatchers/overlay-keyboard-dispatcher.ts:51-56
>       // Dispatch the keydown event to the top overlay which has subscribers to its keydown events.
>       // We want to target the most recent overlay, rather than trying to match where the event came
>       // from, because some components might open an overlay, but keep focus on a trigger element
>       // (e.g. for select and autocomplete). We skip overlays without keydown event subscriptions,
>       // because we don't want overlays that don't handle keyboard events to block the ones below
>       // them that do.
> ```

## How it works

An overlay is created by the free function `createOverlayRef(injector, config)`
(`overlay.ts:52`). It eagerly builds a **two-element pair**: a _host_ `div` and,
inside it, a _pane_ `div` carrying `cdk-overlay-pane`. The host is what the
position strategy sizes (it becomes the "bounding box" in flexible mode); the
pane is what the content is portalled into and what `pointer-events: auto`
applies to. Both are public API on `OverlayRef` (`hostElement`, `overlayElement`)
because every strategy writes styles to them.

The v22 layering decision is made once, at creation, by feature detection:

```ts
// src/cdk/overlay/overlay.ts:75-79
if (!doc.body || !('showPopover' in doc.body)) {
  overlayConfig.usePopover = false;
} else {
  overlayConfig.usePopover = config?.usePopover ?? defaultUsePopover;
}
```

`defaultUsePopover` is `injector.get(OVERLAY_DEFAULT_CONFIG, …)?.usePopover ?? true`
(`overlay.ts:67-68`), so top-layer rendering is the default where the platform
offers it, and the historical container `div` is the fallback. When it is on, the
host gets `popover="manual"` (`overlay.ts:88`) and `showPopover()` is called
inside a `try`/`catch` on attach (`overlay-ref.ts:449`).

The placement engine is `FlexibleConnectedPositionStrategy`. One `apply()` call
takes four measurements — narrowed viewport, origin rect, overlay pane rect,
container rect (`:253-256`) — and then runs a single pass over the author's
ordered `ConnectedPosition[]` with no further reads:

```text
apply():
    viewport   = narrowedViewportRect()          // clientWidth/Height + scroll − margins
    originRect = getOriginRect()                 // element rect, or a rect built from a point
    overlayRect, containerRect = measured once

    flexibleFits = []
    fallback = null
    for pos in preferredPositions:               // author order = designer preference
        originPoint  = originPointFor(originRect, containerRect, pos)
        overlayPoint = overlayPointFor(originPoint, overlayRect, pos)   // top-left of overlay
        fit          = overlayFit(overlayPoint, overlayRect, viewport, pos)

        if fit.isCompletelyWithinViewport:       # TIER 1 — first perfect fit wins, return now
            applyPosition(pos, originPoint); return
        if canFitWithFlexibleDimensions(fit, overlayPoint, viewport):
            flexibleFits ~= {position: pos, origin: originPoint,
                             boundingBoxRect: calculateBoundingBoxRect(originPoint, pos)}
        if fit.visibleArea > (fallback?.overlayFit.visibleArea ?? 0):
            fallback = {position: pos, originPoint, overlayFit: fit}

    if flexibleFits:                             # TIER 2 — best weighted bounding-box area
        best = argmax(f => f.boundingBoxRect.width * f.boundingBoxRect.height * (f.position.weight || 1))
        applyPosition(best.position, best.origin); return

    if canPush:                                  # TIER 3 — least-bad, pushed on-screen
        applyPosition(fallback.position, fallback.originPoint); return

    applyPosition(fallback.position, fallback.originPoint)   # TIER 4 — least-bad, unmoved
```

Event routing is two singletons over one flat array. `BaseOverlayDispatcher`
holds `_attachedOverlays: OverlayRef[]` (`base-overlay-dispatcher.ts:21`), adds
with **remove-then-push** so re-attaching raises to the top (`:30-35`), installs
the global listener lazily on the first add and tears it down at zero (`:46-48`).
Participation is a single predicate:

```ts
// src/cdk/overlay/dispatchers/base-overlay-dispatcher.ts:55-65
protected canReceiveEvent<T>(overlayRef: OverlayRef, event: Event, stream: Subject<T>): boolean {
  if (stream.observers.length < 1) {
    return false;
  }

  if (overlayRef.eventPredicate) {
    return overlayRef.eventPredicate(event);
  }

  return true;
}
```

## The analysis spine

### 1. Anchor model

The anchor type is a three-way union,
`FlexibleConnectedPositionStrategyOrigin = ElementRef | Element | (Point & {width?, height?})`
(`flexible-connected-position-strategy.ts:37-44`), but it is normalized **one
way** at the top of every `apply()`. `_getOriginRect()` (`:1275`) returns a
`Dimensions` — a `DOMRect` minus `x`/`y`/`toJSON` (`:45`) — so everything
downstream sees only a rect. A bare point becomes a 0×0 rect at that point; a
point with `width`/`height` becomes a rect of that size, pinned by a spec at
`flexible-connected-position-strategy.spec.ts:2460` ("should be able to position
relative to a point with width and height").

Re-anchoring is first class. `setOrigin()` (`:488`) mutates the strategy, and
`CdkContextMenuTrigger._open` (`context-menu-trigger.ts:210-232`) uses it to move
an _already open_ menu to a new cursor point — first calling
`menuStack.closeSubMenuOf(this.childMenu!)` so submenus do not end up
disconnected, then `setOrigin(coordinates)` and `updatePosition()`. One popup,
many triggers therefore falls out of the design.

`MatTooltip.positionAtOrigin` swaps the anchor from the trigger element to the
_mouse point captured at `mouseenter`/`touchstart`_; because the cached
strategy's `_origin` would still be an `ElementRef`, `_createOverlay` tears down
and rebuilds the overlay when that mode is active (`tooltip.ts:503`).

What is absent: no text-range multi-rect anchor, no sub-region of an element, no
[virtual anchor][concepts] in the callback sense (no analogue of a
`getBoundingClientRect()`-only object — the `Point` form is data, not a
callback), no separate trigger-vs-anchor distinction, and no screen coordinates
anywhere: the whole engine stays in viewport space.

**Algorithm.**

```text
resolveAnchor(origin) -> Rect:
    if origin is ElementRef: return origin.nativeElement.getBoundingClientRect()
    if origin is Element:    return origin.getBoundingClientRect()   // Element, not HTMLElement, so SVG works
    else:
        w = origin.width  ?? 0
        h = origin.height ?? 0
        return {top: origin.y, bottom: origin.y + h,
                left: origin.x, right: origin.x + w, width: w, height: h}
```

**Where it lives.** Library code — `_getOriginRect` / `setOrigin` on the
strategy. The measurement itself is the platform primitive
`getBoundingClientRect`.

**Degradation.** The rect-normalization step is exactly the seam a cell toolkit
needs: an [anchor rect][concepts] in integer cells produced by the layout pass
instead of by a DOM read, with the point form already serving as the
cursor/context-menu anchor. Nothing here needs an OS window, hover, script or
sub-cell precision. What must be _added_ rather than ported is a multi-rect
anchor for a text run that wraps across rows: CDK has no answer for that shape
and would place against a single union rect.

### 2. Placement model

Placement is not sides-plus-alignment. It is a **connection-point pair**: one of
9 points on the anchor (`originX ∈ {start, center, end}` × `originY ∈ {top, center, bottom}`)
paired with one of 9 on the overlay, i.e. 81 expressible placements, plus
per-position `offsetX`/`offsetY`, `weight` and `panelClass`. `ConnectedPosition`
(`:1374-1385`) is a pure data interface — no methods.

The horizontal axis is **logical**: `start`/`end` are resolved through `_isRtl()`
at compute time in both `_getOriginPoint` (`:557`) and `_getOverlayPoint`
(`:602`). The vertical axis is physical `top`/`bottom`, with no writing-mode
support.

Fallback ordering is the author's list order. There is no automatic
[flip][concepts] and no automatic [shift][concepts]: flipping is something the
author _expresses_ by listing more positions, and the engine reports which one it
chose. Two canned lists are exported for the common cases —
`STANDARD_DROPDOWN_BELOW_POSITIONS` (`:1445`, four entries: below-start,
above-start, below-end, above-end) and `STANDARD_DROPDOWN_ADJACENT_POSITIONS`
(`:1452`, four entries for submenus).

The [clipping boundary][concepts] is the viewport and only the viewport:
`documentElement.clientWidth/clientHeight` (deliberately _client_, so the
scrollbar is excluded to match the container's `width: 100%`) plus scroll offset,
narrowed by `withViewportMargin` (`:447`), which accepts a scalar or
`{top, bottom, start, end}` (`connected-position.ts:16`). No custom boundary
element, no safe-area insets, no work areas, no multi-monitor, no IME box.

> [!NOTE]
> INFERENCE (read from control flow, not test-confirmed): `_getNarrowedViewportRect`
> (`:1157-1175`) maps the _logical_ `start`/`end` margins onto the physical
> `left`/`right` edges without consulting `_isRtl()`, unlike every other use of
> `start`/`end` in the same file. Reading the code, an RTL context with an
> asymmetric margin would therefore narrow the physical left edge by the `start`
> margin. No test covering RTL asymmetric viewport margins was found.

**Algorithm.**

```text
originPoint(originRect, containerRect, pos):
    x = pos.originX == 'center' ? left + width/2
                                : (pos.originX == 'start' ? (rtl ? right : left)
                                                          : (rtl ? left  : right))
    y = pos.originY == 'center' ? top + height/2
                                : (pos.originY == 'top' ? top : bottom)
    if containerRect.left < 0: x -= containerRect.left   // Safari page zoom
    if containerRect.top  < 0: y -= containerRect.top    // virtual keyboard / Safari zoom

overlayPoint(originPoint, overlayRect, pos):     // returns the overlay's TOP-LEFT
    dx = pos.overlayX == 'center' ? -w/2 : pos.overlayX == 'start' ? (rtl ? -w : 0) : (rtl ? 0 : -w)
    dy = pos.overlayY == 'center' ? -h/2 : pos.overlayY == 'top'   ? 0             : -h
    return originPoint + (dx, dy)
```

**Where it lives.** Library code only. Nothing is delegated to CSS anchor
positioning or to the platform; the browser is a measuring tape and a paint
target for computed `top`/`left`/`bottom`/`right` strings.

**Degradation.** The 3×3-to-3×3 pair is a four-field enum tuple that compares by
value and needs no floating point, so it survives a cell port unchanged;
`start`/`end` resolution is a pure boolean. The soft-keyboard case is the one
place the _mechanism_ does not transfer (see dimension 3), but the _shape_ does:
`apply()` consumes a pre-narrowed viewport rect and nothing else, so an explicit
inset folded into that rect is a drop-in substitute. On a script-free static-HTML
tier there is no measurement at emit time, so the fallback list collapses to
`positions[0]` and one placement is baked in.

### 3. Collision & geometry engine

Overflow detection is four signed subtractions per candidate against the narrowed
viewport, each clamped at zero by `_subtractOverflows` (`:1150`), producing
`visibleWidth × visibleHeight = visibleArea`. The perfect-fit test is a single
equality on that product rather than four booleans:

```ts
// src/cdk/overlay/position/flexible-connected-position-strategy.ts:656-671
let leftOverflow = 0 - x;
let rightOverflow = x + overlay.width - viewport.width;
let topOverflow = 0 - y;
let bottomOverflow = y + overlay.height - viewport.height;

// Visible parts of the element on each axis.
let visibleWidth = this._subtractOverflows(
  overlay.width,
  leftOverflow,
  rightOverflow,
);
let visibleHeight = this._subtractOverflows(
  overlay.height,
  topOverflow,
  bottomOverflow,
);
let visibleArea = visibleWidth * visibleHeight;

return {
  visibleArea,
  isCompletelyWithinViewport: overlay.width * overlay.height === visibleArea,
  fitsInViewportVertically: visibleHeight === overlay.height,
  fitsInViewportHorizontally: visibleWidth == overlay.width,
};
```

Per-position offsets are added to the point **before** the fit test (`:646-653`)
precisely so that an 8 px tooltip gap can itself push a candidate off-screen.

> [!NOTE]
> INFERENCE (read from control flow, not test-confirmed): in the block above the
> leading bounds are the literal `0`, while the trailing bounds are
> `viewport.width`/`viewport.height`, which `_getNarrowedViewportRect` already
> reduced by _both_ margins. So during the fit test a symmetric
> `viewportMargin: 8` appears to be charged twice on the trailing edges and not
> at all on the leading ones; the leading margin re-enters only through
> `_calculateBoundingBoxRect` and `_pushOverlayOnScreen`. No test pinning either
> reading was found.

Sub-pixel deviation is handled by flooring: `getRoundedBoundingClientRect`
(`:1420`) floors all six fields of the _overlay_ rect before comparison, because
browser zoom yields fractional `DOMRect`s, and a spec patches
`getBoundingClientRect` to add 0.1 px and asserts placement is unaffected
(`…spec.ts:832`). Safari page zoom yields a _negative_ container rect, undone by
the two `containerRect < 0` corrections; a spec simulates the mobile
virtual-keyboard variant of the same correction by setting the container's `top`
to a negative value (`…spec.ts:2145`, `:2173`).

**Clipping-ancestor discovery does not exist.** The caller must hand the strategy
a list via `withScrollableContainers(scrollables)`, and those come from
`ScrollDispatcher.getAncestorScrollContainers`, which finds only _registered_
`CdkScrollable` directives — an arbitrary `overflow: hidden` ancestor is
invisible. More consequentially, those containers never influence placement at
all: they feed only `_getScrollVisibility()` (`:1129`), which computes four
booleans (`isOriginClipped`, `isOriginOutsideView`, `isOverlayClipped`,
`isOverlayOutsideView`) _reported_ on `positionChanges`, and only when someone is
subscribed. `MatTooltip` is the consumer that acts on them. So CDK's boundary is
the viewport and its clipping ancestor governs only an "is the anchor hidden"
verdict — a two-role split the catalog picks up in [`./concepts.md`][concepts]
and weighs against the other subjects in [`./comparison.md`](./comparison.md).

Tracking is polling-by-event, never observers: `ScrollDispatcher.scrolled()`
audits at `DEFAULT_SCROLL_TIME = 20` ms (`scroll-dispatcher.ts:16`) over one
document-level `scroll` listener plus per-`CdkScrollable` listeners, and
`ViewportRuler.change()` audits at `DEFAULT_RESIZE_TIME = 20` ms
(`viewport-ruler.ts:15`) over `resize` + `orientationchange`. There is no
`ResizeObserver` and no `IntersectionObserver`; `position/scroll-clip.ts:10`
carries the standing `TODO(jelbourn): someday replace this with IntersectionObservers`.
Anchor or content **resize is not tracked at all**: `OverlayRef.attach` schedules
exactly one `afterNextRender(() => updatePosition())` (`overlay-ref.ts:157`), and
every later reposition must be requested by the consumer or driven by a scroll
strategy.

**Algorithm.**

```text
getOverlayFit(point, overlayRect, viewport, pos):
    o = floorAllFields(overlayRect)
    x = point.x + offsetX(pos)
    y = point.y + offsetY(pos)
    leftOver = 0 - x           ; rightOver  = x + o.w - viewport.width
    topOver  = 0 - y           ; bottomOver = y + o.h - viewport.height
    visW = o.w - max(leftOver, 0) - max(rightOver, 0)
    visH = o.h - max(topOver, 0)  - max(bottomOver, 0)
    return {visibleArea: visW * visH,
            isCompletelyWithinViewport: o.w * o.h == visW * visH,
            fitsVertically: visH == o.h, fitsHorizontally: visW == o.w}
```

**Where it lives.** Library code end to end. `getBoundingClientRect`,
`documentElement.clientWidth/Height` and the viewport scroll position are the
only platform primitives; the compositor and the accessibility tree are not
involved.

**Degradation.** The scoring core is six integer subtractions, two clamped sums
and one multiply per candidate over rects a layout pass already knows, so it
generalizes off the DOM directly. In whole cells the sub-pixel machinery
disappears (`getRoundedBoundingClientRect` becomes the identity, the
`w*h == visibleArea` test is exact with no epsilon), and both Safari corrections
disappear with it. The two things that do _not_ generalize are the two things CDK
also declined to solve: clipping-ancestor discovery (punted to the caller) and
content-resize tracking (punted to `updatePosition()`). The virtual-keyboard
correction specifically does not port: it _infers_ the inset from the overlay
container having been scrolled to a negative offset by a mobile browser, and with
no reparenting host there is nothing to infer from — the inset has to become an
explicit field on the boundary rect. Because every input is a value and the
output is a point, the whole cascade is unit-assertable with no window.

### 4. Arrow / caret geometry

**Not applicable — and the absence is the finding.** There is no arrow or caret
concept anywhere in `src/cdk/overlay`: a case-insensitive grep for `arrow`/`caret`
across the package matches only `Key.ARROW_DOWN`/`Key.ARROW_RIGHT` keystrokes in
`scroll/block-scroll-strategy.e2e.spec.ts` and the substring inside
`_getNarrowedViewportRect`. `material/tooltip` has no caret either — its template
is two nested plain `div` elements.

CDK's position is that arrow geometry is a _component styling_ concern, and it
gives the styling layer two channels of placement feedback instead:

- `withTransformOriginOn(selector)` (`:519`) makes the strategy write a
  [`transform-origin`][concepts] _string_ onto every descendant matching a CSS
  selector, where the x component is RTL-resolved from `overlayX` and the y
  component is `overlayY` verbatim (`_setTransformOrigin`, `:806`).
- `ConnectedPosition.panelClass` (`:1384`) adds author-chosen classes to the pane
  for as long as that position is active, cleared on every re-`apply()` (`:246`,
  `:347`) via `_addPanelClasses`/`_clearPanelClasses` (`:1217`, `:1229`).

`MatTooltip` layers a third channel: `_updateCurrentPositionClass` (`:746`)
collapses the chosen `ConnectionPositionPair` back into one of
`above | below | left | right` and toggles `mat-mdc-tooltip-panel-<pos>`.

So the resolved side _is_ exposed — as a symbol, never as a number. Nothing tells
the styling layer the arrow's centre offset, so nothing can constrain an arrow
near a corner, hide it when the anchor is too small, or feed the arrow's size back
into the placement offset; `material/tooltip` hard-codes `UNBOUNDED_ANCHOR_GAP = 8`
(`tooltip.ts:176`) instead.

**Algorithm.** There is no arrow algorithm. The nearest thing is the
transform-origin string:

```text
setTransformOrigin(pos):
    yOrigin = pos.overlayY                              // 'top' | 'bottom' | 'center'
    xOrigin = pos.overlayX == 'center' ? 'center'
            : rtl ? (pos.overlayX == 'start' ? 'right' : 'left')
                  : (pos.overlayX == 'start' ? 'left'  : 'right')
    for el in boundingBox.querySelectorAll(selector):
        el.style.transformOrigin = xOrigin + ' ' + yOrigin
```

**Where it lives.** Not in the primitive. Distributed across each component's
SCSS (reached through panel classes) and the strategy's two string-emitting
hooks.

**Degradation.** With a character cell as the smallest unit, an arrow is one
glyph in one cell on the edge facing the anchor. Every arrow feature CDK lacks is
cheap at that resolution — the centre offset is an integer cell index, corner
constraint is a `clamp`, border-awareness is the choice between painting a tee
into the border run and a solid glyph inside it. But the _channel_ CDK chose does
not transfer: a cell toolkit paints the arrow itself, so the resolved side and
the arrow's cell must be part of the placement result rather than a class name a
stylesheet interprets. What CDK does get right, and what is worth keeping, is
that the resolved placement is reported at all. See
[`./features-people-forget.md`](./features-people-forget.md) and
[`./proposal.md`](./proposal.md).

### 5. Trigger semantics

`OverlayRef` has no triggers: `attach(portal)` (`overlay-ref.ts:131`),
`detach()` and `dispose()` are imperative, and the primitive's only concession is
that it _routes_ keyboard and outside-pointer streams back to whoever opened it.
Triggers are re-implemented per consumer, and the four in-repo implementations
are instructive because each solves a different race:

1. **`CdkConnectedOverlay` is fully controlled.** `@Input('cdkConnectedOverlayOpen') open`
   (`overlay-directives.ts:221`) is acted on in `ngOnChanges`:
   `this.open ? this.attachOverlay() : this.detachOverlay()` (`:337`).
2. **`CdkMenuTrigger`** binds `(click)`, `(keydown)` and — outside the Angular
   zone — `mouseenter`. The hover path is triple-gated (`menu-trigger.ts:230-240`):
   `_inputModalityDetector.mostRecentModality !== 'touch'` (kills synthetic mouse
   events from taps), the menu stack must be non-empty (hover only _switches_
   menus once one is open; it never opens the first), and the trigger must not
   already be open. Space/Enter go through `eventDispatchesNativeClick(elementRef, event)`
   (`:169`) so a `button` element does not toggle twice — once from `keydown` and
   again from the synthesized click.
3. **`CdkContextMenuTrigger`** binds `(contextmenu)` (`context-menu-trigger.ts:102`)
   with both `preventDefault()` and `stopPropagation()`, so among nested
   context-menu regions exactly the innermost enabled one opens; it then branches
   initial focus on `event.button` (`:116`), treating button 2 as mouse and
   button 0 as the keyboard (Shift+F10 / menu-key) path.
4. **`MatTooltip`** chooses its entire listener set once, at `ngAfterViewInit`,
   from `_isTouchPlatform()`: on hover platforms `mouseenter` + `mouseleave` +
   `wheel`; on touch platforms a `touchstart` long-press timer plus
   `touchend`/`touchcancel`. Exit listeners are attached lazily on the first
   enter (`_setupPointerExitEventsIfNeeded`, `tooltip.ts:817`), so a tooltip that
   is never hovered never owns a leave listener. Focus triggers only when
   `FocusMonitor` reports `origin === 'keyboard'` (`:413-422`), so click-focus
   shows nothing, and any blur hides at delay 0.

Assistive-technology activation is not a distinct modality anywhere.

**Algorithm.** There is no trigger combinator; each trigger is a hand-rolled
guard chain. The three reusable anti-race devices are:

```text
A. modality gate:     if inputModalityDetector.mostRecentModality == 'touch': ignore the synthetic mouse event
B. native-click gate: if this key would produce a native click on this element, let the click handler own it
C. open-set gate:     hover only RE-TARGETS an open surface; it never opens the first one
```

**Where it lives.** Entirely in consumer directives (`cdk/menu`,
`material/tooltip`). The pieces that _were_ factored out are `cdk/a11y`'s
`InputModalityDetector` and `FocusMonitor` — modality is a cross-cutting service,
not per-trigger state.

**Degradation.** All three gates transfer: modality becomes a field on the
event or on the target's capability struct, "would this key produce a click" is a
widget-kind question the view can answer, and the open-set gate is a
stack-emptiness check. What does not transfer is the touch long-press _on the
TUI_: a terminal serves pointer release but not key release, so a
press-and-hold keyboard trigger is undefinable there and touch adaptation has to
be a target-level decision made before any timer exists (see
[`../../specs/ui/input.md`](../../specs/ui/input.md)). On Android there is no
hover at all, so gate C has no input to fire on and submenus must open on tap. On
static HTML the only trigger is `:hover`/`:focus-within` or a
`details`/`:checked` toggle — and a controlled `open` boolean maps onto
`details[open]` exactly, which is an argument for a _controlled_ overlay in the
`CdkConnectedOverlay` style rather than a self-toggling one.

### 6. Timing

There is no timing in the primitive at all. `MatTooltip` owns the only real
timing model and it is deliberately thin: `showDelay` and `hideDelay` default to
**0**, `touchendHideDelay` to **1500** (`tooltip.ts:99-101`), and
`touchLongPressShowDelay` falls back to `DEFAULT_LONGPRESS_DELAY = 500`
(`:808-812`). The timers live in the _content_ component
(`TooltipComponent.show(delay)` / `.hide(delay)`), each clearing the other's
pending timeout, so show→hide→show inside the delay window collapses to one
transition. It is a two-timer mutual-cancel machine, not a state machine.

There is no [warm-up][concepts], no [cool-down][concepts] / skip-delay, no
"instant subsequent tooltip" when moving between neighbours in a toolbar, no
shared singleton tooltip instance, no group provider and no maximum display
duration. Every trigger owns its own overlay and its own timers, so traversing a
toolbar re-pays the show delay at every button.

Two subtler devices are worth stealing:

- `_closeOnInteraction` (`:1005`) is set true only inside `_finalizeAnimation(true)`
  (`:1134-1137`), i.e. _after the show animation ends_; until then
  `_handleBodyInteraction()` (`:1072`) is a no-op. That is a self-tuning debounce
  preventing the very tap that opened a touch tooltip from immediately closing it,
  with no magic millisecond constant.
- `show()` early-returns when already visible but still calls
  `_cancelPendingAnimations()` (`:453`), so a re-entry cancels a pending hide
  rather than restarting a show.

`cdk/menu` contributes `CLOSE_DELAY = 300` for the submenu grace period
(`menu-aim.ts:57`). The backdrop's exit waits on `transitionend` with a
`setTimeout(this.dispose, 500)` fallback for the no-transition case
(`backdrop-ref.ts:34-35`).

**Algorithm.** CDK has no single machine; stated as one, its pieces add up to:

```text
states: Closed, Opening(t_show), Open, Closing(t_hide)

Closed  --intent(open)-->   Opening   [start t_show]
Opening --intent(close)-->  Closed    [cancel t_show]        // mutual cancel
Opening --timer-->          Open      [dismissable := false]
Open    --presented-->      Open      [dismissable := true]  // gated on the enter transition ENDING
Open    --intent(close)-->  Closing   [start t_hide]
Closing --intent(open)-->   Open      [cancel t_hide]        // re-entry, no re-show delay
Closing --timer-->          Closed
```

The two facts this factoring gets right are mutual cancellation between the two
timers and gating [light dismiss][concepts] on presentation _completion_ rather
than on a millisecond guard.

**Where it lives.** `material/tooltip` (the directive plus its content
component); `cdk/menu/menu-aim.ts` for the 300 ms submenu grace. Nothing in
`cdk/overlay`.

**Degradation.** On static HTML there are no timers: the machine collapses to
Closed/Open driven by `:hover`, and the only surviving knob is a CSS
`transition-delay`, which cannot express mutual cancellation. On the TUI timers
exist (there is a frame loop) and hover is served, so both delays remain
meaningful — but there is no key-press duration, so nothing keyed to holding a
key survives. On Android the machine is driven only by tap and long-press, and
long-press needs a _down_ timer cancelled by up. For a recording canvas the
machine is assertable only if time is an explicit input to the frame step
(a `dt` parameter) rather than read from a clock — which is the single most
important structural consequence of "every behaviour must be assertable
headlessly". See [`./sparkles-baseline.md`](./sparkles-baseline.md).

### 7. Interactive hover

CDK has exactly one hover-intent algorithm, `TargetMenuAim`, and it is a
**trajectory-consensus predictor**, not a [safe polygon][concepts].

It samples every 3rd `mousemove` over the root menu element
(`MOUSE_MOVE_SAMPLE_FREQUENCY = 3`, `menu-aim.ts:48`) into a ring buffer of
`NUM_POINTS = 5` (`:51`). When a sibling trigger is hovered and wants to close
the currently open submenu, `_isMovingToSubmenu` (`:201-219`) takes the newest
point, draws a line from it to each of the 4 older points, and asks whether that
infinite line intersects the open submenu's `DOMRect` — `isWithinSubmenu` (`:86`)
performs four edge tests. If at least `Math.floor(NUM_POINTS / 2) = 2` of the 4
lines hit, the user is judged to be heading for the submenu and the close is
deferred:

```ts
// src/cdk/menu/menu-aim.ts:189-195
const timeoutId = setTimeout(() => {
  // Resolve if the user is currently moused over some element in the root menu
  if (this._pointerTracker!.activeElement && timeoutId === this._timeoutId) {
    doToggle();
  }
  this._timeoutId = null;
}, CLOSE_DELAY) as any as number;
```

Note what that does: the heuristic never wins permanently. A timeout always
resolves it, and it resolves by _re-validating_ against "is the pointer still on
a root-menu item", not by trusting the earlier prediction. Two guards make the
whole thing safe (`toggle`, `:153-175`): `siblingItemIsWaiting` means at most one
deferred close exists at a time, and a cold start with fewer than two samples
closes immediately. If the parent menu is horizontal the predicate is skipped
entirely — submenus open downward, so there is no diagonal hazard. The service is
opt-in per menu, via the `CdkTargetMenuAim` directive (`:270`); it is off by
default.

For trigger→tooltip travel there is no geometry at all. `mouseleave` on the
trigger inspects `event.relatedTarget` and suppresses the hide when the new
target is inside the overlay element (`tooltip.ts:823-829`); the panel's own
`mouseleave` (`:1087`) does the symmetric check against the trigger.

> [!NOTE]
> INFERENCE (read from control flow, not test-confirmed): because
> `UNBOUNDED_ANCHOR_GAP` is 8 px, a pointer crossing from trigger to tooltip
> passes over page content where `relatedTarget` is neither element, so the hide
> starts. On that reading, travel survives only because the hide delay is still
> running when the pointer arrives — there is no pointer bridge across the gap.
> No test in the repo covers pointer travel across it.

**Algorithm.** The cost in whole cells is the point of the exercise:

```text
sample buffer: 5 points, each an integer (col, row) — 40 bytes, no allocation.
per decision:  4 candidate lines x 4 edge tests = 16 intersection tests.

In cells the slope is a RATIO, so no floating point is needed. For each older
point p, with d = (cur.col - p.col, cur.row - p.row), the line through cur with
direction d hits rect R iff the 4 corners of R do not all lie on one side:
    sign(d.x * (c.row - cur.row) - d.y * (c.col - cur.col)) is not constant over the 4 corners

  -> 20 integer multiplies, 20 subtractions, 16 sign tests, ZERO divisions.
```

The cross-product form is a strict improvement CDK does not make: its `getSlope`
(`menu-aim.ts:66`) divides, yielding `Infinity` for purely vertical motion — the
common case of moving straight down a menu — and `NaN` for a repeated sample.

**Where it lives.** `cdk/menu/menu-aim.ts` (opt-in service) plus
`PointerFocusTracker` for "is the pointer still on an item". Nothing in
`cdk/overlay`. The tooltip's travel logic is in `material/tooltip` and depends on
a hit-tested `relatedTarget` the platform supplies.

**Degradation.** On the TUI hover is served, so trajectory prediction remains
meaningful — but motion arrives at cell granularity and only when motion
reporting has been switched on, so 1-in-3 sampling should become 1-in-1 and the
buffer should shrink. INFERENCE, not measured: at cell scale a 5-sample buffer
spans far more visual distance per sample than at pixel scale, so an equivalent
tuning is likely closer to N=3 with a threshold of 1. On Android there is no
hover, so menu-aim is inert and the diagonal-travel problem does not exist. On
static HTML there is no script, no timer and no measurement, so a "safe region"
must be a _layout_ fact — a container that geometrically encloses both trigger
and submenu — not a computed region. The `relatedTarget` trick does not survive
either: with reverse-paint-order hit testing over a flat derived list, "what is
under the pointer now" is available but "what is the pointer moving to" is not a
platform-supplied value and must be computed from the same hit list.

### 8. Dismissal

The primitive dismisses nothing; it _routes_ two streams and lets the owner
decide. Of the mechanisms read here, this is the one that ports most directly.

**Escape.** `OverlayKeyboardDispatcher` delivers `keydown` to the top willing
overlay; `CdkConnectedOverlay` then checks
`event.keyCode === ESCAPE && !this.disableClose && !hasModifierKey(event)`
(`overlay-directives.ts:353`) and calls `detachOverlay()`. Modifier exclusion is
explicit — Ctrl+Escape does not dismiss.

**Outside pointer.** A two-sample predicate. The dispatcher records the
`pointerdown` target (`overlay-outside-click-dispatcher.ts:78-80`), and on a
`click` pairs it with the release target:

```ts
// src/cdk/overlay/dispatchers/overlay-outside-click-dispatcher.ts:91-97
const origin =
  event.type === 'click' && this._pointerDownEventTarget
    ? this._pointerDownEventTarget
    : target;
// Reset the stored pointerdown event target, to avoid having it interfere
// in subsequent events.
this._pointerDownEventTarget = null;
```

Both press origin and release target must be outside for a dismissal to be
emitted (`:124-128`). All four down/up combinations are pinned by specs
(`overlay-outside-click-dispatcher.spec.ts:191`, `:213`, `:232`, `:254`):
outside→outside dismisses; inside→inside does not; inside→outside does not (so
drag-selecting text out of a panel keeps it open); outside→inside does not.
Listening is capture-phase on `body` for `pointerdown`, `click`, `auxclick` and
`contextmenu` (`:45-50`), so a component's `stopPropagation()` cannot defeat
dismissal. The array is snapshotted with `.slice()` before iteration (`:102`)
because subscribers routinely detach several overlays from inside the loop —
there is a spec whose entire purpose is asserting that does not throw (`:307`).
On iOS the dispatcher sets `body { cursor: pointer }` while any overlay is
attached and restores the previous value on teardown (`:54-58`, `:69-72`),
because Safari does not dispatch `click` for non-interactive elements otherwise.

**Scroll.** A first-class strategy _value_ with four implementations totalling
359 lines: `noop` (the default, 24 lines), `close` (detach on the first scroll
not originating inside the overlay; with `threshold > 1` it repositions until the
cumulative delta exceeds the threshold and only then detaches,
`close-scroll-strategy.ts:79-92`), `block` (pin `documentElement` and add
`cdk-global-scrollblock`, restoring the scroll position on disable; guarded by
`_canBeEnabled()` (`block-scroll-strategy.ts:99-106`) so nested overlays do not
double-block and a non-scrolling page is left alone), and `reposition`
(`updatePosition()` per audited scroll, plus opt-in `autoClose` that detaches
when the overlay rect leaves the viewport, `reposition-scroll-strategy.ts:73-88`).

**Navigation.** `disposeOnNavigation` (`overlay-config.ts:62`).

**Anchor hidden or removed.** Not handled. The only signal is the
`ScrollingVisibility` payload on `positionChanges`, which requires the caller to
have supplied scrollables _and_ to be subscribed. Window/application deactivation
is not handled anywhere.

**Tree dismissal.** Not in `cdk/overlay`. `cdk/menu`'s `MenuStack` owns it:
`close` pops until it has popped `lastItem` (`menu-stack.ts:128`),
`closeSubMenuOf` pops until the peek is `lastItem` (`:149`), `closeAll` drains
(`:164`). Losing focus from the whole stack is detected by a `hasFocus` stream
built with `debounceTime(0)` + `distinctUntilChanged` (`:88-91`) — the zero-delay
debounce is what stops a `focusout` immediately followed by a `focusin` _within_
the stack from reading as focus loss. Tab is treated as
`closeAll({focusParentTrigger: true})` (`menu.ts:94-96`).

**Algorithm.**

```text
outsideClickDispatch(event):
    target = pierceShadowDom(event.target)
    origin = (event.type == 'click' && lastPointerDownTarget) ? lastPointerDownTarget : target
    lastPointerDownTarget = null
    for ref in attachedOverlays.slice().reverse():           // TOP DOWN
        if !ref.hasAttached() or !canReceiveEvent(ref, event, ref._outsidePointerEvents): continue
        if contains(ref.overlayElement, target) or contains(ref.overlayElement, origin):
            break                                            // the click landed here — stop
        ref._outsidePointerEvents.next(event)                // outside — notify AND KEEP GOING
    // net effect: one click closes the whole run of surfaces above the one it hit
```

**Where it lives.** `cdk/overlay/dispatchers/*` (routing),
`cdk/overlay/scroll/*` (policy as a value), consumer directives (the actual close
decision), `cdk/menu/menu-stack.ts` (tree dismissal).

**Degradation.** The dispatcher pattern is target-independent: replace
"capture-phase `body` listener" with "the frame's event router, run before widget
hit testing", and `contains(overlayElement, target)` with "the hit list entry's
owning surface id" — which is cheaper than CDK's shadow-DOM-piercing walk
(`:141`). One adaptation is mandatory. Without a native pointer [grab][concepts],
a press that leaves the surface may never produce a release, so the
press/release conjunction must degrade to "press outside ⇒ dismiss on press" when
no release arrives, keeping the conjunction as an _optimisation_ for the drag
case rather than a precondition; otherwise overlays get stuck open. On the TUI
there is no key release, but dismissal only needs key _press_, so Escape survives
intact; an Android system back key maps onto exactly the same top-down stack walk.
On static HTML the only dismissal is losing `:hover`/`:focus-within` or
unchecking the toggle, so a tier-0 emit has to make every surface reachable _and_
leavable by hover/focus alone.

### 9. Focus

`cdk/overlay` contains zero focus code — no trap, no restore, no initial focus,
no tab order. Focus is delegated, and the delegation is per-surface-kind, which
expresses the tooltip ≠ popover ≠ menu ≠ dialog distinction _structurally_ rather
than as configuration:

- **Tooltip** — never focusable, never focused. The rendered panel host carries
  `aria-hidden: 'true'` (`tooltip.ts:965`), and `disableTooltipInteractivity`
  removes pointer events from the panel entirely. Focus only _triggers_ it, and
  only with keyboard origin; any blur hides at delay 0.
- **Connected overlay** — nothing at all. `CdkConnectedOverlay` does not move
  focus, which is the right default for a positioned popover whose content may or
  may not be interactive, and pushes the whole burden to the consumer.
- **Menu** — no trap. A roving tabindex per menu, plus a `MenuStack` that carries
  focus intent _as data_: `CloseOptions {focusNextOnEmpty?: FocusNext, focusParentTrigger?: boolean}`
  (`menu-stack.ts:46`) over `enum FocusNext {nextItem, previousItem, currentItem}`
  (`:15`). Escape closes one level with `focusParentTrigger: true` (`menu.ts:84-90`);
  Tab closes all with the same flag.
- **Dialog** — a real `FocusTrap` from `cdk/a11y`, with a five-way `autoFocus`
  policy (`dialog-container.ts:254-297`: `false`, `'dialog'`, `true`/`'first-tabbable'`,
  `'first-heading'`, or any CSS selector) and a `restoreFocus` policy (boolean,
  selector or element).

Two dialog subtleties are worth stealing. Focusing is deferred to
`afterNextRender` because the content is not laid out yet. And restoration is
_guarded_: `_restoreFocus` (`:300`) skips the restore unless focus is still
inside the closing dialog, on the container, or on `document.body` (the guard is
at `:318-330`), so a consumer that already relocated focus is not overridden.
Restoration then goes through `_focusMonitor.focusVia(focusTargetElement, this._closeInteractionType)`
(`:332`), so the restored element's focus-visible ring matches _how the dialog was
closed_ — mouse close, no ring; keyboard close, ring.

**Algorithm.**

```text
restoreFocus(cfg):
    target = cfg is string ? querySelector(cfg)
           : cfg is bool   ? (cfg ? elementFocusedBeforeOpen : null)
           : cfg
    if !target or !target.focus: return
    active = focusedElementPiercingShadowDom()
    if active is null or active is body or active is container or container.contains(active):
        focusMonitor.focusVia(target, closeInteractionType)   // ring matches the modality of the CLOSE
    // else: the consumer already relocated focus — do nothing
```

**Where it lives.** `cdk/a11y` (`FocusTrap`, `FocusMonitor`,
`InputModalityDetector`, `InteractivityChecker`), `cdk/dialog/dialog-container.ts`
(policy), `cdk/menu/menu-stack.ts` (intent as data). Not the overlay.

**Degradation.** "Focus intent as a data field on the close event" survives
everywhere and turns a side effect into a value a recording canvas can assert.
`focusVia(target, modality)` survives too and matters _more_ in a cell UI, where
the focus ring is often the only affordance. What simplifies: with no OS focus,
"focus" is a toolkit-internal index and the containment-vs-trap distinction
becomes a routing predicate rather than a DOM guard. On static HTML
`:focus-within` gives containment for free but nothing can trap or restore, so a
tier-0 emit must not rely on restoration. On Android focus exists but is largely
irrelevant without a keyboard, and system back should map onto the same "close one
level, return focus to the parent trigger" semantics as Escape. See
[`../../specs/ui/state-machines.md`](../../specs/ui/state-machines.md).

### 10. Layering & portals

CDK runs two layering mechanisms side by side and picks per overlay.

**Legacy.** One lazily created `div.cdk-overlay-container` appended to
`document.body`: `position: fixed`, `z-index: 1000`, `pointer-events: none`, with
`&:empty { display: none }` (`_index.scss:41-53`) so a detached-but-not-disposed
overlay leaves no hit area. Each overlay is the host/pane pair described above;
the pane restores `pointer-events: auto` (`:73`). Front-to-back order is DOM
order, and `_updateStackingOrder()` (`overlay-ref.ts:497-501`) re-appends the host
when it has a `nextSibling` — re-appending _is_ the "raise to front" operation,
and it exists because a detached overlay's stranded host would otherwise paint
below an overlay opened after it.

**New default (v22).** When `'showPopover' in document.body`, `usePopover`
defaults to true, the host gets `popover="manual"`, and `showPopover()` places it
in the browser's [top layer][concepts], where `z-index`, `overflow: hidden` and
stacking contexts are irrelevant. `_updateStackingOrder` is skipped in that mode
because top-layer order is show order. Since a popover no longer needs the
container to escape clipping, a third axis rides along:
`withPopoverLocation('global' | 'inline' | {type: 'parent', element})`
(`flexible-connected-position-strategy.ts:532`) lets the host be inserted next to
the trigger or under an arbitrary parent, making DOM position purely a
style-inheritance and component-tree concern.

`OverlayContainer` is swappable — `FullscreenOverlayContainer` re-parents the
container into `document.fullscreenElement` on `fullscreenchange`
(`fullscreen-overlay-container.ts:43`).

Overlay **trees** are not modelled here. The dispatchers hold a flat
`OverlayRef[]`; hierarchy exists only in `cdk/menu`'s `MenuStack`, a separate
injectable resolved through the DI hierarchy
(`inject(MENU_STACK, {optional: true, skipSelf: true}) || new MenuStack()`,
`menu-stack.ts:31-34`). So CDK's ancestry is supplied by two _host_ relations —
DOM containment for the outside-pointer predicate, and Angular injector ancestry
for the menu stack — rather than stored on the overlay.

**Algorithm.**

```text
attachHost(ref):
    if host has no parent:
        ip = config.usePopover ? positionStrategy.getPopoverInsertionPoint?.() : null
        if ip is Element:               ip.after(host)              // 'inline' — sibling of the trigger
        elif ip is {type:'parent', e}:  e.appendChild(host)
        else:                           previousHostParent.appendChild(host)
    if config.usePopover: try { host.showPopover() } catch {}

updateStackingOrder(ref):
    if !config.usePopover and host.nextSibling:
        host.parentNode.appendChild(host)                           // re-append == raise to front
```

**Where it lives.** Library plus platform. The legacy path is 100 % library (a
`div` and a `z-index`); the new default delegates to a platform primitive.

**Degradation.** The legacy path _is_ the single-surface model, and it maps
cleanly onto "later in the display list is in front" plus "the hit list contains
pane rects, not the container". Two devices transfer directly:
`:empty { display: none }` means a detached-but-retained surface must contribute
_no_ hit-list entries rather than a transparent full-surface one; and
`_updateStackingOrder`'s re-append means "raise to front" has to be an explicit
operation on the surface list, because attach order and paint order drift once
surfaces are detached and re-attached. The top-layer path has no software
equivalent on a single-surface target — but CDK is evidence that the API survives
the difference: `usePopover` is one boolean in the config and no position-strategy
interface changed except one optional method. Because a display list supplies
neither DOM containment nor injector ancestry, INFERENCE: a sparkles registry
entry would have to carry an explicit parent link where CDK gets ancestry from
the host. See [`./proposal.md`](./proposal.md) and
[`../../specs/ui/containers.md`](../../specs/ui/containers.md).

### 11. Modality

The overlay's entire [modality][concepts] surface is `hasBackdrop: boolean`
(`overlay-config.ts:25`) plus `backdropClass`. A backdrop is a plain sibling
`div` (`position: absolute; inset: 0; pointer-events: auto; opacity: 0`,
`_index.scss:87-104`) inserted _before_ the host so stacked overlays interleave
correctly — except in popover mode, where it must be prepended _inside_ the
popover host (`overlay-ref.ts:455-478`), because a sibling would not be in the top
layer. It fades in via a class added on a later frame and fades out by listening
for `transitionend` with a 500 ms fallback (`backdrop-ref.ts:29-42`).

One detail is a small classic:

```scss
// src/cdk/overlay/_index.scss:130-134
.cdk-overlay-transparent-backdrop {
  // Define a transition on the visibility so that the `transitionend` event can fire immediately.
  transition:
    visibility 1ms linear,
    opacity 1ms linear;
  visibility: hidden;
  opacity: 1;
}
```

A fully transparent element with no transition never fires `transitionend`, so
the 1 ms transition exists purely to guarantee the completion event the teardown
path waits for. There is also a `forced-colors: active` fallback that drops to
`opacity: 0.6` (`:117-121`) because `rgba` goes solid in high contrast.

Absent from the primitive: no `aria-modal`, no inertness, no keyboard blocking,
no focus containment, no scrim semantics beyond a colour. Real modality is
`cdk/dialog`'s job: it walks the overlay container's siblings and sets
`aria-hidden="true"` on each, recording the prior value in a `Map`
(`dialog.ts:394-412`) and restoring only when the last dialog closes (`:376-384`).

The consequence is worth stating plainly, because it is the design's own
statement about the two concepts: **light dismiss and modality are orthogonal
here.** The outside-click dispatcher walks the whole stack regardless of
backdrops, so a "modal" overlay does not stop a lower overlay from receiving
outside-click notifications; only the backdrop's physical pointer capture does,
and only for pointers. Keys stop at the first willing overlay by recency — a
different rule over the same stack.

**Algorithm.**

```text
hideNonDialogContentFromAT(overlayContainer):
    for sibling in overlayContainer.parentElement.children:
        if sibling is not overlayContainer and not a live region and not script/style:
            ariaHiddenElements.set(sibling, sibling.getAttribute('aria-hidden'))
            sibling.setAttribute('aria-hidden', 'true')
    // on the LAST close: restore each recorded value, or removeAttribute when it was null
```

**Where it lives.** Backdrop in `cdk/overlay` (`backdrop-ref.ts`, `_index.scss`);
accessibility modality in `cdk/dialog/dialog.ts`; focus containment in
`cdk/a11y`. Three packages for one user-visible concept.

**Degradation.** On one surface with no compositor a scrim is a fill rect painted
before the panel — which is exactly what `.cdk-overlay-backdrop` is. Pointer
blocking becomes "the scrim contributes a full-surface hit-list entry that
swallows events", which suits reverse-paint-order hit testing and is simpler than
CSS `pointer-events`. On a cell target there is no alpha over glyphs, so a dim
scrim has to be an attribute change rather than a translucent layer — CDK's
`forced-colors` fallback is the same class of problem and the same class of
answer. On static HTML a backdrop can be a sibling element under `:checked` and
`aria-hidden` on siblings is emittable, but nothing can toggle it, so tier-0
modality means "the page _is_ the dialog". The transferable warning is CDK's own
split: do not conflate light dismiss with modality; they are different rules over
the same stack.

### 12. Adaptive presentation

The overlay primitive adapts to nothing: `OverlayConfig` has no breakpoint,
pointer-type or compact-size fields. The only adaptive presentation in the stack
is `MatTooltip`'s hover→long-press swap, and the way it is _factored_ is the
finding:

```ts
// src/material/tooltip/tooltip.ts:865-881
private _isTouchPlatform(): boolean {
  const detectHoverCapability = this._defaultOptions?.detectHoverCapability;

  if (typeof detectHoverCapability === 'function') {
    return !detectHoverCapability();
  }

  if (this._platform.IOS || this._platform.ANDROID) {
    // If we detected iOS or Android, it's definitely supported.
    return true;
  } else if (!this._platform.isBrowser) {
    // If it's not a browser, it's definitely not supported.
    return false;
  }

  return !!detectHoverCapability && this._mediaMatcher.matchMedia('(any-hover: none)').matches;
}
```

Three tiers, in order: an injectable override the _app_ supplies; a definite
platform answer; and only then the media query — and the media query is consulted
only if the app opted in by providing `detectHoverCapability` at all. The same
field does double duty as an override function and as an opt-in flag.

The chosen branch then selects an entire listener set once at `ngAfterViewInit`
and additionally disables native gestures (`_disableNativeGesturesIfNecessary`,
`:884-910`) with two carve-outs under `touchGestures: 'auto'`: never disable
selection on `INPUT`/`TEXTAREA` (it breaks iOS typing), and never disable drag on
draggable elements. There is no popover→sheet transformation, no teaching-tip
variant and no keyboard-driven relocation.

**Where it lives.** The component (`material/tooltip`), never the primitive — but
the _capability_ it consults comes from a shared service (`cdk/platform`) and a
shared injection token. Capability is app-owned; policy is component-owned.

**Degradation.** That layering is the transferable part: capability should come
from below (the backend) and policy should live in the component, with the
application able to override the probe. Applied to a cell toolkit, "hover served
or absent" and "key release present or absent" belong on a backend capability
struct the view can read, not on something a widget sniffs. Android forces the
largest adaptation — no hover at all, plus the soft-keyboard inset as an explicit
boundary input. The TUI forces the second — no key release, so any
press-duration keyboard adaptation is unimplementable and must be replaced by a
distinct key. Static HTML forces the third — the adaptation has to be chosen at
_emit_ time and baked in, so the emitter needs the target's capability struct as
an input too. See [`../platform-ui-guidelines/index.md`](../platform-ui-guidelines/index.md)
and [`../../specs/ui/backends.md`](../../specs/ui/backends.md).

### 13. Accessibility

`cdk/overlay` emits exactly one attribute of its own: `dir` on the host. No role,
no `aria-*`, no live region, no labelling. Semantics belong to the component, and
Angular has taken that to its logical end with `src/aria/` (accordion, combobox,
grid, listbox, menu, tabs, toolbar, tree), whose behaviour patterns import no
overlay code: `ngCombobox` manages `aria-expanded`, `aria-controls` and
`aria-haspopup` (`aria/combobox/combobox.ts:67-70`) and knows nothing about where
the popup is drawn. Positioning and semantics are two independently testable
libraries.

The tooltip case is the most instructive and the most counter-intuitive: the
_rendered_ Material tooltip has `aria-hidden="true"` on its host and no
`role="tooltip"`. The accessible text is a second, duplicated element created by
`AriaDescriber._createMessageElement` (`aria-describer.ts:143-155`) inside a
global container, referenced from the trigger's `aria-describedby` and ref-counted
per (message, role) pair. The container's hiding technique is chosen deliberately:

```ts
// src/cdk/a11y/aria-describer/aria-describer.ts:184-192
// We add `visibility: hidden` in order to prevent text in this container from
// being searchable by the browser's Ctrl + F functionality.
// Screen-readers will still read the description for elements with aria-describedby even
// when the description element is not visible.
messagesContainer.style.visibility = 'hidden';
// Even though we use `visibility: hidden`, we still apply `cdk-visually-hidden` so that
// the description element doesn't impact page layout.
messagesContainer.classList.add(containerClassName);
messagesContainer.classList.add('cdk-visually-hidden');
```

Rendering and semantics therefore never entangle: they are two trees, and the
accessible one is _derived_. Tooltip content is by construction never
interactive.

WCAG 1.4.13 (hoverable / dismissible / persistent) is partially met: dismissible
via Escape — routed through the per-overlay `eventPredicate`, which for the
tooltip accepts `keydown` only when the tooltip is visible, the key is Escape and
no modifier is held (`tooltip.ts:942-951`) — and hoverable via the
`relatedTarget` checks. Persistence has no maximum duration and no explicit
guarantee.

**Where it lives.** `cdk/a11y` (`AriaDescriber`, `FocusMonitor`,
`InputModalityDetector`, `LiveAnnouncer`), `src/aria/*` (behaviour patterns), the
individual components. Nothing in `cdk/overlay`.

**Degradation.** By CDK's own factoring, what belongs to the primitive is the
surface's _kind_ (tooltip / listbox / menu / dialog) as a value, because it
determines dismissal, focus and layering rules — not ARIA strings and not the
semantic tree. The shape to steal is that the accessible representation is a
separate derived tree, exactly as `AriaDescriber` makes it a separate hidden
element. A canvas toolkit has no accessibility tree on its GUI, TUI or recording
targets; on an HTML target that derived tree is real output and must carry
`role`/`aria-describedby`. Because it is derived rather than embedded, it can
simply not be emitted where nothing consumes it — which is only possible if it
was never entangled with paint. See [`./aria-apg.md`](./aria-apg.md).

### 14. Animation

CDK emits geometry metadata specifically to enable animation, and gates the
expensive part on there being a listener. `positionChanges` carries a
`ConnectedOverlayPositionChange` (`connected-position.ts:91`) with the chosen
`ConnectionPositionPair` and a `ScrollingVisibility` (`:83`); `_applyPosition`
computes the scroll visibility — four rect reads over the registered scrollables
— only when someone is subscribed, and re-emits only on change:

```ts
// src/cdk/overlay/position/flexible-connected-position-strategy.ts:780-792
// Notify that the position has been changed along with its change properties.
// We only emit if we've got any subscriptions, because the scroll visibility
// calculations can be somewhat expensive.
if (this._positionChanges.observers.length) {
  const scrollVisibility = this._getScrollVisibility();

  // We're recalculating on scroll, but we only want to emit if anything
  // changed since downstream code might be hitting the `NgZone`.
  if (
    position !== this._lastPosition ||
    !this._lastScrollVisibility ||
    !compareScrollVisibility(this._lastScrollVisibility, scrollVisibility)
  ) {
```

`CdkConnectedOverlay` mirrors the same discipline, subscribing only when
`positionChange.observers.length > 0` and using `takeWhile` to unsubscribe when
the last listener leaves (`overlay-directives.ts:497-506`).

The metadata is **symbolic** (which connection pair won), never numeric — no
offsets, no arrow centre. Placement-aware [`transform-origin`][concepts] is the
separate, more direct channel described in dimension 4.

Enter and exit are CSS/class-driven. `TooltipComponent._toggleVisibility`
(`:1143`) swaps show/hide classes directly on the element, deliberately bypassing
change detection so a detached view can still be hidden, and completion is
detected by `animationend` _filtered on the animation name_ (`_handleAnimationEnd`,
`:1114-1118`). Two defensive details: the tooltip reads `getComputedStyle` and
self-disables its animation logic when it finds `animation-duration: 0s` or
`animation-name: none` (`:1159-1176`), which defeats an app-wide
`* { animation: none !important }`; and the detach path waits for content to
leave the DOM via a `MutationObserver` plus `afterNextRender`
(`overlay-ref.ts:523-545`), so an animating-out component is not ripped out
early. Repositioning during an animation is simply allowed. Reduced motion
appears once, in SCSS: `@media (prefers-reduced-motion)` shortens the backdrop
transition (`_index.scss:106-109`).

**Algorithm.**

```text
applyPosition(pos, originPoint):
    setTransformOrigin(pos)
    setOverlayElementStyles(originPoint, pos); setBoundingBoxStyles(originPoint, pos)
    if pos.panelClass: addPanelClasses(pos.panelClass)
    if positionChanges.observers.length > 0:          // LAZY: the metadata costs 4 rect reads
        vis = getScrollVisibility()
        if pos !== lastPosition or !lastVis or !equal(lastVis, vis):
            positionChanges.next(ConnectedOverlayPositionChange(pos, vis))
        lastVis = vis
    lastPosition = pos; isInitialRender = false
```

**Where it lives.** Library (`_applyPosition`, `withTransformOriginOn`) for the
metadata; CSS/SCSS and the component for the actual motion; `MutationObserver` +
`afterNextRender` for exit sequencing.

**Degradation.** The lazy-metadata pattern matters _more_ in an allocation-averse
toolkit than in JavaScript: "compute the expensive derived geometry only if
someone will consume it" becomes "fill the optional fields of the placement
result only when the view asked for them". The symbolic side/align pair survives
everywhere and is what a cell toolkit actually needs, since a transform origin
has no meaning but "which edge did we attach to" selects the reveal direction and
the arrow glyph. On a cell target there is no transform, scale or shadow, so an
enter animation is at most a per-frame reveal over N cells or an attribute ramp,
and the `animationend` completion signal becomes "frame counter reached N" —
which a recording canvas can assert exactly, precisely because CDK tied
completion to a _named event_ rather than to a duration constant. On static HTML
there are no timers and `transitionend` cannot be observed, so any behaviour
gated on "presentation finished" (dimension 6's `_closeOnInteraction`) needs a
non-animation fallback.

### 15. State architecture

Imperative controllers plus RxJS `Subject`s. No reducers, no finite state
machine, no signals in the overlay itself — though `src/aria/` is signal-based,
which is the direction of travel.

`OverlayRef` is a mutable handle owning five event `Subject`s plus subscriptions
and a `_disposed` flag, with a three-state lifecycle enforced by early returns
rather than by an enum: created → attached → detached → (attached | disposed).
Attachment is not stored — `hasAttached()` delegates to the portal outlet
(`overlay-ref.ts:290-292`), so the state is _derived from the DOM_.

`OverlayConfig` is nominally immutable but is mutated in place by `updateSize`
(`:350`) and directly by consumers: the shipped directive writes
`ref.getConfig().hasBackdrop = this.hasBackdrop` (`overlay-directives.ts:478`).
The immutability is a type-level fiction.

`FlexibleConnectedPositionStrategy` is a stateful builder with fluent `withX()`
methods — and, critically, **six pieces of hidden inter-frame memo state** that
make `apply()` non-pure: `_isInitialRender` (`:84`), `_isPushed`, `_lastPosition`
(`:141`), `_lastBoundingBoxSize`, `_previousPushAmount` (`:165`) and
`_lastScrollVisibility`. They exist to stop the overlay jittering:

- the bounding box may shrink but never _grow_ after open unless `growAfterOpen`
  is set, and in the vertically centred case the box is re-anchored from the
  _previous_ half-height so it does not visibly re-centre (`:857-869`);
- a locked position reuses its recorded push vector instead of re-pushing
  (`:713-721`), so a scrolled overlay drifts with the page instead of sticking to
  the viewport edge;
- a window resize forcibly sets `_isInitialRender = true` before re-applying
  (`:206-215`), deliberately overriding position locking so a shrunken viewport
  gets a fresh best fit.

Note what this state is _not_: the requested positions and the resolved one stay
in separate fields (`_preferredPositions` at `:123`, `_lastPosition` at `:141`),
so the request is never overwritten by the resolution.

`CdkConnectedOverlay` is controlled by its `open` input but writes back to it
(`this.open = true` at the end of `attachOverlay`, `overlay-directives.ts:509`) —
a two-way leak.

**Algorithm.** No state machine exists. Reconstructed, the de-facto machines are:

```text
OverlayRef:  Created -> Attached -> Detached -> (Attached | Disposed)
             'Attached' is not stored; hasAttached() asks the portal outlet.

Strategy:    Fresh -> InitialRender -> Settled(lastPosition, lastBoxSize, pushAmount)
             a resize event forcibly resets Settled -> InitialRender.
```

**Where it lives.** `OverlayRef` plus each strategy object. There is no central
store and no single place where "the state of all overlays" can be inspected —
except the two dispatchers' `_attachedOverlays` arrays, which are `public` for
roughly that reason.

**Degradation.** The geometry core survives a value-semantics, allocation-free,
non-DOM port completely: integer arithmetic over rects, no allocation, no
exceptions. The lifecycle does not survive at all — DI services, `Subject`s,
closures, `MutationObserver`, `afterNextRender`, `NgZone`. The precise lesson is
the six memo fields: they are exactly the state a value-semantics toolkit must
promote into an _explicit input_, so that
`place(anchor, overlaySize, boundary, positions, prev) -> Placement` with
`prev = {lastPosition, lastBoxSize, pushAmount, isInitial}` is pure and directly
assertable. CDK's `apply()` can only be tested by attaching a real overlay;
that is the cost of hiding the memo. The `hasAttached()`-derives-from-the-DOM
trick must also be inverted: where the surface list _is_ the state, attachment is
a stored value and the display list is derived from it.

### 16. Shared infrastructure

The factoring is four layers with sharp edges:

| Layer | Package       | Contents                                                                                                                                            |
| ----- | ------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| L1    | `cdk/portal`  | Content teleport. Knows nothing about position.                                                                                                     |
| L2    | `cdk/overlay` | Host+pane pair, `OverlayConfig` value, `PositionStrategy`, `ScrollStrategy`, `OverlayContainer`, two dispatchers, backdrop, direction.              |
| L3    | `cdk/a11y`    | `FocusTrap`, `FocusMonitor`, `InputModalityDetector`, `AriaDescriber`, `LiveAnnouncer` — cross-cutting, used by every surface kind.                 |
| L4    | surface kinds | `cdk/menu` (`MenuStack`, `MenuAim`, `PointerFocusTracker`, typeahead), `cdk/dialog`, `cdk/listbox`, `material/*`, and the overlay-free `src/aria/`. |

Two facts show the L2 boundary is real rather than aspirational: `src/aria/`'s
combobox, menu and listbox implementations contain no overlay import; and
`cdk/dialog` drives a _completely different_ position strategy through the same
`OverlayRef` —
`createGlobalPositionStrategy(this._injector).centerHorizontally().centerVertically()`
(`dialog.ts:210`) — proving the surface lifecycle is independent of the placement
algorithm.

The two interfaces that carry the design are tiny, and they are values handed in
as config rather than base classes to inherit:

```ts
// src/cdk/overlay/position/position-strategy.ts:12 and scroll/scroll-strategy.ts:14
interface PositionStrategy {
  attach(overlayRef: OverlayRef): void;
  apply(): void;
  detach?(): void;
  dispose(): void;
  getPopoverInsertionPoint?():
    | Element
    | null
    | { type: 'parent'; element: Element };
}

interface ScrollStrategy {
  enable: () => void;
  disable: () => void;
  attach: (overlayRef: OverlayRef) => void;
  detach?: () => void;
}
```

Both are constructed by free functions (`createFlexibleConnectedPositionStrategy`,
`createGlobalPositionStrategy`, `createCloseScrollStrategy`, …) and swapping
either at runtime is a single call (`updatePositionStrategy` /
`updateScrollStrategy`, `overlay-ref.ts:332`, `:389`) that disposes the old one
and re-attaches. Nothing subclasses `OverlayRef`; there is one concrete class.

What this repository's own boundaries say **must stay apart**, with the scars to
prove each: menu-aim (menu-only, opt-in through a separate directive, meaningless
for a tooltip or select); the overlay _tree_ (`MenuStack` is a `cdk/menu` type
resolved through DI ancestry, never a field on `OverlayRef` — the overlay layer
keeps a flat array); focus policy (the dialog's five-way `autoFocus`, the menu's
`FocusNext` intent and the tooltip's never-focus are irreconcilable); show/hide
delays (tooltip-only — a menu with a 200 ms show delay is a bug); flexible
dimensions (a select or autocomplete wants a scrollable panel; the tooltip
explicitly calls `withFlexibleDimensions(false)`, `tooltip.ts:522`); backdrop and
scroll blocking (dialog-only in practice); and ARIA roles and expanded/controls
wiring (now an entirely separate package).

**Where it lives.** Spread over `cdk/portal`, `cdk/overlay`, `cdk/a11y`,
`cdk/menu`, `cdk/dialog`, `src/aria`, `material/*` — deliberately, with the
dependency arrows pointing one way: surface kinds → overlay → portal, and surface
kinds → a11y.

**Degradation.** None of these boundaries depend on the DOM; they are
dependency-direction decisions and they survive the port. Two are worth adopting
as-is. **Scroll/viewport policy as a value**: `{noop, close, reposition, block}`
is a two-bit enum with a small payload, evaluated by the frame loop, turning
"what happens when the world moves under an open surface" from ad-hoc per-widget
code into one comparable field. **Position strategy as a value**:
connected-to-anchor and global-in-surface are genuinely different algorithms
sharing one surface lifecycle, and a toolkit needs both (a dropdown, a centred
modal, a toast) — CDK shows they can share everything except one `apply()`. The
boundary to draw _differently_ is the arrow: CDK keeps it out of the primitive
because CSS can draw it, whereas a cell toolkit must paint it, so the resolved
side and the arrow's cell have to be part of the placement result.

## Strengths

- **The measure/decide split is explicit and enforced by comment.** Four rect
  reads up front, then a pure arithmetic loop over N candidates. That is why
  scoring four candidate positions costs roughly what scoring one costs.
- **Visible area as the fallback objective.** Unlike "flip to the opposite side"
  or "shift until it fits", maximising visible area is a single monotone
  objective, so it does not oscillate between two positions across frames, and it
  degrades gracefully when nothing fits. In cells it is one integer multiply.
- **`weight` as an author-supplied multiplicative bias on the area score** — "prefer
  below even if right has more room" without reordering the list or writing a
  custom strategy.
- **The dispatcher pattern with a per-overlay `eventPredicate`.** One listener per
  event type for the whole application, a flat stack, a top-down walk, and each
  overlay declares which events it wants, so a non-participating surface is
  transparent rather than a blocker.
- **Two-sample outside-click** (press target _and_ release target must both be
  outside), with all four down/up combinations covered by tests.
- **Scroll response as a value**: four small implementations behind a three-method
  interface, swappable at runtime, with an identical surface lifecycle for all
  four.
- **The anti-jitter memo**: the bounding box may shrink but never grow after open;
  a locked position reuses its push vector; a window resize deliberately
  overrides locking. Those three rules are the difference between a dropdown that
  sits still and one that breathes.
- **Placement is reported back as data**, lazily, so the styling and animation
  layer can react to which side won without the geometry layer knowing anything
  about animation.
- **`getRoundedBoundingClientRect` floors all six fields** to defeat sub-pixel
  zoom deviation, with a dedicated spec that perturbs `getBoundingClientRect` by
  0.1 px.
- **Accessibility is a separate derived tree**: the visible tooltip is
  `aria-hidden`, and a ref-counted duplicate `role="tooltip"` element lives in a
  global `visibility: hidden` container — `visibility` specifically so browser
  find-in-page does not hit it.
- **Focus intent travels as data on the close event** (`FocusNext`,
  `focusParentTrigger`) rather than as a side effect at the close site.
- **`MenuStack.hasFocus` uses `debounceTime(0)` + `distinctUntilChanged`** — the
  correct, non-obvious fix for "focusout immediately followed by focusin within
  the same stack must not read as focus loss".
- **`_closeOnInteraction` gates light dismiss on the enter animation finishing**
  rather than on a millisecond guard.
- **The placement cascade is unit-tested at scale** — a 3080-line spec against
  hand-positioned elements, covering exactly-viewport-sized overlays, RTL,
  per-side viewport margins, Safari zoom and a simulated virtual keyboard.

## Weaknesses

- **No clipping-ancestor discovery.** The caller must supply registered
  `CdkScrollable` directives; arbitrary `overflow: hidden` ancestors are
  invisible; and those containers never influence placement at all — they feed
  four report-only booleans. A dropdown inside a scrolling pane is positioned as
  if the pane did not exist.
- **No content or anchor resize tracking.** Exactly one automatic reposition
  happens, via `afterNextRender` at attach. No `ResizeObserver` anywhere, and
  `scroll-clip.ts:10` still carries a TODO to someday use `IntersectionObserver`.
- **`apply()` is not a pure function.** Six hidden inter-frame memo fields mean
  the result depends on history in a way the signature does not reveal, and it can
  only be tested by attaching a real overlay.
- **Position locking compares positions by reference.** `withPositions` clears
  `_lastPosition` when `positions.indexOf(this._lastPosition) === -1` (`:428-436`),
  and `CdkConnectedOverlay._updatePositionStrategy` rebuilds the array on every
  `ngOnChanges` — so a consumer that reconstructs its position objects silently
  loses its lock, and the two behaviours ship in the same package.
- **Viewport margins are applied asymmetrically in the fit test** (INFERENCE, read
  from control flow, not test-confirmed): `_getOverlayFit` uses a literal `0` for
  the leading bounds while the trailing bounds already have both margins
  subtracted.
- **Logical viewport margins are mapped to physical edges without an RTL check**
  (INFERENCE, read from control flow, not test-confirmed) in
  `_getNarrowedViewportRect`, unlike every other use of `start`/`end` in the file.
- **No arrow concept at all.** The primitive tells the styling layer only which
  connection pair won, as a class name and a `transform-origin` string. A toolkit
  that must _paint_ the arrow gets nothing usable.
- **`OverlayConfig`'s immutability is a type-level fiction** — mutated internally
  by `updateSize` and externally by the shipped directive.
- **Modality is spread across three packages** and is not a property of the
  overlay. Nothing prevents a "modal" overlay from letting the overlay beneath it
  receive outside-click notifications.
- **No shared tooltip infrastructure**: no singleton instance, no warm-up/cool-down
  group, no skip-delay when traversing a toolbar. Every trigger pays the show
  delay again and owns its own overlay.
- **Menu-aim divides.** `getSlope` produces `Infinity` for purely vertical pointer
  motion and `NaN` for a repeated sample, so the four edge tests behave
  unpredictably in exactly the common case of moving straight down a menu. A
  cross-product formulation has no such degeneracy.
- **Two independent stacks exist** — the dispatchers' flat `OverlayRef[]` and
  `cdk/menu`'s `MenuStack` — and they can disagree, which is why the context-menu
  trigger must ask `isElementInsideMenuStack(target)` (`context-menu-trigger.ts:198`)
  before choosing between `closeAll()` and closing only siblings.
- **Four trigger implementations in one repository**, disagreeing on modality
  gating, on whether hover opens or only switches, and on where Escape is handled.
- **The popover/legacy dual mode branches in at least six places** — backdrop
  insertion (sibling vs prepended child), stacking fixups (needed vs skipped), DOM
  insertion point, an `inset: auto` workaround for Chrome's UA style
  (`_index.scss:205-207`), a `::backdrop { display: none }` override (`:213-216`),
  and a temporary `display: block` poke in `_getContainerRect` (`:1302-1323`) so
  an empty container can still be measured for the Safari-zoom correction — so
  "the public API did not change" conceals real behavioural divergence.

## Key design decisions and trade-offs

| Decision                                                                                                                                                                                                             | Rationale                                                                                                                                                                                                                                                                                                                                                                            | Trade-off                                                                                                                                                                                                                                                                                                                                                                 |
| -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Placement is an ordered list of author-supplied connection-point **pairs**, scored by visible area — not a side + alignment with automatic flip/shift.                                                               | A 3×3-to-3×3 pair expresses 81 placements, including ones flip/shift cannot reach, and "first that fits, else greatest visible area" is a single monotone objective that never oscillates. Fallback _order_ encodes designer intent, which an automatic flip cannot know.                                                                                                            | Verbose: every consumer ships a 2–4 entry array, and the package had to export `STANDARD_DROPDOWN_BELOW_POSITIONS` / `…ADJACENT_POSITIONS` as canned constants. The list is also compared by reference for position locking, so a consumer that rebuilds it each change-detection pass silently loses the lock — and the shipped `CdkConnectedOverlay` does exactly that. |
| Scroll/viewport response is a first-class **strategy value** in the config (`{noop, close, reposition, block}`), swappable at runtime.                                                                               | "What happens when the world moves under an open surface" genuinely differs per surface kind — a tooltip should vanish, a dropdown should follow, a dialog should freeze the page — so making it a value keeps one lifecycle for all four and makes each policy separately testable. The interface is three methods and all four implementations total 359 lines.                    | Strategies are stateful objects that cannot be shared between overlays — `BlockScrollStrategy` has to coordinate through a global CSS class precisely because it cannot be a singleton — and a mis-scoped factory produces "Scroll strategy has already been attached". `noop` being the default also means the out-of-the-box overlay does nothing on scroll.            |
| Document-level routing is centralised in two dispatchers over a **flat** stack, with different termination rules for keys (first willing receiver, stop) and pointers (notify everything above the hit, stop there). | Routing by stack recency rather than by event target is the only thing that works when the focused element lives outside the overlay — select and autocomplete keep focus on the trigger. A flat array makes the whole open-surface set inspectable and closable in one place, at O(n) per event and one listener per event type for the entire application.                         | The overlay layer therefore has no notion of an overlay _tree_: parent/child, submenu ownership and "close my descendants" all had to be re-invented in `cdk/menu` as `MenuStack`, resolved through DI ancestry. Two independent stacks can and do disagree.                                                                                                              |
| The primitive owns geometry and layering, and owns **nothing** of triggers, timing, focus, ARIA or arrows.                                                                                                           | Those five concerns differ irreconcilably between tooltip, menu, select, dialog and toast; forcing them into one configurable object yields a config with mutually exclusive fields. The evidence this was right: `cdk/dialog` drives a different position strategy through the same `OverlayRef`, and `src/aria` implements combobox/menu/listbox semantics with no overlay import. | Every consumer re-implements triggers and delays. This repository alone carries four independent trigger implementations that disagree on modality gating, on whether hover opens or only switches, and on where Escape is handled. A toolkit with fewer consumers cannot absorb that duplication.                                                                        |
| Expensive derived metadata (`ScrollingVisibility`) is computed only when someone is subscribed, and re-emitted only on change.                                                                                       | It costs a `getBoundingClientRect` per registered scrollable per reposition, and reposition runs on every audited scroll frame. Gating on `observers.length` makes the common case free, and `compareScrollVisibility` avoids waking change detection for identical values.                                                                                                          | The cost is invisible in the type system: `positionChanges` looks like an ordinary observable but silently does more work once subscribed, and `CdkConnectedOverlay` had to mirror the gate with `takeWhile` so unsubscribing actually stops the work. A result struct with optional fields and an explicit "compute these" request would make the same trade legible.    |
| The browser top layer (`popover="manual"` + `showPopover()`) became the default in v22, with the container `div` as fallback, and the public API did not change.                                                     | Z-index conflicts, clipping-ancestor escapes and stacking-context bugs are all solved by the platform; feature detection is one `in` check and the escape hatch is one injection token plus one config boolean.                                                                                                                                                                      | The two modes are not behaviourally identical, and the code now branches in at least six places (backdrop insertion, stacking fixups, insertion point, an `inset: auto` UA-stylesheet workaround, a `::backdrop` override, and a `display: block` poke to measure an empty container).                                                                                    |

## Sources

Primary sources, all at the pinned revision:

- [`src/cdk/overlay/position/flexible-connected-position-strategy.ts`][fcps] — the
  placement engine: the four-tier cascade doc comment (`:222-229`), `apply()`
  (`:232-343`), `_getOriginPoint` (`:557`), `_getOverlayPoint` (`:602`),
  `_getOverlayFit` (`:633`), `_pushOverlayOnScreen` (`:708`), `_applyPosition`
  (`:771`), `_setTransformOrigin` (`:806`), `_calculateBoundingBoxRect` (`:836`),
  `_getScrollVisibility` (`:1129`), `_getNarrowedViewportRect` (`:1157`),
  `_getOriginRect` (`:1275`), `ConnectedPosition` (`:1374`),
  `getRoundedBoundingClientRect` (`:1420`), the canned position lists (`:1445`,
  `:1452`), and the six memo fields (`:84`, `:141`, `:165`).
- [`…/flexible-connected-position-strategy.spec.ts`][fcps-spec] — 3080 lines
  pinning the cascade: exactly-viewport-sized overlays (`:131`, `:166`),
  sub-pixel deviation (`:832`), the virtual-keyboard offset (`:2145`), simulated
  Safari zoom (`:2173`), and a point anchor with width and height (`:2460`).
- [`src/cdk/overlay/dispatchers/base-overlay-dispatcher.ts`][base-disp],
  [`overlay-keyboard-dispatcher.ts`][kbd-disp] and
  [`overlay-outside-click-dispatcher.ts`][click-disp] — the flat stack,
  `canReceiveEvent`, the two termination rules, the two-sample outside-click
  predicate and the iOS cursor workaround; the four down/up cases are pinned in
  [`overlay-outside-click-dispatcher.spec.ts`][click-spec] (`:191`, `:213`,
  `:232`, `:254`) and the mid-loop-detach case at `:307`.
- [`src/cdk/overlay/overlay.ts`][overlay-ts] — `createOverlayRef`, the
  `showPopover` feature test and `defaultUsePopover`.
- [`src/cdk/overlay/overlay-ref.ts`][overlay-ref] — the lifecycle handle,
  `_attachHost`/`showPopover`, `_updateStackingOrder`, the single
  `afterNextRender(updatePosition)`, and `_detachContentWhenEmpty`.
- [`src/cdk/overlay/overlay-config.ts`][overlay-config] — the whole configurable
  surface, including `eventPredicate` (`:74`) and `usePopover` (`:68`).
- [`src/cdk/overlay/overlay-directives.ts`][directives] — `CdkConnectedOverlay`:
  the controlled `open` input, the Escape check with `hasModifierKey`, and the
  mirrored `positionChange` subscription gate.
- [`src/cdk/overlay/position/position-strategy.ts`][pos-strategy] and
  [`scroll/scroll-strategy.ts`][scroll-strategy] — the two interfaces that carry
  the design; [`scroll/scroll-strategy-options.ts`][scroll-opts] and the four
  implementations ([`noop`][noop-ss], [`close`][close-ss], [`block`][block-ss],
  [`reposition`][repos-ss]).
- [`src/cdk/overlay/position/scroll-clip.ts`][scroll-clip] — the
  `IntersectionObserver` TODO and the report-only clipping predicates;
  [`src/cdk/scrolling/scroll-dispatcher.ts`][scroll-dispatcher] and
  [`viewport-ruler.ts`][viewport-ruler] for the 20 ms audit windows.
- [`src/cdk/overlay/_index.scss`][scss] — the container, the `:empty` rule, the
  pane's `pointer-events: auto`, the backdrop, the 1 ms transparent-backdrop
  transition, the forced-colors fallback and the popover overrides;
  [`backdrop-ref.ts`][backdrop-ref] for the `transitionend` + 500 ms fallback.
- [`src/cdk/menu/menu-aim.ts`][menu-aim] — the trajectory-consensus predictor and
  its constants; [`menu-stack.ts`][menu-stack] — `FocusNext`, `CloseOptions`, the
  DI-resolved stack and the `debounceTime(0)` focus stream;
  [`menu-trigger.ts`][menu-trigger] and
  [`context-menu-trigger.ts`][ctx-trigger] — the trigger guard chains.
- [`src/material/tooltip/tooltip.ts`][tooltip] — the only timing model, the
  three-tier hover-capability probe, the lazy exit listeners, the `wheel`
  workaround, `_overlayEventPredicate`, and the animation-completion gate;
  [`tooltip.html`][tooltip-html] shows there is no caret element.
- [`src/cdk/a11y/aria-describer/aria-describer.ts`][aria-describer] — the
  ref-counted duplicate description element and the `visibility: hidden` rationale.
- [`src/cdk/dialog/dialog.ts`][dialog] and
  [`dialog-container.ts`][dialog-container] — the global position strategy on the
  same `OverlayRef`, sibling `aria-hidden` bookkeeping, the five-way `autoFocus`
  policy, and the guarded `focusVia` restore.
- [`src/aria/combobox/combobox.ts`][aria-combobox] — semantics with no overlay
  dependency.

Related pages in this catalog: [`./index.md`](./index.md),
[`./concepts.md`][concepts], [`./comparison.md`](./comparison.md),
[`./features-people-forget.md`](./features-people-forget.md),
[`./sparkles-baseline.md`](./sparkles-baseline.md),
[`./proposal.md`](./proposal.md). Nearest neighbours by mechanism:
[`./floating-ui.md`](./floating-ui.md) (the flip/shift middleware model this
subject deliberately does not have), [`./radix.md`](./radix.md) and
[`./base-ui.md`](./base-ui.md) (headless overlay managers on a single document),
[`./react-aria.md`](./react-aria.md) (the tooltip warm-up machinery absent here),
[`./popover-api.md`](./popover-api.md) and [`./blink.md`](./blink.md) (the top
layer this subject now defaults to), [`./zag.md`](./zag.md) (the explicit
statechart alternative to imperative controllers), and
[`./xdg-positioner.md`](./xdg-positioner.md) (placement as a value solved out of
process). Adjacent research trees:
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

[repo]: https://github.com/angular/components
[repo-sha]: https://github.com/angular/components/tree/f3e6276c969f33e527b616ef8bf7b0404685721d
[overlay-md]: https://github.com/angular/components/blob/f3e6276c969f33e527b616ef8bf7b0404685721d/src/cdk/overlay/overlay.md
[fcps]: https://github.com/angular/components/blob/f3e6276c969f33e527b616ef8bf7b0404685721d/src/cdk/overlay/position/flexible-connected-position-strategy.ts
[fcps-spec]: https://github.com/angular/components/blob/f3e6276c969f33e527b616ef8bf7b0404685721d/src/cdk/overlay/position/flexible-connected-position-strategy.spec.ts
[base-disp]: https://github.com/angular/components/blob/f3e6276c969f33e527b616ef8bf7b0404685721d/src/cdk/overlay/dispatchers/base-overlay-dispatcher.ts
[kbd-disp]: https://github.com/angular/components/blob/f3e6276c969f33e527b616ef8bf7b0404685721d/src/cdk/overlay/dispatchers/overlay-keyboard-dispatcher.ts
[click-disp]: https://github.com/angular/components/blob/f3e6276c969f33e527b616ef8bf7b0404685721d/src/cdk/overlay/dispatchers/overlay-outside-click-dispatcher.ts
[click-spec]: https://github.com/angular/components/blob/f3e6276c969f33e527b616ef8bf7b0404685721d/src/cdk/overlay/dispatchers/overlay-outside-click-dispatcher.spec.ts
[overlay-ts]: https://github.com/angular/components/blob/f3e6276c969f33e527b616ef8bf7b0404685721d/src/cdk/overlay/overlay.ts
[overlay-ref]: https://github.com/angular/components/blob/f3e6276c969f33e527b616ef8bf7b0404685721d/src/cdk/overlay/overlay-ref.ts
[overlay-config]: https://github.com/angular/components/blob/f3e6276c969f33e527b616ef8bf7b0404685721d/src/cdk/overlay/overlay-config.ts
[directives]: https://github.com/angular/components/blob/f3e6276c969f33e527b616ef8bf7b0404685721d/src/cdk/overlay/overlay-directives.ts
[pos-strategy]: https://github.com/angular/components/blob/f3e6276c969f33e527b616ef8bf7b0404685721d/src/cdk/overlay/position/position-strategy.ts
[scroll-strategy]: https://github.com/angular/components/blob/f3e6276c969f33e527b616ef8bf7b0404685721d/src/cdk/overlay/scroll/scroll-strategy.ts
[scroll-opts]: https://github.com/angular/components/blob/f3e6276c969f33e527b616ef8bf7b0404685721d/src/cdk/overlay/scroll/scroll-strategy-options.ts
[noop-ss]: https://github.com/angular/components/blob/f3e6276c969f33e527b616ef8bf7b0404685721d/src/cdk/overlay/scroll/noop-scroll-strategy.ts
[close-ss]: https://github.com/angular/components/blob/f3e6276c969f33e527b616ef8bf7b0404685721d/src/cdk/overlay/scroll/close-scroll-strategy.ts
[block-ss]: https://github.com/angular/components/blob/f3e6276c969f33e527b616ef8bf7b0404685721d/src/cdk/overlay/scroll/block-scroll-strategy.ts
[repos-ss]: https://github.com/angular/components/blob/f3e6276c969f33e527b616ef8bf7b0404685721d/src/cdk/overlay/scroll/reposition-scroll-strategy.ts
[scroll-clip]: https://github.com/angular/components/blob/f3e6276c969f33e527b616ef8bf7b0404685721d/src/cdk/overlay/position/scroll-clip.ts
[scroll-dispatcher]: https://github.com/angular/components/blob/f3e6276c969f33e527b616ef8bf7b0404685721d/src/cdk/scrolling/scroll-dispatcher.ts
[viewport-ruler]: https://github.com/angular/components/blob/f3e6276c969f33e527b616ef8bf7b0404685721d/src/cdk/scrolling/viewport-ruler.ts
[scss]: https://github.com/angular/components/blob/f3e6276c969f33e527b616ef8bf7b0404685721d/src/cdk/overlay/_index.scss
[backdrop-ref]: https://github.com/angular/components/blob/f3e6276c969f33e527b616ef8bf7b0404685721d/src/cdk/overlay/backdrop-ref.ts
[menu-aim]: https://github.com/angular/components/blob/f3e6276c969f33e527b616ef8bf7b0404685721d/src/cdk/menu/menu-aim.ts
[menu-stack]: https://github.com/angular/components/blob/f3e6276c969f33e527b616ef8bf7b0404685721d/src/cdk/menu/menu-stack.ts
[menu-trigger]: https://github.com/angular/components/blob/f3e6276c969f33e527b616ef8bf7b0404685721d/src/cdk/menu/menu-trigger.ts
[ctx-trigger]: https://github.com/angular/components/blob/f3e6276c969f33e527b616ef8bf7b0404685721d/src/cdk/menu/context-menu-trigger.ts
[tooltip]: https://github.com/angular/components/blob/f3e6276c969f33e527b616ef8bf7b0404685721d/src/material/tooltip/tooltip.ts
[tooltip-html]: https://github.com/angular/components/blob/f3e6276c969f33e527b616ef8bf7b0404685721d/src/material/tooltip/tooltip.html
[aria-describer]: https://github.com/angular/components/blob/f3e6276c969f33e527b616ef8bf7b0404685721d/src/cdk/a11y/aria-describer/aria-describer.ts
[dialog]: https://github.com/angular/components/blob/f3e6276c969f33e527b616ef8bf7b0404685721d/src/cdk/dialog/dialog.ts
[dialog-container]: https://github.com/angular/components/blob/f3e6276c969f33e527b616ef8bf7b0404685721d/src/cdk/dialog/dialog-container.ts
[aria-combobox]: https://github.com/angular/components/blob/f3e6276c969f33e527b616ef8bf7b0404685721d/src/aria/combobox/combobox.ts
[concepts]: ./concepts.md
