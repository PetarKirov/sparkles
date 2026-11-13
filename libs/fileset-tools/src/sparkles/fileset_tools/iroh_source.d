/**
An iroh source (`XS3`, `XS4`, `XR`, docs/specs/fsx): a collection a peer
serves, read through the iroh bridge's receive half.

`openIroh` reads the collection's names and nothing of any file, checks
every name, and removes the label `sendme` puts before them; `selectIroh`
evaluates a filter over the names alone; `receiveMembers` fetches the
selected files and writes each one's verified bytes through the capability
VFS as they arrive.
*/
module sparkles.fileset_tools.iroh_source;

import std.conv : text;

import sparkles.base.expected : Expected, err, ok;
import sparkles.iroh_send.bridge : IrohSend, ReceiveEvent, Receiver;

import sparkles.fileset_tools.verify : MemberDigest;

/// One file of the collection, as a member: its path from the root, with
/// the label removed, its digest, and its place in the collection.
struct IrohMember
{
    string path;    ///
    ubyte[32] hash; /// BLAKE3 of its bytes
    size_t index;   /// in the collection's order
}

/// An open collection.
struct IrohSource
{
    Receiver receiver;     ///
    string label;          /// the first component every name shares, or `null`
    IrohMember[] members;  /// in path order, which is the collection's
    ulong openedBytes;     /// what opening it read: the sequence and the names

    /// Closes the connection.
    void close() @safe => receiver.close();
}

/**
Opens the collection `ticket` names, reading its names and nothing of any
file (`XR2`), and checks them (`XS3`): a name that is empty, absolute, has
an empty, `.` or `..` component or a `\`, is not UTF-8, repeats another, or
is a file and a directory of another refuses the source.
*/
Expected!(IrohSource, string) openIroh(IrohSend lib, string ticket, bool noRelay = false)
{
    IrohSource s;
    s.receiver = lib.receive(ticket, noRelay);
    string why = s.receiver.error;
    if (why !is null)
    {
        s.receiver.close();
        return err!IrohSource(why);
    }
    s.openedBytes = s.receiver.stats.payloadBytesRead;
    const entries = s.receiver.entries();
    string[] names;
    foreach (ref e; entries)
        names ~= e.name;
    string label;
    string bad = checkNames(names, label);
    if (bad.length)
    {
        s.receiver.close();
        return err!IrohSource(bad);
    }
    s.label = label;
    foreach (i, ref e; entries)
        s.members ~= IrohMember(label.length ? e.name[label.length + 1 .. $] : e.name, e.hash, i);
    return ok!string(s);
}

/**
Checks a collection's names (`XS3`) and finds its label, the first
component every name shares; returns why the names cannot be a tree, or
`null`.
*/
string checkNames(const(string)[] names, out string label) @safe
{
    import std.algorithm.searching : canFind;
    import std.utf : validate, UTFException;
    import sparkles.base.vfs.names : checkBeneathPath;
    import sparkles.base.io.errors : ErrorKind;

    foreach (n; names)
    {
        try
            validate(n);
        catch (UTFException)
            return text("the collection lists a name that is not UTF-8: ", n);
        if (n.canFind('\\') || checkBeneathPath(n) != ErrorKind.other || n.length == 0)
            return text("the collection lists `", n, "`, which names no place beneath a directory");
    }
    bool[string] seen, dirs;
    foreach (n; names)
    {
        if (n in seen)
            return text("the collection lists `", n, "` twice");
        seen[n] = true;
        foreach (i, c; n)
            if (c == '/')
                dirs[n[0 .. i]] = true;
    }
    foreach (n; names)
        if (n in dirs)
            return text("the collection lists `", n, "` as a file and as a directory");

    // The label: the first component, when every name has one and it is the same.
    if (names.length)
    {
        string first;
        foreach (i, n; names)
        {
            size_t slash = 0;
            while (slash < n.length && n[slash] != '/')
                ++slash;
            if (slash == n.length)
                return null; // a name at the top: there is no label
            if (i == 0)
                first = n[0 .. slash];
            else if (n[0 .. slash] != first)
                return null;
        }
        label = first;
    }
    return null;
}

///
@("fileset_tools.iroh.checkNames")
@safe unittest
{
    string label;
    assert(checkNames(["L/a", "L/b/c"], label) is null && label == "L");
    assert(checkNames(["a", "b/c"], label) is null && label is null, "no label");
    assert(checkNames(["L/a", "M/b"], label) is null && label is null);
    foreach (bad; [["L/../x"], ["/x"], ["L//x"], ["L/a", "L/a"], ["L/a", "L/a/b"], ["L/a\\b"], ["L/\xff"], [""]])
        assert(checkNames(bad, label) !is null, bad[0]);
}

/**
The members of `filter` among `members`, in their order, decided from
their paths alone (`XS4`): a call that needs a git repository is refused,
and the executable and link predicates select nothing.
*/
Expected!(size_t[], string) selectIroh(const(IrohMember)[] members, string filter)
{
    import sparkles.build_primitives.fileset.pattern : CasePolicy;
    import sparkles.build_primitives.fileset.query : compileQuery, NodeKind, parseQuery;
    import sparkles.build_primitives.fileset.value : FilesetEvaluator, Filesets;

    auto q = parseQuery(filter);
    if (!q.ok)
        return err!(size_t[])(text(q.error.message, " (at offset ", q.error.offset, ")"));
    foreach (ref n; q.nodes)
        if (n.kind == NodeKind.gitTracked || n.kind == NodeKind.gitignored)
            return err!(size_t[])(text(n.kind == NodeKind.gitTracked ? "gitTracked()" : "gitignored()",
                " needs a git repository, and a collection carries none"));
    auto sets = Filesets(CasePolicy.sensitive);
    auto compiled = compileQuery(q, sets, () @safe => cast(string[]) null);
    if (!compiled.ok)
        return err!(size_t[])(compiled.error.message);
    auto ev = FilesetEvaluator(sets, compiled.set);
    size_t[] chosen;
    foreach (i, ref m; members)
        if (ev.contains(sets, m.path, false))
            chosen ~= i;
    return ok!string(chosen);
}

/// What `receiveMembers` did.
struct ReceiveReport
{
    size_t files;          ///
    ulong bytes;           /// written
    MemberDigest[] expected; /// each chosen member, from its digest and proved size
    string failure;        /// the first member that failed, and why
}

/**
Fetches the members at `chosen` of `source` and writes each to
`dest/<path>`, its directories made first, through `BlockingVfs`: every
piece verified by the bridge before it arrives here (`XR3`, `XR4`). With
`force`, a file in a member's way is removed first. What was written stays
when a member fails (`XC6`).
*/
ReceiveReport receiveMembers(ref IrohSource source, string dest, const(size_t)[] chosen, bool force)
{
    import core.lifetime : move;
    import std.path : absolutePath, baseName, buildNormalizedPath, dirName;
    import sparkles.base.vfs.handles : ambientAuthority, openRoot;
    import sparkles.base.vfs.types : Access, Disposition, OpenMode, Shared;
    import sparkles.build_primitives.fileset.fso : FsoKind;
    import sparkles.event_horizon.sys : BlockingVfs;
    import sparkles.fileset_tools.copy : destRights;

    ReceiveReport report;
    auto vfs = new BlockingVfs;
    const full = buildNormalizedPath(absolutePath(dest));
    auto parent = openRoot!destRights(vfs, dirName(full), ambientAuthority());
    if (parent.hasError)
    {
        report.failure = text(dirName(full), ": ", parent.error);
        return report;
    }
    auto top = parent.value.walkAll(baseName(full), Shared());
    if (top.hasError)
    {
        report.failure = text(full, ": ", top.error);
        return report;
    }
    bool[string] made;
    foreach (i; chosen)
    {
        const d = dirName(source.members[i].path);
        if (d == "." || d in made)
            continue;
        made[d] = true;
        auto dir = top.value.walkAll(d, Shared());
        if (dir.hasError)
        {
            report.failure = text(d, ": ", dir.error);
            return report;
        }
    }

    ulong[] indices;
    foreach (i; chosen)
        indices ~= source.members[i].index;
    auto asked = source.receiver.fetch(indices);
    if (asked.hasError)
    {
        report.failure = asked.error;
        return report;
    }
    size_t[ulong] memberOf;
    foreach (i; chosen)
        memberOf[source.members[i].index] = i;

    auto buffer = new ubyte[64 * 1024];
    alias Written = typeof(top.value.walk("").value.openFile!(OpenMode(Access.write, Disposition.createNew,
        false))("", Shared()).value);
    Written output;
    ulong written, stated;
    const(IrohMember)* m;
    for (;;)
    {
        ulong index, offset;
        size_t length;
        const ev = source.receiver.next(index, offset, buffer, length);
        if (ev == ReceiveEvent.done)
            break;
        if (ev == ReceiveEvent.error)
        {
            report.failure = text(m ? m.path : "the collection", ": ", source.receiver.error);
            return report;
        }
        auto at = index in memberOf;
        if (at is null)
        {
            report.failure = text("the peer sent file ", index, ", which was not asked for");
            return report;
        }
        m = &source.members[*at];
        final switch (ev)
        {
            case ReceiveEvent.start:
                stated = length;
                written = 0;
                const p = dirName(m.path), name = baseName(m.path);
                auto into = p == "." ? top.value.walk("") : top.value.walk(p);
                if (into.hasError)
                {
                    report.failure = text(m.path, ": ", into.error);
                    return report;
                }
                if (force && !into.value.statAt(name).hasError)
                {
                    const gone = into.value.unlinkAt(name);
                    if (gone.hasError)
                    {
                        report.failure = text(m.path, ": ", gone.error);
                        return report;
                    }
                }
                auto opened = into.value.openFile!(OpenMode(Access.write, Disposition.createNew, false))(name,
                    Shared());
                if (opened.hasError)
                {
                    report.failure = text(m.path, ": ", opened.error);
                    return report;
                }
                output = move(opened.value);
                break;
            case ReceiveEvent.data:
                if (offset != written)
                {
                    report.failure = text(m.path, ": the peer sent bytes at ", offset, ", not ", written);
                    return report;
                }
                size_t done;
                while (done < length)
                {
                    auto put = output.write(buffer[done .. length]);
                    if (put.hasError || put.value == 0)
                    {
                        report.failure = text(m.path, ": ", put.hasError ? text(put.error) : "a write made no progress");
                        return report;
                    }
                    done += put.value;
                }
                written += length;
                report.bytes += length;
                break;
            case ReceiveEvent.end:
                output.close();
                if (written != stated)
                {
                    report.failure = text(m.path, ": ", written, " bytes arrived, not the ", stated, " stated");
                    return report;
                }
                // The size is proved now: the last chunk verified.
                report.expected ~= MemberDigest(m.path, true, FsoKind.regular, false, written, m.hash, null);
                ++report.files;
                break;
            case ReceiveEvent.done, ReceiveEvent.error:
                assert(0);
        }
    }
    if (report.files != chosen.length)
        report.failure = text("the peer sent ", report.files, " of the ", chosen.length, " files asked for");
    return report;
}
