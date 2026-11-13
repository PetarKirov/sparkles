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
fixed RTL row and prints `Home byte: 4`, then `End byte: 0`. It demonstrates
the generic context boundary; its fixed answers are not a paragraph layout
implementation.

Absent these hooks, character movement/collapse retains logical ordering and
Home retains its logical-line/first-nonblank toggle. Word/document motion and
deletion keep their existing semantics. Queries must answer for the supplied
text revision; an old layout cannot supply offsets for changed source bytes.

These hooks establish the generic stepper boundary. `EditorField` currently
embeds `LogicalContext`; a production layout-backed field, shared rendering/hit
geometry and live IME integration remain separate delivery work. The hooks
alone do not establish rendered bidi or wrapping support.
