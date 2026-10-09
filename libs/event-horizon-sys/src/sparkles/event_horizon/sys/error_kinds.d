/**
The portable kind of a native error code.

A failure's `ErrorKind` is computed once, where the raw result first becomes
an `IoError` (the capability VFS's VFE2, event-horizon's §9.1). This module
holds the two tables that do it: $(LREF errnoKind) for the host's `errno`
values, which every POSIX path and the Windows C runtime use, and
$(LREF win32Kind) for the Win32 and Winsock codes `GetLastError` and
`WSAGetLastError` return.

Only the codes some caller branches on have a kind of their own; every other
code is `ErrorKind.other`, and `IoError.code` keeps it for diagnostics.
*/
module sparkles.event_horizon.sys.error_kinds;

import sparkles.base.io.errors : ErrorKind;

/**
The kind of a host `errno` value.

`ELOOP` is `symlinkLoop` here: too many links were followed. The capability
VFS's backends classify it as `symlinkRefused` instead where they asked the
kernel to follow none (VFN2), which only they know.
*/
ErrorKind errnoKind(int e) @safe pure nothrow @nogc
{
    import core.stdc.errno : EACCES, EAGAIN, EBUSY, ECHILD, EEXIST, EINVAL, EISDIR,
        ELOOP, ENAMETOOLONG, ENOENT, ENOTDIR, ENOTEMPTY, EPERM, EPIPE, ESRCH,
        ECANCELED, ECONNREFUSED, ECONNRESET, EWOULDBLOCK;

    switch (e)
    {
        case ENOENT: return ErrorKind.notFound;
        case EEXIST: return ErrorKind.exists;
        case ENOTDIR: return ErrorKind.notADirectory;
        case EISDIR: return ErrorKind.isADirectory;
        case ENOTEMPTY: return ErrorKind.notEmpty;
        case EACCES, EPERM: return ErrorKind.permission;
        case EBUSY: return ErrorKind.busy;
        case ENAMETOOLONG: return ErrorKind.nameTooLong;
        case ELOOP: return ErrorKind.symlinkLoop;
        case ECANCELED: return ErrorKind.cancelled;
        case EAGAIN: return ErrorKind.wouldBlock;
        static if (EWOULDBLOCK != EAGAIN)
        {
            case EWOULDBLOCK: return ErrorKind.wouldBlock;
        }
        case ECONNRESET, EPIPE: return ErrorKind.connectionReset;
        case ECONNREFUSED: return ErrorKind.connectionRefused;
        case EINVAL: return ErrorKind.invalidArgument;
        case ESRCH, ECHILD: return ErrorKind.noProcess;
        default: return ErrorKind.other;
    }
}

///
@("sys.errorKinds.errno")
@safe pure nothrow @nogc unittest
{
    import core.stdc.errno : EAGAIN, ECANCELED, ECONNRESET, EIO, ENOENT, EPIPE, ESRCH;

    assert(errnoKind(ENOENT) == ErrorKind.notFound);
    assert(errnoKind(ECANCELED) == ErrorKind.cancelled);
    assert(errnoKind(EAGAIN) == ErrorKind.wouldBlock);
    // A broken pipe is the writer's view of a reset connection.
    assert(errnoKind(EPIPE) == ErrorKind.connectionReset);
    assert(errnoKind(ECONNRESET) == ErrorKind.connectionReset);
    assert(errnoKind(ESRCH) == ErrorKind.noProcess);
    // Codes nobody branches on stay unclassified.
    assert(errnoKind(EIO) == ErrorKind.other);
    assert(errnoKind(0) == ErrorKind.other);
}

/**
The kind of a Win32 error code (`GetLastError`) or a Winsock error code
(`WSAGetLastError`). The two ranges do not overlap, so one table serves both.
*/
ErrorKind win32Kind(uint code) @safe pure nothrow @nogc
{
    switch (code)
    {
        case 2, 3: return ErrorKind.notFound;           // FILE_ / PATH_NOT_FOUND
        case 5: return ErrorKind.permission;            // ACCESS_DENIED
        case 32, 33: return ErrorKind.busy;             // SHARING_ / LOCK_VIOLATION
        case 80, 183: return ErrorKind.exists;          // FILE_EXISTS, ALREADY_EXISTS
        case 87, 10_022: return ErrorKind.invalidArgument; // INVALID_PARAMETER, WSAEINVAL
        case 109, 232: return ErrorKind.connectionReset; // BROKEN_PIPE, NO_DATA
        case 145: return ErrorKind.notEmpty;            // DIR_NOT_EMPTY
        case 206: return ErrorKind.nameTooLong;         // FILENAME_EXCED_RANGE
        case 267: return ErrorKind.notADirectory;       // DIRECTORY
        case 995, 1223: return ErrorKind.cancelled;     // OPERATION_ABORTED, CANCELLED
        case 10_035: return ErrorKind.wouldBlock;       // WSAEWOULDBLOCK
        case 10_053, 10_054: return ErrorKind.connectionReset; // WSAECONNABORTED, WSAECONNRESET
        case 10_061, 1225: return ErrorKind.connectionRefused; // WSAECONNREFUSED, CONNECTION_REFUSED
        default: return ErrorKind.other;
    }
}

///
@("sys.errorKinds.win32")
@safe pure nothrow @nogc unittest
{
    assert(win32Kind(2) == ErrorKind.notFound);
    assert(win32Kind(995) == ErrorKind.cancelled);
    assert(win32Kind(10_054) == ErrorKind.connectionReset);
    assert(win32Kind(10_061) == ErrorKind.connectionRefused);
    assert(win32Kind(1) == ErrorKind.other); // INVALID_FUNCTION
}
