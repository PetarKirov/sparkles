/**
The M1 verifier — how the formatter proves it did not break your code,
built $(B before) any layout code exists so it can never be written to agree
with a printer's bugs (the ordering `docs/specs/dmd-fmt/` D8 fixes, borrowed
from ocamlformat and ruff).

Three checks, layered per the survey's verification ladder
(`docs/research/code-formatting/verification.md`):

$(LIST
    * [verifyFormat] tier 3 — $(B token equality modulo whitespace): the
        original and the formatted text must agree byte-for-byte on the
        prefix (BOM) and the unlexed tail (`__EOF__`…), and entry-for-entry
        on every non-whitespace spine entry — kind $(I and) text, comments
        and directives included (both are verbatim in v1, so exact text is
        the contract; a future comment-reindenting pass relaxes this
        deliberately, not accidentally). This one check catches dropped
        tokens, mangled literals and lost comments without a reparse.
    * [verifyFormat] DDoc — $(B a separate check with its own error)
        (ocamlformat's `moved_docstrings`): both texts are doc-lexed (the
        second lexer configuration of D4 — attachment is not available on
        the trivia spine) and the compiler's own attachment of every doc
        comment must be unchanged: same code-token ordinal, same slot
        (preceding `blockComment` vs trailing `lineComment`), same text.
        This fires exactly where tier 3 cannot: a whitespace-only change
        that moves a trailing `/// doc` onto its own line silently
        re-attaches it to the $(I next) declaration.
    * [checkConvergence] — the idempotence harness: apply a formatter until
        a fixed point, bounded by `maxIters`, verifying every step with
        [verifyFormat]. Non-convergence and mid-chain corruption are both
        reportable results, not curiosities.
)

CI wiring: the harness runs under `dub test` today (which `ci --test`
covers); the `dub run :ci` verbatim-corpus sweep lands with M5's `--check`,
when there is a formatter to drive it.
*/
module sparkles.dmd_fmt.verify;

import sparkles.dmd_fmt.spine : dmdGlobalsLock, ensureLexerGlobals, lexSpine,
    SpineClass, TokenSpine;

import std.format : format;

/// The outcome of [verifyFormat]: each check carries its own error, per the
/// proposal's "its own check, its own error".
struct VerifyReport
{
    /// Tier-3 failure (`null` when the token streams agree).
    string tokenError;
    /// DDoc-attachment failure (`null` when no doc comment moved; only
    /// meaningful when `tokenError` is `null`).
    string ddocError;

    /// Whether the formatted text is verified safe.
    bool ok() const @safe pure nothrow @nogc
        => tokenError is null && ddocError is null;
}

/**
Verify that `formatted` is a layout-only transformation of `original`.

Runs tier 3 first; the DDoc check runs only when tier 3 passes (attachment
ordinals are only comparable over identical code-token sequences).
*/
VerifyReport verifyFormat(const(char)[] original, const(char)[] formatted) @system
{
    VerifyReport report;
    report.tokenError = compareTokens(lexSpine(original), lexSpine(formatted));
    if (report.tokenError is null)
        report.ddocError = compareDdocAttachment(original, formatted);
    return report;
}

private string compareTokens(const TokenSpine a, const TokenSpine b) @safe
{
    if (a.source[0 .. a.prefixEnd] != b.source[0 .. b.prefixEnd])
        return "prefix (BOM) differs";
    if (a.source[a.tailStart .. $] != b.source[b.tailStart .. $])
        return "unlexed tail differs (bytes at/after __EOF__ are verbatim)";

    size_t ia, ib;
    for (size_t ordinal = 0;; ordinal++)
    {
        while (ia < a.entries.length && a.entries[ia].cls == SpineClass.whitespace)
            ia++;
        while (ib < b.entries.length && b.entries[ib].cls == SpineClass.whitespace)
            ib++;
        const aDone = ia == a.entries.length;
        const bDone = ib == b.entries.length;
        if (aDone || bDone)
            return aDone == bDone ? null
                : format!"entry count differs: %s has extra %s at offset %s"(
                    aDone ? "formatted" : "original",
                    aDone ? b.entries[ib].kind : a.entries[ia].kind,
                    aDone ? b.entries[ib].start : a.entries[ia].start);

        const ta = a.entries[ia];
        const tb = b.entries[ib];
        const textA = a.source[ta.start .. ta.end];
        const textB = b.source[tb.start .. tb.end];
        if (ta.cls != tb.cls || ta.kind != tb.kind || textA != textB)
            return format!"entry %s differs: %s %s %(%s%) vs %s %s %(%s%)"(
                ordinal, ta.cls, ta.kind, [clip(textA)],
                tb.cls, tb.kind, [clip(textB)]);
        ia++;
        ib++;
    }
}

private const(char)[] clip(const(char)[] text) @safe pure nothrow @nogc
    => text.length <= 40 ? text : text[0 .. 40];

/// One doc comment as the compiler attached it: to which code token
/// (ordinal), in which slot, with what text.
private struct Attachment
{
    size_t ordinal;
    string block; // doc comment preceding the token
    string line;  // trailing doc comment (for the previous declaration)
}

private string compareDdocAttachment(const(char)[] original,
    const(char)[] formatted) @system
{
    const a = docLex(original);
    const b = docLex(formatted);
    foreach (i; 0 .. a.length < b.length ? a.length : b.length)
        if (a[i] != b[i])
            return format!(
                "doc comment moved: original attaches %(%s%)/%(%s%) at code token %s, "
                ~ "formatted %(%s%)/%(%s%) at %s")(
                [clip(a[i].block)], [clip(a[i].line)], a[i].ordinal,
                [clip(b[i].block)], [clip(b[i].line)], b[i].ordinal);
    if (a.length != b.length)
        return format!"doc comment %s: %s attachments became %s"(
            a.length > b.length ? "lost" : "gained", a.length, b.length);
    return null;
}

/// The doc-lex: the `doDocComment: true` configuration (attachment is not
/// available on the trivia spine — D4/S3), reduced to the attachment list.
private Attachment[] docLex(const(char)[] source) @system
{
    import dmd.errorsink : ErrorSinkNull;
    import dmd.lexer : Lexer;
    import dmd.tokens : TOK;

    // Strip a UTF-8 BOM exactly as lexSpine does, and terminate the buffer.
    const bom = source.length >= 3 && source[0 .. 3] == "\xEF\xBB\xBF" ? 3 : 0;
    const body_ = source[bom .. $];
    auto buf = new char[](body_.length + 1);
    buf[0 .. body_.length] = body_[];
    buf[body_.length] = '\0';

    synchronized (dmdGlobalsLock)
    {
        ensureLexerGlobals();
        scope sink = new ErrorSinkNull;
        scope lexer = new Lexer(null, buf.ptr, 0, body_.length,
            /*doDocComment*/ true, /*commentToken*/ false, sink,
            /*compileEnv*/ null);

        Attachment[] attachments;
        size_t ordinal;
        while (lexer.nextToken() != TOK.endOfFile)
        {
            if (lexer.token.blockComment !is null ||
                lexer.token.lineComment !is null)
                attachments ~= Attachment(ordinal,
                    lexer.token.blockComment.idup, lexer.token.lineComment.idup);
            ordinal++;
        }
        // The endOfFile token can carry a trailing doc comment too.
        if (lexer.token.blockComment !is null || lexer.token.lineComment !is null)
            attachments ~= Attachment(ordinal,
                lexer.token.blockComment.idup, lexer.token.lineComment.idup);
        return attachments;
    }
}

/// The outcome of [checkConvergence].
struct Convergence
{
    /// Whether a fixed point was reached within the bound.
    bool converged;
    /// Format applications performed (0 = the input was already formatted).
    uint iterations;
    /// The first per-step [verifyFormat] failure, or `null`; when set, the
    /// iteration stopped there and `converged` is `false`.
    string error;
}

/**
The idempotence harness: apply `formatOne` (any callable from `const(char)[]`
to text) until its output stops changing, verifying every step, giving up
after `maxIters` applications (ocamlformat's `max-iters` discipline — its
default is 10 too).
*/
Convergence checkConvergence(F)(scope F formatOne, const(char)[] source,
    uint maxIters = 10)
if (is(typeof(formatOne(cast(const(char)[]) null)) : const(char)[]))
{
    auto current = source;
    foreach (i; 0 .. maxIters)
    {
        const next = formatOne(current);
        const report = verifyFormat(current, next);
        if (!report.ok)
            return Convergence(false, i + 1, report.tokenError !is null
                ? report.tokenError : report.ddocError);
        if (next == current)
            return Convergence(true, i);
        current = next;
    }
    return Convergence(false, maxIters, null);
}

// ---------------------------------------------------------------------------

@("verify.tier3.whitespace-only-changes-pass")
@system unittest
{
    enum original = "int  a =  1; // keep\n\n\n/* mid */  int b;\n";
    enum formatted = "int a = 1; // keep\n\n/* mid */\nint b;\n";
    const report = verifyFormat(original, formatted);
    assert(report.ok, report.tokenError ~ report.ddocError);
}

@("verify.tier3.dropped-comment-fails")
@system unittest
{
    const report = verifyFormat("int a; // gone\nint b;\n", "int a;\nint b;\n");
    assert(report.tokenError !is null);
}

@("verify.tier3.changed-literal-fails")
@system unittest
{
    const report = verifyFormat("auto s = \"x\";\n", "auto s = \"y\";\n");
    assert(report.tokenError !is null);
}

@("verify.tier3.dropped-token-fails")
@system unittest
{
    const report = verifyFormat("int a;\nint b;\n", "int a;\nint b\n");
    assert(report.tokenError !is null);
}

@("verify.tier3.prefix-and-tail-are-verbatim")
@system unittest
{
    // Dropping the BOM fails; touching bytes after __EOF__ fails.
    assert(verifyFormat("\xEF\xBB\xBFint a;\n", "int a;\n").tokenError !is null);
    assert(verifyFormat("int a;\n__EOF__ raw\n", "int a;\n__EOF__ RAW\n")
        .tokenError !is null);
    assert(verifyFormat("int a;\n__EOF__ raw\n", "int  a;\n__EOF__ raw\n").ok);
}

@("verify.ddoc.trailing-doc-reattachment-caught")
@system unittest
{
    // The hazard tier 3 cannot see: identical token sequence, but moving a
    // trailing doc comment onto its own line re-attaches it from `a` to `b`.
    enum original = "int a; /// doc\nint b;\n";
    enum formatted = "int a;\n/// doc\nint b;\n";
    const report = verifyFormat(original, formatted);
    assert(report.tokenError is null);
    assert(report.ddocError !is null, "expected the DDoc check to fire");
}

@("verify.ddoc.preserved-attachment-passes")
@system unittest
{
    // Whitespace changes that do NOT move attachment are fine.
    enum original = "/** doc */ void f();\nint a; /// trailing\nint b;\n";
    enum formatted = "/** doc */\nvoid f();\nint a; /// trailing\nint b;\n";
    const report = verifyFormat(original, formatted);
    assert(report.ok, report.tokenError ~ report.ddocError);
}

@("verify.convergence.fixed-point-and-oscillation")
@system unittest
{
    import std.array : replace;

    // Collapses runs of spaces: reaches a fixed point.
    static const(char)[] collapse(const(char)[] s) @system
        => s.replace("  ", " ");
    const good = checkConvergence(&collapse, "int  a  =  1;\n");
    assert(good.converged && good.error is null);
    assert(good.iterations >= 1);
    assert(checkConvergence(&collapse, "int a;\n").iterations == 0);

    // Oscillates between two spellings: must be reported, not looped.
    static const(char)[] oscillate(const(char)[] s) @system
    {
        import std.algorithm.searching : canFind;

        return s.canFind("  ") ? s.replace("  ", " \t") : s.replace(" \t", "  ");
    }
    const bad = checkConvergence(&oscillate, "int  a;\n");
    assert(!bad.converged && bad.error is null);
    assert(bad.iterations == 10);

    // A "formatter" that corrupts tokens is caught mid-chain.
    static const(char)[] corrupt(const(char)[] s) @system
        => s.replace("a", "b");
    const broken = checkConvergence(&corrupt, "int a;\n");
    assert(!broken.converged && broken.error !is null);
    assert(broken.iterations == 1);
}

@("verify.corpus.identity-verifies-repo-sources")
@system unittest
{
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
            const source = () @trusted { return cast(string) read(entry.name); }();
            const report = verifyFormat(source, source);
            assert(report.ok, entry.name ~ ": " ~ report.tokenError ~ report.ddocError);
            files++;
        }
    assert(files > 20, "corpus unexpectedly small — path resolution broke?");
}

@("verify.corpus.identity-verifies-expressionsem")
@system unittest
{
    // The 20 kLOC leg, from the `dmd-src` flake input (enter `nix develop`).
    import std.file : exists, read;
    import std.path : buildPath;
    import std.process : environment;

    const dmdSrc = environment.get("SPARKLES_FLAKE_INPUT_DMD_SRC", "");
    assert(dmdSrc.length,
        "SPARKLES_FLAKE_INPUT_DMD_SRC not set (enter `nix develop`)");
    const path = buildPath(dmdSrc, "compiler", "src", "dmd", "expressionsem.d");
    assert(path.exists,
        "expressionsem.d missing under SPARKLES_FLAKE_INPUT_DMD_SRC: " ~ path);
    const source = () @trusted { return cast(string) read(path); }();
    const report = verifyFormat(source, source);
    assert(report.ok, report.tokenError ~ report.ddocError);
}
