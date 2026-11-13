/**
`diff` (`XD1`–`XD3`, docs/specs/fsx): the members of one filter over two
sources, compared by content id, git's `--name-status` letters, and with
`--patch` a unified diff of each changed text file.

Only the `full` configuration builds it; the default build says so
(`XA5`).
*/
module diff_command;

version (FsxDiff):

import std.conv : text;

import sparkles.build_primitives.fileset.fso : FsoKind;

import sparkles.fileset_tools.iroh_source : IrohSource;
import sparkles.fileset_tools.verify : MemberDigest;

import cli : Diff, filterOf, sourceOf;

/// What one side of the comparison holds.
private struct Side
{
    string name;             /// as the command line gave it
    MemberDigest[string] at; /// each member's record, by path
    string dir;              /// a local side's directory
    IrohSource* iroh;        /// an iroh side, open for `--patch`
    size_t[string] index;    /// an iroh side's members, by path
}

/// Compares the two sources `d` names; 0 when equal, 1 when they differ,
/// 2 on trouble (`XD3`).
int diffCommand(ref Diff d, ref string output, ref string error)
{
    import std.algorithm.sorting : sort;

    int status;
    const filter = filterOf(d.filter, d.filterFile, "fsdiff", error, status);
    if (filter is null)
        return 2;
    if (d.a.length == 0 || d.b.length == 0)
    {
        error ~= "fsdiff: name two sources: fsdiff A B [--filter EXPR]\n";
        return 2;
    }
    Side a, b;
    if (!open(d.a, filter, a, error) || !open(d.b, filter, b, error))
        return 2;
    scope (exit)
        foreach (s; [&a, &b])
            if (s.iroh)
                s.iroh.close();

    bool[string] all;
    foreach (p; a.at.byKey)
        all[p] = true;
    foreach (p; b.at.byKey)
        all[p] = true;
    auto paths = all.keys;
    paths.sort();

    string[] changed;
    foreach (p; paths)
    {
        const x = p in a.at, y = p in b.at;
        char letter = 0;
        if (x is null)
            letter = 'A';
        else if (y is null)
            letter = 'D';
        else if (x.kind != y.kind)
            letter = 'T';
        else if (x.kind == FsoKind.symlink ? x.target != y.target : x.id != y.id || x.executable != y.executable)
        {
            letter = 'M';
            if (x.kind == FsoKind.regular && x.id != y.id)
                changed ~= p;
        }
        if (letter)
            output ~= text(letter, "\t", p, "\n");
    }
    const differ = output.length > 0;
    if (d.patch && changed.length)
    {
        string why;
        auto old = contents(a, changed, why), new_ = contents(b, changed, why);
        if (why.length)
        {
            error ~= "fsdiff: " ~ why ~ "\n";
            return 2;
        }
        foreach (p; changed)
            output ~= patchOf(p, old[p], new_[p]);
    }
    return differ ? 1 : 0;
}

// Opens one side: a directory's members hashed, or a collection's names
// and digests, fetched with nothing of any file (`XD2`).
private bool open(string name, string filter, ref Side side, ref string error)
{
    import sparkles.base.vfs.handles : ambientAuthority, openRoot;
    import sparkles.base.vfs.types : Rights;
    import sparkles.event_horizon.sys : BlockingVfs;
    import sparkles.iroh_send.bridge : loadIrohSend;
    import sparkles.fileset_tools.evaluate : evaluate, Root;
    import sparkles.fileset_tools.iroh_source : openIroh, selectIroh;
    import sparkles.fileset_tools.source : SourceKind, SourceName;
    import sparkles.fileset_tools.verify : digestMembers;

    side.name = name;
    SourceName source;
    string why;
    if (!sourceOf(name, "fsdiff", source, why))
    {
        error ~= why;
        return false;
    }
    if (source.kind == SourceKind.iroh)
    {
        auto lib = loadIrohSend();
        if (lib.hasError)
        {
            error ~= text("fsdiff: an iroh source needs the iroh bridge: ", lib.error, "\n");
            return false;
        }
        auto opened = openIroh(lib.value, source.ticket);
        if (opened.hasError)
        {
            error ~= text("fsdiff: ", name, ": ", opened.error, "\n");
            return false;
        }
        side.iroh = new IrohSource;
        *side.iroh = opened.value;
        auto chosen = selectIroh(side.iroh.members, filter);
        if (chosen.hasError)
        {
            error ~= text("fsdiff: ", filter, ": ", chosen.error, "\n");
            return false;
        }
        foreach (i; chosen.value)
        {
            const m = side.iroh.members[i];
            side.at[m.path] = MemberDigest(m.path, true, FsoKind.regular, false, 0, m.hash, null);
            side.index[m.path] = i;
        }
        return true;
    }
    const found = evaluate(Root(dir: source.path), filter);
    if (found.failed)
    {
        error ~= text("fsdiff: ", name, ": ", found.error.message, "\n");
        return false;
    }
    string[] paths;
    foreach (ref m; found.found.members)
        paths ~= m.path;
    auto vfs = new BlockingVfs;
    auto root = openRoot!(Rights.readOnly)(vfs, source.path, ambientAuthority());
    if (root.hasError)
    {
        error ~= text("fsdiff: ", name, ": ", root.error, "\n");
        return false;
    }
    foreach (r; digestMembers(root.value.borrow, paths, why))
        side.at[r.path] = r;
    if (why.length)
    {
        error ~= text("fsdiff: ", name, ": cannot hash ", why, "\n");
        return false;
    }
    side.dir = source.path;
    return true;
}

// The bytes of each of `paths` on one side: read from the directory, or
// fetched from the peer, these files alone (`XD2`).
private ubyte[][string] contents(ref Side side, const(string)[] paths, ref string why)
{
    import std.algorithm.sorting : sort;
    import std.file : read;
    import std.path : buildPath;
    import sparkles.iroh_send.bridge : ReceiveEvent;

    ubyte[][string] got;
    if (side.iroh is null)
    {
        foreach (p; paths)
            got[p] = cast(ubyte[]) read(buildPath(side.dir, p));
        return got;
    }
    ulong[] indices;
    string[ulong] pathOf;
    foreach (p; paths)
    {
        const m = side.iroh.members[side.index[p]];
        indices ~= m.index;
        pathOf[m.index] = p;
    }
    indices.sort();
    auto asked = side.iroh.receiver.fetch(indices);
    if (asked.hasError)
    {
        why = side.name ~ ": " ~ asked.error;
        return got;
    }
    auto buffer = new ubyte[64 * 1024];
    for (;;)
    {
        ulong index, offset;
        size_t length;
        const ev = side.iroh.receiver.next(index, offset, buffer, length);
        if (ev == ReceiveEvent.done)
            break;
        if (ev == ReceiveEvent.error)
        {
            why = side.name ~ ": " ~ side.iroh.receiver.error;
            return got;
        }
        if (ev == ReceiveEvent.start)
            got[pathOf[index]] = null;
        else if (ev == ReceiveEvent.data)
            got[pathOf[index]] ~= buffer[0 .. length];
    }
    return got;
}

// A unified diff of one file's two versions, or a line saying they are not
// both text; colored as git colors it when standard output is a terminal.
private string patchOf(string path, const(ubyte)[] old, const(ubyte)[] new_)
{
    import std.array : appender;
    import std.utf : validate, UTFException;
    import sparkles.diff.engine : diffText;
    import sparkles.diff.patch : emitPatch;

    const a = cast(const(char)[]) old, b = cast(const(char)[]) new_;
    try
    {
        validate(a);
        validate(b);
    }
    catch (UTFException)
        return text("Binary files a/", path, " and b/", path, " differ\n");
    auto doc = diffText(a, b, path, path);
    auto w = appender!string;
    emitPatch(doc, w);
    return colored(w[]);
}

private string colored(string patch)
{
    import std.algorithm.searching : startsWith;
    import std.array : split;

    version (Posix)
    {
        import core.sys.posix.unistd : isatty;

        if (!isatty(1))
            return patch;
    }
    else
        return patch;
    string s;
    foreach (line; patch.split('\n')[0 .. $ - 1])
    {
        const code = line.startsWith("+++") || line.startsWith("---") || line.startsWith("diff ") ? "1"
            : line.startsWith("@@") ? "36" : line.startsWith("+") ? "32" : line.startsWith("-") ? "31" : null;
        s ~= code ? text("\x1b[", code, "m", line, "\x1b[0m\n") : line ~ "\n";
    }
    return s;
}
