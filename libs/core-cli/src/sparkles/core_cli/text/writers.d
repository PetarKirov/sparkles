/**
 * @nogc-compatible text writing utilities for output ranges.
 *
 * Provides functions for writing integers, floats, escaped characters/strings,
 * and ANSI escape sequences to output ranges without GC allocation.
 */
module sparkles.core_cli.text.writers;

import core.time : Duration;

import sparkles.core_cli.term_style : Style;

// ─────────────────────────────────────────────────────────────────────────────
// Integer Writing
// ─────────────────────────────────────────────────────────────────────────────

/// Writes an integer (signed or unsigned) to an output range. @nogc-compatible.
void writeInteger(Writer, T)(ref Writer w, const T val)
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

private void writeUnsignedImpl(Writer, T)(ref Writer w, const T val)
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

/// Writes an integer with at least `minDigits` digits, left-padded with
/// `'0'`. For a negative signed value the `'-'` is written first and only
/// the digit count (not the sign) is padded. `minDigits == 0` behaves like
/// $(LREF writeInteger).
void writeIntegerPadded(Writer, T)(ref Writer w, const T val, size_t minDigits)
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
            // unsigned arithmetic handles T.min correctly
            writeUnsignedPadded(w, cast(U)(0 - cast(U) val), minDigits);
        }
        else
            writeUnsignedPadded(w, cast(U) val, minDigits);
    }
    else
        writeUnsignedPadded(w, val, minDigits);
}

private void writeUnsignedPadded(Writer, T)(ref Writer w, const T val, size_t minDigits)
if (__traits(isUnsigned, T))
{
    import std.range.primitives : put;

    size_t digits = 1;
    for (T v = val; v >= 10; v /= 10)
        digits++;
    for (size_t i = digits; i < minDigits; i++)
        put(w, '0');
    writeUnsignedImpl(w, val);
}

@("writeIntegerPadded.pads")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : checkWriter;

    checkWriter!((ref b) => writeIntegerPadded(b, 7, 3))("007");
}

@("writeIntegerPadded.noPadWhenWideEnough")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : checkWriter;

    checkWriter!((ref b) => writeIntegerPadded(b, 1234, 3))("1234");
}

@("writeIntegerPadded.zeroWidthLikeWriteInteger")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : checkWriter;

    checkWriter!((ref b) => writeIntegerPadded(b, 42u, 0))("42");
}

@("writeIntegerPadded.negativeSignExcludedFromWidth")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : checkWriter;

    checkWriter!((ref b) => writeIntegerPadded(b, -5, 3))("-005");
}

@("writeInteger.positive")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : checkWriter;

    checkWriter!((ref b) => writeInteger(b, 42))("42");
}

@("writeInteger.negative")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : checkWriter;

    checkWriter!((ref b) => writeInteger(b, -123))("-123");
}

@("writeInteger.zero")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : checkWriter;

    checkWriter!((ref b) => writeInteger(b, 0))("0");
}

@("writeInteger.unsigned")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : checkWriter;

    checkWriter!((ref b) => writeInteger(b, 0uL))("0");
}

// ─────────────────────────────────────────────────────────────────────────────
// Floating-Point Writing
// ─────────────────────────────────────────────────────────────────────────────

/// Writes a floating-point value to an output range. @nogc-compatible.
/// Handles NaN, infinity, negative zero, and uses scientific notation for extreme values.
void writeFloat(Writer, T)(ref Writer w, const T val)
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
private void writeFloatDecimal(Writer, T)(ref Writer w, T value)
if (__traits(isFloating, T))
{
    import std.range.primitives : put;

    // Integer part.
    ulong intPart = cast(ulong) value;
    writeInteger(w, intPart);

    // Fractional part: a fixed-point integer of T.dig digits (6 for float, 15
    // for double — more accurate than a repeated multiply), trailing zeros
    // dropped. The integer/fraction split keeps `frac * scale` within a `ulong`
    // and within double precision.
    T frac = value - cast(T) intPart;
    if (frac > 0)
    {
        put(w, '.');
        enum int numDigits = T.dig;
        enum ulong scale = 10UL ^^ numDigits;
        const ulong fracInt = cast(ulong)(frac * scale + cast(T) 0.5);
        writeFractionDigits(w, fracInt, numDigits, stripTrailing: true);
    }
}

/// Writes a floating-point value in scientific notation. @nogc-compatible.
private void writeFloatScientific(Writer, T)(ref Writer w, T value)
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
void writeEscapedChar(Writer)(ref Writer w, char c)
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
void writeEscapedString(Writer)(ref Writer w, const(char)[] s)
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
void writeEscapedCharLiteral(Writer)(ref Writer w, char c)
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
void writeValue(Writer, T)(ref Writer w, auto ref const T val)
{
    import std.range.primitives : put;
    import std.traits : isSomeChar, isSomeString;

    static if (is(T == bool))
    {
        put(w, val ? "true" : "false");
    }
    else static if (isSomeChar!T)
    {
        // Copy the char into a one-element stack array and write its slice;
        // fully @safe, with no pointer aliasing of `val`.
        T[1] arr = val;
        put(w, arr[]);
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
void writeEscapeSeq(Writer)(ref Writer w, uint code)
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
void writeStylized(Writer)(ref Writer w, const(char)[] text, Style style, bool resetAfter = true)
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
void writeEnumMemberName(E, Writer)(ref Writer w, const E val)
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
void writeStyledValue(Hook, Writer, T)(ref Writer w, in T value, in Hook hook, bool useColors)
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

// ─────────────────────────────────────────────────────────────────────────────
// Byte / Duration Formatting
// ─────────────────────────────────────────────────────────────────────────────

/// Writes `number` as a fixed-point value with `radixPoint` fractional digits
/// in base `radix` (2 ≤ `radix` ≤ 16) — i.e. the value `number /
/// radix^^radixPoint`. The integer part is written first, then (when
/// `radixPoint > 0`) a `.` and exactly `radixPoint` zero-padded fractional
/// digits. `radix^^radixPoint` must fit in a `ulong`. @nogc-compatible.
///
/// Examples: `writeFixedPoint(w, 15, 1)` → `1.5`;
/// `writeFixedPoint(w, 1234, 2)` → `12.34`; `writeFixedPoint!16(w, 255, 2)` →
/// `0.ff`.
void writeFixedPoint(uint radix = 10, Writer)(
    ref Writer w, ulong number, uint radixPoint)
if (radix >= 2 && radix <= 16)
in (radixPoint <= 64, "radixPoint must be <= 64")
{
    import std.range.primitives : put;

    ulong divisor = 1;
    foreach (_; 0 .. radixPoint)
        divisor *= radix;

    // Integer part. Base 10 reuses the optimized writeInteger; other bases use
    // a most-significant-first digit walk.
    const ulong intPart = number / divisor;
    static if (radix == 10)
        writeInteger(w, intPart);
    else
    {
        char[64] buf = void;              // ≤ 64 digits for a ulong in base 2
        size_t start = buf.length;
        ulong v = intPart;
        do
        {
            buf[--start] = hexDigit(cast(uint)(v % radix));
            v /= radix;
        }
        while (v);
        put(w, buf[start .. $]);
    }

    if (radixPoint > 0)
    {
        put(w, '.');
        writeFractionDigits!radix(w, number % divisor, radixPoint);
    }
}

/// Writes the low `digits` base-`radix` digits of `value`, most-significant
/// first, zero-padded — a fixed-point fractional part, with no leading `.`.
/// When `stripTrailing`, trailing `'0'` digits are dropped (keeping at least
/// one). @nogc-compatible.
private void writeFractionDigits(uint radix = 10, Writer)(
    ref Writer w, ulong value, uint digits, bool stripTrailing = false)
{
    import std.range.primitives : put;

    char[64] buf = void;
    foreach_reverse (i; 0 .. digits)
    {
        buf[i] = hexDigit(cast(uint)(value % radix));
        value /= radix;
    }
    uint len = digits;
    if (stripTrailing)
        while (len > 1 && buf[len - 1] == '0')
            len--;
    put(w, buf[0 .. len]);
}

/// Maps a digit value `0 … 15` to its lower-case character (`0-9`, `a-f`).
private char hexDigit(uint d) @safe pure nothrow @nogc
    => cast(char)(d < 10 ? '0' + d : 'a' + (d - 10));

@("writeFixedPoint.basic")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    SmallBuffer!(char, 32) buf;
    void check(alias call)(string expected)
    {
        buf.clear();
        call(buf);
        assert(buf[] == expected);
    }

    check!((ref b) => writeFixedPoint(b, 15, 1))("1.5");
    check!((ref b) => writeFixedPoint(b, 160, 1))("16.0");        // carries
    check!((ref b) => writeFixedPoint(b, 1234, 2))("12.34");
    check!((ref b) => writeFixedPoint(b, 1000, 3))("1.000");      // zero-padded
    check!((ref b) => writeFixedPoint(b, 842, 0))("842");         // no point
    check!((ref b) => writeFixedPoint!16(b, 255, 2))("0.ff");     // base 16
    check!((ref b) => writeFixedPoint!16(b, 0xABC0, 1))("abc.0"); // base 16 int part
}

/// Writes a human-readable byte count using binary units — `B`, `KiB`, `MiB`,
/// `GiB`, `TiB`, `PiB`, `EiB` — with one (rounded) decimal place at `KiB` and
/// above (e.g. `512B`, `1.5KiB`, `532.3MiB`, `15.9GiB`, `4.0TiB`). `EiB` is the
/// largest unit needed: `ulong.max` is just under `16 EiB`. @nogc-compatible.
void writeBytes(Writer)(ref Writer w, ulong bytes)
{
    import std.range.primitives : put;

    enum ulong kib = 1UL << 10, mib = 1UL << 20, gib = 1UL << 30,
        tib = 1UL << 40, pib = 1UL << 50, eib = 1UL << 60;
    if (bytes >= eib)
        writeScaledBytes(w, bytes, eib, "EiB");
    else if (bytes >= pib)
        writeScaledBytes(w, bytes, pib, "PiB");
    else if (bytes >= tib)
        writeScaledBytes(w, bytes, tib, "TiB");
    else if (bytes >= gib)
        writeScaledBytes(w, bytes, gib, "GiB");
    else if (bytes >= mib)
        writeScaledBytes(w, bytes, mib, "MiB");
    else if (bytes >= kib)
        writeScaledBytes(w, bytes, kib, "KiB");
    else
    {
        writeInteger(w, bytes);
        put(w, 'B');
    }
}

/// Writes `bytes / unit` to one (half-up rounded) decimal place, then `suffix`.
private void writeScaledBytes(Writer)(
    ref Writer w, ulong bytes, ulong unit, string suffix)
{
    import std.range.primitives : put;

    const ulong whole = bytes / unit;
    const ulong rem = bytes % unit;       // rem < unit, so rem*10 cannot overflow
    // The value scaled to tenths, half-up rounded; a `rem` that rounds up to a
    // full unit carries into `whole` (writeFixedPoint divides the total by 10).
    writeFixedPoint(w, whole * 10 + (rem * 10 + unit / 2) / unit, 1);
    put(w, suffix);
}

/**
Writes a duration to `precision` decimal places (default `1`).

With `units == "auto"` (the default) the largest fitting unit is chosen — `ns`,
`µs`, `ms` below one second, then `s`, `m`, `h`, `d` — each rendered to
`precision` decimals; so the default `writeDuration(w, d)` gives `500.0ns`,
`1.5µs`, `5.5s`, `3.0d`, and `writeDuration(w, d, 0)` gives `500ns`, `2µs`,
`5s`. A negative duration is prefixed with `-`.

Any other `units` is a `core.time` unit name — `"nsecs"`, `"hnsecs"`,
`"usecs"`, `"msecs"`, `"seconds"`, `"minutes"`, `"hours"`, `"days"`, `"weeks"`
— and the whole duration is rendered in that single unit, e.g.
`writeDuration!"seconds"(w, d, 3)` → `5.500s`.

`units` is compile-time (it selects the scale and suffix); `precision` is a
runtime value (it only feeds $(LREF writeFixedPoint)'s decimal count) and must
be `<= 19` so `10^^precision` fits in a `ulong`.

@nogc-compatible. (Uses `total!"nsecs"`, which only overflows past ~292 years —
far beyond any duration this is meant to format.)
*/
void writeDuration(string units = "auto", Writer)(
    ref Writer w, in Duration duration, uint precision = 1)
in (precision <= 19, "precision must be <= 19 (10^^precision must fit in a ulong)")
{
    import std.range.primitives : put;

    long ns = duration.total!"nsecs";
    if (ns < 0)
    {
        put(w, '-');
        ns = -ns;
    }

    static if (units == "auto")
    {
        if (ns < 1_000)
            writeDurationIn!"nsecs"(w, ns, precision);
        else if (ns < 1_000_000)
            writeDurationIn!"usecs"(w, ns, precision);
        else if (ns < 1_000_000_000)
            writeDurationIn!"msecs"(w, ns, precision);
        else if (ns < 60_000_000_000L)
            writeDurationIn!"seconds"(w, ns, precision);
        else if (ns < 3_600_000_000_000L)
            writeDurationIn!"minutes"(w, ns, precision);
        else if (ns < 86_400_000_000_000L)
            writeDurationIn!"hours"(w, ns, precision);
        else
            writeDurationIn!"days"(w, ns, precision);
    }
    else
        writeDurationIn!units(w, ns, precision);
}

/// Renders `ns` nanoseconds in a single `unit` to `precision` decimal places
/// via $(LREF writeFixedPoint), followed by the unit's abbreviation.
private void writeDurationIn(string unit, Writer)(ref Writer w, long ns, uint precision)
{
    import std.range.primitives : put;

    enum long per = nsecsPerUnit!unit;    // nanoseconds in one `unit`
    ulong pow = 1;                        // 10^^precision
    foreach (_; 0 .. precision)
        pow *= 10;

    // The value `ns / per`, scaled by `pow` and half-up rounded, as the
    // fixed-point integer writeFixedPoint expects. Dividing first when `per`
    // is a multiple of `pow` avoids the intermediate overflow (the usual case
    // for these units and small `precision`).
    ulong number;
    if (per % pow == 0)
    {
        const ulong step = per / pow;     // step >= 1 (per is a multiple of pow)
        number = (cast(ulong) ns + step / 2) / step;
    }
    else
        number = (cast(ulong) ns * pow + per / 2) / per;

    writeFixedPoint(w, number, precision);
    put(w, durationUnitAbbrev!unit);
}

/// Nanoseconds in one `core.time` time unit.
private template nsecsPerUnit(string unit)
{
    static if (unit == "nsecs")        enum long nsecsPerUnit = 1L;
    else static if (unit == "hnsecs")  enum long nsecsPerUnit = 100L;
    else static if (unit == "usecs")   enum long nsecsPerUnit = 1_000L;
    else static if (unit == "msecs")   enum long nsecsPerUnit = 1_000_000L;
    else static if (unit == "seconds") enum long nsecsPerUnit = 1_000_000_000L;
    else static if (unit == "minutes") enum long nsecsPerUnit = 60_000_000_000L;
    else static if (unit == "hours")   enum long nsecsPerUnit = 3_600_000_000_000L;
    else static if (unit == "days")    enum long nsecsPerUnit = 86_400_000_000_000L;
    else static if (unit == "weeks")   enum long nsecsPerUnit = 604_800_000_000_000L;
    else static assert(false, "unsupported duration unit: " ~ unit);
}

/// Short suffix for a `core.time` time unit.
private template durationUnitAbbrev(string unit)
{
    static if (unit == "nsecs")        enum durationUnitAbbrev = "ns";
    else static if (unit == "hnsecs")  enum durationUnitAbbrev = "hns";
    else static if (unit == "usecs")   enum durationUnitAbbrev = "µs";
    else static if (unit == "msecs")   enum durationUnitAbbrev = "ms";
    else static if (unit == "seconds") enum durationUnitAbbrev = "s";
    else static if (unit == "minutes") enum durationUnitAbbrev = "m";
    else static if (unit == "hours")   enum durationUnitAbbrev = "h";
    else static if (unit == "days")    enum durationUnitAbbrev = "d";
    else static if (unit == "weeks")   enum durationUnitAbbrev = "w";
    else static assert(false, "unsupported duration unit: " ~ unit);
}

/// Writes a duration via $(LREF writeDuration), then right-pads with spaces to
/// at least `width` characters. @nogc-compatible.
void writeDurationPadded(Writer)(
    ref Writer w, in Duration duration, size_t width)
{
    import sparkles.core_cli.smallbuffer : SmallBuffer;
    import std.range.primitives : put;

    SmallBuffer!(char, 16) buf;
    writeDuration(buf, duration);
    const text = buf[];
    put(w, text);
    if (text.length < width)
        foreach (_; 0 .. width - text.length)
            put(w, ' ');
}

/**
Writes `elapsed` as a human-readable relative-time phrase: the largest
`maxUnits` (default `2`) non-zero units, joined Oxford-style and suffixed
`ago` for a non-negative duration or prefixed `in ` for a negative one — e.g.
`10 years and 3 months ago`, `in 2 days`, `5 seconds ago`, `500ms ago`.

`Duration` is not calendar-aware, so the calendar is approximate: a year is
365 days and a month is 30 days. Units descend years → months → days → hours
→ minutes → seconds as spelled-out words, then the abbreviated sub-second
units `ms` → `µs` → `ns`; zero units are skipped and a duration that rounds to
nothing renders as `0ms`. @nogc-compatible.
*/
void writeRelativeTime(Writer)(ref Writer w, in Duration elapsed, uint maxUnits = 2)
in (maxUnits >= 1, "maxUnits must be >= 1")
{
    import std.range.primitives : put;

    Duration d = elapsed;
    const past = !d.isNegative;
    if (d.isNegative)
        d = -d;

    auto parts = d.split!("days", "hours", "minutes", "seconds", "msecs", "usecs", "nsecs")();
    long days = parts.days;
    const years = days / 365;
    days %= 365;
    const months = days / 30;
    days %= 30;

    // `abbrev` units render as a tight `42µs` suffix; the rest as spelled-out,
    // pluralized words (`5 seconds`).
    static struct Unit { long value; string name; bool abbrev; }
    const Unit[9] units = [
        Unit(years,         "year"),
        Unit(months,        "month"),
        Unit(days,          "day"),
        Unit(parts.hours,   "hour"),
        Unit(parts.minutes, "minute"),
        Unit(parts.seconds, "second"),
        Unit(parts.msecs,   "ms", true),
        Unit(parts.usecs,   "µs", true),
        Unit(parts.nsecs,   "ns", true),
    ];
    enum msIndex = 6;       // floor unit when everything rounds to zero

    // The largest `maxUnits` non-zero units, in descending order.
    size_t[9] pick = void;
    size_t n = 0;
    foreach (i, ref u; units)
        if (u.value != 0 && n < maxUnits)
            pick[n++] = i;
    if (n == 0)             // everything rounded to zero → "0ms"
    {
        pick[0] = msIndex;
        n = 1;
    }

    if (!past)
        put(w, "in ");
    foreach (k; 0 .. n)
    {
        if (k > 0)
            put(w, k == n - 1 ? (n == 2 ? " and " : ", and ") : ", ");
        const u = units[pick[k]];
        writeInteger(w, u.value);
        if (u.abbrev)
            put(w, u.name);             // "500ms"
        else
        {
            put(w, ' ');
            put(w, u.name);             // "5 second"
            if (u.value != 1)
                put(w, 's');            // → "5 seconds"
        }
    }
    if (past)
        put(w, " ago");
}

@("writeBytes.units")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    SmallBuffer!(char, 32) buf;
    void check(ulong bytes, string expected)
    {
        buf.clear();
        writeBytes(buf, bytes);
        assert(buf[] == expected);
    }

    check(0, "0B");
    check(1023, "1023B");
    check(1024, "1.0KiB");
    check(1536, "1.5KiB");
    check(2047, "2.0KiB");                // rounds up across the unit boundary
    check(1UL << 20, "1.0MiB");
    check(1UL << 30, "1.0GiB");
    check((1UL << 40) * 4, "4.0TiB");
    check(1UL << 50, "1.0PiB");
    check((1UL << 60) * 2 + (1UL << 60) / 2, "2.5EiB");
    check(ulong.max, "16.0EiB");          // ulong.max ≈ 15.999… EiB, rounds to 16.0
}

@("writeDuration.units")
@safe pure nothrow @nogc
unittest
{
    import core.time : dur;
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    SmallBuffer!(char, 32) buf;
    void check(Duration d, string expected)
    {
        buf.clear();
        writeDuration(buf, d);
        assert(buf[] == expected);
    }

    // Default precision is 1, applied uniformly across every tier.
    check(dur!"nsecs"(0), "0.0ns");
    check(dur!"nsecs"(500), "500.0ns");
    check(dur!"nsecs"(1_500), "1.5µs");   // crosses into µs, one decimal
    check(dur!"usecs"(750), "750.0µs");
    check(dur!"usecs"(1_500), "1.5ms");
    check(dur!"msecs"(42), "42.0ms");
    check(dur!"msecs"(999), "999.0ms");
    check(dur!"msecs"(1_000), "1.0s");
    check(dur!"msecs"(5_500), "5.5s");
    check(dur!"msecs"(60_000), "1.0m");
    check(dur!"msecs"(90_000), "1.5m");
    check(dur!"hours"(1), "1.0h");
    check(dur!"hours"(24), "1.0d");
    check(dur!"nsecs"(-500), "-500.0ns");  // negative is prefixed with '-'
    check(dur!"msecs"(-1_500), "-1.5s");
}

@("writeDuration.explicitUnitAndPrecision")
@safe pure nothrow @nogc
unittest
{
    import core.time : dur;
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    SmallBuffer!(char, 32) buf;

    // `units` is compile-time, `precision` is a runtime argument.
    buf.clear();
    writeDuration!"seconds"(buf, dur!"msecs"(5_500), 3);
    assert(buf[] == "5.500s");

    buf.clear();
    writeDuration!"msecs"(buf, dur!"usecs"(1_500), 0);     // 1.5ms rounds to 2
    assert(buf[] == "2ms");

    buf.clear();
    writeDuration!"minutes"(buf, dur!"seconds"(90), 2);
    assert(buf[] == "1.50m");

    buf.clear();
    writeDuration!"usecs"(buf, dur!"nsecs"(2_500), 0);     // 2.5µs rounds to 3
    assert(buf[] == "3µs");

    // Precision flows through "auto" to sub-second tiers too.
    buf.clear();
    writeDuration(buf, dur!"nsecs"(500), 2);
    assert(buf[] == "500.00ns");

    buf.clear();
    writeDuration(buf, dur!"nsecs"(1_500), 0);             // auto, integer → rounds
    assert(buf[] == "2µs");
}

@("writeDurationPadded.padsToWidth")
@safe pure nothrow @nogc
unittest
{
    import core.time : dur;
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    SmallBuffer!(char, 32) buf;
    writeDurationPadded(buf, dur!"msecs"(1_500), 6);
    assert(buf[] == "1.5s  ");            // "1.5s" then padded to 6 chars
}

@("writeRelativeTime.phrases")
@safe pure nothrow @nogc
unittest
{
    import core.time : dur;
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    SmallBuffer!(char, 64) buf;
    void check(Duration d, uint maxUnits, string expected)
    {
        buf.clear();
        writeRelativeTime(buf, d, maxUnits);
        assert(buf[] == expected);
    }

    enum tenYrs = dur!"days"(365 * 10 + 30 * 3 + 10);   // ≈ 10y 3mo 10d
    check(tenYrs, 3, "10 years, 3 months, and 10 days ago");
    check(tenYrs, 2, "10 years and 3 months ago");
    check(tenYrs, 1, "10 years ago");

    check(dur!"minutes"(90), 2, "1 hour and 30 minutes ago");
    check(dur!"seconds"(5), 2, "5 seconds ago");
    check(dur!"days"(3), 2, "3 days ago");              // only one non-zero unit

    // Sub-second units are abbreviated (no space, no plural).
    check(dur!"msecs"(1_500), 2, "1 second and 500ms ago");
    check(dur!"msecs"(500), 2, "500ms ago");
    check(dur!"usecs"(42), 2, "42µs ago");
    check(dur!"nsecs"(700), 2, "700ns ago");
    check(dur!"msecs"(0), 2, "0ms ago");               // floors at ms, no special case

    check(-dur!"days"(2), 2, "in 2 days");             // negative → future
    check(-dur!"hours"(50), 2, "in 2 days and 2 hours");
}
