# Floating UI (TypeScript / web)

A ~100-line pure geometry kernel that folds an ordered array of _middleware_ over a mutable
`(x, y, placement, rects, middlewareData)` tuple, with every environment contact pushed behind a
three-method `Platform` interface — and, in a separate and much larger React package, the
interaction layer (hover timing, safe polygons, dismissal, focus, roles) that the kernel refuses
to know about.

| Field             | Value                                                                                                                                                                                                                  |
| ----------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language          | TypeScript                                                                                                                                                                                                             |
| License           | MIT                                                                                                                                                                                                                    |
| Repository        | [`floating-ui/floating-ui`][fui-repo]                                                                                                                                                                                  |
| Documentation     | [floating-ui.com][fui-docs]                                                                                                                                                                                            |
| Category          | Web / headless positioning                                                                                                                                                                                             |
| Surface model     | in-canvas — `computePosition` emits coordinates and nothing else; the React layer portals into `document.body`. The native [top layer][concepts] is _detected_ (`isTopLayer`) but never entered by the library itself. |
| Packages read     | `@floating-ui/core` 1.8.0, `@floating-ui/dom` 1.8.0, `@floating-ui/utils` 0.2.12, `@floating-ui/react` 0.27.20, `@floating-ui/react-dom` 2.1.9, `@floating-ui/react-native` 0.10.10                                    |
| **Revision read** | `0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1`                                                                                                                                                                             |

This is an implementation reading of the source tree at that revision, not a docs summary; the
one documentation-derived claim in the page (the 1.8.0 `'layoutViewport'` rationale) is cited to
`packages/core/CHANGELOG.md` and flagged as such.

## Overview

### What it solves

Floating UI computes the position of one rectangle relative to another, subject to a clipping
boundary — and does so without knowing what either rectangle _is_. `packages/core` contains no
DOM identifier of any kind: `ReferenceElement` and `FloatingElement` are both declared as
`any` (`packages/core/src/types.ts:164-165`), and the reference is handed straight to
`platform.getElementRects` and never touched again. Everything downstream is arithmetic over two
`Rect` values plus a clipping `Rect`.

Around that kernel the project ships three separate answers to "what produces the rects":
`@floating-ui/dom` (browser measurement — scroll chains, iframes, CSS `zoom`, containing-block
rules), `@floating-ui/react-native` (a small `View.measure` wrapper, `createPlatform.ts:13`), and,
in the documentation site, a `<canvas>` demo whose entire platform is three inline functions —
one of which is the identity (`website/lib/components/Canvas.js:33`). That third one is
documentation code rather than a shipped package, so it evidences that three methods suffice; it
is not a maintained platform implementation.

The second product — `@floating-ui/react` — is unapologetically DOM- and React-shaped: hover
timing, dismissal, focus management, portals, a logical overlay tree, ARIA roles, delay grouping.
It shares none of the kernel's purity. The seam between them is the subject's most transferable
finding.

### Design philosophy

_Data over behaviour._ No middleware performs an effect. `arrow()` does not position an arrow, it
returns a number. `hide()` does not hide anything, it returns two booleans. `flip()` does not move
the element, it names a new [placement][concepts] and asks the runner to restart. The single
exception is `size()`, which calls a user `apply()` callback and then re-measures — and that
exception is precisely what forces the reset protocol to exist.

The whole recursion budget for that protocol is one integer, and the comment above it states the
purpose without qualification (`packages/core/src/computePosition.ts:10-11`):

```ts
// Maximum number of resets that can occur before bailing to avoid infinite reset loops.
const MAX_RESET_COUNT = 50;
```

The `detectOverflow` doc comment fixes the sign convention that unifies five middleware
(`packages/core/src/detectOverflow.ts:44-46`):

```ts
 * - positive = overflowing the boundary by that number of pixels
 * - negative = how many pixels left before it will overflow
 * - 0 = lies flush with the boundary
```

And a comment added at this revision states the library's position on inferring a viewport inset
from measurement rather than being told it (`packages/dom/src/utils/getViewportRect.ts:75-76`):

```ts
// Only a declared gutter reserves space; any other narrowing of the <html>
// box (a margin, a width, a transform) must not be treated as one.
```

> [!NOTE]
> The revision read is itself a fix for mis-measuring a reserved scrollbar gutter. The 1.8.0
> release that introduces the `'layoutViewport'` root boundary is the structural answer to the
> same class of bug: make the caller _name_ which viewport it means.

## How it works

`computePosition(reference, floating, options)` is 107 lines including comments and is the entire
kernel (`packages/core/src/computePosition.ts:20`). It measures both rects once, derives
coordinates from the requested placement, then iterates the middleware array threading a single
value-typed state through each:

```ts
// packages/core/src/computePosition.ts:70-97 (elided)
x = nextX ?? x;
y = nextY ?? y;

middlewareData[name] = { ...middlewareData[name], ...data }; // merged, never cleared

if (reset && resetCount < MAX_RESET_COUNT) {
  resetCount++;
  if (typeof reset === 'object') {
    if (reset.placement) statefulPlacement = reset.placement;
    if (reset.rects)
      rects =
        reset.rects === true
          ? await platform.getElementRects({ reference, floating, strategy })
          : reset.rects;
    ({ x, y } = computeCoordsFromPlacement(rects, statefulPlacement, rtl));
  }
  i = -1; // restart from middleware[0]
}
```

Two facts in that fragment are load-bearing and undocumented in the public API:

- **`reset: true` (the boolean form) restarts the loop _without_ recomputing coordinates from the
  placement.** Only the object form calls `computeCoordsFromPlacement`. `arrow()` depends on this:
  its alignment nudge would be erased by an unconditional recompute.
- **`middlewareData` is never cleared across a reset.** That is what lets `flip()` accumulate its
  `overflows` trace and advance its `index` across restarts — and equally means a reset triggered
  by an unrelated middleware re-enters `flip()` with a populated accumulator.

The `Platform` interface (`packages/core/src/types.ts:24-57`) has exactly three required methods —
`getElementRects`, `getClippingRect`, `getDimensions` — plus optional members that each degrade to
a sensible default when omitted: `convertOffsetParentRelativeRectToViewportRelativeRect` (absent ⇒
the rect is already viewport-relative), `getOffsetParent`, `isElement`, `getDocumentElement`,
`getClientRects` (absent ⇒ `inline()` cannot run), `isRTL` (absent ⇒ LTR), `getScale` (absent ⇒ the
scale is derived, see below) and `detectOverflow` (absent ⇒ the built-in is injected at
`computePosition.ts:32-34`). Not all of these are measurement: `isRTL`, `isElement`,
`getDocumentElement` and `detectOverflow` are respectively a writing-mode fact, two type
predicates and a whole overridable algorithm.

Every method returns `Promisable<T>` because one consumer — React Native's callback-based
`measure` — is asynchronous. That single fact makes every middleware `async` and makes
`computePosition` return a Promise on every platform, including the two that never await anything
real.

## The analysis spine

### 1. Anchor model

**Algorithm.** The anchor is only ever a `Rect`:

```text
rects        = platform.getElementRects({reference, floating, strategy})
anchorRect   = rects.reference                       // opaque handle in, Rect out
floatingRect = {x: 0, y: 0, width: mW, height: mH}   // always at the origin
```

`getElementRects` in the DOM platform normalises the floating rect to origin `(0,0)` explicitly
(`packages/dom/src/platform/getElementRects.ts:5-18`), so the engine only ever sees a size for the
overlay, never a position.

[Virtual anchors][concepts] are a first-class documented shape:
`VirtualElement = {getBoundingClientRect(); getClientRects?; contextElement?}`
(`packages/utils/src/index.ts:28-32`). `contextElement` exists so that clipping-ancestor discovery
and scroll-listener attachment have a real node to walk from — the _geometry_ comes from the
callback. A pure point anchor is a virtual element of zero extent: `useClientPoint`'s
`createVirtualElement` sets `width = 0; height = 0` and substitutes the tracked coordinates, with
an `axis: 'x' | 'y' | 'both'` option that preserves the element's own extent on the untracked axis
(`packages/react/src/hooks/useClientPoint.ts:13-66`) — which is how a context menu follows x while
staying pinned to a row's y.

Multi-rect (text-range) anchors are handled by `inline()`, which calls `platform.getClientRects`,
groups the rects into lines, synthesises a _new_ virtual reference from the chosen group, feeds it
back through `platform.getElementRects` and returns it as `reset: {rects: resetRects}`.

Trigger and anchor are modelled as distinct in the React layer: `elements.domReference` (the node
receiving events) is separate from `elements.reference` (the positioning reference), and
`refs.setPositionReference()` replaces the latter without touching the former
(`packages/react/src/hooks/useFloatingRootContext.ts:48-73`). `useClientPoint` is exactly that
split: real trigger, virtual anchor.

Anchor movement is not modelled in the engine at all; it is `autoUpdate`'s job (dimension 3).
Many-triggers-one-overlay is not modelled: one `useFloating` is one reference/floating pair, and
sharing is done by the application re-pointing `setPositionReference`.

**Where the behaviour lives.** The contract is in core (`Platform.getElementRects`); the
conversion is entirely per-platform. Note that the handle is _not_ used only for measurement: the
element flows into `platform.getClippingRect` for boundary derivation
(`packages/core/src/detectOverflow.ts:64-74`) and `useDismiss` walks
`reference.contextElement`'s overflow ancestors to scope scroll dismissal
(`packages/react/src/hooks/useDismiss.ts:434-437`). A value-shaped port needs an explicit
substitute for both — see [`./comparison.md`](./comparison.md).

**Degradation.** The model survives every constraint in the survey's degradation set. With no OS
window and integer cells the anchor is a cell-space `Rect`, a plain comparable value. Element
identity is needed only for clipping discovery and RTL probing, both omittable. A point anchor
degrades to a small rect, which the engine handles because `detectOverflow` divides by an extent
only when it is non-zero. No hover costs the _cursor-anchor mode_, not the model.

### 2. Placement model

**Algorithm.** Twelve placements — four physical sides × `{bare, -start, -end}` — built by a
`reduce` over `sides` and `alignments` (`packages/utils/src/index.ts:34-40`). The vocabulary is
purely physical: there is no logical `inline-start` naming and no writing-mode support beyond a
single `rtl` boolean from the optional `platform.isRTL`. RTL flips only the _alignment_ sign on
vertical placements; sides never mirror.

```text
placement -> coords (packages/core/src/computeCoordsFromPlacement.ts:10)
  top    -> (refCx - fW/2,  refY - fH)
  bottom -> (refCx - fW/2,  refY + refH)
  left   -> (refX  - fW,    refCy - fH/2)
  right  -> (refX  + refW,  refCy - fH/2)
  if alignment:
      coords[alignAxis] += (refLen/2 - fLen/2) * (end ? +1 : -1) * (rtl && vertical ? -1 : 1)
```

Fallback is a _generated ordered list_ walked one entry per lifecycle restart, not a search:

```text
base = isBareSide(initial) || !flipAlignment
     ? [opposite(initial)]
     : [oppAlign(initial), opposite(initial), oppAlign(opposite(initial))]   # utils:115-123

if fallbackAxisSideDirection != 'none' and no explicit fallbackPlacements:
    base += getSideList(side(initial), direction == 'start', rtl)            # utils:132-150
              .map(s => alignment ? s + '-' + alignment : s)
              .concat(flipAlignment ? sameListWithOppositeAlignment : [])    # utils:152-170

candidates = [initialPlacement, ...base]
```

The ordering choice is explicit and worth naming: for an aligned placement, the _other alignment
on the same side_ is tried **before** crossing to the opposite side. `autoPlacement()` is the
alternative strategy — enumerate all twelve (or an allowed subset), sorted so the requested
alignment comes first, visit each via a reset, record overflow per candidate, then pick.

Slide is `shift()`; push/limit is `limitShift()`; viewport padding is `detectOverflow`'s `padding`
(a number or a per-side object); custom boundaries are
`boundary: Element | Element[] | 'clippingAncestors'` and
`rootBoundary: 'viewport' | 'layoutViewport' | 'document' | Rect`. The default boundary is
`'clippingAncestors'` — the DOM's overflow chain, not the surface.

Safe-area insets and OS work areas are not modelled: the only levers are `padding` and a
caller-supplied `Rect` root boundary. Multi-monitor is meaningless in this substrate. For
soft-keyboard avoidance the library's answer is naming rather than measuring: `'viewport'`
resolves to `visualViewport` dimensions, and 1.8.0 added `'layoutViewport'`, which the changelog
describes as remaining stable while pinch-zooming or when a mobile software keyboard is open
(`packages/core/CHANGELOG.md`, 1.8.0 — a documentation claim, not read out of the solver).

**Where the behaviour lives.** Entirely in core and `@floating-ui/utils`. `isRTL` is the single
platform hook, and it is optional.

**Degradation.** Every term is integer-safe except the three `/2` centring divisions, which
Floating UI leaves fractional and lets the consumer round (`@floating-ui/react-dom` applies
`roundByDPR`, `packages/react-dom/src/utils/roundByDPR.ts:3`). A cell-grid port needs exactly one
documented rounding rule for those. The dimension that does _not_ survive is script-free static
emit: with no measurement, only one placement can be baked at emit time. The named-root-boundary
shape is the directly adoptable part for a target with a soft-keyboard inset — the boundary
becomes a parameter rather than a discovery.

### 3. Collision & geometry engine

**Algorithm.** `detectOverflow(state, options) -> SideObject` is the single collision primitive;
every collision middleware is a reduction over its output
(`packages/core/src/detectOverflow.ts:49-125`):

```text
clip   = rectToClientRect(platform.getClippingRect({element, boundary, rootBoundary, strategy}))
target = elementContext == 'floating' ? {x, y, w: floating.w, h: floating.h} : rects.reference
tgtVp  = convertOffsetParentRelativeRectToViewportRelativeRect(target) ?? target

sx = target.w ? tgtVp.w / target.w : 0
sy = target.h ? tgtVp.h / target.h : 0
scale = (isElement(offsetParent) && getScale(offsetParent)) || {x: sx || sy || 1, y: sy || sx || 1}

top    = (clip.top     - tgtVp.top    + pad.top)    / scale.y
bottom = (tgtVp.bottom - clip.bottom  + pad.bottom) / scale.y
left   = (clip.left    - tgtVp.left   + pad.left)   / scale.x
right  = (tgtVp.right  - clip.right   + pad.right)  / scale.x
```

The scale factor is **derived, not asked for**: it is the ratio the platform's own convert
function introduced, per axis, with a fallback to the other axis when one has zero length and
finally to 1 (`detectOverflow.ts:98-106`). A core unit test pins the case where the offsetParent
is not an element, asserting `getScale` is never called there
(`packages/core/test/computePosition.test.ts:76`); another annotates a non-uniform scale as
something a custom canvas platform is free to produce (`:118`).

Clipping-ancestor discovery is the expensive part and is DOM-only: `getOverflowAncestors` walks up
collecting scroll containers, then a second pass applies containing-block rules to _drop_
ancestors that a fixed/absolute chain escapes
(`packages/dom/src/platform/getClippingRect.ts:87-134`). The intersection is a running
`max(top) / min(right) / min(bottom) / max(left)` over `[...clippingAncestors, rootBoundary]`
(`:143-192`). Results are memoised in a `Map` created fresh per `computePosition` call and injected
as `platform._c` (`packages/dom/src/index.ts:45-53`) — a cache that deliberately lives for one
call only, because a lifecycle with restarts calls it many times.

Tracking is observer-first and polling-optional. `autoUpdate` (`packages/dom/src/autoUpdate.ts:165`)
attaches `scroll` + `resize` to every overflow ancestor, a `ResizeObserver` to both elements, an
`IntersectionObserver`-based move detector (`observeMove`, `:46`), and only optionally an
`requestAnimationFrame` loop. The move detector sets `rootMargin` to the negated insets of the
element's current rect so that _any_ movement changes the intersection ratio, re-checks the
element's live rect against the rect the margins were computed from (entries are snapshots), and
throttles the re-arm to 1 s when the ratio is exactly 0 to avoid an infinite refresh loop.

Transforms, CSS `zoom`, iframe chains and DPR are all handled outside the engine: `getScale`
divides the bounding rect by the computed CSS width, iframe chains are composed inside the DOM
platform's `getBoundingClientRect`, and DPR rounding lives in the `react-dom` consumer.

**Degradation.** The _engine_ generalises completely; the _discovery_ does not, and that is the
finding. A single-surface toolkit has one clipping chain worth modelling — its own pane/scroll
stack — so `getClippingRect` becomes a lookup in an owned layout tree and the per-call `_c` cache
loses its purpose. With no top layer, `isTopLayer` is constant `false`, which is already the
default branch. With no sub-cell precision the convert function is the identity and both derived
scales fall out as 1 with no special-casing. And `autoUpdate` need not port at all: every
mechanism in it exists because the DOM has no move event. A toolkit that runs layout every frame
gets anchor tracking as a side effect; the only surviving question is whether to recompute
unconditionally or gate on a four-field rect compare (Floating UI's own `rectsAreEqual`).

### 4. Arrow / caret geometry

**Algorithm.** `arrow()` emits data and paints nothing
(`packages/core/src/middleware/arrow.ts:33-115`). Its only environment contact is
`platform.getDimensions` for the arrow's own size and `platform.getOffsetParent` for the
container's client length.

```text
axis       = alignmentAxis(placement);  len = axisLength(axis)
endDiff    = ref[len] + ref[axis] - coords[axis] - floating[len]
startDiff  = coords[axis] - ref[axis]
centerToReference = endDiff/2 - startDiff/2

clientSize = offsetParent[clientW|clientH] ?? floating[len]
largestPossiblePadding = clientSize/2 - arrowLen/2 - 1        # arrow.ts:76-79
minPad = min(userPad.min, largestPossiblePadding)
maxPad = min(userPad.max, largestPossiblePadding)

center = clientSize/2 - arrowLen/2 + centerToReference
offset = clamp(minPad, center, clientSize - arrowLen - maxPad)
centerOffset = center - offset - alignmentOffset              # != 0 => the arrow misses the anchor
```

`centerOffset` is the residual and the documented signal for hiding the arrow: non-zero means the
arrow no longer points at the reference. That is geometry metadata handed to the styling layer,
not a rendering decision. The `largestPossiblePadding` clamp exists so an over-large padding
cannot invert the interval and strand the arrow.

There is exactly one case where the arrow moves the _floating element_: an aligned placement whose
anchor is too small to host a padded arrow. `arrow()` then shifts the element by `alignmentOffset`
and returns `reset: shouldAddOffset` — the **boolean** form, so the restart preserves the nudge
(`arrow.ts:92-113`). It fires at most once, guarded by `!middlewareData.arrow`. Two other
middleware then explicitly stand down: `flip()` returns `{}` immediately when
`middlewareData.arrow?.alignmentOffset` is set, citing upstream issue 2549
(`packages/core/src/middleware/flip.ts:85-91`), and `offset()` refuses to re-add its delta when the
placement is unchanged and an `alignmentOffset` exists
(`packages/core/src/middleware/offset.ts:96-101`). This three-way handshake through
`middlewareData` is the most intricate coupling in the codebase.

Arrow size does **not** feed the gutter automatically; callers write `offset(ARROW_HEIGHT)` by
hand (`offset`'s own default is `0`, `packages/core/src/middleware/offset.ts:85`). Border-aware
arrows, tip radius and rotation live entirely in the React `FloatingArrow` component, which builds
an SVG path, rotates it per side, and cancels its static offset whenever `shift()` moved the
element on the relevant axis (`packages/react/src/components/FloatingArrow.tsx:55-140`).

**Degradation.** Treating the arrow as data is the part that ports. On a cell grid the arrow
length is one cell, padding is whole cells, and the clamp is exact integer arithmetic; the
rendered arrow is a single glyph on the border row or column chosen by the resolved side, and
`centerOffset != 0` becomes "draw the border character instead". Corner radius and stroke are
dropped. Sub-cell centring is impossible, so a one-cell arrow under an even-width overlay is
always half a cell off; `alignmentOffset` — nudge the whole overlay so the arrow lands honestly —
is the right fix in principle, but its boolean-reset-plus-two-middleware-standing-down
implementation is a warning about what that fix costs when the engine cannot see the anchor size
before the pipeline runs.

### 5. Trigger semantics

The positioning core has **no** trigger concept whatsoever. All of it is `@floating-ui/react`, as
independent hooks that each return an `ElementProps` bag: `useHover`, `useFocus`, `useClick`,
`useDismiss`, `useListNavigation`, `useTypeahead`, `useClientPoint`.

**Algorithm.** Multiple triggers are combined by _prop merging_, not by a machine
(`packages/react/src/hooks/useInteractions.ts:15-40`):

```text
mergeProps(userProps, propsList, elementKey):
    for each prop bag, for each key starting with 'on':
        handlers[key].push(fn)
        out[key] = (...args) => handlers[key].map(fn => fn(...args)).find(v => v !== undefined)
    non-handler keys: last writer wins
```

There is no arbitration layer. Every trigger independently calls the same
`onOpenChange(open, event, reason)` and the _application_ owns the `open` boolean — the library is
controlled-by-default. Races are prevented instead by ad-hoc cross-checks against one shared piece
of evidence: `dataRef.current.openEvent`, the DOM event that opened the surface, set in
`useFloatingRootContext.ts:51-53`. From it:

- `useHover.isHoverOpen()` — the open event's type contains `mouse` and is not `mousedown`
  (`packages/react/src/hooks/useHover.ts:146`);
- `useHover.isClickLikeOpenEvent()` — the open event was a click or `mousedown`, in which case
  `mouseleave` does **not** close (`:235`);
- `useClick.stickIfOpen` — a click only toggles closed if the opening event was the same kind of
  click;
- `useClientPoint` refuses to become the anchor unless the open event was mouse-based.

Plus `useFocus.blockFocusRef`, set on reference-press, Escape and window blur, so returning to the
tab does not re-open a tooltip (`packages/react/src/hooks/useFocus.ts:46-63`).

Pointer type is recorded from `event.pointerType` on `pointerdown`/`pointerenter` and tested with
`isMouseLikePointerType` (pen counts as mouse, with a comment about a Linux Chrome bug).
Long-press and native context-menu are not provided; a context menu is assembled by the
application from `onContextMenu` + `useClientPoint`. Assistive-technology activation is not
distinguished from a click. Keyboard activation in `useClick` needs both edges: Enter fires on
keydown, but Space latches `didKeyDownRef` on keydown and only toggles on **keyup**
(`packages/react/src/hooks/useClick.ts:167-185`).

**Degradation.** The prop-merge trick is React-specific and does not port. What ports is the
_arbitration datum_: a single stored open-cause value that every close path consults, which is a
value rather than a machine. Within this subject that value covers the open-time predicates
(`isHoverOpen`, `isClickLikeOpenEvent`, `stickIfOpen`); whether one such enum suffices in general
is settled against the whole corpus in [`./comparison.md`](./comparison.md), not here. On a
terminal target the Space-on-keyup pattern needs a key-release capability the TUI does not
declare, so activation must land on the single key event available. With no hover at all,
`useHover`, `useClientPoint`'s follow mode and the entire safe-polygon dimension are dead — which
this library already handles correctly, because they are all gated on `isMouseLikePointerType`
returning false rather than on a platform name. Script-free static emit keeps only `:hover` and
`:focus-within` — i.e. `useHover` and `useFocus` with zero delay and no arbitration.

### 6. Timing

**Algorithm.** `getDelay(value, 'open' | 'close', pointerType)` is the whole delay resolver, and
its _first_ rule is that any non-mouse-like pointer type gets zero
(`packages/react/src/hooks/useHover.ts:41-63`):

```ts
if (pointerType && !isMouseLikePointerType(pointerType)) {
  return 0;
}
```

Delay may be a number, a `{open, close}` pair, or a thunk returning either — so it can be read
from a group context at call time.

`restMs` is an orthogonal mechanism: not "wait N ms after entering" but "wait until the cursor has
been still for N ms". It is a timeout restarted on every `mousemove` over the reference, with a
tremor filter that ignores movements whose squared displacement is under 2 while a rest timer is
pending (`:512-522`). Crucially, when `restMs > 0` and no open delay is configured, `mouseenter`
returns early — rest becomes the _only_ opening path.

Warm-up / skip-delay across neighbours is `FloatingDelayGroup`, and two implementations coexist:
the original (state in a reducer, causes re-renders, forces `delay.open` to **1**,
`packages/react/src/components/FloatingDelayGroup.tsx:134`) and `NextFloatingDelayGroup` (all refs,
no re-render, forces `delay.open` to **0**,
`packages/react/src/components/NextFloatingDelayGroup.tsx:114`). Both force-close the previous
member when a second opens, raise an `isInstantPhase` flag the styling layer uses to suppress
animation, and optionally keep the group warm for `timeoutMs` after the last close before
reverting to the initial delay.

Reconstructed as a machine, the observed behaviour is:

```text
states: Closed, WarmingUp(t_open), Resting(t_rest), Open, CoolingDown(t_close)

Closed      --enter(mouse)--------> WarmingUp   [t_open; if restMs>0 && !delay.open -> Resting]
Closed      --enter(touch)--------> Open        [all delays forced to 0]
Resting     --move(d^2 >= 2)------> Resting     [restart t_rest]
Resting     --move(d^2 <  2)------> Resting     [ignored: tremor]
Resting     --timeout-------------> Open
WarmingUp   --leave---------------> Closed      [cancel]
Open        --leave, no bridge----> CoolingDown [t_close]
Open        --leave, bridge armed-> Open        [safePolygon owns closing; timer suppressed]
CoolingDown --re-enter------------> Open        [cancel]
CoolingDown --timeout-------------> Closed      [blockMouseMove := true]
Open        --sibling opens-------> Closed      [group.instantPhase := true; group open delay 0]
```

Two details are easy to miss. On every close `useHover` clears both timers and sets
`blockMouseMoveRef`, so a stray `mousemove` cannot immediately re-open (`:156-163`). And
`closeWithDelay` refuses to arm the close timer while a `handleClose` handler is live —
`if (closeDelay && !handlerRef.current)` — so during a safe-polygon traversal the polygon, not the
timer, owns closing.

There is no maximum display duration and no cool-down other than the group's `timeoutMs`.

**Degradation.** Timers are the one thing script-free static emit cannot have: tier-0 `:hover` is
instant-on/instant-off, so the machine collapses to `{Closed, Open}` (a CSS `transition-delay` can
fake the _visual_ delay but cannot gate state). Every target with a frame clock can run the machine
verbatim as an integer countdown stepped per frame — which is strictly _more_ testable than
`setTimeout`, because a frame-counted deadline is deterministic. With no hover, `WarmingUp` and
`Resting` are dead states. The touch-forces-zero-delay rule is a small, directly copyable default.

### 7. Interactive hover (safe polygon)

**Algorithm.** `safePolygon()` is a `handleClose` factory
(`packages/react/src/safePolygon.ts:47`): on `mouseleave` of the reference it installs a
document-level `mousemove` handler that decides per move whether to close. Four ordered tests:

1. **Opposite-side bail** — if the cursor left through the far side of the reference
   (`side === 'top' && y >= refRect.bottom - 1`, and the three mirrors), close immediately; the
   ±1 absorbs float rounding (`:167-174`).
2. **Trough rectangle** — a four-point rect spanning the gap between reference and floating,
   using the _wider_ of the two for its extent; inside it, never close (`:176-216`). It exists
   because the triangle is anchored at the cursor's exit point, which can lie outside the
   reference's edge, so travelling back and forth would otherwise leave the triangle.
3. **Landed test** — once the pointer has been over the floating element, any move outside the
   reference rect closes.
4. **Triangle** — a four-point polygon built from two cursor points offset by `buffer`
   (default `0.5`), spread `buffer * 4` sideways when the floating element is narrower than the
   reference and `buffer / 2` when it is wider, **plus the two far corners of the floating rect**
   (`:216-333`), tested by the standard ray-crossing parity loop (`isPointInPolygon`, `:11-25`).

On top of those, `requireIntent` (default `true`, `:51`) closes immediately when the cursor speed
falls below a threshold, and if the cursor is inside the polygon but has never landed, a 40 ms
`setTimeout(close)` is armed and cleared by the next move — so stalling in the corridor still
closes:

```ts
// packages/react/src/safePolygon.ts:384-392
if (!isLeave && requireIntent) {
  const cursorSpeed = getCursorSpeed(event.clientX, event.clientY);
  const cursorSpeedThreshold = 0.1; // px/ms
  if (cursorSpeed !== null && cursorSpeed < cursorSpeedThreshold) {
    return close();
  }
}
```

`getCursorSpeed` (`:62-83`) computes `sqrt(dx² + dy²) / elapsedMs` from `performance.now()`. This is
the only place in the library where behaviour depends on wall-clock time rather than geometry.

Submenus get no diagonal-intent heuristic beyond the same triangle; the entire menu-aim story is
one guard — any open child aborts the parent's close (`:159`). The pointer [grab][concepts]
substitute is not a DOM element either: `blockPointerEvents` sets `pointer-events: none` on
`document.body` and re-enables it on the reference, the floating element and (in a tree) the parent
floating element (`packages/react/src/hooks/useHover.ts:428-466`).

**Degradation.** The geometry ports to any target that has a pointer; two parts do not.

> [!WARNING]
> The polygon is **not** confined to the corridor between anchor and overlay — for a `bottom`
> placement it spans from the cursor's exit point to the far corners of the _floating_ rect. So
> the intuition that a small gap collapses the polygon into a one-dimensional interval test is
> wrong: at a 0–1 cell gap the _corridor portion_ stops discriminating, but the polygon still
> classifies cells across the overlay's own area.

`requireIntent` is the genuinely unportable piece. Ported onto a cell-quantised pointer vocabulary
it collapses to the two-valued question "did the pointer's cell change this frame", because the
event vocabulary carries whole cells and a terminal has no sub-cell wire at all. It is not
unrepresentable in principle — a velocity gate can live upstream of quantisation, at a
device-space gesture-recognition seam — but it cannot live in the overlay's own state machine.
`blockPointerEvents` is CSS-only and needs a different mechanism entirely; expressing the corridor
as an entry in a derived hit list is the candidate examined in
[`./comparison.md`](./comparison.md) and [`./proposal.md`](./proposal.md). With no hover the whole
dimension is dead; the library's own answer — disable at the source rather than degrade — is the
one it applies to touch.

### 8. Dismissal

**Algorithm.** `useDismiss` (`packages/react/src/hooks/useDismiss.ts:132`) enumerates the causes:
Escape (`escapeKey`), outside press (`outsidePress`, with
`outsidePressEvent: 'pointerdown' | 'mousedown' | 'click'` documented as eager-both /
eager-mouse-lazy-touch / lazy-both), trigger re-press (`referencePress` with its own event
choice), and ancestor scroll (`ancestorScroll`, default **off**). Anchor-hidden is a different
mechanism entirely — the core `hide()` middleware's `referenceHidden` flag, which the application
applies as visibility. Anchor removal, navigation, resize and window deactivation are not handled
here (window blur is consumed only by `useFocus`, for its own purposes).

The outside-press path is far more defensive than the name suggests:

```text
outsidePress(event):
    if dataRef.insideReactTree (a capture-phase flag set on the floating element)   -> return
    if event is 'click' and (mousedown inside or mouseup inside)                    -> return
    if a user predicate rejects the event                                           -> return
    if the target's root ancestor was injected AFTER the floating element rendered  -> return
        (detected via [data-floating-ui-inert] markers)
    if the press landed on a SCROLLBAR (offsetX > target.clientWidth, RTL-aware)    -> return
    if the target is within floating, domReference, or any open descendant node     -> return
    if any open child declares __outsidePressBubbles === false                      -> return
    onOpenChange(false, event, 'outside-press')
```

Escape carries an IME guard: `compositionstart`/`compositionend` set `isComposingRef`, with a
WebKit-specific 5 ms settle delay because Safari fires `compositionend` _before_ `keydown`
(`:174-178`, `:382-399`). Escape also consults the overlay tree: with `bubbles.escapeKey === false`
the event is `stopPropagation`'d and a parent refuses to close while an open child has not opted
into bubbling. Parent/child relationships are resolved through `getNodeChildren`/`getNodeAncestors`
over a flat `nodesRef` array (`packages/react/src/utils/nodes.ts:3`).

> [!WARNING]
> `useDismiss.ts:283` reads a bare `floating`, which resolves to the `const floating` prop-bag
> declared 236 lines later at `:519`, not to `elements.floating`. The shadowing is observed
> directly; the consequence — that the scrollbar-press exemption is therefore unconditionally
> enabled, since the memo is always truthy by the time the callback runs — is an inference from
> reading the two declarations together, not something a test pins.

**Degradation.** Escape, re-activation, outside-press, parent/child cascades and anchor-hidden all
port. Two shifts matter. First, with events routed against the last painted frame, "outside press"
must be decided by the hit list rather than by tree containment — `isEventTargetWithin(floating)`
becomes "the hit entry under the pointer is not owned by this overlay or a descendant overlay",
which is cheaper and equally correct. Second, the pointerdown-vs-click distinction remains real
(press-and-drag out of an overlay is a genuine gesture, and the two-edge
`endedOrStartedInside` test is the minimal correct guard) — but a target without a release event
can only implement the eager policy. An Android back key is a dismissal source with no analogue
here and must be added. `ancestorScroll` maps to "the pane containing the anchor scrolled". The IME
composition guard has no terminal analogue (the terminal owns IME) but does apply on a windowed
GUI. Script-free HTML gets re-activation dismissal from `<details>` and nothing else.

### 9. Focus

**Algorithm.** Focus is a separate opt-in component,
`FloatingFocusManager` (`packages/react/src/components/FloatingFocusManager.tsx:121`), and its
props _are_ the taxonomy: `modal` (default **true**), `order: Array<'reference'|'floating'|'content'>`,
`initialFocus` (a tabbable index into `order`, or a ref), `returnFocus`, `restoreFocus`, `guards`,
`closeOnFocusOut`, `visuallyHiddenDismiss`, `outsideElementsInert`, `getInsideElements`.

Modal = focus guards (zero-size `tabindex=0` sentinels before and after) plus
`markOthers([floating, ...insideElements], ariaHidden, inert)`
(`packages/react/src/utils/markOthers.ts:160`):

```text
attr    = inert ? 'inert' : ariaHidden ? 'aria-hidden' : null
keepSet = ancestor closure of the kept elements
          + every [aria-live], [role="status"] and <output> in the body   # markOthers.ts:167-169
DFS from body.children:
    node in keepSet -> recurse
    else            -> counter[node]++ ; marker[node]++
                       if counter == 1 and the node already had attr: record as uncontrolled
                       if marker  == 1: set data-floating-ui-inert
                       if not already hidden and attr: set attr
undo: decrement both; remove attr only at count 0 and only if not uncontrolled
```

The live-region exemption and the uncontrolled-element bookkeeping are both deliberate: a modal
must not silence toasts, and nested managers unwinding out of order must not strip an attribute the
application owns.

Non-modal = no trapping; `closeOnFocusOut` listens for `focusout` and closes when focus moves to an
unrelated node, while `FloatingPortal`'s four guard spans preserve sequential tab order across the
portal's DOM discontinuity. Return focus keeps a bounded list (`LIST_LIMIT = 20`, `:35`) of
previously focused elements as `WeakRef`s, prunes disconnected ones, and skips restoring when focus
moved elsewhere after mount. `visuallyHiddenDismiss` renders a screen-reader-only close button at
both ends, precisely because touch screen readers have no Escape key.

The four surfaces stay distinct **by composition, not configuration**: a tooltip uses
`useRole({role: 'tooltip'})` + `useHover` + `useFocus` and _no focus manager at all_; a popover adds
`FloatingFocusManager` with `modal: false`; a menu adds `useListNavigation`; a dialog uses
`modal: true` + `FloatingOverlay`. There is no `type: 'tooltip' | 'menu'` switch anywhere.

**Degradation.** This is the dimension that ports most cleanly to a canvas toolkit, because
`markOthers`' entire job — making the rest of the document unreachable — is, in a toolkit that
owns its own hit list and traversal order, a filter over one focus ring. There are no browser focus
guards to synthesise, no address bar to escape into, no `inert` attribute and no shadow roots. What
must survive is the vocabulary: the `order` concept, the initial-focus index, a bounded
return-focus stack with a "did focus move elsewhere" guard, and the modal/non-modal split. Focus
movement is keydown-driven, so a target without key release loses nothing here.
`visuallyHiddenDismiss` maps to a back key on Android. Script-free HTML gets non-modal containment
from `:focus-within` and modal trapping not at all.

### 10. Layering & portals

Floating UI does not own layering, and this is the dimension where the absence is the finding.
`computePosition` returns `{x, y, placement, strategy, middlewareData}`
(`packages/core/src/computePosition.ts:100-106`) and stops. There is no z-index, no stacking
context and no layer manager anywhere in `core` or `dom`.

What exists in the React layer is `FloatingPortal`
(`packages/react/src/components/FloatingPortal.tsx:61`), which creates a
`div[data-floating-ui-portal]` under `document.body` (or a supplied root, or a `ShadowRoot`) and
renders through `createPortal`. Nesting is honoured — a portal inside a portal uses the parent's
node as container. Its real complexity is not layering but _tab order_: four guard spans keep
sequential focus consistent across the DOM discontinuity the portal creates.

The native top layer is **detected, never used**: `isTopLayer(el)` tries `el.matches(':popover-open')`
then `el.matches(':modal')` inside two `try`/`catch` blocks (`packages/utils/src/dom.ts:77`). When it
is true, `getClippingRect` uses _no_ clipping ancestors and `getOffsetParent` returns the window
(`packages/dom/src/platform/getClippingRect.ts:157-162`,
`packages/dom/src/platform/getOffsetParent.ts:54-56`). The library's entire relationship with the
platform top layer is therefore: if the application opted into it, stop pretending we are clipped.

Overlay _trees_ are logical, not visual. `FloatingTree`
(`packages/react/src/components/FloatingTree.tsx:85`) holds a flat
`nodesRef: Array<{id, parentId, context}>` and three pure helpers — `getNodeChildren` (recursive),
`getDeepestNode` (BFS by depth) and `getNodeAncestors` (walk up) — plus a small event emitter for
cross-node messages. It has zero effect on paint order.

The public/private line is unusually crisp: public is `computePosition`'s return value and the
`Platform` interface; private is portal nodes, focus guards, `data-floating-ui-inert` markers,
`platform._c` and the focusable-element attribute.

**Degradation.** A single-surface toolkit is, on this dimension, _more_ aligned with Floating UI
than the DOM is: the library already treats the top layer as an unreliable optional and works
without it on the default path. The portable part is `FloatingTree` — a flat array of
`{id, parentId}` with three pure queries, which is a value type. The unportable part (portals and
focus guards) exists solely to work around DOM tree and stacking-context leakage, which a
single-surface toolkit does not have. What a display-list toolkit's overlay list must additionally
carry — band membership, paint order, hit-routing precedence — is not answered here at all; see
[`./comparison.md`](./comparison.md).

### 11. Modality

**Algorithm.** [Modality][concepts] is decomposed into four independent switches rather than one
flag:

| Switch                     | Mechanism                                                        | Location                                                                 |
| -------------------------- | ---------------------------------------------------------------- | ------------------------------------------------------------------------ |
| Focus modality             | trap + `markOthers(aria-hidden)`                                 | `FloatingFocusManager modal` (default `true`)                            |
| Pointer modality, no scrim | `markOthers` switched to the native `inert` attribute            | `outsideElementsInert` (default `false`), `FloatingFocusManager.tsx:196` |
| Scrim + scroll lock        | a `position:fixed; inset:0` element with refcounted `lockScroll` | `FloatingOverlay.tsx:81`, lock at `:15`                                  |
| [Light dismiss][concepts]  | Escape / outside press / re-press / ancestor scroll              | `useDismiss`                                                             |

`outsideElementsInert`'s own prop documentation states the intent — it enables pointer modality
without a backdrop. The scroll lock is globally refcounted and carries an iOS branch: `overflow:
hidden` on the body is insufficient there, so it pins `position: fixed` with negative offsets
computed from `scrollY` minus `visualViewport.offsetTop` and restores with `window.scrollTo` on
unlock; it also publishes the scrollbar width as a CSS custom property and pads the body
(RTL-aware) to prevent layout shift.

The accessibility modal bit is handled by hiding the rest of the tree rather than by setting
`aria-modal`. Pointer passthrough is the default state — nothing blocks unless a switch is thrown —
so there is no explicit "transparent to pointer" mode.

```text
modality = (focusTrapped?, pointerBlocked?, scrimPainted?, scrollLocked?, lightDismiss?)
  tooltip = (no,  no,  no,  no,  escape only)
  popover = (contained via closeOnFocusOut, no, no, no, yes)
  menu    = (contained, no, no, no, yes)
  dialog  = (yes, yes via inert or overlay, yes, yes, optional)
```

> [!IMPORTANT]
> `modal: true` is the **default** for the focus manager — the opposite of what a tooltip wants.
> It is safe only because a tooltip is composed without a focus manager at all. A design that made
> the focus manager mandatory would inherit a trap on every tooltip.

**Degradation.** Every piece ports except the browser-specific hacks. On one surface, pointer
modality is "the overlay's hit region covers the surface and swallows everything below" — a single
full-surface entry in the hit list, trivially expressible in a display list. A scrim is a fill
with a blend attribute; scroll lock is meaningless with no document scroll; the iOS `position:
fixed` dance and the scrollbar-gutter padding are pure browser tax. The transferable insight is
the **decomposition**: four orthogonal booleans rather than one `modal` enum is what keeps tooltip,
popover, menu and dialog distinct without any of them carrying a type tag.

### 12. Adaptive presentation

This is the library's largest deliberate absence, and the absence is a design position rather than
an omission. There is no popover-to-sheet transformation, no teaching-tip concept, no
compact/regular size-class awareness and no keyboard-driven relocation. `@floating-ui/react` ships
hooks; the component author decides presentation. The docs' Tooltip/Popover/Dialog recipes are
pages, not code.

**Algorithm.** What _does_ adapt is all micro and all in the pointer layer:

```text
pointerType = last observed event.pointerType on the reference
isMouseLike(pt) = pt == 'mouse' || pt == 'pen'          # pen counted as mouse (Linux Chrome bug)

if !isMouseLike(pointerType):
    delay.open = delay.close = 0                        # useHover.ts:46-48
    clientPoint tracking disabled                       # useClientPoint.ts:184
    mouseleave closes only when relatedTarget is outside the floating element   # useHover.ts:318-324
```

The `mouseleave` special case carries a comment saying it exists to allow interactivity without
`safePolygon` on touch devices. `useHover({mouseOnly})` disables hover opening for touch and pen
outright. `visuallyHiddenDismiss` exists because touch-based screen readers lack an Escape key.
`FloatingOverlay`'s iOS scroll branch and `FloatingPortal`'s hidden owner span (an `aria-owns`
workaround for iOS Safari and Voice Control) are platform-quirk adaptations, not presentation
adaptations. Long-press-instead-of-hover is not provided; neither is any coarse-pointer media
query.

**Degradation.** The transferable rule is structural: **capability facts are inputs carried in the
state, and every timing and interaction primitive reads them** rather than branching on a platform
name. "No hover on Android" then falls out as `isMouseLike == false` everywhere, which this
library already handles. What a toolkit spanning terminal, window, static HTML and Android needs
beyond that — a declared substitute when hover is unavailable, and publishing that substitution
rather than silently suppressing the surface — has no analogue here; see
[`./features-people-forget.md`](./features-people-forget.md).

### 13. Accessibility

There is zero accessibility in `@floating-ui/core` and `@floating-ui/dom`, by construction: neither
knows what a floating element _is_. All of it is `useRole` (134 lines) plus
`FloatingFocusManager`.

**Algorithm.** `useRole` is a lookup table plus two branches
(`packages/react/src/hooks/useRole.ts:33-110`):

```text
componentRoleToAriaRoleMap: select -> listbox, combobox -> listbox, label -> false

role == 'tooltip' or 'label':
    reference: aria-describedby | aria-labelledby = floatingId   (only while open)
    floating:  id, role='tooltip'                                 (label => no role)

otherwise:
    reference: aria-expanded, aria-haspopup = (alertdialog ? 'dialog' : role),
               aria-controls = floatingId (while open)
    floating:  id, role
    + listbox  -> reference role='combobox'
    + menu     -> reference id; a NESTED reference gets role='menuitem';
                  floating aria-labelledby = referenceId
    + select   -> aria-autocomplete='none'   ; combobox -> aria-autocomplete='list'
    items (select|combobox only) -> role='option', aria-selected, generated id when active
```

The tooltip/label branch short-circuits **before** the `aria-expanded` block (`:70`) — the clearest
in-source evidence that tooltip semantics fork immediately from everything else. The floating id is
resolved via `getFloatingFocusElement`, which prefers the descendant carrying the library's
focusable marker, so a positioning wrapper does not steal semantics from the real content element.

WCAG 1.4.13 (hoverable / dismissible / persistent) is addressed only by composition: Escape
dismissal from `useDismiss`, hoverable content from `safePolygon`, and persistence not at all —
there is no maximum display duration and nothing prevents a zero close delay. Whether tooltip
content may be interactive is left open, and `safePolygon` exists to make it work.

**Degradation.** On a cell grid or a raw GPU canvas there is no accessibility API to talk to, so
this dimension is largely not applicable in its DOM form. The _decomposition_ is what survives:
`useRole` demonstrates that the positioning primitive needs to carry exactly two things — a role
tag and a describes-vs-labels relation to the anchor — and that everything else is derived from the
role by a pure table, which is a `switch` over an enum. A static HTML emit is the one target where
this table can be implemented completely, because ARIA attributes need no script. Android has a
real accessibility tree and the same table applies. The sparkles-side inventory of what exists
today lives in [`./sparkles-baseline.md`](./sparkles-baseline.md).

### 14. Animation

The library emits geometry metadata specifically so a styling layer can animate, and this is an
explicit selling point rather than a side effect.

**Algorithm.** The payload merged into `middlewareData` (`packages/core/src/types.ts:60`):

```text
placement                                    # final side+alignment => transform-origin
arrow  { x | y, centerOffset, alignmentOffset }   # pin the origin to the arrow tip
shift  { x, y, enabled: {x, y} }                  # how far it slid, and on which axes it could
offset { x, y, placement }
hide   { referenceHidden, escaped, referenceHiddenOffsets, escapedOffsets }
flip / autoPlacement { index, overflows: [{placement, overflows[]}] }   # full candidate trace
```

`useTransitionStyles` consumes it: style values may be _functions_ receiving `{side, placement}`,
so a caller writes an initial transform that depends on the resolved side. It derives
`transitionProperty` by kebab-casing the keys of the open-style object — the transition property
list is computed from the animated styles rather than hand-written.

The status machine (`packages/react/src/hooks/useTransition.ts:58-140`):

```text
open = true  -> status = 'initial' ; next rAF -> flushSync(status = 'open')
open = false -> status = 'close'   ; after closeDuration -> isMounted = false -> 'unmounted'
```

The one-frame deferral plus `flushSync` carries a comment attributing it to avoiding a flicker when
moving between floating elements in a delay group. Reposition-during-animation is handled by
`isPositioned`, deliberately kept false while `open === false` so a re-open never animates from a
stale position (`packages/react-dom/src/useFloating.ts:99`), and by
`autoUpdate({animationFrame: true})` for anchors that are themselves being transform-animated.

There is no reduced-motion handling anywhere in the overlay path; springs are not supported
(duration only); the arrow is an ordinary child and inherits the parent's transition;
`isInstantPhase` from the delay groups is the channel for suppressing animation entirely.

**Degradation.** The metadata-emission pattern is the transferable part and it is
target-independent: a display-list toolkit can carry `placement`, arrow offset, `centerOffset` and
shift delta as plain fields on the overlay's layout result, and every backend reads them without
re-deriving anything. On a cell grid there are no transforms, so animation is a per-frame reveal
driven by the same status enum with an integer frame counter; on a GPU canvas it is real
interpolation off the same enum. Script-free HTML cannot run the machine at all and must present
the open state directly. A frame-counted status machine is deterministic and therefore assertable
on a recording canvas, which `setTimeout` + `requestAnimationFrame` + `flushSync` is not.

### 15. State architecture

Two architectures with a hard seam between them.

**Core is an async fold with a restart.** `computePosition` holds five mutable locals
(`x`, `y`, `statefulPlacement`, `rects`, `middlewareData`), iterates the middleware array awaiting
each, applies `x = nextX ?? x`, shallow-merges `data` into `middlewareData[name]`, and on `reset`
sets `i = -1`. State reaches middleware as one value object (`MiddlewareState`,
`packages/core/src/types.ts:172`) and returns as another (`MiddlewareReturn`, `:143`). No middleware
holds state between calls except through `middlewareData`, which is the state channel. Middleware
are factories closing over options, and options may be `Derivable<T> = (state) => T` (`:19`) so they
can be recomputed each pass.

**The React layer is uncontrolled-by-default hooks over refs and effects.** `useFloating` keeps the
result in `useState`, mirrors it in a ref, `deepEqual`s before setting, and wraps the set in
`flushSync` so the DOM is positioned before paint. `useFloatingRootContext` holds a mutable
`dataRef` bag and a hand-rolled event emitter. Interaction hooks are timers, document listeners and
latest-value refs. The `open` boolean itself belongs to the application.

The consequences for a value-semantics, allocation-conscious port are asymmetric. The kernel is a
fold over an array with a value-typed state and a value-typed return, no identity semantics
anywhere, and no floating-point requirement beyond the centring divisions. `MiddlewareState` becomes
a struct; `MiddlewareReturn` a struct with optional coordinates and a `Reset` sum type; the
middleware array becomes a compile-time tuple, which removes the runtime dispatch and lets
`middlewareData` become a plain struct of optional per-middleware payloads with no map and no
allocation. The `async` must go — it is a tax one asynchronous consumer imposes on every platform.
The React layer does not survive and should not be ported.

> [!WARNING]
> The 50-reset cap fails **silently**: once exceeded, the reset is discarded, the loop runs to
> completion and the caller receives a position with no throw, no warning and no flag. A consumer
> cannot distinguish "converged" from "gave up". A port with an assertable frame should surface a
> non-convergence flag instead.

**Degradation.** The kernel survives every target: zero timers, zero events, zero identity, no DOM,
no OS window. Nothing in it requires a key release, hover, sub-cell precision or script — only
arithmetic over supplied rects.

### 16. Shared infrastructure

**Algorithm.** The factoring is one positioning engine, one prop merger, one dismissal hook, one
focus manager, one role table, one tree — and then per-surface composition in userland. The library
ships **no** `Tooltip`, `Popover`, `Menu`, `Select` or `Combobox` component at all. What the
documentation assembles, observed across the recipes:

```text
Tooltip     = useFloating + offset/flip/shift + useHover(delay | restMs) + useFocus
              + useDismiss + useRole('tooltip')
HoverCard   = Tooltip + safePolygon + FloatingFocusManager(modal: false)
Popover     = useFloating + useClick + useDismiss + useRole('dialog')
              + FloatingFocusManager(modal: false) + FloatingPortal
Menu        = Popover + useListNavigation + useTypeahead + FloatingTree/FloatingNode + role('menu')
Submenu     = Menu with nested: true + safePolygon + parentId
Select      = Popover + useListNavigation(selectedIndex) + role('select') + size()
Combobox    = Select with virtual: true (aria-activedescendant) + role('combobox')
ContextMenu = Menu with useClientPoint(x, y) instead of an element anchor
Dialog      = FloatingFocusManager(modal: true) + FloatingOverlay(lockScroll) + useDismiss
```

Genuinely shared, and correctly so: `computePosition` + middleware + `Platform`; `useDismiss` (whose
tree-bubbling options exist precisely so one hook serves nested cases); `useRole`;
`FloatingFocusManager` (one component, `modal` toggling dialog vs popover behaviour); `FloatingTree`
(one flat registry serving nested hover, nested dismissal, nested list navigation and focus return);
and the `FloatingList` / `Composite` / `useListNavigation` / `useTypeahead` cluster shared by menu,
select, combobox and grid pickers.

What merely _looks_ common and is deliberately kept apart:

- **Hover timing vs click toggling** — `useHover` and `useClick` share nothing but `onOpenChange`
  and the open-event sniff. Their close conditions are irreconcilable: a hover surface closes on
  leave, a click surface must not.
- **Tooltip vs everything else** — `useRole` short-circuits before the `aria-expanded` block, and a
  tooltip uses no focus manager. Unifying them would give tooltips a focus trap and menus a
  `describedby`.
- **Two delay-group implementations** — kept apart because one re-renders and one does not, and
  because their instant-phase semantics differ (`delay.open` forced to `1` vs `0`).
- **Nested list navigation** — `nested: true` changes which key opens, and a nested list's close key
  is only `stopEvent`'d when it is not also the parent's navigation key.
- **Positioning vs interaction** — the package boundary itself: `@floating-ui/dom` (framework-free,
  three platforms) against `@floating-ui/react` (React-only, an order of magnitude larger). The
  `vue` package binds positioning only, with no interaction layer — direct evidence that the
  interaction layer is not considered essential to the product.

**Where the behaviour lives.** The package split _is_ the factoring: `core` (engine) / `utils` (pure
helpers) / `dom` + `react-native` (platforms) / `react-dom` (positioning binding) / `react`
(interaction).

**Degradation.** The boundary is drawn where three real platforms forced it to be drawn, and the
warning it carries is what happened on the other side: once the interaction layer became
React-shaped it grew large and became unportable. The reading this survey takes from it is that a
placement solve belongs in the layout phase as a pure function over values, and that delays, focus
policy, roles and list navigation must stay out of the shared overlay type. Note that this subject
argues for a _measurement abstraction_ as well (the `Platform` seam); the catalog's verified
position is that a toolkit whose measurement is synchronous, in-process and already performed by
`layout()` should **not** reproduce it — see [`./comparison.md`](./comparison.md).

## Strengths

- The `Platform` seam is real and proven three times: `@floating-ui/dom` (substantial browser
  archaeology), `@floating-ui/react-native` (a thin `View.measure` wrapper), and the documentation
  site's canvas platform, whose `getElementRects` is the identity function
  (`website/lib/components/Canvas.js:33`). Nothing in `core` imports anything DOM-shaped.
- The kernel is 107 lines. `computePosition` is a fold over an array with five mutable locals and
  one restart rule; every behaviour — flip, shift, size, arrow, hide, inline, autoPlacement, offset
  — is a separate pure function over that state.
- `detectOverflow`'s signed `SideObject` convention unifies five middleware into reductions over
  one 4-tuple: `flip` sums positives, `shift` clamps by them, `size` subtracts them, `hide` compares
  them to the rect's own extent, `autoPlacement` sorts by them.
- Geometry metadata is first-class output for the styling layer: final placement, arrow offset _and_
  `centerOffset`, shift delta plus which axes were enabled, and the full per-candidate overflow
  trace. Nothing has to be re-derived downstream.
- Edge cases are handled where they occur rather than papered over: the line-grouping tolerance in
  `inline`, its 2 px pointer padding with the browser reason in a comment, `arrow`'s
  `largestPossiblePadding`, `size`'s doubled-overflow rule for centred elements, `detectOverflow`'s
  zero-length-axis scale fallback, `inline`'s no-op on zero client rects.
- Modality is decomposed into four orthogonal switches rather than one enum, which is what keeps
  tooltip, popover, menu and dialog distinct without a type tag.
- `useRole` is a compact lookup table covering tooltip, label, dialog, alertdialog, menu, listbox,
  grid, tree, select and combobox — including the reference-side role changes — and is the most
  directly liftable piece of the React layer.
- `autoUpdate`'s move detector (negate the element's insets into `rootMargin` so any movement
  changes the ratio, then re-check against the live rect because entries are snapshots) is a
  genuinely inventive workaround for the DOM's lack of a move event.

## Weaknesses

- Every platform method is `Promisable<T>`, so every middleware is `async` and `computePosition`
  always returns a Promise — a cost imposed on all platforms by one asynchronous consumer.
- **The middleware maths is largely untested.** `packages/core/test` contains `computePosition`,
  `computeCoordsFromPlacement`, `autoPlacement` and `inline` tests; `flip`, `shift`, `limitShift`,
  `size`, `arrow` and `hide` have no unit tests, and their correctness is pinned only by Playwright
  screenshot snapshots that hide numeric regressions inside pixel diffs.
- `middlewareData` is never cleared across a reset, so `flip`'s `overflows` accumulator and `index`
  persist across resets triggered by _other_ middleware. INFERENCE: a `size()`-driven reset
  therefore appears to re-enter `flip` with a partially walked candidate list and duplicated
  accumulator entries, which could change the `bestFit` outcome. No test covers this and none was
  constructed.
- `useDismiss.ts:283` reads a shadowed `floating` (observed); the consequence — an unconditionally
  active scrollbar-press exemption — is inference.
- `inline()`'s pointer-based rect selection fires only when there are exactly two line groups and
  they are horizontally disjoint. A three-line selection, or two overlapping groups, silently falls
  through to the union bounding box; one Playwright case is skipped with a comment that it chooses
  the wrong rect.
- `safePolygon`'s `requireIntent` depends on `performance.now()` deltas and a 0.1 px/ms threshold
  plus a 40 ms grace timer — untestable deterministically and unimplementable on any target whose
  pointer sampling is frame-quantised.
- Middleware ordering is a load-bearing contract enforced by nothing: `offset` before `shift`,
  `size` after `flip`, `arrow` near the end, `hide` last. A wrong order produces a subtly wrong
  position with no error.
- The 50-reset cap fails silently.
- Adaptive presentation is absent, and arrow size does not feed the gutter automatically — callers
  must write `offset(ARROW_HEIGHT)` by hand.
- Two live delay-group implementations with subtly different semantics coexist, the older
  soft-deprecated by a tag on one exported hook.

## Key design decisions and trade-offs

| Decision                                                                                                                                                                           | Rationale                                                                                                                                                                                                                                                                                                             | Trade-off                                                                                                                                                                                                                                                                                                                                                                                                    |
| ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Make the environment a three-method interface (`getElementRects`, `getClippingRect`, `getDimensions`) plus optional refinements, and put zero environment knowledge in the engine. | It is what lets one geometry engine serve the DOM, React Native and a raw canvas. Each optional member degrades sensibly when absent: no `isRTL` means LTR, no `getScale` means scale 1, no convert function means the rect is already viewport-relative.                                                             | Every platform method returns `Promisable<T>` because one consumer is asynchronous, so every middleware is `async` and `computePosition` returns a Promise even when nothing awaits. Synchronous platforms pay a microtask per platform call per middleware per restart for a capability they never use.                                                                                                     |
| Middleware return **data**, not effects; the runner merges it into a per-name map that survives resets.                                                                            | It makes `arrow`, `hide` and `flip` testable as arithmetic, gives the styling layer geometry it could not otherwise derive, and lets middleware coordinate without knowing about each other — `offset` reads `middlewareData.arrow`, `size` reads `middlewareData.shift`, `limitShift` reads `middlewareData.offset`. | It creates an invisible coupling graph and an ordering contract enforced nowhere. And because the map is never cleared, `flip`'s accumulator keeps growing when an unrelated middleware restarts the pipeline — INFERENCE: a latent correctness hazard, not merely a wart.                                                                                                                                   |
| Express fallback as an ordered candidate list walked one entry per lifecycle restart, rather than a search evaluated in one pass.                                                  | Each pass stays simple (measure one placement, decide, hand back), other middleware re-run with the new placement so their placement-dependent maths is never stale, and the candidate order is explicit and inspectable in `middlewareData.flip.overflows`.                                                          | Cost is O(candidates × middleware × platform calls). With twelve `autoPlacement` candidates and a clipping-ancestor walk per `detectOverflow`, one position can issue very many DOM reads — which is exactly why `platform._c` exists. Over cheap owned rects, a synchronous engine could evaluate all candidates in one pass; the restart design is a workaround for expensive asynchronous platform calls. |
| Ship no components: provide hooks and let the application compose Tooltip / Popover / Menu / Select / Dialog.                                                                      | Tooltip, menu and dialog agree on positioning and disagree on focus, roles, close conditions and timing. `useRole`'s short-circuit for `tooltip`/`label` before the `aria-expanded` block is the clearest evidence that the semantics fork immediately.                                                               | The assembly burden lands on every consumer and the correct compositions live in prose rather than in code, so nothing enforces that a tooltip does not get a focus trap. It is also the direct cause of dimension 12 being empty: a library that ships no components cannot own adaptive presentation.                                                                                                      |
| Guard reset recursion with a single integer cap, and on exceeding it silently ignore further resets.                                                                               | Middleware are user-extensible, so a badly written one can reset forever. A hard cap is the cheapest protection and never fires for the built-in set (`flip` walks at most eight candidates, `autoPlacement` twelve, `size` and `inline` reset at most once per stable state).                                        | Failure is silent and yields a wrong position with no signal. A consumer cannot distinguish convergence from surrender.                                                                                                                                                                                                                                                                                      |
| Treat the viewport as a **named** boundary the caller chooses (`'viewport'`, `'layoutViewport'`, `'document'`, or a literal `Rect`) rather than a single measured quantity.        | Per the 1.8.0 changelog, `'layoutViewport'` stays stable under pinch-zoom and with a software keyboard open, and accounts for a reserved scrollbar gutter that a hand-passed rect would miss. The revision read is itself a fix for mis-measuring such a gutter.                                                      | It pushes a policy decision onto every caller, who must know which viewport their surface lives in. The alternative — one `'viewport'` silently meaning different things on desktop, under pinch-zoom and with a keyboard up — produced a long bug tail visible in the changelog.                                                                                                                            |

## Sources

Primary sources, all read at `0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1`:

- The kernel and its reset protocol — [`packages/core/src/computePosition.ts`][fui-computeposition]
  (the cap at [`:10`][fui-maxreset], the reset block at [`:78`][fui-reset]).
- The environment contract and the emitted metadata — [`packages/core/src/types.ts`][fui-types]
  (`Platform` at [`:24`][fui-platform], `ReferenceElement = any` at [`:164`][fui-refelement]).
- The single collision primitive and its derived scale —
  [`packages/core/src/detectOverflow.ts`][fui-detectoverflow] (scale derivation at
  [`:98`][fui-scale]).
- Placement vocabulary and fallback generation — [`packages/utils/src/index.ts`][fui-utils]
  (`placements` at [`:36`][fui-placements], `getAlignmentSides` swap at
  [`:108`][fui-alignmentsides], `getExpandedPlacements` at [`:115`][fui-expanded],
  `getOppositeAxisPlacements` at [`:152`][fui-oppositeaxis]) and
  [`packages/core/src/computeCoordsFromPlacement.ts`][fui-coords].
- The middleware — [`flip`][fui-flip] (arrow stand-down at [`:85`][fui-flip-arrow], `bestFit` at
  [`:183`][fui-flip-bestfit]), [`shift` and `limitShift`][fui-shift], [`size`][fui-size] (the
  centred-element rule at [`:108`][fui-size-centered], the termination test at
  [`:118`][fui-size-reset]), [`arrow`][fui-arrow] (padding clamp at [`:76`][fui-arrow-padding],
  boolean reset at [`:92`][fui-arrow-reset]), [`hide`][fui-hide], [`inline`][fui-inline] (line
  grouping at [`:27`][fui-inline-lines]) and [`offset`][fui-offset].
- The DOM platform — [`getClippingRect`][fui-clippingrect] (ancestor discovery at
  [`:87`][fui-clippingancestors]), [`getOffsetParent`][fui-offsetparent],
  [`getElementRects`][fui-elementrects], [`getViewportRect`][fui-viewportrect], the per-call cache
  at [`packages/dom/src/index.ts:45`][fui-domcache], and [`autoUpdate`][fui-autoupdate] with its
  move detector at [`:46`][fui-observemove].
- The other platforms — [`packages/react-native/src/createPlatform.ts`][fui-rn] and the
  documentation site's canvas platform at
  [`website/lib/components/Canvas.js:33`][fui-canvas] (documentation code, not a shipped package).
- Triggers and timing — [`useInteractions`][fui-useinteractions],
  [`useFloatingRootContext`][fui-rootcontext], [`useHover`][fui-usehover] (`getDelay` at
  [`:41`][fui-getdelay], the tremor filter at [`:512`][fui-restms], `blockPointerEvents` at
  [`:428`][fui-blockpointer]), [`useClick`][fui-useclick], [`useFocus`][fui-usefocus],
  [`useClientPoint`][fui-useclientpoint], [`FloatingDelayGroup`][fui-delaygroup] and
  [`NextFloatingDelayGroup`][fui-nextdelaygroup].
- Hover intent — [`safePolygon`][fui-safepolygon] (`isPointInPolygon` at
  [`:11`][fui-pointinpolygon], the velocity gate at [`:384`][fui-intent]).
- Dismissal, focus and semantics — [`useDismiss`][fui-usedismiss] (the shadowed identifier at
  [`:283`][fui-usedismiss-shadow] against its declaration at [`:519`][fui-usedismiss-decl]),
  [`FloatingFocusManager`][fui-focusmanager], [`markOthers`][fui-markothers] (the live-region
  exemption at [`:167`][fui-markothers-live]), [`FloatingPortal`][fui-portal],
  [`FloatingTree`][fui-tree], [`nodes.ts`][fui-nodes], [`FloatingOverlay`][fui-overlay],
  [`useRole`][fui-userole] (the tooltip short-circuit at [`:70`][fui-userole-tooltip]) and
  [`isTopLayer`][fui-istoplayer].
- Animation — [`useTransition`][fui-usetransition], [`FloatingArrow`][fui-floatingarrow] and
  [`isPositioned`][fui-ispositioned].
- Tests and release notes — [`packages/core/test/computePosition.test.ts`][fui-coretest] and
  [`packages/core/CHANGELOG.md`][fui-changelog].

Catalog context: [`./index.md`](./index.md) for the umbrella,
[`./concepts.md`](./concepts.md) for the shared vocabulary, [`./comparison.md`](./comparison.md)
for the cross-subject capstone, [`./features-people-forget.md`](./features-people-forget.md) for
the obscure-capability ledger, [`./sparkles-baseline.md`](./sparkles-baseline.md) for what the
toolkit owns today and [`./proposal.md`](./proposal.md) for the design that comes out of it.
The nearest peers on the web side are [`./react-aria.md`](./react-aria.md),
[`./radix.md`](./radix.md), [`./base-ui.md`](./base-ui.md), [`./zag.md`](./zag.md),
[`./ariakit.md`](./ariakit.md), [`./headlessui.md`](./headlessui.md),
[`./tippy.md`](./tippy.md), [`./floating-vue.md`](./floating-vue.md) and
[`./angular-cdk.md`](./angular-cdk.md); the platform-side answers to the same problems are
[`./popover-api.md`](./popover-api.md), [`./css-anchor.md`](./css-anchor.md),
[`./blink.md`](./blink.md) and [`./xdg-positioner.md`](./xdg-positioner.md).
Adjacent research trees: [`../window-system-integration/index.md`](../window-system-integration/index.md),
[`../platform-ui-guidelines/index.md`](../platform-ui-guidelines/index.md),
[`../ui-layout/index.md`](../ui-layout/index.md) and
[`../sean-parent/index.md`](../sean-parent/index.md). Toolkit specs:
[`../../specs/ui/index.md`](../../specs/ui/index.md),
[`../../specs/ui/input.md`](../../specs/ui/input.md),
[`../../specs/ui/containers.md`](../../specs/ui/containers.md),
[`../../specs/ui/state-machines.md`](../../specs/ui/state-machines.md),
[`../../specs/ui/backends.md`](../../specs/ui/backends.md) and
[`../../specs/ui/widgets.md`](../../specs/ui/widgets.md).

<!-- References -->

[concepts]: ./concepts.md
[fui-repo]: https://github.com/floating-ui/floating-ui
[fui-docs]: https://floating-ui.com/docs/getting-started
[fui-computeposition]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/core/src/computePosition.ts#L20
[fui-maxreset]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/core/src/computePosition.ts#L10
[fui-reset]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/core/src/computePosition.ts#L78
[fui-types]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/core/src/types.ts
[fui-platform]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/core/src/types.ts#L24
[fui-refelement]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/core/src/types.ts#L164
[fui-detectoverflow]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/core/src/detectOverflow.ts#L49
[fui-scale]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/core/src/detectOverflow.ts#L98
[fui-utils]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/utils/src/index.ts
[fui-placements]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/utils/src/index.ts#L36
[fui-alignmentsides]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/utils/src/index.ts#L108
[fui-expanded]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/utils/src/index.ts#L115
[fui-oppositeaxis]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/utils/src/index.ts#L152
[fui-coords]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/core/src/computeCoordsFromPlacement.ts#L10
[fui-flip]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/core/src/middleware/flip.ts#L99
[fui-flip-arrow]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/core/src/middleware/flip.ts#L85
[fui-flip-bestfit]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/core/src/middleware/flip.ts#L183
[fui-shift]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/core/src/middleware/shift.ts#L44
[fui-size]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/core/src/middleware/size.ts#L46
[fui-size-centered]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/core/src/middleware/size.ts#L108
[fui-size-reset]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/core/src/middleware/size.ts#L118
[fui-arrow]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/core/src/middleware/arrow.ts#L33
[fui-arrow-padding]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/core/src/middleware/arrow.ts#L76
[fui-arrow-reset]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/core/src/middleware/arrow.ts#L92
[fui-hide]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/core/src/middleware/hide.ts#L32
[fui-inline]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/core/src/middleware/inline.ts#L66
[fui-inline-lines]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/core/src/middleware/inline.ts#L27
[fui-offset]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/core/src/middleware/offset.ts#L85
[fui-clippingrect]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/dom/src/platform/getClippingRect.ts#L143
[fui-clippingancestors]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/dom/src/platform/getClippingRect.ts#L87
[fui-offsetparent]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/dom/src/platform/getOffsetParent.ts#L54
[fui-elementrects]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/dom/src/platform/getElementRects.ts#L5
[fui-viewportrect]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/dom/src/utils/getViewportRect.ts#L75
[fui-domcache]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/dom/src/index.ts#L45
[fui-autoupdate]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/dom/src/autoUpdate.ts#L165
[fui-observemove]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/dom/src/autoUpdate.ts#L46
[fui-rn]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/react-native/src/createPlatform.ts#L13
[fui-canvas]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/website/lib/components/Canvas.js#L33
[fui-useinteractions]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/react/src/hooks/useInteractions.ts#L15
[fui-rootcontext]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/react/src/hooks/useFloatingRootContext.ts#L51
[fui-usehover]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/react/src/hooks/useHover.ts#L146
[fui-getdelay]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/react/src/hooks/useHover.ts#L41
[fui-restms]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/react/src/hooks/useHover.ts#L512
[fui-blockpointer]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/react/src/hooks/useHover.ts#L428
[fui-useclick]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/react/src/hooks/useClick.ts#L167
[fui-usefocus]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/react/src/hooks/useFocus.ts#L46
[fui-useclientpoint]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/react/src/hooks/useClientPoint.ts#L13
[fui-delaygroup]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/react/src/components/FloatingDelayGroup.tsx#L134
[fui-nextdelaygroup]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/react/src/components/NextFloatingDelayGroup.tsx#L114
[fui-safepolygon]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/react/src/safePolygon.ts#L47
[fui-pointinpolygon]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/react/src/safePolygon.ts#L11
[fui-intent]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/react/src/safePolygon.ts#L384
[fui-usedismiss]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/react/src/hooks/useDismiss.ts#L132
[fui-usedismiss-shadow]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/react/src/hooks/useDismiss.ts#L283
[fui-usedismiss-decl]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/react/src/hooks/useDismiss.ts#L519
[fui-focusmanager]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/react/src/components/FloatingFocusManager.tsx#L121
[fui-markothers]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/react/src/utils/markOthers.ts#L160
[fui-markothers-live]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/react/src/utils/markOthers.ts#L167
[fui-portal]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/react/src/components/FloatingPortal.tsx#L61
[fui-tree]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/react/src/components/FloatingTree.tsx#L85
[fui-nodes]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/react/src/utils/nodes.ts#L3
[fui-overlay]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/react/src/components/FloatingOverlay.tsx#L81
[fui-userole]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/react/src/hooks/useRole.ts#L33
[fui-userole-tooltip]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/react/src/hooks/useRole.ts#L70
[fui-istoplayer]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/utils/src/dom.ts#L77
[fui-usetransition]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/react/src/hooks/useTransition.ts#L58
[fui-floatingarrow]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/react/src/components/FloatingArrow.tsx#L55
[fui-ispositioned]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/react-dom/src/useFloating.ts#L99
[fui-coretest]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/core/test/computePosition.test.ts#L76
[fui-changelog]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/core/CHANGELOG.md
