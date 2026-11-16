#!/usr/bin/env dub
/+ dub.sdl:
    name "images_wired_qoi"
    dependency "sparkles:wired" path="../../../../.."
    dflags "-preview=in" "-preview=dip1000"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
 * QOI on the `sparkles:wired` that ships today.
 *
 * The 14-byte header is a plain D struct with `@WireCheck` constraints,
 * read and written by the same schema walk as `png-chunks.d`. Everything
 * after it is hand-written D, marked `GAP`: the op stream (2-bit and 8-bit
 * tags with sub-byte fields, the 8-bit tags taking precedence), the running
 * 64-entry index addressed by a hash of the decoded pixel, runs, and the
 * 8-byte end marker. The op decoder is resumable in the manner of Wuffs: it
 * accepts the input in pieces of any size, keeps a partial op in a scratch
 * buffer, returns `needMore` while the input is open, and reports
 * `truncated` only once the caller says the input is closed. A caller-set
 * pixel budget is checked against the header before anything is allocated.
 *
 * Backs ../index.md (section "QOI"). Run with:
 * `dub run --single qoi.d`
 */
module images_wired_qoi;

import std.algorithm.comparison : min;
import std.stdio : writefln;
import std.traits : EnumMembers, OriginalType;

import sparkles.base.expected : Expected, err, ok;
import sparkles.wired.policy : isOneOf, WireCheck, wireCheckFailures;
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
    limitExceeded,
    badStream,
    badEndMarker,
    trailingBytes,
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
// The QOI header (qoiformat.org specification 1.0)
// ---------------------------------------------------------------------------

/// "magic bytes "qoif"", then big-endian width and height, then two
/// informative bytes.
struct QoiHeader
{
    @WireCheck!(m => m == "qoif", "magic is not qoif") char[4] magic;
    uint width;
    uint height;
    @WireCheck!(isOneOf!(3, 4), "channels must be 3 or 4") ubyte channels;
    @WireCheck!(isOneOf!(0, 1), "colorspace must be 0 or 1") ubyte colorspace;
}

// ---------------------------------------------------------------------------
// GAP: everything below is hand-written
// ---------------------------------------------------------------------------

struct Rgba
{
    ubyte r, g, b, a;
}

/// "index_position = (r * 3 + g * 5 + b * 7 + a * 11) % 64"
size_t hashOf(Rgba p) @safe pure nothrow @nogc => (p.r * 3 + p.g * 5 + p.b * 7 + p.a * 11) % 64;

enum ubyte opIndex = 0x00, opDiff = 0x40, opLuma = 0x80, opRun = 0xC0;
enum ubyte opRgb = 0xFE, opRgba = 0xFF;
immutable ubyte[8] endMarker = [0, 0, 0, 0, 0, 0, 0, 1];

enum Status { ok, needMore, error }

enum Op { rgb, rgba, index, diff, luma, run }

/// GAP: a resumable decoder. Its whole state is this struct; `feed` may be
/// called with any split of the input.
struct QoiDecoder
{
    ulong maxPixels;        /// the caller's budget, checked against the header
    QoiHeader header;
    Rgba[] pixels;
    BinError error;
    ulong[EnumMembers!Op.length] opCounts;
    size_t suspensions;     /// times `feed` returned `needMore`

    private enum Phase { header, ops, end, done }
    private Phase phase;
    private ubyte[14] scratch;
    private size_t scratchLength;
    private size_t position;  /// absolute input position consumed so far
    private size_t written;
    private Rgba previous = Rgba(0, 0, 0, 255);
    private Rgba[64] index;

    /// Returns `need` bytes, from the piece directly when they are all there,
    /// else accumulated in `scratch` across calls; null while incomplete.
    private const(ubyte)[] take(ref const(ubyte)[] piece, size_t need) return
    {
        if (scratchLength == 0 && piece.length >= need)
        {
            auto bytes = piece[0 .. need];
            piece = piece[need .. $];
            position += need;
            return bytes;
        }
        const n = min(need - scratchLength, piece.length);
        scratch[scratchLength .. scratchLength + n] = piece[0 .. n];
        piece = piece[n .. $];
        scratchLength += n;
        position += n;
        if (scratchLength < need)
            return null;
        scratchLength = 0;
        return scratch[0 .. need];
    }

    private Status fail(BinErrorKind kind, string what)
    {
        error = BinError(kind, position, what);
        phase = Phase.done;
        return Status.error;
    }

    private void emit(Rgba p, size_t count = 1)
    {
        pixels[written .. written + count] = p;
        written += count;
        previous = p;
    }

    /// Consumes `piece`; `closed` says no more input will follow.
    Status feed(const(ubyte)[] piece, bool closed)
    {
        if (error.kind != BinErrorKind.none)
            return Status.error; // errors are sticky, as in Wuffs
        while (true)
        {
            final switch (phase)
            {
            case Phase.header:
                auto bytes = take(piece, 14);
                if (bytes is null)
                    return suspend(closed, "header");
                auto h = decodeFixed!QoiHeader(bytes, 0);
                if (h.hasError)
                {
                    error = h.error;
                    phase = Phase.done;
                    return Status.error;
                }
                header = h.value;
                const ulong count = cast(ulong) header.width * header.height;
                if (count == 0)
                    return fail(BinErrorKind.checkFailed, "width or height is 0");
                if (count > maxPixels)
                    return fail(BinErrorKind.limitExceeded, "pixel count above the caller's budget");
                pixels = new Rgba[cast(size_t) count];
                phase = Phase.ops;
                break;
            case Phase.ops:
                if (written == pixels.length)
                {
                    phase = Phase.end;
                    break;
                }
                if (piece.length == 0 && scratchLength == 0)
                    return suspend(closed, "op");
                // "The 8-bit tags have precedence over the 2-bit tags."
                const tag = scratchLength ? scratch[0] : piece[0];
                const size_t need = tag == opRgba ? 5 : tag == opRgb ? 4
                    : (tag & 0xC0) == opLuma ? 2 : 1;
                auto op = take(piece, need);
                if (op is null)
                    return suspend(closed, "op");
                if (!decodeOp(op))
                    return Status.error;
                break;
            case Phase.end:
                auto bytes = take(piece, 8);
                if (bytes is null)
                    return suspend(closed, "end marker");
                if (bytes != endMarker[])
                    return fail(BinErrorKind.badEndMarker, "end marker");
                phase = Phase.done;
                break;
            case Phase.done:
                if (piece.length)
                    return fail(BinErrorKind.trailingBytes, "bytes after the end marker");
                return Status.ok;
            }
        }
    }

    private Status suspend(bool closed, string what)
    {
        if (closed)
            return fail(BinErrorKind.truncated, what);
        suspensions++;
        return Status.needMore;
    }

    private bool decodeOp(in ubyte[] op)
    {
        Rgba p = previous;
        const b = op[0];
        if (b == opRgb)
        {
            p.r = op[1]; p.g = op[2]; p.b = op[3];
            opCounts[Op.rgb]++;
        }
        else if (b == opRgba)
        {
            p = Rgba(op[1], op[2], op[3], op[4]);
            opCounts[Op.rgba]++;
        }
        else if ((b & 0xC0) == opIndex)
        {
            p = index[b & 0x3F];
            opCounts[Op.index]++;
        }
        else if ((b & 0xC0) == opDiff)
        {
            // Three 2-bit fields with a bias of 2, wrapping arithmetic.
            p.r = cast(ubyte)(p.r + ((b >> 4) & 3) - 2);
            p.g = cast(ubyte)(p.g + ((b >> 2) & 3) - 2);
            p.b = cast(ubyte)(p.b + (b & 3) - 2);
            opCounts[Op.diff]++;
        }
        else if ((b & 0xC0) == opLuma)
        {
            // A 6-bit field (bias 32), then two 4-bit fields (bias 8) relative to it.
            const dg = (b & 0x3F) - 32;
            p.r = cast(ubyte)(p.r + dg - 8 + (op[1] >> 4));
            p.g = cast(ubyte)(p.g + dg);
            p.b = cast(ubyte)(p.b + dg - 8 + (op[1] & 0x0F));
            opCounts[Op.luma]++;
        }
        else
        {
            const run = (b & 0x3F) + 1; // 1..62; 63 and 64 are the 8-bit tags
            opCounts[Op.run]++;
            if (run > pixels.length - written)
            {
                fail(BinErrorKind.badStream, "run past the last pixel");
                return false;
            }
            emit(p, run);
            return true; // a run repeats the previous pixel, already indexed
        }
        index[hashOf(p)] = p;
        emit(p);
        return true;
    }
}

/// GAP: the encoder, following the reference `qoi.h` op choice.
ubyte[] encodeQoi(in QoiHeader header, in Rgba[] image)
{
    ubyte[] output;
    const refused = encodeFixed(header, output);
    assert(refused is null, refused);
    Rgba[64] index;
    Rgba previous = Rgba(0, 0, 0, 255);
    size_t run;
    foreach (i, p; image)
    {
        if (p == previous)
        {
            if (++run == 62 || i + 1 == image.length)
            {
                output ~= cast(ubyte)(opRun | (run - 1));
                run = 0;
            }
            continue;
        }
        if (run)
        {
            output ~= cast(ubyte)(opRun | (run - 1));
            run = 0;
        }
        const h = hashOf(p);
        if (index[h] == p)
            output ~= cast(ubyte)(opIndex | h);
        else
        {
            index[h] = p;
            const byte dr = cast(byte)(p.r - previous.r), dg = cast(byte)(p.g - previous.g),
                db = cast(byte)(p.b - previous.b);
            const int drg = dr - dg, dbg = db - dg;
            if (p.a != previous.a)
                output ~= [opRgba, p.r, p.g, p.b, p.a];
            else if (dr >= -2 && dr <= 1 && dg >= -2 && dg <= 1 && db >= -2 && db <= 1)
                output ~= cast(ubyte)(opDiff | (dr + 2) << 4 | (dg + 2) << 2 | (db + 2));
            else if (dg >= -32 && dg <= 31 && drg >= -8 && drg <= 7 && dbg >= -8 && dbg <= 7)
                output ~= [cast(ubyte)(opLuma | (dg + 32)), cast(ubyte)((drg + 8) << 4 | (dbg + 8))];
            else
                output ~= [opRgb, p.r, p.g, p.b];
        }
        previous = p;
    }
    return output ~ endMarker[];
}

/// An 8 by 4 RGBA test image that exercises every op.
Rgba[] testImage()
{
    Rgba[] image;
    foreach (y; 0 .. 4)
    {
        const ubyte v = cast(ubyte) y;
        image ~= [
            Rgba(1, 1, 1, 255),                       // DIFF from black
            Rgba(2, 2, 1, 255),                       // DIFF
            Rgba(20, 22, 18, 255),                    // LUMA
            Rgba(200, 30, cast(ubyte)(90 + v), 255),  // RGB
            Rgba(1, 1, 1, 255),                       // INDEX (seen at x = 0)
            y == 2 ? Rgba(5, 5, 5, 128) : Rgba(5, 5, 5, 255), // RGBA on row 2
            Rgba(0, 0, 0, 255),                       // RUN of two
            Rgba(0, 0, 0, 255),
        ];
    }
    return image;
}

/// Feeds `bytes` in pieces of `step` (0 means all at once), then closes.
QoiDecoder decodeInPieces(in ubyte[] bytes, size_t step, ulong maxPixels = 1 << 20)
{
    QoiDecoder d;
    d.maxPixels = maxPixels;
    const(ubyte)[] rest = bytes;
    Status status = Status.needMore;
    while (status == Status.needMore && rest.length)
    {
        const n = step ? min(step, rest.length) : rest.length;
        status = d.feed(rest[0 .. n], false);
        rest = rest[n .. $];
    }
    if (status == Status.needMore)
        d.feed(null, true);
    return d;
}

ulong fnv1a(in Rgba[] pixels) @safe pure nothrow @nogc
{
    ulong h = 0xcbf2_9ce4_8422_2325;
    foreach (p; pixels)
        foreach (octet; [p.r, p.g, p.b, p.a])
            h = (h ^ octet) * 0x100_0000_01b3;
    return h;
}

void report(string label, in ubyte[] bytes, size_t step = 0, ulong maxPixels = 1 << 20)
{
    auto d = decodeInPieces(bytes, step, maxPixels);
    if (d.error.kind != BinErrorKind.none)
        writefln("qoi: %s: %s at offset %s (%s)", label, d.error.kind, d.error.offset, d.error.what);
    else
        writefln("qoi: %s: ok", label);
}

void main()
{
    enum schema = wireSchemaOf!(BeFixed, QoiHeader);
    writefln("qoi: schema: header %s bytes, %s nodes", fixedSize(schema, 0), schema.nodes.length);

    const image = testImage();
    const header = QoiHeader("qoif", 8, 4, 4, 0);
    const bytes = encodeQoi(header, image);
    writefln("qoi: encoded %s pixels into %s bytes (14 header + %s ops + 8 end)",
        image.length, bytes.length, bytes.length - 22);

    foreach (step; [0, 1, 3, 7])
    {
        auto d = decodeInPieces(bytes, step);
        assert(d.error.kind == BinErrorKind.none);
        writefln("qoi: pieces of %s: %sx%s ch %s, ops rgb %s rgba %s index %s diff %s luma %s run %s, suspensions %s, pixel hash %016x, round trip %s",
            step ? step : bytes.length, d.header.width, d.header.height, d.header.channels,
            d.opCounts[Op.rgb], d.opCounts[Op.rgba], d.opCounts[Op.index], d.opCounts[Op.diff],
            d.opCounts[Op.luma], d.opCounts[Op.run], d.suspensions, fnv1a(d.pixels),
            d.pixels == image);
    }

    ubyte[] again;
    encodeFixed(decodeFixed!QoiHeader(bytes, 0).value, again);
    writefln("qoi: round trip: header re-encoded to %s bytes, identical: %s", again.length, again == bytes[0 .. 14]);

    auto badMagic = bytes.dup;
    badMagic[0] = 'Q';
    report("magic Qoif", badMagic);
    auto badChannels = bytes.dup;
    badChannels[12] = 5;
    report("channels 5", badChannels);
    report("budget of 16 pixels", bytes, 0, 16);
    report("cut after 20 op bytes, fed in pieces of 1", bytes[0 .. 14 + 20], 1);
    auto badEnd = bytes.dup;
    badEnd[$ - 1] = 0;
    report("end marker ends in 0x00", badEnd);
    auto longRun = bytes[0 .. 14] ~ cast(ubyte)(opRun | 61) ~ endMarker[];
    report("one run of 62 for 32 pixels", longRun);
    report("bytes after the end marker", bytes ~ cast(ubyte) 0);
}
