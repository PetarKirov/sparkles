# Uno Platform (C# / .NET)

Uno re-implements the WinUI popup contract with no OS popup surface on any target: every open popup is a full-window `Panel` parented under a single in-app `PopupRoot` canvas, and all placement is `Rect`-to-`Rect` arithmetic in managed code.

| Field             | Value                                                                                                                                                                                                |
| ----------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Language**      | C#                                                                                                                                                                                                   |
| **License**       | Apache-2.0                                                                                                                                                                                           |
| **Repository**    | [`unoplatform/uno`][repo]                                                                                                                                                                            |
| **Documentation** | [platform.uno/docs][unodocs] — but this page is an **implementation reading**, not a docs reading                                                                                                    |
| **Category**      | Native desktop / mobile / web (.NET), in-canvas                                                                                                                                                      |
| **Surface model** | In-canvas on every target. One optional Android full-screen native `PopupWindow` exists, but it is `MatchParent` × `MatchParent` and hosts the same managed panel, so it contributes zero placement. |
| **Revision read** | [`df5d18a850248cb8c2ccb34032b4ebeb54dc8283`][repo-sha] (version.json reports `6.7-dev`)                                                                                                              |

> [!NOTE]
> Nothing here was built or executed. Every claim is a reading of source at the pinned revision; no runtime behaviour was observed and no test was run. Where a statement is an inference rather than something the source states, it is marked as one.

## Overview

### What it solves

Uno's job is behavioural compatibility with WinUI on targets that have no WinUI: Skia (X11/Win32/macOS/framebuffer), WebAssembly, Android, iOS/tvOS. For anchored overlays that means reproducing the observable output of `Popup`, `FlyoutBase`, `MenuFlyout`, `ToolTip`, `ContentDialog`, `ComboBox`'s dropdown and `TeachingTip` — flip-on-overflow, light dismiss, submenu cascades, hover timing, focus save/restore — while having none of the substrate WinUI leans on. There is no compositor popup, no OS child window, no top layer, and no OS input grab in any code path read here.

The whole overlay stack therefore lives inside one app surface. `VisualTree.SetPublicRootVisual` installs a fixed ladder of root layers — `PublicRootVisual`, `FullWindowMediaRoot`, `PopupRoot`, `FocusVisualRoot` — each pinned by a `Canvas.ZIndex` constant defined as an arithmetic chain off `UnoTopZIndex` (`VisualTree.cs:36-39`). Opening a popup is `PopupRoot.Children.Add(panel)`; closing it is `Children.Remove(panel)`. "Top layer" is a Z-index constant, and "front" is "later in the child collection". See [`./concepts.md`](./concepts.md) for the shared vocabulary of _top layer_, _clipping boundary_, _light dismiss_ and _constraint adjustment_ used throughout.

### Design philosophy

Fidelity to WinUI's **observable output**, not to WinUI's mechanism — including deliberately reproducing behaviour a from-scratch design would call a bug. The offset-only fast path in `PopupPanel.ArrangeOverride` says so directly (`PopupPanel.cs:127-129`):

```csharp
// Gets the location of the popup (or its Anchor) in the VisualTree, so we will align Top/Left with it
// Note: we do not prevent overflow of the popup on any side as UWP does not!
//       (And actually it also lets the view appear out of the window ...)
```

Collision handling is consequently **opt-in**, not a universal invariant: `PopupPanel.ArrangeOverride` only delegates to the placement engine when a `PlacementTarget` is set _and_ the naive frame is not contained in the visible bounds (`PopupPanel.cs:164-186`).

The second philosophical statement is an architectural verdict the authors pass on their own shared layer (`PopupPanel.Placement.cs:25-28`):

```csharp
// This is a base popup panel to calculate the placement near an anchor control.
// This class exists mostly to reuse the same logic between a Flyout and a ToolTip.
// This class should eventually be removed, and Uno should match WinUI's approach, where Flyout sets Popup.HorizontalOffset and VerticalOffset
// as well as Width and Height on FlyoutPresenter when it opens, and then allows the popup layouting to do its job.
```

The intended factoring is _consumer computes an offset, the surface just positions_. What shipped is a subclassable layout `Panel`. Six consumers subclass it or bypass it — the evidence is collected under spine dimension 16, _Shared infrastructure_, below.

The third is negative space made explicit. The whole viewport model collapses to one rect, and the function that is supposed to compute it accepts six parameters and ignores all of them (`FlyoutBase.cs:953-961`):

```csharp
internal static Rect CalculateAvailableWindowRect(bool isMenuFlyout, Popup popup, object placementTarget, bool hasTargetPosition, Point positionPoint, bool isFull)
{
#if HAS_UNO // This is a significantly simplified version of the WinUI logic.
    // UNO TODO: UWP also uses values coming from the input pane and app bars, if any.
    // Make sure of migrate to XamlRoot: https://docs.microsoft.com/en-us/uwp/api/windows.ui.xaml.xamlroot
    var xamlRoot = XamlRoot.GetImplementationForElement(popup);
    return xamlRoot.VisualTree.VisibleBounds;
#endif
}
```

> [!IMPORTANT]
> The single most useful thing this subject contributes to the catalog is its **negative list**. `Popup.ShouldConstrainToRootBounds` and `IsConstrainedToRootBounds`, `SystemBackdrop`, `ChildTransitions`, `PopupThemeTransition`, `MenuPopupThemeTransition` and `DesktopPopupSiteBridge` are all `[NotImplemented]` on every target. `ExclusionRect`, windowed-popup monitor math, RTL in the main engine and multi-monitor logic are commented out. `Popup.ActualPlacement` is public, has a change event and a real consumer — and is never assigned. That is a fairly precise measurement of what a strictly in-canvas implementation of the WinUI contract loses.

## How it works

**One surface, one ladder, one panel per popup.** `Popup.Child` is re-parented out of its logical position into a `PopupPanel` that is full-window by construction — "this Panel always take the whole screen for the dismiss layer, but it's content will not" (`PopupPanel.cs:90`). The child keeps a _logical_ parent pointer to the `Popup` (`SetLogicalParent`), so `DataContext` and resource inheritance still flow, while its _visual_ parent is the panel under `PopupRoot`. Re-parenting buys clipping escape for free — no ancestor scroll viewer or clip can ever affect a popup — and costs all scroll/clip awareness in the other direction, since no scroll container is ever consulted as a boundary either.

**Two lists, not one.** Paint order is `PopupRoot.Children` (open order). Ownership is a _separate_ `LinkedList` of `ManagedWeakReference` values built with `AddFirst`, i.e. most-recent-first (`PopupRoot.cs:216`). Escape, light dismiss, close-all and focus all query the second list, never infer order from the first.

**Six placement engines, one boundary.** Every one of them is pure `Rect` arithmetic over `XamlRoot.VisualTree.VisibleBounds`:

| Engine                                        | Owner                        | Shape of the algorithm                                         |
| --------------------------------------------- | ---------------------------- | -------------------------------------------------------------- |
| `CalculatePopupPlacement`                     | `PopupPanel.Placement.cs`    | 5-candidate ordered fallback loop, justification per candidate |
| `ToolTipPositioning.QueryRelativePosition`    | `ToolTipPositioning.cs`      | Win32-lineage side ladder with can-fit / place-exactly split   |
| `ToolTip.PerformPlacementInternal`            | `ToolTip.cs`                 | Cursor-relative, clip-instead-of-shrink last resort            |
| `CascadingMenuHelper.GetPositionAndDirection` | `CascadingMenuHelper.mux.cs` | Per-axis submenu solve with a "don't touch this axis" sentinel |
| `TeachingTip.DetermineEffectivePlacement`     | `TeachingTip.mux.cs`         | 13-mode availability mask, then a fixed permuted priority list |
| `ComboBox.DropDownLayouter`                   | `ComboBox.custom.cs`         | Total bypass via the `Popup.IDynamicPopupLayouter` hatch       |

**The shared loop.** The preferred side is looked up in a static table whose **last entry repeats the preferred side** (`PopupPlacementMode` is first decomposed into a major side and a justification), so the loop always terminates with a defined rect:

```csharp
{FlyoutBase.MajorPlacementMode.Top, new []
{
    FlyoutBase.MajorPlacementMode.Top,
    FlyoutBase.MajorPlacementMode.Bottom,
    FlyoutBase.MajorPlacementMode.Left,
    FlyoutBase.MajorPlacementMode.Right,
    FlyoutBase.MajorPlacementMode.Top // use preferred choice if no others fit
}},
```

**The acceptance test.** The entire collision test is full containment, expressed as a union equality (`PopupPanel.Placement.cs:277-284`):

```csharp
if (fits && RectHelper.Union(visibleBounds, finalRect).Equals(visibleBounds))
{
    break; // this placement is acceptable
}
```

There is no partial-overflow scoring and no best-effort ranking. After the loop, four one-sided rescues fire — but only when the rect is **entirely** past an edge (`finalRect.Bottom < visibleBounds.Top` and its three mirrors, `:297-331`). A rect that overflows partially is left overflowing, on purpose, per the philosophy quoted above.

## The analysis spine

### 1. Anchor model

**Algorithm.** Four anchor kinds, unified nowhere.

- **Element.** `Popup.PlacementTarget`, a `FrameworkElement` dependency property flagged `AffectsArrange`. The anchor rect is _not_ captured at open; it is re-derived on every arrange as `popup.PlacementTarget.GetBoundsRectRelativeTo(this)` (`PopupPanel.Placement.cs:115-125`), or `anchor.TransformToVisual(this).TransformPoint(default)` on the offset-only fast path.
- **Point.** `FlyoutShowOptions.Position`, transformed to root space, then `Math.Clamp`ed into the visible bounds at show time and stored as a plain `Point m_targetPoint` with an `m_isTargetPositionSet` flag (`FlyoutBase.cs:565`). That flag switches the whole strategy to `FlyoutBase.UpdateTargetPosition`.
- **Cursor.** Read _at placement time_ from the global static `PointerRoutedEventArgs.LastPointerEvent`, not captured at open. A keyboard-opened tooltip would therefore read a stale mouse point; the guard is to demote `PlacementMode.Mouse` to `Top` for non-pointer input modes rather than to latch the point.
- **Rect override.** `ToolTip.PlacementRect` (a nullable `Rect`), plus the `Slider` case passing an explicit target rect into `PerformPlacement`.

An escape hatch exists for anchors outside the managed tree: `PopupPanel.NativeAnchor` (Android / UIKit) returns a native view whose bounds are used instead (`PopupPanel.Placement.cs:112`).

Detached trigger vs. anchor is first-class for tooltips: `ToolTipService.PlacementTarget` is an attached property, so the _container_ subscribes the pointer events while the _placement target_ supplies the rect (`ToolTipService.cs:51`). Many-triggers-one-popup is resolved by ownership: `FlyoutBase.Target` is a `ManagedWeakReference`; `ShowAt` on a different target does `Hide(canCancel: false)` then reopens; `ShowAt` on the same target is a no-op.

Text-range / multi-rect anchoring is **absent**: the `TextElement` branch of `PerformPlacementInternal` is entirely commented out (`ToolTip.cs:796`), so a `Hyperlink` tooltip falls back to its containing element's rect.

**Where it lives.** Library code only; there is no platform primitive on the anchor path. Split across `PopupPanel.Placement.GetAnchorRect`, `PopupPanel.ArrangeOverride`, `FlyoutBase.ShowAtCore`, and `ToolTip.PerformNonMousePlacementWithPopup`.

**Degradation.** This dimension survives every constraint in the matrix. An anchor here is a `Rect` plus a way to re-query it — no OS window, no hover, no script, no sub-cell precision, no key release. In integer cells the element anchor is a cell rect and the point anchor is a cell coordinate. INFERENCE: the only part that is not already a plain comparable value is anchor **identity** — an object reference used both for re-query and for the "same target ⇒ no-op" check — and a stable integer handle would make the model value-typed end to end. Note that Uno's cursor anchor is re-read at placement time rather than latched; the tracking policy is therefore a per-anchor-kind decision in this subject, not a global rule.

### 2. Placement model

**Algorithm.** The 13-value `PopupPlacementMode` is decomposed into two orthogonal enums, `MajorPlacementMode {Top, Bottom, Left, Right, Full}` and `PreferredJustification {Center, Top, Bottom, Left, Right}` (`FlyoutBase.cs:1293`, `:1328`). Then, per candidate:

```text
for i in 0 .. 4:
    placement = PlacementsToTry[preferredMajor][i]
    pos       = anchor-edge origin for that side
                  ± PopupPlacementTargetMargin ± popup.HorizontalOffset/VerticalOffset
                  cross axis initially centred on the anchor
    if !FullPlacementRequested:
        (fits, crossPos) = TestAndCenterAlignWithinLimits(
              anchorPos, anchorSize, childSize, low, high, justification)
        pos[cross] = crossPos
    rect = Rect(pos, childDesiredSize clamped to visibleBounds)
    accept iff fits && Union(visibleBounds, rect) == visibleBounds
apply four "entirely outside an edge" rescues
```

`TestAndCenterAlignWithinLimits` (`PopupPanel.Placement.cs:347-407`) is the cross-axis solver and it fuses **shift** into justification: `Center ⇒ anchorPos + 0.5*(anchorSize - controlSize)`, `Top`/`Left ⇒ anchorPos`, `Bottom`/`Right ⇒ anchorPos + anchorSize - controlSize`, then clamped into `[lowLimit, highLimit - controlSize]`. It returns `fits = false` — and pins `controlPos = lowLimit`, i.e. the **start edge** — only when `(highLimit - lowLimit) > controlSize` fails, that is when the overlay is at least as large as the axis.

Two properties of this loop are worth naming:

1. **Only the major axis is permuted.** Justification is re-applied per candidate, so a `TopEdgeAlignedLeft` that falls back to `Bottom` is still left-aligned. Flip preserves edge alignment for free.
2. **Fallback order is flip-first, then perpendicular.** `Top → [Top, Bottom, Left, Right, Top]`; `Left → [Left, Right, Top, Bottom, Left]`.

`Full` placement is separate: it centres inside the first of three areas that fits — the visible bounds, the region below the status bar, then the whole surface — via a local `FindOptimalOffset` (`PopupPanel.Placement.cs:218-233`).

Positioned-at-point popups use a **different** overflow strategy. `FlyoutBase.UpdateTargetPosition` flips back over the point (`offset -= min(size, offset)`) instead of pinning to the viewport edge (`FlyoutBase.cs:1202-1275`). That is precisely the context-menu-vs-picker distinction: a context menu near the right edge should open leftwards _from_ the click point, not slide left _over_ it.

Offsets are a virtual `PopupPlacementTargetMargin` (0 on the base panel, 5 on `FlyoutBasePopupPanel`, `FlyoutPopupPanel.cs:37`) plus `Popup.HorizontalOffset` / `VerticalOffset`. Touch menu flyouts additionally get `preferTopPlacement` (`verticalOffset -= presenterHeight`) with a fall-back-to-down when opening up would clip.

**Absent.** Viewport padding, caller-supplied boundaries, multi-monitor, IME/soft-keyboard avoidance (see the `CalculateAvailableWindowRect` stub above). RTL is read in `UpdateTargetPosition` and in `CascadingMenuHelper`, but the `PopupPanel` engine has none, and `ToolTip` hardcodes `bIsRTL = false` with every RTL branch commented out. Safe-area **is** honoured, because `VisibleBounds` on Android derives from `SystemBars | DisplayCutout` insets (`NativeWindowWrapper.Android.cs:125`) — but the soft keyboard is not in that inset set; `InputPane` instead pads a `ScrollContentPresenter` (`InputPane.Android.cs:23`).

**Where it lives.** Library code, six places: `PopupPanel.Placement.cs`, `FlyoutBase.cs`, `ToolTipPositioning.cs`, `CascadingMenuHelper.mux.cs`, `TeachingTip.mux.cs`, `ComboBox.custom.cs`.

**Degradation.** Fully portable — `double` arithmetic over rects, with one substrate call (the anchor transform). With no OS window nothing changes; nothing here reads hover, script, or key release. With no sub-cell precision, the two halvings (`halfAnchorWidth`, `halfChildWidth`) need a rounding convention that Uno's doubles silently absorb: a cell toolkit must fix a rule, or centred placements jitter by one cell as the anchor grows and shrinks. And the soft-keyboard inset, which Uno does not model at all, has to become an explicit input to the boundary rect rather than a discovery.

### 3. Collision & geometry engine

**Algorithm.** Overflow detection exists; **clipping-ancestor discovery does not**. Because the child is re-parented under `PopupRoot`, the clipping boundary is always the one visible-bounds rect. There are no observers and no polling anywhere in the `Popup`/`Flyout` path. Recomputation is driven purely by layout invalidation:

- `PlacementTargetProperty` is `AffectsArrange`; `DesiredPlacementProperty` likewise (`Popup.cs:234`).
- `HorizontalOffset`/`VerticalOffset` are `AffectsMeasure` and additionally call `PopupPanel.InvalidateMeasure`.
- `XamlRoot.Changed` calls `InvalidateMeasure` (`PopupPanel.Placement.cs:74`).
- `FlyoutBase` subscribes the presenter's `SizeChanged` to re-run `SetPopupPosition` (`FlyoutBase.cs:192`).

The measure/arrange path is: measure the child against `min(availableSize, visibleBounds)`; compute the naive frame from anchor origin + offsets + measured size; if the flyout is not a managed date/time picker **or** the naive frame is not contained (`MathHelpers.DoesRectContainRect`) and `PlacementTarget != null`, delegate to `PlacementArrangeOverride`. `FrameworkElement.GetMaxSize()` is honoured and `Width`/`Height` are ignored, with a comment noting this matches UWP (`PopupPanel.Placement.cs:92`).

Only `TeachingTip` tracks a **moving anchor**, via `EffectiveViewportChanged` on both the target and itself, gated on `m_tipFollowsTarget`, plus a `XamlRoot.Changed` handler that re-checks position inside `QueueCallbackForCompositionRendering` (`TeachingTip.mux.cs:1612`, `:1641`). The consequence for everything else is blunt: **a flyout does not follow its anchor when the anchor scrolls, and is not dismissed either.**

Transforms: the anchor-to-panel conversion is a full `GeneralTransform`, so ancestor scale and rotation are respected for the origin, but the resulting rect is always axis-aligned. `Popup.RenderTransform` has to be manually mirrored onto the panel and re-materialised as a `MatrixTransform`, because the child is not a visual child of the `Popup` — and it is treated as affecting **arrange**, not merely render, since the anchor point is computed in `ArrangeOverride` (`Popup.cs:72`).

One real layout-shift bug is worked around by arranging twice: `CascadingMenuHelper.OnPresenterSizeChanged` mutates `HorizontalOffset` _during_ the first `ArrangeElement` call, so a second arrange runs (`PopupPanel.cs:184-204`).

**Cost.** O(5) rect constructions per arrange, one dictionary lookup, no allocation beyond slicing a `Memory` value.

**Where it lives.** Library code plus the framework's layout-invalidation kernel (`FrameworkPropertyMetadataOptions`). No compositor, no accessibility API, no OS involvement.

**Degradation.** The arithmetic generalises completely. What does **not** generalise is the reliance on a retained layout system to decide _when_ to re-run. An immediate-mode toolkit recomputes every frame anyway, which is strictly better here — it closes the scroll-tracking gap Uno has, and the two-pass arrange workaround disappears with it. With no sub-cell precision the transform reduces to an integer translation; with no OS window nothing in this dimension changes at all.

### 4. Arrow / caret geometry

**Algorithm.** The `Popup`/`Flyout`/`ToolTip` primitive has **no arrow**, matching WinUI's tail-less flyouts. The only nod to one is `PopupPlacementTargetMargin` (5 px on flyouts, 0 on the base panel).

The single arrow implementation is `TeachingTip`'s _tail_, and it is template geometry rather than data: a `Polygon` template part (`m_tailPolygon`) inside a 4×4 `Grid` (`m_tailOcclusionGrid`) whose dimensions are read **back** from live layout:

- `TailLongSideActualLength = max(polygon.ActualHeight, polygon.ActualWidth)` (`TeachingTip.mux.cs:2409`)
- `TailShortSideLength = min(...) - s_tailOcclusionAmount` (`:2424`)
- `MinimumTipEdgeToTailCenter = col0.ActualWidth + col1.ActualWidth + longSide/2` (`:2446`)
- `MinimumTipEdgeToTailEdgeMargin = col1.ActualWidth + occlusion`

Those measurements feed placement directly: `tipHeight = contentHeight + TailShortSideLength()` (`:1991`), and the corner-constrained modes (`LeftTop`, `RightBottom`, …) are knocked out of the availability mask when `contentHeight - MinimumTipEdgeToTailCenter()` exceeds the space around the target — which _is_ the corner constraint.

Auto-centering, corner constraint, hiding (`TeachingTipTailVisibility`, also forced off for untargeted tips) and border-awareness (the occlusion amount overlaps the tail into the border so the seam is hidden) are all present. Detachment is not. The transform origin is derived from the tail: `UpdateTail` sets `CenterPoint` on the occlusion grid per effective placement across 14 cases (`:319`, `:376`) — for example `Top ⇒ (width/2, height - lastRowHeight)`, `TopLeft ⇒ (col0 + col1 + 1, height - lastRowHeight)`, `Left ⇒ (width - lastColumnWidth, height/2)`. The `+1` in the corner cases is a literal in the source.

**Where it lives.** Library code, but expressed through the XAML template: the arrow's size is _discovered_ from `ActualWidth`/`ActualHeight` of template parts rather than declared.

> [!WARNING]
> Reading arrow geometry back out of live layout is the anti-pattern this dimension contributes. It makes the arrow's cost a measured quantity that placement then depends on, which forces the ordering (template applied → measured → placeable) and makes the whole relationship untestable without a layout pass.

**Degradation.** In a cell grid an arrow is not a polygon. INFERENCE: the natural cell-space form is a **border-glyph substitution** — one cell of the popup's border run replaced by a directional glyph (`▲ ▼ ◀ ▶`, or a box-drawing tee `┬ ┴ ┤ ├`) — under which `TailShortSideLength ≡ 0` (the arrow consumes no extra main-axis space) and the corner constraint reduces to `cornerRadius + 1` cell. Arrow geometry then becomes data — a side, an offset along that side in cells, and a visibility bit — rather than something measured. With no sub-cell precision the arrow can only land on an integer cell along the edge, so "point at the anchor centre" becomes `clamp(anchorCentreCell, popupStart + 1, popupEnd - 2)`. Under a script-free HTML tier the arrow is a static pseudo-element that cannot re-point, so its side must be baked at emit time from the placement chosen at emit time; see [`./features-people-forget.md`](./features-people-forget.md) and [`./sparkles-baseline.md`](./sparkles-baseline.md).

### 5. Trigger semantics

**Algorithm.** Tooltip triggers are `PointerEntered` (any pointer type — Uno does **not** convert touch to long-press) and `GotFocus`, where the focus path opens only when `GetRealFocusStateForFocusedElement() == Keyboard`, or `== Programmatic` **and** `InputManager.GetWasUIAFocusSetSinceLastInput()` — an explicit assistive-technology case, commented "If the source of a programmatic focus was UIA, we should show the tooltip" (`ToolTipService.cs:246`).

Flyout triggers are programmatic `ShowAt` / `ShowAttachedFlyout`, or the `ContextRequested` class handler. Context-menu triggers are centralised in `ContextMenuProcessor`: `Shift+F10`, `VirtualKey.Application` and `VirtualKey.GamepadMenu` for keyboard/gamepad (`:46`); right-click through the pointer pipeline; touch through the gesture recognizer's `Holding`, with a 500 ms extra delay inserted **only** when the element `IsDraggableOrPannable`, so a pan can win the gesture (`:109-126`).

Pointer type is captured once at open — `m_inputDeviceTypeUsedToOpen = contentRoot.InputManager.LastInputDeviceType` (`FlyoutBase.cs:552`) — and then drives `InputDevicePrefersPrimaryCommands`, the tooltip offsets, and `MenuFlyout`'s `preferTopPlacement`. Submenu triggers are device-split: mouse/pen `PointerEntered` starts the delay timer; touch shows on `PointerReleased`, never on enter (`CascadingMenuHelper.mux.cs:226`); `Enter`/`Space`/`Right` open from the keyboard.

**Race handling is the standout.** Four mechanisms compose:

1. **Frame-identity dedupe.** `PointerEntered` is raised on every element in the hit chain, innermost to outermost, within one input frame. Each event carries a `FrameId`, and the service drops any whose `FrameId` matches the last one it acted on, so only the innermost owner opens a tooltip (`ToolTipService.cs:273-288`):

   ```csharp
   // Multiple elements can all receive the same PointerEntered at once (from inner-most to outer-most).
   // In this case, the inner-most one is the only one that should be shown,
   // so we are dropping any subsequent events from this frame-id.
   if (e.FrameId == m_LastEnteredFrameId) return;
   ```

2. **A process-wide singleton** `m_CurrentToolTip`, whose opener first closes the incumbent (`:97`).
3. **An early return** when the tooltip is already open, so re-entering the same owner does not restart anything.
4. **Parent-timer cancellation:** entering a child submenu cancels the _parent's_ pending close timer before starting the child's open timer (`CascadingMenuHelper.mux.cs:112-131`).

**Where it lives.** Library code. `ToolTipService` attaches static handlers per owner on `Loaded` and detaches on `Unloaded`; `ContextMenuProcessor` is per `ContentRoot`; `CascadingMenuHelper` is per menu item; `Holding` comes from `UIElement`'s gesture recognizer.

**Degradation.** With **no hover** (Android) the entire `PointerEntered` branch is dead and only press / long-press survives — Uno acknowledges this by defaulting `FeatureConfiguration.ToolTip.UseToolTips` to `true` only on WASM and Skia (`FeatureConfiguration.cs:687-690`). With **no key release**, the `Space`/`Enter` activate-on-release branch of `MenuFlyoutKeyPressProcess.KeyUp` cannot run and activation has to move to key-down; Uno's pointer-release-driven touch submenu path is unaffected, since pointer release is a separate capability. Under **static HTML** the only triggers are `:hover`, `:focus-within` and `:checked` / `details`, so programmatic opens, context menus and pointer-type distinction all vanish and the dedupe becomes structural (CSS nesting) rather than temporal. The frame-id idea itself is the portable part: it needs only that events carry a monotonically increasing sequence integer, which a frame-driven toolkit already has.

### 6. Timing

**Algorithm.** Tooltips share **one static `DispatcherTimer` pair across the whole app**. Open delay is `FeatureConfiguration.ToolTip.ShowDelay = 1000` ms; maximum display duration is `ShowDuration = 5000` ms, after which `OnCloseTimerTick` force-closes (`FeatureConfiguration.cs:692`, `:694`; `ToolTipService.cs:116`, `:141`, `:160`). The open sequence is:

```text
OnPointerEntered:  if (e.FrameId == m_LastEnteredFrameId) return
                   if (tip.IsOpen) return
                   m_LastEnteredFrameId = e.FrameId
                   OpenToolTipImpl(tip, isTouch ? Touch : Mouse)

OpenToolTipImpl:   if (m_CurrentToolTip != null) CloseToolTipImpl(m_CurrentToolTip)
                   s_lastEnterInputMode = mode
                   m_CurrentToolTip = tip
                   m_OpenTimer.Start(); m_CloseTimer?.Stop()
```

There is **no warm-up, no cool-down / skip-delay, and no group or provider concept** beyond the singleton. Every tooltip pays the full second, including when the pointer moves between adjacent toolbar buttons.

Submenus: `m_subMenuShowDelay` defaults to `DefaultMenuShowDelay = 400` ms (`CascadingMenuHelper.h.mux.cs:14`), and the _same_ interval serves both the open timer and the close timer. On Windows, WinUI reads `HKCU\Control Panel\Desktop\MenuShowDelay`; in Uno that block is `#if !HAS_UNO` (`CascadingMenuHelper.mux.cs:62`), so the constant is the value. Context menu on holding adds 500 ms only for draggable/pannable elements. `TeachingTip` has no timing at all — it is dismissed explicitly.

**Where it lives.** Library code, on `DispatcherTimer` (the framework's frame-driven timer). No OS timer, no compositor.

**Degradation.** Timers are the first thing to disappear. On a **static-HTML** tier there are none: the overlay collapses to instant-on-hover / instant-off, i.e. `showDelay = 0`, `closeDelay = 0`, `maxDuration = ∞`, and the machine reduces to two CSS states. With **no hover** the warm-up is meaningless and only the maximum duration and explicit dismissal survive. On a **recording canvas** the machine must be driven by an injected clock so that "after 1000 ms it opens" is assertable without wall time — which Uno's design cannot do, since the timers are static and its own runtime tests sleep real time (`Task.Delay(ShowDelay + 500)`).

INFERENCE: what Uno _lacks_ here is as instructive as what it has. Sketching the shape its gaps imply — states `{Idle, WarmingUp(t), Open, CoolingDown(t), Closing}`, with `Idle --enter--> Open` immediately when a group cool-down token is live (skip-delay), `Open --exit--> CoolingDown` so travel to the content is possible, and every timer cancellable and idempotent — the singleton gives mutual exclusion but not the skip, and its staticness is exactly why `CloseToolTipImpl` has to branch on whether the tooltip it was handed _is_ the current one.

### 7. Interactive hover

**Algorithm.** There is **no safe polygon, no pointer bridge, no trajectory heuristic and no debounce** anywhere in the source read here. Menu-aim is approximated by three cheap mechanisms acting together:

1. **A 400 ms close delay** (`DelayCloseSubMenu`) — the entire travel budget.
2. **A geometric overlap.** `m_subMenuOverlapPixels = 4` (`CascadingMenuHelper.h.mux.cs:21`), so the child menu is positioned to overlap the parent presenter by 4 px on the flip side (`subMenuPosition.X = ownerPosition.X - presenterWidth + overlap`, or `+ ownerWidth - overlap` on the normal side, `:727`). The diagonal traverse lands _on_ the child rather than in a gap.
3. **A hit test at the exit point** instead of a region. On `PointerExited` — mouse only, and only when the parent is not itself a submenu (`:145`, gate at `~:168`) — it calls `FindElementsInHostCoordinates(exitPoint, owner, includeAllElements: true)`, then repeats it rooted at the submenu presenter; if neither the owner nor the presenter appears in either hit list, the close timer starts:

   ```csharp
   // To close the sub menu, the pointer must be outside of the opened chain of sub-menus.
   if (!isOwnerOrSubMenuHit)
   {
       DelayCloseSubMenu();
       args.Handled = true;
   }
   ```

Entering a child cancels the parent's close timer (`parentOwner.CancelCloseSubMenu()`). Tooltips are non-interactive **by construction**: their `Popup` has `IsLightDismissEnabled = false` (`ToolTip.cs:46`), so `PopupPanel.IsViewHit()` returns false and the panel is hit-invisible — there is no travel path into tooltip content at all. Nested surfaces are handled by ownership recursion (`ISubMenuOwner.CloseSubMenuTree` / `ClosePeerSubMenus`), not by geometry.

**Where it lives.** Library code (`CascadingMenuHelper`), over the framework hit-test service.

**Degradation.** Stated in whole cells: Uno's substitute costs one 400 ms timer plus `ceil(4 / cellWidth)` cells of parent/child overlap — one cell at a typical cell advance. In a cell grid that overlap is free: position the submenu so its left border column coincides with the parent's right border column. This is Uno's answer, not a demonstration that a corridor region is unnecessary in general; see [`./comparison.md`](./comparison.md) for the corridor treatments other subjects ship. With **no hover** the dimension is inapplicable — submenus open on release and close on outside press. With **no key release** the keyboard path (`Right` opens, `Left`/`Escape` closes) is unaffected, being entirely key-down. On a recording canvas the timer must be injectable.

### 8. Dismissal

**Handled.**

| Cause                       | Mechanism                                                                                                                                                                    |
| --------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Escape                      | `PopupRoot.OnKeyDown` closes the topmost popup matching `PopupFilter.LightDismissOrFlyout` (`:251-258`); `Popup.OnKeyDown` also handles the directly-focused case            |
| Outside press               | `PopupPanel.OnPointerPressed`, but only when `args.OriginalSource == this` (`:254-276`)                                                                                      |
| Window deactivation         | `PopupRoot.OnWindowActivated → CloseLightDismissablePopups`, suppressible by `FeatureConfiguration.Popup.PreventLightDismissOnWindowDeactivated`                             |
| Resize / scale / visibility | `XamlRoot.Changed → CloseLightDismissablePopups`                                                                                                                             |
| Focus moved outside         | `FlyoutBase.OnPopupLostFocus` walks up from the newly focused element and hides unless a `PopupRoot` was crossed or the popup ancestor is light-dismiss / a submenu (`:817`) |
| System back button          | `Popup` implements `IBackButtonListener`, registered only when `ShouldDismiss(BackPress)`                                                                                    |
| Parent closing              | `FlyoutBase.Hide` cascades to the next flyout in the static open-flyout list; `RemoveFromOpenFlyouts` dispatches a follow-up `Hide` on the new head                          |
| Child opening               | `EnsureCloseExistingSubItems` on submenu open                                                                                                                                |
| Owner gone                  | Owner `Unloaded`, `Visibility != Visible`, `PointerCanceled` and `PointerCaptureLost` all close tooltips                                                                     |

**Not handled.** Scroll, anchor moved, anchor hidden, anchor removed from the tree, navigation.

**Algorithm.** The sweep captures the successor _before_ acting, because the action mutates the list it is walking (`PopupRoot.cs:70-89`):

```csharp
var node = _openPopups.First;
while (node != null)
{
    var next = node.Next;
    if (node.Value.TryGetTarget<Popup>(out var popup) && popup.IsLightDismissEnabled)
    {
        if (popup.AssociatedFlyout is { } flyout) { flyout.Hide(); }
        else { popup.IsOpen = false; }
    }
    node = next;
}
```

`CloseTopmostPopup(filter)` takes the first popup in most-recent-first order matching the filter, calls `OnClosing(ref cancel)`, and returns `false` if cancelled. Escape reports `didClose` as `args.Handled`, so a cancelled close leaves `Escape` unhandled — a divergence a runtime test pins between the Skia/WASM and native heads (`Given_Popup.cs:450 When_Escape_Canceled`).

Two structural notes. Escape must be handled at `PopupRoot`, and the source says why (`PopupRoot.cs:248-250`):

```csharp
// The ESC key closes the topmost light-dismiss-enabled popup.
// Handling must be done by CPopupRoot because the popups reparent their children to be under CPopupRoot,
// so routed events from beneanth the popups route to CPopupRoot and skip the popups themselves.
```

And the WinUI generalisation is present as **dead code**: `DismissalTriggerFlags {CoreLightDismiss, WindowSizeChange, WindowDeactivated, BackPress}` exists and `Popup.ShouldDismiss` reads `m_dismissalTriggerFlags`, but a grep over `src/Uno.UI`, `src/Uno.UWP`, `src/Uno.UI.Composition`, `src/Uno.UI.Runtime.Skia` and the two test projects found nothing that assigns that field, so `ShouldDismiss` always falls through to `IsLightDismissEnabled`. (Other projects in the repository were not searched.)

**Where it lives.** Library code split across `PopupRoot` (Escape, window activation, `XamlRoot` change), `PopupPanel` (pointer), `FlyoutBase` (focus loss, cascade) and `Popup.Base` / `Popup.mux` (back button, `ShouldDismiss`).

**Degradation.** Nothing here needs an OS window. "Window deactivation" has no analogue on a terminal or a recording canvas and simply never fires; on Android it maps to activity pause. Back-key dismissal is already modelled and is the Android requirement. With **no key release**, Escape-on-key-down is what Uno already does. Under **static HTML** dismissal degrades to pointer-away and blur — Escape and outside-press are unavailable, which is why a script-free overlay has to be non-modal and non-destructive.

> [!IMPORTANT]
> The reparenting insight transfers directly to any toolkit whose events route against the last painted frame with the overlay as a sibling of content: Escape must be handled by the **overlay layer**, not by the popup widget.

### 9. Focus

**Algorithm.** Four surfaces, four genuinely different policies:

- **Tooltip** — never takes focus and never restores it. `Popup.OnIsOpenChangedPartial` saves/restores focus only when `IsLightDismissEnabled || AssociatedFlyout != null`, and a tooltip's popup satisfies neither.
- **Plain popup** — save/restore only when light dismiss is on (`Popup.Base.cs:99`).
- **Flyout** — `FlyoutShowMode.Standard ⇒ m_shouldTakeFocus = true`; `Transient` and `TransientWithDismissOnPointerMoveAway ⇒ false`; `Auto` is normalised to `Standard` (`FlyoutBase.cs:667`).
- **Dialog** — `ContentDialog` is the only truly blocking surface, and only because `ContentDialogPopupPanel` overrides `IsViewHit() => true` (`:107`).

The subtle part is _which_ focus state is taken. On presenter `Loaded` (`FlyoutBase.cs:133-159`):

```text
allowFocus = AllowFocusOnInteraction (inherited from Target if the target also allows)
state      = contentRoot.FocusManager.GetRealFocusStateForFocusedElement()
if (m_shouldTakeFocus && state != Unfocused
    && presenter.AllowFocusOnInteraction && flyout.AllowFocusOnInteraction)
    if (!presenter.Focus(state)) popup.Focus(state)
```

So a mouse-opened flyout gets `Pointer` focus and a keyboard-opened one gets `Keyboard` focus, and nothing is focused at all when the app was `Unfocused`.

**Containment, not a trap.** `FocusManager.GetNextTabStop` walks up; when no `Control` ancestor is found before the popup boundary, `GetRootOfPopupSubTree` becomes the scope and Tab **cycles** inside the popup subtree, wrapping to the first focusable element (`FocusManager.mux.cs:881`, `UIElement.mux.cs:510`). `GetFirstFocusableElement` prefers the topmost light-dismiss-or-flyout popup over the page (`:735`). Because containment is _discovered_ rather than installed, nothing has to be un-trapped on close.

**Restoration.** `_lastFocusedElement` is a weak reference plus a saved `FocusState`. On Skia, `Pointer` focus is upgraded to `Keyboard` when restoring into an element inside an opened text flyout, so the selection highlight survives (`Popup.Base.cs:138-151`).

**Gaps.** `PopupRoot.GetOpenPopupForElement` is `[NotImplemented]` and returns `null` with "TODO Uno: Implement for proper focus support" (`PopupRoot.mux.cs:24`); `ClearWasOpenedDuringEngagementOnAllOpenPopups` and `GetPopupChildrenOpenedDuringEngagement` are stubs, so gamepad-engagement focus semantics are absent.

**Where it lives.** Library code only: `FocusManager.mux.cs` (the ported WinUI focus kernel), `Popup.Base.cs`, `FlyoutBase.cs`. No platform focus API is consulted for popup scoping.

**Degradation.** All of it survives — focus here is a pure data structure over the widget tree. With **no OS window** the window-deactivation path is inert. On a terminal the `Pointer`-vs-`Keyboard` distinction still matters, because it decides whether a focus ring paints; propagating the _existing_ focus state into the popup rather than hardcoding `Programmatic` is the transferable trick. Under **static HTML**, `:focus-within` is the only containment mechanism and cycling is impossible, so a script-free overlay must not claim focus. With **no hover** (Android) focus follows touch and the tooltip case is moot.

### 10. Layering & portals

**Algorithm.** Exactly one surface and a fixed ladder of root layers inside it. `VisualTree.AddRoot` installs `PublicRootVisual`, `FullWindowMediaRoot`, `PopupRoot`, `FocusVisualRoot` in that order (`VisualTree.cs:255`), each with a `Canvas.ZIndex` constant defined as an arithmetic chain (`:36-39`, plus `FocusVisualZIndex = int.MaxValue - 99` and `TextBoxTouchKnobPopupZIndex = FocusVisualZIndex + 1` in `VisualTree.uno.cs:18`).

```csharp
private const int VisualDiagnosticsRootZIndex = UnoTopZIndex - 1;
private const int ConnectedAnimationRootZIndex = VisualDiagnosticsRootZIndex - 1;
private const int PopupZIndex = ConnectedAnimationRootZIndex - 1;
private const int FullWindowMediaRootZIndex = PopupZIndex - 1;
```

`OpenPopup` is `PopupRoot.Children.Add(popupPanel)` plus `RegisterOpenPopup` (which sweeps dead weak references, then `AddFirst`), returning an `IDisposable` that removes both (`PopupRoot.cs:169`, `:216`). `PopupRoot.ArrangeOverride` arranges every child panel at `(0, 0, finalSize)` — the panel positions its own content.

**Two lists.** The paint list is `Children` (open order). The ownership list is the most-recent-first weak `LinkedList`, filtered by `GetTopmostPopup` over `{LightDismissOnly, LightDismissOrFlyout, All}`; a runtime test pins the ordering (`Given_Popup.cs:510`).

**Submenus are not nested popups.** Each `MenuFlyoutSubItem` creates its own `Popup` with `IsSubMenu = true` and `IsLightDismissEnabled = false`, and the tree is maintained by `ISubMenuOwner` links rather than by containment.

**Public vs. implementation.** `PopupPanel` and `PopupRoot` are `internal`, but `Popup.PopupPanelProperty` is a **public** dependency property whose value type is internal (`Popup.cs:141`) — a leak. `ShouldConstrainToRootBounds`, `SystemBackdrop` and `ChildTransitions` are public and `[NotImplemented]`; `DesktopPopupSiteBridge` — WinUI's OS child-window popup surface — is `[NotImplemented]` on all targets, and there is no popup code at all in the Skia X11/Win32 hosts.

**Where it lives.** Library code plus the framework's `Canvas.ZIndex` sort. No compositor, no OS window, no stacking context. Android may substitute a native `PopupWindow`, but it is `MatchParent` × `MatchParent` hosting the same panel (`Popup.Android.cs:36`), so it adds only outside-touch dismissal and focus.

**Degradation.** This dimension is already at the floor: "front is later in the display list" needs nothing from any substrate. INFERENCE: for a toolkit that also has exactly one surface, the transferable structure is the **separation of the paint list from the ownership list** — the second is what Escape, light dismiss, focus and close-all all query, and it must not be inferred from paint order. The thing to avoid is the public-property-of-internal-type leak: the overlay layer should stay an implementation detail behind a value-typed handle. Compare [`./sparkles-baseline.md`](./sparkles-baseline.md) and the toolkit's own [containers spec](../../specs/ui/containers.md).

### 11. Modality

**Algorithm.** Modality is not a primitive; it is emergent from two booleans.

**(1) The overlay panel's `Background` is always non-null** — `Transparent` when no scrim is wanted, `LightDismissOverlayBackground` when `LightDismissOverlayMode == On`. `Auto` returns `false` on every platform, so the scrim is opt-in only (`Popup.cs:46`, `:349-361`):

```csharp
// In all cases, we need the background to not be null so that it can receive pointer events, or else it
// will fail hit-testing.
```

**(2) `PopupPanel.IsViewHit()` returns `Popup.IsLightDismissEnabled`** (`:291`), and in the managed hit-test coercion a false `IsViewHit()` maps to `HitTestability.Invisible` for the panel **while its children remain hit-testable** (`UIElement.Pointers.Managed.cs:56-102`):

```text
CoerceHitTestVisibility:
    parent Collapsed                                        -> Collapsed
    !IsLoaded | !IsHitTestVisible | !Visible | !IsEnabled    -> Collapsed (children too)
    !IsViewHit()                                            -> Invisible (children still testable)
    otherwise                                               -> Visible
```

A non-light-dismiss popup is therefore fully click-through except for its own content — passthrough for free, and the reason tooltips can never be interactive. `ContentDialog` overrides `IsViewHit() => true` to block pointers _without_ light-dismissing, commented "the ContentDialog backdrop (aka smoke layer) doesn't light-dismiss, but does block pointer interactions" (`ContentDialogPopupPanel.cs:105`). `CommandBar` is special-cased in **two** places (`OnPointerPressed` and `IsViewHit`) because it uses `IsSticky` rather than `IsLightDismissEnabled`.

**A targeted hole.** `OverlayInputPassThroughElement` (`FlyoutPopupPanel.cs:39-84`) re-runs the hit test with the whole `PopupRoot` **excluded** from testability, requires the hit element to be a descendant of the pass-through element **and** the pass-through element to be an ancestor of the flyout, then re-routes the live pointer args via `InputManager.Pointers.ReRoute`. The double ancestry check is what stops the hole from becoming a general input leak.

**Keyboard blocking: none.** `PopupRoot` handles only Escape, so keystrokes reach whatever has focus.

**Accessibility bit.** `PopupAutomationPeer.IsModal` returns `IsOpen` (`:76`) — every open popup claims modality — and the `IWindowProvider` pattern is exposed only for light-dismiss or submenu popups (`:130`).

**Where it lives.** Library code: `Popup.GetPanelBackground`, `PopupPanel.IsViewHit`, `UIElement.Pointers.Managed.CoerceHitTestVisibility`, `FlyoutPopupPanel.OnPointerPressedDismissed`, `PopupAutomationPeer`.

**Degradation.** Everything here is expressible in a flat hit list. "Invisible, but children still testable" is precisely "do not add this rect to the hit list, but do add its children" — one bit per display-list entry, yielding passthrough, light dismiss and modal blocking from the same mechanism. The scrim is one fill rect. Keyboard blocking has to be added deliberately, since Uno's absence of it is a defect surface, not a simplification. Note especially that Uno **never grabs the pointer**: the "grab" is a full-surface catcher rect plus hit order, so this dimension needs no OS grab, no hover, no script and no sub-cell precision. Whether a translucent fill actually dims foreground glyphs is a per-backend question this subject does not answer; see [`./sparkles-baseline.md`](./sparkles-baseline.md).

### 12. Adaptive presentation

**Algorithm.** Adaptation is decided at **three layers with no single owner**, which is itself the finding.

- **Build / feature layer.** `FeatureConfiguration.ToolTip.UseToolTips` defaults to `true` only on `__WASM__` and `__SKIA__` (`FeatureConfiguration.cs:687-690`), so on native Android/iOS heads tooltips are silently disabled wholesale and `RegisterToolTip` early-returns. `FeatureConfiguration.Popup.ConstrainByVisibleBounds` defaults `true` on native heads and **false** on Skia (`:391`), so the same flyout is clipped to the safe area on one head and allowed under the status bar on another — a runtime test pins both behaviours (`Given_Popup.cs:363`). `FeatureConfiguration.Popup.UseNativePopup` exists only on Android.
- **Control layer.** `FlyoutBase.UseNativePopup = !FeatureConfiguration.Style.UseUWPDefaultStyles` (`:169`); `MenuFlyout`, `DatePickerFlyout` and `TimePickerFlyout` have native iOS/Android variants; `PopupPanel.ArrangeOverride` special-cases `isFlyoutManagedDatePicker` to skip the placement engine entirely (`:164`); `PickerFlyoutBase` deliberately uses a plain `PopupPanel` rather than `FlyoutBasePopupPanel`.
- **Input layer.** `m_inputDeviceTypeUsedToOpen` sets `InputDevicePrefersPrimaryCommands` (touch/pen ⇒ `true`, which makes `CommandBarFlyout` show a primary toolbar instead of a list, `:690`), makes `MenuFlyout` prefer top placement on touch so the finger does not cover the menu, and selects the tooltip offset (keyboard 12, mouse 20, touch 44 — `ToolTip.cs:26`).

The touch menu adjustment is a two-step with a fallback (`FlyoutBase.cs:1043`):

```csharp
preferTopPlacement = (m_inputDeviceTypeUsedToOpen == Touch) && isMenuFlyout;
if (preferTopPlacement) verticalOffset -= presenterSize.Height;
// …later:
if (preferTopPlacement && verticalOffset < availableWindowRect.Y) verticalOffset += presenterSize.Height;
// "If opening up would cause the flyout to get clipped, we fall back to opening down"
```

**Not present.** No popover-to-sheet conversion, no hover-tooltip-to-long-press conversion (touch simply produces a hover-mode tooltip with a bigger offset), no keyboard-driven relocation.

**Where it lives.** Split three ways — compile-time feature flags, control-level native substitution, and the input manager's `LastInputDeviceType`.

**Degradation.** With **no hover** the hover-triggered surface has to be replaced _structurally_ (long-press to menu) rather than re-tuned; Uno instead disables tooltips wholesale on those heads. The touch offset trick — 44 px of clearance so the finger does not cover the surface, roughly 3–4 cells — is the part with a straightforward cell-space analogue. INFERENCE: the `ConstrainByVisibleBounds` split is the warning worth carrying forward — a per-backend feature flag that silently changes the _boundary rect_ makes the same placement call answer differently per target, which argues for passing the boundary in rather than discovering it. See [`../platform-ui-guidelines/index.md`](../platform-ui-guidelines/index.md) and [`../window-system-integration/index.md`](../window-system-integration/index.md) for the platform side of this.

### 13. Accessibility

**Algorithm.** Roles come from `AutomationPeer`s, not from the popup primitive. `PopupAutomationPeer` reports `AutomationControlType.Window` (`:32`), names itself from the localized `UIA_POPUP_NAME`, exposes its child's peer as its only child, and implements `IWindowProvider` (`InteractionState` Running/Closing, `IsModal = IsOpen`, `IsTopmost = IsOpen`, `Close()`) — but only when the popup is light-dismiss or a submenu:

```text
ShouldExposeWindowPattern() => popup.IsLightDismissEnabled || popup.IsSubMenu
GetChildrenCore()           => child.GetOrCreateAutomationPeer()
                               ?? GetAutomationPeersForChildrenOfElement(child)
```

`ToolTip` has a `ToolTipAutomationPeer`. There is **no described-by wiring**: `ToolTipService` does not annotate the owner's peer with the tooltip text, so the tooltip is exposed as a separate surface rather than as the owner's description. The keyboard-accelerator tooltip is a distinct attached property (`KeyboardAcceleratorToolTipObject`), with the public `ToolTip` winning in `GetActualToolTipObject` (`ToolTipService.mux.cs:55`).

Measured against WCAG 1.4.13:

| Requirement | Verdict in this source                                                                                                                                                                                                 |
| ----------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Hoverable   | **Fails by construction** — the tooltip popup is not light-dismiss, so its panel is hit-invisible and its content unreachable                                                                                          |
| Persistent  | **Fails actively** — the 5000 ms close timer force-closes regardless of pointer position (`ToolTipService.cs:160`)                                                                                                     |
| Dismissible | **Partial** — `ToolTipService.OnKeyDown` closes on any key except the four arrows (`:298`), but that handler is attached to the **owner**, so a hover tooltip over a non-focused element cannot be dismissed by Escape |

Native AT trees (VoiceOver / TalkBack / UIA / AT-SPI) are not addressed in the popup code at all; the peer tree is the whole story, and `InputManager.GetWasUIAFocusSetSinceLastInput()` is the only place UIA is consulted — to decide whether a programmatic focus should show a tooltip.

**Where it lives.** The accessibility API layer (`AutomationPeer`), separate from the popup primitive. The primitive contributes only the two booleans the peer branches on.

**Degradation.** A terminal grid can honestly expose painted text in reading order, focus position, keyboard reachability and a stable ordering. It cannot expose a role, a modal bit, or a described-by relationship. INFERENCE: the split Uno already draws — geometric and behavioural properties in the primitive, role and description in the semantic component — is the right one, and its two failures are instructive because both properties it fails on (persistent, hoverable) are exactly the kind a primitive **can** own as declared data rather than leave emergent. See [`../../specs/ui/state-machines.md`](../../specs/ui/state-machines.md).

### 14. Animation

**Algorithm.** The primitive emits almost no geometry metadata, and the one channel it has is broken.

`Popup.ActualPlacement` is public, backed by a plain field with an `ActualPlacementChanged` event, and `CommandBarFlyoutCommandBar` consumes it — "If we have a value set for ActualPlacement, then we'll directly use that" (`CommandBarFlyoutCommandBar.mux.cs:643`). A grep over `src/Uno.UI`, `src/Uno.UWP`, `src/Uno.UI.Composition`, `src/Uno.UI.Runtime.Skia` and the two test projects (excluding `Generated/`) found nothing that assigns it, so it stays `PopupPlacementMode.Auto` and that consumer's branch is unreachable. The chosen side is consequently unavailable to the styling layer for flyouts, menus and tooltips.

`PopupThemeTransition` (with its `FromHorizontalOffset` / `FromVerticalOffset`) is `[NotImplemented]` on every target; `MenuPopupThemeTransition` likewise, existing purely as a property bag (`OpenedLength`, `ClosedRatio`, `Direction`) that theme XAML sets. `ToolTip` animates only through `VisualStateManager.GoToElementState("Opened"/"Closed")` (`:157`), and the source records that its offset-based template settings are dead — the animation "is now a FadeIn/FadeOut which doesn't use any FromHorizontalOffset/FromVerticalOffset", leaving `ToolTipTemplateSettings` "in a basically non-used and deprecated state" (`:704`).

The only real placement-aware animation metadata in the subject is `TeachingTip.UpdateTail` setting the tail-occlusion grid's `CenterPoint` per effective placement, so the expand/contract animation scales out of the tail (`:376`):

```text
Top      -> (w/2,                    h - lastRowHeight)
Bottom   -> (w/2,                    firstRowHeight)
Left     -> (w - lastColumnWidth,    h/2)
Right    -> (firstColumnWidth,       h/2)
TopLeft  -> (col0 + col1 + 1,        h - lastRowHeight)
RightTop -> (w - lastColumnWidth,    h - (row_{n-1} + row_n + 1))
```

Reposition during animation is not handled: a `SizeChanged` re-runs `PerformPlacement` synchronously, which jumps. Reduced motion is not consulted anywhere in the popup path. Submenu direction **is** computed (`isSubMenuDirectionUp`) but only picks a visual state; it is never fed back into geometry.

**Where it lives.** Library code plus composition (`CenterPoint` is a `Visual` property). Everything else is theme XAML.

**Degradation.** The lesson here is negative and it is the strongest one in the subject: **a placement engine must publish its result.** Uno computes the winning side inside `CalculatePopupPlacement`'s loop and then discards it, which is why `ActualPlacement` is permanently `Auto`, why one real consumer is dead code, and why no flyout animation can derive a transform origin. In a cell toolkit the emission is trivial and free — the placement result is a value carrying the chosen side, the alignment, the anchor offset along the edge, the chosen rect and a did-fall-back bit. On a terminal there is no transform origin, but the _side_ is still needed to pick which border row gets the caret glyph and which edge a reveal wipes from. Under **static HTML** the side must be baked at emit time. Reduced motion is a per-target input, not a discovery.

### 15. State architecture

**Algorithm.** Ad-hoc imperative controllers over dependency properties; no reducer, no explicit finite-state machine. The state of one flyout is spread across:

- Instance fields on `FlyoutBase` — `m_isPositionedAtPoint`, `m_targetPoint`, `m_isTargetPositionSet`, `m_hasPlacementOverride`, `m_placementOverride`, `m_openingCanceled`, `m_shouldTakeFocus`, `m_inputDeviceTypeUsedToOpen`, `m_isPositionedForDateTimePicker`, `_isClosedPending` (`:45`).
- Dependency properties on `Popup` — `IsOpen`, `PlacementTarget`, `DesiredPlacement`, the two offsets — whose `AffectsMeasure` / `AffectsArrange` metadata **is** the recompute trigger.
- A static list of open flyouts, `PopupRoot`'s weak most-recent-first list, and static mutable state in `ToolTipService` (`m_CurrentToolTip`, `m_LastEnteredFrameId`, two static timers, `s_lastEnterInputMode`).

Cancellation is a `ref bool cancel` threaded `Popup.OnClosing → FlyoutBase.Hide → FlyoutBaseClosingEventArgs.Cancel`. The open/close sequences are:

```text
Open:  EnsurePopupCreated -> guard _isClosedPending
       -> if open on a different target: Hide(canCancel: false)
       -> Target = t -> ForwardTargetPropertiesToPresenter
       -> capture input device -> map FlyoutPlacementMode to PopupPlacementMode
       -> UpdateStateToShowMode -> OnOpening (cancellable via m_openingCanceled)
       -> Open() -> IsOpen = true -> dispatch Opened at Idle priority

Close: OnClosing(ref cancel) -> if !cancel, cascade-hide the next open flyout
       -> popup.IsOpen = false -> OnClosed -> RemoveFromOpenFlyouts
       -> dispatch Closed, then hide the new head
```

Two deferred dispatches are load-bearing and marked as workarounds: `Opened` is raised at `CoreDispatcherPriority.Idle` — "UNO-FIX: Defer the raising of the Opened event to ensure everything is well initialized before opening it" (`:635`) — and `Closed` is raised from a `Dispatcher.RunAsync` which then hides the new head, with "TODO Uno: Closed should occur on PresenterUnloaded, but that requires aligned loading/unloading lifecycle. #2895" (`:457`).

Memory management is pervasive and deliberate. `Target`, `AssociatedFlyout`, `PopupPanel.Popup`, `_lastFocusedElement`, `CascadingMenuHelper`'s owner and presenter, and every entry of the open-popup list are `ManagedWeakReference`s, and the source names the leak chain that `PlacementTarget = null` on close exists to break: flyout → popup → placement target → control → `DataContext` → view model (`:374`, `:718`).

**Where it lives.** Library code, but structurally dependent on the framework kernel: the dependency-property system provides invalidation, the dispatcher provides ordering, weak references provide lifetime.

**Degradation.** The **placement half** ports to value semantics unchanged — pure `Rect` arithmetic with no allocation, since the fallback table is a static `Memory` over a static array. The **lifecycle half** does not: it depends on a GC plus weak references (to break owner cycles that value semantics would not create), on a dispatcher for ordering fixes, and on layout invalidation as the recompute signal. In an immediate-mode toolkit that recomputes every frame, the invalidation machinery, both deferred dispatches and the two-pass arrange all disappear. INFERENCE: the parts worth keeping as values are the placement inputs and outputs — preferred side, justification, offsets, anchor rect, boundary rect and the positioned-at-point flag in; chosen side, rect and a fits bit out — since that is a pure function and trivially assertable on a recording canvas; the part worth making an explicit machine is the open/closing/cancelled sequence, which in Uno needs `m_openingCanceled`, `_isClosedPending` and a `ref bool` precisely because it has no state enum.

### 16. Shared infrastructure

**Truly shared, and correctly so.** Two things:

- **`Popup` — the surface.** Open/close, the full-window panel, the light-dismiss overlay and its hit-testability, focus save/restore, back-button registration, Escape, and theme forwarding into the reparented subtree.
- **`PopupRoot` — the overlay registry.** Paint order, the most-recent-first ownership list, topmost-with-filter, close-all.

**Shared but wrongly factored.** `PopupPanel`'s placement engine. Its own comment states both the intent and the verdict (quoted in full under _Design philosophy_). It is specialised by **subclassing with virtual hooks** rather than parameterised — `FlyoutBasePopupPanel` (`PopupPlacementTargetMargin = 5`, `FullPlacementRequested`, pass-through dismissal), `ContentDialogPopupPanel` (centre, always hit), `PickerFlyoutPopupPanel` (UIKit), `FlyoutPopupPanel.iOSAndroid` — plus a documented total bypass, `Popup.IDynamicPopupLayouter` (`Popup.Base.cs:209`), whose only implementation is `ComboBox.DropDownLayouter` (`ComboBox.custom.cs:577`).

**What looks common and must stay apart**, with the evidence for each:

1. **`ToolTip` does not use the shared engine** for its own geometry. It runs two of its own algorithms and merely writes `Popup.HorizontalOffset` / `VerticalOffset` (`ToolTip.cs:698`), because cursor tracking, input-mode offsets, handedness and content clipping share nothing with anchored flyout placement.
2. **`MenuFlyout` deliberately ignores `Placement`** — "We want to preserve existing MenuFlyout behavior - it will continue to ignore the Placement property" (`FlyoutBase.cs:1001`).
3. **Submenus reuse nothing**: their own `Popup`, their own absolute positioning through `ISubMenuOwner.PositionSubMenu(Point)` with a per-axis sentinel, their own overlap constant, their own hover machine.
4. **`ComboBox`** needs selected-item-sticky alignment that no side/alignment vocabulary can express — hence the escape hatch.
5. **`ContentDialog`** needs centring plus unconditional hit-blocking.
6. **`TeachingTip`** needs a 13-mode availability mask and tail-aware constraints, and shares only the `Popup` surface.

**The de-facto layering that survives that evidence** is three levels: layer 0 is the surface (paint into the overlay layer, hit-catcher rect, open/close, dismissal, focus); layer 1 is a **pure placement function** over `(anchorRect, contentSize, boundaryRect, preferredSide, justification, offsets, margin)` returning `(rect, chosenSide, fits)`; layer 2 is per-consumer policy that either calls layer 1 or computes its own offsets and hands layer 0 a rect. Uno has 0 and 2 right and made 1 a class with virtual hooks rather than a function.

**Where it lives.** Library code: `PopupPanel` plus its four subclasses, with `Popup.IDynamicPopupLayouter` as the acknowledged escape hatch.

**Degradation.** The layer-0 / layer-1 split is what survives every constraint: the pure function needs no window, no hover, no script, no timers and no sub-cell precision, which also makes it the only part assertable on a recording canvas. INFERENCE: in this subject, making the placement solve a base class rather than a function coincided with four subclasses plus a documented bypass and the authors' own removal verdict — which argues, at least for a toolkit under the same one-surface constraint, for a function over values. See [`./proposal.md`](./proposal.md) and [`../../specs/ui/index.md`](../../specs/ui/index.md).

## Strengths

- **The layering model is at the floor and complete.** One surface, a fixed ladder of root layers, paint order equals open order, no compositor and no OS popup on any target — running flyouts, menus, submenus, tooltips, dialogs, combobox dropdowns and teaching tips.
- **Placement is pure `Rect` arithmetic** with no allocation and one substrate call (`TransformToVisual`) — portable, testable and cheap enough to run every frame.
- **The fallback table's repeat-the-preferred-side-last trick makes the search total.** There is always a defined result, so no null or optional has to be threaded through callers.
- **Justification is re-applied per candidate**, so a flip preserves edge alignment — cheap and correct.
- **Frame-identity dedupe** solves nested-trigger races with one integer compare, no capture, no tree walk, no timer.
- **Hit-invisible-but-children-hit** yields light dismiss, click-through and modal blocking from a single per-element bit, and needs no pointer grab.
- **The overlay registry is deliberately separate from the paint list** — a most-recent-first weak list that Escape, light dismiss, focus and close-all all query.
- **`OverlayInputPassThroughElement` is a careful passthrough primitive**: re-hit-test with the overlay layer excluded, check ancestry in _both_ directions, then re-route the live event.
- **`TeachingTip`'s availability mask composes independent geometric predicates** and can honestly answer "nothing fits, do not open" — more expressive than the flyout engine's ordered try-list.
- **`TeachingTip` derives the tail's transform origin** from the chosen side and the tail's own measurements — the one place the subject emits geometry metadata for animation.
- **Flyout focus takes the _current_ focus state** (Pointer vs. Keyboard vs. Unfocused) into the popup instead of hardcoding `Programmatic`, so a mouse-opened surface does not paint a keyboard focus ring.
- **Tab containment is achieved by scope discovery**, not by a trap, so nothing has to be un-trapped on close.
- **Theme is applied to the popup child before it enters the `PopupRoot` subtree**, including logical-only item collections, specifically to avoid a one-frame wrong-theme flash — an ordering bug class any canvas toolkit will hit identically.

## Weaknesses

- `Popup.ShouldConstrainToRootBounds` and `IsConstrainedToRootBounds` are `[NotImplemented]` on every target (the latter throws), as are `SystemBackdrop`, `ChildTransitions` and `DesktopPopupSiteBridge` — so popups can never leave the app surface.
- `Popup.ActualPlacement` is never assigned by any Uno code found in the searched trees, so the chosen side is invisible to consumers and `CommandBarFlyoutCommandBar`'s dependent branch is dead.
- `PopupThemeTransition` and `MenuPopupThemeTransition` are `[NotImplemented]` on every target: no placement-aware enter/exit animation for flyouts, menus or tooltips, only a `VisualState` fade for tooltips.
- **No soft-keyboard / IME avoidance.** `CalculateAvailableWindowRect` is a stub; Android's visible bounds derive from `SystemBars | DisplayCutout` only, and `InputPane` pads a `ScrollContentPresenter` instead.
- `ExclusionRect` (WinUI's IME-candidate-window avoidance) is entirely commented out in `UpdateTargetPosition`.
- Multi-monitor and windowed-popup monitor math are commented out; `TeachingTip`'s only screen-bounds path is gated behind the `[NotImplemented]` `ShouldConstrainToRootBounds`.
- RTL is absent from the main placement engine; `ToolTip` hardcodes `bIsRTL = false` with every RTL branch commented out, and `ToolTipPositioning.IsLefthandedUser()` is hardcoded `true`, so the handedness fallback always prefers the right side.
- **No anchor tracking** for `Flyout` / `Popup` / `ToolTip`: scrolling the anchor neither moves nor dismisses the surface. Only `TeachingTip` subscribes `EffectiveViewportChanged`.
- No dismissal on scroll, anchor hidden, anchor removed, or navigation; `DismissalTriggerFlags` exists but its backing field is never assigned in the searched trees, so the generalisation is dead code.
- Dismissal is pointer-**down** only, with no down/up/click distinction, and `PopupRoot` unconditionally marks `PointerReleased` as `Handled` as an acknowledged hack.
- WCAG 1.4.13: tooltips are non-hoverable by construction and non-persistent by design (5000 ms force-close); Escape only dismisses while the **owner** has focus.
- No described-by equivalent: `ToolTipService` never annotates the owner's automation peer, so the tooltip is a separate window-ish peer rather than the owner's description.
- `PopupAutomationPeer.IsModal` returns `IsOpen`, so every open popup claims modality to assistive technology regardless of whether it blocks anything.
- `PopupRoot.GetOpenPopupForElement`, `ClearWasOpenedDuringEngagementOnAllOpenPopups` and `GetPopupChildrenOpenedDuringEngagement` are `[NotImplemented]` stubs, the first explicitly noted as needed "for proper focus support".
- The shared placement engine is a subclassable `Panel` rather than a function — four subclasses plus a documented total bypass, with the authors' own comment saying it should be removed.
- Two acknowledged lifecycle workarounds are load-bearing (`Opened` deferred to Idle priority; `Closed` deferred via `Dispatcher.RunAsync`, issue #2895), plus a two-pass `ArrangeElement` because an offset is mutated during arrange.
- `Popup.PopupPanelProperty` is a public dependency property whose value type is internal.
- Behaviour is silently backend-dependent: `ConstrainByVisibleBounds` defaults `true` on native heads and `false` on Skia; `UseToolTips` defaults `true` only on WASM/Skia.

## Key design decisions and trade-offs

| Decision                                                                                                                                      | Rationale                                                                                                                                                                                                                                  | Trade-off                                                                                                                                                                                                                                                                                 |
| --------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Every popup is a **full-surface panel**, not a floating rect; the panel positions its own content in `ArrangeOverride`.                       | One object serves as dismiss catcher, scrim, clip escape and placement coordinate space, and needs no knowledge of where the popup will land — "this Panel always take the whole screen for the dismiss layer, but it's content will not". | N open popups means N full-surface panels measuring and arranging over the whole window; and the panel's own bounds are useless, so hit-testing has to be disabled per-panel via `IsViewHit` rather than by geometry.                                                                     |
| **Reproduce WinUI's overflow behaviour** rather than always clamping — "we do not prevent overflow of the popup on any side as UWP does not!" | Uno's contract is behavioural compatibility, so a popup WinUI lets escape the window must escape in Uno too, or app layouts tuned on Windows break.                                                                                        | On phones a flyout can land partly off-screen. The engine needs an explicit "if the naive frame spills, use the placement engine" gate plus four fully-outside rescues — more code than clamping — and the partial-overflow case is still unhandled.                                      |
| **Boundary = `XamlRoot.VisualTree.VisibleBounds`, full stop.** `CalculateAvailableWindowRect` ignores its six parameters.                     | One rect covers safe-area / notch / status-bar avoidance on every target and needs no platform query, keeping the math backend-neutral.                                                                                                    | No soft-keyboard avoidance (a flyout can sit under the keyboard), no app-bar avoidance, no exclusion rect for IME candidate windows, no multi-monitor, and no per-call boundary override for a consumer wanting a sub-region.                                                             |
| **Keep the placement result private**: compute the winning side inside the loop and never publish it.                                         | INFERENCE: the arrange-time engine has no natural write-back point, since `PopupPanel.ArrangeOverride` is layout code and `Popup.ActualPlacement` is on a different object; WinUI assigns it in a pipeline stage Uno did not port.         | `ActualPlacement` stays `Auto` forever; `CommandBarFlyoutCommandBar`'s branch is unreachable; no animation can derive a transform origin from the chosen side; and no caret or arrow can be added on top of the shared engine without re-deriving the side.                               |
| **Specialise the placement engine by subclassing** `PopupPanel` with virtual hooks, plus `IDynamicPopupLayouter` as a total bypass.           | Each consumer needed one or two knobs (margin, `Full` placement, hit-blocking, pass-through), which virtual members express with minimal ceremony inside an existing layout object.                                                        | Six consumers subclass (four panels) or bypass entirely (`ComboBox`, `ToolTip`, submenus, `TeachingTip`). The engine is not callable as a function, so it cannot be unit-tested or reused off the layout pass — and the authors' comment says it should be removed.                       |
| Make the overlay's input behaviour a **function of `IsLightDismissEnabled`** via `IsViewHit()`, rather than a separate modality concept.      | It collapses light dismiss, click-through and modal blocking into one boolean the existing hit-test coercion already consumes, and needs no pointer capture.                                                                               | Modality cannot be expressed independently of dismissal: `ContentDialog` overrides `IsViewHit() => true`, and `CommandBar` is special-cased by type in two places because it uses `IsSticky`. Keyboard blocking has no home at all.                                                       |
| Give the tooltip service **process-wide static state**: one current tooltip, one open timer, one close timer, one last-entered frame id.      | Tooltips are mutually exclusive by definition, and a singleton makes "opening one closes the other" and the nested-owner race trivially correct with no bookkeeping.                                                                       | No per-group timing and no warm-up / skip-delay across neighbouring toolbar buttons (every tooltip pays the full 1000 ms); `CloseToolTipImpl` has to branch on whether the argument _is_ the current tooltip; and the state is not injectable, so the runtime tests sleep real wall time. |
| **Hold every cross-object popup reference weakly** and null `PlacementTarget` on close.                                                       | A shared flyout otherwise pins its previous placement target's whole `DataContext` — the source names the chain flyout → target → `DataContext` → view model.                                                                              | Every access becomes a liveness dance, dead entries must be swept, and behaviour becomes GC-timing dependent. In a value-semantics toolkit the cycle never exists, so the machinery is pure overhead.                                                                                     |

## Sources

Primary sources, all read at [`df5d18a850248cb8c2ccb34032b4ebeb54dc8283`][repo-sha]:

- [`PopupPanel.Placement.cs`][pp-placement] — the shared 5-candidate engine: the fallback table (`:30`), `CalculatePopupPlacement` (`:127`), the `Full` centring helper (`:218`), the union-containment acceptance test (`:277`), the fully-outside rescues (`:297`), `TestAndCenterAlignWithinLimits` (`:347`).
- [`PopupPanel.cs`][pp] — the full-window panel, the "we do not prevent overflow" fast path (`:127`), the containment gate (`:175`), the two-pass arrange workaround (`:184`), `OnPointerPressed` (`:254`), `IsViewHit` (`:291`).
- [`PopupRoot.cs`][pproot] / [`PopupRoot.mux.cs`][pproot-mux] — `CloseLightDismissablePopups` (`:70`), `OpenPopup` (`:169`), `RegisterOpenPopup` (`:216`), the Escape handler and its reparenting comment (`:248`), `CloseTopmostPopup`, `GetOpenPopupForElement` (`[NotImplemented]`).
- [`Popup.cs`][popup] / [`Popup.Base.cs`][popup-base] / [`Popup.mux.cs`][popup-mux] / [`Popup.WithPopupRoot.cs`][popup-wpr] — `GetPanelBackground` (`:349`), the render-transform mirror (`:72`), `ActualPlacement` (`:253`), focus save/restore and the Pointer-to-Keyboard upgrade, `ShouldDismiss`, the pre-parenting theme application.
- [`FlyoutBase.cs`][flyoutbase] — enum decomposition (`:1293`, `:1328`), `ShowAtCore` (`:515`), `CalculateAvailableWindowRect` (`:953`), `UpdateTargetPosition` (`:1202`), touch `preferTopPlacement` (`:1043`), focus-on-loaded (`:133`), the weak `Target` and its leak-chain comment (`:374`), the two deferred dispatches (`:635`, `:457`).
- [`FlyoutPopupPanel.cs`][flyoutpp] — `PopupPlacementTargetMargin => 5` (`:37`) and the `OverlayInputPassThroughElement` re-route (`:39`).
- [`ToolTipService.cs`][ttsvc] — the singleton opener (`:97`), timers (`:116`, `:141`, `:160`), the UIA focus gate (`:246`), frame-id dedupe (`:273`), `OnKeyDown` (`:298`).
- [`ToolTip.cs`][tooltip] and [`ToolTipPositioning.cs`][ttpos] — the cursor-relative path, `MovePointToPointerToolTipShowPosition`, `CalculateTooltipClip` / `PerformClipping`, and `QueryRelativePosition`.
- [`CascadingMenuHelper.mux.cs`][cmh] / [`CascadingMenuHelper.h.mux.cs`][cmh-h] — the hover machine (`:98`, `:112`, `:145`, `:203`, `:226`), the sentinel `Point` (`:625`), `GetPositionAndDirection` (`:672`), `DefaultMenuShowDelay = 400` (`h:14`), `m_subMenuOverlapPixels = 4` (`h:21`).
- [`TeachingTip.mux.cs`][tt] — `UpdateTail` (`:319`), the `CenterPoint` switch (`:376`), viewport tracking (`:1612`, `:1641`), the availability mask and `GetPlacementFallbackOrder` (`:2291`), tail metrics (`:2409`, `:2424`, `:2446`).
- [`VisualTree.cs`][vt] / [`VisualTree.uno.cs`][vt-uno] — the z-index constants (`:36`) and root ladder (`:255`).
- [`UIElement.Pointers.Managed.cs`][uiel-ptr] — `CoerceHitTestVisibility` and the `IsViewHit` to `Invisible` mapping (`:95`).
- [`ContentDialogPopupPanel.cs`][cdpp] — the smoke-layer comment (`:105`) and `IsViewHit() => true` (`:107`).
- [`PopupAutomationPeer.cs`][pap] — `AutomationControlType.Window` (`:32`), `IsModal` (`:76`), `ShouldExposeWindowPattern` (`:126`).
- [`FeatureConfiguration.cs`][featcfg] — `ConstrainByVisibleBounds` (`:391`), `UseToolTips` (`:687`), `ShowDelay` (`:692`), `ShowDuration` (`:694`).
- [`ContextMenuProcessor.cs`][ctxmenu] — the 500 ms hold delay (`:24`), keyboard triggers (`:46`), the holding gesture (`:109`).
- [`DismissalTriggerFlags.cs`][dtf], [`Popup.cs` (Generated)][gen-popup] and [`DesktopPopupSiteBridge.cs`][dpsb] — the dead generalisation and the `[NotImplemented]` surface.
- [`Given_Popup.cs`][given-popup] — the runtime tests pinning `When_ConstrainedByVisibleBounds` (`:363`), `When_Escape_Canceled` (`:450`) and the most-recent-first ordering (`:510`).

Related catalog pages: [`./index.md`](./index.md), [`./concepts.md`](./concepts.md), [`./comparison.md`](./comparison.md), [`./features-people-forget.md`](./features-people-forget.md), [`./sparkles-baseline.md`](./sparkles-baseline.md), [`./proposal.md`](./proposal.md); nearest siblings [`./winui.md`](./winui.md), [`./avalonia.md`](./avalonia.md), [`./wpf.md`](./wpf.md), [`./compose.md`](./compose.md), [`./flutter.md`](./flutter.md).

<!-- References -->

[repo]: https://github.com/unoplatform/uno
[repo-sha]: https://github.com/unoplatform/uno/tree/df5d18a850248cb8c2ccb34032b4ebeb54dc8283
[unodocs]: https://platform.uno/docs/articles/intro.html
[pp-placement]: https://github.com/unoplatform/uno/blob/df5d18a850248cb8c2ccb34032b4ebeb54dc8283/src/Uno.UI/UI/Xaml/Controls/Popup/PopupPanel.Placement.cs#L25
[pp]: https://github.com/unoplatform/uno/blob/df5d18a850248cb8c2ccb34032b4ebeb54dc8283/src/Uno.UI/UI/Xaml/Controls/Popup/PopupPanel.cs#L127
[pproot]: https://github.com/unoplatform/uno/blob/df5d18a850248cb8c2ccb34032b4ebeb54dc8283/src/Uno.UI/UI/Xaml/Controls/Popup/PopupRoot.cs#L248
[pproot-mux]: https://github.com/unoplatform/uno/blob/df5d18a850248cb8c2ccb34032b4ebeb54dc8283/src/Uno.UI/UI/Xaml/Controls/Popup/PopupRoot.mux.cs#L24
[popup]: https://github.com/unoplatform/uno/blob/df5d18a850248cb8c2ccb34032b4ebeb54dc8283/src/Uno.UI/UI/Xaml/Controls/Popup/Popup.cs#L349
[popup-base]: https://github.com/unoplatform/uno/blob/df5d18a850248cb8c2ccb34032b4ebeb54dc8283/src/Uno.UI/UI/Xaml/Controls/Popup/Popup.Base.cs#L99
[popup-mux]: https://github.com/unoplatform/uno/blob/df5d18a850248cb8c2ccb34032b4ebeb54dc8283/src/Uno.UI/UI/Xaml/Controls/Popup/Popup.mux.cs#L44
[popup-wpr]: https://github.com/unoplatform/uno/blob/df5d18a850248cb8c2ccb34032b4ebeb54dc8283/src/Uno.UI/UI/Xaml/Controls/Popup/Popup.WithPopupRoot.cs#L109
[flyoutbase]: https://github.com/unoplatform/uno/blob/df5d18a850248cb8c2ccb34032b4ebeb54dc8283/src/Uno.UI/UI/Xaml/Controls/Flyout/FlyoutBase.cs#L953
[flyoutpp]: https://github.com/unoplatform/uno/blob/df5d18a850248cb8c2ccb34032b4ebeb54dc8283/src/Uno.UI/UI/Xaml/Controls/Flyout/FlyoutPopupPanel.cs#L37
[ttsvc]: https://github.com/unoplatform/uno/blob/df5d18a850248cb8c2ccb34032b4ebeb54dc8283/src/Uno.UI/UI/Xaml/Controls/ToolTip/ToolTipService.cs#L273
[tooltip]: https://github.com/unoplatform/uno/blob/df5d18a850248cb8c2ccb34032b4ebeb54dc8283/src/Uno.UI/UI/Xaml/Controls/ToolTip/ToolTip.cs#L698
[ttpos]: https://github.com/unoplatform/uno/blob/df5d18a850248cb8c2ccb34032b4ebeb54dc8283/src/Uno.UI/UI/Xaml/Controls/ToolTip/ToolTipPositioning.cs#L224
[cmh]: https://github.com/unoplatform/uno/blob/df5d18a850248cb8c2ccb34032b4ebeb54dc8283/src/Uno.UI/UI/Xaml/Controls/MenuFlyout/CascadingMenuHelper.mux.cs#L203
[cmh-h]: https://github.com/unoplatform/uno/blob/df5d18a850248cb8c2ccb34032b4ebeb54dc8283/src/Uno.UI/UI/Xaml/Controls/MenuFlyout/CascadingMenuHelper.h.mux.cs#L14
[tt]: https://github.com/unoplatform/uno/blob/df5d18a850248cb8c2ccb34032b4ebeb54dc8283/src/Uno.UI/UI/Xaml/Controls/TeachingTip/TeachingTip.mux.cs#L319
[vt]: https://github.com/unoplatform/uno/blob/df5d18a850248cb8c2ccb34032b4ebeb54dc8283/src/Uno.UI/UI/Xaml/Internal/VisualTree.cs#L36
[vt-uno]: https://github.com/unoplatform/uno/blob/df5d18a850248cb8c2ccb34032b4ebeb54dc8283/src/Uno.UI/UI/Xaml/Internal/VisualTree.uno.cs#L18
[uiel-ptr]: https://github.com/unoplatform/uno/blob/df5d18a850248cb8c2ccb34032b4ebeb54dc8283/src/Uno.UI/UI/Xaml/UIElement.Pointers.Managed.cs#L95
[cdpp]: https://github.com/unoplatform/uno/blob/df5d18a850248cb8c2ccb34032b4ebeb54dc8283/src/Uno.UI/UI/Xaml/Controls/ContentDialog/ContentDialogPopupPanel.cs#L105
[pap]: https://github.com/unoplatform/uno/blob/df5d18a850248cb8c2ccb34032b4ebeb54dc8283/src/Uno.UI/UI/Xaml/Automation/Peers/PopupAutomationPeer.cs#L76
[featcfg]: https://github.com/unoplatform/uno/blob/df5d18a850248cb8c2ccb34032b4ebeb54dc8283/src/Uno.UI/FeatureConfiguration.cs#L687
[ctxmenu]: https://github.com/unoplatform/uno/blob/df5d18a850248cb8c2ccb34032b4ebeb54dc8283/src/Uno.UI/UI/Xaml/Internal/ContextMenuProcessor.cs#L46
[dtf]: https://github.com/unoplatform/uno/blob/df5d18a850248cb8c2ccb34032b4ebeb54dc8283/src/Uno.UI/UI/Xaml/Controls/Popup/DismissalTriggerFlags.cs#L7
[gen-popup]: https://github.com/unoplatform/uno/blob/df5d18a850248cb8c2ccb34032b4ebeb54dc8283/src/Uno.UI/Generated/3.0.0.0/Microsoft.UI.Xaml.Controls.Primitives/Popup.cs#L76
[dpsb]: https://github.com/unoplatform/uno/blob/df5d18a850248cb8c2ccb34032b4ebeb54dc8283/src/Uno.UI/Generated/3.0.0.0/Microsoft.UI.Content/DesktopPopupSiteBridge.cs#L7
[given-popup]: https://github.com/unoplatform/uno/blob/df5d18a850248cb8c2ccb34032b4ebeb54dc8283/src/Uno.UI.RuntimeTests/Tests/Windows_UI_Xaml_Controls_Primitives/Given_Popup.cs#L363
