/** Structured errors shared by the SDL reader, writer, and typed codec. */
module sparkles.wired.sdl.error;

import expected : Expected, err, ok;

import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.base.text.errors : NoGcHook;
import sparkles.wired.sdl.document : SdlSpan;

/// Processing stage that produced an SDL error.
enum SdlErrorStage : ubyte
{
    lex,
    parse,
    decode,
    encode,
    fileRead,
    fileWrite,
}

/// Stable machine-readable SDL failure vocabulary.
enum SdlErrorCode : ubyte
{
    invalidUtf8,
    unsupportedBom,
    unexpectedCharacter,
    unexpectedToken,
    unexpectedEof,
    unterminatedString,
    unterminatedComment,
    invalidEscape,
    invalidIdentifier,
    invalidNumber,
    numberOutOfRange,
    invalidBase64,
    invalidDate,
    invalidDateTime,
    invalidDuration,
    depthExceeded,
    missingRole,
    duplicateRole,
    unexpectedKind,
    valueOutOfRange,
    unknownMember,
    conversionFailed,
    checkFailed,
    allocationFailed,
    fileReadFailed,
    fileWriteFailed,
}

/// One SDL operation failure, carried by value through `Expected`.
struct SdlError
{
    SdlErrorStage stage;
    SdlErrorCode code;
    SmallBuffer!(char, 40) sourceName;
    SdlSpan span;
    SdlSpan relatedSpan;
    bool hasRelatedSpan;
    SmallBuffer!(char, 48) valuePath;
    SmallBuffer!(char, 48) rolePath;
    string sourceType;
    string targetType;
    string expectedKind;
    string actualKind;
    string reason;
    SmallBuffer!(char, 40) filePath;
    int cause;

    /// Human-readable rendering over any character output range.
    void toString(Writer)(ref Writer w) const
    {
        import std.range.primitives : put;
        import sparkles.base.text.writers : writeInteger;

        if (sourceName.length)
        {
            put(w, sourceName[]);
            put(w, '(');
            writeInteger(w, span.start.line);
            put(w, ':');
            writeInteger(w, span.start.column);
            put(w, "): ");
        }

        final switch (stage)
        {
        case SdlErrorStage.lex:
        case SdlErrorStage.parse:
            put(w, "Cannot parse SDL");
            break;
        case SdlErrorStage.decode:
            put(w, "Cannot decode ");
            put(w, targetType);
            break;
        case SdlErrorStage.encode:
            put(w, "Cannot encode ");
            put(w, sourceType);
            break;
        case SdlErrorStage.fileRead:
            put(w, "Cannot read SDL file '");
            put(w, filePath[]);
            put(w, "'");
            break;
        case SdlErrorStage.fileWrite:
            put(w, "Cannot write SDL file '");
            put(w, filePath[]);
            put(w, "'");
            break;
        }

        if (valuePath.length || rolePath.length)
        {
            put(w, " at $");
            put(w, valuePath[]);
            put(w, rolePath[]);
        }
        if (reason.length)
        {
            put(w, ": ");
            put(w, reason);
        }
    }

    /// Allocating convenience rendering for exception and logging boundaries.
    string toString() const
    {
        import std.array : appender;

        auto w = appender!string;
        toString(w);
        return w[];
    }
}

/// SDL operation result with an allocation-free explicit state.
alias SdlExpected(T) = Expected!(T, SdlError, NoGcHook);

/// Constructs a successful SDL result carrying `value`.
SdlExpected!T sdlOk(T)(T value) @safe pure nothrow @nogc
    => ok!(SdlError, NoGcHook)(value);

/// Constructs a successful SDL result with no payload.
SdlExpected!void sdlOk() @safe pure nothrow @nogc
    => ok!(SdlError, NoGcHook)();

/// Constructs a failed SDL result.
SdlExpected!T sdlErr(T)(SdlError error) @safe pure nothrow @nogc
    => err!(T, NoGcHook)(error);

@("sdl.error.valueAndRendering")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.smallbuffer : checkWriter;
    import sparkles.wired.sdl.document : SdlPosition;

    SdlError failure;
    failure.stage = SdlErrorStage.decode;
    failure.code = SdlErrorCode.unexpectedKind;
    failure.sourceName ~= "dub.sdl";
    failure.span.start = SdlPosition(12, 2, 5);
    failure.targetType = "Dependency";
    failure.rolePath ~= ".dependency[1]@version";
    failure.reason = "expected a string";

    checkWriter!((ref w) => failure.toString(w))(
        "dub.sdl(2:5): Cannot decode Dependency at "
        ~ "$.dependency[1]@version: expected a string");

    auto result = sdlErr!int(failure);
    assert(result.hasError && result.error.code == SdlErrorCode.unexpectedKind);
    assert(sdlOk(7).value == 7);
}
