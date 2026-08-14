# Turbo Vision (C++ / terminal cell grid, `magiblot/tvision`)

A complete windowing system — dropdown menus, cascading submenus, context menus, modal dialogs, a combobox surface and drop shadows — built inside a character cell grid with no compositor, no OS popup, no z-index, no hover, no key-release events and no timers anywhere in the overlay path.

| Field             | Value                                                                                                                                                                                                         |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language          | C++11 (the 16-bit x86 `.asm` variants of the geometry kernel are not compiled in the `__FLAT__` build and were not read)                                                                                      |
| License           | Borland's 1997 public-source release of Turbo Vision 2.0 (as-is, no warranty — see [`COPYRIGHT`][tv-copyright]) plus MIT-licensed third-party components. No modern SPDX identifier is declared for the port. |
| Repository        | [`magiblot/tvision`][tv-repo]                                                                                                                                                                                 |
| Documentation     | [`README.md`][tv-readme] at the pinned revision; there is no separate reference manual in-tree. Every claim below is read from source, not from the README.                                                   |
| Category          | Terminal / cell grid (historical)                                                                                                                                                                             |
| Surface model     | in-canvas — every overlay is a `TView` painted into the same `TScreenCell` grid; the only OS surface is the terminal or console itself                                                                        |
| **Revision read** | `57b6f56b38e0ee75240a80a10ee0e11470c24693` (`git describe`: `r586-749-g57b6f56`)                                                                                                                              |

## Overview

### What it solves

Turbo Vision solves the whole anchored-overlay problem — see [`./concepts.md`](./concepts.md) for the vocabulary used throughout this tree — under a deliberately small capability budget: one surface, integer cells, one pointer, press/drag/release only, no clock in the overlay path. Every overlay kind is the same quadruple: a rect in an owner group's cell coordinates, an owner `TGroup` to insert into, an event sink, and a `ushort` returned as the dismissal reason.

Because that budget is close to the [`sparkles:ui`](../../specs/ui/index.md) constraint set, the subject is useful less as a design to imitate wholesale than as an existence proof plus a set of small pure functions. The placement functions and the occlusion query are integer arithmetic over rects; the modal machinery is a nested C++ event loop, and that half does not travel.

### Design philosophy

One idea, repeated. Everything on screen is a `TView`: an `origin`/`size` rect in its owner's cell coordinates, a `state` bit word, an `options` word, and a `next` pointer. Every container is a `TGroup` holding a _circular singly-linked list_ of children in which list position **is** z-order. There is no [top layer](./concepts.md); "portal to the root" means literally passing a different `TGroup*` to `execView`.

[Occlusion](./concepts.md) is not solved by painting order. It is solved by subtracting the rects of every view in front of you from each row you write, so views may draw in any order and a fully covered view can skip drawing entirely. [Modality](./concepts.md) is not a window-manager property either — it is a nested event loop, entered by `TGroup::execView`, left by `endModal(command)`, and the loop's return value _is_ the dismissal reason. `source/tvision/tgroup.cpp:173` is the whole mechanism ([`TGroup::execute`][tgroup-execute]):

```cpp
ushort TGroup::execute()
{
    do  {
        endState = 0;
        do  {
            TEvent e;
            getEvent( e );
            handleEvent( e );
            if( e.what != evNothing )
                eventError( e );
            } while( endState == 0 );
    } while( !valid(endState) );
    return endState;
}
```

The outer `do … while( !valid(endState) )` is a dismissal **veto**: a modal view may refuse its own close. The inner loop is the block: background views are not suppressed by a scrim or a [grab](./concepts.md), they simply never get dispatched to.

The consequences run all the way down. Because a modal loop freezes the world, no overlay ever tracks a moving anchor, detects a hidden anchor, or observes a scroll container. Because there is no hover, menus are press-drag-release machines with no delay heuristics at all — two sticky value memos take their place. Because the smallest unit is a cell, there is no arrow: the submenu indicator is a character that contributes width to intrinsic sizing, and the drop shadow is an attribute substitution on cells that already exist, dropped entirely (and replaced by bracket glyphs) in monochrome mode.

## How it works

Four mechanisms carry every overlay in the library.

**1. Intrinsic sizing plus a shift into bounds.** `TMenuBox`'s file-static `getRect` (`source/tvision/tmenubox.cpp:25`, [`getRect`][tmenubox-getrect]) receives an _available region_ — `r.a` is the preferred top-left, `r.b` is the boundary — rather than a position. It computes `w` and `h` from the item list, then resolves each axis independently:

```cpp
if( r.a.x + w < r.b.x )
    r.b.x = r.a.x + w;
else
    r.a.x = r.b.x - w;

if (r.a.y + h < r.b.y)
    r.b.y = r.a.y + h;
else
    r.a.y = r.b.y - h;
```

That is the entire off-screen policy for every menu and submenu in the library: pin to the preferred edge if the extent fits, otherwise pin the far edge to the boundary. A [shift](./concepts.md), never a [flip](./concepts.md); no viewport padding, no fallback list.

**2. Anchor, boundary, portal target and modal entry in eight lines.** `TMenuView::execute` opens a submenu at `source/tvision/tmnuview.cpp:376` ([submenu open][tmnuview-open]):

```cpp
r = getItemRect( current );
r.a.x = r.a.x + origin.x;
r.a.y = r.b.y + origin.y;
r.b = owner->size;
if( size.y == 1 )
    r.a.x--;
target = topMenu()->newSubView(r, current->subMenu, this);
result = owner->execView(target);
```

The [anchor rect](./concepts.md) comes from a virtual (`getItemRect`), is converted to owner space by one add (trigger and popup share a group), the [clipping boundary](./concepts.md) is literally `owner->size`, the overlay is inserted into `owner` so it escapes the menu bar's one-row extent, and the nested loop's return value is the command.

**3. Occlusion by per-row span subtraction.** `TView::exposed()` (`source/tvision/tvexposd.cpp:39`, [`exposed`][tvexposd-exposed]) answers "is any cell of this view actually reachable on screen" by walking the siblings in front and subtracting their rects from each row's span. The single-point form is eleven lines and is the clearest statement of the z-order convention — iteration starts at `owner->last->next`, the front-most view, and stops at the target (`source/tvision/tvcursor.cpp:78`, [`caretCovered`][tvcursor-caretcovered]):

```cpp
Boolean TVCursor::caretCovered(TView *v) const
{
    TView *u = v->owner->last->next;
    for (; u != v; u = u->next)
    {
        if ( (u->state & sfVisible)
             && (u->origin.y <= y && y < u->origin.y + u->size.y)
             && (u->origin.x <= x && x < u->origin.x + u->size.x) )
            return True;
    }
    return False;
}
```

**4. Shadow as an attribute substitution.** `TVWrite::applyShadow` (`source/tvision/tvwrite.cpp:62`, [`applyShadow`][tvwrite-applyshadow]) neither composites nor darkens. It preserves the glyph and replaces the cell's whole attribute, stamping a sticky per-cell style bit so nested shadows cannot compound:

```cpp
auto style = ::getStyle(attr);
if (!(style & slNoShadow))
{
    if (::getBack(attr).toBIOS(false) != 0)
        attr = shadowAttr;
    else // Reverse the shadow attribute on black areas.
        attr = reverseAttribute(shadowAttr);
    ::setStyle(attr, style | slNoShadow);
}
```

`slNoShadow` is declared in `include/tvision/colors.h:496` with the comment "Don't draw window shadows over this cell" ([`slNoShadow`][colors-slnoshadow]), so the idempotence bit doubles as an application-level per-cell opt-out.

## The analysis spine

### 1. Anchor model

There is no anchor abstraction and no anchor type. Three unrelated representations are each reduced to a `TRect` in the _owner group's_ cell coordinates at open time and never consulted again.

- **Item-index anchor.** The virtual `TMenuView::getItemRect(TMenuItem*)` derives a rect by walking the item list. `TMenuBar` accumulates `cstrlen(name)+2` per item (`source/tvision/tmenubar.cpp:94`, [`TMenuBar::getItemRect`][tmenubar-getitemrect]); `TMenuBox` counts rows and returns `TRect(2, y, size.x-2, y+1)` (`source/tvision/tmenubox.cpp:125`, [`TMenuBox::getItemRect`][tmenubox-getitemrect]). The anchor is derived, never stored, and is deliberately narrower than the drawn row — the horizontal span `[2, size.x-2)` excludes the one-cell gutter and the frame column, so a press on the frame hits the view but no item. The base implementation returns `TRect(0,0,0,0)` (`source/tvision/tmnuview.cpp:448`).
- **Point anchor.** `popupMenu(TPoint where, …)` takes a bare screen cell and converts it with `app->makeLocal(where)` (`source/tvision/popupmnu.cpp:49`, [`popupMenu`][popupmnu-popupmenu]).
- **View-pointer anchor.** `THistory` stores a `TInputLine *link` and reads `link->getBounds()` at open time (`source/tvision/thistory.cpp:90`, [`THistory::handleEvent`][thistory-handleevent]). This is the tree's one detached trigger-versus-anchor case: the trigger is the `▼` icon view, the anchor is a different view.

Anchor-to-screen conversion is `makeGlobal`/`makeLocal`, summing `origin` up the `owner` chain (`source/tvision/tview.cpp:612`, [`makeGlobal`][tview-makeglobal]); in the menu path it collapses to a single add because trigger and popup share a group. Multi-rect anchors, text-range anchors, sub-region anchors and [virtual anchors](./concepts.md) are absent. Moving anchors are structurally impossible: the modal loop freezes the world while an overlay is open, which is why no tracking machinery exists anywhere in the library.

**Algorithm.** `anchorRect(menuBar, item)`: `r = TRect(1,0,1,1)`; for each `p` in items, `r.a.x = r.b.x`; if `p.name`, `r.b.x += cstrlen(p.name)+2`; return when `p == item`. `anchorRect(menuBox, item)`: `y = 1`; advance until `p == item`; return `TRect(2, y, size.x-2, y+1)`. `toOwnerSpace(r, view) = r + view.origin`.

**Where the behavior lives.** Library code, inside each overlay's own constructor or caller. `getItemRect` is the one virtual separating a horizontal bar from a vertical box.

**Degradation.** Every form survives every removal: a rect of integer cells needs no OS window, no hover, no script and no sub-cell precision, and is trivially assertable on a recording canvas. The one fragile representation is the raw `TInputLine*`, which requires a manual null-out in `THistory::shutDown` (`source/tvision/thistory.cpp:50`) — the dangling-anchor hazard that a plain comparable value removes.

### 2. Placement model

Three hand-written placement functions, no engine. There is no side/alignment vocabulary, no preferred-placement list, no RTL or writing-mode handling, no safe-area insets, no multi-monitor logic and no IME/keyboard avoidance.

- **Menus.** The caller passes an available region (`r.a` preferred, `r.b = owner->size`) and `getRect` computes intrinsic size — `w = max(10, max over items of cstrlen(name)+6`, `+3` when the item opens a submenu, else `+cstrlen(param)+2` when it has a shortcut label; `h = 2 + itemCount` — then shifts per axis. Shift only, never a flip.
- **Cascade offset.** A submenu of a menu _bar_ item lands at `(item.x + origin.x − 1, item.bottom + origin.y)`: one cell left of the bar item, on the row below. A submenu of a menu _box_ lands at `(origin.x + 2, origin.y + itemY + 1)` — diagonally down-right, **overlapping** the parent box rather than flush to its right edge. The parent/child relationship is expressed by overlap, not by adjacency or a tail.
- **Context menu.** `autoPlacePopup` (`source/tvision/popupmnu.cpp:70`, [`autoPlacePopup`][popupmnu-autoplace]) constructs at `TRect(p, p)` — which `getRect` resolves into a box whose bottom-right corner is `p`, because the far-edge branch fires on both axes — then translates by `(min(w, app.x−p.x), min(h+1, app.y−p.y))`: prefer below-right with a one-row gap, clamped so the box can never cross the screen's right or bottom edge. Then the single flip in the codebase fires (`source/tvision/popupmnu.cpp:83`):

  ```cpp
  // If the popup then contains 'p', try to move it to a better place.
  if (r.contains(p) && r.b.y - r.a.y < p.y)
      r.move(0, -(r.b.y - p.y));
  ```

  The trigger condition is not "does it overflow" but "did the clamp make the popup cover the cursor", and the height must fit above. Collision is defined against the **anchor point**, not the boundary.

- **Dropdown.** `THistory` grows the input line's bounds by one cell left, right and up, adds seven rows below, intersects with `owner->getExtent()`, then shrinks one row (`source/tvision/thistory.cpp:90`). Pure clamp, no flip — near a dialog's bottom edge the list simply gets shorter.

The "work area" is whichever group you insert into, which makes the boundary a first-class argument in practice: commit [`3f40740`][commit-3f40740] moved `popupMenu` from `deskTop` to `application` specifically to obtain the full screen instead of the desktop's inset extent.

**Algorithm.** `place(preferred a, boundary b, intrinsic w,h)`: on x, `if (a.x + w < b.x) box = [a.x, a.x+w) else box = [b.x−w, b.x)`; y likewise. `placeAtCursor(p, app, w, h)`: `box = [p−(w,h), p]`; `box += (min(w, app.x−p.x), min(h+1, app.y−p.y))`; `if (box contains p && h < p.y) box.y −= (box.bottom − p.y)`.

**Where the behavior lives.** Library code, split across three widget files. Nothing is reusable; each overlay kind re-derives the arithmetic.

**Degradation.** Fully survives: integer-cell arithmetic with no measurement pass, no script and no timers — it could run at HTML emit time. The gap that matters for a multi-target toolkit is that the boundary is _read_ from `owner->size` rather than passed in, so a soft-keyboard inset has no way to enter the calculation; the menu path (`r.b = owner->size`) is one edit from an explicit parameter. See [`./proposal.md`](./proposal.md) for how the catalog resolves that.

### 3. Collision & geometry engine

Within this subject the real engine is occlusion, not placement. Clipping-ancestor discovery is just the `owner` pointer chain; there are no scroll containers, transforms, device pixel ratios or fractional pixels. `TView::getClipRect()` is own bounds intersected with `owner->clip`, translated to view-local (`source/tvision/tview.cpp:475`). `TGroup::clip` is a mutable per-group rect in group-local coordinates, temporarily narrowed for partial repaints and then restored to `getExtent()` — to the full extent, not to a saved value (`source/tvision/tview.cpp:387`, [`drawUnderRect`][tview-drawunderrect]), which is only safe because `drawUnderRect` is a top-level entry point.

The occlusion query exists in three separate implementations that share no code: `TView::exposed()` (per-row span subtraction), `TVWrite::L20` (the same walk while writing, plus shadow accounting) and `TVCursor::caretCovered` (single-point). All three are visibly transliterations of 16-bit assembler: the helper structs' members are named `eax`, `ebx`, `ecx`, `esi` and the functions `L0`…`L23`.

The `exposed()` walk: for each row of the view, hold a horizontal span; translate into owner coordinates; reject the row if it falls outside `owner->clip` vertically; clamp the span to `owner->clip` horizontally; then walk the siblings in front — start at `owner->last`, follow `next` (which reaches `first()`, the topmost, first), stop at the target — subtracting each visible sibling's rect: left-truncate, right-truncate, or **split** (recurse on the left sub-span, continue with the right). If a span survives to the target, ascend one level: if the owner is buffered or locked the write lands in a buffer, so the view counts as exposed; otherwise repeat in the owner's frame. First surviving cell wins; all rows dead means not exposed. A cached `sfExposed` state bit, propagated down by `TGroup::setState`/`doExpose` (`source/tvision/tgroup.cpp:509`), short-circuits the scan.

Cost is O(rows × occluders) integer comparisons, recursion only on splits, zero allocation, `noexcept`.

**Tracking.** There is none — no observers, no polling, no frame callbacks. Geometry changes only via explicit `locate`/`changeBounds`, and while an overlay is modal nothing can call them.

**Where the behavior lives.** Library kernel (`tvexposd.cpp` / `tvwrite.cpp` / `tvcursor.cpp`). Nothing platform-specific; the platform layer below receives already-clipped cell runs.

**Degradation.** This generalises off its substrate: it needs no OS window, no compositor, no hover, no timers and no sub-cell precision — pure integer geometry over a flat sibling list, which is what a display list already is.

> [!NOTE]
> What happens on a terminal resize is an **inference**, not an observation. Reading `TView::calcBounds` (`source/tvision/tview.cpp:134`) and `TView::sizeLimits` (`source/tvision/tview.cpp:829`), an open `TMenuBox` has `growMode` 0, so `calcBounds` appears to leave its origin alone while only the size is clamped against the new `owner->size`. The structure therefore suggests a popup that was near the old right edge is left overhanging and truncated rather than re-placed. Nothing was built or run to confirm this.

### 4. Arrow / caret geometry

Not applicable: there is no arrow, no caret, no tail and no [transform origin](./concepts.md) anywhere in the library. The absence is the finding — at one-cell granularity a tail costs a whole character and buys nothing that overlap does not. Three substitutes carry the load.

1. **The submenu indicator is data in the sizing formula.** `b.putChar(size.x-4, 16)` paints CP437 `0x10` (`►`) in the right margin of an item that has a submenu (`source/tvision/tmenubox.cpp:111`), and `getRect` reserves three columns for it with `if (p->command == 0) l += 3` (`source/tvision/tmenubox.cpp:36`). The affordance's size feeds intrinsic width — the cell-grid form of "arrow size participates in the offset".
2. **Cascade relationship is carried by overlap.** The submenu's left frame column lands exactly on the parent item's first text column, because the submenu origin is `parent.origin.x + 2` and `TMenuBox`'s frame string reserves a one-cell blank gutter at `x = 0` before the `│` at `x = 1` (`source/tvision/tvtext1.cpp:70`).
3. **When the decoration channel disappears, a glyph affordance replaces it.** In monochrome, `TButton::markers = "[]"` and `specialChars` (`»`, `«`, `→`, `←`) are drawn around the focused element, gated on `TView::showMarkers` (`source/tvision/tbutton.cpp:89`, `source/tvision/tvtext1.cpp:62`).

**Algorithm.** None for an arrow. The nearest computation is intrinsic width: `w = max(10, max over items of cstrlen(name) + 6 + (3 if submenu else cstrlen(param)+2 if param))`, where the `+3` is the `►` column and the `+6` is gutter, frame and pad on both sides.

**Where the behavior lives.** Library code, inline in each widget's `draw()`; the marker and glyph tables are process-global statics in `tvtext1.cpp`.

**Degradation.** Not applicable, therefore immune. With no cell to spare the affordance becomes the overlap geometry itself, which costs nothing and survives every target including static HTML.

### 5. Trigger semantics

Hover is not a trigger anywhere in Turbo Vision. `TMenuView::execute` handles `evMouseMove` only while a button is held — `case evMouseMove: if( e.mouse.buttons != 0 )` at `source/tvision/tmnuview.cpp:263` — so menus are press-drag-release machines. There is no key-release event to depend on either: `TEventQueue` produces `evKeyDown` only (`source/tvision/tevent.cpp:409`), and the mouse-up event is itself _synthesised_ from a state transition (buttons went zero while the last sample was non-zero, `source/tvision/tevent.cpp:126`), including a `pendingMouseUp` latch that splits a move-plus-release into a move followed by a synthetic up.

Trigger sources, all funnelled into one loop: press inside self; press inside the parent's currently highlighted item rect (`mouseInOwner`); drag; release; `kbUp`/`kbDown`/`kbLeft`/`kbRight`/`kbHome`/`kbEnd`/`kbEnter`/`kbEsc`; `Alt`+letter resolved Unicode-aware over the whole tree (`findAltShortcut` tries the event's text first, then the key code, `source/tvision/tmnuview.cpp:436`); a bare letter matching an item's `~x~` hotkey; a global accelerator searched recursively through every submenu (`findHotKey`, `source/tvision/tmnuview.cpp:557`); `evCommand cmMenu` (`F10` from the status line, or programmatic); and `evBroadcast cmCommandSetChanged`, which re-derives every item's disabled flag from the global command set and redraws.

The interesting part is how multiple triggers combine without racing: **no trigger performs an action.** Every branch of the switch writes only into `current`, `autoSelect`, `lastTargetItem`, `result` or a three-valued `menuAction`; a single block at the tail of the loop body decides whether to open a submenu or produce a command (`source/tvision/tmnuview.cpp:368`). One writer, one actor, one ordering.

Pointer types are not distinguished. The right button is inspected only by the application: `TEditor::handleEvent` checks `mbRightButton` and calls `popupMenu` (`source/tvision/teditor1.cpp:534`).

**Algorithm.** `loop { e = getEvent(); action = doNothing; switch(e.what) { … branches assign only … } if (lastTargetItem != current) lastTargetItem = 0; if (itemShown != current) { itemShown = current; drawView(); } if ((action == doSelect || (action == doNothing && autoSelect)) && current && current->name) { if (current is an enabled submenu) { re-post the mouse event; compute the child rect; result = owner->execView(newSubView(…)); lastTargetItem = current; } else if (action == doSelect) result = current->command; } if (result && commandEnabled(result)) { action = doReturn; clearEvent(e); } else result = 0; } until action == doReturn.`

**Where the behavior lives.** Library code, entirely inside one ~230-line function (`TMenuView::execute`). Nothing in the platform layer knows about menus.

**Degradation.** Already at the floor and still fully functional: no hover, no key release, one pointer, no OS window. `evMouseAuto` (a synthetic auto-repeat while a button is held, `source/tvision/tevent.cpp:196`) is the only event class depending on wall time, and menus ignore it.

### 6. Timing

Not applicable to the overlay path: there is no open delay, no close delay, no [warm-up](./concepts.md), no [cool-down](./concepts.md), no maximum display duration, no shared timing provider and no re-entry grace. The only wall-clock constructs in the library are `doubleDelay`/`repeatDelay` for click classification and `evMouseAuto` autorepeat (`source/tvision/tevent.cpp:51`), the 20 ms `TProgram::eventTimeoutMs` idle wakeup, a `TVISION_MAX_FPS` output-flush governor (`source/platform/dispbuff.cpp:25`), and `TTimerQueue`.

What replaces timing is **two sticky value memos**.

1. `autoSelect` — once set (by `kbDown`/`kbEnter`/a hotkey on the bar, by a bar press on an item that is not the just-closed one, or by dragging onto a different bar item), every subsequent change of `current` opens its submenu immediately. Cleared only by `evCommand cmMenu`. That is "the menu is open, so neighbours open instantly" as one bit rather than a shared-provider timer.
2. `lastTargetItem` — the item whose submenu was just closed by pressing its own name. While the pointer remains on it a release will not re-open it; the first event where `current != lastTargetItem` clears the memo (`source/tvision/tmnuview.cpp:359`), so moving away re-arms it. A re-entry guard expressed as an identity comparison rather than a cool-down window.

The implied state machine is `{closed, open(item), open+child}` over discrete events, with event ordering as the only notion of time and the two memos guarding the transitions.

**Algorithm.** `autoSelect := (bar && press && (current == null || lastTargetItem != current)) | (bar && drag && mouseActive && current != lastTargetItem) | (bar && kbDown) | (bar && kbEnter) | (bar && hotkey-hit)`; `autoSelect := false` on `cmMenu`. `lastTargetItem := current` after a submenu closes; `lastTargetItem := 0` whenever `current != lastTargetItem`. `openSubmenu ⟺ (action == doSelect || autoSelect) && current is an enabled submenu`.

**Where the behavior lives.** Library code; both memos are local variables of `TMenuView::execute`, so they live on the C++ stack for the lifetime of the open menu.

**Degradation.** Immune. With zero timers, every transition is decidable from an event sequence alone, which is what a no-script HTML target and a recording canvas both need. `TTimerQueue` exists as substrate if a delay were ever wanted, and its clock is injectable — `TTimerQueue(TTimePoint (&getTimeMs)())` (`source/tvision/ttimerqu.cpp:19`) — and is mocked in its unit test (`test/tvision/ttimerqu.test.cpp:6`).

> [!WARNING]
> That timers are unsuited to a hover delay here is an **inference** from structure, not a measurement. `collectExpiredTimers` runs from `TProgram::idle()` (`source/tvision/tprogram.cpp:217`), and `idle()` appears to be reached only when the mouse and key paths both return `evNothing` (`source/tvision/tprogram.cpp:143`) — which suggests a hover delay built on `TTimerQueue` would be starved during exactly the continuous pointer motion it must measure. Not observed at runtime.

### 7. Interactive hover

Not applicable: there is no interactive hover, no [safe polygon](./concepts.md), no pointer bridge, no trajectory heuristic, no debounce and no tolerance band. The equivalent problem — travelling from a parent item to its open submenu without the submenu closing — is solved by modality plus exact rectangle membership, at a cost of zero cells.

Three predicates do the work:

- `mouseInView(e.mouse.where)` — am I under the pointer;
- `mouseInOwner(e)` (`source/tvision/tmnuview.cpp:148`) — is the pointer inside the parent menu's _currently highlighted item rect_, not the whole parent;
- `mouseInMenus(e)` (`source/tvision/tmnuview.cpp:160`) — walk the `parentMenu` chain testing `mouseInView`, true iff the pointer is inside some ancestor menu.

The close rule is one condition at `source/tvision/tmnuview.cpp:266`: close this submenu only when the pointer is neither in me nor on my parent item **and** is inside some ancestor. Consequently dragging out over the desktop or an unrelated window closes nothing — the submenu stays open until the pointer re-enters an ancestor menu. The diagonal-travel problem is dissolved rather than mitigated: opening requires a press, a drag with a button held, or a key, so a pointer that merely wanders is neither opening nor closing anything.

The only geometric slack in the stack is incidental: `TMenuBox`'s frame reserves a one-cell blank gutter at `x = 0` and `x = size.x−1`, and the item hit rect is `[2, size.x−2)`, so a press in the gutter or on the `│` lands inside the view but on no item — clearing the highlight without closing the menu. Nesting depth is unbounded; each level is a C++ stack frame.

**Algorithm.** `onDrag(e)`: `trackMouse(e)` sets `current` to the item whose `getItemRect` contains `makeLocal(e.where)`, else null. `if (!(mouseInView(e) || mouseInOwner(e)) && mouseInMenus(e))` close this level; else if `isBar && mouseActive && current != lastTargetItem`, set `autoSelect`.

**Where the behavior lives.** Library code: three small private methods of `TMenuView` plus one condition in its loop.

**Degradation.** Immune, because it never existed. Cost in whole cells: zero for the traversal rule, one cell of incidental gutter on each side of a menu box. On a target with no pointer grab the rule is still safe because it only ever _reads_ the pointer position out of events that did arrive; an event that never arrives leaves the menu open, which is the benign failure.

### 8. Dismissal

The richest dimension in this subject.

- **Escape.** `kbEsc → doReturn`, then `if( parentMenu == 0 || parentMenu->size.y != 1 ) clearEvent(e);` (`source/tvision/tmnuview.cpp:308`). Escape is consumed at the top level and inside a submenu of a box, but deliberately _not_ consumed in a first-level dropdown whose parent is the bar; the un-cleared event is re-posted on the way out (`source/tvision/tmnuview.cpp:403`) so the bar's own loop sees it and closes too. Escape therefore closes one level, except the first dropdown, which also releases the bar.
- **Press outside.** Dismissal is on press, selection on release. The dismissing press is re-posted to the view underneath by default and swallowed when `putClickEventOnExit` is false (`source/tvision/tmnuview.cpp:218`, comment: "Let the event reach the view recovering focus"). Only `TMenuPopup` sets it false, in its constructor (`source/tvision/tmenupop.cpp:27`) — context menus swallow, dropdowns pass through. This is the one place in the tree where "does the dismissing press also reach what is underneath?" is an explicit, per-overlay value rather than a hard-coded policy.
- **Trigger re-activation.** Pressing the parent item again closes the submenu (`!firstEvent && mouseInOwner(e) → doReturn`, `source/tvision/tmnuview.cpp:213`), with a `firstEvent` guard so the press that opened it cannot immediately close it; the `lastTargetItem` memo then prevents the following release from re-opening it.
- **Cascades.** Opening a child never closes a parent; closing a parent while a child is open is impossible, since the parent is blocked inside `execView`. Any `evCommand` other than `cmMenu` returns from every level and is re-posted upward, unwinding the nested loops to the application (`source/tvision/tmnuview.cpp:351`).
- **Veto.** `TGroup::execute` wraps its loop in `do { … } while( !valid(endState) )`, so a modal view can refuse its own dismissal. `TDialog::valid` whitelists `cmCancel` so Cancel always works (`source/tvision/tdialog.cpp:91`), and `TDialog` maps Escape to a re-posted `cmCancel` command rather than closing directly (`source/tvision/tdialog.cpp:57`).
- **The dropdown's simpler [light dismiss](./concepts.md).** `THistoryWindow::handleEvent` does `if (evMouseDown && !mouseInView) { endModal(cmCancel); clearEvent(event); }` (`source/tvision/thistwin.cpp:54`).

Not applicable here, because modality makes them unreachable: focus-outside, application deactivation, scroll, anchor hidden, anchor removed, navigation, touch-outside. Resize _is_ reachable — `cmScreenChanged` is intercepted inside `TProgram::getEvent` (`source/tvision/tprogram.cpp:162`) — and does not dismiss.

**Algorithm.** `dismiss(reason)`: `endModal(reason)` → `TopView().endState = reason` → the innermost blocking loop exits → `execute()` returns the reason → `execView()` restores focus, commands and z-order and returns it to the caller. Outside press: `if (!(inSelf || inParentItem)) { if (passThrough) putEvent(e); return doReturn; }`. Escape: return `doReturn`, consuming the key unless the parent is the menu bar.

**Where the behavior lives.** Library code, distributed: each overlay class contributes its own dismissal branch, while the unwinding mechanism (`endModal`/`endState`/`valid`) lives in `TGroup`/`TView`.

**Degradation.** Everything here survives every target: dismissal is discrete events plus rectangle containment, with no timers, no focus system, no OS notifications and no key release. An Android back key maps cleanly onto the Escape branch. The missing piece for a non-modal toolkit is that Turbo Vision never has to answer "the anchor scrolled away", because it cannot happen.

### 9. Focus

Focus is a per-group `current` pointer plus three state bits: `sfSelected` (I am my group's current), `sfFocused` (I am on the active chain to the root) and `sfActive`. The whole algorithm is `TGroup::setCurrent(p, selectMode)` (`source/tvision/tgroup.cpp:476`) over a three-valued mode declared at `include/tvision/views.h:345`:

```cpp
enum selectMode{ normalSelect, enterSelect, leaveSelect };
```

`enterSelect` means "entering a modal scope, so do not deselect the outgoing view"; `leaveSelect` means "leaving it, so do not reselect the incoming one" (it never lost `sfSelected`). Two enum values express save-and-restore across a modal scope with no focus stack.

`TGroup::execView` (`source/tvision/tgroup.cpp:188`) is the complete modal prologue and epilogue: save `options`, `owner`, the global `TheTopView`, `current` and the entire `TCommandSet`; strip `ofSelectable` so tab traversal cannot reach the modal view; set `sfModal`; `setCurrent(p, enterSelect)`; insert if unowned; run `p->execute()`; remove; `setCurrent(saved, leaveSelect)`; clear `sfModal`; restore everything.

Containment, not a trap: `TGroup::findNext` walks the circular sibling list skipping non-selectable, invisible or disabled views (`source/tvision/tgroup.cpp:224`), so tab cannot leave the group — there is no trap code because the data structure is a ring. Focus changes are vetoable: `TView::focus()` asks the outgoing `current` for `valid(cmReleasedFocus)` before moving (`source/tvision/tview.cpp:452`, `source/tvision/tgroup.cpp:566`).

Critically the overlay kinds stay distinct. Menus take **no** focus at all — `TMenuView::execute` never calls `focus()`, and its notion of "focused" is a `TMenuItem*` into a linked list, not a view — while dialogs and the history dropdown are real focus-containing `TGroup`s. Pointer- versus keyboard-opened differs by initial selection: `TMenuPopup::execute` sets `menu->deflt = 0` so a context menu opens with nothing highlighted, with the reason stated in the source at `source/tvision/tmenupop.cpp:38` ("Do not highlight the default entry, because it would look ugly."), whereas a menu restores the last-used item via `menu->deflt = current` on exit (`source/tvision/tmnuview.cpp:386`).

**Algorithm.** `setCurrent(p, mode)`: if `p == current` return; lock; unfocus `current`; if `mode != enterSelect` clear the outgoing `sfSelected`; if `mode != leaveSelect` set the incoming `sfSelected`; propagate `sfFocused`; `current = p`; unlock. `findNext(forwards)`: walk `next`/`prev` until a view is visible, enabled and `ofSelectable`, or you return to `current`.

**Where the behavior lives.** Library kernel (`TGroup`/`TView`). No platform involvement; the terminal only ever learns a caret position.

**Degradation.** Survives everything — focus here is a pointer comparison and three bits driven by discrete events, needing no OS focus notification and no key release. The one thing a cell grid cannot express is a difference between focused and focus-visible; Turbo Vision always shows the selection, which for a hover-less target is a defensible default.

### 10. Layering & portals

There is no top layer, no z-index and no stacking context. Layering **is** the overlay tree: each `TGroup` owns a circular singly-linked list of children where `last->next == first()` is the front-most view and `last` is back-most (`source/tvision/tgroup.cpp:216`). Z-order operations are list splices — `insert` (to front), `insertBefore`, `makeFirst`, `putInFrontOf` (`source/tvision/tview.cpp:693`), `remove`. The intended public API is that set plus `first`/`nextView`/`prevView`/`forEach`/`firstThat`; the raw splicers `insertView`/`removeView` and the fields `last`, `next`, `clip`, `buffer`, `lockFlag`, `phase`, `endState` are technically public C++ members but are treated as mechanism.

"Portal" means choosing which group you insert into, and it is a real per-overlay choice made at three different escape levels: a submenu goes into `owner`, the application group, escaping the menu bar's one-row extent; `popupMenu` goes into `TProgram::application`, changed from `TProgram::deskTop` in commit [`3f40740`][commit-3f40740] to escape the desktop's inset; and `THistoryWindow` goes into the _dialog_ (`owner->execView`, `source/tvision/thistory.cpp:101`) and is therefore deliberately clipped by it. One argument expresses all three.

Compositing: any group may own an offscreen `TScreenCell*` buffer (`ofBuffered`/`getBuffer`, `source/tvision/tgroup.cpp:285`); a write climbs the ownership chain (`TVWrite::L40`, `source/tvision/tvwrite.cpp:211`) until it reaches a buffer, and stops climbing if a group is locked, so `lock()`/`unlock()` coalesces a burst of child writes into a single repaint (`source/tvision/tgroup.cpp:431`).

The architectural surprise: painting order does **not** determine occlusion. `TGroup::redraw` paints front to back via `drawSubViews(first(), 0)` (`source/tvision/tgroup.cpp:437`), and correctness comes entirely from every write being clipped against the views in front of it.

**Algorithm.** `insertView(p, target)`: splice into the ring, updating `last` when appending at the back. `insert(p) = insertBefore(p, first())`. `hitTest(pt) = firstThat(v ⇒ v.sfVisible && v.contains(pt))` iterating `last.next … last`, i.e. front to back (`source/tvision/grp.cpp:26`).

**Where the behavior lives.** Library kernel (`TGroup`). The platform layer receives only a final flat cell buffer with per-row damage ranges.

**Degradation.** The tree, the ownership relation and the front-to-back hit test map one-to-one onto a single-surface display-list toolkit. What does not survive translation is the per-write occlusion clipping, which exists only because there is no back-to-front repaint, and `ofBuffered` group buffers, whose purpose is subsumed by a frame-based repaint.

### 11. Modality

Modality without an OS, via a nested event loop. `execView` sets `sfModal` and calls `p->execute()`; `TGroup::execute` blocks in `getEvent`/`handleEvent` until `endState != 0`, and `TMenuView::execute` is a hand-written equivalent. Background views are blocked not by a scrim and not by an input grab but because nobody dispatches to them: `getEvent` walks up the owner chain to `TProgram::getEvent`, and the event it returns is handed to the modal view alone. `endModal(command)` finds the nearest modal ancestor through `TView::TopView()` — which prefers the global `TheTopView` set by `execView`, else walks `owner` looking for `sfModal` (`source/tvision/tview.cpp:879`) — and stores the command in `endState` (`source/tvision/tgroup.cpp:159`). The nested loop's return value _is_ the dismissal reason, delivered by the call stack: `ushort c = deskTop->execView(dialog); if (c == cmOK) …`.

The documented hole in the block: `TProgram::getEvent` gives the status line first refusal on every `evKeyDown`, and on any `evMouseDown` that hits it, even inside a modal loop (`source/tvision/tprogram.cpp:153`); `cmScreenChanged` is intercepted in the same place. `F10` and `Alt-X` therefore stay live under modality — a deliberate carve-out for global chrome.

There is no scrim, no dim, no accessibility modal bit and no click-through. A positional event goes to `firstThat(hasMouse)`, the front-most visible view containing the pointer, and if that view is disabled `doHandleEvent` drops it rather than letting it fall through to the view behind (`source/tvision/tgroup.cpp:324`). Note the shadow region is not part of a view's bounds, so a press on a window's shadow falls through to whatever is behind it. Menus are modal but focus-less; dialogs are modal and focus-containing; both use the same `execView`. Non-modal overlays do not exist.

**Algorithm.** `execView(p)`: save `{p.options, p.owner, TheTopView, current, curCommandSet}`; `TheTopView = p`; `p.options &= ~ofSelectable`; `setState(sfModal, true)`; `setCurrent(p, enterSelect)`; insert if unowned; `r = p.execute()`; remove if inserted; `setCurrent(saved, leaveSelect)`; clear `sfModal`; restore; return `r`. `endModal(cmd)`: `TopView().endState = cmd`.

**Where the behavior lives.** Library kernel (`TGroup::execView`/`execute`, `TView::TopView`/`endModal`), plus the one carve-out in `TProgram::getEvent`.

**Degradation.** This is the dimension that does not port. A nested blocking event loop requires re-entrant event acquisition, which a frame-driven single-surface toolkit with a [recording canvas](../../specs/ui-app/index.md) cannot provide. What _does_ port is the contract: a modal scope is (a) a saved and restored focus plus command-enablement snapshot, (b) an exclusive event sink, and (c) a single value returned as the reason — all three expressible as a value on a stack of open overlays instead of a stack of C++ frames.

### 12. Adaptive presentation

Exactly one adaptation exists, and it is a global capability switch rather than a per-widget decision. `TProgram::initScreen` (`source/tvision/tprogram.cpp:244`) runs at startup and on every video-mode change: in colour modes it sets `shadowSize = {2,1}` — or `{1,1}` when an 8×8 font is active, so the shadow's width tracks the cell aspect ratio and the shadow reads as square — and `showMarkers = False`; in monochrome it sets `shadowSize = {0,0}`, `showMarkers = True` and selects the monochrome palette.

Every widget then reads the two process globals at draw time (`::shadowSize` in `source/tvision/tview.cpp:398` and `source/tvision/tvwrite.cpp:167`; `TView::showMarkers` in `source/tvision/tbutton.cpp:89`, `source/tvision/tlabel.cpp:65`, `source/tvision/tcluster.cpp:118`, `source/tvision/tlstview.cpp:141`). So when the shadow channel becomes unavailable the toolkit **substitutes** bracket glyphs around the focused element rather than merely omitting the decoration — the capability probe happens once at the top and the replacement affordance happens at the bottom.

There is no touch adaptation, no compact-size-class sheet, no popover-to-sheet transformation and no keyboard-driven relocation.

**Algorithm.** `initScreen()`: if mode is not mono, `shadowSize = (mode & smFont8x8) ? {1,1} : {2,1}`, `showMarkers = false`, palette by mode; else `shadowSize = {0,0}`, `showMarkers = true`, monochrome palette.

**Where the behavior lives.** The program layer decides once (`TProgram`); widgets consume two ambient globals. Not a per-overlay decision and not a theme object.

**Degradation.** The shape maps directly onto a multi-target matrix: one capability probe, two values, every widget's paint reads them. The weakness is that they are mutable process globals rather than a theme value threaded through the paint call — which [`../../specs/ui/index.md`](../../specs/ui/index.md)'s unified `Theme` already answers differently.

### 13. Accessibility

There is no accessibility API in the tree — no roles, no descriptions, no assistive-technology bridge. A grep for `accessib`, `screen reader`, `a11y` and `braille` over the repository at this revision returns only unrelated prose about the system clipboard. The absence is honest: a terminal application has no AT tree to publish into.

What a cell grid _can_ expose honestly, Turbo Vision does expose, in two channels.

1. **The hardware caret**, which is what terminal screen readers follow. `TView::resetCursor`/`TVCursor` (`source/tvision/tvcursor.cpp:36`) positions the terminal caret only when the view is `sfVisible|sfCursorVis|sfFocused` **and** the caret cell survives a point-occlusion walk up the whole ownership chain (`caretCovered`); otherwise it sets caret size 0. The toolkit spends a real occlusion query per caret update to keep this channel truthful.
2. **A persistent description line keyed by a plain `ushort`.** Every view carries `helpCtx`; `TStatusLine::update()` reads `TopView()->getHelpCtx()` and re-renders when it changes (`source/tvision/tstatusl.cpp:210`); the overridable `TStatusLine::hint(ushort)` (`source/tvision/tstatusl.cpp:204`, declared at `include/tvision/menus.h:499`) prints the description in a fixed screen region; `TMenuView::getHelpCtx` walks the `parentMenu` chain to the innermost highlighted item that has a context (`source/tvision/tmnuview.cpp:453`).

The second channel is this subject's answer to the tooltip, and it dodges the hover-only hazards by construction: single instance, always visible, never obscures anything, never times out, needs no pointer, and cannot contain interactive content. It also separates the primitive from the semantic component — the primitive is "a rect plus a modal loop", the semantics are a comparable integer that some other part of the shell renders wherever it likes. Compare [`./aria-apg.md`](./aria-apg.md) for the normative web contract this deliberately does not attempt.

**Algorithm.** Caret: if not `sfVisible & sfCursorVis & sfFocused`, size 0. Otherwise walk up the ownership chain translating the point by each `origin`; if any front sibling of the current level contains the point, size 0; at the root, place the caret. Hint: on idle, `h = TopView().getHelpCtx()`; if it changed, re-find items and redraw.

**Where the behavior lives.** Library code; the hint text is supplied by the application by overriding a virtual. No platform or OS accessibility involvement.

**Degradation.** The caret channel needs a tty and dies on a recording canvas and in static HTML. The `helpCtx`-to-description channel survives every target, including no-script HTML, because it is a comparable integer plus a fixed region of the same surface.

### 14. Animation

Nothing animates. There is no enter or exit transition, no spring, no reduced-motion switch, no transform origin and no reposition-during-animation. The question that matters for a styling layer has a negative answer: **no geometry metadata is emitted.** `getRect` and `autoPlacePopup` compute a final rect and discard the reasoning, so nothing downstream can know whether a popup ended up above or below its anchor.

The nearest thing to animation infrastructure is output-side frame governance, which exists for CPU reasons rather than visual ones: `DisplayBuffer` coalesces writes into per-row damage ranges (`setDirty`, `source/platform/dispbuff.cpp:104`; `flushScreenAlgorithm`, `:309`) and refuses to flush faster than `TVISION_MAX_FPS` (`source/platform/dispbuff.cpp:25`), while `TGroup::lock`/`unlock` batches a burst of child writes into one repaint. The one piece of geometry derived purely for presentation is the shadow region, computed at write time from the global `shadowSize` plus each occluder's rect (`source/tvision/tvwrite.cpp:167`) rather than stored on any view — presentation geometry owned by the writer, not by the widget.

**Algorithm.** None for animation. Damage coalescing: `setDirty(x, y, len)` widens `rowDamage[y]` to cover `[x, x+len-1]`; the flush walks each row's damage range once per frame and emits a minimal escape-sequence run.

**Where the behavior lives.** Platform layer (`source/platform/dispbuff.cpp`) for the frame governor; library kernel for lock/unlock batching. No animation layer exists.

**Degradation.** Not applicable, therefore immune. The transferable observation is negative and load-bearing: because the placement functions return only a rect, no styling layer could animate from the correct origin even if one existed. A design that wants side-aware presentation has to make placement return the chosen side alongside the rect — this tree shows what it costs not to.

### 15. State architecture

Two architectures coexist.

**(a) A retained object graph with mutable bit-flag state.** `state`, `options` and `eventMask` are `ushort` words (`include/tvision/views.h:63`) and `setState(aState, enable)` is a virtual that cascades side effects — showing a view redraws it, hiding it repaints what was underneath, toggling `sfShadow` repaints the shadow strip, gaining `sfFocused` broadcasts `cmReceivedFocus` (`source/tvision/tview.cpp:771`, `source/tvision/tgroup.cpp:526`). Fully uncontrolled: every widget owns its own truth and mutates the screen as a side effect of a setter.

**(b) The overlay machine itself is a blocking function.** `TMenuView::execute()` is a ~230-line loop over six locals — `current`, `autoSelect`, `firstEvent`, `itemShown`, `lastTargetItem`, `mouseActive` — driving the three-valued `menuAction` enum (`source/tvision/tmnuview.cpp:177`) and returning a `ushort` command. The state machine is the call stack; a nested submenu is a nested stack frame.

The two halves separate cleanly along a portability line. The placement functions (`getRect`, `autoPlacePopup`, `getItemRect`) and the occlusion functions (`exposed`, `caretCovered`) are already pure integer functions over rects — allocation-free, `noexcept`, no I/O, directly unit-testable. The blocking loop is not portable at all. Its locals do read as the fields of a resumable state value — `{current, autoSelect, firstEvent, itemShown, lastTargetItem, mouseActive}` is six plain values, `menuAction` is a natural step-function result, and the two mouse predicates take the pointer position as an argument — and the switch's discipline (branches assign, one tail block acts) is the same discipline a reducer needs.

> [!IMPORTANT]
> That structural resemblance is an observation about shape, not a claim that rewriting `execute()` as `step(state, event) -> (state, action)` is a mechanical transformation. The catalog's verification pass rejected the general form of that claim; treat the inversion as a redesign whose inputs this subject happens to enumerate unusually clearly, and see [`./proposal.md`](./proposal.md) for what it actually costs.

The warning sign in this dimension is that the overlay's **kind is not a field**. It was inferred from tree position (`parentMenu == 0` implies "I am the menu bar") until `TMenuPopup` — a parentless _box_ — falsified that; commit [`c1715cf`][commit-c1715cf] (2024) replaced it with inference from measured geometry:

```diff
-                        else if ( !parentMenu )
-                        // If a main menu entry was closed, exit and stop listening
+                        else if ( size.y == 1 )
+                        // If a menu bar entry was closed, exit and stop listening
```

Both forms infer a type tag from data that happens to correlate with it.

**Algorithm.** The loop's shape is `switch` (assign only) followed by one effect stage that opens a child or produces a command; the effect stage is the only place either happens.

**Where the behavior lives.** Library code. There is no reducer, no controller object, no observable, and no separation between state and effect other than the tail-of-loop convention.

**Degradation.** The pure geometry survives every target unchanged. The loop does not survive at all.

### 16. Shared infrastructure

What is truly shared is a very small kernel: `TView` (rect in owner cells, state/options bits, clip participation, the clipped write path, event plumbing, `makeGlobal`/`makeLocal`) plus `TGroup` (child list, z-order, optional buffer, `execView`/`execute`/`endModal`). Every overlay in the library — dropdown menu, cascading submenu, context menu, modal dialog, message box, history dropdown, help window — is a rect, an owner group, a nested loop and a `ushort` result. That quadruple is this design's anchored-overlay primitive.

Inside the menu family, `TMenuView` holds `{parentMenu, menu, current, putClickEventOnExit}` and the entire event loop (`include/tvision/menus.h:144`); `TMenuBar` and `TMenuBox` differ only in `draw()` and the virtual `getItemRect()` (`include/tvision/menus.h:155`), plus `TMenuBox`'s intrinsic sizing and its `sfShadow|ofPreProcess`. One virtual — the anchor-rect function — is the whole structural seam between a horizontal bar and a vertical box. `TMenuPopup` (`include/tvision/menus.h:373`) adds roughly forty lines to `TMenuBox`: it owns its menu, opens with no default highlight, swallows the dismissing click, and accepts `Ctrl`+letter shortcuts.

What merely looks common and correctly stayed apart is `THistory`/`THistoryWindow`, the combobox surface, which shares nothing with the menu machine: it is a plain `TWindow` containing a `TListViewer`, dismissed by its own five-line `handleEvent` (`source/tvision/thistwin.cpp:28`). Because it was not forced into the menu abstraction it gets scrollbars, a frame, focus and resizing for free, while the menu keeps its tight focus-less loop. The hint channel from dimension 13 is the other correct separation: the description of the focused element is not an overlay at all.

The failure of factoring, for balance: the occlusion walk exists three times with no shared span iterator, each a separate transliteration of the same assembler.

**Algorithm.** The primitive in this design's form is `(rect in owner-cell coordinates, owner group to insert into, an event sink, a ushort dismissal reason)`. The specialisation points actually used are four: intrinsic-size function, anchor-rect function (the virtual `getItemRect`), pass-through-dismissing-click flag, and initial-highlight policy.

**Where the behavior lives.** Library kernel plus a two-level class hierarchy per family; no cross-family framework.

**Degradation.** The quadruple is target-independent. Two of the four specialisation points are ones a modern toolkit does not always expose — the pass-through-dismissing-click bit, and the initial-highlight policy that differs between pointer-opened and keyboard-opened surfaces; [`./features-people-forget.md`](./features-people-forget.md) collects both.

## Strengths

- `exposed()` answers "is my anchor hidden" with no compositor: a cached `sfExposed` bit, then per-row span subtraction over the front siblings — integer-only, allocation-free, `noexcept`, and directly reusable over a display list's derived hit list.
- Placement is a pure function of (preferred point, boundary rect, intrinsic size) returning a rect: no measurement pass, no observers, no script, no floating point. `autoPlacePopup` achieves shift-then-flip in about ten lines.
- The flip predicate for the cursor-anchored surface is defined against the **anchor point** (`r.contains(p)`) rather than boundary overflow, which is the right rule for a surface that must not cover what it was summoned from.
- The drop shadow is an attribute substitution with a sticky per-cell `slNoShadow` bit, giving idempotence under overlapping and nested shadows with no geometry bookkeeping, plus a per-cell application opt-out for free.
- The shadow attribute is _reversed_ when the destination background is already black, so a shadow over a black area still leaves legible text.
- Timing is replaced by two value memos (`autoSelect`, `lastTargetItem`) that reproduce "neighbours open instantly" and "do not re-open the menu you just closed" with zero timers — decidable purely from an event sequence.
- `putClickEventOnExit` makes "does the dismissing press also reach what is underneath?" an explicit per-overlay bit; menus pass it through, context menus swallow it.
- `TMenuBar` and `TMenuBox` differ in exactly two virtuals, `draw()` and `getItemRect()` — the anchor-rect function is the entire seam between a horizontal and a vertical anchored surface.
- `THistory`/`THistoryWindow` deliberately shares nothing with the menu machine and is therefore a real focusable window with scrollbars, while the menu keeps a focus-less loop. Resistance to premature unification.
- `enterSelect`/`leaveSelect` express save-and-restore-focus across a modal scope with no focus stack, and `execView` additionally snapshots and restores the whole global command-enablement set.
- Dismissal can be vetoed (`while( !valid(endState) )`), with `TDialog::valid` whitelisting `cmCancel` so the escape hatch always works.
- The one honest terminal accessibility channel — hardware caret position — is maintained, and a real point-occlusion query is spent per update to keep it truthful.
- `TTimerQueue` takes an injectable clock and is unit-tested with a mock, which is the pattern any delay-bearing behaviour needs to be assertable headlessly.

## Weaknesses

- The same occlusion walk is implemented three times with no shared abstraction (`tvexposd.cpp`, `tvwrite.cpp`, `tvcursor.cpp`), each a literal transliteration of 16-bit assembler with members named `eax`/`ebx`/`ecx`/`esi` and functions named `L0`…`L23`.
- The overlay's kind is inferred, never declared: `parentMenu == 0` until `TMenuPopup` falsified it, now `size.y == 1`, used at many sites. Geometry as a type tag is a latent bug generator.
- Placement emits no metadata — `getRect` and `autoPlacePopup` return a rect and discard the chosen side or alignment, so no styling or animation layer could know where the popup landed relative to its anchor.
- The boundary is read from `owner->size` rather than passed in, so a viewport inset (soft keyboard, reserved region) cannot be expressed, and "place against one rect, clip to another" is not sayable.
- Nothing re-places on resize (inference — see the note in dimension 3).
- Modality is a nested C++ event loop: the least portable decision here, and it hides the overlay's state inside stack frames where nothing can inspect or serialise it.
- There is no hover and therefore no hover-driven surface at all; the hint/status-line substitute is a single global instance that cannot sit next to what it describes.
- No test covers placement, occlusion, shadow, dismissal or modality. The only overlay-adjacent test in the repository is `test/tvision/tmnuview.test.cpp`, which exercises Unicode `Alt`-shortcut resolution.
- Ambient mutable process globals carry presentation policy: `::shadowSize`, `::shadowAttr`, `TView::showMarkers`, `TView::curCommandSet`, `TheTopView`, and `TProgram::pending` (a single-slot pushback queue). None can vary per surface.
- `THistory` holds a raw `TInputLine*` anchor requiring a manual null-out in `shutDown` — a dangling-anchor hazard a comparable value removes.
- `TGroup::drawUnderRect` restores `owner->clip` to `getExtent()` rather than to a saved value, silently discarding any enclosing clip; it is safe only because it is a top-level entry point.
- `evMouseWheel` is excluded from positional events, so wheel events are broadcast to every subview rather than hit-tested — no overlay implements dismiss-on-scroll, and none does.

> [!WARNING]
> Nothing here was built or executed: every behavioural claim is read from source at `57b6f56`. The 16-bit assembler variants (`tvexposd.asm`, `tvwrite.asm`, `tvcursor.asm`, …) were not read, and the `__BORLANDC__` preprocessor branches were read but not verified. The help subsystem (`source/tvision/help.cpp`) and `TFrame`'s hit zones were not analysed in depth. Whether every platform backend delivers `evMouseMove` with no buttons held was not checked below `source/tvision/tevent.cpp` — the menu ignores such events regardless.

## Key design decisions and trade-offs

| Decision                                                                                                                                    | Rationale                                                                                                                                                                                                                                                                                                                                                      | Trade-off                                                                                                                                                                                                                                                                                                                       |
| ------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Occlusion is resolved per _write_ by subtracting the rects of all views in front, not by painting back to front.                            | With no compositor and a 1990 CPU budget, a full back-to-front repaint per frame was unaffordable. Making every write self-clipping lets any view redraw itself at any time in any order — `TGroup::redraw` even paints front-to-back and is still correct.                                                                                                    | The same walk had to be written three times with no shared span iterator, each a transliteration of assembler. A toolkit that repaints a whole frame back-to-front gets the same result for free, so the _query_ (`exposed`) is the transferable part and the _write path_ is not.                                              |
| Modality is a nested event loop; the loop's return value is the dismissal reason.                                                           | With no window manager there is nothing to ask for modality. Nesting gives exclusivity for free (nobody else dispatches), reads linearly (`if (execView(dlg) == cmOK)`), gives each level a natural home for its state, and gives cascading submenus unbounded nesting with no data structure.                                                                 | It cannot exist in a frame-driven single-surface toolkit, and it costs even here: while an overlay is open nothing else runs — which is precisely why no anchor tracking, scroll dismissal or hidden-anchor detection was ever needed. It also forced a deliberate hole so `F10`/`Alt-X` survive under modality.                |
| Delay heuristics are replaced by two sticky value memos, `autoSelect` and `lastTargetItem`.                                                 | No timer infrastructure existed, and the behaviours wanted from menu timing are not really about time: "neighbours open instantly once one is open" is a mode (one bit), and "clicking a menu's own name must not immediately re-open it" is a re-entry guard keyed on identity (one item pointer, cleared the moment the highlight moves).                    | Genuinely time-based affordances (hover intent, tooltip warm-up) become impossible, and the guards are subtle enough to have attracted two upstream fixes ([`544e341`][commit-544e341], [`c1715cf`][commit-c1715cf]). For a target with no clock, value memos are decidable from an event sequence alone, which timers are not. |
| An overlay's escape level is "which `TGroup` do you insert into", not a layer or a z-index.                                                 | Ownership already determines clipping and coordinate space, so reusing it for escape is free and unambiguous — a submenu escapes the bar's one-row extent, `popupMenu` was moved from `deskTop` to `application` to gain the full screen, and `THistoryWindow` is inserted into the dialog and therefore deliberately clipped by it.                           | The clipping boundary and the placement boundary become the same object, so "place against the screen but clip to the dialog" is unsayable — and the boundary is read (`owner->size`) rather than passed, which is exactly what blocks an inset from entering the calculation.                                                  |
| Whether the dismissing outside-press also reaches the view underneath is a per-overlay boolean (`putClickEventOnExit`).                     | Menus and dropdowns want the press to go through, so one click both closes the menu and acts on the target — the source comment says so ("Let the event reach the view recovering focus"). Context menus want it swallowed, so a right-click followed by a click away does not act.                                                                            | None observed in this tree; it costs one bit and one `putEvent` call. The cost is that the choice is a constructor-time constant rather than a per-open decision.                                                                                                                                                               |
| Escape consumption is asymmetric: consumed at the top level and inside box-parented submenus, not consumed when the parent is the menu bar. | Escape from a deep submenu should back out one level; Escape from a first-level dropdown should also release the bar rather than leave it highlighted-but-closed. Leaving the event uncleared and re-posting it makes the parent's independent loop see the same keypress.                                                                                     | The rule (`parentMenu == 0 \|\| parentMenu->size.y != 1`) encodes intent indirectly through geometry, so it is unreadable without knowing that height 1 means "menu bar"; and re-posting goes through `TProgram::pending`, a single-slot queue, so exactly one event may be pushed back at a time.                              |
| When the shadow channel is unavailable, substitute a glyph affordance rather than removing the decoration.                                  | `TProgram::initScreen` sets `shadowSize = {0,0}` and `showMarkers = true` together on monochrome displays, and every widget then brackets its focused element. The elevation/focus signal must live in some channel, so the toolkit trades a colour channel for a glyph channel at a single decision point.                                                    | The signal is carried by two mutable process globals read at draw time, which makes it untestable in isolation and impossible to vary per surface — but the shape (capability probe at the top, replacement affordance at the bottom) is the transferable part.                                                                 |
| The description of the focused element is not an overlay: it is a `ushort` help context rendered into a fixed status line.                  | A terminal has no AT tree, no hover and no timers, so a floating tooltip would be both unimplementable and hostile. A comparable integer on every view plus a fixed region rendering `hint(helpCtx)` gives context-sensitive description with zero placement, zero timing, zero dismissal and zero occlusion risk — and it composes up the `parentMenu` chain. | It is a single global instance, so two things cannot be described at once, and the description cannot be adjacent to what it describes. In exchange it never obscures content, never disappears, and works on every target including static HTML.                                                                               |

## Sources

Primary sources, all read at `57b6f56b38e0ee75240a80a10ee0e11470c24693`:

- Placement — [`source/tvision/tmenubox.cpp:25` `getRect`][tmenubox-getrect] (intrinsic size + shift), [`:125` `TMenuBox::getItemRect`][tmenubox-getitemrect], [`source/tvision/tmenubar.cpp:94` `TMenuBar::getItemRect`][tmenubar-getitemrect], [`source/tvision/popupmnu.cpp:70` `autoPlacePopup`][popupmnu-autoplace], [`:49` `popupMenu`][popupmnu-popupmenu], [`source/tvision/thistory.cpp:90` dropdown rect][thistory-handleevent], [`source/tvision/tmnuview.cpp:376` submenu anchor + boundary + portal][tmnuview-open].
- Geometry kernel — [`source/tvision/tvexposd.cpp:39` `TView::exposed`][tvexposd-exposed], [`source/tvision/tvcursor.cpp:78` `TVCursor::caretCovered`][tvcursor-caretcovered], [`source/tvision/tview.cpp:475` `getClipRect`][tview-getcliprect], [`source/tvision/tview.cpp:387` `drawUnderRect`][tview-drawunderrect], [`source/tvision/tview.cpp:134` `calcBounds`][tview-calcbounds].
- Shadow — [`source/tvision/tvwrite.cpp:62` `applyShadow`][tvwrite-applyshadow], [`source/tvision/tvwrite.cpp:167` shadow-region derivation][tvwrite-shadowregion], [`include/tvision/colors.h:496` `slNoShadow`][colors-slnoshadow], [`source/tvision/tprogram.cpp:244` `TProgram::initScreen`][tprogram-initscreen].
- Menu machine — [`source/tvision/tmnuview.cpp:179` `TMenuView::execute`][tmnuview-execute], [`:148` `mouseInOwner`][tmnuview-mouseinowner], [`:160` `mouseInMenus`][tmnuview-mouseinmenus], [`:218` outside-press dismissal][tmnuview-outsidepress], [`:263` `evMouseMove` guarded by held buttons][tmnuview-mousemove], [`:308` `kbEsc`][tmnuview-esc], [`source/tvision/tmenupop.cpp:27` `putClickEventOnExit = False`][tmenupop-noclick], [`:38` `menu->deflt = 0`][tmenupop-deflt].
- Modality and focus — [`source/tvision/tgroup.cpp:173` `TGroup::execute`][tgroup-execute], [`:188` `TGroup::execView`][tgroup-execview], [`:224` `findNext`][tgroup-findnext], [`:476` `setCurrent`][tgroup-setcurrent], [`include/tvision/views.h:345` `enum selectMode`][views-selectmode], [`source/tvision/tprogram.cpp:153` status-line carve-out inside `getEvent`][tprogram-getevent], [`source/tvision/tdialog.cpp:91` `TDialog::valid`][tdialog-valid], [`source/tvision/thistwin.cpp:54` `THistoryWindow::handleEvent`][thistwin-handleevent].
- Accessibility surrogates — [`source/tvision/tvcursor.cpp:36` `resetCursor`][tvcursor-resetcursor], [`source/tvision/tstatusl.cpp:204` `TStatusLine::hint`][tstatusl-hint], [`:210` `TStatusLine::update`][tstatusl-update], [`source/tvision/tmnuview.cpp:453` `getHelpCtx`][tmnuview-helpctx].
- Tests and timing substrate — [`test/tvision/tmnuview.test.cpp:67` `TestGroup` with an injected event queue][test-tmnuview], [`source/tvision/ttimerqu.cpp:19` injectable clock][ttimerqu-clock], [`source/platform/dispbuff.cpp:104` `setDirty`][dispbuff-setdirty].
- History — commits [`3f40740` "Improve placement of popup menus"][commit-3f40740], [`c1715cf` (kind inferred from geometry)][commit-c1715cf], [`544e341` (closing empty submenus)][commit-544e341].

Related pages in this catalog: [`./index.md`](./index.md), [`./concepts.md`](./concepts.md), [`./comparison.md`](./comparison.md), [`./features-people-forget.md`](./features-people-forget.md), [`./sparkles-baseline.md`](./sparkles-baseline.md), [`./proposal.md`](./proposal.md). Nearest neighbours by surface model: [`./notcurses.md`](./notcurses.md), [`./textual.md`](./textual.md), [`./ratatui.md`](./ratatui.md), [`./tmux-popup.md`](./tmux-popup.md), [`./neovim-floats.md`](./neovim-floats.md), [`./helix.md`](./helix.md), [`./imgui.md`](./imgui.md). Sibling research trees: [`../window-system-integration/index.md`](../window-system-integration/index.md), [`../ui-layout/index.md`](../ui-layout/index.md).

<!-- References -->

[tv-repo]: https://github.com/magiblot/tvision/tree/57b6f56b38e0ee75240a80a10ee0e11470c24693
[tv-readme]: https://github.com/magiblot/tvision/blob/57b6f56b38e0ee75240a80a10ee0e11470c24693/README.md
[tv-copyright]: https://github.com/magiblot/tvision/blob/57b6f56b38e0ee75240a80a10ee0e11470c24693/COPYRIGHT
[tmenubox-getrect]: https://github.com/magiblot/tvision/blob/57b6f56b38e0ee75240a80a10ee0e11470c24693/source/tvision/tmenubox.cpp#L25
[tmenubox-getitemrect]: https://github.com/magiblot/tvision/blob/57b6f56b38e0ee75240a80a10ee0e11470c24693/source/tvision/tmenubox.cpp#L125
[tmenubar-getitemrect]: https://github.com/magiblot/tvision/blob/57b6f56b38e0ee75240a80a10ee0e11470c24693/source/tvision/tmenubar.cpp#L94
[popupmnu-autoplace]: https://github.com/magiblot/tvision/blob/57b6f56b38e0ee75240a80a10ee0e11470c24693/source/tvision/popupmnu.cpp#L70
[popupmnu-popupmenu]: https://github.com/magiblot/tvision/blob/57b6f56b38e0ee75240a80a10ee0e11470c24693/source/tvision/popupmnu.cpp#L42
[thistory-handleevent]: https://github.com/magiblot/tvision/blob/57b6f56b38e0ee75240a80a10ee0e11470c24693/source/tvision/thistory.cpp#L90
[tmnuview-open]: https://github.com/magiblot/tvision/blob/57b6f56b38e0ee75240a80a10ee0e11470c24693/source/tvision/tmnuview.cpp#L376
[tmnuview-execute]: https://github.com/magiblot/tvision/blob/57b6f56b38e0ee75240a80a10ee0e11470c24693/source/tvision/tmnuview.cpp#L179
[tmnuview-mouseinowner]: https://github.com/magiblot/tvision/blob/57b6f56b38e0ee75240a80a10ee0e11470c24693/source/tvision/tmnuview.cpp#L148
[tmnuview-mouseinmenus]: https://github.com/magiblot/tvision/blob/57b6f56b38e0ee75240a80a10ee0e11470c24693/source/tvision/tmnuview.cpp#L160
[tmnuview-outsidepress]: https://github.com/magiblot/tvision/blob/57b6f56b38e0ee75240a80a10ee0e11470c24693/source/tvision/tmnuview.cpp#L218
[tmnuview-mousemove]: https://github.com/magiblot/tvision/blob/57b6f56b38e0ee75240a80a10ee0e11470c24693/source/tvision/tmnuview.cpp#L263
[tmnuview-esc]: https://github.com/magiblot/tvision/blob/57b6f56b38e0ee75240a80a10ee0e11470c24693/source/tvision/tmnuview.cpp#L308
[tmnuview-helpctx]: https://github.com/magiblot/tvision/blob/57b6f56b38e0ee75240a80a10ee0e11470c24693/source/tvision/tmnuview.cpp#L453
[tmenupop-noclick]: https://github.com/magiblot/tvision/blob/57b6f56b38e0ee75240a80a10ee0e11470c24693/source/tvision/tmenupop.cpp#L27
[tmenupop-deflt]: https://github.com/magiblot/tvision/blob/57b6f56b38e0ee75240a80a10ee0e11470c24693/source/tvision/tmenupop.cpp#L38
[tvexposd-exposed]: https://github.com/magiblot/tvision/blob/57b6f56b38e0ee75240a80a10ee0e11470c24693/source/tvision/tvexposd.cpp#L39
[tvcursor-caretcovered]: https://github.com/magiblot/tvision/blob/57b6f56b38e0ee75240a80a10ee0e11470c24693/source/tvision/tvcursor.cpp#L78
[tvcursor-resetcursor]: https://github.com/magiblot/tvision/blob/57b6f56b38e0ee75240a80a10ee0e11470c24693/source/tvision/tvcursor.cpp#L36
[tvwrite-applyshadow]: https://github.com/magiblot/tvision/blob/57b6f56b38e0ee75240a80a10ee0e11470c24693/source/tvision/tvwrite.cpp#L62
[tvwrite-shadowregion]: https://github.com/magiblot/tvision/blob/57b6f56b38e0ee75240a80a10ee0e11470c24693/source/tvision/tvwrite.cpp#L167
[colors-slnoshadow]: https://github.com/magiblot/tvision/blob/57b6f56b38e0ee75240a80a10ee0e11470c24693/include/tvision/colors.h#L496
[tprogram-initscreen]: https://github.com/magiblot/tvision/blob/57b6f56b38e0ee75240a80a10ee0e11470c24693/source/tvision/tprogram.cpp#L244
[tprogram-getevent]: https://github.com/magiblot/tvision/blob/57b6f56b38e0ee75240a80a10ee0e11470c24693/source/tvision/tprogram.cpp#L153
[tgroup-execute]: https://github.com/magiblot/tvision/blob/57b6f56b38e0ee75240a80a10ee0e11470c24693/source/tvision/tgroup.cpp#L173
[tgroup-execview]: https://github.com/magiblot/tvision/blob/57b6f56b38e0ee75240a80a10ee0e11470c24693/source/tvision/tgroup.cpp#L188
[tgroup-findnext]: https://github.com/magiblot/tvision/blob/57b6f56b38e0ee75240a80a10ee0e11470c24693/source/tvision/tgroup.cpp#L224
[tgroup-setcurrent]: https://github.com/magiblot/tvision/blob/57b6f56b38e0ee75240a80a10ee0e11470c24693/source/tvision/tgroup.cpp#L476
[views-selectmode]: https://github.com/magiblot/tvision/blob/57b6f56b38e0ee75240a80a10ee0e11470c24693/include/tvision/views.h#L345
[tview-getcliprect]: https://github.com/magiblot/tvision/blob/57b6f56b38e0ee75240a80a10ee0e11470c24693/source/tvision/tview.cpp#L475
[tview-drawunderrect]: https://github.com/magiblot/tvision/blob/57b6f56b38e0ee75240a80a10ee0e11470c24693/source/tvision/tview.cpp#L387
[tview-calcbounds]: https://github.com/magiblot/tvision/blob/57b6f56b38e0ee75240a80a10ee0e11470c24693/source/tvision/tview.cpp#L134
[tview-makeglobal]: https://github.com/magiblot/tvision/blob/57b6f56b38e0ee75240a80a10ee0e11470c24693/source/tvision/tview.cpp#L612
[tdialog-valid]: https://github.com/magiblot/tvision/blob/57b6f56b38e0ee75240a80a10ee0e11470c24693/source/tvision/tdialog.cpp#L91
[thistwin-handleevent]: https://github.com/magiblot/tvision/blob/57b6f56b38e0ee75240a80a10ee0e11470c24693/source/tvision/thistwin.cpp#L54
[tstatusl-hint]: https://github.com/magiblot/tvision/blob/57b6f56b38e0ee75240a80a10ee0e11470c24693/source/tvision/tstatusl.cpp#L204
[tstatusl-update]: https://github.com/magiblot/tvision/blob/57b6f56b38e0ee75240a80a10ee0e11470c24693/source/tvision/tstatusl.cpp#L210
[test-tmnuview]: https://github.com/magiblot/tvision/blob/57b6f56b38e0ee75240a80a10ee0e11470c24693/test/tvision/tmnuview.test.cpp#L67
[ttimerqu-clock]: https://github.com/magiblot/tvision/blob/57b6f56b38e0ee75240a80a10ee0e11470c24693/source/tvision/ttimerqu.cpp#L19
[dispbuff-setdirty]: https://github.com/magiblot/tvision/blob/57b6f56b38e0ee75240a80a10ee0e11470c24693/source/platform/dispbuff.cpp#L104
[commit-3f40740]: https://github.com/magiblot/tvision/commit/3f40740c28ce03304af3e1d08de5e8ce0bfdaa70
[commit-c1715cf]: https://github.com/magiblot/tvision/commit/c1715cf1aa69c5f14c35356105d3a26d4d3b5788
[commit-544e341]: https://github.com/magiblot/tvision/commit/544e341db5d483261b2d0070c4bafd08ac7cc6c2
