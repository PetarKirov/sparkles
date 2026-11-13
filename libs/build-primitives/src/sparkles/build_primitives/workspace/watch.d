/++
A watch of input sets
([design BGW13–BGW15](../../../../../../docs/specs/build-primitives/build-graph/fileset-native-workspace.md)):
the directories a materialization lists are watched before they are
listed, and the notes the watcher delivers become change sets.

A $(LREF WatchSession) owns a $(REF TreeWatcher, sparkles,event_horizon,tree_watch)
and the map from its tokens to repository-relative directories.
$(LREF WatchSession.materialize) observes a set (BGW9) with a hook that
watches each directory just before it is listed, and checks, once it is,
that the handle listed is the directory the watch found: a rename between
the two is a loss. A start root that does not exist is watched through its
nearest existing ancestor, for the creation of the next component.
Directories no longer listed are no longer watched.

$(LREF WatchSession.changes) turns a batch of notes into a
$(REF ChangeSet, sparkles,build_primitives,workspace,input_state). A note
naming a file the set cannot hold is dropped without a system call; one
naming a directory is judged by the set's verdict on the directory. An
overflow, a lost watch, a watch the host refused and a mismatched identity
each make the change set lossy, and a consumer then materializes every set
again (BGW13), through the digest cache, so only the files whose fingerprint
moved are read.
+/
module sparkles.build_primitives.workspace.watch;

import core.time : Duration;

import sparkles.event_horizon.tree_watch : TreeWatcher, WatchedDir, WatchNote, WatchNoteKind;

import sparkles.build_primitives.fileset.value : Fileset, FilesetEvaluator, Filesets;
import sparkles.build_primitives.workspace.input_state : ChangeKind, ChangeSet, ListingHooks, Observed,
    PathChange, observe;

/// A watch of one fileset beneath one root.
struct WatchSession
{
    @disable this(this);

    /**
    Starts a watcher for the tree at the absolute path `rootPath`, the path
    the watcher resolves directories under, with the process's ambient
    authority.
    */
    static WatchSession open(string rootPath)
    {
        WatchSession s;
        s.rootPath_ = rootPath;
        s.watcher_ = new TreeWatcher;
        s.failed_ = TreeWatcher.create(*s.watcher_).hasError;
        return s;
    }

    /// Whether the watcher could not start: every change set is lossy, and
    /// a caller rescans on a timer (D50).
    bool degraded() const @safe pure nothrow @nogc => failed_ || refused_;

    /**
    Materializes `set` of `sets` beneath `root` through `cache` on `exec`,
    watching each directory before it is listed (BGW14), and returns its
    input state. Watches of directories it no longer lists end.
    */
    Observed materialize(DirRef, Cache, Exec)(DirRef root, ref const Filesets sets, Fileset set,
        ref Cache cache, ref Exec exec)
    {
        import sparkles.base.vfs.handles : ambientAuthority;
        import sparkles.build_primitives.fileset.plan : plan;

        bool[string] now;
        ListingHooks hooks;
        hooks.before = (scope const(char)[] path) {
            const p = path.idup;
            if (watchDir(p))
                now[p] = true;
            return true;
        };
        hooks.listed = (scope const(char)[] path, ulong device, ulong inode) {
            if (auto w = path in watched_)
                if (w.device != device || w.inode != inode)
                    pendingLoss_ = true; // the watch and the listing name different directories
        };
        auto got = observe(root, sets, set, cache, exec, hooks);

        // A start root that does not exist: its nearest existing ancestor,
        // for the next component's creation.
        missing_ = null;
        if (!failed_)
        {
            const roots = plan(sets, set);
            foreach (i; 0 .. roots.length)
            {
                const r = roots[i].idup;
                if (r in now)
                    continue;
                string at = r;
                while (at.length && !isDirectory(at))
                    at = parentOf(at);
                if (at.length && at == r)
                    continue; // it exists, and the set rules it out
                missing_ ~= r;
                if (watchDir(at))
                    now[at] = true;
            }
        }

        // Directories no longer listed are no longer watched.
        string[] gone;
        foreach (path, ref w; watched_)
            if (path !in now)
                gone ~= path;
        foreach (path; gone)
        {
            const token = watched_[path].token;
            watcher_.unwatch(token);
            dirOf_.remove(token);
            watched_.remove(path);
        }
        sets_ = &sets;
        set_ = set;
        return got;
    }

    /**
    The change set a batch of `notes` makes, relative to the root: each
    path once, sorted, a note naming nothing the set may hold dropped. Lossy
    after an overflow, a lost watch, a refused watch or a mismatched
    identity since the last call.
    */
    ChangeSet changes(scope const(WatchNote)[] notes)
    {
        ChangeSet cs;
        cs.lossy = pendingLoss_ || degraded;
        pendingLoss_ = false;
        if (sets_ is null)
            return cs;
        auto ev = FilesetEvaluator(*sets_, set_);
        ChangeKind[string] seen;
        foreach (n; notes)
        {
            final switch (n.kind)
            {
                case WatchNoteKind.overflow:
                case WatchNoteKind.lost:
                    cs.lossy = true;
                    continue;
                case WatchNoteKind.created:
                case WatchNoteKind.removed:
                case WatchNoteKind.modified:
                    break;
            }
            auto dir = n.token in dirOf_;
            if (dir is null)
                continue; // a token unwatched since
            const path = dir.length ? *dir ~ "/" ~ n.name : n.name;
            // A watched directory whose name is removed was deleted or moved.
            // inotify also loses its watch, but Windows goes on watching it
            // under its new name and says so only here, through the parent.
            if (n.kind == WatchNoteKind.removed && path in watched_)
                cs.lossy = true;
            // A directory by the verdict on the directory; a removed name
            // may have been either, and a host that cannot tell says no.
            const mayDir = n.isDir || n.kind == WatchNoteKind.removed;
            const held = ev.mayHoldFile(*sets_, path) || (mayDir && ev.mayHoldTree(*sets_, path))
                || leadsToMissing(path);
            if (!held)
                continue;
            const kind = n.kind == WatchNoteKind.created ? ChangeKind.created
                : n.kind == WatchNoteKind.removed ? ChangeKind.removed : ChangeKind.modified;
            if (auto k = path in seen)
            {
                // A creation then a write is still a creation.
                if (!(*k == ChangeKind.created && kind == ChangeKind.modified))
                    *k = kind;
            }
            else
                seen[path] = kind;
        }
        foreach (path, kind; seen)
            cs.paths ~= PathChange(path, kind);
        import std.algorithm.sorting : sort;

        cs.paths.sort!((a, b) => a.path < b.path);
        return cs;
    }

    /// Waits for the next batch of notes, gathered until `quiet` passes with
    /// nothing new; with a positive `timeout`, an empty batch when none
    /// arrives in time. Empty, too, when the watcher could not start.
    WatchNote[] nextBatch(Duration quiet, Duration timeout = Duration.zero)
    {
        if (failed_)
        {
            import core.thread : Thread;

            Thread.sleep(timeout);
            return null;
        }
        auto got = watcher_.nextBatch(quiet, timeout);
        return got.hasValue ? got.value : [WatchNote(0, WatchNoteKind.lost)];
    }

    /// The directories watched, relative to the root, sorted.
    string[] watchedDirectories() const
    {
        import std.algorithm.sorting : sort;

        string[] dirs;
        foreach (path, _; watched_)
            dirs ~= path;
        dirs.sort();
        return dirs;
    }

    /// Ends every watch and the watcher's thread.
    void close()
    {
        if (watcher_ !is null)
            watcher_.close();
    }

private:
    string rootPath_;
    TreeWatcher* watcher_;
    bool failed_, refused_, pendingLoss_;
    WatchedDir[string] watched_; // by repository-relative directory
    string[uint] dirOf_;         // by token
    string[] missing_;           // start roots that do not exist
    const(Filesets)* sets_;
    Fileset set_;

    string absolute(string path) const => path.length ? rootPath_ ~ "/" ~ path : rootPath_;

    // Whether `path` is watched now.
    bool watchDir(string path)
    {
        import core.stdc.errno : ENOENT, ENOSPC, ENOTDIR;
        import sparkles.base.vfs.handles : ambientAuthority;

        if (failed_)
            return false;
        if (path in watched_)
            return true;
        auto w = watcher_.watch(absolute(path), ambientAuthority());
        if (w.hasError)
        {
            // Refused for want of capacity: degraded for good. Not there:
            // a start root nobody created, watched through an ancestor.
            // Anything else may hide a change.
            if (w.error.code == ENOSPC)
                refused_ = true;
            if (w.error.code != ENOENT && w.error.code != ENOTDIR)
                pendingLoss_ = true;
            return false;
        }
        watched_[path] = w.value;
        dirOf_[w.value.token] = path;
        return true;
    }

    bool isDirectory(string path) const
    {
        import std.file : exists, isDir;

        const p = absolute(path);
        try
            return exists(p) && isDir(p);
        catch (Exception)
            return false;
    }

    // Whether `path` is a missing start root or lies above one.
    bool leadsToMissing(string path) const
    {
        foreach (r; missing_)
            if (r == path || (r.length > path.length && r[0 .. path.length] == path && r[path.length] == '/'))
                return true;
        return false;
    }

    static string parentOf(string path) @safe pure nothrow @nogc
    {
        size_t i = path.length;
        while (i > 0 && path[i - 1] != '/')
            --i;
        return i > 0 ? path[0 .. i - 1] : "";
    }
}

version (unittest)
{
    import core.time : msecs;

    import sparkles.build_primitives.fileset.pattern : CasePolicy;

    // A scratch tree on disk, removed afterwards.
    private struct Scratch
    {
        string root;

        static Scratch make(string[string] files)
        {
            import std.conv : text;
            import std.file : mkdirRecurse, tempDir, write;
            import std.path : buildPath, dirName;
            import std.process : thisProcessID;
            import core.atomic : atomicOp;

            static shared uint serial;
            Scratch s;
            s.root = buildPath(tempDir, text("sparkles-watch-", thisProcessID, "-", atomicOp!"+="(serial, 1)));
            foreach (path, bytes; files)
            {
                mkdirRecurse(dirName(buildPath(s.root, path)));
                write(buildPath(s.root, path), bytes);
            }
            mkdirRecurse(s.root);
            return s;
        }

        string opIndex(string path) const
        {
            import std.path : buildPath;

            return buildPath(root, path);
        }

        void remove()
        {
            import std.file : rmdirRecurse;

            rmdirRecurse(root);
        }
    }

    // Materializes `set` beneath `s` through `session`.
    private Observed materializeIn(ref WatchSession session, ref Scratch s, ref const Filesets sets, Fileset set)
    {
        import sparkles.base.vfs.handles : ambientAuthority, openRoot;
        import sparkles.base.vfs.types : Rights;
        import sparkles.build_primitives.fileset.driver : InlineExecutor;
        import sparkles.build_primitives.workspace.input_state : DigestCache;
        import sparkles.event_horizon.sys : BlockingVfs;

        auto vfs = new BlockingVfs;
        auto root = openRoot!(Rights.readOnly)(vfs, s.root, ambientAuthority());
        assert(root.hasValue);
        DigestCache!() cache;
        InlineExecutor exec;
        return session.materialize(root.value.borrow, sets, set, cache, exec);
    }

    private string describe(const ChangeSet cs)
    {
        import std.conv : text;

        string s = cs.lossy ? "lossy: " : "";
        foreach (p; cs.paths)
            s ~= text(p.kind, " ", p.path, "; ");
        return s;
    }
}

/// BGW14: the directories listed are the ones watched, and a directory the
/// set rules out is neither listed nor watched; a change the set may hold
/// arrives, one it cannot is dropped.
@("build_primitives.workspace.watch.listedDirectoriesAreWatched")
@system
unittest
{
    import std.conv : text;
    import std.file : write, mkdir;

    auto s = Scratch.make(["pkg/src/a.d": "a", "pkg/src/sub/b.d": "b", "pkg/docs/x.md": "x"]);
    scope (exit)
        s.remove();
    auto sets = Filesets(CasePolicy.sensitive);
    const set = sets.glob("pkg/src/**/*.d").value;
    auto session = WatchSession.open(s.root);
    scope (exit)
        session.close();
    auto state = materializeIn(session, s, sets, set);
    assert(state.hasValue);
    // The listing starts at the start root: `pkg` is not listed.
    assert(session.watchedDirectories == ["pkg/src", "pkg/src/sub"], text(session.watchedDirectories));

    write(s["pkg/src/sub/b.d"], "B");
    write(s["pkg/src/notes.txt"], "dropped");
    write(s["pkg/docs/x.md"], "unwatched");
    auto cs = session.changes(session.nextBatch(50.msecs));
    assert(!cs.lossy && cs.paths == [PathChange("pkg/src/sub/b.d", ChangeKind.modified)], describe(cs));

    // A new directory the set may hold is reported, and watched once the
    // set is materialized again.
    mkdir(s["pkg/src/new"]);
    cs = session.changes(session.nextBatch(50.msecs));
    assert(cs.paths == [PathChange("pkg/src/new", ChangeKind.created)], describe(cs));
    assert(materializeIn(session, s, sets, set).hasValue);
    assert(session.watchedDirectories == ["pkg/src", "pkg/src/new", "pkg/src/sub"]);
    write(s["pkg/src/new/c.d"], "c");
    cs = session.changes(session.nextBatch(50.msecs));
    assert(cs.paths == [PathChange("pkg/src/new/c.d", ChangeKind.created)], describe(cs));
}

/// A start root that does not exist is watched through its nearest
/// existing ancestor, and its creation is a change.
@("build_primitives.workspace.watch.missingRootsWatchAnAncestor")
@system
unittest
{
    import std.conv : text;
    import std.file : mkdirRecurse, write;

    auto s = Scratch.make(["pkg/dub.sdl": "name"]);
    scope (exit)
        s.remove();
    auto sets = Filesets(CasePolicy.sensitive);
    const set = sets.glob("pkg/source/gen/**").value;
    auto session = WatchSession.open(s.root);
    scope (exit)
        session.close();
    assert(materializeIn(session, s, sets, set).hasValue);
    assert(session.watchedDirectories == ["pkg"]);

    write(s["pkg/other"], "dropped");
    mkdirRecurse(s["pkg/source"]);
    auto cs = session.changes(session.nextBatch(50.msecs));
    assert(cs.paths == [PathChange("pkg/source", ChangeKind.created)], describe(cs));
    mkdirRecurse(s["pkg/source/gen"]);
    write(s["pkg/source/gen/x.d"], "x");
    assert(materializeIn(session, s, sets, set).hasValue);
    assert(session.watchedDirectories == ["pkg/source/gen"], text(session.watchedDirectories));
}

/// BGW14's losses: a watched directory removed or moved makes the next
/// change set lossy.
@("build_primitives.workspace.watch.lossesAreLossy")
@system
unittest
{
    import std.file : rename;

    auto s = Scratch.make(["pkg/src/a.d": "a"]);
    scope (exit)
        s.remove();
    auto sets = Filesets(CasePolicy.sensitive);
    const set = sets.glob("pkg/**").value;
    auto session = WatchSession.open(s.root);
    scope (exit)
        session.close();
    assert(materializeIn(session, s, sets, set).hasValue);
    rename(s["pkg/src"], s["pkg/moved"]);
    auto cs = session.changes(session.nextBatch(50.msecs));
    assert(cs.lossy, describe(cs));
    // Materialized again, it watches what is there now.
    assert(materializeIn(session, s, sets, set).hasValue);
    assert(session.watchedDirectories == ["pkg", "pkg/moved"]);
    assert(!session.changes(null).lossy);
}
