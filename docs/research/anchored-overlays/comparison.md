# Anchored overlays — the comparison

Thirty-eight systems, read at pinned revisions, cut along sixteen dimensions. This is
the capstone: what the field agrees on, where it genuinely disagrees, how the strongest
implementations are shaped internally, and which of it survives on a toolkit that paints
every overlay into **one surface**, in **integer cells**, on targets that variously lack
hover, key releases, scripting, a frame clock and an OS window.

**Last reviewed:** August 14, 2026

The per-subject readings are in the [master catalog][index]; the shared vocabulary is in
[`concepts.md`][concepts]; the behaviours nobody remembers until they ship are in
[`features-people-forget.md`][forget]; what `sparkles:ui` can express today is in
[`sparkles-baseline.md`][baseline]; the milestoned plan is in [`proposal.md`][proposal].

Four neighbouring surveys carry material this page deliberately does not restate: the
compositor grab, the X11 override-redirect alternative and the in-canvas fork are in
[window-system-integration][wsi]; the platform conventions an overlay's chrome must
respect are in [platform-ui-guidelines][pug]; the box-flow model an overlay's _content_
is laid out by is in [ui-layout][ui-layout]; and the value-semantics vocabulary the
recommendations lean on — Regular types, local reasoning, narrow contracts — is in
[sean-parent][sean-parent]. The toolkit rules being tested against are the
[UI principles][spec-prn] (`PRN1`–`PRN12`), the [state machines][spec-stm]
(`STM1`–`STM13`), the [input model][spec-input] (the tier ladder and the hit-testing
model), the [container routing precedence][spec-dck] (`DCK13`, whose top-layers rung is
empty, and `DCK5`), the [backend degradation inventory][spec-tgt] (`TGT5`), and the
[widget catalog][spec-wgt] (`WGT7`'s popup, `WGT16`'s toast).

> [!IMPORTANT]
> Every load-bearing statement on this page passed a two-lens adversarial verification
> pass, and a large fraction of the first-pass claims did not. Where a claim was
> narrowed, the narrower wording is what appears here — see
> [How this survey was verified](#how-this-survey-was-verified) for the counts and the
> failure taxonomy. Statements that are analysis rather than observation are marked
> **INFERENCE**.

---

## At a glance

Twelve capabilities against all thirty-eight subjects, grouped by category so the rows
stay comparable. Values use a fixed vocabulary:

| Value         | Meaning                                                                                    |
| ------------- | ------------------------------------------------------------------------------------------ |
| `native`      | the substrate supplies it — compositor, window manager, browser engine, or OS presentation |
| `built in`    | the subject implements it in its own library code, available by default                    |
| `plugin`      | present, but in a separate opt-in package/module of the same project                       |
| `partial`     | present and restricted, incomplete, or divergent between the subject's own code paths      |
| `app`         | application responsibility — the subject exposes the seam and decides nothing              |
| `unsupported` | absent, and in several cases deliberately so                                               |

> [!NOTE]
> The matrix compresses; the deep-dives are authoritative. A `partial` almost always
> means something specific and interesting, and the per-dimension sections below say
> what.

### Web — headless behaviour and positioning

| Capability                 | [floating-ui][floating-ui] | [radix][radix] | [base-ui][base-ui] | [ariakit][ariakit] | [zag][zag] | [headlessui][headlessui] | [floating-vue][floating-vue] | [tippy][tippy] | [angular-cdk][angular-cdk] | [react-aria][react-aria] |
| -------------------------- | -------------------------- | -------------- | ------------------ | ------------------ | ---------- | ------------------------ | ---------------------------- | -------------- | -------------------------- | ------------------------ |
| Placement solver           | built in                   | built in       | built in           | built in           | built in   | built in                 | built in                     | built in       | built in                   | built in                 |
| Resolved side reported     | built in                   | built in       | built in           | built in           | built in   | built in                 | built in                     | built in       | built in                   | built in                 |
| Arrow geometry             | built in                   | built in       | built in           | partial            | partial    | unsupported              | partial                      | built in       | unsupported                | partial                  |
| Overlay stack + cascade    | plugin                     | partial        | built in           | partial            | partial    | built in                 | partial                      | partial        | plugin                     | built in                 |
| Outside-press dismissal    | plugin                     | built in       | built in           | built in           | partial    | built in                 | built in                     | built in       | app                        | built in                 |
| Hover-travel corridor      | built in                   | built in       | built in           | built in           | built in   | partial                  | partial                      | built in       | plugin                     | built in                 |
| Warm-up / skip-delay       | plugin                     | built in       | built in           | built in           | partial    | unsupported              | partial                      | built in       | plugin                     | built in                 |
| Focus containment          | plugin                     | built in       | built in           | built in           | plugin     | built in                 | partial                      | partial        | plugin                     | built in                 |
| Modality / input blocking  | partial                    | partial        | partial            | built in           | partial    | built in                 | unsupported                  | unsupported    | partial                    | built in                 |
| Accessibility semantics    | plugin                     | built in       | partial            | built in           | built in   | built in                 | partial                      | built in       | plugin                     | built in                 |
| Adaptive presentation      | partial                    | unsupported    | unsupported        | app                | partial    | partial                  | app                          | partial        | partial                    | partial                  |
| Explicit lifecycle machine | unsupported                | partial        | partial            | partial            | built in   | built in                 | unsupported                  | unsupported    | unsupported                | partial                  |

### Web platform

| Capability                 | [popover-api][popover-api] | [css-anchor][css-anchor] | [blink][blink] | [aria-apg][aria-apg] |
| -------------------------- | -------------------------- | ------------------------ | -------------- | -------------------- |
| Placement solver           | unsupported                | native                   | native         | app                  |
| Resolved side reported     | unsupported                | partial                  | partial        | unsupported          |
| Arrow geometry             | unsupported                | unsupported              | unsupported    | partial              |
| Overlay stack + cascade    | native                     | unsupported              | native         | partial              |
| Outside-press dismissal    | native                     | unsupported              | native         | partial              |
| Hover-travel corridor      | unsupported                | unsupported              | built in       | unsupported          |
| Warm-up / skip-delay       | unsupported                | unsupported              | native         | partial              |
| Focus containment          | native                     | unsupported              | native         | built in             |
| Modality / input blocking  | unsupported                | unsupported              | native         | built in             |
| Accessibility semantics    | partial                    | unsupported              | native         | native               |
| Adaptive presentation      | partial                    | native                   | partial        | partial              |
| Explicit lifecycle machine | native                     | unsupported              | native         | partial              |

### Native desktop

| Capability                 | [qt-quick][qt-quick] | [qt-widgets][qt-widgets] | [gtk4][gtk4] | [wpf][wpf]  | [winui][winui] | [uno][uno]  | [avalonia][avalonia] | [slint][slint] | [gpui][gpui] | [imgui][imgui] |
| -------------------------- | -------------------- | ------------------------ | ------------ | ----------- | -------------- | ----------- | -------------------- | -------------- | ------------ | -------------- |
| Placement solver           | built in             | built in                 | built in     | built in    | built in       | built in    | built in             | partial        | built in     | built in       |
| Resolved side reported     | unsupported          | partial                  | built in     | partial     | partial        | unsupported | unsupported          | unsupported    | unsupported  | partial        |
| Arrow geometry             | unsupported          | partial                  | built in     | unsupported | built in       | built in    | unsupported          | unsupported    | unsupported  | unsupported    |
| Overlay stack + cascade    | built in             | built in                 | built in     | built in    | built in       | built in    | built in             | built in       | built in     | built in       |
| Outside-press dismissal    | built in             | built in                 | native       | built in    | built in       | built in    | built in             | built in       | built in     | built in       |
| Hover-travel corridor      | partial              | built in                 | built in     | built in    | built in       | built in    | built in             | unsupported    | built in     | built in       |
| Warm-up / skip-delay       | built in             | built in                 | built in     | built in    | built in       | built in    | built in             | partial        | built in     | built in       |
| Focus containment          | built in             | built in                 | built in     | built in    | built in       | built in    | built in             | built in       | built in     | built in       |
| Modality / input blocking  | built in             | native                   | native       | native      | built in       | built in    | partial              | built in       | built in     | built in       |
| Accessibility semantics    | built in             | built in                 | partial      | built in    | built in       | built in    | partial              | built in       | partial      | partial        |
| Adaptive presentation      | built in             | partial                  | partial      | partial     | built in       | partial     | built in             | built in       | partial      | partial        |
| Explicit lifecycle machine | partial              | partial                  | partial      | unsupported | unsupported    | unsupported | unsupported          | unsupported    | partial      | unsupported    |

### Mobile and adaptive

| Capability                 | [compose][compose] | [flutter][flutter] | [apple][apple] |
| -------------------------- | ------------------ | ------------------ | -------------- |
| Placement solver           | app                | built in           | native         |
| Resolved side reported     | unsupported        | unsupported        | native         |
| Arrow geometry             | built in           | built in           | native         |
| Overlay stack + cascade    | native             | built in           | native         |
| Outside-press dismissal    | built in           | built in           | native         |
| Hover-travel corridor      | partial            | partial            | unsupported    |
| Warm-up / skip-delay       | partial            | built in           | native         |
| Focus containment          | native             | built in           | native         |
| Modality / input blocking  | native             | built in           | native         |
| Accessibility semantics    | built in           | built in           | native         |
| Adaptive presentation      | built in           | built in           | native         |
| Explicit lifecycle machine | partial            | partial            | native         |

### Terminal and cell grid

| Capability                 | [helix][helix] | [neovim][neovim] | [notcurses][notcurses] | [nui][nui]  | [nvim-cmp][nvim-completion] | [ratatui][ratatui] | [textual][textual] | [tmux][tmux] | [turbo-vision][turbo-vision] | [posframe][emacs-posframe] |
| -------------------------- | -------------- | ---------------- | ---------------------- | ----------- | --------------------------- | ------------------ | ------------------ | ------------ | ---------------------------- | -------------------------- |
| Placement solver           | built in       | app              | partial                | partial     | built in                    | partial            | built in           | built in     | partial                      | built in                   |
| Resolved side reported     | unsupported    | built in         | unsupported            | unsupported | partial                     | unsupported        | unsupported        | unsupported  | unsupported                  | unsupported                |
| Arrow geometry             | unsupported    | partial          | partial                | unsupported | unsupported                 | unsupported        | unsupported        | partial      | partial                      | unsupported                |
| Overlay stack + cascade    | built in       | built in         | built in               | app         | built in                    | app                | built in           | built in     | built in                     | app                        |
| Outside-press dismissal    | partial        | app              | partial                | app         | unsupported                 | app                | built in           | built in     | built in                     | built in                   |
| Hover-travel corridor      | unsupported    | unsupported      | unsupported            | unsupported | unsupported                 | unsupported        | unsupported        | unsupported  | built in                     | unsupported                |
| Warm-up / skip-delay       | built in       | app              | unsupported            | unsupported | built in                    | unsupported        | partial            | unsupported  | partial                      | built in                   |
| Focus containment          | partial        | built in         | unsupported            | built in    | built in                    | app                | built in           | built in     | built in                     | built in                   |
| Modality / input blocking  | built in       | unsupported      | unsupported            | built in    | built in                    | app                | built in           | built in     | built in                     | built in                   |
| Accessibility semantics    | unsupported    | unsupported      | unsupported            | unsupported | unsupported                 | partial            | unsupported        | partial      | built in                     | built in                   |
| Adaptive presentation      | built in       | partial          | partial                | partial     | partial                     | unsupported        | built in           | partial      | partial                      | built in                   |
| Explicit lifecycle machine | partial        | unsupported      | partial                | unsupported | partial                     | app                | partial            | partial      | partial                      | partial                    |

### Protocol

| Capability                 | [xdg_positioner][xdg] |
| -------------------------- | --------------------- |
| Placement solver           | native                |
| Resolved side reported     | unsupported           |
| Arrow geometry             | unsupported           |
| Overlay stack + cascade    | native                |
| Outside-press dismissal    | native                |
| Hover-travel corridor      | unsupported           |
| Warm-up / skip-delay       | unsupported           |
| Focus containment          | native                |
| Modality / input blocking  | partial               |
| Accessibility semantics    | unsupported           |
| Adaptive presentation      | partial               |
| Explicit lifecycle machine | native                |

Two patterns fall straight out of the grid. **The terminal column is the sparse one, and
it is sparse in exactly the places a compositor or a browser was doing the work** —
accessibility, hover corridors, modality — not in placement, stacking or dismissal, which
the cell-grid subjects implement as well as anyone. And **`Resolved side reported` is the
most-failed row in the entire matrix**: of the thirty-eight subjects, only a minority
return the post-flip side from placement, and the ones that do not are the ones with
duplicated collision math downstream.

---

## The sixteen dimensions

### 1. Anchor model

Every engine surveyed reduces whatever it was handed to **one axis-aligned integer rect
(a point being a degenerate rect)** before any placement arithmetic runs, and nothing
downstream touches the original again. The variation is entirely upstream of that seam.
Four algorithms compete: an **opaque rect-provider behind one platform function**
(Floating UI's `platform.getElementRects`, with `ReferenceElement = any`, so the engine
is anchor-agnostic by construction); a **single-seam reduction** where an element or
visual is collapsed at exactly one named place (Compose's `updateParentBounds`, Avalonia's
`CalculateAnchorRect`, GTK4's `GdkPopupLayout` — which alone gives the reduced value a
public equality function); a **caller-owned POD tuple** with no handle anywhere
(`xdg_positioner`, Neovim's `WinConfig`, tmux's expression language over ~17 named cell
coordinates, ratatui's `Copy + Eq + Hash` `Rect`); and a **tree-scoped name with an
acceptability ordering** (CSS anchor positioning: nearest ancestor carrying the name,
else the last in tree order, legal only if laid out strictly before the querying box).

Two further families matter for a text-heavy toolkit. **Multi-rect line-set resolution** —
Floating UI's `inline()` groups a wrapped run's client rects into lines and picks the one
under the pointer; Base UI improves on it by preferring the line index _captured at
trigger time_, so a delayed open still uses the line the pointer was on; Compose, Ariakit
and Angular CDK take the union bounding box instead, which for a run wrapping near
opposite margins places the overlay in the middle of nowhere. And **latch-versus-live
tracking as a property of the anchor rather than a global setting** — GPUI is the only
subject that makes it a first-class field (`PinnedToScreen(Point) | PinnedToEditor{source, offset}`),
while WPF, ImGui and Neovim all latch a cursor anchor at open with the reason written down
(WPF's is that a content-size animation would otherwise make the popup chase the mouse).
Tracking is a **per-anchor policy**, not a universal rule: Helix ships a live per-frame
cursor anchor with row hysteresis on a resizable popup and exhibits no artefact.

**Best in class: Floating UI.** It is the only subject that answers every sub-question
through one abstraction rather than N special cases — element anchor, virtual anchor,
cursor anchor with per-axis pinning, multi-rect text-range anchor, detached
trigger-versus-anchor, and moving anchors — and the decisive evidence for a canvas toolkit
is that Floating UI's own website instantiates its platform as `getElementRects: (data) => data`,
the identity function. The library already runs in exactly the configuration a canvas
toolkit is in. Its one property not to copy — the anchor as a closure — is a DOM
concession that Tippy's independent reading names "pure DOM-retained-mode tax". _Runner-up:_
`xdg_positioner`, strictly better on the narrow question, because it is the only subject
whose anchor is a **normatively copied value** ("the compositor makes a copy of the rules
… the object can be destroyed or reused") proven sufficient across roughly twenty
independent compositors separated by a socket.

> [!NOTE]
> Handles are not used solely for re-measurement, and the survey's first-pass claim that
> they were did not survive. Floating UI keeps a handle for clipping-ancestor discovery
> and scroll-dismissal scoping; Ariakit consults `isConnected` for anchor liveness
> arbitration; Blink and Uno hold weak references so the anchor can die under the popup.
> Each needs an explicit value-shaped substitute, not an assumption that it disappears.

### 2. Placement model

Six placement algorithms, and one strong convergence: **placement is integer arithmetic
over four rects and a small policy value**, and nothing in it needs a window, a
compositor, hover, a key release or sub-cell precision. The families differ on three
axes. _Candidate generation_: per-axis adjustment bits (`xdg_positioner`, GTK4, Textual's
`Region.constrain`, Qt Quick's six booleans, Slint) versus an ordered candidate list
(Floating UI's generated `[oppositeAlignment, opposite, oppositeAlignment(opposite)]`,
WinUI/Uno's hard-coded per-side tables, Compose's two independent per-axis `IntList`s,
ImGui's fixed four-direction order, CSS `position-try-fallbacks`) versus no candidates at
all — a free-space heuristic that picks a side and hands that side's room to layout as a
budget (Helix, Neovim's LSP path, GPUI's editor, Flutter's `positionDependentBox`).
_Overflow measurement_: a boolean containment test, a scalar overflow "badness" (GTK4), or
a real objective — visible area (Angular CDK, WPF, Qt Quick) or available-box size
(CSS `position-try-order`). _And what happens when nothing fits_, which is the question
most libraries answer worst: revert and overflow (WinUI, Blink, Uno), clamp the least-bad
in (ImGui, CDK tier 3, GPUI), shrink (`xdg` resize, Qt, Helix, React Aria), refuse to open
(WinUI's `TeachingTip`, tmux, blink.cmp, Neovim's `pum_adjust_info_position`), or punt to
a host that clips — which a single-surface toolkit cannot do, because it _is_ the host.

Two rules are near-universal. **Flip on the side axis, slide on the edge axis** — GTK4
states the pairing four times and never violates it, Helix enforces non-coverage
structurally, and every subject that permits cross-axis shift makes it opt-in (Ariakit's
`overlap`, Base UI's `shift.crossAxis`, Apple's `canOverlapSourceViewRect`, all defaulting
off). Side-axis _clamping_ after a flip has been attempted is a different thing and is the
standard terminal step in CDK and GPUI; deliberate side-axis overlap is a shipped policy
for menu cascades in ImGui and Turbo Vision. And **the boundary is an input, never a
discovery**: WinUI intersects the input-pane occlude rect and re-runs placement, GTK4's
Android backend subtracts the IME inset from the toplevel so the constraint box shrinks by
construction, Flutter deflates by `MediaQuery` view insets, tmux and Neovim pass status
lines and `above_ch` in — while Compose, React Aria and Angular CDK all discover it and
all carry documented soft-keyboard defects.

**Best in class: GTK4's `GdkPopupLayout` + `gdk_surface_layout_popup_helper`.** It is the
only implementation that is simultaneously complete (flip, slide and resize, per axis,
with a documented precedence, terminating in a defined rect in every case), pure integer
(~110 lines of `+`, `-`, `*`, `/2`, `min`, `max`, no measurement inside the solver),
per-axis independent (a six-bit mask, so no candidate combinatorics), value-shaped (the
result carries the _mirrored gravities_, so the resolved side comes out of the solver), and
forward-compatible (it is the reference client implementation of the semantics a native
windowing backend would have to speak). _Runner-up:_ Angular CDK's
`FlexibleConnectedPositionStrategy`, best-in-class on the question GTK4 does not answer —
a **total order over candidates**: first perfect fit wins, else best weighted flexible-box
area, else push the least-bad on screen, else use it unmoved.

### 3. Collision and geometry engine

The collision engine decomposes into three layers, and only one is real work. Layer 1 is
**discovery** (find the anchor rect, find the clipping ancestors, undo transforms and
DPR). Layer 2 is **arithmetic** (four signed subtractions per candidate, a fit predicate,
a repair). Layer 3 is **tracking** (observers, polling, `requestAnimationFrame`, dirty
flags). A canvas toolkit with a frame loop gets layers 1 and 3 for free — layout has
already produced every frame rect and collapsed the clipping chain — and must write only
layer 2, which is roughly twenty integer operations. Two qualifications, both worth stating
because the first-pass version of this finding overreached: what collapses is every
**geometry-tracking** observer, poll and dirty flag whose inputs layout already owns; the
_cross-surface_ position machinery (per-frame screen-location queries, window-manager
round-trips, compositor surface positioning) disappears for a different reason — one surface —
and would **return** with a native-popup backend. And placement being incrementally free does
not make the frame free: re-running `view` and `layout` for the overlay's own subtree every
tick is a real cost that the observer-based subjects were partly buying their way out of.

That is not speculation: Floating UI's entire environment contact is a three-method
`Platform`, and its own canvas driver implements all three in one line each. Avalonia runs
**one byte-identical positioner** against real monitors and against an in-window canvas
through a four-member adapter whose in-canvas arm reports a single synthetic screen equal
to the overlay layer deflated by safe-area padding, with `Scaling => 1`. The engine cannot
tell an in-window canvas from a 4K monitor. Textual's whole engine is `Region.constrain`
plus `translate_inside` — six integer expressions driven by a per-axis CSS enum. What does
_not_ generalise is uniformly substrate compensation: clipping-ancestor discovery, DPR and
zoom correction, remembered scroll offsets (which exist only because a compositor can
translate but not lay out), and the entire observer apparatus.

**Best in class: Avalonia's `ManagedPopupPositioner` plus its `IManagedPopupPositionerPopup`
seam.** It is the only subject in the corpus that runs one placement engine, unchanged,
against both a multi-monitor desktop and an in-window canvas overlay — precisely the
GUI/TUI/Android/recording problem — behind a four-member interface whose in-canvas
implementation is nine lines. Its flip is formulated over the **anchor rect** (mirror the
anchor edge and the gravity together), which is correct for a non-zero-size anchor, unlike
Textual's `inflect` and GPUI's `from_anchor_and_size`, both of which reflect about a point
and are right only for a cursor anchor. Two defects must be fixed on the way across, and
both are instructive: `ResizeX` computes against the boundary's _extent_ where `ResizeY`
correctly uses its _far edge_ — invisible whenever the boundary starts at zero, live the
moment a left safe-area inset exists — and its slide is an unconditional two-sided clamp
rather than the gravity-directed two-phase slide the same repository quotes verbatim in
its own enum docs. _Runners-up:_ Textual for the best-fitting algorithm (integer cells,
pure, per-axis policy as data), and GPUI for the best in-canvas architecture — recompute
from scratch every frame, deferred prepaint with the clip-mask stack emptied, hit test as
`bounds ∩ mask-captured-at-insert`, with a regression test that scrolls a container 1000 px
and asserts byte-identical overlay bounds.

### 4. Arrow and caret geometry

Twenty of the thirty-eight subjects have no arrow at all — including every mature
cell-grid overlay system. Nine treat it as returned **data** (Floating UI's `arrow()`
middleware and its `centerOffset` residual, Radix, Base UI's `arrowUncentered`, Zag,
react-aria's `arrowOffsetLeft/Top`, UIKit's `(arrowDirection, arrowOffset)` pair). Nine
compute it and bury it in paint or template layout.

The decisive axis is not "does it have an arrow" but **does the placement engine return
the resolved side** — and among the subjects that consume the side for _anything_ (an arrow, a
transform origin, a chevron direction, a border join), every one whose placement result discards
it either paid to recover it or foreclosed the feature. Compose downcasts its own
position provider to read the _requested_ side, compares post-layout screen coordinates
one frame later to recover the _resolved_ one, and re-implements the collision clamp in a
second function; Avalonia's `void IPopupPositioner.Update` foreclosed arrows permanently;
WinUI forked an entire second placement engine because `FlyoutBase`'s fit test could not
express an arrow inset; Qt's balloon tip clamps the window without moving the notch, so
near a screen edge the arrow points at nothing.

At cell resolution the whole problem collapses to **a side, an index along the shared
edge, and a visible flag**. `arrowLen == 1`, so Floating UI's `largestPossiblePadding`,
Base UI's alignment-offset reset, react-aria's `arrowSize/2`, GTK4's tip-versus-base clamp
asymmetry and WinUI's five-band grid all degenerate. Three rules survive: clamp the cell
into `[1, extent-2]` so it never lands on a corner glyph; **suppress rather than clamp**
when the clamped cell is not the anchor's cell, because a one-cell error is _categorical_
(it names a different character) rather than perceptual; and let the arrow's need for
overlap constrain the popup rather than the reverse.

**Best in class: react-aria's `calculatePosition` for the model, composed with Floating
UI's `centerOffset` for the suppression signal.** react-aria is the only subject that
computes the arrow _inside_ the same pure single pass that computes the popup, with the
arrow's needs acting as a constraint **on** the popup — before the arrow is placed, the
overlay's cross position is clamped so at least `arrowSize + arrowBoundaryOffset` of it
overlaps the trigger. It also writes the two clamps as two separately named ranges with an
explicit precedence (clamp into the trigger, then into the overlay; the second wins), which
is the entire corner problem. What it lacks is a residual, so a detached arrow silently
lies — which Floating UI supplies and Radix demonstrates consuming (hide the arrow _and_
swap the transform origin to the alignment keyword). _Honourable mentions:_ WinUI's
`TeachingTip` for the best requirements catalogue (arrow inset feeds the fit test, position
derived _from_ the arrow, tail visibility as a first-class enum) and the worst
implementation shape (every scalar recovered from post-layout `ActualWidth`); GTK4 for the
best native-stack answer (arrow computed from the compositor-resolved gravity, in
popup-local coordinates, after the slide).

### 5. Trigger semantics

Only one subject in thirty-eight puts triggers _inside_ the overlay primitive. CDK's
`OverlayRef`, Qt's `QMenu`, Slint's `PopupWindow`, `nvim_open_win`, nui, ratatui, posframe
and Helix's `Popup` are trigger-free surfaces. Where a toolkit did own triggers it built a
**service** — WPF's `PopupControlService`, WinUI's and Avalonia's `ToolTipService`, GTK4's
tooltip pump — which is a race-avoidance mechanism wearing an architecture's clothes.

Six genuinely distinct combination algorithms exist: a **latch set plus a stateless
predicate** for sustained sources (react-aria — no handler opens anything; every edge
writes its own boolean and calls one shared `handleShow`/`handleHide`, so ordering is
provably irrelevant); an **open-cause record** read at every later decision (Base UI's
`syncOpenEvent`, which refuses to let a pending hover-open overwrite a click-open while
allowing click to upgrade hover; `xdg_positioner`'s event serial is the distributed form);
a **priority lease** totally ordering triggers (Compose's `MutatorMutex` over
`Default < UserInput < PreventUserInput`); a **device-class partition** where the trigger
sets are disjoint by construction (Flutter's `MouseRegion` tracking only
`PointerDeviceKind.mouse` against recognizers declaring `supportedDevices` as the
non-hovering kinds; Compose's two `pointerInput` nodes on different passes); a
**single-owner plus idempotent-enter plus forced-exit plus dedupe token** (the desktop
services, plus ImGui's frame-counter guard against a caller that calls `OpenPopup` every
frame); and **deferred action**, where every branch writes intent and one tail block acts —
Turbo Vision's 230-line event switch in which no branch performs an action, and Helix's
single-threaded `AsyncHook` funnel. The last is `step(state, input) -> state`, so the
corpus's hardest race is free for a value-semantics toolkit.

Two rules recur wherever they appear at all. **Hover never opens the first surface in a
group** — it only switches once the group is already open, and the switch is a distinct
retarget transition, not close-then-open (Base UI and Zag reached that independently, and
a close-then-open pair restarts the presence timeline and flashes the surface). And **the
cause must survive into the open state**, because at least three downstream decisions read
it — the anchor kind (GTK4 nulls `pointing_to` for the keyboard path; WPF passes a
`(-1,-1)` sentinel; Avalonia asks `TryGetPosition`), the initial focus, and the delay.

**Best in class: react-aria.** It answers all four halves at once and every part of its
answer is a value rather than a listener graph: sustained sources compose as independent
latches into one stateless predicate; modality is one global oracle with three values
(keyboard / pointer / **virtual**) consulted by _both_ the focus and hover paths and —
decisively — **settable**, so every pointer, keyboard and screen-reader path is assertable
with no device; the cause selects policy with no extra flag (`state.open(isFocused)` makes
a focus-open immediate and a hover-open warm up); and the trigger set is **declared**
(`trigger ∈ {press, longPress, contextMenu}`), which is exactly the shape a capability
declaration can be resolved against. _Runner-up:_ Compose's three-level `MutatorMutex`
ladder, the only mechanism in the corpus that totally orders _instantaneous_ triggers with
no pairwise table and no timers — losing only on representation, since "shown" is a
suspended coroutine.

### 6. Timing

Twelve subjects have **no timing at all** in the overlay primitive, and that absence is a
design position rather than an oversight: `xdg-shell` partitions overlays into
geometry-plus-dismissal for the compositor and everything time-shaped for the toolkit, and
the HTML Popover API ships an interoperable anchored overlay with zero timers (its own
example uses author `setTimeout`). About twenty implement a delay pair. Nine implement
the real prize — **instant subsequent overlays** — and they converge on one shape: **one
timestamp (or one deadline) on a shared arbiter, with no per-widget cool-down state**. Those
nine represent roughly **six independent lineages** (Avalonia is a port of WPF's API and Base UI
a fork of Floating UI's), which is convergence rather than copying: WPF shipped it around 2006
as `BetweenShowDelay`, and Qt, GTK, react-aria, Radix/Ariakit, WinUI and Floating UI/Base UI
each arrived separately. Derived-from-live-state warmth (Flutter's "some other tooltip is open
but nobody is hovering it", Zag's global id) is strictly weaker: it cannot express _the last one
closed 200 ms ago_. Dear ImGui alone collapses warm-up _and_ cool-down
into a single shared `float` accumulator with a decay grace — the fewest values in the
field, and the only design authored for an immediate-mode frame loop.

Four second-order behaviours recur and deserve the same status as the delays: a **third
channel** ("this transition was instant, do not animate") exported by five subjects under
five names; **rest/stationary gating** in seven; **re-entry during the close delay returns
to open free of charge**, near-universal; and **max display duration**, which the desktop
stacks are _retreating from_ (WPF's .NET 6 default is `Int32.MaxValue`) and which Compose
and Flutter scope explicitly to touch- and keyboard-triggered surfaces only.

**Best in class: Zag.** Warm-up and cool-down are **states**, not annotations —
`{closed, opening, open, closing}` with the delay as a state-scoped effect, so cancellation
is _structural_ and a stale timer is unrepresentable. Every other subject re-derives
cancellation by hand and at least four get it wrong (blink.cmp's stopped-but-still-queued
callback is documented in its own TODO; Uno's static timers leak across owners;
floating-vue's single slot is overwritten by a concurrent hide). Its `closing` state is
treated as _visible_, so the close delay is a live-but-dying window that a re-entering
pointer converts straight back by an ordinary transition. And its cross-instance policy is
seven lines of `{id, prevId, instant}`, not a callback registry. What Zag gets wrong and
must not be copied: it clears the global id on _entry_ to `closed`, so its skip-delay
grace is exactly zero — instant-swap only while another tooltip is showing, never after one
closed. _Runner-up:_ react-aria's `useTooltipTriggerState` — the richest and most-tested
behaviour set, in the wrong shape (module-global mutable state and an id-to-callback
registry). _Honourable mention:_ ImGui, the only design with zero per-widget storage and
the only one that requires the pointer to be **still**.

### 7. Interactive hover and pointer intent

Two problems share one name. **Anchor-to-overlay travel** is geometry: the pointer must
cross a gap without the surface closing. **Parent-item-to-submenu travel** ("menu aim") is
routing: the pointer crosses the parent menu's _own items_, each of which wants to steal
the highlight. Twelve subjects implement the first, nine the second; only three implement
both, never with the same algorithm.

On the first, the field converged independently on **the convex hull of the anchor rect
and the overlay rect** — WPF's `ConvexHull` (a two-pass containment with an axis-aligned
fast path and per-vertex direction caching), WinUI's polled `ComputeConvexHull`,
react-aria's `useSafeArea` (padded corners plus a monotone chain), and Ariakit's
`getElementPolygon`, which is the same hull of point-union-rect **in closed form**, from a
corner-order table and two comparisons. Four independent convergences on one region, from
three codebases and two eras. Floating UI's `safePolygon` is the outlier: a five-stage
cascade whose apex is the _cursor_, with a trough rect, an opposite-side bail, a landed
latch, a 40 ms grace and a wall-clock 0.1 px/ms velocity gate.

On the second, nobody converged. Qt counts wrong-direction moves against a slope pair —
and defaults its uni-direction hint to **false** on every style but macOS. CDK votes four
trajectory lines from a five-slot ring buffer, consensus at two. ImGui builds the Amazon
triangle from _last frame's_ pointer with a slope cap. React-aria compares movement angles
±15° with a 0..2 hysteresis counter. Radix latches `sgn(Δx)` and gates a five-point
trapezoid on it. GTK4 does no geometry at all: an 80 ms timer re-armed on every motion
event, so it fires only when the pointer stops — the only algorithm here that retains no
coordinates whatsoever.

**Best in class: WPF's `ConvexHull` + `SetSafeArea` / `MouseHasLeftSafeArea`**, for the
half a canvas toolkit needs first, and _because_ of constraints resembling a cell grid's:
it is a pure predicate over Regular values with no clock, no velocity and no motion
history; it is integer-first by deliberate design (coordinates are small client ints
specifically so the cross product cannot overflow, and pass 1 disposes of axis-aligned
edges with comparisons alone); it is symmetric and placement-agnostic, so it never reads
the placed side back out of presentation state — the exact coupling Radix left a standing
TODO about; and it does not swallow events, so it cannot break routing. Its design and
trade-offs are written down, including why the hull beat the union rectangle ("too large")
and a shortest-line scheme (which "failed a simple usability study where people naturally
tried to move from P to T along any convenient straight line"). _Runner-up:_ Radix's
submenu grace, whose most valuable part is not the geometry but the **routing
consequences** — while grace holds, item-enter is prevented from stealing focus and
item-leave returns early. _Best new idea:_ Blink's `MenuSafeTriangle`, which **buffers**
the suppressed hover gains and losses instead of dropping them, annihilates a gain against
a pending loss for the same invoker, and replays losses-then-gains — so abandoning the
corridor lands the UI in exactly the state it would have reached anyway.

### 8. Dismissal

Dismissal decomposes into three separable things that most implementations tangle: a
**policy** (which causes may close this surface), a **cause detector** (how each cause is
recognised), and a **cascade** (how far down a nested stack one cause propagates). Only Qt
Quick Controls has all three as data — `ClosePolicy` is a seven-bit flags enum and
`tryClose(pos, phaseFlags)` is one boolean expression. Uno and WinUI have the same shape
as verified dead code: `DismissalTriggerFlags` is declared and read and never assigned
anywhere in the tree, so the generalisation exists and buys nothing.

The detectors split on the axis that matters: **event-driven** causes all reduce, in a
single-surface toolkit, to a group-membership test over the last painted frame's hit list —
Flutter's `RenderTapRegionSurface._classifyRegions` does exactly that with no grab, no
capture and no scrim, collapsing a whole submenu chain into one unit via a group key, and
Avalonia's overlay-tree climb collapses to a set test when the tree is an id array. The
**frame-derived** causes need no events at all: Textual re-hit-tests the cursor after every
reflow, blink.cmp treats "the placement solver returned nothing" as a dismissal, and CSS
`position-visibility` _hides_ rather than closes. For a toolkit that rebuilds
view-layout-display-list every tick, the frame-derived half is nearly free — and it is the
only half assertable on a headless recording target without synthesising input.

The cascade is the most consensual part of the whole survey: **leaf-to-root,
endpoint-indexed, re-validated after each close**. Blink re-runs its find-last-to-hide
scan after every hide because a `beforetoggle` handler may have shown something; ImGui's
`ClosePopupToLevel` is literally `resize`; `xdg-shell` states the ordering as a protocol
invariant with `not_the_topmost_popup` as an error.

**Best in class: Qt Quick Controls' `ClosePolicy` + `tryClose`.** It is the only
implementation where the whole dimension is one comparable value evaluated as one boolean
expression, with a default, a reset, a per-component override and a data-driven
cross-product test — and where **the caller passes the cause in the same vocabulary the
policy is written in**, so the router owns "what happened" and the surface owns "do I
care". It encodes _scope_ as well as cause (`*OutsideParent` makes the anchor's own rect
count as inside, generalising every ad-hoc don't-let-my-own-trigger-close-me latch
elsewhere), and it extended along the axis that turned out to be missing by adding
`CloseMultiple` to the same flags word rather than a second mechanism. _Runner-up:_ the
HTML Popover API and Blink, for the best cause **set** and cascade: one `close request`
abstraction covering Escape, the Android back button, VoiceOver's z-scrub and a gamepad
button, mandated to fire on key **down**; a two-phase pointerdown/pointerup identity test
with the WCAG pointer-cancellation rationale written into the source; and
`hide popovers until(endpoint)` as the single funnel that all eight dismissal paths flow
through.

### 9. Focus

Focus is the most portable dimension in the survey, for an uncomfortable reason: almost
every line of focus code in the corpus is **repair work for a substrate a canvas toolkit
does not have**. Radix's `MutationObserver`, its `focusout` null-`relatedTarget` carve-out
and its scope-stack pause/resume; Headless UI's guard buttons and index rotation; Floating
UI's four portal sentinels; react-aria's ref-counted `ariaHideOutside` tree walk; Ariakit's
snapshot/mark/inert/orchestrate directory; Tippy's append-to-`parentNode` trick plus a
shipped dev warning when it breaks — all of it exists because the DOM has a second writer
of focus and a tab order that diverges from the visual order. The in-canvas subjects prove
the point from the other side: Avalonia's `OverlayPopupHost` gets containment from one
property default, Slint from one boolean in the parent walk, Turbo Vision from a circular
sibling list and three state bits.

What survives is a **policy table**. Four regimes stay distinct everywhere serious:
tooltips never focus (and their content is non-interactive _by type_ — Apple's help text is
a `String`, ImGui's tooltip windows carry a no-inputs flag, Headless UI's tooltip panel's
default tag is literally `Description`); combobox and menu keep focus on a container and
track the active item as an **index**; popovers optionally contain; only dialogs are modal,
and modality is an _exclusion set over the hit list_, never a trap.

**Best in class: the HTML Popover API as implemented in Blink**, for three algorithms that
are each total, allocation-free and assertable with no window. First, **the tab-order
rewrite**: the popover's _trigger_ is a focus-navigation scope owner, and the popover's
contents are inserted immediately after it — the only mechanism in the survey that makes
the overlay's position in the tree irrelevant to keyboard navigation, which is exactly the
problem a toolkit with no top layer has (an overlay must be painted last while it must be
tabbed to from its trigger). Second, **focus policy is opt-in and the default is do not
move focus**, gated by transient activation so a scripted show cannot steal focus. Third,
**restoration is triple-guarded**: only the bottom of a stack remembers, and the restore
fires only if the popover still contains the focused element — plus a one-shot
`SuppressNextFocusInterest` that breaks the close-restore-retrigger-reopen loop, which is
the exact bug floating-vue shipped and worked around by deleting `focus` from its menu
theme's triggers. _Runner-up:_ Radix's `FocusScope`, best-in-class **decomposition** —
the only subject keeping `loop` and `trapped` as genuinely independent props, with a scope
stack whose add pauses the previously-active scope so exactly one scope enforces at a time.

> [!NOTE]
> Focus is overwhelmingly key-down-driven, but not universally: WPF enters menu mode and
> focuses the first item on a lone Alt/F10 **key-up**, and GTK4 drives its focus-visible
> flag from a press/release pair. Any such affordance has to be rebound to key-down on a
> target that cannot report key releases.

### 10. Layering, top layer and overlay trees

Two real answers, split by substrate rather than by year. Subjects with an OS surface
delegate stacking to the window manager and keep only a parent pointer. Subjects without
one — every subject sharing the single-surface constraint — converge on the same three-part
shape: a **flat ordered list** whose order is show order and whose paint order is list
order; a **parent index** per record used only by dismissal, hover inhibition and focus,
never by paint; and a small fixed ladder of **named bands** so a tooltip or a toast cannot
be dragged into a menu's dismissal stack.

The strongest evidence that the tree must be a **query** rather than a structure is the
HTML specification, which stores only an ordered set and recomputes the topmost ancestor
per operation, noting that list order "allows for the construction of a well-formed tree
from the (possibly cyclic) graph of connections". Cascading dismissal is then a slice:
HTML's hide-until is `indexOf(endpoint)+1`, ImGui's `ClosePopupToLevel` is `resize`,
react-aria's expanded-keys stack is `slice(0, level)`. Where a system omitted the parent
link it grew registries instead — Ariakit three, Radix two (with two filed issues) — and
where a system let the ownership tree drive paint order it got bugs: Notcurses'
move-family-above looped forever until 3.0.9, and GPUI's paint pass sorts _all_ deferred
draws by a flat priority while prepaint sorts only within a round, so a nested child of a
low-priority parent can paint behind an unrelated higher-priority sibling.

**Best in class: Textual.** It is the only subject implementing a genuine first-class top
layer **in integer cells with no OS window, no compositor and no z coordinate**, and its
answer decomposes into exactly three resets: an **order reset** (the whole tuple path is
replaced by a length-one tuple, so the overlay sorts against top-level content rather than
its siblings), a **clip reset** (the accumulated sub-clip is replaced by no-clip), and an
**extent reset** — an overlay placement is excluded from the container's total region, so
a wide popup cannot grow its host's scrollable virtual size. That third one appears in no
Textual documentation and in no other subject, and without it opening a dropdown inside a
scroll view materialises scrollbars. Because there is no reparenting, one declaration
serves both hoisting backends and a non-hoisting static-HTML target, which a portal-based
design cannot do. _Runners-up:_ HTML popover and Blink for the **dismissal algebra** over
a flat list (including Blink's deferred removal, which splits "visually open" from "in the
layer" as a data structure rather than a convention), and GPUI for the **record shape** — a
flat vector of value records each carrying offset, content mask, style scale and the
logical parent for event dispatch.

### 11. Modality

The field has converged on one answer and one non-answer. The answer: **modality is not a
mode.** Floating UI, Radix, Zag, Base UI, react-aria, Qt Quick, Compose, WinUI and Apple
all decompose it into three to five independently settable effects — pointer blocking, key
routing, focus containment, scrim, assistive-technology hiding, scroll lock — and every
subject that shipped a single bundled boolean regrets it in its own source: GTK4's
`autohide` conflates four concepts _and is construct-only_, so changing it must unrealize
the widget. The non-answer: nobody agrees where the bit _lives_. Three positions are
defended in code — on the overlay (Qt Quick's `modal`, GPUI's per-hitbox behaviour), on the
stack (Radix's `index >= highestDisabledIndex`, WinUI's derive-at-hit-time, ImGui's
blocking-modal walk), and on the host (Textual's `ModalScreen`, nui's buffer-local keymaps,
`xdg_dialog_v1`'s `set_modal`, which is _only a hint_ and requires client-side filtering).

Mechanically there are five families, and only two port to a single surface: a **full-surface
catcher rect** inserted into the same paint/hit order (Avalonia, WinUI, Uno, Flutter, APG,
GPUI), and **a predicate inside the hit walk with no rect at all** (GPUI, Slint, Qt Quick's
`blockInput`, ImGui, Helix, Textual's binding-chain truncation). The DOM-mutation family —
inert, `aria-hidden`, `pointer-events`, all reference-counted with save-and-restore — has no
analogue at all.

**Best in class: GPUI for the mechanism, Qt Quick Controls for the model.** GPUI's
`HitboxBehavior` has three values on a hit rect (`Normal`, `BlockMouse`,
`BlockMouseExceptScroll`) and the entire enforcement is twenty-two lines inside the
reverse hit walk — no modal flag, no scrim object, no stack, no OS involvement. Its authors
wrote down the argument for that placement: blocking belongs in the **hit test** rather
than an event filter because "any use of hitbox checking, such as hover styles and
tooltips" must obey the same cut, or clicks and moves interact with elements that are not
considered hovered. `BlockMouseExceptScroll` is the third value nearly every other toolkit
collapses and regrets. Qt Quick supplies the model: `blockInput` is a pure predicate over
(item, point, modal, popup geometry, dimmer geometry) with no state, `modal`/`dim`/
`ClosePolicy` are three separate properties, and its containment-mask hole is the only
passthrough in the corpus pinned by a test asserting that the hole suppresses **both**
blocking and dismissal. Qt also supplies the cautionary half: because its delivery agent
does not route wheel, tablet and drag-and-drop through the same path, the same modality
rule is re-implemented twice more. _Runner-up:_ WinUI, the only subject where light
dismiss, scrim visibility, passthrough, the dismissal-triggering event class and the
automation modal bit are five separately named and separately computed things.

### 12. Adaptive presentation

"Adaptive presentation" is two unrelated problems wearing one name. The first is **surface
adaptation** — does this overlay become an OS window, a native menu, a sheet, or an
in-canvas box? Qt Quick's `resolvedPopupType`, Avalonia's `CreatePopup()` returning null,
Slint's `create_child_window_adapter` defaulting to `None`, Uno's native-popup switch,
Flutter's system-context-menu probe, the popover API's appearance branch and Apple's
size-class map all implement the same shape: `resolve(preference, capability) -> surface`,
evaluated once at open, with the outcome **observable** (Avalonia publishes
`IsUsingOverlayLayer` as a read-only property). The second is **trigger adaptation**, and
here the field splits four ways: suppress the surface entirely (Radix, Zag, GTK4, Qt
Widgets, ImGui, Apple's help text), substitute a long press (Compose, Flutter's default,
react-aria, Slint, Radix's context menu, Blink), substitute a tap (Flutter's tap trigger
mode with tap-to-dismiss), or add a **visible extra hit target** (Blink's interest button,
WCAG-sized, deliberately not focusable so it adds no tab stop).

What every subject with an opinion agrees on — and what the ones that violate it pay for
visibly — is the layering: **the adaptive fact is an input, never a discovery.** Uno
spreads it over three layers with no owner and lets one flag silently change the _boundary
rect_ per head; blink.cmp and nvim-cmp re-test command-line mode in five files; Tippy
guesses touch from a 20 ms mousemove gap; react-spectrum's mobile test is
`window.screen.width <= 700`; Helix picks a style from a Rust **type name**. The
disciplined ones pass it: WinUI's `inputDeviceTypeUsedToOpen` parameter, ImGui's
backend-supplied mouse source, blink.cmp's injected command-line position, ratatui's
boundary `Rect`, `xdg`'s client-declared constraint bitmask.

**Best in class: Jetpack Compose**, for the trigger half — the live one. It is the only
subject that ships **both interaction routes in one component, unconditionally**, with no
device-class branch, no configuration and no platform conditional: an initial-pass pointer
node running the long-press path for touch and stylus, and a main-pass node mapping
enter/exit for mouse. A hybrid device gets both simultaneously; nothing anywhere asks what
platform it is on. And it then **publishes the substituted route to the accessibility
layer** as a labelled long-click action, so the gesture is discoverable rather than
folklore. _Runner-up:_ Apple, the clearest statement that the overlay must not choose its
own form, that the host owns `adapt(requestedForm, surfaceSize, capabilities)`, and that
the application's override rides with the **content** rather than the call site.

### 13. Accessibility

One structural rule holds across the corpus: **no working accessibility integration puts a
role in the positioning primitive.** CDK's overlay package emits exactly one attribute of
its own; Radix's Popper, DismissableLayer, FocusScope and Portal carry zero ARIA; Zag's
popper and dismissable emit none; Base UI's positioner emits only a presentation role;
Avalonia's popup automation peer reports itself as not a control element; GTK4's popover
sets no role; `xdg_positioner` and CSS anchor positioning refuse the question outright, the
latter with a spec advisement stating that the _visual_ anchor and the _semantic_ anchor
are genuinely different relations.

Three real disagreements remain. **Where the tooltip's text lives** — as an object in a
parallel tree referenced by id (APG, Radix, Headless UI, react-aria) or folded into the
_anchor's_ accessible name and description so no overlay object exists at all (GTK4's
accessible-name computation, Flutter's semantics tooltip, SwiftUI's help modifier, the APG
toolbar's in-button span hidden off-screen rather than with `display:none`, precisely so it
stays in the name). **Whether an anchored surface may be interactive** — APG says never for
a tooltip role and names the substitute in the same breath ("a hover that contains
focusable elements can be made using a non-modal dialog"); ImGui, Slint, Textual, Apple and
Headless UI enforce it structurally by typing; Zag, Ariakit, GPUI and Blink allow it with a
flag. **Whether to announce on open** — WinUI raises a notification every time, Qt
deliberately suppresses one because Narrator otherwise reads tooltips twice.

The finding that matters most for a cell grid: **all three WCAG 1.4.13 obligations are
discharged by geometry and state, not by an accessibility API.** Hoverable is a pure
predicate (WPF's convex hull). Persistent is the _absence_ of a max-duration timer. Dismissible
is one input transition. **None of the eight terminal libraries surveyed builds an accessibility tree of any kind** —
whether the terminal _host_ exposes a text tree over the buffer is a separate, unchecked
question. A cell grid's structural channels are at least four: the painted characters in
reading order, the hardware caret cell, OSC-8 link metadata, and the window/tab title. Only the
first two are demonstrated in the corpus as actually reaching an assistive technology, and tmux
proves the caret one in nine lines — park the cursor on the selected menu item, with the commit
message naming the reason. A script-free HTML target, meanwhile, can emit the complete static
ARIA contract for free.

**Best in class: react-aria.** It is the only subject that answers every question here with
a mechanism rather than a prop: description-versus-label is not configurable (the tooltip
trigger returns a description relation and an explicit refusal to make the trigger
focusable); the role table is calibrated against real screen readers rather than the spec,
with source comments citing the mis-announcements; modality is implemented by hiding
siblings rather than by a modal attribute, matching what assistive technologies actually
honour; it is the only subject solving **assistive-gesture dismissal** as geometry-free data
(a visually hidden dismiss button rendered both before _and_ after the content, because
that bracketing is the only way iOS VoiceOver's swipe navigation reaches it); it treats
screen-reader timing as a first-class state via the `virtual` modality; and it answers "may
tooltip content be interactive" with a **separate component**, independently reaching APG's
normative conclusion. _Runner-up:_ WPF's .NET 6 tooltip specification, the only primary
source in the corpus that treats WCAG 1.4.13 as a decomposed engineering requirement with a
named mechanism per clause and a recorded rationale — including why the convex hull beat
both the union rectangle and a shortest-line scheme.

### 14. Animation and emitted geometry metadata

Roughly a third of the corpus emits geometry metadata _specifically_ so a styling layer can
animate; two thirds compute the same facts inside the solver and throw them away. The
metadata camp converges on an almost identical payload: the **post-flip side and
alignment**, a **numeric transform origin pinned to the arrow tip**, the **room actually
available**, the **anchor's own size**, and a **suppress-this-transition** flag.

Two structural findings outrank all the styling variables. First, **Blink keeps two sets** —
the top-layer elements and a second, reason-tagged pending-removal list — and behaviour
queries the _difference_, asymmetrically: a closing dialog no longer blocks, while a closing
popover still participates in nesting. Deferred removal is an animation concern that changed
the data structure. Second, **Flutter never emits a side at all**; it feeds animation
progress _back into_ the layout delegate, reconstructs the hypothetical full-open size, and
re-decides grow-up versus grow-down every tick — so a mid-animation flip, resize or inset
change cannot leave a cached decision stale.

Four subjects independently discovered the same hazard and state it as a rule: **never let
an animated value re-enter the placement solver.** WPF subtracts the animation offset before
computing interest points; Blink evaluates fallback candidates against the base un-animated
style; CSS anchor positioning states it normatively and demonstrates the pathology of the
alternative ("constantly recomputed, triggering fresh transitions every frame"); Base UI
rewrites coordinates only when a transition duration is non-zero.

**Best in class: react-aria's `calculatePosition`.** It is the only subject where the
animation metadata is a **return value of a pure placement function over plain values**
rather than a side effect on a live node — the rect, the size clamp, the clamped arrow
offset, the resolved placement and a numeric origin, from one call, with no mutable side
channel. It also gets the two lifecycle rules right that most subjects get wrong: the entry
animation is gated on the placement value _existing_ and cancels a transition that started
earlier, and the skip-animation flag is threaded from the warm-up machine into both popover
and tooltip as a third channel next to open and close. _Runner-up:_ Radix for the richest
and most-copied payload — including the `centerOffset != 0` fallback to a categorical
origin, which is precisely the script-free answer. _For the lifecycle half:_ Blink's
two-set deferred removal, the only place where "a closing overlay still paints but no
longer participates in behaviour" is a data structure rather than a convention.

> [!NOTE]
> Whether a transition plays is **primarily** but not solely a function of the open-change
> reason: Base UI additionally forces suppression from a delay-group timing state,
> react-aria from a warm-up timer, and Headless UI from a _measured_ anchor movement. Only
> Zag suppresses the outgoing surface as well as the incoming one.

### 15. State architecture

The field overwhelmingly does **not** use state machines for anchored overlays. **Four** of the
thirty-eight subjects model the overlay's open/close lifecycle as an explicit machine — Zag's
declarative statechart, Headless UI's abstract machine with a pure reducer, GPUI's tooltip enum,
Compose's sealed context-menu status. Counting _mount and transition_ lifecycles as well adds
Radix's three-state presence, Qt Quick's transition state and Base UI's transition status, for
roughly seven. Everything else is loose booleans over an imperative
controller, and several of the largest boolean sets also carry the most elaborate documented
re-entrancy defenses — a correlation worth noticing rather than a demonstrated cause: Qt's twelve bitfields plus a purpose-built event
re-poster, WinUI's ~15 loose members plus an ignore-next-change bounce, Radix's nineteen
latch refs, Tippy's five-boolean public record with unenforced invariants that its own test
suite writes to directly.

Two structurally different answers work. **Openness as membership in one ordered array** —
ImGui derives every query from comparing two stack lengths, and HTML's popover stack,
Slint's monotonically-keyed vector and Headless UI's forty-line stack machine all do the
same, none of them needing a per-overlay boolean. And **transactional value update** —
Neovim's copy-modify-replace over a flat config with key-presence-guarded partial patches
and a transactional restore on validation failure; `xdg_positioner`'s normatively pinned
copy-on-use; tmux's preferred-versus-current geometry pair.

The single most consequential cross-subject rule is that **requested and resolved geometry
must be separate fields**. Neovim states it in a source comment and demonstrates the cost of
violating it (its preview-popup path re-decides its own flip and writes the placed result
back, which forced two new fields to hold the un-placed anchor); tmux keeps preferred beside
current so a terminal shrink is reversible, and GTK4 pairs the requested layout with the final
rect. Angular CDK is _not_ an instance of the violation — it keeps its preferred positions
intact — but it demonstrates the adjacent failure: six **hidden inter-frame memo fields**
(initial-render, pushed, last-position, last-box-size, previous-push-amount, last-scroll
visibility) make its placement non-pure, so `apply()` cannot be tested without attaching a real
overlay. CSS anchor positioning retains the same hysteresis correctly by **naming** the memo and
**enumerating** its invalidation set.

**Best in class: Headless UI's `Machine` plus its stack machine.** It is the only subject
where the lifecycle is a genuine pure reduce, the transition table is a **total** dispatch
over an action enum (so a missing case is a type error), cross-overlay policy is itself a
composed machine rather than a global convention, "nothing changed" is a first-class result,
and the same layer serves menu, listbox, combobox and popover uniformly. It also already
knows its own porting fix: combobox options carry a numeric order preferred over DOM
comparison, so the authors have demonstrated how to remove the DOM from the reducer.
_Runner-up:_ Zag, for the **declarative half only** — transition tables as inert data with
guards, actions and effects indirected by name into a separate implementations table, plus a
pure least-common-ancestor diff over dotted paths. Its execution layer is duplicated six
times, DOM-bound and asynchronous, so exactly half of it is worth taking.

### 16. Shared infrastructure and the decomposition

Five packaging algorithms exist: N orthogonal mechanism packages composed per surface
(Radix, Floating UI, Zag, react-aria, CDK); one shared parameterised solve wrapped by thin
policy shims (Base UI, blink.cmp, floating-vue, Avalonia); one base class with subclass
differentiation (Qt Quick, Ariakit, WinUI, Uno, nui, Turbo Vision); a nearly empty surface
plus a pure placement **value function** (Compose, `xdg_popup`, GTK4, Flutter, notcurses,
Helix, Neovim); and strategy-as-a-field on one concrete handle (CDK, posframe, WPF). The
null decomposition — share the transport, share no policy — is the control group, and its
cost is measurable: Qt Widgets has five placement ladders, Neovim four flip rules, Flutter
four delegates with three flip algorithms, tmux two adjacent ~190-line copies that have
drifted, GPUI three duplicated element implementations.

The **split** is near-unanimous even where the packaging is not. In: an anchor value, a
placement solve with a resolved-side and arrow report, an ordered layer registry with parent
links and a cascade operation, a reason-tagged dismissal channel, and the open/mounted
lifetime split. Out, on every subject that addresses it: focus **behaviour** — no subject gives
tooltip, menu and dialog the same one, though a shared implementation _behind_ a per-surface
policy value is normal practice (Ariakit's store chain, Qt Quick's focus property, Zag's
focus-trap package, Base UI's focus manager), so what must be forbidden is a shared **default**,
not a shared mechanism — plus timing and hover intent, item collections and typeahead,
content typing, modality, roles, and any exotic placement mode — which must be a strategy
that may **fail**, never a flag.

The two sharpest witnesses cut against each other and both are right. Base UI — a second
attempt by authors of the first — funnels eleven surfaces including **Toast** through one
~800-line hook with a twelve-field purely geometric parameter interface. Zag ships tooltip
with `popper` and no `dismissable`, and toast with `dismissable` and no `popper`: the two
halves are independently needed and cannot be fused. Compose's aggressive unification (eight
surfaces on one popup plus a position provider) is real but **subsidised** — each popup is a
window-manager child window supplying z-order, outside-touch delivery and focusability.

**Best in class: Base UI's `useAnchorPositioning` plus its popup utilities.** It is the only
deliberate _second_ attempt at exactly this decomposition by people who wrote the first one
and the positioning engine under both, and the revision is legible: the shared/split line is
expressed as file placement, the shared half is one hook with one parameter interface
containing no trigger, no delay, no role, no focus and no modality, and the split half is
enumerated component by component. Collision policy is two **named module constants** rather
than per-component flag soup. And it answers the toast question empirically rather than by
taste: toast shares the geometry and nothing else — its lifetime lives in a separate store
and its screen region is an ordinary flow container. _Runner-up:_ Angular CDK for the
**surface boundary** (one concrete overlay handle; position and scroll behaviour as
swappable fields; a viewport-centred dialog and a connected dropdown proving one lifecycle
serves two unrelated placement algorithms), and Radix for the **orthogonality proof** — its
popper, dismissable-layer, focus-scope, portal and presence packages declare zero
dependencies on one another.

---

## The consensus

Twelve things a new toolkit should simply adopt. Each is held by a clear majority of the
subjects surveyed and contradicted only by subjects with named defects.

1. **Reduce the anchor to one axis-aligned integer rect at exactly one named seam**, and
   let nothing downstream see the original. A point is a 1×1 rect, not 0×0 (Avalonia writes
   exactly that). Carry a corner/gravity selector beside the rect rather than encoding the
   side only in the placement.
2. **Placement is a pure function over rects in integer units** — anchor rect, content size,
   boundary rect, a small policy value — returning a rect. No clock, no hover, no keys, no
   OS. This is not a design preference; it is what every implementation actually does,
   including the one that runs in another process.
3. **The boundary is an input, never a discovery.** Deflate the reported surface in the
   adapter and hand the solver a rect. Every subject that queries the environment inside the
   solver has documented soft-keyboard defects; every subject that receives it works.
4. **Flip on the side axis, slide on the edge axis, resize last**, sliding far-edge-first so
   the near edge wins when the overlay exceeds the boundary. Cross-axis shift is opt-in
   everywhere it exists.
5. **Return the resolved side** (and, for a cell toolkit, the arrow cell) from placement.
   This is the single most-agreed point in the corpus, agreed from both directions: everyone
   who emits it draws arrows, picks transform origins and selects animation direction in one
   pass; and among the subjects that need the side at all, everyone who discards it pays a
   downcast, an extra frame, a duplicated clamp, or forecloses arrows permanently. No subject
   is observed regretting having emitted it. (The roughly seventeen arrow-less subjects discard
   it and pay nothing — which is exactly why a cell toolkit that paints its own caret cannot
   reason from their example.)
6. **Guard the degenerate surface.** When the boundary is not more than twice the padding,
   drop the padding; when the content is at least the boundary minus twice the margin, centre
   in the unmargined boundary. Invented independently by ImGui, Flutter and Compose.
7. **Viewport padding is per-side, not scalar.** A uniform scalar cannot express an
   asymmetric inset — an Android bottom keyboard, a terminal status line.
8. **One flat ordered list of open overlays; paint is list order, hit test is reverse list
   order; re-showing is remove-then-append**, so "reopen" and "bring to front" are one
   operation. Cascading dismissal is a **truncation** at an index computed by an ancestry
   predicate, leaf-to-root, re-validated after each step, with only the topmost closable
   directly.
9. **The close request is one input** covering Escape, the Android back key and any future
   assistive dismiss gesture, fired on key **down**, delivered to the topmost open **group**
   — and the overlay emits a dismissal **request carrying a reason**, which the owner acts
   on. An argument-less close signal is the survey's named anti-pattern.
10. **Absolute deadlines, never accumulated deltas, and the clock is a parameter.** Record
    the arm instant and compare against an injected now; a duration of zero must statically
    disable the feature rather than arm a zero-length timer (two subjects shipped opposite
    bugs from that one root cause). The cool-down is one timestamp on a shared arbiter with no
    per-widget cool-down state — nine implementations across roughly six independent lineages.
11. **Hittability and focusability are two independent bits**, tooltips never take focus, and
    the active item in a menu or listbox is an **index in component state**, not platform
    focus. Initial focus is a priority chain, not a boolean; restoration is a ladder with a
    liveness test guarded by "is focus still inside me".
12. **Identity is an opaque monotonic id**, never a pointer, element handle or derived string;
    requested and resolved geometry occupy different fields; and effects are **returned from**
    the transition rather than performed inside it — every subject that performs effects
    mid-transition carries a bespoke re-entrancy apparatus.

---

## The genuine forks

Twelve places where the field actually disagrees, with the argument on each side and which
side a single-surface, integer-cell, capability-declaring toolkit selects.

### Per-axis adjustment bits, or an ordered candidate list?

**Bits** (`xdg`, GTK4, Qt Quick, Textual, Slint, Compose's two per-axis lists): the value is
tiny, the axes never interact, there is no candidate combinatorics, illegal states are
unrepresentable, and the pipeline is a fixed precedence rather than a search — at the cost of
exactly one alternative per axis, so "prefer right-start, then left-start, then bottom-end"
is inexpressible. **List** (CDK, WPF, WinUI/Uno, Floating UI, blink.cmp, CSS
`position-try-fallbacks`): arbitrary preference order is data, one scorer serves every widget
kind, the perpendicular axis is reachable, and the chosen candidate is reportable — at the
cost of a list to bound and axes that stop being independent.

**Our answer: both, layered.** Blink proves they are the same thing (a try-tactic transform
is three bits, and "preferred side plus alignment" is redundantly expressible as flips of one
canonical placement). Take per-axis policy bits as the **primitive** — total, tiny, Regular,
and the semantics a future native backend speaks — and treat an ordered candidate list as a
**generator** over that same primitive, each candidate solved by the same pipeline and ranked
by the same objective. ImGui already demonstrates the productive hybrid inside one function:
the main axis from an ordered list, the cross axis pre-clamped once and reused verbatim.

### When nothing fits: revert and overflow, clamp in, or refuse?

**Revert** (WinUI, Blink, Uno) keeps the overlay attached and hanging off the edge; some go
further and refuse outright (WinUI's teaching tip, tmux, blink.cmp, Neovim). **Clamp**
(ImGui, CDK tier 3, Qt Widgets, GPUI, Slint, Textual, ratatui) keeps it fully visible and
lets it detach from — or cover — its anchor.

**Our answer: neither alone.** With no host to clip, the function must be **total** and must
report which tier produced the answer, because the recording canvas has to assert it. Return
the rect, the side, the arrow cell, the applied adjustments and a fit verdict including
`refused` — which is real on a 40×10 terminal, and which WinUI's teaching tip proves is a
shippable answer. Default per kind, following the field: a menu clamps in (a menu you cannot
read is useless), a tooltip overflows rather than covering its anchor or the pointer.

### Bridge the gap, or delete it?

**Bridge** is where all the interesting code in the field lives — hulls, polygons, trapezoids,
inflated rects, velocity gates. **Delete** is what every overlap-capable subject actually
does: Uno overlaps the submenu by four pixels, Qt Quick pulls the child back over the parent's
frame by one to four, ImGui overlaps by an item spacing _and_ flags nested submenus as child
windows so hover is shared, notcurses draws the unrolled menu body into the menu bar's own
plane, tmux replaces the menu in place so travel distance is definitionally zero.

**Our answer: delete, and it is not close.** At integer-cell resolution the deletion is one
cell of overlap or zero cells of gap — a layout constant rather than a runtime tolerance,
inspectable and testable, removing the problem class instead of mitigating it. Make zero gap
the default for any overlay declared hoverable, and require a non-zero gap to arm the bridge
at all. The bridge machinery must still exist, because a shadow-bearing pixel popup or a
caller-imposed offset can force a gap — but it is the exception path.

### Region intent, or direction intent?

**Region** is stateless, symmetric, placement-agnostic and needs no clock — four independent
convergences on the hull. **Direction** needs motion history and a sample rate, but it is the
only thing that addresses the actual failure, because the region between anchor and overlay
does not overlap the parent menu's own items at all. Qt's own default is the sharpest
evidence for scepticism about direction: its uni-direction hint is false on every style but
macOS.

**Our answer: they solve different problems and must not be traded off.** Ship the **region**
for anchor-to-overlay travel (where the gap is zero or one cell, so it usually costs nothing)
and a **direction latch** — not a slope, not an angle — for parent-item-to-submenu travel,
where the corridor genuinely spans the parent's own surface. Keep the failure **counter**;
that, not the angular precision, is what makes these algorithms work at low sample rates, and
Qt and react-aria added one independently. **INFERENCE:** angles and slopes lose most of their
resolution on a cell grid (a one-cell step admits only a handful of representable directions),
so the latch is the right substitute — but the latch still needs Radix's zero-delta guard, and
cell quantisation makes zero-delta samples _more_ frequent, not less.

### During grace: suppress the intervening hover events, or buffer them?

**Suppress** is what the DOM makes easy — `pointer-events: none` on the body, on a scoped
root, or on the parent menu; capture-phase prevention; a routing lock that discards highlight
updates. **Buffer** is Blink's alone: queue the suppressed gains and losses, annihilate a gain
against a pending loss for the same invoker, replay losses-then-gains at the end.

**Our answer: buffer.** Suppression loses the final state when the user abandons the attempt —
the enter for the sibling item the pointer actually stopped on was discarded, leaving a stale
highlight — and, decisively, _every_ suppression mechanism in the field needs a capability a
single-surface toolkit does not have (a capture phase, or CSS pointer-events; there is no grab
either). Buffering needs nothing: a bounded two-element vector of `{targetId, enterOrLeave}`,
replayed through the same step function. Blink's _placement_ is also right and should be
copied — the buffer is a filter **in front of** the hover state machine, so the machine below
is unmodified.

### Trap, or containment?

**Trap** — a global listener detects that focus escaped and pulls it back (Radix, Headless UI,
react-aria, APG's dialog, Zag). **Containment** — the traversal structure has no exit (Slint,
Avalonia, Qt Quick, WPF, Turbo Vision, GTK, ImGui, Textual).

**Our answer: containment, without hesitation.** A trap is a defence against a **second
writer** of focus, and a toolkit whose focus state is a plain id mutated only by application
calls has one writer. Ariakit is the tell: it ships a focus-trap component that nothing uses,
having achieved containment by inerting instead. Note that even the desktop toolkits choose
containment for in-window overlays — Avalonia's in-canvas host, the exact analogue, gets it
from one enum on the host.

### Overlay tree, or overlay list?

**Tree** (Turbo Vision, GTK4, Flutter, Textual, WinUI): ownership, lifetime, coordinate
translation and cascading destruction are naturally recursive, and if you do not model the
tree you grow registries — Ariakit grew three, Radix two and filed two bugs about it. **List**
(HTML/Blink, ImGui, Qt, Zag, Uno, Helix, CDK, react-aria): a list is a total order and paint
order needs a total order, whereas a tree is a partial order that must be linearised anyway —
and every attempt to make paint follow the tree produced bugs.

**Our answer: both, split by role** — and this is what the corpus converged on, not a
compromise. A flat list for paint and hit order; **one parent index per record** for
ownership; and the tree as a **query**, recomputed per operation from list order plus
containment. See [question 7](#7-overlay-tree-or-overlay-list) for exactly what breaks at
which point.

### Does the dismissing press also act on what it hit?

**Deliver** (Compose non-focusable, Avalonia's dismiss-event pass-through, company-mode's
replay): one user action, one user-visible result. Radix documents the cost of the
alternative in its own prop doc — "users will need to click twice on outside elements".
**Consume** (tmux drops it outright, Compose focusable, Radix/Qt/WinUI by default): a context
menu whose dismissing click also activates what was underneath will delete a file the user
only meant to stop looking at.

**Our answer: a per-overlay value with no default.** Compose proves both are wanted and pins
both in one parameterised test, which is exactly the shape a recording-canvas assertion
takes. Add WinUI's guard as an invariant: a forwarded press landing on the overlay's own
anchor must not reopen it.

### What replaces hover?

**Long press** is the field's plurality answer and even agrees on the constant (500 ms across
react-aria, Slint, Android's view configuration). **Tap to pin** is Flutter's first-class
enum value; it needs no timer, no gesture recognizer and no tier-2 capability. **Suppress**
is the considered answer where the content is also the anchor's accessible description.
**A visible extra hit target** is Blink's, on the principle that a gesture you cannot see is
a feature nobody finds.

**Our answer: tap-to-pin as the default, long-press as an opt-in, a visible affordance
always, suppression only when the content survives elsewhere.** See
[question 4](#4-what-replaces-hover) for the reasoning and the ownership.

### Who owns the animation clock?

**The styling layer** (Radix, Zag, Ariakit, Tippy, Headless UI, CDK, Base UI) — forced on
them by the platform, and it shows: Ariakit parses transition-delay lists with CSS's cyclic
index-matching rule and subtracts a frame to avoid a flicker; Zag and Radix compare computed
animation-name strings; Tippy carries a comment that transition-end "fires 1 frame too late
sometimes". **The toolkit** (Flutter, WPF, Qt Quick, WinUI): the duration is stated, not
discovered; completion is a frame count, not an event.

**Our answer: the toolkit, unambiguously.** This one choice deletes an entire bug class the
web camp lives with. Copy the state **shape** of Radix's presence, Ariakit's end-time
computation and Zag's presence sync; copy none of their mechanism.

### Is a tooltip the same surface as a menu?

**A different animal** (ImGui is emphatic — no entry in either popup stack, no id, no
dismissal, no focus interaction, a different lifetime, a different identity scheme, a
different draw layer; react-aria's tooltip trigger deliberately does not call its overlay
hook; GTK4's tooltip window is 480 lines of re-implementation rather than a popover
subclass). **The same surface differing only in policy** (`xdg_popup` is normatively one role
for "menus, popovers, tooltips", and popups were made non-grabbing by default precisely to
enable tooltips; floating-vue's tooltip and menu are nine lines each differing by a theme
string; Ariakit's tooltip is ~40 lines of overrides on a hovercard).

**Our answer: the same surface, because the split is substrate-dependent and we are on the
other side of it.** Every subject on the "different animal" side has a substrate letting a
tooltip opt out and still be drawn and hit-tested — a second draw layer, its own surface, a
global pointer route. With no top layer, an overlay outside the one ordered list cannot be
painted last and cannot be routed. So the tooltip **must** be a member of the registry, and
what differs is expressed as three independent policy fields: non-interactive (contributes no
hit entry), no dismissal participation, no focus policy. Heed Blink's warning on the third
axis: the moment a hover surface and a click surface can be open at once, one stack is
insufficient — and Blink's answer was a **second ordered list**, i.e. bands, which a single
precedence field expresses more cheaply.

### Is a toast the same primitive?

**Yes** — Base UI, the most deliberate decomposition in the survey, gives toast a portal, a
positioner _and_ an arrow, and its toast positioner calls the same anchoring hook as tooltip
and menu; CDK attaches a viewport-centring strategy through the same overlay handle a
connected dropdown uses; Helix's notification is literally a popup at a synthetic position.
**No** — and the reason is not geometry but **layer membership**: react-aria's toast region
carries a verbatim three-line comment that it is not hidden when an overlay opens, allows
focus outside a containing scope, and does not dismiss overlays when clicked; Zag encodes the
same split by dependency, with toast depending on dismissable and not popper while tooltip is
the exact inverse.

**Our answer: split at the seam the evidence marks, which is not placement.** Share the
placement solve — make a boundary corner an anchor variant, so a corner-anchored notifier is
one call and no second engine exists. Share the registry, but at a distinct **precedence
band** and never as a dismissable member. Do **not** share the lifetime: the queue, priority,
stacking, hover-pause and auto-dismiss belong to a notifier machine, and the corner stack is
ordinary column flow inside a boundary-anchored container.

---

## The architecture comparison

Nine internal abstractions, compared as architectures rather than as feature sets. The
question for each is: what is the unit of composition, where does state live, what does it
buy, how does it fail, and what survives off its substrate?

| Architecture         | Exemplar                                          | Unit of composition                                 | Where state lives                             | Fails by                                                       |
| -------------------- | ------------------------------------------------- | --------------------------------------------------- | --------------------------------------------- | -------------------------------------------------------------- |
| Middleware pipeline  | [Floating UI][floating-ui]                        | a fold over `(state) -> {x, y, data, reset}`        | a per-run `middlewareData` bag                | cross-middleware handshakes; unbounded resets capped silently  |
| Statechart           | [Zag][zag]                                        | a named state with entry/exit/effects               | one context record per machine                | six duplicated interpreters; async `send`                      |
| Overlay manager      | [Angular CDK][angular-cdk]                        | one concrete handle + swappable strategy objects    | six hidden inter-frame memo fields            | strategies are objects with lifecycles, so nothing is pure     |
| Positioning strategy | [Avalonia][avalonia]                              | a four-member adapter around one solver             | a POD `record struct` request                 | one boundary arm written against extent, not far edge          |
| Focus scope          | [Radix][radix] / [react-aria][react-aria]         | a scope node in a stack (or tree) with pause/resume | module-global active scope + a scope tree     | repairs a second writer of focus that need not exist           |
| Dismissable layer    | [Radix][radix] / [Zag][zag]                       | a layer registered in an ordered list               | four sets plus a document-level broadcast     | "inside" defined by containment, so branches must be re-added  |
| Provider / singleton | [react-aria][react-aria] / [compose][compose]     | a shared arbiter consulted by unrelated instances   | module globals, or one atomic mutator slot    | leaks between tests; unassertable without draining timers      |
| Platform adapter     | [Floating UI][floating-ui] / [avalonia][avalonia] | an interface of measurement or commit primitives    | none — it is a seam                           | abstracts measurement that is not abstract in a canvas toolkit |
| Protocol positioner  | [xdg_positioner][xdg]                             | a copied value evaluated in another process         | double-buffered pending/applied plus a serial | reports a rect and no side; leaves the work area undefined     |

**The middleware pipeline** is the most expressive and the least portable of the nine. Its
strength is that every stage is a pure function of a state record and every stage's output is
data the next stage may read — `flip` returns a new placement and restarts the fold, `arrow`
returns a number, `hide` returns two booleans. Its weakness is the coupling that expressiveness
invites: the arrow's nudge forces a boolean reset, and `flip` and `offset` must both stand down
by reading the arrow's data — a three-way handshake through a shared bag, which a single pure
placement function cannot host. The essential stages (overflow measurement, candidate flip,
clamp, available extent, arrow residual) transfer; the _pipeline_ does not have to.

**The statechart** buys one thing nothing else does: cancellation becomes structural. Because a
delay is an effect scoped to a state, exiting the state runs its teardown, and a stale timer is
unrepresentable. Every subject without it re-derives cancellation by hand and several get it
wrong. Its cost is that the description language and the execution engine are different things:
Zag's declarative half is inert data (states, guards, actions and effects indirected by _name_
into a separate implementations table), and its execution half is duplicated once per framework,
DOM-bound and microtask-scheduled. A value-semantics toolkit takes the first half and gets the
second for free from `step(state, input) -> state`.

**The overlay manager** and **the positioning strategy** are the same idea at two different
purity levels, and the comparison is instructive. CDK's `PositionStrategy` and `ScrollStrategy`
are _interfaces with lifecycles_ — attach, apply, detach, dispose — which buys stateful
strategies (a throttled reposition, a page-scroll block) and costs testability: `apply()` cannot
be exercised without attaching a real overlay. Avalonia's positioner is the opposite: the solver
is a plain function over a `record struct`, and the only interface is a **four-member adapter**
for the environment (screens, parent client area, scaling, commit). That adapter is the seam
that lets one byte-identical engine serve a 4K monitor and an in-window canvas — and it is
precisely the shape a backend-neutral toolkit wants, because the in-canvas arm is nine lines.
CDK's contribution that Avalonia lacks is the **total order over candidates** when nothing
fits; Avalonia's contribution that CDK lacks is the proof that the environment collapses to
four values.

**The focus scope** and **the dismissable layer** are the two abstractions most heavily
distorted by their substrate. Both exist to answer one question — _is this thing inside me?_ —
and both grew registries because the DOM's containment relation is not the ownership relation.
Radix ended up with two independently-invented registries for the same relation (one in the
dismissable layer answering "is this click inside", one in the focus scope answering "may focus
live here"), which is the strongest argument in the survey for making membership **explicit**.
The decomposition worth keeping from the focus scope is Radix's insistence that `loop` and
`trapped` are independent props, and Headless UI's finer split into a feature mask with
per-concern stacks; the mechanism — sentinels, mutation observers, the null-`relatedTarget`
carve-out — is repair.

**The provider/singleton** is the smallest architecture with the largest testability cost. Its
_content_ is tiny everywhere it appears: Compose's whole exclusivity rule is `{owner, priority}`
and one comparison; react-aria's warmth is a boolean and two deadlines; GTK's is one object per
display. Its _form_ is what hurts — react-aria's own test file drains leaked module globals in a
teardown hook, and GTK, with the same design, has no tooltip timing test at all. Hoisting the
content into the frame or session state preserves the policy exactly and deletes the global.

**The platform adapter** is where the survey's clearest architectural mismatch lives. Floating
UI's `Platform` exists solely to abstract **measurement** — three required methods — because the
library cannot see the DOM; its non-DOM implementations reduce to one-liners, and its React
Native implementation is a genuinely asynchronous measurement path. A canvas toolkit's
measurement is not abstract: layout has already produced every rect. The correct seam is
therefore Compose's, which has no measurement interface at all — four values in, one offset out.

**The protocol positioner** is the outlier and the most important one for the future. It is the
only architecture that survives a _process boundary_: the client sends a ~40-byte value and a
compositor it shares no code with solves it, with copy semantics stated normatively. That is the
strongest available proof that placement is expressible as data. It also carries the two
warnings a design must absorb: `configure` reports a **rect and no side**, so a client under a
real compositor must re-derive the arrow from the configured rect (which the newer input-method
positioner fixes by promoting the anchor rect to protocol data); and the work area is never
defined, which is the one thing making its placement non-deterministic across implementations.

---

## The ten questions

### 1. What is the minimal surface-independent core?

Six things, and every one of them is a Regular value or a pure function over Regular values:

1. **The anchor value** — kind, key, rect (or a small set of per-row rects), an optional avoid
   rect, and a tracking policy.
2. **`place()`** — anchor rect, content size, boundary rect, policy, previous decision in;
   a decision record out.
3. **The resolved geometry** — rect, side, alignment, arrow cell, available extent, an
   anchor-hidden flag, and which fallback tier produced the answer.
4. **The ordered overlay list** — open order, with a parent index and a precedence band.
5. **The reason-tagged dismissal value**, and the request/commit split that carries it.
6. **The open-versus-mounted lifetime split** — "still painting" and "still participating in
   behaviour" are two bits that end at different times.

These are identical whether the overlay is an OS popup, an in-window layer or cells in a grid.
`xdg_positioner` is the proof for (1)–(3) across a process boundary; Textual is the proof for
(4) in integer cells with no compositor; Blink's two-set removal is the proof for (6) as a data
structure rather than a convention.

What is **irreducibly surface-specific** is a shorter list than the field's code volume
suggests: the **grab** (delivery of events outside the application's own windows — and Qt
Widgets proves it is optional even on the desktop, since its own backend runs the same code
path when the grab fails); **cross-surface layering** (per-window opacity, independent hit
regions, blur-behind, unclippability); the **accessibility tree**, which no cell grid has and
which is not fakeable; the **compositor handshake** (acknowledged configures, serials, a
waiting-for-configure state — machinery a native backend adds _below_ the primitive, not inside
it); and the **existence of a clock**, which is a per-target fact rather than an assumption.

Two things sit on the boundary and must be declared rather than assumed: the **scrim's
foreground treatment** (a cell backend blends the cell background and leaves the glyph, while a
pixel backend paints a translucent layer over already-drawn glyphs — same declared intent, two
different results), and **hover itself**.

### 2. Can placement be a pure function of Regular values?

**Yes**, with two amendments the verification pass forced.

The placement _arithmetic_ — once its inputs are supplied — needs no clock, no key release, no
compositor and no OS window. Every real solver surveyed is integer arithmetic over four rects:
GTK4's ~110 lines of add, subtract, halve, min and max; ImGui's fixed-direction scan; CDK's
four clamped subtractions into a visible-area product; Compose's two per-axis candidate lists;
Helix's sixty lines of saturating `u16` arithmetic; Textual's four ints in, four ints out.

**Amendment one:** two of the inputs are genuinely inputs in the field and must appear in the
signature rather than be waved away. Several subjects consume the **pointer position** — not as
state, but as an anchor point or an _avoid_ rect (ImGui's per-kind avoid box, WPF's mouse
placement, Tippy's cursor following) — and several consume an **anchor-fragment selector** for
multi-rect anchors. **Amendment two:** the boundary is OS-derived in WPF, GTK, Qt and ImGui, so
"never queried by the solver" is an architectural rule about _where_ the query happens (in the
adapter, per Avalonia's discipline), not a claim that nobody queries.

**What `xdg_positioner` proves** is sufficiency across a process boundary: a ~40-byte POD of
plain `int`s — deliberately not fixed-point — normatively copied, produces compatible
placements from roughly twenty compositor implementations sharing no code. If a value can cross
a socket and be solved by a stranger, it can cross a function call. What it also proves, by
omission, is the cost of leaving the **work area undefined**: that is the single thing making
its results implementation-dependent, and it is being retrofitted from outside by later
protocols.

**Compose is the other key witness, in both directions.** Its `calculatePosition(anchorBounds, windowSize, layoutDirection, popupContentSize) -> IntOffset`
is an immutable interface, four values in and one integer offset out, unit-tested in a plain
host test with **no device, no window and no composition** — literally the recording-canvas
requirement. And returning **only an offset** is priced at three separate recovery hacks: a
mutable transform-origin smuggled out of a supposedly pure function, a position-calculated
callback bolted onto two providers, and a caret layer that recovers the side twice
inconsistently — once by downcasting the provider to read the _requested_ side and once by
comparing post-layout screen coordinates for the _resolved_ one. The caret's own clamp then
diverges from the placement it is meant to match: in the left-collision branch it undershoots
the tooltip-local anchor centre by `min(anchorLeft, W - w)` — i.e. by the anchor's left
coordinate in the common case — and the branch is untested, because the dedicated regression
test exercises only the full-width case. (Both functions do read the same extent, so this is
algebraic divergence between two implementations of one clamp, not a boundary mismatch.)

**Verdict for this toolkit:** a total, integer-exact, `@safe pure nothrow @nogc` `place()` is
achievable, and it must return a **decision record** rather than a rect or an offset. One
caveat is structural rather than algorithmic: the geometry vocabulary's `Point`/`Size` are
union-backed, so a named-field read is unavailable in CTFE — placement can be property-tested
and asserted on the recording canvas, but the spec must not promise compile-time evaluation.

### 3. What does the cell grid actually cost?

**Degrades gracefully** — shift, flip and size clamp are exact in integer cells, and every
DPR, zoom, transform and fractional-pixel workaround in the corpus is _deleted_: rounding by
device pixel ratio, sub-half-pixel write suppression, rounded bounding rects with their
dedicated regression tests, fractional max-height observers, ceiling of fractional GUI bounds,
derived scale factors that fall out as 1. Centring survives with one documented rounding rule
(GTK4's low-edge truncation is what a grid wants and is already what half the field does by
accident). The convex-hull safe area quantises to whole cells and becomes _more_ forgiving, not
broken.

**Degrades badly** — **arrows**, because a one-cell error is categorical: at 24 px GTK4's
leaning triangle is a subtle skew, but at one cell the caret either sits on the anchor's column
or names a different character, which is a false statement rather than a small error. **Safe
polygons**, at the gap sizes the field's defaults actually produce (offset zero in Floating UI
and Radix, gutter zero for Zag's submenus, one row in Textual and GPUI): inside the corridor
they add no discrimination over the corridor rectangle. They do retain whole-cell power
_outside_ the corridor — on the anchor's own row a hull selects only the anchor's columns while
a bounding rectangle selects the overlay's full width — so the honest statement is that the
corridor stops discriminating, not that polygons become identical to rectangles. **Shadows**
are dropped outright on a cell target, and Turbo Vision's rule is the one to copy: when a
channel is unavailable, **substitute** rather than omit (it swaps in bracket markers when
monochrome removes the shadow), because otherwise the overlay's separation from the page
disappears with the effect.

**Simply absent** — every sub-cell tolerance in the field (0.5 px buffers, 2 px interactive
borders, 4 px recede hysteresis, ±1 px rounding slack: all zero cells); velocity gates, which
are not merely coarse but **unrepresentable**, because pointer position is quantised to cells at
the input boundary on every target, so one cell in one frame already exceeds the field's
threshold several times over while a zero-cell frame reads exactly zero; angular and slope
tests; one-frame pointer deltas as an intent vector (the delta is zero on most frames, which
collapses a triangle apex onto the test point); text opacity and scale on cell backends;
transform origins as transforms.

**One hazard is created rather than removed**, and it exists nowhere else in the corpus: a
**double-width grapheme bisected by an overlay edge**. Neovim replaces the visible half of a cut
wide glyph with a space in both directions; tmux sums visible widths and falls back to a full
line redraw, then clears leading padding cells. A toolkit whose width function counts one
column per code point cannot currently even detect the condition.

### 4. What replaces hover?

**Tap-to-pin is the default; long-press is an opt-in; a visible affordance is mandatory;
suppression is legitimate only when the content survives elsewhere.**

Tap-to-pin wins on availability: a press/release pair is a tier-1 interaction on every live
target, and the terminal decodes pointer release over SGR-1006 even though it cannot report key
releases. Long-press does **not** clear that bar — a gesture is classified as a tier-2
interaction while the terminal declares tier 1, so the terminal is excluded **by declaration**
rather than by accident, and the terminal host has no frame clock to run a hold against.
Long-press is also already **spent** on the one target that needs a hover substitute: on
Android, `longPress` starts a text selection in the existing viewer, so a toolkit default of
long-press would collide with a shipped gesture. Blink supplies the third leg: a gesture you
cannot see is a feature nobody finds, so the substituted route needs a discoverable,
pointer-sized affordance — deliberately activatable but not focusable, so it adds no tab stop.

**Who owns the decision: nobody alone.** The component **declares** a trigger set; the toolkit
**resolves** it against declared input capabilities with a pure function; the resolution is
**published** as a readable value and as an accessible description. That is not a new pattern —
it is the shape already shipped for scrollbars, where a capability value drives a pure method
and a unit test makes the wrong answer unrepresentable. That is also exactly what turns the
open [`IXR26` defect][spec-ixr] ("the twoslash popup still assumes hover") from a bug to be
patched per host into a state the type system cannot express. Suppression is the fourth option
and is correct only under Apple's rule: the surface disappears, the _content_ survives as the
anchor's accessible description.

> [!WARNING]
> "Android has no hover" is a **declaration, not a physical fact**. The underlying
> NativeActivity input path already receives hover enter and exit events; the toolkit simply
> does not surface them. That matters for the accessibility argument: WCAG 1.4.13's Hoverable
> clause is conditional on pointer hover being able to trigger the content, so the obligation
> is unmet-by-omission rather than vacuous, and it binds the moment those events are forwarded
> or the content is reached through explore-by-touch.

### 5. What does a script-free HTML target get?

**Tier 0 is `:hover`, `:focus-within`, `:checked` and `details`/`summary`, and that is more
than the field assumes** — because a cell toolkit can measure before it emits, which a browser
cannot.

**Expressible.** One trigger per emitted surface, chosen at emit time — and therefore no races
either. A **fully solved placement**: the emitter can run the same `place()` in integer cells
against a declared surface size and bake the winning rect, which is strictly better than the
tier-0 story every web subject reports ("the only honest option is a fixed side plus a
max-width"). The resolved side and alignment as a class name, giving a CSS transition a correct
origin with no script. The arrow cell, since an absolutely positioned element in character
units is already in the emitter's vocabulary. The **complete static ARIA contract** — roles,
described-by, labelled-by, has-popup, controls, orientation, checked, disabled, tab index — at
zero runtime cost, which is a `switch` over an enum. The **tab-order splice**, executed
statically by placing the overlay's markup immediately after its trigger, which is exactly what
Tippy hacks at runtime and warns about when it breaks. And **an open and a close delay**, each
carried by a transition delay on a different rule, with mid-delay cancellation free because the
property simply reverts. **INFERENCE, and the weakest-grounded claim in the sweep:** that last
one is read out of CSS semantics rather than out of any subject's implementation, and it
requires switching a reveal from `display` to a transitionable property.

**Must be declared unavailable.** Warmth and skip-delay, rest gating, instant swap, max display
duration, the dismissal cascade, focus trapping and restoration, safe areas, and modality —
which the platform itself forbids, since a popover that is also a modal dialog throws. Also
unavailable: reaction to a boundary the emitter did not assume, because the reader's viewport is
not the emitter's, so the baked placement is correct with respect to the assumed grid only.

**Does CSS Anchor Positioning move the line?** For a browser, yes and substantially:
`position-area`, `position-try-fallbacks` and `position-try-order` are entirely script-free and
run in the browser's own layout engine — Blink's UA stylesheet already uses them for a native
picker. For an emitter targeting arbitrary readers it moves the line only as a **future
delegation**, and it carries a warning: anchor positioning deliberately gives up DOM containment
(a positioned box may live anywhere), and DOM containment is exactly the affordance tier-0
hover depends on. So: bake the resolved rect, keep the overlay a descendant of its trigger, and
treat anchor positioning as an optional later target rather than a substitute.

### 6. How much of Floating UI will the browser absorb?

**The geometry half is already being absorbed.** Anchor names and the anchor function replace
the rect-provider seam; `position-area` replaces the side-plus-alignment vocabulary;
`position-try-fallbacks` and `position-try-order` replace `flip()` and its ordering;
`position-visibility` replaces `hide()`; and the last-successful-position-option memo is CSS's
version of the hysteresis every mature implementation added after shipping. The top layer and
its ordered set replace the portal.

**What remains a library's job** is the interaction half — hover intent and its corridor,
delay groups and warmth, dismissal policy and its cascade beyond the platform's own light
dismiss, focus management beyond the trigger splice, and role wiring. Plus, notably, **arrow
geometry**: the CSS working group examined a dedicated pseudo-element and rejected it as
"complicated", and Level 2 recovers only _which fallback entry won_ as a container query — the
fallback index, not the side — so the datum a caret actually needs is still not published.

**What that implies about pipeline stages.** The **essential** stages are the ones the platform
is absorbing, which is the strongest possible evidence that they are the real content: signed
overflow measurement, candidate generation with an acceptance rule, the clamp, the available
extent, and the arrow residual. The **incidental** stages are the ones the platform is
_not_ absorbing because they were never about placement: the 264-line auto-update observer
apparatus (which collapses to "recompute in layout" for anything with a frame loop), the
three-method measurement `Platform` (which exists only because a library cannot see the DOM),
and the reset-plus-shared-data-bag handshake that lets the arrow nudge the popup while two
sibling middlewares stand down. A single pure `place()` keeps the five essential stages and
drops all three incidental ones.

### 7. Overlay tree, or overlay list?

**A list for order, one parent index for ownership, and the tree as a query.** The HTML
specification says so in as many words: requiring a parent to be strictly earlier in the
showing list is what "allows for the construction of a well-formed tree from the (possibly
cyclic) graph of connections". Paint needs a total order; a tree is a partial order that must be
linearised anyway; and every attempt to make paint follow the tree produced bugs.

**What breaks at which point**, with witnesses:

- **A bare stack is sufficient** up to and including single-level popups and strictly LIFO
  closing. Most terminal subjects never need more.
- **It breaks first at the outside test.** "Is this click outside me" must answer _no_ for a
  click in my descendant, and a descendant need not overlap me — so it is not a rectangle test.
  Radix, Base UI, ImGui, Zag and react-aria each built a registry for exactly this.
- **It breaks second at partial cascade.** Clicking a parent menu must close the child subtree
  but not the parent, which needs the index of the topmost ancestor — precisely what ImGui
  computes before truncating.
- **It breaks third at sibling switching.** Hovering a sibling item must close the previous
  sibling's whole subtree while keeping the parent; react-aria's depth-indexed expanded-keys
  array is the cheapest correct encoding, because the chain _is_ the array and closing a level
  is a slice.
- **It breaks fourth at non-LIFO coexistence** — a tooltip over an open menu. HTML's answer is
  instructive: it did **not** make the tooltip a child; it added a second ordered list plus a
  hint-stack parent and a position-offset trick to give the two vectors one total order. That is
  **bands, not trees**, and a single precedence field on the record expresses it more cheaply.
- **It never breaks for paint order**, which is why the tree must never touch it.

One correction the verification pass forced: appending overlay targets last gives correct
precedence _within one tree's target list_, but it does **not** give correct positional routing
at the container tier, because a dock container resolves the pane by rectangle first. A
top-layers rung tested front-to-back **before** the positional pane query is required — exactly
as the containers spec already reserves — in addition to the non-positional decisions
(dismiss-on-miss, modal gating, close-request routing).

### 8. Where does adaptive presentation belong?

**The rule is toolkit code, the fact is host data, the override is a field on the overlay's own
configuration.** Three layers, and no platform name anywhere in application code.

WPF states the split most cleanly — "the primitive owns the substitution rule, the component
owns the fact" — and implements it as a placement enum re-mapped when a bound flag says the
trigger was the keyboard, so the primitive never learns what a keyboard is. WinUI passes the
fact as a plain parameter. Compose's structure is the one to copy: **both routes present in the
widget tree unconditionally**, with the unavailable one simply never firing, rather than the
tree branching on the target. Avalonia adds the discipline that closes the loop: the **outcome
must be observable**, published as a readable property, because a golden test and an accessible
description both need to read which form was chosen.

The **form ladder** — anchored, flipped, slid, shrunk, docked to an edge, suppressed — belongs
in the **primitive**, as additional candidates in one ordered fallback list, each a geometry-only
value. CSS anchor positioning independently argues for exactly that restriction: a fallback
option may touch only inset, margin, sizing, self-alignment and the anchor reference, "the
smallest group of properties that affect just the size and position of the box itself, without
otherwise changing its contents or styling", so trying one costs one layout pass and can never
change content. The **trigger substitution** is the one exception that changes the tree, because
a tap affordance is a real, hit-testable, paintable node that hover does not need.

What belongs to **application policy** is narrower than it looks: which trigger set to declare,
which of several offered forms to prefer, and what to do when the resolution reports a drop. The
platform conventions those choices should respect — where a menu may cover the system chrome,
what a context menu owes the main interface, how a light or dark appearance and an accent colour
reach the overlay's palette — belong to [platform-ui-guidelines][pug] and the
[theme spec][spec-theme], not here.

### 9. What must the API not foreclose?

Six commitments, each cheap now and expensive to retrofit. The mechanics a native layer would
add underneath — the compositor grab, the X11 override-redirect alternative, and the end-to-end
windowing harness that would test them — are surveyed separately in
[window-system-integration][wsi]; what follows is only the shape the overlay API must keep so
that layer can slot in without touching a single consumer.

1. **Keep the placement request structurally isomorphic to a protocol positioner** — anchor
   rect, anchor edge, gravity, constraint-adjustment bitmask, offset. A native backend can then
   hand a compositor a _positioner_ rather than a pre-solved rect, and keep compositor-side
   repositioning. GTK4 proves the value is enough: the same `GdkPopupLayout` serves a popover, a
   tooltip window and a text handle.
2. **Publish intent, never mechanism.** WinUI's constrain-to-root-bounds is public while
   "is windowed" is internal, and both it and Avalonia re-decide the host **per open**. A
   consumer says "surface scope" and a band; it never says "windowed".
3. **Fix the grab-shaped commitment at open time and make it immutable.** `xdg-shell` errors if
   a client tries to grab after mapping, so a popup cannot become grabbing later. Declaring that
   now — even though no current target can enforce it — is what stops a tooltip becoming a menu
   mid-life.
4. **Keep the resolved anchor rect unclamped** and expose the protocol's parent-geometry clamp
   as an output policy, because a hover anchor inside a scrolled pane may legitimately extend
   outside it.
5. **Accept, and document, that acceptance rules differ.** GTK4's in-process solver — the one
   its non-Wayland backends use — takes a flipped position whenever its overflow does not
   _exceed_ the unflipped one's, while the protocol reverts unless the flip is fully
   unconstrained. Both rules were read directly and they produce observably different placements
   (a primary overflowing right by 100 against a secondary overflowing left by 5: the protocol
   keeps the primary, GTK takes the secondary), which the subsequent slide then pins to
   _opposite_ edges. The divergence is observable **inside one toolkit**, between its own
   backends. A native backend is therefore a documented backend difference unless the policy
   value is chosen to make the two agree.
6. **Design `place()` to also accept "here is the rect the compositor gave me, re-derive the
   arrow"**, because a popup configure event reports a rect and no side — and the newer
   input-method positioner in the same protocol tree fixes exactly that by promoting the anchor
   rect, in popup-local coordinates, to protocol data.

### 10. Final synthesis

Designing this in 2026 with no backward-compatibility constraints **and** this toolkit's
constraints, the architecture is: **one Regular anchor value; one pure `place()` returning a
decision record; one flat ordered overlay list with a parent index and a small closed set of
precedence bands; one reason-tagged dismissal value evaluated as a policy flags word ANDed with
the offered cause; and everything else composed from state machines the toolkit already owns.**
Triggers, timing, focus, modality and semantics are _policy values_ on the overlay record, not
mechanisms inside the primitive. Placement runs inside the frame pass immediately after layout
has measured; there are no observers, no portals, no z-index, no stacking contexts, no global
priority integers and no strategy objects. Every behaviour is a pure function of Regular values
plus one injected clock, so every behaviour is assertable on a headless recording target — which
is more than any surveyed subject manages.

One idea from each system:

| From                               | Take                                                                                                |
| ---------------------------------- | --------------------------------------------------------------------------------------------------- |
| [Floating UI][floating-ui]         | the anchor as a value behind one seam, and the signed-overflow primitive every decision reads       |
| [xdg_positioner][xdg]              | the placement request as a normatively copied POD — and name the work area it forgot to             |
| [GTK4][gtk4]                       | the six-bit per-axis adjustment mask, and returning the **mirrored gravities** as the result        |
| [Angular CDK][angular-cdk]         | the four-tier total order over candidates when nothing fits                                         |
| [Avalonia][avalonia]               | the four-member environment adapter that lets one engine serve a monitor and an in-window canvas    |
| [react-aria][react-aria]           | placement returning a decision record, and the arrow's overlap constraint acting **on** the popup   |
| [Floating UI][floating-ui] (again) | the arrow residual as the hide signal — exact equality, no tolerance                                |
| [Compose][compose]                 | both interaction routes installed unconditionally, and the substituted route **announced**          |
| [WPF][wpf]                         | the convex-hull safe area as a pure integer predicate, with its rationale written down              |
| [Blink][blink]                     | buffering the suppressed hover events with gain/loss annihilation, as a filter in front             |
| [Zag][zag]                         | delays as **states**, so cancellation is structural rather than disciplined                         |
| [Headless UI][headlessui]          | a total dispatch table over the action enum, so a missing transition is a compile error             |
| [Qt Quick Controls][qt-quick]      | dismissal as one flags value ANDed with a cause offered in the same vocabulary                      |
| [HTML popover][popover-api]        | the close request as one input on key-down, and hide-until-endpoint as the single funnel            |
| [Blink][blink] (again)             | two sets, so "still painting" and "still participating" end at different times                      |
| [Textual][textual]                 | the three resets — order, clip, and **extent** — that make a top layer in integer cells             |
| [GPUI][gpui]                       | blocking as a three-valued behaviour on the hit rect, enforced inside the hit walk                  |
| [Flutter][flutter]                 | the group key that collapses a whole menu chain into one unit for the outside test                  |
| [WinUI][winui]                     | five separately named modality effects, and deriving the blocker from the open set at hit time      |
| [Base UI][base-ui]                 | one shared parameter interface of purely geometric fields, and named collision presets              |
| [Turbo Vision][turbo-vision]       | write-then-act: no branch performs an action, one tail block decides — plus substitute, don't omit  |
| [tmux][tmux]                       | the caret parked on the selected item — nine lines, and a terminal's only real assistive channel    |
| [Helix][helix]                     | decide-then-measure: the side chooses the size budget, so it must be chosen first                   |
| [Neovim][neovim]                   | requested and resolved geometry in different fields, stated in the header and proven by violation   |
| [Slint][slint]                     | containment from one boolean in the parent walk — and its no-flip default as the counterexample     |
| [ImGui][imgui]                     | openness derived from two array lengths, and retry-last-direction-first hysteresis                  |
| [Apple][apple]                     | the host owns the form; the application's override rides with the content                           |
| [APG][aria-apg]                    | interactive hover content is a **different widget**, and the off-screen (not `display:none`) reveal |
| [css-anchor][css-anchor]           | a fallback candidate may change geometry and nothing else                                           |
| [Radix][radix]                     | `loop` and `trapped` are independent; and the routing consequences matter more than the corridor    |
| [notcurses][notcurses]             | one probe into capabilities, then equal-width glyph substitution at each draw site                  |
| [ratatui][ratatui]                 | in cells, "on top" means "wrote to the same index later" — so clear before you draw                 |

---

## How this survey was verified

Every subject was read at a pinned revision (the [revision ledger][index] records each one),
and every load-bearing statement the analysis raised was then attacked by **two independent
adversarial lenses**: a _source_ lens asking whether the cited code says this at the pinned
revision, and a _scope_ lens hunting overreach, misattribution, staleness, and inference
laundered into observed fact. The merge rule was conservative — either lens refuting makes a
claim refuted; either lens downgrading makes it downgraded; a single lens passing is not a pass.

**A large fraction of the first-pass claims did not survive.** Of 147 claims:

| Outcome                               | Claims | May a requirement rest on it?      |
| ------------------------------------- | ------ | ---------------------------------- |
| usable as written (`upheld`)          | 6      | yes                                |
| usable with a corrected detail        | 37     | yes, with the corrected wording    |
| usable only in a narrowed restatement | 93     | yes, **only** in the narrowed form |
| struck out (`refuted`)                | 11     | no                                 |
| never checked                         | 0      | —                                  |

So **43 of 147 claims may carry a requirement as stated** — and only **6** of those survived
entirely untouched, the other 37 needing a detail corrected. **93 survived only after being made
narrower.** The dominant failure mode was not a wrong citation — most citations checked out
line by line — but an **overreaching claim**: a correct citation carrying a universal
quantifier ("every subject", "the only system", "always", "never"), a number with no source, or
an analytical conclusion stated as an observation. The second most common was **misattributed
scope**: a rule true of one family (anchored overlays that must stay visibly attached) asserted
of another (menu cascades, where deliberate overlap is a shipped design).

Concretely, the eleven refuted claims include: that a missing key-release capability costs the
primitive exactly one trigger (it costs the whole release-edge key family, including
lone-modifier gestures that have no press-edge alternative at all); that one stored open-cause
enum subsumes every cross-trigger suppression rule (it subsumes the open-time readers, but not
time-scoped suppression, close-cause suppression, or pointer-down-derived focus suppression);
that a safe polygon degenerates to its bounding rectangle at cell resolution (it stops
discriminating _inside_ the corridor, and retains power outside it); that quantisation makes a
direction latch strictly more reliable (it makes the latch's zero-delta guard _more_ necessary);
that nothing in the focus dimension needs a key release; that a paint/routing split maps
exactly onto two existing timeline predicates; that transition suppression is a pure function of
the open-change reason; that inverting a blocking loop into a step function is mechanical; and
that a single coordinate space removes the duplicated-placement failure class — refuted by this
repository's own two call sites, which disagree on the boundary, the vertical offset and the
clipping while sharing one coordinate space.

The surviving statements are the **narrower** ones, and this page uses them in their narrowed
form throughout. Where a statement is analysis rather than observation it is marked
**INFERENCE**. The full per-claim record — the verdicts, the counterexamples that produced them,
the corrected scope, and the restated wording — is kept with the survey's grounding material as
`dropped-claims.md` and `corrections.md`, alongside the verdict ledger; those files are internal
QA artefacts and are excluded from the published site, in the same way the parsing survey's
claim ledger is.

> [!NOTE]
> Two caveats a reader should carry forward. First, the matrix at the top of this page
> compresses judgements that the per-dimension sections qualify; where the two disagree, the
> prose is the finding. Second, several subjects were read as sparse checkouts or, in one case,
> from documentation only — the [master catalog][index] marks which, and a claim about a subject
> read from docs is a claim about what its documentation states, not about its implementation.

---

<!-- References -->

[index]: ./index.md
[concepts]: ./concepts.md
[forget]: ./features-people-forget.md
[baseline]: ./sparkles-baseline.md
[proposal]: ./proposal.md
[floating-ui]: ./floating-ui.md
[react-aria]: ./react-aria.md
[radix]: ./radix.md
[base-ui]: ./base-ui.md
[zag]: ./zag.md
[tippy]: ./tippy.md
[floating-vue]: ./floating-vue.md
[angular-cdk]: ./angular-cdk.md
[ariakit]: ./ariakit.md
[headlessui]: ./headlessui.md
[popover-api]: ./popover-api.md
[css-anchor]: ./css-anchor.md
[aria-apg]: ./aria-apg.md
[qt-quick]: ./qt-quick-controls.md
[qt-widgets]: ./qt-widgets.md
[gtk4]: ./gtk4.md
[avalonia]: ./avalonia.md
[winui]: ./winui.md
[wpf]: ./wpf.md
[slint]: ./slint.md
[uno]: ./uno.md
[gpui]: ./gpui.md
[imgui]: ./imgui.md
[compose]: ./compose.md
[flutter]: ./flutter.md
[apple]: ./apple.md
[xdg]: ./xdg-positioner.md
[blink]: ./blink.md
[neovim]: ./neovim-floats.md
[nvim-completion]: ./nvim-completion.md
[nui]: ./nui.md
[textual]: ./textual.md
[ratatui]: ./ratatui.md
[helix]: ./helix.md
[turbo-vision]: ./turbo-vision.md
[notcurses]: ./notcurses.md
[tmux]: ./tmux-popup.md
[emacs-posframe]: ./emacs-posframe.md
[wsi]: ../window-system-integration/index.md
[pug]: ../platform-ui-guidelines/index.md
[ui-layout]: ../ui-layout/index.md
[sean-parent]: ../sean-parent/index.md
[spec-prn]: ../../specs/ui/principles.md
[spec-stm]: ../../specs/ui/state-machines.md
[spec-input]: ../../specs/ui/input.md
[spec-dck]: ../../specs/ui/containers.md
[spec-tgt]: ../../specs/ui/backends.md
[spec-wgt]: ../../specs/ui/widgets.md
[spec-theme]: ../../specs/ui/theme.md
[spec-ixr]: ../../specs/ui/interaction-review.md
