/**
Generic, `Expected`-based error vocabulary for text parsers.

The $(LREF readers) in this package, and any higher-level parser built on
them, report failures as a $(LREF ParseError) carried by
$(LREF ParseExpected). The vocabulary is deliberately scheme-agnostic —
it names mechanical parse outcomes (empty input, unexpected character,
numeric overflow, …), not domain concepts.
*/
module sparkles.core_cli.text.errors;

import expected : Expected, err, ok;

/// Machine-readable, scheme-agnostic text-parse error code.
enum ParseErrorCode
{
    emptyInput,          /// nothing to parse
    unexpectedCharacter, /// a character not allowed at this position
    unexpectedEnd,       /// input ended while more was required
    leadingZero,         /// a numeric field had a disallowed leading zero
    numericOverflow,     /// a number exceeded the target type's range
    invalidIdentifier,   /// an identifier contained a disallowed character
    widthMismatch,       /// a fixed-width field did not meet its width
}

/// Structured parse error: a $(LREF ParseErrorCode) plus the byte offset
/// (within the input the failing parser received) of the failure.
struct ParseError
{
    ParseErrorCode code; /// what went wrong
    size_t offset;       /// byte offset of the failure
}

/**
`expected` hook that keeps $(LREF ParseExpected) usable in
`@nogc nothrow` code: it disables the default constructor so a result is
always explicitly `ok` or `err`, never an ambiguous default.
*/
struct NoGcHook
{
    static immutable bool enableDefaultConstructor = false;
}

/// `Expected!` specialised for $(LREF ParseError): carries either a parsed
/// `T` or a structured $(LREF ParseError).
alias ParseExpected(T) = Expected!(T, ParseError, NoGcHook);

/// Constructs a successful $(LREF ParseExpected) carrying `value`, filling
/// in the `(ParseError, NoGcHook)` template arguments — a parser writes
/// `return parseOk(value);` rather than `ok!(ParseError, NoGcHook)(value)`.
ParseExpected!T parseOk(T)(T value) @safe pure nothrow @nogc
    => ok!(ParseError, NoGcHook)(value);

/// ditto — success with no payload (`ParseExpected!void`), for validators.
/// (Explicitly attributed: as a non-template it cannot infer them.)
ParseExpected!void parseOk() @safe pure nothrow @nogc
    => ok!(ParseError, NoGcHook)();

/// Constructs a failed $(LREF ParseExpected)`!T` carrying `error`. `T` is
/// explicit (there is no value to infer it from):
/// `return parseErr!uint(someError);`
ParseExpected!T parseErr(T)(ParseError error) @safe pure nothrow @nogc
    => err!(T, NoGcHook)(error);

/// ditto — the common `code` + `offset` form:
/// `return parseErr!T(ParseErrorCode.numericOverflow, i);`
ParseExpected!T parseErr(T)(ParseErrorCode code, size_t offset) @safe pure nothrow @nogc
    => err!(T, NoGcHook)(ParseError(code, offset));

@("text.errors.parseOk")
@safe pure nothrow @nogc
unittest
{
    auto good = parseOk(42);
    assert(good.hasValue);
    assert(good.value == 42);
}

@("text.errors.parseErr")
@safe pure nothrow @nogc
unittest
{
    auto bad = parseErr!int(ParseErrorCode.numericOverflow, 3);
    assert(!bad.hasValue);
    assert(bad.error.code == ParseErrorCode.numericOverflow);
    assert(bad.error.offset == 3);
}
