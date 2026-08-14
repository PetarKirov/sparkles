# Slint `PopupWindow` (Rust + the Slint DSL)

Slint answers the anchored-overlay problem with the smallest primitive in this catalog's desktop tier — one point anchor, one clamp-and-shrink [placement][placement] pass, and a flat stack of extra item trees the renderer walks in order — and pushes every other behaviour up into `.slint` source.

| Field            | Value                                                                                                                                                                                                                                                                                                               |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language         | Rust, plus the Slint DSL compiled ahead of time by `internal/compiler`                                                                                                                                                                                                                                              |
| License          | `GPL-3.0-only OR LicenseRef-Slint-Royalty-free-2.0 OR LicenseRef-Slint-Software-3.0`                                                                                                                                                                                                                                |
| Repository       | [`slint-ui/slint`][slint-repo]                                                                                                                                                                                                                                                                                      |
| Documentation    | [docs.slint.dev][slint-docs] (the `PopupWindow` reference page is generated from the builtin declaration in `internal/compiler/builtins.slint`)                                                                                                                                                                     |
| Category         | Native desktop (Rust), in-canvas capable                                                                                                                                                                                                                                                                            |
| Surface model    | Both. One source declaration resolves at run time to (a) an in-window `ChildWindow` overlay item tree, (b) a real OS child window (`TopLevel`, implemented only by the Qt backend in this tree), or (c) for context menus, a fully native OS menu — with no source-level difference and no way to ask which you got |
| Revision read    | `24318cebc2b3feed4f7187e237915f52715ce285` (workspace version 1.17.0; `CHANGELOG` head is `[Unreleased]`)                                                                                                                                                                                                           |
| Reading approach | Primary-source reading of the Rust runtime, the compiler passes, the shipped `.slint` widget library and the declarative test cases. Nothing was built or run                                                                                                                                                       |

## Overview

### What it solves

`PopupWindow` is not a widget and not a container. It is a **language construct** that the compiler removes from the element tree entirely and re-parents into a `Component` of its own, so that an overlay escapes its ancestors' clipping, layout and coordinate space structurally rather than by a rendering special case. Everything the runtime then knows about an overlay is captured in one struct, `PopupWindow` (`internal/core/window.rs:441`), and one two-variant enum:

```rust
/// This enum describes the different ways a popup can be rendered by the back-end.
pub enum PopupWindowLocation {
    /// The popup is rendered in its own top-level window that is know to the windowing system.
    TopLevel(Rc<dyn WindowAdapter>),
    /// The popup is rendered as an embedded child window at the given position.
    ChildWindow(LogicalPoint),
}
```

— `internal/core/window.rs:431-437` ([source][window-popuplocation])

Every downstream system — rendering, hit testing, accessibility, coordinate mapping, the headless testing query — branches on that enum, and each of them handles only `ChildWindow` specially; `TopLevel` is delegated to the platform. The `ChildWindow` arm is the one that matters here, because it is what every backend except Qt gets: an extra item tree appended to the frame's render list with a translation. No compositor, no [top layer][top-layer], no z-index — later in the list means in front.

### Design philosophy

The philosophy reads as _minimum mechanism, maximum reuse of the existing reactive graph_. There is exactly one placement function, and its `Placement` input has exactly one variant:

```rust
pub enum Placement {
    /// Request a fixed position
    Fixed(LogicalRect),
}
```

— `internal/core/window/popup.rs:11-14` ([source][popup-placement-enum])

There is no side or alignment vocabulary, no flip, no [anchor rect][anchor-rect], no arrow, no [modality][modality] flag, no scrim, no animation metadata, and no accessibility role for a tooltip or a menu. The `match` on a single-variant enum inside `place_popup`, together with the commented-out `anchor_x`/`anchor_y`/`anchor_height`/`anchor_width` properties still present in the shipped builtin declaration (`internal/compiler/builtins.slint:2472-2475`, [source][builtins-anchor-commented]), suggests a richer anchor-and-side model was contemplated and never landed — though with a shallow clone there is no history to confirm whether it was reverted or merely sketched.

What looks like popup behaviour elsewhere in the toolkit — submenu cascade, combobox drop, tooltip delay — is written in `.slint`, or in one small runtime item, on top of that single primitive. The cost of pushing so much upward shows up as leaks: `absolute-position` is not absolute inside a popup, a popup's own `background` is silently not painted on the in-window path, and a popup repositioned after opening escapes the clamp that was applied when it opened.

> [!NOTE]
> The clone read here is shallow (a single revision, `.git/shallow` present), so no `git log`, blame or PR archaeology was possible. Where this page says "appears to" or "suggests", that is a structural inference from the source at the pinned SHA, not a history claim.

## How it works

Four stages, split across the compiler and the runtime.

**1. The compiler extracts the popup.** `lower_popups.rs` walks each `PopupWindow` element, removes it from its parent's children (marking `has_popup_child` and fixing up the enclosing component's child-insertion index), wraps it in a fresh `Component` whose `parent_element` is the trigger, re-stamps `enclosing_component` on every descendant, retypes the root to the builtin `Window`, and **replaces the popup's `x`/`y` with synthesized `popup-<id>-dummy` length properties** so its children lay out from `(0, 0)`. The original `x`/`y` expressions are snapshotted as `NamedReference`s (`coord_x`, `coord_y`). The pass then rejects any reference from the enclosing component into the popup's new component, and rejects a `PopupWindow` that is repeated or conditional (`internal/compiler/passes/lower_popups.rs:45-296`, [source][lower-popups]).

**2. The generator turns those coordinates into a closure.** In the Rust backend the snapshotted coordinates become a boxed closure evaluated in the _popup's_ scope:

```rust
let popup_instance_vrc_for_position = popup_instance_vrc.clone();
let access_position = sp::Box::new(move || {
    let _self = popup_instance_vrc_for_position.as_pin_ref(); #position
});
```

— `internal/compiler/generator/rust.rs:3676-3679` ([source][rust-access-position])

That closure _is_ the anchor input. The same generated block constructs a **brand-new component instance on every `show()`** and closes the previous instance of the same declaration first (`rust.rs:3668-3691`, [source][rust-fresh-instance]).

**3. `show_popup` resolves a surface and a rect.** The runtime asks the popup component for its window adapter and compares it with the parent's by pointer identity. If they are the same object — which happens whenever the backend declined to make a child window adapter — the popup becomes an in-window `ChildWindow`, and this is the one and only site where `place_popup` runs:

```rust
// Tooltips may extend past the window (e.g. above/left of the anchor); do not clamp.
let clip_region = Some(LogicalRect::new(
    LogicalPoint::new(0.0 as crate::Coord, 0.0 as crate::Coord),
    self.window_adapter().size().to_logical(self.scale_factor()).to_euclid(),
));
```

— `internal/core/window.rs:1810-1814` ([source][window-clip-region])

> [!WARNING]
> The comment says tooltips are not clamped, and the doc comment on `PopupWindow::window_kind` agrees ("Overlay tooltip: no focus steal, unclamped placement", `window.rs:454`). The adjacent code passes `Some(window rect)` unconditionally, for every `WindowKind`. Tooltips _are_ clamped to the window at this revision. This is a source-internal discrepancy, not a subtlety.

**4. The frame walks a flat list.** `draw_contents` builds a `Vec<(ItemTreeWeak, LogicalPoint)>` whose first entry is the main tree and whose remaining entries are the `ChildWindow` popups in `active_popups` order; each renderer loops over it with `save_state(); translate(origin); render_children(); restore_state()` and pushes no clip (`internal/core/window.rs:1528-1568`, [source][window-draw-contents]; `internal/core/item_rendering.rs:243-255`, [source][rendering-render-components]).

Reposition rides the reactive graph rather than the frame loop: each popup owns a pinned `PropertyTracker<true, PopupWindowPropertiesTracker>` whose dirty handler schedules a zero-duration `Timer::single_shot`, and the handler re-evaluates the position closure and the popup's `layout_info`.

## The analysis spine

### 1. Anchor model

The anchor is a **pair**, not a rect: `parent_item: ItemWeak` (the element the popup was lexically declared inside) and `position_access: Box<dyn Fn() -> LogicalPosition>` (`internal/core/window.rs:453-461`). The absolute location is `parent_item.map_to_native_window(parent_item.geometry().origin + position_access())`. So the anchor is a **point offset from the parent element's origin** — there is no anchor rectangle, no [gravity][gravity], and no side. The commented-out `anchor_*` properties are the only trace of one.

Anchoring is lexical: a "detached" trigger is expressed by _nesting_ the `PopupWindow` under whatever element should serve as anchor. Cursor anchoring is done by binding `x`/`y` to a hover tracker's `mouse-x`/`mouse-y` (tooltips) or by passing a click point, in which case the closure is a constant. A [virtual anchor][virtual-anchor] is therefore expressible — any expression that yields a point works — but it is not a distinct concept in the model. Anchor-to-screen conversion exists only in the Qt backend (`qt_window.rs:2276`, `parent->mapToGlobal(QPoint(0,0)) + pos`).

Opening the same declaration twice closes the previous instance, and `show_popup` additionally closes every popup that shares the same `parent_item` (`window.rs:1756-1766`, [source][window-sibling-close]).

**Algorithm.**

```text
resolve_anchor(popup):
    p      = position_access()                          // closure; re-runs the x/y bindings
    origin = parent_item.geometry().origin              // read UNTRACKED on the reposition path
    return parent_item.map_to_native_window(origin + p) // adds each enclosing popup's origin
```

**Where it lives.** The framework kernel owns the struct and the resolution (`internal/core/window.rs`, `internal/core/item_tree.rs:589-624` for `map_to_native_window`); the compiler manufactures the closure.

**Degradation.** Nothing in the anchor model needs an OS window, script, sub-cell precision or a key release — it is `parent_item` plus a `LogicalPoint`. What it is _not_ is a comparable value: `Box<dyn Fn()>` is opaque, non-copyable and non-comparable, which is why nothing in Slint can diff or memoize a placement. A value-semantics port would keep `(anchorId, offset)` as plain data and re-derive the point per frame instead of subscribing to it.

### 2. Placement model

One mode, `Fixed`, and the whole engine is 24 lines. If the requested rect fits the clip region it is used verbatim; otherwise the size is `min`'d componentwise against the clip size — a too-large popup is **shrunk**, not scrolled — and then the origin is clamped into `[clip.origin, clip.origin + clip.size - size]`. That is shift plus resize; there is no flip, no preferred-side list, no alignment, no viewport padding and no caller-supplied boundary.

The [clipping boundary][clipping-boundary] is always the window's logical rect: never the screen, never a work area, and never the safe-area inset — which Slint _does_ compute (`WindowAdapterInternal::safe_area_inset`, `window.rs:263`) and _does_ expose on the `Window` item, but never feeds to `place_popup`. Multi-monitor and IME avoidance are absent from core. There is no RTL or writing-mode concept in the toolkit beyond flexbox `row-reverse`, so logical-versus-physical placement does not arise. `TopLevel` popups receive no clamping from Slint at all — `set_position(position)` and done.

Size is resolved twice by two different formulas: at open time `max(min, min(max, explicit_or_preferred))` per orientation (`window.rs:1727-1739`), and on reposition `layout_info.min.min(layout_info.max)` (`window.rs:1463-1479`).

**Algorithm.**

```text
place(rect, clip):
    if clip is None or clip.contains_rect(rect): return rect
    size   = (min(rect.w, clip.w), min(rect.h, clip.h))
    origin = (clamp(rect.x, clip.x, clip.x + clip.w - size.w),
              clamp(rect.y, clip.y, clip.y + clip.h - size.h))
    return Rect(origin, size)
// exactly one call site: show_popup, ChildWindow branch only
```

**Where it lives.** Library code: `internal/core/window/popup.rs:19-42` ([source][popup-place]), backed by a ~200-line exhaustive table test crossing 9 clip offsets × 2 clip sizes × 4 size classes × 9 requested positions, degenerate "popup larger than the clip" case included (`popup.rs:86-295`, [source][popup-table-test]).

**Degradation.** This is the piece that ports without modification: pure logical-rect arithmetic, no window, no hover, no script, no sub-cell assumption. Replacing `f32::clamp` with an integer clamp yields the same function over cells, with the shrink step meaning a popup wider than the grid becomes exactly grid-width. Its weakness is what it omits — with no flip, a bottom-anchored menu near the window's bottom edge slides up and covers its own anchor instead of opening upward. Compare the flip-and-revert ladders in [`./xdg-positioner.md`][xdg-positioner] and [`./gtk4.md`][gtk4], and the same-engine-two-surfaces arrangement in [`./avalonia.md`][avalonia].

### 3. Collision & geometry engine

Overflow detection is `clip.contains_rect(rect)` — one boolean, evaluated once. There is no clipping-ancestor discovery, because a popup escapes _all_ ancestor clipping by construction: it is not in the ancestor's item tree, and `render_component_items` pushes no clip for the extra trees. Scroll containers are therefore irrelevant to a popup's visibility — and they are also not tracked. The anchor's `geometry().origin` is read **outside** the property tracker in `update_popup_properties` (`window.rs:1432-1442`, [source][window-update-popup-props]), so an open popup does not follow a scrolling or relaid-out anchor unless its own `x`/`y` expression happens to depend on something that changed.

Tracking is dependency-graph-driven rather than observer- or polling-based. The dirty handler schedules a zero-duration timer to coalesce bursts, and the declarative test has to advance mocked time **twice** to observe a reposition — "First triggers the Property Tracker … Second updates the popup properties" (`tests/cases/elements/popupwindow_position.slint:127-129`). Cost per anchor resolution is `map_to_native_window`: a walk up the parent chain, performed for each active popup. Geometry is logical throughout; pointer grabs apply an inverse children transform per item where the renderer supports transformations, but popup placement itself is transform-blind and there is no [transform origin][transform-origin] anywhere in this path.

**Algorithm.**

```text
reposition(popup_id):                       // fired by the dirty handler, one turn later
    offset = anchor_abs()                   // untracked read of the anchor's geometry
    (old, new) = tracker.evaluate_as_dependency_root(||
        read window_item.width/height
        w = layout_info_h.min.min(layout_info_h.max); window_item.width  = w
        h = layout_info_v.min.min(layout_info_v.max); window_item.height = h
        (old_rect, Rect(position_access(), (w, h))))
    location = offset                       // NO clamp on this path
    mark_dirty_region(old); mark_dirty_region(new); request_redraw()
```

**Where it lives.** Framework kernel: the reactive property system does change detection, `window.rs` does the geometry, and renderers only consume the `(tree, origin)` list.

**Degradation.** The geometry generalizes completely — there is nothing native in it. The two parts that would not survive a value-semantics port are the boxed closure and the tracker-plus-timer plumbing; an immediate-mode toolkit recomputes the rect every frame and gets the same answer with no tracker, no timer and no two-turn latency. Notably, the "anchor geometry read untracked" defect cannot exist under a per-frame recompute.

### 4. Arrow / caret geometry

**Not applicable — and the absence has a cause.** There is no arrow, caret, tail or beak concept anywhere in Slint's popup path. `PopupWindow` exposes only `width`, `height`, `close-on-click` and `close-policy` (`builtins.slint:2467-2487`). The shipped tooltip body `ToolTipImpl` is a `Rectangle` with `border-radius: 4px` and padding (`tooltip-base.slint:6-26`); `MenuFrameBase` is a `Rectangle` with a drop shadow (`menu-base.slint:81`). Neither has a tail.

The structural reason is that `place_popup` returns only a rect: no [constraint adjustment][constraint-adjustment] result, no resolved side. Nothing downstream _could_ draw a directional caret, because the styling layer is never told which way the popup was pushed. Since placement never flips, the popup's relation to its anchor is whatever the author wrote in the `x`/`y` expression, so an author who wanted an arrow would hard-code it on the side they already chose.

**Where it lives.** Nowhere — not in the library, not in a backend, not in a style file.

**Degradation.** The transferable observation for a cell grid is the negative one: an arrow only becomes _data_ once placement can move the surface behind the author's back. If placement is clamp-only, arrow geometry collapses to a single authored glyph on a known side.

### 5. Trigger semantics

There is no trigger system. A `PopupWindow` opens when some Slint expression calls `popup.show()`, so every trigger is authored — but the three canonical ones are each realized by a different mechanism at a different layer:

1. **Click / programmatic** — an author-written `TouchArea { clicked => popup.show(); }`.
2. **Hover** — the compiler synthesizes a `TooltipArea` item filling the parent (`x: 0; y: 0; width: 100%; height: 100%`) and wires its `show()`/`hide()` callbacks (`lower_tooltips.rs`).
3. **Context menu** — the `ContextMenu` runtime item handles `Pressed { button: Right }` directly, plus the `Menu` key, plus (under `#[cfg(target_os = "windows")]`) `Shift+F10`, plus (under `#[cfg(target_os = "android")]`) a left-press long-press timer using `Platform::long_press_interval()`.

Trigger races are avoided structurally rather than by arbitration. `TooltipArea::input_event_filter_before_children` returns the dedicated `InputEventFilterResult::ForwardAndObserve`, which places the item on an **observers side-list outside the hit-path stack**, so it sees every event and gets a synthesized `Exit` even when a sibling claims the event. `Exit` fires only when the item is absent from _both_ the new observer set and the new path stack (`internal/core/input.rs:246-248` and `:1435-1448`).

**Algorithm.**

```text
TooltipArea filter(ev):
    if ev is DragMove or Drop: hover = false; return ForwardAndIgnore
    if ev has position: mouse_x, mouse_y = ev.position   // keeps updating even while shown
    next = (ev != Exit); set_hover_state(next)
    if next and not popup_visible and ev is Moved: schedule_show()   // RESTARTS the timer
    return ForwardAndObserve
```

**Where it lives.** Split three ways: the compiler (`lower_tooltips.rs` synthesizes and wires the area), the runtime items (`TooltipArea`, `ContextMenu` in `internal/core/items.rs`), and author-written `.slint` for click. The routing primitive that makes transparent hover tracking correct lives in `internal/core/input.rs`.

**Degradation.** Everything except hover survives a hover-less target, and Android's substitution is made _at compile time_ inside the runtime item rather than by policy. Nothing here needs a key **release**: the `Menu` key and `Shift+F10` both fire on press. `ForwardAndObserve` is the transferable idea — a hover-driven overlay needs an event-routing tier that observes without claiming, or `Exit` gets swallowed by whichever sibling won the hit test.

### 6. Timing

Two timers exist in the whole system, and they are unrelated to each other.

**Tooltip show delay.** `TooltipArea.delay` defaults to `500ms` and `offset` to `8px`, and the builtin declaration marks both as deliberately not user-facing: "Delay and offset are not user-facing in 1.17; the values used here are the built-in defaults applied to the synthesized element on instantiation" (`builtins.slint:2499-2502`). `schedule_show` **restarts** the single-shot timer on every `Moved` while not visible, so the semantics are "pointer quiet for 500 ms", not "hovering for 500 ms"; the callback re-checks `has_hover()` before firing. Hiding is immediate. There is no [warm-up][warm-up] group, no [cool-down][cool-down], no instant-subsequent-tooltip, no shared provider or singleton, and no maximum display duration — every tooltip pays the full delay, every time, which the declarative test asserts (`tests/cases/elements/tooltip_on_button.slint:78-86`).

**Submenu open-on-hover.** A `500ms` `Timer` element declared in `menus.slint`, started by `set-current` (hovering a menu row) and cancelled by any key press; on fire it opens the highlighted entry's submenu, or closes the open one if the newly highlighted entry has none.

**Algorithm.**

```text
tooltip:
    on hover-enter, or (hover and not visible and Moved): timer.restart(500 ms)
    on fire:  if has_hover: show(); visible = true
    on leave: timer.stop(); if visible { visible = false; hide() }
    // no cool-down window, no shared 'recently shown' state

submenu:
    on row hover:    current_highlight = i; open_after_timeout.running = true   // restarts
    on fire:         if entries[i].has_sub_menu: activate(i) else: close open submenu
    on any key press: open_after_timeout.running = false
```

**Where it lives.** Two independent implementations of the same idea at two different layers: tooltip timing in the Rust runtime item `TooltipArea`; submenu timing in the **style file** `internal/compiler/widgets/common/menus.slint`, as a declarative `Timer` element.

**Degradation.** Timers are the first casualty of a script-free static target: with no script the 500 ms delay collapses to instant-on-`:hover`, which is a different product. The machine itself is small enough to state in five lines and would survive a `@nogc` port unchanged — one enum plus one deadline. What Slint stops short of is the fuller ladder (`Idle → Warm(deadline) → Shown → Cooling(deadline) → Idle`), where re-entry while cooling skips the delay and a shared group makes "recently shown" common across siblings; see [`./react-aria.md`][react-aria] and [`./tippy.md`][tippy] for that shape.

### 7. Interactive hover

Slint solves the trigger-to-content travel problem by **forbidding the travel**. Tooltip popups carry `WindowKind::ToolTip` and are skipped outright by the hit-test walk — `if matches!(popup.window_kind, WindowKind::ToolTip) { continue; }` (`window.rs:837`) — so the tooltip is input-transparent and hovering it is impossible. No [safe polygon][safe-polygon], pointer bridge, interactive border, trajectory heuristic or debounce exists anywhere in the tree.

The tooltip is also offset only downward (`y + offset`, `x` unchanged, `lower_tooltips.rs:204-225`), so it sits under the cursor hotspot and would be hit-tested constantly were it not transparent.

Diagonal submenu intent is likewise absent: the 500 ms open-after-timeout is the entire heuristic. Because moving diagonally across a submenu re-hovers rows of the **parent** menu, `set-current` restarts the timer and the cascade re-targets, so the classic diagonal-traversal failure is unmitigated. Nested surfaces work structurally — popup-in-popup is first class, and `show_popup` resolves the parent adapter by finding the popup whose component is the root of the trigger's tree (`window.rs:1783-1795`) — but not ergonomically.

**Where it lives.** Framework kernel (the `ToolTip` skip in `WindowInner::process_mouse_input`), plus the style file's timer.

**Degradation.** Cost in whole cells is zero, because none of these algorithms is implemented — there is nothing to port. The transferable decision is the cheap one: making a hover surface input-transparent removes the entire safe-polygon problem class, at the price of forbidding interactive tooltip content (see dimension 13). Slint is evidence that a production toolkit can ship without a corridor at all.

### 8. Dismissal

Three static policies, chosen at **compile time** — `close-policy` must be an enumeration literal, and `lower_popups.rs:231` says so ("The close-policy property only supports constants at the moment") — resolved by walking the base-component chain.

The mouse rule is evaluated **before** dispatch and against the topmost popup only:

```text
on_mouse(ev):
    pressed  = ev is Pressed;  released = ev is Released
    if pressed: had_popup_on_press = !popups.empty()
    top    = popups.last()
    inside = ev.position.map_or(true, |p| top.component.item_geometry(0).contains(p - top.location))
    to_close = match top.policy:
        CloseOnClick        => (inside and released and had_popup_on_press) or (!inside and pressed)
        CloseOnClickOutside => !inside and pressed
        NoAutoClose         => false
    ... hit-test walk (may promote to_close to the BOTTOM menu of a chain) ...
    if to_close: close_popup(id)   // then cascade every Menu popup above its index
```

`had_popup_on_press` — set on every press to whether any popup was open at that moment — is what stops the click that _opened_ a popup from closing it on its own release (`window.rs:788-790`, `:810-820`). A dismissing outside press is **consumed**: the declarative test asserts the first outside click produces no result and the second reaches the underlying `TouchArea` (`tests/cases/elements/popupwindow_nested.slint:268-273`). `MouseEvent::Exit` carries no position, and every containment test is written `event.position().is_none_or(|p| …)`, so a positionless event counts as "inside" — leaving the window therefore neither closes the popup nor mis-routes the event.

Escape closes the top popup for the two click policies, and the Escape branch returns `EventAccepted` unconditionally, so Escape is swallowed even when nothing closed. Anchor removal closes the popup: during item-tree teardown every popup whose `parent_item.upgrade()` is dead is closed (`item_tree.rs:223-232`). Closing a menu popup cascades — `close_popup` removes it, then keeps removing whatever `WindowKind::Menu` popups now occupy that index.

Not handled at all: window or application deactivation, scroll, resize, the anchor becoming hidden or clipped, navigation, and any press outside the window.

**Where it lives.** Framework kernel: `WindowInner::process_mouse_input` (`window.rs:764-965`) and the Escape branch of `process_key_input` (`window.rs:1136-1161`). The policy value is baked by the compiler.

**Degradation.** The whole rule works with no OS window and no key release — the press/release pairing it needs is a _mouse_ pairing, and the keyboard path uses key-press only. What it cannot do without a pointer [grab][grab] is precisely what Slint also cannot do: a press outside the application's window never arrives, so an in-window popup survives clicks on other applications. That hole is already shipped in a production toolkit, which is worth knowing before treating it as a blocker; the grab-based alternative is visible in [`./qt-widgets.md`][qt-widgets].

### 9. Focus

Focus is taken from the parent on open and restored on close, but only for non-tooltip kinds:

```rust
let focus_item = if matches!(window_kind, WindowKind::ToolTip) {
    Default::default()
} else {
    self.take_focus_item(&FocusEvent::FocusOut(FocusReason::PopupActivation))
```

— `internal/core/window.rs:1847-1850` ([source][window-tooltip-focus])

The previously focused item is stashed in `focus_item_in_parent` and re-focused in `close_popup_impl` (`window.rs:1915-1918`).

Focus is **contained, not trapped**, and containment is a side effect of tree topology rather than a feature: `ItemRc::parent_item(ParentItemTraversalMode::StopAtPopups)` returns `None` at a popup root (`item_tree.rs:386-393`), so key-event bubbling and Tab traversal cannot leave the popup; when nothing is focused, Tab starts at the last active popup's root. `forward-focus` on a `PopupWindow` supplies the initial focus element, arranged by a compiler pass (`lower_popups.rs:219`). For `TopLevel` popups `set_focus_item` is redirected into the popup's own window (`window.rs:1224-1231`), so the two surfaces have genuinely different focus stores.

There is no pointer- versus keyboard-opened distinction, no focus-visible concept, and no close-on-focus-leaving. Crucially the categories are **not** distinct: tooltip / popup / menu is one three-valued `WindowKind` whose only focus consequence is "a tooltip does not take focus", and a Slint `Dialog` is an ordinary element, not a popup kind at all.

**Where it lives.** Framework kernel, plus one compiler pass for initial focus.

**Degradation.** Fully backend-independent — nothing consults an OS focus API. The mechanism worth stealing is `StopAtPopups`: a complete [focus scope][focus-scope] for free from one enum in the parent walk, with no trap logic, no sentinel elements and no focus-cycle bookkeeping. It costs nothing on a grid and needs no key release.

### 10. Layering & portals

This is the dimension Slint answers most directly. There is no top layer and no z-index. `draw_contents` produces `[main tree] ++ [every ChildWindow popup in active_popups order]`; renderers loop and translate. Ordering is stack order, full stop.

The overlay "tree" is a **flat `Vec<PopupWindow>` owned by `WindowInner`** — ownership belongs to the parent window, not the anchor, and the link back to the anchor is a weak `parent_item`. That flat vector is then grafted back into a tree shape _independently, three times_, by three consumers:

- **AccessKit** — each `ChildWindow` popup becomes a child node of its anchor's accessible node, recursed with `window_position = popup.location` so reported bounds come out in window space (`accesskit.rs:363-408`, `:444-472`).
- **The headless testing element query** — `visit_attached_popups` splices the popup's root under the matching item (`search_api.rs:353-371`).
- **`map_to_native_window`** — adds each enclosing popup's origin while walking up the parents (`item_tree.rs:589-624`).

Public API is deliberately thin: the DSL exposes only `show()`, `close()` and `close-policy`. `PopupWindowLocation`, `active_popups`, `WindowKind` and `place_popup` are Rust-side and re-exported only to the testing backend (`internal_tests.rs:14`).

**Algorithm.**

```text
frame():
    if no ChildWindow popup:
        render(main, origin = 0)
    else:
        list = [(main, 0)] ++ [(p.component, p.location) for p in active_popups if p is ChildWindow]
        for (tree, origin) in list:
            save(); translate(origin); render_children(tree); restore()
    post_render(renderer)     // the drag-image overlay, painted after everything
```

**Where it lives.** Framework kernel (`WindowInner::draw_contents`) plus a short loop in each renderer (e.g. `internal/renderers/software/lib.rs:681-690`). Nothing platform-specific on the `ChildWindow` path.

**Degradation.** Already degraded by design — this is what Slint does on every backend except Qt, including embedded targets with no window system. Worth noting is the **second** layering escape sitting beside it: `post_render`, a callback the renderer must invoke with its `ItemRenderer` after walking the trees, documented as being for overlays that "sit on top of the scene without being part of any item tree" and used for the drag image (`window.rs:1518-1526`, `:1571-1600`). Slint ended up with two escapes — an item-tree-shaped one and a raw-painter-shaped one — which suggests a canvas toolkit will want both slots too. The in-canvas peers in [`./imgui.md`][imgui], [`./gpui.md`][gpui] and [`./textual.md`][textual] make instructive comparisons here.

### 11. Modality

There is no modality API, no scrim, no dim, no click-through flag and no accessibility modal bit — and yet non-tooltip popups **are** pointer-modal as an emergent property of the hit-test walk:

```text
route(ev):
    for popup in active_popups.rev():
        if popup.kind == ToolTip: continue                  // input-transparent
        tree = None; menubar_item = None
        if popup is ChildWindow and inside(ev, popup):
            tree = popup.component; offset = popup.location; break
        if popup is the TopLevel window we are in:
            tree = self.component; break
        if popup.kind != Menu: break                        // <-- pointer modality
        if to_close.is_some(): to_close = popup.id          // collapse the whole chain
        menubar_item = popup.parent_item
    if tree is None and menubar_item is None: send_exit_events(); done
```

— `internal/core/window.rs:836-899` ([source][window-hittest-walk])

While a plain popup is open the rest of the UI receives zero mouse events — which is also why `has-hover` elsewhere goes false. Menus are the deliberate exception: the walk continues down the chain, promotes any pending close to the **lowest** menu so an outside click collapses the entire cascade, and when the walk exhausts, re-routes the event into the menubar item's parent tree with a translation, which is what lets a pointer slide from an open menu onto a sibling menu title. The keyboard is contained but not blocked — window-level Tab, Escape and menubar shortcuts still run.

**Where it lives.** Framework kernel, roughly 30 lines of `WindowInner::process_mouse_input`. No flags, no scrim item, no modal stack.

**Degradation.** Perfectly portable: a reverse-order loop over a `Vec` with per-overlay origin translation. The finding worth carrying is that modality need not be a property — "stop the walk at the first non-menu overlay" gives a modal popup and "keep walking" gives a [light-dismiss][light-dismiss] menu chain, from the same three lines of loop control. The absence to note alongside it: with no scrim nothing communicates the modality visually, and with no accessibility modal bit a screen reader can still wander into blocked content.

### 12. Adaptive presentation

Adaptation happens at three layers, and none of them is the style layer.

**Surface adaptation.** `show_popup` compares the parent and popup window adapters by `Rc::ptr_eq`; if the backend's `create_child_window_adapter(kind)` returned `None`, the popup silently becomes an in-window overlay. The decision therefore lives in the **backend, by omission** — the trait's default implementation is literally `None` (`window.rs:196-206`), and the comment at the decision site says so: "because we weren't able to create a dedicated popup adapter (for example if the backend does not support it)". In this tree the Qt backend is the one that overrides it with a real OS child window (`qt_window.rs:2471-2488`), with the testing backend overriding it for test purposes.

**Native-menu adaptation.** A context menu first attempts `show_native_popup_menu` and only instantiates `PopupMenuImpl` as a Slint popup if that returns false (`rust.rs:3833-3835`). One `ContextMenuArea` can therefore render as an OS menu, as an OS child window, or in-canvas.

**Input adaptation.** Touch versus pointer is decided in the runtime item at **compile time**: `#[cfg(target_os = "android")]` arms in `ContextMenu::input_event` turn a left press into a long-press timer using `Platform::long_press_interval()` (500 ms default, with the Android backend querying `ViewConfiguration.getLongPressTimeout()`), and `#[cfg(target_os = "windows")]` adds `Shift+F10`.

There is no popover-to-sheet transformation, no compact size class, no teaching tip and no keyboard-driven relocation.

**Where it lives.** Backend (by declining a capability), framework kernel (the fallback), and the runtime item (`#[cfg]`-gated touch behaviour). Explicitly not the style layer and not the application.

**Degradation.** The capability-declined-by-default pattern is the lesson: because the trait default is `None`, every new backend gets the in-canvas path for free and only opts into OS windows if it can, which makes the in-window path the well-trodden one rather than a fallback. The gap is the soft keyboard: Slint computes `safe_area_inset()` and applies it to the window item, but hands `place_popup` a clip region of `(0, 0, windowSize)`, so on Android a popup can be placed under the IME. See [`./compose.md`][compose] and [`./apple.md`][apple] for the presentation ladders Slint does not attempt, and [`../window-system-integration/index.md`][wsi] for the surface question itself.

### 13. Accessibility

Popups are **present** in the accessibility tree but **unlabelled as popups**. `AccesskitAdapter::build_new_tree` collects the `ChildWindow` popups, finds each one's accessible ancestor (falling back to the root), and recurses into the popup's item tree passing `window_position = popup.location` so every node's bounds are reported in window space. `TopLevel` popups are filtered out by a `let … else { return None }` on the location (`accesskit.rs:450`), so the accessibility integration covers only the in-window surface.

The `AccessibleRole` enum (`internal/common/enums.rs:474-536`) has no `Tooltip`, `Menu`, `MenuItem`, `Dialog`, `Popup` or listbox-popup member, so a popup root maps to `Role::Unknown` (`accesskit.rs:502`). There is no describedby analogue, no modal bit and no live-region tie-in for the tooltip. Because the tooltip is input-transparent by construction (dimension 7), Slint structurally enforces that tooltip content is never interactive — an emergent consequence of the routing skip rather than a stated policy.

Against WCAG 1.4.13: dismissable yes (pointer leave hides it), **hoverable no** (the tooltip cannot be hovered, so overflowing content cannot be read at leisure), and it disappears immediately on leave with no grace period. There is no assistive-technology-specific timing anywhere.

**Algorithm.**

```text
a11y_tree():
    popups = [(loc, accessible_parent(p.parent_item), p.component)
              for p in active_popups if p is ChildWindow]
    build(item, window_position):
        node     = build_node_without_children(item, scale, window_position)
        children = accessible_descendents(item).map(build with same window_position)
                ++ popups.where(parent_node == id(item)).map(build with window_position = popup.location)
        node.set_children(children)
```

**Where it lives.** Backend: `internal/backends/winit/accesskit.rs`. The core exposes `active_popups()` and nothing more; `internal/core` has no accessibility concept of a popup.

**Degradation.** The transferable part is the **graft algorithm, not the semantics**: "a derived tree re-parents each overlay under its anchor's node and offsets its coordinates by the overlay origin" is exactly what a terminal grid must do for its own derived trees, and Slint demonstrates the same shape serving accessibility, element queries and hit testing. What belongs to the primitive is the graft plus the origin; role, the description-versus-label distinction and the modal bit belong to a semantic component, and Slint's primitive attempts none of them. The normative contract Slint is measured against here is catalogued in [`./aria-apg.md`][aria-apg].

### 14. Animation

**Not applicable — and the absence is itself the finding.** Slint emits no geometry metadata for animation. Nothing tells the popup content which side it ended up on, whether it was clamped, whether it was shrunk, or where the anchor sits relative to it: `place_popup` returns a `LogicalRect` that is stored in `PopupWindowLocation::ChildWindow` and read only by the renderer, the hit test and the accessibility graft. There is no transform origin, no enter/exit hook and no reduced-motion query in the popup path.

Popup _content_ can use Slint's ordinary `animate` and `states`, but only on properties the author already controls; a popup's **placement** is neither animatable nor observable. Repositioning is not animated either — it is a hard jump two event-loop turns after the dependency changed, with the old and new rects both marked dirty so a partial renderer repaints both (`window.rs:1494-1503`).

**Where it lives.** Nowhere: no animation-facing surface exists in `window.rs`, `popup.rs` or the style files' popups.

**Degradation.** The informative part is that Slint ships menus, comboboxes, date pickers and tooltips with zero placement-derived animation. On a cell grid, where the only affordable motion is a per-frame content swap, emitting side and alignment metadata would be pure cost _unless_ a component actually renders a directional caret — which is the same conclusion dimension 4 reaches from the other direction.

### 15. State architecture

Two layers, both minimal.

**Per window.** `active_popups: RefCell<Vec<PopupWindow>>`, `next_popup_id: Cell<NonZeroU32>` and one `had_popup_on_press: Cell<bool>` (`window.rs:518-521`). Ids start at 1 and advance with `checked_add(1).unwrap()`, so they never repeat and never alias. There is no state machine, no reducer and no controller object — dismissal is a pure function of `(policy, inside, pressed, released, had_popup_on_press)` evaluated inline.

**Per popup.** `PopupWindow` is a plain struct, but two of its fields are decidedly not value-semantic: the boxed position closure, and a pinned `PropertyTracker` whose dirty handler schedules a zero-duration timer.

Control is **uncontrolled and non-retained**: generated code constructs a brand-new component instance on every `show()`, so popup content state is destroyed on close and `init =>` re-runs; the handle you keep is only a `NonZeroU32`. `ContextMenu` stores `popup_id: Cell<Option<NonZeroU32>>` and implements `is_open()` by _searching_ `active_popups` for that id — id-as-handle, not pointer-as-handle. The compiler enforces isolation: you may not reference anything inside a `PopupWindow` from the enclosing component, and a `PopupWindow` may not be directly repeated or made conditional.

**Algorithm.**

```text
state = Vec<PopupWindow>            // a stack; top = last
open(id):    id = next++; close every sibling sharing parent_item; push
close(id):   remove by id; if kind == Menu, keep removing while popups[idx] is Menu; restore focus
is_open(id): active_popups.any(|p| p.popup_id == id)
```

**Where it lives.** Framework kernel. The ids and the `Vec` are the entire architecture — there is no popup manager, service or provider.

**Degradation.** The `Vec`-of-records plus monotonic-id design ports directly to a `@nogc` value-semantics toolkit; that half is already plain data. The two non-plain-data fields are exactly the parts a canvas toolkit does not need: a per-frame recomputation from a comparable `(anchor, offset)` value replaces the boxed closure, and an immediate-mode frame loop makes the tracker and timer unnecessary. That substitution would also remove the two-turn reposition latency and the untracked anchor-geometry read. Compare the explicit statecharts in [`./zag.md`][zag] and the array-membership model in [`./base-ui.md`][base-ui].

### 16. Shared infrastructure

Slint factors everything through **one** primitive and pushes all differentiation up into `.slint`. `PopupWindow` — plus the three-valued `WindowKind` and the three-valued `PopupClosePolicy` — is the whole shared layer. On top of it:

- **ComboBox** popups are hand-written per style (`x: 0; y: root.height`, or `y: -4px` in the Fluent style, whose source carries the comment that ideally the current element should sit over the popup — an intent the primitive cannot express).
- **`DatePickerPopup` / `TimePickerPopup`** literally inherit `PopupWindow` with `close-policy: no-auto-close` and no placement at all.
- **`PopupMenuImpl`** is a Slint component containing a `ContextMenuInternal` for its own submenu — recursion by composition, not by a menu engine.
- **Tooltip** is a compiler pass that synthesizes `TooltipArea` + `PopupWindow` + `ToolTipImpl`.

What genuinely lives in the shared primitive: the stack, the ids, the surface decision, the clamp, the close policies, focus save/restore, the render graft, the accessibility graft, and coordinate mapping. What is deliberately not shared: placement (every consumer authors its own `x`/`y`), timing (a Rust runtime item for tooltips, a `.slint` `Timer` for submenus — two implementations of one idea), keyboard behaviour (arrow-key navigation lives inside `PopupMenuImpl`'s `FocusScope`, not in the primitive), and content chrome.

The one thing shared **by accident** is `WindowKind`, which conflates "no focus steal plus input transparent" (tooltip) with "participates in the cascade" (menu). The doc comment on the field has to spell out both jobs, and the hit-test loop tests `window_kind` twice, twenty lines apart, for two different meanings (`window.rs:837` and `:857`).

**Algorithm.**

```text
one primitive:   show_popup(component, || position, policy, parent_item, kind) -> id
every surface  = a .slint component + an authored x/y expression + a policy constant
```

**Where it lives.** Split by intent: `internal/core/window.rs` owns the stack and lifecycle; `internal/compiler/passes/{lower_popups,lower_tooltips,lower_menus}.rs` own the desugaring; `internal/compiler/widgets/**` owns per-component behaviour, with each style re-implementing its own combobox and menu chrome.

**Degradation.** The split is a usable template for a cell toolkit: a primitive owning the stack, ids, anchor plus offset, clamp, dismissal policy, focus containment and the render/hit/accessibility graft — and nothing else — with tooltip, menu and combobox as components supplying placement expressions and their own key handling. The countervailing warning is `WindowKind`: once one enum means "input transparent" _and_ "cascades on close" _and_ "does not take focus", three orthogonal booleans have been merged, and Slint's own loop pays for it twice in the same function.

## Strengths

- The in-window path is the **default** and the well-tested one. A production toolkit ships menus, comboboxes, date and time pickers and tooltips with no OS popup, no compositor and no top layer on every backend except Qt — an existence proof that this constraint set is sufficient for a real widget library.
- `place_popup` is 24 lines with an exhaustive table test (9 clip offsets × 2 clip sizes × 4 size classes × 9 positions), degenerate "popup larger than the clip" case included. Placement is the one part of the system that is provably correct.
- Focus containment for free from `ParentItemTraversalMode::StopAtPopups`: one enum value in the parent walk yields both key-bubbling containment and Tab containment, with no trap logic, sentinels or focus-cycle bookkeeping.
- `ForwardAndObserve` plus the observers side-list is a genuinely non-obvious input-routing primitive: a transparent hover tracker gets a reliable `Exit` even when a sibling claims the event, and an observer whose filter never ran is not spuriously exited.
- Modality with no modality flag — "stop the hit-test walk at the first non-menu overlay" versus "keep walking" is the only difference between a modal popup and a light-dismiss menu chain.
- Popups are grafted into the accessibility tree under their anchor node with correct window-space bounds, and into the headless element-query tree the same way, so an overlay is discoverable and assertable without a window, not merely paintable.
- The feature is exercised by a set of declarative `.slint` test cases whose Rust/C++/JS assertions run against a headless testing backend with mocked time and a `use_native_popup(bool)` switch that flips the surface — both surfaces are testable with no window.

## Weaknesses

- **No flip and no anchor rect.** A bottom-anchored menu near the window edge slides up and covers its own anchor. The commented-out `anchor_x`/`anchor_y`/`anchor_height`/`anchor_width` properties in the shipped builtin declaration show the gap was at least contemplated.
- **Clamping is a one-shot at open time.** `place_popup` has exactly one call site, and the reposition path assigns the raw offset (`*old_location = offset;`, `window.rs:1491-1492`), so a popup that moves after opening can escape the window.
- The anchor's own geometry is read outside the property tracker, so an open popup does not follow a scrolling, animating or relaid-out anchor — and nothing closes it either (no dismissal on scroll, resize, window deactivation, or the anchor becoming hidden).
- A `ChildWindow` popup's own `background` is silently never painted, because every renderer's window-background step is a no-op for the non-root case. The same declaration therefore has a background under Qt and none under winit; the shipped widgets all work around it by wrapping content in a `Rectangle` or a menu border.
- `absolute-position` is implemented as a map-to-window that excludes popup offsets, so the language exposes an "absolute" position that is not absolute inside a popup. The submenu placement expression in `menus.slint` exists to compensate for exactly this.
- **Source-internal discrepancy** on tooltip clamping: two comments say tooltips are unclamped while the adjacent line passes `Some(window rect)` for every kind.
- Two event-loop turns of reposition latency from the dirty-handler-schedules-a-timer design; the declarative test advances mocked time twice and says why in a comment.
- No arrow or caret concept, no placement metadata for animation, no `AccessibleRole` for tooltip/menu/dialog (popup roots become `Role::Unknown`), no modal accessibility bit, no scrim, and no shared tooltip timing policy.
- Safe-area insets are computed and exposed on the `Window` item but never fed into `place_popup`, so on Android a popup can be placed under the soft keyboard or a display cutout.
- `TopLevel` popups get no clamping from Slint and no accessibility integration at all (the AccessKit collector filters them out), so the two surfaces are not behaviourally equivalent. Whether Qt itself repositions such a child widget to keep it on screen was not investigated here.

## Key design decisions and trade-offs

| Decision                                                                                                                                        | Rationale                                                                                                                                                                                                                                                                      | Trade-off                                                                                                                                                                                                                                                                                                             |
| ----------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Make `PopupWindow` a language construct lowered into a separate `Component`, not an element in the tree.                                        | An overlay must escape every ancestor's clipping, layout and coordinate space. Extraction makes that structural rather than a rendering special case: no clip is pushed, no z-index is needed, and the popup's position in the parent's child order stops mattering.           | Two coordinate spaces leak into the language (`absolute-position` is popup-relative), the enclosing component may not reference anything inside the popup, a `PopupWindow` cannot be repeated or conditional, and every derived tree — accessibility, element query, hit test — has to re-graft the popup separately. |
| One placement mode: clamp to the parent window, once, at open time. No flip, no sides, no anchor rect.                                          | Keeps the primitive to 24 testable lines and pushes placement policy to the author, who knows the intent; backed by an exhaustive table test rather than heuristics.                                                                                                           | Every consumer re-invents placement: submenus always open right (`x: root.width`), comboboxes always open below or at a magic `-4px`, and a style file carries a comment describing an intent the primitive cannot express. Near a window edge, popups cover their own anchors.                                       |
| Let the backend decide the surface by **declining a capability**: `create_child_window_adapter` defaults to `None`, and `None` means in-window. | New backends get a working popup with zero code, and the in-window path becomes the well-trodden one rather than the fallback.                                                                                                                                                 | One declaration behaves differently per backend with no way to detect which you got: the `ChildWindow` path never paints the popup's own background and has no OS-level pointer grab, while the `TopLevel` path puts focus in a second window store and applies no clamping.                                          |
| Make tooltips a `WindowKind` that the hit test skips rather than a separate primitive.                                                          | Deletes the whole safe-polygon / pointer-bridge / interactive-border problem class, and makes "a tooltip never steals focus" a one-line branch at open time.                                                                                                                   | Tooltip content can never be interactive or hoverable (a WCAG 1.4.13 _Hoverable_ failure), and the enum now conflates transparency, focus policy and cascade behaviour — the hit-test loop tests `window_kind` twice, twenty lines apart, for two different meanings.                                                 |
| Reposition through the reactive property graph (a `PropertyTracker` plus a zero-duration coalescing timer) instead of recomputing per frame.    | A retained toolkit recomputes only what got dirty, and the tracker re-subscribes to whatever the `x`/`y` expression happens to read, so authored placement expressions are automatically live.                                                                                 | Two event-loop turns of latency; the anchor's own geometry is read _outside_ the tracker, so a popup does not follow a scrolled or relaid-out anchor; and the reposition path skips `place_popup` entirely, so a moved popup escapes the window clamp.                                                                |
| Consume the dismissing click rather than passing it through, and bake the close policy at compile time.                                         | Predictability: "first click closes, second click acts" is testable and avoids destructive accidents. A compile-time policy makes the runtime rule a three-arm match with no dynamic state.                                                                                    | `close-policy` cannot depend on anything at run time, every dismiss-then-act interaction costs two clicks, and the Escape branch returns `EventAccepted` even when no popup was open, silently swallowing the key.                                                                                                    |
| Construct a fresh content component on every `show()` and drop it on close.                                                                     | Stale content state (scroll position, highlighted index, entered text) can never reappear on the next open, and the overlay's memory is strictly scoped to its open interval. The compiler's isolation rule — the host may not name anything inside the popup — makes it safe. | Content state that _should_ persist across opens has to be hoisted out of the popup by the author, and `init =>` re-runs on every open.                                                                                                                                                                               |

## Sources

Primary sources, all read at `24318cebc2b3feed4f7187e237915f52715ce285`:

- Runtime core — [`internal/core/window.rs`][window-popuplocation]: `PopupWindowLocation` (`:431`), `PopupWindow` (`:441`), `WindowKind` (`:47`), the default `create_child_window_adapter` (`:196`), `safe_area_inset` (`:263`), `active_popups`/`next_popup_id`/`had_popup_on_press` (`:518`), `process_mouse_input` (`:764-965`), Escape handling (`:1136`), `update_popup_properties` (`:1432`), `draw_contents` and `post_render` (`:1518-1600`), `show_popup` (`:1700-1860`), `close_popup` and the menu cascade (`:1921`).
- Placement — [`internal/core/window/popup.rs`][popup-place]: `Placement`, `place_popup`, and the exhaustive `test_place_popup_fixed_clipped` table test.
- Item tree — [`internal/core/item_tree.rs`][itemtree-stop-at-popups]: `ParentItemTraversalMode::StopAtPopups` (`:386`), popup closing on tree teardown (`:223`), `map_to_native_window` (`:589`).
- Runtime items — [`internal/core/items.rs`][items-tooltiparea]: `TooltipArea` filter and timer (`:2013`, `:2104`), `ContextMenu` input and key handling (`:1618`, `:1666`), `ContextMenu::popup_id`/`is_open` (`:1577`, `:1723`).
- Input routing — [`internal/core/input.rs`][input-forward-observe]: `ForwardAndObserve` (`:246-248`) and the observer `Exit` rule (`:1435-1448`).
- Rendering — [`internal/core/item_rendering.rs`][rendering-render-components] (`:243`) and [`internal/renderers/software/lib.rs`][software-render-loop] (`:681`).
- Compiler passes — [`lower_popups.rs`][lower-popups] (extraction, close-policy resolution, isolation checks), [`lower_tooltips.rs`][lower-tooltips-placement] (synthesized `TooltipArea`, downward-only offset, conditional handling).
- Code generation — [`internal/compiler/generator/rust.rs`][rust-access-position]: the position closure (`:3676`), fresh instance per `show()` (`:3668`), native-menu-first fallback (`:3833`).
- Builtin declarations — [`internal/compiler/builtins.slint`][builtins-popupwindow]: `PopupWindow` (`:2467`), the commented-out anchor properties (`:2472`), `TooltipArea` defaults (`:2499`).
- Shipped widgets — [`menus.slint`][menus-popupmenuimpl] (`PopupMenuImpl`, the submenu timer, the hard-coded `x: root.width`), [`tooltip-base.slint`][tooltip-base], [`menu-base.slint`][menu-base], [`fluent/combobox.slint`][fluent-combobox], [`material/datepicker.slint`][material-datepicker].
- Backends — [`winit/accesskit.rs`][accesskit-build-tree] (the accessibility graft), [`testing/search_api.rs`][testing-search-api] (the element-query graft), [`testing/internal_tests.rs`][testing-internal-tests] (test-only re-exports), [`qt/qt_window.rs`][qt-create-child] (the one `TopLevel` implementation in this tree), [`android-activity/lib.rs`][android-long-press] (long-press interval).
- Declarative tests — [`popupwindow_position.slint`][test-popup-position] (two-tick reposition), [`tooltip_on_button.slint`][test-tooltip] (no skip-delay on re-entry), [`popupwindow_nested.slint`][test-nested] (the dismissing click is consumed).

Catalog context: [index][index] · [shared vocabulary][concepts] · [comparison][comparison] · [features people forget][fpf] · [the sparkles baseline][baseline] · [the proposal][proposal]. Related trees: [window-system integration][wsi], [platform UI guidelines][platform-guidelines], [UI layout][ui-layout], [Sean Parent][sean-parent]. Toolkit specs: [`sparkles:ui`][spec-ui], [input][spec-input], [containers][spec-containers], [state machines][spec-state-machines], [backends][spec-backends], [widgets][spec-widgets].

<!-- References -->

[slint-repo]: https://github.com/slint-ui/slint
[slint-docs]: https://docs.slint.dev/
[window-popuplocation]: https://github.com/slint-ui/slint/blob/24318cebc2b3feed4f7187e237915f52715ce285/internal/core/window.rs#L431
[window-clip-region]: https://github.com/slint-ui/slint/blob/24318cebc2b3feed4f7187e237915f52715ce285/internal/core/window.rs#L1810
[window-update-popup-props]: https://github.com/slint-ui/slint/blob/24318cebc2b3feed4f7187e237915f52715ce285/internal/core/window.rs#L1432
[window-draw-contents]: https://github.com/slint-ui/slint/blob/24318cebc2b3feed4f7187e237915f52715ce285/internal/core/window.rs#L1528
[window-hittest-walk]: https://github.com/slint-ui/slint/blob/24318cebc2b3feed4f7187e237915f52715ce285/internal/core/window.rs#L836
[window-sibling-close]: https://github.com/slint-ui/slint/blob/24318cebc2b3feed4f7187e237915f52715ce285/internal/core/window.rs#L1756
[window-tooltip-focus]: https://github.com/slint-ui/slint/blob/24318cebc2b3feed4f7187e237915f52715ce285/internal/core/window.rs#L1847
[popup-place]: https://github.com/slint-ui/slint/blob/24318cebc2b3feed4f7187e237915f52715ce285/internal/core/window/popup.rs#L19
[popup-placement-enum]: https://github.com/slint-ui/slint/blob/24318cebc2b3feed4f7187e237915f52715ce285/internal/core/window/popup.rs#L11
[popup-table-test]: https://github.com/slint-ui/slint/blob/24318cebc2b3feed4f7187e237915f52715ce285/internal/core/window/popup.rs#L86
[itemtree-stop-at-popups]: https://github.com/slint-ui/slint/blob/24318cebc2b3feed4f7187e237915f52715ce285/internal/core/item_tree.rs#L386
[items-tooltiparea]: https://github.com/slint-ui/slint/blob/24318cebc2b3feed4f7187e237915f52715ce285/internal/core/items.rs#L2013
[input-forward-observe]: https://github.com/slint-ui/slint/blob/24318cebc2b3feed4f7187e237915f52715ce285/internal/core/input.rs#L246
[rendering-render-components]: https://github.com/slint-ui/slint/blob/24318cebc2b3feed4f7187e237915f52715ce285/internal/core/item_rendering.rs#L243
[software-render-loop]: https://github.com/slint-ui/slint/blob/24318cebc2b3feed4f7187e237915f52715ce285/internal/renderers/software/lib.rs#L681
[lower-popups]: https://github.com/slint-ui/slint/blob/24318cebc2b3feed4f7187e237915f52715ce285/internal/compiler/passes/lower_popups.rs#L45
[lower-tooltips-placement]: https://github.com/slint-ui/slint/blob/24318cebc2b3feed4f7187e237915f52715ce285/internal/compiler/passes/lower_tooltips.rs#L204
[rust-access-position]: https://github.com/slint-ui/slint/blob/24318cebc2b3feed4f7187e237915f52715ce285/internal/compiler/generator/rust.rs#L3676
[rust-fresh-instance]: https://github.com/slint-ui/slint/blob/24318cebc2b3feed4f7187e237915f52715ce285/internal/compiler/generator/rust.rs#L3668
[builtins-popupwindow]: https://github.com/slint-ui/slint/blob/24318cebc2b3feed4f7187e237915f52715ce285/internal/compiler/builtins.slint#L2467
[builtins-anchor-commented]: https://github.com/slint-ui/slint/blob/24318cebc2b3feed4f7187e237915f52715ce285/internal/compiler/builtins.slint#L2472
[menus-popupmenuimpl]: https://github.com/slint-ui/slint/blob/24318cebc2b3feed4f7187e237915f52715ce285/internal/compiler/widgets/common/menus.slint#L9
[tooltip-base]: https://github.com/slint-ui/slint/blob/24318cebc2b3feed4f7187e237915f52715ce285/internal/compiler/widgets/common/tooltip-base.slint#L6
[menu-base]: https://github.com/slint-ui/slint/blob/24318cebc2b3feed4f7187e237915f52715ce285/internal/compiler/widgets/common/menu-base.slint#L81
[fluent-combobox]: https://github.com/slint-ui/slint/blob/24318cebc2b3feed4f7187e237915f52715ce285/internal/compiler/widgets/fluent/combobox.slint#L107
[material-datepicker]: https://github.com/slint-ui/slint/blob/24318cebc2b3feed4f7187e237915f52715ce285/internal/compiler/widgets/material/datepicker.slint#L11
[accesskit-build-tree]: https://github.com/slint-ui/slint/blob/24318cebc2b3feed4f7187e237915f52715ce285/internal/backends/winit/accesskit.rs#L444
[testing-search-api]: https://github.com/slint-ui/slint/blob/24318cebc2b3feed4f7187e237915f52715ce285/internal/backends/testing/search_api.rs#L353
[testing-internal-tests]: https://github.com/slint-ui/slint/blob/24318cebc2b3feed4f7187e237915f52715ce285/internal/backends/testing/internal_tests.rs#L14
[qt-create-child]: https://github.com/slint-ui/slint/blob/24318cebc2b3feed4f7187e237915f52715ce285/internal/backends/qt/qt_window.rs#L2471
[android-long-press]: https://github.com/slint-ui/slint/blob/24318cebc2b3feed4f7187e237915f52715ce285/internal/backends/android-activity/lib.rs#L178
[test-popup-position]: https://github.com/slint-ui/slint/blob/24318cebc2b3feed4f7187e237915f52715ce285/tests/cases/elements/popupwindow_position.slint#L127
[test-tooltip]: https://github.com/slint-ui/slint/blob/24318cebc2b3feed4f7187e237915f52715ce285/tests/cases/elements/tooltip_on_button.slint#L78
[test-nested]: https://github.com/slint-ui/slint/blob/24318cebc2b3feed4f7187e237915f52715ce285/tests/cases/elements/popupwindow_nested.slint#L268
[index]: ./index.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[fpf]: ./features-people-forget.md
[baseline]: ./sparkles-baseline.md
[proposal]: ./proposal.md
[anchor-rect]: ./concepts.md
[placement]: ./concepts.md
[gravity]: ./concepts.md
[constraint-adjustment]: ./concepts.md
[clipping-boundary]: ./concepts.md
[top-layer]: ./concepts.md
[light-dismiss]: ./concepts.md
[grab]: ./concepts.md
[safe-polygon]: ./concepts.md
[warm-up]: ./concepts.md
[cool-down]: ./concepts.md
[focus-scope]: ./concepts.md
[modality]: ./concepts.md
[virtual-anchor]: ./concepts.md
[transform-origin]: ./concepts.md
[xdg-positioner]: ./xdg-positioner.md
[gtk4]: ./gtk4.md
[avalonia]: ./avalonia.md
[qt-widgets]: ./qt-widgets.md
[imgui]: ./imgui.md
[gpui]: ./gpui.md
[textual]: ./textual.md
[compose]: ./compose.md
[apple]: ./apple.md
[react-aria]: ./react-aria.md
[tippy]: ./tippy.md
[zag]: ./zag.md
[base-ui]: ./base-ui.md
[aria-apg]: ./aria-apg.md
[wsi]: ../window-system-integration/index.md
[platform-guidelines]: ../platform-ui-guidelines/index.md
[ui-layout]: ../ui-layout/index.md
[sean-parent]: ../sean-parent/index.md
[spec-ui]: ../../specs/ui/index.md
[spec-input]: ../../specs/ui/input.md
[spec-containers]: ../../specs/ui/containers.md
[spec-state-machines]: ../../specs/ui/state-machines.md
[spec-backends]: ../../specs/ui/backends.md
[spec-widgets]: ../../specs/ui/widgets.md
