# Blink (C++, Chromium rendering engine)

Blink implements the anchored overlay as two systems that share exactly one pointer: `popover` owns lifecycle and does no geometry, CSS anchor positioning owns geometry and knows nothing about popovers — and almost all of the implementation's difficulty turns out to be keeping the placement _stable_ across frames rather than getting it right in one.

| Field             | Value                                                                                                                                                                              |
| ----------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language          | C++                                                                                                                                                                                |
| License           | BSD-3-Clause (Chromium Authors); Blink core additionally carries legacy LGPL-2 / LGPL-2.1 / Apple-BSD headers                                                                      |
| Repository        | [chromium/src][repo] (Gitiles; the GitHub mirror carries the same commit hashes)                                                                                                   |
| Documentation     | No per-feature engine documentation was read. The normative specs behind this code are covered separately in [`./css-anchor.md`][css-anchor] and [`./popover-api.md`][popover-api] |
| Category          | Web platform — implementation (the browser engine, not the spec)                                                                                                                   |
| Surface model     | In-canvas. The [top layer][concepts] is a per-`Document` ordered vector of `Element`s painted after everything else in the same renderer surface                                   |
| **Revision read** | [`b0e30a9973232cee28901ea5d6cd4de6ea9428aa`][repo-pin] (Chromium `main`, read 2026-08-11)                                                                                          |

Every path read here paints into the page. `Document::top_layer_elements_` is an ordered vector of elements, not an OS window and not a compositor layer ([`core/dom/document.cc:8613`][doc-addtop]). Native OS popups still exist in Chromium for the legacy `<select>` `PopupMenu` path, but that code lives outside the sparse checkout used for this reading and none of it is described below.

> [!IMPORTANT]
> This page is a static source reading at one pinned revision. Nothing was built or run, no web-platform tests were executed, and several directories were not materialised in the checkout — `core/input`, `core/paint`, `core/page`, `core/style` and all of `modules/`. Where a claim depends on unread code it is marked in place. The per-frame cost figures below are **derived from the loop structure**, never measured.

Paths in prose are relative to `third_party/blink/renderer/`; every one resolves to a pinned URL in the reference block at the bottom.

---

## Overview

### What it solves

Blink has to serve two constituencies that a toolkit usually serves with one mechanism. Authors want a _declarative_ anchored overlay — "put this menu below that button, and if it does not fit, try these other arrangements" — expressed entirely in CSS, with no measurement code and no script. Simultaneously, the HTML `popover` attribute has to give any element top-layer lifecycle, [light dismiss][concepts], Escape handling and focus behaviour without prescribing where the element goes.

The engine's answer is a hard split. `popover` (`core/html/html_element.cc`, `core/dom/popover_data.h`) owns a type (`auto` / `hint` / `manual`), two ordered stacks on `Document`, ancestor discovery over three relationship kinds, cascading close, light dismiss, focus restoration, a `CloseWatcher` for Escape and the Android back button, and deferred top-layer removal so exit animations can run. It performs **zero** positioning. CSS anchor positioning (`core/css/anchor_query.h`, `core/layout/anchor_map.cc`, `core/layout/anchor_evaluator_impl.cc`, `core/layout/out_of_flow_layout_part.cc`) owns geometry: [anchor][concepts] references bubble up the containing-block chain during layout into an `AnchorMap`, `anchor()` and `anchor-size()` are resolved by an evaluator whose _mode_ is set by whichever property is currently being computed, and [constraint adjustment][concepts] is a retry-the-whole-layout loop over `position-try-fallbacks`.

The only coupling between the halves is one field. `PopoverData::implicit_anchor_` is a `WeakMember<Element>` ([`core/dom/popover_data.h:129`][pd-anchor]) set from the invoker at show time ([`core/html/html_element.cc:2113`][he-setanchor]) and read by `position-anchor: auto` through `Element::ImplicitAnchorElement` ([`core/dom/element.cc:13874`][el-implicitanchor]).

### Design philosophy

"Declarative, and pay for it in passes." Nothing in this engine measures a rendered popup and then nudges it. Each candidate placement is a whole _style_ — a synthesised `@position-try` declaration set plus a bitmask "try tactic" flip — and the engine re-runs style recalc plus layout for the anchored subtree once per candidate until one does not overflow its inset-modified containing block. The spec licenses the resulting cost cap by fiat rather than deriving it:

> ```text
> // The spec says:
> // "Implementations may choose to impose an implementation-defined limit on the
> // length of position fallbacks lists, to limit the amount of excess layout work
> // that may be required. This limit must be at least five."
> // The "+1" is because the first attempt is without anything from the position
> // fallbacks list applied.
> constexpr unsigned kMaxTryAttempts = 5 + 1;
> ```
>
> — [`core/layout/out_of_flow_layout_part.cc:1989-1995`][oofl-maxtry]

The second, less obvious commitment is that _stability_ — not correctness — is where the complexity lives. A sticky "last successful fallback", per-anchor "remembered scroll offsets", and a per-candidate validity interval re-checked once per frame all exist for one purpose: to stop the popup flickering between two arrangements while the user scrolls. And placement decisions are deliberately taken against the un-animated style:

> ```cpp
> // Do @position-try placement decisions on the *base style* to avoid
> // interference from animations and transitions.
> const ComputedStyle& style = iter.ActivateBaseStyleForTryAttempt();
> ```
>
> — [`core/layout/out_of_flow_layout_part.cc:2146-2148`][oofl-basestyle]

Without that, a running transition on the popup's size would feed back into which side it flips to, and oscillate at the transition's own frequency.

---

## How it works

### The two halves, and the seam

```text
      popover / interestfor  (core/html, core/dom)
      ────────────────────────────────────────────
      type auto|hint|manual · two ordered stacks · ancestor tree
      light dismiss (down/up pair) · CloseWatcher · focus restore
      deferred top-layer removal
                          │
                          │  PopoverData::implicit_anchor_   (one WeakMember)
                          ▼
      CSS anchor positioning (core/css, core/layout)
      ────────────────────────────────────────────
      AnchorMap (registry) · AnchorQuery (value) · AnchorEvaluatorImpl
      OutOfFlowLayoutPart::CalculateOffset (the fallback loop)
      AnchorPositionScrollData (per-frame validity)
```

Neither half can ask the other a question. The popover layer never learns which side it ended up on; the positioning layer never learns that its box is a popover.

### One frame, for one anchored box

1. **Registration.** During layout, each fragment carrying an `anchor-name` (or eligible as an implicit anchor) calls `AnchorMap::SetFromChild` on its container, accumulating a `TransformState` that maps the anchor's border box into the container's coordinate space. These maps bubble up the containing-block chain.
2. **Fast-out.** Every out-of-flow box reaches the placement code, so there is an explicit predicate to keep unrelated absolutely-positioned layout free — the comment says so directly: "it's important to avoid the expensive call to UpdateStyle here if we _don't_ depend on `anchor*()`, since every out-of-flow will reach this function" ([`core/layout/out_of_flow_layout_part.cc:265-269`][oofl-fastout], predicate `ElementStyleDependsOnAnchor` at `:278`).
3. **Candidate loop.** `CalculateOffset` iterates candidates through `OOFCandidateStyleIterator`. Each iteration installs the base style, computes the containing-block rect, contracts it by `position-area` offsets, resolves insets/margins/alignment, computes inline then block dimensions, and tests the margin box against the inset-modified containing block per axis.
4. **Commit.** The winner's index is committed, and `TryCalculateOffset` runs **one more time** with the real (animated) style ([`core/layout/out_of_flow_layout_part.cc:2146`][oofl-basestyle] for the split).
5. **Post-layout snapshot.** Once per frame, `AnchorPositionScrollData::TakeAndCompareSnapshot` recomputes the accumulated scroll/sticky/chained offset and classifies the change ([`core/layout/anchor_position_scroll_data.cc:269`][apsd-snapshot]).

### Overflow, and the interval you get for free

The overflow test is not a rect intersection against a viewport. It is two signed distances per axis, and those distances _are_ the [slide][concepts] slack:

```text
start_slack = margin_box_start - imcb_inset_start
end_slack   = imcb_inset_end   - margin_box_end
overflow    = (start_slack < 0) || (end_slack < 0)

// when the corresponding inset is auto, the slacks publish the scroll bounds:
scroll_max  =  start_slack
scroll_min  = -end_slack
```

`CalculateNonOverflowingRangeInOneAxis` ([`core/layout/out_of_flow_layout_part.cc:66`][oofl-range]) returns the overflow verdict and, as a side effect, the scroll delta interval over which that verdict would not change. The union over both axes is a `PhysicalScrollRange` — a validity certificate attached to the candidate.

### The flip algebra

`position-try-fallbacks` entries are either `@position-try` rule names or a `<try-tactic>`: a flip. A tactic is not a placement; it is a canonical 3-bit transform over the eight mirror arrangements, with a documented normalisation table, a closed-form `Inverse()`, and `CacheIndex()` doubling as the index into an eight-slot memo of generated flip declaration sets ([`core/css/try_tactic_transform.h:72`][ttt], `Inverse` at `:148`, `CacheIndex` at `:166`).

```text
bits_ : kBlock | kInline | kStart          (3 bits, 8 values incl. identity)

FlipBlock()  : xor kBlock  — unless kStart is already set, then xor kInline
FlipInline() : xor kInline — unless kStart is already set, then xor kBlock

Transform()  : applies the flips as swaps in reverse order (start, block, inline)
Inverse()    : identity for six of eight; swaps (block|start) <-> (inline|start)
```

The flip is applied to **properties**, not values: `TryValueFlips::CreateFlipSet` emits an `-internal-flip-revert(<other-property>)` declaration per affected property ([`core/css/try_value_flips.cc:39`][tvf]), and building that table requires the _inverse_ transform — `right: anchor(left)` under flip-inline plus flip-start must yield `top: anchor(bottom)`, which only falls out if the transformed property table is read backwards.

### The reference consumer

Blink's own UA stylesheet is a real client of the whole mechanism, so the declarative path is exercised on every `<select>` popup:

```css
/* core/html/resources/html.css:2256-2261, ::picker(select) */
position-area: self-block-end span-self-inline-end;
position-try-order: most-block-size;
position-try-fallbacks:
  self-block-start span-self-inline-end,
  self-block-end span-self-inline-start,
  self-block-start span-self-inline-start;
```

---

## The analysis spine

### 1. Anchor model

There are two independent anchor concepts, and only one of them is a value.

The **popover's** anchor is a single element pointer, `PopoverData::implicit_anchor_`, set from the invoker in `ShowPopoverInternal` ([`core/html/html_element.cc:2113`][he-setanchor]) and nulled when the element actually leaves the top layer. It is a `WeakMember`: the anchor may die under the popup, so the handle carries liveness, not geometry.

The **CSS** anchor is an `AnchorQuery` value — query type (`anchor` or `anchor-size`), an `AnchorSpecifierValue` (a scoped name, or "default"), a float percentage, and a variant of the two value enums — with `operator==`, `DISALLOW_NEW`, and no identity of its own ([`core/css/anchor_query.h:24`][anchorquery]). Resolution goes through `AnchorMap`, keyed by `AnchorKey = std::variant<const AnchorScopedName*, const Element*>` ([`core/layout/anchor_map.h:87`][anchormap-key]) — named anchors and element anchors are kept in two separate hash maps rather than growing the key by a pointer.

The stored value is a `PhysicalAnchorReference` holding a full `TransformState` rather than a rect, so the anchor's quad composes through ancestor transforms; the rect is taken late as `TransformedBoundingRect()`, the enclosing rect of the mapped quad ([`core/layout/anchor_map.h:52`][anchormap-rect]). It carries `is_out_of_flow`, a running-transform-animation flag, and a set of display locks. Multiple boxes may claim one key: references form a singly linked list in **reverse tree order** ([`core/layout/anchor_map.cc:44`][anchormap-insert]), and fragments of the same `LayoutObject` are united into one reference rather than added twice.

The [anchor rect][concepts] is therefore always a single axis-aligned rect. There are no multi-rect or text-range anchors, no point or cursor anchors, and no [virtual anchor][concepts] concept at all. `anchor-scope` scopes names. At the popover layer there is no "many triggers, one popup" either: `SetPopoverInvoker` replaces the previous invoker and clears its back-pointer, so a popup has exactly one live invoker — though arbitrarily many elements may _target_ it, which is why `MarkPopoverInvokersDirty` walks the tree scope's invoker lists to dirty them all ([`core/html/html_element.cc:1573`][he-invokersdirty]).

**Algorithm.** Lookup is `AnchorMap::AnchorReference(query_box, actual_cb, key)`: fetch the head of the reverse-tree-order list for the key, walk it, and skip (i) detached layout objects, (ii) the query box itself, (iii) out-of-flow references that are not `IsBeforeInPreOrder(query_box)`, (iv) under block fragmentation, references whose container is not contained by the query box's actual CSS containing block. The first survivor wins — i.e. the _last acceptable anchor in tree order_. The "must precede" rule applies **only** to out-of-flow references:

> ```cpp
>     if (!layout_object || layout_object == &query_box ||
>         (result->IsOutOfFlow() &&
>          !layout_object->IsBeforeInPreOrder(query_box))) {
>       continue;
>     }
> ```
>
> — [`core/layout/anchor_map.cc:74-78`][anchormap-accept]

An in-flow anchor may appear _after_ the popup in tree order, because in-flow layout has already finished when out-of-flow boxes are laid out.

**Where it lives.** `core/dom/popover_data.h` (the element pointer); `core/css/anchor_query.h` (the value); `core/layout/anchor_map.{h,cc}` (registry plus acceptability rule); `core/layout/anchor_evaluator_impl.cc` (resolution); `core/dom/element.cc:13874` (`Element::ImplicitAnchorElement`, the bridge — which also gives `::before`, `::after`, `::backdrop` and `::interest-button` their originating element as implicit anchor).

**Degradation.** The value half survives every constraint in this catalog: `AnchorQuery` is comparable plain data and `AnchorKey` is a variant of two pointers, both of which map onto a D sum type with value semantics. The registry half does not — it presumes a layout pass that walks a containing-block chain accumulating transforms. With no sub-cell precision the `TransformState` collapses to an integer cell rect and `EnclosingRect` becomes exactly the round-outward step a cell grid wants. With no OS window nothing is lost, because Blink never maps to screen coordinates at all: every value here is document-relative. With no script the entire mechanism is still available, since it is CSS — this is the one dimension where the web platform's static tier is _stronger_ than a script-driven toolkit's, and it works precisely because nothing is measured at emit time. See [`./sparkles-baseline.md`][baseline] for what the toolkit's own anchor producers look like.

### 2. Placement model

There are no "sides" and no alignment enum in this engine. [Placement][concepts] is expressed three ways, all reducing to ordinary CSS box layout:

1. `anchor()` inside an inset property, resolved per-property by the evaluator's mode.
2. `position-area`, a grid of regions that **contracts** the containing block by insets computed from the anchor's edges, after which the popup lays out normally inside the shrunken box ([`core/layout/anchor_evaluator_impl.cc:557`][ae-posarea]).
3. `anchor-center` alignment.

All three are logical-first. `CSSAnchorValue` has `start`/`end`/`self-start`/`self-end`/`inside`/`outside`, converted to physical by `PhysicalAnchorValueFromLogicalOrAuto` against the _container's_ writing direction (or the element's own, for the `self-` forms) ([`core/layout/anchor_evaluator_impl.cc:38`][ae-logical]); `inside`/`outside` resolve against which inset property is being computed. Percentages are logical too and are mirrored (`percentage = 100 - percentage`) when the axis flips.

Preferred lists are `position-try-fallbacks`. `position-try-order` (`normal`, `most-width`, `most-height`, `most-block-size`, `most-inline-size`) turns the ordered list into a scored one: candidates are all evaluated and `stable_sort`ed by the size of the inset-modified containing block each would receive ([`core/layout/out_of_flow_layout_part.cc:2040`][oofl-sort]).

What does not exist as a concept anywhere in this code: viewport padding, custom boundaries, safe-area insets, work areas, multi-monitor geometry, IME avoidance. The [clipping boundary][concepts] is always the (possibly scroll-adjusted) containing block. `env(safe-area-inset-*)` is an unrelated CSS feature an author must apply by hand.

**Algorithm.** `CalculateOffset(node)` builds an `AnchorEvaluatorImpl` and iterates candidates. Per candidate: (i) `ActivateBaseStyleForTryAttempt()` installs the un-animated style; (ii) `TryCalculateOffset` computes the containing-block rect, contracts it by `position-area` offsets, resolves insets/margins/alignment, computes inline then block dimensions (block may require a real layout call); (iii) if fitting is requested, recompute an inset-modified containing block "for position fallback" and test the margin box against it on both axes — overflow rejects, and either way the scroll delta interval is recorded. Ordered mode stops at the first acceptance; scored mode collects all and stable-sorts. The winner is then recomputed once with the animated style.

**Where it lives.** `core/layout/out_of_flow_layout_part.cc` (the loop); `core/css/try_tactic_transform.h` (the flip algebra); `core/css/try_value_flips.cc` (property and value rewriting); `core/layout/anchor_evaluator_impl.cc` (`anchor()` and `position-area` to `LayoutUnit`s); `core/layout/absolute_utils.cc` (the box math); `core/html/resources/html.css:2256` (the UA stylesheet's own three-entry fallback list for `::picker(select)`).

**Degradation.** The _decision_ layer ports directly: `TryTacticTransform` is three bits with a swap-based `Transform()` and an `Inverse()`, which in D is a `ubyte`-backed value with pure functions over it — and it demonstrates that "preferred side plus alignment" is redundantly expressible as flips of one canonical placement. What does not port is expressing each candidate as a _style_ and re-running layout; on this reading, a cell toolkit computing candidate rects directly would be strictly cheaper and no less expressive. Integer cells cost nothing here: every value is already a `LayoutUnit` (1/64 px fixed point) and all the mirroring arithmetic is exact. No OS window is a non-issue, since the boundary is never a screen. The Android soft-keyboard inset has no representation in this code at all — which is an argument, though this page cannot settle it alone, for making a viewport inset an explicit _input_ rather than something a solver discovers.

### 3. Collision & geometry engine

Overflow detection is the two-signed-distances-per-axis test given under "How it works", and the free byproduct is the validity interval.

Clipping-ancestor discovery appears only for `position-visibility: anchors-visible`, and there it is delegated to an `IntersectionObserver` whose root is chosen by walking from the anchor's container up to (but excluding) the anchored element's container and taking the last one that clips ([`core/layout/anchor_position_visibility_observer.cc:38`][apvo-root]). If the two share a container the anchor is declared always visible and no observer is created at all.

Transforms, zoom and DPR are handled by keeping a `TransformState` per anchor reference and taking the enclosing rect of the mapped quad; if the anchor has a compositor transform animation running, a flag propagates up so the container knows its anchor geometry is unstable.

Scroll tracking is the interesting part, because it does **not** relayout on scroll. `AnchorPositionScrollData` snapshots the chain of scroll-adjustment containers (scroll containers, sticky boxes, and other anchor-positioned boxes) between the anchor and the anchored element's container, records their compositor element ids, and hands the accumulated offset to the paint-property tree as a `kAnchorPositionScrollTranslation` node ([`core/layout/anchor_position_scroll_data.cc:207`][apsd-translation]) — after which the compositor moves the popup.

[Shift][concepts] in the Floating UI sense exists only as CSS safe alignment: `ComputeInsets` clamps free space to zero and biases toward the safe edge when `justify-self: safe …` ([`core/layout/absolute_utils.cc:326`][au-insets], the bias at `:367`), and separately performs default-alignment-overflow shifting back into the union of the inset-modified containing block and the original containing block. There is no continuous shift toward the boundary of the kind a middleware pipeline provides.

**Algorithm.** Per frame, in a post-layout snapshot: recompute the accumulated scroll/sticky/chained offset; if the anchor element changed, or the set of adjustment container ids changed, or `range.Contains(old_total) != range.Contains(new_total)` for any recorded range, force a relayout; else if only the offset changed, classify as `kOffsetOnly` and update paint properties only ([`core/layout/anchor_position_scroll_data.cc:302`][apsd-valid]).

**Where it lives.** `core/layout/out_of_flow_layout_part.cc:66` (detection plus interval); `core/layout/anchor_position_scroll_data.cc` (per-frame snapshot, compositor ids, invalidation classification); `core/layout/anchor_position_visibility_observer.cc` (clipping-ancestor discovery); `core/layout/absolute_utils.cc:326` (the clamp). The compositor side consumes the translation node in `core/paint` and `cc`, neither of which was read.

**Degradation.** The detection algorithm is four subtractions and two sign tests, which is exactly what a cell toolkit wants, and the free scroll-range byproduct generalises to "the interval of anchor movement over which this placement stays valid" — a cheap way to avoid re-solving placement every frame. What does not generalise is everything downstream of the compositor: with one surface and immediate-mode repaint there is no "move the popup without relayout" tier, so an in-canvas overlay simply recomputes its rect each frame, which is arithmetic rather than layout. Clipping-ancestor discovery via `IntersectionObserver` has no analogue either; a display-list toolkit already knows its clip stack, so the boundary is a parameter rather than a search. Sub-cell precision: `EnclosingRect` of a mapped quad is precisely the round-outward step a cell grid needs.

### 4. Arrow / caret geometry

**Not applicable — and the absence is the finding.** There is no arrow primitive anywhere in the popover or anchor-positioning implementation. The UA stylesheet gives `[popover]` a plain `border: solid` and padding ([`core/html/resources/html.css:1921`][css-popover]) and nothing else.

This follows from the split: an arrow is content, and content is the author's business. The closest thing the engine supplies is that a pseudo-element of the popup automatically gets the popup as its implicit anchor ([`core/dom/element.cc:13874`][el-implicitanchor] returns the originating element for those pseudo ids), so an author _can_ build an arrow as an absolutely positioned `::before` anchored to the trigger by name. The engine supplies anchor plumbing and no arrow semantics.

What is missing as a consequence is worth listing, because each item is a real requirement that the platform pushes entirely onto CSS: the engine never feeds an arrow size back into the main-axis offset, never constrains the arrow against the popup's corner radius, never hides the arrow when the popup slides past the anchor, and never derives a [transform origin][concepts] from the arrow.

**Algorithm.** None.

**Where it lives.** Nowhere. The only relevant mechanism is `Element::ImplicitAnchorElement`'s pseudo-element cases; `OffsetInfo` — the placement result struct — has no arrow field.

**Degradation.** On a cell grid an arrow is one character painted into the border run of the popup at a clamped column or row, so its main-axis cost is a constant known before layout and the two-pass measurement a px-based toolkit needs disappears. The structural point Blink demonstrates is upstream of that: because CSS never returned a resolved side, the platform had to add a whole container-query type to recover it after the fact (dimension 14), and even that exposes the _fallback identity_ rather than the side. A toolkit that owns both halves can emit side and arrow position as part of the placement result from the start. Whether a cell-granularity arrow that cannot be centred should be suppressed or clamped is not answerable from Blink, which has neither; see [`./comparison.md`][comparison].

### 5. Trigger semantics

Two disjoint trigger systems, sharing no code.

**(A) Activation.** `popovertarget` / `popovertargetaction` on form controls, and `commandfor` / `command` on buttons and menu items. Both funnel into `HTMLElement::HandleCommandInternal` via DOM activation — that is, a synthesised click — so keyboard Enter/Space, programmatic `.click()`, and assistive-technology activation all work identically. `popovertargetaction` is normalised into a command event type (`toggle`/`show`/`hide`) precisely so that `popovertargetaction=showModal` is impossible ([`core/html/forms/html_form_control_element.cc:406`][hfce-target]).

Hover as a _popover_ trigger was removed. `PopoverData` still declares `hover_show_tasks_` and `hover_hide_task_` ([`core/dom/popover_data.h:123-125`][pd-dead]) and nothing in the renderer reads them; hover-triggered overlays moved to `interestfor` plus the CSS `interest-delay` properties. The abandoned first design is still visible in the data model.

**(B) Interest.** The `interestfor` attribute is the tooltip/hovercard trigger. Legal invokers are restricted by a virtual hook — `IsValidInterestInvoker` is overridden only by `HTMLButtonElement` (must be enabled, [`core/html/html_button_element.cc:209`][btn-invoker]), `HTMLAnchorElementBase` (must have `href`, [`core/html/html_anchor_element.cc:456`][a-invoker]) and `HTMLMenuItemElement` (must be enabled). A plain `<div interestfor>` is inert. Sources are hover, de-hover, focusin and focusout — all four in one enum — plus long press on a button, which bypasses delays entirely and enters a _distinct_ state (`kExplicitInterest`, not `kFullInterest`). Focus events from touch are filtered out by testing `sourceCapabilities()->firesTouchEvents()`.

The races are handled structurally rather than with locks:

- Hover changes are propagated up the flat-tree ancestor chain explicitly, because focus — unlike hover — does not notify ancestors ([`core/dom/element.cc:12979`][el-hoverfocus]).
- An invoker gaining interest on a target that already has a _different_ invoker either cancels the old invoker's pending lost-task (when the states are compatible) or forces the old invoker through `InterestLost` first and re-validates the whole precondition afterwards ([`core/dom/element.cc:1935`][el-gained]).
- Every step re-runs the guard, because the dispatched `interest` / `loseinterest` events are author-visible and can mutate the DOM.
- A one-shot suppression flag is set when a popover closes and returns focus to its own interest invoker, so the restored focus does not immediately re-trigger it ([`core/html/html_element.cc:2676`][he-restoreguard]).

**Algorithm.** `ShouldContinueWithInterest(invoker, target, newState)` ([`core/dom/element.cc:1919`][el-guard]) rejects if the target is null, if `invoker->InterestForElement() != target`, or if the transition is to no-interest and the target's source invoker is not this invoker. `InterestGained` then: runs the guard; asks the safe-triangle filter whether to defer; resolves an existing invoker as above; dispatches a cancelable `interest` event; on success sets the target's back-pointer and transitions state. Every transition flips the `:interest-source` / `:interest-target` pseudo-classes.

**Where it lives.** `core/html/html_element.cc` (activation and `InvokePopover`); `core/html/forms/html_form_control_element.cc:406` (attribute to command mapping); [`core/dom/element.cc:1919`][el-guard], [`:2012`][el-lost], `:12979` and `:12990` (the interest machine and its hover/focus fan-out).

**Degradation.** The interest state machine is the transferable part, and it is small: an invoker holds `{state, activeTarget, gainedTask, lostTask, suppressNextFocus}`, a target holds `{invoker}`, and the document holds a set of elements with interest — four fields and one set, all value-semantics friendly. With **no hover** only the long-press branch survives, and Blink already models exactly that case as a distinct state with no delay. With **no key release** nothing breaks, because no trigger here depends on key-up: activation is DOM activation and interest is hover/focus/long-press. With **no script** the activation half degrades to `<details>` and the interest half to `:hover`, which is precisely the static tier. The explicit ancestor fan-out for focus is worth noting as a bug class rather than a feature: a toolkit that routes focus without notifying ancestors inherits the same problem.

### 6. Timing

Delays are CSS properties, not constants: `interest-delay-start` / `interest-delay-end` (shorthand `interest-delay`), computed per element, with UA defaults of 0.5 s and 0.25 s ([`core/dom/element.h:293`][el-delays]). `normal` means "use the default"; a **non-finite** value means _never schedule_, checked with `std::isfinite` before posting the task ([`core/dom/element.cc:12828`][el-isfinite-show] for show, [`:12861`][el-isfinite-hide] for hide). One float thus encodes `{default, N seconds, never}` with no extra tag.

There is no [warm-up][concepts] and no [cool-down][concepts]: no "instant subsequent tooltip", no shared timing provider, no singleton arbiter, no maximum display duration, no toolbar-neighbour traversal. What replaces them:

- The show delay is cancelled on de-hover or blur, and the hide delay on re-entry — and the cancellation is applied not just to the element but to **all upstream interest invokers**, computed recursively through both the invoker chain and the parent chain ([`core/dom/element.cc:12956`][el-allsources], consumed at `:13008`). Moving the pointer into the tooltip's content therefore keeps the whole chain alive.
- Hand-off between two invokers of the same target skips the hide delay when the states are compatible — the "skip-delay" behaviour arrived at structurally rather than as a timer policy.
- Long press has no delay, on the stated reasoning that the press itself was the delay.

Tasks are posted on `TaskType::kMiscPlatformAPI` with a `TODO` admitting that is the wrong queue. Separately, the popover's own `toggle` event is coalesced: a pending toggle task is cancelled and re-posted while preserving the **original** old-state, so a show/hide/show burst fires exactly one event with the correct starting state ([`core/html/html_element.cc:2152`][he-toggle]).

**Algorithm.** States are `{NoInterest, PendingGain, FullInterest, ExplicitInterest, PendingLoss}`. Hover or focus on the invoker or any ancestor: cancel a pending loss on self and on every upstream invoker; if the state is `NoInterest` and not suppressed, post a gain task with the start delay. De-hover or blur: cancel a pending gain; if the state is `FullInterest` post a lost task with the end delay, and post one on every upstream invoker too. Long press goes straight to `ExplicitInterest`. A non-finite delay means the corresponding edge is simply never scheduled — a permanent hold, or a never-show.

**Where it lives.** `core/dom/element.h:293` (the two default constants); `core/dom/element.cc:12814` / `:12849` / `:12990` (scheduling); `core/css/resolver/style_builder_converter.cc` (`ConvertInterestDelayValue`); `core/html/html_element.cc:2152` (toggle coalescing).

**Degradation.** Blink posts real delayed tasks, which makes timing the one dimension a recording canvas cannot assert without making time an explicit input. On this reading a backend-neutral primitive should take `now` as a parameter and expose the pending deadline as observable state, so a headless target can step time. The non-finite-means-never encoding survives translation unchanged and is worth stealing. With **no timers at all** (the static tier) the dimension disappears — and the browser's own fallback there is instructive: the delay moves into the animation system as `transition-delay` on a `:hover` rule, which is the only timer a script-free document has.

### 7. Interactive hover

Blink ships a real [safe polygon][concepts] — `MenuSafeTriangle`, whose files carry a 2026 copyright — and its class comment states outright that "the details of this behavior are implementation-defined". The two constants are the whole tuning surface:

> ```cpp
> // Amount to inflate each corner of the safe triangle (by pushing it away
> // from the triangle's center), in pixels.
> constexpr float kTrianglePadding = 10.f;
>
> // How long we allow the mouse pointer to move in the safe triangle without
> // crossing into the submenu.
> constexpr base::TimeDelta kSafeTriangleDuration = base::Milliseconds(1000);
> ```
>
> — [`core/html/menu_safe_triangle.cc:26-32`][mst-consts]

It is created only for a `menuitem` inside a `menulist` (not a menu bar) when a submenu opens **and** the last known mouse position is inside one of the menu item's absolute quads ([`core/html/menu_safe_triangle.cc:44`][mst-create]). Using the _last known_ position rather than the triggering event's coordinates is deliberate, so the triangle also works when the user mixes keyboard and mouse; the comment additionally admits that threading the event coordinates through would have required changing "a rather large number of functions".

Geometry: find the submenu edge nearest the cursor using true point-to-segment distance, with an explicit branch for "the nearest point is a corner" (both projections share a sign) and an acknowledged `TODO` that corner tie-breaking is wrong; build a degenerate quad from `(cursor, cursor, edge.p1, edge.p2)`; inflate all four corners 10 px away from the quad's centroid. There is no trajectory or velocity heuristic and no pointer-bridge element.

The behaviour while alive is the transferable idea: it **buffers** rather than blocks. `ShouldDeferInterestGained` / `ShouldDeferInterestLost` push the suppressed call into an ordered list ([`core/html/menu_safe_triangle.cc:289`][mst-defer]), and a gain and a loss for the same invoker annihilate each other instead of both being stored. It ends on the 1000 ms one-shot timer, or when `Recheck()` finds the cursor outside both the triangle and the submenu quad ([`core/html/menu_safe_triangle.cc:169`][mst-recheck]), or when a deeper menu list opens (only the innermost submenu may own one), or when the cursor reaches the submenu — in which case the deferred queue is replayed, **losses first, then gains** ([`core/html/menu_safe_triangle.cc:261`][mst-finish]).

The class carries three `TODO`s conceding known gaps: the triangle is cached at creation, so an animating submenu breaks it; the timer should probably be a pair (a long one plus a short one reset on movement); and the timer should stop once the submenu is reached.

**Algorithm.** The containment test is `QuadF::Contains(point)` — four cross products — evaluated once per `Recheck`, i.e. per mouse move: O(1) per event, zero allocation. The deferral buffer is a short vector of `{invoker, target, state}` with annihilation on insert, bounded by the number of sibling menu items.

**Where it lives.** `core/html/menu_safe_triangle.{h,cc}`, owned by `Document` (one at a time, `CHECK`-enforced to be set and cleared in strict alternation). It intercepts at `core/dom/element.cc:1935` and `:2012` — that is, it is a **filter in front of** the interest state machine, not part of it.

**Degradation.** Everything here needs hover, so on a touch-only target it vanishes; note that it is inert on touch as a _side effect_ of requiring a known mouse position, not because of an explicit touch gate. On a cell grid it survives intact and gets cheaper: the submenu's near edge is always axis-aligned, so the nearest-edge search collapses to "the vertical edge on the side the submenu opened toward", the containment test to two integer comparisons after one division, and the 10 px inflation to exactly one cell of padding. The buffering design is the insight to carry over, and it is stronger than suppression — suppressing hover events during the diagonal loses the final state, whereas buffering with gain/loss annihilation replays the net effect if the user gives up. The hard 1 s expiry matters more without an OS [grab][concepts]: a cursor that leaves the surface may never report leaving, so a hard expiry is the only safe termination.

### 8. Dismissal

Dismissal is a matrix of (mode × popover type), and the modes are genuinely different code paths rather than options on one.

**Escape and Android back.** A `CloseWatcher` is created at show time. Its stack groups watchers by user activation: one Escape closes the whole topmost _group_, and a group is only allowed to be new if a user interaction was spent on it, with the budget incrementing at most once per interaction and not bankable ([`core/html/closewatcher/close_watcher.cc:118`][cw-budget]). The stated invariant is that the number of back presses needed to escape a page is at most the number of user interactions plus two. The same mechanism serves the Android back button through a mojo close listener, so Escape and back are literally one code path ([`:158`][cw-escape] for the key handler, [`:165`][cw-signal] for the signal).

**Light dismiss.** `pointerdown` records `FindTopmostRelatedPopover(target)`; `pointerup` recomputes it and dismisses only if the two match:

> ```cpp
>     // Hide everything up to the clicked element. We do this on pointerup,
>     // rather than pointerdown or click, primarily for accessibility concerns.
>     // ... To properly handle the use case where a user starts
>     // a pointer-drag on a popover, and finishes off the popover (to highlight
>     // text), the ancestral popover is stored in pointerdown and compared
>     // here.
> ```
>
> — [`core/html/html_element.cc:3103-3113`][he-lightdismiss]

"Related" means the nearest flat-tree ancestor that is either an open popover _or an invoker for_ an open popover, choosing whichever is higher on the stack ([`core/html/html_element.cc:3006`][he-topmostrelated]) — so clicking a trigger inside a popover does not dismiss that popover's own parent. A flag-gated variant runs the identical down-target/up-target comparison on the `click` event's targets instead ([`core/html/html_element.cc:3122-3133`][he-lightdismiss-click]).

**Hint versus auto.** `HidePopoversForLightDismiss` is strictly more aggressive than `HideAllPopoversUntil`: clicking anything that is not a hint closes the entire hint stack first ([`core/html/html_element.cc:3038`][he-hidelight]).

**A child opening.** Showing a popover closes everything above its topmost ancestor, where ancestry is the union of three relations (DOM containment, invoker containment, and formerly the anchor attribute) resolved into a tree by requiring the parent to be strictly lower in the stack ([`core/html/html_element.cc:2889`][he-ancestor]). That rule is how a possibly cyclic anchor graph is made acyclic: if two popovers reference each other, the only valid relationship is that the first to open is the parent.

**Removal from the DOM** is a distinct mode: it hides with no events, no transition wait and no focus restoration, suppressing three of the state machine's outputs at once:

> ```cpp
>     // If a popover is removed from the document, make sure it gets
>     // removed from the popover element stack and the top layer.
>     if (was_in_document) {
>       // We can't run focus event handlers while removing elements.
>       HidePopoverInternal(
>           /*invoker=*/nullptr, HidePopoverFocusBehavior::kNone,
>           HidePopoverTransitionBehavior::kNoEventsNoWaiting,
> ```
>
> — [`core/html/html_element.cc:3869-3877`][he-removedfrom]

**Interest lost** closes the target popover unless explicitly told not to (used when the popover is already closing, to break the recursion).

What is **not** a dismissal trigger for popovers: scroll, window deactivation, anchor hidden, anchor removed, resize, navigation. `position-visibility: no-overflow | anchors-visible` makes the popup _invisible_ rather than closing it ([`core/layout/out_of_flow_layout_part.cc:438`][oofl-posvis]) — visibility and existence are deliberately separated.

**Algorithm.** Light dismiss: on down, `t0 = topmostRelated(hitNode)`; on up, `t1 = topmostRelated(hitNode)`; dismiss only if `t0 == t1`. `topmostRelated(n)` is the maximum by stack position of the nearest open popover ancestor and the nearest popover targeted by an invoker ancestor, where hint-stack positions are offset by `autoStack.size() + 1` so the two vectors compare in one total order ([`core/html/html_element.cc:3015`][he-stackpos]). Cascading close pops the hint stack then the auto stack from the top, **re-validating after every call**, because `beforetoggle` handlers can mutate the stacks; a nesting counter and a "popover showing" flag on `Document` reject re-entrant shows with an exception.

**Where it lives.** `core/html/closewatcher/close_watcher.cc` (Escape, back, grouping); `core/html/html_element.cc:3006`, `:3038`, [`:2245`][he-hideuntil] (`HideAllPopoversUntil`), `:2889`, `:3083`, `:3122`, `:3868`. The pointer-event call sites live in `core/input`, which was not read; that they run before dispatch is inferred from `CHECK`s in the callees (`!event.HasEventPath()`, phase `kNone`).

**Degradation.** With **no pointer grab** the down/up pairing is exactly the right primitive: it needs only two hit tests against the last painted frame and never needs to observe the pointer leaving the surface. With **no key release** nothing is lost, because Escape is handled on key-down (the handler tests the key code on a `KeyboardEvent`, with no release involved). Android back being the same signal as Escape validates unifying both behind one close-request channel. The group/activation-budget machinery is an anti-abuse feature specific to a hostile-content platform and appears to have no place in a toolkit. The "popup becomes invisible rather than closing when its anchor scrolls away" choice looks worth copying for a different reason: on a recording canvas, "open but not painted" is assertable, whereas "closed by scroll" loses the information.

### 9. Focus

The four surface kinds are kept genuinely distinct, and the distinctions are enforced in different places.

**Tooltip** (an `interestfor` target): no focus involvement at all. Showing interest never moves focus; the only focus interaction is the one-shot suppression flag that stops a focus restoration from re-triggering the invoker.

**Popover:** `SetPopoverFocusOnShow` updates style and layout for the element (necessary because focusability requires layout), then focuses the element itself if it is autofocusable, or its autofocus delegate — and **otherwise leaves focus where it is** ([`core/html/html_element.cc:2704`][he-focusonshow], with the source comment citing the Open UI explainer). Popovers are therefore opt-in-focus. There is no [focus scope][concepts] trap and no containment: a non-modal popover makes nothing inert.

Restoration is conditional on three things simultaneously: the "should restore" flag is only set for `auto` and `hint` popovers, and only when nothing was already showing ([`core/html/html_element.cc:2081`][he-shouldrestore]); and at hide time the restore only happens if the popover still contains the document's adjusted focused element ([`core/html/html_element.cc:2676-2677`][he-restoreguard]). The restore uses `preventScroll: true`.

**Modal dialog** is the only surface that blocks anything, and it does so by making everything else inert — `InertSubtreesChanged` dirties the document element's style and rebuilds the entire accessibility tree, the comment conceding that "the most foolproof way is to clear the entire tree and rebuild it" ([`core/html/html_dialog_element.cc:113`][dlg-inert], the rebuild at [`:136`][dlg-a11y]).

Pointer- versus keyboard-opened is not distinguished for focus. It _is_ distinguished for interest, where focus events whose source capabilities fire touch events are ignored.

**Algorithm.** Show: record the currently focused element; compute `shouldRestore = (type is auto|hint) && !TopmostPopoverOrHint()`; add to the top layer; set visible; run `SetPopoverFocusOnShow()`, which focuses only an autofocus delegate; if `shouldRestore` and still open, store the previously focused element. Hide: if a stored element exists, the behaviour asks for restoration, and the popover still contains the active element — then, if the stored element is this popover's own interest invoker, set its suppression flag; and focus it with scrolling prevented.

**Where it lives.** `core/html/html_element.cc:2704`, `:2081`, `:2676`; `core/html/html_dialog_element.cc:113`. Sequential focus navigation across the top layer lives in `core/page/focus_controller.cc`, which was not read — so this page cannot state how Tab traverses an open popover.

**Degradation.** "Do not steal focus unless asked" is the correct default and costs nothing on any target. The restoration guard — restore only if focus is still inside the closing surface — is the transferable subtlety: it makes nested and overlapping closes idempotent without a focus stack. The one-shot "suppress the next focus-triggered interest" flag fixes a real loop (close tooltip → restore focus to trigger → trigger regains interest → tooltip reopens) that any toolkit combining focus-triggered tooltips with focus restoration will hit. With **no key release** nothing changes, since focus here is driven by focusin/focusout and never by key-up. Inert-based [modality][concepts] needs only a "the rest of the hit list is disabled" bit, which a flat derived hit list supports by marking everything painted before the modal as non-hittable — much cheaper than Blink's whole-accessibility-tree rebuild, which it needs because its inertness is a style-computed property.

### 10. Layering & portals

The [top layer][concepts] is a single ordered `HeapVector<Member<Element>>` on `Document`. Painting order is list order. There is no z-index bookkeeping, no per-overlay stacking-context registry, and no native child window. `AddToTopLayer` appends; the only insert-before case is a `::backdrop`, which must sit immediately before its owner, `CHECK`-enforced with a comment noting that changing the invariant would require revisiting container queries for top-layer elements ([`core/dom/document.cc:8613`][doc-addtop]).

The instructive part is **removal**, which is deferred and driven by style. `ScheduleForTopLayerRemoval` pushes `{element, reason}` onto a pending list and schedules a layout-tree update ([`core/dom/document.cc:8660`][doc-schedule]); `RemoveFinishedTopLayerElements` — called from `PostStyleUpdateScope::Apply`, i.e. after every style recalc ([`core/css/post_style_update_scope.cc:55`][psus]) — removes only those pending elements whose computed `overlay` is `none` ([`core/dom/document.cc:8683`][doc-removefinished]).

`overlay` is a discretely-animatable UA-controlled property:

```css
/* core/html/resources/html.css:1986-1988 */
dialog:modal,
[popover]:popover-open {
  overlay: auto !important;
}
```

so an author transitioning `overlay` keeps the element in the top layer for the duration of its exit animation, and it leaves the layer exactly when the animation ends. Re-showing while a removal is pending removes immediately first, so the element re-appends at the end.

Two consequences are visible in the source. First, Blink forces the _computed value_ of `overlay` to `none` for elements not actually in the top layer, so scripts cannot observe the internal flag through `getComputedStyle` ([`core/css/properties/longhands/longhands_custom.cc:12284`][overlay-computed]). Second, internal-only pseudo-classes (`:-internal-popover-in-top-layer`, `:-internal-dialog-in-top-layer`) exist because the public ones stop matching the moment hiding is _requested_ while the `::backdrop` must persist — the UA stylesheet says so verbatim ([`core/html/resources/html.css:1959-1964`][css-backdrop-comment]). Separately, `moveBefore()`'s state-preserving atomic move is checked in three places so reparenting does not tear down top-layer, popover or interest state.

**Algorithm.** Removal: schedule `{element, reason}`; on every style recalc, for each pending element read the computed `overlay`; if the style is gone or `overlay == none`, remove immediately — which also removes its `::backdrop` and, for popovers, nulls the implicit anchor. Ordering: strictly append, with backdrop-immediately-before-owner as the only structural rule.

**Where it lives.** `core/dom/document.cc:8613`, `:8660`, `:8683`, `:8707`; `core/css/post_style_update_scope.cc:55`; `core/html/resources/html.css:1986`; `core/css/properties/longhands/longhands_custom.cc:12284`. The timing is pinned by a C++ unit test, `PopoverTopLayerRemovalTiming` ([`core/html/html_element_test.cc:261`][he-test]).

> [!NOTE]
> The claim that the top layer is a paint-order list rather than a compositor surface rests on the `Document`-side data structure and the UA stylesheet. `core/paint` was not materialised in this checkout, so the actual painting of `top_layer_elements_` was not read.

**Degradation.** An in-canvas toolkit with no top layer loses less than it looks. It does not lose ordering: "top layer" here _is_ "later in the list", which is what a display list already provides. It does not lose clipping escape either, provided overlays are appended at the root of the display list rather than nested. What it does lose is the deferred-removal trick — though the structure suggests that trick exists because Blink's removal is gated on a CSS property whose animation it observes only through style recalc; a toolkit that owns its own animation clock can keep an overlay in the list until its exit animation reports done, which is the same mechanism with none of the plumbing. The rule worth stealing is the one that forced the internal pseudo-classes into existence: **the visual state and the lifetime state are two separate bits, because they end at different times.**

### 11. Modality

Popovers are strictly non-modal, and it is enforced at the styling level:

```css
/* core/html/resources/html.css:1965-1973 */
dialog:-internal-dialog-in-top-layer::backdrop {
  background-color: rgba(0, 0, 0, 0.1);
}

[popover]:-internal-popover-in-top-layer::backdrop {
  pointer-events: none !important;
  background-color: transparent;
}
```

Both surfaces get a full-viewport backdrop pseudo-element; only the dialog's is hit-testable and tinted. That is a clean separation of "a scrim exists" from "the scrim blocks".

Keyboard blocking for modal dialogs is inert-based rather than focus-trap-based (dimension 9). `closedby` gives dialogs a three-state light-dismiss policy whose _default depends on modality_ — a modal dialog defaults to close-request-only, a non-modal one to none ([`core/html/html_dialog_element.cc:240`][dlg-closedby]). Popovers have no equivalent attribute: `auto` is always light-dismissible, `manual` never is, and `hint` is light-dismissible under the aggressive hint-stack rule.

The passthrough case produces a structural lesson. Because a popover's backdrop is `pointer-events: none`, clicks reach the page beneath — which is exactly why light dismiss has to be implemented as an observer in the pointer-event manager rather than as a hit on a scrim. A modal dialog needs the opposite, and its light dismiss consequently uses **geometry**: `FindNearestDialog` notices that a click on the backdrop hit-tests as a click on the dialog element itself, and disambiguates with a point-in-bounding-rect test ([`core/html/html_dialog_element.cc:274`][dlg-nearest], the test at `:289`).

**Algorithm.** Dialog light dismiss: `nearest(node, x, y)` returns null (a backdrop click) if the node — or its `::backdrop` parent — is an open modal dialog and the point is outside its bounding rect; otherwise it walks flat-tree ancestors for the first open dialog. Then the same down/up pairing as for popovers, and if the paired result is not the topmost open dialog and that dialog's `closedby` is `any`, request a close.

**Where it lives.** `core/html/resources/html.css:1965-1973` (the two backdrop rules); `core/html/html_dialog_element.cc:113`, `:240`, `:274`, and the two light-dismiss entry points.

**Degradation.** Everything here maps onto a flat hit list with no OS involvement: "scrim exists but does not block" is a painted rect that is not in the hit list; "scrim blocks" adds it. The accessibility modal bit has no cheap analogue on a cell grid (dimension 13). The geometric backdrop disambiguation is a warning worth carrying: if the overlay and its scrim are the same painted object, an inside click cannot be told from an outside one by identity, and you are forced back to comparing against the content rect. That suggests emitting the scrim and the surface as two distinct hit-list entries and never merging them.

### 12. Adaptive presentation

**Partial.** There is no popover-to-sheet transformation and no teaching-tip concept. The adaptation that does exist is touch-versus-mouse for the interest surface, and it is split across three layers — which is itself the finding.

1. **The element layer** decides that a long press on a button shows interest immediately with no delay, on the reasoning that the long press already contains the delay; and it simultaneously pre-arms the light-dismiss state by seeding the document's pointerdown target with the popover being opened, so the `pointerup` that ends the long press does not immediately dismiss what the long press just opened ([`core/dom/element.cc:2095-2123`][el-longpress]).
2. **The UA stylesheet layer** supplies the touch affordance as a pseudo-element with an explicitly WCAG-target-sized hit area, negative margins so it overlays rather than reflows, and `cursor: help`:

   ```css
   /* core/html/resources/html.css:1663-1675 */
   [interestfor]::interest-button {
     min-inline-size: 24px;
     min-block-size: max(24px, 1lh);
     margin-inline-start: 0.25em;
     margin-block: min(-24px, -1lh);
     cursor: help;
   }
   ```

3. **The pseudo-element layer** makes that button activatable by click, Enter or Space but explicitly **not focusable** ([`core/dom/interest_button_pseudo_element.cc:53`][ibpe-focus]), so it adds a pointer target without adding a tab stop.

A fourth rule exists solely to influence a decision the renderer cannot observe: `button[interestfor] { user-select: none }` ([`core/html/resources/html.css:1660`][css-userselect]) exists so the browser process suppresses the context menu on long press, and a source comment notes that this decision is made asynchronously browser-side, so Blink cannot check it and simply shows interest for all buttons.

Menus adapt too: a submenu activates on mouse **down**, so a press-drag-release gesture can pick an item in one stroke, guarded by a five-unit drag epsilon so a plain click that lands over a freshly rendered item does not select it ([`core/html/forms/html_option_element.h:179`][opt-epsilon], used at [`core/html/html_menu_item_element.cc:578`][menuitem-drag]).

**Algorithm.** Long press: on a long-press gesture over a button with `interestfor` and no current interest — if the target is a popover, set the document's pointerdown target to that popover so the terminating `pointerup`'s recomputed target matches and no dismissal fires; then show interest immediately, bypassing the start delay. Drag-pick: `mousedown` on the trigger records `{target, absoluteLocation}`; on `mouseup` over an item, pick it only if the pointer moved more than five layout units (and, for menu items, only if the up-item differs from the down-item).

**Where it lives.** `core/dom/element.cc:2095-2123`; `core/html/resources/html.css:1660-1682`; `core/dom/interest_button_pseudo_element.cc`; `core/html/forms/html_option_element.h:179`; `core/html/html_menu_item_element.cc:578`.

**Degradation.** For a target with no hover at all, this is the entire story: only the long-press path and the explicit affordance survive, and making the affordance a real hit target rather than an invisible gesture is the robust choice — a gesture nobody can see is a feature nobody finds. The structural observation is _which layer owns the decision_: in Blink it is smeared across three, and the cost is visible in the code as a UA stylesheet rule whose only purpose is to influence a browser-process context-menu decision the renderer cannot read back. This page's inference is that a single-surface toolkit should take pointer capability as an **input** to the view — as with the soft-keyboard inset — so that one view function emits a hover-triggered surface on a pointer target and a tap-target affordance on a touch target, decided in one place. See [`./sparkles-baseline.md`][baseline] for what the toolkit can express today.

### 13. Accessibility

**Partial by necessity.** Most of the accessibility mapping lives in `modules/accessibility`, which was not in the checkout. What is visible in `core` are the hooks it exports, and they are informative.

- **Expanded-state fan-out.** `MarkPopoverInvokersDirty` walks the tree scope's popover-invoker and command-invoker lists on every show and hide and dirties **every** element that targets this popover, "since they all should now have an updated expanded state" ([`core/html/html_element.cc:1573`][he-invokersdirty]). Expanded state is derived, not stored, and one popup updates N triggers.
- **Anchor as an accessibility relation.** `AnchorEvaluatorImpl` tracks the most recent anchor it resolved and deliberately returns null if more than one distinct anchor was involved — the header says this is "to avoid extra noise for assistive tech" ([`core/layout/anchor_evaluator_impl.cc:497`][ae-a11y], the getter at `:510`). That single element is threaded through the offset info into `LayoutBox::AccessibilityAnchor` ([`core/layout/layout_box.cc:4410`][lb-a11yanchor]), so the layout engine tells the accessibility tree "this floating box belongs to that element". No spec asks for this.
- **Pointer cancellation.** Light dismiss runs on `pointerup` with an explicit WCAG 2.1 citation in the comment ([`core/html/html_element.cc:3103`][he-lightdismiss]).
- **Target size.** The interest button's 24 px minimum cites the WCAG 2.2 target-size guideline, and the `<option>` rule cites it too.
- **Modality.** Opening a modal dialog forces a full accessibility-tree rebuild because inertness changes everywhere.

Nothing enforces "tooltip content must not be interactive": `interestfor` may target any popover, including one full of buttons — indeed the whole safe-triangle and interest-cancellation machinery exists precisely because the target _is_ expected to be enterable. WCAG 1.4.13's dismissible/hoverable/persistent trio is served structurally rather than declaratively: Escape closes via `CloseWatcher`, hover into the content cancels the lost-task for the whole invoker chain, and an infinite `interest-delay-end` makes the surface persistent. Compare [`./aria-apg.md`][apg] for the normative side.

**Algorithm.** `AccessibilityAnchor`: on each anchor resolution, if a recorded anchor exists and differs from the new one, set a "multiple" flag; the getter returns null when it is set. The field is cleared before each `@position-try` candidate is applied ([`core/layout/out_of_flow_layout_part.cc:316`][oofl-cleara11y]), so only the winning candidate's anchor is reported.

**Where it lives.** `core/html/html_element.cc:1573`; `core/layout/anchor_evaluator_impl.cc:497`; `core/layout/layout_box.cc:4410`; `core/html/html_dialog_element.cc:136`; `core/html/resources/html.css:1668`.

**Degradation.** On this evidence, three things belong to a _primitive_: the trigger↔surface relation as data, so expanded state can be derived for every trigger rather than stored on one; the anchor relation as data, with the "ambiguous means none" rule; and the dismissal timing rule (act on release, not press). Three belong only to a semantic component: role, label-versus-description, and whether the content may be interactive. What a terminal cell grid can honestly expose is none of the tree APIs — there is no assistive-technology channel from a cell grid — but it can expose reading order (by controlling display-list order), a text alternative inside the surface itself, and the _timing guarantees_, which are behavioural and fully assertable on a recording canvas. Claiming a tooltip role on a cell grid would be a lie; guaranteeing Escape-dismissibility would not.

### 14. Animation

**Partial**, and the shape of the gap is the finding. Blink emits **no placement-derived geometry metadata for styling**: no resolved-side attribute, no [transform origin][concepts] derived from the chosen side, no arrow-driven origin.

That gap was recognised and patched by a different mechanism entirely — `anchored(fallback: <try-fallback>)` container queries. The container-query evaluator stores the currently applied fallback as part of its container values; `AnchoredContainerChanged` compares the new fallback against the stored one ([`core/css/container_query_evaluator.cc:504`][cqe-anchored], the update at [`:720`][cqe-update]) and, on a difference, invalidates only those cached query results whose selector selects anchored containers. Authors therefore learn which fallback won by querying it — but what is exposed is the **fallback identity** (a rule name or a tactic), not a resolved side/alignment pair. You cannot ask "am I above or below"; only "which entry of my list am I on".

The engine goes to real trouble to keep animation _out_ of placement: candidates are evaluated on the base computed style and only the final geometry pass uses the animated style ([`core/layout/out_of_flow_layout_part.cc:2146`][oofl-basestyle]); and if an anchor has a compositor transform animation running, a flag is propagated up to the container builder. Exit animations are supported through the deferred top-layer removal plus the discrete `overlay` property (dimension 10). Reposition-during-animation is a known rough edge — the safe triangle caches the submenu quad at creation and has an explicit `TODO` that it should recompute per re-check "to account for menus that quickly animate into their final position" ([`core/html/menu_safe_triangle.cc:191`][mst-todo]). Reduced motion has no representation in this code at all.

**Algorithm.** On committing a chosen fallback index, the style engine compares it with the container evaluator's stored fallback; if different, it replaces the container values (which carry both the fallback and the absolute container's writing direction, needed to resolve logical try-tactics) and drops cached results for anchored-container selectors, forcing those rules to re-evaluate.

**Where it lives.** `core/css/container_query_evaluator.cc:504` and `:720`; `core/css/css_container_values.h`; `core/layout/out_of_flow_layout_part.cc:2146`; `core/layout/anchor_map.cc` (the running-transform flag); `core/html/resources/html.css:1986`.

**Degradation.** The lesson here is negative. Because the placement engine did not emit side and alignment metadata, the platform had to add a whole query type after the fact — and even that exposes the wrong abstraction. A placement solver that already knows the answer can return `{side, alignment, arrow cell, anchor rect, flipped}` as a value the view reads directly, at no extra cost. "Decide on the un-animated state, render with the animated one" generalises to any toolkit with animated sizes and is cheap: run the solver against the settled size. With no compositor and immediate-mode repaint, reposition-during-animation is not a hazard at all — it is just the next frame.

### 15. State architecture

Imperative controllers over garbage-collected side tables, with re-entrancy guarded by RAII scopes and re-validated preconditions rather than by a formal state machine.

Per-element state is lazily allocated rare-data: `PopoverData` (visibility, type, invoker, previously-focused element, pending toggle task, hiding flag, implicit anchor, close watcher), `InvokerData` (interest state, active target, two task handles, suppress-next-focus), `InterestInvokerTargetData` (one back-pointer), `OutOfFlowData` (last successful fallback, pending successful fallback, remembered scroll offsets), and `AnchorPositionScrollData`. `Document` holds the collections: two popover stacks, an all-open set, an elements-with-interest linked set, a pointerdown target, the top-layer vector, a pending-removal vector, and one safe triangle ([`core/dom/document.h:1725-1813`][doch-toplayer]).

Re-entrancy is the dominant concern, because every step can dispatch author-visible events. `ScopedPopoverShowing` and `ScopedPopoverHiding` set flags and a nesting counter on `Document` ([`core/html/html_element.cc:1398`][he-scopedshowing]); `IsPopoverReady` is re-called after every event dispatch with a message explaining which handler could have invalidated things ([`:1475`][he-ready]); a local lambda re-tests that the popover's type did not change mid-show ([`:1954`][he-validity]).

Two escape hatches leak into the model. DevTools can force a popover to stay open, and the close code has to re-push inspector-held popovers back onto the stack in reverse order to keep it consistent. And feature flags are threaded through the logic itself — the new hint behaviour appears in roughly twenty branches — so two different ancestor-resolution algorithms coexist inside one function.

**Algorithm.** The shape that survives translation is fourfold: (1) all mutable per-surface state is a small struct, allocated only when the element participates; (2) the document owns ordered collections, and "which surface is topmost" is a vector's back element; (3) every operation that can run user code re-checks its preconditions afterwards and bails; (4) a possibly cyclic ancestor graph is turned into a tree by a stack-position ordering rather than by cycle detection.

**Where it lives.** `core/dom/popover_data.h`, `core/dom/invoker_data.h`, `core/dom/interest_invoker_target_data.h`, `core/css/out_of_flow_data.h` (the side tables); `core/dom/document.h:1725-1813` (the collections); `core/html/html_element.cc:1398`, `:1475`, `:1954`.

**Degradation.** The **data** would survive a value-semantics, allocation-conscious toolkit essentially unchanged: `PopoverData` is eight fields, of which four are element references and two are cancellable task handles; `InvokerData` is five. Replace the weak references with ids and the task handles with deadlines, and each is a plain struct in an arena; two stacks plus "topmost is the back element" is already value semantics. What would not survive — and, on this reading, should not be copied — is the re-entrancy scaffolding, which exists only because author JavaScript runs inside the transition. A toolkit whose view function is pure and whose events are processed against the last painted frame has no such hazard, so the scoped flags, the nesting counter, the post-dispatch re-validation and the "showing a popover during another show throws" rule all appear to be platform tax rather than intrinsic complexity.

### 16. Shared infrastructure

Blink is unusually explicit about what it shares and what it deliberately keeps apart.

**Truly shared.** (1) The top layer and its deferred removal — dialog, popover, fullscreen and `::backdrop` all use the same `Document` vector and the same `overlay`-driven removal, with a reason tag purely for bookkeeping. (2) `CloseWatcher` — Escape, Android back, and dialog `closedby` all route through one grouped stack. (3) The popover mechanism itself is reused as the substrate for `<select>`'s picker, `<datalist>`, menu-list submenus and select's autofill preview: those classes override `HidePopoverInternal` ([`core/html/html_menu_list_element.cc:64`][menulist-hide], [`core/html/forms/html_data_list_element.cc:103`][datalist-hide], [`core/html/forms/select_type.cc:181`][selecttype-hide]) and inherit stack, light-dismiss and top-layer behaviour for free. (4) The whole anchor-positioning layer, which knows nothing about popovers.

**Reimplemented rather than shared.** The light-dismiss down/up pairing exists twice — once for popovers, once for dialogs — with the dialog version's comment pointing back at the popover version.

**Deliberately apart.** Dialogs and popovers keep separate stacks, separate light-dismiss entry points with different resolution rules (DOM ancestry for popover; ancestry plus geometry for dialog), separate focus policies, and separate default dismissal policies. Menus get their own alias over the auto stack with a `TODO` saying it may need to diverge ([`core/dom/document.h:1813`][doch-menustack]), plus a safe triangle no other surface uses. The tooltip path (`interestfor`) shares nothing with the popover trigger path except that its target happens to be a popover: separate attribute, separate state machine, separate delays, separate pseudo-classes.

The hint stack is the strongest structural signal in the subject. It exists solely to let a tooltip-ish surface coexist with an open menu without closing it, and it required a second stack, a "hint stack parent" pointer, and an asymmetric more-aggressive close rule.

**Algorithm.** Stack unification without merging: hint-stack positions are compared against auto-stack positions by offsetting them by `autoStack.size() + 1` ([`core/html/html_element.cc:3015`][he-stackpos]), so the two vectors behave as one total order for "which related popover is topmost" while remaining separate.

**Where it lives.** `core/dom/document.h:1725-1813`; `core/html/closewatcher/close_watcher.cc`; the three `HidePopoverInternal` overrides listed above; `core/html/html_element.cc:3015`.

**Degradation.** For a single anchored-overlay primitive, this subject's factoring argues for including: the overlay list with ordered lifetime and deferred removal; the anchor and placement solver; the down/up-paired outside dismiss; one close-request channel (Escape unified with back); and the trigger↔surface relation table. And for keeping apart: focus policy (tooltip takes none, menu takes it, dialog traps it), dismissal defaults (three popover types plus a fourth for dialogs), and the interactive-hover layer (only menus need a safe polygon; a tooltip needs only the invoker-chain cancel). The hint stack suggests a further inference: once a hover surface and a click surface can be open simultaneously, one ordered list is not enough — the choices visible here are two ordered lists with a cross-order comparison (Blink's) or an explicit precedence field per surface in one list.

---

## Strengths

- **Placement is decided on stability, not merely fit.** A sticky last-successful choice, remembered per-anchor scroll offsets, and a validity interval computed as a free byproduct of the overflow test together form a complete anti-flicker design.
- **The try-tactic algebra is exemplary**: eight arrangements in three bits, a documented normalisation table, a closed-form inverse, and the bit pattern doubling as a memo index — a plain comparable value with pure functions over it.
- **Light dismiss is a pointerdown/pointerup pair**, with a "nearest related popover" resolution that spans both DOM ancestry and invoker relationships, so clicking a trigger inside a popover does not dismiss its own parent.
- **Ancestor resolution turns a possibly cyclic graph into a tree by a single documented rule** — the parent must be strictly lower on the stack.
- **The popover mechanism is genuinely reusable**: `<select>`'s picker, `<datalist>`, menu-list submenus and autofill previews all inherit stack, light-dismiss and top-layer behaviour by subclassing, which is evidence the primitive was factored at the right level.
- **One close-request channel** unifies Escape, the Android back button and dialog `closedby`, with group semantics so one press closes a coherent set.
- **The layout engine volunteers an accessibility relation** no spec asks for, and correctly reports "none" when the relation is ambiguous.
- **The UA stylesheet is a first-class consumer** of anchor positioning, so the declarative path is exercised on every `<select>` popup.
- **The safe triangle buffers with annihilation rather than suppressing**, and its comments honestly document what it does not handle.

## Weaknesses

- **The cost model is heavy and invisible to authors.** A scored `position-try-order` — which the UA's own picker uses — forfeits early exit and always evaluates every candidate, each costing a subtree style recalc plus a layout. Reading the loop structure, one anchored element in one frame can reach roughly thirteen such passes in the worst case (six, a forced re-search of six, and one final pass); this was derived, not measured.
- **No placement metadata is emitted.** No side, no alignment, no transform origin, no arrow support of any kind; authors recover "which fallback won" only through a bolted-on container query that exposes the list entry rather than the resolved geometry.
- **No continuous shift.** Placement jumps between authored discrete options; the only continuous correction is CSS safe alignment, a separate feature with separate opt-in syntax.
- **Two generations of behaviour coexist behind runtime flags**, so the ancestor-resolution and cascade-close functions contain two interleaved algorithms and many flag branches.
- **Dead state ships in the data model**: `PopoverData` still carries the hover-show map and hide task, read by nothing in the renderer.
- **Re-entrancy from author events forces defensive re-validation after every step**, plus RAII scopes, a nesting counter, and a thrown exception for nested shows.
- **The DevTools force-open path leaks into the core algorithm**, which must re-push inspector-held popovers back onto the stack in reverse order.
- **Safe-triangle geometry is cached at creation**, so an animating submenu invalidates it (acknowledged), and corner tie-breaking in the nearest-edge search is admitted to be wrong.
- **No concept of viewport insets** — no safe area, no soft keyboard, no work area. The only boundary is the containing block.
- **The tooltip trigger set is closed**: interest invokers are restricted to buttons, links with `href`, and enabled menu items by a virtual hook, so authors cannot extend it.

> [!WARNING]
> Runtime feature-flag defaults could not be determined: `runtime_enabled_features.json5` is outside the checkout. Where two algorithms coexist, both are described above and the flag that selects them is named — but which is live in a shipping build is not established here.

---

## Key design decisions and trade-offs

| Decision                                                                                                                                                             | Rationale                                                                                                                                                                                                                                                                          | Trade-off                                                                                                                                                                                                                                                                                                                |
| -------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Put lifecycle in the element (`popover`) and geometry in the style/layout engine, coupled only by one element pointer read by `position-anchor: auto`.               | Lets the positioning system serve non-popover content, and lets `popover` be reused as the substrate for `<select>` pickers, `<datalist>` and menu-list submenus without any of them inheriting a placement policy.                                                                | The halves cannot cooperate. The popover layer never learns which side it landed on (which is why `anchored(fallback:)` had to be added later), cannot feed an arrow size into the offset, and cannot dismiss itself when placement fails — the best it can do is make the layer invisible while the popover stays open. |
| Model constraint adjustment as an ordered list of whole alternative **styles**, retried by re-running style recalc plus layout, capped at six attempts.              | Every candidate is expressible in ordinary CSS, so authors get the whole language per fallback (different width, margins, alignment), and the engine needs no bespoke geometry solver.                                                                                             | A large constant factor, and the spec had to license the cap explicitly. Any scored order forfeits early exit. There is also no continuous shift — only discrete jumps between authored options, with safe-alignment clamping as the sole continuous adjustment.                                                         |
| Make placement decisions against the base (un-animated) computed style, then recompute the final geometry with the animated style.                                   | Prevents a running size or inset transition on the popup from changing which fallback fits, which would feed back into the transition and oscillate.                                                                                                                               | Two evaluations of the same geometry for the winner, and a latent inconsistency: the committed placement can be one the animated style does not actually fit.                                                                                                                                                            |
| Defer top-layer removal until a UA-controlled discrete CSS property (`overlay`) finishes animating, checked after every style recalc.                                | Gives authors exit animations on overlays with no imperative "closing" state, and keeps `::backdrop` alive for the duration.                                                                                                                                                       | Visual state and lifetime state desynchronise, forcing two internal pseudo-classes because the public ones stop matching too early, plus a special case in `AddToTopLayer` for close-then-show-modal in one task.                                                                                                        |
| Implement light dismiss as a **pair** test over pointerdown and pointerup targets rather than a single outside-click hit test.                                       | WCAG 2.1 pointer cancellation puts destructive actions on release; and a text-selection drag that starts inside a popover and ends outside must not close it.                                                                                                                      | Requires a document-scoped pointerdown target, and workarounds when a popover is opened _during_ pointerdown (long press, `<select>` mousedown) — those paths pre-seed the pointerdown target with the popover being opened.                                                                                             |
| Split hover surfaces off `popover` entirely into a second attribute (`interestfor`) with its own state machine, CSS-controlled delays, and a restricted invoker set. | The first design — hover as a `popovertargetaction` with delays stored in `PopoverData` — could not express hover/focus/long-press uniformly, could not be styled, and could not model invoker↔target hand-off. Delays as CSS properties also let a page tune them without script. | Two trigger systems sharing no code, a dead hover-task map still sitting in `PopoverData`, and a hard rule that a plain `<div>` can never be a tooltip trigger.                                                                                                                                                          |
| Keep a second popover stack (`hint`) with a parent pointer and an asymmetric, more aggressive light-dismiss rule.                                                    | A hover surface must be able to appear over an open menu without closing it, and must disappear as soon as anything that is not a hint is touched.                                                                                                                                 | Two vectors that must be compared as one total order via an offset, a parent pointer that must be nulled in several places, and a second code path in ancestor resolution gated on a runtime flag.                                                                                                                       |
| Ship the safe triangle as a **buffering filter in front of** the interest state machine rather than as event suppression, capped at 1000 ms.                         | Buffered gains and losses can be replayed exactly if the user abandons the diagonal, so the menu ends in the correct state either way; the timer bounds the case where the pointer stops or leaves.                                                                                | The class comment concedes the behaviour is implementation-defined and carries three `TODO`s. It is created only for a menu item inside a menu list — menu bars and every other surface get nothing.                                                                                                                     |

---

## Sources

Primary sources, all read at [`b0e30a99…`][repo-pin] in a sparse checkout of `third_party/blink/renderer/core`:

- **Lifecycle** — [`core/html/html_element.cc`][he-lightdismiss] (show/hide, stacks, ancestors, light dismiss, focus, toggle coalescing), [`core/dom/popover_data.h`][pd-anchor], [`core/html/closewatcher/close_watcher.cc`][cw-budget], [`core/html/html_dialog_element.cc`][dlg-inert], [`core/dom/document.cc`][doc-addtop] and [`core/dom/document.h`][doch-toplayer] (top layer and collections).
- **Triggers and timing** — [`core/dom/element.cc`][el-guard] (the interest state machine, delays, long press), [`core/dom/element.h`][el-delays], [`core/html/html_button_element.cc`][btn-invoker], [`core/html/html_anchor_element.cc`][a-invoker], [`core/html/forms/html_form_control_element.cc`][hfce-target], [`core/dom/interest_button_pseudo_element.cc`][ibpe-focus].
- **Interactive hover** — [`core/html/menu_safe_triangle.cc`][mst-consts] and its header, plus [`core/html/html_menu_item_element.cc`][menuitem-drag] and [`core/html/forms/html_option_element.h`][opt-epsilon].
- **Geometry** — [`core/layout/out_of_flow_layout_part.cc`][oofl-maxtry] (the fallback loop, overflow test, position visibility), [`core/layout/anchor_map.{h,cc}`][anchormap-accept], [`core/css/anchor_query.h`][anchorquery], [`core/layout/anchor_evaluator_impl.cc`][ae-logical], [`core/layout/absolute_utils.cc`][au-insets], [`core/layout/anchor_position_scroll_data.cc`][apsd-snapshot], [`core/layout/anchor_position_visibility_observer.cc`][apvo-root], [`core/css/out_of_flow_data.cc`][oofd-apply], [`core/css/style_engine.cc`][se-oof].
- **The flip algebra** — [`core/css/try_tactic_transform.h`][ttt] and [`core/css/try_value_flips.cc`][tvf].
- **Styling and metadata** — [`core/html/resources/html.css`][css-popover] (the UA stylesheet: `[popover]`, the two backdrops, `overlay`, `::interest-button`, the `::picker(select)` fallback list), [`core/css/container_query_evaluator.cc`][cqe-anchored], [`core/css/properties/longhands/longhands_custom.cc`][overlay-computed], [`core/css/post_style_update_scope.cc`][psus].
- **Reuse witnesses** — [`core/html/html_menu_list_element.cc`][menulist-hide], [`core/html/forms/html_data_list_element.cc`][datalist-hide], [`core/html/forms/select_type.cc`][selecttype-hide].
- **Tests read** — [`core/html/html_element_test.cc`][he-test] (top-layer removal timing); the anchor evaluator, try-tactic, out-of-flow layout, anchor-position scroll and anchor-scope unit tests were surveyed rather than read in full. Web-platform tests are not in the checkout.

Catalog context: the shared vocabulary in [`./concepts.md`][concepts], the umbrella [`./index.md`][index], the capstone [`./comparison.md`][comparison], the edge-case register in [`./features-people-forget.md`][forget]; the two specs this engine implements, [`./css-anchor.md`][css-anchor] and [`./popover-api.md`][popover-api], plus [`./aria-apg.md`][apg]; the library layer built on top of it in [`./floating-ui.md`][floating-ui] and [`./radix.md`][radix]; and the in-canvas and cell-grid peers [`./gpui.md`][gpui], [`./textual.md`][textual] and [`./neovim-floats.md`][nvim].

Adjacent sparkles material: what the toolkit ships today in [`./sparkles-baseline.md`][baseline] and what is proposed in [`./proposal.md`][proposal]; the [window-system integration][wsi] and [UI layout][ui-layout] research trees; and the toolkit's own [UI spec index][spec-ui], [input spec][spec-input], [containers spec][spec-containers], [state-machines spec][spec-stm], [backends spec][spec-backends] and [widgets spec][spec-widgets].

<!-- References -->

[repo]: https://chromium.googlesource.com/chromium/src
[repo-pin]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa
[oofl-maxtry]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/layout/out_of_flow_layout_part.cc#1989
[oofl-basestyle]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/layout/out_of_flow_layout_part.cc#2146
[oofl-range]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/layout/out_of_flow_layout_part.cc#66
[oofl-sort]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/layout/out_of_flow_layout_part.cc#2040
[oofl-fastout]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/layout/out_of_flow_layout_part.cc#265
[oofl-posvis]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/layout/out_of_flow_layout_part.cc#438
[oofl-cleara11y]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/layout/out_of_flow_layout_part.cc#316
[anchormap-accept]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/layout/anchor_map.cc#74
[anchormap-insert]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/layout/anchor_map.cc#44
[anchormap-key]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/layout/anchor_map.h#87
[anchormap-rect]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/layout/anchor_map.h#52
[anchorquery]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/css/anchor_query.h#24
[ae-logical]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/layout/anchor_evaluator_impl.cc#38
[ae-posarea]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/layout/anchor_evaluator_impl.cc#557
[ae-a11y]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/layout/anchor_evaluator_impl.cc#497
[apsd-snapshot]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/layout/anchor_position_scroll_data.cc#269
[apsd-valid]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/layout/anchor_position_scroll_data.cc#302
[apsd-translation]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/layout/anchor_position_scroll_data.cc#207
[apvo-root]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/layout/anchor_position_visibility_observer.cc#38
[au-insets]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/layout/absolute_utils.cc#326
[ttt]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/css/try_tactic_transform.h#72
[tvf]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/css/try_value_flips.cc#39
[se-oof]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/css/style_engine.cc#3961
[oofd-apply]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/css/out_of_flow_data.cc#35
[he-lightdismiss]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/html/html_element.cc#3083
[he-lightdismiss-click]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/html/html_element.cc#3122
[he-topmostrelated]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/html/html_element.cc#3006
[he-stackpos]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/html/html_element.cc#3015
[he-hidelight]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/html/html_element.cc#3038
[he-ancestor]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/html/html_element.cc#2889
[he-hideuntil]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/html/html_element.cc#2245
[he-removedfrom]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/html/html_element.cc#3868
[he-focusonshow]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/html/html_element.cc#2704
[he-shouldrestore]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/html/html_element.cc#2081
[he-restoreguard]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/html/html_element.cc#2676
[he-invokersdirty]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/html/html_element.cc#1573
[he-scopedshowing]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/html/html_element.cc#1398
[he-ready]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/html/html_element.cc#1475
[he-validity]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/html/html_element.cc#1954
[he-toggle]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/html/html_element.cc#2152
[he-setanchor]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/html/html_element.cc#2113
[he-test]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/html/html_element_test.cc#261
[pd-anchor]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/dom/popover_data.h#129
[pd-dead]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/dom/popover_data.h#123
[el-guard]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/dom/element.cc#1919
[el-gained]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/dom/element.cc#1935
[el-lost]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/dom/element.cc#2012
[el-longpress]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/dom/element.cc#2095
[el-isfinite-show]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/dom/element.cc#12828
[el-isfinite-hide]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/dom/element.cc#12861
[el-allsources]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/dom/element.cc#12956
[el-hoverfocus]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/dom/element.cc#12979
[el-implicitanchor]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/dom/element.cc#13874
[el-delays]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/dom/element.h#293
[mst-consts]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/html/menu_safe_triangle.cc#26
[mst-create]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/html/menu_safe_triangle.cc#44
[mst-recheck]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/html/menu_safe_triangle.cc#169
[mst-todo]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/html/menu_safe_triangle.cc#191
[mst-finish]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/html/menu_safe_triangle.cc#261
[mst-defer]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/html/menu_safe_triangle.cc#289
[doc-addtop]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/dom/document.cc#8613
[doc-schedule]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/dom/document.cc#8660
[doc-removefinished]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/dom/document.cc#8683
[doch-toplayer]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/dom/document.h#1725
[doch-menustack]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/dom/document.h#1813
[psus]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/css/post_style_update_scope.cc#55
[overlay-computed]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/css/properties/longhands/longhands_custom.cc#12284
[cqe-anchored]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/css/container_query_evaluator.cc#504
[cqe-update]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/css/container_query_evaluator.cc#720
[cw-budget]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/html/closewatcher/close_watcher.cc#118
[cw-escape]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/html/closewatcher/close_watcher.cc#158
[cw-signal]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/html/closewatcher/close_watcher.cc#165
[dlg-inert]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/html/html_dialog_element.cc#113
[dlg-a11y]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/html/html_dialog_element.cc#136
[dlg-closedby]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/html/html_dialog_element.cc#240
[dlg-nearest]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/html/html_dialog_element.cc#274
[css-popover]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/html/resources/html.css#1921
[css-backdrop-comment]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/html/resources/html.css#1959
[css-userselect]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/html/resources/html.css#1660
[ibpe-focus]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/dom/interest_button_pseudo_element.cc#53
[opt-epsilon]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/html/forms/html_option_element.h#179
[menuitem-drag]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/html/html_menu_item_element.cc#578
[menulist-hide]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/html/html_menu_list_element.cc#64
[datalist-hide]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/html/forms/html_data_list_element.cc#103
[selecttype-hide]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/html/forms/select_type.cc#181
[hfce-target]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/html/forms/html_form_control_element.cc#406
[btn-invoker]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/html/html_button_element.cc#209
[a-invoker]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/html/html_anchor_element.cc#456
[lb-a11yanchor]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/layout/layout_box.cc#4410
[index]: ./index.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[forget]: ./features-people-forget.md
[proposal]: ./proposal.md
[baseline]: ./sparkles-baseline.md
[css-anchor]: ./css-anchor.md
[popover-api]: ./popover-api.md
[apg]: ./aria-apg.md
[floating-ui]: ./floating-ui.md
[radix]: ./radix.md
[gpui]: ./gpui.md
[textual]: ./textual.md
[nvim]: ./neovim-floats.md
[wsi]: ../window-system-integration/index.md
[ui-layout]: ../ui-layout/index.md
[spec-ui]: ../../specs/ui/index.md
[spec-input]: ../../specs/ui/input.md
[spec-containers]: ../../specs/ui/containers.md
[spec-stm]: ../../specs/ui/state-machines.md
[spec-backends]: ../../specs/ui/backends.md
[spec-widgets]: ../../specs/ui/widgets.md
