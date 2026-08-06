/**
 * Fitting a command's captured output into a bounded result box.
 *
 * Every mode of this tool runs child processes and reports each one inside a
 * box of a few lines. When the output does not fit, something has to go — and
 * *which* end is dropped decides whether a failing run is diagnosable from the
 * log alone.
 *
 * $(B The tail is what matters.) A failing command says why it failed in its
 * last lines: the assertion, the missing symbol, the expected/actual diff. The
 * head is a build preamble. Truncating from the tail therefore produces a red
 * box containing dependency chatter and an ellipsis — which reads as "something
 * went wrong somewhere" and sends the reader off to reproduce locally for
 * information the run already had on screen.
 *
 * That failure mode is why this lives in its own module rather than beside its
 * caller in `app.d`: `app.d` is the package's `mainSourceFile`, which dub
 * excludes from the test build, so nothing in it is covered by `dub test :ci`.
 */
module output_lines;

import std.conv : text;

/**
 * Fits `lines` into at most `maxLines`, keeping both ends when it must cut.
 *
 * The budget is spent tail-first: one line goes to the elision marker, up to
 * two to the head for context, and everything left to the tail. A run that fits
 * is returned untouched.
 *
 * Params:
 *   lines = the captured output, one element per line
 *   maxLines = the box's line budget; at least 2
 *   marker = renders the elision line from the number of omitted lines. The
 *      default is plain text; `app.d` passes a styled one.
 *
 * Returns: at most `maxLines` elements, ready to draw.
 */
string[] fitOutputLines(Marker)(string[] lines, size_t maxLines, scope Marker marker)
if (is(typeof(marker(size_t.init)) : string))
in (maxLines > 1, "maxLines must be at least 2 for the truncation indicator")
{
    if (lines.length <= maxLines)
        return lines;

    // The head is worth two lines (the command and its first response) once
    // there is room, and is the first thing given up when there is not.
    const head = maxLines >= 6 ? 2 : (maxLines >= 3 ? 1 : 0);
    const tail = maxLines - head - 1;

    return lines[0 .. head] ~ [marker(lines.length - head - tail)] ~ lines[$ - tail .. $];
}

/// ditto
string[] fitOutputLines(string[] lines, size_t maxLines = 8) @safe
    => fitOutputLines(lines, maxLines, (size_t omitted) => text("… ", omitted, " more lines …"));

@("ci.fitOutputLines.keepsTheTail")
@safe
unittest
{
    import std.algorithm : map;
    import std.array : array;
    import std.range : iota;

    auto lines = 30.iota.map!(n => n.text).array;

    // The budget is honoured, the head gives context, and the tail — where a
    // failure's message lives — survives intact.
    auto shown = fitOutputLines(lines, 8);
    assert(shown.length == 8);
    assert(shown[0 .. 2] == ["0", "1"]);
    assert(shown[$ - 5 .. $] == ["25", "26", "27", "28", "29"]);

    // A larger budget spends the extra lines on the tail, not the head.
    auto wide = fitOutputLines(lines, 24);
    assert(wide.length == 24);
    assert(wide[0 .. 2] == ["0", "1"]);
    assert(wide[$ - 21 .. $] == lines[$ - 21 .. $]);

    // The regression this module exists for: the last line of a failing run is
    // always visible, whatever the budget.
    foreach (budget; [2, 3, 5, 8, 12, 24, 29])
        assert(fitOutputLines(lines, budget)[$ - 1] == "29");
}

@("ci.fitOutputLines.passesThroughWhatFits")
@safe
unittest
{
    import std.algorithm : map;
    import std.array : array;
    import std.range : iota;

    auto lines = 30.iota.map!(n => n.text).array;

    assert(fitOutputLines(lines[0 .. 8], 8) == lines[0 .. 8]);
    assert(fitOutputLines(lines[0 .. 3], 8) == lines[0 .. 3]);
    assert(fitOutputLines([], 8) == []);
}

@("ci.fitOutputLines.markerHook")
@safe
unittest
{
    import std.algorithm : map;
    import std.array : array;
    import std.range : iota;

    auto lines = 30.iota.map!(n => n.text).array;

    // The caller styles the elision line; the count it receives is the number
    // of lines actually dropped, not the input length.
    auto shown = fitOutputLines(lines, 8, (size_t n) => text("cut ", n));
    assert(shown[2] == "cut 23");
    assert(shown.length == 8);
}
