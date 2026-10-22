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
                0, 1, 4096, 4096, 0, null))();
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
            import core.sys.posix.fcntl : F_GETFD, F_SETFD, FD_CLOEXEC, fcntl;
            import core.sys.posix.unistd : pipe_ = pipe;

            int[2] fds;
            if ((() @trusted => pipe_(fds))() != 0)
                return ioErr!void(errnoKind(errno), OpKind.openAt, errno,
                    IoErrorStage.setup, "pipe creation failed");
            pipe.reader = OwnedFd(fds[0]);
            pipe.writer = OwnedFd(fds[1]);
            foreach (fd; fds)
            {
                const flags = (() @trusted => fcntl(fd, F_GETFD))();
                if (flags < 0 || (() @trusted => fcntl(fd, F_SETFD, flags | FD_CLOEXEC))() < 0)
                {
                    const code = errno;
                    pipe.reader.close();
                    pipe.writer.close();
                    return ioErr!void(errnoKind(code), OpKind.openAt, code,
                        IoErrorStage.setup, "pipe close-on-exec setup failed");
                }
            }
            return ioOk();
        }
    }
}

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
    }
}

/// Both endpoints are owned independently and setup sends no payload.
@("sys.pipe.nativeEndpoints")
@safe nothrow @nogc unittest
{
    NativePipe pipe;
    assert(!NativePipe.create(pipe).hasError);
    assert(pipe.reader.valid && pipe.writer.valid);
    assert(pipe.reader.borrowFd.fd != pipe.writer.borrowFd.fd);
    pipe.writer.close();
    assert(pipe.reader.valid && !pipe.writer.valid);
}
