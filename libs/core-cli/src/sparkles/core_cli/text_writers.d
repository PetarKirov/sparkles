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

@("writeEscapedChar.newline")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    SmallBuffer!(char, 32) buf;
    writeEscapedChar(buf, '\n');
    assert(buf[] == `\n`);
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

@("writeEscapedString.basic")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    SmallBuffer!(char, 64) buf;
    writeEscapedString(buf, "hello\nworld");
    assert(buf[] == `"hello\nworld"`);
}

/// Writes an escaped character literal to an output range (with single quotes). @nogc-compatible.
void writeEscapedCharLiteral(Writer)(ref Writer w, char c) @trusted
{
    import std.range.primitives : put;

    put(w, '\'');
    writeEscapedChar(w, c);
    put(w, '\'');
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
// Value Writing / @nogc Conversion Traits
// ─────────────────────────────────────────────────────────────────────────────

/// True if `T` has a `toString` overload that accepts an output range writer,
/// i.g. `void toString(W)(ref W writer)`.
template hasOutputRangeToString(T)
{
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    enum hasOutputRangeToString = __traits(compiles, () {
        T t = T.init;
        SmallBuffer!(char, 128) buf;
        t.toString(buf);
    }());
}

/// True if `T` has a @nogc-compatible `toString` overload that accepts an
/// output range writer.
template hasNogcOutputRangeToString(T)
{
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    enum hasNogcOutputRangeToString = __traits(compiles, () @nogc {
        T t = T.init;
        SmallBuffer!(char, 128) buf;
        t.toString(buf);
    }());
}

/// True if `T` has a `toString` that takes a `scope void delegate(const(char)[])` sink.
template hasSinkToString(T)
{
    enum hasSinkToString = __traits(compiles, () {
        T t = T.init;
        static void sink(const(char)[]) {}
        t.toString(&sink);
    }());
}

/// True if `T` has a @nogc `toString` that takes a @nogc sink delegate.
template hasNogcSinkToString(T)
{
    enum hasNogcSinkToString = __traits(compiles, () @nogc {
        T t = T.init;
        static void sink(const(char)[]) @nogc {}
        t.toString(&sink);
    }());
}

/// True if `T` has a `toString()` that returns `string` and is callable from @nogc.
template hasNogcStringToString(T)
{
    enum hasNogcStringToString = __traits(compiles, () @nogc {
        T t = T.init;
        string s = t.toString();
    }());
}

/// True if `T` supports `cast(string)` and the cast is @nogc.
template hasNogcStringCast(T)
{
    enum hasNogcStringCast = __traits(compiles, () @nogc {
        T t = T.init;
        string s = cast(string) t;
    }());
}

/// True if `T` has any @nogc-compatible string conversion mechanism.
template hasNogcToString(T)
{
    enum hasNogcToString =
        hasNogcOutputRangeToString!T ||
        hasNogcSinkToString!T ||
        hasNogcStringToString!T ||
        hasNogcStringCast!T;
}

// Test struct with @nogc output range toString
private struct NogcOutputRangeType
{
    int value;

    void toString(Writer)(ref Writer w) const @nogc
    {
        import std.range.primitives : put;
        put(w, "NogcOR");
    }
}

@("nogcTraits.builtinTypes")
@safe pure nothrow @nogc
unittest
{
    // Built-in types don't have toString, so traits should be false
    static assert(!hasNogcOutputRangeToString!int);
    static assert(!hasNogcSinkToString!int);
    static assert(!hasNogcStringToString!int);
    static assert(!hasNogcStringCast!int);
    static assert(!hasNogcToString!int);
}

@("nogcTraits.outputRangeToString")
@safe pure nothrow @nogc
unittest
{
    static assert(hasNogcOutputRangeToString!NogcOutputRangeType);
    static assert(hasOutputRangeToString!NogcOutputRangeType);
    static assert(hasNogcToString!NogcOutputRangeType);
}

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
void writeValue(Writer, T)(ref Writer w, auto ref const T val) @trusted
{
    import std.range.primitives : put;
    import std.traits : isSomeChar, isSomeString;

    static if (is(T == bool))
    {
        put(w, val ? "true" : "false");
    }
    else static if (isSomeChar!T)
    {
        put(w, (&val)[0 .. 1]);
    }
    else static if (__traits(isIntegral, T))
    {
        writeInteger(w, val);
    }
    else static if (__traits(isFloating, T))
    {
        writeFloat(w, val);
    }
    else static if (isSomeString!T || is(T : const(char)[]))
    {
        put(w, val);
    }
    else static if (hasNogcOutputRangeToString!T)
    {
        // Best: direct output range — no allocation, no delegate
        val.toString(w);
    }
    else static if (hasNogcSinkToString!T)
    {
        // Good: sink delegate — no allocation
        val.toString((const(char)[] chunk) @nogc { put(w, chunk); });
    }
    else static if (hasNogcStringToString!T)
    {
        put(w, val.toString());
    }
    else static if (hasNogcStringCast!T)
    {
        put(w, cast(string) val);
    }
    else
    {
        // GC fallback
        import std.conv : to;
        put(w, val.to!string);
    }
}

@("writeValue.bool")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    SmallBuffer!(char, 32) buf;
    writeValue(buf, true);
    assert(buf[] == "true");

    buf.clear();
    writeValue(buf, false);
    assert(buf[] == "false");
}

@("writeValue.integer")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    SmallBuffer!(char, 32) buf;
    writeValue(buf, 42);
    assert(buf[] == "42");

    buf.clear();
    writeValue(buf, -7);
    assert(buf[] == "-7");
}

@("writeValue.float")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    SmallBuffer!(char, 32) buf;
    writeValue(buf, 3.14);
    assert(buf[] == "3.14");
}

@("writeValue.char")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    SmallBuffer!(char, 32) buf;
    writeValue(buf, 'A');
    assert(buf[] == "A");
}

@("writeValue.string")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    SmallBuffer!(char, 64) buf;
    writeValue(buf, "hello world");
    assert(buf[] == "hello world");
}

@("writeValue.nogcOutputRangeType")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    SmallBuffer!(char, 32) buf;
    writeValue(buf, NogcOutputRangeType(42));
    assert(buf[] == "NogcOR");
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

@("writeEscapeSeq.basic")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    SmallBuffer!(char, 32) buf;
    writeEscapeSeq(buf, 34);
    assert(buf[] == "\x1b[34m");
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

// ─────────────────────────────────────────────────────────────────────────────
// Enum Member Name Writing
// ─────────────────────────────────────────────────────────────────────────────

/// Writes an enum value's member name to an output range. @nogc-compatible.
///
/// Uses `static foreach` over `__traits(allMembers, E)` for a compile-time
/// generated lookup. Falls back to writing the underlying integer value
/// if no member matches (e.g., combined bit flags).
void writeEnumMemberName(E, Writer)(ref Writer w, const E val) @trusted
if (is(E == enum))
{
    import std.range.primitives : put;
    import std.traits : OriginalType;

    bool matched = false;

    static foreach (member; __traits(allMembers, E))
    {{
        if (!matched && val == __traits(getMember, E, member))
        {
            put(w, member);
            matched = true;
        }
    }}

    if (!matched)
        writeInteger(w, cast(OriginalType!E) val);
}

@("writeEnumMemberName.basic")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    enum Color { red, green, blue }

    SmallBuffer!(char, 32) buf;
    writeEnumMemberName(buf, Color.green);
    assert(buf[] == "green");
}

@("writeEnumMemberName.fallback")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    enum Flags : ubyte { a = 1, b = 2 }

    SmallBuffer!(char, 32) buf;
    writeEnumMemberName(buf, cast(Flags) 3);
    assert(buf[] == "3");
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

/// True if `T` is a leaf type that can be written by `writeStyledValue`
/// without requiring recursive pretty-printing.
///
/// Leaf types: `null`, `bool`, integrals, floating-point, `char`, `string`, `enum`.
template isLeafValue(T)
{
    import std.traits : isSomeChar, isSomeString;

    enum isLeafValue =
        is(T == typeof(null)) ||
        is(T == bool) ||
        is(T == enum) ||
        __traits(isIntegral, T) ||
        __traits(isFloating, T) ||
        isSomeChar!T ||
        isSomeString!T;
}

@("isLeafValue.builtinTypes")
@safe pure nothrow @nogc
unittest
{
    static assert(isLeafValue!bool);
    static assert(isLeafValue!int);
    static assert(isLeafValue!double);
    static assert(isLeafValue!char);
    static assert(isLeafValue!string);
    static assert(isLeafValue!(typeof(null)));

    enum Color { red }
    static assert(isLeafValue!Color);
}

@("isLeafValue.nonLeafTypes")
@safe pure nothrow @nogc
unittest
{
    struct S { int x; }
    static assert(!isLeafValue!S);
    static assert(!isLeafValue!(int[]));
    static assert(!isLeafValue!(int[string]));
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
void writeStyledValue(Hook, Writer, T)(ref Writer w, in T value, in Hook hook, bool useColors) @trusted
{
    import std.range.primitives : put;
    import std.traits : isSomeChar, isSomeString;

    // 1. Compute style from hook (optional primitive)
    Style style = Style.none;
    static if (__traits(compiles, hook.styleOf(value)))
    {
        if (useColors)
            style = hook.styleOf(value);
    }

    // 2. Open style
    if (style != Style.none)
        writeEscapeSeq(w, style[0]);

    // 3. Dispatch by type
    static if (is(T == typeof(null)))
    {
        put(w, "null");
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
            writeEnumMemberName(w, value);
        else
        {
            import std.traits : OriginalType;
            writeInteger(w, cast(OriginalType!T) value);
        }
    }
    else static if (is(T == bool))
    {
        put(w, value ? "true" : "false");
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
            writeEscapedCharLiteral(w, value);
        else
            put(w, (&value)[0 .. 1]);
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
            writeEscapedString(w, value);
        else
            put(w, value);
    }
    else static if (__traits(isIntegral, T))
    {
        writeInteger(w, value);
    }
    else static if (__traits(isFloating, T))
    {
        writeFloat(w, value);
    }
    else
    {
        // Non-leaf fallback: delegate to plain writeValue
        writeValue(w, value);
    }

    // 4. Close style
    if (style != Style.none)
        writeEscapeSeq(w, style[1]);
}

/// Default hook: no styling, no escaping, enums as integers.
@("writeStyledValue.defaultHook")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    struct NoHook {}

    SmallBuffer!(char, 64) buf;
    writeStyledValue(buf, 42, NoHook(), false);
    assert(buf[] == "42");

    buf.clear();
    writeStyledValue(buf, "hello", NoHook(), false);
    assert(buf[] == "hello");
}

/// Hook with styling: values get ANSI color codes.
@("writeStyledValue.withStyle")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : SmallBuffer;

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

    SmallBuffer!(char, 64) buf;
    writeStyledValue(buf, 42, BlueInts(), true);
    assert(buf[] == "\x1b[34m42\x1b[39m");
}

/// Hook with string escaping: strings get quotes and escape sequences.
@("writeStyledValue.escapedStrings")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    struct EscHook
    {
        enum escapeStrings = true;
        enum escapeChars = true;
    }

    SmallBuffer!(char, 64) buf;
    writeStyledValue(buf, "hi\nthere", EscHook(), false);
    assert(buf[] == `"hi\nthere"`);

    buf.clear();
    writeStyledValue(buf, '\t', EscHook(), false);
    assert(buf[] == `'\t'`);
}

/// Hook with enum member name rendering.
@("writeStyledValue.enumMemberName")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    enum Dir { north, south, east, west }

    struct EnumHook
    {
        enum enumRender = EnumRender.memberName;
    }

    SmallBuffer!(char, 32) buf;
    writeStyledValue(buf, Dir.south, EnumHook(), false);
    assert(buf[] == "south");
}

/// Hook with styling disabled (useColors=false): no escape codes emitted.
@("writeStyledValue.stylingDisabled")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    struct AlwaysBlue
    {
        Style styleOf(T)(in T) const @safe pure nothrow @nogc => Style.blue;
    }

    SmallBuffer!(char, 64) buf;
    writeStyledValue(buf, 42, AlwaysBlue(), false);
    assert(buf[] == "42");
}

/// Null value rendering.
@("writeStyledValue.null")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    struct YellowNull
    {
        Style styleOf(T)(in T) const @safe pure nothrow @nogc => Style.yellow;
    }

    SmallBuffer!(char, 64) buf;
    writeStyledValue(buf, null, YellowNull(), true);
    assert(buf[] == "\x1b[33mnull\x1b[39m");
}

/// Bool value rendering with styling.
@("writeStyledValue.bool")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : SmallBuffer;

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

    SmallBuffer!(char, 64) buf;
    writeStyledValue(buf, true, YellowBool(), true);
    assert(buf[] == "\x1b[33mtrue\x1b[39m");
}

/// Float special values with per-value styling.
@("writeStyledValue.floatSpecial")
@safe pure nothrow @nogc
unittest
{
    import std.math.traits : isNaN;
    import sparkles.core_cli.smallbuffer : SmallBuffer;

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

    SmallBuffer!(char, 64) buf;
    writeStyledValue(buf, double.nan, FloatHook(), true);
    assert(buf[] == "\x1b[31mnan\x1b[39m");

    buf.clear();
    writeStyledValue(buf, 3.14, FloatHook(), true);
    assert(buf[] == "\x1b[34m3.14\x1b[39m");
}
