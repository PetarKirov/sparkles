/**
The diff behind $(MREF sparkles,android,ime): what an input method did to a
field that held only a run of $(LREF sentinel) characters. Pure, and compiled
on every host, so it is tested where the rest of the package cannot run.
*/
module sparkles.android.ime_diff;

/// What the field holds between polls: a private-use character, so no
/// keyboard types it and a deletion is never mistaken for a keystroke.
enum wchar sentinel = '\uE000';

/// How many $(LREF sentinel)s the field is reset to: more backspaces than a
/// held key repeats between two frames.
enum int sentinelLength = 8;

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

    assert(isSentinelRun(run[]));
    assert(!isSentinelRun(run[0 .. 7]));
    assert(diff(run[] ~ "a"w) == FieldEdit(0, "a"w));
    assert(diff(run[0 .. 7]) == FieldEdit(1, ""w));
    assert(diff(run[0 .. 5]) == FieldEdit(3, ""w));
    assert(diff(run[0 .. 7] ~ "©"w) == FieldEdit(1, "©"w));
    // Typed in the middle, after a cursor move.
    assert(diff(run[0 .. 3] ~ "xy"w ~ run[3 .. 8]) == FieldEdit(0, "xy"w));
    // Everything deleted, then typed.
    assert(diff("hi"w) == FieldEdit(8, "hi"w));
}
