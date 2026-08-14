# Radix Primitives (TypeScript / React)

Radix cuts the anchored-overlay problem into four separately-consumable mechanisms — geometry (`Popper`), dismissal (`DismissableLayer`), focus (`FocusScope`) and stacking escape (`Portal`) — and builds Tooltip, Popover, HoverCard, Menu, Select and NavigationMenu as thin compositions of them, so that every difference between those components lives in _how they compose_, not in shared branching.

| Field         | Value                                                                                                                                                                                                                                                                                                                                                                  |
| ------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language      | TypeScript (React 18/19), TSX; no runtime CSS                                                                                                                                                                                                                                                                                                                          |
| License       | MIT (Copyright (c) 2022 WorkOS) — [`LICENSE:1`][license]                                                                                                                                                                                                                                                                                                               |
| Repository    | [`radix-ui/primitives`][radix]                                                                                                                                                                                                                                                                                                                                         |
| Documentation | [radix-ui.com — Primitives docs][radix-docs]; in-repo [`philosophy.md`][philosophy]                                                                                                                                                                                                                                                                                    |
| Category      | Web / headless behavior                                                                                                                                                                                                                                                                                                                                                |
| Surface model | In-canvas only. Every overlay is a React portal into the same document (`document.body` by default). No OS popup, no `<dialog>`, no `popover` attribute, no [top layer][concepts], and no z-index assignment in the overlay stack — the positioned wrapper _reads back_ the content's computed `zIndex` and copies it onto itself ([`popper.tsx:301`][popper-zindex]). |
| Revision read | `f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae` (meta-package `radix-ui` 1.6.7; `react-popper` 1.3.7, `react-dismissable-layer` 1.1.19, `react-menu` 2.1.24, `react-tooltip` 1.2.16, `react-focus-scope` 1.1.16, `react-popover` 1.1.23, `react-hover-card` 1.1.23)                                                                                                         |

This is an implementation reading, not a docs reading: every claim below is anchored to source at that SHA. See [`./index.md`](./index.md) for the catalog and [`./concepts.md`](./concepts.md) for the shared vocabulary.

## Overview

### What it solves

Radix supplies the _behavior_ of anchored overlays with none of their appearance: placement against an [anchor rect][concepts], [light dismiss][concepts] with a layer stack, [focus scope][concepts] containment and restoration, portal-based escape from clipping and stacking ancestors, and exit-animation gating. There is no `AnchoredOverlay` component anywhere in the tree. `Tooltip`, `Popover`, `HoverCard`, `DropdownMenu`, `ContextMenu`, `Menubar`, `Select` and `NavigationMenu` are compositions over the four mechanisms plus `Presence`, `RovingFocusGroup` and `Collection`.

The absence is deliberate and load-bearing: `Select`'s `position="item-aligned"` mode needs `DismissableLayer` but not `Popper` at all ([`select.tsx:932`][select-itemaligned]); `Tooltip` needs `Popper` and `DismissableLayer` but never `FocusScope`; `Dialog` needs `FocusScope` and `DismissableLayer` but has no anchor. A monolith would have to branch on component identity at each of those points.

### Design philosophy

The stated philosophy is a 1-to-1 DOM strategy plus composable, _cancellable_ handlers:

> - We achieve this API with a 1-to-1 strategy, where a single component only renders a single DOM element (if a DOM node is rendered at all).
>
> — [`philosophy.md:41`][philosophy]

> - Just as DOM nodes are composable, so are DOM event handlers; consumers should be able to pass their own event handlers directly to a component and stop internal handlers from firing.
>
> — [`philosophy.md:45`][philosophy-handlers]

That second line is the architecture. Every cross-cutting decision is announced as a `cancelable: true` `CustomEvent` dispatched at the relevant DOM node — `dismissableLayer.pointerDownOutside`, `focusScope.autoFocusOnMount`, `menu.itemSelect`, `rovingFocusGroup.onEntryFocus`, `tooltip.open` — and `preventDefault()` is the universal veto ([`dismissable-layer.tsx:531`][dl-dispatch]). The actual _state_ is React `useState` plus a large number of mutable refs used as monotone latches; the only finite-state machine in the overlay stack is `Presence`'s three-state `useStateMachine` ([`presence.tsx:36`][presence]).

## How it works

A `Popover` is roughly eight lines of composition, and reading them names every mechanism:

```text
Popover.Root
└── Popper.Root                      // holds one `anchor: Measurable | null`
    ├── Popper.Anchor  (or the Trigger, if no custom anchor is mounted)
    └── Portal → Presence            // portal into document.body; gate exit animations
        └── RemoveScroll + hideOthers()          // modality, composed not built-in
            └── FocusScope  trapped={modal} loop // focus containment/restore
                └── DismissableLayer             // Escape + outside pointer/focus
                    └── Popper.Content           // the positioned wrapper + content
```

Placement itself is delegated: `Popper.Content` calls `useFloating` from `@floating-ui/react-dom` with `strategy: 'fixed'` and an explicitly ordered middleware array ([`popper.tsx:241`][popper-middleware]):

```text
offset({ mainAxis: sideOffset + arrowHeight, crossAxis: alignOffset })
shift({ mainAxis: true, crossAxis: false, limiter: sticky === 'partial' ? limitShift() : undefined })
flip({ ...detectOverflowOptions })
size({ ...detectOverflowOptions, apply: writes --radix-popper-available-{width,height} })
arrow({ element: arrow, padding: arrowPadding })
transformOrigin({ arrowWidth, arrowHeight })
hide({ strategy: 'referenceHidden', boundary: hasExplicitBoundaries ? boundary : undefined })
```

Each stage sees the previous stage's output; `flip` may change the placement, and everything downstream — arrow side, transform origin, `data-side` — reads the _final_ placement. The result is written as `transform: translate(x, y)` on a wrapper div marked `data-radix-popper-content-wrapper` ([`popper.tsx:309`][popper-wrapper]), which is a separate node from the content the consumer styles.

> [!IMPORTANT]
> Radix contributes the vocabulary, the middleware ordering and the exported metadata; the actual overflow detection, clipping-ancestor discovery, fractional-pixel arithmetic and fallback ordering live in `@floating-ui/react-dom`, which was **not** read for this page. See [`./floating-ui.md`](./floating-ui.md) for that half. Statements here about what `flip`, `shift`, `size`, `hide` and `autoUpdate` do internally are inferences from Radix's call sites and the documented middleware contract, not source readings.

## The analysis spine

### 1. Anchor model

The anchor is a _callable_, not a value: `type Measurable = { getBoundingClientRect(): DOMRect }` ([`observe-element-rect.ts:6`][measurable]). `Popper.Root`'s context holds exactly one `anchor: Measurable | null`. There are two registration paths. A real element registers through a **callback ref**, deliberately not an effect:

> React invokes callback refs during the commit phase which does not count toward the nested update depth limit, so mounting many Popper-based components at once doesn't trigger "Maximum update depth exceeded"
>
> — [`popper.tsx:100-105`][popper-anchor-cb] (issue #3858)

A [virtual anchor][concepts] arrives as `virtualRef?: React.RefObject<Measurable | null>`, diffed in an effect **with no dependency array** — re-checked on every render, comparing previous against current identity ([`popper.tsx:117-127`][popper-virtualref]). When `virtualRef` is supplied, `Popper.Anchor` renders `null` ([`popper.tsx:135`][popper-virtual-null]): the anchor is detached from the DOM entirely. `ContextMenu` builds a point anchor as a zero-size `DOMRect` at the cursor, memoized on the point so a second right-click at a new location re-anchors an already-open menu ([`context-menu.tsx:126`][ctx-virtual]). Detached trigger-vs-anchor is first-class in `Popover`: mounting a `PopoverAnchor` sets `hasCustomAnchor`, and the trigger then stops wrapping itself in `Popper.Anchor` ([`popover.tsx:172`][popover-anchor]).

Not supported anywhere in the tree: text-range multi-rect anchors, sub-region anchors, many-triggers-one-popup (each `Root` owns one anchor), and anchor-to-screen conversion — everything is viewport space via `strategy: 'fixed'`.

**Algorithm.** Anchor := a closure returning a viewport rect, re-read once per `autoUpdate` tick. A point anchor is a zero-width/height rect at (x, y). An identity change of the closure fires `onAnchorChange` and re-places. Treating an anchor as "a thing that provides a rect" is what makes element, virtual, point and moving anchors one code path.

**Where it lives.** `packages/core/rect` (the `Measurable` type), `packages/react/popper` (registration + context), each semantic component (which node plays anchor).

**Degradation.** The abstraction is substrate-independent. A closure is needed here only because the DOM can move a node without telling anyone; a toolkit that re-derives every rect from a layout pass each frame gets freshness by construction, and the anchor can be a plain comparable value. Point anchors and widget anchors unify trivially at integer-cell granularity. On a script-free static-HTML target there is no anchor computation at all — the popup must be a DOM sibling of the trigger, positioned by CSS. Nothing in this dimension needs hover, key release, an OS window or sub-cell precision.

### 2. Placement model

Radix owns the vocabulary and delegates the solver. `SIDE_OPTIONS = ['top','right','bottom','left']` and `ALIGN_OPTIONS = ['start','center','end']` ([`popper.tsx:25`][popper-sides]) are joined into a Floating UI placement string: `side + (align !== 'center' ? '-' + align : '')` ([`popper.tsx:211`][popper-desired]). `sideOffset` defaults to `0` ([`popper.tsx:187`][popper-sideoffset]) — the overlay sits flush against its anchor unless told otherwise.

The vocabulary is physical, not logical, but Floating UI resolves `start`/`end` against the `dir` attribute, which is why Radix stamps `dir` on the _wrapper_ div: "Floating UI internally calculates logical alignment based the `dir` attribute … we must add this attribute here to ensure this is calculated when portalled as well as inline" ([`popper.tsx:328`][popper-dir]). RTL for submenus is handled by Radix itself rather than the solver — `side={rootContext.dir === Direction.RTL ? 'left' : 'right'}` ([`menu.tsx:1245`][menu-sub-side]) — and the open/close keys swap with it (`SUB_OPEN_KEYS`/`SUB_CLOSE_KEYS`, [`menu.tsx:41`][menu-subopenkeys]).

Three constraints on the exposed surface are worth recording. No preferred-placement _list_ is forwarded, so a consumer cannot say "try bottom, then right, then top". [`shift`][concepts] is configured **main-axis only, cross-axis off**, with `limitShift()` when `sticky === 'partial'` and no limiter when `sticky === 'always'` ([`popper.tsx:244`][popper-shift]) — a deliberate choice that keeps the popup visually attached to its side rather than an oversight. And `avoidCollisions` gates [flip][concepts] and shift together: neither is available without the other. `collisionPadding` is a number or a per-side record; `collisionBoundary` is `Element | Element[]`, and when non-empty `altBoundary: true` is set because "with `strategy: 'fixed'`, this is the only way to get it to respect boundaries" ([`popper.tsx:225`][popper-altboundary]).

Absent from the whole `packages` tree: writing modes beyond `dir`, safe-area insets, work areas, multi-monitor, and IME/virtual-keyboard avoidance. `Select`'s `position="item-aligned"` bypasses `Popper` entirely and reimplements placement against `window.innerWidth/innerHeight` with a hardcoded `CONTENT_MARGIN = 10` ([`select.tsx:583`][select-margin], [`:932`][select-itemaligned]).

**Where it lives.** Vocabulary and middleware ordering in `packages/react/popper`; the solver in `@floating-ui/react-dom`; RTL side selection for submenus in `packages/react/menu`; a parallel, non-`Popper` positioner in `packages/react/select`.

**Degradation.** The vocabulary and the ordered pipeline carry to integer cells unchanged; only the solver's internals are DOM-bound. Two inputs Radix has no concept of would have to be added rather than discovered: an asymmetric viewport inset (a soft keyboard, a reserved status line) generalising `collisionPadding` into per-side insets, and the observation that a single-surface toolkit has exactly one "monitor", which deletes a class of problems Radix inherits. On static HTML there is no flip or shift at emit time: one committed side, and clipping accepted.

### 3. Collision & geometry engine

Overflow detection, [clipping-boundary][concepts] discovery, scroll-container awareness, transform/zoom handling and fractional-pixel arithmetic are all delegated. Radix contributes configuration, tracking policy and two hacks.

Tracking is `whileElementsMounted: autoUpdate(..., { animationFrame: updatePositionStrategy === 'always' })` ([`popper.tsx:232`][popper-autoupdate]) — the default `'optimized'` mode uses observers and listeners; `'always'` degrades to a per-frame `requestAnimationFrame` loop. Radix's own `observeElementRect` (used by `useRect`, not by `Popper`) is an unconditional shared rAF loop over a module-level `Map`, structured read-all-then-write-all to avoid layout thrash ([`observe-element-rect.ts:72`][rect-observe]). `useSize` — the arrow measurement — is a `ResizeObserver` whose callback is wrapped in `requestAnimationFrame` specifically to suppress the "ResizeObserver loop completed with undelivered notifications" error ([`use-size.tsx:14`][usesize]).

Two hacks are the price of the wrapper/content split. The wrapper copies the _content's_ computed `zIndex` onto itself, because the wrapper is the positioned element but consumers style the content ([`popper.tsx:301`][popper-zindex]). And the `size()` middleware writes four CSS custom properties **directly to `elements.floating.style`** rather than into React state ([`popper.tsx:251`][popper-size]) — an imperative DOM write from inside the layout pipeline, chosen so that resizing costs no render.

`hideWhenDetached` uses `hide({ strategy: 'referenceHidden' })` and deliberately passes `boundary: undefined` when the consumer gave no explicit boundary, so detach detection falls back to _clipping ancestors_ while collision and size keep the viewport default ([`popper.tsx:264`][popper-hide]). The split is stated in a comment and pinned in both directions by Playwright specs ([`e2e/popper.spec.ts:17`][e2e-popper]).

**Algorithm.** Per tick: read the anchor rect and floating rect, run the middleware chain, produce `{x, y, placement, middlewareData}`, write `transform: translate(x, y)` on the wrapper. Placement is not committed until `isPositioned`; before that the wrapper is parked at `translate(0, -200%)` — laid out and therefore measurable, but off-page.

**Degradation.** What generalises is the _shape_: an ordered pipeline of pure functions over `{anchorRect, popupRect, placement, boundary}`, each returning an offset delta plus optional data. What does not generalise is clipping-ancestor discovery (a single-surface toolkit has an explicit clip stack, so the boundary is a parameter rather than a search), `IntersectionObserver` and `getComputedStyle`. Tracking collapses if layout already runs every frame: `autoUpdate`, `observeElementRect` and `useSize` all become "next frame". The `--radix-popper-available-width/height` idea survives as a value handed to the popup's own layout so it can shrink or scroll itself. On static HTML there is no collision detection at emit time at all.

### 4. Arrow / caret geometry

Arrow geometry is treated as data and never as styling. The visual is a trivial SVG — `viewBox="0 0 30 10"`, `preserveAspectRatio="none"`, `<polygon points="0,0 30,0 15,10"/>`, default 10×5 ([`arrow.tsx:14`][arrow-svg]) — a rasterisation detail the geometry never depends on.

The geometry comes from Floating UI's `arrow({ element, padding: arrowPadding })`, which yields `middlewareData.arrow.{x, y, centerOffset}`. A non-zero `centerOffset` means the arrow could not be centred on the anchor (it hit the corner clamp), which becomes `cannotCenterArrow` ([`popper.tsx:299`][popper-cannotcenter]) and then `visibility: hidden` — Radix suppresses the arrow rather than clamping it and lying about where the anchor is. Arrow _size_ feeds placement: `offset({ mainAxis: sideOffset + arrowHeight })` ([`popper.tsx:242`][popper-offset]), and `arrowHeight` comes from a `ResizeObserver` on a wrapper `<span>` ([`popper.tsx:207`][popper-arrowsize]) that exists only because

> `ResizeObserver` (used by `useSize`) doesn't report size as we'd expect on SVG elements. it reports their bounding box which is effectively the largest path inside the SVG.
>
> — [`popper.tsx:385-387`][popper-arrowspan]

so arrow measurement is a genuine second pass. Positioning is `position: absolute; left: arrowX; top: arrowY;` plus `[OPPOSITE_SIDE[placedSide]]: 0` and a per-side rotation table ([`popper.tsx:367`][popper-opposite]). No border-aware arrow (no stroke/seam handling), and no arrow animation or detachment.

**Algorithm.** (1) Measure the arrow. (2) Add its height to the main-axis offset. (3) The solver returns the arrow's cross-axis position clamped by `arrowPadding` from the popup's corners, plus `centerOffset`, the residual it could not satisfy. (4) `centerOffset !== 0` hides the arrow _and_ changes the [transform origin][concepts] to a categorical fallback. (5) Otherwise the origin is the arrow's centre on the cross axis.

**Degradation.** The data model — side, cross-axis offset, visible — is what ports. On a cell grid an arrow is one glyph in the popup's border row or column, so `arrowHeight` is a constant known before layout and the two-pass measurement Radix needs disappears. Whether suppression (Radix's rule) or clamping is right at cell granularity is an open question this page cannot settle from Radix alone — see [`./comparison.md`](./comparison.md); the corpus's px-based subjects split on it. On static HTML the arrow can only be a fixed-align pseudo-element, since the offset cannot be computed.

### 5. Trigger semantics

There is no unified trigger primitive, and that is the finding: each component hand-writes its trigger, and every difference is deliberate.

- **Tooltip** opens on `pointerMove`, not `pointerenter`, early-returning for `pointerType === 'touch'`, and guarded by two latches: `hasPointerMoveOpenedRef`, so continued movement does not re-fire, and the provider's `isPointerInTransitRef`, so a tooltip cannot open while another tooltip's [safe polygon][concepts] is live ([`tooltip.tsx:300`][tooltip-trigger-move]). Focus opens only `if (!isPointerDownRef.current)` — a hand-rolled `:focus-visible` approximation whose flag is set on `pointerdown` and cleared by a one-shot document `pointerup` ([`tooltip.tsx:279`][tooltip-pointerdownref], read at [`:321`][tooltip-focus]). Click and blur always close.
- **HoverCard** uses `pointerEnter`/`pointerLeave` wrapped in `excludeTouch`, plus `onTouchStart={e => e.preventDefault()}` to suppress the synthetic focus a tap generates ([`hover-card.tsx:138`][hovercard-trigger]).
- **DropdownMenu** opens on `pointerDown` with `event.button === 0 && !event.ctrlKey` (macOS ctrl-click is a right click) and preventDefaults so "the content [can] be given focus without competition" ([`dropdown-menu.tsx:125`][dropdown-trigger]).
- **ContextMenu** uses the `contextmenu` event plus a hand-rolled 700 ms long-press timer armed on `pointerdown` for touch/pen only and cancelled by move/up/cancel ([`context-menu.tsx:181`][ctx-longpress]); `WebkitTouchCallout: 'none'` suppresses the iOS native menu ([`:157`][ctx-callout]).
- **Menubar** switches menus on `pointerEnter`, but only when a menubar menu is already open ([`menubar.tsx:255`][menubar-enter]).
- **MenuItem/SubTrigger** focus on `pointerMove`, explicitly not `mouseenter`, so that after the keyboard has moved focus elsewhere a mere mouse _wiggle_ re-focuses the item under the cursor, "to match native menu implementation" ([`menu.tsx:782`][menu-itemmove]).

Races are resolved with refs-as-latches read _before_ acting, not with a machine. Global input modality is one such latch: a capture-phase document `keydown` sets `isUsingKeyboardRef = true`, and `{once: true}` capture listeners on both `pointerdown` and `pointermove` clear it ([`menu.tsx:101`][menu-keyboard]). That single bit decides whether opening a menu focuses its first item.

**Algorithm.** Each trigger is a handler bundle over a shared open/close pair, with per-source suppression predicates — `whenMouse(h)` ([`menu.tsx:1381`][menu-whenmouse], duplicated verbatim at `navigation-menu.tsx:1364`) and `excludeTouch(h)` ([`hover-card.tsx:392`][hovercard-excludetouch]). Cross-source races are prevented by monotone latches: pointer-down suppresses focus-open, pointer-in-transit suppresses hover-open, keyboard modality gates auto-focus.

**Where it lives.** Entirely in the semantic components. `DismissableLayer`, `FocusScope` and `Popper` know nothing about triggers.

**Degradation.** The latch discipline survives value semantics perfectly — the latches are fields of a state struct. The _sources_ do not survive uniformly. A target with no key release forbids any keyboard press-and-hold affordance (pointer press/release is a separate capability). A target with no hover must replace hover triggers with tap or long-press and must accept a system Back key as a dismissal source. A script-free HTML target has no timers and no latches: only `:hover`, `:focus-within` and `<details>`/`:checked` can trigger anything, which leaves exactly one trigger per popup and no pointer-type distinction. Radix itself cannot distinguish "why is this open" beyond these latches, since it stores no open-cause value.

### 6. Timing

Three independent timing systems, none shared.

**Tooltip** is the most developed. A per-root `delayDuration` (default 700 ms, [`tooltip.tsx:30`][tooltip-delay]) and a provider-scoped `skipDelayDuration` (default 300 ms, [`:71`][tooltip-skip]) implement a [warm-up][concepts] and a [cool-down][concepts]. `isOpenDelayedRef` starts `true`; opening clears the skip timer and sets it `false`; closing starts a `skipDelayDuration` timer that flips it back ([`:89`][tooltip-onopen]). Both callbacks early-return when `skipDelayDuration <= 0`, so the flag never leaves `true`:

```ts
onOpen={React.useCallback(() => {
    if (skipDelayDuration <= 0) return;
    window.clearTimeout(skipDelayTimerRef.current);
    isOpenDelayedRef.current = false;
}, [skipDelayDuration])}
```

That early return is the fix for issue #3873 and is pinned by a regression test asserting that with `skipDelayDuration={0}` moving to a second trigger yields `data-state="closed"` then `"delayed-open"` ([`tooltip.test.tsx:380`][tooltip-test-skip]). A zero-length timer would not have worked, because the flag would still flip for one tick — the correct shape is a static predicate, not a shorter timer.

`wasOpenDelayedRef` produces a three-valued `data-state`: `closed | delayed-open | instant-open` ([`tooltip.tsx:191`][tooltip-state]), exporting timing to the styling layer so a theme can decline to replay an enter animation. The group singleton is a broadcast rather than a registry: opening dispatches a plain `tooltip.open` `CustomEvent` on `document` ([`:183`][tooltip-broadcast]) and every mounted content closes itself ([`:529`][tooltip-singleton]).

**HoverCard** has `openDelay = 700`, `closeDelay = 300`, and two timers where open cancels close and vice versa; closing is additionally _suppressed_ while a text selection exists or the pointer is down on the content ([`hover-card.tsx:75`][hovercard-timers]). The "sweep across a list of triggers" regression (#1248) is pinned by a test that enters and leaves three triggers for 200 ms each and asserts none opens ([`hover-card.test.tsx:77`][hovercard-test-sweep]).

**Submenu** uses a 100 ms open timer armed on `pointermove` over the `SubTrigger` ([`menu.tsx:1126`][menu-subopen-timer]) plus a 300 ms grace expiry ([`:1157`][menu-grace-expiry]). **Typeahead** self-reschedules a 1000 ms buffer reset ([`menu.tsx:447`][menu-typeahead]); its matcher carries two non-obvious rules that are what make it feel native ([`getNextMatch`, `menu.tsx:1336`][menu-nextmatch]): a buffer of identical characters is normalised to one character so `aaa` cycles through items starting with `a`, and the current match is removed from the candidate list _only_ for single-character searches, so refining a multi-character search cannot jump off an item that still matches. The candidate list is first rotated to start at the current match, so the search always looks forward. **NavigationMenu** has its own `delayDuration = 200` and its own skip and close timers ([`navigation-menu.tsx:136`][navmenu-delay]). There is no maximum display duration anywhere in the stack.

**Degradation.** Timing is the dimension a frame-loop toolkit finds _easier_: every `setTimeout` becomes a deadline field compared against the frame clock, which makes the machine a pure function of (state, now, event) and assertable by stepping a synthetic clock. It presupposes a frame clock that ticks while idle. A script-free HTML target has no timers, so delay, skip-delay and close-delay all collapse and only `:hover` survives; a hover-less target loses the entire hover-timing machine, since tap-toggle has no delay.

### 7. Interactive hover

Two independent grace algorithms, in two packages, with `isPointInPolygon` copy-pasted byte-for-byte into both ([`tooltip.tsx:682`][tooltip-inpoly], [`menu.tsx:1356`][menu-inpoly]) along with duplicate `Point`/`Polygon` types.

**(A) Tooltip hoverable content — convex hull.** On `pointerleave` of the trigger or the content, compute the exit point; classify the exit _side_ as the nearest of the four rect edges by absolute distance (`getExitSideFromRect`, [`tooltip.tsx:619`][tooltip-exitside]); emit two points 5 px _inside_ the leaving rect on that side (`getPaddedExitPoints`, [`:639`][tooltip-padded]); take the four corners of the **other** element's rect; and compute the convex hull of the resulting six points with Andrew's monotone chain, credited in a comment to Nayuki's public implementation ([`:703`][tooltip-hull]). A document `pointermove` listener then clears the area when the pointer re-enters trigger or content, and clears _and closes_ when it leaves the hull ([`:430`][tooltip-grace]). While an area exists, `isPointerInTransitRef` is true provider-wide, blocking sibling tooltips from opening. `disableHoverableContent` swaps the entire `TooltipContentHoverable` wrapper out for the plain impl ([`:394`][tooltip-hoverable-switch]) — a component-level switch, not a flag.

> [!NOTE]
> Radix's tooltip hull is `hull(padded exit points ∪ corners of the other rect)` — the anchor rect never enters the hull, only the 5-px-padded exit point does. That is a different region from `hull(anchor rect ∪ overlay rect)`; see [`./comparison.md`](./comparison.md) for how the corpus splits on this.

**(B) Submenu — trapezoid plus direction gate.** On `pointerleave` of a `SubTrigger` with an open submenu, Radix builds a five-point polygon from the exit point plus the submenu's four corners, ordered near-top, far-top, far-bottom, near-bottom, where "near/far" is chosen from the placed side:

```tsx
contentContext.onPointerGraceIntentChange({
  area: [
    // Apply a bleed on clientX to ensure that our exit point is
    // consistently within polygon bounds
    { x: event.clientX + bleed, y: event.clientY },
    { x: contentNearEdge, y: contentRect.top },
    { x: contentFarEdge, y: contentRect.top },
    { x: contentFarEdge, y: contentRect.bottom },
    { x: contentNearEdge, y: contentRect.bottom },
  ],
  side,
});
```

— [`menu.tsx:1144-1155`][menu-poly]

The bleed is `rightSide ? -5 : +5`, i.e. _away_ from the submenu, so the exit point is unambiguously interior and the ray-cast is never evaluated on the boundary. The placed side is read back out of `content.dataset.side`, carrying a standing `TODO: make sure to update this when we change positioning logic`. The intent is stored as `{area, side}` and expires after 300 ms regardless of pointer position.

The polygon alone is not sufficient. Every item `pointermove` asks:

```tsx
const isMovingTowards =
  pointerDirRef.current === pointerGraceIntentRef.current?.side;
return (
  isMovingTowards &&
  isPointerInGraceArea(event, pointerGraceIntentRef.current?.area)
);
```

— [`menu.tsx:481-482`][menu-movingto]

`pointerDirRef` is a one-bit horizontal latch updated on the content's `pointermove`:

```tsx
const pointerXHasChanged = lastPointerXRef.current !== event.clientX;

// We don't use `event.movementX` for this check because
// Safari will always return `0` on a pointer event.
if (event.currentTarget.contains(target) && pointerXHasChanged) {
  const newDir = event.clientX > lastPointerXRef.current ? 'right' : 'left';
  pointerDirRef.current = newDir;
  lastPointerXRef.current = event.clientX;
}
```

— [`menu.tsx:596-604`][menu-guard]

> [!WARNING]
> `pointerXHasChanged` is an exact-inequality test, so it is a **zero-delta guard**, not a jitter filter: a ±1 px sample passes it and flips the latch. What it suppresses is the zero-delta sample, which the ternary would otherwise classify as `'left'` (since `clientX > lastPointerX` is false when they are equal) — so a purely vertical move down a menu cannot silently latch the wrong direction. Any port that quantises positions makes zero-delta samples _more_ common, not less, so the guard becomes more load-bearing under quantisation, not redundant.

When grace holds, `onItemEnter` preventDefaults (the item does not steal focus), `onItemLeave` returns early (the content does not refocus) and `onTriggerLeave` preventDefaults. Each `MenuContent` owns its own grace intent, so nesting works. The e2e suite pins all four quadrants including the RTL mirror and the collision-flipped case at a 550 px viewport ([`e2e/dropdown-menu.spec.ts:34`][e2e-dropdown]).

**Degradation.** Both algorithms are pure geometry over two rects and a point; the only DOM contact is `getBoundingClientRect` and the `dataset.side` read-back, which vanishes when the placed side is a value the overlay already holds. They need hover, a pointer-move stream and a clock — so they degrade to nothing on a touch target (with touch, a submenu opens on tap and stays until dismissed, so there is no travel to protect) and to a crude CSS `:hover` region on static HTML. The document-level `pointermove` listener is the one piece that assumes global event capture; a toolkit that routes its own events can run the same predicate against its last painted frame instead. Cost figures for either algorithm are analytical, not measured: Radix ships no benchmarks for these paths.

### 8. Dismissal

`DismissableLayer` is the single place, and it is considerably subtler than "close on outside click".

**Escape** is handled only by the highest layer: `isHighestLayer = index === layers.length - 1` ([`dismissable-layer.tsx:145`][dl-highest]), and the capture-phase `keydown` listener is attached only when that holds. On dismissal it also preventDefaults the key event; submenus additionally preventDefault "to ensure pressing escape in submenu doesn't escape full screen mode" ([`menu.tsx:1262`][menu-escape]). The handler is stabilised with `useCallbackRef` rather than React's `useEffectEvent`, because the latter "returns a stale closure inside `forwardRef` components on React 19.2.x".

**Outside pointer** dismissal defaults to immediate on `pointerdown`. With `deferPointerDownOutside` — which `Popover` sets ([`popover.tsx:489`][popover-defer]) — and `button === 0`, dismissal is armed and committed on the subsequent `click`:

```tsx
if (!deferPointerDownOutside || event.button !== 0) {
  handleAndDispatchPointerDownOutsideEvent();
} else {
  ownerDocument.removeEventListener('click', handleClickRef.current);
  handleClickRef.current = handleAndDispatchPointerDownOutsideEvent;
  ownerDocument.addEventListener('click', handleClickRef.current, {
    once: true,
  });
}
```

— [`dismissable-layer.tsx:426-432`][dl-defer]

and is _cancelled_ if any of `pointerup | mousedown | mouseup | touchstart | touchend | click` was intercepted between capture and bubble. Interception is a per-event-type ledger: a capture listener marks the type `true` ([`:342`][dl-capture]), a bubble listener marks it `false`, and anything still `true` at commit time drops the dismissal ([`:328`][dl-ledger]). This exists so that browser-extension overlays which `stopPropagation()` cannot silently swallow a dialog's dismissal (#2055), and so that touch's click delay cannot re-enable pointer events too early. Non-primary buttons dismiss immediately, because no click is guaranteed.

`dismissableSurfaces` ([`:281`][dl-surface], #3346) exempt a registered node — a dialog's own overlay, say — from that veto, so a dismiss affordance that legitimately stops propagation still dismisses. **Branches** are nodes outside the layer's DOM subtree that must count as _inside_. **Focus outside** is a document `focusin`, skipped while a deferred interaction is in flight and when the target is in a branch. **Nesting** falls out of the pointer-events index: lower layers see `isPointerEventsEnabled === false` and therefore treat nothing as outside, so a child layer dismissing does not also dismiss its deferred parent ([`dismissable-layer.test.tsx:401`][dl-test-child], #3971).

Other sources are per-component, never shared: window `blur` closes menus and every submenu ([`menu.tsx:131`][menu-blur], #3257); a capture-phase `scroll` on any ancestor containing the trigger closes a tooltip ([`tooltip.tsx:534`][tooltip-scroll]) — capture phase because scroll does not bubble, with a containment test so unrelated scroll containers are ignored; a parent menu closing force-closes its submenu ([`menu.tsx:1029`][menu-subclose]); and `hideWhenDetached` hides without closing. There is no navigation, resize or app-deactivation dismissal beyond window blur.

**Algorithm.** Registry: `layers` (insertion-ordered), `layersWithOutsidePointerEventsDisabled`, `branches`, `dismissableSurfaces`. `isTop = indexOf(self) === len - 1`; `pointerEventsEnabled = indexOf(self) >= indexOf(last(disabledSet))`. On an outside pointerdown: ignore if not pointer-events-enabled or the target is in a branch; dispatch immediately if not deferring or not the primary button; otherwise arm, and on click commit iff no intercepted type remains `true`. Escape: only `isTop` dispatches. Every dispatch is a cancelable `CustomEvent` and `preventDefault()` suppresses `onDismiss`.

**Degradation.** The layer stack and the top-only-Escape rule are cheap and substrate-independent. The capture-vs-bubble ledger has no analogue outside a system where the library does not own event dispatch — a toolkit that routes its own events can answer "did any handler consume this?" with one bit. The outer rule still matters: arm on press, commit on release, cancel if the gesture became a drag or a scroll. A target without a reliable release edge must default to dismiss-on-press with an explicit "pressed inside, released outside" exemption. A system Back key is a dismissal source Radix has no concept of. On static HTML there is no light dismiss at all — a `<details>` toggle or un-hovering is the whole vocabulary, so any emitted popup needs a visible close affordance.

### 9. Focus

Radix keeps tooltip, hovercard, popover, menu and dialog rigorously distinct, and the distinctions are structural rather than flags.

- **Tooltip** is never focused and never focusable; `onFocusOutside` is unconditionally preventDefaulted.
- **HoverCard** content is reachable in DOM order but every tabbable descendant is forcibly set to `tabindex="-1"` on every render ([`hover-card.tsx:324`][hovercard-tabindex]) — deliberate de-tabbing, and the reason genuinely interactive content does not belong in a hover card.
- **Popover** wraps `FocusScope loop trapped={context.open}` in modal mode and `trapped={false}` otherwise. Modal restores focus to the trigger unless the outside interaction was a right-click (`isRightClickOutsideRef`, [`popover.tsx:306`][popover-rightclick]); non-modal restores only if there was no outside interaction and _always_ preventDefaults the scope's own restore, so the choice is explicit ([`:350`][popover-nonmodal-restore]).
- **Menu** is trapped only when modal; `onMountAutoFocus` is preventDefaulted and the _content_ is focused (`tabIndex=-1`, `outline: none`), leaving item focus to `RovingFocusGroup`, whose `onEntryFocus` is preventDefaulted unless `isUsingKeyboardRef` — so a mouse-opened menu focuses no item while a keyboard-opened one focuses the first ([`menu.tsx:545`][menu-entryfocus]). `Tab` is preventDefaulted inside a menu.

`FocusScope` itself is a module-level stack where `add` pauses the previously-active scope and `remove` resumes the new top ([`focus-scope.tsx:420`][fs-stack]), so exactly one scope enforces containment at a time; every handler begins with `if (focusScope.paused) return` ([`focus-scope.tsx:101`][fs-trap]). The trap is `focusin` + `focusout` document listeners, and `focusout` with `relatedTarget === null` is deliberately ignored, because it means either a window blur (the browser remembers) or a removed node, and

> In Google Chrome, when the focused element is removed from the DOM … if we try to focus the deleted focused element … it throws the CPU to 100%
>
> — [`focus-scope.tsx:117-131`][fs-focusout]

The removal case is handled instead by a `MutationObserver`: if `document.activeElement === document.body` after a mutation with `removedNodes`, refocus the container ([`:144`][fs-mutations]). Mount and unmount focus are announced as cancelable `focusScope.autoFocusOnMount` / `autoFocusOnUnmount` events ([`:165`][fs-autofocus]); Tab looping computes the first and last visible tabbables and, at an edge, wraps if `loop` or stays put if trapped without loop ([`:205`][fs-tabloop]). Tabbable discovery is a `TreeWalker` over `node.tabIndex >= 0`:

> `.tabIndex` is not the same as the `tabindex` attribute. It works on the runtime's understanding of tabbability, so this automatically accounts for any kind of element that could be tabbed to.
>
> — [`focus-scope.tsx:351-353`][fs-tabbable]

with the accompanying admission that the result is "only a close approximation". `findVisible` prefers native `element.checkVisibility({ checkVisibilityCSS: true })` over per-ancestor `getComputedStyle`, explicitly to avoid forced style recalculation caused by sibling effects ([`:367`][fs-checkvis]). A separate `FocusScopeBranchRegistry` ([`:258`][fs-branches]) lets portalled descendants of a modal layer count as in-scope.

**Degradation.** The _policy table_ — tooltip never focused; hovercard visible but not tabbable; popover contained or trapped by modality with an explicit restore decision; menu roving-focused with Tab suppressed and the first item focused only when keyboard-opened — is the transferable artifact. Most of the _mechanism_ is DOM tax: a toolkit that owns its widget tree knows what is focusable without a `TreeWalker`, has no `focusout(relatedTarget = null)` ambiguity, and needs no `MutationObserver` or `checkVisibility`. The pause/resume stack must be kept: nested overlays each wanting to trap is a real problem on any substrate. Note that Radix's trapped-without-loop behavior — stay put at the edge — is a distinct outcome from wrapping, and a focus model whose only move is "wrap" cannot express it. A target without a Tab key must drive focus by pointer and by Back; static HTML keeps only `:focus-within`.

### 10. Layering & portals

`Portal` is about twelve lines of substance: `ReactDOM.createPortal(<Primitive.div/>, container ?? document.body)`, gated behind a `mounted` layout-effect flag so SSR renders nothing ([`portal.tsx:19`][portal]). That is the _entire_ clipping and stacking escape mechanism — no top layer, no `<dialog>`, no `popover` attribute, no z-index assignment.

Ownership lives in the `DismissableLayer` context, and it is four insertion-ordered Sets in one module-global:

```tsx
const DismissableLayerContext = React.createContext({
  layers: new Set<DismissableLayerElement>(),
  layersWithOutsidePointerEventsDisabled: new Set<DismissableLayerElement>(),
  branches: new Set<DismissableLayerBranchElement>(),

  // Outside elements that belong to a layer's own dismiss affordance (eg, a
  // dialog overlay). Pressing them should dismiss the layer regardless of
  // whether or not they stop propagation.
  dismissableSurfaces: new Set<DismissableLayerBranchElement>(),
});
```

— [`dismissable-layer.tsx:16-27`][dl-context]

Layer identity is the DOM node, ordering is creation order, and "inside" is a `contains()` scan. The ordering invariant is stated explicitly and is the one most naive layer stacks get wrong:

> We purposefully prevent combining this effect with the `disableOutsidePointerEvents` effect because a change to `disableOutsidePointerEvents` would remove this layer from the stack and add it to the end again so the layering order wouldn't be _creation order_. We only want them to be removed from context stacks when unmounted.
>
> — [`dismissable-layer.tsx:204-209`][dl-order-comment]

Cross-layer invalidation is a document-level `dismissableLayer.update` `CustomEvent` that every layer answers with a forced re-render ([`:526`][dl-update]) — a global broadcast rather than a targeted update. Because a portal appends to the end of `document.body`, focus guards must be re-asserted after each mount; `useFocusGuards` caches a shared start/end guard pair at module scope and only touches the DOM when the edge invariant is actually broken, because writing to `body` "dirties layout and forces a synchronous reflow once sibling effects read layout (Popper measuring, react-remove-scroll, aria-hidden, FocusScope)" ([`focus-guards.tsx:26`][guards], #2812).

**Algorithm.** The overlay tree is one flat insertion-ordered list plus two overlay sets and a branch set. Front-to-back is list order. Membership changes broadcast a global invalidation. A **branch** is a node that is a logical descendant of a layer but a DOM sibling — the only construct that recovers tree structure from a flat portal world.

**Degradation.** Where there is no top layer and no stacking context, paint order _is_ layer order, so the `layers` Set becomes the paint list and the broadcast becomes unnecessary if every frame recomputes. `Portal` has no analogue where there is nothing to escape from. The **branch** concept, however, is the part worth keeping, and Radix's own history is the argument: parentage was re-invented twice, independently, as two unrelated registries — `DismissableLayer` branches for "is this press inside?" (#3346) and `FocusScope` branches for "may focus live here?" (#3423) — because a flat list lost the overlay tree. One parent link on the overlay record answers both.

### 11. Modality

[Modality][concepts] is a _composition_ of four independent tools rather than a mode:

1. `disableOutsidePointerEvents` sets `document.body.style.pointerEvents = 'none'` once, refcounted through `layersWithOutsidePointerEventsDisabled`, with each layer setting its own `pointerEvents: index >= highestDisabledIndex ? 'auto' : 'none'` ([`dismissable-layer.tsx:96`][dl-pointerevents], [`:102`][dl-enabled]).
2. `hideOthers()` from the `aria-hidden` package, described at its call site as a "better supported equivalent to setting `aria-modal`" ([`popover.tsx:285`][popover-hideothers]).
3. `RemoveScroll` with `shards` covering the content and every registered branch ([`popover.tsx:289`][popover-removescroll]).
4. The focus trap itself.

`Menu` ties modality to `modal` (default `true`) and even derives `isModal = Boolean(trapFocus || disableOutsideScroll)` locally ([`menu.tsx:419`][menu-ismodal]); `Popover` defaults to `false`. There is no scrim in Popover, Menu, HoverCard or Tooltip — only `Dialog` has an `Overlay` part — so the dim is a component concern rather than a modality concern. Keyboard is not blocked by modality: only the focus trap prevents Tab escaping, and Escape is gated to the top layer.

The cost is documented honestly in the prop's own doc comment:

> Users will need to click twice on outside elements to interact with them: once to close the DismissableLayer, and again to trigger the element
>
> — [`dismissable-layer.tsx:32-36`][dl-doc-disable]

> [!NOTE]
> Deriving the blocking index from the open set is not by itself a guarantee of correctness. Radix recomputes `highestLayerWithOutsidePointerEventsDisabledIndex` per render and still shipped issue #3645, where removal from the disabled set happened only on unmount: toggling the prop on an open layer could leave `body { pointer-events: none }` when multiple layers overlapped. The fix keeps the removal on the prop change ([`dismissable-layer.tsx:180-202`][dl-3645]).

**Algorithm.** `modal := trapFocus ∧ blockOutsidePointer ∧ hideFromA11yTree ∧ lockScroll` — four independent booleans that happen to be set together. Outside-pointer blocking is expressed as "body off, then every layer at or above the highest modal layer turns itself back on", which yields the right behavior for a non-modal popup opened _above_ a modal one at no extra cost.

**Degradation.** The four-booleans decomposition and the `index >= highestBlockingIndex` rule are the transferable parts; the second is a two-line integer comparison over a reverse-paint-order hit list. `body { pointer-events: none }` has no analogue and needs none — and the "click twice" cost it imposes is avoidable where the toolkit routes its own events, because a dismissing press can also be forwarded to its target, which the DOM cannot do. A Back key must interact with modality on a target that has one. On static HTML modality is unrepresentable: no blocking, no trap, no scroll lock.

### 12. Adaptive presentation

Absent by design, and the absence is the finding. A repository-wide grep across `packages/**/*.ts(x)` for `visualViewport`, `safe-area`, `env(safe`, `virtualKeyboard`, `matchMedia`, `prefers-reduced-motion`, `pointer: coarse`, `any-hover` and `writingMode` returns zero hits. There is no popover-to-sheet transformation, no teaching-tip variant, no keyboard-driven relocation and no responsive breakpoint anywhere in the overlay stack.

Every touch adaptation Radix ships is _negative_ — a suppression rather than a substitution: `whenMouse(h)`, `excludeTouch(h)`, `if (event.pointerType === 'touch') return` ([`tooltip.tsx:300`][tooltip-trigger-move]), `onTouchStart={e => e.preventDefault()}` to kill tap-induced focus, and `WebkitTouchCallout: 'none'` ([`context-menu.tsx:157`][ctx-callout]). The single positive adaptation in the subject is `ContextMenu`'s hand-rolled 700 ms long-press ([`:181`][ctx-longpress]) — and a context menu was never a hover trigger. The consequence is that on a touch device a Tooltip and a HoverCard simply never open, and Radix treats that as correct; any real adaptation decision belongs to the consumer's application code.

**Algorithm.** None exists. The nearest thing is the two suppression combinators, both one-liners over `event.pointerType`.

**Where it lives.** Nowhere central — distributed as per-component suppressions in `tooltip`, `hover-card`, `menu` and `context-menu`. The only environment context in the whole tree is `useDirection`.

**Degradation.** This is the dimension a multi-target toolkit cannot copy, because its targets differ more than a phone differs from a desktop browser. Radix's implicit answer — hover surfaces just do not exist on touch — becomes "tooltips never appear" on a hover-less target, which is a product hole rather than a policy. What Radix _does_ establish, by counterexample, is that per-component suppression does not scale: five components each independently suppress touch, and none of them can substitute. A capability record supplied as an input to the view (hover, timers, key release, pointer count, viewport insets) is the shape Radix lacks; see [`./proposal.md`](./proposal.md) and [`../platform-ui-guidelines/index.md`](../platform-ui-guidelines/index.md).

### 13. Accessibility

The primitive/semantic split is clean: `DismissableLayer`, `FocusScope`, `Popper`, `Portal` and `Presence` carry zero ARIA — not one role, label or `aria-*` attribute among them. Every semantic bit lives in the composing component.

**Tooltip** follows the ARIA tooltip pattern: the content takes `role="tooltip"` and its id is appended to the trigger's `aria-describedby` through a de-duplicating set-join (`concatAriaDescribedby`, [`tooltip.tsx:758`][tooltip-describedby]) — appended rather than replaced, and dropped when closed. When `aria-label` is supplied, the visible content loses the role and id and a `VisuallyHidden` node carries them, so `children` render exactly once ([`:566`][tooltip-arialabel]). **HoverCard** applies no role at all and forcibly de-tabs its descendants. **Popover** is `role="dialog"` with `aria-labelledby`/`aria-describedby` wired only when a `Title` or `Description` part is actually mounted, counted by refcounts ([`popover.tsx:494`][popover-role]). **Menu** uses `role=menu|menuitem|menuitemcheckbox|menuitemradio`, `aria-orientation`, and `aria-checked` with `"mixed"` for indeterminate; a `SubTrigger` carries `aria-haspopup="menu"`, `aria-expanded`, and `aria-controls` **only while open** ([`menu.tsx:1096`][menu-aria]) — a fix for triggers referencing a non-existent element. Modality's accessibility bit is `hideOthers()` rather than `aria-modal`.

WCAG 1.4.13 is only partly met: hoverable and dismissible are implemented, persistence is not guaranteed, and no test asserts the criterion. Touch and screen-reader tooltip timing are unaddressed because touch never opens a tooltip at all. `concatAriaDescribedby` is duplicated in `tooltip.tsx` and `popover.tsx`, both copies carrying the same `TODO: Move to primitive` comment ([`popover.tsx:617`][popover-describedby-dup]).

> [!NOTE]
> This assessment is a source reading. No screen reader, assistive technology or WCAG conformance was exercised.

**Degradation.** The transferable rule is the split itself: the positioning/dismissal/focus primitive carries no role, and role, label and description are supplied by the composing component. What the primitive _should_ own is the id-composition and refcounted-labelling algorithms, which are pure data and which Radix duplicates precisely because it has nowhere to put them. On a target with no accessibility API, roles become metadata — usable by a future bridge and, more immediately, by a recording canvas, which is the only way this dimension is testable there. The hover-only hazard is worse without an OS tooltip fallback: every hover-only affordance needs a keyboard-reachable equivalent. See [`./aria-apg.md`](./aria-apg.md) for the normative contract.

### 14. Animation

Radix emits geometry metadata _specifically_ so a styling layer can animate. The content carries `data-side` and `data-align` (final, post-flip) and `data-state`; the wrapper carries `--radix-popper-transform-origin` ([`popper.tsx:315`][popper-tovars]), and `size()` writes `--radix-popper-available-width/height` and `--radix-popper-anchor-width/height` ([`:251`][popper-size], [`:343`][popper-dataside]). Even the _anchor_ is told where its popup landed: `Popper.Anchor` renders `data-radix-popper-side` and `data-radix-popper-align` ([`popper.tsx:137`][popper-anchor-data]), so a trigger can style itself by the resolved placement. Every consumer then re-namespaces those variables into its own prefix (`--radix-tooltip-content-transform-origin`, `--radix-popover-*`, `--radix-dropdown-menu-*`, …) — five near-identical style blocks.

The `transformOrigin` middleware ([`popper.tsx:430`][popper-transformorigin]) derives the origin from the arrow: the cross-axis origin is the arrow's centre, unless `centerOffset !== 0`, in which case the arrow is hidden and the origin falls back to the align keyword (`start: '0%'`, `center: '50%'`, `end: '100%'`) — so "the arrow could not be centred" is a _separate datum_ from the numeric origin, and the categorical fallback is what makes the metadata usable when it is set.

Exit animations are gated by `Presence`, a three-state machine (`mounted | unmountSuspended | unmounted`) driven by `animationend`/`animationcancel` and a `getComputedStyle().animationName` comparison, with the animation name captured during the layout phase so a later passive read cannot force a style recalculation after sibling effects dirty the body ([`presence.tsx:36`][presence], #1634). Entrance is protected two ways: the wrapper is parked at `translate(0, -200%)` until `isPositioned` ([`popper.tsx:312`][popper-park]) and `animation: !isPositioned ? 'none' : ...` ([`:352`][popper-anim]) so that no entrance animation can begin from a pre-flip side. Repositioning during an animation keeps working, since `autoUpdate` never pauses.

Absent: springs, `prefers-reduced-motion` (zero hits), and any arrow-specific animation.

**Degradation.** The _metadata contract_ is the artifact: a placed overlay should expose side, align, origin, available extent, anchor extent and lifecycle phase as values a theme consumes, which removes the five-way re-namespacing entirely when they live in one struct instead of five CSS-variable prefixes. The `isPositioned` gate generalises to a rule — never paint, hit-test or animate an overlay before placement resolves — and is assertable on a recording canvas. `Presence` maps to an explicit phase enum with a deadline, which needs no `animationName` sniffing. On a cell grid a transform origin degrades to "which corner does the reveal grow from", still meaningful as an integer corner; on static HTML CSS transitions still work off `:hover`, so `data-side`-driven origins are among the few things that survive a script-free tier.

### 15. State architecture

Overwhelmingly ad hoc, with one exception. React `useState` holds anything that must re-render; a long list of mutable refs holds anything that must not: `isPointerDownRef`, `hasPointerMoveOpenedRef`, `isOpenDelayedRef`, `wasOpenDelayedRef`, `isPointerInTransitRef`, `isUsingKeyboardRef`, `pointerDirRef`, `lastPointerXRef`, `pointerGraceIntentRef`, `hasSelectionRef`, `isPointerDownOnContentRef`, `isRightClickOutsideRef`, `hasInteractedOutsideRef`, `hasPointerDownOutsideRef`, `isDeferredPointerDownOutsideRef`, `isPointerInsideReactTreeRef`, `isFocusInsideReactTreeRef`, `interceptedOutsideInteractionEventsRef`, `wasKeyboardTriggerOpenRef`. The only finite-state machine in the overlay stack is `Presence`'s three states.

The controlled/uncontrolled seam is uniform: `useControllableState({ prop, defaultProp, onChange, caller })`, with a dev-mode warning when a component flips between modes ([`use-controllable-state.tsx:19`][controllable]).

The real architecture is the **event-driven veto**. Every cross-cutting decision is `new CustomEvent(name, { bubbles: false, cancelable: true, detail })` dispatched at the relevant node with the handler attached `{ once: true }` immediately before dispatch ([`dismissable-layer.tsx:531`][dl-dispatch]); `preventDefault()` means "I handled it". `composeEventHandlers(theirs, ours, { checkForDefaultPrevented })` is how consumer and internal handlers coexist. Dispatch priority matters: `dispatchDiscreteCustomEvent` wraps the dispatch in `ReactDOM.flushSync` because "React … is not able to infer the priority of custom event types", and is used for `pointerDownOutside` and `menu.itemSelect` but explicitly not for focus events ([`primitive.tsx:103`][primitive-discrete]). Context scoping is per-instance via `createContextScope(NAME, [deps])`, so a Menu inside a Menu inside a Popover keeps its contexts separate.

**Algorithm.** Veto: `dispatch(name, detail, {discrete})` → add a `{once: true}` listener → `dispatchEvent` → `if (!event.defaultPrevented) doDefault()`. Latch: write a boolean ref in a capture-phase or earlier-ordered handler; read it in the later handler that must be suppressed. Both depend on the DOM's capture → target → bubble ordering guarantee.

**Degradation.** The veto _protocol_ survives value semantics and gets cheaper: a returned "consumed" boolean needs no allocation, no listener bookkeeping and no scheduler workaround. The latches are exactly the fields of an explicit state struct; they are refs here only because React re-renders would otherwise fire. What does not survive: DOM-node-as-identity throughout (Sets keyed by element, `contains()`, the `dataset.side` read-back), `getComputedStyle`, `MutationObserver`, document-level dispatch as an event bus, and the capture/bubble ordering the interception ledger depends on. The structure suggests that the machine Radix never wrote down is latent in those latches — they encode trigger arbitration, timing and dismissal arming across five packages — though Radix itself offers no evidence about what writing it down would cost. See [`../../specs/ui/state-machines.md`](../../specs/ui/state-machines.md) for sparkles' existing state vocabulary and [`./zag.md`](./zag.md) for a subject that did write the machine down.

### 16. Shared infrastructure

**Truly shared** (used by three or more overlay components): `Popper`, `DismissableLayer`, `FocusScope`, `Portal`, `Presence`, `Arrow`, `RovingFocusGroup` + `Collection`, `createContextScope`, `useControllableState`, `composeEventHandlers`, `useComposedRefs`, `useId`, `useDirection`, `useFocusGuards`.

**Looks common but deliberately stays apart** — the more valuable half:

1. **Grace geometry is not shared.** The tooltip hull and the menu trapezoid are separate implementations in separate packages, with `isPointInPolygon` copy-pasted byte-for-byte into both.
2. **`Select`'s item-aligned mode does not use `Popper` at all** — a hand-rolled positioner against `window.innerWidth/innerHeight` with its own `CONTENT_MARGIN` and a scroll-expansion mechanic, because aligning the _selected item_ over the trigger is a different geometry problem than anchoring a box to a rect.
3. **`NavigationMenu` uses neither `Popper` nor the tooltip timing** — it carries its own delay, skip and close timers.
4. **Modality is composed, not shared** — `MenuRootContentModal`, `PopoverContentModal` and `Dialog` each assemble the four booleans differently.
5. **Triggers are never shared** (dimension 5).
6. `whenMouse` and `concatAriaDescribedby` are each duplicated across two packages, the latter with a `TODO: Move to primitive` in both copies; and two branch registries were added independently for the same shape of problem.

> [!NOTE]
> Claims 2 and 3 rest on targeted greps plus the cited symbols, not on end-to-end readings of `select.tsx` and `navigation-menu.tsx`.

**Algorithm.** The factoring rule Radix converged on: share anything that is a _mechanism over an anonymous node_ — position it, detect outside it, contain focus in it, portal it, gate its unmount. Do not share anything that encodes _what kind of thing it is_ — when it opens, what closes it, what role it has, where focus goes, what geometry protects the travel to it.

**Degradation.** The rule is substrate-independent, and its practical value for a single-surface toolkit is the boundary it draws: a shared core can own the anchor value, the placement solve, the arrow datum, a layer registry with parent links, the dismissal sources and their veto protocol, a focus-_policy_ selector, and the placement metadata a theme consumes — while trigger semantics, timing policy, roles and labelling, item-aligned positioning, and modality-as-four-booleans stay in the composing component. Radix's own duplication marks the two places where its cut was too shallow rather than too deep: one grace module would have sufficed for both algorithms at the level of abstraction both were written at, and one parent link would have sufficed for both branch registries. On a script-free target almost none of the shared mechanisms can run, so the split must let the semantic components emit a degraded form _without_ the mechanisms — which the primitive/semantic boundary makes possible.

## Strengths

- The four-way decomposition (geometry / dismissal / focus / portal) scales to nine overlay components with a primitive layer that carries zero accessibility semantics, and the boundary is stated and adhered to rather than aspirational.
- The layer stack's invariants are hard-won and precisely right: order is registration order and must never be perturbed by a prop change; exactly one layer — the top — owns Escape; a layer below the highest modal layer treats nothing as outside. Each is a documented regression fix rather than a design guess.
- Placement is a pipeline that _exports data_ — final side and align, transform origin, available extent, anchor extent — specifically so a styling layer can animate without re-deriving geometry, and even the anchor learns where its popup landed.
- Arrow geometry is data (`x`, `y`, `centerOffset`), not styling, and arrow size feeds back into the main-axis offset, so the arrow is part of the layout problem rather than a decoration painted afterwards. Suppression on `centerOffset !== 0` is explicit rather than a silent clamp.
- Timing is exported to the styling layer as a three-valued state (`delayed-open` vs `instant-open` vs `closed`), which lets a theme decline to replay an enter animation on an instantly-reopened tooltip.
- The pointer-grace geometry is real and tested at the pixel level, mirrored for RTL and for the collision-flipped submenu across all four quadrants at a narrow viewport, and the direction gate in front of the polygon test is the non-obvious part that makes it correct.
- The tests are edge-case-driven and tied to issue numbers: shadow-DOM composed events counted as inside, non-primary buttons dismissing immediately, a child layer dismissing without dismissing its deferred parent, `skipDelayDuration={0}`, sweeping across a list of hover-card triggers, `hideWhenDetached` falling back to clipping ancestors.
- Performance discipline is visible and reasoned: reads batched before writes in the rect loop, `checkVisibility` preferred over per-ancestor `getComputedStyle` to avoid forced reflow, animation names captured during the layout phase, focus guards moved only when the edge invariant is actually broken.

## Weaknesses

- No adaptive presentation at all: zero occurrences of `visualViewport`, `matchMedia`, `prefers-reduced-motion`, `pointer: coarse` or safe-area handling in the `packages` tree. Touch is handled purely by suppression, so tooltips and hover cards silently never appear on touch devices, and there is no IME or soft-keyboard avoidance of any kind.
- Grace geometry is implemented twice, with `isPointInPolygon` and the `Point`/`Polygon` types copy-pasted into both packages; `whenMouse` and `concatAriaDescribedby` are likewise duplicated, the latter carrying a `TODO: Move to primitive` in both copies.
- Nineteen-plus mutable refs act as interaction latches against exactly one real state machine, which makes the timing and trigger behavior hard to reason about or to test in isolation.
- Modality via `body { pointer-events: none }` carries the acknowledged "click twice" cost, documented in the prop's doc comment rather than fixed — and it cannot be fixed within the DOM.
- Layering leaks: the positioned wrapper must read the _content's_ computed z-index and copy it, and `size()` writes CSS custom properties imperatively onto the floating element from inside the layout pipeline. Both are workarounds for the wrapper/content split.
- The submenu grace polygon reads the placed side back out of `content.dataset.side` — a DOM round trip for information the component already computed — under a standing `TODO`.
- No fallback-placement list can be expressed, and `avoidCollisions` couples flip and shift into one flag, so shift-without-flip and custom side ordering are both unreachable.
- `aria-controls`, labelling refcounts, describedby composition and id plumbing are re-implemented per component, which is why the same accessibility bugs were fixed separately in Popover and Tooltip.
- WCAG 1.4.13 is only partly satisfied and no test asserts it; touch and screen-reader tooltip timing are unaddressed because touch never opens a tooltip.
- Escape handling had to abandon React's `useEffectEvent` for `useCallbackRef` because of a React 19.2 stale-closure bug in `forwardRef` components — one of several places where the code is fighting its host framework rather than solving the overlay problem.

## Key design decisions and trade-offs

| Decision                                                                                                                                  | Rationale                                                                                                                                                                                                                                                                                                               | Trade-off                                                                                                                                                                                                                                                                                                                                                                      |
| ----------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| There is no `AnchoredOverlay` component; the problem is cut into four separately-consumable primitives plus `Presence`.                   | Each concern has a different lifetime, owner and consumer set: `Select`'s item-aligned mode needs dismissal but not `Popper`; `Tooltip` needs `Popper` and dismissal but never focus; `Dialog` needs focus and dismissal but has no anchor. A monolith would branch on component identity at every one of those points. | Composition is the only documented contract, so the wiring that makes a Popover correct — which handler preventDefaults, which branch registry, which modality booleans — is repeated in each component and drifts. It took two independently-invented branch registries (#3346 and #3423) to discover that the flat primitives had lost the overlay tree.                     |
| Escape is handled by the highest layer only.                                                                                              | Nested overlays must close one at a time; a per-layer listener would close the whole stack on one keypress. The handler also preventDefaults so no ancestor — or the browser, e.g. exiting fullscreen — reacts.                                                                                                         | It requires a global ordered registry: a layer cannot decide locally whether it is on top. Radix pays with a document-level `dismissableLayer.update` broadcast that force-re-renders every mounted layer whenever membership changes.                                                                                                                                         |
| Light dismiss commits on `click`, not `pointerdown`, and any intervening stopped event vetoes it.                                         | Three real failures: extension overlays calling `stopPropagation()` closed dialogs (#2055); touch's click delay could re-enable pointer events too early; and drag-scroll or long-press produces a pointerdown with no click, which must not dismiss.                                                                   | Dismissal becomes asynchronous and stateful (an armed listener plus a per-type ledger), which then needed its own escape hatch (`dismissableSurfaces`, #3346) and a fix so a child layer dismissing does not dismiss a deferred parent (#3971). It is also opt-in — Popover uses it, Menu and Tooltip do not — so light-dismiss semantics are inconsistent across the library. |
| Positioning is delegated wholesale to Floating UI; Radix contributes vocabulary, middleware ordering and exported metadata.               | Collision detection against real clipping ancestors, with transforms, zoom, DPR and fractional pixels, is a large and thankless problem. Radix's value-add is the semantics: side/align, the arrow↔offset coupling, `data-side`/`data-align`, transform origin, available size.                                         | Radix cannot express fallback placement lists, cannot decouple shift from flip, and inherits the fixed-strategy `altBoundary` hack. The upside is that the most-copied part — the metadata contract — is cleanly separable from the part it does not own.                                                                                                                      |
| Cross-cutting decisions are cancelable `CustomEvent`s with `preventDefault()` as the veto, rather than callbacks with return values.      | It gives consumers a uniform override point at the exact node involved, composing with their own handler via `composeEventHandlers` without the primitive knowing anything about them.                                                                                                                                  | It is expensive and scheduler-sensitive: each veto allocates an event, registers a `{once:true}` listener, dispatches, and for discrete events wraps the dispatch in `flushSync` because React cannot infer custom-event priority. The protocol shape is worth copying; the implementation is not.                                                                             |
| Tooltip, HoverCard, Popover and Menu are kept rigorously distinct in focus and interactivity, enforced structurally rather than by flags. | Tooltip content must never be focusable (ARIA tooltip pattern); HoverCard content is visible but must not enter the tab order; Popover is a dialog with a real focus contract; Menu owns roving focus and suppresses Tab. Collapsing these into one popup with flags produces components that are each subtly wrong.    | Enforcement is sometimes brutal: HoverCard writes `tabindex="-1"` onto every descendant on every render, which silently breaks genuinely interactive content. And the hoverable tooltip is a whole separate component swapped in by a prop, doubling the content code path.                                                                                                    |
| No adaptive presentation layer: touch is handled by suppression, never substitution.                                                      | Radix's targets are all browsers; the library declines to guess what a tooltip should become on a phone and pushes the decision to the consumer, keeping the primitive honest about what it does.                                                                                                                       | On a touch device a Tooltip and a HoverCard simply never open, with no fallback — a hole every consumer must solve independently. A toolkit whose targets differ more than phone-vs-browser cannot take this stance without shipping the same hole on more targets.                                                                                                            |

## Sources

Primary sources, all read at `f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae`:

- [`philosophy.md`][philosophy] — the stated design principles (1-to-1 DOM, composable and cancellable handlers).
- [`packages/react/popper/src/popper.tsx`][popper-middleware] — placement vocabulary, the middleware chain, the arrow coupling, the metadata export, the off-page measurement park.
- [`packages/react/dismissable-layer/src/dismissable-layer.tsx`][dl-context] — the four Sets, the layer index rules, Escape ownership, the deferred-dismissal interception ledger, dismissable surfaces.
- [`packages/react/focus-scope/src/focus-scope.tsx`][fs-stack] — the pause/resume scope stack, trap handlers, tabbable discovery, the branch registry.
- [`packages/react/tooltip/src/tooltip.tsx`][tooltip-skip] — delay/skip-delay, the three-valued state, the singleton broadcast, the convex-hull grace area.
- [`packages/react/menu/src/menu.tsx`][menu-poly] — trigger latches, the submenu trapezoid and direction gate, typeahead, roving-focus entry policy, submenu ARIA.
- [`packages/react/hover-card/src/hover-card.tsx`][hovercard-timers] — open/close delays, selection-aware close suppression, forced de-tabbing.
- [`packages/react/popover/src/popover.tsx`][popover-role] — modal/non-modal focus policy, restore decisions, `role="dialog"` with refcounted labelling.
- [`packages/react/context-menu/src/context-menu.tsx`][ctx-virtual] — the point/virtual anchor and the long-press trigger.
- [`packages/react/presence/src/presence.tsx`][presence] and [`packages/react/portal/src/portal.tsx`][portal] — the unmount machine and the whole portal mechanism.
- [`packages/core/rect/src/observe-element-rect.ts`][rect-observe] and [`packages/react/use-size/src/use-size.tsx`][usesize] — the shared rAF rect loop and the arrow `ResizeObserver`.
- [`e2e/dropdown-menu.spec.ts`][e2e-dropdown] and [`e2e/popper.spec.ts`][e2e-popper] — the Playwright specs pinning grace-area direction and the detach/size boundary split.

Related pages: [`./concepts.md`](./concepts.md), [`./comparison.md`](./comparison.md), [`./features-people-forget.md`](./features-people-forget.md), [`./sparkles-baseline.md`](./sparkles-baseline.md), [`./proposal.md`](./proposal.md); nearest siblings [`./floating-ui.md`](./floating-ui.md), [`./base-ui.md`](./base-ui.md), [`./ariakit.md`](./ariakit.md), [`./zag.md`](./zag.md), [`./react-aria.md`](./react-aria.md), [`./angular-cdk.md`](./angular-cdk.md), [`./aria-apg.md`](./aria-apg.md).

<!-- References -->

[radix]: https://github.com/radix-ui/primitives
[radix-docs]: https://www.radix-ui.com/primitives/docs/overview/introduction
[license]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/LICENSE#L1
[philosophy]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/philosophy.md#L41
[philosophy-handlers]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/philosophy.md#L45
[concepts]: ./concepts.md
[popper-sides]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/popper/src/popper.tsx#L25
[popper-anchor-cb]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/popper/src/popper.tsx#L100
[popper-virtualref]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/popper/src/popper.tsx#L117
[popper-virtual-null]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/popper/src/popper.tsx#L135
[popper-anchor-data]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/popper/src/popper.tsx#L137
[popper-sideoffset]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/popper/src/popper.tsx#L187
[popper-arrowsize]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/popper/src/popper.tsx#L207
[popper-desired]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/popper/src/popper.tsx#L211
[popper-altboundary]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/popper/src/popper.tsx#L225
[popper-autoupdate]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/popper/src/popper.tsx#L232
[popper-middleware]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/popper/src/popper.tsx#L241
[popper-offset]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/popper/src/popper.tsx#L242
[popper-shift]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/popper/src/popper.tsx#L244
[popper-size]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/popper/src/popper.tsx#L251
[popper-hide]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/popper/src/popper.tsx#L264
[popper-cannotcenter]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/popper/src/popper.tsx#L299
[popper-zindex]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/popper/src/popper.tsx#L301
[popper-wrapper]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/popper/src/popper.tsx#L309
[popper-park]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/popper/src/popper.tsx#L312
[popper-tovars]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/popper/src/popper.tsx#L315
[popper-dir]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/popper/src/popper.tsx#L328
[popper-dataside]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/popper/src/popper.tsx#L343
[popper-anim]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/popper/src/popper.tsx#L352
[popper-opposite]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/popper/src/popper.tsx#L367
[popper-arrowspan]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/popper/src/popper.tsx#L385
[popper-transformorigin]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/popper/src/popper.tsx#L430
[arrow-svg]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/arrow/src/arrow.tsx#L14
[dl-context]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/dismissable-layer/src/dismissable-layer.tsx#L16
[dl-doc-disable]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/dismissable-layer/src/dismissable-layer.tsx#L32
[dl-pointerevents]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/dismissable-layer/src/dismissable-layer.tsx#L96
[dl-enabled]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/dismissable-layer/src/dismissable-layer.tsx#L102
[dl-highest]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/dismissable-layer/src/dismissable-layer.tsx#L145
[dl-3645]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/dismissable-layer/src/dismissable-layer.tsx#L180
[dl-order-comment]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/dismissable-layer/src/dismissable-layer.tsx#L204
[dl-surface]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/dismissable-layer/src/dismissable-layer.tsx#L281
[dl-ledger]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/dismissable-layer/src/dismissable-layer.tsx#L328
[dl-capture]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/dismissable-layer/src/dismissable-layer.tsx#L342
[dl-defer]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/dismissable-layer/src/dismissable-layer.tsx#L426
[dl-update]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/dismissable-layer/src/dismissable-layer.tsx#L526
[dl-dispatch]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/dismissable-layer/src/dismissable-layer.tsx#L531
[dl-test-child]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/dismissable-layer/src/dismissable-layer.test.tsx#L401
[fs-trap]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/focus-scope/src/focus-scope.tsx#L101
[fs-focusout]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/focus-scope/src/focus-scope.tsx#L117
[fs-mutations]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/focus-scope/src/focus-scope.tsx#L144
[fs-autofocus]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/focus-scope/src/focus-scope.tsx#L165
[fs-tabloop]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/focus-scope/src/focus-scope.tsx#L205
[fs-branches]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/focus-scope/src/focus-scope.tsx#L258
[fs-tabbable]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/focus-scope/src/focus-scope.tsx#L345
[fs-checkvis]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/focus-scope/src/focus-scope.tsx#L367
[fs-stack]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/focus-scope/src/focus-scope.tsx#L420
[tooltip-delay]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/tooltip/src/tooltip.tsx#L30
[tooltip-skip]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/tooltip/src/tooltip.tsx#L71
[tooltip-onopen]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/tooltip/src/tooltip.tsx#L89
[tooltip-broadcast]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/tooltip/src/tooltip.tsx#L183
[tooltip-state]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/tooltip/src/tooltip.tsx#L191
[tooltip-pointerdownref]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/tooltip/src/tooltip.tsx#L279
[tooltip-trigger-move]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/tooltip/src/tooltip.tsx#L300
[tooltip-focus]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/tooltip/src/tooltip.tsx#L321
[tooltip-hoverable-switch]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/tooltip/src/tooltip.tsx#L394
[tooltip-grace]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/tooltip/src/tooltip.tsx#L430
[tooltip-singleton]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/tooltip/src/tooltip.tsx#L529
[tooltip-scroll]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/tooltip/src/tooltip.tsx#L534
[tooltip-arialabel]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/tooltip/src/tooltip.tsx#L566
[tooltip-exitside]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/tooltip/src/tooltip.tsx#L619
[tooltip-padded]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/tooltip/src/tooltip.tsx#L639
[tooltip-inpoly]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/tooltip/src/tooltip.tsx#L682
[tooltip-hull]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/tooltip/src/tooltip.tsx#L703
[tooltip-describedby]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/tooltip/src/tooltip.tsx#L758
[tooltip-test-skip]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/tooltip/src/tooltip.test.tsx#L380
[menu-subopenkeys]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/menu/src/menu.tsx#L41
[menu-keyboard]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/menu/src/menu.tsx#L101
[menu-blur]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/menu/src/menu.tsx#L131
[menu-ismodal]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/menu/src/menu.tsx#L419
[menu-typeahead]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/menu/src/menu.tsx#L447
[menu-movingto]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/menu/src/menu.tsx#L481
[menu-entryfocus]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/menu/src/menu.tsx#L545
[menu-guard]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/menu/src/menu.tsx#L596
[menu-itemmove]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/menu/src/menu.tsx#L782
[menu-subclose]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/menu/src/menu.tsx#L1029
[menu-aria]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/menu/src/menu.tsx#L1096
[menu-subopen-timer]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/menu/src/menu.tsx#L1126
[menu-poly]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/menu/src/menu.tsx#L1144
[menu-grace-expiry]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/menu/src/menu.tsx#L1157
[menu-sub-side]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/menu/src/menu.tsx#L1245
[menu-escape]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/menu/src/menu.tsx#L1262
[menu-nextmatch]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/menu/src/menu.tsx#L1336
[menu-inpoly]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/menu/src/menu.tsx#L1356
[menu-whenmouse]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/menu/src/menu.tsx#L1381
[hovercard-timers]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/hover-card/src/hover-card.tsx#L75
[hovercard-trigger]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/hover-card/src/hover-card.tsx#L138
[hovercard-tabindex]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/hover-card/src/hover-card.tsx#L324
[hovercard-excludetouch]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/hover-card/src/hover-card.tsx#L392
[hovercard-test-sweep]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/hover-card/src/hover-card.test.tsx#L77
[popover-anchor]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/popover/src/popover.tsx#L172
[popover-hideothers]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/popover/src/popover.tsx#L285
[popover-removescroll]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/popover/src/popover.tsx#L289
[popover-rightclick]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/popover/src/popover.tsx#L306
[popover-nonmodal-restore]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/popover/src/popover.tsx#L350
[popover-defer]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/popover/src/popover.tsx#L489
[popover-role]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/popover/src/popover.tsx#L494
[popover-describedby-dup]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/popover/src/popover.tsx#L617
[ctx-virtual]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/context-menu/src/context-menu.tsx#L126
[ctx-callout]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/context-menu/src/context-menu.tsx#L157
[ctx-longpress]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/context-menu/src/context-menu.tsx#L181
[dropdown-trigger]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/dropdown-menu/src/dropdown-menu.tsx#L125
[menubar-enter]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/menubar/src/menubar.tsx#L255
[select-margin]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/select/src/select.tsx#L583
[select-itemaligned]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/select/src/select.tsx#L932
[navmenu-delay]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/navigation-menu/src/navigation-menu.tsx#L136
[portal]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/portal/src/portal.tsx#L19
[guards]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/focus-guards/src/focus-guards.tsx#L26
[presence]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/presence/src/presence.tsx#L36
[primitive-discrete]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/primitive/src/primitive.tsx#L103
[controllable]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/use-controllable-state/src/use-controllable-state.tsx#L19
[measurable]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/core/rect/src/observe-element-rect.ts#L6
[rect-observe]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/core/rect/src/observe-element-rect.ts#L72
[usesize]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/use-size/src/use-size.tsx#L14
[e2e-popper]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/e2e/popper.spec.ts#L17
[e2e-dropdown]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/e2e/dropdown-menu.spec.ts#L34
