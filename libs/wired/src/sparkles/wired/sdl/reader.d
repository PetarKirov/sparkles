/** Deterministic two-pass iterative SDL parser and ordered arena builder. */
module sparkles.wired.sdl.reader;

import std.experimental.allocator.common : stateSize;

import sparkles.base.buffer : SharedBuffer;
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
    const(char)[] opSlice() const return scope @trusted pure nothrow @nogc
        => (cast(const(char)*) target.ptr)[0 .. length];
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
    SdlError error;
    bool failed;

    this(return scope const(char)[] source,
        return scope const(char)[] sourceName)
    {
        lexer = lexSDL!config(source, sourceName);
        read();
    }

    void pop() scope
    {
        if (failed)
            return;
        lexer.popFront();
        read();
    }

    private void read() scope
    {
        if (lexer.empty)
            return;
        auto item = lexer.front;
        if (item.hasError)
        {
            error = (() @trusted => item.error)();
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

private SdlError copyError(SdlError source)
{
    SdlError result;
    result.stage = source.stage;
    result.code = source.code;
    result.sourceName ~= source.sourceName[];
    result.span = source.span;
    result.relatedSpan = source.relatedSpan;
    result.hasRelatedSpan = source.hasRelatedSpan;
    result.valuePath ~= source.valuePath[];
    result.rolePath ~= source.rolePath[];
    result.sourceType = source.sourceType;
    result.targetType = source.targetType;
    result.expectedKind = source.expectedKind;
    result.actualKind = source.actualKind;
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

private SdlSpan rootStartSpan(scope const(char)[] source)
    @safe pure nothrow @nogc
{
    const bom = source.length >= 3 && cast(ubyte) source[0] == 0xEF
        && cast(ubyte) source[1] == 0xBB && cast(ubyte) source[2] == 0xBF;
    const position = SdlPosition(bom ? 3 : 0, 1, 1);
    return SdlSpan(position, position);
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
        if (item.value.kind == SdlTokenKind.openBrace)
        {
            if (depth == targetDepth)
                result = item.value.span;
            depth++;
        }
        else if (item.value.kind == SdlTokenKind.closeBrace && depth)
            depth--;
        lexer.popFront();
    }
    return result;
}

private void parseInto(SdlParserConfig config, Allocator)(
    ref SdlParseResult!Allocator result, scope const(char)[] text,
    scope const(char)[] sourceName)
{
    ParseTotals totals;
    if (!checkedAdd(totals.poolBytes, sourceName.length))
    {
        result.error = parseError(SdlErrorCode.allocationFailed,
            rootStartSpan(text), sourceName, "SDL arena size overflows size_t");
        return;
    }

    SdlError failure;
    if (!runPass!(config, false)(text, sourceName, totals,
        result.document, failure))
    {
        ensureSourceName(failure, sourceName);
        result.error = failure;
        return;
    }

    if (!result.document.acquire(totals.nodes, totals.values,
        totals.attributes, totals.children, totals.poolBytes))
    {
        result.error = parseError(SdlErrorCode.allocationFailed,
            rootStartSpan(text), sourceName, "allocator rejected an SDL arena block");
        return;
    }

    ParseTotals filled;
    filled.poolBytes = 0;
    if (!runPass!(config, true)(text, sourceName, filled,
        result.document, failure))
    {
        result.document = SdlDocument!Allocator.init;
        ensureSourceName(failure, sourceName);
        result.error = failure;
        return;
    }
    finalizeChildren(result.document);
}

private bool runPass(SdlParserConfig config, bool fill, Allocator)(
    scope const(char)[] text, scope const(char)[] sourceName,
    ref ParseTotals totals, ref SdlDocument!Allocator document,
    ref SdlError failure)
{
    auto cursor = TokenCursor!config(text, sourceName);
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
    size_t poolAt;
    uint contextDepth;

    static if (fill)
    {
        const rootSpan = rootStartSpan(text);
        document.nodes[0] = SdlNodeCell(
            qualifiedName: SdlQualifiedName.init,
            nameSpan: rootSpan,
            span: rootSpan,
            depth: uint.max,
        );
        if (sourceName.length)
        {
            document.pool[0 .. sourceName.length] = cast(const(ubyte)[]) sourceName[];
            document.ownedSourceName = () @trusted {
                return (cast(const(char)*) document.pool.ptr)[0 .. sourceName.length];
            }();
            poolAt = sourceName.length;
        }
    }

    bool fail(SdlErrorCode code, SdlSpan span, string reason)
    {
        failure = parseError(code, span, sourceName, reason);
        return false;
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
            nameSpan.end = second.span.end;
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
            SdlPosition end = close.span.end;
            if (terminator(cursor.token.kind))
            {
                end = cursor.token.span.end;
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
                    if (document.nodes[owner].depth == contextDepth)
                    {
                        document.nodes[owner].span.end = end;
                        break;
                    }
                }
            }
            continue;
        }

        const tagStart = cursor.token.span.start;
        SdlQualifiedName tagName;
        SdlSpan tagNameSpan = SdlSpan(tagStart, tagStart);
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
            document.nodes[thisNode] = SdlNodeCell(
                qualifiedName: tagName,
                nameSpan: tagNameSpan,
                span: SdlSpan(tagStart, tagStart),
                valueStart: valueIndex,
                attributeStart: attributeIndex,
                depth: contextDepth,
            );
        else
        {
            if (!checkedAdd(totals.nodes, 1)
                || !checkedAdd(totals.children, 1))
                return fail(SdlErrorCode.allocationFailed, SdlSpan(tagStart, tagStart),
                    "SDL arena size overflows size_t");
        }

        size_t tagValues;
        while (scalarToken(cursor.token.kind))
        {
            SdlScalar scalar;
            if (!decodeValue(cursor.token, scalar))
                return false;
            static if (fill)
                document.values[valueIndex] = SdlValueCell(scalar);
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
                document.attributes[attributeIndex] = SdlAttributeCell(
                    attributeName, attributeNameSpan,
                    SdlSpan(attributeNameSpan.start, valueToken.span.end), scalar);
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
            document.nodes[thisNode].valueCount = tagValues;
            document.nodes[thisNode].attributeCount = tagAttributes;
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
                document.nodes[thisNode].hasBlock = true;
            continue;
        }

        SdlPosition tagEnd;
        if (terminator(cursor.token.kind))
        {
            tagEnd = cursor.token.span.end;
            cursor.pop();
            if (cursor.failed) { takeCursorError(); return false; }
        }
        else if (cursor.token.kind == SdlTokenKind.eof)
            tagEnd = cursor.token.span.end;
        else
            return fail(SdlErrorCode.unexpectedToken, cursor.token.span,
                "tag declaration requires a newline, semicolon, or document EOF");
        static if (fill)
            document.nodes[thisNode].span.end = tagEnd;
    }

    static if (fill)
    {
        assert(nodeIndex == document.nodes.length);
        assert(valueIndex == document.values.length);
        assert(attributeIndex == document.attributes.length);
        assert(poolAt == document.pool.length);
    }
    return true;
}

/** Links each node to its parent's contiguous child-index window.

Nodes are in source preorder, so a node's parent is the most recent node one
level shallower. Tracking that per level makes both passes linear; scanning
backwards for it instead costs O(n) per node, which is quadratic in the number
of siblings — the shape every flat document has.
*/
private void finalizeChildren(Allocator)(ref SdlDocument!Allocator document)
{
    if (document.nodes.length < 2)
        return;

    // Deepest node decides the ladder's height; the root sits below level 0.
    uint deepest;
    foreach (i; 1 .. document.nodes.length)
        if (document.nodes[i].depth != uint.max
            && document.nodes[i].depth > deepest)
            deepest = document.nodes[i].depth;

    auto lastAtDepth = SharedBuffer!(size_t, 32)();
    foreach (_; 0 .. cast(size_t) deepest + 1)
        lastAtDepth ~= 0;

    size_t parentOf(size_t i)
    {
        const depth = document.nodes[i].depth;
        return depth == 0 ? 0 : lastAtDepth[depth - 1];
    }

    foreach (i; 1 .. document.nodes.length)
    {
        document.nodes[parentOf(i)].childCount++;
        lastAtDepth[document.nodes[i].depth] = i;
    }

    size_t next;
    foreach (ref node; document.nodes)
    {
        node.childStart = next;
        next += node.childCount;
        node.childCount = 0;
    }

    foreach (ref slot; lastAtDepth[])
        slot = 0;
    foreach (i; 1 .. document.nodes.length)
    {
        const parent = parentOf(i);
        document.childIndexes[document.nodes[parent].childStart
            + document.nodes[parent].childCount++] = i;
        lastAtDepth[document.nodes[i].depth] = i;
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


    // Positive: every view/range/payload may be borrowed inside the scope'd
    // parameter's lifetime (views store arena slices, so dip1000 tracks the
    // full chain from the document down).
    static assert(__traits(compiles, (scope ref SdlDocument!() document) @safe {
        auto valid = document.valid;
    }));
    static assert(__traits(compiles, (scope ref SdlDocument!() document) @safe {
        auto name = document.sourceName;
    }));
    static assert(__traits(compiles, (scope ref SdlDocument!() document) @safe {
        return document.root.childCount;
    }));
    static void borrowEverything(scope ref SdlDocument!() d) @safe
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
            (scope ref SdlDocument!() document) @safe {
                borrowEverything(document);
            }));
    }
    static assert(__traits(compiles, (scope ref SdlDocument!() document) @safe {
        auto values = document.root.byValue;
        size_t total;
        foreach (value; values)
            total += value.kind == SdlScalarKind.none;
    }));
    static assert(__traits(compiles, (scope ref SdlDocument!() document) @safe {
        auto children = document.root.byChild;
        size_t total;
        foreach (child; children)
            total += child.valueCount;
    }));
    static assert(__traits(compiles, (scope ref SdlDocument!() document) @safe {
        auto filteredAttributes =
            document.root.byAttribute(SdlQualifiedName(null, "x"));
    }));
    static assert(__traits(compiles, (scope ref SdlDocument!() document) @safe {
        auto filteredChildren =
            document.root.byChild(SdlNameQuery.anyNamespace("x"));
    }));
    static assert(__traits(compiles, (scope ref SdlDocument!() document) @safe {
        auto values = document.root.byValue;
        size_t total;
        foreach (value; values)
            total += value.kind == SdlScalarKind.none;
    }));
    static assert(__traits(compiles, (scope ref SdlDocument!() document) @safe {
        auto children = document.root.byChild;
        size_t total;
        foreach (child; children)
            total += child.valueCount;
    }));
    static assert(__traits(compiles, (scope ref SdlDocument!() document) @safe {
        auto attributes = document.root.byAttribute;
    }));
    static assert(__traits(compiles, (scope ref SdlDocument!() document) @safe {
        auto filteredAttributes =
            document.root.byAttribute(SdlQualifiedName(null, "x"));
    }));
    static assert(__traits(compiles, (scope ref SdlDocument!() document) @safe {
        auto filteredChildren =
            document.root.byChild(SdlNameQuery.anyNamespace("x"));
    }));

    // Negative: nothing borrowed from the scope'd document may outlive it.
    // Aggregate views are copyable cursors whose handles themselves are not
    // re-tracked across a function return boundary by either backend, so each
    // probe binds the borrowed view to a local (which dip1000 marks scope)
    // and returns its slice-bearing payload — the bytes that must not
    // outlive the parameter.
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
    assert(root.span.start.byteOffset == 3 && root.span.end.byteOffset == 3);
    auto parent = root.byChild.front;
    assert(parent.nameSpan.start.byteOffset == 3
        && parent.nameSpan.end.byteOffset == 4);
    assert(parent.span.start.byteOffset == 3
        && parent.span.end.byteOffset == source.length);
    auto value = parent.byValue.front;
    assert(value.span.start.byteOffset == 5 && value.span.end.byteOffset == 8);
    auto attribute = parent.byAttribute.front;
    assert(attribute.nameSpan.start.byteOffset == 9
        && attribute.nameSpan.end.byteOffset == 10);
    assert(attribute.span.start.byteOffset == 9
        && attribute.span.end.byteOffset == 15);
    auto child = parent.byChild.front;
    assert(child.span.start.byteOffset == 19 && child.span.end.byteOffset == 21);

    auto eof = parseSdlDocument!sdlFull("tag");
    assert(eof.hasValue && eof.document.root.byChild.front.span.end.byteOffset == 3);
    auto missing = parseSdlDocument!sdlFull("outer {\ninner {\n}\n");
    assert(missing.hasError && missing.error.code == SdlErrorCode.unexpectedEof);
    assert(missing.error.hasRelatedSpan
        && missing.error.relatedSpan.start.byteOffset == 6);
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

        void[] allocate(size_t amount) @trusted nothrow @nogc
        {
            const attempt = (*attempts)++;
            if (attempt == failAt)
                return null;
            auto block = Mallocator.instance.allocate(amount);
            if (block !is null)
                (*liveBlocks)++;
            return block;
        }

        bool deallocate(void[] block) @trusted nothrow @nogc
        {
            if (block is null)
                return true;
            (*liveBlocks)--;
            return Mallocator.instance.deallocate(block);
        }
    }

    enum source = "a [TQ==] x=\"v\" {\nb\n}\n";
    {
        size_t attempts;
        size_t liveBlocks;
        auto empty = parseSdlDocument!sdlFull("", null,
            FailingAllocator(size_t.max, &attempts, &liveBlocks));
        assert(empty.hasValue && attempts == 1 && liveBlocks == 1);
    }
    foreach (failAt; 0 .. 5)
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
        assert(parsed.hasValue && attempts == 5 && liveBlocks == 5);
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
@safe unittest
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

    SdlNode[] nodes;
    foreach (child; root.byChild)
        nodes ~= child;
    assert(nodes.length == 5);

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
    SdlNode[] inner;
    foreach (child; config1.byChild)
        inner ~= child;
    assert(inner.length == 2);

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
    assert(settings.nameSpan.start.byteOffset == starts[11]);
    assert(settings.nameSpan.end.byteOffset == starts[11] + 12);
    assert(settings.span.end.byteOffset == starts[11] + pieces[11].length + 1);
    foreach (attribute; settings.byAttribute)
    {
        assert(attribute.nameSpan.start.byteOffset == starts[11] + 13);
        assert(attribute.nameSpan.end.byteOffset == starts[11] + 20);
        assert(attribute.span.start.byteOffset == starts[11] + 13);
        assert(attribute.span.end.byteOffset == starts[11] + 25);
        assert(attribute.value.span.start.byteOffset == starts[11] + 21);
        assert(attribute.value.span.end.byteOffset == starts[11] + 25);
        assert(attribute.qualifiedName == SdlQualifiedName(null, "verbose"));
        assert(attribute.value.boolean);
    }

    assert(nodes[0].span.start.byteOffset == starts[0]);
    assert(nodes[0].span.end.byteOffset == starts[0] + pieces[0].length + 1);
    assert(nodes[0].byValue.front.span.start.byteOffset == starts[0] + 8);
    assert(nodes[0].byValue.front.span.end.byteOffset
        == starts[0] + pieces[0].length);
    assert(config1.span.end.byteOffset == starts[7] + 2);
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
    assert(rejected.error.span.start.byteOffset == 10);
    assert(rejected.error.span.end.byteOffset == 11);
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
