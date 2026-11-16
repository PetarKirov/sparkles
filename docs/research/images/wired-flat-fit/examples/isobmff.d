#!/usr/bin/env dub
/+ dub.sdl:
    name "images_wired_isobmff"
    dependency "sparkles:wired" path="../../../../.."
    dflags "-preview=in" "-preview=dip1000"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
 * The ISOBMFF box structure that AVIF and HEIF use, on the
 * `sparkles:wired` that ships today.
 *
 * The fixed parts (the 8-byte box header, the FullBox version and flags,
 * `ftyp`, `hdlr`, `infe` version 2, `ispe`) are plain D structs read and
 * written by the schema walk of `png-chunks.d`. Everything else is
 * hand-written D, marked `GAP`: the 64-bit `largesize` when `size` is 1,
 * `size` 0 meaning "to the end of the file", the `uuid` extended type,
 * nesting inside a parent's declared size, version-dependent field widths
 * (`pitm`, `iinf`, `iloc`, `ipma`), `iloc`'s 4-bit size fields that set the
 * width of later fields, `ipma`'s 7- or 15-bit property indices with an
 * essential bit, and the references by item ID and by property index that
 * tie `pitm`, `iinf`, `iloc`, `ipco` and `ipma` together. On encode, every
 * box size and every `iloc` offset is back-patched by hand.
 *
 * Backs ../index.md (section "ISOBMFF"). Run with:
 * `dub run --single isobmff.d`
 */
module images_wired_isobmff;

import std.format : format;
import std.stdio : writefln;
import std.traits : EnumMembers, OriginalType;

import sparkles.base.expected : Expected, err, ok;
import sparkles.wired.policy : isBetween, isOneOf, WireCheck, wireCheckFailures;
import sparkles.wired.schema : NodeKind, ScalarKind, WireSchema, wireSchemaOf;

// ---------------------------------------------------------------------------
// A big-endian, fixed-layout walk over the shipped schema (same in all three
// programs of this experiment)
// ---------------------------------------------------------------------------

/// Byte size of the subtree at `index`, or -1 when the schema gives none.
/// Takes the schema by value: as an `in` parameter, CTFE fails on DMD and crashes LDC.
long fixedSize(const WireSchema schema, size_t index) @safe pure nothrow
{
    const node = schema.nodes[index];
    switch (node.kind)
    {
    case NodeKind.scalar:
        return node.scalarKind == ScalarKind.unsignedInteger
            || node.scalarKind == ScalarKind.signedInteger
            || node.scalarKind == ScalarKind.character
            ? node.scalarBits / 8 : -1;
    case NodeKind.enumeration:
        return node.scalarBits ? node.scalarBits / 8 : -1;
    case NodeKind.staticArray:
        const element = fixedSize(schema, schema.edges[node.firstEdge]);
        return element < 0 ? -1 : element * cast(long) node.staticLength;
    case NodeKind.aggregate:
        long total;
        foreach (edge; schema.edges[node.firstEdge .. node.firstEdge + node.edgeCount])
        {
            const field = fixedSize(schema, edge);
            if (field < 0)
                return -1;
            total += field;
        }
        return total;
    default:
        return -1; // sequences, maps, unions, strings: the schema has no size
    }
}

/// Format marker. Its schema hook admits only fixed-size shapes; the byte
/// order is a property of the marker, since `SchemaNode` has no such field.
struct BeFixed
{
    template validateWireSchema(T, alias schema)
    {
        enum bool validateWireSchema = fixedSize(schema, 0) >= 0;
    }
}

enum BinErrorKind : ubyte
{
    none,
    truncated,
    notAMember,
    checkFailed,
    badSize,
    badVersion,
    badReference,
    duplicate,
}

struct BinError
{
    BinErrorKind kind;
    size_t offset;
    string what;
}

alias BinResult(T) = Expected!(T, BinError);

ulong readBe(in ubyte[] bytes, size_t at, size_t width) @safe pure nothrow @nogc
{
    ulong value;
    foreach (b; bytes[at .. at + width])
        value = (value << 8) | b;
    return value;
}

/// Reads schema node `index` into `value`, in lockstep with the D type.
BinError readNode(V, alias schema, size_t index)(ref V value, in ubyte[] bytes,
    ref size_t pos, string path)
{
    enum node = schema.nodes[index];
    static if (node.kind == NodeKind.aggregate)
    {
        static foreach (i; 0 .. V.tupleof.length)
        {{
            enum child = schema.edges[node.firstEdge + i];
            const fieldPath = path.length ? path ~ "." ~ schema.nodes[child].name : schema.nodes[child].name;
            const fieldStart = pos;
            auto e = readNode!(typeof(V.tupleof[i]), schema, child)(value.tupleof[i], bytes, pos, fieldPath);
            if (e.kind != BinErrorKind.none)
                return e;
            auto failures = wireCheckFailures!(BeFixed, V.tupleof[i])(value.tupleof[i]);
            if (failures.length)
                return BinError(BinErrorKind.checkFailed, fieldStart, fieldPath ~ ": " ~ failures[0].reason);
        }}
        return BinError.init;
    }
    else static if (node.kind == NodeKind.staticArray)
    {
        enum child = schema.edges[node.firstEdge];
        foreach (k; 0 .. node.staticLength)
        {
            auto e = readNode!(typeof(value[0]), schema, child)(value[k], bytes, pos, path);
            if (e.kind != BinErrorKind.none)
                return e;
        }
        return BinError.init;
    }
    else static if (node.kind == NodeKind.enumeration)
    {
        const raw = cast(OriginalType!V) readBe(bytes, pos, node.scalarBits / 8);
        static foreach (member; EnumMembers!V)
            if (raw == member)
            {
                value = member;
                pos += node.scalarBits / 8;
                return BinError.init;
            }
        return BinError(BinErrorKind.notAMember, pos, path);
    }
    else
    {
        value = cast(V) readBe(bytes, pos, node.scalarBits / 8);
        pos += node.scalarBits / 8;
        return BinError.init;
    }
}

/// Decodes a fixed record at `at`: one bounds check, the schema walk with
/// field checks, then the type-level `@WireCheck`s.
BinResult!T decodeFixed(T)(in ubyte[] bytes, size_t at)
{
    enum schema = wireSchemaOf!(BeFixed, T);
    enum size_t size = fixedSize(schema, 0);
    if (at > bytes.length || bytes.length - at < size)
        return err!T(BinError(BinErrorKind.truncated, at, T.stringof));
    T value;
    size_t pos = at;
    auto e = readNode!(T, schema, 0)(value, bytes, pos, "");
    if (e.kind != BinErrorKind.none)
    {
        e.what = T.stringof ~ "." ~ e.what;
        return err!T(e);
    }
    auto failures = wireCheckFailures!(BeFixed, T)(value);
    if (failures.length)
        return err!T(BinError(BinErrorKind.checkFailed, at, T.stringof ~ ": " ~ failures[0].reason));
    return ok!BinError(value);
}

void writeNode(V, alias schema, size_t index)(in V value, ref ubyte[] output)
{
    enum node = schema.nodes[index];
    static if (node.kind == NodeKind.aggregate)
    {
        static foreach (i; 0 .. V.tupleof.length)
            writeNode!(typeof(V.tupleof[i]), schema, schema.edges[node.firstEdge + i])(
                value.tupleof[i], output);
    }
    else static if (node.kind == NodeKind.staticArray)
    {
        foreach (k; 0 .. node.staticLength)
            writeNode!(typeof(value[0]), schema, schema.edges[node.firstEdge])(value[k], output);
    }
    else
    {
        const ulong raw = cast(ulong) value;
        foreach_reverse (k; 0 .. node.scalarBits / 8)
            output ~= cast(ubyte)(raw >> (8 * k));
    }
}

/// Encodes a fixed record after its checks pass, as expressiveness §6.4
/// requires of encode. Returns the first failure's reason, or null.
string encodeFixed(T)(in T value, ref ubyte[] output)
{
    enum schema = wireSchemaOf!(BeFixed, T);
    static foreach (i; 0 .. T.tupleof.length)
        foreach (failure; wireCheckFailures!(BeFixed, T.tupleof[i])(value.tupleof[i]))
            return failure.reason;
    foreach (failure; wireCheckFailures!(BeFixed, T)(value))
        return failure.reason;
    writeNode!(T, schema, 0)(value, output);
    return null;
}


// ---------------------------------------------------------------------------
// ISO/IEC 14496-12 fixed parts, as quoted by the MPEG reference software and
// libavif's parser
// ---------------------------------------------------------------------------

bool isFourCc(in char[4] t) @safe pure nothrow @nogc
{
    foreach (c; t)
        if (c < 0x20 || c > 0x7E)
            return false;
    return true;
}

/// §4.2.2: "unsigned int(32) size; unsigned int(32) type = boxtype;"
struct BoxHeader
{
    uint size;
    @WireCheck!(isFourCc, "box type is not printable") char[4] type;
}

/// §4.2.2 FullBox: "unsigned int(8) version; bit(24) flags;" There is no
/// 24-bit leaf, so the flags are three bytes.
struct FullBoxHeader
{
    ubyte version_;
    ubyte[3] flags;
}

/// §4.3 `ftyp`, before its compatible brands (which run to the box end).
struct FileTypeFixed
{
    char[4] majorBrand;
    uint minorVersion;
}

/// §8.4.3 `hdlr`, after FullBox and before the NUL-terminated name.
struct HandlerFixed
{
    @WireCheck!(isOneOf!(0u)) uint preDefined;
    char[4] handlerType;
    uint[3] reserved;
}

/// §8.11.6 `infe` version 2, after FullBox and before the name.
struct ItemInfoEntryV2
{
    @WireCheck!(isBetween!(1, ushort.max), "item_ID 0 is reserved") ushort itemId;
    ushort protectionIndex;
    char[4] itemType;
}

/// ISO/IEC 23008-12 `ispe`, after FullBox.
@WireCheck!(e => e.width > 0 && e.height > 0, "ispe dimensions must be > 0")
struct ImageSpatialExtents
{
    uint width;
    uint height;
}

// ---------------------------------------------------------------------------
// GAP: everything below is hand-written
// ---------------------------------------------------------------------------

/// A box located in the input: `[start, end)` with the payload after
/// `headerSize` bytes.
struct Box
{
    char[4] type;
    size_t start;
    size_t headerSize;
    size_t end;
    bool large;          /// size was 1 and largesize followed
    bool toEnd;          /// size was 0
    ubyte[16] usertype;  /// for `uuid`
    size_t payload() const @safe pure nothrow @nogc => start + headerSize;
}

alias fail(T) = (BinErrorKind kind, size_t at, string what) => err!T(BinError(kind, at, what));

/// GAP: §4.2.2's header: size, type, then largesize if size == 1, then the
/// 16-byte usertype if type is `uuid`. Size 0 extends to the end of the file
/// and is legal only at the top level (libavif `avifROStreamReadBoxHeaderPartial`).
BinResult!Box readBox(in ubyte[] bytes, size_t at, size_t parentEnd, bool topLevel)
{
    auto h = decodeFixed!BoxHeader(bytes[0 .. parentEnd], at);
    if (h.hasError)
        return err!Box(h.error);
    Box box;
    box.type = h.value.type;
    box.start = at;
    size_t pos = at + 8;
    ulong size = h.value.size;
    if (size == 1)
    {
        if (parentEnd - pos < 8)
            return fail!Box(BinErrorKind.truncated, pos, "largesize");
        size = readBe(bytes, pos, 8);
        pos += 8;
        box.large = true;
    }
    if (box.type == "uuid")
    {
        if (parentEnd - pos < 16)
            return fail!Box(BinErrorKind.truncated, pos, "usertype");
        box.usertype = bytes[pos .. pos + 16];
        pos += 16;
    }
    box.headerSize = pos - at;
    if (size == 0)
    {
        if (!topLevel)
            return fail!Box(BinErrorKind.badSize, at, "size 0 below the top level");
        box.toEnd = true;
        box.end = parentEnd;
        return ok!BinError(box);
    }
    if (size < box.headerSize)
        return fail!Box(BinErrorKind.badSize, at, format!"size %s smaller than its header"(size));
    if (size > parentEnd - at)
        return fail!Box(BinErrorKind.truncated, at, format!"%s overruns its parent"(box.type));
    box.end = at + cast(size_t) size;
    return ok!BinError(box);
}

/// GAP: a FullBox's version and flags, with the versions a box accepts.
BinResult!FullBoxHeader readFull(in ubyte[] bytes, in Box box, ubyte maxVersion)
{
    auto f = decodeFixed!FullBoxHeader(bytes[0 .. box.end], box.payload);
    if (f.hasError)
        return f;
    if (f.value.version_ > maxVersion)
        return fail!FullBoxHeader(BinErrorKind.badVersion, box.payload,
            format!"%s version %s"(box.type, f.value.version_));
    return f;
}

uint flagsOf(in FullBoxHeader f) @safe pure nothrow @nogc
    => f.flags[0] << 16 | f.flags[1] << 8 | f.flags[2];

struct Extent
{
    ulong offset;
    ulong length;
}

struct Item
{
    uint id;
    char[4] type;
    string name;
    Extent[] extents;
    uint[] properties;      /// 1-based indices into ipco
    bool[] essential;
}

struct Property
{
    char[4] type;
    size_t at;
    ImageSpatialExtents ispe;
    ubyte[] bitsPerChannel; /// pixi
}

struct Heif
{
    Box[] tree;             /// every box visited, depth-first
    size_t[] depth;
    char[4] majorBrand;
    char[4][] brands;
    char[4] handler;
    uint primary;
    Item[] items;
    Property[] properties;
    Box mdat;
    ubyte ilocVersion;
    ubyte[4] ilocSizes;     /// offset, length, base_offset, index
    size_t pitmAt, ilocAt, ipmaAt; /// where each reference table starts
}

/// GAP: an unsigned integer whose width (0, 4 or 8 bytes) came from data.
bool readVar(in ubyte[] bytes, ref size_t pos, size_t end, ubyte width, out ulong value)
{
    if (end - pos < width)
        return false;
    value = readBe(bytes, pos, width);
    pos += width;
    return true;
}

/// GAP: the walk, nesting, versions, varying widths and the item tables.
BinResult!Heif parseHeif(in ubyte[] bytes)
{
    Heif heif;

    BinError walk(size_t from, size_t end, size_t level)
    {
        size_t pos = from;
        while (pos < end)
        {
            auto b = readBox(bytes, pos, end, level == 0);
            if (b.hasError)
                return b.error;
            const box = b.value;
            heif.tree ~= box;
            heif.depth ~= level;
            BinError e;
            switch (box.type[])
            {
            case "ftyp":
                auto f = decodeFixed!FileTypeFixed(bytes[0 .. box.end], box.payload);
                if (f.hasError)
                    return f.error;
                heif.majorBrand = f.value.majorBrand;
                for (size_t p = box.payload + 8; p + 4 <= box.end; p += 4)
                {
                    char[4] brand = cast(const(char)[]) bytes[p .. p + 4];
                    heif.brands ~= brand;
                }
                break;
            case "meta":
                auto f = readFull(bytes, box, 0);
                if (f.hasError)
                    return f.error;
                e = walk(box.payload + 4, box.end, level + 1);
                break;
            case "iprp", "ipco":
                e = walk(box.payload, box.end, level + 1);
                break;
            case "hdlr":
                auto f = readFull(bytes, box, 0);
                if (f.hasError)
                    return f.error;
                auto h = decodeFixed!HandlerFixed(bytes[0 .. box.end], box.payload + 4);
                if (h.hasError)
                    return h.error;
                heif.handler = h.value.handlerType;
                break;
            case "pitm":
                auto f = readFull(bytes, box, 1);
                if (f.hasError)
                    return f.error;
                // GAP: item_ID is 16 bits in version 0 and 32 in version 1.
                size_t p = box.payload + 4;
                ulong id;
                if (!readVar(bytes, p, box.end, f.value.version_ == 0 ? 2 : 4, id))
                    return BinError(BinErrorKind.truncated, p, "pitm.item_ID");
                heif.primary = cast(uint) id;
                heif.pitmAt = box.start;
                break;
            case "iinf":
                auto f = readFull(bytes, box, 1);
                if (f.hasError)
                    return f.error;
                size_t p = box.payload + 4;
                ulong count;
                if (!readVar(bytes, p, box.end, f.value.version_ == 0 ? 2 : 4, count))
                    return BinError(BinErrorKind.truncated, p, "iinf.entry_count");
                const before = heif.items.length;
                e = walk(p, box.end, level + 1);
                if (e.kind == BinErrorKind.none && heif.items.length - before != count)
                    e = BinError(BinErrorKind.checkFailed, box.start, "iinf entry_count differs from its infe boxes");
                break;
            case "infe":
                auto f = readFull(bytes, box, 3);
                if (f.hasError)
                    return f.error;
                if (f.value.version_ != 2)
                    return BinError(BinErrorKind.badVersion, box.payload, "infe version other than 2 not described");
                auto v = decodeFixed!ItemInfoEntryV2(bytes[0 .. box.end], box.payload + 4);
                if (v.hasError)
                    return v.error;
                Item item = Item(v.value.itemId, v.value.itemType);
                foreach (other; heif.items)
                    if (other.id == item.id)
                        return BinError(BinErrorKind.duplicate, box.start, "infe item_ID repeated");
                // GAP: a NUL-terminated name inside the box.
                size_t p = box.payload + 12;
                const nameStart = p;
                while (p < box.end && bytes[p] != 0)
                    p++;
                if (p == box.end)
                    return BinError(BinErrorKind.truncated, nameStart, "infe.item_name has no NUL");
                item.name = cast(string) bytes[nameStart .. p].idup;
                heif.items ~= item;
                break;
            case "iloc":
                e = parseIloc(bytes, box, heif);
                break;
            case "ispe", "pixi":
                auto f = readFull(bytes, box, 0);
                if (f.hasError)
                    return f.error;
                Property prop = Property(box.type, box.start);
                if (box.type == "ispe")
                {
                    auto v = decodeFixed!ImageSpatialExtents(bytes[0 .. box.end], box.payload + 4);
                    if (v.hasError)
                        return v.error;
                    prop.ispe = v.value;
                }
                else
                {
                    // GAP: a count byte, then that many bytes.
                    const p = box.payload + 4;
                    if (p >= box.end || box.end - p - 1 < bytes[p])
                        return BinError(BinErrorKind.truncated, p, "pixi.bits_per_channel");
                    prop.bitsPerChannel = bytes[p + 1 .. p + 1 + bytes[p]].dup;
                }
                heif.properties ~= prop;
                break;
            case "ipma":
                e = parseIpma(bytes, box, heif);
                break;
            case "mdat":
                heif.mdat = box;
                break;
            default:
                if (level != 0)
                    heif.properties ~= Property(box.type, box.start); // ipco keeps unknown properties
                break; // unknown boxes are skipped by their size
            }
            if (e.kind != BinErrorKind.none)
                return e;
            pos = box.end;
        }
        return BinError.init;
    }

    auto e = walk(0, bytes.length, 0);
    if (e.kind != BinErrorKind.none)
        return err!Heif(e);
    return resolve(bytes, heif);
}

/// GAP: §8.11.3 `iloc`. Four 4-bit fields set the widths of fields that
/// follow; version 1 adds `construction_method`, version 2 widens the item
/// count and IDs to 32 bits.
BinError parseIloc(in ubyte[] bytes, in Box box, ref Heif heif)
{
    auto f = readFull(bytes, box, 2);
    if (f.hasError)
        return f.error;
    const v = f.value.version_;
    heif.ilocVersion = v;
    heif.ilocAt = box.start;
    size_t p = box.payload + 4;
    if (box.end - p < 2)
        return BinError(BinErrorKind.truncated, p, "iloc sizes");
    heif.ilocSizes = [bytes[p] >> 4, bytes[p] & 0xF, bytes[p + 1] >> 4, v ? bytes[p + 1] & 0xF : 0];
    p += 2;
    foreach (size; heif.ilocSizes)
        if (size != 0 && size != 4 && size != 8)
            return BinError(BinErrorKind.checkFailed, box.payload + 4, format!"iloc field size %s"(size));
    const ubyte offsetSize = heif.ilocSizes[0], lengthSize = heif.ilocSizes[1],
        baseSize = heif.ilocSizes[2], indexSize = heif.ilocSizes[3];
    ulong count;
    if (!readVar(bytes, p, box.end, v < 2 ? 2 : 4, count))
        return BinError(BinErrorKind.truncated, p, "iloc.item_count");
    foreach (_; 0 .. count)
    {
        ulong id, method, dref, base, extentCount;
        if (!readVar(bytes, p, box.end, v < 2 ? 2 : 4, id))
            return BinError(BinErrorKind.truncated, p, "iloc.item_ID");
        if (v >= 1)
        {
            if (!readVar(bytes, p, box.end, 2, method))
                return BinError(BinErrorKind.truncated, p, "iloc.construction_method");
            if ((method & 0xFFF0) != 0 || (method & 0xF) != 0)
                return BinError(BinErrorKind.checkFailed, p - 2, "only construction_method 0 is described");
        }
        if (!readVar(bytes, p, box.end, 2, dref) || !readVar(bytes, p, box.end, baseSize, base)
            || !readVar(bytes, p, box.end, 2, extentCount))
            return BinError(BinErrorKind.truncated, p, "iloc item");
        Item* item;
        foreach (ref candidate; heif.items)
            if (candidate.id == id)
                item = &candidate;
        if (item is null)
            return BinError(BinErrorKind.badReference, box.start, format!"iloc names item %s, absent from iinf"(id));
        if (item.extents.length)
            return BinError(BinErrorKind.duplicate, box.start, format!"item %s located twice"(id));
        foreach (__; 0 .. extentCount)
        {
            ulong index, offset, length;
            if (!readVar(bytes, p, box.end, indexSize, index) || !readVar(bytes, p, box.end, offsetSize, offset)
                || !readVar(bytes, p, box.end, lengthSize, length))
                return BinError(BinErrorKind.truncated, p, "iloc extent");
            if (offset > ulong.max - base)
                return BinError(BinErrorKind.badSize, p, "iloc offset overflows");
            item.extents ~= Extent(base + offset, length);
        }
    }
    return BinError.init;
}

/// GAP: ISO/IEC 23008-12 `ipma`. Item IDs are 16 bits in version 0, 32 in
/// version 1; with flags bit 0 an association is 16 bits (1 essential bit,
/// 15-bit index), else 8 bits (1 + 7).
BinError parseIpma(in ubyte[] bytes, in Box box, ref Heif heif)
{
    auto f = readFull(bytes, box, 1);
    if (f.hasError)
        return f.error;
    const wide = (flagsOf(f.value) & 1) != 0;
    heif.ipmaAt = box.start;
    size_t p = box.payload + 4;
    ulong count;
    if (!readVar(bytes, p, box.end, 4, count))
        return BinError(BinErrorKind.truncated, p, "ipma.entry_count");
    foreach (_; 0 .. count)
    {
        ulong id, associations;
        if (!readVar(bytes, p, box.end, f.value.version_ == 0 ? 2 : 4, id) || !readVar(bytes, p, box.end, 1, associations))
            return BinError(BinErrorKind.truncated, p, "ipma entry");
        Item* item;
        foreach (ref candidate; heif.items)
            if (candidate.id == id)
                item = &candidate;
        if (item is null)
            return BinError(BinErrorKind.badReference, box.start, format!"ipma names item %s, absent from iinf"(id));
        foreach (__; 0 .. associations)
        {
            ulong raw;
            if (!readVar(bytes, p, box.end, wide ? 2 : 1, raw))
                return BinError(BinErrorKind.truncated, p, "ipma association");
            const essentialBit = wide ? 0x8000 : 0x80;
            item.properties ~= cast(uint)(raw & (essentialBit - 1));
            item.essential ~= (raw & essentialBit) != 0;
        }
    }
    return BinError.init;
}

/// GAP: the references by ID and index, checked after the whole tree is read.
BinResult!Heif resolve(in ubyte[] bytes, ref Heif heif)
{
    alias bad = fail!Heif;
    bool found;
    foreach (item; heif.items)
        found |= item.id == heif.primary;
    if (!found)
        return bad(BinErrorKind.badReference, heif.pitmAt, format!"pitm names item %s, absent from iinf"(heif.primary));
    foreach (item; heif.items)
    {
        foreach (i, index; item.properties)
            if (index == 0 ? item.essential[i] : index > heif.properties.length)
                return bad(BinErrorKind.badReference, heif.ipmaAt,
                    format!"item %s names property %s of %s"(item.id, index, heif.properties.length));
        foreach (extent; item.extents)
            if (extent.offset > bytes.length || extent.length > bytes.length - extent.offset)
                return bad(BinErrorKind.badReference, heif.ilocAt, format!"item %s extent outside the file"(item.id));
    }
    return ok!BinError(heif);
}

// ---------------------------------------------------------------------------
// Building an input in memory
// ---------------------------------------------------------------------------

/// GAP on encode: box sizes and `iloc` offsets are only known after the
/// bytes they cover are written, so they are back-patched.
struct BoxWriter
{
    ubyte[] bytes;
    size_t[] open;

    void begin(string type, bool large = false)
    {
        open ~= bytes.length;
        const refused = encodeFixed(BoxHeader(large ? 1 : 0, type[0 .. 4]), bytes);
        assert(refused is null, refused);
        if (large)
            bytes ~= new ubyte[8];
    }

    void beginFull(string type, ubyte version_, uint flags = 0)
    {
        begin(type);
        put(FullBoxHeader(version_, [cast(ubyte)(flags >> 16), cast(ubyte)(flags >> 8), cast(ubyte) flags]));
    }

    void put(T)(in T value)
    {
        const refused = encodeFixed(value, bytes);
        assert(refused is null, refused);
    }

    void be(ulong value, size_t width)
    {
        foreach_reverse (k; 0 .. width)
            bytes ~= cast(ubyte)(value >> (8 * k));
    }

    void patch(size_t at, ulong value, size_t width)
    {
        foreach (k; 0 .. width)
            bytes[at + k] = cast(ubyte)(value >> (8 * (width - 1 - k)));
    }

    /// Closes the innermost box; `toEnd` leaves size 0.
    void end(bool toEnd = false)
    {
        const start = open[$ - 1];
        open = open[0 .. $ - 1];
        if (toEnd)
            return;
        if (readBe(bytes, start, 4) == 1)
            patch(start + 8, bytes.length - start, 8);
        else
            patch(start, bytes.length - start, 4);
    }
}

enum Variant
{
    valid,
    childOverrun,
    sizeZeroNested,
    ilocFieldSize3,
    extentOutside,
    propertyMissing,
    primaryMissing,
    sizeBelowHeader,
}

immutable ubyte[] av1Payload = cast(immutable(ubyte)[]) "AV1-OBU-BYTES....";
immutable ubyte[] exifPayload = cast(immutable(ubyte)[]) "\0\0\0\0MM\0*";

ubyte[] buildHeif(Variant variant)
{
    BoxWriter w;
    w.begin("ftyp");
    w.put(FileTypeFixed("avif", 0));
    foreach (brand; ["avif", "mif1", "miaf"])
        w.bytes ~= cast(const(ubyte)[]) brand;
    w.end();

    w.begin("uuid");
    w.bytes ~= cast(const(ubyte)[]) "0123456789abcdef"; // the usertype
    w.bytes ~= cast(const(ubyte)[]) "note";
    w.end();

    w.beginFull("meta", 0);
    w.beginFull("hdlr", 0);
    w.put(HandlerFixed(0, "pict", [0, 0, 0]));
    w.bytes ~= 0;
    w.end();
    w.beginFull("pitm", 0);
    w.be(variant == Variant.primaryMissing ? 7 : 1, 2);
    w.end();
    w.beginFull("iinf", 0);
    w.be(2, 2);
    w.beginFull("infe", 2);
    w.put(ItemInfoEntryV2(1, 0, "av01"));
    w.bytes ~= cast(const(ubyte)[]) "Color\0";
    w.end();
    w.beginFull("infe", 2);
    w.put(ItemInfoEntryV2(2, 0, "Exif"));
    w.bytes ~= 0;
    w.end();
    w.end();

    w.beginFull("iloc", 1);
    w.bytes ~= cast(ubyte)(variant == Variant.ilocFieldSize3 ? 0x34 : 0x44); // offset_size 4, length_size 4
    w.bytes ~= 0x00;                    // base_offset_size 0, index_size 0
    w.be(2, 2);                         // item_count
    size_t[2] offsetAt;
    foreach (i, id; [1, 2])
    {
        w.be(id, 2);
        w.be(0, 2);                     // reserved, construction_method 0
        w.be(0, 2);                     // data_reference_index
        w.be(1, 2);                     // extent_count
        offsetAt[i] = w.bytes.length;
        w.be(0, 4);                     // extent_offset, patched below
        const length = i == 0 ? av1Payload.length : exifPayload.length;
        w.be(variant == Variant.extentOutside && i == 1 ? 0x7FFF_FFF0 : length, 4);
    }
    w.end();

    w.begin("iprp");
    w.begin("ipco");
    w.beginFull("ispe", 0);
    w.put(ImageSpatialExtents(64, 48));
    w.end();
    const pixiAt = w.bytes.length;
    w.beginFull("pixi", 0);
    w.bytes ~= [3, 8, 8, 8];
    w.end();
    w.end();
    w.beginFull("ipma", 0, 0);
    w.be(2, 4);                         // entry_count
    w.be(1, 2);
    w.bytes ~= 2;
    w.bytes ~= 0x01;                    // ispe, not essential
    w.bytes ~= variant == Variant.propertyMissing ? 0x83 : 0x82; // pixi, essential
    w.be(2, 2);
    w.bytes ~= 0;
    w.end();
    w.end();
    w.end();                            // meta

    w.begin("mdat", true);              // size 1, 64-bit largesize
    const payloadAt = w.bytes.length;
    w.bytes ~= av1Payload;
    w.bytes ~= exifPayload;
    w.end();
    w.patch(offsetAt[0], payloadAt, 4);
    w.patch(offsetAt[1], payloadAt + av1Payload.length, 4);

    w.begin("free");
    w.bytes ~= [0, 0, 0, 0];
    w.end(true);                        // size 0: to the end of the file

    if (variant == Variant.childOverrun)
        w.patch(pixiAt - 20, 200, 4);   // ispe claims more than ipco holds
    if (variant == Variant.sizeZeroNested)
        w.patch(pixiAt, 0, 4);
    if (variant == Variant.sizeBelowHeader)
        w.patch(0, 4, 4);
    return w.bytes;
}

void report(string label, in ubyte[] bytes)
{
    auto r = parseHeif(bytes);
    if (r.hasError)
        writefln("isobmff: %s: %s at offset %s (%s)", label, r.error.kind, r.error.offset, r.error.what);
    else
        writefln("isobmff: %s: ok", label);
}

void main()
{
    writefln("isobmff: schema sizes: BoxHeader %s, FullBoxHeader %s, ftyp %s, hdlr %s, infe v2 %s, ispe %s bytes",
        fixedSize(wireSchemaOf!(BeFixed, BoxHeader), 0), fixedSize(wireSchemaOf!(BeFixed, FullBoxHeader), 0),
        fixedSize(wireSchemaOf!(BeFixed, FileTypeFixed), 0), fixedSize(wireSchemaOf!(BeFixed, HandlerFixed), 0),
        fixedSize(wireSchemaOf!(BeFixed, ItemInfoEntryV2), 0), fixedSize(wireSchemaOf!(BeFixed, ImageSpatialExtents), 0));

    const bytes = buildHeif(Variant.valid);
    auto r = parseHeif(bytes);
    assert(r.hasValue, r.error.what);
    const heif = r.value;
    writefln("isobmff: valid: %s bytes, %s boxes, brand %s %s, handler %s",
        bytes.length, heif.tree.length, heif.majorBrand, heif.brands, heif.handler);
    foreach (i, box; heif.tree)
    {
        string note = box.large ? " largesize" : box.toEnd ? " size 0 (to end)" : "";
        if (box.type == "uuid")
            note ~= " usertype " ~ cast(string) box.usertype[].idup;
        writefln("isobmff:   %*s%s @%s header %s size %s%s", 2 * heif.depth[i], "", box.type,
            box.start, box.headerSize, box.end - box.start, note);
    }
    writefln("isobmff: iloc version %s, field sizes offset %s length %s base_offset %s index %s",
        heif.ilocVersion, heif.ilocSizes[0], heif.ilocSizes[1], heif.ilocSizes[2], heif.ilocSizes[3]);
    foreach (item; heif.items)
    {
        string props;
        foreach (i, index; item.properties)
        {
            const prop = heif.properties[index - 1];
            props ~= format!" %s%s"(prop.type, item.essential[i] ? "(essential)" : "");
            if (prop.type == "ispe")
                props ~= format!"=%sx%s"(prop.ispe.width, prop.ispe.height);
            if (prop.type == "pixi")
                props ~= format!"=%s"(prop.bitsPerChannel);
        }
        const e = item.extents[0];
        const inMdat = e.offset >= heif.mdat.payload && e.offset + e.length <= heif.mdat.end;
        writefln("isobmff: item %s%s %s \"%s\": %s bytes at %s, inside mdat %s, properties:%s",
            item.id, item.id == heif.primary ? " (primary)" : "", item.type, item.name,
            e.length, e.offset, inMdat, props.length ? props : " none");
    }
    writefln("isobmff: primary item bytes: \"%s\"",
        cast(string) bytes[heif.items[0].extents[0].offset .. heif.items[0].extents[0].offset + heif.items[0].extents[0].length]);

    ubyte[] again;
    encodeFixed(decodeFixed!BoxHeader(bytes, 0).value, again);
    writefln("isobmff: round trip: ftyp header re-encoded to %s bytes, identical: %s", again.length, again == bytes[0 .. 8]);

    report("ispe overruns ipco", buildHeif(Variant.childOverrun));
    report("size 0 inside ipco", buildHeif(Variant.sizeZeroNested));
    report("iloc offset_size 3", buildHeif(Variant.ilocFieldSize3));
    report("Exif extent past the file", buildHeif(Variant.extentOutside));
    report("ipma names property 3 of 2", buildHeif(Variant.propertyMissing));
    report("pitm names item 7", buildHeif(Variant.primaryMissing));
    report("ftyp size 4", buildHeif(Variant.sizeBelowHeader));
}
