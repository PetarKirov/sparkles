# GTK4 — `GtkPopover` / `GtkTooltip` / `GdkPopupLayout` (C, GNOME)

GTK4 splits the anchored overlay into a plain-data placement value and a swappable
solver, so the same ten-scalar description is executed by a Wayland compositor, by
GDK's own integer arithmetic on X11/Win32/macOS, or by an Android `ViewGroup` — and
the toolkit above never learns which happened.

| Field             | Value                                                                                         |
| ----------------- | --------------------------------------------------------------------------------------------- |
| Language          | C (GObject); Java for the Android backend glue                                                |
| License           | LGPL-2.1-or-later                                                                             |
| Repository        | [GNOME/gtk][repo]                                                                             |
| Documentation     | [`GdkPopupLayout` API reference][gdk-docs], [`GtkPopover` API reference][gtk-docs]            |
| Category          | Native desktop toolkit (GTK)                                                                  |
| Surface model     | Both — see the surface-model note below                                                       |
| **Revision read** | [`817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671`][repo-pin] (version 4.23.1, committed 2026-06-07) |

A `GdkPopup` is normally a real compositor surface — a Wayland `xdg_popup`, an X11
override-redirect window, a Win32 `HWND`, an `NSWindow`. The Android backend
implements the identical `GdkPopup` interface as an in-window child `View` clipped
to the parent surface rect. The same `GdkPopupLayout` value and, off Wayland, the
same in-process solver serve both. That makes GTK4 one of the few subjects in this
catalog whose own source tree contains a one-surface implementation of its
multi-surface design; see [`./comparison.md`][comparison] for how that lands against
the rest of the corpus.

> [!NOTE]
> This page is a source reading, not a runtime observation: nothing here was built
> or executed. The clone is a sparse checkout limited to `gdk/`, `gtk/` and
> `modules/`; `testsuite/`, `NEWS` and the Android Java glue were read out of the
> git object store, and `demos/` and `docs/` were not read at all. `libadwaita` —
> where GNOME applications actually obtain popover animations and adaptive sheet
> presentation — is out of scope here entirely.

---

## Overview

### What it solves

GTK4 needs one anchored-overlay mechanism that works when the application is not
allowed to know where its own windows are. On Wayland a client cannot read its
surface's position, cannot grab the pointer, and cannot place a child surface
itself; it can only hand the compositor a description and be told the result. GTK4's
answer was to make that description a first-class, backend-neutral value —
`GdkPopupLayout` — and to keep the code that resolves it strictly private, so each
backend may supply its own.

The value is deliberately inert. It is ten scalars and nothing else:

```c
// gdk/gdkpopuplayout.c:64-79
struct _GdkPopupLayout
{
  /* < private >*/
  grefcount ref_count;

  GdkRectangle anchor_rect;
  GdkGravity rect_anchor;
  GdkGravity surface_anchor;
  GdkAnchorHints anchor_hints;
  int dx;
  int dy;
  int shadow_left;
  int shadow_right;
  int shadow_top;
  int shadow_bottom;
};
```

There are no pointers, no callbacks and no widget references in it. It has
`gdk_popup_layout_copy` (`gdkpopuplayout.c:159`) and `gdk_popup_layout_equal`
(`:191`) and no behavior at all — which is what lets a reposition be deduplicated by
comparing two of them (`gdk/wayland/gdkpopup-wayland.c:1375`), and what lets the
whole description be marshalled onto a Wayland `xdg_positioner` request by
request.

Above GDK, `GtkPopover` is a `GtkWidget` that is _also_ a `GtkNative`: it lives in
the widget tree, parented to its anchor widget, so CSS, action groups, shortcuts,
accessibility parentage and lifetime all work — while owning a separate `GdkSurface`
and `GskRenderer` for stacking and input. `GtkTooltip` is a different animal
entirely: a per-display singleton driven from every event in `gtk_main_do_event`,
with a three-constant timing machine and pointer-aware anchor synthesis.

### Design philosophy

Geometry is data; resolution is negotiated; the toolkit adapts its rendering to
whatever answer came back. The header states the fallback policy in prose, and it is
the whole of GTK's [constraint-adjustment][concepts] vocabulary:

```text
gdk/gdkpopuplayout.h:54-56

 * In general, when multiple flags are set, flipping should take precedence over
 * sliding, which should take precedence over resizing.
```

The corresponding enum is six bits — `GDK_ANCHOR_FLIP_X`, `FLIP_Y`, `SLIDE_X`,
`SLIDE_Y`, `RESIZE_X`, `RESIZE_Y` (`gdkpopuplayout.h:57-68`) — and the precedence is
not encoded anywhere except in the order of three `if` blocks inside the solver. That
is the cheapest possible encoding of a fallback policy, and it is the reason there is
no preferred-placement _list_ anywhere in GTK4.

The corresponding cost is admitted in the same file's doc comment, which tells the
caller that the resolved result is readable but that reacting to it has limits:

```text
gdk/gdkpopuplayout.c:54-61

 * You can learn about the result by calling [method@Gdk.Popup.get_position_x],
 * ... This can be used to adjust the rendering. For example,
 * [class@Gtk.Popover] changes its arrow position accordingly. But you have to be
 * careful avoid changing the size of the popover, or it has to be presented again.
```

The second half of the philosophy is that the solver is _not_ API.
`gdk_surface_layout_popup_helper`, `maybe_flip_position` and the gravity-flip
helpers all live in `gdksurfaceprivate.h` (`:186`). Only the VALUE and the RESOLVED
RESULT are public. A caller therefore cannot ask "where would this land?" without
actually presenting the popup.

---

## How it works

A present is four steps: build the value, hand it to the backend, read the result
back, adapt the rendering.

```text
GtkPopover                      GDK                          backend
----------                      ---                          -------
create_popup_layout()  ──────>  GdkPopupLayout
gdk_popup_present(w,h,layout) ─────────────────────────────>  x11/win32/macos/android:
                                                                gdk_surface_layout_popup_helper()
                                                              wayland:
                                                                xdg_positioner + compositor
update_popover_layout()  <────  gdk_popup_get_position_x/y
                                gdk_popup_get_rect_anchor
                                gdk_popup_get_surface_anchor
gtk_popover_get_gap_coords()    (arrow follows final_position)
```

### `maybe_flip_position` — one-axis placement with a badness-compared flip

Nine [gravities][concepts] by nine gravities reduce to two signs per axis.
`get_anchor_x_sign` / `get_anchor_y_sign` (`gdk/gdksurface.c:190-236`) map each
`GdkGravity` to `-1`, `0` or `+1`, and "align start / center / end" then collapses
into an integer multiplication:

```c
// gdk/gdksurface.c:255-258
  /* Try to fit without flipping */

  *flipped = FALSE;
  primary = rect_pos + (1 + rect_sign) * rect_size / 2 + offset - (1 + surface_sign) * surface_size / 2;
```

[Flip][concepts] is not "flip when it does not fit". It is a comparison of _badness_
— how far each candidate lies outside the bounds — and the mirrored candidate is
accepted only when it is not worse:

```c
// gdk/gdksurface.c:263-283
  limit = bounds_pos + bounds_size - surface_size;

  if (primary < bounds_pos)
    badness = bounds_pos - primary;
  if (primary > limit)
    badness = MAX (badness, primary - limit);
  /* If it fit, we're done */
  if (badness == 0)
    return primary;

  /* See if flipping helps */

  secondary = rect_pos + (1 - rect_sign) * rect_size / 2 - offset - (1 - surface_sign) * surface_size / 2;

  if (secondary < bounds_pos && bounds_pos - secondary > badness)
    return primary;
  else if (secondary > limit && secondary - limit > badness)
    return primary;
```

Note the sign trick: `1 - sign` instead of `1 + sign`, and `-offset` instead of
`+offset`, computes the mirrored candidate without ever touching the gravity enums.
The whole function is integer arithmetic with no allocation and no dependency on the
windowing system.

> [!IMPORTANT]
> GTK's acceptance rule ("the less-bad candidate wins") is not the rule the Wayland
> protocol specifies for the same six bits, where a flip is reverted unless it makes
> the surface fully unconstrained. GTK4 therefore solves the same positioner value
> with a different acceptance rule on its non-Wayland backends (`x11`, `win32`,
> `macos`, `android`, `broadway`) than a compositor applies on Wayland — a
> divergence observable inside one toolkit, and one that the subsequent slide step
> can pin to opposite edges. See [`./xdg-positioner.md`][xdg] for the protocol side.

### `gdk_surface_layout_popup_helper` — the full flip / slide / resize pipeline

`gdk/gdksurface.c:313-444`. The steps, in the order the statements appear:

1. Promote the [anchor rect][concepts] to root coordinates via
   `gdk_surface_get_root_coords(surface->parent, ...)`.
2. Shrink the requested size by the shadow widths to obtain the VISUAL box.
3. Solve X and Y independently with `maybe_flip_position`.
4. If `SLIDE` is set on that axis, clamp — **far edge first, then near edge**, so
   the near edge wins for an over-large popup:

   ```c
   // gdk/gdksurface.c:374-381
   if (final_rect.x + final_rect.width > bounds->x + bounds->width)
     final_rect.x = bounds->x + bounds->width - final_rect.width;

   if (final_rect.x < bounds->x)
     final_rect.x = bounds->x;
   ```

5. If `RESIZE` is set on that axis, shrink from whichever side is outside — near
   side first (moving the origin and reducing the size), then far side (size only).
6. Re-add the shadow to origin and size.
7. Subtract the parent origin unless `GDK_SURFACE_LAYOUT_POPUP_HELPER_ROOT_OUT` is
   set. The Android backend sets it, because there is no root.
8. Mirror the two gravities on every axis that flipped, and store the pair on
   `surface->popup` so the toolkit can read the resolved side back.

The `/2` truncations in step 3 bias odd-size centering toward the low edge.

### Reading the result back

`update_popover_layout` (`gtk/gtkpopover.c:390`) is where the requested value and the
resolved result are kept in different fields — `priv->layout` (the request) versus
`priv->final_rect` and `priv->final_position` (the resolution). It reads the position
and the two resolved gravities off the surface, derives `flipped_x` / `flipped_y` by
comparing requested against resolved through `did_flip_horizontally` /
`did_flip_vertically` (`:354-388`), maps `(requested position, flipped)` to
`final_position`, and queues an allocate plus drops the cached arrow render node only
if something actually changed.

The `did_flip_*` predicates carry a guard worth naming: a horizontal flip is believed
only when **both** the rect anchor and the surface anchor went from east-facing to
west-facing (or the reverse). A compositor that mirrored only one of the two would
otherwise make the arrow render on the wrong side (`gtk/gtkpopover.c:414-423`).

### Wayland: inferring the result by recomputing candidates

On Wayland the compositor reports only the final `x`/`y`. To learn _which_
constraint adjustment was applied, GTK recomputes its own unconstrained candidate
(`calculate_popup_rect`), then per axis builds a copy of the layout with that axis's
gravities mirrored, recomputes, and tests coordinate equality:

```c
// gdk/wayland/gdkpopup-wayland.c:699-700
      if (flipped_x_rect.x == x)
        flipped_rect.x = x;
```

Placement result is inferred, not communicated. Equal coordinates do not prove a
flip, which is exactly why `GtkPopover` adds the both-gravities guard above.

---

## The analysis spine

### 1. Anchor model

The anchor is a `GdkRectangle` in the parent SURFACE's coordinate space plus two
`GdkGravity` enums, packed into a comparable value. `GtkPopover` stores an optional
`GdkRectangle pointing_to` in the PARENT WIDGET's space (with a `has_pointing_to`
flag and width/height forced to at least 1, `gtk/gtkpopover.c:2248`) and converts it
at present time. With no `pointing_to`, the anchor is the whole parent widget's
computed bounds — element-anchor and rect-anchor are literally the same code path,
one of them just supplying the widget bounds.

Point and cursor anchors are expressed as degenerate rects: `GtkPopoverBin` uses
`{x, y, 0, 0}` at the gesture coordinates for context menus
(`gtk/gtkpopoverbin.c:123`), and `GtkTooltip` synthesizes a `cursor_size`-square rect
around the pointer when the widget rect is too tall. Text-range anchoring exists only
as caller-supplied rects — `gtk_tooltip_set_tip_area` (`gtk/gtktooltip.c:331`), which
treeviews use for per-cell tooltips and which doubles as a re-query hit region.
Multiple triggers sharing one popup is not modelled: a `GtkPopover` has exactly one
widget parent, and re-anchoring means `set_pointing_to` plus a re-present. A
[virtual anchor][concepts] is achievable by parenting the popover to any widget and
supplying a rect; `GtkPopoverBin`'s keyboard path deliberately sets
`pointing_to = NULL` so an action-triggered menu anchors to the whole widget while
the pointer path anchors to the click point (`gtk/gtkpopoverbin.c:695`).

**Algorithm.** `compute_surface_pointing_to` (`gtk/gtkpopover.c:464`) transforms the
rect through `gtk_widget_compute_transform(parent -> native)`, offsets it by
`gtk_native_get_surface_transform`, then floors the origin and ceils the size to
integers. GDK then promotes to root coordinates before the solve. Wayland
additionally intersects the anchor rect with the parent's window geometry and falls
back to a 1×1 rect at the parent origin if the intersection is empty, because the
protocol requires a non-empty contained rect.

**Where the behavior lives.** Value: `gdk/gdkpopuplayout.c`, backend-neutral.
Widget-to-surface conversion: `gtk/gtkpopover.c`. Root promotion:
`gdk/gdksurface.c`. Protocol clamping: `gdk/wayland/gdkpopup-wayland.c`.

**Degradation.** The representation is integers only, so it survives every
degradation axis: no OS window, no hover, no script, no sub-cell precision, no key
release. In whole cells the floor/ceil become cell rounding of the anchor's cell
rect and the degenerate point anchor is a single cell. The one part that does not
survive is the `ROOT_OUT` distinction: with one surface there is no root, so solving
in parent-local coordinates — the Android path — is the only mode.

### 2. Placement model

Two `GdkGravity` values (eight compass points plus `CENTER`, with `STATIC` aliased to
`NORTH_WEST`) name the point on the anchor rect and the point on the popup that are
pinned together. The fallback space is exactly one mirror per axis, plus slide, plus
resize, in that fixed precedence. There is no ordered candidate list.

`GtkPopover` translates its four-way `GtkPositionType` and three-way align into the
gravity pair and hard-codes the hint mask per side: FLIP on the main axis, SLIDE on
the cross axis. The four assignments in the file are `GDK_ANCHOR_FLIP_X | GDK_ANCHOR_SLIDE_Y`
for `GTK_POS_LEFT`/`RIGHT` (`gtk/gtkpopover.c:546`, `:571`) and
`GDK_ANCHOR_FLIP_Y | GDK_ANCHOR_SLIDE_X` for `GTK_POS_TOP`/`BOTTOM` (`:596`, `:621`)
— never FLIP on the cross axis, never SLIDE on the main axis. `RESIZE_X`/`RESIZE_Y`
are added only when the popover's minimum differs from its natural size in that
orientation (`:682-685`).

The [clipping boundary][concepts] is the monitor WORKAREA — panels excluded — of the
monitor with the largest intersection with the root-space anchor rect
(`gdk/gdksurface.c:156`), so multi-monitor selection follows the anchor, not the
popup. If no workarea intersects, GDK retries against full monitor geometry, then
falls back to monitor 0. Android replaces the whole computation with
`bounds = {0, 0, parent.width, parent.height}` (`gdk/android/gdkandroidpopup.c:57`).

> [!WARNING]
> RTL is handled only for `GTK_POS_TOP` / `GTK_POS_BOTTOM`, where `halign` start/end
> swaps `NORTH_WEST` and `NORTH_EAST`. `GTK_POS_LEFT` / `GTK_POS_RIGHT` are physical
> sides and their `valign` start/end is not mirrored.

**Where the behavior lives.** Solver and monitor pick: `gdk/gdksurface.c`. Hint
semantics and precedence prose: `gdk/gdkpopuplayout.h`. Policy — which gravities,
which hints — `create_popup_layout` in `gtk/gtkpopover.c:504`. Wayland delegates to
the compositor; Android supplies bounds and insets.

**Degradation.** The arithmetic is already integral, so whole cells cost nothing;
the `/2` truncation is the rounding a grid wants. With no OS window the workarea
becomes the single surface's cell rect, which is precisely the Android path. With no
script — a static HTML emit — nothing can be measured, so only the unconstrained
`primary` position is expressible: one side, baked at emit time. On Android the
soft-keyboard inset is subtracted from the toplevel's measured size before the
surface size is set (`ToplevelActivity.java:394` `onApplyWindowInsets`), so the IME
inset is an INPUT to placement by construction and no code in the placement path
ever has to know the keyboard exists. There is no IME avoidance on desktop.

### 3. Collision and geometry engine

There is no overflow detection, no clipping-ancestor discovery and no scroll-container
walk, because the popup is not clipped by anything in the widget tree — it is a
separate surface. Collision is one rectangle-versus-rectangle solve against one
bounds rect, O(1) per present, all integer.

Transforms and zoom: the anchor rect is produced by `graphene_matrix_transform_bounds`
through the widget's arbitrary `GskTransform` chain and then floored and ceiled, so a
rotated or scaled anchor degrades to its axis-aligned integer bounding box.
Device-pixel ratio and fractional scale never reach the solver — everything is in
logical surface pixels and the backend multiplies at the very end
(`gdk/android/gdkandroidpopup.c:80`).

**Algorithm (tracking).** Push-based, not polled and not per-frame.
`sync_widget_surface_transform` (`gtk/gtkwidget.c:3334`) recomputes a widget's
surface-relative matrix on allocate and invokes registered callbacks only when the
matrix actually changed; children re-sync through
`parent_surface_transform_changed_cb` (`:3379`), so an ancestor move walks down once.
`GtkPopover` and `GtkTooltipWindow` both re-present from that callback
(`gtk/gtkpopover.c:1214`). On Wayland GTK additionally sets `xdg_positioner.set_reactive`
(`gdk/wayland/gdkpopup-wayland.c:846`) so the compositor re-solves when the parent
moves, and stops tracking itself.

**Algorithm (resize).** Bidirectional and unusually strict. `present_popup` asks for
the natural size; the compositor may grant something smaller;
`gtk_popover_native_layout` then calls `is_acceptable_size`
(`gtk/gtkpopover.c:748-756`) and POPS THE POPOVER DOWN if the granted size is below
the widget's minimum for the granted cross size, rather than rendering broken.

**Algorithm (dedup).** If the unconstrained size is unchanged and
`gdk_popup_layout_equal` reports the layouts identical, the reposition never reaches
the compositor (`gdk/wayland/gdkpopup-wayland.c:1375`).

**Degradation.** What generalizes: the whole solver as a pure integer function, the
push-based invalidate-on-transform-change discipline, and the `equal()`-based dedup.
What does not: "the overlay is unclipped because it is another surface". In one
surface the overlay geometry must additionally escape every ancestor clip explicitly,
and the collision box is the surface, not a monitor. With no script the engine is
absent entirely. In an immediate-mode painter the tracking machinery is unnecessary:
re-solving every frame is O(1).

> [!WARNING]
> When the compositor is too old for `xdg_popup.reposition`, GTK's fallback is to
> unmap and remap the popup — but `is_fallback_relayout_possible`
> (`gdk/wayland/gdkpopup-wayland.c:1127`) refuses to do so if any child popup is
> mapped, silently leaving the popup mis-positioned with no diagnostic.

### 4. Arrow / caret geometry

The arrow ("tail") is not data exposed to a styling layer. It is three points
computed at snapshot time and rasterized with cairo, governed by two compile-time
constants: `TAIL_GAP_WIDTH 24` and `TAIL_HEIGHT 12` (`gtk/gtkpopover.c:162-163`).
Its side is `priv->final_position`, i.e. the side AFTER the flip was resolved, so it
always points back at the anchor. Its along-axis offset is the anchor rect's centre
expressed in popover-local coordinates using the RESOLVED origin — which is how slide
is absorbed by the arrow moving rather than by the overlay detaching.

**Algorithm.** For a vertical arrow, with `W` the popover width, `r` the border
radius and `tip_pos` the anchor centre in popover-local coordinates:

```c
// gtk/gtkpopover.c:1371-1385
      tip_pos = rect.x + (rect.width / 2);
      initial_x = CLAMP (tip_pos - TAIL_GAP_WIDTH / 2,
                         border_radius,
                         popover_width - TAIL_GAP_WIDTH - border_radius);
      initial_y = base;

      tip_x = CLAMP (tip_pos, 0, popover_width);
      tip_y = tip;

      final_x = CLAMP (tip_pos + TAIL_GAP_WIDTH / 2,
                       border_radius + TAIL_GAP_WIDTH,
                       popover_width - border_radius);
      final_y = base;
```

The base endpoints are clamped into a corner-radius-safe span; the TIP is clamped
only to `[0, W]`. Because the tip clamp is looser than the base clamp, an anchor far
off to one side keeps moving the tip after the base has stopped, and the triangle
becomes a lopsided lean rather than detaching or vanishing.

Arrow size feeds layout in three places: `measure()` adds `TAIL_HEIGHT` to min and
nat on the arrow axis, `get_minimal_size` (`:1536`) imposes `2 * border_radius +
TAIL_GAP_WIDTH` as a cross-axis minimum, and `size_allocate` (`:1620`) insets the
contents by the tail height on the arrow side. Most striking: the same three-point
path is also the pointer INPUT REGION. `gtk_popover_update_shape`
(`:1458-1533`) rasterizes tail path plus rounded contents box into a cairo image
surface and hands the derived region to `gdk_surface_set_input_region`, so clicks in
the shadow gutter and outside the triangle fall through to whatever is behind.

**Where the behavior lives.** `gtk/gtkpopover.c` only. Nothing about the arrow exists
in GDK; it is purely a GTK rendering concern parameterised by the resolved gravity
that GDK reports back.

**Degradation.** In whole cells an arrow is one glyph in one cell.
`TAIL_GAP_WIDTH`/`TAIL_HEIGHT` collapse to one cell; the three-point path collapses
to a single character chosen by side; the CLAMP becomes "clamp the arrow cell to
`[1, width-2]`" so it never sits on a corner. The tip-versus-base asymmetry has no
cell analogue and should be dropped — at one cell the arrow either names the anchor's
column or is omitted. The input-region trick does not survive at all: with one
surface there is nothing to fall through to. Shadow and radius offsets vanish on a
cell target, which conveniently makes tip and base the same line. The part that DOES
survive and matters is that arrow size feeds the measure pass: reserve one cell on
the arrow side in the overlay's minimum.

### 5. Trigger semantics

There is no shared trigger abstraction; each consumer wires its own.

`GtkPopoverBin` (new in 4.22, `gtk/gtkpopoverbin.c:24`) is the closest thing to a
policy: a `GtkGestureClick` whose `pressed_cb` (`:158`) consults
`gdk_event_triggers_context_menu` — pointer-type, button and modifier logic
centralized in GDK — plus a `GtkGestureLongPress` for touch (`:180`), a shortcut
controller, and a `menu.popup` widget action. The three paths deliberately produce
DIFFERENT anchors: click and long-press pass the gesture coordinates and anchor to a
zero-size rect there, while the action/keyboard path anchors to the whole widget.
`GtkMenuButton` is a plain toggle. Tooltips are triggered by the global event pump,
not by the widget: `gtk_main_do_event` unconditionally calls
`_gtk_tooltip_handle_event` for every event (`gtk/gtkmain.c:1788`) and the widget only
opts in via its `has-tooltip` flag, read during requery.

Pointer-type distinction lives in `tooltips_enabled` (`gtk/gtktooltip.c:852`), which
returns `FALSE` when the event's source device is `GDK_SOURCE_TOUCHSCREEN` and when
any of `BUTTON1`..`BUTTON5` is held — so tooltips never appear during a drag and
never on touch.

Race avoidance between triggers is by construction rather than arbitration: only one
`GtkTooltip` exists per display and each transition either clears or restarts the
single timeout id, while gestures resolve by claim/deny on the event sequence
(`pressed_cb` explicitly DENIES the sequence when the event is not a context-menu
trigger, so another gesture can take it).

**Degradation.** With no hover, the long-press gesture is already the declared
substitute — and it sits _beside_ the click gesture rather than instead of it; both
are always installed, which is the pattern that survives a target where the pointer
type can change mid-session. With no key release, only mnemonic visibility and
focus-visible tracking are lost: Escape and every trigger are press-only. With no
script, only `:hover` / `:focus-within` style triggers survive — tooltip and
hovercard, never a context menu. The pointer/keyboard anchor split costs one nullable
field and is the most portable idea in this dimension.

### 6. Timing

Three constants and one boolean:

```c
// gtk/gtktooltip.c:71-73
#define HOVER_TIMEOUT          500
#define BROWSE_TIMEOUT         60
#define BROWSE_DISABLE_TIMEOUT 500
```

`HOVER_TIMEOUT` is the cold [warm-up][concepts]; `BROWSE_TIMEOUT` is the warm one;
`BROWSE_DISABLE_TIMEOUT` is the [cool-down][concepts] — how long warmth survives
after a tooltip hides. `browse_mode_enabled` is set the instant a tooltip becomes
visible (`:749`) and any pending decay timer is cancelled; hiding starts the 500 ms
decay, whose expiry both clears browse mode and DESTROYS the singleton
(`tooltip_browse_mode_expired`, `:449`).

**Algorithm.** States `{Absent, Cold, Warm, Shown}`.

- motion/enter on a widget: if Absent, create the singleton, go Cold, arm `T = 500`.
- if Cold or Warm: requery; if the picked widget differs from the shown widget, or
  the pointer left the caller-declared `tip_area`, or the event is a LEAVE, hide;
  otherwise arm `T = browse ? 60 : 500`, cancelling any prior.
- `T` fires: pick the widget under the pointer, requery walking ancestors; if a
  handler returned `TRUE`, position, show, set `browse := TRUE`, cancel decay.
- hide: cancel `T`; if visible, arm the 500 ms decay; hide the window.
- decay fires: `browse := FALSE`, destroy the singleton.
- any of button press, key press, scroll, drag-enter, grab-broken: hide immediately.

Two consequences worth naming. Warmth is stored per `GdkDisplay`, so "instant
subsequent tooltips" is global across every window and widget on that display —
moving from a toolbar button to a completely different window still takes the 60 ms
path. And there is no separate close delay at all: hide is immediate on every one of
those causes. Re-entry into the SAME widget while visible does nothing, because
`gtk_tooltip_hide_tooltip` early-returns when not visible and
`gtk_tooltip_start_delay` (`:810`) early-returns when visible. Re-query runs on every
motion even while shown, so a treeview can keep one tooltip alive across pixels but
replace it across rows.

There is no maximum display duration. Separately, submenus carry their own 80 ms
timer (dimension 7) and mnemonic underlines a `MNEMONICS_DELAY` of 300 ms
(`gtk/gtkpopover.c:160`).

**Where the behavior lives.** Entirely `gtk/gtktooltip.c`, as GLib timeouts on the
default main context, keyed by a `GQuark` on the `GdkDisplay`.

**Degradation.** With no timers, only the cold delay is expressible (a
`transition-delay` on a `:hover`-revealed element); warm and cool-down cannot be
expressed at all, so a static emit must pick one delay. Every transition here is a
pure function of `(event, elapsed ms)` with all state in one struct, so the machine
would be fully assertable against a virtual clock — but GTK itself does not do this,
and no test of the timing machine was found in the extracted `testsuite/` tree. On
touch the dimension is moot, since tooltips are disabled for touchscreen sources.

### 7. Interactive hover / travel

GTK4 has no [safe polygon][concepts], no pointer bridge and no trajectory heuristic.

For tooltips the problem is dodged geometrically. The anchor rect is inflated by
`MAX(4, gtk-cursor-theme-size - 32)` pixels before solving (`gtk/gtktooltip.c:617-633`),
so the tooltip is pushed clear of the cursor. The tooltip window is nevertheless a
real surface with a real input region; `gtk_tooltip_set_surface` explicitly ignores
surfaces belonging to a `GtkTooltipWindow` (`:502`) so entering one can never
re-target the machinery. INFERENCE: the combination appears to make the tooltip
unreachable in normal use rather than deliberately non-interactive — nothing in the
source states an intent to make it hoverable.

For menus the entire diagonal-travel problem is answered by a debounce.

**Algorithm.** `#define OPEN_TIMEOUT 80` (`gtk/gtkmodelbutton.c:1423`).

- on enter(item): if `popover.open_submenu == NULL`, open ours immediately (zero
  delay); otherwise call `start_open`.
- `start_open` (`:1426`): if our popover is already visible, return; kill any timer;
  arm 80 ms via `g_timeout_add (OPEN_TIMEOUT, open_submenu, button)` (`:1435`).
- on motion(item): call `start_open` again — i.e. RESTART the timer (`:1479`).
- on leave(item): kill the timer, clear the active item.
- on fire: mark the item active, close sibling submenus if the open one is not ours,
  pop ours up, record parent/child links.

The timer therefore only elapses once the pointer has been STILL inside the item for
80 ms. Crossing an intervening item on the way to an already-open submenu is
tolerated as long as the pointer keeps moving. This is motion quiescence substituting
for trajectory geometry: one timer id, two pointers, no coordinates retained, no
polygon, no history buffer.

**Where the behavior lives.** The debounce in `gtk/gtkmodelbutton.c`; active-item and
open-submenu bookkeeping in `gtk/gtkpopovermenu.c`; the anchor inflation in
`gtk/gtktooltip.c`.

**Degradation.** The algorithm retains no coordinates, so whole cells cost it
nothing and it works with one pointer and no sub-cell precision. With no hover the
dimension is not applicable and submenus must open on tap. With no timers neither
the debounce nor the immediate-open distinction can be expressed — a pure-CSS submenu
opens on `:hover` instantly, which is the degenerate branch GTK already takes when
nothing else is open. The tooltip's cursor clearance degrades to one cell.

### 8. Dismissal

Two independent layers.

**(a) GDK autohide.** `check_autohide` (`gdk/gdksurface.c:2736-2797`) runs before
every event is delivered (`:2904`). It fires on `GDK_BUTTON_PRESS`, `GDK_TOUCH_BEGIN`,
`GDK_TOUCHPAD_SWIPE` and `GDK_TOUCHPAD_PINCH` only. Button RELEASE, touch END and
touch CANCEL sit inside an `#if 0` with an in-tree explanation:

```c
// gdk/gdksurface.c:2745-2754
    case GDK_BUTTON_PRESS:
#if 0
    // FIXME: we need to ignore the release that is paired
    // with the press starting the grab - due to implicit
    // grabs, it will be delivered to the same place as the
    // press, and will cause the auto dismissal to be triggered.
    case GDK_BUTTON_RELEASE:
    case GDK_TOUCH_END:
    case GDK_TOUCH_CANCEL:
#endif
```

This is the canonical press-versus-release [light-dismiss][concepts] hazard, admitted
and unfixed. The rest of the function: look up the seat's topmost [grab][concepts]
surface; null out the event surface if it is itself an autohide surface that does not
currently contain the pointer — where `has_pointer` is maintained from ENTER/LEAVE
with `GDK_CROSSING_NORMAL` only, so grab-induced crossings never flip the bit
(`:2786-2792`); then, if the grab surface is neither the event surface nor its
parent, walk UP the surface parent chain hiding every autohide surface until the
event surface is reached. Clicking a parent menu therefore closes only the submenus
above it.

**(b) GTK level.** Escape in `gtk_popover_key_pressed` calls popdown and returns
`TRUE` — handled, not propagated (`gtk/gtkpopover.c:933`). `popdown` then runs
`cascade_popdown` (`:2441-2469`), which returns immediately for non-autohide
popovers, otherwise walks up the widget parents closing every ancestor `GtkPopover`
whose `cascade-popdown` property is `TRUE` (default `FALSE`; `GtkPopoverMenu` sets it
in init), stopping at the first that is `FALSE`, and finally calls `grab_focus` on
the widget below. `GtkPopoverMenu` additionally closes itself on focus-out when focus
moved anywhere outside (`gtk/gtkpopovermenu.c:286`).

Anchor removal is handled by parenthood: the popover is a widget child, so
unparenting or destroying the parent unrealizes it, and `gtk_popover_unmap` calls
`gtk_tooltip_unset_surface` (`gtk/gtkpopover.c:1266`) so a tooltip anchored inside a
closing popover is detached rather than left parented to a dead surface. Scroll does
not dismiss a popover, though it does dismiss a tooltip. Window deactivation
dismisses indirectly, via the seat grab breaking.

> [!NOTE]
> On Android, `_gdk_android_toplevel_on_back_press`
> (`gdk/android/gdkandroidtoplevel.c:132`) synthesises a `GDK_DELETE` on the
> TOPLEVEL. INFERENCE: no code path was found connecting a back press to popup
> teardown, which suggests Back does not close an open `GtkPopover` there — this is
> read from an absence, not an observed behaviour.

**Degradation.** Everything here is press-driven and needs no key release and no
sub-cell precision, so it ports intact. The `#if 0` is the transferable warning: with
no native grab, dismiss on pointer-DOWN outside, never on up or click, and
additionally suppress the dismissal for the very press that opened the overlay. The
`has_pointer` bookkeeping is the substitute for a grab that GTK still needs even
WITH a grab; a one-surface toolkit needs the same "is the pointer inside this
overlay" bit and can compute it directly from its hit list. Android back-as-dismiss
must be added explicitly. With no script the cascade cannot be expressed at all.

### 9. Focus

The four surface kinds are kept sharply distinct, and the distinction is a
[focus scope][concepts] policy per overlay kind rather than a single mechanism.

- **Tooltip.** Never takes focus. Its `GdkPopup` is created with `autohide` `FALSE`
  (`gtk/gtktooltipwindow.c:204`) and it is not in the focus chain at all.
- **Popover, non-autohide.** No initial focus, no containment — `gtk_popover_focus`
  returns `FALSE` when the internal move fails, letting Tab escape into the rest of
  the window.
- **Popover, autohide.** `gtk_popover_show` calls
  `gtk_widget_child_focus(DIR_TAB_FORWARD)` if nothing is focused yet
  (`gtk/gtkpopover.c:1189`), and `gtk_popover_focus` (`:1123`) CYCLES: when the move
  fails it unsets `focus_child` up the chain and restarts the traversal. Containment
  by wrap-around, not a hard trap.
- **Menu.** `GtkPopoverMenu` overrides focus with directional semantics
  (`gtk/gtkpopovermenu.c:462`): Left with an open submenu pops that submenu down and
  refocuses the active item; Left/Right at the end of the chain are eaten unless the
  menu is inside a `GtkPopoverMenuBar`, which uses them to cycle sibling menus;
  Up/Down and Tab cycle.

**Algorithm (cycling containment).** `if (focus_move(dir)) return TRUE;` — if not
autohide, `return FALSE`; take the root focus `p`; if `p` is not inside the popover,
`return TRUE` (a guard against an infinite loop for popovers with no focusable child,
`gtk/gtkpopover.c:1146-1152`); otherwise unset `focus_child` from `p` up to the
popover and retry the move.

The structural fact worth carrying: **keyboard focus is not surface focus**.
`gtk_main_do_event` rewrites every key event to the TOPLEVEL surface
(`rewrite_event_for_toplevel`, `gtk/gtkmain.c:1657`) by walking `surface->parent` to
the root, then targets `gtk_root_get_focus(...)` (`:1603`). The popover's own surface
never needs keyboard focus for its shortcuts to work; `GtkPopover` implements
`GtkShortcutManager` (`gtk/gtkpopover.c:227`) and plugs into the root's shortcut
chain instead.

**Degradation.** This dimension survives a single-surface toolkit well, because GTK
has already reduced it to "one focus pointer owned by the root, plus a per-overlay
scope predicate" — the key-event rewriting is literally the single-surface model
implemented on top of a multi-surface one. With no key release only focus-visible
tracking and mnemonic hiding are lost, both cosmetic. With no script,
`:focus-within` gives containment-free reveal and cycling is impossible. The four
policies — tooltip (none) / popover (optional) / menu (directional) / dialog (trap) —
are worth keeping distinct over one overlay primitive.

### 10. Layering and portals

There is no [top layer][concepts] and no z-index. Layering IS the surface hierarchy.
`gdk_surface_new_popup(parent, autohide)` (`gdk/gdksurface.c:957`) creates a child
surface; the popup keeps `surface->parent` and the parent keeps `surface->children`,
and every backend stacks children above their parent by construction — X11 explicitly
re-stacks each child above the parent whenever the parent moves
(`gdk/x11/gdksurface-x11.c:1913`).

Ownership is DOUBLE. The popover is simultaneously a widget child of its anchor
(`gtk_widget_set_parent`) and a surface child of the anchor's native surface. The
widget tree supplies CSS inheritance, action groups, shortcut scope, accessibility
parent and lifetime; the surface tree supplies stacking and input. The two trees are
kept in sync by hand and the seams are visible:

```c
// gtk/gtkwidget.c:10550-10551
      if (GTK_IS_NATIVE (child))
        continue;
```

`gtk_widget_do_pick` refuses to descend into a `GtkNative` child. A `GtkPopover` is a
widget-tree child of its anchor, yet hit-testing from the parent never reaches it;
each surface is picked from its own root. `gtk_popover_native_layout`
(`gtk/gtkpopover.c:784`) must in turn synthesise a `GskTransform` placing the popover
widget at its resolved surface position relative to the parent, so that
`gtk_widget_compute_point` across the boundary still works. And re-presenting the
overlay tree is a hardcoded type switch:

```c
// gtk/gtklayoutmanager.c:363-378 (allocate_native_children)
      if (GTK_IS_POPOVER (child))
        gtk_popover_present (GTK_POPOVER (child));
      else if (GTK_IS_TEXT_HANDLE (child))
        gtk_text_handle_present (GTK_TEXT_HANDLE (child));
      else if (GTK_IS_TOOLTIP_WINDOW (child))
        gtk_tooltip_window_present (GTK_TOOLTIP_WINDOW (child));
      else if (GTK_IS_NATIVE (child))
        /* warns */
```

Four implementors of `GtkNative` exist and the re-present pass knows three of them by
name.

**Degradation.** This is the dimension that inverts hardest. With one surface there
is no second tree: front-to-back is paint order and the overlay MUST be in the pick
tree, which removes the `GTK_IS_NATIVE` special case and the transform bridging with
it. What is worth keeping is the ownership SHAPE — an overlay is a child of its
anchor in the one tree you have, so lifetime, style scope, action scope and
dismissal cascade all fall out of parenthood — and the public/private split: publish
the placement value and the resolved result, keep the solver internal so it can be
swapped per backend.

### 11. Modality

One boolean, `autohide`, conflates [modality][concepts], light dismiss, focus
containment and grabbing — and it is `CONSTRUCT_ONLY` on the `GdkPopup`
(`gdk/gdkpopup.c:92`), so `gtk_popover_set_autohide` has to UNREALIZE the whole
widget to change it (`gtk/gtkpopover.c:2400`).

Its implementation differs fundamentally per backend:

| Backend                 | What `autohide` actually is                                                                                                                                  |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| X11 / Win32 / macOS     | `gdk_seat_grab(seat, surface)` at present time (`gdk/x11/gdksurface-x11.c:1900`), plus GDK's `check_autohide` predicate                                      |
| Wayland                 | An implicit-grab serial passed to `xdg_popup.grab` (`gdk/wayland/gdkpopup-wayland.c:1007`); the COMPOSITOR owns dismissal and sends `popup_done`             |
| Android                 | A pure software rule: the grabbed child `View` receives ALL motion events, in or out of its input region (`ToplevelActivity.java:216`)                       |
| GTK level, all backends | `gtk_grab_add` (`gtk/gtkpopover.c:1246`) installs a per-`GtkWindowGroup` grab widget that `gtk_main_do_event` uses to redirect events (`gtk/gtkmain.c:1693`) |

**Algorithm (modal delivery).** `grab_widget = window_group.current_grab;` if there is
no grab, or the target is sensitive and a descendant of the grab widget, or the
transient-for chain permits, then `grab_widget = target`; propagate to `grab_widget`.
Non-descendant targets get their events redirected to the grabbing popover, which is
how outside clicks reach the dismissal logic at all.

Passthrough is achieved not by modality but by the input region: a non-arrow
popover's region is the content box inset by the shadow (`gtk/gtkpopover.c:1508`), so
the shadow gutter is click-through; with an arrow, only the triangle plus rounded box
are hit-testable. There is no scrim, no dim, no accessibility modal bit on popovers,
and no background keyboard blocking beyond the grab-widget redirection.

> [!IMPORTANT]
> Wayland enforces a protocol invariant GTK must respect: `can_map_grabbing_popup`
> (`gdk/wayland/gdkpopup-wayland.c:911-924`) refuses to map a grabbing popup whose
> parent is not the current topmost grabbing popup, warning rather than committing a
> protocol error that would kill the client.

**Degradation.** With no native grab, the Android and `gtk_grab_add` paths are the
templates, and both are purely in-process: a grab is (i) a stack of grabbing
overlays, (ii) a rule that events outside the topmost grabber are re-targeted to it,
and (iii) a predicate that turns an outside press into a dismissal. All three are
computable from the hit list of the last painted frame. GTK's own honest limitation
is instructive here: events that never reach the application cannot be handled at
all. The single `autohide` boolean is the part NOT to copy — GTK's own tooltip, text
handle and non-autohide popover each want a different subset of
`{takes focus, light dismiss, blocks background input}`, which is precisely why three
of them refuse to reuse `GtkPopover`.

### 12. Adaptive presentation

GTK4 does very little adaptive presentation, and what exists is owned by three
different layers rather than by one adaptation algorithm.

- **The input layer decides tooltip-or-nothing.** `tooltips_enabled` inspects
  `gdk_device_get_source` and returns `FALSE` for `GDK_SOURCE_TOUCHSCREEN`
  (`gtk/gtktooltip.c:890`). On touch there is no hover tooltip and no long-press
  substitute either: the affordance simply disappears.
- **The widget layer decides menu shape.** `GtkPopoverMenuFlags`
  (`gtk/gtkenums.h:1953`) is either `GTK_POPOVER_MENU_SLIDING` — the DEFAULT, where
  submenus are pages of a `GtkStack` inside ONE popover, animated
  `GTK_STACK_TRANSITION_TYPE_SLIDE_LEFT_RIGHT` with `interpolate-size`
  (`gtk/gtkpopovermenu.c:336`) — or `GTK_POPOVER_MENU_NESTED`, where submenus are
  real child popovers. This is a per-menu property, not a device query.
- **The container layer decides trigger-to-anchor mapping.** `GtkPopoverBin` installs
  BOTH the click gesture and the long-press gesture unconditionally, so touch and
  pointer coexist rather than being switched between.

There is no teaching-tip concept, no compact/regular size class, and no keyboard-driven
relocation of an already-open popover — changing the anchor requires `set_pointing_to`
plus a re-present, which `GtkPopoverBin` does at OPEN time only. Notably the device
type is available at the GDK event, is used for the tooltip decision and for the
cursor-size anchor padding, and never propagates into `GdkPopupLayout`.

**Degradation.** The lesson is the layering, not the features: the presentation
choice sits in the COMPONENT (a menu flag), the availability choice sits in the INPUT
tier (no hover implies no tooltip), and neither sits in the placement value.
`GdkPopupLayout` stays device-agnostic, which is why one solver serves a phone and a
four-monitor desktop. For a target with no hover, GTK's answer — the tooltip does not
exist — is at least honest; installing both gestures unconditionally rather than
branching on device is the pattern that survives a session where the pointer type
changes. Sliding submenus (one surface, a stack of pages) is directly the model a
single-surface toolkit wants, and GTK already ships it as the default.

### 13. Accessibility

This is the weakest dimension, and the finding is largely an ABSENCE.

```text
gtk/gtkenums.h:1381

 * @GTK_ACCESSIBLE_ROLE_TOOLTIP: Unused
```

`GtkTooltipWindow` sets no accessible role; the tooltip surface is never exposed as
an accessible object. Instead the tooltip TEXT is folded into the TRIGGER widget's
accessible name/description computation: `gtk_at_context_get_text_accumulate` step
2.I appends `gtk_widget_get_tooltip_text` (`gtk/gtkatcontext.c:1554`), with a
duplicate check that appends it as the description only if it differs from the name
and vice versa, and `gtk_at_context_get_name` deliberately skips the duplicate check
with the comment that the tooltip should become the name if everything else fails
(`:1646`). The AccessKit backend does the same (`gtk/a11y/gtkaccesskitcontext.c:1723`).

`GtkPopover` sets no accessible role either, so it falls back to
`GTK_ACCESSIBLE_ROLE_GENERIC` (`gtk/gtkwidget.c:2554`); only `GtkPopoverMenu`
declares `GTK_ACCESSIBLE_ROLE_MENU` (`gtk/gtkpopovermenu.c:676`). "Popover" as such
carries no semantics — the semantics live entirely in the component built on it.

WCAG 1.4.13's _persistent_ requirement is met trivially (there is no maximum
duration); _hoverable_ and _dismissable_ are not — the tooltip cannot be hovered
without hiding, and Escape is not wired to tooltips. `keyboard_mode` is a live
parameter of the `::query-tooltip` signal, but GTK4 passes `FALSE` at the single call
site (`gtk/gtktooltip.c:543`) and nothing in the tree passes `TRUE`, so GTK3's
keyboard-triggered tooltips are effectively dead. `gtk_tooltip_set_custom` (`:301`)
permits arbitrary interactive widgets inside a surface that is unreachable by
keyboard and invisible to assistive technologies, and nothing prevents it.

AT-SPI (`gtkatspicontext.c`) and AccessKit (`gtkaccesskitcontext.c`) both consume the
same `GtkATContext`, so the primitive is backend-neutral by construction.

**Degradation.** Nothing here belongs to the PRIMITIVE; the role, the
expanded/haspopup state on the trigger, and the described-by relation belong to the
semantic COMPONENT. A terminal grid can honestly expose exactly what GTK exposes: the
overlay's text as part of the anchor's accessible description, rather than pretending
the overlay is an object. That maps onto a TUI, where the only reader is a screen
reader consuming the terminal, and onto static HTML as `aria-describedby` on the
trigger. See [`./aria-apg.md`][apg] for the normative contract GTK does not
implement. The single portable rule the source supports: an overlay that cannot be
reached by keyboard must never contain anything interactive.

### 14. Animation

**Not applicable — and the absence is the finding.** `GtkPopover`,
`GtkTooltipWindow` and `GtkTooltip` contain no transition, no enter/exit, no spring,
no [transform origin][concepts] and no reduced-motion check; a grep for `transition`
and `animation` across all three files returns nothing. The Adwaita stylesheet gives
`popover.background` only static background, border and box-shadow
(`gtk/theme/Default/_common.scss:1948`), and gives `tooltip` padding and a border
radius while explicitly zeroing `box-shadow` (`:4009`). Reduced motion exists
globally as `GtkSettings:gtk-enable-animations` (`gtk/gtksettings.c:560`), and
nothing in the overlay path reads it.

GTK does publish the geometry that a placement-aware transform origin would need —
`gdk_popup_get_rect_anchor` / `get_surface_anchor` return the RESOLVED gravities
after flipping, `get_position_x` / `get_position_y` the resolved origin, and the
`gdkpopuplayout.c:54-61` doc comment quoted earlier explicitly names adjusting the
rendering as the use case. The only consumer in the tree is the arrow.

The one animation in the neighbourhood is inside the content: `GtkPopoverMenu`'s
sliding submenus use a `GtkStack` slide transition with `interpolate-size`
(`gtk/gtkpopovermenu.c:338`), which resizes the popover and therefore re-triggers
`present_popup` on every frame — and `gtk_popover_native_layout`'s `is_acceptable_size`
veto can pop the menu DOWN mid-animation if a frame's granted size dips below the
minimum.

**Degradation.** A mature, heavily-used desktop overlay stack ships with no overlay
animation at all and is not considered broken; that is licence to skip enter/exit
entirely on a cell target. What is worth copying is that GTK publishes the RESOLVED
side and origin as queryable data even though it only uses them for an arrow: a
display list carrying resolved-side metadata costs two bytes and lets a GPU backend
add motion later without the placement layer knowing.

### 15. State architecture

Three architectures coexist in one stack.

1. **The placement layer is pure value semantics.** `GdkPopupLayout` is an
   immutable-in-practice bag of ten scalars with copy and equal; the solver is a pure
   function of `(layout, size, shadow, bounds)` returning a rect plus two resolved
   gravities. The only test found in the extracted `testsuite/` tree exercises exactly
   that surface — `testsuite/gdk/popuplayout.c` covers copy, equal and every
   setter/getter.
2. **`GtkPopover` is an imperative controller with cached derived state.** `priv`
   holds `layout` (the request) and `final_rect` / `final_position` (the resolution),
   and `update_popover_layout` (`gtk/gtkpopover.c:390`) diffs the new resolved rect
   and side against the cached ones before queueing an allocate and dropping the
   cached arrow render node. There is no reducer and no explicit state enum:
   visibility IS the state, carried by the `GtkWidget` visible flag, and
   `popup`/`popdown` are `set_visible`. Keeping the request and the resolution in
   different fields is the load-bearing part, and it is not unique to GTK — see
   [`./neovim-floats.md`][nvim] and [`./tmux-popup.md`][tmux] for the same split.
3. **The Wayland backend holds the only real finite state machine.** `PopupState`
   `{IDLE, WAITING_FOR_CONFIGURE, WAITING_FOR_FRAME}` (`gdk/wayland/gdkpopup-wayland.c:214`)
   with asserts on the legal transitions and a reposition token correlating
   compositor replies.

Everything is uncontrolled: the popover owns its own visibility and emits `::closed`.
`GtkTooltip` is the outlier — a per-display singleton stored as GObject qdata on the
`GdkDisplay` (`gtk/gtktooltip.c:1006`) with three timer ids and three bitfields,
created lazily on first motion and destroyed when browse mode decays.
`GtkPopoverMenu` keeps a weak pointer to the active item (`gtk/gtkpopovermenu.c:262`)
and a raw pointer to the open submenu, cleaned up from focus-out, unmap and cascade;
`NEWS` records issue #4529, "Popover cannot be closed after opening a child popover",
at that seam.

**Degradation.** Layer 1 survives a value-semantics `@safe pure nothrow @nogc` port
unchanged — a struct of integers with `opEquals` and a pure function returning a
small result struct. Layer 2 survives as "the view returns a desired layout, the
frame stores the resolved one, and the next frame compares", which is what an
immediate-mode painter wants anyway. Layer 3 exists only because of an asynchronous
compositor and disappears with one surface. The tooltip singleton is the part to
REJECT: global mutable state keyed off a display object is what makes the timing
machine untestable.

### 16. Shared infrastructure

The factoring is clean at the bottom and absent at the top.

**Truly shared:** (a) `GdkPopupLayout` plus `gdk_popup_present` plus the
resolved-geometry getters, used verbatim by `GtkPopover`, `GtkTooltipWindow` and
`GtkTextHandle`; (b) `GtkNative` — `get_surface` / `get_renderer` /
`get_surface_transform` / `layout` (`gtk/gtknativeprivate.h:12`), the four-method
interface that makes something an overlay surface, implemented by `GtkWindow`,
`GtkPopover`, `GtkTooltipWindow` and `GtkTextHandle` alike; (c) the autohide and grab
machinery in GDK; (d) the surface-transform observer.

**Deliberately not shared:** `GtkTooltipWindow` is NOT a `GtkPopover`. It
re-implements realize/map/present/relayout — including its own `create_popup_layout`
(`gtk/gtktooltipwindow.c:109`) — rather than subclassing, because it wants no arrow,
no autohide, no focus, no shadow compensation and a fixed gravity pair.
`GtkTextHandle` likewise builds its own `GdkPopupLayout` with NO anchor hints at all
(`gtk/gtktexthandle.c:245`): it must pin exactly under the caret, and flipping or
sliding a text handle would be wrong. That the hint mask is a first-class field is
precisely what lets three very different overlays share one solver.

The composition surfaces are all separate widgets — `GtkPopoverMenu`,
`GtkPopoverMenuBar`, `GtkMenuButton`, `GtkPopoverBin`, plus `GtkDropDown`,
`GtkEmojiChooser`, `GtkColorSwatch` and `GtkScaleButton`, each calling
`gtk_popover_present` from its own `size_allocate`. The glue that betrays the missing
abstraction is the `allocate_native_children` type switch quoted in dimension 10.

**Degradation.** The transferable core is `{value: a comparable placement struct}` +
`{operation: present(size, layout) -> resolved rect and resolved gravities}` +
`{interface: a thing that can be presented at a resolved rect}` — with the four
shadow widths deleted, since dropping them collapses the visual-box-versus-surface-box
distinction that otherwise threads through measure, allocate, arrow and input region.
What must stay APART, on GTK's own evidence, is the four policies: tooltip (no focus,
no dismiss stack, singleton timing, non-interactive, contributes to the anchor's
accessible description), plain popover (optional focus containment, arrow, Escape),
menu (directional focus, cascade dismissal, hover debounce), and caret handle (empty
hint mask meaning "pin exactly"). GTK demonstrates that these four can share a
geometry value while refusing to share a state machine. See
[`./proposal.md`][proposal] for how that decomposition lands on `sparkles:ui`, and
[`../../specs/ui/state-machines.md`][spec-stm] for the machines it would sit beside.

---

## Strengths

- `GdkPopupLayout` is a genuinely inert placement description — ten scalars, copy and
  equal, zero behavior — and the same value is executed by an out-of-process
  compositor, an in-process integer solver, and an Android `ViewGroup` without
  change.
- The solver is roughly 130 lines of pure integer arithmetic with no allocation, no
  floats and no dependency on the windowing system.
- Nine-by-nine gravity combinations reduce to two signs per axis, so start / center /
  end alignment is a multiplication rather than a switch.
- Flip is decided by comparing BADNESS, not by a naive fit test, so a popup never
  flips into a strictly worse position.
- The resolved side and origin are published back to the toolkit, which is what lets
  the arrow track slide and flip without the placement layer knowing what an arrow
  is.
- One primitive serves four genuinely different overlays by varying only the hint
  mask and the autohide flag — including `GtkTextHandle`, which sets NO hints at all
  to mean "pin exactly".
- The Android backend is a working existence proof that the whole model runs with no
  OS popup: bounds become the parent surface rect, the grab becomes "this child view
  gets all motion events", and the IME inset is subtracted from the parent size so it
  is an input to placement rather than something to discover.
- Keyboard events are rewritten to the toplevel and routed through the root's focus
  and shortcut chain regardless of which surface they arrived on, so the
  multi-surface stack already behaves like a single-surface one for keys.
- Light dismiss is deliberately press-only, with an in-tree comment explaining
  exactly why the paired release must be excluded.
- The pointer-opened versus keyboard-opened anchor split in `GtkPopoverBin` — a point
  rect at the click versus the whole-widget rect for the action — costs one nullable
  field.
- Slide clamps the far edge before the near edge, so an over-large popup pins to its
  start rather than scrolling its start off-screen.
- Resize hints are requested only when the widget can actually shrink in that
  orientation, and an unacceptable granted size pops the popover down rather than
  rendering broken content.

## Weaknesses

- The placement solver is effectively untested in the tree that was read:
  `testsuite/gdk/popuplayout.c` exercises setters, getters, copy and equal, and
  nothing found there drives `maybe_flip_position`, the slide clamps or the resize
  clamps. (Scope: this is from grepping the extracted `testsuite/` tree for
  `GDK_ANCHOR`, `popup_layout` and `gtk_popover`; `tests/` and the reftest corpus
  were not audited.)
- On Wayland the resolved constraint adjustment must be INFERRED by recomputing
  candidate rectangles and comparing coordinates, and the inference is ambiguous —
  equal coordinates do not prove a flip, which is why `GtkPopover` adds a second
  guard requiring both gravities to have mirrored.
- No preferred-placement list and no cross-axis flip: the fallback space is exactly
  one mirror per axis, so "bottom, else top, else right" is inexpressible.
- `autohide` conflates modality, light dismiss, initial focus and focus containment
  into one construct-only boolean, and changing it unrealizes the widget.
- No animation of any kind in the overlay path, and the geometry metadata that would
  enable it is published but consumed only by the arrow.
- Accessibility is essentially unimplemented for the primitive: `GtkPopover` has no
  role, `GTK_ACCESSIBLE_ROLE_TOOLTIP` is documented "Unused", keyboard-triggered
  tooltips are dead, and WCAG 1.4.13's hoverable and dismissable requirements are not
  met.
- Tooltip state is a per-display singleton stored as GObject qdata with three raw
  timer ids, created lazily and destroyed on browse-mode decay — global mutable state
  that no test in the read tree drives.
- Submenu bookkeeping is redundant and cleaned up from four directions (focus-out,
  unmap, cascade, weak pointers), which is where `NEWS` #4529 sits.
- The overlay re-present pass is a hardcoded type switch over exactly three concrete
  classes with a warning for anything else, despite four implementors of `GtkNative`.
- `gtk_tooltip_set_custom` permits arbitrary interactive widgets inside a surface that
  is unreachable by keyboard and invisible to assistive technologies.
- The Wayland reposition fallback (unmap plus remap for compositors older than
  `xdg_popup` v3) silently does nothing when any child popup is mapped, leaving the
  popup mis-positioned with no diagnostic.
- RTL is handled only for `GTK_POS_TOP` / `GTK_POS_BOTTOM`.

---

## Key design decisions and trade-offs

| Decision                                                                                                                     | Rationale                                                                                                                                                                                                                                          | Trade-off                                                                                                                                                                                                                                                                                                    |
| ---------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Make the placement description a refcounted plain-data VALUE with copy/equal and no behavior, and keep the solver private.   | The same description can be executed by a Wayland compositor, by GDK's integer solver on the other backends, or by an Android `ViewGroup`, with none of the three knowing about the others; `equal()` then buys free deduplication of repositions. | The value can express combinations no backend honours identically, and because the solver is private a caller cannot ask "where would this land?" without presenting. The resolved result must be read back through a second API, and on Wayland has to be inferred rather than reported.                    |
| Model the fallback space as a six-bit mask with fixed precedence rather than an ordered list of candidate placements.        | Constant-size, comparable, trivially marshalled onto `xdg_positioner`'s `constraint_adjustment`, and solvable in O(1) with no allocation. It also lets three very different overlays share one solver by varying only the mask.                    | No preferred-placement list, so "try bottom, then top, then right" is inexpressible, and the fallback is exactly one mirror per axis. Cross-axis flipping is impossible, which is why a bottom-anchored popover can slide halfway off its anchor but never move to the side.                                 |
| Give every popover its own `GdkSurface` and make `GtkPopover` both a widget child of its anchor and a `GtkNative`.           | One object gets compositor-level escape from all clipping and stacking AND widget-tree CSS inheritance, action groups, shortcut scope, accessibility parentage and lifetime — removing any need for a portal, a top layer or a z-index concept.    | Two parallel trees kept consistent by hand: `gtk_widget_do_pick` must refuse to descend into `GtkNative` children, `gtk_popover_native_layout` must synthesise a transform for cross-boundary coordinate maths, and `GtkLayoutManager` needs a hardcoded type switch to re-present the three known overlays. |
| Collapse modality, light dismiss, initial focus and focus containment into one construct-only boolean.                       | One flag covers the common desktop case and maps directly onto the one thing the windowing systems actually offer — a seat grab or `xdg_popup.grab`.                                                                                               | Changing it requires unrealizing the widget. And it is too coarse for GTK's own overlays: the tooltip window, the text handle and the sliding submenu each want a different subset, so each hand-rolls its own presentation instead of reusing `GtkPopover`.                                                 |
| Substitute an 80 ms motion-restarted debounce for a safe polygon or menu-aim geometry.                                       | Costs one timer id and no geometry, works at any pointer resolution, and gets the important case right: a pointer travelling toward an open submenu keeps moving, so the timer never elapses on intervening items.                                 | A slow, deliberate diagonal traverse still switches submenus; pausing inside an item with no submenu closes the open one after 80 ms; and `OPEN_TIMEOUT` is a compile-time `#define`, so it cannot be tuned per menu.                                                                                        |
| Do not represent the tooltip in the accessibility tree at all; fold its text into the trigger's accessible name/description. | A hover-only, keyboard-unreachable surface that assistive technologies cannot navigate to is better exposed as a property of the thing it describes — and it then works identically over AT-SPI and AccessKit with zero per-backend code.          | `gtk_tooltip_set_custom` still allows arbitrary widgets in a tooltip, and those become completely unreachable; `GTK_ACCESSIBLE_ROLE_TOOLTIP` is left in the public enum documented "Unused"; and WCAG 1.4.13's hoverable/dismissable requirements are not met.                                               |
| Constrain the VISUAL box: subtract the CSS box-shadow extents before solving and add them back afterwards.                   | A popup whose buffer includes a 30-pixel shadow gutter would otherwise be pushed 30 pixels from the screen edge and flip prematurely; carrying the four widths in the value keeps the compositor honest too, via `xdg` window geometry.            | Four extra fields, a shadow term threaded through `measure()`, `size_allocate()`, the arrow's tip and base offsets and the input region, plus a subtle rule that the input region must exclude the gutter or clicks in the shadow are swallowed. All of it is pure cost for a toolkit that has no shadows.   |
| Publish the resolved gravities and origin, and derive the arrow from them rather than from the request.                      | Slide and flip are then absorbed by the arrow moving, and the placement layer never learns what an arrow is.                                                                                                                                       | The toolkit must re-derive the semantic result from the geometry, which on Wayland means recomputing candidate rectangles and guarding an ambiguous equality test.                                                                                                                                           |

---

## Sources

All line references are to the pinned revision
`817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671` (GTK 4.23.1).

- [`gdk/gdkpopuplayout.c`][src-popuplayout-c] — the placement value: the struct
  (`:64-79`), `copy` (`:159`), `equal` (`:191`), and the doc comment on reading the
  result back (`:54-61`).
- [`gdk/gdkpopuplayout.h`][src-popuplayout-h] — `GdkAnchorHints` and the
  flip-over-slide-over-resize precedence prose (`:44-68`).
- [`gdk/gdksurface.c`][src-gdksurface] — the sign extraction (`:190-236`),
  `maybe_flip_position` (`:238-288`), `gdk_surface_layout_popup_helper` (`:313-444`),
  the monitor pick (`:156`), `gdk_surface_new_popup` (`:957`), and `check_autohide`
  with the `#if 0` release block (`:2736-2797`).
- [`gdk/gdksurfaceprivate.h`][src-gdksurfacepriv] — the solver's private declaration
  (`:186`).
- [`gdk/gdkpopup.c`][src-gdkpopup] — the `GdkPopup` interface and the
  construct-only `autohide` property.
- [`gdk/wayland/gdkpopup-wayland.c`][src-wl-popup] — the gravity/anchor tables
  (`:65-193`), flip inference by candidate recomputation (`:657-739`),
  `create_dynamic_positioner` (`:742-909`), `can_map_grabbing_popup` (`:911-924`),
  `xdg_popup.grab` (`:1007`), the remap fallback guard (`:1127`), and the
  `gdk_popup_layout_equal` dedup (`:1375`).
- [`gdk/x11/gdksurface-x11.c`][src-x11] — the X11 layout entry point (`:1818`), the
  seat grab (`:1900`) and popup re-stacking (`:1913`).
- [`gdk/android/gdkandroidpopup.c`][src-android-popup] — bounds as the parent surface
  rect (`:57`) and the scale multiply (`:80`).
- [`gdk/android/glue/java/org/gtk/android/ToplevelActivity.java`][src-android-java] —
  the software grab (`:216`), `onMeasure` (`:361-368`) and `onApplyWindowInsets`
  (`:394-397`).
- [`gtk/gtkpopover.c`][src-gtkpopover] — the tail constants (`:162-163`),
  `did_flip_horizontally` (`:354-388`), `update_popover_layout` (`:390`),
  `compute_surface_pointing_to` (`:464`), `create_popup_layout` (`:504`), the four
  `anchor_hints` assignments (`:546`, `:571`, `:596`, `:621`), the resize hints
  (`:682-685`), `is_acceptable_size` (`:748-756`), the native-layout transform
  (`:784`), Escape (`:933`), `gtk_popover_focus` (`:1123-1152`), the transform
  callback (`:1214`), `gtk_grab_add` (`:1246`), `gtk_popover_get_gap_coords`
  (`:1306-1412`), `gtk_popover_update_shape` (`:1458-1533`), `get_minimal_size`
  (`:1536`) and `cascade_popdown` (`:2441-2469`).
- [`gtk/gtktooltip.c`][src-gtktooltip] — the three timing constants (`:71-73`),
  `gtk_tooltip_set_custom` (`:301`), `set_tip_area` (`:331`), the requery walk
  (`:519-578`), `gtk_tooltip_position` (`:580-688`) including the cursor-size padding
  (`:617-633`) and the tall-anchor substitution (`:658-666`), `tooltips_enabled`
  (`:852-895`) and the singleton qdata (`:1006`).
- [`gtk/gtkmodelbutton.c`][src-modelbutton] — `OPEN_TIMEOUT` (`:1423`), `start_open`
  (`:1426-1437`), and the motion handler that restarts it (`:1479`).
- [`gtk/gtkpopoverbin.c`][src-popoverbin] — the context-menu container (since 4.22):
  `popup_at_position` (`:123`), `pressed_cb` (`:158`), `long_pressed_cb` (`:180`) and
  the keyboard path that clears `pointing_to` (`:695`).
- [`gtk/gtkpopovermenu.c`][src-popovermenu] — the active-item weak pointer (`:262`),
  focus-out (`:286`), leave (`:309`), the stack transition (`:336-338`), directional
  focus (`:462`) and `GTK_ACCESSIBLE_ROLE_MENU` (`:676`).
- [`gtk/gtkwidget.c`][src-gtkwidget] — the default accessible role (`:2554`),
  `sync_widget_surface_transform` (`:3334`) and the `GTK_IS_NATIVE` pick skip
  (`:10550`).
- [`gtk/gtkmain.c`][src-gtkmain] — key routing to the root focus (`:1603`),
  `rewrite_event_for_toplevel` (`:1657`), grab-widget redirection (`:1693`) and the
  unconditional tooltip pump (`:1788`).
- [`gtk/gtklayoutmanager.c`][src-layoutmanager] — `allocate_native_children`, the
  hardcoded three-type overlay re-present switch (`:363-378`).
- [`gtk/gtkenums.h`][src-gtkenums] — `GTK_ACCESSIBLE_ROLE_TOOLTIP: Unused` (`:1381`)
  and `GtkPopoverMenuFlags` (`:1953`).
- [`gtk/gtkatcontext.c`][src-atcontext] — the accessible-name algorithm's tooltip
  step (`:1554`, `:1646`).
- [`gtk/gtktooltipwindow.c`][src-tooltipwindow] and
  [`gtk/gtktexthandle.c`][src-texthandle] — the two overlays that build their own
  layout rather than reusing `GtkPopover`.
- Catalog context: the shared vocabulary in [`./concepts.md`][concepts], the umbrella
  [`./index.md`][index], the capstone [`./comparison.md`][comparison], the
  edge-case register in [`./features-people-forget.md`][forget], the protocol this
  value re-expresses in [`./xdg-positioner.md`][xdg], the in-canvas peers
  [`./avalonia.md`][avalonia], [`./qt-quick-controls.md`][qtquick] and
  [`./slint.md`][slint], and the cell-grid subjects
  [`./neovim-floats.md`][nvim] and [`./tmux-popup.md`][tmux].
- Adjacent sparkles material: what the toolkit ships today in
  [`./sparkles-baseline.md`][baseline], the [window-system integration][wsi] and
  [platform UI guidelines][pug] research trees, and the toolkit's own
  [UI spec index][spec-ui], [input spec][spec-input] and
  [backends spec][spec-backends].

<!-- References -->

[repo]: https://github.com/GNOME/gtk
[repo-pin]: https://github.com/GNOME/gtk/tree/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671
[gdk-docs]: https://docs.gtk.org/gdk4/struct.PopupLayout.html
[gtk-docs]: https://docs.gtk.org/gtk4/class.Popover.html
[src-popuplayout-c]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gdk/gdkpopuplayout.c#L64
[src-popuplayout-h]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gdk/gdkpopuplayout.h#L44
[src-gdksurface]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gdk/gdksurface.c#L238
[src-gdksurfacepriv]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gdk/gdksurfaceprivate.h#L186
[src-gdkpopup]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gdk/gdkpopup.c#L38
[src-wl-popup]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gdk/wayland/gdkpopup-wayland.c#L657
[src-x11]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gdk/x11/gdksurface-x11.c#L1818
[src-android-popup]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gdk/android/gdkandroidpopup.c#L57
[src-android-java]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gdk/android/glue/java/org/gtk/android/ToplevelActivity.java#L394
[src-gtkpopover]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gtk/gtkpopover.c#L390
[src-gtktooltip]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gtk/gtktooltip.c#L71
[src-modelbutton]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gtk/gtkmodelbutton.c#L1423
[src-popoverbin]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gtk/gtkpopoverbin.c#L158
[src-popovermenu]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gtk/gtkpopovermenu.c#L462
[src-gtkwidget]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gtk/gtkwidget.c#L10550
[src-gtkmain]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gtk/gtkmain.c#L1657
[src-layoutmanager]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gtk/gtklayoutmanager.c#L363
[src-gtkenums]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gtk/gtkenums.h#L1381
[src-atcontext]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gtk/gtkatcontext.c#L1554
[src-tooltipwindow]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gtk/gtktooltipwindow.c#L109
[src-texthandle]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gtk/gtktexthandle.c#L245
[index]: ./index.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[forget]: ./features-people-forget.md
[proposal]: ./proposal.md
[baseline]: ./sparkles-baseline.md
[xdg]: ./xdg-positioner.md
[avalonia]: ./avalonia.md
[qtquick]: ./qt-quick-controls.md
[slint]: ./slint.md
[nvim]: ./neovim-floats.md
[tmux]: ./tmux-popup.md
[apg]: ./aria-apg.md
[wsi]: ../window-system-integration/index.md
[pug]: ../platform-ui-guidelines/index.md
[spec-ui]: ../../specs/ui/index.md
[spec-input]: ../../specs/ui/input.md
[spec-backends]: ../../specs/ui/backends.md
[spec-stm]: ../../specs/ui/state-machines.md
