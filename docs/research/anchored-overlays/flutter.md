# Flutter (Dart / Flutter framework)

Flutter paints every anchored overlay — tooltip, menu, submenu, dropdown, dialog, text-selection toolbar — into one render tree and one surface, so "in front" means nothing but "later in the paint order", which is exactly the constraint [`sparkles:ui`](../../specs/ui/index.md) works under.

| Field         | Value                                                                                                                            |
| ------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| Language      | Dart                                                                                                                             |
| License       | BSD-3-Clause (Copyright 2014 The Flutter Authors)                                                                                |
| Repository    | [`flutter/flutter`][repo]                                                                                                        |
| Documentation | [api.flutter.dev][apidocs] — this page is an **implementation reading**, not a docs reading                                      |
| Category      | Mobile / adaptive, in-canvas                                                                                                     |
| Surface model | In-canvas: one render tree, one clip, a derived paint order — with one narrow OS-popup escape hatch (`SystemContextMenu` on iOS) |
| Revision read | `feab40b83b8d1954106e83bb1d7b52265a41cb45` (`master`, SDK constraint `^3.10.0-0`)                                                |

> [!NOTE]
> The clone read for this page is a one-commit shallow, sparse checkout: `packages/` is absent from the worktree and every file was extracted with `git archive HEAD packages/flutter/{lib/src,test}`. All line numbers are the line numbers at the pinned SHA. History (`git log -- <file>`) was unavailable, so no claim here is dated relative to a release.

## Overview

### What it solves

Flutter has no OS popups. A `Tooltip`, a `MenuAnchor` panel, a `PopupMenuButton` route and a text-selection toolbar are all `RenderBox`es inside the same `Overlay`, rasterized in one pass into the same surface. The framework therefore has to answer, in library code and with no platform help, every question a compositor would otherwise answer: what paints in front of what, what receives a tap, what a "light dismiss" means when there is no grab, and how an overlay's geometry can depend on an anchor that is measured in the same layout pass.

Four load-bearing pieces answer it.

1. **`Overlay` / `_RenderTheater`** — a `Stack`-like `RenderBox` whose children are `OverlayEntry`s. `OverlayPortal` lets a widget deep in the tree build its overlay child _as its own widget child_ (inheriting `Theme`, `MediaQuery`, `Directionality`) while `_RenderDeferredLayoutBox` re-parents that child's _render_ subtree directly under the theater.
2. **Placement as a pure function** — four independent `SingleChildLayoutDelegate`s, each a value type with an equality-based `shouldRelayout`, each implementing `Offset getPositionForChild(Size overlaySize, Size childSize)`. No observers, no measurement side-channel.
3. **`TapRegion` / `TapRegionSurface`** — outside-tap dismissal as a registry of render objects plus one hit test per pointer-down, classified inside/outside by set membership in the hit path. No [grab](./concepts.md), no capture, no invisible scrim.
4. **Per-frame anchor recomputation** — the [anchor rect](./concepts.md) is recomputed inside the layout phase every frame and gated on value equality of a `(childSize, childPaintTransform, overlaySize)` record.

### Design philosophy

Geometry is data; ordering is derived from tree order plus a monotonic counter; state is either an `AnimationController` whose status _is_ the state, or an imperative controller with a request/commit split. The clearest statement of the philosophy is the comment that justifies the whole `OverlayPortal` mechanism — build in one place, paint in another — at `widgets/overlay.dart:2523-2533`:

> ```text
> // 1. It's a relayout boundary, and calling `markNeedsLayout` on it or adding it
> //    to the `_RenderTheater` as a child never dirties its `_RenderTheater`.
> //    Instead, it is always added to the `PipelineOwner`'s dirty list when it
> //    needs layout (even for the initial layout when it is first added to the
> //    tree).
> // 2. Its `layout` implementation is overridden such that `performLayout` does
> //    not do anything when its called from `layout`, preventing the parent
> //    `_RenderTheater` from laying out this subtree prematurely
> ```
>
> — [`packages/flutter/lib/src/widgets/overlay.dart:2523-2533`][overlay-defer]

The same file's `_TheaterParentData` doc states the ordering invariant that falls out of it — an overlay child paints "after its `OverlayPortal`, and before the next `OverlayEntry` (which could be something that should obstruct the overlay child, such as a `ModalRoute`)" (`widgets/overlay.dart:1169-1174`, [link][theater-parentdata]).

## How it works

**Deferred re-parenting.** `_RenderDeferredLayoutBox` opts out of the theater's layout walk and re-enters the `PipelineOwner` dirty list at a strictly greater depth, guaranteeing it lays out _after_ both the theater and the anchor's layout surrogate. Only then is `surrogate.getTransformTo(theater)` valid.

```text
frame N layout phase
  _RenderTheater.performLayout                 (surface size known)
  ...anchor subtree...
    _RenderLayoutSurrogateProxyBox.performLayout
      deferredChild._doLayoutFrom(this, tight(theaterSize))
        -> invokeLayoutCallback(() => markNeedsLayout())   // re-enqueue, deeper
  PipelineOwner drains dirty list by depth
    _RenderLayoutBuilder.performLayout
      info := (surrogate.size, surrogate.getTransformTo(theater), theater.size)
      if (info != previousInfo) rebuild overlay child inside buildScope
      run the SingleChildLayoutDelegate
      scheduleFrameCallback(_frameCallback, scheduleNewFrame: false)
```

**Placement.** The delegate contract is three methods and no state (`rendering/custom_layout.dart`), so a placement policy is a value that can be compared, cached and swapped by callers (`RawTooltip.positionDelegate`, `PopupMenuPositionBuilder`). The minimal instance is the free function `positionDependentBox` — 27 lines of arithmetic, `painting/geometry.dart:41-67`:

```dart
final bool fitsBelow = target.dy + verticalOffset + childSize.height <= size.height - margin;
final bool fitsAbove = target.dy - verticalOffset - childSize.height >= margin;
final tooltipBelow = fitsAbove == fitsBelow ? preferBelow : fitsBelow;
```

If both sides fit or neither fits, honour the preference; otherwise take the side that fits. That is the entire [flip](./concepts.md) rule for tooltips.

**Outside taps.** `RenderTapRegionSurface.handleEvent` retrieves the cached `BoxHitTestResult` for the pointer, computes the hit regions, expands each to its whole `groupId` set, and takes the set difference — `widgets/tap_region.dart:323-340`. Consumption is a separate, opt-in step that never blocks the hit test:

```dart
// If any of the "outside" regions have consumeOutsideTaps set, then stop
// the propagation of the event through the gesture recognizer by adding it
// to the recognizer and immediately resolving it.
if (consumeOutsideTaps && event is PointerDownEvent) {
  GestureBinding.instance.gestureArena
      .add(event.pointer, _DummyTapRecognizer())
      .resolve(GestureDisposition.accepted);
}
```

— [`widgets/tap_region.dart:400-407`][tapregion-consume]

## The analysis spine

### 1. Anchor model

**Algorithm.** The anchor is a value computed during layout and handed to a builder. `OverlayChildLayoutInfo` is a Dart extension type over the record `(Size childSize, Matrix4 childPaintTransform, Size overlaySize)` — nothing more (`widgets/overlay.dart:39`). Consumers reduce it: `RawMenuAnchor._buildOverlay` collapses it to `Rect anchorRect = MatrixUtils.transformRect(transform, Offset.zero & anchorSize)` and packs it into the immutable `RawMenuOverlayInfo{anchorRect, overlaySize, position, tapRegionGroupId}` with hand-written `operator==`/`hashCode` (`widgets/raw_menu_anchor.dart:45`); `RawTooltipState._buildTooltipOverlay` collapses it further to a single `Offset target = transformPoint(transform, childSize.center)` (`widgets/raw_tooltip.dart:806`).

Anchor variants observed: element/rect (the portal's own child box); point/cursor — `MenuController.open(position: Offset)` in **anchor-local** coordinates, added to `anchorRect.topLeft` inside the delegate and overriding the alignment path entirely; text-range multi-rect — `TextSelectionToolbarAnchors.fromSelection` collapses N endpoints to ONE rect (the full editing-region width when multiline, else the span between endpoints) and then to TWO candidate `Offset`s, primary and secondary (`widgets/text_selection_toolbar_anchors.dart:27`); [detached trigger vs anchor](./concepts.md) — `RawMenuAnchor.childFocusNode` separates the focus target from the anchor box, and `MenuAnchor.layerLink` makes the panel follow a `CompositedTransformTarget` elsewhere, at which point `anchorRect` is deliberately `Rect.zero` (`material/menu_anchor.dart:3852`); [virtual anchors](./concepts.md) of zero area (a test pins that a zero-size anchor does not crash); and moving anchors (the rect is re-derived every frame, with a regression test asserting `anchorRect` updates when a sibling widget is removed, `test/widgets/raw_menu_anchor_test.dart:3134`).

"Many triggers, one popup" is **not** expressible through the anchor primitives: one `OverlayPortalController` per `OverlayPortal`, one `MenuController` per anchor (asserted). The one place it exists is `ContextMenuController`, which holds the builder, the `OverlayEntry` and the shown instance in **static** fields, enforcing app-wide singleton-ness (`widgets/context_menu_controller.dart:43`).

Anchor-to-surface conversion is `layoutSurrogate.getTransformTo(theater)`, guarded by a debug assert that walks the ancestor chain and throws if a `RenderFollowerLayer` is in the path, because such a layer only establishes its transform at composite time (`widgets/overlay.dart:2874`).

**Where the behavior lives.** Library code only, in the backend-neutral widgets layer. No platform primitive, no accessibility API, no compositor.

**Degradation.** Everything here survives: the anchor is already a comparable value with no window, no hover and no script dependency. Dropping sub-cell precision turns `Matrix4` into an integer cell offset and `anchorRect` into a cell `Rect`; the only loss is scale and rotation. On a static-HTML target the anchor rect must be known at emit time — which Flutter's design also assumes, since it computes during layout, before paint. Key release is not involved.

### 2. Placement model

**Algorithm.** Placement is four separate pure functions sharing only a signature. The common shape:

```text
constraints := loose(overlaySize) deflated by reservedPadding
allowed     := closestSubScreen(splitByAvoidBounds(padding.deflate(viewInsets.deflate(overlayRect))),
                                anchorRect.center)
desired     := anchorAlignment.withinRect(anchorRect) + rtlAdjust(alignmentOffset)
if RTL: desired.x -= childW
per axis:
  if child >= allowed.extent            -> pin to allowed.start
  else if offStart(v) -> v' := oppositeEdgeOf(anchor); v := offEnd(v')   ? allowed.start          : v'
  else if offEnd(v)   -> v' := oppositeEdgeOf(anchor); v := offStart(v') ? allowed.end - child    : v'
```

The four differ in exactly the interesting place — the flip rule:

| Delegate                          | Flip                                                                                                    | Notes                                                                                                                                                               |
| --------------------------------- | ------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `positionDependentBox` (tooltips) | vertical only, `fitsAbove == fitsBelow ? preferBelow : fitsBelow`                                       | then clamp `y`; cross axis centres on the target and clamps into `[margin, flexibleSpace - margin]`, degenerating to dead-centre when `flexibleSpace <= 2 * margin` |
| `_MenuLayout` (Material menus)    | to the **opposite anchor edge** (`anchorRect.right + offset` / `anchorRect.left - childWidth - offset`) | carries a rule no other delegate has: `if (parentOrientation != orientation) x = allowedRect.left` — push, do not flip                                              |
| `_PopupMenuRouteLayout`           | none                                                                                                    | picks a growth direction by comparing `position.left` vs `position.right`, breaks ties with `textDirection`, then pure-clamps                                       |
| Cupertino `_MenuLayoutDelegate`   | **mirror across the anchor centre**, `flipX = anchor.center.dx * 2 - position.dx - childSize.width`     | both axes, plus a rule that shifts vertically by the minimum needed to stop overlapping the anchor when the menu is wider than the screen                           |

A preferred-list / auto-placement mechanism in the [CSS-anchor](./css-anchor.md) sense does not exist: each delegate hardcodes one preference plus one fallback. Viewport padding constants diverge — `_kMenuScreenPadding = 8`, `_kMenuViewPadding = 8`, tooltip `margin = 10.0`.

The safe area is `mediaQueryData.padding.deflateRect(...)` and the IME inset is `mediaQueryData.viewInsets.deflateRect(...)` for menus, `Positioned.fill(bottom: MediaQuery.maybeViewInsetsOf(context)?.bottom ?? 0.0)` for tooltips. In both cases the keyboard inset is an **input carried in inherited data**, never discovered by the placement code. There is no multi-monitor concept (one `Overlay` per `FlutterView`); the analogue is `DisplayFeature` avoid-bounds for folds and cutouts.

**Where the behavior lives.** Entirely inside layout delegates: `painting/geometry.dart:41`, `material/menu_anchor.dart:3346`, `material/popup_menu.dart:811`, `cupertino/menu_anchor.dart:1225`, `widgets/text_selection_toolbar_layout_delegate.dart:26`. Insets arrive from `MediaQuery`, fed by the engine's platform dispatcher.

**Degradation.** Pure `Size`/`Rect` arithmetic; in integer cells the same code with `int`. No hover, no script, no window and no key release enter any of it. A static-HTML target with no measurement at emit time loses the dimension entirely — the honest tier-0 answer there is one baked side plus CSS clamping. Android's soft keyboard is already modelled the way a cell toolkit would want it: an inset value the placement function deflates the viewport by, supplied from outside.

### 3. Collision & geometry engine

**Algorithm.** There is no [clipping-boundary](./concepts.md) discovery, because exactly one clip matters: `_RenderTheater.paint` pushes a `ClipRectLayer` over `Offset.zero & size` with default `Clip.hardEdge` (`widgets/overlay.dart:1531`). An overlay child escapes every clip between itself and the theater — it is re-parented in the render tree — but cannot escape the theater's own rect. Overflow detection is therefore arithmetic against `overlaySize` minus insets: no ancestor walk, no scroll-container search.

Transforms and zoom are handled exactly, because the anchor arrives as a full `Matrix4`; a test asserts a `Transform(diagonal3Values(2, 4, 1))` ancestor is reflected in `childPaintTransform`. Tracking is **frame-callback polling, not observers**: `_RenderLayoutBuilder.performLayout` ends with `SchedulerBinding.instance.scheduleFrameCallback(_frameCallback, scheduleNewFrame: false)` and `_frameCallback` calls `markNeedsLayout` — so on every frame _already being produced_ the layout callback re-runs, and it never forces a frame. Cost is bounded by a value gate one level up: `_LayoutBuilderElement._rebuildWithConstraints` passes a rebuild callback to `buildScope` only when `_needsBuild || layoutInfo != _previousLayoutInfo` (`widgets/layout_builder.dart:267`), so a stationary anchor costs one matrix multiply plus one record comparison per frame and zero rebuilds.

Adding or removing a deferred child deliberately does _not_ dirty the theater's layout: `_RenderTheater.markNeedsLayout` no-ops while `_outstandingDeferredChildUpdateCalls > 0` and `markNeedsPaint` is issued instead, pinned by a test named "adding/removing overlay child does not redirty overlay more than once". Scrolling is not tracked at all — menus close instead (dimension 8).

**Where the behavior lives.** Framework kernel: `RenderObject.invokeLayoutCallback` and `PipelineOwner`'s depth-ordered dirty list, plus `overlay.dart`'s `_RenderDeferredLayoutBox` / `_RenderLayoutSurrogateProxyBox` / `_RenderLayoutBuilder` and `layout_builder.dart`'s rebuild gate. Nothing platform-specific.

**Degradation.** Two things generalise off the substrate: the value-gated per-frame recompute, and the depth-ordering discipline ("the overlay's layout must happen after the anchor's"), which in a single-pass `view → layout → buildDisplayList` toolkit maps to running a second placement pass after the main layout pass. The `PipelineOwner` dirty list, relayout boundaries and `invokeLayoutCallback` do not generalise. With no sub-cell precision the matrix collapses to an integer translation and the comparison becomes trivially cheap; on static HTML the whole dimension vanishes.

### 4. Arrow / caret geometry

Material ships **no arrow anywhere**: `Tooltip` is a rounded box with a 24-pixel `verticalOffset` gap and no beak, and `MenuAnchor`/`PopupMenuButton` have none. The only arrow in the framework is Cupertino's text-selection toolbar, and it is instructive: the arrow is not a widget and not a child — it is folded into the surface's clip `Path` inside `_RenderCupertinoTextSelectionToolbarShape._clipPath`.

**Algorithm.**

```text
isAbove    := anchorAbove.dy >= childHeight - arrowH
childOffset.dy := isAbove ? -arrowH : 0
arrowTipX  := clamp(localAnchor.dx, radius + arrowW/2, surfaceW - arrowW/2 - radius)
if (2*radius + arrowW > surfaceW) emit a plain rounded rect          // arrow dropped
else moveTo(arrowTipX ± arrowW/2, arrowBaseY); lineTo(arrowTipX, arrowTipY);
     lineTo(arrowTipX ∓ arrowW/2, arrowBaseY); append rrect from angle (isAbove ? +π/2 : -π/2)
```

Its geometry is two constants and a clamp: `_kToolbarArrowSize = Size(14, 7)` and a tip that tracks the anchor but is corner-constrained so it never intrudes into the rounded corners. The arrow **size feeds placement** in two places — the child is offset by `-arrowHeight` when placed above, and the fits-above test is biased by it — and the arrow is dropped entirely when `2 * borderRadius.x + arrowWidth > width`, with a comment noting this should be rare and that the arrow would not be useful anyway (`cupertino/text_selection_toolbar.dart:369-377`).

**Where the behavior lives.** One `RenderBox` in `cupertino/text_selection_toolbar.dart`. Nothing in the widgets layer knows about arrows; the Material layer has none.

**Degradation.** In a character grid an arrow is one glyph in one cell on the border run, at column `clamp(anchorCenterCol, boxLeft + 1, boxRight - 1)`. The algorithm survives with `radius = 0` and `arrowW = arrowH = 1`: "drop the arrow if too narrow" becomes "drop it if the box is at most two cells wide", and "the arrow feeds the offset" becomes "reserve one row when placing above or below". Nothing here depends on hover, script, a window or key release — arrow geometry is pure output. Worth noting that Flutter's own cheapest usable answer, in Material, is no arrow at all plus a gap.

### 5. Trigger semantics

**Algorithm.** Tooltip triggers are hover, touch (long-press or tap via `TooltipTriggerMode`) and programmatic (`ensureTooltipVisible`). The two pointer families are made disjoint **by construction, not by arbitration**:

```text
hover : served by _ExclusiveMouseRegion, a MouseRegion that only tracks PointerDeviceKind.mouse
touch : Listener(onPointerDown:) lazily builds a LongPress or Tap recognizer whose
        supportedDevices = {invertedStylus, stylus, touch, unknown, trackpad}   // mouse excluded

exclusiveHitTest(node, pos):
    outermost := isOutermostMouseRegion; isOutermostMouseRegion := false
    hit := childHit || selfHit
    if ((hit || translucent) && !foundInnermost) { foundInnermost := true; addToResult(node) }
    if (outermost) { isOutermostMouseRegion := true; foundInnermost := false }
    return hit
```

`_RenderExclusiveMouseRegion` uses two class-level static booleans so that in a nest of tooltips only the **innermost** is added to the hit result — that is how a chip with a delete icon does not fire both tooltips (`widgets/raw_tooltip.dart:184-210`). A third channel is a **global pointer route** (`pointerRouter.addGlobalRoute`) registered in `initState` and used for dismissal; the obvious race is defused by comparing `event.pointer` against the recognizers' `primaryPointer` and returning early, so a tooltip's own triggering pointer can never dismiss it. The code notes global routes are dispatched _after_ other routes.

Menus combine tap, hover, focus, arrow keys and programmatic opening, and the combination rule is that **hover does not open**: `onHover` requests focus and _focus_ opens (`material/menu_anchor.dart:2183`, `:2309`). Menubar-level buttons additionally refuse to open on hover unless a sibling is already open. Assistive-technology-triggered activation is real: `RenderTapRegionSurface` subscribes to `SemanticsBinding.addSemanticsActionListener`, fetches the node's view-coordinate rect on a semantics tap or long-press, hit-tests its centre, and reuses `_classifyRegions` with a synthesised `PointerDownEvent`.

**Where the behavior lives.** Three layers: `widgets/raw_tooltip.dart` (exclusive region, recognizers, global route), the gestures kernel (`GestureBinding.pointerRouter`, the gesture arena, `PointerDeviceKind`), `material/menu_anchor.dart` (hover → focus → open) and the semantics binding.

**Degradation.** A terminal grid does serve hover, so the innermost-wins rule still matters — and it is cheap, being "first hit in reverse paint order wins". Android has no hover, and Flutter's device-kind partition means the Android build simply never enters the hover branch with no code change; an event vocabulary that carries pointer kind as an explicit field gets the same property (`sparkles:input` does not carry one today — see [`../../specs/ui/input.md`](../../specs/ui/input.md)). What a keyboard with no key release removes is _keyboard_ press-and-hold, not pointer long-press: pointer release is a distinct capability the terminal serves over SGR-1006, so the touch family's press/hold/release shape is expressible where a pointer exists. On static HTML only `:hover` and `:focus-within` survive, and with no timers the delays collapse to zero. Under a recording canvas every trigger is assertable, since all of them are functions of injected events plus a clock.

### 6. Timing

**Algorithm.** The tooltip owns exactly one `Timer?` and one `AnimationController`, and the animation status _is_ the state variable.

```text
states = Dismissed | Delaying | Forward | Shown | Reverse         (one timer)

onHoverEnter(d): devices += d
                 others := openedTooltips.where(t => t.devices.isEmpty)
                 for t in others: t.dismiss(0)
                 show(withDelay = others.isEmpty ? hoverDelay : 0, touchDelay = null)
onHoverExit(d):  devices -= d; if devices.isEmpty: dismiss(withDelay = dismissDelay)
onTouchTrigger:  show(withDelay = 0, touchDelay = devices.isEmpty ? touchDelay : null)
show(w, t):      if (dismissed && w > 0) timer := Timer(w, go) else go()
                 go(): forward(); timer := t == null ? null : Timer(t, reverse)
dismiss(w):      timer.cancel(); if (isForwardOrCompleted) { w > 0 ? timer := Timer(w, reverse) : reverse() }
onStatus(dismissed -> live): openedTooltips.add(this); showOverlay(); announce()
onStatus(live -> dismissed): openedTooltips.remove(this); hideOverlay()
```

`hoverDelay` (Material `waitDuration`, default 0) is the [warm-up](./concepts.md); `touchDelay` (Material `showDuration`, default 1500 ms) is the _maximum display_ duration after a touch trigger; `dismissDelay` (Material `exitDuration`, default 100 ms) is the close delay after the last hovering device leaves. `_scheduleShowTooltip` honours the delay only when `_controller.isDismissed` — if already animating in or visible it shows immediately, which is the built-in anti-flicker rule. Two asserts pin the invariant that the timer must not be active while the tooltip animates out.

The [cool-down](./concepts.md) / skip-delay behaviour is **not** a shared provider, group or singleton timer: it is derived from the static list `RawTooltip._openedTooltips`. On mouse enter the tooltip collects every opened tooltip whose `_activeHoveringPointerDevices` is empty, dismisses them, and shows itself with `withDelay: tooltipsToDismiss.isNotEmpty ? Duration.zero : widget.hoverDelay` (`widgets/raw_tooltip.dart:749-758`). The code relies on the mouse tracker dispatching all `onExit` events before any `onEnter`. Membership in `_openedTooltips` is mutated **only** from `_handleStatusChanged`, so registry membership cannot desync from visibility.

Menus have a separate, simpler timer: `SubmenuButton.hoverOpenDelay` (default zero) arms `Timer(delay, controller.open)`, cleared on focus change and pointer exit, and a debug-only `FlutterError` forbids a non-zero value on a menubar-level button because the sibling's 150 ms closing animation would beat it (`material/menu_anchor.dart:2349`).

**Where the behavior lives.** Entirely in `widgets/raw_tooltip.dart` plus a `static final List<RawTooltipState> _openedTooltips` process global. Material contributes only default `Duration`s (`material/tooltip.dart:392-394`).

**Degradation.** The design needs only a monotonic clock and a frame loop, so a TUI or GUI target can host it as-is; the single-timer-plus-status shape suits value semantics well, since the timer reduces to a deadline stored as a tick count and the state to one enum. Static HTML has no timers: all three delays collapse to zero and the max-display timer vanishes, leaving "visible exactly while `:hover` holds". On Android there is no hover, so `hoverDelay`/`dismissDelay` are dead and `touchDelay` is the only live timer.

### 7. Interactive hover (travel, safe polygon, menu-aim)

This dimension is largely an **absence**, and the absence is the finding. There is no [safe polygon](./concepts.md), no pointer bridge, no trajectory heuristic and no menu-aim in `packages/flutter`: a case-insensitive grep for `safe polygon`, `safeTriangle`, `menu.aim` and `diagonal` over `lib/src` returns only unrelated matrix and scroll-axis hits.

**Algorithm.** Two mechanisms stand in.

1. _Tooltips._ The overlay child is wrapped in the **same** `_ExclusiveMouseRegion(onEnter: _handleMouseEnter, onExit: _handleMouseExit)` as the trigger, so the tooltip counts as part of its own trigger region and hovering it keeps `_activeHoveringPointerDevices` non-empty ("Keep the tooltip visible while the overlay child is hovered", `widgets/raw_tooltip.dart:811`). The gap across the 24-pixel `verticalOffset` is bridged by the 100 ms `dismissDelay` alone — a debounce, not geometry. Cost: `O(1)` per pointer move, zero geometry. A test named "Tooltip text is also hoverable" pins it.
2. _Submenus._ Retention is not pointer-geometric at all: hover requests focus, focus opens the submenu, and the submenu closes when focus leaves the scope. Diagonal travel toward an open submenu therefore works only when the pointer does not cross an intermediate sibling item — crossing one requests focus on that sibling, which closes the submenu. Flutter accepts that; `hoverOpenDelay` is the only mitigation offered, and it is a debug error at menubar level.

> [!WARNING]
> Material's tooltip is pointer-transparent by default: `ignorePointer: widget.ignorePointer ?? widget.message != null` (`material/tooltip.dart:554`). A plain-text tooltip cannot be hovered; only a `richMessage` tooltip is interactive. An easily-missed split, and it means the travel behaviour above applies to the rich case only.

**Where the behavior lives.** `widgets/raw_tooltip.dart:814` (the exclusive region around the overlay child), `material/menu_anchor.dart:2297` (`_SubmenuButtonState._handleFocusChange`), `material/menu_anchor.dart:1272` (`_MenuItemButtonState._handleFocusChange` closing children).

**Degradation.** Flutter's chosen bridge costs zero cells — a debounce over the union of two rects, which a cell grid implements exactly (rects are cell rects; the timer is frames). A safe polygon _confined to the gap between anchor and surface_ would, at the 0-to-1-cell corridors these defaults produce, classify the same whole cells as the corridor rectangle itself; note that the polygons implemented elsewhere in this catalog are not corridor-confined — they hull the anchor and the surface — so this is a statement about the corridor only, and [`./comparison.md`](./comparison.md) is where the corpus-wide claim belongs. INFERENCE: for a cell grid, Flutter's answer (zero-gap placement plus a short close-debounce) appears to be the better-value one, since the trajectory information a polygon consumes does not survive cell quantization. Android removes the dimension entirely; static HTML has no timers, so even the debounce is gone and the tier-0 answer is `:hover` over a wrapper containing both trigger and surface with no gap.

### 8. Dismissal

Three completely different dismissal engines coexist, and the split is deliberate.

**(A) Tooltip** uses the global pointer route, _not_ `TapRegion`: any `PointerDownEvent` anywhere in the app that is not the tooltip's own trigger pointer dismisses it (`enableTapToDismiss` gates this, and it also clears `_activeHoveringPointerDevices`, so a click dismisses even a still-hovered tooltip). Escape is handled at the very top of `WidgetsApp` by a `Focus(canRequestFocus: false, onKeyEvent:)` that fires on `KeyDownEvent`/`KeyRepeatEvent` only and calls the static `RawTooltip.dismissAllToolTips()` (`widgets/app.dart:1781`); an open TODO wants it moved to `Actions`/`Shortcuts`. Other causes: mouse exit plus `dismissDelay`, `touchDelay` expiry, long-press release plus `touchDelay`, and **anchor invisible** — `_buildTooltipOverlay` returns `SizedBox.shrink()` when `layoutInfo.childPaintTransform.determinant() == 0.0`.

**(B) Menus** use `TapRegion` with `groupId: root.menuController`, so the whole menu tree (anchor plus every open panel) is **one region**: a pointer-down inside any member is "inside" for all, and `onTapOutside` fires only when the tap misses every member. It fires on pointer **down** and on any mouse button — tests pin right-click and middle-click outside dismissal.

```text
onPointerDownOrUp(e):
    result  := cachedHitResultFor(e)
    hit     := {r in registered : r in result.path}
    inside  := union over hit of (r.groupId == null ? {r} : group[r.groupId])
    outside := registered \ inside            // MATERIALISED — callbacks mutate the registry
    for r in outside: r.onTapOutside(e); consume |= r.consumeOutsideTaps
    for r in inside:  r.onTapInside(e)
    if (consume && isDown) winGestureArena(e.pointer)
```

Further menu causes: ancestor scroll closes (the root anchor listens to `Scrollable.maybeOf(context)?.position.isScrollingNotifier`) but **internal** scroll does not, covered by a dedicated regression test; view resize closes (`MediaQuery.sizeOf` compared in `didChangeDependencies`); a sibling opening closes (`open()` calls `_parent?.requestChildrenClose()` first); a parent closing closes children first; item activation closes the root (`closeOnActivate`); dispose closes. Escape is a `DismissIntent` bound to `DismissMenuAction`, registered **only while open** so Escape bubbles when the menu is closed. Not handled: the system back key, app deactivation or window blur, and anchor-scrolled-out-of-view (subsumed by close-on-ancestor-scroll).

**(C) `PopupRoute`** (including `PopupMenuButton` and dialogs) dismisses through a `ModalBarrier` — `barrierDismissible` pops on any tap-up over an opaque full-screen gesture detector — plus `Navigator.pop` and, on Android, the system back button through the route stack.

**Where the behavior lives.** `widgets/tap_region.dart` (registry and classification), `widgets/raw_tooltip.dart` + `widgets/app.dart:1781`, and `widgets/routes.dart` + `widgets/modal_barrier.dart`. The gesture arena is framework kernel. `TapRegion.createRenderObject` consults `ModalRoute.isCurrentOf(context)` and nulls out `onTapOutside`/`consumeOutsideTaps` when the region's route is not current, so a background page's popup cannot eat taps meant for the foreground page.

**Degradation.** `TapRegion` is the most directly transplantable piece of this subject: it is built from hit testing alone, needs no grab, no capture and no scrim, and works over the last painted frame's hit list — which is how `sparkles:ui` already routes events ([`../../specs/ui/state-machines.md`](../../specs/ui/state-machines.md)). The group-id trick is what makes submenu chains dismiss correctly, and it is just a comparable key. A keyboard with no release loses nothing here: every dismissal is triggered by a key **down** or a pointer down/up. There is no window-deactivation dismissal to lose, because Flutter has none. On Android the missing piece is the system back key, which Flutter wires only for route-based popups. On static HTML there is no pointer-down handler, so outside-dismissal is not expressible at all.

### 9. Focus

The four surface kinds are kept sharply distinct.

- **Tooltip**: never focusable, no focus node at all — a visual plus semantics-description layer only.
- **Menu** (`RawMenuAnchor`/`MenuAnchor`): **not** a [focus scope](./concepts.md) trap. The panel is wrapped in `FocusScope(node: anchor._menuScopeNode, skipTraversal: true)`, and there is a test literally named "Tab traversal is not handled". On open, focus goes to the **anchor**, not into the menu (`if (_isRootOverlayAnchor) widget.childFocusNode?.requestFocus()`). Entry is by arrow keys only: `_kMenuTraversalShortcuts` maps arrows to `DirectionalFocusIntent` and `_SubmenuDirectionalFocusAction` implements a full orientation- and RTL-aware table — Down on a menubar button focuses the first item, Up focuses the **last**, explicitly so that upward-opening submenus feel right, and Right/Left enters or exits a submenu, opening it and post-frame focusing its first item if it was not already open.
- **Dialog / `PopupRoute`**: real containment — `_ModalScope` installs a `FocusScopeNode` with a `traversalEdgeBehavior`, and `_PopupMenuRoute` forces `TraversalEdgeBehavior.closedLoop` with the comment that menus always cycle focus through their items irrespective of the `Navigator`'s setting.
- **Cupertino** differs again: `_handleOpenRequested` calls `FocusScope.of(context).setFirstFocus(_menuScopeNode)`, pre-arming the menu scope.

**Algorithm.**

```text
openMenu():        if root: anchorFocusNode.requestFocus()          // focus stays OUTSIDE the surface
onArrowInto():     policy := FocusTraversalGroup.maybeOf(menuScope.context) ?? ReadingOrderTraversalPolicy()
                   target := down ? policy.findFirstFocus(menuScope, ignoreCurrentFocus: true)
                                  : policy.findLastFocus (menuScope, ignoreCurrentFocus: true)
                   target.requestFocus()
onFocusChanged(n): if (!n.hasPrimaryFocus && !menuScope.hasFocus && isOpen) close()
onItemFocusLost(i):i.parentController.closeChildren()
reopenGuard:       after close(), if the button did not have focus, set openOnFocusEnabled := false
                   and restore it in a post-frame callback (exactly one frame)
```

Focus restoration is implicit — focus never left the anchor, so closing restores nothing. Hover-focus coupling is explicit: `MenuItemButton.requestFocusOnHover` makes hover request focus and then calls `FocusTraversalGroup.of(context).invalidateScopeData(...)` so subsequent directional traversal originates from the hovered node. A pointer-opened menu therefore has focus on the anchor with nothing highlighted, while a keyboard-opened menu lands on the first or last item.

**Where the behavior lives.** Library code plus the framework's focus kernel (`FocusManager`, `FocusTraversalPolicy`, `FocusScopeNode`, `Actions`/`Shortcuts`/`Intents`).

**Degradation.** Every focus interaction read in Flutter's menu and tooltip code is driven by a key **down**, so a target without key release keeps all of it; that is a statement about this source tree, not about overlay focus in general — release-edge focus affordances do exist elsewhere in the catalog (see [`./wpf.md`](./wpf.md)) and must be rebound to a press edge. There are no window-focus events to lose, since Flutter has none. The transplantable core is four rules: focus lives on the anchor rather than in the surface for pointer-opened menus; arrow keys are the only entry; "focus left the scope" is the close condition for submenus; and the one-frame reopen guard. On Android touch there is no practical focus concept, so the whole focus machine is dead weight there — an argument for keeping it an optional layer rather than part of the primitive.

### 10. Layering & portals

One render tree, one surface, no z-index, no stacking context, no per-overlay compositor layer.

**Algorithm.**

```text
paintOrder(theater)   := for each onstage entry e, in list order:
                             yield e.subtree
                             for each portal loc of e ascending by zOrderIndex: yield loc.renderBox
hitTestOrder(theater) := for each onstage entry e, reversed:
                             for each portal loc of e descending: yield loc.renderBox
                             yield e.subtree
bringToFront(portal)  := portal.zOrderIndex := ++globalCounter; re-sort within the owning entry
onstageEntries        := walk entries from the top; include until (and including) the first `opaque`
                         entry; below that include only `maintainState` entries, built with tickers
                         disabled and counted into skipCount
```

The public API is deliberately tiny — `Overlay`, `OverlayEntry`, `OverlayState`, `OverlayPortal`, `OverlayPortalController`, `OverlayChildLocation`, `OverlayChildLayoutInfo` — while everything doing the work is private (`_RenderTheater`, `_TheaterParentData`, `_OverlayEntryLocation`, `_RenderDeferredLayoutBox`, `_RenderLayoutSurrogateProxyBox`, `_RenderLayoutBuilder`, and more). The element **slot** for a re-parented child is `_OverlayEntryLocation(zOrderIndex, owningOverlayEntryState, theater)`; the class deliberately does _not_ implement `operator==`, with a comment explaining that it is mutable, so one instance must never represent two locations.

The z-order stamp is a process-wide monotonic counter: `OverlayPortalController._wallTime` starts at `-1 << 63` (or `-2^53` on web) and `_now()` post-increments, so `show()` on an already-showing portal is [bring-to-front](./concepts.md). Insertion into the per-entry sorted list is a backwards linear scan from the tail, documented as worst-case `O(N)` for N children shown in the same frame. Both order generators are `sync*` generators specifically so the child model may be mutated during layout or hit test.

Multiple overlay trees exist — `nearestOverlay` versus `rootOverlay`, resolved through `_RenderTheaterMarker` (an `InheritedWidget`) plus `LookupBoundary` and a recursive `_rootRenderTheaterMarkerOf` walk. `RawMenuAnchor.useRootOverlay` picks, and submenus are forced to inherit their root anchor's choice.

**Where the behavior lives.** One file (`widgets/overlay.dart`) plus the render kernel's `adoptChild`/`dropChild`/`redepthChild`/`attach`/`detach` protocol. No compositor involvement beyond one `ClipRectLayer`.

**Degradation.** `_childrenInPaintOrder` is "front == later in the display list" and `_childrenInHitTestOrder` is "hit testing == reverse paint order over a flat derived list", which is already the toolkit shape in [`../../specs/ui/backends.md`](../../specs/ui/backends.md). Transplantable: the two-level ordering (owner entry, then that owner's overlays by monotonic stamp), the monotonic counter as the entire bring-to-front mechanism, the invariant that an overlay may not float above a _later_ top-level entry, and the rule that the surface's own clip is not escapable. Element slots, `GlobalKey` reparenting, `adoptChild`/`redepth`, `Expando` and linked-list machinery do not transplant. INFERENCE: in a value-semantics toolkit the whole thing appears to reduce to a two-field order key (owner entry, then stamp) plus a stable sort of a flat array before display-list emission — and a two-level key of this shape looks preferable to a single flat integer priority, which is the shape [`./gpui.md`](./gpui.md) uses. Nothing in this dimension touches hover, windows, key release, script or sub-cell precision.

### 11. Modality

Two disjoint regimes, with the primitive layer firmly non-modal.

**Non-modal** (`OverlayPortal`, `RawMenuAnchor`, `RawTooltip`, `ContextMenuController`): no scrim, no barrier widget, background fully hit-testable and keyboard-reachable. [Light dismiss](./concepts.md) is `TapRegion.onTapOutside`. The only concession to blocking is `consumeOutsideTaps`, which blocks nothing structurally — the dismissing pointer-down still traverses the hit test as usual, and the surface then wins the gesture arena for that pointer with a `_DummyTapRecognizer` resolved accepted, so downstream recognizers never fire for that tap. Granularity is per group: if any member of a tap-region group sets `consumeOutsideTaps`, the whole group consumes; menus additionally gate it on `root.isOpen`, so a closed menu never consumes.

**Modal** (`PopupRoute` and everything on it, including `showMenu` and `PopupMenuButton`): a real `ModalBarrier` `OverlayEntry` is inserted _below_ the route's scope entry. It is a `RawGestureDetector(behavior: HitTestBehavior.opaque)` with an `_AnyTapGestureRecognizer`, so it blocks all pointer input regardless of `barrierColor` — `_PopupMenuRoute` sets `barrierColor => null`, i.e. invisible but blocking. Keyboard blocking comes from the route's focus scope, not from the barrier. The accessibility modal bit is `BlockSemantics` plus `ExcludeSemantics(excluding: !semanticsDismissible || !barrierSemanticsDismissible)`, and `semanticsDismissible` is platform-conditional: false on Linux/Windows/Fuchsia, true on Android/iOS/macOS, with a non-dismissible barrier tap playing `SystemSoundType.alert`.

`IgnorePointer` is also used as a **temporal** modality switch: `MenuAnchor._buildOverlay` wraps the panel in `ExcludeSemantics` + `IgnorePointer` + `ExcludeFocus`, all keyed on `isClosingOrClosed`, so a menu animating out is visible but inert.

**Where the behavior lives.** `widgets/modal_barrier.dart`, `widgets/routes.dart:2320`, `widgets/tap_region.dart:403`, `material/menu_anchor.dart:700`.

**Degradation.** Everything here works in one surface with no OS support. A barrier is a full-viewport opaque hit rect painted before the surface — one display-list entry, zero platform involvement; the scrim colour is optional, and a cell backend can drop it or dim by re-styling cells (with the caveat that a background-only blend leaves glyph foregrounds untouched — see [`./sparkles-baseline.md`](./sparkles-baseline.md)). Keyboard blocking in a cell toolkit is "route keys to the top-most modal surface first". INFERENCE: `consumeOutsideTaps` needs a gesture arena, which a toolkit routing its own events does not have; the equivalent appears to be "mark the event handled and stop routing" after the dismissal handler runs, which is simpler and loses only the multi-recognizer arbitration Flutter needs. The tri-state during close (visible / inert / gone) driven by **one** boolean gating pointer, focus and accessibility together is worth copying verbatim.

### 12. Adaptive presentation

The decision never lives in the overlay primitive. `RawTooltip`, `OverlayPortal` and `RawMenuAnchor` are platform-agnostic; every adaptive choice is made one layer up, by the design-system component, from three inputs: `defaultTargetPlatform`, `Theme.of(context).platform`, and capability bits carried in `MediaQuery`.

Observed instances:

- Hover-versus-long-press is **not a switch**. Hover is always live and the touch behaviour is a separate, orthogonal `TooltipTriggerMode` whose Material default is `longPress`; the doc is explicit that `manual` "will not prevent the tooltip from showing when the mouse cursor hovers over it" (`widgets/raw_tooltip.dart:349`). The two paths are disjoint by pointer-device class, so no adaptation logic is needed at all.
- Material `TooltipState` switches default height (24 versus 32), padding and font size on `Theme.of(context).platform` — desktop versus mobile _sizing_, not a presentation change.
- `showMenu` sets a default `semanticLabel` on Android/Fuchsia/Linux/Windows but not on iOS/macOS.
- The genuine surface swap is `SystemContextMenu`: `isSupported(context)` is `defaultTargetPlatform == iOS && (MediaQuery.maybeSupportsShowingSystemContextMenu(context) ?? false)`, with a second gate requiring a live `TextInputConnection`. When supported, the app hands an **item model** to the OS and gets a real native popup; otherwise it renders `AdaptiveTextSelectionToolbar` in-canvas. Crucially the item model is shared — `getDefaultItems` maps the generic `ContextMenuButtonItem` list, described in the code as "the single source of truth", onto `IOSSystemContextMenuItem*` values.
- `ModalBarrier` adapts its accessibility dismissibility per platform.

Not present: no popover-to-sheet collapse on compact widths, no teaching-tip concept, no keyboard-driven relocation, and no reduced-motion handling anywhere in the tooltip, menu or popup code (a grep for `disableAnimations`/`accessibleNavigation` in those files returns nothing).

**Where the behavior lives.** The component layer (`material/tooltip.dart`, `material/popup_menu.dart`, `widgets/system_context_menu.dart`, `material/adaptive_text_selection_toolbar.dart`) reading a capability bit the **engine** puts into `MediaQueryData` via `PlatformDispatcher.supportsShowingSystemContextMenu`.

**Degradation.** The lesson is the layering, not the features: the primitive stays ignorant, the capability arrives as **data** in the ambient environment, and the content model is a value type shareable across surfaces. That maps onto a capabilities value carried in the theme or environment (hover, key release, timers, viewport insets) consumed by components, with the anchored-overlay primitive never branching on backend — Android's absent hover then becomes an absent capability bit rather than a special case. Flutter's disjoint-by-device-kind trick means one component can serve several targets without a mode flag. What this subject does not supply is any guidance on popover-to-sheet, teaching tips, or reduced motion.

### 13. Accessibility

The tooltip's model is: **not a node, a description on the trigger.** `RawTooltipState.build` wraps the child in `Semantics(tooltip: semanticsTooltip)`; the overlay content contributes nothing to the semantics tree. On show, `_handleStatusChanged` fires `SemanticsService.tooltip(...)`, a one-shot announcement. `SemanticsRole.tooltip` exists in the enum but is routed to `_unimplemented` in the debug role checker:

> ```dart
> SemanticsRole.tooltip => _unimplemented,
> ```
>
> — [`packages/flutter/lib/src/semantics/semantics.dart:198`][semantics-tooltip-unimpl]

and `widgets/raw_tooltip.dart:868` carries the open TODO. At this SHA, Flutter ships no `role=tooltip` at all.

Menus **do** have roles with debug-mode structural validators: `SemanticsRole.menu` ("a menu cannot be empty"), `menuBar`, `menuItem` (which walks ancestors and errors unless a `menu`/`menuBar` is found), `menuItemCheckbox`, `menuItemRadio`; `SubmenuButton` publishes `Semantics(expanded: ...)`. `comboBox` is in the enum but unimplemented. Dialogs use `SemanticsRole.dialog`/`alertDialog`. The modal bit is `BlockSemantics` on the barrier plus `OrdinalSortKey(0.0)` on the scope and `OrdinalSortKey(1.0)` on the barrier to force reading order.

```text
tooltip: node(trigger).tooltip := message; on show emit SemanticsService.tooltip(message)
menu:    node(panel).role := menu; assert(children >= 1)
         node(item).role := menuItem; assert(ancestor role in {menu, menuBar})
         node(submenuButton).expanded := isOpen
modal:   blockSemantics(everything below); sortKey(scope) = 0, sortKey(barrier) = 1
AT tap:  on SemanticsActionEvent(tap|longPress, nodeId, viewId):
             rect := getRectOfSemanticsNodeInViewCoordinates(...)
             hit  := hitTest(globalToLocal(rect.center)); classify(hit); dispatch synthetic PointerDown
```

> [!WARNING]
> `OverlayPortal` has a documented sharp edge: the overlay child's semantics subtree is attached to the **portal**, not the `Overlay`. If the portal is scrolled out of view but kept alive by `KeepAlive`, the overlay child's semantics are dropped even though it is still visible (`widgets/overlay.dart:1833`). Separately, `widgets/tap_region.dart:235` carries a TODO admitting that `consumeOutsideTaps` cannot stop propagation of accessibility-originated taps.

**Where the behavior lives.** Split three ways: the widgets layer declares intent (`Semantics`, `SemanticsRole`, `SemanticsService`); `semantics/semantics.dart:162` validates structure in debug only; and the engine/platform bridge maps roles to VoiceOver/TalkBack/UIA/AT-SPI — **not read at this SHA**, since the sparse checkout excludes it.

**Degradation.** Flutter's own factoring answers what belongs where: the trigger-to-surface association, the expanded state on the trigger, and an announce hook on show belong to the primitive; roles and their structural invariants belong to a semantic component, which is why `RawMenuAnchor`'s doc says outright that it "does not manage semantics and focus of the menu". A terminal grid exposes nothing to a screen reader through the grid itself but everything through the emitted text — a tooltip painted as cells _is_ read by a screen reader reading the terminal, which is the opposite hazard from the web (content read twice rather than not at all). INFERENCE: modelling a tooltip as a description attached to the trigger in the annotation stream, keeping the painted surface out of any separate accessibility tree, appears to be the honest position for a cell target too. On WCAG 1.4.13, Flutter's tooltip is dismissible (Escape) and hoverable for rich tooltips only, and not persistent — `touchDelay` force-hides after 1.5 s on touch.

### 14. Animation

Flutter emits geometry metadata specifically to drive animation, by feeding the animation value **back into** the layout delegate — and derives the [transform origin](./concepts.md) from placement rather than exporting it to a styling layer.

**Algorithm.**

```text
positionDuringOpen(t), t = heightFactor in (0, 1]:
    fullH  := min(childH / t, overlayH)
    pos    := place(Size(childW, fullH))
    growsUp := pos.y + fullH <= anchorRect.centerY
    return growsUp ? (pos.x, pos.y + (fullH - childH))
                   : lerp((pos.x, anchorRect.bottom), pos, t)

item stagger: item i fades in over Interval(i*g,  i*g  + 1/2), g  = (1 - 1/2)/(n-1)
                        out    over Interval(i*g', i*g' + 1/3), g' = (1 - 1/3 - 1/3)/(n-1)

lifecycle: open  := onOpenRequested(pos, showOverlay)   // implementer calls showOverlay() then forward()
           close := onCloseRequested(hideOverlay)       // implementer reverses, then .whenComplete(hideOverlay)
```

`_Submenu.build` wraps `CustomSingleChildLayout` in an `AnimatedBuilder(animation: heightAnimation)` and passes `heightFactor` into `_MenuLayout`. Inside `getPositionForChild` the delegate reconstructs the full-open height, positions that hypothetical full-size menu, then pins the bottom edge when it grows up and lerps the top-left from `(x, anchorRect.bottom)` otherwise (`material/menu_anchor.dart:3416-3434`). Cupertino does the same with `1 / heightFactor` and a `SpringSimulation`. Item-level stagger is computed as data — per-item `Interval` curves with cached `CurvedAnimation`s. The tooltip merely exposes its raw `Animation<double>` to `tooltipBuilder(context, animation)` and does nothing else: no side or align data, no transform origin, no arrow animation; `AnimationStyle.noAnimation` turns it off. Reposition during animation is continuous, because `shouldRelayout` includes `heightFactor`, so every tick relayouts. No reduced-motion support exists in any of these files.

**Where the behavior lives.** `material/menu_anchor.dart:3416`, `:3901`, `:576`; `cupertino/menu_anchor.dart:1262`; `widgets/raw_tooltip.dart:302`. The request/commit split is declared at `widgets/raw_menu_anchor.dart:124-131`.

**Degradation.** Recomputing placement per animation tick is what an immediate-mode toolkit does anyway, so the pattern is close to free off this substrate. In whole cells the grow-up/grow-down pin becomes "reveal rows from the bottom" versus "reveal rows from the top" — a row count, not a transform — and the lerp quantises to integer rows, which is acceptable (an N-row menu has N animation steps). No timers on static HTML removes all of it, leaving an instantaneous reveal. INFERENCE: the transferable rule appears to be "the placement function takes reveal progress as an input and returns a different origin", rather than "the styling layer receives a side/align token" — Flutter never exports side or align data to a styling layer at all.

### 15. State architecture

Three architectures for three surface kinds, and the differences are principled.

**Tooltip** has no explicit state machine: the `AnimationController`'s status _is_ the state, with one `Timer?` and one `Set<int> _activeHoveringPointerDevices` beside it. All transitions are guarded by `isDismissed`/`isForwardOrCompleted`, and the global registry is mutated only from the status listener.

**Menu** is an event-driven controller over an explicit **tree**. `_RawMenuAnchorBaseMixin` holds `_parent` and a child list, discovers its parent in `didChangeDependencies` via `MenuController.maybeOf(context)?._anchor`, and re-parents on change. `MenuController` is a bare imperative handle with a single `_anchor` field and `_attach`/`_detach`, asserted 1:1. The key structural idea is the **request/commit split**:

```text
open(pos):            if (!mounted) return; if (isOpen) close()
                      parent.requestChildrenClose(); zStamp := ++counter; show(zStamp)
                      if (isRootOverlayAnchor) anchorFocus.requestFocus(); onOpen()
close(inDispose):     if (!isOpen) return; closeChildren(inDispose)
                      hideOverlay (deferred to post-frame if inside build)
                      parent.childChangedOpenState(); onClose()
handleOpenRequest(p): onOpenRequested(p, () => open(p))     // the COMMIT is a closure handed to the caller
handleCloseRequest(): onCloseRequested(close); requestChildrenClose()
```

Ordering rules are explicit and tested: parents **request** close before children, but children **commit** close before parents, pinned by a test named "onCloseRequested is called on descendants before parent". Everything is re-entrancy-hardened against the build phase: at least five places check `schedulerPhase != SchedulerPhase.persistentCallbacks` and defer to `addPostFrameCallback`, and child lists are copied (`List.of(_anchorChildren)`) before iteration because callbacks mutate them.

**Route** state is a `Route` object on a `Navigator` stack with a `Future<T?>` result. On the controlled/uncontrolled axis: `RawMenuAnchor` requires a controller (fully controlled); `MenuAnchor`/`SubmenuButton` create an internal one when none is given; `OverlayPortalController` may be shown before it is attached, stashing the z-stamp and handing it over in `_setupController`.

**Where the behavior lives.** `widgets/raw_menu_anchor.dart:462`, `:1020`; `widgets/raw_tooltip.dart:538`; `widgets/overlay.dart:1685`. Parent discovery leans on the framework kernel's `InheritedWidget` dependency propagation.

**Degradation.** The parts that survive a non-DOM, value-semantics port are the ones most worth having: the request/commit split (two function values, and the only reason animation can be layered on a primitive that knows nothing about time); parent-requests-first / children-commit-first ordering, which is a pure traversal rule; "animation status is the state", which is an enum plus a deadline; and a controller as a single handle with an explicit attach assertion. The parts that do not survive: `InheritedWidget`-based parent discovery (an explicit parent id would replace it), `setState` re-entrancy dancing around a build phase, `GlobalKey` reparenting, `Expando` caches, and the process-wide mutable statics (`_openedTooltips`, `ContextMenuController._shownInstance`, `_RenderExclusiveMouseRegion`'s two hit-test flags), which would become fields on frame or session state. INFERENCE: the density of "defer to post-frame" guards in this code reads as evidence that a retained tree with a build phase makes overlay state harder to keep consistent, which — if it generalises — is a point in favour of an immediate-mode toolkit; the claim is an inference from code shape, not a measured or sourced comparison.

### 16. Shared infrastructure

**Truly shared, and correctly so:** (1) `Overlay`/`OverlayPortal`, used by tooltip, menu, dropdown, drag avatar, text-selection toolbar and every `Route`; (2) `TapRegion`/`TapRegionSurface`, used by `RawMenuAnchor`, `CupertinoMenuAnchor`, `EditableText` and text fields, with `groupId` making a whole menu tree one region; (3) the `SingleChildLayoutDelegate` + `CustomSingleChildLayout` contract, the placement seam shared by all five surfaces; (4) `DisplayFeatureSubScreen.subScreensInBounds`/`avoidBounds` for work-area splitting; (5) `MenuController`/`RawMenuAnchor`/`RawMenuAnchorGroup` as the menu tree; (6) `DismissIntent`/`Actions` for Escape.

**What merely looks common and is deliberately apart:**

- Tooltip does **not** use `TapRegion` and does **not** use `MenuController`. It uses a global pointer route and a static list, because a tooltip must dismiss on a pointer-down that a menu would classify as "inside", and because it has no tree.
- Four positioning delegates with three different flip algorithms and divergent padding constants. The abstraction that survived is the **signature**, not the policy.
- `PopupMenuButton` is a `PopupRoute` (modal, barrier, back-button, `Future` result, closed-loop focus) while `MenuAnchor` is an `OverlayPortal` (non-modal, no barrier, no back-button, callback result, no focus trap) — two menus with opposite modality sharing nothing but the item widgets.
- Tooltip has no focus, no roles and no arrow; menus have the first two and not the third.
- `ContextMenuController` is a fourth, static-singleton mechanism sharing only `OverlayEntry`.

**The factoring Flutter arrived at, as an interface list:**

```text
TopLayer  { insert(entry); portal(anchorWidget, builder, zStamp) -> paint/hit order }
OutsideTap{ register(region, groupId); classify(hitPath) -> (inside, outside); consume? }
Placement { constraintsFor(available) -> constraints;
            positionFor(available, childSize) -> offset;
            shouldRelayout(old) -> bool }
WorkArea  { split(viewport, avoid[]) -> rect[]; closest(rect[], point) -> rect }
MenuTree  { parent, children, open/close, request/commit, root }
```

Everything else — timing, focus policy, roles, arrows, modality, adaptivity — is per-surface.

**Where the behavior lives.** All of the shared list is in the backend-neutral widgets layer, with `material/` and `cupertino/` supplying only policy.

**Degradation.** For a single-surface toolkit this is a usable answer to "what goes in one anchored-overlay primitive": a top-layer/z-stamp ordering rule, a value-typed anchor, a placement function signature `(available, childSize) -> offset`, a work-area splitter, and an outside-hit classifier over the last painted hit list. The per-surface parts that Flutter's own factoring argues against forcing into the primitive are timing (tooltip-only), focus policy (menu-only), roles (component-only), modality (route-only), and the flip policy itself — three reasonable policies coexist in one repository. Flutter's one visible regret is that the four delegates duplicate flip and clamp arithmetic with subtle divergences; a shared `flipOrShift(axis, anchorSpan, childSpan, allowedSpan, preference)` helper would have covered three of the four. See [`./proposal.md`](./proposal.md) for where that lands.

## Strengths

- Solves anchored overlays with no OS popup, no compositor layer, no z-index and no stacking context — one render tree, one clip, a derived paint order.
- `TapRegion` is a fully worked, tested outside-tap solution built from hit testing alone, with grouping, per-region consumption, route awareness and an accessibility path. It needs no pointer grab.
- Placement is genuinely value-typed and pure: `getPositionForChild(Size, Size) -> Offset` plus a field-by-field `shouldRelayout`. `positionDependentBox` is 27 lines of arithmetic that ports to integer cells with `int` substituted for `double`.
- Anchor tracking is per-frame recomputation gated on value equality of a `(childSize, paintTransform, overlaySize)` record — no observers, no polling timers, no measurement side-channels.
- The IME / soft-keyboard inset is an **input** to placement (`viewInsets.deflateRect`, `Positioned.fill(bottom: viewInsets.bottom)`) rather than something discovered.
- Ordering is a two-level rule plus a monotonic counter: bring-to-front is one increment, and an overlay can float over its owner but never over a later top-level entry, so a tooltip cannot paint over a dialog.
- The request/commit split keeps the primitive free of any notion of time while letting animation layer cleanly on top.
- The animation value is fed back into the placement delegate, so the transform origin is derived from placement rather than exported to a styling layer.
- Debug-mode structural validators for semantics roles catch accessibility-tree mistakes at development time with no runtime cost.
- The test suites cover exactly the edge cases that matter here: paint order under `GlobalKey` reparenting, zero-area anchors, internal versus ancestor scroll, hover transfer between adjacent tooltips, right- and middle-click outside taps, and route-aware outside-tap suppression.

## Weaknesses

- No safe polygon, menu-aim, pointer bridge or trajectory heuristic anywhere in the framework. Diagonal travel toward an open submenu closes it; the mitigations are zero-gap layout and an optional `hoverOpenDelay` that is a debug error at menubar level.
- Four positioning delegates, three flip algorithms, divergent viewport-padding constants. Only the signature was factored.
- `SemanticsRole.tooltip` and `SemanticsRole.comboBox` exist in the enum but are routed to `_unimplemented`; the tooltip ships with an open TODO instead of a role.
- No reduced-motion support in any overlay widget — `disableAnimations`/`accessibleNavigation` appear nowhere in `tooltip.dart`, `raw_tooltip.dart`, `menu_anchor.dart` or `popup_menu.dart`.
- `MenuAnchor`/`RawMenuAnchor`/`RawTooltip` have no integration with the Android system back button; only `PopupRoute`-based popups dismiss on back.
- Tooltip Escape handling is an ad-hoc `Focus(onKeyEvent:)` at the top of `WidgetsApp` calling a static, with its own TODO to move it into `Actions`/`Shortcuts` — so tooltips outside a `WidgetsApp` cannot be dismissed by Escape.
- Process-wide mutable statics (`RawTooltip._openedTooltips`, `ContextMenuController._shownInstance`, `OverlayPortalController._wallTime`, `_RenderExclusiveMouseRegion`'s two flags) are correct here but hostile to multi-view and to a value-semantics port.
- Pervasive `schedulerPhase != persistentCallbacks` guards with post-frame deferral — at least five in `raw_menu_anchor.dart` alone.
- `consumeOutsideTaps` cannot stop propagation of accessibility-originated taps; the code carries an explicit TODO saying a new API is needed.
- Menus close on **any** ancestor scroll, so a menu inside a scrollable pane cannot survive an incidental wheel tick.
- The `OverlayPortal` semantics subtree is attached to the portal, not the `Overlay`, so a kept-alive but scrolled-out anchor silently drops its visible overlay's semantics.

## Key design decisions and trade-offs

| Decision                                                                                                                                                                                                         | Rationale                                                                                                                                                                                                                                                                 | Trade-off                                                                                                                                                                                                                                                                                                                                                  |
| ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| The overlay child is built as a **widget** child of the anchor but re-parented as a **render** child of the `Overlay` (`OverlayPortal`), rather than being handed to the `Overlay` as a separate `OverlayEntry`. | The overlay content can depend on the same `InheritedWidget`s as the anchor (`Theme`, `DefaultTextStyle`, `Directionality`, `MediaQuery`) and cannot outlive the anchor — the two most common bugs with the raw `OverlayEntry` API.                                       | Substantially more complex: a bespoke render-object pair, an element slot type that cannot implement `operator==`, extra work during `GlobalKey` reparenting, and the documented semantics wart where a scrolled-out but visible overlay's a11y subtree is dropped. The docs advise using `OverlayEntry` when the content does not need inherited context. |
| Placement is a value-typed pure function (`SingleChildLayoutDelegate`) rather than a positioned widget, a controller method, or a constraint solver.                                                             | It makes placement testable in isolation, cacheable via a `shouldRelayout` value comparison, replaceable by callers, and independent of both the widget tree and the backend.                                                                                             | The policy is not shared: four delegates in one repository implement three flip algorithms with divergent viewport-padding constants, and only the signature was factored out. A caller writing a custom delegate gets no help with collision handling.                                                                                                    |
| Outside-tap dismissal by hit-test classification (`TapRegion`) rather than a pointer grab, an invisible full-screen scrim, or a document-level capture listener.                                                 | It composes: any number of independent light-dismiss surfaces coexist, they do not participate in gesture disambiguation, grouping makes a whole menu tree one region, and a dismissing click can still reach the widget it landed on unless `consumeOutsideTaps` is set. | It only sees pointers that hit the surface, which is why `WidgetsApp` wraps the entire app in one `TapRegionSurface`. It cannot express "block the tap" without reaching into the gesture arena, and the semantics-action path admits in a TODO that `consumeOutsideTaps` cannot stop AT-originated propagation.                                           |
| Menus open on **focus**, with hover merely requesting focus; submenus close when focus leaves the scope.                                                                                                         | One state (focus) drives keyboard, mouse and programmatic paths uniformly, so arrow-key and hover traversal cannot disagree, and no pointer-geometry heuristics are needed.                                                                                               | Focus-thrash hazards needing explicit patches: a one-frame reopen suppression after close, `onHover` instead of `onEnter` because enter fires spuriously after a scroll, `invalidateScopeData` after hover-focus, and a debug `FlutterError` banning `hoverOpenDelay` on menubar buttons. Diagonal travel toward an open submenu is simply not supported.  |
| The tooltip is a description on the **trigger's** semantics node plus a one-shot announcement — never a node of its own — and `SemanticsRole.tooltip` is left unimplemented.                                     | It works uniformly across VoiceOver, TalkBack and desktop ATs without depending on the overlay's tree position, and it makes the hover-only hazard structurally impossible for AT users, who get the text from the trigger whether or not the visual tooltip is showing.  | Tooltip content can never be interactive for AT even though rich tooltips _are_ mouse-interactive — a visible/AT split. WCAG 1.4.13 "persistent" is also violated on touch, where `touchDelay` force-hides after 1.5 s.                                                                                                                                    |
| The open/close primitive is split into **request** and **commit**, and the primitive knows nothing about animation.                                                                                              | An animated menu must show its overlay before the opening animation's first frame and hide it only after the closing animation ends; two callbacks let Material, Cupertino and third parties layer different animation regimes (curves versus springs) on one primitive.  | The primitive can no longer answer "is this menu opening, closing, or stable": `MenuController.isOpen` stays true throughout a close animation, and the docs say a parent widget must track an `AnimationController` separately. Re-entrancy also gets harder — five separate places defer work to a post-frame callback.                                  |
| Menus **close** on ancestor scroll and on view resize rather than repositioning.                                                                                                                                 | Repositioning during scroll requires continuously tracking an anchor that may leave the viewport entirely, and a menu sliding around under the cursor is worse than one that closes. Internal scroll of the menu's own panel is explicitly exempted.                      | A menu inside a scrollable pane cannot survive an incidental wheel tick; a regression test exists precisely because the first implementation closed on internal scroll too. A large menu anchored to a scrollable list is unusable if the list scrolls for any reason, including keyboard traversal.                                                       |

## Sources

Primary sources, all read at `feab40b83b8d1954106e83bb1d7b52265a41cb45`:

- Top layer and portals — [`widgets/overlay.dart`][overlay]: `OverlayChildLayoutInfo` (:39), paint order (:1427) and hit-test order (:1444), `_TheaterParentData` ordering doc (:1164), theater clip (:1531), `markNeedsLayout` suppression (:1338), z-stamp counter (:1699), `_OverlayEntryLocation` (:2152), deferred layout box (:2523, :2620), `_computeNewLayoutInfo` + `RenderFollowerLayer` assert (:2864, :2874), frame-callback recompute (:2914, :2976), semantics caveat (:1833).
- Placement — [`painting/geometry.dart:41`][geometry] (`positionDependentBox`), [`material/menu_anchor.dart:3346`][menu-anchor] (`_MenuLayout`, `getPositionForChild` :3409, animation-aware origin :3416-3434, push-not-flip :3485), [`material/popup_menu.dart:811`][popup-menu] (`_PopupMenuRouteLayout`, `_fitInsideScreen` :896), [`cupertino/menu_anchor.dart:1225`][cupertino-menu] (`_MenuLayoutDelegate`, mirror flip :1285), [`widgets/display_feature_sub_screen.dart:199`][display-feature] (`subScreensInBounds`).
- Outside taps and modality — [`widgets/tap_region.dart`][tap-region]: `RenderTapRegionSurface` (:204), semantics-action TODO (:235), `_handleSemanticsAction` (:240), `_classifyRegions` (:323), `handleEvent` (:342), `consumeOutsideTaps` (:400), `_DummyTapRecognizer` (:426), route gating (:561); [`widgets/modal_barrier.dart`][modal-barrier]: platform dismissibility (:221), `BlockSemantics` (:264), `_AnyTapGestureRecognizer` (:438).
- Tooltip — [`widgets/raw_tooltip.dart`][raw-tooltip]: `_RenderExclusiveMouseRegion` (:184), builder animation (:302), trigger-mode doc (:349), status listener (:570), show/dismiss scheduling (:586, :610), device-kind partition (:632), self-dismiss guard (:666), hovering-behaviour comment (:729), zero-delay transfer (:749), global route (:798), determinant-zero collapse (:802), overlay hover retention (:811), role TODO (:868), trigger semantics (:870); [`material/tooltip.dart`][material-tooltip]: default vertical offset (:389), default durations (:392), platform sizing (:425), `ignorePointer` split (:554).
- Menus — [`widgets/raw_menu_anchor.dart`][raw-menu-anchor]: `RawMenuOverlayInfo` (:45), animation contract (:124, :171), semantics disclaimer (:169), base mixin (:462), resize close (:512), scroll close (:556), open/close/request (:588), child-list copy (:630), outside tap (:657), focus on open (:748), scheduler-phase guard (:769), tap-region group (:846), `DismissMenuAction` (:1109); [`material/menu_anchor.dart`][menu-anchor]: item stagger (:576), inert-while-closing (:700), first/last item focus (:742, :754), item focus change (:1272), hover handling (:2183), one-frame reopen guard (:2255), submenu focus change (:2297), hover-open timer (:2338, :2349), directional focus action (:2365), `_closestScreen` (:3553), `layerLink` anchor (:3852), skip-traversal scope (:3870), `AnimatedBuilder` (:3901).
- Adaptive presentation — [`widgets/system_context_menu.dart:130`][system-context-menu] (`isSupported`, `isSupportedByField` :146, single-source-of-truth comment :162), [`widgets/media_query.dart:715`][media-query] (`supportsShowingSystemContextMenu`).
- Accessibility — [`semantics/semantics.dart:198`][semantics-tooltip-unimpl] (`SemanticsRole.tooltip => _unimplemented`), role checks at :162 and :264.
- Arrow geometry — [`cupertino/text_selection_toolbar.dart:29`][cupertino-toolbar] (`_kToolbarArrowSize`, `_isAbove` :275, `_computeChildOffset` :284, arrow-drop early return :369, tip clamp :380).
- Text-range anchors — [`widgets/text_selection_toolbar_anchors.dart:27`][toolbar-anchors] (`fromSelection`, multiline collapse :81).
- Tests relied on for behaviour — [`test/widgets/overlay_portal_test.dart:1145`][test-overlay-portal] ("adding/removing overlay child does not redirty overlay more than once", `show` brings to top :2814), [`test/widgets/overlay_layout_builder_test.dart:223`][test-layout-builder], [`test/widgets/raw_menu_anchor_test.dart:1881`][test-menu-anchor] ("Tab traversal is not handled", internal scroll :2066, close ordering :2717, anchor movement :3134), [`test/widgets/raw_tooltip_test.dart:895`][test-tooltip] (zero-delay hop, hoverable tooltip :1054), [`test/widgets/tap_region_test.dart:1030`][test-tap-region] (route-aware suppression).

Related pages in this catalog: [`./index.md`](./index.md), [`./concepts.md`](./concepts.md), [`./comparison.md`](./comparison.md), [`./features-people-forget.md`](./features-people-forget.md), [`./sparkles-baseline.md`](./sparkles-baseline.md), [`./proposal.md`](./proposal.md). Nearest neighbours by surface model: [`./gpui.md`](./gpui.md), [`./textual.md`](./textual.md), [`./imgui.md`](./imgui.md), [`./uno.md`](./uno.md); the OS-popup contrast is [`./compose.md`](./compose.md) and [`./xdg-positioner.md`](./xdg-positioner.md). Sibling research trees: [`../window-system-integration/index.md`](../window-system-integration/index.md), [`../ui-layout/index.md`](../ui-layout/index.md), [`../platform-ui-guidelines/index.md`](../platform-ui-guidelines/index.md), [`../sean-parent/index.md`](../sean-parent/index.md). Toolkit specs: [`../../specs/ui/index.md`](../../specs/ui/index.md), [`../../specs/ui/input.md`](../../specs/ui/input.md), [`../../specs/ui/containers.md`](../../specs/ui/containers.md), [`../../specs/ui/state-machines.md`](../../specs/ui/state-machines.md), [`../../specs/ui/backends.md`](../../specs/ui/backends.md), [`../../specs/ui/widgets.md`](../../specs/ui/widgets.md).

<!-- References -->

[repo]: https://github.com/flutter/flutter/tree/feab40b83b8d1954106e83bb1d7b52265a41cb45
[apidocs]: https://api.flutter.dev/
[overlay]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/packages/flutter/lib/src/widgets/overlay.dart
[overlay-defer]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/packages/flutter/lib/src/widgets/overlay.dart#L2523-L2533
[theater-parentdata]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/packages/flutter/lib/src/widgets/overlay.dart#L1164-L1175
[geometry]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/packages/flutter/lib/src/painting/geometry.dart#L41-L67
[tap-region]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/packages/flutter/lib/src/widgets/tap_region.dart
[tapregion-consume]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/packages/flutter/lib/src/widgets/tap_region.dart#L400-L407
[modal-barrier]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/packages/flutter/lib/src/widgets/modal_barrier.dart
[raw-tooltip]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/packages/flutter/lib/src/widgets/raw_tooltip.dart
[raw-menu-anchor]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/packages/flutter/lib/src/widgets/raw_menu_anchor.dart
[menu-anchor]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/packages/flutter/lib/src/material/menu_anchor.dart
[popup-menu]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/packages/flutter/lib/src/material/popup_menu.dart
[material-tooltip]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/packages/flutter/lib/src/material/tooltip.dart
[cupertino-menu]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/packages/flutter/lib/src/cupertino/menu_anchor.dart
[cupertino-toolbar]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/packages/flutter/lib/src/cupertino/text_selection_toolbar.dart
[display-feature]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/packages/flutter/lib/src/widgets/display_feature_sub_screen.dart
[toolbar-anchors]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/packages/flutter/lib/src/widgets/text_selection_toolbar_anchors.dart
[system-context-menu]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/packages/flutter/lib/src/widgets/system_context_menu.dart
[media-query]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/packages/flutter/lib/src/widgets/media_query.dart#L715
[semantics-tooltip-unimpl]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/packages/flutter/lib/src/semantics/semantics.dart#L198
[test-overlay-portal]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/packages/flutter/test/widgets/overlay_portal_test.dart#L1145
[test-layout-builder]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/packages/flutter/test/widgets/overlay_layout_builder_test.dart#L223
[test-menu-anchor]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/packages/flutter/test/widgets/raw_menu_anchor_test.dart#L1881
[test-tooltip]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/packages/flutter/test/widgets/raw_tooltip_test.dart#L895
[test-tap-region]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/packages/flutter/test/widgets/tap_region_test.dart#L1030
