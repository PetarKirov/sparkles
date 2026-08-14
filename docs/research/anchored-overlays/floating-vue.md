# Floating Vue (TypeScript / Vue 3)

A Vue 3 binding over `@floating-ui/dom` in which a single 1187-line component — `Popper.ts` — is the entire product, and tooltip, dropdown and menu are nine-line files that differ only by one theme string.

| Field             | Value                                                                                                                                                                                     |
| ----------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language          | TypeScript + Vue 3 SFC (Options API)                                                                                                                                                      |
| License           | MIT                                                                                                                                                                                       |
| Repository        | [`Akryum/floating-vue`][repo]                                                                                                                                                             |
| Documentation     | [`docs/guide/component.md`][docs-component] (in-repo VitePress)                                                                                                                           |
| Category          | Web / framework binding                                                                                                                                                                   |
| Surface model     | in-canvas — every popper is appended into ONE container (`document.body` by default) at a single flat `z-index: 10000`; no OS popup, no [top layer][concepts], no per-popper z escalation |
| **Revision read** | [`19857764c4f73dea7ed44a7d970adb968ee7ad90`][repo-sha] (v5.2.2)                                                                                                                           |

Source-derived, not docs-derived: every claim below is read from the package
sources at that revision. Where a claim is an inference from control flow rather
than an observed behaviour, it says so.

> [!IMPORTANT]
> `@floating-ui/dom` is a declared dependency (`~1.1.1`) but `node_modules` is
> absent from the clone read here. Every statement about `flip`, `shift`,
> `size`, `arrow`, `autoPlacement`, clipping-ancestor discovery or transform/DPR
> handling is an inference **from the call site only**, and is deferred to
> [`./floating-ui.md`](./floating-ui.md), which read that tree directly.

## Overview

### What it solves

Floating Vue makes an anchored overlay a _component you write in a template_ —
`VTooltip`, `VDropdown`, `VMenu`, plus the `v-tooltip` directive — over a
geometry engine it does not own. Its actual contribution is the choreography
around the geometry: when to show, when to hide, which overlay closes first,
which one paints in front, and which of several nested overlays a click belongs
to. The [placement][concepts] arithmetic is entirely floating-ui's; everything
floating-vue adds is ordinary imperative JavaScript coordinating a small number
of process-global registers.

The three public overlay kinds are literally the same object. `Tooltip.ts`,
`Dropdown.ts` and `Menu.ts` are nine lines each — a spread of `PopperWrapper`
plus a name and a `vPopperTheme` string — and every behavioural difference
between a tooltip, a dropdown and a submenu lives in a plain data table,
`config.themes`, resolved per key through a `$extend` chain.

```ts
// packages/floating-vue/src/components/Menu.ts:1-9
import PopperWrapper from './PopperWrapper.vue';

const Component = {
  ...PopperWrapper,
  name: 'VMenu',
  vPopperTheme: 'menu',
} as unknown as typeof PopperWrapper;

export default Component;
```

### Design philosophy

**Delegate geometry, own the choreography.** The clearest statement of that
philosophy is that theme entries are not merely data but _transforms over
inherited data_ — a theme composes with its base rather than replacing it:

> `hideTriggers: events => [...events, 'click'],`
>
> — [`packages/floating-vue/src/config.ts:46`][config-46] (the `tooltip` theme)

The second statement is the layering rule, which is one line and has no
bookkeeping behind it at all:

> `container.appendChild(this.$_popperNode)`
>
> — [`packages/floating-vue/src/components/Popper.ts:882`][popper-882], inside
> `$_ensureTeleport`, called on **every** show

Because `appendChild` moves an existing node, and because every popper shares
one flat `z-index`, re-showing a popper brings it to the end of the container's
child list — stacking is append order, "later in the list paints in front",
literally. There is no [top layer][concepts], no focus trap, no
[modality][concepts], no ARIA `role`, no global Escape handler, and no
continuous position tracking (floating-ui's `autoUpdate` is never imported).
Correctness is bought instead with small, very specific hacks: an event object
mutated as an IPC channel (`event.usedByTooltip`), a one-frame "show lock" so
the click that opens a dropdown cannot immediately close it, a
`mousedown`/`click` pair so drag-selecting text out of a popover is not a
dismissal, and a ray-casting menu-aim lock that expires after one second.

> [!WARNING]
> Test coverage is effectively nil. The only spec file in the package covers
> `getPlacement` (three cases, `v-tooltip.spec.ts`), and the Cypress spec is the
> unmodified vue-cli template. None of the theme cascade, tree ordering,
> menu-aim, timing or dismissal logic has a test. No code was executed while
> reading this subject; every behavioural claim is read from source control flow.

## How it works

Four source files carry essentially all of it.

- **`Popper.ts`** (1187 lines) — the machine: props whose defaults are wired to
  the theme cascade, `init()`/`dispose()`, the show/hide scheduling, the
  middleware assembly, three module-level registries, the global dismissal
  listeners and the mouse sampler.
- **`PopperWrapper.vue`** — the public prop surface (every prop defaulting to
  `undefined`) plus `getTargetNodes`, which computes the trigger set as _all
  children of the wrapper except the popper content element_.
- **`PopperContent.vue`** — the view: reads a plain result object and writes a
  rounded `translate3d`, the arrow's `left`/`top`, `data-popper-placement`, the
  [transform origin][concepts], `aria-hidden` and `tabindex`.
- **`config.ts`** — the flat root config, the three-entry theme table, and three
  chain walks (`getDefaultConfig`, `getThemeClasses`, `getAllParentThemes`).

A show is roughly:

```text
show()
  guard: parent.lockedChild set and not me      -> return (silently)
  set $_showFrameLocked for one rAF
  $_scheduleShow -> instant-handoff check against the global `hidingPopper`
                 -> else setTimeout($_computeDelay('show'))
  $_applyShow
    $_ensureTeleport(container).appendChild(popperNode)   // moves to end
    register passive `scroll` on every overflow ancestor of reference + popper
    await $_computePosition()                             // floating-ui
    Object.assign(this.result, {x, y, placement, strategy, arrow})
    $_applyShowEffect: transform origin, class protocol, aria attrs, focus()
    push onto shownPoppers; register id at EVERY level of the parent chain
```

and a hide is the mirror image with three extra guards (`$_hideInProgress`, a
non-empty `shownChildren` set, and the menu-aim test), a
`disposeTimeout` detach, and a removal from every ancestor's descendant set.

## The analysis spine

### 1. Anchor model

Two distinct anchor roles, both supplied as thunks and resolved once in
`init()`: `$_referenceNode` (the geometry source, single) and `$_targetNodes`
(the event and ARIA source, an **array**). `PopperWrapper.getTargetNodes`
returns all wrapper children except the popper content, so
many-triggers-one-overlay is the default shape, while the reference defaults to
the wrapper's `$el` — trigger-set ≠ [anchor rect][concepts] is first class. The
directive path collapses both to `[el]` / `() => el`.

There is no point/cursor anchor, no text-range or multi-rect anchor, no
[virtual anchor][concepts], and no detached moving anchor: `clientX`/`clientY`
appear only in the menu-aim mouse sampler, never in positioning. A context menu
at the pointer is therefore not expressible with this library.

**Algorithm.** `init()` resolves `referenceNode = props.referenceNode?.() ?? this.$el`,
`targetNodes = props.targetNodes().filter(n => n.nodeType === ELEMENT_NODE)`,
`popperNode = props.popperNode()`, then queries `.v-popper__inner` and
`.v-popper__arrow-container` out of it. Thereafter the anchor is an opaque live
DOM node whose rect is re-read inside `computePosition` on every recompute. The
only anchor-derived _value_ is `result`, a plain object mutated in place by
`Object.assign`: `x`, `y`, `placement`, `arrow` (`x`, `y`, `centerOffset`,
`overflow`), `transformOrigin`, `strategy`.

**Where it lives.** Library code: `Popper.ts:490-515` (`init`),
`PopperWrapper.vue:313-316` (`getTargetNodes`), `directives/v-tooltip.ts:26-40`
(`getOptions`).

**Degradation.** Node identity _is_ the anchor, so nothing here survives off the
DOM as written; what ports is the shape — an anchor id resolved once, a `rect()`
lookup performed per recompute, and a separate trigger-set list. The
reference/target split is worth keeping in a cell toolkit for exactly the case
it was built for: a row of buttons sharing one tooltip. With no sub-cell
precision the anchor collapses to an integer cell rect, which is a strict
simplification. With no hover the anchor model is unaffected — only the trigger
set is (dimension 5).

### 2. Placement model

Fifteen physical placement strings, `{auto, top, bottom, left, right}` ×
`{'', -start, -end}`, generated by a `reduce` in `util/popper.ts:5-9` and
validated by a prop validator. `auto*` is special-cased: it routes to
floating-ui's `autoPlacement({alignment})` and **mutually excludes flip**
(`if (!isPlacementAuto && this.flip)`). There is no preferred-placement list —
floating-ui's `fallbackPlacements` is never passed — so [flip][concepts] is
opposite-side-only. Offset is `{mainAxis: distance, crossAxis: skidding}` and is
pushed only when nonzero. Cross-axis [shift][concepts] is opt-in via
`shiftCrossAxis`. Viewport padding is one scalar, `overflowPadding`.

> [!WARNING]
> `boundary` is forwarded to `shift`, `flip` and `size` but **not** to
> `autoPlacement` (`Popper.ts:556-560`), so `placement="auto"` silently ignores a
> custom [clipping boundary][concepts].

There is no RTL, logical-property or writing-mode code in the package; no
safe-area insets; no work areas; no multi-monitor concept (one document
coordinate space); and no IME or virtual-keyboard avoidance.

**Algorithm.** `$_computePosition` assembles a middleware array in a fixed
order and then awaits one `computePosition` call:

```text
[offset(mainAxis: distance, crossAxis: skidding)]        if distance || skidding
autoPlacement({alignment})  |  options.placement = placement
[shift({padding, boundary, crossAxis: shiftCrossAxis})]  if preventOverflow && shift
[flip({padding, boundary})]                              if preventOverflow && flip && !auto
arrow({element: $_arrowNode, padding: arrowPadding})
[arrowOverflow]                                          if arrowOverflow
[autoSize]                                               if autoMinSize || autoSize
[size({boundary, padding, apply})]                       if autoMaxSize || autoBoundaryMaxSize
```

**Where it lives.** Ordering and option marshalling are library code
(`Popper.ts:539-671`); the placement, flip and shift arithmetic is inside
`@floating-ui/dom`, which was not read at this revision.

**Degradation.** The placement vocabulary (side × alignment, physical) is
already integral and ports to cells unchanged. The absence of a
preferred-placement list is a real design lesson rather than a mere omission: a
single opposite-side flip cannot express "try `right-start`, then `left-start`,
then `bottom`", which is what a submenu needs. The portable idea for a
soft-keyboard inset is the one floating-vue already implements for `boundary` —
the boundary is an **input**, never discovered by the solver.

### 3. Collision and geometry engine

Wholly delegated. Floating-vue contributes exactly two things: middleware
selection/order (above) and the **update schedule** — and the schedule is the
interesting half. `autoUpdate` is never imported (see the import list,
`Popper.ts:2-11`); there is no `IntersectionObserver`, no `MutationObserver` and
no rAF polling loop anywhere in the package. Position is recomputed on exactly:

| Trigger                                                                                                                                                                   | Site                      |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------- |
| show                                                                                                                                                                      | `Popper.ts:729`           |
| a watched prop among `placement`, `distance`, `skidding`, `boundary`, `strategy`, `overflowPadding`, `arrowPadding`, `preventOverflow`, `shift`, `shiftCrossAxis`, `flip` | `Popper.ts:390-405`       |
| `container` change                                                                                                                                                        | `Popper.ts:376-381`       |
| `scroll` on any overflow ancestor of the reference **or** the popper (registered at show, torn down at hide)                                                              | `Popper.ts:733-740, 844`  |
| window `resize` → `recomputeAllPoppers` over the global list                                                                                                              | `Popper.ts:1062, 1145`    |
| content `ResizeObserver`, when `handleResize` is on                                                                                                                       | `PopperContent.vue:49-52` |
| explicit `onResize()`                                                                                                                                                     | public method             |

Read from that control flow: an anchor moved by a CSS transition, or displaced
by a layout shift with no scroll and no resize, is not tracked and the popper
detaches visually. Scroll handlers are passive but neither throttled nor
rAF-coalesced, so _N_ overflow ancestors × _M_ shown poppers each schedule a
full async `computePosition`. The applied position is integer-snapped at the
paint boundary by the consumer: `translate3d(${Math.round(result.x)}px, ${Math.round(result.y)}px, 0)`.

**Where it lives.** The schedule is library code; overflow-ancestor discovery,
clipping-rect computation and transform/zoom/DPR handling are all inside
`@floating-ui/dom`.

**Degradation.** Two halves generalize off the DOM, and they are precisely the
two halves floating-vue kept: a middleware **pipeline** (a reducer over
`{x, y, placement, rects, middlewareData}` with a `reset` verb that re-runs the
chain after a measurement side effect) and an **explicit recompute trigger
set**. Both suit a canvas toolkit: the pipeline is a pure function over integer
rects, and "recompute only on named events" is the right cost model when there
is no compositor to hide the work. The `Math.round` is validation that
fractional placement arithmetic with integral application is acceptable — but a
cell toolkit should round _inside_ the algorithm, not at paint, so that
hit-testing and pixels agree.

### 4. Arrow / caret geometry

Arrow geometry is data, and the arrow _element_ is an input to placement.
`$_arrowNode` is queried once in `init()` and handed to floating-ui's
`arrow({element, padding: arrowPadding})`, so its measured size participates in
the solve; the output `{x, y, centerOffset}` is merged into `result.arrow` and
written back as `left`/`top` pixels through a `toPx` helper that returns `null`
for `NaN`. Corner constraint is `arrowPadding`.

Hiding is a bespoke middleware, `arrowOverflow` (`Popper.ts:589-609`):

```ts
// packages/floating-vue/src/components/Popper.ts:595-600
if (placement.startsWith('top') || placement.startsWith('bottom')) {
  overflow = Math.abs(centerOffset) > rects.reference.width / 2;
} else {
  overflow = Math.abs(centerOffset) > rects.reference.height / 2;
}
```

The predicate means: the arrow can no longer sit anywhere over the anchor, so it
would point at nothing — drop it. `PopperContent.vue` turns that into the class
`v-popper__popper--arrow-overflow`, and CSS sets `display: none`.

Border-aware arrows involve no JavaScript at all: two absolutely positioned
zero-size bordered `div` elements, inner 7px and outer 6px, nudged 1–2px per
side, so the "border" is a slightly larger triangle painted behind the fill
(`style.css:50-162`). The [transform origin][concepts] is **not** derived from
the arrow — see dimension 14.

**Where it lives.** Predicate in library code (`Popper.ts:589-609`);
`centerOffset` in floating-ui's `arrow` middleware; visual construction entirely
in `style.css`.

**Degradation.** In whole cells the arrow is one glyph (`▲ ▼ ◀ ▶`, or a corner
character), `centerOffset` collapses to roughly `{-1, 0, +1}` cells, and the
`arrowOverflow` predicate survives verbatim: _if the clamped arrow cell falls
outside the anchor's cell span, emit no arrow_. The two-triangle border trick
has no cell analogue — in a TUI the arrow is one character and its "border" is
the same character in the border colour. On a script-free static-HTML tier with
no measurement, the arrow must be emitted at a fixed alignment and cannot be
hidden adaptively.

### 5. Trigger semantics

Five abstract triggers — `hover`, `focus`, `click`, `touch`, `pointer` — mapped
to DOM event names by two tables in `util/events.ts`: `SHOW_EVENT_MAP`
(`mouseenter`, `focus`, `click`, `touchstart`, `pointerdown`) and
`HIDE_EVENT_MAP` (`mouseleave`, `blur`, `click`, `touchend`, `pointerup`). The
mapping is applied **twice**: once against `$_targetNodes` with
`triggers`/`showTriggers`/`hideTriggers`, and once against `[$_popperNode]` with
`popperTriggers`/`popperShowTriggers`/`popperHideTriggers`. The overlay surface
is a first-class trigger surface, and that is what makes hoverable menus
possible at all.

Override resolution has two forms: an array **replaces** the inherited list, a
function **transforms** it —
`typeof customTrigger === 'function' ? customTrigger(triggers) : customTrigger`.

Race avoidance is event tagging, not state. `handleShow` stamps
`event.usedByTooltip = true`; `handleHide` returns immediately if the stamp is
present. Because both handlers sit on the same node for the same `click`, and
show is registered first, click-to-toggle falls out for free: when already
shown, `handleShow` returns _without_ stamping (`Popper.ts:890-892`), so
`handleHide` proceeds.

Not present: a focus-visible distinction, long-press, `contextmenu`, keyboard
shortcuts, or pointer-type discrimination beyond a global iOS user-agent branch.
`blur` does not bubble, so focus-hide fires only for the target node itself.

**Algorithm.** `$_registerTriggerListeners(nodes, eventMap, commonTriggers, customTrigger, handler)`
resolves the trigger list as above, then for each trigger adds `eventMap[trigger]`
as a passive listener. Every registration is recorded in `$_events` so
`$_removeEventListeners` can filter by event type — which is how only the
`scroll` listeners are dropped at hide.

**Where it lives.** Entirely library code: `util/events.ts` (the two maps),
`Popper.ts:886-912` (`$_addEventListeners`) and `:923-936`
(`$_registerTriggerListeners`).

**Degradation.** The abstract-trigger table is the most portable idea in this
subject and maps directly onto capability tiers ([`../../specs/ui/input.md`](../../specs/ui/input.md)):
a target simply omits rows it cannot serve. No hover ⇒ drop the `hover` row.
No key release ⇒ any trigger defined on a release edge must be redefined on the
press edge. The event-stamp trick, by contrast, requires a mutable event object
shared across handlers; in a value-semantics toolkit the equivalent is for the
dispatcher to carry a "consumed-by" token in the routing result — hit-testing
returns a claim, not a bool.

### 6. Timing

Delay is a scalar or `{show, hide}`, resolved by one line:

```ts
// packages/floating-vue/src/components/Popper.ts:714
return parseInt((delay && delay[type]) || delay || 0);
```

For the `menu` theme's `{show: 0, hide: 400}`, the show branch evaluates `0` →
falsy → `parseInt(object)` → `NaN`.

> [!NOTE]
> That `setTimeout(fn, NaN)` clamps to `0` is a specification-level claim about
> the host, not something executed in this environment. The reading is that the
> documented instant show is a coercion accident rather than a code path.

One timer slot, `$_scheduleTimer`, is shared by show and hide and cleared by
both, so the last scheduled transition wins and there is no "both pending"
state. [Warm-up][concepts]/skip-delay is the one-slot module-global
`hidingPopper` register: `$_scheduleHide` publishes `hidingPopper = this` when a
shown popper begins hiding, and the next popper's `$_scheduleShow` checks
`hidingPopper && this.instantMove && hidingPopper.instantMove && hidingPopper !== this.parentPopper`
before arming any delay — if so it force-completes the old hide and force-shows
itself, both with `skipTransition`. The register is neither theme-scoped nor
group-scoped, and a second concurrent hide overwrites it. The parent exclusion is
deliberate: hand-off must not fire between a menu and its own submenu.

`disposeTimeout` (default 150 ms) is an independent timer that detaches the DOM
node and unmounts the slot content — a memory [cool-down][concepts], orthogonal
to interaction. Its default has swung 5000 → 0 → 150 across commits, tuned in
the last move to match the CSS transition. There is no maximum display duration,
no re-entry grace beyond the hide delay, and no shared provider or singleton
timer: each popper owns its own.

**Algorithm.** The machine implied by the code (never written down in it):
per-popper states `{Hidden, ShowScheduled(t), Shown, HideScheduled(t), Detached}`,
one cancellable timer slot, guards `$_hideInProgress` (set at `scheduleHide`,
cleared at `scheduleShow`) and `$_showFrameLocked` (one frame after show), a
process-global last-hiding register consulted on entry to `ShowScheduled`, and a
per-popper detach timer from `Hidden` to `Detached`.

**Where it lives.** Library code: `$_computeDelay` (`:712-715`),
`$_scheduleShow` (`:673-689`), `$_scheduleHide` (`:691-710`), the dispose timer
in `$_applyHide` (`:832-842`), and the module-level `hidingPopper` (`:28`).

**Degradation.** This dimension is entirely timer-driven, so on a script-free
static-HTML target it vanishes wholesale: `:hover` gives instant show and instant
hide, no warm-up, no grace, and floating-vue offers no fallback. That is the
honest tier-0 answer. Everything else — one cancellable slot, a global
last-hidden register, separating "hidden" from "destroyed" — is assertable on a
recording canvas provided the clock is injectable, which is the design
requirement this subject argues for; see
[`../../specs/ui/state-machines.md`](../../specs/ui/state-machines.md).

### 7. Interactive hover

Three layered mechanisms, in increasing order of cleverness and decreasing order
of reliability.

1. **The overlay is a trigger.** `popperTriggers: ['hover']` on the `menu` theme
   means entering the content re-fires show and clears `pendingHide`.
2. **The gap is bridged by the hide delay alone** (menu: 400 ms). There is no
   pointer-bridge element and no [safe polygon][concepts].
3. **Menu-aim**, `$_isAimingPopper` (`Popper.ts:1020-1040`), a ray/segment
   intersection test gated on the _current_ cursor still being inside the
   reference rect — so it only runs at the instant of mouse-leave from the
   trigger.

The ray is cast from the _previous_ `mousemove` sample along the last motion
delta, scaled by a length that is a signed coordinate **sum**, not a distance:

```ts
// packages/floating-vue/src/components/Popper.ts:1026
const distance =
  popperBounds.left +
  popperBounds.width / 2 -
  mousePreviousX +
  (popperBounds.top + popperBounds.height / 2) -
  mousePreviousY;
```

For a popper up-and-left of the cursor this is negative and shortens or reverses
the extended ray. The ray is then tested against the popper's four edges by a
textbook parametric `uA`/`uB` test (`lineIntersectsLine`, `:1179-1183`) with no
parallel guard — a division by zero yields `NaN`, both comparisons are false,
and the result is reported as no-hit, which is benign.

On a hit, the hide is aborted and the child installs `parent.lockedChild = this`
plus a 1000 ms expiry timer that force-hides it. While that lock is set, every
_sibling_ child's `show()` returns at its first line with no event emitted:

```ts
// packages/floating-vue/src/components/Popper.ts:436
if (this.parentPopper?.lockedChild && this.parentPopper.lockedChild !== this)
  return;
```

The lock is released early when the aimed popper actually shows (`:440-442`).
Mouse sampling is a module-level passive `mousemove` listener holding the
current and one previous sample (`:1161-1177`).

**Where it lives.** Entirely library code in `Popper.ts`.

**Degradation.** Costed in whole cells the geometry collapses: the four segment
intersections become a quadrant test — does the popper's cell rect lie in the
quadrant of the last cell-to-cell motion, `sign(dx)` × `sign(dy)`? — four
integer comparisons, no division, no `NaN`; a Bresenham walk from the cursor
cell along `(dx, dy)` is at most `rows + cols` cells and is the exact version.
The load-bearing degradation finding is different, though: **the heuristic
self-disables without a continuous motion stream.** With enter/leave-only
reporting, touch, or no script, `mouseX` stays at its initial value, the
inside-reference gate never passes, aiming never fires, and the system falls
back to the 400 ms hide delay. That fallback is accidental but it is the right
shape — menu-aim must be an optional refinement layered over a timing bridge,
never the only bridge. The sibling-exclusion lock is a warning rather than a
model: it silently swallows a legitimate show for up to a second, and returns
before emitting `update:shown`, so a controlled component desynchronises.

### 8. Dismissal

Outside dismissal ([light dismiss][concepts]) is a single global two-phase
capture pair installed at module load: `mousedown` + `click` on `window`
(capture), or `touchstart` + `touchend` on `document` (capture, passive) when
`isIOS`. Phase one records only `popper.mouseDownContains` for every shown
popper. Phase two runs the close with the two hits OR-ed together:

```ts
// packages/floating-vue/src/components/Popper.ts:1093
const contains = (popper.containsGlobalTarget =
  popper.mouseDownContains || popper.popperNode().contains(event.target));
```

That OR is why a drag that begins inside a popover and releases outside — text
selection — does not dismiss it. Closing on `mousedown` shipped in 5.1.0, broke
exactly that, and was reverted behind `config.autoHideOnMousedown`.

The close loop iterates `shownPoppers` in **reverse** (topmost first), captures
`contains` per popper, then defers the decision by one `requestAnimationFrame`
so the `v-close-popper` directive's own listeners have time to stamp
`event.closePopover` / `event.closeAllPopover` onto the shared event object. The
predicate is:

```text
closeAllPopover || (closePopover && contains) || (autoHide && !contains)
```

where `autoHide` may itself be a _function_ of the event, whose result is cached
to `lastAutoHide` for the slot data. After a popper closes, the ancestor chain is
walked upward, closing each while the predicate holds and **breaking at the first
refusal**; but for a scoped close (`closePopover && contains`) every ancestor is
instead marked in a `preventClose` map keyed by `randomId`, so only the child
closes. `$_showFrameLocked` exempts anything opened during the current frame.

Escape is `@keyup.esc` bound on the popper root — only when `autoHide` is true,
only when focus is inside the popper, and on key **up**. There is no global key
handler, so a tooltip can never be dismissed by keyboard.

Also handled: `keep-alive` `deactivated()` hides, `beforeUnmount` disposes, the
`disabled` watcher disposes. Not handled: scroll-away, an anchor removed or
clipped out of view (there is no `IntersectionObserver`), navigation, or window
blur. Window resize only repositions.

**Algorithm.**

```text
handleGlobalClose(event):
  preventClose = {}
  for i = shownPoppers.length-1 downto 0:
    popper = shownPoppers[i]
    contains = popper.mouseDownContains || popper.node.contains(event.target)
    rAF(():
      if preventClose[popper.randomId]: return
      if shouldAutoHide(popper, contains, event):
        popper.$_handleGlobalClose(event)
        if !event.closeAllPopover and event.closePopover and contains:
          mark every ancestor in preventClose; return
        for p = popper.parent; p; p = p.parent:
          if !shouldAutoHide(p, p.containsGlobalTarget, event): break
          p.$_handleGlobalClose(event))
```

**Where it lives.** Library code at module scope: listener install
(`:1048-1063`), `handleGlobalPointerDown`/`Up` (`:1065-1085`),
`handleGlobalClose` (`:1087-1130`), `shouldAutoHide` (`:1132-1134`), per-popper
`$_handleGlobalClose` (`:958-975`); Escape in `PopperContent.vue:28`; event
stamping in `directives/v-close-popper.ts:21-49`.

**Degradation.** With no OS window and no pointer [grab][concepts], the whole
pointer-down/pointer-up pairing has to be reconstructed on the surface's own
event stream — which is fine, because floating-vue's version is already pure
application logic over a flat list plus a parent chain, not a platform grab. Two
pieces are directly reusable: the pointer-down-contains memory (a drag out of an
overlay is not a dismissal) and the reverse-order iteration plus ancestor
cascade with an early break. The rAF defer exists only so a directive can
retro-annotate a mutable event; a toolkit whose router returns a claim does not
need it. With no key release, `keyup.esc` must become a press-edge binding. An
Android back key would have to be wired to the same cascade entry point;
floating-vue has no equivalent.

### 9. Focus

Deliberately almost absent — and the code shows why that is untenable.
`$_applyShowEffect` ends with `if (!this.noAutoFocus) this.$_popperNode.focus()`.
But the popper root carries `tabindex="0"` only when `autoHide` is true, so for
tooltips the `focus()` call is a no-op and focus stays on the trigger, while for
dropdowns focus **moves** to the popper container. There is no focus trap, no
containment, no restoration on close, no tab-order management, no roving
tabindex, no nested [focus scope][concepts], and no pointer-versus-keyboard-opened
distinction. `focus`/`blur` are simply two more rows in the trigger tables.

The negative result is pinned by the repository's own history: the `menu` theme
originally carried `popperTriggers: ['hover', 'focus']` and had to drop `focus`
(commit `74b940f`, "don't close on popper blur"), leaving `config.ts:71-79` as
it reads at this revision. Auto-focusing the surface and treating focus loss as
a hide trigger are mutually hostile unless the two are reconciled explicitly.

**Algorithm.** There is none. The complete rule is: `tabindex = autoHide ? 0 : undefined`;
on show, `popperNode.focus()` unless `noAutoFocus`; on hide, nothing.

**Where it lives.** `Popper.ts:792` (the focus call), `PopperContent.vue:26`
(`tabindex`), `config.ts:71-79` (the `menu` theme after `74b940f`).

**Degradation.** A single parameterized overlay that ignores focus produces an
a11y-unusable menu, and a tooltip that steals focus if the wrong prop is set.
For a canvas toolkit the argument is that focus policy — none / move-in /
contain / trap-and-restore — must be an explicit enum on the overlay _kind_,
decided above the shared geometry primitive, and that "focus lost" as a
dismissal cause must be defined relative to the overlay's own subtree rather
than a single node. On TUI and recording targets focus is a toolkit-owned
integer, so all four policies are assertable there.

### 10. Layering and portals

The dimension where this subject bears most directly on a single-surface
toolkit. `$_ensureTeleport` resolves `container` (a string via `querySelector`;
`false` meaning the first target node's `parentNode`; an element as itself;
unresolved ⇒ throw) and calls `container.appendChild(this.$_popperNode)` on
**every** show. Since `appendChild` moves an existing node, re-showing brings the
popper to the end of the container's children. Every popper shares one flat
`z-index: 10000` (`style.css:3-8`). Stacking among poppers is therefore purely
append order == show order: later in the list paints in front, with no z-index
escalation, no [top layer][concepts], no `dialog`/`popover` platform API and no
stacking-context management.

On hide, after `disposeTimeout`, the node is removed from the DOM entirely and
`isMounted` flips false, unmounting the slot content — so the paint tree only
ever contains live overlays.

Ownership is a completely separate tree: `provide({[PROVIDE_KEY]: {parentPopper: this}})`
and a matching `inject` give a `parentPopper` computed that works _across the
teleport_, so a submenu rendered into `body` still injects from its logical
parent. Ownership tree and paint parenting are fully decoupled.

Three module-level registries exist:

| Registry              | Shape                       | Consumers                                                                    |
| --------------------- | --------------------------- | ---------------------------------------------------------------------------- |
| `shownPoppers`        | ordered array               | the close cascade, `showGroup`, `recomputeAllPoppers`, `hideAllPoppers`      |
| `hidingPopper`        | one slot                    | the `instantMove` hand-off                                                   |
| `shownPoppersByTheme` | `theme -> array`, per theme | maintained but never read as a list; only its length drives a body CSS class |

`shownPoppersByTheme` is effectively a per-theme reference count exposed to CSS
as `v-popper--some-open--<theme>`; whether anything outside this package reads
the lists was not determined.

**Where it lives.** Library code: `$_ensureTeleport` (`:866-884`),
`$_detachPopperNode` (`:977-979`), `provide`/`inject` (`:50-64`, `:356-358`),
registries (`:27-37`); flat `z-index` in `style.css:3`.

**Degradation.** This subject reads as a natural experiment in a single-surface
constraint that it was not forced into: it has a top layer available and does not
use it. One container, one z value, order == front-to-back. The transferable
lesson is that the _pair_ — an ordered shown-list for stacking, a separate parent
chain for ownership — is sufficient, and is what makes the close cascade, the
`pendingHide` refcount and "bring to front on re-show" each a one-liner. Also
worth carrying over: the popper's tree node survives while its _paint_ node is
detached, so hidden, mounted-but-detached and destroyed are three distinct
states. Compare [`../../specs/ui/containers.md`](../../specs/ui/containers.md)
for where such a registry would sit in `sparkles:ui`.

### 11. Modality

Not applicable — and the absence is itself the finding. There is no scrim, no
`inert`, no `aria-modal`, no background pointer or keyboard blocking, and no
[light dismiss][concepts] primitive distinct from the global outside-click
cascade.

A `.v-popper__backdrop` div exists in every popper (`PopperContent.vue:30-33`),
but `style.css:28-35` sets it `display: none` and — critically — positions it
`absolute; width: 100%; height: 100%` **inside** the popper, so even when a theme
enables it, it covers the popper rather than the page. Its only job is to give
`autoHide && $emit('hide')` a click target for CSS-driven full-screen
presentations (the `positioningDisabled` mobile-sheet pattern of dimension 12).

The one pointer-layering rule that does exist is worth naming: hidden poppers get
`pointer-events: none` while they fade (`style.css:10-15`), so a dismissed popper
cannot intercept clicks during its 150 ms transition.

**Where it lives.** Nowhere, in the sense that no modality machinery exists. The
nearest artefacts are `PopperContent.vue:30-33` and `style.css:28-35`, inert by
default.

**Degradation.** With one surface and no compositor, [modality][concepts] cannot
be a platform bit; it has to be an explicit predicate applied during hit-test
routing (events at cells outside the modal overlay's rect are consumed rather
than routed) plus a scrim entry in the display list. The
`pointer-events: none`-while-fading rule is worth copying literally: an overlay
animating out must leave the hit list before it leaves the paint list, or the
last painted frame keeps eating clicks.

### 12. Adaptive presentation

Exactly one lever, and the decision belongs entirely to the application.
`positioningDisabled` short-circuits `$_computePosition` on its first line:

```ts
// packages/floating-vue/src/components/Popper.ts:539-540
async $_computePosition () {
  if (this.isDisposed || this.positioningDisabled) return
```

`result` then stays `null`; `slotData` passes `result: null` down; and
`PopperContent` renders with no transform, no `data-popper-placement`, and the
class `v-popper__popper--no-positioning`, which CSS uses to hide the arrow. The
application then styles a fixed bottom sheet in plain CSS. The documented
example is `:positioning-disabled="isMobile"`, with the breakpoint computed by
the app ([`docs/guide/component.md`][docs-component]).

Touch adaptation is minimal: the `tooltip` theme includes a `touch` trigger
(`touchstart`/`touchend`), the global outside-close listeners take an iOS
branch, and after a touch-driven close a 300 ms `$_preventShow` window keeps the
same tap from reopening what it just closed. There is no
long-press-instead-of-hover, no teaching tips, no keyboard-driven relocation and
no compact-size-class notion.

**Where it lives.** Library code provides the null-result escape hatch
(`Popper.ts:540`, `slotData` at `:351`, `PopperContent.vue:18-27`); the _when_
lives in application code and CSS.

**Degradation.** The mechanism generalizes cleanly to a canvas toolkit: make
"placement produced no result" a representable value and let a presentation
layer substitute a docked or sheet layout. That is the honest answer to a
soft-keyboard inset — an anchored popup that cannot fit above the keyboard
should not be shifted, it should switch _presentation_, and that switch is a
policy input rather than a geometry outcome. Floating-vue demonstrates that the
seam can be one nullable field. See
[`../platform-ui-guidelines/index.md`](../platform-ui-guidelines/index.md) for
the platform expectations such a substitution has to satisfy.

### 13. Accessibility

Thin, and in places incorrect. While shown, every target node gains
`aria-describedby=<popperId>` and `data-popper-shown`; both are removed on hide.
No `role` is ever emitted — there is no `role=` anywhere in the package: not
`tooltip`, not `menu`, not `listbox`, not `dialog`. `aria-describedby` is applied
uniformly, including for dropdowns and menus, where description semantics are
wrong.

The popper carries `aria-hidden`, widened at the pinned revision (`#1067`) from
`shown ? 'false' : 'true'` to `shown || autoHide ? 'false' : 'true'` — because
the same element receives `tabindex="0"` when `autoHide` is set, and a focusable
element inside an `aria-hidden` subtree is an AT violation.

One nice detail: each target's native `title` attribute is swapped to
`data-original-title` at `init` and swapped back at `dispose`, preventing a
duplicate browser tooltip and preventing permanent loss of the attribute.

Against WCAG 1.4.13: _hoverable_ holds only for themes whose `popperTriggers`
include `hover` (the `menu` theme); the default `tooltip` theme inherits the root
`popperTriggers: []` (`config.ts:19`) and is therefore not hoverable.
_Dismissible_ does not hold for tooltips at all, since the Escape handler is
gated on `autoHide`. Nothing prevents interactive content inside a
tooltip-themed popper.

**Algorithm.** On apply-show, for each target node set
`{aria-describedby: popperId, data-popper-shown: ''}`; on apply-hide, remove
both. `popperId = ariaId ?? randomId`, where `randomId` is
`` `popper_${base36(Math.random())}_${base36(Date.now())}` ``.

**Where it lives.** Library code only: `$_applyAttrsToTarget` (`:991-1002`,
called at `:758` and `:827`), `$_swapTargetAttrs` (`:981-989`), and
`aria-hidden`/`tabindex` in `PopperContent.vue:25-26`. No accessibility-API
integration exists.

**Degradation.** A cell canvas has no accessibility tree at all, so this
dimension is entirely a toolkit's to invent — and floating-vue's failure mode is
the instructive part: one shared primitive emitting one ARIA relationship for
every overlay kind produces wrong semantics for most of them. What belongs _in_
the primitive is only an id, the describedby/labelledby relation direction, and
the shown/hidden bit; role, focus policy, interactivity permission and
dismissibility guarantees belong to the semantic component above it. See
[`./aria-apg.md`](./aria-apg.md) for the normative contracts this package does
not meet.

### 14. Animation

The library deliberately publishes geometry metadata so a styling layer can
animate, through three channels.

1. **`data-popper-placement`** on the popper root carries the _resolved_ side and
   alignment (post-flip) — the CSS hook for directional enter animations and for
   every arrow side rule.
2. **`computeTransformOrigin`** expresses the reference centre in the popper
   wrapper's own coordinate space and stores it as a `"Xpx Ypx"` string in
   `result.transformOrigin`, applied to `.v-popper__wrapper`, so a scale
   animation grows out of the trigger:

   ```text
   originX = (refBounds.x + refBounds.width/2)  - (wrapperParentRect.left + wrapper.offsetLeft)
   originY = (refBounds.y + refBounds.height/2) - (wrapperParentRect.top  + wrapper.offsetTop)
   ```

3. **A manual four-class enter/exit protocol** — `showFrom → showTo` and
   `hideFrom → hideTo`, flipped across a double `requestAnimationFrame`
   (`nextFrame`, `util/frame.ts:1-5`) rather than using Vue's own transition
   component — plus `skipTransition`, which adds a
   `transition: none !important` class for the `instantMove` hand-off.

> [!NOTE]
> `transformOrigin` is computed inside `$_applyShowEffect` and, as far as the
> control flow shows, is never recomputed by `$_computePosition`. This suggests a
> scroll-driven flip after show leaves a stale origin — an inference from the
> call graph, not an observed defect.

There is no reduced-motion handling anywhere in the package, and the arrow is
never animated.

**Where it lives.** Library code: transform origin (`:747-753`), class flipping
(`:784-792`, `:848-855`), `nextFrame` (`util/frame.ts`); the transitions
themselves are entirely author CSS.

**Degradation.** Two ideas port. First, **emit the resolved placement as data**:
a display list should carry the resolved side and alignment on the overlay node,
so a painter can pick corner glyphs, shadow direction and reveal direction
without recomputing anything — see
[`../../specs/ui/backends.md`](../../specs/ui/backends.md). Second, an
anchor-relative origin point remains meaningful in cells (which cell the popup
grows from), and a cell-grid reveal can animate as a row or column wipe from
that cell. On TUI and recording targets the class protocol degrades to a frame
counter, which is exactly what makes it assertable; the double-rAF trick is a
DOM-reflow workaround with no analogue.

### 15. State architecture

An ad-hoc imperative controller — not a reducer, not a statechart. State is split
by **reactivity intent**, which is itself a design decision worth naming:
reactive `data` holds what the view must re-render on (`isShown`, `isMounted`,
`skipTransition`, four transition-class booleans, `result`, `shownChildren` as a
`Set`, `lastAutoHide`, `pendingHide`, `containsGlobalTarget`, `isDisposed`,
`mouseDownContains`, `randomId`), while `$_`-prefixed non-reactive instance
fields hold the machinery (`$_scheduleTimer`, `$_disposeTimer`,
`$_hideInProgress`, `$_showFrameLocked`, `$_preventShow`, `$_events`,
`$_referenceNode`, `$_targetNodes`, `$_popperNode`, `$_innerNode`,
`$_arrowNode`).

`lockedChild` and `lockedChildTimer` are declared nowhere: a child creates them
ad hoc on its parent instance (`:466-470`).

The component is controlled and uncontrolled simultaneously — a `shown` prop is
watched into `$_autoShowHide` while `update:shown` is emitted on every show and
hide. There is no state enum; "what state am I in" is a conjunction of four
booleans and two timer handles, which is why guards like
`if (this.$_hideInProgress) return` sit at the top of `hide()`, and why a
hide-during-hide — including `dispose()`'s own `hide({skipDelay: true})` — is
silently dropped.

**Algorithm.** The nearest thing to a formalism is the guard set: `show()` is
blocked by `parent.lockedChild`; `hide()` by `$_hideInProgress`, by a non-empty
`shownChildren`, and by the aim test; `$_applyShow` by `isShown`;
`$_applyShowEffect` by `$_hideInProgress`; `$_applyHide` by `!isShown` and by a
non-empty `shownChildren`; the global close by `$_showFrameLocked` and
`$_preventShow`.

**Where it lives.** Library code: one Vue Options-API component
(`Popper.ts:294-1041`) plus three module-level globals.

**Degradation.** Would it survive a value-semantics, allocation-conscious
toolkit? Partly, and the split is clean. Portable: `result` (a pure POD of
`x`/`y`/`placement`/`arrow`/`strategy`), the theme cascade (a pure function of
two strings), the trigger-to-event mapping tables, the `shouldAutoHide`
predicate, and the guard set above — which is a hidden finite-state machine
asking to be written down. Not portable: object identity used as semantics
throughout (`hidingPopper === this.parentPopper`,
`removeFromArray(shownPoppers, this)`, `lockedChild !== this`), a child mutating
fields it invents on its parent, and an event object used as a mutable IPC
channel. All three become ids into an arena in a toolkit like `sparkles:ui`:
overlay handles are integers, the parent chain is an index, and "consumed" is a
return value rather than a stamp on a shared object.

### 16. Shared infrastructure

An unusually literal "one primitive, many products" factoring. `Tooltip.ts`,
`Dropdown.ts` and `Menu.ts` are nine lines each. Everything that distinguishes a
tooltip from a dropdown from a submenu is data in `config.themes`:

| Theme      | Distinguishing data (`config.ts:38-80`)                                                                                                                                                |
| ---------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `tooltip`  | `placement: 'top'`, `triggers: ['hover','focus','touch']`, `hideTriggers: e => [...e, 'click']`, `delay: {show: 200, hide: 0}`, `handleResize: false`, `html: false`, `loadingContent` |
| `dropdown` | `placement: 'bottom'`, `triggers: ['click']`, `delay: 0`, `handleResize: true`, `autoHide: true`                                                                                       |
| `menu`     | `$extend: 'dropdown'`, `triggers: ['hover','focus']`, `popperTriggers: ['hover']`, `delay: {show: 0, hide: 400}`                                                                       |

Resolution is **per-key inheritance**, not an object merge: `getDefaultConfig`
walks the `$extend` chain looking for the first theme that defines _that key_,
falling through to the flat root config. Every prop's default is wired to that
walk by a factory —

```ts
// packages/floating-vue/src/components/Popper.ts:44-48
function defaultPropFactory(prop: string) {
  return function (props) {
    return getDefaultConfig(props.theme, prop);
  };
}
```

— which is precisely why every prop on `PopperWrapper` defaults to `undefined`:
the cascade must be able to distinguish "unset" from "set to `false`". Two
parallel chain walks serve CSS: `getThemeClasses` (honours `$resetCss`, produces
the `v-popper--theme-*` class list) and `getAllParentThemes` (ignores
`$resetCss`, maintains the per-theme open counts that drive body classes).

What looks common but had to stay apart, by this repository's own scars:

- **Focus policy** — the `menu` theme had to drop `focus` from `popperTriggers`
  (commit `74b940f`).
- **Escape and `tabindex`** — both gated on `autoHide`, so tooltips get neither.
- **Content semantics** — the directive path needed an entirely separate
  173-line component, `TooltipDirective.vue`, layering async content, a loading
  placeholder, HTML-versus-text rendering, a monotonic fetch-id guard against
  out-of-order resolution, and a re-measure after the content changes. It shares
  `Popper` but not `PopperWrapper`.

Select, combobox, date picker, colour picker, teaching tip and toast do not exist
here at all — the shared core stops before anything with an internal selection
model.

**Algorithm.**

```text
getDefaultConfig(theme, key):
    t = config.themes[theme] || {}
    do:
        v = t[key]
        if v === undefined:
            t = t.$extend ? config.themes[t.$extend] : null
            if !t: v = config[key]
        else:
            t = null
    while t
    return v
```

**Where it lives.** Library code: `config.ts:39-138` (the data plus three chain
walks), `Popper.ts:44-48` (`defaultPropFactory`), the three nine-line component
files, `PopperWrapper.vue` (the prop surface, all defaults `undefined`), and
`TooltipDirective.vue` (the content layer that could not be shared).

**Degradation.** This is the most directly adoptable piece of the subject,
because it is pure data and pure functions: a per-key inheritance walk over a
theme table, with each widget kind being a name plus a theme string. It is
trivially `@safe`, allocation-free if the table is a compile-time associative
array of static strings, and fully assertable on a recording canvas — no OS
window, no hover, no script, no sub-cell precision and no key release enter into
it at all. The boundary it draws is the other half of the value: one anchored
overlay owns anchor, placement, trigger mapping, timing, dismissal and stacking;
separate components own the content model, focus policy, keyboard semantics and
selection. See [`../../specs/ui/widgets.md`](../../specs/ui/widgets.md) and
[`./proposal.md`](./proposal.md).

## Strengths

- The theme cascade (`config.ts:86-138` plus `defaultPropFactory`) makes "one
  overlay, many kinds" a table lookup: nine-line component files, per-key
  inheritance, every default resolved through pure functions of two strings.
- Overlay ownership (the `provide`/`inject` parent chain) is fully decoupled from
  paint parenting (append order in one container) — an ordered list for
  stacking, a tree for close ordering.
- The transitive shown-descendant refcount plus `pendingHide` gives "hide all
  children first" with no traversal at hide time, in a handful of integers.
- An abstract trigger vocabulary — `{hover, focus, click, touch, pointer}` —
  mapped through two tables, applied separately to the trigger set and to the
  overlay surface, with function-valued overrides that compose rather than
  replace.
- Placement failure is a **representable value**: `positioningDisabled` makes
  `result` null, which the view layer reads as "present this some other way".
  That one nullable field is the whole adaptive-presentation seam.
- Geometry metadata is deliberately published for the styling layer: resolved
  placement as an attribute, arrow `x`/`y`/`centerOffset`/`overflow` as data, and
  an anchor-relative transform origin.
- The pointer-down-contains memory (a drag out of an overlay is not a dismissal)
  and the one-frame show lock are exactly the edge cases a naive reimplementation
  gets wrong.
- The two-pass `autoSize` middleware with a `skip` guard solves "popup width
  follows anchor" correctly, including un-clamping `maxWidth`/`maxHeight` before
  re-measuring.
- Stealing the native `title` attribute into `data-original-title` at `init` and
  restoring it at `dispose` — a small, easily forgotten correctness detail.

## Weaknesses

- Effectively untested: one spec file covering `getPlacement` (three cases), and
  a Cypress spec that is the unmodified vue-cli template. None of the cascade,
  tree ordering, aim, timing or dismissal logic is covered.
- No ARIA roles at all, and `aria-describedby` is applied uniformly — including
  to dropdowns and menus, where description semantics are wrong.
- Escape exists only as `@keyup.esc` on the popper root, gated on `autoHide` and
  on focus being inside the popper; there is no global handler, so tooltips
  cannot be dismissed by keyboard. WCAG 1.4.13 _dismissible_ fails for the
  default tooltip theme, which is also not hoverable (the root
  `popperTriggers` default is `[]`).
- No focus management whatsoever: no trap, no containment, no restoration.
- No continuous position tracking (`autoUpdate` is never imported) and no
  `IntersectionObserver`: a popper whose anchor animates, or is scrolled out of a
  clipping container, stays where it was.
- The menu-aim ray length is a signed coordinate sum rather than a distance
  (`Popper.ts:1026`); for a popper up-and-left of the cursor it can be negative
  and reverse the ray. The user-visible consequence was not reproduced.
- The aim lock blocks every sibling's `show()` for up to 1000 ms and returns
  before emitting `update:shown`, silently desynchronising a controlled
  component.
- Delay resolution leans on coercion: `{show: 0}` takes the falsy branch and ends
  at `parseInt(object)`.
- `boundary` is honoured by `shift`, `flip` and `size` but not by
  `autoPlacement`, so `placement="auto"` silently ignores a custom boundary.
- No preferred-placement list, so flip is opposite-side-only — insufficient for
  submenus.
- No cursor, point or [virtual anchor][concepts] of any kind, so a context menu
  at the pointer is not expressible.
- Documentation drift at this revision: `docs/guide/config.md` still shows
  `disposeTimeout: 5000` (source: `150`) and `menu` `popperTriggers: ['hover','focus']`
  (source: `['hover']` since `74b940f`).
- `lockedChild` / `lockedChildTimer` are never declared; a child creates them on
  its parent instance at runtime.
- Scroll-driven recomputation is neither throttled nor coalesced across ancestors
  and poppers.

## Key design decisions and trade-offs

| Decision                                                                                                                                                                     | Rationale                                                                                                                                                                                                                               | Trade-off                                                                                                                                                                                                                                                                                                                               |
| ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| One popper implementation, differentiated only by a data table of theme defaults resolved per key through a `$extend` chain                                                  | Tooltip, dropdown and menu are genuinely the same machine with different timing, triggers and placement; making them classes would duplicate the hard parts (dismissal cascade, tree ordering, timers) three times.                     | Everything the kinds should _not_ share leaks anyway: menus get `aria-describedby`, tooltips get no Escape, and the `menu` theme had to drop `focus` from `popperTriggers` (`74b940f`) because auto-focus and focus-as-hide-trigger fight. Focus policy, role and dismissibility guarantees cannot be theme data.                       |
| No top layer, no z-index escalation: one container, one flat `z-index`, and `appendChild` on every show so DOM order == show order == paint order                            | Stacking then needs no bookkeeping: "bring to front" is a re-append and "topmost first" is a reverse iteration.                                                                                                                         | The popper is at the mercy of the container's own stacking context, and `container` becomes a mandatory escape hatch that can throw at show time. Overlay ownership must then be tracked in a completely separate structure — which floating-vue does via `provide`/`inject`, and which turns out to be the right answer.               |
| No continuous position tracking: `autoUpdate` is never imported; recompute only on show, watched props, ancestor scroll, window resize and (opt-in) content resize           | An always-on observer or rAF loop per open overlay is expensive, and the enumerated triggers cover most real movement.                                                                                                                  | An anchor moved by a CSS animation, or displaced by a layout shift with no scroll and no resize, silently detaches the popper; with no `IntersectionObserver`, an anchor scrolled out of a clipping container keeps its popper visible. Scroll handlers are un-coalesced: N ancestors × M poppers each schedule a full async recompute. |
| Dismissal decided on pointer **up**, with the pointer-down hit test remembered and OR-ed in                                                                                  | Closing on `mousedown` (shipped in 5.1.0) broke drag-selecting text inside a popover and was reverted behind `config.autoHideOnMousedown`.                                                                                              | Two global capture listeners plus a per-popper `mouseDownContains` field refreshed only on the next press, so a popper opened after a press carries a stale value; and the decision must be deferred one frame so `v-close-popper` can retro-annotate the event, which is what makes the whole `$_showFrameLocked` mechanism necessary. |
| Menu-aim implemented as a lock on the **parent** that excludes all sibling children, expiring after 1000 ms                                                                  | It is the smallest change that fixes the diagonal-submenu problem without a safe-polygon overlay element or continuous hit-testing.                                                                                                     | A user who aims at a submenu and changes their mind cannot open a sibling for up to a second: `show()` returns at its first line without even emitting `update:shown`. The ray-length scalar is a signed coordinate sum rather than a distance, so the ray can point backwards for poppers up-and-left of the cursor.                   |
| Separate "hidden" from "unmounted": keep the instance and DOM node alive for `disposeTimeout` (150 ms, tuned to the CSS transition) then detach and unmount the slot content | Detaching immediately kills the exit transition; never detaching leaks DOM and keeps slot components mounted forever. The default swung 5000 → 0 → 150 across three commits, which is itself evidence that the trade is genuinely hard. | Three live states (shown, hidden-but-mounted, detached) that every guard must account for, plus a window in which a hidden popper still has trigger listeners attached to a node that is no longer in the document.                                                                                                                     |

## Sources

Primary sources, all at [`19857764c4f73dea7ed44a7d970adb968ee7ad90`][repo-sha]:

- [`packages/floating-vue/src/components/Popper.ts`][popper] — the whole
  machine: `init`/`dispose`, `$_computePosition` and the middleware assembly,
  `$_scheduleShow`/`$_scheduleHide`, `$_ensureTeleport`, `$_isAimingPopper`,
  `$_updateParentShownChildren`, the module-level registries and the global
  dismissal listeners.
- [`packages/floating-vue/src/components/PopperWrapper.vue`][popper-wrapper] —
  the public prop surface (all defaults `undefined`) and `getTargetNodes`.
- [`packages/floating-vue/src/components/PopperContent.vue`][popper-content] —
  the view: `translate3d` with `Math.round`, arrow placement, `aria-hidden`,
  `tabindex`, `data-popper-placement`, the backdrop element, `keyup.esc`.
- [`packages/floating-vue/src/components/Tooltip.ts`][tooltip] and
  [`Menu.ts`][menu] — the nine-line kind definitions.
- [`packages/floating-vue/src/components/TooltipDirective.vue`][tooltip-directive]
  — the content layer that could not be shared: async content, loading
  placeholder, fetch-id guard, re-measure.
- [`packages/floating-vue/src/config.ts`][config] — the root config, the
  three-theme table, `getDefaultConfig`, `getThemeClasses`,
  `getAllParentThemes`.
- [`packages/floating-vue/src/util/events.ts`][events] — `SHOW_EVENT_MAP` /
  `HIDE_EVENT_MAP`.
- [`packages/floating-vue/src/util/popper.ts`][util-popper] — the 15 placement
  strings.
- [`packages/floating-vue/src/util/frame.ts`][frame] — `nextFrame`, the double
  `requestAnimationFrame`.
- [`packages/floating-vue/src/directives/v-tooltip.ts`][v-tooltip] and
  [`v-close-popper.ts`][v-close-popper] — the directive path and the event
  stamping the dismissal cascade waits a frame for.
- [`packages/floating-vue/src/style.css`][style] — flat `z-index: 10000`,
  `pointer-events: none` while fading, the two-triangle arrow, the inert
  backdrop.
- [`docs/guide/component.md`][docs-component] — the `positioning-disabled`
  mobile-sheet example and the one-second aim expiry.

Related pages in this catalog: [`./index.md`](./index.md),
[`./concepts.md`](./concepts.md), [`./comparison.md`](./comparison.md),
[`./features-people-forget.md`](./features-people-forget.md),
[`./sparkles-baseline.md`](./sparkles-baseline.md),
[`./proposal.md`](./proposal.md). Nearest neighbours by mechanism:
[`./floating-ui.md`](./floating-ui.md) (the geometry engine this subject
delegates to), [`./tippy.md`](./tippy.md) (an imperative controller over the
same lineage), [`./radix.md`](./radix.md) and
[`./angular-cdk.md`](./angular-cdk.md) (the overlay-manager comparison).
Adjacent research trees: [`../ui-layout/index.md`](../ui-layout/index.md),
[`../window-system-integration/index.md`](../window-system-integration/index.md),
[`../platform-ui-guidelines/index.md`](../platform-ui-guidelines/index.md),
[`../sean-parent/index.md`](../sean-parent/index.md).

<!-- References -->

[repo]: https://github.com/Akryum/floating-vue
[repo-sha]: https://github.com/Akryum/floating-vue/tree/19857764c4f73dea7ed44a7d970adb968ee7ad90
[popper]: https://github.com/Akryum/floating-vue/blob/19857764c4f73dea7ed44a7d970adb968ee7ad90/packages/floating-vue/src/components/Popper.ts
[popper-882]: https://github.com/Akryum/floating-vue/blob/19857764c4f73dea7ed44a7d970adb968ee7ad90/packages/floating-vue/src/components/Popper.ts#L882
[popper-wrapper]: https://github.com/Akryum/floating-vue/blob/19857764c4f73dea7ed44a7d970adb968ee7ad90/packages/floating-vue/src/components/PopperWrapper.vue
[popper-content]: https://github.com/Akryum/floating-vue/blob/19857764c4f73dea7ed44a7d970adb968ee7ad90/packages/floating-vue/src/components/PopperContent.vue
[tooltip]: https://github.com/Akryum/floating-vue/blob/19857764c4f73dea7ed44a7d970adb968ee7ad90/packages/floating-vue/src/components/Tooltip.ts
[menu]: https://github.com/Akryum/floating-vue/blob/19857764c4f73dea7ed44a7d970adb968ee7ad90/packages/floating-vue/src/components/Menu.ts
[tooltip-directive]: https://github.com/Akryum/floating-vue/blob/19857764c4f73dea7ed44a7d970adb968ee7ad90/packages/floating-vue/src/components/TooltipDirective.vue
[config]: https://github.com/Akryum/floating-vue/blob/19857764c4f73dea7ed44a7d970adb968ee7ad90/packages/floating-vue/src/config.ts
[config-46]: https://github.com/Akryum/floating-vue/blob/19857764c4f73dea7ed44a7d970adb968ee7ad90/packages/floating-vue/src/config.ts#L46
[events]: https://github.com/Akryum/floating-vue/blob/19857764c4f73dea7ed44a7d970adb968ee7ad90/packages/floating-vue/src/util/events.ts
[util-popper]: https://github.com/Akryum/floating-vue/blob/19857764c4f73dea7ed44a7d970adb968ee7ad90/packages/floating-vue/src/util/popper.ts
[frame]: https://github.com/Akryum/floating-vue/blob/19857764c4f73dea7ed44a7d970adb968ee7ad90/packages/floating-vue/src/util/frame.ts
[v-tooltip]: https://github.com/Akryum/floating-vue/blob/19857764c4f73dea7ed44a7d970adb968ee7ad90/packages/floating-vue/src/directives/v-tooltip.ts
[v-close-popper]: https://github.com/Akryum/floating-vue/blob/19857764c4f73dea7ed44a7d970adb968ee7ad90/packages/floating-vue/src/directives/v-close-popper.ts
[style]: https://github.com/Akryum/floating-vue/blob/19857764c4f73dea7ed44a7d970adb968ee7ad90/packages/floating-vue/src/style.css
[docs-component]: https://github.com/Akryum/floating-vue/blob/19857764c4f73dea7ed44a7d970adb968ee7ad90/docs/guide/component.md
[concepts]: ./concepts.md
