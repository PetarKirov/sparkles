# Qt Quick Controls — `QQuickPopup`, `ToolTip`, `Menu` (C++ / QML)

One C++ base class factors every anchored surface in Qt Quick Controls — `Popup`,
`Dialog`, `Drawer`, `Menu`, `ToolTip`, and `ComboBox`'s list — into a declaration
plus a **permission set**: the style file states where the surface would like to
sit as ordinary property bindings, and a small positioner is granted, per
subclass, permission to flip, push or shrink it on each axis until it fits one
bounds rectangle.

| Field         | Value                                                                                                                                                                                                                            |
| ------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language      | C++ (Qt 6) with a QML styling layer                                                                                                                                                                                              |
| License       | `LicenseRef-Qt-Commercial OR LGPL-3.0-only OR GPL-2.0-only OR GPL-3.0-only`                                                                                                                                                      |
| Repository    | [`qt/qtdeclarative`][repo]                                                                                                                                                                                                       |
| Documentation | [`Popup` QML reference][doc-popup], [`ToolTip`][doc-tooltip], [`Menu`][doc-menu], [`Overlay`][doc-overlay]                                                                                                                       |
| Category      | Native desktop (Qt) — read as an implementation, not docs-only                                                                                                                                                                   |
| Surface model | **Both.** The same declaration resolves at `open()` time to an in-window `Item` inside `QQuickOverlay`, a real OS child window (`QQuickPopupWindow`), or a platform-native menu — see [dimension 12](#_12-adaptive-presentation) |
| Revision read | `ffc46f28ab21b6666dbea46c81cf2726ce682419` (dev branch, `QT_REPO_MODULE_VERSION` 6.13.0)                                                                                                                                         |

> [!NOTE]
> Every behavioural claim below is read from source and from the assertions
> written into Qt's own tests at that revision. No Qt build was run, and no
> performance characteristic was measured; the cost statements in
> [dimension 3](#_3-collision-geometry-engine) are structural, read off the code.

---

## Overview

### What it solves

Qt Quick Controls needs one overlay mechanism that serves six visually and
behaviourally different controls, across desktop, embedded and mobile, on both
a windowing system that offers real popup surfaces and one that does not. Its
answer is `QQuickPopup` — a `QObject`, not an `Item` — that owns lifecycle,
dismissal policy, modality, layer membership, margins and insets, and delegates
its visual body to a separate `QQuickPopupItem` and its geometry to a
`QQuickPopupPositioner`. Everything a style author touches (where the surface
sits relative to its anchor, what it looks like, what it animates) is QML;
everything the engine must do (fit it inside a rectangle, decide who eats the
click, decide who gets focus back) is C++.

The subject earns its place in this catalog for two properties that are unusual
in this corpus and directly relevant to a single-surface toolkit.

**Dismissal is genuinely one value.** `QQuickPopup::ClosePolicy` is a `QFlags`
that answers, in one comparable, storable, resettable word, _which pointer
phase_ dismisses, _relative to which rectangle_, whether the keyboard dismisses,
and whether the surface participates in a stack cascade
(`qquickpopup_p.h:244-254`):

```cpp
enum ClosePolicyFlag {
    NoAutoClose = 0x00,
    CloseOnPressOutside = 0x01,
    CloseOnPressOutsideParent = 0x02,
    CloseOnReleaseOutside = 0x04,
    CloseOnReleaseOutsideParent = 0x08,
    CloseOnEscape = 0x10,
    CloseMultiple = 0x20,
};
Q_DECLARE_FLAGS(ClosePolicy, ClosePolicyFlag)
```

`CloseMultiple` (`0x20`) is recent, which is itself evidence: the value shape
absorbed a new dismissal axis without an API change.

**The same declaration has two surfaces, and one of them is exactly the
constrained one.** Qt's in-window arm is a plain `QQuickItem` parented to the
window's content item at `z = 1000001`, stacking by paint order, needing no
compositor support of any kind — the universally-supported fallback that
`resolvedPopupType()` returns when the platform lacks multiple windows. Reading
the divergence between that arm and the OS-window arm inside one codebase is
the cheapest way to separate overlay behaviours that are intrinsic from those
borrowed from the window system. See [`./concepts.md`][concepts] for the shared
vocabulary (anchor rect, placement, gravity, constraint adjustment, flip / shift
/ slide / resize, clipping boundary, top layer, light dismiss, grab, safe
polygon, warm-up, cool-down, focus scope, modality, virtual anchor, transform
origin) and [`./comparison.md`][comparison] for the cross-subject view.

### Design philosophy

Qt names its own three-position model in a source comment, and that naming is
the philosophy in miniature — a request, a resolution, and a surface-local
coordinate are three different numbers (`qquickpopup.cpp:711-716`, inside
`QQuickPopupPrivate::setEffectivePosFromWindowPos`):

> ```text
> // Popup operates internally with three different positions; requested
> // position, effective position, and window position. The first is the
> // position requested by the application, and the second is where the popup
> // is actually placed. The reason for placing it on a different position than
> // the one requested, is to keep it inside the window (in case of Popup.Item),
> // or the screen (in case of Popup.Window).
> ```

The engine is a _corrector_, not a solver: it never chooses a side, never
enumerates candidates, and never reports what it did. `popup.x`'s setter records
the request and its getter returns the resolution — the triple exists inside the
class but only two thirds of it are reachable, which is the root of most of this
subject's weaknesses ([dimension 4](#_4-arrow-caret-geometry),
[dimension 14](#_14-animation)).

---

## How it works

Four objects and one optional window make up the whole stack.

| Object                  | Kind            | Owns                                                                              |
| ----------------------- | --------------- | --------------------------------------------------------------------------------- |
| `QQuickPopup`           | `QObject`       | Lifecycle, `closePolicy`, `modal`/`dim`, margins/insets, focus opt-in, a11y role  |
| `QQuickPopupItem`       | `QQuickItem`    | The visual body; `isTabFence = true`; forwards its a11y role to the popup's       |
| `QQuickPopupPositioner` | change listener | `reposition()` (in-window) and `repositionPopupWindow()` (OS window)              |
| `QQuickOverlay`         | `QQuickItem`    | The in-window layer, the stack order, modal blocking, the close cascade           |
| `QQuickPopupWindow`     | `QQuickWindow`  | The OS-window arm: transient parent, window-type hints, cross-window hover repair |

The open path, in order (`qquickpopup.cpp:778-806`, `:840-847`,
`:1207-1273`, `qquickpopuppositioner.cpp:75-286`):

```text
open()
  └─ transitionEnter
       ├─ prepareEnterTransition
       │    ├─ resolvedPopupType()          -- Item | Window | Native, decided HERE
       │    ├─ adjustPopupItemParentAndWindow()  -- popupItem->setParentItem(overlay)
       │    ├─ createDimmer() + showDimmer()     -- scrim, stacked just below
       │    ├─ aboutToShow()
       │    └─ if (focus) popupItem->setFocus(true, Qt::PopupFocusReason)
       ├─ run the QML `enter` transition
       └─ finalizeEnterTransition
            ├─ reposition()                 -- placement runs AFTER the animation
            ├─ openedChanged / opened()
            └─ QAccessible::PopupMenuStart | DialogStart
```

Two details of that ordering are load-bearing and reappear in several
dimensions. Placement runs in `finalizeEnterTransition`, so a `ToolTip`'s
timeout clock (started in `QQuickToolTipPrivate::opened()`) excludes the
animation. And `isOpened()` flips false the instant the exit transition
_starts_, while `isVisible()` stays true until it _finishes_ — a distinction the
close cascade depends on
([dimension 8](#_8-dismissal)).

---

## The analysis spine

### 1. Anchor model

The anchor is an **item**, never a rect, a point, a text range or a virtual
object. `QQuickPopupPositioner::m_parentItem` holds it; the popup's `x`/`y` are
an offset in that item's coordinate system; and the anchor-to-scene conversion
is one call — `m_parentItem->mapToItem(popupItem->parentItem(), rect.topLeft())`
(`qquickpopuppositioner.cpp:133`). Because only a single corner is mapped, an
ancestor rotation or scale is honoured only partially; the documentation's
answer for a scaled scene is to apply the same transform to `Overlay.overlay` by
hand, and there is a dedicated `rotatedCombobox` regression test.

`anchors.centerIn` is the only declarative anchor primitive and accepts exactly
two values — the immediate parent, or `Overlay.overlay`. Anything else emits
`Popup can only be centered within its immediate parent or Overlay.overlay` and
**aborts** `reposition()` entirely, leaving stale geometry
(`qquickpopupanchors.cpp:33`, `qquickpopuppositioner.cpp:118-131`).

Point anchoring exists only through `Menu::popup(pos)` and `ContextMenu`, which
converts a `QEvent::ContextMenu` scene position into attachee-local coordinates
and calls `setPosition` (`qquickcontextmenu.cpp:222-261`). Cursor anchoring is a
_fallback inside_ `QQuickMenuPrivate::popup` (`qquickmenu.cpp:2212-2228`): if the
platform reports `MultipleWindows` and has a cursor, the menu is positioned at
`parentItem->mapFromGlobal(QCursor::pos())`; otherwise it is **centred over its
parent item**. The platform, not the author, picks the anchor semantics.

Detached trigger versus anchor is supported by re-parenting rather than by a
separate field: the shared `ToolTip` instance calls `setParentItem(attachee)` on
each show (`qquicktooltip.cpp:739-755`), and `Menu::popup(parent, …)` does the
same — so "many triggers, one popup" works, but only one at a time. Text-range
and multi-rect anchors are absent. Moving anchors are tracked by listener
([dimension 3](#_3-collision-geometry-engine)).

**Algorithm.** `anchorRect := parentItem->mapToItem(overlayItem, QRectF(requested.x, requested.y, w, h))`;
if `centerIn` is set, move the rect's centre to the rounded centre of the
`centerIn` item. No other anchor kinds exist.

**Where the behaviour lives.** Library code (`QQuickPopupPositioner` +
`QQuickPopupAnchors`) over the Qt Quick scene graph's coordinate mapping. The
cursor fallback reaches into `QPlatformIntegration` capabilities and
`QCursor::pos()`.

**Degradation.** Nothing here needs an OS window, hover, script, sub-cell
precision or key release. The item pointer is used for exactly two things —
mapping coordinates and subscribing to geometry changes. _INFERENCE: with
per-frame layout both uses collapse into "pass the anchor's cell rect by
value", which is the shape [`./concepts.md`][concepts] calls an anchor rect._

### 2. Placement model

There is **no side or alignment vocabulary anywhere in this codebase** — no
`Top`/`Bottom`/`Start`/`End` enum, no preferred-placement list, no fallback
ordering. Placement is authored as QML bindings in the _style_ file. The Basic
style's `ToolTip` is the canonical example (`basic/ToolTip.qml:12-13`):

```qml
x: parent ? (parent.width - implicitWidth) / 2 : 0
y: -implicitHeight - 3
```

The engine's only contribution is collision correction, gated by six booleans on
`QQuickPopupPrivate` (`qquickpopup_p_p.h:166-171`):
`allowVerticalFlip` / `allowHorizontalFlip` (both default **false**),
`allowVerticalMove` / `allowHorizontalMove` (default true),
`allowVerticalResize` / `allowHorizontalResize` (default true).

Who turns flipping on is narrow and revealing:

| Subclass                             | Flip permissions granted                               | Source                         |
| ------------------------------------ | ------------------------------------------------------ | ------------------------------ |
| `ToolTip`                            | vertical **and** horizontal                            | `qquicktooltip.cpp:191-192`    |
| `ComboBox`'s popup                   | vertical only (plus Wayland/XCB window-type hints)     | `qquickcombobox.cpp:1491-1499` |
| `Menu`                               | horizontal only, and only when `cascade && parentMenu` | `qquickmenu.cpp:1030`          |
| `Drawer`, root `Menu`, `ContextMenu` | none — push and resize only                            | (no assignment)                |

Right-to-left is real but shallow: `mirrored` comes from `LayoutMirroring` on
the popup item and is consumed by the style binding and by
`QQuickMenuPositioner` (a submenu goes to the left of its parent), never by the
collision engine.

Viewport padding is the `margins` property (a scalar or per-edge), whose default
is **-1**, meaning "do not push inside the window at all"; a negative margin
also disables the resize step unless `relaxEdgeConstraint` is false. Multi-monitor
and work-area knowledge applies **only** on the popup-window path, via
`QGuiApplication::screenAt(globalCoords)->availableGeometry()`.

Safe-area insets are half-wired: `QQuickPopup` implements
`QQuickSafeAreaAttachable` with `safeAreaAttachmentItem() == popupItem`
(`qquickpopup.cpp:3596-3599`), so `SafeArea.margins` is _readable_ inside the
popup — but it is not fed into the positioner. A style must wire it manually,
and the macOS `ComboBox` does exactly that (`macos/ComboBox.qml:61`). IME and
virtual-keyboard avoidance has no engine support at all; the documented answer is
to parent an `InputPanel` into `Overlay.overlay` with a positive `z` and
hand-compute `y`.

**Algorithm.** See [`reposition()`](#reposition-flip-push-snap-resize-restore) below.
The salient detail: flip computes `newTopLeft = (parent.width - x - w, y)`,
maps it to the scene, and adopts it **only if** the flipped rect's intersection
with `bounds` is wider (or taller) than the current one — a mirror about the
anchor's box plus a "more visible area wins" acceptance test, not a side swap.

**Where the behaviour lives.** Split across three layers: the QML style owns
intent, `QQuickPopupPositioner` owns collision, each `QQuickPopup` subclass owns
the six permission bits. Screen and work-area knowledge lives in QPA
(`QScreen::availableGeometry`) and, on Wayland, entirely in the compositor —
see [`../window-system-integration/index.md`][wsi] and the sibling
[`./xdg-positioner.md`][xdg].

**Degradation.** Everything survives with no OS window: the `Item` path is the
fallback and is what runs on embedded and Android targets. Integer cells lose
nothing — the only non-integral operations in the whole path are `qRound` on
centering and `qCeil` on window sizing. With no script, none of it survives:
flip, push and resize all require measuring an implicit size against a viewport
at open time. The soft-keyboard inset must be an **input**, because Qt's engine
never discovers it either; Qt's documented answer is "the author computes it".

### 3. Collision & geometry engine

Overflow detection is a rect-versus-rect test against **one** bounds rectangle.
There is no clipping-ancestor discovery and no scroll-container awareness: the
bounds are the `QQuickOverlay`'s own size (assumed to cover the window, falling
back to the window's width/height when the overlay's geometry is not yet ready)
or, for popup windows, the screen's `availableGeometry`. A popup anchored inside
a `Flickable` will happily be placed outside the visible part of it.

Tracking is **push-based, not polled**. `setParentItem` registers the positioner
as a `QQuickItemChangeListener` on the anchor for `Geometry|Parent`, then walks
the entire ancestor chain registering `Geometry|Parent|Children`
(`qquickpopuppositioner.cpp:50-73`). Any geometry change on that chain fires
`reposition()` — but only while the popup item is visible **and**
`resolvedPopupType() == Item`. Re-entrancy is guarded by an `m_positioning`
flag: a reposition requested during positioning becomes `popupItem->polish()`,
deferred a frame (`:88-91`).

Two behaviours in the resize path are worth naming because they are easy to omit.
The engine both **shrinks** a popup to fit _and_ **restores** it to its implicit
size once it fits again (`:214-219`, `:247-252`); and after assigning the
corrective size it clears `QQuickItemPrivate::widthValidFlag` /
`heightValidFlag` so the engine's own assignment does not count as an
author-set explicit size (`:271-281`). Without the second step, one corrective
resize would freeze implicit sizing forever.

Transforms are handled by exactly one snapshot: the popup's own scale is
captured into `m_popupScale` at `setParentItem` time (`:67-70`) specifically so
a scale enter-transition cannot drag the resolved top-left around while it plays.

**Algorithm.**
`bounds := QRectF(max(0, mL), max(0, mT), overlayW - max(0, mL) - max(0, mR), overlayH - max(0, mT) - max(0, mB))`,
then flip → push → snap → resize → restore. Cost is `O(1)` arithmetic per
reposition and `O(ancestor depth)` listener registrations per open.

**Where the behaviour lives.** Library code (`QQuickPopupPositioner`) on top of
the scene graph's item-change-listener mechanism, which is framework kernel. The
popup-window arm delegates to QPA/`QScreen` and, on Wayland, to the compositor.

**Degradation.** The arithmetic generalises perfectly off its substrate: it is
six booleans, four margins and two rectangles. What does _not_ generalise is the
listener chain, which exists only because Qt retains a scene graph. _INFERENCE:
a toolkit that rebuilds its tree each frame recomputes placement from the live
anchor rect and needs neither the listeners nor the `m_positioning`/`polish`
re-entrancy guard._ With no script the entire dimension is absent. Integer cells
lose nothing.

### 4. Arrow / caret geometry

**Absent by design, and the absence is total.** No Qt Quick Controls style
(Basic, Fusion, Material, Universal, Imagine, macOS, Windows, iOS, FluentWinUI3)
draws a callout tail on a `ToolTip`, a `Menu` or any `Popup`; every "arrow" in
`src/quickcontrols` is a submenu, spinbox or scrollbar **indicator** inside a
`MenuItem` or `ComboBox`, never a popup tail. There is no arrow item, no arrow
size, no arrow offset — and, decisively, **no data path by which one could
exist**: the positioner never reports which side it resolved to, and the flip
decision is discarded the moment `rect.moveLeft` / `rect.moveTop` is called.

The nearest analogue is `Menu::overlap`, a scalar that pulls a cascading submenu
back over its parent's frame (1 in Basic and Universal, 2 in Fusion, 4 in macOS,
Windows and FluentWinUI3, and `control.width` in the iOS style). It is consumed
twice: by `QQuickMenuPositioner`, and — remarkably — by the Wayland path via
`popup()->property("overlap").toReal()` on an untyped `QObject`, inside
`QQuickPopupWindow::parentControlGeometry`, which reports an anchor rect to the
compositor deflated by the overlap and floored to at least a quarter of the
parent's width (`qquickpopupwindow.cpp:504-515`).

The one "decoration overflows the box" concept Qt does model is **negative
insets**: a style declares `leftInset: -32` so its drop shadow can overflow the
background frame, and `windowInsets()` converts exactly the negative part into
extra window size so the shadow is not clipped by the window edge
(`qquickpopup.cpp:667-707`; macOS's `Menu.qml` relies on it).

**Algorithm.** Not applicable — no arrow geometry exists. The only related
arithmetic is the submenu offset:
`submenuX = parentMenuItem.width + parentMenu.rightPadding - menu.overlap`
(mirrored: `-menu.width - parentMenu.leftPadding + menu.overlap`).

**Where the behaviour lives.** Nowhere. It would have to live in the style
layer, which has no access to the resolved side.

**Degradation.** Not applicable, but the absence is instructive. Qt pins the
negative case: if the engine never emits the resolved side as data, no styling
layer can draw a tail — and the same missing datum breaks animation origins
([dimension 14](#_14-animation)). _INFERENCE: at cell resolution the arrow reduces
to one integer index along the touching edge plus a side enum, which a solver
that returns its decision gets for free._ See
[`./features-people-forget.md`][forget] for the corner-clamp hazard that index
implies.

### 5. Trigger semantics

Triggers are **not part of the popup primitive**; each is wired by a different
owner, and `QQuickPopup` owns none of them.

| Trigger              | Owner                                                | Mechanism                                                                                  |
| -------------------- | ---------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| Programmatic         | `QQuickPopup`, `QQuickMenu`, `QQuickToolTip`         | `open()`/`close()`, `Menu::popup(…)`, `Menu::dismiss()`, `ToolTip.show/hide`               |
| Hover → tooltip      | `QQuickControl`, `QQuickTextField`, `QQuickTextArea` | `hoverChange` → `maybeSetVisibleImplicitly(this, isHovered())`, gated by `ToolTip.policy`  |
| Long-press → tooltip | `QQuickAbstractButton` only                          | the `pressAndHold` timer, and only while `touchId != -1`                                   |
| Context menu         | `QQuickContextMenu` attached type                    | a real `QEvent::ContextMenu`, so the platform's right-click / menu-key policy is inherited |
| Submenu on hover     | `QQuickMenuPrivate`                                  | `onItemHovered` → a 225 ms one-shot (`SUBMENU_DELAY`, `qquickmenu.cpp:53`)                 |
| Menu bar on hover    | `QQuickMenuBarPrivate`                               | swap the current item and reopen **only if a menu was already open** (`stayOpen`)          |

A mouse press _hides_ a hovered tooltip rather than showing one — "Tool tips on
desktop should hide when their parent item is pressed"
(`qquickabstractbutton.cpp:163-164`).

Race avoidance is done by explicit guards, not by a combinator. Each hover
handler bails on `!isHovered() || !isEnabled() || touchId != -1`;
`maybeSetVisibleImplicitly` bails if `visible` was ever set explicitly, if
`ToolTip.policy` is `Manual`, or if the text is empty; and `acceptTouch` latches
a single `touchId` and refuses every other point for the popup's lifetime
(`qquickpopup.cpp:561-572`).

**Algorithm.** Per-trigger guard-and-latch. The only real arbitration is the
touch/mouse split: a control latches `touchId` on press, and every hover-driven
path tests `touchId != -1` to suppress itself. The pointer **type** is latched
state that other triggers consult, rather than triggers being merged.

**Where the behaviour lives.** Scattered across `QQuickControl`,
`QQuickAbstractButton`, `QQuickTextField`/`QQuickTextArea`, `QQuickContextMenu` +
`QQuickItemPrivate`, and `QQuickMenuPrivate`/`QQuickMenuBarPrivate`.

**Degradation.** With no hover, the entire hover path is dead and only long
press survives — which is exactly what Qt implemented, and only for buttons.
Nothing here needs a key release; every trigger is press, hold, hover or
programmatic. With no script only tier-0 `:hover`/`:focus-within` can stand in.
No OS window is required. _INFERENCE: the `touchId` latch generalises to "the
last pointer event's device class is state the overlay machine reads", which a
single-pointer terminal can hardcode._ Compare [`../../specs/ui/input.md`][spec-input]
on what the toolkit's event vocabulary does and does not carry.

### 6. Timing

Three timers exist in the whole overlay stack, and no more.

1. **`ToolTip` delay** (`delayTimer`). `setVisible(true)` with `delay > 0` starts
   the timer and **returns without calling the base `setVisible`**, so "visible"
   is a request; the timer's expiry calls `QQuickPopup::setVisible(true)`
   (`qquicktooltip.cpp:274-289`). For attached tooltips under
   `ToolTip.policy: Automatic` the default is `QStyleHints::toolTipWakeUpDelay()`,
   cached once into a file-static; for a standalone `ToolTip` the default delay is
   0 and a **negative** delay means immediate.
2. **`ToolTip` timeout** (`timeoutTimer`), started in `QQuickToolTipPrivate::opened()`
   — that is, after the enter transition completes, so animation time is excluded
   from the display duration. The attached default is a reading-speed heuristic
   ported from `QTipLabel::restartExpireTimer` (`qquicktooltip.cpp:542`):

   ```cpp
   return 10000 + 40 * qMax(0, text.length() - 100);
   ```

   A negative timeout never auto-hides.

3. **Submenu hover-open**: 225 ms.

There is **no** warm-up, no skip-delay / instant-subsequent behaviour, no
cool-down, no group or provider, no re-entry grace, and no maximum display
duration beyond the timeout. Traversing a toolbar therefore pays the full
wake-up delay at every button, because each attachee's `show()` re-pushes its own
delay onto the shared instance. Closing the previous submenu on hover is
**immediate**; only opening is delayed.

Qt makes the automatic policy testable by exporting two injectable file-statics,
`qt_quicktooltipattachedprivate_delay` and `…_short_timeout`
(`qquicktooltip.cpp:100-114`), the second of which substitutes a 123 ms timeout
"for auto tests, to ensure that the default automatic timeout works".

**Algorithm.** The state machine this subject implies is
`{Idle, DelayPending, Shown}`: `Idle --show--> DelayPending` if `delay > 0` else
`Shown`; `DelayPending --hide--> Idle`; `DelayPending --elapsed--> Shown`;
`Shown --enter transition finished--> start timeout`;
`Shown --timeout | hide | policy dismissal--> Idle`. The two edges a better
machine needs and Qt lacks are a group-level "recently shown" clock (so a move
within the group enters `Shown` with zero delay) and a re-entry grace.

**Where the behaviour lives.** Library code on `QBasicTimer`; the defaults come
from `QStyleHints`, i.e. the platform.

**Degradation.** With no timers this dimension is entirely unavailable — Qt's
tooltip is unimplementable at tier 0, leaving only a zero-delay `:hover` label.
With no hover, the delay is replaced by the press-and-hold interval, which is a
_different_ timer owned by `AbstractButton`, while the timeout still applies.
Integer cells and key release are irrelevant. Everything here is assertable on a
recording canvas **if** the clock is injectable — Qt needed two exported globals
to achieve exactly that, which is a direct argument for making the clock a
parameter of the machine rather than a global. See
[`../../specs/ui/state-machines.md`][spec-stm].

### 7. Interactive hover

Qt's tooltip is deliberately **non-interactive** — one line in the constructor
(`qquicktooltip.cpp:193`):

```cpp
d->popupItem->setHoverEnabled(false); // QTBUG-63644
```

There is therefore no trigger-to-content travel problem for tooltips at all: the
content cannot be hovered, so no bridge, no grace area and no
[safe polygon][concepts] is needed. The cost is that WCAG 1.4.13's _hoverable_
clause cannot be satisfied ([dimension 13](#_13-accessibility)).

For menus, hover interactivity is achieved by treating the whole open cascade as
**one surface**. On the in-window path, `QQuickMenuPrivate::blockInput` returns
true for `cascade && parentMenu && contains(point)`, keeping the parent open
while the child is used (`qquickmenu.cpp:1078-1082`). On the OS-window path,
`QQuickPopupWindowPrivate::filterPopupSpecialCases` walks the
menu → parent menu → menu bar chain, finds which window the global point is over,
temporarily **clears the exclusive grabber**, and re-delivers the move event to
that window's delivery agent, so hover highlighting works across separate OS
windows — "we want all open menus and sub menus that belong together to almost
act as a single popup WRT hover event delivery"
(`qquickpopupwindow.cpp:188-208`, `:311-346`).

Absent: safe polygon or triangle, pointer trajectory or velocity heuristics,
interactive-border tolerance, debounce on leave. The diagonal-travel problem is
handled **only** by geometry — `Menu::overlap` pulls the child back over the
parent's frame so the pointer never crosses a gap — plus the 225 ms open delay,
with zero grace on close.

**Algorithm.** Cross-surface hover unification: for each pointer move over a
popup window, resolve `target :=` the first ancestor menu (or the menu bar) whose
`contains(mapFromGlobal(globalPos))` is true; if the target's window differs,
rewrite the event's scene position into that window's coordinates, null the
exclusive grabber, deliver to that delivery agent, then restore both.

**Where the behaviour lives.** Split, and written **twice** — once per surface
model: the tooltip's non-interactivity is one line in the `ToolTip` constructor;
the menu-as-one-surface rule is `QQuickMenuPrivate::blockInput` on the `Item`
path and `filterPopupSpecialCases` on the `Window` path.

**Degradation.** With no hover at all, every mechanism here is dead and menus
fall back to tap-to-open submenus via `onItemTriggered`, which already exists.
With no OS window only the `blockInput` half is needed, and it is five lines.
Sub-cell precision is unnecessary: `overlap` is already measured in whole style
pixels and reads naturally as whole cells. _INFERENCE: expressed in cells, Qt's
overlap costs one cell of re-entry margin where a corridor heuristic would cost
the full diagonal._

### 8. Dismissal

**The central finding of this subject.** Dismissal is one value, its evaluation
is one function, and Qt tests it as a truth table.

The default is `CloseOnEscape | CloseOnPressOutside` (`qquickpopup.cpp:500`).
`resetClosePolicy()` restores it _and_ clears `hasClosePolicy`, which `Menu` uses
to swap in `cascadingSubMenuClosePolicy = CloseOnEscape | CloseOnPressOutsideParent | CloseMultiple`
at enter-transition time — but only if the author never set one
(`qquickmenu.cpp:269`). Styles override it too: the Basic `ToolTip` declares
`CloseOnEscape | CloseOnPressOutsideParent | CloseOnReleaseOutsideParent`
(`basic/ToolTip.qml:23`), and `ComboBox` sets
`CloseOnEscape | CloseOnPressOutsideParent` on its popup
(`qquickcombobox.cpp:1499`).

The decision function is `tryClose(pos, phaseFlags)`: the **caller supplies the
phase as flags**, and the popup ANDs it with its own policy
(`qquickpopup.cpp:533-553`):

```cpp
const bool onOutside = closePolicy & (flags & outsideFlags);
const bool onOutsideParent = closePolicy & (flags & outsideParentFlags);

if ((onOutside && outsidePressed) || (onOutsideParent && outsideParentPressed)) {
    if (!contains(pos) && (!dimmer || dimmer->contains(dimmer->mapFromScene(pos)))) {
        if (!onOutsideParent || !parentItem || !parentItem->contains(parentItem->mapFromScene(pos))) {
            closeOrReject();
            return true;
        }
    }
}
```

> [!IMPORTANT]
> `tryClose` is not a pure function of (policy, cause, containment). It
> early-returns on the `interactive` flag, and it reads `outsidePressed` /
> `outsideParentPressed`, which are **latched at press time** by `handlePress`
> and cleared by `handleRelease` (`:591-626`). That latch is exactly why "press
> inside, release outside" never dismisses — asserted directly in
> `tst_QQuickPopup::closePolicy` (`tst_qquickpopup.cpp:742-746`).

Everything not in the value is hardcoded, and the omissions are as informative
as the flags:

| Cause                 | Behaviour                                                                                        |
| --------------------- | ------------------------------------------------------------------------------------------------ |
| Escape                | in `keyPressEvent`, gated on `hasActiveFocus()`; on Android `Qt::Key_Back` matches the same flag |
| Focus-out             | never closes                                                                                     |
| Scroll                | never closes (a modal popup merely accepts the wheel event)                                      |
| Anchor hidden/removed | never closes — `itemDestroyed` only nulls `parentItem`                                           |
| Window deactivation   | no effect on the `Item` path; on the `Window` path `hideEvent()` closes (or rejects a `Dialog`)  |
| Parent closing        | `prepareExitTransition` walks `currentSubMenu()` down; `Menu::dismiss()` walks `parentMenu` up   |
| Child opening         | does not close the parent when cascading                                                         |

A documented limitation is retained in the source: `CloseOnReleaseOutside` and
`CloseOnReleaseOutsideParent` "only work with modal popups" — a known bug living
inside the abstraction rather than being fixed. (I did not trace the non-modal
delivery path that makes it true.)

The **cascade** over the stack is where `CloseMultiple` and its two companion
predicates live (`qquickoverlay.cpp:184-212`, `:618-724`):

- `canCascadeCloseOnOutsidePress(popup)` — a popup whose policy contains none of
  the four outside flags (a tooltip, or `NoAutoClose`) is skipped entirely: it
  neither closes nor stops the walk. The comment names the exact failure:
  otherwise "a non-modal, non-closing popup sitting above a modal one (e.g. a
  tooltip) would wrongly prevent the modal popup below from being asked to block
  the event."
- `closedItselfViaCloseMultiple(popup, wasOpened)` — a popup that just closed can
  no longer block, so the walk continues. Detected via `isOpened()` rather than
  `isVisible()`, and the comment says why: "`isVisible()` doesn't flip to false
  until the exit transition finishes, so we check `isOpened()` instead".
- `closeCascadeStopped` — an overlay-wide latch, reset at the top of every new
  press/release/touch, which guarantees one cascade per physical event even
  though Qt's delivery agent retries that event against several sibling popup
  items.
- A compensating replay: when a modal dimmer eats a press without closing, the
  popups **below** it never latch `outsidePressed`, so `childMouseEventFilter`
  synthesises `handlePress()` for each of them, stopping at the first one lacking
  `CloseMultiple`.

**Algorithm.**
`close := interactive ∧ ((policy ∩ phase ∩ Outside ≠ ∅ ∧ pressedOutside) ∨ (policy ∩ phase ∩ OutsideParent ≠ ∅ ∧ pressedOutsideParent)) ∧ ¬self.contains(p) ∧ (scrim = null ∨ scrim.contains(p)) ∧ (¬outsideParentCase ∨ anchor = null ∨ ¬anchor.contains(p))`.
Cascade: walk the stack front-to-back; one flag per popup decides whether the
walk continues.

**Where the behaviour lives.** The value and its evaluation are in the popup.
The _stack_ semantics — who is asked, in what order, and when the cascade stops
— live in `QQuickOverlay` for the `Item` path and are **duplicated** in
`QQuickPopupWindowPrivate::filterPopupSpecialCases` for the `Window` path, where
the same cascade is a while-loop climbing `transientParent` windows. The
`CloseMultiple` test data deliberately cross-products
`{Item, Window} × {modal, non-modal}`.

**Degradation.** Every flag except the release pair survives a target with no key
release, since press-outside and Escape are key-down and pointer-down events. No
OS window is needed — the `Item` path is the whole story and the better-tested
one. With no script only "click elsewhere" via a `:checked` or `<details>` toggle
survives, i.e. approximately `CloseOnPressOutside` and nothing else. Android's
system Back is already folded into `CloseOnEscape` by Qt: one flag, two physical
inputs. Sub-cell precision is irrelevant — every test is rect containment.

### 9. Focus

`focus` is an **opt-in bool on the popup, not derived from its kind**: `Menu` and
`Drawer` call `setFocus(true)` in their constructors; `ToolTip` and a plain
`Popup` do not. When it is true, `prepareEnterTransition` calls
`popupItem->setFocus(true, Qt::PopupFocusReason)` and `prepareExitTransition`
clears it.

Containment is a **fence, not a trap**: `QQuickPopupItemPrivate` sets
`isTabFence = true` in its constructor (`qquickpopupitem.cpp:25`), so Tab and
Backtab cycle _inside_ the popup via `QQuickItemPrivate::focusNextPrev`
(`qquickpopup.cpp:3255-3258`); `Drawer` additionally keeps `isTabFence` in sync
with `modal`.

Restoration is the elaborate part, and it is owned by the **overlay**, not the
popup: `QQuickOverlayPrivate` holds `lastActiveFocusItem` and
`lastActiveFocusItemPopup`, recorded at the first popup's enter
(`qquickoverlay_p_p.h:72-74`). On exit, `finalizeExitTransition`
(`qquickpopup.cpp:859-920`):

1. does nothing unless `hadActiveFocusBeforeExitTransition` — snapshotted
   **before** `setFocus(false)`, because clearing focus would otherwise destroy
   the evidence;
2. looks for another still-open popup that `hasFocus()` but not
   `hasActiveFocus()` and forwards focus there;
3. otherwise restores `overlay->lastActiveFocusItem` via `forceActiveFocus`;
4. otherwise hands focus back to the (`ApplicationWindow`) content item;

and it separately re-points `lastActiveFocusItem` at another popup's saved item
so a stack unwinding out of order still lands correctly.

There is no pointer-opened versus keyboard-opened distinction in the popup —
`Qt::PopupFocusReason` is used uniformly; only `Menu` distinguishes, by leaving
`currentIndex` at -1 unless `popup(menuItem)` named one. Roles stay distinct by
construction: a tooltip never focuses and is explicitly skipped by the shortcut
blocker; a menu focuses and therefore steals shortcuts; a dialog is a focusing
popup with accept/reject.

**Algorithm (exit).**
`if !hadActiveFocus → done`. Else
`nextFocusPopup := first p in stackingOrderPopups where p.transitionState ≠ Exit ∧ p.hasFocus ∧ ¬p.hasActiveFocus`;
if found, `p.forceActiveFocus(PopupFocusReason)`; else if the content item has no
scoped focus item and `overlay.lastActiveFocusItem` is alive,
`lastActiveFocusItem.forceActiveFocus(Other)`; else
`contentItem.setFocus(true, PopupFocusReason)`.

**Where the behaviour lives.** Library, split between `QQuickPopupPrivate`
(per popup) and `QQuickOverlayPrivate` (per-window restoration memory), leaning
on the Qt Quick focus-scope machinery (`isTabFence`, `scopedFocusItem`,
`clearFocusInScope`), which is framework kernel.

**Degradation.** No OS window: unchanged, this is all in-scene. No key release:
unchanged, Tab is handled on press. No hover: unchanged. Static HTML: only
`:focus-within`, and no restoration. _INFERENCE: the reusable kernel is small and
value-shaped — "the overlay stack remembers one pre-overlay focus target plus
which overlay saved it", and closing an overlay hands focus to the topmost
still-open focusing overlay or back to that target. That survives a
value-semantics port; only `forceActiveFocus`'s re-entrancy does not._

### 10. Layering & portals

The "[top layer][concepts]" is an ordinary item. `QQuickOverlay` is created
lazily as a child of `window->contentItem()`, cached in a dynamic property
`_q_QQuickOverlay` on the window, and sets exactly one thing in its constructor
(`qquickoverlay.cpp:414`):

```cpp
setZ(1000001); // DefaultWindowDecoration+1
```

The "portal" is one line: `popupItem->setParentItem(overlay)`. A per-subtree
variant exists behind `QQuickItemPrivate::customOverlayRequested`, walking up
from the popup's parent.

Ordering is paint order plus two rules (`qquickpopup.cpp:1207-1273`): when
opening a popup whose `QObject` parent chain contains the current top popup,
`popupItem->stackAfter(topPopupItem)` and, if the author gave no explicit `z`,
`setZ(max(topZ, myZ))`. The ordered query is derived by **reverse paint order
mapped back through ownership** (`qquickoverlay.cpp:44-58`):

```cpp
for (auto it = children.crbegin(), end = children.crend(); it != end; ++it) {
    QQuickPopup *popup = qobject_cast<QQuickPopup *>((*it)->parent());
    if (popup)
        popups += popup;
}
```

That derivation is the source of two documented special cases: a drop-shadow
`QQuickShaderEffectSource` child of the overlay is not a popup and must be
resolved back to its popup item in `eatEventIfBlockedByModal`; and an
asynchronously-loaded popup with a null window needed its own guard.

The dimmer is a sibling stacked immediately **before** the popup item, with
`z = popup->z()`. Public API is `Overlay.overlay` (attached), the
`Overlay.modal` / `Overlay.modeless` components, `Overlay.pressed`/`released`,
and `Popup::z`; `_q_QQuickOverlay`, `_q_dimmerItem`, `stackingOrderPopups`,
`mouseGrabberPopup`, `closeCascadeStopped` and `QQuickPopupItem` itself are
implementation detail.

The alternative layer is a real OS child window: `QQuickPopupWindow`, transient
parent set to the main window, flags
`Qt::Popup | FramelessWindowHint | NoDropShadowWindowHint`, a transparent clear
colour, and per-kind hints pushed to the platform — Wayland
`extendedWindowType ∈ {Default, ToolTip, Menu, ComboBox}` and XCB
`_NET_WM_WINDOW_TYPE ∈ {Tooltip, PopupMenu, Combo}` (`qquickpopup_p_p.h:211-219`).

**Algorithm.** `openOverlayPopup(p)`: `overlay := lazyOverlayFor(window, p.anchor)`;
`p.item.parent := overlay`; if the top popup is an ancestor of `p` in the
`QObject` tree, `p.item.stackAfter(topPopup.item)`; if `p` has no explicit `z`,
`p.item.z := max(topPopup.item.z, p.item.z)`. The ordering query is reverse paint
order filtered by "this child's `QObject` parent is a `QQuickPopup`".

**Where the behaviour lives.** Library (`QQuickOverlay`) for the in-window layer;
QPA and the compositor for the OS-window layer.

**Degradation.** This is the dimension where a single-surface toolkit diverges
least in spirit: Qt's in-window layer already _is_ "one surface, later in paint
order wins", and it is the fallback wherever multiple windows are unavailable.
What should **not** be copied is the ordering derivation — reconstructing the
stack by casting paint-order children's `QObject` parents is an artefact of the
item tree and produced two documented bugs. _INFERENCE: a flat, explicitly
ordered overlay list keyed by handle carries the same information without either
bug._ Compare [`../../specs/ui/containers.md`][spec-containers] on how the
toolkit's existing precedence is expressed.

### 11. Modality

Three orthogonal knobs, not one enum:

- `modal` (bool);
- `dim` (bool) — follows `modal` unless explicitly set: `setModal` calls
  `setDim(modal)` and then restores `hasDim = false`, so the coupling survives
  (`qquickpopup.cpp:2515-2530`);
- `setWindowModality(Qt::WindowModality)` — takes effect **only** on the
  popup-window path.

Blocking is a **predicate over the hit target**, not a property of a layer
(`qquickpopup.cpp:575-589`; the modal term at `:588`):

```cpp
return modal && ((popupItem != item) && !popupItem->isAncestorOf(item))
    && (!dimmer || dimmer->contains(dimmer->mapFromScene(point)));
```

Because Qt's delivery agent does not route wheel, tablet or drag-and-drop through
the same path, modality had to be re-implemented per event category, in
`QQuickOverlayPrivate::eatEventIfBlockedByModal` and in `QQuickPopup::overlayEvent`
— the latter accepting `KeyPress`/`KeyRelease`/`MouseMove`/`Wheel`/`Tablet` for
modal popups while _ignoring_ drag events so the OS renders the not-allowed
cursor rather than accepting too late (`qquickpopup.cpp:3321-3360`). Each of
those was a separate bug fix.

**Light dismiss is not a modality mode here** — it is the `ClosePolicy` value.

Passthrough is real and unusually well pinned. A `QQuickItem` `containmentMask`
on the dimmer punches genuine holes in the scrim, which is how QtVirtualKeyboard
stays usable above a modal dialog; the popup publishes its dimmer as
`_q_dimmerItem` on the overlay specifically so external code can install the
mask (`qquickpopup.cpp:1276-1317`). Crucially the hole suppresses **both**
blocking (`blockInput`'s `dimmer->contains` term) **and** auto-close (the same
term inside `tryClose`, `:545`), and `tst_QQuickPopup::dimmerContainmentMask`
asserts exactly that conjunction: a click in the hole increments the click count
_and_ leaves `modalPopup->isOpened()` true, while one pixel outside does neither.

> [!NOTE]
> Coupling those two suppressions is a policy choice for _this_ kind of hole —
> one cut to keep foreign chrome usable under a modal. It is not a universal
> rule: a hole cut over the overlay's own trigger may legitimately pass the
> click through _and_ dismiss. [`./base-ui.md`][base-ui] is the counterexample;
> [`./comparison.md`][comparison] carries the cross-subject reading.

The scrim itself is a fully styleable `QQmlComponent` (`Overlay.modal` /
`Overlay.modeless`, attached per popup or set globally), faded in and out by
writing `opacity` through `QQmlProperty` so QML `Behavior`s run; when no
component is available and `modal` is true, a bare `QQuickItem` is used purely to
eat hover. The accessibility modal bit is not set anywhere
([dimension 13](#_13-accessibility)).

**Algorithm.** `blockInput` as above; for event categories outside the normal
path, walk `stackingOrderPopups` front-to-back, find the popup item containing
the hit target, and if a modal popup is met first, accept (or, for
drag-and-drop, ignore) and swallow.

**Where the behaviour lives.** Library, spread over
`QQuickPopupPrivate::blockInput`, `QQuickPopup::overlayEvent`,
`QQuickOverlayPrivate::eatEventIfBlockedByModal` and
`QQuickOverlay::eventFilter`; the window-modal arm delegates to `QWindow`/QPA.

**Degradation.** With one surface and no [grab][concepts], modality reduces to
exactly Qt's `Item`-path predicate — "is the hit point inside the topmost modal
overlay's rect, or inside its scrim rect?" — a pure function of the hit list
needing no OS support. Qt's scrim-with-holes also shows the general shape:
_INFERENCE: a scrim is better modelled as a paintable rect list than as a
boolean, so an inset (soft keyboard, docked panel) can be excluded._ Key release
is irrelevant. Static HTML cannot express modality beyond a full-page `:checked`
overlay.

### 12. Adaptive presentation

The adaptation Qt implements is **surface** adaptation, decided by a virtual on
the private class and evaluated just before showing. The base
(`qquickpopup.cpp:1183-1200`):

```cpp
// PopupType::Native is not directly supported by QQuickPopup (only by subclasses).
// So for that case, we fall back to use PopupType::Window, if supported.
if (popupType == QQuickPopup::PopupType::Window
    || popupType == QQuickPopup::PopupType::Native) {
    if (QGuiApplicationPrivate::platformIntegration()->hasCapability(QPlatformIntegration::Capability::MultipleWindows))
        return QQuickPopup::PopupType::Window;
}

return QQuickPopup::PopupType::Item;
```

`popupType` is therefore a **preference, not a fact**, and the universal
fallback is the in-window `Item` path. `QQuickMenuPrivate::resolvedPopupType()`
overrides it (`qquickmenu.cpp:319-364`) so that a menu inside a native menu bar
is forced `Native`, the **root** menu decides for every submenu, and `Native` is
only claimed when `AA_DontUseNativeMenuWindows` is unset — with an honest caveat
in the comment that QPA can still refuse, so `nativeHandle()` must be checked
too. `QQuickDrawerPrivate::resolvedPopupType()` hard-returns `Item` ("For now, a
drawer will always be shown in-scene").

> [!WARNING]
> The behavioural cliff behind that enum is large and documented: a native menu
> drops most of the `Menu` API, does not use the QML delegate (though it still
> instantiates it, hidden, so `onCompleted` runs), and `open()` may **block**
> until the menu closes on some platforms. `QQuickPopup::clip()` also silently
> changes meaning — it returns `popupItem->clip() && !usePopupWindow()`.

Menu cascade adapts on the same axis: `shouldCascade()` returns whether the
platform has `MultipleWindows` (and requires `QT_CONFIG(cursor)`), and a
non-cascading `Menu` **centres** the submenu over its parent and closes the
parent — a genuinely different presentation of the same declaration.

The hover-tooltip to long-press-tooltip adaptation is a second axis, but it is
not owned by the popup: `QQuickAbstractButton`'s press-and-hold path shows the
shared tooltip on touch, `QQuickControl::hoverChange` shows it on hover, and
`maybeSetVisibleImplicitly` is the single funnel with a `policy` opt-out. There
is no popover-to-sheet compaction, no teaching-tip type, and no keyboard-driven
relocation.

**Algorithm.** `resolvedPopupType()`: if inside a native menu bar → `Native`;
else if the root menu already has a native handle → `Native`; else if
`!triedNative ∧ root.popupType == Native ∧ !AA_DontUseNativeMenuWindows` →
`Native`; else the base rule above.

**Where the behaviour lives.** A virtual in the private class (library) reading
`QPlatformIntegration` capabilities and `QGuiApplication` attributes (platform),
overridden per subclass.

**Degradation.** With exactly one surface the `Window`/`Native` branch collapses
and only the `Item` branch — the universally-supported fallback Qt tests hardest
— remains. The transferable idea is the **shape**: a single
`resolve(preference, capabilities) → surface` function evaluated at open time,
overridable per widget kind, with the resolution readable afterwards. _INFERENCE:
the same shape resolves "hover tooltip vs long-press tooltip vs always-visible
hint" from a capability record, and being a pure function of that record is what
makes each branch assertable on a recording canvas._ See
[`../../specs/ui/backends.md`][spec-backends].

### 13. Accessibility

The primitive exposes exactly three things.

1. **A role.** `QQuickPopup::accessibleRole()` returns `QAccessible::Dialog`
   (`qquickpopup.cpp:3555-3558`); `QQuickToolTip` overrides to
   `QAccessible::ToolTip` and `QQuickMenu` to `QAccessible::PopupMenu`.
   `effectiveAccessibleRole()` (`:3542-3553`) lets an `Accessible.role` attached
   property override it, and `QQuickPopupItem::accessibleRole()` forwards to the
   popup's, so the item that appears in the accessibility tree carries the
   popup's role.
2. **Lifecycle events.** `opened()` emits `QAccessible::PopupMenuStart` or
   `DialogStart` on the popup item; `finalizeExitTransition` emits
   `PopupMenuEnd`/`DialogEnd`, chosen by role.
3. **A name.** `maybeSetAccessibleName`, which `ToolTip::setText` calls with the
   tip text and re-applies in `accessibilityActiveChanged` when the assistive
   technology comes online. `QQuickPopupItem::accessibilityActiveChanged`
   carefully copies an `Accessible.name` set on the `Popup` down to the popup
   item, because they are separate attached objects.

> [!IMPORTANT]
> This is a case where the positioning primitive _does_ carry an accessibility
> role: `QQuickPopup`, the class that owns `x`/`y`/`margins` and drives the
> positioner, hard-codes `QAccessible::Dialog`, and `QQuickPopupItem` publishes
> it to the bridge. That is a property of a retained, object-oriented toolkit
> whose overlay base class is itself a control type — see
> [`./comparison.md`][comparison] for how differently the headless libraries
> divide this.

What is missing is relational. The popup is never advertised as the
**description of its anchor** — there is no `aria-describedby` analogue, so a
screen reader on a hovered button learns nothing from an attached `ToolTip`. No
modal bit is set for assistive technology, even for modal popups. Nothing
addresses WCAG 1.4.13: Qt goes the other way and makes tooltip content
explicitly non-hoverable, so _hoverable_ cannot be satisfied at all, while
_dismissible_ is satisfied only because the default tooltip policy includes
`CloseOnEscape`. The automatic timeout applies regardless of whether an
assistive technology is active. Menu items get their semantics from being real
`Control`s in the tree, not from the popup.

One adjacent mechanism deserves naming because it is easy to get backwards.
Global shortcut matching is blocked by the **first** popup in stacking order
that is modal or carries `CloseOnEscape` — and tooltips are explicitly skipped
(`qquickshortcutcontext.cpp:25-51`): `if (qobject_cast<QQuickToolTip *>(popup)) continue; // ignore tooltips (QTBUG-60492)`.
Without that skip, a visible tooltip silently disables every application
shortcut.

**Algorithm.** Not applicable — the contribution is a role constant, two
lifecycle event emissions, and a name pass-through.

**Where the behaviour lives.** Library (`QQuickPopup`/`QQuickPopupItem`),
delegating to Qt's `QAccessible` bridge, which maps onto UIA, AT-SPI,
NSAccessibility and Android's `AccessibilityNodeInfo`.

**Degradation.** A terminal grid can honestly expose the same three things — the
fact that an overlay opened or closed, its role word, and its text — which is a
useful floor. It cannot expose a real accessibility tree, focus containment as a
modal bit, or a `describedby` relation. The division Qt draws is worth copying:
role, open/close events and name live in the primitive; everything relational
lives in the semantic component. But Qt's omission of the anchor-to-overlay
relation is a real defect, and a toolkit that already holds
`(anchorId, overlayId)` as a value has nothing to invent. Compare
[`./aria-apg.md`][apg].

### 14. Animation

Enter and exit are full `QQuickTransition` objects on the popup (`enter`,
`exit`), driven by a `QQuickPopupTransitionManager` over three states
`{NoTransition, EnterTransition, ExitTransition}`; starting an enter while
exiting cancels the exit (`qquickpopup.cpp:1412-1448`).

Ordering is load-bearing and was covered above: `reposition()`, `openedChanged`,
`opened()` and the tooltip's timeout clock all happen in
`finalizeEnterTransition`, i.e. **after** the animation; and `isOpened()` flips
false the instant the exit begins while `isVisible()` stays true until it ends.

Because a transition may animate opacity or scale, the popup snapshots
`prevScale`/`prevOpacity` in `prepareExitTransition` and restores them in
`finalizeExitTransition`, so styles can animate those properties "without losing
any explicitly defined value"; the positioner separately snapshots
`m_popupScale` at parenting time so a scale animation cannot make the resolved
top-left appear to jump.

`Popup::transformOrigin` is exposed — nine values kept in sync with
`Item.TransformOrigin` — **but it is not placement-aware**. Material's `Menu`
binds it from author intent and mirroring only (`material/Menu.qml:22`):

```qml
transformOrigin: !cascade ? Item.Top : (mirrored ? Item.TopRight : Item.TopLeft)
```

_INFERENCE: since a cascading `Menu` is precisely the case where
`allowHorizontalFlip` is enabled, and the positioner discards the fact that it
flipped, this binding cannot reflect a flip — so after a horizontal flip the
enter animation appears to originate from the corner the author declared rather
than the one the menu ended up at._ No geometry metadata is emitted for
animation at all: the resolved side, whether a flip occurred, and the
anchor-relative offset are all discarded inside `reposition()`. Nothing in the
popup stack consults a reduced-motion preference.

**Algorithm.**
`transitionEnter`: cancel any exit → `prepareEnterTransition` (parent to overlay,
create/show dimmer, `aboutToShow`, set focus) → run the transition →
`finalizeEnterTransition` (reposition, `openedChanged`, `opened`, a11y Start).
`transitionExit`: `prepareExitTransition` (snapshot scale/opacity, snapshot
`hadActiveFocus`, clear focus, hide dimmer, `aboutToHide`, `openedChanged`) →
run → `finalizeExitTransition` (unparent, destroy dimmer, restore focus,
`visibleChanged`, `closed`, a11y End, restore scale/opacity).

**Where the behaviour lives.** Library (`QQuickPopupTransitionManager` over
`QQuickTransitionManager`); the animations themselves are authored per style in
QML.

**Degradation.** With no script, only CSS transitions on `:hover` survive and
none of this state machine does. On a cell grid there is no scale or opacity, so
the mechanism reduces to the **state machine** — and that is the valuable half,
because the opened-versus-visible distinction and the
`aboutToShow`/`aboutToHide`/`opened`/`closed` ordering are exactly what a
recording canvas asserts. The defect (origin not derived from the resolved
placement) is free to avoid in a toolkit whose solver returns the side as data.

### 15. State architecture

An imperative controller with hand-rolled state — not a reducer, and not a
declared FSM for anything except transitions. The one explicit enum is
`TransitionState { NoTransition, EnterTransition, ExitTransition }`
(`qquickpopup_p_p.h:146`, field at `:191`), and it does gate the whole
open/close lifecycle: `open()` and `close()` consult and redirect on it, and
`isOpened()` is defined in terms of it.

Everything else is a field on `QQuickPopupPrivate` (`qquickpopup_p_p.h:146-219`),
and the field list is the honest picture: roughly two dozen booleans (`focus`,
`modal`, `dim`, `hasDim`, `visible`, `complete`, `positioning`, `hasWidth`,
`hasHeight`, the four `has*Margin`s, `hasZ`, the six `allow*` permission bits,
`hadActiveFocusBeforeExitTransition`, `interactive`, `hasClosePolicy`,
`outsidePressed`, `outsideParentPressed`, `inDestructor`, `relaxEdgeConstraint`,
`popupWindowDirty`), plus `touchId`, `x`/`y`/`effectivePos`, `pressPoint`,
`closePolicy`, and pointers.

Controlled versus uncontrolled is expressed by paired `has*`/value fields with
`reset*()` methods — `hasWidth`, `hasClosePolicy`, `hasDim`, and the tooltip's
`explicitVisible`/`explicitDelay`/`explicitTimeout`. That is a genuinely
value-friendly idiom: "explicitly set" is a bit sitting next to the value, so a
default can be recomputed without losing author intent, and no heap-allocated
optional is required.

Two pieces of state are **not** per-popup, and they are precisely the ones that
would bite a value-semantics port:

- `QQuickOverlayPrivate::{mouseGrabberPopup, lastActiveFocusItem, lastActiveFocusItemPopup, closeCascadeStopped}`
  — per-window overlay state;
- `s_popupGrabOk` and `s_grabbedWindow` (`qquickpopupwindow.cpp:31-32`) —
  file-scope, process-global grab bookkeeping.

Extension is by virtual override on the private class —
`resolvedPopupType`, `blockInput`, `handlePress`/`Move`/`Release`,
`prepare`/`finalize` transitions, `getPositioner`,
`showDimmer`/`hideDimmer`/`resizeDimmer` — i.e. the shell-with-hooks pattern
that [`../../guidelines/design-by-introspection-01-guidelines.md`][dbi] names
for D.

**Algorithm.** Not applicable — the architecture _is_ the finding.

**Where the behaviour lives.** `QQuickPopupPrivate` (per popup),
`QQuickOverlayPrivate` (per window), file statics (per process).

**Degradation.** The per-popup half survives a non-DOM, allocation-free,
value-semantics port almost verbatim: `closePolicy` is already a flags value,
the placement permissions are six bits, the latches (`outsidePressed`,
`outsideParentPressed`, `touchId`, `transitionState`) are a handful of bytes,
and the `has*`/value pairs are exactly how "explicit versus default" is modelled
without heap optionals. The per-window half survives if hoisted into an explicit
overlay-stack value. The process statics do not, and they exist only to talk to
the window system. _INFERENCE: the largest single simplification available is
that `closeCascadeStopped` exists purely because Qt's delivery agent retries one
physical event against several sibling items; routing each event once against a
flat hit list deletes that bit and the compensating press-replay with it._

### 16. Shared infrastructure

`QQuickPopup` is one base that `Dialog`, `Drawer`, `Menu`, `ToolTip`,
`ComboBox`'s popup and `SearchField`'s popup all use — and the factoring shows
precisely which parts genuinely belong together.

**Truly shared, and it works:** the lifecycle (`open`/`close`/`visible`/`opened`
plus `aboutToShow`/`aboutToHide`/`opened`/`closed`), the transition manager, the
`ClosePolicy` value and `tryClose`, `blockInput`/modality/dimmer, overlay
parenting and stacking, the positioner with its six permission bits,
margins/padding/insets, palette/font/locale propagation, and the a11y role hook.

**Not actually shared, and re-derived per subclass:** focus (`Menu`/`Drawer` opt
in; `ToolTip` and plain `Popup` do not), the flip permissions (see the table in
[dimension 2](#_2-placement-model)), `relaxEdgeConstraint`, the surface decision
(three different `resolvedPopupType` overrides), the placement itself (`Menu` and
`Drawer` each subclass the positioner), and the window-type hints.

The `relaxEdgeConstraint` case is the cautionary tale (`qquickpopup.cpp:1450-1457`):

```cpp
QQuickPopup::QQuickPopup(QObject *parent)
    : QObject(*(new QQuickPopupPrivate), parent)
{
    Q_D(QQuickPopup);
    d->init();
    // By default, allow popup to move beyond window edges
    d->relaxEdgeConstraint = true;
}
```

The protected `QQuickPopup(QQuickPopupPrivate &, QObject *)` used by **every**
subclass does not set it. A behavioural default therefore differs between a
`Popup` and a `Dialog`/`Menu`/`ToolTip` purely because of which constructor ran
— the concrete argument for passing placement settings as an explicit value
rather than mutating fields in constructors.

**What merely looks common but must stay apart**, on this codebase's own
evidence:

| Concern                      | Where it actually lives                                             | Why it is not shared                                               |
| ---------------------------- | ------------------------------------------------------------------- | ------------------------------------------------------------------ |
| Timing (delay/timeout)       | `QQuickToolTip`                                                     | Only the tooltip has one                                           |
| Shared-singleton arbitration | `QQuickToolTipAttached`, keyed on the `QQmlEngine`                  | Only the tooltip has one, and the key is the engine, not the class |
| Hierarchy / cascade          | `QQuickMenu` (`parentMenu`, `currentSubMenu`, `dismiss`, `cascade`) | `Popup` knows nothing about children                               |
| Drag                         | `QQuickDrawer` + `QQuickDrawerPositioner`                           | Edge/position/velocity has no analogue in any other popup          |
| Content semantics            | `QQuickMenu` (`contentModel`, `currentIndex`, mnemonics)            | These are `Container` concerns, not overlay concerns               |

**Algorithm.** Not applicable — the factoring is the finding.

**Where the behaviour lives.** One base class (`QQuickPopup` +
`QQuickPopupPrivate` + `QQuickPopupItem` + `QQuickPopupPositioner`) plus five
subclasses; the shared surface layer is `QQuickOverlay`; the shared window layer
is `QQuickPopupWindow`.

**Degradation.** The split is target-independent, and it is the most directly
reusable conclusion of this subject: **one** anchored-overlay primitive owning
`{anchor, offset, placement permissions, viewport margins, dismissal policy
value, modality + scrim, layer membership + stack order, lifecycle state
machine, role + name}`, and **not** owning `{timing, singleton arbitration,
hierarchy/cascade, drag, content model, focus opt-in}`. See
[`./sparkles-baseline.md`][baseline] and [`./proposal.md`][proposal] for how
that maps onto the toolkit's existing seams
([`../../specs/ui/index.md`][spec-ui], [`../../specs/ui/widgets.md`][spec-widgets]).

---

## Named algorithms

### `reposition()`: flip, push, snap, resize, restore

Given a requested `(x, y)` in `parentItem` coordinates, a popup size `(w, h)` and
an implicit size `(iw, ih)` (`qquickpopuppositioner.cpp:75-286`):

```text
 1. rect := (allowHorizontalMove ? p->x : popupItem->x(),
             allowVerticalMove   ? p->y : popupItem->y(),
             !hasWidth  && iw > 0 ? iw : w,
             !hasHeight && ih > 0 ? ih : h)
 2. if anchors.centerIn: move rect's CENTRE to the rounded centre of the parent
    (or of the overlay, in which case relaxEdgeConstraint is forced off).
    Only the immediate parent or Overlay.overlay is legal; anything else warns
    and ABORTS repositioning, leaving stale geometry.
 3. else rect.moveTopLeft(parentItem->mapToItem(overlay, rect.topLeft()))
 4. bounds := overlay rect deflated by max(0, margin) per side
    (fall back to window w/h if the overlay's size is not yet valid)
 5. HORIZONTAL FLIP  (only if allowHorizontalFlip and rect exits bounds):
        newTopLeft := (parentItem->width() - p->x - rect.width(), p->y)
        flipped    := map(newTopLeft) with rect.size()
        adopt flipped.left() iff  width(flipped ∩ bounds) > width(rect ∩ bounds)
 6. VERTICAL FLIP    -- identical, on height
 7. PUSH  (shift): top uses margins.top(); bottom uses bounds.bottom()
 8. SNAP  (last resort): if it fits at bounds.left() snap there, else bounds.right()
 9. RESIZE: setLeft(bounds.left()) / setRight(bounds.right()), mark widthAdjusted
    -- guarded by (margins >= 0 || !relaxEdgeConstraint)
10. RESTORE: else if it now fits and iw != w, restore rect width to iw
11. COMMIT: popupItem->setPosition(rect.topLeft());
            effectivePos := windowPos + windowInsetsTopLeft();
            if adjusted, setWidth/Height then CLEAR widthValidFlag/heightValidFlag
```

**Portability.** Fully portable: pure rectangle arithmetic over one bounds rect,
one anchor-parent rect, six booleans and four margins. No DOM, no compositor, no
scroll-container discovery, no transform beyond one `mapToItem`. It reproduces
exactly in integer cells — the only real-valued operations are `qRound` on
centering and `qCeil` on window sizing.

> [!WARNING]
> Step 7 is asymmetric: the top edge is pushed to `margins.top()` (an absolute
> coordinate assumed equal to `bounds.top()`) while the bottom edge is pushed to
> `bounds.bottom()`. The two agree only when the bounds origin is the margin.

### `repositionPopupWindow()`: fitting against a screen

A separate, simpler algorithm used when `resolvedPopupType() == Window`
(`qquickpopuppositioner.cpp:288-370`). `windowPos = requestedPos - windowInsetsTopLeft`,
so the background frame — not the window — lands at the requested point. **On
Wayland it returns immediately**: the compositor does server-side repositioning
and Qt attempts no fitting. Otherwise `bounds` is
`QGuiApplication::screenAt(globalCoords)->availableGeometry()` (falling back to
the primary screen), and flip is _not_ the mirror-about-parent used in-window —
it subtracts the requested offset and the width and re-adds the parent popup's
`overlap` and `leftPadding`, a menu-cascade-specific formula read off the popup
via `property("overlap")` on an untyped `QObject`.

**Portability.** The portable idea is the bounds swap: the same declaration is
fitted against a _different_ rectangle depending on the surface it lives on. The
overlap/padding term is menu-specific leakage and should not be copied.

### `tryClose(pos, flags)`: the whole dismissal decision

Covered in [dimension 8](#_8-dismissal). Restated as one expression:

```text
close  ⇔  interactive
       ∧ ((policy ∩ flags ∩ Outside       ≠ ∅ ∧ outsidePressed)
       ∨  (policy ∩ flags ∩ OutsideParent ≠ ∅ ∧ outsideParentPressed))
       ∧ ¬self.contains(pos)
       ∧ (dimmer = null ∨ dimmer.contains(pos))
       ∧ (¬outsideParentCase ∨ anchor = null ∨ ¬anchor.contains(pos))
```

**Portability.** Directly portable, and the strongest single piece of evidence in
this subject that a dismissal policy can be one comparable value: policy flags
ANDed with phase flags, three rect containment tests, and two latched booleans.
No DOM, no focus tree, no window.

### Cascading submenu placement + hover-open

`QQuickMenuPositioner::reposition()` runs **before** the generic algorithm and
computes only the pre-flip anchor position (`qquickmenu.cpp:994-1020`):

```text
mirrored:  x = -menu.width - parentMenu.leftPadding  + menu.overlap
normal:    x =  parentMenuItem.width + parentMenu.rightPadding - menu.overlap
           y = -menu.topPadding      -- align the submenu's first row with the hovered row
```

The parent item of a cascading submenu is the `MenuItem` itself, so the generic
anchor-to-scene mapping does the rest. A non-cascading submenu instead centres
over the parent menu and closes it. `allowHorizontalFlip` is enabled only for
`cascade && parentMenu`: a root menu never flips horizontally, and **no** menu
ever flips vertically.

Hover-open: `onItemHovered` sets the current index and, if the newly current item
has a cascading submenu, starts a 225 ms one-shot; the previously current item's
submenu is closed **immediately**, with no grace period. There is no safe
polygon, no trajectory test and no diagonal-intent tolerance anywhere in the tree.

### Shared-singleton attached `ToolTip`

`ToolTip.text`/`delay`/`timeout`/`policy` live per attachee on a
`QQuickToolTipAttached` (an attached-property propagator, so `policy` inherits
down the item tree). The **visual** is one instance per `QQmlEngine`, stored as a
dynamic property `_q_shared_QQuickToolTip` on the engine and created lazily
(`qquicktooltip.cpp:373-398`). `show()` re-parents that single instance to the
attachee, resets its size, pushes the attachee's delay and timeout, then opens
it. `hide()` closes it **only if** the caller is still the instance's
`parentItem`, so a control whose tooltip was already superseded cannot yank the
visible one away.

**Portability.** Portable and cheap: one overlay slot plus an
`(anchorId, text, delay, timeout)` record. The "last writer owns the slot" rule
removes every multi-tooltip race by construction — at the price of never being
able to show two at once.

### Anchor tracking via ancestor change listeners

`setParentItem` installs the positioner as a change listener on the anchor for
`Geometry|Parent`, then walks the whole ancestor chain installing
`Geometry|Parent|Children`; `itemChildRemoved` tears them down when the anchor
leaves the subtree. Popup **windows** instead learn their position _from_ the
window system (`moveEvent` → `handlePopupPositionChangeFromWindowSystem`) and
track the parent window via `xChanged`/`yChanged`.

**Portability.** The push-based listener chain is a retained-scene-graph idea.
_INFERENCE: in a toolkit that rebuilds per frame the honest equivalent is to
recompute placement every frame from the current anchor rect — cheaper, strictly
more current, and it makes the re-entrancy guard unnecessary._

---

## Strengths

- **Dismissal is one `QFlags` value** with a documented default, a reset path
  and an inheritance story (`Menu` swaps in `cascadingSubMenuClosePolicy` only
  when the author never set one). It is exhaustively testable as a truth table,
  and `tst_QQuickPopup::closePolicy` is exactly that — including the
  non-obvious "press inside, release outside never closes" row.
- **One base class genuinely serves six controls**, and the seams where
  subclasses diverge (six permission bits, `resolvedPopupType`, a positioner
  subclass, `blockInput`, prepare/finalize transitions) are explicit virtual
  hooks rather than special cases buried in the base.
- **The same declaration renders in-window, as an OS window, or natively**,
  resolved at show time from platform capabilities — and the in-window arm needs
  no compositor support whatsoever.
- **The collision algorithm is small, integral and portable**: one bounds rect,
  four margins, six booleans, and a flip acceptance test ("more visible area
  wins") that needs no side vocabulary. It shrinks a popup to fit **and**
  restores its implicit size when it fits again.
- **Placement authored as style bindings** means a style can completely re-place
  a control's popup without touching C++, and right-to-left comes free through
  the existing `LayoutMirroring` machinery.
- **Modality is a predicate over the hit target plus a real, styleable scrim
  item** — which makes the scrim maskable, so a virtual keyboard remains usable
  above a modal dialog. That escape hatch is a first-class, tested feature.
- **The lifecycle exposes the right observables** and is precise about ordering:
  `aboutToShow`/`aboutToHide`, `opened`/`closed`, and a deliberate split between
  `isOpened()` and `isVisible()` that later machinery correctly depends on.
- **Focus restoration is unusually careful**: the overlay remembers the
  pre-overlay target _and_ which popup saved it, handles a stack unwinding out
  of order, and snapshots `hadActiveFocus` before clearing focus so the evidence
  survives.
- **The touch/mouse split is one latched `touchId`** consulted by every
  hover-driven path, so hover machinery cannot misfire mid-touch.
- **The hard parts are actually tested**: `CloseMultiple` is data-driven across
  `{Item, Window} × {modal, non-modal}`, and automatic tooltip timing is
  testable because Qt exports two injectable globals instead of hard-coding the
  clock.

## Weaknesses

- **The resolved placement is never emitted as data.** `reposition()` decides a
  side and immediately discards it, so no style can draw a callout tail and
  animation origins are bound to static author intent.
- **No side vocabulary, no preferred-placement list, no fallback ordering.**
  Flip is a mirror about the anchor's box, which reproduces a genuine side swap
  only when the author's binding happened to be symmetric.
- **The flip permissions are opt-in and inconsistent.** A root `Menu` and a
  `ContextMenu` never flip at all; `ComboBox` flips only vertically; `Menu` only
  horizontally and only when cascading. A context menu opened near the right
  edge on the `Item` path is pushed and shrunk, never flipped.
- **`relaxEdgeConstraint` is set only in the public constructor**, so a `Popup`
  and a `Dialog` silently differ in whether they may hang off the window edge.
- **`popup.x` is asymmetric**: the setter writes the request, the getter returns
  the resolution, and `xChanged` is emitted from the positioner — so a binding
  on `popup.x` is a latent loop, and the requested position is unreachable from
  public API.
- **Two separate placement algorithms** (window bounds versus screen
  `availableGeometry`) with different flip formulas must be kept in sync, and the
  window one reaches into the popup with `property("overlap").toReal()` — a
  menu-specific concept read off an untyped `QObject` inside the generic
  positioner.
- **No clipping-ancestor or scroll-container discovery.** Bounds are always the
  whole overlay or screen, so a popup anchored inside a `Flickable` can be placed
  outside its visible region.
- **Modality had to be re-implemented per event category**, because the delivery
  agent does not route wheel, tablet and drag-and-drop through the popup path.
- **The close cascade needs an overlay-wide latch and a compensating press
  replay**, both of which exist only to undo an artefact of Qt's event delivery.
- **The overlay stack is derived by casting paint-order children's `QObject`
  parents**, which is why a shader-effect shadow and an async-loaded popup each
  needed a special case.
- **Tooltip timing has no warm-up group**: traversing a toolbar pays the full
  wake-up delay at every control.
- **Accessibility contributes only a role, open/close events and a name.** The
  overlay is never advertised as its anchor's description, no modal bit is set,
  and tooltips are deliberately non-hoverable.
- **No reduced-motion consultation anywhere** in the popup stack.
- **Native popups silently drop most of the `Menu` API**, ignore the QML
  delegate, and can make `open()` blocking on some platforms.

> [!WARNING]
> **A documentation/source discrepancy at this revision.** The `Menu`
> documentation states that "The macOS Style … sets it to be `Popup.Native`,
> while the Imagine Style uses `Popup.Window` (which is the default when the
> style doesn't set a popup type)" (`qquickmenu.cpp:172-175`). I could not find
> that in source at this SHA: `QQuickPopupPrivate::popupType` defaults to
> `QQuickPopup::Item` (`qquickpopup_p_p.h:209`), `QQuickMenu`'s constructor does
> not call `setPopupType`, and grepping `src/quickcontrols/**/*.qml` finds
> `popupType` set only in the seven `impl/TextEditingContextMenu.qml` files and
> in `macos/ComboBox.qml` — never in any style's `Menu.qml`. I did **not**
> verify whether a mechanism outside `src/` (a platform theme, a
> `qtquickcontrols2.conf`, or another Qt repository) supplies the default, so
> this is recorded as a discrepancy rather than as a refutation.

---

## Key design decisions and trade-offs

| Decision                                                                                                                                                                                                                                                 | Rationale                                                                                                                                                                                                                                                                                                               | Trade-off                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Dismissal is one flags value on the popup — `NoAutoClose`, `CloseOnPressOutside`, `CloseOnPressOutsideParent`, `CloseOnReleaseOutside`, `CloseOnReleaseOutsideParent`, `CloseOnEscape`, `CloseMultiple`; default `CloseOnEscape \| CloseOnPressOutside`. | Every dismissal question a caller has (which phase, relative to which rectangle, does it cascade) is answered by intersecting the popup's policy with the phase flags the handler passes in. It is declarative, comparable, storable, settable from QML, resettable to a documented default, and testable exhaustively. | The value cannot express the axes that are _not_ in it, so those became hard-coded behaviours: focus-out, scroll, anchor-hidden and window-deactivation never dismiss, and Escape is additionally gated on `hasActiveFocus()` — a fact invisible in the value. "`CloseOnRelease*` only works with modal popups" is a documented bug living inside the abstraction, and "`CloseMultiple` must be combined with an outside flag" is an unenforced invariant between bits of one word. |
| The same declaration renders as an item in the window's overlay, as a real OS child window, or as a platform-native menu — chosen at `open()` time by a virtual `resolvedPopupType()`, not by the author.                                                | `popupType` is a _preference_; the base downgrades `Window`/`Native` to `Item` without `MultipleWindows`, and `QQuickMenuPrivate` further overrides so the root menu (or a native menu bar) decides for a whole cascade. One QML file works on desktop, embedded and mobile.                                            | Two entirely separate placement algorithms had to be written and kept in sync, fitted against different rectangles with different flip formulas, and Wayland skips client-side fitting altogether. Native menus drop most of the API and can make `open()` blocking. `clip` silently changes meaning: `QQuickPopup::clip()` returns `popupItem->clip() && !usePopupWindow()`.                                                                                                       |
| There is no placement DSL. Placement is authored as QML bindings in the style file; the engine performs only collision correction, gated by six per-subclass booleans.                                                                                   | Reuses the binding system for the easy majority (anchoring, centering, mirroring) and keeps the engine to the part bindings cannot do — fitting against a viewport. A style can re-place a control's popup entirely without touching C++.                                                                               | No preferred-side concept, no fallback list, and no way for the engine to report which side it chose. Flip is a mirror about the anchor's box, so an asymmetric authored offset flips to a wrong place; and because the resolved side is never reported, `transformOrigin` is bound to static author intent.                                                                                                                                                                        |
| Attached tooltips share exactly one visual instance per `QQmlEngine` (keyed by a dynamic property on the engine) while text, delay, timeout and policy stay per attachee.                                                                                | Stated in the docs as resource conservation. It also eliminates every multi-tooltip coordination problem by construction: only the last item to call `show()` owns the slot, and `hide()` is a no-op unless you still own it.                                                                                           | No warm-up or skip-delay group behaviour — traversing a toolbar pays the full wake-up delay at every button, because each `show()` re-pushes its own delay onto the shared instance. Two tooltips can never be visible at once, forcing authors into local `ToolTip` instances that then get none of the automatic policy machinery.                                                                                                                                                |
| The in-window top layer is a plain `QQuickItem` at `z = 1000001`, created lazily as a child of the window's content item.                                                                                                                                | Requires zero renderer or compositor support: re-parenting the popup item to the overlay is the entire portal, and stacking is ordinary paint order plus an opportunistic `setZ(max(topZ, myZ))`. It composes with the scene graph — `Overlay.overlay` is a real item you can anchor to.                                | The overlay is not hermetic: the docs tell you to parent a virtual keyboard into it with a positive `z`, then warn that "the overlay wasn't designed for this purpose". A scale applied to a tree containing a `ComboBox` does not scale its popup, and the documented fix is to apply the same transform to `Overlay.overlay` by hand.                                                                                                                                             |
| Modality is a separately-instantiated dimmer item stacked just below the popup, plus a `blockInput()` predicate consulted by the overlay — not a property of the layer.                                                                                  | Makes the scrim fully styleable per popup and lets `dim` follow `modal` unless explicitly set. Because the scrim is a real item, a `containmentMask` can punch holes in it — which is how a virtual keyboard stays usable above a modal dialog.                                                                         | Modality has to be re-implemented per event category, because the delivery agent does not route wheel, tablet and drag-and-drop through the same path; each was a separate bug fix. And the hole suppresses both blocking _and_ auto-close, which is coupling that only one class of hole actually wants.                                                                                                                                                                           |
| `popup.x` is asymmetric: the setter records the requested position, the getter returns the resolved one (after flip/push/clamp and window-inset correction).                                                                                             | Gives authors one property that reads back where the popup actually is, so bindings and tests can observe collision results, while the engine keeps the un-corrected intent needed to re-run placement when the anchor or viewport changes.                                                                             | Setting `x` then reading `x` can yield a different number, and `xChanged` fires from the positioner rather than only from the setter, so a binding on `popup.x` is a latent loop. The requested position is unreachable from public API, so external code cannot reason about placement.                                                                                                                                                                                            |

---

## Sources

Primary sources, all read at
`ffc46f28ab21b6666dbea46c81cf2726ce682419`:

- **The popup base and its policy value** — [`qquickpopup_p.h` (`ClosePolicyFlag`)][src-closepolicy],
  [`qquickpopup.cpp` (`tryClose`)][src-tryclose],
  [`blockInput`][src-blockinput], [`keyPressEvent`][src-keypress],
  [the three-position comment][src-threepos],
  [the constructor asymmetry][src-ctor],
  [`resolvedPopupType`][src-resolvedtype],
  [`windowInsets`][src-insets], [`createDimmer`][src-dimmer],
  [`overlayEvent`][src-overlayevent], [accessible role][src-role],
  [the private field list][src-priv], [`DefaultClosePolicy`][src-defaultpolicy],
  [`finalizeExitTransition` (focus restoration)][src-focusexit],
  [the transition manager][src-transitions],
  [`safeAreaAttachmentItem`][src-safearea].
- **The positioner** — [`reposition()`][src-reposition],
  [the flip block][src-flip], [`repositionPopupWindow()`][src-reposwindow],
  [ancestor listeners][src-listeners].
- **The in-window overlay** — [`setZ(1000001)`][src-overlayz],
  [`stackingOrderPopups`][src-stacking],
  [`canCascadeCloseOnOutsidePress` / `closedItselfViaCloseMultiple`][src-cascade],
  [`eatEventIfBlockedByModal`][src-eatevent],
  [`childMouseEventFilter`][src-childfilter],
  [the per-window overlay state][src-overlaypriv].
- **The popup window** — [`filterPopupSpecialCases`][src-filter],
  [`parentControlGeometry`][src-parentgeom], [Android Back][src-back],
  [the grab statics][src-grabstatics].
- **`ToolTip`** — [the constructor (`setHoverEnabled(false)`)][src-tipctor],
  [the timers][src-tiptimers], [`calculateTimeout`][src-tiptimeout],
  [the shared instance][src-tipinstance],
  [`show`/`hide`][src-tipshow],
  [`maybeSetVisibleImplicitly`][src-tipmaybe],
  [the injectable test globals][src-tipglobals].
- **`Menu` and friends** — [`QQuickMenuPositioner::reposition`][src-menupos],
  [`SUBMENU_DELAY`][src-submenudelay],
  [`cascadingSubMenuClosePolicy` / `shouldCascade`][src-menupolicy],
  [`QQuickMenuPrivate::resolvedPopupType`][src-menutype],
  [`blockInput`][src-menublock], [`onItemHovered`][src-menuhover],
  [`dismiss`][src-menudismiss], [`popup(…)` cursor fallback][src-menupopup],
  [`QQuickContextMenu::event`][src-contextmenu],
  [`QQuickMenuBarPrivate::onItemHovered`][src-menubar].
- **Subclass seams** — [`ComboBox::setPopup`][src-combobox],
  [`Drawer`'s constructor][src-drawerctor],
  [`Drawer`'s `resolvedPopupType`][src-drawertype],
  [`QQuickPopupItemPrivate` (`isTabFence`)][src-tabfence],
  [`QQuickPopupItem::accessibleRole`][src-itemrole],
  [`isBlockedByPopup`][src-shortcut],
  [`QQuickControl::hoverChange`][src-hoverchange],
  [`QQuickAbstractButton::timerEvent`][src-buttontimer].
- **Styles** — [Basic `ToolTip.qml`][src-basictip],
  [Material `Menu.qml` (`transformOrigin`)][src-materialmenu],
  [macOS `ComboBox.qml` (safe area)][src-macoscombo],
  [iOS `Menu.qml` (`overlap`)][src-iosmenu].
- **Tests** — [`tst_QQuickPopup::closePolicy`][src-testpolicy],
  [`tst_QQuickPopup::dimmerContainmentMask`][src-testdimmer].
- **Documentation** — [`Popup`][doc-popup], [`ToolTip`][doc-tooltip],
  [`Menu`][doc-menu], [`Overlay`][doc-overlay].

Catalog cross-references: the umbrella [index][index] and shared
[concepts][concepts]; the capstone [comparison][comparison]; the
[edge-case museum][forget]; the toolkit [baseline][baseline] and
[proposal][proposal]. Nearest siblings by mechanism: [Qt Widgets][qt-widgets]
(the same vendor, OS-popup-only, with grabs), [GTK4][gtk4] and
[xdg_positioner][xdg] (a declared positioner value solved out of process),
[Avalonia][avalonia] and [Slint][slint] (one declaration, two surfaces),
[WinUI][winui] and [WPF][wpf], [Compose][compose] and [Flutter][flutter];
in-canvas peers [Dear ImGui][imgui], [Textual][textual] and
[Neovim floats][neovim]; headless web peers [Base UI][base-ui],
[React Aria][react-aria], [Floating UI][floating-ui] and the
[ARIA APG][apg]. Adjacent research trees:
[window-system integration][wsi], [platform UI guidelines][platform-ui],
[UI layout][ui-layout] (including its own
[Qt layouts deep-dive][qt-layouts]) and [Sean Parent][sean-parent].
Toolkit specs: [UI][spec-ui], [input][spec-input], [containers][spec-containers],
[state machines][spec-stm], [backends][spec-backends], [widgets][spec-widgets].

<!-- References -->

[repo]: https://github.com/qt/qtdeclarative
[doc-popup]: https://doc.qt.io/qt-6/qml-qtquick-controls-popup.html
[doc-tooltip]: https://doc.qt.io/qt-6/qml-qtquick-controls-tooltip.html
[doc-menu]: https://doc.qt.io/qt-6/qml-qtquick-controls-menu.html
[doc-overlay]: https://doc.qt.io/qt-6/qml-qtquick-controls-overlay.html
[src-closepolicy]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quicktemplates/qquickpopup_p.h#L244-L254
[src-tryclose]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quicktemplates/qquickpopup.cpp#L533-L553
[src-blockinput]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quicktemplates/qquickpopup.cpp#L575-L589
[src-keypress]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quicktemplates/qquickpopup.cpp#L3235-L3259
[src-threepos]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quicktemplates/qquickpopup.cpp#L709-L720
[src-ctor]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quicktemplates/qquickpopup.cpp#L1450-L1462
[src-resolvedtype]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quicktemplates/qquickpopup.cpp#L1183-L1205
[src-insets]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quicktemplates/qquickpopup.cpp#L667-L707
[src-dimmer]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quicktemplates/qquickpopup.cpp#L1276-L1317
[src-overlayevent]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quicktemplates/qquickpopup.cpp#L3321-L3360
[src-role]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quicktemplates/qquickpopup.cpp#L3542-L3558
[src-priv]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quicktemplates/qquickpopup_p_p.h#L146-L219
[src-defaultpolicy]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quicktemplates/qquickpopup.cpp#L500
[src-focusexit]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quicktemplates/qquickpopup.cpp#L859-L920
[src-transitions]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quicktemplates/qquickpopup.cpp#L1412-L1448
[src-safearea]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quicktemplates/qquickpopup.cpp#L3596-L3599
[src-reposition]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quicktemplates/qquickpopuppositioner.cpp#L75-L286
[src-flip]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quicktemplates/qquickpopuppositioner.cpp#L156-L172
[src-reposwindow]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quicktemplates/qquickpopuppositioner.cpp#L288-L370
[src-listeners]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quicktemplates/qquickpopuppositioner.cpp#L50-L73
[src-overlayz]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quicktemplates/qquickoverlay.cpp#L410-L418
[src-stacking]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quicktemplates/qquickoverlay.cpp#L44-L58
[src-cascade]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quicktemplates/qquickoverlay.cpp#L184-L212
[src-eatevent]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quicktemplates/qquickoverlay.cpp#L83-L150
[src-childfilter]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quicktemplates/qquickoverlay.cpp#L618-L724
[src-overlaypriv]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quicktemplates/qquickoverlay_p_p.h#L66-L81
[src-filter]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quicktemplates/qquickpopupwindow.cpp#L188-L346
[src-parentgeom]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quicktemplates/qquickpopupwindow.cpp#L504-L516
[src-back]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quicktemplates/qquickpopupwindow.cpp#L393-L401
[src-grabstatics]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quicktemplates/qquickpopupwindow.cpp#L31-L32
[src-tipctor]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quicktemplates/qquicktooltip.cpp#L186-L194
[src-tiptimers]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quicktemplates/qquicktooltip.cpp#L157-L185
[src-tiptimeout]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quicktemplates/qquicktooltip.cpp#L534-L543
[src-tipinstance]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quicktemplates/qquicktooltip.cpp#L373-L398
[src-tipshow]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quicktemplates/qquicktooltip.cpp#L739-L773
[src-tipmaybe]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quicktemplates/qquicktooltip.cpp#L400-L421
[src-tipglobals]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quicktemplates/qquicktooltip.cpp#L100-L114
[src-menupos]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quicktemplates/qquickmenu.cpp#L994-L1020
[src-submenudelay]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quicktemplates/qquickmenu.cpp#L53
[src-menupolicy]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quicktemplates/qquickmenu.cpp#L269-L278
[src-menutype]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quicktemplates/qquickmenu.cpp#L319-L364
[src-menublock]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quicktemplates/qquickmenu.cpp#L1078-L1082
[src-menuhover]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quicktemplates/qquickmenu.cpp#L1121-L1146
[src-menudismiss]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quicktemplates/qquickmenu.cpp#L2352-L2359
[src-menupopup]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quicktemplates/qquickmenu.cpp#L2212-L2228
[src-contextmenu]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quicktemplates/qquickcontextmenu.cpp#L218-L261
[src-menubar]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quicktemplates/qquickmenubar.cpp#L208-L214
[src-combobox]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quicktemplates/qquickcombobox.cpp#L1488-L1502
[src-drawerctor]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quicktemplates/qquickdrawer.cpp#L653-L658
[src-drawertype]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quicktemplates/qquickdrawer.cpp#L610-L614
[src-tabfence]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quicktemplates/qquickpopupitem.cpp#L22-L26
[src-itemrole]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quicktemplates/qquickpopupitem.cpp#L407-L433
[src-shortcut]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quicktemplates/qquickshortcutcontext.cpp#L25-L51
[src-hoverchange]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quicktemplates/qquickcontrol.cpp#L2163
[src-buttontimer]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quicktemplates/qquickabstractbutton.cpp#L1342
[src-basictip]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quickcontrols/basic/ToolTip.qml#L9-L23
[src-materialmenu]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quickcontrols/material/Menu.qml#L22
[src-macoscombo]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quickcontrols/macos/ComboBox.qml#L61
[src-iosmenu]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quickcontrols/ios/Menu.qml#L23
[src-testpolicy]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/tests/auto/quickcontrols/qquickpopup/tst_qquickpopup.cpp#L658-L753
[src-testdimmer]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/tests/auto/quickcontrols/qquickpopup/tst_qquickpopup.cpp#L2270-L2323
[index]: ./index.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[forget]: ./features-people-forget.md
[baseline]: ./sparkles-baseline.md
[proposal]: ./proposal.md
[qt-widgets]: ./qt-widgets.md
[gtk4]: ./gtk4.md
[xdg]: ./xdg-positioner.md
[avalonia]: ./avalonia.md
[slint]: ./slint.md
[winui]: ./winui.md
[wpf]: ./wpf.md
[compose]: ./compose.md
[flutter]: ./flutter.md
[imgui]: ./imgui.md
[textual]: ./textual.md
[neovim]: ./neovim-floats.md
[base-ui]: ./base-ui.md
[react-aria]: ./react-aria.md
[floating-ui]: ./floating-ui.md
[apg]: ./aria-apg.md
[wsi]: ../window-system-integration/index.md
[platform-ui]: ../platform-ui-guidelines/index.md
[ui-layout]: ../ui-layout/index.md
[qt-layouts]: ../ui-layout/qt-layouts.md
[sean-parent]: ../sean-parent/index.md
[spec-ui]: ../../specs/ui/index.md
[spec-input]: ../../specs/ui/input.md
[spec-containers]: ../../specs/ui/containers.md
[spec-stm]: ../../specs/ui/state-machines.md
[spec-backends]: ../../specs/ui/backends.md
[spec-widgets]: ../../specs/ui/widgets.md
[dbi]: ../../guidelines/design-by-introspection-01-guidelines.md
