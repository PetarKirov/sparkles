# `sparkles:ui` anchored overlays — Feature Requirements (`POP`, `ANC`, `PLC`, `TRG`, `DSM`, `LYR`, `MDL`)

_**Status:** proposed · **Date:** 2026-08-14 · **Scope:** one reusable
anchored-overlay primitive for `sparkles:ui` — the surface that is positioned
relative to something else and painted above it: tooltip, popover, hovercard,
dropdown, menu, context menu, combobox surface, teaching tip, the dock hint, and
the screen-anchored notifier. Covers the anchor value, the placement solve, the
overlay arena that fills [`DCK13`](./containers.md)'s empty top-layers rung,
trigger resolution, dismissal, layering and modality. Excludes item collections,
typeahead, roles and any native windowing mechanism._

This page is the **decision record**; the evidence is the
[anchored-overlay catalog](../../research/anchored-overlays/index.md) — 38
subjects, the [ten-question comparison](../../research/anchored-overlays/comparison.md),
the [repository baseline](../../research/anchored-overlays/sparkles-baseline.md)
and the [proposal](../../research/anchored-overlays/proposal.md) it converges on.
Every claim the catalog raised was run through a two-lens adversarial pass; the
verdicts are summarised in the catalog index. **No requirement below rests on a
refuted claim**, downgraded claims are used only in their narrowed form, and
every assertion the catalog does not establish is marked a **Sparkles decision**
in its own row.

## Why this spec exists

The toolkit has a `WidgetKind.popup` that does not float. There is no `case
popup:` anywhere under `libs/ui/src`: the kind is laid out by the same box-flow
walk as a `stack`, at the position its parent gives it, contributing to its
parent's extent like any other child, and the semantic HTML target emits it
`position:relative`. It carries no anchor, no placement, no dismissal, no state
and no top-layer participation. The floating is the caller's job — and three
callers do it three ways.

`clampOrigin` (`libs/twoslash/src/sparkles/twoslash/render_widgets.d:430`) is one
axis, one direction, against one scalar extent, called from three sites that
disagree on the boundary (`apps/hue/src/gui.d:2900`, an anchor-relative **pixel**
edge; `apps/hue/src/tui.d:654`, the **pane** width; `apps/hue/src/twoslash_tui.d:267`,
the **whole grid**), on the vertical offset (`+0`, `+2`, `+1`) and on whether
they clip at all. That is [`PRN8`](./principles.md) violated by three
applications each guessing at a behavior the toolkit does not define — the same
"share the transport, share no policy" outcome the catalog found in Qt Widgets
(five placement ladders), Neovim (four flip rules) and tmux (two drifted
190-line copies).

## Design & rationale

### The surface-independent core

The catalog answers the packaging question five different ways, and the split
between what is **shared** and what is **per-surface** is far more stable than
the packaging. Among the subjects that discuss it, the shared half is an anchor
value, a placement solve whose result reports the resolved side and the arrow, an
ordered layer registry with parent links and a cascade operation, and a
reason-tagged dismissal channel. The per-surface half is focus policy, timing and
hover intent, item collections, content typing, modality-as-a-mode, roles, and
every exotic placement mode.

Two findings bound how large the sparkles primitive may be, and they pull in
opposite directions:

- **Compose's eight-surfaces-on-one-`Popup` unification is subsidised.** Every
  Compose `Popup` is a real window-manager child window, so z-order, per-window
  outside-touch and focusability come free and the whole policy surface is five
  booleans. Sparkles has no such subsidy: one surface, no compositor, no grab
  ([`UI-O3`](./open-issues.md#ui-o3)), hit order **is** reverse paint order. What
  Compose delegates downward, this primitive must own — and Compose's own
  cascading-menu sample is the proof of what falls out, since the menu tree,
  hover-open and cascade dismissal are application code there.
- **Zag's inverted dependency pair** is the sharpest evidence the core is two
  halves rather than one monolith: its toast package depends on the dismissal
  layer and **not** the positioner, its tooltip package on the positioner and
  **not** the dismissal layer. Two surfaces each take exactly one half. A single
  bundled policy struct therefore has to justify itself; see `POP2`.

One structural rule the whole architecture rests on: an overlay's content is
**authored as a child of its anchor**, and only its **emission** is hoisted.
That is Flutter's `OverlayPortal` split with the reparenting removed, and it is
the only shape that also serves the static-HTML target, where `:hover` /
`:focus-within` cannot cross a hoist and where the ARIA practices guide makes
submenu containment mandatory. A portal-based design (Flutter, Radix, CDK,
Ariakit) cannot serve HTML from the same declaration.

### Placement is a pure function over Regular values

Every subject reduces its anchor to a Regular rect-plus-gravity value before any
placement arithmetic — the Wayland positioner makes the copy normative, Avalonia's
positioner parameters are literally a `record struct`, GTK4's layout equality
compares ten POD fields. Handle use beyond re-measurement does exist (boundary
derivation, scroll-ancestor scoping, anchor liveness), and each needs an explicit
value-shaped substitute here: the boundary becomes a `place()` **parameter**
(`PLC3`), liveness becomes a **field** (`ANC6`).

Sparkles is unusually well placed to take that shape. `layout()` **is** the
measurement and it is not abstract, so the three-method measurement `Platform`
that Floating UI needs — and its 264-line `autoUpdate` observer machinery —
collapse to "recompute inside the existing frame pass" (`PLC12`). The clip chain
is already threaded to every node and collapsed to one `Rect`, so there is no
clip measurement step. What remains is arithmetic over `Rect`, `Size`, `Point`
and `Insets`, all `int` cells, all `@safe pure nothrow @nogc` today.

### What the cell grid costs, and what it buys

Integer cells ([`LAY3`](./layout.md)) delete the fractional-pixel, DPR and
transform concerns that dominate the web subjects; the catalog records one
surviving hazard, a double-width grapheme bisected by an overlay edge. The costs
are concrete and are what the requirements below are written against:

| Constraint                                                    | Consequence for this primitive                                                                                                                   |
| ------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| There is no top layer — every backend paints one surface      | an overlay is visible only because something painted it last; ordering is a toolkit-owned arena, never a z coordinate (`LYR1`)                   |
| Hit order is reverse paint order                              | "front-to-back" means "later in the display list"; topmost-wins is already how `HoverState` scans the flat list                                  |
| Events route against the **last painted frame's** hit data    | an overlay's hit rect is one frame stale **by construction** — placement stability is a correctness concern, not polish (`PLC13`, `DSM9`)        |
| Positions may legitimately be **negative**                    | a placement result must clamp to the **boundary**, never to `0` (`PLC4`)                                                                         |
| `Point`/`Size` are `Vector`-backed unions                     | named-field reads are unavailable in CTFE; `place()` is runtime-property-tested and **must not** be specified as `@ctfe`-evaluable (`PLC1`)      |
| No native grab (`UI-O3`), no key release on the TUI (`INP16`) | dismissal and modality must not be specified in terms of a grab; a keyboard press-and-hold is unavailable, a pointer long-press is not (`MDL11`) |
| An arrow is at most one cell; alpha is a GPU/HTML projection  | the caret must be **exact**, and a discrete reveal projection is needed for cells (`PLC11`, advanced)                                            |

### What placement must return — the load-bearing finding

Returning only an offset is the named anti-pattern, and Compose prices it: its
`caretX` disagrees with its own `abovePositioning` by `anchorLeft` in the
left-collision branch, and the disagreement is untested. Among the subjects that
need the resolved side for anything, every one whose result **discards** it either
pays to recover it — Compose with a downcast plus a one-frame-late coordinate
comparison plus a duplicated clamp; WPF re-deriving the direction as two
`BitVector32` bits; GPUI reinventing its flip at three call sites; blink.cmp
duplicating one derivation at two sites — or forecloses the feature entirely
(Avalonia's `void Update`, Slint's fixed-only placement, Qt Quick Controls). The
verification pass narrowed the strong form of this: the cost is **re-derivation**,
and only company-mode exhibits a verified **drift** between two such
re-derivations. The requirement rests on the cost, not on the drift.

Sparkles is the sharpest case in the corpus, because the datum already exists
with nothing producing it. `BoxStyle.arrow`/`arrowOffset` and
`Decoration.arrow`/`arrowOffset` are documented "backends place it", and
consequently **all four** canvases hard-code the arrow to the top edge
(`grid_canvas.d:371-372`, `interp/cells.d:346-347`, `interp/html.d:227+250`,
`raylib_canvas.d:329-347`). Two live defects follow: the raylib backend places
the arrow one cell left of both cell backends, and **nothing in `sparkles:ui`
clamps `arrowOffset` against the box extent**, so `arrowOffset >= width - 2`
unconditionally overwrites the corner glyph. `place()` therefore returns
`OverlayGeometry` — the whole decision record — and the discard is the mistake
(`PLC2`, `PLC10`).

### What is composed, and what is genuinely new

[`PRN8`](./principles.md) forbids a second backend-independent definition of a
behavior the toolkit already owns, so the composition budget is stated before the
requirements, and every new machine carries its justification.

| Existing machine                                  | What it supplies to the primitive                                                                                                                                                         | Changed?                                                                                                |
| ------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| `HoverState` ([`STM4`](./state-machines.md))      | the `hot` id — the hover trigger **and** the "inside" test. It already scans the flat target list keeping the **last** hit, so topmost-wins over an appended overlay is existing behavior | no new predicate for positional routing; **yes** for modality — a behavior field on the target (`MDL1`) |
| `Timeline` ([`STM6`](./state-machines.md))        | fade-in / hold / fade-out, `holdUntilDismissed`, `dismissed()`, the exit clock                                                                                                            | no — but it may **not** host the warm-up (`TRG6`), and its default config is a trap (`TRG13`)           |
| `FocusState` ([`STM7`](./state-machines.md))      | the focus ring over a caller-supplied order, and the return target                                                                                                                        | no — but a new `focusTargets` derivation and an order splice sit above it (`MDL4`)                      |
| `PressState` ([`STM10`](./state-machines.md))     | trigger activation, item arming, and the two-phase outside-press identity test                                                                                                            | no — but dismissal needs its **own instance** keyed by group id (`DSM4`)                                |
| `CaptureState` ([`STM11`](./state-machines.md))   | press-and-drag menu traversal; the drag-out exemption from every outside cause                                                                                                            | no — its no-transfer rule is load-bearing and must not gain a priority (`LYR6`)                         |
| `DisclosureState` ([`STM5`](./state-machines.md)) | the tier-0 HTML spelling of a toggle (`details` / `summary`)                                                                                                                              | no                                                                                                      |

> [!IMPORTANT]
> The catalog's check that `HoverState` already keeps the last hit **survived
> verification**, and it shrinks this spec: topmost-wins _within one widget
> tree's target list_ needs no new mechanism once overlay targets are appended
> last. The claim that this makes the `DCK13` rung unnecessary for positional
> routing was **refuted** — `DockContainer` resolves the pane **by rect** before
> any tree's hit list is consulted, so an overlay that geometrically escapes its
> pane is routed to the neighbouring pane and never reaches its own target list.
> The rung is therefore required for positional routing too, exactly as `DCK13`
> already specifies (`LYR5`).

Genuinely new, and nothing else: the overlay **arena** (`LYR1`), the placement
**solve** (`PLC1`), the trigger **resolution** (`TRG1`), the dismissal
**evaluator** (`DSM1`), the `focusTargets` derivation (`MDL4`), and one state
machine — `DwellState` (`TRG6`), whose `PRN8` justification is three verified
properties of `Timeline`, not a preference.

### Claims this spec deliberately does not use

Recording them is part of the traceability contract: a requirement resting on any
of these would be resting on nothing.

| Struck claim                                                           | What the spec does instead                                                                                      |
| ---------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| "The `DCK13` rung is unnecessary for positional routing"               | `LYR5` requires it for positional routing at the container tier                                                 |
| "A safe polygon and its bounding rect select the same cells"           | `TRG12` keeps the corridor at zero cells by default and reserves a hull only where a corridor is genuinely wide |
| "Direction-latch intent becomes strictly more reliable under cells"    | the direction latch stays **advanced** and unproven, behind a declared motion capability (`TRG11`)              |
| "`INP16` costs the primitive exactly one trigger"                      | `TRG5` keeps per-trigger latches; the release-edge key family is a whole casualty, not one trigger              |
| "One `OpenCause` derives every cross-trigger suppression rule"         | `TRG5` records the cause **and** retains time-scoped and close-cause suppression state                          |
| "Nothing in the focus dimension needs a key release"                   | `MDL4` rebinds focus-visible and menu-mode entry to key-**down** rather than assuming parity                    |
| "Returning effects as values converts a blocking design mechanically"  | `POP4` states the plan/apply split as a Sparkles decision, not as a mechanical inversion                        |
| "Whether to animate is a pure function of the open-change reason"      | no requirement conditions a transition on the reason                                                            |
| "The paint/routing split is exactly `visible()` versus the fade phase" | `LYR10` states the paint-without-hit rule directly, on the arena                                                |
| "The single-surface constraint removes a class of duplication"         | no requirement claims a benefit from the constraint; `PLC4` fixes the duplication it actually caused            |

## The primitive and its ownership boundary (`POP`)

`POP` — the primitive itself: what it is, what it owns, and what it refuses.

| ID   | Requirement                                                                                                                                                                                                                                                                                                                                                                                | Status      | Traces to                                                                                                                                        |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| POP1 | There must be **one** anchored-overlay primitive in one module family (`libs/ui/src/sparkles/ui/overlay/`), serving every anchored surface as one value with different policy — never N widget types. The base-class shape is rejected on the catalog's evidence that its awkward consumers bypass the base entirely (WinUI's `ToolTip` and `TeachingTip` both leave `FlyoutBase`).        | decided     | [proposal §1](../../research/anchored-overlays/proposal.md); the packaging table in [comparison](../../research/anchored-overlays/comparison.md) |
| POP2 | The **shared core** is exactly: the anchor value, the placement solve and its result, the ordered layer arena with parent links and a cascade, and the reason-tagged dismissal channel. **Out**: focus behavior defaults, timing machines, item collections/typeahead/selection ([`WGT13`](./widgets.md)), content typing, roles, modality as a mode, and item-aligned `Select` placement. | decided     | the near-unanimous split among subjects that discuss it; Zag's inverted dependency pair                                                          |
| POP3 | An overlay's content must be **authored as a child of its anchor**; only its **emission** is hoisted. Reparenting, portals and stacking contexts are forbidden — there is nothing to escape, and a hoisted declaration cannot serve the static-HTML target where `:hover` / `:focus-within` cannot reach it.                                                                               | researched  | Flutter's portal split minus reparenting; Textual's order/clip/extent triple; `D10.C2` (narrowed)                                                |
| POP4 | Every value in the primitive must be **Regular** ([`PRN6`](./principles.md)) — no callbacks, no closures, no handles — and the transition must be split into a **plan** (a value) and an **apply**, so a decision is assertable on the recording canvas **without being applied**. _Sparkles decision:_ the catalog's stronger claim that this conversion is mechanical was refuted.       | researched  | `dock.d:826` `struct Route` is the in-tree precedent; `D15.C10` **refuted** — see the note below                                                 |
| POP5 | The public API must be able to be backed by a **native windowing layer** (a real `xdg_popup`, an X11 override-redirect surface) **without a consumer change**. The public value names a scope and a band; it never names a mechanism. _Sparkles decision_ (evidence: WinUI and Avalonia both choose the host per open and keep the choice internal).                                       | decided     | [window-system-integration](../../research/window-system-integration/index.md); `PLC5` keeps the request xdg-isomorphic                          |
| POP6 | `WidgetKind.popup` must stop promising behavior it does not have. Either it becomes the **emission** of an overlay record, or the name is retired in favour of the shipped truth (`panel` plus a shadow the view asks for). A kind whose doc comment says "detached from flow" while every walk groups it with `stack` is an interface that lies ([`PRN8`](./principles.md)).              | not started | [baseline §1](../../research/anchored-overlays/sparkles-baseline.md); [`UI-O2`](./open-issues.md#ui-o2)                                          |
| POP7 | The arena and the solve must hold the toolkit's allocation posture: a bounded `SmallBuffer` arena, `@safe pure nothrow @nogc` transitions, and no steady-state allocation. The nesting bound must be a **stated** capacity, not an unbounded list.                                                                                                                                         | not started | [`NFR2`](./feature-requirements.md); open question — GPUI asserts depth `< 10`, Qt bounds its close loop at 1024                                 |
| POP8 | Every behavior specified here must be **assertable headlessly** — through `RecordingCanvas` and `--render` — and a `ui-gallery` overlay page must exercise the primitive across every target. Today `HUE_GUI_HOVER` exists only because overlays are unreachable in tests.                                                                                                                 | not started | [`TGT10`](./backends.md); `apps/ui-gallery` has fourteen pages and no popup page                                                                 |

> [!NOTE]
> `POP4`'s split is the **only** dismissal-veto mechanism this spec permits: a
> veto cannot live inside a pure `step(state, input) -> state`
> ([`PRN7`](./principles.md)), and a cancelable event object would reintroduce
> the listener bookkeeping the toolkit does not have. The catalog's claim that
> converting a blocking design (Turbo Vision opens submenus through a blocking
> `execView` consumed in the same loop iteration) is _mechanical_ was refuted, so
> this spec claims only that the value-shaped plan is the right target shape —
> not that any particular port is cheap.

## Anchor model (`ANC`)

`ANC` — the anchor: what an overlay is positioned against, and how that resolves.

| ID   | Requirement                                                                                                                                                                                                                                                                                                                                                                                                                           | Status      | Traces to                                                                                                                    |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | ---------------------------------------------------------------------------------------------------------------------------- |
| ANC1 | The anchor must be a **Regular POD in integer cells** — a closed sum over `{key, rect, point, textRange, corner}` plus an optional avoid rect and a tracking policy — with no live handle, no closure and no lifetime. The narrowing is deliberate: this is true at the **placement seam**, not of every use a subject makes of an anchor reference.                                                                                  | researched  | `D1.C1` (narrowed); the positioner-copy rule; Avalonia's `record struct`; GTK4's ten-field POD equality                      |
| ANC2 | The **request** and the **resolved** anchor must be different types, and the solve must never write its resolution back into the request. A design that aliases them is forced to re-introduce the request later.                                                                                                                                                                                                                     | researched  | `D15.C6` (upheld with correction)                                                                                            |
| ANC3 | Anchors must resolve through **clip-aware** producers. `keyTargets` already is one; `keyedRects` and `selectionRects` are **not**, so an anchor resolved through either yields a full rect for a widget scrolled out of its viewport. The missing pieces are a clipped `selectionRects` and an explicit **hidden/clipped flag**, since `keyTargets` drops fully-clipped entries and so cannot distinguish "scrolled out" from "gone". | researched  | `D1.C3` (upheld with correction); `state.d` `keyTargets` `:105`, `keyedRects` `:504`, `selectionRects` `:415`                |
| ANC4 | A point anchor must be a **1×1** cell rect, never `0×0`, and any arrow clamp must **assert** `min <= max` rather than rely on a clamp silently returning `max` where the interval inverts.                                                                                                                                                                                                                                            | researched  | `D1.C8` (narrowed); Avalonia's pointer anchor; react-aria's silent `clamp`                                                   |
| ANC5 | **Tracking is a per-anchor policy field**, not a fixed rule: `latched` is the default for a point/cursor anchor — latched at **press** on the TUI, which has no key release — and `live` remains legitimate. A widget anchor re-resolves per frame because the tree is rebuilt.                                                                                                                                                       | researched  | `D1.C4` (narrowed); WPF/ImGui/Neovim latch, Helix ships a live per-frame point anchor with row hysteresis                    |
| ANC6 | **Anchor liveness** must be a set/identity test over the frame's derived hit list — no observers, no event source. The spec must state that frame-to-frame stability of a hit id is an **authoring convention** (every current consumer derives it from a domain index), not a toolkit guarantee, and the anchor id must be domain-derived.                                                                                           | researched  | `D8.C5` (upheld with correction); `widget.d:101` is a plain author field                                                     |
| ANC7 | The **scope and uniqueness rule for `Widget.key` as an anchor name** must be settled before `Anchor.key` ships. A resolver adopting `keyAt`'s last-in-paint-order-wins would reproduce CSS's documented N-instances-resolve-to-the-last-match failure; `keyedRects`/`keyTargets` return **all** matches, so nearest-ancestor or explicit ambiguity are available.                                                                     | not started | `D1.C6` (upheld with correction); `key` also addresses `ElementStore` ([`WGT5`](./widgets.md))                               |
| ANC8 | A **screen-anchored** surface (toast, notifier) must use the same anchor sum (`corner`) and the same solve, so the primitive count stays at one. It must **not** share band membership, dismissal or modality: a notifier stays visible, focusable and clickable while a modal overlay is open — the opposite of every anchored overlay's contract.                                                                                   | researched  | `D16.C2` (narrowed); three independent witnesses route a screen-anchored surface through the shared engine; `WGT16`, `DEF10` |
| ANC9 | A **multi-rect** anchor (per-row rects for a wrapped text range) is a **latent** requirement, not a v1 one. hue's two TUI sites keep only the first rect, which is harmless today because a hover anchor is a space-free identifier and the wrap engine never splits a word. It becomes load-bearing for a range that can span a wrap point.                                                                                          | not started | `D1.C5` (narrowed); capacity and placement of the rows are open (proposal §3.8)                                              |

## Placement and collision geometry (`PLC`)

`PLC` — the solve: one pure function from anchor, content and boundary to a
decision record.

| ID    | Requirement                                                                                                                                                                                                                                                                                                                                                                                                                             | Status      | Traces to                                                                                                                                                   |
| ----- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| PLC1  | Placement must be **one pure, total function** over Regular values in integer cells — `@safe pure nothrow @nogc` — and covered by **property-based tests** as a lifted algorithm. It must **not** be specified as `@ctfe`-evaluable: `Point`/`Size` are `Vector`-backed unions, so a named-field read is unavailable in CTFE.                                                                                                           | researched  | [`PRN10`](./principles.md), [`PRN11`](./principles.md); `geometry.d:34-40`; `D2.C1` (narrowed)                                                              |
| PLC2  | The solve must return the **whole decision record** — rect, resolved side, resolved alignment, a `fit` verdict including **refused**, which adjustments fired, the arrow cell, whether the arrow could be centred, the room actually available, the anchor in overlay-local cells, the per-side deltas, and the anchor-hidden verdict — never a bare rect and never an offset.                                                          | researched  | `D2.C5` / `D4.C5` / `D14.C8` (all narrowed); `D4.C8` (upheld with correction)                                                                               |
| PLC3  | The **boundary and the coordinate space must be explicit parameters**, never derived inside the solve. The default boundary is the **surface deflated by viewport insets** — not the anchor's clipping ancestor — with a per-overlay override; the clipping ancestor governs only the anchor-hidden verdict.                                                                                                                            | researched  | `D1.C7`, `D3.C3` (both upheld with correction); Compose carries an open bug for exactly this mismatch                                                       |
| PLC4  | Clamping must be to the **boundary**, never to zero. A laid-out position may legitimately be negative (content scrolled above or left of a viewport), so a clamp-to-`0` is wrong for any boundary that does not start at the surface origin. This retires `clampOrigin` and its three divergent call sites.                                                                                                                             | not started | `geometry.d:28-30`; the same structural bug the catalog found in Avalonia's managed positioner                                                              |
| PLC5  | The adjustment precedence is fixed in the **value**, not in a middleware chain: **flip, then slide, then resize**, resize last, floored at `popupMinWidth`/`popupMinHeight`. The adjust mask and the request must stay structurally isomorphic to `(anchor rect, anchor, gravity, constraint-adjustment mask, offset)` so `POP5` stays cheap.                                                                                           | researched  | GTK4's `GdkAnchorHints` and the Wayland positioner both fix this order; `style.d:233`'s doc comment states the **opposite** precedence and must be reworded |
| PLC6  | Flip must mirror the **anchor edge and the gravity together** against the anchor **rect**, and be conditional and reversible; reflecting the placed region about a point is not equivalent. The **flip-acceptance rule** must be an explicit policy field, because "less bad wins" and "revert unless fully unconstrained" produce observably different placements.                                                                     | researched  | `D3.C4`, `D2.C7` (both upheld with correction); the divergence is observable inside one toolkit                                                             |
| PLC7  | The default is **flip on the side axis, slide on the edge axis**; side-axis slide (overlap) must be **opt-in**. It is a shipped policy, not a defect — menu cascades overlap deliberately to convey depth — so the spec forbids it as a default, not as a capability.                                                                                                                                                                   | researched  | `D2.C2` (narrowed — the original "sliding on the side axis is a defect" overreached)                                                                        |
| PLC8  | When the overlay exceeds the boundary on an axis, the **start edge is pinned** and the end overflows. _Sparkles decision:_ this is the majority rule among shift-style implementations and matches the behavior `clampOrigin` already has, but it is a **choice, not a consensus** — Avalonia pins the end edge and Compose centres.                                                                                                    | decided     | `D3.C5` (narrowed)                                                                                                                                          |
| PLC9  | The **side is chosen before the content is laid out**, from a size **bound** rather than a measured size. _Sparkles decision:_ most surveyed subjects measure first and place second, several with no second pass; sparkles adopts decide-then-measure because its own pipeline is `view → layout → buildDisplayList → paint` and the side determines the budget handed to `layout`.                                                    | decided     | `D2.C6` (narrowed); helix's height budget, Base UI's available-height dropdowns                                                                             |
| PLC10 | The **arrow appears twice in the pipeline**: its clearance (0 or 1 cells) is a placement **input**, its cell is a placement **output**, and the resolved **side** must reach the canvases. At cell resolution the arrow is `(side, offsetAlongEdge, visible)`. This retires two live defects: the raylib backend's one-cell divergence from both cell backends, and the complete absence of any clamp of `arrowOffset` against the box. | not started | `D14.C1`, `D4.C2`, `D4.C3` (all upheld with correction); WinUI forked an engine for want of the input half                                                  |
| PLC11 | The result must report **whether the arrow could be centred**, so a consumer can fall back to the categorical alignment instead of trusting a meaningless numeric origin. _Sparkles decision:_ whether that argues for **suppressing** rather than clamping the caret is a judgement — **no cell-grid subject in the corpus has an anchor-pointing caret at all**, and the pixel corpus splits five-to-four.                            | not started | `D4.C6`, `D14.C5` (both narrowed)                                                                                                                           |
| PLC12 | Placement runs **once per frame inside the existing pass**, between `layout()` and display-list consumption, with **no observer machinery** — provided the max-size clamp stays derived from anchor and boundary alone, as `effectivePopupWidth` already is. One-frame correctness is a spec obligation, asserted on a `--render` golden.                                                                                               | researched  | `D3.C1` (upheld with correction); deletes the equivalent of Floating UI's 264-line `autoUpdate`                                                             |
| PLC13 | Placement stability must be an **explicit input field** (the last accepted side), never a hidden memo, because events route against the last painted frame and an oscillating placement is a routing bug rather than a visual one.                                                                                                                                                                                                      | researched  | `D2.C4` (narrowed); baseline cross-cutting constraint 5                                                                                                     |
| PLC14 | Viewport insets must be **per-side** and supplied as inputs — safe area, display cutout, the Android soft keyboard, reserved chrome — and folded into the boundary **before** placement. Two mature toolkits compute the inset and then fail to feed it to popup placement; GTK4's Android backend gets it right by construction.                                                                                                       | researched  | `D12.C8` (upheld with correction); `D2.C9` (narrowed)                                                                                                       |
| PLC15 | Sparkles must **not** reproduce a measurement seam. There is no `getClippingRect` step: the clip stack is already threaded to every node by `childClipOf` and collapsed to one `Rect`, and `layout()` is the measurement.                                                                                                                                                                                                               | decided     | `D3.C9` (upheld with correction)                                                                                                                            |

## Triggers, timing and declared degradation (`TRG`)

`TRG` — what opens an overlay, when, and what a target that cannot serve a
trigger must say instead.

| ID    | Requirement                                                                                                                                                                                                                                                                                                                                                                                                                                                                | Status      | Traces to                                                                                                                     |
| ----- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | ----------------------------------------------------------------------------------------------------------------------------- |
| TRG1  | A trigger set must be a **declaration** (hover, focus-visible, activate, long-press, context-menu), resolved against `InputCapabilities` by a **pure function** returning what is **served**, what is **dropped** and what is **substituted**. A trigger a target cannot serve is a declared degradation, never a silent drop.                                                                                                                                             | researched  | [`TGT5`](./backends.md), [`INP6`](./input.md); `ScrollbarState.expanded(caps)` (`state.d:834`) is the shipped shape (`IXB10`) |
| TRG2  | `TGT5`'s capability set must gain one **additive axis**: whether a **gesture recognizer is wired** on this target. It is not an axis today — the recognizer exists only in `sparkles:ui-raylib` — and the long-press drop rule cannot be resolved without it.                                                                                                                                                                                                              | not started | `D5.C6` (narrowed)                                                                                                            |
| TRG3  | **Tap-to-pin is the only hover substitution expressible on all three live targets** (the terminal decodes SGR-1006 release, raylib derives press/release edges, the Android recognizer emits a tap as press plus release). **Long-press must not be the toolkit's default substitute**: on Android `longPress` is already spent on starting a text selection.                                                                                                              | researched  | `D12.C2`, `D12.C4` (upheld); `D12.C1` (narrowed)                                                                              |
| TRG4  | A **substituted or suppressed** reveal must be **published** — as a stored, readable resolution value, and (when an accessibility channel exists) as a description — or it is a silent product hole. Suppression alone is correct only where the content survives elsewhere.                                                                                                                                                                                               | researched  | `D12.C10` (upheld with correction)                                                                                            |
| TRG5  | The **open cause** must be recorded on the record and readable by the **placement** stage, not only the timing stage. It is **not** sufficient on its own: per-trigger latches must remain for time-scoped suppression, close-cause suppression while shut, and pointer-down-derived focus suppression.                                                                                                                                                                    | researched  | `D5.C3` (narrowed); `D5.C2` **refuted** — the single-enum sufficiency claim is not available                                  |
| TRG6  | The warm-up/rest/cool-down machine is **one new state machine** (`DwellState`, to be recorded as the next free `STM` id, `STM14`), justified against `PRN8` on three verified properties of `Timeline`: `fadeIn` already reports `visible() == true` (so a warming overlay would enter the display **and** hit lists); a cancelled warm-up from `fadeIn` plays a **full-opacity** fade-out; and on the TUI `stepped` is never driven because `frameSeconds()` returns `0`. | researched  | `D6.C3` (upheld with correction); [`STM6`](./state-machines.md)                                                               |
| TRG7  | The cross-instance cool-down must be an **arbiter of two integers** with no per-widget state. Variants derived from live state cannot express "the last one closed 200 ms ago" and are strictly weaker.                                                                                                                                                                                                                                                                    | researched  | `D6.C4` (narrowed); six independent lineages converged on it                                                                  |
| TRG8  | A duration of **zero must statically disable** the feature, never arm a zero-length timer. Radix shipped that bug and fixed it with early returns in both provider callbacks.                                                                                                                                                                                                                                                                                              | researched  | `D6.C7` (upheld with correction)                                                                                              |
| TRG9  | Deadlines must be **absolute** — armed instant plus delay, never recomputed as now plus delay — and the rest gate must be **hit-id stability**, not a pixel threshold. _Sparkles decision:_ id stability is unit-free and exact in cells; the catalog's stronger "strictly cheaper and behaviourally adequate" form was downgraded.                                                                                                                                        | researched  | `D6.C5` (narrowed)                                                                                                            |
| TRG10 | Wall time must be an **injected parameter** of the environment, distinct from `Timeline`'s rendered `dt`. No host exposes "now" and the recorder does not simulate time, so the headless assertion is that the correct deadline was **armed**, not that it fired; the ask itself needs no new host API (`HostState.wakeIn`).                                                                                                                                               | not started | `D6.C2` (narrowed); the weakest joint in the proposal (proposal §3.8)                                                         |
| TRG11 | Hover-intent machinery must be a **declared capability**, not an assumed one: bare-motion reporting is **off by default** on the TUI, so a host that has not opted in has no motion stream at all. On a hoverless target the machinery must be **absent at the source**, not degraded — no subject in the corpus computes hover intent for touch.                                                                                                                          | researched  | `D7.C5`, `D7.C8` (both upheld with correction)                                                                                |
| TRG12 | The default gap between anchor and overlay is **zero cells** — with a zero-cell corridor the entire travel problem does not arise. Where a gap is configured, the corridor must be **an extra entry in the derived hit list** carrying the overlay's own id, so `HoverState`'s last-match rule serves it with no new predicate and no motion history.                                                                                                                      | researched  | `D7.C6` (upheld with correction); `D7.C7` (narrowed); `D7.C1` **refuted** — no claim that a rect always equals a hull         |
| TRG13 | Every **hover- or focus-triggered** overlay must pin `holdUntilDismissed` and make a finite hold unreachable. _Sparkles decision:_ this is a **defaults trap, not a live bug** — `Timeline`'s default config holds for 1200 ms, shorter than any max-display duration in the survey, and every current call site sets an explicit config. The pin stops the next consumer re-entering it.                                                                                  | not started | `D13.C3` (narrowed); WCAG 1.4.13 Persistent                                                                                   |

### Declared overlay degradation per target

This table is the overlay half of [`TGT5`](./backends.md)'s chrome declarations —
the same honest-inventory posture the backends spec already takes, extended so the
toolkit can **act** on a gap rather than document it.

| Overlay feature            | Cell (`GridCanvas`)                       | GPU (`RaylibCanvas`) | Android (GPU)            | Static HTML                                | Recording      |
| -------------------------- | ----------------------------------------- | -------------------- | ------------------------ | ------------------------------------------ | -------------- |
| hover trigger              | served once motion is enabled             | served               | **absent** — substituted | served (`:hover`)                          | driven         |
| bare-motion stream         | **opt-in, off by default**                | served               | n/a                      | **absent**                                 | driven         |
| pointer release            | served (SGR-1006)                         | served               | served (tap)             | **absent**                                 | driven         |
| key release                | **absent** (`INP16`)                      | served               | served                   | **absent**                                 | driven         |
| frame clock                | **absent** (`frameSeconds() == 0`)        | served               | served                   | **absent**                                 | fixed 1/60     |
| warm-up / cool-down        | event-scoped collapse                     | served               | served                   | `transition-delay` approximation           | deadline armed |
| collision solve at runtime | served                                    | served               | served                   | **frozen at emit** — declared, not faked   | served         |
| hoisted emission           | served                                    | served               | served                   | **impossible** — boundary override instead | served         |
| cascade / second overlay   | served                                    | served               | served                   | **one level only**                         | served         |
| arrow                      | one cell                                  | drawn                | drawn                    | native                                     | recorded       |
| shadow                     | **dropped**                               | approximated         | approximated             | native                                     | recorded       |
| scrim foreground dimming   | **absent** without a foreground treatment | served               | served                   | served                                     | recorded       |

> [!IMPORTANT]
> The static-HTML column is the one that decides the design. It cannot hoist, it
> cannot measure and it cannot time, so the primitive must be able to say
> "frozen at emit, one level, no outside-press" as **data**. That is why
> `PLC3`'s boundary is a parameter with an override (`LYR8`) rather than a
> derived value: on HTML the overlay's clipping ancestor **is** the boundary, and
> cross-target parity is bought by **choosing** the boundary, not by pretending
> the escape happened.

## Dismissal (`DSM`)

`DSM` — how an overlay closes, why it closed, and who else closes with it.

| ID    | Requirement                                                                                                                                                                                                                                                                                                 | Status     | Traces to                                                                                              |
| ----- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------- | ------------------------------------------------------------------------------------------------------ |
| DSM1  | Dismissal must be **policy flags ANDed with a cause the router offers**, evaluated by one pure function. The evaluator's inputs must **also** include latched press-phase state, and a separate class of **mandatory** causes (anchor removed, unplaceable) must bypass the policy word entirely.           | researched | `D8.C1` (narrowed); Qt Quick's `tryClose` is the shipped shape                                         |
| DSM2  | The close must carry a **reason** from a closed enum, stored on the record, so dismissal is a **value** the recording canvas can assert rather than an effect it must observe.                                                                                                                              | researched | [baseline §8.5](../../research/anchored-overlays/sparkles-baseline.md); `POP8`                         |
| DSM3  | "Close request" must be spelled once, over `isDismiss` — Escape and the Android system back key are already one equivalence, and releases are already ignored there so a keystroke cannot dismiss twice.                                                                                                    | researched | [`INP13`](./input.md)                                                                                  |
| DSM4  | The outside test must be **two-phase over the overlay's own `PressState` instance**, keyed by surface/group id. `activated` is transient and there is a single armed slot, so sharing the button-activation instance would let an in-overlay button press disarm the overlay's outside test.                | researched | `D8.C2` (upheld with correction); [`STM10`](./state-machines.md)                                       |
| DSM5  | **Dismissal and consumption are independent**: whether the dismissing press also reaches what it hit must be an explicit per-overlay value. The corpus splits on the default, and sparkles routes its own events, so there is no ambient answer to inherit.                                                 | researched | `D11.C6` (upheld with correction)                                                                      |
| DSM6  | Cascading dismissal is a **truncation** of the ordered arena at an index computed by an ancestry predicate. _Sparkles decision (inference):_ a **frame-built** arena dissolves the re-check the popover specification requires, because a reopen during dismissal simply appears in the next frame's arena. | researched | `D10.C10` (narrowed); the strongest single reason the arena is frame-built rather than mutated         |
| DSM7  | The TUI degradation must be **precisely scoped**: what a terminal cannot detect is **window/app deactivation** and **the pointer leaving the terminal window**. Hover-exit **between targets inside the grid** is fully detectable under mouse-motion reporting and must **not** be declared unavailable.   | researched | `D8.C4` (upheld with correction)                                                                       |
| DSM8  | **Anchor gone** must close (mandatory, bypassing the policy word); **anchor clipped** must **hide**, not close. The hide-versus-fit split is a property of the anchor and its clip, known **before** placement, not a verdict computed after it.                                                            | researched | `D3.C3` (upheld with correction); CSS anchor positioning states the split normatively                  |
| DSM9  | An overlay opened **this frame** must be exempt from outside-dismissal for exactly one frame, because events route against the last painted frame's hit data and its rect is therefore one frame stale by construction.                                                                                     | researched | baseline cross-cutting constraint 5; floating-vue's frame lock is the external witness                 |
| DSM10 | On the tier-0 HTML target exactly **one** dismissal cause is expressible with what the emitter produces — trigger re-activation through `details`/`summary` — plus hover-exit for the hover variant. No outside-press, no Escape, no cascade. The gap must be **declared** under `TGT5`, not faked.         | researched | `D8.C6` (narrowed); `html_semantic.d` already carries the disclosure CSS rule with nothing emitting it |
| DSM11 | An application **veto** must be expressed through `POP4`'s plan/apply split, never as a cancelable event object or a hook inside the transition. _Sparkles decision:_ the catalog's mechanical-inversion argument was refuted, so this is a target shape rather than a migration claim.                     | decided    | `D8.C8` (narrowed); `D15.C10` **refuted**                                                              |

## Layering and the top-layer contract (`LYR`)

`LYR` — what a top layer is, who owns the stack, and how it is routed. This
section **discharges [`DCK13`](./containers.md)'s empty top-layers rung**.

| ID    | Requirement                                                                                                                                                                                                                                                                                                                                                                                                                                                                            | Status      | Traces to                                                                                                                 |
| ----- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | ------------------------------------------------------------------------------------------------------------------------- |
| LYR1  | A **top layer** is an entry in one **ordered, frame-built arena** of overlay records, where **index order is paint order is reverse hit order**. Openness is **membership** in that collection, not a per-record boolean; every subject that gets nesting and LIFO dismissal right owns one ordered collection, and the ones keeping only a boolean reconstruct ordering ad hoc.                                                                                                       | researched  | `D15.C4` (narrowed); ImGui's stacks, the popover top layer, Slint's `active_popups`, Headless UI's stack machine          |
| LYR2  | Ordering across overlays is a **closed band vocabulary** — `adorn`, `popup`, `hint`, `notify` — with focus raising **within** a band only, and **no per-overlay integer priority** exposed to callers. _Sparkles decision:_ the fixed named ladder is the convergent choice among in-surface subjects, but the specific four rungs and the refusal of an integer are this project's pick — and Neovim and GPUI, both cell/canvas subjects, do expose an integer.                       | decided     | `D10.C5` (narrowed); the open-integer failure is documented twice in-corpus (a priority chosen "to beat" three strangers) |
| LYR3  | An overlay handle must be **generational** — a slot plus a generation — so a one-frame-stale handle is distinguishable from a live one. _Sparkles decision:_ the corpus supplies the hazard (Slint's monotonic ids; ImGui deliberately never recycling popup names) but not this encoding; it is chosen because the arena is frame-built and staleness is guaranteed, not incidental.                                                                                                  | decided     | proposal §2.3; `PRN6` — the handle stays Regular either way                                                               |
| LYR4  | Each record carries **one parent index**, and the ancestor relation is a **query over list order**, never a stored tree — the parent must be strictly earlier in the list, which is what makes a well-formed tree out of a possibly cyclic graph of connections. Focus containment and scope-keyed modality need **additional per-record scope/kind membership**; the parent link alone does not cover them.                                                                           | researched  | `D10.C3` (narrowed); `D16.C5` (narrowed — Angular CDK's flat array is viable only where the host supplies containment)    |
| LYR5  | The arena is owned by the **container tier** and tested **front-to-back at `DCK13`'s rung — before the positional query**. This is required for **positional** routing, not only for the non-positional decisions: `DockContainer` resolves the pane **by rect** first, so an overlay that geometrically escapes its pane would otherwise be routed to the neighbouring pane and never reach its own target list.                                                                      | not started | `D10.C4` **refuted** the "not needed for positional routing" claim; [`DCK13`](./containers.md), [`INP10`](./input.md)     |
| LYR6  | **Capture still wins.** The rung sits _below_ pointer capture and the gesture owner in the precedence, and `CaptureState`'s no-transfer rule must not gain a priority exemption for overlays. A drag that began outside an overlay is exempt from every outside-dismissal cause until it releases.                                                                                                                                                                                     | researched  | [`STM11`](./state-machines.md), [`DCK8`](./containers.md); proposal §4.0                                                  |
| LYR7  | An overlay must be excluded from its host's **flow accumulation** — natural-size measurement and placement — or an open dropdown resizes or displaces its host box. Sparkles' scroll extent is application-supplied, so the scrollbar symptom the corpus reports does not arise here; the **layout** exclusion still does.                                                                                                                                                             | researched  | `D10.C8` (narrowed); Textual's order/clip/extent triple                                                                   |
| LYR8  | A top layer requires **no new backend capability**: `isCanvas!T` is unchanged and no canvas gains an operation, because the clip pair is already an optional introspected capability and ops appended after the root walk's balanced pops land unclipped. The toolkit-side work is display-list emission, hit-target derivation and the **layout** walk. The HTML emitters, which walk the tree rather than the list, are the exception and take a **boundary override** hook instead. | researched  | `D10.C1`, `D10.C2` (both narrowed); [`TGT1`](./backends.md) unchanged                                                     |
| LYR9  | An invisible overlay must be represented by **absence from this frame's arena**, not by a visibility flag. _Sparkles decision:_ this is not a corpus law (Textual retains invisible widgets behind a flag and derives both views from it); sparkles adopts membership because its paint walk and its **two** hit walks would each have to honour a flag independently and one of them will forget.                                                                                     | decided     | `D10.C9` (narrowed); Neovim and Notcurses model visibility as membership                                                  |
| LYR10 | An overlay **animating out** must contribute paint but **no hit entry**, because events already route against the last painted frame and a closing surface would otherwise keep swallowing input for the length of its fade.                                                                                                                                                                                                                                                           | researched  | `D11.C9` (narrowed)                                                                                                       |
| LYR11 | The rung must route **keys**, not only pointers, with **first refusal**: an overlay sees the key first and an unbound key falls **through** rather than being swallowed.                                                                                                                                                                                                                                                                                                               | not started | `D9.C10` (narrowed); the rung routes only pointers today                                                                  |
| LYR12 | Each band must have a named owner, and the vocabulary is justified by its waiting consumers: `adorn` carries [`DCK5`](./containers.md)'s finished dock hint; `popup` is the **only** band that participates in the dismissal stack; `hint` is never a dismissal parent and never focusable; `notify` carries `WGT16`/`DEF10`, which must stay visible and clickable while a modal overlay is open.                                                                                     | researched  | proposal §2.3; [`WGT16`](./widgets.md); [hue notifier `NTF`](../hue/notifier.md)                                          |

## Modality and focus (`MDL`)

`MDL` — who may be hit, who may be focused, and what the toolkit refuses to
model. (`MOD` is taken by hue's specs; this area is `MDL`.)

| ID    | Requirement                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   | Status                                                                                                                  | Traces to                                                                                                       |
| ----- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| MDL1  | Pointer modality is a **hit-list filter**, not a mode: a behavior value declared on the node, carried into the derived targets, and applied as "find the highest blocking entry containing the point and ignore everything below it". The cut must cover **both** `hoverTargets` and the parallel `keyTargets`/`keyAt` list — a change to `HoverState.update` alone is **not** sufficient.                                                                                                    | researched                                                                                                              | `D11.C3` (narrowed); `state.d:133-141`                                                                          |
| MDL2  | Modality must be **declared on the overlay and derived on the open stack at hit time**, never cached as a mutable flag on a shared object. Every subject that stored stack-derived blocking as a flag shipped a defect from it.                                                                                                                                                                                                                                                               | researched                                                                                                              | `D11.C4` (narrowed)                                                                                             |
| MDL3  | Focus policy must be a **value on the spec**, and the primitive must forbid a shared **default** across surface kinds while permitting a shared **implementation**. No subject examined applies one focus behavior to tooltip, menu and dialog alike.                                                                                                                                                                                                                                         | decided                                                                                                                 | `D16.C1` (narrowed); Containment is four enum values, not four control types (WinUI's lesson)                   |
| MDL4  | A `focusTargets` derivation and a **focus-order splice** are genuinely new, because **sparkles owns no focus order at all** — `FocusState` is one focused id traversed over a caller-supplied order array, and the only such array in the repository is hand-written in a gallery page. An overlay's ids splice in immediately **after its trigger's**, which is what lets an overlay be appended last without breaking Tab. Focus-visible and menu-mode entry must be bound to key-**down**. | not started                                                                                                             | `D9.C1` (upheld with correction); `D9.C3` (narrowed); `D9.C5` **refuted** — key-release parity is not available |
| MDL5  | `FocusState.moved` always wraps and has no result meaning "the edge was reached, leave this order", so it can express a contained or modal scope but **not** a non-modal overlay that hands focus back. An additive result is required before `MDL4` ships.                                                                                                                                                                                                                                   | full — `sparkles.ui.focus.move` returns `FocusMove{state, leftEdge}` without wrapping ([keymap.md `FOC1`](./keymap.md)) | `D9.C4` (narrowed)                                                                                              |
| MDL6  | Focus **restoration** must be guarded by "is focus still inside the closing overlay", or the toolkit fights the application. Six independent implementations in the corpus carry this guard.                                                                                                                                                                                                                                                                                                  | researched                                                                                                              | `D9.C8` (upheld with correction)                                                                                |
| MDL7  | **Initial focus must be actively suppressed** for a touch-opened overlay, not merely defaulted off, so the soft keyboard does not open and consume the placement budget. Three independent implementations suppress it, each naming touch or Android explicitly.                                                                                                                                                                                                                              | researched                                                                                                              | `D9.C6` (narrowed)                                                                                              |
| MDL8  | A tooltip's **non-interactivity must be enforced by the type of its content** — text, not a widget tree — and it must contribute no hit entry. A hover surface containing focusable content is a **different widget**, not a tooltip configuration; three implementations enforce this structurally.                                                                                                                                                                                          | researched                                                                                                              | `D13.C5` (upheld with correction); `D9.C9` (narrowed)                                                           |
| MDL9  | A **scrim** needs no new canvas primitive, but the cell canvases need a **foreground treatment** for parity: their fill blends only the cell background, so a scrim darkens the ground and leaves the glyph at full brightness, while the GPU and HTML targets dim both. The cheapest parity is the already-existing foreground alpha.                                                                                                                                                        | researched                                                                                                              | `D11.C2` (upheld with correction); `D11.C1` (narrowed)                                                          |
| MDL10 | The primitive must carry **no accessibility role vocabulary**: no sparkles backend emits any ARIA/role/UIA today and accessibility is an explicit non-goal in the TUI spec, so the aria-hidden/inert/refcount apparatus has no home. The one obligation kept is `TRG4`'s publication of a substituted trigger. `Slot` already claims the word "role" for style.                                                                                                                               | decided                                                                                                                 | `D11.C7`, `D13.C1` (both upheld with correction)                                                                |
| MDL11 | Modality must **not** be specified in terms of an OS grab or a nested event loop. `UI-O3` stays open; the primitive owes it a model that does not **assume** a grab, so acquiring one later is an improvement rather than a precondition.                                                                                                                                                                                                                                                     | decided                                                                                                                 | `D11.C8` (narrowed); [`UI-O3`](./open-issues.md#ui-o3), [`INP9`](./input.md)                                    |

## Retiring the named open defects

Each defect is retired by a specific requirement, and closing it is a milestone
acceptance gate rather than a side effect.

| Defect                                                                           | What it says today                                                                                      | Retired by                              | Gate |
| -------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- | --------------------------------------- | ---- |
| [`IXR26`](./interaction-review.md) — "the twoslash popup still assumes hover"    | partly resolved by `IXB10`; the scrollbars read the capability, the popup does not                      | `TRG1`, `TRG3`, `TRG4`                  | V2   |
| [`DCK5`](./containers.md) tail — a finished overlay view with no host            | "complete on the container side; what remains is a host positioning that overlay on its top layer"      | `LYR1`, `LYR12` (`adorn`), `PLC2`       | V1   |
| [`DCK13`](./containers.md) — the empty top-layers rung                           | the precedence is written and implemented with the rung unoccupied                                      | `LYR1`, `LYR4`, `LYR5`, `LYR6`, `LYR11` | V1   |
| `clampOrigin` divergence — one behavior, three implementations, three boundaries | one axis, one direction, against one scalar extent, clamped to `0`, from three call sites that disagree | `PLC1`, `PLC3`, `PLC4`, `PLC5`          | V0   |
| The four hard-coded arrow edges and the unclamped `arrowOffset`                  | all four canvases place the arrow on the top edge; nothing clamps it against the box                    | `PLC10`, `PLC11`                        | V1   |
| `WidgetKind.popup` promising "detached from flow"                                | no `case popup:` exists anywhere under `libs/ui/src`                                                    | `POP6`, `LYR7`                          | V1   |

> [!WARNING]
> [`UI-O3`](./open-issues.md#ui-o3) (the missing native pointer grab) **cannot**
> be retired by this work — it is a windowing-system concern owned by the input
> adapter, and its fix must be validated against the end-to-end windowing
> harness. `MDL11` is the obligation this spec takes on instead: nothing here may
> be specified in terms of a grab.

## Milestones

| Milestone | Scope                                                                                                   | Acceptance gate                                                                                                                                                                                                                                       | Requirements                                                     |
| --------- | ------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------- |
| V0        | The solve: `Anchor`/`AnchorRect`, `place()`, the boundary and insets, the environment value             | `place()` is `@safe pure nothrow @nogc` with property tests over random anchor/content/boundary triples asserting the result is inside the boundary or reports `refused`, never clamped to `0`; `clampOrigin` and its three call sites are deleted    | `ANC1`–`ANC6`, `PLC1`–`PLC9`, `PLC12`–`PLC15`                    |
| V1        | The arena: bands, ids, parent links, the three resets, `DCK13`'s rung, the arrow result                 | the dock hint is positioned by the toolkit on the `adorn` band with no host arithmetic; a `--render` golden shows an overlay escaping its pane and receiving the click that lands on it; all four canvases read the resolved side and clamp the arrow | `POP3`, `POP6`–`POP8`, `LYR1`–`LYR10`, `LYR12`, `PLC10`, `PLC11` |
| V2        | Triggers and dismissal: declaration, capability resolution, the reason-tagged evaluator, cascade        | `IXR26` closes — the twoslash popup opens by the resolved trigger on every target and the substitution is readable; a recording test asserts the dismissal **reason** for each cause, including the mandatory ones                                    | `TRG1`–`TRG5`, `TRG11`–`TRG13`, `DSM1`–`DSM10`                   |
| V3        | Timing and focus: `DwellState`, the cool-down arbiter, `focusTargets`, containment, modality            | the warm-up is asserted headlessly as an **armed deadline**; the TUI collapses every timing behavior to an event-scoped equivalent with the collapse declared; Tab traverses into an overlay spliced after its trigger and back out                   | `TRG6`–`TRG10`, `MDL1`–`MDL9`, `LYR11`                           |
| V4        | Advanced: corridors, live tracking, multi-rect anchors, the discrete reveal projection, the native hook | each item ships **behind a declared capability** and is absent — not degraded — where the capability is absent; the native-positioner hook is exercised by a stub asserting the request round-trips unchanged                                         | `ANC9`, `TRG12` (hull), `ANC5` (live), `POP5`                    |

Sequenced solve-first because every other milestone consumes `OverlayGeometry`,
and because V0 alone deletes the `PRN8` violation three applications are
currently paying for. V1 is the milestone that makes the primitive **exist** as a
routing concept; nothing above it can be tested without the arena.

## Module coverage

| Source file                                                       | Requirements                                            |
| ----------------------------------------------------------------- | ------------------------------------------------------- |
| `libs/ui/src/sparkles/ui/overlay/anchor.d` _(planned)_            | `ANC1`–`ANC9`                                           |
| `libs/ui/src/sparkles/ui/overlay/place.d` _(planned)_             | `PLC1`–`PLC15`                                          |
| `libs/ui/src/sparkles/ui/overlay/arena.d` _(planned)_             | `POP4`, `POP7`, `LYR1`–`LYR4`, `LYR9`, `LYR10`, `LYR12` |
| `libs/ui/src/sparkles/ui/overlay/policy.d` _(planned)_            | `TRG1`–`TRG5`, `DSM1`–`DSM6`, `DSM11`, `MDL2`, `MDL3`   |
| `libs/ui/src/sparkles/ui/overlay/package.d` _(planned)_           | re-exports only — no unittests may live here            |
| `libs/ui/src/sparkles/ui/state.d`                                 | `ANC3`, `TRG6`–`TRG9`, `MDL1`, `MDL4`–`MDL8`            |
| `libs/ui/src/sparkles/ui/widget.d`                                | `POP3`, `POP6`, `MDL1`                                  |
| `libs/ui/src/sparkles/ui/layout.d`                                | `LYR7`, `PLC12`                                         |
| `libs/ui/src/sparkles/ui/display_list.d`                          | `LYR8`, `PLC10`                                         |
| `libs/ui/src/sparkles/ui/style.d`                                 | `PLC5` (metric doc), `PLC10` (resolved side), `MDL9`    |
| `libs/ui/src/sparkles/ui/dock.d`                                  | `LYR5`, `LYR6`, `LYR12`                                 |
| `libs/ui/src/sparkles/ui/interp/cells.d`                          | `PLC10`                                                 |
| `libs/ui/src/sparkles/ui/interp/html.d`, `interp/html_semantic.d` | `POP3`, `LYR8` (boundary override), `DSM10`, `PLC10`    |
| `libs/ui-tui/src/sparkles/ui_tui/grid_canvas.d`                   | `PLC10`, `MDL9`                                         |
| `libs/ui-raylib/src/sparkles/ui_raylib/raylib_canvas.d`           | `PLC10`                                                 |
| `libs/input/src/sparkles/input/capability.d`                      | `TRG2`, `TRG11`                                         |
| `libs/twoslash/src/sparkles/twoslash/render_widgets.d`            | `PLC4` (`clampOrigin` deleted), `PLC10`                 |
| `apps/hue/src/gui.d`, `tui.d`, `twoslash_tui.d`                   | adoption sites — `PLC4`, `TRG1`, `TRG3`                 |
| `apps/ui-gallery/src/pages/` _(new overlay page)_                 | `POP8`                                                  |

## Relationship to existing specs

| Piece                                                                               | Role                                                                                                      |
| ----------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| [Anchored-overlay catalog](../../research/anchored-overlays/index.md)               | the evidence base — 38 subjects, the ten questions, the baseline and the verdict ledger                   |
| [principles.md](./principles.md) `PRN6`–`PRN8`, `PRN11`                             | the value-semantics, single-definition and property-test rules every requirement here is written against  |
| [state-machines.md](./state-machines.md) `STM4`–`STM11`                             | the machines this primitive **composes**; `TRG6` is the only new one and carries its `PRN8` justification |
| [input.md](./input.md) `INP10`, `INP13`, `INP14`, `INP16`                           | the hit-testing model, the dismiss equivalence, the capability axes and the missing key release           |
| [containers.md](./containers.md) `DCK5`, `DCK13`                                    | the homeless overlay view and the empty routing rung this spec fills                                      |
| [backends.md](./backends.md) `TGT5`, `TGT10`                                        | declared degradation — the overlay table above is its chrome half — and the parity harness                |
| [widgets.md](./widgets.md) `WGT7`, `WGT13`, `WGT16`                                 | the `popup` kind this spec re-defines, and the two consumers it stays out of                              |
| [theme.md](./theme.md) `THM3`                                                       | the resolved `Visual` that must learn the arrow's side                                                    |
| [layout.md](./layout.md) `LAY3`                                                     | the integer-cell rule that makes the solve exact and the caret categorical                                |
| [open-issues.md](./open-issues.md) `UI-O2`, `UI-O3`                                 | the tagged widget payload `POP6` depends on, and the grab `MDL11` refuses to assume                       |
| [window-system-integration](../../research/window-system-integration/index.md)      | the eventual native path `POP5` must not foreclose                                                        |
| [hue notifier](../hue/notifier.md) `NTF`, [`DEF10`](../hue/feature-requirements.md) | the `notify` band's waiting consumer, which shares the solve and nothing else                             |

→ [Overview](./index.md) · [Input](./input.md) · [Containers](./containers.md)
