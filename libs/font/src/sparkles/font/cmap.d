/**
Character mapping (FTP9, FTP25–FTP27).

`charMap(face)` picks a `cmap` subtable in HarfBuzz's order, checks it once
and returns a `CharMap` value that answers lookups in O(log n) without
checking again. A subtable that fails its checks is skipped, counted and its
first error kept. Checks are lenient where real fonts are wrong, as in
FreeType: a subtable runs to the end of `cmap` whatever its `length` field
says, overlapping segments and groups take disjoint effective spans, and a
format-4 glyph-array target outside `cmap` reads as unmapped.
*/
module sparkles.font.cmap;

import sparkles.font.bytes : be16, be24, be32, bes16, fits;
import sparkles.font.errors : FontError, FontErrorKind, FontResult, fontErr, fontOk, Tag, tableError;
import sparkles.font.face : Face;
import sparkles.font.mac_roman : macRomanByUnicode, unicodeToMacRoman;

@safe pure nothrow @nogc:

/// How a `CharMap` turns a codepoint into a subtable key (FTP25).
enum CmapLookup : ubyte
{
    /// The codepoint itself.
    direct,
    /// Directly; U+0000–U+00FF also tried at U+F000 plus the codepoint.
    symbol,
    /// The codepoint's Mac Roman byte.
    macRoman,
    /// Codepoints up to U+007F only.
    ascii,
}

/// A format-14 answer (FTP27).
enum VariantKind : ubyte
{
    none,
    useDefault,
    glyph,
}

/// The result of `CharMap.variant`.
struct Variant
{
    VariantKind kind;
    ushort glyph;
}

/// An inclusive range of codepoints.
struct CodepointRange
{
    dchar first, last;
}

private enum Tag cmapTag = Tag("cmap");

/// A checked `cmap` subtable and how to look codepoints up in it.
struct CharMap
{
    @safe pure nothrow @nogc:

    private const(ubyte)[] cmap_;
    private ulong cmapStart_;
    private size_t sub_;
    private ushort format_, platform_, encoding_;
    private CmapLookup lookup_;
    private uint numGlyphs_;
    private uint count_; // segments (4), groups (12, 13) or entries (6)
    private uint firstCode_; // format 6
    private uint rejected_;
    private FontError firstRejection_;
    private uint outOfRange_, unmappedByTarget_;
    private bool hasVariants_;
    private bool variantsBroken_;
    private FontError variantsError_;
    private size_t variants_;
    private uint variantCount_;

    /// The chosen record's platform, encoding and subtable format.
    ushort platform() const scope => platform_;
    /// ditto
    ushort encoding() const scope => encoding_;
    /// ditto
    ushort format() const scope => format_;
    /// How codepoints become subtable keys.
    CmapLookup lookup() const scope => lookup_;
    /// The encoding records tried before this one and rejected.
    uint rejectedRecords() const scope => rejected_;
    /// The first rejected record's error, when `rejectedRecords > 0`.
    FontError firstRejection() const scope => firstRejection_;
    /// Mappings to a glyph ID not below `numGlyphs`, read as unmapped.
    uint outOfRangeMappings() const scope => outOfRange_;
    /// Codepoints a format-4 glyph-array target outside `cmap` leaves unmapped.
    uint unmappedByTarget() const scope => unmappedByTarget_;

    /// The glyph for `cp`, or 0 when unmapped (FTP27).
    uint glyph(dchar cp) const scope
    {
        final switch (lookup_)
        {
            case CmapLookup.direct:
                return direct(cp);
            case CmapLookup.symbol:
            {
                const g = direct(cp);
                return g || cp > 0xFF ? g : direct(0xF000 + cp);
            }
            case CmapLookup.macRoman:
            {
                const b = unicodeToMacRoman(cp);
                return b < 0 ? 0 : direct(b);
            }
            case CmapLookup.ascii:
                return cp <= 0x7F ? direct(cp) : 0;
        }
    }

    /// The mapped codepoints as sorted, merged, disjoint ranges (FTP27).
    CodepointRanges ranges() const return scope
    {
        auto r = CodepointRanges(this);
        r.advance();
        return r;
    }

    /// The format-14 answer for `cp` followed by `selector` (FTP27).
    FontResult!Variant variant(dchar cp, dchar selector) const scope
    {
        if (!hasVariants_)
            return fontOk(Variant(VariantKind.none));
        if (variantsBroken_)
            return fontErr!Variant(variantsError_);
        // Selector records: 11 bytes each, ascending (checked).
        size_t lo = 0, hi = variantCount_;
        while (lo < hi)
        {
            const mid = (lo + hi) / 2;
            if (be24(cmap_, variants_ + 10 + 11 * mid) < selector) lo = mid + 1;
            else hi = mid;
        }
        if (lo == variantCount_ || be24(cmap_, variants_ + 10 + 11 * lo) != selector)
            return fontOk(Variant(VariantKind.none));
        const record = variants_ + 10 + 11 * lo;
        const defaults = be32(cmap_, record + 3), nonDefaults = be32(cmap_, record + 7);
        if (defaults)
        {
            const t = variants_ + defaults;
            const n = be32(cmap_, t);
            size_t a = 0, b = n;
            while (a < b)
            {
                const mid = (a + b) / 2;
                const start = be24(cmap_, t + 4 + 4 * mid);
                if (start + cmap_[t + 4 + 4 * mid + 3] < cp) a = mid + 1;
                else b = mid;
            }
            if (a < n && be24(cmap_, t + 4 + 4 * a) <= cp)
                return fontOk(Variant(VariantKind.useDefault));
        }
        if (nonDefaults)
        {
            const t = variants_ + nonDefaults;
            const n = be32(cmap_, t);
            size_t a = 0, b = n;
            while (a < b)
            {
                const mid = (a + b) / 2;
                if (be24(cmap_, t + 4 + 5 * mid) < cp) a = mid + 1;
                else b = mid;
            }
            if (a < n && be24(cmap_, t + 4 + 5 * a) == cp)
            {
                const g = be16(cmap_, t + 4 + 5 * a + 3);
                return fontOk(g < numGlyphs_ ? Variant(VariantKind.glyph, g) : Variant(VariantKind.none));
            }
        }
        return fontOk(Variant(VariantKind.none));
    }

    // -- subtable access ----------------------------------------------------

    private uint direct(uint key) const scope
    {
        switch (format_)
        {
            case 0:
                return key < 256 ? cmap_[sub_ + 6 + key] : 0;
            case 4:
                return key <= 0xFFFF ? format4(key, findSegment(key)) : 0;
            case 6:
                if (key < firstCode_ || key - firstCode_ >= count_) return 0;
                return valid(be16(cmap_, sub_ + 10 + 2 * (key - firstCode_)));
            default: // 12, 13
                return group(key, findGroup(key));
        }
    }

    private uint valid(ulong g) const scope => g < numGlyphs_ ? cast(uint) g : 0;

    // Format 4 arrays.
    private uint segEnd(size_t i) const scope => be16(cmap_, sub_ + 14 + 2 * i);
    private uint segStart(size_t i) const scope => be16(cmap_, sub_ + 16 + 2 * count_ + 2 * i);
    private int segDelta(size_t i) const scope => bes16(cmap_, sub_ + 16 + 4 * count_ + 2 * i);
    private size_t segRangeAt(size_t i) const scope => sub_ + 16 + 6 * count_ + 2 * i;
    private uint segEffectiveStart(size_t i) const scope
    {
        const s = segStart(i);
        if (i == 0) return s;
        const previous = segEnd(i - 1) + 1;
        return s > previous ? s : previous;
    }

    /// The first segment whose end is at least `key`.
    private size_t findSegment(uint key) const scope
    {
        size_t lo = 0, hi = count_;
        while (lo < hi)
        {
            const mid = (lo + hi) / 2;
            if (segEnd(mid) < key) lo = mid + 1;
            else hi = mid;
        }
        return lo;
    }

    /// The raw format-4 glyph for `key` in segment `i`, before `numGlyphs`;
    /// `targetOut` reports a glyph-array target outside `cmap`.
    private uint format4Raw(uint key, size_t i, out bool targetOut) const scope
    {
        if (i >= count_ || key < segEffectiveStart(i) || key > segEnd(i))
            return 0;
        const rangeAt = segRangeAt(i);
        const rangeOffset = be16(cmap_, rangeAt);
        if (rangeOffset == 0)
            return (key + segDelta(i)) & 0xFFFF;
        const at = ulong(rangeAt) + rangeOffset + 2UL * (key - segStart(i));
        if (!fits(cmap_.length, at, 2))
        {
            targetOut = true;
            return 0;
        }
        const g = be16(cmap_, cast(size_t) at);
        return g ? (g + segDelta(i)) & 0xFFFF : 0;
    }

    private uint format4(uint key, size_t i) const scope
    {
        bool targetOut;
        return valid(format4Raw(key, i, targetOut));
    }

    // Formats 12 and 13: groups clamped to U+10FFFF.
    private uint groupStart(size_t i) const scope => be32(cmap_, sub_ + 16 + 12 * i);
    private uint groupEnd(size_t i) const scope
    {
        const e = be32(cmap_, sub_ + 16 + 12 * i + 4);
        return e > 0x10FFFF ? 0x10FFFF : e;
    }
    private uint groupGlyph(size_t i) const scope => be32(cmap_, sub_ + 16 + 12 * i + 8);
    private ulong groupEffectiveStart(size_t i) const scope
    {
        const s = groupStart(i);
        if (i == 0) return s;
        const previous = ulong(groupEnd(i - 1)) + 1;
        return s > previous ? s : previous;
    }

    private size_t findGroup(uint key) const scope
    {
        size_t lo = 0, hi = count_;
        while (lo < hi)
        {
            const mid = (lo + hi) / 2;
            if (groupEnd(mid) < key) lo = mid + 1;
            else hi = mid;
        }
        return lo;
    }

    /// The glyph ID group `i` maps `key` to, before `numGlyphs`, in 64 bits.
    private ulong groupRaw(uint key, size_t i) const scope
        => format_ == 12 ? ulong(groupGlyph(i)) + (key - groupStart(i)) : groupGlyph(i);

    private uint group(uint key, size_t i) const scope
    {
        if (i >= count_ || key < groupEffectiveStart(i) || key > groupEnd(i))
            return 0;
        return valid(groupRaw(key, i));
    }
}

/// The checks of FTP26 for the subtable at `offset` in `cmap`, filling `m`.
private FontResult!bool checkSubtable(ref CharMap m, scope const(ubyte)[] cmap, ulong start, ulong offset)
{
    if (!fits(cmap.length, offset, 2))
        return fontErr!bool(tableError(FontErrorKind.badOffset, cmapTag, start, offset));
    const sub = cast(size_t) offset;
    m.sub_ = sub;
    m.format_ = be16(cmap, sub);
    FontResult!bool fail(FontErrorKind kind, ulong at)
        => fontErr!bool(tableError(kind, cmapTag, start, at));
    switch (m.format_)
    {
        case 0:
            if (!fits(cmap.length, sub, 262)) return fail(FontErrorKind.truncated, sub);
            foreach (b; 0 .. 256)
                if (cmap[sub + 6 + b] >= m.numGlyphs_) ++m.outOfRange_;
            return fontOk(true);
        case 4:
            if (!fits(cmap.length, sub, 14)) return fail(FontErrorKind.truncated, sub);
            const segX2 = be16(cmap, sub + 6);
            if (segX2 == 0 || segX2 % 2) return fail(FontErrorKind.badValue, sub + 6);
            m.count_ = segX2 / 2;
            if (!fits(cmap.length, sub, 16 + 8UL * m.count_)) return fail(FontErrorKind.truncated, sub + 14);
            foreach (i; 0 .. m.count_)
            {
                if (m.segStart(i) > m.segEnd(i)) return fail(FontErrorKind.badValue, sub + 16 + 2 * m.count_ + 2 * i);
                if (i && m.segEnd(i) < m.segEnd(i - 1)) return fail(FontErrorKind.badValue, sub + 14 + 2 * i);
            }
            // Count over disjoint effective spans: at most 65,536 codepoints.
            foreach (i; 0 .. m.count_)
                foreach (key; m.segEffectiveStart(i) .. m.segEnd(i) + 1)
                {
                    bool targetOut;
                    const g = m.format4Raw(key, i, targetOut);
                    if (targetOut) ++m.unmappedByTarget_;
                    else if (g >= m.numGlyphs_) ++m.outOfRange_;
                }
            return fontOk(true);
        case 6:
            if (!fits(cmap.length, sub, 10)) return fail(FontErrorKind.truncated, sub);
            m.firstCode_ = be16(cmap, sub + 6);
            m.count_ = be16(cmap, sub + 8);
            if (m.firstCode_ + m.count_ > 0x10000) return fail(FontErrorKind.badValue, sub + 8);
            if (!fits(cmap.length, sub + 10, 2UL * m.count_)) return fail(FontErrorKind.truncated, sub + 10);
            foreach (i; 0 .. m.count_)
                if (be16(cmap, sub + 10 + 2 * i) >= m.numGlyphs_) ++m.outOfRange_;
            return fontOk(true);
        case 12, 13:
            if (!fits(cmap.length, sub, 16)) return fail(FontErrorKind.truncated, sub);
            const groups = be32(cmap, sub + 12);
            if (!fits(cmap.length, sub + 16, 12UL * groups)) return fail(FontErrorKind.truncated, sub + 16);
            m.count_ = groups;
            foreach (i; 0 .. groups)
            {
                const at = sub + 16 + 12 * i;
                if (be32(cmap, at) > be32(cmap, at + 4)) return fail(FontErrorKind.badValue, at);
                if (i && (be32(cmap, at) <= be32(cmap, at - 12) || be32(cmap, at + 4) < be32(cmap, at - 8)))
                    return fail(FontErrorKind.badValue, at);
            }
            foreach (i; 0 .. groups)
            {
                const first = m.groupEffectiveStart(i), last = m.groupEnd(i);
                if (first > last) continue;
                if (m.format_ == 13)
                {
                    if (m.groupGlyph(i) >= m.numGlyphs_) m.outOfRange_ += cast(uint)(last - first + 1);
                    continue;
                }
                // Glyphs groupGlyph + (key - start) for key in [first, last].
                const g0 = ulong(m.groupGlyph(i)) + (first - m.groupStart(i));
                const g1 = g0 + (last - first);
                const bad = g1 < m.numGlyphs_ ? 0 : g1 - (g0 > m.numGlyphs_ ? g0 : m.numGlyphs_) + 1;
                m.outOfRange_ += cast(uint) bad;
            }
            return fontOk(true);
        default:
            return fail(FontErrorKind.unsupportedVersion, sub);
    }
}

/// Checks the format-14 subtable at `offset` and records it on `m` (FTP27).
private void attachVariants(ref CharMap m, scope const(ubyte)[] cmap, ulong start, ulong offset)
{
    m.hasVariants_ = true;
    void broken(FontErrorKind kind, ulong at)
    {
        m.variantsBroken_ = true;
        m.variantsError_ = tableError(kind, cmapTag, start, at);
    }
    if (!fits(cmap.length, offset, 10)) return broken(FontErrorKind.truncated, offset);
    const sub = cast(size_t) offset;
    if (be16(cmap, sub) != 14) return broken(FontErrorKind.unsupportedVersion, sub);
    const records = be32(cmap, sub + 6);
    if (!fits(cmap.length, sub + 10, 11UL * records)) return broken(FontErrorKind.truncated, sub + 10);
    foreach (i; 0 .. records)
    {
        const r = sub + 10 + 11 * i;
        if (i && be24(cmap, r) <= be24(cmap, r - 11)) return broken(FontErrorKind.badValue, r);
        const defaults = be32(cmap, r + 3), nonDefaults = be32(cmap, r + 7);
        if (defaults)
        {
            const t = ulong(sub) + defaults;
            if (!fits(cmap.length, t, 4)) return broken(FontErrorKind.truncated, r + 3);
            const n = be32(cmap, cast(size_t) t);
            if (!fits(cmap.length, t + 4, 4UL * n)) return broken(FontErrorKind.truncated, t);
            foreach (k; 1 .. n)
                if (be24(cmap, cast(size_t)(t + 4 + 4 * k)) <= be24(cmap, cast(size_t)(t + 4 * k)))
                    return broken(FontErrorKind.badValue, t + 4 + 4 * k);
        }
        if (nonDefaults)
        {
            const t = ulong(sub) + nonDefaults;
            if (!fits(cmap.length, t, 4)) return broken(FontErrorKind.truncated, r + 7);
            const n = be32(cmap, cast(size_t) t);
            if (!fits(cmap.length, t + 4, 5UL * n)) return broken(FontErrorKind.truncated, t);
            foreach (k; 1 .. n)
                if (be24(cmap, cast(size_t)(t + 4 + 5 * k)) <= be24(cmap, cast(size_t)(t + 4 + 5 * (k - 1))))
                    return broken(FontErrorKind.badValue, t + 4 + 5 * k);
        }
    }
    m.variants_ = sub;
    m.variantCount_ = records;
}

/// The lookup an encoding record implies.
private CmapLookup lookupFor(uint platform, uint encoding)
    => platform == 3 && encoding == 0 ? CmapLookup.symbol
        : platform == 1 ? (encoding == 0 ? CmapLookup.macRoman : CmapLookup.ascii) : CmapLookup.direct;

/// Builds a `CharMap` from encoding record `i`, without fallback.
private FontResult!CharMap build(scope const Face face, return scope const(ubyte)[] cmap, ulong start, size_t i)
{
    CharMap m;
    m.cmap_ = cmap;
    m.cmapStart_ = start;
    m.numGlyphs_ = face.numGlyphs;
    m.platform_ = be16(cmap, 4 + 8 * i);
    m.encoding_ = be16(cmap, 6 + 8 * i);
    m.lookup_ = lookupFor(m.platform_, m.encoding_);
    const checked = checkSubtable(m, cmap, start, be32(cmap, 8 + 8 * i));
    if (checked.hasError)
        return fontErr!CharMap(checked.error);
    const records = be16(cmap, 2);
    foreach (k; 0 .. records)
        if (be16(cmap, 4 + 8 * k) == 0 && be16(cmap, 6 + 8 * k) == 5)
        {
            attachVariants(m, cmap, start, be32(cmap, 8 + 8 * k));
            break;
        }
    return fontOk(m);
}

/// The `cmap` table and its absolute start; open checked its header.
private struct CmapTable
{
    const(ubyte)[] data;
    ulong start;
}

private FontResult!CmapTable cmapOf(return scope const Face face)
{
    auto t = face.table(cmapTag);
    if (t.hasError)
        return fontErr!CmapTable(t.error);
    return fontOk(CmapTable(t.value, face.record(face.find(cmapTag)).offset));
}

/// The character map: the first qualifying subtable in HarfBuzz's order (FTP25).
FontResult!CharMap charMap(return scope const Face face)
{
    auto table = cmapOf(face);
    if (table.hasError)
        return fontErr!CharMap(table.error);
    const cmap = table.value.data;
    const start = table.value.start;
    static immutable ushort[2][9] order = [[3, 0], [3, 10], [0, 6], [0, 4], [3, 1], [0, 3], [0, 2], [0, 1], [0, 0]];
    const records = be16(cmap, 2);
    // The first record of each kind, in preference order.
    size_t[order.length + 2] candidates;
    size_t n;
    foreach (pe; order)
        foreach (i; 0 .. records)
            if (be16(cmap, 4 + 8 * i) == pe[0] && be16(cmap, 6 + 8 * i) == pe[1])
            {
                candidates[n++] = i;
                break;
            }
    // Macintosh Roman, then any other platform-1 record.
    foreach (i; 0 .. records)
        if (be16(cmap, 4 + 8 * i) == 1 && be16(cmap, 6 + 8 * i) == 0)
        {
            candidates[n++] = i;
            break;
        }
    foreach (i; 0 .. records)
        if (be16(cmap, 4 + 8 * i) == 1 && be16(cmap, 6 + 8 * i) != 0)
        {
            candidates[n++] = i;
            break;
        }
    uint rejected;
    FontError first;
    foreach (i; candidates[0 .. n])
    {
        auto attempt = build(face, cmap, start, i);
        if (attempt.hasValue)
        {
            auto m = attempt.value;
            m.rejected_ = rejected;
            m.firstRejection_ = first;
            return fontOk(m);
        }
        if (rejected++ == 0)
            first = attempt.error;
    }
    return fontErr!CharMap(FontError(FontErrorKind.unsupportedCapability, cmapTag, start));
}

/// A `CharMap` from encoding record `i` alone, with no fallback (FTP25).
FontResult!CharMap charMapAt(return scope const Face face, size_t i)
{
    auto table = cmapOf(face);
    if (table.hasError)
        return fontErr!CharMap(table.error);
    const cmap = table.value.data;
    const start = table.value.start;
    if (i >= be16(cmap, 2))
        return fontErr!CharMap(FontError(FontErrorKind.indexOutOfRange, cmapTag));
    return build(face, cmap, start, i);
}

/// The mapped codepoints of a `CharMap`, merged (FTP27).
struct CodepointRanges
{
    @safe pure nothrow @nogc:

    private CharMap map_;
    private ulong next_; // the next codepoint or index to examine
    private size_t cursor_; // format-4 segment cursor, or group index
    private CodepointRange front_;
    private bool empty_;

    bool empty() const scope => empty_;
    CodepointRange front() const scope => front_;
    void popFront() scope { advance(); }
    CodepointRanges save() return scope => this;

    private bool groupMode() const scope
        => (map_.format_ == 12 || map_.format_ == 13) && map_.lookup_ == CmapLookup.direct;

    /// The scan limit for codepoint-at-a-time modes.
    private uint limit() const scope
    {
        if (map_.lookup_ == CmapLookup.ascii) return 0x7F;
        if (map_.format_ == 0 && map_.lookup_ == CmapLookup.direct) return 0xFF;
        return map_.format_ == 12 || map_.format_ == 13 ? 0x10FFFF : 0xFFFF;
    }

    /// Whether `cp` maps, advancing the format-4 cursor monotonically.
    private bool mappedAt(uint cp) scope
    {
        if (map_.lookup_ == CmapLookup.direct && map_.format_ == 4)
        {
            while (cursor_ < map_.count_ && map_.segEnd(cursor_) < cp) ++cursor_;
            return map_.format4(cp, cursor_) != 0;
        }
        return map_.glyph(cp) != 0;
    }

    /// The valid span of group `i` as `[first, last]`, or empty.
    private bool groupSpan(size_t i, out ulong first, out ulong last) const scope
    {
        first = map_.groupEffectiveStart(i);
        last = map_.groupEnd(i);
        if (first > last) return false;
        if (map_.format_ == 13)
        {
            const g = map_.groupGlyph(i);
            return g != 0 && g < map_.numGlyphs_;
        }
        // Keys whose glyph groupGlyph + (key - start) lies in [1, numGlyphs - 1].
        const start = map_.groupStart(i), g0 = ulong(map_.groupGlyph(i));
        if (map_.numGlyphs_ < 2 || g0 > map_.numGlyphs_ - 1UL) return false;
        const lo = g0 >= 1 ? start : start + 1;
        const hi = ulong(start) + (map_.numGlyphs_ - 1UL - g0);
        if (lo > first) first = lo;
        if (hi < last) last = hi;
        return first <= last;
    }

    private void advance() scope
    {
        if (groupMode)
        {
            ulong first, last;
            while (cursor_ < map_.count_ && !groupSpan(cursor_, first, last)) ++cursor_;
            if (cursor_ >= map_.count_) { empty_ = true; return; }
            ++cursor_;
            ulong f, l;
            while (cursor_ < map_.count_ && groupSpan(cursor_, f, l) && f == last + 1)
            {
                last = l;
                ++cursor_;
            }
            front_ = CodepointRange(cast(dchar) first, cast(dchar) last);
            return;
        }
        if (map_.lookup_ == CmapLookup.macRoman)
        {
            // Index over the 256 Mac Roman scalars sorted by Unicode.
            while (next_ < 256 && map_.direct(macRomanByUnicode[cast(size_t) next_].mac) == 0) ++next_;
            if (next_ >= 256) { empty_ = true; return; }
            const first = macRomanByUnicode[cast(size_t) next_].unicode;
            dchar last = first;
            ++next_;
            while (next_ < 256 && macRomanByUnicode[cast(size_t) next_].unicode == last + 1
                && map_.direct(macRomanByUnicode[cast(size_t) next_].mac) != 0)
            {
                last = macRomanByUnicode[cast(size_t) next_].unicode;
                ++next_;
            }
            front_ = CodepointRange(first, last);
            return;
        }
        const top = limit();
        while (next_ <= top && !mappedAt(cast(uint) next_)) ++next_;
        if (next_ > top) { empty_ = true; return; }
        const first = cast(dchar) next_;
        while (next_ + 1 <= top && mappedAt(cast(uint)(next_ + 1))) ++next_;
        front_ = CodepointRange(first, cast(dchar) next_);
        ++next_;
    }
}
