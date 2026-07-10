/++
Proportional meters/bars with eighth-cell precision (`█▉▊▋▌▍▎▏`), plus a
`done/total` $(LREF ProgressBar) composing one with a counter — the determinate
counterpart of `ui/progress.d`'s spinner line.

Pure producers into any output range (`@nogc` with a `SmallBuffer`); an ASCII
fallback charset is provided for non-UTF-8 terminals (`TermCaps.unicode`).
+/
module sparkles.core_cli.ui.meter;

/// The partial-cell glyphs, indexed by eighths (index 0 unused).
private static immutable string[8] eighthBlocks = ["", "▏", "▎", "▍", "▌", "▋", "▊", "▉"];

/// The bar charset: `full` for whole cells, `empty` for the remainder;
/// `subCell` draws the fractional final cell with the `▏▎▍▌▋▊▉` eighth blocks
/// (off in the ASCII fallback, which has no partial glyphs).
struct MeterGlyphs
{
    string full = "█";
    string empty = " ";
    bool subCell = true;
}

/// The charset for a terminal's unicode capability: `#`/`-` cells (no
/// sub-cell precision) when `unicode` is false.
MeterGlyphs meterGlyphs(bool unicode) @safe pure nothrow @nogc
{
    if (unicode)
        return MeterGlyphs.init;
    return MeterGlyphs(full: "#", empty: "-", subCell: false);
}

/// Write a `width`-cell bar filled to `fraction` (clamped to [0, 1]): whole
/// cells in `full`, one eighth-precision partial cell, `empty` padding out to
/// exactly `width` cells.
void writeMeter(Writer)(
    ref Writer w, double fraction, size_t width,
    in MeterGlyphs glyphs = MeterGlyphs.init)
{
    import std.range.primitives : put;

    if (fraction < 0 || fraction != fraction) // NaN guards as empty
        fraction = 0;
    if (fraction > 1)
        fraction = 1;

    const cells = fraction * width;
    const full = cast(size_t) cells;
    const eighth = cast(size_t) ((cells - full) * 8 + 0.5);

    size_t used;
    foreach (_; 0 .. full)
    {
        put(w, glyphs.full);
        used++;
    }
    if (used < width && eighth > 0 && eighth < 8 && glyphs.subCell)
    {
        put(w, eighthBlocks[eighth]);
        used++;
    }
    else if (used < width && eighth == 8)
    {
        // Rounding carried the partial cell to a full one.
        put(w, glyphs.full);
        used++;
    }
    foreach (_; used .. width)
        put(w, glyphs.empty);
}

/// A `value`-of-`max` bar (an empty bar when `max == 0`).
void writeMeter(Writer)(
    ref Writer w, size_t value, size_t max, size_t width,
    in MeterGlyphs glyphs = MeterGlyphs.init)
{
    writeMeter(w, max == 0 ? 0.0 : cast(double) value / cast(double) max,
        width, glyphs);
}

/// Convenience overloads returning a GC string. Prefer the writer forms in
/// `@nogc` code.
string meter(double fraction, size_t width, in MeterGlyphs glyphs = MeterGlyphs.init) @safe
{
    import std.array : appender;

    auto w = appender!string;
    writeMeter(w, fraction, width, glyphs);
    return w[];
}

/// ditto
string meter(size_t value, size_t max, size_t width,
    in MeterGlyphs glyphs = MeterGlyphs.init) @safe
{
    import std.array : appender;

    auto w = appender!string;
    writeMeter(w, value, max, width, glyphs);
    return w[];
}

/// A determinate progress bar: `████▌     12/40` — a meter plus the counter,
/// with `done` right-justified in `total`'s digit width. Renders into any
/// output range via `toString` (the `ProgressLine` pattern), so it stays
/// `@nogc`-testable and terminal-free.
struct ProgressBar
{
    size_t done;      /// Completed units.
    size_t total;     /// Total units.
    size_t barWidth = 20; /// Meter width in cells.
    MeterGlyphs glyphs;

    void toString(Writer)(ref Writer w) const
    {
        import std.range.primitives : put;
        import sparkles.base.smallbuffer : SmallBuffer;
        import sparkles.base.text.width : Align, alignField;
        import sparkles.base.text.writers : writeInteger;

        writeMeter(w, done, total, barWidth, glyphs);
        put(w, ' ');

        SmallBuffer!(char, 20) doneBuf;
        writeInteger(doneBuf, done);
        SmallBuffer!(char, 20) totalBuf;
        writeInteger(totalBuf, total);
        alignField(w, doneBuf[], totalBuf.length, Align.right);
        put(w, '/');
        put(w, totalBuf[]);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

@("meter.fractions")
@safe unittest
{
    assert(meter(0.0, 4) == "    ");
    assert(meter(1.0, 4) == "████");
    assert(meter(0.5, 4) == "██  ");
    assert(meter(2.0, 4) == "████");  // clamped
    assert(meter(-1.0, 4) == "    "); // clamped
}

@("meter.eighthPrecision")
@safe unittest
{
    // 0.4375 * 4 cells = 1.75 cells -> one full block + a 6/8 block + padding.
    assert(meter(0.4375, 4) == "█▊  ");
    // A remainder that rounds to 8/8 carries into a full block.
    assert(meter(0.999, 4) == "████");
}

@("meter.countsAndAscii")
@safe unittest
{
    assert(meter(3, 4, 8) == "██████  ");
    assert(meter(0, 0, 4) == "    "); // max == 0 -> empty, no division
    assert(meter(3, 4, 8, meterGlyphs(false)) == "######--");
    assert(meter(1, 1, 4, meterGlyphs(false)) == "####");
}

@("meter.progressBar")
@safe unittest
{
    import sparkles.base.smallbuffer : checkToString;

    checkToString(ProgressBar(done: 5, total: 40, barWidth: 8), "█         5/40");
    checkToString(ProgressBar(done: 40, total: 40, barWidth: 8), "████████ 40/40");
}
