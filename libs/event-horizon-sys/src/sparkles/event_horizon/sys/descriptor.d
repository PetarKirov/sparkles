/**
Descriptor ownership: one owner closes, borrows never do.

$(LREF OwnedFd) is the move-only owner of an operating-system descriptor: a
pipe end, a pty master, a socket, an open file. It closes the descriptor
exactly once, when it is destroyed or $(LREF OwnedFd.close)d. Anything that
holds a descriptor lends it as a $(LREF BorrowedFd), which is copyable and
has no `close` at all, so no copy can close a descriptor out from under
another.

The I/O verbs of `sparkles:event-horizon` take any type satisfying
$(LREF isFdBorrowable), so an owner, a capability VFS `File` whose backend
has descriptors, and a bare borrow all work alike. This is cap-std's shape:
per-kind owners and one universal borrow (event-horizon's O32).

The descriptor is an `int`: a POSIX descriptor, or a Winsock socket on
Windows, which is all the loop's operations carry.
*/
module sparkles.event_horizon.sys.descriptor;

/// A borrowed descriptor. It never closes; its lender must outlive it.
struct BorrowedFd
{
    /// The descriptor, or -1 for none.
    int fd = -1;

    /// Whether this names a descriptor.
    bool valid() const @safe pure nothrow @nogc => fd >= 0;

    /// A borrow lends itself, so a verb can take one directly.
    BorrowedFd borrowFd() const @safe pure nothrow @nogc => this;
}

/// Whether `H` lends a $(LREF BorrowedFd) through `borrowFd()`.
enum isFdBorrowable(H) = is(typeof((ref H h) { BorrowedFd b = h.borrowFd(); }));

/// The move-only owner of a descriptor.
struct OwnedFd
{
    private int _fd = -1;

    /// Takes ownership of `fd`.
    this(int fd) @safe pure nothrow @nogc
    {
        _fd = fd;
    }

    @disable this(this);

    ~this() @safe nothrow @nogc
    {
        close();
    }

    /// Whether this owns a descriptor.
    bool valid() const @safe pure nothrow @nogc => _fd >= 0;

    /// Lends the descriptor.
    BorrowedFd borrowFd() const @safe pure nothrow @nogc => BorrowedFd(_fd);

    /// Gives up ownership without closing; the caller now owns the result.
    int release() @safe pure nothrow @nogc
    {
        const fd = _fd;
        _fd = -1;
        return fd;
    }

    /// Closes the descriptor now. A second call does nothing.
    void close() @trusted nothrow @nogc
    {
        if (_fd < 0)
            return;
        version (Windows)
        {
            import core.sys.windows.winsock2 : closesocket;

            closesocket(_fd);
        }
        else
        {
            import core.sys.posix.unistd : close_ = close;

            close_(_fd);
        }
        _fd = -1;
    }
}

static assert(isFdBorrowable!BorrowedFd);
static assert(isFdBorrowable!OwnedFd);
static assert(!isFdBorrowable!int);

///
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
    auto owner = OwnedFd(7);
    assert(owner.release() == 7);
    assert(!owner.valid); // nothing left to close
}
