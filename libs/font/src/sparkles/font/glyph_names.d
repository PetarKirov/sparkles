/**
Glyph names from `post` and the `CFF` charset (FTP11, FTP30, FTP31).

`glyphName(face, gid)` answers one glyph without storage: a `post` version
2.0 lookup may scan the string data, and a `CFF` lookup parses the header,
the INDEX headers, the Top DICT and the charset. `glyphNameIndex` builds, in
caller storage, an index that makes each later lookup constant time.
Names are borrowed from the font or from static standard tables (FTP16).
*/
module sparkles.font.glyph_names;

import sparkles.font.bytes : be16, be32, fits, slice;
import sparkles.font.errors : FontError, FontErrorKind, FontLimit, FontResult, fontErr, fontOk, Tag, tableError;
import sparkles.font.face : Face, OutlineFormat;
import sparkles.font.std_names : cffStandardStrings, expertCharset, expertSubsetCharset, macGlyphNames;

@safe pure nothrow @nogc:

private enum Tag postTag = Tag("post"), cffTag = Tag("CFF ");

/// A glyph's name, or no name (FTP11).
struct GlyphName
{
    bool present;
    const(char)[] text;
}

private FontResult!GlyphName named(return scope const(char)[] text) => fontOk(GlyphName(true, text));
private FontResult!GlyphName unnamed() => fontOk(GlyphName(false, null));

// ---------------------------------------------------------------------------
// post
// ---------------------------------------------------------------------------

/// The parts of `post` a name lookup reads.
private struct PostNames
{
    const(ubyte)[] data;
    ulong start;
    uint version_;
    ushort count; // glyphs `post` itself describes (2.0, 2.5)
    size_t strings; // offset of the Pascal strings (2.0)
    bool arrayTruncated;
}

private FontResult!PostNames postNames(return scope const Face face)
{
    auto t = face.table(postTag);
    if (t.hasError)
        return fontErr!PostNames(t.error);
    PostNames p;
    p.data = t.value;
    p.start = face.record(face.find(postTag)).offset;
    if (p.data.length < 32)
        return fontErr!PostNames(tableError(FontErrorKind.truncated, postTag, p.start, p.data.length));
    p.version_ = be32(p.data, 0);
    if (p.version_ == 0x0002_0000 || p.version_ == 0x0002_5000)
    {
        if (p.data.length < 34)
            return fontErr!PostNames(tableError(FontErrorKind.truncated, postTag, p.start, 32));
        p.count = be16(p.data, 32);
        const entry = p.version_ == 0x0002_0000 ? 2 : 1;
        p.arrayTruncated = !fits(p.data.length, 34, ulong(entry) * p.count);
        p.strings = 34 + entry * p.count;
    }
    return fontOk(p);
}

/// The offset of Pascal string `k` in `post`, scanning from the first.
private FontResult!size_t postString(scope const PostNames p, size_t k)
{
    size_t at = p.strings;
    foreach (i; 0 .. k + 1)
    {
        if (at >= p.data.length)
            return fontErr!size_t(tableError(FontErrorKind.badValue, postTag, p.start, at));
        if (i == k)
        {
            if (!fits(p.data.length, at + 1, p.data[at]))
                return fontErr!size_t(tableError(FontErrorKind.truncated, postTag, p.start, at));
            return fontOk(at);
        }
        at += 1 + p.data[at];
    }
    assert(0);
}

/// The name `post` gives glyph `gid`, without the `CFF` fallback (FTP30).
private FontResult!GlyphName postName(return scope const PostNames p, uint gid)
{
    switch (p.version_)
    {
        case 0x0001_0000:
            return gid < 258 ? named(macGlyphNames[gid]) : unnamed();
        case 0x0002_0000:
        {
            if (gid >= p.count)
                return unnamed();
            if (p.arrayTruncated)
                return fontErr!GlyphName(tableError(FontErrorKind.truncated, postTag, p.start, 34));
            const index = be16(p.data, 34 + 2 * gid);
            if (index < 258)
                return named(macGlyphNames[index]);
            if (index >= 32_768)
                return fontErr!GlyphName(tableError(FontErrorKind.badValue, postTag, p.start, 34 + 2 * gid));
            const at = postString(p, index - 258);
            if (at.hasError)
                return fontErr!GlyphName(at.error);
            return named(cast(const(char)[]) slice(p.data, at.value + 1, p.data[at.value]));
        }
        case 0x0002_5000:
        {
            if (gid >= p.count)
                return unnamed();
            if (!fits(p.data.length, 34 + gid, 1))
                return fontErr!GlyphName(tableError(FontErrorKind.truncated, postTag, p.start, 34 + gid));
            const index = long(gid) + cast(byte) p.data[34 + gid];
            if (index < 0 || index > 257)
                return fontErr!GlyphName(tableError(FontErrorKind.badValue, postTag, p.start, 34 + gid));
            return named(macGlyphNames[cast(size_t) index]);
        }
        case 0x0003_0000:
            return unnamed();
        default:
            return fontErr!GlyphName(tableError(FontErrorKind.unsupportedVersion, postTag, p.start, 0));
    }
}

// ---------------------------------------------------------------------------
// CFF
// ---------------------------------------------------------------------------

/// A CFF INDEX: `count` objects whose bytes follow its offset array.
private struct CffIndex
{
    ubyte offSize;
    uint count;
    size_t offsets; // start of the offset array
    size_t data; // one byte before the first object, as CFF offsets are 1-based
    size_t end; // the byte after the INDEX
}

private uint readOffset(scope const(ubyte)[] d, size_t at, ubyte size)
{
    uint v;
    foreach (k; 0 .. size) v = (v << 8) | d[at + k];
    return v;
}

/// Reads the INDEX at `at`, checking its offsets lie inside the table.
private FontResult!CffIndex cffIndex(scope const(ubyte)[] d, ulong start, size_t at)
{
    if (!fits(d.length, at, 2))
        return fontErr!CffIndex(tableError(FontErrorKind.truncated, cffTag, start, at));
    CffIndex x;
    x.count = be16(d, at);
    if (x.count == 0)
    {
        x.end = at + 2;
        return fontOk(x);
    }
    if (!fits(d.length, at + 2, 1))
        return fontErr!CffIndex(tableError(FontErrorKind.truncated, cffTag, start, at + 2));
    x.offSize = d[at + 2];
    if (x.offSize < 1 || x.offSize > 4)
        return fontErr!CffIndex(tableError(FontErrorKind.badValue, cffTag, start, at + 2));
    x.offsets = at + 3;
    if (!fits(d.length, x.offsets, ulong(x.count + 1) * x.offSize))
        return fontErr!CffIndex(tableError(FontErrorKind.truncated, cffTag, start, x.offsets));
    x.data = x.offsets + (x.count + 1) * x.offSize - 1;
    const last = readOffset(d, x.offsets + x.count * x.offSize, x.offSize);
    if (last < 1 || !fits(d.length, x.data, last))
        return fontErr!CffIndex(tableError(FontErrorKind.badOffset, cffTag, start, x.offsets));
    x.end = x.data + last;
    return fontOk(x);
}

/// Object `i` of `x`, bounds checked.
private FontResult!(const(ubyte)[]) cffObject(return scope const(ubyte)[] d, ulong start, in CffIndex x, uint i)
{
    const a = readOffset(d, x.offsets + i * x.offSize, x.offSize);
    const b = readOffset(d, x.offsets + (i + 1) * x.offSize, x.offSize);
    if (a < 1 || b < a || !fits(d.length, x.data + a, b - a))
        return fontErr!(const(ubyte)[])(tableError(FontErrorKind.badOffset, cffTag, start, x.offsets));
    return fontOk(slice(d, x.data + a, b - a));
}

/// What the Top DICT says about names.
private struct TopDict
{
    bool cidKeyed;
    long charset; // offset, or 0, 1, 2 for the predefined charsets
}

/// Parses the operators of a Top DICT that name lookups need.
private FontResult!TopDict topDict(scope const(ubyte)[] dict, ulong start, ulong dictAt)
{
    TopDict t;
    long operand;
    size_t i;
    FontResult!TopDict bad() => fontErr!TopDict(tableError(FontErrorKind.badValue, cffTag, start, dictAt + i));
    while (i < dict.length)
    {
        const b0 = dict[i];
        if (b0 <= 21)
        {
            // An operator; 12 escapes a second byte.
            if (b0 == 12)
            {
                if (i + 1 >= dict.length) return bad();
                if (dict[i + 1] == 30) t.cidKeyed = true;
                i += 2;
            }
            else
            {
                if (b0 == 15) t.charset = operand;
                ++i;
            }
            operand = 0;
        }
        else if (b0 == 28)
        {
            if (i + 3 > dict.length) return bad();
            operand = cast(short)((dict[i + 1] << 8) | dict[i + 2]);
            i += 3;
        }
        else if (b0 == 29)
        {
            if (i + 5 > dict.length) return bad();
            operand = cast(int) be32(dict, i + 1);
            i += 5;
        }
        else if (b0 == 30)
        {
            // A real number: nibbles until one is 0xF.
            ++i;
            while (i < dict.length && (dict[i] & 0x0F) != 0x0F && (dict[i] >> 4) != 0x0F) ++i;
            if (i >= dict.length) return bad();
            ++i;
            operand = 0;
        }
        else if (b0 >= 32 && b0 <= 246) { operand = b0 - 139; ++i; }
        else if (b0 >= 247 && b0 <= 250)
        {
            if (i + 2 > dict.length) return bad();
            operand = (b0 - 247) * 256 + dict[i + 1] + 108;
            i += 2;
        }
        else if (b0 >= 251 && b0 <= 254)
        {
            if (i + 2 > dict.length) return bad();
            operand = -(b0 - 251) * 256 - dict[i + 1] - 108;
            i += 2;
        }
        else
            return bad();
    }
    return fontOk(t);
}

/// The parts of `CFF ` a name lookup reads, or `present = false`.
private struct CffNames
{
    bool present;
    const(ubyte)[] data;
    ulong start;
    CffIndex strings;
    long charset;
}

private FontResult!CffNames cffNames(return scope const Face face)
{
    if (face.outlines != OutlineFormat.cff || !face.has(cffTag))
        return fontOk(CffNames.init);
    auto t = face.table(cffTag);
    if (t.hasError)
        return fontErr!CffNames(t.error);
    CffNames c;
    c.data = t.value;
    c.start = face.record(face.find(cffTag)).offset;
    const d = c.data;
    if (d.length < 4)
        return fontErr!CffNames(tableError(FontErrorKind.truncated, cffTag, c.start, d.length));
    const names = cffIndex(d, c.start, d[2]);
    if (names.hasError)
        return fontErr!CffNames(names.error);
    if (names.value.count != 1)
        return fontErr!CffNames(tableError(FontErrorKind.badValue, cffTag, c.start, d[2]));
    const tops = cffIndex(d, c.start, names.value.end);
    if (tops.hasError)
        return fontErr!CffNames(tops.error);
    if (tops.value.count < 1)
        return fontErr!CffNames(tableError(FontErrorKind.badValue, cffTag, c.start, names.value.end));
    const strings = cffIndex(d, c.start, tops.value.end);
    if (strings.hasError)
        return fontErr!CffNames(strings.error);
    const dict = cffObject(d, c.start, tops.value, 0);
    if (dict.hasError)
        return fontErr!CffNames(dict.error);
    const top = topDict(dict.value, c.start, tops.value.data + 1);
    if (top.hasError)
        return fontErr!CffNames(top.error);
    if (top.value.cidKeyed)
        return fontOk(c); // CID-keyed: no names
    c.present = true;
    c.strings = strings.value;
    c.charset = top.value.charset;
    return fontOk(c);
}

/// The SID of glyph `gid` under the charset, or -1 when it has none.
private FontResult!long cffSid(in CffNames c, uint gid)
{
    if (gid == 0)
        return fontOk(0L);
    switch (c.charset)
    {
        case 0:
            return fontOk(gid <= 228 ? long(gid) : -1);
        case 1:
            return fontOk(gid < expertCharset.length ? long(expertCharset[gid]) : -1);
        case 2:
            return fontOk(gid < expertSubsetCharset.length ? long(expertSubsetCharset[gid]) : -1);
        default:
            break;
    }
    const d = c.data;
    if (c.charset < 0 || !fits(d.length, c.charset, 1))
        return fontErr!long(tableError(FontErrorKind.badOffset, cffTag, c.start, 0));
    const at = cast(size_t) c.charset;
    switch (d[at])
    {
        case 0:
            if (!fits(d.length, at + 1 + 2UL * (gid - 1), 2))
                return fontErr!long(tableError(FontErrorKind.truncated, cffTag, c.start, at + 1 + 2UL * (gid - 1)));
            return fontOk(long(be16(d, at + 1 + 2 * (gid - 1))));
        case 1, 2:
        {
            const wide = d[at] == 2;
            const step = wide ? 4 : 3;
            uint glyph = 1;
            size_t r = at + 1;
            while (true)
            {
                if (!fits(d.length, r, step))
                    return fontErr!long(tableError(FontErrorKind.truncated, cffTag, c.start, r));
                const first = be16(d, r);
                const left = wide ? be16(d, r + 2) : d[r + 2];
                if (gid <= glyph + left)
                    return fontOk(long(first) + (gid - glyph));
                glyph += left + 1;
                r += step;
            }
        }
        default:
            return fontErr!long(tableError(FontErrorKind.unsupportedVersion, cffTag, c.start, at));
    }
}

/// The text of `sid`, from the standard strings or the String INDEX.
private FontResult!GlyphName sidName(return scope const(ubyte)[] d, in CffNames c, long sid)
{
    if (sid < 0)
        return unnamed();
    if (sid < cffStandardStrings.length)
        return named(cffStandardStrings[cast(size_t) sid]);
    const k = sid - cffStandardStrings.length;
    if (k >= c.strings.count)
        return fontErr!GlyphName(tableError(FontErrorKind.badValue, cffTag, c.start, c.strings.offsets));
    const s = cffObject(d, c.start, c.strings, cast(uint) k);
    if (s.hasError)
        return fontErr!GlyphName(s.error);
    return named(cast(const(char)[]) s.value);
}

// ---------------------------------------------------------------------------
// Lookups
// ---------------------------------------------------------------------------

/**
The name of glyph `gid` (FTP30, FTP31): from `post`, else, for a glyph `post`
leaves unnamed, empty or in error, from the `CFF` charset; the `post` error is
returned when `CFF` has no name either.
*/
FontResult!GlyphName glyphName(return scope const Face face, uint gid)
{
    if (gid >= face.numGlyphs)
        return fontErr!GlyphName(FontError(FontErrorKind.indexOutOfRange, postTag));
    const hasPost = face.has(postTag);
    const p = hasPost ? postNames(face) : fontOk(PostNames.init);
    auto fromPost = !hasPost ? unnamed() : p.hasError ? fontErr!GlyphName(p.error) : postName(p.value, gid);
    if (fromPost.hasValue && fromPost.value.present && fromPost.value.text.length)
        return fromPost;
    const c = cffNames(face);
    if (c.hasValue && c.value.present)
    {
        const sid = cffSid(c.value, gid);
        if (sid.hasValue)
        {
            const name = sidName(c.value.data, c.value, sid.value);
            if (name.hasValue && name.value.present)
                return name;
        }
        else if (!fromPost.hasError)
            return fontErr!GlyphName(sid.error);
    }
    else if (c.hasError && !fromPost.hasError)
        return fontErr!GlyphName(c.error);
    return fromPost;
}

/// An entry of a `GlyphNameIndex`: the source in the top 3 bits, a value below.
private enum : uint
{
    sourceNone = 0,
    sourceMac = 1, // value: standard name index
    sourcePost = 2, // value: Pascal string number
    sourceSid = 3, // value: CFF SID
    sourceSlow = 4, // an error: look it up without the index for its details
}

private uint entry(uint source, ulong value) => (source << 29) | cast(uint) value;

/// Glyph names in O(1) per lookup, borrowing the face and caller storage (FTP30).
struct GlyphNameIndex
{
    @safe pure nothrow @nogc:

    private Face face_;
    private const(uint)[] scratch_;
    private PostNames post_;
    private CffNames cff_;

    /// The name of glyph `gid`, as `glyphName` would return it.
    FontResult!GlyphName opIndex(uint gid) const return scope
    {
        if (gid >= face_.numGlyphs)
            return fontErr!GlyphName(FontError(FontErrorKind.indexOutOfRange, postTag));
        const e = scratch_[gid];
        const value = e & 0x1FFF_FFFF;
        switch (e >> 29)
        {
            case sourceMac:
                return named(macGlyphNames[value]);
            case sourcePost:
            {
                const at = scratch_[face_.numGlyphs + value];
                return named(cast(const(char)[]) slice(post_.data, at + 1, post_.data[at]));
            }
            case sourceSid:
                return sidName(cff_.data, cff_, value);
            case sourceSlow:
                return glyphName(face_, gid);
            default:
                return unnamed();
        }
    }
}

/// The `scratch` length `glyphNameIndex` needs: `numGlyphs`, plus the stored `post` strings.
FontResult!size_t glyphNameIndexLength(scope const Face face)
{
    size_t strings;
    if (face.has(postTag))
    {
        const p = postNames(face);
        if (p.hasValue && p.value.version_ == 0x0002_0000 && !p.value.arrayTruncated)
            for (size_t at = p.value.strings; at < p.value.data.length; at += 1 + p.value.data[at])
                ++strings;
    }
    return fontOk(size_t(face.numGlyphs) + strings);
}

/**
Builds a `GlyphNameIndex` in `scratch` (FTP30, FTP31). `scratch` must hold at
least `glyphNameIndexLength` entries, or the result is `limitExceeded`. One
pass over the `post` strings and one walk of the `CFF` charset fill every
entry, so the cost is linear in those tables and the glyph count; it never
allocates.
*/
FontResult!GlyphNameIndex glyphNameIndex(return scope const Face face, return scope uint[] scratch)
{
    const needed = glyphNameIndexLength(face);
    if (scratch.length < needed.value)
        return fontErr!GlyphNameIndex(FontError(FontErrorKind.limitExceeded, postTag, 0,
            FontError.noTableOffset, FontLimit.none));
    const n = face.numGlyphs;
    const hasPost = face.has(postTag);
    const p = hasPost ? postNames(face) : fontOk(PostNames.init);
    const c = cffNames(face);
    GlyphNameIndex x;
    x.face_ = face;
    const postBroken = hasPost && p.hasError;
    size_t strings;
    if (hasPost && p.hasValue)
    {
        x.post_ = p.value;
        if (p.value.version_ == 0x0002_0000 && !p.value.arrayTruncated)
            for (size_t at = p.value.strings; at < p.value.data.length; at += 1 + p.value.data[at])
                scratch[n + strings++] = cast(uint) at;
    }

    // The post answer per glyph: an entry, or sourceNone to try CFF.
    uint fromPost(uint gid)
    {
        if (!hasPost) return entry(sourceNone, 0);
        if (postBroken) return entry(sourceSlow, 0);
        const q = x.post_;
        switch (q.version_)
        {
            case 0x0001_0000:
                return gid < 258 ? entry(sourceMac, gid) : entry(sourceNone, 0);
            case 0x0002_0000:
            {
                if (gid >= q.count) return entry(sourceNone, 0);
                if (q.arrayTruncated) return entry(sourceSlow, 0);
                const index = be16(q.data, 34 + 2 * gid);
                if (index < 258) return entry(sourceMac, index);
                const k = index - 258;
                if (index >= 32_768 || k >= strings) return entry(sourceSlow, 0);
                const at = scratch[n + k];
                if (!fits(q.data.length, at + 1, q.data[at])) return entry(sourceSlow, 0);
                // An empty name falls back to CFF.
                return q.data[at] ? entry(sourcePost, k) : entry(sourceNone, 0);
            }
            case 0x0002_5000:
            {
                if (gid >= q.count) return entry(sourceNone, 0);
                if (!fits(q.data.length, 34 + gid, 1)) return entry(sourceSlow, 0);
                const index = long(gid) + cast(byte) q.data[34 + gid];
                return index < 0 || index > 257 ? entry(sourceSlow, 0) : entry(sourceMac, index);
            }
            case 0x0003_0000:
                return entry(sourceNone, 0);
            default:
                return entry(sourceSlow, 0);
        }
    }

    if (c.hasValue)
        x.cff_ = c.value;
    // Walk a format-1/2 charset once, in glyph order.
    const d = x.cff_.data;
    const custom = x.cff_.present && x.cff_.charset > 2 && fits(d.length, x.cff_.charset, 1);
    const format = custom ? d[cast(size_t) x.cff_.charset] : 0;
    size_t rangeAt = custom ? cast(size_t) x.cff_.charset + 1 : 0;
    uint rangeGlyph = 1;
    long rangeFirst = -1, rangeLeft = -1;
    bool charsetBroken;
    long sidOf(uint gid)
    {
        if (!x.cff_.present || charsetBroken) return -1;
        if (!custom || format == 0 || gid == 0)
        {
            const s = cffSid(x.cff_, gid);
            return s.hasValue ? s.value : -1;
        }
        if (format != 1 && format != 2) return -1;
        const step = format == 2 ? 4 : 3;
        while (rangeFirst < 0 || gid > rangeGlyph + rangeLeft)
        {
            if (rangeFirst >= 0) { rangeGlyph += cast(uint) rangeLeft + 1; rangeAt += step; }
            if (!fits(d.length, rangeAt, step)) { charsetBroken = true; return -1; }
            rangeFirst = be16(d, rangeAt);
            rangeLeft = format == 2 ? be16(d, rangeAt + 2) : d[rangeAt + 2];
        }
        return rangeFirst + (gid - rangeGlyph);
    }

    foreach (gid; 0 .. n)
    {
        const e = fromPost(gid);
        if (e >> 29 == sourceMac || e >> 29 == sourcePost)
        {
            scratch[gid] = e;
            continue;
        }
        const sid = sidOf(gid);
        if (sid >= 0)
            scratch[gid] = entry(sourceSid, sid);
        else if (x.cff_.present && (charsetBroken || !c.hasValue))
            scratch[gid] = entry(sourceSlow, 0);
        else
            scratch[gid] = e;
    }
    x.scratch_ = scratch;
    return fontOk(x);
}
