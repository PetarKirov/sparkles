# Qt Widgets — `QMenu`, `QToolTip` and the `Qt::Popup` grab (C++ / Qt 6)

Qt Widgets is the grab-based anchored-overlay model at its most literal: one window flag buys the
overlay stack, the input grab, the event re-routing and the modality exemption — and everything
above that transport layer is hand-written, separately, in every widget that needs it.

| Field         | Value                                                                                                     |
| ------------- | --------------------------------------------------------------------------------------------------------- |
| Language      | C++ (Qt 6, `moc` / `Q_OBJECT`)                                                                            |
| License       | `LicenseRef-Qt-Commercial` OR `LGPL-3.0-only` OR `GPL-2.0-only` OR `GPL-3.0-only` (tests: `GPL-3.0-only`) |
| Repository    | [`qt/qtbase`][repo]                                                                                       |
| Documentation | [`QMenu`][doc-qmenu], [`QToolTip`][doc-qtooltip], [`Qt::WindowFlags`][doc-windowflags]                    |
| Category      | Native desktop (Qt), source-verified                                                                      |
| Surface model | OS popup — every overlay is a real top-level window carrying `Qt::Popup` or `Qt::ToolTip`                 |
| Revision read | `d0787745aa43e5baf49de876f917946df6aceca5` (`QT_REPO_MODULE_VERSION` 6.8.3 in `.cmake.conf`)              |

---

## Overview

### What it solves

Qt Widgets answers "how does a menu behave" by delegating to the window system and then repairing
the delegation in software. A [`QMenu`][doc-qmenu] is an actual top-level OS window carrying the
`Qt::Popup` flag. Showing it pushes it onto a process-global window stack
(`QGuiApplicationPrivate::popup_list`, `qguiapplication.cpp:186`) and, for the first entry in that
stack only, takes a real keyboard [grab][c-grab] followed by a mouse grab. From that moment every
pointer and key event in the process is re-targeted: `QWindowPrivate::forwardToPopup`
(`qwindow.cpp:2432`) clones the event, remaps its points into the popup's coordinates and re-sends
it, and `QWidgetWindow::handleMouseEvent` (`qwidgetwindow.cpp:509`) does the same again,
unconditionally, at the widget layer. [Light dismiss][c-light-dismiss] is a _consequence_ of that
routing — a press whose global position lands outside every menu in the caused chain closes the
chain down to the menubar — not a separate feature.

A [`QToolTip`][doc-qtooltip] is the opposite design in the same library. It is a `Qt::ToolTip`
window that is **not** in the popup list, takes no grab, and dismisses itself through an
application-wide event filter installed by a single shared `QTipLabel` singleton, driven by two
`QBasicTimer`s that live in `QApplicationPrivate`. Two dismissal architectures ship side by side
because a tooltip must never steal input and a menu must always steal it.

> [!IMPORTANT]
> **Reading conditions.** Everything below is read from source and from the in-tree test suite at
> the pinned revision; nothing was built or run, so no claim here is an empirical statement about
> on-screen behaviour on any platform. The clone is shallow (depth 1) and sparsely checked out, so
> no commit history, blame or changelog archaeology was possible — no claim is made about _when_ a
> mechanism landed. Grab-mechanism claims are verified against the XCB backend only; the Wayland
> plugin is absent from the checkout, and the Cocoa and Windows `setMouseGrabEnabled` /
> `setKeyboardGrabEnabled` implementations were not read.

### Design philosophy

"The window system is the overlay system." There is no [placement][c-placement] engine, no collision
framework, and no shared overlay base class. Placement is six to twelve inline `if` statements,
written out separately in `QMenu`, `QComboBox`, `QPushButton`, `QToolButton` and
`QTipLabel`/`QBalloonTip`, each with its own fallback ladder. What _is_ shared is exactly one thing:
the `Qt::Popup` window flag, which buys the stack, the grab and the re-routing at no further cost to
the widget author.

The load-bearing quote is `grabForPopup`, `qapplication.cpp:3331-3343` — the grab is a two-phase
transaction that can fail, and failure is **recorded, not fatal**:

```cpp
static bool popupGrabOk;

static void grabForPopup(QWidget *popup)
{
    Q_ASSERT(popup->testAttribute(Qt::WA_WState_Created));
    popupGrabOk = qt_widget_private(popup)->stealKeyboardGrab(true);
    if (popupGrabOk) {
        popupGrabOk = qt_widget_private(popup)->stealMouseGrab(true);
        if (!popupGrabOk) {
            // transfer grab back to the keyboard grabber if any
            ungrabKeyboardForPopup(popup);
        }
    }
    qCDebug(lcWidgetPopup) << "grabbed mouse and keyboard?" << popupGrabOk << "for popup" << popup;
}
```

`popupGrabOk == false` means the popup keeps working on software re-routing alone. The XCB backend
refuses to grab when `connection()->canGrab()` is false (the `-nograb` debugging switch) or when
`xcb_grab_pointer`'s reply status is not `SUCCESS` (`qxcbwindow.cpp:2340`, `:2354`), and Qt
continues regardless.

> [!NOTE]
> The grab is not, however, purely about events outside the application's own windows. In Qt the
> same `popupGrabOk` flag gates the dismissing-press replay: the `QApplicationPrivate::replayMousePress = true`
> assignment in `closePopup` sits **inside** the `if (popupGrabOk)` branch (`qapplication.cpp:3356-3363`),
> so an application whose grab failed also silently loses press replay. Whatever a port keeps from
> this model has to reproduce the software forwarding _and_ decide the replay question itself.

---

## How it works

Four mechanisms, in the order an event meets them.

**1. The stack.** `QGuiApplicationPrivate::popup_list` is a `QWindowList` used as a stack.
`activatePopup()` does `removeOne` then `append`, so an entry is unique and last; the top is by
definition the event target (`qguiapplication.cpp:969-1004`). It is fed from two places —
`QWindowPrivate::setVisible` for any `Qt::Popup` window, and `QWidgetPrivate::show_helper` /
`hide_helper` for widgets — which is why the invariant is "unique and last" rather than "push/pop".
`closeAllPopups()` loops `activePopupWindow()->close()` **at most 1024 times**, because a popup's
`closeEvent` may refuse.

**2. The grab.** Only the first popup grabs; nested popups ride it. See the quote above.

**3. The re-routing.** Any pointer or key event delivered to any window is first offered, remapped,
to the top of the stack. The pointer path clones the event, rewrites every event point's `position`
and `scenePosition` to `popupWindow->mapFromGlobal(globalPosition)`, and credits the popup with the
event only if it _accepted_ it (`qwindow.cpp:2450-2458`):

```cpp
/*  Popups are expected to be able to directly handle the
    drag-release sequence after pressing to open, as well as
    any other mouse events that occur within the popup's bounds. */
if (QCoreApplication::sendSpontaneousEvent(popupWindow, pointerEvent.get())) {
    event->setAccepted(pointerEvent->isAccepted());
    if (pointerEvent->isAccepted())
        ret = popupWindow;
```

The widget layer then repeats the retarget to `activePopupWidget()->childAt(mapped)` with no
acceptance check at all, and manufactures synthetic enter/leave events because under a grab the
window manager's crossing events describe the pre-grab hierarchy.

> [!NOTE]
> `forwardToPopup`'s second parameter is commented out in the signature —
> `const QWindow */*activePopupOnPress*/` at `qwindow.cpp:2432` — while its documentation comment
> above still describes it. This appears to be a refinement in flux; the routing is still being
> reworked at this revision.

**4. The tooltip filter.** Entirely separate. `QTipLabel::eventFilter` (`qtooltip.cpp:283`) is
installed application-wide by the singleton label and hides on any press, release, double-click or
wheel (`qtooltip.cpp:322-327`):

```cpp
case QEvent::MouseButtonPress:
case QEvent::MouseButtonRelease:
case QEvent::MouseButtonDblClick:
case QEvent::Wheel:
    hideTipImmediately();
    break;
```

---

## The analysis spine

### 1. Anchor model

There is no anchor type. `QMenu::popup(const QPoint &p, QAction *atAction)` takes a bare **global
point**; the trigger is carried separately in `QMenuPrivate::causedPopup`, a
`{QPointer<QWidget>, QPointer<QAction>}` pair (`qmenu_p.h:402`), and is used for RTL alignment,
submenu-overlap resolution, layout-direction inheritance and event forwarding. Trigger and
[anchor rect][c-anchor-rect] are therefore already decoupled, which makes the detached-trigger case
work by construction. Submenus are the only rect-anchored case: the anchor is the parent's current
`actionRect` mapped to global (`qmenu.cpp:3637`). Many-triggers-one-popup is native — one `QMenu`,
many `QToolButton`s, each stamping `causedPopup` before `popup()`.

[Virtual anchors][c-virtual-anchor] and moving anchors are not modelled: geometry is sampled once
and never re-read.

The most transferable idea here is `QMenuPrivate::PositionFunction` (`qmenu_p.h:275`), declared as
`using PositionFunction = std::function<QPoint(const QSize &)>;`. The caller supplies a closure from
the final popup size to a global point, and it is evaluated _after_ `aboutToShow()` — so a menu
populated inside its own `aboutToShow` handler is still placed against its true size (QTBUG-78966).

`QToolTip`'s anchor is a global point plus an optional widget-local `QRect` that is a **dwell
region**, not an alignment box: leaving it hides the tip (`qtooltip.cpp:263`).

**Algorithm.**

```text
popup(p):
    screen := screenAt(p)
    if atAction: p.y -= sum(height of actionRects before atAction)
submenu:
    actionRect := parentMenu.actionRect(parentMenu.currentAction)
    subPos     := global(actionRect.right() + PM_SubMenuOverlap, actionRect.top())
    subPos.y   -= submenu.actionGeometry(firstAction).top()   // align items, not borders
if positionFunction:
    pos := positionFunction(menuSizeHint)   // evaluated after aboutToShow()
```

**Where the behavior lives.** Library code (QtWidgets), entirely. Nothing about anchoring reaches
QPA or the compositor; the platform receives only a final absolute geometry via
`QWidget::setGeometry`.

**Degradation.** This dimension survives everything. With no OS window a "global `QPoint`" becomes a
surface-local cell point and `screenAt()` collapses to the single surface rect. The
`PositionFunction` pattern is expressible either as a D delegate `Point delegate(Size)` or, in a
`@nogc` form, as a tagged struct of anchor kind plus cell rect plus alignment. Hover, script and key
release are irrelevant here.

> [!NOTE]
> INFERENCE: the anchor already behaves like a plain comparable value in this subject —
> `QTipLabel::tipChanged` (`qtooltip.cpp:402`) decides tooltip reuse by comparing text, provider
> widget and rect containment, which is value equality over an anchor tuple in all but name.

### 2. Placement model

Straight-line integer arithmetic in a fixed order: shrink-to-screen, position-at-action, flip
vertically, clamp all four sides, then a submenu-overlap correction with its own three-step
fallback. There is no preferred-side list and no auto-placement — the side is hardcoded per widget
class. Horizontal overflow is never [flipped][c-flip] for a top-level menu, only clamped; vertical
overflow flips above the anchor **fused with the clamp** into one `qMin` (`qmenu.cpp:2491-2493`):

```cpp
if (pos.y() + size.height() - 1 > screen.bottom() - desktopFrame) {
    if (snapToMouse)
        pos.setY(qMin(mouse.y() - (size.height() + desktopFrame), screen.bottom()-desktopFrame-size.height()+1));
```

`snapToMouse` is _inferred_, not passed: it is true when there is no causing widget and the cursor
lies within a 6×6 box around the requested point (`qmenu.cpp:2467`), and it changes both the RTL
x-origin and the vertical flip origin. RTL is handled by three separate branches (snap-to-mouse
flows left from the cursor; menubar- and submenu-caused menus subtract their own width; the clamp
uses `qMax` instead of a hard assignment).

The [clipping boundary][c-boundary] is `QScreen::availableGeometry()` unless the platform theme sets
`UseFullScreenForPopupMenu` (`qstyle.cpp:2418`, consulted through
`QMenuPrivate::useFullScreenForPopup`, `qmenu.cpp:287`); torn-off menus always use available
geometry. `PM_MenuDesktopFrameWidth` is a uniform viewport padding. There are no writing modes, no
safe-area insets and no IME or virtual-keyboard avoidance — `QComboBox` merely calls
`inputMethod()->reset()` (`qcombobox.cpp:2794`) to dismiss the IME rather than make room for it.
Multi-monitor is handled by re-running `QGuiApplication::screenAt()` three times as `pos` changes,
stashing the result in a `QPointer<QScreen> popupScreen` cleared by a `QScopeGuard`; a screen change
sets `itemsDirty`, because item metrics are font- and DPI-dependent.

**Algorithm.**

```text
screen := useFullScreenForPopup() ? screen.geometry : screen.availableGeometry
df     := PM_MenuDesktopFrameWidth

if size > screen:            size := min(sizeHint, screen - 2*df); adjustToDesktop := true
if ncols > 1:                y := screen.top + df
else if atAction:            y -= heightsAbove   (or ScrollUp + scrollOffset if that lands above df)
snapToMouse := (no causedWidget) && rect(p - 3, 6x6).contains(cursor)

LTR x:  if x + w - 1 > screen.right - df:  x := screen.right - df - w + 1
        if x < screen.left + df:           x := screen.left + df
y:      if y + h - 1 > screen.bottom - df: y := min((snapToMouse ? cursor.y : p.y) - (h + df),
                                                   screen.bottom - df - h + 1)
        if y < screen.top + df:            y := screen.top + df
        if still overflowing:              scrollable ? (ScrollDown + shrink) : y := screen.bottom - h + 1

submenu overlap (only if parentWidth + subWidth + PM_SubMenuOverlap < screen.width):
        if placed rect intersects parent action rect horizontally: x := parentActionRect.right()
        if that overflows right:                                   x := parentActionRect.left() - w
        if that overflows left:                                    x := screen.right - w
```

`QTipLabel::placeTip` (`qtooltip.cpp:346`) is its own ladder: offset by `(2, cursorHeight)`, or by
`(cursorWidth / 2, 0)` when the cursor is taller than twice the tip; then `p.x -= 4 + w` on right
overflow, `p.y -= 24 + h` on bottom overflow; then clamp top, right, left, bottom in that order.

**Where the behavior lives.** Library code. `QScreen::availableGeometry` is the only platform input,
plus one theme hint and one platform cursor-size query.

**Degradation.** Ports essentially unchanged to integer cells — every operation is `qMin`/`qMax` on
`int`. What disappears with a single surface: multi-monitor, work areas, DPI. What must be _added_,
because this subject has no answer for it, is a soft-keyboard inset: Qt discovers nothing about a
virtual keyboard anywhere in this path, which is an argument for making the inset an explicit input
to placement rather than something the solver goes looking for (see
[`../platform-ui-guidelines/index.md`](../platform-ui-guidelines/index.md) and
[`./xdg-positioner.md`](./xdg-positioner.md) for how a protocol states the same boundary). With no
script — a static HTML emission — none of this can run at emit time, and a tier-0 fallback must
bake one side and accept clipping.

### 3. Collision & geometry engine

There is no engine, and that is the finding. Overflow detection is inline per call site and written
out five times across the library (see dimension 16). Clipping-ancestor discovery does not exist,
because a popup is an OS window and the only boundary is a `QScreen` rect; the single exception is
`QGraphicsView` embedding, where `bypassGraphicsProxyWidget()` / `nearestGraphicsProxyWidget()`
switch `popupGeometry()` to the widget's own screen rect (`qmenu.cpp:2373`).

There is **no tracking of any kind** — no observers, no polling, no frame callback. Geometry is
computed once inside `popup()` and never revisited. An anchor that moves, scrolls out of view, or is
destroyed (a `QPointer` merely nulls `causedPopup.widget`) leaves the popup exactly where it was.
`QEvent::Resize` recomputes action rects and re-applies the style mask but does not reposition
(`qmenu.cpp:3027`), and adding an action to a _visible_ menu calls `resize(sizeHint())`
(`qmenu.cpp:3601`), growing from the top-left with no re-clamp — so a menu can grow off-screen after
it is shown.

Device-pixel-ratio and fractional scaling never appear in the placement math (logical pixels
throughout); the only high-DPI conversion in the whole overlay path is `QHighDpi::fromNativePixels`
on the platform cursor size for the tooltip offset (`qtooltip.cpp:376`). Cost is `O(actions)` once
for `updateActionRects` — which also performs the multi-column wrap — and `O(1)` for placement.

**Algorithm** (`updateActionRects`, `qmenu.cpp:338`):

```text
column_max_y := screen.height - 2*deskFw - (vmargin + bottommargin + fw)
pass 1: size every item via QStyle::sizeFromContents;
        when not scrollable, increment ncols and reset y whenever y + h > column_max_y
pass 2: x := hmargin + fw + leftmargin;
        advance x by max_column_width + hmargin at each column break;
        force a uniform column width
placement then consumes only the resulting total sizeHint
```

**Where the behavior lives.** Library code, spread across `QMenuPrivate`, `QComboBox`,
`QPushButtonPrivate`, `QToolButtonPrivate`, `QTipLabel` and `QBalloonTip`. Nothing generalized.

**Degradation.** What generalizes off the native substrate is the _shape_ of the pipeline — measure,
flip, clamp against a padded rect — plus the multi-column spill, which is a good answer for a tall
menu in a short terminal. What does not generalize is anchor tracking, because there is none.
INFERENCE: a single-surface toolkit that rebuilds its tree every frame can re-measure the anchor for
free and re-run placement per frame, which would remove the stale-geometry defect class this subject
lives with; see [`./sparkles-baseline.md`](./sparkles-baseline.md) for what the toolkit already
produces per frame.

### 4. Arrow / caret geometry

Neither `QMenu` nor `QToolTip` has a callout arrow — an absence worth recording, because it means
this subject's two flagship overlays carry no anchor-pointing affordance at all and rely purely on
proximity. The only shape hook is a style-supplied mask: `SH_ToolTip_Mask` and `SH_Menu_Mask` return
a `QStyleHintReturnMask` whose `QRegion` is applied in `resizeEvent` (`qtooltip.cpp:223`,
`qmenu.cpp:3027`) — an arbitrary silhouette as opaque data from the style, never parameterized by
side or anchor.

The one real arrow lives in `QBalloonTip`, the system-tray notification (`qsystemtrayicon.cpp:565`):
constants `ah = 18` (arrow height), `ao = 18` (offset from the corner), `aw = 18` (width), `rc = 7`
(corner radius). `arrowAtTop` and `arrowAtLeft` are decided by two overflow predicates
(`qsystemtrayicon.cpp:575`), the arrow height is folded into `setContentsMargins` so it _feeds the
layout_, and the window is then moved so the arrow tip lands on the anchor. But the arrow is
immediately baked into a `QPainterPath` used both as a bitmap mask and as the border stroke, so it is
not data — and the edge clamp `qMax(pos.x - ao, screenRect.left + 2)` (`qsystemtrayicon.cpp:602`)
moves the window without moving the arrow inside it, so near a screen edge the arrow stops pointing
at the anchor.

**Algorithm.**

```text
QBalloonTip::balloon(pos, msecs, showArrow):
    arrowAtTop  := pos.y + sh.height + ah < screenRect.height
    arrowAtLeft := pos.x + sh.width  - ao < screenRect.width
    contentsMargins += ah on the arrow side; re-query sizeHint
    build a rounded-rect path with a 3-point triangular notch at offset ao from the arrow-side corner
    move() the window so the notch tip is at pos, clamped to screenRect +/- 2
```

**Where the behavior lives.** Library code (`QtWidgets` util). Not shared with `QMenu` or
`QToolTip` in any way.

**Degradation.** In a cell grid an arrow is at most one border cell bearing a directional glyph, and
"arrow size feeds the offset" becomes exactly one cell of offset. Below that the arrow must be
dropped, leaving adjacency as the only anchor cue — which is what `QMenu` and `QToolTip` already
ship. INFERENCE: treating the arrow as data — a side, an along-axis offset in cells, and a
visibility bit — computed by placement and consumed by paint would let the TUI drop it, let the GUI
render it, and let the edge clamp move box and arrow independently, which is the failure `QBalloonTip`
exhibits here.

### 5. Trigger semantics

`QMenu` has no trigger of its own: it is opened programmatically, and every trigger lives in the
widget that owns it. `QWidget::event` dispatches `QEvent::ContextMenu` through a four-valued policy
(`qwidget.cpp:9161`): `NoContextMenu`/`PreventContextMenu`, `DefaultContextMenu` → virtual
`contextMenuEvent`, `CustomContextMenu` → signal, `ActionsContextMenu` → `QMenu::exec` over the
widget's actions.

The press-versus-release question for context menus is a first-class, platform-defaulted,
application-overridable style hint: `QGuiApplicationPrivate::contextMenuEventType()`
(`qguiapplication.cpp:3619`) maps `QStyleHints::contextMenuTrigger()` (`qstylehints.cpp:459`) to
`MouseButtonPress` (UNIX default) or `MouseButtonRelease` (Windows default). The synthesized
`QContextMenuEvent` is emitted _after_ the ordinary mouse event, only for `RightButton`, and only if
the position lies inside the widget rect (`qwidgetwindow.cpp:670`).

Button-triggered menus differ per widget: `QPushButton` opens on press (`qpushbutton.cpp:565`),
`QToolButton` on a press-and-hold timer (`qtoolbutton.cpp:740`). Hover as a trigger exists only
_inside_ an already-open menu. Tooltips are hover-only and armed from exactly one place —
`QApplication::notify` intercepts every spontaneous `MouseMove` with `buttons() == 0` whose position
lies inside `w->rect()` (`qapplication.cpp:2749`). There is no focus trigger, no long-press, no
pointer-type distinction and no assistive-technology-initiated trigger; the keyboard equivalent of a
tooltip is a separate subsystem (What's This, Shift+F1).

Trigger races are prevented structurally rather than by arbitration: there is exactly one
`toolTipWidget` pointer and one wake-up timer in the whole application, so a new hover overwrites the
pending one; and once a popup is open, the grab plus the re-routing make it impossible for any other
widget to see a press.

**Algorithm.**

```text
tooltip arming (spontaneous MouseMove, buttons == 0, inside w->rect()):
    toolTipWidget    := w
    toolTipPos       := local
    toolTipGlobalPos := global
    wakeUp.start(fallAsleep.isActive() ? 20 : SH_ToolTip_WakeUpDelay)

context menu (after delivering the mouse event):
    if type == contextMenuEventType() && button == RightButton && widget rect contains pos:
        send QContextMenuEvent(Mouse, ...) to the same receiver
        if accepted: accept the mouse event too
```

**Where the behavior lives.** Split three ways: policy dispatch in `QWidget::event` (library),
synthesis in `QWidgetWindow` (the widget/QPA bridge), and the press-versus-release choice in
`QStyleHints` backed by `QPlatformTheme::ContextMenuOnMouseRelease` (platform theme).

**Degradation.** Android has no hover, so the entire tooltip arming predicate is dead — and this
subject offers no fallback whatsoever, so a hover substitute has to be invented elsewhere. The
press-versus-release hint is the most portable idea in the dimension: making the trigger edge an
explicit input matters precisely because a TUI without key release and a touch target without hover
disagree about it (see [`../../specs/ui/input.md`](../../specs/ui/input.md)). Static HTML keeps only
`:hover`/`:focus-within` — i.e. the tooltip trigger and nothing else.

### 6. Timing

The tooltip machine is four timers and one predicate, with a genuine skip-delay window.
[Warm-up][c-warmup] is `SH_ToolTip_WakeUpDelay` = 700 ms (`qcommonstyle.cpp:5391`), but only 20 ms
while the 2000 ms `SH_ToolTip_FallAsleepDelay` window (`qcommonstyle.cpp:5394`) from the previous
tooltip is still open. One ternary carries the whole "instant subsequent tooltips" and
toolbar-traversal behaviour (`qapplication.cpp:2756`):

```cpp
d->toolTipWakeUp.start(d->toolTipFallAsleep.isActive() ? 20 : wakeDelay, this);
```

Maximum display duration scales with content: `10000 + 40 * max(0, textLength - 100)` ms
(`qtooltip.cpp:167`), overridable per `showText` call and computed from the plain text when rich text
is in play. Soft hide is a 300 ms `hideTimer` that is deliberately _not_ restarted while already
active (`qtooltip.cpp:251`). [Cool-down][c-cooldown] is aggressive and asymmetric: `Wheel`,
`ActivationChange`, `KeyPress`, `KeyRelease`, `FocusIn`, `FocusOut` and all three mouse-button events
stop _both_ the fall-asleep and the wake-up timer (`qapplication.cpp:2648`), so the next tooltip pays
the full 700 ms again — while `Leave` stops only the wake-up timer.

Re-entry on the same provider is handled by mutation, not restart: `tipChanged()` compares text plus
widget plus dwell-rect containment, and when only the position changed, `reuseTip()` re-lays out the
existing label — the source comment says this "removes flickering" — rather than destroying and
recreating a top-level window.

Menu timing is separate and simpler: `SH_Menu_SubMenuPopupDelay` = 256 ms
(`qcommonstyle.cpp:5134`; the macOS style overrides it), stored in `QMenuPrivate::DelayState`
(`qmenu_p.h:337`) keyed by action, so re-arming for the same action is a no-op; a left-button press
or a context-menu event while that timer runs fires the submenu immediately; and the sloppy timer is
`SH_Menu_SubMenuSloppyCloseTimeout` = 1000 ms.

**Algorithm.**

```text
IDLE   --hover-->                  ARMED(wake = warm ? 20 : 700)
ARMED  --wake fires-->             if (target window or an ancestor is active, or WA_AlwaysShowToolTips):
                                       send QHelpEvent(ToolTip)
                                   if accepted: SHOWN; start fallAsleep(2000),
                                                expire(10000 + 40*max(0, len - 100))
SHOWN  --leave / move out of rect-->  SOFT_HIDE(300)
SHOWN  --press / wheel / key / focus / activation--> IDLE immediately
SHOWN  --same provider, new text or position--> reuse in place; restart expire; stop hideTimer
any of {wheel, activation, key, focus, button} --> clear the warm window
warm := fallAsleep.isActive()
```

**Where the behavior lives.** Three owners: arming and the wake/sleep pair in `QApplicationPrivate`
(global singleton timers), the expire and soft-hide timers on the `QTipLabel` singleton, and the
numeric policy in `QStyle` as style hints. The submenu delay lives in `QMenuPrivate`.

**Degradation.** Static HTML has no timers: the dimension collapses to `:hover` plus a CSS
transition delay, which cannot express the warm window. A TUI keeps everything, since a frame loop
can drive four timers. A headless recording target can assert all of it _if and only if_ the clock is
injected — this subject's use of `QBasicTimer` against the real event loop is exactly why
`tst_qtooltip` has to `qWait(1500)` with a comment (`tst_qtooltip.cpp:108`) explaining that the wait
must exceed 300 ms but stay under 10000 ms. INFERENCE: taking a monotonic tick as an explicit
parameter of the state-machine step is what makes that assertion deterministic
([`../../specs/ui/state-machines.md`](../../specs/ui/state-machines.md)).

### 7. Interactive hover / menu-aim

`QMenuSloppyState` (`qmenu_p.h:91`) is the entire mechanism, and it is a **counter-based** menu-aim
rather than a region-based one. Its state: the opening action's rect, the submenu pointer, the
previous mouse point, an origin action, a reset action, a parent link forming a chain up the menu
hierarchy, a timer, and a discarded-move counter. The step function returns one of three values
(`qmenu_p.h:120`) — `EventIsProcessed` (swallow), `EventShouldBePropagated` (let the hover change the
highlight), `EventDiscardsSloppyState` (kill the submenu) — and the caller decides what to do with
it (`qmenu.cpp:3477`).

Direction is tested by comparing slopes from the previous and current pointer positions to the
submenu's two near-side corners. `slope()` (`qmenu_p.h:149`) returns the sentinel `9999` for a
vertical segment; `checkSlope()` (`qmenu_p.h:157`) flips the comparison direction on a `wantSteeper`
argument. Wrong-direction moves are counted, not punished (`qmenu_p.h:225-233`):

```cpp
if (m_uni_dir_discarded_count >= m_uni_dir_fail_at_count && !rightDirection) {
    m_uni_dir_discarded_count = 0;
    return EventDiscardsSloppyState;
}

if (!rightDirection)
    m_uni_dir_discarded_count++;
else
    m_uni_dir_discarded_count = 0;
```

There is also a purely combinatorial fallback: if the hovered action is more than one list index away
from the origin action, "return to origin" is disabled — list distance standing in for geometry.

The surprise is the default. `SH_Menu_SubMenuUniDirection` is `false` in `QCommonStyle`
(`qcommonstyle.cpp:5142`) and is overridden to `true` by the macOS style
(`qmacstyle_mac.mm:2556`); `SH_Menu_SubMenuUniDirectionFailCount` is `1`
(`qcommonstyle.cpp:5145`). So with the bundled non-macOS styles there is no direction heuristic at
all: sloppiness reduces to the 1000 ms timer plus a parent-hover keepalive, where `childEnter`
(`qmenu.cpp:807`) walks up the chain stopping timers. There is no [safe polygon][c-safe-polygon], no
pointer bridge, no trajectory extrapolation and no travel corridor between trigger and content —
there is none to cross, because the submenu is placed to overlap the parent by `PM_SubMenuOverlap`.

> [!WARNING]
> `SH_Menu_SloppySubMenus` is defined and defaulted to `true` (`qcommonstyle.cpp:5138`) but was not
> found to be read by `QMenu`, `QMenuBar` or any style file inspected here (`qmenu.cpp`,
> `qmenubar.cpp`, `qmenu_p.h`, `qmenubar_p.h`, `qcommonstyle.cpp`, `qfusionstyle.cpp`,
> `qstylesheetstyle.cpp`, `qstyle.cpp`, `qmacstyle_mac.mm`). This was a per-file check, **not** an
> exhaustive tree-wide search — the sparse checkout makes `git grep` prohibitively slow — so treat
> "dead hint" as a strong indication rather than a proven negative.

**Algorithm.**

```text
processMouseEvent(pos, hoveredAction, currentAction):
    parent?.stopTimer()
    if !enabled: return Propagate
    startTimerIfNotRunning()                     // 1000 ms escape hatch
    if !subMenu: reset(); return Propagate
    defer { firstMouse := false; previousPoint := pos }
    update resetAction; if |index(hovered) - index(origin)| > 1: useResetAction := false
    if openingActionRect.contains(pos):
        startTimer(); return (currentAction == menuAction ? Processed : Propagate)
    if uniDirectional && !firstMouse && hovered != origin:
        nearTop := LTR ? sub.topLeft    : sub.topRight
        nearBot := LTR ? sub.bottomLeft : sub.bottomRight
        ok := (movedUp   && checkSlope(slope(prev, nearTop), slope(pos, nearTop), nearTop.y < pos.y))
           || (movedDown && checkSlope(slope(prev, nearBot), slope(pos, nearBot), nearBot.y > pos.y))
        if !ok && discarded >= failCount: discarded := 0; return DiscardsSloppyState
        discarded := ok ? 0 : discarded + 1
    return selectOtherActions ? Propagate : Processed

on timeout:
    if the pointer really is inside the menu (checked against frameGeometry when enter events
       were not received) and the current action still matches: do nothing
    else: hide the submenu and restore the reset action
```

> [!NOTE]
> The precise intent of `checkSlope`'s `wantSteeper` argument — why the comparison direction flips
> depending on whether the submenu corner is above or below the pointer — is reported here as
> observed code. No comment or test explaining it was found, and it was not derived algebraically.

**Where the behavior lives.** Library code: one class in a private header, driven entirely from
`QMenu::mouseMoveEvent` / `enterEvent` / `leaveEvent` / `timerEvent`. No platform involvement.

**Degradation.** The cost in whole cells is `O(1)` per pointer move — four subtractions, four
divisions, four comparisons, one counter — and it works on integer coordinates directly
(`qFuzzyIsNull(dx)` becomes `dx == 0`). INFERENCE: at one-cell resolution the corner slopes inside a
20×10-cell menu take only a few dozen distinct values, and with the shipped fail count of 1 a single
sideways cell step is enough to discard the sloppy state — so a cell-grid port should keep the
failure **counter** (raising the tolerance) and treat the angular precision as the part that does not
survive quantization. Note that Qt's own non-macOS default — the timer plus the parent-hover
keepalive — is already that configuration. On Android there is no hover, so the dimension is inert
and submenus must open on tap. Static HTML can express nested `:hover` keepalive but neither the
timer nor the direction test.

### 8. Dismissal

Dismissal is a consequence of the routing model. Because every mouse event is retargeted to the top
of the popup stack, a menu's own `mousePressEvent` (`qmenu.cpp:2891`) sees clicks that landed
anywhere on screen. It first offers the event up the caused chain via `mouseEventTaken()`
(`qmenu.cpp:1313`), which re-sends a coordinate-translated copy to whichever ancestor menu or
menubar rect contains the point; only if nobody claims it does it call `hideUpToMenuBar()`
(`qmenu.cpp:518`).

**Press dismisses; release activates** — and release activates only if `QMenuPrivate::mouseDown == this`
(`qmenu.cpp:49`, `:2921`), a process-global static that prevents a release from triggering in a menu
that was not the one pressed. The `hasMouseMoved` gate (`qmenu.cpp:1573-1580`) makes a click with a
still cursor _close_ rather than trigger:

```cpp
return motions > 6 ||
    QApplication::startDragDistance() < (mousePopupPos - globalPos).manhattanLength();
```

That is what stops a context menu popped up under an already-pressed pointer from firing whatever
item lands there; the regression test (`tst_qmenu.cpp:2129`, QTBUG-128359) connects `QFAIL` to every
action's `triggered` signal and then clicks without moving.

Escape closes one level and hands focus back to the menubar; `Left` closes a submenu; the
`QKeySequence::Cancel` branch (`qmenu.cpp:3327`) also matches `Qt::Key_Back` under keypad navigation.
Application deactivation and screen-orientation change call `closeAllPopups()`
(`qapplication.cpp:2641`, `qguiapplication.cpp:995`). Showing any non-popup, non-tool top-level closes
all popups (`qwidget.cpp:8057`). A disabled popup closes on any button event. Wheel events aimed at
other windows are silently dropped while a popup is open (`qapplication.cpp:2818`). An anchor that is
hidden or removed is _not_ handled at all.

The subtlest piece is **mouse-press replay**: when the last popup closes, the cursor was outside its
geometry, and `WA_NoMouseReplay` is not set, `QApplicationPrivate::replayMousePress` is armed
(`qapplication.cpp:3356-3363`) and the press is re-posted — via `postEvent`, specifically so a
`QMenu::exec()` nested loop can unwind first — to the widget under the cursor
(`qwidgetwindow.cpp:590`), gated by `QPlatformIntegration::ReplayMousePressOutsidePopup`.
`QMenu::setNoReplayFor(button)` is how a menu button avoids being re-opened by its own dismissing
click. As noted in the Overview, this whole path sits inside the `if (popupGrabOk)` branch.

**Algorithm.**

```text
menu press:
    if aboutToHide or mouseEventTaken(e): return
    mouseEventTaken: walk causedPopup.widget upward; for each ancestor whose local rect contains
                     the global point, re-send a translated copy and return true;
                     if the walk reaches the top with no hit, call sloppyState.leave()
    otherwise: if (pos null but globalPos non-null)     // XCB multi-screen workaround
                  or outside rect
                  or !hasMouseMoved:
                   set WA_NoMouseReplay if inside noReplayFor; clear syncAction; hideUpToMenuBar()
hideUpToMenuBar: walk the caused chain hiding each non-torn-off menu; clear the menubar's current action
```

**Where the behavior lives.** Three cooperating layers: `QGuiApplicationPrivate::processMouseEvent`
plus `QWindowPrivate::forwardToPopup` (QtGui); `QWidgetWindow::handleMouseEvent` plus
`QApplicationPrivate::closePopup` (QtWidgets kernel); `QMenu::mousePressEvent` / `mouseEventTaken`
(widget). Tooltip dismissal lives entirely in one event filter.

**Degradation.** Without a native grab, events outside the surface are simply never seen — which in a
single-surface toolkit means an outside press is always an in-surface event, and therefore an easier
case than the one this subject solves. The press/release asymmetry and the `hasMouseMoved` gate both
survive verbatim in cells, and both matter _more_ there, because a terminal's SGR-1006 stream
delivers press and release as distinct records and a menu popped at the cursor always has an item
under it. With no key release, Escape-to-dismiss must key off press — which is already the design
here. The Android system Back key maps onto the same `QKeySequence::Cancel` branch. Mouse-press
replay is unnecessary in one surface, but its _inverse_ is required: deciding, at dismissal time,
whether the dismissing click also acts on what lies beneath it. This subject's answer is a per-popup
`noReplayFor` rect — a plain value.

### 9. Focus

Qt states outright that popups are not focus-handled by the window system, and does it by hand.
`QApplicationPrivate::openPopup` (`qapplication.cpp:3395`): if the popup has a focus widget, focus it
with `Qt::PopupFocusReason`; otherwise, if this is the _first_ popup, send a synthetic `FocusOut` to
the current focus widget **without actually moving focus**. The underlying widget therefore remains
`focusWidget()` but stops receiving keys, because the keyboard was grabbed and
`QWidgetWindow::handleKeyEvent` (`qwidgetwindow.cpp:696`) routes to `keyboardGrabber()` first, then to
`activePopupWidget()->focusWidget()` or the popup itself.

On close (`qapplication.cpp:3345`), focus goes to the next remaining popup if there is one, otherwise
back to the active window's focus widget; and if the stack is back down to one, the grab is re-taken
for the new top.

`QMenu` itself normally holds no focus widget: keyboard selection calls
`q->setFocus(Qt::PopupFocusReason)` only when the highlighted action has no embedded widget
(`qmenu.cpp:744`), while `QWidgetAction` widgets take real focus with `TabFocusReason`. Containment
rather than trapping: `Tab`/`Backtab` are rewritten to `Down`/`Up` (`qmenu.cpp:3102`) and
`focusNextPrevChild` is overridden to re-dispatch as a key event (`qmenu.cpp:3079`), so focus cannot
leave — but there is no ring, no first/last sentinel and no restoration bookkeeping beyond
`active_window->focusWidget()`.

The four roles stay firmly distinct: a tooltip is `Qt::ToolTip`, never focusable, never in the popup
list, never activated (and its `ObjectShow` accessibility event is suppressed, `qwidget.cpp:8090`); a
menu is `Qt::Popup` — grabbing, exclusive, non-modal; a combobox popup is a `Qt::Popup` whose _view_
takes focus; a dialog is an ordinary window with real [modality][c-modality]. Pointer- versus
keyboard-opened differs only in preselection: opening a submenu via `Right`/`Enter` calls
`popupAction(action, 0, activateFirst = true)`, which highlights the submenu's first action, whereas
hover-opening does not.

**Algorithm.**

```text
openPopup(p):
    activatePopup(p->windowHandle())
    if popupCount() == 1: grabForPopup(p)
    if p->focusWidget():          focus it with PopupFocusReason
    else if popupCount() == 1:    send FocusOut(PopupFocusReason) to the current focus widget

closePopup(p):
    remove from popup_list
    if none remain: maybe arm replayMousePress; ungrab mouse then keyboard (transferring back to any
                    pre-existing grabber); restore focus to active_window->focusWidget()
    else:           focus the new top popup's focus widget; if the stack is now size 1, re-grab
```

**Where the behavior lives.** `QApplicationPrivate` (widget-level focus and grabs) over
`QGuiApplicationPrivate` (the window stack); key routing in `QWidgetWindow`.

**Degradation.** With no OS window there is no window activation and no grab, so what is left is
exactly the part this subject hand-rolls: an explicit stack, an explicit "who receives keys" pointer,
and explicit save/restore of the pre-open focus. That is a value-semantics design already and
translates directly into a [focus scope][c-focus-scope] over an index. With no key release nothing
here breaks — every focus decision is made on press. Rewriting Tab to arrow keys is a good default
for a cell grid, where Tab may be consumed by the host terminal.

### 10. Layering & portals

Every popup is a real top-level OS window; there is no portal, no [top layer][c-top-layer] and no
z-index, because the window manager owns stacking and Qt only calls `raise()`. Semantics reach the
window manager as attributes rather than as a type: every `QMenu` sets
`WA_X11NetWmWindowTypePopupMenu` at construction (`qmenu.cpp:164`) and swaps to
`WA_X11NetWmWindowTypeDropDownMenu` at popup time when the top cause is a `QMenuBar`
(`qmenu.cpp:2366`); torn-off menus set `WA_X11NetWmWindowTypeMenu` and become `Qt::Window | Qt::Tool`.
Transient parenting is resolved with a three-step fallback — native parent widget's window, existing
transient parent, causing widget's window (`qmenu.cpp:625`) — and applied on Show.

The overlay "tree" is actually **two structures kept in sync by hand**:

- `QGuiApplicationPrivate::popup_list` (`qguiapplication.cpp:186`), a `QWindowList` used as a stack,
  maintained from both `QWindowPrivate::setVisible` (for any `Qt::Popup` window, including non-widget
  ones) and `QWidgetPrivate::show_helper` / `hide_helper`;
- `QMenuPrivate::causedPopup` plus `calcCausedStack()` (`qmenu.cpp:309`), the _semantic_ parent chain
  — which is not the same set, because it walks through torn-off menus, and those are `Qt::Tool`
  windows absent from `popup_list`.

Public API is precisely two things: the `Qt::Popup` / `Qt::ToolTip` window flags, and
`QApplication::activePopupWidget()`. Everything else — `popup_list`, `popupGrabOk`, `qt_popup_down`,
`active_popup_on_press`, `popup_closed_on_press`, the caused stack — is private, and several are
file-scope globals.

**Algorithm.**

```text
activatePopup(w):     if !w->isVisible(): return
                      popup_list.removeOne(w); popup_list.append(w)
activePopupWindow():  popup_list.isEmpty() ? null : popup_list.last()
closePopup(w):        popup_list.removeAll(w) != 0
closeAllPopups():     loop at most 1024 times: activePopupWindow()->close()
```

**Where the behavior lives.** QtGui kernel owns the stack; QtWidgets owns the grab and focus policy;
the window manager owns stacking and shadows; X11 semantics are carried as widget attributes
translated by the XCB plugin (see [`../window-system-integration/index.md`](../window-system-integration/index.md)).

**Degradation.** In a single-surface toolkit, "later in the display list" replaces the window manager
and the popup stack becomes the paint order — an explicit array of open overlays, painted in order,
hit-tested in reverse. The `removeOne`-then-`append` idiom is exactly the right primitive for
"reopen an already-open overlay" and costs nothing. The two-structure split is the real lesson here:
"close down to depth N" walks the stack while "who triggered me" walks the causes, and torn-off or
detached overlays make the two diverge — this subject maintains both, by hand, and keeps them in
sync at every call site.

### 11. Modality

Popups are explicitly _exempt_ from modality rather than being a weak form of it.
`windowNeverBlocked()` (`qapplication.cpp:2202`) returns true for the active popup window and for any
popup window when no popup widget is active, and `tryModalHelper()` (`qapplication.cpp:2214`) returns
true unconditionally whenever a popup is open. Both `Qt::Popup` and `Qt::ToolTip` are skipped by
`updateBlockedStatus` (`qguiapplication.cpp:858`). A menu can therefore legally open on top of, and
over, a modal dialog.

Exclusivity is bought with the grab instead — and the grab can fail, as shown in the Overview, in
which case the software re-routing carries the whole model. That re-routing exists at two levels:
`QWindowPrivate::forwardToPopup` clones the pointer event, remaps every event point, and treats the
popup as having handled it only if it _accepted_ it; `QWidgetWindow::handleMouseEvent`
(`qwidgetwindow.cpp:509`) retargets to `activePopupWidget()->childAt(mapped)` with **no acceptance
check at all**. There is no scrim, no dim, no click-through mode and no accessibility modal bit; open
and close are signalled to assistive technologies as `QAccessible::PopupMenuStart` /
`PopupMenuEnd` events instead.

**Algorithm.**

```text
forwardToPopup(event):
    p := activePopupWindow(); if p == this: return null
    pointer event: clone; for each point set position and scenePosition to
                   p->mapFromGlobal(globalPosition); sendSpontaneousEvent(p, clone);
                   propagate acceptance back; return p only if accepted
    key event:     sendSpontaneousEvent(p, event); return p

guard in processMouseEvent:
    forward only when (!popup_closed_on_press || type == MouseButtonRelease)
    remember active_popup_on_press across the press so a drag-release stays with the popup
    that saw the press
```

**Where the behavior lives.** Grab: QtWidgets kernel → `QWindow::setMouseGrabEnabled` /
`setKeyboardGrabEnabled` → platform plugin → X server (`xcb_grab_pointer` / `xcb_grab_keyboard`,
`GRAB_MODE_ASYNC`, `qxcbwindow.cpp:2354`). Routing: QtGui kernel and QtWidgets kernel, duplicated.

**Degradation.** This is where the subject speaks most directly to a toolkit without OS windows. The
same code path runs with `popupGrabOk == false`, so a grab is demonstrably an _enhancement over_
in-process routing rather than the mechanism itself — with the one correction that in Qt the flag
additionally gates press replay (`qapplication.cpp:3356-3363`), so a port that drops the grab must
decide the replay/pass-through question explicitly instead of inheriting it. The portable half is the
software one: retarget every pointer event to the top of the overlay stack, remap coordinates once at
the routing boundary, and let acceptance decide consumption. TUI, GUI and Android can all do that;
static HTML can do none of it.

### 12. Adaptive presentation

The decision layer is the platform _theme_ plus a scatter of per-platform `#ifdef`s — never the
widget, never the application. Three adaptations exist.

1. **Native replacement.** A `QMenu` can be backed by a `QPlatformMenu` from
   `QPlatformTheme::createPlatformMenu()` (`qmenu.cpp:183`), in which case every `actionEvent`
   mirrors the action into a platform menu item (`qmenu.cpp:3579`) and the widget rendering path is
   bypassed entirely. `QMenuBar` drives this for the macOS/Android/DBus global menu
   (`qmenubar.cpp:677`), and `QComboBox` has an independent macOS-only native popup handed a target
   rect and a current item (`qcombobox.cpp:2649`).
2. **Touch.** `QWidgetWindow::handleTouchEvent` (`qwidgetwindow.cpp:682`) _ignores_ touch outright
   while any popup is open, so `QGuiApplication` synthesizes mouse events which the popup re-routing
   then handles. A popup is, by construction, a mouse-only surface fed synthetic mice. That is the
   whole touch story: no long-press-for-tooltip, no popover-to-sheet, no touch-target growth.
3. **Boundary policy.** Whether a menu may cover the taskbar is `QPlatformTheme::UseFullScreenForPopupMenu`
   (`qstyle.cpp:2418`). Screen rotation closes all popups.

There is no teaching-tip concept and no keyboard-driven relocation.

**Algorithm.** Not applicable — the adaptations are discrete substitutions, not an algorithm. The one
general shape is `if (the platform theme has a native implementation) delegate wholesale, else run
the widget implementation`, with the two paths sharing only the `QAction` model.

**Where the behavior lives.** `QPlatformTheme` (native menu/menubar factories, theme hints),
`QWidgetWindow` (touch suppression), `QComboBox` / `QMenuBar` (per-widget opt-in).

**Degradation.** Android is the target this subject serves worst: with no hover, the answer here is
"synthesize a mouse", which yields a tooltip that can never appear and a submenu that opens on
tap-and-hold only incidentally. A backend-neutral toolkit has to own that decision at the _view_
layer instead, because one view serves a TUI (hover yes, no key release) and Android (no hover, Back
key, keyboard inset) simultaneously. The one transferable idea is the clean seam: a single
"is there a native surface for this?" question answered once at open time, with both paths driven off
the same item model.

### 13. Accessibility

`QMenu` maps to `QAccessibleMenu` with role `QAccessible::PopupMenu` (`qaccessiblemenu.cpp:67`);
children are one `QAccessibleMenuItem` per `QAction`, created lazily and registered in the global
interface table. `childAt(x, y)` (`qaccessiblemenu.cpp:48`) funnels through `QMenu::actionAt`
(separators excluded). Parent resolution is unusual: it does not use the caused stack but searches the
menu action's `associatedObjects()` for a `QMenu` or `QMenuBar` that actually contains that action
(`qaccessiblemenu.cpp:78`) — the accessibility tree is rebuilt from action associations.

Hover-to-accessibility bridging is explicit: `activateAction(action, Hover)` fires a
`QAccessible::Focus` event carrying the child index (`qmenu.cpp:1497`), and popup/hide fire
`PopupMenuStart` (`qmenu.cpp:2594`) / `PopupMenuEnd` (`qmenu.cpp:2725`). The tooltip maps to
`QAccessibleDisplay` with role `QAccessible::ToolTip` — decided by class-name string matching in
`QAccessibleWidgetFactory` (`qaccessiblewidgetfactory.cpp:147`) — and its `ObjectShow` event is
deliberately suppressed (`qwidget.cpp:8090`) with a comment that tooltips are otherwise read aloud
twice in MS Narrator. An announcement policy encoded as a one-line exclusion.

Tooltip content may be rich text but is never interactive: the label hides on any press and on
leaving the dwell rect, and it enables mouse tracking specifically so that entering it dismisses it.
There is no WCAG 1.4.13 affordance — the tip is not hoverable, not Escape-dismissable (on macOS any
non-modifier key hides it, and `tst_qtooltip.cpp:65` asserts the _opposite_ on other platforms), and
the 700 ms / 10 s timings are reachable only by subclassing `QStyle`, not through public API.

**Algorithm.** Not applicable — this is interface adaptation, not an algorithm.

**Where the behavior lives.** The QtWidgets `accessible/` mapping onto `QAccessible`, which the
platform bridges (UIA, AT-SPI, NSAccessibility) consume.

**Degradation.** A terminal grid can honestly expose almost none of this — there are only glyphs.
What a primitive nevertheless owes, and what is a plain value on every target, is: (a) an explicit
open/close event pair equivalent to `PopupMenuStart` / `PopupMenuEnd`, emitted by the state machine
and therefore assertable on a recording canvas; (b) a stable "this overlay describes that anchor"
relation; (c) a current-item index. Role names, description-versus-label and the modal bit belong to
the semantic component above the primitive. The tooltip show-suppression is the useful precedent: a
primitive should let a component say "do not announce", because double announcement is a real defect.

### 14. Animation

Placement emits exactly two bits of geometry metadata, and does so specifically to drive animation:
`hGuess` in `{LeftScroll, RightScroll}` and `vGuess` in `{UpScroll, DownScroll}`, derived _after_ the
final geometry by comparing the placed rect's horizontal or vertical centre against either the mouse
(the `snapToMouse` case) or the causing widget (`qmenu.cpp:2542`). Which bit is used depends on the
trigger: a `QMenu` cause uses `hGuess` only, a `QMenuBar` cause uses `vGuess` only, and no cause ORs
both. This is the [transform-origin][c-transform-origin] equivalent, computed from the same numbers
the clamp produced.

A second piece of state, `doChildEffects` (`qmenu_p.h:507`, gated at `qmenu.cpp:2561`), implements
"animate the first surface in a chain, then show the rest instantly": a menu reads the flag off its
cause and clears it there. There are explicit anti-glitch calls — `qFadeEffect(nullptr)` /
`qScrollEffect(nullptr)` to kill a running effect when a menu is hidden mid-animation
(`qmenu.cpp:768`) — and `QTipLabel::hideTipImmediately` calls `close()` with a comment that it is done
to trigger `QEvent::Close`, which stops the animation (`qtooltip.cpp:257`). There is no
reposition-during-animation (geometry is final before the effect starts), no spring model, and no
reduced-motion query; the effect flags come from `QPlatformTheme` UI-effect bits.

**Algorithm.**

```text
after setGeometry(pos, size):
    hGuess := isRightToLeft ? LeftScroll : RightScroll
    if (snapToMouse && pos.x + w/2 compares against mouse.x)
       or (cause is a QMenu && pos.x + w/2 compares against cause.x): flip hGuess  // mirrored for RTL
    vGuess := DownScroll
    if (snapToMouse && pos.y + h/2 < mouse.y)
       or (cause is a QMenuBar && pos.y + w/2 < causeGlobalY): vGuess := UpScroll
    if UI_AnimateMenu and doChildEffects:
        fade, or scroll with (cause is a menu ? hGuess : vGuess), or (no cause) hGuess|vGuess
```

> [!WARNING]
> The vertical guess at `qmenu.cpp:2558` reads `pos.y() + size.width() / 2` — width mixed into a
> vertical comparison. It survives because the value only picks an animation direction, which is
> itself the argument for emitting the side as a checked value rather than re-deriving it.

**Where the behavior lives.** Library code (`qeffects_p`), fed by placement in `QMenuPrivate::popup`;
the enabling flags come from `QPlatformTheme`.

**Degradation.** The design lesson survives every target: placement should _return_ a small
side/origin descriptor alongside the rect, because the styling and animation layers cannot re-derive
it without redoing the clamp. In cells there is no transform, but the same two bits can drive a
row-by-row reveal or nothing at all — and a recording canvas can assert the bits even when no
animation is played.

### 15. State architecture

Three architectures coexist in one subject.

1. **Process-global mutable singletons doing cross-object protocol.** `QMenuPrivate::mouseDown` (a
   `static QMenu *`, `qmenu.cpp:49`), `qt_popup_down` / `qt_popup_down_closed`
   (`qwidgetwindow.cpp:29`), `popupGrabOk`, `QApplicationPrivate::replayMousePress`,
   `QGuiApplicationPrivate::popup_list` / `active_popup_on_press` / `popup_closed_on_press`,
   `QTipLabel::instance`, `qt_last_mouse_receiver`, `qt_button_down` — several of them file-scope
   globals exported across translation units (`extern QWidget *qt_button_down`).
2. **One genuine finite state machine.** `QMenuSloppyState`, whose transition function takes
   (point, hovered action, current action) and returns an explicit three-valued enum for the caller to
   act on. It is the one piece of this subject that is testable without a window.
3. **Ad-hoc bitfields.** Twelve one-bit flags on `QMenuPrivate` (`qmenu_p.h:492`).

Reentrancy is handled with RAII sentinels bolted on rather than by design: `QSetValueOnDestroy`
(`qmenu_p.h:76`), `ResetOnDestroy` (`qmenu.cpp:852`), a `QScopeGuard` for `popupScreen`, a
purpose-built `Reposter` `QObject` that intercepts `QEvent::DeferredDelete` while a nested event loop
runs the "flash the triggered item" animation (`qmenu.cpp:556`), an `activationRecursionGuard` bool,
and a `QPointer` guard after essentially every signal emission. All of it exists because
`QMenuPrivate::exec` spins a nested `QEventLoop` (`qmenu.cpp:2664`), so user code can delete the menu
from inside a handler — and the test suite covers exactly that (`tst_qmenu.cpp:2035`,
`deleteWhenTriggered`).

**Algorithm.** Not applicable, but the shape of the good part is:
`MouseEventResult step(state&, point, action, action)` with `MouseEventResult` in
`{Processed, Propagate, Discard}` — the caller performs the side effects
(`setCurrentAction`, or reset plus hide). Effects are returned, not performed.

**Where the behavior lives.** Library code throughout, with the caveats above about file-scope
globals.

**Degradation.** `QMenuSloppyState` would survive a `@nogc`, value-semantics port almost verbatim:
its state is two points, one rect, two indices, three small counters and a timer id — everything POD
except the `QMenu *` / `QAction *` pointers, which become widget/item indices into a flat arena. The
returned-effect enum is the right shape for a `@safe pure` step function. Categories (1) and (3) do
not port: the popup stack must be an explicit array owned by the frame. And note _why_ the reentrancy
apparatus exists here — a nested event loop inside `exec()` — which is a structural property of this
subject's blocking API rather than of overlays as such.

### 16. Shared infrastructure

Exactly one thing is genuinely shared, and it is shared by _inheritance of a window flag_ rather than
by a base class: setting `Qt::Popup` buys the stack, the grab, the event re-routing, the modality
exemption and the focus hand-off. `QMenu` (`qmenu.cpp:1763`), `QComboBoxPrivateContainer`
(`qcombobox.cpp:474`) and `QWhatsThis` all obtain it that way.

Everything else is duplicated:

| Concern   | Copies in this subject                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| --------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Placement | five — `QMenu` (flip vertical, clamp horizontal, submenu-overlap resolution, scroll fallback); `QComboBox` (below-if-it-fits, else above-if-it-fits, else the side with more room truncated, plus a separate `usePopup` mode centring the current item, `qcombobox.cpp:2782`); `QPushButton` (below-else-above, RTL by right-aligning, **no clamp at all**, `qpushbutton.cpp:589`); `QToolButton` (four hand-written RTL branches plus a bolted-on QTBUG-118695 force-inside-screen fixup, `qtoolbutton.cpp:693`); `QTipLabel` + `QBalloonTip` |
| Timing    | three — tooltip wake/sleep in `QApplicationPrivate`; submenu delay in `QMenuPrivate::DelayState`; `QComboBox`'s `blockMouseReleaseTimer` + `popupTimer` to suppress the release that opened the popup                                                                                                                                                                                                                                                                                                                                          |
| Dismissal | three — menus (grab + popup stack); tooltips (application-wide event filter on a singleton); comboboxes (their own `eventFilter` on the view, `qcombobox.cpp:728`, plus a `mousePressEvent` calling `hidePopup`)                                                                                                                                                                                                                                                                                                                               |
| Typeahead | two — `QMenu`'s own 2000 ms search buffer with a per-character match-count scoring loop (`qmenu.cpp:3361`); `QComboBox` delegates to the item view                                                                                                                                                                                                                                                                                                                                                                                             |

**Algorithm.** What is _truly_ common across those five surfaces, and what one anchored-overlay
primitive could own: (1) the anchor value plus a size→point placement closure evaluated after content
is final; (2) flip/clamp against a padded boundary rect, returning rect + side + arrow offset;
(3) an ordered stack with "open (dedup by identity)" and "close down to depth N"; (4) outside-press →
close-to-depth, with an explicit no-replay rect for the trigger; (5) the open/close event pair;
(6) derivation of the animation origin from the placement result.

What must stay apart, on this subject's own evidence: hover timing (tooltips only — a menu must never
wait 700 ms); submenu aim (menus only — a tooltip has no travel corridor); the
selection/current-item/typeahead model (menus and comboboxes already disagree); "suppress the release
that opened me" (button-triggered surfaces only); and interactivity of content (a tooltip must never
be interactive, and here that is enforced by `QTipLabel` hiding on any press).

**Where the behavior lives.** Nowhere central. The absence of a shared base _is_ the architecture:
this subject shares the **transport** (window flag, stack, grab) and shares none of the **policy**.

**Degradation.** This dimension is unaffected by target capabilities. What it shows is what happens
when transport is shared and policy is not: five placement implementations, of which one does no
clamping at all, one needed a bug-fix clamp bolted on, and one desynchronizes its arrow from its
anchor at a screen edge — plus a dismissal model that a tooltip cannot use, and consequently no way
to build a hover-triggered _interactive_ surface out of either half. Sharing the placement **result
type** — rect, side, arrow offset, animation origin — is what would collapse the five into one; see
[`./comparison.md`](./comparison.md) and [`./proposal.md`](./proposal.md).

---

## Strengths

- The grab/stack/re-route triad is factored so that a single window flag makes any widget a
  light-dismissable overlay; third-party widgets inherit correct behaviour without writing any of it.
- `QMenuSloppyState` is a real finite state machine with an explicit three-valued transition result,
  effects returned rather than performed, and `O(1)` allocation-free state — the one piece of this
  subject that would port unchanged into a `@nogc` value-semantics toolkit.
- Cheap, high-value correctness guards: `hasMouseMoved` (a menu popped under a pressed cursor cannot
  self-trigger), `mouseDown` identity (a release only activates in the menu that saw the press),
  `noReplayFor` (a menu button is not re-opened by its own dismissing click), and the submenu
  first-action alignment offset (items line up, not borders).
- The tooltip warm window — 20 ms while the 2000 ms fall-asleep timer runs — delivers warm-up,
  cool-down and toolbar traversal from two timers and one ternary.
- `QHelpEvent` inverts tooltip provision: the framework _asks_ the widget for text at a position
  rather than requiring per-region registration, so per-cell tooltips in an item view cost nothing
  structurally.
- Placement emits explicit direction metadata (`hGuess` / `vGuess`) for the animation layer instead of
  forcing it to re-derive geometry, and `doChildEffects` prevents a cascade of animations down a
  submenu chain.
- Grab failure is anticipated and survivable: `popupGrabOk` is recorded, not asserted, and the XCB
  backend has an explicit `canGrab()` escape hatch for debugging.
- Reentrancy under nested event loops is handled defensively and thoroughly, with test coverage for
  deleting the menu from inside a triggered handler.

## Weaknesses

- Five separate placement implementations with five different fallback ladders;
  `QPushButtonPrivate::adjustedMenuPosition` does no clamping, `QToolButtonPrivate::positionMenu`
  needed a bolted-on QTBUG-118695 fixup, and `QBalloonTip`'s edge clamp moves the window without
  moving the arrow, so near a screen edge the arrow stops pointing at the anchor.
- Zero anchor tracking: geometry is sampled once at `popup()` and never revisited. An anchor that
  moves, scrolls away, resizes or is destroyed leaves the overlay where it was, and adding an action
  to a visible menu resizes it from the top-left with no re-clamp — so it can grow off-screen after
  being shown.
- Cross-object protocol through process-global mutable state (`mouseDown`, `qt_popup_down`,
  `qt_button_down`, `qt_last_mouse_receiver`, `popupGrabOk`, `replayMousePress`), which makes the
  model hard to reason about and hard to test in isolation.
- Menu-aim's direction test is off by default in `QCommonStyle` and enabled by the macOS style, so
  with the other bundled styles sloppy submenus reduce to a 1000 ms timer plus parent-hover keepalive;
  and `SH_Menu_SloppySubMenus` appears to be read by nobody (see the warning in dimension 7).
- Two entirely different dismissal architectures with no shared vocabulary, so a hover-triggered
  _interactive_ surface cannot be built from either.
- No accessibility timing story: tooltips are not hoverable, not Escape-dismissable outside macOS, and
  their delays are reachable only by subclassing `QStyle` — WCAG 1.4.13 is unmet by construction.
- Touch is handled by refusing it: `QWidgetWindow` ignores touch while a popup is open so synthetic
  mouse events take over, which means no long-press, no touch-sized targets and no hover-to-touch
  adaptation.
- `QMenu::exec()` spins a nested `QEventLoop`, which is the root cause of the whole reentrancy-guard
  apparatus and of platform-specific test skips (`tst_qmenu` skips `activeSubMenuPositionExec` on
  Android with "this hangs").
- No IME or virtual-keyboard avoidance anywhere in the placement math; `QComboBox` merely resets the
  input method rather than making room for it.

---

## Key design decisions and trade-offs

| Decision                                                                                                                                                                                               | Rationale                                                                                                                                                                                                                                                                                              | Trade-off                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Make the OS window flag the whole abstraction: `Qt::Popup` buys the stack, the grab, the modality exemption, the focus hand-off and the event re-routing, and there is no anchored-overlay base class. | Maximum reuse of the window system with minimum library surface — any widget becomes light-dismissable by changing one constructor argument, and third-party widgets get correct behaviour for free.                                                                                                   | Everything above transport had to be reinvented per widget: placement five times, dismissal three times, timing three times, with `QComboBox`, `QPushButton` and `QToolButton` each shipping a different (and differently defective) flip ladder. It also makes the model untestable without a window — most `tst_qmenu` cases need `qWaitForWindowExposed`, and several skip on Wayland because "creating grabbing popups requires real input events". |
| Treat the pointer/keyboard grab as an optional enhancement over software re-routing rather than as the mechanism.                                                                                      | Grabs fail — under `-nograb`, when another client holds one, and on compositors that do not permit them. Recording success in `popupGrabOk` and continuing means a popup still works entirely within the application's own windows.                                                                    | Two independent re-routing implementations now exist (`forwardToPopup` with an acceptance check, `QWidgetWindow::handleMouseEvent` without one), plus global cursor-tracking variables to compensate for the window manager's crossing events being wrong under a grab. Behaviour differs subtly depending on whether the grab succeeded — including whether the dismissing press is replayed — and that difference is invisible to the application.    |
| Implement menu-aim as a debounced direction counter with a hard timeout, and default the direction test off in `QCommonStyle`, enabling it in the macOS style.                                         | A counter plus a timer is `O(1)`, allocation-free, needs no polygon, and degrades to something usable when the direction signal is noisy. Making it opt-in per style follows platform convention.                                                                                                      | With the other bundled styles the behaviour is not menu-aim at all: the submenu stays open for a full second regardless of pointer direction, so brushing across a sibling item and pausing closes it. A fail count of `1` also makes the macOS path brittle. And the "return to origin" fallback uses list-index distance rather than geometry, which misbehaves when items have very different heights.                                               |
| Give tooltips a single shared widget and a single pair of application-global timers, and reuse that widget in place when only the text or position changes.                                            | One tooltip can ever be visible, so a singleton removes all arbitration; reuse instead of destroy-and-recreate is justified in the source as removing flicker while traversing cells; and a global warm window (20 ms instead of 700 ms) gives toolbar traversal for free with no per-widget grouping. | The singleton is a raw static pointer whose constructor deletes the previous instance, and dismissal is an application-wide event filter every event in the process passes through while a tooltip is visible. Because the timing lives in `QStyle` rather than in public API, applications cannot adjust 700 ms / 2000 ms / 10 s without subclassing a style — a direct WCAG 1.4.13 obstacle.                                                          |
| Defer menu positioning to a caller-supplied `std::function<QPoint(const QSize &)>` evaluated after `aboutToShow()`.                                                                                    | Menus are routinely populated inside their own `aboutToShow` handler, so any position computed from the pre-show `sizeHint` is wrong (QTBUG-78966). Passing a closure instead of a point lets the caller re-derive the anchor from the final size.                                                     | It is private API (`QMenuPrivate`) used by exactly one caller (`QToolButton`), so `QPushButton` and `QComboBox` still position against a stale or separately recomputed size, and the public `QMenu::popup(QPoint)` cannot express it at all.                                                                                                                                                                                                           |
| Exempt popups from modality entirely (`windowNeverBlocked`, `tryModalHelper`) and buy exclusivity with the grab.                                                                                       | A menu must be operable over a modal dialog, and the grab already guarantees no other widget sees input, so a second blocking mechanism would be redundant.                                                                                                                                            | A popup is invisible to the modality bookkeeping, so there is no scrim, no click-through policy and no accessibility modal bit; and once the grab is gone (or failed) nothing but the software routing enforces exclusivity.                                                                                                                                                                                                                            |

---

## Sources

Primary sources, all at the pinned revision `d0787745aa43e5baf49de876f917946df6aceca5`:

- [`src/widgets/widgets/qmenu.cpp`][qmenu-cpp] — `QMenuPrivate::popup` ([:2307][menu-popup-fn],
  placement block [:2396][menu-desktopframe], [:2467][menu-snap], [:2491][menu-flip], submenu overlap
  [:2512][menu-suboverlap]), `updateActionRects` ([:338][menu-actionrects]),
  `hasMouseMoved` ([:1573][menu-hasmoved]), `mouseEventTaken` ([:1313][menu-eventtaken]),
  `hideUpToMenuBar` ([:518][menu-hideupto]), `calcCausedStack` ([:309][menu-caused]),
  animation guesses ([:2542][menu-guess], [:2558][menu-guess-typo]),
  `internalDelayedPopup` ([:3637][menu-submenu-anchor]).
- [`src/widgets/widgets/qmenu_p.h`][qmenu-p-h] — `QMenuSloppyState` ([:91][sloppy-class]),
  `MouseEventResult` ([:120][sloppy-result]), `slope` ([:149][sloppy-slope]),
  `checkSlope` ([:157][sloppy-checkslope]), `processMouseEvent` ([:164][sloppy-process],
  counter [:225][sloppy-counter]), `PositionFunction` ([:275][position-function]),
  `QMenuCaused` ([:402][menu-caused-type]), `DelayState` ([:337][delay-state]).
- [`src/widgets/kernel/qapplication.cpp`][qapp-cpp] — `grabForPopup` ([:3331][grab-for-popup]),
  `closePopup` / replay arming ([:3345][close-popup], [:3356][replay-arm]),
  `openPopup` ([:3395][open-popup]), tooltip arming ([:2749][tooltip-arm], warm ternary
  [:2756][tooltip-warm]), cool-down resets ([:2648][tooltip-cooldown]),
  `windowNeverBlocked` ([:2202][never-blocked]), `tryModalHelper` ([:2214][try-modal]).
- [`src/widgets/kernel/qtooltip.cpp`][qtooltip-cpp] — `restartExpireTimer` ([:167][tip-expire]),
  `hideTip` ([:251][tip-hide]), `setTipRect` ([:263][tip-rect]),
  `eventFilter` ([:283][tip-filter], press/wheel cases [:322][tip-dismiss]),
  `placeTip` ([:346][tip-place], cursor size [:376][tip-cursor]),
  `tipChanged` ([:402][tip-changed]), `showText` reuse ([:439][tip-showtext]).
- [`src/gui/kernel/qwindow.cpp`][qwindow-cpp] — `QWindowPrivate::forwardToPopup`
  ([:2432][forward-popup], acceptance [:2452][forward-accept]), popup bookkeeping in `setVisible`
  ([:419][window-setvisible]).
- [`src/gui/kernel/qguiapplication.cpp`][qgui-cpp] — `popup_list` ([:186][popup-list]),
  `activePopupWindow` ([:969][active-popup]), `closeAllPopups` ([:995][close-all]),
  forward gate ([:2439][forward-gate]), `contextMenuEventType` ([:3619][ctx-type]).
- [`src/widgets/kernel/qwidgetwindow.cpp`][qwidgetwindow-cpp] — mouse retargeting
  ([:509][ww-mouse]), replay delivery ([:590][ww-replay]), `QContextMenuEvent` synthesis
  ([:670][ww-ctxmenu]), touch ignored for popups ([:682][ww-touch]),
  `handleKeyEvent` ([:696][ww-key]).
- [`src/widgets/styles/qcommonstyle.cpp`][qcommonstyle-cpp] — `SH_Menu_SubMenuPopupDelay`
  ([:5134][sh-submenu-delay]), `SH_Menu_SloppySubMenus` ([:5138][sh-sloppy]),
  `SH_Menu_SubMenuUniDirection` ([:5142][sh-unidir]), fail count ([:5145][sh-failcount]),
  `SH_ToolTip_WakeUpDelay` ([:5391][sh-wake]), `SH_ToolTip_FallAsleepDelay` ([:5394][sh-sleep]).
- [`src/widgets/util/qsystemtrayicon.cpp`][qtray-cpp] — `QBalloonTip::balloon`
  ([:565][balloon], arrow side predicates [:575][balloon-arrow], clamp [:602][balloon-clamp]).
- [`src/plugins/platforms/xcb/qxcbwindow.cpp`][qxcb-cpp] — `setMouseGrabEnabled`
  ([:2354][xcb-grab]).
- [`src/plugins/styles/mac/qmacstyle_mac.mm`][qmac-mm] — the macOS uni-direction override
  ([:2556][mac-unidir]).
- [`src/widgets/accessible/qaccessiblemenu.cpp`][qa11ymenu-cpp] and
  [`src/widgets/accessible/qaccessiblewidgetfactory.cpp`][qa11yfactory-cpp] — roles and parent
  resolution.
- Tests: [`tst_qmenu.cpp`][tst-qmenu] — `closeMenuOnClickIfMouseHasntMoved`
  ([:2129][tst-stillclick], QTBUG-128359), `click_while_dismissing_submenu`
  ([:1247][tst-dismiss]), `deleteWhenTriggered` ([:2035][tst-delete]),
  `QTBUG_56917_wideMenuScreenNumber` ([:1729][tst-widescreen]); [`tst_qtooltip.cpp`][tst-tooltip] —
  the timing bracket comment ([:108][tst-tip-timing]) and the platform-split key test
  ([:65][tst-tip-key]).

Related reading in this catalog: [`./index.md`](./index.md) for the umbrella,
[`./concepts.md`](./concepts.md) for the vocabulary used above,
[`./qt-quick-controls.md`](./qt-quick-controls.md) for Qt's other toolkit,
[`./xdg-positioner.md`](./xdg-positioner.md) and [`./gtk4.md`](./gtk4.md) for the two neighbouring
native-desktop answers, [`./features-people-forget.md`](./features-people-forget.md) for the guards
catalogued out of this subject, and [`./sparkles-baseline.md`](./sparkles-baseline.md) plus
[`./proposal.md`](./proposal.md) for what the toolkit does with them. Toolkit specs:
[`../../specs/ui/index.md`](../../specs/ui/index.md),
[`../../specs/ui/input.md`](../../specs/ui/input.md),
[`../../specs/ui/containers.md`](../../specs/ui/containers.md),
[`../../specs/ui/state-machines.md`](../../specs/ui/state-machines.md),
[`../../specs/ui/backends.md`](../../specs/ui/backends.md),
[`../../specs/ui/widgets.md`](../../specs/ui/widgets.md).

<!-- References -->

[repo]: https://github.com/qt/qtbase/tree/d0787745aa43e5baf49de876f917946df6aceca5
[doc-qmenu]: https://doc.qt.io/qt-6/qmenu.html
[doc-qtooltip]: https://doc.qt.io/qt-6/qtooltip.html
[doc-windowflags]: https://doc.qt.io/qt-6/qt.html#WindowType-enum
[c-anchor-rect]: ./concepts.md
[c-placement]: ./concepts.md
[c-flip]: ./concepts.md
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
[qmenu-cpp]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/widgets/widgets/qmenu.cpp
[menu-popup-fn]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/widgets/widgets/qmenu.cpp#L2307
[menu-desktopframe]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/widgets/widgets/qmenu.cpp#L2396
[menu-snap]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/widgets/widgets/qmenu.cpp#L2467
[menu-flip]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/widgets/widgets/qmenu.cpp#L2491
[menu-suboverlap]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/widgets/widgets/qmenu.cpp#L2512
[menu-actionrects]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/widgets/widgets/qmenu.cpp#L338
[menu-hasmoved]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/widgets/widgets/qmenu.cpp#L1573
[menu-eventtaken]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/widgets/widgets/qmenu.cpp#L1313
[menu-hideupto]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/widgets/widgets/qmenu.cpp#L518
[menu-caused]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/widgets/widgets/qmenu.cpp#L309
[menu-guess]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/widgets/widgets/qmenu.cpp#L2542
[menu-guess-typo]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/widgets/widgets/qmenu.cpp#L2558
[menu-submenu-anchor]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/widgets/widgets/qmenu.cpp#L3637
[qmenu-p-h]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/widgets/widgets/qmenu_p.h
[sloppy-class]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/widgets/widgets/qmenu_p.h#L91
[sloppy-result]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/widgets/widgets/qmenu_p.h#L120
[sloppy-slope]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/widgets/widgets/qmenu_p.h#L149
[sloppy-checkslope]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/widgets/widgets/qmenu_p.h#L157
[sloppy-process]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/widgets/widgets/qmenu_p.h#L164
[sloppy-counter]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/widgets/widgets/qmenu_p.h#L225
[position-function]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/widgets/widgets/qmenu_p.h#L275
[menu-caused-type]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/widgets/widgets/qmenu_p.h#L402
[delay-state]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/widgets/widgets/qmenu_p.h#L337
[qapp-cpp]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/widgets/kernel/qapplication.cpp
[grab-for-popup]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/widgets/kernel/qapplication.cpp#L3331
[close-popup]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/widgets/kernel/qapplication.cpp#L3345
[replay-arm]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/widgets/kernel/qapplication.cpp#L3356
[open-popup]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/widgets/kernel/qapplication.cpp#L3395
[tooltip-arm]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/widgets/kernel/qapplication.cpp#L2749
[tooltip-warm]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/widgets/kernel/qapplication.cpp#L2756
[tooltip-cooldown]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/widgets/kernel/qapplication.cpp#L2648
[never-blocked]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/widgets/kernel/qapplication.cpp#L2202
[try-modal]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/widgets/kernel/qapplication.cpp#L2214
[qtooltip-cpp]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/widgets/kernel/qtooltip.cpp
[tip-expire]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/widgets/kernel/qtooltip.cpp#L167
[tip-hide]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/widgets/kernel/qtooltip.cpp#L251
[tip-rect]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/widgets/kernel/qtooltip.cpp#L263
[tip-filter]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/widgets/kernel/qtooltip.cpp#L283
[tip-dismiss]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/widgets/kernel/qtooltip.cpp#L322
[tip-place]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/widgets/kernel/qtooltip.cpp#L346
[tip-cursor]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/widgets/kernel/qtooltip.cpp#L376
[tip-changed]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/widgets/kernel/qtooltip.cpp#L402
[tip-showtext]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/widgets/kernel/qtooltip.cpp#L439
[qwindow-cpp]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/gui/kernel/qwindow.cpp
[forward-popup]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/gui/kernel/qwindow.cpp#L2432
[forward-accept]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/gui/kernel/qwindow.cpp#L2452
[window-setvisible]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/gui/kernel/qwindow.cpp#L419
[qgui-cpp]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/gui/kernel/qguiapplication.cpp
[popup-list]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/gui/kernel/qguiapplication.cpp#L186
[active-popup]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/gui/kernel/qguiapplication.cpp#L969
[close-all]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/gui/kernel/qguiapplication.cpp#L995
[forward-gate]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/gui/kernel/qguiapplication.cpp#L2439
[ctx-type]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/gui/kernel/qguiapplication.cpp#L3619
[qwidgetwindow-cpp]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/widgets/kernel/qwidgetwindow.cpp
[ww-mouse]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/widgets/kernel/qwidgetwindow.cpp#L509
[ww-replay]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/widgets/kernel/qwidgetwindow.cpp#L590
[ww-ctxmenu]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/widgets/kernel/qwidgetwindow.cpp#L670
[ww-touch]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/widgets/kernel/qwidgetwindow.cpp#L682
[ww-key]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/widgets/kernel/qwidgetwindow.cpp#L696
[qcommonstyle-cpp]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/widgets/styles/qcommonstyle.cpp
[sh-submenu-delay]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/widgets/styles/qcommonstyle.cpp#L5134
[sh-sloppy]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/widgets/styles/qcommonstyle.cpp#L5138
[sh-unidir]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/widgets/styles/qcommonstyle.cpp#L5142
[sh-failcount]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/widgets/styles/qcommonstyle.cpp#L5145
[sh-wake]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/widgets/styles/qcommonstyle.cpp#L5391
[sh-sleep]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/widgets/styles/qcommonstyle.cpp#L5394
[qtray-cpp]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/widgets/util/qsystemtrayicon.cpp
[balloon]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/widgets/util/qsystemtrayicon.cpp#L565
[balloon-arrow]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/widgets/util/qsystemtrayicon.cpp#L575
[balloon-clamp]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/widgets/util/qsystemtrayicon.cpp#L602
[qxcb-cpp]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/plugins/platforms/xcb/qxcbwindow.cpp
[xcb-grab]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/plugins/platforms/xcb/qxcbwindow.cpp#L2354
[qmac-mm]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/plugins/styles/mac/qmacstyle_mac.mm
[mac-unidir]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/plugins/styles/mac/qmacstyle_mac.mm#L2556
[qa11ymenu-cpp]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/widgets/accessible/qaccessiblemenu.cpp
[qa11yfactory-cpp]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/widgets/accessible/qaccessiblewidgetfactory.cpp
[tst-qmenu]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/tests/auto/widgets/widgets/qmenu/tst_qmenu.cpp
[tst-stillclick]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/tests/auto/widgets/widgets/qmenu/tst_qmenu.cpp#L2129
[tst-dismiss]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/tests/auto/widgets/widgets/qmenu/tst_qmenu.cpp#L1247
[tst-delete]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/tests/auto/widgets/widgets/qmenu/tst_qmenu.cpp#L2035
[tst-widescreen]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/tests/auto/widgets/widgets/qmenu/tst_qmenu.cpp#L1729
[tst-tooltip]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/tests/auto/widgets/kernel/qtooltip/tst_qtooltip.cpp
[tst-tip-timing]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/tests/auto/widgets/kernel/qtooltip/tst_qtooltip.cpp#L108
[tst-tip-key]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/tests/auto/widgets/kernel/qtooltip/tst_qtooltip.cpp#L65
