/**
The D-Bus wire format: values marshalled into a buffer, and read back by a
cursor over a received message's bytes.

Every value sits at an offset that is a multiple of its alignment, counted
from the start of the message: 1 for bytes, signatures and variants, 2 for
16-bit integers, 4 for 32-bit ones, booleans, strings and array lengths, 8
for 64-bit values, doubles, structs and dict entries. A message body starts
at an 8-byte boundary, so a body written on its own, from offset 0, aligns
as it will in the message.

$(LREF Reader) never allocates and never throws: a read past the end, or a
malformed value, sets `failed` and yields a zero value, and every later read
fails too. A caller reads the shape it expects and checks `failed` once.
*/
module sparkles.dbus.wire;

import sparkles.base.buffer : UniqueBuffer;

@safe pure nothrow @nogc:

/// The alignment of a value whose signature starts with `code`; 0 for a
/// code that is not a type.
size_t alignmentOf(char code)
{
    switch (code)
    {
        case 'y', 'g', 'v': return 1;
        case 'n', 'q': return 2;
        case 'b', 'i', 'u', 's', 'o', 'a', 'h': return 4;
        case 'x', 't', 'd', '(', '{': return 8;
        default: return 0;
    }
}

///
@("dbus.wire.alignmentOf")
unittest
{
    assert(alignmentOf('y') == 1 && alignmentOf('s') == 4 && alignmentOf('(') == 8);
    assert(alignmentOf('z') == 0);
}

/**
The length of the first complete type in `signature`, or 0 when it does not
start with one: `a{sv}` in `a{sv}u` is 5 long. As the specification bounds
them: at most 32 nested arrays and 32 nested structs, no empty struct, and a
dict entry only as an array's element.
*/
size_t completeTypeLength(scope const(char)[] signature)
{
    return completeType(signature, 0, 0, 0, false);
}

/// Whether `signature` is a sequence of complete types: a message body's,
/// or empty.
bool isSignature(scope const(char)[] signature)
{
    if (signature.length > 255)
        return false;
    for (size_t at = 0; at < signature.length;)
    {
        const n = completeTypeLength(signature[at .. $]);
        if (!n)
            return false;
        at += n;
    }
    return true;
}

private size_t completeType(scope const(char)[] s, size_t at, uint arrays, uint structs,
    bool inArray)
{
    if (at >= s.length)
        return 0;
    const c = s[at];
    switch (c)
    {
        case 'a':
            if (arrays == 32)
                return 0;
            const element = completeType(s, at + 1, arrays + 1, structs, true);
            return element ? 1 + element : 0;
        case '(':
            if (structs == 32)
                return 0;
            size_t i = at + 1;
            if (i < s.length && s[i] == ')')
                return 0; // an empty struct is not a type
            while (i < s.length && s[i] != ')')
            {
                const n = completeType(s, i, arrays, structs + 1, false);
                if (!n)
                    return 0;
                i += n;
            }
            return i < s.length ? i + 1 - at : 0;
        case '{':
            // A dict entry: an array's element only, a basic key, then one
            // complete type. It counts as a struct.
            if (!inArray || structs == 32 || at + 1 >= s.length || !isBasic(s[at + 1]))
                return 0;
            const value = completeType(s, at + 2, arrays, structs + 1, false);
            if (!value || at + 2 + value >= s.length || s[at + 2 + value] != '}')
                return 0;
            return 3 + value;
        default:
            return alignmentOf(c) ? 1 : 0;
    }
}

/// Whether `s` is what a D-Bus string may hold: well-formed UTF-8 with no
/// NUL, and no surrogate or code point past U+10FFFF.
bool isValidString(scope const(char)[] s)
{
    for (size_t i = 0; i < s.length;)
    {
        const b = ubyte(s[i]);
        if (b == 0)
            return false;
        if (b < 0x80)
        {
            ++i;
            continue;
        }
        size_t n;
        uint cp;
        if ((b & 0xE0) == 0xC0) { n = 2; cp = b & 0x1F; }
        else if ((b & 0xF0) == 0xE0) { n = 3; cp = b & 0x0F; }
        else if ((b & 0xF8) == 0xF0) { n = 4; cp = b & 0x07; }
        else
            return false;
        if (i + n > s.length)
            return false;
        foreach (k; 1 .. n)
        {
            const t = ubyte(s[i + k]);
            if ((t & 0xC0) != 0x80)
                return false;
            cp = (cp << 6) | (t & 0x3F);
        }
        // Overlong forms, surrogates and past U+10FFFF.
        if ((n == 2 && cp < 0x80) || (n == 3 && cp < 0x800) || (n == 4 && cp < 0x10000)
            || (cp >= 0xD800 && cp <= 0xDFFF) || cp > 0x10FFFF)
            return false;
        i += n;
    }
    return true;
}

///
@("dbus.wire.isValidString")
unittest
{
    assert(isValidString("café ✓ 𝄞") && isValidString(""));
    assert(!isValidString("a\0b") && !isValidString("\xC0\x80") && !isValidString("\xED\xA0\x80"));
    assert(!isValidString("\xE2\x9C"), "cut short");
}

private bool isBasic(char c)
    => c == 'y' || c == 'b' || c == 'n' || c == 'q' || c == 'i' || c == 'u' || c == 'x'
    || c == 't' || c == 'd' || c == 's' || c == 'o' || c == 'g' || c == 'h';

///
@("dbus.wire.completeTypeLength")
unittest
{
    assert(completeTypeLength("a{sv}u") == 5);
    assert(completeTypeLength("(ddd)") == 5);
    assert(completeTypeLength("a{sa{sv}}") == 9);
    assert(completeTypeLength("v") == 1);
    assert(completeTypeLength("()") == 0 && completeTypeLength("a") == 0);
    assert(completeTypeLength("a{vs}") == 0, "a dict entry's key is basic");
    assert(completeTypeLength("{sv}") == 0 && completeTypeLength("({sv})") == 0,
        "a dict entry is an array's element only");
    assert(completeTypeLength("(ii") == 0);
    char[97] deep;
    deep[0 .. 32] = 'a';
    deep[32 .. 64] = '(';
    deep[64] = 'i';
    deep[65 .. 97] = ')';
    assert(completeTypeLength(deep[]) == 97, "32 arrays and 32 structs are allowed");
    char[67] deeper;
    deeper[0 .. 33] = '(';
    deeper[33] = 'i';
    deeper[34 .. 67] = ')';
    assert(completeTypeLength(deeper[]) == 0, "33 structs are not");
    assert(isSignature("sa{sv}u") && isSignature("") && !isSignature("a") && !isSignature("z"));
}

/**
Marshals values, little-endian, into a growing buffer. Alignment is from the
start of `bytes`, which is the start of a message or of its body.
*/
struct Writer
{
    UniqueBuffer!(ubyte, 256) bytes; ///

@safe pure nothrow @nogc:

    /// The bytes written so far.
    const(ubyte)[] data() const return scope => bytes[];

    /// Zero bytes to the next multiple of `n`.
    void alignTo(size_t n)
    in (n > 0)
    {
        while (bytes.length % n)
            bytes ~= 0;
    }

    void u8(ubyte v) { bytes ~= v; } ///
    void u16(ushort v) { alignTo(2); put(v, 2); } ///
    void u32(uint v) { alignTo(4); put(v, 4); } ///
    void i32(int v) { u32(cast(uint) v); } ///
    void u64(ulong v) { alignTo(8); put(v, 8); } ///
    void boolean(bool v) { u32(v ? 1 : 0); } ///

    /// An IEEE 754 double.
    void f64(double v) @trusted
    {
        ulong bits = *cast(ulong*) &v;
        u64(bits);
    }

    /// A string or an object path: its length, its bytes and a NUL.
    void str(scope const(char)[] s)
    in (isValidString(s), "a D-Bus string is UTF-8 without a NUL; the bus drops a connection that sends another")
    {
        u32(cast(uint) s.length);
        foreach (c; s)
            bytes ~= cast(ubyte) c;
        bytes ~= 0;
    }

    /// A signature: a one-byte length, its bytes and a NUL.
    void sig(scope const(char)[] s)
    in (s.length <= 255, "a signature is at most 255 bytes")
    {
        u8(cast(ubyte) s.length);
        foreach (c; s)
            bytes ~= cast(ubyte) c;
        bytes ~= 0;
    }

    /**
    Starts an array of elements aligned to `elementAlignment`; the value is
    where its length goes, for $(LREF endArray).
    */
    size_t beginArray(size_t elementAlignment)
    {
        u32(0);
        const lengthAt = bytes.length - 4;
        alignTo(elementAlignment);
        return lengthAt;
    }

    /// Ends the array begun at `lengthAt`: its length is the bytes after the
    /// padding that follows the length.
    void endArray(size_t lengthAt, size_t elementAlignment)
    {
        auto first = lengthAt + 4;
        while (first % elementAlignment)
            ++first;
        const length = cast(uint)(bytes.length > first ? bytes.length - first : 0);
        foreach (i; 0 .. 4)
            bytes[lengthAt + i] = cast(ubyte)(length >> (8 * i));
    }

    /// A struct or dict entry starts at an 8-byte boundary.
    void beginStruct() { alignTo(8); }

    private void put(ulong v, size_t n)
    {
        foreach (i; 0 .. n)
            bytes ~= cast(ubyte)(v >> (8 * i));
    }
}

///
@("dbus.wire.writer.alignsFromTheStart")
unittest
{
    Writer w;
    w.u8(1);
    w.u32(0x04030201);
    w.str("ab");
    assert(w.data == [1, 0, 0, 0, 1, 2, 3, 4, 2, 0, 0, 0, 'a', 'b', 0]);
    w.u64(5);
    assert(w.data.length == 24 && w.data[16] == 5, "8-aligned");
}

///
@("dbus.wire.writer.arrayLengthExcludesItsPadding")
unittest
{
    Writer w;
    const at = w.beginArray(8); // an array of structs
    w.beginStruct();
    w.u32(7);
    w.beginStruct();
    w.u32(9);
    w.endArray(at, 8);
    // length 0..4, padding 4..8, elements 8..20.
    assert(w.data.length == 20);
    assert(w.data[0 .. 4] == [12, 0, 0, 0]);
}

/**
Reads values from a message's bytes, little- or big-endian as the message
says. Offsets for alignment are from `data`'s start: the message's start, or
the body's, which is 8-aligned in the message.
*/
struct Reader
{
    const(ubyte)[] data; ///
    size_t pos;          ///
    bool bigEndian;      ///
    bool failed;         /// a read ran past the end or met a malformed value

@safe pure nothrow @nogc:

    /// Whether every byte has been read.
    bool atEnd() scope const => pos >= data.length;

    /// Skips to the next multiple of `n`; the padding must be zero.
    void alignTo(size_t n) scope
    in (n > 0)
    {
        while (!failed && pos % n)
        {
            if (pos >= data.length || data[pos] != 0)
                return fail();
            ++pos;
        }
    }

    ubyte u8() scope ///
    {
        if (failed || pos >= data.length)
            { fail(); return ubyte(0); }
        return data[pos++];
    }

    ushort u16() scope => cast(ushort) get(2); ///
    uint u32() scope => cast(uint) get(4); ///
    int i32() scope => cast(int) get(4); ///
    ulong u64() scope => get(8); ///
    long i64() scope => cast(long) get(8); ///

    /// A boolean: 0 or 1, anything else malformed.
    bool boolean() scope
    {
        const v = u32();
        if (v > 1)
            fail();
        return v == 1;
    }

    /// An IEEE 754 double.
    double f64() scope @trusted
    {
        ulong bits = u64();
        return *cast(double*) &bits;
    }

    /// A string or object path, without its NUL: a slice of `data`.
    const(char)[] str() return scope
    {
        const n = u32();
        return chars(n);
    }

    /// A signature, without its NUL: a slice of `data`.
    const(char)[] sig() return scope
    {
        const n = u8();
        return chars(n);
    }

    /// Starts reading an array; the value is where it ends, for
    /// $(LREF more).
    size_t beginArray(size_t elementAlignment) scope
    {
        const length = u32();
        alignTo(elementAlignment);
        // The spec caps an array at 64 MiB.
        if (failed || pos > data.length || length > 64 << 20 || length > data.length - pos)
            { fail(); return pos; }
        return pos + length;
    }

    /// Whether the array ending at `end` has another element.
    bool more(size_t end) scope const => !failed && pos < end;

    /// A struct or dict entry starts at an 8-byte boundary.
    void beginStruct() scope { alignTo(8); }

    /// A variant's signature, after which its one value follows.
    const(char)[] variant() return scope
    {
        const s = sig();
        if (!failed && (s.length == 0 || completeTypeLength(s) != s.length))
            fail();
        return s;
    }

    /**
    Skips one value of the complete type at the start of `signature`, and
    returns the rest of the signature: what is not wanted is read past.
    */
    const(char)[] skip(return scope const(char)[] signature) scope
    {
        size_t depth;
        skipOne(signature, depth);
        return signature;
    }

    private void skipOne(ref scope const(char)[] s, ref size_t depth) scope
    {
        if (failed || s.length == 0 || ++depth > 65) // 32 arrays, 32 structs, a leaf
            return fail();
        scope (exit)
            --depth;
        const c = s[0];
        s = s[1 .. $];
        switch (c)
        {
            case 'y': u8(); break;
            case 'n', 'q': u16(); break;
            case 'b': boolean(); break;
            case 'i', 'u', 'h': u32(); break;
            case 'x', 't', 'd': u64(); break;
            case 's', 'o': str(); break;
            case 'g': sig(); break;
            case 'v':
                auto inner = variant();
                if (!failed)
                    skipOne(inner, depth);
                break;
            case 'a':
                const n = completeType(s, 0, 0, 0, true); // an array's element
                if (!n)
                    return fail();
                const element = s[0 .. n];
                s = s[n .. $];
                const end = beginArray(alignmentOf(element[0]));
                while (more(end))
                {
                    const(char)[] e = element;
                    skipOne(e, depth);
                }
                if (pos != end)
                    fail();
                break;
            case '(', '{':
                beginStruct();
                const close = c == '(' ? ')' : '}';
                while (!failed && s.length && s[0] != close)
                    skipOne(s, depth);
                if (s.length == 0)
                    return fail();
                s = s[1 .. $];
                break;
            default:
                fail();
        }
    }

    private const(char)[] chars(uint n) return scope @trusted
    {
        if (failed || pos > data.length || n > data.length - pos || data.length - pos - n < 1)
            { fail(); return null; }
        auto s = cast(const(char)[]) data[pos .. pos + n];
        pos += n;
        if (data[pos] != 0)
            { fail(); return null; }
        ++pos;
        if (!isValidString(s))
            { fail(); return null; }
        return s;
    }

    private ulong get(size_t n) scope
    {
        alignTo(n);
        if (failed || pos > data.length || n > data.length - pos)
            { fail(); return 0; }
        ulong v;
        foreach (i; 0 .. n)
        {
            const b = ulong(data[pos + i]);
            v |= bigEndian ? b << (8 * (n - 1 - i)) : b << (8 * i);
        }
        pos += n;
        return v;
    }

    private void fail() scope
    {
        failed = true;
    }
}

///
@("dbus.wire.reader.readsWhatTheWriterWrote")
unittest
{
    Writer w;
    w.u8(7);
    w.boolean(true);
    w.str("dark");
    w.sig("(ddd)");
    w.beginStruct();
    w.f64(0.5);
    w.f64(1);
    w.f64(0.25);
    auto r = Reader(w.data);
    assert(r.u8() == 7 && r.boolean() && r.str() == "dark" && r.sig() == "(ddd)");
    r.beginStruct();
    assert(r.f64() == 0.5 && r.f64() == 1 && r.f64() == 0.25);
    assert(!r.failed && r.atEnd);
}

///
@("dbus.wire.reader.failsInsteadOfOverrunning")
unittest
{
    ubyte[6] bytes = [200, 0, 0, 0, 'a', 0]; // a 200-byte string in 6 bytes
    auto r = Reader(bytes[]);
    assert(r.str() is null && r.failed);
    assert(r.u32() == 0, "and stays failed");

    ubyte[8] padded = [1, 9, 0, 0, 2, 0, 0, 0]; // non-zero padding
    auto p = Reader(padded[]);
    p.u8();
    p.u32();
    assert(p.failed);

    ubyte[4] bad = [2, 0, 0, 0]; // a boolean of 2
    auto b = Reader(bad[]);
    b.boolean();
    assert(b.failed);
}

///
@("dbus.wire.reader.bigEndian")
unittest
{
    ubyte[8] bytes = [0, 0, 0, 5, 0, 0, 0, 1];
    auto r = Reader(bytes[], bigEndian: true);
    assert(r.u32() == 5 && r.boolean());
}

///
@("dbus.wire.reader.skipsWhatIsNotWanted")
unittest
{
    // a{sv} holding {"a": <u 1>, "b": <(ddd) …>}, then a u it was skipped to.
    Writer w;
    const at = w.beginArray(8);
    w.beginStruct();
    w.str("a");
    w.sig("u");
    w.u32(1);
    w.beginStruct();
    w.str("b");
    w.sig("(ddd)");
    w.beginStruct();
    w.f64(1);
    w.f64(2);
    w.f64(3);
    w.endArray(at, 8);
    w.u32(42);
    auto r = Reader(w.data);
    assert(r.skip("a{sv}u") == "u");
    assert(r.u32() == 42 && !r.failed && r.atEnd);
}

///
@("dbus.wire.reader.arrayBoundsAreChecked")
unittest
{
    ubyte[8] bytes = [100, 0, 0, 0, 1, 0, 0, 0];
    auto r = Reader(bytes[]);
    r.beginArray(4);
    assert(r.failed, "an array longer than the message");
}
