/**
 * The few text primitives the harness needs, without `sparkles:base`: every
 * package's tests depend on the harness, so it can depend on no repository
 * package (process-model TRP1).
 */
module sparkles.test_runner.text;

/// A NUL-terminated string assembled in a fixed buffer, for a path or name
/// handed to C. Appends that would not leave room for the terminator fail
/// and leave the contents unchanged.
package(sparkles.test_runner) struct StackCString(size_t capacity)
{
    private char[capacity] buffer = 0;
    private size_t length;

    /// Appends `s`; `false`, with nothing appended, when it does not fit.
    bool tryAppend(scope const(char)[] s) @safe pure nothrow @nogc
    {
        if (length + s.length >= capacity)
            return false;
        buffer[length .. length + s.length] = s[];
        length += s.length;
        buffer[length] = '\0';
        return true;
    }

    /// The terminated contents, valid while this buffer lives.
    const(char)* ptr() const @trusted pure nothrow @nogc return
        => &buffer[0];

    /// The contents without the terminator.
    const(char)[] opSlice() const @safe pure nothrow @nogc return
        => buffer[0 .. length];
}

@("text.StackCString.appendsAndTerminates")
@safe pure nothrow @nogc
unittest
{
    StackCString!8 s;
    assert(s.tryAppend("abc") && s.tryAppend("de"));
    assert(s[] == "abcde");
    assert(!s.tryAppend("xyz"), "would leave no room for the terminator");
    assert(s[] == "abcde");
    assert((() @trusted => s.ptr[5])() == '\0');
}

/// Appends the decimal digits of `value` to `sink`, an output range of
/// `char`.
package(sparkles.test_runner) void putDecimal(Sink)(ref Sink sink, long value)
{
    char[20] digits = void;
    size_t n;
    ulong magnitude = value < 0 ? -cast(ulong) value : value;
    do
    {
        digits[$ - ++n] = cast(char)('0' + magnitude % 10);
        magnitude /= 10;
    }
    while (magnitude);
    if (value < 0)
        sink ~= '-';
    sink ~= digits[$ - n .. $];
}

@("text.putDecimal.signs")
@safe pure nothrow
unittest
{
    string s;
    putDecimal(s, 0);
    s ~= ' ';
    putDecimal(s, -42);
    s ~= ' ';
    putDecimal(s, long.min);
    assert(s == "0 -42 -9223372036854775808");
}

/// The text of an interpolated sequence whose interpolated values are
/// integers or strings.
package(sparkles.test_runner) string interpolatedText(Args...)(Args args)
{
    import core.interpolation : InterpolationFooter, InterpolationHeader,
        InterpolatedExpression, InterpolatedLiteral;

    string s;
    static foreach (i, A; Args)
    {{
        static if (is(A == InterpolationHeader) || is(A == InterpolationFooter)
            || is(A == InterpolatedExpression!code, string code))
        {
        }
        else static if (is(A == InterpolatedLiteral!lit, string lit))
            s ~= lit;
        else static if (is(A : const(char)[]))
            s ~= args[i];
        else static if (__traits(isIntegral, A))
            putDecimal(s, args[i]);
        else
            static assert(false, "interpolatedText: unsupported " ~ A.stringof);
    }}
    return s;
}

@("text.interpolatedText.integersAndStrings")
@safe pure nothrow
unittest
{
    const n = 7;
    const what = "files";
    assert(interpolatedText(i"$(n) $(what), $(-1)") == "7 files, -1");
}
