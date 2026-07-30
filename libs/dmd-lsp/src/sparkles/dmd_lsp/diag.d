/**
Structured diagnostics capture for `sparkles:dmd-lsp` — the counterpart of
`dmdserver`'s `dmderrors.d` (Boost-1.0), re-expressed over the frontend's
`DiagnosticHandler` hook with a typed sink instead of a rendered wire string
(spec `COR3`).

The handler formats each message once (`vsnprintf`, exactly as the console
path would) and classifies it by its header. Supplemental messages — DMD's
`errorSupplemental` chains, whose header is blank — attach to the preceding
primary diagnostic as `notes` rather than becoming top-level entries.
*/
module sparkles.dmd_lsp.diag;

import core.stdc.stdarg : va_list;

import dmd.console : Color;
import dmd.location : SourceLoc;

/// Diagnostic severity, derived from the frontend's message header.
enum DiagKind : ubyte
{
    error,
    warning,
    deprecation,
    message, /// `pragma(msg)` / tips / anything unclassified
}

/// One source position (1-based line, 1-based UTF-8-code-unit column —
/// DMD-native coordinates, spec `COR4`).
struct DiagPos
{
    string filename;
    uint line;
    uint column;
}

/// One captured diagnostic, with its supplemental-note chain.
struct Diagnostic
{
    DiagPos pos;
    DiagKind kind;
    string message;
    Diagnostic[] notes; /// `errorSupplemental` chains (never nested further)
}

/// The collecting sink a `DiagnosticHandler` writes into.
struct DiagnosticSink
{
    Diagnostic[] diagnostics;

    /// Number of `DiagKind.error` entries.
    size_t errorCount() const @safe pure nothrow @nogc
    {
        size_t n;
        foreach (ref d; diagnostics)
            n += d.kind == DiagKind.error;
        return n;
    }

    bool hasErrors() const @safe pure nothrow @nogc => errorCount != 0;

    /// The frontend hook body: format, classify, attach-or-append.
    /// Returns true so the frontend skips its own console output.
    bool handle(const ref SourceLoc loc, Color headerColor, const(char)* header,
        const(char)* messageFormat, va_list args, const(char)* prefix1,
        const(char)* prefix2) nothrow
    {
        import core.stdc.stdio : vsnprintf;
        import core.stdc.string : strlen;

        char[4096] buf = void;
        va_list argsCopy;
        version (X86_64)
        {
            // va_list is an array type on SysV x86-64; copy via va_copy.
            import core.stdc.stdarg : va_copy, va_end;

            va_copy(argsCopy, args);
            scope (exit) va_end(argsCopy);
        }
        else
            argsCopy = args;
        const len = vsnprintf(buf.ptr, buf.length, messageFormat, argsCopy);

        try
        {
            string text;
            if (prefix1 !is null)
                text ~= prefix1[0 .. strlen(prefix1)] ~ " ";
            if (prefix2 !is null)
                text ~= prefix2[0 .. strlen(prefix2)] ~ " ";
            text ~= buf[0 .. len < 0 ? 0 : (len < buf.length ? len : buf.length - 1)];

            const headerText = header is null ? "" : header[0 .. strlen(header)];
            auto d = Diagnostic(
                pos: DiagPos(loc.filename.idup, loc.line, loc.column),
                kind: classify(headerText),
                message: text);

            // A blank/whitespace header is errorSupplemental's continuation —
            // attach to the last primary diagnostic when there is one.
            if (isSupplemental(headerText) && diagnostics.length)
                diagnostics[$ - 1].notes ~= d;
            else
                diagnostics ~= d;
        }
        catch (Exception)
        {
            // Allocation failure while recording: fall back to console output.
            return false;
        }
        return true;
    }
}

private bool isSupplemental(scope const(char)[] header) @safe pure nothrow @nogc
{
    if (!header.length)
        return true;
    foreach (c; header)
        if (c != ' ')
            return false;
    return true;
}

private DiagKind classify(scope const(char)[] header) @safe pure nothrow @nogc
{
    import std.algorithm.searching : canFind;

    if (header.canFind("Error"))
        return DiagKind.error;
    if (header.canFind("Warning"))
        return DiagKind.warning;
    if (header.canFind("Deprecation"))
        return DiagKind.deprecation;
    return DiagKind.message;
}

@("dmd_lsp.diag.classify")
@safe pure nothrow @nogc
unittest
{
    assert(classify("Error: ") == DiagKind.error);
    assert(classify("Warning: ") == DiagKind.warning);
    assert(classify("Deprecation: ") == DiagKind.deprecation);
    assert(classify("") == DiagKind.message);
    assert(isSupplemental("       "));
    assert(!isSupplemental("Error: "));
}
