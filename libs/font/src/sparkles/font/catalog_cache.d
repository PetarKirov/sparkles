/**
The persistent catalog (`docs/specs/font/discovery.md` FTD22–FTD24, SPEC.md
FTD3): the cache file's format, its decoding and encoding.

The file is `SPKFCAT\0`, a little-endian 32-bit format version, the
correction policy as one byte, the payload's length as a little-endian
64-bit integer, the payload, and the payload's 32-byte BLAKE3 hash. A file
that does not match in every part, or whose payload does not decode
completely, is discarded whole with the reason, never migrated or partly
read (FTD23). The format is this library's own; wired's Flat format replaces
it by a version change.

The payload holds, per file, its key (source label, identity, size,
modification time) and its records, the failures of its collection members,
or its own failure. Only `FontError` outcomes are cached; an I/O failure is
retried at the next build (FTD22). Nothing here uses the garbage collector.
*/
module sparkles.font.catalog_cache;

import sparkles.base.buffer : UniqueBuffer;
import sparkles.base.hash.blake3 : blake3;

import sparkles.font.cmap : CodepointRange;
import sparkles.font.corrections : Corrections, CorrectionPolicy, Correction;
import sparkles.font.errors : FontError, FontErrorKind, FontLimit, Tag;
import sparkles.font.face : OutlineFormat;
import sparkles.font.face_record : AxisRecord, FaceRecord, FieldError, PoolSpan, RecordField, RecordPools,
    StringRef;
import sparkles.font.tables : Spacing;

@safe nothrow @nogc:

/// The cache file's magic.
immutable ubyte[8] cacheMagic = ['S', 'P', 'K', 'F', 'C', 'A', 'T', 0];
/// The cache format's version; any change to a record's fields or their meaning changes it (FTD23).
enum uint cacheFormatVersion = 1;

/// Why a cache was discarded (FTD23); `none` when it was used.
enum CacheDiscard : ubyte
{
    none,
    magic,
    version_,
    policy,
    length,
    hash,
    structure,
    /// The file could not be read; reported with its I/O error.
    unreadable,
}

/// A collection member that did not open, and why.
struct CachedFailure
{
    uint index;
    FontError error;
}

/// One file of a cache: its key and what describing it gave.
struct CachedFile
{
    StringRef label, identity;
    ulong size;
    long modifiedNs;
    bool hasModified;
    /// The file's own failure, when `failed`.
    bool failed;
    FontError error;
    /// Its records and member failures.
    PoolSpan records, failures;
}

/// A decoded cache, or an empty one and why (FTD23).
struct CacheContents
{
    @safe nothrow @nogc:

    RecordPools pools;
    UniqueBuffer!FaceRecord records;
    UniqueBuffer!CachedFailure failures;
    UniqueBuffer!CachedFile files;
    CacheDiscard discarded;
    private UniqueBuffer!uint slots_; // file index + 1 by key hash; 0 is empty

    @disable this(this);

    /**
    The file whose key matches, or `size_t.max` (FTD22): the same label and
    identity, size and modification time. Costs O(1) expected.
    */
    size_t find(scope const(char)[] label, scope const(char)[] identity, ulong size, long modifiedNs,
        bool hasModified) const scope
    {
        if (slots_.length == 0)
            return size_t.max;
        const mask = slots_.length - 1;
        for (size_t at = keyHash(label, identity) & mask; slots_[at]; at = (at + 1) & mask)
        {
            const i = slots_[at] - 1;
            const f = files[i];
            if (pools.text(f.label) == label && pools.text(f.identity) == identity && f.size == size
                    && f.hasModified == hasModified && (!hasModified || f.modifiedNs == modifiedNs))
                return i;
        }
        return size_t.max;
    }

    /// Indexes `files` for `find`.
    void index() scope
    {
        size_t size = 64;
        while (size < 2 * files.length)
            size *= 2;
        slots_.clear(false);
        foreach (_; 0 .. size)
            slots_.put(0);
        foreach (i, f; files[])
        {
            size_t at = keyHash(pools.text(f.label), pools.text(f.identity)) & (size - 1);
            while (slots_[at])
                at = (at + 1) & (size - 1);
            slots_[at] = cast(uint)(i + 1);
        }
    }
}

private size_t keyHash(scope const(char)[] label, scope const(char)[] identity) pure
{
    ulong h = 0xcbf2_9ce4_8422_2325;
    foreach (c; label)
        h = (h ^ c) * 0x100_0000_01b3;
    h = (h ^ 0xFF) * 0x100_0000_01b3;
    foreach (c; identity)
        h = (h ^ c) * 0x100_0000_01b3;
    return cast(size_t) h;
}

// ---------------------------------------------------------------------------
// Encoding
// ---------------------------------------------------------------------------

/// Appends little-endian integers and length-prefixed strings.
private struct Writer
{
    @safe nothrow @nogc:

    UniqueBuffer!ubyte* out_;

    void u8(uint v) scope pure { out_.put(cast(ubyte) v); }
    void u16(uint v) scope pure { u8(v); u8(v >> 8); }
    void u32(uint v) scope pure { u16(v); u16(v >> 16); }
    void u64(ulong v) scope pure { u32(cast(uint) v); u32(cast(uint)(v >> 32)); }
    void str(scope const(char)[] s) scope pure
    {
        u32(cast(uint) s.length);
        out_.put(cast(const(ubyte)[]) s);
    }
    void error(in FontError e) scope pure
    {
        u8(e.kind);
        u32(e.tag.value);
        u64(e.offset);
        u64(e.tableOffset);
        u8(e.limit);
        u64(e.needed);
        u8(e.correction);
    }
}

/**
A cache file holding `files`, whose records and failures are in `records`,
`failures` and `pools`, under `policy` (FTD23), appended to `out_`.
*/
void encodeCache(scope const(CachedFile)[] files, scope const(FaceRecord)[] records,
    scope const(CachedFailure)[] failures, ref const RecordPools pools, CorrectionPolicy policy,
    ref UniqueBuffer!ubyte out_)
{
    UniqueBuffer!ubyte payload;
    auto w = Writer(&payload);
    w.u32(cast(uint) files.length);
    foreach (f; files)
    {
        w.str(pools.text(f.label));
        w.str(pools.text(f.identity));
        w.u64(f.size);
        w.u64(f.modifiedNs);
        w.u8(f.hasModified);
        w.u8(f.failed);
        if (f.failed)
        {
            w.error(f.error);
            continue;
        }
        w.u32(f.failures.count);
        foreach (x; failures[f.failures.offset .. f.failures.offset + f.failures.count])
        {
            w.u32(x.index);
            w.error(x.error);
        }
        w.u32(f.records.count);
        foreach (ref r; records[f.records.offset .. f.records.offset + f.records.count])
            writeRecord(w, r, pools);
    }
    out_.put(cacheMagic[]);
    auto h = Writer(&out_);
    h.u32(cacheFormatVersion);
    h.u8(policy);
    h.u64(payload.length);
    out_.put(payload[]);
    const digest = blake3(payload[]);
    out_.put(digest[]);
}

private void writeRecord(scope ref Writer w, in FaceRecord r, ref const RecordPools pools)
{
    w.u32(r.index);
    w.str(pools.text(r.family));
    w.str(pools.text(r.styleName));
    w.str(pools.text(r.fullName));
    w.str(pools.text(r.postScriptName));
    const aliases = pools.aliasesOf(r);
    w.u32(cast(uint) aliases.length);
    foreach (a; aliases)
        w.str(pools.text(a));
    w.u8(r.truncatedNames);
    const int[8] ranges = [r.weightMin, r.weightMax, r.widthMin, r.widthMax, r.italicMin, r.italicMax,
        r.obliqueMin, r.obliqueMax];
    foreach (v; ranges)
        w.u32(v);
    w.u8(r.hasItalAxis | r.hasSlntAxis << 1 | r.hasWghtAxis << 2 | r.hasWdthAxis << 3
        | r.spacingKnown << 4 | r.glyph0Substitutable << 5);
    w.u8(r.spacing);
    const coverage = pools.coverageOf(r);
    w.u32(cast(uint) coverage.length);
    foreach (c; coverage)
    {
        w.u32(c.first);
        w.u32(c.last);
    }
    w.u8(r.colourFormats);
    const axes = pools.axesOf(r);
    w.u32(cast(uint) axes.length);
    foreach (a; axes)
    {
        w.u32(a.tag.value);
        w.u32(a.minValue);
        w.u32(a.defaultValue);
        w.u32(a.maxValue);
    }
    w.u8(r.corrections.bits);
    w.u8(r.outlines);
    w.u16(r.unitsPerEm);
    w.u16(r.numGlyphs);
    const errors = pools.errorsOf(r);
    w.u32(cast(uint) errors.length);
    foreach (e; errors)
    {
        w.u8(e.field);
        w.error(e.error);
    }
}

// ---------------------------------------------------------------------------
// Decoding
// ---------------------------------------------------------------------------

/// Reads little-endian integers and strings, recording any overrun.
private struct Reader
{
    @safe nothrow @nogc:

    const(ubyte)[] data;
    size_t at;
    bool bad;

    private bool need(size_t n) scope pure
    {
        if (bad || data.length - at < n)
        {
            bad = true;
            return false;
        }
        return true;
    }
    uint u8() scope pure => need(1) ? data[at++] : 0;
    uint u16() scope pure { const lo = u8(); return lo | u8() << 8; }
    uint u32() scope pure { const lo = u16(); return lo | u16() << 16; }
    ulong u64() scope pure { const lo = u32(); return lo | ulong(u32()) << 32; }
    StringRef str(ref RecordPools pools) scope pure
    {
        const n = u32();
        if (!need(n))
            return StringRef.init;
        const s = pools.add(cast(const(char)[]) data[at .. at + n]);
        at += n;
        return s;
    }
    FontError error() scope pure
    {
        FontError e;
        const kind = u8();
        bad |= kind > FontErrorKind.max;
        e.kind = cast(FontErrorKind)(kind > FontErrorKind.max ? 0 : kind);
        e.tag = Tag(u32());
        e.offset = u64();
        e.tableOffset = u64();
        const limit = u8();
        bad |= limit > FontLimit.max;
        e.limit = cast(FontLimit)(limit > FontLimit.max ? 0 : limit);
        e.needed = u64();
        const c = u8();
        bad |= c > Correction.max;
        e.correction = cast(Correction)(c > Correction.max ? 0 : c);
        return e;
    }
    /// A count of elements of at least `size` bytes each, refused when the data cannot hold them.
    uint count(size_t size) scope pure
    {
        const n = u32();
        if (!bad && n > (data.length - at) / size)
            bad = true;
        return bad ? 0 : n;
    }
}

/**
Decodes cache file `bytes` built under `policy` into `contents`, or leaves it
empty with `discarded` set (FTD23). Costs O(size).
*/
void decodeCache(scope const(ubyte)[] bytes, CorrectionPolicy policy, ref CacheContents contents)
{
    contents.discarded = decodeInto(bytes, policy, contents);
    if (contents.discarded != CacheDiscard.none)
    {
        contents.files.clear();
        contents.records.clear();
        contents.failures.clear();
    }
    contents.index();
}

private CacheDiscard decodeInto(scope const(ubyte)[] bytes, CorrectionPolicy policy, ref CacheContents c)
{
    enum header = 8 + 4 + 1 + 8;
    if (bytes.length < 8 || bytes[0 .. 8] != cacheMagic[])
        return CacheDiscard.magic;
    auto h = Reader(bytes, 8);
    const version_ = h.u32();
    if (h.bad || version_ != cacheFormatVersion)
        return CacheDiscard.version_;
    const storedPolicy = h.u8();
    if (h.bad || storedPolicy != policy)
        return CacheDiscard.policy;
    const length = h.u64();
    if (h.bad || bytes.length - header < 32 || length != bytes.length - header - 32)
        return CacheDiscard.length;
    const payload = bytes[header .. header + cast(size_t) length];
    if (blake3(payload) != bytes[$ - 32 .. $])
        return CacheDiscard.hash;

    auto r = Reader(payload);
    const files = r.count(1);
    foreach (_; 0 .. files)
    {
        CachedFile f;
        f.label = r.str(c.pools);
        f.identity = r.str(c.pools);
        f.size = r.u64();
        f.modifiedNs = cast(long) r.u64();
        f.hasModified = r.u8() != 0;
        f.failed = r.u8() != 0;
        if (f.failed)
            f.error = r.error();
        else
        {
            const nf = r.count(4);
            f.failures.offset = cast(uint) c.failures.length;
            foreach (__; 0 .. nf)
            {
                const index = r.u32();
                c.failures.put(CachedFailure(index, r.error()));
            }
            f.failures.count = nf;
            const nr = r.count(4);
            f.records.offset = cast(uint) c.records.length;
            foreach (__; 0 .. nr)
            {
                FaceRecord rec;
                readRecord(r, rec, c.pools);
                rec.identity = f.identity;
                rec.fileSize = f.size;
                rec.modifiedNs = f.modifiedNs;
                rec.hasModified = f.hasModified;
                c.records.put(rec);
            }
            f.records.count = nr;
        }
        if (r.bad)
            return CacheDiscard.structure;
        c.files.put(f);
    }
    return r.bad || r.at != payload.length ? CacheDiscard.structure : CacheDiscard.none;
}

private void readRecord(scope ref Reader r, ref FaceRecord rec, ref RecordPools pools)
{
    rec.index = r.u32();
    rec.family = r.str(pools);
    rec.styleName = r.str(pools);
    rec.fullName = r.str(pools);
    rec.postScriptName = r.str(pools);
    const aliases = r.count(4);
    rec.aliases.offset = cast(uint) pools.aliases.length;
    foreach (_; 0 .. aliases)
        pools.aliases.put(r.str(pools));
    rec.aliases.count = aliases;
    rec.truncatedNames = cast(ubyte) r.u8();
    rec.weightMin = r.u32();
    rec.weightMax = r.u32();
    rec.widthMin = r.u32();
    rec.widthMax = r.u32();
    rec.italicMin = r.u32();
    rec.italicMax = r.u32();
    rec.obliqueMin = r.u32();
    rec.obliqueMax = r.u32();
    const flags = r.u8();
    rec.hasItalAxis = (flags & 1) != 0;
    rec.hasSlntAxis = (flags & 2) != 0;
    rec.hasWghtAxis = (flags & 4) != 0;
    rec.hasWdthAxis = (flags & 8) != 0;
    rec.spacingKnown = (flags & 16) != 0;
    rec.glyph0Substitutable = (flags & 32) != 0;
    const spacing = r.u8();
    r.bad |= spacing > Spacing.max;
    rec.spacing = cast(Spacing)(spacing > Spacing.max ? 0 : spacing);
    const ranges = r.count(8);
    rec.coverage.offset = cast(uint) pools.ranges.length;
    foreach (_; 0 .. ranges)
    {
        const first = r.u32(), last = r.u32();
        r.bad |= first > last || last > 0x10FFFF;
        pools.ranges.put(CodepointRange(cast(dchar) first, cast(dchar) last));
    }
    rec.coverage.count = ranges;
    rec.colourFormats = cast(ubyte) r.u8();
    const axes = r.count(16);
    rec.axes.offset = cast(uint) pools.axes.length;
    foreach (_; 0 .. axes)
    {
        const tag = Tag(r.u32());
        const lo = r.u32(), def = r.u32(), hi = r.u32();
        pools.axes.put(AxisRecord(tag, lo, def, hi));
    }
    rec.axes.count = axes;
    rec.corrections = Corrections.fromBits(cast(ubyte) r.u8());
    const outlines = r.u8();
    r.bad |= outlines > OutlineFormat.max;
    rec.outlines = cast(OutlineFormat)(outlines > OutlineFormat.max ? 0 : outlines);
    rec.unitsPerEm = cast(ushort) r.u16();
    rec.numGlyphs = cast(ushort) r.u16();
    const errors = r.count(1);
    rec.errors.offset = cast(uint) pools.errors.length;
    foreach (_; 0 .. errors)
    {
        const field = r.u8();
        r.bad |= field > RecordField.max;
        pools.errors.put(FieldError(cast(RecordField)(field > RecordField.max ? 0 : field), r.error()));
    }
    rec.errors.count = errors;
}
