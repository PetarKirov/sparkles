/**
 * @nogc-compatible text writing utilities for output ranges.
 *
 * Provides functions for writing integers, floats, escaped characters/strings,
 * and ANSI escape sequences to output ranges without GC allocation.
 */
module sparkles.core_cli.text_writers;

import sparkles.core_cli.term_style : Style;

// ─────────────────────────────────────────────────────────────────────────────
// Integer Writing
// ─────────────────────────────────────────────────────────────────────────────

/// Writes an integer (signed or unsigned) to an output range. @nogc-compatible.
void writeInteger(Writer, T)(ref Writer w, const T val) @trusted
if (__traits(isIntegral, T))
{
    import std.range.primitives : put;
    import std.traits : Unsigned, isSigned;

    static if (isSigned!T)
    {
        alias U = Unsigned!T;

        if (val < 0)
        {
            put(w, '-');
            // Handle T.min correctly by using unsigned arithmetic
            U value = cast(U)(0 - cast(U) val);
            writeUnsignedImpl(w, value);
        }
        else
        {
            writeUnsignedImpl(w, cast(U) val);
        }
    }
    else
    {
        writeUnsignedImpl(w, val);
    }
}

private void writeUnsignedImpl(Writer, T)(ref Writer w, const T val) @trusted
if (__traits(isUnsigned, T))
{
    import std.range.primitives : put;

    T value = val;  // Local mutable copy
    char[sizeForUnsignedNumberBuffer!T] buf = void;
    ubyte i = buf.length - 1;
    while (value >= 10)
    {
        buf[i--] = cast(char)('0' + value % 10);
        value /= 10;
    }
    buf[i] = cast(char)('0' + value);
    put(w, buf[i .. $]);
}

private template sizeForUnsignedNumberBuffer(T)
if (__traits(isUnsigned, T))
{
    import core.internal.string : numDigits;
    enum sizeForUnsignedNumberBuffer = T.max.numDigits;
}

@("writeInteger.positive")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    SmallBuffer!(char, 32) buf;
    writeInteger(buf, 42);
    assert(buf[] == "42");
}

@("writeInteger.negative")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    SmallBuffer!(char, 32) buf;
    writeInteger(buf, -123);
    assert(buf[] == "-123");
}

@("writeInteger.zero")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    SmallBuffer!(char, 32) buf;
    writeInteger(buf, 0);
    assert(buf[] == "0");
}

@("writeInteger.unsigned")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    SmallBuffer!(char, 32) buf;
    writeInteger(buf, 0uL);
    assert(buf[] == "0");
}

// ─────────────────────────────────────────────────────────────────────────────
// Floating-Point Writing
// ─────────────────────────────────────────────────────────────────────────────

/// Writes a floating-point value to an output range. @nogc-compatible.
/// Handles NaN, infinity, negative zero, and uses scientific notation for extreme values.
void writeFloat(Writer, T)(ref Writer w, const T val) @trusted
if (__traits(isFloating, T))
{
    import std.math.traits : isNaN, isInfinity, signbit;
    import std.range.primitives : put;

    // Handle special values first
    if (isNaN(val))
    {
        if (signbit(val))
            put(w, "-nan");
        else
            put(w, "nan");
        return;
    }

    if (isInfinity(val))
    {
        if (signbit(val))
            put(w, "-inf");
        else
            put(w, "inf");
        return;
    }

    // Handle sign (including -0.0)
    T value = val;
    if (signbit(val))
    {
        put(w, '-');
        value = -value;
    }

    // Use scientific notation for extreme values
    // Thresholds chosen to match typical 'g' format behavior
    enum T sciLow = 1e-4;   // Below this, use scientific
    enum T sciHigh = 1e15;  // Above this, use scientific

    if (value != 0 && (value < sciLow || value >= sciHigh))
    {
        writeFloatScientific(w, value);
        return;
    }

    // Decimal format for normal range
    writeFloatDecimal(w, value);
}

/// Writes a floating-point value in decimal format. @nogc-compatible.
private void writeFloatDecimal(Writer, T)(ref Writer w, T value) @trusted
if (__traits(isFloating, T))
{
    import std.range.primitives : put;

    // Integer part
    ulong intPart = cast(ulong) value;
    writeInteger(w, intPart);

    // Fractional part using fixed-point conversion
    T frac = value - cast(T) intPart;
    if (frac > 0)
    {
        put(w, '.');

        // Convert to fixed-point integer (more accurate than repeated multiply)
        // Use T.dig digits (6 for float, 15 for double)
        enum int numDigits = T.dig;
        enum ulong scale = 10UL ^^ numDigits;
        ulong fracInt = cast(ulong)(frac * scale + cast(T) 0.5);

        // Write digits to buffer (right-to-left)
        char[numDigits] fracBuf = void;
        foreach_reverse (i; 0 .. numDigits)
        {
            fracBuf[i] = cast(char)('0' + fracInt % 10);
            fracInt /= 10;
        }

        // Strip trailing zeros
        int fracLen = numDigits;
        while (fracLen > 1 && fracBuf[fracLen - 1] == '0')
            fracLen--;

        put(w, fracBuf[0 .. fracLen]);
    }
}

/// Writes a floating-point value in scientific notation. @nogc-compatible.
private void writeFloatScientific(Writer, T)(ref Writer w, T value) @trusted
if (__traits(isFloating, T))
{
    import std.range.primitives : put;

    // Normalize to [1, 10) range and calculate exponent
    int exp = 0;
    if (value != 0)
    {
        while (value >= 10) { value /= 10; exp++; }
        while (value < 1) { value *= 10; exp--; }
    }

    // Write mantissa
    writeFloatDecimal(w, value);

    // Write exponent: e+XX or e-XX
    put(w, 'e');
    if (exp >= 0)
        put(w, '+');
    writeInteger(w, exp);
}

@("writeFloat.basic")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    SmallBuffer!(char, 32) buf;
    writeFloat(buf, 3.14);
    assert(buf[] == "3.14");
}

@("writeFloat.specialValues")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    SmallBuffer!(char, 32) buf;

    writeFloat(buf, double.nan);
    assert(buf[] == "nan");

    buf.clear();
    writeFloat(buf, -double.nan);
    assert(buf[] == "-nan");

    buf.clear();
    writeFloat(buf, double.infinity);
    assert(buf[] == "inf");

    buf.clear();
    writeFloat(buf, -double.infinity);
    assert(buf[] == "-inf");
}

@("writeFloat.zero")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    SmallBuffer!(char, 32) buf;

    writeFloat(buf, 0.0);
    assert(buf[] == "0");

    buf.clear();
    writeFloat(buf, -0.0);
    assert(buf[] == "-0");
}

@("writeFloat.common")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    SmallBuffer!(char, 32) buf;

    writeFloat(buf, 10.0);
    assert(buf[] == "10");

    buf.clear();
    writeFloat(buf, -10.0);
    assert(buf[] == "-10");

    buf.clear();
    writeFloat(buf, 0.1);
    assert(buf[] == "0.1");
}

@("writeFloat.scientific")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    SmallBuffer!(char, 64) buf;

    // Large value should use scientific notation
    writeFloat(buf, 1e30);
    assert(buf[0] == '1');
    assert(buf[].length >= 4);  // At least "1e+X"

    buf.clear();
    // Small value should use scientific notation
    writeFloat(buf, 1e-30);
    assert(buf[0] == '1');
    assert(buf[].length >= 4);  // At least "1e-X"
}

// ─────────────────────────────────────────────────────────────────────────────
// Escaped Character/String Writing
// ─────────────────────────────────────────────────────────────────────────────

/// Writes an escaped character to an output range (without quotes). @nogc-compatible.
void writeEscapedChar(Writer)(ref Writer w, char c) @trusted
{
    import std.range.primitives : put;

    switch (c)
    {
        case '\n': put(w, `\n`); return;
        case '\t': put(w, `\t`); return;
        case '\r': put(w, `\r`); return;
        case '\0': put(w, `\0`); return;
        case '\\': put(w, `\\`); return;
        case '\"': put(w, `\"`); return;
        case '\'': put(w, `\'`); return;
        default:
            if (c >= 0x20 && c < 0x7F)
                put(w, c);
            else
            {
                // Hex escape for non-printable
                put(w, `\x`);
                static immutable hexDigits = "0123456789ABCDEF";
                put(w, hexDigits[(c >> 4) & 0xF]);
                put(w, hexDigits[c & 0xF]);
            }
    }
}

/// Writes an escaped string to an output range (with double quotes). @nogc-compatible.
void writeEscapedString(Writer)(ref Writer w, const(char)[] s) @trusted
{
    import std.range.primitives : put;

    put(w, '"');
    foreach (c; s)
        writeEscapedChar(w, c);
    put(w, '"');
}

/// Writes an escaped character literal to an output range (with single quotes). @nogc-compatible.
void writeEscapedCharLiteral(Writer)(ref Writer w, char c) @trusted
{
    import std.range.primitives : put;

    put(w, '\'');
    writeEscapedChar(w, c);
    put(w, '\'');
}

@("writeEscapedChar.newline")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    SmallBuffer!(char, 32) buf;
    writeEscapedChar(buf, '\n');
    assert(buf[] == `\n`);
}

@("writeEscapedString.basic")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    SmallBuffer!(char, 64) buf;
    writeEscapedString(buf, "hello\nworld");
    assert(buf[] == `"hello\nworld"`);
}

@("writeEscapedCharLiteral.basic")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    SmallBuffer!(char, 32) buf;
    writeEscapedCharLiteral(buf, '\t');
    assert(buf[] == `'\t'`);
}

// ─────────────────────────────────────────────────────────────────────────────
// ANSI Escape Sequence Writing
// ─────────────────────────────────────────────────────────────────────────────

/// Writes ANSI escape sequence to an output range. @nogc-compatible.
void writeEscapeSeq(Writer)(ref Writer w, uint code) @trusted
{
    import std.range.primitives : put;

    put(w, "\x1b[");
    writeInteger(w, code);
    put(w, 'm');
}

/// Writes styled text to an output range. @nogc-compatible.
void writeStylized(Writer)(ref Writer w, const(char)[] text, Style style, bool resetAfter = true) @trusted
{
    import std.range.primitives : put;

    if (style == Style.none)
    {
        put(w, text);
        return;
    }

    writeEscapeSeq(w, style[0]);
    put(w, text);
    if (resetAfter)
        writeEscapeSeq(w, style[1]);
}

@("writeEscapeSeq.basic")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    SmallBuffer!(char, 32) buf;
    writeEscapeSeq(buf, 34);
    assert(buf[] == "\x1b[34m");
}

@("writeStylized.withColor")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    SmallBuffer!(char, 64) buf;
    writeStylized(buf, "hello", Style.blue);
    assert(buf[] == "\x1b[34mhello\x1b[39m");
}

@("writeStylized.noReset")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    SmallBuffer!(char, 64) buf;
    writeStylized(buf, "hello", Style.blue, false);
    assert(buf[] == "\x1b[34mhello");
}

@("writeStylized.noStyle")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    SmallBuffer!(char, 32) buf;
    writeStylized(buf, "hello", Style.none);
    assert(buf[] == "hello");
}
