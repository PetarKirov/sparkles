# Editor surface components

The pieces an editing surface builds around an `EditorField`: hits and
drag selection over the rows it painted. Each takes the field or the
state it acts on and the hit identities its caller assigns; none owns
commands or a theme.

## Painted rows and pointer hits

`sparkles.ui.components.editor`:

| Symbol                                                              | Meaning                                                                                                     |
| ------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| `PaintedRow`                                                        | One drawn row: its tree node, logical line, layout row, inserted cells and the host cursor's column         |
| `PaintedRows.of(source, wrapCells)`                                 | An empty ledger for the text and wrap width the view lays out                                               |
| `PaintedRows.add(node, line, row)`                                  | Record a `VisualRow` drawn as tree node `node`                                                              |
| `PaintedRows.answersFor(text, wrapCells)`                           | Whether the rows still describe `text` at that width; a hit on an older revision must be dropped            |
| `PaintedRows.rowAt(frames, point, exact)`                           | The nearest row by its band; `exact` requires the point on one (a press), otherwise the nearest (a drag)    |
| `PaintedRows.caretAtPoint(context, text, frames, point, exact, at)` | The `CaretTarget` under the point: the row's drawn column less inserted cells, then `LayoutContext.caretAt` |
| `PaintedRows.caretCell(frames, area)`                               | The host cursor's cell `[x, y, 1, 1]`, for the input method's area (`textInputArea`)                        |
| `DragSelection.press(state, at, extend)`                            | Fix the anchor at `at`, or keep the primary's anchor when `extend` (Shift)                                  |
| `DragSelection.moveTo(field, at, now)`                              | Select from the anchor to `at`, keeping `at`'s affinity at a soft wrap or bidi boundary                     |
| `DragSelection.release()`                                           | End the drag; later moves change nothing                                                                    |
| `layoutColumn(row, inserted, layout, column)`                       | The layout column under a drawn column, for a row recorded without its spans                                |

A view starts a ledger with `PaintedRows.of(field.state.text,
field.context.options.wrapCells)` and, for each `VisualRow` it draws as a
`rich` node (with `caretColumn: row.caretColumn` for the host's cursor),
calls `painted.add(node, line, row)`. The editor app's document view and
the tests `editor.view.paintedRows.caretAtPoint`,
`editor.view.paintedRows.bidi`, `editor.view.dragSelection` and
`editor.view.paintedRows.caretCell` do exactly this. The host keeps `painted` with the frames it lays out. On a press it checks
`answersFor`, then asks `caretAtPoint(…, exact: true)` and calls
`drag.press` and `drag.moveTo`; on a drag, `caretAtPoint(…, exact: false)`
and `drag.moveTo`; on release, `drag.release`.
