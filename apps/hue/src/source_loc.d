/**
Source location and traceback target parser for `sparkles:hue`.

Parses CLI target strings into a resolved file path / URL and optional
line / column spans:
$(LIST
    * Python traceback lines (GH #398): `File "/path/to/file.py", line 7, in func`
    * Forge and Web URIs (GitLab, GitHub, Bitbucket, `file://`):
        `https://gitlab.com/.../file.yml#L6-9`, `https://github.com/.../app.d#L42-L55`
    * Compiler diagnostics: `app.d(42)`, `app.d(42,15)`, `app.d(42,15-55,20)`
    * Colon-separated locations: `app.d:42`, `app.d:42:15`, `app.d:42-55`
    * Plain local paths, directories, and URLs
)
*/
module source_loc;

import std.ascii : isDigit, isWhite;
import std.string : startsWith, endsWith, strip;

/// A resolved target location.
struct SourceLoc
{
    string path;      /// Local path or remote URL
    size_t line;      /// 1-based start line (0 = unspecified)
    size_t col;       /// 1-based start col (0 = unspecified)
    size_t endLine;   /// 1-based end line (0 = unspecified / single line)
    size_t endCol;    /// 1-based end col (0 = unspecified)

    bool isRange() const @safe pure nothrow @nogc
    {
        return endLine > 0 && (endLine != line || endCol > 0);
    }

    bool isUrl() const @safe pure nothrow @nogc
    {
        return path.startsWith("http://") || path.startsWith("https://");
    }

    bool opCast(T : bool)() const @safe pure nothrow @nogc
    {
        return path.length != 0;
    }

    /**
    Computes the [outStartByte, outEndByte) source byte range corresponding to
    this location. Returns true if a valid non-empty byte range was computed.
    */
    bool byteRange(scope const(char)[] source, scope const(size_t)[] lineStarts,
        out size_t outStartByte, out size_t outEndByte) const @safe pure nothrow @nogc
    {
        if (line == 0 || lineStarts.length == 0)
        {
            outStartByte = 0;
            outEndByte = 0;
            return false;
        }

        const sLineIdx = line - 1;
        if (sLineIdx >= lineStarts.length)
        {
            outStartByte = source.length;
            outEndByte = source.length;
            return false;
        }

        const size_t sLineStart = lineStarts[sLineIdx];
        const size_t sLineEnd = sLineIdx + 1 < lineStarts.length ? lineStarts[sLineIdx + 1] : source.length;

        size_t sByte = sLineStart;
        if (col > 1)
        {
            size_t colCount = 1;
            size_t cur = sLineStart;
            while (cur < sLineEnd && cur < source.length && colCount < col && source[cur] != '\n' && source[cur] != '\r')
            {
                cur++;
                colCount++;
            }
            sByte = cur;
        }

        const size_t eLine = endLine > 0 ? endLine : line;
        size_t eLineIdx = eLine - 1;
        if (eLineIdx >= lineStarts.length)
            eLineIdx = lineStarts.length - 1;

        const size_t eLineStart = lineStarts[eLineIdx];
        const size_t eLineEnd = eLineIdx + 1 < lineStarts.length ? lineStarts[eLineIdx + 1] : source.length;

        size_t eByte = eLineEnd;
        if (endCol > 1)
        {
            size_t colCount = 1;
            size_t cur = eLineStart;
            while (cur < eLineEnd && cur < source.length && colCount < endCol && source[cur] != '\n' && source[cur] != '\r')
            {
                cur++;
                colCount++;
            }
            eByte = cur;
        }
        else if (endLine == 0 && col > 0 && endCol == 0)
        {
            size_t cur = sByte;
            static bool isIdent(char c) @safe pure nothrow @nogc
            {
                return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
                    || (c >= '0' && c <= '9') || c == '_';
            }
            if (cur < sLineEnd && isIdent(source[cur]))
            {
                while (cur < sLineEnd && isIdent(source[cur]))
                    cur++;
                eByte = cur;
            }
            else
            {
                eByte = cur < sLineEnd ? cur + 1 : sLineEnd;
            }
        }

        if (eByte < sByte)
            eByte = sByte;

        outStartByte = sByte;
        outEndByte = eByte;
        return outEndByte > outStartByte;
    }
}

/// Parses a CLI target string into a `SourceLoc`.
SourceLoc parseSourceLoc(string input) @safe pure nothrow
{
    const raw = input.strip();
    if (raw.length == 0)
        return SourceLoc.init;

    // 1. Python traceback line format (GH #398):
    //    e.g. `File "/home/some/path/file.py", line 7, in do_stuff`
    //    or `  File "foo.py", line 42`
    //    or `"foo.py", line 42`
    const pyLoc = tryParsePythonTraceback(raw);
    if (pyLoc.path.length != 0)
        return pyLoc;

    // 2. `file://` URI:
    if (raw.startsWith("file://"))
    {
        string filePath = raw["file://".length .. $];
        return parseUrlWithFragment(filePath);
    }

    // 3. Web / Forge URL:
    if (raw.startsWith("http://") || raw.startsWith("https://"))
    {
        return parseUrlWithFragment(raw);
    }

    // 4. Compiler diagnostic format: `path(line[,col[-endLine[,endCol]]])`
    const diagLoc = tryParseCompilerDiag(raw);
    if (diagLoc.path.length != 0)
        return diagLoc;

    // 5. Colon-separated format: `path:line[:col][-endLine[:endCol]]`
    const colonLoc = tryParseColonLocation(raw);
    if (colonLoc.path.length != 0)
        return colonLoc;

    // 6. Plain path / stripped quotes
    string plain = raw;
    if (plain.length >= 2)
    {
        if ((plain[0] == '"' && plain[$ - 1] == '"') ||
            (plain[0] == '\'' && plain[$ - 1] == '\''))
            plain = plain[1 .. $ - 1].strip();
    }
    return SourceLoc(plain, 0, 0, 0, 0);
}

// ── Helpers ─────────────────────────────────────────────────────────────────

private ptrdiff_t findFirstChar(string s, char c) @safe pure nothrow @nogc
{
    foreach (i, ch; s)
    {
        if (ch == c)
            return cast(ptrdiff_t) i;
    }
    return -1;
}

private ptrdiff_t findLastChar(string s, char c) @safe pure nothrow @nogc
{
    for (ptrdiff_t i = cast(ptrdiff_t) s.length - 1; i >= 0; i--)
    {
        if (s[i] == c)
            return i;
    }
    return -1;
}

private ptrdiff_t findSubstring(string s, string sub) @safe pure nothrow @nogc
{
    if (sub.length == 0)
        return 0;
    if (s.length < sub.length)
        return -1;
    for (size_t i = 0; i + sub.length <= s.length; i++)
    {
        if (s[i .. i + sub.length] == sub)
            return cast(ptrdiff_t) i;
    }
    return -1;
}

private SourceLoc tryParsePythonTraceback(string s) @safe pure nothrow
{
    string work = s;
    if (work.startsWith("File ") || work.startsWith("file "))
        work = work["File ".length .. $].strip();

    const lineIdx = findSubstring(work, ", line ");
    if (lineIdx < 0)
        return SourceLoc.init;

    string pathPart = work[0 .. lineIdx].strip();
    if (pathPart.length >= 2)
    {
        if ((pathPart[0] == '"' && pathPart[$ - 1] == '"') ||
            (pathPart[0] == '\'' && pathPart[$ - 1] == '\''))
            pathPart = pathPart[1 .. $ - 1];
    }
    if (pathPart.length == 0)
        return SourceLoc.init;

    string rest = work[lineIdx + ", line ".length .. $].strip();
    size_t lineNum = 0;
    size_t pos = 0;
    while (pos < rest.length && rest[pos].isDigit)
    {
        lineNum = lineNum * 10 + (rest[pos] - '0');
        pos++;
    }

    if (lineNum == 0)
        return SourceLoc.init;

    return SourceLoc(pathPart, lineNum, 0, 0, 0);
}

private SourceLoc parseUrlWithFragment(string url) @safe pure nothrow
{
    const hashIdx = findFirstChar(url, '#');
    if (hashIdx < 0)
        return SourceLoc(url, 0, 0, 0, 0);

    const cleanUrl = url[0 .. hashIdx];
    const frag = url[hashIdx + 1 .. $];

    size_t startLine, startCol, endLine, endCol;
    parseFragment(frag, startLine, startCol, endLine, endCol);

    return SourceLoc(cleanUrl, startLine, startCol, endLine, endCol);
}

/// Parses fragment shapes like `L6-9`, `L6-L9`, `L42`, `L42C5-L55C20`, `lines-6:9`
private void parseFragment(string frag, out size_t startLine, out size_t startCol,
    out size_t endLine, out size_t endCol) @safe pure nothrow
{
    string s = frag.strip();
    if (s.startsWith("lines-"))
        s = s["lines-".length .. $];
    else if (s.startsWith("L") || s.startsWith("l"))
        s = s[1 .. $];

    if (s.length == 0)
        return;

    // Parse startLine
    size_t pos = 0;
    while (pos < s.length && s[pos].isDigit)
    {
        startLine = startLine * 10 + (s[pos] - '0');
        pos++;
    }

    if (pos < s.length && (s[pos] == 'C' || s[pos] == 'c' || s[pos] == ':'))
    {
        pos++; // skip C or :
        while (pos < s.length && s[pos].isDigit)
        {
            startCol = startCol * 10 + (s[pos] - '0');
            pos++;
        }
    }

    if (pos < s.length && (s[pos] == '-' || s[pos] == ':'))
    {
        pos++; // skip delimiter
        if (pos < s.length && (s[pos] == 'L' || s[pos] == 'l'))
            pos++;

        while (pos < s.length && s[pos].isDigit)
        {
            endLine = endLine * 10 + (s[pos] - '0');
            pos++;
        }

        if (pos < s.length && (s[pos] == 'C' || s[pos] == 'c' || s[pos] == ':'))
        {
            pos++;
            while (pos < s.length && s[pos].isDigit)
            {
                endCol = endCol * 10 + (s[pos] - '0');
                pos++;
            }
        }
    }
}

private SourceLoc tryParseCompilerDiag(string s) @safe pure nothrow
{
    // Look for `...(`
    const openParen = findLastChar(s, '(');
    const closeParen = findLastChar(s, ')');
    if (openParen <= 0 || closeParen <= openParen)
        return SourceLoc.init;

    const path = s[0 .. openParen].strip();
    if (path.length == 0)
        return SourceLoc.init;

    const inside = s[openParen + 1 .. closeParen].strip();
    if (inside.length == 0 || !inside[0].isDigit)
        return SourceLoc.init;

    size_t startLine = 0, startCol = 0, endLine = 0, endCol = 0;
    size_t pos = 0;
    while (pos < inside.length && inside[pos].isDigit)
    {
        startLine = startLine * 10 + (inside[pos] - '0');
        pos++;
    }
    if (startLine == 0)
        return SourceLoc.init;

    if (pos < inside.length && inside[pos] == ',')
    {
        pos++;
        while (pos < inside.length && inside[pos].isDigit)
        {
            startCol = startCol * 10 + (inside[pos] - '0');
            pos++;
        }
    }

    if (pos < inside.length && inside[pos] == '-')
    {
        pos++;
        while (pos < inside.length && inside[pos].isDigit)
        {
            endLine = endLine * 10 + (inside[pos] - '0');
            pos++;
        }
        if (pos < inside.length && inside[pos] == ',')
        {
            pos++;
            while (pos < inside.length && inside[pos].isDigit)
            {
                endCol = endCol * 10 + (inside[pos] - '0');
                pos++;
            }
        }
    }

    return SourceLoc(path, startLine, startCol, endLine, endCol);
}

private SourceLoc tryParseColonLocation(string s) @safe pure nothrow
{
    // Skip Windows drive letter at start (e.g. "C:\" or "C:/")
    size_t startIdx = 0;
    if (s.length >= 3 && s[1] == ':' && (s[2] == '/' || s[2] == '\\'))
        startIdx = 2;

    // Search for a colon that begins the location specifier:
    for (size_t i = startIdx; i < s.length; i++)
    {
        if (s[i] == ':')
        {
            const afterColon = s[i + 1 .. $].strip();
            if (afterColon.length > 0 && afterColon[0].isDigit)
            {
                size_t startLine = 0, startCol = 0, endLine = 0, endCol = 0;
                size_t pos = 0;

                while (pos < afterColon.length && afterColon[pos].isDigit)
                {
                    startLine = startLine * 10 + (afterColon[pos] - '0');
                    pos++;
                }
                if (startLine == 0)
                    continue;

                if (pos < afterColon.length && afterColon[pos] == ':')
                {
                    pos++;
                    while (pos < afterColon.length && afterColon[pos].isDigit)
                    {
                        startCol = startCol * 10 + (afterColon[pos] - '0');
                        pos++;
                    }
                }

                if (pos < afterColon.length && afterColon[pos] == '-')
                {
                    pos++;
                    while (pos < afterColon.length && afterColon[pos].isDigit)
                    {
                        endLine = endLine * 10 + (afterColon[pos] - '0');
                        pos++;
                    }
                    if (pos < afterColon.length && afterColon[pos] == ':')
                    {
                        pos++;
                        while (pos < afterColon.length && afterColon[pos].isDigit)
                        {
                            endCol = endCol * 10 + (afterColon[pos] - '0');
                            pos++;
                        }
                    }
                }

                if (pos == afterColon.length)
                {
                    const path = s[0 .. i].strip();
                    if (path.length > 0)
                        return SourceLoc(path, startLine, startCol, endLine, endCol);
                }
            }
        }
    }

    return SourceLoc.init;
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

@("source_loc.pythonTraceback")
@safe pure unittest
{
    // Standard Python traceback line (GH #398)
    const loc1 = parseSourceLoc(`File "/home/some/path/exception_hooks.py", line 7, in do_stuff`);
    assert(loc1.path == "/home/some/path/exception_hooks.py");
    assert(loc1.line == 7);
    assert(loc1.col == 0);
    assert(!loc1.isRange);

    // Indented traceback line
    const loc2 = parseSourceLoc(`  File "foo.py", line 42`);
    assert(loc2.path == "foo.py");
    assert(loc2.line == 42);

    // Single quotes
    const loc3 = parseSourceLoc(`File 'bar/baz.py', line 100, in run`);
    assert(loc3.path == "bar/baz.py");
    assert(loc3.line == 100);

    // No File prefix
    const loc4 = parseSourceLoc(`"module.py", line 12`);
    assert(loc4.path == "module.py");
    assert(loc4.line == 12);
}

@("source_loc.forgeAndWebUris")
@safe pure unittest
{
    // GitLab line range
    const gl = parseSourceLoc("https://gitlab.com/gitlab-org/gitlab/-/blob/4376c202d7af89fb9718050fab628a4cbb55c1b1/.gitlab-ci.yml#L6-9");
    assert(gl.path == "https://gitlab.com/gitlab-org/gitlab/-/blob/4376c202d7af89fb9718050fab628a4cbb55c1b1/.gitlab-ci.yml");
    assert(gl.line == 6);
    assert(gl.endLine == 9);
    assert(gl.isRange);
    assert(gl.isUrl);

    // GitHub range
    const ghRange = parseSourceLoc("https://github.com/owner/repo/blob/0123456789abcdef0123456789abcdef01234567/src/app.d#L42-L55");
    assert(ghRange.path == "https://github.com/owner/repo/blob/0123456789abcdef0123456789abcdef01234567/src/app.d");
    assert(ghRange.line == 42);
    assert(ghRange.endLine == 55);
    assert(ghRange.isRange);

    // GitHub single line
    const ghSingle = parseSourceLoc("https://github.com/owner/repo/blob/0123456789abcdef0123456789abcdef01234567/src/app.d#L42");
    assert(ghSingle.path == "https://github.com/owner/repo/blob/0123456789abcdef0123456789abcdef01234567/src/app.d");
    assert(ghSingle.line == 42);
    assert(ghSingle.endLine == 0);
    assert(!ghSingle.isRange);

    // GitHub line and column range
    const ghCols = parseSourceLoc("https://github.com/owner/repo/blob/0123456789abcdef0123456789abcdef01234567/src/app.d#L42C5-L55C20");
    assert(ghCols.line == 42);
    assert(ghCols.col == 5);
    assert(ghCols.endLine == 55);
    assert(ghCols.endCol == 20);

    // file:// URI
    const fileUri = parseSourceLoc("file:///home/user/code/app.d#L10-25");
    assert(fileUri.path == "/home/user/code/app.d");
    assert(fileUri.line == 10);
    assert(fileUri.endLine == 25);
}

@("source_loc.compilerDiagnostics")
@safe pure unittest
{
    const d1 = parseSourceLoc("src/app.d(42)");
    assert(d1.path == "src/app.d");
    assert(d1.line == 42);
    assert(d1.col == 0);

    const d2 = parseSourceLoc("src/app.d(42,15)");
    assert(d2.path == "src/app.d");
    assert(d2.line == 42);
    assert(d2.col == 15);

    const d3 = parseSourceLoc("src/app.d(42,15-55,20)");
    assert(d3.path == "src/app.d");
    assert(d3.line == 42);
    assert(d3.col == 15);
    assert(d3.endLine == 55);
    assert(d3.endCol == 20);
}

@("source_loc.colonLocations")
@safe pure unittest
{
    const c1 = parseSourceLoc("app.d:42");
    assert(c1.path == "app.d");
    assert(c1.line == 42);
    assert(c1.col == 0);

    const c2 = parseSourceLoc("app.d:42:15");
    assert(c2.path == "app.d");
    assert(c2.line == 42);
    assert(c2.col == 15);

    const c3 = parseSourceLoc("app.d:42-55");
    assert(c3.path == "app.d");
    assert(c3.line == 42);
    assert(c3.endLine == 55);

    const c4 = parseSourceLoc("app.d:42:5-55:20");
    assert(c4.path == "app.d");
    assert(c4.line == 42);
    assert(c4.col == 5);
    assert(c4.endLine == 55);
    assert(c4.endCol == 20);

    // Windows path with drive letter
    const win = parseSourceLoc(`C:\projects\sparkles\app.d:100:4`);
    assert(win.path == `C:\projects\sparkles\app.d`);
    assert(win.line == 100);
    assert(win.col == 4);
}

@("source_loc.plainPaths")
@safe pure unittest
{
    const p1 = parseSourceLoc("app.d");
    assert(p1.path == "app.d");
    assert(p1.line == 0);

    const p2 = parseSourceLoc(".");
    assert(p2.path == ".");
    assert(p2.line == 0);

    const p3 = parseSourceLoc(`"quoted/path/file.d"`);
    assert(p3.path == "quoted/path/file.d");
    assert(p3.line == 0);

    const empty = parseSourceLoc("");
    assert(empty.path == "");
    assert(empty.line == 0);
}

@("source_loc.byteRange")
@safe pure unittest
{
    // 3-line sample:
    // line 1: "import std;\n" (length 12, start 0)
    // line 2: "void main() {\n" (length 14, start 12)
    // line 3: "    writeln();\n" (length 15, start 26)
    const source = "import std;\nvoid main() {\n    writeln();\n";
    const lineStarts = [0UL, 12, 26];

    size_t s, e;

    // 1. Single line: line 1
    const loc1 = SourceLoc("app.d", 1, 0, 0, 0);
    assert(loc1.byteRange(source, lineStarts, s, e));
    assert(s == 0);
    assert(e == 12);
    assert(source[s .. e] == "import std;\n");

    // 2. Line range: lines 1 to 2
    const loc2 = SourceLoc("app.d", 1, 0, 2, 0);
    assert(loc2.byteRange(source, lineStarts, s, e));
    assert(s == 0);
    assert(e == 26);
    assert(source[s .. e] == "import std;\nvoid main() {\n");

    // 3. Line with column: line 2 col 6 ("main")
    const loc3 = SourceLoc("app.d", 2, 6, 0, 0);
    assert(loc3.byteRange(source, lineStarts, s, e));
    assert(s == 12 + 5); // 17
    assert(e == 17 + 4); // 21
    assert(source[s .. e] == "main");

    // 4. Exact range: line 2 col 1 to line 2 col 10
    const loc4 = SourceLoc("app.d", 2, 1, 2, 10);
    assert(loc4.byteRange(source, lineStarts, s, e));
    assert(s == 12);
    assert(e == 12 + 9);
    assert(source[s .. e] == "void main");
}
