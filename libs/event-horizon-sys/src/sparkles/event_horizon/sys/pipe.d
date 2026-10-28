/** Internal platform-neutral pipe fixture; both Windows ends support IOCP. */
module sparkles.event_horizon.sys.pipe;

import sparkles.base.io.errors : IoErrorStage, IoResult, OpKind, ioErr, ioOk;
import sparkles.event_horizon.sys.descriptor : OwnedFd, invalidHandle;
import sparkles.event_horizon.sys.error_kinds : errnoKind, win32Kind;

/// Move-only native pipe ownership. Creation is blocking setup, not an
/// operation to perform on a scheduler thread after execution has started.
package(sparkles.event_horizon) struct NativePipe
{
    OwnedFd reader;
    OwnedFd writer;
    @disable this(this);

    /// Creates non-inheritable endpoints; no byte is sent during setup.
    static IoResult!void create(out NativePipe pipe) @safe nothrow @nogc
    {
        version (Windows)
        {
            import core.atomic : atomicOp;
            import core.sys.windows.winbase : OVERLAPPED;

            // PID plus a process-wide sequence, and FIRST_PIPE_INSTANCE:
            // an occupied name fails rather than connecting to another server.
            wchar[96] name;
            enum prefix = `\\.\pipe\sparkles-eh-`w;
            name[0 .. prefix.length] = prefix;
            size_t at = prefix.length;
            const pid = (() @trusted => GetCurrentProcessId())();
            const seq = atomicOp!"+="(pipeSequence, 1UL);
            ulong[2] values = [cast(ulong) pid, seq];
            foreach (value; values)
            {
                foreach_reverse (digit; 0 .. 16)
                    name[at++] = "0123456789abcdef"w[(value >> (digit * 4)) & 15];
                name[at++] = '-';
            }
            name[at - 1] = 0;
            auto rd = (() @trusted => CreateNamedPipeW(name.ptr,
                0x4008_0001, // INBOUND | OVERLAPPED | FIRST_PIPE_INSTANCE
                0x8, // byte mode, PIPE_REJECT_REMOTE_CLIENTS
                1, 4096, 4096, 0, null))();
            if (rd == invalidHandle)
                return windowsPipeError();
            pipe.reader = OwnedFd(rd);
            auto wr = (() @trusted => CreateFileW(name.ptr, 0x4000_0000,
                3, null, 3, 0x4000_0000, null))(); // GENERIC_WRITE, OPEN_EXISTING, OVERLAPPED
            if (wr == invalidHandle)
            {
                auto error = windowsPipeError();
                pipe.reader.close();
                return error;
            }
            pipe.writer = OwnedFd(wr);
            OVERLAPPED ov;
            const connected = (() @trusted => ConnectNamedPipe(rd, &ov))();
            const code = connected ? 0 : (() @trusted => GetLastError())();
            if (code != 0 && code != 535) // ERROR_PIPE_CONNECTED: client won the race
            {
                // Do not let even an unexpected pending connect outlive ov.
                if (code == 997)
                {
                    uint transferred;
                    (() @trusted {
                        CancelIoEx(rd, &ov);
                        GetOverlappedResult(rd, &ov, &transferred, 1);
                    })();
                }
                pipe.reader.close();
                pipe.writer.close();
                return ioErr!void(win32Kind(code), OpKind.openAt, code,
                    IoErrorStage.setup, "named pipe connection failed");
            }
            return ioOk();
        }
        else
        {
            import core.stdc.errno : errno;

            int[2] fds;
            static if (hasPipe2)
            {
                import core.sys.posix.fcntl : O_CLOEXEC;
                import core.sys.posix.unistd : pipe2;

                // Atomic: no other thread can fork between the creation and
                // the flag and leak an end into its child.
                if ((() @trusted => pipe2(fds, O_CLOEXEC))() != 0)
                    return ioErr!void(errnoKind(errno), OpKind.openAt, errno,
                        IoErrorStage.setup, "pipe creation failed");
                pipe.reader = OwnedFd(fds[0]);
                pipe.writer = OwnedFd(fds[1]);
            }
            else
            {
                import core.sys.posix.fcntl : F_GETFD, F_SETFD, FD_CLOEXEC, fcntl;
                import core.sys.posix.unistd : pipe_ = pipe;

                // Darwin has no pipe2: a fork in another thread before the
                // flags are set can still inherit an end.
                if ((() @trusted => pipe_(fds))() != 0)
                    return ioErr!void(errnoKind(errno), OpKind.openAt, errno,
                        IoErrorStage.setup, "pipe creation failed");
                pipe.reader = OwnedFd(fds[0]);
                pipe.writer = OwnedFd(fds[1]);
                foreach (fd; fds)
                {
                    const flags = (() @trusted => fcntl(fd, F_GETFD))();
                    if (flags < 0
                        || (() @trusted => fcntl(fd, F_SETFD, flags | FD_CLOEXEC))() < 0)
                    {
                        const code = errno;
                        pipe.reader.close();
                        pipe.writer.close();
                        return ioErr!void(errnoKind(code), OpKind.openAt, code,
                            IoErrorStage.setup, "pipe close-on-exec setup failed");
                    }
                }
            }
            return ioOk();
        }
    }
}

version (Posix)
    private enum bool hasPipe2 = __traits(compiles, {
        import core.sys.posix.unistd : pipe2;

        int[2] fds;
        cast(void) pipe2(fds, 0);
    });

version (Windows)
{
    private shared ulong pipeSequence;
    private IoResult!void windowsPipeError() @safe nothrow @nogc
    {
        const code = (() @trusted => GetLastError())();
        return ioErr!void(win32Kind(code), OpKind.openAt, code,
            IoErrorStage.setup, "named pipe creation failed");
    }

    private extern (Windows) nothrow @nogc
    {
        void* CreateNamedPipeW(const(wchar)*, uint, uint, uint, uint, uint, uint, void*);
        void* CreateFileW(const(wchar)*, uint, uint, void*, uint, uint, void*);
        int ConnectNamedPipe(void*, void*);
        int CancelIoEx(void*, void*);
        int GetOverlappedResult(void*, void*, uint*, int);
        uint GetCurrentProcessId();
        uint GetLastError();
        int GetHandleInformation(void*, uint*);
    }
}

/// Both endpoints are owned independently, neither is inherited by a child
/// process, and setup sends no payload.
@("sys.pipe.nativeEndpoints")
@system nothrow @nogc unittest
{
    NativePipe pipe;
    assert(!NativePipe.create(pipe).hasError);
    assert(pipe.reader.valid && pipe.writer.valid);
    assert(pipe.reader.borrowFd.fd != pipe.writer.borrowFd.fd);
    foreach (end; [pipe.reader.borrowFd.fd, pipe.writer.borrowFd.fd])
    {
        version (Windows)
        {
            uint flags;
            assert(GetHandleInformation(end, &flags));
            assert(!(flags & 1), "HANDLE_FLAG_INHERIT");
        }
        else
        {
            import core.sys.posix.fcntl : F_GETFD, FD_CLOEXEC, fcntl;

            assert(fcntl(end, F_GETFD) & FD_CLOEXEC);
        }
    }
    pipe.writer.close();
    assert(pipe.reader.valid && !pipe.writer.valid);
}
