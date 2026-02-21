/**
 * @nogc-compatible text writing utilities for output ranges.
 *
 * Provides functions for writing integers, floats, escaped characters/strings,
 * and ANSI escape sequences to output ranges without GC allocation.
 */
module sparkles.core_cli.text_writers;

import std.datetime.date : TimeOfDay;
import std.range.primitives : isOutputRange;

import sparkles.core_cli.term_style : Style;

public import sparkles.core_cli.text_writers.outputspan :
    copySpan, OutputSpan, OutputSpanWriter;
public import sparkles.core_cli.text_writers.traits :
    hasNogcOutputRangeToString, hasNogcSinkToString, hasNogcStringCast,
    hasNogcStringToString, hasNogcToString, hasOutputRangeToString,
    hasSinkToString, isContiguousOutputRange, isLeafValue;

version (unittest) public import sparkles.core_cli.text_writers.expect_written :
    expectWritten, WriterBuf;

// ─────────────────────────────────────────────────────────────────────────────
// Integer Writing
// ─────────────────────────────────────────────────────────────────────────────

/// Writes an integer (signed or unsigned) to an output range. @nogc-compatible.
OutputSpan writeInteger(Writer, T)(scope ref Writer w, const T val) @trusted
if (__traits(isIntegral, T))
{
    import std.traits : Unsigned, isSigned;

    auto writer = OutputSpanWriter!Writer(w);

    static if (isSigned!T)
    {
        alias U = Unsigned!T;

        if (val < 0)
        {
            writer.put('-');
            // Handle T.min correctly by using unsigned arithmetic
            U value = cast(U)(0 - cast(U) val);
            writeUnsignedImpl(writer, value);
        }
        else
        {
            writeUnsignedImpl(writer, cast(U) val);
        }
    }
    else
    {
        writeUnsignedImpl(writer, val);
    }

    return writer.release();
}

private OutputSpan writeUnsignedImpl(Writer, T)(scope ref Writer w, const T val) @trusted
if (__traits(isUnsigned, T))
{
    auto writer = OutputSpanWriter!Writer(w);

    T value = val;  // Local mutable copy
    char[sizeForUnsignedNumberBuffer!T] buf = void;
    ubyte i = buf.length - 1;
    while (value >= 10)
    {
        buf[i--] = cast(char)('0' + value % 10);
        value /= 10;
    }
    buf[i] = cast(char)('0' + value);
    writer.put(buf[i .. $]);
    return writer.release();
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
    expectWritten(
        write: (ref WriterBuf buf) { writeInteger(buf, 42); },
        expected: "42",
    );
}

@("writeInteger.negative")
@safe pure nothrow @nogc
unittest
{
    expectWritten(
        write: (ref WriterBuf buf) { writeInteger(buf, -123); },
        expected: "-123",
    );
}

@("writeInteger.zero")
@safe pure nothrow @nogc
unittest
{
    expectWritten(
        write: (ref WriterBuf buf) { writeInteger(buf, 0); },
        expected: "0",
    );
}

@("writeInteger.unsigned")
@safe pure nothrow @nogc
unittest
{
    expectWritten(
        write: (ref WriterBuf buf) { writeInteger(buf, 0uL); },
        expected: "0",
    );
}

@("writeInteger.spans")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    SmallBuffer!(char, 32) buf;
    auto first = writeInteger(buf, 42);
    auto second = writeInteger(buf, -7);

    assert(first.length == 2);
    assert(first[buf] == "42");
    assert(second[buf] == "-7");
    assert(second.offset == first.offset + first.length);
}

// ─────────────────────────────────────────────────────────────────────────────
// Floating-Point Writing
// ─────────────────────────────────────────────────────────────────────────────

/// Writes a floating-point value to an output range. @nogc-compatible.
/// Handles NaN, infinity, negative zero, and uses scientific notation for extreme values.
OutputSpan writeFloat(Writer, T)(scope ref Writer w, const T val) @trusted
if (__traits(isFloating, T))
{
    import std.math.traits : isNaN, isInfinity, signbit;

    auto writer = OutputSpanWriter!Writer(w);

    // Handle special values first
    if (isNaN(val))
    {
        if (signbit(val))
            writer.put("-nan");
        else
            writer.put("nan");
        return writer.release();
    }

    if (isInfinity(val))
    {
        if (signbit(val))
            writer.put("-inf");
        else
            writer.put("inf");
        return writer.release();
    }

    // Handle sign (including -0.0)
    T value = val;
    if (signbit(val))
    {
        writer.put('-');
        value = -value;
    }

    // Use scientific notation for extreme values
    // Thresholds chosen to match typical 'g' format behavior
    enum T sciLow = 1e-4;   // Below this, use scientific
    enum T sciHigh = 1e15;  // Above this, use scientific

    if (value != 0 && (value < sciLow || value >= sciHigh))
    {
        writeFloatScientific(writer, value);
        return writer.release();
    }

    // Decimal format for normal range
    writeFloatDecimal(writer, value);
    return writer.release();
}

/// Writes a floating-point value in decimal format. @nogc-compatible.
private OutputSpan writeFloatDecimal(Writer, T)(scope ref Writer w, T value) @trusted
if (__traits(isFloating, T))
{
    auto writer = OutputSpanWriter!Writer(w);

    // Integer part
    ulong intPart = cast(ulong) value;
    writeInteger(writer, intPart);

    // Fractional part using fixed-point conversion
    T frac = value - cast(T) intPart;
    if (frac > 0)
    {
        writer.put('.');

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

        writer.put(fracBuf[0 .. fracLen]);
    }
    return writer.release();
}

/// Writes a floating-point value in scientific notation. @nogc-compatible.
private OutputSpan writeFloatScientific(Writer, T)(scope ref Writer w, T value) @trusted
if (__traits(isFloating, T))
{
    auto writer = OutputSpanWriter!Writer(w);

    // Normalize to [1, 10) range and calculate exponent
    int exp = 0;
    if (value != 0)
    {
        while (value >= 10) { value /= 10; exp++; }
        while (value < 1) { value *= 10; exp--; }
    }

    // Write mantissa
    writeFloatDecimal(writer, value);

    // Write exponent: e+XX or e-XX
    writer.put('e');
    if (exp >= 0)
        writer.put('+');
    writeInteger(writer, exp);
    return writer.release();
}

@("writeFloat.basic")
@safe pure nothrow @nogc
unittest
{
    expectWritten(
        write: (ref WriterBuf buf) { writeFloat(buf, 3.14); },
        expected: "3.14",
    );
}

@("writeFloat.specialValues")
@safe pure nothrow @nogc
unittest
{
    expectWritten(
        write: (ref WriterBuf buf) { writeFloat(buf, double.nan); },
        expected: "nan",
    );
    expectWritten(
        write: (ref WriterBuf buf) { writeFloat(buf, -double.nan); },
        expected: "-nan",
    );
    expectWritten(
        write: (ref WriterBuf buf) { writeFloat(buf, double.infinity); },
        expected: "inf",
    );
    expectWritten(
        write: (ref WriterBuf buf) { writeFloat(buf, -double.infinity); },
        expected: "-inf",
    );
}

@("writeFloat.zero")
@safe pure nothrow @nogc
unittest
{
    expectWritten(
        write: (ref WriterBuf buf) { writeFloat(buf, 0.0); },
        expected: "0",
    );
    expectWritten(
        write: (ref WriterBuf buf) { writeFloat(buf, -0.0); },
        expected: "-0",
    );
}

@("writeFloat.common")
@safe pure nothrow @nogc
unittest
{
    expectWritten(
        write: (ref WriterBuf buf) { writeFloat(buf, 10.0); },
        expected: "10",
    );
    expectWritten(
        write: (ref WriterBuf buf) { writeFloat(buf, -10.0); },
        expected: "-10",
    );
    expectWritten(
        write: (ref WriterBuf buf) { writeFloat(buf, 0.1); },
        expected: "0.1",
    );
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
// Time Writing
// ─────────────────────────────────────────────────────────────────────────────

/// Writes a [TimeOfDay] as `HH:MM:SS` to an output range.
OutputSpan writeTimeHms(Writer)(scope ref Writer w, in TimeOfDay time) @safe
{
    auto writer = OutputSpanWriter!Writer(w);
    writePadded2(writer, time.hour);
    writer.put(':');
    writePadded2(writer, time.minute);
    writer.put(':');
    writePadded2(writer, time.second);
    return writer.release();
}

private OutputSpan writePadded2(Writer)(scope ref Writer w, int value) @safe
{
    auto writer = OutputSpanWriter!Writer(w);
    if (value < 10) writer.put('0');
    writeInteger(writer, value);
    return writer.release();
}

///
@("writeTimeHms.basic")
@safe pure nothrow @nogc
unittest
{
    static immutable t = TimeOfDay(9, 5, 3);
    expectWritten(
        write: (ref WriterBuf buf) { writeTimeHms(buf, t); },
        expected: "09:05:03",
    );
}

///
@("writeTimeHms.midnight")
@safe pure nothrow @nogc
unittest
{
    static immutable t = TimeOfDay(0, 0, 0);
    expectWritten(
        write: (ref WriterBuf buf) { writeTimeHms(buf, t); },
        expected: "00:00:00",
    );
}

// ─────────────────────────────────────────────────────────────────────────────
// Escaped Character/String Writing
// ─────────────────────────────────────────────────────────────────────────────

/// Writes an escaped character to an output range (without quotes). @nogc-compatible.
OutputSpan writeEscapedChar(Writer)(scope ref Writer w, char c) @trusted
{
    auto writer = OutputSpanWriter!Writer(w);

    switch (c)
    {
        case '\n': writer.put(`\n`); return writer.release();
        case '\t': writer.put(`\t`); return writer.release();
        case '\r': writer.put(`\r`); return writer.release();
        case '\0': writer.put(`\0`); return writer.release();
        case '\\': writer.put(`\\`); return writer.release();
        case '\"': writer.put(`\"`); return writer.release();
        case '\'': writer.put(`\'`); return writer.release();
        default:
            if (c >= 0x20 && c < 0x7F)
                writer.put(c);
            else
            {
                // Hex escape for non-printable
                writer.put(`\x`);
                static immutable hexDigits = "0123456789ABCDEF";
                writer.put(hexDigits[(c >> 4) & 0xF]);
                writer.put(hexDigits[c & 0xF]);
            }
    }
    return writer.release();
}

@("writeEscapedChar.newline")
@safe pure nothrow @nogc
unittest
{
    expectWritten(
        write: (ref WriterBuf buf) { writeEscapedChar(buf, '\n'); },
        expected: `\n`,
    );
}

/// Writes an escaped string to an output range (with double quotes). @nogc-compatible.
OutputSpan writeEscapedString(Writer)(scope ref Writer w, const(char)[] s) @trusted
{
    auto writer = OutputSpanWriter!Writer(w);

    writer.put('"');
    foreach (c; s)
        writeEscapedChar(writer, c);
    writer.put('"');
    return writer.release();
}

@("writeEscapedString.basic")
@safe pure nothrow @nogc
unittest
{
    expectWritten(
        write: (ref WriterBuf buf) { writeEscapedString(buf, "hello\nworld"); },
        expected: `"hello\nworld"`,
    );
}

/// Writes an escaped character literal to an output range (with single quotes). @nogc-compatible.
OutputSpan writeEscapedCharLiteral(Writer)(scope ref Writer w, char c) @trusted
{
    auto writer = OutputSpanWriter!Writer(w);

    writer.put('\'');
    writeEscapedChar(writer, c);
    writer.put('\'');
    return writer.release();
}

@("writeEscapedCharLiteral.basic")
@safe pure nothrow @nogc
unittest
{
    expectWritten(
        write: (ref WriterBuf buf) { writeEscapedCharLiteral(buf, '\t'); },
        expected: `'\t'`,
    );
}

// ─────────────────────────────────────────────────────────────────────────────
// Value Writing
// ─────────────────────────────────────────────────────────────────────────────

/// Writes any value to an output range using best-effort @nogc conversion.
///
/// Dispatch order:
/// 1. `bool` — writes `"true"` or `"false"`
/// 2. Integral types — uses `writeInteger`
/// 3. Floating-point types — uses `writeFloat`
/// 4. `char` — writes the character directly
/// 5. String/char slices — writes directly via `put`
/// 6. User types with @nogc output range `toString` — calls `t.toString(writer)`
/// 7. User types with @nogc sink `toString` — calls with a forwarding delegate
/// 8. User types with @nogc `toString()` returning `string` — writes the result
/// 9. User types with @nogc `string` cast — writes `cast(string) t`
/// 10. Fallback — uses `std.conv.to!string` (GC-allocating)
OutputSpan writeValue(Writer, T)(scope ref Writer w, auto ref const T val) @trusted
{
    import std.traits : isSomeChar, isSomeString;

    auto writer = OutputSpanWriter!Writer(w);

    static if (is(T == bool))
    {
        writer.put(val ? "true" : "false");
    }
    else static if (isSomeChar!T)
    {
        writer.put((&val)[0 .. 1]);
    }
    else static if (__traits(isIntegral, T))
    {
        writeInteger(writer, val);
    }
    else static if (__traits(isFloating, T))
    {
        writeFloat(writer, val);
    }
    else static if (isSomeString!T || is(T : const(char)[]))
    {
        writer.put(val);
    }
    else static if (hasNogcOutputRangeToString!T)
    {
        // Best: direct output range — no allocation, no delegate
        val.toString(writer);
    }
    else static if (hasNogcSinkToString!T)
    {
        // Good: sink delegate — no allocation
        val.toString((const(char)[] chunk) @nogc { writer.put(chunk); });
    }
    else static if (hasNogcStringToString!T)
    {
        writer.put(val.toString());
    }
    else static if (hasNogcStringCast!T)
    {
        writer.put(cast(string) val);
    }
    else
    {
        // GC fallback
        import std.conv : to;
        writer.put(val.to!string);
    }

    return writer.release();
}

@("writeValue.bool")
@safe pure nothrow @nogc
unittest
{
    expectWritten(
        write: (ref WriterBuf buf) { writeValue(buf, true); },
        expected: "true",
    );
    expectWritten(
        write: (ref WriterBuf buf) { writeValue(buf, false); },
        expected: "false",
    );
}

@("writeValue.integer")
@safe pure nothrow @nogc
unittest
{
    expectWritten(
        write: (ref WriterBuf buf) { writeValue(buf, 42); },
        expected: "42",
    );
    expectWritten(
        write: (ref WriterBuf buf) { writeValue(buf, -7); },
        expected: "-7",
    );
}

@("writeValue.float")
@safe pure nothrow @nogc
unittest
{
    expectWritten(
        write: (ref WriterBuf buf) { writeValue(buf, 3.14); },
        expected: "3.14",
    );
}

@("writeValue.char")
@safe pure nothrow @nogc
unittest
{
    expectWritten(
        write: (ref WriterBuf buf) { writeValue(buf, 'A'); },
        expected: "A",
    );
}

@("writeValue.string")
@safe pure nothrow @nogc
unittest
{
    expectWritten(
        write: (ref WriterBuf buf) { writeValue(buf, "hello world"); },
        expected: "hello world",
    );
}

@("writeValue.nogcOutputRangeType")
@safe pure nothrow @nogc
unittest
{
    struct NogcOR
    {
        int value;

        void toString(Writer)(ref Writer w) const @nogc
        {
            import std.range.primitives : put;
            put(w, "NogcOR");
        }
    }

    expectWritten(
        write: (ref WriterBuf buf) { writeValue(buf, NogcOR(42)); },
        expected: "NogcOR",
    );
}

// ─────────────────────────────────────────────────────────────────────────────
// ANSI Escape Sequence Writing
// ─────────────────────────────────────────────────────────────────────────────

/// Writes ANSI escape sequence to an output range. @nogc-compatible.
OutputSpan writeEscapeSeq(Writer)(scope ref Writer w, uint code) @trusted
{
    auto writer = OutputSpanWriter!Writer(w);

    writer.put("\x1b[");
    writeInteger(writer, code);
    writer.put('m');
    return writer.release();
}

@("writeEscapeSeq.basic")
@safe pure nothrow @nogc
unittest
{
    expectWritten(
        write: (ref WriterBuf buf) { writeEscapeSeq(buf, 34); },
        expected: "\x1b[34m",
    );
}

/// Writes styled text to an output range. @nogc-compatible.
OutputSpan writeStylized(Writer)(scope ref Writer w, const(char)[] text, Style style, bool resetAfter = true) @trusted
{
    auto writer = OutputSpanWriter!Writer(w);

    if (style == Style.none)
    {
        writer.put(text);
        return writer.release();
    }

    writeEscapeSeq(writer, style[0]);
    writer.put(text);
    if (resetAfter)
        writeEscapeSeq(writer, style[1]);
    return writer.release();
}

@("writeStylized.withColor")
@safe pure nothrow @nogc
unittest
{
    expectWritten(
        write: (ref WriterBuf buf) { writeStylized(buf, "hello", Style.blue); },
        expected: "\x1b[34mhello\x1b[39m",
    );
}

@("writeStylized.noReset")
@safe pure nothrow @nogc
unittest
{
    expectWritten(
        write: (ref WriterBuf buf) { writeStylized(buf, "hello", Style.blue, false); },
        expected: "\x1b[34mhello",
    );
}

@("writeStylized.noStyle")
@safe pure nothrow @nogc
unittest
{
    expectWritten(
        write: (ref WriterBuf buf) { writeStylized(buf, "hello", Style.none); },
        expected: "hello",
    );
}

// ─────────────────────────────────────────────────────────────────────────────
// Enum Member Name Writing
// ─────────────────────────────────────────────────────────────────────────────

/// Writes an enum value's member name to an output range. @nogc-compatible.
///
/// Uses `static foreach` over `__traits(allMembers, E)` for a compile-time
/// generated lookup. Falls back to writing the underlying integer value
/// if no member matches (e.g., combined bit flags).
OutputSpan writeEnumMemberName(E, Writer)(scope ref Writer w, const E val) @trusted
if (is(E == enum))
{
    import std.traits : OriginalType;

    auto writer = OutputSpanWriter!Writer(w);

    bool matched = false;

    static foreach (member; __traits(allMembers, E))
    {{
        if (!matched && val == __traits(getMember, E, member))
        {
            writer.put(member);
            matched = true;
        }
    }}

    if (!matched)
        writeInteger(writer, cast(OriginalType!E) val);
    return writer.release();
}

@("writeEnumMemberName.basic")
@safe pure nothrow @nogc
unittest
{
    enum Color { red, green, blue }
    expectWritten(
        write: (ref WriterBuf buf) { writeEnumMemberName(buf, Color.green); },
        expected: "green",
    );
}

@("writeEnumMemberName.fallback")
@safe pure nothrow @nogc
unittest
{
    enum Flags : ubyte { a = 1, b = 2 }
    expectWritten(
        write: (ref WriterBuf buf) { writeEnumMemberName(buf, cast(Flags) 3); },
        expected: "3",
    );
}

// ─────────────────────────────────────────────────────────────────────────────
// Styled Value Writing
// ─────────────────────────────────────────────────────────────────────────────

/// Controls how enum values are rendered by `writeStyledValue`.
enum EnumRender
{
    underlying, /// Write as underlying integer (default for `writeValue`)
    memberName, /// Write the member name string (e.g., `"green"`)
}

/// Writes a leaf value to an output range with optional ANSI styling.
///
/// Parameterized by a DbI hook that controls:
/// $(UL
///   $(LI `Style styleOf(T)(val)` — per-type/per-value style selection)
///   $(LI `enum bool escapeStrings` — write strings with quotes and escapes)
///   $(LI `enum bool escapeChars` — write chars with quotes and escapes)
///   $(LI `enum EnumRender enumRender` — how to render enum values)
/// )
///
/// All hook primitives are optional (DbI §5). When absent, defaults apply:
/// no styling, raw strings/chars, enums as underlying integers.
OutputSpan writeStyledValue(Hook, Writer, T)(scope ref Writer w, in T value, in Hook hook, bool useColors) @trusted
{
    import std.traits : isSomeChar, isSomeString;

    auto writer = OutputSpanWriter!Writer(w);

    // 1. Compute style from hook (optional primitive)
    Style style = Style.none;
    static if (__traits(compiles, hook.styleOf(value)))
    {
        if (useColors)
            style = hook.styleOf(value);
    }

    // 2. Open style
    if (style != Style.none)
        writeEscapeSeq(writer, style[0]);

    // 3. Dispatch by type
    static if (is(T == typeof(null)))
    {
        writer.put("null");
    }
    else static if (is(T == enum))
    {
        // Hook-controlled enum rendering
        enum render = {
            static if (__traits(compiles, Hook.enumRender))
                return Hook.enumRender;
            else
                return EnumRender.underlying;
        }();

        static if (render == EnumRender.memberName)
            writeEnumMemberName(writer, value);
        else
        {
            import std.traits : OriginalType;
            writeInteger(writer, cast(OriginalType!T) value);
        }
    }
    else static if (is(T == bool))
    {
        writer.put(value ? "true" : "false");
    }
    else static if (isSomeChar!T)
    {
        enum esc = {
            static if (__traits(compiles, Hook.escapeChars))
                return Hook.escapeChars;
            else
                return false;
        }();

        static if (esc)
            writeEscapedCharLiteral(writer, value);
        else
            writer.put((&value)[0 .. 1]);
    }
    else static if (isSomeString!T)
    {
        enum esc = {
            static if (__traits(compiles, Hook.escapeStrings))
                return Hook.escapeStrings;
            else
                return false;
        }();

        static if (esc)
            writeEscapedString(writer, value);
        else
            writer.put(value);
    }
    else static if (__traits(isIntegral, T))
    {
        writeInteger(writer, value);
    }
    else static if (__traits(isFloating, T))
    {
        writeFloat(writer, value);
    }
    else
    {
        // Non-leaf fallback: delegate to plain writeValue
        writeValue(writer, value);
    }

    // 4. Close style
    if (style != Style.none)
        writeEscapeSeq(writer, style[1]);
    return writer.release();
}

/// Default hook: no styling, no escaping, enums as integers.
@("writeStyledValue.defaultHook")
@safe pure nothrow @nogc
unittest
{
    struct NoHook {}
    expectWritten(
        write: (ref WriterBuf buf) { writeStyledValue(buf, 42, NoHook(), false); },
        expected: "42",
    );
    expectWritten(
        write: (ref WriterBuf buf) { writeStyledValue(buf, "hello", NoHook(), false); },
        expected: "hello",
    );
}

/// Hook with styling: values get ANSI color codes.
@("writeStyledValue.withStyle")
@safe pure nothrow @nogc
unittest
{
    struct BlueInts
    {
        Style styleOf(T)(in T) const @safe pure nothrow @nogc
        {
            static if (__traits(isIntegral, T))
                return Style.blue;
            else
                return Style.none;
        }
    }

    expectWritten(
        write: (ref WriterBuf buf) { writeStyledValue(buf, 42, BlueInts(), true); },
        expected: "\x1b[34m42\x1b[39m",
    );
}

/// Hook with string escaping: strings get quotes and escape sequences.
@("writeStyledValue.escapedStrings")
@safe pure nothrow @nogc
unittest
{
    struct EscHook
    {
        enum escapeStrings = true;
        enum escapeChars = true;
    }

    expectWritten(
        write: (ref WriterBuf buf) { writeStyledValue(buf, "hi\nthere", EscHook(), false); },
        expected: `"hi\nthere"`,
    );
    expectWritten(
        write: (ref WriterBuf buf) { writeStyledValue(buf, '\t', EscHook(), false); },
        expected: `'\t'`,
    );
}

/// Hook with enum member name rendering.
@("writeStyledValue.enumMemberName")
@safe pure nothrow @nogc
unittest
{
    enum Dir { north, south, east, west }

    struct EnumHook
    {
        enum enumRender = EnumRender.memberName;
    }

    expectWritten(
        write: (ref WriterBuf buf) { writeStyledValue(buf, Dir.south, EnumHook(), false); },
        expected: "south",
    );
}

/// Hook with styling disabled (useColors=false): no escape codes emitted.
@("writeStyledValue.stylingDisabled")
@safe pure nothrow @nogc
unittest
{
    struct AlwaysBlue
    {
        Style styleOf(T)(in T) const @safe pure nothrow @nogc => Style.blue;
    }

    expectWritten(
        write: (ref WriterBuf buf) { writeStyledValue(buf, 42, AlwaysBlue(), false); },
        expected: "42",
    );
}

/// Null value rendering.
@("writeStyledValue.null")
@safe pure nothrow @nogc
unittest
{
    struct YellowNull
    {
        Style styleOf(T)(in T) const @safe pure nothrow @nogc => Style.yellow;
    }

    expectWritten(
        write: (ref WriterBuf buf) { writeStyledValue(buf, null, YellowNull(), true); },
        expected: "\x1b[33mnull\x1b[39m",
    );
}

/// Bool value rendering with styling.
@("writeStyledValue.bool")
@safe pure nothrow @nogc
unittest
{
    struct YellowBool
    {
        Style styleOf(T)(in T) const @safe pure nothrow @nogc
        {
            static if (is(T == bool))
                return Style.yellow;
            else
                return Style.none;
        }
    }

    expectWritten(
        write: (ref WriterBuf buf) { writeStyledValue(buf, true, YellowBool(), true); },
        expected: "\x1b[33mtrue\x1b[39m",
    );
}

/// Float special values with per-value styling.
@("writeStyledValue.floatSpecial")
@safe pure nothrow @nogc
unittest
{
    struct FloatHook
    {
        Style styleOf(T)(in T val) const @safe pure nothrow @nogc
        {
            static if (__traits(isFloating, T))
            {
                import std.math.traits : isNaN, isInfinity;
                if (isNaN(val) || isInfinity(val))
                    return Style.red;
                return Style.blue;
            }
            else
                return Style.none;
        }
    }

    expectWritten(
        write: (ref WriterBuf buf) { writeStyledValue(buf, double.nan, FloatHook(), true); },
        expected: "\x1b[31mnan\x1b[39m",
    );
    expectWritten(
        write: (ref WriterBuf buf) { writeStyledValue(buf, 3.14, FloatHook(), true); },
        expected: "\x1b[34m3.14\x1b[39m",
    );
}

// ─────────────────────────────────────────────────────────────────────────────
// Test Assertion Helper Tests
// ─────────────────────────────────────────────────────────────────────────────

@("expectWritten.pass")
@safe pure nothrow @nogc
unittest
{
    expectWritten(
        write: (ref WriterBuf buf) { writeInteger(buf, 42); },
        expected: "41",
    );
}

@("expectWritten.multipleWrites")
@safe pure nothrow @nogc
unittest
{
    expectWritten(
        write: (ref WriterBuf buf) {
            writeInteger(buf, 1);
            buf.put(", ");
            writeInteger(buf, 2);
        },
        expected: "1, 2",
    );
}
