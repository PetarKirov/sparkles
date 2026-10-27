/** Lossless SDL editing (editing spec, SDE1–SDE10).

An `SdlEditor` borrows a parsed document and the host text it came from — the
recipe itself, or the D program that embeds it — and accumulates edits stated
through the document's views. Each operation resolves at once to byte-range
replacements of the host ($(REF TextEdit, sparkles,base,text,edits)) confined
to the range the spec names; writing renders the edited host into the
editor's buffer, re-parses it, and only then copies it out. Nothing the
operations do not name changes: comments, quoting, blank lines, indentation
and line endings elsewhere survive byte for byte.
*/
module sparkles.wired.sdl.editor;

import std.experimental.allocator.common : stateSize;
import std.experimental.allocator.mallocator : Mallocator;
import std.range.primitives : put;

import sparkles.base.buffer : UniqueBuffer;
import sparkles.base.text.edits : mapOffset, TextEdit, validateEdits, writeEdited;
import sparkles.base.text.errors : valueOf;
import sparkles.base.text.span : TextSpan;
import sparkles.base.text.writers : writeInteger;
import sparkles.wired.sdl.config : SdlParserConfig, sdlFull;
import sparkles.wired.sdl.document;
import sparkles.wired.sdl.embedded : isEmbeddedRendering, locateEmbeddedRecipe,
    newlineWidthAt, SdlEmbeddedRecipe, writeEmbeddedRendering;
import sparkles.wired.sdl.error;
import sparkles.wired.sdl.lexer : isSdlIdentifier, lexSDL, SdlTokenKind;
import sparkles.wired.sdl.reader : parseSdlDocumentIn;
import sparkles.wired.sdl.writer : writeSdlScalar;

/// Whether removing a node also removes the comments attached above it.
enum SdlAttachedComments : ubyte
{
    keep, /// Leave the comment lines above the node.
    remove, /// Remove the run of comment-only lines directly above it too.
}

private struct PendingEdit
{
    uint start, end; // host byte range
    uint textStart, textLength; // replacement, in the editor's text buffer (SDE10)
    uint operation; // 1-based, in the order operations were made
    uint sequence; // creation order, which orders insertions at one point
}

private struct FragmentCheck
{
    uint textStart, textLength; // the re-indented fragment, without separators
    uint operation;
}

/// An indentation: an outer prefix borrowed from the host plus one step.
private struct Indent
{
    const(char)[] outer;
    const(char)[] step;
}

/// What lexing a fragment found (§3: fragments are whole nodes).
private struct FragmentShape
{
    bool valid; // lexes, braces balance, and every node is complete
    size_t nodes; // every node, nested ones included
    size_t topLevel; // nodes at depth 0
    bool hasBlock;
    bool multiLine;
}

/** Accumulates lossless edits to one document's host and writes the result.

`config` is the profile the document was parsed with; writing re-parses under
it (SDE2). The editor borrows the document and the host and never mutates
either; it is movable, and moving it invalidates nothing (SDE10).
*/
struct SdlEditor(SdlParserConfig config = sdlFull, DocumentAllocator = Mallocator)
{
    private const(SdlCore)* _core;
    private const(char)[] _host;
    private const(char)[] _sourceName;
    private SdlSpan _content;
    private SdlEmbeddedRecipe _recipe; // `found` iff the host embeds the recipe
    private UniqueBuffer!char _text;
    private UniqueBuffer!PendingEdit _edits;
    private UniqueBuffer!FragmentCheck _fragments;
    private long _nodeDelta; // expected change in node count (SDE2)
    private bool _nodeCountKnown = true;
    private uint _operations;
    private SdlError _failure;
    private bool _failed;

    @disable this(this);

    /** Borrows `document` and `host`, which is the document's source or the
    D program whose embedded recipe the document was parsed from; any other
    host makes every operation fail with `editTargetMissing`. */
    this(return scope ref const SdlDocument!DocumentAllocator document,
        return scope const(char)[] host)
    {
        _host = host;
        _sourceName = document.sourceName;
        if (!document.valid)
        {
            fail(SdlErrorCode.editTargetMissing, SdlSpan.init, "the document is empty");
            return;
        }
        _core = (() @trusted => document.core)();
        const source = _core.source;
        if (host == source)
            _content = _core.content;
        else
        {
            const recipe = locateEmbeddedRecipe(host);
            if (recipe.found && !recipe.isJson && isEmbeddedRendering(source, host, recipe))
            {
                _recipe = recipe;
                _content = recipe.content;
            }
            else
                fail(SdlErrorCode.editTargetMissing, SdlSpan.init,
                    "the host is not the document's source or its embedding");
        }
    }

    /// Whether every operation so far resolved; `write` reports the first
    /// failure otherwise.
    bool ok() const @safe pure nothrow @nogc => !_failed;

    /// Replaces positional value `index` of `node` with `value`'s canonical
    /// spelling; the range is the value's span.
    void replaceValue(scope SdlNode node, size_t index, in SdlScalar value)
    {
        const op = begin();
        if (!owns(node.core))
            return;
        if (index >= node.valueCount)
            return fail(SdlErrorCode.editTargetMissing, node.nameSpan, "no such value");
        size_t i;
        foreach (scalar; node.byValue)
            if (i++ == index)
            {
                const start = _text.length;
                if (!renderScalar(value, scalar.span))
                    return;
                record(scalar.span, start, op);
                return;
            }
    }

    /// Replaces `attribute` with `name=value`; the separator before it stays.
    void replaceAttribute(scope SdlAttributeView attribute, SdlQualifiedName name,
        in SdlScalar value)
    {
        const op = begin();
        if (!owns(attribute.core))
            return;
        const start = _text.length;
        if (!renderAttribute(name, value, attribute.span))
            return;
        record(attribute.span, start, op);
    }

    /** Sets attribute `name` of `node`: replaces the one attribute of that
    name, or inserts ` name=value` after the node's last value, attribute or
    name. No edit when it already has that value; a name held by several
    attributes is `editAmbiguousTarget`. */
    void setAttribute(scope SdlNode node, SdlQualifiedName name, in SdlScalar value)
    {
        const op = begin();
        if (!owns(node.core))
            return;
        size_t matches;
        SdlAttributeView found;
        foreach (attribute; node.byAttribute(name))
        {
            matches++;
            found = (() @trusted => attribute)();
        }
        if (matches > 1)
            return fail(SdlErrorCode.editAmbiguousTarget, node.nameSpan,
                "the attribute occurs more than once");
        const start = _text.length;
        if (matches == 1)
        {
            if (!renderAttribute(name, value, found.span))
                return;
            const existing = found.span.sliceOf(_host);
            if (_text[start .. $] == existing)
                { _text.length = start; return; }
            record(found.span, start, op);
            return;
        }
        const char[1] space = ' ';
        put(_text, space[]);
        if (!renderAttribute(name, value, node.nameSpan))
            return;
        record(SdlSpan.at(lastItemEnd(node)), start, op);
    }

    /** Removes `attribute`, the spaces and tabs before it on its line, and a
    `\` continuation that separates it from the previous token. */
    void removeAttribute(scope SdlAttributeView attribute)
    {
        const op = begin();
        if (!owns(attribute.core))
            return;
        size_t start = attribute.span.startOffset;
        while (start > _content.startOffset && isBlank(_host[start - 1]))
            start--;
        if (start > _content.startOffset && lineStartAt(start))
        {
            // A continued line: the previous token ends before `\`, spaces,
            // the newline (and, in DUB's profile, blank lines).
            const previous = previousTokenEnd(attribute);
            if (hasCommentIn(previous, start))
                return fail(SdlErrorCode.editUnsupportedLayout, attribute.span,
                    "a comment sits in the continuation before the attribute");
            if (!isContinuationGap(_host[previous .. start]))
                return fail(SdlErrorCode.editUnsupportedLayout, attribute.span,
                    "the attribute starts a line without a continuation");
            start = previous;
        }
        record(SdlSpan(start, attribute.span.endOffset), _text.length, op);
    }

    /// Inserts the nodes of `fragment` before `sibling` (SDE4).
    void insertBefore(scope SdlNode sibling, scope const(char)[] fragment)
    {
        const op = begin();
        if (!owns(sibling.core) || !isNonRoot(sibling))
            return;
        insertBeside(sibling, fragment, op, false);
    }

    /// Inserts the nodes of `fragment` after `sibling` (SDE4).
    void insertAfter(scope SdlNode sibling, scope const(char)[] fragment)
    {
        const op = begin();
        if (!owns(sibling.core) || !isNonRoot(sibling))
            return;
        insertBeside(sibling, fragment, op, true);
    }

    /** Appends the nodes of `fragment` as `parent`'s last children: before
    its `}` line, at the end of the content for the root, or in a new block
    after its last value, attribute or name. */
    void append(scope SdlNode parent, scope const(char)[] fragment)
    {
        const op = begin();
        if (!owns(parent.core))
            return;
        const cell = cellOf(parent);
        const isRoot = parent.cellIndex == 0;
        if (!isRoot && !cell.hasBlock)
            return appendBlock(parent, fragment, op);

        const shape = analyze(fragment, op);
        if (!shape.valid)
            return;
        if (!isRoot && !closeAloneOnLine(cell))
            return inlineInsert(cell.closeBrace.startOffset, fragment, shape, op,
                InlineJoin.fragmentThenSeparator);

        const point = isRoot ? _content.endOffset : lineStart(cell.closeBrace.startOffset);
        const indent = isRoot ? Indent(lastChildIndent(parent, "")) : childIndent(parent);
        insertLines(point, fragment, indent, shape, op);
    }

    /** Removes `node`: its extent, its attached comments when asked, and the
    blank line or newline SDE5 names. */
    void remove(scope SdlNode node, SdlAttachedComments comments = SdlAttachedComments.keep)
    {
        const op = begin();
        if (!owns(node.core) || !isNonRoot(node))
            return;
        const cell = cellOf(node);
        size_t start = cell.extent.startOffset, end = cell.extent.endOffset;
        if (cell.aloneOnLines)
        {
            if (comments == SdlAttachedComments.remove)
                start = attachedCommentsStart(start);
            const before = previousLine(start);
            if (start > _content.startOffset && isBlankLine(before)
                && (end >= _content.endOffset || isBlankLine(lineAt(end))))
                start = before.startOffset;
        }
        if (end == _host.length && !endsWithNewline(_host) && start > _content.startOffset)
        {
            // The last thing in a host without a final newline: take the
            // newline before it, so the host gains none.
            const previous = previousNewlineStart(start);
            if (previous != size_t.max)
                start = previous;
        }
        _nodeDelta -= subtreeSize(node.cellIndex);
        record(SdlSpan(start, end), _text.length, op);
    }

    /// Replaces the lines strictly inside `node`'s block with `fragment`.
    void replaceBody(scope SdlNode node, scope const(char)[] fragment)
    {
        const op = begin();
        if (!owns(node.core) || !isNonRoot(node))
            return;
        const cell = cellOf(node);
        if (!cell.hasBlock)
            return fail(SdlErrorCode.editTargetMissing, cell.nameSpan, "the node has no block");
        const bodyStart = openerLineEnd(cell);
        if (bodyStart == size_t.max || !closeAloneOnLine(cell))
            return fail(SdlErrorCode.editUnsupportedLayout, cell.span,
                "the block's braces share lines with content");
        const bodyEnd = lineStart(cell.closeBrace.startOffset);
        const shape = analyze(fragment, op);
        if (!shape.valid)
            return;
        foreach (i; 0 .. cell.childCount)
            _nodeDelta -= subtreeSize(_core.childIndexes[cell.childStart + i]);
        _nodeDelta += shape.nodes;
        const start = _text.length;
        if (shape.nodes)
        {
            reindent(fragment, childIndent(node), newlineFor(bodyStart), op);
            put(_text, newlineFor(bodyStart));
        }
        record(SdlSpan(bodyStart, bodyEnd), start, op);
    }

    /** Replaces `region` — a span of the content the caller derived from the
    document, such as the lines between two marker comments — with `text`. */
    void replaceRegion(TextSpan region, scope const(char)[] text)
    {
        const op = begin();
        if (_failed)
            return;
        if (!region.isValid || region.startOffset < _content.startOffset
            || region.endOffset > _content.endOffset)
            return fail(SdlErrorCode.editConflict, SdlSpan.init,
                "the region is outside the content");
        _nodeCountKnown = false;
        const start = _text.length;
        put(_text, text);
        record(SdlSpan(region.startOffset, region.endOffset), start, op);
    }

    /** Renders the edited host, re-parses it with `allocator` (SDE2, and the
    embedded-recipe checks of SDE7), then copies it to `writer`; on any
    failure nothing reaches `writer`. The editor is unchanged, so the same set
    may be written again. */
    SdlExpected!void write(Writer, Allocator)(ref Writer writer, ref Allocator allocator)
    {
        if (_failed)
            return sdlErr!void(_failure);

        UniqueBuffer!PendingEdit sorted;
        sorted.reserve(_edits.length);
        foreach (ref e; _edits[])
            sorted ~= e;
        sortEdits(sorted[]);

        UniqueBuffer!TextEdit edits;
        edits.reserve(sorted.length);
        foreach (ref e; sorted[])
            edits ~= TextEdit(TextSpan(e.start, e.end),
                _text[e.textStart .. e.textStart + e.textLength]);
        const validation = validateEdits(_host.length, edits[]);
        if (validation.hasError)
        {
            const index = validation.error.index;
            const first = sorted[index ? index - 1 : index];
            const second = sorted[index];
            return sdlErr!void(conflict(first, second));
        }

        foreach (ref check; _fragments[])
        {
            auto parsed = parseFragment(_text[check.textStart .. check.textStart + check.textLength],
                allocator);
            if (parsed.hasError)
                return sdlErr!void(editError(SdlErrorCode.editFragmentInvalid, SdlSpan.init,
                    "a fragment does not parse as whole nodes", check.operation));
        }

        UniqueBuffer!char output;
        output.reserve(_host.length + _text.length);
        writeEdited(output, _host, edits[]);

        auto checked = reparse(output[], edits[], allocator);
        if (checked.hasError)
            return checked;
        put(writer, output[]);
        return sdlOk();
    }

    // ── Resolution helpers ─────────────────────────────────────────────

    private uint begin() => ++_operations;

    private void fail(SdlErrorCode code, SdlSpan span, string reason, uint operation = 0)
    {
        if (_failed)
            return;
        _failure = editError(code, span, reason, operation ? operation : _operations);
        _failed = true;
    }

    private SdlError editError(SdlErrorCode code, SdlSpan span, string reason,
        uint operation) const
    {
        SdlError error;
        error.stage = SdlErrorStage.edit;
        error.code = code;
        error.sourceName ~= _sourceName;
        error.span = span;
        if (span.isValid && _core !is null)
        {
            error.startPosition = _core.position(span.startOffset);
            error.endPosition = _core.position(span.endOffset);
        }
        error.reason ~= "operation ";
        writeInteger(error.reason, operation);
        error.reason ~= ": ";
        error.reason ~= reason;
        return error;
    }

    private SdlError conflict(in PendingEdit first, in PendingEdit second) const
    {
        auto error = editError(SdlErrorCode.editConflict, SdlSpan(second.start, second.end),
            "overlaps operation ", second.operation);
        writeInteger(error.reason, first.operation);
        return error;
    }

    private bool owns(scope const(SdlCore)* core)
    {
        if (_failed)
            return false;
        if (core !is _core)
        {
            fail(SdlErrorCode.editTargetMissing, SdlSpan.init,
                "the view belongs to another document");
            return false;
        }
        return true;
    }

    private bool isNonRoot(scope SdlNode node)
    {
        if (node.cellIndex != 0)
            return true;
        fail(SdlErrorCode.editTargetMissing, SdlSpan.init, "the root has no siblings or extent");
        return false;
    }

    private SdlNodeCell cellOf(scope SdlNode node) const
        => (() @trusted => _core.nodes[node.cellIndex])();

    private void record(SdlSpan range, size_t textStart, uint operation)
    {
        if (range.startOffset < _content.startOffset || range.endOffset > _content.endOffset)
            return fail(SdlErrorCode.editConflict, range, "the edit leaves the content", operation);
        _edits ~= PendingEdit(range.startOffset, range.endOffset, cast(uint) textStart,
            cast(uint)(_text.length - textStart), operation, cast(uint) _edits.length);
    }

    private bool renderScalar(in SdlScalar value, SdlSpan target)
    {
        const start = _text.length;
        const written = writeSdlScalar(value, _text);
        if (written.hasError)
        {
            _text.length = start;
            fail(SdlErrorCode.editFragmentInvalid, target, "the value has no SDL spelling");
            return false;
        }
        return true;
    }

    private bool renderAttribute(SdlQualifiedName name, in SdlScalar value, SdlSpan target)
    {
        if ((name.namespace_.length && !isSdlIdentifier(name.namespace_))
            || !isSdlIdentifier(name.localName))
        {
            fail(SdlErrorCode.editFragmentInvalid, target, "the attribute name is not an identifier");
            return false;
        }
        if (name.namespace_.length)
        {
            put(_text, name.namespace_);
            const char[1] colon = ':';
            put(_text, colon[]);
        }
        put(_text, name.localName);
        const char[1] equals = '=';
        put(_text, equals[]);
        return renderScalar(value, target);
    }

    // ── Insertion ──────────────────────────────────────────────────────

    private enum InlineJoin : ubyte { fragmentThenSeparator, separatorThenFragment, spaceFragmentSemicolon }

    private void insertBeside(scope SdlNode sibling, scope const(char)[] fragment, uint op,
        bool after)
    {
        const cell = cellOf(sibling);
        const shape = analyze(fragment, op);
        if (!shape.valid)
            return;
        if (cell.aloneOnLines)
        {
            const point = after ? cell.extent.endOffset : cell.extent.startOffset;
            return insertLines(point, fragment, Indent(lineIndent(cell.span.startOffset)), shape, op);
        }
        const startsLine = lineStartAt(lineIndentStart(cell.extent.startOffset))
            && cell.extent.startOffset == cell.span.startOffset;
        const semicolonEnded = cell.terminator.isValid && cell.terminator.length == 1
            && _host[cell.terminator.startOffset] == ';';
        if (after)
            inlineInsert(cell.extent.endOffset, fragment, shape, op,
                semicolonEnded ? InlineJoin.fragmentThenSeparator : InlineJoin.separatorThenFragment);
        else
            inlineInsert(cell.extent.startOffset, fragment, shape, op,
                startsLine ? InlineJoin.fragmentThenSeparator : InlineJoin.spaceFragmentSemicolon);
    }

    /// Inserts `fragment` as whole lines at `point` (SDE4).
    private void insertLines(size_t point, scope const(char)[] fragment,
        in Indent indent, in FragmentShape shape, uint op)
    {
        const newline = newlineFor(point);
        const start = _text.length;
        if (!lineStartAt(point))
            put(_text, newline);
        reindent(fragment, indent, newline, op);
        if (!(point == _host.length && !endsWithNewline(_host)))
            put(_text, newline);
        _nodeDelta += shape.nodes;
        record(SdlSpan.at(point), start, op);
    }

    /// Inserts a single block-less node on an inline anchor's line (§3).
    private void inlineInsert(size_t point, scope const(char)[] fragment,
        in FragmentShape shape, uint op, InlineJoin join)
    {
        if (shape.topLevel != 1 || shape.hasBlock || shape.multiLine)
            return fail(SdlErrorCode.editUnsupportedLayout, SdlSpan.at(point),
                "an inline anchor takes one single-line node without a block", op);
        const node = trimNode(fragment);
        const start = _text.length;
        final switch (join)
        {
        case InlineJoin.fragmentThenSeparator:
            put(_text, node);
            put(_text, "; ");
            break;
        case InlineJoin.separatorThenFragment:
            put(_text, "; ");
            put(_text, node);
            break;
        case InlineJoin.spaceFragmentSemicolon:
            put(_text, " ");
            put(_text, node);
            put(_text, ";");
            break;
        }
        _fragments ~= FragmentCheck(cast(uint)(start + (join == InlineJoin.fragmentThenSeparator ? 0
            : join == InlineJoin.separatorThenFragment ? 2 : 1)), cast(uint) node.length, op);
        _nodeDelta += 1;
        record(SdlSpan.at(point), start, op);
    }

    /// Appends to a node without a block: ` {`, the fragment, and `}`.
    private void appendBlock(scope SdlNode parent, scope const(char)[] fragment, uint op)
    {
        const shape = analyze(fragment, op);
        if (!shape.valid)
            return;
        const point = lastItemEnd(parent);
        const newline = newlineFor(point);
        const indent = lineIndent(cellOf(parent).span.startOffset);
        const start = _text.length;
        put(_text, " {");
        put(_text, newline);
        reindent(fragment, Indent(indent, indentStep()), newline, op);
        put(_text, newline);
        put(_text, indent);
        put(_text, "}");
        _nodeDelta += shape.nodes;
        record(SdlSpan.at(point), start, op);
    }

    /** Writes `fragment` into the text buffer: its common indentation
    replaced by `indent` on every line that begins outside a string or a
    continued line, its line breaks there spelled `newline`, and one final
    line break dropped. Records the result for the write-time parse. */
    private void reindent(scope const(char)[] fragment, in Indent indent,
        scope const(char)[] newline, uint op)
    {
        // Lines that begin inside a multi-line token keep their bytes.
        UniqueBuffer!TextSpan protectedRanges;
        auto lexer = lexSDL!config(fragment);
        while (!lexer.empty)
        {
            auto item = lexer.front;
            if (item.hasError)
                break;
            const span = item.valueOf.span;
            if (span.length > 1 && item.valueOf.kind != SdlTokenKind.newline
                && hasNewline(span.sliceOf(fragment)))
                protectedRanges ~= span.bytes;
            lexer.popFront();
        }

        bool isProtected(size_t at)
        {
            foreach (r; protectedRanges[])
                if (at > r.startOffset && at < r.endOffset)
                    return true;
            return false;
        }

        // Drop one final line break; the separators of SDE4 supply it.
        size_t length = fragment.length;
        foreach (width; widthsLongestCrLf)
            if (length >= width && newlineWidthAt(fragment, length - width) == width)
            {
                length -= width;
                break;
            }
        const body = fragment[0 .. length];

        // The common indentation of the lines that are re-indented.
        size_t common = size_t.max;
        bool continued;
        for (size_t at = 0; at <= body.length;)
        {
            const end = lineEnd(body, at);
            if (!isProtected(at) && !continued)
            {
                size_t ws;
                while (at + ws < end && isBlank(body[at + ws]))
                    ws++;
                if (at + ws < end && ws < common)
                    common = ws;
            }
            continued = endsWithContinuation(body[at .. end]);
            if (end >= body.length)
                break;
            at = end + newlineWidthAt(body, end);
        }
        if (common == size_t.max)
            common = 0;

        const start = _text.length;
        continued = false;
        for (size_t at = 0; at <= body.length;)
        {
            const end = lineEnd(body, at);
            const line = body[at .. end];
            if (isProtected(at) || continued)
                put(_text, line);
            else
            {
                size_t ws;
                while (ws < line.length && isBlank(line[ws]))
                    ws++;
                if (ws < line.length)
                {
                    put(_text, indent.outer);
                    put(_text, indent.step);
                    put(_text, line[common < ws ? common : ws .. $]);
                }
            }
            continued = endsWithContinuation(line);
            if (end >= body.length)
                break;
            const width = newlineWidthAt(body, end);
            if (isProtected(end))
                put(_text, body[end .. end + width]);
            else
                put(_text, newline);
            at = end + width;
        }
        _fragments ~= FragmentCheck(cast(uint) start, cast(uint)(_text.length - start), op);
    }

    /// Lexes `fragment` to check it is whole nodes and to count them.
    private FragmentShape analyze(scope const(char)[] fragment, uint op)
    {
        FragmentShape shape;
        auto lexer = lexSDL!config(fragment);
        size_t depth;
        bool atStatement = true, open;
        while (!lexer.empty)
        {
            auto item = lexer.front;
            if (item.hasError)
            {
                fail(SdlErrorCode.editFragmentInvalid, SdlSpan.init, "the fragment does not lex", op);
                return shape;
            }
            const kind = item.valueOf.kind;
            with (SdlTokenKind) switch (kind)
            {
            case eof:
                break;
            case newline:
                if (depth == 0 && shape.nodes)
                    shape.multiLine = true;
                goto case semicolon;
            case semicolon:
                atStatement = true;
                open = false;
                break;
            case openBrace:
                depth++;
                shape.hasBlock = true;
                open = false;
                break;
            case closeBrace:
                if (depth == 0)
                {
                    fail(SdlErrorCode.editFragmentInvalid, SdlSpan.init,
                        "the fragment closes a block it did not open", op);
                    return shape;
                }
                depth--;
                break;
            default:
                if (atStatement)
                {
                    shape.nodes++;
                    if (depth == 0)
                        shape.topLevel++;
                    atStatement = false;
                    open = true;
                }
                break;
            }
            lexer.popFront();
        }
        if (depth != 0 || shape.topLevel == 0)
        {
            fail(SdlErrorCode.editFragmentInvalid, SdlSpan.init,
                depth ? "the fragment leaves a block open" : "the fragment holds no node", op);
            return shape;
        }
        shape.valid = true;
        return shape;
    }

    private static const(char)[] trimNode(return scope const(char)[] text) @safe pure nothrow @nogc
    {
        size_t start, end = text.length;
        while (start < end && (isBlank(text[start]) || newlineWidthAt(text, start)))
            start++;
        while (end > start && (isBlank(text[end - 1]) || text[end - 1] == '\n'
            || text[end - 1] == '\r' || text[end - 1] == ';'))
            end--;
        return text[start .. end];
    }

    // ── Layout queries over the host ───────────────────────────────────

    /// Whether `at` begins a line: the content start after a byte-order mark
    /// or the start of the host, or just after a logical newline.
    private bool lineStartAt(size_t at) const
    {
        if (at == 0 || (at == _core.lines.lineStart(0) && _recipe.found == false))
            return true;
        foreach (width; newlineWidths)
            if (at >= width && newlineWidthAt(_host, at - width) == width)
                return true;
        return false;
    }

    /// The start of the line containing `at`, never before the content.
    private size_t lineStart(size_t at) const
    {
        size_t start = at;
        while (start > _content.startOffset && !lineStartAt(start))
            start--;
        return start;
    }

    /// Where the spaces and tabs before `at` on its line begin.
    private size_t lineIndentStart(size_t at) const
    {
        size_t start = at;
        while (start > _content.startOffset && isBlank(_host[start - 1]))
            start--;
        return start;
    }

    /// The leading spaces and tabs of the line containing `at`.
    private const(char)[] lineIndent(size_t at) const
    {
        // A line clipped by the content start (an embedded recipe that starts
        // after `dub.sdl:`) has no indentation of its own.
        const start = lineStart(at);
        if (!lineStartAt(start))
            return null;
        size_t end = start;
        while (end < _host.length && isBlank(_host[end]))
            end++;
        return _host[start .. end];
    }

    /// The newline SDE4 inserts at `at`: the one ending its line, else the
    /// nearest preceding line's, else `\n`.
    private const(char)[] newlineFor(size_t at) const
    {
        foreach (i; at .. _host.length)
            if (const width = newlineWidthAt(_host, i))
                return _host[i .. i + width];
        foreach_reverse (i; 0 .. at)
            if (const width = newlineWidthAt(_host, i))
                return i > 0 && width == 1 && _host[i] == '\n' && _host[i - 1] == '\r'
                    ? _host[i - 1 .. i + 1] : _host[i .. i + width];
        return "\n";
    }

    /// The document's first indentation step, else four spaces.
    private const(char)[] indentStep() const
    {
        size_t parentStart = size_t.max;
        foreach (i, ref cell; _core.nodes)
        {
            if (i == 0)
                continue;
            if (cell.depth == 0)
                parentStart = cell.span.startOffset;
            else if (cell.depth == 1 && parentStart != size_t.max && cell.aloneOnLines)
            {
                const outer = lineIndent(parentStart), inner = lineIndent(cell.span.startOffset);
                if (inner.length > outer.length && inner[0 .. outer.length] == outer)
                    return inner[outer.length .. $];
            }
        }
        return "    ";
    }

    /// Indentation for a new child of `parent`'s block (SDE4): like its last
    /// child, or for an empty block the parent's plus one step.
    private Indent childIndent(scope SdlNode parent) const
    {
        const cell = cellOf(parent);
        if (cell.childCount)
            return Indent(lastChildIndent(parent, ""));
        return Indent(lineIndent(cell.span.startOffset), indentStep());
    }

    private const(char)[] lastChildIndent(scope SdlNode parent, string fallback) const
    {
        const cell = cellOf(parent);
        if (!cell.childCount)
            return fallback;
        return lineIndent(_core.nodes[_core.childIndexes[cell.childStart + cell.childCount - 1]]
            .span.startOffset);
    }

    /// The end of a node's last value, attribute or name.
    private size_t lastItemEnd(scope SdlNode node) const
    {
        size_t end = node.nameSpan.endOffset;
        foreach (value; node.byValue)
            if (value.span.endOffset > end)
                end = value.span.endOffset;
        foreach (attribute; node.byAttribute)
            if (attribute.span.endOffset > end)
                end = attribute.span.endOffset;
        return end;
    }

    /// The end of the token before `attribute`: its node's previous
    /// attribute, last value, or name.
    private size_t previousTokenEnd(scope SdlAttributeView attribute) const
    {
        size_t end = 0;
        foreach (ref cell; _core.nodes)
            if (attribute.cellIndex >= cell.attributeStart
                && attribute.cellIndex < cell.attributeStart + cell.attributeCount)
            {
                end = cell.nameSpan.endOffset;
                foreach (i; cell.valueStart .. cell.valueStart + cell.valueCount)
                    end = _core.values[i].value.span.endOffset;
                foreach (i; cell.attributeStart .. attribute.cellIndex)
                    end = _core.attributes[i].span.endOffset;
                break;
            }
        return end;
    }

    private bool hasCommentIn(size_t start, size_t end) const
    {
        foreach (ref comment; _core.comments)
            if (comment.span.startOffset < end && comment.span.endOffset > start)
                return true;
        return false;
    }

    /// Whether the `{` of `cell`'s block ends its line; the offset after
    /// that line's newline, or `size_t.max`.
    private size_t openerLineEnd(in SdlNodeCell cell) const
    {
        size_t at = cell.openBrace.endOffset;
        while (at < _host.length)
        {
            if (isBlank(_host[at]))
            {
                at++;
                continue;
            }
            bool skipped;
            foreach (ref comment; _core.comments)
                if (comment.span.startOffset == at)
                {
                    at = comment.span.endOffset;
                    skipped = true;
                    break;
                }
            if (skipped)
                continue;
            const width = newlineWidthAt(_host, at);
            return width ? at + width : size_t.max;
        }
        return size_t.max;
    }

    /// Whether only spaces and tabs precede `cell`'s `}` on its line.
    private bool closeAloneOnLine(in SdlNodeCell cell) const
        => lineStartAt(lineIndentStart(cell.closeBrace.startOffset));

    /// The span of the line containing `at`, without its newline.
    private SdlSpan lineAt(size_t at) const
    {
        const start = lineStart(at);
        return SdlSpan(start, lineEnd(_host, start));
    }

    /// The line before the one starting at `start`, without its newline.
    private SdlSpan previousLine(size_t start) const
    {
        if (start <= _content.startOffset)
            return SdlSpan.init;
        const newline = previousNewlineStart(start);
        return newline == size_t.max ? SdlSpan.init : lineAt(newline);
    }

    /// The start of the newline sequence that ends just before `start`.
    private size_t previousNewlineStart(size_t start) const
    {
        foreach (width; widthsLongestCrLf)
            if (start >= width && start - width >= _content.startOffset
                && newlineWidthAt(_host, start - width) == width)
                return start - width;
        return size_t.max;
    }

    private bool isBlankLine(SdlSpan line) const
    {
        if (!line.isValid)
            return false;
        foreach (c; line.sliceOf(_host))
            if (!isBlank(c))
                return false;
        return true;
    }

    /// The start of the run of comment-only lines directly above `start`.
    private size_t attachedCommentsStart(size_t start) const
    {
        for (;;)
        {
            const line = previousLine(start);
            if (!line.isValid || isBlankLine(line) || !isCommentOnly(line))
                return start;
            start = line.startOffset;
        }
    }

    private bool isCommentOnly(SdlSpan line) const
    {
        size_t at = line.startOffset;
        while (at < line.endOffset && isBlank(_host[at]))
            at++;
        foreach (ref comment; _core.comments)
            if (comment.span.startOffset == at)
            {
                size_t end = comment.span.endOffset;
                while (end < line.endOffset && isBlank(_host[end]))
                    end++;
                return end >= line.endOffset;
            }
        return false;
    }

    private size_t subtreeSize(size_t cell) const
    {
        const depth = _core.nodes[cell].depth;
        size_t end = cell + 1;
        while (end < _core.nodes.length && _core.nodes[end].depth > depth)
            end++;
        return end - cell;
    }

    // ── Writing ────────────────────────────────────────────────────────

    private static void sortEdits(PendingEdit[] edits) @safe pure nothrow @nogc
    {
        // Insertion sort: edit sets are small, and it is stable, so
        // insertions at one point keep the order they were made (SDE3).
        static bool before(in PendingEdit a, in PendingEdit b)
            => a.start != b.start ? a.start < b.start
                : (a.start == a.end) != (b.start == b.end) ? a.start == a.end
                : a.sequence < b.sequence;
        foreach (i; 1 .. edits.length)
        {
            const item = edits[i];
            size_t j = i;
            while (j > 0 && before(item, edits[j - 1]))
            {
                edits[j] = edits[j - 1];
                j--;
            }
            edits[j] = item;
        }
    }

    private auto parseFragment(Allocator)(scope const(char)[] text, ref Allocator allocator)
    {
        static if (stateSize!Allocator == 0)
            return parseSdlDocumentIn!(config, Allocator)(text, null, SdlSpan.init);
        else
            return parseSdlDocumentIn!(config, Allocator)(text, null, SdlSpan.init, allocator);
    }

    private SdlExpected!void reparse(Allocator)(scope const(char)[] output,
        scope const TextEdit[] edits, ref Allocator allocator)
    {
        SdlSpan content = SdlSpan.init;
        UniqueBuffer!char rendering;
        const(char)[] parsedText = output;
        if (_recipe.found)
        {
            // SDE7: DUB ends the recipe at the first `+/`; it must be where the
            // original one maps, and the `/+` count inside must not change.
            const moved = locateEmbeddedRecipe(output);
            const expected = mapOffset(edits, _recipe.close.startOffset);
            if (!moved.found || moved.isJson || moved.close.startOffset != expected
                || countOpeners(moved.recipe(output)) != countOpeners(_recipe.recipe(_host)))
                return sdlErr!void(editError(SdlErrorCode.editFragmentInvalid, SdlSpan.init,
                    "the edit changes where DUB or the D compiler ends the recipe", _operations));
            rendering.reserve(output.length);
            writeEmbeddedRendering(rendering, output, moved);
            parsedText = rendering[];
            content = moved.content;
        }
        static if (stateSize!Allocator == 0)
            auto parsed = parseSdlDocumentIn!(config, Allocator)(parsedText, _sourceName, content);
        else
            auto parsed = parseSdlDocumentIn!(config, Allocator)(parsedText, _sourceName, content,
                allocator);
        if (parsed.hasError)
        {
            auto error = editError(SdlErrorCode.editResultInvalid, parsed.error.span,
                "the edited text does not parse", _operations);
            error.startPosition = parsed.error.startPosition;
            error.endPosition = parsed.error.endPosition;
            return sdlErr!void(error);
        }
        if (_nodeCountKnown
            && cast(long) parsed.document.core.nodes.length != cast(long) _core.nodes.length + _nodeDelta)
            return sdlErr!void(editError(SdlErrorCode.editResultInvalid, SdlSpan.init,
                "the edited text has an unexpected number of nodes", _operations));
        return sdlOk();
    }
}

/// Constructs an editor for `document`, parsed under `config`, over `host`.
auto sdlEditor(SdlParserConfig config = sdlFull, DocumentAllocator)(
    return scope ref const SdlDocument!DocumentAllocator document,
    return scope const(char)[] host)
    => SdlEditor!(config, DocumentAllocator)(document, host);

private bool isBlank(char c) @safe pure nothrow @nogc => c == ' ' || c == '\t';

// Newline widths to look back for: `\r\n` before its `\n`, then U+2028/9.
private static immutable size_t[3] widthsLongestCrLf = [2, 1, 3];
private static immutable size_t[3] newlineWidths = [1, 2, 3];

private bool endsWithNewline(scope const(char)[] text) @safe pure nothrow @nogc
{
    foreach (width; newlineWidths)
        if (text.length >= width && newlineWidthAt(text, text.length - width) == width)
            return true;
    return false;
}

private bool hasNewline(scope const(char)[] text) @safe pure nothrow @nogc
{
    foreach (i; 0 .. text.length)
        if (newlineWidthAt(text, i))
            return true;
    return false;
}

/// The offset of the first logical newline at or after `at`, or the length.
private size_t lineEnd(scope const(char)[] text, size_t at) @safe pure nothrow @nogc
{
    while (at < text.length && !newlineWidthAt(text, at))
        at++;
    return at;
}

private bool endsWithContinuation(scope const(char)[] line) @safe pure nothrow @nogc
{
    size_t end = line.length;
    while (end > 0 && isBlank(line[end - 1]))
        end--;
    return end > 0 && line[end - 1] == '\\';
}

/// Whether `gap` is spaces and tabs, a `\`, and one or more newlines with
/// blank lines — the trivia a continuation leaves between two tokens.
private bool isContinuationGap(scope const(char)[] gap) @safe pure nothrow @nogc
{
    size_t at;
    while (at < gap.length && isBlank(gap[at]))
        at++;
    if (at >= gap.length || gap[at] != '\\')
        return false;
    at++;
    bool newline;
    while (at < gap.length)
    {
        if (isBlank(gap[at]))
            at++;
        else if (const width = newlineWidthAt(gap, at))
        {
            at += width;
            newline = true;
        }
        else
            return false;
    }
    return newline;
}

/// The number of `/+` sequences in `text`.
private size_t countOpeners(scope const(char)[] text) @safe pure nothrow @nogc
{
    size_t count;
    foreach (i; 1 .. text.length)
        if (text[i - 1] == '/' && text[i] == '+')
            count++;
    return count;
}

version (unittest)
{
    private string edited(alias operations)(string source)
    {
        import sparkles.wired.sdl.reader : parseSdlDocument;

        auto parsed = parseSdlDocument!sdlFull(source, "edit.sdl");
        assert(parsed.hasValue, parsed.error.toString);
        auto editor = sdlEditor(parsed.document, source);
        operations(editor, parsed.document.root);
        UniqueBuffer!char output;
        Mallocator allocator;
        const written = editor.write(output, allocator);
        if (written.hasError)
            return "error: " ~ written.error.toString;
        return output[].idup;
    }

    private SdlNode child(SdlNode node, size_t index) @safe
    {
        auto range = node.byChild;
        foreach (_; 0 .. index)
            range.popFront();
        return range.front;
    }
}

@("sdl.editor.replaceValue.keepsEverythingElse")
@system unittest
{
    enum source = "# keep\nname \"old\" // trailing\r\nversion \"1\"\n";
    assert(edited!((ref e, root) => e.replaceValue(child(root, 0), 0, SdlScalar("new")))(source)
        == "# keep\nname \"new\" // trailing\r\nversion \"1\"\n");
}

@("sdl.editor.hostNewlinesAndByteOrderMark")
@system unittest
{
    assert(edited!((ref e, root) => e.append(root, "b 2"))("a 1\rc 3\r") == "a 1\rc 3\rb 2\r");
    assert(edited!((ref e, root) => e.append(root, "b 2\nc 3"))("a 1\u2028") == "a 1\u2028b 2\u2028c 3\u2028");
    assert(edited!((ref e, root) => e.insertBefore(child(root, 0), "b 2"))("\xEF\xBB\xBFa 1\n")
        == "\xEF\xBB\xBFb 2\na 1\n");
    // A multi-line raw string keeps its bytes; the lines around it re-indent.
    assert(edited!((ref e, root) => e.append(child(root, 0), "s `one\n  two`\nt 1"))("x {\n\ty 1\n}\n")
        == "x {\n\ty 1\n\ts `one\n  two`\n\tt 1\n}\n");
}

@("sdl.editor.attributes")
@system unittest
{
    enum source = "dependency \"a\" version=\"*\" optional=true\n";
    // Replace keeps the separator before the attribute.
    assert(edited!((ref e, root) {
        auto attribute = child(root, 0).byAttribute.front;
        e.replaceAttribute(attribute, SdlQualifiedName(null, "path"), SdlScalar("../.."));
    })(source) == "dependency \"a\" path=\"../..\" optional=true\n");
    // Set replaces a singular attribute, inserts a missing one, and is idempotent.
    assert(edited!((ref e, root) => e.setAttribute(child(root, 0),
        SdlQualifiedName(null, "optional"), SdlScalar(false)))(source)
        == "dependency \"a\" version=\"*\" optional=false\n");
    assert(edited!((ref e, root) => e.setAttribute(child(root, 0),
        SdlQualifiedName(null, "default"), SdlScalar(true)))(source)
        == "dependency \"a\" version=\"*\" optional=true default=true\n");
    assert(edited!((ref e, root) => e.setAttribute(child(root, 0),
        SdlQualifiedName(null, "optional"), SdlScalar(true)))(source) == source);
    // Remove takes the spaces before it.
    assert(edited!((ref e, root) => e.removeAttribute(child(root, 0).byAttribute.front))(source)
        == "dependency \"a\" optional=true\n");
    // ... and a continuation that separates it from the previous token.
    assert(edited!((ref e, root) {
        auto range = child(root, 0).byAttribute;
        range.popFront();
        e.removeAttribute(range.front);
    })("d \"a\" v=1 \\\n    o=true\n") == "d \"a\" v=1\n");
    assert(edited!((ref e, root) {
        auto range = child(root, 0).byAttribute;
        range.popFront();
        e.removeAttribute(range.front);
    })("d \"a\" v=1 \\ # why\n    o=true\n").canFindError("comment sits"));
    // A repeated name is ambiguous.
    assert(edited!((ref e, root) => e.setAttribute(child(root, 0),
        SdlQualifiedName(null, "v"), SdlScalar(3)))("d v=1 v=2\n").canFindError("more than once"));
}

version (unittest) private bool canFindError(string output, string needle) @safe pure
{
    import std.algorithm.searching : canFind;

    return output.length > 6 && output[0 .. 6] == "error:" && output.canFind(needle)
        || output.canFind(needle);
}

@("sdl.editor.insertAndAppend.newlinesAndIndentation")
@system unittest
{
    // SDE4's three examples.
    assert(edited!((ref e, root) => e.append(root, "b 2"))("name \"x\"\n") == "name \"x\"\nb 2\n");
    assert(edited!((ref e, root) => e.append(root, "b 2"))("name \"x\"") == "name \"x\"\nb 2");
    assert(edited!((ref e, root) => e.append(root, "b 2\n"))("a 1\r\n") == "a 1\r\nb 2\r\n");
    // Into a block, indented like the last child; into an empty block, one step in.
    assert(edited!((ref e, root) => e.append(child(root, 0), "c 3"))("x {\n\tb 2\n}\n")
        == "x {\n\tb 2\n\tc 3\n}\n");
    assert(edited!((ref e, root) => e.append(child(child(root, 0), 0), "c 3"))("x {\n  b {\n  }\n}\n")
        == "x {\n  b {\n    c 3\n  }\n}\n");
    // A node without a block gains one.
    assert(edited!((ref e, root) => e.append(child(root, 0), "c 3"))("x 1 # c\ny 2\n")
        == "x 1 {\n    c 3\n} # c\ny 2\n");
    // Before and after a whole-line sibling.
    assert(edited!((ref e, root) => e.insertBefore(child(root, 1), "  m 0\n  n 0\n"))("a 1\nb 2\n")
        == "a 1\nm 0\nn 0\nb 2\n");
    assert(edited!((ref e, root) => e.insertAfter(child(root, 0), "m 0"))("  a 1\nb 2\n")
        == "  a 1\n  m 0\nb 2\n");
    // Inline anchors take one node joined with `; `.
    assert(edited!((ref e, root) => e.insertAfter(child(root, 0), "m 0"))("a 1; b 2\n")
        == "a 1; m 0; b 2\n");
    assert(edited!((ref e, root) => e.insertAfter(child(root, 1), "m 0"))("a 1; b 2\n")
        == "a 1; b 2; m 0\n");
    assert(edited!((ref e, root) => e.append(child(root, 0), "m 0"))("a {; b 1; }\n")
        == "a {; b 1; m 0; }\n");
    assert(edited!((ref e, root) => e.insertAfter(child(root, 0), "m 0\nn 0"))("a 1; b 2\n")
        .canFindError("inline anchor"));
}

@("sdl.editor.remove.extentsAndBlankLines")
@system unittest
{
    assert(edited!((ref e, root) => e.remove(child(root, 0)))("a 1; b 2\n") == "b 2\n");
    assert(edited!((ref e, root) => e.remove(child(root, 1)))("a 1; b 2\n") == "a 1;\n");
    assert(edited!((ref e, root) => e.remove(child(child(root, 0), 0)))("a {; b 1; }\n") == "a {; }\n");
    assert(edited!((ref e, root) => e.remove(child(root, 1)))("a 1\n\nb 2\n\nc 3\n") == "a 1\n\nc 3\n");
    assert(edited!((ref e, root) => e.remove(child(root, 1)))("a 1\nb 2") == "a 1");
    // Attached comments go only when asked.
    enum commented = "a 1\n// about b\n# more\nb 2\n";
    assert(edited!((ref e, root) => e.remove(child(root, 1)))(commented) == "a 1\n// about b\n# more\n");
    assert(edited!((ref e, root) => e.remove(child(root, 1), SdlAttachedComments.remove))(commented)
        == "a 1\n");
}

@("sdl.editor.replaceBodyAndRegion")
@system unittest
{
    assert(edited!((ref e, root) => e.replaceBody(child(root, 0), "c 3\nd 4\n"))("x {\n  a 1\n  b 2\n}\n")
        == "x {\n  c 3\n  d 4\n}\n");
    enum managed = "keep 1\n// begin\nold 1\n// end\n";
    assert(edited!((ref e, root) {
        auto comments = root.core.comments;
        const start = comments[0].span.startOffset;
        const end = comments[1].span.endOffset + 1;
        e.replaceRegion(TextSpan(start, end), "// begin\nnew 2\n// end\n");
    })(managed) == "keep 1\n// begin\nnew 2\n// end\n");
}

@("sdl.editor.conflictsAndForeignViews")
@system unittest
{
    import sparkles.wired.sdl.reader : parseSdlDocument;

    assert(edited!((ref e, root) {
        e.replaceValue(child(root, 0), 0, SdlScalar(2));
        e.remove(child(root, 0));
    })("a 1\n").canFindError("overlaps operation"));
    // Insertions at one point apply in the order they were made.
    assert(edited!((ref e, root) {
        e.append(root, "b 2");
        e.append(root, "c 3");
    })("a 1\n") == "a 1\nb 2\nc 3\n");
    // A fragment that is not whole nodes.
    assert(edited!((ref e, root) => e.append(root, "b {"))("a 1\n").canFindError("block open"));
    assert(edited!((ref e, root) => e.append(root, "b 2010/13/45"))("a 1\n")
        .canFindError("does not parse as whole nodes"));
    // A view from another document.
    auto other = parseSdlDocument!sdlFull("z 1\n");
    assert(edited!((ref e, root) => e.remove(other.document.root.byChild.front))("a 1\n")
        .canFindError("another document"));
}

@("sdl.editor.embeddedRecipe")
@system unittest
{
    import sparkles.wired.sdl.embedded : parseEmbeddedSdlDocument;

    enum host = "#!/usr/bin/env dub\n/+ dub.sdl:\n    name \"x\"\n+/\nvoid main() {}\n";
    auto embedded = parseEmbeddedSdlDocument!sdlFull(host, "x.d");
    assert(embedded.parsed.hasValue);
    auto editor = sdlEditor(embedded.parsed.document, host);
    editor.append(embedded.parsed.document.root, "dependency \"y\" version=\"*\"");
    UniqueBuffer!char output;
    Mallocator allocator;
    assert(!editor.write(output, allocator).hasError);
    assert(output[] == "#!/usr/bin/env dub\n/+ dub.sdl:\n    name \"x\"\n"
        ~ "    dependency \"y\" version=\"*\"\n+/\nvoid main() {}\n");

    // A recipe ending on its `+/` line takes a newline before and after.
    enum inline = "/+ dub.sdl: name \"x\" +/\n";
    auto one = parseEmbeddedSdlDocument!sdlFull(inline);
    auto oneEditor = sdlEditor(one.parsed.document, inline);
    oneEditor.append(one.parsed.document.root, "b 2");
    output.clear();
    assert(!oneEditor.write(output, allocator).hasError);
    assert(output[] == "/+ dub.sdl: name \"x\" \nb 2\n+/\n");

    // Text that would end the recipe early is rejected (SDE7).
    auto broken = sdlEditor(embedded.parsed.document, host);
    broken.append(embedded.parsed.document.root, "s \"+/\"");
    output.clear();
    const failed = broken.write(output, allocator);
    assert(failed.hasError && failed.error.code == SdlErrorCode.editFragmentInvalid);
    assert(output.length == 0);
}

version (unittest)
{
    /// A semantic tree for SDE2's reference model: names, canonical value and
    /// attribute spellings, and children, in source order.
    private struct ModelNode
    {
        string name;
        string[] values;
        string[] attributes;
        ModelNode[] children;
    }

    private string canonical(in SdlScalar scalar)
    {
        UniqueBuffer!char text;
        assert(!writeSdlScalar(scalar, text).hasError);
        return text[].idup;
    }

    private string qualified(SdlQualifiedName name)
        => name.namespace_.length ? (name.namespace_ ~ ":" ~ name.localName).idup : name.localName.idup;

    private ModelNode model(SdlNode node)
    {
        ModelNode result = ModelNode(qualified(node.qualifiedName));
        foreach (value; node.byValue)
            result.values ~= canonical(value);
        foreach (attribute; node.byAttribute)
            result.attributes ~= qualified(attribute.qualifiedName) ~ "=" ~ canonical(attribute.value);
        foreach (child; node.byChild)
            result.children ~= model(child);
        return result;
    }

    /// Parses a recipe file, or the recipe a `.d` file embeds.
    private auto parseRecipe(scope const(char)[] text, string path)
    {
        import core.lifetime : move;
        import sparkles.wired.sdl.config : sdlDubRecipe;
        import sparkles.wired.sdl.embedded : parseEmbeddedSdlDocument;
        import sparkles.wired.sdl.reader : parseSdlDocument;

        if (path[$ - 2 .. $] != ".d")
            return parseSdlDocument!sdlDubRecipe(text, path);
        auto embedded = parseEmbeddedSdlDocument!sdlDubRecipe(text, path);
        return move(embedded.parsed);
    }

    /// Every `dub.sdl` and every embedded recipe under `apps`, `libs` and `docs`.
    private string[] repositoryRecipes()
    {
        import sparkles.wired.sdl.embedded : hasEmbeddedRecipeHeader;
        import std.file : dirEntries, exists, readText, SpanMode;
        import std.path : buildNormalizedPath, dirName, extension;
        import std.algorithm.searching : canFind;

        const root = buildNormalizedPath(__FILE_FULL_PATH__.dirName, "../../../../../..");
        string[] paths;
        foreach (top; ["apps", "libs", "docs"])
        {
            const dir = buildNormalizedPath(root, top);
            if (!dir.exists)
                continue;
            foreach (entry; dirEntries(dir, SpanMode.depth))
            {
                const path = entry.name;
                if (path.canFind("/.dub/") || path.canFind("/node_modules/") || path.canFind("/build/")
                    || !entry.isFile)
                    continue;
                if (path[$ - 8 .. $] == "/dub.sdl"
                    || (path.extension == ".d" && hasEmbeddedRecipeHeader(readText(path))))
                    paths ~= path;
            }
        }
        return paths;
    }
}

@("sdl.editor.properties.repositoryRecipes")
@system unittest
{
    import core.exception : AssertError;
    import std.file : readText;
    import sparkles.wired.sdl.config : sdlDubRecipe;

    const paths = repositoryRecipes();
    assert(paths.length > 100, "the repository walk found too few recipes");

    // One operation, its target's expected changed range, and the model edit.
    enum Op { replaceValue, setAttribute, removeAttribute, remove, appendRoot, appendChild, insertBefore }

    static string opName(Op op)
    {
        import std.conv : to;

        return op.to!string;
    }

    size_t checked;
    foreach (path; paths)
    {
        const host = readText(path);
        foreach (op; [Op.replaceValue, Op.setAttribute, Op.removeAttribute, Op.remove,
            Op.appendRoot, Op.appendChild, Op.insertBefore])
        {
            auto parsed = parseRecipe(host, path);
            if (!parsed.hasValue)
                continue; // a JSON recipe, or a fixture that is meant to fail
            auto root = parsed.document.root;
            auto expected = model(root);
            auto editor = sdlEditor!sdlDubRecipe(parsed.document, host);
            SdlSpan range; // what SDE1 allows to change
            bool applied;

            // Targets: the first node with a value, an attribute, or a block.
            size_t i = size_t.max;
            foreach (node; root.byChild)
            {
                i++;
                final switch (op)
                {
                case Op.replaceValue:
                    if (!node.valueCount || node.byValue.front.kind != SdlScalarKind.string_)
                        continue;
                    editor.replaceValue(node, 0, SdlScalar("edited"));
                    range = node.byValue.front.span;
                    expected.children[i].values[0] = `"edited"`;
                    break;
                case Op.setAttribute:
                    editor.setAttribute(node, SdlQualifiedName(null, "probe"), SdlScalar("p"));
                    range = SdlSpan(node.nameSpan.startOffset, node.span.endOffset);
                    expected.children[i].attributes ~= `probe="p"`;
                    break;
                case Op.removeAttribute:
                    if (!node.attributeCount)
                        continue;
                    editor.removeAttribute(node.byAttribute.front);
                    range = SdlSpan(node.nameSpan.startOffset, node.byAttribute.front.span.endOffset);
                    expected.children[i].attributes = expected.children[i].attributes[1 .. $];
                    break;
                case Op.remove:
                    editor.remove(node);
                    range = node.extent;
                    expected.children = expected.children[0 .. i] ~ expected.children[i + 1 .. $];
                    break;
                case Op.appendRoot:
                    editor.append(root, "probe \"p\"");
                    range = SdlSpan.at(editor._content.endOffset);
                    expected.children ~= ModelNode("probe", [`"p"`]);
                    break;
                case Op.appendChild:
                    if (!node.hasBlock)
                        continue;
                    editor.append(node, "probe \"p\"");
                    // The point is the start of the `}` line.
                    const close = node.core.nodes[node.cellIndex].closeBrace.startOffset;
                    size_t lineStart = close;
                    while (lineStart > 0 && (host[lineStart - 1] == ' ' || host[lineStart - 1] == '\t'))
                        lineStart--;
                    range = SdlSpan(lineStart, close);
                    expected.children[i].children ~= ModelNode("probe", [`"p"`]);
                    break;
                case Op.insertBefore:
                    editor.insertBefore(node, "probe \"p\"");
                    range = SdlSpan.at(node.extent.startOffset);
                    expected.children = expected.children[0 .. i] ~ ModelNode("probe", [`"p"`])
                        ~ expected.children[i .. $];
                    break;
                }
                applied = true;
                break;
            }
            if (!applied)
                continue;

            UniqueBuffer!char output;
            Mallocator allocator;
            const written = editor.write(output, allocator);
            if (written.hasError)
                throw new AssertError(path ~ ": " ~ opName(op) ~ ": " ~ written.error.toString);

            // SDE1: every byte outside the allowed range survives in place —
            // the output keeps the host's bytes before it and after it. A
            // removal may also take the blank line or newline SDE5 names.
            const result = output[];
            size_t low = range.startOffset, high = range.endOffset;
            if (op == Op.remove)
                while (low > 0 && (host[low - 1] == '\n' || host[low - 1] == '\r'
                    || host[low - 1] == ' ' || host[low - 1] == '\t'))
                    low--;
            const tail = host.length - high;
            if (result.length < low + tail || result[0 .. low] != host[0 .. low]
                || result[$ - tail .. $] != host[high .. $])
                throw new AssertError(path ~ ": " ~ opName(op) ~ " changed bytes outside its range");

            // SDE2: the output means the edited model.
            auto reparsed = parseRecipe(result, path);
            if (!reparsed.hasValue)
                throw new AssertError(path ~ ": " ~ opName(op) ~ ": " ~ reparsed.error.toString);
            if (model(reparsed.document.root) != expected)
                throw new AssertError(path ~ ": " ~ opName(op) ~ " changed the wrong meaning");
            checked++;
        }
    }
    assert(checked > 500);
}

@("sdl.editor.replacementsSurviveGrowthAndMoves")
@system unittest
{
    import core.lifetime : move;
    import sparkles.wired.sdl.reader : parseSdlDocument;

    // SDE10: enough replacement text to regrow the buffer several times,
    // then a move, then the write.
    enum source = "a 0\nb 0\nc 0\nd 0\ne 0\nf 0\ng 0\nh 0\n";
    auto parsed = parseSdlDocument!sdlFull(source);
    auto editor = sdlEditor(parsed.document, source);
    size_t i;
    foreach (node; parsed.document.root.byChild)
    {
        char[64] long_ = 'x';
        long_[0] = cast(char)('a' + i++);
        editor.replaceValue(node, 0, SdlScalar(long_[].idup));
    }
    auto moved = move(editor);
    UniqueBuffer!char output;
    Mallocator allocator;
    assert(!moved.write(output, allocator).hasError);
    i = 0;
    foreach (line; [ "a", "b", "c", "d", "e", "f", "g", "h" ])
    {
        import std.algorithm.searching : canFind;

        char[64] expected = 'x';
        expected[0] = cast(char)('a' + i++);
        assert(output[].canFind(line ~ " \"" ~ expected[] ~ "\"\n"));
    }
}

@("sdl.editor.nogc")
@safe pure nothrow @nogc unittest
{
    import sparkles.wired.sdl.reader : parseSdlDocument;

    enum source = "name \"x\"\ndependency \"a\" version=\"*\"\nold 1\n";
    auto parsed = parseSdlDocument!sdlFull(source);
    assert(parsed.hasValue);
    auto editor = sdlEditor(parsed.document, source);
    auto range = parsed.document.root.byChild;
    editor.replaceValue(range.front, 0, SdlScalar("y"));
    range.popFront();
    editor.setAttribute(range.front, SdlQualifiedName(null, "path"), SdlScalar("../.."));
    range.popFront();
    editor.remove(range.front);
    editor.append(parsed.document.root, "new 2");
    UniqueBuffer!char output;
    Mallocator allocator;
    assert(!editor.write(output, allocator).hasError);
    assert(output[] == "name \"y\"\ndependency \"a\" version=\"*\" path=\"../..\"\nnew 2\n");
}
