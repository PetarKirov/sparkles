/** Lossless SDL editing (editing spec, SDE1–SDE10 and SDE18).

An `SdlEditor` borrows a parsed document and the host text it came from — the
recipe itself, or the D program that embeds it — and accumulates edits stated
through the document's views. Each operation resolves at once to byte-range
replacements of the host ($(REF TextEdit, sparkles,base,text,edits)) confined
to the range the spec names; writing renders the edited host into the
editor's buffer, re-parses it, and only then copies it out. Nothing the
operations do not name changes: comments, quoting, blank lines, indentation
and line endings elsewhere survive byte for byte. A move resolves to a
removal and an insertion whose text is composed at writing, from the moved
bytes and the edits made inside them.
*/
module sparkles.wired.sdl.editor;

import std.experimental.allocator.common : stateSize;
import std.experimental.allocator.mallocator : Mallocator;
import std.range.primitives : ElementType, isInputRange, put;

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
import sparkles.wired.sdl.reader : parseSdlDocumentIn, reparseEdited, SdlParseResult;
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
    uint move; // 1-based move whose removal or insertion this is, else 0
    uint cell; // the node a whole-node replacement replaces, else 0
}

/// A node's bytes moved to another point (SDE18). The insertion's text is
/// composed when the editor writes, from the edits made inside those bytes.
private struct PendingMove
{
    uint start, end; // the moved bytes: the attached comments through the extent
    uint cell, extentStart; // the moved node, and where its own lines begin
    uint point; // where they go
    uint indentStart, indentLength; // the destination's indentation, in the host
    bool reindent; // whether it differs from the moved node's
    uint operation;
}

/// Preorder cells `[first, end)` of the borrowed document that an operation
/// replaces, so they lose their identity on a commit (§9).
package struct SdlReplacedCells
{
    uint first, end;
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
    private UniqueBuffer!SdlReplacedCells _replaced;
    private UniqueBuffer!PendingMove _moves;
    private UniqueBuffer!char _composed; // the moves' texts, as of the last render
    private UniqueBuffer!TextSpan _moveTexts; // each move's text in `_composed`
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

    /// Replaces every attribute of `attributes` — a selection (editing
    /// §3.2) or any range of them — in order, as the single form does (SDS5).
    void replaceAttribute(Attributes)(scope Attributes attributes, SdlQualifiedName name,
        in SdlScalar value)
    if (isInputRange!Attributes && is(ElementType!Attributes : const SdlAttributeView))
    {
        foreach (attribute; attributes)
            replaceAttribute(attribute, name, value);
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

    /// Sets attribute `name` of every node of `nodes`, in order (SDS5).
    void setAttribute(Nodes)(scope Nodes nodes, SdlQualifiedName name, in SdlScalar value)
    if (isInputRange!Nodes && is(ElementType!Nodes : const SdlNode))
    {
        foreach (node; nodes)
            setAttribute(node, name, value);
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

    /// Removes every attribute of `attributes`, in order (SDS5).
    void removeAttribute(Attributes)(scope Attributes attributes)
    if (isInputRange!Attributes && is(ElementType!Attributes : const SdlAttributeView))
    {
        foreach (attribute; attributes)
            removeAttribute(attribute);
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
        size_t attached;
        const range = removalRange(cellOf(node), comments, attached);
        _nodeDelta -= subtreeSize(node.cellIndex);
        replaces(node.cellIndex, node.cellIndex + subtreeSize(node.cellIndex));
        record(range, _text.length, op);
    }

    /** Moves `node`, with the comment lines attached above it, to just after
    `sibling` (SDE18): its old place goes as `remove` with
    `SdlAttachedComments.remove` removes it, and its bytes arrive where
    `insertAfter(sibling, …)` inserts, re-indented when the indentation
    there differs. Edits made inside the moved bytes, before or after the
    move, travel with them; insertions just before or after them stay. Both
    nodes must be alone on their lines. */
    void moveAfter(scope SdlNode node, scope SdlNode sibling)
    {
        const op = begin();
        moveBeside(node, sibling, op, true);
    }

    /// Moves `node` and its attached comments to just before `sibling`, as
    /// `moveAfter` does (SDE18).
    void moveBefore(scope SdlNode node, scope SdlNode sibling)
    {
        const op = begin();
        moveBeside(node, sibling, op, false);
    }

    /// Removes every node of `nodes`, in order, as the single form does
    /// (SDS5); a node inside another removed one is `editConflict`.
    void remove(Nodes)(scope Nodes nodes, SdlAttachedComments comments = SdlAttachedComments.keep)
    if (isInputRange!Nodes && is(ElementType!Nodes : const SdlNode))
    {
        foreach (node; nodes)
            remove(node, comments);
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
        _nodeDelta -= subtreeSize(node.cellIndex) - 1;
        _nodeDelta += shape.nodes;
        replaces(node.cellIndex + 1, node.cellIndex + subtreeSize(node.cellIndex));
        const start = _text.length;
        if (shape.nodes)
        {
            reindent(fragment, childIndent(node), newlineFor(bodyStart), op);
            put(_text, newlineFor(bodyStart));
        }
        record(SdlSpan(bodyStart, bodyEnd), start, op);
    }

    /** Replaces `node`'s positional values with `values`, canonically
    spelled: the range from its first value to its last, or the point after
    its name when it has none; values removed take the spaces before them. */
    void setValues(scope SdlNode node, scope const SdlScalar[] values)
    {
        const op = begin();
        if (!owns(node.core) || !isNonRoot(node))
            return;
        size_t first = size_t.max, last;
        foreach (value; node.byValue)
        {
            if (first == size_t.max)
                first = value.span.startOffset;
            last = value.span.endOffset;
        }
        const start = _text.length;
        foreach (i, ref value; values)
        {
            if (i || first == size_t.max)
                put(_text, " ");
            if (!renderScalar(value, node.nameSpan))
                return;
        }
        if (first == size_t.max)
            record(SdlSpan.at(node.nameSpan.endOffset), start, op);
        else if (values.length)
            record(SdlSpan(first, last), start, op);
        else
            record(SdlSpan(node.nameSpan.endOffset, last), start, op);
    }

    /// Inserts ` name=value` after `node`'s last value, attribute or name,
    /// whatever attributes it already has of that name.
    void insertAttribute(scope SdlNode node, SdlQualifiedName name, in SdlScalar value)
    {
        const op = begin();
        if (!owns(node.core) || !isNonRoot(node))
            return;
        const start = _text.length;
        put(_text, " ");
        if (!renderAttribute(name, value, node.nameSpan))
            return;
        record(SdlSpan.at(lastItemEnd(node)), start, op);
    }

    /** Replaces `node` — its extent when it is alone on its lines, else its
    declaration up to its terminator — with `fragment`, re-indented like it. */
    void replaceNode(scope SdlNode node, scope const(char)[] fragment)
    {
        const op = begin();
        if (!owns(node.core) || !isNonRoot(node))
            return;
        const cell = cellOf(node);
        const shape = analyze(fragment, op);
        if (!shape.valid)
            return;
        _nodeDelta += cast(long) shape.nodes - cast(long) subtreeSize(node.cellIndex);
        replaces(node.cellIndex, node.cellIndex + subtreeSize(node.cellIndex));
        const start = _text.length;
        if (cell.aloneOnLines)
        {
            const newline = newlineFor(cell.span.startOffset);
            reindent(fragment, Indent(lineIndent(cell.span.startOffset)), newline, op);
            if (!(cell.extent.endOffset == _host.length && !endsWithNewline(_host)))
                put(_text, newline);
            return record(cell.extent, start, op, 0, cast(uint) node.cellIndex);
        }
        if (shape.topLevel != 1 || shape.hasBlock || shape.multiLine)
            return fail(SdlErrorCode.editUnsupportedLayout, cell.span,
                "an inline node takes one single-line node without a block", op);
        const node_ = trimNode(fragment);
        put(_text, node_);
        _fragments ~= FragmentCheck(cast(uint) start, cast(uint) node_.length, op);
        // Through its last token, so a trailing comment and the terminator stay.
        const end = cell.hasBlock ? cell.closeBrace.endOffset : lastItemEnd(node);
        record(SdlSpan(cell.span.startOffset, end), start, op);
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
        // Every node sharing a byte with the region loses its identity (§9).
        foreach (cell; 1 .. _core.nodeCount)
        {
            const span = _core.nodeAt(cell).span;
            if (span.startOffset < region.endOffset && region.startOffset < span.endOffset)
                replaces(cell, cell + subtreeSize(cell));
        }
        const start = _text.length;
        put(_text, text);
        record(SdlSpan(region.startOffset, region.endOffset), start, op);
    }

    /** Renders the edited host, re-parses it with `allocator` (SDE2, and the
    embedded-recipe checks of SDE7), then copies it to `writer`; on any
    failure nothing reaches `writer`. The editor is unchanged, so the same set
    may be written again. With no edits the host is written as it is, and
    nothing is parsed: it is the borrowed document's own text (§10). */
    SdlExpected!void write(Writer, Allocator)(ref Writer writer, ref Allocator allocator)
    {
        UniqueBuffer!char output;
        UniqueBuffer!TextEdit edits;
        SdlParseResult!Allocator parsed;
        auto rendered = render(allocator, output, edits, parsed);
        if (rendered.hasError)
            return rendered;
        // A localized re-parse keeps the output as its source (§10.1).
        put(writer, output.length || !parsed.hasValue ? output[] : parsed.document.source);
        return sdlOk();
    }

    /** Package seam for commits (§9): renders the edited host into `output`,
    the resolved edits — sorted, borrowing the editor's text — into `edits`,
    and the checked re-parse of the output into `parsed`; `write` without the
    copy. With no edits the output is the host and `parsed` stays empty: the
    borrowed document is the output's parse. A recipe's re-parse that
    localizes keeps the output as its source and leaves `output` empty
    (editing §10.1). */
    package SdlExpected!void render(Allocator)(ref Allocator allocator,
        ref UniqueBuffer!char output, ref UniqueBuffer!TextEdit edits,
        ref SdlParseResult!Allocator parsed)
    {
        if (_failed)
            return sdlErr!void(_failure);

        UniqueBuffer!PendingEdit sorted;
        sorted.reserve(_edits.length);
        foreach (ref e; _edits[])
            sorted ~= e;
        sortEdits(sorted[]);
        if (_moves.length)
        {
            const composed = composeMoves(sorted);
            if (composed.hasError)
                return composed;
        }

        edits.clear(releaseStorage: false);
        edits.reserve(sorted.length);
        foreach (ref e; sorted[])
            edits ~= TextEdit(TextSpan(e.start, e.end), textOf(e));
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
            auto fragment = parseFragment(_text[check.textStart .. check.textStart + check.textLength],
                allocator);
            if (fragment.hasError)
                return sdlErr!void(editError(SdlErrorCode.editFragmentInvalid, SdlSpan.init,
                    "a fragment does not parse as whole nodes", check.operation));
        }

        output.clear(releaseStorage: false);
        output.reserve(_host.length + _text.length);
        writeEdited(output, _host, edits[]);

        return reparse(output, edits[], allocator, parsed);
    }

    /// Package seam: the cells the operations so far replace (§9).
    package const(SdlReplacedCells)[] replaced() const return scope => _replaced[];

    /// Package seam: whether the editor borrows the document whose core is
    /// `core`.
    package bool borrows(scope const(SdlCore)* core) const => core is _core;

    /** Package seam: after a commit replaced the borrowed document, every
    further operation and write fails instead of reading freed cells. */
    package void retire()
    {
        _core = null;
        _host = null;
        _failed = false;
        fail(SdlErrorCode.editTargetMissing, SdlSpan.init,
            "the editor's document was committed");
    }

    /// Package seam: records `error` as the editor's failure, for layers
    /// built on the editor (the typed write-back) whose own steps fail.
    package void failWith(SdlError error)
    {
        if (_failed)
            return;
        _failure = error;
        _failed = true;
    }

    /// Package seam: whether `node` belongs to the editor's document.
    package bool edits(scope SdlNode node) const => node.core is _core;

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
        => (() @trusted => _core.nodeAt(node.cellIndex))();

    private void replaces(size_t first, size_t end)
    {
        if (first < end)
            _replaced ~= SdlReplacedCells(cast(uint) first, cast(uint) end);
    }

    private void record(SdlSpan range, size_t textStart, uint operation, uint move = 0,
        uint cell = 0)
    {
        if (range.startOffset < _content.startOffset || range.endOffset > _content.endOffset)
            return fail(SdlErrorCode.editConflict, range, "the edit leaves the content", operation);
        _edits ~= PendingEdit(range.startOffset, range.endOffset, cast(uint) textStart,
            cast(uint)(_text.length - textStart), operation, cast(uint) _edits.length, move, cell);
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

    private void moveBeside(scope SdlNode node, scope SdlNode sibling, uint op, bool after)
    {
        if (!owns(node.core) || !owns(sibling.core) || !isNonRoot(node) || !isNonRoot(sibling))
            return;
        const cell = cellOf(node), target = cellOf(sibling);
        if (!cell.aloneOnLines || !target.aloneOnLines)
            return fail(SdlErrorCode.editUnsupportedLayout, cell.span,
                "a move takes nodes alone on their lines", op);
        const end = node.cellIndex + subtreeSize(node.cellIndex);
        if (sibling.cellIndex >= node.cellIndex && sibling.cellIndex < end)
            return fail(SdlErrorCode.editConflict, target.span,
                "a node cannot move beside itself or into itself", op);
        size_t attached;
        const removal = removalRange(cell, SdlAttachedComments.remove, attached);
        const point = after ? target.extent.endOffset : target.extent.startOffset;
        const from = lineIndent(cell.span.startOffset), to = lineIndent(target.span.startOffset);
        const indentStart = lineStart(target.span.startOffset);
        const move = cast(uint) _moves.length + 1;
        _moves ~= PendingMove(cast(uint) attached, cast(uint) cell.extent.endOffset,
            cast(uint) node.cellIndex, cast(uint) cell.extent.startOffset,
            cast(uint) point, cast(uint) indentStart, cast(uint) to.length, from != to, op);
        replaces(node.cellIndex, end);
        record(removal, _text.length, op, move);
        record(SdlSpan.at(point), _text.length, op, move);
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

    /// Writes `fragment` re-indented into the text buffer (`reindentInto`)
    /// and records the result for the write-time parse.
    private void reindent(scope const(char)[] fragment, in Indent indent,
        scope const(char)[] newline, uint op)
    {
        const start = _text.length;
        reindentInto(_text, fragment, indent, newline);
        _fragments ~= FragmentCheck(cast(uint) start, cast(uint)(_text.length - start), op);
    }

    /** Writes `fragment` into `output`: its common indentation replaced by
    `indent` on every line that begins outside a string or a continued line,
    its line breaks there spelled `newline`, and one final line break
    dropped. */
    private static void reindentInto(ref UniqueBuffer!char output,
        scope const(char)[] fragment, in Indent indent, scope const(char)[] newline)
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

        continued = false;
        for (size_t at = 0; at <= body.length;)
        {
            const end = lineEnd(body, at);
            const line = body[at .. end];
            if (isProtected(at) || continued)
                put(output, line);
            else
            {
                size_t ws;
                while (ws < line.length && isBlank(line[ws]))
                    ws++;
                if (ws < line.length)
                {
                    put(output, indent.outer);
                    put(output, indent.step);
                    put(output, line[common < ws ? common : ws .. $]);
                }
            }
            continued = endsWithContinuation(line);
            if (end >= body.length)
                break;
            const width = newlineWidthAt(body, end);
            if (isProtected(end))
                put(output, body[end .. end + width]);
            else
                put(output, newline);
            at = end + width;
        }
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
        if (at == 0 || (at == _core.lineZero && _recipe.found == false))
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
        foreach (i; 1 .. _core.nodeCount)
        {
            const cell = _core.nodeAt(i);
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
        size_t last = parent.cellIndex + 1;
        foreach (_; 1 .. cell.childCount)
            last += _core.subtreeSizeAt(last);
        return lineIndent(_core.nodeAt(last).span.startOffset);
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
        foreach (k; 0 .. _core.nodeCount)
        {
            const cell = _core.nodeAt(k);
            if (attribute.cellIndex >= cell.attributeStart
                && attribute.cellIndex < cell.attributeStart + cell.attributeCount)
            {
                end = cell.nameSpan.endOffset;
                foreach (i; cell.valueStart .. cell.valueStart + cell.valueCount)
                    end = _core.valueAt(i).value.span.endOffset;
                foreach (i; cell.attributeStart .. attribute.cellIndex)
                    end = _core.attributeAt(i).span.endOffset;
                break;
            }
        }
        return end;
    }

    private bool hasCommentIn(size_t start, size_t end) const
    {
        foreach (comment; _core.comments)
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
            foreach (comment; _core.comments)
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

    /** The range removing `cell` deletes (SDE5): its extent, its attached
    comments when asked, and the blank line or newline SDE5 names. `attached`
    is where the attached comments begin, else the extent's start. */
    private SdlSpan removalRange(in SdlNodeCell cell, SdlAttachedComments comments,
        out size_t attached) const
    {
        size_t start = cell.extent.startOffset, end = cell.extent.endOffset;
        if (cell.aloneOnLines)
        {
            if (comments == SdlAttachedComments.remove)
                start = attachedCommentsStart(start);
            attached = start;
            const before = previousLine(start);
            if (start > _content.startOffset && isBlankLine(before)
                && (end >= _content.endOffset || isBlankLine(lineAt(end))))
                start = before.startOffset;
        }
        else
            attached = start;
        if (end == _host.length && !endsWithNewline(_host) && start > _content.startOffset)
        {
            // The last thing in a host without a final newline: take the
            // newline before it, so the host gains none.
            const previous = previousNewlineStart(start);
            if (previous != size_t.max)
                start = previous;
        }
        return SdlSpan(start, end);
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
        foreach (comment; _core.comments)
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
        return _core.subtreeSizeAt(cell);
    }

    // ── Moves ──────────────────────────────────────────────────────────

    /// The replacement text of `edit`: a move's composed text for its
    /// insertion, else the operation's own.
    private const(char)[] textOf(in PendingEdit edit) const return scope
    {
        if (edit.move && edit.start == edit.end)
        {
            const text = _moveTexts[edit.move - 1];
            return _composed[text.startOffset .. text.endOffset];
        }
        return _text[edit.textStart .. edit.textStart + edit.textLength];
    }

    /** Composes each move's text (SDE18) — its bytes with the edits made
    inside them applied, and the separators SDE4 names at its point — and
    drops those inner edits from `sorted`, which stays sorted. A move whose
    bytes hold another move's removal or insertion is composed after it;
    two moves into each other's bytes are `editConflict`. */
    private SdlExpected!void composeMoves(ref UniqueBuffer!PendingEdit sorted)
    {
        enum ubyte waiting = 0, started = 1, composed = 2;
        _composed.clear(releaseStorage: false);
        _moveTexts.length = _moves.length;
        UniqueBuffer!bool consumed;
        consumed.length = sorted.length;
        consumed[][] = false;
        UniqueBuffer!ubyte state;
        state.length = _moves.length;
        state[][] = waiting;
        UniqueBuffer!size_t stack, inner;
        UniqueBuffer!TextEdit shifted;
        UniqueBuffer!char piece;
        foreach (first; 0 .. _moves.length)
        {
            stack.clear(releaseStorage: false);
            stack ~= first;
            while (stack.length)
            {
                const m = stack[stack.length - 1];
                if (state[m] == composed)
                {
                    stack.length = stack.length - 1;
                    continue;
                }
                innerEdits(sorted[], consumed[], m, inner);
                if (state[m] == waiting)
                {
                    state[m] = started;
                    bool waits;
                    foreach (i; inner[])
                    {
                        if (!sorted[i].move)
                            continue;
                        const dependency = sorted[i].move - 1;
                        if (state[dependency] == started)
                            return sdlErr!void(editError(SdlErrorCode.editConflict, SdlSpan.init,
                                "two moves go into each other's bytes", _moves[m].operation));
                        if (state[dependency] == waiting)
                        {
                            stack ~= dependency;
                            waits = true;
                        }
                    }
                    if (waits)
                        continue;
                }

                // Every move inside is composed: apply what is left inside.
                const move = _moves[m];
                shifted.clear(releaseStorage: false);
                foreach (i; inner[])
                    shifted ~= TextEdit(TextSpan(sorted[i].start - move.start,
                        sorted[i].end - move.start), textOf(sorted[i]));
                const bytes = _host[move.start .. move.end];
                const validation = validateEdits(bytes.length, shifted[]);
                if (validation.hasError)
                {
                    const index = validation.error.index;
                    return sdlErr!void(conflict(sorted[inner[index ? index - 1 : index]],
                        sorted[inner[index]]));
                }
                piece.clear(releaseStorage: false);
                writeEdited(piece, bytes, shifted[]);
                foreach (i; inner[])
                    consumed[i] = true;
                _moveTexts[m] = placeMoved(move, piece[]);
                state[m] = composed;
                stack.length = stack.length - 1;
            }
        }

        size_t kept;
        foreach (i; 0 .. sorted.length)
            if (!consumed[i])
                sorted[kept++] = sorted[i];
        sorted.length = kept;
        return sdlOk();
    }

    /** The indexes in `sorted` of the edits inside move `m`'s bytes not yet
    applied by a move inside them: every edit within them but the move's
    own, an insertion at their start, which stays where it is, and one over
    the node's whole extent that does not replace that node. */
    private void innerEdits(scope const PendingEdit[] sorted, scope const bool[] consumed,
        size_t m, ref UniqueBuffer!size_t inner) const
    {
        const move = _moves[m];
        inner.clear(releaseStorage: false);
        size_t low, high = sorted.length;
        while (low < high)
        {
            const mid = low + (high - low) / 2;
            if (sorted[mid].start < move.start)
                low = mid + 1;
            else
                high = mid;
        }
        for (size_t i = low; i < sorted.length && sorted[i].start < move.end; i++)
        {
            const e = sorted[i];
            // An edit over the node's whole lines replaces it only when it
            // names it; one that names an ancestor (a body) overlaps.
            const whole = e.start <= move.extentStart && e.end == move.end
                && e.start != e.end && e.cell != move.cell;
            if (consumed[i] || e.end > move.end || e.move == m + 1 || whole
                || (e.start == e.end && e.start == move.start))
                continue;
            inner ~= i;
        }
    }

    /** Appends to `_composed` the moved lines `piece` as inserting them at
    the move's point takes them (SDE4): a newline before them when the
    point does not start a line, and their final line break, unless the
    point ends a host that has none. Re-indented when the move asked;
    otherwise byte for byte. */
    private TextSpan placeMoved(in PendingMove move, scope const(char)[] piece)
    {
        const start = _composed.length;
        const newline = newlineFor(move.point);
        size_t length = piece.length;
        foreach (width; widthsLongestCrLf)
            if (length >= width && newlineWidthAt(piece, length - width) == width)
            {
                length -= width;
                break;
            }
        if (!lineStartAt(move.point))
            put(_composed, newline);
        if (move.reindent)
            reindentInto(_composed, piece,
                Indent(_host[move.indentStart .. move.indentStart + move.indentLength]), newline);
        else
            put(_composed, piece[0 .. length]);
        if (!(move.point == _host.length && !endsWithNewline(_host)))
            put(_composed, !move.reindent && length < piece.length ? piece[length .. $] : newline);
        return TextSpan(cast(uint) start, cast(uint) _composed.length);
    }

    // ── Writing ────────────────────────────────────────────────────────

    private static void sortEdits(PendingEdit[] edits) @safe pure nothrow @nogc
    {
        // Stable, so insertions at one point keep the order they were made
        // (SDE3): an insertion sort for the usual handful, a merge sort past
        // it, since a typed write-back can make thousands.
        static bool before(in PendingEdit a, in PendingEdit b)
            => a.start != b.start ? a.start < b.start
                : (a.start == a.end) != (b.start == b.end) ? a.start == a.end
                : a.sequence < b.sequence;
        enum small = 32;
        static void insertionSort(PendingEdit[] edits)
        {
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
        if (edits.length <= small)
            return insertionSort(edits);

        // Bottom-up merge over runs of `small`, alternating two buffers.
        UniqueBuffer!PendingEdit scratch;
        scratch.length = edits.length;
        for (size_t at = 0; at < edits.length; at += small)
            insertionSort(edits[at .. at + small < edits.length ? at + small : edits.length]);
        PendingEdit[] from = edits, to = scratch[];
        for (size_t width = small; width < edits.length; width *= 2)
        {
            for (size_t lo = 0; lo < edits.length; lo += 2 * width)
            {
                const mid = lo + width < edits.length ? lo + width : edits.length;
                const hi = mid + width < edits.length ? mid + width : edits.length;
                size_t i = lo, j = mid, k = lo;
                while (i < mid && j < hi)
                    to[k++] = before(from[j], from[i]) ? from[j++] : from[i++];
                while (i < mid)
                    to[k++] = from[i++];
                while (j < hi)
                    to[k++] = from[j++];
            }
            auto swap = from;
            from = to;
            to = swap;
        }
        if (from.ptr !is edits.ptr)
            edits[] = from[];
    }

    private auto parseFragment(Allocator)(scope const(char)[] text, ref Allocator allocator)
    {
        static if (stateSize!Allocator == 0)
            return parseSdlDocumentIn!(config, Allocator)(text, null, SdlSpan.init);
        else
            return parseSdlDocumentIn!(config, Allocator)(text, null, SdlSpan.init, allocator);
    }

    private SdlExpected!void reparse(Allocator)(ref UniqueBuffer!char output,
        scope const TextEdit[] edits, ref Allocator allocator, ref SdlParseResult!Allocator parsed)
    {
        // No edits: the output is the host, whose parse is the borrowed document.
        if (edits.length == 0)
            return sdlOk();
        SdlSpan content = SdlSpan.init;
        UniqueBuffer!char rendering;
        if (_recipe.found)
        {
            // SDE7: DUB ends the recipe at the first `+/`; it must be where the
            // original one maps, and the `/+` count inside must not change.
            const moved = locateEmbeddedRecipe(output[]);
            const expected = mapOffset(edits, _recipe.close.startOffset);
            if (!moved.found || moved.isJson || moved.close.startOffset != expected
                || countOpeners(moved.recipe(output[])) != countOpeners(_recipe.recipe(_host)))
                return sdlErr!void(editError(SdlErrorCode.editFragmentInvalid, SdlSpan.init,
                    "the edit changes where DUB or the D compiler ends the recipe", _operations));
            rendering.reserve(output.length);
            writeEmbeddedRendering(rendering, output[], moved);
            content = moved.content;
        }
        // Only the edited region is re-parsed when it can be (§10, SDE14),
        // and then the document keeps the text it parsed — the rendering, or
        // a recipe's output — instead of copying it (§10.1).
        auto parsedText = _recipe.found ? &rendering : &output;
        bool localized;
        static if (stateSize!Allocator == 0)
            parsed = reparseEdited!(config, Allocator)(_core, *parsedText, _sourceName, content,
                edits, localized);
        else
            parsed = reparseEdited!(config, Allocator)(_core, *parsedText, _sourceName, content,
                edits, localized, allocator);

        if (parsed.hasError)
        {
            auto error = editError(SdlErrorCode.editResultInvalid, parsed.error.span,
                "the edited text does not parse", _operations);
            error.startPosition = parsed.error.startPosition;
            error.endPosition = parsed.error.endPosition;
            return sdlErr!void(error);
        }
        if (_nodeCountKnown
            && cast(long) parsed.document.core.nodeCount != cast(long) _core.nodeCount + _nodeDelta)
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

@("sdl.editor.move.keepsBytesAndComments")
@system unittest
{
    enum source = "a 1 # a\n// about b\n#  and more\nb  `2`   # b\nc 3\n";
    // The node, its attached comments and its trailing comment go together.
    assert(edited!((ref e, root) => e.moveAfter(child(root, 1), child(root, 2)))(source)
        == "a 1 # a\nc 3\n// about b\n#  and more\nb  `2`   # b\n");
    assert(edited!((ref e, root) => e.moveBefore(child(root, 2), child(root, 0)))(source)
        == "c 3\na 1 # a\n// about b\n#  and more\nb  `2`   # b\n");
    // Edits inside the moved bytes travel with them, made before or after
    // the move; an insertion beside the node stays where it was.
    assert(edited!((ref e, root) {
        e.replaceValue(child(root, 1), 0, SdlScalar(4));
        e.moveAfter(child(root, 1), child(root, 2));
        e.setAttribute(child(root, 1), SdlQualifiedName(null, "x"), SdlScalar(true));
        e.insertAfter(child(root, 1), "n 0");
    })(source) == "a 1 # a\nn 0\nc 3\n// about b\n#  and more\nb  4 x=true   # b\n");
    // So does replacing the moved node itself.
    assert(edited!((ref e, root) {
        e.moveAfter(child(root, 0), child(root, 2));
        e.replaceNode(child(root, 0), "a 9");
    })(source) == "// about b\n#  and more\nb  `2`   # b\nc 3\na 9\n");
    // Several moves to one point arrive in the order they were made.
    assert(edited!((ref e, root) {
        e.moveAfter(child(root, 0), child(root, 2));
        e.moveAfter(child(root, 1), child(root, 2));
    })(source) == "c 3\na 1 # a\n// about b\n#  and more\nb  `2`   # b\n");
    // A swap: each node moves past the other.
    assert(edited!((ref e, root) {
        e.moveAfter(child(root, 0), child(root, 1));
    })("a 1\nb 2\n") == "b 2\na 1\n");
}

@("sdl.editor.move.edgesOfTheHost")
@system unittest
{
    // A host without a final newline gains none and loses none.
    assert(edited!((ref e, root) => e.moveBefore(child(root, 1), child(root, 0)))("a 1\nb 2")
        == "b 2\na 1");
    assert(edited!((ref e, root) => e.moveAfter(child(root, 0), child(root, 1)))("a 1\nb 2")
        == "b 2\na 1");
    // CRLF stays as written; the blank line SDE5 names goes with the removal.
    assert(edited!((ref e, root) => e.moveAfter(child(root, 1), child(root, 2)))(
        "a 1\r\n\r\nb 2\r\n\r\nc 3\r\n") == "a 1\r\n\r\nc 3\r\nb 2\r\n");
}

@("sdl.editor.move.reindentsAndNests")
@system unittest
{
    enum source = "x {\n    // about y\n    y 1 {\n        s `one\n  two`\n    }\n}\nz 2\n";
    // Out of a block: the lines re-indent; the raw string keeps its bytes.
    assert(edited!((ref e, root) => e.moveAfter(child(child(root, 0), 0), child(root, 1)))(source)
        == "x {\n}\nz 2\n// about y\ny 1 {\n    s `one\n  two`\n}\n");
    // Into a block, between a node and its comments: one step in, and an
    // edit inside comes along.
    assert(edited!((ref e, root) {
        e.moveBefore(child(root, 1), child(child(root, 0), 0));
        e.replaceValue(child(root, 1), 0, SdlScalar(3));
    })(source) == "x {\n    // about y\n    z 3\n    y 1 {\n        s `one\n  two`\n    }\n}\n");
    // A moved parent carries a move among its children.
    enum nested = "p {\n  a 1\n  b 2\n}\nq 0\n";
    assert(edited!((ref e, root) {
        e.moveAfter(child(root, 0), child(root, 1));
        e.moveBefore(child(child(root, 0), 1), child(child(root, 0), 0));
    })(nested) == "q 0\np {\n  b 2\n  a 1\n}\n");
    // A move out of a moved parent leaves it first; both arrive in order.
    assert(edited!((ref e, root) {
        e.moveAfter(child(child(root, 0), 0), child(root, 1));
        e.moveAfter(child(root, 0), child(root, 1));
    })(nested) == "q 0\na 1\np {\n  b 2\n}\n");
}

@("sdl.editor.move.manyToOnePoint")
@system unittest
{
    import std.conv : text;

    // Past the insertion sort's run length, the merge keeps creation order.
    string source, expected;
    foreach (i; 0 .. 200)
        source ~= text("n", i, " ", i, "\n");
    foreach (i; 1 .. 200)
        expected ~= text("n", i, " ", i, "\n");
    expected ~= "n0 0\n";
    assert(edited!((ref e, root) {
        auto first = child(root, 0);
        size_t i;
        foreach (node; root.byChild)
            if (i++)
                e.moveBefore(node, first);
    })(source) == expected);
}

@("sdl.editor.move.rejects")
@system unittest
{
    enum source = "p {\n  a 1\n}\nq 0; r 1\n";
    assert(edited!((ref e, root) => e.moveAfter(child(root, 0), child(child(root, 0), 0)))(source)
        .canFindError("into itself"));
    assert(edited!((ref e, root) => e.moveAfter(child(root, 0), child(root, 0)))(source)
        .canFindError("beside itself"));
    assert(edited!((ref e, root) => e.moveAfter(child(root, 1), child(root, 0)))(source)
        .canFindError("alone on their lines"));
    assert(edited!((ref e, root) => e.moveBefore(child(root, 0), child(root, 2)))(source)
        .canFindError("alone on their lines"));
    // An edit across the moved bytes' edge overlaps the removal.
    assert(edited!((ref e, root) {
        e.moveAfter(child(child(root, 0), 0), child(root, 0));
        e.replaceBody(child(root, 0), "c 3");
    })("p {\n  a 1\n}\nq 0\n").canFindError("overlaps operation"));
    // Two moves into each other's bytes.
    assert(edited!((ref e, root) {
        e.moveAfter(child(root, 0), child(child(root, 1), 0));
        e.moveAfter(child(root, 1), child(child(root, 0), 0));
    })("p {\n  a 1\n}\nq {\n  b 2\n}\n").canFindError("each other"));
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
}

@("sdl.editor.properties.repositoryRecipes")
@system unittest
{
    import core.exception : AssertError;
    import std.file : readText;
    import sparkles.wired.sdl.config : sdlDubRecipe;
    import sparkles.wired.sdl.test_corpus : parseRecipe, repositoryRecipes;

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
                    const close = node.core.nodeAt(node.cellIndex).closeBrace.startOffset;

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

@("sdl.editor.properties.movesInRepositoryRecipes")
@system unittest
{
    import core.exception : AssertError;
    import std.algorithm.searching : canFind;
    import std.file : readText;
    import sparkles.wired.sdl.config : sdlDubRecipe;
    import sparkles.wired.sdl.test_corpus : parseRecipe, repositoryRecipes;

    // SDE18 over every recipe: the first child of the root, and of the first
    // block, moves after its last sibling. The output means the rotated
    // model, and holds the moved node's lines byte for byte.
    size_t checked;
    foreach (path; repositoryRecipes())
    {
        const host = readText(path);
        foreach (nested; [false, true])
        {
            auto parsed = parseRecipe(host, path);
            if (!parsed.hasValue)
                continue;
            auto parent = parsed.document.root;
            size_t[] trail; // child indexes from the root to the parent
            if (nested)
            {
                size_t i;
                bool found;
                foreach (node; parent.byChild)
                {
                    if (node.childCount > 1)
                    {
                        parent = node;
                        trail ~= i;
                        found = true;
                        break;
                    }
                    i++;
                }
                if (!found)
                    continue;
            }
            if (parent.childCount < 2)
                continue;
            auto first = child(parent, 0), last = child(parent, parent.childCount - 1);
            if (!first.aloneOnLines || !last.aloneOnLines)
                continue;

            auto expected = model(parsed.document.root);
            auto siblings = &expected;
            foreach (i; trail)
                siblings = &siblings.children[i];
            siblings.children = siblings.children[1 .. $] ~ siblings.children[0];

            auto editor = sdlEditor!sdlDubRecipe(parsed.document, host);
            editor.moveAfter(first, last);
            UniqueBuffer!char output;
            Mallocator allocator;
            const written = editor.write(output, allocator);
            if (written.hasError)
                throw new AssertError(path ~ ": " ~ written.error.toString);
            auto reparsed = parseRecipe(output[], path);
            if (!reparsed.hasValue)
                throw new AssertError(path ~ ": " ~ reparsed.error.toString);
            if (model(reparsed.document.root) != expected)
                throw new AssertError(path ~ ": the move changed the wrong meaning");
            if (!output[].canFind(first.extent.sliceOf(host)[0 .. $ - 1]))
                throw new AssertError(path ~ ": the moved node lost its bytes");
            checked++;
        }
    }
    assert(checked > 150);
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
    const name = range.front;
    editor.replaceValue(name, 0, SdlScalar("y"));
    range.popFront();
    editor.setAttribute(range.front, SdlQualifiedName(null, "path"), SdlScalar("../.."));
    editor.moveAfter(name, range.front);
    range.popFront();
    editor.remove(range.front);
    editor.append(parsed.document.root, "new 2");
    UniqueBuffer!char output;
    Mallocator allocator;
    assert(!editor.write(output, allocator).hasError);
    assert(output[] == "dependency \"a\" version=\"*\" path=\"../..\"\nname \"y\"\nnew 2\n");
}

@("sdl.editor.write.noEditsParsesNothing")
@system pure nothrow @nogc unittest
{
    import sparkles.wired.sdl.embedded : parseEmbeddedSdlDocument;
    import sparkles.wired.sdl.reader : parseSdlDocument;
    import sparkles.wired.sdl.test_corpus : AllocationCounts, CountingAllocator;

    enum source = "name \"x\" // kept\ndependency \"a\" version=\"*\"\n";
    auto parsed = parseSdlDocument!sdlFull(source);
    auto editor = sdlEditor(parsed.document, source);
    AllocationCounts counts;
    auto allocator = CountingAllocator!()(&counts);
    UniqueBuffer!char output;
    assert(!editor.write(output, allocator).hasError);
    assert(output[] == source && counts.calls == 0);

    // An embedded recipe's host is written as it is, too.
    enum host = "#!/usr/bin/env dub\n/+ dub.sdl:\n    name \"p\"\n+/\nvoid main() {}\n";
    auto embedded = parseEmbeddedSdlDocument!sdlFull(host);
    auto embeddedEditor = sdlEditor(embedded.parsed.document, host);
    output.clear();
    assert(!embeddedEditor.write(output, allocator).hasError);
    assert(output[] == host && counts.calls == 0);
}

@("sdl.editor.write.statefulAllocatorLocalizes")
@system pure nothrow @nogc unittest
{
    import sparkles.wired.sdl.reader : parseSdlDocument;
    import sparkles.wired.sdl.test_corpus : AllocationCounts, CountingAllocator;

    UniqueBuffer!char source;
    foreach (i; 0 .. 4000)
        source ~= "node 1 \"two\" k=3 {\n    leaf on\n}\n";
    AllocationCounts fullCounts, writeCounts;
    auto parsed = parseSdlDocument!sdlFull(source[], null, CountingAllocator!()(&fullCounts));
    assert(parsed.hasValue);
    auto editor = sdlEditor(parsed.document, source[]);
    SdlNode last;
    foreach (node; parsed.document.root.byChild)
        last = node;
    editor.replaceValue(last, 0, SdlScalar(10));
    auto allocator = CountingAllocator!()(&writeCounts);
    UniqueBuffer!char output;
    assert(!editor.write(output, allocator).hasError);
    assert(output[][$ - 34 .. $] == "node 10 \"two\" k=3 {\n    leaf on\n}\n");
    // The full parse grows its arrays; the region path sizes them once.
    assert(writeCounts.calls < fullCounts.calls && writeCounts.live == 0);
}
