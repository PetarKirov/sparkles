/**
The `GDEF` header and its item variation store (`docs/specs/font/variation-metrics.md`
FTM11, FTM14).

`MATH` and `GPOS` have no item variation store of their own: their
VariationIndex tables resolve against `GDEF`'s, which exists from version
1.3. `gdef` reads the header; `gdefVariationStore` is the store a
VariationIndex lookup uses, recording rather than returning a problem with
`GDEF`, so that only a value whose delta needs the store reports it (and at
the default coordinates, nothing does). Nothing here allocates.
*/
module sparkles.font.gdef;

import sparkles.font.bytes : be16, be32, fits;
import sparkles.font.corrections : Correction;
import sparkles.font.coverage : Coverage;
import sparkles.font.errors : FontError, FontErrorKind, FontResult, fontErr, fontOk, Tag, tableError;
import sparkles.font.face : Face;
import sparkles.font.tables : locate, Located, shortTable;
import sparkles.font.variations : ItemVariationStore;

@safe pure nothrow @nogc:

private enum gdefTag = Tag("GDEF");

/**
The `GDEF` header: major version 1; the mark glyph sets offset exists from
1.2 and the item variation store offset from 1.3.
*/
struct Gdef
{
    @safe pure nothrow @nogc:

    private ushort major_, minor_;
    private ItemVariationStore store_;

    /// The stored version.
    ushort majorVersion() const scope => major_;
    /// ditto
    ushort minorVersion() const scope => minor_;

    /**
    The item variation store: `present` only from version 1.3 with a non-null
    offset. A malformed store is recorded in it (`broken`).
    */
    ItemVariationStore variationStore() const return scope => store_;
}

/**
The face's `GDEF` header for a face of `fvarAxisCount` axes: `missingTable`
without one; `unsupportedVersion` for a major version other than 1;
`truncated` for a header past the table (12 bytes, 14 from 1.2, 18 from 1.3).
Costs O(1).
*/
FontResult!Gdef gdef(return scope const Face face, ushort fvarAxisCount)
{
    auto at = gdefTable(face);
    if (at.hasError)
        return fontErr!Gdef(at.error);
    const d = at.value.data;
    if (d.length < 4)
        return shortTable!Gdef(gdefTag, at.value, 4);
    Gdef g;
    g.major_ = be16(d, 0);
    g.minor_ = be16(d, 2);
    if (g.major_ != 1)
        return fontErr!Gdef(tableError(FontErrorKind.unsupportedVersion, gdefTag, at.value.start, 0));
    const needed = g.minor_ >= 3 ? 18 : g.minor_ == 2 ? 14 : 12;
    if (d.length < needed)
        return shortTable!Gdef(gdefTag, at.value, needed);
    if (g.minor_ >= 3)
    {
        const storeOffset = be32(d, 14);
        if (storeOffset != 0)
            g.store_ = ItemVariationStore.read(d, gdefTag, at.value.start, storeOffset, fvarAxisCount);
    }
    return fontOk(g);
}

/**
The item variation store `MATH` and `GPOS` VariationIndex tables use
(FTM11): `GDEF`'s, not `present` when the face has no `GDEF`, its version is
before 1.3, or its offset is null. Any other problem with `GDEF` is recorded
as a `broken` store, returned by the deltas that read it. Costs O(1).
*/
ItemVariationStore gdefVariationStore(return scope const Face face, ushort fvarAxisCount)
{
    const g = gdef(face, fvarAxisCount);
    if (g.hasValue)
        return g.value.variationStore;
    if (g.error.kind == FontErrorKind.missingTable)
        return ItemVariationStore.init;
    return ItemVariationStore.failed(g.error);
}

/**
The `GDEF` table, or `missingTable`, as for a face without one; also under
FTD10's correction, for a face whose `GDEF` HarfBuzz ignores, with the
correction named (FTD45). Every `GDEF` reading goes through here.
*/
package FontResult!Located gdefTable(return scope const Face face)
{
    if (face.corrections.has(Correction.blocklistedGdef))
    {
        auto e = FontError(FontErrorKind.missingTable, gdefTag);
        e.correction = Correction.blocklistedGdef;
        return fontErr!Located(e);
    }
    return locate(face, gdefTag);
}

/**
A class `GDEF` assigns a glyph (FTD10): `present` is false when the face has
no `GDEF` or no such class definition, and then `correction` names FTD10's
entry if that is why. A glyph the definition does not list has class 0.
*/
struct GdefClass
{
    @safe pure nothrow @nogc:

    bool present;
    ushort value;
    Correction correction;
}

/// The glyph class of `gid` (`GlyphClassDef`: 1 base, 2 ligature, 3 mark, 4 component). Costs O(log n).
FontResult!GdefClass glyphClass(scope const Face face, uint gid) => classAt(face, 4, gid);

/// The mark attachment class of `gid` (`MarkAttachClassDef`). Costs O(log n).
FontResult!GdefClass markAttachmentClass(scope const Face face, uint gid) => classAt(face, 10, gid);

/**
Whether mark glyph set `set` holds `gid`, as `value` 1 or 0 (`MarkGlyphSetsDef`,
version 1.2): absent before 1.2 or with a null offset; a set past the count
is `indexOutOfRange`. Costs O(log n).
*/
FontResult!GdefClass inMarkGlyphSet(scope const Face face, uint set, uint gid)
{
    const at = gdefTable(face);
    if (at.hasError)
        return absentOr(at.error);
    const d = at.value.data;
    const start = at.value.start;
    if (d.length < 4)
        return fontErr!GdefClass(tableError(FontErrorKind.truncated, gdefTag, start, d.length));
    if (be16(d, 2) < 2)
        return fontOk(GdefClass.init);
    if (d.length < 14)
        return fontErr!GdefClass(tableError(FontErrorKind.truncated, gdefTag, start, d.length));
    const setsAt = be16(d, 12);
    if (setsAt == 0)
        return fontOk(GdefClass.init);
    if (!fits(d.length, setsAt, 4))
        return fontErr!GdefClass(tableError(FontErrorKind.truncated, gdefTag, start, setsAt));
    const count = be16(d, setsAt + 2);
    if (set >= count)
        return fontErr!GdefClass(tableError(FontErrorKind.indexOutOfRange, gdefTag, start, setsAt + 2));
    if (!fits(d.length, setsAt + 4, 4UL * count))
        return fontErr!GdefClass(tableError(FontErrorKind.truncated, gdefTag, start, setsAt + 4));
    const coverage = Coverage.read(d, gdefTag, start, setsAt + be32(d, setsAt + 4 + 4 * set));
    const index = coverage.index(gid);
    if (index.hasError)
        return fontErr!GdefClass(index.error);
    return fontOk(GdefClass(true, index.value.covered ? 1 : 0));
}

/// A missing `GDEF` as an absent reading, carrying the correction that hid it; any other error as is.
private FontResult!GdefClass absentOr(FontError e)
{
    if (e.kind != FontErrorKind.missingTable)
        return fontErr!GdefClass(e);
    GdefClass c;
    c.correction = e.correction;
    return fontOk(c);
}

/// The class `gid` has in the ClassDef the header field at `field` points to.
private FontResult!GdefClass classAt(scope const Face face, size_t field, uint gid)
{
    const at = gdefTable(face);
    if (at.hasError)
        return absentOr(at.error);
    const d = at.value.data;
    const start = at.value.start;
    if (d.length < 12)
        return fontErr!GdefClass(tableError(FontErrorKind.truncated, gdefTag, start, d.length));
    const offset = be16(d, field);
    if (offset == 0)
        return fontOk(GdefClass.init);
    const v = classDefValue(d, gdefTag, start, offset, gid);
    if (v.hasError)
        return fontErr!GdefClass(v.error);
    return fontOk(GdefClass(true, v.value));
}

/**
The class of `gid` in the ClassDef at `at` of `d` (formats 1 and 2), 0 when
unlisted: format 1 by index, format 2 by binary search over its ranges.
Another format is `unsupportedVersion`. Costs O(log n).
*/
package FontResult!ushort classDefValue(scope const(ubyte)[] d, Tag tag, ulong start, size_t at, uint gid)
{
    if (!fits(d.length, at, 4))
        return fontErr!ushort(tableError(FontErrorKind.truncated, tag, start, at));
    const format = be16(d, at);
    if (format == 1)
    {
        if (!fits(d.length, at, 6))
            return fontErr!ushort(tableError(FontErrorKind.truncated, tag, start, at));
        const first = be16(d, at + 2);
        const count = be16(d, at + 4);
        if (!fits(d.length, at + 6, 2UL * count))
            return fontErr!ushort(tableError(FontErrorKind.truncated, tag, start, at + 6));
        if (gid < first || gid - first >= count)
            return fontOk(ushort(0));
        return fontOk(be16(d, at + 6 + 2 * (gid - first)));
    }
    if (format != 2)
        return fontErr!ushort(tableError(FontErrorKind.unsupportedVersion, tag, start, at));
    const ranges = be16(d, at + 2);
    if (!fits(d.length, at + 4, 6UL * ranges))
        return fontErr!ushort(tableError(FontErrorKind.truncated, tag, start, at + 4));
    size_t lo = 0, hi = ranges;
    while (lo < hi)
    {
        const mid = (lo + hi) / 2;
        const r = at + 4 + 6 * mid;
        if (be16(d, r + 2) < gid)
            lo = mid + 1;
        else
            hi = mid;
    }
    if (lo < ranges)
    {
        const r = at + 4 + 6 * lo;
        if (be16(d, r) <= gid && gid <= be16(d, r + 2))
            return fontOk(be16(d, r + 4));
    }
    return fontOk(ushort(0));
}
