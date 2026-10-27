/** Structured errors shared by the SDL reader, writer, and typed codec. */
module sparkles.wired.sdl.error;

import expected : Expected, err, ok;

import sparkles.base.buffer : SharedBuffer, checkWriter;
import sparkles.base.text.errors : NoGcHook;
import sparkles.wired.sdl.document : SdlCore, SdlPosition, SdlSpan;

/// Processing stage that produced an SDL error.
enum SdlErrorStage : ubyte
{
    lex, /// Tokenizing source text.
    parse, /// Building the document from tokens.
    decode, /// Reading a typed value from a document.
    encode, /// Writing a value or document.
    fileRead, /// Reading a file.
    fileWrite, /// Writing a file.
}

/// Stable machine-readable SDL failure vocabulary.
enum SdlErrorCode : ubyte
{
    invalidUtf8, /// Source bytes are not valid UTF-8.
    unsupportedBom, /// A UTF-16 or UTF-32 byte-order mark.
    unexpectedCharacter, /// A character that cannot start or continue a token.
    unexpectedToken, /// A token the grammar does not allow here.
    unexpectedEof, /// Input ended inside a construct.
    unterminatedString, /// A string or character literal without its closing quote.
    unterminatedComment, /// A block comment without its closing `*/`.
    invalidEscape, /// An escape or continuation the literal does not support.
    invalidIdentifier, /// A malformed tag, namespace, or attribute name.
    invalidNumber, /// A malformed numeric literal or suffix.
    numberOutOfRange, /// A number outside its literal kind or the target type.
    invalidBase64, /// Malformed Base64 in a binary literal.
    invalidDate, /// A malformed or impossible date.
    invalidDateTime, /// A malformed date-time clock, fraction, or zone.
    invalidDuration, /// A malformed duration.
    depthExceeded, /// Child blocks nest deeper than `maxDepth`.
    missingRole, /// A required field's SDL role is absent.
    duplicateRole, /// A singular field's role occurs more than once.
    unexpectedKind, /// A scalar or node of the wrong kind for the field.
    valueOutOfRange, /// A temporal component, or an encoded value, outside its range.
    unknownMember, /// An unmatched occurrence under `@WireStrict`, or an unknown enum name.
    conversionFailed, /// A converter or adapter rejected the value.
    checkFailed, /// A `@WireCheck` rejected the value.
    unsupportedFeature, /// Syntax or a scalar family the profile disables.
    allocationFailed, /// The allocator could not supply arena memory.
    fileReadFailed, /// The file could not be read.
    fileWriteFailed, /// The file could not be written or renamed into place.
    errorSinkOverflow, /// A bounded error sink dropped further errors.
}

/// One SDL operation failure, carried by value through `Expected`.
struct SdlError
{
    /// Final marker a bounded sink appends once it has dropped an error.
    static SdlError sinkOverflow() @safe pure nothrow @nogc
    {
        SdlError result;
        result.stage = SdlErrorStage.decode;
        result.code = SdlErrorCode.errorSinkOverflow;
        result.reason ~= "additional SDL errors exceeded the error sink capacity";
        return result;
    }

    SdlErrorStage stage; /// Where the failure happened.
    SdlErrorCode code; /// What failed, as a stable code.
    SharedBuffer!(char, 40) sourceName; /// Source label, such as the file path.
    SdlSpan span; /// Offending source byte range, when input caused the failure.
    /// Line and column of `span`'s start and end, filled when the error is
    /// made, so rendering needs no document.
    SdlPosition startPosition;
    SdlPosition endPosition; /// ditto
    SdlSpan relatedSpan; /// Secondary context, such as an unclosed opener.
    bool hasRelatedSpan; /// Whether `relatedSpan` is set.
    SharedBuffer!(char, 48) valuePath; /// D value path, such as `$.deps[1].name`.
    SharedBuffer!(char, 48) rolePath; /// SDL role path, such as `$.dependency[1]@version` (SPEC §7).
    string sourceType; /// Type converted from, where applicable.
    string targetType; /// Type converted to, where applicable.
    string expectedKind; /// Kind the field required, where applicable.
    string actualKind; /// Kind the input supplied, where applicable.
    SharedBuffer!(char, 96) reason; /// Bounded human-readable explanation.
    SharedBuffer!(char, 40) filePath; /// Path of a failed file operation.
    int cause; /// OS error number of a failed file operation; `0` otherwise.
    /// Trial-decode failures in union declaration order, with their type/span.
    const(SdlError)[] variants;

    /// Human-readable rendering over any character output range.
    void toString(Writer)(ref Writer w) const
    {
        import std.range.primitives : put;
        import sparkles.base.text.writers : writeInteger;

        if (sourceName.length)
        {
            put(w, sourceName[]);
            put(w, '(');
            writeInteger(w, startPosition.line);
            put(w, ':');
            writeInteger(w, startPosition.column);
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

        if (rolePath.length)
        {
            put(w, " at $");
            put(w, rolePath[]);
        }
        if (valuePath.length)
        {
            put(w, rolePath.length ? " (value $" : " at $");
            put(w, valuePath[]);
            if (rolePath.length)
                put(w, ")");
        }
        if (reason.length)
        {
            put(w, ": ");
            put(w, reason[]);
        }
    }

    /// Allocating convenience rendering for exception and logging boundaries.
    string toString() const @safe
    {
        import std.array : appender;

        auto w = appender!string;
        toString(w);
        return w[];
    }
}

/** Fills `error`'s positions, and its variants', from the document core its
spans index. Decode errors are made from views, which reach the core; this
runs where such an error leaves the library. */
package void resolvePositions(ref SdlError error, scope const(SdlCore)* core)
    @safe pure
{
    if (core is null || core.source.length == 0)
        return;
    if (error.span.isValid)
    {
        error.startPosition = core.position(error.span.startOffset);
        error.endPosition = core.position(error.span.endOffset);
    }
    if (error.variants.length)
    {
        auto resolved = new SdlError[error.variants.length];
        foreach (i, ref variant; error.variants)
        {
            resolved[i] = variant;
            resolvePositions(resolved[i], core);
        }
        error.variants = resolved;
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
    import sparkles.base.buffer : SharedBuffer, checkWriter;

    SdlError failure;
    failure.stage = SdlErrorStage.decode;
    failure.code = SdlErrorCode.unexpectedKind;
    failure.sourceName ~= "dub.sdl";
    failure.span = SdlSpan(12, 13);
    failure.startPosition = SdlPosition(12, 2, 5);
    failure.targetType = "Dependency";
    failure.rolePath ~= ".dependency[1]@version";
    failure.reason ~= "expected a string";

    checkWriter!((ref w) => failure.toString(w))(
        "dub.sdl(2:5): Cannot decode Dependency at "
        ~ "$.dependency[1]@version: expected a string");

    auto result = sdlErr!int(failure);
    assert(result.hasError && result.error.code == SdlErrorCode.unexpectedKind);
    assert(sdlOk(7).value == 7);
}
