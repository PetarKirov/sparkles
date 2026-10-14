/**
OpenType Coverage tables (`docs/specs/font/variation-metrics.md` FTP34; the
layout tables of § 8 share them).

A `Coverage` borrows the bytes of the table that contains it (`MATH`, `GDEF`,
`GSUB`, `GPOS`) and reports errors with that table's tag and offsets (FTP14).
Format 1 is a sorted glyph array and format 2 sorted glyph ranges; `index`
finds a glyph's coverage index by binary search in O(log n), and `glyphs`
walks the covered glyphs in coverage order. Another format is
`unsupportedVersion` and an array past the table `truncated`, both reported by
the lookups rather than by `read`, so a caller decides when they matter.
Nothing here asserts on data or allocates.
*/
module sparkles.font.coverage;

import sparkles.font.bytes : be16, fits;
import sparkles.font.errors : FontError, FontErrorKind, FontResult, fontErr, fontOk, Tag, tableError;

@safe pure nothrow @nogc:

/// The coverage index of a glyph, or that the glyph is not covered.
struct CoverageIndex
{
    /// Whether the glyph is covered.
    bool covered;
    /**
    Its coverage index, when `covered`: its position in a format-1 array, or
    `startCoverageIndex + gid − start` in a format-2 range (up to 2³² − 1 in
    hostile data).
    */
    uint index;
}

/// A covered glyph and its coverage index, as `Coverage.glyphs` yields them.
struct CoveredGlyph
{
    ushort glyph;
    uint index;
}

/**
A Coverage table inside some table. `Coverage.init` covers no glyph; a
problem with the header is recorded by `read` and returned by `index` and
`glyphs`.
*/
struct Coverage
{
    @safe pure nothrow @nogc:

    private const(ubyte)[] table_;
    private ulong at_; // the first record, from the table start
    private ushort format_, count_;
    private bool broken_;
    private FontError error_;

    /**
    The Coverage at `offset` inside `table`, which is the table `tag`
    starting at absolute `tableStart`. An offset past the table is
    `badOffset`; a header or array past it `truncated`; a format other than 1
    or 2 `unsupportedVersion`. A failure is recorded, not returned. Costs O(1).
    */
    static Coverage read(return scope const(ubyte)[] table, Tag tag, ulong tableStart, ulong offset)
    {
        Coverage c;
        c.table_ = table;
        if (offset >= table.length)
            return c.fail(tableError(FontErrorKind.badOffset, tag, tableStart, offset));
        if (!fits(table.length, offset, 4))
            return c.fail(tableError(FontErrorKind.truncated, tag, tableStart, offset));
        const p = cast(size_t) offset;
        c.format_ = be16(table, p);
        if (c.format_ != 1 && c.format_ != 2)
            return c.fail(tableError(FontErrorKind.unsupportedVersion, tag, tableStart, offset));
        c.count_ = be16(table, p + 2);
        c.at_ = offset + 4;
        if (!fits(table.length, c.at_, ulong(c.recordSize) * c.count_))
            return c.fail(tableError(FontErrorKind.truncated, tag, tableStart, c.at_));
        return c;
    }

    private Coverage fail(FontError e) return scope
    {
        broken_ = true;
        count_ = 0;
        error_ = e;
        return this;
    }

    private uint recordSize() const scope => format_ == 1 ? 2 : 6;

    /// Whether `read` found the table malformed; `index` and `glyphs` then return `error`.
    bool broken() const scope => broken_;

    /// What is wrong with the table, when `broken`.
    FontError error() const scope
    in (broken_)
        => error_;

    /// The format, 1 or 2; 0 for `Coverage.init` or an unreadable header.
    ushort format() const scope => format_;

    /// The number of glyphs (format 1) or ranges (format 2).
    ushort count() const scope => count_;

    /**
    The coverage index of `gid` (binary search, O(log n)): format 1 its
    position in the glyph array, format 2 `startCoverageIndex + gid − start`
    in the range holding it. Arrays are searched as stored; unsorted data
    finds what a binary search finds. A malformed table is its error.
    */
    FontResult!CoverageIndex index(uint gid) const scope
    {
        if (broken_)
            return fontErr!CoverageIndex(error_);
        CoverageIndex r;
        if (gid > ushort.max)
            return fontOk(r);
        const t = table_;
        size_t lo = 0, hi = count_;
        while (lo < hi)
        {
            const mid = lo + (hi - lo) / 2;
            const p = cast(size_t)(at_ + recordSize * mid);
            const start = be16(t, p);
            const end = format_ == 1 ? start : be16(t, p + 2);
            if (gid < start)
                hi = mid;
            else if (gid > end)
                lo = mid + 1;
            else
            {
                r.covered = true;
                r.index = format_ == 1 ? cast(uint) mid : be16(t, p + 4) + (gid - start);
                return fontOk(r);
            }
        }
        return fontOk(r);
    }

    /**
    The covered glyphs in coverage order: format 1's array, then format 2's
    ranges each from start to end (a range whose end precedes its start
    covers nothing). A malformed table is its error. Costs O(1), and O(1)
    amortized per glyph.
    */
    FontResult!CoveredGlyphs glyphs() const return scope
    {
        if (broken_)
            return fontErr!CoveredGlyphs(error_);
        auto g = CoveredGlyphs(table_, at_, format_, count_);
        g.settle();
        return fontOk(g);
    }
}

///
@("coverage.Coverage.index")
@safe pure nothrow @nogc
unittest
{
    // Format 2: glyphs 10–12 at index 0, 20–21 at index 3.
    static immutable ubyte[] bytes = [0, 2, 0, 2, 0, 10, 0, 12, 0, 0, 0, 20, 0, 21, 0, 3];
    const c = Coverage.read(bytes, Tag("MATH"), 0, 0);
    assert(c.index(11).value == CoverageIndex(true, 1));
    assert(c.index(21).value == CoverageIndex(true, 4));
    assert(!c.index(15).value.covered);
}

/**
The glyphs a `Coverage` covers, in coverage order, with their coverage
indices: a forward range.
*/
struct CoveredGlyphs
{
    @safe pure nothrow @nogc:

    private const(ubyte)[] table_;
    private ulong at_;
    private ushort format_;
    private size_t record_, count_;
    private uint glyph_; // the current glyph within the current record

    private this(return scope const(ubyte)[] table, ulong at, ushort format, size_t count)
    {
        table_ = table;
        at_ = at;
        format_ = format;
        count_ = count;
    }

    private ushort field(size_t record, size_t at) const scope
        => be16(table_, cast(size_t)(at_ + (format_ == 1 ? 2 : 6) * record + at));

    /// Moves to the first glyph of the current record, skipping empty ranges.
    private void settle() scope
    {
        while (record_ < count_)
        {
            glyph_ = field(record_, 0);
            if (format_ == 1 || field(record_, 2) >= glyph_)
                return;
            ++record_;
        }
    }

    bool empty() const scope => record_ >= count_;

    CoveredGlyph front() const scope
    in (!empty)
    {
        if (format_ == 1)
            return CoveredGlyph(cast(ushort) glyph_, cast(uint) record_);
        return CoveredGlyph(cast(ushort) glyph_, field(record_, 4) + (glyph_ - field(record_, 0)));
    }

    void popFront() scope
    in (!empty)
    {
        if (format_ == 2 && glyph_ < field(record_, 2))
        {
            ++glyph_;
            return;
        }
        ++record_;
        settle();
    }

    typeof(this) save() const return scope => this;
}

///
@("coverage.CoveredGlyphs.order")
@safe pure nothrow @nogc
unittest
{
    static immutable ubyte[] bytes = [0, 2, 0, 2, 0, 10, 0, 11, 0, 0, 0, 20, 0, 20, 0, 2];
    auto g = Coverage.read(bytes, Tag("GSUB"), 0, 0).glyphs.value;
    static immutable CoveredGlyph[3] expected = [CoveredGlyph(10, 0), CoveredGlyph(11, 1), CoveredGlyph(20, 2)];
    size_t n;
    foreach (e; g)
        assert(e == expected[n++]);
    assert(n == 3);
}
