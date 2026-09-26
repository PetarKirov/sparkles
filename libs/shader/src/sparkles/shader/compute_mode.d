/**
Where a D module's code runs, read from the `@compute` attribute on its
module declaration — without a compiler.

LDC compiles a module marked `@compute` for the GPU: `deviceOnly` there alone,
`hostAndDevice` for both. Tools that must know which modules those are before
any compile happens need the answer from the text: `shader-compile` picks the
device unit out of a package's source files with it, and `sparkles:dmd-lsp`
decides which side (or sides) to analyze a file on (`TGT5`).

Host-only, like $(MREF sparkles,shader,testing): it is not `@compute` itself,
so a device build never compiles it.
*/
module sparkles.shader.compute_mode;

/// Where a module's code runs, from its `@compute` attribute (`TGT5`).
enum ComputeMode
{
    /// Not a `@compute` module: ordinary host code.
    none,
    /// `@compute` / `@compute(CompileFor.deviceOnly)`: compiled for the device only.
    deviceOnly,
    /// `@compute(CompileFor.hostAndDevice)`: compiled for both.
    hostAndDevice,
}

/**
The `ComputeMode` a module's declaration states.

A token-level read of the attributes before `module` — the only place D
allows them to appear there are `deprecated` and user-defined attributes — so
it needs no frontend, no globals and no lock, and costs a scan of the file's
head. A file without a module declaration is host code: `@compute` cannot
apply to it.
*/
ComputeMode computeModeOf(const(char)[] source) @safe pure nothrow @nogc
{
    auto lex = HeadLexer(source);
    auto mode = ComputeMode.none;

    for (;;)
    {
        const tok = lex.next();
        if (tok == "@")
        {
            // The attribute's name: a dotted chain whose last link names it
            // (`@compute`, `@ldc.dcompute.compute`).
            const(char)[] name;
            while (isIdentifier(lex.peek()))
            {
                name = lex.next();
                if (lex.peek() != ".")
                    break;
                lex.next();
            }
            const isCompute = name == "compute";
            if (isCompute)
                mode = ComputeMode.deviceOnly;
            if (lex.peek() == "(" && lex.skipParenthesized("hostAndDevice") && isCompute)
                mode = ComputeMode.hostAndDevice;
        }
        else if (tok == "deprecated")
        {
            if (lex.peek() == "(")
                lex.skipParenthesized(null);
        }
        else if (tok == "module")
            return mode;
        else
            return ComputeMode.none; // a declaration, or the end: no module statement
    }
}

@("shader.compute_mode.computeModeOf")
@safe pure nothrow @nogc unittest
{
    assert(computeModeOf("module a;") == ComputeMode.none);
    assert(computeModeOf("import std.stdio; void main() {}") == ComputeMode.none);
    assert(computeModeOf("") == ComputeMode.none);

    assert(computeModeOf("@compute module a;") == ComputeMode.deviceOnly);
    assert(computeModeOf("@compute(CompileFor.deviceOnly)\nmodule effects;")
        == ComputeMode.deviceOnly);
    assert(computeModeOf("@compute(CompileFor.hostAndDevice) module a.b;")
        == ComputeMode.hostAndDevice);
    assert(computeModeOf("@ldc.dcompute.compute(ldc.dcompute.CompileFor.hostAndDevice) module a;")
        == ComputeMode.hostAndDevice);

    // Doc comments, other attributes and a shebang before the declaration.
    assert(computeModeOf(q{#!/usr/bin/env dub
        /++ The shaders. (with a /+ nested +/ comment) +/
        // @compute(CompileFor.hostAndDevice) — commented out
        deprecated("old") @("tag") @compute(CompileFor.deviceOnly) module a;
    }) == ComputeMode.deviceOnly);

    // `hostAndDevice` counts only inside `@compute`'s own arguments.
    assert(computeModeOf("@compute @Tag(hostAndDevice) module a;") == ComputeMode.deviceOnly);
    // A string argument cannot fake it either.
    assert(computeModeOf(`@("hostAndDevice") module a;`) == ComputeMode.none);
    // `@compute` on a declaration below the module is not the module's.
    assert(computeModeOf("module a; @compute void f();") == ComputeMode.none);
}

// A lexer over just enough of D to read the attributes before `module`:
// identifiers, punctuation, and string/character literals and comments to
// skip. Anything it does not understand ends the head.
private struct HeadLexer
{
    const(char)[] src;
    size_t pos;

    this(const(char)[] source) @safe pure nothrow @nogc
    {
        src = source;
        if (src.length >= 2 && src[0 .. 2] == "#!")
            while (pos < src.length && src[pos] != '\n')
                pos++;
    }

    const(char)[] peek() @safe pure nothrow @nogc
    {
        const saved = pos;
        const tok = next();
        pos = saved;
        return tok;
    }

    /// Skips a `(` (the next token) through its matching `)`; returns
    /// whether the identifier `needle` occurred in between.
    bool skipParenthesized(scope const(char)[] needle) @safe pure nothrow @nogc
    {
        next(); // the "("
        bool found;
        for (int depth = 1; depth > 0;)
        {
            const tok = next();
            if (!tok.length)
                break;
            if (tok == "(")
                depth++;
            else if (tok == ")")
                depth--;
            else if (needle.length && tok == needle)
                found = true;
        }
        return found;
    }

    const(char)[] next() @safe pure nothrow @nogc
    {
        skipTrivia();
        if (pos >= src.length)
            return null;

        const start = pos;
        const c = src[pos];
        if (isIdentStart(c))
        {
            // `r"…"`, `q"…"` and `x"…"` are strings, not identifiers.
            if ((c == 'r' || c == 'q' || c == 'x') && pos + 1 < src.length && src[pos + 1] == '"')
            {
                pos++;
                skipQuoted('"', c != 'r');
                return src[start .. pos];
            }
            while (pos < src.length && isIdentPart(src[pos]))
                pos++;
            return src[start .. pos];
        }
        if (c == '"' || c == '\'' || c == '`')
        {
            skipQuoted(c, c != '`');
            return src[start .. pos];
        }
        pos++;
        return src[start .. pos];
    }

    private void skipQuoted(char quote, bool escapes) @safe pure nothrow @nogc
    {
        pos++; // the opening quote
        while (pos < src.length && src[pos] != quote)
            pos += escapes && src[pos] == '\\' ? 2 : 1;
        pos++; // the closing quote
        if (pos > src.length)
            pos = src.length;
    }

    private void skipTrivia() @safe pure nothrow @nogc
    {
        while (pos < src.length)
        {
            const c = src[pos];
            if (c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v')
                pos++;
            else if (startsAt("//"))
                while (pos < src.length && src[pos] != '\n')
                    pos++;
            else if (startsAt("/*"))
            {
                pos += 2;
                while (pos < src.length && !startsAt("*/"))
                    pos++;
                pos = pos + 2 > src.length ? src.length : pos + 2;
            }
            else if (startsAt("/+"))
            {
                pos += 2;
                for (int depth = 1; depth > 0 && pos < src.length;)
                {
                    if (startsAt("/+"))
                    {
                        depth++;
                        pos += 2;
                    }
                    else if (startsAt("+/"))
                    {
                        depth--;
                        pos += 2;
                    }
                    else
                        pos++;
                }
            }
            else
                return;
        }
    }

    private bool startsAt(string s) const @safe pure nothrow @nogc
        => pos + s.length <= src.length && src[pos .. pos + s.length] == s;
}

private bool isIdentStart(char c) @safe pure nothrow @nogc
    => c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c >= 0x80;

private bool isIdentPart(char c) @safe pure nothrow @nogc
    => isIdentStart(c) || (c >= '0' && c <= '9');

private bool isIdentifier(scope const(char)[] tok) @safe pure nothrow @nogc
    => tok.length && isIdentStart(tok[0]);
