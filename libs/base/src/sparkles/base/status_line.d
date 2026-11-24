/**
The console's one line form ([SPEC CON1–CON3](../../../../../docs/specs/base/console.md)):
a verb right-aligned in a column of twelve, coloured by what happened, then
what it happened to and the details, as cargo and dub write their progress.

---
    Compiled base [test-root]  31ms
    Finished 1 package in 2.6m  14 reused, 6 ran
---

A line is data — a verb, a $(LREF Tone), and $(LREF StatusSpan)s, each with a
role — so one renderer gives every program the same look, and a sink that
keeps a copy (a ring, a file) can take the line's plain text. The colours are
the terminal's own sixteen, the same the inline live view resolves its slots to
(`sparkles.ui_tui.inline_frame`), so a line reads the same on a light terminal
and a dark one.
*/
module sparkles.base.status_line;

import std.range.primitives : put;

@safe:

/// The columns the verb is right-aligned in.
enum int verbColumns = 12;

/// What a line reports, which colours its verb.
enum Tone : ubyte
{
    plain,   /// bold, uncoloured
    success, /// green: work done
    failure, /// red: work that failed
    warning, /// yellow: done, with something to look at
    info,    /// blue: a note, a heading
    muted,   /// bright black: a detail
}

/// What a span of a line is, which styles it.
enum SpanRole : ubyte
{
    text,    /// as given
    subject, /// bold: what the line is about
    tag,     /// blue: a qualifier, `[test-root]`
    detail,  /// muted: timings, counts of little weight; set apart by two spaces
    success, /// green
    failure, /// red
    warning, /// yellow
}

/// A span of a line's text, in a role.
struct StatusSpan
{
    const(char)[] text; ///
    SpanRole role;      ///
}

/// `text` as the line's subject.
StatusSpan subject(const(char)[] text) pure nothrow @nogc => StatusSpan(text, SpanRole.subject);
/// `text` as a qualifier of the subject.
StatusSpan tag(const(char)[] text) pure nothrow @nogc => StatusSpan(text, SpanRole.tag);
/// `text` as a muted detail.
StatusSpan detail(const(char)[] text) pure nothrow @nogc => StatusSpan(text, SpanRole.detail);
/// `text` as plain text.
StatusSpan plain(const(char)[] text) pure nothrow @nogc => StatusSpan(text, SpanRole.text);

/**
One line. A line whose verb is null is $(I bare): its spans are written as
they are, without the verb column — a child's output, quoted beneath the
line that reports it. An empty verb leaves the column blank: a line that
continues the one above.
*/
struct StatusLine
{
    const(char)[] verb;           ///
    Tone tone;                    ///
    const(StatusSpan)[] spans;    ///
}

/**
Writes `line`, without a line terminator: the verb padded to $(LREF verbColumns)
on the left, a space, then the spans, one space between two, two before a
detail; an empty span is left out. With `colour`, the verb and the spans are
in the terminal's sixteen colours, each followed by a reset; without, the
text alone.
*/
void writeStatusLine(Writer)(ref Writer w, in StatusLine line, bool colour)
{
    if (line.verb !is null)
    {
        foreach (_; displayWidth(line.verb) .. verbColumns)
            put(w, ' ');
        writeStyled(w, line.verb, toneStyle(line.tone), colour);
    }
    bool first = true;
    foreach (ref s; line.spans)
    {
        if (!s.text.length)
            continue;
        if (!first || line.verb !is null)
            put(w, s.role == SpanRole.detail && !first ? "  " : " ");
        first = false;
        writeStyled(w, s.text, roleStyle(s.role), colour);
    }
}

/**
Writes one span, or one verb, alone: styled as a line would style it, with
no padding and no spacing. What a caller that lays a line's parts out
itself (in a table's columns) writes each part with.
*/
void writeSpan(Writer)(ref Writer w, in StatusSpan span, bool colour)
{
    writeStyled(w, span.text, roleStyle(span.role), colour);
}

/// ditto
void writeVerb(Writer)(ref Writer w, scope const(char)[] verb, Tone tone, bool colour)
{
    writeStyled(w, verb, toneStyle(tone), colour);
}

/// A part alone is styled as in a line, and nothing more.
@("base.status_line.writeSpan.alone")
@safe pure nothrow @nogc unittest
{
    import sparkles.base.buffer : checkWriter;

    checkWriter!((ref b) => writeSpan(b, tag("library"), true))("\x1b[34mlibrary\x1b[0m");
    checkWriter!((ref b) => writeSpan(b, tag("library"), false))("library");
    checkWriter!((ref b) => writeVerb(b, "Compiled", Tone.success, true))("\x1b[1;32mCompiled\x1b[0m");
}

/// The display columns of `text`: its code points, which is exact for the
/// verbs and labels a line carries (no wide or combining characters).
size_t displayWidth(scope const(char)[] text) pure nothrow @nogc
{
    size_t n;
    foreach (char c; text)
        if ((c & 0xC0) != 0x80)
            ++n;
    return n;
}

private:

// SGR parameters for a tone's verb and a role's span; null is no style.
string toneStyle(Tone t) pure nothrow @nogc
{
    final switch (t)
    {
        case Tone.plain: return "1";
        case Tone.success: return "1;32";
        case Tone.failure: return "1;31";
        case Tone.warning: return "1;33";
        case Tone.info: return "1;34";
        case Tone.muted: return "90";
    }
}

string roleStyle(SpanRole r) pure nothrow @nogc
{
    final switch (r)
    {
        case SpanRole.text: return null;
        case SpanRole.subject: return "1";
        case SpanRole.tag: return "34";
        case SpanRole.detail: return "90";
        case SpanRole.success: return "32";
        case SpanRole.failure: return "31";
        case SpanRole.warning: return "33";
    }
}

void writeStyled(Writer)(ref Writer w, scope const(char)[] text, string sgr, bool colour)
{
    if (!colour || sgr is null || !text.length)
    {
        put(w, text);
        return;
    }
    put(w, "\x1b[");
    put(w, sgr);
    put(w, 'm');
    put(w, text);
    put(w, "\x1b[0m");
}

/// Without colour a line is its text: the verb right-aligned in twelve
/// columns, a space, the spans, details set apart by two.
@("base.status_line.writeStatusLine.plain")
@safe pure nothrow @nogc unittest
{
    import sparkles.base.buffer : checkWriter;

    static immutable StatusSpan[3] compiled = [subject("base"), tag("[test-root]"), detail("31ms")];
    static immutable StatusSpan[1] wide = [subject("ü")];
    static immutable StatusSpan[1] quoted = [plain("core.exception.AssertError")];
    checkWriter!((ref b) => writeStatusLine(b, StatusLine("Compiled", Tone.success, compiled), false))(
        "    Compiled base [test-root]  31ms");
    checkWriter!((ref b) => writeStatusLine(b, StatusLine("Up-to-date", Tone.success, wide), false))(
        "  Up-to-date ü");
    static immutable StatusSpan[1] more = [detail("listings in build/coverage")];
    checkWriter!((ref b) => writeStatusLine(b, StatusLine("", Tone.plain, more), false))(
        "             listings in build/coverage");
    // A bare line has no verb column.
    checkWriter!((ref b) => writeStatusLine(b, StatusLine(null, Tone.plain, quoted), false))(
        "core.exception.AssertError");
}

/// With colour the verb is bold in its tone, each span in its role, and each
/// styled run ends in a reset.
@("base.status_line.writeStatusLine.colour")
@safe pure nothrow @nogc unittest
{
    import sparkles.base.buffer : checkWriter;

    static immutable StatusSpan[2] failed = [subject("base"), detail("2.0s")];
    checkWriter!((ref b) => writeStatusLine(b, StatusLine("Failed", Tone.failure, failed), true))(
        "      \x1b[1;31mFailed\x1b[0m \x1b[1mbase\x1b[0m  \x1b[90m2.0s\x1b[0m");
}
