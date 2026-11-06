# Highlighted editing

`sparkles.source_view.editor.highlightedEditorLine(state, line, syntax,
options)` composes source-addressed syntax spans with the shared editor's
decorations for one logical line. `syntax` contains sorted, nonoverlapping
`TextSpan` values with source byte ranges, optional foreground/background and
text styles. It can contain spans from several lines; a viewport index should
pass only intersecting spans when processing large documents.
The overlay advances monotonically through those runs, so token intersection
is linear in the editor segments and syntax runs supplied for the line.

The shared editor supplies the text and decorations. Syntax splits source
spans at token edges and supplies foreground, bold, italic and strike styles.
Selected/protected regions retain their editor slots; syntax background applies
only to ordinary source text. Synthetic carets and composition preedit keep
their own identity and styles and receive no syntax from replaced source text.
Output text owns its bytes through the editor's line-span copies.

Call this only with highlighting for the displayed document revision.
Revision validation, scheduling and fallback to plain edited text belong to
the producer's host. The function does not run a parser or validate that a
stale syntax snapshot refers to current bytes.

`syntaxWindow(source, runs, start, end, theme, pageFg)` resolves only the
requested byte window of sorted `StyledSpan` runs. It locates the first run
with binary search and preserves global byte offsets when clipping edges.

`sparkles.source_view.highlight_session.HighlightSession` supplies a bounded
background producer. `request(text, language, document)` retains an O(1)
persistent-text snapshot; byte copying, grammar setup, parsing and event
flattening run on an event-horizon CPU worker. There is one running job and one
latest request. Superseding a request cancels the previous parser; `poll()`
publishes only the latest completed identity. `snapshot(text, language,
document)` returns a result only for the exact current identity.

The parser and query each have a 100 ms budget. Failed or interrupted work
reports an error and leaves the host free to display plain edited text.
Thread-start/queue failure also reports plain-text fallback; parsing never
moves onto the frame thread. Budgets are initial safety bounds, not measured
editor latency claims. Grammar configuration, source copying and result
flattening are outside those two parser/query budgets.

Keep the session alive through `shutdown()`. The host calls it before dropping
its documents: it cancels queued work, joins the running worker and dispatches
remaining completions while their source snapshots still exist. A stopped
session accepts no further requests.
