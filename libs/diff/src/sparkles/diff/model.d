/// The backend-neutral diff document model (`DVM1`/`DVM2` in
/// `docs/specs/hue/diff-view.md`): files → hunks → rows, each row carrying
/// its side line numbers, an optional similarity pairing to the opposite row
/// of its change block, and intra-line emphasis spans from word refinement.
///
/// The model is a chunk/row stream in the Gerrit/`gr-diff` shape — and it is
/// **`@nogc` by construction** (`DVM8`): a **flat arena** design where every
/// element type is a plain-old-data struct of indices and spans, owned by
/// `SmallBuffer` (the vector-with-SBO, copy-on-write container from
/// `sparkles:base`), the same discipline as `sparkles:ui`'s widget arena.
/// Rows and paths reference text by `Span`; the `DiffDoc` accessors resolve
/// them. The backing texts are **borrowed** (`oldText`/`newText` must outlive
/// the document); path bytes are **owned** (copied into the `paths` arena).
module sparkles.diff.model;

import sparkles.diff.normalize : WhitespaceMode;

import sparkles.base.smallbuffer : SmallBuffer;

/// The kind of one display row.
enum RowKind : ubyte
{
    /// Present on both sides, unchanged.
    context,
    /// Present only on the old side.
    removed,
    /// Present only on the new side.
    added,
}

/// A byte span — into a backing text (row sources), a row's text (emphasis),
/// or the owned `DiffDoc.paths` arena (file paths).
struct Span
{
    size_t start;
    size_t length;

    size_t end() const @safe pure nothrow @nogc => start + length;
}

/// One row of a hunk. Plain data: the text is `src` resolved against the
/// document (`DiffDoc.rowText`), the emphasis spans live in the `emph` arena.
struct Row
{
    RowKind kind;
    /// 1-based line number on the old side; 0 when the row has no old side.
    uint oldLine;
    /// 1-based line number on the new side; 0 when the row has no new side.
    uint newLine;
    /// The row's text (without its trailing newline) as a span into the
    /// backing text of its side: `added` rows span `newText`, the rest span
    /// `oldText` (`DiffDoc.rowText` resolves this).
    Span src;
    /// Index — relative to the row's own hunk (`Hunk.rowsStart`) — of the
    /// opposite row this row is similarity-paired with, or `-1` when
    /// unpaired. A `removed` row pairs with an `added` row of the same
    /// change block and vice versa.
    int pair = -1;
    /// The row's changed segments in the `DiffDoc.emph` arena
    /// (`emphStart .. emphStart + emphCount`); spans are byte ranges into the
    /// row's text. Zero count until refinement runs; a single whole-text span
    /// means "effectively rewritten".
    uint emphStart;
    uint emphCount;
}

/// One hunk: its unified-header coordinates plus its row range in the
/// document's `rows` arena.
struct Hunk
{
    /// 1-based first line of the hunk on each side (0 for an empty side,
    /// matching unified-diff convention).
    uint oldStart;
    uint oldCount;
    uint newStart;
    uint newCount;
    /// The hunk's rows: `DiffDoc.rows[rowsStart .. rowsStart + rowsCount]`.
    uint rowsStart;
    uint rowsCount;
    /// `DVN2`: every changed row in this hunk is formatting (re-padding,
    /// re-indentation, blank-line churn). A verdict, not a policy — the rows
    /// are still here, and renderers dim and fold them rather than dropping
    /// them, so a reviewer can always look. Stamped by
    /// `sparkles.diff.classify.classifyHunks`.
    bool formattingOnly;
}

/// Why an expensive pass was skipped (`DVM6` scale guards). Disclosed
/// in-band by renderers, never silent.
enum Degradation : ubyte
{
    none,
    /// The Myers search exceeded `DiffOptions.maxEditDistance`; the changed
    /// middle was emitted as one remove+add block.
    editDistanceCapped,
    /// The input exceeded `DiffOptions.maxFileBytes`; no diff was computed.
    fileTooLarge,
}

/// One file of the document: path spans into the owned `paths` arena, flags,
/// and its hunk range in the `hunks` arena.
struct FileEntry
{
    Span oldPath;
    Span newPath;
    /// Binary marker (from a parsed patch, or a caller's content sniff);
    /// a binary file carries no hunks.
    bool binary;
    /// `true` when the respective side's last line has no trailing newline.
    bool oldMissingNewline;
    bool newMissingNewline;
    Degradation degraded;
    /// The file's hunks: `DiffDoc.hunks[hunksStart .. hunksStart + hunksCount]`.
    uint hunksStart;
    uint hunksCount;
}

/// A whole diff document: the flat arenas plus the borrowed backing texts.
/// Copies share arena storage copy-on-write; `const` reads never clone.
struct DiffDoc
{
    /// The backing texts rows span. A parsed patch backs both sides with the
    /// patch text itself; a computed diff backs each side with its input.
    /// Borrowed — must outlive the document.
    const(char)[] oldText;
    const(char)[] newText;

    /// Owned path bytes (`FileEntry.oldPath`/`.newPath` span this arena).
    SmallBuffer!char paths;
    SmallBuffer!FileEntry files;
    SmallBuffer!Hunk hunks;
    SmallBuffer!Row rows;
    /// The emphasis-span arena (`Row.emphStart`/`.emphCount`).
    SmallBuffer!Span emph;

@safe pure nothrow @nogc:

    /// The row's text, resolved against its side's backing text.
    const(char)[] rowText(in Row r) const return scope
        => (r.kind == RowKind.added ? newText : oldText)[r.src.start .. r.src.end];

    /// A path span resolved against the owned arena.
    const(char)[] pathText(in Span s) const return scope
        => paths[][s.start .. s.end];

    /// The row's emphasis spans (byte ranges into `rowText(r)`).
    const(Span)[] rowEmph(in Row r) const return scope
        => emph[][r.emphStart .. r.emphStart + r.emphCount];

    /// A file's hunks / a hunk's rows, as `const` slices of the arenas.
    const(Hunk)[] fileHunks(in FileEntry f) const return scope
        => hunks[][f.hunksStart .. f.hunksStart + f.hunksCount];

    /// ditto
    const(Row)[] hunkRows(in Hunk h) const return scope
        => rows[][h.rowsStart .. h.rowsStart + h.rowsCount];

    /// Appends `path` to the owned arena, returning its span.
    Span internPath(scope const(char)[] path)
    {
        const start = paths.length;
        paths ~= path;
        return Span(start, path.length);
    }
}

/// Engine options (`DVM6`: every expensive pass is capped and degrades to
/// the plain line diff rather than hanging).
struct DiffOptions
{
    /// Context lines per hunk (unified-diff `-U`).
    uint context = 3;
    /// Myers search cap: beyond this edit distance the changed middle
    /// degrades to one remove+add block (`Degradation.editDistanceCapped`).
    uint maxEditDistance = 1024;
    /// Per-side input cap; larger inputs are not diffed
    /// (`Degradation.fileTooLarge`).
    size_t maxFileBytes = 8 * 1024 * 1024;
    /// Similarity pairing: per-line char-LCS cap (longer lines are compared
    /// by their first `maxPairLineLength` bytes) and change-block row cap
    /// (larger blocks stay unpaired) — the linematch-style DP guards.
    size_t maxPairLineLength = 400;
    size_t maxBlockRows = 128;
    /// Minimum similarity (0..1) for two lines to pair (delta's
    /// `--max-line-distance 0.6` expressed as a similarity floor).
    double minPairSimilarity = 0.4;
    /// Word refinement: per-row token cap, and the changed-token ratio above
    /// which a pair renders as whole-row emphasis instead of confetti.
    size_t maxRefineTokens = 512;
    double maxRefineChangedRatio = 0.65;
    /// `DVN1`: how much whitespace difference counts as "the same line".
    /// Applied at the line-interning seam, so an ignored difference is never
    /// a change in the model — not a change the renderer hides.
    WhitespaceMode ignoreWhitespace = WhitespaceMode.exact;
    /// Pass toggles.
    bool pairRows = true;
    bool refineWords = true;
    /// `DVN2`: stamp `Hunk.formattingOnly`. Cheap (one pass over the rows
    /// already in cache) and the renderers ignore the flag unless asked, so
    /// it is on by default.
    bool classifyHunks = true;
    /// `DVN4`: refine paired pipe-table rows cell-wise instead of word-wise,
    /// so a re-aligned table lights up only the cells whose content changed.
    bool refineTableCells = true;
}

@("model.Span.end")
@safe pure nothrow @nogc
unittest
{
    assert(Span(3, 4).end == 7);
}

@("model.DiffDoc.accessors")
@safe pure nothrow @nogc
unittest
{
    DiffDoc doc;
    doc.oldText = "hello\nworld\n";
    doc.newText = "hello\nWORLD\n";
    doc.rows ~= Row(RowKind.removed, 2, 0, Span(6, 5));
    doc.rows ~= Row(RowKind.added, 0, 2, Span(6, 5));
    assert(doc.rowText(doc.rows[0]) == "world");
    assert(doc.rowText(doc.rows[1]) == "WORLD");

    const p = doc.internPath("a/x.txt");
    assert(doc.pathText(p) == "a/x.txt");

    doc.emph ~= Span(0, 3);
    doc.rows[0].emphStart = 0;
    doc.rows[0].emphCount = 1;
    assert(doc.rowEmph(doc.rows[0]).length == 1);
    assert(doc.rowEmph(doc.rows[0])[0] == Span(0, 3));
}

@("model.DiffDoc.cow-copies-share")
@safe pure nothrow @nogc
unittest
{
    // The CoW discipline the model relies on: a const copy shares its arena
    // storage without cloning.
    DiffDoc doc;
    foreach (i; 0 .. 64) // spill past the inline capacity
        doc.hunks ~= Hunk(cast(uint)(i + 1), 1, cast(uint)(i + 1), 1);
    const copy = doc;
    assert(copy.hunks.length == 64);
    assert(copy.hunks[3].oldStart == 4);
}
