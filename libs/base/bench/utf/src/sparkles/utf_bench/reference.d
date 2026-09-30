module sparkles.utf_bench.reference;

/// Independent byte-at-a-time RFC 3629 reference; does not call Sparkles or simdutf.
bool decode8(scope const(char)[] input, ref size_t at, out uint scalar)
    @safe pure nothrow @nogc
{
    if (at == input.length)
        return false;
    const first = cast(ubyte) input[at];
    size_t width;
    uint minimum;
    if (first < 0x80) { width = 1; scalar = first; minimum = 0; }
    else if (first >= 0xC2 && first <= 0xDF) { width = 2; scalar = first & 31; minimum = 0x80; }
    else if (first >= 0xE0 && first <= 0xEF) { width = 3; scalar = first & 15; minimum = 0x800; }
    else if (first >= 0xF0 && first <= 0xF4) { width = 4; scalar = first & 7; minimum = 0x10000; }
    else return false;
    if (input.length - at < width)
        return false;
    foreach (i; 1 .. width)
    {
        const next = cast(ubyte) input[at + i];
        if ((next & 0xC0) != 0x80)
            return false;
        scalar = (scalar << 6) | (next & 63);
    }
    if (scalar < minimum || scalar > 0x10FFFF || (scalar >= 0xD800 && scalar <= 0xDFFF))
        return false;
    at += width;
    return true;
}

size_t firstInvalid8(scope const(char)[] input) @safe pure nothrow @nogc
{
    size_t at;
    uint cp;
    while (at < input.length)
        if (!decode8(input, at, cp))
            return at;
    return at;
}

bool decode16(scope const(wchar)[] input, ref size_t at, out uint cp)
    @safe pure nothrow @nogc
{
    if (at == input.length)
        return false;
    cp = input[at];
    if (cp >= 0xD800 && cp <= 0xDBFF)
    {
        if (input.length - at < 2 || input[at + 1] < 0xDC00 || input[at + 1] > 0xDFFF)
            return false;
        cp = 0x10000 + ((cp - 0xD800) << 10) + (input[at + 1] - 0xDC00);
        at += 2;
    }
    else
    {
        if (cp >= 0xDC00 && cp <= 0xDFFF)
            return false;
        at++;
    }
    return true;
}

struct Conversion
{
    bool valid;
    size_t count; // output units on success, first invalid source offset on failure
}

/// Two passes deliberately preserve fail-before-write, like Sparkles' bounded API.
Conversion to16(scope const(char)[] input, scope wchar[] output) @safe pure nothrow @nogc
{
    size_t at, needed;
    uint cp;
    while (at < input.length)
    {
        if (!decode8(input, at, cp)) return Conversion(false, at);
        needed += cp < 0x10000 ? 1 : 2;
    }
    if (needed > output.length) return Conversion(false, input.length);
    at = 0;
    size_t written;
    while (at < input.length)
    {
        decode8(input, at, cp);
        if (cp < 0x10000) output[written++] = cast(wchar) cp;
        else
        {
            cp -= 0x10000;
            output[written++] = cast(wchar)(0xD800 | (cp >> 10));
            output[written++] = cast(wchar)(0xDC00 | (cp & 1023));
        }
    }
    return Conversion(true, written);
}

Conversion to8(scope const(wchar)[] input, scope char[] output) @safe pure nothrow @nogc
{
    size_t at, needed;
    uint cp;
    while (at < input.length)
    {
        if (!decode16(input, at, cp)) return Conversion(false, at);
        needed += cp < 0x80 ? 1 : cp < 0x800 ? 2 : cp < 0x10000 ? 3 : 4;
    }
    if (needed > output.length) return Conversion(false, input.length);
    at = 0;
    size_t written;
    while (at < input.length)
    {
        decode16(input, at, cp);
        if (cp < 0x80) output[written++] = cast(char) cp;
        else
        {
            const size_t width = cp < 0x800 ? 2 : cp < 0x10000 ? 3 : 4;
            const uint prefix = width == 2 ? 0xC0 : width == 3 ? 0xE0 : 0xF0;
            output[written++] = cast(char)(prefix | (cp >> (6 * (width - 1))));
            for (size_t remaining = width - 1; remaining; remaining--)
                output[written++] = cast(char)(0x80 | ((cp >> (6 * (remaining - 1))) & 63));
        }
    }
    return Conversion(true, written);
}

ulong checksum(T)(scope const(T)[] values) @safe pure nothrow @nogc
{
    ulong hash = 14695981039346656037UL;
    foreach (value; values)
        hash = (hash ^ cast(ulong) value) * 1099511628211UL;
    return hash;
}
