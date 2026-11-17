# Editor surface components

The pieces an editing surface builds around an `EditorField`: hits and
drag selection over the rows it painted, and the find bar. Each takes the
field or the state it acts on and the hit identities its caller assigns;
none owns commands or a theme.

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
`editor.view.paintedRows.caretCell` do exactly this. The host keeps
`painted` with the frames it lays out. On a press it checks
`answersFor`, then asks `caretAtPoint(…, exact: true)` and calls
`drag.press` and `drag.moveTo`; on a drag, `caretAtPoint(…, exact: false)`
and `drag.moveTo`; on release, `drag.release`.

## The find bar

The state is `sparkles.ui.editor.search.FindBar` (ui spec `EDS7`); the
view is `sparkles.ui.components.find_bar`.

| Symbol                                                    | Meaning                                                                                                 |
| --------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| `FindOption`                                              | The switches: `regex`, `caseSensitive`, `wholeWord`                                                     |
| `FindBar.show(replace, seed, target)`                     | Open the bar (with the replacement field when `replace`), seeding the query; changes `epoch`            |
| `FindBar.close()`, `toggle(option)`, `focused()`          | Hide it keeping its fields; flip a switch; the field holding the keyboard                               |
| `FindBar.refresh(text, document, budget)`                 | Recompute `result` and `pattern` when the text, document, query or a switch changed                     |
| `FindBar.summary(start, end)`, `ordinalAt(position)`      | `2 of 5`, `5 matches`, `No results` or the pattern's error; the 1-based match at or after a position    |
| `FindBarHits`                                             | The hit identity of each control: previous, next, close, replace one, replace all, the switches, fields |
| `viewFindBar(b, bar, selectionStart, selectionEnd, opts)` | The bar as one column node: the query row and, when replacing, the replacement row                      |
| `findBarRows(bar)`                                        | The rows the view takes: one, two when replacing                                                        |

The host routes keys to `bar.focused` while the bar is open, refreshes it
before each frame and maps the hits it assigned to its own commands, which
call `selectNextMatch`, `replaceCurrent`, `replaceAll` or
`selectAllMatches` with `bar.pattern`.
