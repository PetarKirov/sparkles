/**
The full-fidelity token spine — the fidelity layer of `sparkles:dmd-fmt`.

This module is the proposal's M0-S1/S3 spike grown directly into the seed of
M1 (see `docs/research/code-formatting/dmd-fmt-proposal.md`): it lexes D
source with DMD's own lexer in its DMDLIB trivia configuration
(`commentToken: true, whitespaceToken: true`), records every token with its
exact byte span, and proves the stream reconstructs the input byte-for-byte.

Design facts this module encodes (each verified against the pinned fork and
exercised by a unittest below):

$(LIST
    * `Lexer.p` and `Lexer.token` are public, so after each `nextToken` the
        exact lexeme end is `p` — spans are measured, never inferred. For
        constructs that enqueue several tokens per scan (interpolated string
        sequences), `p` is only an upper bound, so ends are clamped to the next
        token's start.
    * `#line …` special token sequences are consumed by the lexer — including
        their terminating newline — with no token emitted (once `Id` state is
        initialized; see the `Id.initialize` bullet). The spine's gap synthesis surfaces
        those bytes as explicit `SpineClass.directive` entries so nothing is
        silently lost. The `#!` shebang line, which the lexer constructor
        consumes (newline included) before the first token, surfaces the same
        way.
    * A UTF-8 BOM is not the lexer's business (DMD's file loader strips it),
        so the spine strips it into an explicit prefix span.
    * The special-identifier rewrites — `__EOF__` → `TOK.endOfFile`,
        `__DATE__`/`__VENDOR__`/… → literal tokens — compare against
        `dmd.id.Id` globals and therefore $(B silently depend on
        `Id.initialize()` having run): without it, `__EOF__` is a plain
        identifier and lexing runs past it, diverging from compiler semantics.
        [lexSpine] initializes that state itself (once per process). With it,
        `__EOF__` yields `TOK.endOfFile` at the keyword and everything after
        stays unlexed — the spine's explicit tail span. Rewritten tokens'
        contents point outside the source buffer, so reconstruction must use
        byte spans, never token contents.
    * `commentToken: true` suppresses DDoc attachment: every comment arm
        returns before the `doDocComment` branch runs (`lexer.d:732–803`), so
        `Token.blockComment`/`lineComment` stay null on the trivia spine. DDoc
        checks need a second, `doDocComment: true` lex — see
        [verifyDocLexCorrespondence].
    * U+2028/U+2029 handling relies on two fork fixes to upstream's DMDLIB
        paths (tracked in the fork's PLAN-UPSTREAMING.md, aimed at dlang/dmd):
        a `//` comment terminated by LS/PS used to leave the scanner
        mid-sequence under `commentToken`, and bare LS/PS never produced a
        `whitespaceToken`. A regression test below covers both.
)
*/
module sparkles.dmd_fmt.spine;

import dmd.errorsink : ErrorSink, ErrorSinkNull;
import dmd.lexer : Lexer;
import dmd.tokens : TOK, Token;
import std.format : format;

/// What a spine entry is, at the fidelity layer.
enum SpineClass : ubyte
{
    /// A real D token, meaningful to the parser.
    token,
    /// Spacing bytes: `TOK.whitespace`, or `TOK.endOfLine` after a `#` line.
    whitespace,
    /// A comment token (`//`, `/* */`, `/+ +/`), DDoc included.
    comment,
    /// Bytes the lexer consumed without emitting a token: a `#line …`
    /// special token sequence, or the `#!` shebang line. `kind` is
    /// `TOK.reserved` for these entries; `cls` is authoritative.
    directive,
}

/// One spine entry: a classification, a token kind, and its exact byte span.
struct SpineToken
{
    /// Token kind as DMD's lexer reported it (`TOK.reserved` for synthesized
    /// `directive` entries).
    TOK kind;
    /// Fidelity-layer classification of this entry.
    SpineClass cls;
    /// Byte offset of the first byte of this entry within `TokenSpine.source`.
    uint start;
    /// Byte offset one past the last byte of this entry.
    uint end;

    /// Whether this entry is trivia (whitespace, comment, or directive).
    bool isTrivia() const @safe pure nothrow @nogc => cls != SpineClass.token;
}

/**
The lossless result of lexing one buffer with trivia retained.

The byte ranges partition the source exactly:
`[0, prefixEnd)` (a UTF-8 BOM, if any), then the `entries` spans
back-to-back, then `[tailStart, $)` (bytes at/after `__EOF__`, or empty).
*/
struct TokenSpine
{
    /// The exact bytes that were lexed (no sentinel, BOM included).
    const(char)[] source;
    /// Every entry, in source order, spans tiling `[prefixEnd, tailStart)`.
    SpineToken[] entries;
    /// End of the prefix the lexer never saw: 0, or 3 for a UTF-8 BOM.
    uint prefixEnd;
    /// Start of the unlexed tail (`__EOF__` and after); `source.length` if none.
    uint tailStart;
}

private enum utf8Bom = "\xEF\xBB\xBF";

// DMD's lexer reads and writes process-global state — the Identifier string
// table (`Identifier.idPool`) and the `dmd.id.Id` identifiers — none of it
// thread-safe: concurrent lexing from two threads segfaults (observed under
// the parallel test runner). Every lexing entry point in this module
// serializes on this lock. An LSP serving concurrent formatting requests
// inherits this constraint.
package __gshared Object dmdGlobalsLock;
private __gshared bool lexerGlobalsReady;

shared static this()
{
    dmdGlobalsLock = new Object;
}

// The lexer's special-identifier handling — `__EOF__` → TOK.endOfFile,
// `__DATE__`/`__VENDOR__` → literal tokens, and `#line` recognition inside
// `parseSpecialTokenSequence` — compares pooled identifiers against
// `dmd.id.Id` globals, which are null until `Id.initialize()` runs. Without
// it the token stream is materially different: `__EOF__` is an ordinary
// identifier and lexing runs PAST it, and `#line` splits into pound/number
// tokens instead of being consumed as a directive. Ensure the state once per
// process, under the lock. (Id.initialize pools identifiers idempotently; a
// later full `initDMD` in the same process re-pools the same entries.)
private void ensureLexerGlobals() @system
{
    if (lexerGlobalsReady)
        return;
    import dmd.id : Id;
    Id.initialize();
    lexerGlobalsReady = true;
}

/**
Lex `source` with DMD's lexer in the trivia configuration and build the spine.

Params:
    source = the exact file bytes; a UTF-8 BOM is allowed and becomes the
        prefix span

Returns: the spine; call [validateSpine] / [reconstruct] to check it.
*/
TokenSpine lexSpine(const(char)[] source) @system
{
    synchronized (dmdGlobalsLock)
    {
        ensureLexerGlobals();
        return lexSpineImpl(source);
    }
}

private TokenSpine lexSpineImpl(const(char)[] source) @system
{
    const bom = source.length >= 3 && source[0 .. 3] == utf8Bom ? 3u : 0u;
    const body_ = source[bom .. $];

    // The lexer requires base[endoffset] ∈ {0, 0x1A}; copy with a sentinel.
    auto buf = new char[](body_.length + 1);
    buf[0 .. body_.length] = body_[];
    buf[body_.length] = '\0';
    const base = buf.ptr;

    scope sink = new ErrorSinkNull;
    scope lexer = new Lexer(null, base, 0, body_.length,
        /*doDocComment*/ false, /*commentToken*/ true, /*whitespaceToken*/ true,
        sink);

    static struct Raw
    {
        TOK kind;
        uint start;
        uint pEnd; // lexer.p after nextToken — an upper bound on the lexeme end
    }

    Raw[] raw;
    while (lexer.nextToken() != TOK.endOfFile)
        raw ~= Raw(lexer.token.value,
            cast(uint) (lexer.token.ptr - base),
            cast(uint) (lexer.p - base));
    const eofStart = cast(uint) (lexer.token.ptr - base);

    TokenSpine spine;
    spine.source = source;
    spine.prefixEnd = bom;
    spine.tailStart = bom + eofStart;

    static SpineClass classify(TOK kind) @safe pure nothrow @nogc
    {
        switch (kind)
        {
            case TOK.whitespace, TOK.endOfLine: return SpineClass.whitespace;
            case TOK.comment: return SpineClass.comment;
            default: return SpineClass.token;
        }
    }

    uint prev = 0; // end of the previous entry, relative to `base`
    foreach (i, r; raw)
    {
        if (r.start > prev) // bytes the lexer consumed silently: a directive
            spine.entries ~= SpineToken(TOK.reserved, SpineClass.directive,
                bom + prev, bom + r.start);
        const nextStart = i + 1 < raw.length ? raw[i + 1].start : eofStart;
        // Clamp: for token sequences enqueued by one scan (interpolated
        // strings), `pEnd` is past the whole construct.
        const end = r.pEnd < nextStart ? r.pEnd : nextStart;
        spine.entries ~= SpineToken(r.kind, classify(r.kind),
            bom + r.start, bom + end);
        prev = end;
    }
    if (eofStart > prev)
        spine.entries ~= SpineToken(TOK.reserved, SpineClass.directive,
            bom + prev, bom + eofStart);

    return spine;
}

/// Write the exact original bytes back out from the spine's spans.
void reconstruct(Writer)(in TokenSpine spine, ref Writer w)
{
    w.put(spine.source[0 .. spine.prefixEnd]);
    foreach (t; spine.entries)
        w.put(spine.source[t.start .. t.end]);
    w.put(spine.source[spine.tailStart .. $]);
}

/**
Check every structural invariant of the spine.

Checked: span ordering and exact tiling of `[prefixEnd, tailStart)`; the
prefix is empty or a UTF-8 BOM; whitespace entries contain only whitespace
bytes (ASCII spacing plus U+2028/U+2029); comment entries start with `//`,
`/*` or `/+`; directive entries start with `#`; and byte-for-byte
reconstruction equals the source.

Returns: `null` when all invariants hold, else a description of the first
violation.
*/
string validateSpine(in TokenSpine spine) @safe
{
    const src = spine.source;
    if (spine.prefixEnd > spine.tailStart || spine.tailStart > src.length)
        return format!"bad partition: prefixEnd=%s tailStart=%s length=%s"(
            spine.prefixEnd, spine.tailStart, src.length);
    if (spine.prefixEnd != 0 &&
        (spine.prefixEnd != 3 || src[0 .. 3] != utf8Bom))
        return "prefix is not a UTF-8 BOM";

    uint cursor = spine.prefixEnd;
    foreach (i, t; spine.entries)
    {
        if (t.start != cursor)
            return format!"entry %s (%s) starts at %s, expected %s"(
                i, t.kind, t.start, cursor);
        if (t.end < t.start || t.end > spine.tailStart)
            return format!"entry %s (%s) has bad end %s"(i, t.kind, t.end);
        if (t.end == t.start)
            return format!"entry %s (%s) is empty at %s"(i, t.kind, t.start);
        const text = src[t.start .. t.end];
        final switch (t.cls)
        {
            case SpineClass.whitespace:
                if (const bad = firstNonWhitespace(text))
                    return format!"whitespace entry %s at %s contains %s"(
                        i, t.start, *bad);
                break;
            case SpineClass.comment:
                if (text.length < 2 || text[0] != '/' ||
                    (text[1] != '/' && text[1] != '*' && text[1] != '+'))
                    return format!"comment entry %s at %s starts with %(%s%)"(
                        i, t.start, text[0 .. text.length < 2 ? $ : 2]);
                break;
            case SpineClass.directive:
                if (text[0] != '#')
                    return format!"directive entry %s at %s starts with %s"(
                        i, t.start, text[0]);
                break;
            case SpineClass.token:
                break;
        }
        cursor = t.end;
    }
    if (cursor != spine.tailStart)
        return format!"entries end at %s, tail starts at %s"(
            cursor, spine.tailStart);

    import std.array : appender;
    auto w = appender!(char[]);
    () @trusted { reconstruct(spine, w); }();
    if (w[] != src)
        return "reconstruction differs from the source";
    return null;
}

/// Pointer to the first byte of `text` that is not D whitespace
/// (ASCII spacing or a UTF-8 U+2028/U+2029 sequence), or `null`.
private const(char)* firstNonWhitespace(const(char)[] text) @safe pure nothrow @nogc
{
    for (size_t i = 0; i < text.length; i++)
    {
        switch (text[i])
        {
            case ' ', '\t', '\v', '\f', '\r', '\n':
                continue;
            case 0xE2: // U+2028 (LS) / U+2029 (PS): E2 80 A8 / E2 80 A9
                if (i + 2 < text.length && text[i + 1] == 0x80 &&
                    (text[i + 2] == 0xA8 || text[i + 2] == 0xA9))
                {
                    i += 2;
                    continue;
                }
                goto default;
            default:
                return () @trusted { return &text[i]; }();
        }
    }
    return null;
}

/**
The seed of the M1 tier-3 verifier: the spine's non-trivia entries must match
a plain (trivia-off) lex of the same source in kind and start offset.

Returns: `null` on success, else a description of the first mismatch.
*/
string verifyAgainstPlainLex(in TokenSpine spine) @system
{
    synchronized (dmdGlobalsLock)
    {
        ensureLexerGlobals();
        return verifyAgainstPlainLexImpl(spine);
    }
}

private string verifyAgainstPlainLexImpl(in TokenSpine spine) @system
{
    const bom = spine.prefixEnd;
    const body_ = spine.source[bom .. $];
    auto buf = new char[](body_.length + 1);
    buf[0 .. body_.length] = body_[];
    buf[body_.length] = '\0';

    scope sink = new ErrorSinkNull;
    scope lexer = new Lexer(null, buf.ptr, 0, body_.length,
        /*doDocComment*/ false, /*commentToken*/ false, sink,
        /*compileEnv*/ null);

    size_t i = 0;
    while (lexer.nextToken() != TOK.endOfFile)
    {
        while (i < spine.entries.length && spine.entries[i].isTrivia)
            i++;
        if (i == spine.entries.length)
            return format!"plain lex has extra %s at %s"(
                lexer.token.value, lexer.token.ptr - buf.ptr);
        const t = spine.entries[i];
        const start = bom + cast(uint) (lexer.token.ptr - buf.ptr);
        if (t.kind != lexer.token.value || t.start != start)
            return format!"mismatch at entry %s: spine %s@%s vs plain %s@%s"(
                i, t.kind, t.start, lexer.token.value, start);
        i++;
    }
    while (i < spine.entries.length && spine.entries[i].isTrivia)
        i++;
    if (i != spine.entries.length)
        return format!"spine has extra %s at %s"(
            spine.entries[i].kind, spine.entries[i].start);
    return null;
}

/**
The M0-S3 double-lex correspondence check: a second, `doDocComment: true`
lex (the DDoc-attachment oracle — attachment is $(I not) available on the
trivia spine) must agree with the spine's non-trivia entries in kind and
start offset, so DDoc positions can be mapped between the two streams.

Returns: `null` on success, else a description of the first mismatch.
*/
string verifyDocLexCorrespondence(in TokenSpine spine) @system
{
    synchronized (dmdGlobalsLock)
    {
        ensureLexerGlobals();
        return verifyDocLexCorrespondenceImpl(spine);
    }
}

private string verifyDocLexCorrespondenceImpl(in TokenSpine spine) @system
{
    const bom = spine.prefixEnd;
    const body_ = spine.source[bom .. $];
    auto buf = new char[](body_.length + 1);
    buf[0 .. body_.length] = body_[];
    buf[body_.length] = '\0';

    scope sink = new ErrorSinkNull;
    scope lexer = new Lexer(null, buf.ptr, 0, body_.length,
        /*doDocComment*/ true, /*commentToken*/ false, sink,
        /*compileEnv*/ null);

    size_t i = 0;
    while (lexer.nextToken() != TOK.endOfFile)
    {
        while (i < spine.entries.length && spine.entries[i].isTrivia)
            i++;
        if (i == spine.entries.length)
            return format!"doc lex has extra %s at %s"(
                lexer.token.value, lexer.token.ptr - buf.ptr);
        const t = spine.entries[i];
        const start = bom + cast(uint) (lexer.token.ptr - buf.ptr);
        if (t.kind != lexer.token.value || t.start != start)
            return format!"mismatch at entry %s: spine %s@%s vs doc %s@%s"(
                i, t.kind, t.start, lexer.token.value, start);
        i++;
    }
    return null;
}

version (unittest)
{
    /// Run every spine check on one source; returns null or the first failure.
    private string checkSource(string source) @system
    {
        auto spine = lexSpine(source);
        if (const err = validateSpine(spine))
            return err;
        if (const err = verifyAgainstPlainLex(spine))
            return err;
        if (const err = verifyDocLexCorrespondence(spine))
            return err;
        return null;
    }

    private void assumeClean(string source, string file = __FILE__, size_t line = __LINE__) @system
    {
        import core.exception : AssertError;
        if (const err = checkSource(source))
            throw new AssertError(err, file, line);
    }
}

@("spine.roundtrip.basic")
@system unittest
{
    assumeClean("void test() {} // foobar\n");
    assumeClean("int  x =  5 ;\n\tchar c;\r\n");
}

@("spine.roundtrip.empty-and-trivia-only")
@system unittest
{
    assumeClean("");
    assumeClean("\n");
    assumeClean("   \n\t \n");
    assumeClean("// only a comment, no newline");
    assumeClean("/* block */");
}

@("spine.roundtrip.comments")
@system unittest
{
    assumeClean("/// ddoc line\nvoid f();\n");
    assumeClean("/** ddoc block */\nvoid f();\n");
    assumeClean("/+ nested /+ deeper /+ more +/ +/ still comment +/ int x;\n");
    assumeClean("int a; // trailing\nint b; /* mid */ int c;\n");
}

@("spine.roundtrip.string-literals-verbatim")
@system unittest
{
    assumeClean(q"[auto s = q{ int nested; { tokens } };]" ~ "\n");
    assumeClean("auto s = q\"(paren (nested) delimited)\";\n");
    assumeClean("auto s = q\"EOS\nheredoc line\nEOS\";\n");
    assumeClean("auto s = r\"C:\\raw\\wysiwyg\";\n");
    assumeClean("auto s = `backtick \\n not escape`;\n");
    assumeClean("auto s = x\"deadbeef\";\n");
    assumeClean("auto c = '\\n'; auto d = '\\u2028';\n");
}

@("spine.roundtrip.line-endings-and-unicode")
@system unittest
{
    assumeClean("int a;\r\nint b;\r\nint c;\n");
    assumeClean("// ünïcödé 🌟\nstring s = \"日本語テキスト\";\n");
    assumeClean("int äöü = 1;\n");
}

@("spine.roundtrip.LS-PS-terminated-and-bare")
@system unittest
{
    // Regression coverage for the fork's DMDLIB LS/PS fix (tracked in the
    // fork's PLAN-UPSTREAMING.md): a // comment terminated by U+2028/U+2029
    // used to leave the scanner mid-sequence in the commentToken path, and
    // bare U+2028/U+2029 were consumed without a whitespace token.
    assumeClean("int a; // comment\u2028int b;\n");
    assumeClean("int a; // comment\u2029int b;\n");
    assumeClean("int a;\u2028int b;\n");
    assumeClean("int a;\u2029int b;\n");
}

@("spine.roundtrip.predefined-tokens-rewritten-not-copied")
@system unittest
{
    // __DATE__ is rewritten by the lexer into a string literal whose content
    // is not in the source buffer; span-based reconstruction must not care.
    assumeClean("string s = __DATE__;\nstring t = __VENDOR__;\n");
}

@("spine.eof.__EOF__-keeps-the-tail")
@system unittest
{
    enum src = "int x;\n__EOF__\nnot D code at all &&& ***\n";
    auto spine = lexSpine(src);
    assert(validateSpine(spine) is null);
    // The tail must start exactly at __EOF__ and reach the end of the file.
    assert(spine.source[spine.tailStart .. $] ==
        "__EOF__\nnot D code at all &&& ***\n");
    assumeClean(src);
}

@("spine.prefix.shebang-surfaces-as-directive")
@system unittest
{
    enum src = "#!/usr/bin/env dub\nvoid main() {}\n";
    auto spine = lexSpine(src);
    assert(validateSpine(spine) is null);
    assert(spine.entries.length > 0);
    assert(spine.entries[0].cls == SpineClass.directive);
    // The constructor consumes the shebang INCLUDING its newline.
    assert(spine.source[spine.entries[0].start .. spine.entries[0].end]
        == "#!/usr/bin/env dub\n");
    assumeClean(src);
}

@("spine.prefix.utf8-bom")
@system unittest
{
    enum src = "\xEF\xBB\xBFvoid main() {}\n";
    auto spine = lexSpine(src);
    assert(validateSpine(spine) is null);
    assert(spine.prefixEnd == 3);
    assumeClean(src);
    assumeClean("\xEF\xBB\xBF#!/usr/bin/env dub\nint x;\n");
}

@("spine.directive.hash-line-is-a-swallowed-gap")
@system unittest
{
    // S1 finding: with `Id.initialize()` run (which [lexSpine] guarantees),
    // `parseSpecialTokenSequence` recognizes `#line` and consumes the whole
    // directive INCLUDING its terminating newline, emitting no token. The
    // spine's gap synthesis surfaces those bytes as a directive entry.
    // (Without Id state the same input splits into pound/number/endOfLine
    // tokens — the lexer's stream is a function of global Id state, which is
    // why lexSpine initializes it itself.)
    enum src = "int a;\n#line 42\nint b;\n";
    auto spine = lexSpine(src);
    assert(validateSpine(spine) is null);
    bool sawDirective;
    foreach (t; spine.entries)
        if (t.cls == SpineClass.directive)
        {
            sawDirective = true;
            assert(spine.source[t.start .. t.end] == "#line 42\n");
        }
    assert(sawDirective);
    assumeClean(src);
    assumeClean("#line 1\nint x;\n");
    assumeClean("int y;\n#line 7 \"other.d\"\n");
}

@("spine.roundtrip.interpolated-sequences")
@system unittest
{
    // One scan enqueues several tokens; ends are clamped to the next start.
    assumeClean("auto s = i\"hello $(name) end\";\n");
    assumeClean("auto s = iq{ $(a + b) tokens };\n");
}

@("spine.s3.commentToken-suppresses-ddoc-attachment")
@system unittest
{
    // Verified in lexer.d:732-803: with commentToken on, getDocComment never
    // runs, so no token on the trivia spine carries DDoc attachment. This is
    // the M0-S3 finding that forces the double-lex design.
    enum code = "/** doc for f */\nvoid f();\n/// doc for g\nvoid g();\n";
    auto buf = new char[](code.length + 1);
    buf[0 .. code.length] = code[];
    buf[code.length] = '\0';
    synchronized (dmdGlobalsLock)
    {
        scope sink = new ErrorSinkNull;
        scope lexer = new Lexer(null, buf.ptr, 0, code.length,
            /*doDocComment*/ true, /*commentToken*/ true, /*whitespaceToken*/ true,
            sink);
        while (lexer.nextToken() != TOK.endOfFile)
        {
            assert(lexer.token.blockComment is null);
            assert(lexer.token.lineComment is null);
        }
    }
}

@("spine.s3.doc-lex-populates-attachment")
@system unittest
{
    // The doc-lex configuration (commentToken off) is the attachment oracle.
    enum code = "/** doc for f */\nvoid f();\n";
    auto buf = new char[](code.length + 1);
    buf[0 .. code.length] = code[];
    buf[code.length] = '\0';
    synchronized (dmdGlobalsLock)
    {
        scope sink = new ErrorSinkNull;
        scope lexer = new Lexer(null, buf.ptr, 0, code.length,
            /*doDocComment*/ true, /*commentToken*/ false, sink,
            /*compileEnv*/ null);
        bool sawAttachment = false;
        while (lexer.nextToken() != TOK.endOfFile)
            if (lexer.token.blockComment !is null)
            {
                sawAttachment = true;
                assert(lexer.token.value == TOK.void_);
            }
        assert(sawAttachment);
    }
}

@("spine.s3.double-lex-offset-correspondence")
@system unittest
{
    enum code = "/** doc */\nvoid f() { int x = 1; }\n/// more\nint g;\n";
    auto spine = lexSpine(code);
    assert(validateSpine(spine) is null);
    assert(verifyDocLexCorrespondence(spine) is null);
}

@("spine.corpus.round-trips-repo-sources")
@system unittest
{
    // The S1 corpus leg: every D source under the listed in-repo trees must
    // pass the full check stack — structural validation, byte-for-byte
    // reconstruction, token equality against a plain lex, and doc-lex
    // offset correspondence.
    import core.exception : AssertError;
    import std.file : dirEntries, read, SpanMode;
    import std.path : buildPath, dirName;

    enum thisDir = __FILE_FULL_PATH__.dirName;
    enum repoRoot = thisDir.dirName.dirName.dirName.dirName.dirName;
    static immutable corpusDirs = [
        "libs/base/src",
        "libs/dmd-fmt/src",
        "libs/dmd-lsp/src",
    ];

    size_t files;
    foreach (dir; corpusDirs)
        foreach (entry; dirEntries(buildPath(repoRoot, dir), "*.d", SpanMode.depth))
        {
            const source = cast(string) read(entry.name);
            if (const err = checkSource(source))
                throw new AssertError(entry.name ~ ": " ~ err);
            files++;
        }
    assert(files > 20, "corpus unexpectedly small — path resolution broke?");
}

@("spine.granularity.verbatim-constructs-are-single-entries")
@system unittest
{
    // The S4 fidelity-layer inventory, pinned: every construct below is ONE
    // spine entry, so its end — and its verbatim-ness — is the entry span
    // itself. No oracle, no bracket matching, no lookahead.
    static void assertSingleEntry(string code, string lexeme) @system
    {
        auto spine = lexSpine(code);
        foreach (t; spine.entries)
            if (spine.source[t.start .. t.end] == lexeme)
                return;
        assert(false, "not lexed as one entry: " ~ lexeme);
    }

    assertSingleEntry("auto s = q{ int nested; { tokens } };",
        "q{ int nested; { tokens } }");
    assertSingleEntry("auto s = q\"EOS\nline\nEOS\";", "q\"EOS\nline\nEOS\"");
    assertSingleEntry("auto s = q\"(paren (nested))\";", "q\"(paren (nested))\"");
    assertSingleEntry("auto s = x\"deadbeef\";", "x\"deadbeef\"");
    assertSingleEntry("auto s = i\"a $(b) c\";", "i\"a $(b) c\"");
    assertSingleEntry("auto s = iq{ $(a) t };", "iq{ $(a) t }");
    assertSingleEntry("/+ a /+ b +/ c +/ int x;", "/+ a /+ b +/ c +/");
}

@("spine.corpus.expressionsem-round-trips")
@system unittest
{
    // The large-real-world-file leg: dmd's expressionsem.d (~20 kLOC), read
    // from `$SPARKLES_FLAKE_INPUT_DMD_SRC` so the corpus is portable and
    // grammar-matched.
    import std.file : exists, read;
    import std.path : buildPath;
    import std.process : environment;

    const dmdSrc = environment.get("SPARKLES_FLAKE_INPUT_DMD_SRC", "");
    assert(dmdSrc.length,
        "SPARKLES_FLAKE_INPUT_DMD_SRC not set (enter `nix develop`)");
    const path = buildPath(dmdSrc, "compiler", "src", "dmd", "expressionsem.d");
    assert(path.exists,
        "expressionsem.d missing under SPARKLES_FLAKE_INPUT_DMD_SRC: " ~ path);
    assumeClean(() @trusted { return cast(string) read(path); }());
}
