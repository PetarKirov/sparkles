/**
Opening faces and finding their tables (FTP1–FTP5, FTP18–FTP22, FTP33).

A `Face` is an immutable value over the caller's bytes: copying it copies a
slice and a few integers, and every slice it returns borrows those bytes. The
caller keeps the buffer alive while any face or result derived from it is in
use (FTA1); `-preview=dip1000` checks that in `@safe` code.
*/
module sparkles.font.face;

import sparkles.font.bytes : be16, be32, fits, slice;
import sparkles.font.errors : bufferError, FontError, FontErrorKind, FontLimit, FontResult,
    fontErr, fontOk, limitError, Tag, tableError;

@safe pure nothrow @nogc:

private enum : uint
{
    sigTrueType = 0x0001_0000,
    sigApple = 0x7472_7565, // 'true'
    sigCff = 0x4F54_544F, // 'OTTO'
    sigCollection = 0x7474_6366, // 'ttcf'
    sigWoff = 0x774F_4646, // 'wOFF'
    sigWoff2 = 0x774F_4632, // 'wOF2'
}

/// The most table records a directory may hold (FTP19).
enum maxTableRecords = 4_096;
/// The most faces a collection may hold (FTP2).
enum maxCollectionFaces = 65_535;
/// The most encoding records a `cmap` may hold (FTB3).
enum maxCmapRecords = 64;

/// The outline format a face's signature declares.
enum OutlineFormat : ubyte
{
    trueType,
    cff,
}

/// One table record as stored in the directory.
struct DirectoryRecord
{
    @safe pure nothrow @nogc:

    Tag tag;
    uint checksum;
    uint offset;
    uint length;
}

/// A directory record as inspection reports it (FTP33).
struct DirectoryEntry
{
    @safe pure nothrow @nogc:

    Tag tag;
    uint offset;
    uint length;
    uint storedChecksum;
    /// Whether offset plus length lies inside the buffer.
    bool readable;
    /// Whether an earlier record has the same tag; such a record is ignored.
    bool duplicate;
}

/// The directory's binary-search fields, stored and expected.
struct SearchFields
{
    @safe pure nothrow @nogc:

    ushort searchRange, entrySelector, rangeShift;
    ushort expectedSearchRange, expectedEntrySelector, expectedRangeShift;

    /// Whether the stored fields hold the values OpenType defines.
    bool matches() const scope => searchRange == expectedSearchRange
        && entrySelector == expectedEntrySelector && rangeShift == expectedRangeShift;
}

/// `head.checkSumAdjustment`, stored and computed over the whole file.
struct ChecksumAdjustment
{
    @safe pure nothrow @nogc:

    /// False for a face of a collection, where the check does not apply.
    bool applies;
    uint stored;
    uint expected;

    /// Whether the stored value matches.
    bool matches() const scope => !applies || stored == expected;
}

/// An open face: a borrowed, immutable view of one font (FTA1, FTA2).
struct Face
{
    @safe pure nothrow @nogc:

    private const(ubyte)[] data_;
    private size_t header_;
    private ushort numTables_;
    private bool sorted_;
    private bool inCollection_;
    private uint index_;
    private OutlineFormat outlines_;
    private ushort unitsPerEm_;
    private ushort numGlyphs_;

    /// The whole buffer the face was opened from.
    const(ubyte)[] bytes() const return scope => data_;
    /// `head.unitsPerEm`, checked nonzero at open.
    ushort unitsPerEm() const scope => unitsPerEm_;
    /// `maxp.numGlyphs`.
    ushort numGlyphs() const scope => numGlyphs_;
    /// The face's index in its collection, or 0.
    uint index() const scope => index_;
    /// Whether the face is a member of a collection.
    bool inCollection() const scope => inCollection_;
    /// The outline format the signature declares.
    OutlineFormat outlines() const scope => outlines_;
    /// The number of table records in the directory.
    ushort tableCount() const scope => numTables_;
    /// Whether the directory is sorted by tag, so lookups binary-search.
    bool sortedDirectory() const scope => sorted_;

    /// Record `i` of the directory, `i < tableCount`.
    DirectoryRecord record(size_t i) const scope
    in (i < numTables_)
    {
        const at = header_ + 12 + 16 * i;
        return DirectoryRecord(Tag(be32(data_, at)), be32(data_, at + 4), be32(data_, at + 8),
            be32(data_, at + 12));
    }

    /// The absolute offset of record `i` in the buffer.
    size_t recordOffset(size_t i) const scope => header_ + 12 + 16 * i;

    /// The index of the first record with `tag`, or `tableCount` when none.
    size_t find(Tag tag) const scope
    {
        if (sorted_)
        {
            size_t lo = 0, hi = numTables_;
            while (lo < hi)
            {
                const mid = lo + (hi - lo) / 2;
                if (record(mid).tag.value < tag.value) lo = mid + 1;
                else hi = mid;
            }
            // lo is already the first record not below `tag`.
            return lo < numTables_ && record(lo).tag == tag ? lo : numTables_;
        }
        foreach (i; 0 .. numTables_)
            if (record(i).tag == tag)
                return i;
        return numTables_;
    }

    /// The bytes of table `tag` (FTP22): `missingTable`, or `badOffset` when unreadable.
    FontResult!(const(ubyte)[]) table(Tag tag) const return scope
    {
        const i = find(tag);
        if (i == numTables_)
            return fontErr!(const(ubyte)[])(FontError(FontErrorKind.missingTable, tag));
        const r = record(i);
        if (!fits(data_.length, r.offset, r.length))
            return fontErr!(const(ubyte)[])(FontError(FontErrorKind.badOffset, tag,
                recordOffset(i) + 8));
        return fontOk(slice(data_, r.offset, r.length));
    }

    /// Whether the face has a readable or unreadable record for `tag`.
    bool has(Tag tag) const scope => find(tag) != numTables_;

    /// The directory, one entry per stored record (FTP33).
    Directory directory() const return scope => Directory(this, 0, numTables_);

    /// The checksum of record `i`'s table, `head` with its adjustment as zero.
    uint computedChecksum(size_t i) const scope
    in (i < numTables_)
    {
        const r = record(i);
        if (!fits(data_.length, r.offset, r.length))
            return 0;
        const zeroAt = r.tag == Tag("head") ? 8 : size_t.max;
        return sum32(slice(data_, r.offset, r.length), zeroAt);
    }

    /// The directory's search fields with their expected values.
    SearchFields searchFields() const scope
    {
        uint power = 1, log = 0;
        while (power * 2 <= numTables_) { power *= 2; ++log; }
        return SearchFields(be16(data_, header_ + 6), be16(data_, header_ + 8),
            be16(data_, header_ + 10), cast(ushort)(power * 16), cast(ushort) log,
            cast(ushort)(numTables_ * 16 - power * 16));
    }

    /// `head.checkSumAdjustment` against the whole file (FTP33).
    ChecksumAdjustment checksumAdjustment() const scope
    {
        if (inCollection_)
            return ChecksumAdjustment(false);
        const i = find(Tag("head"));
        // `head` was read at open, so its record is readable.
        const at = record(i).offset + 8;
        const stored = be32(data_, at);
        return ChecksumAdjustment(true, stored, 0xB1B0_AFBA - sum32(data_, at));
    }
}

/// The sum of big-endian words of `data`, zero-padded, with the word at `zeroAt` as zero.
private uint sum32(scope const(ubyte)[] data, size_t zeroAt)
{
    uint sum;
    for (size_t i = 0; i < data.length; i += 4)
    {
        if (i == zeroAt)
            continue;
        uint word;
        foreach (k; 0 .. 4)
            word = (word << 8) | (i + k < data.length ? data[i + k] : 0);
        sum += word;
    }
    return sum;
}

/// The directory as a random-access range of `DirectoryEntry` (FTP33).
struct Directory
{
    @safe pure nothrow @nogc:

    private Face face_;
    private size_t front_;
    private size_t back_;

    bool empty() const scope => front_ >= back_;
    size_t length() const scope => back_ - front_;
    DirectoryEntry front() const scope => entry(front_);
    DirectoryEntry back() const scope => entry(back_ - 1);
    void popFront() { ++front_; }
    void popBack() { --back_; }
    DirectoryEntry opIndex(size_t i) const scope => entry(front_ + i);
    typeof(this) save() return scope => this;

    /// Entry `i`; the duplicate flag scans earlier records, O(i).
    private DirectoryEntry entry(size_t i) const scope
    {
        const r = face_.record(i);
        bool duplicate;
        foreach (j; 0 .. i)
            if (face_.record(j).tag == r.tag)
            {
                duplicate = true;
                break;
            }
        return DirectoryEntry(r.tag, r.offset, r.length, r.checksum,
            fits(face_.bytes.length, r.offset, r.length), duplicate);
    }
}

/// A collection file, or a single font seen as a collection of one (FTP2).
struct Collection
{
    @safe pure nothrow @nogc:

    private const(ubyte)[] data_;
    private uint count_;

    /// The number of faces.
    uint count() const scope => count_;

    /// Face `i`, as `openFace(bytes, i)`.
    FontResult!Face face(uint i) const return scope => openFace(data_, i);
}

/// Opens the file as a collection; a single font has one face (FTP2).
FontResult!Collection openCollection(return scope const(ubyte)[] bytes)
{
    const sig = signature(bytes);
    if (sig.hasError)
        return fontErr!Collection(sig.error);
    if (sig.value != sigCollection)
        return fontOk(Collection(bytes, 1));
    const header = collectionHeader(bytes);
    if (header.hasError)
        return fontErr!Collection(header.error);
    return fontOk(Collection(bytes, header.value));
}

/// The first four bytes, refused when absent or not a font signature (FTP1).
private FontResult!uint signature(scope const(ubyte)[] bytes)
{
    if (bytes.length < 4)
        return fontErr!uint(bufferError(FontErrorKind.truncated, bytes.length));
    const sig = be32(bytes, 0);
    switch (sig)
    {
        case sigTrueType, sigApple, sigCff, sigCollection:
            return fontOk!uint(sig);
        case sigWoff, sigWoff2:
            return fontErr!uint(bufferError(FontErrorKind.unsupportedVersion, 0));
        default:
            return fontErr!uint(bufferError(FontErrorKind.notAFont, 0));
    }
}

/// A collection header's face count, checked (FTP2, FTP18).
private FontResult!uint collectionHeader(scope const(ubyte)[] bytes)
{
    if (bytes.length < 12)
        return fontErr!uint(bufferError(FontErrorKind.truncated, bytes.length));
    const major = be16(bytes, 4);
    if (major != 1 && major != 2)
        return fontErr!uint(bufferError(FontErrorKind.unsupportedVersion, 4));
    const count = be32(bytes, 8);
    if (count > maxCollectionFaces)
        return fontErr!uint(bufferError(FontErrorKind.badValue, 8));
    if (!fits(bytes.length, 12, 4UL * count))
        return fontErr!uint(bufferError(FontErrorKind.truncated, 12));
    return fontOk!uint(count);
}

/**
Opens face `index` of `bytes` (FTP18): detects the container, selects the
face, reads the directory, then checks `head`, `maxp` and the `cmap` header.
Costs O(r) for `r` directory records; never allocates (FTP20).
*/
FontResult!Face openFace(return scope const(ubyte)[] bytes, uint index = 0)
{
    const sig = signature(bytes);
    if (sig.hasError)
        return fontErr!Face(sig.error);

    Face face;
    face.data_ = bytes;
    face.index_ = index;
    if (sig.value == sigCollection)
    {
        const count = collectionHeader(bytes);
        if (count.hasError)
            return fontErr!Face(count.error);
        if (index >= count.value)
            return fontErr!Face(bufferError(FontErrorKind.indexOutOfRange, 8));
        face.inCollection_ = true;
        face.header_ = be32(bytes, 12 + 4 * index);
        if (!fits(bytes.length, face.header_, 4))
            return fontErr!Face(bufferError(FontErrorKind.truncated, 12 + 4 * index));
        const member = be32(bytes, face.header_);
        if (member != sigTrueType && member != sigApple && member != sigCff)
            return fontErr!Face(bufferError(FontErrorKind.notAFont, face.header_));
        face.outlines_ = member == sigCff ? OutlineFormat.cff : OutlineFormat.trueType;
    }
    else
    {
        if (index != 0)
            return fontErr!Face(bufferError(FontErrorKind.indexOutOfRange, 0));
        face.outlines_ = sig.value == sigCff ? OutlineFormat.cff : OutlineFormat.trueType;
    }

    // The directory: header, then records, all inside the buffer.
    if (!fits(bytes.length, face.header_, 12))
        return fontErr!Face(bufferError(FontErrorKind.truncated, face.header_));
    const numTables = be16(bytes, face.header_ + 4);
    if (numTables > maxTableRecords)
        return fontErr!Face(limitError(FontLimit.tableRecords, Tag.init, face.header_ + 4));
    if (!fits(bytes.length, face.header_ + 12, 16UL * numTables))
        return fontErr!Face(bufferError(FontErrorKind.truncated, face.header_ + 12));
    face.numTables_ = numTables;
    face.sorted_ = true;
    foreach (i; 1 .. numTables)
        if (face.record(i).tag.value < face.record(i - 1).tag.value)
        {
            face.sorted_ = false;
            break;
        }

    const head = face.table(Tag("head"));
    if (head.hasError)
        return fontErr!Face(head.error);
    const headStart = face.record(face.find(Tag("head"))).offset;
    if (head.value.length < 54)
        return fontErr!Face(tableError(FontErrorKind.truncated, Tag("head"), headStart,
            head.value.length));
    if (be16(head.value, 0) != 1)
        return fontErr!Face(tableError(FontErrorKind.unsupportedVersion, Tag("head"), headStart, 0));
    face.unitsPerEm_ = be16(head.value, 18);
    if (face.unitsPerEm_ == 0)
        return fontErr!Face(tableError(FontErrorKind.badValue, Tag("head"), headStart, 18));

    const maxp = face.table(Tag("maxp"));
    if (maxp.hasError)
        return fontErr!Face(maxp.error);
    const maxpStart = face.record(face.find(Tag("maxp"))).offset;
    if (maxp.value.length < 6)
        return fontErr!Face(tableError(FontErrorKind.truncated, Tag("maxp"), maxpStart,
            maxp.value.length));
    const maxpVersion = be32(maxp.value, 0);
    if (maxpVersion == 0x0001_0000 && maxp.value.length < 32)
        return fontErr!Face(tableError(FontErrorKind.truncated, Tag("maxp"), maxpStart,
            maxp.value.length));
    if (maxpVersion != 0x0000_5000 && maxpVersion != 0x0001_0000)
        return fontErr!Face(tableError(FontErrorKind.unsupportedVersion, Tag("maxp"), maxpStart, 0));
    face.numGlyphs_ = be16(maxp.value, 4);

    const cmap = face.table(Tag("cmap"));
    if (cmap.hasError)
        return fontErr!Face(cmap.error);
    const cmapStart = face.record(face.find(Tag("cmap"))).offset;
    if (cmap.value.length < 4)
        return fontErr!Face(tableError(FontErrorKind.truncated, Tag("cmap"), cmapStart,
            cmap.value.length));
    if (be16(cmap.value, 0) != 0)
        return fontErr!Face(tableError(FontErrorKind.unsupportedVersion, Tag("cmap"), cmapStart, 0));
    const records = be16(cmap.value, 2);
    if (records > maxCmapRecords)
        return fontErr!Face(limitError(FontLimit.cmapSubtables, Tag("cmap"), cmapStart + 2));
    if (!fits(cmap.value.length, 4, 8UL * records))
        return fontErr!Face(tableError(FontErrorKind.truncated, Tag("cmap"), cmapStart, 4));

    return fontOk(face);
}
