# Features people forget

Fifty-six capabilities that a naive anchored-overlay implementation misses, drawn from
the 38 primary-source subjects surveyed in this catalog. Each one is something a
shipping system had to add — usually after a bug report, often with the rationale
written into the source — and each one has a concrete, user-visible failure attached to
it. This is the checklist [`proposal.md`](./proposal.md) is judged against and the
sharpest test of the catalog's framing question: **which of the state of the art
survives on a toolkit that renders every overlay inside one surface, in integer cells,
on targets that variously lack hover, key releases, scripting, and an OS window?**

**Last reviewed:** August 14, 2026

## How to read an entry

Every entry has the same three parts:

- **Where it is done right** — the surveyed system, cited to the upstream source at the
  revision recorded in the catalog's revision ledger. The subject's deep-dive is linked
  from the system name.
- **Failure it prevents** — a specific, user-visible symptom. Not "a bug": a thing a
  person sees happen on screen.
- **Cost on one surface** — what the capability costs `sparkles:ui` given integer cells
  ([`LAY3`][spec-layout]), a TUI target with whole-cell pointers and no key release
  ([`INP16`][spec-input]), an Android target with no hover at all, and a static-HTML
  target with no script, no timers and no measurement ([`TGT5`][spec-backends]).

Each **Cost on one surface** paragraph carries one of four tags:

| Tag          | Meaning                                                                                                               |
| ------------ | --------------------------------------------------------------------------------------------------------------------- |
| **Free**     | Expressible with the vocabulary `sparkles:ui` already owns; costs arithmetic over `Rect`/`Insets` and nothing else    |
| **Declare**  | Expressible, but only if the primitive takes a capability or a policy as an explicit input rather than discovering it |
| **Degrades** | Survives on some targets and must have a stated substitute on the others                                              |
| **Absent**   | Not expressible on at least one live target; the design must say so rather than pretend                               |

> [!IMPORTANT]
> The claims here were adversarially verified, and a large fraction of the survey's
> broader generalisations did not survive. Where a phase-2 claim was narrowed, this page
> uses the narrowed wording; where it was refuted, the claim is absent. In particular:
> a safe polygon does **not** collapse to its bounding rectangle on a cell grid
> (entry 24), direction latching does **not** become more reliable under quantisation
> (entry 25), and "no key release" costs the TUI **keyboard** press-and-hold only, not
> pointer long-press (entry 55). Statements that are this survey's inference rather than
> a source's own claim are marked _inference_ in the text.

> [!NOTE]
> Citations are upstream URLs pinned to the exact revision each subject was read at.
> Paths inside this repository (`libs/ui/src/...`) are given as plain repo-relative
> paths, never as links.

---

## Anchoring

### 1. A zero-size anchor rect is legal, and a point anchor is 1×1

- **Where it is done right** — [`xdg_positioner`](./xdg-positioner.md) permits an anchor
  rectangle of zero size; only a _negative_ size is a protocol error
  ([`xdg-shell.xml:180`][xdg-anchor-rect], added deliberately in commit `e49a2c0`).
  [Avalonia](./avalonia.md) takes the complementary decision on the consumer side and
  materialises `PlacementMode.Pointer` as
  [`new Rect(position, new Size(1, 1))`][avalonia-pointer-rect] with `Anchor=TopLeft`,
  `Gravity=BottomRight`.
- **Failure it prevents** — an API that demands a non-empty anchor forces every caller
  with a cursor position or a text caret to fabricate a rect, and the fabricated extent
  shifts the derived anchor point by half its size. In pixels that is a rounding error;
  in cells it is a whole cell, so the context menu opens one column off the click.
- **Cost on one surface** — **Free**. Both conventions are `Rect` values today. The
  caveat is narrower than it looks: where arrow geometry participates in a cross-axis
  clamp, a small anchor can invert the clamp interval —
  [React Aria's `calculatePosition.ts:298-303`][react-aria-clamp] inverts when
  `2*(arrowSize + arrowBoundaryOffset)` exceeds the anchor's cross extent plus the
  overlay's, and its `clamp` then silently returns `max` — so a cell-grid arrow
  computation should assert `min <= max` rather than trust the clamp.

### 2. The anchor is clamped to the parent's usable bounds, not to the screen

- **Where it is done right** — [`xdg_positioner`](./xdg-positioner.md) states that the
  anchor rectangle may not extend outside the parent surface's _window geometry_
  ([`xdg-shell.xml:176-178`][xdg-anchor-bounds]), and window geometry
  [deliberately excludes shadows and client-side decoration padding][xdg-window-geometry].
  A separate post-condition requires the popup to intersect with, or be at least
  partially adjacent to, its parent ([`xdg-shell.xml:130-132`][xdg-adjacency], commit
  `375385e`: "some restrictions must be placed on this or else it becomes legal for the
  compositor to place popups in unexpected locations").
- **Failure it prevents** — a popup anchored to the invisible shadow margin of a
  decorated window floats detached from the frame, with a consistent off-by-shadow-width
  error; and a constrained popup, absent the adjacency rule, is legal to relocate to an
  arbitrary far corner of the screen, so no pointer path exists between trigger and
  popup at all.
- **Cost on one surface** — **Declare**. The cell-grid analogue of "window geometry" is
  the anchor's pane or clip rect, and `sparkles` has no single answer for it today: the
  three in-repo `clampOrigin` call sites disagree on unit and boundary — `apps/hue/src/gui.d:2900`
  passes pixels and an anchor-relative edge, `apps/hue/src/tui.d:654` passes cells and the
  pane width with a clip, `apps/hue/src/twoslash_tui.d:267` passes cells and the whole grid,
  unclipped. Making the boundary an explicit parameter of `place()` is what closes it.

### 3. An inline (text-range) anchor is multi-rect, and its row is captured at pointer-enter

- **Where it is done right** — [Base UI](./base-ui.md) prefers the _line index_ recorded
  at pointer-enter over re-hit-testing the stored client coordinates when the popup is
  finally positioned ([`inlineRect.ts:146-148`][base-ui-inline], with a test named
  "reuses the captured line index if client coordinates become stale").
  [WPF](./wpf.md) handles a `ContentElement` owner — a `Hyperlink` spanning several
  wrapped lines — as a genuine multi-rect anchor via `IContentHost.GetRectangles`, and
  builds the safe area's hull over all of them
  ([`PopupControlService.cs:864-892`][wpf-safearea-multirect]).
  [Floating UI's](./floating-ui.md) `inline()` returns `{}` when `getClientRects()`
  yields an empty array ([`inline.ts:85-87`][fui-inline]).
- **Failure it prevents** — with a 600 ms open delay the pointer has drifted by the time
  the popup positions, so re-hit-testing anchors the card to a _different_ line than the
  one the user pointed at. On the WPF side, a hull built from one fragment of a wrapped
  link dismisses the tooltip as soon as the pointer approaches from the other line. And
  `min()`/`max()` over an empty rect list yield `Infinity`/`-Infinity`, so a detached or
  collapsed range positions the surface at `NaN`.
- **Cost on one surface** — **Free**, and already half-built:
  `libs/ui/src/sparkles/ui/state.d:415` `selectionRects` returns one rect per covered
  span segment per wrapped row. hue's two TUI call sites keep only `rs[0]`. That is
  harmless _today_ — a twoslash hover node is a single space-free identifier and the wrap
  engine never splits a word — so the extra rects are same-row segments and `rs[0]` is the
  correct leftmost anchor. The multi-rect anchor becomes load-bearing the moment a text
  range that can contain a wrap point (a query span, an error span, a selection) is
  anchored.

### 4. A multi-line selection is collapsed before anchors are derived

- **Where it is done right** — [Flutter](./flutter.md) collapses a multi-line text
  selection to the _full editing-region width_ rather than to the union of the line
  rects, before deriving toolbar anchors
  ([`text_selection_toolbar_anchors.dart:81-89`][flutter-selrect]).
- **Failure it prevents** — a toolbar anchored to the union of a jagged multi-line
  selection jumps horizontally every time the selection grows by one character on the
  last line, because the union's centre moves with it.
- **Cost on one surface** — **Free**. It is a rect-union policy over the same per-row
  rects entry 3 needs, and it is the kind of decision that must be _named_ in the anchor
  value ("hull" vs "first rect" vs "region width") rather than baked into the producer.

### 5. The anchor may align an interior row, not the surface corner

- **Where it is done right** — [AppKit](./apple.md)'s
  [`NSMenu.popUp(positioning:at:in:)`][apple-popup-positioning] places "the top left
  corner of the specified item" at the supplied point — a _named menu item_, not the top
  left of the menu.
- **Failure it prevents** — this is what makes a Mac pop-up button feel right. Without
  it, a combobox opens with its first item under the cursor, so the currently selected
  value jumps somewhere else on screen and the user loses their place in a long list.
- **Cost on one surface** — **Free**, and unusually cheap in cells: the interior offset
  is an integer row count the overlay's own layout already knows, subtracted from the
  placed origin. It does, however, require `place()` to accept an _offset within the
  content_ as an input — a parameter most placement APIs in the survey do not have.

### 6. A sub-rect of the trigger doubles as the hover hit region

- **Where it is done right** — [GTK4](./gtk4.md)'s `tip_area` is both the anchor
  rectangle and a containment test: the tooltip hides when the pointer leaves the
  caller-declared sub-rectangle even though the widget under the pointer has not changed
  ([`gtktooltip.c:994-999`][gtk-tiparea]). The re-query additionally walks _up_ the
  ancestor chain transforming coordinates at each step, so a container can answer for a
  child that declined ([`gtktooltip.c:519-578`][gtk-requery]).
- **Failure it prevents** — in a table or tree, moving between rows of the same widget
  keeps the previous row's tooltip on screen, describing a row the pointer left. The
  ancestor walk prevents the mirror failure: cell-level tooltips, which are answered by
  the view rather than the cell, would be impossible if only the picked leaf could carry
  one.
- **Cost on one surface** — **Free**. `sparkles`' hit list is already per-`hitId` rather
  than per-widget (`libs/ui/src/sparkles/ui/widget.d:101`), so a sub-rect anchor is an
  ordinary entry. [Textual](./textual.md) reaches the same destination from the other
  direction — resolving tooltip content by walking `ancestors_with_self` and taking the
  first non-`None` `.tooltip` ([`screen.py:1615-1621`][textual-tooltip-inherit]), which
  fixed a reported bug where a `ProgressBar`'s tooltip never fired because the pointer
  was always over an internal child.

### 7. Anchor-clipped detection asks a scoped question, and hiding is not closing

- **Where it is done right** — [CSS Anchor Positioning](./css-anchor.md) scopes the
  anchor-clipped test to boxes that are ancestors of the _anchor_ but descendants of the
  _positioned box's_ containing block ([`Overview.bs:2265-2270`][css-clipped]) — i.e. "is
  the anchor hidden by something the popup is not also hidden by". `force-hidden` then
  propagates along chains of anchored boxes ([`Overview.bs:2297-2301`][css-chained]), and
  [Blink](./blink.md) implements the visual half by making the anchored element's
  `PaintLayer` invisible rather than closing or unmounting it
  ([`out_of_flow_layout_part.cc:438-478`][blink-posvis]).
  [Base UI](./base-ui.md) adds the degenerate case Floating UI's overflow test misses: an
  anchor whose rect is exactly `{0,0,0,0}` is hidden ([`hideMiddleware.ts:6-7`][base-ui-hide]).
- **Failure it prevents** — three distinct symptoms. A popup living inside the same
  scroller as its anchor blinks out the moment that scroller scrolls, even though the
  popup is being clipped by the very same scroller. A submenu chain, hidden only at the
  first link, leaves the second "floating in a nonsensical location" (the spec's own
  phrasing). And a detached or never-laid-out anchor reports a zero rect that overflows
  nothing, so the popup renders anchored to the viewport origin.
- **Cost on one surface** — **Declare**, and it exposes a real gap. In `sparkles`,
  `keyedRects` (`state.d:504`) and `selectionRects` (`:415`) do **not** apply the clip
  stack while `hoverTargets` (`:64`) and `keyTargets` (`:105`) do — so an anchor resolved
  through either of the first two yields a full rect for a widget scrolled out of its
  viewport. A clipped _keyed_ producer already exists; what is genuinely missing is a
  clipped `selectionRects` and an explicit hidden/clipped flag, because `keyTargets`
  returns only the visible intersection and drops fully-clipped entries, so it cannot
  distinguish "scrolled out" from "gone".

### 8. Anchor tracking is a per-anchor policy, not a fixed rule

- **Where it is done right** — [WPF](./wpf.md) captures the mouse anchor rect **once**
  per open and reuses it for every subsequent reposition, with the reason in the source:
  a content-size animation would otherwise re-read the live cursor on every reposition
  ([`Popup.cs:2306-2316`][wpf-mouserect]). [Dear ImGui](./imgui.md) latches
  `OpenPopupPos`/`OpenMousePos` in `OpenPopupEx` ([`imgui.cpp:12505`][imgui-openpopup]).
  Against that, [Helix](./helix.md) re-reads the cursor **every frame** for a resizable
  popup and latches only the column, while the cursor's screen _row_ is unchanged
  ([`popup.rs:128-135`][helix-hysteresis], commit `e2594b64` "move popup when cursor line
  changes"), and [Compose](./compose.md) does the inverse for a _widget_ anchor: a
  memoising provider that ignores anchor movement and re-places only when window size,
  layout direction or content size changed
  ([`DefaultTextContextMenuDropdownProvider.android.kt:193`][compose-maintainpos]).
- **Failure it prevents** — the latched half prevents an overlay crawling across the
  screen behind the pointer while its own content animates. The live half prevents a
  completion menu that is frozen at the position it had three keystrokes ago. The Compose
  half prevents a text context menu sliding around while the user scrolls the text under
  it.
- **Cost on one surface** — **Free**, if tracking is a field on the anchor value rather
  than a rule in the engine. `latched` is the right default for a pointer-derived point
  anchor, and on the TUI the latch instant must be the **press**, since there is no key
  release ([`INP16`][spec-input]). Helix's row hysteresis is the cheapest known cure for
  cell-grid jitter and costs one stored integer.

---

## Placement and collision

### 9. Flip compares how bad each candidate is, rather than asking "does it fit"

- **Where it is done right** — [GTK4](./gtk4.md)'s `maybe_flip_position` computes a
  _badness_ for the primary position and rejects the mirrored candidate if its excess
  exceeds that badness ([`gdksurface.c:263-283`][gtk-flip]). The
  [`xdg_positioner`](./xdg-positioner.md) protocol takes the opposite rule: a flip that
  leaves the popup still constrained is rolled back to the pre-flip position
  ([`xdg-shell.xml:296-299`][xdg-flip-revert]).
- **Failure it prevents** — GTK's rule prevents flipping a popup from 5 px of overflow on
  the right into 300 px of overflow on the left. The protocol's rule prevents the classic
  "the tooltip jumped to the other side and is _still_ cut off, but now also covers the
  trigger".
- **Cost on one surface** — **Declare**. The divergence is real and observable _inside
  one toolkit_: GTK4 solves the same positioner value in-process for its non-Wayland
  backends (win32, macOS, X11, Android, Broadway) with a different acceptance rule than
  the compositor applies on Wayland, and the subsequent slide pins the two results to
  opposite edges. So the acceptance rule is a policy `place()` must name, not a detail —
  and a future `sparkles` native-windowing backend delegating to a real `xdg_popup` will
  not necessarily reproduce the in-surface placement.

### 10. Flip mirrors the anchor edge and the gravity together, from the original rect

- **Where it is done right** — [`xdg_positioner`](./xdg-positioner.md) specifies that a
  flip re-evaluates placement from the **original** anchor rect and offset with inverted
  anchor and gravity, rather than mirroring the computed rect
  ([`xdg-shell.xml:308-310`][xdg-flip-y]); commit `8f96c07` exists solely to pin this,
  noting that "while there is no currently known usages ... it must still be specified so
  compositors behave the same". [Avalonia](./avalonia.md)'s `ManagedPopupPositioner`
  implements the same shape ([`ManagedPopupPositioner.cs:146-160`][avalonia-flip]). By
  contrast [Textual](./textual.md)'s `Region.inflect`
  ([`geometry.py:999-1041`][textual-inflect]) and [GPUI](./gpui.md)'s
  `Bounds::from_anchor_and_size` ([`geometry.rs:837`][gpui-anchor-bounds]) reflect the
  placed region about a point.
- **Failure it prevents** — the two differ whenever the offset is non-zero on that axis:
  an arrow-bearing popover with an 8 px anchor offset flips to the wrong _distance_
  (the gutter applied in the wrong direction) and its caret visibly detaches from the
  trigger.
- **Cost on one surface** — **Free**. In cells the gutter is 0 or 1, so the divergence is
  exactly one row — which on a grid is the difference between "adjacent to the anchor"
  and "one blank row away from it", and the arrow glyph then points at the wrong
  character. `Textual` separately compensates by treating opposing margins as
  _overlapping_ rather than summing them ([`geometry.py:1037-1040`][textual-inflect-max],
  recorded as a deliberate change), which is the same failure caught one layer down.

### 11. Slide clamps the far edge first, and an over-large overlay pins to the near edge

- **Where it is done right** — [GTK4](./gtk4.md) clamps the far edge and _then_ the near
  edge, in that order ([`gdksurface.c:374-390`][gtk-slide]).
  [`xdg_positioner`](./xdg-positioner.md) specifies the same walk: slide stops when the
  _far_ edge would become constrained and never pushes the near edge out to rescue it
  ([`xdg-shell.xml:259-287`][xdg-slide]). [Angular CDK](./angular-cdk.md) aligns only the
  leading edge when the overlay is larger than the viewport, with two specs pinning the
  exactly-equal boundary ([`flexible-connected-position-strategy.ts:742-756`][cdk-push]).
  [Textual](./textual.md)'s `translate_inside` clamps with the origin winning
  ([`geometry.py:991-993`][textual-translate]), and [Ratatui](./ratatui.md)'s
  `Rect::clamp` clamps _size_ before computing the shift bound so the "too large" case
  lands at the boundary origin rather than underflowing
  ([`rect.rs:387-393`][ratatui-clamp]).
- **Failure it prevents** — the opposite order leaves a popup wider than the viewport
  flush with the right edge, so its _start_ — the part users read first, and where the
  arrow points — scrolls off-screen. In a `u16` coordinate space the naive form is worse
  than cosmetic: an unguarded `width - 2*margin` wraps to ~65534 and the next paint writes
  far outside the buffer.
- **Cost on one surface** — **Free**, and mandatory. `sparkles`' geometry is signed `int`
  cells and positions may legitimately be negative (content scrolled above or left of the
  viewport), so today's `clampOrigin`, which clamps to `0`, is wrong for any boundary that
  does not start at the origin — the same class of defect as Avalonia's
  `ManagedPopupPositioner.cs:182` subtracting `X` from `bounds.Width` instead of from
  `bounds.Right`.

### 12. The gutter is applied before constraint testing, not after

- **Where it is done right** — [`xdg_positioner`](./xdg-positioner.md) applies the offset
  _before_ the constraint adjustments, so the offset position is what gets tested and
  adjusted ([`xdg-shell.xml:356-358`][xdg-offset]). [Ariakit](./ariakit.md) reaches the
  same conclusion from the arrow's side: the gutter always includes half an arrow's
  height, and a detached `div` is created purely to be measured when the author renders no
  arrow ([`popover.tsx:126-133`][ariakit-gutter]).
- **Failure it prevents** — testing the un-offset rect and adding the gutter afterwards
  pushes the popup back out of the work area _after_ the adjustment already "fixed" it —
  the arrow gap re-introduces exactly the overflow the flip just resolved. Ariakit's
  version prevents the subtler one: switching an arrow on silently changes the popup's
  distance from its anchor, so a popover with an arrow and one without need different
  gutter values to look the same.
- **Cost on one surface** — **Free**. On a cell grid the arrow's main-axis cost is a
  0-or-1-cell constant known before layout, so it is an ordinary term in the fit test
  rather than something recovered by measurement.

### 13. The arrow's inset is a term in the fit test, and a centred placement dies on the anchor's midpoint

- **Where it is done right** — [WinUI](./winui.md)'s `TeachingTip` tests
  `contentHeight - MinimumTipEdgeToTailCenter() > space.Top + target.Height/2` for its
  corner-aligned placements ([`TeachingTip.cpp:1999`][winui-tailfit]), and separately
  knocks out every centred placement when the target's **midpoint** is off-viewport, not
  merely its edge ([`TeachingTip.cpp:1961`][winui-midpoint]).
- **Failure it prevents** — for a corner-aligned placement the popup extends from the
  arrow toward one side, so a fit test that only asks "does the height fit above the
  anchor" passes, the popup is then positioned with its arrow on the anchor centre, and
  its far end runs off the surface. The midpoint check catches the mirror case: an anchor
  half-scrolled off the left edge has a perfectly visible edge and an off-surface centre,
  so a `Top`/`Bottom`/`Center` placement hangs off the side.
- **Cost on one surface** — **Free**, and directly relevant: `sparkles` has no arrow
  constraint of any kind. Nothing in `sparkles:ui` clamps `arrowOffset` against the box
  extent, so `arrowOffset >= width - 2` unconditionally overwrites the box's corner glyph
  and larger values paint outside the box — bounded only by the surface rect and whatever
  clip happens to be pushed (`grid_canvas.d:129-138`, `cells.d:149-151`), never by the box.

### 14. Resize is a last resort, it is reversible, and it is a negotiation

- **Where it is done right** — In [`xdg_positioner`](./xdg-positioner.md) resize fires
  only after flip and slide have both failed, and is reported back to the client for
  re-layout rather than being a silent clip ([`xdg-shell.xml:317-326`][xdg-resize];
  commit `c09e899` frames it as feedback: "In order to get feedback of available space
  where a client can create its popup"). [GTK4](./gtk4.md) requests resize hints only
  when the widget can actually shrink in that orientation, and **vetoes** an unacceptable
  granted size by popping the popover down rather than rendering broken content
  ([`gtkpopover.c:749-797`][gtk-acceptable-size]). [Qt Quick Controls](./qt-quick-controls.md)
  restores a popup's implicit size once it fits again, and marks the assignment
  non-explicit by clearing `widthValidFlag`/`heightValidFlag`
  ([`qquickpopuppositioner.cpp:214-252`][qtquick-restore-size]).
  [Uno](./uno.md) takes the third road for tooltips: clip the content rather than push
  the surface off-screen ([`ToolTip.cs:715-733`][uno-clip]).
- **Failure it prevents** — a popup shrunk once to fit a small window stays permanently
  shrunk after the window grows; and the engine's own corrective resize, mistaken for an
  author-set explicit size, freezes future implicit resizing. Without the veto, a
  compositor may hand back a size below the content's minimum and the popup renders with
  its rows overlapping.
- **Cost on one surface** — **Free**, and it is a decision `sparkles` has already made
  once in the opposite direction: `render_widgets.d:413-435` argues shift-over-shrink
  explicitly ("a popup narrowed to fit under a token near the right edge would wrap its
  signature into a column two words wide, which reads worse than the same popup slid
  left"). The lesson to carry is that whichever is chosen must be **reversible**, and that
  the resolved size belongs in the result value rather than being written back over the
  request.

### 15. Placement needs hysteresis, and hysteresis needs the previous frame as an input

- **Where it is done right** — [Dear ImGui](./imgui.md) starts the candidate loop at
  index `-1` so the direction chosen on the previous frame is retried before the ordered
  list is consulted, then skips that direction when it recurs
  ([`imgui.cpp:12904-12929`][imgui-lastdir]). [GPUI](./gpui.md) chooses the side from
  **maximum** sizes rather than measured ones, deliberately, "for stability"
  ([`element.rs:4179`][gpui-maxsize]). [Blink](./blink.md) evaluates `@position-try`
  candidates against the **base** computed style with animations and transitions excluded
  ([`out_of_flow_layout_part.cc:2143-2148`][blink-basestyle]), and evaluates them using
  the scroll offsets _remembered_ from when the current placement was chosen, excluding on
  a forced re-search every option that also failed at those offsets — with a 16-line
  comment explaining why ([`out_of_flow_layout_part.cc:2119-2135`][blink-remembered]).
  [Base UI](./base-ui.md) applies a 1 px asymmetric padding to `flip()` only, never to
  `shift()` or `size()` ([`useAnchorPositioning.ts:222-231`][base-ui-flipbias]).
  [Tippy](./tippy.md) keeps a visited-set of already-tried placements for multi-rect
  inline anchors ([`inlinePositioning.ts:44-58`][tippy-tried], commit `3598727`,
  "fix(inlinePositioning): infinite loop").
- **Failure it prevents** — every one of these is a visible strobe. A popover whose
  content streams in (an LSP hover, a markdown parse) flips above → below → above as it
  grows. A size transition changes which fallback fits, which changes the size, which
  re-flips, locked to the transition duration. An input centred by the iOS software
  keyboard sits exactly on the flip decision boundary and oscillates. A wrapped inline
  anchor whose rect depends on the placement and whose placement depends on the rect loops
  forever.
- **Cost on one surface** — **Declare**, and `sparkles` is more exposed than most:
  events route against the last painted frame's hit data, so an oscillating placement
  desynchronises routing as well as looking bad. The cure is that `place()` takes the
  previous frame's decision as an explicit input and returns the resolved side, rather
  than re-deriving both.

### 16. "Fits" means a desired minimum, and chrome yields to space before the budget is cut

- **Where it is done right** — [nvim-cmp and blink.cmp](./nvim-completion.md) both define
  fit as a _desired minimum_: nvim-cmp hardcodes `min(10, wanted)` from vim's
  `PUM_DEF_HEIGHT` ([`custom_entries_view.lua:11`][nvimcmp-defheight]), blink exposes
  `desired_min_width = 50` / `desired_min_height = 10` and gives them their own comparator
  tier ([`documentation.lua:60-61`][blink-desired-min]).
  [company-mode](./emacs-posframe.md) flips only when there is no room for a _reasonable_
  popup, sized as `min(configured minimum, actual candidate count)`
  ([`company.el:4371-4377`][company-height]). [Helix](./helix.md) drops the popup's
  borders when `max_height <= 3 || max_width <= 3`, _before_ reducing the budget by two in
  each axis ([`popup.rs:175-179`][helix-chrome]), and its completion documentation
  switches from a menu-anchored side panel to a screen-edge band below ~30 free columns,
  suppressing itself entirely below two free rows
  ([`completion.rs:534-568`][helix-docs-fallback]). blink.cmp folds a visible scrollbar
  into the border budget (`right = math.max(1, right)`) so every downstream width
  computation is already correct ([`window/init.lua:231`][blink-scrollbar-border]).
- **Failure it prevents** — requiring the full content height makes an overlay flip or
  vanish for long content that would have been perfectly usable scrolled; requiring one
  cell makes it flip into a one-line sliver. In a five-row gap a bordered popup spends two
  rows on the frame and shows one line, or produces a zero-height inner rect. A borderless
  overlay that becomes scrollable silently grows one cell wider than the placer believes,
  so left-placed children overlap their parent — nvim-cmp discovers this _after_ opening
  and must re-open the window shifted.
- **Cost on one surface** — **Free**, and this is the cluster where the cell grid makes
  the problem _sharper_, not softer: two cells of border out of a five-row budget is 40%
  of the surface. `sparkles`' `popupMinWidth = 24` (`style.d:233`) is the same idea already
  present as theme data; what is missing is the ladder that spends chrome last.

### 17. Sibling overlays are de-conflicted against predicted rects, not painted ones

- **Where it is done right** — [Helix](./helix.md) computes the _predicted_ rects of
  completion and signature-help without painting them, checks collision in both
  directions with an explicit priority (completion wins), and — because deletion loses
  information — re-fires `trigger_signature_help` after a completion is accepted
  specifically to resurrect the surface it destroyed
  ([`signature_help.rs:274-286`][helix-collide]).
  [blink.cmp](./nvim-completion.md) treats a _foreign_ overlay the same way: it hides
  itself when vim's built-in popup menu appears, and its signature window reads
  `pum_getpos()` to place itself on the opposite side of the cursor
  ([`signature/window.lua:145-150`][blink-pumpos]).
- **Failure it prevents** — two overlays painting into one buffer produce garbage and
  whichever paints later silently wins; and a signature panel drawn underneath a popup
  menu the plugin does not own is simply invisible.
- **Cost on one surface** — **Declare**. This is the failure mode a single-surface
  toolkit owns by construction and the DOM subjects never face. Because
  `sparkles` derives its overlay list per frame, "the set of rects other overlays will
  occupy" is knowable before paint — but only if placement runs for the whole overlay
  list in one pass, in a defined order, rather than per-widget.

---

## Timing: warm-up, cool-down, and the shape of a delay

### 18. The warm-up is charged from the trigger instant, not from the moment content arrives

- **Where it is done right** — [blink.cmp](./nvim-completion.md) computes
  `math.max(0, auto_show_delay_ms - (vim.uv.now() - context.timestamp))`
  ([`menu/init.lua:167`][blink-delay-charge]). [Neovim](./neovim-floats.md) measures its
  autocomplete warm-up "from when it was armed (the keystroke), so a `CursorHold`
  returning in between does not push the popup back", and multiplexes it with the
  unrelated `updatetime` timer onto a single blocking-poll deadline via `min()`
  ([`os/input.c:130-140`][nvim-armed-delay]).
- **Failure it prevents** — with a 500 ms delay and a 400 ms language-server round trip
  the user waits 900 ms and perceives the editor as sluggish. Because a fast provider
  hides it entirely, the bug appears only on slow machines and large projects — the worst
  possible discovery profile. The timer-multiplexing half prevents two independent timers
  on one poll deadline starving each other, so the popup never appears at a stable
  latency.
- **Cost on one surface** — **Declare**. `sparkles` already owns the deadline mechanism:
  `HostState.wakeIn(Duration)` is an ask, re-armed per frame, keeping the soonest — the
  same `min()` multiplex Neovim does by hand. What it does not own is a clock on the TUI:
  `TuiHost.frameSeconds()` returns a hard-coded literal `0`, so anything advanced by
  `step(state, dtMs)` — including `Timeline` ([`STM6`][spec-state]) — never advances there
  at all.

### 19. A repeated identical trigger must not restart the pending timer

- **Where it is done right** — [blink.cmp](./nvim-completion.md) keys the pending show on
  a composite `{contextId, row, col}` and returns early when the timer is already active
  under the same key ([`menu/init.lua:180-181`][blink-timerkey]).
- **Failure it prevents** — several sources answer at different times for one keystroke.
  If each re-emission restarts the timer, the overlay is permanently "about to show" and
  never appears while providers keep answering.
- **Cost on one surface** — **Free**. It is one comparison against a stored key, and the
  key is exactly the anchor identity the primitive needs anyway.

### 20. A duration of zero must statically disable the feature, never arm a zero-length timer

- **Where it is done right** — [Radix](./radix.md) shipped this bug and fixed it with
  early returns in **both** provider callbacks when `skipDelayDuration <= 0`, pinned by a
  regression test ([`tooltip.tsx:90`][radix-skipdelay]; issue #3873;
  [`tooltip.test.tsx:380-418`][radix-skipdelay-test]). [Blink](./blink.md) generalises the
  idea in the other direction: an infinite or `NaN` interest delay means "never schedule
  that transition", guarded with `std::isfinite` before posting
  ([`element.cc:12828`][blink-isfinite], [`:12861`][blink-isfinite-hide]).
- **Failure it prevents** — a zero-length skip timer still flips the "warm" flag for one
  tick, so the next trigger opens instantly for a consumer who explicitly asked for no
  skip window. Blink's version replaces a separate boolean: one float encodes
  default / N seconds / never, which is how a WCAG-persistent tooltip is expressed without
  a second state.
- **Cost on one surface** — **Free**, and it is a rule about the _type_, not the timer:
  the predicate must be static. This matters more on a recording canvas than in a browser,
  because a recording assertion cannot observe a timer that did not fire — so
  "record a deadline, fire always, and let the handler decide" is untestable in exactly
  the case that matters.

### 21. The cool-down is armed only if a surface actually appeared

- **Where it is done right** — [React Aria](./react-aria.md) arms the global tooltip
  cooldown only `if (globalWarmedUp)` and unconditionally cancels a pending warm-up on any
  hide ([`useTooltipTriggerState.ts:145-161`][react-aria-warmup]), with a test named
  "will not show a tooltip if the trigger is left during warmup, nor will warmup
  complete". [Dear ImGui](./imgui.md) shares the delay timer across items and runs a
  `max(0.25 s, dt*2)` clear grace before resetting it
  ([`imgui.cpp:5733-5739`][imgui-shareddelay]). [Base UI](./base-ui.md)'s delay group
  bails out of its reset timer if the popup re-opened **or** another id seized the group,
  and its effect cleanup clears the timer under the same two conditions
  ([`FloatingDelayGroup.tsx:184-201`][base-ui-delaygroup]).
- **Failure it prevents** — brushing past three toolbar buttons without pausing leaves
  the system "warm", so the fourth button — the one the user actually aimed at — flashes
  its tooltip instantly with no intent shown. Without the clear grace, crossing a
  one-pixel separator or a disabled gap between two buttons resets the warm-up and the
  tooltip never appears at all. Without both delay-group guards, sweeping across a toolbar
  interleaves close-of-A, open-of-B, close-of-B and restores the full delay mid-traversal.
- **Cost on one surface** — **Free** for the arbiter, **Declare** for the grace. The
  cool-down is one timestamp on a shared arbiter plus zero per-widget state; ImGui's
  `max(0.25 s, dt*2)` floor exists precisely so the grace does not vanish at low frame
  rates, which a terminal at a few frames per second needs more than a 60 Hz GPU does. On
  a cell grid the "one-pixel separator" case becomes "one cell of padding", which is a
  much more common gap, so the grace is _more_ load-bearing here, not less
  (_inference_).

### 22. Display duration scales with content, and a cumulative budget needs a floor

- **Where it is done right** — [Qt Widgets](./qt-widgets.md) scales the tooltip expire
  time with content length: 10 s plus 40 ms per character beyond 100
  ([`qtooltip.cpp:167-176`][qt-expire]). [TipKit](./apple.md) counts a tip's
  `MaxDisplayDuration` cumulatively _across launches_ but guarantees a
  [60-second anti-flicker floor][apple-maxduration] before a tip can be automatically
  invalidated, and splits the cooldown question in two:
  [`displayFrequency`][apple-displayfrequency] gates only **first** appearances, because
  "previously displayed tips will still appear if their display rules are satisfied".
- **Failure it prevents** — a fixed timeout makes a long tooltip disappear before the
  user finishes reading it. A naive cumulative budget expires mid-appearance and yanks the
  surface away a second after it appeared. A blanket cooldown suppresses re-showing a tip
  the user has already seen and still needs; a per-tip-only cooldown lets five different
  first-time tips fire in one session.
- **Cost on one surface** — **Degrades**. `Timeline`'s `holdMs` and
  `holdUntilDismissed` already express the persistent case, and a content-scaled hold is
  arithmetic over the measured cell count. What does not survive is any of it on the
  static-HTML target, where there are no timers at all.

### 23. Delay is forced to zero when the surface is already on screen or already warm

- **Where it is done right** — [Tippy](./tippy.md) forces the delay to `0` while the
  surface is mounted but no longer visible — mid exit animation
  ([`createTippy.ts:202-204`][tippy-getdelay]). [Flutter](./flutter.md) opens the second
  tooltip with `Duration.zero` when moving from one trigger to another, deriving it from
  the _global opened list_ rather than a shared timer or provider
  ([`raw_tooltip.dart:749-758`][flutter-zero-delay]). [Zag](./zag.md) goes further: a
  tooltip that replaces another skips the delay **and both animations**, marking the
  incoming _and_ outgoing surfaces instant
  ([`tooltip.machine.ts:283`][zag-instant]). [WinUI](./winui.md) uses per-mode multiplier
  pairs rather than a boolean — Touch `{1, 0}`, Mouse `{2, 1.5}`, Keyboard `{2, 2}`
  ([`ToolTipService_Partial.cpp:1769-1780`][winui-reshow]).
- **Failure it prevents** — a 700 ms wait on every hop across a toolbar is the classic
  "tooltips feel broken when scanning a row of icons". Re-entering a trigger during the
  fade-out restarts the full show delay, so a quick out-and-back feels broken while the
  surface is visibly still there. Treating reshow as one boolean makes mouse tooltips
  twitchy or touch re-taps unresponsive, depending on which way you round.
- **Cost on one surface** — **Free**, and it argues for modelling openness as membership
  in one ordered overlay list: Flutter derives the zero delay from the list, not from a
  provider, and that is the cheapest formulation on a toolkit that rebuilds the list every
  frame.

---

## Pointer intent

### 24. The travel region is a hull of anchor and overlay, plus a trough across the gap

- **Where it is done right** — [WPF](./wpf.md) builds a convex hull over the owner
  rect(s) and the tooltip rect, and its containment test chooses `<` for right/down edges
  and `>=` for left/up so the hull is half-open — matching the exclusive semantics of the
  source rectangles' bottom and right edges, with no special-casing and no floating point
  ([`PopupControlService.cs:1644-1668`][wpf-hull]). [Base UI](./base-ui.md) and
  [Floating UI](./floating-ui.md) both add a _trough_: an axis-aligned band spanning the
  gap between anchor and popup, inside which the surface never closes, sized by whichever
  of the two is wider ([`safePolygon.ts:207-260`][base-ui-trough],
  [`safePolygon.ts:176-216`][fui-trough]).
- **Failure it prevents** — the travel triangle's apex is the _cursor_ position, which
  can be outside the anchor's edge; moving back and forth between anchor and popup
  therefore repeatedly exits the triangle and closes the surface even though the pointer
  never left the corridor. WPF's half-open rule prevents off-by-one flicker exactly on
  the hull boundary, where a pointer sitting on the shared edge of two rects is
  alternately in and out on successive moves.
- **Cost on one surface** — **Declare**. Note the shape of the geometry carefully: at the
  corridor sizes the corpus's defaults produce — zero cells (Floating UI `offset` 0, Radix
  `sideOffset` 0, Zag submenu `gutter: 0`, hue's `hy + cellH`) or one cell (Textual's
  `margin: 1 0`) — the portion of the polygon _inside the corridor_ selects the same whole
  cells as the corridor rectangle, so the corridor contributes no discrimination. The
  polygon still discriminates **outside** the corridor: on the anchor's own row it selects
  only the anchor's columns where the bounding rect would select the overlay's full width.
  A cell-grid port therefore keeps the hull and can drop the corridor fan.

### 25. A direction gate sits in front of the polygon, and the grace expires

- **Where it is done right** — [Radix](./radix.md) puts a one-bit horizontal direction
  latch (`isMovingTowards`) in front of the grace trapezoid
  ([`menu.tsx:481`][radix-direction]), applies a ±5 px bleed to the exit point "to ensure
  that our exit point is consistently within polygon bounds"
  ([`menu.tsx:1146-1148`][radix-bleed]), and expires the grace intent after 300 ms
  independently of pointer position ([`menu.tsx:1157-1161`][radix-grace-timer]).
  [Ariakit](./ariakit.md) refreshes the enter point on every successful in-corridor move,
  so the corridor narrows monotonically ([`hovercard.tsx:98-100`][ariakit-refresh]), and
  handles the ray-through-a-shared-vertex case by consulting the vertex _before_ the
  previous vertex ([`polygon.ts:16`][ariakit-polygon]).
  [Dear ImGui](./imgui.md) caps the menu-aim triangle's height at ±8 line-heights,
  naming the failure: "limit the slope and the bias toward large sub-menus"
  ([`imgui_widgets.cpp:9521`][imgui-menuaim-cap]). [Blink](./blink.md)'s
  `MenuSafeTriangle` refuses to exist when the submenu is fragmented into more than one
  quad, and uses the _last known_ mouse position rather than the triggering event's
  ([`menu_safe_triangle.cc:95-100`][blink-safetriangle]).
- **Failure it prevents** — the polygon alone is necessary and not sufficient: a pointer
  geometrically inside the trapezoid but travelling _away_ keeps the submenu open forever.
  A pointer parked inside it — user stopped moving, or the pointer left the window with no
  leave event — permanently suppresses item focus and submenu switching. Without ImGui's
  cap, a very tall submenu produces a cone so wide that the whole parent menu falls inside
  it and the heuristic silently disables itself.
- **Cost on one surface** — **Declare**, with one correction to the obvious intuition:
  cell quantisation does **not** make a direction latch more reliable. What it does is
  collapse Floating UI's velocity gate to a two-valued "did the pointer's cell change this
  frame", because `PointerEvent.pos` is cells on every `sparkles` target and the TUI has
  no sub-cell wire at all. A genuine velocity gate is not impossible, but it would have to
  live at the device-space `GestureRecognizer` seam upstream of quantisation, not in a
  widget's state machine. The ±5 px bleed becomes a mandatory ±1 cell.

### 26. There are zero-geometry ways to get the same result, and they are cheaper

- **Where it is done right** — [Compose](./compose.md) keeps cascading submenus open
  across the trigger→content gap by **sharing one `MutableInteractionSource`** between the
  parent item and the submenu container, so the hovered predicate is simply an OR over
  both surfaces — zero geometry, zero timers, zero tolerance regions
  ([`Menu.kt:294`][compose-shared-interaction]).
  [APG](./aria-apg.md) achieves WCAG "Hoverable" by DOM _containment_: the popup is a
  descendant of the trigger even though it paints outside the trigger's box, so leaving is
  defined over the ownership tree rather than over pixels
  ([`toolbar.html:59`][apg-containment]) — and it excludes the caret from hit testing with
  `pointer-events: none` so a pointer resting on the visual bridge belongs to neither
  surface's containment test ([`toolbar.css:67-77`][apg-arrow-events]).
  [Turbo Vision](./turbo-vision.md) does it with three exact rectangle predicates and
  **zero cells of tolerance**, because opening a submenu there requires a press or a key
  ([`tmnuview.cpp:148-167`][tv-mouseinmenus]). [GPUI](./gpui.md) paints occluder
  rectangles into the gaps of a stacked popover group, blocking both hit-test and
  mouse-move ([`element.rs:4402-4417`][gpui-occluder]).
- **Failure it prevents** — all four prevent the same thing: the pointer crossing the
  gap between trigger and content hits whatever is beneath, which reports "not hovering
  the trigger" and collapses the stack mid-traversal.
- **Cost on one surface** — **Free**, and this is the entry that most changes what
  `sparkles` should build. Ownership-based containment and occluder cells are both
  expressible in the derived hit list; a safe polygon is not, without a geometry
  vocabulary the toolkit does not have. hue's GUI already ships the correct answer for the
  anchor→overlay half — zero-cell-gap placement plus a zero-tolerance containment test
  against the last-painted rect (`gui.d:2536-2537`, `gui.d:2467-2471`) — and its defects
  are that it is per-application, GUI-only (the TUI paths place at +1/+2 rows with no
  keep-open rule), outside the shared hit list, and expressed in pixels outside
  `sparkles:input`'s cell vocabulary.

### 27. Motion is not the only thing that changes what is under the pointer

- **Where it is done right** — [Avalonia](./avalonia.md) re-evaluates hover on renderer
  **scene invalidation**, not only on pointer movement, gated on the dirty rect containing
  the last pointer position ([`TopLevel.cs:794`][avalonia-sceneinvalidated]).
  [GTK4](./gtk4.md) synthesises a motion request after a relayout that changed a popover's
  contents but not the pointer position ([`gtkpopover.c:721-747`][gtk-motion-request]).
  [Angular CDK](./angular-cdk.md)'s `MatTooltip` listens for `wheel` on the trigger and
  closes if `elementFromPoint` is no longer the trigger
  ([`tooltip.ts:831-843`][cdk-wheel]). [Tippy](./tippy.md) re-runs every _other_ instance's
  pending hide test on any instance's `mouseenter`, via a module-global list of registered
  testers, because during scrolling the content moves under a stationary cursor and
  `mouseenter` fires where `mousemove` never will
  ([`createTippy.ts:481-487`][tippy-mousemovelisteners]).
  [Headless UI](./headlessui.md) gates hover-activation of list items on the pointer's
  screen coordinates having actually **changed**
  ([`use-tracked-pointer.ts:13`][headless-wasmoved]), [Radix](./radix.md) focuses menu
  items on `pointermove` rather than `mouseenter` ([`menu.tsx:771-795`][radix-pointermove]),
  [Ariakit](./ariakit.md)'s global mouse-moving flag is reset by scroll, keydown, mousedown
  and mouseup and requires non-zero `movementX`/`movementY`
  ([`hooks.ts:399-441`][ariakit-mousemoving]), and [Zag](./zag.md) closes the tooltip on
  `pointerlockchange` ([`tooltip.machine.ts:386-390`][zag-pointerlock]).
- **Failure it prevents** — a tooltip describing content that scrolled, virtualised or
  re-templated away under a stationary pointer stays open showing a stale description; and
  the symmetric one, a tooltip that should now appear under an unmoved pointer never does.
  Arrow-keying through a long list scrolls a new item under a stationary cursor, so the
  mouse steals the active item mid-keystroke; a mere wiggle over the item already under
  the cursor does not re-focus it, because no enter event fires.
- **Cost on one surface** — **Free**, and it is the single most likely hover bug in a
  repaint-driven toolkit — which is exactly what `sparkles` is. Because the frame is
  rebuilt every tick and `HoverState` is re-derived against the new hit list, `sparkles`
  gets Avalonia's scene-invalidation behaviour for nothing. What it must _add_ is the
  discipline that hover identity is compared against the **new** frame's list, not carried
  forward.

### 28. Hover intent is switched off for touch at the source, not degraded

- **Where it is done right** — Of the subjects examined, none computes hover intent for
  touch input. Most switch the machinery off at the source:
  [React Aria](./react-aria.md)'s safe area early-returns on touch
  ([`useSafeArea.ts:62`][react-aria-touch]), [Floating UI](./floating-ui.md)'s
  `getDelay` returns `0` for any non-mouse-like pointer type before consulting the
  configured delay at all ([`useHover.ts:46-48`][fui-touchdelay]), [Uno](./uno.md) gates
  its cascading-menu hover path to mouse only, and
  [Base UI](./base-ui.md) special-cases the touch close.
  [Blink](./blink.md) is inert on touch only as a side effect of requiring a known mouse
  position; [Compose](./compose.md) dispatches on pointer type with a touch fallback in
  the same expression rather than disabling. [GTK4](./gtk4.md) additionally suppresses
  tooltips while **any** mouse button is held, and for touchscreen sources outright
  ([`gtktooltip.c:876-895`][gtk-tooltips-enabled]).
- **Failure it prevents** — a 600 ms hover delay applied to a tap makes the surface feel
  broken, and a close delay leaves a stale surface after the finger lifts. GTK's
  button-held rule prevents tooltips popping up mid-drag, and its touch rule prevents a
  tooltip appearing _under the finger_, where it can never be dismissed.
- **Cost on one surface** — **Absent** on Android, and that has to be declared rather
  than inferred: `sparkles` cannot express pointer-type distinction on the events a
  trigger reads. `PointerEvent` carries `{action, button, pos, mods, pointerId}` with no
  device kind, and `pointerId` is hard-coded `0` by the raylib adapter's gesture arm, so
  it is no proxy for a finger. Touch is visible only as the target-level
  `InputCapabilities.hover == false` — with the partial exception of `GestureEvent`
  (`longPress`, `pinch`), which is touch-derived by construction. Declaring hover intent
  absent on Android is therefore the _only_ option, not a simplification.

### 29. Bare pointer motion is not reported by default on a terminal

- **Where it is done right** — This one is a `sparkles` finding rather than an external
  capability, and it bounds everything above. `RunConfig.motion` (`libs/ui-app/src/sparkles/ui_app/host.d:81`)
  is opt-in; only two applications (`apps/ui-gallery`, `apps/hue`) plus one example
  (`libs/tui/examples/demo.d:85`, `TerminalOptions(motion: true)`) turn it on. A TUI host
  that has not opted in receives no bare-motion events at all.
- **Failure it prevents** — a hover-intent implementation that assumes motion events
  exist silently degrades into "the overlay opens on the first cell change and never
  updates", which reads to the user as an overlay that ignores the pointer.
- **Cost on one surface** — **Declare**. Hover intent must be a declared capability
  resolved against `InputCapabilities`, not an assumed one — and the pattern is already
  shipped in the toolkit: `ScrollbarState.expanded(in InputCapabilities)` resolves an
  interaction affordance from declared capability with no new mechanism.

---

## Dismissal

### 30. Outside dismissal is a two-phase identity test, not a click handler

- **Where it is done right** — The single most widely reimplemented rule in the survey.
  [Angular CDK](./angular-cdk.md) requires _both_ the pointerdown origin and the click
  target to be outside, with four dedicated specs
  ([`overlay-outside-click-dispatcher.ts:91-97`][cdk-outside]).
  [Blink](./blink.md) compares the nearest related popover at pointerdown against the one
  at pointerup and dismisses only when they match
  ([`html_element.cc:3096-3119`][blink-lightdismiss]).
  [Headless UI](./headlessui.md) pairs the pointerdown _target_ with the pointerup _event_
  instead of listening to `click` ([`use-outside-click.ts:106-137`][headless-outside]).
  [Qt Quick Controls](./qt-quick-controls.md) latches `outsidePressed` at press and
  additionally requires `!contains(pressPoint)` at release
  ([`qquickpopup.cpp:591-626`][qtquick-press-release], with a test named "press inside and
  release outside"). [Floating Vue](./floating-vue.md) ORs the two hit tests
  ([`Popper.ts:1070-1093`][fvue-pointerdown], a real 5.1.0 regression reverted in
  `b5dc40c`), and [Ariakit](./ariakit.md) stores both the composed-path and
  root-projected views of the previous mousedown
  ([`use-previous-mouse-down-ref.ts:62`][ariakit-prevdown], issues 1336 and 2330).
- **Failure it prevents** — selecting text inside a panel and releasing the mouse on the
  page closes the panel and destroys the selection. The inverse — press on the page,
  release inside — is equally wrong: a mis-aimed drag into the panel dismisses it.
- **Cost on one surface** — **Free**, with one correction. `PressState`
  (`libs/ui/src/sparkles/ui/state.d:1403`, `released` at `:1413`) already implements the
  two-phase identity test, and reusing it needs the "root surface / outside everything"
  case to carry a **non-zero** group id. But it needs its _own_ `PressState` instance keyed
  by surface id: `activated` is transient and there is a single `armed` slot, so sharing
  the button-activation instance would let an in-overlay button press disarm the overlay's
  outside test.

### 31. The gesture that opened the surface must be excluded from dismissing it

- **Where it is done right** — [Blink](./blink.md) pre-seeds the document's pointerdown
  target with the popover itself when a popover is opened _during_ pointerdown
  ([`element.cc:2108-2117`][blink-preseed]).
  [GTK4](./gtk4.md) fires light dismiss on press only, with the paired release explicitly
  excluded behind a `#if 0` and an in-tree explanation: because of implicit pointer grabs
  the release is delivered to the same place as the press
  ([`gdksurface.c:2745-2754`][gtk-press-only]).
  [Slint](./slint.md) sets a one-bit window-level latch, `had_popup_on_press`, recording
  whether _any_ popup was open when the gesture began, and requires it for a
  close-on-click ([`window.rs:788-816`][slint-hadpopup]).
  [Turbo Vision](./turbo-vision.md) uses a `firstEvent` guard plus a `lastTargetItem`
  re-entry memo — one item pointer and an identity comparison, no clock — to suppress
  re-opening the exact item whose submenu was just closed by clicking its own name
  ([`tmnuview.cpp:233-246`][tv-lasttarget]).
  [Floating Vue](./floating-vue.md) exempts anything opened during the current frame from
  the deferred outside-close pass ([`Popper.ts:448-451`][fvue-showlock]), and
  [Tippy](./tippy.md) uses a one-macrotask veto so the focus event generated by a
  dismissing press cannot re-show the surface
  ([`createTippy.ts:338-344`][tippy-didhide]).
- **Failure it prevents** — the popover closes on the very release that opened it, which
  makes long-press tooltips impossible on touch; or clicking an open menu's title closes
  and instantly re-opens it, so it never appears to close at all.
- **Cost on one surface** — **Free**, and Turbo Vision's answer is the one to copy: an
  identity memo rather than a cool-down window, because it works with no clock — which the
  TUI, whose `frameSeconds()` is `0`, needs.

### 32. A press on the overlay's own chrome counts as inside

- **Where it is done right** — [Floating UI](./floating-ui.md) ignores outside presses
  that landed on a scrollbar, RTL-aware ([`useDismiss.ts:282-320`][fui-scrollbar]).
  [Zag](./zag.md) extends the test to the _nearest overflow ancestor_ of the content — or
  of the `aria-controls` trigger — with a 16 px slop
  ([`interact-outside/index.ts:90`][zag-scrollbar]), and separately treats an outside
  pointerdown whose client point lies inside the content's bounding rect as inside even
  when the event target is not a descendant ([`index.ts:72`][zag-pointwithin]).
  [Ariakit](./ariakit.md) vetoes an outside click when the pointer coordinates fall inside
  the dialog's non-degenerate bounding rect, independent of hit testing
  ([`use-hide-on-interact-outside.ts:58-68`][ariakit-pointveto]).
  [APG](./aria-apg.md) tests outside-dismissal with `relatedTarget` containment so the
  popup's own scrollbar counts as inside — a real shipped bug, issue #2719, fixed in commit
  `164188c4` ([`select-only.js:249-253`][apg-relatedtarget]).
- **Failure it prevents** — dragging the popup's own scrollbar dismisses it mid-drag; and
  clicking a transparent gap that is visually part of the popup — padding, the space
  between rows, a child with pointer events disabled — dismisses it even though the user
  aimed at the popup. Zag's version also covers password managers and other injected
  overlays rendered on top of a popover.
- **Cost on one surface** — **Free** and, notably, _cheaper here_: on one surface with a
  derived hit list, "inside" can be answered against the overlay's painted rect directly,
  which is what Ariakit and Zag re-derive at cost. The rule to carry is that the test is
  against the overlay **tree including its chrome**, not against the raw event target.

### 33. Cascading dismissal walks the ownership chain and stops at the event surface

- **Where it is done right** — [GTK4](./gtk4.md) hides surfaces up the parent chain and
  stops at the surface the event landed on, so clicking a parent menu closes only the
  submenus above it ([`gdksurface.c:2773-2781`][gtk-cascade]).
  [APG](./aria-apg.md) closes every open popup whose subtree does **not** contain the
  incoming target (`doesNotContain`), with the complementary rule that arriving at an item
  re-opens its parent chain, guaranteeing an unbroken root-to-active path
  ([`menubar-editor.js:457`][apg-doesnotcontain]).
  [Dear ImGui](./imgui.md)'s `CloseCurrentPopup` climbs the child-menu chain but stops
  when the parent popup owns a menu bar ([`imgui.cpp:12641-12651`][imgui-closecurrent]).
  [Avalonia](./avalonia.md)'s `IsChildOrThis` decides "inside" by climbing the **overlay
  ownership** chain rather than the visual tree, and `FocusManager.GetFocusScope` performs
  the same hop so dismissal and focus scoping stay consistent
  ([`Popup.cs:940-962`][avalonia-ischildorthis]).
  The [Popover API](./popover-api.md) adds the cross-kind case: a document-level
  `hint stack parent` pointer records which auto popover the bottom of the hint stack
  hangs off, so hiding that auto tears down all hints while light-dismissing _into_ a hint
  closes autos only above that parent
  ([`source:91901`][whatwg-hintparent]).
- **Failure it prevents** — a flat "close everything on outside click" closes the whole
  menu stack when the user clicks back on a parent item, making it impossible to back out
  one level; the opposite error leaves orphaned parents on screen after choosing an item
  three submenus deep. The hint-stack rule prevents a tooltip stack floating over a menu
  that has already closed, and its mirror, a tooltip click closing the menu that spawned
  it.
- **Cost on one surface** — **Free**. A flat overlay list plus one parent index is
  sufficient for the ancestry predicate; a stored tree is not needed. Cascading dismissal
  is then a truncation of the list at an index computed by that predicate — and the list
  must be re-checked afterwards, because a dismissal handler may open a new overlay.

### 34. A non-dismissing overlay must be skipped by the cascade, not absorb it

- **Where it is done right** — [Qt Quick Controls](./qt-quick-controls.md) has a
  dedicated predicate, `canCascadeCloseOnOutsidePress`, whose comment names exactly the
  tooltip-over-modal case: a popup that cannot auto-close at all is skipped entirely — it
  neither closes nor stops the walk ([`qquickoverlay.cpp:184-197`][qtquick-cascade]). It
  also distinguishes `isOpened()` (false at the _start_ of the exit transition) from
  `isVisible()` (true until it ends), so a modal that closes itself on an outside press
  stops counting as a blocker for that same event
  ([`qquickoverlay.cpp:199-212`][qtquick-closeditself]), and an overlay-wide
  `closeCascadeStopped` latch guarantees each physical press gets at most one cascade
  ([`qquickoverlay.cpp:618-637`][qtquick-latch]).
  [Angular CDK](./angular-cdk.md) reaches the same place with a per-overlay
  `eventPredicate`, and routes keyboard events by stack **recency**, skipping overlays with
  no keydown subscribers ([`overlay-keyboard-dispatcher.ts:47-63`][cdk-keyboard]).
  [Radix](./radix.md) inverts it: layers below the highest modal layer treat **nothing** as
  outside ([`dismissable-layer.tsx:102`][radix-below-modal], regression #3971).
- **Failure it prevents** — a tooltip open over a dialog is the most recent overlay, so it
  consumes Escape and the dialog never closes; or a single click closes two, three or all
  stacked popups when the author asked for only the top one.
- **Cost on one surface** — **Declare**. This is the entry that fills
  [`DCK13`][spec-containers]'s empty top-layers rung with actual semantics: the rung is not
  needed for positional hit routing — that is already correct once overlay targets are
  appended last — it is needed for the _non-positional_ decisions, of which "who owns
  Escape" is the sharpest.

### 35. Dismissal and consumption are independent decisions

- **Where it is done right** — [Turbo Vision](./turbo-vision.md) re-delivers the
  dismissing press to the view underneath by default and turns that off with a single
  per-overlay bit: menus pass through, `TMenuPopup` sets `putClickEventOnExit = False`
  ([`tmnuview.cpp:218-222`][tv-putclick]).
  [Dear ImGui](./imgui.md) publishes both interpretations to the host —
  `io.MouseDownOwnedUnlessPopupClose` and `WantCaptureMouseUnlessPopupClose` — so the host
  can distinguish "the UI genuinely wanted this click" from "the UI only captured it
  because a popup was open" ([`imgui.cpp:5519-5556`][imgui-ownership]).
  [Qt Widgets](./qt-widgets.md) replays the press after dismissal, with a per-menu
  exclusion rect (`setNoReplayFor`) and a platform style-hint gate
  ([`qapplication.cpp:3356-3363`][qt-replay]).
  [Compose](./compose.md) splits on focusability — the dismissing tap is delivered when the
  popup is non-focusable and swallowed when it is focusable, both pinned in one test
  ([`PopupDismissTest.kt:129-139`][compose-dismisstest]) — while
  [tmux](./tmux-popup.md) drops it outright.
- **Failure it prevents** — with consumption always on, closing a menu costs the user an
  extra click and the thing they aimed at never receives it. With it always off, a context
  menu's dismissing click fires an unintended action in the document behind.
- **Cost on one surface** — **Free**. The corpus genuinely splits on the default, so
  neither can be assumed. _Inference (well supported, not sourced):_ because `sparkles`
  routes its own events with no OS grab, this should be an explicit per-overlay value
  rather than a hard-coded rule — and it is one of the few places where the absence of a
  grab ([`UI-O3`][spec-open-issues]) is an advantage, since ImGui demonstrates the same
  need with no grab either.

### 36. Dismissal causes exist that the surface itself cannot see

- **Where it is done right** — [Avalonia](./avalonia.md) subscribes to raw
  `NonClientLeftButtonDown` so clicking the parent window's title bar, resize border or
  system menu dismisses the popup ([`Popup.cs:856-864`][avalonia-nonclient]).
  [Headless UI](./headlessui.md) counts a capture-phase window `blur` as an outside click
  **only** when `document.activeElement` is an `iframe`
  ([`use-outside-click.ts:179-197`][headless-iframe]).
  [GPUI](./gpui.md) suppresses outside-press dismissal while a native system prompt is
  active, with a regression test ([`div.rs:266`][gpui-prompt]).
  [WinUI](./winui.md) suppresses the light-dismiss hit region entirely while a
  drag-and-drop operation is in progress ([`Popup.cpp:4746-4753`][winui-dnd]).
  [Qt Widgets](./qt-widgets.md) silently drops wheel events targeted at any window other
  than the open popup ([`qapplication.cpp:2818-2821`][qt-wheel]).
  [Radix](./radix.md) closes menus and every open submenu on window `blur` — and notes
  this is a **menu-only** rule; tooltips and popovers do not do it
  ([`menu.tsx:126-133`][radix-blur]).
- **Failure it prevents** — the popup stays open while the user drags the window around;
  clicking into an embedded iframe leaves the menu open over content the user is now
  interacting with; a click intended for a system prompt collapses every menu behind it;
  and dragging content over an open light-dismiss surface is swallowed by an invisible
  full-surface hit region.
- **Cost on one surface** — **Absent**, precisely scoped. Two causes are simply
  undetectable on the `sparkles` TUI as it stands: window/app deactivation, and the pointer
  leaving the **terminal window**. Hover-exit _between targets inside the grid_ is fully
  detectable — motion under mouse mode 1002/1003 produces move and drag events, and
  `HoverState`'s later-wins rule already retargets on them (`state.d:155-163`) — so a
  hover-exit dismissal cause must not be declared unavailable on the TUI. Only "pointer
  left the surface entirely" and "surface blurred" must.

### 37. Close is two entry points with different authority, and the reason is data

- **Where it is done right** — [AppKit](./apple.md) splits them: `close()` "forces the
  popover to close without consulting its delegate" while
  [`performClose(_:)`][apple-performclose] runs the `popoverShouldClose` veto — and the
  close **reason** is data, with [`NSPopover.CloseReason`][apple-closereason]
  distinguishing `.standard` from `.detachToWindow`.
  [Zag](./zag.md) dismisses nested layers through a **cancellable**
  `layer:request-dismiss` event, so a child can veto its own teardown
  ([`layer-stack.ts:154-176`][zag-requestdismiss]).
  [Turbo Vision](./turbo-vision.md)'s modal loop re-enters while `valid(endState)` is
  false, with `TDialog::valid` whitelisting `cmCancel` so the escape hatch can never be
  blocked by a validation failure ([`tgroup.cpp:184`][tv-valid]).
  [Qt Widgets](./qt-widgets.md) bounds `closeAllPopups` to 1024 iterations precisely
  because a popup's `close()` may be refused ([`qguiapplication.cpp:995-1004`][qt-1024]).
- **Failure it prevents** — with one close path, either the app can never veto (data loss
  on an accidental dismissal) or the framework can never force (a buggy veto strands an
  overlay on screen, surviving window close and application deactivation — or hangs the
  process in an infinite dismissal loop on screen rotation). Without a reason, "the
  popover closed" is untestable: you can assert it vanished but not that it vanished for
  the right cause, and an app discards state on a transition that was actually a promotion.
- **Cost on one surface** — **Declare**. A veto cannot live inside a pure
  `step(state, input) -> state` machine; AppKit's two-entry-point split is the
  value-semantics substitute — a forced close the toolkit performs, and a requested close
  the application may decline. The reason belongs in the returned value, which is also what
  makes dismissal assertable on the recording canvas.

---

## Focus

### 38. Restoration is guarded by "is focus still inside the closing overlay"

- **Where it is done right** — Six independent implementations carry the same guard:
  [Blink](./blink.md) ([`html_element.cc:2676-2677`][blink-restore-guard]), the
  [Popover API](./popover-api.md) itself ([`source:92464`][whatwg-restore]),
  [Angular CDK](./angular-cdk.md) ([`dialog-container.ts:318-330`][cdk-restore]),
  [WPF](./wpf.md) ([`ContextMenu.cs:624-638`][wpf-restore]),
  [Textual](./textual.md) ([`_select.py:663-665`][textual-restore]) and
  [React Aria](./react-aria.md) (`isElementInChildScope`,
  [`FocusScope.tsx:780-784`][react-aria-childscope]). The spec additionally captures
  restoration only for the **stack bottom** — `shouldRestoreFocus` is set only when the
  topmost auto-or-hint popover is null ([`source:92143`][whatwg-stackbottom]).
- **Failure it prevents** — closing an overlay rips focus away from wherever the user has
  since deliberately moved it; and closing a nested stack restores focus N times, so focus
  visibly ping-pongs back through every level of the menu on teardown.
- **Cost on one surface** — **Free**, and it is a containment test over the frame's own
  data. Note what `sparkles` does _not_ have to build: `FocusState`
  (`libs/ui/src/sparkles/ui/state.d:1316-1352`) has exactly one writer — application code
  calling `next`/`previous`/`FocusState(id)` — so an interception-style focus trap is
  unnecessary. What it also does not have is a toolkit-owned focus **order**: `FocusState`
  is a single `size_t focused` traversed over a caller-supplied `scope const size_t[] order`,
  there is no `focusTargets` producer, and `Widget` carries no focusable bit. An overlay
  cannot join keyboard traversal today without the application splicing it in by hand.

### 39. The restore target is usually gone, so restoration is a ladder

- **Where it is done right** — [Base UI](./base-ui.md) consults a capped,
  disconnection-pruned **list** of previously focused elements rather than a single saved
  reference ([`FloatingFocusManager.tsx:72-94`][base-ui-focuslist]).
  [Dear ImGui](./imgui.md) verifies the stored target is still alive and falls back to
  `FocusTopMostWindowUnderOne` when it is not, citing issue #7325 in the source
  ([`imgui.cpp:12622-12628`][imgui-focusfallback]).
  [tmux](./tmux-popup.md) saves an explicit target with a liveness check, falling back to
  the last-pane stack ([`window.c:1066-1082`][tmux-lostpane]).
  [React Aria](./react-aria.md) dispatches a _cancelable_
  `react-aria-focus-scope-restore` CustomEvent instead of focusing the saved element
  directly, because virtualised collections recycle DOM nodes so the saved element may
  still exist while representing a different row
  ([`FocusScope.tsx:825-832`][react-aria-restore-event]).
- **Failure it prevents** — a list row deleted by the overlay's own action leaves the
  saved reference pointing at a detached node, so focus falls to the document body and
  keyboard navigation dies; or, in a recycled collection, focus lands on a row that now
  holds different content.
- **Cost on one surface** — **Free**, but the ladder is the _common_ case here, not the
  exception: in an immediate-mode toolkit the tree is rebuilt every frame, so "the saved
  target is gone" happens whenever the view changes shape. React Aria's recycled-row
  problem is the same problem `sparkles` has with `hitId`, which is an author-supplied
  field (`widget.d:101`, "0 = not hit-testable") copied verbatim into the frame's hit list
  — frame-to-frame stability is a view-authoring convention the spec must state, not a
  property the toolkit guarantees. Every current consumer derives it from a domain index
  (`render_widgets.d:62`, `tree_widget.d:234`), which is the convention to write down.

### 40. Restoring focus re-triggers the thing that opened the overlay

- **Where it is done right** — [Blink](./blink.md) sets a one-shot
  `SuppressNextFocusInterest` flag on an invoker when a popover closes and restores focus
  to it ([`html_element.cc:2676-2686`][blink-suppress]).
  [Flutter](./flutter.md) suppresses reopen-on-focus for exactly one frame after a submenu
  closes ([`menu_anchor.dart:2249-2263`][flutter-reopen]).
  [Ariakit](./ariakit.md) hides _again_ after two chained animation frames, because Escape
  moves focus back to a tooltip anchor which immediately receives focus-visible
  ([`hovercard.tsx:402-413`][ariakit-doublehide]).
  [GPUI](./gpui.md) grants a time-boxed blur-ignore window during keyboard focus handoff
  between a menu and its submenu — 150 ms opening, 200 ms returning via Escape
  ([`context_menu.rs:1388-1392`][gpui-ignoreblur]).
  [React Aria](./react-aria.md) has `usePreviewTrigger` intercept the restore event to set
  `ignoreFocus` for the same reason.
- **Failure it prevents** — the infinite loop. Escape closes the surface, focus returns to
  the trigger, the trigger opens on focus, the surface reopens — so Escape appears to do
  nothing at all. GPUI's variant prevents the other half: opening a submenu with Enter
  momentarily moves focus, which fires the parent's blur handler, which dismisses the
  parent and the submenu with it.
- **Cost on one surface** — **Declare**, and it is the only place where a per-trigger
  latch beyond the open cause is genuinely needed. A related gap: `focusVisible` is not
  derivable from anything `sparkles` owns today — `FocusState` stores only a focused id and
  `InputFrame` records no last-input-source — so a focus trigger cannot currently
  distinguish keyboard focus from a click that happened to focus the trigger.

### 41. Initial focus is a priority ladder, and touch must suppress it

- **Where it is done right** — [Zag](./zag.md)'s `getInitialFocus` has an explicit
  four-step priority in which the opt-in (`[data-autofocus]`) outranks the opt-out
  (`[data-no-autofocus]`), falling back to the content root when everything is opted out
  ([`initial-focus.ts:11-30`][zag-initialfocus]).
  [Headless UI](./headlessui.md) omits `FocusTrapFeatures.InitialFocus` when
  `matchMedia('(pointer: coarse)')` matches, while keeping TabLock, FocusLock,
  RestoreFocus and AutoFocus ([`dialog.tsx:294-308`][headless-coarse]).
  [Uno](./uno.md) takes focus into a flyout using the focus state already in effect, and
  only if something was focused at all ([`FlyoutBase.cs:144-159`][uno-focusstate]);
  [WinUI](./winui.md) makes the opposite exception deliberately, letting `MenuFlyout` take
  focus even when the anchor sets `AllowFocusOnInteraction=false`, because
  `AppBarButton`'s default template sets it and honouring it would leave the menu
  unusable by keyboard ([`FlyoutBase_partial.cpp:2264-2270`][winui-menufocus]).
- **Failure it prevents** — a popover whose first tabbable is a close button steals focus
  onto "Close"; once chrome controls are opted out, nothing receives focus and the keyboard
  user is stranded outside the surface. On touch, auto-focusing the first field raises the
  on-screen keyboard immediately, covering the dialog the user has not yet read — and, on
  a placement engine, consuming the vertical budget the overlay was just fitted into.
- **Cost on one surface** — **Declare**. Suppression on touch must be _active_, not merely
  defaulted off, because the Android keyboard inset feeds back into entry 54's boundary. A
  second, cheaper rule from the corpus: a tooltip's non-interactivity is best enforced by
  the **type** of its content rather than by a focus policy — see entry 47.

---

## Layering, ordering and re-entrancy

### 42. An overlay must not contribute to its host's content extent

- **Where it is done right** — [Textual](./textual.md) excludes an `overlay: screen`
  widget from its container's total region, so it contributes nothing to auto-height,
  virtual size or scrollbar decisions
  ([`_spatial_map.py:78`][textual-overlay-extent]).
  [Flutter](./flutter.md) suppresses the `Overlay`'s `markNeedsLayout` entirely when an
  overlay child is added or removed and issues only `markNeedsPaint`, with a dedicated
  test asserting the overlay is not re-dirtied more than once
  ([`overlay.dart:1303-1342`][flutter-overlay-layout]).
- **Failure it prevents** — opening a dropdown inside an auto-height container grows the
  container by the dropdown's height, materialises a scrollbar, and shifts the trigger out
  from under the pointer: a layout feedback loop that the user sees as the page jumping
  when a menu opens. Flutter's version prevents the cost variant — showing a tooltip
  re-laying-out the entire application once per open and close.
- **Cost on one surface** — **Free**, and it is a rule about which walk sees the overlay
  rather than a new mechanism.

### 43. Paint order and hit order must come from one walk

- **Where it is done right** — [notcurses](./notcurses.md) records, per screen cell, which
  plane supplied the glyph (`crender->p`), producing a complete per-cell owner map as a
  byproduct of painting ([`render.c:392`][notcurses-owner]).
  [Textual](./textual.md) deliberately breaks the symmetry in a controlled way — hit
  testing skips `not widget.visible` while painting does not, which is what makes a
  full-screen toast container a paint-only layer
  ([`_compositor.py:842`][textual-hitvisible]).
  [Tippy](./tippy.md) disables pointer events at the **start** of the hide, not when the
  element is removed ([`createTippy.ts:217-221`][tippy-pointerevents]);
  [Floating Vue](./floating-vue.md) does the same in CSS
  ([`style.css:10-15`][fvue-pointerevents]); and [Flutter](./flutter.md) makes a closing
  menu non-interactive for pointer, focus **and** semantics with one boolean
  ([`menu_anchor.dart:697-708`][flutter-closing]).
- **Failure it prevents** — a second, separately maintained spatial index disagrees with
  what was actually painted; a dismissed surface keeps swallowing clicks for the 150 ms of
  its fade-out, so the click that dismissed it lands on a ghost; and a menu at 80% faded
  out is still clickable, tab-focusable and read by a screen reader.
- **Cost on one surface** — **Free**, and `sparkles` is _more_ exposed to getting it wrong
  than any subject surveyed, because its events already route against the last painted
  frame by construction. The rule that falls out: an overlay animating out contributes
  paint but **not** a hit entry, and "not in this frame's overlay list" should be the only
  representation of an invisible overlay — a visibility flag consulted during paint means
  the paint walk and the hit walk can disagree.

### 44. A nested deferred draw inherits no priority

- **Where it is done right** — [GPUI](./gpui.md)'s paint pass sorts **all** deferred draws
  by a flat priority ([`window.rs:3469`][gpui-paintsort]) while prepaint sorts only within
  a round ([`:3384`][gpui-prepaint]), and nested deferred draws inherit no priority
  (default `0`, [`deferred.rs:10`][gpui-deferred-default]). GPUI also treats overlay
  identity as a stable **index** into a per-frame vector, preserved across cached-subtree
  reuse — the fix for a crash that was a debug panic in the dispatch tree and, in release,
  misrouted input events ([`window.rs:3366-3374`][gpui-stable-index], regression test at
  [`deferred.rs:155`][gpui-deferred-test], commit `5e982c6bdc`).
- **Failure it prevents** — a nested child of a low-priority parent paints _behind_ an
  unrelated higher-priority sibling, and even behind its own parent — so a submenu renders
  underneath the menu that owns it.
- **Cost on one surface** — **Declare**. _Inference:_ `sparkles` should adopt
  [Flutter](./flutter.md)'s two-level order key — owner entry, then child stamp
  ([`overlay.dart:1163-1175`][flutter-orderkey]) — rather than GPUI's single integer.
  Four named bands (adorn, popup, hint, notify) with focus raising **within** a band only
  is the shape the corpus supports; a per-overlay integer priority is what produces GPUI's
  bug.

### 45. Re-entrancy: opening during a teardown, and closing from a close handler

- **Where it is done right** — The [Popover API](./popover-api.md) runs a **second cleanup
  pass** after hiding the computed slice: the list is re-read and anything not in
  `toRemain` is hidden again with events forced off, because a `beforetoggle` handler that
  shows a popover during teardown would otherwise leave it in the top layer above a closed
  ancestor — a permanently stuck overlay ([`source:92586`][whatwg-secondpass]). Show is
  forbidden during any show or hide, while hide is freely re-entrant with per-element event
  suppression ([`source:91979`][whatwg-showguard]).
  [WPF](./wpf.md) rejects reopening a popup from inside its own `Closed` handler with
  `InvalidOperationException(PopupReopeningNotAllowed)` rather than silently recursing
  ([`Popup.cs:350-351`][wpf-reopen]).
  [Angular CDK](./angular-cdk.md) snapshots the overlay array with `.slice()` before
  iterating, with a spec whose whole purpose is asserting that detaching two of three
  overlays from within the handler does not throw
  ([`overlay-outside-click-dispatcher.ts:99-102`][cdk-slice]);
  [Uno](./uno.md) captures `node.Next` before acting for the same reason
  ([`PopupRoot.cs:70-89`][uno-nodenext]).
  [Qt Quick Controls](./qt-quick-controls.md) defers a reposition requested _while_
  positioning to the next polish pass rather than recursing
  ([`qquickpopuppositioner.cpp:88-91`][qtquick-reentrant]), and
  [WinUI](./winui.md) guards the placement/size feedback loop with a "we resized it
  ourselves" flag ([`FlyoutBase_partial.cpp:1870-1879`][winui-resizeflag]).
- **Failure it prevents** — index errors and skipped overlays when a handler closes two
  related surfaces; an infinite reopen/close recursion with window-handle churn; and the
  `PerformPlacement` → `SizeChanged` → `PerformPlacement` loop, which is the same shape as
  Floating UI's `size()` middleware, whose entire termination proof is that its reset fires
  only when the re-measured dimensions actually differ from the pre-apply ones
  ([`size.ts:118-126`][fui-size-reset]).
- **Cost on one surface** — **Free**, and structurally cheaper: `sparkles` recomputes the
  overlay list per frame, so "re-check the list afterwards" is the natural shape rather
  than an added pass. The rule to carry is that only the _topmost_ overlay may be closed
  directly by an application — which [`xdg_positioner`](./xdg-positioner.md) makes a
  protocol **error** rather than a convention, so the invariant is actually checked
  ([`xdg-shell.xml:1285-1286`][xdg-topmost]).

### 46. Layer names and z-order defaults fail silently

- **Where it is done right** — This is the trap entry. In [Textual](./textual.md), an
  unrecognised `layer:` name resolves to paint index `0` via `dict.get(name, 0)`
  ([`_compositor.py:667`][textual-layerindex]) while the widget still gets its own
  independent layout flow — so a layer-name typo silently changes **layout** and appears to
  do nothing to paint order. (A phase-1 reading of `Widget.layers` as "nearest ancestor
  wins, inner declarations shadow outer" is **inverted**: the source reassigns on every
  declaring ancestor as the walk proceeds, so the outermost declaration wins.)
  Two subjects show the correct positive rules: [Neovim](./neovim-floats.md) inserts a new
  surface at the same z-index **below** the currently focused one, so a background overlay
  cannot cover the surface the user is working in, and raises a grid within its band when
  the cursor moves into it ([`ui_compositor.c:186-190`][nvim-zindex]); and
  [Floating Vue](./floating-vue.md) calls `appendChild` on **every** show, not only on
  first mount, because with a single flat z-index a re-opened popper would otherwise paint
  behind one opened later ([`Popper.ts:882`][fvue-append]).
- **Failure it prevents** — a typo that costs a day; a status HUD covering the hover popup
  the user is reading; and a re-opened dropdown rendering underneath a stale one.
- **Cost on one surface** — **Free**, and it argues for named bands as a closed
  enumeration rather than strings — the failure mode Textual documents is only possible
  because the name is open.

---

## Accessibility

### 47. A tooltip you can click into is a different widget, not a configuration

- **Where it is done right** — [APG](./aria-apg.md) states, non-normatively, that
  "tooltip widgets do not receive focus" and that "a hover that contains focusable
  elements can be made using a non-modal dialog"
  ([`tooltip-pattern.html:31-32`][apg-tooltip-focus]) — naming the substitute in the same
  breath. Three implementations enforce it structurally rather than behaviourally:
  [Dear ImGui](./imgui.md) with `ImGuiWindowFlags_NoInputs`
  ([`imgui.cpp:12316`][imgui-noinputs]), [Headless UI](./headlessui.md) by making the
  tooltip panel's tag a `Description` ([`tooltip.tsx:411`][headless-tooltip-tag]), and
  [React Aria](./react-aria.md) by shipping a separate `role='dialog'` component whose
  trigger emits `aria-haspopup: 'dialog'` ([`usePreviewTrigger.ts:245`][react-aria-preview-role]).
  React Aria also strips `aria-haspopup`, `aria-expanded` and `aria-controls` from
  **context-menu** triggers, since the attribute promises that _activating_ the element
  opens a menu — false for a right-click target
  ([`useMenuTrigger.ts:182-190`][react-aria-contextmenu-aria]).
- **Failure it prevents** — a surface that announces itself as a tooltip but holds a
  button no screen-reader user can reach, or a focus trap that survives the tooltip's own
  dismissal. Compose makes the related structural error a hard failure: its
  `SemanticsProperties.IsPopup` merge policy **throws** with "A popup should not be a
  child of a clickable/focusable node"
  ([`SemanticsProperties.kt:181-190`][compose-ispopup]), turning a subtle announcement bug
  — trigger text and overlay text concatenated into one node — into a development-time
  crash.
- **Cost on one surface** — **Free**, and it is the strongest argument in the survey for
  enforcing the distinction by the **type of the overlay's content** rather than by a focus
  policy the primitive evaluates.

### 48. A suppressed or substituted reveal must be published, not merely suppressed

- **Where it is done right** — [SwiftUI](./apple.md)'s [`.help(_:)`][apple-help]
  "configures the view's accessibility hint and its help tag (also called a tooltip) in
  macOS or visionOS" — one call binds both channels, so where the visual help tag is
  unavailable the same string survives as the accessible description.
  [React Aria](./react-aria.md)'s `usePreviewTrigger` attaches the literal string
  "Long press to open preview" only in the modality where it applies
  ([`usePreviewTrigger.ts:195-208`][react-aria-longpress-hint]). Against those,
  [Radix](./radix.md) suppresses touch outright with no substitute
  ([`tooltip.tsx:301`][radix-touch-suppress]) and has zero adaptation hits repo-wide.
  [Angular CDK](./angular-cdk.md)'s `AriaDescriber` shows the care the channel needs: it
  puts its duplicate description text in a `visibility:hidden` container rather than a
  clip-based visually-hidden one, because a clipped-but-visible duplicate of every tooltip
  message on the page is found by the browser's find-in-page
  ([`aria-describer.ts:183-192`][cdk-describer]).
- **Failure it prevents** — separate APIs guarantee drift: the tooltip is updated, the
  accessible description is not, and screen-reader users get stale or absent help. On a
  no-hover target, a suppressed reveal with no substitute is simply a silent product hole
  — the information the tooltip carried is gone with no trace in the interface.
- **Cost on one surface** — **Absent**, and this must be said plainly. `sparkles` defines
  no accessibility role vocabulary, no description or label relation, and no announcement
  channel today. It owns exactly one assistive-technology-visible name: `RunConfig.title`
  (`libs/ui-app/src/sparkles/ui_app/host.d:77`), emitted as OSC 2 by the TUI arm. The
  static-HTML emitter emits no ARIA either, though `interp/html_semantic.d` already emits
  `<details>`/`<summary>` for tier-0 disclosure. So the _requirement_ this entry generates
  is narrower than the capability: the resolution must be a **stored, readable value** on
  the overlay, so that when an accessibility channel exists it has something correct to
  project. Note also that `Slot` already claims the word "role" for style, so the
  accessibility one needs a different name.

### 49. Dismissal fires on key down, and one abstraction covers Escape, back and AT gestures

- **Where it is done right** — The [Popover API](./popover-api.md) specifies close
  requests on key **down**: "the user agent must interpret the key being pressed down as
  the close request, instead of the key being released" ([`source:88996`][whatwg-keydown]),
  and the same abstraction covers Android back and assistive-technology dismiss gestures.
  [Qt Quick Controls](./qt-quick-controls.md) folds `Qt::Key_Back` into the **same**
  `CloseOnEscape` flag as `QKeySequence::Cancel`, in both the in-window key handler and the
  popup-window event filter ([`qquickpopup.cpp:3240-3247`][qtquick-back]).
  [Blink](./blink.md) budgets `CloseWatcher` groups by user activation — at most one new
  group per interaction, no banking — upholding the invariant that the number of back
  presses needed to escape a page is at most the number of user interactions plus two
  ([`close_watcher.cc:113-151`][blink-closewatcher]).
  [Helix](./helix.md) shows the same rule from the terminal side: it lets a surface
  **decline** to own the dismissal key (`ignore_escape_key(true)`) so a modal editor closes
  the popup and leaves insert mode with one Escape rather than two
  ([`popup.rs:86-96`][helix-ignore-escape]).
- **Failure it prevents** — a dismissal that is unimplementable on inputs with no
  key-release signal; three separate code paths for Escape, back and AT dismissal that
  drift apart; a page that swallows unlimited back presses; and — Helix's case — a
  two-Escape interaction that users report as a bug.
- **Cost on one surface** — **Free**, and it is already half-declared: `sparkles`'
  `INP13` `isDismiss` unifies Escape with the Android back key in the input vocabulary
  today. Helix's decline rule is the piece that is missing, and it costs one boolean on the
  overlay.

---

## Animation and presence

### 50. Nothing may animate before the geometry is known

- **Where it is done right** — [Radix](./radix.md) measures off-page at
  `translate(0,-200%)` and forces `animation: none` until placement resolves, stated
  verbatim: "we prevent animations so that users' animations don't kick in too early from
  the wrong sides" ([`popper.tsx:347-353`][radix-measure-offpage]).
  [Zag](./zag.md) moves the positioner off-screen with `translate3d(0,-100vh,0)` and
  pointer events off until a placement has been computed
  ([`get-styles.ts:228-232`][zag-offscreen]).
  [Compose](./compose.md) renders the popup at alpha `0` until **both** the anchor
  coordinates and the content size are known
  ([`AndroidPopup.android.kt:540`][compose-alpha0]).
  [React Aria](./react-aria.md) gates the entry animation on placement having been computed
  — `useEnterAnimation(ref, !!placement)` — and cancels any CSS transition that started
  before geometry was known ([`Tooltip.tsx:198`][react-aria-enteranim]).
- **Failure it prevents** — the one-frame flash of a correctly sized overlay at the wrong
  position — usually the page corner — and the entrance animation playing from the wrong
  transform origin after the surface subsequently flips.
- **Cost on one surface** — **Free**, and structurally avoided rather than patched:
  `sparkles`' placement runs inside the same frame pass that produced the measured rect, so
  there is no unplaced frame to hide. The lesson that survives is the _ordering_
  requirement, which the spec should state so a future two-pass implementation cannot
  reintroduce it.

### 51. The transform origin is an output of placement, and the arrow can refuse to lie

- **Where it is done right** — [Headless UI](./headlessui.md) exposes `data-anchor`
  reporting the placement **after** flip, and remaps `anchor="selection"` back to the
  literal string `selection` so a consumer who styled it does not silently receive
  `bottom` ([`floating.tsx:329-342`][headless-dataanchor]).
  [Base UI](./base-ui.md) converts `left`/`top` coordinates into `right`/`bottom` — but
  only when the element actually has a non-zero transition duration — so a popup anchored
  above its trigger grows _upward_ while animating rather than away from the anchor
  ([`adaptiveOriginMiddleware.ts:20-29`][base-ui-adaptive]).
  [Floating Vue](./floating-vue.md) hides the arrow outright when the centre offset
  exceeds half the anchor's extent along the placement axis
  ([`Popper.ts:591-609`][fvue-arrowoverflow]), and [GTK4](./gtk4.md) clamps the arrow's
  **base** points away from the corner radius while leaving the **tip** unclamped, so the
  arrow leans instead of detaching ([`gtkpopover.c:1373-1383`][gtk-arrow-clamp]).
  [Ariakit](./ariakit.md) clears `style.right` and `style.bottom` before writing the new
  static side, because in RTL a stale `right` wins over the new `left` under the used-value
  rules ([`popover.tsx:465-473`][ariakit-arrow-clear]).
- **Failure it prevents** — CSS keyed on the _requested_ side animates from the wrong
  origin after a flip; an arrow clamped to the popup's edge visually points at empty space
  beside the anchor, implying the wrong owner; and after an RTL flip the arrow visibly
  detaches from the popup.
- **Cost on one surface** — **Declare**, and it names a live defect. `sparkles` emits no
  resolved side anywhere in the widget model, the display list or `Visual` — no
  `Side`/`placement`/`arrowSide` symbol exists under `libs/ui/src` — and consequently all
  **four** canvases hard-code the popup arrow to the top edge (`grid_canvas.d:371-372`,
  `cells.d:346-347`, `html.d:227`+`:250`, `raylib_canvas.d:329-347`). Worse, they disagree
  about the column: the raylib backend places the arrow one cell left of both cell
  backends, and hue's sole call site leaves `arrowOffset` at its default `1`, so the arrow
  points at its anchor only by accident. The transform-origin datum also needs a companion:
  when the arrow could not be centred, the numeric origin is meaningless and must fall back
  to the categorical alignment.

### 52. Exit is a lifecycle with failure modes, not a fade

- **Where it is done right** — [Zag](./zag.md) unmounts immediately, without waiting for
  `animationend`, when the document is hidden — a backgrounded tab never fires it
  ([`presence.machine.ts:125-127`][zag-presence-hidden]).
  [Ariakit](./ariakit.md) pairs `transition-delay` and `transition-duration` index-wise
  under CSS's cyclic list-matching rule and skips items whose property is `none`, rather
  than taking independent maxima of the two lists
  ([`disclosure-content.tsx:39-56`][ariakit-transition]).
  [Tippy](./tippy.md) re-validates after the exit transition — still not visible **and**
  still parented — because `transitionend` can arrive a frame late or after the user
  re-triggered the surface, and makes the zero-duration case synchronous because
  `transitionend` never fires at all then
  ([`createTippy.ts:379-409`][tippy-transitioned]).
  [Floating Vue](./floating-vue.md) keeps "hidden" and "destroyed" distinct, with a 150 ms
  `disposeTimeout` tuned to the CSS transition
  ([`Popper.ts:832-842`][fvue-dispose]).
  [Angular CDK](./angular-cdk.md) gives its transparent backdrop a deliberate 1 ms
  transition on both properties purely to guarantee `transitionend` fires at all
  ([`_index.scss:130-145`][cdk-backdrop]), and `MatTooltip` sniffs
  `getComputedStyle` for `animation-duration: 0s` and self-disables its animation logic
  ([`tooltip.ts:1157-1170`][cdk-animsniff]).
  [WinUI](./winui.md) resets the content's `Scale` to identity after a shrink-to-close
  animation ([`TeachingTip.cpp:1460-1467`][winui-scalereset]).
- **Failure it prevents** — a surface stuck mounted forever waiting for an exit animation
  that will not run; an element that stays mounted and interactive after its exit animation
  finished, because the end time was over-estimated by pairing the wrong delay with the
  wrong duration; a tooltip that becomes undismissable in an app that ships
  `* { animation: none !important }`; and a re-shown surface whose first frame is
  rasterised at scale ≈ 20/width and magnified ~20× by the compositor, so it appears blurry.
- **Cost on one surface** — **Degrades**. `Timeline` ([`STM6`][spec-state]) covers the
  presence half, but two things must be said about it. It cannot host a _warm-up_ delay:
  `fadeIn` already reports `visible() == true` (`state.d:1245`), so a warming overlay
  enters the display and hit lists; `dismissed()` from `fadeIn` returns
  `Timeline(fadeOut, 0)` whenever `fadeOutMs > 0` and `alphaPercent` at elapsed 0 is 100,
  so a cancelled warm-up plays a **full-opacity fade-out** instead of vanishing; and on the
  TUI `stepped` is never driven, so a warm-up spelled as `fadeInMs` would show the overlay
  at once and never leave `fadeIn`. Separately, `Timeline.alphaPercent` is a GUI-only
  projection — a cell backend can express neither text opacity nor scale — so the cell
  targets need a second, discrete projection (a revealed-extent count) rather than a
  translucent one.

---

## Platform, degradation and the cell grid

### 53. A double-width grapheme bisected by an overlay edge is the one surviving sub-cell hazard

- **Where it is done right** — [Neovim](./neovim-floats.md) repairs the seam in **both**
  directions at every overlay boundary: if a composed run's first cell is the right half of
  a wide character it becomes a space, and if the cell just past the run is a right half the
  last copied cell becomes a space
  ([`ui_compositor.c:427-475`][nvim-seam]).
  [notcurses](./notcurses.md) degrades a double-width glyph to a space when its right half
  would fall off the last column **or** when a higher plane has already claimed the next
  cell ([`render.c:377-388`][notcurses-wide]).
  [Ratatui](./ratatui.md)'s cell diff force-repaints the trailing column when narrower
  content replaces a wide grapheme, with a _softer_ rule for VS16 emoji — symbol changes
  only, ignoring style-only changes, because the emoji visually covers that column
  ([`diff.rs:26-45`][ratatui-diff]) — and `Buffer::set_stringn` resets the cells a
  multi-width grapheme covers as it writes it ([`buffer.rs:359-366`][ratatui-setstring]).
  [tmux](./tmux-popup.md) detects a partially covered wide glyph by summing the visible
  sub-ranges and redraws the whole region as a line if the sum is short, clearing leading
  padding cells with the correct background ([`tty.c:2048-2057`][tmux-wide]).
  And the boring one that matters most: [Ratatui](./ratatui.md)'s `Clear` intersects its own
  rect against the buffer, added by commit `b5c08315` after the widget had existed since
  2020, with tests for the partially- and fully-out-of-bounds cases
  ([`clear.rs:40-42`][ratatui-clear]).
- **Failure it prevents** — an overlay edge landing mid-CJK-glyph leaves an orphaned half
  that the terminal renders as garbage and that desynchronises the row's cell accounting
  for the rest of the line; a stale reversed or underlined style survives in the trailing
  cell until something else touches it; and — the `Clear` case — the application **panics**
  ("index outside of buffer") whenever a popup crosses the right or bottom edge of the
  terminal, which is exactly the anchored case.
- **Cost on one surface** — **Declare**, and it is the _only_ sub-cell concern integer
  cells do not delete. Everything the pixel subjects spend on fractional coordinates, device
  pixel ratios and transforms is gone; this one hazard replaces all of it, and it needs an
  owner in the compositor rather than in the placement engine.

### 54. The usable area is not the screen, and the answer differs per overlay kind

- **Where it is done right** — [WPF](./wpf.md) chooses work-area versus full-monitor bounds
  per content kind **and** per anchor position: menus, tooltips and `MenuItem`-templated
  popups are confined to `rcWork` — but only if the anchor's top-left is itself inside
  `rcWork`; otherwise `rcMonitor` is used
  ([`Popup.cs:2655-2695`][wpf-screenbounds], with the rationale spelled out at `:2643-2654`).
  [Dear ImGui](./imgui.md) makes the opposite call deliberately for popups — the extent rect
  comes from `GetMainRect`, not `GetWorkRect`, so a menu opened from the main menu bar can
  extend over the bar ([`imgui.cpp:12966-12971`][imgui-mainrect]) — and applies its
  safe-area padding only when the viewport is more than twice the padding in that dimension,
  so a transiently zero-sized display cannot invert the rect
  ([`imgui.cpp:12973`][imgui-padguard]).
  [Avalonia](./avalonia.md) falls back to full bounds when a screen reports a 0×0 working
  area ([`ManagedPopupPositioner.cs:119-123`][avalonia-workarea]) and discards any resize
  adjustment whose result is not strictly positive in both axes
  ([`:144`][avalonia-isvalid]).
  [Qt Widgets](./qt-widgets.md) re-resolves the popup's screen **three times** during
  placement, marking `itemsDirty` on a change ([`qmenu.cpp:2310`][qt-screen]).
  [Flutter](./flutter.md) splits the viewport around display features — hinges, folds,
  cutouts — and uses the sub-screen nearest the anchor
  ([`display_feature_sub_screen.dart:199`][flutter-subscreen]).
  [Neovim](./neovim-floats.md) chooses the bottom inset by **stacking band**: overlays below
  z-index 200 are kept clear of the command line, overlays at or above it may cover it, and
  the inset is applied to both the size clamp and the position clamp
  ([`window.c:947`][nvim-abovech]).
- **Failure it prevents** — a tooltip near the bottom of the screen slides under the
  taskbar; an appbar application whose own UI legitimately lives outside the work area has
  its menus clamped away from their anchors; every popup lands in the top-left corner
  because an X11 window manager publishes no `_NET_WORKAREA`; a wide menu is measured on one
  screen and shown on another, so every row is the wrong height; a menu on a foldable
  straddles the hinge; and either every overlay covers the command line or none can —
  including the message pager, whose entire job is to cover it.
- **Cost on one surface** — **Declare**. The default boundary for a single-surface toolkit
  should be `surfaceRect.deflate(viewportInsets)` — the surface, **not** the anchor's
  clipping ancestor — with a per-overlay override, and the clipping ancestor governing only
  the anchor-hidden verdict of entry 7. That is the settled answer among the in-canvas
  subjects (GPUI, Flutter, Textual, Neovim's screen clamp, CDK's report-only booleans,
  Radix and CSS's explicit two-role split); it is emphatically **not** the DOM default,
  where Floating UI defaults to the clipping ancestor. Neovim's per-band inset is the
  cheapest known formulation for reserved chrome, and the inset must be a per-side
  `Insets`, not a scalar.

### 55. Soft-keyboard and cutout insets are an input, and two mature toolkits still get it wrong

- **Where it is done right** — [GTK4](./gtk4.md)'s Android backend subtracts system-bar,
  display-cutout and IME insets from the toplevel's measured size, so the popup constraint
  box already excludes the soft keyboard and no code in the placement path ever has to know
  the keyboard exists ([`ToplevelActivity.java:394-397`][gtk-android-insets];
  [`gdkandroidpopup.c:57-62`][gtk-android-popup]).
  [Angular CDK](./angular-cdk.md) re-adds negative overlay-container coordinates to the
  origin point, covering both the mobile virtual-keyboard page shift and Safari page zoom,
  with a spec that simulates it by setting the container's `top` to `-100px`
  ([`flexible-connected-position-strategy.ts:575-593`][cdk-negcoords]).
  [Compose](./compose.md) polls the host view's absolute screen location **per frame**,
  because the Android soft keyboard in `adjustPan` mode scrolls the view hierarchy without
  firing any layout callback — with a six-line comment saying the callback-based path looks
  complete and is not ([`AndroidPopup.android.kt:944-964`][compose-poll]).
  [AppKit](./apple.md) delivers the keyboard as a _reposition event_ whose anchor rect and
  container view are both rewritable
  ([`popoverPresentationController(_:willRepositionPopoverTo:in:)`][apple-reposition]),
  so the app can re-anchor to a still-visible element rather than merely squeeze.
  The negative witnesses are as instructive: [Slint](./slint.md) computes `safe_area_inset()`
  and applies it to the window item but hands `place_popup` a clip region of
  `(0,0,windowSize)`, and [Dear ImGui](./imgui.md) documents `WorkInsetMin`/`WorkInsetMax` as
  the iOS safe-area and Android display-cutout channel but does not fold them into the popup
  extent rect.
- **Failure it prevents** — a menu opened while the keyboard is up is laid out against the
  full screen and half of it is behind the keyboard; an autocomplete panel lands ~100 px
  away from its input after the browser translates the page; and — Compose's case — the
  popup silently detaches from its anchor with no event to react to.
- **Cost on one surface** — **Declare**, and it is the sharpest argument in the survey for
  the boundary being a parameter rather than a query. `sparkles`' Android target has the
  same soft keyboard and the same problem; the difference is that the inset can be folded
  into the boundary rect _before_ `place()` runs, which is what GTK4 does and what Slint and
  ImGui demonstrate the cost of not doing.

### 56. Press-only is a contract, not a limitation to work around

- **Where it is done right** — [Helix](./helix.md) explicitly **discards** key-release
  events at the application boundary even when the kitty keyboard protocol is negotiated and
  reports them, because otherwise every binding would fire twice
  ([`application.rs:724-729`][helix-release]) — direct confirmation from a terminal-first
  design that press-only is the contract. The [Popover API](./popover-api.md) specifies the
  same thing at the platform level (entry 49). Against that,
  [Qt Widgets](./qt-widgets.md) makes the _context-menu_ trigger a platform-defaulted,
  application-overridable style hint rather than hardcoding press or release
  ([`qguiapplication.cpp:3619`][qt-contextmenu-hint]).
- **Failure it prevents** — bindings firing twice; and, in the other direction, hardcoding
  press means Windows users get a context menu on button-down where the platform convention
  is button-up, which breaks right-drag gestures on one platform or the other.
- **Cost on one surface** — **Absent**, precisely scoped. [`INP16`][spec-input]'s "no key
  release" does **not** block pointer long-press on the TUI: `PointerAction.release` is a
  distinct capability the terminal serves over SGR-1006 (`libs/tui/src/sparkles/tui/input.d:164`,
  with a test at `:439`). What it blocks is **keyboard** press-and-hold — "hold a modifier to
  peek", WPF's held-key dismissal family, any read of a held key's level. Tap-to-pin
  (pointer press, optionally with release) is consequently the only hover substitution
  expressible on all three live targets: the terminal decodes SGR-1006 release, the raylib
  adapter derives press/release edges, and the Android recognizer emits a tap as
  `PointerEvent(press)` + `(release)`. A toolkit default of _long-press_-to-reveal would
  collide with a gesture hue has already spent on the only target that needs a hover
  substitute — on Android, `longPress` starts a text selection.

---

## What the list says about the framing question

Sorted by the tag on each entry's third bullet, the survey answers its own question in a
shape that is worth stating plainly.

| Tag          | Entries                                                                                                                         | Reading                                                                                                                               |
| ------------ | ------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| **Free**     | 1, 3, 4, 5, 6, 10, 11, 12, 13, 14, 16, 19, 20, 21 (arbiter), 23, 26, 27, 30, 31, 32, 33, 35, 38, 39, 42, 43, 45, 46, 47, 49, 50 | Rect arithmetic, identity tests and ordering rules. Nothing here needs a clock, a grab, a compositor or a device pixel                |
| **Declare**  | 2, 7, 8 (default), 9, 15, 17, 18, 24, 25, 29, 34, 37, 40, 41, 44, 51, 53, 54, 55                                                | Expressible, but only if the primitive takes a capability, a boundary or a policy as an explicit **input** rather than discovering it |
| **Degrades** | 22, 52                                                                                                                          | Timers and opacity: real on GUI, discrete on cells, gone on static HTML                                                               |
| **Absent**   | 28, 36, 48, 56                                                                                                                  | Pointer type, surface blur, an accessibility channel, keyboard press-and-hold. These must be **stated**, not silently approximated    |

Two conclusions follow, and both are load-bearing for
[`proposal.md`](./proposal.md). First, the great majority of the state of the art in
anchored overlays is _not_ about pixels, surfaces or window systems — it is about identity
tests, ordering rules and the discipline of keeping the request separate from the
resolution. That part ports to integer cells intact, and several entries (26, 27, 43, 45)
are structurally **cheaper** on a toolkit that rebuilds the frame every tick. Second, the
part that does not port is small, sharply bounded and already visible in the constraint
list: a clock the TUI does not run, a pointer type the event vocabulary does not carry, a
surface-blur signal the terminal does not deliver, an accessibility channel nothing emits,
and a key release that is a keyboard-only loss. The design's honesty is measured by whether
those four appear as declared capabilities with named substitutes, or as silence.

The one thing the corpus insists on that has no analogue in `sparkles` today is the
separation between the requested geometry and the resolved geometry.
[Neovim](./neovim-floats.md) states it verbatim in a comment
([`buffer_defs.h:1210-1214`][nvim-wantline]) and demonstrates the cost of violating it —
`w_wantline`/`w_wantcol` had to be added once `WinConfig.row`/`col` became the _placed_
result; [tmux](./tmux-popup.md) ([`popup.c:53-58`][tmux-preferred]) and
[GTK4](./gtk4.md) ([`gtkpopover.c:390`][gtk-layout-split]) keep the same split. Nine of the
entries above (8, 14, 15, 17, 24, 25, 44, 51, 54) are downstream of it.

## Sources

Every citation above is pinned to the revision recorded in this catalog's revision ledger;
the per-subject deep-dives listed in [`index.md`](./index.md) carry the full source
inventories. For the window-system half of the layering question — `xdg_popup` grabs
versus X11 override-redirect, and the in-canvas fork — see
[`../window-system-integration/index.md`](../window-system-integration/index.md). For the
platform conventions behind entries 22, 41 and 54, see
[`../platform-ui-guidelines/index.md`](../platform-ui-guidelines/index.md); for the
box-flow context the placement pass runs inside, see
[`../ui-layout/index.md`](../ui-layout/index.md). The shared vocabulary these entries use
is defined in [`concepts.md`](./concepts.md); the cross-subject synthesis is
[`comparison.md`](./comparison.md); what `sparkles` has today is
[`sparkles-baseline.md`](./sparkles-baseline.md).

<!-- References -->

[spec-layout]: ../../specs/ui/layout.md
[spec-input]: ../../specs/ui/input.md
[spec-backends]: ../../specs/ui/backends.md
[spec-state]: ../../specs/ui/state-machines.md
[spec-containers]: ../../specs/ui/containers.md
[spec-open-issues]: ../../specs/ui/open-issues.md
[xdg-anchor-rect]: https://gitlab.freedesktop.org/wayland/wayland-protocols/-/blob/afb614d5fcbd02d261a6ae91920aa91cf3915a8a/stable/xdg-shell/xdg-shell.xml#L180
[xdg-anchor-bounds]: https://gitlab.freedesktop.org/wayland/wayland-protocols/-/blob/afb614d5fcbd02d261a6ae91920aa91cf3915a8a/stable/xdg-shell/xdg-shell.xml#L176
[xdg-window-geometry]: https://gitlab.freedesktop.org/wayland/wayland-protocols/-/blob/afb614d5fcbd02d261a6ae91920aa91cf3915a8a/stable/xdg-shell/xdg-shell.xml#L513
[xdg-adjacency]: https://gitlab.freedesktop.org/wayland/wayland-protocols/-/blob/afb614d5fcbd02d261a6ae91920aa91cf3915a8a/stable/xdg-shell/xdg-shell.xml#L130
[xdg-flip-revert]: https://gitlab.freedesktop.org/wayland/wayland-protocols/-/blob/afb614d5fcbd02d261a6ae91920aa91cf3915a8a/stable/xdg-shell/xdg-shell.xml#L296
[xdg-flip-y]: https://gitlab.freedesktop.org/wayland/wayland-protocols/-/blob/afb614d5fcbd02d261a6ae91920aa91cf3915a8a/stable/xdg-shell/xdg-shell.xml#L308
[xdg-slide]: https://gitlab.freedesktop.org/wayland/wayland-protocols/-/blob/afb614d5fcbd02d261a6ae91920aa91cf3915a8a/stable/xdg-shell/xdg-shell.xml#L259
[xdg-offset]: https://gitlab.freedesktop.org/wayland/wayland-protocols/-/blob/afb614d5fcbd02d261a6ae91920aa91cf3915a8a/stable/xdg-shell/xdg-shell.xml#L356
[xdg-resize]: https://gitlab.freedesktop.org/wayland/wayland-protocols/-/blob/afb614d5fcbd02d261a6ae91920aa91cf3915a8a/stable/xdg-shell/xdg-shell.xml#L317
[xdg-topmost]: https://gitlab.freedesktop.org/wayland/wayland-protocols/-/blob/afb614d5fcbd02d261a6ae91920aa91cf3915a8a/stable/xdg-shell/xdg-shell.xml#L1285
[avalonia-pointer-rect]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Primitives/PopupPositioning/IPopupPositioner.cs#L481
[avalonia-flip]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Primitives/PopupPositioning/ManagedPopupPositioner.cs#L146
[avalonia-workarea]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Primitives/PopupPositioning/ManagedPopupPositioner.cs#L119
[avalonia-isvalid]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Primitives/PopupPositioning/ManagedPopupPositioner.cs#L144
[avalonia-sceneinvalidated]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/TopLevel.cs#L794
[avalonia-nonclient]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Primitives/Popup.cs#L856
[avalonia-ischildorthis]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Controls/Primitives/Popup.cs#L940
[react-aria-clamp]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/overlays/calculatePosition.ts#L298
[react-aria-warmup]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-stately/src/tooltip/useTooltipTriggerState.ts#L145
[react-aria-touch]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/tooltip/useSafeArea.ts#L62
[react-aria-childscope]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/focus/FocusScope.tsx#L780
[react-aria-restore-event]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/focus/FocusScope.tsx#L825
[react-aria-preview-role]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/tooltip/usePreviewTrigger.ts#L245
[react-aria-longpress-hint]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/tooltip/usePreviewTrigger.ts#L195
[react-aria-contextmenu-aria]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria/src/menu/useMenuTrigger.ts#L182
[react-aria-enteranim]: https://github.com/adobe/react-spectrum/blob/7c0765468a1d161ab9ac88ca9f1b54d3603a275c/packages/react-aria-components/src/Tooltip.tsx#L198
[base-ui-inline]: https://github.com/mui/base-ui/blob/adbd590484b26c1e68049348c57c70998ad667a7/packages/react/src/utils/popups/inlineRect.ts#L146
[base-ui-hide]: https://github.com/mui/base-ui/blob/adbd590484b26c1e68049348c57c70998ad667a7/packages/react/src/utils/hideMiddleware.ts#L6
[base-ui-flipbias]: https://github.com/mui/base-ui/blob/adbd590484b26c1e68049348c57c70998ad667a7/packages/react/src/internals/useAnchorPositioning.ts#L222
[base-ui-trough]: https://github.com/mui/base-ui/blob/adbd590484b26c1e68049348c57c70998ad667a7/packages/react/src/floating-ui-react/safePolygon.ts#L207
[base-ui-delaygroup]: https://github.com/mui/base-ui/blob/adbd590484b26c1e68049348c57c70998ad667a7/packages/react/src/floating-ui-react/components/FloatingDelayGroup.tsx#L184
[base-ui-focuslist]: https://github.com/mui/base-ui/blob/adbd590484b26c1e68049348c57c70998ad667a7/packages/react/src/floating-ui-react/components/FloatingFocusManager.tsx#L72
[base-ui-adaptive]: https://github.com/mui/base-ui/blob/adbd590484b26c1e68049348c57c70998ad667a7/packages/react/src/utils/adaptiveOriginMiddleware.ts#L20
[wpf-safearea-multirect]: https://github.com/dotnet/wpf/blob/99caccf23145777f910711b51961885bec783213/src/Microsoft.DotNet.Wpf/src/PresentationFramework/System/Windows/Controls/PopupControlService.cs#L864
[wpf-hull]: https://github.com/dotnet/wpf/blob/99caccf23145777f910711b51961885bec783213/src/Microsoft.DotNet.Wpf/src/PresentationFramework/System/Windows/Controls/PopupControlService.cs#L1644
[wpf-mouserect]: https://github.com/dotnet/wpf/blob/99caccf23145777f910711b51961885bec783213/src/Microsoft.DotNet.Wpf/src/PresentationFramework/System/Windows/Controls/Primitives/Popup.cs#L2306
[wpf-screenbounds]: https://github.com/dotnet/wpf/blob/99caccf23145777f910711b51961885bec783213/src/Microsoft.DotNet.Wpf/src/PresentationFramework/System/Windows/Controls/Primitives/Popup.cs#L2655
[wpf-reopen]: https://github.com/dotnet/wpf/blob/99caccf23145777f910711b51961885bec783213/src/Microsoft.DotNet.Wpf/src/PresentationFramework/System/Windows/Controls/Primitives/Popup.cs#L350
[wpf-restore]: https://github.com/dotnet/wpf/blob/99caccf23145777f910711b51961885bec783213/src/Microsoft.DotNet.Wpf/src/PresentationFramework/System/Windows/Controls/ContextMenu.cs#L624
[fui-inline]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/core/src/middleware/inline.ts#L85
[fui-trough]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/react/src/safePolygon.ts#L176
[fui-scrollbar]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/react/src/hooks/useDismiss.ts#L282
[fui-touchdelay]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/react/src/hooks/useHover.ts#L46
[fui-size-reset]: https://github.com/floating-ui/floating-ui/blob/0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1/packages/core/src/middleware/size.ts#L118
[flutter-selrect]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/packages/flutter/lib/src/widgets/text_selection_toolbar_anchors.dart#L81
[flutter-zero-delay]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/packages/flutter/lib/src/widgets/raw_tooltip.dart#L749
[flutter-reopen]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/packages/flutter/lib/src/material/menu_anchor.dart#L2249
[flutter-overlay-layout]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/packages/flutter/lib/src/widgets/overlay.dart#L1303
[flutter-closing]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/packages/flutter/lib/src/material/menu_anchor.dart#L697
[flutter-orderkey]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/packages/flutter/lib/src/widgets/overlay.dart#L1163
[flutter-subscreen]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/packages/flutter/lib/src/widgets/display_feature_sub_screen.dart#L199
[apple-popup-positioning]: https://developer.apple.com/documentation/appkit/nsmenu/popup(positioning:at:in:)
[apple-maxduration]: https://developer.apple.com/documentation/tipkit/tips/maxdisplayduration
[apple-displayfrequency]: https://developer.apple.com/documentation/tipkit/tips/configurationoption/displayfrequency(_:)
[apple-performclose]: https://developer.apple.com/documentation/appkit/nspopoverdelegate
[apple-closereason]: https://developer.apple.com/documentation/appkit/nspopover/closereason
[apple-help]: https://developer.apple.com/documentation/swiftui/view/help(_:)
[apple-reposition]: https://developer.apple.com/documentation/uikit/uipopoverpresentationcontrollerdelegate/popoverpresentationcontroller(_:willrepositionpopoverto:in:)
[gtk-tiparea]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gtk/gtktooltip.c#L994
[gtk-requery]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gtk/gtktooltip.c#L519
[gtk-flip]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gdk/gdksurface.c#L263
[gtk-slide]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gdk/gdksurface.c#L374
[gtk-press-only]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gdk/gdksurface.c#L2745
[gtk-cascade]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gdk/gdksurface.c#L2773
[gtk-acceptable-size]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gtk/gtkpopover.c#L749
[gtk-motion-request]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gtk/gtkpopover.c#L721
[gtk-arrow-clamp]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gtk/gtkpopover.c#L1373
[gtk-layout-split]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gtk/gtkpopover.c#L390
[gtk-tooltips-enabled]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gtk/gtktooltip.c#L876
[gtk-android-insets]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gdk/android/glue/java/org/gtk/android/ToplevelActivity.java#L394
[gtk-android-popup]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gdk/android/gdkandroidpopup.c#L57
[css-clipped]: https://github.com/w3c/csswg-drafts/blob/6dc15cc9cb15043840eacf081e89f5a666fa7889/css-anchor-position-1/Overview.bs#L2265
[css-chained]: https://github.com/w3c/csswg-drafts/blob/6dc15cc9cb15043840eacf081e89f5a666fa7889/css-anchor-position-1/Overview.bs#L2297
[blink-posvis]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/layout/out_of_flow_layout_part.cc#438
[blink-basestyle]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/layout/out_of_flow_layout_part.cc#2143
[blink-remembered]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/layout/out_of_flow_layout_part.cc#2119
[blink-lightdismiss]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/html/html_element.cc#3096
[blink-preseed]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/dom/element.cc#2108
[blink-restore-guard]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/html/html_element.cc#2676
[blink-suppress]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/html/html_element.cc#2681
[blink-isfinite]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/dom/element.cc#12828
[blink-isfinite-hide]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/dom/element.cc#12861
[blink-safetriangle]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/html/menu_safe_triangle.cc#95
[blink-closewatcher]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/third_party/blink/renderer/core/html/closewatcher/close_watcher.cc#113
[whatwg-hintparent]: https://github.com/whatwg/html/blob/ac0389a3aca0331055bf4bf23f509c2913e3f795/source#L91901
[whatwg-secondpass]: https://github.com/whatwg/html/blob/ac0389a3aca0331055bf4bf23f509c2913e3f795/source#L92586
[whatwg-showguard]: https://github.com/whatwg/html/blob/ac0389a3aca0331055bf4bf23f509c2913e3f795/source#L91979
[whatwg-restore]: https://github.com/whatwg/html/blob/ac0389a3aca0331055bf4bf23f509c2913e3f795/source#L92464
[whatwg-stackbottom]: https://github.com/whatwg/html/blob/ac0389a3aca0331055bf4bf23f509c2913e3f795/source#L92143
[whatwg-keydown]: https://github.com/whatwg/html/blob/ac0389a3aca0331055bf4bf23f509c2913e3f795/source#L88996
[imgui-openpopup]: https://github.com/ocornut/imgui/blob/46d39d56febc2a00bdd2270dc88c8a13f2a0441a/imgui.cpp#L12505
[imgui-lastdir]: https://github.com/ocornut/imgui/blob/46d39d56febc2a00bdd2270dc88c8a13f2a0441a/imgui.cpp#L12904
[imgui-shareddelay]: https://github.com/ocornut/imgui/blob/46d39d56febc2a00bdd2270dc88c8a13f2a0441a/imgui.cpp#L5733
[imgui-closecurrent]: https://github.com/ocornut/imgui/blob/46d39d56febc2a00bdd2270dc88c8a13f2a0441a/imgui.cpp#L12641
[imgui-ownership]: https://github.com/ocornut/imgui/blob/46d39d56febc2a00bdd2270dc88c8a13f2a0441a/imgui.cpp#L5519
[imgui-focusfallback]: https://github.com/ocornut/imgui/blob/46d39d56febc2a00bdd2270dc88c8a13f2a0441a/imgui.cpp#L12622
[imgui-noinputs]: https://github.com/ocornut/imgui/blob/46d39d56febc2a00bdd2270dc88c8a13f2a0441a/imgui.cpp#L12316
[imgui-mainrect]: https://github.com/ocornut/imgui/blob/46d39d56febc2a00bdd2270dc88c8a13f2a0441a/imgui.cpp#L12966
[imgui-padguard]: https://github.com/ocornut/imgui/blob/46d39d56febc2a00bdd2270dc88c8a13f2a0441a/imgui.cpp#L12973
[imgui-menuaim-cap]: https://github.com/ocornut/imgui/blob/46d39d56febc2a00bdd2270dc88c8a13f2a0441a/imgui_widgets.cpp#L9521
[helix-hysteresis]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/popup.rs#L128
[helix-chrome]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/popup.rs#L175
[helix-ignore-escape]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/popup.rs#L86
[helix-collide]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/handlers/signature_help.rs#L274
[helix-docs-fallback]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/completion.rs#L534
[helix-release]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/application.rs#L724
[compose-maintainpos]: https://github.com/androidx/androidx/blob/268d841a45644cadf438fc335c793869728449ec/compose/foundation/foundation/src/androidMain/kotlin/androidx/compose/foundation/text/contextmenu/internal/DefaultTextContextMenuDropdownProvider.android.kt#L193
[compose-shared-interaction]: https://github.com/androidx/androidx/blob/268d841a45644cadf438fc335c793869728449ec/compose/material3/material3/src/commonMain/kotlin/androidx/compose/material3/Menu.kt#L294
[compose-dismisstest]: https://github.com/androidx/androidx/blob/268d841a45644cadf438fc335c793869728449ec/compose/ui/ui/src/androidDeviceTest/kotlin/androidx/compose/ui/window/PopupDismissTest.kt#L129
[compose-ispopup]: https://github.com/androidx/androidx/blob/268d841a45644cadf438fc335c793869728449ec/compose/ui/ui/src/commonMain/kotlin/androidx/compose/ui/semantics/SemanticsProperties.kt#L181
[compose-alpha0]: https://github.com/androidx/androidx/blob/268d841a45644cadf438fc335c793869728449ec/compose/ui/ui/src/androidMain/kotlin/androidx/compose/ui/window/AndroidPopup.android.kt#L540
[compose-poll]: https://github.com/androidx/androidx/blob/268d841a45644cadf438fc335c793869728449ec/compose/ui/ui/src/androidMain/kotlin/androidx/compose/ui/window/AndroidPopup.android.kt#L944
[gpui-maxsize]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/editor/src/element.rs#L4179
[gpui-anchor-bounds]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui/src/geometry.rs#L837
[gpui-occluder]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/editor/src/element.rs#L4402
[gpui-prompt]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui/src/elements/div.rs#L266
[gpui-ignoreblur]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/ui/src/components/context_menu.rs#L1388
[gpui-paintsort]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui/src/window.rs#L3469
[gpui-prepaint]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui/src/window.rs#L3384
[gpui-deferred-default]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui/src/elements/deferred.rs#L10
[gpui-stable-index]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui/src/window.rs#L3366
[gpui-deferred-test]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui/src/elements/deferred.rs#L155
[textual-inflect]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/geometry.py#L999
[textual-inflect-max]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/geometry.py#L1037
[textual-translate]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/geometry.py#L991
[textual-tooltip-inherit]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/screen.py#L1615
[textual-restore]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/widgets/_select.py#L663
[textual-overlay-extent]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/_spatial_map.py#L78
[textual-hitvisible]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/_compositor.py#L842
[textual-layerindex]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/_compositor.py#L667
[cdk-outside]: https://github.com/angular/components/blob/f3e6276c969f33e527b616ef8bf7b0404685721d/src/cdk/overlay/dispatchers/overlay-outside-click-dispatcher.ts#L91
[cdk-slice]: https://github.com/angular/components/blob/f3e6276c969f33e527b616ef8bf7b0404685721d/src/cdk/overlay/dispatchers/overlay-outside-click-dispatcher.ts#L99
[cdk-keyboard]: https://github.com/angular/components/blob/f3e6276c969f33e527b616ef8bf7b0404685721d/src/cdk/overlay/dispatchers/overlay-keyboard-dispatcher.ts#L47
[cdk-push]: https://github.com/angular/components/blob/f3e6276c969f33e527b616ef8bf7b0404685721d/src/cdk/overlay/position/flexible-connected-position-strategy.ts#L742
[cdk-negcoords]: https://github.com/angular/components/blob/f3e6276c969f33e527b616ef8bf7b0404685721d/src/cdk/overlay/position/flexible-connected-position-strategy.ts#L575
[cdk-restore]: https://github.com/angular/components/blob/f3e6276c969f33e527b616ef8bf7b0404685721d/src/cdk/dialog/dialog-container.ts#L318
[cdk-wheel]: https://github.com/angular/components/blob/f3e6276c969f33e527b616ef8bf7b0404685721d/src/material/tooltip/tooltip.ts#L831
[cdk-animsniff]: https://github.com/angular/components/blob/f3e6276c969f33e527b616ef8bf7b0404685721d/src/material/tooltip/tooltip.ts#L1157
[cdk-backdrop]: https://github.com/angular/components/blob/f3e6276c969f33e527b616ef8bf7b0404685721d/src/cdk/overlay/_index.scss#L130
[cdk-describer]: https://github.com/angular/components/blob/f3e6276c969f33e527b616ef8bf7b0404685721d/src/cdk/a11y/aria-describer/aria-describer.ts#L183
[radix-direction]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/menu/src/menu.tsx#L481
[radix-bleed]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/menu/src/menu.tsx#L1146
[radix-grace-timer]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/menu/src/menu.tsx#L1157
[radix-pointermove]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/menu/src/menu.tsx#L771
[radix-blur]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/menu/src/menu.tsx#L126
[radix-below-modal]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/dismissable-layer/src/dismissable-layer.tsx#L102
[radix-skipdelay]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/tooltip/src/tooltip.tsx#L90
[radix-skipdelay-test]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/tooltip/src/tooltip.test.tsx#L380
[radix-touch-suppress]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/tooltip/src/tooltip.tsx#L301
[radix-measure-offpage]: https://github.com/radix-ui/primitives/blob/f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae/packages/react/popper/src/popper.tsx#L347
[ariakit-gutter]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/popover/popover.tsx#L126
[ariakit-arrow-clear]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/popover/popover.tsx#L465
[ariakit-refresh]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/hovercard/hovercard.tsx#L98
[ariakit-doublehide]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/hovercard/hovercard.tsx#L402
[ariakit-polygon]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/hovercard/utils/polygon.ts#L16
[ariakit-mousemoving]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-utils/src/hooks.ts#L399
[ariakit-pointveto]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/dialog/utils/use-hide-on-interact-outside.ts#L58
[ariakit-prevdown]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/dialog/utils/use-previous-mouse-down-ref.ts#L62
[ariakit-transition]: https://github.com/ariakit/ariakit/blob/a0426ed547d95b84c9d53033053e51baeaca4aaa/packages/ariakit-react-components/src/disclosure/disclosure-content.tsx#L39
[headless-outside]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/hooks/use-outside-click.ts#L106
[headless-iframe]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/hooks/use-outside-click.ts#L179
[headless-wasmoved]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/hooks/use-tracked-pointer.ts#L13
[headless-coarse]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/components/dialog/dialog.tsx#L294
[headless-dataanchor]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/internal/floating.tsx#L329
[headless-tooltip-tag]: https://github.com/tailwindlabs/headlessui/blob/eea57cf46fd6767ed1059012f7073b88eb159fba/packages/%40headlessui-react/src/components/tooltip/tooltip.tsx#L411
[zag-instant]: https://github.com/chakra-ui/zag/blob/eabc04440baa219723bc5d9a51d4e95c1deaf024/packages/machines/tooltip/src/tooltip.machine.ts#L283
[zag-pointerlock]: https://github.com/chakra-ui/zag/blob/eabc04440baa219723bc5d9a51d4e95c1deaf024/packages/machines/tooltip/src/tooltip.machine.ts#L386
[zag-scrollbar]: https://github.com/chakra-ui/zag/blob/eabc04440baa219723bc5d9a51d4e95c1deaf024/packages/utilities/interact-outside/src/index.ts#L90
[zag-pointwithin]: https://github.com/chakra-ui/zag/blob/eabc04440baa219723bc5d9a51d4e95c1deaf024/packages/utilities/interact-outside/src/index.ts#L72
[zag-requestdismiss]: https://github.com/chakra-ui/zag/blob/eabc04440baa219723bc5d9a51d4e95c1deaf024/packages/utilities/dismissable/src/layer-stack.ts#L154
[zag-initialfocus]: https://github.com/chakra-ui/zag/blob/eabc04440baa219723bc5d9a51d4e95c1deaf024/packages/utilities/dom-query/src/initial-focus.ts#L11
[zag-offscreen]: https://github.com/chakra-ui/zag/blob/eabc04440baa219723bc5d9a51d4e95c1deaf024/packages/utilities/popper/src/get-styles.ts#L228
[zag-presence-hidden]: https://github.com/chakra-ui/zag/blob/eabc04440baa219723bc5d9a51d4e95c1deaf024/packages/machines/presence/src/presence.machine.ts#L125
[tippy-tried]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/src/plugins/inlinePositioning.ts#L44
[tippy-getdelay]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/src/createTippy.ts#L202
[tippy-didhide]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/src/createTippy.ts#L338
[tippy-mousemovelisteners]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/src/createTippy.ts#L481
[tippy-pointerevents]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/src/createTippy.ts#L217
[tippy-transitioned]: https://github.com/atomiks/tippyjs/blob/ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1/src/createTippy.ts#L379
[fvue-pointerdown]: https://github.com/Akryum/floating-vue/blob/19857764c4f73dea7ed44a7d970adb968ee7ad90/packages/floating-vue/src/components/Popper.ts#L1070
[fvue-showlock]: https://github.com/Akryum/floating-vue/blob/19857764c4f73dea7ed44a7d970adb968ee7ad90/packages/floating-vue/src/components/Popper.ts#L448
[fvue-append]: https://github.com/Akryum/floating-vue/blob/19857764c4f73dea7ed44a7d970adb968ee7ad90/packages/floating-vue/src/components/Popper.ts#L882
[fvue-arrowoverflow]: https://github.com/Akryum/floating-vue/blob/19857764c4f73dea7ed44a7d970adb968ee7ad90/packages/floating-vue/src/components/Popper.ts#L591
[fvue-dispose]: https://github.com/Akryum/floating-vue/blob/19857764c4f73dea7ed44a7d970adb968ee7ad90/packages/floating-vue/src/components/Popper.ts#L832
[fvue-pointerevents]: https://github.com/Akryum/floating-vue/blob/19857764c4f73dea7ed44a7d970adb968ee7ad90/packages/floating-vue/src/style.css#L10
[qtquick-press-release]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quicktemplates/qquickpopup.cpp#L591
[qtquick-back]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quicktemplates/qquickpopup.cpp#L3240
[qtquick-cascade]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quicktemplates/qquickoverlay.cpp#L184
[qtquick-closeditself]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quicktemplates/qquickoverlay.cpp#L199
[qtquick-latch]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quicktemplates/qquickoverlay.cpp#L618
[qtquick-restore-size]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quicktemplates/qquickpopuppositioner.cpp#L214
[qtquick-reentrant]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quicktemplates/qquickpopuppositioner.cpp#L88
[qt-expire]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/widgets/kernel/qtooltip.cpp#L167
[qt-replay]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/widgets/kernel/qapplication.cpp#L3356
[qt-wheel]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/widgets/kernel/qapplication.cpp#L2818
[qt-1024]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/gui/kernel/qguiapplication.cpp#L995
[qt-screen]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/widgets/widgets/qmenu.cpp#L2310
[qt-contextmenu-hint]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/gui/kernel/qguiapplication.cpp#L3619
[winui-tailfit]: https://github.com/microsoft/microsoft-ui-xaml/blob/29ebf098f70df518b57b754130bc94004be8c6bc/controls/dev/TeachingTip/TeachingTip.cpp#L1999
[winui-midpoint]: https://github.com/microsoft/microsoft-ui-xaml/blob/29ebf098f70df518b57b754130bc94004be8c6bc/controls/dev/TeachingTip/TeachingTip.cpp#L1961
[winui-scalereset]: https://github.com/microsoft/microsoft-ui-xaml/blob/29ebf098f70df518b57b754130bc94004be8c6bc/controls/dev/TeachingTip/TeachingTip.cpp#L1460
[winui-reshow]: https://github.com/microsoft/microsoft-ui-xaml/blob/29ebf098f70df518b57b754130bc94004be8c6bc/dxaml/xcp/dxaml/lib/ToolTipService_Partial.cpp#L1769
[winui-dnd]: https://github.com/microsoft/microsoft-ui-xaml/blob/29ebf098f70df518b57b754130bc94004be8c6bc/dxaml/xcp/core/core/elements/Popup.cpp#L4746
[winui-menufocus]: https://github.com/microsoft/microsoft-ui-xaml/blob/29ebf098f70df518b57b754130bc94004be8c6bc/dxaml/xcp/dxaml/lib/FlyoutBase_partial.cpp#L2264
[winui-resizeflag]: https://github.com/microsoft/microsoft-ui-xaml/blob/29ebf098f70df518b57b754130bc94004be8c6bc/dxaml/xcp/dxaml/lib/FlyoutBase_partial.cpp#L1870
[uno-clip]: https://github.com/unoplatform/uno/blob/df5d18a850248cb8c2ccb34032b4ebeb54dc8283/src/Uno.UI/UI/Xaml/Controls/ToolTip/ToolTip.cs#L715
[uno-focusstate]: https://github.com/unoplatform/uno/blob/df5d18a850248cb8c2ccb34032b4ebeb54dc8283/src/Uno.UI/UI/Xaml/Controls/Flyout/FlyoutBase.cs#L144
[uno-nodenext]: https://github.com/unoplatform/uno/blob/df5d18a850248cb8c2ccb34032b4ebeb54dc8283/src/Uno.UI/UI/Xaml/Controls/Popup/PopupRoot.cs#L70
[slint-hadpopup]: https://github.com/slint-ui/slint/blob/24318cebc2b3feed4f7187e237915f52715ce285/internal/core/window.rs#L788
[tv-mouseinmenus]: https://github.com/magiblot/tvision/blob/57b6f56b38e0ee75240a80a10ee0e11470c24693/source/tvision/tmnuview.cpp#L148
[tv-lasttarget]: https://github.com/magiblot/tvision/blob/57b6f56b38e0ee75240a80a10ee0e11470c24693/source/tvision/tmnuview.cpp#L233
[tv-putclick]: https://github.com/magiblot/tvision/blob/57b6f56b38e0ee75240a80a10ee0e11470c24693/source/tvision/tmnuview.cpp#L218
[tv-valid]: https://github.com/magiblot/tvision/blob/57b6f56b38e0ee75240a80a10ee0e11470c24693/source/tvision/tgroup.cpp#L184
[nvim-armed-delay]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/os/input.c#L130
[nvim-seam]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/ui_compositor.c#L427
[nvim-zindex]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/ui_compositor.c#L186
[nvim-abovech]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/window.c#L947
[nvim-wantline]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/buffer_defs.h#L1210
[notcurses-owner]: https://github.com/dankamongmen/notcurses/blob/b26048eebc74d5d254717d3332fa484718f9efe6/src/lib/render.c#L392
[notcurses-wide]: https://github.com/dankamongmen/notcurses/blob/b26048eebc74d5d254717d3332fa484718f9efe6/src/lib/render.c#L377
[ratatui-clamp]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-core/src/layout/rect.rs#L387
[ratatui-diff]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-core/src/buffer/diff.rs#L26
[ratatui-setstring]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-core/src/buffer/buffer.rs#L359
[ratatui-clear]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-widgets/src/clear.rs#L40
[tmux-wide]: https://github.com/tmux/tmux/blob/851c5a933d4838c32ad06c248b2ba975d106149c/tty.c#L2048
[tmux-lostpane]: https://github.com/tmux/tmux/blob/851c5a933d4838c32ad06c248b2ba975d106149c/window.c#L1066
[tmux-preferred]: https://github.com/tmux/tmux/blob/851c5a933d4838c32ad06c248b2ba975d106149c/popup.c#L53
[blink-delay-charge]: https://github.com/Saghen/blink.cmp/blob/8ca29c2eb34f5ce4770bffc0d62e6f636a4e8526/lua/blink/cmp/completion/windows/menu/init.lua#L167
[blink-timerkey]: https://github.com/Saghen/blink.cmp/blob/8ca29c2eb34f5ce4770bffc0d62e6f636a4e8526/lua/blink/cmp/completion/windows/menu/init.lua#L180
[blink-desired-min]: https://github.com/Saghen/blink.cmp/blob/8ca29c2eb34f5ce4770bffc0d62e6f636a4e8526/lua/blink/cmp/config/completion/documentation.lua#L60
[blink-scrollbar-border]: https://github.com/Saghen/blink.cmp/blob/8ca29c2eb34f5ce4770bffc0d62e6f636a4e8526/lua/blink/cmp/lib/window/init.lua#L231
[blink-pumpos]: https://github.com/Saghen/blink.cmp/blob/8ca29c2eb34f5ce4770bffc0d62e6f636a4e8526/lua/blink/cmp/signature/window.lua#L145
[nvimcmp-defheight]: https://github.com/hrsh7th/nvim-cmp/blob/2ffe79f1f021def8dd1fcd81deb16f1bb0d989f3/lua/cmp/view/custom_entries_view.lua#L11
[company-height]: https://github.com/company-mode/company-mode/blob/1cc907ac9e46ae4209eb5a341131787e0c678406/company.el#L4371
[apg-containment]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/toolbar/examples/toolbar.html#L59
[apg-arrow-events]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/toolbar/examples/css/toolbar.css#L67
[apg-relatedtarget]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/combobox/examples/js/select-only.js#L249
[apg-doesnotcontain]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/menubar/examples/js/menubar-editor.js#L457
[apg-tooltip-focus]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/tooltip/tooltip-pattern.html#L31
