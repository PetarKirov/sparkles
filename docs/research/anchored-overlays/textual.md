# Textual (Python / terminal cell grid)

Textual has no anchored-overlay subsystem at all: it teaches its ordinary layout engine three small CSS rules — `layers`/`layer`, `overlay`, `constrain` — and every overlay it ships is an ordinary widget that stayed exactly where it was declared.

| Field             | Value                                                                                              |
| ----------------- | -------------------------------------------------------------------------------------------------- |
| Language          | Python                                                                                             |
| License           | MIT (`pyproject.toml:10`)                                                                          |
| Repository        | [`Textualize/textual`][repo]                                                                       |
| Documentation     | [textual.textualize.io][docs] — but see the caveat below: two of the three rules are undocumented  |
| Category          | Terminal / cell grid                                                                               |
| Surface model     | In-canvas. One character grid, integer cells, no OS popup, no compositor, no [top layer][concepts] |
| Package version   | `8.2.8` (`pyproject.toml:3`)                                                                       |
| **Revision read** | `06dbeef4bb70fb718236aa418ed658ef4667a126`                                                         |

This is an implementation reading of the source tree at that revision, cross-checked against the repository's own tests and `CHANGELOG.md`. Nothing was executed: no `textual` module was importable in the reading environment, so every behavioural statement below is read from source plus committed tests, never reproduced at runtime.

## Overview

### What it solves

Textual is a Python TUI framework whose renderer is a cell-grid compositor. It therefore lives under most of the constraints `sparkles:ui` lives under — one surface, integer cells, no OS popup to portal into, no pointer [grab][concepts] — and it still ships four distinct overlay surfaces: a hover tooltip, a toast stack, a `Select` dropdown, and a modal command palette. It is consequently the closest thing in this catalog to an existence proof that an escaping, anchored, non-displacing surface is achievable with nothing but a layout engine and a paint order. See [`./concepts.md`][concepts] for the shared vocabulary and [`./index.md`][index] for how this subject sits against the rest.

What it does **not** solve: there is no menu, no context menu, no submenu, no arrow/caret, no [safe polygon][concepts], no accessibility surface, no overlay animation, and no [virtual anchor][concepts]. Several of those absences are structurally motivated by the cell grid and are recorded as findings in their own right below.

### Design philosophy

Do not build an overlay system; make the existing layout engine able to express one. The entire shared kernel is four things: `Region.constrain` (with `Region.inflect` and `Region.translate_inside`), `Widget.absolute_offset`, the `overlay: screen` exemptions, and the layer/paint-order machinery. Everything above that is per-widget policy, deliberately unfactored: `Tooltip` is a 24-line file that is almost entirely CSS.

The whole placement policy of the tooltip is four declarations (`src/textual/widgets/_tooltip.py:9-18`):

```python
layer: _tooltips;
margin: 1 0;
padding: 1 2;
background: $panel;
width: auto;
height: auto;
constrain: inside inflect;
max-width: 40;
display: none;
offset-x: -50%;
```

`constrain: inside inflect` means _slide horizontally, flip vertically_; `offset-x: -50%` is how "centre on the anchor point" is spelled (a percentage of the widget's **own** size, resolved by `ScalarOffset.resolve` at `src/textual/css/scalar.py:350` and rounded to whole cells); `margin: 1 0` is simultaneously the anchor gap, the flip distance and the viewport padding.

> [!IMPORTANT]
> `overlay` and `constrain` — the two rules that actually make an anchored overlay possible — are **not in the published style reference**. `docs/styles/` contains `layer.md` and `layers.md` and no `overlay.md` or `constrain.md`; a grep of `docs/` finds `constrain` only in a 2023 release blog post and in unrelated widget pages. Both rules are still labelled "Experimental" in the changelog entries that introduced them (`CHANGELOG.md:2576-2577`, both citing PR 2501). They exist to serve `Tooltip` and `Select`.

## How it works

Placement happens inside the ordinary reflow, in one forward pass, with no observers and no second measurement pass.

1. `_arrange.arrange` partitions a container's displayed children by layer name and runs the **entire** per-container pipeline once per layer over the **same** region (`src/textual/_arrange.py:61-65`).
2. Each pipeline emits `WidgetPlacement` values; the `overlay` flag rides along on the placement (`src/textual/layout.py:93`).
3. The compositor maps every placement through `WidgetPlacement.process_offset` (`src/textual/_compositor.py:634`), which applies `Widget.absolute_offset` (if any) and then `Region.constrain` (`src/textual/layout.py:160-190`).
4. The compositor computes a paint-order tuple per widget and a clip per widget, with `overlay: screen` resetting both (`src/textual/_compositor.py:678-687`).
5. Rendering walks the map front-to-back with per-row "cuts", first writer wins (`src/textual/_compositor.py:1200-1242`).

The placement step, verbatim (`src/textual/layout.py:181-190`):

```python
if widget.absolute_offset is not None:
    region = region.at_offset(
        widget.absolute_offset + margin.top_left - absolute_offset
    )

region = region.translate(self.offset).constrain(
    styles.constrain_x,
    styles.constrain_y,
    self.margin,
    constrain_region - absolute_offset,
)
```

`absolute_offset` here is the placement scroll offset — the only coordinate-space conversion in the pipeline.

## The analysis spine

### 1. Anchor model

Textual has two anchor models and neither is an [anchor rect][concepts].

**(a) Point anchor.** `Widget.absolute_offset: Offset | None` (`src/textual/widget.py:486`, made public in 0.83 per `CHANGELOG.md:1053`) is a field on the **popup**, not on the trigger. `Screen._handle_tooltip_timer` sets `tooltip.absolute_offset = self.app.mouse_position` (`src/textual/screen.py:1627`). The anchor is therefore a bare pair of integer cells — the cursor cell — carrying no reference to the trigger widget at all.

**(b) Implicit-parent anchor.** `SelectOverlay` has no anchor of any kind. It is an ordinary second child of `Select`, and its position falls out of the parent's vertical flow (immediately below `SelectCurrent`); `overlay: screen` then makes it non-displacing (`src/textual/widgets/_select.py:329-330`). "Anchored below the trigger" is expressed as "be the next sibling".

Trigger and anchor **can** be detached: in the tooltip case the trigger is the hovered widget while the anchor is the cursor. Many triggers share one popup — a single `Tooltip` instance is inserted per `Screen` (`src/textual/screen.py:1161-1162`) and mutated in place — and content is resolved by walking `widget.ancestors_with_self` for the first non-`None` `.tooltip`, so tooltip content is **inherited down the tree** (`src/textual/screen.py:1615-1621`).

**Algorithm.**

```text
anchorPoint = app.mouse_position                      # screen cells
placed.origin = anchorPoint + margin.topLeft - placementScrollOffset
placed = placed.translate(resolvedStyleOffset)        # offset-x: -50% -> -round(width/2)
placed = placed.constrain(cx, cy, margin, screenRegion)
```

For the sibling model there is no anchor value at all: the origin comes from the parent's flow cursor.

**Where the behaviour lives.** Library code only, in three places: the field on `Widget`, its consumption in `WidgetPlacement.process_offset`, and the tooltip timer callback on `Screen`. There is no anchor registry, no anchor observer and no anchor-to-screen conversion step beyond subtracting the placement scroll offset.

**Degradation.** `Offset` is an immutable, hashable, comparable pair of `int` (`src/textual/geometry.py:72`) — a plain value that needs no OS window, no sub-cell precision and no key release. What does not survive the loss of hover is the **source** of the point: the tooltip's anchor is the cursor, so on a target with no pointer hover the point anchor has no producer, and the fallback is the sibling/trigger model that `Select` already demonstrates. Under no-script static emission the anchor is still expressible (it is a constant), but nothing re-measures it.

### 2. Placement model

There is no side/alignment vocabulary and no [gravity][concepts] enum. [Placement][concepts] is three things: a raw integer origin, a per-axis mode drawn from a three-value enum `Constrain = Literal["none", "inflect", "inside"]` (`src/textual/css/types.py:41`), and the ordinary `offset-x`/`offset-y` style, which may be a percentage of the widget's own size.

There is no preferred-placement list, no fallback ordering, no auto placement, no RTL or writing-mode handling, no work areas, no multi-monitor concept, and no soft-keyboard avoidance. The axes are fully independent: the tooltip is `inside inflect` (slide on x, [flip][concepts] on y) and the `Select` dropdown is `none inside` (never flip; slide on y only). Reading the CSS together with the solver, a dropdown that would fall off the bottom slides **up over its own trigger** rather than flipping above it — this is read from `_select.py:330` plus `Region.constrain`, not observed; no snapshot test isolates a `Select` opened near the bottom edge.

Viewport padding is expressed as the popup's own `margin`, which is subtracted from the container before clamping (`container.shrink(margin)`) and also added to the flip distance.

**Algorithm** (`src/textual/geometry.py:1043-1119`):

```text
constrain(cx, cy, margin, container):
    marginRegion = self.grow(margin)
    if cx == inflect or cy == inflect:
        dx = cx == inflect ? -compare_span(marginRegion.x, marginRegion.right,
                                           container.x, container.right) : 0
        dy = cy == inflect ? -compare_span(marginRegion.y, marginRegion.bottom,
                                           container.y, container.bottom) : 0
        region = region.inflect(dx, dy, margin)
    region = region.translate_inside(container.shrink(margin), cx != none, cy != none)

compare_span(s, e, cs, ce) = 0 if (s >= cs and e <= ce) else (-1 if s < cs else +1)
translate_inside(c, xAxis, yAxis):
    x' = max(min(x, c.x + c.width - width), c.x)      # same shape for y
```

**Where the behaviour lives.** `Region.constrain` / `Region.inflect` / `Region.translate_inside` are pure integer functions on a `NamedTuple` in `src/textual/geometry.py` (`1043`, `999`, `961`) with zero framework dependencies. Policy selection lives in CSS (`src/textual/css/_styles_builder.py`, `process_constrain`).

**Degradation.** The most portable thing in the subject: four integers in, four integers out. No window, no script, no hover, no sub-cell precision, no key release. The missing piece is the **container**: the signature accepts one, but the sole call site passes `size.region` — the whole screen (`src/textual/_compositor.py:634`) — so viewport insets, docked panels and safe areas cannot influence placement in practice even though the API would accept them. Under no-script static emission only the `none` mode survives, since flip cannot be evaluated without measurement.

### 3. Collision & geometry engine

Overflow detection is `compare_span` against **one** rect. There is no [clipping-boundary][concepts] discovery, because `overlay: screen` simply replaces the clip with the full surface (`no_clip if overlay else sub_clip`, `src/textual/_compositor.py:687`). Transforms, zoom, device pixel ratio and fractional pixels do not exist; the only fractional arithmetic is `Fraction` inside box-model resolution, floored to integers before placement.

There is no observer, no polling and no animation-frame tracking. Placement is recomputed as part of the ordinary reflow, driven by the message loop; anchor movement is handled by re-running the whole thing. `_arrange_root` (`src/textual/_compositor.py:525`) rebuilds the compositor map; `layers_visible` (`:768`) builds one front-to-back list per screen row; hit testing is a linear scan of one row's list (`get_widget_at`, `:829-846`). `Region.grow`/`shrink`/`intersection` carry `@lru_cache(maxsize=4096)` — a Python-specific mitigation with no analogue in a compiled value-semantics port.

Compositing walks **front to back** with per-row cuts and first-writer-wins (`src/textual/_compositor.py:1237-1241`):

```python
# Since we are painting front to back, the first segments for a cut "wins"
get_chops_line = chops_line.get
for cut, strip in zip(final_cuts, cut_strips):
    if get_chops_line(cut) is None:
        chops_line[cut] = strip
```

Occlusion is therefore resolved with no z-buffer and no overdraw: every cell is composed exactly once.

**Where the behaviour lives.** `_compositor.Compositor` is the framework kernel; the geometry primitives in `geometry.py` are dependency-free and are the reusable half.

**Degradation.** The rect algebra generalises off its substrate completely — `Region`/`Offset`/`Size`/`Spacing` are integer `NamedTuple`s with `union`, `intersection`, `grow`, `shrink`, `split`, `translate_inside`, `inflect`, `constrain`, `contains`. The cut renderer does not generalise to a back-to-front display list and is not needed there. With no OS window nothing changes, because none of this ever used one; with no script none of it runs at emit time.

### 4. Arrow / caret geometry

**Not applicable — and the absence is the finding.** Textual has no arrow, tail, beak or caret on any overlay, and no code that could produce one. The smallest addressable unit is one character cell, so a tail would be a single glyph occupying a whole cell, centred only to cell granularity.

The direction indicator lives on the **trigger** instead: `SelectCurrent` composes a `▼` and a `▲` static (`src/textual/widgets/_select.py:263-264`) and CSS swaps which is displayed via the `-expanded` class (`:343-346`). Tooltips get proximity alone: one row off the cursor via `margin: 1 0`.

Nothing exposes an arrow size to the offset computation, because there is no arrow. The gap **is** the margin, and the margin is simultaneously the flip distance and the viewport padding — one value serving three roles, which removes a parameter from the placement API and also makes "a 1-cell gap with a 2-cell screen inset" inexpressible.

**Degradation.** At cell granularity an arrow degrades to either a one-cell glyph that can point in four directions and be centred only to the nearest cell, or to nothing. Textual chose nothing for the tooltip and a trigger-side chevron for the dropdown. The structure suggests that for a cell-grid toolkit arrow geometry belongs with drop shadow and corner radius — a droppable theme concern plus at most one integer offset along the shared edge — rather than inside the placement primitive; see [`./features-people-forget.md`][ffpf] and [`./proposal.md`][proposal] for where that argument is settled against the rest of the corpus.

### 5. Trigger semantics

**Tooltip: hover only.** `Screen._handle_mouse_move` (`src/textual/screen.py:1630`) is the sole entry point. There is no focus trigger, no keyboard trigger, no long-press and no programmatic show — setting `Widget.tooltip` only refreshes an already-visible tooltip for the same widget.

**Select: three triggers, one reactive.** A click on `SelectCurrent` posts `Toggle`; the binding `Binding("enter,down,space,up", "show_overlay", ...)` (`src/textual/widgets/_select.py:292-293`) runs `action_show_overlay`; and `Select.expanded` may be set programmatically. Races are avoided not by arbitration but by funnelling every trigger into a single `expanded: var[bool]` (`:358`) whose watcher `_watch_expanded` (`:631`) is idempotent — the state, not the event, is the source of truth.

There is no pointer-type distinction (no touch/pen), no right-click or context-menu concept anywhere in the tree, and no assistive-technology-triggered path.

**Algorithm.** Click is synthesised from a press/release pair (`src/textual/app.py:4086-4118`): on mouse-down record the widget under the pointer; on mouse-up, if the widget under the pointer is the same object, synthesise a `Click` with a chain count (incremented when the screen offset matches and the gap is within `CLICK_CHAIN_TIME_THRESHOLD = 0.5`, `src/textual/app.py:450`). `Widget.suppress_click()` (`src/textual/widget.py:4306-4313`) nulls the recorded mouse-down widget so the pending synthesised click never fires — `SelectOverlay._on_blur` calls it (`src/textual/widgets/_select.py:165-168`) so that clicking the trigger to close does not immediately reopen the dropdown.

**Degradation.** Hover-only triggering has no substitute in this codebase, so a target without hover loses the tooltip entirely rather than degrading it. The reactive-funnel pattern is substrate-independent (one boolean in a state value). Click synthesis needs both a press and a release; that is a pointer-release requirement, not a key-release one, so it is reproducible wherever the backend reports pointer release. `suppress_click` is the portable trick here: without it, "click outside to dismiss" (which fires on the down edge) and "click trigger to toggle" (which fires on the synthesised click) fight each other.

### 6. Timing

One constant, one timer. `App.TOOLTIP_DELAY: float = 0.5` (`src/textual/app.py:470`); `Screen._tooltip_timer` (`src/textual/screen.py:298`) is always stopped before being replaced. There is no close delay, no [warm-up][concepts], no [cool-down][concepts] or skip-delay, no instant-subsequent-tooltip, no maximum display duration and no group registry — moving from one footer key to the next restarts the full 0.5 s.

The surprising part is pinned by a test. While a tooltip is displayed, a further mouse move over the **same** widget takes the `else` branch and hides it, **without** re-arming (`src/textual/screen.py:1665-1677`):

```python
if self._tooltip_widget != widget or not tooltip.display:
    self._tooltip_widget = widget
    if self._tooltip_timer is not None:
        self._tooltip_timer.stop()
    self._tooltip_timer = self.set_timer(
        self.app.TOOLTIP_DELAY,
        partial(self._handle_tooltip_timer, widget),
        name="tooltip-timer",
    )
else:
    tooltip.display = False
```

The next move sees `not tooltip.display` and re-arms. So the machine requires 0.5 s of pointer **stillness**, and a one-cell jiggle kills a shown tooltip; `tests/test_tooltips.py:56` (`test_mouse_move_removes_a_tooltip`) pins exactly that. Any key press while something is focused also clears it (`src/textual/app.py:4131-4135`, recorded at `CHANGELOG.md:1395`).

Toasts use an orthogonal model worth separating out: expiry is a wall-clock deadline on the **data** (`Notification.time_left` / `has_expired`, `src/textual/notifications.py:52-58`), and the widget's timer is seeded from the remaining time when it mounts (`src/textual/widgets/_toast.py:104`, `:130`). A toast raised while another screen was active shows for whatever is left, not a fresh countdown.

**Algorithm** (the machine implied by the source; states Idle / Armed / Shown):

```text
MouseMove(w):  if state.widget != w or state == Idle  -> stop timer; Armed(w, now + DELAY)
               else if state == Shown                 -> hide (the next move re-arms)
TimerFires:    content = firstNonNull(ancestorsWithSelf(w).tooltip)
               if none -> Idle else Shown(w), anchor = cursor
NoWidgetUnderPointer | AnyKey | ScreenSuspend | layoutRefreshMovedTheAnchor -> Idle
```

**Where the behaviour lives.** Split: the timer and all transitions on `Screen`, the delay constant and the any-key clear on `App`, notification lifetimes in a pure data collection independent of any widget.

**Degradation.** With no timers at all the dimension collapses to "show on hover, instantly". Every transition here is driven by an explicit timer callback, which is why the framework's own tests can step it (`await pilot.hover(...)`, `await pilot.pause(...)`, then assert `display`). The absolute-deadline-on-the-data pattern is the transferable idea: it makes an overlay's lifetime independent of which surface or which frame renders it.

### 7. Interactive hover

**Not applicable.** There is no [safe polygon][concepts], no pointer bridge, no menu-aim or diagonal-intent heuristic, no interactive tolerance border, no trajectory tracking and no debounce beyond the single arm timer. There is no submenu because there is no menu.

Within this subject, travel from trigger to tooltip content is impossible by construction, on two independent counts: the tooltip is hidden by the very mouse move that would carry the pointer toward it (`src/textual/screen.py:1676-1677`), and if the pointer ever did land on the `Tooltip` widget, the ancestor walk in `_handle_tooltip_timer` would find no `.tooltip` on it and hide it (`:1615-1624`). The corridor the tooltip leaves is one row (`margin: 1 0`), so there is very little for a travel heuristic to act on even in principle.

The nearest thing to nested interactive surfaces is `Select` → `SelectOverlay`, which is click- and keyboard-driven rather than hover-traversed; its option highlighting under the mouse reads per-cell style metadata (`event.style.meta.get("option")`, `src/textual/widgets/_option_list.py:746`) rather than doing geometry.

**Degradation.** The cell-grid substitute Textual actually ships is instructive: make the interactive surface **focusable and keyboard-first**, and demote hover to pure styling. That answer needs no hover, no sub-cell precision and no key release, and it is the one that survives on a target with no pointer at all.

### 8. Dismissal

Tooltip dismissal is a list of independent invalidations, each wired separately:

- the pointer moves to a different widget (re-arm; content resolves to `None` → hide);
- the pointer leaves all widgets (`NoWidget` → `display = False`, `src/textual/screen.py:1641-1648`);
- any key press while something is focused (`src/textual/app.py:4131-4135`);
- screen suspend (`_on_screen_suspend` → `_clear_tooltip`, `src/textual/screen.py:1502`);
- and the interesting one, a **layout-driven** invalidation.

`Screen._refresh_layout` publishes `screen_layout_refresh_signal` at the end of every layout pass (`src/textual/screen.py:1393`); the screen subscribes itself at mount with `immediate=True` (`:1166-1170`); the handler re-runs one hit test (`_maybe_clear_tooltip`, `:1585-1601`):

```python
if self._tooltip_widget is not None:
    try:
        under_mouse, _ = self.get_widget_at(*self.app.mouse_position)
    except NoWidget:
        pass
    else:
        if under_mouse is not self._tooltip_widget:
            self._clear_tooltip()
```

That single hook covers anchor removed, anchor made invisible, anchor made `display: none`, and anchor shuffled out from under the cursor by a sibling being mounted — four causes, four regression tests (`tests/test_tooltips.py:69`, `:82`, `:95`, `:108`).

`Select` dismissal is separate: an `escape` binding posts `Dismiss` (`src/textual/widgets/_select.py:51`); blur posts `Dismiss(lost_focus=True)` and calls `suppress_click()` (`:165-168`); selecting an option refocuses the `Select` and sets `expanded = False`. Clicking outside works because mouse-down focuses the topmost focusable ancestor, or `set_focus(None)` when there is no widget, which blurs the overlay. There is no dismiss-on-scroll and no separate dismiss-on-resize (a resize reflows, so the liveness hook covers it incidentally).

**Degradation.** The layout-refresh liveness re-hit-test is the most transplantable dismissal mechanism in the subject: it needs no observers, no OS window and no mutation hooks, only an authoritative post-reflow hit list. It is cursor-based as written, which is its limit — it works only while a pointer is present, and it cannot distinguish "the anchor moved three cells but is still under the cursor" from "nothing changed". `Escape` on the dropdown is a press-edge binding, so no key release is required.

### 9. Focus

The four surface kinds are kept strictly distinct, and the distinction **is** the focus policy.

| Surface         | Focusable | Restoration on close                                                                                                  |
| --------------- | --------- | --------------------------------------------------------------------------------------------------------------------- |
| `Tooltip`       | no        | n/a — a `Static` subclass, never focused, never a tab stop                                                            |
| `Toast`         | no        | n/a — click-dismissable only                                                                                          |
| `SelectOverlay` | yes       | `self.focus()` on the `Select`, **guarded** by `if not event.lost_focus` (`src/textual/widgets/_select.py:663-665`)   |
| `ModalScreen`   | yes       | implicit — every `Screen` owns its own `focused` reactive, so popping the screen restores the previous screen's focus |

Opening the dropdown focuses it with `overlay.focus(scroll_visible=False)` (`src/textual/widgets/_select.py:640`) — the suppression matters, because scroll-into-view would move the anchor.

Containment is a first-class node flag rather than a tab-index hack: `DOMNode._trap_focus` (`src/textual/dom.py:234`, assigned at `:494`) makes `Screen.focus_chain` re-root its traversal at the nearest trapping ancestor of the focused node (`src/textual/screen.py:786-790`) — a real [focus scope][concepts]. `AUTO_FOCUS` is a CSS selector string evaluated on screen resume/compose.

**Algorithm.** `focus_chain` = depth-first traversal from that root over `displayed_children` sorted by `_focus_sort_key`, carrying inherited visibility manually and skipping disabled subtrees; the source itself notes the cost ("Calculating a focus chain is moderately expensive", `src/textual/screen.py:773-775`).

**Degradation.** The chain is a derived ordering over the widget tree, recomputed on demand, so it survives a non-DOM value-semantics port unchanged; the per-surface-owns-its-own-focused-index pattern is what makes screen restoration free. Tab traversal is a key-**down** action here, so it is unaffected by a backend that reports no key release. With no OS window nothing changes. Under script-free static emission a focus trap is inexpressible.

### 10. Layering & portals

There is **no portal and no reparenting**: an overlay stays exactly where it is in the widget tree. Three composable mechanisms replace the [top layer][concepts].

**(1) Named layers.** `layers: a b c` on a container declares an ordered namespace; `layer: b` on a descendant joins it. `Screen.layers` appends three system layers after the user's — `_loading`, `_toastrack`, `_tooltips` (`src/textual/screen.py:360-371`) — so framework overlays sit above everything an application can name, and each can be removed by disabling the corresponding feature.

> [!WARNING]
> **Correction to an earlier reading of this file.** `Widget.layers` (`src/textual/widget.py:2613-2626`) walks `ancestors_with_self` — self first, then outward — and **reassigns** `layers` on every ancestor that declares the rule, breaking only at the first non-`Widget` node. The last assignment therefore wins, so the **outermost** declaring widget ancestor's layer tuple is the one in force; an inner declaration does _not_ shadow an outer one.

**(2) A layer is an independent layout flow, not a z-index.** `_arrange.arrange` buckets displayed children by resolved layer name and runs the entire per-container pipeline — split, dock, `layout.arrange`, alignment, absolute — once per bucket against the same region (`src/textual/_arrange.py:60-65`):

```python
# Widgets which will be displayed
display_widgets = list(filter(_get_display, children))
# Widgets organized into layers
layers = _build_layers(display_widgets)

for widgets in layers.values():
```

This appears to be why a shown `Tooltip` does not push application content down, and why per-layer `align` and per-layer `dock` work with no extra API. The documentation describes layers purely as paint order and does not mention it; the mechanism is read from `_arrange.py` plus the committed tooltip snapshot (the label stays on its own row while the tooltip renders below it), not from stepping the layout engine.

**(3) Paint order is a tuple path.** `widget_order = order + ((layer_index, z, layer_order),)` (`src/textual/_compositor.py:678`), where `layer_index` is the position of the widget's layer name in the resolved `layers` tuple, `z` is the placement order (docked widgets take `TOP_Z = 2**31 - 1`, `src/textual/_arrange.py:16`), and `layer_order` is a monotonically decreasing counter giving tree order within a layer. Sorting the map by this tuple descending yields front-to-back.

`overlay: screen` replaces the whole path and the clip in one place (`src/textual/_compositor.py:685-687`):

```python
((1, 0, 0),) if overlay else widget_order,
layer_order,
no_clip if overlay else sub_clip,
```

That pair — order reset plus clip reset — is the entire "escape my scrolling container" mechanism. There is no overlay manager object and no ownership graph; an overlay is an ordinary child, so "child closes when parent closes" falls out of the tree.

> [!WARNING]
> `layer_index = get_layer_index(sub_widget.layer, 0)` (`src/textual/_compositor.py:667`) resolves an **unrecognised** layer name to index 0 — while the widget still gets its own independent layout flow from (2). A layer-name typo therefore silently changes _layout_ (the widget stops displacing its siblings) with no error and no visible paint-order change.

**Degradation.** Everything in this dimension works with no OS window, no compositor and no stacking context — that is the entire point of the design. The two ideas that carry are the layer-as-independent-layout-pass and the order-reset/clip-reset pair as the single definition of "escapes its container". See [`./sparkles-baseline.md`][baseline] for what the toolkit has today and [`./proposal.md`][proposal] for the target shape.

### 11. Modality

[Modality][concepts] is not a property of an overlay here; it is a property of a **screen**. `ModalScreen` sets `self._modal = True` and defaults its background to `$background 60%`, which is the scrim (`src/textual/screen.py:2158-2183`). The accessibility-modal-bit analogue is `DOMNode.is_modal` (`src/textual/dom.py:544-546`), consumed by exactly one thing — `Screen._modal_binding_chain` truncates the binding chain at the first modal node (`src/textual/screen.py:448-455`), making bindings below a modal unreachable. `SystemModalScreen` additionally sets `inherit_css=False` so application CSS cannot restyle it.

Pointer blocking is geometric, not policy-driven: a modal screen is a full-screen widget, so it is simply first in the hit list. [Light dismiss][concepts] does not exist as a concept; it is spelled as a per-widget `escape` binding plus blur handling.

Click-through is expressed with `visibility`: a container set `visibility: hidden` whose children are `visibility: visible`. `ToastHolder` (`src/textual/widgets/_toast.py:28`) and `ToastRack` (`:157`) do exactly this while `Toast` re-enables itself (`:42`), and it works because `Compositor.get_widget_at` skips `not widget.visible` (`src/textual/_compositor.py:846`) while the painter does not. That is a full-screen, hit-transparent overlay layer with no special API at all.

Background screens under a translucent modal keep updating: `App.update_styles` walks the stack in reverse and stops at the first screen that is modal **and** opaque (`src/textual/app.py:2517-2519`).

**Degradation.** None of this needs an OS-level modal, a pointer [grab][concepts], or an accessibility bit — "blocking the background" reduces to "being on top of a full-surface rect in one hit list", and the keyboard half reduces to truncating an ordered chain. The paint-but-do-not-hit bit is the mechanism a cell-grid toolkit needs for full-surface overlay layers, and it costs one flag consulted while deriving the hit list.

### 12. Adaptive presentation

The decision layer is CSS, driven by classes and pseudo-classes the framework sets from measured state — the widget never asks "am I on a small screen".

**Breakpoints.** `Screen._on_resize` (`src/textual/screen.py:1510-1545`) maps the current width and height through `HORIZONTAL_BREAKPOINTS` / `VERTICAL_BREAKPOINTS` — lists of `(threshold, className)` — and calls `update_classes`. `_get_breakpoint_classes` (`:1547-1562`) sorts descending and takes the first match, so exactly one class is set per axis.

**Mode pseudo-classes.** `:inline` (non-alt-screen mode) is used by `CommandPalette:inline { min-height: 20 }`; `:ansi` and `:nocolor` cover reduced-colour terminals.

There is no touch adaptation, no long-press substitution for hover, no sheet/popover switch and no teaching-tip concept. The only switch that changes the overlay **inventory** rather than its style is the test harness: `run_test(tooltips=False, notifications=False)` (`src/textual/app.py:2170`) sets `_disable_tooltips` / `_disable_notifications`, which both suppresses the widget and removes its layer from `Screen.layers`.

**Degradation.** Measure the surface, set a flag, let the theme decide is the right layering and it is target-agnostic. Note the gap this subject leaves: the constrain container is always the full screen, so there is no inset story here at all — a soft-keyboard or reserved-chrome inset has no path into placement even though `Region.constrain` takes a container parameter. That is the amendment [`./proposal.md`][proposal] carries forward.

### 13. Accessibility

**Not applicable — the absence is total.** A case-insensitive search for `aria`, `accessib` or "screen reader" across `src/textual` returns no relevant hits. There is no role vocabulary, no description-versus-label distinction, no accessibility tree and no platform bridging. Tooltips are neither hoverable nor independently dismissable with `Escape` — `Escape` is not bound to the tooltip at all; only "any key while something is focused" clears it (`src/textual/app.py:4131-4135`).

What a terminal honestly exposes is what the emulator exposes: the rendered cells, plus OSC 8 hyperlinks, plus keyboard operability.

The design consequence Textual accepted is a clean split: **non-interactive surfaces are pointer-only and ephemeral** (the `Tooltip` is a `Static`, never focusable, and hides itself when the pointer would reach it), while **genuinely interactive surfaces are focusable and keyboard-first** (`SelectOverlay` is an `OptionList` subclass with its own bindings, `src/textual/widgets/_select.py:48-51`). The obligation that split implies is structural rather than semantic: anything an overlay says must also be reachable without the pointer. Compare [`./aria-apg.md`][aria-apg] for the normative contract this subject does not attempt, and [`../platform-ui-guidelines/index.md`][platform-guidelines] for the platform expectations.

### 14. Animation

No overlay in Textual animates, and no geometry metadata is emitted that would enable one.

A general animation system exists (`src/textual/_animator.py`, `src/textual/css/transition.py`), and `offset` and `opacity` are in `Styles.ANIMATABLE` (`src/textual/css/styles.py:226`), with `ScalarAnimation` able to interpolate a `ScalarOffset` — so an enter/exit slide is _expressible_. But neither `Tooltip`, `Toast`, `SelectOverlay` nor `CommandPalette` declares a transition. There is no [transform origin][concepts] (there are no transforms), no spring, and no reposition-during-animation problem because nothing repositions during animation.

Reduced motion is a global tri-state: the `TEXTUAL_ANIMATIONS` environment variable resolves to an `AnimationLevel` of `none`, `basic` or `full` (`src/textual/constants.py:104`, `:152`), consulted by the animator rather than per-animation.

**The negative finding.** `Region.constrain` returns only a `Region` — it discards whether it flipped and in which direction. A caller therefore cannot style "flipped above" differently from "below", cannot pick a side-aware border cap, and cannot derive a transform origin, without recomputing the decision. Returning the resolved direction alongside the rect would be a one-field change to the return type.

**Degradation.** On a frame-stepped target every transition is assertable frame by frame; under script-free static emission there is no animation at all.

### 15. State architecture

Three architectures coexist in one codebase, and the split is the finding.

**(a) The tooltip is ad-hoc imperative.** Two mutable fields on `Screen` (`_tooltip_widget`, `_tooltip_timer`, `src/textual/screen.py:297-298`) plus direct mutation of a singleton widget's `.display` and `.absolute_offset` from several call sites. It is the least principled code in the subject and also the one with the surprising hide-on-move behaviour from dimension 6.

**(b) The `Select` is reactive/declarative.** `expanded: var[bool]` (`src/textual/widgets/_select.py:358`) plus `value: var[...]` with a validator, and `_watch_expanded` (`:631`) reconciles the world; every trigger writes the reactive, and messages (`Toggle`, `Dismiss`, `UpdateSelection`) are the only cross-widget channel. Openness is uncontrolled with an escape hatch — the application may set `expanded` directly.

**(c) Notifications are a model collection with a reconciling view.** `Notifications._reap()` runs on every `len`/`iter`/`contains` (`src/textual/notifications.py:78`), and `ToastRack.show` (`src/textual/widgets/_toast.py:177`) diffs by identity: remove toasts whose notification is gone, mount toasts for notifications with no widget. This is the only place in the subject that separates overlay **model** from overlay **view**.

```text
# ToastRack reconciliation
display = notifications.nonEmpty
for each mounted toast:  if toast.notification not in notifications -> remove
for each notification:   if no child keyed by it and not expired    -> mount
```

**Degradation.** (b) and (c) survive a value-semantics, rebuild-per-frame port essentially unchanged: a boolean in a state value plus an idempotent reconcile step, and an identity-diffed array of plain data. (a) does not — it depends on mutating a live retained widget from a timer callback. Its natural translation is an explicit state value (Idle / Armed(anchorId, deadline) / Shown(anchorId, anchorCell)) stepped by the frame loop, which also makes every transition assertable on a recording backend rather than only through an async pilot harness. See [`../../specs/ui/state-machines.md`][spec-state-machines] for the existing machine vocabulary.

### 16. Shared infrastructure

Almost nothing is shared at the **widget** level; a great deal is shared at the **geometry and CSS** level. The shared kernel is exactly four things:

```text
Region constrain(Region self, Mode cx, Mode cy, Spacing margin, Region container)
Region inflect(Region self, int xAxis, int yAxis, Spacing margin)
Region translate_inside(Region self, Region container, bool xAxis, bool yAxis)
placement.overlay -> { no flow advance, no margin collapse, no total-region union,
                       clip = surface, order = top, exempt from can_view_partial }
```

Everything above that is per-widget and deliberately unfactored: `Tooltip` is 24 lines of CSS-bearing subclass; `ToastHolder`/`Toast`/`ToastRack` are a dock-and-align container with a reconciler; `SelectOverlay` is an `OptionList` subclass with three messages; `CommandPalette` is a modal screen. There is no `AnchoredOverlay` base class, no popup mixin and no shared surface abstraction.

Two genuinely shared sub-mechanisms cut across kinds:

- `DEFAULT_CLASSES = "-textual-system"` marks framework-owned overlays (`src/textual/widgets/_tooltip.py:24`, `src/textual/widgets/_toast.py:94`, `:163`) so the universal selector `*` skips them (`CHANGELOG.md:1006`) and so `ALLOW_IN_MAXIMIZED_VIEW` can keep them visible when a widget is maximised.
- `_cover_widget` (`src/textual/widget.py:525`, `:770`; consumed at `src/textual/_compositor.py:711-720`) is a fourth, quite different overlay flavour: the loading indicator **replaces** a widget in the compositor map at that widget's exact region, so "overlay exactly on top of X" needs neither an anchor nor a constrain.

What looks common but stays apart, per this source: modality (a screen concern), dismissal policy (tooltip = liveness invalidation; dropdown = focus/`Escape`; toast = timer/click), focusability (three different answers), and the content model (tooltip content is an inherited per-widget value; toast content is an application-level collection; dropdown content is the parent's options array).

**Degradation.** The shared part is pure integer arithmetic plus a handful of layout-engine exemption flags — expressible as `@safe pure nothrow @nogc` free functions over value types with no allocation and no framework coupling. That Textual has four overlay kinds and still no popup base class is evidence, within this subject, that the reusable surface is smaller than it looks: one placement solver and one "escape my container" flag, not a widget hierarchy. [`./comparison.md`][comparison] places that against the rest of the corpus.

## Strengths

- `Region.constrain` / `inflect` / `translate_inside` are a complete, dependency-free integer-cell collision solver with published test vectors (`tests/test_geometry.py:464-582`) — directly reusable by a cell-based toolkit.
- Demonstrates that a first-class overlay layer is achievable with no top layer, no compositor and no OS popup: named layers plus an order tuple plus a clip reset are sufficient.
- `overlay: screen` is a complete enumeration of what "escape my container" actually requires, including the two exemptions that are easy to miss (total-region exclusion, margin-collapse exclusion).
- Layer-as-independent-layout-pass removes overlays from sibling flow with no special-casing, and gives per-layer `align` and `dock` for free.
- Anchor liveness by post-reflow re-hit-test: one hook covering four invalidation causes, each with a regression test.
- Dual-answer hit testing (`get_hover_widgets_at`, `src/textual/screen.py:648-673`) returns both the event target and the topmost target that actually has a `:hover` rule from one reverse-order walk — a small idea that stops a decorative child from breaking its parent's hover styling.
- Notifications separate the overlay model (wall-clock deadlines, identity) from the view (a reconciling container), so a toast survives a screen switch with the correct remaining time.
- All geometry types are immutable `NamedTuple`s — hashable, comparable, allocation-light, trivially portable to value types.
- `visibility: hidden` on a container with `visibility: visible` children yields a paint-but-do-not-hit full-surface layer with no new API.
- Overlay behaviour is testable headlessly through the pilot harness with no terminal; the tooltip's edge cases each have a named test.

## Weaknesses

- `overlay` and `constrain` are undocumented in the style reference and still labelled "Experimental" in the changelog entries that introduced them; they exist to serve `Tooltip` and `Select`.
- The constrain container is unconditionally the full screen at the only call site (`process_offset(size.region, ...)`), so viewport insets, safe areas, docked panels and soft keyboards cannot influence placement even though the API accepts a container.
- `Region.constrain` discards the resolved side, so no placement-aware chrome, styling or animation origin is possible without recomputing the decision.
- The tooltip's timing is ad-hoc mutable state with a surprising, undocumented rule: a pointer move over the same widget hides an already-shown tooltip, so it demands continuous stillness rather than dwell.
- An unrecognised `layer:` name resolves to paint index 0 while still getting its own layout flow — a typo changes layout with no error.
- No arrow or caret concept, and no side indicator on the surface itself (only a chevron on the `Select` trigger).
- No menu, no context menu and no submenu, and therefore no nested-surface, menu-aim or safe-polygon story anywhere in the framework.
- No accessibility surface at all — no roles, no descriptions, no bridge, and tooltips that are neither hoverable nor independently dismissable.
- No overlay animates, and no geometry metadata is emitted that would enable one.
- Overlay layering and the `overlay: screen` exemptions are exercised mainly through SVG snapshot tests rather than unit tests.
- `Tooltip`, `Toast`, `SelectOverlay` and `CommandPalette` each re-implement their own show/hide plumbing; the only shared code is the geometry and the CSS flags.

## Key design decisions and trade-offs

| Decision                                                                                                                                                           | Rationale                                                                                                                                                                                                                               | Trade-off                                                                                                                                                                                                                                         |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| No overlay subsystem: extend the layout engine with three orthogonal CSS rules and let every overlay be an ordinary widget in its ordinary place in the tree.      | On a cell grid there is no top layer to portal into, so reparenting buys nothing; and every overlay still needs box model, styling, focus and hit testing, which the layout engine already provides.                                    | The rules are individually simple but their interaction is not: `overlay: screen` needs six separate exemptions across four files, and missing any one produces a subtle bug. Two of the three rules remain undocumented and effectively private. |
| Make a named layer an independent layout pass over the same region, not merely a paint-order tag.                                                                  | It is what makes an overlay non-displacing with no special-casing, and it gives per-layer `align` and `dock` at no extra cost.                                                                                                          | It is invisible in the documentation, which describes layers purely as paint order; and an unknown layer name resolves to paint index 0 while still getting its own flow, so a typo silently changes layout.                                      |
| Express the collision solver as pure integer functions on an immutable `Region`, with a three-value per-axis mode and no knowledge of anchors, sides or widgets.   | It keeps the solver around forty lines, unit-testable with plain tuples, reusable by both the cursor-anchored tooltip and the sibling-anchored dropdown, and free of framework or platform coupling.                                    | It throws away the answer: the caller cannot learn whether the popup flipped. And although it takes a container parameter, every call site passes the full screen, so viewport insets are unreachable in practice.                                |
| Keep tooltip, toast, dropdown and modal architecturally separate, with different content models, focus policies and dismissal rules.                               | Their invariants genuinely differ: tooltip content is an inherited per-widget value that must never be interactive; toast content is an application-level collection with wall-clock lifetimes; a dropdown must be keyboard-first.      | Real duplication in the small — each re-implements show/hide plumbing — and the tooltip's bespoke imperative timing is the least principled and most surprising part of the subject.                                                              |
| Treat modality as a property of a pushed screen, and give ordinary overlays no modality at all.                                                                    | A full-screen widget on top of the stack blocks the pointer geometrically with no policy code, and truncating the binding chain at the first modal node blocks the keyboard in one line — no grab, no scrim widget, no focus wiring.    | An overlay that wants light dismiss _with_ background blocking has no path: it must become a whole screen, losing its anchor to a widget, or hand-roll blur and `Escape` handling — which is exactly what `Select` does.                          |
| Detect anchor invalidation by re-running one hit test after every layout refresh, instead of observing the anchor.                                                 | One check subsumes anchor-removed, anchor-hidden, anchor-undisplayed and anchor-displaced-by-a-new-sibling, and it cannot go stale because it runs after the authoritative reflow. Four regression tests pass against this single hook. | It is cursor-based, so it serves only pointer-anchored overlays while the pointer is present, and it cannot distinguish "the anchor moved but is still under the cursor" from "nothing changed".                                                  |
| Give the tooltip no arrow and no travel path, and place it one row off the cursor with a margin that serves simultaneously as gap, flip distance and screen inset. | At cell granularity a tail is a whole glyph, and the corridor the tooltip leaves is a single row; collapsing three roles onto `margin` removes a parameter from the placement API.                                                      | Tooltip content can never be selectable, linkable or scrollable; and because gap, viewport padding and flip distance are one value, "a 1-cell gap with a 2-cell screen inset" cannot be asked for.                                                |

## Sources

- `src/textual/geometry.py` — [`Region.translate_inside`][geom-translate-inside] (`:961`), [`Region.inflect`][geom-inflect] (`:999`), [`Region.constrain`][geom-constrain] (`:1043`) with the nested [`compare_span`][geom-compare-span] (`:1064`), the [post-flip clamp comment][geom-clamp-comment] (`:1111-1113`), and [`Spacing.max_width`][geom-max-width] (`:1176`).
- `src/textual/_arrange.py` — [`_build_layers`][arrange-build-layers] (`:19`) and the [per-layer pipeline][arrange-per-layer] (`:60-65`); `TOP_Z` (`:16`).
- `src/textual/_compositor.py` — [`_arrange_root`][comp-arrange-root] (`:525`), the [`process_offset` call site][comp-process-offset] (`:634`), the [layer index default][comp-layer-index] (`:667`), the [order tuple][comp-widget-order] (`:678`), the [overlay order/clip reset][comp-overlay-reset] (`:685-687`), [`get_widget_at`][comp-get-widget-at] (`:829-846`), and the [front-to-back cut renderer][comp-render-chops] (`:1237-1241`).
- `src/textual/_spatial_map.py` — the [total-region exclusion for overlays][spatial-total-region] (`:78`).
- `src/textual/layout.py` — [`WidgetPlacement.overlay`][layout-overlay-flag] (`:93`) and [`process_offset`][layout-process-offset] (`:160-190`).
- `src/textual/screen.py` — [`Screen.layers`][screen-layers] (`:360`), [`_modal_binding_chain`][screen-modal-chain] (`:449`), [`get_hover_widgets_at`][screen-hover-widgets] (`:648`), [`focus_chain`][screen-focus-chain] (`:772`) with the [`_trap_focus` re-root][screen-trap-focus] (`:786-790`), [`_extend_compose`][screen-extend-compose] (`:1152`), the [liveness signal subscription][screen-subscribe] (`:1166`), the [layout-refresh publish][screen-publish] (`:1393`), [`_maybe_clear_tooltip`][screen-maybe-clear] (`:1585`), [`_handle_tooltip_timer`][screen-tooltip-timer] (`:1603`), the [arm/hide branch][screen-arm-hide] (`:1665-1677`), and [`can_view_partial`][screen-can-view-partial] (`:2130`); [`ModalScreen`][screen-modal] (`:2158`).
- `src/textual/widget.py` — [`Widget.absolute_offset`][widget-absolute-offset] (`:486`), [`Widget.layers`][widget-layers] (`:2613-2626`), [`suppress_click`][widget-suppress-click] (`:4306`).
- `src/textual/widgets/_tooltip.py` — [the whole file][tooltip-file] (24 lines).
- `src/textual/widgets/_select.py` — [`SelectOverlay`][select-overlay] (`:48`), [`_on_blur`][select-on-blur] (`:165`), [the trigger chevrons][select-arrows] (`:263-264`), [`BINDINGS`][select-bindings] (`:292`), [the overlay CSS][select-overlay-css] (`:329-330`), [the `expanded` reactive][select-expanded] (`:358`), [`_watch_expanded`][select-watch-expanded] (`:631`), and [the guarded refocus][select-refocus] (`:663-665`).
- `src/textual/widgets/_toast.py` — [`ToastHolder`][toast-holder] (`:16`), [`Toast`][toast-class] (`:33`), [`ToastRack`][toast-rack] (`:146`) and [`ToastRack.show`][toast-show] (`:177`).
- `src/textual/notifications.py` — [`Notification.time_left`][notif-time-left] (`:52`) and [`Notifications._reap`][notif-reap] (`:78`).
- `src/textual/app.py` — [`CLICK_CHAIN_TIME_THRESHOLD`][app-click-chain] (`:450`), [`TOOLTIP_DELAY`][app-tooltip-delay] (`:470`), [`update_styles`][app-update-styles] (`:2504-2519`), and [the any-key tooltip clear][app-key-clear] (`:4131-4135`).
- `src/textual/dom.py` — [`_trap_focus`][dom-trap-focus] (`:234`, `:494`) and [`is_modal`][dom-is-modal] (`:544`).
- `src/textual/css/types.py` — [the `Constrain` literal][css-constrain-type] (`:41`); `src/textual/css/scalar.py` — [`ScalarOffset.resolve`][css-scalar-resolve] (`:350`); `src/textual/css/styles.py` — [`ANIMATABLE`][css-animatable] (`:226`).
- `src/textual/constants.py` — [`TEXTUAL_ANIMATIONS`][constants-animations] (`:104`, `:152`).
- `tests/test_geometry.py` — [`test_translate_inside` / `test_inflect`][tests-geometry] (`:464-493`) and [the `constrain` parametrisation][tests-constrain] (`:533-582`).
- `tests/test_tooltips.py` — [the seven tooltip tests][tests-tooltips], including `test_mouse_move_removes_a_tooltip` (`:56`) and the four anchor-liveness tests (`:69`, `:82`, `:95`, `:108`).
- `CHANGELOG.md` — ["`Region.inflect` will now assume that margins overlap"][changelog-inflect] (`:1055`, released in 0.83.0 on 2024-10-10), ["Made `Widget.absolute_offset` public"][changelog-absolute-offset] (`:1053`), [the `-textual-system` universal-selector exemption][changelog-system-class] (`:1006`), ["Tooltips are now hidden when any key is pressed"][changelog-key-hide] (`:1395`), ["Tooltips are now inherited"][changelog-inherited] (`:2421`), and [the experimental `overlay` / `constrain` entries][changelog-experimental] (`:2576-2577`).

Related pages: [`./index.md`][index], [`./concepts.md`][concepts], [`./comparison.md`][comparison], [`./features-people-forget.md`][ffpf], [`./sparkles-baseline.md`][baseline], [`./proposal.md`][proposal]. Nearest siblings by surface model: [`./ratatui.md`][ratatui], [`./helix.md`][helix], [`./neovim-floats.md`][neovim-floats], [`./notcurses.md`][notcurses], [`./turbo-vision.md`][turbo-vision], [`./imgui.md`][imgui], [`./gpui.md`][gpui]. Toolkit context: [`../../specs/ui/index.md`][spec-ui], [`../../specs/ui/containers.md`][spec-containers], [`../../specs/ui/backends.md`][spec-backends], [`../ui-layout/index.md`][ui-layout].

<!-- References -->

[repo]: https://github.com/Textualize/textual
[docs]: https://textual.textualize.io/
[geom-translate-inside]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/geometry.py#L961
[geom-inflect]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/geometry.py#L999
[geom-constrain]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/geometry.py#L1043
[geom-compare-span]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/geometry.py#L1064
[geom-clamp-comment]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/geometry.py#L1111
[geom-max-width]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/geometry.py#L1176
[arrange-build-layers]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/_arrange.py#L19
[arrange-per-layer]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/_arrange.py#L60
[comp-arrange-root]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/_compositor.py#L525
[comp-process-offset]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/_compositor.py#L634
[comp-layer-index]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/_compositor.py#L667
[comp-widget-order]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/_compositor.py#L678
[comp-overlay-reset]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/_compositor.py#L685
[comp-get-widget-at]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/_compositor.py#L829
[comp-render-chops]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/_compositor.py#L1237
[spatial-total-region]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/_spatial_map.py#L78
[layout-overlay-flag]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/layout.py#L93
[layout-process-offset]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/layout.py#L160
[screen-layers]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/screen.py#L360
[screen-modal-chain]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/screen.py#L449
[screen-hover-widgets]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/screen.py#L648
[screen-focus-chain]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/screen.py#L772
[screen-trap-focus]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/screen.py#L786
[screen-extend-compose]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/screen.py#L1152
[screen-subscribe]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/screen.py#L1166
[screen-publish]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/screen.py#L1393
[screen-maybe-clear]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/screen.py#L1585
[screen-tooltip-timer]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/screen.py#L1603
[screen-arm-hide]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/screen.py#L1665
[screen-can-view-partial]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/screen.py#L2130
[screen-modal]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/screen.py#L2158
[widget-absolute-offset]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/widget.py#L486
[widget-layers]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/widget.py#L2613
[widget-suppress-click]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/widget.py#L4306
[tooltip-file]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/widgets/_tooltip.py
[select-overlay]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/widgets/_select.py#L48
[select-on-blur]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/widgets/_select.py#L165
[select-arrows]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/widgets/_select.py#L263
[select-bindings]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/widgets/_select.py#L292
[select-overlay-css]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/widgets/_select.py#L329
[select-expanded]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/widgets/_select.py#L358
[select-watch-expanded]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/widgets/_select.py#L631
[select-refocus]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/widgets/_select.py#L663
[toast-holder]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/widgets/_toast.py#L16
[toast-class]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/widgets/_toast.py#L33
[toast-rack]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/widgets/_toast.py#L146
[toast-show]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/widgets/_toast.py#L177
[notif-time-left]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/notifications.py#L52
[notif-reap]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/notifications.py#L78
[app-click-chain]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/app.py#L450
[app-tooltip-delay]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/app.py#L470
[app-update-styles]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/app.py#L2504
[app-key-clear]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/app.py#L4131
[dom-trap-focus]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/dom.py#L494
[dom-is-modal]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/dom.py#L544
[css-constrain-type]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/css/types.py#L41
[css-scalar-resolve]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/css/scalar.py#L350
[css-animatable]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/css/styles.py#L226
[constants-animations]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/constants.py#L104
[tests-geometry]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/tests/test_geometry.py#L464
[tests-constrain]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/tests/test_geometry.py#L533
[tests-tooltips]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/tests/test_tooltips.py
[changelog-inflect]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/CHANGELOG.md#L1055
[changelog-absolute-offset]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/CHANGELOG.md#L1053
[changelog-system-class]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/CHANGELOG.md#L1006
[changelog-key-hide]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/CHANGELOG.md#L1395
[changelog-inherited]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/CHANGELOG.md#L2421
[changelog-experimental]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/CHANGELOG.md#L2576
[index]: ./index.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[ffpf]: ./features-people-forget.md
[baseline]: ./sparkles-baseline.md
[proposal]: ./proposal.md
[aria-apg]: ./aria-apg.md
[ratatui]: ./ratatui.md
[helix]: ./helix.md
[neovim-floats]: ./neovim-floats.md
[notcurses]: ./notcurses.md
[turbo-vision]: ./turbo-vision.md
[imgui]: ./imgui.md
[gpui]: ./gpui.md
[spec-ui]: ../../specs/ui/index.md
[spec-containers]: ../../specs/ui/containers.md
[spec-backends]: ../../specs/ui/backends.md
[spec-state-machines]: ../../specs/ui/state-machines.md
[ui-layout]: ../ui-layout/index.md
[platform-guidelines]: ../platform-ui-guidelines/index.md
