# Avalonia (C# / .NET)

Avalonia models anchored-overlay placement on the Wayland `xdg_positioner` protocol and implements that
model once, in managed code, so the same ~130-line solver positions a popup whether it is an OS child
window or a control inside an in-window `Canvas`.

| Field             | Value                                                                                                                                                                                                                    |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Language**      | C#                                                                                                                                                                                                                       |
| **License**       | MIT (`licence.md`, "Copyright (c) AvaloniaUI OÜ")                                                                                                                                                                        |
| **Repository**    | [`AvaloniaUI/Avalonia`][repo]                                                                                                                                                                                            |
| **Documentation** | In-source XML docs; the placement vocabulary carries the vendored `xdg_shell` prose ([`IPopupPositioner.cs`][ipp-head])                                                                                                  |
| **Category**      | Native desktop toolkit (.NET, cross-platform)                                                                                                                                                                            |
| **Surface model** | Both. The same `Popup` resolves at open time to an OS child window (`PopupRoot`) or to an in-window overlay control (`OverlayPopupHost`); `ManagedPopupPositioner` is the solver in both cases, only the adapter differs |
| **Revision read** | `aee3f68551b0ac4417e32996a6627f34462edbc3`                                                                                                                                                                               |
| **Read as**       | Implementation reading (source + test source). Not a docs-only subject                                                                                                                                                   |

> [!NOTE]
> The clone read was shallow (one commit), so nothing here rests on history, blame, or changelogs — every
> statement is about the tree at the pinned revision. Nothing was built or executed; behavioural claims are
> read from source and from test source.

## Overview

### What it solves

Avalonia needs one anchored-overlay story for Win32, macOS, X11, Android, iOS, the browser, the XAML
designer, and a unit-test mock — where the first three can hand a popup a real OS surface and the rest
cannot. Its answer is to refuse a second placement engine. `IPopupPositioner` is declared as an abstraction
of a compositor protocol, and `ManagedPopupPositioner` implements that protocol entirely in managed code
over a four-member platform adapter. In this tree, every backend routes through that managed
implementation: Android, iOS and the browser return `null` from `ITopLevelImpl.CreatePopup()`
([`TopLevelImpl.cs:217`][android-createpopup]), and Win32 and X11 return `null` too when the app opts into
`OverlayPopups` ([`WindowImpl.cs:655`][win32-createpopup], [`X11Window.cs:1355`][x11-createpopup]). What
other toolkits would call the managed fallback is the shipping path.

That makes Avalonia a useful reference for a one-surface toolkit: its in-window arm is not a degraded
mode kept alive for the designer, it is what mobile and web run.

### Design philosophy

The vocabulary is borrowed, and the borrowing is stated in the first three lines of the file that declares
it ([`IPopupPositioner.cs:1-3`][ipp-head]):

```csharp
// The documentation and flag names in this file are initially taken from
// xdg_shell wayland protocol this API is designed after
// therefore, I'm including the license from wayland-protocols repo
```

The `wayland-protocols` MIT licence text is vendored directly beneath it. `PopupAnchor`, `PopupGravity`
and `PopupPositionerConstraintAdjustment` are the protocol's anchor, [gravity][c-gravity] and
[constraint-adjustment][c-constraint] enums renamed. See [`./xdg-positioner.md`](./xdg-positioner.md) for
the protocol itself.

The second half of the philosophy is a deliberately tiny platform seam
([`ManagedPopupPositioner.cs:10-16`][mpp-iface]):

```csharp
public interface IManagedPopupPositionerPopup
{
    IReadOnlyList<ManagedPopupPositionerScreenInfo> Screens { get; }
    Rect ParentClientAreaScreenGeometry { get; }
    double Scaling { get; }
    void MoveAndResize(Point devicePoint, Size virtualSize);
}
```

Three reads and one write. Nothing about focus, input, z-order or lifetime. Because the seam is that
narrow, an in-window `Canvas` can impersonate a monitor: `OverlayPopupHost` reports one synthetic screen
equal to the overlay's arranged size deflated by the safe-area padding ([`OverlayPopupHost.cs:123-136`][oph-screens]),
`Scaling => 1` ([`:152`][oph-scaling]), and implements `MoveAndResize` as `Canvas.SetLeft`/`Canvas.SetTop`
([`:142-150`][oph-moveandresize]). The solver cannot tell the two apart.

The corresponding absences are as sharp as the presences, and several of them are traceable to one
decision: the solver returns nothing. There is no arrow or caret geometry, no [safe polygon][c-safe-polygon],
no `ActualPlacement`-style read-back, no scroll tracking, no IME avoidance, no Android back-key dismissal,
and no direct unit test of the placement algorithm.

## How it works

The pipeline is four stages, and the interesting property is where the boundary between "widgets" and
"arithmetic" falls.

```text
Popup.Open()
  └─ OverlayPopupHost.CreatePopupHost(target, resolver, shouldUseOverlayLayer)
        → PopupRoot (OS child window)   |   OverlayPopupHost (control in a Canvas)
  └─ IPopupHost.ConfigurePosition(PopupPositionRequest)     // request stored, latch set
        └─ (on arrange, once a size is known) PopupPositionerExtensions.Update
              ├─ BuildParameters(topLevel, request, popupSize, flowDirection)
              │     ├─ CalculateAnchorRect  : Visual → Rect            (element resolution ends here)
              │     ├─ PlacementMode switch : 14 cases → (anchor, gravity)
              │     ├─ CustomPopupPlacementCallback (Placement == Custom only)
              │     └─ RTL mirror on the anchor/gravity flag pair
              └─ ManagedPopupPositioner.Update(PopupPositionerParameters)
                    ├─ × Scaling  (DIPs → device pixels)
                    ├─ Calculate(...)  → Rect                          (pure arithmetic)
                    └─ _popup.MoveAndResize(rect.Position, rect.Size / Scaling)
```

Everything above `BuildParameters` knows about visuals, flow direction and placement modes. Everything
below it operates on a `record struct PopupPositionerParameters` ([`IPopupPositioner.cs:69`][ipp-record])
— six plain fields (size, [anchor rect][c-anchor-rect], anchor flags, gravity flags, constraint-adjustment
bitmask, offset point) with C# value equality, no element reference, no callback, no platform type.

`PopupPositionerExtensions.Update` guards on `popupSize == default` and returns
([`IPopupPositioner.cs:457-460`][ipp-ext]), which is why placement is deferred until a measured size
exists rather than run speculatively.

## The analysis spine

### 1. Anchor model

The anchor is always a `Rect` plus a `PopupAnchor` edge/corner selector — never an element. Element →
rect resolution happens once, in `CalculateAnchorRect` ([`IPopupPositioner.cs:568-586`][ipp-anchorrect]):
take `target.TransformToVisual(topLevel.PresentationSource.RootVisual)`; build
`bounds = new Rect(default, target.Bounds.Size)`; intersect the caller's optional `AnchorRect` with those
bounds; then `TransformToAABB` the result through the matrix. The intersect is a deliberate clamp — you
cannot anchor outside the target's own box — and rotation degrades to an axis-aligned bounding box. A
`null` matrix throws with two distinguished messages (not attached to the visual tree, versus not in the
same tree as the popup parent).

The cursor case is the degenerate one and is spelled as such: `PlacementMode.Pointer` sets
`AnchorRectangle = new Rect(position, new Size(1, 1))` with `Anchor = TopLeft`, `Gravity = BottomRight`
([`IPopupPositioner.cs:479-484`][ipp-pointer]). A point is a small rect, not a special case. There is no
[virtual anchor][c-virtual-anchor] object, no text-range or multi-rect anchor, and no per-frame anchor
tracking beyond the bounds test in dimension 3.

Trigger and anchor are separable. `Popup` is a zero-size marker in the tree — `MeasureCore` returns
`new Size()` ([`Popup.cs:629`][popup-measurecore]) and `IsHitTestVisible` defaults to `false`
([`Popup.cs:162`][popup-hittest]) — whose `PlacementTarget` may be any other control, falling back to
`this.FindLogicalAncestorOfType<Control>()` when unset ([`Popup.cs:431`][popup-target]). Many-triggers-one-surface
is how `ToolTip` works: one `ToolTip` instance per adorned control, its single `Popup` re-bound to a new
`PlacementTarget` on each open.

**Algorithm.**

```text
resolveAnchor(target, placementRect?, topLevel):
    m      := target.TransformToVisual(topLevel.RootVisual)   // null ⇒ throw
    bounds := Rect(0, 0, target.Bounds.Size)
    r      := (placementRect ?? bounds) ∩ bounds
    return r.TransformToAABB(m)

cursorAnchor(p) := Rect(p, Size(1,1)), anchor = TopLeft, gravity = BottomRight
```

**Where it lives.** Library code only, in `PopupPositionerExtensions`. The solver never sees a `Visual`.

**Degradation.** The anchor is already a comparable POD, so it survives a cell grid unchanged; the 1×1
cursor rect becomes a 1×1 cell rect. The one part that needs a substitute off this substrate is the
`Visual → Rect` step, which here is one matrix multiply plus an intersect. `PlacementMode.Pointer` has no
meaning without a pointer position (Android) and none without measurement (a script-free HTML emit), and
in both cases must fall back to element anchoring — Avalonia does not implement that fallback, it simply
never produces a pointer-anchored surface there.

### 2. Placement model

Two layers. The upper one is a 14-case `PlacementMode` enum lowered by a `switch` expression into exactly
one `(PopupAnchor, PopupGravity)` pair ([`IPopupPositioner.cs:514-536`][ipp-modes]) — `Bottom => (Bottom, Bottom)`,
`BottomEdgeAlignedLeft => (BottomLeft, BottomRight)`, `Center => (None, None)`, and `AnchorAndGravity`
passing the raw pair through. The lower one is anchor-point plus gravity-offset arithmetic. There is **no
preferred-placement list and no fallback ordering**: exactly one candidate is computed and then repaired
in place.

`PlacementMode.Custom` is the escape hatch and it is a mutation hook, not a candidate generator: a
`CustomPopupPlacement` value carrying the computed anchor rect, anchor, gravity, adjustment and offset is
handed to the callback, and every one of those five fields is copied back out afterwards
([`IPopupPositioner.cs:486-511`][ipp-custom]). It therefore runs _before_ the RTL mirror.

RTL is a post-pass on the flag pair, swapping `Left` ↔ `Right` on both anchor and gravity and leaving the
vertical flags untouched ([`IPopupPositioner.cs:539-563`][ipp-rtl]). The block contains no negation of
`Offset`; the structure therefore suggests `HorizontalOffset` keeps its physical direction under RTL,
though this reading is an inference from an absence and no test in the tree asserts either behaviour.

Illegal states are rejected rather than normalised: `ValidateEdge` throws `ArgumentException("Opposite
edges specified")` for a flag set containing both `Left|Right` or both `Top|Bottom`
([`IPopupPositioner.cs:258-266`][ipp-validate]), at property-set time.

Work-area handling comes from `ManagedPopupPositionerScreenInfo(Bounds, WorkingArea)` with one defensive
rule: a screen reporting a 0×0 working area falls back to its full bounds
([`ManagedPopupPositioner.cs:119-123`][mpp-workarea]). Viewport padding is not a solver concept at all —
the overlay adapter bakes it into the reported screen rect via
`rc.Deflate(topLevel.InsetsManager?.SafeAreaPadding)` ([`OverlayPopupHost.cs:131-134`][oph-screens]).

> [!WARNING]
> There is no soft-keyboard avoidance. Android's `SafeAreaPadding` composes `StatusBars`,
> `NavigationBars` and `DisplayCutout` and deliberately omits `Type.Ime()`
> ([`AndroidInsetsManager.cs:115-140`][android-safearea]); the keyboard rectangle exists only as
> `IInputPane.OccludedRect` ([`:143-160`][android-occluded]), and no code in the popup stack reads it. A
> flyout can be placed underneath the soft keyboard.

**Algorithm.**

```text
anchorPoint(rect, anchor):  x = Left ? rect.X : Right ? rect.Right : rect.X + W/2   (y likewise)
gravitate(p, size, grav):   x += Left ? -W    : Right ? 0          : -W/2           (y likewise)
unconstrained(a, g) = Rect(gravitate(anchorPoint(rect, a), size, g) + offset, size)

RTL post-pass: swap Left↔Right on anchor and on gravity; vertical untouched; offset untouched
```

**Where it lives.** `BuildParameters` owns the mode table, the custom callback and RTL; `GetAnchorPoint`
([`ManagedPopupPositioner.cs:46`][mpp-anchorpoint]) and `Gravitate` ([`:65`][mpp-gravitate]) own the
arithmetic; the platform contributes only the screen list.

**Degradation.** The only division is the `/2` for centred cases, which on a cell grid needs an explicit
floor/ceil convention that pixels let Avalonia leave implicit. Multi-monitor collapses to one entry.
The `Bounds`/`WorkingArea` pair maps onto "the surface" versus "the surface minus reserved rows". The
inset treatment is the transferable part: the solver is never taught about insets, the reported surface
rect is deflated before the call.

### 3. Collision & geometry engine

A single-pass, fixed-order, six-step repair over one candidate rect
([`ManagedPopupPositioner.cs:150-230`][mpp-calculate]). The order is hard-coded FlipX → SlideX → ResizeX →
FlipY → SlideY → ResizeY, and the axes are **not** two independent passes over a shared rect: X is fully
resolved before Y begins.

[Flip][c-flip] is conditional and reversible, and takes only the flipped coordinate, never the flipped
size ([`:153-160`][mpp-flipx]):

```csharp
if (!FitsInBounds(geo, PopupAnchor.HorizontalMask)
    && constraintAdjustment.HasAllFlags(PopupPositionerConstraintAdjustment.FlipX))
{
    var flipped = GetUnconstrained(anchor.FlipX(), gravity.FlipX());
    if (FitsInBounds(flipped, PopupAnchor.HorizontalMask))
        geo = geo.WithX(flipped.X);
}
```

That is the protocol's revert rule: if the flipped candidate is also constrained, the pre-flip result
stands.

[Slide][c-slide] is **unconditional** when its flag is set — there is no `if (!FitsInBounds)` guard — and
is a plain two-sided clamp: `X = max(X, bounds.X)`, then `if (Right > bounds.Right) X = bounds.Right - Width`
([`:163-168`][mpp-slidex]). The enum documentation vendored from the protocol in the same repository
describes a two-phase, gravity-directed slide; the implementation is a clamp. For a popup wider than the
bounds the second clamp wins and the surface hangs off the left edge regardless of gravity.

[Resize][c-resize] clamps the origin into the bounds and then shrinks the extent, and the whole adjustment
is discarded unless the result is strictly positive on both axes (`IsValid`, [`:144`][mpp-isvalid]).

> [!WARNING]
> The horizontal and vertical resize arms are not symmetric. `ResizeX` computes
> `unconstrainedRect.WithWidth(bounds.Width - unconstrainedRect.X)` ([`:182`][mpp-resizex]) where `ResizeY`
> correctly computes `bounds.Bottom - unconstrainedRect.Y` ([`:221`][mpp-resizey]). On any bounds whose
> `X != 0` — a second monitor at x=1920, a work area inset by a left dock — the horizontal arm yields a
> too-small or negative width, fails `IsValid`, and silently becomes a no-op.

The [clipping boundary][c-boundary] is discovered by a five-step total fallback chain plus a terminal
default ([`:109-127`][mpp-getbounds]):

```csharp
var targetScreen =  screens.FirstOrDefault(s => s.Bounds.ContainsExclusive(anchorRect.TopLeft))
                   ?? screens.FirstOrDefault(s => s.Bounds.Intersects(anchorRect))
                   ?? screens.FirstOrDefault(s => s.Bounds.ContainsExclusive(parentGeometry.TopLeft))
                   ?? screens.FirstOrDefault(s => s.Bounds.Intersects(parentGeometry))
                   ?? screens.FirstOrDefault();
```

with `?? new Rect(0, 0, double.MaxValue, double.MaxValue)` for the zero-screens case. It never returns
"no boundary". Clipping ancestors, scroll containers and layout shift are not modelled at all; the only
boundary is a screen (or overlay) rect.

Tracking is event-driven, never polled: window `PositionChanged`, `placementTarget.LayoutUpdated` gated by
a cached `LastPlacementTargetBounds` inequality test ([`Popup.cs:1024-1037`][popup-layoutupdated]), and
parent-popup `PositionChanged` for nested popups. There is no transform tracking for _position_:
`InheritsTransform` wires a `TransformTrackingHelper` whose callback calls `UpdateHostSizing` only
([`Popup.cs:1010-1014`][popup-transform]), so a translated or scrolled ancestor does not move the popup.

Scaling is applied by the caller rather than the solver: `Update` multiplies size, anchor rect and offset
by `Scaling` on the way in and divides the resulting size by it on the way out
([`ManagedPopupPositioner.cs:84-99`][mpp-update]), so `Calculate` runs in device pixels while the API
speaks DIPs.

**Algorithm.**

```text
calculate(size, anchorRect, anchor, gravity, adj, offset):
    anchorRect += parentClientAreaScreenGeometry.TopLeft        // client → screen
    bounds := pickScreen(anchorRect, parentGeometry).workArea    // 5-step fallback chain
    geo    := unconstrained(anchor, gravity)

    if !fits(geo, HorizontalMask) and adj.FlipX:
        f := unconstrained(anchor.flipX(), gravity.flipX())
        if fits(f, HorizontalMask): geo.X := f.X                 // X only; size unchanged

    if adj.SlideX:
        geo.X := max(geo.X, bounds.X)
        if geo.Right > bounds.Right: geo.X := bounds.Right - geo.W

    if adj.ResizeX:
        t := geo
        if t.X < bounds.X:            t.X := bounds.X
        if t.Right > bounds.Right:    t.W := bounds.Width - t.X   // asymmetric; see warning
        if t.W > 0 and t.H > 0:       geo := t

    … the same three steps on Y, with t.H := bounds.Bottom - t.Y

    return geo

fits(rc, edgeMask) tests only the edges named in the mask
```

**Where it lives.** Entirely in `ManagedPopupPositioner.Calculate`, a private method of about 130 lines.
The platform supplies the screen list and the parent client-area rect; nothing else.

**Degradation.** This is the part that generalises most completely. `Calculate` touches no window, no
compositor, no GPU and no DOM — it is `Rect` arithmetic over flag enums, and it is the code a cell-grid
toolkit can port nearly verbatim. Porting needs a rounding convention for the `/2` centring, removal of
the fractional scaling round-trip (`Scaling = 1`, which `OverlayPopupHost` already hardcodes), the
`bounds.Width` → `bounds.Right` fix, and an explicit decision on clamp-slide versus gravity-directed
slide. For a script-free HTML emit there is no repair stage at all, so the honest degradation is the
un-repaired `unconstrained(anchor, gravity)` rect with clipping accepted — which is exactly what
`ConstraintAdjustment.None` already means. The tracking half degrades hardest: with no timers and no
measurement there is nothing to re-run.

### 4. Arrow / caret geometry

Absent, and the absence is total. No `Arrow` property, no beak or tail path, no teaching-tip control in
this repository; the Fluent `ToolTip` template is a `Border` plus a `ContentPresenter` with a corner
radius and no pointer ([`ToolTip.xaml:39-50`][tooltip-xaml-template]).

The structural reason is that the solver returns nothing. `IPopupPositioner.Update` is `void`
([`IPopupPositioner.cs:445`][ipp-update]) and `MoveAndResize` is a sink ([`:96`][mpp-update]). The chosen
side, the flip decisions and the anchor-versus-surface centre delta are all discarded inside `Calculate`,
so there is no datum from which an arrow could be positioned even if one existed — and correspondingly no
`ActualPlacement`-style property anywhere. An arrow would additionally have to feed _back_ into the offset
(its size pushes the surface off the anchor edge), which a one-way pipeline cannot express.

**Algorithm.** Not applicable — no arrow geometry is computed anywhere in this tree.

**Where it lives.** Nowhere. The nearest knob is the caller-supplied `HorizontalOffset`/`VerticalOffset`
pair — `ToolTip` defaults `VerticalOffset` to 20 ([`ToolTip.cs:53`][tooltip-voffset]) — which is what you
would use to reserve room for an arrow by hand.

**Degradation.** The transferable content here is a warning rather than a design: a write-only placement
API forecloses arrows, [transform origins][c-transform-origin], side-aware styling and any assertion of
which side won. On a cell grid an arrow is one glyph in the border row or column, at
`clamp(anchorCentreCell, popupLeft + 1, popupRight - 1)`; that clamp _is_ the corner-constraint algorithm
at cell granularity, and hiding the glyph when the clamp cannot be satisfied is the whole detachment
rule. Both require the placement result to carry the side and the delta — see
[`./features-people-forget.md`](./features-people-forget.md) and
[`./sparkles-baseline.md`](./sparkles-baseline.md).

### 5. Trigger semantics

Triggers are deliberately not unified; each surface owns its own.

- **ToolTip** — pure hover, driven from raw input. `ToolTipService` holds a single global subscription to
  `InputManager.Process` and routes `RawPointerEventType.Move` into `Update(root, hitTestResult)`
  ([`ToolTipService.cs:36-75`][tts-process]). No focus trigger, no keyboard trigger.
- **Flyout** — `ShowAt(target)` / `ShowAt(target, showAtPointer)` programmatic, plus `ContextRequested`
  for context flyouts.
- **Context** — `Control.OnPointerReleased` with `InitialPressMouseButton == Right` raises
  `ContextRequestedEvent` ([`Control.cs:458`][control-released]) — on _release_, which lets a right-button
  drag suppress the menu. `Control.OnKeyUp` matched against
  `PlatformSettings.HotkeyConfiguration.OpenContextMenu` raises the same event with no pointer args
  ([`Control.cs:473`][control-keyup]). Touch long-press arrives through `Gestures.Holding`.
- **Menu** — `PointerEntered` on an already-open menu.

Pointer-type distinction survives as exactly one bit, and the coordinates do not
([`PopupFlyoutBase.cs:597-598`][pfb-triggered]):

```csharp
// We do not support absolute popup positioning yet, so we ignore "point" at this moment.
var triggeredByPointerInput = e.TryGetPosition(null, out _);
```

The boolean chooses pointer anchoring over element anchoring; the position is then re-derived inside the
positioner from `topLevel.LastPointerPosition`, under a source comment reading "We need a better way for
tracking the last pointer position" ([`IPopupPositioner.cs:479-481`][ipp-pointer]). Between the event and
the read, the pointer may have moved.

Race avoidance is by single ownership plus idempotence rather than arbitration. `ToolTipService` owns one
`_tipControl` field and `OnTipControlChanged` stops the timer first ([`ToolTipService.cs:147-151`][tts-closedprev]).
`PopupFlyoutBase.ShowAtCore` early-returns when re-shown on the same target and force-closes with an
uncancellable `HideCore(false)` before opening on a different one
([`PopupFlyoutBase.cs:266-286`][pfb-showatcore]). `Popup.Open` early-returns when `_openState != null`.
Every `IsOpen` write is wrapped in an `IgnoreIsOpenScope` re-entrancy latch so property-change callbacks
cannot recurse.

**Algorithm.**

```text
show(t):  if open and t == current:  return false
          if open:                   forceHide(cancellable: false)
          …open…

every IsOpen write runs inside `using (BeginIgnoringIsOpen())`, so the changed-handler sees the latch
pointer-vs-keyboard := (the request carries a pointer event)
```

**Where it lives.** Raw-input observation in `ToolTipService` and `PopupFlyoutBase`; routed-event synthesis
in `Control`; gesture recognition in `Gestures`; static class-handler wiring in
`PopupFlyoutBase.OnContextFlyoutPropertyChanged`.

**Degradation.** Two triggers here depend on key _release_: the keyboard context-menu trigger
([`Control.cs:473`][control-keyup]) and the flyout's toggle-close
([`PopupFlyoutBase.cs:456-469`][pfb-keyup]). A terminal target that does not report key release cannot
serve either as written; both have to move to the press edge, which turns "press the menu key again to
close" from a release-edge toggle into a down-edge toggle guarded by an open-state check. On a target
without hover the tooltip trigger has no analogue and Avalonia does not substitute one — the service
simply never fires. See [`../../specs/ui/input.md`](../../specs/ui/input.md) for the sparkles capability
vocabulary this maps onto.

### 6. Timing

One timed surface: the tooltip. `ShowDelay` defaults to 400 ms and `BetweenShowDelay` to 100 ms, both as
attached properties so they are per-control overridable ([`ToolTip.cs:63-70`][tooltip-delays]); menus carry
a separate static `MenuShowDelay` of 400 ms ([`DefaultMenuInteractionHandler.cs:53`][dmih-delay]).

The [warm-up][c-warmup] / skip-delay rule is precise ([`ToolTipService.cs:165`][tts-skip]):

```csharp
if (betweenShowDelay >= 0 && (closedPreviousTip || (DateTime.UtcNow.Ticks - _lastTipCloseTime) <= betweenShowDelay * TimeSpan.TicksPerMillisecond))
    showDelay = 0;
```

Note the two-term disjunction. `closedPreviousTip` is a local captured earlier in the same call
([`:151`][tts-closedprev]) with the comment "avoid race conditions by remembering whether we closed a
tooltip in the current call" — because the close path writes `_lastTipCloseTime` from an event handler
whose ordering relative to the open path is not guaranteed. A negative `BetweenShowDelay` disables the
fast path entirely.

There is exactly one `DispatcherTimer`, recreated per show and stopped at every transition
([`ToolTipService.cs:205`][tts-timer]) — a singleton timer, not one per control. Any pointer button down
clears the tip ([`:60-66`][tts-buttondown]). There is no close delay, no maximum display duration and no
auto-hide.

Menu timing is symmetric and simpler: `OpenWithDelay`/`CloseWithDelay` both use `MenuShowDelay` through an
injectable `Action<Action, TimeSpan> DelayRun` delegate ([`DefaultMenuInteractionHandler.cs:41-47`][dmih-delayrun]),
which is how the timing is made testable.

**Algorithm.**

```text
states: Idle | Delaying(target, deadline) | Open(target)

onHoverTarget(t):
    stopTimer
    if open(prev): close(prev); closedPreviousTip := true
    instant := betweenShowDelay >= 0 and (closedPreviousTip or now - lastCloseTime <= betweenShowDelay)
    if t == null:   Idle
    elif instant:   open(t)
    else:           Delaying(t, now + showDelay)

onTimer:            open(target)
onClose:            lastCloseTime := now
onPointerDown(any): stopTimer; close
```

**Where it lives.** `ToolTipService` (one per application, holding `_tipControl`, `_lastTipCloseTime`,
`_timer`, `_lastTipEventTime`, `_lastWindowEventTime`) and `DefaultMenuInteractionHandler` (per menu, with
`DelayRun` injected).

**Degradation.** Timers are the first casualty off this substrate. A script-free HTML target has none, so
the whole skip-delay machine collapses to "always instant" — the degenerate limit of the same algorithm. A
headless recording target has no wall clock either, which is precisely why the `DelayRun` injection point
is the reusable idea: thread `now` (or a tick source) in as a value rather than calling a clock, and the
delay behaviour becomes assertable. The shared `_lastTipCloseTime` scalar is worth noting for its size —
one timestamp for the whole application is all the [cool-down][c-cooldown] behaviour needs, with no group
or provider tree.

### 7. Interactive hover

No safe polygon, no trajectory heuristics, no menu-aim anywhere in this tree. Three cruder mechanisms
cover the same ground.

1. **Tooltip travel.** `ToolTipService.Update` hard-returns when the event root _is_ the tooltip's own
   popup root ([`ToolTipService.cs:81-84`][tts-rootcheck]), so moving onto the tooltip never re-evaluates
   the target. A _second_, different check covers the overlay case, where the tooltip lives in the same
   visual root as the trigger and the first test can never match
   ([`:89`][tts-overlaycheck], commented "when OverlayPopupHost is in use, the tooltip is in the same
   window as the host control"). `ToolTipPointerExited` closes only if the pointer left the tooltip _and_
   the tooltip's `AdornedControl != _tipControl` ([`:195-202`][tts-exited]), so travelling tooltip →
   trigger keeps it open. That path is covered by tests
   ([`ToolTipTests.cs:325`][tooltiptests-travel]).
2. **Submenu intent.** A flat 400 ms open delay plus a 400 ms close delay whose callback re-checks
   `item.IsPointerOverSubMenu` before actually closing
   ([`DefaultMenuInteractionHandler.cs:193-201`][dmih-submenu]). The whole diagonal-intent story is a time
   budget, not a geometric one.
3. **Flyout proximity.** `FlyoutShowMode.TransientWithDismissOnPointerMoveAway` inflates the surface's
   bounds by a hard-coded 100 px, caches that once, and closes when the pointer leaves the cached rect
   ([`PopupFlyoutBase.cs:342-396`][pfb-transient]). The source comment is candid: "I'm not sure what WinUI
   uses, but I'm defaulting to 100px, which seems about right". The cache is kept in two fields for the
   two coordinate spaces (`_enlargePopupRectScreenPixelRect` in screen pixels, `_enlargedPopupRect` in
   overlay DIPs), and the first move after opening only primes the cache and returns without testing.

**Algorithm.** Costs, translated to whole cells:

```text
tooltip travel-bridge : 0 cells   — an identity test on the hit result's root/ancestor chain
submenu intent        : 0 cells   — openWithDelay + closeWithDelay with an "still over my submenu" re-check
proximity dismiss     : one cached inflated rect + one point-in-rect test per move
```

**Where it lives.** `ToolTipService.Update`, `DefaultMenuInteractionHandler.PointerEntered/PointerExited`,
`PopupFlyoutBase.HandleTransientDismiss`. Nothing is delegated to the platform.

**Degradation.** Mechanism (1) is not geometric at all, so it ports directly onto a flat hit list as
"if the hit owner is the open overlay or its trigger, keep". Mechanisms (2) and (3) are a timer and a
rect. On a target without hover all three are dead code and the surfaces must be press/dismiss only —
Avalonia does not adapt, it never triggers. The dual coordinate-space caching in (3) is pure
two-surface tax and disappears on a single surface. The 100 px constant has to become a cell constant.

### 8. Dismissal

Dismissal is a `CompositeDisposable(7)` of event subscriptions assembled at open time and torn down as
one unit ([`Popup.cs:450`][popup-composite]). The set, all gated on `IsLightDismissEnabled` except where
noted:

- outside pointer _press_ (not release) on the shared `LightDismissOverlayLayer`
  ([`Popup.cs:866`][popup-dismissoverlay]);
- non-client press — title bar, resize border, system menu — via a global raw-input subscription filtering
  `RawPointerEventType.NonClientLeftButtonDown` ([`Popup.cs:856`][popup-nonclient]);
- `Window.Deactivated`, `IWindowImpl.LostFocus`, and `ITopLevelImpl.LostFocus` for non-`Window` top levels;
- parent-popup `Closed`, cascading nested popups shut;
- `placementTarget.DetachedFromVisualTree` → `Close()`, **unconditionally** — anchor removal always
  dismisses, regardless of light dismiss.

Escape is _not_ in this set. It is handled per content: `FlyoutPresenter.OnKeyDown` walks
`FindLogicalAncestorOfType<Popup>()` and sets `IsOpen = false` ([`FlyoutPresenter.cs:9-19`][fp-escape]),
and `ComboBox`, `SplitButton`, `Button` and the picker presenters each handle it themselves. Trigger
re-activation closes a context flyout on key _up_ ([`PopupFlyoutBase.cs:456-469`][pfb-keyup]).

Anchor-hidden and scroll are not handled: nothing observes visibility or scroll offset. Navigation and
resize do not dismiss, they reposition. Opening a child does not close the parent. The Android back key
does not dismiss: `TopLevel.BackRequestedEvent` exists ([`TopLevel.cs:106`][toplevel-back]) but the popup,
flyout and menu stack does not subscribe to it.

The inside/outside test is the piece worth copying ([`Popup.cs:940-962`][popup-ischildorthis]): it climbs
the **overlay ownership chain**, not the visual tree — start at `child.VisualRoot`, and while that root is
an `IHostedVisualTreeRoot`, hop to `hostedRoot.Host.VisualRoot`. A click in a submenu, or in a popup
opened from inside another popup, is not a visual descendant of the outer popup, so a naive
`IsVisualAncestorOf` test would dismiss the whole chain the moment the user reached a nested surface.
`FocusManager.GetFocusScope` performs the same hop, which keeps dismissal and focus scoping consistent.

**Algorithm.**

```text
dismissSources(popup) := disposableBundle {
    lightDismissLayer.PointerPressed  → if source not inside popup: [passThrough?] close
    rawInput NonClientLeftButtonDown  → close
    window.Deactivated | impl.LostFocus | topLevel.LostFocus → close
    parentPopup.Closed                → close   (cascade)
    target.DetachedFromVisualTree     → close   (unconditional)
}

inside(v) := climb v.VisualRoot, hopping IHostedVisualTreeRoot.Host.VisualRoot, until popup is found
```

**Where it lives.** `Popup.Open` builds the bundle; `LightDismissOverlayLayer` supplies the outside press;
`InputManager.Instance.Process` supplies the non-client press; Escape lives in each content presenter.

**Degradation.** On one surface with a flat hit list the overlay-chain climb becomes set membership over
overlay ids — no tree walk at all. Window deactivation, non-client presses and OS focus loss have no
analogue and must be replaced by whatever the target does report (terminal focus-out, window blur,
activity pause). Two gaps in this tree are instructive rather than copyable: the Android back key reaching
`SplitView` but not the overlay stack, and Escape duplicated across content controls instead of living in
the primitive. On a script-free HTML target, press-outside is not implementable at all, and an honest "no
dismissal" beats a fake one.

### 9. Focus

The four surfaces are kept genuinely distinct.

- **ToolTip** never takes focus: `_popup.TakesFocusFromNativeControl = false`
  ([`ToolTip.cs:412`][tooltip-takesfocus]).
- **Flyout** focus depends on `ShowMode`: `Standard` focuses `Popup.Child` if focusable, else
  `KeyboardNavigationHandler.GetNext(child, Next)` ([`PopupFlyoutBase.cs:313-327`][pfb-focus]);
  `Transient` and `TransientWithDismissOnPointerMoveAway` do not focus at all.
- **Menu / Popup**: `internal interface IPopupHost : IDisposable, IFocusScope`
  ([`IPopupHost.cs:18`][ipopuphost]) — every popup host, windowed or overlay, _is_ a
  [focus scope][c-focus-scope].

Containment, not a trap. `OverlayPopupHost`'s static constructor overrides the default of
`KeyboardNavigation.TabNavigationProperty` to `KeyboardNavigationMode.Cycle`
([`OverlayPopupHost.cs:31-32`][oph-tabnav]), so Tab cycles within an in-window popup. That per-host enum
is the entire stand-in for a native focus trap where there is no OS window.

Restoration is structural rather than explicit. `PopupRoot`'s `IHostedVisualTreeRoot.Host` returns the
parent visual when attached and otherwise `ParentTopLevel`, with the source comment that this "helps to
allow the focus manager to restore the focus to the outer scope when the popup is closed"
([`PopupRoot.cs:101-115`][popuproot-host]); `FocusManager.GetFocusScope` walks visual parents and then hops
through `IHostedVisualTreeRoot.Host`, so the overlay chain and the focus-scope chain are one chain.

**Algorithm.**

```text
scopeOf(e): walk visual parents; first IFocusScope with a visible VisualRoot wins;
            when visual parents are exhausted, continue through (e as IHostedVisualTreeRoot).Host

onOpen(mode): tooltip → nothing; transient → nothing;
              standard → focus(child.Focusable ? child : nextFocusable(child))
containment:  TabNavigation = Cycle on the overlay host
```

**Where it lives.** `FocusManager` owns scopes; `IPopupHost : IFocusScope` makes every host one;
`OverlayPopupHost`'s static constructor owns containment; `PopupFlyoutBase.ShowAtCore` owns initial focus
policy; `Popup` owns the native-control handoff via `TakesFocusFromNativeControl`.

**Degradation.** `KeyboardNavigationMode.Cycle` on the overlay host is the answer that survives without an
OS window — and Avalonia uses it on desktop too, because an overlay popup is not a window there either.
The `IHostedVisualTreeRoot` hop degrades to a parent-overlay index in a flat overlay list. Restoration has
to become explicit (remember the focused id at open, restore at close) where there is no `FocusManager`
to lean on; a closing-popup restore is pinned by a test here
([`PopupTests.cs:728`][popuptests-focus]). With no key release, Tab cycling must run on the press edge.
The tooltip-never-focuses rule is the one distinction that keeps a tooltip from becoming a popover and is
worth preserving verbatim.

### 10. Layering & portals

Two portal implementations behind one internal interface, chosen at open time
([`OverlayPopupHost.cs:154-171`][oph-create]):

```csharp
internal static IPopupHost CreatePopupHost(Visual target, IAvaloniaDependencyResolver? dependencyResolver, bool shouldUseOverlayLayer)
{
    if (!shouldUseOverlayLayer)
    {
        if (TopLevel.GetTopLevel(target) is { } topLevel && topLevel.PlatformImpl?.CreatePopup() is { } popupImpl)
            return new PopupRoot(topLevel, popupImpl, dependencyResolver);
    }
    if (PopupOverlayLayer.GetPopupOverlayLayer(target) is { } overlayLayer)
        return new OverlayPopupHost(overlayLayer);
    throw new InvalidOperationException(...);
}
```

The in-window [top layer][c-top-layer] is a fixed five-rung integer ladder inside one `Decorator`, each
rung created lazily ([`VisualLayerManager.cs:11-15`][vlm]):

```csharp
private const int AdornerZIndex = int.MaxValue - 100;
private const int OverlayZIndex = int.MaxValue - 98;
private const int LightDismissOverlayZIndex = int.MaxValue - 97;
private const int TextSelectorLayerZIndex = int.MaxValue - 96;
private const int PopupOverlayZIndex = int.MaxValue - 95;
```

Note the ordering: the light-dismiss scrim sits _below_ the popup rung, so it can never occlude the popup
it belongs to. Note also that `PopupOverlayLayer` is a separate `internal sealed Canvas`
([`PopupOverlayLayer.cs:6`][pol]) — popups do not share the general `OverlayLayer`. Both canvases override
`BypassFlowDirectionPolicies => true` so RTL does not mirror the layer itself, and both cache `finalSize`
into an `AvailableSize` property during `ArrangeOverride` with the comment that `Bounds` "won't be updated
in time" ([`OverlayLayer.cs:53-59`][ol-avail], [`PopupOverlayLayer.cs:33-39`][pol-avail]) — a
frame-ordering hazard solved by caching, and `OverlayPopupHost.Screens` reads the cached value rather than
`Bounds`.

Layer lookup is two-phase: the nearest `VisualLayerManager` among self-and-ancestors, else the first
`VisualLayerManager` descendant of the `TopLevel` ([`PopupOverlayLayer.cs:12-25`][pol-lookup]). That
nearest-scope-then-root shape is what lets a popup host nested overlays, since `PopupRoot`'s own template
contains a `VisualLayerManager`.

Ordering among sibling popups is plain child order: `Show()` is `_overlayLayer.Children.Add(this)` and
`Hide()` is `Children.Remove(this)` ([`OverlayPopupHost.cs:72-87`][oph-show]).

The public/implementation split is enforced with attributes: `IPopupHost` is `internal`,
`PopupOverlayLayer` is `internal sealed`, `ManagedPopupPositioner` and `IManagedPopupPositionerPopup` are
public but `[PrivateApi]`, and `IPopupPositioner` is `[NotClientImplementable]`
([`IPopupPositioner.cs:437`][ipp-notclient]).

**Algorithm.**

```text
choosePortal(target, forceOverlay):
    if !forceOverlay and platform.CreatePopup() is impl: return PopupRoot(topLevel, impl)
    if PopupOverlayLayer.Get(target) is layer:           return OverlayPopupHost(layer)
    throw

layerZ    = { Adorner: MAX-100, Overlay: MAX-98, LightDismiss: MAX-97, TextSelector: MAX-96, PopupOverlay: MAX-95 }
layerFind = nearest VisualLayerManager among self+ancestors, else first descendant of TopLevel
```

**Where it lives.** `VisualLayerManager`, a `Decorator` instantiated inside each top-level control
template. The rung constants are private consts in one file; discovery is a static method per layer type.

**Degradation.** This is the dimension a one-surface toolkit is forced into, and the overlay arm is a
complete shipping implementation of it: overlays as siblings in one canvas, ordered by insertion, over a
small ladder of named rungs. Two adaptations are needed where there is no `ZIndex`: the ladder becomes
ordered display-list sections emitted in that order, and the lazy `Enable*Layer` bools become "does this
frame contain any overlay of kind K", so an empty rung costs nothing. See
[`../../specs/ui/containers.md`](../../specs/ui/containers.md) and
[`../../specs/ui/backends.md`](../../specs/ui/backends.md).

### 11. Modality

There is no modal popup. The only [modality][c-modality] primitive is [light dismiss][c-light-dismiss], and
it is a hit-testable transparent `Border`: `internal class LightDismissOverlayLayer : Border, ICustomHitTest`
with the background overridden to `Brushes.Transparent` in its static constructor
([`LightDismissOverlayLayer.cs:15-24`][ldol]). It sits at `MAX-97` — above the general overlay rung, below
the popup rung — so it blocks pointer input to the application while never occluding the popup. No scrim
dimming (it is transparent, not semi-opaque), no keyboard blocking, no accessibility modal bit.

Pass-through comes in two orthogonal flavours and the distinction is subtle:

- `OverlayDismissEventPassThrough` (bool) is **temporal** — when a click dismisses the popup, also deliver
  that click to whatever was underneath. Implemented by re-hit-testing the root excluding the scrim,
  capturing the pointer to the hit, and re-raising the _same_ event args on it
  ([`Popup.cs:888-903`][popup-passthrough]); pinned by a test
  ([`PopupTests.cs:581`][popuptests-passthrough]).
- `OverlayInputPassThroughElement` (an element reference) is **spatial** — this subtree is never blocked
  at all. Implemented as a hole in the scrim via `ICustomHitTest`
  ([`LightDismissOverlayLayer.cs:49-60`][ldol-hittest]):

```csharp
public bool HitTest(Point point)
{
    if (InputPassThroughElement is Visual v)
        if (VisualRoot is IInputElement ie && ie.InputHitTest(point, x => x != this) is Visual hit)
            return !v.IsVisualAncestorOf(hit);
    return true;
}
```

A single shared `LightDismissOverlayLayer` instance per `VisualLayerManager` is toggled `IsVisible` by each
opening popup and untoggled by a disposable on close ([`Popup.cs:555-576`][popup-scrimtoggle]).

> [!WARNING]
> The visibility flag is a plain bool with no reference count. The structure therefore suggests that two
> simultaneously open light-dismiss popups in one window would leave the survivor without light dismiss
> when the first closes. This is an inference from the shared instance and the un-refcounted toggle; no
> test covering it was found in this tree and it was not reproduced.

**Algorithm.**

```text
scrim := a transparent, always-hit-testable rect covering the window, at a rung below the popup rung

hitTest(p):  if passThroughElement is set:
                 h := root.InputHitTest(p, x => x != scrim)
                 return !passThroughElement.IsVisualAncestorOf(h)     // hole in the scrim
             return true

onPress(p):  if source not inside popup:
                 if passThroughEvents:
                     h := root.InputHitTest(p, x => x != scrim); h.Capture(); h.RaiseEvent(sameArgs)
                 if still open: close()
```

**Where it lives.** `LightDismissOverlayLayer` and `Popup.PointerPressedDismissOverlay`/`PassThroughEvent`.
Nothing platform-side; the OS is never asked for a [grab][c-grab].

**Degradation.** A scrim is a full-surface entry in the hit list, painted before the popup, that consumes
presses — no new capability is required, and both pass-through flavours reduce to tests against a flat
reverse-order hit list rather than tree walks. That matters for a toolkit with no pointer grab: this tree
shows the in-surface scrim is what a desktop toolkit uses anyway. The un-refcounted toggle is the concrete
hazard to design out — derive the scrim from the open-overlay set rather than toggling a shared flag per
opener. Keyboard blocking is simply absent here and would have to be decided explicitly rather than
inherited.

### 12. Adaptive presentation

Exactly one adaptation exists, and it is about the _surface_, not the presentation. The decision is
layered, and the layering is the interesting part:

1. **Platform capability** — `ITopLevelImpl.CreatePopup()` returning `null` means "no popup surface here".
   Android, iOS and the browser hard-return `null` ([`TopLevelImpl.cs:217`][android-createpopup]).
2. **Platform policy** — `Win32PlatformOptions.OverlayPopups`, `X11PlatformOptions.OverlayPopups` and the
   macOS equivalent make `CreatePopup()` return `null` on desktop too
   ([`WindowImpl.cs:655`][win32-createpopup], [`X11Window.cs:1355`][x11-createpopup]).
3. **Per-popup override** — `Popup.ShouldUseOverlayLayer` ([`Popup.cs:142`][popup-shoulduse]), documented as
   the equivalent of the platform option settable independently per popup.

The outcome is observable: a read-only `IsUsingOverlayLayer` direct property is set to
`popupHost is OverlayPopupHost` at show time ([`Popup.cs:583`][popup-isusing]) and is asserted by tests
([`PopupTests.cs:1322-1349`][popuptests-overlay]). The decision is made once per open and never
re-evaluated.

There is no popover→sheet adaptation, no hover→long-press substitution, and no keyboard-driven relocation.
Touch does get one adaptation, but at the trigger layer: `Gestures.Holding` synthesises `ContextRequested`
with `IsHolding`, and the flyout responds by also calling `control.PerformFeedback(FeedbackAction.Hold)`
([`PopupFlyoutBase.cs:601-610`][pfb-feedback]).

**Algorithm.**

```text
surfaceKind := forceOverlay ? Overlay
             : platform.CreatePopup() is impl ? Window
             : Overlay
observable as IsUsingOverlayLayer (a DirectProperty raised at Show time)
```

**Where it lives.** Capability in each backend's `ITopLevelImpl.CreatePopup`; policy in the platform
options; per-instance on `Popup`; the join in the static `CreatePopupHost`.

**Degradation.** For a toolkit that is overlay-only on every target this whole axis is pre-decided, which
is why the overlay arm is the relevant reference and the window arm is not. What transfers is the
_layering_ lesson: the choice belongs to the host/application layer rather than the widget, and its
outcome must be observable so tests and styles can react. The adaptations this tree lacks — a hover
substitute where there is no hover, an interaction-tier decision for a script-free target — belong in the
same host layer, decided once from the backend's capability tier and passed in as data. See
[`../platform-ui-guidelines/index.md`](../platform-ui-guidelines/index.md) and
[`../window-system-integration/index.md`](../window-system-integration/index.md).

### 13. Accessibility

Thin, but correctly factored. `ToolTipAutomationPeer` reports `AutomationControlType.ToolTip` and the class
name "ToolTip", and does nothing else ([`ToolTipAutomationPeer.cs:10`][tooltip-peer]).
`PopupAutomationPeer` returns `IsContentElementCore() => false` and `IsControlElementCore() => false`
([`PopupAutomationPeer.cs:24-25`][popup-peer]) — the popup machinery is invisible in the accessibility tree
and only its content shows. The primitive contributes structure, not semantics; roles come from the
content control (`FlyoutPresenter`, `MenuFlyoutPresenter`, `ToolTip`).

Reparenting the popup root under the popup needs an explicit escape hatch, under a candid comment
([`PopupAutomationPeer.cs:31-38`][popup-peer-trysetparent]): the UIA API is called "an abomination", and
the note records that invalidating children does not make UIA re-read them.

There is no modal bit exposed (nothing is modal), no announcement on tooltip show, and no mapping from
`ToolTip.Tip` to an automation help-text property. WCAG 1.4.13 is satisfied only partly: hoverable holds
because the tooltip is a real control tree the pointer can enter (dimension 7), and dismissible holds for
pointer input because any button press clears the tip ([`ToolTipService.cs:60-66`][tts-buttondown]) — but
`ToolTip` has no Escape handler, so keyboard dismissal of a tooltip is missing. `Tip` is `object?`
([`ToolTip.cs:29`][tooltip-tip]), so tooltip content may be an arbitrary, hit-testable, hoverable control
tree; nothing forbids interactive content in a tooltip.

**Algorithm.**

```text
peer(popupHost).IsControlElement = false
peer(popupHost).IsContentElement = false     // structural, not semantic
peer(toolTip).ControlType        = ToolTip
onOpen/onClose: popupRootPeer.TrySetParent(popupPeer); InvalidateChildren()   // UIA workaround
```

**Where it lives.** `Avalonia.Automation.Peers` per control, feeding per-platform bridges (UIA on Win32,
AT-SPI on FreeDesktop, NSAccessibility on the native backend). `Popup` itself declares no role.

**Degradation.** The factoring is the transferable answer: the primitive says only "this content is an
overlay owned by that anchor, at that z-position", and the role belongs exclusively to the semantic
component wrapped inside it. What a terminal grid can honestly expose is narrow — reading order (emit
overlay content contiguously and after its anchor), and an explicit textual boundary such as a bordered,
titled box — and nothing resembling a role, a live region or a focus event, because there is no
accessibility API to carry them. The missing Escape-dismiss for a tooltip is a gap to fix rather than
copy.

### 14. Animation

One pseudo-class and one opacity transition, and no geometry metadata at all. `ToolTip` declares
`[PseudoClasses(":open")]` ([`ToolTip.cs:23`][tooltip-pseudo]) and toggles it in `OnPopupOpened`/`OnPopupClosed`
([`:472`][tooltip-pseudoupdate]); the Fluent theme pairs that with `Opacity 0`, a 150 ms `DoubleTransition`
on `Opacity`, and a `^:open` selector setting `Opacity 1`
([`ToolTip.xaml:31-34`][tooltip-xaml-opacity], [`:55-56`][tooltip-xaml-open]). That is the whole enter/exit
story: no scale, no slide, no reduced-motion check.

Because the solver returns nothing, there is no side data, no [transform origin][c-transform-origin] and no
way for a style to know the surface flipped. The one transform that _is_ plumbed is unrelated to
animation: `InheritsTransform` extracts a scale from the target's transform-to-top-level matrix and applies
it through a `LayoutTransformControl` in `PopupRoot`'s template
([`PopupRoot.xaml:15`][popuproot-xaml]) — and both `scaleX` and `scaleY` are computed from the same
expression `Math.Sqrt(m.M11 * m.M11 + m.M12 * m.M12)` ([`Popup.cs:734-735`][popup-scale]), so a
non-uniform target transform is not represented.

Repositioning during animation is not addressed. `OverlayPopupHost.MoveAndResize` defers to
`MediaContext.Instance.BeginInvokeOnRender` ([`OverlayPopupHost.cs:142-150`][oph-moveandresize]), so a
reposition lands as a render-phase side effect and jumps. An exit transition on an overlay popup appears
unable to complete, since `Hide()` removes the child from the canvas immediately
([`OverlayPopupHost.cs:84-87`][oph-show]) — an inference from the unconditional synchronous removal; no
deferral mechanism was traced.

**Algorithm.**

```text
styling state machine := PseudoClasses.Set(":open", isOpen) on Opened/Closed
only geometry-derived transform := scale = sqrt(M11² + M12²), applied uniformly (UpdateHostSizing)
```

**Where it lives.** `ToolTip.UpdatePseudoClasses` plus theme XAML. Nothing in `Popup`, `IPopupHost` or the
positioner participates.

**Degradation.** The finding here is negative and actionable: a placement function that returns a rect and
nothing else cannot feed an arrow, a transform origin, a side-aware style hook, or a recorded assertion of
which side won. On a cell grid there is no opacity and no sub-cell motion, so enter/exit degrades to
instant appear/disappear — but the metadata still matters, because it drives the arrow rather than the
animation. On a script-free HTML target a CSS transition on a `:hover`-revealed element is available and
needs the side as a static class emitted at build time: again metadata, not timers.

### 15. State architecture

Three architectures coexist, and the differences are instructive.

1. **The positioner is a stateless pure function over a value.** `Calculate` reads only its arguments plus
   `_popup.Screens` and `_popup.ParentClientAreaScreenGeometry`, and returns a `Rect`. No field mutates.
2. **Popup lifetime is an option-of-record plus a disposable bundle.** All open state lives in a single
   nullable `PopupOpenState` ([`Popup.cs:1062`][popup-openstate]) holding `PlacementTarget`, `TopLevel`,
   `PopupHost`, `LastPlacementTargetBounds` and a cleanup `IDisposable`; `_openState == null` _is_ the
   closed state; closing is dispose-and-null. Every subscription made at open time is `DisposeWith`-ed
   into the bundle, so teardown cannot forget one.
3. **Everything else is ad-hoc booleans plus a re-entrancy latch** — `_isOpen`, `_ignoreIsOpenChanged`,
   `_isOpenRequested`, `_needsUpdate`, `_lastPlacementTarget`, `_enlargedPopupRect`, `_lastTipCloseTime`.
   There is no reducer, no explicit FSM type and no state enum.

`IsOpen` is written back by the framework under the latch so it stays honest when opening is cancelled;
`PopupFlyoutBase` reverts the property when `ShowAtCore` returns false and re-asserts it when `HideCore` is
cancelled ([`PopupFlyoutBase.cs:471-502`][pfb-revert]). Deferred open is a one-bit resume:
`_isOpenRequested` is set when `Open()` finds no target or no `TopLevel`
([`Popup.cs:435`][popup-isopenreq]) and re-tried on attach.

The position latch is the reusable piece, and the identical three fields appear in both hosts
([`OverlayPopupHost.cs:95-121`][oph-latch]):

```csharp
void IPopupHost.ConfigurePosition(PopupPositionRequest positionRequest)
{
    _popupPositionRequest = positionRequest;
    _needsUpdate = true;
    UpdatePosition();
}

protected override Size ArrangeOverride(Size finalSize)
{
    if (_popupSize != finalSize) { _popupSize = finalSize; _needsUpdate = true; UpdatePosition(); }
    return base.ArrangeOverride(finalSize);
}

private void UpdatePosition()
{
    if (_needsUpdate && _popupPositionRequest is not null) { _needsUpdate = false; _positioner.Update(...); }
}
```

Either arrival order converges, and a repeated arrange at the same size does not re-place.

**Where it lives.** `Popup` (lifetime), `OverlayPopupHost`/`PopupRoot` (position latch), `PopupFlyoutBase`
(flyout and transient state), `ToolTipService` (hover and timing state). No shared state-machine type.

**Degradation.** Three things survive a value-semantics, allocation-averse port cleanly: the solver as a
pure function over a POD (which makes it table-testable and assertable on a recording target), the
three-field configure/arrange latch (exactly the reconciliation an immediate-mode loop needs between "the
application told me where to anchor" and "layout just told me my size"), and `_openState == null` as the
closed state, which maps onto a nullable or tagged union. What does not survive is the
`CompositeDisposable` bundle: it presumes GC-managed closures and push-style event subscription. The
value-semantics substitute is a per-frame predicate over the current event batch — "did a press land
outside the topmost overlay this frame?" replaces "is a handler attached to a scrim?" — which inverts
ownership from push to pull and removes the forgot-to-unsubscribe bug class. See
[`../../specs/ui/state-machines.md`](../../specs/ui/state-machines.md).

### 16. Shared infrastructure

The factoring is unusually explicit. **Truly shared, one implementation:** the placement engine and its
value type (every surface funnels into `PopupPositionerParameters`); `Popup` itself as the host-choosing,
dismissal-owning, lifetime-owning primitive; and the property _vocabulary_, shared by
`AvaloniaProperty.AddOwner<T>()` rather than by inheritance. `PopupFlyoutBase` re-declares `Placement`,
`HorizontalOffset`, `VerticalOffset`, `PlacementAnchor`, `PlacementGravity`, `CustomPopupPlacementCallback`,
`OverlayDismissEventPassThrough`, `OverlayInputPassThroughElement` and `PlacementConstraintAdjustment` as
owned aliases of `Popup`'s ([`PopupFlyoutBase.cs:19-63`][pfb-addowner]); `ContextMenu` does the same
([`ContextMenu.cs:39`][cm-addowner]). Type, default, metadata and documentation are shared at compile time
with no inheritance relationship.

**What deliberately stays apart:** `ToolTip` composes a private `Popup`; `PopupFlyoutBase` composes a
`Lazy<Popup>` ([`PopupFlyoutBase.cs:65`][pfb-lazy]); `ContextMenu` composes a `Popup`. Three independent
controllers over one primitive, composition at every seam. Timing is not shared (the tooltip's 400/100 ms
and the menu handler's static 400 ms are separate constants in separate files). Focus policy is not shared.
Dismissal is only partly shared — light dismiss lives in `Popup`, Escape is re-implemented in each content
control.

The vocabulary is copied onto the composed `Popup` by hand at open time in `PositionPopup`, and that hand
copy has a visible seam: `PlacementConstraintAdjustment` is assigned only in the non-pointer branch
([`PopupFlyoutBase.cs:544-552`][pfb-position]), so a context flyout shown at the pointer keeps whatever
adjustment the `Popup` last had.

**Algorithm.**

```text
sharing mechanism := property-ownership aliasing, not inheritance
    PopupFlyoutBase.PlacementProperty = Popup.PlacementProperty.AddOwner<PopupFlyoutBase>()
values copied onto the composed Popup imperatively, in one place (PositionPopup)
```

**Where it lives.** `Popup` plus `PopupPositioning` form the shared kernel; `ToolTip`/`ToolTipService`,
`PopupFlyoutBase`/`Flyout`/`MenuFlyout`, and `ContextMenu`/`DefaultMenuInteractionHandler` are three
independent controllers; `ComboBox`, `DatePicker`, `TimePicker`, `AutoCompleteBox`, `CalendarDatePicker`
and `SplitButton` are direct consumers, and two of them set `PlacementConstraintAdjustment = SlideY` by
hand — evidence that the constraint bitmask, rather than a placement preset, is the shared currency.

**Degradation.** The split is directly usable. Belongs in one primitive: the placement value type and
solver, the anchor→rect resolution, the overlay-layer insertion and ordering, the scrim and the
inside/outside test, the open-state option, and the reposition latch. Stays apart despite looking common:
timing (a tooltip's warm-up is not a submenu's open delay is not a combobox's zero delay), focus policy
(never-focus versus contain versus trap), trigger, and role. The `AddOwner` idea transfers in spirit as a
shared placement _struct_ embedded by value in each component's state — vocabulary shared as a type with
no inheritance relationship between tooltip, menu and combobox. The one thing worth doing differently is
hoisting Escape (and a back key where one exists) into the primitive, since the per-content duplication
here spans at least seven controls.

## Strengths

- The solver is a stateless pure function over a `record struct` of six POD fields — no element references,
  no callbacks, no platform types — which makes it portable to a value-semantics toolkit essentially as
  written.
- One solver, every backend in this tree: Win32, macOS, X11, Android, iOS, the browser, the designer and
  the unit-test mock all run the same code, so placement behaviour is uniform by construction rather than
  by discipline.
- The platform-adapter question is answered in four members, and the seam is narrow enough that an
  in-window `Canvas` can implement it — empirical evidence that a placement engine does not need an OS
  window.
- `OverlayPopupHost` is a complete, shipping implementation of "no OS top layer": overlays as siblings in
  one canvas, ordered by insertion, over a five-rung named ladder.
- Illegal placement states are rejected at the API boundary (`ValidateEdge` throws on `Left|Right`) rather
  than silently normalised, so the anchor/gravity pair can never be self-contradictory downstream.
- Boundary discovery is a total function with a degenerate-input fallback: it never returns "no boundary".
- The tooltip warm-up machine is precise and carries an explicit in-call race guard for the shared
  last-close timestamp, with real edge-case tests for travel onto and back off the tooltip.
- Modality without a pointer grab: a transparent scrim plus two distinct pass-through mechanisms — a
  temporal event replay and a spatial hole via `ICustomHitTest` — built entirely from hit testing.
- Hover is re-evaluated on renderer scene invalidation, not only on pointer movement, which is the right
  fix for a tooltip surviving the content it described.
- Open state as a single nullable record plus a disposable bundle makes teardown structurally hard to get
  wrong, and the configure/arrange latch converges from either arrival order with three fields.
- `AvaloniaProperty.AddOwner` gives three unrelated controllers a common placement vocabulary; `[PrivateApi]`,
  `[NotClientImplementable]` and `internal` keep hosts and positioners out of the public contract while
  still letting backends implement them.

## Weaknesses

- The horizontal resize arm computes `bounds.Width - X` where the vertical correctly computes
  `bounds.Bottom - Y` ([`ManagedPopupPositioner.cs:182`][mpp-resizex] versus [`:221`][mpp-resizey]). On any
  bounds with `X != 0` the result fails `IsValid` and `ResizeX` silently does nothing.
- `OverlayPopupHost.MoveAndResize` discards its `virtualSize` argument entirely, so the resize
  constraint — which is on by default ([`Popup.cs:60-65`][popup-adjdefault]) — has no effect on the overlay
  path: the surface is moved but never shrunk to fit.
- The placement algorithm has no direct unit tests. Searching the test tree for `FlipX`, `SlideX`, `ResizeX`
  or `ConstraintAdjustment` surfaces nothing in the popup path; placement is exercised only incidentally
  through `Popup` integration tests against a mock windowing platform whose screen is at the origin — which
  is exactly why the asymmetric resize survives.
- Slide is a plain two-sided clamp, contradicting the protocol prose vendored verbatim into the same
  repository's enum documentation, which describes a two-phase gravity-directed slide. The documentation
  and the source disagree, and the documentation is the copied standard.
- No placement result is returned anywhere, so arrows, transform origins, side-aware styling and any
  assertion of which side won are structurally impossible.
- No IME or soft-keyboard avoidance: `SafeAreaPadding` omits `Type.Ime()`, `OccludedRect` has no popup
  consumer, and a flyout can be placed under the keyboard.
- The Android back key does not dismiss popups, flyouts or menus; `TopLevel.BackRequestedEvent` exists but
  the overlay stack does not subscribe.
- No scroll or transform tracking of the anchor: repositioning is driven by a `Bounds` inequality and
  window `PositionChanged` only, and `InheritsTransform`'s transform-changed callback updates sizing rather
  than position.
- The context-flyout path discards the triggering event's coordinates and re-derives the anchor from
  `TopLevel.LastPointerPosition`, with two source comments admitting the shortcut.
- The shared `LightDismissOverlayLayer` is toggled by an un-refcounted `IsVisible` bool — see the inference
  in dimension 11.
- Escape is re-implemented in at least seven content controls instead of living in the overlay primitive.
- Both the keyboard context-menu trigger and the flyout's toggle-close are keyed on key _release_.
- `UpdateHostSizing` computes `scaleY` from the same expression as `scaleX`, so a non-uniform target
  transform is not represented.
- No arrow or caret, no reduced-motion handling, and no exit animation on the overlay path.

## Key design decisions and trade-offs

| Decision                                                                                                                                                             | Rationale                                                                                                                                                                                                                                                                                                                                                                             | Trade-off                                                                                                                                                                                                                                                                                                                                                                                                             |
| -------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Model the placement API on the Wayland `xdg_positioner` protocol rather than on a `PlacementMode` enum, and vendor the protocol's licence and prose into the source. | A protocol negotiated between processes that cannot share objects is already expressed as pure data: an anchor rect, two direction enums, a constraint bitmask, an offset, a size. Adopting it makes the request serialisable, comparable and delegatable, and lets the friendlier `PlacementMode` enum be a 14-case lowering into that vocabulary rather than the vocabulary itself. | Anchor and gravity as independent flag pairs are harder to learn than "place bottom-start", and illegal combinations need a runtime throw. It also imports the protocol's blind spots: no arrow, no result, no scroll container. And having vendored the prose, the implementation then diverges from it — slide is a clamp, not a gravity-directed two-phase slide — leaving documentation the code does not honour. |
| Make the platform adapter exactly four members and route every backend through the same managed solver.                                                              | With the seam that narrow an in-window canvas can impersonate a monitor, which is what makes `OverlayPopupHost` possible at all. Windowed and in-window popups are then positioned by identical code, so a placement bug is one bug and a fix is one fix across every backend, the designer and the test mock.                                                                        | The adapter cannot express what a real platform positioner could — an auto-hiding taskbar, an IME rect, per-monitor scaling — and, sharply, it cannot _refuse_ part of the result: `OverlayPopupHost` silently drops `virtualSize`, so the resize constraint is inert on every overlay platform and neither the type system nor the tests notice.                                                                     |
| Return nothing from placement: `IPopupPositioner.Update` is `void` and `MoveAndResize` is a sink.                                                                    | It matches the protocol, where the compositor moves the surface and the client is told asynchronously or not at all. It also keeps the solver trivially stateless and leaves the host in charge of how the rect is applied — a canvas offset, a window move-and-resize, or a deferred render-phase callback.                                                                          | This is the costliest decision in the design. The chosen side, the flip decisions and the clamp deltas are discarded inside `Calculate`, so an arrow, a placement-aware transform origin, a `side=` styling hook and an `ActualPlacement` read-back are all foreclosed — and the tree has none of them. One returned struct would have enabled all four.                                                              |
| Keep three separate controllers composing one `Popup`, sharing the property vocabulary by `AddOwner` rather than a common base class.                                | Tooltip, flyout and context menu differ in trigger, timing, focus and dismissal, and agree only on "anchor a surface to a rect and tear it down". Composition keeps the differences local while `AddOwner` shares type, default, metadata and documentation at compile time without an inheritance relationship the semantics could not support.                                      | The shared vocabulary must be copied onto the composed `Popup` by hand, which is a place to forget a field — and `PlacementConstraintAdjustment` is in fact assigned only in the non-pointer branch of `PositionPopup`. Escape handling, having no shared home, is re-implemented in at least seven content controls.                                                                                                 |
| Implement light dismiss as a transparent, hit-testable in-window layer below the popup rung, rather than requesting a pointer grab.                                  | It behaves identically for windowed and overlay popups, needs no platform capability, and makes "outside" a hit-test question rather than a grab question — which in turn makes both pass-through behaviours expressible as ordinary hit-testing code.                                                                                                                                | It cannot see outside the window, so three out-of-band subscriptions are needed to cover the rest: a raw-input filter for non-client presses, `Window.Deactivated`, and `ITopLevelImpl.LostFocus`. The single shared scrim is toggled by a plain bool with no reference count.                                                                                                                                        |
| Ship the solver with no unit tests of its own, testing placement only indirectly through `Popup` integration tests against a mock windowing platform.                | The mock wires the real `ManagedPopupPositioner` over a fake screen and a mocked popup implementation, so integration tests do exercise the engine end-to-end and assert concrete coordinates — coverage of the common path at the level users care about.                                                                                                                            | The uncommon paths are exactly the ones the constraint machinery exists for. The asymmetric `ResizeX` survives because no test places bounds with a non-zero `X` — no second monitor, no inset work area. Since the solver is pure, it is the cheapest thing in the toolkit to table-test exhaustively, and it is not tested at all.                                                                                  |

## Sources

Primary sources, all at revision `aee3f68551b0ac4417e32996a6627f34462edbc3`:

- [`src/Avalonia.Controls/Primitives/PopupPositioning/IPopupPositioner.cs`][ipp-head] — the vendored
  `xdg_shell` provenance, `PopupPositionerParameters`, edge validation, the `PlacementMode` lowering table,
  the custom-placement callback, the RTL mirror and `CalculateAnchorRect`.
- [`src/Avalonia.Controls/Primitives/PopupPositioning/ManagedPopupPositioner.cs`][mpp] — the four-member
  adapter interface, `GetAnchorPoint`/`Gravitate`, the scaling round-trip, boundary discovery and the
  six-step constraint repair.
- [`src/Avalonia.Controls/Primitives/Popup.cs`][popup] — host selection, the dismissal bundle,
  `IsChildOrThis`, pass-through, the open-state record and `UpdateHostSizing`.
- [`src/Avalonia.Controls/Primitives/OverlayPopupHost.cs`][oph] — the in-window adapter: synthetic screen,
  `Scaling => 1`, deferred `MoveAndResize`, the position latch and `CreatePopupHost`.
- [`src/Avalonia.Controls/Primitives/VisualLayerManager.cs`][vlm],
  [`PopupOverlayLayer.cs`][pol], [`OverlayLayer.cs`][ol-avail],
  [`LightDismissOverlayLayer.cs`][ldol] — the in-window layer stack and the scrim.
- [`src/Avalonia.Controls/ToolTip.cs`][tooltip] and [`ToolTipService.cs`][tts] — delays, the warm-up race
  guard, the two travel checks and the single timer.
- [`src/Avalonia.Controls/Flyouts/PopupFlyoutBase.cs`][pfb] and
  [`FlyoutPresenter.cs`][fp-escape] — show modes, transient dismissal, the property aliases and per-content
  Escape.
- [`src/Avalonia.Controls/Platform/DefaultMenuInteractionHandler.cs`][dmih] — menu delays and the injectable
  `DelayRun` seam.
- [`src/Avalonia.Controls/TopLevel.cs`][toplevel] — hover re-evaluation on scene invalidation, and
  `BackRequestedEvent`.
- [`src/Android/Avalonia.Android/Platform/AndroidInsetsManager.cs`][android-safearea] — safe-area
  composition and the unused `OccludedRect`.
- Tests: [`tests/Avalonia.Controls.UnitTests/ToolTipTests.cs`][tooltiptests-travel],
  [`tests/Avalonia.Controls.UnitTests/Primitives/PopupTests.cs`][popuptests-focus].

Related pages in this catalog: [`./index.md`](./index.md), [`./concepts.md`](./concepts.md),
[`./comparison.md`](./comparison.md), [`./features-people-forget.md`](./features-people-forget.md),
[`./sparkles-baseline.md`](./sparkles-baseline.md), [`./proposal.md`](./proposal.md); the protocol this
subject models itself on, [`./xdg-positioner.md`](./xdg-positioner.md); and the other subjects that solve
the same value in-process, [`./gtk4.md`](./gtk4.md), [`./wpf.md`](./wpf.md), [`./winui.md`](./winui.md),
[`./uno.md`](./uno.md), [`./compose.md`](./compose.md).

<!-- References -->

[c-anchor-rect]: ./concepts.md
[c-gravity]: ./concepts.md
[c-constraint]: ./concepts.md
[c-flip]: ./concepts.md
[c-slide]: ./concepts.md
[c-resize]: ./concepts.md
[c-boundary]: ./concepts.md
[c-top-layer]: ./concepts.md
[c-light-dismiss]: ./concepts.md
[c-grab]: ./concepts.md
[c-safe-polygon]: ./concepts.md
[c-warmup]: ./concepts.md
[c-cooldown]: ./concepts.md
[c-focus-scope]: ./concepts.md
[c-modality]: ./concepts.md
[c-virtual-anchor]: ./concepts.md
[c-transform-origin]: ./concepts.md
[repo]: https://github.com/AvaloniaUI/Avalonia
[ipp-head]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Primitives/PopupPositioning/IPopupPositioner.cs#L1-L3
[ipp-record]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Primitives/PopupPositioning/IPopupPositioner.cs#L69
[ipp-validate]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Primitives/PopupPositioning/IPopupPositioner.cs#L258-L266
[ipp-update]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Primitives/PopupPositioning/IPopupPositioner.cs#L445
[ipp-notclient]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Primitives/PopupPositioning/IPopupPositioner.cs#L437
[ipp-ext]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Primitives/PopupPositioning/IPopupPositioner.cs#L457-L463
[ipp-pointer]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Primitives/PopupPositioning/IPopupPositioner.cs#L479-L484
[ipp-custom]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Primitives/PopupPositioning/IPopupPositioner.cs#L486-L511
[ipp-modes]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Primitives/PopupPositioning/IPopupPositioner.cs#L514-L536
[ipp-rtl]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Primitives/PopupPositioning/IPopupPositioner.cs#L539-L563
[ipp-anchorrect]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Primitives/PopupPositioning/IPopupPositioner.cs#L568-L586
[mpp]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Primitives/PopupPositioning/ManagedPopupPositioner.cs
[mpp-iface]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Primitives/PopupPositioning/ManagedPopupPositioner.cs#L10-L16
[mpp-anchorpoint]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Primitives/PopupPositioning/ManagedPopupPositioner.cs#L46-L63
[mpp-gravitate]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Primitives/PopupPositioning/ManagedPopupPositioner.cs#L65-L82
[mpp-update]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Primitives/PopupPositioning/ManagedPopupPositioner.cs#L84-L99
[mpp-calculate]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Primitives/PopupPositioning/ManagedPopupPositioner.cs#L102-L231
[mpp-getbounds]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Primitives/PopupPositioning/ManagedPopupPositioner.cs#L109-L127
[mpp-workarea]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Primitives/PopupPositioning/ManagedPopupPositioner.cs#L119-L123
[mpp-isvalid]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Primitives/PopupPositioning/ManagedPopupPositioner.cs#L144
[mpp-flipx]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Primitives/PopupPositioning/ManagedPopupPositioner.cs#L153-L160
[mpp-slidex]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Primitives/PopupPositioning/ManagedPopupPositioner.cs#L163-L168
[mpp-resizex]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Primitives/PopupPositioning/ManagedPopupPositioner.cs#L182
[mpp-resizey]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Primitives/PopupPositioning/ManagedPopupPositioner.cs#L221
[popup]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Primitives/Popup.cs
[popup-adjdefault]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Primitives/Popup.cs#L60-L65
[popup-shoulduse]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Primitives/Popup.cs#L142
[popup-hittest]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Primitives/Popup.cs#L162
[popup-target]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Primitives/Popup.cs#L431
[popup-isopenreq]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Primitives/Popup.cs#L435
[popup-composite]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Primitives/Popup.cs#L450
[popup-scrimtoggle]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Primitives/Popup.cs#L555-L576
[popup-isusing]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Primitives/Popup.cs#L583
[popup-measurecore]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Primitives/Popup.cs#L629
[popup-scale]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Primitives/Popup.cs#L730-L735
[popup-nonclient]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Primitives/Popup.cs#L856-L864
[popup-dismissoverlay]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Primitives/Popup.cs#L866-L886
[popup-passthrough]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Primitives/Popup.cs#L888-L903
[popup-ischildorthis]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Primitives/Popup.cs#L940-L962
[popup-transform]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Primitives/Popup.cs#L1010-L1014
[popup-layoutupdated]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Primitives/Popup.cs#L1024-L1037
[popup-openstate]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Primitives/Popup.cs#L1062
[oph]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Primitives/OverlayPopupHost.cs
[oph-tabnav]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Primitives/OverlayPopupHost.cs#L31-L32
[oph-show]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Primitives/OverlayPopupHost.cs#L72-L87
[oph-latch]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Primitives/OverlayPopupHost.cs#L95-L121
[oph-screens]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Primitives/OverlayPopupHost.cs#L123-L136
[oph-moveandresize]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Primitives/OverlayPopupHost.cs#L142-L150
[oph-scaling]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Primitives/OverlayPopupHost.cs#L152
[oph-create]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Primitives/OverlayPopupHost.cs#L154-L171
[vlm]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Primitives/VisualLayerManager.cs#L11-L15
[pol]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Primitives/PopupOverlayLayer.cs#L6
[pol-lookup]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Primitives/PopupOverlayLayer.cs#L12-L25
[pol-avail]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Primitives/PopupOverlayLayer.cs#L33-L39
[ol-avail]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Primitives/OverlayLayer.cs#L53-L59
[ldol]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Primitives/LightDismissOverlayLayer.cs#L15-L24
[ldol-hittest]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Primitives/LightDismissOverlayLayer.cs#L49-L60
[popuproot-host]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Primitives/PopupRoot.cs#L101-L115
[ipopuphost]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Primitives/IPopupHost.cs#L18
[tooltip]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/ToolTip.cs
[tooltip-pseudo]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/ToolTip.cs#L23
[tooltip-tip]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/ToolTip.cs#L29
[tooltip-voffset]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/ToolTip.cs#L53
[tooltip-delays]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/ToolTip.cs#L63-L70
[tooltip-takesfocus]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/ToolTip.cs#L412
[tooltip-pseudoupdate]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/ToolTip.cs#L472
[tts]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/ToolTipService.cs
[tts-process]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/ToolTipService.cs#L36-L75
[tts-buttondown]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/ToolTipService.cs#L60-L66
[tts-rootcheck]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/ToolTipService.cs#L81-L84
[tts-overlaycheck]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/ToolTipService.cs#L89
[tts-closedprev]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/ToolTipService.cs#L147-L151
[tts-skip]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/ToolTipService.cs#L165
[tts-exited]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/ToolTipService.cs#L195-L202
[tts-timer]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/ToolTipService.cs#L205
[pfb]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Flyouts/PopupFlyoutBase.cs
[pfb-addowner]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Flyouts/PopupFlyoutBase.cs#L19-L63
[pfb-lazy]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Flyouts/PopupFlyoutBase.cs#L65
[pfb-showatcore]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Flyouts/PopupFlyoutBase.cs#L266-L286
[pfb-focus]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Flyouts/PopupFlyoutBase.cs#L313-L327
[pfb-transient]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Flyouts/PopupFlyoutBase.cs#L342-L396
[pfb-keyup]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Flyouts/PopupFlyoutBase.cs#L456-L469
[pfb-revert]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Flyouts/PopupFlyoutBase.cs#L471-L502
[pfb-position]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Flyouts/PopupFlyoutBase.cs#L544-L552
[pfb-triggered]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Flyouts/PopupFlyoutBase.cs#L597-L598
[pfb-feedback]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Flyouts/PopupFlyoutBase.cs#L601-L610
[fp-escape]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Flyouts/FlyoutPresenter.cs#L9-L19
[cm-addowner]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/ContextMenu.cs#L39
[control-released]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Control.cs#L458
[control-keyup]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Control.cs#L473
[dmih]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Platform/DefaultMenuInteractionHandler.cs
[dmih-delayrun]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Platform/DefaultMenuInteractionHandler.cs#L41-L47
[dmih-delay]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Platform/DefaultMenuInteractionHandler.cs#L53
[dmih-submenu]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Platform/DefaultMenuInteractionHandler.cs#L193-L201
[toplevel]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/TopLevel.cs
[toplevel-back]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/TopLevel.cs#L106
[popup-peer]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Automation/Peers/PopupAutomationPeer.cs#L24-L25
[popup-peer-trysetparent]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Automation/Peers/PopupAutomationPeer.cs#L31-L38
[tooltip-peer]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Automation/Peers/ToolTipAutomationPeer.cs#L10
[tooltip-xaml-opacity]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Themes.Fluent/Controls/ToolTip.xaml#L31-L34
[tooltip-xaml-template]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Themes.Fluent/Controls/ToolTip.xaml#L39-L50
[tooltip-xaml-open]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Themes.Fluent/Controls/ToolTip.xaml#L55-L56
[popuproot-xaml]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Themes.Fluent/Controls/PopupRoot.xaml#L15
[android-createpopup]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Android/Avalonia.Android/Platform/SkiaPlatform/TopLevelImpl.cs#L217
[android-safearea]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Android/Avalonia.Android/Platform/AndroidInsetsManager.cs#L115-L140
[android-occluded]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Android/Avalonia.Android/Platform/AndroidInsetsManager.cs#L143-L160
[win32-createpopup]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Windows/Avalonia.Win32/WindowImpl.cs#L655
[x11-createpopup]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.X11/X11Window.cs#L1355-L1356
[tooltiptests-travel]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/tests/Avalonia.Controls.UnitTests/ToolTipTests.cs#L325
[popuptests-passthrough]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/tests/Avalonia.Controls.UnitTests/Primitives/PopupTests.cs#L581
[popuptests-focus]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/tests/Avalonia.Controls.UnitTests/Primitives/PopupTests.cs#L728
[popuptests-overlay]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/tests/Avalonia.Controls.UnitTests/Primitives/PopupTests.cs#L1322-L1349
