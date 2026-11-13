/**
`ls` (`XL1`–`XL4`, docs/specs/fsx): the members, one path per line, in
the long form, or as a tree.
*/
module ls;

import std.conv : text;

import sparkles.build_primitives.fileset.fso : FsoKind;

import sparkles.fileset_tools.evaluate : Member;

/// What to list, and how.
struct ListOptions
{
    string dir;              /// a local source's directory
    string ticket;           /// an iroh source's ticket, instead
    bool noRelay;            /// reach the peer at its direct addresses only
    string filter = "all()"; ///
    bool nul;                /// NUL after each path (`XL1`)
    bool long_;              /// the long form (`XL2`)
    bool tree;               /// the tree (`XL3`)
    bool stats;              /// the Stats report after it (`XL4`)
    bool treeHashes;         /// the ids after it (`XL4`)
}

/// Lists the members of `o.filter` over `o.dir`; returns the exit status.
int listCommand(in ListOptions o, ref string output, ref string error)
{
    import std.algorithm.sorting : sort;
    import sparkles.fileset_tools.evaluate : evaluate, Root;
    import sparkles.fileset_tools.stats : formatStats, statsRows;

    if (o.ticket.length)
        return listIroh(o, output, error);
    const found = evaluate(Root(dir: o.dir), o.filter, withIds: o.treeHashes || o.stats);
    if (found.failed)
    {
        error ~= text("fsls: ", o.filter, ": ", found.error.message, " (at offset ", found.error.offset, ")\n");
        return 1;
    }
    auto members = found.found.members.dup;
    members.sort!((a, b) => a.path < b.path);
    if (o.tree)
        output ~= drawTree(members);
    else
        foreach (ref m; members)
            output ~= (o.long_ ? longRow(m) : m.path) ~ (o.nul ? "\0" : "\n");
    if (o.stats)
        error ~= formatStats(statsRows(found, found, ""));
    if (o.treeHashes)
        error ~= text("castore   ", found.castore, "\nNarHash   ", found.narHash, "\ngit tree  ", found.gitTree,
            "\n");
    return 0;
}

/// A member in the long form (`XL2`): `f`, `x` or `l`, the size, the path,
/// and a link's target, separated by tabs.
string longRow(ref const Member m) @safe pure
{
    const kind = m.kind == FsoKind.symlink ? "l" : m.executable ? "x" : "f";
    return text(kind, "\t", m.kind == FsoKind.symlink ? m.target.length : m.size, "\t", m.path,
        m.kind == FsoKind.symlink ? "\t-> " ~ m.target : "");
}

/**
The members as a tree (`XL3`): each directory before the files beside it,
each level in name order, drawn with `tree`'s connectors.
*/
string drawTree(const(Member)[] members) @safe
{
    import std.algorithm.sorting : sort;
    import std.array : split;

    static final class Node
    {
        Node[string] dirs;
        const(Member)*[string] files;
    }

    auto root = new Node;
    foreach (ref m; members)
    {
        auto parts = m.path.split('/');
        auto n = root;
        foreach (p; parts[0 .. $ - 1])
        {
            if (auto d = p in n.dirs)
                n = *d;
            else
                n = n.dirs[p] = new Node;
        }
        n.files[parts[$ - 1]] = &m;
    }

    string s = ".\n";
    void draw(Node n, string indent) @safe
    {
        auto dirs = n.dirs.keys, files = n.files.keys;
        dirs.sort();
        files.sort();
        const total = dirs.length + files.length;
        size_t i;
        foreach (d; dirs)
        {
            const last = ++i == total;
            s ~= indent ~ (last ? "└── " : "├── ") ~ d ~ "/\n";
            draw(n.dirs[d], indent ~ (last ? "    " : "│   "));
        }
        foreach (f; files)
        {
            const last = ++i == total;
            const m = n.files[f];
            s ~= indent ~ (last ? "└── " : "├── ") ~ f
                ~ (m.kind == FsoKind.symlink ? " -> " ~ m.target : "") ~ "\n";
        }
    }

    draw(root, "");
    return s;
}

/**
`listCommand` over an iroh source: its names, fetched with nothing of any
file (`XR2`). A size is proved only by downloading the file, so the long
form shows `-` for it, and the ids wait for a copy.
*/
private int listIroh(in ListOptions o, ref string output, ref string error)
{
    import std.algorithm.sorting : sort;
    import sparkles.iroh_send.bridge : loadIrohSend;
    import sparkles.fileset_tools.iroh_source : openIroh, selectIroh;

    auto lib = loadIrohSend();
    if (lib.hasError)
    {
        error ~= text("fsls: an iroh source needs the iroh bridge: ", lib.error, "\n");
        return 1;
    }
    auto opened = openIroh(lib.value, o.ticket, o.noRelay);
    if (opened.hasError)
    {
        error ~= text("fsls: ", opened.error, "\n");
        return 1;
    }
    auto source = opened.value;
    scope (exit) source.close();
    auto chosen = selectIroh(source.members, o.filter);
    if (chosen.hasError)
    {
        error ~= text("fsls: ", o.filter, ": ", chosen.error, "\n");
        return 1;
    }
    Member[] members;
    foreach (i; chosen.value)
        members ~= Member(source.members[i].path, FsoKind.regular);
    members.sort!((a, b) => a.path < b.path);
    if (o.tree)
        output ~= drawTree(members);
    else
        foreach (ref m; members)
            output ~= (o.long_ ? text("f\t-\t", m.path) : m.path) ~ (o.nul ? "\0" : "\n");
    if (o.stats || o.treeHashes)
        error ~= text("fsls: ", source.label.length ? "`" ~ source.label ~ "`" : "the collection", " lists ",
            source.members.length, " files; the filter selects ", members.length,
            "; sizes and ids need the files, which fscp fetches and verifies\n");
    return 0;
}
