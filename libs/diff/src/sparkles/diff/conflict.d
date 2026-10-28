/**
Merge conflicts read back from a conflict-markered file (`CFV1`).

git leaves an unresolved merge as one file with the sides interleaved
between markers. This reads that file back into a model of plain regions
and conflicts, each conflict holding its _ours_, _base_ (with the `diff3`
and `zdiff3` styles) and _theirs_ texts and their labels, as Mergiraf's
`ParsedMerge` does. Each side of the whole file follows by joining the plain
regions with that side's part of every conflict.

`@nogc` like the rest of the engine (`DVM8`): the regions are spans into the
borrowed file text, in a `SharedBuffer`.

$(DL
    $(DT `merge`)  $(DD `<<<<<<< ours`, ours, `=======`, theirs, `>>>>>>> theirs`)
    $(DT `diff3`)  $(DD as `merge`, with `||||||| base` and the base before `=======`)
    $(DT `zdiff3`) $(DD as `diff3`, with the lines both sides share moved out of the conflict)
)

A marker is seven of its character at the start of a line, then a space and
its label or the end of the line, as git writes them; a rebase's labels name
commits (`<<<<<<< HEAD`, `>>>>>>> 1a2b3c4 (subject)`).
*/
module sparkles.diff.conflict;

import sparkles.base.buffer : SharedBuffer;
import sparkles.diff.model : Span;

/// What one region of a conflicted file is.
enum RegionKind : ubyte
{
    /// Text both sides agree on.
    plain,
    /// An unresolved conflict.
    conflict,
}

/// One region: a run of plain text, or one conflict and its sides.
struct ConflictRegion
{
    RegionKind kind;
    /// The whole region in the file, markers included for a conflict.
    Span whole;
    /// A conflict's sides: ours, the base when the style records it, theirs.
    Span ours, base, theirs;
    /// ditto
    bool hasBase;
    /// The markers' labels.
    Span oursLabel, baseLabel, theirsLabel;
    /// The 1-based line of the region's first line in the file.
    uint line;
}

/// Why a file could not be read back.
enum ConflictError : ubyte
{
    none,
    /// A `<<<<<<<` with no `=======` or no `>>>>>>>` after it.
    unterminated,
}

/// A conflicted file's regions (`CFV1`).
struct ConflictDoc
{
    /// The file, borrowed.
    const(char)[] text;
    SharedBuffer!(ConflictRegion, 8) regions;
    ConflictError error;

@safe pure nothrow @nogc:

    /// How many conflicts remain.
    size_t conflicts() const scope
    {
        size_t n;
        foreach (ref r; regions[])
            n += r.kind == RegionKind.conflict;
        return n;
    }

    /// The text `s` names in the file.
    const(char)[] slice(in Span s) const return scope => text[s.start .. s.end];
}

/// Which side of a conflict, for `sideText`.
enum ConflictSide : ubyte
{
    ours,
    base,
    theirs,
}

private enum markerLength = 7;

/// `line` is a marker of `c`: seven of it, then a space or the line's end.
private bool isMarker(scope const(char)[] line, char c) @safe pure nothrow @nogc
{
    if (line.length < markerLength)
        return false;
    foreach (ch; line[0 .. markerLength])
        if (ch != c)
            return false;
    return line.length == markerLength || line[markerLength] == ' '
        || line[markerLength] == '\r';
}

/// The label after a marker line's run of seven, without the space or the
/// line break.
private Span labelOf(size_t lineStart, scope const(char)[] line) @safe pure nothrow @nogc
{
    size_t end = line.length;
    while (end > markerLength && (line[end - 1] == '\r'))
        --end;
    const start = end > markerLength + 1 ? markerLength + 1 : end;
    return Span(lineStart + start, end - start);
}

/// Reads `text`, a conflict-markered file, into its regions (`CFV1`).
ConflictDoc parseConflicts(return scope const(char)[] text) @safe pure nothrow @nogc
{
    ConflictDoc doc;
    doc.text = text;

    enum State : ubyte { plain, ours, base, theirs }
    State state;
    ConflictRegion pending;
    size_t plainStart;
    uint plainLine = 1;
    size_t sideStart;
    uint lineNo = 1;

    void closePlain(size_t at)
    {
        if (at > plainStart)
            doc.regions.put(ConflictRegion(RegionKind.plain,
                whole: Span(plainStart, at - plainStart), line: plainLine));
    }

    size_t pos;
    while (pos < text.length)
    {
        size_t end = pos;
        while (end < text.length && text[end] != '\n')
            ++end;
        const next = end < text.length ? end + 1 : end;
        const line = text[pos .. end];

        final switch (state)
        {
            case State.plain:
                if (isMarker(line, '<'))
                {
                    closePlain(pos);
                    pending = ConflictRegion(RegionKind.conflict, line: lineNo);
                    pending.whole.start = pos;
                    pending.oursLabel = labelOf(pos, line);
                    sideStart = next;
                    state = State.ours;
                }
                break;
            case State.ours:
                if (isMarker(line, '|'))
                {
                    pending.ours = Span(sideStart, pos - sideStart);
                    pending.hasBase = true;
                    pending.baseLabel = labelOf(pos, line);
                    sideStart = next;
                    state = State.base;
                }
                else if (isMarker(line, '='))
                {
                    pending.ours = Span(sideStart, pos - sideStart);
                    sideStart = next;
                    state = State.theirs;
                }
                break;
            case State.base:
                if (isMarker(line, '='))
                {
                    pending.base = Span(sideStart, pos - sideStart);
                    sideStart = next;
                    state = State.theirs;
                }
                break;
            case State.theirs:
                if (isMarker(line, '>'))
                {
                    pending.theirs = Span(sideStart, pos - sideStart);
                    pending.theirsLabel = labelOf(pos, line);
                    pending.whole.length = next - pending.whole.start;
                    doc.regions.put(pending);
                    plainStart = next;
                    plainLine = lineNo + 1;
                    state = State.plain;
                }
                break;
        }
        pos = next;
        ++lineNo;
    }
    if (state != State.plain)
        doc.error = ConflictError.unterminated;
    else
        closePlain(text.length);
    return doc;
}

/**
One side of the whole file: the plain regions joined with `side`'s part of
every conflict, into `w`. The base of a conflict whose style recorded none
is its ours, the closest thing to "before" a `merge`-style file keeps.
*/
void writeSide(Writer)(const ref ConflictDoc doc, ConflictSide side, ref Writer w)
{
    import std.range.primitives : put;

    foreach (ref r; doc.regions[])
    {
        if (r.kind == RegionKind.plain)
        {
            put(w, doc.slice(r.whole));
            continue;
        }
        final switch (side)
        {
            case ConflictSide.ours: put(w, doc.slice(r.ours)); break;
            case ConflictSide.base: put(w, doc.slice(r.hasBase ? r.base : r.ours)); break;
            case ConflictSide.theirs: put(w, doc.slice(r.theirs)); break;
        }
    }
}

@("conflict.parseConflicts.mergeStyle")
@safe pure nothrow @nogc
unittest
{
    enum text = "a\n<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> feature\nz\n";
    const doc = parseConflicts(text);
    assert(doc.error == ConflictError.none && doc.regions.length == 3 && doc.conflicts == 1);
    const c = doc.regions[1];
    assert(c.kind == RegionKind.conflict && !c.hasBase && c.line == 2);
    assert(doc.slice(c.ours) == "ours\n" && doc.slice(c.theirs) == "theirs\n");
    assert(doc.slice(c.oursLabel) == "HEAD" && doc.slice(c.theirsLabel) == "feature");
    assert(doc.slice(doc.regions[0].whole) == "a\n" && doc.slice(doc.regions[2].whole) == "z\n");
    assert(doc.regions[2].line == 7);
}

@("conflict.parseConflicts.diff3AndRebaseLabels")
@safe pure nothrow @nogc
unittest
{
    enum text = "<<<<<<< HEAD\nx = 1;\n||||||| parent of 1a2b3c4 (fix)\nx = 0;\n"
        ~ "=======\nx = 2;\n>>>>>>> 1a2b3c4 (fix)\n";
    const doc = parseConflicts(text);
    assert(doc.regions.length == 1);
    const c = doc.regions[0];
    assert(c.hasBase && doc.slice(c.base) == "x = 0;\n");
    assert(doc.slice(c.baseLabel) == "parent of 1a2b3c4 (fix)");
    assert(doc.slice(c.theirsLabel) == "1a2b3c4 (fix)");
}

@("conflict.parseConflicts.sidesJoinBack")
@safe pure nothrow
unittest
{
    import std.array : appender;

    enum text = "a\n<<<<<<< ours\nb\n||||||| base\nB\n=======\nc\n>>>>>>> theirs\nd\n";
    const doc = parseConflicts(text);
    auto ours = appender!string, base = appender!string, theirs = appender!string;
    writeSide(doc, ConflictSide.ours, ours);
    writeSide(doc, ConflictSide.base, base);
    writeSide(doc, ConflictSide.theirs, theirs);
    assert(ours[] == "a\nb\nd\n" && base[] == "a\nB\nd\n" && theirs[] == "a\nc\nd\n");
}

@("conflict.parseConflicts.unterminatedAndLookalikes")
@safe pure nothrow @nogc
unittest
{
    assert(parseConflicts("<<<<<<< HEAD\nx\n").error == ConflictError.unterminated);
    // Eight `<` or a marker inside a line is text, not a marker.
    const doc = parseConflicts("<<<<<<<< not\n a <<<<<<< b\n");
    assert(doc.error == ConflictError.none && doc.conflicts == 0);
}
