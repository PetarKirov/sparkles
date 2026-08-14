# WinUI 3 — Flyout, TeachingTip, ToolTip and the popup root (C++/WinRT + XAML)

Two anchored-overlay stacks that share a portal and a dismissal layer but not a placement engine: a classic XAML core (`CPopup`/`CPopupRoot`/`FlyoutBase`/`ToolTipService`) whose geometry is pure rect arithmetic, and a modern control (`TeachingTip`) that forked its own 14-candidate solver because the shared one had no notion of an arrow.

| Field             | Value                                                                                                                                                         |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Language**      | C++ (C++/WinRT for `controls/dev/`, legacy dxaml COM core for `dxaml/xcp/`), XAML templates, C# interaction tests                                             |
| **License**       | MIT                                                                                                                                                           |
| **Repository**    | [`microsoft/microsoft-ui-xaml`][repo]                                                                                                                         |
| **Documentation** | In-repo only for this reading (`TeachingTip-FocusBehavior.md`, control specs under `specs/`); [learn.microsoft.com][learn] was **not** consulted              |
| **Category**      | Native desktop (Windows)                                                                                                                                      |
| **Surface model** | Both — an in-window overlay under `CPopupRoot` by default, or a real OS child window when `ShouldConstrainToRootBounds` is `false` and the platform allows it |
| **Revision read** | [`29ebf098f70df518b57b754130bc94004be8c6bc`][repo] (`winui3/main`; `eng/winui-version.props` `ProductMajorVersion=3`)                                         |

> [!NOTE]
> This is an implementation reading, not a docs reading. Nothing below was checked against
> `learn.microsoft.com`, so a documented-but-unimplemented behaviour would go unrecorded here
> rather than be reported as absent. Nothing was built or executed either — there is no Windows
> host in this environment — so every behavioural statement is a source reading at the pinned SHA.

## Overview

### What it solves

WinUI has to place four unrelated kinds of surface: a **flyout** (menus, pickers, the generic
`Flyout`), a **tooltip** (cursor-anchored, timed, never focusable), a **teaching tip** (a large
arrow-bearing coach mark that may also be corner-anchored with no target at all), and a
**combo-box dropdown** (which is a popup that deliberately is not flagged light-dismiss). All four
share one portal and one dismissal layer; only the first shares a placement engine.

The lower layer is present in this clone in full — `dxaml/xcp/` is not a stub tree.
`FlyoutBase_partial.cpp` is 4148 lines and `Popup.cpp` is 5641 lines of implementation, so the
[light dismiss][concepts] and [placement][concepts] semantics below are verified against source
rather than inferred from behaviour. The upper layer, `controls/dev/`, is where `TeachingTip`
lives, and it reimplements placement from scratch.

### Design philosophy

Placement is a pure geometric function of a handful of rects, evaluated at open and re-evaluated
only when something explicitly pokes it. There is no observer machinery in the decision path: no
scroll-container walk, no clipping-ancestor discovery, no transform stack. The one
`TransformToVisual` call collapses the anchor into a `winrt::Rect` at open time and the element is
never consulted by the geometry again.

The clearest statement of the stack's attitude to problems it cannot solve is `TeachingTip`'s
multi-monitor comment, at `controls/dev/TeachingTip/TeachingTip.cpp:1828-1831`:

```text
// Because we do not have access to APIs to give us details about multi monitor scenarios we do not have the ability to correctly
// Place the tip in scenarios where we have an out of root bounds tip. Since this is the case we have decided to do no special
// calculations and return the provided value or top if auto was set. This behavior can be removed via the
// SetReturnTopForOutOfWindowBounds test hook.
```

A shipping control's entire multi-monitor story is _return the requested side, or `Top`_ — a
respectable framework choosing an announced degradation over a guess. (The behaviour is gated on
`m_returnTopForOutOfWindowPlacement`, which a test hook can clear; the shipping default takes the
give-up branch.)

The second load-bearing philosophy is that dismissal belongs to the **popup root**, not to the
popup. `CPopupRoot::OnKeyDown` says why, at `dxaml/xcp/core/core/elements/Popup.cpp:5338-5340`:

```text
// The ESC key closes the topmost light-dismiss-enabled popup.
// Handling must be done by CPopupRoot because the popups reparent their children to be under CPopupRoot,
// so routed events from beneanth the popups route to CPopupRoot and skip the popups themselves.
```

The cost of that centralization is paid, in full and in public, by `TeachingTip`, at
`controls/dev/TeachingTip/TeachingTip.cpp:276-282`:

```text
// Playing a closing animation when the Teaching Tip is closed via light dismiss requires this work around.
// This is because there is no event that occurs when a popup is closing due to light dismiss so we have no way to intercept
// the close and play our animation first. To work around this we've created a second popup which has no content and sits
// underneath the teaching tip and is put into light dismiss mode instead of the primary popup. Then when this popup closes
// due to light dismiss we know we are supposed to close the primary popup as well. To ensure that this popup does not block
// interaction to the primary popup we need to make sure that the LightDismissIndicatorPopup is always opened first, so that
// it is Z ordered underneath the primary popup.
```

A whole second, content-free `Popup` exists because the close **reason** is not an output of the
dismissal machinery. That is the single most transferable lesson in this subject.

## How it works

Three engines, one substrate.

**`CPopup` / `CPopupRoot` (framework kernel).** An open `CPopup` reparents its `Child` under the
popup root. `m_pOpenPopups` is an insertion-ordered list iterated `NewestBegin` → `OldestBegin`;
there is no z-index anywhere. Light dismiss is implemented as bounds inflation plus a hit
predicate — `CPopupRoot::GenerateChildOuterBounds` unions the whole available rect into the popup
root's bounds when any open popup is light-dismissible, at
`dxaml/xcp/core/core/elements/Popup.cpp:4931-4936`:

```cpp
if (includeLightDismissCanvasBounds)
{
    XRECTF_RB lightDismissCanvasBounds = { 0, 0, m_availableSizeAtLastMeasure.width, m_availableSizeAtLastMeasure.height };
    UnionRectF(pBounds, &lightDismissCanvasBounds);
}
```

**`FlyoutBase` (shared library base).** A 13-value `FlyoutPlacementMode` is decomposed into
`MajorPlacementMode` × `PreferredJustification` by two free functions
(`FlyoutBase_partial.cpp:78`, `:115`), then a static, dependency-free trio —
`TestAgainstLimitsAndPlace` (`:364`), `TestAndCenterAlignWithinLimits` (`:308`), `TryPlacement`
(`:415`) — answers _fits / does not fit_ while always writing a usable position.
`PerformPlacementWithFallback` (`:488`) walks a 4-entry order and `ResizeToFit` (`:648`) shrinks
when nothing fits.

**`TeachingTip` (control library).** A 14-value flat `TeachingTipPlacementMode` (four sides, eight
side+corner, `Center`, `Auto`), a boolean availability array knocked out by roughly twenty named
predicates, a permuted 13-entry priority list, and a first-class arrow occupying a band of a 5×5
grid. It uses a raw `Popup`, not `FlyoutBase` (`TeachingTip.cpp:1014` `CreateNewPopup`).

`ToolTip` is a fourth path again: a `ContentControl` in its own `Popup` with its own
placement code, plus `ToolTipService` as a process-wide timing and hover arbiter.

## The analysis spine

### 1. Anchor model

Four anchor representations coexist, and all four are reduced to rects before geometry runs.

- **`TeachingTip`** takes `Target` (a `FrameworkElement`) and converts it **once**, at open, into
  `m_currentTargetBoundsInCoreWindowSpace` (`TeachingTip.h:207`) via
  `target.TransformToVisual(nullptr).TransformBounds(...)` (`TeachingTip.cpp:865`). Everything
  downstream — availability predicates, offsets, arrow centring — reads only that rect; the element
  reference survives only to re-derive it and to hook `Unloaded`.
- **`FlyoutBase`** caches `m_placementTargetBounds` in `ValidateAndSetParameters`
  (`FlyoutBase_partial.cpp:1672`) _before_ opening, explicitly "in case if it goes away (as would
  be the case in flyout invoked by element from another flyout)" — the detached-trigger case,
  named. `CalculatePlacementTargetBoundsPrivate` (`:2662`) additionally expands the bounds to the
  whole `AppBar` when the target is an app-bar child, and force-overrides the side (top app bar ⇒
  `Bottom`, bottom ⇒ `Top`).
- **Point anchors** arrive through `ShowAtWithOptions(target, FlyoutShowOptions)`
  (`FlyoutBase_partial.cpp:1007`): `Position` is transformed to root space, clamped into the
  content or monitor rect, and stored as `m_targetPoint`. `ExclusionRect` (`:1067`) is a _second_
  rect the popup must not overlap — the mechanism by which a cursor-anchored `MenuFlyout` still
  avoids covering the row it was invoked from. This is WinUI's [virtual anchor][concepts]: a point
  plus an avoid-rect, with no element behind it.
- **`ToolTip`** picks its anchor by priority — last pointer point, else `PlacementRect`, else the
  owner's rect (`ToolTip_Partial.cpp:1156` `PerformPlacementWithPopup`).

**Algorithm.** `resolveAnchor()`: if a `Position` was supplied, `p = clamp(toRoot(position), contentRect)` and
`anchor = Rect(p, 0, 0)`; else if the target is in the live tree, `anchor = toRoot(Rect(0, 0, ActualWidth, ActualHeight))`;
else use the rect cached at `ShowAt` time. If the target's parent is a top/bottom `AppBar`, replace the anchor with the
app bar's own band and override the side. `exclusion = toRoot(showOptions.ExclusionRect)` or empty.

**Where the behavior lives.** Entirely library code. The only platform call is `TransformToVisual`;
multiple triggers competing for one surface are arbitrated by a metadata singleton
(`GetFlyoutMetadata`, `:3661`), not by per-anchor state.

**Degradation.** This dimension survives everything. The anchor is already a value by the time any
placement code runs, so it needs no OS window, no hover, no script and no sub-cell precision; in a
cell grid the transform is identity-plus-offset and the rect is integral by construction. The one
casualty is the `AppBar` expansion, which is chrome policy rather than geometry. The four
representations appear to collapse to a single comparable value — `(Rect anchor, Rect exclusion,
Point? at)` — since nothing in the math touches the element again.

### 2. Placement model

Two unrelated engines, and they differ in kind, not only in detail.

`FlyoutBase` fallback is a hardcoded four-entry table per major side, built in
`CalculatePlacementPrivate` at `FlyoutBase_partial.cpp:2559` (`Top` ⇒ `[Top, Bottom, Left, Right]`,
`Left` ⇒ `[Left, Right, Top, Bottom]`, and so on). Fallback is attempted only when
`m_allowPlacementFallbacks` is set, and `PerformPlacement` skips the virtual auto-adjust hook
entirely when the application set `Placement` locally (`:1814`):

```cpp
if (!isPlacementPropertyLocal)
{
    IFC(AutoAdjustPlacement(&effectivePlacementMode));
}
```

`TeachingTip` instead computes an availability array over all 14 candidates and returns the first
survivor of a permuted priority order (`GetPlacementFallbackOrder`, `TeachingTip.cpp:2178`).

[Gravity][concepts] is spelled `PreferredJustification` (`Center`/`Left`/`Right`/`Top`/`Bottom`) on
`FlyoutBase` and is baked into the enum on `TeachingTip` (`Top` vs `TopLeft` vs `TopRight`). RTL is
pure enum mapping applied _before_ geometry (`GetFlowDirectionAdjustedPlacement`,
`TeachingTip.cpp:1470`) and un-applied afterwards for the entrance transition, "because transitions
already respect flow direction".

The viewport is assembled by `FlyoutBase::CalculateAvailableWindowRect` (`:2800`): visible content
bounds, minus an open top app bar, minus a bottom app bar, minus the intersection with
`GetInputPaneOccludeRect` (`:2891`) — the soft-keyboard inset is a first-class **input** to
placement, and `NotifyInputPaneStateChange` re-runs placement when it changes. Multi-monitor exists
only on the windowed path (`CalculateAvailableMonitorRect`).

There is no [shift][concepts] separate from [flip][concepts]: sliding is folded into the clamp
inside the two test helpers, and the 4px gap (`FlyoutBase::FlyoutMargin`, `:65`) is added
_after_ clamping, in the chosen direction only (`:2627`).

**Algorithm.** `FlyoutBase`: `order = fallbackTable[major]`; try `order[0]` and keep its position regardless of the
outcome; if it does not fit, walk `order[1..3]`; if none fit, revert to `order[0]`'s position and, when
`allowPresenterResizing`, `ResizeToFit`. Then add `±FlyoutMargin` along the effective side.
`TeachingTip`: `avail[14] = true` except `Auto`; apply the knockouts of dimension 3; walk
`GetPlacementFallbackOrder(rtlAdjust(preferred))` and return the first available mode; if none survive, return
`(Top, tipDoesNotFit = true)` and **do not open**.

**Where the behavior lives.** Library code. `FlyoutBase`'s helpers are `static` free functions over
`wf::Rect`/`wf::Size` with no framework dependency at all; `TeachingTip`'s member functions read
only cached rects. Only viewport assembly reaches into the platform.

**Degradation.** Every operation is compare, add and clamp on rects, so the whole dimension ports to
integer cells unchanged; what must be _supplied_ on a single surface rather than discovered is the
viewport rect and its insets. WinUI already treats the keyboard occlude rect that way, which is the
shape a soft-keyboard target needs (an inference about porting — WinUI does not target Android).
Multi-monitor and work areas simply do not exist on one surface, and `TeachingTip` demonstrates that
a shipping control can decline them.

> [!WARNING]
> `MenuFlyout::AutoAdjustPlacement` (`dxaml/xcp/dxaml/lib/MenuFlyout_Partial.cpp:348`) is the only
> override of that hook, and it reads as a no-op: it fetches `windowRect` via
> `GetContentBoundsForElement` and returns `S_OK` without writing `*pPlacement`. This reading was
> not confirmed against a build, and no search was made for a codegen wrapper that might mutate the
> value.

### 3. Collision & geometry engine

No observers participate in the decision anywhere in this subject, and that is the most
transferable structural fact about it.

`TeachingTip::DetermineSpaceAroundTarget` (`TeachingTip.cpp:2098`) returns two `Thickness` values:
the gap from the target's edges to the _window_ edges, and the same against the _screen_. When
`ShouldConstrainToRootBounds()` is true — the default, and the single-surface case — the second is
literally the first. `DetermineEffectivePlacementTargeted` (`:1869`) then knocks candidates out in
four classes:

1. **the target's edge is off-window** — `clippedTargetBounds.Left < 0` kills `Left`, `LeftTop`,
   `LeftBottom` (`:1932`);
2. **the target's midpoint is off-window** — `clippedTargetBounds.Left < -targetWidth / 2` kills all
   of `Top*`, `Bottom*` and `Center`, because those centre the arrow on the target's midpoint
   (`:1960`);
3. **the tip does not fit beside the target** — `tipHeight > availableBoundsAroundTarget.Top`
   (`:1987`);
4. **the tip does not fit measured from the target's centre**, using the arrow inset:
   `contentHeight - MinimumTipEdgeToTailCenter() > space.Top + target.Height / 2` kills `RightTop`
   and `LeftTop` (`:1999`).

`HeroContent` adds two further knockout groups so a tall hero image never sits behind the arrow.

`FlyoutBase` has one predicate instead (`TryPlacement`) plus `ResizeToFit` (`:648`) — a genuine
third strategy beyond flip and shift: pick the side with more space
(`SelectSideWithMoreSpace`, `:581`), shrink the presenter but never below `MinWidth`/`MinHeight`,
clamp to the container, reposition adjacent to the anchor, clamp again.

Tracking is deliberately thin. `TeachingTip` re-places on `XamlRoot.Changed` (only when
`xamlRoot.Size()` actually changed), on content `SizeChanged`, on `Target.Loaded`, and on
`EffectiveViewportChanged` — but the last is subscribed only from
`SetViewportChangedEvent` (`:1553`), which is reached only when `m_tipFollowsTarget` is true.
That member defaults to `false` (`TeachingTip.h:227`) and the only setter is
`TeachingTipTestHooks.SetTipFollowsTarget` (`TeachingTipTestHooks.idl:18`). **A shipping teaching
tip does not follow a scrolling target.** `RepositionPopup` (`:1583`) further guards with a
rect-equality check. `FlyoutBase` re-places on presenter `SizeChanged`, guarded by
`m_presenterResized` (`:2196`) against the feedback loop its own resize would otherwise create.

**Algorithm.** `space = { L: target.X - win.X, T: target.Y - win.Y, R: win.right - target.right, B: win.bottom - target.bottom }`.
Knockouts as above, then first-available over the permuted priority order.
`ResizeToFit(side)`: `avail = space[side]`; if the control exceeds it, consider the opposite side and switch only if it
can hold the minimum; shrink to `avail` but never below the minimum; clamp to the container; place adjacent; clamp again.

**Where the behavior lives.** Pure library code over cached rects. No compositor, no layout system
and no transform stack participates in the decision — `TransformBounds` is a pre-step.

**Degradation.** Rects in, enum and point out; nothing here needs sub-cell precision, an OS window,
hover or script. On one surface the window rect _is_ the screen rect, collapsing the two `Thickness`
values into one — which is exactly the `ShouldConstrainToRootBounds == true` branch WinUI already
ships. With no observers there is nothing to lose by recomputing in the frame after a size or anchor
change, which a recording canvas can drive deterministically.

### 4. Arrow / caret geometry

`TeachingTip`'s arrow (WinUI calls it the **tail**) is the strongest arrow model in this subject —
and it is _not_ data. It is a template element positioned by the layout system, which is precisely
why the C++ has to reverse-engineer it back into numbers.

The template (`controls/dev/TeachingTip/TeachingTip.xaml:283-296`) declares a 5×5 grid whose outer
band is `TeachingTipTailShortSideLength` (8) and whose second band is `TeachingTipTailMargin` (10),
both from `TeachingTip_themeresources.xaml:93-94`; `TailOcclusionGrid` (`:297`) spans all 5×5 and
`ContentRootGrid` occupies rows and columns 1–3, leaving the outer 8-unit band for the arrow.
`TailPolygon` is a three-point polygon whose `Points`, `Grid.Row`/`Grid.Column`, alignment and
margin are switched by thirteen visual states — for `Top`, `Points="0,0 10,10, 20,0"`, row 4,
column 2, centred, with a `0,-1,0,0` margin so the arrow's border merges with the body's
(`TeachingTip.xaml:118-124`).

The C++ then recovers the scalars it needs _from layout_:

```cpp
// TeachingTip.cpp:2313, :2333
double TeachingTip::TailShortSideLength()       // min(polygon.ActualHeight, ActualWidth) - s_tailOcclusionAmount
double TeachingTip::MinimumTipEdgeToTailCenter() // col[0].ActualWidth + col[1].ActualWidth + max(polygonH, polygonW) / 2
```

At default metrics `MinimumTipEdgeToTailCenter()` is `8 + 10 + 10 = 28`, and that value does double
duty: it is a term in the **fit test** (dimension 3) _and_ in the final offset — for `TopRight`,
`HorizontalOffset = targetCenterX - MinimumTipEdgeToTailCenter()` (`TeachingTip.cpp:519`
`PositionTargetedPopup`), so the popup is positioned to put the _arrow_ on the target's centre while
the body hangs off to one side. The corner constraint is therefore structural: the corner-aligned
modes exist because clamping an arrow near a rounded corner is ugly.

`UpdateTail` (`:349`) also sets a `CenterPoint` per placement mode on the occlusion grid — the
[transform origin][concepts] — and `TeachingTipTemplateSettings.TopLeftHighlightMargin` /
`TopRightHighlightMargin` (`TeachingTip.h:261`, `:266`) are `Thickness` values computed in C++ and
handed to the template so the 1px top highlight splits around the arrow. That is border-aware arrow
geometry shipped as data.

Hiding is a mode, not a flag on the arrow: with `TailVisibility.Collapsed`, or with no target,
`m_currentEffectiveTailPlacementMode` becomes `Auto`, whose visual state is named `"Untargeted"` and
draws nothing — while `m_currentEffectiveTipPlacementMode` is tracked separately so the body still
positions correctly.

`FlyoutBase`, `Popup` and `ToolTip` have **no arrow at all**. WinUI's mainstream flyout is arrowless
and uses the 4px `FlyoutMargin` instead. An absence worth recording.

**Algorithm.** `minTipEdgeToTailCenter = colW[0] + colW[1] + tailLongSide / 2` (8 + 10 + 10 = 28 by default).
`place(TopRight)`: `y = target.Y - tipH - margin.Top`, `x = targetCenterX - minTipEdgeToTailCenter`.
`place(Top)`: `x = targetCenterX - tipW / 2`.
`fitTest(RightTop)` requires `contentH - minTipEdgeToTailCenter <= space.Top + target.H / 2`.

**Where the behavior lives.** Split across three places, badly: the XAML template owns the shape and
its grid cell, the theme dictionary owns the two band lengths, and the C++ reads `ActualWidth` and
`ColumnDefinitions[i].ActualWidth` back out after layout has run. Nothing here is a value that could
be computed before layout.

**Degradation.** In whole cells the arrow is one cell: the outer band becomes one cell, the second
band (a corner-radius allowance) becomes zero, `minTipEdgeToTailCenter` becomes one cell, and the
corner-aligned modes become _arrow in the second column from the edge_. The transform origin has no
meaning without animation, but the arrow's **cell coordinate** is exactly what a styling layer wants,
so it should still be emitted. The 1px negative-margin overlap has no cell analogue; with
box-drawing, the arrow becomes a glyph choice per side and the border must be broken at that cell —
the grid analogue of `TopLeftHighlightMargin`. The clearest lesson in this dimension is that every
scalar `TeachingTip` painfully recovers from layout should have been a constant _supplied to_ the
placement function.

### 5. Trigger semantics

Triggers are owned by services, not by the overlay.

`ToolTipService` attaches `PointerEntered`/`PointerExited`/`GotFocus`/`LostFocus`/`KeyDown` on the
owner and funnels every one of them into
`OnOwnerEnterInternal(sender, source, AutomaticToolTipInputMode)`
(`ToolTipService_Partial.cpp:583`), where the mode is one of `None`/`Touch`/`Mouse`/`Keyboard`
(pointer at `:1386`, focus at `:1663`). The mode is stored on the tooltip and later selects both the
delay and the offset.

Races between overlapping triggers are prevented by three mechanisms, all state on a per-core
`ToolTipServiceMetadata` singleton: a `m_tpLastEnterSource` dedupe so a bubbled enter from a child
is dropped (`:596`); a nesting rule where entering a child with a _different_ tooltip closes the
current one first and entering the _same_ element returns early; and an `s_bOpeningAutomaticToolTip`
reentrancy guard while `put_IsOpen(TRUE)` runs.

`FlyoutBase`'s trigger surface is programmatic (`ShowAt`, `ShowAtWithOptions`, plus the attached
`FlyoutBase.AttachedFlyout` + `ShowAttachedFlyout`). Pointer type enters as
`m_inputDeviceTypeUsedToOpen = GetLastInputDeviceType()` captured at `ShowAt` (`:1682`) — one
authoritative source rather than per-event sniffing — and is consumed later for focus state and for
the touch/pen placement adjustments of dimension 12. Assistive-technology triggers are handled by
`GetWasUIAFocusSetSinceLastInput()` (`:2259`), which forces `FocusState::Keyboard` so a Narrator user
gets focus moved into the flyout.

Submenus are `CascadingMenuHelper`'s: `OnPointerEntered` (`CascadingMenuHelper.cpp:167`) starts the
delayed-open timer only for non-touch pointers, so touch opens on release instead.

**Algorithm.** `onOwnerEnter(sender, source, mode)`: if `source == metadata.lastEnterSource` return; if another
tooltip is current, close it unless it belongs to this owner (in which case return); record owner and source;
`delay = initialShowDelay(mode, isReshow)`; arm the open timer.
`submenuEnter()`: cancel the parent's close timer; if the device is not touch, cancel our own close and arm the
delayed-open timer with `MenuShowDelay`.

**Where the behavior lives.** `ToolTipService_Partial.cpp` (a per-`DXamlCore` metadata singleton),
`CascadingMenuHelper.cpp` (a per-owner helper), `FlyoutBase` (programmatic only). The last-input-device
fact comes from the framework kernel's input manager.

**Degradation.** Hover triggers are unavailable where the target has no hover; the dedupe and
nesting rules are pure state-machine logic and survive everywhere. Keyboard triggers act on key
**down**, so a target with no key-release events loses nothing here. The portable idea is a single
shared trigger arbiter holding `(owner, source, mode, timers)` with "entering a different owner
closes the previous" as an explicit transition rather than an emergent race.

### 6. Timing

Every duration is read from the operating system; the toolkit owns only the ratios.

| Quantity                   | Source                                                                                 | Fallback                                                 |
| -------------------------- | -------------------------------------------------------------------------------------- | -------------------------------------------------------- |
| Initial show delay         | `SystemParametersInfo(SPI_GETMOUSEHOVERTIME)`                                          | `DEFAULT_SPI_GETMOUSEHOVERTIME = 400` ms                 |
| Max display duration       | `SPI_GETMESSAGEDURATION` (`ToolTipService_Partial.cpp:450`)                            | `DEFAULT_SHOW_DURATION_SECONDS = 5`                      |
| Submenu open + close delay | `HKEY_CURRENT_USER\Control Panel\Desktop\MenuShowDelay` (`CascadingMenuHelper.cpp:83`) | `DefaultMenuShowDelay = 400` (`MenuFlyout_Partial.h:13`) |
| Reshow window              | `BETWEEN_SHOW_DELAY_MS = 200` (`ToolTipService_Partial.h:17`)                          | —                                                        |
| Safe-zone poll             | `s_safeZoneCheckTimerDuration = 10000000L` = 1 s (`:22`)                               | —                                                        |

The per-mode multipliers are applied in `GetInitialShowDelay`
(`ToolTipService_Partial.cpp:1769-1780`):

```cpp
case AutomaticToolTipInputMode::Touch:
    ulSPIGetMouseHoverTimeTicks *= isReshow ? 0 : 1;
    break;
case AutomaticToolTipInputMode::Mouse:
    ulSPIGetMouseHoverTimeTicks *= static_cast<INT64>(isReshow ? 1.5 : 2);
    break;
case AutomaticToolTipInputMode::Keyboard:
    ulSPIGetMouseHoverTimeTicks *= 2;
    break;
```

Touch's [warm-up][concepts] on a reshow is exactly **zero** — instant, not merely shortened.

> [!NOTE]
> The mouse reshow factor reads as `1`, not `1.5`: the ternary yields a `double`, and
> `static_cast<INT64>` truncates it _before_ the multiplication. That is a reading of the C++, not a
> measured behaviour — nothing was built or run — but it is what the expression at
> `ToolTipService_Partial.cpp:1775` computes.

"Reshow" means `GetTickCount() - s_lastToolTipOpenedTime < BETWEEN_SHOW_DELAY_MS` (`:659`), and the
timestamp is assigned in `CloseAutomaticToolTip` — so despite the name, this is a **[cool-down][concepts]
measured from the previous tooltip's close**.

Grouping is singleton-shaped: one automatic tooltip per thread, and one flyout per `FlyoutMetadata`
scope with a single _staged_ slot — opening B while A is open hides A, stages B, and opens B from
A's `OnPresenterUnloaded` (`CheckAndHandleOpenFlyout`, `FlyoutBase_partial.cpp:1691`). A third
request replaces the staged one. Child flyouts get their own metadata on the parent, so a submenu
never evicts its parent.

**Algorithm.** The machine visible in the source, restated as a value:
`state ∈ { Idle, WarmingUp(deadline), Shown(closeDeadline), Cooling(until = closeTime + 200 ms) }`.
`enter(owner, mode)` → `WarmingUp(now + base × factor(mode, reshow = state is Cooling))`;
`tick` → open at the warm-up deadline, close at the display deadline, close when the pointer leaves the safe zone;
`leave(owner)` → `Idle`; `close()` → `Cooling`.
Factors: `Touch {first 1, reshow 0}`, `Mouse {2, 1.5 as written}`, `Keyboard {2, 2}`.

**Where the behavior lives.** `ToolTipService_Partial.cpp` (a `DispatcherTimer` for open/close and a
`DispatcherQueueTimer` for the safe zone), `CascadingMenuHelper.cpp` (two timers), and
`FlyoutMetadata` for the singleton. The _values_ live in the OS.

**Degradation.** With no timers at all — a static, script-free HTML target — this dimension has no
answer beyond a CSS transition delay, and the honest statement is that such a target shows
immediately. Where timers exist the machine above is directly implementable as a value updated per
frame with absolute deadlines, which makes it assertable by driving a clock. The portable insight is
that the cool-down is **one `(lastCloseTime, window)` pair on the shared arbiter**, not per-widget
state.

### 7. Interactive hover

Two genuinely different mechanisms ship here, plus a third that is neither.

**(A) The convex-hull [safe polygon][concepts].** Once a tooltip is open, a 1 Hz
`DispatcherQueueTimer` samples `GetCursorPos()` — screen coordinates, chosen deliberately over
`PointerPoint.Position` "since it is based on the current window", which would be wrong for
out-of-window tooltips (`OnSafeZoneCheck`, `ToolTipService_Partial.cpp:366`). If the cursor has not
moved since the timer started (both axes within 0.1) the check returns early, so a keyboard-opened
tooltip is never dismissed by a parked mouse. Otherwise
`IsToolTipInSafeZone(point, ownerBounds, toolTipBounds)` (`:1062`) decides:

```cpp
if (ToolTipService::IsPointInRect(point, ownerBounds) || ToolTipService::IsPointInRect(point, toolTipBounds))
{
    return true;
}
XPOINTF polygonPoints[] = { /* the 8 corners of both rects */ };
ComputeConvexHull<XPOINTF>(ARRAYSIZE(polygonPoints), polygonPoints, &numHullPoints, polygonPoints);
const bool isPointInsideConvexHull = IsPointInsidePolygon(testPoint, numHullPoints, /* … */);
```

`ComputeConvexHull` is a PAL template (`dxaml/xcp/pal/inc/xcpmath.h:402`). The corridor is
**symmetric** (no trajectory, no direction), **stateless** (no history) and **polled** (no
pointer-move handler).

**(B) Submenu aim is not geometric at all.** `CascadingMenuHelper::OnPointerExited` (`:236`) re-runs
`VisualTreeHelper::FindAllElementsInHostCoordinatesPointStatic` at the exit point _twice_ — once
rooted at the owner's tree, once at the submenu presenter's, because they live in different popup
subtrees — and arms the close timer only if neither is under the point. Entering a child cancels the
parent's close (`parentOwner->CancelCloseSubMenu()`, `:152`), which is what keeps a chain open.

**(C) Move-away dismissal.** `FlyoutShowMode.TransientWithDismissOnPointerMoveAway` installs a
root-visual `PointerMoved` handler whose entire algorithm is a squared axis-wise distance
(`FlyoutBase_partial.cpp:2447-2449`):

```cpp
// The flyout is hidden when the pointer is moved more than 80 pixels
// away from its bounds. This is the square of that threshold distance.
const double hidingThreshold = 6400;
```

**Algorithm, costed in whole cells.** The hull of eight integer points is on the order of two dozen comparisons with
integer cross-products, and point-in-polygon over at most eight vertices is another eight — per _poll_, not per move.
The submenu exit test is two reverse-order scans of a derived hit list at one point. Move-away is
`dx = max(0, rect.left - p.x, p.x - rect.right)`, likewise `dy`, dismiss when `dx² + dy² > R²` — four compares and
two multiplies, no square root, and "inside the rect" falls out as distance zero.

**Where the behavior lives.** `ToolTipService` plus a PAL math routine plus `GetCursorPos`;
`CascadingMenuHelper` plus the framework's hit testing; `FlyoutBase` plus a routed handler on the
root visual.

**Degradation.** (A) is the mechanism worth porting, because it needs no pointer-move stream: a
per-frame test of the last known pointer cell is enough, which suits an immediate-mode repaint and
is assertable by feeding cursor positions. Notably it also needs **no pointer [grab][concepts]** —
it is a test against a sampled position, not a capture. Where hover does not exist at all the
dimension is not applicable and the surfaces must be tap-driven; note that WinUI does not merely
"not trigger" on touch — it carries a distinct `AutomaticToolTipInputMode::Touch` timing branch —
but the hull test is computed from a cursor position and has nothing to consume without one. On a
static target the corridor cannot exist, and the mitigation WinUI implicitly relies on is available:
make the gap zero so one hover region covers anchor and surface together.

### 8. Dismissal

Centralized and enumerable — the cleanest dimension in this subject.

`CPopupRoot::OnPointerPressed` (`Popup.cpp:5322`) closes the topmost light-dismiss popup, but only
when the popup root itself was the event source, and it marks the event handled **only if something
actually closed**:

```cpp
if (pRoutedEventArgs->m_pSource == this)
{
    bool didCloseAPopup = false;
    IFC_RETURN(CloseTopmostPopup(DirectUI::FocusState::Pointer, CPopupRoot::PopupFilter::LightDismissOnly, &didCloseAPopup));
    pRoutedEventArgs->m_bHandled = didCloseAPopup;
}
```

`CPopupRoot::OnKeyDown` (`:5340`) handles `VK_ESCAPE` with a **wider** filter,
`PopupFilter::LightDismissOrFlyout` — so a non-light-dismiss flyout still closes on Escape even
though a press outside it does not close it.

Which message types dismiss at all is one function
(`PointerInputProcessor.cpp:1028`):

```cpp
bool PointerInputProcessor::ShouldEventCloseFlyout(_In_ MessageMap message)
{
    // Pointer-down messages should close the topmost flyout.
    // The others can pass through the light-dismiss layer, but should leave it open.
    return message == XCP_POINTERDOWN;
}
```

Right-click and drag-and-drop always pass through — the drag case is enforced in the hit test itself
(`Popup.cpp:4748`, gated on `!FxCallbacks::DXamlCore_IsWinRTDndOperationInProgress()`).

Focus-out is `FlyoutBase::OnPopupLostFocus` (`:2348`): walk the newly focused element's ancestors
looking for a `CPopup`, and hide unless the new focus is inside a light-dismiss popup — with two
special cases. A `RootScrollViewer` grabbing focus during tap-and-hold is ignored, and a ComboBox
dropdown is recognized _structurally_ by finding a `CComboBoxLightDismiss` as the popup's grandchild
(`HasComboBoxLightDismiss`, `:4008`), because such dropdowns are not flagged light-dismiss. When the
popup root exists but no popup object can be resolved (hosted islands), the code errs toward **not**
hiding.

Anchor liveness: `TeachingTip` subscribes `Target.Unloaded` → `ClosePopupOnUnloadEvent`
(`TeachingTip.cpp:1376`), and there is a shipped test that a _previous_ target unloading does **not**
close the tip (`TeachingTipTests.cs:156`). Chain closing is top-down by design —
`FlyoutBase::HideImpl` (`:1192`) hides child flyouts first "to produce the effect of the entire chain
of child flyouts closing at the same time" rather than bottom-up with a visible cascade.

Cancellation exists on both sides: `FlyoutBaseClosingEventArgs.Cancel`, and
`TeachingTipClosingEventArgs` with a `Deferral` whose callback re-sets `IsOpen(true)` when cancelled.
The close **reason** is a first-class enum (`CloseButton | LightDismiss | Programmatic`) — but
`TeachingTip` can only _infer_ `LightDismiss`, by watching its shadow popup's `Closed`
(`OnLightDismissIndicatorPopupClosed`, `:1382`).

**Algorithm.** The observed dismissal table:

| Input                                         | Effect                                                   |
| --------------------------------------------- | -------------------------------------------------------- |
| pointer **down** on the dismiss layer         | close topmost light-dismiss popup; handled iff it closed |
| pointer move / up / wheel on the layer        | pass through, stay open                                  |
| right-click, drag-and-drop                    | pass through, stay open                                  |
| Escape (key **down**, at the popup root)      | close topmost {light-dismiss **or** flyout}              |
| focus moved outside every light-dismiss popup | `Hide()` (ignore `RootScrollViewer`; sniff ComboBox)     |
| target `Unloaded`                             | `IsOpen = false`                                         |
| presenter `Unloaded`                          | `OnClosed`, then open the staged flyout                  |
| `Hide()` with children                        | hide children first, then self                           |
| nothing fits at open                          | raise `Closing` + `Closed` anyway, never open            |

**Where the behavior lives.** Framework kernel for the mechanism (`CPopupRoot` for Escape and
pointer, `PointerInputProcessor` for the message policy); library for the policy (`FlyoutBase`
focus-out and chain closing, `TeachingTip` target-unload and reason inference).

**Degradation.** None of this requires an OS popup, and only the focus-out rule requires a focus
model. Dismissal is driven by pointer **down** and key **down**, so a target with no _keyboard_
release events loses nothing in this dimension. With no pointer grab, "pointer down outside" is
exactly a hit against a full-surface entry in a derived hit list — which is what WinUI does anyway.
On a static target the enumerable table collapses to a single row (re-toggling the control that
opened the surface), which is worth stating in an API rather than silently dropping.

### 9. Focus

The four surface kinds stay genuinely distinct, and the distinguishing switch is three booleans, set
in one place (`FlyoutBase::UpdateStateToShowMode`, `FlyoutBase_partial.cpp:3938`):

| `FlyoutShowMode`                        | `m_shouldTakeFocus` | `m_shouldHideIfPointerMovesAway` | `m_shouldOverlayPassThroughAllInput` |
| --------------------------------------- | ------------------- | -------------------------------- | ------------------------------------ |
| `Standard`                              | `true`              | `false`                          | `false`                              |
| `Transient`                             | `false`             | `false`                          | `true`                               |
| `TransientWithDismissOnPointerMoveAway` | `false`             | `true`                           | `true`                               |

On presenter load, focus moves in only if `Focus::FocusSelection::ShouldUpdateFocus` agrees — _or_
unconditionally for `MenuFlyout` regardless of the target's `AllowFocusOnInteraction`
(`:2264`), because `AppBarButton`'s default template sets that to false and honouring it would leave
an opened menu unusable by arrow keys. If focusing a child fails, focus lands on the `Popup` itself.

Restoration is a three-step ladder in `CPopup::Close` (`Popup.cpp:886`): the weak-referenced
previously focused element if it is still focusable, else the first focusable element from the root,
else `ClearFocus()`; the movement is stamped `isForLightDismiss = true` so downstream policy can
tell. The saved XY-focus manifolds (directional-navigation memory) are snapshotted at open
(`:617`, `ResetManifolds()`) and restored at close (`:940`).

`TeachingTip` inverts the usual model, and documents it
(`controls/dev/TeachingTip/TestUI/TeachingTip-FocusBehavior.md:3-12`): a **non**-light-dismiss tip
takes no focus and is reachable only by **F6**; a **light-dismiss** tip _does_ take focus on open,
and moving focus out closes it. F6 is handled in three places (content `PreviewKeyDown`, popup-child
`PreviewKeyDown`, and a `CoreWindow` accelerator fallback carrying a TODO for islands);
`HandleF6Clicked` (`TeachingTip.cpp:1178`) computes `hasFocusInSubtree` by walking
`VisualTreeHelper::GetParent` up to the tip's root, then either returns focus to the remembered
element or moves it in, preferring the close button. The tip is deliberately excluded from tab
order, with a test to pin it (`TeachingTipTests.cs:1040`).

**Algorithm.** `onOpen(mode)`: if `!takeFocus`, do nothing; else derive `focusState` from the last input device,
override to `Keyboard` when UIA set focus since the last input, and focus the presenter (or the popup on failure).
`onClose`: try the saved element, then the first focusable from the root, then clear; restore the XY-focus manifolds.
`F6(fromPopup)`: `inSubtree = ancestorWalk(focused) contains tipRoot`; in-subtree and from the popup ⇒ restore the
remembered element; outside and not from the popup ⇒ move focus in, remembering the previous element via a scoped
`GettingFocus` handler.

**Where the behavior lives.** Policy in `FlyoutBase`/`TeachingTip`; mechanism in the focus manager;
the previous-focus weak reference and the manifold snapshot in `CPopup`.

**Degradation.** Everything here is value-level policy over a focus model and needs no OS window.
F6 as a dedicated "move focus into the non-focus-stealing surface" key is directly adoptable and is
a lighter answer than a focus trap. The three-step restoration ladder is the important portable
piece, because a single "restore to the remembered element" cannot handle the element vanishing.
F6 and Escape act on key **down**, so no key-release capability is required. The `tooltip` /
`popover` / `menu` / `dialog` split that other stacks encode as four control types is, here, three
booleans — copy the booleans.

### 10. Layering & portals

`CPopupRoot` is the portal, and reparenting is what forces the centralization quoted in the
Overview. Z-order is insertion order in `m_pOpenPopups`, iterated `NewestBegin` first for hit
testing (`Popup.cpp:4896`); there is no z-index anywhere in the stack. `TeachingTip` exploits that
ordering as if it were API — its light-dismiss indicator popup must be opened _first_ so it sits
underneath (`TeachingTip.cpp:280-282`).

The escape hatch from the window is `ShouldConstrainToRootBounds = false` →
`CPopup::SetIsWindowedIfNeeded` (`Popup.cpp:1043`) → a real OS child window. It is conditional:
`MeetsRenderingRequirementsForWindowedPopup()` (`:2207`) is re-evaluated at every open, and
`SetIsWindowed` (`:1073`) notes that the platform may refuse, "so controls can use
`CPopup::IsWindowed` to determine whether to fall back to non-windowed placement". `MenuFlyout`s are
always windowed (`FlyoutBase_partial.cpp:967`).

Ownership is a tree of singletons, not one global: `FlyoutMetadata` holds `(openFlyout, target)` plus
`(stagedFlyout, stagedTarget)`, and a parent flyout allocates its own `m_childFlyoutMetadata`
(`GetFlyoutMetadata`, `:3661`).

The public/private split is instructive. Public: `ShouldConstrainToRootBounds`, `XamlRoot`,
`Popup.Child`, `LightDismissOverlayMode`, `OverlayInputPassThroughElement`. Implementation detail:
`CPopupRoot`, `m_pOpenPopups`, windowed-ness (`IsWindowed` is internal), the light-dismiss indicator
popup, `CComboBoxLightDismiss`. The _property_ names the intent; the _mechanism_ stays hidden.

**Algorithm.** `open(popup)`: push newest onto `m_pOpenPopups`; add the overlay element if visible; show the OS
window if windowed. `hitTest`: iterate newest → oldest, transform into each popup's space and bounds-test it; if a
popup is light-dismiss and the walk wants to continue, report a hit on the popup **root**.
`bounds(popupRoot) = union(all popup bounds) ∪ (any light-dismiss ? fullAvailableRect : ∅)`.

**Where the behavior lives.** Framework kernel, plus the compositor for windowed popups. The
ordering contract leaks into library code — `TeachingTip` depends on open order for z-order — which
is a smell worth not reproducing.

**Degradation.** A toolkit with no [top layer][concepts], no compositor and no OS popup gets only the
`ShouldConstrainToRootBounds == true` half of WinUI, and that half is complete and shipping.
"Later in the display list is in front" _is_ `m_pOpenPopups` insertion order, and reverse-order hit
testing _is_ `NewestBegin`. Two transferable API lessons: expose intent
(`shouldConstrainToRootBounds`) rather than mechanism (`isWindowed`), so a backend that cannot escape
the surface degrades by clamping instead of failing; and keep the overlay **tree** (parent → child
metadata) rather than a single global "current popup", which is what stops nested menus evicting
their parents.

### 11. Modality

WinUI's implemented distinction is that **light dismiss is not [modality][concepts]**. Light dismiss
means: the popup root claims full-surface bounds and hit-tests true everywhere
(`CPopupRoot::HitTestLocalInternalImpl`, `Popup.cpp:5151`); a pointer **down** there closes the
topmost such popup; Escape closes it; focus leaving it closes it. It does not block keyboard input
to the application and does not by itself set an accessibility modal bit.

The **scrim** is orthogonal and is decided by a pure static function — 38 lines of header, no state
(`LightDismissOverlayHelper.h:12-18`):

```cpp
static bool IsOverlayVisibleForMode(xaml_controls::LightDismissOverlayMode mode)
{
    bool isOverlayVisible = false;
    if (mode == xaml_controls::LightDismissOverlayMode_Auto)
    {
        isOverlayVisible = XboxUtility::IsOnXbox();
    }
    ...
```

`Auto` means _visible only on Xbox_. `FlyoutBase::ConfigurePopupOverlay` (`:3860`) then ANDs the
result with the popup's light-dismiss flag — "Some modes of flyout configure their popup as not
light-dismissible; for those cases don't allow the overlay to be visible" — and picks one of five
theme brushes by control type (`:3870`).

Pass-through is a distinct, _named_ capability: `OverlayInputPassThroughElement` designates a
`UIElement` whose pointer events reach through the dismiss layer, and the transient show modes
auto-set it to the root visual, tracking ownership in `m_ownsOverlayInputPassThroughElement` so it
can be un-set later (`SetPopupLightDismissBehavior`, `:1426-1430`).

The accessibility modal bit is a third, independent thing:
`TeachingTipAutomationPeer::IsModal()` returns `IsLightDismissEnabled()`, and
`GetAutomationControlTypeCore()` returns **`Window`** when light-dismiss and **`Pane`** otherwise
(`TeachingTipAutomationPeer.cpp:17`, `:55`) — the control changes its UIA type based on its
dismissal mode. `Flyout` (but not `MenuFlyout`) additionally sets `AutomationProperties.IsDialog`
on its popup (`FlyoutBase_partial.cpp:1393`).

**Algorithm.** `hitTest(point)`: if any open, non-unloading popup is light-dismiss, the popup root hit-tests as the
entire available rect. `overlayVisible = ((mode == On) || (mode == Auto && isXbox)) && isLightDismiss`.
`passThrough(point, msg)`: right-click and drag-and-drop pass; a point over the pass-through element's subtree passes;
otherwise the layer consumes it, and if the message is pointer-down it closes the topmost popup.
`uiaControlType = isLightDismiss ? Window : Pane`; `uiaIsModal = isLightDismiss`.

**Where the behavior lives.** Hit-testing and dismissal in the framework kernel; overlay _visibility_
in a header-only pure function of `(mode, deviceIsXbox)`; brush choice in `FlyoutBase`; the UIA bits
in the control's automation peer.

**Degradation.** Fully portable and cheap. On one surface, "light dismiss" is one extra full-surface
entry in the display list, painted before the popup, that the hit list resolves to a dismiss
action — WinUI's implementation _is_ that, minus the paint. The scrim stays an independent decision
(a translucent fill, or a dim attribute on a cell grid), and keeping it a pure function of
`(mode, target class)` keeps it out of the state machine. Pass-through needs an explicit "these
rects stay live" list, which a flat derived hit list handles naturally.

### 12. Adaptive presentation

There is no popover-to-sheet transformation and no responsive breakpoint in this stack. Adaptation
is per-input-device and per-platform, and it is decided in three different layers, none of which
consults a "form factor" object — each reads either `XboxUtility::IsOnXbox()` or
`GetLastInputDeviceType()`.

1. **Helper layer** — scrim visibility from device class (`Auto` ⇒ Xbox), above.
2. **Service layer** — `ToolTipService` picks delay _and_ offset from the input mode:
   `DEFAULT_KEYBOARD_OFFSET = 12`, `DEFAULT_MOUSE_OFFSET = 20` (`ToolTip_Partial.h:10`), plus
   `CONTEXT_MENU_HINT_VERTICAL_OFFSET = -5` (`:14`) because on touch the tooltip doubles as the
   context-menu hint. It also **refuses to open automatic tooltips on Xbox at all**
   (`ToolTipService_Partial.cpp:441`).
3. **Control layer** — `FlyoutBase::UpdateTargetPosition` (`:3299`) prefers `Top` for a
   touch-opened `MenuFlyout` (shifting up by the full presenter height so the menu is not under the
   finger) and applies pen "handedness" (shift left by the presenter width when right-handed and
   not RTL), each with its own flip-back guard when the shifted position leaves the screen
   (`:3474`).

`TeachingTip`'s own adaptation is the targeted/untargeted split: with no `Target` it becomes a
corner-anchored tip positioned by `UntargetedTipNearPlacementOffset` /
`UntargetedTipFarPlacementOffset` (`TeachingTip.h:274-276`) against a fixed
`s_untargetedTipWindowEdgeMargin = 24` (`:310`), and its arrow is suppressed unless explicitly
`Visible`.

**Algorithm.** `near(coord, off) = 24 + coord + off`; `far(farCoord, size, off) = farCoord - (size + 24 + off)`;
`center(near, far, size, nOff, fOff) = (near + far) / 2 - size / 2 + nOff - fOff`.
`touchMenuAdjust`: `y -= presenterH`; if the result is above the available rect, `y += presenterH` and flip `Top` ⇄ `Bottom`.
`penHandedness`: `x -= presenterW` when right-handed ≠ RTL; if the result is left of the available rect, undo and flip.

**Where the behavior lives.** Deliberately spread across a static helper, a service and the placement
function.

**Degradation.** WinUI's answer to the layering question is clear: the decision belongs to whoever
owns the input fact, and the placement function receives it as a plain parameter
(`m_inputDeviceTypeUsedToOpen`) rather than sniffing it. That maps onto a backend-neutral toolkit
directly — the host knows the target and the last input kind, the view picks a preferred placement,
and the placement function stays pure. Where hover is absent, the touch branches (offset hint,
prefer-top so the finger does not cover the surface, zero reshow delay) are the ones that matter, and
the corner margin becomes a small cell count; the soft-keyboard inset enters as _viewport_, not as
adaptation. These last mappings are inferences about porting — WinUI does not target mobile.

### 13. Accessibility

UI Automation, with an unusually explicit mapping.

`TeachingTipAutomationPeer` switches control type on dismissal mode (light-dismiss ⇒ `Window` +
`IsModal` + the window pattern; otherwise `Pane`), derives `InteractionState` from `(m_isIdle,
IsOpen)` (`:34`), and raises `WindowOpened`/`WindowClosed` **only** in the light-dismiss case
(`:105`). Independently, every open raises a notification event —
`RaiseNotificationEvent(Other, CurrentThenMostRecent, …, "TeachingTipOpenedActivityId")` — composed
from `Package.Current.DisplayName` plus the popup's automation name (`TeachingTip.cpp:1300`), so a
tip that is only a `Pane` is still announced.

Names flow explicitly: `AutomationProperties.Name` on the tip, falling back to `Title`, is copied
onto the _popup_ (`SetPopupAutomationProperties`, `:261`); button names come from their content; the
icon-only alternate close button gets both a localized name and its own tooltip (`:106`).
`ContentRootGrid` carries `AutomationProperties.LandmarkType="Custom"`
(`TeachingTip.xaml:312`) with a localized landmark name, so a screen reader can jump to the tip.

WinUI's `ToolTip` is a `ContentControl` and can technically host anything, but the timing machinery
around it — a max display duration from `SPI_GETMESSAGEDURATION` and dismissal when the cursor
leaves the hull — makes interactive content impractical. Against WCAG 1.4.13 the convex-hull safe
zone satisfies _hoverable_, Escape satisfies _dismissible_, and the fixed max duration works against
_persistent_.

**Algorithm.** `controlType = isLightDismiss ? Window : Pane`; `isModal = isLightDismiss`;
`interactionState = idle && open ? ReadyForUserInteraction : idle && !open ? BlockedByModalWindow : !idle && !open ? Closing : Running`;
`onOpen`: raise the notification, and raise `WindowOpened` only when light-dismiss **and** a listener exists.

**Where the behavior lives.** Control-level automation peers talking to the UIA provider surface; the
framework kernel supplies the `ListenerExists` gating so no event string is composed when nobody is
listening.

**Degradation.** A cell grid cannot expose a UIA or AT-SPI tree, and pretending otherwise would be
worse than silence. What it _can_ honestly expose is the announcement on open (the analogue of
`RaiseNotificationEvent`), a stable accessible name, and a real dismiss affordance. The genuinely
transferable split is that the **primitive** owns "is this surface dismissible, is it modal, what is
its name, did it just open or close", while the semantic **component** owns "this is a tooltip / a
menu / a dialog" — and WinUI shows the primitive-level bit is real by deriving `controlType` from
the dismissal flag rather than from the control class.

> [!WARNING]
> `InteractionState` reports `BlockedByModalWindow` for the idle-and-closed case
> (`TeachingTipAutomationPeer.cpp:34`), which is not what that UIA value means. Copy the structure,
> not the mapping.

### 14. Animation

Geometry metadata is emitted specifically to drive animation, in two forms.

**Transform origin from the arrow.** `UpdateTail` (`TeachingTip.cpp:349`) computes a `CenterPoint`
per placement mode and pushes it onto the occlusion grid and the tail edge border, so the expand
animation grows _out of the arrow's attachment point_. The expand key frame scales from
`Vector3(min(0.01, 20.0 / Width), min(0.01, 20.0 / Height), 1.0)` to identity over 300 ms
(`:1660`); the contract animation is the mirror at 200 ms (`:1707`) and ends at a _pixel-relative_
scale rather than zero — which is why `ClosePopup` explicitly resets `Scale` to identity (`:1460`),
or a re-shown tip would rasterize its text at that tiny scale and magnify it.

**Side data to the styling layer.** The effective placement is published as a visual state name —
`VisualStateManager::GoToState(*this, L"TopRight", false)` — which is how the template positions the
arrow and picks the highlight margins, and
`TeachingTipTemplateSettings.TopLeftHighlightMargin`/`TopRightHighlightMargin` are geometry computed
in C++ and handed over as `Thickness` values.

`FlyoutBase`'s equivalent is `PreparePopupTheme(popup, effectivePlacementMode, target)` (`:1885`),
selecting a `PopupThemeTransition` with `g_entranceThemeOffset = 50.0` (`:68`) in the placement
direction — after un-applying the RTL adjustment, because transitions already respect flow direction.

Reduced motion is read through `SharedHelpers::IsAnimationsEnabled()` (`TeachingTip.cpp:934`), and it
**changes the shape of the state machine**: without animations the `Opened` event fires inline and
`SetIsIdle(true)` runs immediately instead of from a composition scoped-batch completion callback.
Reposition during a transition is prevented by the `m_isIdle` interlock (dimension 15).

**Algorithm.** `centerPoint(mode, w, h, colW[], rowH[])`: `Top → (w/2, h - rowH[4])`; `Bottom → (w/2, rowH[0])`;
`Left → (w - colW[4], h/2)`; `Right → (colW[0], h/2)`; `TopRight → (colW[0] + colW[1] + 1, h - rowH[4])`;
`Auto → (w/2, h/2)`. Expand: scale from `(max(0.01, 20/w), max(0.01, 20/h))` to 1 over 300 ms about that point.
Emit to the style layer: `visualStateName = effectivePlacementMode`, plus the two computed highlight thicknesses.

**Where the behavior lives.** Library computes the geometry, the XAML template consumes the visual
state and template settings, the compositor plays the key frames. The _metadata production_ is
backend-free; only playback is not.

**Degradation.** On a cell grid there is no transform origin and no scale, so animation degrades to
nothing — but the metadata is the durable part and should be emitted regardless:
`(effectiveSide, effectiveAlign, arrowCell)` from the placement result is precisely
`GoToState("TopRight")` plus `CenterPoint`, and it is what a styling layer needs whether or not it
animates. The `IsAnimationsEnabled()` branch is the model to copy — reduced motion should change the
_state machine_ (fire `Opened` immediately, go idle inline), not merely set durations to zero. The
`m_isIdle` interlock, restated as `Phase { Idle, Opening, Shown, Closing }` plus one pending flag, is
value-semantics friendly and assertable frame by frame.

### 15. State architecture

Imperative controllers over a dependency-property system, with no explicit state machine — and the
seams show.

`TeachingTip`'s state is roughly fifteen loose members (`TeachingTip.h:211` onward): `m_isIdle`,
`m_isExpandAnimationPlaying`, `m_isContractAnimationPlaying`, `m_ignoreNextIsOpenChanged`,
`m_isTemplateApplied`, `m_createNewPopupOnOpen`, `m_hasF6BeenInvoked`,
`m_currentEffectiveTipPlacementMode`, `m_currentEffectiveTailPlacementMode`, `m_lastCloseReason`,
plus four cached rects and sizes.

The closest thing to a machine is the idle interlock, and it is implemented by _bouncing the public
property_: `OnIsOpenChanged` (`:822`) posts onto composition rendering and, if the control is not
idle, flips `IsOpen` back and sets `m_ignoreNextIsOpenChanged` so the resulting notification is
swallowed. The request is dropped, not queued.

`m_currentEffectiveTipPlacementMode` doubles as a memo: `DetermineEffectivePlacement` (`:1843`)
returns the cached mode when the tip is open and the cached value is not `Auto`, so placement is
_sticky_ once chosen — and four separate sites must remember to reset it (hero-content placement
changes at `:1110`, content size changes, close, and tail visibility). It is a documented
invalidation protocol with no enforcement.

`FlyoutBase` adds real multi-object state: `FlyoutMetadata{openFlyout, target, stagedFlyout,
stagedTarget}` as the arbiter, `m_openingCanceled`, `m_wasTargetPositionSet`/`m_lastTargetPoint` for
the same-position dedupe (`:1709`), and closing cancellation through event args. Configuration
changes that cannot apply live are deferred rather than applied:
`OnShouldConstrainToRootBoundsChanged` (`:1084`) merely sets `m_createNewPopupOnOpen = true`.

**Algorithm.** The reusable part, as observed:

```text
onIsOpenChanged():
    if ignoreNext { ignoreNext = false; return }
    postToRenderTick(():
        if isIdle -> isOpen ? enterOpen() : enterClose()
        else      { ignoreNext = true; IsOpen = !IsOpen }   // reject and revert
    )

enterOpen():
    cache rects; ensure popup; (mode, doesNotFit) = determinePlacement()
    if doesNotFit -> raise Closing + Closed, IsOpen = false, DO NOT OPEN
    else          -> isIdle = false; open shadow popup; open popup; animate or go idle

placementMemo: determinePlacement() returns the cached mode iff (IsOpen && cached != Auto)
```

**Where the behavior lives.** Entirely library code, but the transport is the dependency-property
system and the scheduler is `QueueCallbackForCompositionRendering` — a frame tick. The machine
already advances on frames rather than on events, which is the right shape even though the
implementation is not.

**Degradation.** This architecture as written depends on reference identity, weak references,
revokers and property-changed reentrancy, so it does not survive a value-semantics toolkit — but its
_content_ does, restated as
`struct OverlayState { Phase phase; Side side; Align align; Rect anchor; Rect surface; CloseReason lastReason; bool pendingToggle; }`
with a pure `step(state, event, clock)`. Three specific lessons: give the placement memo an explicit
invalidation _input set_ (anchor rect, content size, surface size, hero placement) so it becomes
`if inputs changed then recompute` rather than four scattered resets; do not reject a mid-transition
toggle by writing a public property and swallowing the echo; and keep the rule that "does not fit ⇒
never open, but still fire the full open/closing/closed lifecycle", which only a state machine can
guarantee.

### 16. Shared infrastructure

Factoring is by **substrate**, not by control — and the two most interesting overlays both bypass the
shared base.

| Layer                 | Owns                                                                                                                                |
| --------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| `CPopup`/`CPopupRoot` | portal, z by open order, the light-dismiss hit layer, Escape, focus save/restore, overlay brush, the windowed escape hatch          |
| `FlyoutBase`          | anchor → rect, placement + fallback + resize, the show-mode flags, the open-flyout singleton and staged queue, closing cancellation |
| `CascadingMenuHelper` | submenu open/close delay, the hover chain, the `ISubMenuOwner` seam (shared by `MenuFlyoutSubItem` and `MenuBarItem`)               |
| `ToolTipService`      | timing arbiter, input mode, safe zone — **bypasses `FlyoutBase`**                                                                   |
| `TeachingTip`         | its own placement engine, the arrow, shadow-popup light dismiss — **bypasses `FlyoutBase`**                                         |

`ToolTip` is a `ContentControl` plus its own `Popup` plus its own placement code, and that code
exists twice: `ToolTip::PerformPlacementWithPopup` (`ToolTip_Partial.cpp:772`) and
`PerformPlacementWithWindowedPopup` (`:1333`) are two long functions whose anchor-selection and
offset sections read as near-duplicates (they were not diffed line by line, so exactly how their
clamping differs is unverified here). `ComboBox` is a third path: a popup that is not flagged
light-dismiss but carries a `CComboBoxLightDismiss` element, which forces `FlyoutBase` to identify it
by tree shape (`HasComboBoxLightDismiss`, `:4008`).

So, from this subject's own source: **truly common** is the portal, the dismissal layer, focus
save/restore, the anchor-to-rect conversion, and the fit/fallback geometry. **Looks common but stayed
apart** is timing (only tooltips and submenus have it, from different sources), arrow geometry (only
`TeachingTip`), focus-taking (menus force it, tooltips forbid it, flyouts make it a mode), resize-to-fit
(flyouts only — `TeachingTip` refuses to open instead of shrinking), and singleton scope (one global
tooltip; one flyout per metadata scope with a per-parent child scope).

**Where the behavior lives.** Three tiers: framework kernel, shared library base classes, per-control
code.

**Degradation.** All three tiers collapse onto one surface without loss, because the interesting tier
is the middle one. The concrete warning this subject supplies for a shared primitive is specific and
checkable: `TeachingTip` forked a whole parallel placement engine because `FlyoutBase`'s fit test has
no arrow-inset parameter. If a shared fit test is to serve an arrow-bearing consumer, `arrowInset`
has to be a parameter of it from the start.

## Strengths

- The classic core is present and readable at this revision — `CPopup`, `CPopupRoot`, `FlyoutBase`
  and `ToolTipService` are full implementations, so light-dismiss and placement semantics can be
  verified against source rather than behaviour.
- Placement is a pure function of cached rects. `TransformToVisual` runs once at open; afterwards no
  transform, scroll container or clipping ancestor participates in any decision.
- The arrow is a first-class positioned element with real math: `MinimumTipEdgeToTailCenter()` feeds
  both the fit test and the final offset, and the arrow's attachment point becomes the animation's
  transform origin.
- Light dismiss is bounds inflation plus a hit predicate, not a scrim element — which cleanly
  separates "dismiss region" from "dim overlay".
- Dismissal semantics are precise and enumerable: pointer **down** only; right-click and
  drag-and-drop always pass through; Escape uses a wider filter than a pointer press; `handled` is
  set only if something actually closed.
- A real hover safe polygon ships — the convex hull of anchor ∪ tooltip — polled rather than
  event-driven, with a no-movement early-out so a keyboard-opened tooltip survives a parked mouse.
- Focus restoration is a three-step ladder and even snapshots and restores directional-navigation
  manifolds.
- Reduced motion changes event ordering rather than only durations, so the lifecycle is identical
  with and without animation.
- "Does not fit" still raises the complete open/closing/closed sequence so consumers relying on the
  event order do not leak.
- Timing values come from OS settings with per-input-mode multipliers, including a 200 ms cool-down
  window and a touch reshow factor of exactly zero.
- `ResizeToFit` is a genuine third collision strategy — shrink to available space, floored by
  `MinWidth`/`MinHeight` — rather than only flip and shift.
- The soft-keyboard occlude rect is subtracted from the placement container as a normal input, and
  input-pane state changes re-run placement.
- `ShouldConstrainToRootBounds` exposes intent while `IsWindowed` stays internal and is re-decided
  per open, so a platform that cannot escape the window degrades by clamping instead of failing.

## Weaknesses

- Two and a half parallel placement engines: `FlyoutBase`, `TeachingTip`, and `ToolTip` — the last
  with near-duplicate windowed and non-windowed variants of a long function. `TeachingTip` forked
  because `FlyoutBase`'s fit test cannot express an arrow inset.
- `MenuFlyout::AutoAdjustPlacement`, the only override of the auto-adjust hook, reads as dead code —
  and the hook is skipped entirely whenever the application set `Placement` locally.
- A shipping `TeachingTip` does not follow a moving target: `EffectiveViewportChanged` is subscribed
  only when `m_tipFollowsTarget` is true, which defaults to false and is reachable only through
  `TeachingTipTestHooks`.
- `TeachingTip` declines multi-monitor placement outright when `ShouldConstrainToRootBounds` is
  false, by explicit admission in a comment.
- The light-dismiss shadow popup is a genuine hack whose correctness depends on undocumented
  z-ordering by open order.
- The idle interlock rejects a mid-transition request by writing the public `IsOpen` property back
  and swallowing the echo. The request is dropped, not queued.
- The placement memo has an unenforced invalidation protocol: four call sites must remember to reset
  it, each with its own explanatory comment.
- `ComboBox` dropdowns are recognized by walking `Popup` → panel → `children[0]` and type-checking —
  one control identifying another by tree shape.
- The most interesting placement tests are disabled: `AutoPlacement`
  (`TeachingTipTests.cs:321`, "Disabled as per tracking issue #3125"), `SpecifiedPlacement` (`:349`)
  and `SpecifiedPlacementRTL` (`:553`) all carry `[TestProperty("Ignore", "True")]`, so the fallback
  matrix is not exercised in CI.
- `InteractionState` reports `BlockedByModalWindow` for the idle-and-closed case.
- `ShouldConstrainToRootBounds` cannot be changed on a live popup; the change is silently deferred
  to the next open.
- The 4px flyout margin is applied _after_ the container clamp, so an edge-pinned flyout can be
  pushed out of the container on the windowed path.
- Light-dismiss policy must be committed before the popup opens — that is, before placement is
  known — an ordering constraint the code explicitly regrets in a comment.

## Key design decisions and trade-offs

| Decision                                                                                                                                                               | Rationale                                                                                                                                                                                                             | Trade-off                                                                                                                                                                                                                                                                                                  |
| ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Represent "does it fit here" as a per-candidate availability boolean knocked out by named predicates, rather than as an overflow measurement per trial placement.      | Each predicate encodes a distinct geometric reason — target edge off-viewport, target midpoint off-viewport, no room beside, no room measured from the centre with the arrow inset — and the choice is then one pass. | All twenty predicates run even when the first candidate wins, and the predicate set must stay in sync with the enum (`Center` appears in five of them). It cannot express "fits if shrunk", so `TeachingTip` refuses to open where `FlyoutBase`, using trial-and-measure, can resize.                      |
| Make dismissal a property of the popup **root** — one full-surface hit region, one Escape handler, one "topmost matching popup" query with a filter.                   | Popups reparent their children under the root, so routed events from inside a popup skip the popup itself; centralizing is the only correct place, and it makes "topmost" and "chain" well-defined.                   | Individual popups lose the ability to observe their own light dismissal — which is exactly why `TeachingTip` opens a second, empty popup underneath itself just to receive a `Closed` event. Centralizing dismissal without also emitting a per-surface close **reason** is the mistake.                   |
| Read every timing constant from the OS (`SPI_GETMOUSEHOVERTIME`, `SPI_GETMESSAGEDURATION`, `MenuShowDelay`) and apply fixed per-input-mode multipliers on top.         | Respects user accessibility settings and platform convention; the toolkit owns only the ratios, which are the parts that are genuinely design decisions.                                                              | Behaviour is not reproducible across machines. A toolkit that wants assertable behaviour must inject the clock and base durations as values — keeping the ratios, not the sources.                                                                                                                         |
| Give the arrow a dedicated band in a 5×5 grid, let the layout system position it, then recover the numbers placement needs by reading `ActualWidth` back after layout. | The arrow becomes themable in XAML — points, alignment, per-side margins, border-highlight splitting — with no C++ change, and negative margins let its border merge with the body's.                                 | Placement now depends on layout having already run, the inset must be reconstructed with magic constants (`s_tailOcclusionAmount`, commented "Ideally this would be computed from layout but it is difficult to do"), and the engine had to be forked. Arrow geometry should be data fed _into_ placement. |
| Enforce one open flyout per scope with a metadata singleton plus a single staged slot, and give each parent flyout its own child metadata.                             | Prevents two peer flyouts being open without an explicit ownership model, makes re-showing at the same position a no-op, and lets nested menus form a tree of independent singletons.                                 | Only one request can be staged — a third `ShowAt` silently replaces the staged one — and opening becomes asynchronous, so `ShowAt` can return with `IsOpen == false`, which the code special-cases with an `openDelayed` out-parameter.                                                                    |
| Let reduced motion change the shape of the state machine, not just the durations.                                                                                      | With animations disabled the `Opened` event fires inline and the idle flag is set immediately instead of from a scoped-batch completion, so event ordering stays correct in both worlds.                              | Two code paths that must stay behaviourally equivalent, and the idle flag has to be re-asserted defensively in several places.                                                                                                                                                                             |
| Decide scrim visibility with a pure static function of `(LightDismissOverlayMode, isXbox)`, separately from whether dismissal is light.                                | Keeps the visual affordance out of the interaction state machine, and lets one device class get scrims by default with no control-level code.                                                                         | `Auto` means something undiscoverable from its name, and the two concepts still have to be re-coupled by hand (`isOverlayVisible &= isLightDismissEnabled`) in every consumer that cares.                                                                                                                  |

## Sources

Primary sources, all read at [`29ebf098f70df518b57b754130bc94004be8c6bc`][repo]:

- [`dxaml/xcp/core/core/elements/Popup.cpp`][popup-cpp] — `CPopup` and `CPopupRoot`: the portal, the
  open-popup list, light dismiss as bounds inflation plus hit predicate, Escape, the focus
  restoration ladder, the windowed escape hatch.
- [`dxaml/xcp/dxaml/lib/FlyoutBase_partial.cpp`][flyoutbase] — placement, fallback, `ResizeToFit`,
  the show-mode flags, the flyout singleton and staged queue, focus-out policy, the exclusion-rect
  nudge, overlay configuration.
- [`dxaml/xcp/dxaml/lib/ToolTipService_Partial.cpp`][ttsvc] and
  [`ToolTipService_Partial.h`][ttsvc-h] — the trigger arbiter, OS-sourced timing, the convex-hull
  safe zone.
- [`dxaml/xcp/dxaml/lib/ToolTip_Partial.cpp`][tooltip-cpp] and [`ToolTip_Partial.h`][tooltip-h] —
  the tooltip's own placement path and its per-input-mode offsets.
- [`dxaml/xcp/dxaml/lib/CascadingMenuHelper.cpp`][cmh] — submenu open/close delays, the hover chain,
  the double hit-test on exit.
- [`dxaml/xcp/components/ContentRoot/PointerInputProcessor.cpp`][pip] — which message types dismiss
  and which pass through.
- [`dxaml/xcp/components/controls/LightDismissOverlay/inc/LightDismissOverlayHelper.h`][ldoh] — scrim
  visibility as a pure function.
- [`dxaml/xcp/pal/inc/xcpmath.h`][xcpmath] — `ComputeConvexHull`.
- [`dxaml/xcp/dxaml/lib/MenuFlyout_Partial.cpp`][menuflyout] and [`MenuFlyout_Partial.h`][menuflyout-h].
- [`controls/dev/TeachingTip/TeachingTip.cpp`][tt-cpp] and [`TeachingTip.h`][tt-h] — the 14-candidate
  solver, the arrow, the shadow popup, F6, the idle interlock.
- [`controls/dev/TeachingTip/TeachingTip.xaml`][tt-xaml] and
  [`TeachingTip_themeresources.xaml`][tt-themeres] — the 5×5 band grid, the arrow's per-state
  geometry, the band lengths.
- [`controls/dev/TeachingTip/TeachingTipAutomationPeer.cpp`][tt-peer] — UIA control type, modality
  and the open announcement.
- [`controls/dev/TeachingTip/TeachingTipTestHooks.idl`][tt-hooks] — the test-only target-following
  switch.
- [`controls/dev/TeachingTip/TestUI/TeachingTip-FocusBehavior.md`][tt-focusdoc] — the documented
  focus contract.
- [`controls/dev/TeachingTip/InteractionTests/TeachingTipTests.cs`][tt-tests] — the anchor-liveness
  and tab-order tests, and the disabled placement matrix.

Related pages in this catalog: the umbrella [index][index], the shared
[vocabulary][concepts], the [capstone comparison][comparison], the
[edge-case inventory][forgotten], the [Sparkles baseline][baseline] and the
[proposal][proposal]. Nearest neighbours by architecture: [WPF][wpf] (the same lineage, one
generation earlier), [Uno][uno] (a managed reimplementation of this same API surface),
[Avalonia][avalonia] and [GTK4][gtk4] (one placement solver, two surface kinds), and
[xdg_positioner][xdg] (the same constraint-adjustment algebra expressed as a protocol). For the
surface-vs-window question see [`../window-system-integration/index.md`][wsi]; for how a placement
result reaches a canvas in this repository, see the toolkit specs
[`../../specs/ui/index.md`][spec-ui], [`../../specs/ui/input.md`][spec-input] and
[`../../specs/ui/state-machines.md`][spec-stm].

<!-- References -->

[repo]: https://github.com/microsoft/microsoft-ui-xaml/tree/29ebf098f70df518b57b754130bc94004be8c6bc
[learn]: https://learn.microsoft.com/windows/apps/winui/winui3/
[popup-cpp]: https://github.com/microsoft/microsoft-ui-xaml/blob/29ebf098f70df518b57b754130bc94004be8c6bc/dxaml/xcp/core/core/elements/Popup.cpp
[flyoutbase]: https://github.com/microsoft/microsoft-ui-xaml/blob/29ebf098f70df518b57b754130bc94004be8c6bc/dxaml/xcp/dxaml/lib/FlyoutBase_partial.cpp
[ttsvc]: https://github.com/microsoft/microsoft-ui-xaml/blob/29ebf098f70df518b57b754130bc94004be8c6bc/dxaml/xcp/dxaml/lib/ToolTipService_Partial.cpp
[ttsvc-h]: https://github.com/microsoft/microsoft-ui-xaml/blob/29ebf098f70df518b57b754130bc94004be8c6bc/dxaml/xcp/dxaml/lib/ToolTipService_Partial.h#L17-L22
[tooltip-cpp]: https://github.com/microsoft/microsoft-ui-xaml/blob/29ebf098f70df518b57b754130bc94004be8c6bc/dxaml/xcp/dxaml/lib/ToolTip_Partial.cpp#L772
[tooltip-h]: https://github.com/microsoft/microsoft-ui-xaml/blob/29ebf098f70df518b57b754130bc94004be8c6bc/dxaml/xcp/dxaml/lib/ToolTip_Partial.h#L10-L14
[cmh]: https://github.com/microsoft/microsoft-ui-xaml/blob/29ebf098f70df518b57b754130bc94004be8c6bc/dxaml/xcp/dxaml/lib/CascadingMenuHelper.cpp
[pip]: https://github.com/microsoft/microsoft-ui-xaml/blob/29ebf098f70df518b57b754130bc94004be8c6bc/dxaml/xcp/components/ContentRoot/PointerInputProcessor.cpp#L1028-L1033
[ldoh]: https://github.com/microsoft/microsoft-ui-xaml/blob/29ebf098f70df518b57b754130bc94004be8c6bc/dxaml/xcp/components/controls/LightDismissOverlay/inc/LightDismissOverlayHelper.h#L12-L26
[xcpmath]: https://github.com/microsoft/microsoft-ui-xaml/blob/29ebf098f70df518b57b754130bc94004be8c6bc/dxaml/xcp/pal/inc/xcpmath.h#L402
[menuflyout]: https://github.com/microsoft/microsoft-ui-xaml/blob/29ebf098f70df518b57b754130bc94004be8c6bc/dxaml/xcp/dxaml/lib/MenuFlyout_Partial.cpp#L348
[menuflyout-h]: https://github.com/microsoft/microsoft-ui-xaml/blob/29ebf098f70df518b57b754130bc94004be8c6bc/dxaml/xcp/dxaml/lib/MenuFlyout_Partial.h#L13
[tt-cpp]: https://github.com/microsoft/microsoft-ui-xaml/blob/29ebf098f70df518b57b754130bc94004be8c6bc/controls/dev/TeachingTip/TeachingTip.cpp
[tt-h]: https://github.com/microsoft/microsoft-ui-xaml/blob/29ebf098f70df518b57b754130bc94004be8c6bc/controls/dev/TeachingTip/TeachingTip.h
[tt-xaml]: https://github.com/microsoft/microsoft-ui-xaml/blob/29ebf098f70df518b57b754130bc94004be8c6bc/controls/dev/TeachingTip/TeachingTip.xaml#L283-L312
[tt-themeres]: https://github.com/microsoft/microsoft-ui-xaml/blob/29ebf098f70df518b57b754130bc94004be8c6bc/controls/dev/TeachingTip/TeachingTip_themeresources.xaml#L93-L94
[tt-peer]: https://github.com/microsoft/microsoft-ui-xaml/blob/29ebf098f70df518b57b754130bc94004be8c6bc/controls/dev/TeachingTip/TeachingTipAutomationPeer.cpp
[tt-hooks]: https://github.com/microsoft/microsoft-ui-xaml/blob/29ebf098f70df518b57b754130bc94004be8c6bc/controls/dev/TeachingTip/TeachingTipTestHooks.idl#L18
[tt-focusdoc]: https://github.com/microsoft/microsoft-ui-xaml/blob/29ebf098f70df518b57b754130bc94004be8c6bc/controls/dev/TeachingTip/TestUI/TeachingTip-FocusBehavior.md
[tt-tests]: https://github.com/microsoft/microsoft-ui-xaml/blob/29ebf098f70df518b57b754130bc94004be8c6bc/controls/dev/TeachingTip/InteractionTests/TeachingTipTests.cs
[index]: ./index.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[forgotten]: ./features-people-forget.md
[baseline]: ./sparkles-baseline.md
[proposal]: ./proposal.md
[wpf]: ./wpf.md
[uno]: ./uno.md
[avalonia]: ./avalonia.md
[gtk4]: ./gtk4.md
[xdg]: ./xdg-positioner.md
[wsi]: ../window-system-integration/index.md
[spec-ui]: ../../specs/ui/index.md
[spec-input]: ../../specs/ui/input.md
[spec-stm]: ../../specs/ui/state-machines.md
