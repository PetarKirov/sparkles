# WPF Popup / ToolTipService / ContextMenu (C# / .NET)

WPF treats anchored placement as **candidate generation plus scoring** rather than as a named side with fallbacks, and pays for its top layer with a real top-level Win32 window per overlay.

| Field         | Value                                                                                                                                                                 |
| ------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language      | C# (.NET)                                                                                                                                                             |
| License       | MIT                                                                                                                                                                   |
| Repository    | [`dotnet/wpf`][repo]                                                                                                                                                  |
| Documentation | In-repo design spec [`src/Microsoft.DotNet.Wpf/specs/tooltip.md`][spec] (the .NET 6 tooltip rework), plus the public [`Popup` API reference][learn-popup]             |
| Category      | Native desktop (Windows)                                                                                                                                              |
| Surface model | OS popup — one top-level `HwndSource` per `Popup` instance (`WS_POPUP`, `WS_EX_TOPMOST \| WS_EX_TOOLWINDOW \| WS_EX_NOACTIVATE`), with an internal `PopupRoot` visual |
| Revision read | `99caccf23145777f910711b51961885bec783213`                                                                                                                            |

This page is an implementation reading: every claim below is taken from source at that
revision, except where it explicitly cites the in-repo spec. See [`./index.md`](./index.md)
for the catalog and [`./concepts.md`](./concepts.md) for the shared vocabulary — every term
of art (anchor rect, placement, constraint adjustment, flip/shift/slide/resize, clipping
boundary, top layer, light dismiss, grab, safe polygon, warm-up, cool-down, focus scope,
modality, virtual anchor, transform origin) is defined there and used here in that sense.

> [!IMPORTANT]
> No unit or integration tests for `Popup`, `ToolTip` or `ContextMenu` exist in this
> repository — `src/Microsoft.DotNet.Wpf/tests/UnitTests` contains no references to them,
> and the `SafeAreaOnHyperlink` test named in a source comment lives in the closed
> `dotnet/wpf-test` suite. Nothing below is corroborated by tests, and no WPF code was
> executed; timing values, flip behaviour and safe-area geometry are read from
> implementation source plus the shipped spec.

## Overview

### What it solves

`Popup` is the framework's single anchored-overlay primitive. `ToolTip`, `ContextMenu`,
`MenuItem` submenus, `ComboBox` drop-downs, `DatePicker` calendars, `ToolBar` overflow and
`Slider`'s auto-tooltip are all the same primitive with a different child, wired up by one
composition root (`Popup.CreateRootPopupInternal`, `Popup.cs:879`). The primitive itself is
permanently `Visibility.Collapsed` in its own tree — `CoerceVisibility` forces it — and
instead owns a separate top-level window whose root visual is the internal `PopupRoot`. So
escaping clipping and z-order is the operating system's problem, not the framework's, and
the whole placement engine works in **screen device pixels**, rounding to whole integers at
the end via `DoubleUtil.DoubleToInt` (`DoubleUtil.cs:261`).

### Design philosophy

Placement is not a side name. Each `PlacementMode` expands into 1, 2 or 4 _(anchor interest
point, overlay interest point)_ pairs; each pair yields a translation; each translation is
scored by the area of its intersection with the screen; the first candidate that is fully
on-screen wins by early exit. The contract is stated in four comment lines above
`UpdatePosition` (`Popup.cs:1993-1996`):

> To position the popup, we find the InterestPoints of the placement rectangle/point
> in the screen coordinate space. We also find the InterestPoints of the child in
> the popup's space. Then we attempt all valid combinations of matching InterestPoints
> (based on PlacementMode) to find the position that best fits on the screen.

The scoring function is documented as a heuristic, together with its known failure mode
(`Popup.cs:2085-2088`) — which makes the scorer, not the enum, the extension point:

> Note: this score is based on the percent of the popup that is on screen
> not the percent of the child that is on screen. For certain
> scenarios, this may produce in counter-intuitive results.
> If this is a problem, more complex scoring is needed

`PlacementMode.Custom` replaces the built-in generator with an app callback returning an
array of `CustomPopupPlacement` candidates: the app proposes, the framework still scores,
clamps and disposes.

The tooltip layer — `ToolTipService` attached properties plus the internal
`PopupControlService` controller — is a complete hover state machine with warm-up
(`InitialShowDelay`), max display duration (`ShowDuration`) and a cool-down
(`BetweenShowDelay`) that makes the _next_ tooltip appear instantly. .NET 6 added a
convex-hull safe polygon so the pointer can travel from owner to tooltip without dismissal,
justified in the spec by the geometry of the requirement itself (`PopupControlService.cs:1329-1334`):

> A region is convex if every line segment connecting two points of the region lies
> within the region. … the tooltip should remain open as long as the mouse lies on a line
> segment connecting some point in the owner to some point in the tooltip, i.e. as long
> as the mouse is in the convex hull of the corners of the owner and tooltip rectangles.

That work cites WCAG 2.1 §1.4.13 as the first of its requirement sources (`specs/tooltip.md:26`)
and attributes the dismissal-inhibiting buffer zone to the "hoverable" requirement
(`specs/tooltip.md:201`). The spec never labels individual mechanisms with WCAG clause names;
the mapping of safe region → hoverable, `ShowDuration` → persistent, `Ctrl` → dismissible is
an inference from the requirement list, not a quotation.

## How it works

Opening a `Popup` runs four phases, in this order.

```text
IsOpen = true
  └─ CreateWindow()          Popup.cs:1516 — build (or rebuild) the HWND
  └─ PopupRoot.Measure()     PopupRoot.cs:137 — layout, clamped by Popup.RestrictSize
  └─ UpdatePosition()        Popup.cs:1999 — candidate scoring + nudge, then SetWindowPos
  └─ ShowWindow(SW_SHOWNA)   Popup.cs:3159 — show without activating
```

`UpdatePosition` is the whole placement engine and it is short. It builds two 5-element
`Point[]` arrays of _interest points_ — `TopLeft, TopRight, BottomLeft, BottomRight, Center` —
one for the anchor in screen space (`GetPlacementTargetInterestPoints`, `Popup.cs:2284`) and
one for the child in the popup's own space (`GetChildInterestPoints`, `Popup.cs:2372`). It
then enumerates candidates, scores each by on-screen intersection area, applies an
axis-conditional clamp, and rounds:

```text
best = previous position; bestScore = -1; childArea = w * h
for i in 0 .. candidateCount(mode) - 1:
    t     = anchorPts[combo(i).target] - childPts[combo(i).child]   // or Custom's callback
    inter = intersect(screenBoundsOfTargetMonitor, childBounds + t)
    if area(inter) - bestScore > Tolerance:
        best = t; bestScore = area(inter)
        if |bestScore - childArea| < Tolerance: break               // fully visible
if i >= 2 and mode in {Left, Right}: DropOpposite = !DropOpposite
nudge(best)                                                        // clamp onto screen
SetWindowPos(DoubleToInt(best.x), DoubleToInt(best.y))
```

`Tolerance` is `1.0e-2` (`Popup.cs:2899`), and the comparison is strictly-better-by-tolerance,
so ties preserve the candidate table's preference order.

The three services around it are thin. `ToolTipService` and `ContextMenuService` are
symmetric bags of attached properties; `PopupControlService` is a per-`Dispatcher` singleton
hooked into `InputManager.Current.PostProcessInput` (`PopupControlService.cs:34`) that owns
all timing, owner discovery, the safe area and dismissal for both tooltips and context
menus. Everything the services configure reaches the primitive through eight one-way
bindings established in `CreateRootPopupInternal`, with `IsOpen` bound last so the popup is
fully configured before it can open.

## The analysis spine

### 1. Anchor model

Three anchor sources collapse into one internal representation. `PlacementTarget` (a
`UIElement`; if null, the popup's own visual parent via `GetTarget`, `Popup.cs:1436`);
`PlacementRectangle` (a `Rect` in the target's coordinate space, defaulting to the target's
whole `RenderSize`, except under `Relative`/`RelativePoint` where it degenerates to a point
at the target origin); or the mouse, for `Mouse`/`MousePoint`. `HorizontalOffset`/`VerticalOffset`
offset the rect before conversion.

**Internally the anchor is not a rect — it is a 5-point `Point[]`.** That is deliberate: the
target may be arbitrarily transformed, so each corner is pushed individually through
`TransformToClient` and then `PopupSecurityHelper.ClientToScreen`; `GetBounds` collapses the
five points to an axis-aligned rect only for scoring. Cursor anchoring is **latched**:
`_positionInfo.MouseRect` is computed once per open and reused for every subsequent
reposition, with the reason stated in the source (`Popup.cs:2306-2311`) — "if the popup's
content size is animated the popup will keep repositioning, but we should not pick up a new
position for the mouse". Detached trigger versus anchor is first-class: the services set
`PlacementTarget` from the _owner_ element through `PopupControlService.CoerceProperty`
(`PopupControlService.cs:1263`), so one `ToolTip` instance can serve many owners, rebinding
`OwnerProperty` on each show. Multi-rect anchors exist only in the safe-area path: for a
`ContentElement` owner such as a `Hyperlink`, `SetSafeArea` calls `IContentHost.GetRectangles`
and receives N rects (`PopupControlService.cs:873`). There are no virtual anchors and
nothing observes the anchor after open.

```text
anchorPoints(placement):
    rect = PlacementRectangle
    if target == null or placement is absolute-ish:
        if placement in {Mouse, MousePoint}: rect = latched mouse rect   // once per open
        else if rect empty:                  rect = (0,0,0,0)
        return interestPointsFromRect(rect + toDevice(offset))           // already screen space
    else:
        if rect empty: rect = (placement in {Relative, RelativePoint}) ? point(0,0)
                                                                       : (0,0,target.RenderSize)
        pts = interestPointsFromRect(rect + offset)
        for i in 0..4: pts[i] = clientToScreen(transformToClient(target, root) * pts[i])
        return pts
```

**Where it lives.** Library code, except the last hop: `ClientToScreen` is the only part of
anchor resolution that touches the OS.

**Degradation.** Fully portable. The 5-point array is a plain comparable value with no DOM,
window or handle in it; on a cell grid the points are cell coordinates and the whole
conversion chain collapses to one translation by the target's absolute cell origin, deleting
the transform and DPI machinery. The mouse-rect latch is the behaviour to preserve verbatim —
recomputing the anchor from the live cursor each frame makes an animated overlay chase the
pointer. With no hover (Android, static HTML) the `Mouse`/`MousePoint` modes are unavailable
and must degrade to a rect anchor; WPF already ships exactly that fallback as
`TreatMousePlacementAsBottom` (dimension 12).

### 2. Placement model

Twelve `PlacementMode` values, each expanding to a candidate count
(`GetNumberOfCombinations`, `Popup.cs:2467`) and an ordered table of (anchor point → overlay
point) alignments (`GetPointCombination`, `Popup.cs:2495`). `dropFromRight` is
`SystemParameters.MenuDropAlignment` — the `SPI_GETMENUDROPALIGNMENT` system setting — OR-ed,
for `Left`/`Right`, with the inherited `DropOpposite` flag:

| Mode                                                          | N                  | Axis       | i=0   | i=1   | i=2   | i=3   |
| ------------------------------------------------------------- | ------------------ | ---------- | ----- | ----- | ----- | ----- |
| `Bottom` / `Mouse` (LTR)                                      | 2                  | Horizontal | BL→TL | TL→BL | –     | –     |
| `Bottom` / `Mouse` (dropFromRight)                            | 2                  | Horizontal | BR→TR | TR→BR | –     | –     |
| `Top` (LTR)                                                   | 2                  | Horizontal | TL→BL | BL→TL | –     | –     |
| `Top` (dropFromRight)                                         | 2                  | Horizontal | TR→BR | BR→TR | –     | –     |
| `Right` (or `Left` + dropFromRight)                           | 4                  | Vertical   | TR→TL | BR→BL | TL→TR | BL→BR |
| `Left` (or `Right` + dropFromRight)                           | 4                  | Vertical   | TL→TR | BL→BR | TR→TL | BR→BL |
| `Relative`/`RelativePoint`/`MousePoint`/`AbsolutePoint` (LTR) | 4                  | Horizontal | TL→TL | TL→TR | TL→BL | TL→BR |
| …the same, dropFromRight                                      | 4                  | Horizontal | TL→TR | TL→TL | TL→BR | TL→BL |
| `Center`                                                      | 1                  | None       | C→C   | –     | –     | –     |
| `Absolute` / `Custom` / default                               | 1 (0 for `Custom`) | None       | TL→TL | –     | –     | –     |

Candidates 0 and 1 are the primary placement and its flip; candidates 2 and 3 — `Left`/`Right`
only — are the cross-axis flip that sets `DropOpposite`. RTL is handled in two independent
places: `MenuDropAlignment` reorders the candidate table, and `GetChildInterestPoints` swaps
the overlay's TL↔TR and BL↔BR points when anchor and child have different `FlowDirection`
(`Popup.cs:2391`). Multi-monitor selection is by _anchor_, never by candidate. Viewport
padding, safe-area insets, caller-supplied boundaries, IME avoidance and virtual-keyboard
avoidance are absent.

> [!NOTE]
> `PlacementMode.Relative` declares one combination in `GetNumberOfCombinations` but its
> `GetPointCombination` arm lists four — three of them unreachable.

**Where it lives.** Library code entirely; the only OS inputs are the `MenuDropAlignment`
system parameter and the monitor rects.

**Degradation.** The table is pure integer arithmetic over five points and survives untouched
in cells. `PlacementMode` maps one-to-one onto a list of `(anchorCorner, overlayCorner)`
pairs, which a toolkit can expose _as the value the caller supplies_ instead of as an enum,
making "preferred list plus fallback ordering" data. Because the scorer receives a viewport
rect rather than asking the OS for one, an Android soft-keyboard inset enters as a shrunken
rect — a one-field change. The RTL child-point swap is two swaps and needs no layout system.

### 3. Collision and geometry engine

Overflow detection is a scoring loop, not a boolean. The score is the area of
`Rect.Intersect(screenBounds, translatedChildBounds)`; `screenBounds` comes from
`MonitorFromRect(targetBounds, MONITOR_DEFAULTTONEAREST)` computed from the _anchor_ and
recomputed identically inside the loop, so a candidate that would sit mostly on a neighbouring
monitor scores near zero — the overlay is confined to the anchor's monitor by construction.
Work area (`rcWork`, taskbar-excluded) is used only when the child is a `MenuBase` or `ToolTip`
or the popup's `TemplatedParent` is a `MenuItem`, **and** the anchor's top-left lies inside the
work area; otherwise the full `rcMonitor` (`GetScreenBounds`, `Popup.cs:2655`, with the
rationale for both halves spelled out in the comment at `:2643-2654`). Child popups
(`IsChildPopup`, hosted as `WS_CHILD`) use the parent window's client rect as their "monitor".

After scoring, a clamp pass runs when the intersection differs from the child bounds by more
than `Tolerance`, and it re-measures from `_popupRoot.RenderSize` — the possibly-clipped
actual size — not the desired size:

```text
b = popupRootRenderSize + best
if |intersect(screen, b).w - b.w| > TOL or |…h…| > TOL:
    if anchor's horizontal edge vector is screen-aligned (or the window is opaque):
        if b.right > screen.right: best.x = screen.right - b.w
        elif b.left < screen.left: best.x = screen.left
    if anchor's vertical edge vector is screen-aligned (or the window is opaque):
        if b.bottom > screen.bottom: best.y = screen.bottom - b.h
        elif b.top < screen.top:     best.y = screen.top
```

The clamp is per-axis and conditional on that axis being axis-aligned (`|axis.Y| < Tolerance`);
for a non-transparent popup it always clamps, since such a window cannot be rotated anyway.
Overflow is additionally prevented _before_ placement, at measure time:
`PopupRoot.MeasureOverride` (`PopupRoot.cs:137`) calls `Popup.RestrictSize` (`Popup.cs:2618`),
which clamps to the screen size, to `limitSize` (the larger of the two gaps between anchor and
screen edge along the primary axis — what stops a drop-down covering its own anchor), and to
`RestrictPercentage * screenW * screenH / desiredWidth` with `RestrictPercentage = 0.75`
(`Popup.cs:2935`), an aspect-aware area cap.

**Tracking: there is none.** `Reposition()` is called only from `OnChildChanged`,
`OnPlacementChanged`, `OnOffsetChanged` and `OnWindowResize` (content auto-resize). Nothing
observes scroll, ancestor layout, window movement or monitor change. DPI is handled by
refusal: `OnDpiChanged` marks the event handled while `IsOpen` (`Popup.cs:1880`), and
`PopupInitialPlacementHelper` (`Popup.cs:3492`) creates the HWND at the _anchor monitor's_
origin under Per-Monitor DPI so a `WM_DPICHANGED` never arrives at all.

**Where it lives.** Library code for scoring, restriction and nudging; platform primitives
only for the viewport rect (`MonitorFromRect`/`GetMonitorInfo`) and the final `SetWindowPos`.
Note that size restriction is wired into the _layout_ pass, not the placement pass.

**Degradation.** Everything but the two P/Invokes is portable and already integral —
`DoubleToInt` rounds to whole device pixels, so cells lose nothing. The clipping-ancestor
problem does not exist for an OS window but does for a single-surface toolkit; the substitute
for `screenBounds` is the surface rect intersected with the nearest scroll/clip ancestor, and
nothing downstream changes because the algorithm consumes a rect. The absence of tracking is
the transferable lesson inverted: a canvas toolkit repaints every frame anyway, so re-running
a four-candidate scorer per frame costs on the order of twenty integer operations and removes
WPF's worst behavioural gap for free. The scorer is a pure function
`(anchorPts, childSize, screenRect, mode) -> (x, y)` and is directly unit-testable with no
window — which is what a recording canvas needs.

### 4. Arrow / caret geometry

**Not applicable — WPF has no arrow, beak, tail or caret anywhere in the overlay stack, and
the absence is informative.** The `Popup`/`ToolTip`/`ContextMenu` implementation and the
shipped theme dictionaries read here (`Themes/XAML/ToolTip.xaml` and the Fluent
`PresentationFramework.Fluent/Styles/ToolTip.xaml`) contain no arrow geometry: the default
tooltip template is a `SystemDropShadowChrome` wrapping a `Border` with `CornerRadius=2`;
Fluent uses `CornerRadius=4` plus a `DropShadowEffect`. Because there is no arrow, nothing
feeds an arrow size back into the offset, and there is no corner-constraint or arrow-hiding
logic to have.

The nearest thing to side metadata is two bits derived from _which overlay interest point
won_ (`Popup.cs:2079-2080`):

```text
animateFromRight  = winningChildPoint in {TopRight, BottomRight}
animateFromBottom = winningChildPoint in {BottomLeft, BottomRight}
```

They live in a `BitVector32` and are consumed only by `PopupRoot.SetupTranslateAnimations`
(`PopupRoot.cs:298`) — a transform origin derived from the resolved side, treated as data,
but only two bits of it. `HasDropShadow` is coerced to false unless `AllowsTransparency` and
`SystemParameters.DropShadow` both hold, and the shadow is faked with a 5 px margin and a
`#71000000` chrome colour rather than an arrow-aware border.

**Where it lives.** Not applicable; the two animation-origin bits are written in
`Popup.UpdatePosition` and read in `PopupRoot`.

**Degradation.** In a cell grid an arrow cannot be sub-cell, so it is one glyph in one cell on
the overlay's edge (`▲▼◀▶` or a box-drawing tee) whose along-edge index must be clamped to
`[1, len-2]` so it never lands on a corner glyph — the corner constraint, made trivial by
integer offsets. The lesson from WPF's absence is the inverse of its practice: because
placement emits no side data, the animation layer has to re-derive direction from the winning
point. A placement result that carried `(resolvedAnchorCorner, resolvedOverlayCorner, arrowCell)`
as a plain value would let paint, animation and the arrow all read one number. With no script
(static HTML) the arrow must be emitted at build time from a statically chosen side, which
requires running the scorer at emit time against an assumed viewport — something WPF's scorer
cannot do, because it reads live monitor info.

### 5. Trigger semantics

Two trigger systems share one controller. **Tooltips** use
`ToolTipService.TriggerAction { Mouse, KeyboardFocus, KeyboardShortcut }`
(`ToolTipService.cs:638`). Mouse triggers come from `PostProcessInput` watching the _raw_
`RawMouseActions.AbsoluteMove` report rather than routed `MouseMove`, and when a capture is
active the service re-hit-tests from the root visual to recover the true `directlyOver`,
because capture would otherwise report the capturing element (`PopupControlService.cs:59-77`).
Keyboard-focus triggers fire from `GotKeyboardFocusEvent` but only when
`KeyboardNavigation.IsKeyboardMostRecentInputDevice()` — clicking to focus never shows a
tooltip. The shortcut is `Ctrl+Shift+F10`, and it toggles. Owner discovery differs per
trigger: the mouse path raises a bubbling internal `FindToolTipEvent` so the nearest ancestor
with an enabled tooltip wins; the keyboard paths use the focused element only.

**Context menus** open on right-button _up_ (only if unhandled), `Shift+F10` on key down as a
`SystemKey`, and the `Apps` key on key **up**; all three funnel into
`RaiseContextMenuOpeningEvent(source, x, y, userInitiated)` (`PopupControlService.cs:962`),
which bubbles a cancellable `ContextMenuOpening` and auto-opens only if unhandled. Pointer
type is distinguished by a sentinel: the keyboard path passes `x = y = -1`, which the service
reads back as "opened by keyboard" and turns into `PlacementMode.Center` instead of
`MousePoint`. There is no touch or long-press path and no AT-triggered open.

Races are avoided structurally rather than with locks: one `PopupControlService` per
`Dispatcher`, one pending request (stored on a reused sentinel `ToolTip` carrying only
`Owner` and `FromKeyboard`), one current tooltip, and a `LastMouseToolTipOwner` latch so
re-entering the same owner is a no-op until the pointer leaves it.

```text
onRawMouseMove(pt):
    if anyButtonDown: dismissAll(); return
    over = rawDirectlyOver; if captureActive: over = rootHitTest(pt)
    if mouseHasLeftSafeArea(): dismissCurrent()
    if over != lastDirectlyOver: lastDirectlyOver = over
                                 beginShow(findOwnerByBubbling(over), Mouse)
    else if pendingTimer.isShortDelay: currentTooltip == null ? promoteNow() : restartTimer()

onKeyDown: Ctrl+Shift+F10 -> toggle; Shift+F10 -> contextMenu; remember a lone Ctrl down
onKeyUp:   Apps -> contextMenu; lone Ctrl released and current tooltip fromKeyboard -> dismiss
```

**Where it lives.** Library code, in a singleton controller hooked to the framework's input
pipeline; owner discovery rides the routed-event system.

**Degradation.** The taxonomy transfers; the plumbing does not. Post-process interception maps
onto a canvas toolkit's single event route, and bubbling owner discovery becomes a walk up the
flat hit list from the hit cell — cheaper than WPF's, because the list is already flat. On a
terminal there is **no key release at all**, so the `Ctrl`-up dismissal and the `Apps`-up
context menu are unimplementable and must move to a press edge; the discrimination "a lone
modifier" then becomes "ignore any modifier that arrives with another key". (WPF's release-edge
key handling is not confined to the overlay stack: `KeyboardNavigation.cs:3189-3200` enters
menu mode on an `Alt`/`F10` key _up_ matched against the last key down, which is a real focus
move on a release edge.) With no hover (Android) the mouse trigger disappears entirely, leaving
long-press, focus and programmatic opens — a case WPF never had to design.

### 6. Timing

Four timers and one boolean. `InitialShowDelay` defaults to **1000 ms**
(`ToolTipService.cs:393`), changed in .NET 6 from `SystemParameters.MouseHoverTimeMilliseconds`
≈ 400, which the spec calls "too short" (`specs/tooltip.md:145-151`). `ShowDuration` defaults
to **`Int32.MaxValue`** ≈ 24.8 days (`ToolTipService.cs:360`), changed from 5000; the spec
permits honouring that literally or disabling the timer, and the implementation honours it
literally by starting a `DispatcherTimer` with that interval. `BetweenShowDelay` defaults to
**100 ms** (`ToolTipService.cs:426`). An internal `ShortDelay = 73` ms
(`PopupControlService.cs:1732`) is the debounce that resolves "moving toward the tooltip"
versus "hovering a new owner", explained in the source (`PopupControlService.cs:344-347`):

> We use a heuristic to compromise between these conflicting expectations.
> We'll put the pending request on a timer with a very short interval.
> If the user moves the mouse within the interval, we restart the timer;
> this keeps the tooltip open as long as the user keeps moving the mouse.

`BetweenShowDelay` is the cool-down: on close, `_quickShow = (betweenShowDelay > 0)` and a
timer of that length is armed; while `_quickShow` holds, the next tooltip — for _any_ owner —
opens with zero delay. The flag is a single bool on the singleton, so although the duration is
read from the **closing** tooltip's owner, the warmth it grants is global.

```text
beginShow(owner, trigger):
    if trigger == Mouse:
        if owner == lastMouseOwner: return                 // latch: no re-show on same owner
        lastMouseOwner = owner
    if owner is null or owner == pendingOwner or owner == currentOwner: return
    showNow = quickShow; useShort = false; toReplace = current
    if not showNow: switch trigger
        Mouse:            if safeArea != null: useShort = true
        KeyboardFocus:    showNow = toReplace?.fromKeyboard ?? false
        KeyboardShortcut: toReplace = null; showNow = true
    if toReplace != null and (showNow or useShort) and betweenShowDelay(toReplaceOwner) == 0:
        showNow = useShort = false                         // PopupControlService.cs:366-375
    delay = showNow ? 0 : useShort ? 73 : initialShowDelay(owner)
```

> [!WARNING]
> The `betweenShowDelay == 0` branch at `PopupControlService.cs:366-375` cancels **both** fast
> paths when replacing a tooltip, forcing the full `InitialShowDelay`. Setting the cool-down
> to its "off" value therefore makes tooltip replacement slower, not faster.

Submenu timing is a separate, simpler machine on `MenuItem`: `_openHierarchyTimer` and
`_closeHierarchyTimer`, both at `SystemParameters.MenuShowDelay` (`SPI_GETMENUSHOWDELAY`,
`MenuItem.cs:2565`); a top-level header opens immediately when already in menu mode.

**Where it lives.** Library code — the controller, the attached properties, and `MenuItem`'s
own timers. No OS timer involvement; all `DispatcherTimer` at `DispatcherPriority.Normal`.

**Degradation.** The machine this suggests is `{Idle, Pending(owner, trigger, deadline),
Shown(owner, deadline), Cooldown(deadline)}` with `step(state, event, now) -> (state, effects)`:
a pure function of a value struct plus a clock, which is exactly what a recording canvas can
assert by feeding synthetic timestamps. Keep the four separable knobs; fix the two flaws —
make the cool-down's scope a design decision rather than an accident of one shared bool, and
never let a zero cool-down reintroduce a delay. On static HTML there are no timers at all, so
every delay collapses to zero and `:hover` alone drives it; warm-up and cool-down are simply
absent. Without hover, the whole timing layer is replaced by long-press duration, which belongs
to a gesture recognizer rather than the overlay.

### 7. Interactive hover (safe polygon)

WPF's safe polygon is a **convex hull**, not a triangle. On open, `SetSafeArea`
(`PopupControlService.cs:834`) collects the owner's rect — or N rects via
`IContentHost.GetRectangles` for a `ContentElement` such as a `Hyperlink` spanning several
lines — plus the tooltip's screen rect converted to client coordinates, and hulls all corner
points. The single-rect case short-circuits: the hull is the rect itself, corners emitted
counter-clockwise with edge directions preset. Otherwise an insertion sort by `(y, x)` —
justified in a comment because the points are nearly ordered already — feeds an incremental
build that processes one scanline of equal-`y` points per iteration, locating the splice range
by walking outward from the previous extremes (binary search is explicitly rejected as not
worth the overhead at N ≈ 8).

```text
buildHull(rects):
    if rects.len == 1: return rect corners CCW, directions preset
    pts = all 4 corners of each rect; insertionSortBy(y, then x)
    hull = []
    for each scanline of equal y (leftmost L, rightmost R):
        if hull empty: seed with (R, L) or (L)
        else:
            minIdx = walk CW  from prevLeftIdx  while cross(L, p[i], p[i-1]) <= 0
            maxIdx = walk CCW from prevRightIdx while cross(R, p[i], p[i+1]) >= 0
            splice [minIdx+1, maxIdx) := [L] or [L, R]
    setDirections()          // Left / Right / Up / Down / Skew per outgoing edge

contains(x, y):
    for v in hull:           # pass 1 — no multiplies
        Left  and y <  v.Y -> false;   Right and y >= v.Y -> false
        Up    and x >= v.X -> false;   Down  and x <  v.X -> false
    for v in hull:           # pass 2 — skew edges only
        Skew and cross(v, next(v), (x, y)) > 0 -> false
    return true
```

Each hull vertex caches a `Direction ∈ {Left, Right, Up, Down, Skew}`, so containment runs two
passes: axis-aligned edges decided by bare integer comparisons — the `<` versus `>=` choice
also buys exclusive bottom/right semantics for free — and cross-products only for skew edges
(`PopupControlService.cs:1638`, `:1694`). Coordinates are small client-space integers from
`WM_MOUSEMOVE`, so the cross-product cannot overflow.

The hull is computed **once at open and never updated**; the spec accepts a dangling safe area
if layout scrolls underneath it. Mouse events inside the hull are deliberately _delivered_ to
whatever is beneath rather than swallowed. Submenus get none of this — `MenuItem` uses only
open/close timers, so there is no menu-aim triangle here.

The spec records why the alternatives lost (`specs/tooltip.md:204-214`): the bounding rectangle
of both was "too large", and a rectangle around the _shortest_ connecting line failed a
usability study because people move along any convenient straight line —

> the "any straight line" usability requirement leads naturally to the convex hull (it's
> equivalent to the definition), which is a non-rectangular area that includes P and T.

**Where it lives.** Pure library code — the private nested `ConvexHull` class plus
`SetSafeArea`/`MouseHasLeftSafeArea`. The only OS contact is reading the pointer position.

**Degradation.** This is the most transferable algorithm in the subject. In whole cells: a hull
of at most eight integer corners, containment in at most eight comparisons plus at most four
cross-products of small integers — no allocation, `@nogc`, and straightforwardly `@safe`. For
an axis-aligned anchor and overlay the hull has four to six vertices of which at least four are
axis-aligned, so pass 1 usually decides. Cell quantisation _helps_: the spec spends a paragraph
on pointer "drift" through a narrow corridor, and a one-cell-wide diagonal corridor is roughly
eight pixels, so that worry largely evaporates. Where hover does not exist the hull must not be
computed at all, which argues for the safe area being an optional field on the overlay record
rather than always-on state. On a recording canvas `contains()` is a pure predicate over a
value, assertable with synthetic pointer paths.

### 8. Dismissal

Two independent regimes. **Popup with `StaysOpen=false`** takes
`Mouse.Capture(_popupRoot, CaptureMode.SubTree)` and closes on any mouse button press _or_
release whose `OriginalSource` is `_popupRoot` and whose position fails
`_popupRoot.InputHitTest` — an explicit hit test is required because the event args cannot say
whether the event arrived by capture or genuinely. App deactivation (`WM_ACTIVATEAPP` with
`wParam == 0`, marshalled back onto the `Dispatcher`) closes it. Losing capture to anything
outside closes it, unless a drag-drop is active, which class handlers suppress and then
re-establish. Unloading from the visual tree closes it. Reopening from inside a `Closed`
handler throws `PopupReopeningNotAllowed` (`Popup.cs:350`) rather than recursing.

**Tooltips** are dismissed by: any mouse down, any mouse up, any raw move while a button is
held, `Deactivate`, `ShowDuration` expiry, leaving the safe area, any keyboard focus change
(keyboard-triggered tooltips only), a lone `Ctrl` press-and-release, `Ctrl+Shift+F10`, opening
a context menu, and text-editor activity — `TextEditorTyping`, `TextEditorMouse` and `TextStore`
(IME composition) all call `DismissToolTipsForOwner`.

> [!WARNING]
> The shipped spec states that `ESC` closes any open tooltip (`specs/tooltip.md:87`, restated as
> a KeyDown response at `:162-163`), but there is no `Key.Escape` handling in
> `PopupControlService` at this revision — only `Ctrl` on key up and `Ctrl+Shift+F10`. Docs and
> source disagree; the source wins.

Menus dismiss through `PreviewMouseDownOutsideCapturedElement` /
`PreviewMouseUpOutsideCapturedElement` (`MenuBase.OnClickThrough`), with
`IgnoreNextLeftRelease`/`IgnoreNextRightRelease` latches so the button-up that _opened_ the menu
does not immediately close it. For nested popups, opening a child steals capture and records the
parent's `PopupRoot` in `ParentPopupRootField`; closing restores capture to the parent and, if a
button is still down, sets `IsIgnoringMouseEvents` so one outside click cannot dismiss two levels
(`Popup.cs:1143-1154`). Scroll, anchor hidden, anchor moved, navigation and window resize are not
dismissal sources at all.

**Where it lives.** Library code plus one platform signal. Outside-click detection is built on
WPF's own _logical_ capture and a manual hit test — not a Win32 `SetCapture` grab; the code only
_queries_ `GetCapture()` to detect that someone else holds a real grab. `WM_ACTIVATEAPP` is the
one true OS input.

**Degradation.** Most of this transfers, because "route the event to the overlay first, hit-test,
close if it misses" is precisely what a single-surface toolkit with reverse-paint-order hit
testing does natively, and without a pointer grab. The behaviour that genuinely needs a grab is
events _outside the surface_; WPF's substitute is `WM_ACTIVATEAPP`, whose toolkit analogue is a
window/terminal focus-lost event that every backend can supply. The `IsIgnoringMouseEvents` latch
should be copied verbatim. Without key release the `Ctrl`-up dismissal is unimplementable and the
press-versus-release distinction on outside clicks collapses to press only; on Android the system
Back key must be wired as an additional dismissal source, which WPF has no concept of.

### 9. Focus

The surface kinds are kept rigorously distinct.

**Tooltip:** `FocusableProperty` is overridden to `false` in the static constructor
(`ToolTip.cs:27`); the window carries `WS_EX_NOACTIVATE` and answers `WM_MOUSEACTIVATE` with
`MA_NOACTIVATE` (`Popup.cs:1748-1751`) —

> Don't let the popup become active -- we don't want the main window
> to become inactive because of the popup.

— and when `StaysOpen` is true (mandatory for service-shown tooltips, which throw
`NotSupportedException` otherwise, `PopupControlService.cs:456`) the HWND additionally gets
`WS_EX_TRANSPARENT` so the pointer passes straight through (`ToolTip.cs:507`,
`HitTestable = !StaysOpen`). A tooltip can therefore never take focus, never take capture, and by
default is not even hit-testable — but note this is a policy over arbitrary `ContentControl`
content, not a restriction on the content's type.

**ContextMenu / MenuBase:** `FocusManager.IsFocusScopeProperty` is overridden to true,
`KeyboardNavigation.TabNavigation = Cycle` and `ControlTabNavigation = Contained` — containment,
not a hard trap. The previously focused element is stored in a `WeakReference<IInputElement>` on
entering menu mode and restored on leaving, but only if focus has not already moved out:
`ContextMenu.OnIsKeyboardFocusWithinChanged` (`ContextMenu.cs:624-638`) nulls the weak reference
when focus leaves, so a menu dismissed _by_ focus loss does not yank focus back. Entering menu
mode is ordered carefully — `OnPreviewKeyboardInputProviderAcquireFocus` pushes menu mode before
focus actually moves, with a companion handler to pop it if acquisition failed.

**Popup (generic):** no initial focus at all; focus is whatever the child does. **Dialog:** out
of scope — `Window`, deliberately not built on `Popup`.

**Where it lives.** Split: focusability and scoping are library-level; non-activation and
click-through are platform primitives (`WS_EX_NOACTIVATE`, `WS_EX_TRANSPARENT`, `MA_NOACTIVATE`)
set in `PopupSecurityHelper`.

**Degradation.** The taxonomy is the portable part: tooltip = never focusable and never
hit-testable; menu/popover = focus containment plus restore-if-not-stolen; dialog = a different
primitive. In a single-surface toolkit `WS_EX_TRANSPARENT` becomes "do not add this overlay's
rects to the derived hit list" — one bit on a display-list entry, strictly simpler than the OS
version. The `WeakReference` for focus restore becomes a plain index into the widget arena, with
value semantics and no GC. A terminal has one focus ring and no OS activation to lose, so all of
this works; on Android, focus restore matters more because the soft keyboard moves focus, and
Back must restore focus the way a menu close does.

### 10. Layering and portals

**Every `Popup` is a real OS window, one per instance, and that single fact drives most of the
design.** `PopupSecurityHelper.BuildWindow` (`Popup.cs:3287`) creates an `HwndSource` with
`WS_CLIPSIBLINGS | WS_POPUP` and `WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TOPMOST`, parented
to the anchor's HWND only if that chain reaches the foreground window
(`ConnectedToForegroundWindow`, `:3371`) — otherwise unparented, so a popup from a background app
does not drag its owner forward. `AllowsTransparency` maps to `UsesPerPixelOpacity` →
`WS_EX_LAYERED` and is fixed at window-creation time. A second mode, `IsChildPopup`, creates a
`WS_CHILD` window whose "screen" is the parent's client rect and which must be z-ordered behind
any embedded web control (`GetLastWebOCHwnd` walks sibling HWNDs by class name) — legacy from
XBAP hosting, but structurally it is the shape of "no top layer available".

```text
open():
    if perMonitorDpi: destroyHwnd(); recreate
    origin = prevPosition ?? monitorOriginOfPlacementTarget()      // dodge WM_DPICHANGED
    hwnd = CreateWindow(WS_POPUP | WS_CLIPSIBLINGS,
                        WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TOPMOST,
                        parent = connectedToForeground(targetHwnd) ? targetHwnd : 0)
    hwnd.RootVisual = PopupRoot(Decorator(AdornerDecorator(child)))
    UpdatePosition(); ShowWindow(SW_SHOWNA)
close():
    hide; destroy on a DispatcherTimer at Input priority
    // below Render priority, so a menu click still routes before disposal
```

The consequences are spelled out in the source: `WM_WINDOWPOSCHANGING` must force
`SWP_NOCOPYBITS` for child popups because DirectX rendering breaks Windows' blit optimisation
(`Popup.cs:1761-1785`); under Per-Monitor DPI the HWND is destroyed and recreated on every open so
a recycled handle cannot cross monitors and receive a fatal `WM_DPICHANGED`. Overlay _trees_ exist
as ownership chains rather than a real tree: `ParentPopupRootField` (an `UncommonField<PopupRoot>`)
records who held capture, and `DropOpposite` walks up through `PopupRoot.Parent as Popup`.

The public/private split is instructive. Public: `Popup`, `Child`, `IsOpen`, the `Placement*`
family, `StaysOpen`, `PopupAnimation`, `AllowsTransparency`, `HasDropShadow`,
`CustomPopupPlacement`, `PopupPrimaryAxis`, `Popup.CreateRootPopup`. Implementation detail:
`PopupRoot`, `PopupSecurityHelper`, `PopupControlService`, `TreatMousePlacementAsBottom`,
`HitTestable`, `DropOpposite`, `ParentPopupRootField` and every HWND style.

**Where it lives.** Platform primitive, wrapped by `PopupSecurityHelper` — a private nested class
that exists solely to concentrate the P/Invokes.

**Degradation.** This is the dimension that does _not_ transfer, and knowing precisely why is the
value. Everything WPF gets free from the OS — escaping clipping, topmost stacking, per-window
opacity, an independent hit-test region — a single-surface toolkit must supply as data: paint
order, an explicit clip rect the overlay is exempt from, and an opt-out bit in the hit list to
reproduce `WS_EX_TRANSPARENT`. The compensations are real: no HWND means no `WM_DPICHANGED`
recreate dance, no `SWP_NOCOPYBITS`, no activation refusal, no MSAA→UIA bridge, and no popup left
stranded when the window moves. The part worth keeping is the ownership chain — a parent pointer
per overlay, an integer index in an arena — because that is what makes cascade flip inheritance
and one-click-one-dismissal correct.

### 11. Modality

Three levels, none of them OS-modal.

```text
level 0  passthrough:  IsHitTestVisible = false; if layered: exStyle |= WS_EX_TRANSPARENT
level 1  lightDismiss: if Mouse.Captured is another PopupRoot: remember it, steal capture
                       else Mouse.Capture(popupRoot, SubTree)
                       onLost: if nobody else took it -> retake, mark handled
level 2  menuMode:     if !Mouse.Capture(menu, SubTree): abort menu mode
                       InputManager.PushMenuMode(src) -> src.OnEnterMenuMode():
                           subscribe ThreadPreprocessMessage first; HideCaret()
                       inherit InputMethod.IsInputMethodSuspended = true
```

Level 0 is `StaysOpen=true` (the default) plus, for tooltips, `WS_EX_TRANSPARENT`; `SetHitTestable`
(`Popup.cs:1448`) toggles both the managed `IsHitTestVisible` and the Win32 ex-style, touching the
latter only when the window is layered. Level 1 is mouse-only: there is no keyboard or touch
capture in `Popup`, so a `StaysOpen=false` popup does not block keystrokes, and the capture is
fragile by the code's own admission — `OnLostMouseCapture` carries a "workaround until we can get
real subcapture" comment citing bug 940198. Level 2 additionally calls
`InputManager.PushMenuMode`, which makes the `HwndSource` re-subscribe to
`ComponentDispatcher.ThreadPreprocessMessage` so it runs _first_ on every thread message and hides
the Win32 caret; if capture cannot be taken, menu mode self-clears immediately. Menus also set
`InputMethod.IsInputMethodSuspended` so keystrokes are not dispatched to the IME while open. There
is no scrim, no dim and no `aria-modal` analogue.

**Where it lives.** Library code decides the level; enforcement splits between WPF's own input
manager (logical capture, menu mode, message-preprocessing priority) and two Win32 primitives.

**Degradation.** The ladder is expressible with two booleans on an overlay record: `hitTestable`
and `capturesPointer`. Level 0 is free — omit from the hit list. Level 1 needs no OS grab in a
single-surface toolkit, because every event already routes through the toolkit, so "capture"
degenerates to "consult the topmost open overlay first" — which appears strictly more robust than
WPF's admittedly fragile capture chain, since there is no external component that can steal it.
Level 2 becomes a routing-priority flag. What genuinely degrades is events _outside the surface_,
where `HandleDeactivateApp` is the model to copy: treat surface-focus-loss as an unconditional
dismiss for every light-dismiss overlay. On Android the Back key must be the level-1/2 dismissal,
and passthrough has no touch meaning.

### 12. Adaptive presentation

Partial. WPF has essentially one adaptive behaviour, and it is a good miniature of how to do it.
`Popup.PlacementInternal` (`Popup.cs:456`) reads `Placement` and, if it is `Mouse` or `MousePoint`
_and_ the internal `TreatMousePlacementAsBottom` flag is set, substitutes `Bottom`. The flag is
one-way-bound to `ToolTip.FromKeyboard` by `CreateRootPopupInternal`, and `FromKeyboard` is written
by the controller from the trigger action:

```text
PlacementInternal = (Placement in {Mouse, MousePoint} and TreatMousePlacementAsBottom)
                        ? Bottom : Placement
TreatMousePlacementAsBottom  <== OneWay binding <== ToolTip.FromKeyboard
FromKeyboard := isFromKeyboard(triggerAction)          // KeyboardFocus | KeyboardShortcut

contextMenu: (x, y) == (-1, -1) -> Placement = Center       // keyboard
             else               -> Placement = MousePoint   // mouse
```

So: a tooltip triggered by the keyboard cannot anchor to the cursor, so it silently re-anchors to
the element. The context-menu analogue is cruder and lives in the controller as a magic sentinel
coordinate (`PopupControlService.cs:1006`). There is no touch adaptation — no long-press tooltip,
no popover-to-sheet — no compact-width behaviour and no keyboard-driven relocation; touch reaches
the system only as promoted mouse input, and the controller never inspects a stylus or touch
device.

**Where it lives.** The _decision_ is in the primitive; the _input_ to it is supplied by the
component through a data binding, so the primitive never learns what a keyboard is. The
context-menu variant is decided in the controller and is correspondingly uglier.

**Degradation.** The layering answer generalises: the primitive owns the substitution rule, the
component owns the fact. A cursor-anchored placement must be able to degrade to a rect-anchored
placement given one boolean, and that boolean must be an _input_ rather than something the
primitive discovers. Where there is no hover at all, every cursor-anchored placement is
permanently in the degraded branch and the substitution must be automatic; a static HTML emitter
has no pointer position at emit time and reaches the same conclusion; a terminal has hover and a
real cell cursor, so cursor anchoring is genuinely available there. A soft-keyboard inset belongs
in this dimension too, as an explicit viewport-inset input to the scorer — WPF has no equivalent
and could not add one without changing `GetScreenBounds`.

### 13. Accessibility

UIA is the tree. `ToolTip` maps to `ToolTipAutomationPeer` with `AutomationControlType.ToolTip`;
`ContextMenu` to `ContextMenuAutomationPeer`; and the internal `PopupRoot` to
`PopupRootAutomationPeer` with **`AutomationControlType.Window`** and class name `Popup` — the
extra HWND is honestly reported as a window. Because UIA cannot connect that HWND to the main
window, `ForceMsaaToUiaBridge` (`Popup.cs:3425`) manually pumps
`AutomationInteropProvider.ReturnRawElementProvider` and `ObjectFromLresult` to force the MSAA→UIA
bridge, which a comment calls a deficiency in `UIAutomationCore`; it runs only when
`IsWinEventHookInstalled` reports that an assistive technology is actually listening.
`AutomationEvents.ToolTipOpened` is raised asynchronously at `DispatcherPriority.Input` so the
`PopupRoot` has time to hook up; `ToolTipClosed` is raised synchronously.

The .NET 6 tooltip work is driven by the requirement list at `specs/tooltip.md:26-28`, whose first
entry is WCAG 2.1 §1.4.13. The mechanisms it delivers are the convex-hull safe region
(`:95-104`), a `ShowDuration` default raised from 5000 to `Int32.MaxValue` with explicit
permission to disable the timer instead (`:147-151`, restated at `:284`), and single-key dismissal —
`Ctrl` on key up, `Esc` on key down (`:158-163`). The spec also records the decision that tooltips
must not be focusable or appear in the tab order (`:198`), and notes that
`ShowsToolTipOnKeyboardFocus` is hidden from the designer because setting it breaks accessibility
(`ToolTipService.cs:459-470`).

**Where it lives.** Split between library automation peers and the accessibility API itself. The
bridge hack lives in the platform layer, because it exists only because the overlay is a separate
HWND.

**Degradation.** What belongs to the primitive: the open/close _notification_ (something opened,
anchored here, with this text) and the guarantee that a tooltip is neither focusable nor in the tab
order. What belongs to a semantic component: whether the content is a description or a label, and
whether it is a menu, listbox or dialog. A terminal grid can honestly expose almost nothing of a
UIA tree, but it can expose two things that matter more than a role name — the overlay's text is
present in the cell buffer and therefore in the terminal's own accessibility path, and _paint
order_, which means an overlay must be painted so that a screen-reader-driven terminal reads it
after its anchor. The honest terminal contract is therefore "text, reading order, and a dismissal
path that does not require a key release"; claiming `role=tooltip` would be a lie. WPF's own hazard
applies verbatim: hover-only content is invisible to keyboard users, so a keyboard trigger is not
optional.

### 14. Animation

`PopupAnimation ∈ {None, Fade, Slide, Scroll}`, defaulting to `None` and coerced to `None` unless
`AllowsTransparency` — an unlayered HWND cannot fade. The duration is a hard-coded
`AnimationDelay = 150` ms (`Popup.cs:2901`), not a theme value.

```text
on placement resolved:
    animateFromRight  = childPoint in {TopRight, BottomRight}
    animateFromBottom = childPoint in {BottomLeft, BottomRight}
show: Fade   -> Opacity 0 -> 1 over 150 ms
      Slide  -> translate.Y from ±h to 0
      Scroll -> translate.X from ±w to 0 (flipped if FlowDirection differs) and translate.Y
hide: Fade   -> 1 -> 0 over 150 ms, then destroy the hwnd
      else   -> hide immediately; destroy on an Input-priority tick
reposition during animation: childPts computed from (rect - PopupRoot.AnimationOffset)
```

So the placement engine does emit geometry metadata specifically to drive animation — but only two
bits of it. The animated translate lives on the inner adorner decorator's `RenderTransform`, and
`GetChildInterestPoints` subtracts `PopupRoot.AnimationOffset` before computing child points
(`Popup.cs:2399-2409`) so that a reposition _during_ an animation measures the settled geometry
rather than the animated one — a subtle correctness detail that is easy to miss.
`_transformDecorator.ClipToBounds = true` keeps a slide clipped to the window. Exit is asymmetric:
`Fade` animates both directions, `Slide`/`Scroll` only on show. Window destruction is deferred by a
`DispatcherTimer` of exactly `AnimationDelayTime` at `DispatcherPriority.Input`, with an explicit
comment that it must sit below `Render` priority so a menu click still routes before disposal.
Reduced motion is honoured indirectly: the themes bind `PopupAnimation` to
`SystemParameters.ToolTipPopupAnimationKey` and its menu/combobox siblings.

**Where it lives.** Library code end to end, on WPF's own animation system; the only platform
dependency is that `Fade` needs `WS_EX_LAYERED`.

**Degradation.** The transferable idea is small and cheap: the placement result should carry the
resolved corners so the animation layer never re-derives a direction. In cells the vocabulary
shrinks to a reveal along one axis (paint N of M rows or columns per frame); opacity fade is
unavailable on a terminal and approximated on raylib. The "subtract the animation offset before
re-measuring" rule matters on any immediate-mode backend that repositions every frame: measure the
settled geometry, animate the delta at paint time, and never feed an animated position back into
the scorer. Static HTML has no script but does have CSS transitions, so an enter animation is the
one animation that survives with no timers. On a recording canvas, because the origin is two bits
of data, an animation-direction assertion is a plain equality check on the frame record.

### 15. State architecture

Partial — two different architectures sit side by side.

**The primitive is declarative.** `Popup` state is dependency properties with coercion:
`CoerceIsOpen` refuses to open an unloaded in-tree popup and instead registers an `OpenOnLoad`
handler, `CoerceVisibility` forces `Collapsed`, and `CoerceAllowsTransparency`/`CoerceHasDropShadow`
gate on system settings. Alongside them sit **ten packed booleans in a single `BitVector32`**
(`CacheBits`, `Popup.cs:2917`): `CaptureEngaged`, `IsTransparent`, `OnClosedHandlerReopen`,
`DropOppositeSet`, `DropOpposite`, `AnimateFromRight`, `AnimateFromBottom`, `HitTestable` (stored
inverted so the default is true), `IsDragDropActive`, `IsIgnoringMouseEvents`. Position state is one
small mutable `PositionInfo { int X, int Y, Size ChildSize, Rect MouseRect }`. `IsOpen` is
`BindsTwoWayByDefault` and the framework always writes it through `SetCurrentValueInternal`
(`Popup.cs:1120`), so a user binding is never clobbered — WPF's exact answer to the
controlled/uncontrolled problem.

**The controller is imperative and ad hoc.** `PopupControlService` holds `_pendingToolTip`,
`_pendingToolTipTimer`, `_sentinelToolTip`, `_currentToolTip`, `_currentToolTipTimer` (double duty:
show duration _and_ between-show cooldown), `_forceCloseTimer`, `_lastCtrlKeyDown`, two weak
history slots and `_quickShow`. There is no reducer and no FSM type; the state machine exists only
as the control flow of `BeginShowToolTip`. The pending request is encoded as a reused sentinel
`ToolTip` object whose only meaningful state is two dependency properties, created lazily because
constructing it in the constructor would recurse through `FrameworkServices`. Re-entrancy is a
first-class hazard, flagged in three places with `** Public callout - re-entrancy is possible **`
and defended by re-reading `_currentToolTip` and `IsOpen` after every callout.

**Where it lives.** Library code, but heavily coupled to the `DependencyProperty` machinery:
coercion, two-way binding defaults, attached properties as per-instance storage, and
`UncommonField<T>` for sparse state.

**Degradation.** Half survives, half must be replaced. Survives: the ten-flag `BitVector32` is
already the value-semantics, `@nogc` answer; `PositionInfo` is a four-field POD; the sentinel
pending request becomes an optional `struct { WidgetId owner; TriggerKind trigger; }`; and
`SetCurrentValueInternal` maps onto "framework writes never overwrite an app-set value", which a D
toolkit expresses as an explicit `controlled` field. Must be replaced: the whole
`DependencyProperty` substrate is unavailable and unnecessary, and the six `DispatcherTimer` objects
become deadline fields polled by the frame loop — which is better for a recording canvas, because
time becomes an input. The underrated lesson is the re-entrancy discipline: any design that raises
app callbacks mid-transition must re-validate its own state afterwards, and a value-semantics FSM
(`step(state, event, now) -> (state, effects)`) removes the hazard by construction, because effects
are applied after the transition rather than during it.

### 16. Shared infrastructure

WPF factors this unusually cleanly. **One primitive** (`Popup`) serves `ToolTip`, `ContextMenu`,
`MenuItem` submenus, `ComboBox`, `DatePicker`, `ToolBar` overflow and `Slider`. The glue is
`CreateRootPopupInternal`, which one-way-binds eight properties from the child up to the popup in a
deliberate order:

```text
CreateRootPopupInternal(popup, child, bindKeyboardFlag):
    assert child has no logical and no visual parent
    bind popup.PlacementTarget <- child.PlacementTarget   // FIRST: resource lookup needs it
    popup.Child = child                                   // establishes logical parenting
    bind VerticalOffset, HorizontalOffset, PlacementRectangle,
         Placement, StaysOpen, CustomPopupPlacementCallback
    if bindKeyboardFlag: bind TreatMousePlacementAsBottom <- child.FromKeyboard
    bind IsOpen                                           // LAST (comment says so explicitly)
```

That ordered list is effectively the anchored-overlay interface, discovered empirically over two
decades. **One controller** serves both tooltips and context menus, because both need the same
post-process input hook and both must be able to dismiss the other. **Two symmetric attached-property
services** expose `HorizontalOffset`, `VerticalOffset`, `PlacementTarget`, `PlacementRectangle`,
`Placement`, `HasDropShadow`, `IsEnabled` and `ShowOnDisabled` with identical shapes, resolved by one
shared rule:

```text
coerceProperty(popup, value, dp):
    owner = popup.Owner
    if owner has a non-default value for dp: return owner.GetValue(dp)
    if dp is PlacementTarget:                return targetUIElementOf(owner)
    return value
```

`OnOwnerChanged` re-coerces all six placement properties whenever the owner changes, which is what
lets one `ToolTip` instance be reused across owners.

What stays apart is as informative as what is shared: tooltips are non-focusable, non-hit-testable,
timed and forbidden from `StaysOpen=false`; menus are focus scopes with capture, menu mode, IME
suspension, arrow-key navigation, `MenuShowDelay` submenu timers and `DropOpposite` chaining;
`ComboBox`/`DatePicker` popups are plain `StaysOpen=false` popups declared in XAML, sharing nothing
but the primitive. The one place the abstraction leaks is `GetScreenBounds` type-testing its own
child (`Child is MenuBase || Child is ToolTip || TemplatedParent is MenuItem`, `Popup.cs:2677`) to
choose work-area versus full-monitor bounds — a primitive reaching upward to identify its consumers.

**Where it lives.** Library code throughout: the composition root in `Popup`, the property-resolution
rule in `PopupControlService`, and the two symmetric public façades.

**Degradation.** The eight-binding list is a concrete answer to what belongs in one anchored-overlay
value: anchor (target, rect, offsets), placement mode plus a custom candidate source, dismiss policy,
and open state — nothing else. Passing that set as one struct by value also deletes the "bind `IsOpen`
last" ordering hazard, because the whole spec arrives at once, and lets the work-area/full-surface
choice be a `boundsPolicy` field instead of a type test on the content. The controller split is worth
copying too: one shared input-hook controller for hover-timed surfaces, because tooltips and context
menus must be able to dismiss each other and cannot do so from separate owners.

## Named algorithms worth lifting

| Algorithm                         | Shape                                                                                                                                 | Portability off Win32                                                                             |
| --------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| Interest-point candidate scoring  | 5 anchor points × 5 overlay points, a per-mode ordered pair table, area-of-intersection score, tolerance-guarded ties, early exit     | Complete. Needs integer points, a size, a viewport rect and a candidate table; ~20 integer ops    |
| Nudge (axis-conditional clamp)    | Re-measure from the rendered size; clamp the far edge in first, pin the near edge second; per-axis, only when that axis is aligned    | Simpler in cells — with no rotation the alignment tests are constant-true                         |
| `DropOpposite` (flip inheritance) | On a cross-axis flip, set a flag; descendants without their own flag inherit the nearest ancestor's and reverse their candidate table | A boolean plus a parent pointer; an arena index loop. Essential for cascades                      |
| Convex-hull safe area             | Hull of ≤ 8 integer corners; direction-tagged edges; two-pass containment (comparisons, then cross-products only for skew edges)      | Highest-value item here; whole-cell quantisation removes the drift concern the spec worries about |
| Tooltip promotion machine         | One pending request, one current tooltip, trigger-chosen delay, a global warm flag armed on close                                     | Yes, once the timers become deadline fields compared against a frame clock                        |
| `RestrictSize` (measure-time cap) | Clamp to viewport, to the anchor-to-edge gap, and to 75 % of viewport area ÷ width; re-measure once so text can rewrap; clip last     | Integer arithmetic on cell counts; the two-pass measure is what a text-heavy cell layout wants    |
| `GetMouseCursorSize`              | Scan the cursor mask bitmap for the drawn extent, with a fallback for all-inverted cursors (I-beam, crosshair)                        | Not portable, and should not be — in cells the cursor's visible extent _is_ one cell              |

> [!NOTE]
> `GetMouseCursorSize` is worth understanding even though it cannot be ported: the requirement
> behind it is that a cursor-anchored overlay must offset by the cursor's _visible_ extent rather
> than its hotspot, or the overlay lands under the pointer graphic. In a cell grid that is exactly
> one cell — a case where the cell constraint deletes ~120 lines of bitmap scanning.

## Strengths

- The candidate-scoring engine is a smaller abstraction than side-plus-fallback lists: twelve
  modes, one table, one scorer, and `Custom` drops in as just another candidate source.
- `CustomPopupPlacementCallback` is the right shape for an escape hatch — the app returns _data_
  and the framework still owns collision, scoring and clamping, so an app cannot accidentally place
  an overlay off-screen.
- Anchors are five points rather than a rect, so arbitrarily transformed anchors work; the rect is
  synthesised only for scoring.
- The convex-hull safe area is a precise, cheap, integer-only implementation, and the spec records
  _why_ the rectangular alternatives failed.
- `BetweenShowDelay` is a clear formulation of the cool-down: one duration, one flag, zero delay
  while warm.
- Trigger provenance flows all the way through — `FromKeyboard` travels from controller to `ToolTip`
  to `PlacementInternal`, so a keyboard-triggered tooltip silently re-anchors from cursor to element.
- Dismissal is exhaustively enumerated: press and release outside, app deactivation, capture loss,
  tree unload, editor typing, IME composition, focus change, lone `Ctrl`, duration expiry, safe-area
  exit, context-menu opening.
- Nested-overlay hygiene: capture is restored to the parent popup, and `IsIgnoringMouseEvents`
  prevents one outside click from dismissing two levels.
- `DropOpposite` makes flip decisions inherit down a cascade instead of each level re-deciding.
- `RestrictSize` prevents an overlay from covering its own anchor at _measure_ time, with a
  re-measure pass so content can rewrap before anything is clipped.
- Per-Monitor DPI handling is defensive and documented rather than incidental.
- `specs/tooltip.md` is a rare artefact: a shipped design document recording rejected alternatives,
  a usability-study outcome, and exact default-value changes with reasons.

## Weaknesses

- **No tracking whatsoever.** `Reposition()` fires only on property changes and content auto-resize;
  scrolling the anchor, moving the owner window or a layout shift leaves the popup stranded. This is
  architectural — the overlay is a separately positioned HWND and nothing observes layout.
- `CustomPopupPlacement.PrimaryAxis` appears to be inert: `UpdatePosition` writes `bestAxis`
  (`Popup.cs:2021`, `:2102`) and no read of it follows, while `GetPopupRootLimits` asks
  `GetPrimaryAxis(placement)` instead. This is a grep-level observation, not an observed behaviour.
- `PlacementMode.Relative` declares one combination but lists four arms — three unreachable.
- The spec's `Esc` dismissal is not implemented at this revision (see dimension 8).
- `BetweenShowDelay` is documented per element but its warmth is a single flag on the singleton, and
  setting it to 0 makes tooltip _replacement_ slower by cancelling both fast paths.
- No arrow geometry at any layer, and only two bits of placement metadata reach the styling layer, so
  a theme cannot react to the resolved side at all.
- The primitive type-tests its consumers in `GetScreenBounds` — a layering inversion a policy field
  would have avoided.
- Capture-based light dismiss is mouse-only and admittedly fragile; it covers neither touch nor
  keyboard and needs drag-drop-specific suppression hooks.
- No touch story: no long-press tooltip, no popover-to-sheet, no pointer-type branch; touch
  participates only as promoted mouse input.
- No viewport-inset concept (soft keyboard, safe areas, docked panels) — `GetScreenBounds` returns
  `rcWork` or `rcMonitor` and nothing can be injected.
- `ShowDuration`'s `Int32.MaxValue` default is honoured literally by arming a ~24.8-day timer rather
  than by not arming one, though the spec permits either.
- The controller is an ad-hoc imperative machine over six timers and eight fields with three
  documented re-entrancy hazards; there is no state type, so it cannot be tested in isolation.
- None of the timing or safe-area machinery is public: `PopupControlService` is internal, so an app
  that wants an interactive hover-card gets `Popup` and nothing else.

## Key design decisions and trade-offs

| Decision                                                                                                                                                    | Rationale                                                                                                                                                                                                                                                                         | Trade-off                                                                                                                                                                                                                                                                                                                              |
| ----------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Placement is candidate generation plus scoring, not a named side with fallbacks.                                                                            | One mechanism covers flip, alignment, RTL reordering, cursor anchoring and app-supplied placement. A new placement is a row in a table, not a branch in a function — and `Custom` is a natural extension because the same scorer picks among the app's candidates.                | Area-based scoring is a heuristic and the source says so (`Popup.cs:2085-2088`): it maximises visible overlay area, which can prefer a position showing empty chrome over one showing the important content. There is no per-candidate cost and no way to say "preferred but clipped is worse than non-preferred and whole".           |
| Every `Popup` is a real top-level OS window rather than an in-tree adorner.                                                                                 | Content escapes the app window's clipping and z-order for free, can overhang the window edge, can be per-pixel transparent, and gets a real UIA window node.                                                                                                                      | The ongoing cost is visible throughout the source: refusing activation on every `WM_MOUSEACTIVATE`, `SWP_NOCOPYBITS`, HWND destroy/recreate per open under Per-Monitor DPI, suppressed DPI relayout, a manual MSAA→UIA bridge, a sibling-HWND search for embedded web content, immutable `AllowsTransparency`, and no anchor tracking. |
| Outside-click dismissal is built on WPF's own logical capture plus an explicit hit test, never on a Win32 `SetCapture` grab.                                | Dismissal stays inside the routed-event world, so it composes with focus, drag-drop and nested popups; the code queries `GetCapture()` only to detect that another component holds a real grab and back off.                                                                      | Capture is fragile by the code's own admission: a descendant taking capture forces a re-establish dance, drag-drop needs explicit hooks, nested popups need a parent chain plus an ignore latch, and the scheme covers the mouse only.                                                                                                 |
| The hoverable requirement is met with the convex hull of anchor ∪ overlay, and the "toward the overlay versus a new owner" ambiguity with a 73 ms debounce. | The spec records that the alternatives were tried and rejected — the bounding rectangle was too large, and a rectangle around the shortest connecting line failed a usability study. The hull is equivalent to the stated requirement; the debounce avoids trajectory prediction. | The hull is built once at open and never updated, so scrolling leaves it dangling — explicitly accepted. Events inside the hull are delivered to underlying elements rather than swallowed, which can defeat the user's intent to reach the overlay. And it costs a real hull implementation inside a UI framework.                    |
| `BetweenShowDelay`: a cool-down window after close during which the next tooltip opens instantly.                                                           | Traversing a toolbar feels instant after the first wait, without making the first tooltip aggressive — the skip-delay idea, shipping since WPF 3.0 at a 100 ms default.                                                                                                           | The duration is read per owner but the warmth is one bool on the service, so per-owner tuning does not do what it appears to; and the 0 value cancels both fast paths on replacement.                                                                                                                                                  |
| A service-managed tooltip is structurally non-interactive: `Focusable=false`, `WS_EX_TRANSPARENT`, and `NotSupportedException` on `StaysOpen=false`.        | The spec records that tooltips must not be focusable or in the tab order; letting one take capture would also break the service's own hit testing.                                                                                                                                | There is then no primitive for an interactive hover-card. An app needing one drops to raw `Popup` and re-implements timing, safe area and dismissal, because none of the controller is public. Note the guarantee is a policy over arbitrary content, not a restriction on content type.                                               |
| The placement result feeds animation as data — the winning overlay corner reduced to two bits.                                                              | The animation layer reads what the scorer decided instead of re-deriving it; subtracting the animation offset before recomputing child points keeps a mid-animation reposition measuring settled geometry.                                                                        | Only two bits are exported. There is no arrow, no exposed side/align pair and no transform origin a style could react to, which is consistent with the absence of arrow geometry in the themes read here.                                                                                                                              |

## Implications for a canvas-first toolkit

Three things transfer nearly verbatim, and one large thing must be deliberately not copied. See
[`./sparkles-baseline.md`](./sparkles-baseline.md) for what the toolkit already has,
[`./proposal.md`](./proposal.md) for the primitive being designed, and
[`./comparison.md`](./comparison.md) for how this subject sits against the rest.

1. **The placement engine.** `resolve(anchorPts, overlaySize, viewportRect, candidates) -> (x, y, winningPair)`
   is a pure function over integer cells, needing no window, no hover and no script. Because it
   consumes a viewport _rect_, a soft-keyboard inset is an input rather than a discovery. Because
   `Custom` is just "the caller supplies the candidate array", the app-proposes/framework-disposes
   seam costs one parameter. Return the winning pair as data — WPF exports two bits and its animation
   code pays for it.
2. **The convex-hull safe area, only where hover exists.** Cheap, integral, allocation-free, and
   better in cells than in pixels. Pair it with the 73 ms debounce rather than trajectory prediction.
3. **The timing machine, as a value FSM over deadlines rather than timers** — which is what makes it
   assertable with synthetic time on a headless recording target, and what lets a script-free HTML
   target collapse every delay to zero honestly.

What not to copy is the window model. In a single-surface toolkit, paint order gives front-to-back for
free and clipping escape becomes a policy field; the three OS mechanisms that need explicit
replacements are `WS_EX_TRANSPARENT` (a "not in the hit list" bit), capture-based light dismiss
("consult the topmost open overlay first" in a reverse-paint-order hit walk), and `WM_ACTIVATEAPP` (a
surface-focus-lost event, with Android's Back key as its peer). Keep the ownership chain, though: a
parent index per overlay is what makes cascade flip inheritance and one-click-one-dismissal correct.

Related reading: [`../window-system-integration/index.md`](../window-system-integration/index.md) for
what an OS-window overlay actually costs per platform,
[`../platform-ui-guidelines/index.md`](../platform-ui-guidelines/index.md) for the appearance side, and
[`../../specs/ui/state-machines.md`](../../specs/ui/state-machines.md) for the toolkit's existing
value-FSM vocabulary. Nearby subjects: [`./winui.md`](./winui.md) and [`./uno.md`](./uno.md) for the
Windows lineage that followed, [`./avalonia.md`](./avalonia.md) for a port of this API onto a
cross-platform positioner, and [`./features-people-forget.md`](./features-people-forget.md) for the
obscure-capability catalog this page feeds.

## Sources

- [`Popup.cs`][popup] — the primitive: interest points, candidate scoring, nudge, `RestrictSize`,
  capture-based dismissal, HWND construction, `DropOpposite`, animation bits.
  ([`UpdatePosition`][popup-updateposition], [scoring note][popup-score],
  [`DropOpposite` comment][popup-dropopposite], [`GetNumberOfCombinations`][popup-combos],
  [`GetPointCombination`][popup-pointcombo], [mouse-rect latch][popup-mouselatch],
  [`GetScreenBounds`][popup-screenbounds], [`RestrictSize`][popup-restrictsize],
  [`MA_NOACTIVATE`][popup-noactivate], [`BuildWindow`][popup-buildwindow],
  [`CreateRootPopupInternal`][popup-createroot], [`PlacementInternal`][popup-placementinternal],
  [`CacheBits`][popup-cachebits], [`AnimationDelay`][popup-animdelay])
- [`PopupControlService.cs`][pcs] — the controller: triggers, timing, safe area, dismissal.
  ([`OnPostProcessInput`][pcs-postprocess], [capture re-hit-test][pcs-rehit],
  [`BeginShowToolTip`][pcs-beginshow], [the `BetweenShowDelay==0` override][pcs-zero],
  [debounce rationale][pcs-debounce], [`ShortDelay`][pcs-shortdelay],
  [`SetSafeArea`][pcs-setsafearea], [`ConvexHull` rationale][pcs-hullcomment],
  [`ContainsPoint`][pcs-contains], [`CoerceProperty`][pcs-coerce])
- [`PopupRoot.cs`][popuproot] — layout host: `MeasureOverride`, the restrict/re-measure loop,
  translate animations.
- [`ToolTip.cs`][tooltip-cs] / [`ToolTipService.cs`][tooltipservice] — non-focusability,
  `HitTestable = !StaysOpen`, and the three timing properties.
- [`ContextMenu.cs`][contextmenu] / [`MenuBase.cs`][menubase] / [`MenuItem.cs`][menuitem] — focus
  scope, menu mode, `MenuShowDelay` submenu timers.
- [`PlacementMode.cs`][placementmode] — the twelve modes.
- [`KeyboardNavigation.cs`][keyboardnav] — `Alt`/`F10` key-_up_ entry into menu mode (a release-edge
  overlay trigger outside the popup stack).
- [`InputManager.cs`][inputmanager] / [`HwndSource.cs`][hwndsource] — `PushMenuMode` and the
  exclusive message-preprocessing it installs.
- [`PopupRootAutomationPeer.cs`][popuprootpeer] — the overlay reported as
  `AutomationControlType.Window`.
- [`DoubleUtil.cs`][doubleutil] — `DoubleToInt`, the final rounding to whole device pixels.
- [`specs/tooltip.md`][spec] — the .NET 6 tooltip design spec: requirement sources, safe-region
  definition, rejected alternatives, and the summary of behaviour changes.
- [`Themes/XAML/ToolTip.xaml`][theme-tooltip] and [the Fluent `ToolTip` style][theme-fluent] — the
  shipped templates, and the absence of arrow geometry in them.

<!-- References -->

[repo]: https://github.com/dotnet/wpf
[learn-popup]: https://learn.microsoft.com/en-us/dotnet/api/system.windows.controls.primitives.popup
[popup]: https://github.com/dotnet/wpf/blob/99caccf23145777f910711b51961885bec783213/src/Microsoft.DotNet.Wpf/src/PresentationFramework/System/Windows/Controls/Primitives/Popup.cs
[popup-updateposition]: https://github.com/dotnet/wpf/blob/99caccf23145777f910711b51961885bec783213/src/Microsoft.DotNet.Wpf/src/PresentationFramework/System/Windows/Controls/Primitives/Popup.cs#L1993-L1999
[popup-score]: https://github.com/dotnet/wpf/blob/99caccf23145777f910711b51961885bec783213/src/Microsoft.DotNet.Wpf/src/PresentationFramework/System/Windows/Controls/Primitives/Popup.cs#L2083-L2090
[popup-dropopposite]: https://github.com/dotnet/wpf/blob/99caccf23145777f910711b51961885bec783213/src/Microsoft.DotNet.Wpf/src/PresentationFramework/System/Windows/Controls/Primitives/Popup.cs#L2115-L2121
[popup-combos]: https://github.com/dotnet/wpf/blob/99caccf23145777f910711b51961885bec783213/src/Microsoft.DotNet.Wpf/src/PresentationFramework/System/Windows/Controls/Primitives/Popup.cs#L2467
[popup-pointcombo]: https://github.com/dotnet/wpf/blob/99caccf23145777f910711b51961885bec783213/src/Microsoft.DotNet.Wpf/src/PresentationFramework/System/Windows/Controls/Primitives/Popup.cs#L2495-L2500
[popup-mouselatch]: https://github.com/dotnet/wpf/blob/99caccf23145777f910711b51961885bec783213/src/Microsoft.DotNet.Wpf/src/PresentationFramework/System/Windows/Controls/Primitives/Popup.cs#L2304-L2316
[popup-screenbounds]: https://github.com/dotnet/wpf/blob/99caccf23145777f910711b51961885bec783213/src/Microsoft.DotNet.Wpf/src/PresentationFramework/System/Windows/Controls/Primitives/Popup.cs#L2643-L2660
[popup-restrictsize]: https://github.com/dotnet/wpf/blob/99caccf23145777f910711b51961885bec783213/src/Microsoft.DotNet.Wpf/src/PresentationFramework/System/Windows/Controls/Primitives/Popup.cs#L2618-L2641
[popup-noactivate]: https://github.com/dotnet/wpf/blob/99caccf23145777f910711b51961885bec783213/src/Microsoft.DotNet.Wpf/src/PresentationFramework/System/Windows/Controls/Primitives/Popup.cs#L1747-L1751
[popup-buildwindow]: https://github.com/dotnet/wpf/blob/99caccf23145777f910711b51961885bec783213/src/Microsoft.DotNet.Wpf/src/PresentationFramework/System/Windows/Controls/Primitives/Popup.cs#L3287
[popup-createroot]: https://github.com/dotnet/wpf/blob/99caccf23145777f910711b51961885bec783213/src/Microsoft.DotNet.Wpf/src/PresentationFramework/System/Windows/Controls/Primitives/Popup.cs#L879
[popup-placementinternal]: https://github.com/dotnet/wpf/blob/99caccf23145777f910711b51961885bec783213/src/Microsoft.DotNet.Wpf/src/PresentationFramework/System/Windows/Controls/Primitives/Popup.cs#L456
[popup-cachebits]: https://github.com/dotnet/wpf/blob/99caccf23145777f910711b51961885bec783213/src/Microsoft.DotNet.Wpf/src/PresentationFramework/System/Windows/Controls/Primitives/Popup.cs#L2917
[popup-animdelay]: https://github.com/dotnet/wpf/blob/99caccf23145777f910711b51961885bec783213/src/Microsoft.DotNet.Wpf/src/PresentationFramework/System/Windows/Controls/Primitives/Popup.cs#L2899-L2902
[pcs]: https://github.com/dotnet/wpf/blob/99caccf23145777f910711b51961885bec783213/src/Microsoft.DotNet.Wpf/src/PresentationFramework/System/Windows/Controls/PopupControlService.cs
[pcs-postprocess]: https://github.com/dotnet/wpf/blob/99caccf23145777f910711b51961885bec783213/src/Microsoft.DotNet.Wpf/src/PresentationFramework/System/Windows/Controls/PopupControlService.cs#L34
[pcs-rehit]: https://github.com/dotnet/wpf/blob/99caccf23145777f910711b51961885bec783213/src/Microsoft.DotNet.Wpf/src/PresentationFramework/System/Windows/Controls/PopupControlService.cs#L59-L77
[pcs-beginshow]: https://github.com/dotnet/wpf/blob/99caccf23145777f910711b51961885bec783213/src/Microsoft.DotNet.Wpf/src/PresentationFramework/System/Windows/Controls/PopupControlService.cs#L298
[pcs-zero]: https://github.com/dotnet/wpf/blob/99caccf23145777f910711b51961885bec783213/src/Microsoft.DotNet.Wpf/src/PresentationFramework/System/Windows/Controls/PopupControlService.cs#L366-L375
[pcs-debounce]: https://github.com/dotnet/wpf/blob/99caccf23145777f910711b51961885bec783213/src/Microsoft.DotNet.Wpf/src/PresentationFramework/System/Windows/Controls/PopupControlService.cs#L344-L347
[pcs-shortdelay]: https://github.com/dotnet/wpf/blob/99caccf23145777f910711b51961885bec783213/src/Microsoft.DotNet.Wpf/src/PresentationFramework/System/Windows/Controls/PopupControlService.cs#L1730-L1732
[pcs-setsafearea]: https://github.com/dotnet/wpf/blob/99caccf23145777f910711b51961885bec783213/src/Microsoft.DotNet.Wpf/src/PresentationFramework/System/Windows/Controls/PopupControlService.cs#L834
[pcs-hullcomment]: https://github.com/dotnet/wpf/blob/99caccf23145777f910711b51961885bec783213/src/Microsoft.DotNet.Wpf/src/PresentationFramework/System/Windows/Controls/PopupControlService.cs#L1329-L1334
[pcs-contains]: https://github.com/dotnet/wpf/blob/99caccf23145777f910711b51961885bec783213/src/Microsoft.DotNet.Wpf/src/PresentationFramework/System/Windows/Controls/PopupControlService.cs#L1638
[pcs-coerce]: https://github.com/dotnet/wpf/blob/99caccf23145777f910711b51961885bec783213/src/Microsoft.DotNet.Wpf/src/PresentationFramework/System/Windows/Controls/PopupControlService.cs#L1263
[popuproot]: https://github.com/dotnet/wpf/blob/99caccf23145777f910711b51961885bec783213/src/Microsoft.DotNet.Wpf/src/PresentationFramework/System/Windows/Controls/Primitives/PopupRoot.cs#L137
[tooltip-cs]: https://github.com/dotnet/wpf/blob/99caccf23145777f910711b51961885bec783213/src/Microsoft.DotNet.Wpf/src/PresentationFramework/System/Windows/Controls/ToolTip.cs
[tooltipservice]: https://github.com/dotnet/wpf/blob/99caccf23145777f910711b51961885bec783213/src/Microsoft.DotNet.Wpf/src/PresentationFramework/System/Windows/Controls/ToolTipService.cs#L360
[contextmenu]: https://github.com/dotnet/wpf/blob/99caccf23145777f910711b51961885bec783213/src/Microsoft.DotNet.Wpf/src/PresentationFramework/System/Windows/Controls/ContextMenu.cs#L624-L638
[menubase]: https://github.com/dotnet/wpf/blob/99caccf23145777f910711b51961885bec783213/src/Microsoft.DotNet.Wpf/src/PresentationFramework/System/Windows/Controls/Primitives/MenuBase.cs
[menuitem]: https://github.com/dotnet/wpf/blob/99caccf23145777f910711b51961885bec783213/src/Microsoft.DotNet.Wpf/src/PresentationFramework/System/Windows/Controls/MenuItem.cs#L2565
[placementmode]: https://github.com/dotnet/wpf/blob/99caccf23145777f910711b51961885bec783213/src/Microsoft.DotNet.Wpf/src/PresentationFramework/System/Windows/Controls/Primitives/PlacementMode.cs
[keyboardnav]: https://github.com/dotnet/wpf/blob/99caccf23145777f910711b51961885bec783213/src/Microsoft.DotNet.Wpf/src/PresentationFramework/System/Windows/Input/KeyboardNavigation.cs#L3189-L3200
[inputmanager]: https://github.com/dotnet/wpf/blob/99caccf23145777f910711b51961885bec783213/src/Microsoft.DotNet.Wpf/src/PresentationCore/System/Windows/Input/InputManager.cs#L325
[hwndsource]: https://github.com/dotnet/wpf/blob/99caccf23145777f910711b51961885bec783213/src/Microsoft.DotNet.Wpf/src/PresentationCore/System/Windows/InterOp/HwndSource.cs#L731
[popuprootpeer]: https://github.com/dotnet/wpf/blob/99caccf23145777f910711b51961885bec783213/src/Microsoft.DotNet.Wpf/src/PresentationFramework/System/Windows/Automation/Peers/PopupRootAutomationPeer.cs#L24
[doubleutil]: https://github.com/dotnet/wpf/blob/99caccf23145777f910711b51961885bec783213/src/Microsoft.DotNet.Wpf/src/Shared/MS/Internal/DoubleUtil.cs#L261
[spec]: https://github.com/dotnet/wpf/blob/99caccf23145777f910711b51961885bec783213/src/Microsoft.DotNet.Wpf/specs/tooltip.md
[theme-tooltip]: https://github.com/dotnet/wpf/blob/99caccf23145777f910711b51961885bec783213/src/Microsoft.DotNet.Wpf/src/Themes/XAML/ToolTip.xaml#L49
[theme-fluent]: https://github.com/dotnet/wpf/blob/99caccf23145777f910711b51961885bec783213/src/Microsoft.DotNet.Wpf/src/Themes/PresentationFramework.Fluent/Styles/ToolTip.xaml#L34
