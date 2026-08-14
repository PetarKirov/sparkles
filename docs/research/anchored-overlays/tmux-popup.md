# tmux `display-popup` / `display-menu` (C / terminal multiplexer)

tmux paints every overlay into one cell grid it already owns — no OS surface, no compositor, no z-buffer, only integer columns and rows and a byte stream to a terminal — and at the revision read it holds three successive generations of that idea side by side, together with its maintainer's written verdict on the oldest of them.

| Field         | Value                                                                                              |
| ------------- | -------------------------------------------------------------------------------------------------- |
| Language      | C                                                                                                  |
| License       | ISC                                                                                                |
| Repository    | [`tmux/tmux`][repo]                                                                                |
| Documentation | [`tmux.1`][man-pos] (the shipped manual page, read at the same revision as the source)             |
| Category      | Terminal / cell grid                                                                               |
| Surface model | in-canvas — one terminal cell grid per client; every overlay is cells in that grid                 |
| Revision read | `851c5a933d4838c32ad06c248b2ba975d106149c` (`configure.ac:3` declares `AC_INIT([tmux], next-3.8)`) |

> [!NOTE]
> This is a source reading, not a docs reading, and it was not built or run. Behavioural
> statements below come from the C source at the pinned revision plus the shipped
> `regress/*.sh` scripts and their golden `.result` files, which were read but not executed.

## Overview

### What it solves

tmux needs three different anchored surfaces on a substrate that offers none of the
machinery every windowing toolkit assumes. `display-popup` opens a bordered box hosting a
real PTY child, movable and resizable with the mouse, in whole cells. `display-menu` opens
a keyboard- and mouse-driven item list positioned relative to a pane, the mouse, the status
line or the previous menu. `new-pane` with `-F`/`-O` creates floating and modal panes —
ordinary panes with a z-order, general per-scanline occlusion, cascade placement and a
thirteen-name position vocabulary. All three resolve to the same primitive question: which
cells does this rectangle own, and who gets the next key.

The three are not variations of one mechanism. They are three _generations_ of the same
idea, and the codebase currently contains all three:

1. **Client-level overlay** (`popup.c`) — six function pointers on `struct client`
   (`overlay_check` / `overlay_mode` / `overlay_draw` / `overlay_key` / `overlay_free` /
   `overlay_resize`) that intercept drawing, cursor placement and input ahead of everything
   else. Exactly one slot per client.
2. **Window-owned scene node** (`menu.c`) — `display-menu` used to be an overlay and was
   moved by commit [`ad6832e6`][c-menus] to be owned by the window and drawn as one more
   span type inside the cached redraw scene, so a menu now appears on every attached client.
3. **Z-ordered floating panes** (`window.c`, `window-visible.c`, `cmd-join-pane.c`) —
   many surfaces, one `w->z_index` list, general occlusion, and a modal variant that pins
   the top of the stack.

### Design philosophy

The direction of travel is stated by the maintainer, not inferred. Commit
[`1a02c995`][c-panes], which deleted `cmd-display-panes.c` and turned `display-panes` into a
window mode, says:

> Convert display-panes away from an overlay and into a mode. This is another step on the
> road of getting rid of overlays altogether (they are full of special cases; popups and
> menus are to go also eventually).

The replacement is a cached, typed display list, described in the file comment of
`screen-redraw.c:38-43` — arrived at independently of any toolkit vocabulary, and describing
the same build/paint split `sparkles:ui` uses:

> A scene is made from spans. A span is a horizontal run of cells on one visible line that
> can be drawn in the same way. Each span has a type … but does not include items such as
> the style and content - those are determined when it is drawn.

[Placement][concepts] is not a constraint solver. An `-x` / `-y` expression, written in a
small algebra of named integer cell coordinates, is expanded through tmux's general format
engine, converted with `strtol`, and clamped. There is no flip, no candidate list, no
arrow, no animation, no delay, no [safe polygon][concepts]. What tmux does have is a
rigorously integer, backend-free geometry model, and a no-[grab][concepts] input answer: the
_terminal's_ mouse-reporting mode is switched on for the surface's lifetime, so motion is
reported for the whole screen and the origin of a drag is enough to route it.

## How it works

**The resolver.** `cmd_display_menu_get_popup_pos` (`cmd-display-menu.c:95`) builds a
`format_tree` populated with roughly seventeen named integer cell coordinates —
`popup_mouse_x`/`_y`, `popup_mouse_centre_x`/`_y`, `popup_mouse_top`/`_bottom`,
`popup_centre_x`/`_y`, `popup_pane_top`/`_bottom`/`_left`/`_right`, `popup_status_line_y`,
`popup_window_status_line_x`/`_y`, `popup_last_x`/`_y`, `popup_width`, `popup_height` —
then expands the user's string against it. The single-letter position words are literally
aliases that rewrite to those variables (`cmd-display-menu.c:236-248` for `-x`,
`:260-272` for `-y`):

```text
-x C -> #{popup_centre_x}     -y C -> #{popup_centre_y}
-x R -> #{popup_pane_right}   -y P -> #{popup_pane_bottom}
-x P -> #{popup_pane_left}    -y M -> #{popup_mouse_top}
-x M -> #{popup_mouse_centre_x}
-x L -> #{popup_last_x}       -y L -> #{popup_last_y}
-x W -> #{popup_window_status_line_x}
                              -y S -> #{popup_status_line_y}
```

Because the expression goes through `format_expand`, arbitrary arithmetic is legal
placement: `-x '#{e|-:#{popup_pane_right},4}'` is a well-formed anchor expression. The
result is one `long`; failure is silent, because an unparsable string `strtol`s to `0`.

**The one asymmetry.** `-x` names the LEFT edge of the surface; `-y` names the BOTTOM edge —
the row one past its last. Every vertical variable is therefore authored as a bottom
(`popup_pane_bottom = wp->yoff + wp->sy`, `popup_mouse_top = mouse_y + h`,
`popup_last_y = menu_last_py + h`) and one subtraction at `cmd-display-menu.c:274-277`
converts all of them at once:

```c
p = format_expand(ft, yp);
n = strtol(p, NULL, 10);
if (n < h)
        n = 0;
else
        n -= h;
if (n + h >= tty->sy)
        n = tty->sy - h;
else if (n < 0)
        n = 0;
```

> [!IMPORTANT]
> This convention is documented nowhere in `tmux.1`. The only statement of it in the tree is
> a comment in a regression test, `regress/menu-mouse.sh:57-59`: "`-y` is the bottom of the
> menu, so with four menu lines this puts the menu at window y=3."

**The scene.** `redraw_build_cells` (`screen-redraw.c:936`) fills an `sx * sy` scratch array
of typed cells: panes back-to-front by walking `w->z_index` with `TAILQ_FOREACH_REVERSE`,
then a two-pane colour pass, then the menu marked last (`redraw_mark_menu`,
`screen-redraw.c:849`) — so "above" is expressed purely as "written later".
`redraw_make_scene` (`:969`) then run-length-joins horizontally adjacent cells whose
payloads compare equal under `redraw_compare_data` (`:877`) into spans, bucketed per line by
span type. The scene is cached on the client and invalidated by a monotonic
`w->redraw_scene_generation` plus four geometry keys, compared in `redraw_get_scene`
(`:1079`). The client overlay is not part of the scene: it is drawn last, after everything
else, and everything below queries it through `overlay_check` before writing a cell.

## The analysis spine

### 1. Anchor model

There is no persistent anchor object anywhere in the tree. An anchor is an expression in the
placement value language, evaluated exactly once at open time into a plain
`(u_int px, u_int py)` and then discarded; only `(x, y, w, h)` survive on the surface. Three
consequences follow. (a) An anchor is a comparable value — two unsigned integers — with no
handle, no lifetime and no observer. (b) The trigger and the [anchor rect][concepts] are
already decoupled: `-c target-client` selects the SURFACE while `-t target-pane` supplies the
anchor GEOMETRY, and `cmdq_get_event(item)->m` supplies the pointer position, so a popup can
be anchored to a pane on one client and displayed on another. (c) There is no anchor
tracking of any kind — if the pane is resized or moved after the popup opens, the popup does
not follow. The only post-open geometry updates are re-clamps against the _surface_
(`popup_resize_cb`, `menu_resize`).

A [virtual anchor][concepts] exists in two forms: the mouse position (a point, promoted to a
rect only in the sense that `popup_mouse_top` already adds `h`), and a _detached_ anchor —
`w->menu_last_px` / `w->menu_last_py`, two integers cached on the window in `menu_display`
(`menu.c:602-603`) before the previous menu is torn down, which is how `-xL -yL` reopens a
replacement menu in exactly the previous menu's spot. Floating panes carry their own anchor
as `struct layout_geometry { u_int sx, sy; int xoff, yoff; }` (`tmux.h:1560`); `xoff`/`yoff`
are SIGNED, so a pane can be positioned partly off-window and clipped.

```text
resolveAnchor(spec, axis, ctx) -> int
    ft   = { ~17 named cell coords: mouse / pane / status / last / centre }
    expr = (spec is one of C R P M L W S) ? alias[spec] : spec
    n    = strtol(format_expand(ft, expr))      // unparsable -> 0, silently
    if axis == Y: n = (n < h) ? 0 : n - h       // the value names the row BELOW
    return clamp(n, 0, surfaceExtent - size)
```

**Where it lives.** `cmd-display-menu.c:95-289` (popup, in client/tty coordinates) and
`:292-467` (menu, in window coordinates); `format.c` supplies the expansion;
`popup.c:638-646` and `menu.c:636-637` store the resolved integers.

**Degradation.** Nothing in this dimension needs an OS surface, hover, script, sub-cell
precision or a key release — it is integer arithmetic over values the host already knows,
and it resolves at emit time as happily as per frame. The only thing an absent OS surface
costs is the multi-monitor / work-area notion, which tmux never had.

### 2. Placement model

Placement is one expression plus clamping: no preferred list, no fallback ordering, no auto
placement, no [flip][concepts], no [gravity][concepts] value. The vocabulary is the
interesting artifact, and it comes in three layers.

- **Seven position words** for popups and menus (`tmux.1:8185-8193`): `C` centre, `R` right
  side (`-x` only), `P` pane (bottom-left of the pane), `M` mouse, `L` last menu, `W` the
  window's cell in the status line, `S` the line above/below the status line (`-y` only).
- **Any format expression**, evaluated against the same variables the words expand to.
- **Thirteen named positions for floating panes** in `cmd_join_pane_place`
  (`cmd-join-pane.c:68`): `top-left` … `bottom-right`, plus the quarter points
  `top-left-centre` / `top-right-centre` / `bottom-left-centre` / `bottom-right-centre`
  (`wx/4 - px/2` and `3*wx/4 - px/2`), plus six pure z-order verbs (`front`, `back`,
  `forward`, `backward`, `forward-loop`, `backward-loop`), with American spellings aliased.

[Constraint adjustment][concepts] is pure [slide][concepts], never flip and never
[resize][concepts]: `if (n + w >= tty->sx) n = tty->sx - w; else if (n < 0) n = 0;`. The
oversize policy differs between the two surfaces, twenty lines apart in one file. A popup
refuses (`cmd-display-menu.c:118-120`):

```c
/* If the popup is too big, stop now. */
if (w > tty->sx || h > tty->sy)
        return (0);
```

A menu instead clamps to `0` and lets the scene clip it (`menu.c:592-601`), and
`regress/screen-redraw-menus.sh:126` asserts exactly that: "Menu wider than the window: it
should be accepted and clipped by the scene."

The two surfaces also live in different coordinate spaces. Popups are placed in client/tty
coordinates and must compensate for status lines by hand (`status_at_line(tc)`, `+lines`,
`tty->sy - lines`); menus are placed in window coordinates and receive the status offset and
horizontal scroll (`tty_window_offset`) later, from the scene. Viewport insets are exactly
the status lines, and they are an INPUT (`popup_status_line_y`,
`popup_window_status_line_y`, `status_line_size`), never discovered by the placer. Menus are
clamped three independent times: in `cmd_display_menu_get_menu_pos`, again in
`menu_display`, and again in `menu_resize` on every window resize. There is no RTL handling,
no writing modes, no multi-monitor, no safe-area and no IME avoidance.

```text
place(specX, specY, w, h, surface):
    x       = clamp(eval(specX), 0, surface.sx - w)     // left edge
    yBottom = eval(specY)
    y       = (yBottom < h) ? 0 : yBottom - h           // bottom edge -> top edge
    y       = clamp(y, 0, surface.sy - h)
oversize: popup -> refuse; menu -> x = y = 0, clipped by the scene
floating pane, named position, border b in {0,1}:
    left: b     centre: (W-w)/2     right: W-w-b        // rows identical
    quarter: W/4 - w/2   and   3W/4 - w/2
cascade default (no position given): ox = 4 then +4 per pane; oy = 2 then +2
```

**Where it lives.** `cmd-display-menu.c:236-286` (popup expansion and clamp), `:415-463`
(menu clamp); `menu.c:592-601` (second clamp), `menu.c:541-569` (`menu_resize`);
`popup.c:285-321` (`popup_resize_cb`); `cmd-join-pane.c:68-193`; `layout.c:1742-1765`
(cascade defaults).

**Degradation.** Every operation is an integer add, subtract or clamp over values known
before anything is painted, so the whole algebra survives with no OS surface, no hover, no
script, no sub-cell precision and no key release, and can be evaluated at emit time on a
script-free HTML tier. An Android soft-keyboard inset appears to map onto tmux's status-line
inset directly — pass it in as a reduction of the surface extent before clamping rather than
letting the placer discover it — though tmux itself has no such case and this is an
inference about transfer, not an observation.

> [!WARNING]
> `tmux.1:8220` still states "If the menu is too large to fit on the terminal, it is not
> displayed." That was true when menus were built on `popup_display`; the source now clamps
> and the regression suite asserts clipping. Documentation drift between two surfaces that
> once shared a placement path is a real cost of duplicating that path.

### 3. Collision & geometry engine

tmux runs two occlusion engines and one cached display list, all in whole cells.

The popup's engine is `server_client_overlay_range(x, y, sx, sy, px, py, nx, r)`
(`server-client.c:168`): given a horizontal run about to be drawn, return the at-most-two
sub-runs the popup rectangle does not cover — trivial `y` reject first, then a left piece and
a right piece.

The general engine is `window_visible_ranges` (`window-visible.c:51`). It walks `w->z_index`
from BACK to front, skips everything until it reaches `base_wp` itself (the `found_self`
gate), and then subtracts each pane ABOVE it from the run, growing the range array when a
floating pane lands strictly inside. Border columns are folded into the occluding rectangle
(`lb = xoff - 1`, `rb = xoff + sx`, plus scrollbar width) unless the floating pane has
`PANE_LINES_NONE`.

```text
occlude(run [px, px+nx) on row py, occluders above self, back-to-front):
    ranges = [run]
    for each occluder O whose [top, bottom] contains py:
        lb = O.x - border;  rb = O.x + O.sx + border(+scrollbar);  clamp to surface
        for each r in ranges:
            if lb > r.s && lb <= r.e && rb > r.e:   r.nx = lb - r.s          // shrink left
            elif rb >= r.s && rb <= r.e && lb <= r.s: r.px = rb+1;
                                                    r.nx = r.e - rb         // shrink right
            elif lb > r.s && rb <= r.e:  split into [r.s, lb-1], [rb+1, r.e] // array grows
            elif lb <= r.s && rb > r.e:  r.nx = 0                            // annihilate
    return ranges       // emptiness is "every nx == 0", not "used == 0"
```

Cost is `O(sx * sy)` to rebuild the scene into one grow-only static arena
(`redraw_cells` / `redraw_ncells`) and `O(spans)` to draw it. Invalidation is a monotonic
generation counter plus four geometry keys — no observers, no polling, no frame callbacks.
Sub-cell precision, device pixel ratio, transforms and zoom do not exist here.

The genuinely hard cell-grid case is a double-width grapheme bisected by an occluder.
`tty_cmd_cell` (`tty.c:2046-2057`) sums the visible sub-range widths and, if the sum is less
than the character's width, falls back to a full `tty_draw_line` of the region;
`tty_draw_line` then detects leading `GRID_FLAG_PADDING` cells at the clip boundary and
CLEARS them with the correct background rather than painting half a glyph
(`tty-draw.c:183-186`):

> If there is padding at the start, we must have truncated a wide character. Clear it.

**Where it lives.** `server-client.c:168`; `window-visible.c:51-215`;
`screen-redraw.c:936-1034`; `screen-redraw.c:1064-1104` (invalidate / get scene);
`tty.c:1511` (`tty_check_overlay_range`); `tty.c:2046`; `tty-draw.c:183-219`.

**Degradation.** Interval arithmetic over integers survives every degradation axis, and it
PRESUPPOSES the absence of sub-cell precision rather than suffering from it. The output is
plain data — a list of `(px, nx)` pairs — so it is assertable byte-for-byte on a recording
canvas. The part that does not generalise off tmux's substrate is escape-sequence-specific:
`tty_clear_line` and `tty_draw_line_clear` refuse to use `EL`/`EL1`/`ECH` whenever
`c->overlay_check != NULL`, because those sequences clear to the physical end of the line and
cannot be masked. A canvas backend has no such hazard.

### 4. Arrow / caret geometry

Not applicable: tmux draws no arrows, tails, beaks or connectors on any overlay, and no code
path knows which side of an anchor a surface landed on. The absence is itself a finding — on
a cell grid the smallest expressible unit is a whole character cell, so a caret could only
ever be one cell, and that cell is spent on the border instead.

The structural analogue worth naming is the border-connection model, which does the
"geometry is data, glyph is paint" split the arrow dimension usually asks for. A four-bit
mask (`REDRAW_BORDER_L|R|U|D`) is mapped by `redraw_get_cell_type` (`screen-redraw.c:384`) to
one of eleven `CELL_*` types (`CELL_LRUD`, `CELL_LRU`, `CELL_LR`, `CELL_ULD`, `CELL_LU`, …
`CELL_NONE`), and `screen_write_box_border_set` (`screen-write.c:722`) renders that type
through one of the `enum box_lines` styles (single / double / heavy / rounded / simple /
padded / none). Geometry is decided as a bitmask; glyph selection is a late, style-dependent
lookup. The second analogue is the menu separator: `screen_write_hline`
(`screen-write.c:758`) emits `CELL_URD` at the left end and `CELL_ULD` at the right, so a
separator tees into the surrounding frame in whatever line style the frame uses instead of
butting against it. tmux does have "arrows" in an unrelated sense —
`redraw_mark_border_arrows` draws directional pane-border indicators and marks those spans
`REDRAW_BORDER_IS_ARROW`, which deliberately defeats span joining so each arrow cell stays
individually addressable.

**Degradation.** At one-cell granularity an arrow reduces to a border-cell type choice, so
there is no offset to compute, no [transform origin][concepts] to derive, and nothing that
needs script or sub-cell precision. The transferable conclusion for a cell toolkit is to
model connectivity as a direction bitmask on border cells rather than as a triangle with an
offset — and, separately, to note what tmux cannot express: with no resolved side anywhere in
the system, arrow orientation would have nothing to read.

### 5. Trigger semantics

Every trigger is a key binding, and mouse buttons ARE keys. `server_client_check_mouse`
(`server-client.c:852-1160`) is the entire trigger decoder: it classifies the raw event into
a type (`MOUSEDOWN`, `MOUSEUP`, `MOUSEDRAG`, `MOUSEMOVE`, `SECONDCLICK`, `DOUBLECLICK`,
`TRIPLECLICK`, `WHEELUP`, `WHEELDOWN`), determines a location (status-line range, scrollbar,
pane by z-ordered hit test, or empty), and encodes type + buttons + modifiers + location into
a single key code. That is why `MouseDown3Pane`, `MouseDown3Status`, `MouseDown3StatusLeft`,
`MouseDown3Empty`, `MouseDown1Control9` and `M-MouseDown3Pane` are distinct key codes looked
up in the ordinary key table (`key-bindings.c:537-556`).

There is no hover trigger for popups or menus anywhere in the tree; the only
hover-triggered surface in the program is the auto-hide pane scrollbar. Programmatic
triggering is the norm, since any command list can run `display-menu`. Pointer-type
distinction reduces to one bit: `if (!event->m.valid && !args_has(args, 'M')) flags |=
MENU_NOMOUSE` (`cmd-display-menu.c:551`) — the menu asks the INVOKING KEY EVENT whether it
carried a valid mouse position.

Multiple triggers cannot race, because there is exactly one input source per client (the tty
byte stream), decoded on one thread, funnelled through `server_client_handle_key0`, and every
command that opens a surface runs from the single global command queue. Ambiguity is resolved
by an ordered chain, not by priorities. Click sequencing is a real state machine:
`CLIENT_DOUBLECLICK` / `CLIENT_TRIPLECLICK` plus a `click_timer` armed at
`KEYC_CLICK_TIMEOUT`, with the sequence RESET if the button, the location or the target pane
changed between clicks (`server-client.c:1116-1141`).

```text
decodeTrigger(rawMouse):
    type = classify(b, lb, sgr_b, drag/release/wheel bits, doubleclick flag)
    loc  = statusRange(x,y) ?? scrollbar(x,y) ?? paneHitTest(z_index, x,y) ?? EMPTY
    key  = encode(type, buttons, modifiers, loc)
    if type in {DOWN, SECOND, TRIPLE} and (button | loc | pane changed):
        demote to DOWN, restart the click timer
route(key): themeKeys -> overlay -> windowMenu -> clientPrompt -> panePrompt -> keyTable
```

**Degradation.** With no hover every trigger here still works: all of them are press,
release or programmatic. The casualty of an absent RELEASE edge is the click machine —
`DOUBLECLICK`/`SECONDCLICK` need down and up distinguished, and tmux already runs a degraded
version of this itself, because the legacy `m->sgr_type == ' '` branch cannot tell WHICH
button was released and must consult `m->lb`. (Under SGR-1006 the release and its button are
reported, so the ambiguity is a property of the older wire format, not of terminals in
general.) With no script, only `:hover`/`:checked`-shaped triggers survive and the entire
location-encoded key vocabulary collapses. The transferable lesson is to encode a trigger as
(type, location) in one comparable value and to make the router an explicit ordered chain, so
removing a tier removes a link rather than changing the algorithm.

### 6. Timing

Neither popups nor menus have any delay: no open delay, no close delay, no
[warm-up][concepts], no [cool-down][concepts], no maximum duration, no groups and no
singleton provider. The overlay API _has_ an auto-dismiss timer —
`server_client_set_overlay(c, delay, …)` arms `c->overlay_timer` and
`server_client_overlay_timer` calls `server_client_clear_overlay` — but the only caller at
this revision is `popup.c:657`, which passes `0`, so no timer is armed and the timed path is
unreachable. Its previous user was the overlay-based `display-panes`, deleted by
[`1a02c995`][c-panes].

Three real timing machines survive elsewhere and are the models worth reading:

- `status_message_set(c, delay, ignore_styles, ignore_keys, no_freeze, …)`
  (`status.c:340`): `delay == -1` means use the `display-time` option, `0` means wait for a
  key press (no timer armed), `> 0` means milliseconds. Crucially
  `if (delay != 0) c->message_ignore_keys = ignore_keys` — a message that waits for a key can
  never also ignore keys.
- The auto-hide scrollbar: a pure close-delay machine. A `MOUSEMOVE` into the scrollbar area
  sets `sb_auto_hover = 1` and calls `window_pane_scrollbar_show`, which DELETES the pending
  timer; moving out calls `window_pane_scrollbar_start_timer` (`window.c:2510`), which arms
  `pane-scrollbars-timeout`. No open delay, one timer per pane, re-entry cancels.
- Click timing: `KEYC_CLICK_TIMEOUT` with the sequence reset on any target change.

```text
distilled machine (from the three instances above):
    Closed -(trigger)-> Opening[openDelay] -> Open -(leave)-> Closing[closeDelay] -> Closed
    enter(anchor | surface)   cancels Closing and its timer
    re-enter before it fires  returns to Open with no reopen cost
    explicit dismiss          goes straight to Closed and cancels every timer
    delay == 0                must NOT also arm an ignore-input window (status.c's rule)
    group/singleton           = one owner slot; opening B closes A synchronously
```

**Where it lives.** `server-client.c:69-95` (the unreachable overlay timer); `status.c:340`;
`window.c:1386`, `:2510`, `:2527`; `server-client.c:1129`.

**Degradation.** A target with no timers at all kills every one of these machines, and leaves
tmux's popup and menu untouched, because they never had any. On a target with no hover the
scrollbar machine loses its only trigger. The design implication is the strong one: make the
delay a parameter that may be zero and make zero the structural default, so a timerless
target is the degenerate case of the same code path — which is exactly how tmux's overlay
delay behaves, and it is why the timed branch is dead rather than broken.

### 7. Interactive hover

There is no safe polygon, no pointer bridge, no diagonal menu-aim, no trajectory heuristic,
no debounce and no interactive border tolerance. The whole-cell cost of every one of those
algorithms in tmux is zero, because none is implemented.

Submenus do not exist as a concept. Choosing an item that runs `display-menu` closes the
current menu (`menu_key` returns 1) and the queued command then opens a NEW menu, positioned
`-xL -yL` at exactly the previous menu's top-left (`key-bindings.c:68-69`) — the stored
`popup_last_y` is `menu_last_py + h`, and the universal `n -= h` gives `menu_last_py` back.
A "submenu" is therefore an in-place replacement: the pointer travel distance is zero cells
by construction, so the corridor problem is removed rather than solved.

What tmux implements instead is a defence against the transport's ambiguity. A pointer move
with no button held is reported as a release on a terminal, so `menu_key`
(`menu.c:341-349`) derives a synthetic predicate and refuses to let it act:

> A mouse move with no button held reports as a release, so treat it as highlight-only: it
> must never select or close the menu, otherwise a menu opened without a button already down
> (such as a submenu opened from another menu) would vanish as soon as the mouse moved over
> it.

```text
hoverHighlight(menu, m):
    move = MOUSE_DRAG(m->b) && MOUSE_RELEASE(m->b)     // "motion, nothing pressed"
    if outside(rect):  choice = -1
                       if (!STAYOPEN && !move && RELEASE(m->b)) close
    else:              if (!STAYOPEN && !move && RELEASE(m->b)) choose
                       choice = m.y - (py + 1)
    redraw only if choice changed
```

`MENU_STAYOPEN` (`-O`) inverts the rules so that a release never chooses and never closes,
requiring a genuine click. Hover highlighting needs all-motion mouse reporting, which
`menu_display` obtains by setting `MODE_MOUSE_ALL|MODE_MOUSE_BUTTON` on the menu's own screen
(`menu.c:632-633`) so `server_client_reset_state` and `tty_update_mode` emit the 1000/1002/1003
modes for the menu's lifetime. Nested surfaces coexist without interaction: a client popup
and a window menu can both be up, and the popup wins every key unconditionally, so the menu
underneath is unreachable until the popup closes.

> [!NOTE]
> Whether a keyboard-invoked `display-menu -M` turns terminal mouse reporting on even when
> the `mouse` option is off is an INFERENCE from tracing `server_client_reset_state` into
> `tty_update_mode` (the mode starts as the menu screen's mode and the mouse-option block does
> not clear it). It was not observed.

**Degradation.** With no hover, highlight-follows-pointer disappears and only tap-to-choose
remains — a mode tmux already ships as `MENU_NOMOUSE`. Where a release edge is unavailable,
the release-chooses rule cannot survive and the `-O` click-required semantics become the only
option, which is a direct argument for making STAYOPEN-like behaviour the default rather than
the flag on such a target. With no script, `:hover` gives highlighting for free and nothing
else survives. And the placement lesson stands on its own: if you cannot afford a safe
polygon, place the child surface where the travel corridor is empty — in place, or
edge-aligned — instead of building a corridor.

### 8. Dismissal

Popup dismissal (`popup.c:382-460`, `popup.c:485-502`):

- Escape or `C-c` close it, but ONLY if neither `-E` nor `-EE` is set or there is no job
  (`popup.c:429-432`) — with `-E` the child owns the keyboard and Escape must reach it.
- `-k` (`POPUP_CLOSEANYKEY`) closes on any non-mouse, non-paste key once the job has exited.
- `-E` closes when the child exits; `-EE` only when it exits zero
  (`popup_job_complete_cb`).
- `display-popup -C` clears it programmatically.
- A client resize would clear an overlay that supplies no resize callback
  (`server-client.c:2649-2652`); popups supply one, so they survive by re-clamping.
- A click OUTSIDE a popup is NOT a dismissal and is NOT passed through: `popup_key_cb`
  returns 0 for an out-of-rect mouse event and the router returns 0, so the event is
  silently discarded.

Menu dismissal (`menu.c:327-538`): Escape, `C-[`, `C-c`, `C-g` and `q` close it; Enter
chooses; a mouse RELEASE outside the rect closes unless `-O`; choosing a separator or a
disabled item closes unless `-O`; any command that opens another menu closes it first
(`menu_close`); a window resize does NOT close it, because `menu_resize` re-clamps; and a
menu dies with its window (`menu_destroy` from `window.c:461`).

A modal floating pane implements the tree's only true [light dismiss][concepts]:
`new-pane -O -C` sets `PANE_CLOSEONCLICK`, and a `MOUSEDOWN`/`SECONDCLICK`/`TRIPLECLICK`
outside the modal's rect calls `server_kill_pane` (`server-client.c:1065-1069`) — light
dismiss implemented as "kill the thing". Notably absent: no dismissal on focus-out, on anchor
removal, on the anchor scrolling out of view, on navigation, or on window deactivation.

> [!IMPORTANT]
> There is a catch-all worth knowing: if an overlay has a NULL key callback,
> `server_client_handle_key0` falls through to `server_client_clear_overlay(c)` on the next
> key (`server-client.c:1757`). An overlay that declines to handle keys is dismissed by any
> key.

```text
popupKey(e):
    if mouse && dragging:            continueDrag; swallow
    if mouse && outside rect:        swallow (no dismiss, no passthrough)
    if (!closeOnExit || no job) && key in {ESC, C-c}:   return CLOSE
    if no job && CLOSEANYKEY && key is a real key:      return CLOSE
    if job: re-encode mouse into popup-local cells; forward; return HANDLED
menuKey(e):
    outside && release -> CLOSE ; ESC/C-[/C-c/C-g/q -> CLOSE
    Enter | hotkey     -> choose, then CLOSE ; otherwise HANDLED
```

**Degradation.** Every dismissal path converges on one boolean returned from one callback,
which is exactly the shape an Android back-key handler wants. Where a release edge is
unavailable, "release outside closes" must become "press outside closes" — and both variants
already exist in-tree, since the modal pane's light dismiss is press-based. Without a pointer
[grab][concepts], a press that leaves the surface may never be reported at all; tmux does not
care because the terminal reports the whole screen while a mouse mode is on, so a toolkit
without that guarantee should prefer press-based dismissal.

### 9. Focus

tmux keeps toast, menu, popover and dialog sharply distinct by giving each a DIFFERENT input
mechanism rather than a different flag on one mechanism — four data types, not four values of
an enum:

| Surface    | What "focus" is                       | Mechanism                                                                               |
| ---------- | ------------------------------------- | --------------------------------------------------------------------------------------- |
| Message    | nothing                               | drawn in the status line; keys dismiss it or are ignored (`message_ignore_keys`)        |
| Menu       | an integer selection index            | `md->choice`, `-1` = nothing selected; `menu_key` consumes all keys                     |
| Popup      | a delegated input sink                | keys re-encoded to the PTY child via `input_key`; mouse re-encoded to popup-local cells |
| Modal pane | an ownership flag other code consults | `w->modal`, checked by every pane-selection and target-resolution path                  |

The modal pane is the only real application-[focus scope][concepts]:
`window_set_active_pane` refuses any pane other than `w->modal` (`window.c:719`),
`window_get_active_at` short-circuits to the modal or NULL (`window.c:813`), and `cmd.c:835`
refuses to resolve a command target to a non-modal pane. Focus RESTORATION is one saved
pointer, `w->modal_last`, consumed in `window_lost_pane` with a liveness check and a fallback
to the last-pane stack (`window.c:1066-1082`); window zoom state is separately saved and
restored around the modal's life (`window_push_modal_zoom` / `window_pop_modal_zoom` and
`WINDOW_WASMODALZOOMED`, `window.c:976-996`).

Pointer-opened and keyboard-opened menus differ materially. A keyboard-opened menu is
`MENU_NOMOUSE` and applies `-C starting-choice`, wrapping over disabled items (`-C -` means
no preselection); a mouse-opened menu starts at `choice = -1` with nothing highlighted
(`menu.c:640-674`). Navigation skips separators and disabled items in both directions and
bails after one full lap, a guard added by commit [`347baa6f`][c-menuloop] for a menu in
which every item is disabled.

```text
openMenu(fromMouse, startingChoice):
    choice = fromMouse ? -1 : firstEnabledFrom(startingChoice, wrapping, bail after one lap)
move(dir):  do { choice = wrap(choice + dir) } while (separator|disabled && choice != origin)
modalFocus(open):  saved = active; active = modal; savedZoom = zoomed; unzoom()
modalFocus(close): active = (saved alive) ? saved : lastPaneStack; if savedZoom re-zoom
```

Focus events to panes are suppressed while any overlay or menu is up:
`window_pane_update_focus` requires `c->overlay_draw == NULL && wp->window->menu == NULL`
(`window.c:686-687`).

**Degradation.** With no OS surface there is no system focus to lose, so focus reduces to
"which node consumes the next key" — a single owner slot, which is what tmux models. Nothing
here needs a key release: selection movement is press-driven throughout. On a recording
canvas every part of it is assertable, because focus is an integer index or a pane pointer,
never an opaque platform state.

### 10. Layering & portals

There is no [top layer][concepts], no portal, no stacking context and no z-index property —
and yet three distinct layering mechanisms coexist, which is the finding.

1. **Client overlay** — exactly one per client, six callbacks on `struct client`, drawn
   LAST in `redraw_draw` (`if (c->overlay_draw != NULL && (flags & REDRAW_OVERLAY))`), with
   everything below querying `overlay_check` before writing a cell.
   `server_client_set_overlay` clears any existing overlay first, so the slot IS the
   ownership model.
2. **Window menu** — exactly one per window (`w->menu`), drawn as span type
   `REDRAW_SPAN_MENU`, marked into the build grid after all panes (`redraw_mark_menu` is the
   last call in `redraw_build_cells`), so "above" is expressed purely as "marked later".
3. **Floating panes** — many, ordered by `w->z_index`: a TAILQ whose head is the front,
   painted with `TAILQ_FOREACH_REVERSE` (back to front), hit-tested with `TAILQ_FOREACH`
   (front to back), reordered by six verbs plus an automatic raise-on-activate in
   `window_redraw_active_switch`. A modal pins the ceiling: a new floating pane is inserted
   AFTER the modal in z-order (`window.c:1046-1052`), so nothing can stack above a modal.

```text
paint:  for wp in reverse(z_index): mark(wp);  mark(menu);  RLE -> spans;
        draw spans by type;  draw the client overlay last
hit:    for wp in z_index (front first): if contains(wp, x, y) return wp   // modal first
raise:  TAILQ_REMOVE(z); TAILQ_INSERT_HEAD(z)          // on activate, on 'front'
insert: floating -> head, unless a modal exists -> after the modal; tiled -> tail
```

The public API is `server_client_set_overlay(client, delay, six callbacks, data)`,
`menu_display(…)`, the `-z` z-index argument and the position verbs; the span types, the
build grid, the generation counter and the visible-range arrays are implementation. Note
`window_panes_find_pane` (`window-panes.c:1017`), the `display-panes` mode's hit test: a
reverse-order walk of a flat derived list of areas — literally the "hit-test the display list
backwards" loop.

**Degradation.** This dimension needs no OS surface, compositor or script; front-to-back is
already just "later in the display list". The one thing that does not transfer is the
client-overlay slot itself, whose cost is the special-casing the maintainer cites when saying
overlays should be deleted.

### 11. Modality

Three graded levels, each implemented by a different mechanism.

**Popup — hard modal, no light dismiss, no passthrough.** `popup_key_cb` sees every key
first, and BOTH of its return values cause `server_client_handle_key0` to `return (0)`: the
event is never queued, never reaches the key table and never reaches a pane. A mouse click
far outside the popup is swallowed — not passed through, not treated as a dismissal. The only
escape is the out-of-band branch ahead of the chain (`server-client.c:1722-1725`):

> Handle theme reporting keys before overlays so they work even when a popup is open.

`server_client_set_overlay` additionally sets `TTY_FREEZE` when there is no check callback and
`TTY_NOCURSOR` when there is no mode callback — a crude "freeze everything below" that popups
opt out of by supplying both.

**Menu — light-dismiss modal.** It takes all keys (`server_client_handle_menu_key` always
consumes once `w->menu != NULL`), but a mouse release outside closes it; `-O` upgrades it to
click-required.

**Modal pane — application modal.** Keys reach the pane routing layer normally, but every
pane-selection, target-resolution and mouse hit-test path consults `w->modal` and refuses
other panes, so background POINTER input is blocked while the client's prefix key table still
works — `regress/modal-pane.sh:199-200` asserts that a click on a non-modal pane leaves
`@modal-mouse` empty, and `:224` asserts that `C-b x` still fires. There is no scrim, no dim
and no accessibility modal bit anywhere.

One exception to pointer blocking matters: a drag that STARTED in the modal continues to be
delivered after the pointer leaves the modal's rect, keyed on `c->tty.mouse_drag_flag` and
`c->tty.mouse_last_pane` (`server-client.c:1045-1055`) — software pointer capture with no OS
grab.

```text
modalRoute(key):
    if key is out-of-band protocol (theme report):  handle; done
    if overlay:     r = overlay.key(key); ALWAYS consume; if r == CLOSE close; done
    if windowMenu:  menu.key(key);       ALWAYS consume; done
    if modalPane && pointer event outside modalRect:
        if dragOriginWasModal && (drag | up):  deliver to modal      // capture
        else: if CLOSEONCLICK && isPress: kill(modal);  drop the event
    else: normal routing
```

**Degradation.** Without a native pointer grab, tmux's `modal_drag` is the exact substitute:
remember which node owns the in-progress drag and route by ORIGIN rather than by current
position. Where a drag can never formally end for want of a release, tmux's own guard applies
— it also ends the drag on any event that is not a drag. Without an OS surface there is no
app-deactivation event, so tmux simply has no such dismissal cause, which is the honest
answer rather than a gap.

### 12. Adaptive presentation

There is no automatic popover-to-sheet or tooltip-to-long-press adaptation, and no capability
probe drives presentation. One genuine adaptation exists, and it lives in the COMMAND layer
rather than the widget layer: `cmd_display_menu_exec` inspects the key event that invoked it
and, if that event carried no valid mouse position and the caller did not force `-M`, sets
`MENU_NOMOUSE` (`cmd-display-menu.c:551`). One bit of provenance — "was this invoked by a
pointer?" — then selects three things at once: (i) all mouse handling in `menu_key` is
suppressed, (ii) the mouse-mode bits are not set on the menu's screen, and (iii) the
`-C starting-choice` preselection is ENABLED.

A second, coarser adaptation is that `display-popup` on a client that already has a popup
MODIFIES it (`popup_present` → `popup_modify` for title, style, border and flags) instead of
stacking a second one. A third is width adaptation at build time in `menu_add_item`
(`menu.c:96-127`): item text is trimmed to the client width, and the bracketed key hint is
reserved only if it is short relative to the row.

```text
presentation = f(invocationProvenance, surfaceWidth):
    mouseCapable = event.mouse.valid || forcedByFlag
    if !mouseCapable: no mouse handling, no motion reporting, preselect an item
    itemText: max = clientWidth - 4
              if keylen <= max/4                        -> reserve the hint
              elif keylen >= max || slen >= max - keylen -> drop the hint entirely
              if text > max                              -> max-- and append '>'
reopen: if a surface of this kind already exists on this client -> mutate it, do not stack
```

**Degradation.** On a touch target the `MENU_NOMOUSE` branch is wrong in the other direction:
it keys off "the invoking event carried no mouse coordinate" rather than "this target
delivers motion without buttons", and a touch DOES carry a coordinate — so the mouse branch
would be selected and hover highlighting would never happen. tmux gets away with it because a
terminal that reports mouse position always reports motion too. The transferable rule is to
adapt on the CAPABILITY, not on the presence of a coordinate.

### 13. Accessibility

A terminal grid can honestly expose exactly two things to assistive technology: the visible
characters, and the hardware cursor position. tmux uses both deliberately.

`menu_get_cursor` (`menu.c:287-294`) parks the real cursor at `(px + 2, py + 1 + choice)` —
the selected item's first text column — and `server_client_reset_state` moves the terminal
cursor there whenever a menu is up (`server-client.c:2135-2137`), suppressing it when the
menu has scrolled outside the visible window offset (`:2158-2169`). If nothing is selected
the cursor sits on the title row. Commit [`7cee982f`][c-cursor] states the purpose plainly:
"Keep cursor on selected item on menu (useful for blind people)". For popups,
`popup_mode_cb` (`popup.c:186-198`) returns the child's screen and translates its cursor into
client coordinates (`px + 1 + s.cx` with a border, `px + s.cx` without), so a caret-following
reader follows the popup's child. `server_client_set_overlay` sets `TTY_NOCURSOR` when an
overlay supplies no mode callback (`server-client.c:107`): a surface that cannot say where
the caret is hides the caret rather than leaving it stale. Menus clear `MODE_CURSOR` on their
own screen (`menu.c:634`) — the highlight, not a blinking block, is the visual, while the
caret is the assistive-technology channel.

Beyond that there are no roles, no name/description split, no live regions, no modal bit and
no accessibility tree. Disabled items are encoded in the CONTENT model (a leading `-` in the
item name, rendered `GRID_ATTR_DIM`) and skipped by every navigation path. Nothing is
hover-only interactive: everything reachable by mouse is also reachable by an item hotkey or
by arrow keys.

```text
exposeToAT(surface):
    caret = surface.hasSelection ? cellOf(firstTextColumn, selectedRow) : cellOf(titleRow)
    if the surface cannot report a caret: hide it entirely (never leave it stale)
    every pointer-reachable action also has a key: hotkeys + arrows + Home/End/PageUp/PageDown
```

> [!NOTE]
> What a screen reader actually does with the parked cursor is an INFERENCE from the commit's
> stated intent. No assistive-technology behaviour was observed here.

**Degradation.** All four rules above are reachable without an accessibility API, an OS
surface or script, and all four are assertable on a recording canvas (the caret cell, and the
presence of a hotkey per item). This is the floor a cell-grid toolkit can hit, and it costs
almost nothing.

### 14. Animation

Not applicable: there is no animation of any kind on popups, menus or floating panes — no
enter/exit transition, no [transform origin][concepts], no spring, no reduced-motion setting,
no reposition-during-animation, and no side/alignment metadata emitted for a styling layer to
consume. Opening a surface marks the client dirty and the next frame contains it fully
formed.

The reason is structural rather than aesthetic. The output is a byte stream of cell writes,
the redraw unit is a whole line span, and the codebase deliberately MINIMISES writes: commit
[`824a0729`][c-redrawoverlay] ("Do not redraw overlays unless actually asked to") added
`CLIENT_REDRAWOVERLAY` specifically so an overlay is not repainted every frame, and
`popup_set_client_cb` (`popup.c:146`) refuses incremental output while a full overlay redraw
is already pending. The only animation primitive in the whole program is the status-line
format modifier `#{A/count:frames}`, which cycles frames of text and is confined to the
status line.

The relevant algorithm here is the dual of animation — suppressing redundant repaints.
`redraw_screen` selects a flag set from the dirty bits (`CLIENT_REDRAWWINDOW` / `BORDERS` /
`STATUS` / `OVERLAY` / `MENU`) and `redraw_draw` walks only the span buckets whose type flag
is set, so a menu highlight change repaints only `REDRAW_SPAN_MENU` spans
(`screen-redraw.c:1486-1520`, `:1868-1891`; `server-fn.c:132` sets `CLIENT_REDRAWMENU` alone).

**Degradation.** An immediate-mode backend repainting every frame loses this optimisation
entirely, and a script-free target has no frames at all. The transferable part is that a
per-surface dirty flag plus per-span-type filtering lets the SAME display list serve both a
full repaint and a one-row highlight update. What tmux would still lack if it ever wanted
animation is a side or alignment tag: placement here produces coordinates, never a resolved
side, so there is no fact anywhere in the system saying "this ended up above the anchor".

### 15. State architecture

Ad-hoc structs plus callbacks: no reducers, no controllers, no controlled/uncontrolled
duality. `struct popup_data` (`popup.c:29-73`) is one flat POD — identity (client, command
queue item, flags, title), style strings and resolved grid cells, the child's screen and
palette, a reused `visible_ranges` scratch buffer, job and input plumbing, the CURRENT
geometry `px`/`py`/`sx`/`sy`, the PREFERRED geometry `ppx`/`ppy`/`psx`/`psy`, and the only
real state machine in the file:

```c
    /* Current position and size. */
    u_int                     px, py, sx, sy;

    /* Preferred position and size. */
    u_int                     ppx, ppy, psx, psy;

    enum { OFF, MOVE, SIZE }  dragging;
    u_int                     dx, dy;      /* drag origin */
    u_int                     lx, ly, lb;  /* last event */
```

`struct menu_data` (`menu.c:26-52`) is smaller: window, flags, three style strings and three
resolved cells, the find-state commands will run against, the invoking key and mouse event
(replayed later so a chosen command sees the original event), the rendered screen, `px`/`py`,
the menu model, and `int choice`. Both key handlers are large switches returning 0 (stay) or
1 (close) — a two-state protocol the router turns into a lifecycle. Ownership is a `void *`
plus a free callback.

Two details are worth isolating. First, the current/preferred split: on terminal resize a
popup shrinks to fit but REMEMBERS `psx`/`psy` and `ppx`/`ppy`, so growing the terminal
restores its intended size and position — and a user drag rewrites BOTH, so "the user moved
it" and "the author asked for it" are the same state. Second, style is re-resolved on every
draw (`popup_reapply_styles` at `popup.c:95`, `menu_reapply_styles` at `menu.c:180`, added by
commit [`ecbf8d76`][c-styles]) while geometry is not, so an option change repaints the surface
immediately without disturbing its position or size.

```text
surfaceState = { current rect, preferred rect, dragging: {OFF|MOVE|SIZE},
                 dragOrigin, lastPointer, selection }
resize(surface, newExtent):
    size = min(preferredSize, extent)
    pos  = (preferredPos + size > extent) ? extent - size : preferredPos
drag(MOVE): pos  = clamp(pointer - origin, 0, extent - size);  preferred = pos
drag(SIZE): size = pointer - pos (rejected below a 3-cell floor); preferred = size
key(e) -> {HANDLED, CLOSE}
```

**Degradation.** Nothing in this architecture needs floating point, sub-cell precision, a key
release or an OS surface: every field is a scalar, an enum or an owned buffer, with no
closures, no observers and no reactive graph. Two things would need changing on the way out:
`menu_update` (`menu.c:229-248`) re-renders the entire menu into an off-screen grid on every
draw, duplicating the caching the scene already provides; and the returned-int protocol
(0/1, plus a third value the router still switches on) wants to be an enum.

### 16. Shared infrastructure

Genuinely shared across every surface: `struct screen` (an off-screen cell grid anything can
render into); `screen_write_box` plus `enum box_lines` and `screen_write_box_border_set`
(one border renderer for popups, menus, floating panes and mode UIs); the `visible_ranges`
occlusion vocabulary; `tty_draw_line` (one blitter from a screen to the terminal at an
offset); the style/option layer (`popup-style`, `popup-border-style`, `menu-style`,
`menu-selected-style`, `menu-border-style` and the `*-border-lines` family all go through
`style_apply`/`style_parse`); and `format_expand` as the placement expression evaluator.

What only LOOKS shared is PLACEMENT. `cmd_display_menu_get_popup_pos`
(`cmd-display-menu.c:95`, ~195 lines) and `cmd_display_menu_get_menu_pos` (`:292`, ~176
lines) sit adjacent in one file, compute the same named variables with the same formulas, and
differ in two respects: the coordinate space (client/tty with hand-applied status offsets
versus window with offsets applied later by the scene), and the oversize policy (refuse
versus clamp). They have already drifted — the menu version never checks whether the surface
fits, and omits the status-line corrections the popup version applies.

Also NOT shared: key handling (`popup_key_cb` forwards to a PTY, `menu_key` runs commands);
lifetime (client overlay slot versus window field versus pane list); and the redraw path
(drawn last by the client versus a span type in the scene versus a z-ordered pane).

```text
what one anchored-overlay primitive can hold, per this subject:
    - a rect in integer cells + a preferred rect
    - a placement expression evaluator over named cell coordinates, with one clamp step
    - a border/box renderer parameterised by a line-style enum and a connection bitmask
    - occlusion as per-row interval subtraction; hit test as reverse-order rect containment
    - a single consume/close return protocol from the surface's key handler
what must stay apart:
    - content ownership (a child process vs an item list vs a widget subtree)
    - dismissal policy (hard modal / light dismiss / click-required / close-on-exit)
    - who owns the surface (viewer-local vs document-global)
    - the coordinate SPACE, which is one choice made once, not per surface
```

> [!WARNING]
> Menus became document-global (commit [`ad6832e6`][c-menus]; `CHANGES` records "Menus now
> belong to the window, so appear on all clients") while one of their layout inputs stayed
> viewer-local: `menu_add_item` still trims item text to `c->tty.sx - 4` for the ORIGINATING
> client (`menu.c:98`). A narrow client's menu is therefore rendered pre-truncated on a wide
> one. Decide per overlay kind whether a surface belongs to the document or to the viewer's
> session, and make every layout input come from the same side of that line.

**Degradation.** The duplication here has nothing to do with degradation: it is a
consequence of the coordinate space having been chosen per surface rather than once. In a
toolkit with a single coordinate space, this particular copy could not arise for this
particular reason — which is a narrow, single-instance observation, not a general law about
duplication. See [`./comparison.md`][comparison] for how it lands against the rest of the
corpus, and [`./proposal.md`][proposal] for what a shared `place()` would and would not fix.

## Strengths

- Placement is a genuine value language over integer cell coordinates, resolved once into a
  plain comparable pair — no anchor object, no tracking, no measurement, no reflow.
- The bottom-edge convention with a single `n -= h` normalisation lets a dozen semantically
  different anchor variables share one clamp path, with no per-variable fix-up.
- Preferred-versus-current geometry (four extra integers) buys correct restore-on-regrow and
  unifies "the author asked for this" with "the user dragged it here".
- Occlusion is per-scanline interval subtraction over a z-ordered list, returning plain
  `(px, nx)` data: cheap, exact, assertable, and independent of any rendering substrate.
- The redraw scene is a real cached display list, arrived at independently: typed spans
  bucketed per line and per type, invalidated by a generation counter, painted back-to-front,
  hit-tested front-to-back over a flat derived list.
- Move and resize of a floating surface in whole cells, with no pointer grab — routed by drag
  ORIGIN, with the origin re-derived after clamping so the surface never drifts at an edge.
- The wide-character clip case is handled: partial obstruction of a double-width cell forces a
  full line redraw of the region, and orphaned padding cells are cleared with the correct
  background rather than left as half a glyph.
- Border geometry is data (a four-bit connectivity mask over eleven cell types) and glyph
  selection is a late per-style lookup, so separators tee into the frame automatically.
- The accessibility floor a terminal can honestly reach is reached: the hardware cursor is
  parked on the selected menu row, popups expose their child's cursor, and a surface that
  cannot report a caret hides it.
- A two-valued key protocol (handled / close) with teardown owned by the router, not the
  surface.

## Weaknesses

- The client-overlay seam is a dead end by the maintainer's own statement, and its cost is
  `overlay_check != NULL` special cases scattered through `tty.c`, `server-client.c` and
  `window.c` (escape-sequence optimisations, cursor and mouse modes, focus events).
- Placement is duplicated: two ~190-line near-identical functions differing only in coordinate
  space and oversize policy, already drifted apart.
- No resolved side, ever. Placement yields coordinates, not "above/below", so flip, fallback
  ordering, arrow orientation, transform origin and side-aware styling are all structurally
  inexpressible.
- Silent failure on a bad placement expression: `format_expand` plus `strtol` turns anything
  unparsable into `0`, and the surface lands in the corner with only a `log_debug` line.
- Documentation is stale where it matters (`tmux.1:8220` on oversized menus).
- Menu item text is truncated by keeping the TAIL (`format_trim_right` emits only the columns
  after `skip = total - limit`) while the `>` overflow marker is appended at the END, so the
  marker points away from the elision.
- The menu's mouse hit rectangle is one column wider than it draws
  (`m->x > md->px + 4 + menu->width` admits the first column past the right border) while the
  top and bottom border rows count as outside — an inconsistent inclusive/exclusive
  convention.
- Long menus have no scrolling: `sy = count + 2` is unbounded, `py` clamps to 0, and rows past
  the window bottom are clipped away while remaining keyboard-selectable and invisible.
- Dead API surface has accumulated around the seam: the overlay auto-dismiss delay is now
  always 0 (its only user was deleted), `popup_data.close` is never read, `popup_display`'s
  close callback and argument are always NULL, and `MENU_TAB` is handled in `menu_key` but
  set by nobody found in the tree.
- Adaptation keys off the wrong signal: `MENU_NOMOUSE` is chosen from "the invoking event
  carried no mouse coordinate" rather than "this target reports motion".
- `menu_update` re-renders the entire menu into an off-screen grid on every draw, duplicating
  the caching the scene already provides.

## Key design decisions and trade-offs

| Decision                                                                                                                                                                   | Rationale                                                                                                                                                                                                                                                                                                  | Trade-off                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Implement an anchored surface as a client-level OVERLAY: six function pointers (`check`/`mode`/`draw`/`key`/`free`/`resize`) plus a `void *` on `struct client`, one slot. | It is the smallest possible seam: the surface owns its own screen and its own input, and the rest of the program only asks "is a cell of mine visible?" before writing. Setting a new overlay implicitly frees the old one, so lifetime is trivially correct.                                              | The cost is paid everywhere else — `c->overlay_check != NULL` gates escape-sequence optimisations in `tty.c`, cursor and mouse modes in `server_client_reset_state`, and focus events in `window_pane_update_focus`. The maintainer's conclusion (commit [`1a02c995`][c-panes]) is that overlays are "full of special cases" and are being removed: `display-panes` became a window mode, menus became window-owned scene nodes, and popups are stated to be next. |
| Move menus from a per-client overlay to a per-window object drawn as one more span type in the cached scene (commit [`ad6832e6`][c-menus]).                                | A menu belongs to the thing it acts on. Window ownership means every attached client sees it, it participates in the normal invalidation and partial-redraw machinery (`CLIENT_REDRAWMENU` repaints only `REDRAW_SPAN_MENU` spans), and it stops needing the overlay special cases.                        | Ownership semantics changed observably: a menu opened by one user appears on every other attached client, and its item text is still trimmed to the ORIGINATING client's width. Coordinates also moved from client space to window space, which is why `server_client_handle_menu_key` must re-map incoming mouse events — adding the window offset, and mapping a click on the status line to the sentinel `(UINT_MAX, UINT_MAX)` so it counts as outside.        |
| Refuse to display a popup larger than the client, but accept an oversized menu and let the scene clip it.                                                                  | A popup hosts a real PTY child whose size must be meaningful, so a popup that does not fit is an error the caller should see. A menu is a fixed list of rows, clipping is survivable, and the width is already bounded by trimming each item to the client width.                                          | The two policies live twenty lines apart in one file and only one matches the manual (`tmux.1:8220`), which still describes the pre-`ad6832e6` behaviour while `regress/screen-redraw-menus.sh:126` asserts the opposite. A too-tall menu is drawn clipped at the bottom with no scrolling: items below the fold stay keyboard-selectable and invisible.                                                                                                           |
| Express placement as a string in a small algebra of named cell coordinates, evaluated through the general format engine, rather than as an enum of sides.                  | Seven single-letter words cover the common cases while any format expression covers everything else, so users can write real arithmetic against the same variables the built-in words use. The engine is integer throughout, needs no measurement of the rendered surface, and produces a comparable pair. | There is no resolved side anywhere in the system, so flip, fallback ordering, arrow orientation and animation origin are all inexpressible. Errors are silent: an unparsable expression `strtol`s to 0 and the surface lands in the corner. And `-x` naming the left edge while `-y` names the bottom edge is a trap documented only by a comment in `regress/menu-mouse.sh`.                                                                                      |
| Implement no hover, delay or safe-polygon behaviour for menus; make a "submenu" replace its parent in place instead of cascading.                                          | On a terminal a pointer move with no button held is reported identically to a release, so any hover-driven machine starts from an ambiguous signal — `menu.c:342-348` documents a submenu vanishing for exactly that reason. Replacing in place at `-xL -yL` makes pointer travel zero cells.              | There is no menu hierarchy: no breadcrumb, no way back to the parent, and each level is a separate command invocation. The related decision — deriving `move = MOUSE_DRAG(b) && MOUSE_RELEASE(b)` rather than trusting the release bit — is the one to copy on any target that cannot distinguish those two signals.                                                                                                                                               |
| Route input as a fixed ordered chain consuming unconditionally at the first matching tier (theme keys, overlay, window menu, client prompt, pane prompt, key table).       | One input source, one consumer chain, no priorities to reconcile and no races to lose. The surface's key handler returns only "handled" or "close", and the router turns "close" into the whole teardown, so the surface never destroys anything itself.                                                   | Consumption is total: once a popup is up, a mouse click far outside it is neither delivered to the pane nor treated as a dismissal — it is dropped. That is defensible for a modal surface, but it forces light dismiss to be re-implemented at each tier (the menu uses a release test; the modal pane uses `PANE_CLOSEONCLICK` and a press test), and the out-of-band escape hatch for theme reports had to be hard-coded ahead of the chain.                    |

## Sources

Primary sources, all read at `851c5a933d4838c32ad06c248b2ba975d106149c`:

- [`popup.c`][popup-c] — `struct popup_data` (current vs preferred geometry, the
  `{OFF, MOVE, SIZE}` drag machine), [`popup_key_cb`][popup-key],
  [`popup_handle_drag`][popup-drag], [`popup_resize_cb`][popup-resize],
  [`popup_mode_cb`][popup-mode], [`popup_reapply_styles`][popup-styles],
  [`popup_display`][popup-display].
- [`menu.c`][menu-c] — `struct menu_data`, [`menu_key`][menu-key] (the move-reports-as-release
  predicate), [`menu_add_item`][menu-additem] (width budget and hint dropping),
  [`menu_display`][menu-display] (the second clamp and `menu_last_px`/`_py`),
  [`menu_get_cursor`][menu-cursor], [navigation with the disabled-item lap guard][menu-nav],
  [`menu_resize`][menu-resize].
- [`cmd-display-menu.c`][cdm-popuppos] — [the oversize refusal][cdm-oversize], the
  [`-x`][cdm-xalias] and [`-y`][cdm-yalias] alias tables and clamps, the
  [duplicate menu placement function][cdm-menupos], the [`MENU_NOMOUSE` decision][cdm-nomouse].
- [`server-client.c`][sc-setoverlay] — [`server_client_overlay_range`][sc-overlay-range],
  [`server_client_check_mouse`][sc-checkmouse] (the trigger decoder),
  [modal pointer blocking and `modal_drag` capture][sc-modal],
  [the menu-key window-offset remap and the `UINT_MAX` sentinel][sc-menukey-remap],
  [the pre-overlay theme-report branch][sc-theme], [the consume-everything dispatch][sc-dispatch],
  [menu cursor placement][sc-cursor].
- [`screen-redraw.c`][sr-header] — the scene design comment,
  [`redraw_get_cell_type`][sr-celltype], [`redraw_mark_menu`][sr-markmenu],
  [`redraw_compare_data`][sr-compare], [`redraw_build_cells`][sr-build],
  [`redraw_make_scene`][sr-scene], [`redraw_invalidate_scene`][sr-invalidate],
  [`redraw_get_scene`][sr-getscene].
- [`window-visible.c`][wv-ranges] — `window_visible_ranges`, the `found_self` gate and the
  four interval-subtraction cases.
- [`window.c`][win-setactive] — modal refusal in `window_set_active_pane`,
  [`window_get_active_at`][win-activeat], [modal zoom push/pop][win-modalzoom],
  [z-order insertion after a modal][win-addpane], [focus restoration][win-lostpane],
  [the scrollbar close-delay timer][win-scrollbar-timer],
  [focus suppression while an overlay or menu is up][win-focus].
- [`window-panes.c`][wp-find] — `window_panes_find_pane`, a reverse-order hit test over a flat
  derived list.
- [`cmd-join-pane.c`][join-place] — `cmd_join_pane_place`, the thirteen named positions and six
  z-order verbs; [`layout.c`][layout-cascade] — cascade defaults;
  [`tmux.h`][layout-geometry] — `struct layout_geometry` with signed offsets.
- [`tty.c`][tty-overlay-range] — `tty_check_overlay_range`;
  [the partially obstructed wide character][tty-widechar];
  [`tty-draw.c`][ttydraw-padding] — the padding clear at a clip boundary.
- [`screen-write.c`][sw-borderset] — `screen_write_box_border_set`;
  [`screen_write_hline`][sw-hline] (tee cell types); [`screen_write_menu`][sw-menu];
  [`screen_write_box`][sw-box]. [`status.c`][status-message] — `status_message_set` delay
  semantics.
- [`tmux.1`][man-pos] — the position-word table; [the stale oversized-menu sentence][man-toolarge].
- Regression scripts: [`regress/menu-mouse.sh`][regress-menumouse] (the only statement of the
  bottom-edge convention), [`regress/modal-pane.sh`][regress-modal] (modal pointer blocking and
  the surviving prefix table), [`regress/screen-redraw-menus.sh`][regress-menus] (oversized
  menus are clipped, not refused).
- Commits: [`1a02c995`][c-panes] (overlays are being removed), [`ad6832e6`][c-menus] (menus
  become window-owned), [`95afd754`][c-scene] (the screen-redraw rewrite that introduced the
  scene), [`824a0729`][c-redrawoverlay] (do not redraw overlays unless asked),
  [`ecbf8d76`][c-styles] (re-evaluate styles on each draw), [`347baa6f`][c-menuloop]
  (all-disabled menu navigation guard), [`7cee982f`][c-cursor] (cursor on the selected item),
  [`e242da16`][c-clipstatus] (clip the status line against an open popup).

Related pages in this catalog: [index][index], [concepts][concepts], [comparison][comparison],
[features people forget][features], [the sparkles baseline][baseline], [the proposal][proposal].
Sibling terminal subjects: [Neovim floats][neovim], [nui.nvim][nui],
[nvim completion menus][nvimcmp], [Notcurses][notcurses], [Ratatui][ratatui], [Textual][textual],
[Helix][helix], [Turbo Vision][turbovision], [Emacs posframe][posframe]. Related trees:
[window-system integration][wsi], [UI layout][uilayout], [toolkit specs][uispec],
[input spec][inputspec], [state machines][stmspec], [backends][backendspec].

<!-- References -->

[repo]: https://github.com/tmux/tmux
[popup-c]: https://github.com/tmux/tmux/blob/851c5a933d4838c32ad06c248b2ba975d106149c/popup.c#L29
[popup-styles]: https://github.com/tmux/tmux/blob/851c5a933d4838c32ad06c248b2ba975d106149c/popup.c#L95
[popup-mode]: https://github.com/tmux/tmux/blob/851c5a933d4838c32ad06c248b2ba975d106149c/popup.c#L186
[popup-resize]: https://github.com/tmux/tmux/blob/851c5a933d4838c32ad06c248b2ba975d106149c/popup.c#L285
[popup-drag]: https://github.com/tmux/tmux/blob/851c5a933d4838c32ad06c248b2ba975d106149c/popup.c#L324
[popup-key]: https://github.com/tmux/tmux/blob/851c5a933d4838c32ad06c248b2ba975d106149c/popup.c#L382
[popup-display]: https://github.com/tmux/tmux/blob/851c5a933d4838c32ad06c248b2ba975d106149c/popup.c#L560
[menu-c]: https://github.com/tmux/tmux/blob/851c5a933d4838c32ad06c248b2ba975d106149c/menu.c#L26
[menu-additem]: https://github.com/tmux/tmux/blob/851c5a933d4838c32ad06c248b2ba975d106149c/menu.c#L96
[menu-cursor]: https://github.com/tmux/tmux/blob/851c5a933d4838c32ad06c248b2ba975d106149c/menu.c#L287
[menu-key]: https://github.com/tmux/tmux/blob/851c5a933d4838c32ad06c248b2ba975d106149c/menu.c#L341
[menu-nav]: https://github.com/tmux/tmux/blob/851c5a933d4838c32ad06c248b2ba975d106149c/menu.c#L396
[menu-resize]: https://github.com/tmux/tmux/blob/851c5a933d4838c32ad06c248b2ba975d106149c/menu.c#L541
[menu-display]: https://github.com/tmux/tmux/blob/851c5a933d4838c32ad06c248b2ba975d106149c/menu.c#L592
[cdm-popuppos]: https://github.com/tmux/tmux/blob/851c5a933d4838c32ad06c248b2ba975d106149c/cmd-display-menu.c#L95
[cdm-oversize]: https://github.com/tmux/tmux/blob/851c5a933d4838c32ad06c248b2ba975d106149c/cmd-display-menu.c#L118
[cdm-xalias]: https://github.com/tmux/tmux/blob/851c5a933d4838c32ad06c248b2ba975d106149c/cmd-display-menu.c#L236
[cdm-yalias]: https://github.com/tmux/tmux/blob/851c5a933d4838c32ad06c248b2ba975d106149c/cmd-display-menu.c#L260
[cdm-menupos]: https://github.com/tmux/tmux/blob/851c5a933d4838c32ad06c248b2ba975d106149c/cmd-display-menu.c#L292
[cdm-nomouse]: https://github.com/tmux/tmux/blob/851c5a933d4838c32ad06c248b2ba975d106149c/cmd-display-menu.c#L551
[sc-setoverlay]: https://github.com/tmux/tmux/blob/851c5a933d4838c32ad06c248b2ba975d106149c/server-client.c#L78
[sc-overlay-range]: https://github.com/tmux/tmux/blob/851c5a933d4838c32ad06c248b2ba975d106149c/server-client.c#L168
[sc-checkmouse]: https://github.com/tmux/tmux/blob/851c5a933d4838c32ad06c248b2ba975d106149c/server-client.c#L852
[sc-modal]: https://github.com/tmux/tmux/blob/851c5a933d4838c32ad06c248b2ba975d106149c/server-client.c#L1045
[sc-menukey-remap]: https://github.com/tmux/tmux/blob/851c5a933d4838c32ad06c248b2ba975d106149c/server-client.c#L1693
[sc-theme]: https://github.com/tmux/tmux/blob/851c5a933d4838c32ad06c248b2ba975d106149c/server-client.c#L1722
[sc-dispatch]: https://github.com/tmux/tmux/blob/851c5a933d4838c32ad06c248b2ba975d106149c/server-client.c#L1747
[sc-cursor]: https://github.com/tmux/tmux/blob/851c5a933d4838c32ad06c248b2ba975d106149c/server-client.c#L2135
[sr-header]: https://github.com/tmux/tmux/blob/851c5a933d4838c32ad06c248b2ba975d106149c/screen-redraw.c#L38
[sr-celltype]: https://github.com/tmux/tmux/blob/851c5a933d4838c32ad06c248b2ba975d106149c/screen-redraw.c#L384
[sr-markmenu]: https://github.com/tmux/tmux/blob/851c5a933d4838c32ad06c248b2ba975d106149c/screen-redraw.c#L849
[sr-compare]: https://github.com/tmux/tmux/blob/851c5a933d4838c32ad06c248b2ba975d106149c/screen-redraw.c#L877
[sr-build]: https://github.com/tmux/tmux/blob/851c5a933d4838c32ad06c248b2ba975d106149c/screen-redraw.c#L936
[sr-scene]: https://github.com/tmux/tmux/blob/851c5a933d4838c32ad06c248b2ba975d106149c/screen-redraw.c#L969
[sr-invalidate]: https://github.com/tmux/tmux/blob/851c5a933d4838c32ad06c248b2ba975d106149c/screen-redraw.c#L1064
[sr-getscene]: https://github.com/tmux/tmux/blob/851c5a933d4838c32ad06c248b2ba975d106149c/screen-redraw.c#L1079
[wv-ranges]: https://github.com/tmux/tmux/blob/851c5a933d4838c32ad06c248b2ba975d106149c/window-visible.c#L51
[win-focus]: https://github.com/tmux/tmux/blob/851c5a933d4838c32ad06c248b2ba975d106149c/window.c#L672
[win-setactive]: https://github.com/tmux/tmux/blob/851c5a933d4838c32ad06c248b2ba975d106149c/window.c#L711
[win-activeat]: https://github.com/tmux/tmux/blob/851c5a933d4838c32ad06c248b2ba975d106149c/window.c#L805
[win-modalzoom]: https://github.com/tmux/tmux/blob/851c5a933d4838c32ad06c248b2ba975d106149c/window.c#L976
[win-addpane]: https://github.com/tmux/tmux/blob/851c5a933d4838c32ad06c248b2ba975d106149c/window.c#L1021
[win-lostpane]: https://github.com/tmux/tmux/blob/851c5a933d4838c32ad06c248b2ba975d106149c/window.c#L1058
[win-scrollbar-timer]: https://github.com/tmux/tmux/blob/851c5a933d4838c32ad06c248b2ba975d106149c/window.c#L2510
[wp-find]: https://github.com/tmux/tmux/blob/851c5a933d4838c32ad06c248b2ba975d106149c/window-panes.c#L1017
[join-place]: https://github.com/tmux/tmux/blob/851c5a933d4838c32ad06c248b2ba975d106149c/cmd-join-pane.c#L68
[layout-cascade]: https://github.com/tmux/tmux/blob/851c5a933d4838c32ad06c248b2ba975d106149c/layout.c#L1742
[layout-geometry]: https://github.com/tmux/tmux/blob/851c5a933d4838c32ad06c248b2ba975d106149c/tmux.h#L1560
[tty-overlay-range]: https://github.com/tmux/tmux/blob/851c5a933d4838c32ad06c248b2ba975d106149c/tty.c#L1511
[tty-widechar]: https://github.com/tmux/tmux/blob/851c5a933d4838c32ad06c248b2ba975d106149c/tty.c#L2046
[ttydraw-padding]: https://github.com/tmux/tmux/blob/851c5a933d4838c32ad06c248b2ba975d106149c/tty-draw.c#L183
[sw-borderset]: https://github.com/tmux/tmux/blob/851c5a933d4838c32ad06c248b2ba975d106149c/screen-write.c#L722
[sw-hline]: https://github.com/tmux/tmux/blob/851c5a933d4838c32ad06c248b2ba975d106149c/screen-write.c#L758
[sw-menu]: https://github.com/tmux/tmux/blob/851c5a933d4838c32ad06c248b2ba975d106149c/screen-write.c#L824
[sw-box]: https://github.com/tmux/tmux/blob/851c5a933d4838c32ad06c248b2ba975d106149c/screen-write.c#L875
[status-message]: https://github.com/tmux/tmux/blob/851c5a933d4838c32ad06c248b2ba975d106149c/status.c#L340
[man-pos]: https://github.com/tmux/tmux/blob/851c5a933d4838c32ad06c248b2ba975d106149c/tmux.1#L8185
[man-toolarge]: https://github.com/tmux/tmux/blob/851c5a933d4838c32ad06c248b2ba975d106149c/tmux.1#L8220
[regress-menumouse]: https://github.com/tmux/tmux/blob/851c5a933d4838c32ad06c248b2ba975d106149c/regress/menu-mouse.sh#L57
[regress-modal]: https://github.com/tmux/tmux/blob/851c5a933d4838c32ad06c248b2ba975d106149c/regress/modal-pane.sh#L199
[regress-menus]: https://github.com/tmux/tmux/blob/851c5a933d4838c32ad06c248b2ba975d106149c/regress/screen-redraw-menus.sh#L126
[c-panes]: https://github.com/tmux/tmux/commit/1a02c9957ca3d7c49f2756a794dce645a8af4f12
[c-menus]: https://github.com/tmux/tmux/commit/ad6832e6972663c3aafad890ce983eb213401b7f
[c-scene]: https://github.com/tmux/tmux/commit/95afd7549c564c6584fad989947e2fddceb5fc87
[c-redrawoverlay]: https://github.com/tmux/tmux/commit/824a07290f853a97219ee2624a46c0aada246efb
[c-styles]: https://github.com/tmux/tmux/commit/ecbf8d76d0df0dcc3c05ea59e280de1b15b149c3
[c-menuloop]: https://github.com/tmux/tmux/commit/347baa6f3ebded07e664d534a0d04f661039bedb
[c-cursor]: https://github.com/tmux/tmux/commit/7cee982f909d29e7331d35bd9c21d337688b9ea1
[c-clipstatus]: https://github.com/tmux/tmux/commit/e242da168bb6d50c687ccd1897b82c1d282a651a
[index]: ./index.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[features]: ./features-people-forget.md
[baseline]: ./sparkles-baseline.md
[proposal]: ./proposal.md
[neovim]: ./neovim-floats.md
[nui]: ./nui.md
[nvimcmp]: ./nvim-completion.md
[notcurses]: ./notcurses.md
[ratatui]: ./ratatui.md
[textual]: ./textual.md
[helix]: ./helix.md
[turbovision]: ./turbo-vision.md
[posframe]: ./emacs-posframe.md
[wsi]: ../window-system-integration/index.md
[uilayout]: ../ui-layout/index.md
[uispec]: ../../specs/ui/index.md
[inputspec]: ../../specs/ui/input.md
[stmspec]: ../../specs/ui/state-machines.md
[backendspec]: ../../specs/ui/backends.md
