# Ariakit (TypeScript / React)

A headless React component library whose entire overlay family — disclosure, dialog, popover, hovercard,
tooltip, menu, select, combobox — is one single-inheritance chain of stores and prop-transformer hooks, with
positioning delegated wholesale to Floating UI and hover intent implemented in-house as a 96-line polygon test.

| Field             | Value                                                                                                                                               |
| ----------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language          | TypeScript (React; a framework-free store core)                                                                                                     |
| License           | MIT                                                                                                                                                 |
| Repository        | [`ariakit/ariakit`][repo]                                                                                                                           |
| Documentation     | [ariakit.com][docs] — plus in-repo `readme.md` files per example                                                                                    |
| Category          | Web / headless behavior                                                                                                                             |
| Surface model     | in-canvas: a React portal into a `div` appended to `document.body`. No OS popup, no [top layer][concepts], no `showPopover`, no `HTMLDialogElement` |
| Packages read     | `@ariakit/react` 0.4.37, `@ariakit/react-components` 0.4.1, `@ariakit/components` 0.1.10, `@ariakit/store` 0.1.8                                    |
| **Revision read** | `a0426ed547d95b84c9d53033053e51baeaca4aaa`                                                                                                          |

> [!NOTE]
> This is an implementation reading of the source tree at that SHA, not a docs summary. Where a statement comes
> from a doc comment rather than from executable code it is marked as such. The positioning solver itself is
> **not** in this tree: `@floating-ui/dom` is a pinned dependency (1.8.0) whose source was not read here, so every
> statement below about flip/shift/size/arrow internals is a statement about Ariakit's _use_ of those middlewares.
> The solver is covered in its own deep-dive, [`./floating-ui.md`](./floating-ui.md).

Terms of art used throughout — [anchor rect, placement, gravity, constraint adjustment, flip/shift/slide/resize,
clipping boundary, top layer, light dismiss, grab, safe polygon, warm-up, cool-down, focus scope, modality,
virtual anchor, transform origin](./concepts.md) — are defined in the shared vocabulary page.

## Overview

### What it solves

Ariakit's overlay stack is not a set of siblings that happen to share utilities; it is one inheritance chain.
`createDisclosureStore` → `createDialogStore` → `createPopoverStore` → `createHovercardStore` →
`createTooltipStore`, with `createMenuStore` mixing hovercard with composite, and select / combobox /
composite-overflow mixing popover with composite. `createDialogStore` is a literal alias — it forwards to
`createDisclosureStore` and adds nothing ([`dialog-store.ts:12`][dialog-store]).

The consequences are structural, not cosmetic. A `Menu` submenu gets hover intent because `useMenu` calls
`useHovercard` ([`menu.tsx:190`][menu-hovercard]). A `Hovercard` gets outside-dismissal, focus restoration and
modality because `useHovercard` calls `usePopover` which calls `useDialog`. A `Tooltip` is roughly forty lines of
overrides on `Hovercard` ([`tooltip.tsx:69`][tooltip-overrides]). Divergence between surface kinds is expressed
almost entirely as changed defaults plus one or two narrowed predicates, which makes the differences between a
tooltip, a hovercard, a popover and a menu unusually legible.

### Design philosophy

Two layers. `@ariakit/store` is a framework-free, key-granular observable object: `getState()` /
`setState(key, value)`, three subscription timings, parent/child composition with a bounded repair loop.
`@ariakit/react-components` holds every DOM behavior in `createHook` prop transformers that compose bottom-up.
The store layer nonetheless holds `HTMLElement` references in state — which is what makes anchor / disclosure /
content relationships declarative across components, and simultaneously what stops the anchor from ever being a
plain comparable value.

The most transferable idea in the subject is that "not yet positioned" is _state_, not an implementation detail.
`PopoverStoreState.unstable_placing` is documented at [`popover-store.ts:147-159`][popover-store-placing]:

> Whether the popover is showing and hasn't settled at the position its current positioning pass will leave it
> at. Every pass a commit starts asserts it, not just the one that follows the popover being shown […]
> Components that move focus or scroll into the popup wait for this to become `false`, otherwise they act on an
> element that's still at its pre-placement origin, or at a position it's about to leave, and drag the page along
> with it.

The second philosophy statement is about hover intent. The whole geometry is one integer-safe cross product per
polygon edge — no trigonometry, no velocity, no trajectory extrapolation ([`polygon.ts:23`][polygon-where]):

```text
const where = (yi - yj) * (x - xi) - (xi - xj) * (y - yi);
```

And the third is about what the transit corridor is _for_. It does not merely defer hiding
([`hovercard.tsx:82-83`][hovercard-transit-comment]):

> These events can trigger focus on other elements and close the hovercard while the mouse is still moving toward
> it.

## How it works

Three packages carry the overlay stack, and the split is enforced:

```text
@ariakit/store            framework-free observable object; no DOM types
@ariakit/components       typed store factories; state holds HTMLElement refs
@ariakit/react-components createHook prop transformers; every DOM behavior
```

The hook chain mirrors the store chain and composes bottom-up, each level wrapping the previous level's props:

```text
useTooltip -> useHovercard -> usePopover -> useDialog -> useDisclosureContent
                                                      -> useFocusable
                                                      -> usePortal
```

One popover renders **two** elements. The outer wrapper is the positioner (`position: absolute|fixed`,
`top/left: 0`, `width: max-content`) and carries the `transform`; the inner content element is what the author
styles and animates. That split is semi-public: `wrapperProps` is documented API, so authors can animate the
content without fighting the positioner.

A positioning pass, as written in [`popover.tsx:333`][popover-position-effect] and the surrounding helpers:

```text
assert unstable_placing = true (only while mounted)
build virtual anchor  { contextElement, getBoundingClientRect }
autoUpdate(anchor, popoverElement, update, { elementResize })
  update() = custom updatePosition ?? default
  default:
    pos = await computePosition(anchor, wrapper, { placement, strategy, middleware })
    if (canceled || !popoverElement.isConnected) return          // write nothing
    setState("currentPlacement", pos.placement)
    wrapper.style.transform = translate3d(roundByDPR(x)px, roundByDPR(y)px, 0)
    position the arrow; write --popover-transform-origin
finally setState("unstable_placing", false)
```

`roundByDPR` ([`popover.tsx:112`][popover-round-dpr]) snaps `x` and `y` to the device-pixel grid —
`Math.round(value * devicePixelRatio) / devicePixelRatio` — which is the closest thing in this subject to
integer-cell placement.

## The analysis spine

### 1. Anchor model

The store holds three distinct element slots and keeps them distinct on purpose: `anchorElement` (what the
overlay is positioned against), `disclosureElement` (what opened it, and where focus returns), `popoverElement`
(the positioned wrapper) ([`popover-store.ts:58`][popover-store-initial]).

**Algorithm.** An anchor is the pair `(HTMLElement | null, getAnchorRect?)` lifted into a Floating UI
[virtual anchor][concepts] — `{ contextElement, getBoundingClientRect }` ([`popover.tsx:88`][popover-get-anchor]).
The two slots are reconciled by a mirroring rule rather than by identity, driven by a `sync` over both keys
([`popover-store.ts:74-83`][popover-store-sync]) against a private `syncedAnchorElement`
([`popover-store.ts:69`][popover-store-synced]):

```text
on change of { anchorElement, disclosureElement }:
    if anchorElement && anchorElement !== syncedAnchorElement:
        syncedAnchorElement = null          # stop mirroring, explicit anchor wins
    else:
        syncedAnchorElement = disclosureElement
        anchorElement := disclosureElement
```

Six edge cases of that rule are pinned in [`popover-store.test.ts`][popover-store-test], including "preserves an
explicit anchor matching a previous fallback" and re-initialisation reseeding the fallback — a ready-made
conformance suite for anyone porting the rule.

Many-triggers-one-popup is handled separately, in the shared trigger's ref callback: it refuses to reassign
`anchorElement` while the current one is still `isConnected`, so adding a second anchor to the DOM does not steal
the anchor ([`__hovercard-trigger.tsx:107-118`][hovercard-trigger-ref], with the guard on `:112`). Detached
trigger-versus-anchor is first class — `MenuAnchor` / `SelectAnchor` / `ComboboxAnchor` exist as separate
components, and `Menu` positions against `anchorElement` while restoring focus to `disclosureElement ||
anchorElement`.

Point, cursor and text-range anchors all go through one caller-supplied `getAnchorRect` returning
`{x, y, width, height}`: the context-menu example returns the `contextmenu` event's `clientX/clientY`
([`examples/menu-context-menu`][ex-context-menu]), the selection example returns
`range.getBoundingClientRect()` ([`examples/popover-selection`][ex-selection]). **Multi-rect text ranges are not
supported** — a wrapped range collapses to a single bounding rect. Moving anchors are handled by Floating UI's
`autoUpdate` plus an explicit `store.render()` escape hatch that flips a `rendered: symbol` state to force a
fresh pass ([`popover-store.ts:91`][popover-store-render]).

There is no anchor-to-screen conversion: everything is viewport coordinates in one document, and cross-document
anchoring is refused outright — a target in another document is unconditionally _outside_
([`use-hide-on-interact-outside.ts:126`][uhoio-doc]).

**Where it lives.** Identity in the store layer (`@ariakit/components`); rect production in the React layer;
consumption in `@floating-ui/dom`.

**Degradation.** No OS window changes nothing — there is none. With no script the anchor cannot be measured at
all. With no sub-cell precision the rect becomes integral, which `roundByDPR` half-anticipates already. No key
release is irrelevant here. The fragile part is the anchor/disclosure mirror, which is driven by mount-order
effects: with no hover, the hovercard trigger's `setAnchorElement` path never runs and the anchor must be set
programmatically.

> [!IMPORTANT]
> The anchor here cannot be compared, cached or serialised — it is an element identity plus a
> `getBoundingClientRect` closure, deliberately late-bound so re-measurement is always fresh. The _reconciliation
> rule_, however, is value-shaped and would port unchanged over an opaque comparable id. That contrast is the
> single most useful thing this dimension offers a toolkit whose widgets already have ids
> (see [`./sparkles-baseline.md`](./sparkles-baseline.md)).

### 2. Placement model

Ariakit's own [placement][concepts] vocabulary is deliberately small: twelve physical placements
(`top|bottom|left|right`, each with optional `-start`/`-end`), declared as a TypeScript union at
[`popover-store.ts:19-24`][popover-store-placement] and re-validated at runtime by a regex,
`isValidPlacement` ([`popover.tsx:107`][popover-valid-placement]).

There is no logical (block/inline) placement, no writing-mode awareness and no RTL handling **in Ariakit
itself**; whatever `-start`/`-end` mean under `dir=rtl` is Floating UI's answer. (`composite-store` does carry an
`rtl` state, but it governs arrow-key direction inversion, not placement.)

Per-component defaults are the real behavioural signal: popover `bottom`, hovercard `bottom`
([`hovercard-store.ts:25`][hovercard-store-placement]), tooltip `top`
([`tooltip-store.ts:34`][tooltip-store-placement]), menu `bottom-start`, submenu derived from the parent's
orientation by a store-level `sync` — vertical parent → `right-start`, horizontal → `bottom-start`
([`menu-store.ts:110-117`][menu-store-orientation]).

**Algorithm.** The middleware array is assembled per render:

```text
offset(({placement}) => {
    arrowOffset = arrowElement.clientHeight / 2
    mainAxis    = typeof gutter === "number" ? gutter + arrowOffset : gutter ?? arrowOffset
    hasAlignment = !!placement.split("-")[1]
    return { crossAxis: hasAlignment ? undefined : shift, mainAxis, alignmentAxis: shift }
})
flip({ padding: overflowPadding, fallbackPlacements: flip.split(" ") })
shift({ mainAxis: slide, crossAxis: overlap, padding, limiter: limitShift() })
arrow({ element, padding: arrowPadding = 4 })
size({ padding, apply: write CSS vars + optional sameWidth / fitViewport })
```

Note the `crossAxis`/`alignmentAxis` duality at [`popover.tsx:122-144`][popover-offset-mw]: the same `shift`
number is applied as a cross-axis offset for a centred placement and as an alignment-axis offset for an aligned
one. `slide` (main-axis shift) defaults true, `overlap` (cross-axis shift, letting the popup cover its anchor)
defaults false, and **if both are false the shift middleware is omitted entirely**
([`popover.tsx:165`][popover-shift-mw]).

Fallback ordering is exposed as a _space-delimited string_ — `flip="top bottom"` — rather than an array, with a
development-time validity check on each entry. `overflowPadding` accepts a number or a per-side object; the
object goes straight to Floating UI, but the exported CSS variable `--popover-overflow-padding` collapses it to
`max(left, right)` with omitted sides treated as 0 ([`popover.tsx:117-120`][popover-overflow-padding]).

Viewport insets, safe areas, work areas and multi-monitor geometry are absent: the [clipping boundary][concepts]
is whatever Floating UI's default clipping-ancestor detection finds. Virtual-keyboard avoidance exists only for
`Dialog`, and only as _data_: an effect writes `--dialog-viewport-height` from `window.visualViewport.height` and
rewrites it on `visualViewport` resize, leaving the actual avoidance to author CSS
([`dialog.tsx:343`][dialog-viewport-height]).

**Degradation.** No script means no placement at all — the wrapper stays at `translate3d(0,0,0)` at its offset
parent's top-left. On a cell grid the offset arithmetic is integer-friendly except `arrowElement.clientHeight / 2`,
which needs an odd/even rule. The soft-keyboard case is the notable inversion: Ariakit _discovers_ the inset from
`visualViewport` rather than accepting it as a placement input.

### 3. Collision & geometry engine

Ariakit owns none of the collision math and all of the lifecycle around it. Overflow detection,
clipping-ancestor discovery, scroll containers and transform/zoom handling belong to `@floating-ui/dom`. What
Ariakit contributes is five things.

1. **`autoUpdate` with a guarded `elementResize`** — `typeof ResizeObserver === "function"` gates the option, so
   JSDOM / happy-dom degrade to scroll + resize listeners only ([`popover.tsx:503`][popover-autoupdate]).
2. **DPR snapping** — `roundByDPR` before writing `translate3d` ([`popover.tsx:112`][popover-round-dpr]).
3. **A cancellation protocol.** `computePosition` is async and `autoUpdate`'s cleanup does _not_ abort an
   in-flight call, so each effect run owns a `canceled` flag; `shouldCancelUpdate()` additionally re-checks
   `popoverElement.isConnected` ([`popover.tsx:378`][popover-should-cancel]), and `shouldCancel` is injected into
   the `size` middleware's `apply()` so a stale run cannot mutate `width`/`maxWidth`
   ([`popover.tsx:181-198`][popover-size-mw]).
4. **An explicit skip** when the popover is unmounted-while-hidden and no custom `updatePosition` is supplied, so
   a closed-but-connected popover keeps no observers alive.
5. **Geometry exported as data** — the `size` middleware writes `--popover-anchor-width` (`Math.round`) and
   `--popover-available-width` / `--popover-available-height` (`Math.floor`) as CSS custom properties. Measured
   geometry is deliberately handed to the styling layer _as integers_.

**Algorithm.** The pass is the pseudo-code in [How it works](#how-it-works). Its subtlety is the writer
accounting: a separate layout effect keeps a per-store `WeakMap<Store, number>` count of how many mounted
popovers assert the placing bit, and defers the final reset by a `queueMicrotask`, so StrictMode replay, keyed
remounts and store swaps can neither strand the bit nor clear it early
([`popover.tsx:46`][popover-placing-writers], [`popover.tsx:568`][popover-placing-effect]).

**Where it lives.** Solver and observers in `@floating-ui/dom`; lifecycle, cancellation, DPR snapping and CSS
variable export in `popover.tsx`. Nothing in the framework-free store layer.

**Degradation.** The portable parts are the cancellation protocol (an in-flight async pass must be invalidated by
identity, not by cleanup), the placed/unplaced bit, and publishing resolved geometry as data. The non-portable
parts are clipping-ancestor discovery, transform/zoom compensation and `ResizeObserver`. In a single-surface
integer-cell toolkit with synchronous layout, collision reduces to a pure function of
`(anchorRect, popupSize, surfaceRect, padding)` and the whole observer/rAF apparatus disappears. With no script
there is no measurement, so no collision detection at emit time.

### 4. Arrow / caret geometry

Arrow geometry is data in exactly two places and CSS everywhere else. The store holds `arrowElement`; the
positioning pass reads `middlewareData.arrow.{x,y}` and writes three things
([`popover.tsx:444-473`][popover-arrow-handling]):

- `arrow.style.left` / `arrow.style.top` — the offset along the popup's edge;
- `arrow.style[side] = "100%"` — detachment to the outside of the popup, with `right` and `bottom` explicitly
  cleared first, because a stale RTL `right` would override the new `left` and visibly detach the arrow;
- `--popover-transform-origin` on the popover element — the arrow's centre projected onto the popup box.

**Algorithm.** [Transform origin][concepts] is a per-side lookup over the resolved side:

```text
side    = currentPlacement.split("-")[0]
centerX = arrow.clientWidth  / 2
centerY = arrow.clientHeight / 2
originX = arrowX == null ? -centerX : arrowX + centerX      # likewise originY
top:    `${originX}px calc(100% + ${centerY}px)`
bottom: `${originX}px ${-centerY}px`
left:   `calc(100% + ${centerX}px) ${originY}px`
right:  `${-centerX}px ${originY}px`
```

The arrow's size feeds the [gutter][concepts]: `getOffsetMiddleware` adds `arrowElement.clientHeight / 2` to it
— and does so **even when the author rendered no arrow**, because `usePopover` lazily creates a detached `div`
purely so the arrow middleware and the gutter arithmetic always have something to measure
([`popover.tsx:388`][popover-default-arrow]). Corner constraint is `arrowPadding` (default 4), passed to Floating
UI's `arrow` middleware. **Arrow hiding is not implemented** — there is no `hide({strategy: 'referenceHidden'})`
middleware anywhere in the tree, and nothing reacts to the anchor being scrolled out of view.

Border-aware arrows are unusually elaborate and live entirely in a _component_, `PopoverArrow`: it reads
`getComputedStyle` of the content element and infers stroke width and colour either from a Tailwind-style ring
(the first `box-shadow` segment with zero offsets and positive spread, located by masking parenthesised colour
functions so the commas inside `rgb(59, 130, 246)` do not split segments,
[`popover-arrow.tsx:56`][popover-arrow-mask]) or from `border-<side>-width` / `border-<side>-color`; the stroke
is then scaled as `borderWidth * 2 * (30 / size)` against a fixed 30-unit SVG `viewBox`, and a four-path SVG with
a mask emulates a border that joins the popup's own.

**Where it lives.** Offset and clamping in Floating UI's `arrow` middleware; the projection to transform origin
and the style writes in `popover.tsx`; all visuals in `popover-arrow.tsx`.

**Degradation.** In whole cells an arrow is one character: the geometry collapses from `(x, y, centre, origin)`
to a single integer offset along the popup's edge plus a side, and the natural rendering is a box-drawing joint
glyph replacing one border cell. Ariakit's own split is directly reusable — side plus integer offset is the data;
everything in `popover-arrow.tsx` is presentation. The ring/border colour inference has no analogue without
sub-cell edges. Static HTML keeps the arrow (it is pure CSS) but cannot compute its offset, so only a centred
arrow is honest there.

### 5. Trigger semantics

Triggers are separate composable hooks, and the composition order is itself the race-avoidance mechanism.
`useHovercardTrigger` (the shared internal, filename-prefixed `__` to mark it private) implements hover-open;
`usePopoverDisclosure` / `useDialogDisclosure` implement click-toggle; `useMenuButton` composes both plus
composite typeahead.

Ariakit does not listen to `mouseenter` for opening. It listens to `onMouseMove` and gates on a **global**
`isMouseMoving()` predicate ([`__hovercard-trigger.tsx:57-63`][hovercard-trigger-move]), so a `mouseover`
synthesised by scrolling, by a tap, or by the page moving under a stationary cursor cannot open a hovercard.
That predicate is one module-global boolean, set by a capture-phase `document` `mousemove` listener that requires
non-zero `movementX`/`movementY`, and reset by `mousedown`, `mouseup`, `keydown` and `scroll`
([`hooks.ts:399-442`][hooks-mouse-moving]). It is re-validated: `showHovercard()` calls `isMouseMoving()` a
_second_ time before `store.show()` ([`__hovercard-trigger.tsx:74`][hovercard-trigger-second-check]), so a
pointer that stopped moving during the delay still opens while a tap that produced one synthetic move does not.
Pointer-type distinction is therefore implicit — movement-based — rather than read from
`PointerEvent.pointerType`.

A zero delay is a distinct code path, not `setTimeout(0)` ([`__hovercard-trigger.tsx:88-93`][hovercard-trigger-zero]):

```text
const timeoutMs = showTimeout ?? timeout;
if (timeoutMs === 0) { showHovercard(); } else { setTimeout(showHovercard, timeoutMs); }
```

Menubar submenus set `timeout: 0` ([`menu-store.ts:81-85`][menu-store-timeout]) and rely on that synchronous
branch so the pointer cannot outrun the popup.

**Algorithm.** Multiple triggers are combined by prop-chain composition plus per-trigger latches, never by a
priority table. Each hook wraps the previous handler (`onMouseMoveProp?.(event); if (event.defaultPrevented)
return; …`) and owns one ref — `showTimeoutRef` on the hovercard trigger, `canShowOnHoverRef` on the tooltip
anchor. Cross-trigger races are broken by three latches:

1. a non-zero `showTimeoutRef.current` makes `onMouseMove` idempotent;
2. a **native** capture-phase `mouseleave` listener clears it, deliberately bypassing React's `onMouseLeave`
   because the open hovercard stops propagation of mouse events during transit
   ([`__hovercard-trigger.tsx:38-51`][hovercard-trigger-native-leave]);
3. `onClick` clears the pending show timeout, so click-then-hover cannot resurrect it.

Long-press and touch-triggered tooltips are absent. The context menu is not a trigger primitive at all — the
documented pattern is the application's own `onContextMenu` plus `getAnchorRect` plus `menu.show()`. Keyboard:
`MenuButton` maps Arrow keys to open-with-initial-focus based on the _resolved_ base placement, so a menu that
flipped to `top` opens on ArrowUp with `"last"`. `TooltipAnchor` opens on `onFocusVisible`, not `onFocus`
([`tooltip-anchor.tsx:127`][tooltip-anchor-focus-visible]), so mouse-focus shows no tooltip.

**Degradation.** With no hover, every hover path is dead and `Hovercard` becomes unopenable unless
`HovercardDisclosure` is rendered. No key release is irrelevant — every trigger here is keydown, click or focus.
With no script, only `:hover` / `:focus-within` can trigger anything, which means a static tier-0 emitter cannot
reproduce the `isMouseMoving` guarantee at all. Multiple simultaneous pointers are not modelled; one pointer is
assumed throughout.

### 6. Timing

Three numbers live in the store and nothing else does: `timeout` (base), `showTimeout`, `hideTimeout`, resolved
at use time as `showTimeout ?? timeout` and `hideTimeout ?? timeout` — read lazily from `getState()`, not
captured at subscription. The defaults encode the component taxonomy precisely:

| Surface        | `timeout` | `hideTimeout` | Other                          |
| -------------- | --------- | ------------- | ------------------------------ |
| Hovercard      | 500       | inherits      | —                              |
| Tooltip        | inherits  | **0**         | `skipTimeout` 300              |
| Menu (submenu) | 150       | 0             | 0 when the parent is a menubar |

A tooltip disappears instantly ([`tooltip-store.ts:36`][tooltip-store-hide-timeout]); a hovercard waits 500 ms to
appear ([`hovercard-store.ts:29`][hovercard-store-timeout]); moving along a menubar swaps menus with no delay
([`menu-store.ts:81-85`][menu-store-timeout]).

**Algorithm.** The machine as implemented, in states:

```text
Closed  --qualified move on trigger-->                    Opening(showTimeout)
Opening --native mouseleave | click-->                    Closed
Opening --timer fires && isMouseMoving()-->               Open
Open    --move outside {card, anchor, disclosure, nested} Closing(hideTimeout)
           && not in transit polygon && hideOnHoverOutside
Closing --any qualifying move back inside-->              Open
Closing --timer fires-->                                  Closed
```

Overlaid on that, for tooltips only, a page-global singleton implements [warm-up and cool-down][concepts]:
`skipTimeout` (default 300, [`tooltip-store.ts:42`][tooltip-store-skip]) is the window during which any _other_
tooltip opens instantly. The singleton is a module-level `createStore<{activeStore: TooltipStore | null}>`
([`tooltip-anchor.tsx:23-27`][tooltip-anchor-global]) — its own comment says it exists "so we can show other
tooltips without a delay when there's already an active tooltip". On mount, if a different store is active, hide
it and become active; on close, schedule removal after `skipTimeout` and cancel if it re-opens
([`tooltip-anchor.tsx:83-116`][tooltip-anchor-sync]).

Two re-entrancy guards make that safe. A `hidingStores` `WeakSet` marks a store between `hide()` and a
`queueMicrotask` cleanup, so a controlled `open` prop that forces it back open cannot start a hide/show loop
([`tooltip-anchor.tsx:39-46`][tooltip-anchor-hiding]); and `onBlur` clears `activeStore`, so clicking a menu
button does not leave the next tooltip in instant mode. There is no max display duration.

**Degradation.** With no timers (static HTML) the entire dimension vanishes: `:hover` gives an instantaneous,
uncancellable open and close, which is precisely the accidental-tooltip problem the delays exist to solve. With
no hover, show/hide delays are meaningless; only the skip-window grouping would survive if triggers became taps.
Everything here is integer milliseconds over a monotonic clock, so it ports verbatim to a target that can advance
a virtual clock — which is how these behaviours become assertable without a tty.

### 7. Interactive hover

This is Ariakit's most distinctive code, and it is an independent implementation rather than a fork of Floating
UI's [safe polygon][concepts]. Four differences are worth naming.

**(a) The polygon is built from the hovercard's own rect plus one enter point.** The anchor rect is _not_ part of
it, and there is no blocking rectangle and no buffer parameter. `getElementPolygon`
([`polygon.ts:70-96`][polygon-get-element]) classifies the enter point against the rect as
`(x ∈ {left, right, null}, y ∈ {top, bottom, null})` via `getEnterPointPlacement`
([`polygon.ts:62`][polygon-enter-placement]) and emits a fan of four to six vertices:

```text
if x is set:  [enterPoint,
               (near-side top corner   unless y === "top"),
               (far-side  top corner),
               (far-side  bottom corner),
               (near-side bottom corner unless y === "bottom")]
elif y === "top":  [enterPoint, TL, BL, BR, TR]
else:              [enterPoint, BL, TL, TR, BR]
```

**(b) The enter point is refreshed as the pointer advances.** `refreshEnterPoint: true` on the mousemove path
([`hovercard.tsx:251-257`][hovercard-refresh-enter]) rewrites `enterPointRef` to the current point on every
successful in-corridor move, so the corridor narrows monotonically toward the card and a pointer that stalls then
reverses falls out immediately.

**(c) Inside the polygon, mouse events are suppressed globally.** `disablePointerEventsOnApproach` (defaulting to
`!!hideOnHoverOutside`) installs capture-phase handlers for `mouseenter`, `mouseover`, `mouseout` and
`mouseleave` that call `preventDefault()` and `stopPropagation()` while the pointer is in transit
([`hovercard.tsx:286-307`][hovercard-suppress]) — because those events would otherwise focus intervening
elements and close the card. This is a substitute for a pointer [grab][concepts] that the library does not have.

**(d) The point-in-polygon test carries an explicit third-vertex lookback.** `isPointInPolygon`
([`polygon.ts:9-60`][polygon-in-polygon]) is a crossing-count ray cast; when the ray's ordinate equals the shared
vertex ordinate it consults `polygon[j === 0 ? l - 1 : j - 1]` (`vy`) and toggles only if `y > vy`, so a
horizontal ray grazing a local extremum does not flip the result. Its test states the reason directly
([`polygon.test.ts:70-71`][polygon-test-apex]):

> The apex `[3, 0]` is a local extremum, so the horizontal ray grazing it must not be counted as a crossing.
> Without the vy guard this point would toggle.

There are also explicit on-edge and on-horizontal-edge early returns (a point on the boundary counts as inside)
and a null-vertex guard returning `false` for a malformed polygon.

**Nested surfaces.** Each `Hovercard` registers itself on the nearest ancestor `Hovercard` through
`NestedHovercardContext`, in a **layout** effect specifically so no mousemove is lost between mount and
registration ([`hovercard.tsx:335-351`][hovercard-nested-register] — the comment names the failing case: "a
submenu that's overlapping its menu button and we keep moving the mouse while the submenu is due to open").
Registration also clears the parent's pending hide timer and recurses, so a grandparent sees the grandchild
([`hovercard.tsx:353-367`][hovercard-register-nested]). Non-portal children need no registration because
`composedPath()` already contains them.

There is no menu-aim heuristic beyond this, and no velocity or trajectory extrapolation anywhere. Submenus get
exactly this algorithm because `Menu` calls `useHovercard`.

**Cost.** O(V) per pointer move with V = 5 or 6 — five or six integer multiply-subtract pairs, no allocation. The
nested check is an O(N) `path.includes` scan over the composed path per open card; in a toolkit with an owned
overlay tree it would be an O(depth) walk instead.

**Degradation.** In whole cells the geometry is exact and cheaper: all coordinates are integers and there is no
DPR to worry about, and the vertex-grazing guard becomes _more_ important rather than less, because on a lattice
a horizontal ray hits a vertex ordinate constantly. What does not survive is (c): without an event-dispatch
capture phase there is no way to swallow events destined for other widgets. The structure suggests a substitute
that is strictly cleaner in a toolkit that derives its own hit list — while a corridor is live, veto hover
targets that are not the card, the anchor, or a registered descendant — but that is an inference about the port,
not a mechanism Ariakit implements. With no hover (or no script) the whole dimension is dead. Everything here is
a pure function of `(enterPoint, cardRect, currentPoint)`, so it is fully assertable on a recording target.

### 8. Dismissal

Dismissal is centralised in `useDialog` and `useHideOnInteractOutside`, and every overlay inherits it.

**Escape.** Three listeners cooperate — a React `onKeyDown`, a React `onKeyDownCapture`, and a document-level
capture + bubble pair — coordinated by a per-component
`WeakMap<KeyboardEvent, {accepted, defaultPrevented}>` so the `hideOnEscape` predicate runs at most once per
physical keypress and the decision is memoised ([`dialog.tsx:663-669`][dialog-escape-map]). The memo is
invalidated if `defaultPrevented` flipped after it was taken. Topmost-wins is decided by reading DOM marks left
by _other_ dialogs ([`dialog.tsx:696-698`][dialog-escape-marked]):

> Ignore the event if the current dialog is marked by another dialog. This guarantees that only the topmost
> dialog will close on Escape.

The document capture handler additionally accepts Escape when the target is `BODY`, inside the dialog, inside the
disclosure, or marked outside by this dialog, so Escape works with focus anywhere.

**Outside interaction.** Three event types, all capture-phase, installed through `addGlobalEventListener` (which
recurses into same-origin child frames): `click`, `focusin`, `contextmenu`
([`use-hide-on-interact-outside.ts:215`][uhoio-click], [`:255`][uhoio-focusin], [`:275`][uhoio-contextmenu]).
Notably **not** `pointerdown`/`mousedown` — a mousedown ref is captured separately
([`use-previous-mouse-down-ref.ts:62`][prev-mousedown]) and used to classify the _click_, so dragging a text
selection from inside the overlay and releasing outside does not dismiss it, and an overlay opened on mousedown
ignores the trailing click. Four further guards:

- `isMouseEventOnDialog` does a bounding-box hit test, so clicking a transparent gap that is geometrically over
  the dialog counts as inside ([`use-hide-on-interact-outside.ts:58`][uhoio-mouse-on-dialog]);
- a target in a different document is unconditionally outside ([`:126`][uhoio-doc]);
- a target that is not `isConnected` is ignored (unmount-then-focus);
- the marked-tree check applies only once the dialog has been focused at least once (a `focusedRef` fed by a
  `focusin` listener), so hovercards are not closed when unrelated nodes are added and focused.

**Scroll does not dismiss** — and structurally cannot, because the global mouse-moving flag is reset by `scroll`,
which makes the hovercard's mousemove path inert during a wheel; a browser test pins "does not hide an open
hovercard on wheel" ([`sandbox/hovercard-interactions`][sandbox-hovercard]). Anchor removal or hiding is not
watched at all. Parent closing cascades via `hideAll()` on menus ([`menu.tsx:197`][menu-hide-all]); a child
opening does not close its parent. `Tooltip` narrows both predicates: it refuses to hide on hover-outside while
the anchor has `data-focus-visible`, and refuses to hide on interact-outside when the interaction is within the
anchor ([`tooltip.tsx:75`][tooltip-narrowing]).

**Algorithm.** `acceptEscape(e)` ([`dialog.tsx:684-705`][dialog-accept-escape]):

```text
if key !== "Escape" or !e.bubbles            -> false
if memoised                                  -> replay memo unless defaultPrevented flipped
if e.defaultPrevented                        -> false
if !mounted or !dialog                       -> false
if isElementMarked(dialog)                   -> false   # a deeper dialog owns it
accepted = hideOnEscape(e); memoise; return accepted
```

**Degradation.** No key release is irrelevant — everything is keydown. No script leaves only `<details>`-style
toggling and no outside-dismiss at all. No OS window is the status quo; window/application deactivation is
deliberately ignored (a changelog entry for 0.4.36 states that true browser or application window blur remains
ignored). The Android back key is not modelled anywhere; it would map onto the same accept/hide predicate as
Escape, which suggests treating it as a dismissal _reason_ rather than a keycode. The mousedown-to-click pairing
and the bounding-box hit guard both survive verbatim on a cell grid, and are the two things a naive
"click outside closes" implementation gets wrong.

### 9. Focus

The four surfaces are kept distinct by defaults chosen at each layer, not by a mode enum:

| Surface   | `modal` | `autoFocusOnShow`                                        | Notes                                                      |
| --------- | ------- | -------------------------------------------------------- | ---------------------------------------------------------- |
| Dialog    | `true`  | `true`                                                   | `portal`, `backdrop`, `preventBodyScroll` all follow modal |
| Popover   | `false` | `true` **ANDed with `positioned`** (`!unstable_placing`) | `preserveTabOrder: true`                                   |
| Hovercard | `false` | `false` in the store; forced true only when modal        | adds `useAutoFocusOnHide`; pins `finalFocus` to the anchor |
| Tooltip   | `false` | never focuses                                            | `preserveTabOrder: false`                                  |
| Menu      | `false` | only with a resolved `initialFocus` or when modal        | `finalFocus` prefers `disclosureElement`                   |

The popover's AND with `positioned` ([`popover.tsx:644`][popover-autofocus-gate]) is the placed-bit paying off:
focus is never moved into an element that is still at its pre-placement origin. `Menu`'s narrowing
([`menu.tsx:148`][menu-can-autofocus]) exists because a hover-opened submenu must not steal focus.

**Algorithm.** Initial focus resolution in `useDialog` ([`dialog.tsx:496`][dialog-initial-focus]) is an ordered
ladder: `initialFocus` prop if focusable → `[data-autofocus=true],[autofocus]` → the first tabbable (with a
portal- and `preserveTabOrder`-aware variant) → the dialog element itself. The actual `.focus()` is deferred to a
`queueMicrotask` that re-checks `open`, scrolls with `block/inline: "nearest"`, then focuses with
`preventScroll` ([`dialog.tsx:515`][dialog-focus-microtask]). A late-arriving microtask must not steal focus back
if focus escaped meanwhile — that is what `focusedStoreRef` plus a shadow-root-descending
`getDeepestActiveElement` decide.

Restoration is a second resolver ([`dialog.tsx:582`][dialog-focus-on-hide]):

```text
focusOnHide(dialog, retry = true):
    if interactedOutside                                  -> return
    if an outside focusable already has focus             -> return
    el = finalFocus ?? disclosureElement
    if some node has aria-activedescendant === el.id      -> el = that composite
    if !focusable(el) and el.closest("[data-dialog]").id  -> el = [aria-controls~=id]
    if !focusable(el) and retry -> rAF(() => focusOnHide(dialog, false))
    if !autoFocusOnHide(el) -> return
    el.focus()
```

The retry-on-next-frame exists because a nested dialog may still be removing `inert`.

> [!WARNING]
> There is **no focus trap** in the modal path. Containment is achieved by inerting everything outside (see
> dimension 11). `FocusTrapRegion` exists in the tree and is used by nothing
> ([`focus-trap-region.tsx:27`][focus-trap-region]) — dead code that a reader can easily mistake for the
> mechanism.

**Degradation.** No key release is irrelevant to Ariakit's focus paths — every one of them is keydown, click or
focus-driven (a statement about this subject only). No OS window is unaffected: focus here is a document concept,
which is what a single-surface toolkit has anyway. With no script, [focus scope][concepts] is impossible;
`:focus-within` is the only tier-0 handle, so a static emitter can express "popup visible while the trigger group
has focus" but never "focus moved into the popup". The portable content is the restoration _ladder_ and the rule
that a hover-opened surface must not take focus while a click-opened one must — both pure decisions over a small
state record. The rAF retry is an artefact of `inert` removal ordering and should not be ported.

### 10. Layering & portals

Ariakit has no top layer and does not use the native popover or dialog APIs — grepping for `showPopover`,
`showModal` or `HTMLDialogElement` in this tree finds only doc-comment links. Layering is:

```text
portalElement prop (element | factory) ?? document.createElement("div")
  -> appended to PortalContext ?? document.fullscreenElement ?? document.body
  -> id = `portal/${element.id}` or a random id
  -> published via portalRef and PortalContext so descendants nest
```

`getRootElement` prefers `document.fullscreenElement` when one exists
([`portal.tsx:33`][portal-root]), and a `fullscreenchange` listener re-parents the node
([`portal.tsx:186`][portal-fullscreen]). Ordering is DOM order plus author `z-index`; the library's only
contribution is to _mirror_ z-index twice — the positioning wrapper copies
`getComputedStyle(contentElement).zIndex` and re-copies it across two animation frames in case it changes after
mount ([`popover.tsx:543`][popover-zindex]), and `DialogBackdrop` copies it in a layout effect.

The overlay _tree_ is real but is three separate registries, none of them a single structure:

| Registry                     | Kind                  | Used for                            |
| ---------------------------- | --------------------- | ----------------------------------- |
| `NestedDialogsContext`       | React context (array) | exempting descendants from inerting |
| `NestedHovercardContext`     | register callback     | hover-intent membership             |
| `MenuStore.parent/.menubar/` | store-to-store refs   | `hideAll` and placement inheritance |

Public API versus implementation detail is explicitly annotated: `portal`, `portalElement`, `portalRef`,
`preserveTabOrder`, `preserveTabOrderAnchor`, `getPersistentElements`, `wrapperProps`, `updatePosition` and
`getAnchorRect` are public; `data-placing`, `unstable_placing`, `unstable_treeSnapshotKey`,
`__hovercard-trigger.tsx`, the `__ariakit-dialog-*` element properties and the `insideElements` `WeakMap` are
not.

**Modal cohort ordering** is the one genuinely surprising piece: when several default-modal portals open in the
same layout pass, `getLaterOpenModalPortals` ([`dialog.tsx:139`][dialog-cohort]) walks
`root.querySelectorAll("[data-dialog][data-dialog-portal][data-open]")`, keeps only dialogs _after_ this one in
DOM order whose portal is not already in the `openModalPortals` `WeakSet`, and treats them as peers to be
exempted from inerting — so two modals opening together do not inert each other, while an already-established
stack is never re-ordered by DOM position.

**Degradation.** Everything in this dimension is a workaround for problems a single-surface toolkit does not
have: with one surface and a display list, "later in the list is in front" replaces portals, stacking contexts,
z-index mirroring and fullscreen re-parenting. What must be kept is the _ownership tree_. Ariakit needed three
ad-hoc registries because it has no first-class overlay tree, and the subtle bugs this dimension guards against
(persistent elements, cohorts, nested marks) all trace back to that absence.

### 11. Modality

[Modality][concepts] here is not a focus trap and not `aria-modal` — it is a DOM-mutation regime applied to
everything outside the dialog. On open, three passes run in order:

1. **Snapshot.** `createWalkTreeSnapshot` stamps a per-dialog property `__ariakit-dialog-snapshot-<id>` on `body`
   and on every element outside the dialog _at open time_, so later-added third-party nodes are never touched
   ([`walk-tree-outside.ts:70`][walk-snapshot]). The snapshot is taken independently of nested dialogs, so
   re-rendering a child does not re-snapshot.
2. **Mark inside.** `markTreeInside` records the dialog, persistent elements, opening-cohort peers and nested
   dialogs' content elements in a `WeakMap<Element, WeakSet<Element>>` keyed by the dialog node
   ([`tree-cleanup.ts:40`][tree-mark-inside]), so outside-listeners can recognise them as inside _before_ the
   dialog has ever been focused.
3. **Mark and disable outside.** `markAndDisableTreeOutside` walks siblings-of-ancestors and, per element, stamps
   `__ariakit-dialog-outside` and either sets `inert` (when supported) or falls back to: `tabindex="-1"` on every
   tabbable, a no-op `focus` method, `role="none"` on ancestors that had a role, and
   `pointer-events: none` / `user-select: none` ([`disable-tree.ts:90`][disable-tree-mark]).

Non-modal dialogs run only the marking half, so "outside" is a queryable property of nodes without any
interaction being blocked — which is exactly what makes [light dismiss][concepts] cheap for hovercards and
tooltips.

**Algorithm.** The walk ([`walk-tree-outside.ts:38`][walk-tree-outside]):

```text
walkTreeOutside(id, elements, cb, ancestorCb):
    for each element in elements:
        skip if it already has an ancestor in the list
        walk up to body:
            ancestorCb(parent, element)
            unless it had an ancestor in the list:
                for each sibling child passing shouldWalkElement: cb(child)

shouldWalkElement(child) = tag not in {SCRIPT, STYLE}
                        && inSnapshot(id, child)
                        && no listed element is contained by it
```

`inSnapshot` walks up looking for the snapshot property and returns `true` if `body` was never stamped, so a
dialog opened before the snapshot degrades to "everything is in scope" rather than to nothing.

Every mutation goes through `orchestrate()` ([`orchestrate.ts:26`][orchestrate]), a per-element per-key stack of
setup/cleanup entries that restores in LIFO order and tolerates out-of-order disposal — an entry only _marks_
itself disposed, and the stack is flushed from the top until it meets a live entry. That is what lets overlapping
dialogs inert and un-inert the same nodes without corrupting the original attributes.

The backdrop is a separate `DisclosureContent`-driven element (`role="presentation"`,
`data-backdrop="<dialogId>"`, `position: fixed`, inset 0) deliberately excluded from marking and disabling by
`isBackdrop`, and marked as an _ancestor_ of the dialog so clicking it counts as an outside interaction. Scrim
appearance is entirely author CSS. `preventBodyScroll` is separate again — root-dialog-arbitrated via a body
attribute plus a `MutationObserver` retry, with three compensation strategies (none, `scrollbar-gutter: stable`,
padding plus `--scrollbar-width`) and a distinct iOS `position: fixed` strategy
([`use-prevent-body-scroll.ts:29`][prevent-body-scroll]).

**Degradation.** With one surface and a derived hit list, modality reduces to a boolean on the overlay node plus
a hit-test cut and a keyboard-routing cut, and every file above becomes unnecessary. Two ideas remain worth
importing, and both are pure data: `getPersistentElements` — an explicit escape list of things that count as
inside though they live elsewhere in the tree (a toast container; a combobox input rendered outside its listbox)
— and the open-time snapshot, i.e. modality applies to the world _as it was when the overlay opened_, not to
whatever appears later. No OS window is unaffected; with no script, modality cannot exist.

### 12. Adaptive presentation

Ariakit deliberately does not own this decision. There is no compact/regular breakpoint, no sheet variant, no
long-press-for-tooltip and no teaching-tip component. The library's answer is to make every dimension of
presentation a prop an application can flip from its own media query. The canonical responsive-popover example
uses a `useMedia` hook and passes `modal={!isLarge}`, a conditional `backdrop`, and — the load-bearing part —
`updatePosition={isLarge ? undefined : customFn}`, where the custom function abandons Floating UI entirely and
writes `position: fixed; bottom: 0; width: 100%`, i.e. a bottom sheet ([`examples/popover-responsive`][ex-responsive]).

**Algorithm.** There is no adaptation algorithm in the library. There is only a seam
([`popover.tsx:477`][popover-custom-update], documented at [`:812`][popover-update-position-doc]):

```text
updatePosition?: (props: { updatePosition: () => Promise<void> }) => void | Promise<void>
```

It is invoked in place of the default positioner while the placing bit is held; the application may call the
supplied default, keep working, and the popup counts as placed only when the whole callback resolves. If a custom
callback throws, waiters are released only if a position had already been written.

Touch is handled only negatively: the `isMouseMoving` gate suppresses tooltips and hovercards on taps (the second
`isMouseMoving()` check inside `showHovercard` exists for exactly this), and `combobox-store` carries an
`isTouchSafari` constant. Keyboard-driven relocation exists in one narrow form: `HovercardDisclosure`, a
visually-hidden button that becomes visible when a `MutationObserver` sees `data-focus-visible` appear on the
anchor ([`hovercard-disclosure.tsx:98`][hovercard-disclosure]), giving keyboard users a way into a hover-only
surface.

**Degradation.** This is the dimension where the subject has the least to offer a target with no hover: every
hovercard and tooltip trigger is dead there, and the library supplies no mapping to a replacement. Its
transferable piece is only the _shape_ of the seam — a single override hook that can hold the "placed" bit open
while it works. A toolkit whose placement layer must also fold in a soft-keyboard inset cannot push the decision
to the application the way this seam does, because the inset is an input to placement rather than a style choice.

### 13. Accessibility

Roles are computed from the rendered content element rather than asserted: `getPopupRole(contentElement,
fallback)` reads the actual `role` attribute, so a `MenuButton` whose menu renders as a dialog reports
`aria-haspopup="dialog"` ([`menu-button.tsx:224`][menu-button-role]); `getPopupItemRole` does the same for items.

Tooltip semantics are being narrowed. `role="tooltip"` is emitted only when `type === "description"`
([`tooltip.tsx:63`][tooltip-role]), and the `type` option is deprecated with a development-mode warning
([`tooltip-store.ts:17-25`][tooltip-store-deprecation]):

> The `type` option on the tooltip store is deprecated. Render a visually hidden label or use the `aria-label` or
> `aria-labelledby` attributes on the anchor element instead.

Ariakit therefore refuses the description-versus-label duality at the primitive level and pushes the anchor's
accessible name onto the author. Tooltip content _may_ be interactive here — a `Tooltip` is a `Hovercard` is a
`Dialog`, so it can contain focusable content, and the repo's own browser test clicks a button inside a tooltip
and presses Escape to restore the anchor ([`sandbox/tooltip-interactions`][sandbox-tooltip]). That is a
deliberate divergence from the ARIA tooltip pattern described in [`./aria-apg.md`](./aria-apg.md).

Hover-only hazards are addressed structurally: `HovercardDisclosure` gives keyboard access; hover-out is
polygon-guarded (hoverable); the tooltip refuses to hide on hover-out while the anchor is focus-visible
(persistent); Escape dismisses (dismissible). Modal dialogs prepend a visually-hidden "Dismiss popup" button when
no `DialogDismiss` exists ([`dialog.tsx:364`][dialog-hidden-dismiss]), reset heading levels via `HeadingLevel`,
wire `aria-labelledby` / `aria-describedby` from `DialogHeading` / `DialogDescription` contexts, and set
`role="none"` on outside ancestors that had a role. `aria-modal` is **not** used; the outside tree is inerted
instead. Portals get `aria-owns` from a fixed-position span placed next to the tab-order anchor.

**Degradation.** None of the ARIA attributes exist off the DOM. What belongs in a primitive is the
_classification_, not the attributes: an overlay kind, whether it is described-by or labelled-by its anchor,
whether it is dismissible and hoverable, and whether it takes focus. Those bits drive both ARIA on an HTML
backend and, on a cell grid, the equivalent decisions about announcement order and Escape handling. The
strongest evidence this subject offers is negative: the one place it modelled a semantic distinction inside the
overlay _store_ — the tooltip's `type: label | description` — is the one place it is deprecating.

### 14. Animation

Ariakit emits geometry metadata specifically for animation, and owns an animation _lifecycle_ so exit animations
can run before unmount.

**Metadata.** `data-placing` (mirroring `unstable_placing`), `data-open` / `data-enter` / `data-leave` on the
content element ([`disclosure-content.tsx:268-271`][disclosure-data-attrs]), `currentPlacement` in the store
(distinct from the requested placement, and documented as the thing a Motion example reads), and the custom
properties `--popover-transform-origin`, `--popover-anchor-width`, `--popover-available-width` /
`--popover-available-height`, `--popover-overflow-padding` (written even while hidden, because it is public API)
and `--dialog-viewport-height`.

**Lifecycle.** The disclosure store carries `{open, animated, animating, mounted}` with `mounted = open ||
animating`, so unmount is deferred. The duration is _derived from computed style_ rather than from a
`transitionend` event that may never fire ([`disclosure-content.tsx:41`][disclosure-get-end-time]):

```text
getEndTime(names, delays, durations) =
    max over i of ( name[i] !== "none"
                    ? parse(delay[i % nDelays]) + parse(duration[i % nDurations])
                    : 0 )
```

That `i % n` is CSS's cyclic list-matching rule, and pairing the lists index-wise rather than taking independent
maxima is the point: independent maxima would combine one transition's delay with another's duration and
overestimate the end time. The result is computed separately for transitions and animations, maxed, then maxed
again across the content element, the store-tracked other element (backdrop ↔ dialog) and an explicitly passed
related element; finally one 60 Hz frame is subtracted to avoid a flicker
([`disclosure-content.tsx:236`][disclosure-frame-sub]). If the computed timeout is zero it not only stops
immediately but sets `animated = false`, so the next close unmounts without waiting.

Transition state is set on a double animation frame so the data attribute lands after the element is really in
the DOM, and stale states are ignored (`transition === "leave" && open`, or `"enter" && !open`). Reposition
during an animation is not special-cased — `autoUpdate` keeps running. `alwaysVisible` exists specifically so a
third-party animation library can keep the element mounted and visible while closed.

**Reduced motion is not read anywhere in the overlay machinery.** The only `prefers-reduced-motion` occurrence in
this tree is in an unrelated example's `readme.md` ([`examples/tab-panel-animated/readme.md`][ex-tab-panel]);
motion preference is left entirely to author CSS.

**Degradation.** On a cell grid there is no transform origin and no easing surface worth naming, but the
_lifecycle_ is backend-neutral and is exactly what a toolkit needs: open / closing / closed with a closing
duration, plus the invariant that geometry metadata (resolved side, alignment offset, anchor width, available
size) is published as data before paint. The derive-duration-from-computed-style trick is DOM-specific; a toolkit
that owns its animation clock states the duration directly. Because `mounted` and `animating` are store state and
the timeout is a number, the whole thing is assertable with a virtual clock.

### 15. State architecture

An event-driven observable-store architecture — explicitly not a statechart and not a reducer.
`createStore(initialState, ...parentStores)` ([`store/index.ts:380`][store-create]) returns
`{getState, setState, __unstableInternals}`. `setState` is per-key: it early-returns on `SameValue` equality,
clones the state object, fans the change out to parent stores, then notifies.

Three subscription timings share one type and differ in semantics: `subscribe` (after the change), `sync`
(immediately on registration and synchronously on change), `batch` (immediately, then microtask-coalesced with a
`Set` of updated keys). Listeners may return a cleanup that runs before their next invocation — which is how
derived rules such as "when `mounted` goes false, clear `activeId`" express themselves
([`menu-store.ts:103-108`][menu-store-activeid]).

**Algorithm.** `setState(key, value, fromStores = false)` ([`store/index.ts:709`][store-set-state]):

```text
if !hasOwnProperty(state, key) return
next = applyState(value, () => state[key])
if SameValue(next, state[key]) return
prev = state; state = { ...state, [key]: next }
if (!fromStores && parents):
    for each parent: parent.setState(key, next)
    if state[key] changed underneath -> mark superseded and stop
    if superseded: run up to MAX_REPAIR_PASSES pushing the committed value to every parent
if (!superseded):
    notify sync listeners with a prevState that preserves reentrantly-committed other keys
    if batch listeners exist: add key to updatedKeys; schedule one microtask flush that
        swaps the Set so reentrant updates land in the next flush
```

`MAX_REPAIR_PASSES` is 100 ([`store/index.ts:115`][store-repair]) and bounds parent/child fights over one key.
Composition primitives are `mergeStore`, `pick`, `omit`, `setup` (register an init-time callback) and `init`
(reference-counted, so a store shared by two components is destroyed only once). Controlled versus uncontrolled
is convention — `open` versus `defaultOpen`, with `throwOnConflictingProps` rejecting store-plus-default
combinations.

Derived state is written as explicit `sync` rules inside `setup()` (`mounted = open || animating`; submenu
placement from parent orientation; `activeId = null` on unmount), i.e. the "reducer" is a set of small local
invariants rather than a transition table. There is exactly one enum-shaped state in the overlay stack — menu's
`initialFocus: "container" | "first" | "last"`; everything else is booleans, numbers and element references.

**Degradation.** The _shape_ survives a value-semantics, allocation-conscious toolkit; the _implementation_ does
not. Portable: per-key change detection with `SameValue`, derived invariants as small pure rules,
controlled-versus-uncontrolled by explicit precedence, per-listener cleanup discipline. Not portable: `{...state}`
cloning per `setState` (an allocation per keystroke), `WeakMap`s and `WeakSet`s keyed by DOM nodes, `Symbol`
instance sets, microtask batching, and the fast-path-frame recovery machinery. That last piece appears to exist
because listeners can register and re-key themselves during dispatch — the repair loop and the recovery frames
are both about dispatch-time mutation — which is a hazard specific to this dispatch model rather than a
universal cost of observable state.

> [!IMPORTANT]
> The store's state holds `HTMLElement` references. That single choice is what keeps `@ariakit/components`
> DOM-bound despite depending only on `@ariakit/store` and `@ariakit/utils`, and it is precisely what prevents
> the anchor from being a plain comparable value (dimension 1).

### 16. Shared infrastructure

Factoring is by single-inheritance store chains plus hook chains, with very little duplication.

```text
stores:  Disclosure -> Dialog (alias) -> Popover -> Hovercard -> Tooltip
         Menu   = Composite + Hovercard
         Select = Composite + Popover      Combobox = Composite + Popover
         CompositeOverflow = Popover verbatim
hooks:   useTooltip -> useHovercard -> usePopover -> useDialog
             -> { useFocusableContainer, useDisclosureContent, useFocusable, usePortal }
```

Genuinely common: the disclosure/mounted/animating lifecycle, the anchor/disclosure/content/popover element
quartet, hide-on-escape, hide-on-interact-outside, focus restoration, portal plus tab-order preservation, the
positioning pass. Pieces that only _look_ common and are correctly kept apart:

- **Hover intent is Hovercard-and-below only.** `Popover` and `Dialog` never load the polygon.
- **Composite / roving focus is a sibling axis**, mixed in per component rather than part of the overlay chain,
  so a `Popover` has no items and a `Menu` gets items without the overlay knowing.
- **The tooltip singleton lives in the React component file**, not in any store, because it is a page-global
  policy rather than overlay state.
- **`__hovercard-trigger.tsx` is a private shared trigger** used by both `HovercardAnchor`
  (`setAnchorElement: true`) and `MenuButton` (`setAnchorElement: false`) — the anchor-versus-trigger
  distinction is its only parameter.
- **Arrow rendering is a component** (`PopoverArrow`) while arrow _geometry_ is in the positioning pass.

**The mechanical device.** Divergence is written as `props = useX({defaults, ...props, narrowedPredicate})`:
placing `...props` before the predicate makes the predicate authoritative, placing defaults before it makes them
overridable. `BooleanOrCallback` options let a subclass wrap the superclass's predicate — check
`isFalsyBooleanCallback(prop, event)`, then add its own rule.

**Where sharing broke down, it shows.** `ComboboxPopover` has to re-implement `getPersistentElements` to re-admit
its own input and select controls into its modal context ([`combobox-popover.tsx:233`][combobox-persistent]),
because the dialog's notion of "inside" is DOM containment rather than explicit membership.

**Degradation.** The factoring is the most directly actionable thing here. What one anchored-overlay primitive
should own, on this evidence: anchor (a comparable id or rect), requested and resolved placement, the
gutter/shift/flip/slide/overlap/padding policy, open/closing/closed, dismissal predicates, focus policy, a
modality flag, a parent link, and the resolved side plus arrow offset as data. What it should _not_ own: hover
intent (a separate value the caller feeds it), roving focus and item collections, the tooltip singleton (a global
policy value), arrow rendering, animation duration, or the accessibility role. Ariakit's evidence is that it
already keeps every one of those apart — and its one leak is exactly the case where "inside" was defined by tree
containment.

## Strengths

- `polygon.ts` is 96 lines, dependency-free, integer-arithmetic-only, unit-tested including the vertex-grazing
  edge case, and separated from all orchestration — the most directly portable artefact in the subject.
- `unstable_placing` turns "not yet positioned" into observable state with a mirrored `data-placing` attribute,
  so focus, scroll-into-view and tests all wait on the same fact instead of guessing with animation frames.
- The store chain makes each overlay's differences explicit and small; `Tooltip`'s entire divergence from
  `Hovercard` is two narrowed predicates and four default values, which reads as a specification of what actually
  differs between surface kinds.
- Element-reference state is split three ways — `anchorElement` / `disclosureElement` / `contentElement` — with
  a tested reconciliation rule, correctly separating "what I am positioned against" from "what opened me and
  where focus returns".
- Outside-interaction detection is unusually careful: mousedown/click pairing survives drag-out selections, a
  bounding-box hit test treats transparent gaps over the popup as inside, cross-document targets are handled, and
  a focused-once gate keeps hovercards alive through unrelated DOM insertions.
- Geometry is deliberately published as data — `currentPlacement` in the store; anchor width, available size,
  transform origin and overflow padding as CSS variables — rather than consumed privately.
- The tooltip singleton solves warm-up and cool-down with one global nullable plus one number, and hardens it
  against controlled-open re-entrancy with a `WeakSet`.
- Comments carry the reasoning and often link the issue that produced the behaviour, which makes the non-obvious
  guards (`capturedDisclosures`, `hidingStores`, the `vy` lookback, the cohort scan) legible rather than
  mysterious.
- Overlay tests are behaviour-level and edge-case-first — sandboxes named after issue numbers, browser tests for
  wheel-during-hovercard and cross-anchor tooltip timing — rather than snapshot-level.

## Weaknesses

- Modality by DOM mutation is a large body of accidental complexity: a snapshot pass, an inside-marking pass, an
  inert/disable pass, a stacked restoration mechanism, backdrop and focus-trap exemptions, a nested-dialog
  registry, an opening-cohort DOM scan, and `getPersistentElements` as an escape hatch.
- No logical placement, no RTL handling and no writing-mode awareness in Ariakit itself; the placement union is
  twelve physical strings and `-start`/`-end` semantics are delegated.
- The anchor cannot be compared, cached or serialised — element identity plus a `getBoundingClientRect` closure,
  so "did the anchor change?" is answerable only by element identity.
- No arrow hiding when the anchor scrolls out of view (no `referenceHidden` middleware), and no reaction to
  anchor removal or the anchor becoming hidden — the popup stays where it was.
- Three unrelated ad-hoc registries stand in for one overlay tree, and bugs leak between them:
  `ComboboxPopover` must re-inject its own controls via `getPersistentElements` because dialog membership is DOM
  containment.
- Hover intent requires globally suppressing four mouse event types with `preventDefault`/`stopPropagation`,
  which is invasive to the host application and forces the trigger to use a native `mouseleave` listener to
  escape its own suppression.
- `isMouseMoving` is a module-global mutable boolean installed once and never removed, with a
  `process.env.NODE_ENV === "test"` branch that makes every synthetic move count as movement — so the production
  behaviour on that path is not the tested behaviour.
- Adaptive presentation is entirely the application's problem; there is no touch or compact story beyond
  suppressing hover.
- Reduced motion is not read anywhere in the overlay machinery.
- Store internals have grown intricate — fast-path frames, listener re-keying recovery, a 100-pass parent repair
  loop with a console warning — correctness machinery attached to dispatch-time listener mutation.

## Key design decisions and trade-offs

| Decision                                                                                                                  | Rationale                                                                                                                                                                                                                                                                    | Trade-off                                                                                                                                                                                                                                                                                     |
| ------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Make `Dialog` the base of every overlay (`Tooltip` is a `Hovercard` is a `Popover` is a `Dialog` is a `Disclosure`).      | Dismissal, focus restoration, portalling, mount/unmount animation and modality are the same problem for all of them; writing them once and narrowing with predicates and defaults eliminates the drift separate implementations accumulate.                                  | A tooltip carries the whole dialog apparatus: dialog-shaped defaults, disclosure capture, escape arbitration, portal machinery and outside-interaction listeners. It also puts the ARIA tooltip pattern out of reach by construction, since tooltip content can be focusable and interactive. |
| Delegate all positioning to `@floating-ui/dom` and expose an `updatePosition` override rather than a strategy enum.       | Collision detection against clipping ancestors, transforms and zoom is a large browser-specific problem the library does not want to own; an override seam lets applications express bottom sheets or custom two-phase measurement with no new API.                          | Placement semantics (RTL, logical placements, fallback ordering details) are not Ariakit's to define or fix, and the async `computePosition` forces both the cancellation protocol and `unstable_placing` into existence. The override must itself participate in the placed-bit contract.    |
| Implement hover intent as a polygon over the popup rect from a refreshed exit point, and suppress mouse events inside it. | A pure hide-delay is not enough: while the pointer crosses the gap it passes over elements whose `mouseenter`/focus handlers would close the card, and suppressing those events is the only way to guarantee the corridor without a pointer grab.                            | Global capture-phase `preventDefault`/`stopPropagation` on four mouse event types is invasive to the host application, and it forces the trigger to listen for a _native_ `mouseleave` to escape its own suppression. It cannot be replicated without control of the event dispatcher.        |
| Achieve modality by walking the DOM and inerting/marking everything outside, rather than by a focus trap.                 | Real inertness (pointer, focus and accessibility tree) is stronger than a tab-cycling trap, and it lets non-modal surfaces reuse the same marking pass to answer "is this event outside?".                                                                                   | It mutates foreign DOM, which required an open-time snapshot, a stacked restoration mechanism, backdrop and focus-trap exceptions, a nested-dialog registry, an opening-cohort heuristic and `getPersistentElements`. `FocusTrapRegion` survives as dead code.                                |
| Gate hover-opening on a global movement predicate rather than on `mouseenter` or `pointerType`.                           | `mouseover`/`mouseenter` fire from scrolling, from taps, from layout moving under a stationary cursor and from programmatic focus; requiring non-zero `movementX`/`movementY` since the last `mousedown`/`mouseup`/`keydown`/`scroll` rejects all of those with one boolean. | A page-global mutable flag with a test-mode escape that makes every synthetic move count. Touch is handled implicitly, so there is nowhere to hang a deliberate touch presentation.                                                                                                           |
| Publish resolved geometry as CSS custom properties and data attributes rather than as callback arguments.                 | The styling layer, not JavaScript, should decide how a popup reacts to its resolved side, its anchor's width or the available space — `--popover-anchor-width`, `--popover-available-*`, `--popover-transform-origin`, `data-enter`/`data-leave` do that with zero runtime.  | The metadata contract becomes stringly-typed and partly undocumented (`--popover-overflow-padding` silently collapses a per-side object to `max(left, right)`), and consumers who need the values in code must read them back out of the DOM or subscribe to `currentPlacement` separately.   |
| Keep the state layer framework-free and key-granular, but let it hold DOM element references.                             | A tiny observable object with per-key subscriptions gives fine-grained re-renders and lets stores compose (menu inherits combobox, submenu inherits parent) without a reducer or a statechart; element references make anchor/disclosure/content relationships declarative.  | `@ariakit/components` cannot be used off the DOM despite depending only on `@ariakit/store` and `@ariakit/utils`. The elements-in-state choice is precisely what prevents the anchor from being a plain comparable value.                                                                     |

## Sources

Primary sources, all read at `a0426ed547d95b84c9d53033053e51baeaca4aaa`:

- Store engine — [`packages/ariakit-store/src/index.ts`][store-create] (`createStore`, `setState` fan-out and
  repair, `MAX_REPAIR_PASSES`).
- Typed stores — [`popover-store.ts`][popover-store-initial], [`hovercard-store.ts`][hovercard-store-timeout],
  [`tooltip-store.ts`][tooltip-store-deprecation], [`menu-store.ts`][menu-store-timeout],
  [`dialog-store.ts`][dialog-store], [`disclosure-store.ts`][disclosure-store].
- Positioning — [`popover.tsx`][popover-position-effect] (virtual anchor, middleware assembly, cancellation, DPR
  snapping, CSS variables, placing-bit writers) and [`popover-arrow.tsx`][popover-arrow-mask].
- Hover intent — [`hovercard/utils/polygon.ts`][polygon-in-polygon] and its
  [test][polygon-test-apex]; orchestration in [`hovercard.tsx`][hovercard-transit-comment]; the shared trigger in
  [`__hovercard-trigger.tsx`][hovercard-trigger-move]; the movement predicate in
  [`ariakit-react-utils/src/hooks.ts`][hooks-mouse-moving].
- Dismissal, focus and modality — [`dialog.tsx`][dialog-accept-escape] plus
  [`dialog/utils/`][walk-tree-outside]: `walk-tree-outside.ts`, `disable-tree.ts`, `tree-cleanup.ts`,
  `orchestrate.ts`, `use-hide-on-interact-outside.ts`, `use-previous-mouse-down-ref.ts`,
  `use-prevent-body-scroll.ts`.
- Layering — [`portal/portal.tsx`][portal-root]; cohort logic in [`dialog.tsx:139`][dialog-cohort].
- Animation lifecycle — [`disclosure/disclosure-content.tsx`][disclosure-get-end-time].
- Timing singleton — [`tooltip/tooltip-anchor.tsx`][tooltip-anchor-global].
- Examples and sandboxes — [`menu-context-menu`][ex-context-menu], [`popover-selection`][ex-selection],
  [`popover-responsive`][ex-responsive], [`sandbox/hovercard-interactions`][sandbox-hovercard],
  [`sandbox/tooltip-interactions`][sandbox-tooltip], [`sandbox/tooltip-cross-anchor`][sandbox-tooltip-cross].
- Project documentation — [ariakit.com][docs] (used for API surface and deprecation guidance only; every
  mechanism above is read from source).

Related pages in this catalog: [`./index.md`](./index.md), [`./concepts.md`](./concepts.md),
[`./comparison.md`](./comparison.md), [`./features-people-forget.md`](./features-people-forget.md),
[`./proposal.md`](./proposal.md); the positioning engine this subject delegates to,
[`./floating-ui.md`](./floating-ui.md); the nearest headless peers, [`./radix.md`](./radix.md),
[`./base-ui.md`](./base-ui.md), [`./zag.md`](./zag.md), [`./react-aria.md`](./react-aria.md),
[`./headlessui.md`](./headlessui.md), [`./angular-cdk.md`](./angular-cdk.md); the platform baseline it does not
use, [`./popover-api.md`](./popover-api.md) and [`./css-anchor.md`](./css-anchor.md); and the pattern it
diverges from, [`./aria-apg.md`](./aria-apg.md). Toolkit context:
[`../../specs/ui/index.md`](../../specs/ui/index.md), [`../../specs/ui/input.md`](../../specs/ui/input.md),
[`../../specs/ui/state-machines.md`](../../specs/ui/state-machines.md),
[`../../specs/ui/containers.md`](../../specs/ui/containers.md).

<!-- References -->

[repo]: https://github.com/ariakit/ariakit/tree/a0426ed547d95b84c9d53033053e51baeaca4aaa
[docs]: https://ariakit.com
[concepts]: ./concepts.md
[dialog-store]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-components/src/dialog/dialog-store.ts#L12
[disclosure-store]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-components/src/disclosure/disclosure-store.ts#L56
[menu-hovercard]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/menu/menu.tsx#L190
[tooltip-overrides]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/tooltip/tooltip.tsx#L69
[popover-store-placing]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-components/src/popover/popover-store.ts#L147-L159
[popover-store-initial]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-components/src/popover/popover-store.ts#L58
[popover-store-synced]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-components/src/popover/popover-store.ts#L69
[popover-store-sync]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-components/src/popover/popover-store.ts#L74-L83
[popover-store-render]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-components/src/popover/popover-store.ts#L91
[popover-store-placement]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-components/src/popover/popover-store.ts#L19-L24
[popover-store-test]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-components/src/popover/popover-store.test.ts
[polygon-where]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/hovercard/utils/polygon.ts#L23
[polygon-in-polygon]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/hovercard/utils/polygon.ts#L9-L60
[polygon-enter-placement]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/hovercard/utils/polygon.ts#L62
[polygon-get-element]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/hovercard/utils/polygon.ts#L70-L96
[polygon-test-apex]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/hovercard/utils/polygon.test.ts#L70-L72
[hovercard-transit-comment]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/hovercard/hovercard.tsx#L82-L83
[hovercard-refresh-enter]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/hovercard/hovercard.tsx#L251-L257
[hovercard-suppress]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/hovercard/hovercard.tsx#L286-L307
[hovercard-nested-register]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/hovercard/hovercard.tsx#L335-L351
[hovercard-register-nested]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/hovercard/hovercard.tsx#L353-L367
[hovercard-disclosure]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/hovercard/hovercard-disclosure.tsx#L98
[hovercard-trigger-ref]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/hovercard/__hovercard-trigger.tsx#L107-L118
[hovercard-trigger-move]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/hovercard/__hovercard-trigger.tsx#L57-L63
[hovercard-trigger-second-check]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/hovercard/__hovercard-trigger.tsx#L74
[hovercard-trigger-zero]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/hovercard/__hovercard-trigger.tsx#L88-L93
[hovercard-trigger-native-leave]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/hovercard/__hovercard-trigger.tsx#L38-L51
[hovercard-store-timeout]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-components/src/hovercard/hovercard-store.ts#L29
[hovercard-store-placement]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-components/src/hovercard/hovercard-store.ts#L24-L26
[tooltip-store-placement]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-components/src/tooltip/tooltip-store.ts#L31-L35
[tooltip-store-hide-timeout]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-components/src/tooltip/tooltip-store.ts#L36
[tooltip-store-skip]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-components/src/tooltip/tooltip-store.ts#L42
[tooltip-store-deprecation]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-components/src/tooltip/tooltip-store.ts#L17-L25
[tooltip-anchor-global]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/tooltip/tooltip-anchor.tsx#L23-L27
[tooltip-anchor-hiding]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/tooltip/tooltip-anchor.tsx#L39-L46
[tooltip-anchor-sync]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/tooltip/tooltip-anchor.tsx#L83-L116
[tooltip-anchor-focus-visible]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/tooltip/tooltip-anchor.tsx#L127
[tooltip-role]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/tooltip/tooltip.tsx#L63
[tooltip-narrowing]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/tooltip/tooltip.tsx#L75
[menu-store-timeout]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-components/src/menu/menu-store.ts#L81-L85
[menu-store-orientation]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-components/src/menu/menu-store.ts#L110-L117
[menu-store-activeid]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-components/src/menu/menu-store.ts#L103-L108
[menu-can-autofocus]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/menu/menu.tsx#L148
[menu-hide-all]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/menu/menu.tsx#L197
[menu-button-role]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/menu/menu-button.tsx#L224
[combobox-persistent]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/combobox/combobox-popover.tsx#L233
[popover-get-anchor]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/popover/popover.tsx#L88-L105
[popover-valid-placement]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/popover/popover.tsx#L107
[popover-round-dpr]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/popover/popover.tsx#L112
[popover-overflow-padding]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/popover/popover.tsx#L117-L120
[popover-offset-mw]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/popover/popover.tsx#L122-L144
[popover-shift-mw]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/popover/popover.tsx#L165-L179
[popover-size-mw]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/popover/popover.tsx#L181-L198
[popover-placing-writers]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/popover/popover.tsx#L46
[popover-position-effect]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/popover/popover.tsx#L333
[popover-should-cancel]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/popover/popover.tsx#L378
[popover-default-arrow]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/popover/popover.tsx#L388-L393
[popover-arrow-handling]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/popover/popover.tsx#L444-L473
[popover-custom-update]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/popover/popover.tsx#L477
[popover-autoupdate]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/popover/popover.tsx#L503
[popover-zindex]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/popover/popover.tsx#L543
[popover-placing-effect]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/popover/popover.tsx#L568
[popover-autofocus-gate]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/popover/popover.tsx#L644
[popover-update-position-doc]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/popover/popover.tsx#L812
[popover-arrow-mask]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/popover/popover-arrow.tsx#L56
[dialog-escape-map]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/dialog/dialog.tsx#L663-L669
[dialog-accept-escape]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/dialog/dialog.tsx#L684-L705
[dialog-escape-marked]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/dialog/dialog.tsx#L696-L698
[dialog-cohort]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/dialog/dialog.tsx#L139
[dialog-viewport-height]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/dialog/dialog.tsx#L343
[dialog-hidden-dismiss]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/dialog/dialog.tsx#L364
[dialog-initial-focus]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/dialog/dialog.tsx#L496
[dialog-focus-microtask]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/dialog/dialog.tsx#L515
[dialog-focus-on-hide]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/dialog/dialog.tsx#L582
[focus-trap-region]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/focus-trap/focus-trap-region.tsx#L27
[uhoio-mouse-on-dialog]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/dialog/utils/use-hide-on-interact-outside.ts#L58
[uhoio-doc]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/dialog/utils/use-hide-on-interact-outside.ts#L126
[uhoio-click]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/dialog/utils/use-hide-on-interact-outside.ts#L215
[uhoio-focusin]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/dialog/utils/use-hide-on-interact-outside.ts#L255
[uhoio-contextmenu]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/dialog/utils/use-hide-on-interact-outside.ts#L275
[prev-mousedown]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/dialog/utils/use-previous-mouse-down-ref.ts#L62
[walk-tree-outside]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/dialog/utils/walk-tree-outside.ts#L38
[walk-snapshot]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/dialog/utils/walk-tree-outside.ts#L70
[disable-tree-mark]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/dialog/utils/disable-tree.ts#L90
[tree-mark-inside]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/dialog/utils/tree-cleanup.ts#L40
[orchestrate]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/dialog/utils/orchestrate.ts#L26
[prevent-body-scroll]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/dialog/utils/use-prevent-body-scroll.ts#L29
[portal-root]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/portal/portal.tsx#L33
[portal-fullscreen]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/portal/portal.tsx#L186
[disclosure-get-end-time]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/disclosure/disclosure-content.tsx#L41
[disclosure-frame-sub]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/disclosure/disclosure-content.tsx#L236
[disclosure-data-attrs]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/disclosure/disclosure-content.tsx#L268-L271
[hooks-mouse-moving]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-utils/src/hooks.ts#L399-L442
[store-create]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-store/src/index.ts#L380
[store-set-state]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-store/src/index.ts#L709
[store-repair]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-store/src/index.ts#L115
[ex-context-menu]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/examples/menu-context-menu/index.react.tsx
[ex-selection]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/examples/popover-selection/index.react.tsx
[ex-responsive]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/examples/popover-responsive/index.react.tsx
[ex-tab-panel]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/examples/tab-panel-animated/readme.md
[sandbox-hovercard]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/app/src/sandbox/hovercard-interactions/test-chrome-firefox.ts
[sandbox-tooltip]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/app/src/sandbox/tooltip-interactions/test.ts
[sandbox-tooltip-cross]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/app/src/sandbox/tooltip-cross-anchor/test-browser.ts
