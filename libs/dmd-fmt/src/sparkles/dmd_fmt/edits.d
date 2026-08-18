/**
Edits, not strings — M5/M6 of the dmd-fmt proposal, per decision D2: the
formatter's output contract is `TextEdit[]`, computed as a minimal line
diff (`sparkles:diff`'s Myers engine) between the original and the
formatted text. Range formatting is D2's format-everything-and-filter
model, and cursor mapping rides the same edits.
*/
module sparkles.dmd_fmt.edits;

import sparkles.dmd_fmt.config : FormatConfig;
import sparkles.dmd_fmt.printer : formatText;

/// One replacement: `[start, end)` byte range of the original becomes
/// `newText`. The LSP `TextEdit` shape, in byte offsets.
struct TextEdit
{
    uint start;
    uint end;
    string newText;
}

/**
The minimal line-level edits turning `original` into `formatted`.

Line-granular by design (a formatter's changes are line-shaped); computed
with Myers via `sparkles:diff`, whose scale cap degrades a pathological
diff to one whole-region edit — still correct, just coarser.
*/
TextEdit[] minimalEdits(const(char)[] original, const(char)[] formatted) @safe
{
    import sparkles.diff.myers : diffLines, splitDiffLines;

    if (original == formatted)
        return null;

    bool missingA, missingB;
    auto oldLines = splitDiffLines(original, missingA);
    auto newLines = splitDiffLines(formatted, missingB);
    const diff = diffLines(original, oldLines, formatted, newLines, 4096);

    // A line's byte range extends to the start of the next line, so runs
    // carry their newlines with them.
    uint oldBound(size_t i) @safe
        => cast(uint) (i < oldLines.length ? oldLines[][i].start : original.length);
    uint newBound(size_t i) @safe
        => cast(uint) (i < newLines.length ? newLines[][i].start : formatted.length);

    TextEdit[] edits;
    size_t oi, ni;
    while (oi < oldLines.length || ni < newLines.length)
    {
        const oldChanged = oi < oldLines.length && diff.oldRemoved[][oi];
        const newChanged = ni < newLines.length && diff.newInserted[][ni];
        if (!oldChanged && !newChanged)
        {
            oi++;
            ni++;
            continue;
        }
        const oStart = oi;
        const nStart = ni;
        while (oi < oldLines.length && diff.oldRemoved[][oi])
            oi++;
        while (ni < newLines.length && diff.newInserted[][ni])
            ni++;
        edits ~= TextEdit(oldBound(oStart), oldBound(oi),
            formatted[newBound(nStart) .. newBound(ni)].idup);
    }
    return edits;
}

/// Apply `edits` (sorted, non-overlapping — [minimalEdits]' shape) to
/// `original`.
string applyEdits(const(char)[] original, const TextEdit[] edits) @safe
{
    import std.array : appender;

    auto sink = appender!string;
    uint cursor;
    foreach (edit; edits)
    {
        sink.put(original[cursor .. edit.start]);
        sink.put(edit.newText);
        cursor = edit.end;
    }
    sink.put(original[cursor .. $]);
    return sink[];
}

/**
Map a byte offset in the original through `edits` to the formatted text —
M6's cursor preservation (`clang-format --cursor`'s contract). An offset
inside a replaced region clamps to the corresponding position within the
replacement.
*/
uint mapCursor(const TextEdit[] edits, uint offset) @safe pure nothrow @nogc
{
    int delta;
    foreach (edit; edits)
    {
        if (offset < edit.start)
            break;
        const oldLen = edit.end - edit.start;
        const newLen = cast(uint) edit.newText.length;
        if (offset < edit.end)
        {
            const into = offset - edit.start;
            return edit.start + delta + (into < newLen ? into : newLen);
        }
        delta += cast(int) newLen - cast(int) oldLen;
    }
    return cast(uint) (cast(int) offset + delta);
}

/// Format and return the edit list (empty = already formatted).
TextEdit[] formatEdits(const(char)[] source,
    FormatConfig cfg = FormatConfig()) @system
    => minimalEdits(source, formatText(source, cfg));

/**
Range formatting, D2's model: format the whole file, keep only the edits
intersecting `[selStart, selEnd)`. Whole-file latency is the budget D3
measures, so the simple model is the affordable one.
*/
TextEdit[] formatRange(const(char)[] source, uint selStart, uint selEnd,
    FormatConfig cfg = FormatConfig()) @system
{
    TextEdit[] kept;
    foreach (edit; formatEdits(source, cfg))
        if (edit.start < selEnd && selStart < edit.end)
            kept ~= edit;
    return kept;
}

/// `--check`'s core: is the source already formatted?
bool checkFormatted(const(char)[] source, FormatConfig cfg = FormatConfig()) @system
    => formatText(source, cfg) == source;

// ---------------------------------------------------------------------------

@("edits.minimal.line-shaped-and-roundtrips")
@system unittest
{
    enum original = "int  a;\nint b;\nint    c;\nint d;\n";
    const formatted = formatText(original);
    const edits = minimalEdits(original, formatted);
    // Only the two mis-spaced lines change; b and d are untouched.
    assert(edits.length == 2);
    assert(applyEdits(original, edits) == formatted);
}

@("edits.identical-input-yields-no-edits")
@system unittest
{
    enum src = "int a;\nint b;\n";
    assert(formatEdits(src).length == 0);
    assert(checkFormatted(src));
    assert(!checkFormatted("int  a;\n"));
}

@("edits.cursor.maps-through-replacements")
@system unittest
{
    // "int  a;\n" -> "int a;\n": one edit, one byte shorter.
    enum original = "int  a;\nint b;\n";
    const formatted = formatText(original);
    const edits = minimalEdits(original, formatted);
    // Offset of 'b' in the original is 12; one byte was removed before it.
    assert(original[12] == 'b');
    assert(formatted[mapCursor(edits, 12)] == 'b');
    // An offset before any edit is unchanged.
    assert(mapCursor(edits, 0) == 0);
}

@("edits.range.filters-to-the-selection")
@system unittest
{
    enum original = "int  a;\nint b;\nint    c;\n";
    // Select only the first line: the c-line's edit must not leak in.
    const first = formatRange(original, 0, 7);
    assert(first.length == 1 && first[0].start < 7);
    const none = formatRange(original, 8, 14); // the already-clean b line
    assert(none.length == 0);
}
