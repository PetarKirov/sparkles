# Highlighted editing

`sparkles.source_view.editor.highlightedEditorLine(state, line, syntax,
options)` composes source-addressed syntax spans with the shared editor's
decorations for one logical line. `syntax` contains sorted, nonoverlapping
`TextSpan` values with source byte ranges, optional foreground/background and
text styles. It can contain spans from several lines; a viewport index should
pass only intersecting spans when processing large documents.

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
