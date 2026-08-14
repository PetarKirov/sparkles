# Jetpack Compose — `Popup` / `PopupPositionProvider` / `TooltipBox` / `DropdownMenu` (Kotlin, AndroidX)

Compose reduces anchored placement to one pure method over four plain values —
`calculatePosition(anchorBounds, windowSize, layoutDirection, popupContentSize) -> IntOffset`
— and then pays, three separate times, for the fields that method does not return.

| Field             | Value                                                                                                                                                  |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Language          | Kotlin (Compose Multiplatform `commonMain` with `androidMain` actuals)                                                                                 |
| License           | Apache-2.0                                                                                                                                             |
| Repository        | [androidx/androidx][repo]                                                                                                                              |
| Documentation     | [`PopupPositionProvider` API reference][docs-provider], [Menus guide][docs-menu], [Tooltips guide][docs-tooltip]                                       |
| Category          | Mobile / adaptive (Android)                                                                                                                            |
| Surface model     | OS popup — every `Popup` is a real `WindowManager` child window (`TYPE_APPLICATION_SUB_PANEL` by default)                                              |
| **Revision read** | [`268d841a45644cadf438fc335c793869728449ec`][repo-pin] (`COMPOSE = 1.13.0-alpha02`, `COMPOSE_MATERIAL3 = 1.5.0-alpha26`, `libraryversions.toml:28-29`) |

There is exactly one anchored-overlay primitive in this tree: `Popup`. Plain and rich
tooltips, dropdown menus, exposed dropdowns, right-click context menus, the text
selection context menu, the text selection drag handles and `SearchBar` are all the
same composable plus a different [placement][concepts] policy object. That makes the
subject unusually good evidence for a single `AnchoredOverlay` abstraction — with the
caveat, recorded plainly below, that the unification is subsidised by a platform
window manager that sparkles does not have.

> [!NOTE]
> This page is a source reading. Nothing here was built or executed: no Android SDK
> or Gradle run was available, so every claim about the `androidDeviceTest` suites is
> asserted by reading the test source, not by observing a run. The clone is a
> depth-1 checkout containing `compose/{ui,foundation,material3,…}` only — there is
> no history to do archaeology in, Material 2 (`compose/material`) is absent, and the
> desktop/iOS/web `actual`s for `Popup` are not present (`commonStubsMain` is
> `implementedInJetBrainsFork()`), so nothing here speaks for non-Android behaviour of
> the same API.

---

## Overview

### What it solves

Compose needs one overlay mechanism that escapes the composition's own clipping and
z-ordering, works when the host `View` is scrolled out from under it by the system,
and can be positioned by application code that has no access to windows. Its answer
splits the problem along a hard seam: _where_ is a pure value function supplied by
the caller; _what_ and _when_ are composition plus a state object; and _how it gets
on screen_ is a real `WindowManager` child window that the caller never sees.

The seam is the whole design, and it is one method on one `@Immutable` interface:

```kotlin
// compose/ui/ui/src/commonMain/kotlin/androidx/compose/ui/window/Popup.kt:86-91
public fun calculatePosition(
    anchorBounds: IntRect,
    windowSize: IntSize,
    layoutDirection: LayoutDirection,
    popupContentSize: IntSize,
): IntOffset
```

Four values in — two integer rect/size pairs, one integer size, one direction enum —
and one integer offset out. No node handle, no callback, no clipping ancestor, no
float, no scroll container. The interface's own doc comment states the intended use
of `windowSize` in exactly the terms this catalog calls constraint adjustment:

> The window size is useful in cases where the popup is meant to be positioned next
> to its anchor instead of inside of it. The size can be used to calculate available
> space around the parent to find a spot with enough clearance (e.g. when
> implementing a dropdown). Note that positioning the popup outside of the window
> bounds might prevent it from being visible.
>
> — `compose/ui/ui/src/commonMain/kotlin/androidx/compose/ui/window/Popup.kt:75-79`

Because the parameters are already reduced to comparable values before the placer
runs, every position provider in the tree is testable in a plain JUnit host test with
no device, no window and no composition. `PopupPositionProviderTest` does exactly
that for the built-in alignment provider (18 `@Test` methods = 9 alignments × LTR/RTL,
asserting exact integer offsets), and `ContextMenuPopupPositionProviderTest` does it
for the context-menu axis solver, including its off-by-one boundaries.

### Design philosophy

Three commitments run through the whole stack.

**Placement is a value function, not an object graph.** The provider receives values,
returns a value, and is annotated `@Immutable` (`Popup.kt:70-71`). Everything that
would otherwise require a live handle — the anchor's position, the viewport, the
measured content size — has been resolved by the caller-side machinery first.

**Change detection is value equality.** `updateParentBounds` recomputes the anchor
rect and re-places only when `newParentBounds != parentBounds`
(`AndroidPopup.android.kt:993`); `PopupProperties` has hand-written `equals` and the
window update short-circuits on `if (this.properties == properties) return` (`:903`);
and because `scrimAlpha`'s "unset" sentinel is `NaN`, the equality uses
`equalsIncludingNaN` (`:430`) so a default-constructed properties value still compares
equal to itself.

**The primitive never closes itself.** `onDismissRequest` is advisory; the caller owns
the open/closed state. That single decision is why `Popup` can serve an animated menu
that must stay composed through its exit transition and a tooltip whose visibility is
a suspended coroutine, without knowing about either.

> [!IMPORTANT]
> The `@Immutable` promise on `PopupPositionProvider` is unenforced documentation. At
> least three in-tree implementations are stateful: `DropdownMenuPositionProvider`
> writes `transformOrigin` from inside `calculatePosition`
> (`internal/MenuPosition.kt:288`, `:387`), `HandlePositionProvider` caches
> `prevPosition` (`SelectionHandles.kt:113-133`), and
> `MaintainWindowPositionPopupPositionProvider` memoizes its last result
> (`DefaultTextContextMenuDropdownProvider.android.kt:193`).

---

## How it works

### `alignPopupAxis` — point-anchored placement, one axis, four integers

The context-menu solver is the cleanest placement code in the subject: one axis, four
mutually exclusive cases, and RTL folded into a single boolean that every helper
mirrors by calling itself with the negation.

```kotlin
// compose/foundation/foundation/src/commonMain/kotlin/androidx/compose/foundation/contextmenu/ContextMenuPopupPositionProvider.kt:107-120
internal fun alignPopupAxis(
    position: Int,
    popupLength: Int,
    windowLength: Int,
    closeAffinity: Boolean = true,
): Int =
    when {
        popupLength >= windowLength -> alignStartEdges(popupLength, windowLength, closeAffinity)
        popupFitsBetweenPositionAndEndEdge(position, popupLength, windowLength, closeAffinity) ->
            alignPopupStartEdgeToPosition(position, popupLength, closeAffinity)
        popupFitsBetweenPositionAndStartEdge(position, popupLength, windowLength, closeAffinity) ->
            alignPopupEndEdgeToPosition(position, popupLength, closeAffinity)
        else -> alignEndEdges(popupLength, windowLength, closeAffinity)
    }
```

Read as a fallback ladder it is: too big to fit at all → pin the start edge; fits
after the point → start-align to the point; fits before the point → end-align to the
point; otherwise → pin the end edge. The tests pin the branch boundaries exactly —
with `windowLength = 100` and `popupLength = 25`, `position = 74` yields `74` and
`position = 75` yields `50` (`ContextMenuPopupPositionProviderTest.kt:176-186`) — plus
all ten close/far-affinity branches at `:119-160`.

### Candidate-list first fit with a margin inset and a terminal clamp

The menu solver is the general form. Each axis gets an ordered `IntList` of candidate
coordinates; the first candidate that fits inside the margined window wins; if none
fit, the last candidate is not tested but repaired.

```kotlin
// compose/material3/material3/src/commonMain/kotlin/androidx/compose/material3/internal/MenuPosition.kt:332-358
var x = 0
for (index in xCandidates.indices) {
    val xCandidate = xCandidates[index] + contentOffsetX
    if (
        xCandidate >= horizontalMargin &&
            xCandidate + popupContentSize.width <= windowSize.width - horizontalMargin
    ) {
        x = xCandidate
        break
    }
    if (index == xCandidates.lastIndex) {
        x =
            if (popupContentSize.width >= windowSize.width - 2 * horizontalMargin) {
                Alignment.CenterHorizontally.align(
                    size = popupContentSize.width,
                    space = windowSize.width,
                    layoutDirection = layoutDirection,
                )
            } else {
                xCandidate.coerceIn(
                    horizontalMargin,
                    windowSize.width - horizontalMargin - popupContentSize.width,
                )
            }
        break
    }
}
```

Four properties are worth naming because they are the portable part of this subject.
The user's content offset is added _before_ the fit test, so a nudge can itself cause
a flip. The fit test is a margin-inset containment test, not a scored overflow — no
candidate is ever ranked, first fit wins. The axes are computed by two structurally
identical loops that never consult each other, so there is no notion of "this x is
only valid with that y". And the degenerate branch does not pin an edge: an overlay
wider than the margined window is **centred in the unmargined window**, which is a
different last-resort policy from the start-edge pinning most in-canvas subjects use.

### Alignment-pair placement — one enum used twice

The only provider the primitive itself ships expresses "align this point of the popup
to that point of the anchor" with a single `Alignment` value applied twice, exploiting
the fact that aligning a zero-size child turns an alignment enum into a
fraction-of-span function:

```kotlin
// compose/ui/ui/src/commonMain/kotlin/androidx/compose/ui/window/Popup.kt:103-116
val anchorAlignmentPoint = alignment.align(IntSize.Zero, anchorBounds.size, layoutDirection)
// Note the negative sign. Popup alignment point contributes negative offset.
val popupAlignmentPoint = -alignment.align(IntSize.Zero, popupContentSize, layoutDirection)
val resolvedUserOffset =
    IntOffset(offset.x * (if (layoutDirection == LayoutDirection.Ltr) 1 else -1), offset.y)

return anchorBounds.topLeft + anchorAlignmentPoint + popupAlignmentPoint + resolvedUserOffset
```

Nine placements times two directions come from that one expression, and the integer
division in `align` is the tie-breaking the host tests encode.

### The two-pass measure-then-place protocol

Because `calculatePosition` needs `popupContentSize`, the popup must be measured
before it can be positioned. Compose resolves the chicken-and-egg by rendering the
first frame fully transparent:

```kotlin
// compose/ui/ui/src/androidMain/kotlin/androidx/compose/ui/window/AndroidPopup.android.kt:535-540
.onSizeChanged {
    popupContentSize = it
    updatePosition()
}
// Hide the popup while we can't position it correctly
.alpha(if (canCalculatePosition) 1f else 0f)
```

`canCalculatePosition` is a `derivedStateOf` requiring both the parent coordinates and
the content size to be known (`:728-730`).

### Anchor tracking is a union of three mechanisms

Positioning is re-run from three independent sources, and the source comment is candid
about why the obvious one is not enough:

```kotlin
// compose/ui/ui/src/androidMain/kotlin/androidx/compose/ui/window/AndroidPopup.android.kt:580-582
// The parent's bounds can change on any frame without onGloballyPositioned being called, if
// e.g. the soft keyboard changes visibility. For that reason, we need to check if we've moved
// on every frame.
```

So: (1) `onGloballyPositioned` on a zero-size sibling `Layout`, documented as
best-effort; (2) an infinite `withInfiniteAnimationFrameNanos` loop calling
`pollForLocationOnScreenChange()` (`:589`, `:955`), which compares a reused two-int
array before doing any real work; (3) a `SnapshotStateObserver` wrapped around the
`calculatePosition` call (`:1012`), so any snapshot state the _provider_ reads becomes
a positioning dependency.

### The tooltip lease

There is no registry of open tooltips and no group id. Mutual exclusion _is_ the
singleton, and cancellation _is_ the dismissal:

```kotlin
// compose/material3/material3/src/commonMain/kotlin/androidx/compose/material3/internal/BasicTooltip.kt:428-440
mutatorMutex.mutate(mutatePriority) {
    try {
        if (isPersistent || mutatePriority == MutatePriority.UserInput) {
            cancellableShow()
        } else {
            withTimeout(BasicTooltipDefaults.TooltipDuration) { cancellableShow() }
        }
    } finally {
        // timeout or cancellation has occurred
        // and we close out the current tooltip.
        isVisible = false
    }
}
```

`mutatorMutex` defaults to `BasicTooltipDefaults.GlobalMutatorMutex` (`:459`), a
process-wide instance. Showing tooltip B cancels tooltip A's coroutine, whose
`finally` clears A's visibility. Passing a local `MutatorMutex` is the documented
opt-out, and the two behaviours are pinned by paired tests
(`TooltipTest.kt:808` `tooltipSync_global_onlyOneVisible`, `:872`
`tooltipSync_local_bothVisible`).

---

## The analysis spine

### 1. Anchor model

Internally the [anchor rect][concepts] is always reduced to one `IntRect` —
`IntRect(layoutPosition, layoutSize)` built in `updateParentBounds`
(`AndroidPopup.android.kt:972`) — before any placement code runs. Every richer anchor
kind is collapsed upstream rather than taught to the placer:

- **Point / cursor.** `ContextMenuPopupPositionProvider` still receives a rect and adds
  a local offset: the axis solver is called with `anchorBounds.left + anchorPosition.x`
  (`ContextMenuPopupPositionProvider.kt`), so the "point" is a latched offset carried
  by the provider, not a second anchor kind.
- **Text range.** `getSelectedRegionRect` (`SelectionManager.kt:1635`) unions a
  selection to one rect: for the first and last selectable only, it takes the bounding
  boxes of the range endpoints, min/max's them into a local rect, maps both corners into
  container space, min/max's again, intersects with `visibleBounds()`, rejects a
  negative-extent result, translates to root, and extends the bottom by
  `HandleHeight * 4` so the toolbar clears the drag handles.
- **Moving anchor.** A selection handle's anchor is an `OffsetProvider` closure re-read
  on each call (`SelectionHandles.kt:108`), with the handles themselves rendered as
  `Popup`s (`AndroidSelectionHandles.android.kt:225`).
- **Detached trigger vs anchor.** Supported by construction: `TooltipBox` keeps
  `anchorBounds: MutableState<LayoutCoordinates?>` separate from the trigger modifiers,
  and `MaintainWindowPositionPopupPositionProvider` deliberately ignores `anchorBounds`
  changes so the text context menu does not slide around while the text scrolls under it.

**Algorithm.** `anchor = IntRect(round(coords.positionInWindow() or coords.positionOnScreen()), coords.size)`,
recomputed only when the rect value changed (`AndroidPopup.android.kt:993`). The
`fastRoundToInt` at that boundary is the single float→int conversion in the whole
placement path; everything downstream is integral.

**Where the behavior lives.** Library. The reduction from a `LayoutCoordinates` node
handle to a comparable rect happens in exactly one place (`PopupLayout.updateParentBounds`),
and the whole public placement API sits downstream of it. The platform contributes the
coordinates, not the model.

> [!WARNING]
> The coordinate space of `anchorBounds` depends on nesting — `positionOnScreen()` when
> the popup is inside another popup, `positionInWindow()` otherwise
> (`AndroidPopup.android.kt:976-989`, each branch pinned by its own device test:
> `PopupTest.kt:915` and `:965`). `windowSize`, however, always comes from
> `getDisplayBounds()` (`:1121`). The mismatch is acknowledged in-tree as
> `TODO(b/256233441)` at `ContextMenuPopupPositionProvider.kt:61`, and
> `ExposedDropdownMenu` papers over it by hand — see dimension 3.

**Degradation.** This dimension survives every axis intact. With no OS window the
anchor a placer sees is already an integer rect; in sparkles a widget key resolved to
its laid-out cell rect gives the same value with no observer. Multi-rect text anchors
must be pre-unioned the same way, because this codebase never hands a placer more than
one rect. A moving anchor needs a per-frame re-place, which is what Compose does
anyway. Value-equality change detection needs no capability at all.

### 2. Placement model

There is no "side" concept in the primitive — only an offset. Sides exist only in
userland providers, and this tree contains three vocabularies for them that share no
code:

| Vocabulary              | Shape                                                                    | Used by                                                        |
| ----------------------- | ------------------------------------------------------------------------ | -------------------------------------------------------------- |
| `Alignment` pairs       | anchor alignment point + (−popup alignment point) + mirrored user offset | the built-in `AlignmentOffsetPositionProvider` (`Popup.kt:94`) |
| `MenuAnchorPosition`    | two lambdas producing candidate coordinate lists per axis                | `DropdownMenu`, `ExposedDropdownMenu` (`Menu.kt:1407`)         |
| `TooltipAnchorPosition` | a `@JvmInline value class` over `Int` 1..6, dispatched by `when`         | `TooltipBox` (`Tooltip.kt:809`)                                |

The candidate lists are built from named single-axis atoms in `MenuPosition`
(`internal/MenuPosition.kt:50`): `startToAnchorStart` (`:79`), `endToAnchorEnd`,
`startToAnchorEnd`, `endToAnchorStart`, `leftToWindowLeft` (`:107`),
`rightToWindowRight`, `topToAnchorBottom` (`:115`), `bottomToAnchorTop`,
`topToAnchorTop`, `bottomToAnchorBottom`, `centerToAnchorTop` (`:143`),
`topToWindowTop`, `bottomToWindowBottom`. Adding a placement policy is therefore a list
literal, and `MenuAnchorPosition.Custom(xCandidates, yCandidates)` makes that extension
public.

**Algorithm.** For `MenuAnchorPosition.Below` the ladders are:

```text
y = [ topToAnchorBottom,              # preferred: under the anchor
      bottomToAnchorTop,              # flip: above the anchor
      centerToAnchorTop,              # compromise: partial overlap
      anchorCentreInTopHalf ? topToWindowTop : bottomToWindowBottom ]

x = [ startToAnchorStart,
      endToAnchorEnd,
      anchorCentreInLeftHalf ? leftToWindowLeft : rightToWindowRight ]
```

Flip, then a deliberate partial-overlap compromise, then pin to whichever window edge
is nearer the anchor's centre. Both axes then run the first-fit-with-terminal-repair
loop shown above, independently.

Logical and physical directions both exist and are distinguished on purpose:
`Start`/`End` resolve through `layoutDirection`, while `Left`/`Right` deliberately do
not (the window-edge atoms use `AbsoluteAlignment`).

**Viewport padding** is two constants, `MenuVerticalMargin` (48.dp, `Menu.kt:2168`) and
`MenuHorizontalMargin` (8.dp, `:2216`) — note these are per-**axis**, not per-side, so
an asymmetric inset is inexpressible in this vocabulary. Tooltips use a separate
`SpacingBetweenTooltipAndAnchor` (4.dp, `Tooltip.kt:1450`) and clamp with
`coerceIn(0, maxOf(0, window − size))`. Custom clipping boundaries do not exist:
`windowSize` is the only boundary a provider is given, and multi-monitor is absent
because `getDisplayBounds()` returns one rect.

**Where the behavior lives.** Entirely library code, and almost entirely in the
caller's provider. `compose-ui` contributes only the alignment default; material3 owns
menus and tooltips; foundation owns context menus and selection handles.

**Degradation.** The most portable dimension in the subject: integer arithmetic over
four values, with no hover, no script, no window and no sub-cell precision involved
anywhere. A cell-grid port is the same candidate list of integer coordinates per axis,
the same first-fit, the same clamp. The one thing that does not port cleanly is the
per-axis margin, which cannot express a bottom-only inset such as an Android soft
keyboard — a limitation this tree runs into for real, below.

### 3. Collision and geometry engine

There is no collision engine. Overflow detection is a per-axis containment test inlined
into each provider. There is no clipping-ancestor discovery, no scroll-container walk,
no transform or zoom handling in the placement path, and no [top layer][concepts] —
because the popup is a real OS window and escapes all in-app clipping for free.

The boundary value itself comes from `getDisplayBounds()`
(`AndroidPopup.android.kt:1121`), which returns the window's _visible_ display frame
when `clippingEnabled` (the default) and the full window/display bounds when not.
Tooltips deliberately pass `clippingEnabled = false` so a tooltip window may extend past
the screen — pinned by `PopupLayoutTest.kt:320`
`unclippedPopup_usesFullWindowBounds_forPositioning`.

**Algorithm.** Per frame: if not attached, return; `getLocationOnScreen(buf)`; if the
two-int buffer changed, `updateParentBounds()`; that recomputes the anchor rect and
calls `updatePosition()` only if the rect value changed; `updatePosition` observes
snapshot reads while calling `calculatePosition`, writes `params.x`/`params.y`, and
pushes the result to the `WindowManager`. Resizing is symmetric: `internalOnLayout`
writes the measured child size back into the `LayoutParams`, and when
`usePlatformDefaultWidth` is false the popup re-measures against full display bounds
with `AT_MOST` specs instead of the platform's narrower default (`:825`).

**Where the behavior lives.** Split three ways. Overflow arithmetic: library provider
code. Clipping escape, z-order and the actual move: the platform compositor. Change
detection: library (`pollForLocationOnScreenChange` plus the snapshot observer).

> [!WARNING]
> The soft-keyboard inset is not the boundary's problem here — it is the boundary
> _value's_ problem. `windowSize` **is** an explicit parameter of `calculatePosition`,
> so the solver never queries anything; what fails is (a) the value the adapter
> supplies, which omits insets in the nested case (`b/256233441`), and (b)
> invalidation, since nothing re-runs placement when the IME appears
> (`b/326394521`). The tree carries three separate repairs for one input:
> per-frame `getLocationOnScreen` polling; a `neverEqualPolicy` `keyboardSignalState`
> that a window-bounds listener pokes and the provider reads purely for the dependency
> (`ExposedDropdownMenu.kt:359`, read at `:830` with the comment "Read the state
> because we want any changes to the state to trigger recalculation"); and a
> hand-applied `windowSize.height + topWindowInsets` inside the provider itself
> (`:834-835`, commented "Popup fails to account for window insets so we do it here
> instead"). Receiving the boundary as a parameter is necessary; it was not sufficient.

**Degradation.** The clipping-escape half is pure OS and does not generalise: a
single-surface toolkit clips at the surface edge, so Compose's `clippingEnabled = false`
tooltip behaviour is unreproducible and should be dropped rather than emulated. The
arithmetic half generalises completely. The tracking triad has no analogue either, but
for a different reason — cross-surface tracking is _absent_ in a one-surface toolkit
rather than replaced by something: there is no second window whose screen position can
drift. What remains is the snapshot-observer trick, whose value-semantics equivalent is
to make the placer a pure function of an explicit inputs struct and compare the struct,
which removes the need for both the poll and the observer. That `place()` is testable
with no tracking machinery at all is exactly what `PopupPositionProviderTest`
demonstrates.

### 4. Arrow / caret geometry

The most instructive dimension in this subject, because the caret is not data — it is a
`Shape` unioned into the tooltip's container outline. `TooltipCaretShape.createOutline`
(`Tooltip.kt:1372`) builds the container path, builds the caret path, applies a
`Matrix`, and does `Path.op(..., PathOperation.Union)`. The default caret is a 16×8dp
triangle centred on the origin (`moveTo(0,0)` → `(w/2,0)` → `(0,h)` → `(−w/2,0)`,
`:1345`), so the matrix translation lands its tip.

The matrix is computed in `Modifier.layoutCaret` (`:1195`), inside an
`onLayoutRectChanged(throttleMillis = 0, debounceMillis = 0)` callback — that is, one
frame after placement, from measured screen coordinates. Because `calculatePosition`
returned no side, the caret layer recovers it twice over, by two different means:

```kotlin
// compose/material3/material3/src/commonMain/kotlin/androidx/compose/material3/Tooltip.kt:1215-1216
val isBelow = tooltipScreenPos.top > anchorScreenPos.y
val isToTheRight = tooltipScreenPos.left > anchorScreenPos.x
```

and, three lines later, `if (positionProvider is TooltipPositionProviderImpl)` (`:1219`)
— a downcast to a private class to read `.type`, i.e. the _requested_ side, alongside
the coordinate comparison that yields the _resolved_ one.

**Algorithm.** `caretY = sidePlacement ? tooltipHeight / 2 : (isBelow ? 0 : tooltipHeight)`;
`caretX` per a four-case function; `matrix = translate(caretX, caretY)` then
`rotateZ(±90)` for side placements or `rotateX(180)` for below; outline =
`union(containerShape, matrix * caretShape)`. The corner constraint lives in `caretX`
(`:1166-1192`), which is a second, independent implementation of clamping the placer
already did: tooltip wider than the screen → anchor midpoint; would collide left →
`anchorMid + max(tooltipWidth − screenWidthPx, −anchorLeft)`; would collide right →
`anchorMid + min(tooltipWidth − anchorRight, 0)`; else `tooltipWidth / 2`.

> [!WARNING]
> The two implementations disagree, and the mechanism is arithmetic, not a
> boundary mismatch: both `caretX` and the tooltip provider read the same extent
> (`LocalWindowInfo.current.containerSize`, `Tooltip.kt:751` and `:1211-1212`), and
> `TooltipPositionProviderImpl.calculatePosition` in fact ignores the `windowSize`
> argument it is handed in favour of that field (`:901-932`). In the left-collision
> branch `caretX` under-shoots the tooltip-local anchor centre by
> `min(anchorLeft, W − w)` relative to what `abovePositioning` actually did — that
> function pins `x = 0` in this case (`:991-993`) — so
> `caretX(200f, 1000, Rect(left = 10f, right = 30f))` returns `10` where `20` is
> correct. The right-collision branch diverges by `W − anchorRight` on the same
> pattern. The full-width branch has a dedicated regression test
> (`TooltipTest.kt:1190` `fullWidthTooltipCaret_xPositioning`); the collision branches
> do not.

Arrow size does not feed the placement offset: `SpacingBetweenTooltipAndAnchor` (4.dp)
is independent of `caretSize` (8.dp tall), so the default caret overlaps the gap. Menus
and context menus have no arrow at all, and the caret machinery is not offered to them.

**Where the behavior lives.** Entirely in material3 component code (`Tooltip.kt`); the
primitive knows nothing about arrows, and the path union executes on the graphics layer.

**Degradation.** In an integer-cell world the arrow is one glyph in one cell on one
edge of the box, so everything Compose does with matrices collapses to (side, index
along that edge) — two integers. The lesson is negative and strong: because `place()`
returned no side, a triangle cost a downcast, an extra frame and a duplicated clamp
that does not agree with the original. Under no-script static HTML the border character
must be chosen at emit time, with no later measurement pass available at all, so a
placement result carrying the side is mandatory there rather than merely convenient.

### 5. Trigger semantics

Triggers are modifiers on the anchor and are never part of the popup.
`BasicTooltipBox.handleGestures` (`internal/BasicTooltip.kt:213`) installs **two**
independent `pointerInput` nodes on the same `Box`:

- one on `PointerEventPass.Initial`, gated on `awaitFirstDown(pass).type` being `Touch`
  or `Stylus` (`:224`), running a long-press timer;
- one on `PointerEventPass.Main`, gated on the change's type being `Mouse`, reacting to
  `PointerEventType.Enter` (`:271`) and `Exit` (`:274`).

Keyboard focus is a third trigger (`keyboardBehavior`, `:305`, showing on focus at
`:319`), Escape and Tab are handled in `onPreviewKeyEvent`, and assistive technologies
get a fourth via an `onLongClick` semantics action with a localized label (`:295`).
Context menus use `Modifier.pointerInput(ContextMenuKey) { onRightClickDown(...) }`,
where `ContextMenuKey` is an explicit non-`Unit` key object carrying the comment
"Unique key to avoid `Unit` clashes in `pointerInput`" (`ContextMenuGestures.kt:26`).
`DropdownMenu` has no built-in trigger at all — `expanded` is a caller-owned `Boolean`.

**Algorithm.** There is no arbitration inside any component. Every trigger funnels into
`state.show(priority)` and arbitration is delegated to `MutatorMutex`
(`MutatorMutex.kt`), whose `Mutator.canInterrupt(other) = priority >= other.priority`
(`:82`) is checked inside a CAS loop in `tryMutateOrCancel` (`:90`): a claimant with
equal-or-higher priority atomically replaces the incumbent and cancels its job, and a
lower-priority claimant throws `CancellationException` immediately. The ladder is a
three-value enum, `Default < UserInput < PreventUserInput` (`:34-53`).

> [!NOTE]
> The ladder is real, but its level assignment is not consistent even inside this tree.
> In material3, long press claims `PreventUserInput` (`internal/BasicTooltip.kt:238`),
> mouse `Enter` claims `UserInput` (`:272`), and the accessibility `onLongClick` action
> calls bare `show()`, i.e. `Default` (`:293-298`). In compose-foundation's copy, the
> touch long press claims `UserInput` (`BasicTooltip.kt:205`) — the same rung as that
> file's own hover open (`:228`). Long press therefore sits on three different rungs
> depending on which route reached it.

**Where the behavior lives.** Library throughout: foundation gesture detectors plus
material3 component modifiers, with the priority ladder living in
`androidx.compose.foundation.MutatorMutex`, a general-purpose primitive that is not
specific to overlays.

**Degradation.** With hover but no key release, the mouse `Enter`/`Exit` path is fine
and Escape is fine (material3's own tooltip Escape handler is `KeyDown`-only, `:485`);
what does not survive is any keyboard press-and-hold. The touch long-press path needs a
timed up-or-cancel and is dead on a target with no gesture recognizer. On Android only
the long-press path lives, and the hover branch simply never fires — no code changes,
because the gate is on the event, not on the build. Under static HTML only `:hover` and
`:focus-within` remain. The transferable idea is the ladder itself: three values plus
"later, equal-or-higher wins; lower loses immediately" removes every trigger race with
no timers — provided the level assignment is decided once rather than per route.

### 6. Timing

The striking finding here is an absence. There is no initial hover delay, no close
delay, no [warm-up][concepts], no [cool-down][concepts] / skip-delay window, and no
toolbar-neighbour traversal anywhere in the tooltip files: a grep for `delay(` across
`Tooltip.kt`, `internal/BasicTooltip.kt` and `foundation/BasicTooltip.kt` returns
nothing. Mouse `Enter` calls `show(UserInput)` immediately, and `Exit` dismisses
immediately unless `isPersistent`.

The only timing constant is `BasicTooltipDefaults.TooltipDuration = 1500L`
(`internal/BasicTooltip.kt:465`), and it is a **maximum display duration**, not a delay
— applied via `withTimeout` and skipped entirely when `isPersistent` or when the
priority is `UserInput` (`:430-433`). The practical consequence is a clean split: hover
tooltips never auto-hide, and only non-persistent touch/keyboard-triggered tooltips do.

**Algorithm.** The state machine this implies is two states plus one lease plus one
optional deadline. States are `{Hidden, Shown}`; every show is a cancellable task
holding the global lease; the transitions are `(trigger, priority) → try-acquire-or-lose`;
and leaving `Shown` is task cancellation from any of {a higher-priority show elsewhere,
trigger-off, timeout, dispose}. There are no timers in the machine itself — the only
timer is the optional `withTimeout` wrapper around the shown task.

Long-press timing uses the platform's `viewConfiguration.longPressTimeoutMillis` via
`withTimeout` around `waitForUpOrCancellation` (`:230`), catching
`PointerEventTimeoutCancellationException` as the **success** signal: the timeout _is_
the gesture. Re-entry is handled with a `MutableStateFlow<Boolean>` because, as the
comment says, the long press may finish before or after the show.

**Where the behavior lives.** Library, in the state object (`TooltipStateImpl` /
`BasicTooltipStateImpl`) plus `MutatorMutex`; only the long-press threshold comes from
the platform `ViewConfiguration`.

> [!NOTE]
> `TooltipFadeIn` is not a production symbol at this revision. The only match is
> `TooltipFadeInDuration = 300L`, a private constant in the test file
> (`TooltipTest.kt:1229`) whose comment says the value is arbitrary "because we use
> springs to animate". Production enter/exit uses motion-scheme springs with no nominal
> duration.

**Degradation.** Static HTML loses both the max-display timeout and the long-press
threshold and keeps only `:hover` — which is what Compose's mouse behaviour already is,
so almost nothing is lost. In a frame-loop target the lease-plus-deadline model is an
integer frame or millisecond deadline compared once per frame; no coroutines are
implied by the policy, only by this implementation. The whole machine is three values
(state, lease holder, deadline), which is assertable on a recording canvas in a way a
suspended coroutine is not.

### 7. Interactive hover / travel

There is no [safe polygon][concepts], no menu-aim, no trajectory heuristic, no
interactive border and no debounce anywhere in this tree. Compose solves
trigger→content travel **structurally** rather than geometrically, and it does so twice.

For tooltips, the popup is a sibling inside the same `Box` as the anchor but hover is
read only from the anchor, and a persistent tooltip simply does not dismiss on `Exit`
(`internal/BasicTooltip.kt:274-275`), so travel is a non-event.

For cascading submenus, the parent item and the submenu **share one
`MutableInteractionSource`**: the sample creates it per item
(`MenuSamples.kt:340-341`), passes it to the item (`:344`), opens the submenu on
`expanded = itemChecked || itemHovered` (`:373`) and hands the same source to the
submenu builder (`:377`); `DropdownMenuGroup` then applies
`Modifier.hoverable(interactionSource = interactionSource)` to the submenu container
(`Menu.kt:294`). `collectIsHoveredAsState()` therefore stays true while the pointer is
anywhere in either surface. The submenu opens with `focusable = false` so it does not
steal focus from the parent item.

**Algorithm.** `hovered = OR over all nodes given the same InteractionSource`;
`submenuOpen = parentItemHovered || parentItemToggled`. No timers, no polygons, no
tolerance regions.

**Where the behavior lives.** Sample plus material3 component code (the
external-`interactionSource` parameter); the `InteractionSource` abstraction itself is
foundation's.

**Degradation.** The shared-source bridge costs zero cells: no corridor, no tolerance
band, no diagonal region. A geometric safe polygon on a cell grid would need at least a
one-cell tolerance band and would still be wrong on the diagonal at cell resolution;
this subject is evidence that the geometric machinery is avoidable when the two
surfaces can share a hover token. With no hover at all, the same expression degrades to
tap-to-open/tap-to-close, because `itemChecked` is already the other half of the `||`.
The transposition for a cell toolkit is to model "hovered" as a set of widget ids
sharing one hover token, evaluated over the hit list, rather than as a region.

### 8. Dismissal

The primitive owns exactly three dismissal paths and delegates everything else.

1. **Outside touch.** `onTouchEvent` (`AndroidPopup.android.kt:1044`) fires
   `onDismissRequest` on `ACTION_DOWN` whose coordinates fall outside
   `[0,width) × [0,height)`, or on `ACTION_OUTSIDE` — which arrives at all only because
   every popup sets `FLAG_WATCH_OUTSIDE_TOUCH` as a base flag (`:614`). Note it is
   **down**, not up or click, so the whole test needs one event and no gesture state.
2. **Back / Escape key.** `dispatchKeyEvent` (`:855`) starts tracking on `ACTION_DOWN`
   with `repeatCount == 0` and dismisses only on `ACTION_UP` while
   `state.isTracking(event) && !event.isCanceled` — a full press-and-release protocol
   borrowed from `PopupWindow`, with `KEYCODE_BACK` and `KEYCODE_ESCAPE` treated
   identically.
3. **Predictive back.** On API 33+, an `OnBackInvokedCallback` registered at
   `PRIORITY_OVERLAY` (`:1144`).

Both key paths require `focusable = true`, which the properties documentation states
outright ("if the popup is not focusable then this property does nothing").

Everything else belongs to the caller or to the component. Anchor removal dismisses
because the popup is composed inside the anchor's composition and `onDispose` calls
`dismiss() → removeViewImmediate` — with `doesNotCrashWhenAnchorDetachedFirst`
(`PopupTest.kt:600`) as the named regression test. Scrolling does not dismiss, and for
the text context menu it does not even move the overlay. Focus-out dismisses tooltips
only, guarded by a latch so a tooltip that never held keyboard focus is not dismissed by
an unrelated blur. Escape dismisses a tooltip through a different mechanism entirely —
`onPreviewKeyEvent` on `KeyDown` (`internal/BasicTooltip.kt:485`).

**Algorithm.**
`outsideDismiss = (action == DOWN && !inBounds(x, y)) || action == ACTION_OUTSIDE → onDismissRequest()`;
`backOrEscape = down starts tracking; up while still tracking and not cancelled → onDismissRequest()`.
`onDismissRequest` is a request: the primitive never closes itself.

**Where the behavior lives.** `compose-ui`'s `PopupLayout`, riding on platform window
flags (`FLAG_WATCH_OUTSIDE_TOUCH`, `KeyDispatcherState`, `OnBackInvokedDispatcher`).
Tooltip-specific dismissal is material3's.

**Degradation.** With no key release the press-and-release Escape protocol is
unimplementable and must collapse to dismiss-on-Escape-down — which is what this
codebase's own tooltip handler already does, so the down-only form is demonstrably
acceptable. On Android, `dismissOnBackPress` maps to the system back key directly. With
no pointer grab, the `ACTION_OUTSIDE` half is unavailable: outside-clicks are detectable
only for events landing inside the one surface, so "clicked outside the popup but inside
the app" works and "clicked outside the app" does not — the same limitation a
non-focusable Compose popup has when another app is on top. The down-not-up choice ports
well, because it needs a single event and no gesture state, which suits a hit-list
router.

### 9. Focus

Focus is one boolean — `PopupProperties.focusable`, implemented as the absence of
`WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE` (`AndroidPopup.android.kt:397`,
assembled in `createFlags` at `:616`). There is no [focus scope][concepts] trap, no
initial-focus API and no restoration API in the primitive, because with a separate OS
window focus containment belongs to the window manager.

The defaults differ per component, and the differences _are_ the tooltip ≠ menu ≠
dialog distinction:

| Surface               | Focus policy                                                                                                                                                                                        |
| --------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Popup`               | `focusable = false`                                                                                                                                                                                 |
| Tooltip               | `focusable = false`, forced true when the tooltip has an action **and** (a touch-exploration/switch-access service is running **or** the user Tab'd toward it) — `internal/BasicTooltip.kt:110-120` |
| Context menu          | `PopupProperties(focusable = true)` (`ContextMenuUi.kt:92`)                                                                                                                                         |
| `ExposedDropdownMenu` | flags computed dynamically (`ExposedDropdownMenu.android.kt:55-79`)                                                                                                                                 |

The exposed-dropdown case is the most instructive: it always sets
`FLAG_ALT_FOCUSABLE_IM`; it adds `FLAG_NOT_TOUCH_MODAL` only when no accessibility
service is running, with the comment "In order for a11y focus to jump to the menu when
opened, it needs to be focusable and touch modal"; and it adds `FLAG_NOT_FOCUSABLE` when
the anchor is an editable text field, commented "If typing on the IME is required, the
menu should not be focusable in order to prevent stealing focus from the input method"
(`:70-76`). That is four flag combinations expressing what one boolean could not.

Tab-into-tooltip is bespoke: `onPreviewKeyEvent` intercepts Tab while a tooltip with an
action is visible, sets `forceKeyboardFocusable = true` and **returns true to swallow
that Tab**, so the next Tab lands inside the now-focusable popup; Escape resets the
latch, with the source comment "Make sure keyboard focus is not trapped once tooltip is
dismissed" (`internal/BasicTooltip.kt:327-344`). Pointer- versus keyboard-opened is a
real distinction here and is encoded as priority: keyboard focus opens with
`PreventUserInput`, hover with `UserInput`.

**Algorithm.** `focusable = !(flags & FLAG_NOT_FOCUSABLE)`;
`effectiveFocusable = declared || (hasAction && (a11yServiceRunning || tabbedToward))`.

**Where the behavior lives.** Platform (window-manager flags) for the mechanism;
library (material3) for the policy, including the accessibility-service query.

**Degradation.** With no OS window there is no free containment, so a single-surface
toolkit must implement focus scoping itself. The honest reading of the four flag
combinations above is that a boolean is the wrong shape: a small enum
(none / contained / trapped) expresses what Compose needed four flags to say. The
accessibility-conditional focusability has no terminal analogue — its motivation ("make
the surface focusable so the screen reader lands in it") maps to "put the overlay's
cells first in the reading order", which a terminal cannot express at all.

### 10. Layering and portals

There is no portal and no top layer because there is no shared surface: every popup is a
distinct OS window. `PopupLayout` is an `AbstractComposeView` added with
`windowManager.addView(this, params)` (`AndroidPopup.android.kt:796`) that runs its own
composition attached to the parent's `CompositionContext` — so composition locals,
`LifecycleOwner`, `ViewModelStore` and `SavedStateRegistry` are all inherited while the
view tree is not. Z-order belongs to the window manager and is not exposed; no z-index
parameter exists anywhere in the API.

The public/implementation split is clean: public is `Popup`, `PopupProperties`,
`PopupPositionProvider`, and the Android-only `windowType`, `windowToken`, `flags`,
`blurBehindRadius` and `scrimAlpha`; implementation is `PopupLayout`,
`PopupLayoutHelper` (`:1196` — an interface that exists only so tests can fake
`WindowManager`), `LocalIsInPopupLayout` (`:654`) and `LocalPopupTestTag` (whose TODO
calls it "a hack"). Overlay trees exist only implicitly: nesting is a boolean
composition local whose sole consequence is which coordinate space the anchor is
reported in.

Cross-process anchoring is first-class:
`resolveWindowToken(provided ?: rootSubWindowToken ?: applicationWindowToken)` (`:1275`)
has six host-side unit tests (`PopupWindowTokenTest.kt`), so a service can anchor a
popup into another process's window.

> [!WARNING]
> Shadows are faked twice over. The window sets `clipChildren = false` and an
> `elevation` of `maxSupportedElevation = 8.dp`, capped because higher values broke
> accessibility services before Android S (`:733-734`, `b/232788477`), plus a
> rectangular `ViewOutlineProvider` with `alpha = 0f` whose only job is to make the
> window manager allocate surface space for a shadow the composable draws itself
> (`:770-788`). The source comment warns that this rectangular outline also defines the
> dismiss hit area — so a visually circular popup consumes clicks in its rectangular
> corners.

**Algorithm.** Not applicable — delegation to `WindowManager`.

**Where the behavior lives.** Platform compositor for layering; library for composition
wiring and token resolution.

**Degradation.** This is the dimension that cannot survive. With one surface, "later in
the display list" is the whole story, and every OS-window affordance — blur-behind,
dim-behind, secure flag, cross-process token, overlay window types — evaporates. Two
transferable negatives survive, though. The outline-versus-visible-shape mismatch says
the dismiss hit region must be derived from the same geometry that is painted, which is
free if the overlay contributes rects to the hit list. And the elevation cap says shadow
is a rendering-only affordance that must never influence geometry.

### 11. Modality

[Modality][concepts] is not a parameter in this API; it is an emergent product of window
flags. With `focusable = false` (the default) the popup is a passthrough overlay:
keyboard goes to the application, and an outside tap both dismisses the popup and
reaches the widget under it. With `focusable = true` the popup takes key input and
consumes the outside tap.

`PopupDismissTest` asserts precisely that dichotomy, parameterised on `focusable`, and
its comments name the mechanism:

```kotlin
// compose/ui/ui/src/androidDeviceTest/kotlin/androidx/compose/ui/window/PopupDismissTest.kt:129-139
assertThat(dismissCounter).isEqualTo(1)
if (focusable) {
    // Focusable popup consumes touch events => button receives none
    assertThat(btnClicksCounter).isEqualTo(0)
} else {
    // Not focusable popup doesn't consume touch events => button receives one
    assertThat(btnClicksCounter).isEqualTo(1)
}
```

Both behaviours are genuinely wanted: the dismissal fires in both cases and only the
delivery of the click differs.

Scrim and background blur are first-class on the primitive: `scrimAlpha: Float = NaN`
maps to `FLAG_DIM_BEHIND` plus `dimAmount` (`:1181`), and `blurBehindRadius: Dp` maps to
`FLAG_BLUR_BEHIND` on API 31+ (`:1171`). `FLAG_NOT_TOUCH_MODAL` appears only in
`ExposedDropdownMenu`'s hand-rolled flags. There is no accessibility modal bit.

**Algorithm.**
`modality = f(FLAG_NOT_FOCUSABLE, FLAG_NOT_TOUCH_MODAL, FLAG_WATCH_OUTSIDE_TOUCH, FLAG_DIM_BEHIND)`
— four independent bits, never named as one "modal" concept.

**Where the behavior lives.** Platform window manager entirely; the library only
assembles the bitmask.

**Degradation.** On one surface, consume-versus-passthrough is a property of the hit
list: an overlay either contributes a full-surface catcher rect beneath itself or it does
not, and that single choice reproduces both Compose behaviours more cheaply and more
testably than four flags. The scrim becomes a dimmed fill painted before the panel, which
a cell canvas can express as a background blend; blur is unavailable and should be
dropped rather than approximated. Because this subject shows both behaviours shipping in
one API — a tooltip must not eat the click that dismisses it, a context menu must — the
catcher policy should be an explicit input rather than a default.

### 12. Adaptive presentation

There is no popover→sheet adaptation here: no size-class branch exists in any popup path.
What does exist is the hover→long-press substitution, and the notable part is _which
layer decides and when_. The component decides, per pointer type, at event time — not per
device class at composition time. `handleGestures` installs both paths unconditionally;
`awaitFirstDown(pass).type` selects the long-press path for `Touch`/`Stylus`, and the
`Mouse` check on the main pass selects hover. A device with both gets both,
simultaneously, with no configuration.

The second adaptive axis is not form factor at all but **accessibility state**:
`rememberAccessibilityServiceState(listenToTouchExplorationState = true, listenToSwitchAccessState = true)`
(`internal/BasicTooltip.kt:477`, implementation at
`internal/AccessibilityServiceStateProvider.android.kt:43`) is driven by an
`AccessibilityManager` listener registered and unregistered on lifecycle
`ON_RESUME`/`ON_PAUSE`, and its value flips a tooltip from non-focusable to focusable and
flips `ExposedDropdownMenu`'s `FLAG_NOT_TOUCH_MODAL`.

There is no keyboard-driven relocation (no arrow-key repositioning anywhere), and no
teaching-tip surface in this tree.

**Algorithm.** Per gesture: `inputType = awaitFirstDown(Initial).type`; if `Touch` or
`Stylus`, run the long-press timer path. Separately, on the main pass, if the change's
type is `Mouse`, map `Enter → show` and `Exit → dismiss`. Both nodes coexist on the same
modifier chain.

**Where the behavior lives.** Component library (material3/foundation tooltip modifiers)
plus a platform capability query. Not the primitive: `Popup` is unaware of all of it.

**Degradation.** This is the model worth copying: adapt on the event's pointer type, not
on a compile-time target, so one view serves a hover-capable target and a touch-only one
with no branching in the view. Android's total absence of hover then needs no special
case — the hover branch simply never fires. The accessibility-state adaptation has no
terminal analogue and should be dropped rather than faked.

### 13. Accessibility

The primitive contributes exactly two things: `Modifier.semantics { this.popup() }`
wrapped around the content (`AndroidPopup.android.kt:533`, with the property declared at
`SemanticsProperties.kt:1232`), and a window `title` from the string resource
`default_popup_window_title`, carrying the comment that `accessibilityTitle` is not a
public API so the window title is used as the fallback assistive-technology services read
(`:1117`).

The interesting part is that `SemanticsProperties.IsPopup` is a `Unit`-valued
`AccessibilityKey` whose merge policy **throws** (`SemanticsProperties.kt:180-190`), with
a message stating that a popup should not be a child of a clickable or focusable node.
The semantics tree therefore enforces structurally that an overlay is not a descendant of
its trigger, turning a subtle announcement bug into a development-time crash.

Everything else is the component's: tooltips set `liveRegion = LiveRegionMode.Assertive`
and a localized `paneTitle` on the tooltip content (`internal/BasicTooltip.kt:204-205`),
and an `onLongClick(label = …)` semantics action on the anchor (`:295`) so a screen-reader
user has an explicit gesture.

> [!WARNING]
> A live in-tree TODO (`Tooltip.kt:1415`, `b/496338253`) records that tooltip text is
> still not announced by screen readers, and the workaround — duplicating the text into
> `paneTitle` — is hand-copied into the public samples. Hover-only hazard mitigation is
> likewise partial: the content is dismissible via Escape and can be made persistent and
> hoverable when it has an action, but there is no delay and no grace period, so a
> non-persistent tooltip disappears the instant the pointer leaves.

Tooltip content _may_ be interactive: `RichTooltip(action = …)` exists, and it drags the
entire Tab/focus/`forceKeyboardFocusable` machinery in with it — a clear demonstration
that an "interactive tooltip" costs a different component's worth of code.

**Algorithm.** Not applicable.

**Where the behavior lives.** Primitive: one semantics flag plus a window title.
Component: the live-region and pane-title semantics, the long-click action, and the
accessibility-service-conditional focusability.

**Degradation.** A terminal cell grid has no accessibility tree, so the only truthful
analogues are painting the overlay's text into the cell buffer where a screen reader that
reads the terminal will encounter it, and ordering — the overlay's cells paint last but
should arguably be emitted first in any textual dump, mirroring an assertive live region.
The throwing merge policy transposes as a debug assertion: an overlay must not be a child
of a focusable node in the widget arena. The `b/496338253` TODO is a caution worth
carrying: a full accessibility stack still fails to announce tooltip text reliably, so a
toolkit with no accessibility API should not pretend otherwise.

### 14. Animation

This subject emits geometry metadata specifically for animation, and it had to bolt the
channel on. `DropdownMenuPopupPositionProvider` is a public sub-interface of
`PopupPositionProvider` adding exactly one member (`Menu.kt:1636-1643`):

```kotlin
// compose/material3/material3/src/commonMain/kotlin/androidx/compose/material3/Menu.kt:1636-1643
public interface DropdownMenuPopupPositionProvider : PopupPositionProvider {
    public val transformOrigin: TransformOrigin
}
```

documented as being used to animate the menu from the correct point relative to where it
was positioned. `calculateTransformOrigin(anchorBounds, menuBounds)` (`Menu.kt:2060`)
computes each pivot axis as `0f` if the menu starts after the anchor ends, `1f` if it ends
before the anchor starts, and otherwise the centre of the anchor∩menu overlap expressed as
a fraction of the menu's own extent — a purely arithmetic "where did I come from" signal.

The awkwardness is where it is written: into a `mutableStateOf` from **inside**
`calculatePosition` (`internal/MenuPosition.kt:288` declares
`override var transformOrigin by mutableStateOf(TransformOrigin.Center)`, `:387` assigns
it), so the pure function has a side effect and the menu reads it back through a
`graphicsLayer`. The same method also invokes an `onPositionCalculated(anchorBounds, menuBounds)`
callback (`:390`) — a second escape hatch for the same missing return value.

Tooltips get no such channel and instead derive a quadrant (1..4 for the four corners) in
a `derivedStateOf` comparing popup screen position to anchor screen position
(`Tooltip.kt:188`), used solely as `key(tooltipSide) { … }` (`:239`) so the scale/alpha
transition restarts when the resolved side changes.

**Algorithm.**
`pivotX = menuLeft >= anchorRight ? 0 : menuRight <= anchorLeft ? 1 : ((max(anchorLeft, menuLeft) + min(anchorRight, menuRight)) / 2 − menuLeft) / menuWidth`,
with `pivotY` symmetric and a zero-extent guard. Enter and exit are spring-based
motion-scheme tokens; repositioning during a transition is unrestricted, because the
window moves whenever `updatePosition` runs regardless of the animation. Reduced motion is
not handled in these files (this was not searched across the whole motion-scheme
subsystem, so the observation is scoped to the tooltip and menu files).

**Where the behavior lives.** material3 owns both the sub-interface and the arithmetic;
the primitive has no animation awareness whatsoever.

**Degradation.** A cell grid has no transform origin and scale animation is inexpressible.
But the _metadata_ lesson is independent of pixels: the placement result must carry enough
to answer "which side, and where along it", because both consumers here needed that and
each invented a private channel — a sub-interface with mutable state, and a quadrant
derived post-hoc from coordinates. In cells the equivalent payloads are the chosen side
(for the arrow glyph and for a grow-from-the-anchor reveal) and the arrow cell index. With
no script the metadata is still needed, for the border character.

### 15. State architecture

Three architectures coexist in one tree, and their differences are the finding.

**(a) Menus — fully controlled.** `expanded: Boolean` plus `onDismissRequest`, both owned
by the caller. The component holds only a `MutableTransitionState` for the exit animation
and keeps the popup composed while `expandedState.currentState || expandedState.targetState`
(`AndroidMenu.android.kt:58`).

**(b) Context menus — a value-typed machine.** A two-case sealed class
`Status = Open(offset: Offset) | Closed` (`ContextMenuState.kt:46-68`), with a
precondition that `Open`'s offset is specified and hand-written `equals`/`hashCode`. The
provider is keyed on the state value: `remember(status) { ContextMenuPopupPositionProvider(status.offset.round()) }`.

**(c) Tooltips — an imperative interface over a live coroutine.**
`TooltipState { transition; isVisible; isPersistent; suspend show(priority); dismiss(); onDispose() }`
(`Tooltip.kt:1122`), whose "shown" state _is_ a suspended coroutine: `show` stores a
continuation in a field via `suspendCancellableCoroutine` (`:1078`), and the global mutex
coordinates the rest.

**Algorithm.** Tooltip: acquire the global lease by priority, suspend indefinitely (or
until `withTimeout`), and on cancellation or timeout clear visibility in a `finally`.
Menus: caller state drives composition presence. Context menu: a sealed value compared by
equality.

**Where the behavior lives.** Library, split across compose-foundation (`MutatorMutex`,
`ContextMenuState`) and material3 (`TooltipState`).

**Degradation.** (a) and (b) survive a value-semantics, allocation-averse setting intact —
(b) is literally a sum type carrying its anchor offset, and keying the provider on it by
equality is exactly the re-place trigger such a toolkit wants. (c) does not survive: it
requires structured concurrency, cancellation as control flow and a stored continuation,
and it is unassertable on a recording canvas. The substitute that preserves the observable
policy is an explicit record — owner id, priority, deadline — in a single global lease
slot, which reproduces the global-single-tooltip behaviour, the priority arbitration and
the maximum-duration timeout with three integers. Worth keeping either way: value equality
as the change-detection strategy, which this codebase relies on in at least three separate
places to avoid redundant work.

### 16. Shared infrastructure

The factoring is unusually clean and its seams are visible.

**Truly shared** — all literally the same `Popup` plus a `PopupPositionProvider`: plain
tooltip, rich tooltip, `DropdownMenu`, `ExposedDropdownMenu`, right-click context menu,
text-selection context menu, text-selection drag handles (`AndroidSelectionHandles.android.kt:225`)
and `SearchBar` (`SearchBar.kt:843`). Eight surfaces on one primitive.

**Shared one level up, but stopping one level too early.** `MenuPosition.Horizontal` /
`MenuPosition.Vertical` — the single-axis placement atoms — are reused by both
`DropdownMenuPositionProvider` and `ExposedDropdownMenuPositionProvider`. But those two
then implement the _same candidate loop twice with different semantics_: the menu version
tests fit against margins and repairs the last candidate (`internal/MenuPosition.kt:332-358`),
while the exposed-dropdown version tests against `0`/`windowSize.width` and accepts the
last x candidate unclamped (`ExposedDropdownMenu.kt:847-860`).

**What merely looks common and stays apart.** Tooltip state versus menu state — a coroutine
lease and a caller boolean, never unified. Caret geometry, which lives only in tooltips and
is not offered to menus. Dialogs, which use a sibling primitive rather than `Popup`.

> [!IMPORTANT]
> `BasicTooltipBox` is **forked**, not shared. material3 carries a copy of foundation's
> implementation under the header "NOTICE: Fork from `androidx.compose.foundation.BasicTooltip`
> box since those are experimental" (`internal/BasicTooltip.kt:72`), and the two have already
> diverged: material3's long press uses `withTimeout` plus
> `PointerEventTimeoutCancellationException` and claims `MutatePriority.PreventUserInput`
> (`:230-238`), while foundation's uses `waitForLongPress` and claims `UserInput`
> (`BasicTooltip.kt:202-205`) — and foundation's copy has no keyboard, Escape or Tab handling
> at all.

**Algorithm.** Not applicable.

**Where the behavior lives.** `compose-ui` owns the primitive; compose-foundation owns
context menus, selection and the experimental tooltip; material3 owns menus, the forked
tooltip and the caret.

**Degradation.** The transposition for one `AnchoredOverlay` is a decomposition rather than
a feature: put `place()`-as-values, the anchor-rect reduction, the outside-catcher policy,
the dismissal keys and the paint-last ordering in the primitive, and keep the trigger state
machines out. The fork is the cautionary tale — two teams needed the same tooltip, could not
share an experimental API, copied it, and the copies now differ in gesture semantics _and_ in
keyboard support. That is precisely the seam a shared primitive must not straddle.

> [!NOTE]
> The eight-surfaces-on-one-primitive result is real, but it is subsidised: the window
> manager supplies clipping escape, z-ordering, focus containment and outside-touch delivery
> for free, so `Popup` itself never had to grow a layer registry, an overlay tree or a
> modality model. A single-surface toolkit gets the placement half of that unification at the
> same price and must pay for the layering half itself.

---

## Strengths

- The placement seam is small, total and value-shaped: four values in, one value out,
  integer throughout, with host-side unit tests asserting exact geometry
  (`PopupPositionProviderTest` covers 9 alignments × 2 directions in 18 tests;
  `ContextMenuPopupPositionProviderTest` covers all four axis cases plus both off-by-one
  boundaries).
- One primitive genuinely serves eight surfaces, which is empirical evidence that a single
  anchored-overlay abstraction is viable at least for the placement and window-hosting half.
- Placement is decomposed into per-axis, per-edge named atoms that compose into candidate
  lists, so adding a placement policy is a list literal rather than new geometry code — and
  `MenuAnchorPosition.Custom` makes that extension public.
- Trigger arbitration is delegated to one general-purpose primitive (`MutatorMutex` plus a
  three-value priority ladder) rather than re-derived per component, and the global-versus-local
  behaviour is pinned by paired tests.
- Value equality is the change-detection strategy throughout — the anchor rect comparison, the
  properties early-out, the memoizing provider's triple comparison — a discipline that
  transfers directly to a value-semantics toolkit.
- Pointer-type adaptation is at the right layer and the right granularity: both gesture paths
  are installed unconditionally and each is gated on the event's own pointer type, so a
  hover-less target needs no code change.
- The tests document intent unusually well:
  `popupPositionProvider_receivesWindowRelativeCoordinates_whenNotNested` versus
  `..._receivesScreenCoordinates_whenNested`,
  `positionNotUpdated_whenStateReadInPositionProviderChanged_whileDetached`,
  `fullWidthTooltipCaret_xPositioning`, `alignPopupAxis_popupBarelyFitsInAfterSpace` and its
  `DoesNotFit` twin.

## Weaknesses

- The return type of `calculatePosition` is too small — no side, no flip flag, no arrow anchor
  — and every consumer needing that information invented a private channel: a sub-interface
  carrying mutable `transformOrigin`, an `onPositionCalculated` callback, a `derivedStateOf`
  quadrant recovered from screen coordinates one frame late, and an
  `is TooltipPositionProviderImpl` downcast.
- `PopupPositionProvider` is annotated `@Immutable` while at least three in-tree
  implementations are stateful; the annotation is unenforced documentation.
- The same candidate-loop algorithm is implemented twice with different fit predicates and
  different last-candidate handling (menu versus exposed dropdown).
- Caret geometry re-implements the placer's clamping and disagrees with it: in the
  left-collision branch `caretX` under-shoots by `min(anchorLeft, W − w)` relative to the
  position the provider actually produced, and the collision branches carry no test.
- `anchorBounds` changes coordinate space depending on nesting while `windowSize` does not —
  an inconsistency the code flags twice and that `ExposedDropdownMenu` patches by adding
  status-bar insets to the `windowSize` it was handed.
- The boundary is an explicit parameter, but the value handed in omits the soft-keyboard inset
  and nothing invalidates it, so one missing input is repaired three different ways
  (per-frame polling; a `neverEqualPolicy` signal read for its dependency alone; a manual
  inset addition inside the provider).
- Tooltip "shown" is a suspended coroutine holding a continuation in a field: the state is
  unrepresentable as a value and unassertable without a test clock.
- `BasicTooltipBox` is forked between compose-foundation and material3, and the forks have
  already diverged in gesture semantics and in keyboard support.
- There is no hover delay and no grace period, which makes a hoverable non-persistent tooltip
  unachievable; and a live TODO records that tooltip text is still not announced by screen
  readers, worked around by duplicating the text into `paneTitle` — including in the public
  samples.

## Key design decisions and trade-offs

| Decision                                                                                                                                                                      | Rationale                                                                                                                                                                                                                                                | Trade-off                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Make placement an interface with ONE pure method over four plain values returning one `IntOffset`, and make it the only placement API in the stack.                           | Everything a placer needs about its environment reduces to (anchor rect, viewport size, direction, content size). Keeping it that small made every provider host-testable with no device and no composition, and let one primitive serve eight surfaces. | The return type is too small, and three escape hatches grew around it — a sub-interface smuggling `transformOrigin` out through mutable state, an `onPositionCalculated` callback on two providers, and a downcast plus coordinate comparison in the caret layer. A result carrying `{offset, side, arrowIndex, flipped}` would have cost nothing and prevented all three.                                                                                 |
| Use integer units everywhere in placement (`IntRect` / `IntOffset` / `IntSize`), pinning the float→int conversion at a single boundary.                                       | Windows are positioned in whole pixels anyway, and integer geometry makes exact-equality change detection both correct and cheap.                                                                                                                        | Sub-pixel anchor drift produces no reposition — desirable here — but the caret layer works in floats from `boundsInScreen`, so the two reason in different numeric spaces, and their arithmetic has drifted apart at screen edges.                                                                                                                                                                                                                         |
| Make every popup a real OS child window rather than an in-app overlay layer.                                                                                                  | Free escape from ancestor clipping, free z-ordering, real focus containment, real outside-touch delivery, and cross-process anchoring via window tokens.                                                                                                 | Heavy platform coupling: a dozen window flags, SDK-conditional helpers, per-frame `getLocationOnScreen` polling because the OS moves the host view without callbacks, a nested-popup coordinate-space split needing two device tests to pin, a fake-shadow outline that silently becomes the dismiss hit area, and an elevation cap to avoid breaking accessibility services. The parts that transfer are exactly the parts that never touched the window. |
| Ship no hover delay, no close delay and no skip-delay group; the only timing constant is a 1500 ms MAX display duration that hover explicitly bypasses.                       | Mutual exclusion via a global `MutatorMutex` already prevents tooltip storms and pointer-type dispatch already prevents accidental touch tooltips, so delays would add state without removing a failure mode.                                            | Mouse tooltips appear instantly on `Enter` and vanish instantly on `Exit`, which is jumpy on a dense toolbar and leaves the hoverable-tooltip requirement unmet for non-persistent tooltips. The upside for a constrained toolkit is that the entire timing story is one optional deadline.                                                                                                                                                                |
| Adapt on the POINTER TYPE of the actual event by installing both gesture handlers unconditionally on different pointer passes, rather than branching on device or size class. | Hybrid devices exist, so a composition-time branch would be wrong on a tablet with a mouse; gating inside the gesture is exact and needs no configuration.                                                                                               | Two always-installed `pointerInput` nodes per tooltip anchor, on two different passes, plus the child-click consumption dance after a long press. Slightly more machinery than a branch — and the only design that degrades to a hover-less target with zero code changes.                                                                                                                                                                                 |
| Never let the primitive close itself: `onDismissRequest` is advisory and the caller owns open/closed state.                                                                   | One uniform controlled-state model serves an animated menu that must stay composed through its exit transition and a tooltip whose visibility is a coroutine lease.                                                                                      | Every consumer re-implements the same dismiss handler, and subtle obligations migrate into the consumer — the tooltip's handler must also clear `forceKeyboardFocusable` or keyboard focus stays trapped, as a source comment records. A primitive owning an explicit open/closed sum type, as `ContextMenuState` does one level up, would centralise that.                                                                                                |
| Arbitrate every trigger through one three-level priority lease rather than per-component race handling.                                                                       | A CAS'd single-slot registry where equal-or-higher priority replaces and lower is refused removes every trigger race with no timers and no pairwise table.                                                                                               | The rung assignment is a per-call-site decision and has already drifted: long press claims `PreventUserInput` in material3, `UserInput` in foundation's copy, and `Default` when it arrives through the accessibility semantics action. The mechanism is sound; the policy needs a single owner.                                                                                                                                                           |

---

## Sources

All line references are to the pinned revision
`268d841a45644cadf438fc335c793869728449ec` (`COMPOSE = 1.13.0-alpha02`,
`COMPOSE_MATERIAL3 = 1.5.0-alpha26`).

Primitive (`compose-ui`):

- [`compose/ui/ui/src/commonMain/kotlin/androidx/compose/ui/window/Popup.kt`][src-popup] — the
  `@Immutable` interface (`:70-71`), the doc comment on `windowSize` (`:75-79`), the sole
  placement method (`:86-91`), and `AlignmentOffsetPositionProvider` (`:94-116`).
- [`compose/ui/ui/src/androidMain/kotlin/androidx/compose/ui/window/AndroidPopup.android.kt`][src-androidpopup]
  — `equalsIncludingNaN` in `PopupProperties.equals` (`:430`), the semantics wrapper (`:533`),
  the measure-then-place alpha gate (`:535-540`), the per-frame polling loop and its comment
  (`:580-591`), the base window flags (`:613-614`), `LocalIsInPopupLayout` (`:654`),
  `canCalculatePosition` (`:728-730`), `maxSupportedElevation` and `b/232788477` (`:733-734`),
  the clip/outline setup (`:771-788`), `addView` (`:797`), the measure path (`:825`),
  `dispatchKeyEvent` (`:855`), the properties early-out (`:903`),
  `pollForLocationOnScreenChange` (`:938-964`), `updateParentBounds` including the
  nested-coordinate-space comment (`:966-996`), `observeReads` around the placement call
  (`:1012`), `onTouchEvent` (`:1044`), the fallback window title (`:1117`), `getDisplayBounds`
  (`:1121`), blur and scrim (`:1171`, `:1181`), the predictive-back callback (`:1144`),
  `PopupLayoutHelper` (`:1196`) and `resolveWindowToken` (`:1275`).
- [`compose/ui/ui/src/commonMain/kotlin/androidx/compose/ui/semantics/SemanticsProperties.kt`][src-semantics]
  — `IsPopup` and its throwing merge policy (`:180-190`), `SemanticsPropertyReceiver.popup`
  (`:1232`).

Menus and tooltips (`compose-material3`):

- [`compose/material3/material3/src/commonMain/kotlin/androidx/compose/material3/internal/MenuPosition.kt`][src-menuposition]
  — the single-axis atoms (`:50`, `:79`, `:107`, `:115`, `:143`),
  `DropdownMenuPositionProvider` (`:280`), the `onPositionCalculated` hook (`:286`), the
  stateful `transformOrigin` (`:288`, assigned `:387`), and `positioningLogic` with the
  first-fit loop and centre-or-clamp repair (`:317-392`).
- [`compose/material3/material3/src/commonMain/kotlin/androidx/compose/material3/Menu.kt`][src-menu]
  — `Modifier.hoverable(interactionSource)` on the submenu container (`:294`),
  `MenuAnchorPosition.Below`'s candidate ladders (`:1407`),
  `DropdownMenuPopupPositionProvider` and `transformOrigin` (`:1636-1643`),
  `calculateTransformOrigin` (`:2060`), `MenuVerticalMargin` (`:2168`) and
  `MenuHorizontalMargin` (`:2216`).
- [`compose/material3/material3/src/commonMain/kotlin/androidx/compose/material3/Tooltip.kt`][src-tooltip]
  — the `tooltipSide` quadrant (`:188`) and `key(tooltipSide)` (`:239`), the
  `LocalWindowInfo.current.containerSize` reads (`:751`, `:1211-1212`),
  `TooltipAnchorPosition` (`:809`), `TooltipPositionProviderImpl` and its per-side
  functions including `abovePositioning` (`:901-1000`), `suspendCancellableCoroutine`
  (`:1078`), `TooltipState` (`:1122`), `caretX` (`:1166-1192`), `Modifier.layoutCaret`
  (`:1195`) with the `isBelow`/`isToTheRight` recovery (`:1215-1216`) and the provider
  downcast (`:1219`), `DefaultTooltipCaretShape` (`:1345`), `createOutline` (`:1372`), the
  `b/496338253` announcement TODO (`:1415`) and `SpacingBetweenTooltipAndAnchor` (`:1450`).
- [`compose/material3/material3/src/commonMain/kotlin/androidx/compose/material3/internal/BasicTooltip.kt`][src-basictooltip-m3]
  — the fork notice (`:72`), `shouldForceFocusableForA11y` (`:110-120`, `:140`), the
  live-region and pane-title semantics (`:204-205`), `handleGestures` (`:213`) with the
  pointer-type gate (`:224`), the long-press timeout (`:230`, priority at `:238`), the mouse
  `Enter`/`Exit` arms (`:271-275`), the accessibility `onLongClick` action (`:293-298`),
  `keyboardBehavior` (`:305`) with the focus show (`:319`) and Tab interception (`:327-344`),
  the show lease (`:428-440`), `GlobalMutatorMutex` (`:459`), `TooltipDuration` (`:465`), the
  accessibility-service state (`:477`) and the `KeyDown`-only Escape predicate (`:485`).
- [`compose/material3/material3/src/commonMain/kotlin/androidx/compose/material3/ExposedDropdownMenu.kt`][src-edm]
  — the `neverEqualPolicy` keyboard signal (`:359`), the status-bar inset (`:361`), the
  dependency-only read and the two workaround comments (`:825-835`), and the duplicated
  candidate loop with its different fit predicate (`:837-860`).
- [`compose/material3/material3/src/androidMain/kotlin/androidx/compose/material3/ExposedDropdownMenu.android.kt`][src-edm-android]
  — `popupPropertiesForAnchorType` and its four-flag computation (`:55-79`).
- [`compose/material3/material3/src/androidMain/kotlin/androidx/compose/material3/AndroidMenu.android.kt`][src-androidmenu]
  — the keep-composed-through-exit condition (`:58`).
- [`compose/material3/material3/src/androidMain/kotlin/androidx/compose/material3/internal/AccessibilityServiceStateProvider.android.kt`][src-a11ystate]
  — the lifecycle-scoped `AccessibilityManager` listener (`:43`).
- [`compose/material3/material3/src/commonMain/kotlin/androidx/compose/material3/SearchBar.kt`][src-searchbar]
  — the search bar's own `Popup` (`:843`).
- [`compose/material3/material3/samples/src/main/java/androidx/compose/material3/samples/MenuSamples.kt`][src-menusamples]
  — the shared interaction source (`:340-344`), the `itemChecked || itemHovered` open
  condition (`:373`) and the source handed to the submenu (`:377`).

Context menus, selection and the foundation tooltip (`compose-foundation`):

- [`compose/foundation/foundation/src/commonMain/kotlin/androidx/compose/foundation/contextmenu/ContextMenuPopupPositionProvider.kt`][src-ctxpos]
  — the `b/256233441` coordinate-space TODO (`:61`) and `alignPopupAxis` with its helpers
  (`:107-158`).
- [`compose/foundation/foundation/src/commonMain/kotlin/androidx/compose/foundation/contextmenu/ContextMenuState.kt`][src-ctxstate]
  — the sealed `Status` value type (`:46-68`).
- [`compose/foundation/foundation/src/commonMain/kotlin/androidx/compose/foundation/contextmenu/ContextMenuGestures.kt`][src-ctxgestures]
  — `ContextMenuKey` and the `Unit`-clash comment (`:26`).
- [`compose/foundation/foundation/src/commonMain/kotlin/androidx/compose/foundation/contextmenu/ContextMenuUi.kt`][src-ctxui]
  — `DefaultPopupProperties(focusable = true)` (`:92`).
- [`compose/foundation/foundation/src/commonMain/kotlin/androidx/compose/foundation/MutatorMutex.kt`][src-mutatormutex]
  — `MutatePriority` (`:34-53`), `canInterrupt` (`:82`) and `tryMutateOrCancel` (`:90-100`).
- [`compose/foundation/foundation/src/commonMain/kotlin/androidx/compose/foundation/BasicTooltip.kt`][src-basictooltip-foundation]
  — the divergent fork: `handleGestures` (`:191`), `waitForLongPress` at `UserInput`
  (`:202-205`) and the hover open at the same rung (`:227-228`).
- [`compose/foundation/foundation/src/commonMain/kotlin/androidx/compose/foundation/text/selection/SelectionManager.kt`][src-selectionmanager]
  — `getContentRect` (`:1207`) and `getSelectedRegionRect` (`:1635`).
- [`compose/foundation/foundation/src/commonMain/kotlin/androidx/compose/foundation/text/selection/SelectionHandles.kt`][src-selectionhandles]
  — `HandlePositionProvider` (`:108`) and its `prevPosition` memo with the lifecycle comment
  (`:113-133`).
- [`compose/foundation/foundation/src/androidMain/kotlin/androidx/compose/foundation/text/selection/AndroidSelectionHandles.android.kt`][src-androidhandles]
  — the handles' `Popup` (`:225`).
- [`compose/foundation/foundation/src/androidMain/kotlin/androidx/compose/foundation/text/contextmenu/internal/DefaultTextContextMenuDropdownProvider.android.kt`][src-textmenu]
  — `MaintainWindowPositionPopupPositionProvider` (`:193`).

Tests read (source only — nothing was executed):

- [`compose/ui/ui/src/androidHostTest/kotlin/androidx/compose/ui/window/PopupPositionProviderTest.kt`][src-test-provider]
  — 18 exact-geometry cases (9 alignments × LTR/RTL).
- [`compose/foundation/foundation/src/androidHostTest/kotlin/androidx/compose/foundation/contextmenu/ContextMenuPopupPositionProviderTest.kt`][src-test-ctxpos]
  — the ten affinity branches (`:119-160`) and the four boundary cases (`:176-207`).
- [`compose/ui/ui/src/androidDeviceTest/kotlin/androidx/compose/ui/window/PopupTest.kt`][src-test-popup]
  — `doesNotCrashWhenAnchorDetachedFirst` (`:600`) and the two coordinate-space tests
  (`:915`, `:965`).
- [`compose/ui/ui/src/androidDeviceTest/kotlin/androidx/compose/ui/window/PopupLayoutTest.kt`][src-test-layout]
  — the snapshot-observer test and its detached negative (`:223`, `:257`) and the unclipped
  bounds test (`:320`).
- [`compose/ui/ui/src/androidDeviceTest/kotlin/androidx/compose/ui/window/PopupDismissTest.kt`][src-test-dismiss]
  — the consume-versus-passthrough assertion (`:129-139`).
- [`compose/material3/material3/src/androidDeviceTest/kotlin/androidx/compose/material3/TooltipTest.kt`][src-test-tooltip]
  — the paired global/local mutex tests (`:808`, `:872`), the full-width caret regression
  (`:1190`) and the test-only fade constant (`:1229`).
- [`compose/ui/ui/src/androidHostTest/kotlin/androidx/compose/ui/window/PopupWindowTokenTest.kt`][src-test-token]
  — the window-token resolution cases (`:29`).

Catalog cross-links: the umbrella [index][index] and shared [vocabulary][concepts]; the
capstone [comparison][comparison]; [features people forget][forget]; the
[sparkles baseline][baseline] and [proposal][proposal]. Nearest neighbours by surface model
and by algorithm shape: [`xdg_positioner`][xdg] (the other integer-only placement algebra),
[GTK4][gtk4] (the other toolkit whose value is solved by a compositor), [Flutter][flutter]
(the same ecosystem, opposite surface model), [Avalonia][avalonia] and [Slint][slint] (one
declaration, two surfaces), [Apple][apple] (the other mobile/adaptive stack) and
[Helix][helix] (a cell-grid subject that also discards the resolved side). Sibling research
trees: [window-system integration][wsi], [platform UI guidelines][pug], [UI layout][layout]
and [Sean Parent][parent]. Toolkit specs: [`sparkles:ui`][spec-ui], [input][spec-input],
[containers][spec-containers], [state machines][spec-stm], [backends][spec-backends] and
[widgets][spec-widgets].

<!-- References -->

[repo]: https://github.com/androidx/androidx
[repo-pin]: https://github.com/androidx/androidx/tree/268d841a45644cadf438fc335c793869728449ec
[docs-provider]: https://developer.android.com/reference/kotlin/androidx/compose/ui/window/PopupPositionProvider
[docs-menu]: https://developer.android.com/develop/ui/compose/components/menu
[docs-tooltip]: https://developer.android.com/develop/ui/compose/components/tooltip
[src-popup]: https://github.com/androidx/androidx/blob/268d841a45644cadf438fc335c793869728449ec/compose/ui/ui/src/commonMain/kotlin/androidx/compose/ui/window/Popup.kt#L71
[src-androidpopup]: https://github.com/androidx/androidx/blob/268d841a45644cadf438fc335c793869728449ec/compose/ui/ui/src/androidMain/kotlin/androidx/compose/ui/window/AndroidPopup.android.kt#L533
[src-semantics]: https://github.com/androidx/androidx/blob/268d841a45644cadf438fc335c793869728449ec/compose/ui/ui/src/commonMain/kotlin/androidx/compose/ui/semantics/SemanticsProperties.kt#L181
[src-menuposition]: https://github.com/androidx/androidx/blob/268d841a45644cadf438fc335c793869728449ec/compose/material3/material3/src/commonMain/kotlin/androidx/compose/material3/internal/MenuPosition.kt#L317
[src-menu]: https://github.com/androidx/androidx/blob/268d841a45644cadf438fc335c793869728449ec/compose/material3/material3/src/commonMain/kotlin/androidx/compose/material3/Menu.kt#L1407
[src-tooltip]: https://github.com/androidx/androidx/blob/268d841a45644cadf438fc335c793869728449ec/compose/material3/material3/src/commonMain/kotlin/androidx/compose/material3/Tooltip.kt#L1166
[src-basictooltip-m3]: https://github.com/androidx/androidx/blob/268d841a45644cadf438fc335c793869728449ec/compose/material3/material3/src/commonMain/kotlin/androidx/compose/material3/internal/BasicTooltip.kt#L213
[src-basictooltip-foundation]: https://github.com/androidx/androidx/blob/268d841a45644cadf438fc335c793869728449ec/compose/foundation/foundation/src/commonMain/kotlin/androidx/compose/foundation/BasicTooltip.kt#L191
[src-mutatormutex]: https://github.com/androidx/androidx/blob/268d841a45644cadf438fc335c793869728449ec/compose/foundation/foundation/src/commonMain/kotlin/androidx/compose/foundation/MutatorMutex.kt#L34
[src-ctxpos]: https://github.com/androidx/androidx/blob/268d841a45644cadf438fc335c793869728449ec/compose/foundation/foundation/src/commonMain/kotlin/androidx/compose/foundation/contextmenu/ContextMenuPopupPositionProvider.kt#L107
[src-ctxstate]: https://github.com/androidx/androidx/blob/268d841a45644cadf438fc335c793869728449ec/compose/foundation/foundation/src/commonMain/kotlin/androidx/compose/foundation/contextmenu/ContextMenuState.kt#L46
[src-ctxgestures]: https://github.com/androidx/androidx/blob/268d841a45644cadf438fc335c793869728449ec/compose/foundation/foundation/src/commonMain/kotlin/androidx/compose/foundation/contextmenu/ContextMenuGestures.kt#L26
[src-ctxui]: https://github.com/androidx/androidx/blob/268d841a45644cadf438fc335c793869728449ec/compose/foundation/foundation/src/commonMain/kotlin/androidx/compose/foundation/contextmenu/ContextMenuUi.kt#L92
[src-selectionmanager]: https://github.com/androidx/androidx/blob/268d841a45644cadf438fc335c793869728449ec/compose/foundation/foundation/src/commonMain/kotlin/androidx/compose/foundation/text/selection/SelectionManager.kt#L1635
[src-selectionhandles]: https://github.com/androidx/androidx/blob/268d841a45644cadf438fc335c793869728449ec/compose/foundation/foundation/src/commonMain/kotlin/androidx/compose/foundation/text/selection/SelectionHandles.kt#L108
[src-androidhandles]: https://github.com/androidx/androidx/blob/268d841a45644cadf438fc335c793869728449ec/compose/foundation/foundation/src/androidMain/kotlin/androidx/compose/foundation/text/selection/AndroidSelectionHandles.android.kt#L225
[src-textmenu]: https://github.com/androidx/androidx/blob/268d841a45644cadf438fc335c793869728449ec/compose/foundation/foundation/src/androidMain/kotlin/androidx/compose/foundation/text/contextmenu/internal/DefaultTextContextMenuDropdownProvider.android.kt#L193
[src-edm]: https://github.com/androidx/androidx/blob/268d841a45644cadf438fc335c793869728449ec/compose/material3/material3/src/commonMain/kotlin/androidx/compose/material3/ExposedDropdownMenu.kt#L825
[src-edm-android]: https://github.com/androidx/androidx/blob/268d841a45644cadf438fc335c793869728449ec/compose/material3/material3/src/androidMain/kotlin/androidx/compose/material3/ExposedDropdownMenu.android.kt#L55
[src-androidmenu]: https://github.com/androidx/androidx/blob/268d841a45644cadf438fc335c793869728449ec/compose/material3/material3/src/androidMain/kotlin/androidx/compose/material3/AndroidMenu.android.kt#L58
[src-a11ystate]: https://github.com/androidx/androidx/blob/268d841a45644cadf438fc335c793869728449ec/compose/material3/material3/src/androidMain/kotlin/androidx/compose/material3/internal/AccessibilityServiceStateProvider.android.kt#L43
[src-searchbar]: https://github.com/androidx/androidx/blob/268d841a45644cadf438fc335c793869728449ec/compose/material3/material3/src/commonMain/kotlin/androidx/compose/material3/SearchBar.kt#L843
[src-menusamples]: https://github.com/androidx/androidx/blob/268d841a45644cadf438fc335c793869728449ec/compose/material3/material3/samples/src/main/java/androidx/compose/material3/samples/MenuSamples.kt#L340
[src-test-provider]: https://github.com/androidx/androidx/blob/268d841a45644cadf438fc335c793869728449ec/compose/ui/ui/src/androidHostTest/kotlin/androidx/compose/ui/window/PopupPositionProviderTest.kt#L32
[src-test-ctxpos]: https://github.com/androidx/androidx/blob/268d841a45644cadf438fc335c793869728449ec/compose/foundation/foundation/src/androidHostTest/kotlin/androidx/compose/foundation/contextmenu/ContextMenuPopupPositionProviderTest.kt#L119
[src-test-popup]: https://github.com/androidx/androidx/blob/268d841a45644cadf438fc335c793869728449ec/compose/ui/ui/src/androidDeviceTest/kotlin/androidx/compose/ui/window/PopupTest.kt#L600
[src-test-layout]: https://github.com/androidx/androidx/blob/268d841a45644cadf438fc335c793869728449ec/compose/ui/ui/src/androidDeviceTest/kotlin/androidx/compose/ui/window/PopupLayoutTest.kt#L223
[src-test-dismiss]: https://github.com/androidx/androidx/blob/268d841a45644cadf438fc335c793869728449ec/compose/ui/ui/src/androidDeviceTest/kotlin/androidx/compose/ui/window/PopupDismissTest.kt#L129
[src-test-tooltip]: https://github.com/androidx/androidx/blob/268d841a45644cadf438fc335c793869728449ec/compose/material3/material3/src/androidDeviceTest/kotlin/androidx/compose/material3/TooltipTest.kt#L808
[src-test-token]: https://github.com/androidx/androidx/blob/268d841a45644cadf438fc335c793869728449ec/compose/ui/ui/src/androidHostTest/kotlin/androidx/compose/ui/window/PopupWindowTokenTest.kt#L29
[index]: ./index.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[forget]: ./features-people-forget.md
[baseline]: ./sparkles-baseline.md
[proposal]: ./proposal.md
[xdg]: ./xdg-positioner.md
[gtk4]: ./gtk4.md
[flutter]: ./flutter.md
[avalonia]: ./avalonia.md
[slint]: ./slint.md
[apple]: ./apple.md
[helix]: ./helix.md
[wsi]: ../window-system-integration/index.md
[pug]: ../platform-ui-guidelines/index.md
[layout]: ../ui-layout/index.md
[parent]: ../sean-parent/index.md
[spec-ui]: ../../specs/ui/index.md
[spec-input]: ../../specs/ui/input.md
[spec-containers]: ../../specs/ui/containers.md
[spec-stm]: ../../specs/ui/state-machines.md
[spec-backends]: ../../specs/ui/backends.md
[spec-widgets]: ../../specs/ui/widgets.md
