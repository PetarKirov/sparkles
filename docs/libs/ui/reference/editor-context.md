# Editor layout contexts

`sparkles.ui.editor.step.step` and `stepInPlace` accept a context satisfying
`isEditContext`. It supplies time, viewport height, visual-line queries and
clipboard capabilities. `LogicalContext` answers with logical lines and
Unicode cell columns; it needs no font or window.

A layout producer may add two optional queries, each returning
`sparkles.ui.editor.context.CaretTarget`:

| Query                                                   | Meaning                                                                                                      |
| ------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| `horizontalCaret(text, range, direction, extend)`       | The next visual caret, or the nonempty selection's visual left/right collapse edge when not extending        |
| `lineBoundaryCaret(text, position, affinity, boundary)` | The wrapped row's visual left edge for `Boundary.start`, right edge for `Boundary.end`, including an RTL row |

`CaretTarget.position` is a source byte position; `affinity` identifies the side
of an ambiguous visual boundary. The stepper retains that affinity and snaps
endpoints to legal grapheme boundaries. Shift movement retains the existing
logical anchor. The layout query chooses geometry; it does not mutate the
editor, perform an edit or insert an undo transaction.

For example, the Hebrew run in `ab אב` displays Bet followed by Alef from
left to right. Moving visually right from Bet's start (byte 5) reaches Alef's
start (byte 3), with the layout's affinity. In a wholly RTL `אב` row, Home's
visual left edge is logical EOF (byte 4) and End's right edge is byte zero.
The shared motion tests use these worked examples through a fixed layout
context, checking collapse, extension and retained affinity.

The [runnable example](../../../../libs/ui/examples/visual-carets.d) uses a
fixed RTL row and prints `Home byte: 4`, then `End byte: 0`; `LayoutContext`
then derives the same two answers from the bidi layout. The fixed row demonstrates
the generic context boundary; its fixed answers are not a paragraph layout
implementation.

Absent these hooks, character movement/collapse retains logical ordering and
Home retains its logical-line/first-nonblank toggle. Word/document motion and
deletion keep their existing semantics. Queries must answer for the supplied
text revision; an old layout cannot supply offsets for changed source bytes.

Vertical motion adds two optional queries. `caretColumn(text, line, caret)`
measures a goal column with the caret's affinity, and `caretAt(text, line,
column)` returns the nearest caret with the affinity that draws it there.
Vertical motion always finds the head's row with its affinity, so a caret at
a soft wrap moves from the row it is drawn on.

## The cell-grid layout context

`sparkles.ui.editor.layout.LayoutContext` implements every query from one
`ParagraphLayout` per logical line. Base supplies the paragraph's bidi levels
(UAX #9), line opportunities (UAX #14), grapheme boundaries and cluster
widths. The layout wraps greedily at `LayoutOptions.wrapCells`, lets white
space hang past a row's end, and orders each row's clusters by its L1 levels.
A lone mirrored scalar in a right-to-left run records its L4 mirror.

| Query               | Answer                                                                                                                                                                    |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `lineAt`            | The visual row holding the caret; at a soft wrap, `before` is the earlier row's end                                                                                       |
| `horizontalCaret`   | Crosses the visually adjacent cluster; past a row's edge, the paragraph's next row in reading order, then the next line (Right) or previous line (Left) in document order |
| `lineBoundaryCaret` | The row's visual left/right edge; a row without RTL text keeps the first-nonblank Home toggle                                                                             |
| `caretAt`           | The caret stop nearest a cell column, attached to the row it lies on; at a bidi stop, the clicked cluster's side                                                          |
| `caretArea`         | Cells and visual rows from `originLine`/`originRow`, for input-method placement                                                                                           |

A view draws the same rows with `visualRows`
(`sparkles.ui.components.editor`), which projects a line's logical spans onto
the layout. Clusters keep their span's styling, and carets or a preedit are
drawn at the caret stop for their range's affinity. `layoutColumn` removes
those inserted cells from a pointer column before `caretAt` resolves it.
Drawing, hit-testing and motion therefore share one layout for a given text
and wrap width. The context caches four paragraphs, keyed by byte-equal
text and options.

`EditorFieldOf!LayoutContext` is a field over this context; `EditorField`
remains `EditorFieldOf!LogicalContext` for single-line and unwrapped fields.
The Sparkles editor application uses the layout context for documents.

The context works on the toolkit's cell grid. Proportional shaped flow,
joining across separately drawn clusters and ligature carets belong to
`sparkles:text-layout` and the renderer. Live IME, touch selection handles
and device font acceptance remain separate delivery work.
