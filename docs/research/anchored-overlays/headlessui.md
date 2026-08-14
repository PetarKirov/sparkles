# Headless UI (TypeScript — React / Vue)

A behavior-only overlay toolkit that ships state machines, focus algebra, dismissal
detection and ARIA wiring for menus, listboxes, comboboxes, popovers and dialogs —
and deliberately ships no positioning engine and no arrow, delegating placement
wholesale to [Floating UI][floating-ui-page] behind a single one-prop seam.

| Field             | Value                                                                                                                                                                                                                                                                     |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language          | TypeScript (React and Vue packages)                                                                                                                                                                                                                                       |
| License           | MIT — Copyright (c) 2020 Tailwind Labs ([`LICENSE:1`][lic])                                                                                                                                                                                                               |
| Repository        | <https://github.com/tailwindlabs/headlessui>                                                                                                                                                                                                                              |
| Documentation     | <https://headlessui.com>                                                                                                                                                                                                                                                  |
| Version           | `@headlessui/react` 2.2.10 ([`package.json:3`][pkg-version])                                                                                                                                                                                                              |
| Category          | Web / headless behavior                                                                                                                                                                                                                                                   |
| Surface model     | In-canvas, DOM only: one document, one userland portal root (`div#headlessui-portal-root`), and an explicitly **non-native** "top layer" built from ordered id stacks. No OS popup, no `showPopover`, no `<dialog>`, and no `z-index` assignment anywhere in the package. |
| Docs-only?        | No — every claim below is read from the source tree at the pinned revision.                                                                                                                                                                                               |
| **Revision read** | `eea57cf46fd6767ed1059012f7073b88eb159fba`                                                                                                                                                                                                                                |

> [!NOTE]
> Unless stated otherwise, every path is relative to `packages/@headlessui-react/src/`.
> The Vue package is a genuinely different arrangement and is treated separately
> under dimension 16, _Shared infrastructure_.

---

## Overview

### What it solves

Headless UI's product is the _behavior_ of an overlay, not its geometry: what the
keyboard does, where focus goes, when the surface closes, which ARIA attributes are
emitted, and what the styling layer is told about the outcome. Placement is treated
as somebody else's problem — the React package lists `@floating-ui/react` as a
runtime dependency ([`package.json:59`][pkg-deps]) and routes every anchored surface
through one internal module, `internal/floating.tsx`. The public surface of that
seam is a single prop, `anchor`, whose entire vocabulary is the string
`"<side> <align>"` plus three numbers (`gap`, `offset`, `padding`)
([`internal/floating.tsx:43`][floating-anchorprops]).

That seam is the most transferable artifact in the repository for a canvas toolkit,
because it shows precisely where a library can cut positioning off. Everything above
the cut is "which side do I want, and how far away"; everything below is "where does
that land in device space". A toolkit that owns its own integer-cell geometry needs
only the half above the cut — and Headless UI demonstrates that the half above the
cut is small: four physical sides, three alignments, three scalars, and one string
handed back naming the side that actually won.

The rest of the library is the part a positioning engine cannot supply: an ordered
arbitration model for "who owns Escape right now", a two-phase pointer protocol for
outside dismissal, four distinct focus policies, reference-counted world-blocking,
and a hand-rolled reducer runtime that every overlay's state is expressed in.

### Design philosophy

Three moves recur throughout the source.

**(1) Ordered stacks instead of a top layer.** `useIsTopLayer(enabled, scope)`
maintains N independent LIFO stacks of component ids and every global behavior asks
"am I the top of _my_ stack?" rather than consulting the DOM. The doc comment says
so outright ([`hooks/use-is-top-layer.ts:6-11`][top-layer]):

> A hook that returns whether the current node is on the top of the hierarchy, aka
> "top layer". Note: this does not use the native DOM "top-layer" but conceptually
> it's the same thing.

This is the same constraint a cell-grid toolkit lives under — no compositor, no
native [top layer][concepts], no `z-index` — solved in userland by an ordered id
stack rather than by asking the platform.

**(2) Dismissal is a separate pass, not a bubbling handler.** Outside-click
detection runs in the capture phase specifically so that intermediate layers cannot
suppress it, and re-arbitrates afterwards on `event.defaultPrevented`
([`hooks/use-outside-click.ts:132`][outside-capture]):

```ts
// We will use the `capture` phase so that layers in between with `event.stopPropagation()`
// don't "cancel" this outside click check. E.g.: A `Menu` inside a `DialogPanel` if the `Menu`
// is open, and you click outside of it in the `DialogPanel` the `Menu` should close. However,
// the `DialogPanel` has a `onClick(e) { e.stopPropagation() }` which would cancel this.
```

The companion line is the whole cross-layer veto channel — an inner Menu cancels so
that only it closes and the enclosing Dialog stays open
([`hooks/use-outside-click.ts:40`][outside-dp]):

```ts
if (event.defaultPrevented) return;
```

**(3) Reducers over ad-hoc state.** Menu, Listbox, Combobox and Popover are
subclasses of an abstract `Machine<State, Event>` with a pure
`reduce(state, event)` ([`machine.ts:5`][machine-class]), immutable state, identity
early-outs, slice subscriptions gated by `shallowEqual`, and cross-machine wiring
done by subscribing to another machine's action stream.

A fourth trait is worth naming because it is unusual: the source records _why_, not
_what_. The `transform: false` justification, the Safari blur-before-close note, the
one-frame transition delay, the VoiceOver `aria-selected` deviation and the
virtual-keyboard refocus skip are all decision records left in place. The
`transform: false` note is the one most relevant here
([`internal/floating.tsx:213-215`][floating-transform]):

```ts
// We use the panel in a `Dialog` which is making the page inert, therefore no re-positioning is
// needed when scrolling changes.
transform: false,
```

That is a recorded justification for turning _off_ continuous transform tracking:
because modality already froze the world, static absolute placement suffices. The
same argument applies to a toolkit that repaints whole frames.

---

## How it works

**The anchoring seam.** A `FloatingProvider` wraps the component; the trigger calls
`useFloatingReference()` to register itself as Floating UI's reference element
([`internal/floating.tsx:109`][floating-reference]); the panel calls
`useFloatingPanel(anchor)`, which resolves the `anchor` prop
([`:99`][floating-resolved-anchor]), splits `"<side> <align>"` into two tokens
([`:189`][floating-split]), builds a middleware array and hands the result back as a
style object plus the resolved side/align as a `data-anchor` attribute
([`:122`][floating-dataanchor]).

```text
anchor prop            →  { to: "bottom start", gap, offset, padding }
split(' ')             →  to = "bottom", align = "start"
placement              →  align === 'center' ? to : `${to}-${align}`
middleware             →  offset({mainAxis: gap, crossAxis: offset})
                          shift({padding})
                          flip({padding})               // unless to === 'selection'
                          inner({...})                  // only if to === 'selection'
                          size({padding, apply: clamp maxWidth/maxHeight})
result read back       →  context.placement.split('-')  →  data-anchor="bottom start"
```

**The machine layer.** `send(event)` computes `reduce(state, event)`, returns early
if the reducer returned the same reference, notifies slice subscribers only when
`shallowEqual` fails, then fires per-event-type subscribers
([`machine.ts:66`][machine-send]). React sees a machine only through `useSlice`, a
`useSyncExternalStoreWithSelector` wrapper in `react-glue.tsx` — the single React
coupling point in the whole state layer.

**The global layer.** `machines/stack-machine.ts` holds a
`DefaultMap<Scope, StackMachine>` ([`:72`][stack-map]); six scopes are live
(`null`, `escape`, `inert-others`, `scroll-lock`, `focus-trap#tab-lock`,
`focus-trap#initial-focus`). Every cross-cutting hook — `useEscape`,
`useInertOthers`, `useScrollLock`, `FocusTrap` — gates itself on
`useIsTopLayer(enabled, scope)`. Component machines additionally subscribe to the
default scope's `Push` action and close themselves the moment they are open but no
longer top-of-stack ([`components/menu/menu-machine.ts:398`][menu-stack-close]).

---

## The analysis spine

### 1. Anchor model

The anchor is always a single live DOM element handed to Floating UI via
`refs.setReference`, exposed to component code only as the opaque
`useFloatingReference()` ref setter. There is no rect, point, cursor, text-range or
[virtual-anchor][concepts] API anywhere in the package. `AnchorProps` is _not_ an
anchor — it is a placement config: `false | "<side> <align>" | {to, gap, offset, padding}`.

One trigger per popup is enforced at runtime rather than by type: `PopoverButton`
pushes a per-instance `Symbol()` into `state.buttons` and `console.warn`s when more
than one is registered ([`components/popover/popover.tsx:370`][popover-symbol]).
The inverse relation exists as `PopoverGroup`, which registers bags of
`{buttonId, panelId, close}` and drives `closeOthers(buttonId)`.

A detached trigger-vs-anchor case does appear, in an unusual form: `anchor="selection"`
re-anchors a Listbox panel over the _currently selected option inside the panel
itself_, by feeding Floating UI's `inner` middleware a list of option elements plus
an index ([`components/listbox/listbox.tsx:621`][listbox-inner]). The anchor becomes
a sub-region of the popup.

Two anchor identities in the codebase are already plain comparable values:
`computeVisualPosition(el)` returns the string `"x,y"` built from
`getBoundingClientRect` ([`utils/element-movement.ts:15`][movement-pos]), and the
resolved placement is re-exposed as the string `data-anchor="bottom start"`. Config
identity, by contrast, is compared by serializing DOM nodes into the key:
`JSON.stringify(placement, (_, v) => v?.outerHTML ?? v)`
([`internal/floating.tsx:136`][floating-stable]).

```text
resolveAnchor(prop):
    falsy      → disabled
    string     → { to: prop }
    object     → prop
    [side, align = 'center'] = to.split(' ')

anchorIdentity(el) := `${rect.x},${rect.y}`      // string, compared for inequality

selectionAnchor(options, selectedIdx):
    idx = selectedIdx ?? 0
    → inner({ listRef: options, index: idx })
```

**Where it lives.** The seam is `internal/floating.tsx`; the anchor→screen
arithmetic is in the external `@floating-ui/react` package (**not read** — see
[Sources](#sources)); movement tracking is `utils/element-movement.ts`; multi-trigger
arbitration is `PopoverGroup` in `components/popover/popover.tsx`.

**Degradation.** Everything in this dimension survives off the DOM if "element" is
replaced by an integer-cell rect plus an id: the config is already a value, the
tracked position is already a string, the resolved placement is already a string.
What does not survive is the implicit registration — "the anchor is whatever element
the ref landed on" — which a canvas toolkit must replace with an explicit name
(widget id → rect from the last layout pass; see [`./sparkles-baseline.md`][baseline]).
Sub-cell precision is irrelevant here because the anchor is never a point. With no
script at all (the static-HTML tier) there is no anchor: only CSS adjacency remains.

### 2. Placement model

The public vocabulary is intentionally tiny and physical: `top | right | bottom | left`
optionally followed by `start | end`, defaulting to `bottom` with an implicit
`center` ([`internal/floating.tsx:183`][floating-default]). There is no
preferred-placement list, no `autoPlacement`, no custom [clipping boundary][concepts],
and no work-area or multi-monitor concept. A grep of the React package at this
revision finds zero references to `visualViewport`, `env(safe-area-inset-*)`,
`availWidth` or `screenLeft`, and zero references to `rtl` or `writing-mode` — so
soft-keyboard avoidance is absent, and any writing-mode handling of `start`/`end`
happens inside Floating UI, which was not read.

[Flip][concepts] and [shift][concepts] are both always on — neither is configurable —
and both take the same single `padding` scalar as viewport inset
([`:232`][floating-shift], [`:237`][floating-flip]). A fifth pseudo-side,
`selection`, maps to `bottom`/`bottom-<align>`, forces the main-axis gap to `0`,
_disables_ flip (the source notes the incompatibility with `inner`) and enables the
`inner` middleware.

The three scalars default to CSS custom properties — `var(--anchor-gap, 0)`,
`--anchor-offset`, `--anchor-padding` — and are resolved by DOM measurement (see
dimension 3). Placement inputs are therefore owned by the stylesheet, not by the
call site.

```text
placement := to === 'selection'
             ? (align === 'center' ? 'bottom' : `bottom-${align}`)
             : (align === 'center' ? to      : `${to}-${align}`)

middleware := [ offset({ mainAxis: to === 'selection' ? 0 : gap, crossAxis: offset }),
                shift({ padding }),
                to !== 'selection' && flip({ padding }),
                to === 'selection' && inner ? inner({...}) : null,
                size({ padding, apply: maxWidth = availableWidth,
                                       maxHeight = min(var(--anchor-max-height, 100vh),
                                                       availableHeight) }) ]

resolved := context.placement.split('-')     // re-exported as data-anchor
```

**Where it lives.** Vocabulary and middleware composition:
`internal/floating.tsx:182-342`. The flip/shift/size arithmetic itself: Floating UI.

**Degradation.** The vocabulary — four sides × three alignments plus a
gap/offset/padding triple — is target-independent and translates directly to cells.
Note what the model cannot express, though: with no fallback ordering, a single flip
is the entire [constraint-adjustment][concepts] story, and `padding` is a _uniform_
scalar, so an asymmetric inset (a bottom-only soft-keyboard inset, a reserved status
row) has no representation at all. That is the argument for a per-side inset in a
cell toolkit rather than a scalar; the general form of that argument is developed in
[`./concepts.md`][concepts] and [`./comparison.md`][comparison]. On the static-HTML
tier only the preferred side survives as a CSS class: no flip, no shift.

### 3. Collision & geometry engine

Overflow detection, clipping-ancestor discovery and scroll-container walking are
100% outside this repository. What Headless UI owns is the _tracking and hygiene_
layer, and it is unexpectedly polling-heavy:

- `whileElementsMounted: autoUpdate` hands continuous tracking to Floating UI
  ([`internal/floating.tsx:325`][floating-autoupdate]).
- `useElementSize` runs an unconditional `requestAnimationFrame` loop calling
  `getBoundingClientRect()` every frame, with the recorded reason that a
  `transform: scale` would not fire a `ResizeObserver`
  ([`hooks/use-element-size.ts:11`][element-size]). The measured width is published
  as `--button-width` ([`components/listbox/listbox.tsx:753`][listbox-buttonwidth])
  / `--input-width` so a panel can match its trigger.
- The CSS-variable placement scalars are re-resolved by a second `rAF` loop that
  first compares the raw computed strings as a fast path before re-running the
  expensive measurement ([`internal/floating.tsx:473`][floating-poll]).
- `useFixScrollingPixel` installs a `MutationObserver` on the panel's `style`
  attribute and rewrites a fractional computed `maxHeight` up to
  `Math.ceil` ([`internal/floating.tsx:373`][floating-fixpixel]).
- `useOnDisappear` treats an all-zero bounding rect as "the anchor vanished" and
  subscribes with _both_ `ResizeObserver` and `IntersectionObserver`
  ([`hooks/use-on-disappear.ts:13`][disappear]).
- `detectMovement` compares the `"x,y"` string on `ResizeObserver`, passive window
  scroll and window resize ([`utils/element-movement.ts:20`][movement-detect]).

```text
disappeared(el) := rect.x == 0 && rect.y == 0 && rect.width == 0 && rect.height == 0
moved(el, tracked) := `${rect.x},${rect.y}` != tracked
fractionalFix(el) := mh = computed maxHeight
                     if parseFloat(mh) != parseInt(mh)
                         el.style.maxHeight = ceil(parseFloat(mh)) + 'px'
```

**Where it lives.** Collision math: Floating UI. Tracking, observers and hygiene:
`hooks/use-element-size.ts`, `hooks/use-on-disappear.ts`,
`utils/element-movement.ts`, `internal/floating.tsx:373`.

**Degradation.** The part Headless UI wrote itself is exactly the part that
generalises: "anchor vanished" as a degenerate-rect test, "anchor moved" as an
equality test on a cheap position value, "the panel must not exceed the available
box" as a max-size clamp, and "the panel's width follows the trigger's width" as a
published measurement. All four are integral in cells and all four are assertable on
a headless recording canvas ([`../../specs/ui-app/index.md`][spec-ui-app]). The
observer and polling apparatus is the part that does _not_ generalise: an
immediate-mode toolkit recomputes layout every frame anyway, so `autoUpdate` and the
two `rAF` loops have no analogue and should not be ported. With no sub-cell
precision the fractional-pixel fix disappears by construction.

### 4. Arrow / caret geometry

**Not applicable, and the absence is total and deliberate.** A case-insensitive grep
for `arrow` across the React package at this revision returns two hits, both prose
comments about _keyboard_ arrow keys. There is no arrow element, no import of
Floating UI's `arrow` middleware, no arrow inset feeding the main-axis gap, no
corner clamping, no arrow hiding when the surface detaches, and no
[transform origin][concepts] derived from the resolved side.

The only placement-derived datum handed to the styling layer is the
`data-anchor="<side> <align>"` string, which reports the side _after_ flip and is
remapped back to the literal `selection` for the selection anchor
([`internal/floating.tsx:329-333`][floating-exposed]). A consumer who wants a caret
must derive it from that string plus their own CSS.

**Where it lives.** Nowhere in the library; pushed to the consumer's stylesheet,
keyed off `data-anchor`.

**Degradation.** The absence itself is the finding: a headless library can decline
arrow geometry because CSS can draw a triangle from a side name alone. A cell toolkit
cannot make the same trade, because an arrow in a grid is a _glyph in a specific
cell_ on the popup's anchor-facing edge, and nothing downstream can recompute which
cell without the geometry. What does transfer is the shape of the contract: publish
the resolved side (and, for cells, the integer offset along that side) as data and
let the paint layer decide whether to draw anything. The arrow question proper is
developed in [`./concepts.md`][concepts] and [`./comparison.md`][comparison]; the
state of `sparkles:ui`'s four arrow renderers is in
[`./sparkles-baseline.md`][baseline].

### 5. Trigger semantics

Trigger handling is unusually surgical. `useHandleToggle` splits on pointer type at
`pointerdown` ([`hooks/use-handle-toggle.tsx:6`][handle-toggle]): for
`pointerType === 'mouse'` with `button === MouseButton.Left` it calls
`preventDefault()` and toggles _on pointerdown_, with the recorded rationale that
this fires before focus moves, so a currently-focused `input` keeps its caret and
selection; for touch and pen it does nothing on pointerdown (to avoid blocking
scroll) and toggles on the later `click`, latching the pointer type so the click
path skips mouse events. Right-click is filtered explicitly against
`MouseButton.Right`, and a test asserts it
([`components/popover/popover.test.tsx:2245`][popover-rightclick]).

`useActivePress` implements press-state _without_ relying on `pointerleave`, which
the source records as unreliable or absent on iOS Safari
([`hooks/use-active-press.tsx:68`][active-press-ios]). It builds a rect from the
pointer event's own `width`/`height` and keeps `pressed` true only while that rect
overlaps the target's bounding rect, resetting on document-level `pointerup` /
`pointercancel` ([`:9`][active-press-rect]).

Hover and focus-visible are not implemented in-house: `@react-aria/interactions`
`useHover` and `@react-aria/focus` `useFocusRing` are runtime dependencies
([`package.json:60-61`][pkg-deps]) used by every trigger — see
[`./react-aria.md`][react-aria]. Separately there is a global focus-visible
heuristic in `utils/focus-management.ts`: a capture-phase `keydown` (ignoring
meta/alt/ctrl) sets `data-headlessui-focus-visible` on the root element, and a
capture-phase `click` clears or sets it based on `event.detail` (0 meaning a
keyboard-synthesised click).

No shipped overlay has a hover trigger; only the unexported Tooltip hovers.
Multiple handlers on one element are combined by `mergeProps`, which _concatenates_
same-named `on*` handlers into an ordered chain rather than overwriting
([`utils/render.ts:345`][render-handlers]) — the only race-avoidance mechanism at
the props level.

```text
toggle(pointerdown e):
    pointerTypeRef = e.pointerType
    if disabled                       return
    if e.pointerType !== 'mouse'      return       // touch/pen handled on click
    if e.button !== Left              return
    e.preventDefault(); cb(e)

toggle(click e):
    if pointerTypeRef === 'mouse'     return       // already handled above
    if disabled                       return
    cb(e)

pressed(target):
    pointerdown → pressed = true, subscribe document pointerup/move/cancel
    pointermove → pressed = overlap(rectOf(pointer), rectOf(target))
                  where rectOf(pointer) = [clientX ± width/2, clientY ± height/2]
```

**Where it lives.** `hooks/use-handle-toggle.tsx`, `hooks/use-active-press.tsx`,
`components/mouse.ts`, `utils/focus-management.ts:158-195`, `utils/render.ts:339`.

**Degradation.** The pointer-type split is the transferable idea, and it maps onto a
cell toolkit as a two-target specialisation rather than a runtime sniff (see
dimension 12). `useActivePress` needs pointer _motion_ and pointer _release_: the
terminal decodes button release over SGR-1006, but bare-motion reporting is off by
default and must be declared, so press-visual is a capability-gated feature on the
TUI rather than an unconditional one ([`../../specs/ui/input.md`][spec-input],
[`./sparkles-baseline.md`][baseline]). The `event.detail === 0` focus-visible trick
has no analogue and should be replaced by an explicit last-input-source field, which
sparkles does not carry today. `mergeProps`-style handler chaining is worth copying
as an explicit ordered handler list rather than a single callback slot.

### 6. Timing

No shipped overlay has an open or close delay: Menu, Listbox, Combobox, Popover and
Dialog are all instantaneous. All timing lives in the **unexported** Tooltip, which
`index.ts` still carries commented out with `// TODO: Enable when ready`
([`index.ts:25-26`][index-tooltip]).

That tooltip is nonetheless the most complete delay machine in the repository: a
four-state enum `Hidden | Initiated | Visible | Hiding`
([`components/tooltip/tooltip.tsx:46`][tooltip-state]) driven by a reducer over
(state × `When.Delayed | When.Immediate`) ([`:111`][tooltip-reducers]), with
`showDelayMs = 750` and `hideDelayMs = 300` ([`:211-212`][tooltip-delays]). A single
effect keyed on the state schedules the only timers — `Initiated` schedules
`Show(Immediate)` after the show delay, `Hiding` schedules `Hide(Immediate)` after
the hide delay, and every state change disposes the pending timer first
([`:237-246`][tooltip-timers]).

[Warm-up / cool-down][concepts] coordination is a module-global `TooltipStore`
holding one `activeTooltipId` ([`:69`][tooltip-store]): a `Delayed` show is upgraded
to `Immediate` when some _other_ tooltip is currently active
([`:252`][tooltip-upgrade]), and an `Immediate` show claims the id. Visibility
requires both the local state and `activeTooltipId === state.id`
([`:281`][tooltip-visible]), so exactly one tooltip can be visible globally.
Re-entry during the hide delay is handled by an `onMouseMove` on the _trigger_:
while `Hiding`, any movement re-shows immediately ([`:375`][tooltip-mousemove]).

```text
states  {Hidden, Initiated, Visible, Hiding}
inputs  Show(when) | Hide(when),   when ∈ {Delayed, Immediate}

δ(Hidden,    Show(D)) = Initiated      entry(Initiated) ⇒ after(showDelay) Show(I)
δ(Hidden,    Show(I)) = Visible        entry(Hiding)    ⇒ after(hideDelay) Hide(I)
δ(Initiated, Show(I)) = Visible        every other entry ⇒ cancel timers
δ(Initiated, Hide(*)) = Hidden
δ(Visible,   Hide(D)) = Hiding
δ(Visible,   Hide(I)) = Hidden
δ(Hiding,    Show(*)) = Visible
δ(Hiding,    Hide(I)) = Hidden

upgrade   Show(D) becomes Show(I)  iff activeId ∉ {null, self}
claim     Show(I) sets activeId = self;  Hide(I) clears it iff activeId === self
visible   activeId === self AND state ∈ {Visible, Hiding}
```

Elsewhere the only timers are the typeahead reset (350 ms in Listbox
([`:725`][listbox-typeahead]) and Menu) and the quick-release hold threshold
(200 ms — dimension 7). There is no max display duration and no group provider: the
store is process-global, not a React context.

**Where it lives.** Entirely in `components/tooltip/tooltip.tsx`, and not exported.

**Degradation.** This machine has no DOM dependency at all — four states, two
inputs, two scalars, one global id — so it is drivable by a virtual clock on a
recording canvas. Two targets remove parts of it cleanly rather than breaking it:
with no hover, `Show(Delayed)` is never produced and the `Initiated` state collapses;
with no script, both delays are zero and the table reduces to `{Hidden, Visible}`,
which is a _sound degenerate case of the same table_ rather than a different design.
That is the strongest argument this subject offers for expressing timing as a table
over (state, input, urgency) rather than as ad-hoc timers. Note the sparkles-side
caveat: a zero duration must statically disable the feature rather than arm a
zero-length timer ([`./features-people-forget.md`][forget]).

### 7. Interactive hover

There is no [safe polygon][concepts], no pointer bridge, no menu-aim and no
trajectory heuristic — and, grep-confirmed at this revision, no submenu and no
context-menu component at all. The trigger→content travel problem is sidestepped
rather than solved: the only hover-opened surface is the unexported Tooltip, whose
300 ms hide delay is the entire bridge, and whose panel installs _no_ pointer
handlers ([`components/tooltip/tooltip.tsx:424`][tooltip-panel]), so moving the
pointer into the tooltip does not cancel the pending hide. That is an observed gap,
not a documented feature.

What the library does have is a precise hover-intent-versus-keyboard discriminator
used by every option list. `useTrackedPointer` stores the last
`[screenX, screenY]` and `wasMoved(evt)` returns false when the coordinates are
identical ([`hooks/use-tracked-pointer.ts:9`][tracked-pointer]). Every option
registers both `onPointerEnter` (record only) and `onPointerMove` (activate only if
moved); symmetrically `onPointerLeave` deactivates only if the current
`activationTrigger === Pointer`. This exists because keyboard navigation scrolls an
option under a stationary cursor, firing a spurious `pointerenter` that would
otherwise steal the active item mid-keystroke. Combobox's `hold` prop
([`components/combobox/combobox.tsx:1184`][combobox-hold]) suppresses the leave
branch entirely.

A separate "drag out of the trigger and release on an item" interaction is handled
by `useQuickRelease`, gated on a 200 ms hold _and_ ≥ 5 px of travel
([`hooks/use-quick-release.ts:29,33`][quick-release]).

```text
wasMoved(evt):  p = [evt.screenX, evt.screenY]
                if p == last then return false
                last = p; return true

onMove(opt):    if !wasMoved            return
                if disabled             return
                if active && trigger == Pointer return
                goToOption(Specific(opt), trigger = Pointer)

onLeave(opt):   if !wasMoved || !active || trigger != Pointer || hold  return
                goToOption(Nothing)

quickRelease:   pointerdown → record (t0, x0, y0)
                pointerup   → if |dx| < 5 && |dy| < 5 → ordinary click, ignore
                              classify(target) → Ignore | Select(el) | Close
                              Select commits only if (t1 - t0) > 200 ms
```

**Where it lives.** `hooks/use-tracked-pointer.ts`, `hooks/use-quick-release.ts`,
per-option handlers in `components/listbox/listbox.tsx:876-906` and
`components/combobox/combobox.tsx`.

**Degradation.** The movement discriminator becomes cheaper in cells: "did the
pointer's `(row, col)` change?" is one integer comparison, and sub-cell jitter cannot
produce a false positive. The 5 px quick-release threshold becomes ≥ 1 cell of
travel, and the 30 px touch-cancel threshold a small number of cells. The companion
invariant — every activation records _why_ it happened, and later handlers branch on
that provenance — is the part worth copying verbatim; it is what lets hover and
keyboard navigation coexist without fighting. Both `useQuickRelease` and the
two-phase press protocol need pointer release, which the terminal does decode over
SGR-1006, so they are not lost on the TUI; hover intent does, however, require the
host to have opted into motion reporting ([`./sparkles-baseline.md`][baseline]).
On a target with no hover at all, none of this dimension is reachable. What
replaces a safe polygon on a cell grid is _not_ settled by this subject — it has
none — and is treated in [`./concepts.md`][concepts] and
[`./comparison.md`][comparison].

> [!WARNING]
> A hoverable panel that does not cancel its own pending hide is the classic tooltip
> bug, and Headless UI's in-tree Tooltip has it: `TooltipPanel`'s `ourProps` are only
> `ref`, `role: 'tooltip'` and `style`. Any toolkit that lets the pointer enter the
> surface must feed `Show(Immediate)` back into the machine on entry.

### 8. Dismissal

The richest dimension in this subject, and the one with the most directly reusable
structure. Seven independent causes are implemented.

**Escape.** `useEscape` listens on the window in the bubble phase, requires
`useIsTopLayer(enabled, 'escape')`, and skips if `event.defaultPrevented`
([`hooks/use-escape.ts:5`][escape]). Dialog additionally blurs the active element
_before_ closing, with the recorded reason that Safari otherwise scrolls the page to
keep a focused element inside a body-appended portal in view
([`components/dialog/dialog.tsx:246`][dialog-escape]). Menu and Listbox handle Escape
on the panel with `flushSync(close)` followed by `button.focus({preventScroll: true})`.

**Outside pointer.** Not a `click` listener. A capture-phase `pointerdown` records
`composedPath()[0] ?? target` ([`:108`][outside-down]); the capture-phase `pointerup`
runs the check against that _recorded_ target ([`:119`][outside-up]). Press-inside /
release-outside therefore does not dismiss, and vice versa. Both handlers early-return
on `isMobile()`.

**Outside touch.** `touchstart` records the position; `touchend` bails if
`max(|dx|, |dy|) ≥ 30` px, treated as a scroll
([`:19`][outside-threshold], [`:152`][outside-touchend]).

**Window blur.** A capture-phase window `blur` counts as an outside click _only_ if
the active element is an `iframe` ([`:179`][outside-blur]) — the narrow case where a
click produces no document-level pointer event at all.

**Focus outside.** Popover installs its own capture-phase `focus` listener that
closes when focus lands outside the button, panel, registered nested portals,
sentinels and group ([`components/popover/popover.tsx:206`][popover-focusout]).

**Anchor hidden.** `useOnDisappear` closes when the trigger's rect collapses to all
zeros — the responsive-breakpoint case (`hidden md:block`).

**Top-of-stack changed.** Menu, Listbox and Combobox machines subscribe to the stack
machine's `Push` and close themselves when they are open and no longer on top.

Scroll and navigation are explicitly _not_ dismissal causes; the panel re-positions
instead. A related non-dismissal is `didButtonMove`: after a close begins, if the
trigger moved, the panel is force-disabled so a running exit transition cannot
visibly chase the anchor ([`components/menu/menu.tsx:429`][menu-didmove]).

```text
outsideCheck(recordedTarget, event, containers):
    if event.defaultPrevented                              stop
    if target == null                                      stop
    if !target.getRootNode().contains(target)              stop      // disconnected
    if !target.isConnected                                 stop
    for c in resolve(containers):
        if c.contains(target)                              stop
        if event.composed && composedPath().includes(c)    stop      // shadow piercing
    if !isFocusable(target, Loose) && target.tabIndex != -1
        event.preventDefault()                                       // dismiss without activating
    cb(event, target)
```

**Where it lives.** `hooks/use-outside-click.ts` (the whole pointer/touch/blur
protocol), `hooks/use-escape.ts`, `hooks/use-on-disappear.ts`,
`utils/element-movement.ts`, `machines/stack-machine.ts` plus per-component machine
constructors, `components/popover/popover.tsx:206`.

**Degradation.** Almost all of it survives. The pointerdown/pointerup pairing needs
pointer release, which is available on sparkles' pointer targets — including the
terminal, which decodes SGR-1006 release — so the two-phase identity test is
implementable, and the single-phase collapse Headless UI already carves out for
mobile is the template for a target that lacks it. `defaultPrevented` has no
analogue in a value-semantics toolkit and must become an explicit `handled` flag
threaded through a dismissal pass that runs in stack order, top first. Window
blur / iframe detection has no analogue in one surface; the nearest equivalent is
"the application lost focus", which a GUI backend can supply and the terminal
backend cannot. On the static-HTML tier, dismissal reduces to trigger
re-activation. The `preventDefault()` carve-out for non-focusable targets is worth
noting as a hazard rather than a pattern: the source itself flags it as a
backwards-compatibility choice, and it is precisely why the stack-based auto-close
above is needed to make "click menu B's trigger while menu A is open" behave.

### 9. Focus

Four distinct strategies, deliberately not unified.

1. **Tooltip:** no focus management at all. The trigger keeps focus, the panel is a
   `Description`, and Enter / Space / Escape on the trigger hide it immediately.
2. **Menu / Listbox:** focus moves to the _panel container_ itself
   (`container.focus({preventScroll: true})`), with roving selection expressed as
   `aria-activedescendant`; options are `tabIndex = -1` and never focused. Escape
   and Tab both `flushSync(close)` and then move focus deterministically.
3. **Popover:** non-modal by default. Containment is achieved with hidden
   focus-guard buttons (`data-headlessui-focus-guard`) rendered before and after the
   portalled panel and after the button, each with an `onFocus` that redirects based
   on the last Tab direction — forward off the end of the panel resumes document
   order _after_ the button, computed by rotating the focusable list around the
   button's index ([`components/popover/popover.tsx:880`][popover-rotate]). Guards
   render only when `isPortalled` is true, which is itself a heuristic (dimension 10).
4. **Dialog:** the full `FocusTrap` with a feature bitmask —
   `InitialFocus | TabLock | FocusLock | RestoreFocus | AutoFocus` — assembled
   per render ([`components/focus-trap/focus-trap.tsx:53`][focus-trap-features]).
   `TabLock` and `InitialFocus` each consult their _own_ stack scope, so nested traps
   hand off cleanly. `FocusLock` is a capture-phase window `focus` listener that
   prevents the event and re-focuses the previous element. `RestoreFocus` reads a
   module-global ten-entry history of recently focused elements
   ([`utils/active-element-history.ts:5`][focus-history]) and restores the most
   recent one still connected.

The shared primitive under all four is `focusIn`
([`utils/focus-management.ts:235`][focus-in]), whose loop keeps stepping while
`next !== getActiveElement(next)` — it _verifies_ the focus actually landed and
skips elements that silently refuse it ([`:297-317`][focus-in-verify]) — and which
calls `.select()` on text inputs for `Next`/`Previous` only, mimicking browser Tab
([`:328`][focus-in-select]).

```text
focusIn(elements, focus, {sorted, relativeTo, skipElements}):
    direction = (First|Next) ? +1 : -1
    start     = First    ? 0
              : Previous ? max(0, idx(relativeTo)) - 1
              : Next     ? max(0, idx(relativeTo)) + 1
              :            len - 1
    do {
        if offset >= total || offset + total <= 0   → Error
        i = start + offset
        if WrapAround   i = (i + total) % total
        else if i < 0   → Underflow
        else if i >= total → Overflow
        next = elements[i]; next.focus(opts); offset += direction
    } while (next !== activeElement(next))
    if (Next|Previous) && next is input/textarea  next.select()
    → Success
```

**Where it lives.** `utils/focus-management.ts` (the primitive plus `Focus`,
`FocusResult`, `FocusableMode` enums and the DOM-order comparators),
`components/focus-trap/focus-trap.tsx`, `utils/active-element-history.ts`,
`internal/hidden.tsx` (the guard element), `components/popover/popover.tsx`.

**Degradation.** The factoring — four policies over one stepping primitive — is the
transferable part, and `focusIn` itself ports almost verbatim to a list of widget
ids: the intent bitmask is a plain enum, the four outcomes
(`Success`/`Error`/`Overflow`/`Underflow`) are an ideal `Expected`-style return, and
"verify the focus took" becomes "skip widgets that decline focus". Two things should
not be ported: the focus _sentinel_ technique, which exists only because DOM tab
order and visual order diverge under portals, and the global active-element history,
because a toolkit that owns its focus can save a widget id and test liveness against
the current frame's arena. Within Headless UI every focus and open/close decision is
taken on `keydown` — the three `onKeyUp` handlers on overlay triggers exist solely
to cancel a Firefox-synthesised click on Space
([`components/menu/menu.tsx:221-230`][menu-keyup],
[`components/listbox/listbox.tsx:409-418`][listbox-keyup],
[`components/popover/popover.tsx:440-448`][popover-keyup]) — so a target without key
release loses nothing _in this subject_; whether that holds across the corpus is a
question for [`./comparison.md`][comparison], and it does not hold universally.

### 10. Layering & portals

There is exactly one portal target: a `div#headlessui-portal-root` created lazily on
`document.body`, reused if it already exists, and removed on unmount when it has no
children ([`components/portal/portal.tsx:38-44`][portal-target]). Each portal
instance wraps its children in a `div[data-headlessui-portal]` marker
([`:116`][portal-marker]), which nested-portal registration and the inert logic key
off. `PortalGroup` retargets descendants (Dialog uses it so nested overlays render
_inside_ the dialog rather than at the body root) and `ForcePortalRoot` overrides
that back. `useNestedPortals` ([`:208`][portal-nested]) maintains a parent/child
registry so a Popover knows which portalled subtrees are its own for outside-click
purposes.

Ordering is pure DOM order within the portal root. There is no `z-index` management
in the package at all — a repository grep at this revision finds none.

The overlay "tree" is not one tree: it is N independent LIFO stacks in a
`DefaultMap<Scope, StackMachine>` ([`machines/stack-machine.ts:72`][stack-map]),
keyed by scope string. `Push` moves an existing id to the top rather than
duplicating it ([`:22`][stack-push]). `useIsTopLayer` returns an _optimistic_ `true`
when enabled but not yet registered, correcting itself on the next render
([`hooks/use-is-top-layer.ts:65`][top-layer-optimistic]).

A separate concept, the **main tree node**, exists because a portalled panel can no
longer see its own application root: `MainTreeProvider` walks the document's root
children to find the container holding a marker element (rendering a hidden probe if
it must), so outside-click can distinguish "the app" from third-party root
containers ([`hooks/use-root-containers.tsx:90`][main-tree]).

```text
portalTarget(doc) := group target
                  ?? doc.getElementById('headlessui-portal-root')
                  ?? doc.body.appendChild(<div id="headlessui-portal-root">)

isPortalled(button, panel):
    for root in body > *:
        if root.contains(button) XOR root.contains(panel)  → true
    els    = focusableElements(doc); i = els.indexOf(button)
    before = els[(i + len - 1) % len]; after = els[(i + 1) % len]
    → !panel.contains(before) && !panel.contains(after)

stack.Push(id) := if present, splice out then append; else append
isTop(state, id) := state.stack.at(-1) === id
```

**Where it lives.** `components/portal/portal.tsx`,
`hooks/use-root-containers.tsx`, `machines/stack-machine.ts`,
`hooks/use-is-top-layer.ts`, `components/popover/popover-machine.ts:141`
(the `isPortalled` selector).

**Degradation.** This is the dimension with the most direct read-across, because
Headless UI operates under the same constraint a cell toolkit does: no native top
layer, no compositor, ordering by document position, arbitration in userland. Three
lessons transfer. (i) Do not build one overlay tree — build a stack _per concern_
(dismiss, focus containment, modality, input blocking), because a Menu inside a
Dialog is top-of-stack for Escape while the Dialog is still top-of-stack for
modality. (ii) Push-moves-to-top rather than push-duplicates makes re-entrancy free.
(iii) The optimistic `true` is a real ordering hazard in a retained system; the
structure suggests it disappears in an immediate-mode toolkit, where the entire
overlay set is known at frame-build time and the stacks can be derived from paint
order — but that is an inference about the toolkit, not something this source
demonstrates. `isPortalled`, the sentinels and the main-tree probe are DOM-divergence
artifacts with no analogue in one surface; their absence is a simplification rather
than a loss. See [`../../specs/ui/containers.md`][spec-containers] for where such a
registry would sit in `sparkles:ui`.

### 11. Modality

Modality is a `modal?: boolean` prop on `MenuItems`, `ListboxOptions`,
`ComboboxOptions` and `PopoverPanel`, and the defaults differ per component —
`true` for Menu ([`:358`][menu-modal]), Listbox ([`:525`][listbox-modal]) and
Combobox ([`:1187`][combobox-modal]), `false` for Popover
([`:703`][popover-modal]). It composes exactly two effects: `useScrollLock` and
`useInertOthers`. Dialog is unconditionally modal and adds `aria-modal` (only while
open and not in demo mode, [`:288`][dialog-ariamodal]) plus the focus trap.

`useInertOthers` is the sharpest algorithm here. Rather than computing the
complement of the allowed set, it walks _up_ from each allowed element to the body
and marks every sibling at each level inert, skipping any sibling that itself
contains an allowed element ([`hooks/use-inert-others.tsx:97-121`][inert-walk]) — so
the path from the body down to the allowed elements stays live and everything else
is dead. Marking is **reference counted** in two module-global maps: the first mark
snapshots the prior `aria-hidden` and `inert` values, later marks only increment, and
only the last unmark restores ([`:6-9`][inert-refcount]). It sets both `inert` (the
native pointer/keyboard/focus block) and `aria-hidden`. It is itself gated on
`useIsTopLayer(enabled, 'inert-others')`, so nested modals do not fight.

Scroll lock is a separate stack scope with an iOS specialisation that installs
document-level `touchstart`/`touchmove` handlers, sets `overscroll-behavior: contain`
on the allowed container's root and `touch-action: none` outside it, and prevents
`touchmove` unless the target's scrollable-parent chain terminates before the portal
marker.

There is no passthrough / click-through mode and no built-in scrim: Dialog's
`Backdrop` is `aria-hidden` and does _not_ close on click (outside-click does that),
while Popover's `Backdrop` does.

```text
inertOthers(allowed[], disallowed[]):
    for d in disallowed: markInert(d)
    for a in allowed:
        p = a.parentElement
        while p && p !== body:
            for node in p.children:
                if allowed.some(x => node.contains(x)) continue
                markInert(node)
            p = p.parentElement

markInert(el):
    n = counts[el] ?? 0; counts[el] = n + 1
    if n != 0 return unmark                       // already marked by someone else
    originals[el] = { 'aria-hidden': el.getAttribute('aria-hidden'), inert: el.inert }
    el.setAttribute('aria-hidden', 'true'); el.inert = true
```

**Where it lives.** `hooks/use-inert-others.tsx`, `hooks/use-scroll-lock.ts` plus
`hooks/document-overflow/*`, `components/dialog/dialog.tsx`, and the per-component
`modal` plumbing.

**Degradation.** The sibling walk is a tree algorithm with no place in a flat
display list, where "inert everything below the modal" is a truncation of the hit
list rather than a mutation of the world. The refcounting lesson _does_ transfer and
is the durable one: any globally blocked resource touched by two simultaneous
overlays needs a count plus the saved previous value, or the first overlay to close
un-blocks for both. The accessibility modal bit and `inert` have no cell-grid
analogue and are simply dropped — `sparkles:ui` emits no ARIA on any backend
([`./sparkles-baseline.md`][baseline]). Scroll lock remains meaningful (a scrollable
pane behind an overlay should not scroll) and its iOS complexity evaporates.

### 12. Adaptive presentation

There is no popover→sheet transformation, no teaching-tip concept and no
keyboard-driven relocation. Adaptation is three narrow, component-owned booleans, and
it always adapts the _interaction protocol_, never the presentation — the same panel,
the same placement, the same DOM.

1. `useIsTouchDevice()` is `matchMedia('(pointer: coarse)')` with a live `change`
   subscription. Dialog uses it for exactly one decision: omit
   `FocusTrapFeatures.InitialFocus` so the soft keyboard does not appear
   ([`components/dialog/dialog.tsx:294-307`][dialog-touch]). Note the gate is on
   device _type_, not on how the overlay was opened.
2. `isMobile()` is a platform-string sniff — `isIOS() || isAndroid()`, where iOS is
   `/iPhone/` on `navigator.platform` or `/Mac/` with `maxTouchPoints > 0`
   ([`utils/platform.ts:4-25`][platform]) — used to skip the pointerdown/pointerup
   outside-click path entirely (leaving only the touch path) and to skip refocusing
   the `ComboboxInput` after a selection, with an explicit comment that this exists
   solely to avoid raising the virtual keyboard and a pointer to
   `navigator.virtualKeyboard` as the eventual better answer
   ([`components/combobox/combobox.tsx:1509-1518`][combobox-vk]).
3. `useHandleToggle` branches on `event.pointerType` (dimension 5).

The file itself opens with the disclaimer that these detections "aren't perfect, and
we are making assumptions here" ([`utils/platform.ts:1-2`][platform]).

**Where it lives.** `utils/platform.ts`, `hooks/use-is-touch-device.ts`, consumed at
`components/dialog/dialog.tsx:294`, `hooks/use-outside-click.ts:112`/`:123`, and
`components/combobox/combobox.tsx:1509`. There is no platform layer and no
capability object; each component owns its own adaptation.

**Degradation.** For a toolkit whose targets are known at compile time, UA sniffing
is unnecessary, but the _structural_ choice is the right one to copy: adapt the
protocol, not the presentation. Two of the three adaptations map onto sparkles
targets directly — "no initial focus on coarse pointers" corresponds to "do not
steal focus where a soft keyboard would open", and "skip the press/release protocol
on touch" corresponds to a single-phase protocol on a target that has one. The soft
keyboard is the one place a canvas toolkit must go further than this subject:
Headless UI merely avoids _provoking_ the keyboard, whereas an inset that is already
present has to be folded into the placement boundary — and the uniform `padding`
scalar of dimension 2 cannot express it. See
[`../platform-ui-guidelines/index.md`][platform-guidelines] and
[`./proposal.md`][proposal].

### 13. Accessibility

The accessibility surface is the library's product, and it is layered into a
_reusable_ part and a _per-pattern_ part — a split worth noting on its own.

Reusable: `Label` and `Description` registries that collect ids and hand back joined
`aria-labelledby` / `aria-describedby`; the `Hidden` component (a clipped 1×0 span,
[`internal/hidden.tsx:7`][hidden]) used both as a visually hidden focus guard and as
a fully hidden probe; the global `data-headlessui-focus-visible` flag; and `render()`
dropping a self-referential `aria-labelledby` ([`utils/render.ts:161`][render-aria]).

Per-pattern: Menu (`aria-haspopup`, `aria-expanded`, `aria-controls`,
`role=menu`/`menuitem`), Listbox (`role=listbox`/`option`, `aria-multiselectable`,
`aria-orientation`, and `aria-selected` for both single and multi-select, with a
comment recording that WAI-ARIA prescribes `aria-checked` for multi-select but
VoiceOver disagrees), Combobox, and Dialog (`role=dialog|alertdialog`, validated with
a warning). Roving focus in Menu and Listbox is `aria-activedescendant` on the focused
container, not real focus — see [`./aria-apg.md`][apg].

The Tooltip is the sharpest statement: `role="tooltip"`, `aria-describedby` on the
trigger only while visible ([`components/tooltip/tooltip.tsx:385`][tooltip-describedby]),
and a panel whose default tag is literally `Description`
([`:411`][tooltip-panel-tag]) — the content is _structurally_ a description, which is
the strongest available statement that tooltip content may not be interactive.

The one algorithmic piece is the styling channel rather than the semantic one:
`render()` builds `data-headlessui-state` by collecting every boolean-true key of the
render slot, kebab-casing it and joining with spaces, and also emits a bare
`data-<state>` attribute for each; a consumer-supplied attribute wins
([`utils/render.ts:182`][render-state]).

**Where it lives.** Per component (each assembles its own `ourProps`), plus shared
registries in `components/label/label.tsx` and `components/description/description.tsx`,
`internal/hidden.tsx`, `utils/render.ts`, `utils/focus-management.ts:167`.

**Degradation.** The split is the transferable part. A backend-neutral primitive can
own the facts that are _values_ — this surface is anchored to that trigger, it is or
is not modal, its content is or is not interactive, and a description/label
association as ids — all of which are assertable on a recording canvas. Every role
name and every ARIA attribute must stay in the semantic component, because nothing on
a cell grid consumes them, and `sparkles:ui` emits no ARIA on any backend today. The
genuinely portable insight is `Description`-as-panel-tag: encode "this content may
never be interactive" in the _type_ of the tooltip's content slot so it cannot be
violated. Separately, `data-headlessui-state` is the styling analogue of a sparkles
`Slot` — a small set of boolean state names published for the theme to key on
([`../../specs/ui/index.md`][spec-ui]).

### 14. Animation

Headless UI emits geometry metadata specifically to enable animation, and the set is
deliberately thin: `data-anchor="<side> <align>"` carrying the **resolved** side (so
a flipped panel gets the correct transform origin from CSS without the library
computing one), `--button-width` / `--input-width` as px strings from the `rAF` size
poll, `--anchor-max-height` participating in the `size` middleware's `min()`
([`internal/floating.tsx:320`][floating-maxheight]), and `data-headlessui-state`.

The transition lifecycle emits `data-closed`, `data-enter`, `data-leave` and
`data-transition` from a three-bit flag set, produced by `transitionDataAttributes`,
which turns each true key into a valueless attribute
([`hooks/use-transition.ts:70`][transition-attrs]).

The engine behind it is real. `prepareTransition` forces the "before" classes to
flush by setting `transition: 'none'`, reading `offsetHeight` to trigger reflow, then
restoring ([`:283-302`][transition-prepare]); the run is delayed by one frame with a
recorded explanation about browsers snapping to the end state
([`:241`][transition-nextframe]); completion waits on `getAnimations()` filtered to
`CSSTransition` instances via `Promise.allSettled` of their `.finished`
([`:266`][transition-wait]); and a cancel mid-flight inverts the flags back to the
idle state rather than to the new one.

Repositioning during an exit is _suppressed_, not solved: if the trigger moved while
the panel was closing, `didButtonMove` sets `panelEnabled = false` and the panel is
dropped rather than allowed to chase the anchor. Reduced motion is not handled
anywhere in the package; it is left to the consumer's media query.

**Where it lives.** `hooks/use-transition.ts` (engine and data attributes),
`utils/render.ts` (state attributes), `internal/floating.tsx:329-342` (resolved
side/align → `data-anchor`), per-component width variables.

**Degradation.** The metadata idea survives and is the main takeaway: after placement
resolves, publish the resolved side, the resolved alignment, the anchor's offset
along that side and the trigger's width as plain data on the display-list entry, so
the paint layer can choose a reveal direction, an arrow cell and a matching width
without re-deriving geometry. The engine does not survive: a cell target has no
per-frame interpolation budget worth spending and no transitions to await, and a
recording canvas has no clock. `didButtonMove` — "if the anchor moved while we were
closing, drop the surface rather than animate it toward a stale place" — is portable
and costs one integer-rect comparison per frame. Reduced motion should be an explicit
theme input rather than a discovered property.

### 15. State architecture

An explicit hand-rolled machine layer: not React state, not a third-party FSM
library. `abstract class Machine<State, Event extends {type: number|string}>` holds a
private immutable state, an abstract pure `reduce`, a set of slice subscribers and a
per-event-type subscriber map. `send()` computes the next state, **returns early if
`reduce` returned the same reference**, notifies slice subscribers only when
`shallowEqual(previousSlice, newSlice)` is false, then fires event subscribers
([`machine.ts:66-90`][machine-send]). `shallowEqual` handles `Object.is`, arrays,
`Map`/`Set` by entries, and plain objects ([`:92`][machine-shallow]).

Reducers are dispatch _tables_ keyed by an action enum, selected by `match()` — a
total mapping, so a missing case is a type error — and almost every reducer begins
with an identity guard that returns the same state object. `batch()` coalesces
high-frequency registrations (option register/unregister) into one action per
microtask ([`:144`][machine-batch]). Cross-machine wiring is `machine.on(type, cb)`:
each overlay machine subscribes to the stack machine's `Push`, and opening/closing
pushes/pops.

Two DOM leaks remain inside otherwise-pure reducers: `sortByDomNode` calls
`compareDocumentPosition` from within the ordered-state adjustment, and state fields
hold live elements. Combobox already shows the escape hatch — its options carry an
`order: number | null` and sorting prefers that numeric order when present, falling
back to DOM comparison only when it is null. The Menu reducer additionally carries
hand-written fast paths that consult `previousElementSibling`/`nextElementSibling` to
skip a full re-sort ([`components/menu/menu-machine.ts:176`][menu-fastpath]).

```text
send(e):
    s' = reduce(state, e)
    if s' === state return                       // identity early-out
    state = s'
    for sub in sliceSubscribers:
        slice = sub.selector(s')
        if shallowEqual(sub.current, slice) continue
        sub.current = slice; sub.callback(slice)
    for cb in eventSubscribers[e.type]: cb(s', e)

batch(setup):
    [cb, flush] = setup()
    return (...args) => { cb(...args); dispose(); microTask(flush) }
```

**Where it lives.** `machine.ts` (base class, `shallowEqual`, `batch`),
`machines/stack-machine.ts`, `components/{menu,listbox,combobox,popover}/*-machine.ts`,
`react-glue.tsx` (the only React coupling), `utils/match.ts`.

**Degradation.** This architecture survives a non-DOM, value-semantics,
`@nogc`-leaning toolkit unusually well: `State` becomes a plain struct, the action
set becomes a tagged union, the identity early-outs become field comparisons that let
a caller skip a repaint, and the `shallowEqual`-gated slice notification is what an
immediate-mode toolkit does implicitly by rebuilding its display list. Two things
must change on the way over: replace element references with widget ids and
`compareDocumentPosition` with the integer order that layout already produces (the
direction Combobox's `order` field is already heading), and replace the class plus
subscriber sets with a value type plus an explicit output-effect list, since the
callback graph is the part that would need GC. See
[`../../specs/ui/state-machines.md`][spec-machines] for the existing `sparkles:ui`
machines this would join.

### 16. Shared infrastructure

Factored out and reused by three or more components: the stack machine plus
`useIsTopLayer`; `useOutsideClick`; `useEscape`; `useOnDisappear`; `useScrollLock`;
`useInertOthers`; `useElementSize`; `useTrackedPointer`; `useQuickRelease`;
`useHandleToggle`; `useActivePress`; `Portal` and `useNestedPortals`; `Hidden`;
`FocusTrap` plus `focus-management`; `useTransition` and `transitionDataAttributes`;
`calculateActiveIndex`; the `OpenClosed` context (a four-bit
`Open | Closed | Closing | Opening` flag that lets an outer `Transition` tell an inner
overlay it is about to close, [`internal/open-closed.tsx:5`][open-closed]);
`CloseProvider`/`useClose`; the `Label` and `Description` registries; the
`render`/`mergeProps` machinery; and the whole `FloatingProvider` seam.

Deliberately kept apart: the three focus strategies, none of which is expressed in
terms of the others; each component's own machine and keyboard map; the `modal`
defaults, which differ per component; `PopoverGroup` with `closeOthers`; and
Combobox's virtualization and `hold`.

The biggest structural fact is that **the anchoring seam is React-only**. The Vue
package's dependency list contains no Floating UI at all
([`packages/@headlessui-vue/package.json:52-54`][vue-pkg]), has no `anchor` prop, and
uses a nesting `provide`/`inject` stack context rather than a global stack machine
([`packages/@headlessui-vue/src/internal/stack-context.ts:12`][vue-stack]). The same
"headless overlay" product therefore ships both with and without a positioning
engine — which is itself the answer to "which half is the library".

**Where it lives.** `hooks/*` and `internal/*` for the shared parts; `components/*/`
for the per-pattern parts; `packages/@headlessui-vue/src/internal/stack-context.ts`
for the alternate, engine-free arrangement.

**Degradation.** What this subject's own factoring suggests belongs in one
anchored-overlay primitive: the anchor value and placement config; resolution against
an inset boundary; the ordered stack _per concern_; the dismissal pass with an
explicit handled flag; the open/closed lifecycle including a closing phase; the
resolved-geometry metadata emitted for paint; and the anchor-vanished /
anchor-moved guards. What merely _looks_ common and stays apart: focus policy (a
three-valued mode is fine; one shared implementation is not), timing (only tooltips
have delays), modality defaults, item and roving-selection machinery, and content
interactivity — a tooltip's content must be non-interactive by type while a popover's
must be interactive, and that cannot be one slot. The Vue/React divergence is the
evidence that the positioning engine is a separable half. See
[`./proposal.md`][proposal] for how this maps onto `sparkles:ui`.

---

## Strengths

- `useIsTopLayer(enabled, scope)` — N independent LIFO stacks, one per global
  concern, documented in-source as a userland substitute for the native top layer —
  is a directly reusable answer to "no top layer, no z-index, no compositor".
- Dismissal is a separate capture-phase pass with an explicit veto channel rather
  than a bubbling handler, which is the shape a reverse-paint-order hit list needs.
- Every activation records its provenance (`Pointer` / `Focus` / `Other`) and
  downstream handlers branch on it, so hover and keyboard navigation coexist without
  fighting; `useTrackedPointer` reduces hover intent to a single comparison.
- The `Machine` base class is a portable value-semantics design: enum-keyed reducer
  tables, immutable state, identity early-outs, slice diffing, microtask batching,
  and one small React adapter.
- `focusIn` is a well-factored primitive: a bitmask of intents, a four-valued result,
  wrap/overflow/underflow handled explicitly, and a loop that _verifies_ the focus
  landed instead of assuming it.
- `useOnDisappear` (all-zero rect) and `detectMovement` (`"x,y"` string equality)
  reduce "my anchor vanished" and "my anchor moved" to trivially portable value
  comparisons, and `didButtonMove` turns the second into a concrete rule: drop the
  surface rather than let it chase a stale anchor.
- `useInertOthers` refcounts its mutations and restores the exact prior value — the
  correct discipline for any globally blocked resource shared by nested overlays.
- The unexported Tooltip's four-state × two-input × two-urgency transition table plus
  one global active id degrades soundly to the zero-delay case.
- Comments record _why_: the Safari blur-before-close note, the one-frame transition
  delay, the `transform: false` justification, the VoiceOver `aria-selected`
  deviation and the virtual-keyboard refocus skip are all in-source decision records.
- Encoding "tooltip content may never be interactive" in the panel's default tag
  (`Description`) makes the rule structurally unbreakable rather than merely
  documented.

## Weaknesses

- No positioning engine of its own: the only in-repo placement knowledge is a mapping
  onto Floating UI strings, and the Vue package — lacking the dependency — has no
  `anchor` prop at all.
- No arrow, no caret geometry, no transform origin; a consumer gets the `data-anchor`
  string and nothing else.
- No submenu, no context menu, no hover card, and therefore no safe polygon, pointer
  bridge or menu-aim anywhere in the codebase.
- The in-tree Tooltip panel installs no pointer handlers, so moving into the tooltip
  does not cancel its 300 ms hide — the content is effectively unhoverable.
- Placement scalars are read from CSS custom properties by injecting a temporary
  element and reading back a computed `margin-top`, then `rAF`-polled for changes,
  with a self-documented shadowing bug when a `> *` rule redefines the variable.
- Two unconditional `requestAnimationFrame` polls per open surface, plus a
  `MutationObserver` whose only job is to `Math.ceil` a fractional `max-height`.
- `isPortalled` is a two-stage heuristic (root XOR, then focus-order-neighbour
  inspection) that gates whether the focus sentinels render at all, so Popover's Tab
  behavior depends on a guess.
- Reducers are not pure: `sortByDomNode` calls `compareDocumentPosition` inside the
  ordered-state adjustment, and machine state holds live elements — which is what
  forced the hand-written sibling fast paths.
- `useIsTopLayer` optimistically returns `true` before registration completes, so
  ordering is briefly wrong on the first render.
- Platform adaptation is platform-string sniffing, acknowledged in-source as
  imperfect.
- Overlay arbitration is process-global mutable state: six stacks, two inert maps, a
  focus history and a tooltip store.
- No reduced-motion handling, no max display duration, no navigation-based dismissal,
  and no representation for a viewport inset that is not uniform on all four sides.

## Key design decisions and trade-offs

| Decision                                                                                                                                                                                                          | Rationale                                                                                                                                                                                                                             | Trade-off                                                                                                                                                                                                                                                                                    |
| ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Ship no positioning engine; delegate to Floating UI behind a one-prop `anchor` seam exposing four sides × three alignments plus `gap`/`offset`/`padding`.                                                         | Keeps the library headless in the strict sense and keeps the placement vocabulary small enough to be a value; the resolved side comes back as `data-anchor` so styling can react to a flip without knowing the math.                  | No fallback placement lists, no custom boundaries, no safe-area or virtual-keyboard insets, and no `visualViewport` reference in the package. The Vue package ships the same product with no anchoring at all.                                                                               |
| Replace the native top layer with N scoped LIFO id stacks, one per concern, rather than one overlay tree.                                                                                                         | A Menu inside a Dialog must own Escape while the Dialog still owns modality, scroll lock and the focus trap; one tree cannot express that, and the source states explicitly that this is a conceptual rather than a native top layer. | Registration order is a render-time side effect, so `useIsTopLayer` guesses `true` before it is on the stack and corrects itself later. Six global mutable stacks also make overlay arbitration process-global state that tests must reset.                                                  |
| Detect outside dismissal from paired `pointerdown`/`pointerup` (and `touchstart`/`touchend` with a 30 px cancel) in the capture phase, arbitrated by `defaultPrevented` — never from `click`.                     | Press-inside/release-outside must not dismiss; an intermediate `stopPropagation()` must not suppress dismissal; and an inner overlay needs a way to claim the event so only it closes.                                                | Requires a pointer release, so the whole protocol is disabled on mobile and replaced by the touch pair. It also has to `preventDefault()` the outside press when the target is not focusable, which the source itself flags as a backwards-compatibility choice.                             |
| Keep three different focus strategies rather than unifying them: Dialog traps with a feature bitmask, Popover uses hidden guard sentinels with Tab-direction redirection, Menu/Listbox focus the panel container. | The patterns genuinely differ: a dialog must contain focus, a popover must remain part of the page's tab order, and a listbox must keep one focused element while a selection roves.                                                  | Three implementations to maintain, and Popover's sentinels render only when `isPortalled` — itself a heuristic that can be wrong.                                                                                                                                                            |
| Model overlay state as hand-rolled `Machine` subclasses: enum-keyed reducer tables, immutable state with identity early-outs, `shallowEqual`-gated slices, microtask `batch()`, and `on(type, cb)` wiring.        | Overlay behavior genuinely is a state machine, the reducer table makes every (state, action) pair explicit, and the machines are decoupled from React entirely — `react-glue.tsx` is the only coupling point.                         | Two DOM leaks remain inside otherwise-pure reducers, which is what forced the per-reducer sibling fast paths. Combobox's numeric `order` field is the acknowledged fix, not yet applied everywhere.                                                                                          |
| Emit placement and lifecycle as data attributes (`data-anchor`, `data-closed/enter/leave/transition`, `data-headlessui-state`, `--button-width`) and compute no transform origin.                                 | Animation is a styling concern; the library's job is to publish the resolved facts CSS cannot derive by itself.                                                                                                                       | Consumers must write the origin and arrow CSS themselves, and the width variable is kept fresh by an unconditional per-frame `getBoundingClientRect()` poll, chosen because a `transform: scale` would not fire a `ResizeObserver`.                                                          |
| Adapt the interaction protocol per platform but never the presentation, and let each component own its own adaptation.                                                                                            | Small, auditable, and keeps the DOM identical across platforms: `useIsTouchDevice()` drops only `InitialFocus` in Dialog; `isMobile()` only skips the pointer outside-click path and the input refocus.                               | Platform-string sniffing is admitted in-source to be imperfect, and it gates on device type rather than on how the surface was opened. "Avoid provoking the soft keyboard" is also not the same as "account for the keyboard inset in placement", which this placement model cannot express. |
| Write a complete Tooltip with a delay machine and a global skip-delay singleton, then leave it unexported.                                                                                                        | Not stated in the source beyond `// TODO: Enable when ready`. The structure suggests the hover-only interaction is the unfinished part — the panel as implemented is not hoverable, since entering it does not cancel the hide.       | The best-developed timing machine in the repository ships to nobody, and it is not the reason for the two `@react-aria` dependencies, which the shipped components also use.                                                                                                                 |

## Sources

Primary sources, all read at
`eea57cf46fd6767ed1059012f7073b88eb159fba` under `packages/@headlessui-react/src/`
unless noted:

- The anchoring seam — [`internal/floating.tsx`][floating-anchorprops]: `AnchorProps`,
  `useResolvedAnchor`, `useFloatingReference`, the middleware composition, the
  resolved-side read-back, `useFixScrollingPixel`, and the CSS-variable resolver.
- Arbitration — [`machines/stack-machine.ts`][stack-map] and
  [`hooks/use-is-top-layer.ts`][top-layer].
- Dismissal — [`hooks/use-outside-click.ts`][outside-click],
  [`hooks/use-escape.ts`][escape], [`hooks/use-on-disappear.ts`][disappear],
  [`utils/element-movement.ts`][movement-pos].
- Focus — [`utils/focus-management.ts`][focus-in],
  [`components/focus-trap/focus-trap.tsx`][focus-trap-features],
  [`utils/active-element-history.ts`][focus-history].
- Modality — [`hooks/use-inert-others.tsx`][inert-refcount] and its test file.
- Timing — [`components/tooltip/tooltip.tsx`][tooltip-state] (unexported, see
  [`index.ts:25`][index-tooltip]).
- State — [`machine.ts`][machine-class] and the four component machines.
- Triggers — [`hooks/use-handle-toggle.tsx`][handle-toggle],
  [`hooks/use-active-press.tsx`][active-press-rect],
  [`hooks/use-tracked-pointer.ts`][tracked-pointer],
  [`hooks/use-quick-release.ts`][quick-release].
- Animation — [`hooks/use-transition.ts`][transition-attrs],
  [`utils/render.ts`][render-state].
- The Vue arrangement — [`packages/@headlessui-vue/package.json`][vue-pkg],
  [`packages/@headlessui-vue/src/internal/stack-context.ts`][vue-stack].

> [!IMPORTANT]
> **Not read, and therefore not claimed.** The flip / shift / size / inner /
> `autoUpdate` arithmetic lives in `@floating-ui/react`, a `node_modules` dependency
> that was not part of this clone; every statement above about overflow detection,
> clipping-ancestor discovery, RTL handling of `-start`/`-end`, and continuous
> tracking is attributed to that package _by import site only_. See
> [`./floating-ui.md`][floating-ui-page] for a reading of that engine.
> `@react-aria/focus` and `@react-aria/interactions` supply hover and focus-ring
> state to every trigger and were likewise not read — see
> [`./react-aria.md`][react-aria]. No tests were executed; test evidence is from
> reading titles and bodies. The Vue package was spot-checked only (its `internal/`
> listing, `stack-context.ts`, and the absence of a Floating UI dependency), so the
> claims about Vue are limited to those facts.

### Cross-references

- [`./index.md`][index] — the catalog umbrella and the 16-dimension spine.
- [`./concepts.md`][concepts] — shared vocabulary: anchor rect, placement, gravity,
  constraint adjustment, flip/shift/slide/resize, clipping boundary, top layer, light
  dismiss, grab, safe polygon, warm-up, cool-down, focus scope, modality, virtual
  anchor, transform origin.
- [`./comparison.md`][comparison] — the capstone comparison across subjects.
- [`./features-people-forget.md`][forget] — the edge-case catalog this subject feeds
  (paired pointerdown/pointerup, the 30 px touch cancel, movement-gated hover
  activation, the anchor-moved suppression, the all-zero-rect anchor test, the Safari
  blur-before-close, refcounted inert marking, focus-landing verification).
- [`./floating-ui.md`][floating-ui-page] — the engine this subject delegates to.
- [`./react-aria.md`][react-aria] — the hover/focus-ring dependency, and an
  alternative arrangement of the same responsibilities.
- [`./base-ui.md`][base-ui], [`./radix.md`][radix], [`./ariakit.md`][ariakit],
  [`./zag.md`][zag] — the other headless-behavior subjects.
- [`./popover-api.md`][popover-api] — the platform top layer this subject explicitly
  declines to use.
- [`./sparkles-baseline.md`][baseline] and [`./proposal.md`][proposal] — where these
  mechanisms land in `sparkles:ui`.
- [`../window-system-integration/index.md`][wsi] — the OS-surface side of the same
  problem.

<!-- References -->

[lic]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/LICENSE#L3
[pkg-version]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/package.json#L3
[pkg-deps]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/package.json#L59
[index-tooltip]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/index.ts#L25
[top-layer]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/hooks/use-is-top-layer.ts#L6
[top-layer-optimistic]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/hooks/use-is-top-layer.ts#L65
[stack-map]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/machines/stack-machine.ts#L72
[stack-push]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/machines/stack-machine.ts#L22
[outside-click]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/hooks/use-outside-click.ts#L21
[outside-dp]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/hooks/use-outside-click.ts#L40
[outside-threshold]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/hooks/use-outside-click.ts#L19
[outside-down]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/hooks/use-outside-click.ts#L108
[outside-up]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/hooks/use-outside-click.ts#L119
[outside-capture]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/hooks/use-outside-click.ts#L132
[outside-touchend]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/hooks/use-outside-click.ts#L152
[outside-blur]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/hooks/use-outside-click.ts#L179
[escape]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/hooks/use-escape.ts#L5
[disappear]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/hooks/use-on-disappear.ts#L13
[movement-pos]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/utils/element-movement.ts#L15
[movement-detect]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/utils/element-movement.ts#L20
[floating-anchorprops]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/internal/floating.tsx#L43
[floating-resolved-anchor]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/internal/floating.tsx#L99
[floating-reference]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/internal/floating.tsx#L109
[floating-dataanchor]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/internal/floating.tsx#L122
[floating-stable]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/internal/floating.tsx#L136
[floating-default]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/internal/floating.tsx#L183
[floating-split]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/internal/floating.tsx#L189
[floating-transform]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/internal/floating.tsx#L213
[floating-shift]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/internal/floating.tsx#L232
[floating-flip]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/internal/floating.tsx#L237
[floating-maxheight]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/internal/floating.tsx#L320
[floating-autoupdate]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/internal/floating.tsx#L325
[floating-exposed]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/internal/floating.tsx#L329
[floating-fixpixel]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/internal/floating.tsx#L373
[floating-poll]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/internal/floating.tsx#L473
[element-size]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/hooks/use-element-size.ts#L11
[handle-toggle]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/hooks/use-handle-toggle.tsx#L6
[active-press-rect]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/hooks/use-active-press.tsx#L9
[active-press-ios]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/hooks/use-active-press.tsx#L68
[tracked-pointer]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/hooks/use-tracked-pointer.ts#L9
[quick-release]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/hooks/use-quick-release.ts#L29
[inert-refcount]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/hooks/use-inert-others.tsx#L6
[inert-walk]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/hooks/use-inert-others.tsx#L97
[main-tree]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/hooks/use-root-containers.tsx#L90
[portal-target]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/components/portal/portal.tsx#L38
[portal-marker]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/components/portal/portal.tsx#L116
[portal-nested]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/components/portal/portal.tsx#L208
[focus-in]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/utils/focus-management.ts#L235
[focus-in-verify]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/utils/focus-management.ts#L317
[focus-in-select]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/utils/focus-management.ts#L328
[focus-trap-features]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/components/focus-trap/focus-trap.tsx#L53
[focus-history]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/utils/active-element-history.ts#L5
[hidden]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/internal/hidden.tsx#L7
[open-closed]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/internal/open-closed.tsx#L5
[machine-class]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/machine.ts#L5
[machine-send]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/machine.ts#L66
[machine-shallow]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/machine.ts#L92
[machine-batch]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/machine.ts#L144
[render-aria]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/utils/render.ts#L161
[render-state]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/utils/render.ts#L182
[render-handlers]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/utils/render.ts#L345
[transition-attrs]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/hooks/use-transition.ts#L70
[transition-nextframe]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/hooks/use-transition.ts#L241
[transition-wait]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/hooks/use-transition.ts#L266
[transition-prepare]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/hooks/use-transition.ts#L283
[tooltip-state]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/components/tooltip/tooltip.tsx#L46
[tooltip-store]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/components/tooltip/tooltip.tsx#L69
[tooltip-reducers]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/components/tooltip/tooltip.tsx#L111
[tooltip-delays]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/components/tooltip/tooltip.tsx#L211
[tooltip-timers]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/components/tooltip/tooltip.tsx#L237
[tooltip-upgrade]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/components/tooltip/tooltip.tsx#L252
[tooltip-visible]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/components/tooltip/tooltip.tsx#L281
[tooltip-mousemove]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/components/tooltip/tooltip.tsx#L375
[tooltip-describedby]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/components/tooltip/tooltip.tsx#L385
[tooltip-panel-tag]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/components/tooltip/tooltip.tsx#L411
[tooltip-panel]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/components/tooltip/tooltip.tsx#L424
[menu-modal]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/components/menu/menu.tsx#L358
[menu-keyup]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/components/menu/menu.tsx#L221
[menu-didmove]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/components/menu/menu.tsx#L429
[menu-stack-close]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/components/menu/menu-machine.ts#L398
[menu-fastpath]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/components/menu/menu-machine.ts#L176
[listbox-modal]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/components/listbox/listbox.tsx#L525
[listbox-keyup]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/components/listbox/listbox.tsx#L409
[listbox-inner]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/components/listbox/listbox.tsx#L621
[listbox-typeahead]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/components/listbox/listbox.tsx#L725
[listbox-buttonwidth]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/components/listbox/listbox.tsx#L753
[combobox-modal]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/components/combobox/combobox.tsx#L1187
[combobox-hold]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/components/combobox/combobox.tsx#L1184
[combobox-vk]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/components/combobox/combobox.tsx#L1509
[popover-symbol]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/components/popover/popover.tsx#L370
[popover-focusout]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/components/popover/popover.tsx#L206
[popover-keyup]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/components/popover/popover.tsx#L440
[popover-modal]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/components/popover/popover.tsx#L703
[popover-rotate]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/components/popover/popover.tsx#L880
[popover-rightclick]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/components/popover/popover.test.tsx#L2245
[dialog-escape]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/components/dialog/dialog.tsx#L246
[dialog-ariamodal]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/components/dialog/dialog.tsx#L288
[dialog-touch]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/components/dialog/dialog.tsx#L294
[platform]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/utils/platform.ts#L1
[vue-pkg]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-vue/package.json#L52
[vue-stack]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-vue/src/internal/stack-context.ts#L12
[index]: ./index.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[forget]: ./features-people-forget.md
[baseline]: ./sparkles-baseline.md
[proposal]: ./proposal.md
[floating-ui-page]: ./floating-ui.md
[react-aria]: ./react-aria.md
[base-ui]: ./base-ui.md
[radix]: ./radix.md
[ariakit]: ./ariakit.md
[zag]: ./zag.md
[popover-api]: ./popover-api.md
[apg]: ./aria-apg.md
[wsi]: ../window-system-integration/index.md
[platform-guidelines]: ../platform-ui-guidelines/index.md
[spec-ui]: ../../specs/ui/index.md
[spec-input]: ../../specs/ui/input.md
[spec-containers]: ../../specs/ui/containers.md
[spec-machines]: ../../specs/ui/state-machines.md
[spec-ui-app]: ../../specs/ui-app/index.md
