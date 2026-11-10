/++
The fileset query language: a fileset written as text (fileset explorer
`FXL1`–`FXL9`).

```
src/**/*.d - **/*_test.d          # sources, not tests
unions(README.md, docs) & gitTracked()
fileFilter(hasExt(d) && name != package.d)
"my notes"/*.md
```

A query's leaves are paths and calls. A path is relative to the fileset root,
as a Nix path is, and is a run of pieces written together: bare pieces, which
are globs (the fileset library's syntax, `FSG1`, a `\` escaping only a
metacharacter), and quoted pieces, which are literal. `all()`, `none()`,
`exec()`, `gitignored()` and `gitTracked()` are calls. `|` is union, `&`
intersection and `-` difference, `&` binding tighter, and `|` and `-` mixed
need parentheses; Nix's names are accepted in call syntax too: `unions(…)`,
`intersection(a, b)`, `difference(a, b)`, and `fileFilter(p)` over the
predicates `hasExt(x)`, `name == n`, `name != n`, `type == t` and
`type != t`, combined with `&&`, `||`, `!` and parentheses. A `#` where a
token could begin starts a comment that runs to the end of its line.

$(LREF parseQuery) never fails outright: it returns every token it saw, with
its kind, for highlighting — a path's text, its glob metacharacters and its
escapes apart — and either the query's tree or the first error and its byte
offset. $(LREF compileQuery) builds the tree into a fileset arena;
$(LREF canonical) renders it back as text.

The library underneath still takes `.gitignore` patterns: a path reaches it
anchored with a leading `/`, its quoted pieces escaped.

Specified in `docs/specs/fileset-explorer/SPEC.md` §2.
+/
module sparkles.build_primitives.fileset.query;

import sparkles.build_primitives.fileset.value : Fileset, Filesets;

/// A half-open byte range of the query text.
struct Span
{
    size_t start; ///
    size_t end;   ///
}

/// What a token is, for highlighting (`FXL8`).
enum TokenKind : ubyte
{
    path,        /// a path's literal text: a bare piece's, or a quoted piece with its quotes
    globMeta,    /// `*`, `**`, `?`, a whole `[…]` class, a brace's `{`, `,` and `}`
    escape,      /// a `\` and the metacharacter it escapes
    operator,    /// `|`, `&`, `-`, `&&`, `||`, `!`, `==`, `!=`
    function_,   /// a call's name: `all` … `gitTracked`, `unions` … `fileFilter`, `hasExt`
    predicate,   /// `name`, `type`
    comment,     /// `#` to the end of the line
    punctuation, /// `(`, `)`, `,`
}

/// One token of a query.
struct Token
{
    TokenKind kind; ///
    Span span;      ///
}

/// A node of a query's tree.
enum NodeKind : ubyte
{
    glob,         /// `text` is the path, as the library's anchored pattern
    all,          ///
    none,         ///
    exec,         ///
    gitignored,   ///
    gitTracked,   ///
    union_,       /// over `args`, two or more
    intersection, /// over `args`, two or more
    difference,   /// `args[0]` minus `args[1]`
    fileFilter,   /// the files `pred` holds for
}

/// A node of a `fileFilter` predicate.
enum PredKind : ubyte
{
    hasExt, /// `value` is the extension's pattern, without its dot
    name,   /// `value` is the name's pattern
    type,   /// `value` is `regular` or `symlink`
    and,    /// `a && b`
    or,     /// `a || b`
    not,    /// `!a`
}

/// No node.
enum uint noNode = uint.max;

/// A query node.
struct QueryNode
{
    NodeKind kind;  ///
    string text;    /// a path's pattern: `/`-anchored, quoted pieces escaped
    uint[] origin;  /// for each byte of `text`, the query byte it came from
    uint[] args;    /// operands, in order
    uint pred = noNode; /// a `fileFilter`'s predicate
    Span span;      /// the source it was parsed from
}

/// A predicate node.
struct Pred
{
    PredKind kind; ///
    string value;  /// a pattern for `hasExt` and `name`, a word for `type`
    uint a = noNode; ///
    uint b = noNode; ///
    Span span;     ///
    bool negated;  /// written `!=`
}

/// Why a query does not parse or compile, and where (`FXL6`).
struct QueryError
{
    string message; ///
    size_t offset;  /// into the query text
}

/// A parsed query: its tokens, and its tree or its error.
struct Query
{
    string source;     /// the text parsed
    Token[] tokens;    /// every token, comments included, in order
    QueryNode[] nodes; ///
    Pred[] preds;      ///
    uint root = noNode; /// `noNode` for a query with no expression: `none()`
    bool ok;           /// it parsed
    QueryError error;  /// when not `ok`

    /// Whether the query calls `gitTracked()`.
    bool usesGitTracked() const @safe pure nothrow
    {
        foreach (ref n; nodes)
            if (n.kind == NodeKind.gitTracked)
                return true;
        return false;
    }

    /**
    The names of the calls without arguments written as bare paths, `all`
    for `all()` (`FXL9`): each path whose whole text is such a name, once.
    */
    string[] bareCallNames() const @safe pure
    {
        string[] names;
        foreach (ref n; nodes)
            if (n.kind == NodeKind.glob && n.span.end <= source.length)
            {
                const t = source[n.span.start .. n.span.end];
                foreach (c; nullaryCalls)
                    if (t == c)
                    {
                        bool seen;
                        foreach (m; names)
                            seen |= m == c;
                        if (!seen)
                            names ~= c;
                    }
            }
        return names;
    }
}

/// The calls that take no arguments, and the node each is.
private immutable string[] nullaryCalls = ["all", "none", "exec", "gitignored", "gitTracked"];
private immutable NodeKind[] nullaryKinds = [NodeKind.all, NodeKind.none, NodeKind.exec,
    NodeKind.gitignored, NodeKind.gitTracked];

/// The operators, as a bare word spells them.
private immutable string[] operators = ["|", "&", "-", "&&", "||", "==", "!="];

/// Whether `c` is a glob metacharacter a `\` may escape (`FXL1`).
bool isGlobMeta(char c) @safe pure nothrow @nogc
    => c == '*' || c == '?' || c == '[' || c == ']' || c == '{' || c == '}' || c == ','
        || c == '!' || c == '\\';

private bool isSpace(char c) @safe pure nothrow @nogc => c == ' ' || c == '\t' || c == '\r' || c == '\n';

/// Parses `source` (`FXL1`–`FXL6`).
Query parseQuery(string source) @safe pure
{
    auto p = Parser(source);
    p.lex();
    p.parse();
    return p.q;
}

private enum LexKind : ubyte
{
    leaf,
    operator,
    punctuation,
}

// What the parser reads: a path whole, an operator or punctuation.
private struct Lexeme
{
    LexKind kind;
    Span span;
    size_t tok;       // its first token in `q.tokens`
    string pattern;   // a path's, unanchored: bare pieces as written, quoted ones escaped
    uint[] origin;    // for each byte of `pattern`, the query byte it came from
    bool bareWord;    // a single bare piece with no metacharacter or escape
    bool hasMeta;     // a metacharacter outside an escape or quotes
    string literal;   // the text it matches, when it has no metacharacter
}

private struct Parser
{
    Query q;
    Lexeme[] lx;
    size_t at; // into `lx`
    bool failed;
    QueryError lexError;
    bool lexFailed;

    this(string source) @safe pure nothrow
    {
        q.source = source;
    }

    // ---- lexing -------------------------------------------------------

    void lexFail(string message, size_t offset) @safe pure nothrow
    {
        if (lexFailed)
            return;
        lexFailed = true;
        lexError = QueryError(message, offset);
    }

    void token(TokenKind kind, size_t start, size_t end) @safe pure nothrow
    {
        q.tokens ~= Token(kind, Span(start, end));
    }

    void lex() @safe pure
    {
        const s = q.source;
        size_t i;
        while (i < s.length)
        {
            const c = s[i];
            if (isSpace(c))
            {
                ++i;
                continue;
            }
            const start = i;
            if (c == '#')
            {
                while (i < s.length && s[i] != '\n')
                    ++i;
                token(TokenKind.comment, start, i);
                continue;
            }
            if (c == '(' || c == ')' || c == ',')
            {
                lx ~= Lexeme(LexKind.punctuation, Span(start, i + 1), q.tokens.length);
                token(TokenKind.punctuation, start, ++i);
                continue;
            }
            if (c == '!')
            {
                i += i + 1 < s.length && s[i + 1] == '=' ? 2 : 1;
                lx ~= Lexeme(LexKind.operator, Span(start, i), q.tokens.length);
                token(TokenKind.operator, start, i);
                continue;
            }
            i = leaf(i);
        }
    }

    // Lexes the path at `i`, a run of pieces; returns where it ends.
    size_t leaf(size_t i) @safe pure
    {
        const s = q.source;
        const start = i, firstTok = q.tokens.length;
        Lexeme l = Lexeme(LexKind.leaf, Span(start, start), firstTok);
        char[] pattern;
        uint[] origin;
        char[] literal;
        size_t[] braces; // the open braces' offsets
        bool quoted, escaped;

        void put(size_t from, size_t to) // the source bytes, as written
        {
            pattern ~= s[from .. to];
            foreach (k; from .. to)
                origin ~= cast(uint) k;
        }

        // A brace or its comma must be followed by an alternative.
        void needAlternative(size_t after)
        {
            if (after >= s.length || s[after] == ',' || s[after] == '}' || isSpace(s[after])
                || s[after] == '(' || s[after] == ')' || s[after] == '"')
                lexFail("empty brace alternative", after);
        }

        while (i < s.length)
        {
            const d = s[i];
            if (isSpace(d) || d == '(' || d == ')' || (d == ',' && braces.length == 0))
                break;
            const at = i;
            if (d == '"')
            {
                if (braces.length)
                    lexFail("a quoted piece cannot be inside braces", at);
                ++i;
                char[] value;
                while (i < s.length && s[i] != '"')
                {
                    if (s[i] == '\\' && i + 1 < s.length && (s[i + 1] == '"' || s[i + 1] == '\\'))
                        ++i;
                    value ~= s[i];
                    ++i;
                }
                if (i >= s.length)
                {
                    lexFail("a string is not closed", at);
                    token(TokenKind.path, at, i);
                    break;
                }
                ++i; // the closing quote
                token(TokenKind.path, at, i);
                quoted = true;
                // Literal: each byte escaped as the library needs, mapped to its quote.
                const escapedValue = escapeGlob(value);
                pattern ~= escapedValue;
                foreach (_; 0 .. escapedValue.length)
                    origin ~= cast(uint)(at + 1);
                literal ~= value;
                continue;
            }
            if (d == '\\')
            {
                if (i + 1 < s.length && isGlobMeta(s[i + 1]))
                {
                    token(TokenKind.escape, at, i + 2);
                    put(at, i + 2);
                    literal ~= s[i + 1];
                    i += 2;
                    escaped = true;
                    continue;
                }
                lexFail("`\\` escapes only a glob metacharacter: * ? [ ] { } , ! \\", at);
                token(TokenKind.escape, at, i + 1);
                ++i;
                escaped = true;
                continue;
            }
            if (d == '*' || d == '?')
            {
                i += d == '*' && i + 1 < s.length && s[i + 1] == '*' ? 2 : 1;
                token(TokenKind.globMeta, at, i);
                put(at, i);
                l.hasMeta = true;
                continue;
            }
            if (d == '[')
            {
                size_t j = i + 1;
                if (j < s.length && (s[j] == '!' || s[j] == '^'))
                    ++j;
                const body = j;
                while (j < s.length && s[j] != ']' && !isSpace(s[j]) && s[j] != '(' && s[j] != ')'
                    && s[j] != '"' && s[j] != ',')
                    j += s[j] == '\\' && j + 1 < s.length && !isSpace(s[j + 1]) ? 2 : 1;
                if (j >= s.length || s[j] != ']')
                {
                    lexFail("unclosed character class", at);
                    token(TokenKind.globMeta, at, j);
                    i = j;
                    l.hasMeta = true;
                    continue;
                }
                if (j == body)
                    lexFail("empty character class", at);
                i = j + 1;
                token(TokenKind.globMeta, at, i);
                put(at, i);
                l.hasMeta = true;
                continue;
            }
            if (d == '{')
            {
                braces ~= at;
                token(TokenKind.globMeta, at, ++i);
                put(at, i);
                needAlternative(i);
                l.hasMeta = true;
                continue;
            }
            if (d == ',') // inside braces
            {
                token(TokenKind.globMeta, at, ++i);
                put(at, i);
                needAlternative(i);
                continue;
            }
            if (d == '}')
            {
                if (braces.length == 0)
                    lexFail("unmatched `}`", at);
                else
                    braces = braces[0 .. $ - 1];
                token(TokenKind.globMeta, at, ++i);
                put(at, i);
                l.hasMeta = true;
                continue;
            }
            // Literal text, to the next byte that is anything else.
            while (i < s.length && !isSpace(s[i]) && s[i] != '(' && s[i] != ')' && s[i] != '"'
                && s[i] != '\\' && s[i] != '*' && s[i] != '?' && s[i] != '[' && s[i] != '{'
                && s[i] != '}' && s[i] != ',')
                ++i;
            token(TokenKind.path, at, i);
            put(at, i);
            literal ~= s[at .. i];
        }
        if (braces.length)
            lexFail("unclosed brace", braces[0]);
        l.span.end = i;
        l.pattern = pattern.idup;
        l.origin = origin;
        l.literal = literal.idup;
        l.bareWord = !quoted && !escaped && !l.hasMeta && q.tokens.length == firstTok + 1;
        if (l.bareWord)
            foreach (op; operators)
                if (s[start .. i] == op)
                {
                    l.kind = LexKind.operator;
                    q.tokens[firstTok].kind = TokenKind.operator;
                }
        lx ~= l;
        return i;
    }

    // ---- lexeme access ------------------------------------------------

    bool atEnd() const @safe pure nothrow => at >= lx.length;

    ref Lexeme cur() return @safe pure nothrow => lx[at];

    string text() @safe pure nothrow => q.source[cur.span.start .. cur.span.end];

    bool isPunct(string p) @safe pure nothrow
        => !atEnd && cur.kind == LexKind.punctuation && text == p;

    bool isOp(string p) @safe pure nothrow
        => !atEnd && cur.kind == LexKind.operator && text == p;

    size_t here() @safe pure nothrow => atEnd ? q.source.length : cur.span.start;

    size_t endOfPrevious() @safe pure nothrow => lx[at - 1].span.end;

    // A call: a bare word followed by `(`.
    bool isCall(string name) @safe pure nothrow
        => !atEnd && cur.kind == LexKind.leaf && cur.bareWord && text == name && at + 1 < lx.length
            && lx[at + 1].kind == LexKind.punctuation && q.source[lx[at + 1].span.start] == '(';

    // Marks the current lexeme, a bare word, as `kind` for highlighting.
    void mark(TokenKind kind) @safe pure nothrow
    {
        q.tokens[cur.tok].kind = kind;
    }

    void fail(string message, size_t offset) @safe pure nothrow
    {
        if (failed)
            return;
        failed = true;
        q.ok = false;
        q.error = QueryError(message, offset);
    }

    bool expect(string punct, string message) @safe pure nothrow
    {
        if (isPunct(punct))
        {
            ++at;
            return true;
        }
        fail(message, here);
        return false;
    }

    uint node(QueryNode n) @safe pure nothrow
    {
        q.nodes ~= n;
        return cast(uint)(q.nodes.length - 1);
    }

    uint pred(Pred p) @safe pure nothrow
    {
        q.preds ~= p;
        return cast(uint)(q.preds.length - 1);
    }

    // ---- parsing ------------------------------------------------------

    void parse() @safe pure
    {
        q.ok = true;
        if (lx.length)
        {
            const r = expr();
            if (!failed && !atEnd)
                fail("unexpected `" ~ text ~ "`", here);
            if (!failed)
                q.root = r;
        }
        // A glob's own error comes first when it is earlier than the parser's.
        if (lexFailed && (!failed || lexError.offset <= q.error.offset))
        {
            q.ok = false;
            q.error = lexError;
            q.root = noNode;
        }
    }

    uint expr() @safe pure
    {
        auto left = term();
        string first;
        while (!failed && (isOp("|") || isOp("-")))
        {
            const op = text;
            if (first.length && op != first)
            {
                fail("`|` and `-` together need parentheses", here);
                return noNode;
            }
            first = op;
            const start = q.nodes[left].span.start;
            ++at;
            const right = term();
            if (failed)
                return noNode;
            left = node(QueryNode(kind: op == "|" ? NodeKind.union_ : NodeKind.difference,
                args: [left, right], span: Span(start, q.nodes[right].span.end)));
        }
        return left;
    }

    uint term() @safe pure
    {
        auto left = unary();
        while (!failed && isOp("&"))
        {
            const start = q.nodes[left].span.start;
            ++at;
            const right = unary();
            if (failed)
                return noNode;
            left = node(QueryNode(kind: NodeKind.intersection, args: [left, right],
                span: Span(start, q.nodes[right].span.end)));
        }
        return left;
    }

    uint unary() @safe pure
    {
        if (failed)
            return noNode;
        if (atEnd)
        {
            fail("expected a path, a call or `(`", here);
            return noNode;
        }
        const start = here;
        if (isPunct("("))
        {
            ++at;
            const inner = expr();
            if (failed || !expect(")", "expected `)`"))
                return noNode;
            q.nodes[inner].span = Span(start, endOfPrevious);
            return inner;
        }
        foreach (fn; ["unions", "intersection", "difference", "fileFilter"])
            if (isCall(fn))
                return call(fn);
        foreach (k, fn; nullaryCalls)
            if (isCall(fn))
            {
                mark(TokenKind.function_);
                at += 2; // the name and `(`
                if (!expect(")", "`" ~ fn ~ "()` takes no arguments"))
                    return noNode;
                return node(QueryNode(kind: nullaryKinds[k], span: Span(start, endOfPrevious)));
            }
        if (cur.kind != LexKind.leaf)
        {
            fail("expected a path, a call or `(` before `" ~ text ~ "`", start);
            return noNode;
        }
        return path();
    }

    // The current path, anchored at the root (`FXL1`).
    uint path() @safe pure
    {
        auto l = cur;
        string p = l.pattern;
        const(uint)[] o = l.origin;
        if (p.length >= 2 && p[0 .. 2] == "./")
        {
            p = p[2 .. $];
            o = o[2 .. $];
        }
        if (p.length && p[0] == '/')
        {
            fail("a path is relative to the root: drop the leading `/`", o[0]);
            return noNode;
        }
        ++at;
        return node(QueryNode(kind: NodeKind.glob, text: "/" ~ p, origin: [cast(uint) l.span.start] ~ o.dup,
            span: l.span));
    }

    uint call(string fn) @safe pure
    {
        const start = here;
        mark(TokenKind.function_);
        at += 2; // the name and `(`
        if (fn == "fileFilter")
        {
            const p = predicate();
            if (failed || !expect(")", "expected `)` after the predicate"))
                return noNode;
            return node(QueryNode(kind: NodeKind.fileFilter, pred: p, span: Span(start, endOfPrevious)));
        }
        uint[] args;
        if (isPunct(")"))
        {
            fail("`" ~ fn ~ "` needs an argument", here);
            return noNode;
        }
        for (;;)
        {
            args ~= expr();
            if (failed)
                return noNode;
            if (isPunct(","))
            {
                ++at;
                continue;
            }
            if (!expect(")", "expected `,` or `)`"))
                return noNode;
            break;
        }
        const span = Span(start, endOfPrevious);
        if (fn == "unions")
            return args.length == 1 ? args[0] : node(QueryNode(kind: NodeKind.union_, args: args, span: span));
        if (args.length != 2)
        {
            fail("`" ~ fn ~ "` takes two arguments", span.start);
            return noNode;
        }
        return node(QueryNode(kind: fn == "intersection" ? NodeKind.intersection : NodeKind.difference,
            args: args, span: span));
    }

    uint predicate() @safe pure
    {
        auto left = predAnd();
        while (!failed && isOp("||"))
        {
            ++at;
            const right = predAnd();
            if (failed)
                return noNode;
            left = pred(Pred(PredKind.or, null, left, right,
                Span(q.preds[left].span.start, q.preds[right].span.end)));
        }
        return left;
    }

    uint predAnd() @safe pure
    {
        auto left = predNot();
        while (!failed && isOp("&&"))
        {
            ++at;
            const right = predNot();
            if (failed)
                return noNode;
            left = pred(Pred(PredKind.and, null, left, right,
                Span(q.preds[left].span.start, q.preds[right].span.end)));
        }
        return left;
    }

    uint predNot() @safe pure
    {
        if (isOp("!"))
        {
            const start = here;
            ++at;
            const inner = predNot();
            if (failed)
                return noNode;
            return pred(Pred(PredKind.not, null, inner, noNode, Span(start, q.preds[inner].span.end)));
        }
        return predAtom();
    }

    uint predAtom() @safe pure
    {
        if (failed)
            return noNode;
        const start = here;
        if (isPunct("("))
        {
            ++at;
            const inner = predicate();
            if (failed || !expect(")", "expected `)`"))
                return noNode;
            return inner;
        }
        if (isCall("hasExt"))
        {
            mark(TokenKind.function_);
            at += 2;
            string ext;
            if (!argument(ext))
                return noNode;
            if (!expect(")", "expected `)`"))
                return noNode;
            return pred(Pred(PredKind.hasExt, ext, noNode, noNode, Span(start, endOfPrevious)));
        }
        if (!atEnd && cur.kind == LexKind.leaf && cur.bareWord && (text == "name" || text == "type"))
        {
            const isName = text == "name";
            mark(TokenKind.predicate);
            ++at;
            const negated = isOp("!=");
            if (!negated && !isOp("=="))
            {
                fail("expected `==` or `!=`", here);
                return noNode;
            }
            ++at;
            string value;
            if (isName)
            {
                if (!argument(value))
                    return noNode;
            }
            else
            {
                if (atEnd || cur.kind != LexKind.leaf)
                {
                    fail("expected `regular` or `symlink`", here);
                    return noNode;
                }
                // One word, bare or quoted: the grammar's `type_is` takes no joined pieces.
                const t = text;
                if (t != "regular" && t != "symlink" && t != `"regular"` && t != `"symlink"`)
                {
                    fail("a type is `regular` or `symlink`", here);
                    return noNode;
                }
                value = cur.literal;
                ++at;
            }
            return pred(Pred(isName ? PredKind.name : PredKind.type, value, noNode, noNode,
                Span(start, endOfPrevious), negated));
        }
        fail("expected `hasExt(…)`, `name == …`, `type == …`, `!` or `(`", here);
        return noNode;
    }

    // A predicate's argument: a path's pattern, a bare piece a glob, a quoted one literal.
    bool argument(out string pattern) @safe pure
    {
        if (atEnd || cur.kind != LexKind.leaf)
        {
            fail("expected a name or a pattern", here);
            return false;
        }
        pattern = cur.pattern;
        ++at;
        return true;
    }
}

/// FXL1–FXL3: paths, pieces, comments and operators.
@("fileset.query.lexAndParse")
@safe pure unittest
{
    auto q = parseQuery("a-b/*.d | \"#foo#\" & \"a b\" # tail\n| \"say \\\"hi\\\"\" | \"my notes\"/*.md");
    assert(q.ok, q.error.message);
    assert(q.nodes[q.root].kind == NodeKind.union_);
    string[] globs;
    foreach (ref n; q.nodes)
        if (n.kind == NodeKind.glob)
            globs ~= n.text;
    assert(globs == ["/a-b/*.d", "/#foo#", "/a b", "/say \"hi\"", "/my notes/*.md"], globs[0]);

    assert(parseQuery("a#b").nodes[0].text == "/a#b", "a # inside a path is the path's");
    auto c = parseQuery("a #b");
    assert(c.ok && c.nodes.length == 1 && c.nodes[0].text == "/a");
    auto blank = parseQuery("# nothing\n  # at all");
    assert(blank.ok && blank.root == noNode);
    assert(parseQuery("*.{d,di}").nodes[0].text == "/*.{d,di}", "a brace's comma is the path's");
    assert(parseQuery("\"[draft].md\"").nodes[0].text == "/\\[draft\\].md", "quotes are literal");
    assert(parseQuery("./src").nodes[0].text == "/src");
    assert(parseQuery("src\\*x").nodes[0].text == "/src\\*x");
    assert(!parseQuery("/src").ok && parseQuery("/src").error.offset == 0);
    auto bare = parseQuery("all");
    assert(bare.ok && bare.nodes[0].kind == NodeKind.glob && bare.nodes[0].text == "/all",
        "a bare call name is a path");
    assert(bare.bareCallNames == ["all"]);
    auto call = parseQuery("all() - gitTracked()");
    assert(call.ok && call.nodes[0].kind == NodeKind.all && call.usesGitTracked);
    assert(!parseQuery("all(x)").ok);
}

/// FXL8: a path's text, its metacharacters and its escapes are tokens of their own.
@("fileset.query.tokens")
@safe pure unittest
{
    static string kinds(string s)
    {
        auto q = parseQuery(s);
        string r;
        foreach (ref t; q.tokens)
            r ~= (r.length ? " " : "") ~ s[t.span.start .. t.span.end] ~ ":"
                ~ ["p", "m", "e", "o", "f", "r", "c", "u"][t.kind];
        return r;
    }

    assert(kinds("src/*.{d,di}") == "src/:p *:m .:p {:m d:p ,:m di:p }:m", kinds("src/*.{d,di}"));
    assert(kinds("\"a b\"/**/[ab]?") == "\"a b\":p /:p **:m /:p [ab]:m ?:m");
    assert(kinds("x\\*y") == "x:p \\*:e y:p");
    assert(kinds("all() | a - b") != "", "mixing fails, still tokenized");
    assert(kinds("fileFilter(name != *.d)") == "fileFilter:f (:u name:r !=:o *:m .d:p ):u");
}

/// FXL3: `&` binds tighter; `|` and `-` each read left to right, and mixed need parentheses.
@("fileset.query.precedence")
@safe pure unittest
{
    assert(canonical(parseQuery("a | b & c")) == "a | b & c");
    assert(canonical(parseQuery("(a | b) & c")) == "(a | b) & c");
    assert(canonical(parseQuery("a - (b - c)")) == "a - (b - c)");
    assert(canonical(parseQuery("(a - b) - c")) == "a - b - c");
    assert(canonical(parseQuery("a - b - c")) == "a - b - c");
    auto mixed = parseQuery("a | b - c");
    assert(!mixed.ok && mixed.error.offset == 6, mixed.error.message);
    assert(!parseQuery("a - b | c").ok);
    assert(canonical(parseQuery("(a | b) - c")) == "(a | b) - c");
    assert(canonical(parseQuery("a | (b - c)")) == "a | (b - c)");
}

/// FXL4: function forms mean what the operators mean; predicates take bare arguments.
@("fileset.query.functions")
@safe pure unittest
{
    assert(canonical(parseQuery("difference(unions(a, b, c), intersection(d, e))")) == "(a | b | c) - d & e");
    assert(canonical(parseQuery("unions(a)")) == "a");
    assert(canonical(parseQuery("fileFilter(hasExt(\"d\") && !name == \"x.d\")"))
        == "fileFilter(hasExt(d) && !name == x.d)");
    assert(canonical(parseQuery("fileFilter(hasExt(d) && name != x.d)"))
        == "fileFilter(hasExt(d) && name != x.d)");
    assert(canonical(parseQuery("fileFilter((type == symlink || name == a) && hasExt(d))"))
        == "fileFilter((type == symlink || name == a) && hasExt(d))");
    assert(canonical(parseQuery("fileFilter(type != \"regular\")")) == "fileFilter(type != regular)");
    assert(!parseQuery("fileFilter(type == dir)").ok);
    auto glob = parseQuery("fileFilter(name == *_test.d)");
    assert(glob.ok && glob.preds[0].value == "*_test.d");
    assert(parseQuery("fileFilter(name == \"*_test.d\")").preds[0].value == "\\*_test.d", "quoted: literal");
}

/// FXL6: an error has one message and the byte it is about.
@("fileset.query.errors")
@safe pure unittest
{
    assert(parseQuery("(a | b").error.offset == 6);
    assert(parseQuery("unions()").error.offset == 7);
    assert(parseQuery("a b").error.offset == 2);
    assert(parseQuery("a |").error.offset == 3);
    assert(parseQuery("\"open").error.offset == 0);
    assert(parseQuery("difference(a)").error.message == "`difference` takes two arguments");
    assert(parseQuery("| a").error.offset == 0);
    assert(parseQuery("a | [b").error.offset == 4);
    assert(parseQuery("a\\ b").error.offset == 1);
    assert(parseQuery("a{b").error.offset == 1);
    assert(parseQuery("a}").error.offset == 1);
    assert(parseQuery("a{b,}").error.offset == 4);
    assert(parseQuery("x[]").error.offset == 1);
    assert(parseQuery("{\"a\"}").error.offset == 1);
}

// ---- the canonical form (FXL7) ------------------------------------------

/// The query's canonical text: comments dropped, operators for the function
/// forms that have one, n-ary unions and intersections flattened, parentheses
/// only where precedence needs them, and paths bare where they can be.
/// `none()` for an empty query.
string canonical(in Query q) @safe pure
{
    if (!q.ok)
        return null;
    if (q.root == noNode)
        return "none()";
    return render(q, q.root, 0);
}

// 1: `|`; 2: `-`; 3: `&`; 4: a leaf.
private int level(NodeKind k) @safe pure nothrow @nogc
    => k == NodeKind.union_ ? 1 : k == NodeKind.difference ? 2 : k == NodeKind.intersection ? 3 : 4;

// `outer`: the operator around it, whose operand needs parentheses unless it
// binds tighter, or is the same left-associative run on the left.
private string render(in Query q, uint n, int outer, bool leftOfSame = false) @safe pure
{
    const node = q.nodes[n];
    const lv = level(node.kind);
    string s;
    final switch (node.kind)
    {
        case NodeKind.glob: s = globText(node.text); break;
        case NodeKind.all: s = "all()"; break;
        case NodeKind.none: s = "none()"; break;
        case NodeKind.exec: s = "exec()"; break;
        case NodeKind.gitignored: s = "gitignored()"; break;
        case NodeKind.gitTracked: s = "gitTracked()"; break;
        case NodeKind.union_, NodeKind.intersection:
            const op = node.kind == NodeKind.union_ ? " | " : " & ";
            foreach (i, a; flatten(q, n, node.kind))
                s ~= (i ? op : "") ~ render(q, a, lv);
            break;
        case NodeKind.difference:
            // Left-associative: a difference on the left reads without parentheses.
            s = render(q, node.args[0], lv, true) ~ " - " ~ render(q, node.args[1], lv);
            break;
        case NodeKind.fileFilter:
            s = "fileFilter(" ~ renderPred(q, node.pred, 0) ~ ")";
            break;
    }
    // An intersection or a leaf binds tightest; a union or a difference inside
    // an intersection needs parentheses, and so do `|` and `-` side by side,
    // but for a difference's left operand that is a difference.
    bool bare;
    if (outer == 0 || lv >= 3)
        bare = true;
    else if (outer == 3)
        bare = false;
    else if (lv == outer)
        bare = lv == 1 || leftOfSame;
    else
        bare = false;
    return bare ? s : "(" ~ s ~ ")";
}

// The operands of a run of one associative operator.
private uint[] flatten(in Query q, uint n, NodeKind kind) @safe pure
{
    uint[] out_;
    foreach (a; q.nodes[n].args)
        if (q.nodes[a].kind == kind)
            out_ ~= flatten(q, a, kind);
        else
            out_ ~= a;
    return out_;
}

private string renderPred(in Query q, uint p, int outer) @safe pure
{
    const pr = q.preds[p];
    int prec;
    string s;
    const eq = pr.negated ? " != " : " == ";
    final switch (pr.kind)
    {
        case PredKind.hasExt: prec = 3; s = "hasExt(" ~ pathText(pr.value) ~ ")"; break;
        case PredKind.name: prec = 3; s = "name" ~ eq ~ pathText(pr.value); break;
        case PredKind.type: prec = 3; s = "type" ~ eq ~ pr.value; break;
        case PredKind.not: prec = 3; s = "!" ~ renderPred(q, pr.a, 3); break;
        case PredKind.and: prec = 2; s = renderPred(q, pr.a, 2) ~ " && " ~ renderPred(q, pr.b, 2); break;
        case PredKind.or: prec = 1; s = renderPred(q, pr.a, 1) ~ " || " ~ renderPred(q, pr.b, 1); break;
    }
    return prec < outer ? "(" ~ s ~ ")" : s;
}

/// `s` as a quoted piece: quoted, with `"` and `\` escaped.
string quote(scope const(char)[] s) @safe pure
{
    string r = "\"";
    foreach (c; s)
    {
        if (c == '"' || c == '\\')
            r ~= '\\';
        r ~= c;
    }
    return r ~ "\"";
}

/**
A path's pattern, anchored as $(LREF QueryNode)`.text` is, as the query
writes it: without the anchor, bare where a bare piece can hold it, a run of
literal text quoted where one cannot.
*/
string globText(string pattern) @safe pure
    => pathText(pattern.length && pattern[0] == '/' ? pattern[1 .. $] : pattern);

/// ditto, for an unanchored pattern: a predicate's argument.
string pathText(string p) @safe pure
{
    string out_;
    char[] run; // literal bytes, unescaped
    int depth;

    void flush()
    {
        if (run.length == 0)
            return;
        bool needsQuotes = out_.length == 0 && run[0] == '#';
        foreach (c; run)
            needsQuotes |= isSpace(c) || c == '(' || c == ')' || c == '"';
        if (needsQuotes)
            out_ ~= quote(run);
        else
            foreach (i, c; run)
            {
                if (isGlobMeta(c) && (c != '!' || (out_.length == 0 && i == 0)))
                    out_ ~= '\\';
                out_ ~= c;
            }
        run = null;
    }

    for (size_t i; i < p.length;)
    {
        const c = p[i];
        if (c == '\\' && i + 1 < p.length)
        {
            run ~= p[i + 1];
            i += 2;
            continue;
        }
        if (c == '[')
        {
            flush();
            size_t j = i + 1;
            if (j < p.length && (p[j] == '!' || p[j] == '^'))
                ++j;
            while (j < p.length && p[j] != ']')
                j += p[j] == '\\' && j + 1 < p.length ? 2 : 1;
            j = j < p.length ? j + 1 : j;
            out_ ~= p[i .. j];
            i = j;
            continue;
        }
        if (c == '*' || c == '?' || c == '{' || (depth > 0 && (c == ',' || c == '}')))
        {
            flush();
            depth += c == '{' ? 1 : c == '}' ? -1 : 0;
            out_ ~= c;
            ++i;
            continue;
        }
        run ~= c;
        ++i;
    }
    flush();
    if (out_.length == 0)
        return "./";
    foreach (op; operators)
        if (out_ == op)
            return quote(out_);
    return out_;
}

/// FXL7: the canonical form parses to the same tree's text again.
@("fileset.query.canonicalRoundTrips")
@safe pure unittest
{
    foreach (s; ["a | b & c", "(a | b) & c", "a - (b - c)", "\"a b\" | \"#x\" | \"|\"",
        "fileFilter(!(hasExt(d) || type == symlink))", "all() - gitignored()", "*.{d,di}",
        "\"my notes\"/*.md", "\"[x]\" | a\\*b", "(a | b) - c & d", "a | (b - c)", "./x"])
    {
        const once = canonical(parseQuery(s));
        assert(once.length, s);
        assert(canonical(parseQuery(once)) == once, once);
    }
    assert(globText("/|") == "\"|\"" && globText("/all") == "all" && globText("/a b") == "\"a b\"");
    assert(globText("/src/**") == "src/**");
    assert(globText("/my notes/*.md") == "\"my notes/\"*.md");
    assert(globText("/\\[x\\]") == "\\[x\\]");
    assert(canonical(parseQuery("")) == "none()");
}

// ---- compilation --------------------------------------------------------

/// What compiling a query gives: the fileset, or why not.
struct Compiled
{
    bool ok;          ///
    Fileset set;      /// when `ok`
    QueryError error; /// when not
}

/**
Builds the parsed `q` into `sets`. `tracked` lists the files of git's index
beneath the fileset root for `gitTracked()`, or returns `null` when the root
is not in a git work tree, which fails the query (`FXL5`); it is called at
most once, and only when `q` uses `gitTracked()`.
*/
Compiled compileQuery(const Query q, ref Filesets sets, scope string[] delegate() @safe tracked)
    @safe
{
    if (!q.ok)
        return Compiled(false, Fileset.init, q.error);
    if (q.root == noNode)
        return Compiled(true, sets.nothing);
    bool haveTracked;
    Fileset trackedSet;
    QueryError err;

    bool buildPred(uint p, out Fileset f)
    {
        const pr = q.preds[p];
        final switch (pr.kind)
        {
            case PredKind.hasExt, PredKind.name:
                const pattern = pr.kind == PredKind.hasExt ? "*." ~ pr.value : pr.value;
                auto g = sets.fileName(pattern);
                if (g.hasError)
                {
                    err = QueryError(g.error.context, pr.span.start);
                    return false;
                }
                f = pr.negated ? sets.difference(sets.everything, g.value) : g.value;
                return true;
            case PredKind.type:
                const symlink = pr.value == "symlink";
                f = symlink != pr.negated ? sets.symlinks : sets.difference(sets.everything, sets.symlinks);
                return true;
            case PredKind.not:
                Fileset a;
                if (!buildPred(pr.a, a))
                    return false;
                f = sets.difference(sets.everything, a);
                return true;
            case PredKind.and, PredKind.or:
                Fileset a, b;
                if (!buildPred(pr.a, a) || !buildPred(pr.b, b))
                    return false;
                f = pr.kind == PredKind.and ? sets.intersection(a, b) : sets.union_(a, b);
                return true;
        }
    }

    bool build(uint n, out Fileset f)
    {
        const node = q.nodes[n];
        final switch (node.kind)
        {
            case NodeKind.glob:
                auto g = sets.glob(node.text);
                if (g.hasError)
                {
                    const at = g.error.offset < node.origin.length ? node.origin[g.error.offset]
                        : node.span.end;
                    err = QueryError(g.error.context, at);
                    return false;
                }
                f = g.value;
                return true;
            case NodeKind.all: f = sets.everything; return true;
            case NodeKind.none: f = sets.nothing; return true;
            case NodeKind.exec: f = sets.executable; return true;
            case NodeKind.gitignored: f = sets.gitignored; return true;
            case NodeKind.gitTracked:
                if (!haveTracked)
                {
                    auto list = tracked is null ? null : tracked();
                    if (list is null)
                    {
                        err = QueryError("not a git work tree", node.span.start);
                        return false;
                    }
                    auto p = sets.paths(list);
                    if (p.hasError)
                    {
                        err = QueryError(p.error.context, node.span.start);
                        return false;
                    }
                    trackedSet = p.value;
                    haveTracked = true;
                }
                f = trackedSet;
                return true;
            case NodeKind.union_, NodeKind.intersection, NodeKind.difference:
                Fileset acc;
                foreach (i, a; node.args)
                {
                    Fileset x;
                    if (!build(a, x))
                        return false;
                    acc = i == 0 ? x : node.kind == NodeKind.union_ ? sets.union_(acc, x)
                        : node.kind == NodeKind.intersection ? sets.intersection(acc, x)
                        : sets.difference(acc, x);
                }
                f = acc;
                return true;
            case NodeKind.fileFilter:
                return buildPred(node.pred, f);
        }
    }

    Fileset f;
    if (!build(q.root, f))
        return Compiled(false, Fileset.init, err);
    return Compiled(true, f);
}

/// `s` with every glob metacharacter escaped, so it matches only itself.
string escapeGlob(scope const(char)[] s) @safe pure
{
    string r;
    foreach (c; s)
    {
        if (isGlobMeta(c))
            r ~= '\\';
        r ~= c;
    }
    return r;
}

/**
The files of git's index beneath `dir`, relative to it (`git ls-files`), or
`null` when `dir` is not in a git work tree, or there is no `git` to ask (a
phone): the `tracked` of $(LREF compileQuery).
*/
string[] gitTrackedPaths(string dir) @safe
{
    import std.algorithm.iteration : filter, splitter;
    import std.array : array;
    import std.process : ProcessException;
    import sparkles.build_primitives.git_env : runGit;

    typeof(runGit(null, dir)) r;
    try
        r = runGit(["ls-files", "-z", "--cached"], dir);
    catch (ProcessException)
        return null;
    if (r.status != 0)
        return null;
    auto list = r.output.splitter('\0').filter!(p => p.length > 0).array;
    return list.length ? list : [];
}

/// FXL5: `gitTracked()` is the index beneath the root, and a plain directory
/// has none.
@("fileset.query.FXL5.gitTracked")
@system unittest
{
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.process : thisProcessID;
    import std.conv : text;
    import sparkles.build_primitives.git_env : runGit;
    import sparkles.test_runner.skip : skipTest;

    try
        cast(void) runGit(["--version"]);
    catch (Exception)
        return skipTest("git is not installed");

    const dir = buildPath(tempDir, text("fxl5-", thisProcessID));
    scope (exit) rmdirRecurse(dir);
    mkdirRecurse(buildPath(dir, "repo", "sub"));
    mkdirRecurse(buildPath(dir, "plain"));
    write(buildPath(dir, "repo", "a.d"), "a");
    write(buildPath(dir, "repo", "sub", "b.d"), "b");
    write(buildPath(dir, "repo", "untracked"), "u");
    const repo = buildPath(dir, "repo");
    assert(runGit(["init", "-q"], repo).status == 0);
    assert(runGit(["add", "a.d", "sub/b.d"], repo).status == 0);

    assert(gitTrackedPaths(repo) == ["a.d", "sub/b.d"]);
    assert(gitTrackedPaths(buildPath(repo, "sub")) == ["b.d"], "relative to the root, beneath it");
    assert(gitTrackedPaths(buildPath(dir, "plain")) is null);
}

version (unittest)
{
    import sparkles.build_primitives.fileset.pattern : CasePolicy;
    import sparkles.build_primitives.fileset.value : FilesetEvaluator;
}

/// A query compiles to the fileset its operators and predicates mean.
@("fileset.query.compile")
@safe unittest
{
    auto sets = Filesets(CasePolicy.sensitive);
    bool has(string query, string path)
    {
        auto c = compileQuery(parseQuery(query), sets, () => ["a.d", "src/t.d"]);
        assert(c.ok, c.error.message);
        auto ev = FilesetEvaluator(sets, c.set);
        return ev.contains(sets, path);
    }

    assert(has("src/**/*.d - **/*_test.d", "src/a.d") && !has("src/**/*.d - **/*_test.d", "src/a_test.d"));
    assert(has("README.md", "README.md") && !has("README.md", "docs/README.md"), "relative to the root");
    assert(has("**/README.md", "docs/README.md"));
    assert(has("src", "src/a/b.d"), "a directory selects what is beneath it");
    assert(has("fileFilter(hasExt(d) && name != x.d)", "q/y.d"));
    assert(!has("fileFilter(hasExt(d) && name != x.d)", "q/x.d"));
    assert(has("fileFilter(name == *_test.d)", "q/a_test.d"), "a bare name is a glob");
    assert(has("fileFilter(name == \"a*b\")", "a*b") && !has("fileFilter(name == \"a*b\")", "aXb"),
        "a quoted name is literal");
    assert(has("\"[x].md\"", "[x].md") && !has("\"[x].md\"", "x.md"), "a quoted piece is literal");
    assert(has("\"my notes\"/*.md", "my notes/a.md"));
    assert(has("gitTracked() & **/*.d", "src/t.d") && !has("gitTracked()", "b.d"));
    assert(has("fileFilter(type != symlink)", "a.d"));

    auto none = compileQuery(parseQuery("gitTracked()"), sets, () => cast(string[]) null);
    assert(!none.ok && none.error.message == "not a git work tree");
    auto bad = compileQuery(parseQuery("a | x/{b/c,d}"), sets, null);
    assert(!bad.ok && bad.error.offset >= 4, bad.error.message);
}
