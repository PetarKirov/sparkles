# Zag.js (TypeScript / web, framework-agnostic state machines)

A library of UI-component state machines in which the chart is plain data, the interpreter
lives outside the core, and every anchored-overlay concern except the statechart itself is
delegated to a small single-purpose package — positioning to `@zag-js/popper` (a wrapper
over Floating UI), outside-interaction and nesting to `@zag-js/dismissable`, focus to
`@zag-js/focus-trap` and `@zag-js/dom-query`.

| Field         | Value                                                                                                                                                                                                                                  |
| ------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language      | TypeScript                                                                                                                                                                                                                             |
| License       | MIT (Copyright (c) 2021 Chakra UI)                                                                                                                                                                                                     |
| Repository    | [`chakra-ui/zag`][zag-repo]                                                                                                                                                                                                            |
| Documentation | [zagjs.com][zag-docs]                                                                                                                                                                                                                  |
| Category      | Web / headless behavior — component state machines                                                                                                                                                                                     |
| Surface model | in-canvas: one document, content portalled to `document.body`; no OS popup, no browser [top layer][concepts] anywhere                                                                                                                  |
| Packages read | `@zag-js/core`, `@zag-js/popper`, `@zag-js/dismissable`, `@zag-js/interact-outside`, `@zag-js/dom-query`, `@zag-js/rect-utils`, `@zag-js/presence`, and the `tooltip` / `popover` / `menu` / `hover-card` / `select` / `tour` machines |
| Version       | 1.43.0 (all workspace packages)                                                                                                                                                                                                        |
| Revision read | `eabc04440baa219723bc5d9a51d4e95c1deaf024`                                                                                                                                                                                             |

---

## Overview

### What it solves

Zag factors every overlay widget into four files: `machine.ts` (a declarative statechart
_config object_), `connect.ts` (state → framework props and DOM handlers), `dom.ts`
(string-ID element getters), and `types.ts`. One `Service` is created per widget instance,
and six framework packages (`react`, `vue`, `solid`, `svelte`, `preact`, `vanilla`) each
supply their own interpreter for the same description.

For anchored overlays specifically, the machines own almost no geometry. A tooltip machine's
entire positional state is `currentPlacement`; a menu's is `currentPlacement`, `anchorPoint`
and `intentPolygon`. Everything else — [anchor rect][concepts] resolution, overflow
measurement, [flip and shift][concepts] — happens inside `@zag-js/popper` and, below it,
Floating UI. What the machines do own is the _lifecycle_: `closed → opening → open →
closing → closed`, with [warm-up][concepts] and [cool-down][concepts] modelled as real
states rather than as annotations on a transition.

### Design philosophy

Two commitments dominate the design, and both are stated in the repository's own
contributor guide. The first is that machines stay small:

> 5. **Simple Machines**: Avoid complex nested states, spawn, etc.
>
> — `CLAUDE.md:66`

The v1 statechart vocabulary is correspondingly tiny. `MachineState` is `id`, `tags`,
`entry`, `exit`, `effects`, `initial`, `states`, `on`; the root adds `props`, `context`,
`computed`, `refs`, `watch` and `initialState`:

```ts
  initialState: (params: { prop: PropFn<T> }) => T["state"]
  entry?: ActionsOrFn<T> | undefined
  exit?: ActionsOrFn<T> | undefined
  effects?: EffectsOrFn<T> | undefined
```

— verbatim, `packages/core/src/types.ts:208-211`

Note what is absent at this revision: no `after`, no `invoke`, no activities, no parallel
regions, no history. Delayed transitions are hand-rolled — a state's `effects` entry calls
`setTimeout` and sends a synthetic event, and the effect's returned cleanup cancels it when
the state is exited.

The second commitment is that core logic never depends on framework specifics. That holds
for the _description_ but not for the _execution_: `createMachine(config)` indexes the
state tree and returns the config unchanged (`packages/core/src/create-machine.ts:24-27`),
so `@zag-js/core` contributes path algebra, a `Scope`, and prop merging — the `send` loop,
guard evaluation, LCA exit/enter and effect lifecycle are reimplemented once per framework.

> [!IMPORTANT]
> `@floating-ui/dom` is a runtime dependency and is not vendored; `node_modules` is absent
> in the clone read here. Everything attributed below to Floating UI — `flip`, `shift`,
> `limitShift`, `size`, `hide`, `arrow`, clipping-ancestor discovery, transform/zoom
> compensation, RTL handling of `-start`/`-end` — is attributed **by call site only** and
> was not read at this revision. See [`./floating-ui.md`](./floating-ui.md) for that side.
> No code was executed: no build, no vitest run, no Playwright run, no browser.

## How it works

A floating machine's `open` state lists named effects, and the interpreter starts each one
on entry and runs its returned teardown on exit. Popover's is representative
(`packages/machines/popover/src/popover.machine.ts:107-113`):

```text
open.effects = [
    "trapFocus",              // @zag-js/focus-trap, only when modal
    "preventScroll",          // @zag-js/remove-scroll, only when modal
    "hideContentBelow",       // @zag-js/aria-hidden, only when modal
    "trackDismissableElement",// @zag-js/dismissable  → layer stack + escape + outside
    "trackPositioning",       // @zag-js/popper       → Floating UI autoUpdate
    "proxyTabFocus",          // @zag-js/dom-query,   only when non-modal
]
```

Order is load-bearing: the changelog records a nested-popover `z-index` fix obtained by
running `trackDismissableElement` before `trackPositioning`, so that the layer index exists
by the time the popper reads it.

`trackPositioning` is the whole positional pipeline in one call. It passes _thunks_, not
elements, so the anchor is re-resolved on every tick, and it prefers a dedicated `anchor`
part over the trigger (`popover.machine.ts:152-164`):

```text
getTriggerEl   = () => anchorEl ?? getActiveTriggerEl(scope, triggerValue)
getPositionerEl = () => getPositionerEl(scope)
getPlacement(getTriggerEl, getPositionerEl, {
    ...prop("positioning"),
    defer: true,                                  // first run one rAF later
    onComplete: data => context.set("currentPlacement", data.placement),
})
```

`getPlacement` builds a fixed middleware chain, calls Floating UI's `computePosition`, and
writes the result back as CSS custom properties on the positioner element — `--x`, `--y`,
`--z-index`, `--transform-origin`, and the `size` middleware's `--reference-width` /
`--available-height` family. The machine learns only `data.placement`. Everything a
stylesheet needs to react — which side won, where the caret landed, whether this is an
instant switch — is emitted as `data-*` attributes and CSS variables rather than returned
as values.

## The analysis spine

### 1. Anchor model

Three anchor kinds funnel into one Floating UI `VirtualElement`.

- **Element anchor.** Resolved lazily by string id at every position tick. `getPlacement`
  takes a `MaybeFn<MaybeRectElement>` and machines always pass thunks.
- **Point anchor** ([virtual anchor][concepts]). `anchorPoint: Point | null` lives in
  machine context and is converted to a zero-size rect at use time:
  `getAnchorRect = () => ({ width: 0, height: 0, ...anchorPoint })`
  (`packages/machines/menu/src/menu.machine.ts:708-713`, inside `reposition`).
- **Detached anchor.** Popover ships a distinct `anchor` part, preferred over the trigger,
  so trigger ≠ anchor is first-class.

Many-triggers-one-popup is a shipped feature: `triggerValue: string | null` in context
selects which of N `[data-scope][data-part=trigger][data-ownedby=<id>]` elements is the
anchor, and `getActiveTriggerEl` falls back to the first match when the value is `null`
(`packages/machines/menu/src/menu.dom.ts:49`). Tour adds a fourth kind — an element rect
inflated by `spotlightOffset` through `getAnchorRect`
(`packages/machines/tour/src/tour.machine.ts:557`). There is no text-range anchor and no
multi-rect anchor anywhere in the tree.

**Algorithm.** `resolveAnchor()` (`get-placement.ts:221-224`) is
`opts.getAnchorElement?.() ?? maybeFn(referenceOrVirtual)` — an explicit anchor element
outranks the reference thunk — and `resolveReference()` (`:226-230`) wraps the result in
`getAnchorElement(anchor, opts.getAnchorRect)`, which returns a `VirtualElement` whose
`contextElement` is the anchor and whose `getBoundingClientRect` prefers the supplied
`getAnchorRect` over the element's own measurement
(`packages/utilities/popper/src/get-anchor.ts:28-43`). Every `autoUpdate` tick re-invokes the
thunk, so a replaced anchor (a multi-trigger switch) is picked up automatically;
`syncAutoUpdateObservers()` compares `anchorIdentity(anchor)` — which reduces an anchor to
its `contextElement` — against the last one and rebinds the `ResizeObserver` and scroll
listeners only when it changes (`get-placement.ts:202`, `:283`).

**Where it lives.** `@zag-js/popper` (`get-anchor.ts`, `get-placement.ts`), with element
identity supplied by each machine's `dom.ts`; _which_ trigger is active is machine context.

**Degradation.** Pure geometry, so no OS window is required and nothing here needs hover,
key release or sub-cell precision. The DOM-shaped part is that the anchor is a _lookup_,
not a value. In a toolkit with no persistent element registry the anchor must become a
value — an id plus the rect layout produced for it, or an explicit cell rect, or a cell
point. The point anchor and the multi-trigger selector are already plain comparable values
here and port unchanged. With no script, an anchor cannot be re-resolved at all: the rect
must be baked at emit time.

### 2. Placement model

[Placement][concepts] is Floating UI's 12-value physical grid, validated by one regex —
`/^(?:top|bottom|left|right)(?:-(?:start|end))?$/`
(`packages/utilities/popper/src/placement.ts:4-6`). Zag adds no logical/writing-mode layer
of its own; the only RTL handling _in Zag_ is a submenu choosing `left-start` in RTL and
`right-start` in LTR, written into a `positioningOverride` ref rather than into props
(`menu.machine.ts:703-708`).

The wrapper's option surface (`packages/utilities/popper/src/types.ts:19`) is: `strategy`,
`placement`, `offset{mainAxis,crossAxis}`, `gutter` (main-axis gap), `shift` (cross-axis
gap), `overflowPadding`, `arrowPadding`, `flip` (`true` or a fallback `Placement[]`),
`slide` (main-axis shift), `overlap` (cross-axis shift), `sameWidth`, `fitViewport`,
`boundary`, `hideWhenDetached`, `listeners`, `applyStyles`. Defaults are `placement:
"bottom"`, `gutter: 8`, `flip: true`, `slide: true`, `overlap: false`, `overflowPadding:
8`, `arrowPadding: 4` (`get-placement.ts:10-24`). Preferred lists exist only as
`flip: Placement[]` → `fallbackPlacements`; there is no `autoPlacement` middleware anywhere
in the tree. Per-widget defaults differ: tooltip and popover `bottom`, menu and select
`bottom-start` with `gutter: 8`, combobox `bottom` + `sameWidth`, submenu `right-start` with
`gutter: 0`.

**Algorithm.** A fixed middleware order:

```text
offset(mainAxis = gutter + arrowHeight/2, alignmentAxis = shift)
  → flip{boundary, padding: overflowPadding, fallbackPlacements}
  → shift{mainAxis: slide, crossAxis: overlap, padding: overflowPadding, limiter: limitShift()}
  → arrow{element, padding: arrowPadding}
  → shiftArrow → transformOrigin → size → hide → rects
```

The [clipping boundary][concepts] is re-resolved on _every_ tick — `getFlipMiddleware` and
`getShiftMiddleware` both wrap their options in a function so a function-form `boundary`
picks up a late-mounted element (`get-placement.ts:84-108`) — and the same boundary is
forwarded into the `size` middleware so available width/height agree with flip and shift.
The final placement is reported through `onComplete(data.placement)` and stored in
`context.currentPlacement`, the only placement state a machine keeps.

**Where it lives.** Floating UI does flip/shift/size/hide; `@zag-js/popper` configures and
orders them; per-widget defaults live in each machine's `props()`.

**Degradation.** The physical grid plus an explicit fallback list ports directly to integer
cells. Flip and shift need a boundary rect, which on a single surface is the surface rect
minus insets — no clipping-ancestor walk required. Absent here entirely, and therefore
something a cell toolkit must add rather than copy: no safe-area insets, no work areas, no
multi-monitor, and no soft-keyboard/IME avoidance in any overlay machine (`visualViewport`
is read only by `tour`, `safe-area-inset` only by `toast`). With no script nothing in this
dimension survives — the side must be baked at emit time from a guessed anchor position.

### 3. Collision and geometry engine

Overflow detection, clipping-ancestor discovery and transform/zoom compensation are all
inside Floating UI. What Zag owns is the _tracking policy_ and the _write-back_, and both
are more transferable than the math.

Tracking is observer-based, never polling and never a rAF loop: `listeners: true` expands to
`autoUpdate{ancestorResize, ancestorScroll, elementResize, layoutShift}`
(`get-placement.ts:161`), and observers are rebound only when the anchor identity or the
floating node changes.

Write-back is aggressively guarded. Computed `x`/`y` are quantized to the device grid with
`roundByDpr(v) = Math.round(v * dpr) / dpr` (`:44`), and a write is skipped when the delta
is under half a pixel — `isApproximatelyEqual(a, b) = a != null && Math.abs(a - b) < 0.5`
(`:49`, used at `:327` and `:331`). The same guard protects each CSS variable the `size`
middleware exports. `z-index` is probed from computed style exactly once per floating
element, with the reason stated in a comment — "compute z-index only once to avoid forced
reflow on every update" (`:347`). `hideWhenDetached` maps to Floating UI's
`hide({strategy: "referenceHidden"})` and produces `visibility: hidden` plus
`pointer-events: none` rather than an unmount.

Zag has its own overflow-ancestor walker used for _behavior_ rather than layout:
`getOverflowAncestors` climbs parents testing `/auto|scroll|overlay|hidden|clip/` against
`overflow`/`overflowX`/`overflowY`, excludes `display: inline|contents`, and terminates at
`body` by concatenating `window` and `visualViewport`
(`packages/utilities/dom-query/src/overflow.ts:13`). That list drives tooltip's
close-on-scroll and the scrollbar exemption in outside-interaction.

**Algorithm.** `updatePosition()`: sync observers; rebuild the middleware array and reset
`zIndexComputed` if the floating node changed; `pos = await computePosition(...)`;
`x = roundByDpr(pos.x)`, `y = roundByDpr(pos.y)`; `onComplete`; write `--x`/`--y` only when
they moved ≥ 0.5px; apply the `hide` visibility; compute `--z-index` once. `getPlacement()`
can defer the whole first run by one rAF (`defer: true`) so lazily-mounted content is
measurable.

**Degradation.** The _policy_ generalizes and the _math_ mostly does not. Observe rather
than poll, rebind only on identity change, quantize to the output grid, skip writes below a
threshold, defer the first measurement one frame — all four map onto a frame loop, where
quantization is rounding to a whole cell and the skip test is integer equality. What does
not generalize: clipping-ancestor discovery (one surface, one clip stack), DPR/transform
compensation (layout is already in cells), and the `z-index` probe. The `layoutShift` and
`elementResize` observers collapse into "recompute placement every frame from the current
layout", which is plausibly cheaper than the observer machinery they replace.

### 4. Arrow / caret geometry

Arrow geometry _is_ computed data here, but it is emitted as CSS custom properties and
inline styles rather than returned to the machine. Three pieces cooperate.

1. **The arrow feeds the offset.** `getOffsetMiddleware` reads the arrow element's live
   `clientHeight` and adds half of it to the main axis:
   `mainAxis = gutter + arrowEl.clientHeight / 2` (`get-placement.ts:64-70`). Authors set
   `gutter` as the visual gap and the arrow is accounted for automatically.
2. **The cross-axis position is a clamp.** Floating UI's
   `arrow({element, padding: arrowPadding})` clamps the arrow `arrowPadding` away from the
   corners; `shiftArrowMiddleware` (`packages/utilities/popper/src/middleware.ts:103`)
   writes it as `left`/`top` plus `[side]: calc(100% + var(--arrow-offset))`, where
   `--arrow-offset` is `calc(var(--arrow-size) / 2 * -1)` — the arrow hangs half its size
   outside the content box on the anchored side (`get-styles.ts:26-27`).
3. **The [transform origin][concepts] is derived from the arrow centre.**
   `createTransformOriginMiddleware` (`middleware.ts:28-83`) computes
   `transformX = arrowX + arrowWidth/2`, `transformY = arrowY + arrowHeight/2`, and a
   per-side origin with `G = gutter + arrowHeight/2`:

   ```text
   top    → `${transformX}px calc(100% + ${G}px)`
   bottom → `${transformX}px ${-G}px`
   left   → `calc(100% + ${G}px) ${transformY}px`
   right  → `${-G}px ${transformY}px`
   ```

   When `overlap` is enabled, the axis is vertical, and `|shift.y| > G`, it switches to an
   anchor-centre origin instead: `${transformX}px ${rects.reference.y + refHeight/2 - y}px`.

The visible tip is a separate `arrowTip` part: a square rotated by side —
`{bottom: 45deg, left: 135deg, top: 225deg, right: 315deg}` (`get-styles.ts:9-13`) — with
`background: var(--arrow-background)` and `zIndex: inherit`.

Two things are **not** implemented. There is no arrow hiding when the anchor is too narrow:
Floating UI exposes `middlewareData.arrow.centerOffset`, and `grep -rn centerOffset
packages/` returns nothing at this revision, so the caret can point at nothing. And there is
no border-aware arrow (no two-layer stroke trick).

**Degradation.** The decomposition — side, offset along the side, size — is the portable
part. At one-cell granularity `gutter + arrowSize/2` collapses to `gutter` (there is no half
cell), so the caret must be drawn _in_ the gutter row/column rather than hanging half
outside; the rotated square becomes one glyph chosen by side; `arrowPadding: 4` becomes one
cell so the caret never lands on a corner. The clamp is the whole algorithm and it is
already integer arithmetic. `transform-origin` has no meaning without transforms, but the
same datum (side plus caret cell) is what a cell-grid reveal needs as its origin. With no
script the caret must be emitted at a fixed alignment, since the clamp needs measurement.

### 5. Trigger semantics

Triggers are DOM handlers in `connect.ts` that translate into machine events; the machine
never sees a raw DOM event type, only a named event plus a payload (`value`, `triggerId`,
`point`, `target`).

Pointer-type discrimination is explicit and pervasive. Tooltip's `onPointerMove` and
`onPointerOver` return early on `event.pointerType === "touch"`
(`packages/machines/tooltip/src/tooltip.connect.ts:98-110`), so a tooltip cannot be opened
by touch at all. Menu's context trigger inverts the test: every non-mouse pointer path runs
a long-press branch (`packages/machines/menu/src/menu.connect.ts:159-198`) —
`onPointerDown` sends `CONTEXT_MENU_START` into an `opening:contextmenu` state whose
`waitForLongPress` effect fires `LONG_PRESS.OPEN` after 700 ms, while `onPointerMove`,
`onPointerUp` and `onPointerCancel` all send `CONTEXT_MENU_CANCEL`, which exits the state
and thereby cancels the timer. `onContextMenu` (the mouse path) sends `CONTEXT_MENU` with
the event point directly.

Focus is filtered through `isFocusVisible()` from `@zag-js/focus-visible`
(`tooltip.connect.ts:74`), so a mouse click does not also open the tooltip via focus. That
modality oracle is a module-global that patches `HTMLElement.prototype.focus`
(`packages/utilities/focus-visible/src/index.ts:156`).

Multiple triggers do not race, because they are not independent: they send into one machine,
`triggerValue` selects the active one, and `connect` rewrites the event —
`shouldSwitch = open && value != null && !current` turns an `open` / `pointer.move` /
`close` into `triggerValue.set` (`tooltip.connect.ts:68`, `:75`, `:102`). Switching anchors
is therefore a distinct event, never a close followed by an open. Blur is additionally
suppressed when focus moved to another trigger of the same owner —
`activeEl?.closest(getByOwnerId(scope.id)) != null` (`:78-88`).

There is no `keyup` anywhere in the tooltip, popover, menu, select or combobox machines;
every keyboard interaction is keydown-only. There is no keyboard-shortcut trigger, and no
assistive-technology-specific path beyond focus-visible's `virtual` modality.

**Algorithm.** Delay-skipping is a guarded transition pair on one event
(`tooltip.machine.ts:97-108`): `pointer.move` in `closed` takes arm 0 —
`and(noVisibleTooltip, not(hasPointerMoveOpened))` → `opening` — else arm 1 —
`not(hasPointerMoveOpened)` → `open` directly. `hasPointerMoveOpened` stores the
`triggerId` that caused the pointer-open, so a repeat `pointermove` over the same trigger is
idempotent.

**Degradation.** No key release costs nothing here: overlays never use `keyup`. No hover is
already modelled, though bluntly — a hover trigger simply does not fire on touch, and the
context menu supplies a long-press path instead. The transferable idea is the
discrimination itself: hover transitions are guarded on a pointer-kind value carried _in
the event_, not on a compile-time target check, so the same machine behaves correctly on a
stylus or touch screen. With no script only `:hover` and `:focus-within` survive, which is
roughly the subset a tooltip degrades to.

### 6. Timing

[Warm-up][concepts] and [cool-down][concepts] are states, not annotations. Tooltip runs
`closed → opening → open → closing → closed` with defaults `openDelay: 400`,
`closeDelay: 150` (`tooltip.machine.ts:24-25`); hover-card is the same shape with `600` /
`300` (`packages/machines/hover-card/src/hover-card.machine.ts:13`). The tooltip is treated
as visible in _both_ `open` and `closing` — `connect` computes
`open = state.matches("open", "closing")` (`tooltip.connect.ts:19`) — so the cool-down is a
live-but-dying window that a re-entering pointer converts straight back to `open`.

Menu's submenu timing is the same shape but the numbers are hardcoded and unconfigurable:
200 ms open, 100 ms close, 700 ms long-press, written as literals inside the effects
(`menu.machine.ts:563-581`); menu exposes no `openDelay`/`closeDelay` prop at all.

The cross-instance "skip the warm-up when another tooltip is already showing" policy is one
module-global store plus one guard — no provider, no group component:

> noVisibleTooltip: () => store.get("id") === null,
>
> — `packages/machines/tooltip/src/tooltip.machine.ts:275`

The store is three fields (`packages/machines/tooltip/src/tooltip.store.ts:3`). Entering
`open` runs `setGlobalId`, which computes
`isInstant = prevId !== null && prevId !== prop("id")` and writes
`{id, prevId: isInstant ? prevId : null, instant: isInstant}` (`:283-287`); entering
`closed` runs `clearGlobalId`, which clears the store only if this instance owns it
(`:289-293`). A root-level `trackStore` effect (`:416`) subscribes and force-closes any
tooltip whose id is no longer the global one, so "at most one visible" is enforced without
a coordinator.

> [!NOTE]
> There is no grace window after the last tooltip closes. `clearGlobalId` runs on entry to
> `closed`, so the skip-delay period ends the instant the previous tooltip is gone. Whether
> a separate, longer skip window is the better design is a cross-subject question — see
> [`./radix.md`](./radix.md) and [`./comparison.md`](./comparison.md). Max display duration
> does not exist in any of these machines.

**Algorithm.** The delayed transition, in full (`tooltip.machine.ts:441-446`; the
close-delay effect at `:448-453` is the same shape):

```ts
      waitForOpenDelay: ({ send, prop, event }) => {
        const id = setTimeout(() => {
          send({ type: "after.openDelay", previousEvent: event })
        }, prop("openDelay"))
        return () => clearTimeout(id)
      },
```

— verbatim, `packages/machines/tooltip/src/tooltip.machine.ts:441-446`

The effect _returns_ its own `clearTimeout`. Because the interpreter tears a state's effects
down on exit (`packages/frameworks/react/src/machine.ts:232-241`), any event that leaves
`opening` aborts the warm-up and any event that leaves `closing` aborts the cool-down, with
no cancellation logic written anywhere.

**Degradation.** This is the most portable dimension in the design. Timers as state-scoped
effects with cleanup map onto a frame loop directly: on state entry push
`{deadline = now + delay, event}` into a slot owned by the state, clear it on exit, and
drain elapsed slots once per frame. No key release, no hover and no sub-cell precision
affect any of it. With no script the dimension vanishes entirely: `transition-delay` on
`:hover` can reproduce an open delay but not the cool-down, the skip-delay or the singleton.
On a headless recording target everything here is assertable _provided_ the clock is an
input rather than a read — which is the argument for injecting `now`.

### 7. Interactive hover

Two entirely different mechanisms coexist, which is itself the finding.

**Tooltip and hover-card: no bridge, no polygon.** `interactive` defaults to `false` and
only flips the content's `pointerEvents` between `auto` and `none`
(`tooltip.connect.ts:171`); when `auto`, `content.pointer.move` / `content.pointer.leave`
swap the machine between `open` and `closing`. Travel across the gutter is survived purely
by the 150 ms (tooltip) or 300 ms (hover-card) cool-down.

**Menu submenus: a real [safe polygon][concepts].** On pointer-move or pointer-leave over a
submenu trigger, `setIntentPolygon` (`menu.machine.ts:754-768`) builds five points: the
cursor nudged by `bleed` toward the submenu, followed by the four corners of the _submenu
content_ rect ordered by placement side.

> context.set("intentPolygon", [{ ...event.point, x: event.point.x + bleed }, ...polygon])
>
> — `packages/machines/menu/src/menu.machine.ts:767`

`bleed` is `-5` for a right-side submenu and `+5` otherwise, pushing the apex slightly _into_
the submenu. `getElementPolygon` (`packages/utilities/rect/src/polygon.ts:4-15`) selects the
corner order by base side so that the two corners nearest the parent come first. Membership
is a standard even-odd ray cast over the five edges (`polygon.ts:17-32`): per sample, five
iterations of two comparisons, one multiply and one divide.

While in `closing`, the `trackPointerMove` effect (`menu.machine.ts:654-673`) subscribes to
document `pointermove` and tests each sample; the first sample outside the polygon sends
`POINTER_MOVED_AWAY_FROM_SUBMENU` and closes immediately, otherwise the 100 ms cool-down
decides.

Orthogonally — and this is the half that is easy to miss — a `pointerRoutingLocked` ref
suppresses the _parent's_ highlight updates while the pointer is travelling.
`ITEM_POINTERMOVE` is a two-arm transition (`menu.machine.ts:475-483`): unlocked sets the
highlight, locked only records `lastHighlightedValue`, and a `HIGHLIGHTED.RESTORE` puts it
back when the submenu closes. That is why skimming diagonally across sibling items does not
flash the highlight. `closeSiblingMenus` (`:874`) additionally refuses to close a sibling
whose own `intentPolygon` still contains the pointer, and `unlockParentAfterChildClose`
(`packages/machines/menu/src/menu.utils.ts:35-65`) declines to unlock while the parent's
highlighted item still has an open submenu.

**Degradation.** The routing lock is pure state with no geometry and ports unchanged; it is
the half that survives even where the corridor is zero cells wide, and Zag itself sets the
submenu `gutter` to 0. The geometry half needs care. INFERENCE: at whole-cell resolution the
ray cast appears reducible to an integer trapezoid membership test — for a right-side
submenu, `inside == cursorCol ≤ col ≤ subLeftCol` and the row between two linear
interpolations of the submenu's near edge — which would be a handful of integer operations
evaluated once per cell crossed. That is an inference about a port, not an observation of
Zag, and it is _not_ the claim that a polygon and its bounding box select the same cells;
they do not in general. With no hover the dimension is dead; with no pointer [grab][concepts]
the document-level `pointermove` subscription becomes a surface-level one, which is strictly
easier in a toolkit that owns its own routing.

### 8. Dismissal

[Light dismiss][concepts] is centralized in `@zag-js/dismissable` (`trackDismissableElement`)
over `@zag-js/interact-outside`, and every overlay machine _except tooltip_ uses it.

- **Escape.** A capture-phase document `keydown`, filtered on `event.isComposing` and gated
  by `layerStack.isTopMost(node)` so only the top layer reacts
  (`packages/utilities/dismissable/src/dismissable-layer.ts:132-135`); the handler
  `preventDefault`s so a parent does not also act. Tooltip opts out of the layer stack
  entirely and hand-rolls `trackEscapeKey` (`tooltip.machine.ts:428-439`).
- **Outside pointer.** Capture-phase `pointerdown` on the document, on the parent window,
  and on every same-origin child frame. For `pointerType === "touch"` dismissal is deferred
  to the subsequent `click` so a scroll flick does not dismiss
  (`packages/utilities/interact-outside/src/index.ts:203-212`); for mouse it fires on
  `pointerdown`.
- **Outside focus.** Capture-phase `focusin`, but skipped entirely while a pointer is down
  — `if (isPointerDown) return` (`interact-outside/src/index.ts:226`) — and not registered
  at all on touch devices. Safari does not focus buttons on `pointerdown`, so without this
  the two outside paths race.
- **Anchor scroll.** Tooltip closes on scroll of any overflow ancestor (capture, passive),
  configurable via `closeOnScroll` (`tooltip.machine.ts:392`); other overlays reposition
  instead.
- **Anchor hidden.** `hideWhenDetached` produces `visibility: hidden`, not a dismissal.
- **Parent closing.** `layerStack.remove(node)` dismisses every nested layer above it, each
  through a cancellable `layer:request-dismiss` `CustomEvent`, so a child can veto its own
  teardown (`packages/utilities/dismissable/src/layer-stack.ts:104-134`, `:154-176`).
- **Trigger re-activation.** Tooltip closes on trigger click and pointerdown
  (`closeOnClick`, `closeOnPointerDown`, the latter defaulting to the former); a menu
  `TRIGGER_CLICK` while open closes unless the trigger is itself a menu item.
- **Not handled at all.** Window/app deactivation and navigation.

`isEventOutside` (`interact-outside/src/index.ts:133-161`) rejects a candidate — treats it
as _inside_ — when the target is disconnected, contained, geometrically inside the node's
bounding rect even though not a descendant (`isEventPointWithin`, `:72`), inside an element
the node `aria-controls` with `aria-expanded=true`, on the scrollbar gutter of the nearest
overflow ancestor of either the node or its controlled trigger (`isEventWithinScrollbar`,
`:90`, with 16px of slop), or matched by the caller's `exclude` — which covers its own
triggers, `persistentElements`, and every nested layer above it
(`dismissable-layer.ts:141-148`).

Escape inside a submenu is a deliberate deviation: `onEscapeKeyDown`
(`menu.machine.ts:632`) `preventDefault`s the layer dismissal and instead walks parents to
the root, closing the whole tree.

**Degradation.** Every rule here is a routing decision, and on a single surface the router
already knows what is inside which overlay — "is this event outside" collapses to "which
overlay did the hit list resolve to". The rules worth carrying, none of which need a DOM:
escape only the topmost; touch dismisses on release, not press; suppress focus-outside while
a pointer is down; a closing parent cascades to children with a vetoable request; and an
outside press landing geometrically inside the surface's own rect is not outside. Android's
system back key slots in exactly where Escape does, topmost-gated. With no pointer grab an
outside press that leaves the surface is never delivered at all, so "the pointer left the
surface" has to become a dismissal _input_ — which Zag has no equivalent of, because
document-level capture makes the question moot.

### 9. Focus

Sharply differentiated per widget, and the differences are visible in the code.

- **Tooltip never moves focus.** It only _reads_ focus — `onFocus`/`onBlur` on the trigger,
  gated by `isFocusVisible()`.
- **Popover's [focus scope][concepts] is a function of `modal`.** Non-modal gets
  `setInitialFocus` (a rAF, then `getInitialFocus`) plus `proxyTabFocus`
  (`popover.machine.ts:197-208`) so tabbing out of portalled content lands after the trigger
  in document order rather than looping. Modal gets `trapFocus` (`:221`) with
  `returnFocusOnDeactivate`, and `setFinalFocus` (`:296`) prefers `finalFocusEl`, then the
  active trigger, then the first trigger, then whatever the trap chose — honouring a
  per-event `restoreFocus: false` set when the outside interaction landed on something
  focusable or was a context menu, so clicking another input does not steal focus back.
- **Menu contains without trapping.** The content itself is `tabIndex: 0` and takes DOM
  focus; items are never focused — highlight is `aria-activedescendant` only
  (`menu.connect.ts:351`). `focusMenu` (`menu.machine.ts:793-805`) calls `getInitialFocus`
  with a filter that _excludes_ anything whose role starts with `menuitem`, so a submenu
  containing a focusable non-item control still works. Tab is intercepted by
  `isValidTabEvent`, which permits Tab only when it would leave from the first or last
  tabbable edge (`packages/utilities/dom-query/src/initial-focus.ts:32-45`). Closing
  restores focus to the trigger, skipped for submenus and for point-anchored context menus;
  a closing submenu sends `FOCUS_MENU` to its parent.

`getInitialFocus` is an explicit four-step priority, with in-source comments naming each step
(`initial-focus.ts:11-30`): the explicit override, then `[data-autofocus]`/`[autofocus]`
(opt-in outranks opt-out), then the first tabbable without `[data-no-autofocus]`, then the
content root itself so that a fully opted-out surface still receives focus.

Pointer-versus-keyboard opening is decided by a one-slot event history: the opening event is
stashed as `event.previousEvent`, and guards read `previousEvent.type` —
`isArrowDownEvent` highlights the first item, `isArrowUpEvent` the last, `OPEN_AUTOFOCUS`
the first, anything else highlights nothing — the three arms of `CONTROLLED.OPEN` in the
`closed` state (`menu.machine.ts:342-355`), with the guards at `:557-560`.
`scrollToHighlightedItem` (`:674`) additionally suppresses scrolling when
`getInteractionModality() === "pointer"`, so hovering an item near a scroll edge cannot
scroll the list under the cursor.

**Degradation.** The tooltip ≠ popover ≠ menu taxonomy is the transferable part: tooltip
never touches focus; menu contains but does not trap and uses activedescendant, so "focus"
is a value in machine context; popover traps only when modal. On a canvas toolkit where
focus is already an id in state, the activedescendant model is the native one and the
DOM-focus model is the alien one. The four-step initial-focus priority is pure policy over
an ordered tabbable list, which layout can produce. No key release changes nothing (Tab is
handled on keydown). On a recording target all of it is assertable, since focus is a value.

### 10. Layering and portals

Zag never uses the browser [top layer][concepts]: no `dialog.showModal`, no `popover`
attribute anywhere in the tree. Layering is a framework `Portal` component that
`createPortal`s into `container ?? doc.body`
(`packages/frameworks/react/src/portal.tsx:13`), plus one mutable module-global array
(`packages/utilities/dismissable/src/layer-stack.ts:27`) of
`{node, type, pointerBlocking, dismiss, requestDismiss, styleTargets}`.

The stack is ordered by _registration_ — open order, not DOM order — and it is the sole
source of truth for topmost, nested, below-a-blocking-layer, and "is this target inside a
child overlay". `syncLayers()` (`:139`) reindexes and `applyLayerStackMetadata` (`:182`)
writes `--layer-index`, `--nested-layer-count`, `data-nested`, `data-has-nested` onto each
layer node and onto any declared `styleTargets` (a dialog backdrop, a positioner), mirroring
the node's computed `z-index` into `--z-index` there. `z-index` itself is left to CSS.
`branches` is a second registry for portalled subtrees that must count as inside without
being layers. `LayerType` is an open union of `"dialog"`, `"popover"`, `"menu"`,
`"listbox"` and an escape hatch for arbitrary strings, used for type-scoped nesting
queries.

**Algorithm.** `add` is idempotent per node: an existing entry is spliced out and the new one
pushed, so re-adding re-tops rather than duplicating — the in-source comment names React
Strict Mode as the motivating case (`:91-100`). `isTopMost(node)` is
`layers[count-1].node === node`. `getNestedLayers(node)` is `layers.slice(indexOf(node)+1)`.
`remove(node)` marks the node in a `recentlyRemoved` set for two frames, dismisses every
nested layer above it, splices and reindexes (`:104-134`).

**Public API versus implementation.** Public: the `Portal` component, the
`positioner`/`content` part split (the positioner is the transform target, the content the
styled box), `persistentElements`, `layerStyleTargets`, and the emitted `data-*` and CSS
variables. The `layerStack` itself is exported but undocumented. Notably the overlay _tree_
is not owned by the library for menus: submenu parent/child links are wired by the
application calling `api.setParent(parentService)` / `api.setChild(childService)`, each
level being an independent machine with its own portal
(`examples/next-ts/pages/menu/nested.tsx:22-28`).

**Degradation.** "Front to back == later in the list" is precisely what `layerStack` already
encodes, and every use it puts the stack to — topmost gating for escape, nested-is-inside
for outside detection, cascade dismissal, nested counts for styling — is available without
portals, `z-index` or stacking contexts, because those are consequences of tree-scoped
painting that a flat display list does not have. What to drop: `--z-index` mirroring,
pointer-events juggling, `styleTargets`, and the `MutationObserver` defence against
frameworks rewriting the `style` attribute. What to improve: ownership. Zag's own menu tree
has to be assembled by the application precisely because a flat stack keyed by node cannot
express parent/child, and "is this target inside my subtree" then needs a recursive walk
over `refs.children` (`menu.dom.ts:130`).

### 11. Modality

[Modality][concepts] is a bundle of four independent effects a machine opts into, not one
flag in a primitive. Popover's `modal` (default `false`) enables `trapFocus`,
`preventBodyScroll`, `ariaHidden` over `[content, activeTrigger]`, and `pointerBlocking` on
the dismissable layer; non-modal instead gets `proxyTabFocus`
(`popover.machine.ts:107-113`, `:210-228`).

Pointer blocking is implemented in `packages/utilities/dismissable/src/pointer-event-outside.ts`
in two halves. Per-layer: `getDesiredPointerEvents(node)` (`:8`) returns `"none"` when the
node is below the topmost pointer-blocking layer and `"auto"` otherwise, applied to every
layer. Globally: `disablePointerEventsOutside` (`:47`) sets `body.style.pointerEvents =
"none"` plus `[data-inert]` while any blocking layer exists, and restores on the last
teardown. Because some frameworks' prop spreading rewrites the entire `style` attribute,
each layer node also gets a `MutationObserver` on `attributes: ["style"]` that reasserts the
value (`ensurePointerEventsObserver`, `:19-33`) — the changelog records this as a real bug
fix. `persistentElements` are awaited with a `waitForElement` poll (`:63`) before being
granted `pointerEvents: auto`, so a third-party portal that mounts after the modal opens is
not permanently unclickable.

The accessibility modality bit is `aria-modal={modal}` on popover content plus
`role="dialog"` (`packages/machines/popover/src/popover.connect.ts:118-126`). Menus use
`role="menu"` (or `role="dialog"` when `composite: false`) and are never `aria-modal`.
Keyboard blocking is not separately implemented — it falls out of the focus trap. There is
no scrim in popover or menu; `dialog` and `drawer` own the backdrop part. Light dismiss is
the default everywhere, and "modeless but focus-containing" is exactly the menu.

**Degradation.** The decomposition is the lesson: modal is not one bit but four —
trap focus, block background pointers, hide background from assistive tech, lock background
scroll — and each is separately wanted (blocking pointers without trapping focus, for a
transient teaching tip). On a canvas toolkit, background pointer blocking is a routing rule
— stop hit testing below overlay index k — needing neither `pointer-events` nor observers,
and scroll locking is the same rule for wheel events. `aria-hidden` has no canvas analogue
and must be replaced by whatever accessibility bridge exists (dimension 13). No OS window
changes nothing; with no script all of it is lost.

### 12. Adaptive presentation

Zag performs **no automatic adaptation**, and the absence is instructive. There is no
popover-to-sheet switch, no compact-width breakpoint, no reduced-input mode. The `drawer`
machine is a separate component the _application_ chooses; nothing selects between drawer
and popover.

The only adaptations present are input-modality ones inside a single component, and they are
all-or-nothing: tooltip's pointer handlers return early on `pointerType === "touch"` — so a
tooltip is simply unreachable by touch, with no long-press substitute — while menu's context
trigger runs a distinct long-press path for non-mouse pointers.

Teaching tips exist as a separate `tour` machine in which the _step author_ declares the
presentation: `StepType = "tooltip" | "dialog" | "wait" | "floating"`
(`packages/machines/tour/src/tour.types.ts:22`) and
`StepPlacement = Placement | "center"` (`:28`). `trackPlacement`
(`packages/machines/tour/src/tour.machine.ts:532`) branches on the step type — `dialog`
steps get no positioning at all beyond `z-index` sync, `tooltip` steps run `getPlacement`
against the resolved target with the spotlight inflation applied through `getAnchorRect`
(`:557`), `floating` steps get neither. Keyboard-driven relocation does not exist.

Which layer owns the decision is unambiguous: the application (which machine to instantiate)
or the content author (which step type), never the primitive and never the backend.

**Degradation.** Zag's answer to "no hover on touch" is to make the hover-only surface not
exist there and to offer a _different component_ for the touch idiom. The same choice is
available to a cell toolkit and is cheaper there, because the target's capability tier is
known statically per backend — but the honest consequence is that a target without hover
should not silently lose the content; it should route the same content through a different
affordance, decided one layer above the overlay primitive, with the primitive merely
declaring that this surface requires hover. The soft-keyboard inset is the adaptive input
Zag has no concept of and a mobile-capable toolkit must model explicitly as a placement
input (see [`../window-system-integration/index.md`](../window-system-integration/index.md)).

### 13. Accessibility

Semantics live in `connect.ts` and are per-widget; the shared primitives (`popper`,
`dismissable`, `focus-trap`) emit no ARIA whatsoever.

- **Tooltip.** Content gets `role="tooltip"` and an id referenced by the trigger's
  `aria-describedby` (`tooltip.connect.ts:63`) — _unless_ an `aria-label` prop is supplied,
  in which case both the role and the id are dropped and the label wins
  (`:160-161`, computed from `hasAriaLabel` at `:17`). A tooltip that supplies a label is
  therefore purely visual.
- **Popover.** Trigger gets `aria-haspopup="dialog"` + `aria-expanded` + `aria-controls`;
  content gets `role="dialog"`, `aria-modal` only when modal, and `aria-labelledby` /
  `aria-describedby` only if a title/description part was actually rendered.
  `checkRenderedElements` (`popover.machine.ts:274`) probes the DOM in a rAF on entry to
  decide.
- **Menu.** `role="menu"` when composite (default) or `role="dialog"` when `composite: false`
  (`menu.connect.ts:229` for the trigger's matching `aria-haspopup`); `tabIndex: 0`;
  `aria-activedescendant` naming the highlighted item (`:351`); `aria-labelledby` pointing
  at the context trigger when point-anchored, otherwise the trigger; items are
  `menuitem`/`menuitemcheckbox`/`menuitemradio` with `aria-checked`.

WCAG 1.4.13 (Content on Hover or Focus) is only partly addressed. The `interactive` prop's
own doc comment links the success criterion — "In this mode, the tooltip will remain open
when user hovers over the content. @see https://www.w3.org/TR/WCAG21/#content-on-hover-or-focus"
— and then declares `@default false`
(`packages/machines/tooltip/src/tooltip.types.ts:70-77`). Out of the box, tooltip content is
`pointerEvents: none` and cannot be hovered; it _is_ dismissible (Escape, on by default) and
persistent only for the 150 ms cool-down. The hover-only-on-touch hazard is "solved" by
making the tooltip unreachable there. Native accessibility trees are not touched at all: no
AOM, no platform bridges. See [`./aria-apg.md`](./aria-apg.md) for the normative contract.

**Degradation.** The split Zag demonstrates is the useful one: the anchored-overlay
primitive owns zero semantics — geometry, timing, dismissal, layering — while
role, description-versus-label, and activedescendant belong to the semantic component built
on it. That also means the primitive must _carry_ an opaque semantic payload it never
interprets. Portable rules: describedby-versus-label is a real fork; only emit a description
relationship if the description part exists; menu highlight is activedescendant, not focus.
On a canvas with no accessibility API these attributes can only become metadata on the
display list for a future bridge; the behavioural half (Escape dismissal, persistence,
non-hover reachability) is the part that can actually be guaranteed — and `interactive:
false` is the default _not_ to copy.

### 14. Animation

Geometry metadata is emitted specifically to enable animation, and this is among the
cleanest parts of the design. Every floating machine exposes, on the placement-aware parts,
`data-placement` (the full 12-value placement), `data-side` (the base side), and
`data-state` of `"open"` / `"closed"` (`tooltip.connect.ts:158-163`). The popper writes
`--transform-origin` derived from the arrow centre so a scale-in grows out of the caret (see
dimension 4), plus `--x`, `--y`, `--z-index`, `--reference-width`, `--reference-height`,
`--available-width`, `--available-height` as CSS variables so a stylesheet can react with no
JS in the loop. Repositioning during an exit animation is handled by `applyStyles: false`
(`packages/utilities/popper/src/types.ts:25`), which stops the popper writing `--x`/`--y` so
the consumer can drive them.

The mount lifecycle is a separate machine, `@zag-js/presence`, holding
`{mounted, unmountSuspended, unmounted}`. When `present` flips false it rAFs, reads
`getComputedStyle(node).animationName`, and unmounts **immediately** when the name is
`"none"`, unchanged from the previous name, `display` is none, or the duration is `0s`;
otherwise it suspends, forces `animationFillMode: "forwards"`, and waits for an
`animationend`/`animationcancel` whose `animationName` matches the recorded unmount name and
whose target is the node itself (`presence.machine.ts:118-146`, `:160-197`). It also
short-circuits straight to unmounted when `node.ownerDocument.visibilityState === "hidden"`
(`:125-127`) — a backgrounded tab never fires `animationend`.

Tooltip adds `data-instant` on the content, computed from the global store
(`tooltip.connect.ts:147-149`):

```text
isCurrentTooltip = store.id === id
isPrevTooltip    = store.prevId === id
instant = store.instant && ((open && isCurrentTooltip) || isPrevTooltip)
```

so the flag is set for the incoming tooltip _and_ for the outgoing one — sweeping across a
toolbar produces one continuous label rather than N fade cycles.

> [!NOTE]
> No overlay machine in these packages reads `prefers-reduced-motion`. The repository does
> contain two such rules, both in demo/website CSS, none in the overlay path. Spring
> animation does not exist here.

**Degradation.** The metadata contract — the geometry engine tells the styling layer which
side won, where the caret landed, and whether this transition should be instant — is the
reusable idea, and in cells "side plus caret column" is precisely what a directional reveal
needs. `presence`'s algorithm, by contrast, exists only because CSS owns the timeline and
the machine must guess when it ends; a toolkit that owns its own timeline collapses it into
the same delay-as-effect pattern as dimension 6, which is strictly simpler. With no script
only `data-state` survives, driven by `:hover`.

### 15. State architecture

The declarative half is genuinely data; the execution is not shared.

**Vocabulary.** `props(normalizer)` / `context` (bindable cells with
`defaultValue|value|onChange`) / `refs` (non-reactive slots) / `computed` / `watch` /
`initialState(fn)` / `entry|exit|effects` at root and per state / `states{tags, entry, exit,
effects, initial, states, on}` / `on{target, guard, actions, reenter}` /
`implementations{guards, actions, effects}` keyed **by name**
(`packages/core/src/types.ts:176-241`). Guards, actions and effects are referenced as
strings in the declarative half and implemented in a separate table, so a `machine.ts` file
contains no closures. Guard combinators `and`/`or`/`not` are pure. Transitions may be arrays
and the first passing guard wins — there is no conflict resolution beyond order.

**Target resolution** is pure string algebra over dotted paths (`packages/core/src/state.ts`):
`#id` is absolute via an id index, `.child` is relative-down, and a bare name is resolved as
a **sibling**, searched from the parent scope upward:

> // Bare name = sibling resolution (aligned with XState/SCXML semantics).
> // Siblings are checked from parent scope upward, never children of the source.
>
> — `packages/core/src/state.ts:168-169`

**Exit/enter** is a standard LCA diff over those paths (`state.ts:209-239`): advance a common
index while `prevChain[i].path === nextChain[i].path`, then `exiting =
prevChain.slice(common).reverse()` (deepest first) and `entering = nextChain.slice(common)`.
`reenter` on a transition forces a full exit/enter of an identical leaf. The React
interpreter's `onChange` (`packages/frameworks/react/src/machine.ts:232-272`) executes, in
order: exit-effect teardowns, exit actions, transition actions, entering effects, root
entry/effects on first run, entry actions.

**Effects are keyed by state path and torn down on exit only** — there is no dependency
list. The sharpest consequence is a documented round trip in tooltip:

```ts
        "triggerValue.set": {
          // Transition to closing (which cleans up trackPositioning) then immediately back to open
          // This re-creates the positioning effect with the new trigger
          target: "closing",
          actions: ["setTriggerValue", "immediateReopen"],
        },
```

— verbatim, `packages/machines/tooltip/src/tooltip.machine.ts:206-211`

**Controlled versus uncontrolled** is modelled by duplicating every transition behind an
`isOpenControlled` guard — ten such arms in the tooltip machine alone — plus a
`watch(prop("open")) → toggleVisibility → send("controlled.open" | "controlled.close")`
round trip that performs the actual state change (`tooltip.machine.ts:337-343`,
guard at `:279`). `send` is asynchronous in every interpreter (`queueMicrotask`,
`react/src/machine.ts:117-118`) and `toggleVisibility` queues another microtask on top, so a
single gesture can span several turns.

**Would this survive a non-DOM, value-semantics toolkit?** The declarative half, yes — and
INFERENCE: it would likely get _better_ in a compiled language, since state names become an
enum, dotted paths a compile-time index, guard/action/effect names enum members dispatched
by switch, transition tables immutable static data, and `getExitEnterStates` two integer
walks over path arrays. The imperative half, no. The concrete blockers, each observable in
the source:

1. `Scope` is a **document** abstraction, not an environment abstraction. It has eight
   members — the optional identity fields `id` and `ids`, plus `getRootNode`, `getById`,
   `getActiveElement`, `isActiveElement`, `getDoc`, `getWin`
   (`packages/core/src/types.ts:78-87`) — all DOM-scoped, implemented over
   `getElementById`/`getDocument` in `core/src/scope.ts`. The six framework packages that
   ship are all web. Every action still resolves elements by string id and calls
   `getBoundingClientRect`, `focus` or `style` directly.
2. `context` is bindable _reactive cells_ with per-framework storage and `onChange`
   callbacks; a value-semantics port wants one plain struct diffed after each transition.
3. Effects are closures returning closures, capturing mutable locals (`lastX`/`lastY` in the
   positioning loop); a no-GC port wants a disposable handle plus a subscription table.
4. `refs` hold live child `Service` objects with parent↔child cycles (menu), which must
   become arena indices.
5. The vanilla interpreter re-runs `machine.props()` and reallocates the merged props object
   on every `prop(key)` read (`packages/frameworks/vanilla/src/machine.ts:96`).
6. Asynchronous `send` changes semantics; a frame-drained queue is the natural port, but the
   controlled-mode microtask dance would need redesigning.
7. Cross-instance policy (the tooltip store, the `layerStack`) is module-global mutable
   state.

> [!WARNING]
> The escape hatch is leaky in practice and only visible by reading the source: tooltip's
> `trackEscapeKey` registers on the ambient global `document`
> (`tooltip.machine.ts:438`) rather than `scope.getDoc()`, unlike every other overlay
> listener in the tree — so a tooltip in another realm would listen on the wrong document.
> No test covers it and none was run here.

**Degradation.** Nothing in this dimension depends on a window, hover, sub-cell precision or
key release; the FSM is the layer that survives every target. On a headless recording target
the whole machine is assertable provided two things are injected: the clock (for the delay
effects) and the layout snapshot (for anything geometric). With no script the machine cannot
run at all, so a static target must be able to emit **one precomputed state** — which is
what Zag's SSR path does: `hidden`, `data-state="closed"`, and the off-screen
`translate3d(0, -100vh, 0)` the positioner carries until a placement exists
(`packages/utilities/popper/src/get-styles.ts:49-53`).

### 16. Shared infrastructure

Sharing is by small single-purpose packages composed in each machine's `open` state — no
base class, no shared `AnchoredOverlay`, no mixins.

| Shared package        | Consumers                                                                                                          |
| --------------------- | ------------------------------------------------------------------------------------------------------------------ |
| `@zag-js/popper`      | 10 machines: cascade-select, color-picker, combobox, date-picker, hover-card, menu, popover, select, tooltip, tour |
| `@zag-js/dismissable` | 13 machines: those plus dialog, drawer, navigation-menu, toast — minus tooltip                                     |
| `@zag-js/focus-trap`  | 4 machines: dialog, drawer, popover, tour                                                                          |

Below those sit `@zag-js/dom-query` (typeahead, tabbable, initial-focus, overflow,
interact-outside helpers, platform sniffing, rAF, visual-viewport, proxy-tab-focus),
`@zag-js/rect-utils` (polygon, corners, intersection, alignment), `@zag-js/anatomy` (the
part vocabulary), `@zag-js/core` (`mergeProps` for handler composition) and
`@zag-js/focus-visible`.

The per-machine repetition is substantial and visible: `currentPlacement`, `triggerValue`,
`toggleVisibility`, `isOpenControlled`, the reposition action, the positioning effect, and
`invokeOnOpen`/`invokeOnClose` are re-implemented in tooltip, popover, menu, hover-card,
select and combobox with only small differences — and even the _name_ differs, so the same
`getPlacement` call appears as `trackPositioning` in popover
(`popover.machine.ts:152-164`) and as `computePlacement` in select
(`packages/machines/select/src/select.machine.ts:486-497`). The library accepts duplication
over a shared base.

**What is genuinely common** — validated by 10-13 consumers — is anchor-plus-placement
computation and its result datum; the layer stack and the outside/escape/topmost rules;
open/closed plus delay states; controlled/uncontrolled plumbing; and placement metadata
emission. **What looks common but is deliberately kept apart**, with the reasons visible in
the source:

- _Focus_: three incompatible models (tooltip never touches it, menu contains via
  activedescendant, popover traps only when modal, dialog always traps).
- _Delays_: tooltip and hover-card expose them as props with different defaults; menu
  hardcodes 200/100/700 and exposes nothing.
- _Collections_: select/combobox/listbox share a `collection` abstraction that menu does not
  use — menu items are DOM-queried by role selector (`menu.dom.ts:58`).
- _Escape semantics_: a submenu's Escape closes the whole tree; a nested dialog's closes only
  itself.
- _Typeahead_: menu/select/listbox/tree, but not popover/tooltip
  (`packages/utilities/dom-query/src/typeahead.ts:17`).
- _Modality_: a four-part bundle only dialog/drawer/modal-popover want.

**Degradation.** The two strongest structural signals here are that tooltip — the simplest
overlay — opts out of the shared dismissal layer entirely, and that menu's submenu tree has
to be assembled by the application because the shared layer stack cannot express ownership.
Both argue against one monolithic overlay type and for an overlay _stack_ plus per-widget
machines. The ordered named-effect list is directly portable and gives a natural place to
hang a per-target capability gate — skip `trapFocus` on a target with no focus concept. What
a single-surface port would keep inside a shared primitive: the anchor value, placement plus
fallbacks against the surface rect, the resolved side and caret cell, the open/opening/
open/closing timing with an injected clock, stack membership with topmost/nested/cascade
rules, dismissal inputs, and the placement metadata. What it would keep out: focus policy,
item collections and typeahead, modality bundles, selection, and per-widget semantics.

## Strengths

- The declarative half of the chart is data: states, tags, entry/exit/effects and guarded
  transition arrays with guards, actions and effects referenced by string name. Nothing in a
  `machine.ts` closes over mutable state.
- Timers are structurally cancellable. A delay is an effect owned by a state and the
  interpreter tears effects down on exit, so no "clear the pending timer" logic appears
  anywhere — a stale timer is impossible by topology rather than by discipline.
- Warm-up and cool-down are first-class states, and the surface counts as visible during the
  cool-down, so re-entry is a transition rather than a cancellation; "never showed" and
  "dying" are distinguishable states.
- Placement metadata is emitted deliberately for the styling layer: `data-placement`,
  `data-side`, `data-state`, `data-instant`, plus `--transform-origin` derived from the
  arrow centre.
- The safe polygon is small, pure and stored as machine context data (five points, one
  even-odd test), and it is paired with a state-only routing lock that keeps the parent's
  highlight stable during travel.
- Outside-interaction classification handles a long tail of real hazards: scrollbar gutters,
  injected overlays that are geometrically inside but not descendants, touch drags,
  Safari's pointerdown-does-not-focus race, and focus escaping a layer mid-teardown.
- Escape is gated on `layerStack.isTopMost` and `preventDefault`s, so nesting works without
  every layer re-deriving whether it is on top.
- Modality is decomposed into four independently selectable effects rather than one boolean.
- Focus policy is deliberately different per widget and the differences are legible in the
  code.
- Playwright coverage targets exactly the hard cases: diagonal travel across sibling items
  toward a submenu, moving to a submenu and back, closing a submenu by moving to a parent
  item, and tooltip-to-tooltip switching.

## Weaknesses

- `@zag-js/core` is not a runtime. `createMachine` returns its argument, and the interpreter
  is duplicated across six framework packages; the changelog records behavioural drift
  between them (bindable `value`/`defaultValue` precedence in Vue/Svelte; exit actions
  running for never-started machines in Solid/Svelte).
- There is no environment abstraction — `Scope` abstracts _which_ document, not whether
  there is one — and the abstraction leaks (`tooltip.machine.ts:438` uses the ambient
  `document`).
- `send` is asynchronous everywhere, and several actions queue another microtask, so one
  gesture can take multiple turns to settle; the E2E suite contains explicit small waits.
- Effects have no dependency list and can only be re-parameterized by leaving and re-entering
  their state — the tooltip transitions `open → closing → open` to rebuild its positioning
  effect.
- Controlled-mode support roughly doubles every machine and is duplicated verbatim across
  tooltip, popover, menu, hover-card, select and combobox.
- The floating-overlay skeleton is copy-pasted into ten machines, down to three different
  names for the same delayed-transition event (`after.openDelay` in tooltip, `DELAY.OPEN` in
  menu, `OPEN_DELAY` in hover-card).
- Menu's submenu timings are hardcoded (200/100/700 ms) while tooltip and hover-card expose
  theirs.
- Cross-instance coordination is module-global mutable state (the tooltip store, the
  `layerStack`) — per bundle rather than per document, with no owner.
- `@zag-js/focus-visible` monkey-patches `HTMLElement.prototype.focus` globally.
- There are essentially no unit tests for the overlay machines themselves; correctness rests
  on Playwright E2E plus tests for the pure helpers (core state resolution, layer stack,
  focus trap). Machine behaviour is not assertable headlessly.
- No arrow hiding: `middlewareData.arrow.centerOffset` is never read, so the caret can point
  at nothing when the anchor is narrower than the padding allows.
- No handling of virtual-keyboard insets, safe areas or work areas in any anchored overlay.
- Escape inside a submenu closes the entire menu tree — deliberate, but unannounced.
- The vanilla interpreter re-evaluates `machine.props()` and allocates a fresh merged props
  object on every `prop(key)` read.

## Key design decisions and trade-offs

| Decision                                                                                                                                                             | Rationale                                                                                                                                                                                                                      | Trade-off                                                                                                                                                                                                                                                                                                                |
| -------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Make the statechart plain data with guards/actions/effects referenced by name and implemented in a separate table; put the interpreter outside the core.             | One description executed by six reactive runtimes; the chart stays serializable and inspectable (the examples ship a state visualizer); no closures in the declaration.                                                        | The interpreter is duplicated six times and has drifted. `@zag-js/core` is left so thin it is essentially a path-algebra library, so "framework-agnostic" guarantees the description, not the behaviour.                                                                                                                 |
| Drop `after`, `invoke`, activities, parallel regions and history; express delays as state-scoped effects that send synthetic events.                                 | Keeps the runtime tiny and makes cancellation structural — exiting a state runs its effect teardown, so no timer can outlive its state. The repo's own guidance is "Simple Machines: avoid complex nested states, spawn, etc." | Warm-up/cool-down become extra states in every machine, and delay handling is re-implemented per widget with inconsistent event naming and inconsistent configurability (menu hardcodes its three durations).                                                                                                            |
| Scope the environment only as far as "which document/shadow root".                                                                                                   | Solves the problems Zag actually has — iframes, shadow DOM, multiple realms — with eight members and no indirection cost, while letting implementations call `getBoundingClientRect`/`focus` directly.                         | Not portable off the DOM: elements are resolved by string id at action time, layout is read synchronously mid-action, and the hatch leaks (`tooltip.machine.ts:438`).                                                                                                                                                    |
| Model controlled versus uncontrolled by duplicating every transition behind an `isOpenControlled` guard plus a `watch → toggleVisibility → controlled.*` round trip. | One machine serves both modes, and in controlled mode the state change always originates from the prop, so the machine cannot diverge from its owner.                                                                          | Ten guarded arms in tooltip alone; machines roughly double in size; the round trip costs extra microtask turns, and in-source comments mark where the pattern leaks.                                                                                                                                                     |
| Delegate all positioning to Floating UI behind a wrapper that writes CSS custom properties rather than returning geometry to the machine.                            | No collision detection to reimplement; the machine's positional state stays at one field; the style layer can animate and clamp with no JS in the loop.                                                                        | The geometry is invisible to the machine and untestable without a browser; the wrapper accumulates DOM-tax micro-optimizations (0.5px write suppression, once-only `z-index` probe, `MutationObserver` reassertion); and CSS-only concerns (`sameWidth`, `fitViewport`, `sizeMiddleware`) leak into the positioning API. |
| Do not own the overlay tree: the layer stack is flat and keyed by DOM node, and submenu parent/child links are wired by the application.                             | The stack is usable by any component from any framework with no registration ceremony, and each menu level stays an ordinary machine with its own portal.                                                                      | Ownership is inexpressible, so the tree is reconstructed by hand in userland, cross-level behaviour is plumbed through refs holding live sibling services (parent↔child cycles), and "is this target inside my subtree" needs a recursive walk.                                                                          |
| Default tooltip content to non-interactive and make tooltips unreachable by touch.                                                                                   | Stops the tooltip from stealing pointer events over its own trigger, and avoids inventing a touch idiom for a hover-only affordance.                                                                                           | The default does not satisfy the hoverable half of WCAG 1.4.13 that the prop's own doc comment cites, and touch users get no path to the content — even though the same library implements a long-press path for its context menu.                                                                                       |

## Sources

Primary sources, all read at `eabc04440baa219723bc5d9a51d4e95c1deaf024`:

- Statechart core — [`packages/core/src/types.ts`][core-types],
  [`create-machine.ts`][core-create-machine], [`state.ts`][core-state]; one interpreter,
  [`packages/frameworks/react/src/machine.ts`][react-machine], and the prop-read cost in
  [`vanilla/src/machine.ts`][vanilla-machine].
- Positioning — [`packages/utilities/popper/src/get-placement.ts`][popper-get-placement],
  [`get-anchor.ts`][popper-get-anchor], [`middleware.ts`][popper-middleware],
  [`get-styles.ts`][popper-get-styles], [`placement.ts`][popper-placement],
  [`types.ts`][popper-types].
- Layering and dismissal —
  [`packages/utilities/dismissable/src/layer-stack.ts`][layer-stack],
  [`dismissable-layer.ts`][dismissable-layer],
  [`pointer-event-outside.ts`][pointer-event-outside],
  [`packages/utilities/interact-outside/src/index.ts`][interact-outside].
- Helpers — [`dom-query/src/initial-focus.ts`][initial-focus],
  [`dom-query/src/overflow.ts`][overflow], [`dom-query/src/typeahead.ts`][typeahead],
  [`rect/src/polygon.ts`][polygon], [`focus-visible/src/index.ts`][focus-visible].
- Machines — tooltip ([`machine`][tooltip-machine], [`connect`][tooltip-connect],
  [`store`][tooltip-store], [`types`][tooltip-types]), popover
  ([`machine`][popover-machine], [`connect`][popover-connect]), menu
  ([`machine`][menu-machine], [`connect`][menu-connect], [`dom`][menu-dom],
  [`utils`][menu-utils]), [`hover-card`][hover-card-machine], [`select`][select-machine],
  [`presence`][presence-machine], tour ([`machine`][tour-machine],
  [`types`][tour-types]).
- Composition and integration — [`react/src/portal.tsx`][react-portal],
  [`examples/next-ts/pages/menu/nested.tsx`][menu-nested-example],
  [`CLAUDE.md`][zag-claude-md].

Related pages in this catalog: [`./index.md`](./index.md) (umbrella),
[`./concepts.md`](./concepts.md) (shared vocabulary),
[`./comparison.md`](./comparison.md) (capstone),
[`./features-people-forget.md`](./features-people-forget.md),
[`./sparkles-baseline.md`](./sparkles-baseline.md),
[`./proposal.md`](./proposal.md). Nearest neighbours:
[`./floating-ui.md`](./floating-ui.md) (the positioning engine Zag delegates to),
[`./radix.md`](./radix.md), [`./base-ui.md`](./base-ui.md),
[`./ariakit.md`](./ariakit.md), [`./react-aria.md`](./react-aria.md),
[`./tippy.md`](./tippy.md), [`./aria-apg.md`](./aria-apg.md). Toolkit specs:
[`../../specs/ui/index.md`](../../specs/ui/index.md),
[`../../specs/ui/state-machines.md`](../../specs/ui/state-machines.md),
[`../../specs/ui/input.md`](../../specs/ui/input.md),
[`../../specs/ui/containers.md`](../../specs/ui/containers.md),
[`../../specs/ui/backends.md`](../../specs/ui/backends.md),
[`../../specs/ui/widgets.md`](../../specs/ui/widgets.md).

<!-- References -->

[zag-repo]: https://github.com/chakra-ui/zag
[zag-docs]: https://zagjs.com
[concepts]: ./concepts.md
[zag-claude-md]: https://github.com/chakra-ui/zag/blob/eabc04440baa219723bc5d9a51d4e95c1deaf024/CLAUDE.md#L66
[core-types]: https://github.com/chakra-ui/zag/blob/eabc04440baa219723bc5d9a51d4e95c1deaf024/packages/core/src/types.ts#L78
[core-create-machine]: https://github.com/chakra-ui/zag/blob/eabc04440baa219723bc5d9a51d4e95c1deaf024/packages/core/src/create-machine.ts#L24
[core-state]: https://github.com/chakra-ui/zag/blob/eabc04440baa219723bc5d9a51d4e95c1deaf024/packages/core/src/state.ts#L148
[react-machine]: https://github.com/chakra-ui/zag/blob/eabc04440baa219723bc5d9a51d4e95c1deaf024/packages/frameworks/react/src/machine.ts#L232
[vanilla-machine]: https://github.com/chakra-ui/zag/blob/eabc04440baa219723bc5d9a51d4e95c1deaf024/packages/frameworks/vanilla/src/machine.ts#L96
[react-portal]: https://github.com/chakra-ui/zag/blob/eabc04440baa219723bc5d9a51d4e95c1deaf024/packages/frameworks/react/src/portal.tsx#L13
[popper-get-placement]: https://github.com/chakra-ui/zag/blob/eabc04440baa219723bc5d9a51d4e95c1deaf024/packages/utilities/popper/src/get-placement.ts#L44
[popper-get-anchor]: https://github.com/chakra-ui/zag/blob/eabc04440baa219723bc5d9a51d4e95c1deaf024/packages/utilities/popper/src/get-anchor.ts#L28
[popper-middleware]: https://github.com/chakra-ui/zag/blob/eabc04440baa219723bc5d9a51d4e95c1deaf024/packages/utilities/popper/src/middleware.ts#L28
[popper-get-styles]: https://github.com/chakra-ui/zag/blob/eabc04440baa219723bc5d9a51d4e95c1deaf024/packages/utilities/popper/src/get-styles.ts#L9
[popper-placement]: https://github.com/chakra-ui/zag/blob/eabc04440baa219723bc5d9a51d4e95c1deaf024/packages/utilities/popper/src/placement.ts#L4
[popper-types]: https://github.com/chakra-ui/zag/blob/eabc04440baa219723bc5d9a51d4e95c1deaf024/packages/utilities/popper/src/types.ts#L19
[layer-stack]: https://github.com/chakra-ui/zag/blob/eabc04440baa219723bc5d9a51d4e95c1deaf024/packages/utilities/dismissable/src/layer-stack.ts#L91
[dismissable-layer]: https://github.com/chakra-ui/zag/blob/eabc04440baa219723bc5d9a51d4e95c1deaf024/packages/utilities/dismissable/src/dismissable-layer.ts#L132
[pointer-event-outside]: https://github.com/chakra-ui/zag/blob/eabc04440baa219723bc5d9a51d4e95c1deaf024/packages/utilities/dismissable/src/pointer-event-outside.ts#L8
[interact-outside]: https://github.com/chakra-ui/zag/blob/eabc04440baa219723bc5d9a51d4e95c1deaf024/packages/utilities/interact-outside/src/index.ts#L133
[initial-focus]: https://github.com/chakra-ui/zag/blob/eabc04440baa219723bc5d9a51d4e95c1deaf024/packages/utilities/dom-query/src/initial-focus.ts#L11
[overflow]: https://github.com/chakra-ui/zag/blob/eabc04440baa219723bc5d9a51d4e95c1deaf024/packages/utilities/dom-query/src/overflow.ts#L13
[typeahead]: https://github.com/chakra-ui/zag/blob/eabc04440baa219723bc5d9a51d4e95c1deaf024/packages/utilities/dom-query/src/typeahead.ts#L17
[polygon]: https://github.com/chakra-ui/zag/blob/eabc04440baa219723bc5d9a51d4e95c1deaf024/packages/utilities/rect/src/polygon.ts#L4
[focus-visible]: https://github.com/chakra-ui/zag/blob/eabc04440baa219723bc5d9a51d4e95c1deaf024/packages/utilities/focus-visible/src/index.ts#L156
[tooltip-machine]: https://github.com/chakra-ui/zag/blob/eabc04440baa219723bc5d9a51d4e95c1deaf024/packages/machines/tooltip/src/tooltip.machine.ts#L441
[tooltip-connect]: https://github.com/chakra-ui/zag/blob/eabc04440baa219723bc5d9a51d4e95c1deaf024/packages/machines/tooltip/src/tooltip.connect.ts#L147
[tooltip-store]: https://github.com/chakra-ui/zag/blob/eabc04440baa219723bc5d9a51d4e95c1deaf024/packages/machines/tooltip/src/tooltip.store.ts#L3
[tooltip-types]: https://github.com/chakra-ui/zag/blob/eabc04440baa219723bc5d9a51d4e95c1deaf024/packages/machines/tooltip/src/tooltip.types.ts#L70
[popover-machine]: https://github.com/chakra-ui/zag/blob/eabc04440baa219723bc5d9a51d4e95c1deaf024/packages/machines/popover/src/popover.machine.ts#L107
[popover-connect]: https://github.com/chakra-ui/zag/blob/eabc04440baa219723bc5d9a51d4e95c1deaf024/packages/machines/popover/src/popover.connect.ts#L118
[menu-machine]: https://github.com/chakra-ui/zag/blob/eabc04440baa219723bc5d9a51d4e95c1deaf024/packages/machines/menu/src/menu.machine.ts#L754
[menu-connect]: https://github.com/chakra-ui/zag/blob/eabc04440baa219723bc5d9a51d4e95c1deaf024/packages/machines/menu/src/menu.connect.ts#L159
[menu-dom]: https://github.com/chakra-ui/zag/blob/eabc04440baa219723bc5d9a51d4e95c1deaf024/packages/machines/menu/src/menu.dom.ts#L49
[menu-utils]: https://github.com/chakra-ui/zag/blob/eabc04440baa219723bc5d9a51d4e95c1deaf024/packages/machines/menu/src/menu.utils.ts#L35
[hover-card-machine]: https://github.com/chakra-ui/zag/blob/eabc04440baa219723bc5d9a51d4e95c1deaf024/packages/machines/hover-card/src/hover-card.machine.ts#L13
[select-machine]: https://github.com/chakra-ui/zag/blob/eabc04440baa219723bc5d9a51d4e95c1deaf024/packages/machines/select/src/select.machine.ts#L486
[presence-machine]: https://github.com/chakra-ui/zag/blob/eabc04440baa219723bc5d9a51d4e95c1deaf024/packages/machines/presence/src/presence.machine.ts#L118
[tour-machine]: https://github.com/chakra-ui/zag/blob/eabc04440baa219723bc5d9a51d4e95c1deaf024/packages/machines/tour/src/tour.machine.ts#L532
[tour-types]: https://github.com/chakra-ui/zag/blob/eabc04440baa219723bc5d9a51d4e95c1deaf024/packages/machines/tour/src/tour.types.ts#L22
[menu-nested-example]: https://github.com/chakra-ui/zag/blob/eabc04440baa219723bc5d9a51d4e95c1deaf024/examples/next-ts/pages/menu/nested.tsx#L22
