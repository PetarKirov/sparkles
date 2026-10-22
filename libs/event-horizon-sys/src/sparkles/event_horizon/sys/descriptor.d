/**
Descriptor ownership: one owner closes, borrows never do.

$(LREF OwnedFd) is the move-only owner of an operating-system descriptor: a
pipe end, a pty master, an open file (also a socket on POSIX). It closes the
descriptor exactly once, when it is destroyed or $(LREF OwnedFd.close)d. Anything that
holds a descriptor lends it as a $(LREF BorrowedFd), which is copyable and
has no `close` at all, so no copy can close a descriptor out from under
another.

The I/O verbs of `sparkles:event-horizon` take any type satisfying
$(LREF isFdBorrowable), so an owner, a capability VFS `File` whose backend
has descriptors, and a bare borrow all work alike. This is cap-std's shape:
per-kind owners and one universal borrow (event-horizon's O32).

The descriptor is a `NativeHandle`: an `int` on POSIX, a Windows `HANDLE`
otherwise. Windows owners close with `CloseHandle`; Winsock sockets require
their own owner and `closesocket`, not an `OwnedFd`.
*/
module sparkles.event_horizon.sys.descriptor;

version (Windows)
{
    import core.sys.windows.winnt : HANDLE;

    /// The operating system's file/pipe/process handle, without narrowing.
    alias NativeHandle = HANDLE;
    /// The sentinel for an empty descriptor owner or borrow.
    enum NativeHandle invalidHandle = cast(NativeHandle) -1;
}
else
{
    /// The operating system's file descriptor.
    alias NativeHandle = int;
    /// The sentinel for an empty descriptor owner or borrow.
    enum NativeHandle invalidHandle = -1;
}

private bool validHandle(in NativeHandle handle) @safe pure nothrow @nogc
{
    version (Windows)
        return handle !is null && handle != invalidHandle;
    else
        return handle >= 0;
}

// A HANDLE is an opaque token, not a pointer to caller-accessible memory.
// Copying it from a const owner does not lend mutable access to that owner.
private NativeHandle copyHandle(in NativeHandle handle) @safe pure nothrow @nogc
{
    version (Windows)
        return (() @trusted => cast(NativeHandle) handle)();
    else
        return handle;
}

/// A borrowed descriptor. It never closes; its lender must outlive it.
struct BorrowedFd
{
    /// The descriptor, or -1 for none.
    NativeHandle fd = invalidHandle;

    /// Borrows an opaque handle token, without taking ownership.
    this(in NativeHandle handle) @safe pure nothrow @nogc
    {
        fd = copyHandle(handle);
    }

    /// Whether this names a descriptor.
    bool valid() const @safe pure nothrow @nogc => validHandle(fd);

    /// A borrow lends itself, so a verb can take one directly.
    BorrowedFd borrowFd() const @safe pure nothrow @nogc => BorrowedFd(fd);
}

/// Whether `H` lends a $(LREF BorrowedFd) through `borrowFd()`.
enum isFdBorrowable(H) = is(typeof((ref H h) { BorrowedFd b = h.borrowFd(); }));

/// The move-only owner of a descriptor.
struct OwnedFd
{
    private NativeHandle _fd = invalidHandle;

    /// Takes ownership of `fd`.
    this(in NativeHandle fd) @safe pure nothrow @nogc
    {
        _fd = copyHandle(fd);
    }

    @disable this(this);

    ~this() @safe nothrow @nogc
    {
        close();
    }

    /// Whether this owns a descriptor.
    bool valid() const @safe pure nothrow @nogc => validHandle(_fd);

    /// Lends the descriptor.
    BorrowedFd borrowFd() const @safe pure nothrow @nogc => BorrowedFd(_fd);

    /// Gives up ownership without closing; the caller now owns the result.
    NativeHandle release() @safe pure nothrow @nogc
    {
        auto fd = _fd;
        _fd = invalidHandle;
        return fd;
    }

    /// Closes the descriptor now. A second call does nothing.
    void close() @safe nothrow @nogc
    {
        if (!valid)
            return;
        version (Windows)
        {
            (() @trusted => CloseHandle(_fd))();
        }
        else
        {
            import core.sys.posix.unistd : close_ = close;

            (() @trusted => close_(_fd))();
        }
        _fd = invalidHandle;
    }
}

version (Windows)
    private extern (Windows) int CloseHandle(NativeHandle h) nothrow @nogc;

version (Windows) version (unittest)
private extern (Windows) nothrow @nogc
{
    NativeHandle CreateEventW(void*, int, int, const(wchar)*);
    int GetHandleInformation(NativeHandle, uint*);
}

static assert(isFdBorrowable!BorrowedFd);
static assert(isFdBorrowable!OwnedFd);
static assert(!isFdBorrowable!int);

///
version (Posix)
@("sys.descriptor.ownerClosesOnce")
@system unittest
{
    version (Posix)
    {
        import core.sys.posix.fcntl : fcntl, F_GETFD;
        import core.sys.posix.unistd : pipe;

        int[2] fds;
        assert(pipe(fds) == 0);
        auto other = OwnedFd(fds[1]);
        BorrowedFd lent;
        {
            auto owner = OwnedFd(fds[0]);
            lent = owner.borrowFd();
            auto copy = lent; // copying a borrow closes nothing
            assert(copy.valid && fcntl(fds[0], F_GETFD) >= 0);
        }
        // The owner's destruction closed it; the borrow is now stale, which
        // is exactly why a borrow must not outlive its lender.
        assert(fcntl(fds[0], F_GETFD) < 0);
        assert(other.valid);
        other.close();
        other.close();
        assert(!other.valid);
    }
}

///
@("sys.descriptor.release")
@safe nothrow @nogc unittest
{
    version (Windows)
        const fake = (() @trusted => cast(NativeHandle)((1UL << 40) | 7))();
    else
        const fake = 7;
    auto owner = OwnedFd(fake);
    assert(owner.release() == fake);
    assert(!owner.valid); // nothing left to close
}

/// Native Windows handles retain their full pointer width and close exactly
/// once. A borrow never takes ownership, including null/invalid defaults.
version (Windows)
@("sys.descriptor.windowsHandleOwnership")
@system nothrow @nogc unittest
{
    static assert(NativeHandle.sizeof == (void*).sizeof);
    assert(!BorrowedFd.init.valid && !BorrowedFd(null).valid);
    auto handle = CreateEventW(null, 1, 0, null);
    assert(handle !is null);
    uint flags;
    {
        auto owner = OwnedFd(handle);
        assert(owner.valid && owner.borrowFd.fd == handle);
        auto borrowed = owner.borrowFd;
        auto copied = borrowed;
        assert(copied.valid && GetHandleInformation(copied.fd, &flags));
    }
    assert(!GetHandleInformation(handle, &flags), "the owner closed its handle");
    auto empty = OwnedFd(null);
    empty.close();
    empty.close();
}
