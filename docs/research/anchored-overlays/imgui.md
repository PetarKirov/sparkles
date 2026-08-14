# Dear ImGui — popup stack, `BeginPopupContextItem` and tooltips (C++, immediate mode)

Dear ImGui resolves every anchored overlay — context menu, submenu, combo, modal and
tooltip — with two flat arrays of plain-old-data, one ~70-line integer placement
function and a single draw-layer bit, with no OS window, no compositor, no pointer grab
and no retained node anywhere in the path.

| Field             | Value                                                                                                 |
| ----------------- | ----------------------------------------------------------------------------------------------------- |
| Language          | C++ (C++11-era subset; no STL in the public surface)                                                  |
| License           | MIT                                                                                                   |
| Repository        | [ocornut/imgui][repo]                                                                                 |
| Documentation     | [`docs/FAQ.md`][docs-faq] in-tree; header comments in [`imgui.h`][src-imgui-h]                        |
| Category          | Immediate-mode GUI toolkit                                                                            |
| Surface model     | In-canvas — see the surface-model note below                                                          |
| **Revision read** | [`46d39d56febc2a00bdd2270dc88c8a13f2a0441a`][repo-pin] (`IMGUI_VERSION` `"1.93.0 WIP"`, `imgui.h:32`) |

On the `master` branch read here there is exactly one `ImGuiViewport`. Every popup,
tooltip, menu and combo is an ordinary `ImGuiWindow` rasterized into the same
`ImDrawData` that the application's own windows go into; the backend receives one
command list and is never told that a popup exists. That makes ImGui one of the few
subjects in this catalog whose native substrate already matches the
[one-surface model][baseline] `sparkles:ui` is confined to — no [top layer][concepts],
no z-index space, no [grab][concepts], integer-truncated positions, and hit testing
against the previous frame's state.

> [!NOTE]
> This page is a source reading, not a runtime observation: nothing was built or
> executed. Two limits on scope are worth stating up front. (1) The docking /
> multi-viewport branch is **not** in this clone, so every placement claim here is for
> the single-viewport `master` branch; multi-monitor placement and the platform-window
> path for popups differ there and were not examined. (2) There are no tests in this
> tree at this revision — the `imgui_test_engine` repository that holds the popup, menu
> and tooltip regressions is separate, and only the `IMGUI_TEST_ENGINE_ITEM_INFO` hook
> macros are visible from here. Nothing on this page is pinned by a test.

---

## Overview

### What it solves

An immediate-mode library has no place to put per-widget state. The widget that opened a
context menu does not exist between frames; there is no node to hang a `bool isOpen` on,
no object to observe, and no callback target that survives to the next frame. ImGui's
answer is to make the overlay's whole existence a value in a library-owned array, keyed
by a hashed id, and to make every query about that overlay a comparison of two array
lengths.

The demo states the design consequence directly, and the reasoning generalises to any
toolkit whose overlays can be dismissed by something other than the caller:

> ```cpp
> // imgui_demo.cpp:5431-5434
> //   as we are used to with regular Begin() calls. User can manipulate the visibility state by calling OpenPopup().
> // Those three properties are connected. The library needs to hold their visibility state BECAUSE it can close
> // popups at any time.
> ```

Because the library closes popups on outside click, on `Escape`, on focus change and on
item activation, a caller-owned boolean would be perpetually stale — so the API is
exclusively uncontrolled. The escape hatch added in this development cycle is that
`OpenPopup` now returns `bool` ("true when the popup is toggled open, which allows you to
capture local state if needed", `imgui.cpp:12484-12485`; changelog entry at
`docs/CHANGELOG.txt:166-168`).

### Design philosophy

Three commitments run through the whole subject.

**Everything is plain data.** `ImGuiPopupData` (`imgui_internal.h:1508`) is two `ImGuiID`,
two `ImGuiWindow*`, two `int` and two `ImVec2`, with a constructor that is a `memset`
followed by two field assignments. `g.OpenPopupStack` and `g.BeginPopupStack` are two
`ImVector<ImGuiPopupData>` (`imgui_internal.h:2376-2377`) and records are pushed **by
value** — `Begin()` copies the resolved record into the frame-scoped stack
(`imgui.cpp:7635`).

**Geometry is integer arithmetic over rectangles.** Placement is add, subtract, `min`,
`max` and compare, with no measurement API, no clipping-ancestor discovery and no
observers. Positions are truncated to whole units every frame
(`window->Pos = ImTrunc(window->Pos)`, `imgui.cpp:7918`) and the mouse position is
floored (`imgui.cpp:10420`).

**Prefer a geometric predicate to a timer.** The submenu "safe area" is implemented as a
triangle test and the source says why:

> ```cpp
> // imgui_widgets.cpp:9504-9505
> // Close menu when not hovering it anymore unless we are moving roughly in the direction of the menu
> // Implement http://bjk5.com/post/44698559168/breaking-down-amazons-mega-dropdown to avoid using timers, so menus feels more reactive.
> ```

Where a timer is unavoidable — hover warm-up — the whole machine is five scalars on the
context and about twenty-five lines, with a frame-rate-aware floor so it does not
misbehave at low frame rates:

> ```cpp
> // imgui.cpp:5735-5738
> // This gives a little bit of leeway before clearing the hover timer, allowing mouse to cross gaps
> // We could expose 0.25f as style.HoverClearDelay but I am not sure of the logic yet, this is particularly subtle.
> g.HoverItemDelayClearTimer += g.IO.DeltaTime;
> if (g.HoverItemDelayClearTimer >= ImMax(0.25f, g.IO.DeltaTime * 2.0f)) // ~7 frames at 30 Hz + allow for low framerate
> ```

---

## How it works

### The two stacks

`g.OpenPopupStack` persists across frames and answers _what is open_.
`g.BeginPopupStack` is cleared at the top of every frame
(`g.BeginPopupStack.resize(0)`, `imgui.cpp:5846`) and answers _how deep the current
submission is_. Openness at the current nesting level is one line
(`imgui.cpp:12397`):

```cpp
return g.OpenPopupStack.Size > g.BeginPopupStack.Size && g.OpenPopupStack[g.BeginPopupStack.Size].PopupId == id;
```

Every other query is a variation: any popup open at this level is the size comparison
alone; any popup open anywhere is `OpenPopupStack.Size > 0`; a specific id open anywhere
is a linear scan (`imgui.cpp:12371-12400`).

### One placement function, three policies

`FindBestWindowPosForPopupEx` (`imgui.cpp:12893`) is the single placement routine for the
whole library. Its signature is the entire interface between "what kind of surface is
this" and "where does it go":

```cpp
// imgui_internal.h:3521
IMGUI_API ImVec2 FindBestWindowPosForPopupEx(const ImVec2& ref_pos, const ImVec2& size, ImGuiDir* last_dir, const ImRect& r_outer, const ImRect& r_avoid, ImGuiPopupPositionPolicy policy);
```

A reference point, a size, an in/out last-direction, an outer clip rect, an "avoid" rect
and a three-value policy enum (`ImGuiPopupPositionPolicy_Default` / `_ComboBox` /
`_Tooltip`, `imgui_internal.h:1500`). No side parameter, no gap, no alignment: the
_kind_ of surface is expressed entirely by the shape of `r_avoid`, which is built per
window-flag in the thin wrapper `FindBestWindowPosForPopup` (`imgui.cpp:12978`).

The candidate loop is the whole collision engine. Its overflow test is two subtractions:

```cpp
// imgui.cpp:12931-12932
const float avail_w = (dir == ImGuiDir_Left ? r_avoid.Min.x : r_outer.Max.x) - (dir == ImGuiDir_Right ? r_avoid.Max.x : r_outer.Min.x);
const float avail_h = (dir == ImGuiDir_Up ? r_avoid.Min.y : r_outer.Max.y) - (dir == ImGuiDir_Down ? r_avoid.Max.y : r_outer.Min.y);
```

### Where placement is called from

`Begin()` dispatches by window flag (`imgui.cpp:7899-7904`):

```cpp
else if ((flags & ImGuiWindowFlags_ChildMenu) != 0)
    window->Pos = FindBestWindowPosForPopup(window);
else if ((flags & ImGuiWindowFlags_Popup) != 0 && !window_pos_set_by_api && window_just_appearing_after_hidden_for_resize)
    window->Pos = FindBestWindowPosForPopup(window);
else if ((flags & ImGuiWindowFlags_Tooltip) != 0 && !window_pos_set_by_api && !window_is_child_tooltip)
    window->Pos = FindBestWindowPosForPopup(window);
```

A child menu and a tooltip are re-placed **every frame**; a plain popup is placed **once**,
on the frame it stops being hidden-for-resize, and its position is then frozen. That
single `else if` is the difference between a tracking overlay and a latched one, and it
is the whole tracking model.

`BeginComboPopup` (`imgui_widgets.cpp:2019`) is the one surface that bypasses the
dispatch: it peeks `CalcWindowNextAutoFitSize()` on the recycled combo window and calls
the placement function itself before `Begin` (`imgui_widgets.cpp:2058-2067`), because a
combo's _size_ depends on its anchor (minimum width = anchor width).

### Tooltips are outside all of this

A tooltip has no entry in either stack, no id, no dismissal logic and no focus
interaction. It is a window carrying `ImGuiWindowFlags_Tooltip | ImGuiWindowFlags_NoInputs`
(`imgui.cpp:12316`), named from a counter (`"##Tooltip_%02d"`, `imgui.cpp:12313`), drawn
on the second of two draw layers, and timed by the hover system rather than the popup
system. The only thing it shares with a popup is `FindBestWindowPosForPopupEx`.

---

## The analysis spine

### 1. Anchor model

The [anchor rect][concepts] is collapsed to a **point plus an avoid rect** before
placement runs; no element-anchor or rect-anchor abstraction survives into the placement
call. `OpenPopupEx` latches both at open time and never updates them
(`imgui.cpp:12502-12506`):

```cpp
popup_ref.RestoreNavWindow = g.NavWindow;
popup_ref.OpenParentId = parent_window->IDStack.back();
popup_ref.OpenPopupPos = NavCalcPreferredRefPos(ImGuiWindowFlags_Popup);
popup_ref.OpenMousePos = IsMousePosValid(&g.IO.MousePos) ? g.IO.MousePos : popup_ref.OpenPopupPos;
```

`NavCalcPreferredRefPos` (`imgui.cpp:13926`) forks on the input source: a mouse-driven
open anchors to the **cursor**, offset by one unit on x, while a keyboard or gamepad open
anchors to the focused item's **bottom-left**, inset by `FramePadding` and clamped to the
viewport. The one-unit offset carries its own justification:

> ```cpp
> // imgui.cpp:13935-13937
> // The +1.0f offset when stored by OpenPopupEx() allows reopening this or another popup (same or another mouse button) while not moving the mouse, it is pretty standard.
> ImVec2 p = IsMousePosValid(&g.IO.MousePos) ? g.IO.MousePos : g.MouseLastValidPos;
> return ImVec2(p.x + 1.0f, p.y);
> ```

Five distinct anchor kinds exist, and each is expressed _only_ as the `r_avoid` passed to
placement (`imgui.cpp:12978-13029`):

| Kind          | `r_avoid`                                                                                                                                          |
| ------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| Plain popup   | degenerate point rect `ImRect(window->Pos, window->Pos)` — with the source's own comment `// Ideally we'd disable r_avoid here` (`:12999`)         |
| Child menu    | infinite **vertical band** over the parent menu's x-range, inset by `style.ItemInnerSpacing.x` on both sides and by the scrollbar width (`:12994`) |
| Menu-bar menu | infinite **horizontal band** over the parent's clip-rect y-range (`:12992`)                                                                        |
| Tooltip       | synthetic cursor box around the reference point, asymmetric: 16 left, 8 up, `24 * scale` right and down (`:13022-13025`)                           |
| Combo         | the widget's real bounding box `bb` — the only case where the anchor is the trigger's rect (`imgui_widgets.cpp:2065`)                              |

Many-triggers-to-one-popup is supported by **id**, not by anchor:
`BeginPopupContextItem(str_id)` with an explicit id lets any call site `OpenPopup` the
same id, while `str_id == NULL` makes the popup id _be_ the last item's id
(`imgui.cpp:12854`) — anchor and identity become the same value. Ids are hashed against
the parent window's `IDStack`, and `OpenParentId` records `IDStack.back()` at open so two
menu sets built from the same strings are distinguishable.

Detached trigger-versus-anchor is not modelled. Text-range anchors, multi-rect anchors
and [virtual anchors][concepts] are absent.

**Algorithm.**

```text
anchor_point(input_source):
    if input_source == mouse:
        p = valid(mouse) ? mouse : lastValidMouse
        return (p.x + 1, p.y)
    else:
        r = navItemRect
        return trunc(clamp((r.x0 + min(4 * padX, r.w),
                            r.y1 - min(padY, r.h)), viewport))

avoid_rect(kind):
    popup         -> Rect(p, p)                             // degenerate
    tooltip       -> Rect(p - (16, 8), p + (24s, 24s))      // synthetic cursor box
    submenu(vert) -> Rect(parent.x0 + ov, -INF, parent.x1 - ov - sb, +INF)
    submenu(bar)  -> Rect(-INF, parentClip.y0, +INF, parentClip.y1)
    combo         -> widget bounding box
```

The stored anchor is exactly `(ImGuiID id, ImVec2 pos, ImVec2 mousePos, ImGuiID parentId, int frame)` —
a comparable value with no pointers into the widget tree.

**Where the behavior lives.** Library core. `OpenPopupEx` (`imgui.cpp:12489`) latches;
`NavCalcPreferredRefPos` (`:13926`) converts an input source to a point;
`FindBestWindowPosForPopup` (`:12978`) builds the avoid rect per window-flag kind.
Nothing is delegated to a backend or an OS.

**Degradation.** The representation is two integer points, so it survives every axis: no
OS window, no hover, no script and no sub-cell precision are needed to compute or store
it. Where hover does not exist, the mouse branch of `NavCalcPreferredRefPos` has no
input and the nav branch — the item's bottom-left — is the correct default; ImGui
already carries that branch. The one porting hazard is the `+1.0f` cursor offset: in
whole cells the same trick costs a **whole cell** and is visible, so a cell toolkit
should express the intent directly (exclude the anchor cell from the overlay rect)
rather than nudging the point. Latching the anchor at open is what makes the model
assertable on a recording canvas — an open popup's position becomes a pure function of
latched values, the current size and the viewport.

### 2. Placement model

One function, three policies, four directions, a fixed fallback order and
last-direction hysteresis.

**Candidate order.** `Default` and `Tooltip` share `{Right, Down, Up, Left}`;
`ComboBox` uses `{Down, Right, Left, Up}` in which the direction names are **misleading**
— in that branch `Down` means "below, toward right", `Right` means "above, toward
right", `Left` means "below, toward left" and `Up` means "above, toward left"
(`imgui.cpp:12909-12912`, and the source annotates each line accordingly).

**Hysteresis.** Both loops start at `n = -1` when a direction was recorded last frame, so
the previous choice is retried first and then skipped when it recurs in the ordered list
(`imgui.cpp:12903-12906` and `:12925-12929`):

```cpp
for (int n = (*last_dir != ImGuiDir_None) ? -1 : 0; n < ImGuiDir_COUNT; n++)
{
    const ImGuiDir dir = (n == -1) ? *last_dir : dir_preferred_order[n];
    if (n != -1 && dir == *last_dir) // Already tried this direction?
        continue;
```

That is three lines, and it is what stops a surface near a boundary from flip-flopping
between two sides when its size changes by a unit frame to frame.

**Shift is not a pass.** `base_pos_clamped = ImClamp(ref_pos, r_outer.Min, r_outer.Max - size)`
is computed once at the top (`imgui.cpp:12895`) and used verbatim as the **cross-axis**
coordinate of every candidate. [Flip][concepts] is the direction loop; [slide][concepts]
is that single pre-clamp. There is no third stage except in the fallback.

**Skip rule.** Only the candidate's **own** axis is checked: a horizontal candidate is
skipped when `avail_w < size.x`, a vertical one when `avail_h < size.y`. The cross axis
is assumed satisfied by the pre-clamp. The source explains the intent inline: "If there's
not enough room on one axis, there's no point in positioning on a side on this axis (e.g.
when not enough width, use a top/bottom position to maximize available width)".

**Asymmetric clamp.** After choosing, only the top-left is clamped
(`pos.x = ImMax(pos.x, r_outer.Min.x)` and the y analogue, `imgui.cpp:12944-12945`), so an
oversize overlay overflows bottom/right and never hides its own origin.

**ComboBox differs on purpose.** It requires full containment
(`if (!r_outer.Contains(ImRect(pos, pos + size))) continue;`, `imgui.cpp:12913`) with no
clamping at all, because it wants a connecting edge or nothing.

**Fallback.** When no direction fits, `*last_dir = ImGuiDir_None` and the policies part
ways — this is a rare case of a placement engine documenting _which constraint loses
last_:

> ```cpp
> // imgui.cpp:12956-12958
> // For tooltip we prefer avoiding the cursor at all cost even if it means that part of the tooltip won't be visible.
> if (policy == ImGuiPopupPositionPolicy_Tooltip)
>     return ref_pos + ImVec2(2, 2);
> ```

Everything else gets a classic push into view:
`max(min(p + size, outer.max) - size, outer.min)` per axis (`imgui.cpp:12961-12964`).

**Boundary.** `GetPopupAllowedExtentRect` (`imgui.cpp:12968`) returns the viewport's
`GetMainRect()` — deliberately **not** `GetWorkRect()`:

> ```cpp
> // imgui.cpp:12967
> // Note that this is used for popups, which can overlap the non work-area of individual viewports.
> ```

It is then deflated by `style.DisplaySafeAreaPadding`, but only per axis where the
viewport is more than twice the padding (`imgui.cpp:12974`), so a transiently tiny display
cannot invert the rect. Safe-area insets exist as a first-class concept elsewhere —
`ImGuiViewportP::WorkInsetMin` / `WorkInsetMax` are documented as "Generally
'safeAreaInsets' in iOS land, 'DisplayCutout' in Android land"
(`imgui_internal.h:2006-2012`) — but popup placement bypasses them.

RTL, writing modes and logical side vocabulary are absent from the placement code
entirely. Multi-monitor is out of scope on this branch. Keyboard-inset avoidance is
absent: IME data flows _outward_ only (`Platform_SetImeDataFn` reports the caret position
to the OS, `imgui.h:4069`), and nothing feeds a keyboard rect back into `r_outer`.

**Algorithm.**

```text
place(ref, size, inout lastDir, rOuter, rAvoid, policy):
    base = clamp(ref, rOuter.min, rOuter.max - size)

    if policy == ComboBox:
        order = [Down, Right, Left, Up]
        for n in (lastDir != None ? -1 : 0) .. 3:
            d = (n == -1) ? lastDir : order[n]
            if n != -1 and d == lastDir: continue
            pos = corner_alignment(d, rAvoid, size)
            if not rOuter.contains(pos, pos + size): continue
            lastDir = d; return pos

    if policy in {Default, Tooltip}:
        order = [Right, Down, Up, Left]
        for n in (lastDir != None ? -1 : 0) .. 3:
            d = (n == -1) ? lastDir : order[n]
            if n != -1 and d == lastDir: continue
            availW = (d == Left ? rAvoid.x0 : rOuter.x1) - (d == Right ? rAvoid.x1 : rOuter.x0)
            availH = (d == Up   ? rAvoid.y0 : rOuter.y1) - (d == Down  ? rAvoid.y1 : rOuter.y0)
            if availW < size.x and d in {Left, Right}: continue
            if availH < size.y and d in {Up, Down}:    continue
            pos.x = d == Left ? rAvoid.x0 - size.x : d == Right ? rAvoid.x1 : base.x
            pos.y = d == Up   ? rAvoid.y0 - size.y : d == Down  ? rAvoid.y1 : base.y
            pos = max(pos, rOuter.min)            // top-left clamp only
            lastDir = d; return pos

    lastDir = None
    if policy == Tooltip: return ref + (2, 2)     // clip rather than sit on the pointer
    return (max(min(ref.x + size.x, rOuter.x1) - size.x, rOuter.x0),
            max(min(ref.y + size.y, rOuter.y1) - size.y, rOuter.y0))
```

**Where the behavior lives.** Library core, `imgui.cpp:12893`. Called from `Begin()`
(`:7899-7904`) and directly from `BeginComboPopup`. No backend and no platform layer
participate.

**Degradation.** Every operation is `+`, `-`, `min`, `max` and compare; the `float` is a
data type, not a requirement. Worst case is roughly forty integer operations. The
tooltip's `24 * scale` cursor box and the `(2, 2)` fallback need cell-sized replacements
— the natural one being an avoid rect of the single pointer cell expanded by one cell
right and down. Two gaps matter for a cell toolkit. First, the soft-keyboard inset:
ImGui models it and then does not use it here, so a port must fold the inset into
`r_outer` itself rather than into a work rect that placement ignores. Second, a
script-free HTML target cannot run the candidate loop at emit time; the honest reduction
is to emit **one** side chosen by a static estimate and accept clipping — see the
[shared vocabulary][concepts] entry for constraint adjustment, and
[`./comparison.md`][comparison] for how other subjects land the same question.

### 3. Collision and geometry engine

There is no geometry engine, and the absence is structural rather than an omission.
Overflow detection is the two subtractions above. There is no clipping-ancestor discovery
because a popup is not a child in a clip hierarchy: it is a root window in `g.Windows`
with its own clip rect, so it escapes scroll containers by construction. There are no
transforms, no zoom, no device-pixel-ratio and no fractional-pixel handling —
`window->Pos` is truncated every frame (`imgui.cpp:7918`) and the mouse position is
floored, with the source noting that non-rounded positions break `UpdateManualResize`
(`imgui.cpp:10420`).

**Tracking model: polling, once per frame, inside the frame the widget is submitted.**
No observers, no callbacks, no dirty flags. Cost is O(1) per overlay per frame plus the
window sort. "Layout shift" is not a category that exists, because everything is
recomputed from scratch each frame — except where the library deliberately opts out:
a plain popup's position is computed once and frozen, so if the anchoring item scrolls
away the popup does not move. Child menus and tooltips are recomputed every frame.

**Auto-size costs one frame.** A fresh popup window is created with
`HiddenFramesCannotSkipItems = 1`, submitted invisibly to measure its auto-fit size, and
only on the _next_ frame does `Begin()` place it — the gate is
`window_just_appearing_after_hidden_for_resize` (`imgui.cpp:7708`, consumed at `:7901`).
So an auto-sized popup is invisible for exactly one frame and correctly placed on the
second. `BeginComboPopup` is the one surface that pre-measures instead.

**Hit testing for the purpose of overlay blocking is not geometric.**
`IsWindowContentHoverable` (`imgui.cpp:4876`) inhibits hovering on any window whose
`RootWindow` is not within the **begin stack** of the focused popup or modal root — a
tree-membership test, not a rect test. Geometric hit testing (`FindHoveredWindowEx`) still
runs, but only to pick `g.HoveredWindow`.

**Algorithm.**

```text
per frame, per overlay:
    size = auto-fit size measured last frame (or the constrained size)
    if kind in {ChildMenu, Tooltip}:                 pos = place(...)   // every frame
    elif kind == Popup and justAppearedAfterHidden:  pos = place(...)   // once
    else:                                            pos = latched
    pos = trunc(pos)

blocking(window, flags):
    root = focusedNavWindow.rootWindow
    if root.wasActive and root != window.rootWindow:
        inhibit = root.isModal or (root.isPopup and not AllowWhenBlockedByPopup)
        if inhibit and not isWithinBeginStackOf(window.rootWindow, root): return false
    return true
```

**Where the behavior lives.** Library core: `Begin()` (`imgui.cpp:7899-7918`),
`IsWindowContentHoverable` (`:4876`), `FindHoveredWindowEx`. Backends supply only mouse
position, display size and delta time.

**Degradation.** Everything here generalises off its native substrate because there is no
substrate: no DOM, no compositor, no transforms. The one-frame measurement lag is the
part that must be designed around on a recording canvas — a golden test that paints a
single frame sees the popup **missing**, not misplaced. Either pre-measure the way
`BeginComboPopup` does, or run the recording target for two frames. The begin-stack
membership test is directly adoptable, and it appears to answer the "is this click
outside?" question more robustly than a reverse-paint-order rect test would, because it
stays correct when overlays overlap.

### 4. Arrow / caret geometry

**Not applicable — and the absence is a finding.** There is no arrow, caret, beak or tail
on any anchored overlay in this library. Grepping the popup, menu, combo and tooltip
paths for `RenderArrow` finds exactly one call, and it is the submenu affordance drawn
_inside_ the parent menu item — a `>` chevron at
`text_pos.x + offsets->OffsetMark + extra_w + g.FontSize * 0.30f`
(`imgui_widgets.cpp:9482`). That is a label decoration, not a connector. There is no
border-aware arrow, no centre offset, no corner constraint and no
[transform origin][concepts] derived from a side.

Two cheaper devices do the arrow's job of expressing relationship:

1. **A connecting edge.** The `ComboBox` policy exists solely to produce one. Its four
   candidates are the four corner alignments that keep one popup edge flush with one
   anchor edge, and it refuses to slide or clamp — it would rather fall through to the
   generic push than break the edge (`imgui.cpp:12899-12915`).
2. **Overlap.** Submenus deliberately overlap their parent by `style.ItemInnerSpacing.x`:

   > ```cpp
   > // imgui.cpp:12989
   > float horizontal_overlap = g.Style.ItemInnerSpacing.x; // We want some overlap to convey the relative depth of each menu (currently the amount of overlap is hard-coded to style.ItemSpacing.x).
   > ```

The only geometry metadata that could feed an arrow is `window->AutoPosLastDirection`
(`imgui_internal.h:2769`), an `ImGuiDir` stored per window and threaded in and out of the
placement function. It is kept purely for hysteresis. Across the popup, menu, combo and
tooltip paths read here, its only readers are placement itself
(`imgui.cpp:12995`, `:12999`, `:13028`) — this is strong but not exhaustive evidence that
nothing in rendering or styling consumes it.

**Algorithm.** None exists. The relationship cues reduce to:

```text
connecting_edge: combo popup shares the anchor's left or right x and its bottom or top y exactly
depth_overlap:   submenu x = parent.x1 - ItemInnerSpacing.x   (mirrored when opening leftwards)
```

**Where the behavior lives.** Nowhere as such. The nearest equivalents are the `ComboBox`
branch of `FindBestWindowPosForPopupEx` (`imgui.cpp:12899`) and the child-menu avoid rect
in `FindBestWindowPosForPopup` (`imgui.cpp:12989`).

**Degradation.** In a character grid an arrow is at best one cell holding a box-drawing
glyph, and it must be subtracted from the overlay's own rect because it cannot straddle a
cell boundary. ImGui's substitution — omit the arrow, use a flush shared edge plus one
unit of overlap — reads as the right shape for a cell toolkit, where a `▲`/`▼`/`◀`/`▶`
tail costs a whole row or column while an aligned edge costs nothing. The transferable
correction is to treat _(side, alignment)_ as emitted **data** so a GPU backend may draw a
triangle and a cell backend may draw nothing; ImGui computes exactly that value in
`AutoPosLastDirection` and drops it. `sparkles:ui` currently has the mirror-image problem
— it emits no resolved side at all — which is the subject of
[`./sparkles-baseline.md`][baseline].

### 5. Trigger semantics

**Context menus open on mouse RELEASE, not press.** `IsPopupOpenRequestForItem`
(`imgui.cpp:12794`) tests
`IsMouseReleased(mouse_button) && IsItemHovered(ImGuiHoveredFlags_AllowWhenBlockedByPopup)`.
The `AllowWhenBlockedByPopup` opt-out is load-bearing: it deliberately pierces the popup
hover block so you can right-click a _different_ item while a popup is already open.

The default button is the right one — `GetMouseButtonFromPopupFlags`
(`imgui.cpp:12783`) returns `ImGuiMouseButton_Right` when no button bit is set — and the
flag enum reserves bits 0 and 1 as an `InvalidMask_` to catch code written against the
older default-value convention.

Three context surfaces exist and differ only in the request predicate
(`imgui.cpp:12849` / `:12862` / `:12874`):

| Surface                   | Predicate                                                                                        |
| ------------------------- | ------------------------------------------------------------------------------------------------ |
| `BeginPopupContextItem`   | last item hovered, with `AllowWhenBlockedByPopup`                                                |
| `BeginPopupContextWindow` | window hovered, optionally requiring `!IsAnyItemHovered()` via `ImGuiPopupFlags_NoOpenOverItems` |
| `BeginPopupContextVoid`   | released, no window hovered at all, and no modal open                                            |

**Keyboard and gamepad triggering is a separate path.** `NavUpdateContextMenuRequest`
(`imgui.cpp:14538`) fires on `IsKeyReleased(ImGuiKey_Menu)`, on `Shift+F10` **pressed**, or
on a gamepad face button, then publishes two ids for the frame —
`g.NavOpenContextMenuItemId = g.NavId` and `g.NavOpenContextMenuWindowId = g.NavWindow->ID`
— which the same item and window predicates consume. If nav is sitting on a window's
close or collapse button it retargets to `window->MoveId` so the title-bar context menu
opens (`imgui.cpp:14552-14557`). Note the asymmetry: the `Menu` key uses **release**,
while `Shift+F10` and the gamepad button use **press**.

**Races between triggers are avoided structurally, not arbitrated.** Every trigger funnels
into `OpenPopupEx`, which is guardedly idempotent: if a popup with the same id is already
at this level and was opened on the _previous_ frame
(`OpenFrameCount == g.FrameCount - 1`), or `ImGuiPopupFlags_NoReopen` is set, the existing
entry is kept and only its frame counter refreshed (`imgui.cpp:12519-12528`). The comment
explains the failure this prevents: a caller who calls `OpenPopup()` unconditionally every
frame would otherwise re-latch the position and re-enter the hidden-while-measuring state
forever, so the popup would never become visible while still claiming focus.
`ImGuiPopupFlags_NoOpenOverExistingPopup` rejects the open outright if any popup is open.

Pointer _type_ is distinguished (`io.MouseSource`) but only for tooltip placement, never
for trigger selection. There is no long-press context trigger; the only long-press in the
library is the 0.60 s gamepad text-input activation. AT-triggered opening does not exist.

**Algorithm.**

```text
open_request(item):
    return (mouseReleased(button) and itemHovered(AllowWhenBlockedByPopup))
        or (navContextMenuItemId == id and (itemFocused or id == window.MoveId))

open_request(window):
    return (mouseReleased(button) and windowHovered(AllowWhenBlockedByPopup)
            and (not NoOpenOverItems or not anyItemHovered))
        or (navContextMenuWindowId != 0 and isWindowChildOf(navWindow, curWindow))

OpenPopupEx(id, flags):
    if NoOpenOverExistingPopup and anyPopupOpenAtAnyLevel: return false
    ref = { id, window: null, restoreNav: navWindow, frame: FrameCount,
            parentId: curWindow.IDStack.back(), pos: preferredRefPos(), mouse: mousePos }
    if openStack.size < beginStack.size + 1: push(ref); return true
    keep = openStack[beginStack.size].id == id
           and (openStack[beginStack.size].frame == FrameCount - 1 or NoReopen)
    if keep: openStack[beginStack.size].frame = FrameCount
    else:    closeToLevel(beginStack.size); push(ref)
    return not keep
```

**Where the behavior lives.** Library core: `IsPopupOpenRequestForItem` (`imgui.cpp:12794`),
`IsPopupOpenRequestForWindow` (`:12805`), the three `BeginPopupContext*` entry points,
`OpenPopupEx` (`:12489`) and `NavUpdateContextMenuRequest` (`:14538`). Backends supply raw
button and key state only.

**Degradation.** Release-driven _opening_ is the interesting risk. Pointer release is
available on a terminal — SGR-1006 reports button release — so the mouse path ports; what
does not port is `IsKeyReleased(ImGuiKey_Menu)`, since a terminal delivers no key release.
ImGui already ships the press-driven alternative (`Shift+F10`), which is therefore the
right terminal binding. Where there is no hover and no right button, only the programmatic
path remains from this list: the library has no long-press context trigger, so one would
have to be added. On a script-free HTML target the only realizable trigger is
`<details>`-style toggling, which erases the press/release distinction entirely. The
idempotence rule is a frame-counter comparison and behaves identically on a recording
canvas.

### 6. Timing

This is the densest part of the subject: a complete warm-up, cool-down, skip-delay and
stationary machine in five context scalars and about twenty-five lines, in a setting where
no widget can own persistent state.

**State** (`imgui_internal.h:2515-2526`): `HoverItemDelayId`,
`HoverItemDelayIdPreviousFrame`, `HoverItemDelayTimer`, `HoverItemDelayClearTimer`,
`HoverItemUnlockedStationaryId`, `HoverWindowUnlockedStationaryId`, and
`MouseStationaryTimer`.

**Stationary detection** (`imgui.cpp:10430-10431`): threshold 2.0 for mouse, 3.0 for touch
or pen; the timer accumulates while the _squared_ mouse delta is under the squared
threshold, so there is no square root.

```cpp
const float mouse_stationary_threshold = (io.MouseSource == ImGuiMouseSource_Mouse) ? 2.0f : 3.0f;
const bool mouse_stationary = (ImLengthSqr(io.MouseDelta) <= mouse_stationary_threshold * mouse_stationary_threshold);
```

**Claim phase** (inside `IsItemHovered`, `imgui.cpp:5001-5015`): the querying item writes
`g.HoverItemDelayId` with its own id — or, if it has none, with a **positional** id:

```cpp
ImGuiID hover_delay_id = (g.LastItemData.ID != 0) ? g.LastItemData.ID : window->GetIDFromPos(g.LastItemData.Rect.Min);
```

That is how a bare `Text()` or `Image()` can carry a delayed tooltip without sharing id 0
with every other anonymous item on screen. If `ImGuiHoveredFlags_NoSharedDelay` is set and
last frame's claimant differed, the timer resets. Then two gates: fail if `_Stationary` is
requested and this id is not yet unlocked; fail if the delay timer has not elapsed.

**Commit phase** (tail of `NewFrame`, `imgui.cpp:5714-5740`): if a claimant exists and the
stationary timer has passed `style.HoverStationaryDelay`, that id becomes
`HoverItemUnlockedStationaryId` — and the unlock is **sticky**, cleared only when no item
claims the slot at all (`imgui.cpp:5717-5719`), so once you have been still on an item you
may then move freely within it. The claimant is remembered as the previous frame's, the
delay timer accumulates and the clear timer resets; with no claimant the clear timer
accumulates until the `ImMax(0.25f, dt * 2.0f)` grace elapses and both timers zero.

**Defaults** (`imgui.cpp:1584-1589`): `HoverStationaryDelay` 0.15, `HoverDelayShort` 0.15,
`HoverDelayNormal` 0.40, with
`HoverFlagsForTooltipMouse = Stationary | DelayShort | AllowWhenDisabled` and
`HoverFlagsForTooltipNav = NoSharedDelay | DelayNormal | AllowWhenDisabled`. Keyboard
tooltips are therefore both slower _and_ not shared — a deliberate asymmetry.

Three behaviours fall out of the design rather than being coded as features: the delay
timer is **shared** across items by default, so traversing a toolbar shows each subsequent
tooltip immediately; the 0.25 s clear grace lets the pointer cross a gap or a separator
without losing warmth; the per-item sticky unlock means a tooltip does not vanish when the
pointer jitters. There is no maximum display duration, no re-entry rule beyond the shared
timer, and no provider or group object — the sharing _is_ the provider.

Menus have their own timing, subordinate to the aim triangle: hover-to-open is instant
when the triangle says the pointer is not travelling toward the open submenu, with a
fallback of `HoveredIdTimer >= 0.30f && MouseStationaryTimer >= 0.30f`
(`imgui_widgets.cpp:9539`) for the case where the triangle keeps saying yes.

**Algorithm.**

```text
// once per frame, in input update
stationary = dot(mouseDelta, mouseDelta) <= thr * thr    // thr = 2 (mouse) or 3 (touch/pen)
stationaryTimer = stationary ? stationaryTimer + dt : 0

// during the frame, in each IsItemHovered(delay | stationary) call
id = item.id != 0 ? item.id : hashOfPosition(item.rect.min)
if NoSharedDelay and prevFrameClaim != id: delayTimer = 0
claim = id
if Stationary and unlockedStationaryId != id: return false
if delayTimer < delay: return false
return true

// end of frame
if claim != 0 and stationaryTimer >= stationaryDelay: unlockedStationaryId = claim
elif claim == 0:                                      unlockedStationaryId = 0
prevFrameClaim = claim
if claim != 0: delayTimer += dt; clearTimer = 0; claim = 0
elif delayTimer > 0:
    clearTimer += dt
    if clearTimer >= max(0.25, dt * 2): delayTimer = clearTimer = 0
```

**Where the behavior lives.** Library core, spread across three phases of one frame:
`UpdateMouseInputs` (`imgui.cpp:10406`) for the stationary timer, `IsItemHovered`
(`:4922`) for the claim and the gates, and the tail of `NewFrame` (`:5714-5740`) for the
commit. Nothing per-widget is stored.

**Degradation.** The timers are pure `dt` accumulation, so warm-up, cool-down and shared
delay all survive losing an OS window, script and sub-cell precision, and the whole
machine is assertable on a recording canvas by feeding synthetic `dt`. The **stationary
test** is the casualty on a cell grid: motion arrives at cell granularity, so the
sub-unit threshold has no analogue below one cell; the honest port is a threshold of zero
in cells (any cell change resets) combined with a longer stationary delay. Where hover
does not exist the dimension collapses to "no tooltips" — and ImGui's own touch answer is
to reposition drag tooltips rather than to fake hover. On a script-free HTML target there
are **no timers at all**: only the instantaneous `:hover` state exists, so warm-up,
cool-down and the shared delay are unrepresentable and the honest emit is a zero-delay
CSS tooltip plus a documented behavioural difference.

### 7. Interactive hover (menu-aim / safe area)

ImGui implements the Amazon mega-dropdown heuristic explicitly, cites it in the source,
and states the motivation as avoiding timers (`imgui_widgets.cpp:9504-9505`, quoted in the
Overview). The construction is `imgui_widgets.cpp:9511-9523`:

```cpp
const float ref_unit = g.FontSize; // FIXME-DPI
const float child_dir = (window->Pos.x < child_menu_window->Pos.x) ? 1.0f : -1.0f;
const ImRect next_window_rect = child_menu_window->Rect();
ImVec2 ta = (g.IO.MousePos - g.IO.MouseDelta);
ImVec2 tb = (child_dir > 0.0f) ? next_window_rect.GetTL() : next_window_rect.GetTR();
ImVec2 tc = (child_dir > 0.0f) ? next_window_rect.GetBL() : next_window_rect.GetBR();
const float pad_farmost_h = ImClamp(ImFabs(ta.x - tb.x) * 0.30f, ref_unit * 0.5f, ref_unit * 2.5f); // Add a bit of extra slack.
ta.x += child_dir * -0.5f;
tb.x += child_dir * ref_unit;
tc.x += child_dir * ref_unit;
tb.y = ta.y + ImMax((tb.y - pad_farmost_h) - ta.y, -ref_unit * 8.0f); // Triangle has maximum height to limit the slope and the bias toward large sub-menus
tc.y = ta.y + ImMin((tc.y + pad_farmost_h) - ta.y, +ref_unit * 8.0f);
moving_toward_child_menu = ImTriangleContainsPoint(ta, tb, tc, g.IO.MousePos);
```

Four details are worth naming. The apex is **last frame's pointer position**
(`MousePos - MouseDelta`) — the trajectory is a single-frame difference with no history
buffer. The base is the child menu's near vertical edge, pushed one line-height _past_ the
menu so the cone reaches into it. The vertical slack grows with horizontal distance but is
clamped to `[0.5, 2.5]` line-heights. And the triangle's half-height relative to the apex
is capped at eight line-heights, with the source naming the failure it prevents: a very
tall submenu would otherwise produce a cone wide enough to swallow the whole parent menu,
silently disabling the heuristic. Containment is three cross-product sign tests
(`ImTriangleContainsPoint`, `imgui.cpp:2169`) against the **current** pointer position.

Use sites (`imgui_widgets.cpp:9530-9540`): `want_close` requires
`menu_is_open && !hovered && g.HoveredWindow == window && !moving_toward_child_menu && !g.NavHighlightItemUnderNav && g.ActiveId == 0`;
hover-to-open requires `!moving_toward_child_menu` so a diagonal traverse does not open the
sibling it crosses. The `g.HoveredWindow == window` guard means moving into void does not
close the menu, and the source flags this as a known inconsistency: "moving away from menu
slowly tends to hit same window, whereas moving away fast does not" (`:9527-9529`).

Travel across the trigger-to-content gap is otherwise handled by two devices rather than a
bridge. Submenus **overlap** their parent by `ItemInnerSpacing.x`, so there is no gap to
cross. Nested submenu windows additionally carry `ImGuiWindowFlags_ChildWindow`
(`imgui_widgets.cpp:9408-9410`) so hover is shared with the parent — the source's own
reason being that the top-most popup menu would otherwise steal focus and forbid hovering
the parent. The first menu in a hierarchy is not a child window, so a different mechanism
covers it: `IsRootOfOpenMenuSet` (`imgui_widgets.cpp:9372`) detects "my open child menu is
a `ChildMenu` of me and shares my nav layer" and, if so, sets
`ImGuiItemFlags_NoWindowHoverableCheck` on the item (`:9433-9435`) so the parent's items
stay hoverable while a popup holds focus. The nav-layer comparison is what stops the fix
from making every unrelated menu in the window hover-open.

**Algorithm.**

```text
movingTowardChild(parentWin, childWin, mousePos, mouseDelta, u /* = line height */):
    dir = (parentWin.x0 < childWin.x0) ? +1 : -1
    a = mousePos - mouseDelta                      // apex = previous pointer position
    b = dir > 0 ? childWin.topLeft    : childWin.topRight
    c = dir > 0 ? childWin.bottomLeft : childWin.bottomRight
    pad = clamp(abs(a.x - b.x) * 0.30, 0.5 * u, 2.5 * u)
    a.x += dir * -0.5
    b.x += dir * u ;  c.x += dir * u
    b.y = a.y + max((b.y - pad) - a.y, -8 * u)
    c.y = a.y + min((c.y + pad) - a.y, +8 * u)
    return triangleContains(a, b, c, mousePos)     // 3 cross products, sign agreement
```

**Where the behavior lives.** Library core, `BeginMenuEx` (`imgui_widgets.cpp:9396`), the
triangle block at `:9506-9524`, and `ImTriangleContainsPoint` (`imgui.cpp:2169`). No
platform involvement: it reads `g.IO.MousePos`, `g.IO.MouseDelta` and two window rects.

**Degradation.** The predicate itself is integer cross products with no timers and no
script, and in whole cells the constants translate directly — base pushed one column past
the child's near edge, `pad` clamped to a small integer number of rows, slope capped at
eight rows.

> [!WARNING]
> **The apex is the porting hazard.** `ta = MousePos - MouseDelta` assumes a per-frame
> sub-unit delta. Where pointer motion is reported only when the pointer crosses a cell,
> `MouseDelta` is `(0, 0)` on most frames; the apex then coincides with the test point and
> `ImTriangleContainsPoint(a, b, c, a)` answers a degenerate winding question rather than a
> direction question. INFERENCE — this appears to require replacing the one-frame delta
> with a short motion accumulator (the last non-zero cell delta, or the vector over the
> last few tens of milliseconds) before the heuristic means anything on a cell grid. It is
> not a claim about which _shape_ of intent test survives quantization; see
> [`./concepts.md`][concepts] on safe polygons and
> [`./features-people-forget.md`][forget].

Where there is no hover at all the dimension is void: submenus must open on tap and close
on tap-outside. Where there is no script it is likewise void, and the portable half of
ImGui's answer is the _other_ device — overlap the submenu with its parent so there is no
gap to cross, which is expressible in pure CSS.

### 8. Dismissal

Dismissal is centralised: every path ends at
`ClosePopupToLevel(remaining, restore_focus)` (`imgui.cpp:12608`), which truncates the
array and optionally restores focus.

| Trigger                           | Site                                                                                                                                                                                                                                                  |
| --------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Escape`                          | `NavUpdateCancelRequest` (`imgui.cpp:14495`), a strict ladder — clear `ActiveId` first; else leave the menu nav layer; else exit a child window; else close the topmost popup, **and only if it is not modal** (`:14517-14520`); else clear nav focus |
| Left click outside                | the click focuses the hovered window, and `FocusWindow` calls `ClosePopupsOverWindow(window, false)` (`imgui.cpp:13246`); clicking void calls `FocusWindow(NULL, UnlessBelowModal)`                                                                   |
| Right click outside               | a **separate** path that closes without changing focus (`imgui.cpp:5472-5481`)                                                                                                                                                                        |
| Activating an item inside         | `Selectable` / `MenuItem` with `ImGuiItemFlags_AutoClosePopups` (default on) call `CloseCurrentPopup` on press (`imgui_widgets.cpp:7578`)                                                                                                             |
| A child opening at the same level | `OpenPopupEx` calls `ClosePopupToLevel(current_stack_size, true)` before pushing (`imgui.cpp:12532`)                                                                                                                                                  |
| `Ctrl+Tab` / window switching     | `NavUpdateWindowingApplyFocus` calls `ClosePopupsOverWindow(apply_focus_window, false)`                                                                                                                                                               |
| Nav-left out of a submenu         | `EndMenu` closes one level (`imgui_widgets.cpp:9635-9640`)                                                                                                                                                                                            |
| A `BeginMenu` going disabled      | force-close (`imgui_widgets.cpp:9564-9567`)                                                                                                                                                                                                           |
| Parent closing                    | implicit — `ClosePopupToLevel` truncates, so all descendants die at once                                                                                                                                                                              |

The right-click path is a small behaviour that is easy to miss:

> ```cpp
> // imgui.cpp:5472
> // With right mouse button we close popups without changing focus based on where the mouse is aimed
> ```

It is gated on `g.HoveredId == 0`, computes the topmost window between the hovered window
and the topmost modal, and calls `ClosePopupsOverWindow(..., true)` so focus lands under
the bottom-most closed popup. Dismissing a context menu with another right-click therefore
does not reorder windows.

`CloseCurrentPopup` climbs the child-menu chain: while the current popup is a `ChildMenu`
and its parent popup does not own a menu bar, it closes the parent too
(`imgui.cpp:12641-12651`). Choosing an item three submenus deep dismisses the whole tree,
while a menu opened from a menu bar does not close the window owning the bar.

`ClosePopupsOverWindow`'s trim rule is itself the interesting algorithm: walking from the
bottom, keep level `k` as long as the reference window is a begin-stack descendant of
_some_ popup at level `k` or above, and truncate at the first level where it is not. The
comments enumerate the three resulting behaviours (`imgui.cpp:12564-12571`): focusing a
plain window that was opened _from_ `Popup1` does not close `Popup1`; focusing `Popup1`
closes `Popup2` and `Popup3`; comparisons use `RootWindow`, so child windows inside popups
count as inside.

**Notable absences, each deliberate or acknowledged.** Application deactivation exists in
the source **commented out** — `//if (g.IO.AppFocusLost) ClosePopupsExceptModals();`
(`imgui.cpp:5743`), labelled "currently wip/opt-in". Nothing closes or repositions a popup
on scroll. Nothing reacts to the anchor being hidden or removed. And a popup that was
opened but never `Begin()`-ed keeps `Window == NULL`, which the trim skips outright:

```cpp
// imgui.cpp:12562-12563
if (!popup.Window)
    continue;
```

so an orphaned popup is never dismissed by clicking outside — it is reachable only by
`Escape` or by a same-level reopen.

**Algorithm.**

```text
closeToLevel(remaining, restoreFocus):
    prev = stack[remaining]; stack.resize(remaining)
    if restoreFocus and prev.window:
        target = prev.window.isChildMenu ? prev.window.parent : prev.restoreNavWindow
        if target and not target.wasActive: focusTopMostUnder(prev.window)
        else: focus(target)

closePopupsOverWindow(ref, restoreFocus):
    keep = 0
    if ref:
        while keep < stack.size:
            if stack[keep].window == null: keep++; continue     // <-- orphan is sticky
            if exists n in [keep, size): isWithinBeginStackOf(ref, stack[n].window): keep++
            else: break
    if keep < stack.size: closeToLevel(keep, restoreFocus)

closeCurrentPopup():
    i = beginStack.size - 1
    if mismatch(beginStack[i].id, openStack[i].id): return
    while i > 0 and openStack[i].window.isChildMenu and not openStack[i-1].window.hasMenuBar: i--
    closeToLevel(i, true); navWindow.hideNavHighlightOneFrame = true
```

**Where the behavior lives.** Library core: `ClosePopupToLevel` (`imgui.cpp:12608`),
`ClosePopupsOverWindow` (`:12547`), `ClosePopupsExceptModals` (`:12593`),
`CloseCurrentPopup` (`:12634`), `UpdateMouseMovingWindowEndFrame` (`:5422`) for the
right-click path, `FocusWindow` (`:13211`) and `NavUpdateCancelRequest` (`:14495`). No OS
or compositor participation and — critically — **no pointer grab**: dismissal is inferred
from where the click landed inside the same surface.

**Degradation.** Because there is no grab and no OS window, "click outside" is already
computed from the last painted frame's hovered window, which is exactly the shape of a
derived reverse-paint-order hit list. Every dismissal trigger listed above is a press, a
click or a state change, so the absence of key release does not remove one of them (only
the `Menu`-key _open_ in dimension 5 depends on release). An Android-style system back key
has no ImGui equivalent and would map onto the `Escape` ladder — and the ladder's ordering
is the transferable part: clear an active edit first, leave a nav layer second, close the
overlay third. Two defects are worth explicitly not inheriting: the commented-out
deactivation path (make the choice explicit rather than accidental) and the orphaned-popup
skip. A cheap fix for the latter is to close any level whose id was not submitted for two
consecutive frames — and a retained `view()` tree makes that failure _more_ likely, not
less.

### 9. Focus

The four overlay kinds are kept distinct by flag bundles, and the distinctions are exactly
the ones the behaviour needs:

| Kind    | Flags                                                                                                                |
| ------- | -------------------------------------------------------------------------------------------------------------------- |
| Tooltip | `Tooltip \| NoInputs \| NoTitleBar \| NoMove \| NoResize \| NoSavedSettings \| AlwaysAutoResize` (`imgui.cpp:12316`) |
| Popup   | `AlwaysAutoResize \| NoTitleBar \| NoSavedSettings \| Popup` (`imgui.cpp:12715`)                                     |
| Menu    | adds `ChildMenu \| NoMove \| NoNavFocus`, plus `ChildWindow` when nested (`imgui_widgets.cpp:9408-9410`)             |
| Modal   | `Popup \| Modal \| NoCollapse`, keeps a title bar, centred on first use (`imgui.cpp:12742-12747`)                    |

`NoInputs` means a tooltip is never hovered, never focused and never hit-tested — it
cannot take focus by construction. `NoNavFocus` keeps a submenu out of the `Ctrl+Tab`
order; `ChildWindow` makes hover shared with the parent so the pointer can slide back up
the chain.

**Restoration is a stored value plus a liveness check plus a fallback.**
`popup_ref.RestoreNavWindow = g.NavWindow` is captured at open (`imgui.cpp:12502`). On
close (`imgui.cpp:12621-12628`):

```cpp
// Restore focus (unless popup window was not yet submitted, and didn't have a chance to take focus anyhow. See #7325 for an edge case)
ImGuiWindow* focus_window = (popup_window->Flags & ImGuiWindowFlags_ChildMenu) ? popup_window->ParentWindow : prev_popup.RestoreNavWindow;
if (focus_window && !focus_window->WasActive)
    FocusTopMostWindowUnderOne(popup_window, NULL, NULL, ImGuiFocusRequestFlags_RestoreFocusedChild); // Fallback
```

The `ChildMenu` branch is what returns focus to the _parent menu_ rather than to the
application window when a submenu closes. The liveness check exists because the window a
popup was opened from can stop being submitted while the popup is open.

**Containment, not trapping.** There is no tab-cycle trap anywhere. A modal contains focus
because `FindBlockingModal` (`imgui.cpp:12447`) refuses focus requests for windows outside
the modal's begin stack, and because `IsWindowContentHoverable` inhibits hover outside it.
The begin-stack rule handles nested modals correctly, with a worked example drawn in the
comments (`imgui.cpp:12432-12440`).

`EndPopup` (`imgui.cpp:12760`) imposes vertical wrapping centrally
(`NavMoveRequestTryWrapping(window, ImGuiNavMoveFlags_LoopY)` at `:12768`) so every popup,
menu, combo and context menu wraps identically; the source notes the policy is hardcoded
for now.

Pointer- and keyboard-opened menus differ concretely. `BeginMenuEx` tracks
`want_open_nav_init` separately and, when the menu was already open from a previous hover,
performs `FocusWindow` plus `NavInitWindow` (`imgui_widgets.cpp:9600-9603`) so that
arrowing into an already-hovered submenu lands the cursor on its first item. On close,
`CloseCurrentPopup` sets `NavHideHighlightOneFrame` on the returning window so the nav
highlight does not flash.

**Algorithm.**

```text
open:   popupRecord.restoreNav = currentNavWindow                  // latch
        Begin() -> if just activated and not NoFocusOnAppearing: focusWindow(popup)
close:  target = popup.isChildMenu ? popup.parentWindow : popupRecord.restoreNav
        if target and not target.wasActive: focusTopMostWindowUnder(popup)
        else focusWindow(target, navLayer == Main ? RestoreFocusedChild : None)
modal:  focusWindow(w, UnlessBelowModal) -> if findBlockingModal(w):
            bring w just below the modal, close popups over the topmost modal, refuse the change
wrap:   EndPopup -> navMoveRequestTryWrapping(LoopY)
```

**Where the behavior lives.** Library core: `OpenPopupEx` (`imgui.cpp:12502`),
`ClosePopupToLevel` (`:12622`), `FocusWindow` (`:13211`), `FindBlockingModal` (`:12447`),
`EndPopup` (`:12760`), and `BeginMenuEx`'s nav-init (`imgui_widgets.cpp:9600`). No
accessibility API and no OS focus are involved.

**Degradation.** Focus here is one window handle plus a nav item id — no DOM focus, no OS
focus, no `tabindex` — so it survives having no OS window and is fully assertable on a
recording canvas. Sub-cell precision is irrelevant. The nav paths read here are driven by
key _presses_, so the mechanism does not depend on release edges, though the `Menu`-key
context _open_ of dimension 5 does. What does not port is the assumption that focus and
hover are separate channels: with touch only, "pointer-opened" and "keyboard-opened"
collapse, and the `want_open_nav_init` distinction loses meaning — the correct default
there is the keyboard branch (focus the first item), because there is no pointer left
hovering. The latch-plus-liveness-plus-fallback triple is three fields and it addresses
the class of bug where the thing you came from disappeared while the overlay was open;
[`./comparison.md`][comparison] collects the other subjects that carry the same guard.

### 10. Layering and portals

There is no portal and no [top layer][concepts] in any meaningful sense. Ordering has
three ingredients:

1. The focus-driven display order maintained by `BringWindowToDisplayFront` / `Behind`.
2. Within a parent, `ChildWindowComparer` (`imgui.cpp:5895`), which sorts non-popups
   before popups before tooltips by comparing raw flag bits.
3. Exactly **two** output layers:

   > ```cpp
   > // imgui.cpp:5935-5938
   > static inline int GetWindowDisplayLayer(ImGuiWindow* window)
   > {
   >     return (window->Flags & ImGuiWindowFlags_Tooltip) ? 1 : 0;
   > }
   > ```

   `ImDrawDataBuilder` concatenates `Layers[0]` then `Layers[1]` into the final command
   list (`imgui.cpp:5969-5972`).

That is the complete z-model: one bit plus a sorted flat list, with later-in-list meaning
in-front.

**Overlay trees are real and expressed as two independent parent relations.** The **begin
stack** (`window->ParentWindowInBeginStack`) records where the popup was submitted from,
and is what `IsWindowWithinBeginStackOf` tests for dismissal, hover inhibition and modal
blocking. The **popup stack** records nesting depth. A nested submenu additionally carries
`ImGuiWindowFlags_ChildWindow`, so it is also in the parent's `DC.ChildWindows` and
inherits its clip and hover.

**Ownership is literal.** A popup's id is derived from the _parent window's_ ID stack
(`window->GetID(str_id)`) and `window->PopupId` is stamped in `Begin`
(`imgui.cpp:7629-7637`), so the same string in two windows yields two different popups.

**The public/internal line is drawn where a toolkit would want it.** Public
(`imgui.h:845-885`): `OpenPopup`, `BeginPopup`, `BeginPopupModal`, `BeginPopupContext*`,
`EndPopup`, `CloseCurrentPopup`, `IsPopupOpen`, `OpenPopupOnItemClick`, `ImGuiPopupFlags`,
plus the tooltip entry points. Internal (`imgui_internal.h:3509-3528`): `BeginPopupEx`,
`OpenPopupEx`, `ClosePopupToLevel`, `ClosePopupsOverWindow`, `GetTopMostPopupModal`,
`FindBestWindowPosForPopup(Ex)`, `GetPopupAllowedExtentRect`, the request predicates, and
both stacks. Placement and the stack are internal; identity and scoping are public.

**Window-name schemes encode a recycling policy** that is easy to miss and load-bearing:

```cpp
// imgui.cpp:12676
ImFormatString(name, IM_COUNTOF(name), "##Popup_%08x", id); // No recycling, so we can close/open during the same frame
// imgui.cpp:12701
ImFormatString(name, IM_COUNTOF(name), "%s###Menu_%02d", label, g.BeginMenuDepth); // Recycle windows based on depth
```

Combos recycle by `g.BeginComboDepth`, tooltips by `g.TooltipOverrideCount`
(`imgui.cpp:12313`). Recycling by depth preserves measured size and scroll across
openings; _not_ recycling lets a popup be closed and reopened within one frame.

**Algorithm.**

```text
draw order:
    sortedWindows = displayOrder(g.Windows)      // focus-driven; children sorted by
                                                 // ChildWindowComparer: normal < popup < tooltip
    for w in sortedWindows: emit(w) into Layers[w.isTooltip ? 1 : 0]
    finalDrawData = Layers[0] ++ Layers[1]

ownership:
    popupId = parentWindow.GetID(str_id)         // hashed with the parent ID stack
    window.PopupId = popupRecord.id              // stamped in Begin

trees:
    beginStackParent = the window it was submitted from   // dismissal / hover / modal tests
    popupStackParent = openStack[level - 1]               // nesting depth
```

**Where the behavior lives.** Library core: `ChildWindowComparer` (`imgui.cpp:5895`),
`GetWindowDisplayLayer` (`:5935`), `AddRootWindowToDrawData` (`:5941`), the popup-stack
push in `Begin` (`:7629-7637`). The backend receives a single `ImDrawData` and knows
nothing about popups.

**Degradation.** Nothing here needs script, hover, key release, sub-cell precision or an
OS window — there never was one. The two-layer split is the piece worth copying exactly:
it lets a tooltip escape the paint order of everything else, including a modal, without
introducing a general z space. The part that must be _materialised_ rather than derived is
the begin-stack relation: where the hit list is flat and computed from the frame's paint
order, "is this click inside my subtree?" cannot be recovered from geometry, so an
explicit parent id belongs on every overlay record.

### 11. Modality

Two levels, cleanly separated.

A **non-modal popup** is light dismiss: it blocks _hover_ on other windows and nothing
else. The blocking is `IsWindowContentHoverable` (`imgui.cpp:4876`) — if the focused root
window is a popup and the queried window is not within its begin stack, hovering returns
false, unless the caller passes `ImGuiHoveredFlags_AllowWhenBlockedByPopup`, which is
precisely what the context-menu predicates do.

A **modal** adds six things: hover inhibition with no opt-out (the modal branch sets
`want_inhibit` unconditionally, `imgui.cpp:4887-4888`); `g.HoveredWindow` cleared outright
for windows outside its begin stack (`:5509-5512`); focus requests below it refused via
`FindBlockingModal` + `ImGuiFocusRequestFlags_UnlessBelowModal` (`:13216-13227`); `Escape`
excluded (`:14517`); outside clicks excluded — `ClosePopupsExceptModals` exists
specifically to stop at the topmost modal (`:12593-12606`); and a scrim.

The scrim is the only animated thing in the entire subject. `RenderDimmedBackgrounds`
(`imgui.cpp:6053`) draws `window->DC.ModalDimBgColor` at `g.DimBgRatio` behind
`FindBottomMostVisibleWindowWithinBeginStack(modal)` — behind the bottom-most window of
the modal's _own begin stack_, not simply behind the modal — and the ratio ramps
asymmetrically (`imgui.cpp:5811` and `:5813`):

```cpp
g.DimBgRatio = ImMin(g.DimBgRatio + g.IO.DeltaTime * 6.0f, 1.0f);
// ...
g.DimBgRatio = ImMax(g.DimBgRatio - g.IO.DeltaTime * 10.0f, 0.0f);
```

Nested modals are handled by begin-stack ancestry: `FindBlockingModal` walks the open
popup stack and returns the first modal the window is not within, with a worked example in
the comments (`imgui.cpp:12432-12440`).

**Pointer capture is exposed as two booleans, not one.** `io.WantCaptureMouse` and
`io.WantCaptureMouseUnlessPopupClose`, derived from `io.MouseDownOwned` and
`io.MouseDownOwnedUnlessPopupClose` computed at click time (`imgui.cpp:5519-5528`,
`:5548-5556`):

```cpp
io.MouseDownOwnedUnlessPopupClose[i] = (g.HoveredWindow != NULL) || has_open_modal;
```

That distinction lets a host application learn that a click was captured _only_ because a
popup was open — i.e. that the click which merely dismissed the overlay can be forwarded
to the application beneath.

There is no accessibility modal bit, because there is no accessibility layer, and no
click-through or passthrough mode.

**Algorithm.**

```text
hoverBlocked(w, flags):
    root = navWindow.rootWindow
    if root.wasActive and root != w.rootWindow:
        inhibit = root.isModal or (root.isPopup and not (flags & AllowWhenBlockedByPopup))
        if inhibit and not withinBeginStackOf(w.rootWindow, root): return true
    return false

modalHoverClear:
    if topMostModal and hoveredWindow and not withinBeginStackOf(hoveredWindow.root, modal):
        hoveredWindow = null

focusGuard(w):
    if UnlessBelowModal and findBlockingModal(w):
        place w just below the modal; closePopupsOver(topMostModal); refuse

captureFlags:
    mouseDownOwned[i]                 = hoveredWindow != null or anyPopupOpen
    mouseDownOwnedUnlessPopupClose[i] = hoveredWindow != null or anyModalOpen

scrim: dimRatio += dt*6 (up) / -= dt*10 (down), clamped [0,1];
       drawn behind bottomMostVisible(modal.beginStack)
```

**Where the behavior lives.** Library core: `IsWindowContentHoverable` (`imgui.cpp:4876`),
`UpdateHoveredWindowAndCaptureFlags` (`:5491`), `FindBlockingModal` (`:12447`),
`GetTopMostPopupModal` (`:12412`), `RenderDimmedBackgrounds` (`:6053`),
`ClosePopupsExceptModals` (`:12593`). The scrim goes into the ordinary draw list; no
compositor is involved.

**Degradation.** Modality here is a predicate over a tree, evaluated during hit testing,
plus a rectangle fill — no OS modal, no grab. On a cell target the scrim degrades to a dim
cell attribute rather than an alpha blend, and the 6-per-second / 10-per-second ramp is
worth dropping or quantising, since a terminal repaint budget makes a sub-second alpha fade
pointless. The `UnlessPopupClose` pair is the transferable idea: with no pointer grab, "was
this click captured only because an overlay was open?" is the exact question a host needs
answered before forwarding an event, and ImGui shows it costs one extra boolean per button
computed at click time. Note that on ImGui's side it is easy for a host to ignore — most
backends read only `WantCaptureMouse`.

### 12. Adaptive presentation

One real adaptation exists, and it is owned by the toolkit core and driven by a per-event
field the backend fills: `io.MouseSource` (`ImGuiMouseSource_Mouse` / `_TouchScreen` /
`_Pen`).

**Touch tooltips are placed above the finger.** Constants at `imgui.cpp:1367-1369`:

```cpp
static const ImVec2 TOOLTIP_DEFAULT_OFFSET_MOUSE = ImVec2(16, 10);      // Multiplied by g.Style.MouseCursorScale
static const ImVec2 TOOLTIP_DEFAULT_OFFSET_TOUCH = ImVec2(0, -20);      // Multiplied by g.Style.MouseCursorScale
static const ImVec2 TOOLTIP_DEFAULT_PIVOT_TOUCH = ImVec2(0.5f, 1.0f);   // Multiplied by g.Style.MouseCursorScale
```

The touch branch computes `ref + offsetTouch * scale - pivotTouch * size` — bottom-centre
anchored above the touch point — and uses it **only if it fits entirely**
(`r_outer.Contains(...)`, `imgui.cpp:13013-13018`), otherwise silently falling through to
the ordinary mouse path. That guard is what stops the rule from pushing tooltips off the
top edge for items near the top of the screen; clamping instead would put the tooltip back
under the finger, which is the exact failure the offset exists to avoid.

Drag-and-drop tooltips do the same adaptation a second time, via `SetNextWindowPos` with a
pivot, bypassing the placement function entirely (`imgui.cpp:12291-12299`). The stationary
threshold also adapts, 2.0 for mouse against 3.0 for touch or pen (`imgui.cpp:10430`) — a
finger or stylus never holds perfectly still.

Nothing else adapts. There is no popover-to-sheet transformation, no
hover-tooltip-to-long-press substitution (a touch device simply gets no hover and therefore
no tooltip), no teaching-tip concept and no size classes. Keyboard-driven relocation exists
only as the mouse-versus-nav fork inside `NavCalcPreferredRefPos` plus the smaller nav
avoid rect (`±16, ±8` instead of the asymmetric cursor box, `imgui.cpp:13022-13025`) — the
tooltip moves to the focused item when nav is driving, implemented as one branch.

**Which layer owns it:** the toolkit, reading a backend-supplied enum. The backend does not
choose a presentation; it reports an input source.

**Algorithm.**

```text
placeTooltip(refPos, size, scale, source, rOuter):
    if source == TouchScreen and refPosSource == Mouse:
        p = refPos + (0, -20) * scale - (0.5, 1.0) * size    // bottom-centred above the finger
        if rOuter.contains(p, p + size): return p            // otherwise fall through
    p = refPos + (16, 10) * scale
    avoid = navDriven ? Rect(ref - (16, 8), ref + (16, 8))
                      : Rect(ref - (16, 8), ref + (24, 24) * scale)
    return findBestPos(p, size, lastDir, rOuter, avoid, Tooltip)
```

**Where the behavior lives.** Library core, reading `ImGuiIO::MouseSource`, which backends
set per input event: `imgui.cpp:1367-1369` (constants), `:13010-13027` (tooltip
adaptation), `:12291-12299` (drag tooltip), `:10430` (stationary threshold).

> [!NOTE]
> How individual backends (`imgui_impl_*`) populate `io.MouseSource` was not read, so the
> claim that this adaptation is driven by real touch events depends on backend behaviour
> outside the scope of this reading.

**Degradation.** The _mechanism_ ports cleanly — one enum in, a branch in placement out, no
OS involvement, fully assertable on a recording canvas by injecting a source value. What
does not port is the assumption that touch still produces a tooltip: where hover is absent,
ImGui's touch tooltip appears only for drag-and-drop, which is the honest answer and
arguably better than inventing a long-press tooltip. The genuinely missing input is the
soft-keyboard inset. ImGui models safe-area insets — `WorkInsetMin` / `WorkInsetMax`,
documented as iOS `safeAreaInsets` and Android `DisplayCutout` (`imgui_internal.h:2006-2012`)
— but popup placement uses `GetMainRect` and ignores them, so this subject offers no
precedent for keyboard avoidance: the inset has to be folded into the boundary rect
supplied to placement, as an explicit input.

### 13. Accessibility

**Not applicable.** Dear ImGui has no accessibility layer. Grepping `imgui.cpp`,
`imgui.h`, `imgui_internal.h` and `docs/FAQ.md` for accessibility, screen reader, UI
Automation, AT-SPI, VoiceOver and TalkBack returns no substantive hits. There is no role
vocabulary, no description-versus-label distinction, no ARIA equivalent, no modal bit
exposed to any platform tree, no live region and no announcement channel. A tooltip is
pixels; assistive technology sees nothing. This is a coherent consequence of drawing
everything into one vertex buffer.

The closest thing to a semantic export is the **test-engine hook**, and it is instructive
as a minimum viable one. `IMGUI_TEST_ENGINE_ITEM_INFO(id, label, statusFlags)` is called
per item; `BeginMenuEx` passes `ImGuiItemStatusFlags_Openable` and, conditionally,
`_Opened` (`imgui_widgets.cpp:9567`), and `MenuItemEx` passes `_Checkable` and
conditionally `_Checked` (`imgui_widgets.cpp:9727`). The library therefore already
computes, per item, an `(id, label, role-ish flags, expanded, checked)` tuple — and hands
it to an external observer rather than to an assistive technology.

**On WCAG 1.4.13** (Content on Hover or Focus — dismissible, hoverable, persistent):
ImGui satisfies _dismissible_ incidentally, since tooltips vanish when the pointer leaves,
and satisfies _persistent_ because there is no maximum display duration and no auto-hide.
It fails _hoverable_ structurally: tooltip windows carry `ImGuiWindowFlags_NoInputs`
(`imgui.cpp:12316`), so the pointer can never enter a tooltip and its content can never be
interactive or selectable. That is a hard answer to "may tooltip content ever be
interactive?" — in this design, never. The [APG deep-dive][apg] records the same
separation from the specification side: a hover surface containing focusable elements is a
different widget, not a tooltip configuration.

**Algorithm.** None. The observable semantic export is:

```text
per item, per frame: (id, label, statusFlags)
    statusFlags may include Openable | Opened | Checkable | Checked | HoveredWindow | Visible
    emitted only to an optional external test-engine hook
```

**Where the behavior lives.** Nowhere in the library. The nearest surface is the
`IMGUI_TEST_ENGINE_ITEM_INFO` macro, whose consumer is a separate repository not present
in this clone.

**Degradation.** A terminal cell grid can honestly expose very little of this, and
pretending otherwise is the failure mode: a screen reader attached to a terminal reads
cells, so a tooltip painted over content is read _as_ content, which is a hazard rather
than a feature. What ImGui's test-engine tuple suggests is a cheap and useful shape — have
the overlay primitive emit `(overlayId, kind, triggerId, label, opened)` into a
recording/observer sink. INFERENCE: one sink would then serve three consumers at once —
recording-canvas assertions, a future accessibility bridge on a GPU backend, and an HTML
emit where `role="tooltip"`, `aria-describedby` and `aria-expanded` are representable
without script. The argument for carrying the tuple even on targets that discard it is
that the targets which _can_ use it cannot reconstruct it.

### 14. Animation

**Not applicable.** Popups, tooltips, menus and combos have no enter animation, no exit
animation, no fade, no scale, no transform origin and no reduced-motion switch. A popup is
absent on frame N and fully drawn on frame N+1 (or N+2, given the measurement frame). This
follows from immediate mode: there is no retained node to animate and no place to store
per-overlay animation state without inventing one.

The two exceptions are both scrims, not overlays: `g.DimBgRatio` (dimension 11) and
`g.NavWindowingHighlightAlpha` for the `Ctrl+Tab` overlay. Drag-and-drop tooltips get a
static alpha multiplier (`PopupBg` alpha `* 0.60f`, `imgui.cpp:12300`) but no transition.

On whether geometry metadata is emitted to enable animation: **no, but the metadata
exists**. `window->AutoPosLastDirection` holds the chosen `ImGuiDir` and is threaded in and
out of the placement function as an in/out parameter (`imgui_internal.h:3521`). It is
computed for hysteresis, and across the overlay paths read here nothing in rendering or
styling consumes it — yet it is precisely the datum a placement-aware transform origin
needs.

There is also no reposition-during-animation problem, because there is no animation and
because position is either recomputed every frame (menus, tooltips) or frozen (popups),
with no interpolation in either case.

**Algorithm.** None for overlays. The only interpolator is the scrim; the placement
metadata an animator would want is:

```text
window.AutoPosLastDirection in {None, Left, Right, Up, Down}    // set by findBestPos
```

**Where the behavior lives.** `imgui.cpp:5810-5813` (the `DimBgRatio` ramp, inside
`NewFrame`) and `imgui.cpp:6053` (`RenderDimmedBackgrounds`). The direction datum lives on
`ImGuiWindow` and is written only by `FindBestWindowPosForPopupEx`.

**Degradation.** There is nothing to degrade, which is itself the finding: a toolkit whose
cell target repaints a grid and whose HTML target has no script cannot afford enter/exit
transitions as a primitive-level feature, and this subject demonstrates a complete
menu/popup system that does not need them. What is worth taking is the part ImGui leaves
unused: emit the resolved _(side, alignment, offset along the edge)_ as data on the display
list item. That costs one small value, is free on a cell backend, lets a GPU backend
animate a scale-from-origin if it ever wants one, and lets a static HTML emit set
`transform-origin` without script. Compute-and-discard is the mistake to avoid.

### 15. State architecture

Two `ImVector<ImGuiPopupData>` and nothing else. No reducer, no FSM object, no controller,
no callbacks, no subscriptions.

`g.OpenPopupStack` persists across frames and represents _what is open_.
`g.BeginPopupStack` is cleared every frame (`imgui.cpp:5846`) and represents _how deep the
current submission is_. The whole query surface is derived by comparing their sizes
(`imgui.cpp:12371-12400`).

`ImGuiPopupData` (`imgui_internal.h:1508-1521`) is plain data — two `ImGuiID`, two
`ImGuiWindow*`, two `int`, two `ImVec2` — with a `memset`-based constructor. Records are
pushed and popped **by value**: `Begin()` copies the resolved record into
`BeginPopupStack` (`imgui.cpp:7635`) so the frame-local stack holds a snapshot, not a
reference; mutation of the persistent record goes through the array.

Controlled versus uncontrolled: exclusively uncontrolled, argued in the demo (quoted in the
Overview). The escape hatches are the `bool` return of `OpenPopupEx`
(`imgui.cpp:12484-12485`) and `IsWindowAppearing()` inside the popup scope.

Temporal state beyond the stacks is a handful of context scalars: `OpenFrameCount` (for the
every-frame-`OpenPopup` guard), the five hover-timer scalars, `g.MenusIdSubmittedThisFrame`
(an `ImVector<ImGuiID>` supporting `BeginMenu` append semantics with an explicitly
justified O(N) scan, `imgui_widgets.cpp:9412-9426`), `g.BeginMenuDepth` and
`g.BeginComboDepth` (window recycling keys), `g.TooltipOverrideCount` and
`g.TooltipPreviousWindow`.

**Algorithm.**

```text
state:
    openStack  : Vector!PopupData     // persists across frames
    beginStack : Vector!PopupData     // cleared each frame

PopupData = { id, windowHandle, restoreNavHandle, parentNavLayer,
              openFrame, openParentId, openPos, openMousePos }

queries (all O(1) except by-id-anywhere):
    openAtThisLevel(id) = openStack.length > beginStack.length
                          && openStack[beginStack.length].id == id
    anyOpenAtThisLevel  = openStack.length > beginStack.length
    anyOpenAnywhere     = openStack.length > 0
    openAnywhere(id)    = openStack.canFind!(p => p.id == id)

transitions:
    open(id)   : see the OpenPopupEx pseudocode in dimension 5
    begin(id)  : if !openAtThisLevel(id) return false
                 resolve window; openStack[beginStack.length].window = w
                 beginStack ~= openStack[beginStack.length]
    end()      : beginStack.popBack()
    closeTo(n) : openStack.length = n   (+ focus restore)

frame boundary: beginStack.length = 0
```

**Where the behavior lives.** Library core: `imgui_internal.h:2376-2377` declares both
stacks and `:1508` the record; `IsPopupOpen` (`imgui.cpp:12371`), `OpenPopupEx` (`:12489`),
the `Begin` push (`:7629-7637`), the `End` pop and the `NewFrame` clear (`:5846`).

**Degradation.** Two integer lengths and a flat POD array need no OS window, no hover, no
timers, no script and no sub-cell precision, and the whole thing is byte-comparable, which
makes it trivially assertable on a recording canvas: dump the open stack and diff. Replacing
`ImVector` with a small-buffer array and `ImGuiWindow*` with an integer handle leaves the
design intact — no allocation in steady state, no indirection, trivially copyable and
comparable — and the pointers are the only non-value dependency, present only because
ImGui resolves identity to pointers. The frame-scoped stack maps onto a `view()`/`layout()`
pass directly. The caveat is that ImGui assumes overlays are _submitted_ each frame by the
same code that owns the trigger; a retained view tree has to decide whether an overlay that
stops being emitted counts as closed, and ImGui's answer — no — is the orphaned-popup gap
of dimension 8 and is the wrong default to inherit.

### 16. Shared infrastructure

The factoring is clean and the boundary is instructive because of _where_ it is drawn.

**Truly shared, one implementation and five consumers:**

1. **The popup stack and its id protocol.** `BeginPopup`, `BeginPopupModal`,
   `BeginPopupContext{Item,Window,Void}`, `BeginMenu` and `BeginCombo` all route through
   `OpenPopupEx` / `IsPopupOpen` / `ClosePopupToLevel` and all nest in the same array.
2. **`FindBestWindowPosForPopupEx`.** Every anchored surface positions through it, differing
   only in `r_avoid` and a three-value policy enum.
3. **The dismissal cascade.** One `ClosePopupToLevel` serves click-outside, `Escape`, item
   activation, reopen and focus change.
4. **The window-flag composition idiom**, where each kind is a named bundle of
   `ImGuiWindowFlags`.

**Deliberately not shared — and this is the key finding: tooltips are not popups.** A
tooltip has no entry in either stack, no id, no dismissal logic, no focus interaction
(`NoInputs`), a different lifetime (it exists for exactly the frames the caller submits
it), a different identity scheme (a counter, bumped when a second tooltip overrides the
first because a window's contents cannot be cleared mid-frame), a different draw layer, and
its own timing machinery living in the hover system rather than the popup system. The only
thing it shares with a popup is the placement function. A toolkit that models Tooltip as
"a Popover with hover triggers" pays for it in exactly the three systems ImGui kept it out
of: dismissal, focus and stack nesting.

Also not shared: the drag-and-drop tooltip, which bypasses placement entirely
(`imgui.cpp:12291-12299`); and the combo, which must pre-measure and position itself before
`Begin` because it needs the anchor width as a size constraint
(`imgui_widgets.cpp:2029-2067`). Combo is the one surface whose _size_ depends on its
anchor — minimum width equals anchor width, maximum height a whole number of items via
`CalcMaxPopupHeightFromItemCount` — and that dependency is why it cannot ride the generic
path.

**Menu-specific additions on top of the shared stack:** `ImGuiWindowFlags_ChildMenu`, the
`ChildWindow`-when-nested trick, `IsRootOfOpenMenuSet` +
`ImGuiItemFlags_NoWindowHoverableCheck`, the aim triangle, `MenusIdSubmittedThisFrame` for
append semantics, `BeginMenuDepth`-keyed window recycling, and the `CloseCurrentPopup`
chain climb. That is a substantial amount of menu-only machinery, and none of it leaked
into `BeginPopup`.

There is no Toast, no TeachingTip, no HoverCard and no DatePicker in the library.
`ColorPicker` is an ordinary widget placed inside a normal popup — which demonstrates that
"a popup containing a complex widget" needs nothing from the overlay primitive beyond the
stack.

**Algorithm.**

```text
shared core (what one anchored-overlay primitive owns):
    1. identity:   id = parentIdStack.hash(name), plus a stack of open records
    2. placement:  place(refPoint, size, inout lastDir, outerRect, avoidRect, policy)
    3. dismissal:  closeToLevel(n) + the begin-stack descendant trim
    4. blocking:   withinBeginStackOf(candidate, activeOverlayRoot)

per-kind, kept apart:
    Tooltip : no stack entry, no id, NoInputs, second draw layer, counter-named, hover-timed
    Combo   : size constrained by the anchor; positions itself before submission
    Menu    : ChildMenu flags, aim triangle, menu-set hover exemption, append-by-id, depth recycling
    Modal   : dismissal opt-outs + scrim + focus refusal
```

**Where the behavior lives.** Shared parts in the POPUPS section of `imgui.cpp`
(`:12365-13030`) and `imgui_internal.h:3506-3528`; menu-specific parts in
`imgui_widgets.cpp:9144-9740`; combo-specific in `imgui_widgets.cpp:1925-2085`;
tooltip-specific in the TOOLTIPS section (`imgui.cpp:12264-12365`) plus the hover timers in
`NewFrame` and `IsItemHovered`.

**Degradation.** The shared core is four things that need no OS window, hover, script,
sub-cell precision or key release: an id, a placement function over integers, a dismissal
cascade over a stack, and a subtree-membership predicate. The per-kind machinery is where
targets diverge and should therefore stay per-kind — the aim triangle needs hover and a
motion signal, the tooltip timing needs a clock, the modal scrim needs a cell-attribute
fallback, and the combo's anchor-width constraint is the one piece that is uniformly
implementable on every target.

---

## Strengths

- `FindBestWindowPosForPopupEx` is about seventy lines with no measurement API, no
  clipping-ancestor discovery and no observers; every operation is add, subtract, `min`,
  `max` or compare, so it transcribes into integer-cell code essentially line for line.
- Last-direction hysteresis — retry the previously chosen side first, then skip it in the
  ordered list — is three lines and removes the flip-flop oscillation that a naive flip
  implementation shows when a surface near a boundary changes size frame to frame.
- Encoding the anchor's side as an **avoid rectangle**, including infinite bands, collapses
  side selection, gap, overlap and cursor avoidance into one parameter and makes impossible
  directions arithmetically impossible rather than special-cased.
- The whole overlay state is two flat arrays of `memset`-constructible POD, with openness
  expressed as a comparison of two array lengths — byte-comparable, and therefore
  dumpable and diffable for recording-canvas assertions.
- A complete tooltip timing machine — warm-up, cool-down, skip-delay across neighbours,
  gap tolerance and a stationary requirement — in five context scalars and about
  twenty-five lines, with no per-widget storage.
- The stationary requirement itself: require the pointer to have been still on this item
  _once_, then let it move freely within the item. It removes most of the need for a long
  delay.
- Timer-free submenu intent via a trajectory triangle, with an explicit slope cap so a tall
  submenu cannot create a corridor that swallows the parent, plus a stationary-timer
  fallback so the heuristic cannot deadlock.
- Light dismiss and modal blocking are decided by begin-stack tree membership rather than
  by geometry or an OS pointer grab — which stays correct when overlays overlap, when the
  pointer is between two overlays, and when it leaves the surface.
- Dismissal is enumerated and centralised: every path funnels into one truncate-and-restore
  function, so there is exactly one place to reason about ordering.
- Focus restoration stores the return target at open **and** checks its liveness at close,
  with a documented fallback for the case where it died in the meantime.
- Right-click-outside closes popups _without_ changing focus, restoring focus under the
  bottom-most closed popup — a small behaviour that is very visible when missing.
- Two draw layers plus a sorted flat list is the entire z-model, which is a working
  demonstration that painting overlays into one surface needs a layer _enum_, not a z-index
  space.
- Per-input-source adaptation (touch tooltips above the finger, with a fit guard) is owned
  by the toolkit and driven by a backend-supplied enum — the backend reports an input
  source, it does not choose a presentation.

## Weaknesses

- A popup that is opened but never submitted keeps a null window pointer, and
  `ClosePopupsOverWindow` skips such entries with a bare `continue` — so an orphaned popup
  is never dismissed by clicking outside. Nothing validates that open levels are still
  being submitted.
- Popup position is latched at open and never re-derived: the surface does not follow a
  moving anchor, does not reposition on scroll, and does not close when its anchor scrolls
  away or is removed.
- Auto-sized popups are invisible for one frame while being measured, so a single-frame
  render sees nothing at all.
- No accessibility layer of any kind. The library already computes an
  `(id, label, Openable/Opened)` tuple per item but sends it only to an optional
  test-engine hook.
- No animation and no exported placement metadata: `AutoPosLastDirection` holds exactly
  the side a styling or animating layer would need, and it is computed and then dropped.
- No arrow, caret or beak, and no vocabulary for one; relationship is conveyed only by a
  flush shared edge (combo) or a one-spacing overlap (submenu).
- Tooltip windows carry `NoInputs`, so tooltip content can never be interactive, hoverable
  or selectable, and WCAG 1.4.13's hoverable clause is structurally unsatisfiable.
- No RTL, no writing modes and no logical side vocabulary anywhere in the placement code.
- The `ComboBox` policy's direction names are actively misleading: `ImGuiDir_Right` means
  "above, toward right" and `ImGuiDir_Left` means "below, toward left".
- Only one hover delay timer exists globally, so two items requesting different delays
  interfere; the source acknowledges the equivalent limitation for windows and notes that a
  hash-to-timer cache would be needed to fix it.
- The menu-aim triangle's apex is derived from a single-frame pointer delta, and
  `want_close` additionally requires the pointer to still be over the parent window — an
  inconsistency the source itself documents.
- Nothing closes popups when the application loses focus: the code exists and is commented
  out as "currently wip/opt-in".
- Popup placement deliberately ignores the viewport work area and safe-area insets
  (`GetPopupAllowedExtentRect` uses `GetMainRect`, not `GetWorkRect`), so this subject
  offers no precedent for soft-keyboard or display-cutout avoidance despite modelling those
  insets elsewhere.
- Popup identity is a hash of a caller-supplied string against the parent's ID stack, so a
  collision silently shares state between two unrelated popups, and passing `NULL` to
  `BeginPopupContextItem` after a widget with no id asserts at runtime rather than failing
  at compile time.

---

## Key design decisions and trade-offs

| Decision                                                                                                                                                     | Rationale                                                                                                                                                                                                                                                                                                                        | Trade-off                                                                                                                                                                                                                                                                                                                                                                   |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Latch the anchor to a POINT at open time and never re-derive it (`OpenPopupPos` / `OpenMousePos`, set once in `OpenPopupEx`).                                | An immediate-mode library cannot hold a reference to the anchoring item — the item does not exist between frames. Reducing the anchor to two points makes the open record plain data, makes reopening cheap, and makes the popup's position independent of whether the trigger is submitted at all this frame.                   | A popup cannot follow a moving or scrolling anchor and cannot know its anchor was scrolled out of view or destroyed. Combined with nothing closing an orphaned popup, this yields surfaces floating over content they are no longer related to. Child menus and tooltips opt out by recomputing every frame — an admission that the latch is a compromise, not a principle. |
| Express the anchor's "side" as an AVOID RECTANGLE rather than a side parameter, and let infinite bands prune the candidate directions.                       | One rect subsumes side selection, gap, overlap and cursor avoidance. A vertical infinite band makes vertical placement arithmetically impossible, so a submenu goes sideways without any code saying so; a horizontal band forces a menu-bar menu downwards the same way. Placement then needs no knowledge of what it places.   | The direction enum becomes a lie in the `ComboBox` branch, the intent is invisible at the call site, and callers must reason about `FLT_MAX` arithmetic to predict which directions survive. There is also no vocabulary for "prefer bottom-start, then bottom-end" — only what the rect geometry implies.                                                                  |
| Tooltips are NOT popups: no stack entry, no id, no dismissal logic, `NoInputs`, their own draw layer, their own timing, sharing only the placement function. | The four hard behaviours of a popup — identity, nesting, dismissal, focus — are all things a tooltip must not have. Modelling a tooltip as a popup variant would force every one of those systems to grow a "but not for tooltips" branch.                                                                                       | Tooltip content can never be interactive or even selectable, so WCAG 1.4.13's hoverable requirement is structurally unsatisfiable, and a rich hover card — which wants tooltip timing _and_ popup dismissal — has no home in the library at all.                                                                                                                            |
| Share the hover delay timer across items by default, with a 0.25 s clear grace, and make the stationary unlock per-item and one-shot.                        | Three desirable behaviours fall out of one shared scalar plus one sticky id: instant tooltips when traversing a toolbar, tolerance for crossing gaps and separators, and no flicker when the pointer jitters on an item that has already earned its tooltip. Nothing per-widget is stored, which is mandatory in immediate mode. | Only one delay can be in flight at a time, so two items requesting different delays interfere; the source acknowledges the equivalent limitation and says a hash-to-timer cache would be needed. Callers who want isolation must opt into `NoSharedDelay` and give up the traversal behaviour.                                                                              |
| Popups are uncontrolled: the library owns visibility, and the caller may only request an open and query the state.                                           | Stated in the demo: the library must be able to close popups at any time (outside click, `Escape`, focus change, item activation), so a caller-owned bool would be perpetually stale. Library-owned state is also what makes the whole system expressible as two arrays.                                                         | Callers cannot drive a popup from external state (a URL, a saved session, an undo stack) without replaying `OpenPopup`, cannot animate a close, and must hang side effects off the new bool return or `IsWindowAppearing`. An id collision silently reuses another popup's slot.                                                                                            |
| Implement submenu intent as a geometric triangle over the pointer's trajectory rather than an open/close timer.                                              | Stated in the source: to avoid timers, so menus feel more reactive. A predicate answers instantly in both directions, needs no state, and is exact.                                                                                                                                                                              | It depends on a per-frame pointer delta, so it degenerates when motion is coarse or the frame rate is low. The library hedges with a 0.30 s hovered + 0.30 s stationary fallback for opening, and `want_close` additionally requires the pointer to still be over the parent window, which the source flags as an inconsistency.                                            |
| Two draw layers, total: tooltips on layer 1, everything else on layer 0, ordering otherwise by a sorted flat window list.                                    | A single bit resolves the only ordering question geometry and focus cannot: a tooltip must be above the overlay that spawned it, including above a modal. Everything else is already ordered by focus and submission.                                                                                                            | There is no room for a third class (a toast, a drag ghost, a debug overlay) without sharing a layer or widening the model; ImGui works around this with foreground/background draw lists appended outside the window system entirely.                                                                                                                                       |
| Place a popup only on the frame after it was measured, leaving it invisible for one frame.                                                                   | Auto-sized surfaces cannot be positioned before their size is known, and immediate mode measures by submitting. Hiding the first frame is honest and avoids a visible jump.                                                                                                                                                      | A single-frame renderer sees no popup at all — directly relevant to headless/recording targets, where a one-frame paint would assert emptiness. `BeginComboPopup` shows the escape hatch (peek the previous frame's auto-fit size and place before submitting), but it is applied to exactly one surface out of five.                                                       |
| Report pointer capture as two booleans — `WantCaptureMouse` and `WantCaptureMouseUnlessPopupClose`.                                                          | Without a pointer grab, a click outside an overlay is ambiguous: it both dismisses the overlay and might be meant for the application beneath. Exposing both interpretations lets the host decide instead of guessing.                                                                                                           | It pushes a subtle policy decision onto every host integration, and the flag is easy to ignore — most backends read only `WantCaptureMouse` — so the nuance is usually lost in practice.                                                                                                                                                                                    |

---

## Sources

All line references are to the pinned revision
`46d39d56febc2a00bdd2270dc88c8a13f2a0441a` (`IMGUI_VERSION` `"1.93.0 WIP"`). Nothing was
built or executed, and there are no tests in this tree at this revision.

- [`imgui.cpp`][src-findbestpos] — the POPUPS section (`:12365-13030`):
  `IsPopupOpen` (`:12371`), `FindBlockingModal` (`:12447`), `OpenPopupEx` (`:12489`) with
  the anchor latch (`:12502-12506`) and the reopen guard (`:12519-12528`),
  `ClosePopupsOverWindow` (`:12547`) with the null-window skip (`:12562`),
  `ClosePopupsExceptModals` (`:12593`), `ClosePopupToLevel` (`:12608`) with focus
  restoration (`:12621-12628`), `CloseCurrentPopup` (`:12634`) and its chain climb
  (`:12641-12651`), the request predicates (`:12783`, `:12794`, `:12805`), the three
  `BeginPopupContext*` entry points (`:12849`, `:12862`, `:12874`),
  `FindBestWindowPosForPopupEx` (`:12893`) with the pre-clamp (`:12895`), the two candidate
  loops (`:12899-12952`), the overflow test (`:12931-12932`) and the policy-split fallback
  (`:12954-12964`), `GetPopupAllowedExtentRect` (`:12968`) and
  `FindBestWindowPosForPopup` (`:12978`) with the per-kind avoid rects (`:12989-13029`).
- [`imgui.cpp` — TOOLTIPS section][src-tooltipflags] (`:12264-12365`) — the drag-tooltip
  pivot bypass (`:12291-12299`), the override-counter naming (`:12303-12315`) and the
  tooltip window flags including `NoInputs` (`:12316`).
- [`imgui.cpp` — hover timing][src-hovercommit] — the `NewFrame` commit block
  (`:5714-5740`), `IsItemHovered`'s claim and gates (`:4997-5015`) including the positional
  id (`:5001`), `UpdateMouseInputs`' stationary detection (`:10430-10431`), the mouse floor
  (`:10420`) and the style defaults (`:1584-1589`).
- [`imgui.cpp` — layering and hit testing][src-displaylayer] — `IsWindowContentHoverable`
  (`:4876`), `ChildWindowComparer` (`:5895`), `GetWindowDisplayLayer` (`:5935`), the
  two-layer concatenation (`:5969-5972`), the capture-flag pair (`:5519-5556`), the
  right-click dismissal path (`:5472-5481`), the commented-out `AppFocusLost` close
  (`:5743`), the `DimBgRatio` ramp (`:5810-5813`) and `RenderDimmedBackgrounds` (`:6053`).
- [`imgui.cpp` — `Begin()`][src-beginplacement] — the placement dispatch (`:7899-7904`),
  the measurement gate (`:7708`), the popup-stack push (`:7629-7637`) and the position
  truncation (`:7918`).
- [`imgui.cpp` — navigation][src-navrefpos] — `NavCalcPreferredRefPos` (`:13926`) with the
  cursor offset (`:13935-13937`), `NavUpdateCancelRequest` (`:14495`) and its popup rung
  (`:14517`), and `NavUpdateContextMenuRequest` (`:14538`) with the two published ids and
  the `MoveId` retarget (`:14552-14557`).
- [`imgui_widgets.cpp` — menus][src-bjk5] (`:9144-9740`) — `IsRootOfOpenMenuSet` (`:9372`),
  `BeginMenuEx` (`:9396`) and its flag composition (`:9408-9410`), the append-by-id scan
  (`:9412-9426`), the hoverable-check exemption (`:9433-9435`), the submenu chevron
  (`:9482`), the drag-release of `ActiveId` (`:9488-9494`), the bjk5 citation
  (`:9504-9505`), the aim-triangle construction (`:9506-9524`), `want_close` (`:9530`),
  hover-to-open with the timer fallback (`:9535-9540`), the nav-init path (`:9600-9603`)
  and `EndMenu`'s nav-left close (`:9635-9640`).
- [`imgui_widgets.cpp` — combo][src-combopopup] — `BeginComboPopup` (`:2019`) and its
  pre-measure-then-place sequence (`:2058-2067`), the one surface that positions itself.
- [`imgui_widgets.cpp` — `Selectable`][src-selectable] — `ImGuiItemFlags_AutoClosePopups`
  firing `CloseCurrentPopup` on press (`:7578`).
- [`imgui_internal.h`][src-popupdata] — `ImGuiPopupPositionPolicy` (`:1500`),
  `ImGuiPopupData` (`:1508-1521`), the viewport work insets documented as iOS
  `safeAreaInsets` / Android `DisplayCutout` (`:2006-2012`), the hover-delay context
  scalars (`:2515-2526`), `ImGuiWindow::AutoPosLastDirection` (`:2769`), the two stacks
  (`:2376-2377`) and the internal popup API block (`:3509-3528`).
- [`imgui.h`][src-imgui-h] — `IMGUI_VERSION` (`:32`), the public popup and tooltip API
  block (`:845-885`), `ImGuiPopupFlags` (`:1360-1375`), `ImGuiHoveredFlags_NoSharedDelay`
  (`:1498`) and `Platform_SetImeDataFn` (`:4069`).
- [`imgui_demo.cpp`][src-demo] — the uncontrolled-by-design rationale (`:5427-5434`).
- [`docs/CHANGELOG.txt`][src-changelog] — the `OpenPopup` bool-return entry (`:166-168`)
  and the menu press-drag-release fixes (`:432-438`).

For the catalog this page belongs to see [`./index.md`][index]; for the shared vocabulary
used above see [`./concepts.md`][concepts]; for how this subject
lands against the rest of the corpus see [`./comparison.md`][comparison] and
[`./features-people-forget.md`][forget]; for the toolkit-side starting point and the
resulting design see [`./sparkles-baseline.md`][baseline] and
[`./proposal.md`][proposal]. Related subjects with an in-canvas surface model include
[GPUI][gpui], [Flutter][flutter], [Textual][textual] and [Turbo Vision][tvision]; for the
out-of-process contrast see [`./xdg-positioner.md`][xdg] and [GTK4][gtk4]. Neighbouring
research trees: [window-system integration][wsi], [platform UI guidelines][pug],
[UI layout][ui-layout] and [Sean Parent][sean-parent]. Toolkit specs:
[UI index][spec-ui], [input][spec-input], [containers][spec-containers],
[state machines][spec-stm], [backends][spec-backends] and [widgets][spec-widgets].

<!-- References -->

[repo]: https://github.com/ocornut/imgui
[repo-pin]: https://github.com/ocornut/imgui/tree/46d39d56febc2a00bdd2270dc88c8a13f2a0441a
[docs-faq]: https://github.com/ocornut/imgui/blob/46d39d56febc2a00bdd2270dc88c8a13f2a0441a/docs/FAQ.md
[src-imgui-h]: https://github.com/ocornut/imgui/blob/46d39d56febc2a00bdd2270dc88c8a13f2a0441a/imgui.h#L32
[src-findbestpos]: https://github.com/ocornut/imgui/blob/46d39d56febc2a00bdd2270dc88c8a13f2a0441a/imgui.cpp#L12893
[src-tooltipflags]: https://github.com/ocornut/imgui/blob/46d39d56febc2a00bdd2270dc88c8a13f2a0441a/imgui.cpp#L12316
[src-hovercommit]: https://github.com/ocornut/imgui/blob/46d39d56febc2a00bdd2270dc88c8a13f2a0441a/imgui.cpp#L5714
[src-displaylayer]: https://github.com/ocornut/imgui/blob/46d39d56febc2a00bdd2270dc88c8a13f2a0441a/imgui.cpp#L5935
[src-beginplacement]: https://github.com/ocornut/imgui/blob/46d39d56febc2a00bdd2270dc88c8a13f2a0441a/imgui.cpp#L7899
[src-navrefpos]: https://github.com/ocornut/imgui/blob/46d39d56febc2a00bdd2270dc88c8a13f2a0441a/imgui.cpp#L13926
[src-bjk5]: https://github.com/ocornut/imgui/blob/46d39d56febc2a00bdd2270dc88c8a13f2a0441a/imgui_widgets.cpp#L9504
[src-combopopup]: https://github.com/ocornut/imgui/blob/46d39d56febc2a00bdd2270dc88c8a13f2a0441a/imgui_widgets.cpp#L2019
[src-selectable]: https://github.com/ocornut/imgui/blob/46d39d56febc2a00bdd2270dc88c8a13f2a0441a/imgui_widgets.cpp#L7578
[src-popupdata]: https://github.com/ocornut/imgui/blob/46d39d56febc2a00bdd2270dc88c8a13f2a0441a/imgui_internal.h#L1508
[src-demo]: https://github.com/ocornut/imgui/blob/46d39d56febc2a00bdd2270dc88c8a13f2a0441a/imgui_demo.cpp#L5427
[src-changelog]: https://github.com/ocornut/imgui/blob/46d39d56febc2a00bdd2270dc88c8a13f2a0441a/docs/CHANGELOG.txt#L166
[index]: ./index.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[forget]: ./features-people-forget.md
[baseline]: ./sparkles-baseline.md
[proposal]: ./proposal.md
[apg]: ./aria-apg.md
[gpui]: ./gpui.md
[flutter]: ./flutter.md
[textual]: ./textual.md
[tvision]: ./turbo-vision.md
[gtk4]: ./gtk4.md
[xdg]: ./xdg-positioner.md
[wsi]: ../window-system-integration/index.md
[pug]: ../platform-ui-guidelines/index.md
[ui-layout]: ../ui-layout/index.md
[sean-parent]: ../sean-parent/index.md
[spec-ui]: ../../specs/ui/index.md
[spec-input]: ../../specs/ui/input.md
[spec-containers]: ../../specs/ui/containers.md
[spec-stm]: ../../specs/ui/state-machines.md
[spec-backends]: ../../specs/ui/backends.md
[spec-widgets]: ../../specs/ui/widgets.md
