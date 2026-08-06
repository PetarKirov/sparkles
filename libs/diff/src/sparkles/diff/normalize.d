/**
Whitespace-insensitive line comparison (`DVN1`).

The noise strategy's first layer. A reviewer who reformats a file and edits one
line wants to see the edit, not the reformat — so the engine must be able to
decide "these two lines are the same" under a configurable whitespace policy,
and it must decide it **before** the line diff runs. That is the difference
between _hiding_ a change in the renderer and never producing one: a line that
compares equal here is never a change in the model, so every consumer — the
hunk builder, the pairing pass, the emitters, and every sink — agrees.

What is deliberately NOT done here: normalizing the text that gets rendered.
The comparison sees a normalized view, the model keeps the raw bytes, and the
viewer shows the file as it actually is. A diff tool that quietly re-spaced the
code it displays would be lying about the file.

The vocabulary mirrors git's, because that is what the audience already knows:
$(LREF WhitespaceMode.trailing) is `--ignore-space-at-eol`,
$(LREF WhitespaceMode.change) is `-b`, and $(LREF WhitespaceMode.all) is `-w`.

`@safe pure nothrow @nogc` throughout (`DVM8`), and allocation-free by
construction: the modes that cannot be expressed as a slice comparison walk
both lines with cursors rather than materializing a normalized copy.
*/
module sparkles.diff.normalize;

/// How much whitespace difference counts as "the same line" (`DVN1`).
enum WhitespaceMode : ubyte
{
    /// Every byte counts (the default — a diff tool's honest baseline).
    exact,
    /// Ignore whitespace at end of line (git `--ignore-space-at-eol`).
    trailing,
    /// Ignore leading and trailing whitespace, and treat any run of internal
    /// whitespace as equal to any other (git `-b`). The mode that survives a
    /// re-indent or a re-aligned table without losing real edits.
    change,
    /// Ignore whitespace entirely (git `-w`).
    all,
}

/// Whitespace for this purpose: the blanks a formatter moves around. `\r` is
/// included so a CRLF file does not read as changed on every line.
bool isSpace(char c) @safe pure nothrow @nogc
    => c == ' ' || c == '\t' || c == '\r' || c == '\v' || c == '\f';

/// `line` with trailing whitespace removed.
const(char)[] withoutTrailingSpace(return scope const(char)[] line)
    @safe pure nothrow @nogc
{
    size_t end = line.length;
    while (end != 0 && isSpace(line[end - 1]))
        --end;
    return line[0 .. end];
}

/// `true` when `line` holds nothing but whitespace (including empty) — the
/// blank-line test `DVN2` classifies with.
bool isBlank(scope const(char)[] line) @safe pure nothrow @nogc
    => withoutTrailingSpace(line).length == 0;

/**
Three-way comparison of two lines under `mode`: negative when `a` sorts before
`b`, zero when they are the same line, positive otherwise.

Total order rather than just equality because the line-interning pass sorts to
assign ids without an associative array (`DVM8`) — so equality and ordering
have to come from one function, or a sort could group lines the equality test
then disagrees about.
*/
int compareLines(scope const(char)[] a, scope const(char)[] b, WhitespaceMode mode)
    @safe pure nothrow @nogc
{
    final switch (mode) with (WhitespaceMode)
    {
        case exact:
            return rawCompare(a, b);
        case trailing:
            // Expressible as a slice comparison, so it costs one scan rather
            // than a cursor walk.
            return rawCompare(withoutTrailingSpace(a), withoutTrailingSpace(b));
        case change:
        case all:
            return cursorCompare(a, b, mode);
    }
}

/// ditto — equality alone, for callers that do not need the ordering.
bool linesEqual(scope const(char)[] a, scope const(char)[] b, WhitespaceMode mode)
    @safe pure nothrow @nogc
    => compareLines(a, b, mode) == 0;

private int rawCompare(scope const(char)[] a, scope const(char)[] b)
    @safe pure nothrow @nogc
{
    const n = a.length < b.length ? a.length : b.length;
    foreach (i; 0 .. n)
        if (a[i] != b[i])
            return a[i] < b[i] ? -1 : 1;
    if (a.length == b.length)
        return 0;
    return a.length < b.length ? -1 : 1;
}

/// One line's significant bytes under `change`/`all`, produced on demand.
private struct Cursor
{
    const(char)[] s;
    WhitespaceMode mode;
    size_t i;
    bool atStart = true;

    /// The next significant byte, or `-1` at end of line. Under `change` a run
    /// of internal whitespace yields a single `' '`, while leading and
    /// trailing runs yield nothing at all — which is what makes a re-indent
    /// and a re-aligned column compare equal.
    int next() scope @safe pure nothrow @nogc
    {
        for (;;)
        {
            if (i >= s.length)
                return -1;
            const c = s[i];
            if (!isSpace(c))
            {
                atStart = false;
                ++i;
                return c;
            }
            if (mode == WhitespaceMode.all)
            {
                ++i;
                continue;
            }
            // `change`: consume the whole run, then decide what it was worth.
            while (i < s.length && isSpace(s[i]))
                ++i;
            if (i >= s.length)
                return -1; // trailing run
            if (atStart)
            {
                atStart = false;
                continue; // leading run
            }
            return ' '; // internal run — one space, whatever its width
        }
    }
}

private int cursorCompare(scope const(char)[] a, scope const(char)[] b,
    WhitespaceMode mode) @safe pure nothrow @nogc
{
    auto ca = Cursor(a, mode);
    auto cb = Cursor(b, mode);
    for (;;)
    {
        const x = ca.next();
        const y = cb.next();
        if (x != y)
            return x < y ? -1 : 1;
        if (x == -1)
            return 0;
    }
}

// ── Tests ───────────────────────────────────────────────────────────────────

@("normalize.compareLines.exactIsByteForByte")
@safe pure nothrow @nogc
unittest
{
    assert(linesEqual("int x;", "int x;", WhitespaceMode.exact));
    assert(!linesEqual("int x;", "int  x;", WhitespaceMode.exact));
    assert(!linesEqual("int x;", "int x; ", WhitespaceMode.exact));
    // The default really is exact: a whitespace-only difference IS a change
    // until a reviewer says otherwise.
    assert(!linesEqual("  a", "a", WhitespaceMode.exact));
}

@("normalize.compareLines.trailingOnly")
@safe pure nothrow @nogc
unittest
{
    assert(linesEqual("int x;", "int x;   ", WhitespaceMode.trailing));
    assert(linesEqual("int x;\t", "int x;", WhitespaceMode.trailing));
    // Leading and internal whitespace still count.
    assert(!linesEqual("  int x;", "int x;", WhitespaceMode.trailing));
    assert(!linesEqual("int  x;", "int x;", WhitespaceMode.trailing));
    // A CRLF file must not read as changed on every line.
    assert(linesEqual("int x;\r", "int x;", WhitespaceMode.trailing));
}

@("normalize.compareLines.changeCollapsesRuns")
@safe pure nothrow @nogc
unittest
{
    // The mode that survives a re-indent…
    assert(linesEqual("    return a;", "\treturn a;", WhitespaceMode.change));
    // …and a re-aligned table column, which is the motivating scenario.
    assert(linesEqual("| a | b |", "|  a   |    b |", WhitespaceMode.change));
    // But a real edit is still a change: collapsing runs must not collapse
    // content.
    assert(!linesEqual("| a | b |", "| a | c |", WhitespaceMode.change));
    // Whitespace where there was none is a change (`a b` is not `ab`) —
    // the difference between this mode and `all`.
    assert(!linesEqual("a b", "ab", WhitespaceMode.change));
    assert(linesEqual("a b", "ab", WhitespaceMode.all));
}

@("normalize.compareLines.allIgnoresEveryBlank")
@safe pure nothrow @nogc
unittest
{
    assert(linesEqual("  a\tb  ", "ab", WhitespaceMode.all));
    assert(!linesEqual("ab", "ba", WhitespaceMode.all), "order still matters");
    // A blank line and an empty line are the same line under every mode that
    // ignores anything at all.
    assert(linesEqual("   ", "", WhitespaceMode.trailing));
    assert(linesEqual("\t", "", WhitespaceMode.all));
}

@("normalize.compareLines.isATotalOrder")
@safe pure nothrow @nogc
unittest
{
    // The interning pass sorts with this and then groups equal neighbours, so
    // ordering and equality must agree: antisymmetry, and equal lines really
    // comparing zero in both directions.
    static immutable string[] lines = [
        "alpha", "  alpha  ", "beta", "beta ", "a b", "ab", "",
    ];
    foreach (m; [WhitespaceMode.exact, WhitespaceMode.trailing,
            WhitespaceMode.change, WhitespaceMode.all])
        foreach (a; lines)
            foreach (b; lines)
            {
                const ab = compareLines(a, b, m);
                const ba = compareLines(b, a, m);
                assert((ab == 0) == (ba == 0));
                assert((ab < 0) == (ba > 0));
                assert(compareLines(a, a, m) == 0);
            }
}

@("normalize.isBlank.whitespaceOnly")
@safe pure nothrow @nogc
unittest
{
    assert(isBlank("") && isBlank("   ") && isBlank("\t \r"));
    assert(!isBlank("x") && !isBlank("  x  "));
}
