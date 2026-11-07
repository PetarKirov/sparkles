/** Deterministic one-pass iterative SDL parser and ordered arena builder. */
module sparkles.wired.sdl.reader;

import std.experimental.allocator.common : stateSize;

import sparkles.base.text.errors : valueOf;
import sparkles.base.buffer : SharedBuffer, UniqueBuffer;
import sparkles.base.text.edits : TextEdit;
import sparkles.base.text.lineindex : LineIndex;
import std.experimental.allocator.mallocator : Mallocator;

import sparkles.wired.sdl.config;
import sparkles.wired.sdl.document;
import sparkles.wired.sdl.error;
import sparkles.wired.sdl.lexer;

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
        return scope const(char)[] sourceName, SdlLexerLayout* layout, size_t start = 0)
    {
        lexer = lexSDL!config(source, sourceName);
        lexer._layout = layout;
        if (start)
            lexer.startAt(start);
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
    if (!content.isValid)
        content = SdlSpan(contentStart(text), text.length);

    // One pool, sized before lexing (SDP4): the source name, the source copy,
    // and room for every decoded payload, which never exceeds the source.
    size_t poolBytes = sourceName.length;
    if (!checkedAdd(poolBytes, text.length) || !checkedAdd(poolBytes, text.length))
    {
        result.error = startError(SdlErrorCode.allocationFailed, text, sourceName,
            "SDL arena size overflows size_t");
        return;
    }
    // Cheap first capacities; the arrays double when a document outgrows them.
    const guess = text.length / 32 + 8;
    if (!result.document.acquire(guess, guess, guess / 2, poolBytes))
    {
        result.error = startError(SdlErrorCode.allocationFailed, text, sourceName,
            "allocator rejected an SDL arena block");
        return;
    }

    // The document owns its source: the copy follows the source name in the
    // pool, and the pass lexes the copy.
    auto core = result.document.core;
    auto pool = result.document.pool;
    pool[sourceName.length .. sourceName.length + text.length] = cast(const(ubyte)[]) text[];
    core.source = () @trusted {
        return (cast(const(char)*) pool.ptr + sourceName.length)[0 .. text.length];
    }();
    core.content = content;

    SdlError failure;
    PassCounts counts;
    SdlLexerLayout layout;
    layout.recordLines = true;
    if (!runPass!config(core.source, sourceName, content, counts, result.document,
        layout, failure))
    {
        result.document = SdlDocument!Allocator.init;
        ensureSourceName(failure, sourceName);
        result.error = failure;
        return;
    }
    if (!result.document.finish(counts.nodes, counts.values, counts.attributes,
        layout.comments[], LineIndex(layout.lineStarts[], text.length, contentStart(text))))
    {
        result.document = SdlDocument!Allocator.init;
        result.error = startError(SdlErrorCode.allocationFailed, text, sourceName,
            "allocator rejected an SDL arena block");
    }
}

/** Re-parses `text` — `old`'s source after `edits`, which are sorted and
valid — re-lexing only the region editing §10 names and sharing `old`'s
cells before and after it with the new document (SDE14, editing §10.1).
Whenever the region cannot be localized it parses all of `text` instead
(SDE15), so the result and any error are a full parse's; `localized` reports
which path ran. No edits over `old`'s own text and content share all of `old`
without lexing a byte. `content` is the new content, or invalid for the
source after any byte-order mark. */
package SdlParseResult!Allocator reparseEdited(SdlParserConfig config, Allocator = Mallocator)(
    scope const(SdlCore)* old, scope const(char)[] text, scope const(char)[] sourceName,
    SdlSpan content, scope const TextEdit[] edits, out bool localized)
if (stateSize!Allocator == 0)
{
    SdlParseResult!Allocator result;
    UniqueBuffer!char none;
    reparseInto!config(result, old, text, none, sourceName, content, edits, localized);
    return result;
}

/// ditto; a stateful allocator is retained by the returned document, and
/// serves the region path and the fallback alike.
package SdlParseResult!Allocator reparseEdited(SdlParserConfig config, Allocator)(
    scope const(SdlCore)* old, scope const(char)[] text, scope const(char)[] sourceName,
    SdlSpan content, scope const TextEdit[] edits, out bool localized, Allocator alloc)
if (stateSize!Allocator != 0)
{
    import core.lifetime : move;

    SdlParseResult!Allocator result;
    result.document.alloc = move(alloc);
    UniqueBuffer!char none;
    reparseInto!config(result, old, text, none, sourceName, content, edits, localized);
    return result;
}

/** ditto, over text the caller hands over: a localized result keeps `text`
as its source instead of copying it, and leaves it empty (performance SDP8),
unless it is short enough to sit inline in the buffer; a full parse copies it
and leaves it as it was. */
package SdlParseResult!Allocator reparseEdited(SdlParserConfig config, Allocator = Mallocator)(
    scope const(SdlCore)* old, ref UniqueBuffer!char text, scope const(char)[] sourceName,
    SdlSpan content, scope const TextEdit[] edits, out bool localized)
if (stateSize!Allocator == 0)
{
    SdlParseResult!Allocator result;
    reparseInto!config(result, old, (() @trusted => text[])(), text, sourceName, content,
        edits, localized);
    return result;
}

/// ditto, through a stateful allocator.
package SdlParseResult!Allocator reparseEdited(SdlParserConfig config, Allocator)(
    scope const(SdlCore)* old, ref UniqueBuffer!char text, scope const(char)[] sourceName,
    SdlSpan content, scope const TextEdit[] edits, out bool localized, Allocator alloc)
if (stateSize!Allocator != 0)
{
    import core.lifetime : move;

    SdlParseResult!Allocator result;
    result.document.alloc = move(alloc);
    reparseInto!config(result, old, (() @trusted => text[])(), text, sourceName, content,
        edits, localized);
    return result;
}

private void reparseInto(SdlParserConfig config, Allocator)(
    ref SdlParseResult!Allocator result, scope const(SdlCore)* old,
    scope const(char)[] text, ref UniqueBuffer!char adopted, scope const(char)[] sourceName,
    SdlSpan content, scope const TextEdit[] edits, out bool localized)
{
    if (text.length < uint.max && !content.isValid)
        content = SdlSpan(contentStart(text), text.length);
    if (old !is null
        && spliceRegion!config(result, old, text, adopted, sourceName, content, edits))
    {
        localized = true;
        return;
    }
    // The failed splice's arenas go; the document's allocator stays.
    result.document.reset();
    parseInto!config(result, text, sourceName, content);
}

/// Whether a line starts at `at` in `text`: just after a logical newline,
/// or at `lineZero`.
private bool atLineStart(scope const(char)[] text, size_t at, size_t lineZero)
    @safe pure nothrow @nogc
{
    if (at == lineZero)
        return true;
    if (at == 0 || at > text.length)
        return false;
    const c = text[at - 1];
    if (c == '\n' || c == '\r')
        return true;
    return at >= 3 && cast(ubyte) text[at - 3] == 0xE2 && cast(ubyte) text[at - 2] == 0x80
        && (cast(ubyte) c == 0xA8 || cast(ubyte) c == 0xA9);
}

/// Whether only spaces and tabs come between the start of `at`'s line and
/// `at`, the line starting at or after `floor`.
private bool onlyIndentBefore(scope const(char)[] text, size_t at, size_t floor,
    size_t lineZero) @safe pure nothrow @nogc
{
    while (at > floor && (text[at - 1] == ' ' || text[at - 1] == '\t'))
        at--;
    return at >= floor && atLineStart(text, at, lineZero);
}

/// The region a splice re-lexes (editing §10), in old and new offsets.
private struct SpliceBounds
{
    long delta;          // the edits' length change
    size_t owner;        // the node whose interior holds the region
    bool afterOpener;    // the region starts right after the owner's `{`
    size_t regionStart;  // the same in the old text and the new
    size_t a, b;         // the old cells `[a, b)` the region replaces
    size_t replaced;     // how many of `owner`'s children `[a, b)` holds
    bool endsContent;    // the region runs to the end of the content
    size_t oldLexEnd;    // where lexing the region stops, in the old text
    size_t newRegionEnd; // the region's end in the new text
    size_t newLexEnd;    // `oldLexEnd` in the new text
    bool relex = true;   // `false` when there are no edits: every cell is kept
    UniqueBuffer!(size_t, 16) chain; // the root, ..., `owner`: the region's ancestors
}

/** Steps 1–3 of editing §10: the region `edits` re-lex, or `false` when it
cannot be localized (SDE15). No edits over `old`'s own text make a region
that is empty and keeps every cell. */
private bool locateRegion(SdlParserConfig config)(ref SpliceBounds bounds,
    scope const(SdlCore)* old, scope const(char)[] text, SdlSpan content,
    scope const TextEdit[] edits)
{
    const oldText = old.source;
    const n = old.nodeCount;
    if (text.length >= uint.max || oldText.length == 0 || n == 0)
        return false;
    const long delta = cast(long) text.length - cast(long) oldText.length;
    const oldContent = old.content;
    const lineZero = contentStart(text);
    if (content.startOffset != oldContent.startOffset || lineZero != contentStart(oldText)
        || cast(long) content.endOffset != oldContent.endOffset + delta)
        return false;
    if (edits.length == 0)
    {
        if (text != oldText)
            return false;
        // An empty region at the end: every cell before it is kept.
        bounds.regionStart = bounds.oldLexEnd = bounds.newRegionEnd = bounds.newLexEnd
            = text.length;
        bounds.a = bounds.b = n;
        bounds.endsContent = true;
        bounds.chain ~= 0;
        bounds.relex = false;
        return true;
    }
    const minStart = edits[0].range.startOffset;
    size_t maxEnd;
    foreach (ref e; edits)
        if (e.range.endOffset > maxEnd)
            maxEnd = e.range.endOffset;

    // 1. The deepest block whose interior holds every edit and whose `}`
    // starts its line.
    size_t owner;
    size_t interiorStart = oldContent.startOffset, interiorEnd = oldContent.endOffset;
    bounds.chain ~= 0;
    descend: while (true)
    {
        const cell = old.nodeAt(owner);
        size_t c = owner + 1;
        foreach (k; 0 .. cell.childCount)
        {
            const child = old.nodeAt(c);
            if (child.span.startOffset > maxEnd)
                break;
            if (child.hasBlock && child.openBrace.endOffset <= minStart
                && maxEnd <= child.closeBrace.startOffset
                && onlyIndentBefore(oldText, child.closeBrace.startOffset,
                    child.openBrace.endOffset, lineZero))
            {
                owner = c;
                bounds.chain ~= c;
                interiorStart = child.openBrace.endOffset;
                interiorEnd = child.closeBrace.startOffset;
                continue descend;
            }
            c += child.subtreeSize;
        }
        break;
    }

    // 2. The affected children, widened to children alone on their lines:
    // `lo` the last child before them alone on its lines, `hi` the first one
    // after them that is, by their positions among `owner`'s children.
    const ownerCell = old.nodeAt(owner);
    const ownerEnd = owner + ownerCell.subtreeSize;
    const childCount = ownerCell.childCount;
    size_t k, c = owner + 1;
    ptrdiff_t lo = -1;
    size_t afterLo = owner + 1; // the cell of child `lo + 1`
    size_t loEnd = interiorStart;
    while (k < childCount)
    {
        const child = old.nodeAt(c);
        if (child.extent.endOffset >= minStart)
            break;
        c += child.subtreeSize;
        k++;
        if (child.aloneOnLines)
        {
            lo = k - 1;
            afterLo = c;
            loEnd = child.extent.endOffset;
        }
    }
    while (k < childCount && old.nodeAt(c).extent.startOffset <= maxEnd)
    {
        c += old.subtreeSizeAt(c);
        k++;
    }
    while (k < childCount && !old.nodeAt(c).aloneOnLines)
    {
        c += old.subtreeSizeAt(c);
        k++;
    }
    // `c` is now child `k`'s cell, or `ownerEnd` past the last child.
    const size_t regionStart = loEnd;
    const size_t regionEnd = k < childCount ? old.nodeAt(c).extent.startOffset : interiorEnd;
    if (regionStart >= regionEnd || regionStart > minStart || maxEnd > regionEnd
        || cast(long) regionEnd + delta < cast(long) regionStart)
        return false;
    const a = afterLo;
    const b = k < childCount ? c : ownerEnd;

    // 3. The region's new text must still start and end at line boundaries.
    const endsContent = regionEnd == oldContent.endOffset;
    const size_t oldLexEnd = endsContent ? oldText.length : regionEnd;
    const size_t newRegionEnd = cast(size_t)(regionEnd + delta);
    const size_t newLexEnd = cast(size_t)(oldLexEnd + delta);
    if (regionStart && oldText[regionStart - 1] == '\r' && newRegionEnd > regionStart
        && text[regionStart] == '\n')
        return false;
    if (!endsContent)
    {
        if (newRegionEnd == regionStart ? !atLineStart(text, regionStart, lineZero)
            : !onlyIndentBefore(text, newRegionEnd, regionStart + 1, lineZero))
            return false;
    }
    static if (config.validateUtf8)
    {
        import sparkles.base.text.utf8 : indexOfInvalidUtf8;

        if (regionStart && indexOfInvalidUtf8(text[regionStart .. newLexEnd])
            != newLexEnd - regionStart)
            return false;
    }
    bounds.delta = delta;
    bounds.owner = owner;
    bounds.afterOpener = owner && lo < 0;
    bounds.regionStart = regionStart;
    bounds.a = a;
    bounds.b = b;
    bounds.replaced = k - cast(size_t)(lo + 1);
    bounds.endsContent = endsContent;
    bounds.oldLexEnd = oldLexEnd;
    bounds.newRegionEnd = newRegionEnd;
    bounds.newLexEnd = newLexEnd;
    return true;
}

/// Shared pieces shorter than this are copied into the new block, so runs
/// stay at least this long (editing §10.1).
private enum size_t absorbBelow = 16;

/// A range `[from, to)` of an old document's logical cells, inside one of its
/// runs, which the new document copies or shares.
private struct Piece
{
    size_t from, to;
    bool copy;
    bool tail; // after the region: shifted by the edits' length change
}

/// The bytes `name` takes in a pool.
private size_t spelling(scope const SdlQualifiedName name) @safe pure nothrow @nogc
    => name.namespace_.length + name.localName.length;

/// Appends `[from, to)` of `runs`' logical cells to `pieces`, one piece per

/// run it crosses, each copied when shorter than `absorbBelow` or `copy`.
private void addPieces(ref UniqueBuffer!Piece pieces, scope const(SdlRun)[] runs,
    size_t from, size_t to, bool tail, bool copy = false) @safe pure nothrow @nogc
{
    while (from < to)
    {
        const run = runs[runOf!"base"(runs, from)];
        const runEnd = run.base + (run.hi - run.lo);
        const end = to < runEnd ? to : runEnd;
        pieces ~= Piece(from, end, copy || end - from < absorbBelow, tail);
        from = end;
    }
}

/// The first of `count` logical items that `keep` rejects, `keep` holding
/// for a prefix.
private size_t prefixLength(alias keep)(size_t count)
{
    size_t lo = 0, hi = count;
    while (lo < hi)
    {
        const mid = lo + (hi - lo) / 2;
        if (keep(mid))
            lo = mid + 1;
        else
            hi = mid;
    }
    return lo;
}

/** Splices the region's own comments or line starts between `old`'s before
it (`[0, head)`) and after it (`[tail, count)`, shifted by `delta`): pieces
shorter than `absorbBelow` are copied, by `item`, into `copies`, after the
region's own ones, and the rest are shared; appends the runs to `runs`. */
private void spliceItems(T, alias item)(scope const(SdlRun)[] oldRuns, size_t count,
    size_t head, size_t tail, uint delta, scope const(T)[] region,
    ref UniqueBuffer!T copies, ref UniqueBuffer!SdlRun runs, bool copyAll)
{
    size_t logical;
    void addCopies(scope const(T)[] items)
    {
        if (items.length == 0)
            return;
        const at = copies.length;
        foreach (ref x; items)
            copies ~= x;
        if (runs.length && runs[$ - 1].block is null && runs[$ - 1].hi == at)
            runs[$ - 1].hi += cast(uint) items.length;
        else
            runs ~= SdlRun(null, cast(uint) at, cast(uint)(at + items.length), cast(uint) logical);
        logical += items.length;
    }
    void addOld(size_t from, size_t to, bool shifted)
    {
        UniqueBuffer!Piece pieces;
        addPieces(pieces, oldRuns, from, to, shifted, copyAll);
        foreach (piece; pieces[])
        {
            if (piece.copy)
            {
                foreach (i; piece.from .. piece.to)
                {
                    T x = item(i, shifted);
                    addCopies((() @trusted => (&x)[0 .. 1])());
                }
                continue;
            }
            const run = oldRuns[runOf!"base"(oldRuns, piece.from)];
            const lo = run.lo + (piece.from - run.base);
            runs ~= SdlRun(run.block, cast(uint) lo, cast(uint)(lo + piece.to - piece.from),
                cast(uint) logical, run.delta + (shifted ? delta : 0));
            logical += piece.to - piece.from;
        }
    }
    addOld(0, head, false);
    addCopies(region);
    addOld(tail, count, true);
}

/** The region path of `reparseEdited`: fills `result` and returns `true`, or
returns `false`, leaving `result` to be discarded, when the edits cannot be
localized (editing §10, SDE15) or sharing would hold too much (§10.1). */
private bool spliceRegion(SdlParserConfig config, Allocator)(
    ref SdlParseResult!Allocator result, scope const(SdlCore)* old,
    scope const(char)[] text, ref UniqueBuffer!char adopted,
    scope const(char)[] sourceName, SdlSpan content, scope const TextEdit[] edits)
{
    // Only blocks this document can free may be shared (§10.1); a document
    // of another allocator type has its kept cells copied instead.
    if (old.blocks.length == 0)
        return false;
    bool share = true;
    foreach (block; old.blocks)
        share &= SdlDocument!Allocator.canHold(block);
    // A full parse, which makes a flat document again, once the old one's
    // blocks hold more than twice what a full parse of the text would: its
    // pool, and cell arrays that grow by doubling. The rule reads only the
    // old document, so every allocator takes the same path (SDE16).
    const cells = old.nodeCount * SdlNodeCell.sizeof + old.valueCount * SdlValueCell.sizeof
        + old.attributeCount * SdlAttributeCell.sizeof + old.commentCount * SdlComment.sizeof
        + old.lineCount * size_t.sizeof;
    if (SdlDocument!Allocator.heldBytes(old.blocks)
        > 2 * (2 * text.length + sourceName.length + 2 * cells))
        return false;

    SpliceBounds bounds;
    if (!locateRegion!config(bounds, old, text, content, edits))
        return false;
    SdlRun[3] scratch;
    const(SdlRun)[] oldNodes, oldComments, oldLines;
    () @trusted { old.runsInto(scratch, oldNodes, oldComments, oldLines); }();
    auto document = &result.document;
    const lineZero = contentStart(text);

    // No edits: every cell is shared as it is (SDE17).
    if (!bounds.relex && share)
        return document.finishShared(0, 0, 0, null, null, oldNodes, oldComments, oldLines,
            old.blocks, text, sourceName, adopted, content, lineZero);

    const uint delta = cast(uint) bounds.delta; // modulo 2³², as runs add it
    const regionStart = bounds.regionStart;
    const a = bounds.a, b = bounds.b;
    const n = old.nodeCount;
    const endsContent = bounds.endsContent;
    const oldLexEnd = bounds.oldLexEnd, newRegionEnd = bounds.newRegionEnd;
    const newLexEnd = bounds.newLexEnd;

    // 4. What the new block copies: the region's ancestors, and every short
    // piece before and after it; the rest is shared.
    UniqueBuffer!Piece pieces;
    size_t next;
    foreach (ancestor; bounds.chain[])
    {
        addPieces(pieces, oldNodes, next, ancestor, false, !share);
        addPieces(pieces, oldNodes, ancestor, ancestor + 1, false, true);
        next = ancestor + 1;
    }
    addPieces(pieces, oldNodes, next, a, false, !share);
    const regionPiece = pieces.length;
    addPieces(pieces, oldNodes, b, n, true, !share);

    size_t copiedNodes, copiedValues, copiedAttributes, headPool, tailPool;
    foreach (k, piece; pieces[])
        if (piece.copy)
            foreach (i; piece.from .. piece.to)
            {
                const cell = old.nodeAt(i);
                copiedNodes++;
                copiedValues += cell.valueCount;
                copiedAttributes += cell.attributeCount;
                size_t bytes = spelling(cell.qualifiedName);
                foreach (v; 0 .. cell.valueCount)
                    bytes += old.valueAt(cell.valueStart + v).value.borrowedBytes.length;
                foreach (t; 0 .. cell.attributeCount)
                {
                    const attribute = old.attributeAt(cell.attributeStart + t);
                    bytes += spelling(attribute.qualifiedName)
                        + attribute.value.borrowedBytes.length;
                }
                (k < regionPiece ? headPool : tailPool) += bytes;
            }

    // The new block's pool holds every name and payload its cells have
    // (§10.1): the copies', then the region's payloads and its names, each
    // no longer than the region's text.
    size_t poolBytes = headPool;
    if (!checkedAdd(poolBytes, tailPool) || !checkedAdd(poolBytes, newLexEnd - regionStart)
        || !checkedAdd(poolBytes, newLexEnd - regionStart))
        return false;
    const guess = (newRegionEnd - regionStart) / 32 + 8;
    if (!document.acquire(copiedNodes + guess, copiedValues + guess,
        copiedAttributes + guess / 2, poolBytes))
        return false;
    auto core = document.core;
    auto pool = document.pool;
    // The pass reads names from the text it lexes; a shared core spells them
    // from its own source (§10.1), which `finishShared` sets.
    () @trusted { core.source = text; }();

    // Offsets up to the region's start stay; offsets after it shift. No
    // kept offset lies strictly inside the region.
    uint shift(uint offset) => offset <= regionStart ? offset : offset + delta;
    SdlSpan shifted(SdlSpan span)
        => span.isValid ? SdlSpan(shift(span.startOffset), shift(span.endOffset)) : span;
    size_t poolAt;
    SdlQualifiedName pooled(SdlQualifiedName name)
    {
        const(char)[] put(scope const(char)[] text)
        {
            pool[poolAt .. poolAt + text.length] = cast(const(ubyte)[]) text[];
            const at = poolAt;
            poolAt += text.length;
            return (() @trusted => (cast(const(char)*) pool.ptr + at)[0 .. text.length])();
        }
        return SdlQualifiedName(put(name.namespace_), put(name.localName));
    }
    SdlScalar rebased(SdlScalar scalar)
    {
        scalar.setSpan(shifted(scalar.span));
        const bytes = scalar.borrowedBytes;
        pool[poolAt .. poolAt + bytes.length] = bytes[];
        scalar.rebind(pool[poolAt .. poolAt + bytes.length]);
        poolAt += bytes.length;
        return scalar;
    }
    PassCounts counts;
    counts.nodes = 0;
    void copyNode(size_t from)
    {
        SdlNodeCell cell = old.nodeAt(from);
        cell.nameSpan = shifted(cell.nameSpan);
        cell.span = shifted(cell.span);
        cell.extent = shifted(cell.extent);
        cell.openBrace = shifted(cell.openBrace);
        cell.closeBrace = shifted(cell.closeBrace);
        cell.terminator = shifted(cell.terminator);
        cell.qualifiedName = pooled(cell.qualifiedName);
        foreach (v; 0 .. cell.valueCount)
            core.flatValues[counts.values + v]
                = SdlValueCell(rebased(old.valueAt(cell.valueStart + v).value));
        foreach (t; 0 .. cell.attributeCount)
        {
            SdlAttributeCell attribute = old.attributeAt(cell.attributeStart + t);
            attribute.nameSpan = shifted(attribute.nameSpan);
            attribute.span = shifted(attribute.span);
            attribute.qualifiedName = pooled(attribute.qualifiedName);
            attribute.value = rebased(attribute.value);
            core.flatAttributes[counts.attributes + t] = attribute;
        }
        cell.valueStart = counts.values;
        cell.attributeStart = counts.attributes;
        counts.values += cell.valueCount;
        counts.attributes += cell.attributeCount;
        core.flatNodes[counts.nodes++] = cell;
    }

    // 5. The copies before the region, the region's cells, then the copies
    // after it. The ancestors' child counts and subtree sizes change.
    UniqueBuffer!(size_t, 16) ancestorSlots;
    size_t ownerSlot;
    foreach (piece; pieces[0 .. regionPiece])
        if (piece.copy)
            foreach (i; piece.from .. piece.to)
            {
                const slot = counts.nodes;
                copyNode(i);
                if (ancestorSlots.length < bounds.chain.length
                    && i == bounds.chain[ancestorSlots.length])
                {
                    ancestorSlots ~= slot;
                    if (i == bounds.owner)
                    {
                        ownerSlot = slot;
                        core.flatNodes[slot].childCount -= bounds.replaced;
                    }
                }
            }
    assert(ancestorSlots.length == bounds.chain.length, "an ancestor was not copied");
    const regionFirst = counts.nodes;
    const regionAttributes = counts.attributes;

    poolAt = headPool + tailPool;
    counts.poolEnd = poolAt;
    SdlLexerLayout layout;
    layout.recordLines = true;
    PassRegion region;
    region.active = true;
    region.start = regionStart;
    region.baseDepth = bounds.owner ? old.nodeAt(bounds.owner).depth + 1 : 0;
    region.poolAt = poolAt;
    region.afterOpener = bounds.afterOpener;
    region.parent = ownerSlot;
    SdlError failure;
    if (bounds.relex && !runPass!config(text[0 .. newLexEnd], sourceName,

        SdlSpan(regionStart, endsContent ? content.endOffset : newRegionEnd), counts,
        *document, layout, failure, region))
        return false;
    if (!endsContent)
    {
        // Only the end of the input may end a node without a terminator.
        foreach (k; regionFirst .. counts.nodes)
            if (core.flatNodes[k].terminator.length == 0)
                return false;
        // The region must end with a newline token, not a continuation's
        // newline, then indentation: what the next node's line start was.
        size_t tail = counts.hasLast ? counts.lastEnd : regionStart;
        if (counts.hasLast && counts.lastKind != SdlTokenKind.newline)
            return false;
        while (tail < newRegionEnd && (text[tail] == ' ' || text[tail] == '\t'))
            tail++;
        if (tail != newRegionEnd)
            return false;
    }
    // The region's names slice the text the caller lent; its block keeps
    // copies, after the region's payloads.
    poolAt = counts.poolEnd;
    foreach (k; regionFirst .. counts.nodes)
        core.flatNodes[k].qualifiedName = pooled(core.flatNodes[k].qualifiedName);
    foreach (k; regionAttributes .. counts.attributes)
        core.flatAttributes[k].qualifiedName = pooled(core.flatAttributes[k].qualifiedName);
    const regionNodes = counts.nodes - regionFirst;
    foreach (slot; ancestorSlots[])
        core.flatNodes[slot].subtreeSize += regionNodes - (b - a);
    const regionPool = poolAt;


    size_t tailNodes, tailValues, tailAttributes;
    foreach (piece; pieces[regionPiece .. $])
        if (piece.copy)
            foreach (i; piece.from .. piece.to)
            {
                const cell = old.nodeAt(i);
                tailNodes++;
                tailValues += cell.valueCount;
                tailAttributes += cell.attributeCount;
            }
    while (core.flatNodes.length < counts.nodes + tailNodes)
        if (!document.grow!"nodes"(counts.nodes))
            return false;
    while (core.flatValues.length < counts.values + tailValues)
        if (!document.grow!"values"(counts.values))
            return false;
    while (core.flatAttributes.length < counts.attributes + tailAttributes)
        if (!document.grow!"attributes"(counts.attributes))
            return false;
    poolAt = headPool;
    foreach (piece; pieces[regionPiece .. $])
        if (piece.copy)
            foreach (i; piece.from .. piece.to)
                copyNode(i);
    assert(poolAt == headPool + tailPool && regionPool <= pool.length);

    // 6. The node runs: the new block's cells in logical order, which is
    // their order in it, between the shared runs.
    UniqueBuffer!SdlRun nodeRuns;
    size_t logical, stored;
    void addNew(size_t count)
    {
        if (count == 0)
            return;
        if (nodeRuns.length && nodeRuns[$ - 1].block is null && nodeRuns[$ - 1].hi == stored)
            nodeRuns[$ - 1].hi += cast(uint) count;
        else
            nodeRuns ~= SdlRun(null, cast(uint) stored, cast(uint)(stored + count),
                cast(uint) logical);
        stored += count;
        logical += count;
    }
    foreach (k, piece; pieces[])
    {
        if (k == regionPiece)
            addNew(regionNodes);
        if (piece.copy)
        {
            addNew(piece.to - piece.from);
            continue;
        }
        const run = oldNodes[runOf!"base"(oldNodes, piece.from)];
        const lo = run.lo + (piece.from - run.base);
        nodeRuns ~= SdlRun(run.block, cast(uint) lo, cast(uint)(lo + piece.to - piece.from),
            cast(uint) logical, run.delta + (piece.tail ? delta : 0));
        logical += piece.to - piece.from;
    }
    if (regionPiece == pieces.length)
        addNew(regionNodes);
    assert(stored == counts.nodes, "a copied cell is in no run");
    const fresh = document.filling;
    size_t values, attributes;
    foreach (ref run; nodeRuns[])
    {
        const block = run.block is null ? fresh : run.block;
        const first = (() @trusted => &block.nodes[run.lo])();
        const last = (() @trusted => &block.nodes[run.hi - 1])();
        run.valueLo = cast(uint) first.valueStart;
        run.valueBase = cast(uint) values;
        values += last.valueStart + last.valueCount - first.valueStart;
        run.attributeLo = cast(uint) first.attributeStart;
        run.attributeBase = cast(uint) attributes;
        attributes += last.attributeStart + last.attributeCount - first.attributeStart;
    }

    // 7. Comments and line starts: those before the region, the region's
    // own, then those after it, shifted.
    UniqueBuffer!SdlComment comments;
    UniqueBuffer!SdlRun commentRuns;
    {
        const count = old.commentCount;
        const head = prefixLength!(i => old.commentAt(i).span.endOffset <= regionStart)(count);
        const tail = prefixLength!(i => old.commentAt(i).span.startOffset < oldLexEnd)(count);
        spliceItems!(SdlComment, (i, moved) {
            const comment = old.commentAt(i);
            return SdlComment(moved ? shiftedBy(comment.span, delta) : comment.span,
                comment.kind);
        })(oldComments, count, head, tail, delta, layout.comments[], comments, commentRuns,
            !share);
    }
    UniqueBuffer!size_t lineStarts;
    UniqueBuffer!SdlRun lineRuns;
    {
        const count = old.lineCount;
        const head = prefixLength!(i => old.lineStart(i) <= regionStart)(count);
        const tail = prefixLength!(i => old.lineStart(i) <= oldLexEnd)(count);
        spliceItems!(size_t, (i, moved) => cast(size_t)(cast(uint) old.lineStart(i)
            + (moved ? delta : 0)))(oldLines, count, head, tail, delta, layout.lineStarts[],
            lineStarts, lineRuns, !share);
    }

    // The old blocks the runs share, by ascending address, each once.
    UniqueBuffer!(const(SdlBlock)*) others;
    void hold(scope const(SdlRun)[] runs)
    {
        foreach (ref run; runs)
            if (run.block !is null)
                others ~= run.block;
    }
    hold(nodeRuns[]);
    hold(commentRuns[]);
    hold(lineRuns[]);
    {
        import std.algorithm.sorting : sort;
        import std.algorithm.iteration : uniq;
        import std.algorithm.mutation : copy;

        auto sorted = others[];
        sort(sorted);
        others.length = sorted.length - sorted.uniq.copy(sorted).length;

    }


    return document.finishShared(counts.nodes, counts.values, counts.attributes, comments[],
        lineStarts[], nodeRuns[], commentRuns[], lineRuns[], others[], text, sourceName,
        adopted, content, lineZero);
}

/// How many cells the pass filled; the arrays may be longer.
private struct PassCounts
{
    size_t nodes = 1; // the synthetic root
    size_t values;
    size_t attributes;
    size_t poolEnd; // where the pass stopped writing payloads
    // The last token before the end of input, which a region must end with.
    bool hasLast;
    SdlTokenKind lastKind;
    size_t lastEnd;
}

/// A pass over one region of an edited source (editing §10); `.init` is a
/// whole-source pass.
private struct PassRegion
{
    bool active;
    size_t start;      // the region's first byte, at a line boundary
    uint baseDepth;    // the depth of the region's top-level nodes
    size_t poolAt;     // where the region's payloads go
    bool afterOpener;  // the region starts right after a `{`
    size_t parent;     // the cell whose children the region's top-level nodes are
}

/**
Parses `text` — the document's own copy, in its pool — in one pass (SDP4).

The pool already holds the source name and the copy, and has room for every
decoded payload after them (they never exceed the source); names slice the
copy itself. The node, value and attribute arrays grow geometrically through
the document's allocator; nothing holds a pointer into them across a growth,
since every access goes through `document.core`.
*/
private bool runPass(SdlParserConfig config, Allocator)(
    scope const(char)[] text, scope const(char)[] sourceName, SdlSpan content,
    ref PassCounts counts, ref SdlDocument!Allocator document,
    ref SdlLexerLayout layout, ref SdlError failure, in PassRegion region = PassRegion.init)
{
    auto cursor = TokenCursor!config(text, sourceName, &layout, region.start);
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

    size_t poolAt = region.active ? region.poolAt : sourceName.length + text.length;
    const baseDepth = region.baseDepth;
    uint contextDepth = baseDepth;
    // The node that owns each open block, innermost last.
    UniqueBuffer!(size_t, 32) openBlocks;

    auto core = document.core;
    if (!region.active)
    {
        const rootSpan = rootStartSpan(text);
        core.flatNodes[0] = SdlNodeCell(
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

    bool room(string field)(size_t used, SdlSpan at)
    {
        static if (field == "nodes")
            const capacity = core.flatNodes.length;
        else static if (field == "values")
            const capacity = core.flatValues.length;
        else
            const capacity = core.flatAttributes.length;
        if (used < capacity || document.grow!field(used))
            return true;
        return fail(SdlErrorCode.allocationFailed, at, "allocator rejected an SDL arena block");
    }

    /** Records a node's terminator and its extent (editing §2), once its
    terminator — for a block, the one after `}` — is known. */
    void finishLayout(size_t node, SdlTokenKind terminatorKind,
        SdlSpan terminatorSpan, in SdlToken next)
    {
        core.flatNodes[node].terminator = terminatorSpan;
        nodeExtent(text, content, core.flatNodes[node], terminatorKind, next.kind, next.span);
    }

    bool decodeValue(SdlToken token, out SdlScalar scalar)
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
        return true;
    }

    bool readName(out SdlQualifiedName name, out SdlSpan nameSpan)
    {
        if (cursor.token.kind != SdlTokenKind.identifier)
            return fail(SdlErrorCode.unexpectedToken, cursor.token.span,
                "expected an SDL identifier");
        // `text` is the pool's copy (`core.source`), so a name slices it.
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
            name = SdlQualifiedName(first.span.sliceOf(core.source), second.span.sliceOf(core.source));
            cursor.pop();
        }
        else
            name = SdlQualifiedName(null, first.span.sliceOf(core.source));
        if (cursor.failed) { takeCursorError(); return false; }
        return true;
    }

    // The full pass checks this when it opens the block (SDE15).
    if (region.afterOpener && !terminator(cursor.token.kind))
        return fail(SdlErrorCode.unexpectedToken, cursor.token.span,
            "child block opener must be followed by a terminator");

    while (true)
    {
        while (terminator(cursor.token.kind))
        {
            cursor.pop();
            if (cursor.failed) { takeCursorError(); return false; }
        }

        if (cursor.token.kind == SdlTokenKind.eof)
        {
            if (contextDepth != baseDepth)
            {
                failure = parseError(SdlErrorCode.unexpectedEof,
                    cursor.token.span, sourceName, "missing closing '}'");
                cursor.locate(failure);
                failure.relatedSpan = core.flatNodes[openBlocks[$ - 1]].openBrace;
                failure.hasRelatedSpan = true;
                return false;
            }
            break;
        }

        if (cursor.token.kind == SdlTokenKind.closeBrace)
        {
            if (contextDepth == baseDepth)
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
            const owner = openBlocks[$ - 1];
            openBlocks.popBack();
            core.flatNodes[owner].span = SdlSpan(core.flatNodes[owner].span.startOffset, end);
            core.flatNodes[owner].closeBrace = close.span;
            core.flatNodes[owner].subtreeSize = counts.nodes - owner;
            finishLayout(owner, closeTerminator, closeTerminatorSpan, cursor.token);
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

        const thisNode = counts.nodes++;
        if (!room!"nodes"(thisNode, SdlSpan.at(tagStart)))
            return false;
        core.flatNodes[thisNode] = SdlNodeCell(
            qualifiedName: tagName,
            nameSpan: tagNameSpan,
            span: SdlSpan.at(tagStart),
            valueStart: counts.values,
            attributeStart: counts.attributes,
            depth: contextDepth,
            // Provisional: `nodeExtent` reads these back as the start
            // candidates, then replaces `extent`.
            extent: SdlSpan(lineStart, tagStart),
            aloneOnLines: startsLine,
        );
        core.flatNodes[openBlocks.length ? openBlocks[$ - 1] : region.parent].childCount++;

        size_t tagValues;
        while (scalarToken(cursor.token.kind))
        {
            SdlScalar scalar;
            if (!decodeValue(cursor.token, scalar)
                || !room!"values"(counts.values, cursor.token.span))
                return false;
            core.flatValues[counts.values++] = SdlValueCell(scalar);
            tagValues++;
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
            if (!decodeValue(valueToken, scalar)
                || !room!"attributes"(counts.attributes, valueToken.span))
                return false;
            core.flatAttributes[counts.attributes++] = SdlAttributeCell(
                attributeName, attributeNameSpan,
                SdlSpan(attributeNameSpan.startOffset, valueToken.span.endOffset), scalar);
            tagAttributes++;
            cursor.pop();
            if (cursor.failed) { takeCursorError(); return false; }
        }

        core.flatNodes[thisNode].valueCount = tagValues;
        core.flatNodes[thisNode].attributeCount = tagAttributes;

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
            openBlocks ~= thisNode;
            core.flatNodes[thisNode].hasBlock = true;
            core.flatNodes[thisNode].openBrace = opener.span;
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
        core.flatNodes[thisNode].span = SdlSpan(tagStart, terminatorToken.span.endOffset);
        finishLayout(thisNode, terminatorToken.kind, terminatorToken.span,
            cursor.token);
    }
    if (!region.active)
        core.flatNodes[0].subtreeSize = counts.nodes;
    counts.poolEnd = poolAt;
    counts.hasLast = cursor.hasPrevious;

    counts.lastKind = cursor.previousKind;
    counts.lastEnd = cursor.previousEnd;
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

    // Enough nodes, values and attributes to outgrow the first capacities,
    // and a comment, so every block — core, pool, nodes, values, attributes,
    // their growths, children and comments — is requested.
    string source = "# c\n";
    foreach (i; 0 .. 40)
        source ~= "a [TQ==] 1 2 x=\"v\" y=true {\n    b\n}\n";
    {
        size_t attempts;
        size_t liveBlocks;
        auto empty = parseSdlDocument!sdlFull("", null,
            FailingAllocator(size_t.max, &attempts, &liveBlocks));
        assert(empty.hasValue && liveBlocks == attempts);
    }
    // Fail each request in turn until a parse needs no more than it got.
    size_t failAt;
    for (;; failAt++)
    {
        size_t attempts;
        size_t liveBlocks;
        bool succeeded;
        {
            auto parsed = parseSdlDocument!sdlFull(source, "alloc.sdl",
                FailingAllocator(failAt, &attempts, &liveBlocks));
            succeeded = parsed.hasValue;
            if (!succeeded)
                assert(parsed.error.code == SdlErrorCode.allocationFailed
                    && attempts == failAt + 1, parsed.error.toString);
            else
                assert(liveBlocks == 7, "a grown array left its old block behind");
        }
        assert(liveBlocks == 0);
        if (succeeded)
            break;
    }
    assert(failAt > 7, "the source did not outgrow the first capacities");
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
        assert(core.nodeCount == test.extents.length + 1, test.source);
        foreach (i, expected; test.extents)
        {
            const actual = core.nodeAt(i + 1).extent.sliceOf(test.source);
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
    foreach (i; 0 .. comments.length)
    {
        const comment = comments[i];

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

version (unittest)
{
    /// Applies `edits` to `old`'s source and re-parses the result both ways,
    /// the incremental way through `Mallocator` and through a stateful
    /// allocator; `null` when all three agree (SDE14, and SDE15's equal
    /// errors) and the stateful one freed every block. Counts the runs the
    /// region path took.
    private string reparseBothWays(SdlParserConfig config)(scope const(SdlCore)* old,
        scope const(char)[] sourceName, scope const TextEdit[] edits, ref size_t localized) @system
    {
        import sparkles.base.text.edits : writeEdited;
        import sparkles.wired.sdl.test_corpus : AllocationCounts, CountingAllocator,
            documentDifference;

        UniqueBuffer!char text;
        writeEdited(text, old.source, edits);
        auto full = parseSdlDocument!config(text[], sourceName);
        string compare(R)(ref R incremental)
        {
            if (full.hasError != incremental.hasError)
                return "one path failed: " ~ (full.hasError ? full.error.reason[].idup
                    : incremental.error.reason[].idup);
            if (full.hasError)
                return full.error.code == incremental.error.code
                    && full.error.span == incremental.error.span
                    && full.error.startPosition == incremental.error.startPosition
                    && full.error.reason[] == incremental.error.reason[] ? null : "different errors";
            return documentDifference(incremental.document, full.document);
        }

        bool local;
        auto incremental = reparseEdited!config(old, text[], sourceName, SdlSpan.init, edits,
            local);
        if (local)
            localized++;
        if (auto difference = compare(incremental))
            return difference;

        AllocationCounts counts;
        {
            bool statefulLocal;
            auto stateful = reparseEdited!config(old, text[], sourceName, SdlSpan.init, edits,
                statefulLocal, CountingAllocator!()(&counts));
            if (statefulLocal != local)
                return "the stateful allocator took the other path";
            if (auto difference = compare(stateful))
                return "stateful: " ~ difference;
        }
        return counts.live ? "the stateful allocator leaked a block" : null;
    }

    private TextEdit replacing(size_t start, size_t end, string text) @safe pure nothrow @nogc
    {
        import sparkles.base.text.span : TextSpan;

        return TextEdit(TextSpan(cast(uint) start, cast(uint) end), text);
    }
}

@("sdl.reader.reparseEdited.localizesAndFallsBack")
@system unittest
{
    enum source = "a 1\nb {\n    c 2 // note\n    d 3\n}\ne \"x\"\n";
    auto parsed = parseSdlDocument!sdlFull(source, "t.sdl");
    assert(parsed.hasValue);
    const old = parsed.document.core;
    size_t localized;
    string check(TextEdit[] edits...)
        => reparseBothWays!sdlFull(old, "t.sdl", edits, localized);

    // In the block: `c`'s value, then a new child before `d`.
    assert(check(replacing(14, 15, "20")) is null);
    assert(check(replacing(24, 24, "    z 9\n")) is null);
    // At the root: `a`'s value, the end of the input, the first line.
    assert(check(replacing(2, 3, "10")) is null);
    assert(check(replacing(source.length, source.length, "f 4\n")) is null);
    assert(check(replacing(0, 4, "")) is null);
    // Two edits in two children of the block.
    assert(check(replacing(14, 15, "7"), replacing(30, 31, "8")) is null);
    assert(localized == 6);

    // SDE15: whatever the region cannot hold re-parses in full, and each
    // result or error is the full parse's.
    foreach (edit; [
        replacing(14, 14, "/*"),           // an unterminated block comment
        replacing(14, 15, "`two\nlines`"), // a multi-line string
        replacing(15, 15, " \\"),          // a continuation into `d`
        replacing(16, 16, "}"),            // a brace that ends the block early
        replacing(15, 15, " {"),           // a block that never closes
        replacing(14, 15, "\xFF"),         // invalid UTF-8
        replacing(6, 7, "{ x"),            // a node on the opener's line
        replacing(32, 33, "} y"),          // a node after the closing brace
    ])
        assert(check(edit) is null);
}

@("sdl.reader.reparseEdited.crlf")
@system unittest
{
    enum crlf = "a 1\r\nb 2\r\nc 3\r\n";
    auto parsed = parseSdlDocument!sdlFull(crlf);
    const old = parsed.document.core;
    size_t localized;
    assert(reparseBothWays!sdlFull(old, null, [replacing(7, 8, "20")], localized) is null);
    assert(localized == 1);
    // A CR before the region must not join an LF the edit puts after it.
    foreach (edit; [replacing(5, 5, "\n"), replacing(4, 5, ""), replacing(9, 10, "\r")])
        assert(reparseBothWays!sdlFull(old, null, [edit], localized) is null);
}

@("sdl.reader.reparseEdited.properties")
@system unittest
{
    import std.file : readText;
    import sparkles.wired.sdl.test_corpus : parseRecipe, repositoryRecipes;

    uint state = 0x2545_F491;
    uint next(size_t bound)
    {
        state = state * 1_103_515_245 + 12_345;
        return bound ? cast(uint)((state >> 8) % bound) : 0;
    }
    // Replacements: structure, values, comments, strings, continuations,
    // braces and newlines, valid and not.
    static immutable string[] snippets = [
        "", "x 1\n", "    y \"s\"\n", " z=true", "\"v\"", "42", "// c\n", "/* c */",
        "/*", "*/", "`", "`a\nb`", " \\\n", "{", "}", "{\n}\n", "\n", "\r", "\r\n",
        ";", " ", "é", "\xE2\x80\xA8", "w {\n    q 1\n}\n", "#", "--", "\"",
    ];

    // One or two non-overlapping edits of `old`, half of them at line starts.
    size_t generate(scope const(SdlCore)* old, ref TextEdit[2] edits)
    {
        const contentEnd = old.content.endOffset;
        size_t count = 1 + next(2);
        size_t cursor = old.content.startOffset;
        foreach (k; 0 .. count)
        {
            if (cursor > contentEnd)
                return k;
            size_t start = cursor + next(contentEnd - cursor + 1);
            if (next(2))
                while (start > cursor && old.source[start - 1] != '\n')
                    start--;
            const end = next(3) ? start : start + next((contentEnd - start) / 8 + 1);
            edits[k] = replacing(start, end, snippets[next(snippets.length)]);
            cursor = end + 1;
        }
        return count;
    }

    size_t localized, total;
    void exercise(SdlParserConfig config)(scope const(SdlCore)* old, string name, size_t rounds)
    {
        foreach (round; 0 .. rounds)
        {
            TextEdit[2] edits;
            const count = generate(old, edits);
            if (!count)
                continue;
            const verdict = reparseBothWays!config(old, name, edits[0 .. count], localized);
            if (verdict !is null)
            {
                import std.conv : to;

                assert(false, name ~ ": " ~ verdict ~ " after " ~ edits[0 .. count].to!string);
            }
            total++;
        }
    }

    const paths = repositoryRecipes();
    assert(paths.length > 100, "the repository walk found too few recipes");
    foreach (path; paths)
    {
        if (path[$ - 2 .. $] == ".d")
            continue; // embedded recipes reach this path through the editor
        auto parsed = parseRecipe(readText(path), path);
        if (parsed.hasValue)
            exercise!sdlDubRecipe(parsed.document.core, path, 24);
    }

    // A deep, wide document: nested blocks, values and attributes.
    UniqueBuffer!char deep;
    foreach (tree; 0 .. 6)
    {
        foreach (level; 0 .. 7)
        {
            foreach (_; 0 .. level)
                deep ~= "    ";
            deep ~= "n";
            deep ~= cast(char)('a' + level);
            deep ~= " 1 \"two\" k=3 {\n";
            foreach (_; 0 .. level + 1)
                deep ~= "    ";
            deep ~= "leaf on x:y=\"z\" // c\n";
        }
        foreach_reverse (level; 0 .. 7)
        {
            foreach (_; 0 .. level)
                deep ~= "    ";
            deep ~= "}\n";
        }
    }
    auto generated = parseSdlDocument!sdlFull(deep[]);
    assert(generated.hasValue, generated.error.reason[]);
    exercise!sdlFull(generated.document.core, "deep.sdl", 2000);

    // Both paths run; most edits that leave the text valid localize.
    assert(total > 5000 && localized > total / 10 && localized < total,
        "the region path ran too rarely, or always");

    // Chained (editing §10.1): each edit applies to the document the one
    // before produced, which is dropped while the next shares its blocks —
    // through `Mallocator`, and through a counting allocator that must get
    // every block back.
    size_t chained, chainedLocal, mostBlocks;
    void chain(SdlParserConfig config, A...)(scope const(char)[] source, string name,
        size_t rounds, A alloc)
    {
        import core.lifetime : move;
        import sparkles.base.text.edits : writeEdited;
        import sparkles.wired.sdl.test_corpus : documentDifference;

        auto current = parseSdlDocument!config(source, name, alloc);
        assert(current.hasValue, name);
        foreach (round; 0 .. rounds)
        {
            TextEdit[2] edits;
            const count = generate(current.document.core, edits);
            if (!count)
                continue;
            UniqueBuffer!char text;
            writeEdited(text, current.document.source, edits[0 .. count]);
            bool local;
            auto incremental = reparseEdited!config(current.document.core, text[], name,
                SdlSpan.init, edits[0 .. count], local, alloc);
            auto full = parseSdlDocument!config(text[], name);
            string verdict;
            if (full.hasError != incremental.hasError)
                verdict = "one path failed";
            else if (full.hasError)
                verdict = full.error.code == incremental.error.code
                    && full.error.span == incremental.error.span ? null : "different errors";
            else
                verdict = documentDifference(incremental.document, full.document);
            if (verdict !is null)
            {
                import std.conv : to;

                assert(false, name ~ " (chained, round " ~ round.to!string ~ "): " ~ verdict
                    ~ " after " ~ edits[0 .. count].to!string);
            }
            chained++;
            chainedLocal += local;
            if (incremental.hasValue)
                current = move(incremental);
            if (current.document.core.blocks.length > mostBlocks)
                mostBlocks = current.document.core.blocks.length;
        }
    }
    chain!sdlFull(deep[], "deep.sdl", 1500);
    {
        import sparkles.wired.sdl.test_corpus : AllocationCounts, CountingAllocator;

        AllocationCounts counts;
        chain!sdlFull(deep[], "deep.sdl", 500, CountingAllocator!()(&counts));
        assert(counts.live == 0, "a chained document leaked a block");
    }
    foreach (path; paths[0 .. 40])
        if (path[$ - 2 .. $] != ".d")
            chain!sdlDubRecipe(readText(path), path, 24);
    // Some document shared the blocks of several generations before it.
    assert(chained > 2000 && chainedLocal > chained / 10 && mostBlocks >= 4,
        "the chained region path ran too rarely, or never shared");

}


@("sdl.reader.reparseEdited.oracleCatchesASplice")
@system unittest
{
    import sparkles.base.text.edits : writeEdited;
    import sparkles.wired.sdl.test_corpus : documentDifference;

    // The mutation check: perturb a shared run's shift, a line run's, or a
    // copied cell, of a localized result, and the SDE14 comparison must see
    // it. The nodes after the edit are enough to be shared, not copied.
    UniqueBuffer!char source;
    source ~= "a 1\nb {\n    c 2\n}\n";
    foreach (_; 0 .. 20)
        source ~= "d 3\n";
    auto parsed = parseSdlDocument!sdlFull(source[]);
    const edits = [replacing(14, 15, "20")];
    UniqueBuffer!char text;
    writeEdited(text, source[], edits);
    bool local;
    auto incremental = reparseEdited!sdlFull(parsed.document.core, text[], null, SdlSpan.init,
        edits, local);
    auto full = parseSdlDocument!sdlFull(text[]);
    assert(local && documentDifference(incremental.document, full.document) is null);

    // The result shares the cells after the edit through a shifted run.
    auto core = incremental.document.core;
    const old = parsed.document.core.blocks[0];
    assert(!core.flat && core.nodeRuns.length > 1 && core.blocks.length == 2);
    const fresh = core.blocks[core.blocks[0] is old];
    auto shiftedRun = cast(SdlRun*) &core.nodeRuns[$ - 1];
    assert(shiftedRun.block is old && shiftedRun.delta == 1);
    shiftedRun.delta = 0;
    assert(documentDifference(incremental.document, full.document) !is null);
    shiftedRun.delta = 1;
    assert(documentDifference(incremental.document, full.document) is null);
    auto lineRun = cast(SdlRun*) &core.lineRuns[$ - 1];
    lineRun.delta++;
    assert(documentDifference(incremental.document, full.document) !is null);
    lineRun.delta--;
    assert(documentDifference(incremental.document, full.document) is null);
    auto copied = cast(SdlNodeCell*) &fresh.nodes[0];
    copied.extent = SdlSpan(copied.extent.startOffset + 1, copied.extent.endOffset);
    assert(documentDifference(incremental.document, full.document) !is null);
}


@("sdl.reader.reparseEdited.noEditsCopyWithoutLexing")
@system unittest
{
    import sparkles.wired.sdl.test_corpus : AllocationCounts, CountingAllocator,
        documentDifference;

    enum source = "a 1 // one\nb {\n    c \"x\" k=2\n}\n";
    auto parsed = parseSdlDocument!sdlFull(source, "t.sdl");
    const old = parsed.document.core;
    bool local;
    auto copy = reparseEdited!sdlFull(old, source, "t.sdl", SdlSpan.init, null, local);
    assert(local && copy.document.core !is old);
    assert(documentDifference(copy.document, parsed.document) is null);

    // A stateful allocator gets the copy too.
    AllocationCounts counts;
    {
        auto counted = reparseEdited!sdlFull(old, source, "t.sdl", SdlSpan.init, null, local,
            CountingAllocator!()(&counts));
        assert(local && documentDifference(counted.document, parsed.document) is null);
        assert(counts.calls && counts.live == counts.calls);
    }
    assert(counts.live == 0);

    // No edits but other text is not a copy: the text parses in full.
    auto other = reparseEdited!sdlFull(old, "a 2 // one\nb {\n    c \"x\" k=2\n}\n", "t.sdl",
        SdlSpan.init, null, local);
    assert(!local && other.hasValue);
}

@("sdl.reader.reparseEdited.statefulAllocatorLocalizes")
@system unittest
{
    import sparkles.base.text.edits : writeEdited;
    import sparkles.wired.sdl.test_corpus : AllocationCounts, CountingAllocator,
        documentDifference;

    // A large document and a one-value edit near its end.
    UniqueBuffer!char source;
    foreach (i; 0 .. 4000)
        source ~= "node 1 \"two\" k=3 {\n    leaf on\n}\n";
    AllocationCounts fullCounts, localCounts;
    auto parsed = parseSdlDocument!sdlFull(source[], null, CountingAllocator!()(&fullCounts));
    assert(parsed.hasValue);
    const at = source.length - 33 + 5;
    assert(source[][at .. at + 1] == "1");
    const edits = [replacing(at, at + 1, "10")];
    UniqueBuffer!char text;
    writeEdited(text, source[], edits);
    bool local;
    auto incremental = reparseEdited!sdlFull(parsed.document.core, text[], null, SdlSpan.init,
        edits, local, CountingAllocator!()(&localCounts));
    assert(local);
    assert(documentDifference(incremental.document, parseSdlDocument!sdlFull(text[]).document)
        is null);
    // The old document was parsed through `Mallocator`, another allocator
    // type, so the kept cells are copied rather than shared (editing §10.1),
    // each array sized once where the full parse grew it.
    assert(localCounts.calls < fullCounts.calls);
    assert(localCounts.bytes < fullCounts.bytes * 2 / 3);
}

@("sdl.reader.reparseEdited.allocatesTheEdit")
@system unittest
{
    import sparkles.base.text.edits : writeEdited;
    import sparkles.wired.sdl.test_corpus : AllocationCounts, CountingAllocator,
        documentDifference;

    // Performance SDP8: a one-value edit of a document re-parsed through its
    // own allocator type, which hands over the edited text, allocates the
    // same few blocks at the start and at the end of documents of two sizes.
    alias Counting = CountingAllocator!();
    AllocationCounts[2][2] counts;
    size_t[2] fullBytes;
    foreach (size, repeats; [1000, 4000])
    {
        UniqueBuffer!char source;
        foreach (i; 0 .. repeats)
            source ~= "node 1 \"two\" k=3 {\n    leaf on\n}\n";
        AllocationCounts parseCounts;
        auto parsed = parseSdlDocument!sdlFull(source[], null, Counting(&parseCounts));
        assert(parsed.hasValue);
        fullBytes[size] = parseCounts.bytes;
        foreach (where, at; [5, source.length - 33 + 5])
        {
            assert(source[][at .. at + 1] == "1");
            const edits = [replacing(at, at + 1, "10")];
            UniqueBuffer!char text;
            writeEdited(text, source[], edits);
            bool local;
            auto incremental = reparseEdited!sdlFull(parsed.document.core, text, null,
                SdlSpan.init, edits, local, Counting(&counts[size][where]));
            assert(local && text.length == 0, "the text was not handed over");
            const reference = parseSdlDocument!sdlFull(incremental.document.source);
            assert(documentDifference(incremental.document, reference.document) is null);
        }
    }
    foreach (where; 0 .. 2)
    {
        const small = counts[0][where], large = counts[1][where];
        assert(small.calls == large.calls && small.bytes == large.bytes,
            "an edit's allocation grew with the document");
        assert(small.calls <= 16 && small.bytes <= 16 * 1024 && small.bytes * 50 < fullBytes[0]);
    }
}


@("sdl.reader.reparseEdited.retentionIsBounded")
@system unittest
{
    import core.lifetime : move;
    import sparkles.base.text.edits : writeEdited;
    import sparkles.wired.sdl.test_corpus : AllocationCounts, CountingAllocator,
        documentDifference;

    // Editing §10.1: edits all over a document leave blocks partly shared,
    // and what the document holds stays within a few full parses' worth, as
    // the re-parse falls back to a full one when it would hold more.
    alias Counting = CountingAllocator!();
    UniqueBuffer!char source;
    foreach (i; 0 .. 400)
        source ~= i % 4 ? "n 1000 \"text\"\n" : "b {\n    c 1000\n}\n";
    AllocationCounts counts;
    {
        auto current = parseSdlDocument!sdlFull(source[], null, Counting(&counts));
        const fullBytes = counts.bytes;
        size_t flatAgain;
        uint state = 7;
        foreach (round; 0 .. 600)
        {
            state = state * 1_103_515_245 + 12_345;
            // A value at the start of one of the document's lines.
            const text = current.document.source;
            size_t at = (state >> 8) % (text.length - 8);
            while (at < text.length && (text[at] < '0' || text[at] > '9'))
                at++;
            if (at == text.length)
                continue;
            const edits = [replacing(at, at + 1, round % 2 ? "2" : "3")];
            UniqueBuffer!char edited;
            writeEdited(edited, text, edits);
            bool local;
            auto next = reparseEdited!sdlFull(current.document.core, edited, null, SdlSpan.init,
                edits, local, Counting(&counts));
            assert(next.hasValue);
            current = move(next);
            const core = current.document.core;
            flatAgain += core.flat;
            assert(SdlDocument!Counting.heldBytes(core.blocks) <= 4 * fullBytes,
                "a shared document holds too much");
        }
        assert(flatAgain, "the re-parse never fell back to a full one");
        const reference = parseSdlDocument!sdlFull(current.document.source);
        assert(documentDifference(current.document, reference.document) is null);
    }
    assert(counts.live == 0);
}
