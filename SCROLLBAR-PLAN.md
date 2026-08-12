# Scrollbars: make the right path the only path

**Implementation record + agent handoff.** Branch `feat/hue/tree-sitter-inspector`,
worktree `sparkles-hue-tree-sitter-inspector`. Approved 2026-08-12.
(A copy of the approved plan also lives at `~/.claude/plans/vast-churning-manatee.md`;
**this file is the authority** — it carries the handoff context.)

---

## 1. Why

Fifth round of scrollbar bugs. The reported GUI symptoms are one disease:
`ScrollView` (`SCV1`) was supposed to end this class and did not, because **a
scrollbar here is a convention you assemble, not a component you have.** Six
sites assemble it; each new pane forgets a different piece.

The audit, in numbers:

- **6 rendering paths** — `chrome.scrollbar` (cell glyphs, the loop written
  twice in one file), `ui_raylib.drawScrollbar` (px, animated, bypasses the
  display list entirely), hue's hand-built `ScrollbarLayout` literals for
  fences, the markdown fence bars (the only bars not using the `track`/`thumb`
  slots), the gallery's 1-or-2-column quantised bar, the gallery's hand-rolled
  px rail — plus `libs/terminal-view`, which has **its own struct also named
  `ScrollbarState`** and a 4th thumb formula that fails the flush-at-both-ends
  property `scrollbarThumb` is property-tested for.
- **The idle-rail width is copied five times** in `gui.d`, twice with `cellW`
  and twice with `cellH`; the expanded _width_ constant is used as a _height_
  for both horizontal bars (a live bug, hidden because `cellW ≈ cellH`).
- **Paint geometry ≠ hit geometry everywhere except the gallery** — hue's
  document h-bar is drawn from one rect and hit-tested against another origin
  plus a magic `- 4`. `TreeViewState` states its bar zones twice.
- **`TreeViewState` never calls `ScrollView`** — it drives `ScrollbarState`
  directly, so every pane built on it (hue's explorer, hue's inspector, the
  gallery's tree page) has no capture arbitration, no hover, no easing. The
  toolkit's own tree component opted out of the toolkit's own scroll container.

Reported symptom → cause:

| Symptom (GUI UAT)              | Cause                                                                                                                                                                                              |
| ------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Inspector bar has no animation | Painted as **cell glyphs** through the widget tree while its neighbours are **animated px** painted outside it. Two renderers in one window.                                                       |
| No horizontal bar              | `inspectorView` only ever emits the vertical one; nothing derives "this axis overflows" for it.                                                                                                    |
| Wheel does nothing             | `gui.d`'s wheel arm sat inside the final `else` of a **keyboard-focus** chain. Clicking the pane focuses it, and the wheel died window-wide — though `dock.handle` would have routed it correctly. |
| Drag offset                    | The component paints the bar at pane row 2; `TreeViewState.pointer` hit-tests rows 1..bodyRows; `inspector_pane.d` bridges with `pos.y - 1`. Three parties, one geometry, no owner.                |
| Gallery page list has no bar   | Nobody owns "this region scrolls". `GalleryState.navScroll` has **never been read or written**.                                                                                                    |

The user's hypothesis — scrollbars are integrated by hue instead of built into
`dock.d` — is the more important half. The other half: the toolkit cannot
_express_ hue's bar, so a container that painted bars could not paint the one
hue wants (`UGL-O6`: widget bars are whole-cell; hue's rail is ⅓ cell easing to
1.5). **Both halves move, in that order** — container-first would leave the
inspector still not animating.

---

## 2. Feature requirement: selection and scrolling must compose

Stated directly, because it is in no spec today and **nothing in the repo
implements it** (the one "selection auto-scroll" mention, in `terminal-view`'s
module doc, is aspirational — its own code comment concludes "the user will
have to drag the thumb"):

1. **A scroll during a selection extends it.** With the button held, the wheel
   (or any other scroll — keys, a search jump) must keep working, and the
   selection must extend over the content it reveals **without the pointer
   moving**. A capture must never swallow the wheel.
2. **Dragging to or past an edge autoscrolls.** A hot band at each edge of the
   pane's content rect starts a continuous scroll that accelerates with
   deflection, extending the selection as it goes, stopping at the content's
   ends and on release.
3. **Both axes, independently.** Long lines and wide tables/spreadsheets scroll
   sideways under the same rule; a diagonal drag scrolls both.
4. **Both targets.** In a terminal the pointer _cannot_ be reported past the
   edge — SGR mouse reporting stops at the last cell — so the near-edge band is
   not a nicety, it is the only mechanism the TUI has. In a window the OS keeps
   delivering motion outside the frame while a button is held, and the ramp
   saturates.

It belongs in the container: it already owns the offsets, the pane rects and
the capture, and is the only party that knows a drag is in flight _and_ how far
the pointer is from an edge. **Panes stay ignorant** — after any scroll while a
pane holds the pointer, the container re-delivers a **synthetic drag at the
last pointer position**, so each pane's existing drag arm extends the selection
with no new code, in either backend.

One new host obligation: a **tick**. Autoscroll must continue while nothing
moves. The GUI has `frameSeconds`; the TUI is event-driven and its
`frameSeconds` is `0`, so the container exposes `nextTickIn()` and hue's
workspace feeds it to the deadline machinery it already has (`HST16`). This is
genuinely tier-2 — the category `IXR17` flagged for the touch fling.

---

## 3. Decisions taken (do not re-litigate)

- Sub-cell crosses the seam as a **semantic `ubyte expandPercent`** (0 = idle
  rail, 100 = expanded), never a px width — the `RuleEdge` bargain, and the
  shape `Visual.fontScale`/`fgAlpha` already use. This is what _deletes_ the
  five rail-width copies instead of relocating them.
- **The op carries content units, never a resolved thumb.** hue's document bar
  derives its thumb over a px track with `minExtent: 24`; a cell-resolved thumb
  would make the most-used bar in the app snap by whole rows.
- **Wheel means viewport everywhere** (was: the TUI explorer moved the cursor).
- The container **routes** wheels (`DCK7`, already correct) and offers
  `scrollBy` for the clamp; panes keep policy (hue's fence gets first refusal).
- Reserved gutters are **always reserved**, live or not: a pane that reflowed
  when a bar appeared would oscillate at the width where content just fits.
- Scope includes the outliers (fence bars adopt the new drawing;
  `terminal-view`'s private bar is converted) as a final, droppable stage.

---

## 4. Status

Implementation completed through the optional outliers on 2026-08-12. The
stage commits before the final integration are `00bd9dbe`, `f2edea63`,
`13598992`, `5015aff6`, and `4937e156`.

| Stage                                                           | State                                                                                                           |
| --------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| 0 — oracles, wheel hoist, spec rows                             | complete — pointer injection, wheel routing, specs and GUI baselines                                            |
| 1 — `OpKind.scrollbar` + cell degrade + `ScrollbarAnim.percent` | complete (`f2edea63`)                                                                                           |
| 2 — `RaylibCanvas.scrollbar` owns the px look                   | complete (`f2edea63`)                                                                                           |
| 3 — `WidgetKind.scrollbar`; the inspector animates              | complete (`f2edea63`)                                                                                           |
| 4 — one geometry authority (`SCV7`)                             | complete (`13598992`)                                                                                           |
| 5 — `TreeViewState` through `ScrollView`                        | complete (`5015aff6`)                                                                                           |
| 6 — the dock owns pane scrolling (`DCK14`)                      | complete — gallery foundation (`4937e156`) plus Hue TUI/GUI adoption                                            |
| 7 — selection ⨯ scrolling composes (`SCV8`)                     | complete — pure ramp, synthetic drag, event-driven TUI ticks and end-to-end selection test                      |
| 8 — outliers: fence bars + `terminal-view` (droppable)          | complete — semantic fence nodes with no GUI overlay; terminal overlay on `ScrollView`/pane-local `scrollLayout` |

---

## 5. Stages

Each stage builds, tests and lints alone. The deletion column is the point.

### Stage 0 — oracles and the wheel (small, immediate relief)

- ✅ `explorer.d`'s wheel moves the **viewport**, not the selection
  (+ `explorer.wheel.scrollsTheViewNotTheCursor`).
- ✅ `gui.d`'s wheel arm **and** the mouse back/forward arm hoisted out of the
  keyboard-focus `else` chain (they were dead whenever a pane held focus).
- ✅ **`HUE_GUI_POINTER=<x>,<y>` in `GuiCapture`** (`apps/hue/src/gui_state.d`,
  beside `HUE_GUI_INSPECT`). Today `HUE_GUI_HOVER` forces the _Nth popup_, not
  a pointer — so the expanded rail, the hover track, the easing and every hit
  zone are **unphotographable**. ~10 lines, covered by the existing `fromEnv`
  fake-env test; it converts the half of this work that has no oracle into
  goldens. Highest value-per-line item in the plan. Inject at
  `apps/hue/src/gui.d:1680` (`inp.fin = foldFrame(evBuf, inp.fin);`) by
  overriding `inp.fin.pos` when the capture is set.
- ✅ Spec rows: new `SCV7` (geometry authority), new **`SCV8`** (selection ⨯
  scrolling composes — §2, stated before it is built), `DCK14` promoted from
  proposed, a `UIA` decision record for `expandPercent` beside the 2026-08-06
  `RuleEdge` one, and `TRV3`/`gui.md SEL` cross-refs.
- ✅ Record screenshot baselines (§8), including inspector coexistence and an
  overflowing fence in idle and injected-hover states.

### Stage 1 — the bar becomes a drawing the toolkit can express (dormant)

`libs/ui/src/sparkles/ui/canvas.d`: `OpKind.scrollbar`, reusing **`RuleEdge`**
for placement (`right`/`bottom` for pane bars, `centerX`/`centerY` for hue's
border-centred fence bars — all four cases already exist; generalise its doc
from "where a hairline sits" to "where a sub-cell band sits"). `DrawOp` gains
`barContent`/`barViewport`/`barOffset` (`int`, saturating cast in the
producer), `expandPercent`, `barTrackLit`, `barTrackColor`, and the two glyphs.
Pure degrade helpers beside `ruleEndpoints`: `scrollbarCellCount` /
`scrollbarCell`.

Arms in **both** dispatchers — `interp/immediate.d` (`__traits(compiles, …)`,
exactly like the `rule` arm) and `ui-tui/grid_canvas.d`'s own `final switch`
(it does **not** use `interp.immediate.paint`, for dip1000 `scope` reasons).
The cell degrade is a threshold, not a ramp: `< 50` → one column with
`'█'`/`'│'` (byte-identical to today), `>= 50` → two columns. That is the
gallery's shipped behaviour promoted into the toolkit, and it keeps every TUI
golden identical.

`ScrollbarAnim` loses its px `width` for `percent`; `easeV(caps, dt)` loses its
two float parameters. Rename `libs/terminal-view`'s `ScrollbarState` →
`OverlayScrollbar` (3 call sites, zero risk).

_Deletes:_ nothing yet — nothing emits the op. That dormancy is what makes it
reviewable.

### Stage 2 — the px backend owns the px look

`RaylibCanvas` gains the optional `scrollbar` primitive, with geometry factored
into **pure, window-free** `scrollbarRail` / `railIdlePx` / `railExpandedPx`
(use `cellExtent*3/2`, **not** `cast(int)(x*1.5f)` — they differ on odd cell
sizes). hue's six px draw sites emit the op.

_Deletes:_ `ui_raylib/scrollbar.d` **entirely** (`toRaylibCursor` moves to
`events.d`), the five idle-rail copies, both hand-built `ScrollbarLayout`
literals, the gallery's px rail and its third colour authority. Fixes the
width-constant-used-as-a-height bug — land that as its own commit with a
re-baselined capture.

### Stage 3 — one widget, and the inspector animates

`WidgetKind.scrollbar` + `ScrollbarSpec` (content units, axis, expand, gutter,
glyphs, optional fg overrides for the fence bars). Seven `final switch` arms;
four are grouped leaf arms, so a one-token addition. `chrome.scrollbar`
collapses **both** overloads and the twice-written loop into one node; the
gallery's catalog pages keep a thin static specimen wrapper.

`inspectorView` emits that node → in the GUI it flows through
`RaylibCanvas.scrollbar`, animated and hover-expanding. **First reported
symptom fixed**, with zero geometry risk (the pane rect comes from the dock in
exact cells).

### Stage 4 — one geometry authority (`SCV7`)

In `scroll_view.d`: `ScrollArea` (rect + per-axis extents + gutters + per-axis
`minExtent`) → pure `scrollLayout` → `ScrollLayout` (content rect, both track
rects, liveness), plus `vExtents`/`vPointer` and `ScrollView` overloads that
consume the pair. **Purity is the enforcement**: "paint and hit must use the
same geometry" is discharged by computing one `ScrollArea` per pane per frame.

Mixed units: **formalise, and fix the two defects it hides.** An axis _is_ a
unit (px on the document's vertical, cells on its horizontal — correct; forcing
them together would degrade one). Per-axis `minExtent` becomes explicit (today
the horizontal thumb can be one unit long — the exact ungrabbability the
vertical bar's 24 exists to prevent).

_Deletes:_ `tui.d:275-281`, `tree_view.d:120-126`, `workspace.d`'s out-of-band
`hoveredNow` block, both `-4`s, six duplicated hit expressions in `gui.d`.

### Stage 5 — `TreeViewState` goes through `ScrollView`

Add `headerRows` (chrome rows _above_ the tree body — `inspectorView` has two,
the explorer one; that mismatch **is** the `pos.y - 1` shim), a `scrollFrame()`
accessor over stage 4, `pointer(p, ref capture, capBase)` routing both axes
through `stepH`/`stepV`, and `tick(caps, dt)`. Keep a one-argument `pointer`
overload for exactly one stage so consumers and the eight existing tests
compile untouched, then delete it.

_Deletes:_ the inline bar zones, `overScrollbar`/`overHScrollbar`,
`inspector_pane.d`'s `pos.y - 1`. The inspector gains capture arbitration and
its horizontal bar.

### Stage 6 — the dock owns it (`DCK14`)

`DockNode.scrollGutterV/H`, carved in `walk` exactly like `headerExtent`
(header off the top, V gutter off the right, H off the bottom of the
remainder; the corner belongs to V, so the H track is one gutter shorter —
which is what hue paints today). `PaneFrame.rect` then excludes them, so
`contentCell`/`toLocal` exclude them **for free** — the UAT bug where hue's
bars landed inside the inspector pane becomes unrepresentable, and `SCB3`'s
reserved gutter becomes structural instead of a hue constant.

`DockContainer` gains: `contentExtent(pane, cols, rows)` in; `offsetV/H(pane)`
out; `scrollOf(pane)` (**const** — the container runs the grab);
`scrollBy`/`scrollTo`/`reveal`; `tickScroll(dt, caps)`; `ScrollFrame[] bars` in
`DockFrames` (**frames, not widgets** — `dock.d` stays free of `Builder`, and
hue's pixel painter stays a first-class consumer); `scrollCapBase = 1 << 40`
(chosen to fit between `divCapBase = 1<<32` and `tabCapBase = 1<<48` so **no
existing predicate changes**); a `routeScroll` arm inserted as step **3b**,
between the tab strip and the positional query; and `cellW`/`cellH` (default
`1×1` = identity, so terminals cannot regress).

On `cellW`/`cellH`: hue's GUI already reads real px (`RunConfig.pointerUnit`)
and throws them away at the container's door with `pointerFor`. The container
divides for routing and keeps the remainder for the one affordance whose
resolution should follow the device — the bar grab. Cell-space-only cannot
work: a 4 000-line document in a 45-row pane gives 45 reachable offsets;
hue has ~800 today.

Adoption order: **gallery shell bars → gallery nav list → hue TUI panes → hue
GUI**. The GUI step replaces the synthesised one-pointer-per-frame with a
single unconditional drain of the real `evBuf` through `dock.handle` — one call
site, not inside any branch, so the wheel bug class is gone by construction (a
fast drag also stops skipping positions, and Android gains the press/release
edges `gui.d:936-945` documents as missing).

_Deletes:_ the gallery's `driveVertical`, `BarGeometry`, both bar blocks in
`onPointer`, `contentView`/`inspView`, **the dead `navScroll`**; hue TUI's bar
branches and release lines; hue GUI's four grab/hit blocks, four capture ids,
`paneGrab`/`paneHover` (byte-identical to `workspace.d`'s), the three
`pointerFor` divisions and the offset re-sync trio. Net ≈ −600 lines.

### Stage 7 — selection ⨯ scrolling composes (`SCV8`)

- Pure machine in `scroll_view.d`: `AutoScroll { int band; float maxRate; }`
  with `Point tick(in Rect content, in Point pointer, float dt)` → per-axis
  delta in **content units**; zero in the dead zone, ramped with deflection,
  saturating, clamped to the ends by the `ScrollView` it feeds.
- The container advances it in `tickScroll` **for the capture-holding pane
  only**, applies `scrollBy`, and — after any scroll while a capture is live —
  emits the synthetic `PointerAction.drag` at the last pointer position.
  `nextTickIn()` returns `Duration.max` when no capture is live (an idle
  terminal still emits no bytes).
- hue's document selection, the diff view's hunk drags and the tree's row drags
  all get it **for free** — the synthetic drag is indistinguishable from a real
  one.

_Acceptance_: start a selection and spin the wheel → it extends without moving
the pointer; drag to the bottom edge → it scrolls and keeps selecting,
accelerating with deflection, stopping at the end; same left/right on a
long-line document and a wide table; release stops it; both backends.

### Stage 8 — the outliers (droppable)

- **Fence bars** adopt the widget-level node (`stack(borderRow,
scrollbar(edge: centerY))`), deleting ~90 lines of hue overlay. They stay
  _content_-level — the container must not absorb them (no `PaneId`, many per
  document, row-dependent). Risk: byte-pinned markdown goldens.
- **`libs/terminal-view`'s overlay** converted to the toolkit machine. **Not a
  pure refactor**: its track is `GetScreenHeight()` (the whole screen, wrong
  when embedded), its track-press centres rather than jumping the leading edge,
  and its drag re-reads the offset after issuing a ghostty delta. Converting
  changes scrollback behaviour under `TVW`'s own spec.

---

## 6. Deliberately not doing

Container emitting widgets (frames only); `ScrollView` made private (hue's
fences and the gallery's specimens are legitimate direct users); a `Scrollable`
interface or callback web; content extent on `DockNode` (per-frame data; the
layout value stays Regular and serializable per `DCK1`/`DCK2`); a
`ScrollPolicy` enum (gutter `0`/`N` already spells never/always); auto-hiding
gutters; a second `ScrollbarEdge` enum; `expandPercent` on `Visual` (it is on
every op; this concerns six a frame); moving `ScrollbarGlyphs` into the theme's
`GlyphSet` yet (needs `Theme`, not just `Palette`, in `buildDisplayList`);
nested scrollables; `SCV5` element-store identity (`PaneId` _is_ the identity
here).

---

## 7. Relevant files (context map)

### The shared core — what everything should go through

| File                                                    | Why you care                                                                                                                                                                                                                                                                                                                                                                         |
| ------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `libs/ui/src/sparkles/ui/state.d`                       | `scrollbarThumb:593` (THE thumb formula, property-tested), `ScrollState:620` (`draggedTo:647`, `pressedAt:665` — grab-relative), `ScrollbarState:763` (`pressed:775`, `dragged:786`, `released:797`, `hoveredNow:801`, `scrolledTo:805`, `thumb:809`, `shape:817`, `expanded:834`). `grab` is stored in **track units**.                                                             |
| `libs/ui/src/sparkles/ui/components/scroll_view.d`      | `ScrollView:71` (`stepV:96`, `stepH:104`, `wheeledV:113`, `easeV:127`, private `run:151` — the only capture arbitration in the repo), `ScrollbarAnim:32` (15/s rate), `ScrollExtents`, `ScrollPointer`. Stages 1, 4, 7 all land here.                                                                                                                                                |
| `libs/ui/src/sparkles/ui/canvas.d`                      | `OpKind:49`, `DrawOp:66`, `RuleEdge:39` + `ruleEndpoints:85` (the sub-cell precedent), `isCanvas:130`, `RecordingCanvas:151`. Stage 1's op goes here.                                                                                                                                                                                                                                |
| `libs/ui/src/sparkles/ui/interp/immediate.d`            | The painter; `rule` dispatch + fallback at `:38-52` — the template for a new optional primitive. Test `:101`.                                                                                                                                                                                                                                                                        |
| `libs/ui/src/sparkles/ui/interp/cells.d`                | `accentGlyph:105` — px weight → `▏▎▌`/`▕▐`, the "sub-cell degrades to block glyphs" reference.                                                                                                                                                                                                                                                                                       |
| `libs/ui/src/sparkles/ui/components/chrome.d`           | `ScrollbarGlyphs:48`, `scrollbar:59` (position-only) and `:79` (machine-driven) — **the same loop written twice**. `scrollView:33`. Collapses in stage 3.                                                                                                                                                                                                                            |
| `libs/ui/src/sparkles/ui/components/dock.d`             | 1975 lines. `DockNode:63`, `DockLayout:93`, `walk:525` (leaf branch `:531-548` is where gutters get carved), `PaneFrame:433`, `DockFrames:501`, `DockContainer:841`, `arrange:894`, `handle:1054` (wheel `:1059`), `routePointer:1083` (precedence 1-5; **step 3b goes between `:1212` and `:1216`**), `contentCell:1275`, `toLocal:1291`, cap bases `:884-886`, tests `:1309-1975`. |
| `libs/ui/src/sparkles/ui/components/tree_view.d`        | `TreeViewState:76`, `scroll:87`, `sb`/`hsb:99-103`, `hOverflows:115`, `overScrollbar:120`, `overHScrollbar:125`, `clamp:173`, `clampBounds:197`, `pointer:255-303` (**drives `ScrollbarState` directly — no capture, no hover, no easing**). Stage 5's target.                                                                                                                       |
| `libs/ui/src/sparkles/ui/components/inspector.d`        | `inspectorView:82`; the in-widget-tree bar at `:104-117` (why the GUI inspector is glyphs); `actionAt`, `WidgetInspect`.                                                                                                                                                                                                                                                             |
| `libs/ui/src/sparkles/ui/widget.d`                      | `Widget:72` (fat per-kind payload POD — where `ScrollbarSpec` goes), `WidgetKind:45`.                                                                                                                                                                                                                                                                                                |
| `libs/ui/src/sparkles/ui/display_list.d`                | `buildDisplayList` — emits only `fillRect`/`textRun`/`glyph`/`line`/clip today; never `rule`.                                                                                                                                                                                                                                                                                        |
| `libs/ui-raylib/src/sparkles/ui_raylib/scrollbar.d`     | 127 lines: `ScrollbarLayout:31`, `scrollbarLayout:46`, `drawScrollbar:74` (raw `DrawRectangle`, no canvas, no display list), test `:87`. **Deleted in stage 2.**                                                                                                                                                                                                                     |
| `libs/ui-raylib/src/sparkles/ui_raylib/raylib_canvas.d` | `RaylibCanvas` — cells→px `:74`, `fillRect:154`, `rule:218`, `fillPixels:143` (the `UIA7` escape hatch), clip `:82-123`. Stage 2's new primitive.                                                                                                                                                                                                                                    |
| `libs/ui-tui/src/sparkles/ui_tui/grid_canvas.d`         | `GridCanvas` + **`paintGrid`'s own `final switch` `:49-86`** (second dispatcher — a new op needs an arm here too), `accentColumn:295`, cross-canvas agreement test `:655-722`.                                                                                                                                                                                                       |

### hue (the biggest consumer)

| File                            | Why you care                                                                                                                                                                                                                                                                                                                                                                                                     |
| ------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `apps/hue/src/gui.d`            | ~3000 lines, **zero unit tests**. Bars drawn `:1424`, `:1449`, `:1500`, `:1511`, fences `:1102`/`:1128`; grab/hit blocks `:2432-2490` (V, px) and `:2837-2877` (H, cells, with the magic `-4`); `scrollbarGutter:387`; `docRightPx:466`; `paneContent:448`; `FrameGeom:246`; `chrome = RaylibCanvas(...)` at `:992`; wheel + back/forward now hoisted out of the focus chain (was inside the `else` at `:2023`). |
| `apps/hue/src/tui.d`            | `PreviewTui`; `sb` ref `:116`, `overScrollbar:275`, `overHScrollbar:280`, `paintScrollbar:756`, bar arms `:1255-1310`, fence bars `:821`/`:844`, `offsetAt` (inspector hover feed).                                                                                                                                                                                                                              |
| `apps/hue/src/workspace.d`      | The TUI shell: `dock` `:92`, panes `:93`, `buildLayout:164` (**sets no `headerExtent`** — the GUI does, which is why panes compensate by hand), `arrange:181`, `paint:289`, `handle:652` (`dock.handle` at `:739`), `paneGrabShape`/`paneHoverShape:611-631`, grid tests `:1600-2330` incl. `workspace.inspectorPane.itsScrollbarIsItsOwnColumnAndItHolds:2257` (the existing `DCK14` regression test).          |
| `apps/hue/src/explorer.d`       | `ExplorerTui` over `TreeViewState`; wheel arm (**now viewport-scrolling**), pointer `:652`, tests `:919+`.                                                                                                                                                                                                                                                                                                       |
| `apps/hue/src/inspector_pane.d` | `InspectorPane`; the `pos.y - 1` shim in the pointer arm; wheel arm; `picking`/`pick`.                                                                                                                                                                                                                                                                                                                           |
| `apps/hue/src/gui_state.d`      | `GuiCapture:431` + `fromEnv:444` (**`HUE_GUI_POINTER` goes here**), `Panes:173` (`inspVisible`/`treeVisible` proxy `dock.layout.setVisible`), 13 unit tests — the only testable GUI state.                                                                                                                                                                                                                       |
| `apps/hue/src/viewer_model.d`   | `ViewerModel` — `scroll`, `hOverflows`, `contentCols`, `sbTrack`/`sbThumb`, `inspectRects`, `setInspectExtent`. Backend-neutral; `@system:` label from `:268`.                                                                                                                                                                                                                                                   |

### ui-gallery (the toolkit's showcase, and the best-wired consumer)

| File                                    | Why you care                                                                                                                                                                                                                                                                                                    |
| --------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `apps/ui-gallery/src/scrollbars.d`      | 392 lines, the whole per-bar wiring once: `BarGeometry:53`, `verticalBar:73` (1-or-2-column quantisation), `easeVertical:117`, `driveVertical:144`, `rectOf:179` (**the only consumer deriving its hit rect from the painted frames**), 9 unit tests `:206-392`.                                                |
| `apps/ui-gallery/src/gallery.d`         | Shell: `dock:90`, `syncDock:456`, `onPointer:813` (dock → bars → page, the ordering `DCK14` generalises), `onWheel:974` (geometric, `UGL-O5`), `navPane:1084` (**`clipY: true`, no offset — the missing bar**), `paintTermChrome:543` (hand-rolled px rail, third colour authority), acceptance tests `:1497+`. |
| `apps/ui-gallery/src/state.d`           | Five `ScrollView`s (`contentView:289`, `demoView:315`, `chromeView:319`, `termView:327`, `inspView:331`), `navScroll:294` (**dead**), `keyNavScroll:93`, hit ids `:68-81`.                                                                                                                                      |
| `apps/ui-gallery/src/render.d`          | `--render`/`--render-plain` headless frame (`frameSeconds = 0`, so easings snap) — the determinism harness.                                                                                                                                                                                                     |
| `apps/ui-gallery/src/pages/dock_page.d` | The container demo; re-walks the arena itself; the natural place to _show_ a container-owned bar.                                                                                                                                                                                                               |

### Elsewhere

| File                                                    | Why you care                                                                                                                                                     |
| ------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `libs/syntax/src/sparkles/syntax/md/render_widgets.d`   | Fence bars: `fenceBottomBorder:742`, `fenceVTrack:783` — glyph borders that _are_ the bars; the only bars not using `Slot.track`/`Slot.thumb`. Stage 8.          |
| `libs/terminal-view/src/sparkles/terminal_view/input.d` | **`struct ScrollbarState:272`** (name collision), hit/drag `:350-430`. `core.d:699-721` draws it; `component.d:131` gates it. Stage 1 renames, stage 8 converts. |
| `libs/input/src/sparkles/input/frame.d`                 | `InputFrame`, `foldFrame`, `pointerFor:232` (the px→cell truncation stage 6 deletes), `wheelCells:60`.                                                           |

### Specs to update as you go

`docs/specs/ui/containers.md` (`SCV1`-`SCV6` → add `SCV7`/`SCV8`; `DCK1`-`DCK14`)
· `docs/specs/ui/widgets.md` (`WGT10`, `VMD7`) ·
`docs/specs/ui/state-machines.md` (`STM2`, `STM9`) ·
`docs/specs/ui/interaction-review.md` (`IXR1`-`IXR4`, `IXB1`/`IXB2`/`IXB10` —
several rows marked "resolved" are resolved _only for hue's four original
bars_, which is the failure mode) · `docs/specs/hue/gui.md` (`SCB1`-`SCB5`,
`RND4`, `SEL5`, `COD6`) · `docs/specs/hue/tui.md` (`TSB1`) ·
`docs/specs/hue/ui-architecture.md` (the 2026-08-06 `RuleEdge` decision record
— put `expandPercent`'s beside it) · `docs/specs/ui-gallery/open-issues.md`
(`UGL-O5`, **`UGL-O6` closes**) · `docs/specs/ui/open-issues.md`.

---

## 8. Verification

```bash
dub test :ui            # 322 tests
dub test :hue           # 215 (+2 skipped without the twoslash extractor)
dub test :ui-gallery    # 122
dub test :syntax        # 123
nix run .#ci -- --test  # 34/34 sub-packages passed (2026-08-12)
```

- **Pure/unit**: `RecordingCanvas` degrade test (twin of
  `ruleFallsBackToTheCellAlignedLine`); **cross-canvas agreement** extending
  `grid_canvas.d:655` — one op through `paintGrid` and through
  `interp.immediate.paint` must give identical glyphs at `expandPercent` ∈
  {0,49,50,100}, both axes, both track states; `scrollbarRail`
  idle/expanded/monotonicity incl. **odd cell sizes**; `scrollLayout`
  invariants; the emitted rect's axis extent == the frame's.
- **The `-1` regression, as a test**: build `inspectorView`, lay it out, assert
  the bar node's painted rect == `state.scrollFrame().vTrack`, and that a press
  at its top grabs the thumb in place.
- **dock**: gutter-carving mirrors `headerIsReservedFromThePaneItBelongsTo`; a
  bar press is never a pane click; a grab survives straying into the neighbour;
  a foreign grab crossing a bar stays quiet; divider beats bar beats pane;
  `1×1` gives bit-identical results to today; at `8×16`, N device positions in
  one cell give N distinct offsets. **Extend `copyPreservesEveryField`
  (`dock.d:1683`)** — it sets every field by hand, so new node fields must be
  added there or they are silently uncovered.
- **hue TUI**: the three existing bar tests keep their event scripts and
  retarget assertions to `dock.scrollOf(pane)` — identical inputs, identical
  outcomes, different owner.
- **hue GUI screenshots** — the only oracle for the px look:

  ```bash
  cd <scratch>   # the path is RELATIVE: raylib's TakeScreenshot prepends CWD
  env HUE_GUI_SCREENSHOT=shot.png HUE_GUI_INSPECT=1 HUE_GUI_TOP=100 \
      xvfb-run -n 91 -s "-screen 0 1400x800x24" \
      /abs/path/apps/hue/build/hue --gui /abs/path/docs/specs/hue/overlays.md
  ```

  **Never `xvfb-run -a`** — auto-selection can land on the real display and
  ambient keystrokes become hue commands. Captures to A/B before/after stages
  2-3-4-6: plain document; `HUE_GUI_TOP=0` and `=999999` (thumb flush at both
  ends in px); a wide fixture (the horizontal bar, most likely to move);
  explorer open; `HUE_GUI_INSPECT=1` (**expected to differ** — glyph column →
  animated rail: reviewed re-baseline, the deliverable photographed); an
  overflowing fence, visible and partly scrolled off; all repeated at
  `HUE_GUI_FONTSIZE=13` and `=31`; and with `HUE_GUI_POINTER` parked on each
  bar — the only way `SCB2`/`SCB3`/`SCB5` become goldens.

- **gallery**: `--render`/`--render-plain` per page; a short-surface render
  pins the nav defect (a selected page must be visible); the catalog sweep
  (`everyPageFitsThePaneWidth`) guards the gutter against breaking layout.
- **Composition (stage 7)**: `AutoScroll.tick` pure tests — dead zone, monotone
  ramp, saturation, zero at a clamped end, axes independent, linear in `dt`.
  Container: a wheel during a live capture still scrolls _and_ emits the
  synthetic drag; a pointer parked in the band scrolls each tick and stops on
  release; `nextTickIn()` is `Duration.max` with no capture. End-to-end proof
  is a hue TUI grid test: press in the body, drag to the last visible row,
  tick, then assert both that the painted rows scrolled and that the selection
  covers the newly revealed lines.

---

## 9. Traps (all hit in this worktree)

- **A cached build hides a broken package.** `dub test :ui-gallery` passed for
  a whole session while `pages/dock_page.d` still imported the pre-move
  `sparkles.ui.dock`. After any module move, force a rebuild.
- **`SPARKLES_TS_GRAMMAR_PATH` goes stale** in a long-lived shell, and
  `nix run .#ci` **inherits it** — a grammar test then fails at a commit whose
  CI was green. Compare `echo $SPARKLES_TS_GRAMMAR_PATH` with
  `nix develop -c bash -c 'echo $SPARKLES_TS_GRAMMAR_PATH'` before believing it.
- **Never read a pipeline's exit code as the runner's** — `… | tail -25`
  reports `tail`'s status, which is always 0.
- **`prek` can roll a commit back**: prettier reformats markdown/tables,
  editorconfig-checker rejects non-multiple-of-4 indentation (including inside
  DDoc). Run `prek run prettier --files <paths>` before committing docs.
- **New files are invisible to nix/flake until `git add`ed** (staged is enough).
- `dip1000` + `-preview=in`: `paintGrid` has its own dispatcher precisely
  because of `scope` — a new optional canvas primitive needs an arm in **two**
  places, not one.
- Commit style: conventional commits with **detailed scopes**; backtick any
  `@`-prefixed token in a message (`` `@safe` `` etc.) or GitHub pings a
  stranger.
