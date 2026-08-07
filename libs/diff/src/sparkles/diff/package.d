/// `sparkles:diff` — the text diff engine behind hue's diff & PR viewer
/// (`docs/specs/hue/diff-view.md` `DVM*`): a backend-neutral diff document
/// model, Myers line diff with scale guards, similarity alignment pairing,
/// word-level refinement, and a unified-patch parser/emitter.
///
/// The whole library is `@safe pure nothrow @nogc` (`DVM8`): the model is a
/// flat arena of plain-data rows/hunks/files owned by `SmallBuffer` (the
/// vector-with-SBO, copy-on-write container from `sparkles:base`), texts are
/// borrowed spans, and the emitter writes to caller-supplied output ranges.
///
/// Tests live in the feature modules (the runner does not discover
/// `package.d` unittests); this module only re-exports the public surface.
module sparkles.diff;

public import sparkles.diff.classify : classifyHunks, formattingOnlyCount,
    isFormattingOnly;
public import sparkles.diff.engine : diffText;
public import sparkles.diff.model : Degradation, DiffDoc, DiffOptions, FileEntry,
    Hunk, Row, RowKind, Span;
public import sparkles.diff.normalize : compareLines, isBlank, linesEqual,
    WhitespaceMode;
public import sparkles.diff.patch : emitPatch, parsePatch;
public import sparkles.diff.refine : refinePairTokens,
    refineTokenize = tokenize, RefineToken = Token;
public import sparkles.diff.table : cellsEqual, cellSpans, isSeparatorRow,
    isTableRow, rowsEquivalent;
