/**
Async file watching (PLAN M7): an inotify descriptor driven through the
ring — the IDE/agent-tooling primitive. `nextEvent` parks the fiber until
the kernel delivers an event.

Loop-side module (the capability concept + test double join `live`/`Env` in
M9).
*/
module sparkles.event_horizon.watch;

version (linux)  :  // inotify is Linux; the kqueue backend maps EVFILT_VNODE (M10)

import core.sys.linux.sys.inotify;

import sparkles.event_horizon.buffer : Buf, BufferPool;
import sparkles.event_horizon.errors;
import sparkles.event_horizon.op;
import sparkles.event_horizon.sched : Sched;

/// One delivered file-system event.
struct WatchEvent
{
    int wd;             /// which watch fired
    uint mask;          /// `IN_*` event bits
    char[256] nameBuf;  /// the name bytes (directories: the child's name)
    uint nameLen;       /// valid bytes of `nameBuf`

    /// The event's name as a slice.
    const(char)[] name() const return @safe pure nothrow @nogc
        => nameBuf[0 .. nameLen];
}

/// An inotify instance plus a small event buffer.
struct Watcher
{
    @disable this(this);

    /// Creates the inotify descriptor (non-blocking is unnecessary — reads
    /// go through the ring and park the fiber, never a thread).
    static IoResult!void create(out Watcher w) @trusted nothrow @nogc
    {
        const fd = inotify_init1(IN_CLOEXEC);
        if (fd < 0)
            return ioErr!void(24 /* EMFILE */, OpKind.none, IoErrorStage.setup,
                "inotify_init1 failed");
        w._fd = fd;
        return ioOk();
    }

    /// Watches `path` for `mask` events; the watch descriptor.
    IoResult!int addWatch(scope const(char)[] path, uint mask) @trusted nothrow @nogc
    {
        char[4096] zpath = void;
        if (path.length >= zpath.length)
            return ioErr!int(36 /* ENAMETOOLONG */, OpKind.none,
                IoErrorStage.submit, "path too long");
        zpath[0 .. path.length] = path[];
        zpath[path.length] = '\0';
        int wd = inotify_add_watch(_fd, zpath.ptr, mask);
        if (wd < 0)
            return ioErr!int(2 /* ENOENT */, OpKind.none, IoErrorStage.submit,
                "inotify_add_watch failed");
        return ioOk(wd);
    }

    /// Parks until the next event arrives.
    IoResult!WatchEvent nextEvent(ref Sched s) @trusted
    {
        // The event buffer lives on this parked frame (§6.5); one
        // inotify_event + a full name fits comfortably.
        ubyte[inotify_event.sizeof + 256] raw = void;
        auto view = raw[];
        auto foreign = Buf.fromForeign(view, null);
        foreign.length = foreign.capacity;
        auto o = s.await(OpRead(_fd, (() @trusted {
            import core.lifetime : move;

            return move(foreign);
        })(), ulong.max));
        if (o.res < 0)
            return ioErr!WatchEvent(-o.res, OpKind.read);
        if (o.res < inotify_event.sizeof)
            return ioErr!WatchEvent(74 /* EBADMSG */, OpKind.read,
                IoErrorStage.completion, "short inotify read");

        const ev = cast(const(inotify_event)*) raw.ptr;
        WatchEvent result;
        result.wd = ev.wd;
        result.mask = ev.mask;
        if (ev.len > 0)
        {
            // len includes NUL padding; trim to the C string.
            const bytes = raw[inotify_event.sizeof .. inotify_event.sizeof + ev.len];
            uint n;
            while (n < bytes.length && n < result.nameBuf.length && bytes[n] != 0)
                ++n;
            result.nameBuf[0 .. n] = cast(const(char)[]) bytes[0 .. n];
            result.nameLen = n;
        }
        return ioOk(result);
    }

    /// Closes the inotify descriptor.
    void close() @trusted nothrow @nogc
    {
        import core.sys.posix.unistd : close_ = close;

        if (_fd >= 0)
            close_(_fd);
        _fd = -1;
    }

    ~this() @safe nothrow @nogc
    {
        close();
    }

private:
    int _fd = -1;
}

@("watch.inotify.createEventThroughRing")
@safe
unittest
{
    import sparkles.event_horizon.io : yieldNow;

    Sched s;
    if (Sched.create(s).hasError)
        return; // SKIP: io_uring unavailable
    scope (exit) s.destroy();

    enum dir = "/tmp/sparkles-event-horizon-watch-test";
    (() @trusted {
        import core.sys.posix.sys.stat : mkdir;
        import std.conv : octal;

        char[64] z = void;
        z[0 .. dir.length] = dir[];
        z[dir.length] = '\0';
        mkdir(z.ptr, octal!700);
    })();

    Watcher w;
    assert(!Watcher.create(w).hasError);
    scope (exit) w.close();

    auto wd = w.addWatch(dir, IN_CREATE);
    assert(wd.hasValue);

    bool sawCreate;
    auto r = s.run(() {
        // A sibling fiber creates a file while we park on the watch.
        cast(void) s.spawn(() {
            import core.sys.posix.fcntl : O_CREAT, O_WRONLY;
            import std.conv : octal;

            import sparkles.event_horizon.fs : closeFile, openFile;

            auto f = openFile(s, dir ~ "/hello.txt", O_CREAT | O_WRONLY, octal!600);
            assert(f.hasValue);
            auto handle = f.value;
            assert(!closeFile(s, handle).hasError);
        });

        auto ev = w.nextEvent(s);
        assert(ev.hasValue);
        assert(ev.value.mask & IN_CREATE);
        sawCreate = ev.value.name == "hello.txt";
    });
    assert(!r.hasError);
    assert(sawCreate);

    (() @trusted {
        import core.stdc.stdio : remove;

        remove(dir ~ "/hello.txt\0");
        import core.sys.posix.unistd : rmdir;

        rmdir(dir ~ "\0");
    })();
}
