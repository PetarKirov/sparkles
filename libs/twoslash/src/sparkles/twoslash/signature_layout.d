/**
Staged line breaking for a hover signature (spec `TWH9`).

A D signature does not wrap like prose. Breaking `int f(int a, int b)` at a
space gives `int f(int a,` / `int b)`, which is where a generic breaker stops —
it has no idea that `(` and `,` are the places a reader expects a line to end.
Worse, the parts of a real signature that overflow are single unbreakable
tokens: `sparkles.evenSquares.FilterResult!(__lambda_L7_C45, …)` contains no
space at all until it is 51 cells wide.

So the producer says where the structure is
($(REF SignatureLayout, sparkles,twoslash,protocol)) and this module decides
which of those places to use, Prettier-style: try it flat; if that does not
fit, break progressively harder until it does.

$(NUMBERED_LIST
    $(ITEM everything on one line;)
    $(ITEM the `if`/`in`/`out` clauses each on their own line;)
    $(ITEM the runtime parameter list exploded, one parameter per line;)
    $(ITEM the template argument list exploded too.)
)

The result is byte ranges, not text — the caller slices its own styled spans by
them, so one syntax-highlighting pass covers every stage and the colours cannot
change with the window width. Rows are a pure function of (layout, width), as
`LIV2` requires: the popup must lay out identically before and after an async
type lands.
*/
module sparkles.twoslash.signature_layout;

import sparkles.twoslash.protocol : BreakGroup, Contract, SignatureLayout;

@safe:

/// One rendered line: either a slice of the signature text, or a clause the
/// producer reported separately (which is not in the text at all).
struct SigRow
{
    uint start;      /// byte offset into the signature text
    uint end;        /// exclusive end; `start == end` for a literal row
    string literal;  /// the clause text, when this row is not a text slice
    ubyte indent;    /// leading indent in cells

    /// Whether this row is a clause rather than a slice of the signature.
    bool isLiteral() const pure nothrow @nogc => literal.length != 0;
}

/// How hard the breaker had to try. Reported so a caller can tell "it fits" from
/// "nothing fits" — the last stage is used even when it still overflows, since a
/// signature must be shown somehow.
enum SigStage : ubyte
{
    flat,         /// one line
    clauses,      /// `if`/`in`/`out` on their own lines
    runtimeArgs,  /// + the runtime parameter list exploded
    templateArgs, /// + the template argument list exploded
}

/// ditto
struct SigLayoutResult
{
    SigRow[] rows;
    SigStage stage;
}

// The measurer is a template parameter, not a delegate alias: injected rather
// than assumed (`LAY5` — the layout engine counts codepoints, a
// grapheme-correct caller counts clusters, and this module must not decide
// which is right), and templated so a `pure @nogc` measurer keeps its
// attributes instead of being forced through a delegate.

/**
Lays `text` out within `width` cells, using the producer's structure.

`indentCells` is the continuation indent for an exploded list — a style metric
the caller reads from its palette, never invented here (`LAY10`).
*/
SigLayoutResult layoutSignature(F)(scope const(char)[] text, in SignatureLayout sig,
    int width, int indentCells, scope F measure)
if (is(typeof(measure("")) : int))
{
    auto clauses = clauseLines(sig);

    // Stage 0: the whole thing on one line, clauses included.
    if (width <= 0 || fits(oneLine(text, clauses), width, measure))
        return SigLayoutResult(flatRows(text, clauses), SigStage.flat);

    // Stage 1: the signature keeps one line; each clause takes its own.
    auto rows = [SigRow(0, cast(uint) text.length)] ~ clauseRows(clauses);
    if (fitsAll(text, rows, width, measure))
        return SigLayoutResult(rows, SigStage.clauses);

    // Stages 2 and 3: explode the lists, runtime first — a reader scanning a
    // call cares about the arguments they pass before the types it was
    // instantiated with.
    foreach (stage; [SigStage.runtimeArgs, SigStage.templateArgs])
    {
        const maxStage = stage == SigStage.runtimeArgs ? 0 : 1;
        auto exploded = explode(text, sig, maxStage, indentCells)
            ~ clauseRows(clauses);
        if (fitsAll(text, exploded, width, measure))
            return SigLayoutResult(exploded, stage);
        rows = exploded;
    }

    // Nothing fits: show the hardest break anyway. A row that still overflows
    // is the caller's to wrap; refusing to break at all would be worse.
    return SigLayoutResult(rows, SigStage.templateArgs);
}

/// The clause lines a signature carries beside its text, in source order.
private string[] clauseLines(in SignatureLayout sig)
{
    string[] out_;
    if (sig.constraint.length)
        out_ ~= "if (" ~ sig.constraint ~ ")";
    foreach (c; sig.contracts)
        if (c.kind == "in")
            out_ ~= c.isBlock ? "in " ~ c.text : "in (" ~ c.text ~ ")";
    foreach (c; sig.contracts)
        if (c.kind == "out")
        {
            if (c.isBlock)
                out_ ~= "out " ~ c.text;
            else
                out_ ~= "out (" ~ c.resultId ~ "; " ~ c.text ~ ")";
        }
    return out_;
}

private SigRow[] flatRows(scope const(char)[] text, string[] clauses)
{
    auto rows = [SigRow(0, cast(uint) text.length)];
    // Flat means one line, so the clauses ride along as one trailing literal.
    if (clauses.length)
    {
        string joined;
        foreach (c; clauses)
            joined ~= " " ~ c;
        rows ~= SigRow(cast(uint) text.length, cast(uint) text.length, joined);
    }
    return rows;
}

private SigRow[] clauseRows(string[] clauses)
{
    SigRow[] rows;
    foreach (c; clauses)
        rows ~= SigRow(0, 0, c);
    return rows;
}

/**
Breaks every group up to `maxStage` one item per line.

The break points the producer recorded sit *before* each item, so the comma
stays on the line above and the closing paren returns to the outer indent —
the shape D itself is formatted in.
*/
private SigRow[] explode(scope const(char)[] text, in SignatureLayout sig,
    int maxStage, int indentCells)
{
    // Cut points, each carrying the indent the row that *starts* there wants.
    // Depth comes from containment: a list nested inside another indents one
    // level further, or `Foo!(Bar!(a, b))` would lay its inner arguments out in
    // the same column as its outer ones and read as one flat list.
    ubyte[uint] indentAt;
    foreach (i, g; sig.groups)
    {
        if (g.stage > maxStage)
            continue;

        int depth;
        foreach (j, outer; sig.groups)
            if (j != i && outer.stage <= maxStage
                && outer.open < g.open && g.close < outer.close)
                ++depth;

        foreach (b; sig.breaks)
            if (b.group == i)
                indentAt[b.offset] = cast(ubyte)((depth + 1) * indentCells);
        // The closing paren rejoins the level of the list it closes.
        indentAt[g.close] = cast(ubyte)(depth * indentCells);
    }

    import std.algorithm.sorting : sort;
    import std.array : array;

    auto points = indentAt.keys.array;
    points.sort();

    SigRow[] rows;
    uint from;
    ubyte indent;
    foreach (p; points)
    {
        if (p <= from)
            continue;
        // A break sits *before* an item, so the row above ends with the
        // separator's `", "` — the comma belongs to the line, the space does
        // not, and a trailing space would be visible under a selection.
        rows ~= SigRow(from, trimEnd(text, from, p), null, indent);
        from = p;
        indent = indentAt[p];
    }
    if (from < text.length)
        rows ~= SigRow(from, trimEnd(text, from, cast(uint) text.length), null, indent);
    return rows;
}

/// `end`, pulled back over trailing spaces (never past `start`).
private uint trimEnd(scope const(char)[] text, uint start, uint end) pure nothrow @nogc
{
    while (end > start && text[end - 1] == ' ')
        end--;
    return end;
}

private string oneLine(scope const(char)[] text, string[] clauses)
{
    string s = text.idup;
    foreach (c; clauses)
        s ~= " " ~ c;
    return s;
}

private bool fits(F)(scope const(char)[] s, int width, scope F measure)
    => measure(s) <= width;

private bool fitsAll(F)(scope const(char)[] text, in SigRow[] rows, int width,
    scope F measure)
{
    foreach (r; rows)
    {
        // Clause rows are already alone on their line; one that is still too
        // long stays too long however hard the parameter lists are broken, so
        // letting it force another stage would explode a signature that fits
        // for no gain. An over-long clause is the caller's to wrap.
        if (r.isLiteral)
            continue;
        if (measure(text[r.start .. r.end]) + r.indent > width)
            return false;
    }
    return true;
}

// ── Tests ───────────────────────────────────────────────────────────────────

version (unittest)
{
    import sparkles.twoslash.protocol : BreakPoint;

    /// Cell width as the layout engine counts it, for tests that care about
    /// the staging rather than about grapheme correctness.
    private int ascii(scope const(char)[] s) @safe pure nothrow @nogc
        => cast(int) s.length;

    /// The rows as text, indent made visible, so a test reads like the output.
    private string[] renderRows(scope const(char)[] text, in SigRow[] rows)
    {
        string[] out_;
        foreach (r; rows)
        {
            string pad;
            foreach (_; 0 .. r.indent)
                pad ~= " ";
            out_ ~= pad ~ (r.isLiteral ? r.literal : text[r.start .. r.end].idup);
        }
        return out_;
    }
}

@("signature_layout.layoutSignature.flatWhenItFits")
@safe unittest
{
    enum text = "int f(int a, int b)";
    const sig = SignatureLayout(
        groups: [BreakGroup(5, 18, 0)],
        breaks: [BreakPoint(6, 0), BreakPoint(13, 0)]);

    const r = layoutSignature(text, sig, 80, 4, &ascii);
    assert(r.stage == SigStage.flat);
    assert(renderRows(text, r.rows) == ["int f(int a, int b)"]);
}

@("signature_layout.layoutSignature.clausesBreakBeforeParameters")
@safe unittest
{
    // The user-visible staging rule: a signature that fits keeps its
    // parameters on one line and moves only the clauses down.
    enum text = "T twice(T)(T x)";
    const sig = SignatureLayout(
        groups: [BreakGroup(10, 14, 0), BreakGroup(7, 9, 1)],
        breaks: [BreakPoint(11, 0), BreakPoint(8, 1)],
        constraint: "isIntegralAndAlsoQuiteLong!T");

    // Flat would be 15 + 1 + 33 = 49 cells; 30 forces the clause down but
    // leaves the parameters alone.
    const r = layoutSignature(text, sig, 30, 4, &ascii);
    assert(r.stage == SigStage.clauses, "parameters must not break first");
    assert(renderRows(text, r.rows)
        == ["T twice(T)(T x)", "if (isIntegralAndAlsoQuiteLong!T)"]);
}

@("signature_layout.layoutSignature.runtimeListExplodesBeforeTemplate")
@safe unittest
{
    //  0         1         2         3
    //  0123456789012345678901234567890123456789
    enum text = "T pick(T, U)(T first, U second, int third)";
    const sig = SignatureLayout(
        groups: [BreakGroup(12, 41, 0), BreakGroup(6, 11, 1)],
        breaks: [
            BreakPoint(13, 0), BreakPoint(22, 0), BreakPoint(32, 0),
            BreakPoint(7, 1), BreakPoint(10, 1),
        ]);

    const r = layoutSignature(text, sig, 24, 4, &ascii);
    assert(r.stage == SigStage.runtimeArgs, "the template list must hold");
    assert(renderRows(text, r.rows) == [
        "T pick(T, U)(",
        "    T first,",
        "    U second,",
        "    int third",
        ")",
    ]);
}

@("signature_layout.layoutSignature.templateListExplodesLast")
@safe unittest
{
    enum text = "T pick(T, U)(T first, U second, int third)";
    const sig = SignatureLayout(
        groups: [BreakGroup(12, 41, 0), BreakGroup(6, 11, 1)],
        breaks: [
            BreakPoint(13, 0), BreakPoint(22, 0), BreakPoint(32, 0),
            BreakPoint(7, 1), BreakPoint(10, 1),
        ]);

    const r = layoutSignature(text, sig, 12, 4, &ascii);
    assert(r.stage == SigStage.templateArgs);
    assert(renderRows(text, r.rows) == [
        "T pick(",
        "    T,",
        "    U",
        ")(",
        "    T first,",
        "    U second,",
        "    int third",
        ")",
    ]);
}

@("signature_layout.layoutSignature.nestedListsIndentByDepth")
@safe unittest
{
    // `Foo!(Bar!(a, b))` laid out with one indent for both lists would read as
    // a single flat list; the inner one belongs a level in, and its closing
    // paren belongs at the level of the list it closes.
    //  0         1         2         3
    //  0123456789012345678901234567890
    enum text = "Foo!(Lambda, Bar!(a, b)) f()";
    const sig = SignatureLayout(
        groups: [
            BreakGroup(4, 23, 1),   // Foo!( … )
            BreakGroup(17, 22, 1),  // Bar!( … )
        ],
        breaks: [
            BreakPoint(5, 0), BreakPoint(13, 0),
            BreakPoint(18, 1), BreakPoint(21, 1),
        ]);

    const r = layoutSignature(text, sig, 8, 4, &ascii);
    assert(renderRows(text, r.rows) == [
        "Foo!(",
        "    Lambda,",
        "    Bar!(",
        "        a,",
        "        b",
        "    )",
        ") f()",
    ], renderRows(text, r.rows).length.stringof ~ ": unexpected nesting");
}

@("signature_layout.layoutSignature.contractsBecomeTheirOwnLines")
@safe unittest
{
    enum text = "int guarded(int x)";
    const sig = SignatureLayout(
        groups: [BreakGroup(11, 17, 0)],
        breaks: [BreakPoint(12, 0)],
        contracts: [
            Contract("in", null, "x > 0", false),
            Contract("out", "r", "r > x", false),
        ]);

    const flat = layoutSignature(text, sig, 80, 4, &ascii);
    assert(renderRows(text, flat.rows)
        == ["int guarded(int x)", " in (x > 0) out (r; r > x)"]);

    const broken = layoutSignature(text, sig, 20, 4, &ascii);
    assert(renderRows(text, broken.rows)
        == ["int guarded(int x)", "in (x > 0)", "out (r; r > x)"]);
}

@("signature_layout.layoutSignature.unbreakableStillReturnsTheHardestBreak")
@safe unittest
{
    // A name with nowhere to break must not come back empty or unbroken: the
    // caller wraps what remains, but the structure it can use is already used.
    enum text = "FilterResult!(Lambda, MapResult!(Lambda, Result)) f(int n)";
    const sig = SignatureLayout(
        groups: [BreakGroup(50, 56, 0), BreakGroup(13, 47, 1)],
        breaks: [BreakPoint(51, 0), BreakPoint(14, 1), BreakPoint(22, 1)]);

    const r = layoutSignature(text, sig, 10, 4, &ascii);
    assert(r.stage == SigStage.templateArgs);
    assert(r.rows.length > 1, "it must still break where it can");
}

@("signature_layout.layoutSignature.rowsTileTheTextExactly")
@safe unittest
{
    // The caller slices styled spans by these ranges, so anything dropped
    // between rows must be *only* the separator whitespace a line break
    // replaces — a lost character or a doubled one would both be silent.
    enum text = "T pick(T, U)(T first, U second, int third)";
    const sig = SignatureLayout(
        groups: [BreakGroup(12, 41, 0), BreakGroup(6, 11, 1)],
        breaks: [
            BreakPoint(13, 0), BreakPoint(22, 0), BreakPoint(32, 0),
            BreakPoint(7, 1), BreakPoint(10, 1),
        ]);

    foreach (width; [4, 12, 24, 40, 200])
    {
        const r = layoutSignature(text, sig, width, 4, &ascii);
        uint at;
        foreach (row; r.rows)
        {
            if (row.isLiteral)
                continue;
            assert(row.start >= at, "rows must not overlap");
            foreach (c; text[at .. row.start])
                assert(c == ' ', "only separator space may fall between rows");
            at = row.end;
        }
        foreach (c; text[at .. $])
            assert(c == ' ', "the text must be covered to its end");
    }
}
