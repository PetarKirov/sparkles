/**
Text and table selection state machine (`SEL` / `TBL`).

Provides presentation-free selection models, drag tracking, and text
extraction across both GUI and TUI backends without rendering dependencies.
*/
module sparkles.ui.selection;

import sparkles.ui.components.table.render : GridHit;

/// Which selection regime a drag runs (`SEL`/`TBL`).
enum SelectionRegime : ubyte
{
    none,
    text,
    table,
}

/// Generic hit classification from hit-testing content on a laid-out document.
struct SelectionHit
{
    bool ok;
    bool table;
    long lo = -1;
    long hi = -1;
    int tableIdx = -1;
    GridHit cell;
}

/// The mouse-selection drag state machine: tracks selection regime (text span vs
/// 2D table grid), live anchors/heads, and table modifier snapshots.
struct SelectionDrag
{
    SelectionRegime regime;
    bool selecting;
    long anchorLo, anchorHi, headLo, headHi;
    int selTable = -1;
    GridHit tblAnchor, tblHead;
    bool tblShift, tblAlt;

@safe pure nothrow @nogc:

    /// Lower source byte boundary of the text selection.
    long selMin() const => anchorLo < headLo ? anchorLo : headLo;

    /// Upper source byte boundary of the text selection.
    long selMax() const => anchorHi > headHi ? anchorHi : headHi;

    /// Whether any selection is currently active.
    bool active() const => regime != SelectionRegime.none;

    /// Resets the selection state to inactive.
    void clear()
    {
        regime = SelectionRegime.none;
        selecting = false;
        anchorLo = anchorHi = headLo = headHi = 0;
        selTable = -1;
        tblAnchor = tblHead = GridHit.init;
        tblShift = tblAlt = false;
    }

    /**
    Begins a drag from a hit: returns `true` when a drag actually starts.
    The regime and anchors come from what was under the pointer; a miss clears
    the selection. Generic over `H` (`ok`/`table`/`tableIdx`/`cell`/`lo`/`hi`).
    */
    bool begin(H)(in H h)
    {
        selecting = h.ok;
        if (h.table)
        {
            regime = SelectionRegime.table;
            selTable = h.tableIdx;
            tblAnchor = tblHead = h.cell;
            tblShift = tblAlt = false;
        }
        else if (h.ok)
        {
            regime = SelectionRegime.text;
            anchorLo = headLo = h.lo;
            anchorHi = headHi = h.hi;
        }
        else
            clear();
        return selecting;
    }

    /**
    Extends the running drag with a hover/motion hit. A table drag only follows
    hits in its own table and carries modifier snapshots; a text drag extends over
    any source span.
    */
    void extend(H)(in H h, bool shiftMod = false, bool altMod = false)
    {
        if (regime == SelectionRegime.table && h.table && h.tableIdx == selTable)
        {
            tblHead = h.cell;
            tblShift = shiftMod;
            tblAlt = altMod;
        }
        else if (regime == SelectionRegime.text && h.ok)
        {
            headLo = h.lo;
            headHi = h.hi;
        }
    }
}

/// Advance past the ANSI escape starting at `s[i] == ESC`.
private size_t skipAnsiEscape(scope const(char)[] s, size_t i) @safe pure nothrow @nogc
{
    if (i + 1 >= s.length)
        return i + 1;
    const c = s[i + 1];
    if (c == '[')
    {
        i += 2;
        while (i < s.length && !(s[i] >= '@' && s[i] <= '~'))
            ++i;
        return i < s.length ? i + 1 : i;
    }
    if (c == ']')
    {
        i += 2;
        while (i < s.length && s[i] != '\x07' && s[i] != '\x1b')
            ++i;
        if (i < s.length && s[i] == '\x07')
            return i + 1;
        if (i + 1 < s.length && s[i] == '\x1b' && s[i + 1] == '\\')
            return i + 2;
        return i < s.length ? i + 1 : i;
    }
    return i + 2;
}

/// Strips ANSI SGR escape sequences from `s`.
string stripSgr(scope const(char)[] s) @safe pure nothrow
{
    auto r = new char[s.length];
    size_t n, i;
    while (i < s.length)
    {
        if (s[i] == '\x1b' && i + 1 < s.length)
        {
            i = skipAnsiEscape(s, i);
            continue;
        }
        r[n++] = s[i++];
    }
    return (() @trusted => cast(string) r[0 .. n])();
}

/**
Extracts the selected source text from `source` for `drag` (text regime),
optionally stripping ANSI SGR formatting codes. Returns `null` if no text is selected.
*/
string extractSelectedText(scope const(char)[] source, in SelectionDrag drag,
    bool stripAnsi = false) @safe
{
    if (drag.regime == SelectionRegime.text && drag.selMax > drag.selMin
        && drag.selMax <= cast(long) source.length && drag.selMin >= 0)
    {
        auto slice = source[cast(size_t) drag.selMin .. cast(size_t) drag.selMax];
        return stripAnsi ? stripSgr(slice) : slice.idup;
    }
    return null;
}

// ── Tests ───────────────────────────────────────────────────────────────────

@("ui.selection.SelectionDrag.beginPicksTheRegime")
@safe pure nothrow @nogc
unittest
{
    SelectionDrag d;

    // A text hit: anchors collapse onto the hit span.
    assert(d.begin(SelectionHit(ok: true, lo: 10, hi: 14)));
    assert(d.regime == SelectionRegime.text);
    assert(d.selMin == 10 && d.selMax == 14);
    assert(d.active);

    // A table hit: the drag binds to that table.
    d.tblShift = true;
    assert(d.begin(SelectionHit(ok: true, table: true, tableIdx: 2,
        cell: GridHit(1, 3))));
    assert(d.regime == SelectionRegime.table);
    assert(d.selTable == 2);
    assert(!d.tblShift && !d.tblAlt);
    assert(d.active);

    // A miss: cleared.
    assert(!d.begin(SelectionHit()));
    assert(d.regime == SelectionRegime.none);
    assert(!d.active);
}

@("ui.selection.SelectionDrag.extendFollowsItsRegime")
@safe pure nothrow @nogc
unittest
{
    SelectionDrag d;

    // A table drag ignores hits in OTHER tables and text spans:
    cast(void) d.begin(SelectionHit(ok: true, table: true, tableIdx: 1,
        cell: GridHit(0, 0)));
    d.extend(SelectionHit(ok: true, table: true, tableIdx: 7,
        cell: GridHit(9, 9)), true, false);
    assert(d.tblHead == GridHit(0, 0) && !d.tblShift);

    // ...and follows its own table:
    d.extend(SelectionHit(ok: true, table: true, tableIdx: 1,
        cell: GridHit(2, 4)), true, false);
    assert(d.tblHead == GridHit(2, 4) && d.tblShift);

    // Text drag extends across text hits:
    cast(void) d.begin(SelectionHit(ok: true, lo: 20, hi: 25));
    d.extend(SelectionHit(ok: true, lo: 5, hi: 10));
    assert(d.selMin == 5 && d.selMax == 25);
}

@("ui.selection.extractSelectedText")
@safe unittest
{
    const src = "Hello, \x1b[31mworld\x1b[0m!";
    SelectionDrag d;
    cast(void) d.begin(SelectionHit(ok: true, lo: 7, hi: 21));

    assert(extractSelectedText(src, d, false) == "\x1b[31mworld\x1b[0m");
    assert(extractSelectedText(src, d, true) == "world");

    d.clear();
    assert(extractSelectedText(src, d) is null);
}
