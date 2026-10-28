/**
Local review comments anchored by content (`DCM1`).

A comment remembers the line it is about by what the line and its
neighbours say, not by the line's number, and finds it again in whatever
text the file has now. It survives a re-diff, a rebase, and lines inserted
above it, as GitButler's comments do. A comment whose line is gone is
_outdated_ rather than lost: it still renders, next to where it was, and
says so.

The text a comment is anchored in is one side of a diff: the new side,
or the old one for a comment on a removed line.
*/
module sparkles.doc_view.diff_comments;

import sparkles.doc_view.diff_session : AnchoredThread, ThreadComment;
import sparkles.syntax.md.model : MdDoc;

/// How many lines above and below the anchor a comment remembers.
enum uint anchorRadius = 2;

/// A proposed replacement for the lines a comment is anchored to (`DCM3`).
struct Suggestion
{
    /// How many lines, from the anchor down, the replacement covers.
    uint lines = 1;
    /// The replacement text for them, without a final line break.
    string text;
}

/// One local review comment (`DCM1`).
struct LocalComment
{
    /// Stable for the comment's life: the store and the forge name it by this.
    string id;
    /// The file, as the diff names its new side.
    string path;
    /// Anchored on the old side: a comment on a removed line.
    bool oldSide;
    /// The 1-based line it was written on: a hint when the content repeats.
    uint line;
    /// The anchor line and up to `anchorRadius` lines either side of it.
    string[] context;
    /// The anchor line's index in `context`.
    uint anchorAt;
    /// The comment, in markdown.
    string body_;
    string author;
    /// When it was written, in seconds since the Unix epoch.
    long created;
    bool resolved;
    /// A proposed change to the anchored lines (`DCM3`).
    bool hasSuggestion;
    /// ditto
    Suggestion suggestion;
}

/// The lines of `text`, without their line breaks.
string[] linesOf(string text) @safe pure nothrow
{
    string[] lines;
    size_t start;
    foreach (i, c; text)
        if (c == '\n')
        {
            lines ~= text[start .. i];
            start = i + 1;
        }
    if (start < text.length)
        lines ~= text[start .. $];
    return lines;
}

/**
Records the content around 1-based line `line` of `sideText` into `c`: the
anchor line and its neighbours. `false` when the side has no such line.
*/
bool captureAnchor(ref LocalComment c, string sideText, uint line) @safe pure nothrow
{
    const lines = linesOf(sideText);
    if (line == 0 || line > lines.length)
        return false;
    const at = line - 1;
    const from = at >= anchorRadius ? at - anchorRadius : 0;
    const to = at + anchorRadius + 1 < lines.length ? at + anchorRadius + 1 : lines.length;
    c.line = line;
    c.context = lines[from .. to].dup;
    c.anchorAt = cast(uint)(at - from);
    return true;
}

/**
Finds `c`'s anchor in `sideText` (`DCM1`): the 1-based line, or 0 when no
line reads as the anchor did.

Every line equal to the anchor is a candidate. The one whose neighbours
agree with the remembered ones on the most lines wins, the nearest to the
line it was written on breaking a tie, so a comment on one of several
identical lines stays on its own.
*/
uint relocate(in LocalComment c, string sideText) @safe pure nothrow
{
    if (c.anchorAt >= c.context.length)
        return 0;
    const lines = linesOf(sideText);
    const anchor = c.context[c.anchorAt];
    uint best;
    size_t bestScore;
    ulong bestDistance = ulong.max;
    foreach (i, l; lines)
    {
        if (l != anchor)
            continue;
        size_t score;
        foreach (k, remembered; c.context)
        {
            const at = cast(long) i + cast(long) k - cast(long) c.anchorAt;
            if (k != c.anchorAt && at >= 0 && at < cast(long) lines.length
                && lines[cast(size_t) at] == remembered)
                ++score;
        }
        const line = cast(uint)(i + 1);
        const distance = line > c.line ? line - c.line : c.line - line;
        if (best == 0 || score > bestScore || score == bestScore && distance < bestDistance)
        {
            best = line;
            bestScore = score;
            bestDistance = distance;
        }
    }
    return best;
}

/**
The comments on `path` as thread blocks for the diff view (`DCM2`), each
re-located in its side's text. An outdated one hangs where it was written,
clamped to the text, and is marked so; its body is parsed by `parse`.
*/
AnchoredThread[] threadsOf(in LocalComment[] comments, string path, string oldText,
    string newText, scope MdDoc delegate(string markdown) @safe parse) @safe
{
    AnchoredThread[] threads;
    foreach (ref c; comments)
    {
        if (c.path != path)
            continue;
        const text = c.oldSide ? oldText : newText;
        const found = relocate(c, text);
        const lineCount = linesOf(text).length;
        AnchoredThread t;
        t.path = c.path;
        t.oldSide = c.oldSide;
        t.resolved = c.resolved;
        t.outdated = found == 0;
        t.line = found != 0 ? found
            : cast(uint)(c.line <= lineCount ? c.line : lineCount);
        t.comments = [ThreadComment(c.author, createdText(c.created), parse(bodyWithSuggestion(c)))];
        threads ~= t;
    }
    return threads;
}

/// The comment's body, with its suggestion as a fence a reader recognizes.
string bodyWithSuggestion(const ref LocalComment c) @safe pure nothrow
    => c.hasSuggestion ? c.body_ ~ "\n\n```suggestion\n" ~ c.suggestion.text ~ "\n```\n" : c.body_;

/// `created` as `YYYY-MM-DD HH:MM` UTC, or empty when unknown.
string createdText(long created) @safe
{
    import std.datetime.systime : SysTime, unixTimeToStdTime;
    import std.datetime.timezone : UTC;
    import std.format : format;

    if (created <= 0)
        return null;
    const t = SysTime(unixTimeToStdTime(created), UTC());
    return format!"%04d-%02d-%02d %02d:%02d"(t.year, t.month, t.day, t.hour, t.minute);
}

@("diff_comments.relocate.followsTheContentNotTheNumber")
@safe pure nothrow unittest
{
    LocalComment c;
    assert(captureAnchor(c, "a\nb\nc\nd\ne\n", 3));
    assert(c.context == ["a", "b", "c", "d", "e"] && c.anchorAt == 2);
    assert(relocate(c, "new\nnew\na\nb\nc\nd\ne\n") == 5, "lines inserted above");
    assert(relocate(c, "a\nb\nd\ne\n") == 0, "the line is gone: outdated");
}

@("diff_comments.relocate.repeatedLinesKeepTheirOwn")
@safe pure nothrow unittest
{
    // Two identical lines: the neighbours decide, then the distance.
    enum text = "x\n}\ny\n}\nz\n";
    LocalComment second;
    assert(captureAnchor(second, text, 4));
    assert(relocate(second, text) == 4);
    assert(relocate(second, "header\n" ~ text) == 5);
}

@("diff_comments.threadsOf.marksOutdated")
@safe unittest
{
    LocalComment kept, lost;
    kept.path = lost.path = "f.d";
    kept.body_ = "keep";
    lost.body_ = "lost";
    captureAnchor(kept, "a\nb\nc\n", 2);
    captureAnchor(lost, "a\nb\nc\n", 3);
    const threads = threadsOf([kept, lost], "f.d", "", "a\nb\nC\n",
        (string md) => MdDoc.init);
    assert(threads.length == 2);
    assert(threads[0].line == 2 && !threads[0].outdated);
    assert(threads[1].line == 3 && threads[1].outdated, "it hangs where it was");
}
