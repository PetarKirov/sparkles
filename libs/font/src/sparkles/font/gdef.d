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

import sparkles.font.bytes : be16, be32;
import sparkles.font.errors : FontErrorKind, FontResult, fontErr, fontOk, Tag, tableError;
import sparkles.font.face : Face;
import sparkles.font.tables : locate, shortTable;
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
    auto at = locate(face, gdefTag);
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
