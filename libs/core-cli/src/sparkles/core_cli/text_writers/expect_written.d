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
/// Params:
///   write    = delegate that writes into the buffer
///   expected = expected buffer contents after writing
alias WriterBuf = SmallBuffer!(char, 16 * 1024);

void expectWritten(
    void delegate(ref WriterBuf) @safe pure nothrow @nogc write,
    const(char)[] expected,
    string file = __FILE__,
    size_t line = __LINE__,
) @trusted pure nothrow @nogc
{
    WriterBuf buf;
    write(buf);
    checkWritten(buf[], expected, file, line);
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
