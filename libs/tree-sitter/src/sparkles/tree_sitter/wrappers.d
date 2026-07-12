/**
RAII wrappers over the tree-sitter C runtime.

Thin, mechanism-only handles — `TsParser`, `TsTree`, `TsQuery`,
`TsQueryCursor` — that own their C object (`@disable this(this)`, dtor
deletes), confine `@trusted` to the narrow C calls, and surface failures as
$(REF TsError, sparkles,tree_sitter,errors) values. Policy (queries as
highlight configs, event assembly, budget defaults) lives in
`sparkles.syntax.ts`.

Cancellation/budget plumbing uses the options APIs introduced in 0.25
(`ts_parser_parse_with_options` / `ts_query_cursor_exec_with_options` with a
progress callback) — the pre-0.25 timeout/cancellation-flag APIs were
removed in 0.26 (the runtime the flake ships) and are never touched.
*/
module sparkles.tree_sitter.wrappers;

import core.time : Duration, MonoTime;

import sparkles.tree_sitter.errors : TsError, TsErrorCode, TsExpected, tsErr, tsOk;
import sparkles.tree_sitter.tree_sitter_c :
    TSLanguage, TSNode, TSParseOptions, TSParseState, TSParser, TSPoint, TSRange,
    TSInput, TSInputEncoding,
    TSQuery, TSQueryCursor, TSQueryCursorOptions, TSQueryCursorState,
    TSQueryError, TSQueryMatch, TSQueryPredicateStep, TSTree,
    ts_language_abi_version,
    ts_node_child, ts_node_child_count,
    ts_node_has_error, ts_node_start_byte, ts_node_end_byte,
    ts_node_start_point, ts_node_end_point, ts_node_string,
    ts_parser_delete, ts_parser_new, ts_parser_parse,
    ts_parser_parse_with_options, ts_parser_reset,
    ts_parser_set_included_ranges, ts_parser_set_language,
    ts_query_capture_count, ts_query_capture_name_for_id,
    ts_query_cursor_delete, ts_query_cursor_did_exceed_match_limit,
    ts_query_cursor_exec, ts_query_cursor_exec_with_options,
    ts_query_cursor_new, ts_query_cursor_next_capture, ts_query_cursor_next_match,
    ts_query_cursor_remove_match,
    ts_query_cursor_set_byte_range, ts_query_cursor_set_match_limit,
    ts_query_delete, ts_query_disable_pattern, ts_query_new,
    ts_query_pattern_count, ts_query_predicates_for_pattern,
    ts_query_string_value_for_id,
    ts_tree_delete, ts_tree_root_node;

/// Guards for a batch parse: a wall-clock budget and/or a host cancellation
/// flag. `Duration.zero` = no budget; both unset = plain uninterruptible parse.
struct ParseGuards
{
    Duration budget;                        /// wall-clock parse budget (zero = unlimited)
    const(shared(bool))* cancelFlag = null; /// checked in the progress callback
}

/// Shared cancellation context for the parse/query progress callbacks.
struct CancelCtx
{
    MonoTime deadline = MonoTime.max; /// `MonoTime.max` = no deadline
    const(shared(bool))* cancelFlag;  /// null = no host cancellation
    bool timedOut;                    /// set by the callback: deadline hit
    bool cancelled;                   /// set by the callback: flag observed

    /// Builds a context from guard values (reads the clock only when needed).
    static CancelCtx from(Duration budget, const(shared(bool))* cancelFlag) @safe nothrow @nogc
    {
        CancelCtx ctx;
        if (budget > Duration.zero)
            ctx.deadline = MonoTime.currTime + budget;
        ctx.cancelFlag = cancelFlag;
        return ctx;
    }

    /// `true` iff any cancellation source is armed.
    bool armed() const scope @safe pure nothrow @nogc
        => deadline != MonoTime.max || cancelFlag !is null;

    /// The polling step shared by both progress callbacks (and the engine's
    /// own event-loop checks): `true` requests cancellation.
    bool shouldCancel() scope @safe nothrow @nogc
    {
        import core.atomic : atomicLoad;

        if (cancelFlag !is null && atomicLoad(*cancelFlag))
        {
            cancelled = true;
            return true;
        }
        if (deadline != MonoTime.max && MonoTime.currTime > deadline)
        {
            timedOut = true;
            return true;
        }
        return false;
    }

    /// The error the interrupted operation should report.
    TsError toError(TsErrorCode timeoutCode, TsErrorCode cancelledCode) const scope @safe pure nothrow @nogc
        => TsError(timedOut ? timeoutCode : cancelledCode);
}

private extern (C) bool parseProgressCallback(TSParseState* state) nothrow @nogc
    => (cast(CancelCtx*) state.payload).shouldCancel();

private extern (C) bool queryProgressCallback(TSQueryCursorState* state) nothrow @nogc
    => (cast(CancelCtx*) state.payload).shouldCancel();

// TSInput.read callback over a D slice (byte-exact UTF-8 feed).
private struct SliceReader
{
    const(char)* ptr;
    size_t length;
}

private extern (C) const(char)* sliceReaderRead(
    void* payload, uint byteIndex, TSPoint, uint* bytesRead) nothrow @nogc
{
    auto s = cast(SliceReader*) payload;
    if (byteIndex >= s.length)
    {
        *bytesRead = 0;
        return s.ptr;
    }
    *bytesRead = cast(uint)(s.length - byteIndex);
    return s.ptr + byteIndex;
}

/// Owning handle over a `TSParser`.
struct TsParser
{
    private TSParser* _raw;

    @disable this(this);

    /// Creates a fresh parser (aborts only on allocation failure).
    static TsParser create() @trusted nothrow @nogc
    {
        auto parser = TsParser(ts_parser_new());
        assert(parser._raw !is null);
        return parser;
    }

    ~this() @trusted nothrow @nogc
    {
        if (_raw !is null)
            ts_parser_delete(_raw);
    }

    /// `true` iff this handle owns a live parser.
    bool valid() const scope @safe pure nothrow @nogc
        => _raw !is null;

    /// Assigns the grammar; fails when the grammar's ABI version is outside
    /// the runtime's supported window.
    TsExpected!void setLanguage(const(TSLanguage)* language) @trusted nothrow @nogc
    in (valid)
    {
        if (!ts_parser_set_language(_raw, cast(TSLanguage*) language))
            return tsErr!void(TsErrorCode.incompatibleAbi,
                language is null ? 0 : ts_language_abi_version(cast(TSLanguage*) language));
        return tsOk();
    }

    /**
    Whole-buffer batch parse. On abort (budget/cancellation) the parser is
    `ts_parser_reset` so the handle stays reusable, and `error` reports
    `parseTimeout`/`parseCancelled`; `parseFailed` covers the no-language
    case. On success returns a valid $(LREF TsTree) and `error` is `none`.

    The 2 GiB input ceiling is structural: tree-sitter uses 32-bit signed
    byte indices.
    */
    TsTree parse(scope const(char)[] source, out TsError error,
        in ParseGuards guards = ParseGuards()) @trusted nothrow
    in (valid)
    {
        if (source.length > cast(size_t) int.max)
        {
            error = TsError(TsErrorCode.sourceTooLarge);
            return TsTree.init;
        }

        auto reader = SliceReader(source.ptr, source.length);
        TSInput input;
        input.payload = &reader;
        input.read = &sliceReaderRead;
        input.encoding = TSInputEncoding.TSInputEncodingUTF8;

        auto ctx = CancelCtx.from(guards.budget, guards.cancelFlag);
        TSTree* rawTree;
        if (ctx.armed)
        {
            TSParseOptions options;
            options.payload = &ctx;
            options.progress_callback = &parseProgressCallback;
            rawTree = ts_parser_parse_with_options(_raw, null, input, options);
        }
        else
            rawTree = ts_parser_parse(_raw, null, input);

        if (rawTree is null)
        {
            ts_parser_reset(_raw);
            error = ctx.timedOut || ctx.cancelled
                ? ctx.toError(TsErrorCode.parseTimeout, TsErrorCode.parseCancelled)
                : TsError(TsErrorCode.parseFailed);
            return TsTree.init;
        }

        error = TsError.init;
        return TsTree(rawTree);
    }

    /**
    Restricts subsequent parses to `ranges` — the byte/point spans an injected
    layer occupies in the parent buffer (must be ascending and non-overlapping).
    Returns `false` (and keeps the previous ranges) if tree-sitter rejects them;
    an empty slice resets to the whole buffer. The parser reads the same source
    slice as the root — only the included ranges differ per layer.
    */
    bool setIncludedRanges(scope const(TSRange)[] ranges) @trusted nothrow @nogc
    in (valid)
    {
        // ImportC drops the C `const` on the pointer param; cast at the boundary
        // (tree-sitter copies the ranges and never mutates them).
        return ts_parser_set_included_ranges(_raw, cast(TSRange*) ranges.ptr,
            cast(uint) ranges.length);
    }
}

/// Owning handle over a `TSTree`.
struct TsTree
{
    private TSTree* _raw;

    @disable this(this);

    ~this() @trusted nothrow @nogc
    {
        if (_raw !is null)
            ts_tree_delete(_raw);
    }

    /// `true` iff this handle owns a live tree.
    bool valid() const scope @safe pure nothrow @nogc
        => _raw !is null;

    /// The root node (only on a valid tree).
    TSNode rootNode() const scope @trusted nothrow @nogc
    in (valid)
    {
        return ts_tree_root_node(cast(TSTree*) _raw);
    }

    /// `true` iff the parse recovered from errors anywhere in the tree
    /// (diagnostic only — highlighting proceeds regardless).
    bool rootHasError() const scope @trusted nothrow @nogc
    in (valid)
    {
        return ts_node_has_error(ts_tree_root_node(cast(TSTree*) _raw));
    }
}

/// Writes `node`'s S-expression (via `ts_node_string`) into any writer.
void writeSExpression(Writer)(ref Writer w, TSNode node) @trusted
{
    import core.stdc.stdlib : free;
    import std.range.primitives : put;

    char* s = ts_node_string(node);
    if (s is null)
        return;
    scope (exit) free(s);
    size_t n = 0;
    while (s[n] != '\0')
        ++n;
    put(w, s[0 .. n]);
}

// ── Node accessors ──────────────────────────────────────────────────────────
// `TSNode` is a small POD value type (no ownership), so these are free helpers
// rather than a wrapper; the engine already reads nodes via raw `ts_node_*`.

/// The node's byte+point extent as a `TSRange` — the shape
/// $(LREF TsParser.setIncludedRanges) consumes when building an injected layer.
TSRange nodeRange(TSNode node) @trusted nothrow @nogc
{
    TSRange r;
    r.start_byte = ts_node_start_byte(node);
    r.end_byte = ts_node_end_byte(node);
    r.start_point = ts_node_start_point(node);
    r.end_point = ts_node_end_point(node);
    return r;
}

/// Start byte offset of `node`.
uint nodeStartByte(TSNode node) @trusted nothrow @nogc
    => ts_node_start_byte(node);

/// End byte offset of `node` (exclusive).
uint nodeEndByte(TSNode node) @trusted nothrow @nogc
    => ts_node_end_byte(node);

/// Number of children of `node`, named and anonymous.
uint nodeChildCount(TSNode node) @trusted nothrow @nogc
    => ts_node_child_count(node);

/// The `i`-th child of `node` (named or anonymous).
TSNode nodeChild(TSNode node, uint i) @trusted nothrow @nogc
    => ts_node_child(node, i);

/// Owning handle over a compiled `TSQuery`.
struct TsQuery
{
    private TSQuery* _raw;

    @disable this(this);

    /**
    Compiles `source` (query S-expressions, e.g. a `highlights.scm`) for
    `language`. On failure returns an invalid handle and sets `error` to the
    mapped `TSQueryError` (with the byte offset in `detail`).
    */
    static TsQuery create(const(TSLanguage)* language, scope const(char)[] source,
        out TsError error) @trusted nothrow @nogc
    {
        uint errorOffset;
        TSQueryError errorType;
        auto raw = ts_query_new(cast(TSLanguage*) language, source.ptr, cast(uint) source.length,
            &errorOffset, &errorType);
        if (raw is null)
        {
            error = TsError(mapQueryError(errorType), errorOffset);
            return TsQuery.init;
        }
        error = TsError.init;
        return TsQuery(raw);
    }

    ~this() @trusted nothrow @nogc
    {
        if (_raw !is null)
            ts_query_delete(_raw);
    }

    /// `true` iff this handle owns a live query.
    bool valid() const scope @safe pure nothrow @nogc
        => _raw !is null;

    /// Number of patterns in the query.
    uint patternCount() const scope @trusted nothrow @nogc
    in (valid)
    {
        return ts_query_pattern_count(cast(TSQuery*) _raw);
    }

    /// Number of distinct captures in the query.
    uint captureCount() const scope @trusted nothrow @nogc
    in (valid)
    {
        return ts_query_capture_count(cast(TSQuery*) _raw);
    }

    /// The capture name behind a capture id (borrowed from the query).
    const(char)[] captureName(uint captureId) const scope @trusted nothrow @nogc
    in (valid)
    {
        uint length;
        const p = ts_query_capture_name_for_id(cast(TSQuery*) _raw, captureId, &length);
        return p[0 .. length];
    }

    /// The literal behind a string value id (predicate arguments).
    const(char)[] stringValue(uint valueId) const scope @trusted nothrow @nogc
    in (valid)
    {
        uint length;
        const p = ts_query_string_value_for_id(cast(TSQuery*) _raw, valueId, &length);
        return p[0 .. length];
    }

    /// The raw predicate steps recorded for a pattern (the C API does not
    /// evaluate predicates — callers do).
    const(TSQueryPredicateStep)[] predicatesForPattern(uint patternIndex) const scope @trusted nothrow @nogc
    in (valid)
    {
        uint count;
        const p = ts_query_predicates_for_pattern(cast(TSQuery*) _raw, patternIndex, &count);
        return p[0 .. count];
    }

    /// Permanently disables a pattern (dialect-degradation path).
    void disablePattern(uint patternIndex) scope @trusted nothrow @nogc
    in (valid)
    {
        ts_query_disable_pattern(_raw, patternIndex);
    }
}

/// Owning handle over a `TSQueryCursor`.
struct TsQueryCursor
{
    private TSQueryCursor* _raw;

    @disable this(this);

    /// Creates a fresh cursor (aborts only on allocation failure).
    static TsQueryCursor create() @trusted nothrow @nogc
    {
        auto cursor = TsQueryCursor(ts_query_cursor_new());
        assert(cursor._raw !is null);
        return cursor;
    }

    ~this() @trusted nothrow @nogc
    {
        if (_raw !is null)
            ts_query_cursor_delete(_raw);
    }

    /// `true` iff this handle owns a live cursor.
    bool valid() const scope @safe pure nothrow @nogc
        => _raw !is null;

    /// Caps in-progress matches (helix-tuned 256 is the engine default);
    /// exceeding it silently drops the earliest match — check
    /// $(LREF didExceedMatchLimit).
    void setMatchLimit(uint limit) scope @trusted nothrow @nogc
    in (valid)
    {
        ts_query_cursor_set_match_limit(_raw, limit);
    }

    /// ditto
    bool didExceedMatchLimit() const scope @trusted nothrow @nogc
    in (valid)
    {
        return ts_query_cursor_did_exceed_match_limit(cast(TSQueryCursor*) _raw);
    }

    /// Restricts query execution to a byte range (viewport bounding).
    bool setByteRange(uint startByte, uint endByte) scope @trusted nothrow @nogc
    in (valid)
    {
        return ts_query_cursor_set_byte_range(_raw, startByte, endByte);
    }

    /// Starts executing `query` over `node` (plain, uninterruptible).
    void exec(ref const TsQuery query, TSNode node) scope @trusted nothrow @nogc
    in (valid && query.valid)
    {
        ts_query_cursor_exec(_raw, cast(TSQuery*) query._raw, node);
    }

    /// ditto, with the shared progress callback bounding time spent inside
    /// the C call. `ctx` must outlive the capture iteration.
    void execWithCancellation(ref const TsQuery query, TSNode node, ref CancelCtx ctx) scope @trusted nothrow @nogc
    in (valid && query.valid)
    {
        TSQueryCursorOptions options;
        options.payload = &ctx;
        options.progress_callback = &queryProgressCallback;
        ts_query_cursor_exec_with_options(_raw, cast(TSQuery*) query._raw, node, &options);
    }

    /// Advances to the next capture (in position order). `false` = exhausted.
    bool nextCapture(out TSQueryMatch match, out uint captureIndex) scope @trusted nothrow @nogc
    in (valid)
    {
        return ts_query_cursor_next_capture(_raw, &match, &captureIndex);
    }

    /// Advances to the next whole match (all its captures at once). `false` =
    /// exhausted. Used by injection discovery, which needs a pattern's
    /// `@injection.content`/`@injection.language` captures together. As with
    /// `nextCapture`, `match.captures` aliases cursor storage the next call
    /// invalidates — read it before advancing.
    bool nextMatch(out TSQueryMatch match) scope @trusted nothrow @nogc
    in (valid)
    {
        return ts_query_cursor_next_match(_raw, &match);
    }

    /// Removes an in-progress match (predicate rejection / same-node override).
    void removeMatch(uint matchId) scope @trusted nothrow @nogc
    in (valid)
    {
        ts_query_cursor_remove_match(_raw, matchId);
    }
}

private TsErrorCode mapQueryError(TSQueryError e) @safe pure nothrow @nogc
{
    switch (e)
    {
        case TSQueryError.TSQueryErrorSyntax: return TsErrorCode.querySyntax;
        case TSQueryError.TSQueryErrorNodeType: return TsErrorCode.queryNodeType;
        case TSQueryError.TSQueryErrorField: return TsErrorCode.queryField;
        case TSQueryError.TSQueryErrorCapture: return TsErrorCode.queryCapture;
        case TSQueryError.TSQueryErrorStructure: return TsErrorCode.queryStructure;
        case TSQueryError.TSQueryErrorLanguage: return TsErrorCode.queryLanguage;
        default: return TsErrorCode.querySyntax;
    }
}

@("tree_sitter.wrappers.parserLifecycle")
@system nothrow
unittest
{
    auto parser = TsParser.create();
    assert(parser.valid);

    // no language set: parse yields no tree → parseFailed, parser reusable
    TsError error;
    auto tree = parser.parse("{}", error);
    assert(!tree.valid);
    assert(error.code == TsErrorCode.parseFailed);
    assert(parser.valid);
}

@("tree_sitter.wrappers.invalidHandlesAreInert")
@system nothrow @nogc
unittest
{
    // default-initialized handles destruct as no-ops
    TsTree tree;
    assert(!tree.valid);
    TsQuery query;
    assert(!query.valid);
}

@("tree_sitter.wrappers.sizeGuard")
@system nothrow
unittest
{
    // A fake over-2GiB slice must be rejected before any C call touches it.
    auto parser = TsParser.create();
    const(char)[] fake = (cast(const(char)*) null)[0 .. cast(size_t) int.max + 1];
    TsError error;
    auto tree = parser.parse(fake, error);
    assert(!tree.valid);
    assert(error.code == TsErrorCode.sourceTooLarge);
}

@("tree_sitter.wrappers.parseSmoke")
@system
unittest
{
    import sparkles.base.smallbuffer : SmallBuffer;
    import sparkles.tree_sitter.loader : loadGrammarForTest;

    const grammar = loadGrammarForTest("json");
    auto parser = TsParser.create();
    assert(!parser.setLanguage(grammar.language).hasError);

    TsError error;
    auto tree = parser.parse(`{"a": [1, true]}`, error);
    assert(!error);
    assert(tree.valid);
    assert(!tree.rootHasError);

    SmallBuffer!(char, 512) sexp;
    writeSExpression(sexp, tree.rootNode);
    assert(sexp.length > 9);
    assert(sexp[0 .. 9] == "(document");

    // error recovery is diagnostic, not fatal
    auto broken = parser.parse(`{"a": ]`, error);
    assert(!error);
    assert(broken.valid);
    assert(broken.rootHasError);
}

@("tree_sitter.wrappers.queryCompileAndErrors")
@system
unittest
{
    import sparkles.tree_sitter.loader : loadGrammarForTest;

    const grammar = loadGrammarForTest("json");

    TsError error;
    auto query = TsQuery.create(grammar.language, "(string) @string", error);
    assert(!error);
    assert(query.valid);
    assert(query.patternCount == 1);
    assert(query.captureCount == 1);
    assert(query.captureName(0) == "string");
    assert(query.predicatesForPattern(0).length == 0);

    auto badSyntax = TsQuery.create(grammar.language, "(string", error);
    assert(!badSyntax.valid);
    assert(error.code == TsErrorCode.querySyntax);

    auto badNode = TsQuery.create(grammar.language, "(nosuchnode) @x", error);
    assert(!badNode.valid);
    assert(error.code == TsErrorCode.queryNodeType);
}

@("tree_sitter.wrappers.captureIteration")
@system
unittest
{
    import sparkles.tree_sitter.loader : loadGrammarForTest;

    const grammar = loadGrammarForTest("json");
    auto parser = TsParser.create();
    assert(!parser.setLanguage(grammar.language).hasError);

    TsError error;
    const source = `{"a": "b"}`;
    auto tree = parser.parse(source, error);
    assert(tree.valid);

    auto query = TsQuery.create(grammar.language, `(string) @string`, error);
    assert(query.valid);

    auto cursor = TsQueryCursor.create();
    cursor.setMatchLimit(256);
    cursor.exec(query, tree.rootNode);

    size_t count;
    TSQueryMatch match;
    uint captureIndex;
    while (cursor.nextCapture(match, captureIndex))
    {
        auto node = cast(TSNode) match.captures[captureIndex].node;
        assert(ts_node_start_byte(node) < ts_node_end_byte(node));
        ++count;
    }
    assert(count == 2); // "a" and "b"
    assert(!cursor.didExceedMatchLimit);
}

@("tree_sitter.wrappers.guardsAbortAndReset")
@system
unittest
{
    import sparkles.tree_sitter.loader : loadGrammarForTest;

    const grammar = loadGrammarForTest("json");
    auto parser = TsParser.create();
    assert(!parser.setLanguage(grammar.language).hasError);

    // Large enough that the progress callback definitely fires.
    auto big = new char[](2 * 1024 * 1024);
    big[0] = '[';
    foreach (i; 1 .. big.length - 1)
        big[i] = (i & 1) ? '0' : ',';
    big[$ - 1] = ']';

    // pre-set host cancellation flag → parseCancelled, parser reusable
    shared bool cancel = true;
    TsError error;
    auto aborted = parser.parse(big, error, ParseGuards(cancelFlag: &cancel));
    assert(!aborted.valid);
    assert(error.code == TsErrorCode.parseCancelled);

    // already-expired deadline → parseTimeout
    import core.time : hnsecs;

    auto timedOut = parser.parse(big, error, ParseGuards(budget: 1.hnsecs));
    assert(!timedOut.valid);
    assert(error.code == TsErrorCode.parseTimeout);

    // the handle stays usable after aborts
    auto ok = parser.parse(`[1]`, error);
    assert(!error);
    assert(ok.valid);
}
