/**
`MemVfs`, the in-memory backend (VFM1–VFM5).

A supported backend, not a test double: it models directories, regular files
with contents and an executable bit, symbolic links with opaque targets, a
settable modification time, a device id per mounted subtree, and the sharing
each entry was created with. It does not model permissions, hard links,
reparse tags or case-insensitive names.

Its nodes and file contents live in arenas the caller supplies (VFM4); it
counts every backend call by `OpKind` (VFM2); and an optional hook runs
before each call and may change the tree, which turns a race into a
repeatable scenario (VFM3). The `tree` methods build and inspect trees for
tests and are not part of the capability API: they take paths from the
backend's own root and check nothing.
*/
module sparkles.base.vfs.mem;

import sparkles.base.io.errors : ErrorKind, IoError, IoErrorStage, IoResult, OpKind, ioErr, ioOk;
import sparkles.base.vfs.names : pathComponents;
import sparkles.base.vfs.types : Access, Disposition, EntryKind, OpenMode, Sharing, Stat,
    StatMask, maxNameLength, maxSymlinkHops;

/// One node of a `MemVfs` tree. Callers allocate an array of these and hand it
/// to `MemVfs`; its fields are private to the backend.
struct MemNode
{
private:
    EntryKind kind;                 // `unknown` marks a free node
    ubyte nameLength;
    char[maxNameLength] name;
    uint parent = none;
    uint firstChild = none;
    uint nextSibling = none;        // also links the free list
    uint mountDevice;               // non-zero on a mount point
    bool executable;
    bool detached;                  // removed from the tree, still open
    bool touched;                   // reached by a backend call since `clearTouched`
    uint openCount;
    long mtimeNs;
    Sharing sharing;
    size_t dataOffset, dataLength, dataCapacity; // contents, or a link's target
}

private enum uint none = uint.max;

/// The in-memory backend.
struct MemVfs
{
    /// A handle: a slot in the open-handle table and its generation.
    struct Handle
    {
        private uint slot = none;
        private uint generation;
    }

    /// A directory listing in progress.
    struct Listing
    {
        private Handle dir;
        private uint cursor = none;
        private bool started;
    }

    /// The hook of VFM3: runs before backend call number `callIndex`.
    alias Hook = void delegate(size_t callIndex, ref MemVfs vfs) @safe nothrow @nogc;

    /// Runs before every backend call when set.
    Hook hook;

    private MemNode[] nodes;
    private ubyte[] bytes;
    private size_t bytesUsed;
    private uint freeList = none;
    private uint nodesUsed;
    private uint nextDevice = 2;
    private ulong[OpKind.max + 1] counts;
    private size_t calls;
    private bool inHook;

    private enum handleCapacity = 256;
    private static struct Slot
    {
        uint node = none;
        uint generation;
        bool directory;
        Access access;
        ulong offset;
    }
    private Slot[handleCapacity] slots;

    @disable this(this);

    /**
    A backend over caller-supplied arenas: `nodes` holds every entry (one is
    the root directory) and `bytes` every file's contents and link's target.
    */
    this(MemNode[] nodes, ubyte[] bytes) @safe pure nothrow @nogc
    in (nodes.length > 0, "MemVfs needs at least the root node")
    {
        this.nodes = nodes;
        this.bytes = bytes;
        foreach (ref n; nodes)
            n = MemNode.init;
        nodes[0].kind = EntryKind.directory;
        nodes[0].mountDevice = 1;
        nodesUsed = 1;
    }

    /// Backend calls made so far, by kind (VFM2).
    ulong count(OpKind op) const @safe pure nothrow @nogc => counts[op];

    /// Backend calls made so far, in total.
    ulong totalCalls() const @safe pure nothrow @nogc => calls;

    /// Resets the call counters.
    void resetCounts() @safe pure nothrow @nogc
    {
        counts[] = 0;
        calls = 0;
    }

    // ---------------------------------------------------------------- primitives

    /// The ambient open: resolves `path` from the backend's root, following
    /// symbolic links (VFH7).
    IoResult!Handle openRootDir(scope const(char)[] path) @safe nothrow @nogc
    {
        enter(OpKind.resolve);
        const n = resolveAmbient(path);
        if (n.hasError)
            return ioErr!Handle(n);
        if (nodes[n.value].kind != EntryKind.directory)
            return ioErr!Handle(ErrorKind.notADirectory, OpKind.resolve);
        return newHandle(n.value, true, Access.read, OpKind.resolve);
    }

    /// Opens the directory `name` in `dir` without following it.
    IoResult!Handle openDirAt(Handle dir, scope const(char)[] name) @safe nothrow @nogc
    {
        enter(OpKind.openAt);
        const c = child(dir, name, OpKind.openAt);
        if (c.hasError)
            return ioErr!Handle(c);
        final switch (nodes[c.value].kind)
        {
            case EntryKind.directory:
                return newHandle(c.value, true, Access.read, OpKind.openAt);
            case EntryKind.symlink:
                return ioErr!Handle(ErrorKind.symlinkRefused, OpKind.openAt);
            case EntryKind.regular, EntryKind.other, EntryKind.unknown:
                return ioErr!Handle(ErrorKind.notADirectory, OpKind.openAt);
        }
    }

    /// A new handle to the directory `dir` names, as opening `.` gives.
    IoResult!Handle reopen(Handle dir) @safe nothrow @nogc
    {
        enter(OpKind.openAt);
        const d = dirNode(dir, OpKind.openAt);
        return d.hasError ? ioErr!Handle(d) : newHandle(d.value, true, Access.read, OpKind.openAt);
    }

    /// Opens or creates the file `name` in `dir` without following it.
    IoResult!Handle openFileAt(Handle dir, scope const(char)[] name, OpenMode mode,
        Sharing sharing) @safe nothrow @nogc
    {
        enter(OpKind.openAt);
        const d = dirNode(dir, OpKind.openAt);
        if (d.hasError)
            return ioErr!Handle(d);
        uint n = find(d.value, name);
        if (n == none)
        {
            if (!mode.creates)
                return ioErr!Handle(ErrorKind.notFound, OpKind.openAt);
            const made = attach(d.value, name, EntryKind.regular, sharing, OpKind.openAt);
            if (made.hasError)
                return ioErr!Handle(made);
            n = made.value;
            nodes[n].executable = mode.executable;
        }
        else
        {
            touch(n);
            if (nodes[n].kind == EntryKind.symlink)
                return ioErr!Handle(ErrorKind.symlinkRefused, OpKind.openAt);
            if (nodes[n].kind == EntryKind.directory)
                return ioErr!Handle(ErrorKind.isADirectory, OpKind.openAt);
            if (mode.disposition == Disposition.createNew)
                return ioErr!Handle(ErrorKind.exists, OpKind.openAt);
            if (mode.disposition == Disposition.createOrTruncate)
                nodes[n].dataLength = 0;
        }
        return newHandle(n, false, mode.access, OpKind.openAt);
    }

    /// Creates the directory `name` in `dir`.
    IoResult!void mkdirAt(Handle dir, scope const(char)[] name, Sharing sharing)
        @safe nothrow @nogc
    {
        enter(OpKind.mkdirAt);
        const d = dirNode(dir, OpKind.mkdirAt);
        if (d.hasError)
            return ioErr!void(d);
        if (find(d.value, name) != none)
            return ioErr!void(ErrorKind.exists, OpKind.mkdirAt);
        const made = attach(d.value, name, EntryKind.directory, sharing, OpKind.mkdirAt);
        return made.hasError ? ioErr!void(made) : ioOk();
    }

    /// Stats the entry `name` in `dir` itself, never a link's target.
    IoResult!Stat statAt(Handle dir, scope const(char)[] name, StatMask mask)
        @safe nothrow @nogc
    {
        enter(OpKind.statAt);
        const c = child(dir, name, OpKind.statAt);
        return c.hasError ? ioErr!Stat(c) : ioOk(statOf(c.value, mask));
    }

    /// Stats an open handle.
    IoResult!Stat fstat(Handle h, StatMask mask) @safe nothrow @nogc
    {
        enter(OpKind.statAt);
        const n = nodeOf(h, OpKind.statAt);
        return n.hasError ? ioErr!Stat(n) : ioOk(statOf(n.value, mask));
    }

    /// Reads the target of the link `name` in `dir` into `buffer`.
    IoResult!size_t readlinkAt(Handle dir, scope const(char)[] name, scope char[] buffer)
        @safe nothrow @nogc
    {
        enter(OpKind.readlinkAt);
        const c = child(dir, name, OpKind.readlinkAt);
        if (c.hasError)
            return ioErr!size_t(c);
        const n = &nodes[c.value];
        if (n.kind != EntryKind.symlink)
            return ioErr!size_t(ErrorKind.other, OpKind.readlinkAt, 22, // EINVAL
                IoErrorStage.completion, "not a symbolic link");
        if (buffer.length < n.dataLength)
            return ioErr!size_t(ErrorKind.bufferTooSmall, OpKind.readlinkAt);
        foreach (i; 0 .. n.dataLength)
            buffer[i] = cast(char) bytes[n.dataOffset + i];
        return ioOk(n.dataLength);
    }

    /// Creates the link `name` in `dir`, storing `target` verbatim.
    IoResult!void symlinkAt(Handle dir, scope const(char)[] name, scope const(char)[] target)
        @safe nothrow @nogc
    {
        enter(OpKind.symlinkAt);
        const d = dirNode(dir, OpKind.symlinkAt);
        if (d.hasError)
            return ioErr!void(d);
        if (find(d.value, name) != none)
            return ioErr!void(ErrorKind.exists, OpKind.symlinkAt);
        const region = allocate(target.length, OpKind.symlinkAt);
        if (region.hasError)
            return ioErr!void(region);
        const made = attach(d.value, name, EntryKind.symlink, Sharing.init, OpKind.symlinkAt);
        if (made.hasError)
            return ioErr!void(made);
        auto n = &nodes[made.value];
        n.dataOffset = region.value;
        n.dataCapacity = n.dataLength = target.length;
        foreach (i, ch; target)
            bytes[region.value + i] = cast(ubyte) ch;
        return ioOk();
    }

    /// Removes the non-directory `name` in `dir`.
    IoResult!void unlinkAt(Handle dir, scope const(char)[] name) @safe nothrow @nogc
    {
        enter(OpKind.unlinkAt);
        const c = child(dir, name, OpKind.unlinkAt);
        if (c.hasError)
            return ioErr!void(c);
        if (nodes[c.value].kind == EntryKind.directory)
            return ioErr!void(ErrorKind.isADirectory, OpKind.unlinkAt);
        detach(c.value);
        return ioOk();
    }

    /// Removes the empty directory `name` in `dir`.
    IoResult!void rmdirAt(Handle dir, scope const(char)[] name) @safe nothrow @nogc
    {
        enter(OpKind.rmdirAt);
        const c = child(dir, name, OpKind.rmdirAt);
        if (c.hasError)
            return ioErr!void(c);
        if (nodes[c.value].kind != EntryKind.directory)
            return ioErr!void(ErrorKind.notADirectory, OpKind.rmdirAt);
        if (nodes[c.value].firstChild != none)
            return ioErr!void(ErrorKind.notEmpty, OpKind.rmdirAt);
        detach(c.value);
        return ioOk();
    }

    /// Renames `name` in `dir` to `dstName` in `dstDir`, replacing a
    /// non-directory or an empty directory there.
    IoResult!void renameAt(Handle dir, scope const(char)[] name, Handle dstDir,
        scope const(char)[] dstName) @safe nothrow @nogc
    {
        enter(OpKind.renameAt);
        const c = child(dir, name, OpKind.renameAt);
        if (c.hasError)
            return ioErr!void(c);
        const d = dirNode(dstDir, OpKind.renameAt);
        if (d.hasError)
            return ioErr!void(d);
        const src = c.value;
        for (uint p = d.value; p != none; p = nodes[p].parent)
            if (p == src)
                return ioErr!void(ErrorKind.other, OpKind.renameAt, 22, // EINVAL
                    IoErrorStage.completion, "rename into its own subtree");
        if (deviceOf(d.value) != deviceOf(nodes[src].parent))
            return ioErr!void(ErrorKind.other, OpKind.renameAt, 18, // EXDEV
                IoErrorStage.completion, "rename across devices");
        const existing = find(d.value, dstName);
        if (existing == src)
            return ioOk();
        if (existing != none)
        {
            touch(existing);
            const srcDir = nodes[src].kind == EntryKind.directory;
            const dstDirKind = nodes[existing].kind == EntryKind.directory;
            if (dstDirKind && !srcDir)
                return ioErr!void(ErrorKind.isADirectory, OpKind.renameAt);
            if (!dstDirKind && srcDir)
                return ioErr!void(ErrorKind.notADirectory, OpKind.renameAt);
            if (dstDirKind && nodes[existing].firstChild != none)
                return ioErr!void(ErrorKind.notEmpty, OpKind.renameAt);
            detach(existing);
        }
        unlink(src);
        setName(src, dstName);
        link(d.value, src);
        return ioOk();
    }

    /// Starts a listing of `dir`, independent of every other listing.
    IoResult!Listing openListing(Handle dir) @safe nothrow @nogc
    {
        enter(OpKind.readDir);
        const d = dirNode(dir, OpKind.readDir);
        if (d.hasError)
            return ioErr!Listing(d);
        const h = newHandle(d.value, true, Access.read, OpKind.readDir);
        if (h.hasError)
            return ioErr!Listing(h);
        return ioOk(Listing(h.value));
    }

    /// Advances a listing: writes the next entry's name into `buffer`.
    IoResult!bool nextEntry(ref Listing listing, scope char[] buffer, out size_t nameLength,
        out EntryKind kind) @safe nothrow @nogc
    {
        enter(OpKind.readDir);
        const d = nodeOf(listing.dir, OpKind.readDir);
        if (d.hasError)
            return ioErr!bool(d);
        uint next = listing.started
            ? (listing.cursor == none ? none : nodes[listing.cursor].nextSibling)
            : nodes[d.value].firstChild;
        // An entry removed since the last advance ends its chain; restart from
        // the directory's current children, as a real listing may skip.
        if (listing.cursor != none && (nodes[listing.cursor].detached
                || nodes[listing.cursor].parent != d.value))
            next = none;
        listing.started = true;
        listing.cursor = next;
        if (next == none)
            return ioOk(false);
        const n = &nodes[next];
        if (buffer.length < n.nameLength)
            return ioErr!bool(ErrorKind.bufferTooSmall, OpKind.readDir);
        buffer[0 .. n.nameLength] = n.name[0 .. n.nameLength];
        nameLength = n.nameLength;
        kind = n.kind;
        return ioOk(true);
    }

    /// Ends a listing.
    void closeListing(ref Listing listing) @safe nothrow @nogc
    {
        release(listing.dir);
        listing = Listing.init;
    }

    /// Reads from an open file at its offset.
    IoResult!size_t read(Handle h, scope ubyte[] buffer) @safe nothrow @nogc
    {
        enter(OpKind.read);
        auto s = slotOf(h, OpKind.read);
        if (s.hasError)
            return ioErr!size_t(s);
        auto slot = &slots[s.value];
        if (slot.directory)
            return ioErr!size_t(ErrorKind.isADirectory, OpKind.read);
        if (slot.access == Access.write || slot.access == Access.append)
            return ioErr!size_t(ErrorKind.permission, OpKind.read, 9); // EBADF
        const n = &nodes[slot.node];
        if (slot.offset >= n.dataLength)
            return ioOk(size_t(0));
        const count = cast(size_t)(buffer.length < n.dataLength - slot.offset
            ? buffer.length : n.dataLength - slot.offset);
        const from = n.dataOffset + cast(size_t) slot.offset;
        buffer[0 .. count] = bytes[from .. from + count];
        slot.offset += count;
        return ioOk(count);
    }

    /// Writes to an open file at its offset, or at its end in append mode.
    IoResult!size_t write(Handle h, scope const(ubyte)[] data) @safe nothrow @nogc
    {
        enter(OpKind.write);
        auto s = slotOf(h, OpKind.write);
        if (s.hasError)
            return ioErr!size_t(s);
        auto slot = &slots[s.value];
        if (slot.directory)
            return ioErr!size_t(ErrorKind.isADirectory, OpKind.write);
        if (slot.access == Access.read)
            return ioErr!size_t(ErrorKind.permission, OpKind.write, 9); // EBADF
        auto n = &nodes[slot.node];
        if (slot.access == Access.append)
            slot.offset = n.dataLength;
        const end = cast(size_t) slot.offset + data.length;
        if (end > n.dataCapacity)
        {
            const grown = allocate(end * 2, OpKind.write);
            if (grown.hasError)
                return ioErr!size_t(grown);
            bytes[grown.value .. grown.value + n.dataLength]
                = bytes[n.dataOffset .. n.dataOffset + n.dataLength];
            n.dataOffset = grown.value;
            n.dataCapacity = end * 2;
        }
        if (slot.offset > n.dataLength)
            bytes[n.dataOffset + n.dataLength .. n.dataOffset + cast(size_t) slot.offset] = 0;
        bytes[n.dataOffset + cast(size_t) slot.offset .. n.dataOffset + end] = data[];
        if (end > n.dataLength)
            n.dataLength = end;
        slot.offset = end;
        return ioOk(data.length);
    }

    /// Flushes an open file; a no-op in memory.
    IoResult!void sync(Handle h) @safe nothrow @nogc
    {
        enter(OpKind.fsync);
        const s = slotOf(h, OpKind.fsync);
        return s.hasError ? ioErr!void(s) : ioOk();
    }

    /// Closes a handle.
    IoResult!void close(Handle h) @safe nothrow @nogc
    {
        enter(OpKind.close);
        const s = slotOf(h, OpKind.close);
        if (s.hasError)
            return ioErr!void(s);
        release(h);
        return ioOk();
    }

    // ---------------------------------------------------------------- tree (tests)

    /// Creates the directory `path` and any missing parents. Returns `false` if
    /// a component exists and is not a directory, or an arena is full.
    bool mkdirs(scope const(char)[] path, Sharing sharing = Sharing.init)
        @safe nothrow @nogc
    {
        uint d = 0;
        foreach (c; pathComponents(path))
        {
            uint n = find(d, c);
            if (n == none)
            {
                const made = attach(d, c, EntryKind.directory, sharing, OpKind.mkdirAt);
                if (made.hasError)
                    return false;
                n = made.value;
            }
            if (nodes[n].kind != EntryKind.directory)
                return false;
            d = n;
        }
        return true;
    }

    /// Creates or replaces the file `path`, creating its parents.
    bool writeFile(scope const(char)[] path, scope const(ubyte)[] content,
        bool executable = false, Sharing sharing = Sharing.init) @safe nothrow @nogc
    {
        uint parent;
        const leaf = splitParent(path, parent, true);
        if (leaf is null)
            return false;
        uint n = find(parent, leaf);
        if (n != none && nodes[n].kind != EntryKind.regular)
            return false;
        const region = allocate(content.length, OpKind.write);
        if (region.hasError)
            return false;
        if (n == none)
        {
            const made = attach(parent, leaf, EntryKind.regular, sharing, OpKind.openAt);
            if (made.hasError)
                return false;
            n = made.value;
        }
        auto node = &nodes[n];
        node.executable = executable;
        node.dataOffset = region.value;
        node.dataLength = node.dataCapacity = content.length;
        bytes[region.value .. region.value + content.length] = content[];
        return true;
    }

    /// Creates the link `path` with any `target`, absolute ones included.
    bool symlink(scope const(char)[] path, scope const(char)[] target) @safe nothrow @nogc
    {
        uint parent;
        const leaf = splitParent(path, parent, true);
        if (leaf is null || find(parent, leaf) != none)
            return false;
        const region = allocate(target.length, OpKind.symlinkAt);
        if (region.hasError)
            return false;
        const made = attach(parent, leaf, EntryKind.symlink, Sharing.init, OpKind.symlinkAt);
        if (made.hasError)
            return false;
        auto node = &nodes[made.value];
        node.dataOffset = region.value;
        node.dataLength = node.dataCapacity = target.length;
        foreach (i, ch; target)
            bytes[region.value + i] = cast(ubyte) ch;
        return true;
    }

    /// Moves `from` to `to`, replacing whatever is there. Open handles keep
    /// naming the moved node.
    bool rename(scope const(char)[] from, scope const(char)[] to) @safe nothrow @nogc
    {
        const src = lookup(from);
        uint parent;
        const leaf = src == none || src == 0 ? null : splitParent(to, parent, true);
        if (leaf is null)
            return false;
        for (uint p = parent; p != none; p = nodes[p].parent)
            if (p == src)
                return false;
        const existing = find(parent, leaf);
        if (existing == src)
            return true;
        if (existing != none)
            removeSubtree(existing);
        unlink(src);
        setName(src, leaf);
        link(parent, src);
        return true;
    }

    /// Removes `path` and everything beneath it.
    bool remove(scope const(char)[] path) @safe nothrow @nogc
    {
        const n = lookup(path);
        if (n == none || n == 0)
            return false;
        removeSubtree(n);
        return true;
    }

    /// Makes the directory `path` a mount point: it and everything beneath it
    /// move to a new device.
    bool mount(scope const(char)[] path) @safe nothrow @nogc
    {
        const n = lookup(path);
        if (n == none || nodes[n].kind != EntryKind.directory)
            return false;
        nodes[n].mountDevice = nextDevice++;
        return true;
    }

    /// Sets the modification time of `path`.
    bool setMtime(scope const(char)[] path, long ns) @safe nothrow @nogc
    {
        const n = lookup(path);
        if (n == none)
            return false;
        nodes[n].mtimeNs = ns;
        return true;
    }

    /// The kind of `path`, without following a final link; `unknown` if absent.
    EntryKind kindOf(scope const(char)[] path) const scope @safe nothrow @nogc
    {
        const n = lookup(path);
        return n == none ? EntryKind.unknown : nodes[n].kind;
    }

    /// Whether `path` exists.
    bool exists(scope const(char)[] path) const scope @safe nothrow @nogc => lookup(path) != none;

    /// The contents of the file `path`, or of the link's target text.
    const(ubyte)[] contents(scope const(char)[] path) const return scope @safe nothrow @nogc
    {
        const n = lookup(path);
        if (n == none)
            return null;
        return bytes[nodes[n].dataOffset .. nodes[n].dataOffset + nodes[n].dataLength];
    }

    /// The sharing `path` was created with (VFM5).
    Sharing sharingOf(scope const(char)[] path) const scope @safe nothrow @nogc
    {
        const n = lookup(path);
        return n == none ? Sharing.init : nodes[n].sharing;
    }

    /// Whether `path` was reached by a backend call since `clearTouched`.
    bool touched(scope const(char)[] path) const scope @safe nothrow @nogc
    {
        const n = lookup(path);
        if (n == none)
            return false;
        // A subtree counts as touched if any node in it was.
        return subtreeTouched(n);
    }

    /// Forgets which nodes backend calls have reached.
    void clearTouched() @safe nothrow @nogc
    {
        foreach (ref n; nodes[0 .. nodesUsed])
            n.touched = false;
    }

    /// Entries currently in use, the root included.
    size_t liveNodes() const scope @safe nothrow @nogc
    {
        size_t count;
        foreach (ref n; nodes[0 .. nodesUsed])
            if (n.kind != EntryKind.unknown)
                ++count;
        return count;
    }

    /// Handles currently open.
    size_t openHandles() const scope @safe nothrow @nogc
    {
        size_t count;
        foreach (ref s; slots)
            if (s.node != none)
                ++count;
        return count;
    }

    // ---------------------------------------------------------------- internals

private:

    void enter(OpKind op) @safe nothrow @nogc
    {
        if (hook !is null && !inHook)
        {
            inHook = true;
            hook(calls, this);
            inHook = false;
        }
        ++counts[op];
        ++calls;
    }

    void touch(uint n) @safe nothrow @nogc
    {
        nodes[n].touched = true;
    }

    bool subtreeTouched(uint n) const scope @safe nothrow @nogc
    {
        if (nodes[n].touched)
            return true;
        for (uint c = nodes[n].firstChild; c != none; c = nodes[c].nextSibling)
            if (subtreeTouched(c))
                return true;
        return false;
    }

    IoResult!uint slotOf(Handle h, OpKind op) const scope @safe nothrow @nogc
    {
        if (h.slot >= handleCapacity || slots[h.slot].node == none
            || slots[h.slot].generation != h.generation)
            return ioErr!uint(ErrorKind.other, op, 9, // EBADF
                IoErrorStage.completion, "closed or unknown handle");
        return ioOk(h.slot);
    }

    IoResult!uint nodeOf(Handle h, OpKind op) const scope @safe nothrow @nogc
    {
        const s = slotOf(h, op);
        return s.hasError ? ioErr!uint(s) : ioOk(slots[s.value].node);
    }

    IoResult!uint dirNode(Handle h, OpKind op) const scope @safe nothrow @nogc
    {
        const n = nodeOf(h, op);
        if (n.hasError)
            return n;
        if (nodes[n.value].kind != EntryKind.directory)
            return ioErr!uint(ErrorKind.notADirectory, op);
        return n;
    }

    IoResult!uint child(Handle dir, scope const(char)[] name, OpKind op) @safe nothrow @nogc
    {
        const d = dirNode(dir, op);
        if (d.hasError)
            return d;
        const c = find(d.value, name);
        if (c == none)
            return ioErr!uint(ErrorKind.notFound, op);
        touch(c);
        return ioOk(c);
    }

    uint find(uint dir, scope const(char)[] name) const scope @safe nothrow @nogc
    {
        for (uint c = nodes[dir].firstChild; c != none; c = nodes[c].nextSibling)
            if (nodes[c].name[0 .. nodes[c].nameLength] == name)
                return c;
        return none;
    }

    uint lookup(scope const(char)[] path) const scope @safe nothrow @nogc
    {
        uint n = 0;
        foreach (c; pathComponents(path))
        {
            if (nodes[n].kind != EntryKind.directory)
                return none;
            n = find(n, c);
            if (n == none)
                return none;
        }
        return n;
    }

    // The leaf name of `path`, with its parent in `parent`; null on failure.
    const(char)[] splitParent(return scope const(char)[] path, out uint parent,
        bool createParents) @safe nothrow @nogc
    {
        size_t end = path.length;
        while (end > 0 && path[end - 1] == '/')
            --end;
        size_t start = end;
        while (start > 0 && path[start - 1] != '/')
            --start;
        if (start == end)
            return null;
        if (createParents && !mkdirs(path[0 .. start]))
            return null;
        parent = lookup(path[0 .. start]);
        if (parent == none || nodes[parent].kind != EntryKind.directory)
            return null;
        return path[start .. end];
    }

    IoResult!uint attach(uint dir, scope const(char)[] name, EntryKind kind, Sharing sharing,
        OpKind op) @safe nothrow @nogc
    {
        if (name.length > maxNameLength)
            return ioErr!uint(ErrorKind.nameTooLong, op);
        uint n;
        if (freeList != none)
        {
            n = freeList;
            freeList = nodes[n].nextSibling;
        }
        else if (nodesUsed < nodes.length)
            n = nodesUsed++;
        else
            return ioErr!uint(ErrorKind.other, op, 0, IoErrorStage.completion, "arena exhausted");
        nodes[n] = MemNode.init;
        nodes[n].kind = kind;
        nodes[n].sharing = sharing;
        nodes[n].touched = true;
        setName(n, name);
        link(dir, n);
        return ioOk(n);
    }

    void setName(uint n, scope const(char)[] name) @safe nothrow @nogc
    {
        nodes[n].nameLength = cast(ubyte) name.length;
        nodes[n].name[0 .. name.length] = name[];
    }

    void link(uint dir, uint n) @safe nothrow @nogc
    {
        nodes[n].parent = dir;
        nodes[n].nextSibling = nodes[dir].firstChild;
        nodes[dir].firstChild = n;
    }

    void unlink(uint n) @safe nothrow @nogc
    {
        const p = nodes[n].parent;
        if (p == none)
            return;
        if (nodes[p].firstChild == n)
            nodes[p].firstChild = nodes[n].nextSibling;
        else
            for (uint c = nodes[p].firstChild; c != none; c = nodes[c].nextSibling)
                if (nodes[c].nextSibling == n)
                {
                    nodes[c].nextSibling = nodes[n].nextSibling;
                    break;
                }
        nodes[n].parent = none;
        nodes[n].nextSibling = none;
    }

    // Removes `n` from the tree; frees it once no handle names it.
    void detach(uint n) @safe nothrow @nogc
    {
        unlink(n);
        nodes[n].detached = true;
        if (nodes[n].openCount == 0)
            free(n);
    }

    void removeSubtree(uint n) @safe nothrow @nogc
    {
        while (nodes[n].firstChild != none)
            removeSubtree(nodes[n].firstChild);
        detach(n);
    }

    void free(uint n) @safe nothrow @nogc
    {
        nodes[n] = MemNode.init;
        nodes[n].nextSibling = freeList;
        freeList = n;
    }

    IoResult!size_t allocate(size_t length, OpKind op) @safe nothrow @nogc
    {
        if (bytes.length - bytesUsed < length)
            return ioErr!size_t(ErrorKind.other, op, 0, IoErrorStage.completion, "arena exhausted");
        const at = bytesUsed;
        bytesUsed += length;
        return ioOk(at);
    }

    IoResult!Handle newHandle(uint n, bool directory, Access access, OpKind op)
        @safe nothrow @nogc
    {
        foreach (i, ref s; slots)
        {
            if (s.node != none)
                continue;
            s.node = n;
            s.directory = directory;
            s.access = access;
            s.offset = 0;
            ++nodes[n].openCount;
            touch(n);
            return ioOk(Handle(cast(uint) i, s.generation));
        }
        return ioErr!Handle(ErrorKind.other, op, 24, // EMFILE
            IoErrorStage.completion, "handle table full");
    }

    void release(Handle h) @safe nothrow @nogc
    {
        if (h.slot >= handleCapacity || slots[h.slot].node == none
            || slots[h.slot].generation != h.generation)
            return;
        const n = slots[h.slot].node;
        slots[h.slot].node = none;
        ++slots[h.slot].generation;
        if (--nodes[n].openCount == 0 && nodes[n].detached)
            free(n);
    }

    uint deviceOf(uint n) const scope @safe nothrow @nogc
    {
        for (uint p = n; p != none; p = nodes[p].parent)
            if (nodes[p].mountDevice)
                return nodes[p].mountDevice;
        return 1;
    }

    Stat statOf(uint n, StatMask mask) const scope @safe nothrow @nogc
    {
        Stat s;
        const node = &nodes[n];
        s.kind = node.kind;
        s.executable = node.executable;
        s.size = node.kind == EntryKind.directory ? 0 : node.dataLength;
        s.device = deviceOf(n);
        if (mask & StatMask.mtime)
        {
            s.hasMtime = true;
            s.mtimeNs = node.mtimeNs;
        }
        version (Posix)
            s.permissions = node.kind == EntryKind.symlink ? 511
                : node.sharing.modeBits(node.kind == EntryKind.directory, node.executable);
        return s;
    }

    // The ambient resolution behind `openRootDir`: follows links, as an
    // ordinary path lookup does. Paths are taken from the backend's root.
    IoResult!uint resolveAmbient(scope const(char)[] path) @safe nothrow @nogc
    {
        char[4096] pending, scratch;
        if (path.length > pending.length)
            return ioErr!uint(ErrorKind.nameTooLong, OpKind.resolve);
        pending[0 .. path.length] = path[];
        size_t length = path.length, pos;
        uint n = 0;
        size_t hops;
        while (true)
        {
            while (pos < length && pending[pos] == '/')
                ++pos;
            if (pos >= length)
                return ioOk(n);
            size_t end = pos;
            while (end < length && pending[end] != '/')
                ++end;
            const c = pending[pos .. end];
            pos = end;
            if (c == ".")
                continue;
            if (c == "..")
            {
                if (nodes[n].parent != none)
                    n = nodes[n].parent;
                continue;
            }
            if (nodes[n].kind != EntryKind.directory)
                return ioErr!uint(ErrorKind.notADirectory, OpKind.resolve);
            const next = find(n, c);
            if (next == none)
                return ioErr!uint(ErrorKind.notFound, OpKind.resolve);
            if (nodes[next].kind != EntryKind.symlink)
            {
                n = next;
                continue;
            }
            if (++hops > maxSymlinkHops)
                return ioErr!uint(ErrorKind.symlinkLoop, OpKind.resolve);
            const target = bytes[nodes[next].dataOffset
                .. nodes[next].dataOffset + nodes[next].dataLength];
            const total = target.length + 1 + (length - pos);
            if (total > pending.length)
                return ioErr!uint(ErrorKind.nameTooLong, OpKind.resolve);
            foreach (i, b; target)
                scratch[i] = cast(char) b;
            scratch[target.length] = '/';
            scratch[target.length + 1 .. total] = pending[pos .. length];
            pending[0 .. total] = scratch[0 .. total];
            length = total;
            pos = 0;
            if (target.length && target[0] == '/')
                n = 0;
        }
    }
}

version (unittest)
{
    /// A `MemVfs` over GC arenas, for tests that do not measure allocation.
    package MemVfs* testVfs(size_t nodeCount = 256, size_t byteCount = 1 << 16) @safe
    {
        auto v = new MemVfs(new MemNode[nodeCount], new ubyte[byteCount]);
        return v;
    }
}

@("vfs.mem.treeAndPrimitives")
@safe unittest
{
    import sparkles.base.vfs.types : OwnerOnly, sharingOf;

    auto v = testVfs();
    assert(v.writeFile("r/a/f", cast(const(ubyte)[]) "hello"));
    assert(v.symlink("r/s", "a"));
    assert(v.kindOf("r/a") == EntryKind.directory);
    assert(v.kindOf("r/s") == EntryKind.symlink);

    auto root = v.openRootDir("r");
    assert(!root.hasError);
    v.resetCounts();

    // VFM2: a successful single-name open is exactly one call.
    auto a = v.openDirAt(root.value, "a");
    assert(!a.hasError);
    assert(v.count(OpKind.openAt) == 1 && v.totalCalls == 1);

    // VFO2: the named link is never followed.
    assert(v.openDirAt(root.value, "s").error.kind == ErrorKind.symlinkRefused);
    assert(v.openDirAt(a.value, "f").error.kind == ErrorKind.notADirectory);
    assert(v.openDirAt(a.value, "x").error.kind == ErrorKind.notFound);

    auto f = v.openFileAt(a.value, "f", OpenMode.read, Sharing.init);
    ubyte[16] buf;
    assert(v.read(f.value, buf[]).value == 5);
    assert(buf[0 .. 5] == "hello");
    assert(!v.close(f.value).hasError);
    assert(v.close(f.value).hasError); // closes exactly once

    auto g = v.openFileAt(a.value, "g", OpenMode.createNew, sharingOf(OwnerOnly()));
    assert(!v.write(g.value, cast(const(ubyte)[]) "xyz").hasError);
    assert(v.contents("r/a/g") == "xyz");
    assert(v.sharingOf("r/a/g").kind == Sharing.Kind.ownerOnly);
    assert(v.openFileAt(a.value, "g", OpenMode.createNew, Sharing.init).error.kind
        == ErrorKind.exists);

    char[8] target;
    assert(v.readlinkAt(root.value, "s", target[]).value == 1);
    assert(target[0] == 'a');
    assert(v.readlinkAt(root.value, "s", target[0 .. 0]).error.kind == ErrorKind.bufferTooSmall);

    assert(v.rmdirAt(root.value, "a").error.kind == ErrorKind.notEmpty);
    assert(v.unlinkAt(root.value, "a").error.kind == ErrorKind.isADirectory);
    assert(!v.renameAt(a.value, "g", root.value, "moved").hasError);
    assert(v.exists("r/moved") && !v.exists("r/a/g"));

    v.close(g.value);
    v.close(a.value);
    v.close(root.value);
    assert(v.openHandles == 0);
}

@("vfs.mem.listingIsIndependent")
@safe unittest
{
    auto v = testVfs();
    foreach (name; ["d/x", "d/y", "d/z"])
        v.writeFile(name, null);
    auto d = v.openRootDir("d");
    auto l1 = v.openListing(d.value);
    auto l2 = v.openListing(d.value);
    char[16] buf;
    size_t len, seen1, seen2;
    EntryKind kind;
    while (v.nextEntry(l1.value, buf[], len, kind).value)
    {
        ++seen1;
        if (v.nextEntry(l2.value, buf[], len, kind).value)
            ++seen2;
    }
    while (v.nextEntry(l2.value, buf[], len, kind).value)
        ++seen2;
    assert(seen1 == 3 && seen2 == 3);
    v.closeListing(l1.value);
    v.closeListing(l2.value);
    v.close(d.value);
    assert(v.openHandles == 0);
}

@("vfs.mem.movedDirectoryKeepsItsHandle")
@safe unittest
{
    auto v = testVfs();
    v.mkdirs("r/a");
    auto r = v.openRootDir("r");
    assert(v.rename("r", "elsewhere/r"));
    assert(!v.openDirAt(r.value, "a").hasError); // R7: the handle names the node
}

@("vfs.mem.arena")
@safe unittest
{
    auto v = testVfs(3);
    auto root = v.openRootDir("");
    assert(!v.mkdirAt(root.value, "a", Sharing.init).hasError);
    assert(!v.mkdirAt(root.value, "b", Sharing.init).hasError);
    const before = v.liveNodes;
    auto full = v.mkdirAt(root.value, "c", Sharing.init);
    assert(full.error.kind == ErrorKind.other && full.error.context == "arena exhausted");
    assert(v.liveNodes == before && !v.exists("c"));
}

@("vfs.mem.hook")
@safe unittest
{
    auto v = testVfs();
    v.mkdirs("a/b");
    auto root = v.openRootDir("");
    v.resetCounts();
    size_t fired = size_t.max;
    v.hook = (size_t index, ref MemVfs fs) @safe nothrow @nogc {
        if (index == 1)
        {
            fired = index;
            fs.remove("a/b");
            fs.symlink("a/b", "/");
        }
    };
    auto a = v.openDirAt(root.value, "a");
    auto b = v.openDirAt(a.value, "b");
    assert(fired == 1);
    assert(b.error.kind == ErrorKind.symlinkRefused);
}

@("vfs.mem.mount")
@safe unittest
{
    auto v = testVfs();
    v.mkdirs("a/m/x");
    assert(v.mount("a/m"));
    auto root = v.openRootDir("a");
    const outer = v.statAt(root.value, "m", StatMask.basic).value.device;
    auto m = v.openDirAt(root.value, "m");
    const inner = v.fstat(m.value, StatMask.basic).value.device;
    const rootDevice = v.fstat(root.value, StatMask.basic).value.device;
    assert(outer == inner && inner != rootDevice);
}

@("vfs.mem.isVfs")
@safe pure nothrow @nogc unittest
{
    import sparkles.base.vfs.concept : hasWholePathResolver, isVfs;

    static assert(isVfs!MemVfs);
    static assert(!hasWholePathResolver!MemVfs);
    static struct MissingClose
    {
        alias Handle = MemVfs.Handle;
        alias Listing = MemVfs.Listing;
    }
    static assert(!isVfs!MissingClose);
}
