/**
The help (`FXU7`, `FXT1`–`FXT5`): the page `docs/apps/fileset-explorer/index.md`,
compiled in, drawn with the markdown view, and its try blocks run by the
`fileset` runner.

A try block's result is the members of its query, as `lib.fileset.trace`
lists them: directories with a trailing `/`, children by name, under
box-drawing guides. That text is what the view shows under the block and what
the block's expected fence must equal (`FXT5`).
*/
module help;

import std.algorithm.sorting : sort;
import std.array : join;
import std.string : strip;

import sparkles.build_primitives.fileset.fso : FsoKind;
import sparkles.syntax.md.model : MdBlock, MdBlockKind, MdDoc;

import evaluate : evaluate, Member, Root;

/// The help page's markdown.
enum string helpSource = import("index.md");

/// One try block of the page.
struct TryBlock
{
    string runner;   /// the runner it names
    string tree;     /// its `tree=` attribute, or null for the open directory
    string input;    /// the input fence's body
    string expected; /// the expected fence's body, or null
    size_t at;       /// the input fence's `codeBody.start`: its identity
}

/// The try blocks of `doc`, in order.
TryBlock[] tryBlocks(const MdDoc doc) @safe
{
    TryBlock[] found;
    void walk(in MdBlock[] blocks)
    {
        foreach (ref b; blocks)
        {
            if (b.kind == MdBlockKind.tryBlock)
            {
                TryBlock t;
                t.runner = b.infoLang.idup;
                t.tree = attribute(b.label, "tree");
                t.input = bodyOf(doc, b.children[0]);
                t.at = b.children[0].codeBody.start;
                if (b.children.length > 1)
                    t.expected = bodyOf(doc, b.children[1]);
                found ~= t;
            }
            walk(b.children);
        }
    }
    walk(doc.root.children);
    return found;
}

/// The trees the page declares: each ```` ```tree-literal {#name} ```` fence.
string[string] namedTrees(const MdDoc doc) @safe
{
    string[string] trees;
    void walk(in MdBlock[] blocks)
    {
        foreach (ref b; blocks)
        {
            if (b.kind == MdBlockKind.codeFence && b.infoLang == "tree-literal")
            {
                const l = strip(b.label);
                if (l.length > 3 && l[0 .. 2] == "{#" && l[$ - 1] == '}')
                    trees[l[2 .. $ - 1].idup] = bodyOf(doc, b);
            }
            walk(b.children);
        }
    }
    walk(doc.root.children);
    return trees;
}

private string bodyOf(const MdDoc doc, in MdBlock fence) @safe
    => doc.source[fence.codeBody.start .. fence.codeBody.end].idup;

/// The value of `key=` in a `{key=value …}` attribute list, or null.
string attribute(const(char)[] attrs, string key) @safe pure
{
    import std.algorithm.iteration : splitter;

    auto s = strip(attrs);
    if (s.length < 2 || s[0] != '{' || s[$ - 1] != '}')
        return null;
    foreach (part; s[1 .. $ - 1].splitter(' '))
        if (part.length > key.length && part[0 .. key.length] == key && part[key.length] == '=')
            return part[key.length + 1 .. $].idup;
    return null;
}

///
@("fileset_explorer.help.attribute")
@safe pure unittest
{
    assert(attribute("{tree=tutorial}", "tree") == "tutorial");
    assert(attribute("{a=1 tree=x}", "tree") == "x");
    assert(attribute("", "tree") is null && attribute("{trees=x}", "tree") is null);
}

/// What running a try block gave: its trace, or why it failed.
struct TryOutcome
{
    bool ok;       ///
    string trace;  /// the members as `traceText` writes them
    string error;  ///
}

/// Runs the `fileset` runner on `t`: its input against its named tree, or
/// against `dir` when it names none (`FXT3`, `FXT4`).
TryOutcome runFileset(in TryBlock t, string[string] trees, in Root dir)
{
    Root root = dir;
    if (t.tree !is null)
    {
        auto lit = t.tree in trees;
        if (lit is null)
            return TryOutcome(false, null, "no tree `" ~ t.tree ~ "` on this page");
        root = Root(literal: *lit, name: t.tree);
    }
    const o = evaluate(root, t.input);
    if (o.failed)
        return TryOutcome(false, null, o.error.message);
    return TryOutcome(true, traceText(o.found.members));
}

/**
The members as `lib.fileset.trace` lists them: one line per directory (with a
trailing `/`) and file, children sorted by name, nested under `├─ `, `└─ `
and `│  ` guides. Nothing for no members.
*/
string traceText(in Member[] members) @safe
{
    static struct Node
    {
        Node*[string] children;
        bool isDir;
    }

    auto root = new Node(null, true);
    foreach (ref m; members)
    {
        Node* at = root;
        size_t start;
        foreach (i; 0 .. m.path.length + 1)
            if (i == m.path.length || m.path[i] == '/')
            {
                const name = m.path[start .. i];
                const dir = i < m.path.length;
                if (auto c = name in at.children)
                    at = *c;
                else
                {
                    auto c = new Node(null, dir);
                    at.children[name] = c;
                    at = c;
                }
                start = i + 1;
            }
    }

    string[] lines;
    void walk(Node* n, string indent, bool top)
    {
        auto names = n.children.keys;
        sort(names);
        foreach (i, name; names)
        {
            const last = i + 1 == names.length;
            auto c = n.children[name];
            const label = c.isDir ? name ~ "/" : name;
            lines ~= top ? label : indent ~ (last ? "└─ " : "├─ ") ~ label;
            walk(c, top ? "" : indent ~ (last ? "   " : "│  "), false);
        }
    }
    walk(root, "", true);
    return lines.length ? lines.join("\n") ~ "\n" : "";
}

/// The trace: top-level entries bare, nested ones under guides, by name.
@("fileset_explorer.help.traceText")
@safe unittest
{
    const members = [Member("src/b.d"), Member("README.md"), Member("src/a.d"), Member("src/x/y.d")];
    assert(traceText(members) == "README.md\nsrc/\n├─ a.d\n├─ b.d\n└─ x/\n   └─ y.d\n", traceText(members));
    assert(traceText(null) == "");
}
