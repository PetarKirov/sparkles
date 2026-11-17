# Pointer cells

An application that asks for pixel pointer positions
(`RunConfig.pointerUnit = PointerUnit.pixels`, `HST18`) still lays its widget
tree out in cells. `sparkles.ui_app.pointer_cells` converts each event back.

`pointerCells(host)` reads the host once per event into a `PointerCells`
value:

| Member                    | Meaning                                                                                       |
| ------------------------- | --------------------------------------------------------------------------------------------- |
| `cellWidth`, `cellHeight` | Pixels per cell on the GPU backend (`host.backend == Backend.gui`); 1×1 on any other host     |
| `touch`                   | The pointer cannot hover (`!host.capabilities.hover`): presses are touches                    |
| `slop()`                  | The travel in pixels under which a touch is still a tap: `max(cellWidth, cellHeight) / 4 + 1` |
| `cell(at)`                | The cell holding pixel `at`                                                                   |
| `column(x)`, `row(y)`     | Fractional cell coordinates, for `hitAt` between cell edges                                   |
| `inCells(event)`          | The event with its position in cells                                                          |

Each host fact is optional: a host without `cellWidth`/`cellHeight` reports
cells, one without `backend` is taken at its word, and one without
`capabilities` reports no touch. Non-positive cell sizes clamp to one pixel.

A touch that scrolls is a `TouchPan` (`sparkles.ui.components.scroll_body`):
`begin` on the press, then `track` each later event with the cell height and
the slop. It answers `holding`, `panning`, `tapped` or `cancelled`. An open
command palette uses `PaletteTouch` over it, so a press never runs a row and
a scroll never does; see [command-palette state](../../ui/reference/command-palette.md).
