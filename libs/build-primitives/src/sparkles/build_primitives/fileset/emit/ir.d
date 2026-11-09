/**
The generators' common form (fileset explorer `FXE1`, `FXE2`): a query lowered
to an expression over leaves, normalized by meaning-preserving rules, and its
globs taken apart into what each target's pattern syntax needs.
*/
module sparkles.build_primitives.fileset.emit.ir;

import sparkles.build_primitives.fileset.query : NodeKind, noNode, PredKind, Query, Span;

/// A node of the lowered expression.
enum E : ubyte
{
    glob,         /// `text` is the glob
    fileName,     /// `text` is a one-segment glob over a file's own name
    symlinks,     ///
    all,          ///
    none,         ///
    exec,         ///
    gitignored,   ///
    gitTracked,   ///
    union_,       /// over `args`, flattened
    intersection, /// over `args`, flattened
    difference,   /// `args[0]` minus `args[1]`
}

/// The lowered expression.
struct Expr
{
    E kind;       ///
    string text;  /// a glob's or a file name's pattern
    Span span;    /// the query bytes it came from
    Expr[] args;  ///
}

/// Whether `e` is a leaf.
bool isLeaf(in Expr e) @safe pure nothrow @nogc => e.kind < E.union_;

/// `q`, lowered: `fileFilter` predicates become `fileName`, `symlinks` and
/// the algebra over them. `q` must have parsed.
Expr lower(const Query q) @safe pure
in (q.ok)
{
    import sparkles.build_primitives.fileset.query : escapeGlob;

    if (q.root == noNode)
        return Expr(E.none);

    Expr pred(uint p)
    {
        const pr = q.preds[p];
        final switch (pr.kind)
        {
            case PredKind.hasExt: return Expr(E.fileName, "*." ~ escapeGlob(pr.value), pr.span);
            case PredKind.name: return Expr(E.fileName, escapeGlob(pr.value), pr.span);
            case PredKind.type:
                return pr.value == "symlink" ? Expr(E.symlinks, null, pr.span)
                    : Expr(E.difference, null, pr.span, [Expr(E.all), Expr(E.symlinks)]);
            case PredKind.not: return Expr(E.difference, null, pr.span, [Expr(E.all), pred(pr.a)]);
            case PredKind.and: return Expr(E.intersection, null, pr.span, [pred(pr.a), pred(pr.b)]);
            case PredKind.or: return Expr(E.union_, null, pr.span, [pred(pr.a), pred(pr.b)]);
        }
    }

    Expr walk(uint n)
    {
        const node = q.nodes[n];
        final switch (node.kind)
        {
            case NodeKind.glob: return Expr(E.glob, node.text, node.span);
            case NodeKind.all: return Expr(E.all, null, node.span);
            case NodeKind.none: return Expr(E.none, null, node.span);
            case NodeKind.exec: return Expr(E.exec, null, node.span);
            case NodeKind.gitignored: return Expr(E.gitignored, null, node.span);
            case NodeKind.gitTracked: return Expr(E.gitTracked, null, node.span);
            case NodeKind.fileFilter: return pred(node.pred);
            case NodeKind.union_, NodeKind.intersection, NodeKind.difference:
                Expr[] args;
                foreach (a; node.args)
                    args ~= walk(a);
                const k = node.kind == NodeKind.union_ ? E.union_
                    : node.kind == NodeKind.intersection ? E.intersection : E.difference;
                if (k == E.difference)
                    return Expr(k, null, node.span, args[0 .. 2]);
                return Expr(k, null, node.span, args);
        }
    }

    return walk(q.root);
}

/**
`e`, normalized by rules that keep its meaning (`FXE2`): unions and
intersections flattened; `none` and `all` simplified away where they are
units or zeros; `a - (b | c)` into `(a - b) - c`; an intersection of a literal
anchored directory glob `d/**` and an unanchored glob `g` into `d/**` `/g`.
*/
Expr normalize(Expr e) @safe pure
{
    if (e.isLeaf)
        return e;
    foreach (ref a; e.args)
        a = normalize(a);

    final switch (e.kind)
    {
        case E.union_:
        {
            Expr[] flat;
            foreach (a; e.args)
            {
                if (a.kind == E.all)
                    return a;
                if (a.kind == E.none)
                    continue;
                flat ~= a.kind == E.union_ ? a.args : [a];
            }
            if (flat.length == 0)
                return Expr(E.none, null, e.span);
            if (flat.length == 1)
                return flat[0];
            e.args = flat;
            return e;
        }
        case E.intersection:
        {
            Expr[] flat;
            foreach (a; e.args)
            {
                if (a.kind == E.none)
                    return a;
                if (a.kind == E.all)
                    continue;
                flat ~= a.kind == E.intersection ? a.args : [a];
            }
            if (flat.length == 0)
                return Expr(E.all, null, e.span);
            // A literal directory and an unanchored glob: one glob beneath it.
            foreach (i, d; flat)
            {
                const dir = literalDirGlob(d);
                if (dir is null)
                    continue;
                foreach (j, g; flat)
                    if (j != i && g.kind == E.glob && !parseGlob(g.text).anchored && !parseGlob(g.text).dirOnly)
                    {
                        auto merged = Expr(E.glob, dir ~ "/**/" ~ g.text, e.span);
                        Expr[] rest;
                        foreach (k, x; flat)
                            if (k != i && k != j)
                                rest ~= x;
                        return normalize(rest.length ? Expr(E.intersection, null, e.span, merged ~ rest) : merged);
                    }
            }
            if (flat.length == 1)
                return flat[0];
            e.args = flat;
            return e;
        }
        case E.difference:
        {
            auto a = e.args[0], b = e.args[1];
            if (a.kind == E.none || b.kind == E.all)
                return Expr(E.none, null, e.span);
            if (b.kind == E.none)
                return a;
            // a - (b1 | b2 | …) = ((a - b1) - b2) - …
            if (b.kind == E.union_)
            {
                Expr acc = a;
                foreach (x; b.args)
                    acc = Expr(E.difference, null, e.span, [acc, x]);
                return acc;
            }
            return e;
        }
        case E.glob, E.fileName, E.symlinks, E.all, E.none, E.exec, E.gitignored, E.gitTracked:
            assert(0);
    }
}

// The directory of a glob `d/**` or `/d/**` whose `d` has no metacharacter.
private string literalDirGlob(Expr e) @safe pure
{
    if (e.kind != E.glob)
        return null;
    const g = parseGlob(e.text);
    if (!g.anchored || g.dirOnly || g.body.length < 4 || g.body[$ - 3 .. $] != "/**")
        return null;
    const dir = g.body[0 .. $ - 3];
    foreach (c; dir)
        if (c == '*' || c == '?' || c == '[' || c == '{' || c == '\\')
            return null;
    return dir;
}

/// A glob taken apart (`FSG1`'s anchoring rule).
struct GlobParts
{
    bool anchored; /// it contains `/` before its last character, or starts with one
    bool dirOnly;  /// it ends in `/`: directories only
    string body;   /// without the leading or trailing `/`
}

/// Takes `glob` apart.
GlobParts parseGlob(string glob) @safe pure nothrow
{
    GlobParts g;
    string s = glob;
    if (s.length && s[0] == '/')
    {
        g.anchored = true;
        s = s[1 .. $];
    }
    if (s.length > 1 && s[$ - 1] == '/')
    {
        g.dirOnly = true;
        s = s[0 .. $ - 1];
    }
    foreach (i, c; s)
        if (c == '/')
            g.anchored = true;
    g.body = s;
    return g;
}

/// The globs `glob`'s brace alternatives stand for, in order: `a{b,c}d` is
/// `abd` and `acd`. A brace inside a bracket or after `\` is literal.
string[] expandBraces(string glob) @safe pure
{
    // The first top-level `{` with a matching `}`.
    size_t open = size_t.max;
    int depth;
    bool inClass;
    size_t[] commas;
    for (size_t i; i < glob.length; ++i)
    {
        const c = glob[i];
        if (c == '\\')
        {
            ++i;
            continue;
        }
        if (inClass)
        {
            if (c == ']')
                inClass = false;
            continue;
        }
        if (c == '[')
            inClass = true;
        else if (c == '{')
        {
            if (depth++ == 0)
            {
                open = i;
                commas = null;
            }
        }
        else if (c == ',' && depth == 1)
            commas ~= i;
        else if (c == '}' && depth > 0 && --depth == 0)
        {
            string[] out_;
            size_t from = open + 1;
            foreach (cut; commas ~ i)
            {
                out_ ~= expandBraces(glob[0 .. open] ~ glob[from .. cut] ~ glob[i + 1 .. $]);
                from = cut + 1;
            }
            return out_;
        }
    }
    return [glob];
}

/// Whether `glob` has a character class.
bool hasClass(string glob) @safe pure nothrow @nogc
{
    for (size_t i; i < glob.length; ++i)
        if (glob[i] == '\\')
            ++i;
        else if (glob[i] == '[')
            return true;
    return false;
}

/// Whether `glob` has any metacharacter: `*`, `?`, `[`, `{`.
bool isLiteral(string glob) @safe pure nothrow @nogc
{
    foreach (c; glob)
        if (c == '*' || c == '?' || c == '[' || c == '{' || c == '\\')
            return false;
    return true;
}

///
@("fileset.emit.ir.globs")
@safe pure unittest
{
    assert(parseGlob("*.d") == GlobParts(false, false, "*.d"));
    assert(parseGlob("/README.md") == GlobParts(true, false, "README.md"));
    assert(parseGlob("src/*.d") == GlobParts(true, false, "src/*.d"));
    assert(parseGlob("build/") == GlobParts(false, true, "build"));
    assert(expandBraces("*.{d,di}") == ["*.d", "*.di"]);
    assert(expandBraces("{a,{b,c}}/x") == ["a/x", "b/x", "c/x"]);
    assert(expandBraces("[{]x") == ["[{]x"] && expandBraces("\\{a,b}") == ["\\{a,b}"]);
    assert(hasClass("a[bc]") && !hasClass("a\\[b") && isLiteral("src/a.d") && !isLiteral("*.d"));
}

///
@("fileset.emit.ir.normalize")
@safe pure unittest
{
    import sparkles.build_primitives.fileset.query : parseQuery;

    string shape(string q)
    {
        string show(in Expr e)
        {
            final switch (e.kind)
            {
                case E.glob: return e.text;
                case E.fileName: return "name(" ~ e.text ~ ")";
                case E.symlinks: return "links";
                case E.all: return "all";
                case E.none: return "none";
                case E.exec: return "exec";
                case E.gitignored: return "gitignored";
                case E.gitTracked: return "gitTracked";
                case E.union_, E.intersection, E.difference:
                    string s = "(";
                    foreach (i, a; e.args)
                        s ~= (i ? (e.kind == E.union_ ? " | " : e.kind == E.intersection ? " & " : " - ") : "")
                            ~ show(a);
                    return s ~ ")";
            }
        }

        return show(normalize(lower(parseQuery(q))));
    }

    assert(shape("a | (b | c) | none") == "(a | b | c)");
    assert(shape("a - (b | c)") == "((a - b) - c)");
    assert(shape("a & all & (b & c)") == "(a & b & c)");
    assert(shape("src/** & *.d") == "src/**/*.d");
    assert(shape("none - a | all & b") == "b");
    assert(shape("fileFilter(hasExt(\"d\") && !name == \"x.d\")") == "(name(*.d) & (all - name(x.d)))");
}
