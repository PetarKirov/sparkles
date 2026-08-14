# Tippy.js (TypeScript / web)

Tippy v6 contributes almost no geometry of its own — it configures Popper 2 and spends its 1145 lines on the part Popper refuses to answer: _when_ an anchored surface appears, stays, and goes away.

| Field             | Value                                                                                                                                                                                                                    |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Language          | TypeScript (ES2015 DOM, framework-free)                                                                                                                                                                                  |
| License           | MIT                                                                                                                                                                                                                      |
| Repository        | [`atomiks/tippyjs`][tippy-repo]                                                                                                                                                                                          |
| Documentation     | In-repo VitePress-era docs under `website/src/pages/v6/`, published as [atomiks.github.io/tippyjs/v6][tippy-site]. Read as documentation, not as implementation.                                                         |
| Category          | Web / mature tooltip-popover library — an imperative controller layered over a third-party positioning engine                                                                                                            |
| Surface model     | In-canvas. The overlay is a plain `<div>` appended into the same document (`document.body` by default, `reference.parentNode` when `interactive`). No OS popup, no [top layer][concepts], `zIndex` defaulting to `9999`. |
| **Revision read** | `ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1` — v6.3.7 (`package.json:3`)                                                                                                                                                   |

## Overview

### What it solves

Tippy markets itself in one line — `"The complete tooltip, popover, dropdown, and menu solution for the web"` ([`package.json:4`][pkg]) — and delivers all four from a single factory, `createTippy`, whose variation surface is props rather than components. Positioning is delegated wholesale to `@popperjs/core`; what tippy owns is the interaction envelope around a positioned box: which DOM events count as a trigger, how long to wait before showing or hiding, whether the pointer travelling from trigger to content should keep the surface open, what counts as an outside press versus a scroll, when the surface becomes non-hit-testable, and what geometry metadata the stylesheet is allowed to see.

The value of reading it is not its architecture. It is the accumulated corpus of interaction edge cases: roughly forty small private functions inside one closure, several of which read as hand-tuned answers to a single bug report — their comments name the exact failure they prevent — plus a set of undocumented policy overrides that exist because a naive implementation felt wrong in practice.

### Design philosophy

The philosophy is legible in the file layout: one closure, a public five-boolean `state` record, about eleven private mutable flags, and no transition table anywhere. Where a state machine would encode a rule, tippy encodes an ordering of guards. The clearest single artefact is the delay policy, which silently returns zero in three unrelated situations:

> ```ts
> // For touch or keyboard input, force `0` delay for UX reasons
> // Also if the instance is mounted but not visible (transitioning out),
> // ignore delay
> if (
>   (instance.state.isMounted && !instance.state.isVisible) ||
>   currentInput.isTouch ||
>   (lastTriggerEvent && lastTriggerEvent.type === 'focus')
> ) {
>   return 0;
> }
> ```
>
> — `src/createTippy.ts:199-208`, [`getDelay`][ct-getdelay]

The second philosophical commitment is that the surface publishes its geometry rather than consuming it. A private Popper modifier named `$$tippy` exists for no other purpose than to copy the resolved [placement][concepts] and two overflow verdicts onto the styled box as `data-*` attributes, and then to blank Popper's own attribute map so the engine will not stamp them on the root ([`src/createTippy.ts:608-631`][ct-modifier]). Everything visual — [transform origin][concepts], the arrow triangle, the enter/exit interpolation — is downstream CSS reading that data.

The third is scope discipline. There is no [modality][concepts], no focus trap, no list or menu keyboard model, and — see dimension 8 — no Escape handling at all. Tippy provides the surface and declines to provide the content's interaction model.

> [!IMPORTANT]
> `@popperjs/core` is a runtime dependency and is **not vendored in the clone read for this page**. Everything stated here about flip, shift, overflow detection, clipping-ancestor discovery or transform handling is limited to (a) the configuration tippy passes and (b) the values tippy reads back (`state.placement`, `state.modifiersData.offset`, `state.attributes.popper`). No claim below is an implementation reading of Popper.

## How it works

`createTippy(reference, passedProps)` evaluates props once into a closure constant (`const props = evaluateProps(...)`, [`src/createTippy.ts:49`][ct-props]), allocates the private flags ([`:56-73`][ct-private]) and the public `state` record ([`:78-89`][ct-state]), renders the template, and binds listeners derived from the `trigger` string. Nothing is positioned until `show()` runs.

**Popper configuration.** `createPopperInstance` builds the anchor, then a fixed modifier stack with hard-coded padding constants, then appends whatever the user passed:

```ts
// src/createTippy.ts:637-680 (abridged)
const modifiers = [
  { name: 'offset', options: { offset } }, // default [0, 10]
  {
    name: 'preventOverflow',
    options: { padding: { top: 2, bottom: 2, left: 5, right: 5 } },
  },
  { name: 'flip', options: { padding: 5 } },
  { name: 'computeStyles', options: { adaptive: !moveTransition } },
  tippyModifier, // the $$tippy projector
];
if (getIsDefaultRenderFn() && arrow) {
  modifiers.push({ name: 'arrow', options: { element: arrow, padding: 3 } });
}
modifiers.push(...(popperOptions?.modifiers || []));
```

The asymmetric `preventOverflow` padding, the `flip` padding of 5 and the `arrow` padding of 3 carry no explanation in source and no mention on the props page ([`src/createTippy.ts:637-680`][ct-modifiers]). Because user modifiers are appended last, a user entry with the same `name` wins — pinned by a snapshot test over `orderedModifiers` ([`test/integration/props.test.js:988-1022`][test-modifiers]).

**Mount ordering.** `show()` deliberately performs a two-phase mount: it forces transition durations to zero and suppresses transitions _before_ the element is parented, so a re-show after a flip does not animate from the stale side; then Popper's `onFirstUpdate` callback forces a reflow (`void popper.offsetHeight`), restores `moveTransition`, applies the real durations, flips `data-state` to `visible`, attaches the ARIA relationship, registers the instance in the module-global mounted list, calls `forceUpdate()` a second time for modifiers that need post-placement measurements, and only then fires `onMount` ([`src/createTippy.ts:967-1015`][ct-firstupdate]).

```text
show()          durations := 0; transition := 'none'; addDocumentPress()
  mount()       parent := interactive && default ? currentTarget.parentNode : appendTo(currentTarget)
                appendChild; isMounted := true; createPopperInstance()
  onFirstUpdate reflow; transition := moveTransition; durations := duration
                data-state := 'visible'; aria; mountedInstances += this
                popperInstance.forceUpdate(); invokeHook('onMount')
  transitionend isShown := true; invokeHook('onShown')
```

The ordering is worth naming independently of its DOM mechanics: **geometry is resolved before the surface is announced to accessibility and before any `mounted` observer runs.**

**Two listener families, one live.** The mouse/focus family is bound from the `trigger` string; a `touchstart`/`touchend` pair is bound in addition when — and only when — `touch: 'hold'` is configured ([`:429-433`][ct-addlisteners]). Which family is live at any instant is then decided by a single expression against a document-wide pointer mode ([`:581-585`][ct-stopped]); see dimension 12.

## The analysis spine

### 1. Anchor model

Internally there is exactly one anchor representation and it is a **callback, not a value**. `createPopperInstance` builds a `computedReference` that is either the reference `Element` itself (an `Element` already satisfies the shape, since it has `getBoundingClientRect`) or an object literal wrapping the user's function plus a `contextElement` that exists only so Popper can find scroll parents ([`src/createTippy.ts:600-606`][ct-computedref]):

```ts
const computedReference = getReferenceClientRect
  ? {
      getBoundingClientRect: getReferenceClientRect,
      contextElement:
        getReferenceClientRect.contextElement || getCurrentTarget(),
    }
  : reference;
```

Every exotic anchor in the library is that one function, swapped. A [virtual anchor][concepts] is `getReferenceClientRect` supplied by the caller (`src/types.ts:60`). `followCursor` sets it to a closure over the last `clientX`/`clientY` ([`src/plugins/followCursor.ts:51-91`][fc]). `inlinePositioning` sets it to a function that folds the multi-rect `getClientRects()` of a wrapped inline element into one rect chosen by the _current_ placement ([`src/plugins/inlinePositioning.ts:112-178`][inline-rect]). `createSingleton` sets it to `() => references[index].getBoundingClientRect()` so one surface re-anchors to N triggers ([`src/addons/createSingleton.ts:135-139`][singleton-prepare]). `sticky` re-reads the same function every animation frame ([`src/plugins/sticky.ts:23-46`][sticky]).

Trigger and anchor are decoupled: `triggerTarget` may be one element or many while `reference` remains the geometric [anchor rect][concepts] source, and `getCurrentTarget()` returns whichever trigger last fired ([`:185-187`][ct-currenttarget], assigned in `onTrigger` at `:477`). It is the _current target_, not the reference, that decides the mount parent and the owner document.

Text-range anchoring exists only as the inline special case, and it is genuinely a multi-rect fold:

```text
anchorRect(placement):
    rects = element.getClientRects()
    if rects.length < 2                              -> boundingRect
    if rects.length == 2 and disjoint and cursorRect -> the rect the cursor was in at trigger time
    if placement is top|bottom -> {top: first.top, bottom: last.bottom,
                                   left/right: taken from first (top) or last (bottom)}
    if placement is left|right -> {left: min(all.left), right: max(all.right),
                                   top/bottom: spanning the rects touching that extreme column}
```

**Where the behavior lives.** Library code chooses the shape; Popper consumes it; the DOM produces the rects. Neither the accessibility layer nor any compositor participates.

**Degradation.** The callback is the part that does not survive: with no script, an anchor can only be a static ancestor/sibling relationship in markup. The rest generalises cleanly, because at the placement seam an anchor is fully described by a rect plus an identity for comparison. The callback buys re-evaluation per frame — which an immediate-mode toolkit gets for free, since `view()` reruns — so it appears to be retained-mode tax rather than a portable idea. Tippy is nonetheless a live witness that a per-frame re-read anchor is a legitimate _policy_ (`followCursor`, `sticky`), not a defect; see [`./concepts.md`][concepts] on tracking policies and [`./sparkles-baseline.md`][baseline] for what sparkles already produces.

### 2. Placement model

Tippy owns almost none of this dimension. It forwards `placement` (Popper's twelve physical values, `side` or `side-start|end`) and an `offset` that is either `[skidding, distance]` or a function of the placement and the two rects, defaulting to `[0, 10]` ([`src/props.ts:29-60`][props-defaults]). What it does own is the padding policy quoted above, plus one CSS clamp that is arithmetic nowhere in the source: `max-width: calc(100vw - 10px)` on the popper root ([`src/scss/index.scss:6-8`][scss-root]).

Absent, and the absences are findings: there is no RTL or logical-placement layer, no writing-mode awareness, no safe-area insets, no work-area or multi-monitor concept (there is one document viewport), and no soft-keyboard avoidance anywhere in the tree. Custom [clipping boundaries][concepts] exist only as Popper's `boundary`/`rootBoundary` passthrough.

**Algorithm.** Not present in this repository. Flip, shift and hide are Popper's; tippy's contribution is the ordered modifier list and the two top-level options (`placement`, `onFirstUpdate`).

**Where the behavior lives.** Third-party engine, plus a hard-coded configuration block, plus one stylesheet rule.

**Degradation.** Everything in this dimension is rect arithmetic and survives every target unchanged. The two DOM-specific pieces are the CSS clamp — which must become explicit width clamping in layout — and the missing inset model. The asymmetric `preventOverflow` padding is a useful precedent in the other direction: viewport padding is per-side in a shipping library, not a scalar.

### 3. Collision and geometry engine

Overflow detection, clipping-ancestor discovery, scroll-parent listeners and transform handling are Popper's and are not verifiable here. What is observable is how tippy _consumes_ the results and what it pays to keep them fresh.

1. **Verdicts become styling data, never transitions.** The `$$tippy` modifier projects `data-reference-hidden` and `data-escaped` onto the box ([`:608-631`][ct-modifier]). "The anchor scrolled out of its clipping rect" is thus available to CSS and to assertions, and tippy never auto-hides on it.
2. **Tracking is per-feature and inconsistent.** The default is Popper's own scroll/resize listeners. `sticky` is an unbounded `requestAnimationFrame` poll comparing four numbers and calling `popperInstance.update()` on any difference ([`src/plugins/sticky.ts:23-46`][sticky], `areRectsDifferent` at [`:60-74`][sticky-diff] — an exact float compare of `top/right/bottom/left`, width and height ignored). `followCursor` calls the full `setProps()` path on every `mousemove`, which internally removes and re-adds every listener and destroys and recreates the Popper instance ([`src/plugins/followCursor.ts:65`][fc] → [`src/createTippy.ts:849-899`][ct-setprops]).
3. **A forced second pass exists**, commented as needed because "certain modifiers (e.g. `maxSize`) require a second update after the popper has been positioned for the first time" ([`:1001-1003`][ct-firstupdate]).
4. **Oscillation is real and guarded.** With a multi-rect anchor the rect depends on the placement and the placement depends on the rect; `inlinePositioning` keeps a visited set of tried placements that clears when a placement repeats ([`src/plugins/inlinePositioning.ts:33,44-58`][inline-modifier]; commit `3598727`, "fix(inlinePositioning): infinite loop").

```text
sticky poll (per animation frame, while mounted):
    r := anchorRect()  if checking 'reference'
    p := popperRect()  if checking 'popper'
    if r != prevR || p != prevP: popperInstance.update()
    prevR, prevP := r, p
```

**Where the behavior lives.** Third-party engine for the math; library code for the tracking loops and the verdict projection; the browser layout engine for rect production.

**Degradation.** The rect math is integer-friendly and needs no compositor. The tracking layer does not generalise and does not need to: a toolkit that rebuilds `view → layout → display list` every frame has "sticky" by construction and needs neither polling, observers, nor forced second passes. The idea worth carrying is (1): make "anchor is clipped away" and "surface escaped its boundary" explicit _outputs_ of placement rather than hidden internal state — on a headless recording canvas both are assertable per frame.

### 4. Arrow / caret geometry

Arrow geometry is emphatically **not data** in tippy. `render()` creates a `<div>` with the arrow class — or an SVG wrapper for the round-arrow variant — as a child of the box ([`src/template.ts:20-36,132-141`][tpl-arrow]), and `createPopperInstance` registers it with Popper's arrow modifier at `padding: 3` only when the default render function is in use. Popper writes the along-axis offset as an inline style. Everything else — the cross-axis side, the triangle itself, the transform origin — is stylesheet rules keyed on the projected attribute with a prefix selector, `[data-placement^='top']` and friends ([`src/scss/index.scss:22-63`][scss-placement]).

Two museum details follow directly from that split:

- A **bordered** arrow needs two stacked triangles: `border.scss` adds an `::after` triangle offset by 8px behind the `::before` triangle offset by 7px, plus per-side 1px nudges for the SVG variant ([`src/scss/border.scss:5-40,51-74`][scss-border]).
- The **SVG** arrow needs hand-tuned per-side pixel constants (`top: 16px; transform: rotate(180deg)`, `top: calc(50% - 3px); left: 11px`) because a rotated SVG cannot be expressed by the border trick ([`src/scss/svg-arrow.scss:3-45`][scss-svg]).

The arrow size does not feed the offset: the default distance of 10 and the `$arrow-size` of 16 are unrelated constants. The only datum crossing the JS/CSS seam is the placement string, and alignment is deliberately discarded by the `^=` prefix match.

**Where the behavior lives.** Split three ways — element creation in library code, along-axis offset in the engine, everything visual in the stylesheet — and exposed programmatically nowhere.

**Degradation.** Without sub-cell precision an arrow is one character cell holding a directional glyph or a box-drawing junction, which makes it a **layout participant**: it consumes a row or column of the gap, so unlike tippy the arrow size must feed the offset. The three-way split is the anti-pattern; the SVG pixel constants are what it costs. Emitting `{side, alongAxisOffset, clampedToCorner}` as display-list data lets each backend render it and lets the recording canvas assert it — see [`./features-people-forget.md`][forgotten] and the arrow findings in [`./sparkles-baseline.md`][baseline].

### 5. Trigger semantics

`trigger` is a space-separated string, split and bound verbatim, each event paired with its opposite: `mouseenter`↔`mouseleave`, `focus`↔`blur` (`focusout` on IE11), `focusin`↔`focusout`; `manual` binds nothing. Every bound event routes to one entry point, `onTrigger` ([`src/createTippy.ts:429-454`][ct-addlisteners], [`:463-509`][ct-ontrigger]).

There is no focus-visible distinction, no `contextmenu` trigger, no keyboard shortcut and no assistive-technology path. Races between triggers are resolved by four collaborating flags rather than by a machine:

- `isVisibleFromClick`, set on every click trigger;
- `lastTriggerEvent`, read as `wasFocused` so the click that follows a focus-triggered show does not immediately close it ([`:474`][ct-ontrigger], `:506`);
- `didHideDueToDocumentMouseDown`, a one-macrotask veto so the `focus` event generated by a dismissing `mousedown` cannot re-show ([`:469`][ct-ontrigger], set at [`:337-344`][ct-docpress]);
- `currentTarget`, which trigger element is live.

```text
onTrigger(e):
    if !isEnabled || isEventListenerStopped(e) || didHideDueToDocumentMouseDown: return
    wasFocused := lastTriggerEvent?.type == 'focus'
    lastTriggerEvent := e ; currentTarget := e.currentTarget ; syncAriaExpanded()
    if !visible && isMouseEvent(e): for each global mouseMoveListener -> call(e)
    shouldClickHide := e.type == 'click'
                       && (trigger lacks 'mouseenter' || isVisibleFromClick)
                       && hideOnClick !== false && visible
    if !shouldClickHide: scheduleShow(e)
    if e.type == 'click': isVisibleFromClick := !shouldClickHide
    if shouldClickHide && !wasFocused: scheduleHide(e)
```

A separate interception lives in `scheduleHide`: when the trigger list contains both `mouseenter` and `click` and the surface is currently visible-from-click, hover-driven hides are swallowed ([`:803-810`][ct-schedhide]).

**Where the behavior lives.** Entirely library code over raw DOM listeners. No platform primitive, no framework kernel.

**Degradation.** Hover triggers vanish on a touch-only target. Static HTML has only `:hover`, `:focus-within` and `:checked`. The transferable shape is tippy's, not its flags: one trigger entry point receiving an already-normalised event, with races resolved by an explicit record of _why_ the surface is open rather than by a pile of booleans. The structure suggests an `openCause` value plus the identity of the live trigger would subsume most of these flags — but the survey's verification pass found that an open-cause enum alone is **not** sufficient to derive every cross-trigger suppression rule in the corpus, so the live trigger's identity (tippy's `currentTarget`) has to travel with it. See [`./comparison.md`][comparison].

### 6. Timing

`delay` is a scalar or a `[show, hide]` tuple; a `null` element falls back to the default for that index, so `[100, null]` means "custom show delay, default hide delay" ([`src/utils.ts:10-25`][utils-index]). Three overrides force zero — mid-exit re-entry, touch input, and a `focus`-caused show — and none of them is mentioned on the `delay` documentation page in this tree ([`website/src/pages/v6/all-props.mdx:291-315`][docs-delay]).

Touch-hold has its own delay channel: `touch: ['hold', ms]` replaces the show delay only while the pointer mode is touch ([`:773-777`][ct-schedshow]). The zero-hide-delay path is not synchronous — it goes through `requestAnimationFrame`, commented as fixing "a transitionend problem when it fires 1 frame too late sometimes" ([`:821-826`][ct-schedhide]).

There is no [warm-up][concepts] separate from the show delay, and no [cool-down][concepts] or skip-delay shared across a group of triggers. What substitutes for a cool-down is the `createSingleton` addon: one instance stays mounted while `prepareInstance` swaps its content and anchor, so moving between neighbours re-uses an already-shown surface with no re-entry animation. There is no maximum display duration anywhere in the tree.

```text
The machine tippy approximates with two timers and four booleans:
    states  Idle | ShowPending(deadline) | Open | HidePending(deadline) | Closing(anim)
    trigger-on  in Idle        -> ShowPending(now + showDelay)
                                  showDelay = 0 if cause == focus
                                                or pointerMode == touch
                                                or phase == Closing      (tippy's rule)
                in HidePending -> Open      (cancel timer)
                in Closing     -> Open with delay 0
    trigger-off in Open        -> HidePending(now + hideDelay)
                in ShowPending -> Idle      (cancel)
```

**Where the behavior lives.** Library code over `setTimeout`/`requestAnimationFrame`. `clearDelayTimeouts` clears both timers plus the pending frame callback ([`:843-847`][ct-cleardelays]) and runs at the head of both schedulers.

**Degradation.** With no timers, the dimension collapses to `transition-delay` on `:hover` — which is exactly why the delay must be expressible as data (milliseconds) rather than as scheduler calls. On a recording canvas every timer needs an injected clock to be assertable; tippy's raw `setTimeout` is precisely what makes its own suite depend on fake timers. One small discipline is worth copying verbatim: `debounce` returns the raw function when `ms === 0` rather than arming a zero-length timer ([`src/utils.ts:36-42`][utils-debounce]). The transferable insight of the dimension is the delay policy itself — delay is a function of `(cause, pointer mode, current phase)`, never a constant.

### 7. Interactive hover

The headline algorithm, and it is deliberately **not** a [safe polygon][concepts]. Travel from trigger to content is protected by an axis-aligned expanded-box test evaluated on document `mousemove`.

The path: the reference's `mouseleave` reaches `onMouseLeave`, which for an interactive instance calls `hideWithInteractivity(event)`; that registers a debounced tester on the document, pushes it into a module-global registry, and invokes it immediately with the `mouseleave` event ([`:544-559`][ct-mouseleave], [`:1077-1089`][ct-hidewith]). `onMouseMove` first bails when a genuine `mousemove` lands inside the current trigger or the popper — a cheap containment fast path ([`:511-518`][ct-mousemove]) — which the immediate `mouseleave` invocation skips by construction, going straight to geometry. It then materialises `popperTreeData` for `getNestedPopperTree().concat(popper)` — every nested root inside this popup's content, i.e. open submenus — and requires the cursor to be outside **all** of them:

> ```ts
>   return popperTreeData.every(({popperRect, popperState, props}) => {
> ```
>
> — `src/dom-utils.ts:78`, [`isCursorOutsideInteractiveBorder`][du-border]

Per surface, the keep-open region is the popup rect grown by `interactiveBorder` on all four sides **and additionally by the Popper offset distance on the side facing the anchor** — so the default 10px gap between anchor and content is inside the keep-open region and the pointer may cross it:

> ```ts
> const topDistance = basePlacement === 'bottom' ? offsetData.top!.y : 0;
> const bottomDistance = basePlacement === 'top' ? offsetData.bottom!.y : 0;
> const leftDistance = basePlacement === 'right' ? offsetData.left!.x : 0;
> const rightDistance = basePlacement === 'left' ? offsetData.right!.x : 0;
>
> const exceedsTop = popperRect.top - clientY + topDistance > interactiveBorder;
> ```
>
> — `src/dom-utils.ts:87-93`

Temporal tolerance is stacked on the spatial one and the documentation frames it exactly that way: `interactiveDebounce` "Offers a temporal (rather than spacial) alternative to `interactiveBorder`" ([`website/src/pages/v6/all-props.mdx:595`][docs-debounce]). `debounce` is rebuilt whenever the prop changes. Re-entering the popup clears pending hide timers through a `mouseenter` listener on the popper itself; leaving it re-arms the document tester ([`:151-164`][ct-popperlisteners]).

```text
keepOpen(cursor c) = OR over open surfaces s of inside(c, grow(s.rect, border, s.side, gap))
grow(r, b, side, gap):
    r.left   -= b + (side == right  ? gap : 0)
    r.right  += b + (side == left   ? gap : 0)
    r.top    -= b + (side == bottom ? gap : 0)
    r.bottom += b + (side == top    ? gap : 0)
cost: 4 integer compares per open surface, zero allocation, no history, no trajectory
```

Three traps, all verified in this tree:

> [!WARNING]
> The `props` captured into `popperTreeData` is the **closure constant** created at construction ([`:49`][ct-props]), not `instance.props` and not the nested instance's props ([`:530`][ct-mousemove]). An `interactiveBorder` changed through `setProps` is therefore ignored, and nested surfaces are tested with the _outer_ instance's border.

- With no `modifiersData.offset` the surface is treated as outside — the guard returns `true` early ([`src/dom-utils.ts:83-85`][du-border]).
- The library's signature feature has no unit coverage at all: `describe('interactiveBorder', () => { // TODO })` ([`test/integration/props.test.js:667-669`][test-border]).

**Where the behavior lives.** Library code only: one pure function over rects, one debounce, and a module-global listener registry. No platform primitive participates, and notably no pointer [grab][concepts].

**Degradation.** This dimension needs no grab, no sub-cell precision and no key release. Tippy uses a document-level listener; a single-surface toolkit substitutes "the pointer cell in the last painted frame", which is strictly more reliable. With no hover the dimension is vacuous and the surface must be dismissed by an outside tap instead. With no script, the CSS analogue is a padded hover region — the same expanded-box idea expressed through the box model.

> [!NOTE]
> Whether a safe polygon would out-perform this grown box on a cell grid is a cross-subject question and is settled in [`./comparison.md`][comparison], not here. The narrow result that survived verification is that within a corridor of 0–1 whole cells the polygon and the corridor rectangle select the same cells; polygons that also span the anchor's own row or the overlay's area — which is what the corpus actually implements — do differ. Tippy simply does not play in that space: it stores no cursor history, computes no velocity and builds no hull.

### 8. Dismissal

**There is no Escape handling.** A grep of `src/` finds no `keydown` or `keyup` listener anywhere; Escape-to-dismiss ships only as a copy-paste plugin recipe in the documentation ([`website/src/pages/v6/plugins.mdx:128-150`][docs-esc]).

Outside-press is `mousedown` in the **capture** phase plus `touchend`, both bound to the owner document at `scheduleShow` time — that is, before the show delay elapses ([`:363-369`][ct-adddocpress]). The touch/scroll disambiguation is explicit: `touchstart` clears `didTouchMove`, `touchmove` sets it, and the press handler returns early when the input is touch and either a move happened or the event is a `mousedown` — the comment reads "Moved finger to scroll instead of an intentional tap outside" ([`:295-301`][ct-docpress], [`:355-361`][ct-touch]). Target resolution pierces shadow roots twice, via `composedPath()[0]` and via `actualContains`, which walks `getRootNode().host` chains ([`src/dom-utils.ts:127-136`][du-contains]).

The `hideOnClick` matrix, read from source rather than from docs:

| `hideOnClick` | Outside press                      | Press on the trigger                                                                       |
| ------------- | ---------------------------------- | ------------------------------------------------------------------------------------------ |
| `true`        | dismisses                          | dismisses, unless the trigger list contains `click` (the toggle owns it) or input is touch |
| `'toggle'`    | does not dismiss (guard at `:333`) | the `onTrigger` toggle still fires, because it tests only `!== false`                      |
| `false`       | does not dismiss                   | does not dismiss                                                                           |

Focus-outside dismissal exists only through `blur`/`focusout`, and only when the new focus target is not inside the popper ([`:561-579`][ct-blur]). Window deactivation is handled backwards, as a defensive blur: on window blur, a focused trigger whose surface is _not_ visible is programmatically blurred so that returning to the tab does not spuriously show it — with the source's own "TODO: find a better technique" ([`src/bindGlobalEventListeners.ts:42-58`][bgl-blur]).

Not handled at all: Escape, scroll-dismiss, anchor removal from the document (there is no observer; `data-reference-hidden` is styling only), navigation, resize, and child-opening. Parent-closing is handled only as an unmount cascade ([`:1110-1112`][ct-unmount]).

```text
onDocumentPress(e):
    if isTouch && (didTouchMove || e.type == 'mousedown'): return
    t := e.composedPath?.()[0] ?? e.target
    if interactive && actualContains(popper, t): return
    if any triggerTarget actualContains t:
        if isTouch: return
        if visible && trigger has 'click': return
    else: invokeHook('onClickOutside')
    if hideOnClick === true:
        clearDelayTimeouts(); hide()
        didHideDueToDocumentMouseDown := true; queueMacrotask(() => flag := false)
        if !isMounted: removeDocumentPress()
```

**Where the behavior lives.** Library code on document-level capture listeners; the touch listeners are registered `{passive: true, capture: true}` ([`src/constants.ts:10`][const-touch]).

**Degradation.** Press-not-click is the right default and survives everywhere, including a target where the system back gesture must map to the same dismissal entry point. The scroll-versus-tap disambiguation is a genuine touch requirement — a drag that began outside must not dismiss on release — and must be modelled explicitly where there is no native gesture recogniser. The Escape omission is a defect not to repeat: Escape arrives as a key _press_, so it is available even on a target with no key-release capability, and for anything menu- or popover-shaped it belongs in the primitive rather than in a plugin. See [`./concepts.md`][concepts] on [light dismiss][concepts].

### 9. Focus

**Tippy never moves focus.** There is no [focus scope][concepts], no containment, no restoration and no autofocus; the only `.focus()`-family call in `src/` is the defensive blur described above. The box gets `tabindex="-1"` ([`src/template.ts:79-80`][tpl-state]) so it is programmatically focusable but out of the tab order.

The entire keyboard strategy is **DOM order**. When `interactive` is set and `appendTo` is still the default sentinel, `mount()` appends the popup to `getCurrentTarget().parentNode` instead of `document.body`, "so it's directly after the reference element so the elements inside the tippy can be tabbed to" ([`:706-719`][ct-mount]). This is fragile enough that tippy ships a development-time warning when `node.nextElementSibling !== popper`, telling the author to wrap the trigger in its own element ([`:733-753`][ct-warn]) — and the warning text itself concedes that the documented fix for clipping, `appendTo: document.body`, "assumes you are using a focus management solution".

Focus-out keeps the surface open when `event.relatedTarget` is inside the popper. Modal versus non-modal is not a concept. The tooltip / popover / menu / dialog distinction exists only as the free-form `role` string ([`src/template.ts:119-123`][tpl-role]) and the derived ARIA policy; no behavior changes with the role.

**Algorithm.** The only algorithm is the append-target choice: `parentNode = (interactive && appendTo === TIPPY_DEFAULT_APPEND_TO) || appendTo === 'parent' ? currentTarget.parentNode : invokeWithArgsOrReturn(appendTo, [currentTarget])`.

**Where the behavior lives.** Delegated to the browser's sequential focus navigation — a platform primitive a canvas toolkit does not have. The library only picks an insertion point and warns when the trick breaks.

**Degradation.** This is a dimension where a canvas-first toolkit must do **more** than tippy, not less: with no document order to inherit and no tab-order engine, "the next Tab goes into the popup" has to be an explicit focus scope in the widget tree. Tippy's own warning is the evidence that piggy-backing on document order is a weak primitive. The distinction tippy blurs is worth keeping sharp: a tooltip should never take focus and should contain no focusables; a menu takes focus on open and restores on close; a dialog contains it.

### 10. Layering and portals

The portal is public API and is called `appendTo`: `'parent' | Element | (ref) => Element`, defaulting to the sentinel `TIPPY_DEFAULT_APPEND_TO = () => document.body` ([`src/constants.ts:12`][const-appendto]). The _identity_ of that sentinel is load-bearing — `mount()` compares it by reference to decide whether interactivity may override it ([`:713-716`][ct-mount]).

There is no top layer (v6 predates the platform's). Stacking is a plain `zIndex` prop defaulting to `9999`, written as an inline style on the popper root every time `handleStyles` runs ([`:217-221`][ct-handlestyles]).

Overlay **trees** are real, and they are discovered by DOM query rather than by ownership bookkeeping: `getNestedPopperTree()` is a `querySelectorAll` for nested roots inside this popup ([`:757-761`][ct-nestedtree]). It serves three purposes — the multi-surface keep-open test, the cascading unmount of children when the parent unmounts ([`:1110-1112`][ct-unmount]), and a frame-deferred `forceUpdate` of children after the parent's props change ([`:905-909`][ct-setprops]). A separate module-global array exists only so `hideAll()` can iterate ([`:43`][ct-mounted], [`src/index.ts:70-94`][index-hideall]), and each instance back-links itself from both DOM nodes as `_tippy`.

```text
tree(parent)   = querySelectorAll('[data-…-root]') within parent.popper
unmount(p)     = destroyPopper(p); for child in tree(p): child.unmount(); removeChild(p.popper)
ownership      = POSITIONAL — a popup is a child because it was appended inside the
                 parent's content subtree, which happens only when it is interactive and
                 inherits appendTo:'parent'
```

**Where the behavior lives.** Library code plus the DOM as the tree store; z-index is the compositor's problem.

**Degradation.** With one surface and no top layer, the z-index half evaporates and the tree half becomes the whole story. Positional ownership is unavailable off the DOM and its natural replacement is an explicit overlay stack — an ordered list of open surfaces, each carrying a parent identity — which then serves all three of tippy's uses at once and is directly assertable frame by frame. The lesson of `appendTo` (who owns the surface is public API) is worth keeping; its mechanism (a DOM insertion point) is not.

### 11. Modality

**Not applicable, and the absence is deliberate.** There is no modal flag, no scrim, no background pointer or keyboard blocking, no `aria-modal`, no `inert`. The decorative `animateFill` "backdrop" is a fill _inside_ the box, not a page scrim ([`src/scss/backdrop.scss:44-63`][scss-backdrop]).

The closest thing to modality is its inverse — click-through. Non-interactive surfaces get `pointer-events: none` as an inline style, and interactive ones get it back **at the start of the hide**, not at removal, so a fading-out surface cannot swallow the next click:

```ts
// src/createTippy.ts:217-221
function handleStyles(fromHide = false): void {
  popper.style.pointerEvents =
    instance.props.interactive && !fromHide ? '' : 'none';
  popper.style.zIndex = `${instance.props.zIndex}`;
}
```

`hide()` calls `handleStyles(true)` at its head ([`:1054`][ct-hide]; commit `cac8a12`, "fix: check state only from hide"), and the behavior is pinned by a test ([`test/integration/props.test.js:534`][test-pointerevents]). Because nothing is modal, two surfaces can be open at the same z-index with no arbitration.

**Where the behavior lives.** Library code writing one inline CSS property; the browser's hit-testing engine enforces it.

**Degradation.** There is nothing to degrade, but the gap is instructive. A toolkit that hit-tests by reverse paint order over a derived hit list uses exactly the mechanism `pointer-events: none` participates in, so the transferable rule is that each display-list entry carries a hit-testable bit and a surface animating out is marked non-hit-testable at the _start_ of the exit. Modality proper is a dialog concern; tippy's consistent absence of it supports keeping it out of an anchored-overlay primitive.

### 12. Adaptive presentation

The only adaptation axis is pointer type, and the decision is owned by a **module-global singleton**, not by the instance and not by the platform: `currentInput = {isTouch: false}` ([`src/bindGlobalEventListeners.ts:4`][bgl-input]), flipped true on the first document `touchstart` and flipped back only when two `mousemove` events arrive less than 20ms apart:

> ```ts
> /**
>  * When two `mousemove` event are fired consecutively within 20ms, it's assumed
>  * the user is using mouse input again. `mousemove` can fire on touch devices as
>  * well, but very rarely that quickly.
>  */
> ```
>
> — `src/bindGlobalEventListeners.ts:25-29`

Three behaviors read that flag: `touch: false` suppresses show entirely; `touch: 'hold'` re-routes the trigger from hover to `touchstart`/`touchend`, i.e. hover becomes press-and-hold, with an optional hold delay; and `getDelay` forces zero. Arbitration between the listener families is a single XOR — by JavaScript precedence, `getIsCustomTouchBehavior() !== event.type.indexOf('touch') >= 0` parses as `hold !== isTouchEvent`, so while the pointer mode is touch, a `'hold'` instance drops every mouse-ish event (including the synthetic mouse events a tap generates) and a non-`'hold'` instance drops every `touch*` event; outside touch mode nothing is dropped at all ([`:581-585`][ct-stopped]). Note that the touch pair is bound only under `touch: 'hold'` ([`:429-433`][ct-addlisteners]), so the XOR's second arm exists to filter events the browser synthesises rather than a second set of registrations.

There is no popover-to-sheet transformation, no compact-width breakpoint and no keyboard-driven relocation. The answer to "this tooltip is unreachable on touch" is to suppress it or to require a long press — both preserve the content; neither re-presents it.

**Where the behavior lives.** One library-level global populated from raw DOM events. Deliberately not a media query, not `pointer: coarse`, and not per-event `PointerEvent.pointerType`.

**Degradation.** A backend knows statically what it is, so pointer mode should be a **capability of the target** handed to the toolkit rather than a runtime heuristic — which deletes the 20ms guess and its hybrid-device failure mode. What must be kept is the consequence table: on a hover-less target a hover-triggered surface must either be suppressed or re-bound, and its delay must go to zero. Note the corrected constraint for a terminal target: a pointer press-and-hold like `touch: 'hold'` **is** expressible, because pointer release is decoded over SGR-1006; what a terminal lacks is keyboard key release, so a "hold a key to peek" trigger is the thing that cannot be built. A form swap (anchored popup to a sheet above a keyboard inset) is a decision for the application host, with the primitive exposing its preferred anchored rect and accepting insets — see [`../window-system-integration/index.md`][wsi] and [`../platform-ui-guidelines/index.md`][pug].

### 13. Accessibility

Two attributes and one policy function. `evaluateProps` resolves `aria: {content: 'auto', expanded: 'auto'}` into concrete values derived from `interactive` ([`src/props.ts:155-168`][props-aria]):

```ts
out.aria = {
  expanded:
    out.aria.expanded === 'auto' ? props.interactive : out.aria.expanded,
  content:
    out.aria.content === 'auto'
      ? props.interactive
        ? null
        : 'describedby'
      : out.aria.content,
};
```

That derivation encodes the real rule: an interactive surface is a disclosure, a non-interactive one is a description, and an interactive surface must not be an `aria-description`. `handleAriaContentAttribute` maintains a space-separated id list so several instances can describe one element, appending on show and removing with `String.replace(id, '')` on hide ([`:239-265`][ct-ariacontent]) — a removal that is prefix-unsafe, since removing `tippy-1` from `tippy-11 tippy-1` yields `1 tippy-1`. `handleAriaExpandedAttribute` refuses to touch the attribute when the reference already carried one at construction, and writes `true` only on the trigger that is currently the target ([`:267-286`][ct-ariaexpanded]).

The box carries a free-form `role`, defaulting to `'tooltip'`. There is no `aria-controls`, no active-descendant, and no keyboard interaction to match whatever role is set. WCAG 1.4.13 is partially satisfied by construction — interactive content is hoverable through the interactive-border machinery and is persistent — but dismissible-by-Escape is not provided. One defect is preserved by its own test: a singleton sets the relationship on **every** trigger simultaneously, because its `triggerTarget` is the whole array ([`test/integration/addons/createSingleton.test.js:210-217`][test-singleton-aria]).

Timing is part of the contract: the description is attached inside `onFirstUpdate`, i.e. after the first positioning pass ([`:996`][ct-firstupdate]).

**Where the behavior lives.** Library code writing ARIA attributes; the semantics belong to the browser's accessibility tree. There is no native accessibility API path.

**Degradation.** With no accessibility tree, none of the attribute plumbing transfers — but the **policy** does, and it is the part worth taking: a semantic role plus a derived relationship (describes / labels / controls-expandable / none) computed from whether the surface is interactive, projected by whichever backend has a channel for it. The id-list merge is DOM-specific noise; a relation keyed by node identity has no prefix bug. See [`../../specs/ui/index.md`][spec-ui] for where such a value would live and [`./aria-apg.md`][apg] for the normative contract tippy is approximating.

### 14. Animation

Tippy emits geometry metadata specifically so the styling layer can animate, and that projection is the private modifier's entire purpose. `$$tippy` runs at phase `beforeWrite` requiring `computeStyles`, writes `data-placement` (the full placement, e.g. `top-start`), `data-reference-hidden` and `data-escaped` onto the inner box, then blanks `state.attributes.popper` so Popper's `applyStyles` will not stamp its own attributes on the root ([`:608-631`][ct-modifier]).

Every animation stylesheet keys the transform origin off that attribute with a prefix selector and a per-side origin list (`$origins: bottom, top, right, left`, [`src/scss/_vars.scss:4`][scss-vars]) — so a placement-aware [transform origin][concepts] is data-driven and side-only, alignment deliberately ignored. Enter/exit state is a second datum: `data-state="visible|hidden"` set on box and content ([`src/dom-utils.ts:52-61`][du-visstate]) with durations written as inline `transition-duration` from the `[in, out]` tuple.

Ordering is intricate and browser-specific: durations are zeroed **before** mounting so a re-show after a flip does not animate from the stale side; `transition: 'none'` while unmounted; then the reflow-restore-apply-flip sequence in `onFirstUpdate`. Exit completion is detected with a `transitionend` listener that also registers the WebKit-prefixed alias ([`src/dom-utils.ts:105-121`][du-transend]), is made synchronous when the duration is zero, and is re-validated before unmount because the callback can arrive late ([`:379-415`][ct-transout]). Repositioning during an animation is the `moveTransition` prop, which must also disable Popper's `computeStyles.adaptive` or the transform fights the placement swap.

There is no spring model, no arrow animation beyond inheriting the box transform, and **no reduced-motion handling**: `prefers-reduced-motion` appears nowhere in `src/` or `scss/` in this tree.

```text
emit per update: {placement (side + alignment), referenceHidden, escaped,
                  state: visible|hidden, durationIn, durationOut,
                  transformOrigin = opposite(side)}
show: durations := 0 -> mount -> first placement { reflow; durations := in; state := visible }
                     -> transition end { isShown := true }
hide: state := hidden with durationOut -> transition end, IF still !visible AND still parented
                                       -> unmount
```

**Where the behavior lives.** Library code emits the data; the CSS engine owns the interpolation; the arrow inherits. The two-phase reflow dance is a browser requirement.

**Degradation.** The metadata emission is the transferable half: a display list that carries `{side, alignment, anchorClipped, escapedBoundary, phase}` per surface lets the paint layer choose an origin and lets a recording canvas assert placement without measuring pixels. The interpolation half does not transfer — no CSS engine, no `transitionend`, no reflow — and an immediate-mode toolkit that advances a phase per frame removes tippy's whole class of "the transition end fired late or never" bugs. On a cell grid animation reduces to a phase enum, but the metadata still chooses the corner glyph and the arrow side.

### 15. State architecture

Ad-hoc closure-scoped mutable state, explicitly not a state machine. One factory holds about eleven private `let` bindings — `showTimeout`, `hideTimeout`, `scheduleHideAnimationFrame`, `isVisibleFromClick`, `didHideDueToDocumentMouseDown`, `didTouchMove`, `ignoreOnFirstUpdate`, `lastTriggerEvent`, `currentTransitionEndListener`, `listeners`, `currentTarget` ([`:56-73`][ct-private]) — plus a public five-boolean record whose members are not independent ([`:78-89`][ct-state]):

```ts
const state = {
  isEnabled: true, // Is the instance currently enabled?
  isVisible: false, // Is the tippy currently showing and not transitioning out?
  isDestroyed: false,
  isMounted: false, // Is the tippy currently mounted to the DOM?
  isShown: false, // Has the tippy finished transitioning in?
};
```

The reachable combinations are a small subset of the 32, but nothing enforces that, and the public API lets a consumer write the fields directly — a test does exactly that, setting `instance.state.isEnabled = false` by hand and asserting the consequences ([`test/integration/createTippy.test.js:526-547`][test-statewrite]). Control flow is early-bail-out guards duplicated at the head of `show`/`hide`/`unmount`/`destroy`/`setProps` rather than a transition table.

Lifecycle hooks are a fixed list of twelve (`src/types.ts:27-46`) dispatched by `invokeHook`, which runs plugin hooks first and then the props hook — with a hard-coded exception for `onShow`/`onHide`, where the props hook is invoked separately so its `false` return can veto the transition, a veto plugin hooks cannot express. `setProps` is a full teardown and rebuild: remove listeners, re-evaluate props with attributes ignored, re-add listeners, maybe rebuild the debounce, fix ARIA, run `onUpdate`, recreate the Popper instance, and frame-defer a `forceUpdate` on every nested popup ([`:849-913`][ct-setprops]). Control is purely imperative and uncontrolled: the surface owns its own visibility and the host observes through hooks.

```text
The implicit machine (guards, not transitions, keep it consistent):
    Idle --show()--> Visible(unmounted) --mount--> Visible(mounted)
         --onFirstUpdate--> Shown
         --hide()--> isVisible=false, isShown=false, pointer-events off
         --transitionend|immediate--> Unmounted
         --destroy()--> Destroyed (terminal)
```

**Where the behavior lives.** Library code, in one closure. No framework, no store, no observer.

**Degradation.** This is the dimension least worth copying. Closure-captured mutable flags are unserialisable, untestable without a live event loop, and unassertable on a recording canvas. Two details make the case concretely: the stale `props` capture in the interactive-border test ([`:530`][ct-mousemove]) is a bug that cannot exist when the tester takes its state by value, and the five-boolean record with representable illegal combinations is exactly what a sum-typed phase eliminates. The hook _list_ is worth keeping as an observable event vocabulary — `onTrigger` / `onUntrigger` / `onShow` / `onMount` / `onShown` / `onHide` / `onHidden` / `onClickOutside` is a well-chosen decomposition — emitted from transitions rather than scattered across eight functions. See [`../../specs/ui/state-machines.md`][spec-stm] for the shape sparkles already uses.

### 16. Shared infrastructure

Tippy's answer is maximal sharing: one `createTippy` serves tooltip, popover, dropdown and menu, and the variation surface is props — `interactive`, `trigger`, `role`, `aria`, `hideOnClick`, `appendTo`. Composition above it uses three distinct mechanisms, and each reveals something about what genuinely factors.

1. **Plugins** are `{name, defaultValue, fn(instance) -> Partial<LifecycleHooks>}` (`src/types.ts:206-210`), auto-registering a same-named prop through `getExtendedPassedProps` ([`src/props.ts:84-105`][props-extended]). This seam carries `followCursor`, `sticky`, `inlinePositioning` and `animateFill` without privileged access.
2. **`createSingleton`** builds a real tippy over a throwaway `div` that is never in the document, disables the individual instances, and retargets by swapping `getReferenceClientRect` plus a caller-chosen `overrides` list of props copied from the hovered instance — monkey-patching `show`, `setProps` and each child's `setProps` to keep them in sync. It must also ship a modified `applyStyles` modifier whose effect returns **no cleanup**, because Popper's default cleanup wipes styles on every retarget and breaks the move transition ([`src/addons/createSingleton.ts:16-46`][singleton-styles]).
3. **`delegate`** is event delegation that lazily constructs a child instance on the first `mouseover`/`focusin`/`click` over a selector, mapping bubbling events to their non-bubbling equivalents through a three-entry table ([`src/addons/delegate.ts:9-13`][delegate]).

```text
singleton retarget (on any child's trigger with element t):
    if t == currentTarget: return
    currentTarget := t ; i := triggerTargets.indexOf(t)
    overrideProps := (overrides ++ ['content']).map(p => individual[i].props[p])
    singleton.setProps({...overrideProps,
                        getReferenceClientRect: () => references[i].getBoundingClientRect()})
    // content is ALWAYS overridden; everything else is opt-in by name
```

Conspicuously absent is everything list-shaped: no select, combobox or listbox, no submenu navigation, no roving tabindex, no typeahead, no date or colour picker, no toast. Tippy provides the surface and nothing about the content's interaction model.

**Where the behavior lives.** Library code. The plugin seam is a hook-record merge; both addons are wrappers built on the public API — which is itself evidence that the public API is sufficient.

**Degradation.** The partition transfers directly: one anchored-overlay primitive owning anchor, placement, collision, arrow, timing, keep-open, dismissal, layer-tree membership and animation metadata; nothing owning list semantics. The singleton is the sleeper. In a toolkit that paints one surface into one canvas, "one overlay that moves between many anchors" is not an addon — it appears to be the natural implementation, since there is only ever one painted overlay per open state — which argues for an anchor that is a plain comparable value rather than a re-evaluated callback. `delegate` (lazy per-target construction) is a retained-mode concern that immediate mode deletes. The things that look common and must stay apart are focus management (menu and dialog only), modality (dialog only), roving selection and typeahead (listbox and combobox only), and the semantic relationship to the anchor (describes versus controls).

## Strengths

- The interactive-border test is cheap and composable: one scalar, an offset-aware box grow, and a single `every` quantifier over the nested surface list gives trigger-to-content travel and submenu retention in four integer comparisons per surface with no stored history.
- Growing the keep-open region by the anchor **gap**, and only on the side facing the anchor, is the non-obvious half — it is what makes an interactive surface reachable across a 10px offset at all.
- Delay is a function of cause and phase rather than a constant: instant re-show while animating out, zero for keyboard focus, zero for touch.
- Placement results are emitted as styling **data** (`data-placement`, `data-reference-hidden`, `data-escaped`, `data-state`) instead of being consumed internally — the display-list-metadata discipline a canvas toolkit needs.
- The ARIA policy is derived, not configured: both `aria.content` and `aria.expanded` resolve from `interactive`, encoding the description-versus-disclosure rule in one place.
- Touch is treated as a distinct input mode with three coordinated consequences (suppress, hold-to-show, zero delay) plus a scroll-versus-tap gesture discrimination.
- The plugin seam is small, auto-registers its prop, and demonstrably carries four features plus two addons written entirely against the public API.
- `hide()` marks the surface non-hit-testable at the **start** of the exit animation rather than at removal — a one-line fix for the "the fading tooltip ate my click" class of bugs.
- Scope discipline: no modality, no focus trap, no list semantics. The absences are consistent rather than accidental.

## Weaknesses

- No Escape handling anywhere in `src/`; the canonical dismissal for anything menu- or popover-like is a documentation recipe, so every consumer re-implements it.
- The interactive-border test reads the closure-captured `props` constant instead of `instance.props`, so a changed `interactiveBorder` is ignored and nested surfaces are tested against the outer instance's border (`src/createTippy.ts:49` versus `:530`).
- `interactiveBorder`, the library's signature feature, has zero unit tests — `describe('interactiveBorder', () => { // TODO })`.
- ARIA id-list removal uses `String.replace` on a space-separated list and is prefix-unsafe.
- `createSingleton` sets the ARIA relationship on every trigger simultaneously, asserted as correct by its own tests.
- `followCursor` re-runs the entire `setProps` path per `mousemove`, removing and re-adding all listeners and destroying and recreating the Popper instance on each pointer motion.
- No state machine: five public mutable booleans with representable illegal combinations plus roughly eleven private flags whose interactions live in the ordering of guards across eight functions.
- Keyboard accessibility for interactive surfaces relies on DOM sibling order, is defended by a console warning rather than by focus management, and conflicts with the documented fix for clipping.
- `role` is a free-form string with no behavioral consequence: `role='menu'` can be set without arrow-key navigation, active-descendant or typeahead.
- The pointer-mode heuristic is a document-wide global driven by a 20ms threshold; one stray `touchstart` reclassifies every instance on the page.
- No reduced-motion support, and no viewport-inset concept at all — a soft keyboard is invisible to placement.
- Test files reference exports that no longer exist (`IOS_CLASS` in `test/integration/createTippy.test.js:6`, `POPPER_SELECTOR` in `test/unit/tippy.test.js:4`), so a handful of assertions pass vacuously.

## Key design decisions and trade-offs

| Decision                                                                                                                                        | Rationale                                                                                                                                                                                                  | Trade-off                                                                                                                                                                                                                                                                                                                                                             |
| ----------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Delegate all geometry to Popper 2 and contribute only a fixed modifier configuration plus a metadata-projection modifier                        | Overflow detection, clipping ancestors, transforms and scroll parents are the most browser-specific work; tippy keeps its own surface at 1145 lines and inherits upstream fixes.                           | Geometry becomes unverifiable and untunable from tippy's own source: the paddings (2/2/5/5, flip 5, arrow 3) are unexplained constants, users must reach through `popperOptions`, and tippy must add compensating hacks — the no-cleanup `applyStyles` clone, a forced second update after first placement, and a visited set to stop inline-positioning oscillation. |
| Model travel to the popup as an axis-aligned box grown by the border **and** by the anchor gap, rather than as a trajectory or hull             | It is O(1) per surface, allocation-free, needs no pointer history, composes over nested surfaces with one quantifier, and has a documented temporal counterpart (`interactiveDebounce`) for the same knob. | Diagonal travel to a submenu is unprotected: moving diagonally can leave the parent's grown rect before entering the child's, so tippy relies on the child rect already overlapping. There is also no way to express "the pointer is clearly heading toward the surface".                                                                                             |
| Represent every anchor as a `getBoundingClientRect` callback and reconfigure by calling the full `setProps()` path                              | One code path serves element, virtual, cursor, multi-rect and singleton anchors, and plugins need no privileged access.                                                                                    | `setProps` is a teardown and rebuild, so `followCursor` pays that cost on every `mousemove`; and the same design produced the stale-capture bug in the interactive-border test, silently freezing `interactiveBorder` at construction.                                                                                                                                |
| Keep no state machine: five public booleans plus roughly eleven private flags, with early-bail-out guards at every entry point                  | Minimal bundle, a public state object consumers can read directly, and cheap incremental patching as bug reports arrive.                                                                                   | Illegal state combinations are representable and the public API lets callers write them; the interaction rules live in the ordering of guards across eight functions; correctness depends on flags such as `didHideDueToDocumentMouseDown` that exist only to paper over event ordering.                                                                              |
| Solve keyboard accessibility for interactive surfaces by DOM insertion order (`appendTo = reference.parentNode`) rather than by managing focus  | Zero focus-management code; native sequential focus navigation does the work, so tabbing out of the trigger lands in the popup.                                                                            | Correct only when the popup is the trigger's immediate next sibling, so tippy ships a development warning telling authors to wrap the trigger, and it conflicts with the documented fix for clipping ancestors. A toolkit with no document order cannot borrow this at all.                                                                                           |
| Ship no Escape handling, no modality and no list/menu keyboard semantics in the core                                                            | Keeps the primitive at "an anchored surface with timing and dismissal"; the docs supply Escape as a twenty-line plugin recipe and the plugin seam makes content behavior the author's job.                 | Every real dropdown built on tippy re-implements Escape, roving focus and typeahead, and `role='menu'` can be set without any of the behavior it promises — semantics and behavior are decoupled in the wrong direction. The correct split is nonetheless visible: surface concerns inside, content interaction models outside.                                       |
| Detect pointer type with one global heuristic (`touchstart` implies touch; two `mousemove`s within 20ms imply mouse) rather than per-event data | Handles hybrid devices dynamically in about fifteen lines with no per-instance bookkeeping, and lets three behaviors read one flag.                                                                        | It is a guess with a global blast radius: one stray `touchstart` reclassifies every instance in the document, and the 20ms threshold is unexplained. For a toolkit whose backends know their input capabilities statically, the heuristic is liability rather than leverage.                                                                                          |

## Sources

Primary sources, all read at `ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1`:

- [`src/createTippy.ts`][ct-props] — the whole controller: private members and public `state`, delay policy, ARIA policy, document-press handling, trigger routing, the interactive-border driver, Popper configuration and the `$$tippy` projector, mount, schedulers, `show`/`hide`/`unmount`.
- [`src/dom-utils.ts`][du-border] — `isCursorOutsideInteractiveBorder`, `setVisibilityState`, `updateTransitionEndListener`, `actualContains`.
- [`src/props.ts`][props-aria] — `defaultProps` (including `interactiveBorder: 2`, `offset: [0, 10]`, `zIndex: 9999`, `role: 'tooltip'`), the `aria` auto-resolution, plugin prop extension.
- [`src/utils.ts`][utils-index] — `getValueAtIndexOrReturn`, `debounce`.
- [`src/bindGlobalEventListeners.ts`][bgl-input] — the global pointer mode and the window-blur defensive blur.
- [`src/template.ts`][tpl-arrow] — arrow element creation, `tabindex="-1"`, `data-state`, `role`.
- [`src/constants.ts`][const-touch] — `TOUCH_OPTIONS`, `TIPPY_DEFAULT_APPEND_TO`.
- [`src/plugins/followCursor.ts`][fc], [`src/plugins/sticky.ts`][sticky], [`src/plugins/inlinePositioning.ts`][inline-modifier] — cursor anchoring, rect polling, multi-rect folding and its oscillation guard.
- [`src/addons/createSingleton.ts`][singleton-styles], [`src/addons/delegate.ts`][delegate] — one surface over N anchors; lazy delegation.
- [`src/scss/index.scss`][scss-root], [`src/scss/border.scss`][scss-border], [`src/scss/svg-arrow.scss`][scss-svg], [`src/scss/_vars.scss`][scss-vars] — the arrow triangles, the per-placement origins, the viewport clamp.
- Tests as behavior pins: [`test/integration/props.test.js`][test-border] (the `interactiveBorder` TODO, the pointer-events assertion, the unintentional-tap test), [`test/integration/createTippy.test.js`][test-statewrite], [`test/integration/addons/createSingleton.test.js`][test-singleton-aria].
- Documentation in-tree: [`website/src/pages/v6/all-props.mdx`][docs-delay] (delay, `interactiveDebounce`), [`website/src/pages/v6/plugins.mdx`][docs-esc] (the `hideOnEsc` recipe).

Catalog cross-links: [index][index] · [concepts][concepts] · [comparison][comparison] · [features people forget][forgotten] · [sparkles baseline][baseline] · [proposal][proposal]. Nearest neighbours in this tree: [Floating UI][floating-ui] (the successor engine's design), [Floating Vue][floating-vue] and [Angular CDK][angular-cdk] (other imperative overlay managers), [React Aria][react-aria] and [Radix][radix] (safe-area and dismissal done as behavior hooks), [Base UI][base-ui] and [Zag][zag] (the state-machine answer to dimension 15).

<!-- References -->

[tippy-repo]: https://github.com/atomiks/tippyjs
[tippy-site]: https://atomiks.github.io/tippyjs/v6/all-props/
[pkg]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/package.json#L4
[ct-props]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/src/createTippy.ts#L49
[ct-private]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/src/createTippy.ts#L56-L73
[ct-state]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/src/createTippy.ts#L78-L89
[ct-currenttarget]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/src/createTippy.ts#L185-L187
[ct-getdelay]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/src/createTippy.ts#L198-L215
[ct-handlestyles]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/src/createTippy.ts#L217-L221
[ct-ariacontent]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/src/createTippy.ts#L239-L265
[ct-ariaexpanded]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/src/createTippy.ts#L267-L286
[ct-docpress]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/src/createTippy.ts#L295-L353
[ct-touch]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/src/createTippy.ts#L355-L361
[ct-adddocpress]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/src/createTippy.ts#L363-L369
[ct-transout]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/src/createTippy.ts#L379-L415
[ct-addlisteners]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/src/createTippy.ts#L429-L454
[ct-ontrigger]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/src/createTippy.ts#L463-L509
[ct-mousemove]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/src/createTippy.ts#L511-L542
[ct-mouseleave]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/src/createTippy.ts#L544-L559
[ct-blur]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/src/createTippy.ts#L561-L579
[ct-stopped]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/src/createTippy.ts#L581-L585
[ct-computedref]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/src/createTippy.ts#L600-L606
[ct-modifier]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/src/createTippy.ts#L608-L631
[ct-modifiers]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/src/createTippy.ts#L637-L680
[ct-mount]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/src/createTippy.ts#L701-L719
[ct-warn]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/src/createTippy.ts#L733-L753
[ct-nestedtree]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/src/createTippy.ts#L757-L761
[ct-schedshow]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/src/createTippy.ts#L763-L786
[ct-schedhide]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/src/createTippy.ts#L788-L830
[ct-cleardelays]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/src/createTippy.ts#L843-L847
[ct-setprops]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/src/createTippy.ts#L849-L913
[ct-firstupdate]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/src/createTippy.ts#L967-L1015
[ct-hide]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/src/createTippy.ts#L1018-L1075
[ct-hidewith]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/src/createTippy.ts#L1077-L1089
[ct-unmount]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/src/createTippy.ts#L1091-L1122
[ct-mounted]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/src/createTippy.ts#L40-L43
[ct-popperlisteners]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/src/createTippy.ts#L151-L164
[du-visstate]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/src/dom-utils.ts#L52-L61
[du-border]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/src/dom-utils.ts#L72-L103
[du-transend]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/src/dom-utils.ts#L105-L121
[du-contains]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/src/dom-utils.ts#L127-L136
[utils-index]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/src/utils.ts#L10-L25
[utils-debounce]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/src/utils.ts#L36-L52
[props-defaults]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/src/props.ts#L29-L60
[props-aria]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/src/props.ts#L155-L168
[props-extended]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/src/props.ts#L84-L105
[bgl-input]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/src/bindGlobalEventListeners.ts#L4-L40
[bgl-blur]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/src/bindGlobalEventListeners.ts#L42-L58
[tpl-arrow]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/src/template.ts#L20-L36
[tpl-state]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/src/template.ts#L79-L84
[tpl-role]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/src/template.ts#L119-L123
[const-touch]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/src/constants.ts#L10
[const-appendto]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/src/constants.ts#L12
[index-hideall]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/src/index.ts#L70-L94
[fc]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/src/plugins/followCursor.ts#L51-L91
[sticky]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/src/plugins/sticky.ts#L23-L46
[sticky-diff]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/src/plugins/sticky.ts#L60-L74
[inline-modifier]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/src/plugins/inlinePositioning.ts#L33-L58
[inline-rect]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/src/plugins/inlinePositioning.ts#L112-L178
[singleton-styles]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/src/addons/createSingleton.ts#L16-L46
[singleton-prepare]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/src/addons/createSingleton.ts#L112-L140
[delegate]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/src/addons/delegate.ts#L9-L13
[scss-root]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/src/scss/index.scss#L6-L8
[scss-placement]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/src/scss/index.scss#L22-L63
[scss-vars]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/src/scss/_vars.scss#L4
[scss-border]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/src/scss/border.scss#L5-L40
[scss-svg]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/src/scss/svg-arrow.scss#L3-L45
[scss-backdrop]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/src/scss/backdrop.scss#L44-L63
[test-modifiers]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/test/integration/props.test.js#L988-L1022
[test-border]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/test/integration/props.test.js#L667-L669
[test-pointerevents]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/test/integration/props.test.js#L534
[test-statewrite]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/test/integration/createTippy.test.js#L526-L547
[test-singleton-aria]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/test/integration/addons/createSingleton.test.js#L210-L217
[docs-delay]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/website/src/pages/v6/all-props.mdx#L291-L315
[docs-debounce]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/website/src/pages/v6/all-props.mdx#L595
[docs-esc]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/website/src/pages/v6/plugins.mdx#L128-L150
[index]: ./index.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[forgotten]: ./features-people-forget.md
[baseline]: ./sparkles-baseline.md
[proposal]: ./proposal.md
[floating-ui]: ./floating-ui.md
[floating-vue]: ./floating-vue.md
[angular-cdk]: ./angular-cdk.md
[react-aria]: ./react-aria.md
[radix]: ./radix.md
[base-ui]: ./base-ui.md
[zag]: ./zag.md
[apg]: ./aria-apg.md
[wsi]: ../window-system-integration/index.md
[pug]: ../platform-ui-guidelines/index.md
[spec-ui]: ../../specs/ui/index.md
[spec-stm]: ../../specs/ui/state-machines.md
