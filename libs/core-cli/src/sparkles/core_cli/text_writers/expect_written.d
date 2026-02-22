/**
 * @nogc-compatible test assertion helper for writer functions.
 */
module sparkles.core_cli.text_writers.expect_written;

version (unittest):

import sparkles.core_cli.smallbuffer : SmallBuffer;

/// @nogc-compatible test assertion for writer functions.
///
/// Allocates a `SmallBuffer`, passes it to the `write` delegate,
/// and asserts the buffer contents match `expected`.
///
/// Overloads are generated for all combinations of `pure`, `nothrow`,
/// and `@nogc` on the `write` callback (`@safe` is always required).
///
/// Params:
///   write    = delegate that writes into the buffer
///   expected = expected buffer contents after writing
alias WriterBuf = SmallBuffer!(char, 16 * 1024);

private:

import std.traits : FunctionAttribute, SetFunctionAttributes, functionLinkage;

alias FA = FunctionAttribute;

alias BaseWriteDg = void delegate(ref WriterBuf) @safe;

/// All 8 combinations of pure, nothrow, @nogc, always with @safe.
enum uint[8] attrCombinations = () {
    uint[8] result;
    enum base = functionAttributes!BaseWriteDg;
    static foreach (i; 0 .. 8)
        result[i] = base
            | ((i & 1) ? FA.pure_ : 0)
            | ((i & 2) ? FA.nothrow_ : 0)
            | ((i & 4) ? FA.nogc : 0);
    return result;
}();

import std.traits : functionAttributes;

static foreach (attrs; attrCombinations)
{
    public auto expectWritten(
        SetFunctionAttributes!(BaseWriteDg, functionLinkage!BaseWriteDg, attrs) write,
        const(char)[] expected,
        string file = __FILE__,
        size_t line = __LINE__,
    )
    {
        WriterBuf buf;
        write(buf);
        checkWritten(buf[], expected, file, line);
    }
}

void checkWritten(
    in char[] actual,
    in char[] expected,
    string file,
    size_t line,
) @trusted pure nothrow @nogc
{
    import core.exception : AssertError;
    import sparkles.core_cli.lifetime : recycledErrorInstance;

    if (actual != expected)
    {
        SmallBuffer!(char, 4 * 1024) errBuf;
        errBuf.put("expectWritten mismatch:\nExpected:\n");
        errBuf.put(expected);
        errBuf.put("\nActual:\n");
        errBuf.put(actual);

        throw recycledErrorInstance!AssertError(
            cast(string) errBuf[],
            file, line);
    }
}

/// Passes when written output matches expected string.
@("expectWritten.matching")
@safe pure nothrow @nogc
unittest
{
    expectWritten(
        (ref WriterBuf buf) { buf.put("hello"); },
        "hello",
    );
}

/// Passes with empty expected and empty write.
@("expectWritten.empty")
@safe pure nothrow @nogc
unittest
{
    expectWritten(
        (ref WriterBuf buf) {},
        "",
    );
}

/// Passes when multiple writes are concatenated.
@("expectWritten.multipleWrites")
@safe pure nothrow @nogc
unittest
{
    expectWritten(
        (ref WriterBuf buf) {
            buf.put("foo");
            buf.put("bar");
        },
        "foobar",
    );
}

/// Throws AssertError on mismatch.
@("expectWritten.mismatchThrows")
@system pure nothrow @nogc
unittest
{
    import core.exception : AssertError;

    bool threw = false;
    try
        expectWritten(
            (ref WriterBuf buf) { buf.put("actual"); },
            "expected",
        );
    catch (AssertError)
        threw = true;

    assert(threw, "expectWritten should throw on mismatch");
}

/// Verifies that calling `expectWritten` with a delegate of the given
/// attributes selects an overload whose inferred attributes match.
void checkExpectWrittenAttrs(uint writerAttrs)()
{
    alias WriteDg = SetFunctionAttributes!(BaseWriteDg, functionLinkage!BaseWriteDg, writerAttrs);
    alias call = (WriteDg dg) => expectWritten(dg, "ok");
    enum actual = functionAttributes!call;

    static assert(
        (actual & FA.pure_) == (writerAttrs & FA.pure_),
        "pure mismatch",
    );
    static assert(
        (actual & FA.nothrow_) == (writerAttrs & FA.nothrow_),
        "nothrow mismatch",
    );
    static assert(
        (actual & FA.nogc) == (writerAttrs & FA.nogc),
        "@nogc mismatch",
    );
    static assert(
        actual & FA.safe,
        "expectWritten overload must be @safe",
    );
}

void writeFunctionAttributeTest_safe(ref WriterBuf buf) @safe
{
    buf.put("ok");
}

void writeFunctionAttributeTest_safe_pure(ref WriterBuf buf) @safe pure
{
    buf.put("ok");
}

void writeFunctionAttributeTest_safe_nothrow(ref WriterBuf buf) @safe nothrow
{
    buf.put("ok");
}

void writeFunctionAttributeTest_safe_nogc(ref WriterBuf buf) @safe @nogc
{
    buf.put("ok");
}

void writeFunctionAttributeTest_safe_pure_nothrow(ref WriterBuf buf) @safe pure nothrow
{
    buf.put("ok");
}

void writeFunctionAttributeTest_safe_pure_nogc(ref WriterBuf buf) @safe pure @nogc
{
    buf.put("ok");
}

void writeFunctionAttributeTest_safe_nothrow_nogc(ref WriterBuf buf) @safe nothrow @nogc
{
    buf.put("ok");
}

void writeFunctionAttributeTest_safe_pure_nothrow_nogc(ref WriterBuf buf) @safe pure nothrow @nogc
{
    buf.put("ok");
}

/// expectWritten overload matches @safe-only callback attributes.
@("expectWritten.attrs.safe_only")
@safe pure nothrow @nogc
unittest
{
    checkExpectWrittenAttrs!(functionAttributes!writeFunctionAttributeTest_safe)();
}

/// expectWritten overload matches @safe pure callback attributes.
@("expectWritten.attrs.safe_pure")
@safe pure nothrow @nogc
unittest
{
    checkExpectWrittenAttrs!(functionAttributes!writeFunctionAttributeTest_safe_pure)();
}

/// expectWritten overload matches @safe nothrow callback attributes.
@("expectWritten.attrs.safe_nothrow")
@safe pure nothrow @nogc
unittest
{
    checkExpectWrittenAttrs!(functionAttributes!writeFunctionAttributeTest_safe_nothrow)();
}

/// expectWritten overload matches @safe @nogc callback attributes.
@("expectWritten.attrs.safe_nogc")
@safe pure nothrow @nogc
unittest
{
    checkExpectWrittenAttrs!(functionAttributes!writeFunctionAttributeTest_safe_nogc)();
}

/// expectWritten overload matches @safe pure nothrow callback attributes.
@("expectWritten.attrs.safe_pure_nothrow")
@safe pure nothrow @nogc
unittest
{
    checkExpectWrittenAttrs!(functionAttributes!writeFunctionAttributeTest_safe_pure_nothrow)();
}

/// expectWritten overload matches @safe pure @nogc callback attributes.
@("expectWritten.attrs.safe_pure_nogc")
@safe pure nothrow @nogc
unittest
{
    checkExpectWrittenAttrs!(functionAttributes!writeFunctionAttributeTest_safe_pure_nogc)();
}

/// expectWritten overload matches @safe nothrow @nogc callback attributes.
@("expectWritten.attrs.safe_nothrow_nogc")
@safe pure nothrow @nogc
unittest
{
    checkExpectWrittenAttrs!(functionAttributes!writeFunctionAttributeTest_safe_nothrow_nogc)();
}

/// expectWritten overload matches @safe pure nothrow @nogc callback attributes.
@("expectWritten.attrs.safe_pure_nothrow_nogc")
@safe pure nothrow @nogc
unittest
{
    checkExpectWrittenAttrs!(functionAttributes!writeFunctionAttributeTest_safe_pure_nothrow_nogc)();
}
