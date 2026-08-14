# Base UI (TypeScript / React)

Base UI is the successor to [Radix Primitives](./radix.md), written largely by the author of [Floating UI](./floating-ui.md), and its anchored-overlay stack is one 800-line positioning hook plus one reason-tagged popup store shared by Tooltip, Popover, Menu, ContextMenu, Submenu, Select, Combobox, PreviewCard, NavigationMenu and Toast.

| Field         | Value                                                                                                                                                                                                                                   |
| ------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language      | TypeScript (React)                                                                                                                                                                                                                      |
| License       | MIT (Copyright (c) 2019 Material-UI SAS)                                                                                                                                                                                                |
| Repository    | [`mui/base-ui`][repo]                                                                                                                                                                                                                   |
| Documentation | In-repo MDX under `docs/src/app/(docs)/react/` — read as documentation, never as an implementation reading                                                                                                                              |
| Category      | Web / headless behavior                                                                                                                                                                                                                 |
| Surface model | In-canvas (DOM only). Overlays are React portals into a generated `div` under `document.body`; stacking is document order. No OS popup was found, and no `showPopover()` or `<dialog>` appears in the overlay path read for this survey |
| Revision read | `adbd590484b26c1e68049348c57c70998ad667a7` (`@base-ui/react` 1.7.0)                                                                                                                                                                     |
| Read as       | Implementation (source), with two claims explicitly sourced to the in-repo docs                                                                                                                                                         |

> [!NOTE]
> The surface-model row records what was read, not an exhaustive monorepo audit. `showPopover()` and `<dialog>` are absent from the overlay path surveyed here — the positioner, the portals, and the Tooltip / Popover / Menu / Select / PreviewCard trees. The one place a platform dismissal primitive does appear is `CloseWatcher`, used by `drawer/root/DrawerRoot.tsx:454` and by nothing in the anchored path.

## Overview

### What it solves

Base UI supplies the behavior of eight anchored surfaces without supplying their appearance: where the surface goes, when it opens and closes, what owns focus, and what geometry the stylesheet may animate against. Its structural bet is that all of that reduces to two shared artifacts — a placement hook and an open-change sequencer — and that everything a component must _not_ share is a promise about reachability.

The repository makes the seam visible in its layout. Floating UI's React layer was **vendored into the tree** at `packages/react/src/floating-ui-react/` and forked; the pure geometry core (`@floating-ui/react-dom`, which supplies `flip`, `shift`, `size`, `offset`, `detectOverflow` and the DOM platform) stayed an ordinary npm dependency. Read as a boundary, that is: _geometry is reusable, interaction is not_.

### Design philosophy

Two quotes carry most of the philosophy. The first is a comment on a one-pixel constant, and it is the clearest evidence in the subject that placement is not pure geometry — `internals/useAnchorPositioning.ts:222-227`:

```text
// Create a bias to the preferred side.
// On iOS, when the mobile software keyboard opens, the input is exactly centered
// in the viewport, but this can cause it to flip to the top undesirably.
// The bias is only applied to `flip()` so it doesn't shift the resting position
// computed by `shift()` and `size()` away from the requested `collisionPadding`.
const bias = 1;
```

The second is normative in the docs and explains an absence the source confirms — `docs/src/app/(docs)/react/components/tooltip/page.mdx:17`:

> **Prefer using tooltips as visual labels only**: Tooltips should act as supplementary visual labels for sighted mouse and keyboard users. Tooltips alone are not accessible to touch or screen reader users.

Grepping the whole `tooltip/` tree for `aria-` returns exactly one hit — `aria-hidden` on the arrow (`tooltip/arrow/TooltipArrow.tsx:39`). The library declines to make a hover-revealed surface an accessibility object at all, and routes content that matters to Popover with `openOnHover`. A promise the component cannot keep is not made.

## How it works

Every anchored component is a set of parts (`Root` / `Trigger` / `Portal` / `Backdrop` / `Positioner` / `Popup` / `Arrow` / `Viewport`) whose only coupling is a store constructed once in the `Root`. The `Positioner` part calls `useAnchorPositioning` with one shared parameter object and receives one shared return value.

```text
anchor value ──▶ VirtualElement (rect provider)
                     │
      useAnchorPositioning (internals/useAnchorPositioning.ts, 800 lines)
                     │  middleware: [inline?] offset (shift,flip)|(flip,shift)
                     │              size arrow transformOrigin hide [adaptiveOrigin?]
                     ▼
   { positionerStyles, arrowStyles, arrowRef, arrowUncentered,
     side, align, physicalSide, anchorHidden, isPositioned, refs, context, update }
```

The eight `*Positioner` components are 143–358 lines each and are almost entirely _policy_ around that one call: which collision preset, which extra middleware, whether to mount a backdrop, whether to join a floating tree. `utils/usePositioner.tsx:22` is 44 lines and renders the shared outer element (`role="presentation"`, `hidden`, and `pointerEvents: 'none'` when `inert`).

The second pillar is the popup store. `utils/popups/store.ts:12` defines `PopupStoreState<Payload>` — a flat record of roughly eighteen plain fields — shared by Tooltip, Popover, Menu and PreviewCard. Every mutation runs through `applyPopupOpenChange` (`utils/popups/popupStoreUtils.ts:241`), a single sequencer that builds a `BaseUIChangeEventDetails` carrying a `reason`, the originating event, the owning trigger, and `cancel()` / `allowPropagation()` handles; notifies the consumer; aborts if cancelled; dispatches on the floating root store; derives an animation-suppression value; and commits — synchronously for hover (`popupStoreUtils.ts:302-307`):

```ts
if (isHover) {
  // Flush synchronously for hover so `node.getAnimations()` sees the new state.
  ReactDOM.flushSync(changeState);
} else {
  changeState();
}
```

The reasons come from a flat vocabulary in `internals/reason-parts.ts` — 35 exported string constants at this revision (`none`, `trigger-press`, `trigger-hover`, `trigger-focus`, `outside-press`, `escape-key`, `close-press`, `sibling-open`, `cancel-open`, …). Eight otherwise-unrelated features read it.

## The analysis spine

### 1. Anchor model

The public anchor type is a union: `Element | VirtualElement | RefObject | (() => Element | VirtualElement | null)`. It is resolved in a layout effect (`useAnchorPositioning.ts:510`) and again in a passive effect (`:527`), because parent refs are only populated by the time `useEffect` runs. Internally everything is normalised to a Floating UI `VirtualElement` — `useFloating.ts:93 setPositionReference` wraps a real `Element` into `{getBoundingClientRect, getClientRects, contextElement}` — so the positioner never holds an element, only a **rect provider**. Registration is identity-gated: `setPositionReference` runs only when the resolved anchor differs from the last one registered.

Four anchor kinds exist downstream of that normalisation:

| Kind                | Construction                                                                                                                                                                                                                               |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| element / ref       | Wrapped as a `VirtualElement` at the boundary                                                                                                                                                                                              |
| point               | `ContextMenuTrigger.tsx:57` builds `{getBoundingClientRect: () => DOMRect.fromRect({x, y, width: touch ? 10 : 0, height: touch ? 10 : 0})}` — a touch long-press gets a 10 px anchor box so the menu does not sit exactly under the finger |
| cursor-tracking     | `useClientPoint.ts:10 createVirtualElement` collapses width/height to 0 on the tracked axis and keeps the DOM rect on the other; tracking stops on `autoUpdate`-driven recomputes unless the open event was a mouse event                  |
| text-range (inline) | `utils/popups/inlineRect.ts` groups `getClientRects()` into **line** rects and anchors to the specific wrapped line the pointer entered                                                                                                    |

**Algorithm — line grouping and line selection** (`inlineRect.ts:62 getLineRects`, `:131 getInlineReferenceRect`): sort the client rects by `top`; start a new line when `rect.top - previousRect.top > previousRect.height / 2`, else union into the current line; if fewer than two lines result, inline behavior is skipped. Selection prefers the **captured line index** over re-hit-testing (`:146-147`): `if (coords?.lineIndex != null && lines[coords.lineIndex]) return createClientRect(lines[coords.lineIndex])`. Only if no index was captured does it hit-test the stored `(x, y)`. Failing that, for `top`/`bottom` placements it returns `rect(target.left, firstLine.top, target.right, lastLine.bottom)`; for `left`/`right`, the union x-extent with the extreme-edge line's y-extent. The middleware returns `reset: {rects}` so the remaining chain re-runs against the substituted reference.

Triggers are decoupled from anchors. `utils/popups/popupTriggerMap.ts:28 PopupTriggerMap` holds N triggers (id → element) per popup and `useImplicitActiveTrigger` (`popupStoreUtils.ts:416`) reconciles which one owns the open popup on each commit. Detached triggers reach the store through a `BasePopupHandle` (`popupHandle.ts:68`) that keeps a stack of attached root stores and hands out an inert `NullStore` when none is attached.

**Where the behavior lives.** Library code throughout; the browser contributes only `getBoundingClientRect` / `getClientRects`.

**Degradation.** Three of the four kinds are already plain comparable values; only the element case is a closure over live DOM. Off the DOM the anchor collapses to `{kind, rect}` with `kind ∈ {element-derived, point, line-of-a-run, virtual}`. Nothing here needs hover, key release, script, sub-cell precision or an OS window — the one thing that needs script is _re-resolution_ (dimension 3). The trigger registry is pure data and survives everywhere; with no script it degrades to one trigger per popup, since ownership reconciliation cannot run. In a cell grid the line-grouping rule simplifies rather than disappears: line height is exactly one row, so "rects on the same row are one line" replaces the half-height heuristic.

### 2. Placement model

The public vocabulary is `side ∈ {top, right, bottom, left, inline-start, inline-end}` × `align ∈ {start, center, end}`. Logical sides resolve to physical through an RTL-keyed table (`useAnchorPositioning.ts:184-195`) and the _rendered_ side is mapped back to logical for the `data-side` attribute (`:37 getLogicalSide`), so CSS sees the vocabulary it asked for.

There is no user-facing preferred-placement list. Instead a declarative `collisionAvoidance = {side, align, fallbackAxisSide}` is **compiled** into Floating UI middleware options. Two named presets encode the design distinction that matters (`internals/constants.ts:18` and `:26`):

- `DROPDOWN_COLLISION_AVOIDANCE = {fallbackAxisSide: 'none'}` — "used for dropdowns that usually strictly prefer top/bottom placements and use `var(--available-height)` to limit their height" (Menu, Select, Combobox: never fall onto the perpendicular axis).
- `POPUP_COLLISION_AVOIDANCE = {fallbackAxisSide: 'end'}` — "regular popups that usually aren't scrollable and are allowed to freely flip to any axis" (Tooltip, Popover, PreviewCard, submenus).

**Algorithm — the compilation** (`:279-347`):

```text
shiftDisabled       = align === 'none' && side !== 'shift'
crossAxisShift      = !shiftDisabled && (sticky || shift.crossAxis || side === 'shift')

flip   (unless side === 'none'):  mainAxis = !shift.crossAxis && side === 'flip'
                                  crossAxis = align === 'flip' ? 'alignment' : false
                                  fallbackAxisSideDirection = fallbackAxisSide
                                  padding = collisionPadding + bias + perSideBias
shift  (unless shiftDisabled):    mainAxis = align !== 'none'
                                  crossAxis = crossAxisShift
                                  limiter   = limitShift(...) unless sticky || crossAxis

order = (side === 'shift' || align === 'shift' || align === 'center')
        ? [shift, flip] : [flip, shift]
```

The `limitShift` limiter (`:312-322`) reads the arrow's measured size and lets the surface slide only until the arrow would leave the anchor: its `offset` is `arrowSize / 2 + (sum of the two perpendicular collision paddings) / 2`.

`collisionPadding` is a number or per-side object normalised to four numbers. `collisionBoundary` accepts `'clipping-ancestors' | Element | Element[] | Rect`. `shift.rootBoundary: 'layoutViewport'` is opt-in and used by `MenuPositioner.tsx:131` with the in-source rationale "Use the Layout Viewport to avoid shifting around when pinch-zooming"; the default is the visual viewport.

> [!IMPORTANT]
> Safe-area insets, work-area rects, multi-monitor geometry and IME insets are never inputs to placement here. The iOS soft keyboard is handled _indirectly_ — by the 1 px flip bias and by `adaptiveOrigin` reading `visualViewport` — never as a modelled inset. For a target with a real keyboard inset this is the wrong shape, and it is the clearest gap the subject exposes.

**Where the behavior lives.** Entirely in `internals/useAnchorPositioning.ts` for the policy; the `flip`/`shift`/`size`/`offset` primitives are `@floating-ui/react-dom`, an external dependency (see [`./floating-ui.md`](./floating-ui.md) for their internals — this page describes only how Base UI configures them).

**Degradation.** Placement is the most portable dimension: arithmetic on rects against a boundary rect. In integer cells everything survives except two fractional quantities — the 1 px flip bias, which must become an explicit "prefer the requested side on ties" comparison, and the `limitShift` offset, which must round to whole cells. With no script, placement must be frozen at emit time: a side can be chosen and baked, but flip and shift cannot react. Nothing here needs hover, key release or an OS window.

### 3. Collision and geometry engine

Overflow detection, clipping-ancestor discovery, scroll-container walking, transform handling and DPR all come from the `@floating-ui/react-dom` DOM platform; Base UI reimplements none of it. What it _adds_ is tracking policy and two corrections.

1. **`autoUpdate` is configured, not defaulted** (`:438`): `{elementResize: !disableAnchorTracking && ResizeObserver exists, layoutShift: !disableAnchorTracking && IntersectionObserver exists}`; scroll and resize listeners stay on unconditionally.
2. **Keep-mounted popups do zero geometry work while closed.** With `keepMounted`, `whileElementsMounted` is dropped (`:463-465`) and `autoUpdate` is armed manually in an effect gated on `mounted` (`:548`); a separate layout effect nulls out all four element refs on the floating root context whenever `!mounted` (`:425`).
3. **`isPositioned` gates painting.** Until the first pass completes, `position` is forced to `fixed` at the viewport origin with `opacity: 0` (`:474`, `:478`).
4. **A forked `hide` middleware** ORs Floating UI's `referenceHidden` with an all-zero-rect test — `utils/hideMiddleware.ts:7`: `const anchorHidden = width === 0 && height === 0 && x === 0 && y === 0;`, with the comment at `:8-9` stating it "Mirrors Floating UI's `hide()` referenceHidden strategy". A test asserts native `hide()` returns `false` and this returns `true` for exactly that input (`hideMiddleware.test.ts:67`).
5. **DPR snapping by edge rounding** (`:364`) — this is the integer-cell rounding rule stated in pixels:

```ts
const anchorWidth = (Math.round((x + width) * dpr) - Math.round(x * dpr)) / dpr;
```

Round the two edges, subtract; do not round the extent.

6. **`usePopupAutoResize`** (`utils/usePopupAutoResize.ts:15`) measures content by temporarily forcing `position: static; transform: none; scale: 1` and `--available-*: max-content` on the popup, reading `getCssDimensions`, then restoring.

**Degradation.** What generalises off the DOM: the overflow test (candidate rect vs boundary rect → four signed overflows), the clamp and flip decisions, the anchor-hidden predicate, and the round-the-edges rule. What does not: clipping-ancestor _discovery_ and observer-based tracking. In a toolkit that re-lays-out every frame there is no stale-position state, so the `isPositioned` / `opacity: 0` dance, the `autoUpdate` configuration and the layout-shift observer all have nothing to do — the cost drops from an async middleware pipeline per update to one pass of integer comparisons. With no measurement at all (static HTML) this dimension is simply absent, which is precisely why the no-script fallback must be a _chosen_ side rather than a computed one.

### 4. Arrow / caret geometry

Arrow geometry is unambiguously **data**. The forked `arrow()` middleware returns `{[axis]: offset, centerOffset, alignmentOffset?}`; the positioner turns that into `arrowStyles = {position: 'absolute', top: data.y, left: data.x}` (`:567`) plus a boolean `arrowUncentered = middlewareData.arrow?.centerOffset !== 0` (`:576`). The `*Arrow` components are pure renderers of that data plus `aria-hidden` and `data-side` / `data-align` / `data-uncentered`.

Base UI's fork adds `offsetParent: 'floating'` (`:371`) so the arrow measures against the floating element rather than its real offset parent — necessary because the arrow lives inside the popup while the positioner is the offset parent. If no arrow element is registered, the positioner fabricates a detached `document.createElement('div')` (`:374`) purely so the transform-origin computation has something to measure.

**Algorithm** (`floating-ui-react/middleware/arrow.ts:34-100`) — three distinct clamps:

```text
centerToReference = endDiff/2 - startDiff/2
center            = clientSize/2 - arrowLen/2 + centerToReference

largestPossiblePadding = clientSize/2 - arrowLen/2 - 1        // arrow.ts:73
minPadding = min(padding[min], largestPossiblePadding)
maxPadding = min(padding[max], largestPossiblePadding)

offset       = clamp(minPadding, center, clientSize - arrowLen - maxPadding)
centerOffset = center - offset - alignmentOffset
```

The first clamp is on the _padding itself_, with the source comment "If the padding is large enough that it causes the arrow to no longer be centered, modify the padding so that it is centered" — an over-large `arrowPadding` cannot push the arrow off-centre. The residual is reported as `centerOffset` so the styling layer can render an "uncentered" variant instead of lying. The third case: when the anchor is so small that the padded arrow would point at nothing, the middleware translates the _floating element_ by `alignmentOffset` and issues a `reset` so `shift()` re-runs (`arrow.ts:88-100`).

Arrow size feeds placement in two places: the `limitShift` offset (dimension 2) and the transform origin (dimension 14).

**Degradation.** In a cell grid the arrow is one character, so the algebra collapses: `arrowLen === 1` makes `largestPossiblePadding = floor(popupCells / 2) - 1`, the offset becomes `clamp(padCells, round(centerCell), popupCells - 1 - padCells)`, and "uncentered" becomes an integer inequality. The `shouldAddOffset` reset branch appears unnecessary at that granularity — a one-cell arrow fits over any anchor of at least one cell — so it seems droppable. Drop shadows and rounded corners are what `arrowPadding` exists to avoid, and neither exists on a cell target, so the padding defaults to zero there. Arrow geometry needs no hover, no script and no key release: it can be baked into static HTML.

### 5. Trigger semantics

Triggers are composed from independent hooks returning prop bags merged by `mergeProps`, and races are resolved by a **shared mutable record**, not by hook ordering. The record is `dataRef.current.openEvent`: `FloatingRootStore.syncOpenEvent` (`components/FloatingRootStore.ts:93`) stores the native event that opened the popup and refuses to let a pending hover open overwrite a click open, while allowing a click to upgrade a hover. Every later decision then asks the same two questions — `isClickLikeOpenEvent()` and `isHoverOpenEvent()` (`type.includes('mouse') && type !== 'mousedown'`).

`useClick.getNextOpen` (`hooks/useClick.ts:99`) is a decision table over: current open state, whether the pressed trigger is the **inactive** one (always open, never toggle — that is trigger-to-trigger handoff), `toggle`, and `stickIfOpen` (default `true`, `:68`), which lets a hover- or focus-opened popup survive the first click.

Pointer type is distinguished everywhere. Beyond `isMouseLikePointerType`, a synthetic `'virtual'` type is assigned when a mouse-like `pointerType` coincides with `isVirtualPointerEvent` (`useClick.ts:132-142`) — that is how Android TalkBack and desktop screen-reader activations bypass `ignoreMouse`. `useFocus` blocks re-open on focus for the specific element just dismissed by Escape or press (`blockedReferenceRef`, `hooks/useFocus.ts:100`).

Long press is `ContextMenuTrigger`: a 500 ms timer (`LONG_PRESS_DELAY`, `:16`) cancelled by touch movement past a 10 px threshold (`:146`), plus a one-shot document `mouseup` that closes with reason `cancel-open` (`:114`) if the right-button release lands outside.

**Algorithm — race resolution.** The hover open path checks `blockMouseMove`, `restTimeoutPending` and `isClickLikeOpenEvent()` at **fire** time, not at schedule time, so a rest-delay timer that elapses after a click already opened the popup returns early. On `mouseleave`, if `event.relatedTarget` is in the trigger registry the popup does not close — it will be _moved_. On `mouseenter` over an inactive trigger while open, the popup opens immediately, skipping all delays; `useClick` applies the same rule via `hasClickedOnInactiveTrigger`.

**Degradation.** The transferable idea is the arbitration mechanism itself — one stored open-cause field consulted by every later decision — and it is pure value semantics. On a terminal target there is no pointer-type distinction and no focus-visible distinction, so the pointer-type branches collapse to one device. With no hover (Android), every hover-derived trigger must fall back to press; Base UI already encodes that shape (`mouseOnly: true` on the tooltip's hover interaction, `TooltipTrigger.tsx:176`) but discovers it from a runtime `pointerType`, where a toolkit that knows its backend can decide it statically. With no script, exactly one trigger semantics can be emitted per popup and the arbitration layer collapses to nothing. On a recording backend every trigger is a synthesized event, and because the arbitration result is _stored_, an assertion can read the last open-change reason directly instead of inspecting pixels.

### 6. Timing

The tooltip's open delay is not a plain timer. It is passed as `restMs` with `move: false` (`tooltip/trigger/TooltipTrigger.tsx:174`), meaning the cursor must come to **rest** over the trigger for the delay; `mouseenter` alone never starts it.

| Surface                 | Open        | Close  | Source                              |
| ----------------------- | ----------- | ------ | ----------------------------------- |
| Tooltip                 | 600 ms rest | 0      | `tooltip/utils/constants.ts:1`      |
| PreviewCard             | 600 ms      | 300 ms | `preview-card/utils/constants.ts:1` |
| Popover (`openOnHover`) | 300 ms      | 0      | `popover/utils/constants.ts:1`      |
| Submenu                 | 100 ms      | 0      | menu trigger policy                 |

Warm-up and skip-delay are `FloatingDelayGroup` + `useDelayGroup` (`components/FloatingDelayGroup.tsx:66`). The provider holds `{delayRef, initialDelayRef, currentIdRef, currentContextRef, timeout, timeoutMs}` in **refs** — deliberately, so changing the delay does not re-render unrelated consumers. `FloatingDelayGroup`'s own `timeoutMs` default is `0` (`:67`); `TooltipProvider` supplies `400` (`tooltip/provider/TooltipProvider.tsx:13`).

**Algorithm — group seizure and interleaving guards** (`FloatingDelayGroup.tsx:141-270`). On open a tooltip seizes the group: sets `currentIdRef` to its `floatingId`, rewrites `delayRef = {open: 0, close: initialClose}`, and if a _different_ tooltip held the group, marks both as `isInstantPhase` and force-closes the previous with reason `none`. On close, the group reset is deferred by `timeoutMs`. Two guards make it correct under interleaving: the deferred reset bails if the store re-opened **or** another id seized the group, and the effect cleanup only clears the timer if the tooltip is still open **or** the id changed hands.

Tremor rejection is a squared comparison on the raw pointer movement (`hooks/useHoverReferenceInteraction.ts:463`): `event.movementX ** 2 + event.movementY ** 2 < 2` ignores the move rather than restarting the rest timer.

The implemented state machine, read off the handlers, is: `Closed → RestPending(restMs) → Open → ClosePending(closeDelay) → Closing`, with a same-trigger re-entry during the close transition returning immediately to `Open`. There is no max display duration and no toolbar traversal mechanism beyond the delay group.

**Degradation.** Timers are the first casualty. A static-HTML emit has none — a `:hover` tooltip appears instantly and the whole dimension vanishes, which argues for making the delay a policy _value_ the emitter can read and discard rather than a hardcoded behavior. Without hover there is no rest delay at all; a long-press timer replaces it. On a cell grid the "cursor at rest" test becomes "same cell as the last sample", which is cheaper and more stable than a pixel threshold — though it is a weaker test, not an equivalent one, since motion within one wide cell is invisible to it. The delay **group** is pure value state (`activeId`, delay override, instant phase) with no DOM, and transfers verbatim; the non-obvious part worth copying is the pair of interleaving guards, and the fact that the group stores the previous holder's close callback so the handoff is atomic.

### 7. Interactive hover

`floating-ui-react/safePolygon.ts` is 451 lines and is not a single polygon test — it is an eight-stage cascade run on every document `mousemove` after the pointer leaves the trigger. In order:

1. Pointer over the floating element → set `hasLanded = true`, stop. Over the reference → reset, stop.
2. Leaving _into_ the floating element (`relatedTarget` contained) → stop. This guards a documented open/close loop for overlapping surfaces (`:161`).
3. Any nested child node open → abort entirely.
4. **Opposite-side test**: pointer already past the far edge of the anchor relative to the popup's side (±1 px for floating-point error) → close (`:197`).
5. **Trough rect**: an axis-aligned band spanning the gap between anchor and popup; inside it, never close (`:207-260`).
6. Landed and now outside the anchor rect → close.
7. **Speed test**: not a leave event and the cursor is moving slower than `CURSOR_SPEED_THRESHOLD = 0.1` px/ms → close. Compared squared against `elapsed²`, no square root (`:101-115`).
8. **Quadrilateral**: two points at the cursor ± an offset plus the two far corners of the popup, tested by even-odd ray casting. Inside but not yet landed arms a 40 ms close timer (`:437`).

**Algorithm — the two numeric kernels.**

```text
isCursorMovingSlowly(x, y):
    dt = now - last;  d2 = dx*dx + dy*dy
    return d2 < dt*dt * CURSOR_SPEED_THRESHOLD_SQUARED      // 0.01

isPointInQuadrilateral(pt, corners):
    XOR over 4 edges of:
      (yi >= py) !== (yj >= py) && px <= (xj-xi)*(py-yi)/(yj-yi) + xi
```

The cursor spread is `POLYGON_BUFFER / 2` (0.25 px) when the popup is wider than the anchor and `POLYGON_BUFFER * 4` (2 px) otherwise (`:276`); the far-edge corner selection switches on which half of the anchor the cursor left from, so the polygon fans out toward the popup in the direction of travel.

`blockPointerEvents` (submenus only) is a separate mechanism: `applySafePolygonPointerEventsMutation` (`hooks/useHoverInteractionSharedState.ts:87`) sets `pointer-events: none` on a scope element and `auto` on just the reference and floating element, with a module-level `WeakMap` ensuring one owner per scope. Submenu menu-aim is not a distinct algorithm: the floating tree emits an `itemhover` event and each submenu closes itself when a different item in its parent is hovered (`menu/positioner/MenuPositioner.tsx:216`).

**Degradation.** With the common `sideOffset: 0` there is no gap between anchor and popup, so the trough band has zero extent and contributes nothing; the polygon's discriminating power then lies outside the corridor — on the anchor's own row and across the popup's area — which is where a cell port would still need it. The ±0.25/±2 px cursor spread is sub-cell noise correction and does not port. The speed test does port with a per-cell rate: 0.1 px/ms at an ~8 px cell is roughly one cell per 80 ms, a usable integer threshold. The 40 ms intent timer is unchanged.

> [!WARNING]
> `blockPointerEvents` is a **pointer grab substitute** that depends on a real capture-phase hit test. Without a native grab, the equivalent is a full-surface transparent hit-blocking entry in the display list beneath the popup — available in any toolkit whose hit testing is reverse paint order over a flat list, but it is a different mechanism, not a port.

With no hover the entire algorithm is dead code, and Base UI already special-cases that direction: a `pointerType === 'touch'` leave whose `relatedTarget` is inside the popup skips the close (`hooks/useHoverReferenceInteraction.ts:354-357`). With no script it cannot be expressed at all; a padded pseudo-element bridge covering the gap is the only tier-0 approximation, and only where the popup is reachable by `:hover`.

### 8. Dismissal

`floating-ui-react/hooks/useDismiss.ts` is 753 lines and is the densest file in the subject. Outside-press has **two modes** resolved per pointer type (`:319 getOutsidePressEvent`, `:336 shouldIgnoreEvent`):

```text
pointerType 'pen' | ''  ->  'mouse'
'sloppy'      : fires on pointerdown for mouse; for touch on touchend within 1000 ms,
                or as soon as a touchmove exceeds the 10 px threshold
'intentional' : fires only on click — press AND release must both be outside
```

Intentional mode carries a **one-shot suppression** (`:456-463`): a press that starts inside and ends outside consumes the next outside click, so dragging a slider thumb out of the popup does not dismiss it. A timeout-based variant covers presses whose `pointerdown` was `defaultPrevented`.

Five "not really outside" exclusions run before any dismissal:

| Exclusion             | Mechanism                                                                                                                                          |
| --------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| registered trigger    | Target is, or is inside, a trigger of this popup (`:382`)                                                                                          |
| floating-tree child   | Target is inside any child node of the tree                                                                                                        |
| scrollbar             | Computes `canScrollX/Y` and compares `event.offsetX` against `target.clientWidth`, RTL-aware; skipped for touch (`:428-443`)                       |
| third-party overlay   | Walks to the target's root ancestor and checks for a `[data-base-ui-inert]` marker, catching overlays injected _after_ the popup rendered (`:404`) |
| portalled React child | A capture-phase `insideReactTree` flag on the popup, cleared on a 0 ms timer (`:520`)                                                              |

Escape is gated on `isComposingRef` (`:151`, `:210`), with a WebKit-only 5 ms delay after `compositionend` because Safari fires it before `keydown`. A `bubbles` option controls whether a child popup blocks its parent's Escape.

Every listener is capture-phase on the document and re-dispatches through `addTargetEventListenerOnce(event, handler)` (`:520`) — a once-listener added to the _target_ for the same event type — so the handler runs at the target phase _after_ the application's own handlers, letting an application `preventDefault()` suppress dismissal.

Anchor removal closes only where opted into: `useImplicitActiveTrigger({closeOnActiveTriggerUnmount})` closes after a microtask (`popupStoreUtils.ts:506`); Tooltip opts in, Popover and Menu do not by default. An anchor that becomes _hidden_ yields a `data-anchor-hidden` attribute, not a close. Sibling opening closes menubar siblings with reason `sibling-open`; a parent close cascades to children through the tree emitter.

> [!NOTE]
> The Android back key is handled only by `Drawer`, via `CloseWatcher` (`drawer/root/DrawerRoot.tsx:454`). No anchored overlay wires it. A toolkit with an Android target must wire it for every overlay — and the reason vocabulary already contains a suitable name.

**Degradation.** Most of this survives as pure predicates over a hit list. Scrollbar detection disappears where a scrollbar is itself a widget in the hit list ("pressed a scrollbar" is just "hit a scrollbar entry"). Third-party-injection detection disappears with one surface and one owner. IME composition gating disappears on a terminal. The intentional/sloppy distinction does **not** collapse on a terminal target that decodes pointer release — that distinction is about press-versus-click on the _pointer_, and pointer release is a separate capability from key release; what a target without key release loses is the keyboard half (a release-edge activation or context-menu key, and any lone-modifier gesture). With no script, only trigger re-activation can dismiss, so emitted markup must never depend on Escape or outside press for correctness.

### 9. Focus

Four distinct focus behaviors, kept apart **structurally** rather than by configuration:

| Surface                                              | Focus treatment                                                                                                                                                                                                                                           |
| ---------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Tooltip                                              | No focus manager at all; portals via `FloatingPortalLite` (no guards). The popup carries only `FOCUSABLE_POPUP_PROPS = {tabIndex: -1, [FOCUSABLE_ATTRIBUTE]: ''}` (`popupStoreUtils.ts:32`) so it can be focused programmatically but is not in tab order |
| PreviewCard                                          | Same — no `FloatingFocusManager`                                                                                                                                                                                                                          |
| Popover / Menu / Select / Combobox / Dialog / Drawer | `FloatingFocusManager` (1005 lines)                                                                                                                                                                                                                       |

Its knobs (`FloatingFocusManager.tsx:147`): `initialFocus` (bool, ref, or a function of the interaction type), `returnFocus` (same shape, receiving the _close_ interaction type), `restoreFocus` (`false` | `true` = nearest tabbable inside the tree | `'popup'` = the container), `modal`, `closeOnFocusOut`. Popover is modal only when it has a Close part: `focusManagerModal = modal !== false && hasClosePart` (`popover/popup/PopoverPopup.tsx:71`).

Two behaviors are worth isolating.

**Touch-opened initial focus.** `createDefaultInitialFocus` (`popupStoreUtils.ts:38-45`) returns the popup element itself when the interaction type is `touch`. The doc comment names the reason: it "focuses the popup element itself to prevent the virtual keyboard from opening (required for Android specifically; iOS handles this automatically)". Note the shape: focus is **moved to the container**, not suppressed.

**Return focus consults a list, not a saved element.** `FloatingFocusManager.tsx:72-94` keeps a module-level `WeakRef` array capped at `LIST_LIMIT = 20`, pruned of disconnected nodes on every read:

```ts
const LIST_LIMIT = 20;
let previouslyFocusedElements: WeakRef<Element>[] = [];
```

Restoration walks it from the end. And the restore is guarded by whether focus is still inside the tree — `isFocusInsideFloatingTree` participates in the return-focus condition at `:869-880`, so a focus that moved elsewhere after mount is respected rather than yanked back.

Trigger-side focus guards (`utils/popups/useTriggerFocusGuards.ts:38`) render invisible spans before and after the trigger so that tabbing off a non-modal open popover closes it with reason `focus-out` and lands on the correct next tabbable, skipping everything inside the positioner.

**Degradation.** The tooltip ≠ popover ≠ menu ≠ dialog separation is the durable finding here and costs nothing to reproduce. Where focus is a widget-tree concept rather than an OS one, trap-versus-contain becomes a routing rule over a derived focus list — no tabbable computation, no guard spans, no `aria-hidden` ledger, no shadow-root unwrapping. Base UI's own focus paths in this dimension are keydown-driven (Tab is a `keydown`), so a target without key release loses nothing _in these paths_; release-edge focus affordances do exist elsewhere in the corpus and are covered in [`./comparison.md`](./comparison.md). The touch/keyboard distinction driving `initialFocus` maps onto backend capability directly. Static HTML gets `:focus-within` containment only. The capped previously-focused **list** is worth copying verbatim: widget identity in a rebuilt tree is exactly as fragile as a removed DOM node.

### 10. Layering and portals

No browser top layer is used anywhere in the path read here. Layering is a portal into a generated `div[data-base-ui-portal]` appended to `document.body` (or a caller-supplied container, or the **parent portal node**), plus ordinary DOM order for stacking.

**Algorithm — container resolution** (`components/FloatingPortal.tsx:110`): `explicit container ?? parentPortalNode ?? document.body`. A popup opened from inside a portalled popup therefore lands _inside_ the parent's portal `div`, giving correct paint order with no `z-index` assignment.

Two portal flavours encode the public/implementation split in practice: `FloatingPortal` renders four focus-guard spans, an `aria-owns` owner span and portal-context synchronisation; `FloatingPortalLite` (`utils/FloatingPortalLite.tsx:18`) is a bare double `createPortal` with no guards, used by Tooltip (`tooltip/portal/TooltipPortal.tsx:31`), PreviewCard and Toast.

The overlay **tree** is explicit and separate from the DOM. `FloatingTreeStore` (`components/FloatingTreeStore.ts:8`) holds a flat `Array<{id, parentId, context}>` with an event emitter; `getNodeChildren` filters by `parentId` transitively. Ownership is by node id, and dismissal, hover and menu-open events are broadcast on that tree, not bubbled through the DOM. Menus additionally accept an `externalTree` (`MenuPositioner.tsx:134`) so a menubar's menus share one tree without nesting in React.

**Where the behavior lives.** Library code entirely; the browser contributes only document order — no compositor layer, no top layer.

**Degradation.** This is the dimension where the subject and a single-surface canvas toolkit agree most. Base UI has already reduced layering to (a) an ordered insertion point and (b) an explicit parent/child overlay tree with ids. Nothing here needs an OS window, hover, script, sub-cell precision or key release. The portal _container_ is the one thing to drop, since there is one surface. The overlay **tree** is the one thing to keep and make public, because four otherwise-unrelated features query it: dismissal bubbling, `safePolygon`'s "a child is open" abort, Escape blocking, and focus restoration. One index, four features.

### 11. Modality

Modality is decomposed into four **independent bits** rather than one flag.

| Bit                  | Mechanism                                                                                                                                                                                                                                                                       |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Pointer blocking     | `InternalBackdrop` — a `position: fixed; inset: 0` div carrying `data-base-ui-inert`, with an optional cutout rendered as a `clip-path: polygon(...)` (`utils/InternalBackdrop.tsx:15`)                                                                                         |
| Accessibility hiding | `markOthers` — `inert` or `aria-hidden` on every element outside the keep-set, with reference-counted `WeakMap`s and an `uncontrolledElements` `WeakSet` recording nodes already hidden beforehand; `[aria-live]` regions are always exempt (`utils/markOthers.ts:152`, `:180`) |
| Focus trapping       | `FloatingFocusManager` in `modal` mode                                                                                                                                                                                                                                          |
| Scroll locking       | `useAnchoredPopupScrollLock`                                                                                                                                                                                                                                                    |

**Algorithm — the cutout** exploits `polygon()` winding: an outer rect path followed by a reversed inner rect path subtracts the trigger's rect from the blocking layer, so a modal dropdown's own toggle stays clickable underneath its backdrop.

**Algorithm — `markOthers` refcounting**: for each node outside the keep-set, increment the counter; if the counter is 1 and the node was _already_ hidden, record it in the uncontrolled set; otherwise set the attribute. Undo decrements and removes only at zero and only when the node is not in the uncontrolled set — so nested and overlapping overlays restore correctly.

Policy is per-component. `MenuPositioner.tsx:268` computes `const popupModal = modal && lastOpenChangeReason !== REASONS.triggerHover;` — a hover-opened menu never becomes modal, and its backdrop, if present, gets `pointerEvents: 'none'` (`menu/backdrop/MenuBackdrop.tsx:47`). Scroll lock carries a touch rule with its rationale in-source (`utils/useAnchoredPopupScrollLock.ts:7-11`): touch-opened popups lock scroll **only** when effectively viewport-wide, within `VIEWPORT_WIDTH_TOLERANCE_PX = 20`, "so users can still swipe outside to dismiss" while "common ~10px side padding still locks scroll". Click-through for a closed-but-mounted surface is `inert` on the positioner mapping to `pointerEvents: 'none'` (`utils/usePositioner.tsx:30`).

**Degradation.** Splitting modality into four bits is the transferable design, and three of the four port cheaply. Pointer blocking becomes a full-surface hit-blocking entry painted just under the popup; the cutout becomes "paint the trigger's hit entry _after_ the blocker" in a flat reverse-order hit list. Scroll lock becomes "ignore wheel events not targeting the popup". The focus trap becomes a routing rule. The accessibility bit has no analogue in a toolkit with no accessibility tree — an absence worth recording, because it means the modal bit reduces to input routing alone, and the whole `markOthers` refcounting apparatus has no home. The touch scroll-lock heuristic is directly relevant to a touch target and wants the keyboard inset as an input.

### 12. Adaptive presentation

There is no popover-to-sheet transformation and no teaching-tip primitive; `Drawer` is a separate component the application chooses. What _is_ adaptive is spread across four layers, and the interesting finding is that no single layer owns the decision:

| Layer       | Adaptation                                                                                                                                                                                                 |
| ----------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Component   | Select's `alignItemWithTrigger` is excluded when `openMethod === 'touch'` (`select/positioner/SelectPositioner.tsx:89`) and self-disables at runtime                                                       |
| Shared util | `createDefaultInitialFocus` redirects focus on touch; `useAnchoredPopupScrollLock` changes policy by pointer type                                                                                          |
| Hook        | `resolveValue` returns 0 for any non-mouse-like pointer type (`hooks/useHover.ts:498`), so touch never waits for a hover delay; `useClick.touchOpenDelay` (`:47`) exists to let the mobile viewport settle |
| Docs        | The tooltip → "Popover with `openOnHover`" substitution for touch is a documentation recommendation, not code (`docs/src/app/(docs)/react/components/tooltip/page.mdx:52`)                                 |

The single carrier tying them together is the stored interaction type — `openMethod: 'mouse' | 'touch' | 'pen' | 'keyboard' | null` (`utils/useOpenInteractionType.ts:44`) — readable from every part.

**Algorithm — Select's runtime fallback** (`select/popup/SelectPopup.tsx:355-372`), with `triggerCollisionThreshold = 20` (`:307`):

```ts
const fallbackToAlignPopupToTrigger =
  triggerRect.top < triggerCollisionThreshold ||
  triggerRect.bottom > viewportHeight - triggerCollisionThreshold ||
  Math.ceil(height) + SCROLL_EDGE_TOLERANCE_PX <
    Math.min(scrollHeight, minHeight);
```

with a separate WebKit pinch-zoom test at `:366`. When either fires, the saved positioner styles are restored and the component re-renders in ordinary anchored mode.

**Degradation.** The content of this dimension is _which layer owns the decision_. Base UI answers "the component, informed by a stored interaction type", and pays by spreading the decision across four layers. A toolkit that knows its backend at build or host time can make the choice once and hand it down as capability flags — hover, key release, timers, viewport insets. Concretely: "no hover at all" should not be discovered from a per-event pointer type; it should be a target capability that makes a hover trigger _construct_ as a press trigger. The Select fallback is the pattern worth copying for any exotic placement mode: a strategy that measures, may fail, and degrades into the shared solver.

### 13. Accessibility

The primitive layer emits almost no semantics. `usePositioner` contributes `role="presentation"`; arrows carry `aria-hidden`; the store exposes `popupId` / `triggerPopupId` selectors that wire `aria-controls` (`utils/popups/store.ts:200`); `markOthers` supplies the modal bit; and `internals/constants.ts:36` carries an `ownerVisuallyHidden` style for an `aria-owns` owner span, a documented workaround for iOS/Safari/VoiceControl.

Roles live in the semantic components: Popover popup `role="dialog"`, Menu popup `role="menu"` with `aria-haspopup="menu"`, Select `role="listbox"` (moved to `SelectList` when a list part is present, with the popup demoted to `role="presentation"`, `select/popup/SelectPopup.tsx:454`).

Tooltip and PreviewCard emit no role at all. Two screen-reader-specific behaviours exist: VoiceOver's `aria-expanded` announcement is suppressed on a keyboard-opened submenu trigger (`menu/submenu-trigger/MenuSubmenuTrigger.tsx:181`), and the synthetic `'virtual'` pointer type routes screen-reader presses through the click path rather than the hover path (dimension 5).

**Algorithm.** None — this dimension is a placement-of-responsibility finding. The rule it yields: the primitive owns **relationships** (id wiring, hidden-ness of decoration, the modal bit); the semantic component owns **roles**; and the library refuses to give a role to a surface it cannot make reachable by the users that role would promise it to.

**Degradation.** Where there is no accessibility API on any target, the ARIA half is not applicable — an absence, not a gap. What transfers is the responsibility split: an anchored-overlay primitive should carry no semantics, and each of tooltip / menu / select should attach its own. The tooltip rule is directly actionable on targets without hover or without timers, where a hover-only tooltip conveys nothing: such a primitive must either refuse to carry load-bearing content or degrade to an always-visible or press-revealed surface. Base UI chose the former and documented it, which is the cheaper choice. See [`./aria-apg.md`](./aria-apg.md) for the normative pattern this diverges from.

### 14. Animation and emitted geometry metadata

The positioner emits geometry metadata specifically so a stylesheet can animate against it. Four custom properties are written **imperatively** onto the floating element by middleware:

| Property                                   | Written by                                                                      |
| ------------------------------------------ | ------------------------------------------------------------------------------- |
| `--available-width` / `--available-height` | `size()` (`useAnchorPositioning.ts:358`), seeded to `100vw` / `100vh` at `:499` |
| `--anchor-width` / `--anchor-height`       | DPR-snapped at `:364-368`                                                       |
| `--transform-origin`                       | a bespoke middleware at `:381`                                                  |

The seeding is the subtlest thing in the file, and the comment at `:490-498` explains a whole bug class:

```text
// Seed the available size vars so consumer `max-height: min(x, var(--available-height))` rules
// resolve to a valid length on the first positioning pass, before `size()` writes the real
// values. Without a fallback the unresolved `var()` invalidates the whole declaration, so the
// popup is measured unconstrained while `flip()` picks its side, against the full content
// height rather than the capped one. Seeded unconditionally (not only while `!isPositioned`):
// the keys must stay present with a constant value so React's per-property style diff never
// rewrites them after mount, preserving the px values `size()` sets imperatively.
```

That is the measure/constrain circularity in one paragraph: the side you flip to depends on the height, which depends on the side.

**Algorithm — transform origin.** For the ordinary adjacent case the origin is the arrow's centre projected onto the anchor-facing edge, offset outward by `sideOffset`. When cross-axis shift is enabled _and_ the popup vertically overlaps its anchor, it instead uses the anchor's vertical centre expressed in popup-local coordinates (`:409`). Select in item-aligned mode overrides it again with a percentage origin at the selected item's text centre.

**Algorithm — `adaptiveOrigin`** (`utils/adaptiveOriginMiddleware.ts:21-28`) is gated on the element actually being animated:

```ts
const hasTransition =
  styles.transitionDuration !== '0s' && styles.transitionDuration !== '';
if (!hasTransition) {
  return { x: rawX, y: rawY, data: DEFAULT_SIDES };
}
```

When there _is_ a transition it converts `left`/`top` coordinates into `right`/`bottom` for top- and left-anchored popups, so an animating popup grows away from its anchor rather than pinning the wrong edge.

Suppression is a three-valued channel: `instantType ∈ {'delay', 'dismiss', 'focus'}` (plus Menu's `'trigger-change'`), surfaced as `data-instant`. Its **primary** input is the change reason (`popupStoreUtils.ts:261-264`, mapped at `:291-297`):

```ts
const isHover = reason === REASONS.triggerHover;
const isFocusOpen = nextOpen && reason === REASONS.triggerFocus;
const isDismissClose =
  !nextOpen &&
  (reason === REASONS.triggerPress || reason === REASONS.escapeKey);
```

> [!IMPORTANT]
> The reason is the primary input but not the only one, even inside Base UI: `TooltipRoot.tsx:103-118` overrides `instantType` to `'delay'` from `transitionStatus === 'ending'` and `isInstantPhase` — that is transition phase plus delay-group warm state, not a reason. Any port that models suppression as a pure function of the reason will be missing the warm-traversal case.

**Degradation.** The metadata itself is durable and fully portable: side, align, uncentered, anchor extent, available extent, transform origin and a suppression value are all plain values a layout pass can return. In cells the transform origin degenerates to an anchor **cell**; where neither scale nor opacity exists, the only surviving animation channel is per-frame content substitution over whole cells — which a recording backend can assert frame by frame. The idea worth copying regardless of whether a toolkit animates is that "this close was a dismissal, so skip the exit" is policy belonging to the state machine, not the stylesheet.

### 15. State architecture

An event-driven controller over an external observable store — not a finite-state machine and not a reducer. Each `Root` constructs a class store once via `useRefWithInit`; React subscribes with selector-scoped `store.useState(key, arg?)`.

- **State** is `PopupStoreState<Payload>`, a flat record of roughly eighteen plain fields.
- **Context** holds the non-reactive collaborators: the trigger map, the popup ref, callbacks.
- **Selectors** are pure functions of state plus an argument, and they are where distinctions get folded away. `store.ts:15` holds `open` (internal) and `:20` holds `readonly openProp` (external); `:142` is the entire controlled/uncontrolled resolution:

```ts
const openSelector = (state: S) => state.openProp ?? state.open;
```

with `activeTriggerIdSelector` at `:140` doing the same for the trigger id. No component branches on controlled-ness.

**Algorithm — `applyPopupOpenChange`** (`popupStoreUtils.ts:241`): derive `isHover` / `isFocusOpen` / `isDismissClose` from the reason; call `onOpenChange`; **abort if cancelled**; run a component-supplied `onBeforeDispatch`; dispatch on the floating root store; build the next state via `createPopupOpenState`; set `instantType`; and commit — `flushSync` for hover, plain call otherwise.

Mount lifetime is separate from open: `mounted`, `transitionStatus`, `preventUnmountingOnClose`, `forceUnmount`. There is **no state chart**: legality is enforced by guard conditions scattered through handlers plus the `openEvent` arbitration record.

**Degradation.** The shape survives a value-semantics port with three changes. (1) The state record is already plain data — replace the two element handles with widget ids and it is a copyable, comparable POD assertable frame by frame. (2) The reason vocabulary becomes an enum, and it is the highest-leverage single artifact in the subject: suppression, modality, backdrop pointer-events, focus return, submenu cascade, tooltip group handoff, portal choice and menubar sibling close all consult it. (3) What would not survive is React-shaped rather than essential: once-construction, `flushSync`, microtask-deferred close, and the cancellation closure — which becomes a `ref bool` or a returned enum.

> [!WARNING]
> The absence of an explicit state chart is a weakness, not a simplification to copy. The cost shows up as multi-term boolean guards — `isReenteringSameTriggerDuringCloseTransition` is a five-term conjunction — that exist only because `Open`, `Closing` and `RestPending` are implicit. A chart would make these transitions rather than predicates.

### 16. Shared infrastructure

This is the subject's strongest evidence for what belongs in one primitive, because the factoring is expressed as file placement (`internals/` and `utils/popups/` = shared; `<component>/` = not) rather than as documentation.

**Shared** by Tooltip, Popover, Menu, ContextMenu, Submenu, Select, Combobox, PreviewCard, NavigationMenu and Toast:

1. `useAnchorPositioning` (`:127`) — one hook, one parameter interface (`UseAnchorPositioningSharedParameters`, `:616`) that every `*Positioner` re-exports as its own props, one return value.
2. `usePositioner` (`utils/usePositioner.tsx:22`) — 44 lines: the shared outer element, role, hidden state, transition styles, state attributes, inert styling.
3. `PopupStoreState` + `popupStoreSelectors` + `applyPopupOpenChange` + `useOpenStateTransitions` + `usePopupInteractionProps` + `useImplicitActiveTrigger` + `PopupTriggerMap` + `BasePopupHandle`.
4. The reason vocabulary and `createChangeEventDetails`.
5. `popupStateMapping` — the `data-*` attribute contract.
6. `useDismiss`, `useClick`, `useFocus`, the split hover hooks, `safePolygon`, `FloatingFocusManager`, `FloatingPortal`, `FloatingTree`, `InternalBackdrop`, `useAnchoredPopupScrollLock`, `usePopupAutoResize`, `usePopupViewport`.

**Deliberately not shared**, which is the more informative half:

| Looks common                   | Actually split                                                                                                                                                                                               |
| ------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Portal                         | `FloatingPortalLite` (no guards) for Tooltip / PreviewCard / Toast vs full `FloatingPortal` elsewhere                                                                                                        |
| Focus manager                  | Tooltip and PreviewCard mount none at all                                                                                                                                                                    |
| Semantics                      | See dimension 13                                                                                                                                                                                             |
| Collision policy               | Two named presets separate "height-capped dropdown" from "free-flipping popup"                                                                                                                               |
| The placement algorithm itself | Select's `alignItemWithTrigger` discards `positioner.positionerStyles` for a bare `{position: 'fixed'}`, runs its own measurement, and reports `side: 'none'` (`select/positioner/SelectPositioner.tsx:124`) |
| Hover delay policy             | Rest-delay for tooltip vs plain delay for submenu, from one hook                                                                                                                                             |
| `openOnHover`                  | Present on Popover, `Omit`-ted from ContextMenu's props                                                                                                                                                      |

**Algorithm — the factoring rule that emerges.** Share anything that is a pure function of `(anchor rect, popup size, boundary, options)` or of `(reason, previous state)`: placement, arrow data, geometry metadata, the open-change sequence, the trigger registry, the overlay tree. Split anything that is a **promise to the user about reachability** — focus, semantics, portal guards, modality — because those promises differ per component and a shared default silently makes the wrong one.

**Degradation.** Nothing in the shared set requires hover, key release, script, sub-cell precision or an OS window; every one of the split items is exactly where a target capability differs. That correspondence is the reason this subject's factoring is directly usable for a single-surface toolkit rather than merely instructive — see [`./sparkles-baseline.md`](./sparkles-baseline.md) and [`./proposal.md`](./proposal.md).

## Strengths

- One 800-line hook genuinely serves eight components through one parameter interface and one return value; the per-component positioners are 143–358 lines of policy. That is a concrete, measurable answer to "what belongs in one anchored-overlay primitive".
- The change-reason vocabulary plus cancellable event details is a small, pure-data mechanism consumed by eight unrelated features — the most directly portable artifact in the subject.
- Divergence where components genuinely differ is enforced _structurally_: two portal implementations, an opt-in focus manager, two collision presets, and one component that discards the shared placement result. A tooltip cannot be made modal by passing a prop, because the machinery is not wired.
- Unusually high comment-to-code ratio on non-obvious invariants — the flip bias, the seeded `--available-*` variables, the microtask-deferred trigger close, the pending-versus-lost trigger distinction. Each explains a real bug class rather than restating the code.
- Anchors are normalised to a rect provider at the boundary, so point anchors, cursor tracking, text-range line anchors and element anchors are one code path downstream.
- The overlay tree is separate from the DOM tree and is queried by dismissal bubbling, `safePolygon`, Escape blocking and focus restoration alike.
- Real edge-case test coverage where it matters: `hideMiddleware` is differentially tested against Floating UI's native `hide()`, and `inlineRect` has a test named for stale client coordinates reusing the captured line index.

## Weaknesses

- No explicit state machine. `Open` / `Closing` / `RestPending` / `ClosePending` are implicit, and the cost is multi-term boolean guards standing in for transitions.
- Timing policy is spread across the hook, the trigger component, the provider and per-component constants, so "what is the delay right now" is answered by a function reading three refs.
- Soft-keyboard and safe-area insets are never an **input** to placement. The iOS keyboard is addressed by a 1 px flip bias and by `adaptiveOrigin` reading `visualViewport` — workarounds, not a model.
- `safePolygon`'s quadrilateral construction is roughly 160 lines of nested ternaries computing corner coordinates per side, with a lint suppression for nested ternaries at the top of the file; the four cases are near-transpositions that are not derived from a shared axis abstraction.
- Several behaviors exist only as browser-bug workarounds and would be dead weight elsewhere: a WebKit 5 ms `compositionend` delay, Firefox pointer-lock synthetic-click suppression, a Chrome dropped-`mouseleave` guard, the Safari pinch-zoom Select fallback.
- Modality is re-derived at use sites rather than stored: `modal && lastOpenChangeReason !== REASONS.triggerHover` is written twice in `MenuPositioner.tsx` (`:268` and, with an extra `parent.type` guard, `:289`), with a third `triggerHover` test in `MenuBackdrop.tsx:47`.
- `usePopupAutoResize` and `usePopupViewport` reach deep into imperative DOM mutation — forcing `position: static`, cloning subtrees, `flushSync` inside `requestAnimationFrame`. Powerful, and the least reusable idea in the subject.

## Key design decisions and trade-offs

| Decision                                                                                                                             | Rationale                                                                                                                                                                                                                                                                                | Trade-off                                                                                                                                                                                                                                                                                                                                                                         |
| ------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Vendor Floating UI's React layer into the repo and fork it, while keeping `@floating-ui/react-dom` external.                         | The integration layer needed behavior not expressible as options — splitting `useHover` across trigger and popup, a store-backed root context, a private `useFloating` path, an arrow with a configurable offset parent, an all-zero-rect `hide`. The geometry needed none of that.      | A clean seam between reusable geometry and owned interaction, at the cost of maintaining thousands of lines of forked interaction code that drift from upstream documentation. Informative as a boundary: the solver is the reusable part; the interaction layer is where a toolkit's own constraints live.                                                                       |
| Every state change carries a reason from one flat vocabulary, plus a cancellation handle, applied by one sequencer.                  | Eight features need to know _why_ a popup opened or closed: suppression, modality, backdrop pointer-events, focus return, group handoff, submenu cascade, menubar sibling close, re-open blocking after Escape. Encoding that on the transition beats each feature sniffing event types. | A flat string union with no vocabulary-level type safety (narrowing is per-component), and 35 values to keep coherent. It remains the highest-leverage artifact in the codebase and is trivially an enum with no runtime cost.                                                                                                                                                    |
| Tooltip and PreviewCard get no role, no focus manager and a guard-free portal; the docs redirect to Popover when content matters.    | A hover-revealed surface is unreachable by touch and screen-reader users, so `role="tooltip"` plus `aria-describedby` would promise reachability the component cannot deliver.                                                                                                           | Users migrating from libraries whose tooltip auto-describes its trigger silently lose that description. In exchange the primitive stays honest and the split is enforced by structure, not configuration.                                                                                                                                                                         |
| Position absolutely by default, but force `position: fixed` at the viewport origin with `opacity: 0` until the first pass completes. | Painting a full-size popup at coordinates retained from a previous open can overflow the layout viewport, which makes mobile Chrome zoom the page out and reflow everything the popup is anchored to.                                                                                    | An extra render pass and a visible "unpositioned" state consumers must not rely on. The transferable invariant is narrower and cheaper: never paint an overlay whose placement was not solved this frame.                                                                                                                                                                         |
| Expose geometry as CSS custom properties written imperatively by middleware, rather than as component state.                         | These change on every scroll and resize tick; routing them through React state would re-render at animation rate. Writing them to the style object lets the styling layer consume them at zero cost.                                                                                     | A fragile interaction between React's style reconciliation and imperative writes, documented in a ten-line comment because moving the seed into the wrong branch wipes `size()`'s values. For a canvas toolkit the hazard disappears: the metadata is a return value from layout.                                                                                                 |
| Model an overlay as parts with a store in the `Root`, rather than one component with props.                                          | It lets each part opt into exactly the shared infrastructure it needs, and it makes the store the only coupling point, so a part can be rendered zero or many times.                                                                                                                     | A lot of context plumbing and one store per root; the Positioner/Popup split exists largely so `size()` can write variables on one element while transforms animate the other. The separation of the placement **result** from the painted surface is still worth keeping — Select proves an exotic strategy must be able to replace the placement while reusing everything else. |

## Sources

Primary sources, all at revision `adbd590484b26c1e68049348c57c70998ad667a7`:

- [`internals/useAnchorPositioning.ts`][uap] — the shared positioning hook: side table, collision-avoidance compilation, the flip bias, the middleware pipeline, DPR snapping, the seeded size variables, `arrowStyles`.
- [`internals/constants.ts`][constants] — `DROPDOWN_COLLISION_AVOIDANCE`, `POPUP_COLLISION_AVOIDANCE`, `ownerVisuallyHidden`.
- [`internals/reason-parts.ts`][reasons] — the change-reason vocabulary.
- [`utils/popups/store.ts`][store] and [`utils/popups/popupStoreUtils.ts`][psu] — `PopupStoreState`, selectors, `applyPopupOpenChange`, `createDefaultInitialFocus`, active-trigger reconciliation.
- [`utils/popups/inlineRect.ts`][inline] — text-range line grouping and the captured-line-index rule.
- [`utils/hideMiddleware.ts`][hide] and [`utils/hideMiddleware.test.ts`][hidetest] — the all-zero-rect anchor-hidden test.
- [`utils/adaptiveOriginMiddleware.ts`][adaptive] — transition-gated coordinate inversion.
- [`utils/InternalBackdrop.tsx`][backdrop], [`utils/useAnchoredPopupScrollLock.ts`][scrolllock], [`utils/usePositioner.tsx`][usepositioner].
- [`floating-ui-react/middleware/arrow.ts`][arrow] — the forked arrow middleware and its three clamps.
- [`floating-ui-react/safePolygon.ts`][safepolygon] — the eight-stage hover-travel cascade.
- [`floating-ui-react/hooks/useDismiss.ts`][dismiss], [`useClick.ts`][useclick], [`useFocus.ts`][usefocus], [`useHoverReferenceInteraction.ts`][hoverref].
- [`floating-ui-react/components/FloatingFocusManager.tsx`][ffm], [`FloatingDelayGroup.tsx`][delaygroup], [`FloatingPortal.tsx`][portal], [`FloatingTreeStore.ts`][treestore], [`FloatingRootStore.ts`][rootstore].
- [`menu/positioner/MenuPositioner.tsx`][menupos], [`select/popup/SelectPopup.tsx`][selectpopup], [`select/positioner/SelectPositioner.tsx`][selectpos], [`tooltip/trigger/TooltipTrigger.tsx`][ttrigger], [`tooltip/root/TooltipRoot.tsx`][troot], [`tooltip/provider/TooltipProvider.tsx`][tprovider], [`context-menu/trigger/ContextMenuTrigger.tsx`][ctxtrigger].
- Documentation (read as documentation): [tooltip page][tooltipdocs].

Related pages in this catalog: [`./index.md`](./index.md), [`./concepts.md`](./concepts.md), [`./comparison.md`](./comparison.md), [`./features-people-forget.md`](./features-people-forget.md), [`./sparkles-baseline.md`](./sparkles-baseline.md), [`./proposal.md`](./proposal.md). Nearest siblings: [`./floating-ui.md`](./floating-ui.md) (the geometry core this configures), [`./radix.md`](./radix.md) (the predecessor), [`./react-aria.md`](./react-aria.md), [`./zag.md`](./zag.md), [`./ariakit.md`](./ariakit.md), [`./headlessui.md`](./headlessui.md). Toolkit context: [`../../specs/ui/index.md`](../../specs/ui/index.md), [`../../specs/ui/input.md`](../../specs/ui/input.md), [`../../specs/ui/state-machines.md`](../../specs/ui/state-machines.md), [`../../specs/ui/containers.md`](../../specs/ui/containers.md), [`../../specs/ui/backends.md`](../../specs/ui/backends.md), [`../../specs/ui/widgets.md`](../../specs/ui/widgets.md). Adjacent research: [`../window-system-integration/index.md`](../window-system-integration/index.md), [`../platform-ui-guidelines/index.md`](../platform-ui-guidelines/index.md), [`../ui-layout/index.md`](../ui-layout/index.md), [`../sean-parent/index.md`](../sean-parent/index.md).

<!-- References -->

[repo]: https://github.com/mui/base-ui/tree/adbd590484b26c1e68049348c57c70998ad667a7
[uap]: https://github.com/mui/base-ui/blob/adbd590484b26c1e68049348c57c70998ad667a7/packages/react/src/internals/useAnchorPositioning.ts#L222
[constants]: https://github.com/mui/base-ui/blob/adbd590484b26c1e68049348c57c70998ad667a7/packages/react/src/internals/constants.ts#L18
[reasons]: https://github.com/mui/base-ui/blob/adbd590484b26c1e68049348c57c70998ad667a7/packages/react/src/internals/reason-parts.ts#L1
[store]: https://github.com/mui/base-ui/blob/adbd590484b26c1e68049348c57c70998ad667a7/packages/react/src/utils/popups/store.ts#L142
[psu]: https://github.com/mui/base-ui/blob/adbd590484b26c1e68049348c57c70998ad667a7/packages/react/src/utils/popups/popupStoreUtils.ts#L241
[inline]: https://github.com/mui/base-ui/blob/adbd590484b26c1e68049348c57c70998ad667a7/packages/react/src/utils/popups/inlineRect.ts#L62
[hide]: https://github.com/mui/base-ui/blob/adbd590484b26c1e68049348c57c70998ad667a7/packages/react/src/utils/hideMiddleware.ts#L7
[hidetest]: https://github.com/mui/base-ui/blob/adbd590484b26c1e68049348c57c70998ad667a7/packages/react/src/utils/hideMiddleware.test.ts#L67
[adaptive]: https://github.com/mui/base-ui/blob/adbd590484b26c1e68049348c57c70998ad667a7/packages/react/src/utils/adaptiveOriginMiddleware.ts#L21
[backdrop]: https://github.com/mui/base-ui/blob/adbd590484b26c1e68049348c57c70998ad667a7/packages/react/src/utils/InternalBackdrop.tsx#L15
[scrolllock]: https://github.com/mui/base-ui/blob/adbd590484b26c1e68049348c57c70998ad667a7/packages/react/src/utils/useAnchoredPopupScrollLock.ts#L7
[usepositioner]: https://github.com/mui/base-ui/blob/adbd590484b26c1e68049348c57c70998ad667a7/packages/react/src/utils/usePositioner.tsx#L22
[arrow]: https://github.com/mui/base-ui/blob/adbd590484b26c1e68049348c57c70998ad667a7/packages/react/src/floating-ui-react/middleware/arrow.ts#L73
[safepolygon]: https://github.com/mui/base-ui/blob/adbd590484b26c1e68049348c57c70998ad667a7/packages/react/src/floating-ui-react/safePolygon.ts#L101
[dismiss]: https://github.com/mui/base-ui/blob/adbd590484b26c1e68049348c57c70998ad667a7/packages/react/src/floating-ui-react/hooks/useDismiss.ts#L319
[useclick]: https://github.com/mui/base-ui/blob/adbd590484b26c1e68049348c57c70998ad667a7/packages/react/src/floating-ui-react/hooks/useClick.ts#L99
[usefocus]: https://github.com/mui/base-ui/blob/adbd590484b26c1e68049348c57c70998ad667a7/packages/react/src/floating-ui-react/hooks/useFocus.ts#L100
[hoverref]: https://github.com/mui/base-ui/blob/adbd590484b26c1e68049348c57c70998ad667a7/packages/react/src/floating-ui-react/hooks/useHoverReferenceInteraction.ts#L463
[ffm]: https://github.com/mui/base-ui/blob/adbd590484b26c1e68049348c57c70998ad667a7/packages/react/src/floating-ui-react/components/FloatingFocusManager.tsx#L72
[delaygroup]: https://github.com/mui/base-ui/blob/adbd590484b26c1e68049348c57c70998ad667a7/packages/react/src/floating-ui-react/components/FloatingDelayGroup.tsx#L66
[portal]: https://github.com/mui/base-ui/blob/adbd590484b26c1e68049348c57c70998ad667a7/packages/react/src/floating-ui-react/components/FloatingPortal.tsx#L110
[treestore]: https://github.com/mui/base-ui/blob/adbd590484b26c1e68049348c57c70998ad667a7/packages/react/src/floating-ui-react/components/FloatingTreeStore.ts#L8
[rootstore]: https://github.com/mui/base-ui/blob/adbd590484b26c1e68049348c57c70998ad667a7/packages/react/src/floating-ui-react/components/FloatingRootStore.ts#L93
[menupos]: https://github.com/mui/base-ui/blob/adbd590484b26c1e68049348c57c70998ad667a7/packages/react/src/menu/positioner/MenuPositioner.tsx#L268
[selectpopup]: https://github.com/mui/base-ui/blob/adbd590484b26c1e68049348c57c70998ad667a7/packages/react/src/select/popup/SelectPopup.tsx#L360
[selectpos]: https://github.com/mui/base-ui/blob/adbd590484b26c1e68049348c57c70998ad667a7/packages/react/src/select/positioner/SelectPositioner.tsx#L89
[ttrigger]: https://github.com/mui/base-ui/blob/adbd590484b26c1e68049348c57c70998ad667a7/packages/react/src/tooltip/trigger/TooltipTrigger.tsx#L174
[troot]: https://github.com/mui/base-ui/blob/adbd590484b26c1e68049348c57c70998ad667a7/packages/react/src/tooltip/root/TooltipRoot.tsx#L103
[tprovider]: https://github.com/mui/base-ui/blob/adbd590484b26c1e68049348c57c70998ad667a7/packages/react/src/tooltip/provider/TooltipProvider.tsx#L13
[ctxtrigger]: https://github.com/mui/base-ui/blob/adbd590484b26c1e68049348c57c70998ad667a7/packages/react/src/context-menu/trigger/ContextMenuTrigger.tsx#L16
[tooltipdocs]: https://github.com/mui/base-ui/blob/adbd590484b26c1e68049348c57c70998ad667a7/docs/src/app/%28docs%29/react/components/tooltip/page.mdx#L17
