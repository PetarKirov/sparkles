/**
Absence by directory listing (build-graph SPEC BGK2): a manifest's absent
candidates are tens of thousands of paths in a few hundred directories, most
of them missing, so a lookup decides them from each directory's listing
instead of one `stat` per candidate.

A listing is evidence only while it is current. $(LREF DirectoryListings)
keeps each directory's listing with the directory's identity, modification
and status-change times, and reuses it only while all three are unchanged,
the directory lies on the file system whose clock the run read, and both
times predate that clock by BGK5's two seconds (a file created in the same
clock tick as the listing leaves the times as they were). Otherwise it lists
the directory again. A missing directory is looked up again on every check,
never remembered. Any error (an open refused, a symbolic link on the way, a
listing that fails part-way, a directory that can be searched but not read)
answers `unknown`, and the caller then asks the file system for the path
itself.

Only Linux's file systems are taken to compare names byte for byte. On
macOS and Windows, where the default file systems fold case and Windows
paths have their own separators, every answer is `unknown`.
*/
module sparkles.build_graph.listings;

import core.lifetime : move;

import sparkles.base.io.errors : ErrorKind;
import sparkles.base.vfs.types : StatMask;

/// What a listing says of a name.
enum Presence
{
    absent,  /// the directory, as listed now, has no entry of that name
    present, /// it has one
    unknown, /// no listing can say: ask the file system
}

/**
BGK5: the clock a listing is dated by, as the file system the run's store
lies on keeps it (the mtime of a file written as the run began), and that
file system's device. A listing of a directory on another device, or with
no clock, is never reused.
*/
struct ListingClock
{
    bool known;   ///
    long nowNs;   /// nanoseconds since the epoch
    ulong device; ///
}

/**
The listings one run reads (BGK2) through directory handles of type `D`,
validated parent first: a directory's entry stands while its parent's does
and the directory itself is unchanged (its identity, modification and
status-change times, with BGK5's margin). Renaming a directory into place
changes its parent's modification time, so a parent that is unchanged still
names the same child. A directory a current parent does not list is absent
without being looked up, which answers most candidates of a search: the
roots that hold no such package.

Each directory is opened from its parent's handle, never through a symbolic
link (one on the way answers `unknown`), and its handle kept while the
process's budget allows (`heldBudget`); past that it is opened again from its
parent's when it is checked. A check verifies each directory once. $(LREF
close) closes every handle kept; the owner calls it before the backend the
handles use goes.
*/
struct DirectoryListings(D)
{
    /// A modification time this close to the clock does not vouch for a listing.
    enum long racyNs = 2_000_000_000L;

    private static final class Entry
    {
        D dir;                  // kept open when `held`
        bool held;
        ulong device, inode;
        long mtime, ctime, listedAt;
        bool vouched;           // whether `listedAt` is a clock reading
        bool[string] names;
        ulong generation;       // unique to each listing this instance made
        ulong parentGeneration; // the parent's, when this entry was validated
    }

    private enum State : ubyte { current, missing, unknown }

    private Entry[string] cache;   // by root ~ "\0" ~ directory
    private State[string] checked; // this check's answers
    private ulong nextGeneration;

    /// Starts a check (one manifest's candidates): each directory is
    /// verified again once in it.
    void beginCheck() @safe pure nothrow
    {
        checked = null;
    }

    /// Closes every handle kept and forgets every listing.
    void close()
    {
        foreach (e; cache)
            release(e);
        cache = null;
        checked = null;
    }

    /**
    Whether `name` is in `dir`, a normalized `/`-separated path beneath
    `root` (empty for `root` itself, no `.` or `..` component), dated by
    `clock`. `rootName` tells one root's directories from another's.
    */
    Presence of(ref D root, string dir, string name, ListingClock clock, string rootName = null)
    {
        version (linux)
        {
            Entry e;
            final switch (current(root, rootName, dir, clock, e))
            {
            case State.current:
                return name in e.names ? Presence.present : Presence.absent;
            case State.missing:
                return Presence.absent;
            case State.unknown:
                return Presence.unknown;
            }
        }
        else
            return Presence.unknown;
    }

    private State current(ref D root, string rootName, string dir, ListingClock clock, out Entry e)
    {
        const key = rootName ~ "\0" ~ dir;
        if (auto seen = key in checked)
        {
            if (*seen == State.current)
                e = cache[key];
            return *seen;
        }
        State answer(State s)
        {
            checked[key] = s;
            if (s != State.current)
                forget(key);
            return s;
        }
        if (!dir.length)
        {
            // The root itself: validated by the caller's handle.
            e = key in cache ? cache[key] : new Entry;
            cache[key] = e;
            return answer(validate(root, e, clock, 0) ? State.current : State.unknown);
        }
        size_t slash = dir.length;
        while (slash > 0 && dir[slash - 1] != '/')
            --slash;
        const parentDir = slash ? dir[0 .. slash - 1] : "";
        const base = dir[slash .. $];
        if (!base.length || base == "." || base == ".." || (slash && !parentDir.length))
            return answer(State.unknown); // not normalized: no listing names it
        Entry parent;
        const p = current(root, rootName, parentDir, clock, parent);
        if (p != State.current)
            return answer(p);
        if (base !in parent.names)
            return answer(State.missing);
        auto have = key in cache;
        e = have !is null ? *have : null;
        if (e !is null && e.held && e.parentGeneration == parent.generation)
            return answer(validate(e.dir, e, clock, parent.generation) ? State.current : State.unknown);
        // Opened from its parent's handle, or one entry at a time from the
        // root when the parent keeps none: never through a link.
        auto opened = parent.held ? parent.dir.openDir(base) : openBeneath(root, dir);
        if (opened.hasError)
        {
            const k = opened.error.kind;
            return answer(k == ErrorKind.notFound || k == ErrorKind.notADirectory ? State.missing : State.unknown);
        }
        if (e is null)
        {
            e = new Entry;
            cache[key] = e;
        }
        if (e.held || take())
        {
            e.dir = move(opened.value);
            e.held = true;
            return answer(validate(e.dir, e, clock, parent.generation) ? State.current : State.unknown);
        }
        auto dirNow = move(opened.value);
        return answer(validate(dirNow, e, clock, parent.generation) ? State.current : State.unknown);
    }

    // `dir` opened from `root` one entry at a time, refusing links.
    private static auto openBeneath(ref D root, string dir)
    {
        size_t start;
        size_t end = 0;
        while (end < dir.length && dir[end] != '/')
            ++end;
        auto d = root.openDir(dir[0 .. end]);
        while (!d.hasError && end < dir.length)
        {
            start = end + 1;
            end = start;
            while (end < dir.length && dir[end] != '/')
                ++end;
            d = d.value.openDir(dir[start .. end]);
        }
        return d;
    }

    // Forgets `key`'s listing and every one beneath it, closing their handles:
    // a directory gone or unknown vouches for nothing below it. An entry is
    // made only beneath a current one, so a directory never listed has none
    // beneath it, and the common answer, a directory its parent lacks, costs
    // no scan.
    private void forget(string key)
    {
        auto gone = key in cache;
        if (gone is null)
            return;
        release(*gone);
        cache.remove(key);
        const prefix = key[$ - 1] == '\0' ? key : key ~ "/"; // the root's: every key of its root
        string[] below;
        foreach (k, _; cache)
            if (k.length > prefix.length && k[0 .. prefix.length] == prefix)
                below ~= k;
        foreach (k; below)
        {
            release(cache[k]);
            cache.remove(k);
        }
    }

    private static void release(Entry e)
    {
        if (e.held)
        {
            destroy(e.dir);
            e.held = false;
            give();
        }
    }

    // Validates `e` against the open directory `d`, listing it again when it
    // changed or its listing is not vouched for; false when that cannot be done.
    private bool validate(H)(ref H d, Entry e, ListingClock clock, ulong parentGeneration)
    {
        enum mask = cast(StatMask)(StatMask.mtime | StatMask.identity | StatMask.change);
        auto st = d.stat(mask);
        if (st.hasError || !st.value.hasMtime || !st.value.hasIdentity || !st.value.hasCtime)
            return false;
        const s = st.value;
        const same = e.generation != 0 && e.vouched && !s.ctimeSettable && e.device == s.device
            && e.inode == s.inode && e.mtime == s.mtimeNs && e.ctime == s.ctimeNs
            && s.mtimeNs < e.listedAt - racyNs && s.ctimeNs < e.listedAt - racyNs;
        e.parentGeneration = parentGeneration;
        if (same)
            return true;
        auto listing = d.list();
        if (listing.hasError)
            return false;
        bool[string] names;
        while (true)
        {
            auto more = listing.value.next();
            if (more.hasError)
                return false;
            if (!more.value)
                break;
            names[listing.value.front.name.idup] = true;
        }
        e.device = s.device;
        e.inode = s.inode;
        e.mtime = s.mtimeNs;
        e.ctime = s.ctimeNs;
        // Dated by the clock read before the listing: a change after it
        // carries a later time, and so does one in the same tick.
        e.vouched = clock.known && s.device == clock.device;
        e.listedAt = clock.nowNs;
        e.names = names;
        e.generation = ++nextGeneration;
        return true;
    }
}

// ── the process's budget of kept handles, shared by every instance: a run
// across worktrees keeps several drivers, and the process's descriptor
// limit is one ──────────────────────────────────────────────────────────────

private shared size_t heldNow;
private shared size_t budget; // 0 until first asked

/// The most directory handles all listings keep open at once: a quarter of
/// the process's soft descriptor limit, at most 512.
size_t heldBudget() @trusted nothrow @nogc
{
    import core.atomic : atomicLoad, atomicStore;

    auto b = atomicLoad(budget);
    if (b)
        return b;
    b = 64;
    version (Posix)
    {
        import core.sys.posix.sys.resource : getrlimit, rlimit, RLIMIT_NOFILE;

        rlimit r;
        if (getrlimit(RLIMIT_NOFILE, &r) == 0)
            b = r.rlim_cur / 4 > 512 ? 512 : r.rlim_cur / 4 < 16 ? 16 : cast(size_t)(r.rlim_cur / 4);
    }
    atomicStore(budget, b);
    return b;
}

// Takes a slot of the budget; false when none is free.
private bool take() @safe nothrow @nogc
{
    import core.atomic : atomicLoad, cas;

    const limit = heldBudget();
    for (;;)
    {
        const n = atomicLoad(heldNow);
        if (n >= limit)
            return false;
        if (cas(&heldNow, n, n + 1))
            return true;
    }
}

private void give() @safe nothrow @nogc
{
    import core.atomic : atomicOp;

    atomicOp!"-="(heldNow, 1);
}

/// Parent first, on a memory file system whose clock the test moves: a
/// listing old by the clock is reused without a listing, a directory its
/// parent lacks is absent without an open, a directory replaced by a rename,
/// one beneath a replaced parent and one created since are seen, a link on
/// the way gives no answer, and a listing on another device, racily recent or
/// without a clock is listed again.
@("build_graph.listings.memory")
@safe unittest
{
    import sparkles.base.io.errors : OpKind;
    import sparkles.base.vfs.handles : Dir, ambientAuthority, openRoot;
    import sparkles.base.vfs.mem : MemNode, MemVfs;
    import sparkles.base.vfs.types : DotDotPolicy, ResolvePolicy, Rights, SymlinkPolicy;
    import sparkles.test_runner.skip : skipTest;

    version (linux)
    {
        enum long s = 1_000_000_000L;
        auto vfs = new MemVfs(new MemNode[64], new ubyte[4096]);
        vfs.clockNs = 1 * s;
        assert(vfs.mkdirs("top/a/b") && vfs.mkdirs("top/a/d"));
        assert(vfs.writeFile("top/a/b/x.d", null));
        auto root = openRoot!(Rights.readOnly)(vfs, "top", ambientAuthority(),
            ResolvePolicy(SymlinkPolicy.beneath, DotDotPolicy.reject));
        assert(!root.hasError);
        auto clock = ListingClock(true, 100 * s, 1);

        DirectoryListings!(Dir!(MemVfs, Rights.readOnly)) l;
        scope (exit)
            l.close();
        l.beginCheck();
        assert(l.of(root.value, "a/b", "x.d", clock) == Presence.present);
        assert(l.of(root.value, "a/b", "y.d", clock) == Presence.absent);

        // Unchanged and old by the clock: kept handles stat'ed, nothing opened or listed.
        vfs.resetCounts();
        l.beginCheck();
        assert(l.of(root.value, "a/b", "x.d", clock) == Presence.present);
        assert(l.of(root.value, "a/missing/deeper", "y.d", clock) == Presence.absent);
        assert(vfs.count(OpKind.openAt) == 0 && vfs.count(OpKind.readDir) == 0, "a current listing is reused");

        // A directory replaced by a rename, at a time after the clock: listed anew.
        vfs.clockNs = 200 * s;
        assert(vfs.rename("top/a/b", "top/a/c") && vfs.mkdirs("top/a/b"));
        l.beginCheck();
        assert(l.of(root.value, "a/b", "x.d", clock) == Presence.absent, "the replaced directory");
        assert(l.of(root.value, "a/c", "x.d", clock) == Presence.present);

        // The parent replaced: everything beneath it is read again.
        assert(vfs.rename("top/a", "top/old") && vfs.mkdirs("top/a/b") && vfs.writeFile("top/a/b/x.d", null));
        l.beginCheck();
        assert(l.of(root.value, "a/b", "x.d", clock) == Presence.present, "beneath a replaced parent");
        assert(l.of(root.value, "a/d", "x.d", clock) == Presence.absent);

        // A link on the way: no answer, so the caller asks for the path.
        assert(vfs.symlink("top/a/l", "b"));
        l.beginCheck();
        assert(l.of(root.value, "a/l", "x.d", clock) == Presence.unknown);
        assert(l.of(root.value, "a/./b", "x.d", clock) == Presence.unknown, "an unnormalized path");

        // Racily recent by the clock (the clock reads 201 s, the times 200 s):
        // listed on every check, and a file made in the same tick is seen.
        clock.nowNs = 201 * s;
        l.beginCheck();
        assert(l.of(root.value, "a/b", "y.d", clock) == Presence.absent);
        assert(vfs.writeFile("top/a/b/y.d", null));
        l.beginCheck();
        assert(l.of(root.value, "a/b", "y.d", clock) == Presence.present, "a file made in the listing's tick");

        // Another device, or no clock: listed on every check.
        foreach (other; [ListingClock(true, 1000 * s, 2), ListingClock.init])
        {
            l.beginCheck();
            cast(void) l.of(root.value, "a/b", "y.d", other);
            vfs.resetCounts();
            l.beginCheck();
            assert(l.of(root.value, "a/b", "y.d", other) == Presence.present);
            assert(vfs.count(OpKind.readDir) > 0, "a listing no clock vouches for is not reused");
        }
    }
    else
        skipTest("listings answer only on Linux");
}

/// On a real file system: a file created in a listed directory and in a
/// directory that was missing is seen by the next check, and a directory
/// that can be searched but not read gives no answer.
@("build_graph.listings.currentOnly")
@system unittest
{
    import core.sys.posix.unistd : geteuid;
    import std.conv : octal, text;
    import std.file : mkdirRecurse, rmdirRecurse, setAttributes, tempDir, write;
    import std.path : buildPath;
    import std.process : thisProcessID;
    import sparkles.base.vfs.handles : Dir, ambientAuthority, openRoot;
    import sparkles.base.vfs.types : DotDotPolicy, ResolvePolicy, Rights, SymlinkPolicy;
    import sparkles.event_horizon.sys : BlockingVfs;
    import sparkles.test_runner.skip : skipTest;

    version (linux)
    {
        const top = buildPath(tempDir, text("sparkles-listings-", thisProcessID));
        mkdirRecurse(buildPath(top, "a"));
        mkdirRecurse(buildPath(top, "s"));
        scope (exit)
        {
            setAttributes(buildPath(top, "s"), octal!755);
            rmdirRecurse(top);
        }
        write(buildPath(top, "clock"), "");
        auto vfs = new BlockingVfs;
        auto root = openRoot!(Rights.readOnly)(vfs, top, ambientAuthority(),
            ResolvePolicy(SymlinkPolicy.beneath, DotDotPolicy.reject));
        assert(!root.hasError);
        auto probe = root.value.statAt("clock", StatMask.mtime);
        assert(!probe.hasError);
        const clock = ListingClock(true, probe.value.mtimeNs, probe.value.device);

        DirectoryListings!(Dir!(BlockingVfs, Rights.readOnly)) l;
        scope (exit)
            l.close();
        l.beginCheck();
        assert(l.of(root.value, "a", "x.d", clock) == Presence.absent);
        assert(l.of(root.value, "b", "y.d", clock) == Presence.absent, "a missing directory");
        write(buildPath(top, "a", "x.d"), "");
        mkdirRecurse(buildPath(top, "b"));
        write(buildPath(top, "b", "y.d"), "");
        l.beginCheck();
        assert(l.of(root.value, "a", "x.d", clock) == Presence.present);
        assert(l.of(root.value, "b", "y.d", clock) == Presence.present);
        if (geteuid() == 0)
            return skipTest("root lists any directory");
        setAttributes(buildPath(top, "s"), octal!311);
        l.beginCheck();
        assert(l.of(root.value, "s", "x.di", clock) == Presence.unknown);
    }
    else
        skipTest("listings answer only on Linux");
}
