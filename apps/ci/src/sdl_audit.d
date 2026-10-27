/++
The regression half of lossless editing's SDE9 (`docs/specs/wired/sdl/editing.md`):
no D source reads, edits or detects SDL by matching text.

Every SDL site goes through `sparkles.wired.sdl` (the document API, the
lossless editor, the embedded-recipe locator) or the `dub.sdl` schema
(`sparkles.build_primitives.dub_manifest`). This audit flags a call that
matches SDL by hand: one of $(LREF auditedCalls) whose arguments or UFCS
receiver hold a string literal — or name a string constant declared at any
scope — containing one of
$(LREF sdlMarkers). Test code (`unittest` blocks, `version (unittest)` code)
and the two modules that implement SDL are outside it.

A hit that is not SDL work goes on the allowlist beside the audit
(`apps/ci/sdl-audit-allowlist.txt`) with the reason it was reviewed.
+/
module sdl_audit;

import std.algorithm.searching : canFind, startsWith;
import std.array : appender;
import std.ascii : isAlphaNum, isDigit, isWhite;
import std.string : lineSplitter, strip;

/// Calls that match text; their string arguments are what the audit reads.
immutable string[] auditedCalls = ["canFind", "indexOf", "startsWith", "endsWith",
    "replace", "split", "splitter", "lineSplitter", "matchFirst", "matchAll", "regex",
    "ctRegex", "tryConsume"];

/// Text whose presence in such an argument means SDL is matched by hand.
immutable string[] sdlMarkers = ["dub.sdl:", "+/", "buildType", `configuration "`,
    `dependency "`, "subPackage", "dflags", "lflags", "test-runner"];

/// Sources that implement SDL, and so match its text by design.
immutable string[] sdlImplementations = ["libs/wired/src/sparkles/wired/sdl/",
    "libs/build-primitives/src/sparkles/build_primitives/dub_manifest.d"];

/// One ad-hoc SDL match.
struct AdHocSdlHit
{
    string path; /// repository-relative
    size_t line; /// one-based
    string call; /// the audited call
    string literal; /// the offending text, as written between its delimiters
}

private enum Kind : ubyte { identifier, string_, other }

private struct Token
{
    Kind kind;
    string text; // an identifier, a string's contents, or one punctuation byte
    size_t line;
}

/// Lexes `source` far enough for the audit: identifiers, string literals of
/// every form (their contents), and punctuation; comments are dropped.
private Token[] lexD(string source) @safe pure
{
    auto tokens = appender!(Token[]);
    size_t at, line = 1;

    void advance(size_t n)
    {
        foreach (c; source[at .. at + n < source.length ? at + n : source.length])
            if (c == '\n')
                line++;
        at = at + n < source.length ? at + n : source.length;
    }

    bool lookingAt(string s) => source.length - at >= s.length && source[at .. at + s.length] == s;

    void quoted(char close, bool escapes, size_t startLine)
    {
        const start = at;
        while (at < source.length && source[at] != close)
            advance(escapes && source[at] == '\\' ? 2 : 1);
        tokens ~= Token(Kind.string_, source[start .. at < source.length ? at : source.length], startLine);
        advance(1);
        // A postfix `c`, `w` or `d` belongs to the literal.
        if (at < source.length && (source[at] == 'c' || source[at] == 'w' || source[at] == 'd'))
            advance(1);
    }

    while (at < source.length)
    {
        const c = source[at];
        const startLine = line;
        if (isWhite(c))
            advance(1);
        else if (lookingAt("//"))
        {
            while (at < source.length && source[at] != '\n')
                at++;
        }
        else if (lookingAt("/*"))
        {
            advance(2);
            while (at < source.length && !lookingAt("*/"))
                advance(1);
            advance(2);
        }
        else if (lookingAt("/+"))
        {
            size_t depth;
            do
            {
                if (lookingAt("/+"))
                {
                    depth++;
                    advance(2);
                }
                else if (lookingAt("+/"))
                {
                    depth--;
                    advance(2);
                }
                else
                    advance(1);
            }
            while (depth && at < source.length);
        }
        else if (c == '"')
        {
            advance(1);
            quoted('"', true, startLine);
        }
        else if (c == '`')
        {
            advance(1);
            quoted('`', false, startLine);
        }
        else if ((c == 'r' || c == 'x' || c == 'i') && at + 1 < source.length
            && (source[at + 1] == '"' || source[at + 1] == '`'))
        {
            const close = source[at + 1];
            advance(2);
            quoted(close, c != 'r' && close == '"', startLine);
        }
        else if ((lookingAt("q\"") || lookingAt("iq\"")))
        {
            advance(source[at] == 'i' ? 3 : 2);
            if (at >= source.length)
                break;
            const open = source[at];
            if (open == '(' || open == '[' || open == '{' || open == '<')
            {
                const close = open == '(' ? ')' : open == '[' ? ']' : open == '{' ? '}' : '>';
                advance(1);
                size_t depth = 1;
                const start = at;
                while (at < source.length)
                {
                    if (source[at] == open)
                        depth++;
                    else if (source[at] == close && --depth == 0)
                        break;
                    advance(1);
                }
                tokens ~= Token(Kind.string_, source[start .. at], startLine);
                advance(2); // the delimiter and the closing quote
            }
            else
            {
                // A heredoc: `q"EOS` … a line that is `EOS"`.
                const idStart = at;
                while (at < source.length && source[at] != '\n')
                    at++;
                const id = source[idStart .. at];
                advance(1);
                const start = at;
                while (at < source.length && !(lookingAt(id ~ "\"")
                    && (at == 0 || source[at - 1] == '\n')))
                    advance(1);
                tokens ~= Token(Kind.string_, source[start .. at], startLine);
                advance(id.length + 1);
            }
        }
        else if (lookingAt("q{") || lookingAt("iq{"))
        {
            advance(source[at] == 'i' ? 3 : 2);
            size_t depth = 1;
            const start = at;
            while (at < source.length)
            {
                if (source[at] == '{')
                    depth++;
                else if (source[at] == '}' && --depth == 0)
                    break;
                advance(1);
            }
            tokens ~= Token(Kind.string_, source[start .. at], startLine);
            advance(1);
        }
        else if (c == '\'')
        {
            advance(1);
            while (at < source.length && source[at] != '\'')
                advance(source[at] == '\\' ? 2 : 1);
            advance(1);
            tokens ~= Token(Kind.other, "'", startLine);
        }
        else if (c == '_' || isAlphaNum(c) && !isDigit(c) || c >= 0x80)
        {
            const start = at;
            while (at < source.length && (source[at] == '_' || isAlphaNum(source[at]) || source[at] >= 0x80))
                at++;
            tokens ~= Token(Kind.identifier, source[start .. at], startLine);
        }
        else if (isDigit(c))
        {
            while (at < source.length && (isAlphaNum(source[at]) || source[at] == '_'
                || (source[at] == '.' && at + 1 < source.length && isDigit(source[at + 1]))))
                at++;
            tokens ~= Token(Kind.other, "0", startLine);
        }
        else
        {
            tokens ~= Token(Kind.other, source[at .. at + 1], startLine);
            advance(1);
        }
    }
    return tokens[];
}

private bool hasMarker(scope const(char)[] text) @safe pure nothrow @nogc
{
    foreach (marker; sdlMarkers)
        if (text.canFind(marker))
            return true;
    return false;
}

/// The ad-hoc SDL matches in one D source, `path` repository-relative.
AdHocSdlHit[] auditSource(string path, string source) @safe pure
{
    foreach (prefix; sdlImplementations)
        if (path.startsWith(prefix))
            return null;

    const tokens = lexD(source);

    // Test code: `unittest { … }`, `version (unittest) { … }` or one
    // declaration, and everything after `version (unittest):`.
    auto test = new bool[tokens.length];
    size_t skipBlock(size_t open)
    {
        size_t depth, i = open;
        for (; i < tokens.length; i++)
        {
            if (tokens[i].text == "{" && tokens[i].kind == Kind.other)
                depth++;
            else if (tokens[i].text == "}" && tokens[i].kind == Kind.other && --depth == 0)
                break;
        }
        return i;
    }
    for (size_t i = 0; i < tokens.length; i++)
    {
        size_t from = i, body = size_t.max;
        if (tokens[i].kind == Kind.identifier && tokens[i].text == "unittest")
            body = i + 1;
        else if (tokens[i].kind == Kind.identifier && tokens[i].text == "version"
            && i + 3 < tokens.length && tokens[i + 1].text == "("
            && tokens[i + 2].text == "unittest" && tokens[i + 3].text == ")")
        {
            body = i + 4;
            if (body < tokens.length && tokens[body].text == ":")
            {
                test[from .. $] = true;
                break;
            }
        }
        if (body == size_t.max || body >= tokens.length)
            continue;
        size_t end;
        if (tokens[body].text == "{")
            end = skipBlock(body);
        else
        {
            // One declaration: through its `;`, or its braced body.
            end = body;
            while (end < tokens.length && tokens[end].text != ";" && tokens[end].text != "{")
                end++;
            if (end < tokens.length && tokens[end].text == "{")
                end = skipBlock(end);
        }
        test[from .. (end < tokens.length ? end + 1 : tokens.length)] = true;
        i = end;
    }

    // String constants at any scope: a declaration whose storage class is
    // `enum`, `immutable`, `const` or `static`, `name = "…"`, the
    // initializer's literals concatenated with `~`. A `==` comparison lexes as
    // two `=` tokens, so it is not an initializer.
    bool isConstantDeclaration(size_t name)
    {
        foreach_reverse (j; 0 .. name)
        {
            const t = tokens[j];
            if (t.kind == Kind.other && (t.text == ";" || t.text == "{" || t.text == "}"
                || t.text == "(" || t.text == ","))
                return false;
            if (t.kind == Kind.identifier && (t.text == "enum" || t.text == "immutable"
                || t.text == "const" || t.text == "static"))
                return true;
        }
        return false;
    }
    bool[string] markedConstants;
    {
        foreach (i, ref t; tokens)
        {
            if (t.kind == Kind.identifier && i + 2 < tokens.length
                && tokens[i + 1].text == "=" && tokens[i + 1].kind == Kind.other
                && tokens[i + 2].text != "=" && !test[i] && isConstantDeclaration(i))
            {
                // The initializer: string literals concatenated with `~`.
                for (size_t j = i + 2; j < tokens.length && tokens[j].text != ";"; j++)
                    if (tokens[j].kind == Kind.string_ && hasMarker(tokens[j].text))
                        markedConstants[t.text] = true;
            }
        }
    }

    AdHocSdlHit[] hits;
    foreach (i, ref t; tokens)
    {
        if (test[i] || t.kind != Kind.identifier || !auditedCalls.canFind(t.text))
            continue;
        // Its argument lists: a template argument after `!` (parenthesized or
        // one token) and the call's own parentheses.
        size_t j = i + 1;
        size_t[2][2] lists;
        size_t listCount;
        if (j < tokens.length && tokens[j].text == "!")
        {
            j++;
            if (j < tokens.length && tokens[j].text == "(")
            {
                const close = matching(tokens, j);
                lists[listCount++] = [j + 1, close];
                j = close + 1;
            }
            else if (j < tokens.length)
                lists[listCount++] = [j, ++j];
        }
        if (j < tokens.length && tokens[j].text == "(")
            lists[listCount++] = [j + 1, matching(tokens, j)];
        // A UFCS receiver: `"…".canFind(x)` or `constant.canFind(x)`.
        if (i >= 2 && tokens[i - 1].text == "." && tokens[i - 1].kind == Kind.other)
        {
            const receiver = tokens[i - 2];
            if (receiver.kind == Kind.string_ ? hasMarker(receiver.text)
                : receiver.kind == Kind.identifier && (receiver.text in markedConstants) !is null)
                hits ~= AdHocSdlHit(path, receiver.line, t.text, receiver.text);
        }
        foreach (list; lists[0 .. listCount])
            foreach (ref argument; tokens[list[0] .. list[1]])
            {
                const offending = argument.kind == Kind.string_ ? hasMarker(argument.text)
                    : argument.kind == Kind.identifier && (argument.text in markedConstants) !is null;
                if (offending)
                    hits ~= AdHocSdlHit(path, argument.line, t.text, argument.text);
            }
    }
    return hits;
}

/// The index of the `)` matching the `(` at `open`, or the token count.
private size_t matching(scope const Token[] tokens, size_t open) @safe pure nothrow @nogc
{
    size_t depth;
    foreach (i; open .. tokens.length)
    {
        if (tokens[i].kind != Kind.other)
            continue;
        if (tokens[i].text == "(")
            depth++;
        else if (tokens[i].text == ")" && --depth == 0)
            return i;
    }
    return tokens.length;
}

/// One allowlist entry: a path and an offending literal, with its reason.
struct AllowedHit
{
    string path;
    string literal;
    string reason;
}

/++
Parses the allowlist: one entry per line, `path | literal | reason`, the
literal written as the audit reports it; `#` starts a comment line. A
malformed line is reported by its number.
+/
AllowedHit[] parseAllowlist(string text, out size_t badLine) @safe pure
{
    import std.algorithm.iteration : splitter;
    import std.array : array;

    AllowedHit[] entries;
    size_t number;
    foreach (raw; text.lineSplitter)
    {
        number++;
        const line = raw.strip;
        if (line.length == 0 || line[0] == '#')
            continue;
        const parts = line.splitter(" | ").array;
        if (parts.length != 3 || parts[2].strip.length == 0)
        {
            badLine = number;
            return null;
        }
        entries ~= AllowedHit(parts[0].strip, parts[1].strip, parts[2].strip);
    }
    return entries;
}

@("sdlAudit.auditSource.flagsHandMatching")
@safe pure unittest
{
    enum source = `module m;
enum header = "/+ dub.sdl:";
bool single(string text) => text.canFind(header);
bool checked(string s) => s.canFind("buildType \"checked\"");
auto pattern = regex(` ~ "`(?ms)^dflags.*`" ~ `);
bool runner(string s) => s.canFind("test-runner"); // a comment: dub.sdl:
bool fine(string s) => s.canFind("module ");
bool receiver(string s) => "dflags lflags".canFind(s);
void local(string s) { enum marker = "subPackage"; s.tryConsume(marker); }
`;
    const hits = auditSource("apps/x.d", source);
    assert(hits.length == 6);
    assert(hits[4] == AdHocSdlHit("apps/x.d", 8, "canFind", "dflags lflags"));
    assert(hits[5].call == "tryConsume" && hits[5].literal == "marker");
    assert(hits[0] == AdHocSdlHit("apps/x.d", 3, "canFind", "header"));
    assert(hits[1].line == 4 && hits[1].literal == `buildType \"checked\"`);
    assert(hits[2].call == "regex" && hits[3].literal == "test-runner");
}

@("sdlAudit.auditSource.skipsTestsAndImplementations")
@safe pure unittest
{
    enum source = `module m;
unittest { assert("x".canFind("dflags")); }
version (unittest) bool helper(string s) => s.canFind("dflags");
version (unittest) { auto x = "a".indexOf("+/"); }
string s = q"EOS
buildType
EOS";
bool live(string t) => t.startsWith(q{subPackage});
`;
    const hits = auditSource("libs/y.d", source);
    assert(hits.length == 1 && hits[0].call == "startsWith" && hits[0].line == 8);
    assert(auditSource("libs/wired/src/sparkles/wired/sdl/lexer.d", source).length == 0);
    assert(auditSource("z.d", "version (unittest):\nauto a = s.canFind(\"dflags\");\n").length == 0);
}

@("sdlAudit.parseAllowlist")
@safe pure unittest
{
    size_t bad;
    const entries = parseAllowlist("# comment\n\na.d | dflags- | the dub.json reader's keys\n", bad);
    assert(bad == 0 && entries == [AllowedHit("a.d", "dflags-", "the dub.json reader's keys")]);
    assert(parseAllowlist("a.d | dflags\n", bad) is null && bad == 1);
}
