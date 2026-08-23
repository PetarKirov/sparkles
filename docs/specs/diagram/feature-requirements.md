# `apps/diagram` — Feature Requirements

_**Status:** in progress — Series 1–3 complete (D1.1–D3.3); `GRD` and `SET`
implemented · **Date:** 2026-08-13, updated 2026-08-22 · **Scope:**
`apps/diagram` — architecture (`DIA`), camera (`CAM`), world (`WLD`),
interaction (`IXN`), rendering (`RND`), grid (`GRD`), settings (`SET`). The
grid core is a composable `sparkles:ui` component; diagram hosts it and
`ui-gallery` showcases it._

## Architecture (`DIA`)

| ID   | Requirement                                                                                                                                                                                                                                                                                                             | Status                                                                    | Traces to                             |
| ---- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------- | ------------------------------------- |
| DIA1 | The application depends on `sparkles:ui`, `sparkles:ui-app`, `sparkles:input`, `sparkles:base`, `sparkles:core-cli` and **nothing else** — no `sparkles:ui-tui`, `sparkles:ui-raylib`, `raylib` or `sparkles.tui` import anywhere under `apps/diagram/` ([`APP2`](../ui-app/feature-requirements.md#architecture-app)). | full — deps and imports; re-checked at each gate                          | `apps/diagram/dub.sdl`                |
| DIA2 | The isolation check is a **manual grep**, run at every phase gate and recorded in the PR: `rg -n "ui_tui\|ui_raylib\|sparkles\.tui\|import raylib" apps/diagram/` must find nothing. Deliberately not automated — the decision is recorded in the ui-app plan.                                                          | full — grep is clean through D1.5                                         | PR checklists                         |
| DIA3 | The app enters through **`runApp`** (`HST10`): a component whose `view` supplies the (empty) page tree, whose `handle` feeds `systemInput`, and whose `paint` (`HST13`) replays the frame's op buffer onto `host.canvas` through the toolkit's immediate interpreter — so the board renders identically on both arms.   | full                                                                      | `src/diagram_app.d`                   |
| DIA4 | Two configurations: the default carries the host's `full` closure; a `no-gui` configuration carries `tui` only — proving the app builds and runs where no GPU stack exists.                                                                                                                                             | full                                                                      | `apps/diagram/dub.sdl`                |
| DIA5 | The world's columns and the frame's op buffer are `SmallBuffer`/fixed arrays; labels live in fixed `char[labelCap]` slots — the steady-state frame is `@nogc`, asserted by compiling a frame path under the attribute.                                                                                                  | full                                                                      | `src/world.d`; `src/systems/render.d` |
| DIA6 | Every system is a **free function over `World`** — `Event → World` mutations and `World → ops` renders — so every behavior is a scripted-event or pure-function test against the recording target (`TST1`), and `main` is the only untested line.                                                                       | full — input + render free functions; `main` excluded from the test build | `src/systems/`                        |

## Camera (`CAM`)

| ID   | Requirement                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         | Status | Traces to      |
| ---- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------ | -------------- |
| CAM1 | Magnification is an **exponent and a mantissa**. The exponent is `zoom` — a power of two, in **cells** — and the mantissa is `scalePercent`, how large a cell is **drawn**, in `[100, 200)`% of the target's natural cell. A terminal pins the mantissa at 100 and zooms by octaves, which is all an indivisible cell can express; a window moves the mantissa and carries into the exponent when it leaves the octave, so the same camera reads as continuous zoom there. **The cell mapping never reads the mantissa** — that is what keeps a hit test and a paint in agreement on either target. | full   | `src/camera.d` |
| CAM2 | `worldToScreen`/`screenToWorld` round-trip within a cell at every zoom; `zoomAt(pivot)` (octaves) and `zoomByRatio(pivot)` (a wheel notch or a pinch, applied multiplicatively) both keep the world cell under the pointer stationary; `panBy` is unbounded (an infinite canvas has no edge). The mantissa reaches the screen only where sub-cell resolution exists: `cellPixels` sizes the board's canvas and `pixelToCell` converts the pixel pointer positions `HST18` provides.                                                                                                                 | full   | `src/camera.d` |

| CAM3 | `visibleWorldRect` bounds render culling; `contentBounds` over live entities backs fit-all (`f`) and the minimap's content fit. | full | `src/camera.d` |
| CAM4 | Minimap math — content→panel fit, panel local↔world, camera frustum in panel space — is pure and lives with the camera, tested without any render. | full | `src/camera.d` |
| CAM5 | Camera math is `@safe pure nothrow @nogc`, tested at **runtime** (union-backed vectors have no CTFE field reads — the recorded `sparkles:math` limitation). | full | `src/camera.d` |

## World (`WLD`)

| ID   | Requirement                                                                                                                                                                                       | Status                                                                                    | Traces to     |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------- | ------------- |
| WLD1 | Entities are dense `uint` indices with a free list; components are SoA columns (`bounds`, `zOrder`, `group`, label slot + length) sized by compile-time caps.                                     | full                                                                                      | `src/world.d` |
| WLD2 | Groups are a `group` column (0 = none): grouping stamps a fresh group id on the selection, ungrouping clears it, and a move applies to every member — no nested hierarchy in the MVP.             | full                                                                                      | `src/world.d` |
| WLD3 | Edges are `(from, to)` entity pairs in their own columns; deleting an entity deletes its edges.                                                                                                   | full                                                                                      | `src/world.d` |
| WLD4 | Selection is a capped entity list plus the marquee in progress; all interaction state (tool, drag, menu, label edit, capture/press/hover) lives in `World` so a scripted test inspects one value. | full — the columns, the edges, and every interaction field; the systems consume them next | `src/world.d` |

## Interaction (`IXN`)

| ID   | Requirement                                                                                                                                                                                                                                                                                                                                                                                               | Status                                                               | Traces to                            |
| ---- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------- | ------------------------------------ |
| IXN1 | Pointer routing is layered, topmost first: context menu → toolbar → minimap → board (`screenToWorld`); a capture owner (create, marquee, move, pan, minimap scrub) holds the drag through the toolkit's `CaptureState`.                                                                                                                                                                                   | full — menu topmost, then toolbar/minimap/board + capture owners     | `src/systems/input.d`                |
| IXN2 | Tools: select (`v`), rect-create (`r`), connect (`c`). Create drags a new box; select clicks/Shift-toggles/marquees; connect completes an edge on the second entity click; Esc cancels the pending half.                                                                                                                                                                                                  | full                                                                 | `src/systems/input.d`                |
| IXN3 | Pan is **middle-drag, Space+LMB, and arrows/WASD** — never a held-key-only binding, because a terminal cannot report key releases (`INP16`); every binding works identically on both targets.                                                                                                                                                                                                             | full — hold where releases exist, sticky Space arm where they do not | `src/systems/input.d`                |
| IXN4 | Wheel and pinch zoom toward the pointer via `zoomByRatio` — smooth in a window, octave-stepped in a terminal, one camera either way (see [Zoom is per-target](./index.md#zoom-is-per-target-by-design)); `+`/`-` step from the keyboard and `0` RESETS, which is the only exact magnification a run has (an integer mantissa drifts across a zoom round trip); `m` toggles the minimap; `f` fits content. | full — polish pass in D2.5                                           | `src/systems/input.d`                |
| IXN5 | The context menu (RMB) offers Group, Ungroup, Label…, Connect, Delete; label editing is the toolkit's `LineEditState` over the fixed edit buffer, committed to the entity's label slot on Enter and dismissed on Esc.                                                                                                                                                                                     | full — fixed-slot edit with LineEditState contract                   | `src/systems/input.d`; `src/world.d` |
| IXN6 | Dismissal is a chain: Esc closes the menu, then cancels the pending interaction, then clears the selection, and only then quits; `q` quits directly.                                                                                                                                                                                                                                                      | full — menu → edit → connect → capture → selection → quit            | `src/systems/input.d`                |

## Rendering (`RND`)

| ID   | Requirement                                                                                                                                                                                                                                                                                                                        | Status | Traces to              |
| ---- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------ | ---------------------- |
| RND1 | Three op streams appended in order — board, minimap, chrome — into one reused `SmallBuffer!(DrawOp, N)`; z-order is append order.                                                                                                                                                                                                  | full   | `src/systems/render.d` |
| RND2 | The board culls with `visibleWorldRect`: an off-camera entity emits nothing to the board stream and still appears on the minimap — asserted as a test, not an optimization note.                                                                                                                                                   | full   | `src/systems/render.d` |
| RND3 | Connectors are **orthogonal routes drawn with box-drawing glyphs on both axes** (`─ │ ╭ ╮ ╰ ╯` + arrowheads) — they route through the GPU backend's procedural box drawing, so arms connect across cells on both targets; the canvas `line` primitive is not used for them ([P3 constraints](../ui-app/PLAN.md#phase-3)).          | full   | `src/systems/render.d` |
| RND4 | The grid is zoom-aware and faint; groups outline their members; the marquee and the create preview render from the in-progress drag state. Customizable lattice, stripes, and mark kinds are specified under **`GRD`** — once that lands, the board backdrop is the ui component (`GRD1`/`GRD7`), not a second private grid model. | full   | `src/systems/render.d` |
| RND5 | Colors come from the theme's slots — the app names `Slot`s, never RGB, except where the theme's page colors are the explicit page (`CLI`'s `--theme` works unmodified). Grid stroke and stripe brushes stay on this path (`GRD10`); palette entries may carry per-slot alpha.                                                      | full   | `src/systems/render.d` |

## Grid (`GRD`)

Customizable **background lattice** for infinite-canvas boards: major/minor
lines and stripe bands, line vs dotted-graph-paper marks, stroke styling, and
cyclic X/Y stripe brushes. The **core** is a composable component in
`sparkles:ui` (`libs/ui/src/sparkles/ui/components/`); `apps/diagram` configures
and hosts it on the board stream; `apps/ui-gallery` showcases it without the
diagram ECS.

### Model (shared by component, config file, settings, gallery)

| Concept                             | Values / meaning                                                                                                                                                 |
| ----------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Axis visibility**                 | `none` · `x` · `y` · `xy` — independent per subdivision layer                                                                                                    |
| **Subdivision layers**              | **minor lattice**, **major lattice**, **minor stripes**, **major stripes** — each has visibility + positive **interval** in world cells                          |
| **Lattice mark kind**               | `lines` — continuous axis rules per visibility (MVP `RND4`); `dots` — marks **only at lattice intersections** (classic graph paper)                              |
| **Lattice style** (per minor/major) | mark kind; stroke **slot** (fg + fg alpha); **thickness** (stroke width for `lines`, mark size for `dots`); **dash array** for `lines` only (ignored for `dots`) |
| **Stripe brushes**                  | fixed-cap cyclic arrays for **X** and **Y**; each entry is **transparent** (skip) or a **slot** whose **bg + bg alpha** fills the band                           |
| **Paint order**                     | page background → major then minor **stripes** (X bands under Y bands) → minor then major **lattice** → entities / connectors / chrome (`RND1`)                  |
| **Defaults**                        | match pre-`GRD` `RND4`: zoom-aware minor step, major every 8 minors, `lines`, `Slot.muted` / `Slot.border`, no stripes                                           |

**Named fixtures** (acceptance + gallery presets):

1. **Default (`RND4`)** — `lines`, major interval = 8× minor, faint muted/border, no stripes.
2. **Stripe bands** — `lines` plus cyclic X/Y brushes (e.g. X: transparent then a yellow-tint slot @ ~0.2 bg alpha; Y: red-tint @ 0.2, green-tint @ 0.2, transparent).
3. **Dot paper** — minor `dots` on a regular interval, blue stroke slot, small mark size; optional major `dots` every _N_ (e.g. 4) with a larger mark — procedural graph paper, not an image tile.

| ID    | Requirement                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    | Status | Traces to                                                                                                                                                                                 |
| ----- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| GRD1  | The **core** is a **`sparkles:ui` component** under `libs/ui/src/sparkles/ui/components/` (name TBD, e.g. `grid_backdrop` / `cartesian_grid`): pure **config** + **emit** of `DrawOp`s from `(config, viewport / world→screen mapping, palette)`. Composable with other toolkit components; **no** `apps/diagram` (or host) dependency. Caps keep the emit path `@nogc`-friendly for diagram's steady-state frame (`DIA5`).                                                                    | full   | `libs/ui/src/sparkles/ui/components/grid_backdrop.d`                                                                                                                                      |
| GRD2  | **Subdivisions:** major and minor **lattice** layers and major and minor **stripe** layers. Each layer has `AxisVisibility` (`none` / `x` / `y` / `xy`) and a positive world-cell **interval**. Intervals drive both line spacing and stripe band width; culling still uses `visibleWorldRect` (`CAM3` / `RND2`).                                                                                                                                                                              | full   | `grid_backdrop.d` (`AxisSubdivision`)                                                                                                                                                     |
| GRD3  | **Lattice styling** (minor and major independently): **mark kind** (`lines` \| `dots`), stroke **slot**, **thickness**, and **dash array** (`lines` only; empty = solid). Defaults: `lines`, minor → `Slot.muted`, major → `Slot.border`, hairline-equivalent thickness, solid dash.                                                                                                                                                                                                           | full   | `grid_backdrop.d` (`LatticeStyle`)                                                                                                                                                        |
| GRD4  | **Dotted graph paper** is first-class: `markKind = dots` places marks only at lattice intersections of the layer's intervals (same alignment rules as lines). Thickness is mark size; dash array is ignored. Major and minor may differ (e.g. small dots every step, larger accent dots every 4). Procedural — not a PNG/texture tile.                                                                                                                                                         | full   | `grid_backdrop.d` (`MarkKind.dots`)                                                                                                                                                       |
| GRD5  | **Stripe brushes:** fixed-cap cyclic arrays for the X axis and for the Y axis. An entry is transparent (skip fill) or a theme **slot** (background + bg alpha). Band index advances one step per stripe-layer interval along that axis. X bands paint under Y bands. The stripe-band fixture above is an acceptance case.                                                                                                                                                                      | full   | `grid_backdrop.d` (`StripeBrushes`, `gridPreset`)                                                                                                                                         |
| GRD6  | **TUI/GUI parity:** the same config yields the same lattice/stripe **geometry** and style mapping on both arms (including identical world positions for dots). Backends may map thickness/dash/alpha/marks through honest cell resolution (e.g. TUI dots as a centered glyph), but must not disagree about what is under a world cell. Toolkit gaps (dash arrays, thickness, alpha fills, sub-cell marks) are implementation dependencies of this contract, not a license to GUI-only styling. | full   | `appendGridBackdrop` — one `DrawOp` stream                                                                                                                                                |
| GRD7  | **Diagram host:** the board stream draws the backdrop **only** through the ui component (`GRD1`) — no second private grid model once `GRD` lands. Defaults match pre-`GRD` `RND4`. Lattice/stripes append on the board stream before entities (`RND1` order). Groups, marquee, and create preview stay diagram-local (`RND4`).                                                                                                                                                                 | full   | `apps/diagram/src/systems/render.d`                                                                                                                                                       |
| GRD8  | **Diagram config file:** `--config-file <path>` loads grid config (and any palette slot overrides the file carries) at startup. Invalid file **fails closed** with a clear error — no silent half-apply. Prefer `sparkles:wired` JSON matching the component's config type so gallery, settings, and CLI share one schema.                                                                                                                                                                     | full   | `apps/diagram/src/grid_file.d`; `app.d` (`--config-file`). JSON schema is the component's (`parseGridConfigJson` / `writeGridConfigJson`) so `DIA1` stays closed — no `wired` dependency. |
| GRD9  | **Diagram settings UI:** an in-app settings surface edits the live grid config (visibility, intervals, mark kind, lattice styles, stripe brushes) and the theme **slots** its strokes and brushes name (`SET7` scopes free-colour palette overrides back to the config file), and can persist via the same schema as the config file. Reachable from chrome (menu or toolbar); not a full app-shell redesign.                                                                                  | full   | a modal `PropertyTree` pane over the live config — **`SET`** below; persist is the shared JSON schema (`writeGridConfigJson`)                                                             |
| GRD10 | Grid colors remain theme-slot based (`RND5`): lattice strokes and stripe fills resolve through `resolveSlot` / palette alphas. Settings and config may **override slot color and alpha values**; render code still names slots, never free RGB.                                                                                                                                                                                                                                                | full   | `resolveSlot` in emit; `slotOverrides` in JSON                                                                                                                                            |
| GRD11 | **Gallery showcase:** `apps/ui-gallery` ships a page (or catalog section) that **composes** the grid component, exercises the three named fixtures (default / stripe bands / dot paper), and exposes enough controls to validate subdivisions, mark kinds, and brushes **without** the diagram world or tools.                                                                                                                                                                                 | full   | `apps/ui-gallery/src/pages/grid_page.d`                                                                                                                                                   |

## Settings (`SET`)

The in-app editing surface `GRD9` asked for, built the way the toolkit already
answers this question: a **modal `PropertyTree` pane**
([`PRT1`](../ui/property-tree.md)) over the live board configuration.

What shipped for `GRD9` first was a stand-in and honest about it — four rows,
`1`/`2`/`3`, one named fixture each. Every knob `GRD2`–`GRD5` specifies (an
interval, a mark kind, a stroke slot, a thickness, a dash array, a stripe
brush) was reachable only by writing a JSON file and restarting (`GRD8`). The
property tree closes that gap without `apps/diagram` declaring a single row:
`GridConfig` **is** the schema, so a field added to the component is a row in
the pane, and the pane cannot drift from the thing it edits.

### The modal owns the keyboard, and that is a change

The stand-in took only _first refusal_: it claimed `1`–`3`, the arrows and
Enter, and let everything else fall through, which is how `q` still quit while
it showed. A property tree cannot be layered that way. Its navigation is
`j`/`k`/arrows, its edits are `+`/`-`/Enter, and the board binds `d` to pan,
`u` to ungroup and `q` to quit — a pane that let unbound keys through would
pan the camera underneath the dialog and quit the application from a typo.

So `DiagramScope.settings` is `@terminalScope @hidesLaterScopes`: the shape the
label edit already uses (`IXN5`), and the shape hue's settings scope has
([`SET1`](../hue/config.md#the-settings-pane-set)). While the pane is open the
board's keys are neither resolved nor advertised, so the key guide (`LTN`)
lists the pane's own rows — which it must, since both read one table.

The routing guard that delivers an event to the pane is one `if` at the
component's event seam, exactly as the picker and the settings pane are routed
in hue. What a key _means_ is never an `if`: it is the scope.

### What the pane edits, and what it deliberately does not

The subject is `DiagramSettings` — the live `GridConfig` (`GRD2`–`GRD5`) plus
the board preferences that are already runtime toggles, so an experiment made
with `m` and a value set in the pane are the same setting rather than two.

Palette **slot colour and alpha overrides** stay out. `RND5`/`GRD10` are the
reason: render code names slots and never free RGB, and the pane honours that
by editing the slot _choice_ — `LatticeStyle.stroke` is a `Slot` leaf, so
picking a different one is an ordinary enum edit. Overriding what a slot
_resolves to_ is a palette edit, not a grid edit; it remains the config file's
`slotOverrides` (`GRD8`) until a palette surface is designed for it.

`GridConfig` has no string leaves — every field is a `bool`, an integer, or an
enum — so the pane needs no line editor and the `EDT`/`EDR` gate that holds
back [`PRT13`](../ui/property-tree.md) does not apply here. A string leaf, if
one ever appears, renders read-only with the property view's own marker.

| ID     | Requirement                                                                                                                                                                                                                                                                                              | Status | Traces to                                         |
| ------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------ | ------------------------------------------------- |
| `SET1` | One component (`src/settings_pane.d`) generic over its subject, built from `PropertyTree` + `propertyView` and mounted by the board's own `handle`/`paint` — so `--tui` and `--gui` show the same pane and `DIA1`/`DIA2` still hold: no backend name appears in it.                                      | full   | `src/settings_pane.d`; `src/diagram_app.d`        |
| `SET2` | Modality is the keymap: `DiagramScope.settings` is `@terminalScope @hidesLaterScopes`, so the board's keys neither resolve nor list while the pane shows. Event routing is one guard at the component seam; no key's meaning is decided by an `if`.                                                      | full   | `src/keymap.d`; `src/diagram_app.d`               |
| `SET3` | **Live-apply**: a committed edit mutates the running `World.gridConfig` immediately through the property tree's generated dispatch — range-checked, refusable inline (`PRT21`), undoable (`PRT18`). `v` preview drags collapse to one history entry at the commit boundary (`PRT19`).                    | full   | `src/settings_pane.d`                             |
| `SET4` | The subject is `DiagramSettings`: the live `GridConfig` plus the board preferences that are already runtime toggles (minimap). Named fixtures stay one keystroke away (`1`–`3`) and are applied **through the same dispatch as any edit**, so a preset is undoable rather than a trapdoor.               | full   | `src/settings.d`                                  |
| `SET5` | **Explicit save** (`s`): the subject's grid half persists through `writeGridConfigJson` — the schema `--config-file` reads (`GRD8`) — to that file's path when one was given, else `$XDG_CONFIG_HOME/diagram/grid.json`. A write failure reports in the pane's footer and never escapes as an exception. | full   | `src/grid_file.d`; `src/settings_pane.d`; `app.d` |
| `SET6` | The live fuzzy filter, match navigation, reveal-in-base and transient folding are the property tree's own (`PRT29`–`PRT33`), taking first refusal ahead of the pane's command dispatch.                                                                                                                  | full   | `src/settings_pane.d`                             |
| `SET7` | Palette slot **colour/alpha** overrides are out of scope: the pane edits which `Slot` a stroke or brush names (`RND5`, `GRD10`), and free-colour overrides stay the config file's `slotOverrides`. String leaves render read-only — `GridConfig` has none, so no line editor exists to go stale.         | full   | `src/settings.d`; `GRD8` schema                   |
| `SET8` | `DIA5` is unaffected: `systemRender` stays `@nogc`, and the pane — like the key guide — costs a GC frame only on the frames it actually shows.                                                                                                                                                           | full   | `src/systems/render.d`; `src/diagram_app.d`       |

## Non-goals (MVP)

Save/load of diagrams, undo, freehand drawing, diagonal connectors, continuous
zoom, multi-select handles/resize, edge labels, nested groups.

Grid customization under **`GRD` is in scope** (lines, dots, stripes, config,
settings, gallery). Still out of scope for this slice: image- or texture-tiled
backgrounds, diagonal / isometric / hex lattices, mark kinds beyond `lines` and
`dots`, and per-entity grid overrides.
