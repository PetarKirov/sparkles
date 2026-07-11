/**
The `Expected`-based error vocabulary for the tree-sitter binding.

Mirrors `sparkles.base.text.errors`: a machine-readable code enum, a small
error struct, an `Expected` alias reusing the `NoGcHook`, and `tsOk`/`tsErr`
constructor helpers.
*/
module sparkles.tree_sitter.errors;

import expected : Expected, err, ok;
import sparkles.base.text.errors : NoGcHook;

/// Machine-readable binding/engine error code.
enum TsErrorCode : ubyte
{
    none,                  /// no error (the `TsError.init` state)
    unsupportedPlatform,   /// grammar dlopen not implemented on this platform
    grammarNotFound,       /// no `<dir>/<lang>/parser` on the search path
    dlopenFailed,          /// dlopen refused the shared object
    symbolNotFound,        /// no `tree_sitter_<lang>` symbol in the object
    incompatibleAbi,       /// grammar ABI outside the runtime's window (`detail` = seen version)
    queryFileMissing,      /// no `queries/<kind>.scm` for the language
    querySyntax,           /// TSQueryErrorSyntax (`detail` = byte offset)
    queryNodeType,         /// TSQueryErrorNodeType (`detail` = byte offset)
    queryField,            /// TSQueryErrorField (`detail` = byte offset)
    queryCapture,          /// TSQueryErrorCapture (`detail` = byte offset)
    queryStructure,        /// TSQueryErrorStructure (`detail` = byte offset)
    queryLanguage,         /// TSQueryErrorLanguage
    queryPredicateInvalid, /// malformed predicate arguments / bad regex
    sourceTooLarge,        /// input exceeds the size guard (or 2 GiB hard cap)
    parseFailed,           /// parser returned no tree (e.g. no language set)
    parseTimeout,          /// parse budget exceeded (progress callback)
    parseCancelled,        /// host cancellation flag observed during parse
    highlightTimeout,      /// query/event budget exceeded
    highlightCancelled,    /// host cancellation flag observed during highlight
}

/// Structured binding/engine error: a code plus one code-specific detail
/// value (query byte offset, observed ABI version, …; 0 when unused).
struct TsError
{
    TsErrorCode code;  /// what went wrong
    uint detail;       /// code-specific detail (see $(LREF TsErrorCode))

    /// `true` iff this carries a real error (not `none`).
    bool opCast(T : bool)() const scope @safe pure nothrow @nogc
        => code != TsErrorCode.none;

    /// Renders `code` (and `detail` where meaningful) into any writer.
    void toString(Writer)(ref Writer w) const scope
    {
        import sparkles.base.text.writers : writeEnumMemberName, writeInteger;
        import std.range.primitives : put;

        writeEnumMemberName(w, code);
        final switch (code) with (TsErrorCode)
        {
            case querySyntax:
            case queryNodeType:
            case queryField:
            case queryCapture:
            case queryStructure:
                put(w, " at byte ");
                writeInteger(w, detail);
                return;
            case incompatibleAbi:
                put(w, " (grammar ABI version ");
                writeInteger(w, detail);
                put(w, ')');
                return;
            case none:
            case unsupportedPlatform:
            case grammarNotFound:
            case dlopenFailed:
            case symbolNotFound:
            case queryFileMissing:
            case queryLanguage:
            case queryPredicateInvalid:
            case sourceTooLarge:
            case parseFailed:
            case parseTimeout:
            case parseCancelled:
            case highlightTimeout:
            case highlightCancelled:
                return;
        }
    }
}

/// `Expected` specialized for $(LREF TsError) (same `NoGcHook` discipline as
/// `ParseExpected`).
alias TsExpected(T) = Expected!(T, TsError, NoGcHook);

/// Constructs a successful $(LREF TsExpected) carrying `value`.
TsExpected!T tsOk(T)(T value) @safe pure nothrow @nogc
    => ok!(TsError, NoGcHook)(value);

/// ditto — success with no payload.
TsExpected!void tsOk() @safe pure nothrow @nogc
    => ok!(TsError, NoGcHook)();

/// Constructs a failed $(LREF TsExpected)`!T` carrying `error`.
TsExpected!T tsErr(T)(TsError error) @safe pure nothrow @nogc
    => err!(T, NoGcHook)(error);

/// ditto — the common code (+ detail) form.
TsExpected!T tsErr(T)(TsErrorCode code, uint detail = 0) @safe pure nothrow @nogc
    => err!(T, NoGcHook)(TsError(code, detail));

@("tree_sitter.errors.expectedHelpers")
@safe pure nothrow @nogc
unittest
{
    auto good = tsOk(42);
    assert(good.hasValue && good.value == 42);

    auto bad = tsErr!int(TsErrorCode.querySyntax, 17);
    assert(bad.hasError);
    assert(bad.error.code == TsErrorCode.querySyntax);
    assert(bad.error.detail == 17);
    assert(bad.error);
    assert(!TsError.init);
}

@("tree_sitter.errors.toString")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.smallbuffer : checkToString;

    checkToString(TsError(TsErrorCode.querySyntax, 17), "querySyntax at byte 17");
    checkToString(TsError(TsErrorCode.incompatibleAbi, 12), "incompatibleAbi (grammar ABI version 12)");
    checkToString(TsError(TsErrorCode.parseTimeout), "parseTimeout");
}
