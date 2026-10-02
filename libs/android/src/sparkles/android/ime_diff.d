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

/**
Split UTF-16 into code points, calling `sink` for each; an unpaired surrogate
is passed through as itself (the IME's text is not ours to reject).
*/
void eachCodePoint(Sink)(const(wchar)[] units, scope Sink sink)
{
    while (units.length)
    {
        dchar c = units[0];
        size_t n = 1;
        if (c >= 0xD800 && c <= 0xDBFF && units.length > 1
            && units[1] >= 0xDC00 && units[1] <= 0xDFFF)
        {
            c = 0x10000 + ((c - 0xD800) << 10) + (units[1] - 0xDC00);
            n = 2;
        }
        units = units[n .. $];
        sink(c);
    }
}

///
@("ime_diff.eachCodePoint")
@safe pure nothrow @nogc unittest
{
    dchar[4] got;
    size_t n;
    eachCodePoint("a©\U0001F600"w, (dchar c) { got[n++] = c; });
    assert(n == 3 && got[0] == 'a' && got[1] == '©' && got[2] == '\U0001F600');
}

/**
Encode UTF-16 `units` as UTF-8 into `dst` and return the bytes written; an
unpaired surrogate becomes U+FFFD. Stops before the first code point that
does not fit whole, so `dst` never ends inside one. `@nogc`, for text read
on a thread D does not run ($(MREF sparkles,android,autofill)).
*/
size_t toUtf8(const(wchar)[] units, char[] dst) @safe pure nothrow @nogc
{
    size_t n;
    bool full;
    eachCodePoint(units, (dchar c) {
        if (full)
            return;
        if (c >= 0xD800 && c <= 0xDFFF)
            c = '�';
        char[4] b;
        size_t len;
        if (c < 0x80)
            b[len++] = cast(char) c;
        else if (c < 0x800)
        {
            b[len++] = cast(char)(0xC0 | (c >> 6));
            b[len++] = cast(char)(0x80 | (c & 0x3F));
        }
        else if (c < 0x10000)
        {
            b[len++] = cast(char)(0xE0 | (c >> 12));
            b[len++] = cast(char)(0x80 | ((c >> 6) & 0x3F));
            b[len++] = cast(char)(0x80 | (c & 0x3F));
        }
        else
        {
            b[len++] = cast(char)(0xF0 | (c >> 18));
            b[len++] = cast(char)(0x80 | ((c >> 12) & 0x3F));
            b[len++] = cast(char)(0x80 | ((c >> 6) & 0x3F));
            b[len++] = cast(char)(0x80 | (c & 0x3F));
        }
        if (n + len > dst.length)
        {
            full = true;
            return;
        }
        dst[n .. n + len] = b[0 .. len];
        n += len;
    });
    return n;
}

///
@("ime_diff.toUtf8")
@safe pure nothrow @nogc unittest
{
    char[16] buf;
    assert(buf[0 .. toUtf8("pa©\U0001F600"w, buf[])] == "pa©\U0001F600");
    // An unpaired surrogate is replaced, not passed through.
    static immutable wchar[2] lone = ['x', 0xD800];
    assert(buf[0 .. toUtf8(lone[], buf[])] == "x�");
    // Out of room: the emoji does not fit whole and is left out.
    assert(buf[0 .. toUtf8("ab\U0001F600"w, buf[0 .. 5])] == "ab");
}
