/**
 * Sparkles Markdown parser and renderer.
 *
 * This is a profile-aware parser with a CommonMark-first baseline and a
 * shell-with-hooks extension model.
 */
module sparkles.markdown;

import std.algorithm.searching : canFind, endsWith, startsWith;
import std.array : Appender, appender, array;
import std.conv : to;
import std.range.primitives : ElementType, isInputRange, isOutputRange, put;
import std.string : strip, stripRight;
import std.typecons : Nullable;
import std.utf : UTFException, decode, validate;

/// Parsing profiles.
enum Profile
{
    commonmark_strict,
    gfm,
    vitepress_compatible,
    nextra_compatible,
    custom,
}

/// Feature toggles used by `Profile.custom` and profile defaults.
struct FeatureFlags
{
    bool tables = false;
    bool strikethrough = false;
    bool taskLists = false;
    bool autolinks = false;
    bool customContainers = false;
    bool emojiShortcodes = false;
    bool tocToken = false;
    bool mathSyntax = false;
    bool codeImport = false;
    bool markdownInclude = false;
    bool codeGroups = false;
    bool githubAlerts = false;
    bool headingAnchors = false;
    bool customHeadingIds = false;
    bool fenceMetadata = false;
    bool codeMarkers = false;
    bool mdxSyntax = false;
}

/// Parser hard limits.
struct Limits
{
    uint maxNestingDepth = 128;
    uint maxIncludeDepth = 8;
    size_t maxInputBytes = 16 * 1024 * 1024;
    uint maxTokenCount = 0;
}

/// Source ownership policy.
enum BorrowPolicy
{
    automatic,
    requireBorrow,
    requireCopy,
}

/// Indicates whether source text is borrowed or owned by parse result.
enum SourceOwnership
{
    borrowed,
    owned,
}

/// UTF-8 handling mode for `ubyte` inputs.
enum Utf8ErrorMode
{
    replace,
    strictFail,
}

/// Priority for heading-id syntax recognition when both are enabled.
enum HeadingIdSyntaxPreference
{
    vitepressBraceFirst,
    nextraBracketFirst,
}

/// Span into normalized source text.
struct SourceSpan
{
    uint offset;
    uint length;
}

/// Human-readable source location.
struct SourceLocation
{
    uint line;
    uint column;
}

/// Source map used to lazily convert offsets into line/column.
struct SourceMap
{
    uint[] lineStarts;

    SourceLocation locationAt(size_t offset) const
    {
        if (lineStarts.length == 0)
            return SourceLocation(1, 1);

        size_t low = 0;
        size_t high = lineStarts.length;
        while (low + 1 < high)
        {
            size_t mid = (low + high) / 2;
            if (lineStarts[mid] <= offset)
                low = mid;
            else
                high = mid;
        }

        auto lineStart = lineStarts[low];
        auto column = cast(uint) (offset - lineStart + 1);
        return SourceLocation(cast(uint) low + 1, column);
    }
}

/// Diagnostic severity.
enum DiagnosticLevel
{
    info,
    warning,
    error,
}

/// Parser diagnostic code.
enum ParseErrorCode
{
    none,
    maxInputExceeded,
    invalidUtf8,
    borrowContractViolation,
    unsupportedInput,
    parseFailure,
    tokenLimitExceeded,
}

/// One parse diagnostic.
struct Diagnostic
{
    DiagnosticLevel level;
    ParseErrorCode code;
    SourceSpan span;
    string message;
}

/// Aggregate diagnostics.
alias DiagnosticList = Diagnostic[];

/// Parse error passed to optional error hooks.
struct ParseError
{
    ParseErrorCode code;
    SourceSpan span;
    string message;
}

/// Error-recovery action returned by optional hook.
enum ErrorAction
{
    skip,
    recover,
    abort_,
}

/// Parser source storage contract.
struct SourceStorage
{
    SourceOwnership ownership;
    const(char)[] text;
}

/// Preserved raw byte storage contract.
struct RawByteStorage
{
    SourceOwnership ownership;
    const(ubyte)[] bytes;
}

/// Placeholder scanner passed to optional block hooks.
struct LineScanner
{
    const(char)[] line;
    size_t lineIndex;
    size_t byteOffset;
}

/// Placeholder block stack descriptor passed to optional block hooks.
struct BlockStack
{
    uint depth;
}

/// Placeholder delimiter stack descriptor passed to optional inline hooks.
struct DelimiterStack
{
    uint depth;
}

/// Internal AST kind.
enum AstKind
{
    document,
    blockQuote,
    listBlock,
    listItem,
    paragraph,
    heading,
    thematicBreak,
    fencedCode,
    indentedCode,
    htmlBlock,
    tableBlock,
    tableRow,
    tableCell,
    customContainer,
    codeGroup,
    frontmatter,
    tocToken,
    mathBlock,
    text,
    softBreak,
    hardBreak,
    code,
    emphasis,
    strong,
    link,
    image,
    htmlInline,
    autolink,
    strikethrough,
    emoji,
    mathInline,
    codeMarker,
    mdxJsxElement,
    mdxEsmImport,
    mdxEsmExport,
    mdxExpression,
}

/// Task-list status.
enum TaskStatus : ubyte
{
    none,
    unchecked,
    checked,
}

/// Table alignment.
enum Alignment : ubyte
{
    none,
    left,
    center,
    right,
}

/// Code marker kind.
enum MarkerKind : ubyte
{
    focus,
    add,
    remove,
    error_,
}

/// Parsed code marker payload.
struct CodeMarker
{
    MarkerKind kind;
    uint line;
}

/// Parsed code-fence metadata.
struct CodeMeta
{
    bool showLineNumbers = false;
    uint lineNumberStart = 1;
    bool copyButton = true;
    const(char)[] filename;
    uint[] highlightedLines;
    const(char)[] highlightedSubstring;
    CodeMarker[] markers;
}

/// Unified AST node.
struct AstNode
{
    AstKind kind;
    SourceSpan span;

    AstNode[] children;

    ubyte level;
    bool ordered;
    uint start;
    bool tight;
    TaskStatus taskStatus;
    bool isHeader;
    Alignment alignment;
    bool selfClosing;

    const(char)[] customId;
    const(char)[] infoString;
    CodeMeta metadata;

    const(char)[] literal;
    const(char)[] languageHint;
    const(char)[] destination;
    const(char)[] title;
    const(char)[] alt;
    const(char)[] name;
}

/// Inline alias for API ergonomics.
alias InlineNode = AstNode;

/// Block alias for API ergonomics.
alias BlockNode = AstNode;

/// Block-start request result returned by extension hooks.
struct BlockStart
{
    AstNode node;
    size_t consumedLines = 1;
}

/// Parser context passed to preprocess hooks.
struct ParseContext
{
    string input;
    string sourcePath;
    Limits limits;
    DiagnosticList diagnostics;
}

/// Event kind used by the primary event stream.
enum EventKind
{
    enter,
    exit,
    text,
    code,
    softBreak,
    hardBreak,
    thematicBreak,
}

/// Flat parser event.
struct Event
{
    EventKind kind;
    AstKind tag;
    SourceSpan span;
    const(char)[] literal;
    const(char)[] destination;
    const(char)[] title;
    ubyte level;
}

/// Primary parser representation.
alias EventStream = Event[];

/// Parse output.
struct ParseResult
{
    EventStream events;
    SourceStorage source;
    RawByteStorage rawBytes;
    SourceMap sourceMap;
    DiagnosticList diagnostics;

    AstNode ast;

    // Preserve owned storage when parse result decouples from caller memory.
    string _ownedSource;
    ubyte[] _ownedRaw;

    FeatureFlags features;
}

/// Rendering options.
struct RenderOptions
{
    bool unsafeHtml = false;
    bool sourcePos = false;
    char softBreakAs = '\n';
}

/// Basic hook that forces `BorrowPolicy.requireBorrow` at compile-time.
struct RequireBorrowHook
{
    enum borrowPolicy = BorrowPolicy.requireBorrow;
}

/// Basic hook that forces `BorrowPolicy.requireCopy` at compile-time.
struct RequireCopyHook
{
    enum borrowPolicy = BorrowPolicy.requireCopy;
}

private enum defaultBorrowPolicy(Hook) = ()
{
    static if (!is(Hook == void) && __traits(compiles, Hook.borrowPolicy))
        return Hook.borrowPolicy;
    else
        return BorrowPolicy.automatic;
}();

/// Parser options.
struct MarkdownOptions(Hook = void, Alloc = void)
{
    Profile profile = Profile.commonmark_strict;
    FeatureFlags features;
    bool sourcePos = true;
    bool safeMode = true;
    Limits limits;
    Utf8ErrorMode utf8ErrorMode = Utf8ErrorMode.replace;
    HeadingIdSyntaxPreference headingIdPreference = HeadingIdSyntaxPreference.vitepressBraceFirst;

    static if (!is(Hook == void))
        Hook hook;

    static if (!is(Alloc == void))
        Alloc* allocator = null;

    enum BorrowPolicy borrowPolicy = defaultBorrowPolicy!Hook;
}

/// Hook capability trait for preprocess phase.
enum bool hasPreprocessDocument(E, Ctx) =
    !is(E == void) && __traits(compiles, {
        E e = E.init;
        Ctx ctx = Ctx.init;
        e.preprocessDocument(ctx);
    });

/// Hook capability trait for block start extension.
enum bool hasTryStartBlock(E, Scanner, Stack) =
    !is(E == void) && __traits(compiles, {
        E e = E.init;
        Scanner s = Scanner.init;
        Stack st = Stack.init;
        auto r = e.tryStartBlock(s, st);
    });

/// Hook capability trait for inline extension.
enum bool hasTryParseInline(E, Scanner, Delims) =
    !is(E == void) && __traits(compiles, {
        E e = E.init;
        Scanner s = Scanner.init;
        Delims d = Delims.init;
        auto r = e.tryParseInline(s, d);
    });

/// Hook capability trait for post-parse phase.
enum bool hasOnPostParse(E, Events) =
    !is(E == void) && __traits(compiles, {
        E e = E.init;
        Events ev = Events.init;
        e.onPostParse(ev);
    });

/// Hook capability trait for custom node rendering.
enum bool hasOnRenderNode(E, Node, Writer) =
    !is(E == void) && __traits(compiles, {
        E e = E.init;
        Node node = Node.init;
        Writer writer = Writer.init;
        auto r = e.onRenderNode(node, writer);
    });

/// Hook capability trait for custom error handling.
enum bool hasOnError(E, Err) =
    !is(E == void) && __traits(compiles, {
        E e = E.init;
        Err err = Err.init;
        auto r = e.onError(err);
    });

private enum bool isCharInputRange(R) =
    is(R : const(char)[]) ||
    (isInputRange!R && (
        is(ElementType!R == char) ||
        is(ElementType!R == const(char)) ||
        is(ElementType!R == immutable(char))
    ));

private enum bool isByteInputRange(R) =
    is(R : const(ubyte)[]) ||
    (isInputRange!R && (
        is(ElementType!R == ubyte) ||
        is(ElementType!R == const(ubyte)) ||
        is(ElementType!R == immutable(ubyte))
    ));

/// Parse markdown from an input range of UTF-8 code units (`char`) or bytes (`ubyte`).
ParseResult parse(R, Hook = void, Alloc = void)(
    R input,
    MarkdownOptions!(Hook, Alloc) opts = MarkdownOptions!(Hook, Alloc)(),
)
{
    static if (!(isCharInputRange!R || isByteInputRange!R))
        static assert(false, "parse input must be a range of char or ubyte.");

    ParseResult result;
    auto normalized = normalizeInput!R(input, opts, result.diagnostics);

    result.source = SourceStorage(normalized.sourceOwnership, normalized.text);
    result.rawBytes = RawByteStorage(normalized.rawOwnership, normalized.rawBytes);

    if (normalized.sourceOwnership == SourceOwnership.owned)
    {
        result._ownedSource = normalized.ownedText;
        result.source.text = result._ownedSource;
        result.source.ownership = SourceOwnership.owned;
    }

    if (normalized.rawOwnership == SourceOwnership.owned)
    {
        result._ownedRaw = normalized.ownedRawBytes;
        result.rawBytes.bytes = result._ownedRaw;
        result.rawBytes.ownership = SourceOwnership.owned;
    }

    if (opts.limits.maxInputBytes > 0 && result.rawBytes.bytes.length > opts.limits.maxInputBytes)
    {
        result.diagnostics ~= Diagnostic(
            level: DiagnosticLevel.error,
            code: ParseErrorCode.maxInputExceeded,
            span: SourceSpan(0, 0),
            message: "Input exceeds configured maxInputBytes.",
        );

        result.sourceMap = makeSourceMap(result.source.text);
        result.ast = AstNode(kind: AstKind.document, span: SourceSpan(0, cast(uint) result.source.text.length));
        result.events = astToEvents(result.ast);
        return result;
    }

    auto activeFeatures = withProfileDefaults(opts.profile, opts.features);
    result.features = activeFeatures;

    static if (!is(Hook == void) && hasPreprocessDocument!(Hook, ParseContext))
    {
        ParseContext ctx;
        ctx.input = result.source.text.idup;
        ctx.limits = opts.limits;
        ctx.diagnostics = result.diagnostics;

        auto hook = opts.hook;
        hook.preprocessDocument(ctx);

        result.diagnostics = ctx.diagnostics;
        if (ctx.input != result.source.text)
        {
            result._ownedSource = ctx.input;
            result.source = SourceStorage(SourceOwnership.owned, result._ownedSource);
        }
    }

    result.sourceMap = makeSourceMap(result.source.text);
    result.ast = parseDocument(result.source.text, activeFeatures, opts.headingIdPreference);
    result.events = astToEvents(result.ast);

    static if (!is(Hook == void) && hasOnPostParse!(Hook, EventStream))
    {
        auto hook = opts.hook;
        hook.onPostParse(result.events);
    }

    if (opts.limits.maxTokenCount > 0 && result.events.length > opts.limits.maxTokenCount)
    {
        result.diagnostics ~= Diagnostic(
            level: DiagnosticLevel.error,
            code: ParseErrorCode.tokenLimitExceeded,
            span: SourceSpan(0, 0),
            message: "Token count exceeded configured limit.",
        );
    }

    return result;
}

/// Parse with a hard no-copy contract for slice inputs.
ParseResult parseBorrowed(S, Hook = RequireBorrowHook)(
    S input,
    MarkdownOptions!(Hook, void) opts = MarkdownOptions!(Hook, void)(),
)
if ((is(S : const(char)[]) || is(S : const(ubyte)[])) && MarkdownOptions!(Hook, void).borrowPolicy == BorrowPolicy.requireBorrow)
{
    return parse!(S, Hook, void)(input, opts);
}

/// Parse with a hard owned-source contract.
ParseResult parseOwned(R, Hook = RequireCopyHook, Alloc)(
    R input,
    ref Alloc allocator,
    MarkdownOptions!(Hook, Alloc) opts = MarkdownOptions!(Hook, Alloc)(),
)
if (MarkdownOptions!(Hook, Alloc).borrowPolicy == BorrowPolicy.requireCopy)
{
    static if (!(isCharInputRange!R || isByteInputRange!R))
        static assert(false, "parseOwned input must be a range of char or ubyte.");

    auto adjusted = opts;
    adjusted.allocator = &allocator;
    return parse!(R, Hook, Alloc)(input, adjusted);
}

/// Resolve span into normalized source text.
const(char)[] sourceSlice(return scope const ref ParseResult result, in SourceSpan span)
{
    if (span.offset + span.length > result.source.text.length)
        return null;
    return result.source.text[span.offset .. span.offset + span.length];
}

/// Resolve span into preserved raw source bytes.
const(ubyte)[] rawSlice(return scope const ref ParseResult result, in SourceSpan span)
{
    if (span.offset + span.length > result.rawBytes.bytes.length)
        return null;
    return result.rawBytes.bytes[span.offset .. span.offset + span.length];
}

/// Render parse result to HTML via output range.
ref Writer renderHtml(Writer, Hook = void)(
    in ParseResult result,
    return ref Writer writer,
    in RenderOptions opts = RenderOptions(),
)
if (isOutputRange!(Writer, char))
{
    renderNode(result.ast, writer, opts);
    return writer;
}

/// Convenience rendering helper that allocates and returns a `string`.
string toHtml(Hook = void)(
    in ParseResult result,
    in RenderOptions opts = RenderOptions(),
)
{
    auto writer = appender!string();
    renderHtml!(Appender!string, Hook)(result, writer, opts);
    return writer.data;
}

/// Build tree AST from parse result.
const(AstNode) buildAst(const ref ParseResult result)
{
    return result.ast;
}

private struct NormalizedInput
{
    const(char)[] text;
    SourceOwnership sourceOwnership = SourceOwnership.borrowed;

    const(ubyte)[] rawBytes;
    SourceOwnership rawOwnership = SourceOwnership.borrowed;

    string ownedText;
    ubyte[] ownedRawBytes;
}

private @safe FeatureFlags withProfileDefaults(Profile profile, FeatureFlags user)
{
    FeatureFlags defaults;

    final switch (profile)
    {
        case Profile.commonmark_strict:
            break;
        case Profile.gfm:
            defaults.tables = true;
            defaults.strikethrough = true;
            defaults.taskLists = true;
            defaults.autolinks = true;
            break;
        case Profile.vitepress_compatible:
            defaults.tables = true;
            defaults.strikethrough = true;
            defaults.taskLists = true;
            defaults.autolinks = true;
            defaults.customContainers = true;
            defaults.emojiShortcodes = true;
            defaults.tocToken = true;
            defaults.codeImport = true;
            defaults.markdownInclude = true;
            defaults.codeGroups = true;
            defaults.githubAlerts = true;
            defaults.headingAnchors = true;
            defaults.customHeadingIds = true;
            defaults.fenceMetadata = true;
            defaults.codeMarkers = true;
            break;
        case Profile.nextra_compatible:
            defaults.tables = true;
            defaults.strikethrough = true;
            defaults.taskLists = true;
            defaults.autolinks = true;
            defaults.githubAlerts = true;
            defaults.customHeadingIds = true;
            defaults.fenceMetadata = true;
            defaults.codeMarkers = true;
            defaults.mdxSyntax = true;
            break;
        case Profile.custom:
            break;
    }

    user.tables = user.tables || defaults.tables;
    user.strikethrough = user.strikethrough || defaults.strikethrough;
    user.taskLists = user.taskLists || defaults.taskLists;
    user.autolinks = user.autolinks || defaults.autolinks;
    user.customContainers = user.customContainers || defaults.customContainers;
    user.emojiShortcodes = user.emojiShortcodes || defaults.emojiShortcodes;
    user.tocToken = user.tocToken || defaults.tocToken;
    user.mathSyntax = user.mathSyntax || defaults.mathSyntax;
    user.codeImport = user.codeImport || defaults.codeImport;
    user.markdownInclude = user.markdownInclude || defaults.markdownInclude;
    user.codeGroups = user.codeGroups || defaults.codeGroups;
    user.githubAlerts = user.githubAlerts || defaults.githubAlerts;
    user.headingAnchors = user.headingAnchors || defaults.headingAnchors;
    user.customHeadingIds = user.customHeadingIds || defaults.customHeadingIds;
    user.fenceMetadata = user.fenceMetadata || defaults.fenceMetadata;
    user.codeMarkers = user.codeMarkers || defaults.codeMarkers;
    user.mdxSyntax = user.mdxSyntax || defaults.mdxSyntax;

    return user;
}

private NormalizedInput normalizeInput(R, Hook, Alloc)(
    R input,
    in MarkdownOptions!(Hook, Alloc) opts,
    ref DiagnosticList diagnostics,
)
{
    static if (!(isCharInputRange!R || isByteInputRange!R))
        static assert(false, "normalizeInput requires char/ubyte input range.");

    NormalizedInput outv;

    enum borrowPolicy = MarkdownOptions!(Hook, Alloc).borrowPolicy;

    static if (is(R : const(char)[]))
    {
        const(char)[] source = input;
        outv.rawBytes = cast(const(ubyte)[]) source;

        bool changed;
        auto normalized = normalizeNewlines(source, changed);

        if (borrowPolicy == BorrowPolicy.requireCopy || changed)
        {
            outv.ownedText = normalized;
            outv.text = outv.ownedText;
            outv.sourceOwnership = SourceOwnership.owned;
        }
        else
        {
            outv.text = source;
            outv.sourceOwnership = SourceOwnership.borrowed;
        }

        if (borrowPolicy == BorrowPolicy.requireCopy)
        {
            outv.ownedRawBytes = cast(ubyte[]) outv.rawBytes.dup;
            outv.rawBytes = outv.ownedRawBytes;
            outv.rawOwnership = SourceOwnership.owned;
        }
        else
            outv.rawOwnership = SourceOwnership.borrowed;

        if (borrowPolicy == BorrowPolicy.requireBorrow && changed)
        {
            diagnostics ~= Diagnostic(
                level: DiagnosticLevel.error,
                code: ParseErrorCode.borrowContractViolation,
                span: SourceSpan(0, 0),
                message: "Borrow contract cannot normalize CRLF/CR without copying.",
            );
            outv.text = source;
            outv.sourceOwnership = SourceOwnership.borrowed;
        }
    }
    else static if (is(R : const(ubyte)[]))
    {
        const(ubyte)[] raw = input;
        outv.rawBytes = raw;

        auto bytesAsChars = cast(const(char)[]) raw;
        bool utfValid = true;
        try
            validate(bytesAsChars);
        catch (UTFException)
            utfValid = false;

        if (!utfValid && opts.utf8ErrorMode == Utf8ErrorMode.strictFail)
        {
            diagnostics ~= Diagnostic(
                level: DiagnosticLevel.error,
                code: ParseErrorCode.invalidUtf8,
                span: SourceSpan(0, cast(uint) raw.length),
                message: "Invalid UTF-8 in byte input while Utf8ErrorMode.strictFail is enabled.",
            );
        }

        const(char)[] source;
        SourceOwnership sourceOwnership = SourceOwnership.borrowed;

        if (utfValid)
            source = bytesAsChars;
        else
        {
            outv.ownedText = decodeWithReplacement(bytesAsChars);
            source = outv.ownedText;
            sourceOwnership = SourceOwnership.owned;
        }

        bool changed;
        auto normalized = normalizeNewlines(source, changed);
        if (changed)
        {
            outv.ownedText = normalized;
            source = outv.ownedText;
            sourceOwnership = SourceOwnership.owned;
        }

        if (borrowPolicy == BorrowPolicy.requireCopy)
        {
            outv.ownedRawBytes = cast(ubyte[]) raw.dup;
            outv.rawBytes = outv.ownedRawBytes;
            outv.rawOwnership = SourceOwnership.owned;

            if (sourceOwnership == SourceOwnership.borrowed)
            {
                outv.ownedText = cast(string) source.dup;
                source = outv.ownedText;
                sourceOwnership = SourceOwnership.owned;
            }
        }
        else
            outv.rawOwnership = SourceOwnership.borrowed;

        if (borrowPolicy == BorrowPolicy.requireBorrow && (sourceOwnership == SourceOwnership.owned || !utfValid || changed))
        {
            diagnostics ~= Diagnostic(
                level: DiagnosticLevel.error,
                code: ParseErrorCode.borrowContractViolation,
                span: SourceSpan(0, 0),
                message: "Borrow contract could not be honored for byte input.",
            );
            source = bytesAsChars;
            sourceOwnership = SourceOwnership.borrowed;
        }

        outv.text = source;
        outv.sourceOwnership = sourceOwnership;
    }
    else static if (is(ElementType!R : char))
    {
        auto owned = input.array;
        outv.ownedText = cast(string) owned.idup;

        bool changed;
        outv.ownedText = normalizeNewlines(outv.ownedText, changed);
        outv.text = outv.ownedText;
        outv.sourceOwnership = SourceOwnership.owned;

        outv.ownedRawBytes = cast(ubyte[]) (cast(const(ubyte)[]) outv.ownedText).dup;
        outv.rawBytes = outv.ownedRawBytes;
        outv.rawOwnership = SourceOwnership.owned;

        if (borrowPolicy == BorrowPolicy.requireBorrow)
        {
            diagnostics ~= Diagnostic(
                level: DiagnosticLevel.error,
                code: ParseErrorCode.borrowContractViolation,
                span: SourceSpan(0, 0),
                message: "Borrow contract requires slice input.",
            );
        }
    }
    else
    {
        auto owned = input.array;
        outv.ownedRawBytes = cast(ubyte[]) owned.idup;
        outv.rawBytes = outv.ownedRawBytes;
        outv.rawOwnership = SourceOwnership.owned;

        auto bytesAsChars = cast(const(char)[]) outv.rawBytes;
        bool utfValid = true;
        try
            validate(bytesAsChars);
        catch (UTFException)
            utfValid = false;

        if (!utfValid && opts.utf8ErrorMode == Utf8ErrorMode.strictFail)
        {
            diagnostics ~= Diagnostic(
                level: DiagnosticLevel.error,
                code: ParseErrorCode.invalidUtf8,
                span: SourceSpan(0, cast(uint) outv.rawBytes.length),
                message: "Invalid UTF-8 in byte input while Utf8ErrorMode.strictFail is enabled.",
            );
        }

        outv.ownedText = utfValid ? cast(string) bytesAsChars.idup : decodeWithReplacement(bytesAsChars);
        bool changed;
        outv.ownedText = normalizeNewlines(outv.ownedText, changed);

        outv.text = outv.ownedText;
        outv.sourceOwnership = SourceOwnership.owned;

        if (borrowPolicy == BorrowPolicy.requireBorrow)
        {
            diagnostics ~= Diagnostic(
                level: DiagnosticLevel.error,
                code: ParseErrorCode.borrowContractViolation,
                span: SourceSpan(0, 0),
                message: "Borrow contract requires slice input.",
            );
        }
    }

    return outv;
}

private string decodeWithReplacement(const(char)[] bytes)
{
    auto writer = appender!string();
    size_t i = 0;

    while (i < bytes.length)
    {
        auto start = i;
        try
        {
            decode(bytes, i);
            put(writer, bytes[start .. i]);
        }
        catch (UTFException)
        {
            put(writer, "\xEF\xBF\xBD");
            i = start + 1;
        }
    }

    return writer.data;
}

private string normalizeNewlines(const(char)[] text, out bool changed)
{
    changed = false;
    if (!text.canFind('\r'))
        return text.idup;

    auto writer = appender!string();
    size_t i = 0;
    while (i < text.length)
    {
        auto c = text[i];
        if (c == '\r')
        {
            changed = true;
            put(writer, '\n');
            ++i;
            if (i < text.length && text[i] == '\n')
                ++i;
            continue;
        }

        put(writer, c);
        ++i;
    }

    return writer.data;
}

private SourceMap makeSourceMap(const(char)[] source)
{
    SourceMap map;
    map.lineStarts ~= 0u;

    for (size_t i = 0; i < source.length; ++i)
    {
        if (source[i] == '\n')
            map.lineStarts ~= cast(uint) (i + 1);
    }

    return map;
}

private struct LineInfo
{
    size_t start;
    size_t end;
    const(char)[] text;
}

private LineInfo[] splitLines(const(char)[] source)
{
    LineInfo[] lines;
    size_t i = 0;

    while (i < source.length)
    {
        auto lineStart = i;
        while (i < source.length && source[i] != '\n')
            ++i;

        auto lineEnd = i;
        lines ~= LineInfo(
            start: lineStart,
            end: lineEnd,
            text: source[lineStart .. lineEnd],
        );

        if (i < source.length && source[i] == '\n')
            ++i;
    }

    if (source.length == 0)
        lines ~= LineInfo(0, 0, "");

    return lines;
}

private AstNode parseDocument(
    const(char)[] source,
    in FeatureFlags features,
    HeadingIdSyntaxPreference headingIdPreference,
)
{
    auto lines = splitLines(source);
    AstNode[] children;

    size_t i = 0;
    while (i < lines.length)
    {
        auto line = lines[i];
        if (isBlank(line.text))
        {
            ++i;
            continue;
        }

        auto headingResult = parseHeadingLine(source, line, features, headingIdPreference);
        if (!headingResult.isNull)
        {
            children ~= headingResult.get;
            ++i;
            continue;
        }

        if (isThematicBreak(line.text))
        {
            children ~= AstNode(
                kind: AstKind.thematicBreak,
                span: SourceSpan(cast(uint) line.start, cast(uint) (line.end - line.start)),
            );
            ++i;
            continue;
        }

        auto fenceOpen = parseFenceOpen(line.text);
        if (!fenceOpen.isNull)
        {
            auto fenced = parseFencedCodeBlock(source, lines, i, fenceOpen.get);
            children ~= fenced.node;
            i = fenced.nextLine;
            continue;
        }

        auto paragraphStart = lines[i].start;
        auto paragraphEnd = lines[i].end;

        ++i;
        while (i < lines.length)
        {
            auto next = lines[i];
            if (isBlank(next.text) ||
                isThematicBreak(next.text) ||
                !parseHeadingLine(source, next, features, headingIdPreference).isNull ||
                !parseFenceOpen(next.text).isNull)
                break;

            paragraphEnd = next.end;
            ++i;
        }

        auto paragraphSlice = source[paragraphStart .. paragraphEnd];
        children ~= AstNode(
            kind: AstKind.paragraph,
            span: SourceSpan(cast(uint) paragraphStart, cast(uint) (paragraphEnd - paragraphStart)),
            children: parseInline(paragraphSlice, paragraphStart, features),
        );
    }

    return AstNode(
        kind: AstKind.document,
        span: SourceSpan(0, cast(uint) source.length),
        children: children,
    );
}

private bool isBlank(const(char)[] line)
{
    foreach (c; line)
    {
        if (c != ' ' && c != '\t')
            return false;
    }
    return true;
}

private bool isThematicBreak(const(char)[] line)
{
    auto trimmed = line.strip;
    if (trimmed.length < 3)
        return false;

    char marker = 0;
    uint markerCount = 0;

    foreach (c; trimmed)
    {
        if (c == ' ' || c == '\t')
            continue;

        if (c != '*' && c != '-' && c != '_')
            return false;

        if (marker == 0)
            marker = c;
        else if (c != marker)
            return false;

        ++markerCount;
    }

    return markerCount >= 3;
}

private struct FenceOpen
{
    char marker;
    size_t count;
    const(char)[] info;
}

private Nullable!FenceOpen parseFenceOpen(const(char)[] line)
{
    size_t indent = countLeadingSpaces(line);
    if (indent > 3 || indent >= line.length)
        return Nullable!FenceOpen.init;

    auto trimmed = line[indent .. $];
    if (trimmed.length < 3)
        return Nullable!FenceOpen.init;

    auto marker = trimmed[0];
    if (marker != '`' && marker != '~')
        return Nullable!FenceOpen.init;

    size_t run = 1;
    while (run < trimmed.length && trimmed[run] == marker)
        ++run;

    if (run < 3)
        return Nullable!FenceOpen.init;

    return Nullable!FenceOpen(FenceOpen(
        marker: marker,
        count: run,
        info: trimmed[run .. $].strip,
    ));
}

private struct FencedParseResult
{
    AstNode node;
    size_t nextLine;
}

private FencedParseResult parseFencedCodeBlock(
    const(char)[] source,
    in LineInfo[] lines,
    size_t openLine,
    in FenceOpen open,
)
{
    size_t i = openLine + 1;
    size_t closeLine = lines.length;

    while (i < lines.length)
    {
        auto line = lines[i];
        auto indent = countLeadingSpaces(line.text);
        if (indent <= 3)
        {
            auto trimmed = line.text[indent .. $];
            size_t run = 0;
            while (run < trimmed.length && trimmed[run] == open.marker)
                ++run;

            if (run >= open.count && trimmed[run .. $].strip.length == 0)
            {
                closeLine = i;
                break;
            }
        }

        ++i;
    }

    size_t contentStart = lines[openLine].end;
    if (contentStart < source.length && source[contentStart] == '\n')
        ++contentStart;

    size_t contentEnd = closeLine < lines.length ? lines[closeLine].start : source.length;
    auto literal = contentStart <= contentEnd ? source[contentStart .. contentEnd] : "";

    size_t nodeEnd = closeLine < lines.length ? lines[closeLine].end : source.length;
    size_t nextLine = closeLine < lines.length ? closeLine + 1 : lines.length;

    auto node = AstNode(
        kind: AstKind.fencedCode,
        span: SourceSpan(cast(uint) lines[openLine].start, cast(uint) (nodeEnd - lines[openLine].start)),
        infoString: open.info,
        literal: literal,
    );

    return FencedParseResult(node, nextLine);
}

private size_t countLeadingSpaces(const(char)[] line)
{
    size_t i = 0;
    while (i < line.length && line[i] == ' ')
        ++i;
    return i;
}

private Nullable!AstNode parseHeadingLine(
    const(char)[] source,
    in LineInfo line,
    in FeatureFlags features,
    HeadingIdSyntaxPreference headingIdPreference,
)
{
    auto indent = countLeadingSpaces(line.text);
    if (indent > 3 || indent >= line.text.length)
        return Nullable!AstNode.init;

    auto text = line.text[indent .. $];
    if (text.length == 0 || text[0] != '#')
        return Nullable!AstNode.init;

    size_t level = 0;
    while (level < text.length && text[level] == '#')
        ++level;

    if (level == 0 || level > 6)
        return Nullable!AstNode.init;

    if (level < text.length && text[level] != ' ' && text[level] != '\t')
        return Nullable!AstNode.init;

    size_t contentStartInLine = indent + level;
    while (contentStartInLine < line.text.length && (line.text[contentStartInLine] == ' ' || line.text[contentStartInLine] == '\t'))
        ++contentStartInLine;

    auto contentSlice = line.text[contentStartInLine .. $].stripRight;

    const(char)[] customId;
    auto titleSlice = contentSlice;
    if (features.customHeadingIds)
    {
        auto extracted = extractHeadingId(contentSlice, headingIdPreference);
        titleSlice = extracted.title;
        customId = extracted.id;
    }

    auto headingTextOffset = line.start + contentStartInLine;
    auto node = AstNode(
        kind: AstKind.heading,
        span: SourceSpan(cast(uint) line.start, cast(uint) (line.end - line.start)),
        level: cast(ubyte) level,
        customId: customId,
        children: parseInline(titleSlice, headingTextOffset, features),
    );

    return Nullable!AstNode(node);
}

private struct HeadingIdExtraction
{
    const(char)[] title;
    const(char)[] id;
}

private HeadingIdExtraction extractHeadingId(
    const(char)[] content,
    HeadingIdSyntaxPreference pref,
)
{
    final switch (pref)
    {
        case HeadingIdSyntaxPreference.vitepressBraceFirst:
        {
            auto brace = extractVitepressHeadingId(content);
            if (brace.id.length > 0)
                return brace;
            return extractNextraHeadingId(content);
        }
        case HeadingIdSyntaxPreference.nextraBracketFirst:
        {
            auto bracket = extractNextraHeadingId(content);
            if (bracket.id.length > 0)
                return bracket;
            return extractVitepressHeadingId(content);
        }
    }
}

private HeadingIdExtraction extractVitepressHeadingId(const(char)[] content)
{
    auto trimmed = content.stripRight;
    if (!trimmed.endsWith("}"))
        return HeadingIdExtraction(content, null);

    size_t close = trimmed.length - 1;
    size_t open = close;
    while (open > 0 && trimmed[open] != '{')
        --open;

    if (trimmed[open] != '{')
        return HeadingIdExtraction(content, null);

    auto candidate = trimmed[open .. close + 1];
    if (candidate.length < 4 || candidate[1] != '#')
        return HeadingIdExtraction(content, null);

    auto id = candidate[2 .. $ - 1];
    if (id.length == 0)
        return HeadingIdExtraction(content, null);

    auto title = trimmed[0 .. open].stripRight;
    return HeadingIdExtraction(title, id);
}

private HeadingIdExtraction extractNextraHeadingId(const(char)[] content)
{
    auto trimmed = content.stripRight;
    if (!trimmed.endsWith("]"))
        return HeadingIdExtraction(content, null);

    size_t close = trimmed.length - 1;
    size_t open = close;
    while (open > 0 && trimmed[open] != '[')
        --open;

    if (trimmed[open] != '[')
        return HeadingIdExtraction(content, null);

    auto candidate = trimmed[open .. close + 1];
    if (candidate.length < 4 || candidate[1] != '#')
        return HeadingIdExtraction(content, null);

    auto id = candidate[2 .. $ - 1];
    if (id.length == 0)
        return HeadingIdExtraction(content, null);

    auto title = trimmed[0 .. open].stripRight;
    return HeadingIdExtraction(title, id);
}

private AstNode[] parseInline(
    const(char)[] text,
    size_t baseOffset,
    in FeatureFlags features,
)
{
    AstNode[] nodes;
    size_t i = 0;

    while (i < text.length)
    {
        if (text[i] == '\n')
        {
            bool hard = i >= 2 && text[i - 1] == ' ' && text[i - 2] == ' ';
            nodes ~= AstNode(
                kind: hard ? AstKind.hardBreak : AstKind.softBreak,
                span: SourceSpan(cast(uint) (baseOffset + i), 1),
            );
            ++i;
            continue;
        }

        if (text[i] == '`')
        {
            auto close = findNext(text, '`', i + 1);
            if (close != size_t.max)
            {
                nodes ~= AstNode(
                    kind: AstKind.code,
                    span: SourceSpan(cast(uint) (baseOffset + i), cast(uint) (close - i + 1)),
                    literal: text[i + 1 .. close],
                );
                i = close + 1;
                continue;
            }
        }

        if (features.strikethrough && i + 1 < text.length && text[i] == '~' && text[i + 1] == '~')
        {
            auto close = findSubstring(text, "~~", i + 2);
            if (close != size_t.max)
            {
                nodes ~= AstNode(
                    kind: AstKind.strikethrough,
                    span: SourceSpan(cast(uint) (baseOffset + i), cast(uint) (close - i + 2)),
                    children: parseInline(text[i + 2 .. close], baseOffset + i + 2, features),
                );
                i = close + 2;
                continue;
            }
        }

        if (i + 1 < text.length && text[i] == '!' && text[i + 1] == '[')
        {
            auto closeLabel = findNext(text, ']', i + 2);
            if (closeLabel != size_t.max && closeLabel + 1 < text.length && text[closeLabel + 1] == '(')
            {
                auto closeDest = findNext(text, ')', closeLabel + 2);
                if (closeDest != size_t.max)
                {
                    nodes ~= AstNode(
                        kind: AstKind.image,
                        span: SourceSpan(cast(uint) (baseOffset + i), cast(uint) (closeDest - i + 1)),
                        destination: text[closeLabel + 2 .. closeDest].strip,
                        alt: text[i + 2 .. closeLabel],
                    );
                    i = closeDest + 1;
                    continue;
                }
            }
        }

        if (text[i] == '[')
        {
            auto closeLabel = findNext(text, ']', i + 1);
            if (closeLabel != size_t.max && closeLabel + 1 < text.length && text[closeLabel + 1] == '(')
            {
                auto closeDest = findNext(text, ')', closeLabel + 2);
                if (closeDest != size_t.max)
                {
                    nodes ~= AstNode(
                        kind: AstKind.link,
                        span: SourceSpan(cast(uint) (baseOffset + i), cast(uint) (closeDest - i + 1)),
                        destination: text[closeLabel + 2 .. closeDest].strip,
                        children: parseInline(text[i + 1 .. closeLabel], baseOffset + i + 1, features),
                    );
                    i = closeDest + 1;
                    continue;
                }
            }
        }

        if (i + 1 < text.length && text[i] == '*' && text[i + 1] == '*')
        {
            auto close = findSubstring(text, "**", i + 2);
            if (close != size_t.max)
            {
                nodes ~= AstNode(
                    kind: AstKind.strong,
                    span: SourceSpan(cast(uint) (baseOffset + i), cast(uint) (close - i + 2)),
                    children: parseInline(text[i + 2 .. close], baseOffset + i + 2, features),
                );
                i = close + 2;
                continue;
            }
        }

        if (text[i] == '*')
        {
            auto close = findNext(text, '*', i + 1);
            if (close != size_t.max)
            {
                nodes ~= AstNode(
                    kind: AstKind.emphasis,
                    span: SourceSpan(cast(uint) (baseOffset + i), cast(uint) (close - i + 1)),
                    children: parseInline(text[i + 1 .. close], baseOffset + i + 1, features),
                );
                i = close + 1;
                continue;
            }
        }

        if (text[i] == '<')
        {
            auto close = findNext(text, '>', i + 1);
            if (close != size_t.max)
            {
                auto literal = text[i + 1 .. close];
                if (literal.startsWith("http://") || literal.startsWith("https://") || literal.startsWith("mailto:"))
                {
                    nodes ~= AstNode(
                        kind: AstKind.autolink,
                        span: SourceSpan(cast(uint) (baseOffset + i), cast(uint) (close - i + 1)),
                        destination: literal,
                    );
                }
                else
                {
                    nodes ~= AstNode(
                        kind: AstKind.htmlInline,
                        span: SourceSpan(cast(uint) (baseOffset + i), cast(uint) (close - i + 1)),
                        literal: text[i .. close + 1],
                    );
                }
                i = close + 1;
                continue;
            }
        }

        auto start = i;
        while (i < text.length &&
            text[i] != '\n' &&
            text[i] != '`' &&
            text[i] != '[' &&
            text[i] != '*' &&
            text[i] != '<' &&
            text[i] != '~' &&
            !(i + 1 < text.length && text[i] == '!' && text[i + 1] == '['))
            ++i;

        auto literal = text[start .. i];
        if (literal.length > 0)
        {
            nodes ~= AstNode(
                kind: AstKind.text,
                span: SourceSpan(cast(uint) (baseOffset + start), cast(uint) literal.length),
                literal: literal,
            );
        }
        else
            ++i;
    }

    return nodes;
}

private size_t findNext(const(char)[] text, char needle, size_t from)
{
    for (size_t i = from; i < text.length; ++i)
    {
        if (text[i] == needle)
            return i;
    }

    return size_t.max;
}

private size_t findSubstring(const(char)[] text, const(char)[] needle, size_t from)
{
    if (needle.length == 0 || from >= text.length)
        return size_t.max;

    for (size_t i = from; i + needle.length <= text.length; ++i)
    {
        if (text[i .. i + needle.length] == needle)
            return i;
    }

    return size_t.max;
}

private EventStream astToEvents(in AstNode root)
{
    EventStream events;
    appendNodeEvents(events, root);
    return events;
}

private void appendNodeEvents(ref EventStream events, in AstNode node)
{
    switch (node.kind)
    {
        case AstKind.text:
            events ~= Event(EventKind.text, AstKind.text, node.span, node.literal);
            return;
        case AstKind.softBreak:
            events ~= Event(EventKind.softBreak, AstKind.softBreak, node.span);
            return;
        case AstKind.hardBreak:
            events ~= Event(EventKind.hardBreak, AstKind.hardBreak, node.span);
            return;
        case AstKind.code:
            events ~= Event(EventKind.code, AstKind.code, node.span, node.literal);
            return;
        case AstKind.thematicBreak:
            events ~= Event(EventKind.thematicBreak, AstKind.thematicBreak, node.span);
            return;
        case AstKind.fencedCode:
        case AstKind.indentedCode:
            events ~= Event(EventKind.code, node.kind, node.span, node.literal);
            return;
        default:
            events ~= Event(EventKind.enter, node.kind, node.span, node.literal, node.destination, node.title, node.level);
            foreach (child; node.children)
                appendNodeEvents(events, child);
            events ~= Event(EventKind.exit, node.kind, node.span, node.literal, node.destination, node.title, node.level);
            return;
    }
}

private void renderNode(Writer)(in AstNode node, ref Writer writer, in RenderOptions opts)
if (isOutputRange!(Writer, char))
{
    switch (node.kind)
    {
        case AstKind.document:
            foreach (child; node.children)
                renderNode(child, writer, opts);
            break;
        case AstKind.paragraph:
            put(writer, "<p>");
            foreach (child; node.children)
                renderNode(child, writer, opts);
            put(writer, "</p>\n");
            break;
        case AstKind.heading:
            put(writer, "<h");
            put(writer, cast(char) ('0' + node.level));
            if (node.customId.length > 0)
            {
                put(writer, " id=\"");
                writeEscaped(writer, node.customId);
                put(writer, "\"");
            }
            put(writer, ">");
            foreach (child; node.children)
                renderNode(child, writer, opts);
            put(writer, "</h");
            put(writer, cast(char) ('0' + node.level));
            put(writer, ">\n");
            break;
        case AstKind.thematicBreak:
            put(writer, "<hr />\n");
            break;
        case AstKind.fencedCode:
            put(writer, "<pre><code");
            auto language = fenceLanguage(node.infoString);
            if (language.length > 0)
            {
                put(writer, " class=\"language-");
                writeEscaped(writer, language);
                put(writer, "\"");
            }
            put(writer, ">");
            writeEscaped(writer, node.literal);
            put(writer, "</code></pre>\n");
            break;
        case AstKind.indentedCode:
            put(writer, "<pre><code>");
            writeEscaped(writer, node.literal);
            put(writer, "</code></pre>\n");
            break;
        case AstKind.htmlBlock:
            if (opts.unsafeHtml)
            {
                put(writer, node.literal);
                put(writer, '\n');
            }
            else
            {
                put(writer, "<pre><code>");
                writeEscaped(writer, node.literal);
                put(writer, "</code></pre>\n");
            }
            break;
        case AstKind.blockQuote:
            put(writer, "<blockquote>\n");
            foreach (child; node.children)
                renderNode(child, writer, opts);
            put(writer, "</blockquote>\n");
            break;
        case AstKind.listBlock:
            put(writer, node.ordered ? "<ol>\n" : "<ul>\n");
            foreach (child; node.children)
                renderNode(child, writer, opts);
            put(writer, node.ordered ? "</ol>\n" : "</ul>\n");
            break;
        case AstKind.listItem:
            put(writer, "<li>");
            foreach (child; node.children)
                renderNode(child, writer, opts);
            put(writer, "</li>\n");
            break;
        case AstKind.text:
            writeEscaped(writer, node.literal);
            break;
        case AstKind.softBreak:
            if (opts.softBreakAs == '\n')
                put(writer, '\n');
            else
                put(writer, opts.softBreakAs);
            break;
        case AstKind.hardBreak:
            put(writer, "<br />\n");
            break;
        case AstKind.code:
            put(writer, "<code>");
            writeEscaped(writer, node.literal);
            put(writer, "</code>");
            break;
        case AstKind.emphasis:
            put(writer, "<em>");
            foreach (child; node.children)
                renderNode(child, writer, opts);
            put(writer, "</em>");
            break;
        case AstKind.strong:
            put(writer, "<strong>");
            foreach (child; node.children)
                renderNode(child, writer, opts);
            put(writer, "</strong>");
            break;
        case AstKind.link:
            put(writer, "<a href=\"");
            writeEscaped(writer, sanitizeUrl(node.destination));
            put(writer, "\">");
            foreach (child; node.children)
                renderNode(child, writer, opts);
            put(writer, "</a>");
            break;
        case AstKind.image:
            put(writer, "<img src=\"");
            writeEscaped(writer, sanitizeUrl(node.destination));
            put(writer, "\" alt=\"");
            writeEscaped(writer, node.alt);
            put(writer, "\" />");
            break;
        case AstKind.htmlInline:
            if (opts.unsafeHtml)
                put(writer, node.literal);
            else
                writeEscaped(writer, node.literal);
            break;
        case AstKind.autolink:
            put(writer, "<a href=\"");
            writeEscaped(writer, sanitizeUrl(node.destination));
            put(writer, "\">");
            writeEscaped(writer, node.destination);
            put(writer, "</a>");
            break;
        case AstKind.strikethrough:
            put(writer, "<del>");
            foreach (child; node.children)
                renderNode(child, writer, opts);
            put(writer, "</del>");
            break;
        default:
            foreach (child; node.children)
                renderNode(child, writer, opts);
            break;
    }
}

private const(char)[] fenceLanguage(const(char)[] info)
{
    if (info.length == 0)
        return null;

    auto trimmed = info.strip;
    if (trimmed.length == 0)
        return null;

    size_t i = 0;
    while (i < trimmed.length && trimmed[i] != ' ' && trimmed[i] != '\t' && trimmed[i] != '{' && trimmed[i] != ':')
        ++i;

    return trimmed[0 .. i];
}

private void writeEscaped(Writer)(ref Writer writer, const(char)[] text)
if (isOutputRange!(Writer, char))
{
    foreach (c; text)
    {
        switch (c)
        {
            case '&':
                put(writer, "&amp;");
                break;
            case '<':
                put(writer, "&lt;");
                break;
            case '>':
                put(writer, "&gt;");
                break;
            case '"':
                put(writer, "&quot;");
                break;
            default:
                put(writer, c);
                break;
        }
    }
}

private bool startsWithIgnoreAsciiCase(const(char)[] text, const(char)[] prefix)
{
    if (text.length < prefix.length)
        return false;

    foreach (i; 0 .. prefix.length)
    {
        char lhs = text[i];
        char rhs = prefix[i];

        if (lhs >= 'A' && lhs <= 'Z')
            lhs = cast(char) (lhs - 'A' + 'a');
        if (rhs >= 'A' && rhs <= 'Z')
            rhs = cast(char) (rhs - 'A' + 'a');

        if (lhs != rhs)
            return false;
    }

    return true;
}

private const(char)[] sanitizeUrl(const(char)[] destination)
{
    auto trimmed = destination.strip;
    if (trimmed.length == 0)
        return trimmed;

    if (startsWithIgnoreAsciiCase(trimmed, "javascript:") ||
        startsWithIgnoreAsciiCase(trimmed, "vbscript:"))
        return "";

    return trimmed;
}

@("markdown.profileDefaults.gfm")
@system unittest
{
    auto flags = withProfileDefaults(Profile.gfm, FeatureFlags.init);
    assert(flags.tables);
    assert(flags.strikethrough);
    assert(flags.taskLists);
    assert(flags.autolinks);
}

@("markdown.parse.headingAndParagraph")
@system unittest
{
    auto doc = "# Hello\n\nWelcome to *sparkles* parser.";
    auto result = parse(doc);

    assert(result.diagnostics.length == 0);

    auto html = result.toHtml();
    assert(html == "<h1>Hello</h1>\n<p>Welcome to <em>sparkles</em> parser.</p>\n");
}

@("markdown.parse.fencedCode")
@system unittest
{
    auto doc = "```d\nint x = 42;\n```\n";
    auto result = parse(doc);
    auto html = result.toHtml();

    assert(html == "<pre><code class=\"language-d\">int x = 42;\n</code></pre>\n");
}

@("markdown.ownership.borrowed")
@system unittest
{
    const(char)[] doc = "# Borrowed\n";
    auto result = parseBorrowed(doc);

    assert(result.source.ownership == SourceOwnership.borrowed);
}

@("markdown.ownership.owned")
@system unittest
{
    struct DummyAlloc
    {
    }

    DummyAlloc alloc;
    const(char)[] doc = "# Owned\r\n";

    auto result = parseOwned(doc, alloc);
    assert(result.source.ownership == SourceOwnership.owned);
}

@("markdown.preprocessHook")
@system unittest
{
    struct Hook
    {
        void preprocessDocument(ref ParseContext ctx)
        {
            ctx.input = "# Rewritten";
        }
    }

    auto opts = MarkdownOptions!Hook();
    opts.hook = Hook();

    auto result = parse("content", opts);
    assert(result.toHtml() == "<h1>Rewritten</h1>\n");
}

@("markdown.postParseHook")
@system unittest
{
    struct Hook
    {
        void onPostParse(ref EventStream events)
        {
            events ~= Event(
                kind: EventKind.text,
                tag: AstKind.text,
                span: SourceSpan(0, 0),
                literal: "tail",
            );
        }
    }

    auto opts = MarkdownOptions!Hook();
    opts.hook = Hook();

    auto result = parse("Text", opts);

    assert(result.events.length > 0);
    assert(result.events[$ - 1].literal == "tail");
}
