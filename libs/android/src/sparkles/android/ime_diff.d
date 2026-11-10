/**
The diff behind $(MREF sparkles,android,ime): what an input method did to a
field that held only a run of $(LREF sentinel) characters with the cursor in
its middle. Pure, and compiled on every host, so it is tested where the rest
of the package cannot run.
*/
module sparkles.android.ime_diff;

/// What the field holds between polls: a private-use character, so no
/// keyboard types it and a deletion is never mistaken for a keystroke.
enum wchar sentinel = '';

/// How many $(LREF sentinel)s the field is reset to: more backspaces than a
/// held key repeats between two frames, on either side of the cursor.
enum int sentinelLength = 16;

/**
Where the cursor rests in the run: its middle, so the field always has text
on both sides. An input method asks the field where its cursor is, and moves
nowhere the field says there is nothing — with the cursor at the run's end,
Gboard's Right, Down and End did nothing.
*/
enum int sentinelCaret = sentinelLength / 2;

/// What the IME did to the sentinel run since the last reset.
struct FieldEdit
{
    size_t deleted; /// characters removed (backspaces)
    const(wchar)[] inserted; /// text committed, UTF-16
}

/// `true` when `text` is exactly the untouched run.
bool isSentinelRun(const(wchar)[] text) @safe pure nothrow @nogc
{
    if (text.length != sentinelLength)
        return false;
    foreach (c; text)
        if (c != sentinel)
            return false;
    return true;
}

/**
The edit that turns the sentinel run into `text`: the common prefix and
suffix are untouched, whatever lies between was deleted and replaced. A
cursor the IME moved into the run (a space-bar swipe) still diffs to what was
typed there.
*/
FieldEdit diff(const(wchar)[] text) @safe pure nothrow @nogc
{
    size_t prefix;
    while (prefix < text.length && prefix < sentinelLength && text[prefix] == sentinel)
        ++prefix;
    size_t suffix;
    while (suffix < text.length - prefix && suffix < sentinelLength - prefix
        && text[$ - 1 - suffix] == sentinel)
        ++suffix;
    return FieldEdit(sentinelLength - prefix - suffix, text[prefix .. $ - suffix]);
}

///
@("ime_diff.diff")
@safe pure unittest
{
    static immutable wchar[sentinelLength] run = sentinel;
    enum c = sentinelCaret;

    assert(isSentinelRun(run[]));
    assert(!isSentinelRun(run[0 .. $ - 1]));
    assert(diff(run[0 .. c] ~ "a"w ~ run[c .. $]) == FieldEdit(0, "a"w));
    assert(diff(run[0 .. $ - 1]) == FieldEdit(1, ""w));
    assert(diff(run[0 .. $ - 3]) == FieldEdit(3, ""w));
    assert(diff(run[0 .. c - 1] ~ "©"w ~ run[c .. $]) == FieldEdit(1, "©"w));
    // Typed elsewhere, after a cursor move.
    assert(diff(run[0 .. 3] ~ "xy"w ~ run[3 .. $]) == FieldEdit(0, "xy"w));
    // Everything deleted, then typed.
    assert(diff("hi"w) == FieldEdit(sentinelLength, "hi"w));
}

/// A move the IME made by selecting in the field rather than by a key.
enum FieldMoveKind : ubyte
{
    none,
    left,        /// the cursor moved back `count` characters
    right,       /// ... forward
    home,        /// to the field's start
    end,         /// to its end
    selectAll,   /// everything selected
    selectLeft,  /// a selection grown back from the cursor, `count` long
    selectRight, /// ... forward
}

/// ditto
struct FieldMove
{
    FieldMoveKind kind; ///
    int count;          /// characters, for the moves that have a length
}

/**
What a selection of `start .. end` in the untouched run means, the cursor
having rested at $(LREF sentinelCaret): a move an input method made through
`setSelection` or a context-menu action (Select All), not a key event. A
negative position (no selection) is no move.
*/
FieldMove moveOf(int start, int end) @safe pure nothrow @nogc
{
    if (start > end)
    {
        const t = start;
        start = end;
        end = t;
    }
    if (start < 0 || end > sentinelLength)
        return FieldMove.init;
    if (start == end)
    {
        if (start == sentinelCaret)
            return FieldMove.init;
        if (start == 0)
            return FieldMove(FieldMoveKind.home, 1);
        if (start == sentinelLength)
            return FieldMove(FieldMoveKind.end, 1);
        return start < sentinelCaret ? FieldMove(FieldMoveKind.left, sentinelCaret - start)
            : FieldMove(FieldMoveKind.right, start - sentinelCaret);
    }
    if (start == 0 && end == sentinelLength)
        return FieldMove(FieldMoveKind.selectAll, 1);
    return start < sentinelCaret ? FieldMove(FieldMoveKind.selectLeft, sentinelCaret - start)
        : FieldMove(FieldMoveKind.selectRight, end - sentinelCaret);
}

///
@("ime_diff.moveOf")
@safe pure nothrow @nogc unittest
{
    enum c = sentinelCaret;
    assert(moveOf(c, c) == FieldMove.init, "a cursor at rest moved nowhere");
    assert(moveOf(-1, -1) == FieldMove.init);
    assert(moveOf(c - 2, c - 2) == FieldMove(FieldMoveKind.left, 2));
    assert(moveOf(c + 1, c + 1) == FieldMove(FieldMoveKind.right, 1));
    assert(moveOf(0, 0) == FieldMove(FieldMoveKind.home, 1));
    assert(moveOf(sentinelLength, sentinelLength) == FieldMove(FieldMoveKind.end, 1));
    assert(moveOf(0, sentinelLength) == FieldMove(FieldMoveKind.selectAll, 1));
    assert(moveOf(c, c - 3) == FieldMove(FieldMoveKind.selectLeft, 3));
    assert(moveOf(c, c + 2) == FieldMove(FieldMoveKind.selectRight, 2));
}
