# Anchored-Overlay Concepts: Shared Vocabulary

The shared-vocabulary page for the [anchored-overlays][index] survey. Every per-subject
deep-dive — [Floating UI][floating-ui], [xdg_positioner][xdg-positioner], [GTK4][gtk4],
[Avalonia][avalonia], [Textual][textual], [GPUI][gpui], [Dear ImGui][imgui],
[Neovim floats][neovim-floats], … — links back here on first use of a term of art, so
each idea is defined **once**, grounded in one system that names it best, and pinned to
that system's source at a fixed revision.

The page exists for a second reason a glossary link could not serve. This catalog's
framing question is _what survives on a toolkit that renders every overlay inside one
surface, in integer cells, on targets that variously lack hover, key releases, scripting
and an OS window_ — and a large fraction of these terms **mean something different in a
cell grid than on a pixel surface**. Where that is true the entry says so explicitly,
under a bolded **In cells** lead-in. Where it is not true, the entry says nothing, which
is itself information.

> [!NOTE]
> **Scope.** Definitions and the one canonical spelling per concept. Mechanics stay in
> the deep-dives; the cross-subject synthesis is [`comparison.md`][comparison]; what
> `sparkles:ui` can express today is [`sparkles-baseline.md`][baseline]; the design that
> follows is [`proposal.md`][proposal]; the behaviours a first implementation habitually
> omits are collected in [`features-people-forget.md`][forgotten]. Terms that are windowing concepts wearing an
> overlay hat (compositor grabs, override-redirect, surface roles) are defined in the
> sibling [window-system-integration][wsi] tree and only cross-referenced here.

> [!IMPORTANT]
> **Every claim on this page was adversarially verified**, and the wording reflects the
> verdict. Statements are scoped to _the subjects examined_ rather than universally
> quantified; a claim that is a reading rather than an observation is labelled
> **INFERENCE** in the prose. Where verification narrowed a claim, the narrowed form is
> what appears.

**Last reviewed:** August 14, 2026

---

## Canonical spellings {#canonical-spellings}

The field names the same handful of operations a dozen ways. This table fixes the
catalog's spelling, and says which system it is borrowed from. Deep-dives use the
canonical column; the "also spelled" column is what you will read in the sources.

| Concept                                    | Canonical spelling                              | Borrowed from                                                   | Also spelled in the field                                                                                                                 |
| ------------------------------------------ | ----------------------------------------------- | --------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| the whole repair family                    | [constraint adjustment](#constraint-adjustment) | [`xdg_positioner`][xdg-positioner]                              | "collision detection" (Floating UI), "fit logic" (Compose), "nudge" (WPF)                                                                 |
| mirror to the other side of the anchor     | [flip](#flip)                                   | [`xdg_positioner`][xdg-positioner] / [Floating UI][floating-ui] | `inflect` (Textual), `SwitchAnchor` (GPUI), `FlipX`/`FlipY` (Avalonia), "reposition" (Qt Quick)                                           |
| slide along the edge axis to stay inside   | [shift](#shift)                                 | [Floating UI][floating-ui]                                      | `slide_x`/`slide_y` (Wayland), `SlideX` (Avalonia), `translate_inside` (Textual), "nudge" (WPF), `Rect::clamp` (Ratatui)                  |
| the last-resort clamp on the **side** axis | [push](#push)                                   | [Angular CDK][angular-cdk]                                      | folded into "slide"/"clamp" nearly everywhere else                                                                                        |
| shrink the overlay to the room left        | [resize](#resize)                               | [`xdg_positioner`][xdg-positioner]                              | `size()` middleware (Floating UI), `ResizeToFit` (WinUI), "shrink-and-restore" (Qt Quick)                                                 |
| the rect the overlay must stay inside      | [boundary](#boundary)                           | [Floating UI][floating-ui]                                      | "inset-modified containing block" (CSS), `WorkingArea` (Avalonia), `viewport` (Helix), `r_outer` (ImGui), "clip region" (Slint)           |
| ordered alternatives to try                | [fallback list](#fallback-list)                 | [Floating UI][floating-ui] `fallbackPlacements`                 | `position-try-fallbacks` (CSS), `placementOrder` (WinUI), `direction_priority` (blink.cmp), `ConnectedPosition[]` (Angular CDK)           |
| the painted-last, clip-free plane          | [top layer](#top-layer)                         | [CSS `position-4`][css-anchor] / [HTML][popover-api]            | `layers` (Textual), `zindex` (Neovim), "deferred draw" (GPUI), `.cdk-overlay-container` (Angular CDK)                                     |
| close on an outside interaction            | [light dismiss](#light-dismiss)                 | [WinUI][winui] (adopted by [HTML][popover-api])                 | `CloseOnPressOutside` (Qt Quick), `DismissableLayer` (Radix), `transient` (AppKit), `autohide` (GTK4)                                     |
| the corridor between anchor and overlay    | [safe polygon](#safe-polygon)                   | [Floating UI][floating-ui] `safePolygon`                        | "safe area" (WPF), "safe zone" (WinUI), "grace area" (Radix), "intent polygon" (Zag)                                                      |
| tolerate crossing the parent's own items   | [menu-aim](#menu-aim)                           | [Angular CDK][angular-cdk] `cdkTargetMenuAim`                   | "sloppy submenus" (Qt), `useSafelyMouseToSubmenu` (React Aria), "the Amazon triangle" (ImGui's own citation)                              |
| grow the surface's own hit rect            | [interactive border](#interactive-border)       | [Tippy][tippy] `interactiveBorder`                              | `padded_submenu_bounds` (GPUI), `TransientWithDismissOnPointerMoveAway` (Avalonia)                                                        |
| first-open delay                           | [warm-up](#warm-up)                             | [React Aria][react-aria] `globalWarmedUp`                       | `InitialShowDelay` (WPF), `delayDuration` (Radix), `delay[0]` (Tippy), `wakeDelay` (Qt)                                                   |
| the window in which the next open is free  | [cool-down](#cool-down)                         | [React Aria][react-aria] `TOOLTIP_COOLDOWN`                     | `BetweenShowDelay` (WPF), `skipDelayDuration` (Radix), `skipTimeout` (Ariakit), `toolTipFallAsleep` (Qt), `BROWSE_DISABLE_TIMEOUT` (GTK4) |
| the translucent blocking plane             | [scrim](#scrim)                                 | Material / [Compose][compose]                                   | `dimmer` (Qt Quick), "light-dismiss overlay" (WinUI/Uno), `ModalBarrier` (Flutter), `::backdrop` (CSS)                                    |
| the anchor left its clip                   | [anchor-hidden](#anchor-hidden)                 | [Floating UI][floating-ui] `hide()` → `referenceHidden`         | `position-visibility: anchors-visible` (CSS), `isOverlayClipped` (Angular CDK)                                                            |
| the overlay left the anchor's scroller     | [escaped](#anchor-hidden)                       | [Floating UI][floating-ui] `hide()` → `escaped`                 | `data-escaped` (Tippy, re-projected from Popper)                                                                                          |

Two of these picks deserve a sentence of justification, because they cut across an
otherwise consistent source.

- **`shift`, not `slide`.** [`xdg_positioner`][xdg-positioner] supplies the umbrella
  ([constraint adjustment](#constraint-adjustment)) and the [flip](#flip) semantics this
  catalog adopts, and it calls the second adjustment `slide_x`/`slide_y`. The catalog
  still takes **shift** from Floating UI, because the placement recommendation splits the
  operation in two — an edge-axis `shift` and a side-axis last-resort [push](#push) — and
  Wayland's single word cannot carry that split. Keeping `slide` would make the two
  indistinguishable in prose exactly where the distinction is load-bearing.
- **`push`, from Angular CDK.** Almost no other subject names the side-axis clamp
  separately; CDK's `_pushOverlayOnScreen` does, and the distinction survived
  verification as the thing that separates a defect from a legitimate last resort (see
  [push](#push)).

---

## 1. The anchor {#anchor-group}

### Anchor {#anchor}

The **anchor** is the thing an overlay is positioned _relative to_: the geometry that
enters the placement arithmetic. Of the 38 subjects surveyed, every one reduces whatever
the caller supplied — an element handle, a widget, a text offset, a cursor position, a
name — to an axis-aligned integer rect plus a corner/edge selector at exactly one named
seam, and nothing downstream of that seam sees the original.

[`xdg_positioner`][xdg-positioner] names the value form best because it has no choice:
the client and the solver are in different processes. The anchor is
[`set_anchor_rect(x, y, width, height)`][xdg-anchor-rect] plus a
[nine-value `anchor` enum][xdg-anchor-enum], and the copy semantics are
[normative][xdg-copy] — "the compositor makes a copy of the rules … the object can be
destroyed or reused". Roughly twenty independent compositors, sharing no code and
separated by a socket, produce compatible placements from it.

The catalog's restated position after verification: **across the surveyed subjects the
anchor's _placement inputs_ reduce to a Regular POD** — kind, key, rect (or per-row
rects), an optional [avoid rect](#avoid-rect), and a [tracking policy](#anchor-tracking).
That is narrower than "an anchor is a value". Subjects that retain a live handle use it
for two things beyond re-measurement, and each needs a value-shaped substitute:
**boundary/scope derivation** (Floating UI passes `element.contextElement` into
`platform.getClippingRect` and walks its overflow ancestors for scroll-dismissal scoping)
and **anchor liveness/identity** ([Ariakit][ariakit] refuses to reassign an anchor whose
current one is still `isConnected`; Blink's `implicit_anchor_` is a `WeakMember`; Uno
holds `FlyoutBase.Target` as a managed weak reference).

**In cells.** The reduction is where element identity stops, and on a per-frame rebuild
the handle buys nothing at all: `view→layout` re-derives the rect every tick, so a value
is fresh by construction. `sparkles:ui` already ships the producers — `keyedRects`
(key → unclipped rect, paint order, `libs/ui/src/sparkles/ui/state.d:504`), `keyTargets`
(key → clipped rect, `:104`), `selectionRects` (byte range → per-row rects, `:415`),
`hoverTargets` (clipped hit list, `:64`) and `elementKeys` (liveness, `:1708`).

### Anchor rect {#anchor-rect}

The **anchor rect** is that reduced value: an axis-aligned rect in one named coordinate
space, from which a placement picks a corner, an edge midpoint, or the centre. A point
anchor is a degenerate anchor rect.

**In cells, a point anchor is 1×1, not 0×0.** [Avalonia][avalonia] already writes the
convention: `PlacementMode.Pointer` becomes
[`new Rect(position, new Size(1, 1))`][avalonia-pointer-anchor] with `Anchor = TopLeft`
and `Gravity = BottomRight`. Zero-size anchors are legal in Wayland (added so a client
can "map a popup against a coordinate, not a pixel") and are what Radix, React Aria, Zag
and Base UI pass as zero-size `DOMRect`s — but where arrow geometry participates in a
cross-axis clamp, a small anchor can invert the clamp interval. React Aria's
`calculatePosition.ts:298-303` inverts when
`2*(arrowSize + arrowBoundaryOffset) > anchorCrossSize + overlayCrossSize`, and its
`clamp` then silently returns `max` rather than erroring — so a cell port must assert
`min <= max` rather than rely on the clamp.

One more cell-specific consequence: ImGui nudges a tooltip off the cursor by `+1.0f`
pixel, which at cell granularity is a whole visible cell of drift and must be replaced by
an explicit [avoid rect](#avoid-rect).

### Virtual anchor {#virtual-anchor}

A **virtual anchor** is an anchor with no widget behind it — a cursor position, a
synthesized rect, a caller-computed region. [Floating UI][floating-ui] names it and gives
it the field's most general shape: `VirtualElement = {getBoundingClientRect;
getClientRects?; contextElement?}` (`packages/utils/src/index.ts:28`), where
`contextElement` exists _only_ so clipping-ancestor discovery has a node to walk from —
the geometry comes from the callback. `ReferenceElement = any`
(`packages/core/src/types.ts:164`), so the engine is anchor-agnostic by construction.

The decisive datapoint for a canvas toolkit is that Floating UI's own website instantiates
its platform for a `<canvas>` with [`getElementRects: (data) => data`][fui-canvas] — the
identity function. The library already runs in the configuration a canvas toolkit is in,
where the anchor _is_ a value and there is no DOM to interrogate.

[Angular CDK][angular-cdk] spells the same union out instead of hiding it behind a
callable: `ElementRef | Element | (Point & {width?, height?})`, normalised by
[`_getOriginRect()`][cdk-origin-rect] at every `apply()`, with a bare point becoming a
0×0 rect.

**In cells.** The closure is a DOM concession, not a design commitment —
[Tippy][tippy]'s own analysis calls it "pure DOM-retained-mode tax". What ports is the
_shape_: one seam, one rect out. Floating UI's 264-line `autoUpdate`
(`packages/dom/src/autoUpdate.ts:46`) — scroll and resize listeners on every overflow
ancestor, a `ResizeObserver` on both elements, an `IntersectionObserver` move detector and
an optional rAF loop — exists solely because the DOM will not report movement, and has no
counterpart in a frame loop.

### Avoid rect {#avoid-rect}

An **avoid rect** is a second rect passed alongside the anchor that says where the overlay
must _not_ go. It is never derived by the placer.

[Dear ImGui][imgui] has the richest form: `FindBestWindowPosForPopupEx` takes a per-kind
`r_avoid`, and the shapes are surprising — a child menu inside a vertical menu gets an
**infinite vertical band** (`ImRect(parent.x + spacing, -FLT_MAX, parent.right - spacing,
+FLT_MAX)`), a menu-bar child gets an infinite horizontal band, a tooltip gets a synthetic
cursor box, and a plain popup gets a degenerate rect carrying the source comment "Ideally
we'd disable r_avoid here". [WinUI][winui] ships the same concept as public API —
`FlyoutShowOptions.ExclusionRect`, transformed to root and stored beside the point anchor
— which is how a menu flyout anchored at a cursor point still avoids covering its own
anchor row.

**In cells.** Four extra integers, no capability required. Two near-term consumers need
it: a submenu must clear its parent column, and a touch-opened menu must not sit under the
finger (Base UI already inflates touch-point anchors to a 10 px box for exactly this). The
infinite-band form needs an explicit sentinel or an `AvoidKind` discriminator; `FLT_MAX`
has no integer analogue that survives arithmetic.

### Inline / multi-rect anchor {#multi-rect-anchor}

A text range that wraps produces **several** client rects, one per line. A **multi-rect
anchor** keeps them; the alternative — collapsing to the union bounding box — places the
overlay against a rectangle covering text the user never pointed at.

[Floating UI][floating-ui]'s [`inline()`][fui-inline] middleware is the reference: sort
rects by `y`; start a new group whenever `rect.y - prevRect.y > prevRect.height/2`; take
each group's bounding box; then, if exactly two horizontally disjoint groups exist and a
pointer position was supplied, return the group containing the point padded by 2 px
(because "a MouseEvent's client{X,Y} coords can be up to 2 pixels off a ClientRect's
bounds"). [Base UI][base-ui] lifts the two-group restriction and **prefers the captured
`lineIndex` over re-hit-testing**, so a delayed open still uses the line the pointer was
on; [Tippy][tippy] records `cursorRectIndex` at trigger time. The collapse-to-union camp
is [Ariakit][ariakit] ("multi-rect text ranges are NOT supported"), [Compose][compose],
[Avalonia][avalonia] and [Angular CDK][angular-cdk].

**In cells this gets easier, not harder.** The `height/2` grouping tolerance collapses to
exact row equality, and "which row of a wrapped run is the pointer on" is one integer
compare. One wrinkle absent from every web subject: `selectionRects`
(`libs/ui/src/sparkles/ui/state.d:415`) emits one rect **per span segment per row**, so
several rects can share a row and grouping must union by `y` before selecting.

> [!NOTE]
> The in-repo instance is latent, not live. `apps/hue`'s two TUI call sites keep only
> `rs[0]`, discarding the per-row rects the producer already emits — but a hover anchor is
> a single space-free identifier and the wrap engine never splits a word, so today the
> extra rects are same-row span segments and `rs[0]` is the correct leftmost anchor. The
> multi-rect anchor becomes load-bearing only for a text-range anchor that can span a wrap
> point (a twoslash query or error range, a selection, a prose run).

### Trigger vs anchor {#trigger-vs-anchor}

The **trigger** is what _opens_ the overlay; the **anchor** is what it is _positioned
against_. They coincide by default and must be separable.

[Floating UI][floating-ui] separates them explicitly: `elements.domReference` (the element
carrying the event handlers) is distinct from `elements.reference` (the geometry source),
and `setPositionReference` swaps the latter without touching the former. A menu opened
from a toolbar button but positioned against the toolbar; a hover card triggered by an
avatar but anchored to the row; a context menu triggered by a right-click but anchored at
the click point — all are one trigger, another anchor.

The distinction also decides **focus parenting**: the HTML popover model makes a showing
popover's focus-scope parent its **trigger**, not its DOM parent, so keyboard traversal
follows the causal relation rather than the geometric one (see [focus scope](#focus-scope)).

**Failure mode with a name.** When many triggers share one overlay, the anchor can be
stolen or lost on rebuild. [Base UI][base-ui]'s `PopupTriggerMap` (id → element) plus
`useImplicitActiveTrigger` claims the single trigger when exactly one is registered,
re-associates by identity when the id changed, and **defers close by a microtask** so a
same-tick replacement can register. That second guard is the one an immediate-mode toolkit
needs most: when the tree is rebuilt every frame, "the owning trigger vanished" is the
normal case, and without the deferral every rebuild closes every overlay.

**In cells.** `Widget.key` (`libs/ui/src/sparkles/ui/widget.d:109`) is already a name and
`keyedRects`/`keyTargets` are already the lookup — but `key` also addresses the per-element
state store (`ElementStore.require`, `state.d:1659`), which is a plain linear key match.
Making `key` double as the anchor name **would** reproduce CSS's documented
last-match-wins collision _if_ the resolver adopts `keyAt`'s later-in-paint-order-wins rule
(`state.d:134`); `keyedRects`/`keyTargets` return _all_ matches, so a resolver could
instead prefer the nearest ancestor or report ambiguity. The state-store aliasing exists
today regardless of what the anchor model does.

### Reactive vs latched anchor tracking {#anchor-tracking}

**Latched**: the anchor rect is captured once at open and frozen. **Reactive** (live): it
is re-resolved every frame. [GPUI][gpui] is the only subject that makes this a field of the
anchor value rather than a mode of the placer:
[`MenuPosition = PinnedToScreen(Point) | PinnedToEditor { source: Anchor, offset }`][gpui-menu-position]
— the first survives scrolling and never disappears, the second follows the text and
disappears when the row scrolls out.

Others reach the same split elsewhere. [WPF][wpf] computes `_positionInfo.MouseRect` once
per open, with the reason in the source: if the popup's content size is animated the popup
keeps repositioning, and it should not pick up a new mouse position each time.
[ImGui][imgui] latches `OpenPopupPos`/`OpenMousePos` in `OpenPopupEx` and never updates
them. [Neovim][neovim-floats] latches at the _configuration_ layer: `win_config_float`
rewrites `relative=cursor|mouse` into `relative=win` plus a frozen offset, so cursor and
mouse anchors are sugar over a snapshot while `laststatus`/`tabline` stay live.

Verification narrowed this from a rule to a **default**. Latch-at-open is the correct
default for a pointer-derived point anchor — WPF, ImGui and Neovim converge on it — but
live is legitimate and shipped: [Helix][helix] re-reads `editor.cursor()` every frame for a
resizable popup, latching only while the row is unchanged, and Tippy's `followCursor` is a
live point anchor by design. Conversely a _widget_ anchor is not obliged to be live:
Compose's `MaintainWindowPositionPopupPositionProvider` deliberately ignores
`anchorBounds` changes so a scrolling anchor does not drag the text context menu along.

**In cells.** A latched anchor is a stored `Rect` in the overlay's state; a live anchor is
a stored key re-resolved against this frame's `keyedRects`. Both flow through the same
placement call, so ImGui's asymmetry becomes a data choice per overlay rather than two
branches. On the TUI the latch instant must be the **press**, because
[`INP16`](../../specs/ui/input.md) declares key release absent by default — note this
constrains _keyboard_ press-and-hold only; pointer release is a distinct capability the
terminal serves over SGR-1006.

### Anchor-hidden and escaped {#anchor-hidden}

Two different questions, and [Floating UI][floating-ui]'s `hide()` middleware is the
subject that separates them by name:

- **`referenceHidden`** — the _anchor_ has left its own clipping context. The overlay is
  now attached to something invisible.
- **`escaped`** — the _overlay_ has left the scroll container its anchor lives in
  (computed with the `altBoundary` trick).

Floating UI reports both as **data** and lets the application decide; Tippy re-projects
them as `data-reference-hidden` / `data-escaped` and likewise never auto-hides. CSS takes
the opposite default: `position-visibility: anchors-visible` is the _initial_ value, so
hiding is automatic (`css-anchor-position-1/Overview.bs:2262-2284` states the hide-vs-fit
split). Blink implements it by making the paint layer invisible rather than destroying the
popup, so its state and focus survive.

**In cells this is nearly free, and the in-repo asymmetry is the thing to fix.**
`hoverTargets` (`state.d:64`) and `keyTargets` (`:104`) apply the clip stack;
`keyedRects` (`:504`) and `selectionRects` (`:415`) do not — so an anchor resolved through
either of the latter two yields a **full rect for a widget scrolled out of its viewport**.
A clipped keyed producer already exists (`keyTargets`); what is genuinely missing is a
clipped `selectionRects` and an explicit hidden/clipped **flag**, because `keyTargets`
returns only the visible intersection and drops fully-clipped entries, so it cannot
distinguish "scrolled out" from "absent".

---

## 2. Placement {#placement-group}

### Placement {#placement}

A **placement** is both the request ("bottom-start, 1 cell of gap") and the result (the
resolved rect, the resolved side, the arrow's cell). Keeping the two in **different
fields** is a rule the field states in its own words: Neovim's `WinConfig` comment
(`src/nvim/buffer_defs.h:1210-1214`) says so verbatim, and its `previewpopup` path
demonstrates the cost of violating it — `w_wantline`/`w_wantcol` had to be added once
`WinConfig.row`/`col` became the _placed_ result. [tmux][tmux-popup] keeps `current` vs
`preferred` in `popup.c:53-58`; [GTK4][gtk4] keeps the `GdkPopupLayout` request separate
from `final_rect`/`flipped_*`.

Of the surveyed subjects, six distinct placement algorithms exist, and every one that
ships a real solver ships it as **library code over plain rects**: GTK4's
`gdk_surface_layout_popup_helper` (~110 lines, all `int`), ImGui's
`FindBestWindowPosForPopupEx` (add/sub/min/max only), Angular CDK's four-tier cascade,
Compose's `IntOffset` providers, Helix's 60-line `render_info`. Only Wayland puts it in
another process, and it does so with a ~40-byte POD of plain integers.

**In cells.** The arithmetic is unchanged; the one thing that must be written down is a
**rounding rule for centring**. Every centred placement divides by two, and the field
splits: GTK4's `(1 + sign) * size / 2` truncates and therefore biases toward the low edge;
Avalonia, Uno and WPF use doubles and absorb the half unit, which in cells becomes a
one-cell jitter as the anchor grows or shrinks by one. GTK4's low-edge truncation is the
right default because it is what a cell grid wants anyway — but it must be stated once and
pinned by a test rather than emerging from a cast.

### Side {#side}

The **side** is which face of the anchor the overlay sits on: `top`, `right`, `bottom`,
`left`. It is the primary output of a placement, not just its input.

[Radix][radix] and Floating UI name it best because they _publish_ it: the resolved
placement is reported back and everything downstream — the arrow's side, the
[transform origin](#transform-origin), the `data-side` attribute — reads it. GTK4 achieves
the same by mirroring the two gravities for each axis that flipped and storing them on the
surface, so the resolved anchor/gravity pair **is** the output. Angular CDK emits the
chosen `ConnectedPosition` on `positionChanges`.

The discard camp pays for it: ImGui computes `AutoPosLastDirection` and never reads it;
[Helix][helix]'s `Completion::render` reconstructs the side by comparing y-coordinates;
Compose's `calculatePosition` returns a bare `IntOffset` and material3 recovers the side
four different ways; `xdg_popup.configure` is rect-only, and the very next positioner
designed in that tree fixes it.

**In cells the side is not cosmetic.** On a pixel surface the side selects a CSS transform
and an arrow rotation; on a cell grid it selects the **border cap glyph, the arrow
character and the connector elbow** at paint time, and on the static-HTML target it does so
at emit time with no later measurement pass available. `sparkles:ui` emits no resolved side
anywhere in the widget model, the display list or `Visual`, and consequently **all four
canvases hard-code the popup arrow to the top edge** (`grid_canvas.d:371-372`,
`cells.d:346-347`, `interp/html.d:227`+`:250`, `raylib_canvas.d:329-347`).

### Alignment {#alignment}

Given a side, the **alignment** is where along that side the overlay sits: `start`,
`center`, `end`. Side + alignment is Floating UI's `Placement` (`bottom-start`,
`right-end`, …) and Radix's `data-side` + `data-align` pair.

The vocabulary matters because it decides what a [fallback list](#fallback-list) can
express. Floating UI's generated list is
`[oppositeAlignment(p), opposite(p), oppositeAlignment(opposite(p))]` — try the other
alignment on the _same_ side before crossing to the other side. A per-axis policy cannot
say that; an ordered candidate list can.

**In cells.** Alignment is where the centring rounding rule bites (see
[placement](#placement)), and where an odd/even extent decision must be documented rather
than inherited from integer division.

### Gravity {#gravity}

**Gravity** is the direction the overlay grows from its anchor point — equivalently, which
of the overlay's _own_ corners is placed at the anchor point. [`xdg_positioner`][xdg-positioner]
and [GTK4][gtk4] use an explicit `(anchor, gravity)` pair; Avalonia's 14-case
`PlacementMode` switch lowers each mode to exactly one such pair.

The pair is more primitive than side+align: `unconstrained(P) = anchorPoint(rect, anchor) +
offset - gravityShift(size, gravity)`. Its virtue is that [flip](#flip) is expressible as
"mirror the anchor edge **and** the gravity together", which is correct for a non-zero-size
anchor — see the failure mode under [flip](#flip).

Avalonia makes illegal states unrepresentable at the boundary: `ValidateEdge` throws on an
anchor containing both `Left` and `Right`. Wayland reached the same place by replacing
bitfields with enums.

### Fallback list {#fallback-list}

An ordered list of alternative placements, tried in order until one passes a fit
predicate. [Floating UI][floating-ui]'s `fallbackPlacements`
(`packages/core/src/middleware/flip.ts:99`) is the canonical name; CSS spells it
`position-try-fallbacks`; [WinUI][winui] hardcodes four- and five-entry
[`placementOrder` tables][winui-placement-order] per major side, flip-first-then-perpendicular,
with justification re-applied per candidate so a top-left-aligned flyout that flips to
bottom stays left-aligned; blink.cmp's `direction_priority` is a **pair** of lists keyed by
the parent's resolved side, and may be a function.

[Base UI][base-ui] turns the choice into two named presets, which is the cheapest real
distinction in the field: `DROPDOWN_COLLISION_AVOIDANCE = {fallbackAxisSide: 'none'}` for
surfaces that cap their height with an available-extent variable and must **never** fall
onto the perpendicular axis, versus `POPUP_COLLISION_AVOIDANCE = {fallbackAxisSide: 'end'}`
for tooltips, popovers and submenus.

CSS is the one substrate where candidates are expensive — each is a real layout pass — which
is why it caps the candidate list (implementation-defined, "must be at least five") and
skips the **incumbent** option so a stable choice never re-costs.

**In cells a candidate is arithmetic, not a layout pass**, so CSS's cap has no reason to
exist — with one exception: if a candidate changes the available extent and therefore the
content's measured size, the cost model of CSS returns along with the risk of a
[measure↔place cycle](#resize).

### Auto placement {#auto-placement}

**Auto placement** picks the side from free space with no author preference at all —
Floating UI's `autoPlacement()`, [floating-vue][floating-vue]'s `placement: 'auto'`, CSS's
`position-try-order`. It is distinct from a [fallback list](#fallback-list), which honours
an author order and only departs from it under collision.

A whole family of subjects does auto placement without naming it — the free-space
heuristic: one boolean decides the side from room alone, then the content is measured
against that side's budget. [Flutter][flutter]'s
[`positionDependentBox`][flutter-position-dependent] is the compact form
(`fitsAbove == fitsBelow ? preferBelow : fitsBelow`, then clamp, then centre the cross axis
with a dead-centre fallback when the flexible space is smaller than twice the margin);
Neovim's LSP path is a majority vote with an `anchor_bias` of auto/above/below;
[Helix][helix] tests a six-row constant rather than the measured height, because
measurement happens _after_ the side is chosen.

That last point is the structural lesson and it survives to a cell grid unchanged:
**the side determines the size budget handed to layout**, so it must be chosen using a
size _bound_ rather than a measured size. [GPUI][gpui] states the same rule for a different
reason — its editor decides the side using **max** sizes explicitly "for stability", so the
popover does not flip-flop as content shrinks.

**In cells.** `effectivePopupWidth(pal, available)`
(`libs/twoslash/src/sparkles/twoslash/render_widgets.d:413`) is already exactly this
pre-layout budget step; what it lacks is the side.

---

## 3. Constraint adjustment {#constraint-adjustment}

**Constraint adjustment** is [`xdg_positioner`][xdg-positioner]'s name for the whole repair
family — what to do when the unconstrained placement does not fit — and the catalog adopts
it as the umbrella term. Wayland states the members and their
[precedence normatively][xdg-constraint]: "The adjustments can be combined, according to a
defined precedence: 1) Flip, 2) Slide, 3) Resize." GTK4 repeats the ordering in its own
header: "flipping should take precedence over sliding, which should take precedence over
resizing."

The catalog splits Wayland's `slide` into [shift](#shift) and [push](#push) (see
[canonical spellings](#canonical-spellings)) and keeps the rest.

### Flip {#flip}

**Flip** mirrors the overlay to the opposite side of the anchor. Two things vary across the
field and they are not interchangeable: **what it mirrors about**, and **when the mirror is
accepted**.

| Mirror reference                              | Subjects                                                  | Correct for                         |
| --------------------------------------------- | --------------------------------------------------------- | ----------------------------------- |
| the **anchor rect** (edge + gravity together) | [xdg][xdg-positioner], [GTK4][gtk4], [Avalonia][avalonia] | any anchor, including sized ones    |
| the anchor **centre**                         | Flutter Cupertino                                         | any anchor                          |
| the placed region's **own origin**            | [Textual][textual] `inflect`                              | zero-size anchors only              |
| a point                                       | [GPUI][gpui] `from_anchor_and_size`                       | zero-size anchors only              |
| the **parent item's** box                     | Qt Quick                                                  | the anchor's parent, not the anchor |
| the opposite **anchor edge**                  | Flutter Material                                          | any anchor                          |

Acceptance rules diverge just as widely: Wayland **reverts unless the flip is fully
unconstrained**; GTK4 accepts whenever the flipped position's overflow "badness" is not
strictly worse (total and monotone — it can never return a worse position); GPUI accepts
only if the flipped rect fully fits on that axis; Qt Quick accepts only if the flipped
rect's intersection with the bounds is wider or taller.

That divergence is observable inside one toolkit. GTK4 solves the same positioner value
in-process for its non-Wayland backends (win32, macOS, X11, Android, Broadway) with a
**different acceptance rule than the compositor applies on Wayland**, and the subsequent
[shift](#shift) pins the two results to opposite edges — so a future native-windowing
backend delegating to a real `xdg_popup` will not necessarily reproduce an in-surface
placement.

**In cells.** Flip is integer-exact everywhere and needs no adaptation — but the mirror
reference does. Reflecting about a point is correct only for a zero-size anchor, and both
in-canvas cell subjects that do it (Textual, GPUI) have zero-size anchors by construction:
Textual's tooltip anchor is `self.app.mouse_position`, a bare cell pair. A toolkit whose
anchors are widget rects must use the anchor-edge × gravity mirroring.

GTK4 carries one detail worth copying verbatim: it **negates the offset** on the flipped
branch, so a gutter below the anchor becomes a gutter above it. Avalonia's RTL mirror gets
this wrong (it swaps the anchor and gravity but not the offset).

### Shift {#shift}

**Shift** slides the overlay along the **edge axis** — the axis parallel to the anchored
side — so it stays inside the [boundary](#boundary), without changing which side it is on.

[Textual][textual]'s [`translate_inside`][textual-translate-inside] is the clearest
expression in the corpus, and its shape is the thing to copy:
`max(min(x2, x1 + width1 - width2), x1)` — the container's **origin** appears in both
terms, so it cannot be dropped. That matters more than it looks: writing the clamp against
the boundary's _extent_ instead of its _far edge_ is silent whenever the boundary starts at
zero (which is every test) and wrong the moment a safe-area inset, a keyboard inset or a
pane origin makes it non-zero. Avalonia ships exactly that bug — `ResizeX` computes
`bounds.Width - t.X` where `ResizeY` correctly computes `bounds.Bottom - t.Y`.

**Flip on the side axis, shift on the edge axis** is the pairing GTK4 states four times in
`gtkpopover.c` and never violates (`FLIP_X|SLIDE_Y` for left/right, `FLIP_Y|SLIDE_X` for
top/bottom). A toolkit that _shifts on the side axis instead of flipping_ either detaches
the overlay from its anchor or covers it — [Slint][slint]'s `place_popup` has no flip at
all, so a bottom-anchored menu near the window's bottom edge slides up over its own anchor;
Textual's `Select` declares `constrain: none inside` and does the same.

Every surveyed subject that permits **cross-axis** shift makes it opt-in (Ariakit's
`overlap` defaults false; Radix configures `shift({mainAxis: true, crossAxis: false})`;
[Apple][apple]'s `canOverlapSourceViewRect` defaults false). Deliberate side-axis overlap is
nonetheless a shipped policy for menu **cascades** — ImGui overlaps a submenu onto its
parent by `ItemInnerSpacing.x` "to convey the relative depth of each menu", and Turbo
Vision's diagonal submenu does likewise — so the pairing is a rule for anchor-attached
overlays, not a law about all menus.

**When the overlay is larger than the boundary on an axis, pin the start edge and let the
end overflow.** This is the majority rule among the shift-style implementations, reached by
three different routes: Textual's nested `min`/`max`, React Aria's
`Math.max(endCorrection, startCorrection)`, and GPUI's clamp ordered right-then-left with
the comment "aligning to the left if it is wider than the limits" — and it is what
`clampOrigin` already does. It is a **choice, not a consensus**: Avalonia pins the end edge
and Compose centres an over-large overlay. None of the three start-pinning implementations
handles RTL, where "start" is the right edge.

**In cells.** `clampOrigin` (`render_widgets.d:430`) is already a one-axis, one-direction
shift against a scalar extent — and it floors at `0`, which is wrong for a boundary whose
origin is not the surface origin.

### Push {#push}

**Push** is the last-resort clamp on the **side** axis, applied _after_ a flip has been
attempted and failed. [Angular CDK][angular-cdk] is the subject that names it separately —
`_pushOverlayOnScreen`, per axis, `overflowLeading || -overflowTrailing` (fix the leading
overflow if there is one, otherwise pull back from the trailing one, never both).

Verification made this its own term. Side-axis clamping as a substitute for flipping is a
defect; side-axis clamping **after** a flip is the standard terminal step: CDK's
`_canPush = true` by default and its push adjusts the side axis too, and GPUI clamps the
vertical axis unconditionally for every fit mode. Neither is documented as a bug.

**In cells.** Push is where "nothing fits anywhere in a 24-row terminal" has to resolve to
_something_. A single-surface toolkit cannot do what Compose does for tooltips (pass
`clippingEnabled = false` and let the window hang off the screen) or what nui, notcurses and
[APG][aria-apg] do (punt to a host that clips) — it **is** the host. So push must always produce a
least-bad answer, and that answer must be a value the recording canvas can assert.

### Resize {#resize}

**Resize** shrinks the overlay to the room actually available. Wayland fires it only "if
all other adjustments requested didn't manage to make the popup rectangle fully visible",
and documents its purpose as feedback: "to get feedback of available space where a client
can create its popup".

There are two genuinely different placements of the idea:

1. **The placer shrinks.** [WinUI][winui]'s `ResizeToFit` picks the side with more space,
   shrinks the presenter but never below its minimum, clamps, repositions, clamps again.
   Qt Quick shrinks **and restores** the implicit size once it fits again.
2. **The placer publishes the extent and the content decides.** Floating UI's `size()`
   middleware, re-exported by Radix as `--radix-popper-available-width/height` and by
   Ariakit (floored) as `--popover-available-width`.

The third and safest variant is [WPF][wpf]'s: the max-size clamp runs at **measure** time
and its `limitSize` is derived from the anchor and the screen **alone**, never from the
measured content — "restricted in the orthogonal dimension to the primary/nudge axis …
prevents the popup from overlapping the placement target". That formulation provably cannot
create the **measure↔place cycle** (placement changes the available extent → the content
re-measures → the new size changes the placement) that four subjects shipped a bug for and
all four fixed with an ad-hoc guard: Floating UI unobserves the floating element and
re-observes on the next frame ("Prevent update loops when using the size middleware"),
Tippy added a `triedPlacements` visited set in a commit literally titled
"fix(inlinePositioning): infinite loop", Uno added a two-pass arrange workaround, WinUI
guarded `OnPresenterSizeChanged` with a flag. CSS resolves it by fiat: "Layout does not go
backward, in other words."

**In cells the repo has already argued the policy in the opposite direction**, and the
argument is worth carrying into the spec verbatim: `clampOrigin`'s doc comment says a popup
narrowed to fit under a token near the right edge "would wrap its signature into a column
two words wide, which reads worse than the same popup slid left". Shift first, publish the
available extent as an output, and keep the anchor+boundary-derived max clamp in the layout
constraint — which is what `effectivePopupWidth` already is.

---

## 4. Boundaries and insets {#boundary-group}

### Boundary {#boundary}

The **boundary** is the rect the overlay must stay inside. The architectural rule the
survey supports is that **the boundary is a parameter of the placement call, resolved by
the adapter and never queried by the solver** — [Avalonia][avalonia] states it by
construction (the adapter deflates the reported screen rect; the positioner never learns
about insets), and GTK4 on Android, Flutter's inherited media data, Helix's `viewport: Rect`
and tmux's status-line offset are the same discipline.

Receipt alone is **not** sufficiency, and it is worth saying so because the tempting
shorthand ("receives it → works, discovers it → broken") is false. [Compose][compose]
receives its window size as a solver parameter and is still wrong on the soft keyboard, on
two separate counts filed as bugs: the adapter's value omits the insets, and nothing re-runs
placement when the keyboard appears. The correct statement is that discovery inside the
solver makes the failure unfixable from outside, while receipt only makes it fixable.

[Avalonia][avalonia] states the discipline architecturally, and it is why one engine serves
both a 4K monitor and an in-window canvas: the placement engine talks to a **four-member**
adapter (`Screens`, `ParentClientAreaScreenGeometry`, `Scaling`, `MoveAndResize`), and the
in-canvas implementation reports a single synthetic screen equal to
[the overlay layer deflated by the safe-area padding][avalonia-overlay-host], with
`Scaling => 1`. The engine cannot tell the two apart.

**In cells.** The boundary is the concept `sparkles:ui` most obviously lacks: its three
existing placement call sites pass three different ones, and two of them do not clip to
what they placed against — `apps/hue/src/gui.d:2897` uses an anchor-relative pixel edge and
does not clip; `apps/hue/src/tui.d:654` uses the pane width and clips;
`apps/hue/src/twoslash_tui.d:266` uses the whole terminal grid and does not clip.
Consequently the third can place a popup across a pane divider that the second would have
clamped.

### Clipping boundary / clipping ancestor {#clipping-boundary}

A **clipping ancestor** is a container between the anchor and the root that clips its
content — a scroll pane, an `overflow: hidden` box, a dock pane. The **clipping boundary**
is the intersection of them all.

Two _roles_ hide under one word, and Radix and Blink both resolved this by splitting them
rather than by picking a side:

- **fit boundary** — what placement, clipping and hit-target derivation are computed
  against. Radix keeps the viewport default here deliberately, "to avoid clamping content
  rendered inside transformed or overflow-clipping portal containers"; Blink uses the
  inset-modified containing block.
- **anchor clip** — used _only_ for the [anchor-hidden](#anchor-hidden) verdict. Radix
  passes `boundary: undefined` to `hide()` so detach detection falls back to clipping
  ancestors, and both halves are pinned by end-to-end tests; Blink uses
  `IntersectionObserver`'s clip set for `position-visibility`.

For a single-surface toolkit the settled default among the in-canvas subjects is **the
surface, not the anchor's clipping ancestor** — GPUI clamps to `window.viewport_size()`
with exactly one masked exception in all of Zed; Flutter clips to the theatre's own rect and
the overlay escapes every clip below it; Textual always passes `size.region`, the screen;
Neovim clamps a float to `Columns`/`Rows` rather than to its anchor window
(`src/nvim/window.c:948-952`); Angular CDK collects scrollable ancestors that never
influence placement at all — they feed four report-only booleans. This is explicitly _not_
the DOM default: Floating UI defaults to `clippingAncestors`.

**In cells this is free**, and the invariant is the interesting part: **the same boundary
value must govern placement, the overlay's clip, and the derivation of its hit targets.**
`sparkles:ui` already computes the clipping-ancestor chain — `childClipOf`
(`libs/ui/src/sparkles/ui/layout.d:560`) has collapsed it to one `Rect` before placement
could run — so `getClippingRect`-style discovery must **not** be ported. [GPUI][gpui]
supplies the counter-discipline to copy: its deferred prepaint runs with the mask stack
empty so `content_mask()` returns the viewport, `insert_hitbox` captures the ambient mask at
insert time, and `hit_test` intersects `bounds ∩ mask`. Without that, an overlay declared
inside a scroll pane is painted but not clickable at exactly the edges where it escapes.

### Viewport padding {#viewport-padding}

**Viewport padding** is the margin kept between the overlay and the boundary's edges. It is
a placement input, not a style.

Two spellings exist and they are **alternatives, not a right and a wrong answer**. The
web positioners carry a per-side padding object — [Tippy][tippy]'s
`{top: 2, bottom: 2, left: 5, right: 5}` is the precedent, and Angular CDK, Floating UI,
Radix, Base UI, Zag and Ariakit all follow — because their boundary is a viewport they
cannot deflate. [Headless UI][headlessui]'s uniform scalar is the minimal form. A scalar
padding **plus a per-side-deflatable [boundary](#boundary)** is expressively equivalent for
the asymmetric cases, and is how GTK4 on Android, [tmux][tmux-popup], [Helix][helix] and
[Textual][textual] actually handle them.

**In cells.** `Insets` in CSS order already exists
(`libs/ui/src/sparkles/ui/geometry.d:119-147`), so whichever spelling is chosen costs no new
type — and the asymmetric case is not hypothetical: the Android soft keyboard and the
terminal status line are both bottom-only. What must **not** happen is a scalar that is the
only lever, with no way to deflate the boundary per side.

### Safe-area inset {#safe-area-inset}

A **safe-area inset** is the part of the surface the platform has taken: a display cutout, a
rounded corner, a system bar, or the soft keyboard. It must be **folded into the boundary
before placement**, not discovered by the solver.

The disciplined implementations pass it. [WinUI][winui] intersects the input-pane occlude
rect into the container rect in `CalculateAvailableWindowRect` and re-runs placement on
`NotifyInputPaneStateChange`; GTK4 on Android subtracts `systemBars | displayCutout | ime`
from the measured toplevel so the popup's constraint box shrinks **by construction**;
Flutter passes it in inherited data
(`padding.deflateRect(viewInsets.deflateRect(overlayRect))`); Avalonia deflates the reported
screen rect in the _adapter_, so its positioner never learns about insets at all.

Two mature toolkits model the inset and then keep it out of popup placement anyway, which is
the instructive middle case: [Slint][slint] computes `safe_area_inset()` and applies it to
the window item but hands `place_popup` a clip region of `(0, 0, windowSize)`; [ImGui][imgui]
documents `WorkInsetMin`/`WorkInsetMax` as exactly iOS `safeAreaInsets` and Android
`DisplayCutout`, but `GetPopupAllowedExtentRect` deliberately uses the **main** rect rather
than the **work** rect, because "popups are ALLOWED to overlap the non work-area".

**In cells.** The soft keyboard is the sharpest case and the one the Android target has
today: it steals the bottom of the screen, and no in-repo call site accepts it. It enters as
`Insets` on the boundary derivation, exactly as Avalonia's overlay host does.

### Work area {#work-area}

The **work area** is the surface minus reserved chrome — a taskbar on a desktop, a status
line in a terminal, the command line in an editor. It is the distinction between "the
surface" and "the part of the surface an overlay may use", and the field's answer is that it
is chosen **per overlay**, not globally.

[Avalonia][avalonia]'s `ManagedPopupPositionerScreenInfo(Bounds, WorkingArea)` carries both.
[ImGui][imgui] states the per-overlay choice outright: `GetPopupAllowedExtentRect` uses
`GetMainRect`, not `GetWorkRect`, because popups may overlap the non-work area.
[tmux][tmux-popup] passes its status-line offset in (`status_at_line`, `popup_status_line_y`)
rather than discovering it, and [Emacs posframe][emacs-posframe] takes `:mode-line-height`
and `:minibuffer-height` as plist arguments for the same reason. [Neovim][neovim-floats] decides per overlay **by z-index**:
`above_ch = p_ch` for a float below the messages band, while a float at or above it may
cover the command line.

**In cells.** Multi-monitor work-area selection collapses to nothing — but the
surface-vs-work-area distinction does not, and it is precisely what the three in-repo call
sites disagree about (an anchor-relative pixel edge, the pane, the whole terminal). It must
become a declared value per overlay.

---

## 5. Layering {#layering-group}

### Top layer {#top-layer}

The **top layer** is a plane painted after everything else, clipped by nothing below it.
[CSS `position-4`][css-position-4] and the [HTML Popover API][popover-api] give it its name
and its most precise definition: an **ordered set** of elements painted as siblings of the
root, in set order, with re-showing an already-present element implemented as
remove-then-append — so "bring to front" and "reopen" are the same operation.

Subjects with an OS surface delegate stacking to the window manager and keep only a parent
pointer. Subjects without one — Textual, Turbo Vision, Notcurses, Neovim's `ui_compositor`,
tmux, Helix, [Ratatui][ratatui], ImGui, GPUI, Flutter, Slint, Uno, Avalonia's overlay arm, and every
web headless library — converge on the same three-part shape: a flat ordered list whose
paint order is list order; a parent index per record used only by dismissal, hover
inhibition and focus (never by paint); and a small ladder of **named bands** so a tooltip or
a toast cannot be dragged into a menu's dismissal stack.

**In cells a top layer is three resets and no backend capability**: an **order** reset
(emit last), a **clip** reset (to the overlay's own boundary rather than its declaration
site's), and an **extent** reset (exclude the overlay from its host container's
content-extent computation, or opening a dropdown inside a scroll view grows the scroll
extent and materialises scrollbars). Textual's `((1, 0, 0))` order key, `no_clip`, and
exclusion from `total_region` are literally those three.

The static-HTML target is the exception: `libs/ui/src/sparkles/ui/interp/html.d` walks the
**widget tree**, not the display list, emitting nested boxes with clipping written from node
structure, so it cannot hoist a subtree out of its declaration site the way the cell and
GPU backends can.

> [!WARNING]
> `sparkles:ui` reserves the rung and leaves it empty. [`DCK13`](../../specs/ui/containers.md)
> fixes routing precedence as capture → gesture owner → **top layers (tested front-to-back)**
> → the positional query, and `DockContainer.handle` implements every rung but that one.
> Appending overlay targets last already yields topmost-wins **within one tree's target
> list** (`keyAt` keeps the last hit, `state.d:134`) — but `DockContainer` resolves the pane
> **by rect first**, so an overlay that geometrically escapes its pane is routed to the
> neighbouring pane and never reaches its own target list. The rung is required, exactly as
> specified, in addition to the non-positional decisions it also serves.

### Portal {#portal}

A **portal** is the DOM-specific act of rendering an overlay's subtree into a different
parent node (typically `document.body`) so it escapes ancestor clipping, transforms and
stacking contexts. React portals, Angular CDK's `.cdk-overlay-container`, and Tippy's
append-to-`document.body` are the same mechanism.

It is worth defining precisely because **it does not exist here**, and the absence should be
stated rather than silently assumed. A portal is a reparenting operation in a retained tree;
a display list has no parents to re-point. What a portal _achieves_ — order, clip and extent
escape — is the [top layer](#top-layer)'s three resets, and those are what port.

The one thing a portal costs its users is worth recording as a hazard avoided: every web
subject that portals had to re-import focus and dismissal relationships it had just
destroyed. Floating UI adds four focus sentinels around the portal; React Aria walks the
tree to hide everything outside with a refcount; Ariakit needed three registries and Radix
two (with two filed issues) to rebuild the parent relation the portal removed.

### Overlay stack vs overlay tree {#overlay-stack-vs-tree}

An **overlay stack** is the flat ordered list of open overlays. An **overlay tree** is the
parent relation among them (this submenu belongs to that menu; that popover was opened from
this one). The distinction matters because the two are used for different things and only
one of them needs to be stored.

The HTML spec is the clearest statement in the corpus: it stores only the ordered set and
**recomputes** `topmost popover ancestor` per operation, requiring the parent to be
[strictly earlier in the list][html-topmost] — which is what "allows for the construction of
a well-formed tree from the (possibly cyclic) graph of connections". Cascading dismissal is
then a **slice**, never a tree walk: `hide popover stack until` computes
`indexOf(endpoint) + 1`, hides the tail in reverse, and then **re-checks the whole list**,
because a `beforetoggle` handler may have shown something during the hide. ImGui's
`ClosePopupToLevel(remaining)` is literally `OpenPopupStack.resize(remaining)`; React Aria's
submenu close is `stack.slice(0, level)`.

Where a system omitted the parent link it grew registries instead (Ariakit needed three,
Radix two, Zag makes the application wire `setParent`/`setChild`). Where a system let the
ownership tree drive **paint** order it got bugs: GPUI's paint pass sorts _all_ deferred
draws by a flat priority while prepaint sorts only within a round, and nested deferred draws
inherit no priority — so a nested child can paint behind an unrelated higher-priority
sibling and even behind its own parent. **INFERENCE:** the fix is Flutter's two-level order
key (owner entry, then child stamp) rather than GPUI's single integer.

**In cells.** "Later in the display list" already _is_ the ordered set; the only new code is
the derived-ancestor predicate, and it is cheaper here than in the DOM because the widget
tree is right there. A visibility flag consulted during paint is a defect: "not in this
frame's overlay list" should be the only representation of an invisible overlay, because the
paint walk and the hit walk must not be able to disagree.

> [!NOTE]
> One nuance verification insisted on. Hit-list **membership** must follow "is this overlay
> visible", not "is it past its exit animation" — a hover-triggered surface must still
> receive pointer enter/leave while fading out, or re-entering a fading hover card cannot
> cancel the close (Radix keeps the content mounted with live handlers for exactly this).
> Per-query behaviour (dismissal, focus containment, modal blocking) may then filter on
> phase; Blink's `ActiveModalDialog` skips a dialog pending removal while
> `IsPopoverInTopLayer` still returns true for a popover transitioning out.

---

## 6. Triggering and timing {#timing-group}

### Warm-up {#warm-up}

**Warm-up** is the delay between the trigger firing and the overlay appearing — the "don't
show a tooltip just because the pointer crossed the button" delay.

The important structural fact is that a warm-up is **not** the first phase of a fade. It is
a state in which the overlay does not exist: it is not painted, it is not hit-tested, and
cancelling it must produce nothing at all rather than a fade-out from full opacity.

**In cells this is a hard constraint on reuse, not a preference.** `Timeline`
([`STM6`](../../specs/ui/state-machines.md)) cannot host a warm-up on three independent
grounds, all in `libs/ui/src/sparkles/ui/state.d`: (i) `fadeIn` already reports
`visible() == true` (`:1245`), so a "warming" overlay enters the display and hit lists;
(ii) `dismissed()` from `fadeIn` returns a fade-out whenever `fadeOutMs > 0`, and
`alphaPercent` at elapsed 0 is 100, so a cancelled warm-up plays a **full-opacity fade-out**
instead of vanishing; (iii) on the TUI `stepped` is never driven, because `frameSeconds()`
returns a hard-coded literal `0` — so a warm-up spelled as `fadeInMs` would show the overlay
at once and never leave `fadeIn`.

That third point generalises: **any `dt`-accumulating timing machine is dead on the terminal
today**, and a deadline mechanism (`HostState.wakeIn`) is the backend-neutral shape that
does work.

### Cool-down / skip-delay {#cool-down}

Once one overlay has been shown, the **next** one should appear instantly — moving along a
toolbar should not re-pay the [warm-up](#warm-up) for every button. The **cool-down** is the
window after a close during which the system stays "warm"; Radix's `skipDelayDuration` names
the same number from the other side.

Nine independent implementations reached this — WPF's `BetweenShowDelay` (shipped around
2006), Avalonia, WinUI's `BETWEEN_SHOW_DELAY_MS`, Qt's `toolTipFallAsleep`, GTK's
`BROWSE_TIMEOUT`/`BROWSE_DISABLE_TIMEOUT`, React Aria's `globalWarmedUp` +
`TOOLTIP_COOLDOWN`, Radix's `skipDelayDuration`, Ariakit's `skipTimeout`, Base UI's
`FloatingDelayGroup` — and they converge on **shared arbiter state**: one timestamp (or one
boolean plus one deadline) held outside every instance, not per-widget state. ImGui alone
collapses warm-up and cool-down into a single shared float accumulator with a 0.25 s decay
grace, which is the only design in the field authored for an immediate-mode frame loop.

Four second-order rules recur and deserve the same status as the delays: a **third channel**
saying "this transition was instant, do not animate" (exported under five different names);
**rest/stationary** gating; **re-entry during the close delay returns to open free of
charge**; and a **max display duration** the desktop stacks are retreating from for
accessibility reasons (WPF's .NET 6 default is `Int32.MaxValue`).

One rule is worth stating as an invariant because two subjects shipped opposite bugs around
it: **a duration of zero must statically disable the feature, never arm a zero-length
timer.** Radix shipped that bug (issue 3873) and fixed it with early returns in both provider
callbacks, pinned by a regression test. WPF disables structurally instead
(`_quickShow = (betweenShowDelay > 0)`) — its own zero-handling override is a deliberate,
separately-documented policy rather than the mirror bug.

**In cells.** The arbiter is Regular value state — `{activeId, warm, warmUntilMs,
closeAtMs}` — and the id→callback registry every web implementation carries is unnecessary
when the arbiter itself decides who is open. React Aria's constant carries the comment "this
seems to be a 1.5 second delay, check with design": the number is unowned, so port the
machine and not the value.

---

## 7. Pointer intent {#intent-group}

The field puts two different problems under one heading. **Anchor→overlay travel** (tooltip,
hover card, popover) is geometry: the pointer must cross a gap without the surface closing.
**Parent-item→submenu travel** is routing: the pointer crosses the parent menu's _own items_,
each of which wants to steal the highlight and close the submenu. Twelve of the surveyed
subjects implement the first, nine the second, and only three implement both — never with
the same algorithm.

### Safe polygon {#safe-polygon}

A **safe polygon** is a region spanning the anchor and the overlay; while the pointer is
inside it, the overlay does not close. [Floating UI][floating-ui]'s
[`safePolygon`][fui-safe-polygon] gives the catalog its spelling; WPF calls the same idea a
"safe area", WinUI a "safe zone", Radix a "grace area", Zag an "intent polygon".

On the anchor→overlay half the field converged independently on one shape: **the convex hull
of the anchor rect and the overlay rect**. WPF computes it with an incremental scanline hull
whose vertices cache an edge direction so containment runs two passes — integer compares for
axis-aligned edges, cross products only for skew ones. WinUI hulls the same eight corners but
**polls** at 1 Hz off `GetCursorPos()`, with a no-move early-out so an idle mouse cannot
dismiss a keyboard-opened tooltip. React Aria pads both rects by 8 px, short-circuits on
either padded rect, and returns early for `pointerType === 'touch'`. [Ariakit][ariakit]'s
[`getElementPolygon`][ariakit-polygon] reaches the same region in **closed form** — it is the
convex hull of a point and an axis-aligned rect obtained by two comparisons and a corner-order
table, four or five vertices, no hull algorithm.

Floating UI is the outlier: a five-stage cascade whose apex is the _cursor_, with a trough
rect spanning the gap, an opposite-side bail, a `hasLanded` latch, a 40 ms grace timeout, and
a wall-clock **0.1 px/ms velocity gate** — the richest and the least portable.

**In cells the constants collapse, and that is the finding.** Floating UI's `buffer = 0.5` px
is **0 cells**; its lateral spread of `buffer * 4` is 0 cells at an 8 px cell; its ±1 px
opposite-side slack is 0 cells; Radix's ±5 px `bleed` is 1 column and 0 rows; React Aria's 8 px
padding is 1 cell each way. The velocity gate is not merely coarse but **unrepresentable**:
`sparkles:input` delivers `PointerEvent.pos` already quantised to cells, so the predicate
degenerates to "did the cell change this frame".

The corridor itself is usually 0 or 1 cell at the defaults the corpus produces (Floating UI's
`offset` 0, Radix's `sideOffset` 0, Zag's submenu `gutter: 0`, Textual's `margin: 1 0`), so
**inside the corridor** the polygon adds nothing over the corridor rectangle. It retains
whole-cell discriminating power **outside** the corridor, though — on the anchor's own row a
hull selects only the anchor's columns while its bounding rectangle selects the overlay's full
width — so the shape is not free discrimination but it is not nothing either.

What ports cheaply: the trough rect, the opposite-side bail (four integer compares), the
`hasLanded` latch (one bool), the nested-child abort (one tree walk), and the grace timeout
expressed in frames. Ariakit's on-edge and vertex-lookback guards become **more** important on
a lattice, not less: on a cell grid a containment ray grazes a vertex constantly.

### Pointer grace area / menu-aim {#menu-aim}

**Menu-aim** is the submenu half: keeping a submenu open while the pointer travels diagonally
across its parent's other items. [Angular CDK][angular-cdk] gives the catalog its spelling
(`cdkTargetMenuAim`, off by default); Qt calls it "sloppy submenus"; ImGui cites its origin —
bjk5's mega-dropdown post, "to avoid using timers, so menus feel more reactive".

Nobody converged here. Qt's `QMenuSloppyState` is a real FSM whose step returns one of
`EventIsProcessed` / `EventShouldBePropagated` / `EventDiscardsSloppyState`, comparing slopes
to the submenu's two near corners — and Qt defaults `SH_Menu_SubMenuUniDirection` to **false**
on every style but macOS. Angular CDK votes four trajectory lines from a five-slot ring buffer
against the submenu rect (consensus ≥ 2) and defers the close by 300 ms. ImGui builds a
triangle from _last frame's_ pointer with a ±8-line-height slope cap. React Aria compares
movement angles ±15° with a 0..2 hysteresis counter. Radix latches `sgn(Δx)` and gates a
five-point trapezoid on it. GTK4 does no geometry at all: an 80 ms timer **re-armed on every
motion event**, so it fires only once the pointer has stopped — which means crossing an
intervening item is tolerated as long as you keep moving.

**In cells, keep the counter and drop the angles.** React Aria's ±15° padding is meaningless
when a one-cell step admits only a handful of representable directions, and Qt's corner slopes
quantise to a few dozen values inside a 20×10-cell menu, tripping the default fail count of 1
on a single sideways step. What survives verbatim is the **failure/hysteresis counter** (Qt's
`m_uni_dir_discarded_count`, React Aria's `[0, 2]` clamp), and the direction latch `sgn(Δcol)`
replaces the angular test. The latch still needs Radix's zero-delta guard — the guard is an
exact-equality test that rejects a sample where the column did not change, and on a cell grid
**zero-delta is the common sample**, so it becomes more necessary, not less.

Two porting hazards are specific to quantisation. ImGui's apex is `MousePos - MouseDelta`,
which assumes a per-frame sub-pixel delta; on a cell grid the delta is `(0, 0)` on most frames
and the apex collapses onto the test point, turning a direction test into a degenerate winding
question — a cell port must accumulate motion over several frames. And [floating-vue][floating-vue] fails the
same way **silently**: with no continuous motion stream its inside-reference gate never passes,
aiming never fires, and it falls back to a 400 ms hide delay. That accident is the design
lesson stated cleanly: **menu-aim must be an optional refinement over a timing-based bridge,
never the only bridge**, because the geometric heuristic self-disables wherever the motion
stream is absent — a terminal that has not enabled motion reporting, touch, static HTML.

> [!WARNING]
> Bare-motion pointer reporting is **off by default** on the TUI target, so hover intent must
> be a declared capability rather than an assumed one: a host that has not opted in receives
> no motion events at all between presses. Only two applications and one example opt in
> in-tree today.

### Interactive border {#interactive-border}

The cheapest member of the family: no polygon, no trajectory — keep the surface open while the
pointer is inside its own rect **grown by a constant**, plus the gap on the anchor-facing side.
[Tippy][tippy] names it (`interactiveBorder`, default 2 px) and supplies the one refinement
worth copying: the grow on the anchor-facing side is read from the positioning offset, so the
declared gap is bridged **by construction** rather than by a second constant that can drift out
of sync. GPUI inflates observed submenu bounds by ±50 px; Avalonia inflates by a hard-coded
100 px cached at open (with the source comment "I'm not sure what WinUI uses, but I'm
defaulting to 100px, which seems about right"); WinUI uses a squared radius past 80 px.

**In cells the constants collapse to one or zero.** Tippy's 2 px is 0 cells; GPUI's 4 px
hover-recede hysteresis disappears entirely at every plausible cell size; Avalonia's 100 px is
about 12 columns and 6 rows; WinUI's 80 px about 10 and 5. The honest cell restatement is
`inflate(rect, 1, 1)` plus the gap — four integer compares per open surface, no history, no
trajectory state.

**The zero-gap alternative dissolves the problem instead of protecting it**, and it is the
consensus answer for a cell grid: place the child flush with, or overlapping, its parent so
there is no corridor to cross. Uno overlaps a submenu onto its parent by 4 px; Qt Quick's
`Menu::overlap` is 1–4 px by style; ImGui overlaps by `ItemInnerSpacing.x` and flags nested
submenus as child windows so hover is shared; Notcurses sizes **one** plane to the worst-case
section height so the trigger and the content share one rectangle. `apps/hue`'s GUI already
ships the tooltip half — a 0-cell gap plus a zero-tolerance containment test against the
last-painted rect — and needs no additional geometry for it. Its remaining defects are that the
behaviour is per-application and GUI-only (the TUI paths place at +1/+2 rows with no keep-open
rule), lives outside the shared hit list, and is expressed in pixels rather than in the
toolkit's cell vocabulary.

> [!NOTE]
> **Touch.** No subject in the corpus computes hover intent for touch input. Most that
> encounter it switch the machinery off at the source (React Aria returns early on
> `pointerType === 'touch'`; Floating UI's `useHover` gates the same way; Uno's cascade is
> mouse-only); Blink is inert on touch only as a side effect of requiring a known mouse
> position; Compose dispatches on pointer type with a touch fallback in the same expression
> rather than disabling. Declaring the capability absent on the touch target is therefore the
> field's practice, not a shortcut.

---

## 8. Dismissal {#dismissal-group}

### Dismissal policy {#dismissal-policy}

A **dismissal policy** declares which causes may close a given surface. The field's cleanest
form is [Qt Quick Controls][qt-quick-controls]' `ClosePolicy`: a seven-bit flags enum, with
`tryClose(pos, phaseFlags)` reducing to one boolean expression `closePolicy & (phase &
outsideFlags)` plus containment tests. WinUI/Uno declares the same shape
(`DismissalTriggerFlags {CoreLightDismiss, WindowSizeChange, WindowDeactivated, BackPress}`)
and reads it — but never assigns it anywhere in the tree, so the field's second attempt at
policy-as-data **rotted for lack of a default**. `NSPopover.behavior` is the degenerate
three-value form with a scope built into one value.

Dismissal decomposes into three separable things that most implementations tangle:

| Part               | What it is                                       | Where it belongs                                 |
| ------------------ | ------------------------------------------------ | ------------------------------------------------ |
| **policy**         | which causes may close this surface              | on the overlay, as a flags value                 |
| **cause detector** | how each cause is recognised                     | in the router, once — not per backend            |
| **cascade**        | how far down a nested stack one cause propagates | over the [overlay stack](#overlay-stack-vs-tree) |

The causes split on one axis that matters to a frame-loop toolkit. **Event-driven** causes
(close request, outside press or release, trigger re-press, focus-out) reduce in a
single-surface toolkit to a group-membership test over the last painted frame's hit list —
Flutter's `RenderTapRegionSurface._classifyRegions` does exactly this with no grab, no capture
and no scrim. **Frame-derived** causes (anchor removed, anchor clipped, does-not-fit, resize)
need no events at all: Textual re-hit-tests the cursor after every reflow; blink.cmp treats
"the placement solver returned nothing" as a dismissal; CSS `position-visibility` hides rather
than closes.

**In cells the frame-derived half is nearly free and is the only half assertable on a recording
canvas without synthesising input.** Anchor-liveness dismissal is a set/identity test over the
frame's derived hit list — but it carries a qualification the spec must state: `hitId` is an
**author-supplied field** on `Widget` (`widget.d:101`, "0 = not hit-testable"), copied verbatim
into the per-frame list, so frame-to-frame stability is a view-authoring convention, not a
toolkit guarantee. Every current consumer derives it from a domain index, and the requirement
must be worded as "the anchor id is domain-derived", not "ids are stable".

Two causes are simply **undetectable on the TUI** and any policy naming them must degrade
rather than pretend: surface blur (window or application deactivation), and the pointer leaving
the terminal window. Hover-exit _between targets inside the grid_ is fully detectable — motion
under the appropriate reporting mode produces move/drag events and `HoverState`'s later-wins
rule already retargets on them — so hover-exit must **not** be declared unavailable there.

### Light dismiss {#light-dismiss}

**Light dismiss** is closing on an interaction outside the surface, without a modal barrier and
usually without consuming the interaction. [WinUI][winui] gives the catalog its spelling; HTML
adopted the term for `popover="auto"`.

The mechanism that matters is the **two-phase pointer identity test**: the same surface must be
under both the press and the release. The HTML spec's `sameTarget` check and Blink's
`HandlePopoverLightDismiss` implement exactly that, and Qt latches `outsidePressed` at press and
re-checks at release so press-inside/release-outside can never close. Angular CDK's outside-click
predicate requires **both** the `pointerdown` target and the `click` target to be outside.

**Dismissal and consumption are independent**, and the corpus splits on the default: Compose
delivers the dismissing tap when the popup is non-focusable and swallows it when focusable
(both pinned in one test, via Android window flags rather than a library hit rule); Avalonia
re-raises the event on a re-hit-test; tmux drops it outright. **INFERENCE** (well supported, not
sourced): because a single-surface toolkit routes its own events, this should be an explicit
per-overlay value rather than an emergent consequence of how the surface was configured.

**In cells the two-phase test already exists.** `PressState`
([`STM10`](../../specs/ui/state-machines.md), `state.d:1403`/`:1413`) implements press-arms /
release-over-the-same-target-activates. Reusing it for dismissal needs the "outside everything"
case to be a **non-zero group id** — and it needs its **own** `PressState` instance keyed by
surface, because `activated` is transient and there is a single `armed` slot: sharing the
button-activation instance would let an in-overlay button press disarm the overlay's outside
test.

On the static-HTML target the expressible causes are narrow: trigger re-activation via
`<details>`/`<summary>` in the semantic emitter, plus hover-exit for a hover-triggered surface.
There is no outside-press, no Escape and no timer at tier 0.

### Grab {#grab}

A **grab** (pointer grab, mouse capture, `xdg_popup.grab`) is a windowing-system guarantee that
input is delivered to the grabbing client even when the pointer is outside its windows. It is
the mechanism most native menu stacks rest on, and the sibling
[window-system-integration][wsi] tree covers the protocol side.

Two findings make it a smaller loss here than it looks. First, Qt Widgets proves the grab is
**optional at the toolkit level**: `popupGrabOk == false` runs the same code path, and the only
capability lost is receiving events outside the application's own windows — which, on one
surface, is not a capability. Second, Wayland's owner-events grab exists precisely so that "users
can navigate through submenus … without having to dismiss the topmost popup", and a
single-surface toolkit is **natively owner-events**: one surface, one flat derived hit list, so
the routing guarantee comes free.

Floating UI's substitute is worth recording as the shape of the workaround where no grab exists:
`blockPointerEvents` sets `pointer-events: none` on the document body and re-enables it on the
anchor and the floating element only — a grab built out of CSS.

**In cells.** [`UI-O3`/`INP9`](../../specs/ui/input.md) records the absence: no native pointer
grab, so a drag leaving the window loses motion and release. For overlays specifically the cost
is confined to causes that originate outside the surface (see
[dismissal policy](#dismissal-policy)), not to the cascade or the routing.

---

## 9. Focus and modality {#focus-group}

### Focus scope {#focus-scope}

A **focus scope** is a subtree that keyboard traversal treats as a unit: entering it, ordering
within it, and where focus goes when it closes. React Aria and Radix both ship a component
literally called `FocusScope`; Base UI's is `FloatingFocusManager`; Avalonia gets the same effect
from one property default (`KeyboardNavigationMode.Cycle`); Slint from one boolean in the parent
walk (`StopAtPopups`); Turbo Vision from a circular sibling list and three state bits.

Almost every line of focus code in the web corpus is **repair work for a substrate a
single-surface toolkit does not have** — a second writer of focus, and a tab order that diverges
from visual order. The in-canvas subjects prove it from the other side by needing almost none of
it.

Four regimes stay distinct everywhere serious, and this table is the portable part:

| Regime          | Focus behaviour                                               | Enforced by                                                                                                        |
| --------------- | ------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| tooltip         | never focused; content non-interactive **by type**            | ImGui's `NoInputs` flag; WPF's `Focusable=false` + a transparent window style; Apple's `toolTip` taking a `String` |
| combobox / menu | focus stays on the container; the active item is an **index** | `aria-activedescendant`; Neovim's `cursorline`                                                                     |
| popover         | optionally **contains**                                       | a policy on the surface                                                                                            |
| dialog          | modal                                                         | an exclusion set over the hit list                                                                                 |

[APG][aria-apg] states the tooltip rule non-normatively and names the substitute in the same breath —
"Tooltip widgets do not receive focus", and "a hover that contains focusable elements can be made
using a non-modal dialog". So _a tooltip you can click into_ is not a configuration of a tooltip;
it is a different widget.

Three algorithms are worth porting outright: the Popover API's rewrite of an overlay's
focus-scope parent to its [trigger](#trigger-vs-anchor); a restoration **ladder** evaluated
against a liveness test rather than an assignment to a saved id; and a one-shot reopen guard.
Restoration must additionally be guarded by "is focus still inside the closing overlay" or the
toolkit fights the application — six independent implementations carry that guard (Blink, the
Popover spec, Angular CDK, WPF's `ContextMenu`, Textual's `Select`, React Aria's
`isElementInChildScope`).

**In cells there is no toolkit-owned focus order at all.** `FocusState`
([`STM7`](../../specs/ui/state-machines.md), `state.d:1316-1352`) is a single `size_t focused`
whose traversal is defined entirely over a **caller-supplied** `size_t[] order`; `hoverTargets`
and `keyTargets` are derived from the tree but there is no `focusTargets`, and `Widget` carries
`hitId` and `key` but no focusable bit. The only order array in the repo is hand-written. An
overlay therefore cannot join keyboard traversal today without the application splicing it in.
Separately, `FocusState.moved` always wraps and has no result meaning "the edge was reached,
leave this scope", so it can express a contained scope but not a non-modal popover that hands
focus back to the page.

Key release costs less here than elsewhere but not nothing: almost every focus decision in the
corpus is made on key-**down**, and the casualties are GTK's focus-visible press/release pair and
WPF's Alt/F10-on-key-**up** entry into menu mode, which moves real focus into the menu. Any such
affordance must be rebound to key-down.

### Trap vs containment {#trap-vs-containment}

Two mechanisms that produce the same user-visible effect and must not be confused:

- **Containment** — the toolkit's traversal function simply does not leave the scope. It is a
  property of the order, costs nothing, and is what Avalonia, Slint and Turbo Vision use.
- **Trap** — an interception listener watches focus changes and pulls focus back when something
  else takes it. It exists because the DOM has a second writer of focus, and it brings scope
  stacks, pause/resume, mutation observers and guard sentinels with it.

**In cells, containment is the only one that is needed**, because `FocusState` has exactly one
writer: application code calling `next`/`previous` or assigning. There is no second writer to
intercept, so a trap would be machinery guarding against an event that cannot occur. That is a
statement about the current toolkit, not a universal claim — it becomes false the moment a
backend gains an independent focus authority.

### Modality {#modality}

**Modality** is the property that a surface excludes interaction with what is behind it. The
field's converged answer is that **modality is not a mode**: Floating UI, Radix, Zag, Base UI,
React Aria, Qt Quick, Compose, WinUI and Apple all decompose it into three to five independently
settable effects — pointer blocking, key routing, focus containment, a [scrim](#scrim),
assistive-technology hiding, scroll lock. Every subject that shipped a single bundled boolean
regrets it in its own source; GTK4's `autohide` conflates four concepts _and_ is
construct-only, so changing it must unrealize the widget.

Where the bit **lives** is genuinely unsettled — three positions are defended in code: on the
overlay (Qt Quick's `modal`, GPUI's per-hitbox behaviour), on the stack (Radix's
`index >= highestDisabledIndex`, WinUI's "hit iff any open light-dismiss popup", ImGui's
`FindBlockingModal`), and on the host (Textual's `ModalScreen`, buffer-local keymaps in [nui.nvim][nui],
Wayland's `xdg_dialog_v1.set_modal` which is _only a hint_ and requires client-side filtering).

Mechanically there are five families, and only two of them reach a single-surface cell toolkit:
a full-surface catcher rect painted into the same surface (Avalonia, WinUI, Uno, Flutter, [APG][aria-apg],
GPUI), and **a predicate inside the hit walk with no rect at all** (GPUI's `HitboxBehavior`,
Slint, Qt Quick's `blockInput`, ImGui, Helix). The other three — a nested event loop (Turbo
Vision), an OS grab, and DOM mutation of everything outside — do not.

**In cells the fourth family _is_ the existing hit model plus one enum.** Keyboard modality is a
truncation of an ordered chain rather than a geometric test, so it composes with
[`DCK13`](../../specs/ui/containers.md)'s existing precedence instead of needing a parallel
mechanism. A passthrough hole must suppress **both** input blocking and dismissal — suppressing
only one is a defect, and Qt Quick is the subject that pins the conjunction with a test.

One thing has no home at all today: the **accessibility modal bit**. No `sparkles` backend emits
any role, ARIA or platform accessibility information, and accessibility is an explicit non-goal in
`docs/specs/tui/index.md`, so the web subjects' `aria-hidden`/`inert`/refcount apparatus has
nowhere to land. (The HTML target's vocabulary is _unused_ rather than strictly empty: the
semantic emitter already carries a disclosure CSS rule and emits `<details>`/`<summary>`.)

### Scrim {#scrim}

A **scrim** is the translucent plane painted between a modal surface and everything behind it. Qt
Quick calls it a `dimmer`, WinUI and Uno a "light-dismiss overlay", Flutter a `ModalBarrier`, CSS
`::backdrop`; Material's "scrim" is the clearest name and the catalog takes it.

**In cells the scrim already exists**, and the phase-1 notes claiming a terminal must drop it or
invent a dim attribute are wrong: `GridCanvas.fillRect` blends translucent backgrounds and
`RaylibCanvas` maps background alpha to a quad alpha, while the HTML emitter writes `rgba()`.

**But the cell backends dim only half of it.** `GridCanvas.fillRect` and `CellCanvas.fillRect`
blend only the cell **background** and never touch the foreground, so on the cell targets a scrim
darkens the ground and leaves the glyph at full brightness — and contrast can invert on a light
ground. The raylib and HTML backends paint a translucent layer over already-drawn glyphs and
therefore do dim the foreground. The requirement this creates is a **foreground treatment on the
cell canvases for parity**, most cheaply by applying the `Visual.fgAlpha` that already exists.

---

## 10. Emitted geometry {#geometry-group}

### Geometry metadata {#geometry-metadata}

**Geometry metadata** is what the placement engine publishes about its decision, for consumers
that must style, animate or draw from it. Roughly a third of the surveyed subjects emit it
deliberately; two thirds compute the same facts inside the solver and throw them away.

The metadata camp converges on an almost identical payload: the post-flip **side** and
**alignment** (Radix's `data-side`/`data-align`, Zag's `data-placement`, [Headless UI][headlessui]'s
`data-anchor`, Tippy's `data-placement`, CDK's `ConnectionPositionPair`), a numeric
[transform origin](#transform-origin), the **room actually available**, the anchor's own size,
and a **suppress-this-transition** flag.

The discard camp pays a measurable price, and the recovery hacks are the sharpest evidence in the
dimension: ImGui computes its direction and never reads it; GPUI's anchored element flips into a
_local_ variable and discards it, so three call sites re-invent it; Uno's `Popup.ActualPlacement`
is never assigned, making a live consumer branch dead code; Compose's material3 pays **three**
separate times for `calculatePosition` returning a bare offset.

One of those recoveries is worth naming because it is a bug the survey found rather than
inherited: Compose's `caretX` disagrees with its own `abovePositioning` in the left-collision
branch — it under-shoots the tooltip-local anchor centre by `min(anchorLeft, W - w)`, and the
right-collision branch diverges by `W - anchorRight` on the same pattern. Both functions do use
the same extent, so the mechanism is not a boundary mismatch; and the disagreement is untested.

**In cells the consumer is different, and that raises the stakes.** On a pixel surface the side
selects a transform and an arrow rotation; on a cell grid it selects the **arrow glyph, the border
cap and the connector elbow** — and on the static-HTML target it does so at emit time with no
later measurement pass. The metadata is owed even though the CSS-variable delivery mechanism is
not.

Two in-repo defects follow directly. The four canvases **do not agree on the arrow's column**: the
raylib backend places it one cell left of both cell backends for an identical `Visual` and `Rect`,
and the HTML emitter writes the same numeral but in CSS `ch` from the padding box, so its agreement
with the cell backends holds only under the mapping "a 1 px CSS border occupies no cell". And
nothing anywhere in `sparkles:ui` clamps `arrowOffset` against the box extent: the only guard is an
in-bounds test against the surface rect plus the active clip stack — neither of which is the box —
and the arrow cell is written **after** the corner cells, so an offset at or beyond `width - 2`
overwrites the box's corner glyph and larger values paint outside the box.

### Transform origin {#transform-origin}

The **transform origin** is the point a scale-and-fade animation grows from — pinned, in the
subjects that bother, to the **arrow tip**, so a popover appears to emerge from its anchor rather
than from its own centre. Radix exports it as `--radix-popper-transform-origin`; Base UI as
`--transform-origin`; Zag builds it in a dedicated middleware; React Aria calls the same value
`triggerAnchorPoint`.

**In cells there is no transform**, so the numeric origin has no consumer — but the datum it is
computed from does. The categorical fallback matters more than the number: when the arrow could
not be centred, the numeric origin is meaningless and the correct answer is the categorical
alignment, which means "the arrow could not be centred" must be a **separate reported datum**
rather than something inferred from the offset.

The cell analogue of an animated origin is a **discrete revealed extent**: `Timeline.alphaPercent`
is a GUI-only projection (a cell backend can express neither text opacity nor a scale), so a
second, integral projection — a count of revealed rows or columns — is what a cell target can act
on.

Reduced motion is the related input, and it cannot be discovered uniformly: it must be a
configuration or theme **input**, with one exception worth exploiting — the static-HTML emitter can
emit both branches under `@media (prefers-reduced-motion)` and let the viewer's own CSS engine
choose, which is deferred resolution rather than build-time discovery. Of the surveyed subjects,
none reads reduced motion in its overlay path at all.

---

## Where each term is exercised {#index-by-subject}

A reading aid, not a taxonomy: the subject each term is best studied in.

| Term                                                                                                    | Study it in                                                                                  |
| ------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| [anchor](#anchor), [anchor rect](#anchor-rect), [gravity](#gravity)                                     | [xdg_positioner][xdg-positioner], [Avalonia][avalonia]                                       |
| [virtual anchor](#virtual-anchor), [inline anchor](#multi-rect-anchor), [fallback list](#fallback-list) | [Floating UI][floating-ui], [Base UI][base-ui]                                               |
| [trigger vs anchor](#trigger-vs-anchor)                                                                 | [Floating UI][floating-ui], [Base UI][base-ui], [popover API][popover-api]                   |
| [anchor tracking](#anchor-tracking)                                                                     | [GPUI][gpui], [WPF][wpf], [Neovim][neovim-floats], [Helix][helix]                            |
| [anchor-hidden / escaped](#anchor-hidden)                                                               | [Floating UI][floating-ui], [CSS anchor positioning][css-anchor], [Blink][blink]             |
| [constraint adjustment](#constraint-adjustment), [flip](#flip)                                          | [xdg_positioner][xdg-positioner], [GTK4][gtk4]                                               |
| [shift](#shift), [push](#push)                                                                          | [Textual][textual], [Angular CDK][angular-cdk], [GPUI][gpui]                                 |
| [resize](#resize)                                                                                       | [WinUI][winui], [WPF][wpf], [Qt Quick][qt-quick-controls]                                    |
| [auto placement](#auto-placement)                                                                       | [Helix][helix], [Flutter][flutter], [nvim completion][nvim-completion]                       |
| [boundary](#boundary), [work area](#work-area)                                                          | [Avalonia][avalonia], [ImGui][imgui], [tmux][tmux-popup]                                     |
| [clipping ancestor](#clipping-boundary)                                                                 | [Radix][radix], [Blink][blink], [GPUI][gpui]                                                 |
| [safe-area inset](#safe-area-inset)                                                                     | [WinUI][winui], [Flutter][flutter], [Slint][slint]                                           |
| [top layer](#top-layer), [overlay stack](#overlay-stack-vs-tree)                                        | [popover API][popover-api], [Textual][textual], [ImGui][imgui]                               |
| [portal](#portal)                                                                                       | [Angular CDK][angular-cdk], [Radix][radix], [Ariakit][ariakit]                               |
| [warm-up](#warm-up), [cool-down](#cool-down)                                                            | [React Aria][react-aria], [WPF][wpf], [ImGui][imgui]                                         |
| [safe polygon](#safe-polygon)                                                                           | [Floating UI][floating-ui], [WPF][wpf], [Ariakit][ariakit]                                   |
| [menu-aim](#menu-aim)                                                                                   | [Angular CDK][angular-cdk], [Qt Widgets][qt-widgets], [GTK4][gtk4]                           |
| [interactive border](#interactive-border)                                                               | [Tippy][tippy], [Uno][uno], [Notcurses][notcurses]                                           |
| [dismissal policy](#dismissal-policy), [light dismiss](#light-dismiss)                                  | [Qt Quick][qt-quick-controls], [WinUI][winui], [popover API][popover-api]                    |
| [grab](#grab)                                                                                           | [Qt Widgets][qt-widgets], [xdg_positioner][xdg-positioner], [window-system-integration][wsi] |
| [focus scope](#focus-scope), [trap vs containment](#trap-vs-containment)                                | [React Aria][react-aria], [Avalonia][avalonia], [Turbo Vision][turbo-vision]                 |
| [modality](#modality), [scrim](#scrim)                                                                  | [Qt Quick][qt-quick-controls], [Compose][compose], [Turbo Vision][turbo-vision]              |
| [geometry metadata](#geometry-metadata), [transform origin](#transform-origin)                          | [Radix][radix], [Zag][zag], [Compose][compose]                                               |

---

## Sources

Every citation on this page is the upstream source at the revision recorded in the
[catalog's revision ledger][index]. Beyond the per-subject deep-dives linked throughout:

- **Wayland** — [`xdg-shell.xml`][xdg-constraint], the constraint-adjustment precedence and
  the anchor-rect copy semantics.
- **WHATWG HTML** — the [top layer and popover algorithms][html-topmost], including the
  strictly-earlier rule that turns a connection graph into a well-formed tree.
- **CSS WG drafts** — [`css-anchor-position-1`][css-anchor-names] (anchor names, acceptable
  anchors, `position-visibility`) and [`css-position-4`][css-position-4] (the top layer as a
  paint-order set).
- **In-repo** — [`docs/specs/ui/`](../../specs/ui/index.md): the
  [principles](../../specs/ui/principles.md) (`PRN1`–`PRN12`), the
  [state machines](../../specs/ui/state-machines.md) (`STM1`–`STM13`), the
  [input model](../../specs/ui/input.md) (`INP*`, the tier ladder, the hit-testing model),
  the [containers](../../specs/ui/containers.md) (`DCK5`, `DCK13`), the
  [backends](../../specs/ui/backends.md) (`TGT5` and the degradation inventory), the
  [widgets](../../specs/ui/widgets.md) (`WGT7`'s popup) and the
  [theme](../../specs/ui/theme.md).
- **Sibling research** — [window-system-integration][wsi] for grabs, surface roles and the
  end-to-end windowing harness; [platform UI guidelines][platform-guidelines] for the
  appearance side; [ui-layout][ui-layout] for the layout algebra these placements sit on;
  [sean-parent][sean-parent] for the Regular-value and local-reasoning vocabulary the
  recommendations lean on.

<!-- References -->

<!-- Catalog -->

[index]: ./index.md
[comparison]: ./comparison.md
[baseline]: ./sparkles-baseline.md
[proposal]: ./proposal.md
[forgotten]: ./features-people-forget.md

<!-- Subject deep-dives -->

[angular-cdk]: ./angular-cdk.md
[apple]: ./apple.md
[aria-apg]: ./aria-apg.md
[ariakit]: ./ariakit.md
[avalonia]: ./avalonia.md
[base-ui]: ./base-ui.md
[blink]: ./blink.md
[compose]: ./compose.md
[css-anchor]: ./css-anchor.md
[emacs-posframe]: ./emacs-posframe.md
[floating-ui]: ./floating-ui.md
[floating-vue]: ./floating-vue.md
[flutter]: ./flutter.md
[gpui]: ./gpui.md
[gtk4]: ./gtk4.md
[headlessui]: ./headlessui.md
[helix]: ./helix.md
[imgui]: ./imgui.md
[neovim-floats]: ./neovim-floats.md
[notcurses]: ./notcurses.md
[nui]: ./nui.md
[nvim-completion]: ./nvim-completion.md
[popover-api]: ./popover-api.md
[qt-quick-controls]: ./qt-quick-controls.md
[qt-widgets]: ./qt-widgets.md
[radix]: ./radix.md
[ratatui]: ./ratatui.md
[react-aria]: ./react-aria.md
[slint]: ./slint.md
[textual]: ./textual.md
[tippy]: ./tippy.md
[tmux-popup]: ./tmux-popup.md
[turbo-vision]: ./turbo-vision.md
[uno]: ./uno.md
[winui]: ./winui.md
[wpf]: ./wpf.md
[xdg-positioner]: ./xdg-positioner.md
[zag]: ./zag.md

<!-- Sibling research trees -->

[wsi]: ../window-system-integration/index.md
[platform-guidelines]: ../platform-ui-guidelines/index.md
[ui-layout]: ../ui-layout/index.md
[sean-parent]: ../sean-parent/index.md

<!-- Pinned primary sources -->

[xdg-anchor-rect]: https://gitlab.freedesktop.org/wayland/wayland-protocols/-/blob/afb614d5fcbd02d261a6ae91920aa91cf3915a8a/stable/xdg-shell/xdg-shell.xml#L169
[xdg-anchor-enum]: https://gitlab.freedesktop.org/wayland/wayland-protocols/-/blob/afb614d5fcbd02d261a6ae91920aa91cf3915a8a/stable/xdg-shell/xdg-shell.xml#L188
[xdg-copy]: https://gitlab.freedesktop.org/wayland/wayland-protocols/-/blob/afb614d5fcbd02d261a6ae91920aa91cf3915a8a/stable/xdg-shell/xdg-shell.xml#L136
[xdg-constraint]: https://gitlab.freedesktop.org/wayland/wayland-protocols/-/blob/afb614d5fcbd02d261a6ae91920aa91cf3915a8a/stable/xdg-shell/xdg-shell.xml#L239
[fui-canvas]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/website/lib/components/Canvas.js#L33
[fui-inline]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/core/src/middleware/inline.ts#L27
[fui-safe-polygon]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/react/src/safePolygon.ts#L47
[cdk-origin-rect]: https://github.com/angular/components/blob/f3e6276c969f33e527b616ef8bf7b0404685721d/src/cdk/overlay/position/flexible-connected-position-strategy.ts#L1275
[ariakit-polygon]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/hovercard/utils/polygon.ts#L70
[avalonia-pointer-anchor]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Primitives/PopupPositioning/IPopupPositioner.cs#L481
[avalonia-overlay-host]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Primitives/OverlayPopupHost.cs#L123
[textual-translate-inside]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/geometry.py#L961
[gpui-menu-position]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/editor/src/mouse_context_menu.rs#L21
[flutter-position-dependent]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/packages/flutter/lib/src/painting/geometry.dart#L41
[winui-placement-order]: https://github.com/microsoft/microsoft-ui-xaml/blob/29ebf098f70df518b57b754130bc94004be8c6bc/dxaml/xcp/dxaml/lib/FlyoutBase_partial.cpp#L2559
[html-topmost]: https://github.com/whatwg/html/blob/ac0389a3aca0331055bf4bf23f509c2913e3f795/source#L92612
[css-anchor-names]: https://github.com/w3c/csswg-drafts/blob/6dc15cc9cb15043840eacf081e89f5a666fa7889/css-anchor-position-1/Overview.bs#L233
[css-position-4]: https://github.com/w3c/csswg-drafts/blob/6dc15cc9cb15043840eacf081e89f5a666fa7889/css-position-4/Overview.bs#L136
