/**
`RingVfs`: the capability VFS's asynchronous backend (VFB5), and the `fs`
member of the capability row (SPEC §10.5).

Every primitive is `BlockingVfs`'s own, so `RingVfs` produces its results
by construction. What changes is where the call runs: on a scheduler fiber,
each call that can block moves to the blocking pool and parks only the
calling fiber, never the loop. Off a scheduler, or where the pool is absent
(Windows, until it is ported), the call runs inline. A full pool queue also
runs the call inline rather than inventing an error `BlockingVfs` never
returns; an interrupted caller gets `cancelled` at the pool's entry
checkpoint, the one cancellation point a blocking call has.

Specified in `docs/specs/base/vfs/backends.md` (VFB5).
*/
module sparkles.event_horizon.vfs;

import core.lifetime : move, moveEmplace;

import expected : Expected;

import sparkles.base.io.errors : ErrorKind, IoError, IoResult, NoGcHook, ioErr, ioOk;
import sparkles.base.vfs.concept : isVfs;
import sparkles.base.vfs.types : EntryKind, MountCheck, OpenMode, ResolvePolicy, Sharing,
    Stat, StatMask;
import sparkles.base.io.errors : OpKind;
import sparkles.base.vfs.types : maxNameLength, maxSplicedPathLength;
import sparkles.event_horizon.op : OpMkdirAt, OpRenameAt, OpSymlinkAt, OpUnlinkAt;
import sparkles.event_horizon.sys : BlockingVfs, BorrowedFd, OwnedFd;

version (Posix)
{
    import sparkles.event_horizon.blocking_pool : BlockingPool, sharedBlockingPool;
    import sparkles.event_horizon.sched : currentScheduler, onScheduler;
    import sparkles.event_horizon.sys.vfs : terminate;
}

/// The capability VFS backend the loop exposes as `env.fs`.
struct RingVfs
{
    /// Handles and listings are `BlockingVfs`'s: the same descriptors.
    alias Handle = BlockingVfs.Handle;
    /// ditto
    alias Listing = BlockingVfs.Listing;

    /// The capability row's name for this member.
    enum capName = "fs";

    /// Test switch: resolve every walk with the component walk (oracle 3).
    bool forceComponentWalk;
    /// Test switch: behave as if the kernel resolver were withdrawn (VFR5).
    bool simulateWithdrawal;

    // A capability is a plain value the row copies, and BlockingVfs holds
    // nothing but these switches, so each call makes its own.
    private BlockingVfs inner() const @safe pure nothrow @nogc
    {
        BlockingVfs b;
        b.forceComponentWalk = forceComponentWalk;
        b.simulateWithdrawal = simulateWithdrawal;
        return b;
    }

    // ------------------------------------------------------------ primitives

// Not `@nogc`: the pool bootstraps itself with one allocation, and its
// locking is not annotated. Everything else here is.
@safe nothrow:

    /// See `BlockingVfs.openRootDir`.
    IoResult!Handle openRootDir(scope const(char)[] path)
        => offload(() => inner.openRootDir(path));
    /// See `BlockingVfs.openDirAt`.
    IoResult!Handle openDirAt(Handle dir, scope const(char)[] name)
        => offload(() => inner.openDirAt(dir, name));
    /// See `BlockingVfs.openSearchAt`.
    IoResult!Handle openSearchAt(Handle dir, scope const(char)[] name)
        => offload(() => inner.openSearchAt(dir, name));
    /// See `BlockingVfs.reopen`.
    IoResult!Handle reopen(Handle dir) => offload(() => inner.reopen(dir));
    /// See `BlockingVfs.openFileAt`.
    IoResult!Handle openFileAt(Handle dir, scope const(char)[] name, OpenMode mode,
        Sharing sharing)
        => offload(() => inner.openFileAt(dir, name, mode, sharing));
    /// See `BlockingVfs.mkdirAt`.
    IoResult!void mkdirAt(Handle dir, scope const(char)[] name, Sharing sharing)
    {
        static if (canRing!OpMkdirAt)
            if (onRing!OpMkdirAt)
            {
                char[maxNameLength + 1] z;
                if (!terminate(name, z))
                    return ioErr!void(ErrorKind.nameTooLong, OpKind.mkdirAt);
                return inner.mkdirOutcome(ringErrno((() @trusted => OpMkdirAt(
                    BlockingVfs.fdOf(dir), &z[0], sharing.modeBits(true, false)))()));
            }
        return offload(() => inner.mkdirAt(dir, name, sharing));
    }
    /// See `BlockingVfs.statAt`.
    IoResult!Stat statAt(Handle dir, scope const(char)[] name, StatMask mask)
        => offload(() => inner.statAt(dir, name, mask));
    /// See `BlockingVfs.fstat`.
    IoResult!Stat fstat(Handle h, StatMask mask) => offload(() => inner.fstat(h, mask));
    /// See `BlockingVfs.readlinkAt`.
    IoResult!size_t readlinkAt(Handle dir, scope const(char)[] name, scope char[] buffer)
        => offload(() => inner.readlinkAt(dir, name, buffer));
    /// See `BlockingVfs.symlinkAt`.
    IoResult!void symlinkAt(Handle dir, scope const(char)[] name, scope const(char)[] target)
    {
        static if (canRing!OpSymlinkAt)
            if (onRing!OpSymlinkAt)
            {
                char[maxNameLength + 1] z;
                char[maxSplicedPathLength + 1] tz;
                if (!terminate(name, z) || !terminate(target, tz))
                    return ioErr!void(ErrorKind.nameTooLong, OpKind.symlinkAt);
                return inner.symlinkOutcome(ringErrno((() @trusted => OpSymlinkAt(
                    &tz[0], BlockingVfs.fdOf(dir), &z[0]))()));
            }
        return offload(() => inner.symlinkAt(dir, name, target));
    }
    /// See `BlockingVfs.unlinkAt`.
    IoResult!void unlinkAt(Handle dir, scope const(char)[] name)
    {
        static if (canRing!OpUnlinkAt)
            if (onRing!OpUnlinkAt)
            {
                char[maxNameLength + 1] z;
                if (!terminate(name, z))
                    return ioErr!void(ErrorKind.nameTooLong, OpKind.unlinkAt);
                const e = ringErrno((() @trusted => OpUnlinkAt(BlockingVfs.fdOf(dir), &z[0], 0))());
                return inner.unlinkOutcome(dir, z, e);
            }
        return offload(() => inner.unlinkAt(dir, name));
    }
    /// See `BlockingVfs.rmdirAt`.
    IoResult!void rmdirAt(Handle dir, scope const(char)[] name)
    {
        static if (canRing!OpUnlinkAt)
            if (onRing!OpUnlinkAt)
            {
                import core.sys.posix.fcntl : AT_REMOVEDIR;

                char[maxNameLength + 1] z;
                if (!terminate(name, z))
                    return ioErr!void(ErrorKind.nameTooLong, OpKind.rmdirAt);
                return inner.rmdirOutcome(ringErrno((() @trusted => OpUnlinkAt(
                    BlockingVfs.fdOf(dir), &z[0], AT_REMOVEDIR))()));
            }
        return offload(() => inner.rmdirAt(dir, name));
    }
    /// See `BlockingVfs.renameAt`.
    IoResult!void renameAt(Handle dir, scope const(char)[] name, Handle dstDir,
        scope const(char)[] dstName)
    {
        static if (canRing!OpRenameAt)
            if (onRing!OpRenameAt)
            {
                char[maxNameLength + 1] z, d;
                if (!terminate(name, z) || !terminate(dstName, d))
                    return ioErr!void(ErrorKind.nameTooLong, OpKind.renameAt);
                return inner.renameOutcome(ringErrno((() @trusted => OpRenameAt(
                    BlockingVfs.fdOf(dir), &z[0], BlockingVfs.fdOf(dstDir), &d[0]))()));
            }
        return offload(() => inner.renameAt(dir, name, dstDir, dstName));
    }
    /// See `BlockingVfs.openListing`.
    IoResult!Listing openListing(Handle dir) => offload(() => inner.openListing(dir));
    /// See `BlockingVfs.nextEntry`.
    IoResult!bool nextEntry(scope ref Listing listing, scope char[] buffer,
        out size_t nameLength, out EntryKind kind)
    {
        size_t length;
        EntryKind k;
        auto r = offload(() => inner.nextEntry(listing, buffer, length, k));
        nameLength = length;
        kind = k;
        return r;
    }
    /// See `BlockingVfs.closeListing`; closing a directory stream does not block.
    void closeListing(scope ref Listing listing) @nogc => inner.closeListing(listing);
    /// See `BlockingVfs.read`.
    IoResult!size_t read(Handle h, scope ubyte[] data) => offload(() => inner.read(h, data));
    /// See `BlockingVfs.write`.
    IoResult!size_t write(Handle h, scope const(ubyte)[] data)
        => offload(() => inner.write(h, data));
    /// See `BlockingVfs.sync`.
    IoResult!void sync(Handle h) => offload(() => inner.sync(h));
    /// See `BlockingVfs.close`.
    IoResult!void close(Handle h) => offload(() => inner.close(h));

    // ------------------------------------------- the optional members (VFB3)

    static if (__traits(hasMember, BlockingVfs, "wholePathFor"))
    {
        /// See `BlockingVfs.wholePathFor`.
        bool wholePathFor(ResolvePolicy policy) @nogc => inner.wholePathFor(policy);
        /// See `BlockingVfs.resolveWhole`.
        IoResult!Handle resolveWhole(Handle start, scope const(char)[] path,
            ResolvePolicy policy)
            => offload(() => inner.resolveWhole(start, path, policy));
    }
    static if (__traits(hasMember, BlockingVfs, "wholePathWithdrawn"))
        /// See `BlockingVfs.wholePathWithdrawn`.
        bool wholePathWithdrawn() const @nogc => inner.wholePathWithdrawn();
    static if (__traits(hasMember, BlockingVfs, "mountCheckFor"))
        /// See `BlockingVfs.mountCheckFor`.
        MountCheck mountCheckFor(ResolvePolicy policy) @nogc => inner.mountCheckFor(policy);
    static if (__traits(hasMember, BlockingVfs, "borrowFd"))
        /// See `BlockingVfs.borrowFd`.
        BorrowedFd borrowFd(Handle h) const @nogc => inner.borrowFd(h);
    static if (__traits(hasMember, BlockingVfs, "ownedFd"))
        /// See `BlockingVfs.ownedFd`.
        OwnedFd ownedFd(Handle h) const @nogc => inner.ownedFd(h);

    version (unittest)
    {
        /// Calls this instance's thread completed on the pool; a test reads it
        /// to tell the pool path from the inline fallback.
        static uint poolCalls;
        /// Calls submitted to the ring instead (VFB5).
        static uint ringCalls;
    }

private:
    // ------------------------------------------------------- the ring path

    /// Whether this build's backend lowers `Op` at all.
    enum bool canRing(Op) = is(typeof(() {
        import sparkles.event_horizon.backend.concept : canSubmitOp;
        import sparkles.event_horizon.backend.select : DefaultBackend;

        static assert(canSubmitOp!(DefaultBackend, Op));
    }));

    /// Whether this call can go to the ring: on a scheduler fiber, whose
    /// kernel the probe found to support `Op`.
    static bool onRing(Op)() @trusted nothrow @nogc
    {
        version (Posix)
            return onScheduler() && currentScheduler().loop.caps().supports(Op.kind);
        else
            return false;
    }

    /// Submits `op`, parks the fiber until it completes, and returns its
    /// errno, 0 for success; the same value the system call would leave.
    static int ringErrno(Op)(Op op) @trusted
    {
        version (Posix)
        {
            version (unittest)
                ringCalls++;
            const o = currentScheduler().await(op);
            return o.res < 0 ? -o.res : 0;
        }
        else
            assert(0, "no ring on this platform");
    }

    /// Runs `call` on the blocking pool when the caller is a scheduler fiber,
    /// otherwise inline. See the module comment for the fallbacks.
    static R offload(R)(scope R delegate() @safe nothrow @nogc call) @trusted nothrow
    {
        version (Posix)
        {
            if (!onScheduler())
                return call();
            BlockingPool* pool;
            try
            {
                auto shared_ = sharedBlockingPool();
                if (shared_.hasError)
                    return call();
                pool = shared_.value;
            }
            catch (Exception)
                return call();

            static struct Job
            {
                R delegate() @safe nothrow @nogc call;
                // A union, so no destructor ever runs on it: it holds a value
                // only after the worker ran, and that value is moved out.
                union { R result; }
            }

            static void runJob(void* context) nothrow
            {
                auto job = cast(Job*) context;
                auto r = job.call();
                moveEmplace(r, job.result);
            }

            Job job = void;
            job.call = call;
            IoResult!void ran = ioOk();
            try
                ran = pool.run(currentScheduler(), &runJob, &job);
            catch (Exception)
                return call();
            if (!ran.hasError)
            {
                version (unittest)
                    poolCalls++;
                return move(job.result);
            }
            static if (is(R == Expected!(T, IoError, NoGcHook), T))
            {
                if (ran.error.kind == ErrorKind.cancelled)
                    return ioErr!T(ran);
            }
            // A full queue or a pool shutting down: run it here instead.
            return call();
        }
        else
            return call();
    }
}

static assert(isVfs!RingVfs);
