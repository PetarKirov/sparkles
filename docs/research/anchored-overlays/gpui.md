# GPUI / Zed (Rust, GPU-rendered desktop)

GPUI solves the whole overlay problem — menus, submenus, popovers, hover cards, tooltips
and modals — inside a single GPU surface with no [top layer][concepts], no OS popup and no
pointer [grab][concepts]: "on top" is a flat per-frame vector of deferred paint records,
stable-sorted by an integer priority.

| Field         | Value                                                                                               |
| ------------- | --------------------------------------------------------------------------------------------------- |
| Language      | Rust                                                                                                |
| License       | Apache-2.0 (`crates/gpui`); GPL-3.0 for the Zed application crates                                  |
| Repository    | [`zed-industries/zed`][zed-repo]                                                                    |
| Documentation | [`crates/gpui/README.md`][gpui-readme] plus rustdoc on the source; no separate overlay guide exists |
| Category      | Native desktop (Rust GPU, in-canvas)                                                                |
| Surface model | in-canvas — one OS window, one GPU surface; no OS popup window appears anywhere in the overlay path |
| Revision read | [`d71f1461045c098dc6ca6b1b5adcf1b8949722e8`][zed-repo] (Zed 1.16.0, `crates/zed/Cargo.toml:5`)      |

> [!NOTE]
> This is an implementation reading, not a docs reading. Every claim below comes from the
> source at the pinned SHA. Zed was not built or run, and no behaviour was observed at
> runtime; the regression tests cited are read, not executed.

## Overview

### What it solves

An editor needs several overlay families at once: a completion menu anchored to the caret,
LSP hover popovers anchored to a text range, a code-action documentation aside beside the
menu, right-click context menus with submenus, toolbar popover menus, and tooltips. GPUI
supplies three shared mechanisms for all of them — a deferred-paint ordering primitive, a
small `Anchored` placement element, and a dismissal protocol — and leaves every richer
geometry policy to the call site. The framework never opens an OS window for an overlay,
never asks a compositor to place one, and never takes a pointer grab.

### Design philosophy

The kernel owns ordering, clipping escape, hit-test order and lifetime; components own
geometry policy. The clearest statement is the doc comment on the deferred element, which
splits layout from paint (`crates/gpui/src/elements/deferred.rs:14-15`):

> /// An element which delays the painting of its child until after all of
> /// its ancestors, while keeping its layout as part of the current element tree.

Keeping layout in the tree is load-bearing: the overlay inherits the parent's Taffy
context, text style, rem size and element-id namespace, and the parent can measure it
before deciding where to put it.

The second philosophical commitment is that overlay lifetime is a _message_, not a call
(`crates/gpui/src/window.rs:691`, quoted verbatim):

```rust
pub trait ManagedView: Focusable + EventEmitter<DismissEvent> + Render {}
```

An overlay body is anything focusable, renderable and able to emit one unit event. The
overlay never removes itself; the host subscribes to `DismissEvent` and drops its handle.

The third is that even a sub-pixel-capable GPU backend snaps the final anchored offset to
whole device-independent pixels (`crates/gpui/src/elements/anchored.rs:207-208`):

> let offset = desired.origin - bounds.origin;
> let offset = point(offset.x.round(), offset.y.round());

## How it works

One frame is `request_layout` (Taffy) → `prepaint` → `paint`, and an overlay is a subtree
whose _paint_ is relocated out of the normal recursion. `Window::defer_draw`
(`window.rs:4012`) appends a `DeferredDraw` record (`window.rs:930`) to a flat per-frame
vector, capturing the ambient context the subtree will need when it is re-run out of
place: the element-id stack, the text-style stack, the dispatch-tree parent node, the rem
size, an absolute offset, an optional content mask, the current view, and the `usize`
priority.

```text
Window::draw
  root.request_layout()                     Taffy lays out everything, overlays included
  root.prepaint_as_root()                   pushes hitboxes + DeferredDraw records
  prepaint_deferred_draws()                 rounds; each round stable-sorted by priority
  prepaint prompt | active drag | tooltip   exactly one of the three (else-if chain)
  mouse_hit_test = hit_test(mouse_position)
  root.paint()
  paint_deferred_draws()                    ALL indices stable-sorted by priority, globally
  paint prompt | active drag | tooltip
```

Nesting is handled by rounds rather than by a tree. `prepaint_deferred_draws`
(`window.rs:3360`) snapshots the vector length, sorts that slice by priority
(`window.rs:3384`), prepaints each entry, and lets entries appended during the round form
the next round, guarded by `assert!(depth < 10, "Exceeded maximum (10) deferred depth")`.
The draws are processed _in place_ — a hard-won invariant recorded in the source:

> // The draws are processed in place rather than being moved out of
> // `next_frame.deferred_draws`: `prepaint_index` snapshots that vector's
> // length, so any prepaint range recorded during a round (view caches,
> // nested deferred draws) must index the same vector `reuse_prepaint`
> // slices on the next frame.

Because hitboxes and mouse listeners are appended to flat per-frame vectors in
prepaint/paint order, "later" mechanically means "in front": `Frame::hit_test`
(`window.rs:1059`) walks hitboxes in reverse and intersects
`hitbox.bounds ∩ hitbox.content_mask.bounds`.

Placement is a separate, much smaller concern. `Anchored` (`anchored.rs:122`) measures the
union of its children's laid-out bounds, computes a rect from an `Anchor` corner plus a
point, tries one axis-wise corner flip, unconditionally clamps to the viewport, and rounds
the offset. Everything richer — text-range anchoring, stacked popovers, gap bridging,
submenu safe zones, aside placement — is hand-written in `crates/editor` and `crates/ui`.

## The analysis spine

### 1. Anchor model

Two anchor representations coexist. The framework's is `(Point, Anchor)`: `Anchored` stores
which corner or edge-centre _of the popup_ is pinned (`Anchor`, `geometry.rs:2165` — a
`Copy + Eq` enum of four corners and four edge centres), an optional
`anchor_position: Option<Point<Pixels>>`, and a `position_mode` selecting window-absolute
or parent-local coordinates (`anchored.rs:254`). With no explicit position the pin point is
the anchored element's own laid-out `bounds.origin` — its slot in the parent flow. **There
is no [anchor rect][concepts] in the framework at all.**

Call sites rebuild a rect anchor themselves. `PopoverMenu` records the trigger's laid-out
`Bounds` during prepaint and, on the _next_ frame's `request_layout`, converts it with
`child_bounds.corner(self.resolved_attach())` (`popover_menu.rs:382`) — an attach corner on
the trigger plus an anchor corner on the popup, which is the classic side/align pair
encoded as two corners. `RightClickMenu` uses a raw cursor `Point` captured at mouse-down
(a [virtual anchor][concepts] in all but name).

Text-range anchoring belongs entirely to the editor. `InfoPopover.symbol_range` is a
`RangeInEditor` over document `Anchor`s that survives edits and scrolling, resolved to
pixels only at layout time (`element.rs:4377`). Multi-row ranges are collapsed to one
point: `HoverState::render` (`hover_popover.rs:947`) picks the diagnostic range start, else
the first text range start, else the inlay position, and then _walks the anchor's row into
the visible range_ with `movement::up_by_rows` / `down_by_rows`
(`hover_popover.rs:984-994`), giving up only with
`log::error!("Hover popover point out of bounds after moving")` at `:1006`.

The sharpest statement that an anchor is a policy choice rather than a coordinate is
`MenuPosition` (`mouse_context_menu.rs:21`), a two-variant sum with the semantics spelled
out in its own doc comments: `PinnedToScreen(Point)` stays put and never disappears;
`PinnedToEditor { source, offset }` follows the text and disappears when the row scrolls
out.

**Algorithm.** `resolve_anchor()`: take the explicit position if given, else the element's
own laid-out origin; in local mode add the parent origin; add `offset`; then
`Bounds::from_anchor_and_size(anchor, point, measured_size)` (`geometry.rs:837`) subtracts
width for right-anchors, half width for centre-anchors, height for bottom-anchors. Editor
path: document `Anchor` → `DisplayPoint` → row clamped into the visible range →
`x_for_index(column) - scroll.x`, `row * line_height - scroll.y`, plus `content_origin`.

**Where it lives.** Framework: `anchored.rs` and `geometry.rs`. Rect reconstruction:
`crates/ui/src/components/{popover_menu.rs,right_click_menu.rs}`. Text-range anchoring:
`crates/editor/src/{hover_popover.rs,element.rs}`.

**Degradation.** _No OS window:_ nothing is lost — every coordinate in the overlay path is
window-local and no screen conversion exists anywhere (multi-monitor is simply not
modelled). _No sub-cell precision:_ the model is unchanged; `Anchor` is an eight-value enum
and the resulting offset is rounded to integers regardless (`anchored.rs:208`). The one
casualty is centre anchors on odd extents, where `Size::half()` must pick a side — a cell
port needs a documented floor/ceil rule. _No hover:_ untouched; a click or caret position
produces the same point. _No script:_ the pair is emit-time computable only if the popup's
size is known at emit time, and GPUI obtains that from a real measure pass.

### 2. Placement model

The framework model is deliberately impoverished: **sides are not named at all.** There is
no side or [placement][concepts] enum, no preferred list, no fallback ordering, no custom
[clipping boundary][concepts] — the boundary is always
`Bounds { origin: (0,0), size: window.viewport_size() }` (`anchored.rs:150-153`) — no work
area, no multi-monitor, no RTL or writing-mode plumbing, and no IME/virtual-keyboard
avoidance (the IME position is reported _outward_ by `update_ime_position`, never consumed
as a placement input).

What exists is three fit modes (`AnchoredFitMode`, `anchored.rs:243`):
`SwitchAnchor` (the default) tries a corner flip; `SnapToWindow` and
`SnapToWindowWithMargin(Edges)` skip the flip. The clamp at `anchored.rs:189-205` then runs
**unconditionally for every fit mode**, so [flip and shift][concepts] are not alternatives
but a pipeline: flip if it fully fits, then always clamp. Margins are additively combined
with `window.client_inset` (the Linux CSD shadow inset) at `anchored.rs:181-187` — the
framework's single safe-area concept, and structurally the right hook for any other inset.

Note what the flip actually is: it recomputes the rect from the _mirrored corner about the
same pin point_ (`Anchor::other_side_along`, `geometry.rs:2217`, feeding
`Bounds::from_anchor_and_size`, `geometry.rs:837`, called from `anchored.rs:158-176`). With
no anchor rect in the model there is no anchor edge to mirror and no [gravity][concepts] to
mirror with it, so the flip is a reflection of the placed region about a point.

Richer placement lives in the editor. `layout_popovers_above_or_below_line`
(`element.rs:4069`) is a real preferred/fallback ladder:

```text
bottom_y_when_flipped = target.y - line_height
available_above = bottom_y_when_flipped - text_hitbox.top()
available_below = text_hitbox.bottom() - target.y
y_flipped = placement_override ?? (max_height > available_below
                                   && available_above > available_below)
height   = min(max_height, chosen side's available space)
if height < min_height:                       # re-evaluate against the VIEWPORT
    prefer below if it fits min_height, else above, else the larger side,
    with height clamped to that side's space
x = min(target.x, max(viewport.right - max_width, 0))     # right edge only
```

Two details are worth naming. The flip decision uses `max_height` — a caller-supplied bound
consulted _before_ `make_sized_popovers` runs — not a measured height, so the side is
chosen frame-invariantly. And the horizontal adjustment is one-sided: it snaps the right
edge in and never the left, with an explicit admission at `element.rs:4143`
(`// TODO: Use viewport_bounds.width as a max width so that it doesn't get clipped on the left`).

**Algorithm.** `Anchored::prepaint`: `size = union(children_bounds).size`;
`(origin, desired) = position_mode.get_position_and_bounds(...)`;
`limits = (0, 0, viewport)`. Under `SwitchAnchor`: if `desired` overflows on X, build the
horizontally mirrored placement and accept it only if it fully fits on X (updating the
working anchor); repeat on Y with the possibly-updated anchor. Then, always: if
`desired.right > limits.right` subtract the overflow plus the right margin; if
`desired.left < limits.left` hard-set the left edge to `limits.left + edges.left`; same for
the vertical axis. `edges = (margin or zero) + client_inset`. Finally
`offset = round(desired.origin - bounds.origin)`.

**Where it lives.** `anchored.rs:150-215`; corner algebra in `geometry.rs`; the editor
ladders at `element.rs:4069` (above/below the line) and `element.rs:4195` (the aside).

**Degradation.** _No OS window:_ nothing is lost; the boundary is already a plain rect and
the whole pipeline is arithmetic. _No sub-cell precision:_ only the centre-anchor rounding
rule needs deciding. _No hover:_ unaffected. _No script:_ the flip is undecidable at emit
time because it needs a measured popup size — the honest static answer is to emit the
preferred side only, or to pre-measure (which a cell grid can do and a browser cannot).
Android's soft-keyboard inset has no analogue here; `client_inset` is the shape such an
inset would take, folded into the clamp margin as an input.

### 3. Collision & geometry engine

Overflow detection is pure rect arithmetic against one boundary. There is **no
clipping-ancestor discovery, no observers, no polling** — and no [constraint
adjustment][concepts] machinery beyond the flip-then-clamp above.

Escaping scroll containers is structural rather than API-level. `defer_draw` records an
absolute offset, deferred prepaint runs under `with_absolute_element_offset`, and — the
load-bearing detail — `prepaint_deferred_draws` re-establishes **no** content mask, so the
mask stack is empty and `Window::content_mask()` falls back to the full viewport
(`window.rs:3811-3822`). Every hitbox inserted during a deferred prepaint therefore carries
a viewport-sized mask (`insert_hitbox`, `window.rs:4820`), and since `hit_test` intersects
bounds with that mask, overlays remain hit-testable outside their scrolling ancestor.
`test_anchored_position_when_scrolled` (`anchored.rs:349`) scrolls a container by 1000px and
asserts the menu's bounds are unchanged.

Paint-time clipping is opt-in via `defer_draw(..., Some(mask))`, applied in
`paint_deferred_draws` (`window.rs:3430`). Exactly one call site in the tree uses it —
`edit_prediction.rs:2128`, to keep the edit-prediction popover inside the editor's text
bounds — which makes the default ("escape everything") explicit by exception.

> [!IMPORTANT]
> `Window::defer_draw`'s doc comment says the supplied content mask clips during both
> prepaint and paint, but the mask is only observed being applied in
> `paint_deferred_draws`; no corresponding application was found in
> `prepaint_deferred_draws` (`window.rs:3360-3425`). Whether the doc is stale or the
> prepaint application lives elsewhere was not resolved.

Cost is `O(n log n)` for the two priority sorts (into `SmallVec<[usize; 8]>`) plus
`O(hitboxes)` per hit test, per frame, unconditionally — read from the code, not measured.
There is no transform stack in the overlay path and `scale_factor` enters only when
converting Taffy output and snapping to the pixel grid.

**Algorithm.** Per frame: Taffy lays out the whole tree including anchored subtrees; root
prepaint pushes hitboxes with the ambient mask and pushes `DeferredDraw` records; rounds of
deferred prepaint run with an _empty_ mask stack and an absolute offset, each recomputing
flip and clamp from the current viewport and the current measured child size; the hit test
runs once after all prepaint; paint runs in priority order. No caching, no invalidation, no
observers.

**Degradation.** This dimension generalises best. _No OS window:_ unchanged — the viewport
is a `Size`. _No sub-cell precision:_ unchanged in kind, since GPUI already rounds. _No
script:_ recompute-every-frame has no static analogue; a scriptless target must accept a
single emit-time placement and no collision response. The transferable discipline is the
mask rule: an overlay's hit rects must be built with the _root_ clip, not the clip in force
where the overlay was declared.

### 4. Arrow / caret geometry

**Not applicable, and the absence is the finding.** Grepping the overlay surface
(`anchored.rs`, `deferred.rs`, `popover.rs`, `popover_menu.rs`, `tooltip.rs`,
`context_menu.rs`, `hover_popover.rs`) yields no arrow, caret, beak, tail or pointer
triangle, and no [transform origin][concepts] concept exists anywhere in GPUI. Zed's
popovers are rounded rectangles with an `elevation_2` shadow token and nothing pointing at
the anchor. The only directional glyph near a menu is `IconName::ChevronRight` used as a
submenu affordance inside a row — semantics, not geometry.

Consequently no arrow size feeds the offset. The trigger-to-popup gap is a scalar, signed
by anchor corner: `PopoverMenu::resolved_offset` (`popover_menu.rs:259-271`) uses
`rems_from_px(5.0) * rem_size` with the comment `// Default offset = 4px padding + 1px border`
and flips its sign for right-anchors versus left-anchors, zero for centre anchors. The
editor uses `HOVER_POPOVER_GAP = px(10.)` (`hover_popover.rs:39`) and `MENU_GAP = px(4.)`
(`code_context_menus.rs:48`). The tooltip's gap is cruder still: `tooltip_container` adds
`pl_2().pt_2p5()` _inside_ the tooltip element, commented
`// padding to avoid tooltip appearing right below the mouse cursor`
(`tooltip.rs:223`) — the offset is baked into the content's box model rather than the
placement.

**Where it lives.** Nowhere as geometry; only the gap scalars named above, plus
`POPOVER_Y_PADDING = px(8.)` (`popover.rs:9`).

**Degradation.** Trivially, because it does not exist. The evidence a cell-grid design can
take from this is negative but useful: a production editor ships zero arrows. If arrows are
wanted, the cheapest honest representation on a grid is `(side, index along that side)` —
two integers — attached to the _resolved_ placement as presentation, never fed back into
the offset as an input.

### 5. Trigger semantics

Triggers are per-component and never unified.

- **Tooltip** — hover only, wired by `register_tooltip_mouse_handlers`
  (`div.rs:3573`), which registers three window listeners: `MouseMove` (both phases),
  `MouseDown`, `ScrollWheel`. No focus trigger, no touch trigger, no long-press.
- **Popover menu** — click on the trigger, plus a programmatic
  `PopoverMenuHandle::{show, hide, toggle}` (`popover_menu.rs:41-126`) reachable from
  keybindings.
- **Right-click menu** — a bubble-phase `MouseDownEvent` listener filtered to
  `MouseButton::Right` on the hovered hitbox, which then calls both `cx.stop_propagation()`
  and `window.prevent_default()` (`right_click_menu.rs:245-252`).
- **Editor hover** — mouse-move over text, _or_ the bindable `Hover` action via
  `show_keyboard_hover` (`hover_popover.rs:98`), a genuine keyboard trigger for the same
  surface.
- **Submenu** — hover, click and Enter all funnel through
  `open_submenu(ix, builder, reason: SubmenuOpenTrigger::{Pointer, Keyboard})`
  (`context_menu.rs:1358`).

Race avoidance is explicit and multi-mechanism: `open_submenu` is idempotent per item
index; a keyboard-opened submenu sets `ignore_blur_until = now + 150ms` so the parent's
blur handler cannot dismiss during the focus handoff (`context_menu.rs:1393`); a
capture-phase mouse-down/up latch (`submenu_trigger_mouse_down`) stops `on_hover(false)`
closing mid-click; and `suppress_focus_selection` prevents the focus-in auto-select from
fighting the hover highlight (`context_menu.rs:236-239`).

Pointer-type distinction exists but is coarse and global. `InputModality::{Mouse, Keyboard, Touch}`
is assigned from the last platform event (`window.rs:5107-5109`), and
`HitboxId::is_hovered` returns `false` outright while the modality is `Keyboard`
(`window.rs:750-757`) — so keyboard navigation globally suppresses hover styling and hover
tooltips. Touch sets `InputModality::Touch`, but nothing in the overlay path branches on
it, and `LongPressEvent` (`gestures.rs:169`, 500 ms with an 8 px slop, `gestures.rs:115-118`)
has **zero consumers anywhere in `crates/`** — there is no touch-to-context-menu path. No
overlay registers an `on_a11y_action` to open itself.

**Algorithm.** Tooltip trigger: on every `MouseMove`, in the bubble phase, only when the
state is `None` and the element is hovered, spawn a timer task. Concurrency is contained by
computing an `Action` enum from an immutable borrow _before_ mutating —
`// Separates logic for what mutation should occur from applying it, to avoid overlapping RefCell borrows`
(`div.rs:3642-3643`).

**Degradation.** _No key release:_ every overlay-_opening_ trigger read here fires on a
press, a move or an action; the release-driven path in the API is `on_mouse_up_out`
(`div.rs:279`), used for dismissal. _No hover (Android):_ the tooltip becomes unreachable —
hover is its only trigger — and submenu opening loses its primary path, while click and
the keyboard `Hover` action survive. GPUI itself offers no substitute, so a port must
invent one; the long-press event exists and is unused. _No script:_ click can be faked with
`:checked` or a disclosure element and hover with `:hover`, but none of the idempotence,
grace windows or latches has a scriptless representation — the honest degradation is one
trigger per surface and no races because there is no state.

### 6. Timing

Two independent timing systems.

**GPUI tooltips.** `DEFAULT_TOOLTIP_SHOW_DELAY = 500ms`, overridable per element via
`tooltip_show_delay`; `HOVERABLE_TOOLTIP_HIDE_DELAY = 500ms`, not overridable
(`div.rs:49-50`). There is no [warm-up][concepts] or [cool-down][concepts] — no
"instant subsequent tooltip", no shared provider or group, no singleton registry, no max
display duration. The _window_ nonetheless enforces a de-facto singleton at render time:
`prepaint_tooltip` (`window.rs:3291`) walks `tooltip_requests` in reverse and returns the
first that reports visible, so at most one tooltip is painted and the last-requested wins.

**Editor hover.** `hover_popover_delay: 300`, `hover_popover_hiding_delay: 300`,
`hover_popover_sticky: true` (`assets/settings/default.json:146-153`). The show delay is
_split around the LSP request_: wait `delay - delay/2`, issue the request, then wait the
remaining `delay/2` (`hover_popover.rs:316-335`) — a slow server costs nothing extra up to
half the intent delay. Re-entry is suppressed by an **inclusive** range test with its
rationale in the source (`hover_popover.rs:628-633`):

```rust
// LSP returns a hover result for the end index of ranges that should be hovered, so we need to
// use an inclusive range here to check if we should dismiss the popover
(hover_range.start..=hover_range.end).contains(&offset)
```

The hide timer is armed, not restarted, while the pointer recedes:
`// If we are moving away and a timer is already running, just let it count down.`
(`hover_popover.rs:79`).

**Algorithm.** `ActiveTooltip` (`div.rs:3516`) has three variants — `WaitingForShow`,
`Visible { tooltip, is_hoverable }`, `WaitingForHide` — held in an
`Rc<RefCell<Option<ActiveTooltip>>>`, so `None` is the fourth (idle) state:

```text
None            --(MouseMove bubble && hovered)--> WaitingForShow(timer = show_delay)
WaitingForShow  --(MouseMove && !hovered)-------> None            (Task is cancel-on-drop)
WaitingForShow  --(timer fires)-----------------> Visible         (view + mouse position
                                                                   captured AT FIRE TIME)
Visible(!hoverable) --(not hovered at prepaint)-> None
Visible(hoverable)  --(not hovered at prepaint)-> WaitingForHide(timer = 500ms)
WaitingForHide  --(hovered again)---------------> Visible
WaitingForHide  --(timer fires)-----------------> None
any             --(MouseDown | ScrollWheel)-----> None, unless hoverable and hovered
```

The structurally decisive choice is that the hide decision is made in **window prepaint**,
not in the mouse handler, because
`// the mouse move handler won't get called when the element is not painted (e.g. via use of visible_on_hover)`
(`div.rs:3757-3759`); the window invokes `check_visible_and_update` from
`prepaint_tooltip` before prepainting the tooltip.

**Degradation.** _Static HTML:_ no timers, so the dimension collapses to `:hover` plus a
CSS `transition-delay`, which can fake the show delay but not the hide delay, the hoverable
grace, or re-entry suppression. _Recording canvas:_ every state is assertable because the
timers are `BackgroundExecutor` timers the test dispatcher can `advance_clock` — Zed's own
tooltip tests do exactly this (`div.rs:4681`, `:4718`, `:4746`). _No hover:_ show and hide
delays become meaningless; only "build content at fire time, not at arm time" still
matters. _No key release:_ unaffected — no timing transition depends on one.

### 7. Interactive hover (trigger → content travel)

Three different algorithms coexist and **none is a [safe polygon][concepts]**.

1. **Tooltip travel.** `hoverable_tooltip` makes the tooltip itself a hover target;
   `TooltipId::is_hovered` (`window.rs:908`) is a plain containment test against the
   tooltip's bounds, and the hide is delayed 500 ms. The gap is unguarded, but
   `tooltip_container`'s internal padding means the tooltip's hit bounds start at the
   cursor while its visible box is offset — the padding is the bridge.

2. **Stacked hover popovers (editor).** A real painted rectangle is deferred into every gap
   between consecutive stacked popovers (`element.rs:4404-4417`):

   ```rust
   let mut occlusion = div()
       .size_full()
       .occlude()
       .on_mouse_move(|_, _, cx| cx.stop_propagation())
       .into_any_element();
   occlusion.layout_as_root(size(width, HOVER_POPOVER_GAP).into(), window, cx);
   window.defer_draw(occlusion, origin, 2, None);
   ```

   It is both a hit-test shield (`occlude()` sets `HitboxBehavior::BlockMouse`, so the hit
   test stops there) and an event sink (the move handler stops the editor beneath from
   seeing the move and calling `hover_at(None)`, which would start the hide timer). It is
   installed between every consecutive pair (`element.rs:4436`, `:4458`, `:4554`). This is a
   pointer bridge expressed as ordinary display-list geometry.

3. **Submenu "menu-aim".** One scalar plus one inflated rect. On pointer entry to a submenu
   trigger, `submenu_safety_threshold_x = mouse.x - 50px` (`context_menu.rs:1665`); on
   further moves over the trigger while the submenu is open, `= mouse.x - 100px`
   (`:1628`). When a submenu item reports hover-lost, the parent closes only if the pointer
   is left of the threshold (`context_menu.rs:2043-2049`):

   ```rust
   // Only close if mouse is to the left of the safety threshold
   // (prevents accidental close when moving diagonally toward submenu)
   let should_close = parent
       .submenu_safety_threshold_x
       .map(|threshold_x| mouse_pos.x < threshold_x)
       .unwrap_or(true);
   ```

   Independently, `padded_submenu_bounds()` (`context_menu.rs:1750-1762`) inflates the
   observed bounds cell by 50 px on every side, and both the trigger's hover-lost path and
   `on_mouse_down_out` (`:2313-2318`) consult it.

4. **Editor hover recede.** `is_mouse_getting_closer` (`hover_popover.rs:893-929`) computes
   the axis-clamped Euclidean distance from the pointer to the nearest edge of each
   popover's last painted bounds (0 inside), takes the minimum, and returns `false` — arming
   the hide — only when the new distance exceeds a running minimum by more than 4 px
   (`:921`). It is a monotone-approach heuristic with a hysteresis band, not a trajectory
   predictor.

The parent/child hover relationship is an explicit `HoverTarget::{None, MainMenu, Submenu}`
that each side writes into the _other_ entity from its own hover listener.

**Degradation.** In whole cells the occluder bridge is a one-row by N-column rect appended
to the hit list with a "block" flag and no glyphs. The 50 px / 100 px submenu slack and the
4 px recede band are pixel constants that a cell port must restate as cell counts; at
typical cell sizes the 4 px band is smaller than one cell, so it cannot be expressed at
cell granularity and must be widened or dropped. _No hover (Android):_ all four algorithms
are dead code. _No key release:_ unaffected — all four are pointer-only. _Static HTML:_ the
occluder bridge is the one technique that survives, because a wrapper spanning the gap is
pure CSS; the threshold and the hysteresis are not.

### 8. Dismissal

There is no unified dismissal service, but there is a unified dismissal **protocol**:
`DismissEvent` on a `ManagedView` (`window.rs:691-696`). The host subscribes and drops its
`Entity<M>` handle; the overlay never removes itself. Observed causes:

| Cause                 | Mechanism                                                                                                                                                                  |
| --------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Escape                | the `menu::Cancel` action → `ContextMenu::cancel` (`context_menu.rs:1057`), which for a submenu refocuses the parent and grants it a 200 ms blur grace (`:1066`)           |
| Focus out             | `cx.on_blur` → cancel, with two carve-outs: the grace window, and "my open submenu currently holds focus" (`context_menu.rs:282-297`)                                      |
| Pointer down outside  | `on_mouse_down_out` (`div.rs:259-271`), a **capture-phase** listener gated on `!window.has_active_prompt()` and raw `!hitbox.contains(mouse_position)`                     |
| Trigger re-activation | `PopoverMenu::paint` installs a bubble-phase `MouseDown` listener over the trigger that emits `DismissEvent` and stops propagation (`popover_menu.rs:483-496`)             |
| Child closing parent  | a submenu's `DismissEvent` also emits the parent's when the item was clicked, so confirming a leaf collapses the chain                                                     |
| Anchor scrolled away  | `MenuPosition::PinnedToEditor` menus stop being laid out when neither the source row nor the position is visible (`element/mouse.rs:311-322`) — suppression, not dismissal |
| Selection changed     | `MouseContextMenu` subscribes to the editor's own `SelectionsChanged { local: true }` and removes itself when the range moved                                              |
| Scroll                | `hide_hover` on editor scroll; a tooltip is cleared by any `ScrollWheelEvent` unless hoverable and hovered                                                                 |

Not present: nothing dismisses on window or application deactivation
(`on_active_status_change` only refreshes and runs activation observers, and
`Window::focused` does not filter by active state), nothing dismisses on resize, and there
is no touch-outside or navigation hook.

The notable composite is `Editor::dismiss_menus_and_popups` (`editor.rs:3349-3382`): one
Escape runs a fixed ordered cascade of about eleven dismissals OR-combined into a single
`bool` — rename, blame popover, hover, signature help, completion/code-action menu, mouse
context menu, edit prediction, snippet stack, diff-review drag, diff-review overlays,
active diagnostic group — and returns whether anything closed so propagation stays correct.
This is a deliberate departure from "Escape peels the topmost".

> [!WARNING]
> `on_mouse_down_out` uses raw `hitbox.contains(...)` while `on_mouse_up_out` uses the
> occlusion-aware `hitbox.is_hovered(...)` (`div.rs:266` vs `div.rs:288`). The asymmetry is
> undocumented; the down variant therefore treats a press that landed on something painted
> _in front of_ the overlay as an outside press.

**Algorithm.** The host's subscription closure: if the overlay's focus handle
`contains_focused`, restore the `previous_focus_handle` captured at open time; then
`*menu.borrow_mut() = None; window.refresh()`. Outside-press: capture-phase listener over
every mouse-down; guard on no active system prompt; guard on bounds containment; for menus
with an open submenu, additionally guard on the inflated submenu rect and on the parent's
recorded trigger bounds.

**Degradation.** _No OS window, no grab:_ this is precisely the situation GPUI is in —
every outside-press check is a capture-phase listener over an in-surface rect and needs no
grab. But GPUI still receives moves that _leave_ a hitbox, because the OS delivers them to
the window; where that is not guaranteed, the hover-lost submenu close and the tooltip's
"not hovered" transition can both stall. GPUI's own defence for the analogous case is the
prepaint-time `check_visible_and_update`, which re-derives hover from geometry every frame
rather than trusting an event. _No key release:_ every dismissal above is triggered by a
press, an action, a focus change or a frame. An Android back key maps naturally onto
`menu::Cancel`. _Static HTML:_ only trigger-toggle survives.

### 9. Focus

Focus is a single `Option<FocusId>` per frame plus a dispatch tree. There is **no focus
trap and no [focus scope][concepts] primitive**; overlays create no nested tab scopes, and
although a `TabStopMap` exists per frame, nothing in the overlay path touches it.

The four surface kinds differ cleanly in what they do with focus:

- **Tooltip** — never focusable, no focus handle at all; the tooltip view is rendered from
  `AnyTooltip` outside the dispatch tree entirely (`window.rs:3291`).
- **Menu** — takes real focus on its container (`track_focus`, `context_menu.rs:2281-2292`)
  and keeps it there; **items are never focused**, they are a `selected_index` plus
  `aria_active_descendant` (`:1637`, `:1978`).
- **Popover content** — focused via a doubly-nested `on_next_frame`, because deferring
  paint defers dispatch-tree linkage (`popover_menu.rs:299-310`):

  > // Since menus are rendered in a deferred fashion, their focus handles are
  > // not linked in the dispatch tree until after the deferred draw callback
  > // runs. We need to wait for that to happen before focusing it

- **Modal** — the workspace `ModalLayer` is a full-surface `occlude()` scrim with
  `track_focus` (`modal_layer.rs:285-325`).

Restoration is explicit and captured at open time: `window.focused(cx)` is read _before_
building the menu and restored inside the `DismissEvent` subscription only if the menu
still contains focus (`popover_menu.rs:281`, `:288-293`; the same block appears in
`right_click_menu.rs:258-268`).

Pointer- and keyboard-opened submenus differ materially: a keyboard open immediately
focuses the submenu and selects the first item, while a pointer open selects nothing and
sets `suppress_focus_selection` so focus-in does not fight the hover highlight. ARIA
conformance is deliberate and commented (`context_menu.rs:304-310`):

> // Per the ARIA menu button
> // pattern, opening a menu places focus on a menu item; for select-style
> // menus we prefer the currently-checked item.

**Algorithm.** `open()`: `prev = window.focused()`; build the entity; subscribe to
`DismissEvent`; `on_next_frame(on_next_frame(focus(handle)))`. Selection inside a menu is
index-based: `select_next` / `select_previous` (`context_menu.rs:1145`, `:1164`) skip
non-selectable entries and wrap, pinned by `can_navigate_back_over_headers`
(`context_menu.rs:2441`).

**Degradation.** _No OS window:_ unaffected — focus is an internal id. _No key release:_
the focus moves observed here are driven by press-phase actions, blur and frame callbacks;
no release-driven focus transition was found in the overlay path. _Cell grid:_ the
"container holds focus, selection is an index" model is directly expressible, since a grid
has no per-item focus ring to move. _Static HTML:_ `:focus-within` can express "menu is
open", but there is no restoration and no selection model. The two-frame focus dance is a
direct consequence of deferring; a design that resolves overlays in the same pass avoids it.

### 10. Layering & portals

There is no portal, no [top layer][concepts], no z-index, no stacking context, no
compositor layer and no native child window. The complete model is:

```text
paint order:  root → inspector → deferred draws (stable sort by usize priority)
                                → exactly one of { prompt | active drag | tooltip }
```

Priority is a bare `usize` defaulting to `0` (`deferred.rs:10`), with two conventions in
the codebase: `1` for popovers, popover menus and the completion menu; `2` for hover
popovers, occluders, asides and the blame popover. `sort_by_key` is stable, so equal
priorities preserve declaration order — "later in the list is in front" holds exactly.
Nesting is handled by rounds, not by a tree, capped at depth 10. A `DeferredDraw` is a flat
record: current view, dispatch parent node, element-id stack, text-style stack, content
mask, rem size, priority, element, absolute offset, prepaint range, paint range.

> [!WARNING]
> The priority sort is **per round during prepaint** (`window.rs:3384`) but **global during
> paint**: `deferred_draw_traversal_order` (`window.rs:3469`) sorts _all_ indices. Nested
> deferred draws inherit no priority (the default is `0`, `deferred.rs:10`), so a nested
> child can be painted behind an unrelated higher-priority sibling and even behind its own
> parent unless the author sets a higher priority by hand — which is exactly what the
> nesting test does (`deferred.rs:125` sets `2` inside a `1`). A two-level order key (owner
> entry, then child stamp) removes the class of bug at no cost.

The public API is `deferred(child).with_priority(n)` and `anchored()`; `Window::defer_draw`
is also public and raw, and the editor uses it directly to bypass `Anchored` entirely.
Implementation details are `DeferredDraw`, the rounds loop, the index-stability invariant
and the prepaint/paint ranges used for frame-to-frame subtree reuse (whose violation was a
real crash — the comment at `window.rs:3366-3374` and the regression test
`test_nested_deferred_draws_with_reused_views`, `deferred.rs:156`).

The tooltip layer is **not** part of this system: it is a fourth hard-coded slot in
`Window::draw` fed by `tooltip_requests`, guaranteed above every deferred draw and mutually
exclusive with the prompt and the active drag via an else-if chain (`window.rs:3218-3257`).

**Degradation.** Native to a world with no top layer; nothing degrades. The transferable
shape is: keep the overlay record flat, sort it stably by an integer, and make each record
carry the ambient context the overlay needs to be re-laid-out out of place — offset, clip,
style scale, and (separately) the logical parent for event routing.

### 11. Modality

[Modality][concepts] is not a framework concept; it is an emergent property of one flag on
a hit rect. `HitboxBehavior` (`window.rs:845-892`) has three values: `Normal`, `BlockMouse`
(set by `.occlude()`) and `BlockMouseExceptScroll` (set by `.block_mouse_except_scroll()`).
`Frame::hit_test` walks hitboxes in reverse, **breaks** on the first `BlockMouse`, and
records `hover_hitbox_count` at the first `BlockMouseExceptScroll` so everything behind is
not-hovered but still scroll-eligible. The doc is explicit that the mechanism is broader
than event handling (`window.rs:866-868`):

> /// This has effects beyond event handling - any use of hitbox checking, such as hover
> /// styles and tooltips. These other behaviors are the main point of this mechanism.

So "modal" means "paint an occluding rect". Every menu and popover body is wrapped in
`div().occlude()` or built from `WithRemSize::new(..).occlude()`. The full modal case,
`ModalLayer`, is an absolutely positioned `size_full().inset_0().occlude()` div with an
optional faded scrim and a left-mouse-down handler that hides the modal
(`modal_layer.rs:294-325`) — scrim plus [light dismiss][concepts] in a handful of lines.

Keyboard blocking is separate and weaker: nothing blocks keys geometrically. Keys route
through the dispatch tree from the focused node, so a non-focused overlay blocks no keys at
all, and "modal" is only ever pointer-modal unless the component also takes focus. There is
no accessibility modal bit anywhere in the overlay path. Passthrough is the default: a
`Normal` hitbox leaves everything behind hoverable, and making a surface non-passthrough is
one call. `has_active_prompt()` is a separate global veto consulted only by
`on_mouse_down_out` (`div.rs:266`), so a native system prompt does not collapse the UI
behind it — regression-tested at `div.rs:4789`.

**Algorithm.**

```text
hit_test(pos):
    ids = []; blocked = false
    for hitbox in hitboxes.rev():
        if (hitbox.bounds ∩ hitbox.content_mask.bounds).contains(pos):
            ids.push(hitbox.id)
            if !blocked && behavior == BlockMouseExceptScroll:
                hover_hitbox_count = ids.len(); blocked = true
            if behavior == BlockMouse: break
    if !blocked: hover_hitbox_count = ids.len()

is_hovered(id)            = id ∈ ids[..hover_hitbox_count]   (and false in keyboard modality)
should_handle_scroll(id)  = id ∈ ids
```

**Degradation.** This maps directly onto a single-surface, reverse-order hit list with one
extra enum per rect. _No OS window:_ unaffected. _No hover:_ `BlockMouse` still blocks
taps. _No script:_ a scrim can be painted but light dismiss cannot fire. The
`BlockMouseExceptScroll` distinction is worth carrying over on its own merits: an overlay
should stop _pointing_ interactions behind it without stealing the _scroll_ that belongs to
the nearest scrollable container.

### 12. Adaptive presentation

Adaptation is decided by the **component, at render time, from the window size** — never by
the framework and never from a device class. The clearest case is
`ContextMenu::render` (`context_menu.rs:2199`):

```rust
let is_wide_window = window_size.width / rem_size > rems_from_px(800_f32).0;
```

which branches the documentation aside between a horizontal sibling (absolutely positioned
`right_full().mr_1()` or `left_full().ml_1()`, capped `max_w_96`) and a stacked column above
the menu capped `max_w_48` (`:2251-2252`). The same idea appears in the editor's aside
ladder (`element.rs:4195`), which falls back from "to the right of the menu" to "above or
below the menu" when `available_within_viewport.right < MENU_ASIDE_MIN_WIDTH` (260 px,
`:4209`) or when the caller forces it. That ladder chooses its direction from **maximum**
sizes before falling back to the measured one (`element.rs:4263-4272`):

> // Prefer choosing a direction using max sizes rather than actual size for stability.

with a three-tier `fit_within` cascade: max size within the text bounds → max size within
the viewport → actual size within the viewport.

Hover-to-touch adaptation is **absent**: `InputModality::Touch` is recorded and never
branched on, and `LongPressEvent` has no consumers. Keyboard-driven relocation exists in
the editor as `show_keyboard_hover` (`hover_popover.rs:98-130`), which re-shows the hover
popover anchored to the selection head and sets a `keyboard_grace` flag so a subsequent
mouse-down clears the grace rather than dismissing. `hover_popover_sticky` is a user
setting switching the hover popover between "vanish on leave" and "grace period plus recede
detection". There are no teaching tips and no popover-to-sheet transformation.

**Degradation.** The finding for a cell-grid port is a hole rather than a design: GPUI has
no touch adaptation at all, so nothing here can be inherited for a hover-less target. What
_is_ inheritable is the shape of the decision — a pure read of the viewport (and, for a
port, the keyboard inset) inline at render, with the inset an input rather than something
discovered. Static HTML can express the wide/narrow branch with a media query and nothing
else.

### 13. Accessibility

GPUI ships a real AccessKit integration (`crates/gpui/src/window/a11y.rs`, 888 lines) that
builds a per-frame `TreeUpdate` during prepaint from a node stack, with `role()`,
`aria_label`, `aria_description`, `aria_keyshortcuts`, `accessibility_id`,
`aria_active_descendant`, synthetic children and `on_a11y_action` as the author API
(`div.rs:1250-1340`).

What the overlays use is narrow. `ContextMenu` sets `Role::Menu` on its scrolling container
(`context_menu.rs:2281`) and `Role::MenuItem` plus a label on each entry, and marks the
selected entry `aria_active_descendant` — with a good doc note that GPUI's active-descendant
is set on the _descendant_ (unlike ARIA's container-side attribute) and is honoured only
while a focused ancestor exists, so it is safe to set unconditionally (`div.rs:1298-1312`).
**Tooltips expose nothing**: rendered outside the dispatch tree, no focus handle, no role,
no described-by linkage. There is no `Role::Tooltip`, no dialog role on modals, and no
modal bit.

> [!NOTE]
> INFERENCE, not an observed tree dump: `DeferredDraw` saves and restores the element-id and
> text-style stacks but no accessibility node stack (`window.rs:930-941`), and deferred
> prepaint runs after the root subtree has fully unwound — so the structure suggests an
> overlay's accessibility nodes attach to the window root rather than to their logical
> trigger. That would be coincidentally right for a menu and wrong for a described-by
> tooltip. The node builder's stack depth across deferred rounds was not traced.

Against WCAG 1.4.13, `hoverable_tooltip` supplies hoverable and persistent (a 500 ms grace,
and it stays while hovered); dismissible is satisfied only incidentally, since a mouse-down
clears it and there is no Escape-dismisses-tooltip path. GPUI also permits _interactive_
tooltip content — `hoverable_tooltip` exists precisely for that — with no guard in the API.

**Degradation.** What plausibly belongs to a backend-neutral primitive is only: that an
overlay is a top-level surface in whatever tree exists, a stable identity so an assistive
technology can track it across frames, and an active-descendant channel so a
container-focus widget can name its selected row. Role, label, description linkage and the
modal bit belong to the semantic component. A terminal cell grid can honestly expose none
of the structure: its channels are the painted characters in reading order and the caret,
so the primitive-level contract there is to paint the overlay's text readable in order at
its final position and to make the selected row's text change when the selection changes.
See [`../platform-ui-guidelines/index.md`][platform-guidelines] for the surrounding
platform expectations.

### 14. Animation

**Not applicable, and the absence is total.** No overlay in the tree animates: the
`with_animation` helper is used for loading labels, spinners, two AI list items and edit
prediction — not for any tooltip, popover, menu, context menu or hover popover. There is no
transform-origin concept, no enter/exit transition, no spring, and no reduced-motion
handling in the overlay path.

The consequence that matters is not the missing motion but the missing **metadata**.
`Anchored::prepaint` computes the final rect, possibly flips `anchor`, and then discards the
result: the flipped corner is a local `let mut anchor` (`anchored.rs:156`) that is never
written back to `self`, never stored in element state and never observable by the child. A
child cannot learn which side it ended up on. Both real consumers therefore re-derive it by
hand — `ContextMenu` computes `flip_left` from its own observed bounds
(`context_menu.rs:1377-1380`) and uses it to switch between `right_full().mr_neg_0p5()` and
`left_full().ml_neg_0p5()` and between `Anchor::TopRight` and `Anchor::TopLeft`
(`:1790-1800`), while the editor threads a `y_flipped: bool` through `ContextMenuLayout`
into the aside placer.

The nearest thing to reposition-during-animation is an anti-jitter latch: an open submenu's
vertical `offset` is computed once, on the first frame where both the parent menu bounds
and the trigger bounds are known, and never recomputed (`context_menu.rs:2205-2229`).

**Degradation.** Nothing to degrade. The transferable lesson is negative and cheap to act
on: the resolved side, the resolved anchor and the clamp deltas should be part of the value
the placement pass _returns_. Not for animation — a cell grid has none, and shadows and
radii are dropped — but because border joins, a submenu chevron's direction, the aside's
side and any future arrow all need it, and every one of those is a grid concern.

### 15. State architecture

Three surfaces, three architectures, which is itself the finding.

1. **Tooltip** — an explicit state machine (`ActiveTooltip`, `div.rs:3516`) in an
   `Rc<RefCell<Option<ActiveTooltip>>>` with cancel-on-drop `Task`s as timers and a strict
   compute-then-apply discipline. Uncontrolled; the element owns it; the window sees only a
   `TooltipRequest` published each prepaint.
2. **Menus** — an imperative entity plus events. `ContextMenu` (`context_menu.rs:211-240`)
   is 23 fields of ad-hoc state — `selected_index`, `delayed`, `clicked`, `hover_target`,
   `submenu_state`, `submenu_safety_threshold_x`, `submenu_trigger_mouse_down`,
   `ignore_blur_until`, `suppress_focus_selection`, and several
   `Rc<Cell<Option<Bounds<Pixels>>>>` / `Rc<RefCell<HashMap<usize, Bounds<Pixels>>>>` cells
   written from `canvas()` callbacks during paint and read on the _next_ render. The only
   sum types are `SubmenuState::{Closed, Open(OpenSubmenu)}` and
   `HoverTarget::{None, MainMenu, Submenu}`.
3. **Editor hover** — a plain struct (`HoverState`, `hover_popover.rs:880-886`) whose state
   _is_ which options are `Some` and which tasks are alive; dropping a `Task` cancels it, so
   "cancel the pending show" is literally `self.info_task = None`.

`PopoverMenuHandle<M>` (`popover_menu.rs:41`) is the single controlled escape hatch: an
`Rc<RefCell<...>>` the parent holds to `show`/`hide`/`toggle`/`is_deployed`/`refresh_menu`
from outside.

The architectural smell is **measurement feedback**. A zero-size `canvas()` probe writing
`Bounds` into a shared `Cell` is used repeatedly in `context_menu.rs` — the menu's own
container measures itself at `:2257-2268`, the submenu container at `:1772-1784` — and the
values are consumed a frame later, gated by
`// Only render the aside once we have trigger bounds to avoid flicker.` (`:2390`).
`PopoverMenu` has the same lag: `child_bounds` is written in prepaint and read in the next
frame's `request_layout`. Note also that both probes above write the **same**
`main_menu_observed_bounds` cell, so what `padded_submenu_bounds()` and the `flip_left` test
read depends on which probe wrote most recently.

**Degradation.** The tooltip machine survives a value-semantics, `@nogc`-leaning port almost
verbatim: three variants plus idle, one optional timer, and a compute-then-apply discipline
that is exactly what one does when aliasing is unavailable — replace the `Task` with a
deadline value the frame loop compares against an injected clock and the whole thing becomes
plain data with a `tick()` a recording canvas can drive. The menu state bag does not
survive: its correctness rests on interior mutability and on two-way parent-child writes
through `Rc<RefCell>`, which must be inverted into events a parent reduces. The
measurement-into-`Cell` pattern should not be ported at all — a cell grid measures its own
text exactly at layout time, so anchor, size and clamp can be resolved in one pass and the
whole class of one-frame-stale bugs need not exist.

### 16. Shared infrastructure

The shared floor is thin: (1) `deferred()` plus `Window::defer_draw` — ordering, clipping
escape and context capture; (2) `anchored()` — measure, corner flip, clamp, round; (3)
`ManagedView`/`DismissEvent` plus `.occlude()` — lifetime and outside-press. Everything
above that is duplicated per surface.

`PopoverMenu` and `RightClickMenu` are two separate `Element` implementations with
near-identical structure: element state holding
`Rc<RefCell<Option<Entity<M>>>>`, `anchored().snap_to_window_with_margin(px(8.))`,
`deferred(...).with_priority(1)`, the same block that subscribes to `DismissEvent` and
restores the previously focused handle, and the same doubly-nested `on_next_frame` focus
comment copied verbatim (`popover_menu.rs:299` and `right_click_menu.rs:258-268`). They
differ only in the trigger button and in whether the anchor is the child rect or the cursor
point. `DropdownMenu` is a third wrapper over `PopoverMenu` (inferred from the component
set and the surrounding pattern; that file was not read line by line).

The editor reuses none of it: completion menus, signature help, hover popovers, the
code-action aside, the inline blame popover and edit predictions each call
`window.defer_draw` directly with hand-written placement, because they need text-range
anchoring, stacking, gap occluders and mutual avoidance that `Anchored` cannot express.
Tooltips share nothing with menus: a fourth hard-coded window slot, their own request list,
their own machine in `div.rs`, and their own placement (`window.rs:3291`) that offsets one
pixel from the cursor, mirrors about the cursor on overflow, and only then clamps.

**Algorithm.** The observable shared call sequence for every popover-like surface is:
build `deferred(anchored().anchor(A).offset(O).snap_to_window_with_margin(8px).position(P).child(div().occlude().child(entity))).with_priority(1)`;
request layout alongside the trigger; prepaint both; paint both; install a `MouseDown`
listener over the trigger hitbox that suppresses re-open.

**Degradation.** The factoring is substrate-independent. On this evidence a single anchored
overlay primitive owning ordering, context capture, one-anchor placement and dismissal
covers `PopoverMenu`, `RightClickMenu` and `DropdownMenu` — Zed's own duplication is the
argument that those three are one thing. It does **not** cover a stacked hover group, which
needs multi-body placement, gap bridging and mutual avoidance with a third surface; that
belongs above the primitive, exactly as `layout_hover_popovers` (`element.rs:4315`) is built
on raw `defer_draw`. The pairs that merely look common and should stay apart are tooltip
timing versus menu keyboard navigation, and the three focus contracts (tooltip: none; menu:
container focus plus selection index; modal: scrim plus tracked focus).

## Named algorithms

**Deferred-draw ordering (rounds plus a stable priority sort).** `defer_draw` snapshots
element, absolute offset, priority, optional mask, id/text-style stacks, rem size, current
view and dispatch parent into a flat vector. After the root prepaints, run rounds: stable
sort the current slice by priority, prepaint each entry with the saved stacks and an _empty_
clip stack under an absolute offset; entries appended during a round form the next round;
assert depth < 10. Paint runs once over all entries sorted globally. Hitboxes and mouse
listeners land in flat vectors in this order, so reverse-scan hit testing and the reverse
bubble phase get front-to-back ordering for free.

**Anchored fit: flip if it fits, then always clamp, then round.** Described in dimension 2.
Directly expressible in integer cells, since GPUI's last act is already a round to integers;
the two gaps a port should close are a documented rounding rule for centre anchors and
returning the resolved anchor plus the clamp deltas.

**Painted occluder as a pointer bridge.** For each consecutive pair of stacked popovers,
defer an element of size (popover width, gap) at the gap's origin, at the same priority,
built as `div().size_full().occlude().on_mouse_move(stop_propagation)`. It is simultaneously
a hit-test shield and an event sink, and it is ordinary display-list geometry — in cells, a
one-row rect with a block flag and no glyphs.

**Scalar submenu safe zone (menu-aim without a triangle).** Record
`threshold_x = mouse.x - 50px` on entry to the trigger and `- 100px` on subsequent motion;
close the parent's submenu on hover-lost only when `mouse.x < threshold_x`; independently
suppress closing while the pointer is inside the submenu bounds inflated by 50 px, or while
a capture-phase mouse-down latch is set on the trigger. It is one comparable number and one
inflated rect, needing no pointer history — but it is directional and is _not_ mirrored when
`flip_left` puts the submenu on the left, where the correct guard is the opposite
inequality, and it expresses no vertical intent at all.

**Monotone-approach hide with hysteresis.** `dx = max(0, |px - cx| - w/2)`,
`dy = max(0, |py - cy| - h/2)`, `d = hypot(dx, dy)`, minimised over all popover bounds;
maintain a running minimum; if `d > closest + 4px` declare the pointer receding and _arm_
(never restart) the hide timer, else update the running minimum.

**Latency-hiding split intent delay.** Wait `delay - delay/2`, issue the request, wait
`delay/2`, then render whatever arrived — the perceived intent delay is unchanged while up
to half of it overlaps request latency. Paired with the inclusive `start..=end` "same hover
target" test so intra-symbol motion never re-issues.

**Multi-body placement with mutual avoidance** (`element.rs:4315-4560`). Measure every
popover at natural size; per popover compute
`horizontal_offset = min(0, hitbox.right - POPOVER_RIGHT_OFFSET - (anchor.x + width))` — a
left-only shift (`:4386`). Then test the whole **stack** as a unit: `can_place_above` holds
only if every popover, laid out upward with the gap between, is contained in the text hitbox
_and_ does not intersect the completion menu's bounds; `can_place_below` likewise. If
neither, try four candidate origins around the completion menu in order — left of it, right
of it, above it, below it (`:4521`) — aligned to the menu's top, or to its bottom minus the
total height when the menu is itself flipped. If nothing fits, fall back and accept overlap.

**Escape as an ordered dismissal cascade** (`editor.rs:3349`). One handler runs a fixed
ordered list of dismissals, OR-combining each, and returns whether anything closed so the
caller can decide whether to propagate.

## Strengths

- The top-layer problem is solved without a top layer, and the solution is smaller than the
  problem: one `Vec`, one stable sort by `usize`, and reverse-order hit testing that falls
  out of paint order for free.
- Escaping clipping ancestors needs no portal, no reparenting and no API — it is a
  consequence of prepainting deferred draws with an empty clip stack, and it is
  regression-tested against a real scroll container.
- The painted `occlude()`d gap bridge turns "safe travel between surfaces" into ordinary
  display-list geometry that the hit test already understands: exact, cheap, and expressible
  on a cell grid.
- The tooltip is an explicit state machine with cancel-on-drop timers and a
  compute-then-apply discipline, and — decisively — it re-evaluates its own visibility
  during window prepaint rather than trusting mouse events, so it behaves correctly even
  when its owning element stops being painted.
- `ManagedView` plus `DismissEvent` is a minimal, non-aliasing lifetime contract: overlays
  never remove themselves, hosts own the handle, and focus restoration is captured at open
  time and guarded by a containment test.
- `HitboxBehavior::BlockMouseExceptScroll` separates "do not interact with what is behind
  me" from "let the scroll reach the nearest scrollable container".
- The editor's multi-popover placement is genuinely sophisticated: whole-stack containment
  tests, mutual avoidance with the completion menu, four ordered fallback origins, and a
  side chosen from maximum sizes explicitly for stability.
- Splitting the hover intent delay around the LSP request hides up to half the request
  latency at no cost to perceived responsiveness, and the inclusive `start..=end` re-hover
  test handles the real server behaviour of reporting a hover at a range's end index.
- Timers are `BackgroundExecutor` tasks the test dispatcher can `advance_clock`, so the
  tooltip machine is fully assertable headlessly.
- A menu keeps real focus on its container and expresses selection as an index plus
  `aria_active_descendant`, with the ARIA menu-button initial-selection rule implemented and
  commented.
- `MenuPosition::{PinnedToScreen, PinnedToEditor}` makes "does this overlay follow the
  document or the screen" an explicit policy value rather than an accident.

## Weaknesses

- `Anchored` discards the placement result. The flipped corner is a local binding never
  written back, so no child learns which side it landed on; `flip_left` and `y_flipped` are
  hand-reimplemented at two other call sites as a direct consequence.
- No arrow, caret or transform-origin concept exists, and no placement metadata is emitted
  that would enable one.
- No RTL, no writing modes, no multi-monitor, no work area, no safe-area insets beyond the
  Linux CSD `client_inset`, and no IME or virtual-keyboard avoidance. The boundary is always
  the whole viewport.
- Nothing dismisses an overlay on window or application deactivation, so a context menu
  stays open when the app loses focus.
- No touch story: `InputModality::Touch` and a fully specified `LongPressEvent` exist with
  zero consumers, and the tooltip's only trigger is hover.
- Tooltips are invisible to assistive technology — no role, no focus handle, no described-by
  linkage, not in the dispatch tree — and `hoverable_tooltip` permits interactive tooltip
  content with no guard.
- The submenu safe-zone threshold is directional and is not mirrored when the submenu flips
  left, which is exactly the case the flip exists to handle.
- Placement inputs are one frame stale by construction: trigger rects, menu bounds and aside
  offsets come from paint-time `canvas()` probes read on the next render, and a submenu's
  vertical offset is latched on first success and never recomputed.
- Deferred paint defers dispatch-tree linkage, so focusing a newly opened overlay needs two
  nested `on_next_frame` hops — a workaround copy-pasted with its comment into more than one
  file.
- Paint order sorts all deferred draws globally, ignoring nesting, and nested draws inherit
  no priority; the `1`/`2` convention is unwritten and enforced only by grep.
- The editor's horizontal shift is `min(0, ...)` — left-only — so an anchor near the left
  edge lets a wide popover clip off-screen; the code carries a `// TODO` admitting the same
  for the completion menu.
- Three surfaces, three unrelated state architectures, and `ContextMenu` in particular is a
  23-field mutable bag with two-way parent-child writes through `Rc<RefCell>` and three
  ad-hoc anti-race latches.
- `on_mouse_down_out` uses raw bounds containment while `on_mouse_up_out` uses the
  occlusion-aware `is_hovered`.

## Key design decisions and trade-offs

| Decision                                                                                    | Rationale                                                                                                                                                                                                         | Trade-off                                                                                                                                                                                                                             |
| ------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Defer paint only; keep the overlay's layout inside the parent tree                          | The overlay inherits the parent's layout context, text style, rem size and id namespace for free, and the parent can measure it before placing it — stated in the doc comment at `deferred.rs:14-15`              | Deferring paint also defers dispatch-tree linkage, so focusing a freshly opened menu needs two nested `on_next_frame` hops — a comment-documented wart copied into more than one file                                                 |
| Order overlays by a bare `usize` priority with a stable sort, not by a tree                 | A flat vector plus a stable sort gives deterministic front-to-back with no ownership graph and no z-index resolution, and it matches the flat hitbox/listener vectors so hit order and paint order cannot diverge | Nesting is not respected at paint time (`window.rs:3469` sorts all indices; nested draws default to priority `0`), so a nested child can paint behind an unrelated sibling or its own parent; the `1`/`2` convention is unwritten     |
| Do not re-establish a clip when prepainting deferred draws                                  | Overlays escape scroll containers and clipped ancestors with no portal concept: the hitbox records the ambient mask at insert time, and at deferred-prepaint time that mask is the whole viewport                 | Paint-time clipping must be opted into explicitly, and exactly one call site in the tree does so; everything else can and does paint over the window chrome                                                                           |
| Express modality as one flag on a hit rect, not as a modal mode                             | Three values cover scrim modals, menu bodies, occluding bridges and scroll-transparent overlays uniformly, and the semantics reach hover styles and tooltips too — "the main point of this mechanism"             | Keyboard is not blocked geometrically at all, so "modal" is only ever pointer-modal unless the component also takes focus; and with no accessibility modal bit, screen readers are not told a modal is up                             |
| Keep tooltips out of the deferred system as a fourth hard-coded window slot                 | Tooltips must sit above everything including menus, must be singleton, and must be re-evaluated for visibility even when their owning element is not painted; a reverse-scanned request list gives all three      | Tooltips then share nothing with the rest of the stack — their own placement, their own machine, no dispatch-tree presence, no accessibility node — and the else-if chain means a tooltip never appears while a drag is active        |
| Reduce menu-aim to a scalar x-threshold plus an inflated rect instead of a safe polygon     | One comparable number, no pointer history, trivially auditable; combined with the inflated bounds it covers the common diagonal path from a trigger to a right-opening submenu                                    | It is directional and unmirrored — the same `mouse.x < threshold_x` test is used when `flip_left` puts the submenu on the left — and it cannot express vertical intent                                                                |
| Measure via zero-size `canvas()` probes writing into shared `Cell`s, consumed a frame later | It gives components access to final laid-out rects the element API otherwise hides, without adding a second layout pass                                                                                           | Every consumer is one frame stale and must handle the `None` case by not rendering; submenu offsets are latched on first success and never recomputed; and two probes write the same cell, so its meaning depends on which wrote last |
| Make dismissal a message (`DismissEvent` on `ManagedView`) the host acts on                 | The overlay needs no reference to its host, its parent, or a window-level registry; the host owns the `Option<Entity<M>>` and drops it, and focus restoration is a host concern captured at open time             | Every host re-implements the same subscription block (restore previous focus if still contained, clear the option, refresh), duplicated verbatim across the component crate and again per editor surface                              |
| Choose the aside's direction from maximum sizes, not measured sizes                         | Explicitly "for stability" (`element.rs:4265`): a surface whose content streams in must not flip as it grows, so the decision is frame-invariant and only the extent is clamped to available space                | A surface that ends up much smaller than its maximum can be placed on the side with less room, and the three-tier fallback is more code than a single fit test                                                                        |

## Could not verify

- Zed, GPUI and their test suites were not built or run; all behaviour is read from source.
- The doc/source disagreement about whether `defer_draw`'s content mask applies during
  prepaint (see dimension 3) was not resolved.
- The accessibility-attachment claim in dimension 13 is an inference from the `DeferredDraw`
  field list and the prepaint ordering; no tree was dumped.
- How touch input reaches overlays on any mobile target was not established; only that no
  overlay code consumes `LongPressEvent`.
- Only the in-canvas overlay path was examined; native platform menus elsewhere in Zed (for
  example an application menu bar) were not surveyed.
- `crates/ui/src/components/dropdown_menu.rs` was not read line by line.
- No performance characteristic was measured; cost statements come from reading sort sizes
  and vector scans.

## Sources

All links below are pinned to `d71f1461045c098dc6ca6b1b5adcf1b8949722e8`.

- `crates/gpui/src/elements/deferred.rs` — the deferred element's [doc comment][deferred-doc],
  its [default priority of `0`][deferred-default-priority], and the
  [nested-reuse regression test][deferred-nested-test].
- `crates/gpui/src/elements/anchored.rs` — the whole framework placement engine:
  [`prepaint`][anchored-prepaint], the [viewport boundary][anchored-limits], the
  [corner flip][anchored-switch], the [`client_inset` fold][anchored-inset], the
  [unconditional clamp][anchored-clamp], the [rounding][anchored-round],
  [`AnchoredFitMode`][anchored-fitmode], [`AnchoredPositionMode`][anchored-posmode] and the
  [scrolled-container test][anchored-scroll-test].
- `crates/gpui/src/window.rs` — [`ManagedView`/`DismissEvent`][win-managedview],
  [keyboard modality suppressing hover][win-keyboard-modality-hover],
  [`HitboxBehavior`][win-hitbox-behavior] and its [doc rationale][win-hitbox-doc],
  [`TooltipId::is_hovered`][win-tooltipid-hovered], [`DeferredDraw`][win-deferreddraw],
  [`Frame::hit_test`][win-hittest], the [paint-slot chain][win-draw-slots],
  [`prepaint_tooltip`][win-prepaint-tooltip],
  [`prepaint_deferred_draws`][win-prepaint-deferred], the
  [index-stability invariant][win-index-invariant], the [per-round sort][win-round-sort],
  [`paint_deferred_draws`][win-paint-deferred], the [global paint sort][win-global-sort],
  the [content-mask fallback][win-content-mask], [`defer_draw`][win-defer-draw],
  [`insert_hitbox`][win-insert-hitbox] and [input modality][win-input-modality].
- `crates/gpui/src/geometry.rs` — [`Bounds::from_anchor_and_size`][geo-from-anchor],
  [`Bounds::corner`][geo-corner], [`Anchor`][geo-anchor],
  [`Anchor::other_side_along`][geo-other-side].
- `crates/gpui/src/elements/div.rs` — the [tooltip delays][div-delays],
  [`on_mouse_down_out`][div-mouse-down-out] / [`on_mouse_up_out`][div-mouse-up-out], the
  [active-descendant semantics][div-active-descendant], [`ActiveTooltip`][div-active-tooltip],
  [`register_tooltip_mouse_handlers`][div-register-tooltip], the
  [compute-then-apply discipline][div-action-enum], the
  [prepaint-time visibility re-check][div-check-visible], and the
  [tooltip][div-tooltip-test] and [system-prompt][div-prompt-test] regression tests.
- `crates/gpui/src/gestures.rs` — [`LongPressEvent`][gestures-longpress] and its
  [thresholds][gestures-thresholds] (unused by overlays).
- `crates/gpui/src/window/a11y.rs` — the [AccessKit tree builder][a11y-root].
- `crates/ui/src/components/context_menu.rs` — the [state bag][cm-state],
  [blur dismissal][cm-blur], the [ARIA focus-in rule][cm-focus-in], [`cancel`][cm-cancel] and
  its [grace window][cm-cancel-grace], [selection navigation][cm-select-next],
  [`open_submenu`][cm-open-submenu], [`flip_left`][cm-flip-left], the
  [keyboard blur grace][cm-blur-grace], the safe-zone thresholds
  ([100 px][cm-threshold-100], [50 px][cm-threshold-50]),
  [`padded_submenu_bounds`][cm-padded-bounds], the [submenu measurement probe][cm-submenu-probe]
  and [submenu anchor][cm-submenu-anchor], the [close test][cm-should-close],
  [`is_wide_window`][cm-wide-window], the [submenu offset latch][cm-offset-latch], the
  [menu measurement probe][cm-menu-probe], [`Role::Menu`][cm-role-menu],
  [outside-press][cm-down-out], the [anti-flicker gate][cm-flicker] and the
  [navigation test][cm-nav-test].
- `crates/ui/src/components/popover_menu.rs` — [`PopoverMenuHandle`][pm-handle], the
  [signed gap offset][pm-offset], [focus capture][pm-prev-focus], the
  [two-frame focus comment][pm-focus-comment], the [anchored/deferred sequence][pm-anchored],
  the [corner conversion][pm-corner] and the [re-click suppression][pm-reclick]; the same
  scaffolding duplicated in `right_click_menu.rs` ([trigger][rcm-trigger],
  [focus restore][rcm-restore]).
- `crates/ui/src/components/{tooltip.rs,popover.rs}` — the
  [padding-as-offset comment][tooltip-padding] and [`POPOVER_Y_PADDING`][popover-padding].
- `crates/editor/src/element.rs` — [`layout_popovers_above_or_below_line`][ed-above-below],
  the [flip decision][ed-yflip], the [min-height re-evaluation][ed-minheight], the
  [left-clip TODO][ed-todo-left], the [right-edge snap][ed-x-snap],
  [`layout_context_menu_aside`][ed-aside] and its [min-width gate][ed-aside-gate], the
  [max-sizes-for-stability comment][ed-max-sizes], [`layout_hover_popovers`][ed-hover-popovers],
  the [left-only horizontal shift][ed-hshift], [`draw_occluder`][ed-occluder], the
  [whole-stack containment tests][ed-can-place] and the
  [candidate origins around the menu][ed-candidates].
- `crates/editor/src/hover_popover.rs` — [`HOVER_POPOVER_GAP`][hp-gap], the
  [do-not-restart note][hp-timer-note], [`show_keyboard_hover`][hp-keyboard-hover], the
  [split intent delay][hp-split-delay], the [inclusive range test][hp-inclusive-range],
  [`HoverState`][hp-state], [`is_mouse_getting_closer`][hp-closer], its
  [hysteresis band][hp-hysteresis] and the [row clamp][hp-anchor-clamp].
- `crates/editor/src/{mouse_context_menu.rs,editor.rs,code_context_menus.rs,edit_prediction.rs}`
  and `crates/editor/src/element/mouse.rs` — [`MenuPosition`][mcm-menuposition], the
  [dismissal cascade][ed-dismiss-cascade], the [menu gap constants][ed-menu-consts], the
  [only masked deferred draw][ed-masked-defer] and the
  [pinned-to-editor visibility test][ed-menu-visibility].
- `crates/workspace/src/modal_layer.rs` — the [scrim plus light-dismiss modal][modal-layer].
- `assets/settings/default.json` — the [user-facing hover timings][settings-hover].

Related reading in this catalog: [`./index.md`][index], [`./concepts.md`][concepts],
[`./comparison.md`][comparison], [`./features-people-forget.md`][forget],
[`./sparkles-baseline.md`][baseline], [`./proposal.md`][proposal]. The closest siblings by
surface model are [`./imgui.md`][imgui], [`./flutter.md`][flutter],
[`./textual.md`][textual] and [`./notcurses.md`][notcurses]; for the OS-surface contrast see
[`./xdg-positioner.md`][xdg] and [`./gtk4.md`][gtk4]. Toolkit context lives in
[`../../specs/ui/index.md`][spec-ui], [`../../specs/ui/input.md`][spec-input],
[`../../specs/ui/containers.md`][spec-containers],
[`../../specs/ui/state-machines.md`][spec-stm], [`../../specs/ui/backends.md`][spec-backends]
and [`../../specs/ui/widgets.md`][spec-widgets]; adjacent research in
[`../window-system-integration/index.md`][wsi], [`../ui-layout/index.md`][ui-layout] and
[`../sean-parent/index.md`][sean-parent].

<!-- References -->

[zed-repo]: https://github.com/zed-industries/zed/tree/d71f1461045c098dc6ca6b1b5adcf1b8949722e8
[gpui-readme]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui/README.md
[deferred-doc]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui/src/elements/deferred.rs#L14
[deferred-default-priority]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui/src/elements/deferred.rs#L10
[deferred-nested-test]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui/src/elements/deferred.rs#L156
[anchored-prepaint]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui/src/elements/anchored.rs#L122
[anchored-limits]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui/src/elements/anchored.rs#L150
[anchored-switch]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui/src/elements/anchored.rs#L155
[anchored-inset]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui/src/elements/anchored.rs#L181
[anchored-clamp]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui/src/elements/anchored.rs#L189
[anchored-round]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui/src/elements/anchored.rs#L207
[anchored-fitmode]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui/src/elements/anchored.rs#L243
[anchored-posmode]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui/src/elements/anchored.rs#L254
[anchored-scroll-test]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui/src/elements/anchored.rs#L349
[geo-from-anchor]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui/src/geometry.rs#L837
[geo-corner]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui/src/geometry.rs#L1418
[geo-anchor]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui/src/geometry.rs#L2165
[geo-other-side]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui/src/geometry.rs#L2217
[win-managedview]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui/src/window.rs#L691
[win-keyboard-modality-hover]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui/src/window.rs#L750
[win-hitbox-behavior]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui/src/window.rs#L845
[win-hitbox-doc]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui/src/window.rs#L866
[win-tooltipid-hovered]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui/src/window.rs#L908
[win-deferreddraw]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui/src/window.rs#L930
[win-hittest]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui/src/window.rs#L1059
[win-draw-slots]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui/src/window.rs#L3218
[win-prepaint-tooltip]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui/src/window.rs#L3291
[win-prepaint-deferred]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui/src/window.rs#L3360
[win-index-invariant]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui/src/window.rs#L3366
[win-round-sort]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui/src/window.rs#L3384
[win-paint-deferred]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui/src/window.rs#L3430
[win-global-sort]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui/src/window.rs#L3469
[win-content-mask]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui/src/window.rs#L3811
[win-defer-draw]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui/src/window.rs#L4012
[win-insert-hitbox]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui/src/window.rs#L4820
[win-input-modality]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui/src/window.rs#L5107
[div-delays]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui/src/elements/div.rs#L49
[div-mouse-down-out]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui/src/elements/div.rs#L259
[div-mouse-up-out]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui/src/elements/div.rs#L279
[div-active-descendant]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui/src/elements/div.rs#L1298
[div-active-tooltip]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui/src/elements/div.rs#L3516
[div-register-tooltip]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui/src/elements/div.rs#L3573
[div-action-enum]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui/src/elements/div.rs#L3642
[div-check-visible]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui/src/elements/div.rs#L3757
[div-tooltip-test]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui/src/elements/div.rs#L4681
[div-prompt-test]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui/src/elements/div.rs#L4789
[gestures-longpress]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui/src/gestures.rs#L169
[gestures-thresholds]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui/src/gestures.rs#L115
[a11y-root]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui/src/window/a11y.rs#L477
[cm-state]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/ui/src/components/context_menu.rs#L211
[cm-blur]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/ui/src/components/context_menu.rs#L282
[cm-focus-in]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/ui/src/components/context_menu.rs#L304
[cm-cancel]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/ui/src/components/context_menu.rs#L1057
[cm-cancel-grace]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/ui/src/components/context_menu.rs#L1066
[cm-select-next]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/ui/src/components/context_menu.rs#L1145
[cm-open-submenu]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/ui/src/components/context_menu.rs#L1358
[cm-flip-left]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/ui/src/components/context_menu.rs#L1377
[cm-blur-grace]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/ui/src/components/context_menu.rs#L1393
[cm-threshold-100]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/ui/src/components/context_menu.rs#L1628
[cm-threshold-50]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/ui/src/components/context_menu.rs#L1665
[cm-padded-bounds]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/ui/src/components/context_menu.rs#L1750
[cm-submenu-probe]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/ui/src/components/context_menu.rs#L1772
[cm-submenu-anchor]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/ui/src/components/context_menu.rs#L1790
[cm-should-close]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/ui/src/components/context_menu.rs#L2043
[cm-wide-window]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/ui/src/components/context_menu.rs#L2199
[cm-offset-latch]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/ui/src/components/context_menu.rs#L2205
[cm-menu-probe]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/ui/src/components/context_menu.rs#L2257
[cm-role-menu]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/ui/src/components/context_menu.rs#L2281
[cm-down-out]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/ui/src/components/context_menu.rs#L2313
[cm-flicker]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/ui/src/components/context_menu.rs#L2390
[cm-nav-test]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/ui/src/components/context_menu.rs#L2441
[pm-handle]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/ui/src/components/popover_menu.rs#L41
[pm-offset]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/ui/src/components/popover_menu.rs#L259
[pm-prev-focus]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/ui/src/components/popover_menu.rs#L281
[pm-focus-comment]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/ui/src/components/popover_menu.rs#L299
[pm-anchored]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/ui/src/components/popover_menu.rs#L377
[pm-corner]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/ui/src/components/popover_menu.rs#L382
[pm-reclick]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/ui/src/components/popover_menu.rs#L483
[rcm-trigger]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/ui/src/components/right_click_menu.rs#L245
[rcm-restore]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/ui/src/components/right_click_menu.rs#L258
[tooltip-padding]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/ui/src/components/tooltip.rs#L223
[popover-padding]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/ui/src/components/popover.rs#L9
[ed-above-below]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/editor/src/element.rs#L4069
[ed-yflip]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/editor/src/element.rs#L4100
[ed-minheight]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/editor/src/element.rs#L4114
[ed-todo-left]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/editor/src/element.rs#L4143
[ed-x-snap]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/editor/src/element.rs#L4158
[ed-aside]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/editor/src/element.rs#L4195
[ed-aside-gate]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/editor/src/element.rs#L4209
[ed-max-sizes]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/editor/src/element.rs#L4265
[ed-hover-popovers]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/editor/src/element.rs#L4315
[ed-hshift]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/editor/src/element.rs#L4386
[ed-occluder]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/editor/src/element.rs#L4404
[ed-can-place]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/editor/src/element.rs#L4471
[ed-candidates]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/editor/src/element.rs#L4521
[ed-dismiss-cascade]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/editor/src/editor.rs#L3349
[ed-masked-defer]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/editor/src/edit_prediction.rs#L2128
[ed-menu-consts]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/editor/src/code_context_menus.rs#L48
[ed-menu-visibility]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/editor/src/element/mouse.rs#L311
[hp-gap]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/editor/src/hover_popover.rs#L39
[hp-timer-note]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/editor/src/hover_popover.rs#L79
[hp-keyboard-hover]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/editor/src/hover_popover.rs#L98
[hp-split-delay]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/editor/src/hover_popover.rs#L316
[hp-inclusive-range]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/editor/src/hover_popover.rs#L628
[hp-state]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/editor/src/hover_popover.rs#L880
[hp-closer]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/editor/src/hover_popover.rs#L893
[hp-hysteresis]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/editor/src/hover_popover.rs#L921
[hp-anchor-clamp]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/editor/src/hover_popover.rs#L984
[mcm-menuposition]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/editor/src/mouse_context_menu.rs#L21
[modal-layer]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/workspace/src/modal_layer.rs#L285
[settings-hover]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/assets/settings/default.json#L146
[index]: ./index.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[forget]: ./features-people-forget.md
[baseline]: ./sparkles-baseline.md
[proposal]: ./proposal.md
[imgui]: ./imgui.md
[flutter]: ./flutter.md
[textual]: ./textual.md
[notcurses]: ./notcurses.md
[xdg]: ./xdg-positioner.md
[gtk4]: ./gtk4.md
[wsi]: ../window-system-integration/index.md
[platform-guidelines]: ../platform-ui-guidelines/index.md
[ui-layout]: ../ui-layout/index.md
[sean-parent]: ../sean-parent/index.md
[spec-ui]: ../../specs/ui/index.md
[spec-input]: ../../specs/ui/input.md
[spec-containers]: ../../specs/ui/containers.md
[spec-stm]: ../../specs/ui/state-machines.md
[spec-backends]: ../../specs/ui/backends.md
[spec-widgets]: ../../specs/ui/widgets.md
