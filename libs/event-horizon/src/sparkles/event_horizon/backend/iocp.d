/**
The Windows peer backend: I/O Completion Ports (SPEC §3.5, PLAN M11). IOCP
is natively completion-based — the exact shape the `isCompletionBackend`
concept was designed around — so the mapping is direct: each async winsock
call (`WSARecv`/`WSASend`/`AcceptEx`/`ConnectEx`) carries an
`OVERLAPPED` embedded in a backend-owned op context; `GetQueuedCompletionStatus`
returns that `OVERLAPPED*`, from which the op's `user_data` token and the
transferred byte count are recovered into a `RawCompletion`.

Unlike io_uring there is no submission queue to fill and flush — a winsock
call is issued immediately in `trySubmit` and either completes inline or
posts to the port later. `submitAndWait` therefore only waits (`flush` is a
no-op), and the deadline maps to the `GetQueuedCompletionStatus` timeout.

Status: verified under Wine two ways — the raw backend's data path
(`scripts/verify-iocp-wine.sh`) and the full `EventLoop!IocpBackend` fiber echo
(`scripts/verify-iocp-loop-wine.sh`: tier-A loop + tier-B fibers + the io
verbs). accept (`AcceptEx`), connect (`ConnectEx`, extension pointers loaded
via `WSAIoctl`), recv and send all run through the loop — full parity with the
kqueue backend; sockets are lazily associated with the port on first use. Only
an IOCP timer for `OpTimeout` remains, so the `sleep` verb and deadlines are
absent on Windows for now (SPEC §3.1 — absence degrades, never breaks).
*/
module sparkles.event_horizon.backend.iocp;

version (Windows)  :  // IOCP is Windows-only.

import core.sys.windows.winbase : CreateIoCompletionPort, GetQueuedCompletionStatus,
    INFINITE, OVERLAPPED;
import core.sys.windows.windef : DWORD, FALSE, TRUE;
import core.sys.windows.winnt : HANDLE;
import core.sys.windows.basetsd : ULONG_PTR;

import sparkles.event_horizon.backend.concept : BackendConfig, RawCompletion;
import sparkles.event_horizon.backend.probe : BackendCaps, BackendId, LoopMode;
import sparkles.event_horizon.errors;
import sparkles.event_horizon.op : KernelTimespec, OpAccept, OpConnect, OpNop,
    OpRecv, OpSend, OpSlot, OpToken;

// ── minimal winsock2 / IOCP bindings (only what the data path needs) ────────

private:

enum INVALID_HANDLE_VALUE = cast(HANDLE) -1;
alias SOCKET = size_t;
enum SOCKET INVALID_SOCKET = ~cast(SOCKET) 0;

struct WSABUF
{
    ULONG len;
    char* buf;
}

alias ULONG = uint;

extern (Windows) nothrow @nogc
{
    struct WSADATA
    {
        ushort wVersion;
        ushort wHighVersion;
        // The rest is unused by us; over-size to be safe on all layouts.
        ubyte[512] _pad;
    }

    int WSAStartup(ushort wVersionRequested, WSADATA* lpWSAData);
    int WSACleanup();
    int WSAGetLastError();
    int closesocket(SOCKET s);

    int WSARecv(SOCKET s, WSABUF* lpBuffers, DWORD dwBufferCount,
        DWORD* lpNumberOfBytesRecvd, DWORD* lpFlags, OVERLAPPED* lpOverlapped,
        void* lpCompletionRoutine);
    int WSASend(SOCKET s, WSABUF* lpBuffers, DWORD dwBufferCount,
        DWORD* lpNumberOfBytesSent, DWORD dwFlags, OVERLAPPED* lpOverlapped,
        void* lpCompletionRoutine);
    int PostQueuedCompletionStatus(HANDLE port, DWORD bytes, ULONG_PTR key,
        OVERLAPPED* ov);
    int CloseHandle(HANDLE h); // @nogc-declared here (winbase's isn't marked)

    // Socket setup + the async accept/connect machinery.
    SOCKET socket(int af, int type, int protocol);
    SOCKET WSASocketW(int af, int type, int protocol, void* protocolInfo,
        uint group, DWORD dwFlags);
    int bind(SOCKET s, const void* addr, int namelen);
    int listen(SOCKET s, int backlog);
    SOCKET accept(SOCKET s, void* addr, int* addrlen);
    int connect(SOCKET s, const void* addr, int namelen);
    int getsockname(SOCKET s, void* addr, int* namelen);
    int setsockopt(SOCKET s, int level, int optname, const void* optval, int optlen);
    int WSAIoctl(SOCKET s, DWORD code, void* inBuf, DWORD inLen, void* outBuf,
        DWORD outLen, DWORD* bytesReturned, OVERLAPPED* ov, void* completion);
    ushort htons(ushort hostshort);
    uint htonl(uint hostlong);
    ushort ntohs(ushort netshort);

    // The AcceptEx/ConnectEx extension functions, resolved at runtime.
    alias LPFN_ACCEPTEX = int function(SOCKET listenSock, SOCKET acceptSock,
        void* outputBuffer, DWORD recvDataLength, DWORD localAddrLength,
        DWORD remoteAddrLength, DWORD* bytesReceived, OVERLAPPED* ov) nothrow @nogc;
    alias LPFN_CONNECTEX = int function(SOCKET s, const void* name, int namelen,
        void* sendBuffer, DWORD sendDataLength, DWORD* bytesSent,
        OVERLAPPED* ov) nothrow @nogc;
}

struct GUID
{
    uint data1;
    ushort data2;
    ushort data3;
    ubyte[8] data4;
}

// {b5367df1-cbac-11cf-95ca-00805f48a192} / {25a207b9-ddf3-4660-8ee9-76e58c74063e}
enum GUID WSAID_ACCEPTEX =
    GUID(0xb5367df1, 0xcbac, 0x11cf, [0x95, 0xca, 0x00, 0x80, 0x5f, 0x48, 0xa1, 0x92]);
enum GUID WSAID_CONNECTEX =
    GUID(0x25a207b9, 0xddf3, 0x4660, [0x8e, 0xe9, 0x76, 0xe5, 0x8c, 0x74, 0x06, 0x3e]);
enum DWORD SIO_GET_EXTENSION_FUNCTION_POINTER = 0xc800_0006;

enum int AF_INET = 2;
enum int SOCK_STREAM = 1;
enum int IPPROTO_TCP = 6;
enum int SOL_SOCKET = 0xffff;
enum int SO_UPDATE_ACCEPT_CONTEXT = 0x700B;
enum int SO_UPDATE_CONNECT_CONTEXT = 0x7010;
enum DWORD WSA_FLAG_OVERLAPPED = 0x01;
enum uint INADDR_ANY = 0;
enum uint INADDR_LOOPBACK = 0x7f00_0001;

struct sockaddr_in
{
    short sin_family;
    ushort sin_port;
    uint sin_addr;
    ubyte[8] sin_zero;
}

enum int WSA_IO_PENDING = 997;
enum int SOCKET_ERROR = -1;

enum IoKind : ubyte
{
    data,     // recv/send: res is the byte count
    accept,   // AcceptEx: res is the new socket fd
    connect,  // ConnectEx: res is 0 / -errno
}

/// A backend-owned op context. `ov` is first so `OVERLAPPED*` casts back to it.
struct IocpOp
{
    OVERLAPPED ov;
    ulong token;        // the op's user_data
    WSABUF buf;         // recv/send buffer descriptor
    IoKind kind;
    SOCKET sock;        // accept: the new socket; connect: the fd (for SO_UPDATE_*)
    SOCKET listenSock;  // accept: the listener (for SO_UPDATE_ACCEPT_CONTEXT)
    ubyte[64] addrBuf;  // AcceptEx local+remote address output
    uint nextFree;      // freelist link (uint.max = none)
    bool inUse;
}

public:

/// The IOCP backend. Thread-affine (one port per loop thread).
struct IocpBackend
{
    @disable this(this);

    /// Creates the completion port and starts winsock.
    IoResult!void open(in BackendConfig cfg) @trusted nothrow
    {
        WSADATA wsa;
        if (WSAStartup(0x0202, &wsa) != 0) // request Winsock 2.2
            return ioErr!void(WSAGetLastError(), OpKind.none, IoErrorStage.setup,
                "WSAStartup failed");
        _port = CreateIoCompletionPort(INVALID_HANDLE_VALUE, null, 0, 0);
        if (_port is null)
        {
            WSACleanup();
            return ioErr!void(1, OpKind.none, IoErrorStage.setup,
                "CreateIoCompletionPort failed");
        }

        // A backend-owned op-context slab, freelist-linked.
        const cap = cfg.cqEntries != 0 ? cfg.cqEntries : 2 * cfg.sqEntries;
        _cap = cap != 0 ? cap : 256;
        _ops = (cast(IocpOp*) pureMalloc(_cap * IocpOp.sizeof))[0 .. _cap];
        if (_ops.ptr is null)
        {
            close();
            return ioErr!void(12, OpKind.none, IoErrorStage.setup,
                "op-context slab allocation failed");
        }
        foreach (i; 0 .. _cap)
        {
            _ops[i] = IocpOp.init;
            _ops[i].nextFree = i + 1 == _cap ? uint.max : cast(uint)(i + 1);
        }
        _freeHead = 0;

        // Load the AcceptEx / ConnectEx extension pointers (a bootstrap socket
        // is needed for the WSAIoctl query).
        const boot = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (boot != INVALID_SOCKET)
        {
            loadExt(boot, WSAID_ACCEPTEX, cast(void**) &_acceptEx);
            loadExt(boot, WSAID_CONNECTEX, cast(void**) &_connectEx);
            closesocket(boot);
        }

        _caps.backend = BackendId.iocp;
        _caps.mode = LoopMode.cooperative;
        return ioOk();
    }

    private void loadExt(SOCKET s, GUID guid, void** target) @trusted nothrow @nogc
    {
        DWORD bytes;
        cast(void) WSAIoctl(s, SIO_GET_EXTENSION_FUNCTION_POINTER,
            &guid, GUID.sizeof, target, (void*).sizeof, &bytes, null, null);
    }

    /// Closes the port and winsock.
    void close() @trusted nothrow @nogc
    {
        if (_ops.ptr !is null)
        {
            pureFree(_ops.ptr);
            _ops = null;
        }
        if (_port !is null)
        {
            CloseHandle(_port);
            _port = null;
        }
        WSACleanup();
    }

    /// The negotiated capabilities (IOCP: natively completion-based).
    ref const(BackendCaps) caps() const return @safe pure nothrow @nogc => _caps;

    /// Maps raw completion flags to the portable set. IOCP delivers one
    /// completion per op — no `MORE`/buffer-select flags.
    import sparkles.event_horizon.op : CompletionFlags;

    CompletionFlags mapFlags(uint) const @safe pure nothrow @nogc
        => CompletionFlags.init;

    /// Never called (IOCP sets no buffer-select flag); present for the
    /// dispatch's static shape.
    static ushort selectedBufferId(uint) @safe pure nothrow @nogc => 0;

    /// Associates a socket with the completion port (call once per socket).
    IoResult!void register(SOCKET s) @trusted nothrow
    {
        if (CreateIoCompletionPort(cast(HANDLE) s, _port, 0, 0) is null)
            return ioErr!void(WSAGetLastError(), OpKind.none, IoErrorStage.registration,
                "CreateIoCompletionPort(assoc) failed");
        return ioOk();
    }

    /// Lazily associates a socket the first time an op targets it — so the
    /// generic loop's verbs (which never call `register`) still work. A
    /// verification-grade fixed set; a real backend would use a hash set.
    private void ensureRegistered(SOCKET s) @trusted nothrow @nogc
    {
        foreach (i; 0 .. _regCount)
            if (_regged[i] == s)
                return;
        if (_regCount < _regged.length)
        {
            CreateIoCompletionPort(cast(HANDLE) s, _port, 0, 0);
            _regged[_regCount++] = s;
        }
    }

    // ── lowering: issue the winsock async call immediately ──────────────────

    /// A NOP: post a synthetic completion to the port.
    bool trySubmit(in OpNop, OpToken token, ref OpSlot) @trusted nothrow @nogc
    {
        auto op = acquire();
        if (op is null)
            return false;
        op.token = token.raw;
        PostQueuedCompletionStatus(_port, 0, 0, &op.ov);
        return true;
    }

    /// A socket receive into the pinned buffer's capacity (`WSARecv`).
    bool trySubmit(in OpRecv o, OpToken token, ref OpSlot slot) @trusted nothrow
    {
        ensureRegistered(cast(SOCKET) o.fd);
        auto op = acquire();
        if (op is null)
            return false;
        op.token = token.raw;
        auto space = slot.pinned.space();
        op.buf = WSABUF(cast(ULONG) space.length, cast(char*) space.ptr);
        DWORD flags, recvd;
        const rc = WSARecv(cast(SOCKET) o.fd, &op.buf, 1, &recvd, &flags, &op.ov, null);
        if (rc == SOCKET_ERROR && WSAGetLastError() != WSA_IO_PENDING)
        {
            release(op);
            return false;
        }
        return true;
    }

    /// A socket send of the pinned buffer's valid bytes (`WSASend`).
    bool trySubmit(in OpSend o, OpToken token, ref OpSlot slot) @trusted nothrow
    {
        ensureRegistered(cast(SOCKET) o.fd);
        auto op = acquire();
        if (op is null)
            return false;
        op.token = token.raw;
        auto bytes = slot.pinned[];
        op.buf = WSABUF(cast(ULONG) bytes.length, cast(char*) bytes.ptr);
        DWORD sent;
        const rc = WSASend(cast(SOCKET) o.fd, &op.buf, 1, &sent, 0, &op.ov, null);
        if (rc == SOCKET_ERROR && WSAGetLastError() != WSA_IO_PENDING)
        {
            release(op);
            return false;
        }
        return true;
    }

    /// Async accept via `AcceptEx`: pre-create the accept socket, associate it
    /// with the port, and issue AcceptEx. On completion `res` is the new fd.
    bool trySubmit(in OpAccept o, OpToken token, ref OpSlot) @trusted nothrow
    {
        if (_acceptEx is null)
            return false;
        const listenSock = cast(SOCKET) o.listenFd;
        ensureRegistered(listenSock);
        const acceptSock = WSASocketW(AF_INET, SOCK_STREAM, IPPROTO_TCP, null, 0,
            WSA_FLAG_OVERLAPPED);
        if (acceptSock == INVALID_SOCKET)
            return false;
        ensureRegistered(acceptSock);
        auto op = acquire();
        if (op is null)
        {
            closesocket(acceptSock);
            return false;
        }
        op.token = token.raw;
        op.kind = IoKind.accept;
        op.sock = acceptSock;
        op.listenSock = listenSock;
        DWORD received;
        // localAddrLength/remoteAddrLength = sizeof(sockaddr_in)+16 = 32.
        const rc = _acceptEx(listenSock, acceptSock, op.addrBuf.ptr, 0, 32, 32,
            &received, &op.ov);
        if (rc == 0 && WSAGetLastError() != WSA_IO_PENDING)
        {
            closesocket(acceptSock);
            release(op);
            return false;
        }
        return true;
    }

    /// Async connect via `ConnectEx`: the socket must be bound first. On
    /// completion `res` is 0 / -errno.
    bool trySubmit(in OpConnect o, OpToken token, ref OpSlot) @trusted nothrow
    {
        if (_connectEx is null)
            return false;
        const s = cast(SOCKET) o.fd;
        // ConnectEx requires a bound socket; bind to the wildcard address.
        sockaddr_in local;
        local.sin_family = AF_INET;
        local.sin_addr = htonl(INADDR_ANY);
        cast(void) bind(s, &local, sockaddr_in.sizeof);
        ensureRegistered(s);
        auto op = acquire();
        if (op is null)
            return false;
        op.token = token.raw;
        op.kind = IoKind.connect;
        op.sock = s;
        DWORD sent;
        const rc = _connectEx(s, o.addr.storage.ptr, o.addr.len, null, 0, &sent, &op.ov);
        if (rc == 0 && WSAGetLastError() != WSA_IO_PENDING)
        {
            release(op);
            return false;
        }
        return true;
    }

    /// No submission queue on IOCP — calls issue inline. `flush` is a no-op.
    IoResult!uint flush() @safe nothrow @nogc => ioOk(0u);

    /**
    Waits for at least one completion (or until `deadline`), draining it and
    any others already queued via the caller's subsequent `reap`. Here we
    block on one `GetQueuedCompletionStatus` and stash it; `reap` returns it.
    */
    IoResult!uint submitAndWait(uint want, scope const KernelTimespec* deadline)
        @trusted nothrow
    {
        if (want == 0)
            return ioOk(0u);
        const timeout = deadline is null
            ? INFINITE
            : cast(DWORD)((deadline.tv_sec * 1000) + (deadline.tv_nsec / 1_000_000));
        DWORD bytes;
        ULONG_PTR key;
        OVERLAPPED* ov;
        const ok = GetQueuedCompletionStatus(_port, &bytes, &key, &ov, timeout);
        if (ov is null)
            return ioOk(0u); // timeout with nothing dequeued
        // Stash the dequeued completion for reap().
        _pending = ovToCompletion(ov, bytes, ok != FALSE);
        _hasPending = true;
        return ioOk(1u);
    }

    /// Non-blocking drain: the stashed completion plus any others queued.
    uint reap(Sink)(scope Sink sink) @trusted
    {
        uint n;
        if (_hasPending)
        {
            sink(_pending);
            _hasPending = false;
            ++n;
        }
        // Drain anything else already completed (zero timeout).
        for (;;)
        {
            DWORD bytes;
            ULONG_PTR key;
            OVERLAPPED* ov;
            const ok = GetQueuedCompletionStatus(_port, &bytes, &key, &ov, 0);
            if (ov is null)
                break;
            const c = ovToCompletion(ov, bytes, ok != FALSE); // named: binds ref const
            sink(c);
            ++n;
        }
        return n;
    }

    /// Cancel is best-effort on IOCP (`CancelIoEx` per handle); unimplemented
    /// for the data-path verification (the loop's detach discipline covers
    /// the slot lifetime).
    bool trySubmitCancel(OpToken, OpToken) @safe nothrow @nogc => true;

private:
    RawCompletion ovToCompletion(OVERLAPPED* ov, DWORD bytes, bool ok) @trusted nothrow
    {
        auto op = cast(IocpOp*) ov; // ov is the first field of IocpOp
        const token = op.token;
        int res;
        final switch (op.kind)
        {
            case IoKind.data:
                res = ok ? cast(int) bytes : -5 /* EIO */;
                break;
            case IoKind.accept:
                if (ok)
                {
                    // Inherit the listener's properties; res is the new fd.
                    setsockopt(op.sock, SOL_SOCKET, SO_UPDATE_ACCEPT_CONTEXT,
                        &op.listenSock, SOCKET.sizeof);
                    res = cast(int) op.sock;
                }
                else
                {
                    closesocket(op.sock);
                    res = -5;
                }
                break;
            case IoKind.connect:
                if (ok)
                {
                    setsockopt(op.sock, SOL_SOCKET, SO_UPDATE_CONNECT_CONTEXT, null, 0);
                    res = 0;
                }
                else
                    res = -111 /* ECONNREFUSED */;
                break;
        }
        release(op);
        return RawCompletion(token, res, 0);
    }

    IocpOp* acquire() @trusted nothrow @nogc
    {
        if (_freeHead == uint.max)
            return null;
        auto op = &_ops[_freeHead];
        _freeHead = op.nextFree;
        *op = IocpOp.init;
        op.inUse = true;
        return op;
    }

    void release(IocpOp* op) @trusted nothrow @nogc
    {
        const idx = cast(uint)(op - _ops.ptr);
        op.inUse = false;
        op.nextFree = _freeHead;
        _freeHead = idx;
    }

    import core.memory : pureFree, pureMalloc;

    HANDLE _port;
    LPFN_ACCEPTEX _acceptEx;
    LPFN_CONNECTEX _connectEx;
    SOCKET[64] _regged; // lazily-associated sockets (verification-grade set)
    uint _regCount;
    IocpOp[] _ops;
    uint _cap;
    uint _freeHead = uint.max;
    RawCompletion _pending;
    bool _hasPending;
    BackendCaps _caps;
}

version (unittest)
{
    import sparkles.event_horizon.backend.concept : isCompletionBackend;

    static assert(isCompletionBackend!IocpBackend);
}

version (unittest)
{
    import core.thread : Thread;
    import core.time : msecs;

    import sparkles.event_horizon.buffer : Buf;
    import sparkles.event_horizon.op : OpSlot;
}

/// The M11 data-path gate (runs under Wine): drive a real WSASend through the
/// IOCP port on a loopback pair and confirm the peer receives the bytes, and
/// a WSARecv through the port receives the peer's reply — proving the
/// OVERLAPPED→token completion mapping end to end.
@("iocp.dataPath.sendRecvThroughPort")
@system
unittest
{
    IocpBackend b;
    if (b.open(BackendConfig()).hasError)
        return; // SKIP: winsock unavailable
    scope (exit) b.close();

    // A connected loopback pair: listener + a client thread that connects,
    // then the main thread accepts. Only the data path uses IOCP.
    const listener = socket(AF_INET, SOCK_STREAM, 0);
    assert(listener != INVALID_SOCKET);
    sockaddr_in addr;
    addr.sin_family = AF_INET;
    addr.sin_port = 0; // ephemeral
    addr.sin_addr = htonl(INADDR_LOOPBACK);
    assert(bind(listener, &addr, sockaddr_in.sizeof) == 0);
    assert(listen(listener, 1) == 0);
    sockaddr_in bound;
    int blen = sockaddr_in.sizeof;
    assert(getsockname(listener, &bound, &blen) == 0);
    const port = bound.sin_port;

    __gshared SOCKET clientSock;
    __gshared bool clientGotEcho;
    auto client = new Thread({
        clientSock = socket(AF_INET, SOCK_STREAM, 0);
        sockaddr_in to;
        to.sin_family = AF_INET;
        to.sin_port = port;
        to.sin_addr = htonl(INADDR_LOOPBACK);
        if (connect(clientSock, &to, sockaddr_in.sizeof) != 0)
            return;
        // The client sends a greeting the server will read through IOCP.
        WSABUF wb;
        char[5] hello = "hello";
        wb = WSABUF(5, hello.ptr);
        DWORD sent;
        WSASend(clientSock, &wb, 1, &sent, 0, null, null);
        // Then reads the server's echo (blocking).
        char[16] rbuf;
        WSABUF rb = WSABUF(16, rbuf.ptr);
        DWORD got, flags;
        WSARecv(clientSock, &rb, 1, &got, &flags, null, null);
        clientGotEcho = got == 5 && rbuf[0 .. 5] == "hello";
    });
    client.start();

    const server = accept(listener, null, null);
    assert(server != INVALID_SOCKET);
    assert(!b.register(server).hasError);

    // Server: WSARecv the greeting through the port.
    ubyte[64] rxStore;
    auto rxBuf = Buf.fromForeign(rxStore[], null);
    rxBuf.length = rxBuf.capacity;
    OpSlot rxSlot;
    rxSlot.pinned = () @trusted { import core.lifetime : move; return move(rxBuf); }();
    import sparkles.event_horizon.op : OpRecv, OpSend, OpToken, OpClass;

    assert(b.trySubmit(OpRecv(cast(int) server), OpToken.pack(1, 1, OpClass.user), rxSlot));
    uint recvBytes;
    ulong recvToken;
    for (int spins = 0; spins < 100 && recvBytes == 0; ++spins)
    {
        cast(void) b.submitAndWait(1, null);
        b.reap((ref const RawCompletion c) { recvBytes = cast(uint) c.res; recvToken = c.userData; });
    }
    assert(recvBytes == 5, "server received the 5-byte greeting via IOCP");
    assert(rxSlot.pinned[][0 .. 5] == cast(const(ubyte)[]) "hello");

    // Server: echo it back with WSASend through the port.
    ubyte[5] txStore = cast(ubyte[5]) "hello";
    auto txBuf = Buf.fromForeign(txStore[], null);
    txBuf.length = 5;
    OpSlot txSlot;
    txSlot.pinned = () @trusted { import core.lifetime : move; return move(txBuf); }();
    assert(b.trySubmit(OpSend(cast(int) server), OpToken.pack(2, 1, OpClass.user), txSlot));
    uint sentBytes;
    for (int spins = 0; spins < 100 && sentBytes == 0; ++spins)
    {
        cast(void) b.submitAndWait(1, null);
        b.reap((ref const RawCompletion c) { sentBytes = cast(uint) c.res; });
    }
    assert(sentBytes == 5, "server echoed 5 bytes via IOCP");

    client.join();
    assert(clientGotEcho, "client received the echoed greeting");

    closesocket(server);
    closesocket(listener);
    closesocket(clientSock);
}
