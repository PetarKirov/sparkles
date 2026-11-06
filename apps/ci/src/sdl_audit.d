/++
The regression half of lossless editing's SDE9 (`docs/specs/wired/sdl/editing.md`):
no D source reads, edits, detects or writes SDL by matching or building text.

Every SDL site goes through `sparkles.wired.sdl` (the document API, the
lossless editor, the embedded-recipe locator) or the `dub.sdl` schema
(`sparkles.build_primitives.dub_manifest`). This audit flags, wherever a
string literal — or a string constant declared at any scope — contains one
of $(LREF sdlMarkers):

$(LIST
    * a call of one of $(LREF auditedCalls) holding it in its arguments or UFCS receiver;
    * a comparison (`==`, `!=`, or a `case` label of a `switch`) with it as an operand;
    * a concatenation (`~`, `~=`) with it as an operand, which builds SDL text;
    * a call of one of $(LREF formattingCalls) holding it in its arguments or UFCS receiver, which builds SDL text;
    * an interpolated expression sequence (`i"…"`, ``i`…` ``, `iq{…}`), which builds SDL text from its literal parts — each interpolation `$(…)` stands between them, so no marker spans one.
)

A concatenation, formatting call or interpolated sequence counts only when the
literal holds recipe syntax, not a marker in prose.

A match or comparison whose subject — another argument or the receiver, the
other operand, the `switch` expression — is a decoded value is typed work
and is not flagged: the subject reads a member named in $(LREF decodedAccessors),
or its root is a `foreach` variable, lambda parameter or initialized local
bound, in an enclosing block, from such a read. Test code (`unittest`
blocks, `version (unittest)` code) and the two modules that implement SDL are
outside the audit.

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

/// Calls that format text; an operand holding recipe syntax builds SDL.
immutable string[] formattingCalls = ["format", "sformat", "formattedWrite", "text", "wtext",
    "dtext", "writeText", "writeStyled", "write", "writeln", "writef", "writefln", "put"];

/++
Text whose presence in such an operand means SDL is matched or built by
hand: the embedded-recipe delimiters, statement syntax, the keys tools look
for, and the two recipe spellings of the test runner — its dependency name and
its source-include path. The bare package name `test-runner` is not one: it is
also a commit scope, an executable and a stack frame, none of them recipe text.
+/
immutable string[] sdlMarkers = ["dub.sdl:", "+/", "buildType", `configuration "`,
    `dependency "`, "subPackage", "dflags", "lflags", "sparkles:test-runner", "test-runner/src"];

/// Members of the typed models — the SDL document views, the `dub.sdl`
/// schema, `std.json` — whose read makes a value decoded rather than text.
immutable string[] decodedAccessors = ["name", "localName", "qualifiedName", "namespace_",
    "stringValue", "byValue", "byChild", "byAttribute", "valuesOf", "object", "str", "array"];

/// Sources that implement SDL, and so match its text by design, and this
/// audit, whose markers are SDL text by design.
immutable string[] sdlImplementations = ["libs/wired/src/sparkles/wired/sdl/",
    "libs/build-primitives/src/sparkles/build_primitives/dub_manifest.d",
    "apps/ci/src/sdl_audit.d"];

/// One ad-hoc SDL match.
struct AdHocSdlHit
{
    string path; /// repository-relative
    size_t line; /// one-based
    string call; /// the audited or formatting call, the operator (`==`, `!=`, `case`, `~`, `~=`), or `i""`
    string literal; /// the offending text, as written between its delimiters
}

private enum Kind : ubyte { identifier, string_, other }

private struct Token
{
    Kind kind;
    string text; // an identifier, a string's contents, or one punctuation byte
    size_t line;
    string escaped; // a string's value, when its escapes changed it
    bool interpolated; // an interpolated expression sequence: `i"…"`, ``i`…` ``, `iq{…}`

    /// A string's value: its contents with `\"`, `\\`, `\n`, `\r` and `\t` decoded.
    string value() const @safe pure nothrow @nogc => escaped is null ? text : escaped;
}

/// `contents` with the escapes markers can hold decoded; null when it has none.
private string unescape(string contents) @safe pure nothrow
{
    if (!contents.canFind(`\`))
        return null;
    auto decoded = appender!string;
    for (size_t i = 0; i < contents.length; i++)
    {
        if (contents[i] != '\\' || i + 1 == contents.length)
        {
            decoded ~= contents[i];
            continue;
        }
        const c = contents[++i];
        decoded ~= c == 'n' ? '\n' : c == 'r' ? '\r' : c == 't' ? '\t' : c;
    }
    return decoded[];
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
        const contents = source[start .. at < source.length ? at : source.length];
        tokens ~= Token(Kind.string_, contents, startLine, escapes ? unescape(contents) : null);
        advance(1);
        // A postfix `c`, `w` or `d` belongs to the literal.
        if (at < source.length && (source[at] == 'c' || source[at] == 'w' || source[at] == 'd'))
            advance(1);
    }

    // Skips an interpolation's expression through its closing `)`; the
    // strings in it, interpolated ones included, are skipped whole.
    void skipInterpolation()
    {
        size_t depth = 1;
        while (at < source.length && depth)
        {
            const c = source[at];
            if (c == '(' || c == ')')
            {
                depth = c == '(' ? depth + 1 : depth - 1;
                advance(1);
            }
            else if (c == '"' || c == '`' || c == '\'')
            {
                const nested = at > 0 && source[at - 1] == 'i';
                advance(1);
                while (at < source.length && source[at] != c)
                {
                    if (c != '`' && source[at] == '\\')
                        advance(2);
                    else if (nested && lookingAt("$("))
                    {
                        advance(2);
                        skipInterpolation();
                    }
                    else
                        advance(1);
                }
                advance(1);
            }
            else
                advance(1);
        }
    }

    // An interpolated sequence's contents, through `close` (a `}` balanced
    // against `{`). Its value holds the literal parts only: each `$(…)`
    // stands as `\x01`, so no marker spans one and no line starts after one.
    void interpolated(char close, bool escapes, size_t startLine)
    {
        const start = at;
        auto value = appender!string;
        size_t braces = 1;
        while (at < source.length)
        {
            const c = source[at];
            if (escapes && c == '\\' && at + 1 < source.length)
            {
                const e = source[at + 1];
                value ~= e == 'n' ? '\n' : e == 'r' ? '\r' : e == 't' ? '\t' : e;
                advance(2);
            }
            else if (lookingAt("$("))
            {
                advance(2);
                skipInterpolation();
                value ~= '\x01';
            }
            else if (c == close && (close != '}' || --braces == 0))
                break;
            else
            {
                if (close == '}' && c == '{')
                    braces++;
                value ~= c;
                advance(1);
            }
        }
        // Never null, so an empty value still reads as the value.
        tokens ~= Token(Kind.string_, source[start .. at], startLine, value[] ~ "", true);
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
        else if (c == 'i' && at + 1 < source.length
            && (source[at + 1] == '"' || source[at + 1] == '`'))
        {
            const close = source[at + 1];
            advance(2);
            interpolated(close, close == '"', startLine);
        }
        else if (lookingAt("iq{"))
        {
            advance(3);
            interpolated('}', false, startLine);
        }
        else if ((c == 'r' || c == 'x') && at + 1 < source.length
            && (source[at + 1] == '"' || source[at + 1] == '`'))
        {
            const close = source[at + 1];
            advance(2);
            quoted(close, c != 'r' && close == '"', startLine);
        }
        else if (lookingAt("q\""))
        {
            advance(2);
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
        else if (lookingAt("q{"))
        {
            advance(2);
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

/**
Whether `text`, a concatenation operand's value, holds recipe syntax rather
than a marker in prose: `dub.sdl:`, `configuration "` or `dependency "`; a
line that starts — after indentation — with `+/`, or with a key marker
followed by its end, a space, a tab, `"`, `{`, `\` or `-`; or the test
runner's dependency name in quotes, or its source-include path.
*/
private bool hasRecipeSyntax(scope const(char)[] text) @safe pure nothrow @nogc
{
    static immutable string[] syntax = ["dub.sdl:", `configuration "`, `dependency "`,
        `"sparkles:test-runner`, "test-runner/src"];
    static immutable string[] keys = ["buildType", "subPackage", "dflags", "lflags"];
    foreach (marker; syntax)
        if (text.canFind(marker))
            return true;
    for (size_t lineStart = 0; lineStart <= text.length;)
    {
        size_t at = lineStart;
        while (at < text.length && (text[at] == ' ' || text[at] == '\t'))
            at++;
        const rest = text[at .. $];
        if (rest.startsWith("+/"))
            return true;
        foreach (key; keys)
            if (rest.startsWith(key))
            {
                const after = rest[key.length .. $];
                if (after.length == 0 || after[0] == ' ' || after[0] == '\t' || after[0] == '"'
                    || after[0] == '{' || after[0] == '\\' || after[0] == '-')
                    return true;
            }
        size_t next = at;
        while (next < text.length && text[next] != '\n')
            next++;
        lineStart = next + 1;
    }
    return false;
}

/// The ad-hoc SDL matches in one D source, `path` repository-relative.
AdHocSdlHit[] auditSource(string path, string source) @safe pure
{
    foreach (prefix; sdlImplementations)
        if (path.startsWith(prefix))
            return null;

    const tokens = lexD(source);
    bool isOp(size_t i, string text)
        => i < tokens.length && tokens[i].kind == Kind.other && tokens[i].text == text;
    bool isIdentifier(size_t i, string text)
        => i < tokens.length && tokens[i].kind == Kind.identifier && tokens[i].text == text;

    // Test code: `unittest { … }`, `version (unittest) { … }` or one
    // declaration, and everything after `version (unittest):`.
    auto test = new bool[tokens.length];
    size_t skipBlock(size_t open)
    {
        size_t depth, i = open;
        for (; i < tokens.length; i++)
        {
            if (isOp(i, "{"))
                depth++;
            else if (isOp(i, "}") && --depth == 0)
                break;
        }
        return i;
    }
    for (size_t i = 0; i < tokens.length; i++)
    {
        size_t from = i, body = size_t.max;
        if (isIdentifier(i, "unittest"))
            body = i + 1;
        else if (isIdentifier(i, "version") && i + 3 < tokens.length && tokens[i + 1].text == "("
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

    // Each token's innermost enclosing `{`, and each `{`'s `}`.
    auto enclosing = new size_t[tokens.length];
    auto closeOf = new size_t[tokens.length];
    {
        size_t[] open;
        foreach (i; 0 .. tokens.length)
        {
            enclosing[i] = open.length ? open[$ - 1] : size_t.max;
            if (isOp(i, "{"))
                open ~= i;
            else if (isOp(i, "}") && open.length)
            {
                closeOf[open[$ - 1]] = i;
                open = open[0 .. $ - 1];
            }
        }
        foreach (o; open)
            closeOf[o] = tokens.length;
    }

    // The bracket matching the one at `i`, searching forward from `(`/`[`
    // or backward from `)`/`]`; the token range's edge when unmatched.
    size_t matchForward(size_t i)
    {
        const open = tokens[i].text, close = open == "(" ? ")" : "]";
        size_t depth;
        foreach (k; i .. tokens.length)
        {
            if (isOp(k, open))
                depth++;
            else if (isOp(k, close) && --depth == 0)
                return k;
        }
        return tokens.length;
    }
    size_t matchBackward(size_t i)
    {
        const close = tokens[i].text, open = close == ")" ? "(" : "[";
        size_t depth;
        foreach_reverse (k; 0 .. i + 1)
        {
            if (isOp(k, close))
                depth++;
            else if (isOp(k, open) && --depth == 0)
                return k;
        }
        return 0;
    }

    // A postfix expression — an atom or a parenthesized group, then member
    // reads, calls, indexing and template arguments — by its last token, or
    // by its first.
    size_t expressionStart(size_t last)
    {
        size_t i = last;
        for (;;)
        {
            if (isOp(i, ")") || isOp(i, "]"))
            {
                i = matchBackward(i);
                if (i > 0 && (tokens[i - 1].kind != Kind.other || isOp(i - 1, ")")
                    || isOp(i - 1, "]") || isOp(i - 1, "!")))
                {
                    i--;
                    continue;
                }
                return i;
            }
            if (isOp(i, "!") && i > 0)
            {
                i--;
                continue;
            }
            // Punctuation ends it (a number lexes as `0`, an atom).
            if (tokens[i].kind == Kind.other && tokens[i].text != "0")
                return i + 1;
            if (i >= 2 && isOp(i - 1, "."))
            {
                i -= 2;
                continue;
            }
            if (i >= 2 && isOp(i - 1, "!") && tokens[i - 2].kind == Kind.identifier)
            {
                i -= 2;
                continue;
            }
            return i;
        }
    }
    size_t expressionEnd(size_t first)
    {
        if (first >= tokens.length)
            return first;
        size_t i = isOp(first, "(") || isOp(first, "[") ? matchForward(first) + 1 : first + 1;
        while (i < tokens.length)
        {
            if (isOp(i, ".") && i + 1 < tokens.length)
                i += 2;
            else if (isOp(i, "(") || isOp(i, "["))
                i = matchForward(i) + 1;
            else if (isOp(i, "!") && !isOp(i + 1, "=") && i + 1 < tokens.length)
                i = isOp(i + 1, "(") ? matchForward(i + 1) + 1 : i + 2;
            else
                break;
        }
        return i < tokens.length ? i : tokens.length;
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
    // Only an initializer of literals, `~`, other names and array brackets is
    // a string constant; one that calls or reads a member (`run([… "--data=dflags"])`)
    // is a value that merely mentions a marker.
    bool isStringInitializer(size_t from)
    {
        for (size_t j = from; j < tokens.length && !isOp(j, ";"); j++)
            if (!(tokens[j].kind == Kind.string_ || tokens[j].kind == Kind.identifier
                || isOp(j, "~") || isOp(j, "[") || isOp(j, "]") || isOp(j, ",")))
                return false;
        return true;
    }
    bool[string] markedConstants, syntaxConstants;
    foreach (i, ref t; tokens)
        if (t.kind == Kind.identifier && isOp(i + 1, "=") && !isOp(i + 2, "=")
            && !test[i] && isConstantDeclaration(i) && isStringInitializer(i + 2))
            for (size_t j = i + 2; j < tokens.length && tokens[j].text != ";"; j++)
                if (tokens[j].kind == Kind.string_)
                {
                    if (hasMarker(tokens[j].value))
                        markedConstants[t.text] = true;
                    if (hasRecipeSyntax(tokens[j].value))
                        syntaxConstants[t.text] = true;
                }
    // A constant is referred to by its bare name, not as a member (`x.name`).
    bool isConstantReference(size_t i, scope const bool[string] constants)
        => tokens[i].kind == Kind.identifier && !(i > 0 && isOp(i - 1, "."))
            && (tokens[i].text in constants) !is null;
    bool isMarked(size_t i)
        => tokens[i].kind == Kind.string_ ? hasMarker(tokens[i].value)
            : isConstantReference(i, markedConstants);
    bool isSyntax(size_t i)
        => tokens[i].kind == Kind.string_ ? hasRecipeSyntax(tokens[i].value)
            : isConstantReference(i, syntaxConstants);

    // Decoded values: a read of a typed model's member, or a name bound from
    // one — a `foreach` variable or an initialized local, visible in the block
    // it was bound in; a lambda parameter, visible in its argument list.
    static struct Binding
    {
        string name;
        size_t from, to; // the tokens it is visible strictly between
    }
    Binding[] decodedBindings;
    bool visible(in Binding b, size_t use) => use > b.from && use < b.to;
    bool isDecoded(size_t from, size_t to, size_t use)
    {
        if (from >= to)
            return false;
        foreach (k; from .. to)
            if (tokens[k].kind == Kind.identifier && k > 0 && isOp(k - 1, ".")
                && decodedAccessors.canFind(tokens[k].text))
                return true;
        if (tokens[from].kind == Kind.identifier)
            foreach (b; decodedBindings)
                if (b.name == tokens[from].text && visible(b, use))
                    return true;
        return false;
    }
    void bind(size_t name, size_t at)
    {
        const block = enclosing[at];
        decodedBindings ~= block == size_t.max ? Binding(tokens[name].text, 0, tokens.length)
            : Binding(tokens[name].text, block, closeOf[block]);
    }
    foreach (i, ref t; tokens)
    {
        if (test[i])
            continue;
        if ((isIdentifier(i, "foreach") || isIdentifier(i, "foreach_reverse")) && isOp(i + 1, "("))
        {
            const close = matchForward(i + 1);
            size_t semi = i + 2;
            while (semi < close && !isOp(semi, ";"))
                semi++;
            if (semi < close && isDecoded(semi + 1, close, i))
                foreach (k; i + 2 .. semi)
                    if (tokens[k].kind == Kind.identifier && (isOp(k + 1, ",") || k + 1 == semi))
                        bind(k, i);
        }
        else if (isOp(i, "=") && isOp(i + 1, ">") && i > 0)
        {
            // `x => …` or `(x, y) => …`, an argument of `receiver.call!(…)`
            // or `receiver.call(…)`: bound when the receiver is decoded.
            size_t paramsFrom = i - 1, paramsTo = i;
            if (isOp(i - 1, ")"))
                paramsFrom = matchBackward(i - 1);
            size_t depth, open = size_t.max;
            foreach_reverse (k; 0 .. paramsFrom)
            {
                if (isOp(k, ")"))
                    depth++;
                else if (isOp(k, "("))
                {
                    if (depth == 0)
                    {
                        open = k;
                        break;
                    }
                    depth--;
                }
            }
            if (open == size_t.max || open == 0)
                continue;
            size_t callee = isOp(open - 1, "!") ? open - 2 : open - 1;
            if (callee >= 2 && tokens[callee].kind == Kind.identifier && isOp(callee - 1, "."))
            {
                const receiverFrom = expressionStart(callee - 2);
                if (isDecoded(receiverFrom, callee - 1, i))
                    foreach (k; paramsFrom .. paramsTo)
                        if (tokens[k].kind == Kind.identifier)
                            decodedBindings ~= Binding(tokens[k].text, open, matchForward(open));
            }
        }
        else if (t.kind == Kind.identifier && isOp(i + 1, "=") && !isOp(i + 2, "=")
            && !isOp(i + 2, ">") && (i == 0 || !isOp(i - 1, ".")))
        {
            if (isDecoded(i + 2, expressionEnd(i + 2), i))
                bind(i, i);
        }
    }

    AdHocSdlHit[] hits;
    bool[size_t] reported;
    void report(size_t marked, string call)
    {
        if (marked in reported)
            return;
        reported[marked] = true;
        hits ~= AdHocSdlHit(path, tokens[marked].line, call, tokens[marked].text);
    }
    // The first marked token of `[from, to)`, or size_t.max.
    size_t markedIn(size_t from, size_t to)
    {
        foreach (k; from .. to)
            if (isMarked(k))
                return k;
        return size_t.max;
    }

    // A call's operands, by the call's name at `i`: the UFCS receiver and
    // each argument of its template and runtime argument lists.
    size_t[2][] callOperands(size_t i)
    {
        size_t[2][] operands;
        if (i >= 2 && isOp(i - 1, "."))
            operands ~= [expressionStart(i - 2), i - 1];
        void arguments(size_t from, size_t to)
        {
            size_t start = from, depth;
            foreach (k; from .. to)
            {
                if (isOp(k, "(") || isOp(k, "[") || isOp(k, "{"))
                    depth++;
                else if (isOp(k, ")") || isOp(k, "]") || isOp(k, "}"))
                    depth--;
                else if (isOp(k, ",") && depth == 0)
                {
                    operands ~= [start, k];
                    start = k + 1;
                }
            }
            if (start < to)
                operands ~= [start, to];
        }
        size_t j = i + 1;
        if (isOp(j, "!"))
        {
            j++;
            if (isOp(j, "("))
            {
                const close = matchForward(j);
                arguments(j + 1, close);
                j = close + 1;
            }
            else if (j < tokens.length)
                arguments(j, ++j);
        }
        if (isOp(j, "("))
            arguments(j + 1, matchForward(j));
        return operands;
    }

    foreach (i, ref t; tokens)
    {
        if (test[i])
            continue;

        // An interpolated sequence formats text: literal parts holding
        // recipe syntax build SDL.
        if (t.interpolated && isSyntax(i))
            report(i, `i""`);

        // A text-matching call: its operands are the UFCS receiver and each
        // argument of its template and runtime argument lists.
        if (t.kind == Kind.identifier && auditedCalls.canFind(t.text))
        {
            const operands = callOperands(i);
            bool typed;
            foreach (o; operands)
                if (markedIn(o[0], o[1]) == size_t.max && isDecoded(o[0], o[1], i))
                    typed = true;
            if (!typed)
                foreach (o; operands)
                    foreach (k; o[0] .. o[1])
                        if (isMarked(k))
                            report(k, t.text);
            continue;
        }

        // A formatting call, building SDL text: an operand holds recipe
        // syntax. Whatever its other operands are, the text is built by hand.
        if (t.kind == Kind.identifier && formattingCalls.canFind(t.text)
            && (isOp(i - 1, ".") || isOp(i + 1, "(") || isOp(i + 1, "!")))
        {
            foreach (o; callOperands(i))
                foreach (k; o[0] .. o[1])
                    if (isSyntax(k))
                        report(k, t.text);
            continue;
        }

        // A comparison: `a == b` or `a != b`.
        const equals = isOp(i, "=") && isOp(i + 1, "=") && i > 0
            && !(isOp(i - 1, "=") || isOp(i - 1, "!") || isOp(i - 1, "<") || isOp(i - 1, ">"));
        const differs = isOp(i, "!") && isOp(i + 1, "=") && !isOp(i + 2, "=") && i > 0;
        if (equals || differs)
        {
            const leftFrom = expressionStart(i - 1), rightTo = expressionEnd(i + 2);
            const left = markedIn(leftFrom, i), right = markedIn(i + 2, rightTo);
            if (left != size_t.max && !isDecoded(i + 2, rightTo, i))
                report(left, equals ? "==" : "!=");
            if (right != size_t.max && !isDecoded(leftFrom, i, i))
                report(right, equals ? "==" : "!=");
            continue;
        }

        // A `case` label of a `switch`, compared with its expression.
        if (isIdentifier(i, "case"))
        {
            size_t colon = i + 1;
            while (colon < tokens.length && !isOp(colon, ":") && !isOp(colon, ";"))
                colon++;
            const marked = markedIn(i + 1, colon);
            if (marked == size_t.max)
                continue;
            bool typed;
            const block = enclosing[i];
            if (block != size_t.max && block > 0 && isOp(block - 1, ")"))
            {
                const open = matchBackward(block - 1);
                if (open > 0 && isIdentifier(open - 1, "switch"))
                    typed = isDecoded(open + 1, block - 1, i);
            }
            if (!typed)
                foreach (k; i + 1 .. colon)
                    if (isMarked(k))
                        report(k, "case");
            continue;
        }

        // A concatenation, `a ~ b` or `a ~= b`, building SDL text: an
        // operand holds recipe syntax, not just a marker in prose.
        if (isOp(i, "~") && i > 0)
        {
            const append = isOp(i + 1, "=");
            const rightFrom = append ? i + 2 : i + 1;
            const leftFrom = expressionStart(i - 1), rightTo = expressionEnd(rightFrom);
            foreach (k; leftFrom .. i)
                if (isSyntax(k))
                    report(k, append ? "~=" : "~");
            foreach (k; rightFrom .. rightTo)
                if (isSyntax(k))
                    report(k, append ? "~=" : "~");
        }
    }
    return hits;
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
literal written as the audit reports it, its outer blanks stripped (as each
field is); `#` starts a comment line. A
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
bool runner(string s) => s.canFind("sparkles:test-runner"); // a comment: dub.sdl:
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
    assert(hits[2].call == "regex" && hits[3].literal == "sparkles:test-runner");
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

@("sdlAudit.auditSource.flagsConcatenationAndComparison")
@safe pure unittest
{
    enum source = `module m;
string line(string name) => "dependency \"" ~ name ~ "\" version=\"*\"";
void append(ref string text) { text ~= "buildType \"checked\" {\n"; }
enum header = "#!/usr/bin/env dub\n" ~ "/+ dub.sdl:\n";
bool key(string word) => word == "dflags";
bool notKey(string[] words) => words[0] != "lflags";
bool reversed(string word) => "subPackage" == word.strip;
bool cased(string word)
{
    switch (word)
    {
        case "buildType": return true;
        default: return false;
    }
}
string prose(string x) => "Enter edit · +/- step " ~ x ~ "// Generated by sparkles:test-runner"
    ~ "set the dflags of " ~ x;
`;
    const hits = auditSource("apps/x.d", source);
    assert(hits.length == 7);
    assert(hits[0] == AdHocSdlHit("apps/x.d", 2, "~", `dependency \"`));
    assert(hits[1] == AdHocSdlHit("apps/x.d", 3, "~=", `buildType \"checked\" {\n`));
    assert(hits[2].call == "~" && hits[2].literal == `/+ dub.sdl:\n`);
    assert(hits[3] == AdHocSdlHit("apps/x.d", 5, "==", "dflags"));
    assert(hits[4] == AdHocSdlHit("apps/x.d", 6, "!=", "lflags"));
    assert(hits[5].call == "==" && hits[5].literal == "subPackage");
    assert(hits[6] == AdHocSdlHit("apps/x.d", 12, "case", "buildType"));
}

@("sdlAudit.auditSource.flagsFormattingAndInterpolation")
@safe pure unittest
{
    enum source = `module m;
string nested(string n) => i"$(f("dflags \"x\"")) name";
string dep(string name) => format("dependency \"%s\" version=\"*\"", name);
void config(ref W w, string name) { w.formattedWrite!"configuration \"%s\" {\n"(name); }
string key(SdlNode node) => text("dflags \"", node.name, "\"");
void plain(ref W w) { w.writeText("buildType \"checked\" {\n"); }
void ies(ref W w, string name) { w.writeText(i"dependency \"$(name)\" version=\"*\""); }
enum header = "/+ dub.sdl:\n";
void constant(ref W w) { put(w, header); }
string tokens(string n) => iq{subPackage { name "$(n)" }}.text;
string raw(string n) => i` ~ "`    lflags \"$(n)\"`" ~ `;
string prose(size_t n) => format("%s dflags read", n) ~ text(n, " steps of +/-");
void info(size_t n) { log(i"$(n) sub-package(s) to build; set the dflags of $(n)"); }
string spans(string k) => i"$(k)dflags \"x\"";
unittest { auto s = i"dependency \"$(x)\""; }
`;
    const hits = auditSource("apps/x.d", source);
    assert(hits.length == 8);
    // A string inside an interpolation is skipped whole, not misread as its end.
    assert(hits[0] == AdHocSdlHit("apps/x.d", 3, "format", `dependency \"%s\" version=\"*\"`));
    assert(hits[1] == AdHocSdlHit("apps/x.d", 4, "formattedWrite", `configuration \"%s\" {\n`));
    // A decoded argument does not make the text typed.
    assert(hits[2] == AdHocSdlHit("apps/x.d", 5, "text", `dflags \"`));
    assert(hits[3].line == 6 && hits[3].call == "writeText");
    assert(hits[4] == AdHocSdlHit("apps/x.d", 7, "writeText", `dependency \"$(name)\" version=\"*\"`));
    assert(hits[5] == AdHocSdlHit("apps/x.d", 9, "put", "header"));
    assert(hits[6] == AdHocSdlHit("apps/x.d", 10, `i""`, `subPackage { name "$(n)" }`));
    assert(hits[7] == AdHocSdlHit("apps/x.d", 11, `i""`, `    lflags "$(n)"`));
}

@("sdlAudit.auditSource.decodedSubjectsAreTyped")
@safe pure unittest
{
    enum source = `module m;
bool member(SdlNode node) => node.name == "dflags";
bool local(SdlNode node)
{
    const name = node.qualifiedName.localName;
    return name == "buildType";
}
void json(JSONValue c)
{
    foreach (key, value; c.object)
        if (key == "dflags" || key.startsWith("dflags-"))
            use(value);
}
bool lambda(DubBuildSettings s)
    => s.sourcePaths.valuesOf.any!(p => p.endsWith("test-runner/src"))
        || s.dependencies.any!(d => d.name == "sparkles:test-runner");
bool membership(SdlNode node) => ["dflags", "lflags"].canFind(node.qualifiedName.localName);
bool switched(SdlNode node)
{
    switch (node.name) { case "subPackage": return true; default: return false; }
}
bool scopes(string s) => ["test-runner", "wired"].canFind(s);
bool own(string[] args) => args[0].baseName.canFind("test-runner");
void described(string root)
{
    const result = run(["dub", "describe", "--root", root, "--data=dflags"]);
    foreach (line; result.output.lineSplitter)
        if (line != result.input)
            use(line);
}
`;
    assert(auditSource("apps/x.d", source).length == 0);

    // A name bound in one function does not decode the same name elsewhere.
    enum other = `module m;
void a(SdlNode node) { const name = node.name; use(name); }
bool b(string name) { return name == "dflags"; }
`;
    const hits = auditSource("apps/y.d", other);
    assert(hits.length == 1 && hits[0] == AdHocSdlHit("apps/y.d", 3, "==", "dflags"));
}

@("sdlAudit.parseAllowlist")
@safe pure unittest
{
    size_t bad;
    const entries = parseAllowlist("# comment\n\na.d | dflags- | the dub.json reader's keys\n", bad);
    assert(bad == 0 && entries == [AllowedHit("a.d", "dflags-", "the dub.json reader's keys")]);
    assert(parseAllowlist("a.d | dflags\n", bad) is null && bad == 1);
}
