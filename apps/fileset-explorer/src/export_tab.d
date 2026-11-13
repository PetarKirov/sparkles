/**
The Export tab and `--emit` (`FXE11`, `FXE12`): the query written for another
system, or why that system cannot express it.

What a generator needs to know beyond the query comes from the open root
here: its members (dub's snapshot, Nix's), the files Cargo packages anyway,
and whether `gitignored` is the root minus `gitTracked`.
*/
module export_tab;

import std.algorithm.iteration : splitter;
import std.conv : text;

import sparkles.build_primitives.fileset.emit : emit, EmitOptions, Emitted, NixGlobs, Target, targetName;
import sparkles.build_primitives.fileset.query : globText, Query;
import sparkles.ui.style : Slot;
import sparkles.ui.widget : TextSpan;

import sparkles.fileset_tools.evaluate : evaluate, Outcome, Root;

/// The targets in the order the tab cycles them.
immutable Target[] targets = [Target.nix, Target.gitPathspec, Target.gitignore, Target.rsync, Target.tar,
    Target.cargo, Target.bazel, Target.dub];

/// The target `name` names (`--emit`), or false.
bool targetNamed(string name, out Target t) @safe pure nothrow
{
    foreach (x; targets)
        if (targetName(x) == name)
        {
            t = x;
            return true;
        }
    return false;
}

/// The glob mode `name` names (`--nix-globs`), or false.
bool nixGlobsNamed(string name, out NixGlobs m) @safe pure nothrow
{
    switch (name)
    {
        case "shim": m = NixGlobs.shim; return true;
        case "expand": m = NixGlobs.expand; return true;
        case "refuse": m = NixGlobs.refuse; return true;
        default: return false;
    }
}

/// `q`, whose resolution under `root` is `o`, written for `t`.
Emitted exportFor(Target t, NixGlobs mode, in Root root, const Query q, const Outcome o)
{
    EmitOptions opt;
    opt.nixGlobs = mode;
    string[] members;
    foreach (ref m; o.found.members)
        members ~= m.path;
    opt.members = members;
    const r = root;
    opt.expand = (string glob) @trusted {
        string[] paths;
        foreach (ref m; evaluate(r, globText(glob)).found.members)
            paths ~= m.path;
        return paths;
    };
    if (t == Target.cargo)
        foreach (ref m; evaluate(root, "Cargo.toml | README.md | README.txt | README").found.members)
            opt.cargoAlways ~= m.path;
    if (t == Target.nix && !root.inMemory)
        opt.gitignoredIsUntracked = gitignoredIsUntracked(root.dir);
    return emit(t, q, opt);
}

/**
`fileset-explorer emit` (`FXE11`): `query` beneath `dir` written for the
target `targetName_`. Returns the exit status: 0 with the code in `output`;
2 with the refusal in `error`; 1 for a bad argument or a query that does not
resolve.
*/
int emitCommand(string dir, string query, string targetName_, string globMode, out string output,
    out string error)
{
    Target t;
    if (!targetNamed(targetName_, t))
    {
        error = "emit takes nix, git-pathspec, gitignore, rsync, tar, cargo, bazel or dub\n";
        return 1;
    }
    NixGlobs mode;
    if (!nixGlobsNamed(globMode, mode))
    {
        error = "--nix-globs takes shim, expand or refuse\n";
        return 1;
    }
    const root = Root(dir: dir);
    const o = evaluate(root, query);
    if (o.failed)
    {
        error = "the query: " ~ o.error.message ~ "\n";
        return 1;
    }
    const e = exportFor(t, mode, root, o.query, o);
    if (!e.ok)
    {
        error = targetName_ ~ " cannot express this query: " ~ e.reason ~ "\n";
        if (e.span.end > e.span.start)
            error ~= "  at `" ~ query[e.span.start .. e.span.end] ~ "`\n";
        return 2;
    }
    output = e.code;
    return 0;
}

/// FXE11: the code and 0, or the refusal and 2.
@("fileset_explorer.FXE11.emitCommand")
@system unittest
{
    import std.algorithm.searching : canFind;

    string output, error;
    assert(emitCommand(".", "src/** - **/*_test.d", "rsync", "shim", output, error) == 0);
    assert(output.canFind("+ */") && error.length == 0);
    assert(emitCommand(".", "src/** & exec", "rsync", "shim", output, error) == 2);
    assert(error.canFind("rsync cannot express") && error.canFind("at `src/** & exec`"), error);
    assert(emitCommand(".", "x", "make", "shim", output, error) == 1);
    assert(emitCommand(".", "(x", "nix", "shim", output, error) == 1);
}

/// Whether `dir` is a git work tree whose ignored files are exactly its
/// untracked ones: no untracked file is unignored, no tracked one ignored.
bool gitignoredIsUntracked(string dir) @safe
{
    import std.process : ProcessException;
    import sparkles.build_primitives.git_env : runGit;

    // No `git` to ask (a phone): not known to hold, so not assumed.
    try
    {
        const untracked = runGit(["ls-files", "--others", "--exclude-standard"], dir);
        const ignoredTracked = runGit(["ls-files", "--cached", "--ignored", "--exclude-standard"], dir);
        return untracked.status == 0 && untracked.output.length == 0 && ignoredTracked.status == 0
            && ignoredTracked.output.length == 0;
    }
    catch (ProcessException)
        return false;
}

/// The grammar the code of `t` is highlighted with, when the bundle has one.
string languageOf(Target t) @safe pure nothrow @nogc
{
    final switch (t)
    {
        case Target.nix: return "nix";
        case Target.gitPathspec, Target.tar: return "bash";
        case Target.gitignore: return "gitignore";
        case Target.rsync: return "";
        case Target.cargo: return "toml";
        case Target.bazel: return "starlark";
        case Target.dub: return "sdl";
    }
}

/**
`code`, one span list per line, highlighted with `language`'s grammar where
the bundle has it, in slots by capture name; plain otherwise.
*/
TextSpan[][] highlightCode(string language, string code) @system
{
    import std.array : appender;
    import std.algorithm.searching : startsWith;
    import sparkles.syntax.event : HighlightEvent;
    import sparkles.syntax.label : LabelSet;
    import sparkles.syntax.ts.highlighter : highlightInjected;
    import sparkles.syntax.ts.injection : TsConfigCache;
    import sparkles.syntax.ts.registry : GrammarRegistry;
    import launch : appGrammars;

    static GrammarRegistry registry;
    static bool ready;
    static TsConfigCache cache;
    static LabelSet labels;
    if (!ready)
    {
        labels = LabelSet.standard();
        registry = appGrammars();
        cache = TsConfigCache.create(&registry, labels);
        ready = true;
    }

    auto slots = new Slot[](code.length);
    slots[] = Slot.code;
    if (language.length)
    {
        auto sink = appender!(HighlightEvent[]);
        if (!highlightInjected(cache, language, code, sink).hasError)
        {
            const(char)[][] stack;
            foreach (e; sink[])
                final switch (e.kind)
                {
                    case HighlightEvent.Kind.push: stack ~= labels.name(e.label); break;
                    case HighlightEvent.Kind.pop: stack = stack[0 .. $ - 1]; break;
                    case HighlightEvent.Kind.source:
                        if (stack.length)
                            slots[e.start .. e.end] = slotOfCapture(stack[$ - 1]);
                        break;
                }
        }
    }

    TextSpan[][] lines = [[]];
    size_t start;
    foreach (i; 0 .. code.length + 1)
    {
        if (i < code.length && code[i] != '\n' && slots[i] == slots[start])
            continue;
        if (i > start)
            lines[$ - 1] ~= TextSpan(code[start .. i], slots[start]);
        if (i < code.length && code[i] == '\n')
        {
            lines ~= TextSpan[].init;
            start = i + 1;
        }
        else
            start = i;
    }
    if (lines.length && lines[$ - 1].length == 0)
        lines = lines[0 .. $ - 1];
    return lines;
}

/// The slot a highlight capture is drawn in.
Slot slotOfCapture(scope const(char)[] name) @safe pure nothrow @nogc
{
    import std.algorithm.searching : startsWith;

    // The query editor's slots for the fileset language's kinds (`FXU4`, `FXL8`).
    if (name.startsWith("comment"))
        return Slot.muted;
    if (name.startsWith("string.escape"))
        return Slot.link;
    if (name.startsWith("punctuation.special"))
        return Slot.accentSecondary;
    if (name.startsWith("property"))
        return Slot.accentPrimary;
    if (name.startsWith("string"))
        return Slot.success;
    if (name.startsWith("keyword"))
        return Slot.accentPrimary;
    if (name.startsWith("function"))
        return Slot.info;
    if (name.startsWith("operator"))
        return Slot.warn;
    if (name.startsWith("constant") || name.startsWith("number") || name.startsWith("boolean"))
        return Slot.accentSecondary;
    if (name.startsWith("punctuation"))
        return Slot.textSecondary;
    return Slot.code;
}

///
@("fileset_explorer.export.names")
@safe pure nothrow unittest
{
    Target t;
    assert(targetNamed("git-pathspec", t) && t == Target.gitPathspec);
    assert(!targetNamed("make", t));
    NixGlobs m;
    assert(nixGlobsNamed("expand", m) && m == NixGlobs.expand && !nixGlobsNamed("x", m));
    assert(slotOfCapture("comment.line") == Slot.muted && slotOfCapture("variable") == Slot.code);
}

/// Without a grammar the code is its lines, each one span.
@("fileset_explorer.export.plainLines")
@system unittest
{
    const lines = highlightCode("", "a\nbc\n");
    assert(lines.length == 2 && lines[0][0].text == "a" && lines[1][0].text == "bc");
}
