/**
The targets that take lists of patterns (fileset explorer `FXE4`–`FXE10`).

Each accepts as much of the normalized query as it can express exactly, and
refuses the rest, naming the construct (`FXE1`, decision X7):

$(UL
$(LI `rsync` and `gitignore` take a $(I decision list): a union with a glob
    adds an include ahead of the rest, a difference with a glob an exclude.
    rsync matches first to last, a `.gitignore` last to first.)
$(LI `git-pathspec` and `bazel` take an include set minus an exclude set.)
$(LI `tar` takes literal paths to archive, minus excluded globs.)
$(LI `cargo` takes a union, which must keep `Cargo.toml`.)
$(LI `dub` writes the members out: its own globs list directories as source
    files, so no dub glob is exact.)
)
*/
module sparkles.build_primitives.fileset.emit.lists;

import std.array : join;

import sparkles.build_primitives.fileset.emit.ir : E, expandBraces, Expr, hasClass, isLiteral, lower,
    normalize, parseGlob;
import sparkles.build_primitives.fileset.emit.result : EmitOptions, Emitted, refuse, Target;
import sparkles.build_primitives.fileset.query : canonical, Query, Span;

/// One rule of a decision list: include or exclude what `e` (a leaf) selects.
struct Rule
{
    bool include; ///
    Expr leaf;    /// a `glob`, `fileName` or `all`
}

// Whether `e` is a union of patterns a list target can name.
private bool globlike(in Expr e) @safe pure nothrow
{
    if (e.kind == E.glob || e.kind == E.fileName || e.kind == E.all)
        return true;
    if (e.kind != E.union_)
        return false;
    foreach (a; e.args)
        if (!globlike(a))
            return false;
    return true;
}

// The leaves of a globlike union.
private Expr[] leavesOf(Expr e) @safe pure
{
    if (e.kind != E.union_)
        return [e];
    Expr[] out_;
    foreach (a; e.args)
        out_ ~= leavesOf(a);
    return out_;
}

/// The decision list of `e`, first match first, or the node it cannot hold.
bool decisionList(Expr e, out Rule[] rules, out Expr refused) @safe pure
{
    final switch (e.kind)
    {
        case E.glob, E.fileName, E.all:
            rules = [Rule(true, e)];
            return true;
        case E.none:
            return true;
        case E.union_:
        {
            Expr compound;
            bool haveCompound;
            Rule[] front;
            foreach (a; e.args)
                if (globlike(a))
                    foreach (l; leavesOf(a))
                        front ~= Rule(true, l);
                else if (!haveCompound)
                {
                    compound = a;
                    haveCompound = true;
                }
                else
                {
                    refused = a; // two compound operands: their rules would shadow each other
                    return false;
                }
            Rule[] rest;
            if (haveCompound && !decisionList(compound, rest, refused))
                return false;
            rules = front ~ rest;
            return true;
        }
        case E.difference:
        {
            if (!globlike(e.args[1]))
            {
                refused = e.args[1];
                return false;
            }
            Rule[] rest;
            if (!decisionList(e.args[0], rest, refused))
                return false;
            Rule[] front;
            foreach (l; leavesOf(e.args[1]))
                front ~= Rule(false, l);
            rules = front ~ rest;
            return true;
        }
        case E.intersection, E.symlinks, E.exec, E.gitignored, E.gitTracked:
            refused = e;
            return false;
    }
}

/// An include set minus an exclude set, and whether to keep only tracked files.
struct Sets
{
    Expr[] include; ///
    Expr[] exclude; ///
    bool trackedOnly; /// `gitTracked & …`
    bool everything;  /// the include set is `all`
}

/// `e` as an include set minus an exclude set, or the node it cannot hold.
bool includeExclude(Expr e, out Sets s, out Expr refused, bool allowTracked) @safe pure
{
    if (e.kind == E.intersection && allowTracked)
    {
        Expr[] rest;
        foreach (a; e.args)
            if (a.kind == E.gitTracked)
                s.trackedOnly = true;
            else
                rest ~= a;
        if (s.trackedOnly)
        {
            if (rest.length == 0)
                return true;
            if (rest.length > 1)
            {
                refused = e;
                return false;
            }
            Sets inner;
            if (!includeExclude(rest[0], inner, refused, false))
                return false;
            inner.trackedOnly = true;
            s = inner;
            return true;
        }
    }
    if (e.kind == E.gitTracked && allowTracked)
    {
        s.trackedOnly = true;
        return true;
    }
    if (e.kind == E.none)
        return true;
    if (e.kind == E.difference)
    {
        if (!globlike(e.args[1]))
        {
            refused = e.args[1];
            return false;
        }
        if (!includeExclude(e.args[0], s, refused, allowTracked))
            return false;
        s.exclude ~= leavesOf(e.args[1]);
        return true;
    }
    if (!globlike(e))
    {
        refused = e;
        return false;
    }
    foreach (l; leavesOf(e))
        if (l.kind == E.all)
            s.everything = true;
        else
            s.include ~= l;
    return true;
}

private string header(string comment, const Query q) @safe pure
    => comment ~ " Generated by fileset-explorer from: " ~ canonical(q) ~ "\n";

private Emitted refusedAt(Expr e, string what) @safe pure
{
    import std.conv : text;

    const name = e.kind == E.glob ? "the glob `" ~ e.text ~ "`" : e.kind == E.fileName ? "`fileFilter` by name"
        : e.kind == E.intersection ? "an intersection" : e.kind == E.difference ? "a difference"
        : e.kind == E.union_ ? "a union" : e.kind == E.symlinks ? "`fileFilter` by type"
        : text("`", e.kind, "`");
    return refuse(what ~ " cannot express " ~ name, e.span);
}

// ---- patterns ------------------------------------------------------------

// Every variant of `body` with each `**` segment kept or dropped: rsync's
// `**` matches at least the slashes around it, where ours matches none.
private string[] globstarVariants(string body) @safe pure
{
    import std.algorithm.iteration : splitter;

    string[][] acc = [[]];
    foreach (seg; body.splitter('/'))
    {
        string[][] next;
        foreach (a; acc)
        {
            next ~= a ~ seg;
            if (seg == "**")
                next ~= a;
        }
        acc = next;
    }
    string[] out_;
    foreach (a; acc)
        if (a.length)
            out_ ~= a.join("/");
    return out_;
}

// A `.gitignore` or rsync line's text: escape what starts a comment or a
// negation, and a trailing space.
private string lineSafe(string p) @safe pure
{
    if (p.length && (p[0] == '#' || p[0] == '!'))
        p = "\\" ~ p;
    if (p.length && p[$ - 1] == ' ')
        p = p[0 .. $ - 1] ~ "\\ ";
    return p;
}

/**
The wildmatch patterns (`.gitignore`, rsync) that select what a leaf
selects: for a glob, the path itself and everything beneath it; for a file
name, the name alone (a directory is let through elsewhere).
*/
private string[] wildPatterns(Expr leaf, bool rsync) @safe pure
{
    if (leaf.kind == E.all)
        return ["*"];
    if (leaf.kind == E.fileName)
        return [lineSafe(leaf.text)];
    string[] out_;
    foreach (one; expandBraces(leaf.text))
    {
        const g = parseGlob(one);
        foreach (body; rsync ? globstarVariants(g.body) : [g.body])
        {
            const at = g.anchored ? "/" ~ body : body;
            const beneath = g.anchored ? "/" ~ body ~ "/**" : "**/" ~ body ~ "/**";
            if (!g.dirOnly)
                out_ ~= lineSafe(at);
            out_ ~= lineSafe(rsync && !g.anchored ? body ~ "/**" : beneath);
        }
    }
    return out_;
}

// ---- the targets -----------------------------------------------------------

/// The `rsync` target (`FXE6`): a filter file, first match first.
Emitted emitRsync(const Query q, in EmitOptions o) @safe pure
{
    Rule[] rules;
    Expr refused;
    if (!decisionList(normalize(lower(q)), rules, refused))
        return refusedAt(refused, "rsync's first-match filter list");
    string s = header("#", q) ~ "# rsync -r --prune-empty-dirs --filter='merge THIS_FILE' SRC/ DEST/\n";
    s ~= "+ */\n"; // every directory is entered; --prune-empty-dirs drops the empty ones
    foreach (r; rules)
        foreach (p; wildPatterns(r.leaf, true))
            s ~= (r.include ? "+ " : "- ") ~ p ~ "\n";
    return Emitted(true, s ~ "- *\n");
}

/// The `gitignore` target (`FXE5`): what to leave unignored, last match wins.
Emitted emitGitignore(const Query q, in EmitOptions o) @safe pure
{
    Rule[] rules;
    Expr refused;
    if (!decisionList(normalize(lower(q)), rules, refused))
        return refusedAt(refused, "a .gitignore's rule list");
    string s = header("#", q) ~ "# Everything is ignored but the fileset's members.\n*\n";
    foreach_reverse (r; rules)
        foreach (p; wildPatterns(r.leaf, false))
            s ~= (r.include ? "!" : "") ~ p ~ "\n";
    return Emitted(true, s ~ "# Directories stay open, so a file beneath one can be kept.\n!*/\n");
}

/// The `git-pathspec` target (`FXE4`): `git ls-files` with glob pathspecs.
Emitted emitGitPathspec(const Query q, in EmitOptions o) @safe pure
{
    Sets s;
    Expr refused;
    if (!includeExclude(normalize(lower(q)), s, refused, true))
        return refusedAt(refused, "a pathspec list");
    string[] args;
    foreach (l; s.include)
    {
        if (l.kind == E.fileName)
            return refusedAt(l, "a pathspec, which also matches a directory's contents,");
        foreach (p; pathspecPatterns(l))
            args ~= shellQuote(":(glob)" ~ p);
    }
    // git matches an exclude against paths shorn of the includes' common
    // directory: an unanchored exclude must carry that directory, which every
    // included path has, so it means the same.
    const common = s.everything || s.trackedOnly ? "" : commonDirectory(s.include);
    foreach (l; s.exclude)
    {
        if (l.kind == E.fileName)
            return refusedAt(l, "a pathspec, which also matches a directory's contents,");
        foreach (p; pathspecPatterns(l, common))
            args ~= shellQuote(":(exclude,glob)" ~ p);
    }
    if (!s.everything && s.include.length == 0 && !s.trackedOnly)
        args = [shellQuote(":(exclude,glob)**")]; // nothing
    return Emitted(true, header("#", q) ~ "git ls-files " ~ (s.trackedOnly ? "--cached" : "--cached --others")
        ~ " -- " ~ args.join(" ") ~ "\n");
}

// The literal leading directory every include's glob starts with, `"a/b/"`,
// or empty.
private string commonDirectory(in Expr[] include) @safe pure
{
    import std.algorithm.iteration : splitter;

    string common;
    foreach (i, l; include)
    {
        if (l.kind != E.glob)
            return "";
        const g = parseGlob(l.text);
        if (!g.anchored)
            return "";
        string dir;
        string[] segs;
        foreach (seg; g.body.splitter('/'))
            segs ~= seg;
        foreach (seg; segs[0 .. $ - 1])
        {
            if (!isLiteral(seg))
                break;
            dir ~= seg ~ "/";
        }
        if (i == 0)
            common = dir;
        else
        {
            size_t n;
            while (n < common.length && n < dir.length && common[n] == dir[n])
                ++n;
            while (n > 0 && common[n - 1] != '/')
                --n;
            common = common[0 .. n];
        }
    }
    return common;
}

private string[] pathspecPatterns(Expr leaf, string common = "") @safe pure
{
    string[] out_;
    foreach (one; expandBraces(leaf.text))
    {
        const g = parseGlob(one);
        // A leading `**` floats like an unanchored glob, so it takes the prefix too.
        const at = !g.anchored ? common ~ "**/" ~ g.body
            : g.body.length >= 2 && g.body[0 .. 2] == "**" ? common ~ g.body : g.body;
        if (!g.dirOnly)
            out_ ~= at;
        out_ ~= at ~ "/**";
    }
    return out_;
}

/// The `bazel` target (`FXE9`): a `glob` over one package.
Emitted emitBazel(const Query q, in EmitOptions o) @safe pure
{
    Sets s;
    Expr refused;
    if (!includeExclude(normalize(lower(q)), s, refused, false))
        return refusedAt(refused, "Bazel's glob");
    string[] inc, exc;
    if (s.everything)
        inc ~= "**";
    foreach (l; s.include)
    {
        if (l.kind == E.glob && (hasClass(l.text) || hasQuestion(l.text)))
            return refusedAt(l, "Bazel's glob, which has only `*` and `**`,");
        inc ~= bazelPatterns(l);
    }
    foreach (l; s.exclude)
    {
        if (l.kind == E.glob && (hasClass(l.text) || hasQuestion(l.text)))
            return refusedAt(l, "Bazel's glob, which has only `*` and `**`,");
        exc ~= bazelPatterns(l);
    }
    string list(string[] ps)
    {
        string r = "[\n";
        foreach (p; ps)
            r ~= "        " ~ starlarkString(p) ~ ",\n";
        return r ~ "    ]";
    }

    return Emitted(true, header("#", q) ~ "# The root must be one Bazel package: no BUILD file beneath it.\n"
        ~ "glob(\n    include = " ~ list(inc) ~ ",\n    exclude = " ~ list(exc)
        ~ ",\n    exclude_directories = 1,\n    allow_empty = True,\n)\n");
}

private bool hasQuestion(string glob) @safe pure nothrow @nogc
{
    for (size_t i; i < glob.length; ++i)
        if (glob[i] == '\\')
            ++i;
        else if (glob[i] == '?')
            return true;
    return false;
}

private string[] bazelPatterns(Expr leaf) @safe pure
{
    if (leaf.kind == E.fileName)
        return ["**/" ~ leaf.text]; // a file by its name: Bazel matches whole file paths
    string[] out_;
    foreach (one; expandBraces(leaf.text))
    {
        const g = parseGlob(one);
        const at = g.anchored ? g.body : "**/" ~ g.body;
        if (!g.dirOnly)
            out_ ~= at;
        out_ ~= at ~ "/**";
    }
    return out_;
}

/// The `tar` target (`FXE7`): literal paths to archive, minus excluded globs.
Emitted emitTar(const Query q, in EmitOptions o) @safe pure
{
    Sets s;
    Expr refused;
    if (!includeExclude(normalize(lower(q)), s, refused, false))
        return refusedAt(refused, "tar's paths and exclusions");
    string[] paths;
    if (s.everything)
        paths = ["."];
    foreach (l; s.include)
    {
        if (l.kind != E.glob)
            return refusedAt(l, "tar, which archives named paths,");
        const g = parseGlob(l.text);
        string body = g.body;
        if (body.length > 3 && body[$ - 3 .. $] == "/**")
            body = body[0 .. $ - 3];
        if (!g.anchored || g.dirOnly || !isLiteral(body))
            return refusedAt(l, "tar, which archives literal paths,");
        paths ~= shellQuote(body);
    }
    if (paths.length == 0)
        return refuse("tar archives nothing for an empty fileset", Span(0, 0));
    const prefix = s.everything ? "./" : "";
    string[] opts;
    foreach (l; s.exclude)
    {
        if (l.kind != E.glob)
            return refusedAt(l, "tar's --exclude, which matches directories too,");
        foreach (one; expandBraces(l.text))
        {
            const g = parseGlob(one);
            string body = g.body;
            if (body.length > 3 && body[$ - 3 .. $] == "/**")
                body = body[0 .. $ - 3];
            foreach (seg; splitPath(body))
                if (seg == "**")
                    return refusedAt(l, "tar's --exclude, which has no `**`,");
            if (g.dirOnly)
                return refusedAt(l, "tar's --exclude, which cannot tell a directory from a file,");
            opts ~= (g.anchored ? "--anchored " : "--no-anchored ")
                ~ shellQuote("--exclude=" ~ (g.anchored ? prefix : "") ~ body);
        }
    }
    return Emitted(true, header("#", q) ~ "tar -cf archive.tar --wildcards --no-wildcards-match-slash "
        ~ (opts.length ? opts.join(" ") ~ " " : "") ~ "-- " ~ paths.join(" ") ~ "\n");
}

private string[] splitPath(string p) @safe pure
{
    import std.algorithm.iteration : splitter;
    import std.array : array;

    return p.splitter('/').array;
}

/// The `cargo` target (`FXE8`): `[package] include`.
Emitted emitCargo(const Query q, in EmitOptions o) @safe
{
    Sets s;
    Expr refused;
    auto e = normalize(lower(q));
    if (!includeExclude(e, s, refused, false))
        return refusedAt(refused, "Cargo's include list");
    if (s.exclude.length)
        return refusedAt(s.exclude[0], "Cargo, which ignores `exclude` beside `include`,");
    string[] ps;
    if (s.everything)
        ps ~= "*";
    foreach (l; s.include)
    {
        if (l.kind == E.fileName)
            return refusedAt(l, "Cargo's include, which also matches a directory's contents,");
        foreach (one; expandBraces(l.text))
        {
            const g = parseGlob(one);
            ps ~= g.anchored ? "/" ~ g.body ~ (g.dirOnly ? "/" : "") : g.body ~ (g.dirOnly ? "/" : "");
        }
    }
    foreach (always; o.cargoAlways)
        if (!s.everything && !holds(s.include, always))
            return refuse("Cargo always packages `" ~ always ~ "`, which the fileset leaves out", e.span);
    string r = header("#", q) ~ "[package]\ninclude = [\n";
    foreach (p; ps)
        r ~= "    " ~ starlarkString(p) ~ ",\n";
    return Emitted(true, r ~ "]\n");
}

// Whether a union of globs holds the root file `path`.
private bool holds(in Expr[] include, string path) @safe
{
    import sparkles.build_primitives.fileset.pattern : CasePolicy;
    import sparkles.build_primitives.fileset.value : FilesetEvaluator, Filesets;

    auto sets = Filesets(CasePolicy.sensitive);
    foreach (l; include)
    {
        auto g = sets.glob(l.text);
        if (g.hasError)
            continue;
        auto ev = FilesetEvaluator(sets, g.value);
        if (ev.contains(sets, path))
            return true;
    }
    return false;
}

/// The `dub` target (`FXE10`): the members, as `sourceFiles`.
Emitted emitDub(const Query q, in EmitOptions o) @safe pure
{
    import std.path : extension;

    // dub hands these to the linker, not the compiler: they are no source file.
    foreach (m; o.members)
        switch (extension(m))
        {
            case ".o", ".obj", ".a", ".lib", ".so", ".dylib", ".dll", ".res", ".def":
                return refuse("dub passes `" ~ m ~ "` to the linker, not as a source file", Span(0, q.source.length));
            default:
                break;
        }
    string r = header("#", q) ~ "# A snapshot of the members: dub's globs list directories as source\n"
        ~ "# files, so no dub glob is exact.\nsourcePaths\nimportPaths\nsourceFiles";
    foreach (m; o.members)
        r ~= " " ~ starlarkString(m);
    return Emitted(true, r ~ "\n");
}

/// `s` as a POSIX shell word.
string shellQuote(scope const(char)[] s) @safe pure
{
    string r = "'";
    foreach (c; s)
        r ~= c == '\'' ? "'\\''" : [c];
    return r ~ "'";
}

/// `s` as a double-quoted string (Starlark, TOML basic strings, SDLang).
string starlarkString(scope const(char)[] s) @safe pure
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
