/**
Absence by directory listing (build-graph SPEC BGK2): a manifest's absent
candidates are tens of thousands of paths in a few hundred directories, most
of them missing, so a lookup decides them from each directory's listing
instead of one `stat` per candidate.

A listing is evidence only while it is current. $(LREF DirectoryListings)
keeps each directory's listing with the directory's identity, modification
and status-change times, and reuses it only while all three are unchanged
and the modification time predates the listing by BGK5's two seconds (a
file created in the same clock tick as the listing leaves the time as it
was). Otherwise it lists the directory again. A missing directory is looked
up again on every check, never remembered. Any error (a walk refused, a
listing that fails part-way, a directory that can be searched but not read)
answers `unknown`, and the caller then asks the file system for the path
itself.

Only Linux's file systems are taken to compare names byte for byte. On
macOS and Windows, where the default file systems fold case and Windows
paths have their own separators, every answer is `unknown`.
*/
module sparkles.build_graph.listings;

import sparkles.base.vfs.types : StatMask;

/// What a listing says of a name.
enum Presence
{
    absent,  /// the directory, as listed now, has no entry of that name
    present, /// it has one
    unknown, /// no listing can say: ask the file system
}

/// The listings one run reads (BGK2).
struct DirectoryListings
{
    private static struct Listing
    {
        ulong device, inode;
        long mtime, ctime, listedAt;
        bool[string] names;
    }

    private Listing[string] cache;
    // The directories this check already resolved: `checked[dir]` is true
    // when its listing in `cache` is current, false when it is missing.
    private bool[string] checked;

    /// A modification time this close to a listing does not vouch for it.
    enum long racyNs = 2_000_000_000L;

    /// Starts a check (one manifest's candidates): each directory is
    /// verified again once in it.
    void beginCheck() @safe pure nothrow
    {
        checked = null;
    }

    /**
    Whether `name` is in `dir`, a path beneath `root` (empty for `root`
    itself), as of now (`nowNs`, nanoseconds since the epoch).
    */
    Presence of(D)(ref D root, string dir, string name, long nowNs)
    {
        version (linux)
        {
            if (auto seen = dir in checked)
                return !*seen ? Presence.absent : name in cache[dir].names ? Presence.present : Presence.absent;
            if (!dir.length)
                return listed(root, dir, name, nowNs);
            auto d = root.walk(dir);
            if (d.hasError)
            {
                // ENOENT, ENOTDIR: no such directory, so no such entry.
                if (d.error.code == 2 || d.error.code == 20)
                {
                    checked[dir] = false;
                    return Presence.absent;
                }
                return Presence.unknown;
            }
            return listed(d.value, dir, name, nowNs);
        }
        else
            return Presence.unknown;
    }

    private Presence listed(D)(ref D d, string dir, string name, long nowNs)
    {
        enum mask = cast(StatMask)(StatMask.mtime | StatMask.identity | StatMask.change);
        auto st = d.stat(mask);
        if (st.hasError)
            return Presence.unknown;
        const s = st.value;
        auto have = dir in cache;
        const current = have !is null && have.device == s.device && have.inode == s.inode && have.mtime == s.mtimeNs
            && have.ctime == s.ctimeNs && s.mtimeNs < have.listedAt - racyNs && s.ctimeNs < have.listedAt - racyNs;
        if (!current)
        {
            Listing fresh = Listing(s.device, s.inode, s.mtimeNs, s.ctimeNs, nowNs);
            auto listing = d.list();
            if (listing.hasError)
            {
                cache.remove(dir);
                return Presence.unknown;
            }
            while (true)
            {
                auto more = listing.value.next();
                if (more.hasError)
                {
                    cache.remove(dir);
                    return Presence.unknown;
                }
                if (!more.value)
                    break;
                fresh.names[listing.value.front.name.idup] = true;
            }
            cache[dir] = fresh;
        }
        checked[dir] = true;
        return name in cache[dir].names ? Presence.present : Presence.absent;
    }
}

/// A listing answers for a directory until it changes: a file created in
/// a listed directory, in a directory that was missing, and in one whose
/// listing is racily recent is seen by the next check.
@("build_graph.listings.currentOnly")
@system unittest
{
    import std.datetime.systime : Clock, SysTime;
    import std.file : mkdirRecurse, rmdirRecurse, setTimes, tempDir, write;
    import std.path : buildPath;
    import std.process : thisProcessID;
    import std.conv : text;
    import sparkles.base.vfs.handles : ambientAuthority, openRoot;
    import sparkles.base.vfs.types : DotDotPolicy, ResolvePolicy, Rights, SymlinkPolicy;
    import sparkles.event_horizon.sys : BlockingVfs;
    import sparkles.test_runner.skip : skipTest;

    version (linux)
    {
        const top = buildPath(tempDir, text("sparkles-listings-", thisProcessID));
        mkdirRecurse(buildPath(top, "a"));
        scope (exit)
            rmdirRecurse(top);
        auto vfs = new BlockingVfs;
        auto root = openRoot!(Rights.readOnly)(vfs, top, ambientAuthority(),
            ResolvePolicy(SymlinkPolicy.beneath, DotDotPolicy.reject));
        assert(!root.hasError);
        long now() => (Clock.currStdTime - 621_355_968_000_000_000L) * 100;

        DirectoryListings l;
        l.beginCheck();
        assert(l.of(root.value, "a", "x.d", now) == Presence.absent);
        assert(l.of(root.value, "b", "y.d", now) == Presence.absent, "a missing directory");
        // A new file, within the racy window of the listing: the next check lists again.
        write(buildPath(top, "a", "x.d"), "");
        l.beginCheck();
        assert(l.of(root.value, "a", "x.d", now) == Presence.present);
        // The missing directory made since, with the file: seen.
        mkdirRecurse(buildPath(top, "b"));
        write(buildPath(top, "b", "y.d"), "");
        l.beginCheck();
        assert(l.of(root.value, "b", "y.d", now) == Presence.present);
        // An old, unchanged directory's listing is reused, and a change to it,
        // even one that restores the old modification time, is not missed.
        const old = SysTime(Clock.currStdTime - 100_000_000_000L); // 10 s ago
        setTimes(buildPath(top, "a"), old, old);
        l.beginCheck();
        assert(l.of(root.value, "a", "z.d", now) == Presence.absent);
        write(buildPath(top, "a", "z.d"), "");
        setTimes(buildPath(top, "a"), old, old); // the mtime as it was; the ctime moves
        l.beginCheck();
        assert(l.of(root.value, "a", "z.d", now) == Presence.present);
        // Within one check, a directory is verified once.
        assert(l.of(root.value, "a", "x.d", now) == Presence.present);
    }
    else
        skipTest("listings answer only on Linux");
}

/// A directory that can be searched but not listed gives no answer, so the
/// caller asks for the path itself.
@("build_graph.listings.unreadableIsUnknown")
@system unittest
{
    import core.sys.posix.unistd : geteuid;
    import std.conv : octal, text;
    import std.file : mkdirRecurse, rmdirRecurse, setAttributes, tempDir;
    import std.path : buildPath;
    import std.process : thisProcessID;
    import sparkles.base.vfs.handles : ambientAuthority, openRoot;
    import sparkles.base.vfs.types : DotDotPolicy, ResolvePolicy, Rights, SymlinkPolicy;
    import sparkles.event_horizon.sys : BlockingVfs;
    import sparkles.test_runner.skip : skipTest;

    version (linux)
    {
        if (geteuid() == 0)
            return skipTest("root lists any directory");
        const top = buildPath(tempDir, text("sparkles-listings-x-", thisProcessID));
        mkdirRecurse(buildPath(top, "s"));
        setAttributes(buildPath(top, "s"), octal!311);
        scope (exit)
        {
            setAttributes(buildPath(top, "s"), octal!755);
            rmdirRecurse(top);
        }
        auto vfs = new BlockingVfs;
        auto root = openRoot!(Rights.readOnly)(vfs, top, ambientAuthority(),
            ResolvePolicy(SymlinkPolicy.beneath, DotDotPolicy.reject));
        assert(!root.hasError);
        DirectoryListings l;
        l.beginCheck();
        assert(l.of(root.value, "s", "x.di", 0) == Presence.unknown);
    }
    else
        skipTest("listings answer only on Linux");
}
