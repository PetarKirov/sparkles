/** Shared results and source endpoints for owned Unicode algorithms. */
module sparkles.base.text.unicode_algorithm;

import sparkles.base.text.utf : UtfToken, UtfTokenKind, isUnicodeScalar;

/// Storage limits are caller limits, never Unicode text length limits.
enum UnicodeStatus : ubyte
{
    ok,
    invalidInput,
    invalidOptions,
    unsupportedLocale,
    workspaceFull,
    outputFull,
    overflow,
    overlap,
    staleView,
}

/// Half-open original source code-unit interval.
struct UnicodeSourceSpan
{
    size_t start;
    size_t end;
}

/// Whole-operation result. Failure publishes no consumable output.
struct UnicodeResult
{
    UnicodeStatus status;
    size_t written;
    size_t required;
    UnicodeSourceSpan blocking;

    bool succeeded() const @safe pure nothrow @nogc => status == UnicodeStatus.ok;
}

/// Line opportunities distinguish hard breaks from selectable soft breaks.
enum UnicodeBoundaryKind : ubyte
{
    prohibited,
    allowed,
    mandatory,
}

/// Logical token boundary and its original source endpoint.
struct UnicodeBoundary
{
    size_t index;
    size_t offset;
    UnicodeBoundaryKind kind;
}

/// Validate scalar tokens and lossless opaque-byte tokens before property lookup.
bool validUnicodeToken(in UtfToken token) @safe pure nothrow @nogc
{
    switch (token.kind)
    {
    case UtfTokenKind.scalar:
    case UtfTokenKind.replacement:
        return isUnicodeScalar(token.scalar) && token.start <= token.end;
    case UtfTokenKind.opaqueByte:
        return token.start < token.end;
    default:
        return false;
    }
}

@("text.unicodeAlgorithm.tokenDomain")
@safe pure nothrow @nogc
unittest
{
    assert(validUnicodeToken(UtfToken(scalar: 'A', start: 2, end: 3)));
    assert(!validUnicodeToken(UtfToken(scalar: cast(dchar) 0xD800)));
    assert(!validUnicodeToken(UtfToken(scalar: 'A', start: 3, end: 2)));
    assert(validUnicodeToken(UtfToken(kind: UtfTokenKind.opaqueByte,
        byteValue: 0xFF, start: 2, end: 3)));
}
