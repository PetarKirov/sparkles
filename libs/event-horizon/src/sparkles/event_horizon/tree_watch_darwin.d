/**
The macOS backend of $(REF TreeWatcher, sparkles,event_horizon,tree_watch)
(design BGW14, D50): FSEvents, through its C API.

$(B Few streams, one table.) An FSEvents stream watches a whole subtree, and
its paths are fixed when it is created. Rather than a stream per watched
directory, which would deliver an event once to every watched ancestor and
spend one `fseventsd` client on each of the thousands of directories a
workspace lists, the backend keeps one stream per $(I root): a watched
directory with no watched ancestor. A directory added under a root needs no
stream, only an entry in the path table, since the root's stream already
reports its children; a new root that covers older ones starts its stream
before theirs stop, so no change falls between them. An event is reported for
the watched directory that holds it, found by its parent path in the table;
any other event is dropped there. Paths are kept as `realpath` gives them,
since FSEvents reports resolved paths (`/private/var/…` for `/var/…`).

$(B Notes.) Streams carry file-level events (`kFSEventStreamCreateFlagFileEvents`),
whose flags accumulate across a path's recent history, and a stream can
deliver events from just before it started. A `created`, `removed` or
`renamed` flag is therefore resolved from the file system: `removed` if the
name is gone; for a name that exists, `created` if it was renamed in or was
born (`st_birthtimespec`) after its directory's watch began, otherwise
`modified` if its status changed (`st_ctimespec`, which any write or
metadata change advances) after then. A change-only event for an existing
name is judged by the same time. Anything else is history from before the
watch, and is dropped: nothing changed under it. `MustScanSubDirs`, `UserDropped` and
`KernelDropped` become `overflow`. A watch is `lost` when its stream's root or
an ancestor moves (`RootChanged`, from `kFSEventStreamCreateFlagWatchRoot`),
when a mount or unmount covers it, and when an event names the watched
directory itself and the directory at its path is gone or is another one. As
the table is by path, a lost directory takes every watch beneath it along: a
moved subtree no longer has the paths its watches name.

$(B Threads.) The streams run on a serial GCD queue, whose threads druntime
does not know. Attaching one with `thread_attachThis` for a callback and
detaching it after does not work twice: `thread_detachThis` leaves the
thread's `Thread.getThis()` set, so a second attach on the same pooled thread
returns that stale object unregistered, and the GC would neither scan nor
stop a thread that allocates; never detaching leaves a dead thread in the
GC's list once GCD retires it. So the callback touches no GC memory: it
copies each event's flags and path into a preallocated inbox under a
`sparkles.base.sync` mutex (which allocates nothing and parks a foreign
thread natively) and signals the backend's own D thread, which decodes the
events and delivers notes through the sink, as the inotify reader does. An
event that finds the inbox full is dropped and becomes an `overflow`. Streams
are created, stopped and released on the queue itself (`dispatch_sync_f`), so
none is torn down while its callback runs.
*/
module sparkles.event_horizon.tree_watch_darwin;

version (OSX):

import core.stdc.errno : ENOMEM, ENOSPC, ENOTDIR, errno;
import core.stdc.stdlib : calloc, free;
import core.stdc.string : memcpy, strlen;
import core.sys.posix.stdlib : realpath;
import core.sys.posix.sys.stat : lstat, stat, stat_t, S_IFDIR, S_IFMT;
import core.sys.posix.time : timespec;
import core.thread : Thread;

import sparkles.base.sync : AutoResetEvent, Mutex;
import sparkles.base.text.cstring : toTempStringz;

import sparkles.event_horizon.errors : IoErrorStage, IoResult, OpKind, ioErr, ioOk;
import sparkles.event_horizon.tree_watch : WatchedDir, WatchNote, WatchNoteKind, WatchSink;

// ─────────────────────────────────────────────────────────────────────────────
// CoreFoundation, CoreServices (FSEvents) and libdispatch, as much as is used
// ─────────────────────────────────────────────────────────────────────────────

private extern (C) nothrow @nogc
{
    alias CFIndex = ptrdiff_t;
    alias CFTypeRef = const(void)*;
    alias CFAllocatorRef = const(void)*;
    alias CFStringRef = const(void)*;
    alias CFArrayRef = const(void)*;
    alias FSEventStreamRef = void*;
    alias ConstFSEventStreamRef = const(void)*;
    alias DispatchQueue = void*;
    alias DispatchFunction = void function(void*) nothrow @nogc;
    alias FSEventStreamCallback = void function(ConstFSEventStreamRef stream, void* info,
        size_t count, void* paths, const(uint)* flags, const(ulong)* ids) nothrow @nogc;

    struct CFArrayCallBacks
    {
        CFIndex version_;
        const(void)* retain, release, copyDescription, equal;
    }

    struct FSEventStreamContext
    {
        CFIndex version_;
        void* info;
        const(void)* retain, release, copyDescription;
    }

    extern __gshared const CFArrayCallBacks kCFTypeArrayCallBacks;

    CFStringRef CFStringCreateWithFileSystemRepresentation(CFAllocatorRef alloc, const(char)* path);
    CFArrayRef CFArrayCreate(CFAllocatorRef alloc, const(void*)* values, CFIndex count,
        const(CFArrayCallBacks)* callBacks);
    void CFRelease(CFTypeRef cf);

    FSEventStreamRef FSEventStreamCreate(CFAllocatorRef alloc, FSEventStreamCallback callback,
        FSEventStreamContext* context, CFArrayRef paths, ulong sinceWhen, double latency, uint flags);
    void FSEventStreamSetDispatchQueue(FSEventStreamRef stream, DispatchQueue queue);
    ubyte FSEventStreamStart(FSEventStreamRef stream);
    void FSEventStreamStop(FSEventStreamRef stream);
    void FSEventStreamInvalidate(FSEventStreamRef stream);
    void FSEventStreamRelease(FSEventStreamRef stream);

    DispatchQueue dispatch_queue_create(const(char)* label, const(void)* attr);
    void dispatch_sync_f(DispatchQueue queue, void* context, DispatchFunction work);
    void dispatch_release(void* object);
    // <time.h>: druntime declares no `clock_gettime` for Darwin (macOS 10.12+).
    int clock_gettime(int clock, timespec* t);
}

// <CoreServices/FSEvents.h>
private enum : ulong { sinceNow = ulong.max }
// <time.h>
private enum int CLOCK_REALTIME = 0;

private enum : uint
{
    createWatchRoot = 0x04,
    createFileEvents = 0x10,
}

private enum : uint
{
    mustScanSubDirs = 0x1,
    userDropped = 0x2,
    kernelDropped = 0x4,
    rootChanged = 0x20,
    mount = 0x40,
    unmount = 0x80,
    itemCreated = 0x100,
    itemRemoved = 0x200,
    itemInodeMetaMod = 0x400,
    itemRenamed = 0x800,
    itemModified = 0x1000,
    itemFinderInfoMod = 0x2000,
    itemChangeOwner = 0x4000,
    itemXattrMod = 0x8000,
    itemIsDir = 0x20000,
    itemCloned = 0x400000,
}

// The delay FSEvents gathers a burst over before calling back; the watcher
// batches by its own quiet period on top.
private enum double latencySeconds = 0.01;

// ─────────────────────────────────────────────────────────────────────────────
// The backend
// ─────────────────────────────────────────────────────────────────────────────

/// Watches directories with FSEvents; see the module documentation.
struct FsEventsBackend
{
    @disable this(this);

    /// Creates the queue, the inbox and the decoding thread.
    IoResult!void start(WatchSink sink)
    {
        inbox = (() @trusted => cast(Inbox*) calloc(1, Inbox.sizeof))();
        if (inbox is null)
            return ioErr!void(ENOMEM, OpKind.none, IoErrorStage.setup, "the watcher's inbox");
        queue = dispatch_queue_create("sparkles.event_horizon.tree_watch", null);
        if (queue is null)
        {
            free(inbox);
            inbox = null;
            return ioErr!void(ENOMEM, OpKind.none, IoErrorStage.setup, "dispatch_queue_create failed");
        }
        state = new Shared;
        state.sink = sink;
        auto st = state;
        auto box = inbox;
        reader = new Thread(() { readLoop(st, box); });
        reader.isDaemon = true;
        reader.start();
        return ioOk();
    }

    /// Watches the directory at `path`; see `TreeWatcher.watch`.
    IoResult!WatchedDir add(scope const(char)[] path)
    {
        // Before the stream exists and before the caller lists the
        // directory: a file born after this was created under the watch.
        const watchedAt = realtimeNanoseconds();
        auto z = path.toTempStringz;
        char[4096] resolved = void; // `realpath` writes at most PATH_MAX (1024) bytes
        if ((() @trusted => realpath(z.ptr, resolved.ptr))() is null)
            return ioErr!WatchedDir(errno, OpKind.none, IoErrorStage.submit, "realpath of a watched directory failed");
        stat_t st;
        if ((() @trusted => stat(resolved.ptr, &st))() != 0)
            return ioErr!WatchedDir(errno, OpKind.none, IoErrorStage.submit, "stat of a watched directory failed");
        if ((st.st_mode & S_IFMT) != S_IFDIR)
            return ioErr!WatchedDir(ENOTDIR, OpKind.none, IoErrorStage.submit, "not a directory");
        const canonical = (() @trusted => resolved[0 .. strlen(resolved.ptr)])().idup;
        const ulong device = st.st_dev, inode = st.st_ino;

        uint token;
        bool covered;
        synchronized (state.lock)
        {
            if (auto known = canonical in state.byPath)
            {
                const e = state.byToken[*known];
                if (e.device == device && e.inode == inode)
                    return ioOk(WatchedDir(*known, device, inode));
                state.loseWithin(canonical); // another directory now has the path
            }
            token = state.nextToken++;
            state.byToken[token] = Entry(canonical, device, inode, watchedAt);
            state.byPath[canonical] = token;
            covered = state.covered(canonical);
        }
        if (!covered)
        {
            auto rootz = canonical.toTempStringz;
            auto job = OpenJob(rootz.ptr, inbox, queue);
            (() @trusted => dispatch_sync_f(queue, &job, &openOnQueue))();
            if (job.stream is null)
            {
                synchronized (state.lock)
                    state.forget(token);
                return ioErr!WatchedDir(job.error, OpKind.none, IoErrorStage.submit,
                    job.error == ENOSPC ? "FSEventStreamStart failed" : "FSEventStreamCreate failed");
            }
            synchronized (state.lock)
                state.streams ~= Stream(canonical, job.stream);
        }
        prune();
        return ioOk(WatchedDir(token, device, inode));
    }

    /// Stops watching `token`; no `lost` note follows.
    void remove(uint token)
    {
        synchronized (state.lock)
            state.forget(token);
        prune();
    }

    /// Stops every stream, then the decoding thread, and releases the queue.
    void stop()
    {
        if (reader is null)
            return;
        Stream[] all;
        synchronized (state.lock)
        {
            all = state.streams;
            state.streams = null;
        }
        foreach (s; all)
            close(s.stream);
        // A callback queued before the streams were invalidated has run once
        // this returns.
        (() @trusted => dispatch_sync_f(queue, null, &nothingOnQueue))();
        {
            auto held = inbox.lock.guard();
            inbox.stopping = true;
        }
        inbox.wake.set();
        reader.join();
        reader = null;
        dispatch_release(queue);
        queue = null;
        free(inbox);
        inbox = null;
    }

private:
    Shared state;
    Inbox* inbox;
    DispatchQueue queue;
    Thread reader;

    // Stops the streams no watch needs: lost ones, ones with no watch left
    // beneath them, and ones a wider stream covers.
    void prune()
    {
        Stream[] done;
        synchronized (state.lock)
        {
            Stream[] kept;
            foreach (s; state.streams)
                (state.needed(s) ? kept : done) ~= s;
            state.streams = kept;
        }
        foreach (s; done)
            close(s.stream);
    }

    void close(FSEventStreamRef stream)
    {
        (() @trusted => dispatch_sync_f(queue, stream, &closeOnQueue))();
    }

    // Decodes what the callbacks queued until `stop`.
    static void readLoop(Shared st, Inbox* box)
    {
        auto local = new ubyte[Inbox.bytes.length];
        for (;;)
        {
            box.wake.wait();
            size_t used;
            bool dropped, stopping;
            {
                auto held = box.lock.guard();
                used = box.used;
                local[0 .. used] = box.bytes[0 .. used];
                box.used = 0;
                dropped = box.dropped;
                box.dropped = false;
                stopping = box.stopping;
            }
            for (size_t at; at < used;)
            {
                Record r;
                (() @trusted => memcpy(&r, &local[at], Record.sizeof))();
                at += Record.sizeof;
                const path = cast(const(char)[]) local[at .. at + r.length];
                at += r.length;
                st.decode(path, r.flags);
            }
            if (dropped)
                st.sink.deliver(WatchNote(0, WatchNoteKind.overflow));
            if (stopping)
                return;
        }
    }
}

private:

struct Entry
{
    string path;
    ulong device, inode;
    long watchedAt; // the realtime clock, in nanoseconds, as the watch began
}

// The realtime clock in nanoseconds: the clock file birth times are stamped by.
long realtimeNanoseconds() @trusted nothrow @nogc
{
    timespec t;
    clock_gettime(CLOCK_REALTIME, &t);
    return nanoseconds(t);
}

long nanoseconds(const timespec t) @safe pure nothrow @nogc
    => cast(long) t.tv_sec * 1_000_000_000 + t.tv_nsec;

struct Stream
{
    string root;
    FSEventStreamRef stream;
    bool stale; // its root or an ancestor moved: it no longer covers its root
}

// The table, shared by the caller's thread and the decoding thread.
final class Shared
{
    Object lock;
    WatchSink sink;
    Entry[uint] byToken;
    uint[string] byPath;
    Stream[] streams;
    uint nextToken = 1;

    this() { lock = new Object; }

    // Under `lock`, as every method below.
    // A live stream's root holds `path` (strictly: is an ancestor of it).
    bool covered(scope const(char)[] path, bool strictly = false)
    {
        foreach (ref s; streams)
            if (!s.stale && (strictly ? below(path, s.root) : within(path, s.root)))
                return true;
        return false;
    }

    bool needed(ref Stream s)
    {
        if (s.stale || covered(s.root, true))
            return false;
        foreach (ref e; byToken)
            if (within(e.path, s.root))
                return true;
        return false;
    }

    void forget(uint token)
    {
        if (auto e = token in byToken)
        {
            byPath.remove(e.path);
            byToken.remove(token);
        }
    }

    // Ends, with a `lost` note, every watch at or beneath `path`.
    void loseWithin(scope const(char)[] path)
    {
        uint[] gone;
        foreach (token, ref e; byToken)
            if (within(e.path, path))
                gone ~= token;
        foreach (token; gone)
        {
            forget(token);
            sink.deliver(WatchNote(token, WatchNoteKind.lost));
        }
        foreach (ref s; streams)
            if (within(s.root, path))
                s.stale = true;
    }

    void decode(scope const(char)[] raw, uint flags)
    {
        if (flags & (mustScanSubDirs | userDropped | kernelDropped))
        {
            sink.deliver(WatchNote(0, WatchNoteKind.overflow));
            return;
        }
        const path = raw.length > 1 && raw[$ - 1] == '/' ? raw[0 .. $ - 1] : raw;
        if (flags & (rootChanged | mount | unmount))
        {
            synchronized (lock)
                loseWithin(path);
            return;
        }

        enum uint names = itemCreated | itemRemoved | itemRenamed;
        enum uint changes = itemModified | itemInodeMetaMod | itemChangeOwner | itemXattrMod
            | itemFinderInfoMod | itemCloned;
        if (!(flags & (names | changes)))
            return;

        stat_t now;
        bool looked, exists;
        bool existsNow()
        {
            if (!looked)
            {
                auto z = path.toTempStringz;
                exists = (() @trusted => lstat(z.ptr, &now))() == 0;
                looked = true;
            }
            return exists;
        }

        synchronized (lock)
        {
            // The watched directory itself: gone, or replaced, ends its watch.
            if (flags & (itemRemoved | itemRenamed))
                if (auto self = cast(string) path in byPath)
                {
                    const e = byToken[*self];
                    if (!existsNow() || now.st_dev != e.device || now.st_ino != e.inode)
                        loseWithin(path);
                }

            const slash = lastSlash(path);
            if (slash < 0 || slash + 1 == path.length)
                return;
            const parent = slash == 0 ? "/" : path[0 .. slash];
            auto token = cast(string) parent in byPath;
            if (token is null)
                return;
            const name = path[slash + 1 .. $].idup;
            if (flags & names)
            {
                if (!existsNow())
                {
                    sink.deliver(WatchNote(*token, WatchNoteKind.removed, (flags & itemIsDir) != 0, name));
                    return;
                }
                const isDir = (now.st_mode & S_IFMT) == S_IFDIR;
                const since = byToken[*token].watchedAt;
                if ((flags & itemRenamed) || nanoseconds(now.st_birthtimespec) >= since)
                    sink.deliver(WatchNote(*token, WatchNoteKind.created, isDir, name));
                else if (nanoseconds(now.st_ctimespec) >= since)
                    sink.deliver(WatchNote(*token, WatchNoteKind.modified, isDir, name));
                // Otherwise history from before the watch: nothing changed since.
            }
            else if (!existsNow() || nanoseconds(now.st_ctimespec) >= byToken[*token].watchedAt)
                sink.deliver(WatchNote(*token, WatchNoteKind.modified, (flags & itemIsDir) != 0, name));
        }
    }
}

// `path` is `root` or beneath it.
bool within(scope const(char)[] path, scope const(char)[] root) @safe pure nothrow @nogc
    => path == root || below(path, root);

// `path` is strictly beneath `root`.
bool below(scope const(char)[] path, scope const(char)[] root) @safe pure nothrow @nogc
{
    if (root == "/")
        return path.length > 1 && path[0] == '/';
    return path.length > root.length && path[0 .. root.length] == root && path[root.length] == '/';
}

ptrdiff_t lastSlash(scope const(char)[] path) @safe pure nothrow @nogc
{
    foreach_reverse (i, c; path)
        if (c == '/')
            return i;
    return -1;
}

// What the callbacks hand the decoding thread: records of a header and a
// path's bytes, in memory the GC never sees.
struct Record
{
    uint flags;
    uint length;
}

struct Inbox
{
    Mutex lock;
    AutoResetEvent wake;
    bool stopping; // under `lock`
    bool dropped;  // under `lock`: an event found no room
    size_t used;   // under `lock`
    ubyte[256 * 1024] bytes;

    // Under `lock`.
    void push(uint flags, scope const(char)[] path) nothrow @nogc
    {
        if (path.length > bytes.length || used + Record.sizeof + path.length > bytes.length)
        {
            dropped = true;
            return;
        }
        auto r = Record(flags, cast(uint) path.length);
        (() @trusted => memcpy(&bytes[used], &r, Record.sizeof))();
        used += Record.sizeof;
        bytes[used .. used + path.length] = cast(const(ubyte)[]) path;
        used += path.length;
    }
}

static assert(__traits(isZeroInit, Inbox), "the inbox is allocated by calloc");

// ─────────────────────────────────────────────────────────────────────────────
// On the queue's threads: C calls and the inbox only, never the GC
// ─────────────────────────────────────────────────────────────────────────────

extern (C) void onEvents(ConstFSEventStreamRef, void* info, size_t count, void* paths,
    const(uint)* flags, const(ulong)*) nothrow @nogc
{
    auto box = cast(Inbox*) info;
    auto ps = cast(const(char*)*) paths;
    {
        auto held = box.lock.guard();
        foreach (i; 0 .. count)
            box.push(flags[i], ps[i][0 .. strlen(ps[i])]);
    }
    box.wake.set();
}

struct OpenJob
{
    const(char)* root;
    Inbox* inbox;
    DispatchQueue queue;
    FSEventStreamRef stream;
    int error;
}

extern (C) void openOnQueue(void* p) nothrow @nogc
{
    auto job = cast(OpenJob*) p;
    job.error = ENOMEM;
    auto path = CFStringCreateWithFileSystemRepresentation(null, job.root);
    if (path is null)
        return;
    scope (exit)
        CFRelease(path);
    const(void)* item = path;
    auto paths = CFArrayCreate(null, &item, 1, &kCFTypeArrayCallBacks);
    if (paths is null)
        return;
    scope (exit)
        CFRelease(paths);
    auto context = FSEventStreamContext(0, job.inbox);
    auto s = FSEventStreamCreate(null, &onEvents, &context, paths, sinceNow, latencySeconds,
        createFileEvents | createWatchRoot);
    if (s is null)
        return;
    FSEventStreamSetDispatchQueue(s, job.queue);
    if (!FSEventStreamStart(s))
    {
        FSEventStreamInvalidate(s);
        FSEventStreamRelease(s);
        job.error = ENOSPC; // `fseventsd` refused it: a loss to the caller
        return;
    }
    job.stream = s;
    job.error = 0;
}

extern (C) void closeOnQueue(void* stream) nothrow @nogc
{
    FSEventStreamStop(stream);
    FSEventStreamInvalidate(stream);
    FSEventStreamRelease(stream);
}

extern (C) void nothingOnQueue(void*) nothrow @nogc {}
