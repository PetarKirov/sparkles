/++
The fileset query language: a fileset written as text (fileset explorer
`FXL1`–`FXL7`).

```
src/**/*.d - **/*_test.d          # sources, not tests
unions("README.md", docs/**) & gitTracked
fileFilter(hasExt("d") && !name == "package.d")
```

A query's leaves are globs (the fileset library's, `FSG1`), double-quoted
strings, which are globs whose text may hold any character, and the keywords
`all`, `none`, `exec`, `gitignored` and `gitTracked`. `|` is union, `&`
intersection and `-` difference, `&` binding tighter; Nix's names are
accepted in call syntax too: `unions(…)`, `intersection(a, b)`,
`difference(a, b)`, and `fileFilter(p)` over the predicates `hasExt("x")`,
`name == "n"` and `type == "regular" | "symlink"`, combined with `&&`, `||`,
`!` and parentheses. A `#` where a token could begin starts a comment that
runs to the end of its line.

$(LREF parseQuery) never fails outright: it returns every token it saw, with
its kind, for highlighting, and either the query's tree or the first error
and its byte offset. $(LREF compileQuery) builds the tree into a fileset
arena; $(LREF canonical) renders it back as text.

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
    glob,        /// a bare glob
    string_,     /// a double-quoted glob
    keyword,     /// `all`, `none`, `exec`, `gitignored`, `gitTracked`
    operator,    /// `|`, `&`, `-`, `&&`, `||`, `!`, `==`
    function_,   /// `unions`, `intersection`, `difference`, `fileFilter`, `hasExt`
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
    glob,         /// `text` is the glob
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
    hasExt, /// `value` is the extension, without its dot
    name,   /// `value` is the whole name
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
    string text;    /// a glob's text, unescaped
    bool quoted;    /// the glob was a string
    uint[] args;    /// operands, in order
    uint pred = noNode; /// a `fileFilter`'s predicate
    Span span;      /// the source it was parsed from
}

/// A predicate node.
struct Pred
{
    PredKind kind; ///
    string value;  ///
    uint a = noNode; ///
    uint b = noNode; ///
    Span span;     ///
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
    uint root = noNode; /// `noNode` for a query with no expression: `none`
    bool ok;           /// it parsed
    QueryError error;  /// when not `ok`

    /// Whether the query names `gitTracked`.
    bool usesGitTracked() const @safe pure nothrow
    {
        foreach (ref n; nodes)
            if (n.kind == NodeKind.gitTracked)
                return true;
        return false;
    }
}

private immutable string[] keywords = ["all", "none", "exec", "gitignored", "gitTracked"];

/// Parses `source` (`FXL1`–`FXL6`).
Query parseQuery(string source) @safe pure
{
    auto p = Parser(source);
    p.lex();
    p.parse();
    return p.q;
}

private struct Parser
{
    Query q;
    size_t[] sig; // indices of the non-comment tokens
    size_t at;    // into `sig`
    bool failed;

    this(string source) @safe pure nothrow
    {
        q.source = source;
    }

    // ---- lexing -------------------------------------------------------

    void lex() @safe pure
    {
        const s = q.source;
        size_t i;
        while (i < s.length)
        {
            const c = s[i];
            if (c == ' ' || c == '\t' || c == '\r' || c == '\n')
            {
                ++i;
                continue;
            }
            const start = i;
            if (c == '#')
            {
                while (i < s.length && s[i] != '\n')
                    ++i;
                q.tokens ~= Token(TokenKind.comment, Span(start, i));
                continue;
            }
            if (c == '(' || c == ')' || c == ',')
            {
                q.tokens ~= Token(TokenKind.punctuation, Span(start, ++i));
                continue;
            }
            if (c == '"')
            {
                ++i;
                while (i < s.length && s[i] != '"')
                    i += s[i] == '\\' && i + 1 < s.length ? 2 : 1;
                if (i < s.length)
                    ++i; // the closing quote; an unclosed one is the parser's error
                q.tokens ~= Token(TokenKind.string_, Span(start, i));
                continue;
            }
            if (c == '!' && !(i + 1 < s.length && s[i + 1] == '='))
            {
                q.tokens ~= Token(TokenKind.operator, Span(start, ++i));
                continue;
            }
            int braces;
            while (i < s.length)
            {
                const d = s[i];
                if (d == '\\' && i + 1 < s.length)
                {
                    i += 2;
                    continue;
                }
                if (d == ' ' || d == '\t' || d == '\r' || d == '\n' || d == '(' || d == ')'
                    || d == '"' || (d == ',' && braces == 0))
                    break;
                if (d == '{')
                    ++braces;
                else if (d == '}' && braces > 0)
                    --braces;
                ++i;
            }
            const word = s[start .. i];
            TokenKind kind = TokenKind.glob;
            switch (word)
            {
                case "|", "&", "-", "&&", "||", "==":
                    kind = TokenKind.operator;
                    break;
                default:
                    foreach (k; keywords)
                        if (word == k)
                            kind = TokenKind.keyword;
            }
            q.tokens ~= Token(kind, Span(start, i));
        }
        foreach (k, ref t; q.tokens)
            if (t.kind != TokenKind.comment)
                sig ~= k;
    }

    // ---- token access -------------------------------------------------

    bool atEnd() const @safe pure nothrow => at >= sig.length;

    ref Token tok() return @safe pure nothrow => q.tokens[sig[at]];

    string text() @safe pure nothrow => q.source[tok.span.start .. tok.span.end];

    bool isPunct(string p) @safe pure nothrow
        => !atEnd && tok.kind == TokenKind.punctuation && text == p;

    bool isOp(string p) @safe pure nothrow
        => !atEnd && tok.kind == TokenKind.operator && text == p;

    size_t here() @safe pure nothrow => atEnd ? q.source.length : tok.span.start;

    // A call: a word followed by `(`.
    bool isCall(string name) @safe pure nothrow
        => !atEnd && tok.kind == TokenKind.glob && text == name && at + 1 < sig.length
            && q.tokens[sig[at + 1]].kind == TokenKind.punctuation
            && q.source[q.tokens[sig[at + 1]].span.start] == '(';

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
        if (sig.length == 0)
            return; // only comments, or nothing: `none`
        const r = expr();
        if (!failed && !atEnd)
            fail("unexpected `" ~ text ~ "`", here);
        if (!failed)
            q.root = r;
    }

    uint expr() @safe pure
    {
        auto left = term();
        while (!failed && (isOp("|") || isOp("-")))
        {
            const op = text;
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
            fail("expected a glob, a keyword, a function or `(`", here);
            return noNode;
        }
        const start = here;
        if (isPunct("("))
        {
            ++at;
            const inner = expr();
            if (failed || !expect(")", "expected `)`"))
                return noNode;
            q.nodes[inner].span = Span(start, q.tokens[sig[at - 1]].span.end);
            return inner;
        }
        foreach (fn; ["unions", "intersection", "difference", "fileFilter"])
            if (isCall(fn))
                return call(fn);
        auto t = tok;
        final switch (t.kind)
        {
            case TokenKind.keyword:
                ++at;
                NodeKind k;
                switch (q.source[t.span.start .. t.span.end])
                {
                    case "all": k = NodeKind.all; break;
                    case "none": k = NodeKind.none; break;
                    case "exec": k = NodeKind.exec; break;
                    case "gitignored": k = NodeKind.gitignored; break;
                    default: k = NodeKind.gitTracked; break;
                }
                return node(QueryNode(kind: k, span: t.span));
            case TokenKind.glob:
                ++at;
                return node(QueryNode(kind: NodeKind.glob, text: q.source[t.span.start .. t.span.end],
                    span: t.span));
            case TokenKind.string_:
                string value;
                if (!unquote(t.span, value))
                    return noNode;
                ++at;
                return node(QueryNode(kind: NodeKind.glob, text: value, quoted: true, span: t.span));
            case TokenKind.operator, TokenKind.punctuation, TokenKind.function_,
                TokenKind.predicate, TokenKind.comment:
                fail("expected a glob, a keyword, a function or `(` before `"
                    ~ q.source[t.span.start .. t.span.end] ~ "`", t.span.start);
                return noNode;
        }
    }

    uint call(string fn) @safe pure
    {
        const start = here;
        tok.kind = TokenKind.function_;
        at += 2; // the name and `(`
        if (fn == "fileFilter")
        {
            const p = predicate();
            if (failed || !expect(")", "expected `)` after the predicate"))
                return noNode;
            return node(QueryNode(kind: NodeKind.fileFilter, pred: p,
                span: Span(start, q.tokens[sig[at - 1]].span.end)));
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
        const span = Span(start, q.tokens[sig[at - 1]].span.end);
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
            tok.kind = TokenKind.function_;
            at += 2;
            string ext;
            if (!stringArg(ext))
                return noNode;
            if (!expect(")", "expected `)`"))
                return noNode;
            return pred(Pred(PredKind.hasExt, ext, noNode, noNode, Span(start, q.tokens[sig[at - 1]].span.end)));
        }
        if (!atEnd && tok.kind == TokenKind.glob && (text == "name" || text == "type"))
        {
            const isName = text == "name";
            tok.kind = TokenKind.predicate;
            ++at;
            if (!isOp("=="))
            {
                fail("expected `==`", here);
                return noNode;
            }
            ++at;
            string value;
            if (!stringArg(value))
                return noNode;
            if (!isName && value != "regular" && value != "symlink")
            {
                fail("a type is \"regular\" or \"symlink\"", q.tokens[sig[at - 1]].span.start);
                return noNode;
            }
            return pred(Pred(isName ? PredKind.name : PredKind.type, value, noNode, noNode,
                Span(start, q.tokens[sig[at - 1]].span.end)));
        }
        fail("expected `hasExt(\"…\")`, `name == \"…\"`, `type == \"…\"`, `!` or `(`", here);
        return noNode;
    }

    bool stringArg(out string value) @safe pure
    {
        if (atEnd || tok.kind != TokenKind.string_)
        {
            fail("expected a string", here);
            return false;
        }
        if (!unquote(tok.span, value))
            return false;
        ++at;
        return true;
    }

    // The value of the string token at `span`: `\"` and `\\` unescaped.
    bool unquote(Span span, out string value) @safe pure
    {
        const s = q.source[span.start .. span.end];
        if (s.length < 2 || s[$ - 1] != '"' || (s.length >= 3 && s[$ - 2] == '\\' && !evenBackslashes(s[1 .. $ - 1])))
        {
            fail("a string is not closed", span.start);
            return false;
        }
        char[] v;
        const body = s[1 .. $ - 1];
        for (size_t i; i < body.length; ++i)
        {
            if (body[i] == '\\' && i + 1 < body.length && (body[i + 1] == '"' || body[i + 1] == '\\'))
                ++i;
            v ~= body[i];
        }
        value = v.idup;
        return true;
    }
}

// Whether `s` ends in an even run of backslashes: its last quote is not escaped.
private bool evenBackslashes(scope const(char)[] s) @safe pure nothrow @nogc
{
    size_t n;
    while (n < s.length && s[$ - 1 - n] == '\\')
        ++n;
    return n % 2 == 0;
}

/// FXL1–FXL3: leaves, strings, comments and operators.
@("fileset.query.lexAndParse")
@safe pure unittest
{
    auto q = parseQuery("a-b/*.d | \"#foo#\" & \"a b\" # tail\n- \"say \\\"hi\\\"\"");
    assert(q.ok, q.error.message);
    assert(q.nodes[q.root].kind == NodeKind.difference);
    string[] globs;
    foreach (ref n; q.nodes)
        if (n.kind == NodeKind.glob)
            globs ~= n.text;
    assert(globs == ["a-b/*.d", "#foo#", "a b", "say \"hi\""]);
    assert(q.tokens[$ - 3].kind == TokenKind.comment);

    assert(parseQuery("a#b").nodes[0].text == "a#b", "a # inside a glob is the glob's");
    auto c = parseQuery("a #b");
    assert(c.ok && c.nodes.length == 1 && c.nodes[0].text == "a");
    auto blank = parseQuery("# nothing\n  # at all");
    assert(blank.ok && blank.root == noNode);
    assert(parseQuery("*.{d,di}").nodes[0].text == "*.{d,di}", "a brace's comma is the glob's");
}

/// FXL3: `&` binds tighter; `|` and `-` are left-associative.
@("fileset.query.precedence")
@safe pure unittest
{
    assert(canonical(parseQuery("a | b & c - d")) == "a | b & c - d");
    assert(canonical(parseQuery("(a | b) & c")) == "(a | b) & c");
    assert(canonical(parseQuery("a - (b - c)")) == "a - (b - c)");
    assert(canonical(parseQuery("(a - b) - c")) == "a - b - c");
}

/// FXL4: function forms mean what the operators mean.
@("fileset.query.functions")
@safe pure unittest
{
    assert(canonical(parseQuery("difference(unions(a, b, c), intersection(d, e))")) == "a | b | c - d & e", "left-associative: no parentheses needed");
    assert(canonical(parseQuery("unions(a)")) == "a");
    assert(canonical(parseQuery("fileFilter(hasExt(\"d\") && !name == \"x.d\")"))
        == "fileFilter(hasExt(\"d\") && !name == \"x.d\")");
    assert(canonical(parseQuery("fileFilter((type == \"symlink\" || name == \"a\") && hasExt(\"d\"))"))
        == "fileFilter((type == \"symlink\" || name == \"a\") && hasExt(\"d\"))");
    assert(!parseQuery("fileFilter(type == \"dir\")").ok);
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
}

// ---- the canonical form (FXL7) ------------------------------------------

/// The query's canonical text: comments dropped, operators for the function
/// forms that have one, n-ary unions and intersections flattened, and
/// parentheses only where precedence needs them. `none` for an empty query.
string canonical(in Query q) @safe pure
{
    if (!q.ok)
        return null;
    if (q.root == noNode)
        return "none";
    return render(q, q.root, 0);
}

private int precedence(NodeKind k) @safe pure nothrow @nogc
    => k == NodeKind.union_ || k == NodeKind.difference ? 1 : k == NodeKind.intersection ? 2 : 3;

private string render(in Query q, uint n, int outer) @safe pure
{
    const node = q.nodes[n];
    const prec = precedence(node.kind);
    string s;
    final switch (node.kind)
    {
        case NodeKind.glob: s = globText(node.text); break;
        case NodeKind.all: s = "all"; break;
        case NodeKind.none: s = "none"; break;
        case NodeKind.exec: s = "exec"; break;
        case NodeKind.gitignored: s = "gitignored"; break;
        case NodeKind.gitTracked: s = "gitTracked"; break;
        case NodeKind.union_, NodeKind.intersection:
            const op = node.kind == NodeKind.union_ ? " | " : " & ";
            foreach (i, a; flatten(q, n, node.kind))
                s ~= (i ? op : "") ~ render(q, a, node.kind == NodeKind.union_ ? 1 : 2);
            break;
        case NodeKind.difference:
            // Left-associative: a difference on the right needs parentheses.
            s = render(q, node.args[0], 1) ~ " - " ~ render(q, node.args[1], 2);
            break;
        case NodeKind.fileFilter:
            s = "fileFilter(" ~ renderPred(q, node.pred, 0) ~ ")";
            break;
    }
    return prec < outer ? "(" ~ s ~ ")" : s;
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
    final switch (pr.kind)
    {
        case PredKind.hasExt: prec = 3; s = "hasExt(" ~ quote(pr.value) ~ ")"; break;
        case PredKind.name: prec = 3; s = "name == " ~ quote(pr.value); break;
        case PredKind.type: prec = 3; s = "type == " ~ quote(pr.value); break;
        case PredKind.not: prec = 3; s = "!" ~ renderPred(q, pr.a, 3); break;
        case PredKind.and: prec = 2; s = renderPred(q, pr.a, 2) ~ " && " ~ renderPred(q, pr.b, 2); break;
        case PredKind.or: prec = 1; s = renderPred(q, pr.a, 1) ~ " || " ~ renderPred(q, pr.b, 1); break;
    }
    return prec < outer ? "(" ~ s ~ ")" : s;
}

/// `s` as a string literal: quoted, with `"` and `\` escaped.
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

/// A glob as the query writes it: bare when the lexer reads it back as one
/// glob, else as a string.
string globText(string g) @safe pure
{
    auto back = parseQuery(g);
    if (back.ok && back.nodes.length == 1 && back.nodes[0].kind == NodeKind.glob && !back.nodes[0].quoted
        && back.tokens.length == 1)
        return g;
    return quote(g);
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
beneath the fileset root for `gitTracked`, or returns `null` when the root is
not in a git work tree, which fails the query (`FXL5`); it is called at most
once, and only when `q` uses `gitTracked`.
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
                const pattern = pr.kind == PredKind.hasExt ? "*." ~ escapeGlob(pr.value) : escapeGlob(pr.value);
                auto g = sets.fileName(pattern);
                if (g.hasError)
                {
                    err = QueryError(g.error.context, pr.span.start);
                    return false;
                }
                f = g.value;
                return true;
            case PredKind.type:
                f = pr.value == "symlink" ? sets.symlinks : sets.difference(sets.everything, sets.symlinks);
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
                    err = QueryError(g.error.context, node.span.start + (node.quoted ? 1 : 0) + g.error.offset);
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
    foreach (i, c; s)
    {
        if (c == '*' || c == '?' || c == '[' || c == ']' || c == '{' || c == '}' || c == '\\'
            || (i == 0 && c == '!'))
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

/// FXL5: `gitTracked` is the index beneath the root, and a plain directory
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
    assert(has("fileFilter(hasExt(\"d\") && !name == \"x.d\")", "q/y.d"));
    assert(!has("fileFilter(hasExt(\"d\") && !name == \"x.d\")", "q/x.d"));
    assert(has("fileFilter(name == \"a*b\")", "a*b") && !has("fileFilter(name == \"a*b\")", "aXb"),
        "a name is literal");
    assert(has("gitTracked & *.d", "src/t.d") && !has("gitTracked", "b.d"));

    auto none = compileQuery(parseQuery("gitTracked"), sets, () => cast(string[]) null);
    assert(!none.ok && none.error.message == "not a git work tree");
    auto bad = compileQuery(parseQuery("a | \"[b\""), sets, null);
    assert(!bad.ok && bad.error.offset >= 5, bad.error.message);
}

/// FXL7: the canonical form parses to the same tree's text again.
@("fileset.query.canonicalRoundTrips")
@safe pure unittest
{
    foreach (s; ["a | b & c - d", "(a | b) & c", "a - (b - c)", "\"a b\" | \"#x\" | \"|\"",
        "fileFilter(!(hasExt(\"d\") || type == \"symlink\"))", "all - gitignored", "*.{d,di}"])
    {
        const once = canonical(parseQuery(s));
        assert(once.length, s);
        assert(canonical(parseQuery(once)) == once, once);
    }
    assert(globText("|") == "\"|\"" && globText("all") == "\"all\"" && globText("a b") == "\"a b\"");
    assert(globText("src/**") == "src/**");
}
