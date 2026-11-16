#!/usr/bin/env dub
/+ dub.sdl:
    name "images_wired_png_chunks"
    dependency "sparkles:wired" path="../../../../.."
    dflags "-preview=in" "-preview=dip1000"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
 * PNG chunk framing on the `sparkles:wired` that ships today.
 *
 * The fixed-layout records (the chunk header, `IHDR`, `cICP`, `acTL`,
 * `fcTL`) are plain D structs with `@WireCheck` constraints. A small walker
 * reads and writes them by following `wireSchemaOf!(BeFixed, T)` node by
 * node, as a binary backend would: the schema supplies kinds, widths and
 * array lengths; the format marker supplies the byte order, because a
 * `SchemaNode` has none.
 *
 * Everything the schema cannot say is hand-written D, marked `GAP`: the
 * signature, the length-prefixed chunk body, CRC-32 over type and data, the
 * chunk-ordering rules, `PLTE`/`tRNS` presence and length that depend on
 * the colour type, the `IDAT` run that forms one zlib stream and its
 * expected inflated size, and APNG sequence numbers.
 *
 * Backs ../index.md (section "PNG"). Run with:
 * `dub run --single png-chunks.d`
 */
module images_wired_png_chunks;

import std.stdio : writefln;
import std.traits : EnumMembers, OriginalType;
import std.zlib : compress, UnCompress;

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
    badSignature,
    badCrc,
    badOrder,
    badLength,
    missingChunk,
    badSequence,
    badStream,
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
// PNG descriptions (W3C PNG Third Edition)
// ---------------------------------------------------------------------------

enum ColorType : ubyte
{
    greyscale = 0,
    truecolor = 2,
    indexed = 3,
    greyscaleAlpha = 4,
    truecolorAlpha = 6,
}

/// Table 12 (§11.2.1): allowed bit depths per colour type.
bool depthAllowed(in Ihdr h) @safe pure nothrow @nogc
{
    final switch (h.colorType)
    {
    case ColorType.greyscale:
        return true;
    case ColorType.indexed:
        return h.bitDepth <= 8;
    case ColorType.truecolor, ColorType.greyscaleAlpha, ColorType.truecolorAlpha:
        return h.bitDepth >= 8;
    }
}

/// §11.2.1. A PNG four-byte unsigned integer is at most 2^31 - 1 (§7.1).
@WireCheck!(depthAllowed, "bit depth not allowed for colour type")
struct Ihdr
{
    @WireCheck!(isBetween!(1u, 0x7FFF_FFFFu)) uint width;
    @WireCheck!(isBetween!(1u, 0x7FFF_FFFFu)) uint height;
    @WireCheck!(isOneOf!(1, 2, 4, 8, 16)) ubyte bitDepth;
    ColorType colorType;
    @WireCheck!(isOneOf!(0)) ubyte compression;
    @WireCheck!(isOneOf!(0)) ubyte filter;
    @WireCheck!(isOneOf!(0, 1)) ubyte interlace;
}

bool isChunkType(in char[4] t) @safe pure nothrow @nogc
{
    foreach (c; t)
        if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')))
            return false;
    return true;
}

/// §5.3: the part of a chunk the schema can describe.
struct ChunkHeader
{
    @WireCheck!(isBetween!(0u, 0x7FFF_FFFFu)) uint length;
    @WireCheck!(isChunkType, "chunk type byte is not a letter") char[4] type;
}

/// §11.3.2.6.
struct Cicp
{
    ubyte colourPrimaries;
    ubyte transferFunction;
    @WireCheck!(isOneOf!(0), "matrix coefficients must be 0 for RGB") ubyte matrixCoefficients;
    @WireCheck!(isOneOf!(0, 1)) ubyte videoFullRange;
}

/// §11.3.6.1: "0 is not a valid value".
struct Actl
{
    @WireCheck!(isBetween!(1u, 0x7FFF_FFFFu), "num_frames must not be 0") uint numFrames;
    uint numPlays;
}

enum DisposeOp : ubyte { none = 0, background = 1, previous = 2 }
enum BlendOp : ubyte { source = 0, over = 1 }

/// §11.3.6.2. The frame-region rule needs IHDR, so it cannot be a check here.
@WireCheck!(f => f.width > 0 && f.height > 0, "frame width and height must be > 0")
struct Fctl
{
    uint sequenceNumber;
    uint width;
    uint height;
    uint xOffset;
    uint yOffset;
    ushort delayNum;
    ushort delayDen;
    DisposeOp disposeOp;
    BlendOp blendOp;
}

// ---------------------------------------------------------------------------
// GAP: everything below is hand-written
// ---------------------------------------------------------------------------

immutable ubyte[8] pngSignature = [0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A];

/// GAP: CRC-32 of §5.5 (reflected, initialised to all ones, inverted), over
/// two ranges: the chunk type and the chunk data.
uint crc32(in ubyte[] a, in ubyte[] b) @safe pure nothrow @nogc
{
    uint crc = 0xFFFF_FFFF;
    const(ubyte)[][2] parts = [a, b];
    foreach (part; parts)
        foreach (octet; part)
        {
            crc ^= octet;
            foreach (_; 0 .. 8)
                crc = (crc >> 1) ^ (0xEDB8_8320 & -(crc & 1));
        }
    return ~crc;
}

struct Chunk
{
    ChunkHeader header;
    size_t start;              /// offset of the length field
    const(ubyte)[] data;       /// borrowed from the input
}

/// GAP: a length-prefixed body and a trailing CRC over type and data.
BinResult!Chunk readChunk(return scope const(ubyte)[] bytes, size_t at)
{
    auto header = decodeFixed!ChunkHeader(bytes, at);
    if (header.hasError)
        return err!Chunk(header.error);
    const dataStart = at + 8;
    const ulong end = cast(ulong) dataStart + header.value.length + 4;
    if (end > bytes.length)
        return err!Chunk(BinError(BinErrorKind.truncated, at, header.value.type.idup));
    auto data = bytes[dataStart .. dataStart + header.value.length];
    const stored = cast(uint) readBe(bytes, dataStart + header.value.length, 4);
    if (stored != crc32(bytes[at + 4 .. at + 8], data))
        return err!Chunk(BinError(BinErrorKind.badCrc, at, header.value.type.idup));
    return ok!BinError(Chunk(header.value, at, data));
}

/// GAP: bytes per row plus the filter byte, times rows (§7.2, §9.2), for a
/// non-interlaced image: the output-size contract Wuffs calls `workbuf_len`.
ulong expectedInflated(uint width, uint height, in Ihdr h) @safe pure nothrow @nogc
{
    static immutable ubyte[7] samples = [1, 0, 3, 1, 2, 0, 4];
    const ulong bitsPerPixel = samples[h.colorType] * h.bitDepth;
    return height * (1 + (width * bitsPerPixel + 7) / 8);
}

struct Summary
{
    Ihdr ihdr;
    size_t chunks;
    size_t idatChunks;
    size_t paletteEntries;
    ulong inflatedImage;
    ulong inflatedFrames;
    Cicp cicp;
    Actl actl;
    size_t frames;
}

/// GAP: the walk, the ordering rules of §5.6 Table 7, the colour-type
/// dependencies of §11.2.2 and §11.3.1.1, the IDAT run of §10.2, APNG
/// sequence numbers of §11.3.6.
BinResult!Summary parsePng(in ubyte[] bytes)
{
    alias fail = (kind, offset, what) => err!Summary(BinError(kind, offset, what));
    alias relocate = (BinError e, size_t chunkAt) =>
        err!Summary(BinError(e.kind, chunkAt + 8 + e.offset, e.what));
    if (bytes.length < 8 || bytes[0 .. 8] != pngSignature[])
        return fail(BinErrorKind.badSignature, 0, "signature");

    Summary s;
    bool sawPlte, sawTrns, sawCicp, sawActl, sawIdat, idatClosed, sawIend;
    uint nextSequence;
    auto image = new UnCompress;
    UnCompress frame;
    Fctl frameControl;
    size_t pos = 8;
    while (pos < bytes.length)
    {
        auto c = readChunk(bytes, pos);
        if (c.hasError)
            return err!Summary(c.error);
        const chunk = c.value;
        const type = chunk.header.type;
        const at = chunk.start;
        s.chunks++;
        if (sawIend)
            return fail(BinErrorKind.badOrder, at, "chunk after IEND");
        if (s.chunks == 1 && type != "IHDR")
            return fail(BinErrorKind.badOrder, at, "IHDR must be first");
        if (sawIdat && type != "IDAT")
            idatClosed = true;

        switch (type[])
        {
        case "IHDR":
            if (s.chunks != 1)
                return fail(BinErrorKind.badOrder, at, "second IHDR");
            if (chunk.data.length != 13)
                return fail(BinErrorKind.badLength, at, "IHDR");
            auto h = decodeFixed!Ihdr(chunk.data, 0);
            if (h.hasError)
                return relocate(h.error, at);
            s.ihdr = h.value;
            break;
        case "PLTE":
            if (sawPlte || sawIdat)
                return fail(BinErrorKind.badOrder, at, "PLTE must be once, before IDAT");
            if (s.ihdr.colorType == ColorType.greyscale || s.ihdr.colorType == ColorType.greyscaleAlpha)
                return fail(BinErrorKind.badOrder, at, "PLTE forbidden for this colour type");
            if (chunk.data.length == 0 || chunk.data.length % 3 || chunk.data.length / 3 > 256
                || (s.ihdr.colorType == ColorType.indexed && chunk.data.length / 3 > (1 << s.ihdr.bitDepth)))
                return fail(BinErrorKind.badLength, at, "PLTE");
            sawPlte = true;
            s.paletteEntries = chunk.data.length / 3;
            break;
        case "tRNS":
            if (sawTrns || sawIdat)
                return fail(BinErrorKind.badOrder, at, "tRNS must be once, before IDAT");
            final switch (s.ihdr.colorType)
            {
            case ColorType.greyscale:
                if (chunk.data.length != 2)
                    return fail(BinErrorKind.badLength, at, "tRNS");
                break;
            case ColorType.truecolor:
                if (chunk.data.length != 6)
                    return fail(BinErrorKind.badLength, at, "tRNS");
                break;
            case ColorType.indexed:
                if (!sawPlte)
                    return fail(BinErrorKind.badOrder, at, "tRNS before PLTE");
                if (chunk.data.length > s.paletteEntries)
                    return fail(BinErrorKind.badLength, at, "tRNS longer than PLTE");
                break;
            case ColorType.greyscaleAlpha, ColorType.truecolorAlpha:
                return fail(BinErrorKind.badOrder, at, "tRNS forbidden for this colour type");
            }
            sawTrns = true;
            break;
        case "cICP":
            if (sawCicp || sawPlte || sawIdat)
                return fail(BinErrorKind.badOrder, at, "cICP must be once, before PLTE and IDAT");
            if (chunk.data.length != 4)
                return fail(BinErrorKind.badLength, at, "cICP");
            auto v = decodeFixed!Cicp(chunk.data, 0);
            if (v.hasError)
                return relocate(v.error, at);
            s.cicp = v.value;
            sawCicp = true;
            break;
        case "acTL":
            if (sawActl || sawIdat)
                return fail(BinErrorKind.badOrder, at, "acTL must be once, before IDAT");
            if (chunk.data.length != 8)
                return fail(BinErrorKind.badLength, at, "acTL");
            auto v = decodeFixed!Actl(chunk.data, 0);
            if (v.hasError)
                return relocate(v.error, at);
            s.actl = v.value;
            sawActl = true;
            break;
        case "fcTL":
            if (chunk.data.length != 26)
                return fail(BinErrorKind.badLength, at, "fcTL");
            auto v = decodeFixed!Fctl(chunk.data, 0);
            if (v.hasError)
                return relocate(v.error, at);
            if (v.value.sequenceNumber != nextSequence++)
                return fail(BinErrorKind.badSequence, at, "fcTL sequence_number");
            // A cross-chunk check: the frame region lies inside IHDR's canvas.
            if (cast(ulong) v.value.xOffset + v.value.width > s.ihdr.width
                || cast(ulong) v.value.yOffset + v.value.height > s.ihdr.height)
                return fail(BinErrorKind.checkFailed, at, "fcTL region outside IHDR");
            if (s.frames > 0 && !sawIdat)
                return fail(BinErrorKind.badOrder, at, "only one fcTL may precede IDAT");
            if (frame !is null)
                s.inflatedFrames += frame.flush().length;
            frame = sawIdat ? new UnCompress : null;
            frameControl = v.value;
            s.frames++;
            break;
        case "IDAT":
            if (idatClosed)
                return fail(BinErrorKind.badOrder, at, "IDAT chunks must be consecutive");
            if (s.ihdr.colorType == ColorType.indexed && !sawPlte)
                return fail(BinErrorKind.missingChunk, at, "PLTE required for indexed colour");
            sawIdat = true;
            s.idatChunks++;
            // One zlib stream across every IDAT (§10.2): each body goes to the
            // same inflater, nothing is concatenated in memory.
            s.inflatedImage += image.uncompress(chunk.data).length;
            break;
        case "fdAT":
            if (!sawIdat || frame is null)
                return fail(BinErrorKind.badOrder, at, "fdAT before IDAT or without fcTL");
            if (chunk.data.length < 4)
                return fail(BinErrorKind.badLength, at, "fdAT");
            if (readBe(chunk.data, 0, 4) != nextSequence++)
                return fail(BinErrorKind.badSequence, at, "fdAT sequence_number");
            s.inflatedFrames += frame.uncompress(chunk.data[4 .. $]).length;
            break;
        case "IEND":
            if (chunk.data.length != 0)
                return fail(BinErrorKind.badLength, at, "IEND");
            sawIend = true;
            break;
        default:
            if ((type[0] & 0x20) == 0)
                return fail(BinErrorKind.missingChunk, at, "unknown critical chunk");
            break; // unknown ancillary chunks are skipped
        }
        pos += 12 + chunk.data.length;
    }
    if (!sawIend)
        return fail(BinErrorKind.missingChunk, pos, "IEND");
    if (!sawIdat)
        return fail(BinErrorKind.missingChunk, pos, "IDAT");
    s.inflatedImage += image.flush().length;
    if (frame !is null)
        s.inflatedFrames += frame.flush().length;
    if (s.inflatedImage != expectedInflated(s.ihdr.width, s.ihdr.height, s.ihdr))
        return fail(BinErrorKind.badStream, pos, "IDAT stream size differs from IHDR");
    if (sawActl && s.actl.numFrames != s.frames)
        return fail(BinErrorKind.checkFailed, pos, "acTL num_frames differs from the fcTL count");
    return ok!BinError(s);
}

// ---------------------------------------------------------------------------
// Building inputs in memory
// ---------------------------------------------------------------------------

/// GAP on encode: the length prefix and the CRC are computed by hand.
void putChunk(ref ubyte[] output, string type, in ubyte[] data)
{
    ChunkHeader header;
    header.length = cast(uint) data.length;
    header.type = type[0 .. 4];
    const refused = encodeFixed(header, output);
    assert(refused is null, refused);
    output ~= data;
    const crc = crc32(cast(const(ubyte)[]) type, data);
    foreach_reverse (k; 0 .. 4)
        output ~= cast(ubyte)(crc >> (8 * k));
}

ubyte[] fixedBytes(T)(in T value)
{
    ubyte[] output;
    const refused = encodeFixed(value, output);
    assert(refused is null, refused);
    return output;
}

ubyte[] be32(uint v) => [cast(ubyte)(v >> 24), cast(ubyte)(v >> 16), cast(ubyte)(v >> 8), cast(ubyte) v];

enum Variant
{
    valid,
    badCrc,
    badDepth,
    trnsBeforePlte,
    splitIdat,
    sequenceGap,
    frameOutside,
    cicpMatrix,
    truncated,
}

ubyte[] buildPng(Variant variant)
{
    ubyte[] png = pngSignature.dup;
    const ihdr = Ihdr(4, 2, variant == Variant.badDepth ? 16 : 8, ColorType.indexed, 0, 0, 0);
    ubyte[] ihdrBytes;
    // encodeFixed refuses depth 16 with indexed colour, so that variant
    // writes the record without its checks.
    if (encodeFixed(ihdr, ihdrBytes) !is null)
        writeNode!(Ihdr, wireSchemaOf!(BeFixed, Ihdr), 0)(ihdr, ihdrBytes);
    putChunk(png, "IHDR", ihdrBytes);
    if (variant == Variant.cicpMatrix)
    {
        ubyte[] cicpBytes; // matrix 1 fails a field check, so skip encode's checks
        writeNode!(Cicp, wireSchemaOf!(BeFixed, Cicp), 0)(Cicp(1, 13, 1, 1), cicpBytes);
        putChunk(png, "cICP", cicpBytes);
    }
    else
        putChunk(png, "cICP", fixedBytes(Cicp(1, 13, 0, 1)));
    putChunk(png, "acTL", fixedBytes(Actl(2, 0)));

    const ubyte[] palette = [255, 0, 0, 0, 255, 0, 0, 0, 255];
    const ubyte[] trns = [0];
    if (variant == Variant.trnsBeforePlte)
        putChunk(png, "tRNS", trns);
    putChunk(png, "PLTE", palette);
    if (variant != Variant.trnsBeforePlte)
        putChunk(png, "tRNS", trns);
    putChunk(png, "fcTL", fixedBytes(Fctl(0, 4, 2, 0, 0, 1, 10, DisposeOp.none, BlendOp.source)));

    // Two rows of filter byte 0 plus four palette indices: one zlib stream
    // split across two IDAT chunks.
    const ubyte[] rows = [0, 0, 1, 2, 0, 0, 2, 1, 0, 1];
    const stream = cast(const(ubyte)[]) compress(rows);
    const half = stream.length / 2;
    putChunk(png, "IDAT", stream[0 .. half]);
    if (variant == Variant.splitIdat)
        putChunk(png, "tEXt", cast(const(ubyte)[]) "Comment\0split");
    putChunk(png, "IDAT", stream[half .. $]);

    const xOffset = variant == Variant.frameOutside ? 3 : 1;
    putChunk(png, "fcTL", fixedBytes(Fctl(1, 2, 1, xOffset, 1, 1, 10, DisposeOp.background, BlendOp.over)));
    const ubyte[] frameRow = [0, 2, 2];
    putChunk(png, "fdAT", be32(variant == Variant.sequenceGap ? 3 : 2)
        ~ cast(const(ubyte)[]) compress(frameRow));
    putChunk(png, "IEND", null);

    if (variant == Variant.badCrc)
        png[8 + 8 + 13] ^= 0x01; // a bit of IHDR's CRC
    if (variant == Variant.truncated)
        png = png[0 .. 8 + 8 + 6];
    return png;
}

void report(string label, in ubyte[] bytes)
{
    auto r = parsePng(bytes);
    if (r.hasError)
        writefln("png: %s: %s at offset %s (%s)", label, r.error.kind, r.error.offset, r.error.what);
    else
        writefln("png: %s: ok", label);
}

void main()
{
    enum headerSchema = wireSchemaOf!(BeFixed, ChunkHeader);
    writefln("png: schema sizes: ChunkHeader %s, IHDR %s, cICP %s, acTL %s, fcTL %s bytes",
        fixedSize(headerSchema, 0), fixedSize(wireSchemaOf!(BeFixed, Ihdr), 0),
        fixedSize(wireSchemaOf!(BeFixed, Cicp), 0), fixedSize(wireSchemaOf!(BeFixed, Actl), 0),
        fixedSize(wireSchemaOf!(BeFixed, Fctl), 0));
    // What a backend can learn about a check from the schema: a spelling.
    writefln("png: schema annotation on ChunkHeader.length: %s",
        headerSchema.annotations[headerSchema.nodes[1].firstAnnotation].value);

    const png = buildPng(Variant.valid);
    auto r = parsePng(png);
    assert(r.hasValue);
    const s = r.value;
    writefln("png: valid: %s bytes, %s chunks, IHDR %sx%s %s depth %s, %s palette entries",
        png.length, s.chunks, s.ihdr.width, s.ihdr.height, s.ihdr.colorType, s.ihdr.bitDepth,
        s.paletteEntries);
    writefln("png: valid: cICP %s/%s/%s/%s, acTL frames %s plays %s, fcTL seen %s",
        s.cicp.colourPrimaries, s.cicp.transferFunction, s.cicp.matrixCoefficients,
        s.cicp.videoFullRange, s.actl.numFrames, s.actl.numPlays, s.frames);
    writefln("png: valid: %s IDAT chunks -> one zlib stream of %s bytes (IHDR implies %s); fdAT frame %s bytes",
        s.idatChunks, s.inflatedImage, expectedInflated(s.ihdr.width, s.ihdr.height, s.ihdr),
        s.inflatedFrames);

    const again = fixedBytes(s.ihdr);
    writefln("png: round trip: IHDR re-encoded to %s bytes, identical: %s",
        again.length, again == png[16 .. 29]);

    report("bit flip in IHDR CRC", buildPng(Variant.badCrc));
    report("depth 16 with indexed colour", buildPng(Variant.badDepth));
    report("tRNS before PLTE", buildPng(Variant.trnsBeforePlte));
    report("tEXt between IDATs", buildPng(Variant.splitIdat));
    report("fdAT sequence gap", buildPng(Variant.sequenceGap));
    report("frame outside the canvas", buildPng(Variant.frameOutside));
    report("cICP matrix coefficients 1", buildPng(Variant.cicpMatrix));
    report("cut inside IHDR", buildPng(Variant.truncated));
}
