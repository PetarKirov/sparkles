/**
The subtree cache (FSC1–FSC6): what one run of a Merkle fold learned,
handed to the next so that it can skip work. It is advisory: with the cache
deleted the next run gives the same id, only more slowly (FSC1).

A `MerkleFold` given a cache records, for each directory, the id it sealed
and each entry it encoded. For a file, that is the file's id, its size and
the `FsoFingerprint` of the `stat` the walk made before the file was read
(FSC2). The next run then reuses two kinds of work:

$(UL
$(LI $(B A file's id.) A file whose fingerprint the validator accepts is
    not read (FSC3).)
$(LI $(B A directory's id.) A directory is not encoded when every entry
    matches its record: the same names and kinds, every file accepted, every
    link's target the same, and every subdirectory's id the same as
    recorded (FSC4). Ids are content-derived, so a change anywhere beneath
    a directory changes a child id on the way up, and the reuse stops
    there, as git's `cache-tree` invalidates every directory above a
    changed path.)
)

`StatValidator` accepts a file when its whole fingerprint is unchanged (its
size, both times, its device and its inode) and its change time is safely
older than the moment the recording run began (FSC3). The second condition
is git's answer to racy-git. A file changed in the same timestamp tick as
the `stat` that recorded it keeps an identical fingerprint, so a file
recorded that close to its last change is read again next time. Its id is
still recorded, and the run after that one trusts it. A validator may
report a file as changed when it is not, because that only costs a read.
It may never report a changed file as unchanged when the change moved its
fingerprint (A9). A change that moves no part of it, such as a store
through a shared mapping to a page already dirty, is beyond what `stat`
can see, as it is for git (A24).

The stored form is `encode`'s bytes, which `load` reads back (FSC5). A
cache from another scheme, another layout or a damaged file is rejected
whole, never partly used: its checksum covers every byte, and a canary
tree, a fixed directory and file whose ids the current scheme computes
afresh, must come out the same as the cache recorded them (FSC6). The library
performs no I/O, so its caller reads and writes the bytes.

Specified in `docs/specs/build-primitives/filesets/SPEC.md`, FSC.
*/
module sparkles.build_primitives.content_addressing.cache;

import std.traits : fullyQualifiedName, hasIndirections;

import sparkles.base.buffer : HeapBuffer, Storage;
import sparkles.base.expected : Expected, err, ok;
import sparkles.base.hash.blake3 : Blake3, blake3;
import sparkles.base.text.errors : NoGcHook;
import sparkles.build_primitives.content_addressing.merkle : DefaultLeaf, MerkleFold, NoSupply;
import sparkles.build_primitives.fileset.fso : FsoFingerprint, FsoKind, precedes;

/**
The default validator: a file is unchanged when its fingerprint equals the
recorded one and the recorded change time is older than the recording run's
stamp by more than `marginNs` (FSC3).

The margin absorbs the distance between the clock a caller reads and the
one that stamps files. A file system's timestamps are coarse: the kernel's
coarse clock lags the precise one by a tick, and FAT records modification
times in two-second steps. Two seconds therefore covers both. A larger
margin only costs reads of recently changed files.
*/
struct StatValidator
{
    long marginNs = 2_000_000_000; ///

    /// Whether a file recorded as `recorded` by a run stamped `stampNs` is
    /// unchanged now that its `stat` reads `now`.
    bool unchanged(in FsoFingerprint recorded, in FsoFingerprint now, long stampNs)
        const @safe pure nothrow @nogc
        => recorded == now && recorded.ctimeNs < stampNs - marginNs;
}

/// Why `load` rejected a cache. Each rejection is whole: none of it is used.
enum CacheRejection : ubyte
{
    truncated,     /// shorter than its header and checksum say
    damaged,       /// its checksum or its structure does not hold
    otherFormat,   /// another format version, or another record layout
    otherScheme,   /// recorded by another directory encoding or file identity
}

/// What `load` returns: the directories loaded, or why none were.
alias CacheLoad = Expected!(size_t, CacheRejection, NoGcHook);

/**
The subtree cache of a `MerkleFold!(Dir, Leaf)`: the run it loaded, and the
run being recorded. `Validator` decides which files are unchanged; it is a
parameter so a test can substitute one that lies, and check that the
oracle catches it (PLAN M7).

One run is: `load` the previous run's bytes (optional), `begin` with a stamp,
resolve, and `encode` the new record. `load` and `begin` may come in either
order.
*/
struct SubtreeCache(Dir, Leaf, Validator = StatValidator)
{
    static assert(!hasIndirections!(Dir.Id) && !hasIndirections!(Leaf.Id),
        "a cached id is stored as its bytes, so it may hold no pointer");

    alias DirId = Dir.Id;   ///
    alias LeafId = Leaf.Id; ///

    Validator validator; ///

    /// What the current run reused and did, for a caller's statistics and a
    /// test's assertions.
    size_t filesReused, filesRead, dirsReused, dirsEncoded;

    private Table previous, next;
    private long previousStamp, stamp;
    private bool sealed;
    private uint openFirst;          // the open directory's first entry in `next`
    private uint openPath, openPathLength;

    /**
    Loads the run `bytes` recorded, replacing any loaded before. A rejected
    cache leaves none loaded, so the run reads everything.
    */
    CacheLoad load(scope const(ubyte)[] bytes)
    {
        previous.clear();
        previousStamp = 0;
        if (bytes.length < Header.sizeof + 32)
            return rejected(CacheRejection.truncated);
        Header[1] header;
        copyBytes(header[], bytes[0 .. Header.sizeof]);
        const h = header[0];
        if (h.magic != magic || h.version_ != formatVersion || h.dirSize != DirRecord.sizeof
            || h.entrySize != EntryRecord.sizeof)
            return rejected(CacheRejection.otherFormat);
        const ulong body = ulong(h.dirCount) * DirRecord.sizeof
            + ulong(h.entryCount) * EntryRecord.sizeof + h.textLength;
        if (bytes.length != Header.sizeof + body + 32)
            return rejected(CacheRejection.truncated);
        if (blake3(bytes[0 .. $ - 32]) != bytes[$ - 32 .. $])
            return rejected(CacheRejection.damaged);
        DirId dirCanary;
        LeafId leafCanary;
        canary(dirCanary, leafCanary);
        if (h.scheme != schemeTag || h.dirCanary != dirCanary || h.leafCanary != leafCanary)
            return rejected(CacheRejection.otherScheme);

        const dirsAt = Header.sizeof;
        const entriesAt = dirsAt + h.dirCount * DirRecord.sizeof;
        const textAt = entriesAt + h.entryCount * EntryRecord.sizeof;
        previous.dirs.length = h.dirCount;
        previous.entries.length = h.entryCount;
        previous.text.length = h.textLength;
        copyBytes(previous.dirs[], bytes[dirsAt .. entriesAt]);
        copyBytes(previous.entries[], bytes[entriesAt .. textAt]);
        copyBytes(previous.text[], bytes[textAt .. $ - 32]);
        if (!previous.wellFormed)
        {
            previous.clear();
            return rejected(CacheRejection.damaged);
        }
        previousStamp = h.stampNs;
        return ok!(CacheRejection, NoGcHook)(previous.dirs.length);
    }

    /**
    Starts recording a run. `stampNs` must be no later than the run's first
    `stat`, read from the clock that stamps the files' change times: the
    current time on a local file system, or the change time of a file just
    written to the same file system, as git takes its index file's. Without
    a `begin`, the stamp is zero and the next run trusts nothing recorded.
    */
    void begin(long stampNs)
    {
        next.clear();
        stamp = stampNs;
        sealed = false;
        filesReused = filesRead = dirsReused = dirsEncoded = 0;
    }

    /**
    Writes the run recorded since `begin` to `w`, an output range of
    `ubyte`s. It returns `false` and writes nothing when the run did not
    complete: a record of part of a run would not be wrong, but it is never
    needed.
    */
    bool encode(Writer)(ref Writer w)
    {
        import std.algorithm.sorting : sort;

        if (!sealed)
            return false;
        // Directories by path, so `load`'s lookup can bisect; their entries
        // keep their encoding order.
        auto order = HeapBuffer!(uint, Storage.unique)();
        foreach (i; 0 .. cast(uint) next.dirs.length)
            order ~= i;
        auto byPath = (uint a, uint b) => next.pathOf(next.dirs[a]) < next.pathOf(next.dirs[b]);
        sort!byPath(order[]);

        Header h;
        h.magic = magic;
        h.version_ = formatVersion;
        h.dirSize = DirRecord.sizeof;
        h.entrySize = EntryRecord.sizeof;
        h.scheme = schemeTag;
        canary(h.dirCanary, h.leafCanary);
        h.stampNs = stamp;
        h.dirCount = cast(uint) next.dirs.length;
        h.entryCount = cast(uint) next.entries.length;
        h.textLength = cast(uint) next.text.length;

        Blake3 sum;
        sum.start();
        void raw(T)(ref const T value)
        {
            const bytes = (() @trusted => (cast(const(ubyte)*) &value)[0 .. T.sizeof])();
            sum.put(bytes);
            w.put(bytes);
        }

        raw(h);
        uint first;
        foreach (i; order[])
        {
            DirRecord d = next.dirs[i];
            d.first = first;
            first += d.count;
            raw(d);
        }
        foreach (i; order[])
            foreach (ref e; next.entries[next.dirs[i].first .. next.dirs[i].first + next.dirs[i].count])
                raw(e);
        const text = (() @trusted => cast(const(ubyte)[]) next.text[])();
        sum.put(text);
        w.put(text);
        const ubyte[32] digest = sum.finish();
        w.put(digest[]);
        return true;
    }

    /// The number of directories the loaded run recorded.
    size_t loadedDirs() const => previous.dirs.length;

    // ── What `MerkleFold` calls ──────────────────────────────────────────

    /// The loaded record of the directory at `path`, or `noRecord`.
    package uint recorded(scope const(char)[] path) const
    {
        size_t lo = 0, hi = previous.dirs.length;
        while (lo < hi)
        {
            const mid = (lo + hi) / 2;
            const p = previous.pathOf(previous.dirs[mid]);
            if (p == path)
                return cast(uint) mid;
            if (p < path)
                lo = mid + 1;
            else
                hi = mid;
        }
        return noRecord;
    }

    /**
    Whether `entries`, a directory's in the scheme's order, match record
    `rec` entry for entry (FSC4). If they do, the record is carried into the
    new run and `id` and `holds` are the recorded ones.
    */
    package bool reuseDirectory(Entries)(uint rec, scope const(char)[] path, Entries entries,
        out DirId id, out bool holds)
    {
        if (rec == noRecord)
            return false;
        const d = previous.dirs[rec];
        const es = previous.entries[d.first .. d.first + d.count];
        size_t i;
        foreach (e; entries)
        {
            if (i == es.length || previous.nameOf(es[i]) != e.name || es[i].kind != e.node.kind)
                return false;
            const r = es[i++];
            final switch (e.node.kind)
            {
                case FsoKind.directory:
                    if (r.child != e.value.id || r.holds != e.value.holdsMember)
                        return false;
                    break;
                case FsoKind.symlink:
                    if (previous.targetOf(r) != e.node.target)
                        return false;
                    break;
                case FsoKind.regular:
                    if (!trusted(r, e.hasFingerprint, e.fingerprint) || r.executable != e.node.executable)
                        return false;
                    break;
            }
        }
        if (i != es.length)
            return false;
        id = d.id;
        holds = d.holds != 0;
        ++dirsReused;
        carry(rec, path);
        return true;
    }

    /// Starts recording the directory at `path`, whose entries follow.
    package void open(scope const(char)[] path)
    {
        openFirst = cast(uint) next.entries.length;
        openPath = next.append(path);
        openPathLength = cast(uint) path.length;
        ++dirsEncoded;
    }

    /**
    The id and size recorded for the file `e` in record `rec`, when the
    validator accepts its fingerprint (FSC3). `cursor` walks the record
    alongside the entries, which arrive in the order they were recorded in.
    */
    package bool reuseFile(Entry)(uint rec, ref uint cursor, ref const Entry e, out LeafId id,
        out ulong size)
    {
        if (rec == noRecord)
            return false;
        const d = previous.dirs[rec];
        while (cursor < d.count)
        {
            const r = &previous.entries[d.first + cursor];
            const name = previous.nameOf(*r);
            const kind = cast(FsoKind) r.kind;
            if (!precedes(Dir.order, name, kind, e.name, FsoKind.regular))
            {
                if (name != e.name || kind != FsoKind.regular)
                    return false;
                ++cursor;
                if (!trusted(*r, e.hasFingerprint, e.fingerprint)
                    || r.executable != e.node.executable)
                    return false;
                id = r.leaf;
                size = r.size;
                return true;
            }
            ++cursor;
        }
        return false;
    }

    /// Records a file of the open directory, read or reused.
    package void file(scope const(char)[] name, bool executable, bool hasFingerprint,
        in FsoFingerprint fp, ref const LeafId id, ulong size, bool reused)
    {
        EntryRecord r;
        r.kind = FsoKind.regular;
        r.flags = (executable ? flagExecutable : 0) | (hasFingerprint ? flagFingerprint : 0);
        r.fingerprint = fp;
        r.size = size;
        r.leaf = id;
        add(r, name);
        if (reused)
            ++filesReused;
        else
            ++filesRead;
    }

    /// Records a link of the open directory.
    package void symlink(scope const(char)[] name, scope const(char)[] target)
    {
        EntryRecord r;
        r.kind = FsoKind.symlink;
        r.target = next.append(target);
        r.targetLength = cast(uint) target.length;
        add(r, name);
    }

    /// Records a subdirectory of the open directory.
    package void directory(scope const(char)[] name, ref const DirId child, bool holds)
    {
        EntryRecord r;
        r.kind = FsoKind.directory;
        r.flags = holds ? flagHolds : 0;
        r.child = child;
        add(r, name);
    }

    /// Ends the open directory with the id it sealed.
    package void close(ref const DirId id, bool holds)
    {
        DirRecord d;
        d.path = openPath;
        d.pathLength = openPathLength;
        d.first = openFirst;
        d.count = cast(uint)(next.entries.length - openFirst);
        d.id = id;
        d.holds = holds;
        next.dirs ~= d;
    }

    /// Marks the run complete: its fileset root's value is computed.
    package void seal()
    {
        sealed = true;
    }

private:
    enum ubyte[8] magic = ['S', 'P', 'K', 'S', 'T', 'C', 'v', '1'];
    enum uint formatVersion = 1;
    enum uint noRecord = uint.max;
    enum ubyte flagExecutable = 1, flagFingerprint = 2, flagHolds = 4;

    // Which encoding and identity recorded a cache. A renamed type only
    // costs a cold run; a changed encoding under the same name is caught by
    // the canary.
    static ubyte[32] schemeTag() => blake3(fullyQualifiedName!Dir ~ "|" ~ fullyQualifiedName!Leaf);

    // Fills `to` with `from`, which holds exactly its bytes. Every record is
    // checked (`wellFormed`) before it is used, and none holds a pointer.
    static void copyBytes(T)(T[] to, scope const(ubyte)[] from)
    in (from.length == to.length * T.sizeof)
    {
        static assert(!hasIndirections!T);
        (() @trusted => (cast(ubyte[]) to)[] = from[])();
    }

    static struct Header
    {
        ubyte[8] magic;
        uint version_;
        uint dirSize, entrySize;
        ubyte[32] scheme;
        DirId dirCanary;
        LeafId leafCanary;
        long stampNs;
        uint dirCount, entryCount, textLength;
    }

    static struct DirRecord
    {
        uint path, pathLength;   // into the text
        uint first, count;       // into the entries
        DirId id;
        bool holds() const => holdsByte != 0;
        void holds(bool b) { holdsByte = b; }
        ubyte holdsByte;
    }

    static struct EntryRecord
    {
        uint name, nameLength;     // into the text
        uint target, targetLength; // a link's
        ubyte kind;                // an FsoKind
        ubyte flags;
        FsoFingerprint fingerprint; // a file's
        ulong size;                 // a file's
        LeafId leaf;                // a file's
        DirId child;                // a subdirectory's

        bool executable() const => (flags & flagExecutable) != 0;
        bool hasFingerprint() const => (flags & flagFingerprint) != 0;
        bool holds() const => (flags & flagHolds) != 0;
    }

    static struct Table
    {
        HeapBuffer!(DirRecord, Storage.unique) dirs;
        HeapBuffer!(EntryRecord, Storage.unique) entries;
        HeapBuffer!(char, Storage.unique) text;

        void clear()
        {
            dirs.clear();
            entries.clear();
            text.clear();
        }

        uint append(scope const(char)[] s)
        {
            const at = cast(uint) text.length;
            text ~= s;
            return at;
        }

        const(char)[] pathOf(ref const DirRecord d) const return
            => text[d.path .. d.path + d.pathLength];
        const(char)[] nameOf(ref const EntryRecord e) const return
            => text[e.name .. e.name + e.nameLength];
        const(char)[] targetOf(ref const EntryRecord e) const return
            => text[e.target .. e.target + e.targetLength];

        // Every span lies in the text and every directory's entries in the
        // entries, every kind and flag is one this format writes, and the
        // directories are sorted by path, with no path twice.
        bool wellFormed() const
        {
            bool within(ulong at, ulong length, ulong limit) => at <= limit && length <= limit - at;

            foreach (i, ref d; dirs[])
            {
                if (!within(d.path, d.pathLength, text.length) || !within(d.first, d.count, entries.length)
                    || d.holdsByte > 1)
                    return false;
                if (i && !(pathOf(dirs[i - 1]) < pathOf(d)))
                    return false;
            }
            foreach (ref e; entries[])
                if (!within(e.name, e.nameLength, text.length) || !within(e.target, e.targetLength, text.length)
                    || e.kind > FsoKind.max || e.flags > (flagExecutable | flagFingerprint | flagHolds))
                    return false;
            return true;
        }
    }

    static CacheLoad rejected(CacheRejection why) => err!(size_t, NoGcHook)(why);

    // Ids the current scheme gives a fixed tree: a directory holding a file
    // and a link, beside an executable file. A cache whose canary differs
    // was recorded by an encoding that names trees differently.
    static void canary(out DirId dirId, out LeafId leafId)
    {
        static immutable ubyte[] content = cast(immutable(ubyte)[]) "subtree cache canary\n";
        Leaf leaf;
        leaf.start(content.length);
        leaf.put(content);
        leafId = leaf.finish();
        Dir dir;
        dir.begin();
        dir.file("a", false, leafId, content.length);
        dir.symlink("b", "a");
        const inner = dir.seal();
        dir.begin();
        dir.directory("c", inner);
        dir.file("x", true, leafId, content.length);
        dirId = dir.seal();
    }

    bool trusted(ref const EntryRecord r, bool hasFingerprint, in FsoFingerprint now) const
        => r.hasFingerprint && hasFingerprint && validator.unchanged(r.fingerprint, now, previousStamp);

    void add(ref EntryRecord r, scope const(char)[] name)
    {
        r.name = next.append(name);
        r.nameLength = cast(uint) name.length;
        next.entries ~= r;
    }

    // Copies record `rec` of the loaded run, with its entries, into the new
    // one, at `path`.
    void carry(uint rec, scope const(char)[] path)
    {
        const d = previous.dirs[rec];
        open(path);
        --dirsEncoded;
        foreach (ref const e; previous.entries[d.first .. d.first + d.count])
        {
            EntryRecord r = e;
            if (r.kind == FsoKind.symlink)
            {
                r.target = next.append(previous.targetOf(e));
                r.targetLength = e.targetLength;
            }
            add(r, previous.nameOf(e));
            if (r.kind == FsoKind.regular)
                ++filesReused;
        }
        close(d.id, d.holds);
    }
}

/// A Merkle fold that keeps a subtree cache: `fold.cache` loads the
/// previous run and records this one.
alias CachedFold(Dir, Leaf = DefaultLeaf!Dir, Validator = StatValidator) =
    MerkleFold!(Dir, Leaf, NoSupply, SubtreeCache!(Dir, Leaf, Validator));
