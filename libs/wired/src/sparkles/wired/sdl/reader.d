/** Deterministic two-pass iterative SDL parser and ordered arena builder. */
module sparkles.wired.sdl.reader;

import std.experimental.allocator.common : stateSize;

import sparkles.base.text.errors : valueOf;
import sparkles.base.buffer : SharedBuffer;
import sparkles.base.text.lineindex : LineIndex;
import std.experimental.allocator.mallocator : Mallocator;

import sparkles.wired.sdl.config;
import sparkles.wired.sdl.document;
import sparkles.wired.sdl.error;
import sparkles.wired.sdl.lexer;

private struct ParseTotals
{
    size_t nodes = 1; // synthetic root
    size_t values;
    size_t attributes;
    size_t children;
    size_t comments;
    size_t poolBytes;
}

private struct CountBuffer(T)
{
    size_t length;
    void clear() @safe pure nothrow @nogc { length = 0; }
    void opOpAssign(string op : "~")(scope const(T)[] value)
        @safe pure nothrow @nogc
    {
        length += value.length;
    }
    void opOpAssign(string op : "~")(T value) @safe pure nothrow @nogc
    {
        length++;
    }
    const(T)[] opSlice() const @safe pure nothrow @nogc => null;
}

private struct CountStorage
{
    CountBuffer!char text;
    CountBuffer!ubyte bytes;
    void clear() @safe pure nothrow @nogc
    {
        text.clear();
        bytes.clear();
    }
}

private struct ExactTextBuffer
{
    ubyte[] target;
    size_t length;
    void clear() @safe pure nothrow @nogc { length = 0; }
    void opOpAssign(string op : "~")(scope const(char)[] value)
        @safe pure nothrow @nogc
    in (value.length <= target.length - length)
    {
        foreach (c; value)
            target[length++] = cast(ubyte) c;
    }
    void opOpAssign(string op : "~")(char value) @safe pure nothrow @nogc
    in (length < target.length)
    {
        target[length++] = cast(ubyte) value;
    }
    // Narrow trust: reinterprets the filled prefix of `target` as text.
    const(char)[] opSlice() const return scope @safe pure nothrow @nogc
        => (() @trusted => (cast(const(char)*) target.ptr)[0 .. length])();
}

private struct ExactByteBuffer
{
    ubyte[] target;
    size_t length;
    void clear() @safe pure nothrow @nogc { length = 0; }
    void opOpAssign(string op : "~")(scope const(ubyte)[] value)
        @safe pure nothrow @nogc
    in (value.length <= target.length - length)
    {
        target[length .. length + value.length] = value[];
        length += value.length;
    }
    void opOpAssign(string op : "~")(ubyte value) @safe pure nothrow @nogc
    in (length < target.length)
    {
        target[length++] = value;
    }
    const(ubyte)[] opSlice() const return scope @safe pure nothrow @nogc
        => target[0 .. length];
}

private struct ExactStorage
{
    ExactTextBuffer text;
    ExactByteBuffer bytes;
    void clear() @safe pure nothrow @nogc
    {
        text.clear();
        bytes.clear();
    }
}

private struct TokenCursor(SdlParserConfig config)
{
    SdlLexer!config lexer;
    SdlToken token;
    /// The token consumed before `token`; `hasPrevious` is false at the start.
    SdlTokenKind previousKind;
    size_t previousEnd;
    bool hasPrevious;
    SdlError error;
    bool failed;

    this(return scope const(char)[] source,
        return scope const(char)[] sourceName, SdlLexerLayout* layout)
    {
        lexer = lexSDL!config(source, sourceName);
        lexer._layout = layout;
        read();
    }

    void pop() scope
    {
        if (failed)
            return;
        previousKind = token.kind;
        previousEnd = token.span.endOffset;
        hasPrevious = true;
        lexer.popFront();
        read();
    }

    /// Fills `error`'s positions from the lexer, which has the source.
    void locate(ref SdlError error) const scope
    {
        if (error.span.isValid)
        {
            error.startPosition = lexer.position(error.span.startOffset);
            error.endPosition = lexer.position(error.span.endOffset);
        }
    }

    private void read() scope
    {
        if (lexer.empty)
            return;
        auto item = lexer.front;
        if (item.hasError)
        {
            error = copyError(item.error);
            failed = true;
        }
        else
            token = (() @trusted => item.value)();
    }
}

/// Expected-shaped parse result for the non-copyable SDL document.
struct SdlParseResult(Allocator = Mallocator)
{
    SdlDocument!Allocator document; /// valid iff `hasValue`
    SdlError error; /// meaningful iff `hasError`

    /// Whether the parse succeeded, as on `Expected`.
    bool hasValue() const @safe pure nothrow @nogc => document.valid;
    /// ditto
    bool hasError() const @safe pure nothrow @nogc => !document.valid;
}

/** Parses SDL into exact allocator-owned arenas.

The input and `sourceName` are borrowed only for the call. The successful
document owns all names, decoded strings, binary bytes, zones, and source name.
*/
SdlParseResult!Allocator parseSdlDocument(
    SdlParserConfig config = sdlFull, Allocator = Mallocator)(
    scope const(char)[] text, scope const(char)[] sourceName = null)
if (stateSize!Allocator == 0)
{
    SdlParseResult!Allocator result;
    parseInto!config(result, text, sourceName);
    return result;
}

/// ditto; stateful allocators are retained by the returned document.
SdlParseResult!Allocator parseSdlDocument(
    SdlParserConfig config = sdlFull, Allocator)(
    scope const(char)[] text, scope const(char)[] sourceName, Allocator alloc)
if (stateSize!Allocator != 0)
{
    import core.lifetime : move;

    SdlParseResult!Allocator result;
    result.document.alloc = move(alloc);
    parseInto!config(result, text, sourceName);
    return result;
}

/// ditto; convenient stateful-allocator overload without a source label.
SdlParseResult!Allocator parseSdlDocument(
    SdlParserConfig config = sdlFull, Allocator)(
    scope const(char)[] text, Allocator alloc)
if (stateSize!Allocator != 0)
    => parseSdlDocument!config(text, null, alloc);

/** Parses `text` whose nodes all lie inside `content`, such as an embedded
recipe's rendering: extents are clipped to `content`, and everything else
behaves as $(LREF parseSdlDocument). */
package SdlParseResult!Allocator parseSdlDocumentIn(SdlParserConfig config, Allocator)(
    scope const(char)[] text, scope const(char)[] sourceName, SdlSpan content)
if (stateSize!Allocator == 0)
{
    SdlParseResult!Allocator result;
    parseInto!config(result, text, sourceName, content);
    return result;
}

/// ditto; a stateful allocator is retained by the returned document.
package SdlParseResult!Allocator parseSdlDocumentIn(SdlParserConfig config, Allocator)(
    scope const(char)[] text, scope const(char)[] sourceName, SdlSpan content,
    Allocator alloc)
if (stateSize!Allocator != 0)
{
    import core.lifetime : move;

    SdlParseResult!Allocator result;
    result.document.alloc = move(alloc);
    parseInto!config(result, text, sourceName, content);
    return result;
}

/** Validates SDL text against a profile without retaining a document
(SPEC §11).

A successful result proves the input parses under `config`; nothing is kept,
so this is a pure check with no arena cost beyond the discarded parse. All
lex/parse/decode failures propagate unchanged with their structured stage,
code, span, and source name.
*/
SdlExpected!void validateSDL(SdlParserConfig config = sdlFull)(
    scope const(char)[] text, scope const(char)[] sourceName = null)
{
    auto parsed = parseSdlDocument!config(text, sourceName);
    if (parsed.hasValue)
        return sdlOk();
    return sdlErr!void(parsed.error);
}

private bool scalarToken(SdlTokenKind kind) @safe pure nothrow @nogc
{
    return kind >= SdlTokenKind.null_ && kind <= SdlTokenKind.duration;
}

private bool terminator(SdlTokenKind kind) @safe pure nothrow @nogc
    => kind == SdlTokenKind.newline || kind == SdlTokenKind.semicolon;

private SdlError parseError(SdlErrorCode code, SdlSpan span,
    scope const(char)[] sourceName, string reason) @safe pure nothrow @nogc
{
    SdlError result;
    result.stage = SdlErrorStage.parse;
    result.code = code;
    result.span = span;
    result.sourceName ~= sourceName;
    result.reason ~= reason;
    return result;
}

private void ensureSourceName(ref SdlError error,
    scope const(char)[] sourceName) @safe pure nothrow @nogc
{
    if (error.sourceName.length == 0)
        error.sourceName ~= sourceName;
}

private SdlError copyError(ref scope const SdlError source) @safe pure nothrow @nogc
{
    SdlError result;
    result.stage = source.stage;
    result.code = source.code;
    result.sourceName ~= source.sourceName[];
    result.span = source.span;
    result.startPosition = source.startPosition;
    result.endPosition = source.endPosition;
    result.relatedSpan = source.relatedSpan;
    result.hasRelatedSpan = source.hasRelatedSpan;
    result.valuePath ~= source.valuePath[];
    result.rolePath ~= source.rolePath[];
    // The four `string` fields name types and kinds — text the compiler
    // emitted, never text borrowed from a document — so copying one out of a
    // `scope` error extends no borrow.
    result.sourceType = (() @trusted => source.sourceType)();
    result.targetType = (() @trusted => source.targetType)();
    result.expectedKind = (() @trusted => source.expectedKind)();
    result.actualKind = (() @trusted => source.actualKind)();
    result.reason ~= source.reason[];
    result.filePath ~= source.filePath[];
    result.cause = source.cause;
    return result;
}

private bool checkedAdd(ref size_t target, size_t amount)
    @safe pure nothrow @nogc
{
    if (amount > size_t.max - target)
        return false;
    target += amount;
    return true;
}

private size_t contentStart(scope const(char)[] source) @safe pure nothrow @nogc
    => source.length >= 3 && cast(ubyte) source[0] == 0xEF
        && cast(ubyte) source[1] == 0xBB && cast(ubyte) source[2] == 0xBF ? 3 : 0;

private SdlSpan rootStartSpan(scope const(char)[] source)
    @safe pure nothrow @nogc
{
    const start = source.length < uint.max ? contentStart(source) : 0;
    return SdlSpan.at(start);
}

/// A parse error before lexing starts, at the content start (line 1, column 1).
private SdlError startError(SdlErrorCode code, scope const(char)[] source,
    scope const(char)[] sourceName, string reason) @safe pure nothrow @nogc
{
    auto error = parseError(code, rootStartSpan(source), sourceName, reason);
    error.startPosition = error.endPosition = SdlPosition(error.span.startOffset);
    return error;
}

private SdlSpan unmatchedOpener(SdlParserConfig config)(
    scope const(char)[] source, scope const(char)[] sourceName,
    uint targetDepth) @safe pure nothrow @nogc
{
    auto lexer = lexSDL!config(source, sourceName);
    uint depth;
    SdlSpan result;
    while (!lexer.empty)
    {
        auto item = lexer.front;
        if (item.hasError)
            break;
        // `item` is `scope`: a token borrows the source.
        const kind = item.valueOf.kind;
        if (kind == SdlTokenKind.openBrace)
        {
            if (depth == targetDepth)
                result = item.valueOf.span;
            depth++;
        }
        else if (kind == SdlTokenKind.closeBrace && depth)
            depth--;
        lexer.popFront();
    }
    return result;
}

private void parseInto(SdlParserConfig config, Allocator)(
    ref SdlParseResult!Allocator result, scope const(char)[] text,
    scope const(char)[] sourceName, SdlSpan content = SdlSpan.init)
{
    // `TextSpan` reserves `uint.max`, so every offset and end must stay below it.
    if (text.length >= uint.max)
    {
        result.error = startError(SdlErrorCode.allocationFailed, text, sourceName,
            "SDL source is too long for 32-bit spans");
        return;
    }

    ParseTotals totals;
    if (!checkedAdd(totals.poolBytes, sourceName.length)
        || !checkedAdd(totals.poolBytes, text.length))
    {
        result.error = startError(SdlErrorCode.allocationFailed, text, sourceName,
            "SDL arena size overflows size_t");
        return;
    }

    if (!content.isValid)
        content = SdlSpan(contentStart(text), text.length);

    SdlError failure;
    SdlLexerLayout counted;
    if (!runPass!(config, false)(text, sourceName, content, totals,
        result.document, counted, failure))
    {
        ensureSourceName(failure, sourceName);
        result.error = failure;
        return;
    }
    totals.comments = counted.commentCount;

    if (!result.document.acquire(totals.nodes, totals.values,
        totals.attributes, totals.children, totals.comments, totals.poolBytes))
    {
        result.error = startError(SdlErrorCode.allocationFailed, text, sourceName,
            "allocator rejected an SDL arena block");
        return;
    }

    // The document owns its source: the copy follows the source name in the
    // pool, and the fill pass lexes the copy.
    auto core = result.document.core;
    auto pool = result.document.pool;
    pool[sourceName.length .. sourceName.length + text.length] = cast(const(ubyte)[]) text[];
    core.source = () @trusted {
        return (cast(const(char)*) pool.ptr + sourceName.length)[0 .. text.length];
    }();
    core.content = content;

    ParseTotals filled;
    filled.poolBytes = sourceName.length + text.length;
    SdlLexerLayout layout;
    layout.comments = core.comments;
    layout.recordLines = true;
    if (!runPass!(config, true)(core.source, sourceName, content, filled,
        result.document, layout, failure))
    {
        result.document = SdlDocument!Allocator.init;
        ensureSourceName(failure, sourceName);
        result.error = failure;
        return;
    }
    core.lines = LineIndex(layout.lineStarts[], text.length, contentStart(text));
    finalizeChildren(result.document);
}

private bool runPass(SdlParserConfig config, bool fill, Allocator)(
    scope const(char)[] text, scope const(char)[] sourceName, SdlSpan content,
    ref ParseTotals totals, ref SdlDocument!Allocator document,
    ref SdlLexerLayout layout, ref SdlError failure)
{
    auto cursor = TokenCursor!config(text, sourceName, &layout);
    void takeCursorError()
    {
        import core.lifetime : move;

        () @trusted { failure = move(cursor.error); }();
    }
    if (cursor.failed)
    {
        takeCursorError();
        return false;
    }

    size_t nodeIndex = 1;
    size_t valueIndex;
    size_t attributeIndex;
    size_t poolAt = sourceName.length + (fill ? text.length : 0);
    uint contextDepth;

    static if (fill)
    {
        const rootSpan = rootStartSpan(text);
        auto nodes = document.core.nodes;
        nodes[0] = SdlNodeCell(
            qualifiedName: SdlQualifiedName.init,
            nameSpan: rootSpan,
            span: rootSpan,
            depth: uint.max,
            extent: content,
            aloneOnLines: true,
        );
        if (sourceName.length)
        {
            document.pool[0 .. sourceName.length] = cast(const(ubyte)[]) sourceName[];
            document.ownedSourceName = () @trusted {
                return (cast(const(char)*) document.pool.ptr)[0 .. sourceName.length];
            }();
        }
    }

    bool fail(SdlErrorCode code, SdlSpan span, string reason)
    {
        failure = parseError(code, span, sourceName, reason);
        cursor.locate(failure);
        return false;
    }

    /** Records a node's terminator and its extent (editing §2), once its
    terminator — for a block, the one after `}` — is known. */
    void finishLayout(size_t node, SdlTokenKind terminatorKind,
        SdlSpan terminatorSpan, in SdlToken next)
    {
        static if (fill)
        {
            nodes[node].terminator = terminatorSpan;
            nodeExtent(text, content, nodes[node], terminatorKind, next.kind, next.span);
        }
    }

    bool addPool(size_t amount, SdlSpan span)
    {
        if (!checkedAdd(totals.poolBytes, amount))
            return fail(SdlErrorCode.allocationFailed, span,
                "SDL arena size overflows size_t");
        return true;
    }

    const(char)[] ownText(scope const(char)[] value)
    {
        static if (fill)
        {
            const start = poolAt;
            document.pool[start .. start + value.length]
                = cast(const(ubyte)[]) value[];
            poolAt += value.length;
            return () @trusted {
                return (cast(const(char)*) document.pool.ptr + start)[0 .. value.length];
            }();
        }
        else
            return null;
    }

    bool decodeValue(SdlToken token, out SdlScalar scalar)
    {
        static if (fill)
        {
            ExactStorage storage;
            storage.text.target = document.pool[poolAt .. $];
            storage.bytes.target = document.pool[poolAt .. $];
            auto decoded = decodeSdlScalarInto!config(token, storage);
            if (decoded.hasError)
            {
                failure = (() @trusted { return copyError(decoded.error); })();
                cursor.locate(failure);
                return false;
            }
            () @trusted { scalar = decoded.value; }();
            scalar.setSpan(token.span);
            poolAt += storage.text.length + storage.bytes.length;
        }
        else
        {
            CountStorage storage;
            auto decoded = decodeSdlScalarInto!config(token, storage);
            if (decoded.hasError)
            {
                failure = (() @trusted { return copyError(decoded.error); })();
                cursor.locate(failure);
                return false;
            }
            if (!addPool(storage.text.length + storage.bytes.length,
                token.span))
                return false;
        }
        return true;
    }

    bool readName(out SdlQualifiedName name, out SdlSpan nameSpan)
    {
        if (cursor.token.kind != SdlTokenKind.identifier)
            return fail(SdlErrorCode.unexpectedToken, cursor.token.span,
                "expected an SDL identifier");
        const first = cursor.token;
        cursor.pop();
        if (cursor.failed) { takeCursorError(); return false; }
        nameSpan = first.span;
        if (cursor.token.kind == SdlTokenKind.colon)
        {
            cursor.pop();
            if (cursor.failed) { takeCursorError(); return false; }
            if (cursor.token.kind != SdlTokenKind.identifier)
                return fail(cursor.token.kind == SdlTokenKind.eof
                        ? SdlErrorCode.unexpectedEof : SdlErrorCode.invalidIdentifier,
                    cursor.token.span, "qualified name requires a local name after ':'");
            const second = cursor.token;
            nameSpan = SdlSpan(first.span.startOffset, second.span.endOffset);
            static if (fill)
                name = SdlQualifiedName(ownText(first.raw), ownText(second.raw));
            else if (!addPool(first.raw.length + second.raw.length, nameSpan))
                return false;
            cursor.pop();
        }
        else
        {
            static if (fill)
                name = SdlQualifiedName(null, ownText(first.raw));
            else if (!addPool(first.raw.length, nameSpan))
                return false;
        }
        if (cursor.failed) { takeCursorError(); return false; }
        return true;
    }

    while (true)
    {
        while (terminator(cursor.token.kind))
        {
            cursor.pop();
            if (cursor.failed) { takeCursorError(); return false; }
        }

        if (cursor.token.kind == SdlTokenKind.eof)
        {
            if (contextDepth != 0)
            {
                failure = parseError(SdlErrorCode.unexpectedEof,
                    cursor.token.span, sourceName, "missing closing '}'");
                cursor.locate(failure);
                failure.relatedSpan = unmatchedOpener!config(text, sourceName,
                    contextDepth - 1);
                failure.hasRelatedSpan = true;
                return false;
            }
            break;
        }

        if (cursor.token.kind == SdlTokenKind.closeBrace)
        {
            if (contextDepth == 0)
                return fail(SdlErrorCode.unexpectedToken, cursor.token.span,
                    "closing brace has no matching child block");
            const close = cursor.token;
            cursor.pop();
            if (cursor.failed) { takeCursorError(); return false; }
            size_t end = close.span.endOffset;
            SdlTokenKind closeTerminator = SdlTokenKind.eof;
            SdlSpan closeTerminatorSpan = SdlSpan.at(text.length);
            if (terminator(cursor.token.kind))
            {
                end = cursor.token.span.endOffset;
                closeTerminator = cursor.token.kind;
                closeTerminatorSpan = cursor.token.span;
                cursor.pop();
                if (cursor.failed) { takeCursorError(); return false; }
            }
            else if (cursor.token.kind != SdlTokenKind.eof)
                return fail(SdlErrorCode.unexpectedToken, cursor.token.span,
                    "child block must be followed by a terminator");
            contextDepth--;
            static if (fill)
            {
                size_t owner = nodeIndex;
                while (owner > 1)
                {
                    owner--;
                    if (nodes[owner].depth == contextDepth)
                    {
                        nodes[owner].span = SdlSpan(nodes[owner].span.startOffset, end);
                        nodes[owner].closeBrace = close.span;
                        finishLayout(owner, closeTerminator, closeTerminatorSpan,
                            cursor.token);
                        break;
                    }
                }
            }
            continue;
        }

        const tagStart = cursor.token.span.startOffset;
        // A node starts its line when the token before it is a newline or
        // there is none; the end of that token is where its line begins.
        const startsLine = !cursor.hasPrevious
            || cursor.previousKind == SdlTokenKind.newline;
        const lineStart = cursor.hasPrevious ? cursor.previousEnd : content.startOffset;
        SdlQualifiedName tagName;
        SdlSpan tagNameSpan = SdlSpan.at(tagStart);
        const named = cursor.token.kind == SdlTokenKind.identifier;
        if (named)
        {
            if (!readName(tagName, tagNameSpan))
                return false;
        }
        else if (!scalarToken(cursor.token.kind))
            return fail(SdlErrorCode.unexpectedToken, cursor.token.span,
                "expected an SDL tag name or anonymous scalar value");
        else if (!config.syntax.anonymousTags)
            return fail(SdlErrorCode.unsupportedFeature, cursor.token.span,
                "anonymous tags are disabled by this SDL profile");

        const thisNode = nodeIndex++;
        static if (fill)
            nodes[thisNode] = SdlNodeCell(
                qualifiedName: tagName,
                nameSpan: tagNameSpan,
                span: SdlSpan.at(tagStart),
                valueStart: valueIndex,
                attributeStart: attributeIndex,
                depth: contextDepth,
                // Provisional: `nodeExtent` reads these back as the start
                // candidates, then replaces `extent`.
                extent: SdlSpan(lineStart, tagStart),
                aloneOnLines: startsLine,
            );
        else
        {
            if (!checkedAdd(totals.nodes, 1)
                || !checkedAdd(totals.children, 1))
                return fail(SdlErrorCode.allocationFailed, SdlSpan.at(tagStart),
                    "SDL arena size overflows size_t");
        }

        size_t tagValues;
        while (scalarToken(cursor.token.kind))
        {
            SdlScalar scalar;
            if (!decodeValue(cursor.token, scalar))
                return false;
            static if (fill)
                document.core.values[valueIndex] = SdlValueCell(scalar);
            valueIndex++;
            tagValues++;
            static if (!fill)
                if (!checkedAdd(totals.values, 1))
                    return fail(SdlErrorCode.allocationFailed, cursor.token.span,
                        "SDL arena size overflows size_t");
            cursor.pop();
            if (cursor.failed) { takeCursorError(); return false; }
        }
        if (!named && tagValues == 0)
            return fail(SdlErrorCode.unexpectedToken, cursor.token.span,
                "anonymous tag requires at least one scalar value");

        size_t tagAttributes;
        while (cursor.token.kind == SdlTokenKind.identifier)
        {
            SdlQualifiedName attributeName;
            SdlSpan attributeNameSpan;
            if (!readName(attributeName, attributeNameSpan))
                return false;
            if (cursor.token.kind != SdlTokenKind.equals)
                return fail(SdlErrorCode.unexpectedToken, cursor.token.span,
                    "attribute name must be followed by '='");
            cursor.pop();
            if (cursor.failed) { takeCursorError(); return false; }
            if (!scalarToken(cursor.token.kind))
                return fail(cursor.token.kind == SdlTokenKind.eof
                        ? SdlErrorCode.unexpectedEof : SdlErrorCode.unexpectedToken,
                    cursor.token.span, "attribute requires one scalar value");
            const valueToken = cursor.token;
            SdlScalar scalar;
            if (!decodeValue(valueToken, scalar))
                return false;
            static if (fill)
                document.core.attributes[attributeIndex] = SdlAttributeCell(
                    attributeName, attributeNameSpan,
                    SdlSpan(attributeNameSpan.startOffset, valueToken.span.endOffset), scalar);
            attributeIndex++;
            tagAttributes++;
            static if (!fill)
                if (!checkedAdd(totals.attributes, 1))
                    return fail(SdlErrorCode.allocationFailed, valueToken.span,
                        "SDL arena size overflows size_t");
            cursor.pop();
            if (cursor.failed) { takeCursorError(); return false; }
        }

        static if (fill)
        {
            nodes[thisNode].valueCount = tagValues;
            nodes[thisNode].attributeCount = tagAttributes;
        }

        if (cursor.token.kind == SdlTokenKind.openBrace)
        {
            const opener = cursor.token;
            if (contextDepth >= config.maxDepth)
                return fail(SdlErrorCode.depthExceeded, opener.span,
                    "SDL child block exceeds maxDepth");
            cursor.pop();
            if (cursor.failed) { takeCursorError(); return false; }
            if (!terminator(cursor.token.kind))
                return fail(cursor.token.kind == SdlTokenKind.eof
                        ? SdlErrorCode.unexpectedEof : SdlErrorCode.unexpectedToken,
                    cursor.token.span,
                    "child block opener must be followed by a terminator");
            do
            {
                cursor.pop();
                if (cursor.failed) { takeCursorError(); return false; }
            }
            while (terminator(cursor.token.kind));
            contextDepth++;
            static if (fill)
            {
                nodes[thisNode].hasBlock = true;
                nodes[thisNode].openBrace = opener.span;
            }
            continue;
        }

        const terminatorToken = cursor.token;
        if (terminator(cursor.token.kind))
        {
            cursor.pop();
            if (cursor.failed) { takeCursorError(); return false; }
        }
        else if (cursor.token.kind != SdlTokenKind.eof)
            return fail(SdlErrorCode.unexpectedToken, cursor.token.span,
                "tag declaration requires a newline, semicolon, or document EOF");
        static if (fill)
            nodes[thisNode].span = SdlSpan(tagStart, terminatorToken.span.endOffset);
        finishLayout(thisNode, terminatorToken.kind, terminatorToken.span,
            cursor.token);
    }

    static if (fill)
    {
        assert(nodeIndex == nodes.length);
        assert(valueIndex == document.core.values.length);
        assert(attributeIndex == document.core.attributes.length);
        assert(poolAt == document.pool.length);
    }
    return true;
}

/** Sets a node's extent and `aloneOnLines` (editing §2).

On entry `extent` holds the start candidates — the end of the token before the
node and its first byte — and `aloneOnLines` whether the node starts its line;
`terminator` is set. A node alone on its lines owns them whole, from the start
of its first line through the newline that ends its terminator's line. Otherwise
the extent is inline: from the end of the preceding terminator, or the first
byte when the node starts its line, through its `;` (and the spaces and tabs
after it, when it started its line), or up to the newline that ends its line.
The result is clipped to the content.
*/
private void nodeExtent(scope const(char)[] text, SdlSpan content,
    ref SdlNodeCell cell, SdlTokenKind terminatorKind, SdlTokenKind nextKind,
    SdlSpan nextSpan) @safe pure nothrow @nogc
{
    with (SdlTokenKind)
    {
        const lineStart = cell.extent.startOffset;
        const firstByte = cell.extent.endOffset;
        const startsLine = cell.aloneOnLines;
        const term = cell.terminator;
        const endsLine = terminatorKind == newline || terminatorKind == eof
            || (terminatorKind == semicolon && (nextKind == newline || nextKind == eof));
        cell.aloneOnLines = startsLine && endsLine;

        size_t start, end;
        if (cell.aloneOnLines)
        {
            start = lineStart;
            if (terminatorKind == newline)
                end = term.endOffset;
            else if (terminatorKind == semicolon && nextKind == newline)
                end = nextSpan.endOffset;
            else
                end = content.endOffset;
        }
        else
        {
            start = startsLine ? firstByte : lineStart;
            if (terminatorKind == semicolon)
            {
                end = term.endOffset;
                if (startsLine)
                    while (end < content.endOffset && (text[end] == ' ' || text[end] == '\t'))
                        end++;
            }
            else if (terminatorKind == newline)
                end = term.startOffset;
            else
                end = content.endOffset;
        }
        if (start < content.startOffset)
            start = content.startOffset;
        if (end > content.endOffset)
            end = content.endOffset;
        cell.extent = SdlSpan(start, end < start ? start : end);
    }
}

/** Links each node to its parent's contiguous child-index window.

Nodes are in source preorder, so a node's parent is the most recent node one
level shallower. Tracking that per level makes both passes linear; scanning
backwards for it instead costs O(n) per node, which is quadratic in the number
of siblings — the shape every flat document has.
*/
private void finalizeChildren(Allocator)(ref SdlDocument!Allocator document)
{
    if (document.core.nodes.length < 2)
        return;

    // Deepest node decides the ladder's height; the root sits below level 0.
    uint deepest;
    foreach (i; 1 .. document.core.nodes.length)
        if (document.core.nodes[i].depth != uint.max
            && document.core.nodes[i].depth > deepest)
            deepest = document.core.nodes[i].depth;

    auto lastAtDepth = SharedBuffer!(size_t, 32)();
    foreach (_; 0 .. cast(size_t) deepest + 1)
        lastAtDepth ~= 0;

    size_t parentOf(size_t i)
    {
        const depth = document.core.nodes[i].depth;
        return depth == 0 ? 0 : lastAtDepth[depth - 1];
    }

    foreach (i; 1 .. document.core.nodes.length)
    {
        document.core.nodes[parentOf(i)].childCount++;
        lastAtDepth[document.core.nodes[i].depth] = i;
    }

    size_t next;
    foreach (ref node; document.core.nodes)
    {
        node.childStart = next;
        next += node.childCount;
        node.childCount = 0;
    }

    foreach (ref slot; lastAtDepth[])
        slot = 0;
    foreach (i; 1 .. document.core.nodes.length)
    {
        const parent = parentOf(i);
        document.core.childIndexes[document.core.nodes[parent].childStart
            + document.core.nodes[parent].childCount++] = i;
        lastAtDepth[document.core.nodes[i].depth] = i;
    }
}

@("sdl.reader.grammarArenaAndFiltering")
@safe
unittest
{
    auto parsed = parseSdlDocument!sdlFull(
        "a 1 x:v=\"one\" x:v=\"two\" {\n"
        ~ "b true\n"
        ~ "n:b false\n"
        ~ "b on\n"
        ~ "}\n"
        ~ "a 2;", "memory.sdl");
    assert(parsed.hasValue);
    auto root = parsed.document.root;
    assert(root.qualifiedName == SdlQualifiedName.init);
    assert(root.childCount == 2);
    auto first = root.byChild.front;
    assert(first.qualifiedName.localName == "a");
    assert(first.valueCount == 1 && first.attributeCount == 2
        && first.childCount == 3);
    assert(first.byValue.front.integer == 1);
    size_t duplicateAttributes;
    foreach (attribute; first.byAttribute(SdlQualifiedName("x", "v")))
        duplicateAttributes++;
    assert(duplicateAttributes == 2);
    size_t exactChildren;
    foreach (child; first.byChild(SdlQualifiedName(null, "b")))
        exactChildren++;
    assert(exactChildren == 2);
    size_t wildcardChildren;
    foreach (child; first.byChild(SdlNameQuery.anyNamespace("b")))
        wildcardChildren++;
    assert(wildcardChildren == 3);
}

@("sdl.reader.grammarRejectionsAndDepth")
@safe
unittest
{
    enum noAnonymous = SdlParserConfig(
        scalars: sdlFull.scalars,
        syntax: SdlSyntaxFeatures(
            rawStrings: true, unicodeIdentifiers: true, unicodeWhitespace: true,
            unicodeNewlines: true, hashComments: true, slashComments: true,
            dashComments: true, blockComments: true, continuations: true,
            semicolonTerminators: true, anonymousTags: false),
    );
    assert(parseSdlDocument!noAnonymous("1\n").error.code
        == SdlErrorCode.unsupportedFeature);
    assert(parseSdlDocument!sdlFull("a { b\n}\n").error.code
        == SdlErrorCode.unexpectedToken);
    assert(parseSdlDocument!sdlFull("a x=\n").error.code
        == SdlErrorCode.unexpectedToken);
    assert(parseSdlDocument!sdlFull("a {\nb\n").error.code
        == SdlErrorCode.unexpectedEof);
    enum flatOnly = SdlParserConfig(
        scalars: sdlFull.scalars, syntax: sdlFull.syntax, maxDepth: 0);
    assert(parseSdlDocument!flatOnly("a\n").hasValue);
    assert(parseSdlDocument!flatOnly("a {\n}\n").error.code
        == SdlErrorCode.depthExceeded);
}

@("sdl.reader.inputAndSourceNameAreOwned")
@safe
unittest
{
    char[15] source = "name \"payload\"\n";
    char[10] label = "memory.sdl";
    auto parsed = parseSdlDocument!sdlFull(source[], label[]);
    assert(parsed.hasValue);
    source[] = 'x';
    label[] = 'y';
    assert(parsed.document.sourceName == "memory.sdl");
    auto node = parsed.document.root.byChild.front;
    assert(node.qualifiedName.localName == "name");
    assert(node.byValue.front.stringValue == "payload");
}

@("sdl.reader.moveAndLifetimeContract")
@safe
unittest
{
    import core.lifetime : move;

    auto parsed = parseSdlDocument!sdlFull("name \"value\"\n");
    auto moved = move(parsed.document);
    assert(moved.valid && !parsed.document.valid);
    static assert(!__traits(compiles, { auto copy = moved; }));

    static assert(!__traits(compiles, () @safe {
        auto local = parseSdlDocument("tag 42\n");
        return local.document.root;
    }));
    static assert(!__traits(compiles, () @safe {
        auto local = parseSdlDocument("tag 42\n");
        return local.document.root.byChild.front;
    }));
    static assert(!__traits(compiles, () @safe {
        auto local = parseSdlDocument("tag 42\n");
        return local.document.root.byChild;
    }));
    static assert(!__traits(compiles, () @safe {
        auto local = parseSdlDocument("tag \"value\" attr=\"attribute\"\n");
        return local.document.root.byChild.front.byValue.front;
    }));
    static assert(!__traits(compiles, () @safe {
        auto local = parseSdlDocument("tag attr=\"attribute\"\n");
        return local.document.root.byChild.front.byAttribute.front;
    }));
    static assert(!__traits(compiles, () @safe {
        auto local = parseSdlDocument("tag attr=\"attribute\"\n");
        return local.document.root.byChild.front.byAttribute;
    }));


    // Positive: metadata-only access accepts a scope parameter. Lending
    // views additionally borrows the owner itself and takes an ordinary ref.
    static assert(__traits(compiles, (scope ref SdlDocument!() document) @safe {
        auto valid = document.valid;
    }));
    static assert(__traits(compiles, (scope ref SdlDocument!() document) @safe {
        auto name = document.sourceName;
    }));
    static assert(__traits(compiles, (scope ref SdlDocument!() document) @safe {
        return document.root.childCount;
    }));
    static void borrowEverything(ref SdlDocument!() d) @safe
    {
        auto root = d.root;
        auto values = root.byValue;
        auto attributes = root.byAttribute;
        auto children = root.byChild;
        auto filteredAttributes = root.byAttribute(SdlQualifiedName(null, "x"));
        auto filteredChildren = root.byChild(SdlNameQuery.anyNamespace("x"));
        size_t total;
        foreach (value; values)
            total += value.kind == SdlScalarKind.none;
        foreach (child; children)
            total += child.valueCount;
    }
    {
        auto owned = parseSdlDocument!sdlFull("a 1\n");
        borrowEverything(owned.document);
        static assert(__traits(compiles,
            (ref SdlDocument!() document) @safe {
                borrowEverything(document);
            }));
    }
    static assert(__traits(compiles, (ref SdlDocument!() document) @safe {
        auto values = document.root.byValue;
        size_t total;
        foreach (value; values)
            total += value.kind == SdlScalarKind.none;
    }));
    static assert(__traits(compiles, (ref SdlDocument!() document) @safe {
        auto children = document.root.byChild;
        size_t total;
        foreach (child; children)
            total += child.valueCount;
    }));
    static assert(__traits(compiles, (ref SdlDocument!() document) @safe {
        auto filteredAttributes =
            document.root.byAttribute(SdlQualifiedName(null, "x"));
    }));
    static assert(__traits(compiles, (ref SdlDocument!() document) @safe {
        auto filteredChildren =
            document.root.byChild(SdlNameQuery.anyNamespace("x"));
    }));
    static assert(__traits(compiles, (ref SdlDocument!() document) @safe {
        auto values = document.root.byValue;
        size_t total;
        foreach (value; values)
            total += value.kind == SdlScalarKind.none;
    }));
    static assert(__traits(compiles, (ref SdlDocument!() document) @safe {
        auto children = document.root.byChild;
        size_t total;
        foreach (child; children)
            total += child.valueCount;
    }));
    static assert(__traits(compiles, (ref SdlDocument!() document) @safe {
        auto attributes = document.root.byAttribute;
    }));
    static assert(__traits(compiles, (ref SdlDocument!() document) @safe {
        auto filteredAttributes =
            document.root.byAttribute(SdlQualifiedName(null, "x"));
    }));
    static assert(__traits(compiles, (ref SdlDocument!() document) @safe {
        auto filteredChildren =
            document.root.byChild(SdlNameQuery.anyNamespace("x"));
    }));

    // Negative: nothing borrowed from the scope'd document may outlive it.
    // Payload slices as well as whole cursors must remain within the owner.
    static assert(!__traits(compiles, { auto copy = moved; }));
    static assert(!__traits(compiles, {
        const(char)[] escape(scope ref SdlDocument!() document) @safe
        {
            auto node = document.root;
            return node.qualifiedName.localName;
        }
    }));
    static assert(!__traits(compiles, {
        const(char)[] escape(scope ref SdlDocument!() document) @safe
        {
            auto values = document.root.byValue;
            foreach (value; values)
                if (value.kind == SdlScalarKind.string_)
                    return value.stringValue;
            return null;
        }
    }));
    static assert(!__traits(compiles, {
        const(ubyte)[] escape(scope ref SdlDocument!() document) @safe
        {
            auto values = document.root.byValue;
            foreach (value; values)
                if (value.kind == SdlScalarKind.binary)
                    return value.binary;
            return null;
        }
    }));
    static assert(!__traits(compiles, {
        const(char)[] escape(scope ref SdlDocument!() document) @safe
        {
            auto children = document.root.byChild;
            foreach (child; children)
                return child.byValue.front.stringValue;
            return null;
        }
    }));
    static assert(!__traits(compiles, {
        const(char)[] escape(scope ref SdlDocument!() document) @safe
        {
            auto attributes = document.root.byAttribute;
            foreach (attribute; attributes)
                return attribute.qualifiedName.localName;
            return null;
        }
    }));
    static assert(!__traits(compiles, {
        const(char)[] escape(scope ref SdlDocument!() document) @safe
        {
            auto filtered =
                document.root.byChild(SdlNameQuery.anyNamespace("x"));
            foreach (child; filtered)
                return child.byValue.front.stringValue;
            return null;
        }
    }));
    static assert(!__traits(compiles, {
        const(char)[] escape(scope ref SdlDocument!() document) @safe
        {
            auto name = document.sourceName;
            return name;
        }
    }));
}



@("sdl.reader.spansBomTerminatorsAndMissingBraceContext")
@safe
unittest
{
    enum source = "\xEF\xBB\xBFa \"x\" k=true {\r\nb;\r\n}\r\n";
    auto parsed = parseSdlDocument!sdlFull(source, "span.sdl");
    assert(parsed.hasValue);
    auto root = parsed.document.root;
    assert(root.span.startOffset == 3 && root.span.endOffset == 3);
    auto parent = root.byChild.front;
    assert(parent.nameSpan.startOffset == 3
        && parent.nameSpan.endOffset == 4);
    assert(parent.span.startOffset == 3
        && parent.span.endOffset == source.length);
    auto value = parent.byValue.front;
    assert(value.span.startOffset == 5 && value.span.endOffset == 8);
    auto attribute = parent.byAttribute.front;
    assert(attribute.nameSpan.startOffset == 9
        && attribute.nameSpan.endOffset == 10);
    assert(attribute.span.startOffset == 9
        && attribute.span.endOffset == 15);
    auto child = parent.byChild.front;
    assert(child.span.startOffset == 19 && child.span.endOffset == 21);

    auto eof = parseSdlDocument!sdlFull("tag");
    assert(eof.hasValue && eof.document.root.byChild.front.span.endOffset == 3);
    auto missing = parseSdlDocument!sdlFull("outer {\ninner {\n}\n");
    assert(missing.hasError && missing.error.code == SdlErrorCode.unexpectedEof);
    assert(missing.error.hasRelatedSpan
        && missing.error.relatedSpan.startOffset == 6);
}

@("sdl.reader.scalarKindsAndExactPayloadRetention")
@system
unittest
{
    auto parsed = parseSdlDocument!sdlFull(
        "v null true \"s\\n\" 'x' -1 2L .5F .25D 3BD "
        ~ "[TQ==]; v 2024/2/29; v 2024/2/29 01:02:03; "
        ~ "v 2024/2/29 01:02:03-GMT+02:00; v 01:02:03\n");
    assert(parsed.hasValue, parsed.error.toString);
    static immutable expected = [
        SdlScalarKind.null_, SdlScalarKind.boolean, SdlScalarKind.string_,
        SdlScalarKind.character, SdlScalarKind.integer,
        SdlScalarKind.longInteger, SdlScalarKind.float_,
        SdlScalarKind.double_, SdlScalarKind.decimal, SdlScalarKind.binary,
        SdlScalarKind.date, SdlScalarKind.dateTime,
        SdlScalarKind.zonedDateTime, SdlScalarKind.duration,
    ];
    size_t index;
    foreach (node; parsed.document.root.byChild)
    foreach (value; node.byValue)
    {
        assert(value.kind == expected[index++]);
        if (value.kind == SdlScalarKind.string_)
            assert(value.stringValue == "s\n");
        if (value.kind == SdlScalarKind.binary)
            assert(value.binary == [cast(ubyte) 'M']);
        if (value.kind == SdlScalarKind.zonedDateTime)
            assert(value.zonedDateTime.zone == "GMT+02:00");
    }
    assert(index == expected.length);
}

@("sdl.reader.allocatorFailureRollbackEveryBlock")
@system unittest
{
    static struct FailingAllocator
    {
        size_t failAt;
        size_t* attempts;
        size_t* liveBlocks;

        enum uint alignment = Mallocator.alignment;

        void[] allocate(size_t amount) @safe nothrow @nogc
        {
            const attempt = (*attempts)++;
            if (attempt == failAt)
                return null;
            auto block = (() @trusted => Mallocator.instance.allocate(amount))();
            if (block !is null)
                (*liveBlocks)++;
            return block;
        }

        bool deallocate(void[] block) @safe nothrow @nogc
        {
            if (block is null)
                return true;
            (*liveBlocks)--;
            return (() @trusted => Mallocator.instance.deallocate(block))();
        }
    }

    // Every block: core, nodes, values, attributes, children, comments, pool.
    enum source = "a [TQ==] x=\"v\" { # c\nb\n}\n";
    {
        size_t attempts;
        size_t liveBlocks;
        auto empty = parseSdlDocument!sdlFull("", null,
            FailingAllocator(size_t.max, &attempts, &liveBlocks));
        assert(empty.hasValue && attempts == 2 && liveBlocks == 2); // core, nodes
    }
    foreach (failAt; 0 .. 7)
    {
        size_t attempts;
        size_t liveBlocks;
        {
            auto parsed = parseSdlDocument!sdlFull(source, "alloc.sdl",
                FailingAllocator(failAt, &attempts, &liveBlocks));
            assert(parsed.hasError
                && parsed.error.code == SdlErrorCode.allocationFailed);
        }
        assert(attempts == failAt + 1);
        assert(liveBlocks == 0);
    }

    size_t attempts;
    size_t liveBlocks;
    {
        auto parsed = parseSdlDocument!sdlFull(source, "alloc.sdl",
            FailingAllocator(size_t.max, &attempts, &liveBlocks));
        assert(parsed.hasValue && attempts == 7 && liveBlocks == 7);
    }
    assert(liveBlocks == 0);
}

@("sdl.reader.namedProfilesArbitraryByteSmoke")
@safe
unittest
{
    foreach (value; 0 .. 256)
    {
        char[1] source = [cast(char) value];
        auto full = parseSdlDocument!sdlFull(source[]);
        auto compat = parseSdlDocument!sdlDubCompat(source[]);
        auto recipe = parseSdlDocument!sdlDubRecipe(source[]);
        assert(full.hasValue || full.hasError);
        assert(compat.hasValue || compat.hasError);
        assert(recipe.hasValue || recipe.hasError);
    }
}

@("sdl.reader.allInTreeAndPinnedDubRecipes")
@system unittest
{
    import core.exception : AssertError;
    import std.file : SpanMode, dirEntries, isSymlink, readText;
    import std.path : baseName;

    static void check(string path)
    {
        const source = readText(path);
        auto parsed = parseSdlDocument!sdlDubRecipe(source, path);
        if (parsed.hasError)
            throw new AssertError(parsed.error.toString);
    }

    static void visit(string directory, ref size_t count)
    {
        foreach (entry; dirEntries(directory, SpanMode.shallow))
        {
            if (entry.isDir)
            {
                const name = entry.name.baseName;
                if (name == ".git" || name == ".direnv" || name == ".dub"
                    || name == "build" || name == "node_modules"
                    || isSymlink(entry.name))
                    continue;
                visit(entry.name, count);
            }
            else if (entry.isFile && entry.name.baseName == "dub.sdl")
            {
                check(entry.name);
                count++;
            }
        }
    }

    size_t count;
    visit(".", count);
    assert(count > 100);

    // Direct compatibility fixture: dlang/dub dub.sdl at
    // 5efed360e1c9342453bc5dd19339c75981526d83 (MIT; fixture README/notices).
    enum pinned = "libs/wired/src/sparkles/wired/sdl/fixtures/"
        ~ "dub-5efed360-recipe.snapshot.sdl";
    check(pinned);
}

@("sdl.reader.pinnedDubRecipeSemanticSnapshot")
@system unittest
{
    // Adapted fixture: shaped after dlang/dub source/dub/recipe/sdl.d at
    // 5efed360e1c9342453bc5dd19339c75981526d83 (MIT; see
    // libs/wired/THIRD_PARTY_NOTICES.md). Inline adaptation of its documented
    // recipe forms — not a byte-for-byte upstream copy.
    static immutable string[] pieces = [
        `authors "Petar Kirov"`,
        `authors "Ada Lovelace"`,
        `configuration "library" {`,
        `    dependency "sparkles:base" optional=true version="~>1.0"`,
        `    buildType "checked" platform="windows" {`,
        `        dflags "-g"`,
        `    }`,
        `}`,
        `configuration "unittest" {`,
        `    dependency "sparkles:test-runner" version="*"`,
        `}`,
        `dub:settings verbose=true`,
    ];

    size_t[size_t] starts;
    string recipe;
    foreach (index, piece; pieces)
    {
        starts[index] = recipe.length;
        recipe ~= piece;
        recipe ~= "\n";
    }

    auto parsed = parseSdlDocument!sdlDubRecipe(recipe, "recipe.sdl");
    assert(parsed.hasValue);
    auto root = parsed.document.root;

    SdlNode[5] nodes;
    size_t nodeCount;
    foreach (child; root.byChild)
        nodes[nodeCount++] = child;
    assert(nodeCount == nodes.length);

    assert(nodes[0].qualifiedName == SdlQualifiedName(null, "authors"));
    assert(nodes[1].qualifiedName.localName == "authors");
    assert(nodes[2].qualifiedName.localName == "configuration");
    assert(nodes[3].qualifiedName.localName == "configuration");
    assert(nodes[4].qualifiedName.namespace_ == "dub");
    assert(nodes[4].qualifiedName.localName == "settings");

    assert(nodes[0].valueCount == 1
        && nodes[0].byValue.front.stringValue == "Petar Kirov");
    assert(nodes[1].valueCount == 1
        && nodes[1].byValue.front.stringValue == "Ada Lovelace");

    auto config1 = nodes[2];
    assert(config1.valueCount == 1
        && config1.byValue.front.stringValue == "library");
    SdlNode[2] inner;
    size_t innerCount;
    foreach (child; config1.byChild)
        inner[innerCount++] = child;
    assert(innerCount == inner.length);

    auto dependency = inner[0];
    assert(dependency.qualifiedName.localName == "dependency");
    assert(dependency.valueCount == 1
        && dependency.byValue.front.stringValue == "sparkles:base");
    auto versions = dependency.byAttribute(SdlQualifiedName(null, "version"));
    assert(!versions.empty && versions.front.value.stringValue == "~>1.0");
    auto optionals = dependency.byAttribute(SdlQualifiedName(null, "optional"));
    assert(!optionals.empty && optionals.front.value.boolean);

    auto buildType = inner[1];
    assert(buildType.qualifiedName.localName == "buildType");
    assert(buildType.byValue.front.stringValue == "checked");
    auto platforms = buildType.byAttribute(SdlQualifiedName(null, "platform"));
    assert(!platforms.empty && platforms.front.value.stringValue == "windows");
    assert(buildType.childCount == 1);
    auto dflags = buildType.byChild.front;
    assert(dflags.qualifiedName.localName == "dflags");
    assert(dflags.byValue.front.stringValue == "-g");

    assert(nodes[3].byValue.front.stringValue == "unittest");
    auto dependency2 = nodes[3].byChild.front;
    assert(dependency2.byValue.front.stringValue == "sparkles:test-runner");
    auto versions2 = dependency2.byAttribute(SdlQualifiedName(null, "version"));
    assert(!versions2.empty && versions2.front.value.stringValue == "*");

    const settings = nodes[4];
    assert(settings.nameSpan.startOffset == starts[11]);
    assert(settings.nameSpan.endOffset == starts[11] + 12);
    assert(settings.span.endOffset == starts[11] + pieces[11].length + 1);
    foreach (attribute; settings.byAttribute)
    {
        assert(attribute.nameSpan.startOffset == starts[11] + 13);
        assert(attribute.nameSpan.endOffset == starts[11] + 20);
        assert(attribute.span.startOffset == starts[11] + 13);
        assert(attribute.span.endOffset == starts[11] + 25);
        assert(attribute.value.span.startOffset == starts[11] + 21);
        assert(attribute.value.span.endOffset == starts[11] + 25);
        assert(attribute.qualifiedName == SdlQualifiedName(null, "verbose"));
        assert(attribute.value.boolean);
    }

    assert(nodes[0].span.startOffset == starts[0]);
    assert(nodes[0].span.endOffset == starts[0] + pieces[0].length + 1);
    assert(nodes[0].byValue.front.span.startOffset == starts[0] + 8);
    assert(nodes[0].byValue.front.span.endOffset
        == starts[0] + pieces[0].length);
    assert(config1.span.endOffset == starts[7] + 2);
}

@("sdl.reader.maxDepthBoundarySpans")
@safe unittest
{
    enum depth2 = SdlParserConfig(
        scalars: sdlFull.scalars,
        syntax: sdlFull.syntax,
        maxDepth: 2,
    );

    auto accepted = parseSdlDocument!depth2("a {\nb {\nc\n}\n}\n");
    assert(accepted.hasValue);
    auto root = accepted.document.root;
    assert(root.childCount == 1);
    auto a = root.byChild.front;
    assert(a.childCount == 1);
    auto b = a.byChild.front;
    assert(b.qualifiedName.localName == "b");
    assert(b.childCount == 1);
    assert(b.byChild.front.qualifiedName.localName == "c");

    enum source = "a {\nb {\nc {\nd\n}\n}\n}\n";
    const rejected = parseSdlDocument!depth2(source);
    assert(rejected.hasError
        && rejected.error.code == SdlErrorCode.depthExceeded);
    assert(rejected.error.span.startOffset == 10);
    assert(rejected.error.span.endOffset == 11);
}

@("sdl.reader.extendedGrammarRejections")
@safe unittest
{
    enum unexpected = SdlErrorCode.unexpectedToken;

    const strayClose = parseSdlDocument!sdlFull("}\n");
    assert(strayClose.hasError && strayClose.error.code == unexpected);

    const missingBlockTerminator = parseSdlDocument!sdlFull("a {\nb {\n} }");
    assert(missingBlockTerminator.hasError
        && missingBlockTerminator.error.code == unexpected);

    const valueAfterAttribute = parseSdlDocument!sdlFull("a x=\"1\" 2\n");
    assert(valueAfterAttribute.hasError
        && valueAfterAttribute.error.code == unexpected);

    const identifierWithoutEquals = parseSdlDocument!sdlFull("a 1 b\n");
    assert(identifierWithoutEquals.hasError
        && identifierWithoutEquals.error.code == unexpected);

    const trailingGarbageAtEof = parseSdlDocument!sdlFull("a 1 zzz");
    assert(trailingGarbageAtEof.hasError
        && trailingGarbageAtEof.error.code == unexpected);

    const emptyBlock = parseSdlDocument!sdlFull("a {\n}");
    assert(emptyBlock.hasValue);
    assert(emptyBlock.document.root.childCount == 1);
    assert(emptyBlock.document.root.byChild.front.childCount == 0);

    const eofAfterOuterClose = parseSdlDocument!sdlFull("a {\nb\n}");
    assert(eofAfterOuterClose.hasValue);
    assert(eofAfterOuterClose.document.root.byChild.front.childCount == 1);

    enum noSemicolons = SdlParserConfig(
        scalars: sdlFull.scalars,
        syntax: SdlSyntaxFeatures(
            rawStrings: true,
            unicodeIdentifiers: true,
            unicodeWhitespace: true,
            unicodeNewlines: true,
            hashComments: true,
            slashComments: true,
            dashComments: true,
            blockComments: true,
            continuations: true,
            semicolonTerminators: false,
            anonymousTags: true,
        ),
    );
    const semicolon = parseSdlDocument!noSemicolons("a;\n");
    assert(semicolon.hasError
        && semicolon.error.code == SdlErrorCode.unsupportedFeature
        && semicolon.error.stage == SdlErrorStage.lex);
}

@("sdl.reader.multiByteDeterministicFuzzSmoke")
@safe unittest
{
    static void runProfile(SdlParserConfig config)(ref uint state)
    {
        char[96] bytes;
        foreach (_; 0 .. 512)
        {
            state = state * 1_664_525 + 1_013_904_223;
            const length = state % (bytes.length + 1);
            foreach (ref value; bytes[0 .. length])
            {
                state = state * 1_664_525 + 1_013_904_223;
                value = cast(char)(state >> 24);
            }
            if (length > 3)
            {
                bytes[state % length] = '{';
                bytes[(cast(size_t) state >> 9) % length] = '"';
                if (length > 8)
                    bytes[(cast(size_t) state >> 17) % length] = '}';
            }
            const parsed = parseSdlDocument!config(bytes[0 .. length], "fuzz");
            assert(parsed.hasValue || parsed.hasError);
            if (parsed.hasValue)
            {
                size_t budget = 1024;
                foreach (child; parsed.document.root.byChild)
                {
                    assert(budget-- > 0);
                    foreach (grandchild; child.byChild)
                        assert(budget-- > 0);
                }
            }
        }
    }

    uint state;
    runProfile!sdlFull(state = 0x1BAD_B002);
    runProfile!sdlDubCompat(state = 0xC0FF_EE42);
    runProfile!sdlDubRecipe(state = 0xD15E_A5E5);
    runProfile!(SdlParserConfig(
        scalars: sdlFull.scalars,
        syntax: sdlFull.syntax,
        validateUtf8: false,
    ))(state = 0x5DEE_CE66);
}

@("sdl.reader.validateSdlOutcomes")
@safe unittest
{
    enum noSemicolons = SdlParserConfig(
        scalars: sdlFull.scalars,
        syntax: SdlSyntaxFeatures(
            rawStrings: true,
            unicodeIdentifiers: true,
            unicodeWhitespace: true,
            unicodeNewlines: true,
            hashComments: true,
            slashComments: true,
            dashComments: true,
            blockComments: true,
            continuations: true,
            semicolonTerminators: false,
            anonymousTags: true,
        ),
    );
    enum flat = SdlParserConfig(
        scalars: sdlFull.scalars,
        syntax: sdlFull.syntax,
        maxDepth: 0,
    );

    assert(!validateSDL!sdlFull("a 1\nb;\n").hasError);
    assert(!validateSDL!sdlFull("").hasError);

    auto lex = validateSDL!sdlFull(`"open`);
    assert(lex.hasError && lex.error.stage == SdlErrorStage.lex
        && lex.error.code == SdlErrorCode.unterminatedString);

    auto parse = validateSDL!sdlFull("a {\nb\n");
    assert(parse.hasError && parse.error.stage == SdlErrorStage.parse
        && parse.error.code == SdlErrorCode.unexpectedEof);

    auto depth = validateSDL!flat("a {\n}\n");
    assert(depth.hasError && depth.error.code == SdlErrorCode.depthExceeded);

    auto feature = validateSDL!noSemicolons("a;\n");
    assert(feature.hasError
        && feature.error.code == SdlErrorCode.unsupportedFeature
        && feature.error.stage == SdlErrorStage.lex);

    auto decode = validateSDL!sdlFull("2147483648\n");
    assert(decode.hasError && decode.error.stage == SdlErrorStage.decode
        && decode.error.code == SdlErrorCode.numberOutOfRange);

    auto named = validateSDL!sdlFull("a {\nb\n", "named.sdl");
    assert(named.hasError && named.error.sourceName[] == "named.sdl");
}

@("sdl.reader.layout.extentFixtures")
@safe unittest
{
    import core.exception : AssertError;
    import sparkles.wired.sdl.embedded : parseEmbeddedSdlDocument;

    static struct Case { string source; string[] extents; } // preorder, root excluded
    static immutable Case[] cases = [
        Case("a 1\nb 2\n", ["a 1\n", "b 2\n"]),
        Case("a 1\r\n  b 2 # c\r\n", ["a 1\r\n", "  b 2 # c\r\n"]),
        Case("a 1\nb 2", ["a 1\n", "b 2"]),
        Case("\ta 1;\n", ["\ta 1;\n"]),
        Case("a 1; b 2\n", ["a 1; ", " b 2"]),
        Case("a {; b 1; }\n", ["a {; b 1; }\n", " b 1;"]),
        Case("x {\n\tb 1\n}\n", ["x {\n\tb 1\n}\n", "\tb 1\n"]),
        Case("# lead\na 1 /* t */\n", ["a 1 /* t */\n"]),
        Case("a 1 b 2", ["a 1 ", "b 2"]),
        Case("a 1\rb 2\r", ["a 1\r", "b 2\r"]),
        Case("\xEF\xBB\xBFa 1\n", ["a 1\n"]),
        Case("a {\n    b 1; c 2\n}\n", ["a {\n    b 1; c 2\n}\n", "b 1; ", " c 2"]),
        Case("a 1 \\\n    x=2\n", ["a 1 \\\n    x=2\n"]),
    ];
    foreach (test; cases)
    {
        auto parsed = parseSdlDocument!sdlFull(test.source);
        assert(parsed.hasValue, parsed.error.toString);
        const core = parsed.document.core;
        assert(core.nodes.length == test.extents.length + 1, test.source);
        foreach (i, expected; test.extents)
        {
            const actual = core.nodes[i + 1].extent.sliceOf(test.source);
            if (actual != expected)
                throw new AssertError(("extent of node " ~ (cast(char)('1' + i)) ~ " in "
                    ~ test.source ~ ": `" ~ actual ~ "`").idup);
        }
    }

    // An embedded recipe's extents stay inside it, short of the `+/`.
    const host = "/+ dub.sdl:\n    name \"x\" +/\nvoid main() {}\n";
    auto embedded = parseEmbeddedSdlDocument(host);
    assert(embedded.parsed.hasValue);
    assert(embedded.parsed.document.root.byChild.front.extent.sliceOf(host) == "    name \"x\" ");
}

@("sdl.reader.layout.commentsInSourceOrder")
@safe unittest
{
    enum source = "# one\na 1 // two\n/* three\n */ b -- four\nc \\ # five\n    x=1\n";
    auto parsed = parseSdlDocument!sdlFull(source);
    assert(parsed.hasValue, parsed.error.toString);
    static immutable string[] texts = ["# one", "// two", "/* three\n */", "-- four", "# five"];
    const comments = parsed.document.comments;
    assert(comments.length == texts.length);
    foreach (i, comment; comments)
    {
        assert(comment.span.sliceOf(source) == texts[i]);
        assert(comment.kind == (i == 2 ? SdlCommentKind.block : SdlCommentKind.line));
    }
}

@("sdl.reader.layout.positionsMatchTheScan")
@safe unittest
{
    import sparkles.wired.sdl.lexer : sdlScanPosition;

    static immutable string[] sources = [
        "a 1\nb 2", "\xEF\xBB\xBFa\r\nb\rc d e", "s `x\r\ny`\n\xC3\xA9 1 'é'\n",
        "a {\n\tb \"\\\n  c\"\n}\n", "", "\n\n\n", "a /*   */ 1\r\r\n",
    ];
    foreach (source; sources)
    {
        auto parsed = parseSdlDocument!sdlFull(source);
        assert(parsed.hasValue, parsed.error.toString);
        foreach (offset; 0 .. source.length + 1)
            assert(parsed.document.position(offset) == sdlScanPosition(source, offset), source);
    }
}

@("sdl.reader.ownsSourceAndRejectsHugeSpans")
@safe unittest
{
    char[8] text = "name 1\n\n";
    auto parsed = parseSdlDocument!sdlFull(text[]);
    text[] = 'x';
    assert(parsed.document.source == "name 1\n\n");
    assert(parsed.document.position(7) == SdlPosition(7, 2, 1));
    assert(parsed.document.position(8) == SdlPosition(8, 3, 1));
}
