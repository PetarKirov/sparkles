/**
D-Bus messages: the fixed header, the header fields, and the body after
them.

A message is 16 fixed bytes — endianness (`l` or `B`), type, flags,
protocol version 1, the body's length, the serial, and the length of the
header-field array that follows — then that array of `(yv)` fields, padding
to 8, and the body. $(LREF messageLength) frames a stream of them;
$(LREF parseMessage) reads one; $(LREF encodeMessage) writes one.
*/
module sparkles.dbus.message;

import sparkles.dbus.wire : isSignature, Reader, Writer;

@safe pure nothrow @nogc:

/// What a message is.
enum MessageType : ubyte
{
    invalid,
    methodCall,   ///
    methodReturn, ///
    error,        ///
    signal,       ///
}

/// Header flags.
enum MessageFlags : ubyte
{
    none,
    noReplyExpected = 1, ///
    noAutoStart = 2,     ///
}

/// The longest message the spec allows: 128 MiB.
enum size_t maxMessageLength = 128 << 20;

/**
A message's header, its strings slices of the message's bytes.
*/
struct Header
{
    MessageType type; ///
    ubyte flags;      ///
    uint serial;      ///
    uint replySerial; /// for a return or an error: the call's serial
    const(char)[] path, iface, member, errorName, destination, sender; ///
    const(char)[] signature; /// the body's; empty for none
}

/**
The length of the message at the start of `bytes` once its first 16 bytes
are there; 0 while fewer have arrived, and `size_t.max` for a header no
message can have (a bad endianness, version or length).
*/
size_t messageLength(scope const(ubyte)[] bytes)
{
    if (bytes.length < 16)
        return 0;
    if ((bytes[0] != 'l' && bytes[0] != 'B') || bytes[3] != 1)
        return size_t.max;
    auto r = Reader(bytes[0 .. 16], bigEndian: bytes[0] == 'B');
    r.pos = 4;
    const body = r.u32();
    r.pos = 12;
    const fields = r.u32();
    const header = (16 + size_t(fields) + 7) & ~size_t(7);
    if (body > maxMessageLength || fields > maxMessageLength
        || header + body > maxMessageLength)
        return size_t.max;
    return header + body;
}

///
@("dbus.message.messageLength")
unittest
{
    ubyte[16] head = ['l', 1, 0, 1, 4, 0, 0, 0, 1, 0, 0, 0, 9, 0, 0, 0];
    assert(messageLength(head[0 .. 15]) == 0, "not yet");
    assert(messageLength(head[]) == 32 + 4, "16 + 9 fields padded to 32, and the body");
    head[3] = 2;
    assert(messageLength(head[]) == size_t.max, "only version 1");
}

/// A message read: its header, and a reader over its body.
struct Parsed
{
    bool ok;       /// `false` for a malformed message
    Header header; ///
    Reader body;   ///
}

/**
Reads the whole message `bytes` (as long as $(LREF messageLength) says): its
header, and a reader over its body. Both slice `bytes`, which must outlive
them.
*/
Parsed parseMessage(const(ubyte)[] bytes)
{
    Parsed p;
    ref header = p.header;
    const length = messageLength(bytes);
    if (length == 0 || length == size_t.max || length != bytes.length)
        return p;
    auto r = Reader(bytes, bigEndian: bytes[0] == 'B');
    r.pos = 1;
    header.type = cast(MessageType) r.u8();
    header.flags = r.u8();
    r.u8();
    const bodyLength = r.u32();
    header.serial = r.u32();
    // Each field at most once; code 0 never, and file descriptors never:
    // none is negotiated, so a message claiming some cannot be read whole.
    uint seen;
    const end = r.beginArray(8);
    while (r.more(end))
    {
        r.beginStruct();
        const code = r.u8();
        const sig = r.variant();
        if (code == 0 || code == 9 || (code < 32 && (seen & (1u << code))))
            return p;
        if (code < 32)
            seen |= 1u << code;
        switch (code)
        {
            case 1: if (sig == "o") header.path = r.str(); else return p; break;
            case 2: if (sig == "s") header.iface = r.str(); else return p; break;
            case 3: if (sig == "s") header.member = r.str(); else return p; break;
            case 4: if (sig == "s") header.errorName = r.str(); else return p; break;
            case 5: if (sig == "u") header.replySerial = r.u32(); else return p; break;
            case 6: if (sig == "s") header.destination = r.str(); else return p; break;
            case 7: if (sig == "s") header.sender = r.str(); else return p; break;
            case 8: if (sig == "g") header.signature = r.sig(); else return p; break;
            default: r.skip(sig); break; // unknown fields are ignored
        }
    }
    r.alignTo(8);
    if (r.failed || header.serial == 0 || header.type == MessageType.invalid
        || header.type > MessageType.signal || r.pos + bodyLength != bytes.length)
        return p;
    // The fields each type requires: a call its path and member, a signal
    // its interface too, an error its name and the call's serial, a return
    // that serial.
    enum path = 1u << 1, iface = 1u << 2, member = 1u << 3, errorName = 1u << 4,
        replySerial = 1u << 5;
    const uint required = header.type == MessageType.methodCall ? path | member
        : header.type == MessageType.signal ? path | iface | member
        : header.type == MessageType.error ? errorName | replySerial : replySerial;
    if ((seen & required) != required || !isSignature(header.signature))
        return p;
    p.body = Reader(bytes[r.pos .. $], bigEndian: bytes[0] == 'B');
    // The body is what its signature says, whole.
    auto check = p.body;
    const(char)[] rest = header.signature;
    while (rest.length && !check.failed)
        rest = check.skip(rest);
    if (check.failed || !check.atEnd)
        return p;
    p.ok = true;
    return p;
}

/**
Writes a message whose body `body` has signature `signature` into `out_`,
which must be empty: alignment counts from the message's start.
*/
void encodeMessage(ref Writer out_, in Header header, scope const(ubyte)[] body)
in (header.serial != 0, "serials start at 1")
in (out_.data.length == 0, "a message aligns from its own start: one per writer")
{
    out_.u8('l');
    out_.u8(header.type);
    out_.u8(header.flags);
    out_.u8(1);
    out_.u32(cast(uint) body.length);
    out_.u32(header.serial);
    const fields = out_.beginArray(8);
    void field(ubyte code, string sig, scope const(char)[] value)
    {
        if (value.length == 0)
            return;
        out_.beginStruct();
        out_.u8(code);
        out_.sig(sig);
        if (sig == "g")
            out_.sig(value);
        else
            out_.str(value);
    }
    field(1, "o", header.path);
    field(2, "s", header.iface);
    field(3, "s", header.member);
    field(4, "s", header.errorName);
    if (header.replySerial)
    {
        out_.beginStruct();
        out_.u8(5);
        out_.sig("u");
        out_.u32(header.replySerial);
    }
    field(6, "s", header.destination);
    field(7, "s", header.sender);
    field(8, "g", header.signature);
    out_.endArray(fields, 8);
    out_.alignTo(8);
    foreach (b; body)
        out_.bytes ~= b;
}

///
@("dbus.message.roundTrip")
unittest
{
    Writer body;
    body.str("org.freedesktop.appearance");
    body.str("color-scheme");
    Writer msg;
    encodeMessage(msg, Header(type: MessageType.methodCall, serial: 7,
        path: "/org/freedesktop/portal/desktop", iface: "org.freedesktop.portal.Settings",
        member: "ReadOne", destination: "org.freedesktop.portal.Desktop", signature: "ss"),
        body.data);
    assert(messageLength(msg.data) == msg.data.length);
    auto p = parseMessage(msg.data);
    assert(p.ok);
    const h = p.header;
    auto r = p.body;
    assert(h.type == MessageType.methodCall && h.serial == 7 && h.member == "ReadOne");
    assert(h.path == "/org/freedesktop/portal/desktop" && h.signature == "ss");
    assert(h.destination == "org.freedesktop.portal.Desktop");
    assert(r.str() == "org.freedesktop.appearance" && r.str() == "color-scheme" && r.atEnd);
}

///
@("dbus.message.requiredFieldsAndAWholeBody")
unittest
{
    Writer missing;
    encodeMessage(missing, Header(type: MessageType.methodReturn, serial: 1), null);
    assert(!parseMessage(missing.data).ok, "a return without the call's serial");

    Writer body;
    body.u32(7);
    Writer short_;
    encodeMessage(short_, Header(type: MessageType.methodReturn, serial: 1, replySerial: 1,
        signature: "uu"), body.data);
    assert(!parseMessage(short_.data).ok, "a body shorter than its signature");
    Writer long_;
    encodeMessage(long_, Header(type: MessageType.methodReturn, serial: 1, replySerial: 1),
        body.data);
    assert(!parseMessage(long_.data).ok, "a body without a signature");
    Writer whole;
    encodeMessage(whole, Header(type: MessageType.methodReturn, serial: 1, replySerial: 1,
        signature: "u"), body.data);
    assert(parseMessage(whole.data).ok);
}

@("dbus.message.rejectsAFieldOfTheWrongType")
unittest
{
    Writer msg;
    encodeMessage(msg, Header(type: MessageType.signal, serial: 1, path: "/a", iface: "a.b",
        member: "C"), null);
    assert(parseMessage(msg.data).ok && parseMessage(msg.data).header.type == MessageType.signal);
    // The path field (code 1) claims signature "s", not "o".
    ubyte[256] copy;
    auto bytes = copy[0 .. msg.data.length];
    bytes[] = msg.data[];
    foreach (i; 16 .. bytes.length - 1)
        if (bytes[i] == 1 && bytes[i + 1] == 1 && bytes[i + 2] == 'o')
        {
            bytes[i + 2] = 's';
            break;
        }
    assert(!parseMessage(bytes).ok);
}
