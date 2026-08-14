# Wayland `xdg_positioner` / `xdg_popup` (Wayland protocol IDL)

A wire protocol in which the client never computes a position: it builds a small
value describing the rules, and the compositor returns four integers.

| Field         | Value                                                                                                                                                                                                  |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Language      | XML (Wayland protocol IDL). **Specification only** — this repository contains protocol XML plus scanner/compile tests; no compositor implementation was read                                           |
| License       | MIT                                                                                                                                                                                                    |
| Repository    | [`gitlab.freedesktop.org/wayland/wayland-protocols`][repo]                                                                                                                                             |
| Documentation | The `<description>` blocks inside the protocol XML are the normative documentation; see also the repository [`README.md`][readme] for the stable/staging/experimental tiers                            |
| Category      | Protocol-level placement algebra                                                                                                                                                                       |
| Surface model | OS popup — a separate compositor-managed `wl_surface` carrying the `xdg_popup` role; the placement decision happens out of process                                                                     |
| Revision read | `afb614d5fcbd02d261a6ae91920aa91cf3915a8a` (wayland-protocols 1.49; `xdg_positioner` interface version 7, last functional change in version 3; `xx_input_popup_positioner_v1` version 1, experimental) |

> [!IMPORTANT]
> This is a **specification** subject, not an implementation reading. The placement
> code lives in mutter, kwin, wlroots and smithay, none of which are in this clone.
> Every algorithmic statement below is what the normative prose **requires**, not
> what any compositor was observed to do. The repository's `tests/` directory runs
> `wayland-scanner` over each XML file and compiles the generated headers
> (`tests/scan.sh`, `tests/meson.build`); `grep -rn positioner tests/` returns
> nothing, so there is no executable conformance oracle for the algebra at this SHA.

## Overview

### What it solves

A Wayland client cannot place its own popup. It does not know its own absolute
position on screen, does not know the output layout, and does not know where the
panels are. `xdg_positioner` exists so that placement can be **described** by the
party that knows the widget semantics and **computed** by the party that knows the
screen. The description is a small record: a surface size, an [anchor rect][c-anchor]
inside the parent's window geometry, an anchor point on that rect, a
[gravity][c-gravity] for the popup, a bitmask of permitted
[constraint adjustments][c-adjust], an integer offset, and — since interface
version 3 — a reactive flag plus a description of the parent's _future_ geometry.

The record's value semantics are stated normatively, on the wire, at
`stable/xdg-shell/xdg-shell.xml:136-139`:

> At the time of the request, the compositor makes a copy of the rules specified by
> the xdg_positioner. Thus, after the request is complete the xdg_positioner object
> can be destroyed or reused; further changes to the object will have no effect on
> previous usages.

That sentence is the subject's central contribution to this survey: the positioner
object is a mutable builder for an immutable value, and [placement][c-placement] is
a function of that value plus compositor-private state. Completeness is checked at
use time rather than at build time — "it must have a non-zero size set by
`set_size`, and a non-zero anchor rectangle set by `set_anchor_rect`"
(`xdg-shell.xml:141-144`), enforced by `xdg_wm_base.error.invalid_positioner`
(`:51-52`), so the placement function never sees a partial input.

### Design philosophy

The philosophy is legible in the git history, because every mistake was fixed in
public. xdg-shell v5 placed popups at an absolute `(x, y)` with an implicit
[grab][c-grab] (`unstable/xdg-shell/xdg-shell-unstable-v5.xml:91-112`, `:557-566`).
Commit [`dee23fd`][c-dee23fd] introduced the positioner as "a method for declarative
positioning of child surfaces"; commit [`eef4b95`][c-eef4b95] split grabbing out of
the role, so that one role serves "menus, popovers, tooltips and other similar user
interface concepts" (`xdg-shell.xml:1249-1251`) with the only per-kind
differentiation being whether `xdg_popup.grab` is called. Stabilisation then
replaced v6's anchor/gravity bitfields with nine-entry enums, because
[`6bff136`][c-6bff136] records that "Bitfields allowed for impossible combinations
of anchor edges, such as being on the left and right edge" — a
make-illegal-states-unrepresentable refactor performed on a wire format.

What the design deliberately omits is as instructive as what it specifies. The
boundary itself is left open, at `xdg-shell.xml:245-248`:

> Whether a surface is considered 'constrained' is left to the compositor to
> determine. For example, the surface may be partly outside the compositor's defined
> 'work area', thus necessitating the child surface's position be adjusted until it
> is entirely inside the work area.

So `place()` here is pure in `(positioner, parentGeometry, workArea)`, but the third
argument is unspecified — the difference between _pure_ and _deterministic across
implementations_. Timing, hover, arrows, animation, modality and accessibility are
absent entirely; see dimensions 6, 7, 4, 14, 11 and 13 below.

## How it works

Three objects, in sequence.

1. **Build the value.** `xdg_wm_base.create_positioner` yields a builder; a series
   of `set_*` requests fills it in. Nothing is computed yet.
2. **Use it.** `xdg_surface.get_popup(parent, positioner)` (`xdg-shell.xml:495-509`)
   snapshots the builder into the compositor's own copy and creates the popup. The
   builder may be destroyed or reused immediately.
3. **Receive the answer.** The compositor sends `xdg_popup.configure(x, y, width,
height)` followed by `xdg_surface.configure(serial)`; the client acks the serial
   and commits. Nothing takes effect until `wl_surface.commit`.

```xml
<!-- stable/xdg-shell/xdg-shell.xml:239-256 (constraint_adjustment, abridged) -->
<enum name="constraint_adjustment" bitfield="true">
    <!-- The adjustments can be combined, according to a defined precedence:
         1) Flip, 2) Slide, 3) Resize. -->
    <entry name="none"     value="0"/>
    <entry name="slide_x"  value="1"/>
    <entry name="slide_y"  value="2"/>
    <entry name="flip_x"   value="4"/>
    <entry name="flip_y"   value="8"/>
    <entry name="resize_x" value="16"/>
    <entry name="resize_y" value="32"/>
</enum>
```

The evaluation the compositor is required to perform:

```text
place(positioner, parentGeometry, workArea) -> rect

    p    := anchorPoint(positioner.anchorRect, positioner.anchor)
    rect := (p + positioner.offset) - gravityShift(positioner.size, positioner.gravity)

    for each axis constrained against workArea, in the order Flip, Slide, Resize:
        if the corresponding bit is set for that axis:
            rect := adjust(rect)          # see dimension 3 for each adjustment

    enforce: rect intersects with, or is at least partially adjacent to, the parent
```

`anchorPoint` picks a corner for the four corner values, the midpoint of the named
edge for the four edge values, and the rect centre for `none` (`:200-211`).
`gravityShift` is the mirror operation on the popup's own box: gravity `right` puts
the popup's **left** edge on the anchor point; gravity `none` on an axis centres the
popup on that axis (`:225-233`). The offset is applied _before_ constraint testing —
"The offset position of the surface is the one used for constraint testing"
(`:356-358`) — which is what makes an arrow gap survive a flip.

## The analysis spine

### 1. Anchor model

The anchor is a **rect plus an enum**, never an element and never a live reference.
`set_anchor_rect(x, y, w, h)` (`:169-181`) is expressed in the parent's _window
geometry_ space as defined by `xdg_surface.set_window_geometry` (`:511-553`), i.e.
the visible-bounds space, so shadows and client-side-decoration padding are excluded
before placement runs. The rect "may not extend outside the window geometry of the
positioned child's parent surface" (`:176-178`): the anchor is clamped to the
**parent**, not to the screen, and a [virtual anchor][c-virtual] detached from the
parent is not representable. A zero-size rect is explicitly legal — only a negative
size raises `invalid_input` (`:180`) — and commit [`e49a2c0`][c-e49a2c0] added that
so a client can anchor to a coordinate rather than to a pixel; the point anchor is
the degenerate rect.

Multi-rect (text-range) anchors do not exist. The nearest thing in the tree is
`zwp_text_input_v3.set_cursor_rectangle`
(`unstable/text-input/text-input-unstable-v3.xml:266-300`), a single rect the client
publishes so the compositor can place the IME popup, with a two-stage commit so "the
compositor [can] position the input method popup in the same frame as the contents of
the text on the surface are updated" (`:296-298`). Many-triggers-one-overlay is
served by `xdg_popup.reposition` (`:1368-1396`): the same popup object, a new
positioner.

> [!NOTE]
> The newest positioner in this tree, `xx_input_popup_positioner_v1`, **drops**
> `set_anchor_rect` entirely (`experimental/xx-input-method/xx-input-method-v2.xml:670-720`):
> the anchor is the compositor-owned text cursor area, and it is _reported back_ to
> the client instead of being supplied by it. Reading that as the design direction —
> "the anchor is a value owned by whoever knows it; the placee is told about it" — is
> an inference from two data points in one tree, not a stated goal.

**Algorithm.** `anchorPoint(rect, anchor)`: for the four corner values, the named
corner; for the four edge values, the midpoint of that edge; for `none`, the centre.
Per axis, `x = rect.x + (0 | rect.w/2 | rect.w)`. The whole anchor is therefore the
5-tuple `(x, y, w, h, anchorEnum)` — four integers and one nine-value enum.

**Where the behavior lives.** The client builds the value; the compositor evaluates
it. Nothing in this repository evaluates anything.

**Degradation.** A rect of integers plus a nine-value enum needs no OS window, no
hover, no script, no sub-cell precision and no key release, so the model survives
every target intact; on a script-free HTML target it is even emittable at build time
as a static box. The one part that does not carry over is "anchor rect clamped to the
parent's window geometry" when the parent is a scroll viewport, because the protocol
has no scroll or [clipping-boundary][c-boundary] concept at all (dimension 3).

### 2. Placement model

Placement is anchor point + gravity + offset, then constraint adjustment. Gravity
reuses the same nine-entry enum as anchor but applies it to the popup, so one value
encodes both the side and the cross-axis alignment: `top` means "above, horizontally
centred", `top_left` means "up and to the left of the point" (`:225-233`). There is
no separate align axis and no preferred-placement _list_ — the fallback order is not
data, it is the fixed precedence at `:250-251`:

> The adjustments can be combined, according to a defined precedence: 1) Flip, 2)
> Slide, 3) Resize.

Deliberately absent: RTL and writing modes (the enums are physical `top`/`bottom`/
`left`/`right`, never start/end), viewport padding, caller-supplied boundaries,
safe-area insets, multi-monitor selection, and any notion of the work area as a
client-visible value. Two experimental protocols are filling those holes from
outside xdg-shell: `xx_zone_v1` exposes an actual placeable area with a `size` event
and a `position`/`position_failed` feedback pair
(`experimental/xx-zones/xx-zones-v1.xml:228-361`), and `xx_cutouts_v1` reports
notches and rounded corners as boxes and radii in surface-local coordinates plus a
`set_unhandled` array (`experimental/xx-cutouts/xx-cutouts-v1.xml:164-229`).

**Algorithm.** `unconstrained(P) = anchorPoint(P.rect, P.anchor) + P.offset −
gravityShift(P.size, P.gravity)`, then the Flip → Slide → Resize sweep, each step
gated by its own bit and its own axis, each testing the whole rect against the
compositor's work area, and finally the intersect-or-adjacent post-condition at
`:130-132`.

**Where the behavior lives.** Entirely in the compositor. The XML is the interface.

**Degradation.** Every argument is a plain `int` in surface-local logical
coordinates — never `wl_fixed`, never a float, never a percentage — so the model
transposes into integer cells with no rounding anywhere. No hover, no OS window and
no key release participate. Without script the flip/slide search cannot run at emit
time, so only the unconstrained branch is emittable; the adjustments degrade to
`none`, which the protocol itself defines as a legal, fully specified value
(`:253-257`) rather than an error. On Android the soft-keyboard inset is exactly the
"work area" the protocol refuses to expose, and `xx-zones` / `xx-cutouts` are the
tree's own acknowledgement that it must become an explicit input.

### 3. Collision & geometry engine

Overflow detection exists; its boundary does not. There is no clipping-ancestor
discovery, no scroll container, no transform or zoom awareness and no observer
machinery, because the popup is a **sibling surface** in the compositor's scene
graph rather than a descendant of the anchor in a clipped box tree. Tracking is
handled by two mechanisms instead of observers:

- **`set_reactive`** (`:370-379`) — "the surface is reconstrained if the conditions
  used for constraining changed, e.g. the parent window moved", after which the
  compositor pushes `xdg_popup.configure` + `xdg_surface.configure`. It is a
  subscription, not a poll.
- **Explicit `reposition`** (`:1368-1396`) with `set_parent_size` (`:381-395`) and
  `set_parent_configure` (`:397-406`), which let a client place against the parent's
  _future, not-yet-applied_ geometry. Commit [`26f494e`][c-26f494e] gives the
  motivating case: "an interactive resize where both the toplevel position and the
  relative popup position changes".

The known defect is admitted in the protocol's own history, in commit
[`ebbad29`][c-ebbad29]:

> Implicit repositioning by itself is racy regarding inter-surface synchronization of
> applied state. Inter-surface synchronization is deliberately left out of xdg-shell,
> and left to be handled externally.

There is no [top layer][c-toplayer] concept; stacking is creation order
(`:1265-1266`). Fractional scaling is out of band
(`staging/fractional-scale/fractional-scale-v1.xml:26-45`); positioner coordinates
stay integral logical units regardless.

**Algorithm.** `constrained(rect, workArea)` is a compositor-private predicate over
"partly outside positioning boundaries set by the compositor" (`:333-335`). For each
axis with bits set, in the order flip, slide, resize: compute the candidate; accept
it if unconstrained; for flip, revert to the pre-flip position if it is not
(`:296-299`, `:312-314`); for slide, run the two-phase directional walk; for resize,
shrink until unconstrained. Resize is documented as the last resort in commit
[`c09e899`][c-c09e899].

**Where the behavior lives.** The compositor's scene graph. The client's only
geometry duty is publishing its window geometry and the anchor rect; it measures
nothing about the screen.

**Degradation.** Most of the DOM-shaped work in this dimension is created by the
substrate, and a toolkit that owns one surface and a flat display list already knows
every rect, so overflow detection is arithmetic rather than discovery. What has to
be reimplemented is the reactive re-place-on-change subscription — which in an
immediate-mode frame loop is simply re-running `place()` each frame — and the
future-parent-geometry idea, which becomes "place against the layout you are about
to paint, not the one you painted last frame". Without script the whole dimension
collapses to the `none` adjustment. The inter-surface race is structurally
impossible in a single surface that presents atomically.

### 4. Arrow / caret geometry

xdg-shell has **no arrow concept** — no arrow size, no centre offset, no corner
clamping, no [transform origin][c-origin]. The problem is nevertheless acknowledged
twice, from opposite ends.

As an **input**, `set_offset`'s documented use case is "placing a popup menu on top
of a user interface element, while aligning the user interface element of the parent
surface with some user interface element placed somewhere in the popup surface"
(`:360-362`) — arrow alignment expressed as a client-computed integer nudge. It is
applied before constraint testing (`:356-358`) and survives a flip, because the flip
re-evaluates "given the original anchor rectangle and offset" (`:308-310`).

As an **output**, the newest positioner in the tree emits the anchor geometry as
data. `xx_input_popup_surface_v2.start_configure`
(`experimental/xx-input-method/xx-input-method-v2.xml:530-545`, args `:578-585`)
carries `anchor_x`, `anchor_y`, `anchor_width`, `anchor_height`:

> The anchor\_\* arguments represent the geometry of the anchor to which the popup was
> attached, relative to the upper left corner of the popup's surface. Note that this
> makes anchor_x, anchor_y the reverse of the what they represent in xdg_popup.

Those four integers carry the side (the sign of `anchor_y`), the caret's coordinate
inside the popup (`anchor_x + anchor_width/2`) and everything a corner clamp needs.
The protocol's own worked example shows the anchor moving from `(10, -2, 5, 30)` to
`(-60, -2, 55, 30)` as the text cursor moves (`:501`, `:515`) — the popup's local
view of its own anchor, updated per configure sequence.

**Algorithm.** Arrow-as-data, given the configured popup rect `R` and the anchor rect
`A` in one coordinate space: the side is the axis and sign of
`anchorPoint(A) − centre(R)`; the arrow's position along the edge is
`anchorCentre − R.origin`, clamped inward by the corner radius plus half the arrow
width; the arrow is suppressible when the clamped position leaves `A`'s projection
onto that edge. Integer arithmetic on two rects, with no measurement.

**Where the behavior lives.** Nowhere in xdg-shell — the client's problem. In
`xx-input-method`, the compositor computes it and reports it.

**Degradation.** In a cell grid the arrow is one border cell carrying a directional
glyph (`▲▼◀▶`, or `┴┬┤├` when the border must connect), at the clamped column or
row; the geometry is the same integers and only the paint changes. Corner radius and
shadow do not exist on that target, so the corner clamp degenerates to the box's
first and last interior cell. Without script only the unflipped side can be baked
in, which is the same honest tier-0 answer as the protocol's own `none` adjustment.
No hover, sub-cell precision or key release is involved at any tier. What
`sparkles:ui` does with the arrow today is recorded in
[`./sparkles-baseline.md`][baseline].

### 5. Trigger semantics

The protocol has exactly one trigger concept: a **serial**. `xdg_popup.grab`
requires that "This request must be used in response to some sort of user action like
a button press, key press, or touch down event. The serial number of the event should
be passed as serial" (`:1301-1303`), naming the `wl_seat` as well. The same
construction appears on `xdg_toplevel.move` (`:756-759`), `resize`, and
`show_window_menu` (`:743-744`), and `staging/pointer-warp/pointer-warp-v1.xml:56`
reuses it as an authorisation check ("reject it if the enter serial is incorrect").

This is a capability-token design rather than a state machine: every delivered input
event carries a serial, quoting one proves _which_ user action you are acting on, and
the compositor validates it against its own history and may deny — in which case
"the popup will be immediately dismissed" (`:1298-1299`). Two triggers cannot race,
because a stale serial simply fails validation. Note that only the **grab** is
serial-gated: creating and mapping a non-grabbing popup (a tooltip) needs no user
action at all, which is precisely what commit [`eef4b95`][c-eef4b95] made
expressible. Hover, focus-visible, long-press and AT-driven triggers do not exist,
because the compositor cannot know what the client's widgets are. Pointer-type
distinction is available only indirectly, via `xdg_toplevel.move`'s note that "The
passed serial is used to determine the type of interactive move (touch, pointer,
etc)" (`:757-759`) — the serial carries provenance.

**Algorithm.** `grab(seat, serial)`: look the serial up in the per-seat event
history; if it is absent, expired or from another seat, deny and dismiss. Otherwise
install the grab and push the popup onto that seat's grab chain. There is no
client-side debounce and no combination logic.

**Where the behavior lives.** The compositor validates; the client chooses which
serial to quote. There is no library layer between them.

**Degradation.** Serial validation is a distributed-systems device that a
single-process toolkit does not need — it _is_ the event source, so "which event
opened this" is a direct value rather than a token. What transfers is the shape: an
open request should carry the causing event, so that a machine can reject an open
caused by an event a close already consumed. The protocol's own trigger vocabulary
is press/down-only ("button press, key press, or touch down"), i.e. already the
release-free subset — which matters on a terminal target, where keyboard key release
is not delivered even though pointer release is (see
[`./sparkles-baseline.md`][baseline]). Without script there are no serials and no
timers: the trigger becomes a CSS state and the grab is unrepresentable.

### 6. Timing

**Absent, structurally.** The compositor does not know which popups are tooltips, so
it cannot own delays: there is no initial delay, no close delay, no
[warm-up][c-warmup] or [cool-down][c-cooldown], no skip-delay group, no singleton
provider and no maximum display duration anywhere in the tree. The protocol's only
timing statements concern liveness (`xdg_wm_base.ping`/`pong`, `:104-121`, with an
`unresponsive` error at `:53-54`) and the fact that a compositor may dismiss a popup
on "a timeout" or a lid close (`:1293-1296`) — the compositor's timeout, over which
the client has no control and receives no explanation.

The interesting part is the partition rather than the gap: Wayland assigns geometry
and the dismissal chain to the compositor and everything time-shaped to the toolkit.
Reading that as a deliberate factoring — a placement value that stays free of timing
— is an inference from the absence, but the absence is total and the value's other
properties (dimension 15) are consistent with it.

**Algorithm.** Not applicable. The one transferable precedent is `ping`/`pong`: a
timeout has a _defined_ outcome (an error) rather than silence.

**Where the behavior lives.** Nowhere in the protocol.

**Degradation.** Without script there are no timers at all, so the entire dimension
is unavailable at that tier and the honest degradation is instant open and instant
close on `:hover`. A terminal target has timers and hover and is served. Android has
no hover, so the open-delay branch is dead and a touch gesture must substitute. None
of this is informed by the subject beyond the negative lesson.

### 7. Interactive hover / travel

There is no [safe polygon][c-safe], no menu-aim, no interactive border and no
trajectory heuristic — but the enabling primitive is here, at `:1325-1328`:

> During a popup grab, the client owning the grab will receive pointer and touch
> events for all their surfaces as normal (similar to an "owner-events" grab in X11
> parlance), while the top most grabbing popup will always have keyboard focus.

Commit [`3dab2f1`][c-3dab2f1] clarified this precisely so that "users can navigate
through submenus and other nested popup windows without having to dismiss the topmost
popup" — wording that survives verbatim from v5
(`unstable/xdg-shell/xdg-shell-unstable-v5.xml:571-575`). The protocol's contribution
to hover travel is therefore a guarantee: pointer motion between the trigger, the
menu, the gap and every submenu stays inside **one** event-routing domain. A second,
subtler contribution is the intersect-or-adjacent post-condition at `:130-132` — a
compositor may never open a gap the pointer cannot cross, because the popup is
required to touch or overlap its parent.

**Algorithm.** Owner-events routing: while a grab chain is active, all pointer and
touch events for _any_ surface of the grabbing client route to that client normally;
only other clients are excluded. Keyboard is not owner-events; it is hard-bound to
the topmost grabbing popup.

**Where the behavior lives.** The compositor, for routing. The heuristics on top live
nowhere in the protocol.

**Degradation.** A single-surface toolkit is natively owner-events — one surface, one
hit list — so travel across the gap between trigger and popup needs no grab, which
matters because there is no native grab available to it. What corridor shape belongs
on top is argued in [`./features-people-forget.md`][forget] and
[`./comparison.md`][comparison]; the protocol supplies only the geometric
precondition. Under touch there is no hover at all and submenus must open on tap,
which the press-only trigger vocabulary of dimension 5 already fits. Without script,
only a CSS-adjacency approximation survives.

### 8. Dismissal

Dismissal is compositor-driven, cascading and **reasonless**. The entire
client-facing signal is `popup_done`, an event with no arguments (`:1358-1363`); the
causes are enumerated only in prose on `grab`: "the user clicking outside the
surface, using the keyboard, or even locking the screen through closing the lid or a
timeout" (`:1293-1296`). A client therefore cannot distinguish Escape from
click-outside from screen-lock, which makes "restore focus only when dismissed by the
keyboard" unimplementable at this layer.

The cascade, by contrast, is fully specified (`:1305-1316`):

> Nested popups must be destroyed in the reverse order they were created in, e.g. the
> only popup you are allowed to destroy at all times is the topmost one.
>
> When compositors choose to dismiss a popup, they may dismiss every nested grabbing
> popup as well. When a compositor dismisses popups, it will follow the same
> dismissing order as required from the client.

The ordering is backed by a protocol error rather than a convention
(`xdg_wm_base.error.not_the_topmost_popup`, `:45-46`, `:1285-1286`). The grab returns
to the parent when the topmost is destroyed (`:1318-1319`), and "If the parent is a
grabbing popup which has already been dismissed, this popup will be immediately
dismissed" (`:1321-1322`). Opening a child never dismisses its parent — that is the
point of the chain. Same-client [light dismiss][c-light] is explicitly the client's
job: "Clients that want to dismiss the popup when another surface of their own is
clicked should dismiss the popup using the destroy request" (`:1260-1263`), which
follows from the grab being owner-events. Anchor-hidden, navigation and scroll are
not dismissal causes at all: a reactive popup is re-placed, never closed. A
non-grabbing popup receives **no dismissal service whatsoever** and lives until the
client destroys it.

**Algorithm.** `Chain(seat)` is a stack of grabbing popups rooted at a toplevel.
`dismissTo(k)`: for `i` from the top down to `k`, send `popup_done(i)` and unmap. A
client `destroy(i)` is legal only when `i` is the top, else it is a protocol error.
On destroying the top, the grab reverts to the popup below it if that one held one.

**Where the behavior lives.** The compositor owns detection and the cascade; the
client owns only same-client outside-clicks and explicit destruction.

**Degradation.** The cascade transfers to an overlay stack with a parent index,
walked leaf-to-root, and needs no OS window. Escape must fire on press on a terminal
target, which costs nothing because the protocol never mentions releases either. A
system back key maps onto "only the topmost", one level per press. Without script,
dismissal is limited to whatever CSS state opened the overlay — there is no
outside-click and no cascade beyond nesting the markup. The reasonless `popup_done`
is the part worth _not_ copying: a toolkit that is also the compositor gets the cause
for free, and both focus restoration (dimension 9) and adaptive behaviour
(dimension 12) want it.

### 9. Focus

Focus is specified in one sentence, and only for grabbing popups: "the top most
grabbing popup will always have keyboard focus" (`:1327-1328`), while pointer and
touch stay owner-events. Three consequences follow. Keyboard focus tracks the chain
automatically — opening a submenu moves it, dismissing the leaf returns it, and no
client code participates. A non-grabbing popup never takes keyboard focus, which is
the correct tooltip semantic obtained by simply not calling `grab`. And there is no
[focus scope][c-scope], no trap, no tab order, no initial-focus choice and no
restore-on-close, because all of that lives inside the client's single `wl_keyboard`
focus. There is no pointer-opened versus keyboard-opened distinction anywhere.

The tooltip / popover / menu / dialog distinction therefore exists in this protocol
as exactly two bits: grab or not, and `xdg_popup` versus `xdg_toplevel` +
`xdg_dialog`. Everything else that separates them lives above the window system.

**Algorithm.** `focus(seat)` = the topmost grabbing popup if the chain is non-empty,
else whatever toplevel had focus. Push on grab, pop on dismiss. This is containment
by _assignment_, not trapping: there is nothing to escape from, and Tab is a
client-internal matter.

**Where the behavior lives.** The compositor assigns; the client owns intra-surface
focus order.

**Degradation.** "The topmost overlay in the chain owns the keyboard" is a one-line
rule over an overlay stack and needs no OS window; it also yields tooltip ≠ menu from
a single flag. Any behaviour keyed to a keyboard _release_ (holding a modifier to
peek, releasing Alt to open a menu) is unavailable on a terminal target, and the
protocol never uses releases, so copying it costs nothing there. Without script,
`:focus-within` expresses containment but neither assignment nor restoration. Because
focus is a value in a toolkit's own state, a headless recording target can assert it
— which a Wayland client cannot do at all, since it never observes the chain's rule.

### 10. Layering & portals

This is the dimension where the subject is furthest from a single-surface toolkit,
and therefore most useful for separating API from substrate. A popup is a real,
separate `wl_surface` with its own buffer, composited above the parent. There is no
z-index and no stacking context: "A newly created xdg_popup will be stacked on top of
all previously created xdg_popup surfaces associated with the same xdg_toplevel"
(`:1265-1266`) — creation order **is** paint order. Ownership is a strict tree: "The
parent of an xdg_popup must be mapped ... before the xdg_popup itself" (`:1268-1269`);
`get_popup` takes the parent `xdg_surface` (`:495-509`) and accepts null only when "a
parent surface must be specified using some other protocol, before committing the
initial state" (`:500-501`), the escape hatch for cross-process parenting.

Clip escape is total and free, because the popup is a sibling surface rather than a
descendant — the capability that a portal in a clipped box tree exists to emulate.
That capability is a gift of the substrate and does not transfer.

**Algorithm.** Scene order: per toplevel, its popups in creation order, each above
the previous. Destruction is constrained to the top. There is no reparenting and no
reordering request; the tree is append-only at the leaf.

**Where the behavior lives.** The compositor's scene graph. The client's whole model
is the parent pointer it passed to `get_popup`.

**Degradation.** What is portable is creation-order stacking plus a strict parent
tree: append overlays to the display list after all normal content in open order, and
hit-test in reverse. What is not portable is clip escape — an overlay cannot leave
the surface, so the work area _is_ the surface, which makes flip and slide more
necessary in a small window than on a whole desktop. Both the Android and the
script-free HTML targets share that single-surface bound. The ordering rule itself is
directly assertable from a recorded display list.

### 11. Modality

`xdg_popup` has no [modality][c-modal] controls at all: no scrim, no dim, no
click-through flag, no input-blocking toggle, no accessibility modal bit. What it has
is the grab, which is a **routing** rule: other clients stop receiving pointer and
touch while the owning client keeps receiving everything (`:1325-1327`). A grabbing
popup is thus modal to the rest of the desktop and modeless within the application.

Real modality arrived years later, outside xdg-shell, and only as a hint
(`staging/xdg-dialog/xdg-dialog-v1.xml:87-97`):

> Hints that the dialog has "modal" behavior. ... Clients must implement the logic to
> filter events in the parent toplevel on their own. Compositors may choose any policy
> in event delivery to the parent toplevel, from delivering all events unfiltered to
> using them for internal consumption.

It also "has no effect on toplevels that are not attached to a parent toplevel"
(`:75-76`). That modality ended up as a presentation hint plus client-side
enforcement, on a separate ancillary object rather than on the anchored-overlay
primitive, is the shape this tree settled on; whether that generalises is argued in
[`./comparison.md`][comparison].

**Algorithm.** `grab`: exclude other clients from pointer and touch on this seat, and
bind the keyboard to the topmost popup. `set_modal`: no algorithm, only a hint.

**Where the behavior lives.** The compositor, for grab routing; entirely the client,
for actual modal event filtering.

**Degradation.** With no other clients and no native grab, the outward half of the
grab is meaningless and the inward half — the owning application keeps routing
normally — is already the default. What must be implemented is the same thing
Wayland makes its clients implement: filtering input against the parent, which in one
surface is a hit-test predicate ("if a modal overlay is open, the hit list stops at
its rect"). A scrim degrades on a cell grid to a dim attribute over the covered
cells, with the caveat that a cell-canvas fill blends only the background — see
[`./sparkles-baseline.md`][baseline]. Without script there is no way to block input
at all, so that tier simply has no modality, which matches xdg-shell.

### 12. Adaptive presentation

There is exactly one adaptive mechanism, and it is a surprising one: `resize_x` /
`resize_y`, "Resize the surface horizontally/vertically so that it is completely
unconstrained" (`:317-326`). Commit [`c09e899`][c-c09e899] gives the rationale: "In
order to get feedback of available space where a client can create its popup, let it
create requ[e]st that its popup rectangle being resized would it not fit within the
work area." The placer is permitted to change the placee's **size**, and the placee
must re-lay-out, because the new size arrives in `xdg_popup.configure` (`:1354-1355`)
and must be acked before it takes effect. Note the precedence: resize fires last,
only after flip and slide have failed (`:250-251`) — relocate first, adapt only when
relocation cannot help.

Everything else in this dimension is absent: no size classes, no touch-versus-hover
substitution, no teaching tips, no keyboard-driven relocation.
`xx_cutouts_v1.set_unhandled`
(`experimental/xx-cutouts/xx-cutouts-v1.xml:215-229`) is a second instance of the
same shape — the client declares which environmental constraints it could not
accommodate, and "the compositor might then try to reposition the surface in a way
that avoids these elements in a future configure sequence". A negotiation loop, not a
query.

**Algorithm.** If flip and slide were disabled or failed on an axis and the resize
bit is set for it, shrink the popup along that axis until the rect fits the work
area, report the new width and height in `configure`, and let the client re-lay-out
and ack.

> [!WARNING]
> The specification does not say **which edge moves** during a resize, nor a minimum
> size, nor what happens if shrinking to fit would produce a degenerate rect. A
> resized popup's final origin is therefore implementation-defined even given a known
> work area.

**Where the behavior lives.** The compositor decides; the client re-lays-out. Nothing
in between.

**Degradation.** On a small surface — a terminal of a few dozen columns — shrink-to-
fit is the common outcome rather than the rare one, so `place()` must be allowed to
return a size smaller than requested and the content view must accept a size it did
not ask for. That is an API-shape decision, and this subject is primary-source
justification for taking it early rather than retrofitting. A soft-keyboard inset is
the same case, and the tree's own answer (`xx-zones`, `xx-cutouts`) is that the inset
must be an _input_ to placement rather than something discovered afterwards. Without
measurement at emit time, resize cannot fire and the honest fallback is a static
maximum size.

### 13. Accessibility

**Completely absent, and the absence is itself the finding.** Nothing in xdg-shell
mentions roles, names, descriptions, screen readers, AT-SPI or WCAG; grepping this
repository at the pinned SHA finds no accessibility vocabulary in any
anchored-overlay protocol. Linux accessibility lives on D-Bus (AT-SPI2), maintained
elsewhere and not surveyed here — so the claim is that the _display protocol_
contains no accessibility vocabulary, not that Wayland desktops lack accessible
popups.

The consequence is that the placement algebra is fully decoupled from semantics: the
compositor positions an opaque rectangle and has no idea whether it is a tooltip, a
menu or a colour picker. The only adjacent signal is prose — `xdg_popup` names its
intended uses at `:1249-1251` ("menus, popovers, tooltips and other similar user
interface concepts"), which is documentation, not a machine-readable role. The
grab-or-not bit is the only distinction the primitive itself carries, and it carries
it because it changes focus and dismissal, which are mechanism rather than semantics.

**Algorithm.** Not applicable.

**Where the behavior lives.** Nowhere in this repository.

**Degradation.** A cell grid can expose almost nothing structural, so its honest
answer resembles Wayland's: the primitive exposes geometry, and any semantics must
ride on the painted text in reading order. A GPU canvas has no accessibility tree
either, and an Android `NativeActivity` exposes none without extra JNI work. A
script-free HTML target is the one tier that _can_ carry role and description
attributes — which argues for a semantic layer that emits them on that backend and
drops them elsewhere, rather than a primitive that pretends to be accessible
everywhere. What `sparkles:ui` has today (nothing, by design) is recorded in
[`./sparkles-baseline.md`][baseline].

### 14. Animation

**Absent.** No transform origin, no side or align metadata, no enter/exit hooks, no
reduced-motion signal, no timing curves. A compositor may animate a popup's
appearance however it likes and never tells the client. Critically,
`xdg_popup.configure` emits only `x`, `y`, `width`, `height` (`:1341-1355`) — there
is no field naming the applied adjustment.

A client _can_ recover the chosen side by recomputing the unconstrained position from
the value it supplied and comparing; but because it does not know the work area, it
cannot distinguish a flip from a slide that travelled past the anchor in ambiguous
cases. That recovery is an inference about what is derivable, not a documented
capability.

The one piece of animation-adjacent infrastructure is the **reposition token**:
`xdg_popup.reposition(positioner, token)` → `xdg_popup.repositioned(token)` →
`configure` → `xdg_surface.configure` (`:1368-1417`), which commit
[`26f494e`][c-26f494e] introduced "so that a client may determine for which reposition
request the compositor has sent configure events". That is correlation metadata for
in-flight placement changes — exactly the problem an animating toolkit has when a
reposition lands mid-transition — and "If multiple reposition requests are sent, the
compositor may skip all but the last one" (`:1382-1383`).

**Algorithm.** Not applicable for animation. For correlation: the client sends token
`t`; the compositor replies `repositioned(t)` immediately before the configure
carrying the new geometry, and the pair applies atomically on ack.

**Where the behavior lives.** Nowhere. Compositor-side visual effects are invisible
to the protocol.

**Degradation.** The lesson is negative and strong: emit the geometry metadata that
`xdg_popup.configure` omits. The resolved side, the applied adjustments and the
anchor rect in overlay-local coordinates are, respectively, the transform origin on a
GPU backend, the border cell that gets the arrow glyph on a cell backend, and the
thing that makes a placement decision assertable on a headless recording target at
all. Without them a test can assert only a rect and must re-derive intent. On a cell
grid, motion is quantised to whole cells; the side and adjustment data still matter
for the arrow. Without script, side data must be baked in at emit time, which is only
possible for the unconstrained placement.

### 15. State architecture

Two cleanly separated architectures.

**The positioner** is a mutable builder producing an immutable value. Copy semantics
are normative (`:136-139`); completeness is validated at use time, with
`xdg_positioner.error.invalid_input` (`:147-149`) for bad scalars and
`xdg_wm_base.error.invalid_positioner` (`:51-52`) for an incomplete value. The stable
version never enumerates its full default state — only "The default adjustment is
none" (`:344`) is written down. The newer experimental positioner does
(`experimental/xx-input-method/xx-input-method-v2.xml:682-689`):

> A newly created positioner has the following state:
>
> - 0 surface width
> - 0 surface height
> - anchor at the center ("none")
> - gravity towards the center ("none")
> - constraints adjustment set to none
> - offset at x = 0, y = 0
> - not reactive

**The popup** is a double-buffered, ack-gated state machine shared with
`xdg_surface`: pending state accumulates, `xdg_surface.configure` ends "a configure
sequence ... a set of one or more events configuring the state ... where the
xdg_surface.configure commits the accumulated state" (`:598-609`), the client acks a
serial, and serials are strictly monotonic — acking one consumes all earlier ones and
acking out of order raises `invalid_serial` (`:584-593`, commit
[`115ba71`][c-115ba71]). Nothing takes effect until `wl_surface.commit`.

This is neither a reducer nor a controller; it is transactional double-buffered state
with explicit acknowledgement. Almost all of the positioner's fields are
value-shaped: size (two ints), anchor rect (four ints), anchor and gravity (enums),
adjustments (a six-bit mask), offset (two ints), reactive (a bool), parent size (two
ints). The exception is `set_parent_configure(serial)` (`:397-406`), which is a
reference into a per-connection event history and is meaningful only to the peer that
issued it. That field appears to exist only because placement is out of process; in a
single process the same intent reads as "place against the layout you are about to
present", which is an inference about the mechanism rather than a statement the
protocol makes.

**Algorithm.** Builder → value: each `set_*` mutates pending fields, and
`get_popup`/`reposition` snapshots them. Popup: pending accumulates from configure
events; on `ack_configure(serial)` plus commit, applied becomes pending; serial
monotonicity is enforced as a total order.

**Where the behavior lives.** Protocol-defined; both peers implement it, sharing no
library.

**Degradation.** The copy-on-use rule that Wayland must state in prose is what a
value type in a systems language gets by default, and a fixed-size record with no
indirections places no demands on an allocator, so the placement half survives into
`@safe pure nothrow @nogc` territory unchanged. The ack/serial protocol is the part
not worth copying: it synchronises two processes that present independently, and in
one surface the equivalent is the frame. Because both the input value and the output
rect are values, a placement decision becomes a pure-function unit test with no
backend — a property this repository itself does not exploit, since it ships no
conformance suite.

### 16. Shared infrastructure

The factoring is severe. **One** role, `xdg_popup`, is normatively intended for
"menus, popovers, tooltips and other similar user interface concepts"
(`:1249-1251`), and the only differentiation the protocol offers between them is
whether `xdg_popup.grab` is called. The grab must be requested before mapping —
grab-after-map raises `invalid_grab`, "tried to grab after being mapped"
(`:1275-1278`) — so the dismissal-and-focus contract is fixed at construction and
cannot be toggled mid-life. Commit [`eef4b95`][c-eef4b95] performed this split
deliberately, making popups non-grabbing by default "to enable using xdg_popup for
creating tooltips and other user interface elements that does not want to take an
explicit grab".

What is genuinely common here: the placement value, the parent link, creation-order
stacking, the reposition/reconfigure protocol, and the mapping/ack lifecycle. What
looks common but is kept apart: the grab chain (menus and submenus are in it;
tooltips are not), modality (a separate ancillary object on toplevels), the anchor
source when it is not client-owned (a whole separate positioner interface for IME
popups rather than a flag on the existing one), and every time-, hover-, arrow-,
accessibility- and animation-shaped behaviour, which is nowhere. That the IME case
got a new positioner rather than a parameter suggests "who owns the anchor" is
treated as a type-level distinction rather than a flag — an inference from a single
instance in this tree.

**Algorithm.** Not applicable; this dimension is a factoring, not a computation.

**Where the behavior lives.** The IDL itself is the factoring artefact.

**Degradation.** The economy transfers: one primitive owning the placement value and
`place()`, the parent/child tree, creation-order painting with reverse-order hit
testing, the dismissal cascade, and one immutable-at-open flag for "takes the
dismissal-and-focus chain". Copying the `invalid_grab` rule — the flag cannot change
after open — prevents a tooltip from becoming a menu mid-life, which is a real source
of state bugs. Kept apart: hover and delay machines, typeahead and roving focus,
value editing, modality and scrim, and non-anchored transient surfaces. Without
script, what remains is the placement value and the tree but neither the chain nor
the cascade — precisely the `none`-adjustment, no-grab subset the protocol already
defines as valid. The corresponding proposal for `sparkles:ui` is in
[`./proposal.md`][proposal].

## Strengths

- The placement value is genuinely Regular: plain integers, two nine-entry enums, a
  six-bit mask and a bool, with copy-on-use stated normatively (`:136-139`). It is an
  existence proof that a placement description can be a value rather than an object
  graph.
- The fallback algebra is small, total and ordered — three adjustments, two axes, one
  global precedence (`:250-251`) — and the default (`none`) is a specified, legal
  behaviour rather than an error.
- Slide and flip are specified with unusual precision: slide's two-phase
  gravity-ordered walk with its stopping rule (`:263-271`), and flip's transactional
  re-evaluation from the original anchor rect and offset with rollback if it does not
  help (`:296-314`).
- One role serves menus, popovers and tooltips, and the sole differentiator is one
  opt-in request, fixed before mapping.
- The overlay tree and its cascading dismissal are specified in both directions —
  clients must destroy leaf-to-root, compositors must dismiss in the same order — and
  backed by a protocol error rather than a convention (`:1310-1316`, `:1285-1286`).
- Grab splits pointer from keyboard: owner-events pointer routing plus hard keyboard
  assignment to the topmost (`:1325-1328`), two independent rules where a single
  "modal" flag would conflate them.
- `resize_x`/`resize_y` make the placer a size negotiator whose documented purpose is
  feedback about available space.
- Every coordinate is a plain integer in logical surface-local units, so the algebra
  is as expressible in character cells as in logical pixels.
- The design's mistakes were fixed in public and are readable in the history:
  bitfield → enum ([`6bff136`][c-6bff136]), always-grab → opt-in grab
  ([`eef4b95`][c-eef4b95]), flip-with-offset ambiguity ([`8f96c07`][c-8f96c07]),
  absolute `(x, y)` → declarative ([`dee23fd`][c-dee23fd]).

## Weaknesses

- **The reply is geometry-only.** `xdg_popup.configure` returns `x`, `y`, `width`,
  `height` and nothing else (`:1341-1355`) — no chosen side, no applied-adjustment
  mask, no anchor in popup-local space. A caller drawing a caret or setting a
  transform origin must reverse-engineer it, and cannot do so fully because the work
  area is unknown. The newer `xx_input_popup_surface_v2.start_configure` reports
  exactly that missing datum.
- **The work area is undefined** (`:245-248`), so identical positioners may produce
  different results under different compositors. This is the difference between a
  pure function and a deterministic one.
- **`popup_done` carries no reason** (`:1358-1363`). Escape, click-outside, screen
  lock and compositor timeout are indistinguishable, so reason-dependent focus
  restoration is impossible at this layer.
- **The stable positioner never enumerates its default state**; only "The default
  adjustment is none" (`:344`) is written down. The successor design lists all seven
  defaults.
- **Resize does not say which edge moves**, so a shrunk popup's origin is
  implementation-defined even given a known work area.
- **The reactive/reposition path is admitted to be racy** ([`ebbad29`][c-ebbad29]);
  `set_parent_size`/`set_parent_configure` mitigate but do not solve it, and
  `set_parent_configure` drags a connection-scoped serial into what is otherwise a
  plain value.
- **There is no conformance test suite.** `tests/scan.sh` runs `wayland-scanner` and
  `tests/meson.build` compiles the generated headers; nothing exercises the algebra.
- **Directions are physical only** — no start/end, no writing mode, no RTL awareness.
- **There is no preferred-placement list.** The caller gets one gravity plus
  mechanical fallbacks; "bottom, else right, else top" is inexpressible.
- **Nothing above geometry exists**: no timing, hover, arrows, animation metadata or
  accessibility. Defensible for a display protocol, but it means the subject can
  validate only the placement half of an anchored-overlay design.

> [!NOTE]
> A related divergence, established by cross-checking this protocol against
> [`./gtk4.md`][gtk4] during verification: GTK4 solves the same positioner value
> in-process for its non-Wayland backends with a **different flip-acceptance rule** —
> less-bad wins, rather than the protocol's revert-unless-fully-unconstrained — and
> the subsequent slide can pin the two results to opposite edges. A toolkit that
> delegates to a real `xdg_popup` on one backend and solves in-process on another
> will therefore not necessarily reproduce its own placement across backends.

## Key design decisions and trade-offs

| Decision                                                                                                                                             | Rationale                                                                                                                                                                                                                                                 | Trade-off                                                                                                                                                                                                                                                                                                     |
| ---------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Placement is described declaratively by the client and computed by the placer, out of process.                                                       | Only the compositor knows the work area, the output layout and the popup's absolute position; a client cannot compute a correct position even in principle. [`dee23fd`][c-dee23fd] introduced the positioner as "a method for declarative positioning".   | The client cannot learn _why_ it landed where it did: the reply is a rect only, so arrow direction and transform origin must be re-derived, and cannot be resolved at all in ambiguous cases because the work area is unknown.                                                                                |
| Anchor and gravity are nine-entry enums, not bitfields.                                                                                              | [`6bff136`][c-6bff136]: "Bitfields allowed for impossible combinations of anchor edges, such as being on the left and right edge. Use of explicit enumerations means we don't need to handle that case." Illegal states made unrepresentable on the wire. | Future edge combinations need a version bump, and the enums entrench physical directions — no start/end, so RTL and vertical writing modes must be resolved by the caller before the value is built.                                                                                                          |
| Constraint adjustment is an opt-in bitmask with a fixed global precedence (Flip → Slide → Resize) rather than a caller-supplied list of fallbacks.   | A total, ordered rule that independent compositor implementations can follow identically with no shared code and no way to ship a common library.                                                                                                         | "Try bottom, then right, then top" is inexpressible; the caller gets one gravity plus mechanical fallbacks. And the default is `none`, so every caller must remember to opt in.                                                                                                                               |
| Grab — and therefore the dismissal chain, the keyboard focus rule and the reverse-destruction ordering — is an opt-in request, fixed before mapping. | [`eef4b95`][c-eef4b95]: making popups non-grabbing by default "enables using xdg_popup for creating tooltips and other user interface elements that does not want to take an explicit grab". One geometry primitive, two behavioural contracts.           | A non-grabbing popup gets no dismissal service at all — no outside-click, no Escape, no `popup_done` on user action. And because grab-after-map is a protocol error, an overlay cannot be promoted from tooltip to menu in place.                                                                             |
| The work area, the definition of "constrained", and the tie-breaking inside resize are left to the compositor.                                       | Panels, docks, per-output policy and multi-monitor topology are shell policy; freezing them into the protocol would prevent shells from differing (`:245-246`).                                                                                           | Placement is only conditionally pure — the same positioner may yield different rects under different shells, and the client cannot reproduce the computation locally. The tree is now retrofitting the missing input from outside (`xx_zone_v1`'s placeable area, `xx_cutouts_v1`'s notch and corner insets). |
| Modality, timing, hover, arrows, animation and accessibility are all excluded from the anchored-overlay primitive.                                   | The compositor cannot know a client's widget semantics. Modality arrived years later as a hint on toplevels, with the explicit statement that "Clients must implement the logic to filter events in the parent toplevel on their own".                    | Every one of those behaviours must be re-implemented by each toolkit. For a system that is both placer and widget library the same split reads as a factoring recommendation rather than a cost: keep the placement value free of everything time- or semantics-shaped.                                       |

## Sources

Primary sources, all at the pinned revision `afb614d5fcbd02d261a6ae91920aa91cf3915a8a`:

- [`stable/xdg-shell/xdg-shell.xml`][xdg-shell] — the positioner and popup
  interfaces: value semantics ([`:136`][q-copy]), completeness ([`:141`][q-complete]),
  anchor rect ([`:169`][q-anchorrect]), anchor and gravity enums
  ([`:188`][q-anchor], [`:213`][q-gravity]), the constraint-adjustment enum with its
  precedence ([`:239`][q-adjust], [`:250`][q-precedence]), slide ([`:259`][q-slide]),
  flip ([`:289`][q-flip], [`:301`][q-flipy]), resize ([`:317`][q-resize]), offset
  ([`:350`][q-offset]), reactive and future-parent state ([`:370`][q-reactive],
  [`:381`][q-parentsize], [`:397`][q-parentcfg]), window geometry
  ([`:511`][q-wingeom]), the configure/ack contract ([`:560`][q-ack],
  [`:598`][q-cfgseq]), the popup role ([`:1247`][q-popup]), stacking
  ([`:1265`][q-stack]), grab and the chain ([`:1290`][q-grab]),
  `configure` ([`:1341`][q-configure]), `popup_done` ([`:1358`][q-done]) and
  `reposition`/`repositioned` ([`:1368`][q-reposition], [`:1398`][q-repositioned]).
- [`unstable/xdg-shell/xdg-shell-unstable-v5.xml`][v5] — the pre-positioner design:
  absolute `(x, y)` placement with an implicit grab, and the submenu-travel wording
  that survives into the stable text.
- [`unstable/text-input/text-input-unstable-v3.xml`][text-input] —
  `set_cursor_rectangle`, the tree's single-rect text anchor.
- [`staging/xdg-dialog/xdg-dialog-v1.xml`][xdg-dialog] — `set_modal` as a hint with
  client-side enforcement.
- [`staging/pointer-warp/pointer-warp-v1.xml`][pointer-warp] — serials reused as an
  authorisation check.
- [`staging/fractional-scale/fractional-scale-v1.xml`][fractional] — scaling kept out
  of band from positioner coordinates.
- [`experimental/xx-input-method/xx-input-method-v2.xml`][xx-input] —
  `xx_input_popup_positioner_v1` (no `set_anchor_rect`, enumerated default state) and
  `start_configure` (the anchor reported in popup-local coordinates).
- [`experimental/xx-zones/xx-zones-v1.xml`][xx-zones] and
  [`experimental/xx-cutouts/xx-cutouts-v1.xml`][xx-cutouts] — the placeable area and
  the notch/cutout insets, being retrofitted from outside xdg-shell.
- Git history: [`dee23fd`][c-dee23fd] (introduce the positioner),
  [`eef4b95`][c-eef4b95] (non-grabbing by default), [`6bff136`][c-6bff136]
  (bitfield → enum), [`8f96c07`][c-8f96c07] (flip with an anchor offset),
  [`e49a2c0`][c-e49a2c0] (empty anchor rects), [`375385e`][c-375385e]
  (intersect-or-adjacent), [`c09e899`][c-c09e899] (resize as space feedback),
  [`ebbad29`][c-ebbad29] (implicit repositioning is racy), [`26f494e`][c-26f494e]
  (explicit repositioning and its token), [`115ba71`][c-115ba71] (monotonic
  `ack_configure`), [`3dab2f1`][c-3dab2f1] (focus semantics for popup grabs).

Related pages: the catalog [index][index], the shared [vocabulary][concepts], the
[capstone comparison][comparison], [features people forget][forget], the
[sparkles baseline][baseline] and the [proposal][proposal]. Sibling subjects most
often referenced from here: [GTK4][gtk4] (the reference client for this protocol on
Wayland, with its own in-process solver for other backends), [Qt Widgets][qt-widgets]
(the other large `xdg_popup` client), [Compose][compose] (an OS-popup toolkit whose
placement policy is a value), and [Neovim floats][neovim] (the same algebra on a cell
grid). Wider context lives in the [window-system integration][wsi] and
[platform UI guidelines][platform] research trees, and the toolkit side in
[`../../specs/ui/index.md`][spec-ui] and [`../../specs/ui/input.md`][spec-input].

<!-- References -->

[repo]: https://gitlab.freedesktop.org/wayland/wayland-protocols
[readme]: https://gitlab.freedesktop.org/wayland/wayland-protocols/-/blob/afb614d5fcbd02d261a6ae91920aa91cf3915a8a/README.md
[xdg-shell]: https://gitlab.freedesktop.org/wayland/wayland-protocols/-/blob/afb614d5fcbd02d261a6ae91920aa91cf3915a8a/stable/xdg-shell/xdg-shell.xml
[q-copy]: https://gitlab.freedesktop.org/wayland/wayland-protocols/-/blob/afb614d5fcbd02d261a6ae91920aa91cf3915a8a/stable/xdg-shell/xdg-shell.xml#L136
[q-complete]: https://gitlab.freedesktop.org/wayland/wayland-protocols/-/blob/afb614d5fcbd02d261a6ae91920aa91cf3915a8a/stable/xdg-shell/xdg-shell.xml#L141
[q-anchorrect]: https://gitlab.freedesktop.org/wayland/wayland-protocols/-/blob/afb614d5fcbd02d261a6ae91920aa91cf3915a8a/stable/xdg-shell/xdg-shell.xml#L169
[q-anchor]: https://gitlab.freedesktop.org/wayland/wayland-protocols/-/blob/afb614d5fcbd02d261a6ae91920aa91cf3915a8a/stable/xdg-shell/xdg-shell.xml#L188
[q-gravity]: https://gitlab.freedesktop.org/wayland/wayland-protocols/-/blob/afb614d5fcbd02d261a6ae91920aa91cf3915a8a/stable/xdg-shell/xdg-shell.xml#L213
[q-adjust]: https://gitlab.freedesktop.org/wayland/wayland-protocols/-/blob/afb614d5fcbd02d261a6ae91920aa91cf3915a8a/stable/xdg-shell/xdg-shell.xml#L239
[q-precedence]: https://gitlab.freedesktop.org/wayland/wayland-protocols/-/blob/afb614d5fcbd02d261a6ae91920aa91cf3915a8a/stable/xdg-shell/xdg-shell.xml#L250
[q-slide]: https://gitlab.freedesktop.org/wayland/wayland-protocols/-/blob/afb614d5fcbd02d261a6ae91920aa91cf3915a8a/stable/xdg-shell/xdg-shell.xml#L259
[q-flip]: https://gitlab.freedesktop.org/wayland/wayland-protocols/-/blob/afb614d5fcbd02d261a6ae91920aa91cf3915a8a/stable/xdg-shell/xdg-shell.xml#L289
[q-flipy]: https://gitlab.freedesktop.org/wayland/wayland-protocols/-/blob/afb614d5fcbd02d261a6ae91920aa91cf3915a8a/stable/xdg-shell/xdg-shell.xml#L301
[q-resize]: https://gitlab.freedesktop.org/wayland/wayland-protocols/-/blob/afb614d5fcbd02d261a6ae91920aa91cf3915a8a/stable/xdg-shell/xdg-shell.xml#L317
[q-offset]: https://gitlab.freedesktop.org/wayland/wayland-protocols/-/blob/afb614d5fcbd02d261a6ae91920aa91cf3915a8a/stable/xdg-shell/xdg-shell.xml#L350
[q-reactive]: https://gitlab.freedesktop.org/wayland/wayland-protocols/-/blob/afb614d5fcbd02d261a6ae91920aa91cf3915a8a/stable/xdg-shell/xdg-shell.xml#L370
[q-parentsize]: https://gitlab.freedesktop.org/wayland/wayland-protocols/-/blob/afb614d5fcbd02d261a6ae91920aa91cf3915a8a/stable/xdg-shell/xdg-shell.xml#L381
[q-parentcfg]: https://gitlab.freedesktop.org/wayland/wayland-protocols/-/blob/afb614d5fcbd02d261a6ae91920aa91cf3915a8a/stable/xdg-shell/xdg-shell.xml#L397
[q-wingeom]: https://gitlab.freedesktop.org/wayland/wayland-protocols/-/blob/afb614d5fcbd02d261a6ae91920aa91cf3915a8a/stable/xdg-shell/xdg-shell.xml#L511
[q-ack]: https://gitlab.freedesktop.org/wayland/wayland-protocols/-/blob/afb614d5fcbd02d261a6ae91920aa91cf3915a8a/stable/xdg-shell/xdg-shell.xml#L560
[q-cfgseq]: https://gitlab.freedesktop.org/wayland/wayland-protocols/-/blob/afb614d5fcbd02d261a6ae91920aa91cf3915a8a/stable/xdg-shell/xdg-shell.xml#L598
[q-popup]: https://gitlab.freedesktop.org/wayland/wayland-protocols/-/blob/afb614d5fcbd02d261a6ae91920aa91cf3915a8a/stable/xdg-shell/xdg-shell.xml#L1247
[q-stack]: https://gitlab.freedesktop.org/wayland/wayland-protocols/-/blob/afb614d5fcbd02d261a6ae91920aa91cf3915a8a/stable/xdg-shell/xdg-shell.xml#L1265
[q-grab]: https://gitlab.freedesktop.org/wayland/wayland-protocols/-/blob/afb614d5fcbd02d261a6ae91920aa91cf3915a8a/stable/xdg-shell/xdg-shell.xml#L1290
[q-configure]: https://gitlab.freedesktop.org/wayland/wayland-protocols/-/blob/afb614d5fcbd02d261a6ae91920aa91cf3915a8a/stable/xdg-shell/xdg-shell.xml#L1341
[q-done]: https://gitlab.freedesktop.org/wayland/wayland-protocols/-/blob/afb614d5fcbd02d261a6ae91920aa91cf3915a8a/stable/xdg-shell/xdg-shell.xml#L1358
[q-reposition]: https://gitlab.freedesktop.org/wayland/wayland-protocols/-/blob/afb614d5fcbd02d261a6ae91920aa91cf3915a8a/stable/xdg-shell/xdg-shell.xml#L1368
[q-repositioned]: https://gitlab.freedesktop.org/wayland/wayland-protocols/-/blob/afb614d5fcbd02d261a6ae91920aa91cf3915a8a/stable/xdg-shell/xdg-shell.xml#L1398
[v5]: https://gitlab.freedesktop.org/wayland/wayland-protocols/-/blob/afb614d5fcbd02d261a6ae91920aa91cf3915a8a/unstable/xdg-shell/xdg-shell-unstable-v5.xml
[text-input]: https://gitlab.freedesktop.org/wayland/wayland-protocols/-/blob/afb614d5fcbd02d261a6ae91920aa91cf3915a8a/unstable/text-input/text-input-unstable-v3.xml#L266
[xdg-dialog]: https://gitlab.freedesktop.org/wayland/wayland-protocols/-/blob/afb614d5fcbd02d261a6ae91920aa91cf3915a8a/staging/xdg-dialog/xdg-dialog-v1.xml#L87
[pointer-warp]: https://gitlab.freedesktop.org/wayland/wayland-protocols/-/blob/afb614d5fcbd02d261a6ae91920aa91cf3915a8a/staging/pointer-warp/pointer-warp-v1.xml#L56
[fractional]: https://gitlab.freedesktop.org/wayland/wayland-protocols/-/blob/afb614d5fcbd02d261a6ae91920aa91cf3915a8a/staging/fractional-scale/fractional-scale-v1.xml#L26
[xx-input]: https://gitlab.freedesktop.org/wayland/wayland-protocols/-/blob/afb614d5fcbd02d261a6ae91920aa91cf3915a8a/experimental/xx-input-method/xx-input-method-v2.xml#L530
[xx-zones]: https://gitlab.freedesktop.org/wayland/wayland-protocols/-/blob/afb614d5fcbd02d261a6ae91920aa91cf3915a8a/experimental/xx-zones/xx-zones-v1.xml#L228
[xx-cutouts]: https://gitlab.freedesktop.org/wayland/wayland-protocols/-/blob/afb614d5fcbd02d261a6ae91920aa91cf3915a8a/experimental/xx-cutouts/xx-cutouts-v1.xml#L164
[c-dee23fd]: https://gitlab.freedesktop.org/wayland/wayland-protocols/-/commit/dee23fd0cf35e33ad95cfaeed37f27897613f453
[c-eef4b95]: https://gitlab.freedesktop.org/wayland/wayland-protocols/-/commit/eef4b95f59ccc3eedcb01cd6e06556488bf8f71c
[c-6bff136]: https://gitlab.freedesktop.org/wayland/wayland-protocols/-/commit/6bff136f30b39677505ee92a0e6ce2cdf9e388f7
[c-8f96c07]: https://gitlab.freedesktop.org/wayland/wayland-protocols/-/commit/8f96c079d2788e869fd704de2b040b79c5b9bcac
[c-e49a2c0]: https://gitlab.freedesktop.org/wayland/wayland-protocols/-/commit/e49a2c0b56c3992cf6e10f1a1a870eef6d4f855f
[c-375385e]: https://gitlab.freedesktop.org/wayland/wayland-protocols/-/commit/375385e3d2372604618f2b2adebc57e304b4268c
[c-c09e899]: https://gitlab.freedesktop.org/wayland/wayland-protocols/-/commit/c09e89929bad8f19b6eb70018c1d984bbe650346
[c-ebbad29]: https://gitlab.freedesktop.org/wayland/wayland-protocols/-/commit/ebbad29e3fc82f62a73cc19e924dcde89dd05c49
[c-26f494e]: https://gitlab.freedesktop.org/wayland/wayland-protocols/-/commit/26f494edb0ad7978ab04eb41d2293e26c50e5451
[c-115ba71]: https://gitlab.freedesktop.org/wayland/wayland-protocols/-/commit/115ba71872914f7b7dc3e5e57d4eff0ca892608b
[c-3dab2f1]: https://gitlab.freedesktop.org/wayland/wayland-protocols/-/commit/3dab2f13f74bd6676c907660c1f6a63f18d56b1a
[index]: ./index.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[forget]: ./features-people-forget.md
[baseline]: ./sparkles-baseline.md
[proposal]: ./proposal.md
[gtk4]: ./gtk4.md
[qt-widgets]: ./qt-widgets.md
[compose]: ./compose.md
[neovim]: ./neovim-floats.md
[c-anchor]: ./concepts.md
[c-placement]: ./concepts.md
[c-gravity]: ./concepts.md
[c-adjust]: ./concepts.md
[c-boundary]: ./concepts.md
[c-toplayer]: ./concepts.md
[c-light]: ./concepts.md
[c-grab]: ./concepts.md
[c-safe]: ./concepts.md
[c-warmup]: ./concepts.md
[c-cooldown]: ./concepts.md
[c-scope]: ./concepts.md
[c-modal]: ./concepts.md
[c-virtual]: ./concepts.md
[c-origin]: ./concepts.md
[wsi]: ../window-system-integration/index.md
[platform]: ../platform-ui-guidelines/index.md
[spec-ui]: ../../specs/ui/index.md
[spec-input]: ../../specs/ui/input.md
