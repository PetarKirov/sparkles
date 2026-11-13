/**
Watching directories (design
[BGW14](../../../../../docs/specs/build-primitives/build-graph/fileset-native-workspace.md),
D50): a host-neutral watcher of individual directories that reports the
names that changed in each, and every way it may have missed a change.

A $(LREF TreeWatcher) watches directories one at a time, by path, and
returns for each a token and the identity of the directory it found there,
so that a caller who lists the directory through a handle can tell whether
the two name the same directory. Changes arrive as $(LREF WatchNote)s: a
name created, removed or modified in a watched directory, or a loss, which
says the caller may have missed changes:

$(UL
$(LI `overflow`: a queue overflowed, the kernel's or the watcher's own;)
$(LI `lost`: one watch ended without being asked to: its directory was
    removed or moved, or its file system unmounted.)
)

A watch the kernel refuses for want of capacity fails with `ENOSPC`, which a
caller treats as a loss too. On Windows a watched directory that is renamed
ends no watch: the watch on its parent reports the name `removed`, which a
caller that watches every directory it lists treats as the loss.

Each host has a backend: inotify on Linux, FSEvents on macOS and
`ReadDirectoryChangesW` on Windows. A backend runs on a thread of its own
and hands notes to the loop through a bounded cross-thread channel; a note
that finds the channel full is dropped and becomes an `overflow`, so a
backend never blocks on a slow consumer.
*/
module sparkles.event_horizon.tree_watch;

import core.atomic : atomicExchange, atomicStore;
import core.time : Duration;

import sparkles.base.vfs.handles : AmbientAuthority;

import sparkles.event_horizon.cross_channel : CrossChannel;
import sparkles.event_horizon.errors : IoErrorStage, IoResult, OpKind, ioErr, ioOk;

/// What happened to a name, or to the watch itself.
enum WatchNoteKind : ubyte
{
    created,  /// a name appeared: created, or moved in
    removed,  /// a name disappeared: removed, or moved out
    modified, /// a file's content or metadata changed
    overflow, /// a queue overflowed: changes may have been missed anywhere
    lost,     /// the watch `token` ended: its directory was removed, moved or unmounted
}

/// One change a watcher reports.
struct WatchNote
{
    uint token;         /// the watch whose directory holds `name`; for `overflow`, none
    WatchNoteKind kind; ///
    bool isDir;         /// whether `name` is a directory, when the host says
    string name;        /// the name in the directory; empty for `overflow` and `lost`
}

/// A directory being watched: its token, and the identity of the directory
/// found at the path when the watch began.
struct WatchedDir
{
    uint token;   ///
    ulong device; /// the file system holding it, as the VFS's `Stat.device`
    ulong inode;  /// its identity there, as the VFS's `Stat.inode`
}

/// Where a backend delivers its notes: a bounded channel, and a latch for
/// the notes it had to drop.
final class WatchSink
{
    package CrossChannel!(WatchNote, 1024) channel;
    private shared bool dropped_;

    /// Delivers `note`, or, when the channel is full or closed, remembers
    /// that one was dropped. Never blocks; callable from any thread.
    void deliver(WatchNote note) nothrow
    {
        try
        {
            if (!channel.tryPut(note))
                atomicStore(dropped_, true);
        }
        catch (Exception)
            atomicStore(dropped_, true);
    }

    /// Whether a note was dropped since the last call.
    package bool takeDropped() nothrow @nogc => atomicExchange(&dropped_, false);
}

/**
Watches directories and reports the names that change in them. Move-only:
it owns a backend thread, joined by $(LREF close) or the destructor.
*/
struct TreeWatcher
{
    @disable this(this);

    /// Starts a watcher with no directory watched.
    static IoResult!void create(out TreeWatcher w)
    {
        w.sink_ = new WatchSink;
        auto started = w.backend_.start(w.sink_);
        if (started.hasError)
            return started;
        w.open_ = true;
        return ioOk();
    }

    /**
    Watches the directory at `path`, an absolute path the process's ambient
    authority resolves, for changes to the names directly in it. Watching a
    directory already watched returns its token again. `ENOSPC` when the
    host refuses the watch for want of capacity, `ErrorKind.notADirectory`
    (`ENOTDIR`, or `ERROR_DIRECTORY` on Windows) when `path` is not a
    directory.
    */
    IoResult!WatchedDir watch(scope const(char)[] path, AmbientAuthority authority)
    in (authority.granted, "AmbientAuthority must come from ambientAuthority()")
    in (open_, "watch on a closed TreeWatcher")
        => backend_.add(path);

    /// Stops watching `token`'s directory; no `lost` note follows.
    void unwatch(uint token)
    in (open_, "unwatch on a closed TreeWatcher")
    {
        backend_.remove(token);
    }

    /**
    Waits on a fiber of `exec` for the next change, then gathers what else
    arrives until `quiet` passes with nothing new, measured on `clock`: one
    batch per burst of edits, as an editor's save is several events. A note
    the backend dropped becomes an `overflow` note at the end of the batch.
    `EPIPE` once the watcher is closed and drained; `ECANCELED` when the
    fiber is interrupted.
    */
    IoResult!(WatchNote[]) nextBatch(X, C)(ref X exec, ref C clock, Duration quiet)
    {
        WatchNote[] batch;
        if (sink_.takeDropped())
            batch ~= WatchNote(0, WatchNoteKind.overflow);
        else
        {
            auto first = sink_.channel.take(exec);
            if (first.hasError)
                return ioErr!(WatchNote[])(first.error.code, OpKind.read, IoErrorStage.completion,
                    "the watcher ended");
            batch ~= first.value;
        }
        for (;;)
        {
            const before = batch.length;
            WatchNote more;
            while (sink_.channel.tryTake(more))
                batch ~= more;
            if (batch.length == before)
            {
                if (quiet <= Duration.zero)
                    break;
                auto slept = clock.sleep(quiet);
                if (slept.hasError)
                    return ioErr!(WatchNote[])(slept.error.code, OpKind.read, IoErrorStage.completion,
                        "interrupted while gathering a batch");
                while (sink_.channel.tryTake(more))
                    batch ~= more;
                if (batch.length == before)
                    break;
            }
        }
        if (sink_.takeDropped())
            batch ~= WatchNote(0, WatchNoteKind.overflow);
        return ioOk(batch);
    }

    /**
    ditto, on a thread no scheduler runs: blocks for the first note, or,
    with a positive `timeout`, for at most that long, and then returns an
    empty batch. A caller whose watches the host refused rescans on that
    timeout (D50's fallback).
    */
    IoResult!(WatchNote[]) nextBatch(Duration quiet, Duration timeout = Duration.zero)
    {
        import core.thread : Thread;
        import core.time : MonoTime, msecs;

        WatchNote[] batch;
        WatchNote more;
        if (sink_.takeDropped())
            batch ~= WatchNote(0, WatchNoteKind.overflow);
        else if (timeout <= Duration.zero)
        {
            auto first = sink_.channel.take();
            if (first.hasError)
                return ioErr!(WatchNote[])(first.error.code, OpKind.read, IoErrorStage.completion,
                    "the watcher ended");
            batch ~= first.value;
        }
        else
        {
            const until = MonoTime.currTime + timeout;
            while (!sink_.channel.tryTake(more))
            {
                if (sink_.takeDropped())
                    return ioOk([WatchNote(0, WatchNoteKind.overflow)]);
                if (sink_.channel.closed)
                    return ioErr!(WatchNote[])(32 /* EPIPE */, OpKind.read, IoErrorStage.completion,
                        "the watcher ended");
                if (MonoTime.currTime >= until)
                    return ioOk(batch);
                Thread.sleep(10.msecs);
            }
            batch ~= more;
        }
        for (;;)
        {
            const before = batch.length;
            if (quiet > Duration.zero)
                Thread.sleep(quiet);
            while (sink_.channel.tryTake(more))
                batch ~= more;
            if (batch.length == before || quiet <= Duration.zero)
                break;
        }
        if (sink_.takeDropped())
            batch ~= WatchNote(0, WatchNoteKind.overflow);
        return ioOk(batch);
    }

    /// Stops the backend and ends every watch; a parked `nextBatch` returns
    /// once the notes already delivered are taken. Idempotent.
    void close()
    {
        if (!open_)
            return;
        open_ = false;
        backend_.stop();
        sink_.channel.close();
    }

    ~this()
    {
        close();
    }

private:
    WatchSink sink_;
    Backend backend_;
    bool open_;
}

// ─────────────────────────────────────────────────────────────────────────────
// Backends: `start(sink)`, `add(path)`, `remove(token)`, `stop()`.
// ─────────────────────────────────────────────────────────────────────────────

version (linux)
    private alias Backend = InotifyBackend;
else version (OSX)
{
    import sparkles.event_horizon.tree_watch_darwin : FsEventsBackend;

    private alias Backend = FsEventsBackend;
}
else version (Windows)
{
    import sparkles.event_horizon.tree_watch_windows : DirectoryChangesBackend;

    private alias Backend = DirectoryChangesBackend;
}
else
    static assert(0, "no directory watcher for this host (D50)");

version (linux)
private struct InotifyBackend
{
    import core.sys.linux.sys.inotify;
    import core.thread : Thread;

    @disable this(this);

    // Every change to a directory's names, its files' content and metadata,
    // and the end of the directory itself.
    enum uint mask = IN_CREATE | IN_DELETE | IN_MODIFY | IN_CLOSE_WRITE | IN_ATTRIB | IN_MOVED_FROM
        | IN_MOVED_TO | IN_DELETE_SELF | IN_MOVE_SELF | IN_ONLYDIR;

    IoResult!void start(WatchSink sink)
    {
        import core.sys.linux.sys.eventfd : EFD_CLOEXEC, eventfd;

        fd = inotify_init1(IN_CLOEXEC | IN_NONBLOCK);
        if (fd < 0)
            return ioErr!void(lastErrno, OpKind.none, IoErrorStage.setup, "inotify_init1 failed");
        stopFd = eventfd(0, EFD_CLOEXEC);
        if (stopFd < 0)
            return ioErr!void(lastErrno, OpKind.none, IoErrorStage.setup, "eventfd failed");
        state = new Shared;
        state.sink = sink;
        auto st = state;
        const watchFd = fd, wakeFd = stopFd;
        reader = new Thread(() { readLoop(st, watchFd, wakeFd); });
        reader.isDaemon = true;
        reader.start();
        return ioOk();
    }

    IoResult!WatchedDir add(scope const(char)[] path)
    {
        import core.stdc.errno : ENAMETOOLONG;
        import core.sys.posix.sys.stat : stat, stat_t;

        char[4096] z = void;
        if (path.length >= z.length)
            return ioErr!WatchedDir(ENAMETOOLONG, OpKind.none, IoErrorStage.submit, "path too long");
        z[0 .. path.length] = path[];
        z[path.length] = '\0';
        const wd = (() @trusted => inotify_add_watch(fd, z.ptr, mask))();
        if (wd < 0)
            return ioErr!WatchedDir(lastErrno, OpKind.none, IoErrorStage.submit, "inotify_add_watch failed");
        stat_t st;
        if ((() @trusted => stat(z.ptr, &st))() != 0)
        {
            const e = lastErrno;
            remove(wd);
            return ioErr!WatchedDir(e, OpKind.none, IoErrorStage.submit, "stat of a watched directory failed");
        }
        synchronized (state.lock)
            state.removing.remove(wd);
        return ioOk(WatchedDir(cast(uint) wd, st.st_dev, st.st_ino));
    }

    void remove(uint token)
    {
        synchronized (state.lock)
            state.removing[cast(int) token] = true;
        cast(void) (() @trusted => inotify_rm_watch(fd, cast(int) token))();
    }

    void stop()
    {
        import core.sys.posix.unistd : close, write;

        if (reader is null)
            return;
        ulong one = 1;
        cast(void) (() @trusted => write(stopFd, &one, one.sizeof))();
        reader.join();
        reader = null;
        close(fd);
        close(stopFd);
        fd = stopFd = -1;
    }

private:
    static final class Shared
    {
        Object lock;
        WatchSink sink;
        bool[int] removing; // watches the caller ended: their IN_IGNORED is no loss

        this() { lock = new Object; }
    }

    int fd = -1, stopFd = -1;
    Thread reader;
    Shared state;

    static int lastErrno() @trusted nothrow @nogc
    {
        import core.stdc.errno : errno;

        return errno;
    }

    // Reads events until the stop descriptor fires; one read can carry many.
    static void readLoop(Shared st, int fd, int stopFd)
    {
        import core.stdc.errno : EAGAIN, EINTR, errno;
        import core.sys.posix.poll : poll, pollfd, POLLIN;
        import core.sys.posix.unistd : read;

        align(8) ubyte[64 * 1024] buf = void;
        for (;;)
        {
            pollfd[2] fds = [pollfd(fd, POLLIN, 0), pollfd(stopFd, POLLIN, 0)];
            const ready = (() @trusted => poll(fds.ptr, 2, -1))();
            if (ready < 0)
            {
                if (errno == EINTR)
                    continue;
                st.sink.deliver(WatchNote(0, WatchNoteKind.overflow));
                return;
            }
            if (fds[1].revents)
                return;
            const n = (() @trusted => read(fd, buf.ptr, buf.length))();
            if (n < 0)
            {
                if (errno == EAGAIN || errno == EINTR)
                    continue;
                st.sink.deliver(WatchNote(0, WatchNoteKind.overflow));
                return;
            }
            size_t at;
            while (at + inotify_event.sizeof <= n)
            {
                const ev = (() @trusted => cast(const(inotify_event)*) (buf.ptr + at))();
                const nameBytes = (() @trusted => buf[at + inotify_event.sizeof .. at + inotify_event.sizeof + ev.len])();
                at += inotify_event.sizeof + ev.len;
                size_t len;
                while (len < nameBytes.length && nameBytes[len] != 0)
                    ++len;
                decode(st, ev.wd, ev.mask, cast(const(char)[]) nameBytes[0 .. len]);
            }
        }
    }

    static void decode(Shared st, int wd, uint m, scope const(char)[] name)
    {
        const isDir = (m & IN_ISDIR) != 0;
        void note(WatchNoteKind kind, string n = null)
        {
            st.sink.deliver(WatchNote(cast(uint) wd, kind, isDir, n));
        }

        if (m & IN_Q_OVERFLOW)
        {
            st.sink.deliver(WatchNote(0, WatchNoteKind.overflow));
            return;
        }
        if (m & IN_IGNORED)
        {
            // The watch ended: removed by the caller, or by the kernel.
            bool asked;
            synchronized (st.lock)
                if (wd in st.removing)
                {
                    asked = true;
                    st.removing.remove(wd);
                }
            if (!asked)
                note(WatchNoteKind.lost);
            return;
        }
        if (m & (IN_DELETE_SELF | IN_MOVE_SELF | IN_UNMOUNT))
        {
            note(WatchNoteKind.lost);
            return;
        }
        if (m & (IN_CREATE | IN_MOVED_TO))
            note(WatchNoteKind.created, name.idup);
        else if (m & (IN_DELETE | IN_MOVED_FROM))
            note(WatchNoteKind.removed, name.idup);
        else if (m & (IN_MODIFY | IN_CLOSE_WRITE | IN_ATTRIB))
        {
            if (name.length)
                note(WatchNoteKind.modified, name.idup);
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests (on the host's own backend)
// ─────────────────────────────────────────────────────────────────────────────

version (unittest)
{
    import core.time : msecs;

    import sparkles.base.vfs.handles : ambientAuthority;
    import sparkles.event_horizon.sched : Sched, schedOrSkip;

    // Runs `body` on a scheduler fiber, with a fresh scratch directory.
    private void onLoop(void delegate(ref Sched, string dir) body)
    {
        import std.file : mkdirRecurse, rmdirRecurse, tempDir;
        import std.path : buildPath;
        import std.process : thisProcessID;
        import std.conv : text;

        static shared uint serial;
        import core.atomic : atomicOp;

        const dir = buildPath(tempDir, text("sparkles-tree-watch-", thisProcessID, "-", atomicOp!"+="(serial, 1)));
        mkdirRecurse(dir);
        scope (exit)
            rmdirRecurse(dir);
        Sched s;
        schedOrSkip(s);
        auto r = s.run(() { body(s, dir); });
        assert(!r.hasError);
    }

    private string describe(const WatchNote[] batch)
    {
        import std.conv : text;

        string s;
        foreach (n; batch)
            s ~= text(n.kind, n.isDir ? " dir " : " ", n.name, "; ");
        return s;
    }
}

/// A file created, written and removed in a watched directory arrives as
/// notes on its token, gathered into batches; a subdirectory says it is one.
@("tree_watch.namesInAWatchedDirectory")
@system
unittest
{
    import std.algorithm.searching : canFind;
    import std.file : mkdir, remove, write;
    import std.path : buildPath;
    import sparkles.event_horizon.live_shared : RingClock;

    onLoop((ref Sched s, string dir) {
        TreeWatcher w;
        assert(!TreeWatcher.create(w).hasError);
        scope (exit)
            w.close();
        const watched = w.watch(dir, ambientAuthority());
        assert(watched.hasValue, watched.hasError ? watched.error.context : "");
        assert(w.watch(dir, ambientAuthority()).value.token == watched.value.token,
            "a directory watched twice has one token");

        auto clock = RingClock(&s);
        write(buildPath(dir, "a.d"), "x");
        mkdir(buildPath(dir, "sub"));
        auto batch = w.nextBatch(s, clock, 50.msecs);
        assert(batch.hasValue);
        assert(batch.value.canFind!(n => n.token == watched.value.token
            && n.kind == WatchNoteKind.created && n.name == "a.d"), describe(batch.value));
        assert(batch.value.canFind!(n => n.kind == WatchNoteKind.created && n.name == "sub" && n.isDir),
            describe(batch.value));

        remove(buildPath(dir, "a.d"));
        batch = w.nextBatch(s, clock, 50.msecs);
        assert(batch.value.canFind!(n => n.kind == WatchNoteKind.removed && n.name == "a.d"),
            describe(batch.value));
    });
}

/// A watched directory that is removed or moved ends its watch with a
/// `lost` note; one the caller unwatched ends without one.
@("tree_watch.lostWatches")
@system
unittest
{
    import std.algorithm.searching : canFind;
    import std.file : mkdir, rename, rmdir, write;
    import std.path : buildPath;
    import sparkles.event_horizon.live_shared : RingClock;

    onLoop((ref Sched s, string dir) {
        TreeWatcher w;
        assert(!TreeWatcher.create(w).hasError);
        scope (exit)
            w.close();
        auto clock = RingClock(&s);
        foreach (name; ["gone", "moved", "quiet"])
            mkdir(buildPath(dir, name));
        const gone = w.watch(buildPath(dir, "gone"), ambientAuthority()).value;
        const moved = w.watch(buildPath(dir, "moved"), ambientAuthority()).value;
        const quiet = w.watch(buildPath(dir, "quiet"), ambientAuthority()).value;
        assert(gone.inode != moved.inode);
        // Windows reports no rename on a directory's own handle: a caller
        // learns of it through the parent, which it watches too (BGW14).
        version (Windows)
            const parent = w.watch(dir, ambientAuthority()).value;

        w.unwatch(quiet.token);
        rmdir(buildPath(dir, "quiet"));
        rmdir(buildPath(dir, "gone"));
        rename(buildPath(dir, "moved"), buildPath(dir, "elsewhere"));
        auto batch = w.nextBatch(s, clock, 50.msecs);
        assert(batch.value.canFind!(n => n.token == gone.token && n.kind == WatchNoteKind.lost),
            describe(batch.value));
        version (Windows)
            assert(batch.value.canFind!(n => n.token == parent.token
                && n.kind == WatchNoteKind.removed && n.name == "moved"), describe(batch.value));
        else
            assert(batch.value.canFind!(n => n.token == moved.token
                && n.kind == WatchNoteKind.lost), describe(batch.value));
        assert(!batch.value.canFind!(n => n.token == quiet.token), describe(batch.value));
    });
}

/// A directory watched inside another keeps its own token, and its watch
/// outlives its parent's: notes go to the directory that holds the name.
@("tree_watch.nestedWatches")
@system
unittest
{
    import std.algorithm.searching : all, canFind;
    import std.file : mkdir, write;
    import std.path : buildPath;
    import sparkles.event_horizon.live_shared : RingClock;

    onLoop((ref Sched s, string dir) {
        TreeWatcher w;
        assert(!TreeWatcher.create(w).hasError);
        scope (exit)
            w.close();
        auto clock = RingClock(&s);
        mkdir(buildPath(dir, "sub"));
        const outer = w.watch(dir, ambientAuthority()).value;
        const inner = w.watch(buildPath(dir, "sub"), ambientAuthority()).value;
        assert(outer.token != inner.token);

        write(buildPath(dir, "sub", "f"), "x");
        auto batch = w.nextBatch(s, clock, 50.msecs);
        assert(batch.value.canFind!(n => n.token == inner.token
            && n.kind == WatchNoteKind.created && n.name == "f"), describe(batch.value));
        assert(!batch.value.canFind!(n => n.name == "f" && n.token == outer.token), describe(batch.value));

        w.unwatch(outer.token);
        write(buildPath(dir, "h"), "x");
        write(buildPath(dir, "sub", "g"), "x");
        batch = w.nextBatch(s, clock, 50.msecs);
        assert(batch.value.canFind!(n => n.token == inner.token
            && n.kind == WatchNoteKind.created && n.name == "g"), describe(batch.value));
        assert(batch.value.all!(n => n.token != outer.token), describe(batch.value));
    });
}

/// More notes than the channel holds: the rest become one `overflow`.
@("tree_watch.overflowIsReported")
@system
unittest
{
    import std.algorithm.searching : canFind;
    import std.conv : text;
    import std.file : write;
    import std.path : buildPath;
    import sparkles.event_horizon.live_shared : RingClock;

    onLoop((ref Sched s, string dir) {
        TreeWatcher w;
        assert(!TreeWatcher.create(w).hasError);
        scope (exit)
            w.close();
        assert(w.watch(dir, ambientAuthority()).hasValue);
        foreach (i; 0 .. 1500)
            write(buildPath(dir, text(i)), "x");
        auto clock = RingClock(&s);
        // FSEvents calls back after a latency: let every note arrive before
        // the first batch drains the channel.
        assert(!clock.sleep(200.msecs).hasError);
        bool overflowed;
        // Each file is at least one note (inotify: a creation and a write):
        // more than 1024.
        foreach (_; 0 .. 20)
        {
            auto batch = w.nextBatch(s, clock, 20.msecs);
            if (batch.value.canFind!(n => n.kind == WatchNoteKind.overflow))
            {
                overflowed = true;
                break;
            }
        }
        assert(overflowed);
    });
}

/// Off the loop: a thread waits for a batch, and a timeout ends a wait
/// with nothing to report.
@("tree_watch.onAThread")
@system
unittest
{
    import std.algorithm.searching : canFind;
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.process : thisProcessID;
    import std.conv : text;

    const dir = buildPath(tempDir, text("sparkles-tree-watch-thread-", thisProcessID));
    mkdirRecurse(dir);
    scope (exit)
        rmdirRecurse(dir);
    TreeWatcher w;
    assert(!TreeWatcher.create(w).hasError);
    scope (exit)
        w.close();
    assert(w.watch(dir, ambientAuthority()).hasValue);
    auto none = w.nextBatch(10.msecs, 30.msecs);
    assert(none.hasValue && none.value.length == 0);
    write(buildPath(dir, "x"), "1");
    auto batch = w.nextBatch(30.msecs);
    assert(batch.value.canFind!(n => n.kind == WatchNoteKind.created && n.name == "x"), describe(batch.value));
}

/// A path that is not a directory is refused.
@("tree_watch.notADirectory")
@system
unittest
{
    import std.file : write;
    import std.path : buildPath;

    onLoop((ref Sched s, string dir) {
        TreeWatcher w;
        assert(!TreeWatcher.create(w).hasError);
        scope (exit)
            w.close();
        write(buildPath(dir, "f"), "x");
        assert(w.watch(buildPath(dir, "f"), ambientAuthority()).hasError);
        assert(w.watch(buildPath(dir, "missing"), ambientAuthority()).hasError);
    });
}
