/**
Verifying a copy (`XV1`–`XV5`, docs/specs/fsx): each member's digest
record, the castore id of a list of them, and the first member two lists
disagree on.

A record is what castore names a member by: its kind, its executable bit,
its size and the BLAKE3 id of its bytes for a file, its target for a link
([`CAC1`](../../../../../docs/specs/build-primitives/content-addressing/SPEC.md)).
`castoreOf` assembles the tree id from records alone, so the same id comes
from a walk that reads the files, from the bytes a copy reads as it goes,
and from an iroh collection's digests, which name the same bytes.
*/
module sparkles.fileset_tools.verify;

import std.conv : text;

import sparkles.base.hash.blake3 : Blake3;
import sparkles.base.vfs.handles : DirRef;
import sparkles.base.vfs.types : EntryKind, OpenMode, Rights;
import sparkles.build_primitives.content_addressing.castore : CastoreDirectory, toCastoreText;
import sparkles.build_primitives.fileset.fso : FsoKind;

/// What castore names one member by.
struct MemberDigest
{
    string path;       /// from the root, `/`-separated
    bool present;      /// whether an entry was there at all
    FsoKind kind;      /// a regular file or a link; `directory` for anything else
    bool executable;   ///
    ulong size;        /// a file's
    ubyte[32] id;      /// BLAKE3 of a file's bytes
    string target;     /// a link's
}

/// A BLAKE3 hasher, started.
Blake3 startedHasher() @safe pure nothrow @nogc
{
    Blake3 h;
    h.start();
    return h;
}

/**
The castore id of the tree `entries` describe: each file and link at its
path, the directories between them implied. An absent entry, or one of
another kind, has no place in a tree; such a list has no id, and `null` is
returned beside the path to blame.
*/
CastoreDirectory.Id castoreOf(const(MemberDigest)[] entries, out string blame) @safe
{
    import std.algorithm.sorting : sort;
    import std.array : split;

    static final class Node
    {
        Node[string] dirs;
        const(MemberDigest)*[string] files, links;
    }

    auto root = new Node;
    foreach (ref e; entries)
    {
        if (!e.present || e.kind == FsoKind.directory)
        {
            blame = e.path;
            return CastoreDirectory.Id.init;
        }
        auto parts = e.path.split('/');
        auto n = root;
        foreach (p; parts[0 .. $ - 1])
        {
            if (auto d = p in n.dirs)
                n = *d;
            else
                n = n.dirs[p] = new Node;
        }
        if (e.kind == FsoKind.regular)
            n.files[parts[$ - 1]] = &e;
        else
            n.links[parts[$ - 1]] = &e;
    }

    // Each list in name order, the lists in castore's field order (CAC2).
    CastoreDirectory.Id seal(Node n) @safe
    {
        auto dirNames = n.dirs.keys, fileNames = n.files.keys, linkNames = n.links.keys;
        dirNames.sort();
        fileNames.sort();
        linkNames.sort();
        CastoreDirectory.Id[] children;
        foreach (d; dirNames)
            children ~= seal(n.dirs[d]);
        CastoreDirectory c;
        c.begin();
        foreach (i, d; dirNames)
            c.directory(d, children[i]);
        foreach (f; fileNames)
            c.file(f, n.files[f].executable, n.files[f].id, n.files[f].size);
        foreach (l; linkNames)
            c.symlink(l, n.links[l].target);
        return c.seal();
    }

    return seal(root);
}

/// `castoreOf`'s id as Snix prints it, or `null` when the list has none.
string castoreText(const(MemberDigest)[] entries) @safe
{
    string blame;
    const id = castoreOf(entries, blame);
    return blame.length ? null : toCastoreText(id.digest).idup;
}

/**
Reads the record of each of `paths` beneath `dir`, never following a link:
a file's bytes are hashed, a link's target read. A path with nothing there
is recorded absent; `failure` names the first entry that could not be read.
*/
MemberDigest[] digestMembers(V, Rights R)(DirRef!(V, R) dir, const(string)[] paths, out string failure)
{
    import std.path : baseName, dirName;

    auto records = new MemberDigest[paths.length];
    auto buffer = new ubyte[64 * 1024];
    char[4096] linkBuffer;
    foreach (i, path; paths)
    {
        auto r = &records[i];
        r.path = path;
        const parent = dirName(path), name = baseName(path);
        auto into = parent == "." ? dir.walk("") : dir.walk(parent);
        if (into.hasError)
            continue; // its directory is not there, so neither is it
        auto st = into.value.statAt(name);
        if (st.hasError)
            continue;
        r.present = true;
        r.executable = st.value.executable;
        final switch (st.value.kind)
        {
            case EntryKind.regular:
                r.kind = FsoKind.regular;
                auto file = into.value.openFile!(OpenMode.read)(name);
                if (file.hasError)
                {
                    failure = text(path, ": ", file.error);
                    return records;
                }
                auto h = startedHasher();
                for (;;)
                {
                    auto got = file.value.read(buffer);
                    if (got.hasError)
                    {
                        failure = text(path, ": ", got.error);
                        return records;
                    }
                    if (got.value == 0)
                        break;
                    h.put(buffer[0 .. got.value]);
                    r.size += got.value;
                }
                r.id = h.finish();
                break;
            case EntryKind.symlink:
                r.kind = FsoKind.symlink;
                r.executable = false;
                auto t = into.value.readlinkAt(name, linkBuffer[]);
                if (t.hasError)
                {
                    failure = text(path, ": ", t.error);
                    return records;
                }
                r.target = t.value.idup;
                break;
            case EntryKind.directory, EntryKind.other, EntryKind.unknown:
                r.kind = FsoKind.directory;
                break;
        }
    }
    return records;
}

/**
The first path, in path order, at which `expected` and `actual` disagree,
and how; `null` when they agree. Both list the same paths in the same
order.
*/
string firstDifference(const(MemberDigest)[] expected, const(MemberDigest)[] actual) @safe
{
    import std.algorithm.sorting : sort;

    auto order = new size_t[expected.length];
    foreach (i, ref o; order)
        o = i;
    order.sort!((a, b) => expected[a].path < expected[b].path);
    foreach (i; order)
    {
        const e = &expected[i], a = &actual[i];
        string why;
        if (!a.present)
            why = "is missing";
        else if (a.kind != e.kind)
            why = a.kind == FsoKind.directory ? "is not a file or a link"
                : a.kind == FsoKind.symlink ? "is a link, not a file" : "is a file, not a link";
        else if (e.kind == FsoKind.symlink && a.target != e.target)
            why = text("points to ", a.target, ", not ", e.target);
        else if (e.kind == FsoKind.regular && a.size != e.size)
            why = text("holds ", a.size, " bytes, not ", e.size);
        else if (e.kind == FsoKind.regular && a.id != e.id)
            why = "holds other bytes";
        else if (a.executable != e.executable)
            why = a.executable ? "is executable, and should not be" : "lost its executable bit";
        if (why.length)
            return e.path ~ " " ~ why;
    }
    return null;
}
