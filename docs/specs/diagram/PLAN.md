# `apps/diagram` — delivery plan

_Audience: contributors. Execution-only; IDs refer to the
[feature requirements](./feature-requirements.md). Parent phase:
[ui-app PLAN, phase 3](../ui-app/PLAN.md#phase-3)._

Two commit series, stacked (`gh stack`), each commit green on its own.

## Series 1 — the MVP board

| Step | Deliverable                                                                                                                              | IDs                    |
| ---- | ----------------------------------------------------------------------------------------------------------------------------------------- | ---------------------- |
| D1.1 | Scaffold: `apps/diagram` + root `subPackage`, both configurations, `runApp` component that clears to the theme page and quits on `q`/Esc | `DIA1`–`DIA4`          |
| D1.2 | `camera.d` + the full pure test table (round-trips, pivot-stable zoom, unbounded pan, culling rects, minimap math)                       | `CAM1`–`CAM5`          |
| D1.3 | `world.d`: columns, spawn/free free-list, groups, edges; unit tests                                                                       | `WLD1`–`WLD4`          |
| D1.4 | `systemInput`: create/select/marquee/move/pan/zoom/minimap scrub, capture owners; scripted-event tests via `runAppRecorded`               | `IXN1`–`IXN4`          |
| D1.5 | Render systems: board (grid, nodes, marquee) + minimap + status chrome into one op buffer; cull test; `@nogc` frame assertion             | `RND1`, `RND2`, `RND4`, `RND5`, `DIA5` |

Gate: both configurations build; the scripted session suite passes headlessly;
the isolation grep (`DIA2`) finds nothing; a manual GUI + TUI smoke run.

## Series 2 — menus, structure, connectors

| Step | Deliverable                                                                                   | IDs            |
| ---- | ---------------------------------------------------------------------------------------------- | -------------- |
| D2.1 | Context menu + dismissal chain; Delete                                                        | `IXN5`, `IXN6` |
| D2.2 | Group / ungroup, group-aware move and outlines                                                | `WLD2`         |
| D2.3 | Labels: `LineEditState` edit, commit/dismiss, render                                          | `IXN5`         |
| D2.4 | Connectors: connect tool + orthogonal box-drawing routes with arrowheads; edge delete cascade | `IXN2`, `WLD3`, `RND3` |
| D2.5 | Fit-all + minimap toggle polish; final scripted-session sweep                                 | `IXN4`         |

Gate: the full [UX table](./feature-requirements.md#interaction-ixn) exercised
by scripted tests where expressible and by the manual pass where not; isolation
grep again; `dub test :diagram` green on ldc2 and dmd.

## Verification

```bash
dub test :diagram
dub build :diagram && dub build :diagram -c no-gui
dub run :diagram -- --tui
dub run :diagram -- --gui --window-width 120 --window-height 40
rg -n "ui_tui|ui_raylib|sparkles\.tui|import raylib" apps/diagram/   # no matches
```
