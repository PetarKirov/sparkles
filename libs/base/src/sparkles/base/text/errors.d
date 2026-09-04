/**
Generic, `Expected`-based error vocabulary for text parsers.

The $(LREF readers) in this package, and any higher-level parser built on
them, report failures as a $(LREF ParseError) carried by
$(LREF ParseExpected). The vocabulary is deliberately scheme-agnostic —
it names mechanical parse outcomes (empty input, unexpected character,
numeric overflow, …), not domain concepts.
*/
module sparkles.base.text.errors;

import std.traits : isInstanceOf, Unqual;

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
    unknownValue,        /// a token matched no value in a known (closed) set
    widthMismatch,       /// a fixed-width field did not meet its width
    nonCanonicalTrailing,/// unused trailing bits in a final encoded group were not zero
    paddingMismatch,     /// padding count did not match the final encoded group's length
    invalidEscape,       /// a string escape sequence was malformed
    invalidSurrogate,    /// a UTF-16 surrogate escape was lone or mispaired
    invalidUtf8,         /// a byte sequence was not well-formed UTF-8
    depthExceeded,       /// nesting exceeded the parser's depth limit
    trailingContent,     /// input continued after a complete value
    outOfMemory,         /// the parser's allocator failed
}

/// Structured parse error: a $(LREF ParseErrorCode) plus the byte offset
/// (within the input the failing parser received) of the failure.
struct ParseError
{
    ParseErrorCode code; /// what went wrong
    size_t offset;       /// byte offset of the failure
    /// optional borrowed detail (typically a CTFE literal, e.g.
    /// `"expected one of: a, b, c"`)
    string context = null;
}

/**
`expected` hook that keeps $(LREF ParseExpected) usable in
`@nogc nothrow` code: it disables the default constructor so a result is
always explicitly `ok` or `err`, never an ambiguous default.
*/
struct NoGcHook
{
    static immutable bool enableDefaultConstructor = false;

    /**
     * Reading `value` from a result that holds an error, or `error` from one
     * that holds a value, is a bug — not a `T.init`. Defining both hooks also
     * removes the accessors' `T.init`/`E.init` return paths, so their
     * `auto ref` returns by $(B reference) into the result's storage. That
     * matters for a copy-on-write payload: `r.value[]` on a by-value
     * temporary clones the block and frees the clone at the end of the
     * statement — a use-after-free `-preview=dip1000` cannot see — while a
     * reference slices the result's own buffer, valid for as long as `r` is.
     */
    static void onAccessEmptyValue(E)(E) @safe pure nothrow @nogc
    {
        assert(0, "Expected.value read from a result that holds an error");
    }

    /// ditto — a template so a `-betterC` consumer instantiates it in its own
    /// object rather than linking this module's.
    static void onAccessEmptyError()() @safe pure nothrow @nogc
    {
        assert(0, "Expected.error read from a result that holds a value");
    }
}

/**
`r.value` borrowed from a `scope` result.

With $(LREF NoGcHook) the accessors return by reference, but their misuse
path materializes a copy of the other side (the library hands the hook
`state == error ? getError() : E.init`), and copying an error that carries
indirections out of a `scope` result stops the compiler inferring `scope`
for the accessor. A result that borrows — a token over its source, a decode
whose extras view the document — is `scope`, so `r.value` on it is rejected
in `@safe` code. This borrows the payload through a `return scope` reference
without constructing anything; the one trusted step is taking the address
of the reference the accessor already returns.
*/
ref auto valueOf(R)(return ref scope R r) @safe
if (isInstanceOf!(Expected, Unqual!R))
    => *(() @trusted => &(r.value()))();

/// ditto
ref auto errorOf(R)(return ref scope R r) @safe
if (isInstanceOf!(Expected, Unqual!R))
    => *(() @trusted => &(r.error()))();

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

/// ditto — `code` + `offset` + a borrowed `context` detail (typically a CTFE
/// literal so the call stays `@nogc`):
/// `return parseErr!T(ParseErrorCode.unknownValue, 0, msg);`
ParseExpected!T parseErr(T)(ParseErrorCode code, size_t offset, string context) @safe pure nothrow @nogc
    => err!(T, NoGcHook)(ParseError(code, offset, context));

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

@("text.errors.structuredTextCodes")
@safe pure nothrow @nogc
unittest
{
    // The structured-text additions (JSON and friends) travel like any
    // other code, with a borrowed CTFE context.
    auto bad = parseErr!char(ParseErrorCode.invalidSurrogate, 7,
        "high surrogate not followed by a low surrogate");
    assert(bad.error.code == ParseErrorCode.invalidSurrogate);
    assert(bad.error.offset == 7);
    assert(bad.error.context.length > 0);

    auto deep = parseErr!void(ParseErrorCode.depthExceeded, 0);
    assert(deep.hasError);
}

// With both hooks in place neither accessor has a `T.init`/`E.init` return
// path, so `auto ref` returns by reference into the result's storage — a
// slice of a copy-on-write payload taken through `value` is a slice of the
// result's own buffer, not of a temporary clone freed at the statement's end.
@("text.errors.NoGcHook.accessorsReturnByReference")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.buffer : SharedBuffer;

    alias Text = SharedBuffer!(char, 8);
    ParseExpected!Text r = parseOk(Text());
    static assert(__traits(compiles, &(r.value())));
    static assert(__traits(compiles, &(r.error())));
    static assert(__traits(compiles, &(r.valueOf())));

    // Past the inline capacity, so the block is on the heap and a by-value
    // read would have cloned and freed it.
    foreach (i; 0 .. 300)
        r.value ~= cast(char)('a' + i % 26);
    const held = r.value[];
    assert(held.length == 300 && held[0 .. 4] == "abcd" && held[$ - 1] == 'n');
    assert(r.value[].ptr is held.ptr);
    assert(r.valueOf[].ptr is held.ptr);

    const ParseExpected!int c = parseOk(7);
    assert(c.valueOf == 7);
    const failed = parseErr!int(ParseErrorCode.emptyInput, 0);
    assert(failed.errorOf.code == ParseErrorCode.emptyInput);
}

// Reading the missing side is a bug and says so, instead of yielding `T.init`.
@("text.errors.NoGcHook.misreadAsserts")
@system unittest
{
    import core.exception : AssertError;

    static bool asserted(void delegate() @system dg)
    {
        try
            dg();
        catch (AssertError)
            return true;
        return false;
    }

    auto failed = parseErr!int(ParseErrorCode.emptyInput, 0);
    auto fine = parseOk(1);
    assert(asserted({ cast(void) failed.value; }));
    assert(asserted({ cast(void) fine.error; }));
    assert(!asserted({ cast(void) fine.value; }));
    assert(!asserted({ cast(void) failed.error; }));
}
