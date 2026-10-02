/**
The D-Bus wire format, as much of it as the desktop terminal speaks
(docs/specs/terminal/decisions.md, D43): message framing, the marshalling of
the basic and container types, the `EXTERNAL` authentication lines and the
`unix:` bus addresses. No I/O — `dbus_conn` owns the socket.

The authority is the D-Bus Specification (dbus.freedesktop.org/doc/
dbus-specification.html), "Message Protocol" and "Authentication Protocol".
Alignment is relative to the start of the message; a body starts 8-aligned,
so aligning relative to the body's start is the same thing.
*/
module dbus_wire;

/// A message's type (the header's second byte).
enum MessageType : ubyte
{
    invalid,
    methodCall,
    methodReturn,
    error,
    signal,
}

/// Header flags.
enum MessageFlags : ubyte
{
    none = 0,
    noReplyExpected = 1,
    noAutoStart = 2,
}

/// The header field codes.
private enum Field : ubyte
{
    path = 1,
    iface = 2,
    member = 3,
    errorName = 4,
    replySerial = 5,
    destination = 6,
    sender = 7,
    signature = 8,
    unixFds = 9,
}

/// The largest message the terminal accepts (the specification allows
/// 128 MiB; the terminal's match rules never ask for anything near this).
enum size_t maxMessageBytes = 1 << 20;

/// Containers nest at most this deep (the specification's 32 + 32).
enum maxNesting = 64;

/**
Marshals values in little-endian order. Each method aligns first, as the
type requires; `beginArray`/`endArray` bracket an array's elements and
patch its byte length.
*/
struct WireWriter
{
    ubyte[] data;

    /// Pads with zero bytes to a multiple of `n`.
    void pad(size_t n) @safe pure nothrow
    {
        while (data.length % n)
            data ~= 0;
    }

    /// `y`
    void u8(ubyte v) @safe pure nothrow
    {
        data ~= v;
    }

    /// `u`
    void u32(uint v) @safe pure nothrow
    {
        pad(4);
        data ~= [cast(ubyte) v, cast(ubyte)(v >> 8), cast(ubyte)(v >> 16),
            cast(ubyte)(v >> 24)];
    }

    /// `i`
    void i32(int v) @safe pure nothrow => u32(cast(uint) v);

    /// `b`
    void boolean(bool v) @safe pure nothrow => u32(v ? 1 : 0);

    /// `s` and `o`. The caller guarantees valid UTF-8 without NUL
    /// (`scrubUtf8`): a bus disconnects a client that sends anything else.
    void str(in char[] s) @safe pure nothrow
    {
        u32(cast(uint) s.length);
        data ~= cast(const(ubyte)[]) s;
        data ~= 0;
    }

    /// `g`, and the type of a `v` (whose value the caller writes next).
    void signature(in char[] s) @safe pure nothrow
    in (s.length < 256)
    {
        data ~= cast(ubyte) s.length;
        data ~= cast(const(ubyte)[]) s;
        data ~= 0;
    }

    /// Opens an array whose elements align to `elementAlign`.
    ArrayMark beginArray(size_t elementAlign) @safe pure nothrow
    {
        pad(4);
        const at = data.length;
        u32(0);
        pad(elementAlign);
        return ArrayMark(at, data.length);
    }

    /// Closes the array `m` opened, writing its byte length.
    void endArray(ArrayMark m) @safe pure nothrow
    {
        const n = cast(uint)(data.length - m.start);
        data[m.at .. m.at + 4] = [cast(ubyte) n, cast(ubyte)(n >> 8),
            cast(ubyte)(n >> 16), cast(ubyte)(n >> 24)];
    }

    /// A struct or dict entry starts 8-aligned.
    void beginStruct() @safe pure nothrow => pad(8);
}

/// Where an open array's length lives and where its elements start.
struct ArrayMark
{
    size_t at;
    size_t start;
}

/**
Reads values in the message's byte order. A read past the end, or a value
that breaks the format, sets `failed` and yields a zero value; check it
once after a sequence of reads.
*/
struct WireReader
{
    const(ubyte)[] data;
    size_t pos;
    bool bigEndian;
    bool failed;

    /// Bytes left.
    bool empty() const @safe pure nothrow @nogc => pos >= data.length;

    /// Skips padding to a multiple of `n`.
    void alignTo(size_t n) scope @safe pure nothrow @nogc
    {
        const next = (pos + n - 1) / n * n;
        if (next > data.length)
            failed = true;
        else
            pos = next;
    }

    /// `y`
    ubyte u8() scope @safe pure nothrow @nogc
    {
        if (failed || pos + 1 > data.length)
            return fail!ubyte;
        return data[pos++];
    }

    /// `n`/`q`
    ushort u16() scope @safe pure nothrow @nogc
    {
        alignTo(2);
        if (failed || pos + 2 > data.length)
            return fail!ushort;
        const b = data[pos .. pos + 2];
        pos += 2;
        return bigEndian ? cast(ushort)(b[0] << 8 | b[1]) : cast(ushort)(b[1] << 8 | b[0]);
    }

    /// `u`
    uint u32() scope @safe pure nothrow @nogc
    {
        alignTo(4);
        if (failed || pos + 4 > data.length)
            return fail!uint;
        const b = data[pos .. pos + 4];
        pos += 4;
        return bigEndian
            ? (uint(b[0]) << 24 | uint(b[1]) << 16 | uint(b[2]) << 8 | b[3])
            : (uint(b[3]) << 24 | uint(b[2]) << 16 | uint(b[1]) << 8 | b[0]);
    }

    /// `i`
    int i32() scope @safe pure nothrow @nogc => cast(int) u32();

    /// `b`
    bool boolean() scope @safe pure nothrow @nogc
    {
        const v = u32();
        if (v > 1)
            failed = true;
        return v == 1;
    }

    /// `s` and `o`: a slice of `data`.
    const(char)[] str() return scope @safe pure nothrow @nogc
    {
        const n = u32();
        if (failed || n >= data.length - pos || data[pos + n] != 0)
            return fail!(const(char)[]);
        auto s = cast(const(char)[]) data[pos .. pos + n];
        pos += n + 1;
        return s;
    }

    /// `g`, and the type of a `v`.
    const(char)[] signature() return scope @safe pure nothrow @nogc
    {
        const n = u8();
        if (failed || n >= data.length - pos || data[pos + n] != 0)
            return fail!(const(char)[]);
        auto s = cast(const(char)[]) data[pos .. pos + n];
        pos += n + 1;
        return s;
    }

    /**
    Steps over one complete value of the leading type of `sig`, and that
    type off `sig`. Fails on a malformed signature or value.
    */
    void skip(ref scope const(char)[] sig, uint depth = 0) scope @safe pure nothrow @nogc
    {
        if (failed)
            return;
        if (!sig.length || depth > maxNesting)
        {
            failed = true;
            return;
        }
        const t = sig[0];
        sig = sig[1 .. $];
        switch (t)
        {
            case 'y':
                u8();
                break;
            case 'n', 'q':
                u16();
                break;
            case 'b', 'i', 'u', 'h':
                u32();
                break;
            case 'x', 't', 'd':
                alignTo(8);
                if (pos + 8 > data.length)
                    failed = true;
                else
                    pos += 8;
                break;
            case 's', 'o':
                str();
                break;
            case 'g':
                signature();
                break;
            case 'v':
                auto inner = signature();
                skip(inner, depth + 1);
                if (inner.length)
                    failed = true; // a variant holds exactly one type
                break;
            case 'a':
                const len = u32();
                const elem = completeTypeLength(sig);
                if (elem == 0 || failed)
                {
                    failed = true;
                    break;
                }
                alignTo(alignmentOf(sig[0]));
                if (failed || len > data.length - pos)
                {
                    failed = true;
                    break;
                }
                const end = pos + len;
                while (!failed && pos < end)
                {
                    auto e = sig[0 .. elem];
                    skip(e, depth + 1);
                }
                if (pos != end)
                    failed = true;
                sig = sig[elem .. $];
                break;
            case '(':
            case '{':
                const close = t == '(' ? ')' : '}';
                alignTo(8);
                while (!failed && sig.length && sig[0] != close)
                    skip(sig, depth + 1);
                if (!sig.length)
                    failed = true;
                else
                    sig = sig[1 .. $];
                break;
            default:
                failed = true;
        }
    }

    private T fail(T)() scope
    {
        failed = true;
        return T.init;
    }
}

///
@("dbus_wire.WireReader.roundTripsTheBasicTypes")
@safe pure nothrow unittest
{
    WireWriter w;
    w.u8(7);
    w.u32(0xDEADBEEF);
    w.str("héllo");
    w.signature("a{sv}");
    w.boolean(true);
    auto r = WireReader(w.data);
    assert(r.u8() == 7);
    assert(r.u32() == 0xDEADBEEF);
    assert(r.str() == "héllo");
    assert(r.signature() == "a{sv}");
    assert(r.boolean());
    assert(!r.failed && r.empty);
}

///
@("dbus_wire.WireReader.skipsNestedContainers")
@safe pure nothrow unittest
{
    WireWriter w;
    // a{sv} holding {"k": <as ["x", "y"]>}, then a trailing u.
    auto dict = w.beginArray(8);
    w.beginStruct();
    w.str("k");
    w.signature("as");
    auto arr = w.beginArray(4);
    w.str("x");
    w.str("y");
    w.endArray(arr);
    w.endArray(dict);
    w.u32(42);

    auto r = WireReader(w.data);
    const(char)[] sig = "a{sv}u";
    r.skip(sig);
    assert(sig == "u" && !r.failed);
    assert(r.u32() == 42 && r.empty);
}

///
@("dbus_wire.WireReader.rejectsTruncatedAndOverlongValues")
@safe pure nothrow unittest
{
    WireWriter w;
    w.str("abc");
    auto r = WireReader(w.data[0 .. $ - 1]); // the NUL is missing
    r.str();
    assert(r.failed);

    ubyte[8] lies = [0xff, 0xff, 0xff, 0x7f, 0, 0, 0, 0]; // an array of 2 GiB
    auto r2 = WireReader(lies[]);
    const(char)[] sig = "ay";
    r2.skip(sig);
    assert(r2.failed);
}

/// The length of the first complete type in `sig`, 0 when there is none.
size_t completeTypeLength(in char[] sig) @safe pure nothrow @nogc
{
    size_t i;
    // Arrays prefix their element type: `aa{sv}` is one type.
    while (i < sig.length && sig[i] == 'a')
        i++;
    if (i >= sig.length)
        return 0;
    const c = sig[i];
    if (c != '(' && c != '{')
        return c == ')' || c == '}' ? 0 : i + 1;
    int depth;
    for (; i < sig.length; i++)
    {
        if (sig[i] == '(' || sig[i] == '{')
            depth++;
        else if (sig[i] == ')' || sig[i] == '}')
            if (--depth == 0)
                return i + 1;
    }
    return 0;
}

///
@("dbus_wire.completeTypeLength")
@safe pure nothrow @nogc unittest
{
    assert(completeTypeLength("susssasa{sv}i") == 1);
    assert(completeTypeLength("as") == 2);
    assert(completeTypeLength("a{sv}i") == 5);
    assert(completeTypeLength("(ua(ss))x") == 8);
    assert(completeTypeLength("a") == 0);
    assert(completeTypeLength("(u") == 0);
}

/// The alignment of a value whose type starts with `t`.
size_t alignmentOf(char t) @safe pure nothrow @nogc
{
    switch (t)
    {
        case 'n', 'q':
            return 2;
        case 'b', 'i', 'u', 'h', 's', 'o', 'a':
            return 4;
        case 'x', 't', 'd', '(', '{':
            return 8;
        default:
            return 1; // y g v
    }
}

/// A message read off the bus. Strings and the body are copies.
struct Message
{
    MessageType type;
    ubyte flags;
    uint serial;
    uint replySerial; /// the call a return or error answers
    string path;
    string iface;
    string member;
    string errorName;
    string destination;
    string sender;
    string signature; /// the body's
    immutable(ubyte)[] body;
    bool bigEndian;

    /// A reader over the body.
    WireReader bodyReader() const @safe pure nothrow @nogc
        => WireReader(body, 0, bigEndian);
}

/// A message to send. The connection assigns the serial.
struct Outgoing
{
    MessageType type = MessageType.methodCall;
    ubyte flags;
    string path;
    string iface;
    string member;
    string errorName;
    string destination;
    uint replySerial;
    string signature; /// the body's; empty for none
    const(ubyte)[] body;
}

/// `m` as bytes, numbered `serial`.
ubyte[] encodeMessage(in Outgoing m, uint serial) @safe pure nothrow
in (serial != 0)
{
    WireWriter w;
    w.u8('l');
    w.u8(m.type);
    w.u8(m.flags);
    w.u8(1);
    w.u32(cast(uint) m.body.length);
    w.u32(serial);
    auto fields = w.beginArray(8);
    void text(Field f, string sig, in char[] v)
    {
        if (!v.length)
            return;
        w.beginStruct();
        w.u8(f);
        w.signature(sig);
        if (sig == "g")
            w.signature(v);
        else
            w.str(v);
    }

    text(Field.path, "o", m.path);
    text(Field.iface, "s", m.iface);
    text(Field.member, "s", m.member);
    text(Field.errorName, "s", m.errorName);
    if (m.replySerial)
    {
        w.beginStruct();
        w.u8(Field.replySerial);
        w.signature("u");
        w.u32(m.replySerial);
    }
    text(Field.destination, "s", m.destination);
    text(Field.signature, "g", m.signature);
    w.endArray(fields);
    w.pad(8);
    w.data ~= m.body;
    return w.data;
}

/// What `decodeMessage` found at the front of a buffer.
enum Decoded : ubyte
{
    incomplete, /// read more
    ok,         /// one message, `consumed` bytes long
    malformed,  /// not D-Bus: drop the connection
}

/**
Decodes the message at the front of `buf`, in either byte order. A message
larger than `maxMessageBytes` is `malformed`.
*/
Decoded decodeMessage(in ubyte[] buf, out Message m, out size_t consumed) @safe pure nothrow
{
    if (buf.length < 16)
        return Decoded.incomplete;
    if ((buf[0] != 'l' && buf[0] != 'B') || buf[3] != 1)
        return Decoded.malformed;
    auto head = WireReader(buf[0 .. 16], 4, buf[0] == 'B');
    const bodyLen = head.u32();
    head.u32();
    const fieldsLen = head.u32();
    if (fieldsLen > maxMessageBytes || bodyLen > maxMessageBytes)
        return Decoded.malformed;
    const headerEnd = 16 + size_t(fieldsLen);
    const bodyStart = (headerEnd + 7) / 8 * 8;
    const total = bodyStart + bodyLen;
    if (total > maxMessageBytes)
        return Decoded.malformed;
    if (buf.length < total)
        return Decoded.incomplete;

    m.bigEndian = buf[0] == 'B';
    m.type = cast(MessageType) buf[1];
    m.flags = buf[2];
    auto r = WireReader(buf[0 .. headerEnd], 8, m.bigEndian);
    m.serial = r.u32();
    r.u32();
    while (!r.failed && r.pos < headerEnd)
    {
        r.alignTo(8);
        const code = r.u8();
        auto sig = r.signature();
        if (r.failed)
            break;
        string text() => r.str().idup;
        switch (code)
        {
            case Field.path:
                m.path = text();
                break;
            case Field.iface:
                m.iface = text();
                break;
            case Field.member:
                m.member = text();
                break;
            case Field.errorName:
                m.errorName = text();
                break;
            case Field.replySerial:
                m.replySerial = r.u32();
                break;
            case Field.destination:
                m.destination = text();
                break;
            case Field.sender:
                m.sender = text();
                break;
            case Field.signature:
                m.signature = r.signature().idup;
                break;
            default:
                r.skip(sig);
        }
    }
    if (r.failed || m.serial == 0 || m.type == MessageType.invalid
        || m.type > MessageType.signal)
        return Decoded.malformed;
    m.body = buf[bodyStart .. total].idup;
    consumed = total;
    return Decoded.ok;
}

///
@("dbus_wire.encodeMessage.helloMatchesTheSpecification")
@safe pure nothrow unittest
{
    Outgoing hello = {
        path: "/org/freedesktop/DBus", iface: "org.freedesktop.DBus",
        member: "Hello", destination: "org.freedesktop.DBus",
    };
    const bytes = encodeMessage(hello, 1);
    // The fixed header: little-endian, a method call, no flags, version 1,
    // no body, serial 1.
    assert(bytes[0 .. 12] == [
        'l', 1, 0, 1,
        0, 0, 0, 0,
        1, 0, 0, 0,
    ]);
    // The first field: PATH (1), signature "o", the 21-byte path.
    assert(bytes[16 .. 24] == [1, 1, 'o', 0, 21, 0, 0, 0]);
    assert(bytes.length % 8 == 0);

    Message m;
    size_t used;
    assert(decodeMessage(bytes, m, used) == Decoded.ok);
    assert(used == bytes.length);
    assert(m.type == MessageType.methodCall && m.serial == 1);
    assert(m.path == "/org/freedesktop/DBus" && m.member == "Hello");
    assert(m.destination == "org.freedesktop.DBus" && m.iface == "org.freedesktop.DBus");
}

///
@("dbus_wire.decodeMessage.readsBigEndianSignals")
@safe pure nothrow unittest
{
    // A big-endian signal `ActionInvoked(u 7, s "default")`, built by hand
    // as a big-endian peer would send it.
    ubyte[] be(uint v) => [cast(ubyte)(v >> 24), cast(ubyte)(v >> 16),
        cast(ubyte)(v >> 8), cast(ubyte) v];
    ubyte[] body = be(7) ~ be(7) ~ cast(ubyte[]) "default".dup ~ ubyte(0);
    ubyte[] fields;
    void field(ubyte code, char sig, string v)
    {
        while (fields.length % 8)
            fields ~= 0;
        fields ~= [code, 1, cast(ubyte) sig, 0];
        if (sig == 'g')
            fields ~= cast(ubyte) v.length ~ cast(ubyte[]) v.dup ~ ubyte(0);
        else
            fields ~= be(cast(uint) v.length) ~ cast(ubyte[]) v.dup ~ ubyte(0);
    }

    field(3, 's', "ActionInvoked");
    field(8, 'g', "us");
    ubyte[] msg = [ubyte('B'), 4, 0, 1];
    msg ~= be(cast(uint) body.length) ~ be(9)
        ~ be(cast(uint) fields.length) ~ fields;
    while (msg.length % 8)
        msg ~= 0;
    msg ~= body;

    Message m;
    size_t used;
    assert(decodeMessage(msg, m, used) == Decoded.ok);
    assert(m.type == MessageType.signal && m.serial == 9 && m.bigEndian);
    assert(m.member == "ActionInvoked" && m.signature == "us");
    auto r = m.bodyReader;
    assert(r.u32() == 7 && r.str() == "default" && !r.failed);

    assert(decodeMessage(msg[0 .. $ - 1], m, used) == Decoded.incomplete);
    msg[0] = 'X';
    assert(decodeMessage(msg, m, used) == Decoded.malformed);
}

/**
`s`, with every byte sequence D-Bus would refuse replaced by U+FFFD:
invalid UTF-8, NUL, and the noncharacters older buses reject. A bus drops a
client that sends any of them — and a notification's text comes from the
program in the pane.
*/
string scrubUtf8(in char[] s) @safe pure nothrow
{
    // Decoded by hand: Phobos' replacing `decode` swallows the bytes after
    // an invalid lead byte along with it.
    static immutable replacement = "\uFFFD";
    char[] o;
    o.reserve(s.length);
    for (size_t i; i < s.length;)
    {
        const b = s[i];
        size_t n;
        uint c, min;
        if (b < 0x80)
            (n = 1, c = b);
        else if (b >= 0xC2 && b <= 0xDF)
            (n = 2, c = b & 0x1F, min = 0x80);
        else if (b >= 0xE0 && b <= 0xEF)
            (n = 3, c = b & 0x0F, min = 0x800);
        else if (b >= 0xF0 && b <= 0xF4)
            (n = 4, c = b & 0x07, min = 0x10000);
        bool ok = n > 0 && i + n <= s.length;
        for (size_t k = 1; ok && k < n; k++)
        {
            ok = (s[i + k] & 0xC0) == 0x80;
            c = c << 6 | (s[i + k] & 0x3F);
        }
        ok = ok && c >= min && c <= 0x10FFFF && !(c >= 0xD800 && c <= 0xDFFF);
        const allowed = ok && c != 0 && !(c >= 0xFDD0 && c <= 0xFDEF)
            && (c & 0xFFFE) != 0xFFFE;
        if (allowed)
            o ~= s[i .. i + n];
        else
            o ~= replacement;
        // An ill-formed sequence costs one byte, so the next starts afresh.
        i += ok ? n : 1;
    }
    return (() @trusted => cast(string) o)();
}

///
@("dbus_wire.scrubUtf8")
@safe pure nothrow unittest
{
    assert(scrubUtf8("plain ✓") == "plain ✓");
    assert(scrubUtf8("a\xffb") == "a\uFFFDb");
    assert(scrubUtf8("a\0b") == "a\uFFFDb");
    assert(scrubUtf8("\uFFFE") == "\uFFFD");
    assert(scrubUtf8("\xed\xa0\x80") != "\xed\xa0\x80"); // a UTF-16 surrogate
}

/**
The first line of `EXTERNAL` authentication: the leading NUL byte the
protocol requires, then `AUTH EXTERNAL` with the user id as hex-encoded
decimal digits.
*/
string authExternalLine(uint uid) @safe pure nothrow
{
    import std.conv : to;

    static immutable hex = "0123456789abcdef";
    string id;
    foreach (c; uid.to!string)
        id ~= [hex[c >> 4], hex[c & 0xF]];
    return "\0AUTH EXTERNAL " ~ id ~ "\r\n";
}

///
@("dbus_wire.authExternalLine")
@safe pure nothrow unittest
{
    assert(authExternalLine(1000) == "\0AUTH EXTERNAL 31303030\r\n");
    assert(authExternalLine(0) == "\0AUTH EXTERNAL 30\r\n");
}

/// A socket a `unix:` address names.
struct UnixAddress
{
    string path;
    bool abstract_; /// in the Linux abstract namespace
}

/**
The first connectable `unix:` entry of a D-Bus address list
(`DBUS_SESSION_BUS_ADDRESS`): `unix:path=…` or `unix:abstract=…`, values
percent-decoded. `tmpdir=`/`dir=` are listen-only and skipped.
*/
bool parseBusAddress(string address, out UnixAddress a) @safe pure nothrow
{
    // Byte-wise: `splitter` on a `char` decodes, and so may throw.
    static string cut(ref string s, char sep)
    {
        size_t i;
        while (i < s.length && s[i] != sep)
            i++;
        auto head = s[0 .. i];
        s = i < s.length ? s[i + 1 .. $] : null;
        return head;
    }

    for (string rest = address; rest.length;)
    {
        auto entry = cut(rest, ';');
        if (entry.length < 5 || entry[0 .. 5] != "unix:")
            continue;
        for (string params = entry[5 .. $]; params.length;)
        {
            auto value = cut(params, ',');
            const key = cut(value, '=');
            if (key != "path" && key != "abstract")
                continue;
            string decoded;
            if (!percentDecode(value, decoded) || !decoded.length)
                return false;
            a = UnixAddress(decoded, key == "abstract");
            return true;
        }
    }
    return false;
}

///
@("dbus_wire.parseBusAddress")
@safe pure nothrow unittest
{
    UnixAddress a;
    assert(parseBusAddress("unix:path=/run/user/1000/bus", a));
    assert(a.path == "/run/user/1000/bus" && !a.abstract_);
    assert(parseBusAddress("tcp:host=x;unix:abstract=/tmp/dbus-Ab%2c1,guid=ff", a));
    assert(a.path == "/tmp/dbus-Ab,1" && a.abstract_);
    assert(!parseBusAddress("unix:tmpdir=/tmp", a));
    assert(!parseBusAddress("", a));
}

private bool percentDecode(in char[] s, out string o) @safe pure nothrow
{
    int hexValue(char c)
    {
        if (c >= '0' && c <= '9')
            return c - '0';
        if (c >= 'a' && c <= 'f')
            return c - 'a' + 10;
        if (c >= 'A' && c <= 'F')
            return c - 'A' + 10;
        return -1;
    }

    char[] r;
    for (size_t i; i < s.length; i++)
    {
        if (s[i] != '%')
        {
            r ~= s[i];
            continue;
        }
        if (i + 2 >= s.length)
            return false;
        const hi = hexValue(s[i + 1]), lo = hexValue(s[i + 2]);
        if (hi < 0 || lo < 0)
            return false;
        r ~= cast(char)(hi << 4 | lo);
        i += 2;
    }
    o = r.idup;
    return true;
}
