# HTML Popover API and the top layer (WHATWG HTML + CSS Position 4)

A deliberately geometry-free overlay primitive: the web platform specifies stacking, cascade dismissal, focus scope and re-entrancy for popovers in painstaking detail, and specifies placement, timing, hover and semantics not at all.

| Field             | Value                                                                                                                                                                                                                                                                                                                                           |
| ----------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language          | Specification prose. WHATWG HTML is a single `source` file (a bikeshed-flavoured HTML document); the CSS drafts are Bikeshed `.bs`. No implementation code was read for this page.                                                                                                                                                              |
| License           | CC-BY-4.0 for the spec text; BSD-3-Clause for the portions incorporated into source code                                                                                                                                                                                                                                                        |
| Repository        | [`whatwg/html`][html-repo] (primary); [`w3c/csswg-drafts`][csswg-repo] (adjacent, different repository and revision)                                                                                                                                                                                                                            |
| Documentation     | [HTML Standard § The `popover` attribute][html-docs]; [CSS Positioned Layout 4][css-pos-docs]; [CSS Anchor Positioning 1][css-anchor-docs]                                                                                                                                                                                                      |
| Category          | Web platform (normative specification)                                                                                                                                                                                                                                                                                                          |
| Surface model     | Both, in a narrow sense. The popover algorithms are surface-agnostic; the [top layer](./concepts.md) is an in-document ordered set whose boxes are generated as siblings of the root element — in-canvas, not an OS popup. The one place the platform admits an OS surface is the `select` picker, chosen by computed style (see dimension 12). |
| **Revision read** | `ac0389a3aca0331055bf4bf23f509c2913e3f795` (`whatwg/html`, Living Standard); `6dc15cc9cb15043840eacf081e89f5a666fa7889` (`w3c/csswg-drafts`)                                                                                                                                                                                                    |
| Reading           | **Docs-only — spec prose, not an implementation reading.** Every claim below is derived from normative or informative spec text. For the engine side see the sibling deep-dive [`./blink.md`](./blink.md); for the placement half see [`./css-anchor.md`](./css-anchor.md).                                                                     |

> [!IMPORTANT]
> No browser source and no web-platform tests were read for this page. Where the spec's own commit history says a rule is "not currently implemented in browsers", that is noted inline; nothing here should be read as a statement about shipped behaviour.

## Overview

### What it solves

The Popover API answers exactly one question: how do independent, possibly nested, possibly cross-feature overlays share a single stacking surface and a single dismissal policy without any of them knowing about the others. It supplies a three-state `popover` content attribute — Auto, Manual, Hint — whose differences are entirely about **stack participation** rather than appearance; an overlay _tree_ recomputed on demand from one ordered set plus two kinds of edge; a family of cascade-closing algorithms parameterised by an "endpoint" element; a two-phase `pointerdown`/`pointerup` [light dismiss](./concepts.md); and a defensive re-entrancy discipline that assumes every event dispatch can destroy the element under it.

It solves nothing about [placement](./concepts.md), arrows, timing, hover intent, or semantics. Those are elsewhere or nowhere: placement in CSS Anchor Positioning ([`./css-anchor.md`](./css-anchor.md)), semantics in HTML-AAM and author ARIA ([`./aria-apg.md`](./aria-apg.md)), timing and hover in author script. The absences are the design, and each one is recorded as a finding in the spine below.

### Design philosophy

Three commitments run through the text.

**Derive the tree; never store it.** The parent/child relation between overlays is not a pointer but a rule over one ordered list:

> In each of the relationships formed above, the parent popover has to be strictly earlier in the showing auto popover list or showing hint popover list than the child popover, or it does not form a valid ancestral relationship. This eliminates non-showing popovers and self-pointers (e.g., a popover containing an invoking element that points back to the containing popover), and it allows for the construction of a well-formed tree from the (possibly cyclic) graph of connections.
>
> — `source:92634` ([`topmost popover ancestor`][src-tree-note])

**The ordering must be owned by exactly one party, and it must not be the author.** CSS Positioned Layout 4 states the rationale rather than merely the rule:

> The top layer is managed entirely by the user agent; it cannot be directly manipulated by authors. This ensures that "nested" invocations of top-layer-using APIs, like a popup within a popup, will display correctly.
>
> — `css-position-4/Overview.bs:167` ([top layer][css-ua-managed])

and states, one note earlier, precisely what membership buys:

> This special rendering behavior ensures that elements in the top layer cannot be clipped by anything in the document, or obscured by anything except elements later in the top layer. This ensures that things like popovers can be displayed reliably, regardless of what their ancestor elements might be doing.
>
> — `css-position-4/Overview.bs:146` ([rendering note][css-clip-note])

**The primitive is a substrate, not a component.** Roles, names and keyboard conventions are explicitly somebody else's job:

> When using popover on elements without accessibility semantics, for instance the div element, authors should use the appropriate ARIA attributes to ensure the popover is accessible.
>
> — `source:91758` ([authoring note][src-aria-note])

## How it works

**The three states.** `popover=auto` joins the auto stack, gets a close watcher and light dismiss, and closes unrelated popovers when it opens. `popover=hint` (`source:91843`) does the same in a _separate, strictly higher_ stack that does not tear the auto stack down. `popover=manual` (`source:91836`) is a top-layer surface with no stack participation, no light dismiss and no close watcher — the toast/status escape hatch.

**The state.** Per element: `popover visibility state`, `popover trigger`, `popover hiding`, `popover toggle task tracker`, `popover close watcher`, `opened in popover mode`, `previously focused element`, `implicit anchor element`. Per document: `popover pointerdown target`, `hiding popover nesting count`, `showing popover`, `hint stack parent`, and the top layer plus `pending top layer removals`. There is no manager object anywhere.

**The stacks are projections.** `showing auto popover list` and `showing hint popover list` are recomputed on every read by filtering the document's top layer (`source:92833`):

```text
autoList() => topLayer.filter(e => e.openedMode == "auto" && e.visible)
hintList() => topLayer.filter(e => e.openedMode == "hint" && e.visible)
```

Dialogs and fullscreen elements sit in the same ordered set and are simply filtered out, which is why a dialog can open inside a popover and vice versa without either feature knowing about the other.

**The tree is an integer.** `topmost popover ancestor` (`source:92612`) concatenates the two lists so every hint outranks every auto, then takes the last entry that flat-tree-contains either the new popover (a containment edge) or its invoker (an invocation edge):

```text
C = autoList ++ hintList
i = lastIndexWhere(C, p => isFlatTreeDescendant(el, p))       // containment edge
j = source ? lastIndexWhere(C, p => isFlatTreeDescendant(source, p)) : -1   // invocation edge
k = max(i, j)
ancestor = k < 0 ? null : C[k]
```

Two structurally different relationships collapse to one comparable index, and the strictly-earlier rule quoted above is what makes cycle detection unnecessary.

**Showing.** `show popover` (`source:91971`) refuses to run if the document's `showing popover` latch is set or `hiding popover nesting count` is non-zero, validates, fires a cancelable `beforetoggle` synchronously, **re-validates**, computes the ancestor, demotes an Auto whose ancestor is a Hint down to Hint (`source:92083`), closes the hint stack and then the auto stack above the ancestor, re-validates again, records `shouldRestoreFocus` only when the stack was empty, snapshots `opened in popover mode`, establishes a close watcher, appends to the top layer, sets `popover trigger` and `implicit anchor element` to the invoker, runs the popover focusing steps, and queues a coalescing `toggle`.

**Hiding.** `hide a popover` (`source:92283`) takes `(element, focusPreviousElement, fireEvents, throwExceptions, source)`, sets a per-element `popover hiding` bool (forcing `fireEvents` to false if it was already set), increments the document nesting count, cascades to the stack above itself, fires `beforetoggle`, and then chooses between two removal algorithms — deferred when events are firing, immediate otherwise.

**Dismissing by pointer.** `light dismiss open popovers` (`source:93077`) is a two-phase identity test, not a hit test:

```text
on pointerdown: if topmostAutoOrHint() == null: return
                doc.popoverPointerdownTarget = topmostClickedPopover(event.target)

on pointerup:   if topmostAutoOrHint() == null: return
                ancestor  = topmostClickedPopover(event.target)
                sameTarget = (ancestor is doc.popoverPointerdownTarget)
                doc.popoverPointerdownTarget = null
                if !sameTarget: return
                hidePopoversUntil(document, ancestor, focusPrevious: false, fireEvents: true)
```

**The UA stylesheet is the whole positional contribution.** `source:150618`:

```css
[popover] {
  position: fixed;
  inset: 0;
  width: fit-content;
  height: fit-content;
  margin: auto;
  border: solid;
  padding: 0.25em;
  overflow: auto;
  color: CanvasText;
  background-color: Canvas;
}

:popover-open::backdrop {
  position: fixed;
  inset: 0;
  pointer-events: none !important;
  background-color: transparent;
}
```

An unstyled popover is centred in the viewport, nowhere near its invoker; and its backdrop is explicitly click-through, in deliberate contrast to a dialog's translucent one.

## The analysis spine

### 1. Anchor model

The primitive has no geometric [anchor rect](./concepts.md). It has exactly one anchor-shaped piece of state: `implicit anchor element`, set to `source` at show time (`source:92211`) and cleared to null on hide (`source:92432`). `source` is an element-or-null supplied three ways — the `source` member of `ShowPopoverOptions` (`source:13058`), the invoker passed by `popover target attribute activation behavior` or the command-button steps, or the `select` element for a base-appearance select popover (`source:153151`). There is no rect, no point, no cursor position, no text range, no [virtual anchor](./concepts.md), and no anchor-to-screen conversion anywhere in HTML; the geometry is delegated to CSS, which reads the implicit anchor through `position-anchor: auto` or an omitted reference in `anchor()` (`css-anchor-position-1/Overview.bs:586`).

**Algorithm.** `anchorOf(popover) = popover.source` — an element handle, or null. There is no arithmetic. The invoker's identity does quadruple duty: the anchor for CSS, the invocation edge for `topmost popover ancestor`, the [focus scope](./concepts.md) owner, and `ToggleEvent`'s `source`.

**Where the behavior lives.** Element-scoped HTML state (`popover trigger`, `source:91879`) plus the CSS hook the layout engine consumes. Neither is a value; both are element references.

Many triggers may target one popover (any number of buttons may name the same id) but only the most recent wins: `popover trigger` and `implicit anchor element` are single-valued and overwritten on each show. A trigger detached from the anchor is not expressible — the invoker is always both.

**Degradation.** With no OS window this dimension loses nothing, because there is no window in it. Everything HTML itself does with the anchor is identity comparison and ancestor testing, which a stable widget id serves as well as a DOM handle; only the CSS side needs geometry, and a toolkit with no layout engine has no `position-anchor: auto` to defer to, so the anchor rect has to be captured explicitly. Nothing here needs sub-cell precision, hover, or a key release. Static output degrades cleanly: the invoker/target relation is an attribute pair, not a computed value.

### 2. Placement model

**Absent from the subject, deliberately.** The popover spec specifies zero placement; the entire positional contribution is the UA stylesheet rule quoted above, which centres the popover in the viewport. Nothing flips, shifts or resizes. Sides, alignment, RTL, writing modes, preferred lists and fallback ordering all live in CSS Anchor Positioning — `position-area` for the logical grid, `position-try-fallbacks` for the ordered list, `position-try-order` for a stable re-sort by available space — and are read in [`./css-anchor.md`](./css-anchor.md), not here. Safe-area insets, work areas, multi-monitor geometry and virtual-keyboard avoidance appear nowhere in either document; the viewport is the only boundary concept, and top-layer styling pins the containing block to the initial containing block or the viewport (`css-position-4/Overview.bs:194`).

**Algorithm.** For the primitive: none. For the adjacent engine (`css-anchor-position-1/Overview.bs:1948`): walk the ordered options list, skip the option currently in effect, lay out, and accept the first whose margin box is contained in its inset-modified containing block; if none fits, keep the current styles. Hysteresis comes from `last successful position option`, recorded at ResizeObserver timing and cleared only on fallback-sensitive changes.

**Where the behavior lives.** The UA stylesheet and the CSS layout/cascade engine — not in the popover state machine. The two are joined only by `implicit anchor element`.

**Degradation.** Nothing in this dimension is inherited by a toolkit that has no CSS engine; it must be rebuilt entirely. Three shapes look worth carrying across, and the catalog's [proposal](./proposal.md) is where they are argued: an ordered fallback list decided by a containment test (which on integer cells is an exact integer rect test with no fractional tolerance); the `last successful position option` hysteresis, whose purpose is to stop an overlay oscillating between two placements when it sits exactly on the boundary; and the "layout does not go backward" discipline, i.e. one placement pass per frame in which later overlays never invalidate earlier ones. A soft-keyboard inset has no counterpart here at all and has to be an explicit input to whatever boundary is used ([`../platform-ui-guidelines/index.md`](../platform-ui-guidelines/index.md)).

### 3. Collision & geometry engine

The popover spec contributes one geometric guarantee and no engine. Top-layer elements "cannot be clipped by anything in the document, or obscured by anything except elements later in the top layer" (`css-position-4/Overview.bs:146`), achieved structurally: each generates a stacking context whose parent stacking context is the root one, boxes are generated as siblings of the root element, and the containing block is the initial containing block or the viewport, so ancestor `overflow`, `opacity`, `mask` and `transform` are provably irrelevant. One leak survives — `display: none` on any shadow-including inclusive ancestor still hides it (`css-position-4/Overview.bs:194`).

Overflow detection, [clipping-boundary](./concepts.md) discovery, scroll containers, transforms and DPR are the CSS engine's problem, and tracking is neither polling nor `requestAnimationFrame` but interleaved layout: `record the last successful position option` is pinned to ResizeObserver timing, and `clipped by intervening boxes` is pinned to after content-relevancy and ResizeObserver but before IntersectionObserver. The anchor-hidden answer is a CSS property, `position-visibility`, whose initial value `anchor-visible` forces `visibility: force-hidden` when the anchor is invisible or clipped by an intervening box — chained, so a popover anchored to a hidden popover hides too (`css-anchor-position-1/Overview.bs:2222`, `:2262`).

**Algorithm.** Containment: emit the box at document scope with the viewport as containing block, so no ancestor clip rect applies; paint order is the top-layer index. Visibility: if the anchor's ink-overflow rect is entirely clipped by a box that is an ancestor of the anchor and a descendant of the overlay's containing block, force-hide.

**Where the behavior lives.** The layout/paint engine. The popover algorithms reach it only through "add to the top layer".

**Degradation.** Three things generalize off the DOM. (a) "Front-to-back equals later in the ordered set" is what `paint a document` (`css-position-4/Overview.bs:513`) literally does — paint the root, then for each top-layer element paint its backdrop and then the element — which is an append-to-display-list loop. (b) An overlay's clip rect is the surface, never its parent's clip; an in-surface renderer reproduces the whole benefit of the top layer by painting overlays from a document-level list with the clip stack reset. (c) `anchor-visible` as the _default_ is a strong hint for scrolled-out anchors: hide the overlay rather than leave it floating over unrelated content. All three are assertable with no window, no hover and no script, on a recording canvas. Sub-cell precision is irrelevant: the containment test is integer.

### 4. Arrow / caret geometry

**Absent, and the absence is a finding.** There is no arrow concept in the popover spec or in the top layer; the word does not appear in the popover machinery. The UA stylesheet gives a popover a plain `border: solid` and `padding: 0.25em` and nothing else. No [transform origin](./concepts.md) is exposed, no side or alignment datum is emitted, no arrow size feeds an offset. An author who wants a caret builds it as a pseudo-element and — in the CSS world — may anchor it independently; the primitive knows nothing about it.

**Algorithm.** Not applicable.

**Where the behavior lives.** Nowhere. Author CSS.

**Degradation.** The consequence for a cell grid is structural rather than arithmetical: with no second layout pass available to place a decorative pseudo-element, the caret has to be decided where the placement is decided, which means the placement result must report the resolved side and the anchor's offset along that side. What is drawn is then a theme glyph on the shared edge rather than geometry. The corner cases (an offset that lands on a corner glyph, an edge too short to carry a caret at all) are toolkit concerns this subject offers no guidance on; see [`./features-people-forget.md`](./features-people-forget.md) and [`./sparkles-baseline.md`](./sparkles-baseline.md).

### 5. Trigger semantics

Two trigger classes exist: declarative activation of a button, and script. Declarative comes in two generations — legacy `popovertarget` plus `popovertargetaction` (`toggle` | `show` | `hide`, default `toggle`, `source:92902`) and the newer `commandfor` plus `command` with the keywords `toggle-popover`, `show-popover`, `hide-popover` (`source:56739`). Both run in _activation behavior_, i.e. on click (including a synthetic `click()`), never on `pointerdown`, never on hover, never on focus. `popover target element` gates hard: the invoker must be a button, not disabled, and not a submit button with a form owner (`source:93042`). Command buttons additionally fire a cancelable `command` event at the target first, and the spec notes those events are dispatched even to elements carrying no `popover` attribute (`source:56831`). Inside button activation behavior the command path runs first and the `popovertarget` path is the `Otherwise` branch (`source:56966`), so one element cannot do both.

There is no pointer-type distinction, no long-press, no context-menu trigger, no keyboard shortcut and no AT-initiated show. `popover=hint` exists precisely to support hover-like surfaces, but this revision supplies no hover trigger at all: a grep of the spec source for `interestfor` at the pinned revision returns zero hits, so the hint stack currently has no declarative producer.

**Algorithm.** Race avoidance is by construction rather than arbitration — a single trigger kind reaching a single re-entrancy-guarded entry point. The only multi-trigger arbitration in the feature is the nested-invoker guard (`source:93006`): if the event target is inside the popover _and_ the popover is inside the invoker, activation does nothing, because otherwise a click inside the popover would bubble to the wrapper element that both contains and targets it and toggle it shut.

**Where the behavior lives.** HTML activation behavior for `button` and `input` (`source:51183`, `source:56899`), the command-event dispatch, and the `showPopover`/`hidePopover`/`togglePopover` methods.

**Degradation.** Everything here survives a target with no hover and no key release intact, because nothing in it is timing- or hover-based. Three rules travel: triggers are activation-level, so a terminal's Enter/Space and a touch tap map identically; the explicit show/hide/toggle triple (not toggle alone) is what makes an idempotent close button _inside_ the overlay safe; and the nested-invoker guard is exactly the failure a canvas toolkit meets when the trigger widget is an ancestor of the overlay's owner in the widget tree. For script-free HTML output, a `<button popovertarget>` pair is a genuine anchored overlay with no script — one of very few such constructs.

### 6. Timing

**Zero timing.** No delay, [warm-up](./concepts.md), [cool-down](./concepts.md), skip-delay, instant-subsequent, maximum display duration or group provider exists anywhere in the popover machinery. The spec's own example of an auto-dismissing status popover uses a raw author `setTimeout(..., 10000)` (`source:91786`).

Two temporal mechanisms do exist and neither is a dwell timer. The `popover toggle task tracker` (`source:92229`) coalesces event _delivery_: N flips within one task collapse into a single `toggle` whose `oldState` is the pre-burst state, and a show immediately followed by a hide therefore fires a degenerate `toggle` with `oldState == newState == "closed"`. And `process top layer removals` runs once per frame at the tail of Update the Rendering (`source:123114`) — a frame boundary, not a delay.

**Algorithm.** The lifecycle extracted from what is present: Hidden → (cancelable at `beforetoggle`) Showing → Hidden, synchronous, with two orthogonal guards layered on — a per-document `showing popover` latch and a per-document `hiding popover nesting count` — which together forbid a show while any transition is in flight but permit recursive hides. A delay would attach _outside_ this machine as a trigger-side debouncer. The spec makes the same separation structurally: the surface class that would carry timing (hint) is a different _stack_, not a different timer inside the same object.

**Where the behavior lives.** Nowhere in the platform; author script. The frame-boundary part lives in HTML's Update the Rendering.

**Degradation.** With no script there are no timers, and the primitive needs none — a `<button popovertarget>` overlay works with zero timers, which is the striking result: an entirely untimed anchored-overlay primitive is shippable and interoperable. The structural suggestion for a toolkit is the same split — an untimed core that a recording canvas can assert frame by frame, plus an optional hover-intent policy that only the targets with hover instantiate. The toggle coalescer looks directly worth copying into an immediate-mode loop, where several show/hide flips per frame are normal and one collapsed notification carrying the pre-burst old state is the useful contract.

### 7. Interactive hover

**Nothing.** No [safe polygon](./concepts.md), no pointer bridge, no menu-aim, no interactive border, no trajectory heuristic, no debounce. The popover spec sees exactly two pointer events, `pointerdown` and `pointerup`, and only to decide dismissal. Hover never appears. The Hint state exists for tooltip-like surfaces but supplies only stack semantics — its own stack, closes sibling hints, does not close autos, dies with its `hint stack parent` (`source:92447`) — never traversal semantics.

**Algorithm.** Not applicable.

**Where the behavior lives.** Nowhere.

**Degradation.** INFERENCE: the platform's answer to trigger-to-content travel appears to be structural rather than geometric — because the hint stack does not close the auto stack, a hover surface can appear over a menu without the pointer's route between them mattering. That reading is consistent with the Hint state's specified behaviour but is not stated as a rationale anywhere in the text. What this subject supports concretely is only the negative: whatever a toolkit does about pointer travel, this primitive supplies none of it, so it must be an explicitly declared policy on the targets that have hover at all rather than something the core depends on. The geometric options — corridors, hulls, latched directions — belong to the subjects that implement them ([`./floating-ui.md`](./floating-ui.md), [`./react-aria.md`](./react-aria.md)) and to [`./comparison.md`](./comparison.md), not here.

### 8. Dismissal

Eight distinct dismissal paths, each with different flags.

1. **Close request** — Esc, the Android back gesture, a gamepad back button, or an assistive technology's dismiss gesture such as VoiceOver's two-finger scrub (`source:88898`, `source:88911`). Routed through a close watcher established at show time whose close action hides the popover with `focusPrevious = true`, `fireEvents = true`; the cancel action always returns true, so **a popover never cancels a close request**. Only Auto and Hint establish close watchers (`source:92176`); Manual gets none.
2. **Light dismiss** — the two-phase `pointerdown`/`pointerup` identity test (`source:93077`), Auto and Hint only, ending in `hide popovers until(topmost clicked popover)`.
3. **Trigger re-activation** — the default `popovertargetaction`/`command` is toggle.
4. **Another popover opening** — `show popover` closes the hint stack above the new popover's ancestor, then, if Auto, the auto stack above it.
5. **A dialog opening** — both `show()` and `showModal()` compute `topmost popover ancestor(dialog, null, false)` and then `hide popovers until` (`source:66434`, `source:66693`), so a dialog nested inside a popover keeps that popover open and closes everything else.
6. **DOM removal** — the generic node removing steps hide with `focusPrevious = false` and **`fireEvents = false`** (`source:1867`), so removing a showing popover fires no `toggle` and takes the immediate top-layer removal branch, killing any exit animation.
7. **Attribute mutation** — changing the `popover` attribute between states while showing hides it (`source:91922`).
8. **A parent closing** — cascading through `hide popover stack until`, plus the special case that hiding the document's `hint stack parent` hides _all_ hints (`source:92353`).

Not dismissal triggers, deliberately: scroll, resize, window or application deactivation, focus moving outside, and the anchor becoming hidden — that last is `position-visibility`, which hides the _box_ without removing it from the stack.

**Algorithm.** Every path funnels into either `hide a popover` (one element, cascading to its children) or `hide popovers until(endpoint)` (close everything above a computed endpoint). The endpoint is always produced by the same integer-index ancestor computation, whether the cause was a pointer, a key, a new popover or a dialog. `hide popovers until` (`source:92521`) additionally reparents across stacks: it closes the hint stack above the endpoint, then, if the endpoint was itself a hint, substitutes the document's `hint stack parent` before closing the auto stack.

**Where the behavior lives.** The HTML popover algorithms, the generic close-watcher infrastructure (`source:89018`), and the DOM node-removing steps.

**Degradation.** Two results transfer directly. First, Esc, the Android back key and an AT dismiss gesture are **one** abstraction here, so a toolkit needs one close-request event rather than three code paths. Second, that abstraction is specified on key **down**:

> On platforms where pressing the Esc key is interpreted as a close request, the user agent must interpret the key being pressed down as the close request, instead of the key being released.
>
> — `source:88996` ([close requests][src-keydown])

so a target that reports no key _release_ still gets dismissal exactly as specified. The two-phase pointer test is a different capability from key release and needs pointer press _and_ pointer release; where only one pointer phase is available the mechanism degrades to single-phase dismissal — correct, merely less tolerant of drags. Focus-moving-outside is deliberately _not_ a dismissal cause here, which is a convenient default for a toolkit with no OS focus notion. See [`./sparkles-baseline.md`](./sparkles-baseline.md) for which of these causes a cell backend can actually observe.

### 9. Focus

Popover and dialog are kept surgically distinct.

**Initial focus.** `popover focusing steps` (`source:92744`) move focus only if the popover carries `autofocus` or has an autofocus delegate; otherwise focus does not move at all. Even then it is gated by `allow focus steps` (`source:87211`), which requires transient activation, so a script-shown popover cannot steal focus. A `dialog` element used as a popover detours to the dialog focusing steps instead (`source:92750`).

**Restoration.** `previously focused element` is captured only when `shouldRestoreFocus` is true, and that is true only when `topmost auto or hint popover` was null — i.e. **only the bottom popover of a stack remembers focus** (`source:92143`). On hide, focus is restored only if the currently focused DOM anchor is still a shadow-including inclusive descendant of the popover being hidden (`source:92464`); if the user tabbed away, focus is left alone. Restoration explicitly does not scroll.

**Trap.** None. Popovers make nothing inert; `blocked by a modal dialog` is defined solely for the topmost `dialog` in the top layer (`source:84990`).

**Containment.** Also none — but tab _order_ is rewritten. An element that is the `popover trigger` of a showing popover is a `focus navigation scope owner` (`source:86001`), and `associated focus navigation owner` returns that trigger for the popover (`source:86027`), so tabbing off the invoker lands inside the popover regardless of where the popover element lives in the tree. Nested scopes fall out of the same rule. Focus leaving the popover closes nothing.

**Algorithm.**

```text
scopeOwner(el) = el is a showing popover with a non-null trigger ? el.trigger
                                                                : usual parent/host/slot chain
initialFocus(el) = autofocus attribute ?: autofocus delegate ?: none    // gated on transient activation
restore(el)      = el was the stack bottom AND focus is still inside el
```

**Where the behavior lives.** The HTML focus model (`focus navigation scope owner`), the popover focusing steps, and the inert/modal machinery that popovers deliberately do not touch.

**Degradation.** This is the dimension with the least platform dependence: with one surface and no OS focus, focus is a toolkit-owned id, and the scope-owner rewrite is a pure function of (open overlay, its trigger) that a recording canvas can assert by driving Tab and snapshotting the focused id. Tab itself is a key-down, so a target with no key-release signal loses nothing _in this mechanism_ — but that is a statement about the mechanism, not a general claim that a keyboard without release events costs a toolkit nothing elsewhere. The transposition worth arguing (and it is an inference from the HTML rule, not an observed toolkit result) is that an overlay's tab-order parent should be its **trigger** rather than its owner in the widget tree, which is what makes an overlay's position in the view function irrelevant to keyboard navigation; see [`./proposal.md`](./proposal.md).

### 10. Layering & portals

This is the subject's core. The top layer is a per-`Document` **ordered set** of elements plus a `pending top layer removals` ordered set (`css-position-4/Overview.bs:136`, `:177`), managed entirely by the user agent and unreachable from author code. Correspondingly the popover spec never touches it except through four exported algorithms — add, request removal, remove immediately, process removals.

The public API is the `popover` attribute, `showPopover`/`hidePopover`/`togglePopover`, `:popover-open`, `beforetoggle`/`toggle` and `::backdrop`. The implementation detail is the top layer itself, both stack lists, the `overlay` property (author-unsettable via a UA `* { overlay: none !important }` rule, `css-position-4/Overview.bs:443`), `opened in popover mode` and `hint stack parent`. Re-showing an element that is already present **re-appends** it (`css-position-4/Overview.bs:303`), so show order defines z-order and no `z-index` appears anywhere in the feature.

**Algorithm.**

```text
paint(document):
    paint the root element's stacking context
    for el in document.topLayer:            // in order
        paint el's ::backdrop stacking context
        paint el as a stacking context whose containing block is the ICB / viewport

in the top layer(el)          = topLayer.has(el) and not pending.has(el)      // logical membership
rendered in the top layer(el) = topLayer.has(el) and computed overlay == auto // visual membership
```

Two predicates, deliberately different, with a spec note (`css-position-4/Overview.bs:286`) telling other specs which to use: hit testing and ancestor arithmetic read the logical one; painting reads the visual one.

**Where the behavior lives.** CSS Positioned Layout 4 owns the set and the painting; HTML owns who is allowed in and in what order.

**Degradation.** A single-surface toolkit has no top layer, and this subject says precisely what would have to be rebuilt and what is already true. To rebuild: a document-level ordered set of overlays, a clip-stack reset when painting them, and the rule that an overlay's containing rect is the surface. Already true by construction in a canvas toolkit with no `z-index` and no stacking contexts: "later in the display list is in front", which is what `paint a document` does, and the absence of anything to escape from. The one capability genuinely lost is cross-window or OS-level layering ([`../window-system-integration/index.md`](../window-system-integration/index.md)).

> [!WARNING]
> Painting overlays last is not the same as _routing_ to them last. In this spec the two coincide because hit testing reads the same ordered set the painter reads. A toolkit whose input router resolves a container (a pane, a dock) by rectangle before it consults any widget tree's hit list needs an explicit top-layer rung in that router as well — see [`../../specs/ui/containers.md`](../../specs/ui/containers.md) and [`./sparkles-baseline.md`](./sparkles-baseline.md).

### 11. Modality

A popover is strictly **non-modal** and the spec works to keep it that way. `check popover validity` throws `InvalidStateError` if the element is a dialog whose `is modal` is true, or if its fullscreen flag is set (`source:92803`): you cannot be modal and a popover at once. Nothing is made inert; background pointer and keyboard input are not blocked. The only pointer consequence of an open popover is that a `pointerdown`/`pointerup` pair outside it light-dismisses. The accessibility modal bit does not appear in HTML here at all.

The scrim is `::backdrop`, which exists for every element rendered in the top layer — but the UA sheet gives a popover's backdrop `background-color: transparent` and, critically, `pointer-events: none !important` (`source:150631`), an explicit click-through in deliberate contrast to a dialog's translucent backdrop. Manual popovers are the fully passthrough case: no light dismiss, no close watcher, no stack participation.

**Algorithm.** [Modality](./concepts.md) is not a flag on the overlay. It is the presence or absence of two things: an inert-making rule keyed on the topmost dialog in the top layer, and a pointer-opaque backdrop. Popover opts out of both, so light dismiss is the only modality-adjacent behaviour, and it is per-stack rather than per-document.

**Where the behavior lives.** The HTML inert/modal-dialog machinery (dialog only), the UA stylesheet for `::backdrop`, and `check popover validity`.

**Degradation.** Cheap and directly portable: in a single-surface toolkit modality reduces to whether a full-surface scrim rect is appended before the overlay and whether the hit list below it is consulted. The three-way split this spec ships — Manual (in the layer, out of the stack, no dismissal), Auto (stack member, light dismiss), modal dialog (inerts everything below) — is a finer factoring than a boolean `modal` flag. And the `pointer-events: none` backdrop is a recorded trap: a scrim that eats clicks destroys light dismiss's ability to resolve the real target underneath. No [grab](./concepts.md) is involved anywhere; the platform has no equivalent and needs none, since all input already arrives at one document.

### 12. Adaptive presentation

No popover-to-sheet transformation, no hover-to-long-press substitution, no teaching tip, no keyboard-driven relocation. The one adaptation in the area is the customizable `select`: it owns a `select popover` (a div in the UA shadow tree, `source:153121`) that is rendered **only** when the control opts into base appearance; otherwise the user agent uses a native picker and the popover element is excluded from the layout tree (`source:153140`). The spec further notes that implementations should always build the base-appearance DOM and merely include or exclude it from layout, since appearance is determined by computed style and cannot be swapped structurally (`source:153136`).

**Algorithm.**

```text
appearance(select) = computed style => { native picker | select popover in the top layer }
open the picker    => show popover(selectPopover, focus: false, source: select)   // source:57406
```

The option-activation path calls the hide-popover algorithm on the select popover only in the base-appearance branch (`source:57361`). The popover algorithms are reused unchanged.

**Where the behavior lives.** CSS `appearance` plus the UA shadow tree. The decision belongs to the style/rendering layer — not to the component, and not to the application.

**Degradation.** The transferable shape is the seam, not the branch: one component whose surface decision is made by a _lower_ layer, with the overlay algorithms identical on both sides. A toolkit with no native-surface branch collapses the decision to a presentation choice within one surface — for example a touch target rendering a menu as a bottom sheet above the keyboard inset rather than as an anchored box. On this subject's evidence that choice belongs in the theme/target layer and the state machine should not know about it. What form the ladder takes, and what a substituted presentation owes the user, are questions this subject does not answer; see [`./features-people-forget.md`](./features-people-forget.md).

### 13. Accessibility

The primitive is deliberately semantics-free and says so. Beside the authoring note quoted in the Overview, the spec's own menu example ships hand-written `role=menu`, `role=menuitem`, `tabindex=-1` and `autofocus`, with the remark that "Navigating the menuitems with arrow keys and activation behaviors would still need author scripting" (`source:91766`).

> [!NOTE]
> A search of the spec source at this revision finds no line containing both "aria" and "popover", and no occurrence of `aria-haspopup` at all. HTML itself therefore specifies no implicit ARIA for popovers; the mapping lives in HTML-AAM, which was **not** read for this page. The negative is an observation about this document, not about the platform as a whole.

What the primitive does provide to assistive technology is threefold: the tab-order rewrite via `focus navigation scope owner` (`source:86001`), which is a real non-visual relationship; close requests that explicitly include "any assistive technology's dismiss gesture, such as iOS VoiceOver's two-finger scrub z gesture" (`source:88911`); and two authoring notes — place the popover immediately after its trigger in the DOM for reading order (`source:92985`), and beware that a popover inside `output` becomes a live region and may be annoying (`source:91810`). There is no hover-only hazard handling and no WCAG 1.4.13 mechanism, because there is no tooltip here — only a substrate.

**Algorithm.** Delegated.

**Where the behavior lives.** Split three ways: focus and tab order in HTML; role and state mapping in HTML-AAM plus author ARIA; the dismiss gesture inside the close-request abstraction.

**Degradation.** The line this subject draws is the reusable part: the _primitive_ owns stacking, dismissal (including an AT-reachable dismiss gesture), focus scope and tab order, and the trigger-to-surface link; the _semantic component_ owns role, name and description, expanded state, and arrow-key navigation. For a toolkit with no platform accessibility tree on any target, the only channel that can carry the semantic half is whatever the static-HTML emitter and the recording canvas can express — which suggests the primitive should carry a small semantic tag purely as data, rendered by the HTML emitter and ignored elsewhere. That is a proposal, not a finding: nothing in this subject says how a non-DOM target should behave, and the catalog's own baseline notes that the toolkit emits no ARIA today ([`./sparkles-baseline.md`](./sparkles-baseline.md)).

### 14. Animation

The animation story is entirely about the top layer, not about geometry. A popover is `display: none` when hidden and is removed from the top layer when hidden, so a naive exit animation would be impossible — the element would stop painting on top the instant it hid. The platform's answer has three parts:

1. Hiding calls `request an element to be removed from the top layer` (`css-position-4/Overview.bs:317`), which parks the element in `pending top layer removals` and drops its UA `overlay: auto` rule, but leaves it in the top layer set, so it keeps painting.
2. `overlay` is a real animatable property that authors cannot set but _can_ transition, interpolated as a discrete step in which any progress strictly between 0 and 1 maps to `auto` (like `visibility`), so under most easings the element stays rendered on top for the whole transition (`css-position-4/Overview.bs:428`).
3. `process top layer removals` (`css-position-4/Overview.bs:352`) runs at the end of each Update the Rendering and finally evicts anything whose computed `overlay` is `none` **or that is not rendered**. User agents may kill a running overlay transition at their discretion, which is the spec's answer to `transition: overlay 1e9s` abuse (`css-position-4/Overview.bs:455`).

```text
hide(fireEvents: true):  drop overlay:auto -> author transition runs -> each frame,
                         process top layer removals checks computed overlay ->
                         when it resolves to none (or the element is not rendered), evict
hide(fireEvents: false): evict now                                   // source:92436
```

No geometry metadata for animation is exposed: the popover primitive publishes no resolved side, no alignment and no [transform origin](./concepts.md). Reduced motion is not mentioned anywhere in the popover machinery.

> [!WARNING]
> The asymmetry is load-bearing. The `fireEvents = false` paths — DOM removal and nested hides — take `remove an element from the top layer immediately` and therefore bypass the exit transition entirely (`source:92429` versus `source:92436`). Destruction and teardown must take the immediate branch, or an animating overlay outlives its data.

**Where the behavior lives.** CSS Positioned Layout 4 (`overlay`, pending removals) plus HTML's Update the Rendering ordering. The popover algorithm's only contribution is choosing which of the two removal algorithms to call.

**Degradation.** No CSS transitions exist off the platform, but the _structure_ is cheap and target-independent: keep "in the overlay stack" (logical — hit testing, ancestor arithmetic, dismissal) apart from "painted in the overlay stack" (visual — the display list), let a closing overlay stay in the second while its animation plays, and drain it at the end of the frame. That is one extra set and one end-of-frame sweep. Note that the eviction predicate must also cover "not rendered", so a closing overlay whose owner disappeared does not linger. On a recording canvas the whole mechanism is assertable frame by frame with no window and no timing source beyond the frame counter.

### 15. State architecture

Not a reducer, not a state-machine object, not a controller: a set of document-scoped and element-scoped flags plus a family of free algorithms, with derived collections instead of stored ones.

| Scope    | State                                                                                                                                                                                                                                        |
| -------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Element  | `popover visibility state` (`source:91864`), `popover trigger`, `popover hiding`, `popover toggle task tracker`, `popover close watcher`, `opened in popover mode` (`source:91891`), `previously focused element`, `implicit anchor element` |
| Document | `popover pointerdown target`, `hiding popover nesting count` (`source:91895`), `showing popover` (`source:91898`), `hint stack parent` (`source:91901`), the top layer, pending removals                                                     |
| Derived  | both showing lists, the entire ancestor tree, stack position                                                                                                                                                                                 |

Control is uncontrolled by default — the element owns its state — with a controlled escape hatch through the cancelable `beforetoggle`; `toggle` is notification-only and is the coalesced one, while `beforetoggle` is synchronous and never coalesced.

The most striking architectural property is **defensive re-validation**. Because every event dispatch is a re-entry point, `show popover` re-runs `check popover validity` after `beforetoggle` (`source:92036`) and again after the stack-closing step (`source:92122`), and `hide a popover` does the same twice — five re-validations across the two algorithms, each with a spec note naming the exact hazard. `hide popover stack until` goes further and re-reads the list after user code has run:

> This happens if popovers are shown whilst hiding popovers. For example, in beforetoggle events. This is usually a developer error, so user agents are encouraged to show a warning. In this additional hiding phase, fireEvents is ignored, and false is used instead.
>
> — `source:92596` ([second cleanup pass][src-second-pass])

**Algorithm.** A handful of small scalars plus one ordered set; all relationships recomputed on demand. Three guards: `showing popover` (a bool latch) forbids re-entrant shows; `hiding popover nesting count` (an integer) makes hide re-entrancy explicit and counted; `popover hiding` (per element) suppresses duplicate events for one logical hide.

**Where the behavior lives.** Spread across the `Document` and every HTML element, deliberately. There is no popover manager object.

**Degradation.** This dimension survives a non-DOM, value-semantics, allocation-conscious toolkit better than a closure-based controller would: every piece of state is a scalar, an enum, an index or a handle; the only collection is one ordered array; there is no allocation on show or hide beyond the array push; and every derived query is a filter over that array. The re-validation discipline maps to a concrete rule for any toolkit that runs application callbacks inside its overlay algorithms — after any callback, re-check that the overlay id is still live and still of the same kind, and re-read any list you had already indexed. Nothing here needs a window, hover, sub-cell precision or a key release. It is worth stating what this subject does _not_ establish: it gives no evidence that a different formulation (returning effects as values, say) would make the guards unnecessary — the spec's own answer is to keep them and to add a sweep.

### 16. Shared infrastructure

The factoring is unusually explicit, because the same substrate now backs five features.

**Shared.** The top layer (popover, dialog, fullscreen). `hide popovers until`, called both by light dismiss and by `dialog.show()`/`showModal()` — unified at this revision after the dialog path was found to close the wrong set. The close-watcher infrastructure (popover, dialog and script's `CloseWatcher` share grouping and the anti-abuse budget, `source:89018`). `ToggleEvent` with `beforetoggle`/`toggle`, shared with `details` (`source:160480`). The toggle task tracker. And the two-phase pointer light-dismiss _shape_.

**Not shared, deliberately.** Focusing steps: popover focusing steps and dialog focusing steps are separate algorithms, and a `dialog` used as a popover explicitly detours to the dialog ones (`source:92750`). Modality and inertness (dialog only). The entire semantic layer. Meanwhile the customizable `select` reuses the popover algorithms wholesale for its picker rather than getting a surface of its own.

> [!NOTE]
> The counter-example is in the same spec. `dialog` re-implements two-phase light dismiss separately as `light dismiss open dialogs` with its own `dialog pointerdown target` (`source:67066`), and both are invoked from one `run light dismiss activities` (`source:67117`). Shared shape with unshared code produced a real divergence, fixed by the unification at this revision.

**Algorithm.** Not applicable — this dimension is a factoring observation.

**Where the behavior lives.** HTML: the popover section, the dialog section, close requests and close watchers, and the rendering section's UA stylesheet. CSS: Positioned Layout 4's top layer.

**Degradation.** What this subject puts in one primitive, none of which needs a window, hover, sub-cell precision or a key release: the ordered stack plus the pending-removal set; the ancestor computation over containment and invocation edges; show and hide with re-entrancy guards; endpoint-based cascade closing; two-phase pointer dismissal; the close-request hookup; the coalesced state-change notification; and the trigger-to-surface link (anchor, focus scope, event source). What it keeps apart, and what a toolkit should therefore hesitate to unify: initial-focus policy (the spec ships two focusing-steps algorithms and dispatches on element type), modality and scrim, hover and dwell timing (absent entirely here, and its absence is why the primitive stays small), semantics and roles, and the hint-versus-auto lifetime — which is a _stack choice_, not a component property.

## Strengths

- The overlay tree is derived, not stored: one ordered set plus a strict-ordering rule yields a well-formed tree from a cyclic graph of containment and invocation edges, with no cycle detection and no per-overlay parent pointer.
- Both stacks are projections of the top layer computed on read, so no two features have to agree on a merge order, and dialog, fullscreen and popover nest arbitrarily.
- One endpoint concept unifies pointer dismissal, a new overlay opening, and a dialog opening — and this revision folded the last straggler into it.
- Re-entrancy is treated as the default hazard rather than an edge case: a show latch, a counted hide depth, a per-element event-suppression flag, five defensive re-validations, and a re-read-and-sweep second pass after user code.
- Esc, the Android back gesture and AT dismiss gestures are one abstraction, specified on key **down**, with an anti-abuse budget tied to user activation.
- Animation is solved structurally by splitting logical stack membership from painted membership with a once-per-frame drain — no animation tracking inside the state machine.
- Tab order is rewired by making the invoker a focus-scope owner, so an overlay's position in the tree is irrelevant to keyboard navigation.
- Explicitly non-modal, with a pointer-transparent `::backdrop` and a hard validity error if you try to be a modal dialog and a popover at once.
- Manual is a genuinely useful third state: a top-layer surface with no stack participation, no light dismiss and no close watcher.
- The state is entirely scalars, enums, indices and handles plus one ordered set, which is why so much of it reads directly onto a value-semantics toolkit.

## Weaknesses

- No placement whatsoever: an unstyled popover is centred in the viewport, nowhere near its invoker. The anchoring story is a separate specification at a different maturity level, joined only by `implicit anchor element`.
- No timing, no hover trigger, no hover-travel handling. `popover=hint` was built for hover-driven surfaces, but no declarative hover trigger exists at this revision (`interestfor` returns zero hits), so the hint stack has no declarative producer.
- No arrow or caret concept, and no geometry metadata at all — the primitive cannot tell the styling layer which side it ended up on.
- No implicit ARIA in HTML itself; role, name and expanded state are author-supplied, and the spec's own menu example needs hand-written roles, `tabindex` and author scripting for arrow keys.
- `dialog` re-implements two-phase light dismiss separately instead of sharing popover's, and that split already produced a divergence.
- INFERENCE, read off the algorithm at `source:93077` rather than observed: opening a popover during `pointerdown` appears unsafe, because no `popover pointerdown target` is recorded for that gesture, so the following `pointerup` outside resolves `ancestor` to null, compares equal to the stored null, and dismisses. Not verified against any implementation.
- A show attempted during any show or hide throws `InvalidStateError`, so an author cannot legitimately swap one popover for another from a `beforetoggle` handler.
- The `overlay` transition is an author-controllable delay on top-layer eviction, mitigated only by "user agents may, at their discretion, remove a running transition" — an explicitly undefined escape hatch.
- One close request can close an entire _group_ of close watchers, so the number of Escapes needed to unwind a stack is not the depth of the stack (`source:89293`).
- Stack membership snapshots the _effective_ mode at show time, so identical markup can have a different lifetime depending on what was open when it was shown.

## Key design decisions and trade-offs

| Decision                                                                                                                                                                                     | Rationale                                                                                                                                                                                                | Trade-off                                                                                                                                                                                                                                          |
| -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| The overlay stack is a projection of one document-wide ordered set; `showing auto popover list` and `showing hint popover list` filter the top layer on every read.                          | Ordering, cross-feature nesting and paint order all derive from one insertion-ordered set the user agent alone owns. Two features never have to agree on a merge order.                                  | Every stack query is linear in the top layer, and the list can change between two reads inside one algorithm — which is exactly why `hide popover stack until` re-reads and runs a second pass, and why five re-validations litter `show popover`. |
| The parent/child relation is one integer: the index of the last showing popover that contains either the new popover or its invoker, containment and invocation merged by `max`.             | Two structurally different relationships collapse to one comparable value, and "the parent must be strictly earlier in the list" turns a possibly cyclic graph into a tree with no cycle-detection code. | The tree is only as good as list order: a popover nested inside another but shown _first_ is not its child and will be closed. Authors cannot express an ancestor relation that contradicts show order.                                            |
| Light dismiss is two-phase — `pointerdown` records, `pointerup` compares — with an identity test on the resolved popover rather than a hit test on a rect.                                   | Drag gestures (selecting text out of a popover, a scrollbar drag starting inside) do not dismiss, and neither does press-outside/release-inside, with no timing or geometry heuristics at all.           | Requires a mutable per-document `popover pointerdown target`, and creates the pointerdown-open hazard noted above (inference).                                                                                                                     |
| Hint is a second, strictly higher stack rather than a per-popover priority number; `combinedPopovers = autoList ++ hintList`, and stack position adds `autoList.length + 1` to hint indices. | Tooltip-like surfaces must be able to sit above a menu without closing it, and must all die together when the auto they hang off dies. One extra list plus one `hint stack parent` pointer buys both.    | An Auto whose ancestor is a Hint is silently demoted to Hint for its whole lifetime (`source:92083`), so identical markup yields a different lifetime depending on what was open, and `opened in popover mode` must be stored per element.         |
| Re-entrancy is banned outward but permitted inward: show throws while any show or hide is in flight; hide recurses freely and self-suppresses events.                                        | Cascading closes are inherently recursive; cascading opens are author error and previously produced unbounded re-entrancy.                                                                               | Swapping one popover for another inside `beforetoggle` is impossible; and hides still need the second cleanup pass, because handlers can show popovers from outside the guard window.                                                              |
| Exit animation is a deferred removal — `pending top layer removals` plus the UA-only, author-transitionable `overlay` property — resolved once per frame.                                    | Keeps "is in the stack" (logical, used by the algorithms) apart from "is painted on top" (visual, used by painting and `::backdrop`) so animation cannot corrupt stack arithmetic.                       | Two predicates that every consuming spec must choose between correctly, plus an abuse vector answered only by "user agents may, at their discretion".                                                                                              |
| Sequential focus order is rewired by making the invoker a `focus navigation scope owner`.                                                                                                    | Tab-from-the-button-into-the-popover works regardless of where the popover element lives in the document.                                                                                                | Focus order becomes a function of runtime state (which popover is showing, with which `source`) and cannot be computed from the static tree — and the spec still has to ask authors to place the popover after its trigger for reading order.      |
| The primitive ships no initial-focus policy: focus moves only for `autofocus` or an autofocus delegate, and only under transient activation.                                                 | Tooltip, menu and dialog want different focus behaviour; a substrate should default to not moving focus, and script-shown surfaces should not steal it.                                                  | Every real component must implement its own roving focus; the primitive is not usable as a menu without author script, which the spec states outright.                                                                                             |
| Escape is not handled by the popover at all — it delegates to the generic close-watcher mechanism, grouped and rate-limited by user activation.                                              | Unifies Esc, Android back and AT dismiss gestures into one close-request concept, and stops a page swallowing unlimited back navigations by opening popovers.                                            | One close request can close a whole group of watchers, so the stack depth an author sees is not the number of Escapes needed to unwind it.                                                                                                         |

## Sources

Primary sources, all read at the pinned revisions in the metadata table.

- WHATWG HTML `source` — the popover section: state definitions ([`:91864`][src-visibility], [`:91891`][src-opened-mode], [`:91895`][src-hiding-count], [`:91898`][src-showing-bool], [`:91901`][src-hint-parent]), `show popover` ([`:91971`][src-show], guard at [`:91979`][src-show-guard], demotion at [`:92083`][src-demote]), `hide a popover` ([`:92283`][src-hide]), `hide popover stack until` ([`:92551`][src-hide-stack], second pass note at [`:92596`][src-second-pass]), `hide popovers until` ([`:92521`][src-hide-until]), `topmost popover ancestor` ([`:92612`][src-ancestor], tree note at [`:92634`][src-tree-note]), the toggle-task coalescer ([`:92229`][src-toggle-task]), and the derived stack lists ([`:92833`][src-lists]).
- WHATWG HTML `source` — light dismiss and invocation: [`:93077`][src-light-dismiss] (`light dismiss open popovers`), [`:93105`][src-same-target] (`sameTarget`), [`:93120`][src-topmost-clicked] and [`:93139`][src-stack-position], the activation behavior at [`:92999`][src-activation] with the nested-invoker guard at [`:93006`][src-invoker-guard], `popover target element` at [`:93042`][src-target-element], and the command keywords at [`:56739`][src-command].
- WHATWG HTML `source` — close requests and close watchers: [`:88911`][src-at-dismiss] (AT dismiss gestures), [`:88996`][src-keydown] (fire on key down), [`:89018`][src-close-watchers], [`:89035`][src-close-abuse], [`:89293`][src-process-watchers].
- WHATWG HTML `source` — focus: `popover focusing steps` [`:92744`][src-focusing-steps] with the dialog detour at [`:92750`][src-dialog-detour], `allow focus steps` [`:87211`][src-allow-focus], `shouldRestoreFocus` [`:92143`][src-should-restore], the conditional restore at [`:92464`][src-restore-guard], `focus navigation scope owner` [`:86001`][src-scope-owner], and `blocked by a modal dialog` [`:84990`][src-blocked-modal].
- WHATWG HTML `source` — rendering, dialogs and `select`: the UA stylesheet [`:150618`][src-ua-sheet] and the backdrop rule [`:150631`][src-ua-backdrop]; `process top layer removals` in Update the Rendering [`:123114`][src-render-removals]; dialog interaction [`:66434`][src-dialog-show], [`:67066`][src-dialog-light-dismiss], [`:67117`][src-run-light-dismiss]; the customizable `select` [`:153121`][src-select-popover], [`:153136`][src-select-note], [`:153140`][src-select-base], [`:57406`][src-select-open].
- WHATWG HTML `source` — authoring and validity notes: [`:91758`][src-aria-note], [`:91766`][src-menu-script], [`:91786`][src-settimeout], [`:91810`][src-output-warning], [`:91836`][src-manual], [`:91843`][src-hint], [`:91922`][src-attr-change], [`:92803`][src-validity], [`:92985`][src-after-trigger], [`:1867`][src-removing-steps], [`:13058`][src-showpopover-options].
- CSS Positioned Layout 4 (`css-position-4/Overview.bs`) — the top layer [`:136`][css-top-layer], the clipping note [`:146`][css-clip-note], UA ownership [`:167`][css-ua-managed], top-layer styling [`:194`][css-styling], the logical/visual split [`:269`][css-membership] and its usage note [`:286`][css-membership-note], add [`:303`][css-add], request removal [`:317`][css-request-removal], process removals [`:352`][css-process-removals], `overlay` interpolation [`:428`][css-overlay-discrete] and the UA `!important` rule [`:443`][css-overlay-unsettable], the transition escape hatch [`:455`][css-overlay-kill], and `paint a document` [`:513`][css-paint].
- CSS Anchor Positioning 1 (`css-anchor-position-1/Overview.bs`), adjacent context at a different revision — the implicit anchor element [`:586`][anchor-implicit], `position-try-order` [`:1682`][anchor-try-order], the fallback algorithm [`:1948`][anchor-fallback], `last successful position option` [`:2043`][anchor-last-successful], `position-visibility` [`:2222`][anchor-visibility] and `clipped by intervening boxes` [`:2262`][anchor-clipped].

Catalog context: [`./index.md`](./index.md), [`./concepts.md`](./concepts.md), [`./comparison.md`](./comparison.md), [`./features-people-forget.md`](./features-people-forget.md), [`./sparkles-baseline.md`](./sparkles-baseline.md), [`./proposal.md`](./proposal.md). Closest siblings: [`./css-anchor.md`](./css-anchor.md) (the placement half of the same platform), [`./blink.md`](./blink.md) (an implementation of both), [`./angular-cdk.md`](./angular-cdk.md) (a library that adopts this primitive as a backend), [`./aria-apg.md`](./aria-apg.md) (the semantics this spec delegates). Toolkit specs: [`../../specs/ui/index.md`](../../specs/ui/index.md), [`../../specs/ui/containers.md`](../../specs/ui/containers.md), [`../../specs/ui/state-machines.md`](../../specs/ui/state-machines.md), [`../../specs/ui/input.md`](../../specs/ui/input.md).

<!-- References -->

[html-repo]: https://github.com/whatwg/html/tree/ac0389a3aca0331055bf4bf23f509c2913e3f795
[csswg-repo]: https://github.com/w3c/csswg-drafts/tree/6dc15cc9cb15043840eacf081e89f5a666fa7889
[html-docs]: https://html.spec.whatwg.org/multipage/popover.html
[css-pos-docs]: https://drafts.csswg.org/css-position-4/
[css-anchor-docs]: https://drafts.csswg.org/css-anchor-position-1/
[src-visibility]: https://github.com/whatwg/html/blob/ac0389a3aca0331055bf4bf23f509c2913e3f795/source#L91864
[src-opened-mode]: https://github.com/whatwg/html/blob/ac0389a3aca0331055bf4bf23f509c2913e3f795/source#L91891
[src-hiding-count]: https://github.com/whatwg/html/blob/ac0389a3aca0331055bf4bf23f509c2913e3f795/source#L91895
[src-showing-bool]: https://github.com/whatwg/html/blob/ac0389a3aca0331055bf4bf23f509c2913e3f795/source#L91898
[src-hint-parent]: https://github.com/whatwg/html/blob/ac0389a3aca0331055bf4bf23f509c2913e3f795/source#L91901
[src-show]: https://github.com/whatwg/html/blob/ac0389a3aca0331055bf4bf23f509c2913e3f795/source#L91971
[src-show-guard]: https://github.com/whatwg/html/blob/ac0389a3aca0331055bf4bf23f509c2913e3f795/source#L91979
[src-demote]: https://github.com/whatwg/html/blob/ac0389a3aca0331055bf4bf23f509c2913e3f795/source#L92083
[src-hide]: https://github.com/whatwg/html/blob/ac0389a3aca0331055bf4bf23f509c2913e3f795/source#L92283
[src-hide-stack]: https://github.com/whatwg/html/blob/ac0389a3aca0331055bf4bf23f509c2913e3f795/source#L92551
[src-second-pass]: https://github.com/whatwg/html/blob/ac0389a3aca0331055bf4bf23f509c2913e3f795/source#L92596
[src-hide-until]: https://github.com/whatwg/html/blob/ac0389a3aca0331055bf4bf23f509c2913e3f795/source#L92521
[src-ancestor]: https://github.com/whatwg/html/blob/ac0389a3aca0331055bf4bf23f509c2913e3f795/source#L92612
[src-tree-note]: https://github.com/whatwg/html/blob/ac0389a3aca0331055bf4bf23f509c2913e3f795/source#L92634
[src-toggle-task]: https://github.com/whatwg/html/blob/ac0389a3aca0331055bf4bf23f509c2913e3f795/source#L92229
[src-lists]: https://github.com/whatwg/html/blob/ac0389a3aca0331055bf4bf23f509c2913e3f795/source#L92833
[src-light-dismiss]: https://github.com/whatwg/html/blob/ac0389a3aca0331055bf4bf23f509c2913e3f795/source#L93077
[src-same-target]: https://github.com/whatwg/html/blob/ac0389a3aca0331055bf4bf23f509c2913e3f795/source#L93105
[src-topmost-clicked]: https://github.com/whatwg/html/blob/ac0389a3aca0331055bf4bf23f509c2913e3f795/source#L93120
[src-stack-position]: https://github.com/whatwg/html/blob/ac0389a3aca0331055bf4bf23f509c2913e3f795/source#L93139
[src-activation]: https://github.com/whatwg/html/blob/ac0389a3aca0331055bf4bf23f509c2913e3f795/source#L92999
[src-invoker-guard]: https://github.com/whatwg/html/blob/ac0389a3aca0331055bf4bf23f509c2913e3f795/source#L93006
[src-target-element]: https://github.com/whatwg/html/blob/ac0389a3aca0331055bf4bf23f509c2913e3f795/source#L93042
[src-command]: https://github.com/whatwg/html/blob/ac0389a3aca0331055bf4bf23f509c2913e3f795/source#L56739
[src-at-dismiss]: https://github.com/whatwg/html/blob/ac0389a3aca0331055bf4bf23f509c2913e3f795/source#L88911
[src-keydown]: https://github.com/whatwg/html/blob/ac0389a3aca0331055bf4bf23f509c2913e3f795/source#L88996
[src-close-watchers]: https://github.com/whatwg/html/blob/ac0389a3aca0331055bf4bf23f509c2913e3f795/source#L89018
[src-close-abuse]: https://github.com/whatwg/html/blob/ac0389a3aca0331055bf4bf23f509c2913e3f795/source#L89035
[src-process-watchers]: https://github.com/whatwg/html/blob/ac0389a3aca0331055bf4bf23f509c2913e3f795/source#L89293
[src-focusing-steps]: https://github.com/whatwg/html/blob/ac0389a3aca0331055bf4bf23f509c2913e3f795/source#L92744
[src-dialog-detour]: https://github.com/whatwg/html/blob/ac0389a3aca0331055bf4bf23f509c2913e3f795/source#L92750
[src-allow-focus]: https://github.com/whatwg/html/blob/ac0389a3aca0331055bf4bf23f509c2913e3f795/source#L87211
[src-should-restore]: https://github.com/whatwg/html/blob/ac0389a3aca0331055bf4bf23f509c2913e3f795/source#L92143
[src-restore-guard]: https://github.com/whatwg/html/blob/ac0389a3aca0331055bf4bf23f509c2913e3f795/source#L92464
[src-scope-owner]: https://github.com/whatwg/html/blob/ac0389a3aca0331055bf4bf23f509c2913e3f795/source#L86001
[src-blocked-modal]: https://github.com/whatwg/html/blob/ac0389a3aca0331055bf4bf23f509c2913e3f795/source#L84990
[src-ua-sheet]: https://github.com/whatwg/html/blob/ac0389a3aca0331055bf4bf23f509c2913e3f795/source#L150618
[src-ua-backdrop]: https://github.com/whatwg/html/blob/ac0389a3aca0331055bf4bf23f509c2913e3f795/source#L150631
[src-render-removals]: https://github.com/whatwg/html/blob/ac0389a3aca0331055bf4bf23f509c2913e3f795/source#L123114
[src-dialog-show]: https://github.com/whatwg/html/blob/ac0389a3aca0331055bf4bf23f509c2913e3f795/source#L66434
[src-dialog-light-dismiss]: https://github.com/whatwg/html/blob/ac0389a3aca0331055bf4bf23f509c2913e3f795/source#L67066
[src-run-light-dismiss]: https://github.com/whatwg/html/blob/ac0389a3aca0331055bf4bf23f509c2913e3f795/source#L67117
[src-select-popover]: https://github.com/whatwg/html/blob/ac0389a3aca0331055bf4bf23f509c2913e3f795/source#L153121
[src-select-note]: https://github.com/whatwg/html/blob/ac0389a3aca0331055bf4bf23f509c2913e3f795/source#L153136
[src-select-base]: https://github.com/whatwg/html/blob/ac0389a3aca0331055bf4bf23f509c2913e3f795/source#L153140
[src-select-open]: https://github.com/whatwg/html/blob/ac0389a3aca0331055bf4bf23f509c2913e3f795/source#L57406
[src-aria-note]: https://github.com/whatwg/html/blob/ac0389a3aca0331055bf4bf23f509c2913e3f795/source#L91758
[src-menu-script]: https://github.com/whatwg/html/blob/ac0389a3aca0331055bf4bf23f509c2913e3f795/source#L91766
[src-settimeout]: https://github.com/whatwg/html/blob/ac0389a3aca0331055bf4bf23f509c2913e3f795/source#L91786
[src-output-warning]: https://github.com/whatwg/html/blob/ac0389a3aca0331055bf4bf23f509c2913e3f795/source#L91810
[src-manual]: https://github.com/whatwg/html/blob/ac0389a3aca0331055bf4bf23f509c2913e3f795/source#L91836
[src-hint]: https://github.com/whatwg/html/blob/ac0389a3aca0331055bf4bf23f509c2913e3f795/source#L91843
[src-attr-change]: https://github.com/whatwg/html/blob/ac0389a3aca0331055bf4bf23f509c2913e3f795/source#L91922
[src-validity]: https://github.com/whatwg/html/blob/ac0389a3aca0331055bf4bf23f509c2913e3f795/source#L92803
[src-after-trigger]: https://github.com/whatwg/html/blob/ac0389a3aca0331055bf4bf23f509c2913e3f795/source#L92985
[src-removing-steps]: https://github.com/whatwg/html/blob/ac0389a3aca0331055bf4bf23f509c2913e3f795/source#L1867
[src-showpopover-options]: https://github.com/whatwg/html/blob/ac0389a3aca0331055bf4bf23f509c2913e3f795/source#L13058
[css-top-layer]: https://github.com/w3c/csswg-drafts/blob/6dc15cc9cb15043840eacf081e89f5a666fa7889/css-position-4/Overview.bs#L136
[css-clip-note]: https://github.com/w3c/csswg-drafts/blob/6dc15cc9cb15043840eacf081e89f5a666fa7889/css-position-4/Overview.bs#L146
[css-ua-managed]: https://github.com/w3c/csswg-drafts/blob/6dc15cc9cb15043840eacf081e89f5a666fa7889/css-position-4/Overview.bs#L167
[css-styling]: https://github.com/w3c/csswg-drafts/blob/6dc15cc9cb15043840eacf081e89f5a666fa7889/css-position-4/Overview.bs#L194
[css-membership]: https://github.com/w3c/csswg-drafts/blob/6dc15cc9cb15043840eacf081e89f5a666fa7889/css-position-4/Overview.bs#L269
[css-membership-note]: https://github.com/w3c/csswg-drafts/blob/6dc15cc9cb15043840eacf081e89f5a666fa7889/css-position-4/Overview.bs#L286
[css-add]: https://github.com/w3c/csswg-drafts/blob/6dc15cc9cb15043840eacf081e89f5a666fa7889/css-position-4/Overview.bs#L303
[css-request-removal]: https://github.com/w3c/csswg-drafts/blob/6dc15cc9cb15043840eacf081e89f5a666fa7889/css-position-4/Overview.bs#L317
[css-process-removals]: https://github.com/w3c/csswg-drafts/blob/6dc15cc9cb15043840eacf081e89f5a666fa7889/css-position-4/Overview.bs#L352
[css-overlay-discrete]: https://github.com/w3c/csswg-drafts/blob/6dc15cc9cb15043840eacf081e89f5a666fa7889/css-position-4/Overview.bs#L428
[css-overlay-unsettable]: https://github.com/w3c/csswg-drafts/blob/6dc15cc9cb15043840eacf081e89f5a666fa7889/css-position-4/Overview.bs#L443
[css-overlay-kill]: https://github.com/w3c/csswg-drafts/blob/6dc15cc9cb15043840eacf081e89f5a666fa7889/css-position-4/Overview.bs#L455
[css-paint]: https://github.com/w3c/csswg-drafts/blob/6dc15cc9cb15043840eacf081e89f5a666fa7889/css-position-4/Overview.bs#L513
[anchor-implicit]: https://github.com/w3c/csswg-drafts/blob/6dc15cc9cb15043840eacf081e89f5a666fa7889/css-anchor-position-1/Overview.bs#L586
[anchor-try-order]: https://github.com/w3c/csswg-drafts/blob/6dc15cc9cb15043840eacf081e89f5a666fa7889/css-anchor-position-1/Overview.bs#L1682
[anchor-fallback]: https://github.com/w3c/csswg-drafts/blob/6dc15cc9cb15043840eacf081e89f5a666fa7889/css-anchor-position-1/Overview.bs#L1948
[anchor-last-successful]: https://github.com/w3c/csswg-drafts/blob/6dc15cc9cb15043840eacf081e89f5a666fa7889/css-anchor-position-1/Overview.bs#L2043
[anchor-visibility]: https://github.com/w3c/csswg-drafts/blob/6dc15cc9cb15043840eacf081e89f5a666fa7889/css-anchor-position-1/Overview.bs#L2222
[anchor-clipped]: https://github.com/w3c/csswg-drafts/blob/6dc15cc9cb15043840eacf081e89f5a666fa7889/css-anchor-position-1/Overview.bs#L2262
