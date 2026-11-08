/**
Nix's archive (NAR) as a stream scheme: the serialization `nix-store
--dump` writes, hashed as it is written, with its length beside the digest:
`NarHash` and `NarSize` (D2).

A NAR is serial: a directory's entries follow one another in byte order, a
subdirectory's whole subtree among them, so a later file of a directory is
written after an earlier subdirectory's subtree. The scheme therefore
declares `leave` (A19): it writes a directory's entries up to its first
subdirectory, keeps the rest, and resumes them when that subdirectory's
`leave` comes, reading their files through references that stay valid until
the directory's own `leave`.

The grammar, from Nix's `protocols/nix-archive`: each token is a string,
its length as a little-endian `u64` and its bytes padded with zeros to a
multiple of 8.

```
nar       = "nix-archive-1" node
node      = "(" "type" ( regular | symlink | directory ) ")"
regular   = "regular" [ "executable" "" ] "contents" contents
symlink   = "symlink" "target" target
directory = "directory" { "entry" "(" "name" name "node" node ")" }
```

A plan's start roots may lie beneath the fileset root, which a stream never
sees as a unit: the scheme writes the directories above them itself, as a
directory holding only the way to its roots. `nix-store --dump` is the
oracle (`content_addressing.nar.dump`).
*/
module sparkles.build_primitives.content_addressing.nar;

import std.digest : isDigest;

import sparkles.base.buffer : UniqueBuffer;
import sparkles.base.io.errors : ErrorKind;
import sparkles.build_primitives.content_addressing.merkle : streamFile;
import sparkles.build_primitives.fileset.fso : EntryOrder, FsoKind, FsoMetadata;

/// A NAR's digest by `H`, and its length in bytes.
struct NarHash(H)
if (isDigest!H)
{
    typeof(H.init.finish()) digest; ///
    ulong size;                     ///
}

/**
The NAR of a fileset, hashed by `H` as it is written. `Ref` is the
reference type its entries carry, `FsoRef!(V, R)` for the root's VFS `V`
and rights `R`.
*/
struct NarScheme(H, Ref)
if (isDigest!H)
{
    enum order = EntryOrder.narOrder; ///
    enum metadata = cast(FsoMetadata)(FsoMetadata.executable | FsoMetadata.linkTarget); ///
    alias Result = NarHash!H; ///

    // An entry not yet written: its strings live in `text`.
    private static struct Pending
    {
        size_t name, nameEnd, target, targetEnd;
        FsoKind kind;
        bool executable;
        Ref ref_;
    }

    // An open directory: one a unit gave (`listed`), whose unwritten entries
    // are `pending[next .. end]`, or one above the start roots. Its entries
    // begin at `first`, its strings at `textMark`, and `path` is the length
    // of its path in `openPath`. Every open directory has a frame.
    private static struct Frame
    {
        size_t path, first, next, end, textMark;
        bool listed;
    }

    private H h;
    private ulong size;
    private UniqueBuffer!(Pending, 16) pending;
    private UniqueBuffer!(Frame, 16) frames;
    private UniqueBuffer!(char, 256) text;
    private UniqueBuffer!(char, 256) openPath; // the innermost open directory's path
    private bool started;
    private string why;

    /// Opens `path` and writes its entries up to its first subdirectory.
    bool visit(Entries, Exec)(scope const(char)[] path, Entries entries, bool empty, ref Exec exec)
    {
        if (!openTo(path))
            return false;
        Frame f = { path: path.length, first: pending.length, next: pending.length,
            textMark: text.length, listed: true };
        foreach (e; entries)
        {
            Pending p;
            p.name = text.length;
            text.put(e.name);
            p.nameEnd = text.length;
            p.target = text.length;
            if (e.node.kind == FsoKind.symlink)
                text.put(e.node.target);
            p.targetEnd = text.length;
            p.kind = e.node.kind;
            p.executable = e.node.executable;
            p.ref_ = e.ref_;
            pending ~= p;
        }
        f.end = pending.length;
        frames ~= f;
        return advance();
    }

    /// Closes `path`, and resumes the directory holding it.
    bool leave(Exec)(scope const(char)[] path, ref Exec exec)
    {
        assert(frames.length && frames.back.listed && frames.back.next == frames.back.end
            && openPath[] == path, "a directory is left once its entries are written");
        close();
        return advance();
    }

    /// A tree whose entries cannot all be read has no NAR (FSE1).
    bool incomplete(scope const(char)[] path, ErrorKind kind) =>
        fail("an entry could not be read, so the tree has no NAR");

    /// Why the scheme aborted.
    string failure() const => why;

    /// The NAR's digest and length.
    Result finish()
    {
        if (!started)
        {
            // A fileset holding nothing is the empty directory.
            begin();
            frames ~= Frame.init;
        }
        while (frames.length)
            close();
        return Result(h.finish(), size);
    }

    private void begin()
    {
        started = true;
        h.start();
        token("nix-archive-1");
        openDirectory(null);
    }

    // Opens the directory `path`, a unit's, without giving it a frame: closes
    // the open directories it is not beneath, and opens with a frame each
    // directory between them and it.
    private bool openTo(scope const(char)[] path)
    {
        if (!started)
        {
            begin();
            if (!path.length)
                return true; // the archive's root is the unit's directory
            frames ~= Frame.init;
        }
        else if (!frames.length)
            return fail("a directory came after the archive's root was done");
        while (!beneath(path, openPath[]))
        {
            if (frames.back.listed)
                return fail("a directory came before the one holding it was done");
            close();
        }
        const deeper = frames.back.listed;
        for (;;)
        {
            const start = openPath.length ? openPath.length + 1 : 0;
            size_t end = start;
            while (end < path.length && path[end] != '/')
                ++end;
            if (deeper && end != path.length)
                return fail("a unit skipped a directory");
            openDirectory(path[start .. end]);
            if (openPath.length)
                openPath.put('/');
            openPath.put(path[start .. end]);
            if (end == path.length)
                return true;
            Frame f = { path: openPath.length, first: pending.length, next: pending.length,
                end: pending.length, textMark: text.length };
            frames ~= f;
        }
    }

    // Writes the innermost listed directory's entries until a subdirectory,
    // whose own unit comes next, or until none is left.
    private bool advance()
    {
        while (frames.length && frames.back.listed)
        {
            auto f = &frames.back();
            if (f.next == f.end)
                return true; // its `leave` closes it
            auto p = pending[f.next++];
            const name = text[][p.name .. p.nameEnd];
            final switch (p.kind)
            {
                case FsoKind.directory:
                    return true; // opened by its own unit
                case FsoKind.symlink:
                    openEntry(name);
                    token("(");
                    token("type");
                    token("symlink");
                    token("target");
                    token(text[][p.target .. p.targetEnd]);
                    token(")");
                    token(")");
                    break;
                case FsoKind.regular:
                    openEntry(name);
                    token("(");
                    token("type");
                    token("regular");
                    if (p.executable)
                    {
                        token("executable");
                        token("");
                    }
                    token("contents");
                    auto contents = Contents(&this);
                    ulong length;
                    const failed = streamFile(p.ref_, contents, length);
                    if (failed.length)
                        return fail(failed);
                    pad(length);
                    token(")");
                    token(")");
                    break;
            }
        }
        return true;
    }

    // The bytes of one file's contents: its length, then the bytes.
    private static struct Contents
    {
        NarScheme* nar;
        void start(ulong length) { nar.u64(length); }
        void put(scope const(ubyte)[] bytes) { nar.raw(bytes); }
    }

    // Opens a directory node, inside an entry named `name` unless it is the
    // archive's root.
    private void openDirectory(scope const(char)[] name)
    {
        if (name !is null)
            openEntry(name);
        token("(");
        token("type");
        token("directory");
    }

    private void openEntry(scope const(char)[] name)
    {
        token("entry");
        token("(");
        token("name");
        token(name);
        token("node");
    }

    // Closes the innermost open directory, and its entry unless it is the
    // archive's root.
    private void close()
    {
        const f = frames.back;
        frames.length = frames.length - 1;
        pending.length = f.first;
        text.length = f.textMark;
        token(")");
        if (frames.length)
            token(")");
        openPath.length = frames.length ? frames.back.path : 0;
    }

    private void token(scope const(char)[] s)
    {
        u64(s.length);
        raw(cast(const(ubyte)[]) s);
        pad(s.length);
    }

    private void u64(ulong n)
    {
        ubyte[8] le;
        foreach (i; 0 .. 8)
            le[i] = cast(ubyte)(n >> (8 * i));
        raw(le[]);
    }

    private void pad(ulong length)
    {
        static immutable ubyte[8] zeros;
        raw(zeros[0 .. (8 - length % 8) % 8]);
    }

    private void raw(scope const(ubyte)[] bytes)
    {
        h.put(bytes);
        size += bytes.length;
    }

    private bool fail(string s)
    {
        why = s;
        return false;
    }
}

/// Whether `path` is `dir` or lies beneath it.
private bool beneath(scope const(char)[] path, scope const(char)[] dir) @safe pure nothrow @nogc
    => dir.length == 0 || (path.length >= dir.length && path[0 .. dir.length] == dir
        && (path.length == dir.length || path[dir.length] == '/'));

/// A digest as Nix prints it in SRI form: `sha256-` and standard, padded
/// base64.
char[51] toSri(in ubyte[32] digest) @safe pure nothrow @nogc
{
    import std.base64 : Base64;

    char[51] text = "sha256-                                            ";
    Base64.encode(digest[], text[7 .. $]);
    return text;
}
