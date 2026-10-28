/**
The Windows peer backend: I/O Completion Ports (SPEC §3.5, PLAN M11). IOCP
is natively completion-based — the exact shape the `isCompletionBackend`
concept was designed around — so the mapping is direct: each async winsock
call (`WSARecv`/`WSASend`/`AcceptEx`/`ConnectEx`) carries an
`OVERLAPPED` embedded in a backend-owned op context; `GetQueuedCompletionStatusEx`
returns that `OVERLAPPED*`, from which the op's `user_data` token and the
transferred byte count are recovered into a `RawCompletion`.

Unlike io_uring there is no submission queue to fill and flush — a winsock
call is issued immediately in `trySubmit` and either completes inline or
posts to the port later. `submitAndWait` therefore only waits (`flush` is a
no-op), and the deadline maps to the `GetQueuedCompletionStatusEx` timeout.

Status: verified under Wine two ways — the raw backend's data path
(`scripts/verify-iocp-wine.sh`) and the full `EventLoop!IocpBackend` fiber echo
(`scripts/verify-iocp-loop-wine.sh`: tier-A loop + tier-B fibers + the io
verbs). accept (`AcceptEx`), connect (`ConnectEx`, extension pointers loaded
via `WSAIoctl`), recv and send all run through the loop — full parity with the
kqueue backend; sockets are lazily associated with the port on first use.
`OpTimeout` is driven off the completion-port wait timeout (no threadpool), so
`sleep`, deadlines, `timeout`, and schedules work on Windows too — the peer
backend is at full parity with io_uring for the socket + timer surface.

Native file/pipe reads and writes require overlapped handles; synchronous
handles are rejected with `-EINVAL` before I/O is issued. Regular files also
require explicit offsets: the POSIX current-position sentinel (`ulong.max`)
is supported only for pipes, not a shared file position or append-to-EOF.
*/
module sparkles.event_horizon.backend.iocp;

version (Windows)  :  // IOCP is Windows-only.

pragma(lib, "ntdll"); // NtQueryInformationFile, RtlNtStatusToDosError

import core.sys.windows.winbase : CreateIoCompletionPort,
    INFINITE, OVERLAPPED;
import core.sys.windows.windef : DWORD, FALSE, TRUE;
import core.sys.windows.winnt : HANDLE;
import core.sys.windows.basetsd : ULONG_PTR;
import core.stdc.errno : ECANCELED, EINVAL, EIO, ENOENT, ENOMEM, EOPNOTSUPP, EOVERFLOW;
import core.time : MonoTime, Duration, msecs, nsecs, seconds;

import sparkles.event_horizon.backend.concept : BackendConfig, RawCompletion, WakeTarget;
import sparkles.event_horizon.backend.probe : BackendCaps, BackendId, LoopMode;
import sparkles.event_horizon.errors;
import sparkles.event_horizon.op : KernelTimespec, OpAccept, OpConnect, OpNop,
    OpRead, OpRecv, OpSend, OpSlot, OpTimeout, OpToken, OpWrite, NativeHandle;

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
    int GetQueuedCompletionStatusEx(HANDLE port, OverlappedEntry* entries,
        uint count, uint* removed, uint timeout, int alertable);
    int CancelIoEx(HANDLE handle, OVERLAPPED* ov);
    uint GetLastError();
    uint GetFileType(HANDLE handle);
    int ReadFile(HANDLE, void*, uint, uint*, OVERLAPPED*);
    int WriteFile(HANDLE, const(void)*, uint, uint*, OVERLAPPED*);
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
    HANDLE CreateEventW(void* attributes, int manualReset, int initialState,
        const(wchar)* name);
    int SetEvent(HANDLE event);
    int ResetEvent(HANDLE event);
    DWORD WaitForSingleObject(HANDLE handle, DWORD milliseconds);
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

// The batched API reports the operation's NTSTATUS in each entry, not in
// GetLastError (which belongs to the dequeue call).
struct OverlappedEntry
{
    ULONG_PTR key;
    OVERLAPPED* ov;
    ULONG_PTR status;
    DWORD bytes;
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
enum uint ERROR_INVALID_PARAMETER = 87;

extern (Windows) uint RtlNtStatusToDosError(uint status) nothrow @nogc;

/**
The C runtime's `errno` for a Win32 or Winsock error code, as `RawCompletion`
reports it: the values `errnoKind` reads, not Linux's numbers. Unlisted codes
are `EIO`.
*/
int winErrno(uint code) @safe pure nothrow @nogc
{
    import core.stdc.errno;

    switch (code)
    {
        case 5, 10_013:          return EACCES;      // ACCESS_DENIED, WSAEACCES
        case 6, 10_009:          return EBADF;       // INVALID_HANDLE, WSAEBADF
        case 8, 14:              return ENOMEM;      // NOT_ENOUGH_MEMORY, OUTOFMEMORY
        case 87, 10_022:         return EINVAL;      // INVALID_PARAMETER, WSAEINVAL
        case 109, 232, 233, 10_058:
            return EPIPE;   // BROKEN_PIPE, NO_DATA, PIPE_NOT_CONNECTED, WSAESHUTDOWN
        case 112, 39:            return ENOSPC;      // DISK_FULL, HANDLE_DISK_FULL
        case 121, 1460, 10_060:  return ETIMEDOUT;   // SEM_TIMEOUT, TIMEOUT, WSAETIMEDOUT
        case 995, 1223:          return ECANCELED;   // OPERATION_ABORTED, CANCELLED
        case 64, 10_054:         return ECONNRESET;  // NETNAME_DELETED, WSAECONNRESET
        case 1225, 10_061:       return ECONNREFUSED;
        case 1236, 10_053:       return ECONNABORTED;
        case 1231, 10_051:       return ENETUNREACH;
        case 1232, 10_065:       return EHOSTUNREACH;
        case 10_035:             return EWOULDBLOCK;
        case 10_038:             return ENOTSOCK;
        case 10_040:             return EMSGSIZE;
        case 10_048:             return EADDRINUSE;
        case 10_049:             return EADDRNOTAVAIL;
        case 10_050:             return ENETDOWN;
        case 10_052:             return ENETRESET;
        case 10_055:             return ENOBUFS;
        case 10_056:             return EISCONN;
        case 10_057:             return ENOTCONN;
        default:                 return EIO;
    }
}

/// The `errno` for a completion packet's NTSTATUS.
int ntErrno(uint status) @trusted nothrow @nogc
    => winErrno(RtlNtStatusToDosError(status));

/**
The handles this backend has associated with its port, and what a file
operation learned about each. Windows reports the same error for a handle
already associated with this port as for one associated with another, so the
set is what tells them apart. Entries are never removed, because the backend
does not see a handle close. A closed handle's value that comes back as a new
handle associates afresh, which resets its entry.
*/
struct Associations
{
    import core.memory : pureFree, pureMalloc;

    /// Facts a file operation reads once per associated handle.
    enum ubyte known = 1, synchronous = 2, pipe = 4;

    private static struct Entry
    {
        HANDLE handle; // null is the empty sentinel, never a real handle
        ubyte facts;
    }

    private Entry* _slots;
    private size_t _cap;
    private size_t _count;

    bool contains(HANDLE h) const @trusted nothrow @nogc => find(h) !is null;

    /// The facts recorded for `h`; 0 when there are none.
    ubyte facts(HANDLE h) const @trusted nothrow @nogc
    {
        auto e = find(h);
        return e is null ? 0 : e.facts;
    }

    void setFacts(HANDLE h, ubyte facts) @trusted nothrow @nogc
    {
        if (auto e = cast(Entry*) find(h))
            e.facts = facts;
    }

    /// Records a fresh association of `h`, forgetting any earlier facts;
    /// `false` when the table could not grow.
    bool add(HANDLE h) @trusted nothrow @nogc
    {
        if (auto e = cast(Entry*) find(h))
        {
            e.facts = 0;
            return true;
        }
        if ((_count + 1) * 4 >= _cap * 3 && !grow())
            return false;
        insert(Entry(h, 0));
        return true;
    }

    void clear() @trusted nothrow @nogc
    {
        pureFree(_slots);
        _slots = null;
        _cap = _count = 0;
    }

    private const(Entry)* find(HANDLE h) const @trusted nothrow @nogc
    {
        if (_slots is null)
            return null;
        for (auto i = slotOf(h);; i = (i + 1) & (_cap - 1))
        {
            if (_slots[i].handle is null)
                return null;
            if (_slots[i].handle is h)
                return &_slots[i];
        }
    }

    private void insert(Entry entry) @trusted nothrow @nogc
    {
        auto i = slotOf(entry.handle);
        while (_slots[i].handle !is null)
            i = (i + 1) & (_cap - 1);
        _slots[i] = entry;
        ++_count;
    }

    private size_t slotOf(HANDLE h) const @trusted pure nothrow @nogc
        => (cast(size_t) h >> 2) & (_cap - 1); // handle values are multiples of 4

    private bool grow() @trusted nothrow @nogc
    {
        const cap = _cap == 0 ? 64 : _cap * 2;
        auto slots = cast(Entry*) pureMalloc(cap * Entry.sizeof);
        if (slots is null)
            return false;
        slots[0 .. cap] = Entry.init;
        auto old = _slots[0 .. _cap];
        _slots = slots;
        _cap = cap;
        _count = 0;
        foreach (entry; old)
            if (entry.handle !is null)
                insert(entry);
        pureFree(old.ptr);
        return true;
    }
}

enum IoKind : ubyte
{
    data,     // recv/send: res is the byte count
    read,     // ReadFile: a broken pipe / end-of-file status is EOF
    accept,   // AcceptEx: res is the new socket fd
    connect,  // ConnectEx: res is 0 / -errno
    wake,     // external waker post (SPEC §5.6): persistent, res is 0
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
    HANDLE handle;      // the exact handle CancelIoEx must target
}

public:

/// The IOCP backend. Thread-affine (one port per loop thread).
struct IocpBackend
{
    @disable this(this);
    enum terminalCancelCompletions = true;

    /// Creates the completion port and starts winsock.
    IoResult!void open(in BackendConfig cfg) @trusted nothrow
    {
        WSADATA wsa;
        if (WSAStartup(0x0202, &wsa) != 0) // request Winsock 2.2
            return ioErr!void(WSAGetLastError(), OpKind.none, IoErrorStage.setup,
                "WSAStartup failed");
        _winsockStarted = true;
        _port = CreateIoCompletionPort(INVALID_HANDLE_VALUE, null, 0, 0);
        if (_port is null)
        {
            close();
            return ioErr!void(1, OpKind.none, IoErrorStage.setup,
                "CreateIoCompletionPort failed");
        }
        // Manual-reset: one signal represents any number of queued IOCP
        // completions. This is the handle a native Win32 message host folds
        // into MsgWaitForMultipleObjectsEx.
        _hostEvent = CreateEventW(null, TRUE, FALSE, null);
        if (_hostEvent is null)
        {
            close();
            return ioErr!void(1, OpKind.none, IoErrorStage.setup,
                "CreateEventW(host bridge) failed");
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
        foreach (kind; [OpKind.nop, OpKind.recv, OpKind.send, OpKind.timeout,
            OpKind.read, OpKind.write])
            _caps.opBits |= 1UL << kind;
        if (_acceptEx !is null)
            _caps.opBits |= 1UL << OpKind.accept;
        if (_connectEx !is null)
            _caps.opBits |= 1UL << OpKind.connect;
        return ioOk();
    }

    private void loadExt(SOCKET s, GUID guid, void** target) @trusted nothrow @nogc
    {
        DWORD bytes;
        cast(void) WSAIoctl(s, SIO_GET_EXTENSION_FUNCTION_POINTER,
            &guid, GUID.sizeof, target, (void*).sizeof, &bytes, null, null);
    }

    /// Closes the port and winsock and forgets all runtime state, so the
    /// backend can open again. A second call does nothing.
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
        if (_hostEvent !is null)
        {
            CloseHandle(_hostEvent);
            _hostEvent = null;
        }
        _associated.clear();
        _timerCount = 0;
        _readyHead = _readyCount = 0;
        _dequeueError = 0;
        _freeHead = uint.max;
        _acceptEx = null;
        _connectEx = null;
        _caps = BackendCaps.init;
        if (_winsockStarted)
        {
            WSACleanup(); // one per successful WSAStartup: Winsock counts them
            _winsockStarted = false;
        }
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
        if (const failed = ensureAssociated(cast(HANDLE) s))
            return ioErr!void(-failed, OpKind.none, IoErrorStage.registration,
                "CreateIoCompletionPort(assoc) failed");
        return ioOk();
    }

    /**
    Associates a handle with the port on its first operation, so the loop's
    verbs (which never call `register`) work. Returns 0 or `-errno`.

    Every operation asks Windows, rather than trusting a cached value, because
    a closed handle's value can return as a new handle. Windows answers a
    repeated association with ERROR_INVALID_PARAMETER whether the handle is
    this port's or another's; only a handle in `_associated` is this port's,
    and any other is rejected with `EINVAL` rather than left to complete on
    a port that will never deliver it here.
    */
    private int ensureAssociated(HANDLE handle) @safe nothrow @nogc
    {
        bool fresh;
        return associate(handle, fresh);
    }

    /// As `ensureAssociated`; `fresh` says whether this call made the
    /// association, so facts recorded for the value belong to another handle.
    private int associate(HANDLE handle, out bool fresh) @trusted nothrow @nogc
    {
        if (CreateIoCompletionPort(handle, _port, 0, 0) !is null)
        {
            fresh = true;
            return _associated.add(handle) ? 0 : -ENOMEM;
        }
        const error = GetLastError();
        if (error == ERROR_INVALID_PARAMETER && _associated.contains(handle))
            return 0;
        return -winErrno(error);
    }

    // ── lowering: issue the winsock async call immediately ──────────────────

    /// One operation moves at most `int.max` bytes, so its count never reads as
    /// `-errno`. Linux caps a single transfer below that too; callers loop.
    private static uint transferLength(size_t length) @safe pure nothrow @nogc
        => length > int.max ? int.max : cast(uint) length;

    /// A NOP: post a synthetic completion to the port.
    bool trySubmit(in OpNop, OpToken token, ref OpSlot) @trusted nothrow @nogc
    {
        if (_readyCount == _ready.length)
            return false;
        auto op = acquire();
        if (op is null)
            return false;
        op.token = token.raw;
        if (!PostQueuedCompletionStatus(_port, 0, 0, &op.ov))
            return reject(op, -winErrno(GetLastError()));
        SetEvent(_hostEvent);
        return true;
    }

    /**
    The native wake capability (SPEC §5.6): binds one persistent op context
    to `token` and returns the target a `Waker` posts to the port —
    IOCP needs no armed op, and `PostQueuedCompletionStatus` is thread-safe
    by contract. The context lives until `close()` frees the slab, which
    the loop does only after retiring every `Waker` copy.
    */
    WakeTarget nativeWaker(OpToken token) @trusted nothrow @nogc
    {
        auto op = acquire();
        if (op is null)
            return WakeTarget.init;
        op.token = token.raw;
        op.kind = IoKind.wake;
        WakeTarget w = {port: cast(void*) _port, ov: cast(void*) &op.ov,
            event: cast(void*) _hostEvent};
        return w;
    }

    /// A socket receive into the pinned buffer's capacity (`WSARecv`).
    bool trySubmit(in OpRecv o, OpToken token, ref OpSlot slot) @trusted nothrow @nogc
    {
        if (_readyCount == _ready.length)
            return false;
        auto op = acquire();
        if (op is null)
            return false;
        op.token = token.raw;
        auto space = slot.pinned.space();
        op.handle = cast(HANDLE) cast(SOCKET) o.fd;
        if (const failed = ensureAssociated(op.handle))
            return reject(op, failed);
        op.buf = WSABUF(transferLength(space.length), cast(char*) space.ptr);
        DWORD flags, recvd;
        const rc = WSARecv(cast(SOCKET) o.fd, &op.buf, 1, &recvd, &flags, &op.ov, null);
        if (rc == SOCKET_ERROR && WSAGetLastError() != WSA_IO_PENDING)
            return reject(op, -winErrno(WSAGetLastError()));
        repairHostSignalAfterIssue();
        return true;
    }

    /// A socket send of the pinned buffer's valid bytes (`WSASend`).
    bool trySubmit(in OpSend o, OpToken token, ref OpSlot slot) @trusted nothrow @nogc
    {
        if (_readyCount == _ready.length)
            return false;
        auto op = acquire();
        if (op is null)
            return false;
        op.token = token.raw;
        auto bytes = slot.pinned[];
        op.handle = cast(HANDLE) cast(SOCKET) o.fd;
        if (const failed = ensureAssociated(op.handle))
            return reject(op, failed);
        op.buf = WSABUF(transferLength(bytes.length), cast(char*) bytes.ptr);
        DWORD sent;
        const rc = WSASend(cast(SOCKET) o.fd, &op.buf, 1, &sent, 0, &op.ov, null);
        if (rc == SOCKET_ERROR && WSAGetLastError() != WSA_IO_PENDING)
            return reject(op, -winErrno(WSAGetLastError()));
        repairHostSignalAfterIssue();
        return true;
    }

    /// Reads an overlapped native pipe or a file at an explicit offset.
    bool trySubmit(in OpRead o, OpToken token, ref OpSlot slot) @safe nothrow @nogc
        => fileIo!true((() @trusted => cast(NativeHandle) o.fd)(), o.offset, token, slot);

    /// Writes an overlapped native pipe or a file at an explicit offset.
    bool trySubmit(in OpWrite o, OpToken token, ref OpSlot slot) @safe nothrow @nogc
        => fileIo!false((() @trusted => cast(NativeHandle) o.fd)(), o.offset, token, slot);

    /// The `Associations` facts for a file or pipe handle, or `-errno`.
    /// Asked once per association: a handle's mode and type never change.
    private static int fileFacts(scope NativeHandle handle) @safe nothrow @nogc
    {
        import sparkles.event_horizon.sys.nt : IO_STATUS_BLOCK, NtQueryInformationFile;

        IO_STATUS_BLOCK io;
        uint mode;
        const status = (() @trusted => NtQueryInformationFile(handle, &io,
            &mode, mode.sizeof, 16 /* FileModeInformation */))();
        if (status != 0)
            return -ntErrno(status);
        enum synchronousModes = 0x10 | 0x20; // ALERT / NONALERT
        int facts = Associations.known;
        if (mode & synchronousModes)
            facts |= Associations.synchronous;
        if ((() @trusted => GetFileType(handle))() == 3) // FILE_TYPE_PIPE
            facts |= Associations.pipe;
        return facts;
    }

    private bool fileIo(bool reading)(scope NativeHandle handle, ulong offset,
        OpToken token, ref OpSlot slot) @safe nothrow @nogc
    {
        if (_readyCount == _ready.length)
            return false;
        auto op = acquire();
        if (op is null)
            return false;
        op.token = token.raw;
        // HANDLE is an opaque integer token in pointer-shaped ABI storage;
        // retaining that token does not retain a pointer into the descriptor.
        op.handle = (() @trusted => cast(HANDLE) cast(size_t) handle)();
        // A handle another port owns is rejected here, before any I/O.
        bool fresh;
        if (const failed = associate(op.handle, fresh))
            return reject(op, failed);
        auto facts = _associated.facts(op.handle);
        if (fresh || !(facts & Associations.known))
        {
            const probed = fileFacts(handle);
            if (probed < 0)
                return reject(op, probed);
            facts = cast(ubyte) probed;
            _associated.setFacts(op.handle, facts);
        }
        // A synchronous handle can return success without ever posting a
        // terminal packet (or block this worker).
        if (facts & Associations.synchronous)
            return reject(op, -EINVAL);
        static if (reading)
            op.kind = IoKind.read;
        // Async regular files have no implicit shared file position. Never
        // reinterpret ulong.max as WriteFile's append-to-EOF sentinel.
        if (offset == ulong.max && !(facts & Associations.pipe))
            return reject(op, -EINVAL);
        if (offset != ulong.max)
            (() @trusted {
                op.ov.Offset = cast(uint) offset;
                op.ov.OffsetHigh = cast(uint)(offset >> 32);
            })();
        uint transferred;
        int issued;
        static if (reading)
        {
            auto space = slot.pinned.space();
            // The loop's pinned buffer and this backend's OVERLAPPED remain
            // live through the terminal packet, even after CancelIoEx.
            issued = (() @trusted => ReadFile(handle, space.ptr,
                transferLength(space.length), &transferred, &op.ov))();
        }
        else
        {
            auto bytes = slot.pinned[];
            issued = (() @trusted => WriteFile(handle, bytes.ptr,
                transferLength(bytes.length), &transferred, &op.ov))();
        }
        if (!issued)
        {
            const code = (() @trusted => GetLastError())();
            if (code != 997) // ERROR_IO_PENDING: the port owns completion
            {
                static if (reading)
                    if (code == 109 || code == 38) // BROKEN_PIPE / HANDLE_EOF
                        return reject(op, 0);
                return reject(op, -winErrno(code));
            }
        }
        repairHostSignalAfterIssue();
        return true;
    }

    /// A relative timer, driven off the completion-port wait timeout (no
    /// threadpool): the deadline is tracked and its completion synthesized
    /// when it expires. `res` is 0 on expiry.
    bool trySubmit(in OpTimeout o, OpToken token, ref OpSlot) @trusted nothrow @nogc
    {
        if (_timerCount >= _timers.length)
            return false;
        const now = MonoTime.currTime;
        const room = MonoTime.max - now;
        // Compare before converting seconds to clock ticks, so huge finite
        // deadlines saturate rather than wrapping into an immediate timeout.
        Duration rel = o.rel.tv_sec >= room.total!"seconds" ? room
            : o.rel.tv_sec.seconds + o.rel.tv_nsec.nsecs;
        if (rel < Duration.zero)
            rel = Duration.zero;
        if (rel > room)
            rel = room;
        _timers[_timerCount++] = Timer(token.raw, now + rel);
        return true;
    }

    /// Async accept via `AcceptEx`: pre-create the accept socket, associate it
    /// with the port, and issue AcceptEx. On completion `res` is the new fd.
    bool trySubmit(in OpAccept o, OpToken token, ref OpSlot) @trusted nothrow @nogc
    {
        if (_readyCount == _ready.length)
            return false;
        auto op = acquire();
        if (op is null)
            return false;
        op.token = token.raw;
        if (_acceptEx is null)
            return reject(op, -EOPNOTSUPP);
        const listenSock = cast(SOCKET) o.listenFd;
        if (const failed = ensureAssociated(cast(HANDLE) listenSock))
            return reject(op, failed);
        const acceptSock = WSASocketW(AF_INET, SOCK_STREAM, IPPROTO_TCP, null, 0,
            WSA_FLAG_OVERLAPPED);
        if (acceptSock == INVALID_SOCKET)
            return reject(op, -winErrno(WSAGetLastError()));
        if (const failed = ensureAssociated(cast(HANDLE) acceptSock))
        {
            closesocket(acceptSock);
            return reject(op, failed);
        }
        op.kind = IoKind.accept;
        op.sock = acceptSock;
        op.listenSock = listenSock;
        op.handle = cast(HANDLE) listenSock;
        DWORD received;
        // localAddrLength/remoteAddrLength = sizeof(sockaddr_in)+16 = 32.
        const rc = _acceptEx(listenSock, acceptSock, op.addrBuf.ptr, 0, 32, 32,
            &received, &op.ov);
        if (rc == 0 && WSAGetLastError() != WSA_IO_PENDING)
        {
            const error = WSAGetLastError();
            closesocket(acceptSock);
            return reject(op, -winErrno(error));
        }
        repairHostSignalAfterIssue();
        return true;
    }

    /// Async connect via `ConnectEx`: the socket must be bound first. On
    /// completion `res` is 0 / -errno.
    bool trySubmit(in OpConnect o, OpToken token, ref OpSlot) @trusted nothrow @nogc
    {
        if (_readyCount == _ready.length)
            return false;
        auto op = acquire();
        if (op is null)
            return false;
        op.token = token.raw;
        if (_connectEx is null)
            return reject(op, -EOPNOTSUPP);
        const s = cast(SOCKET) o.fd;
        // ConnectEx requires a bound socket; bind to the wildcard address.
        sockaddr_in local;
        local.sin_family = AF_INET;
        local.sin_addr = htonl(INADDR_ANY);
        cast(void) bind(s, &local, sockaddr_in.sizeof);
        if (const failed = ensureAssociated(cast(HANDLE) s))
            return reject(op, failed);
        op.kind = IoKind.connect;
        op.sock = s;
        op.handle = cast(HANDLE) s;
        DWORD sent;
        const rc = _connectEx(s, o.addr.storage.ptr, o.addr.len, null, 0, &sent, &op.ov);
        if (rc == 0 && WSAGetLastError() != WSA_IO_PENDING)
            return reject(op, -winErrno(WSAGetLastError()));
        repairHostSignalAfterIssue();
        return true;
    }

    /// No submission queue on IOCP; surface any latched non-blocking-drain fault.
    IoResult!uint flush() @safe nothrow @nogc
        => _dequeueError == 0 ? ioOk(0u)
            : ioErr!uint(EIO, OpKind.none, IoErrorStage.submit,
                "GetQueuedCompletionStatusEx failed");

    /** Event that mirrors IOCP completions for a foreign native host wait. */
    void* nativeHostWaitHandle() @trusted pure nothrow @nogc
        => cast(void*) _hostEvent;

    /**
    Narrows a host-requested timeout to the next Event Horizon timer.

    `uint.max` means infinite, matching the Win32 wait APIs.
    */
    uint nativeHostWaitTimeout(uint requestedMs) @trusted nothrow @nogc
    {
        if (_readyCount != 0)
            return 0; // queued completions are already due
        ulong waitMs = requestedMs;
        const now = MonoTime.currTime;
        foreach (i; 0 .. _timerCount)
        {
            const rem = waitMilliseconds(_timers[i].deadline - now);
            if (rem < waitMs)
                waitMs = rem;
        }
        return waitMs > uint.max ? uint.max : cast(uint) waitMs;
    }

    /**
    Resets the level signal before the loop performs its closing non-blocking
    drain. A completion racing after the reset sets it again; one queued
    before the reset is found by that drain. This is the lost-wake repair.
    */
    void prepareNativeHostDrain() @trusted nothrow @nogc
    {
        ResetEvent(_hostEvent);
    }

    /**
    Waits for at least one completion (or until `deadline`), stashing a batch
    for `reap`. Already-stashed results are never overwritten by a wait.
    */
    IoResult!uint submitAndWait(uint want, scope const KernelTimespec* deadline)
        @trusted nothrow
    {
        if (want == 0)
            return ioOk(0u);

        // Something is ready already: a completion the issue-time probe took
        // off the port (`repairHostSignalAfterIssue`), or a synthesized one.
        // Waiting would delay it, and the dequeue below would overwrite the
        // held completion and lose it — the operation it belongs to would
        // never complete. An overlapped call that succeeds at once queues its
        // packet before the probe runs, so this is the common case under Wine
        // and a race on Windows.
        expireTimers();
        if (_readyCount != 0)
            return ioOk(_readyCount);

        // The wait timeout is the min of the caller's deadline and the
        // earliest pending timer, so the port wakes when a timer is due.
        ulong waitMs = deadline is null ? ulong.max
            : deadline.tv_sec >= uint.max / 1000 ? uint.max - 1
            : waitMilliseconds(deadline.tv_sec.seconds + deadline.tv_nsec.nsecs);
        const now = MonoTime.currTime;
        foreach (i; 0 .. _timerCount)
        {
            const rem = waitMilliseconds(_timers[i].deadline - now);
            if (rem < waitMs)
                waitMs = rem;
        }
        const timeout = waitMs == ulong.max ? INFINITE
            : (waitMs > uint.max ? uint.max : cast(DWORD) waitMs);

        dequeue(timeout);
        if (_dequeueError != 0)
            return ioErr!uint(EIO, OpKind.none, IoErrorStage.completion,
                "GetQueuedCompletionStatusEx failed");
        expireTimers(); // synthesize any timers now due
        return ioOk(_readyCount);
    }

    /// Non-blocking drain: the stashed completion, expired timers, plus any
    /// others already queued on the port.
    uint reap(Sink)(scope Sink sink) @trusted
    {
        uint n;
        expireTimers();
        for (;;)
        {
            while (_readyCount != 0)
            {
                const c = _ready[_readyHead];
                _readyHead = (_readyHead + 1) % _ready.length;
                --_readyCount;
                // Pop before dispatch: a callback may submit another op and
                // its host-signal repair may enqueue a new batch here.
                sink(c);
                ++n;
            }
            expireTimers();
            if (_readyCount == 0 && dequeue(0) == 0)
                break;
        }
        return n;
    }

    /// Acknowledges cancellation separately from the target's terminal packet.
    /// Neither its OVERLAPPED nor its pinned storage is released by CancelIoEx.
    bool trySubmitCancel(OpToken cancelSlot, OpToken target) @trusted nothrow @nogc
    {
        if (_readyCount + 2 > _ready.length)
            return false;
        foreach (i; 0 .. _timerCount)
        {
            if (_timers[i].token != target.raw)
                continue;
            _timers[i] = _timers[--_timerCount];
            enqueue(RawCompletion(target.raw, -ECANCELED, 0));
            enqueue(RawCompletion(cancelSlot.raw, 0, 0));
            SetEvent(_hostEvent); // a native host waits on the event, not the queue
            return true;
        }
        int res = -ENOENT;
        foreach (ref op; _ops)
        {
            if (!op.inUse || op.token != target.raw || op.kind == IoKind.wake)
                continue;
            if (op.handle !is null)
            {
                if (CancelIoEx(op.handle, &op.ov))
                    res = 0;
                else
                    res = GetLastError() == 1168 ? -ENOENT : -winErrno(GetLastError());
            }
            break;
        }
        // A packet may already have been dequeued into _ready, or may be
        // queued on the port: completion won, and must still be delivered.
        enqueue(RawCompletion(cancelSlot.raw, res, 0));
        SetEvent(_hostEvent);
        return true;
    }

private:
    /**
    Starting an overlapped operation resets its `hEvent`. If an older
    completion had already signalled the shared event, that reset would hide
    it from the host. Repair by remembering already-queued completions and
    restoring the level signal. A completion racing after this zero-time
    probe signals the event itself.
    */
    void repairHostSignalAfterIssue() @trusted nothrow @nogc
    {
        if (_readyCount != 0)
        {
            SetEvent(_hostEvent);
            return;
        }

        if (dequeue(0) != 0)
            SetEvent(_hostEvent);
    }

    /// A bounded ring also used for software timers and cancel acknowledgments.
    private void enqueue(RawCompletion completion) @trusted nothrow @nogc
    {
        assert(_readyCount < _ready.length);
        _ready[(_readyHead + _readyCount) % _ready.length] = completion;
        ++_readyCount;
    }

    /// Kernel rejection is a terminal result, never submission backpressure.
    private bool reject(IocpOp* op, int res) @trusted nothrow @nogc
    {
        enqueue(RawCompletion(op.token, res, 0));
        release(op);
        SetEvent(_hostEvent);
        return true;
    }

    private uint dequeue(DWORD timeout) @trusted nothrow @nogc
    {
        OverlappedEntry[64] entries;
        const room = cast(uint)(_ready.length - _readyCount);
        if (room == 0)
            return 0;
        uint removed;
        if (!GetQueuedCompletionStatusEx(_port, entries.ptr, room, &removed, timeout, FALSE))
        {
            const error = GetLastError();
            if (error != 258) // WAIT_TIMEOUT is an ordinary empty dequeue
                _dequeueError = error;
            return 0;
        }
        foreach (ref entry; entries[0 .. removed])
            enqueue(ovToCompletion(entry.ov, entry.bytes, cast(uint) entry.status));
        return removed;
    }

    /// Moves any now-due timers into the synthesized-completion buffer.
    void expireTimers() @trusted nothrow @nogc
    {
        const now = MonoTime.currTime;
        uint w;
        foreach (i; 0 .. _timerCount)
        {
            if (_timers[i].deadline <= now && _readyCount < _ready.length)
                enqueue(RawCompletion(_timers[i].token, 0, 0));
            else
                _timers[w++] = _timers[i]; // keep the still-pending ones
        }
        _timerCount = w;
    }

    RawCompletion ovToCompletion(OVERLAPPED* ov, DWORD bytes, uint status)
        @trusted nothrow @nogc
    {
        auto op = cast(IocpOp*) ov; // ov is the first field of IocpOp
        const token = op.token;
        const ok = cast(int) status >= 0;
        const failure = ok ? 0 : -ntErrno(status);
        int res;
        final switch (op.kind)
        {
            case IoKind.data:
            case IoKind.read:
                res = ok ? cast(int) bytes : failure;
                break;
            case IoKind.accept:
                if (ok && op.sock <= int.max)
                {
                    // Inherit the listener's properties; res is the new fd.
                    setsockopt(op.sock, SOL_SOCKET, SO_UPDATE_ACCEPT_CONTEXT,
                        &op.listenSock, SOCKET.sizeof);
                    res = cast(int) op.sock;
                }
                else
                {
                    // An accepted socket whose value does not fit the `int`
                    // that `Stream` holds is closed, not leaked.
                    closesocket(op.sock);
                    res = ok ? -EOVERFLOW : failure;
                }
                break;
            case IoKind.connect:
                if (ok)
                {
                    setsockopt(op.sock, SOL_SOCKET, SO_UPDATE_CONNECT_CONTEXT, null, 0);
                    res = 0;
                }
                else
                    res = failure;
                break;
            case IoKind.wake:
                // Persistent (SPEC §5.6): the op context is the posting
                // target for every future wake — never released here.
                return RawCompletion(token, 0, 0);
        }
        if (op.kind == IoKind.read
            && (status == 0xc000_014b || status == 0xc000_0011)) // PIPE_BROKEN / END_OF_FILE
            res = 0;
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
        op.ov.hEvent = _hostEvent;
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

    static struct Timer
    {
        ulong token;
        MonoTime deadline;
    }

    // Round up, never down: sub-millisecond truncation fires timers early
    // against the scheduler's monotonic clock and can cause zero-time spins.
    private static uint waitMilliseconds(Duration duration) @safe pure nothrow @nogc
    {
        if (duration <= Duration.zero)
            return 0;
        const ms = duration.total!"msecs";
        if (ms >= uint.max - 1)
            return uint.max - 1; // uint.max means infinite, not a finite wait
        return cast(uint) ms + (duration > ms.msecs ? 1 : 0);
    }

    HANDLE _port;
    HANDLE _hostEvent;
    LPFN_ACCEPTEX _acceptEx;
    LPFN_CONNECTEX _connectEx;
    Timer[64] _timers;
    uint _timerCount;
    RawCompletion[64] _ready;
    uint _readyHead;
    uint _readyCount;
    uint _dequeueError;
    Associations _associated;
    bool _winsockStarted;
    IocpOp[] _ops;
    uint _cap;
    uint _freeHead = uint.max;
    BackendCaps _caps;
}

/// The capability mask names the lowered ops, not the complete vocabulary.
@("iocp.caps.exactLoweringMask")
@system unittest
{
    IocpBackend b;
    assert(!b.open(BackendConfig()).hasError);
    scope (exit) b.close();
    foreach (kind; [OpKind.nop, OpKind.recv, OpKind.send, OpKind.timeout])
        assert(b.caps.supports(kind));
    assert(b.caps.supports(OpKind.accept) == (b._acceptEx !is null));
    assert(b.caps.supports(OpKind.connect) == (b._connectEx !is null));
    assert(b.caps.supports(OpKind.read));
    assert(b.caps.supports(OpKind.write));
    assert(!b.caps.supports(OpKind.fsync));
}

/// A full dequeue batch, an overflow batch, and callback-side submission all
/// survive without overwriting stashed packets or duplicating tokens.
@("iocp.batch.multipleDrainsAndReentrantSubmission")
@system unittest
{
    import sparkles.event_horizon.op : OpClass;

    IocpBackend b;
    assert(!b.open(BackendConfig()).hasError);
    scope (exit) b.close();
    OpSlot slot;
    foreach (i; 0 .. 192)
        assert(b.trySubmit(OpNop(), OpToken.pack(i, 1, OpClass.user), slot));
    assert(b.submitAndWait(1, null).value == 64);
    uint[194] seen;
    b.reap((ref const RawCompletion c) {
        const index = OpToken(c.userData).index;
        assert(index < seen.length);
        assert((index == 193 ? c.res < 0 : c.res == 0) && seen[index]++ == 0);
        if (index == 0)
        {
            assert(b.trySubmit(OpNop(), OpToken.pack(192, 1, OpClass.user), slot));
            assert(b.trySubmit(OpRecv(-1), OpToken.pack(193, 1, OpClass.user), slot));
        }
    });
    foreach (count; seen)
        assert(count == 1);
}

/// Software timers and a completion that already won still acknowledge the
/// internal cancel slot; only a pending timer changes to ECANCELED.
@("iocp.cancel.timerAndCompletedTarget")
@system unittest
{
    import sparkles.event_horizon.op : OpClass;

    IocpBackend b;
    assert(!b.open(BackendConfig()).hasError);
    scope (exit) b.close();
    OpSlot slot;
    const target = OpToken.pack(1, 1, OpClass.user);
    const cancel = OpToken.pack(2, 1, OpClass.internal);
    assert(b.trySubmit(OpTimeout(KernelTimespec(60, 0)), target, slot));
    assert(b.trySubmitCancel(cancel, target));
    uint targets, cancels;
    b.reap((ref const RawCompletion c) {
        if (c.userData == target.raw)
        {
            ++targets;
            assert(c.res == -ECANCELED);
        }
        else
        {
            ++cancels;
            assert(c.userData == cancel.raw && c.res == 0);
        }
    });
    assert(targets == 1 && cancels == 1);
    assert(b.trySubmitCancel(cancel, target));
    assert(b.reap((ref const RawCompletion c) {
        assert(c.userData == cancel.raw && c.res == -ENOENT);
    }) == 1);
}

version (unittest)
private void connectedSockets(out SOCKET client, out SOCKET server) @system nothrow
{
    const listener = socket(AF_INET, SOCK_STREAM, 0);
    assert(listener != INVALID_SOCKET);
    scope (exit) closesocket(listener);
    sockaddr_in addr;
    addr.sin_family = AF_INET;
    addr.sin_addr = htonl(INADDR_LOOPBACK);
    assert(bind(listener, &addr, addr.sizeof) == 0);
    assert(listen(listener, 1) == 0);
    int length = addr.sizeof;
    assert(getsockname(listener, &addr, &length) == 0);
    client = socket(AF_INET, SOCK_STREAM, 0);
    assert(client != INVALID_SOCKET);
    assert(connect(client, &addr, addr.sizeof) == 0);
    server = accept(listener, null, null);
    assert(server != INVALID_SOCKET);
}

/// CancelIoEx races the receive, but never releases its OVERLAPPED before the
/// terminal packet. Both the target and cancel complete exactly once.
@("iocp.cancel.pendingReceiveAndCompletionRaces")
@system unittest
{
    import sparkles.event_horizon.op : OpClass;

    IocpBackend b;
    assert(!b.open(BackendConfig()).hasError);
    scope (exit) b.close();
    foreach (mode; 0 .. 3)
    {
        SOCKET client, server;
        connectedSockets(client, server);
        scope (exit) closesocket(client);
        scope (exit) closesocket(server);
        ubyte[32] storage;
        OpSlot slot;
        slot.pinned = Buf.fromForeign(storage[], null);
        const target = OpToken.pack(1, 1, OpClass.user);
        const cancel = OpToken.pack(2, 1, OpClass.internal);
        assert(b.trySubmit(OpRecv(cast(int) server), target, slot));
        Thread sender;
        if (mode == 1)
            sender = new Thread({
                char[1] payload = 'x';
                WSABUF buf = WSABUF(1, payload.ptr);
                DWORD sent;
                assert(WSASend(client, &buf, 1, &sent, 0, null, null) == 0);
            }).start();
        else if (mode == 2)
        {
            char[1] payload = 'x';
            WSABUF buf = WSABUF(1, payload.ptr);
            DWORD sent;
            assert(WSASend(client, &buf, 1, &sent, 0, null, null) == 0);
            KernelTimespec deadline = KernelTimespec(2, 0);
            assert(b.submitAndWait(1, &deadline).value != 0);
        }
        assert(b.trySubmitCancel(cancel, target));
        uint targets, cancels;
        while (targets + cancels < 2)
        {
            KernelTimespec deadline = KernelTimespec(2, 0);
            assert(b.submitAndWait(1, &deadline).value != 0);
            b.reap((ref const RawCompletion c) {
                if (c.userData == target.raw)
                {
                    assert(++targets == 1);
                    assert(c.res == (mode == 0 ? -ECANCELED : 1)
                        || (mode == 1 && c.res == -ECANCELED));
                }
                else
                {
                    assert(c.userData == cancel.raw && ++cancels == 1);
                    assert(c.res == 0 || c.res == -ENOENT);
                }
            });
        }
        if (sender !is null)
            sender.join();
        assert(b.reap((ref const RawCompletion c) {}) == 0);
    }
}

/// Hard port faults do not masquerade as an ordinary timeout or empty reap.
@("iocp.wait.closedPortSurfacesAHardError")
@system unittest
{
    IocpBackend b;
    assert(!b.open(BackendConfig()).hasError);
    scope (exit) b.close();
    CloseHandle(b._port);
    b._port = null;
    KernelTimespec zero;
    assert(b.submitAndWait(1, &zero).hasError);
    assert(b.flush().hasError);
}

/// A synchronous kernel rejection is delivered once instead of making the
/// loop retry an invalid operation as though submission resources were full.
@("iocp.rejection.invalidSocketIsATerminalCompletion")
@system unittest
{
    import sparkles.event_horizon.op : OpClass;

    IocpBackend b;
    assert(!b.open(BackendConfig()).hasError);
    scope (exit) b.close();
    OpSlot slot;
    const token = OpToken.pack(1, 1, OpClass.user);
    assert(b.trySubmit(OpRecv(-1), token, slot));
    assert(b.reap((ref const RawCompletion c) {
        assert(c.userData == token.raw && c.res < 0);
    }) == 1);
}

/// Win32 and Winsock codes become the C runtime's `errno` values, and a
/// completion's NTSTATUS goes through the same table.
@("iocp.errors.winErrnoAndNtStatus")
@system unittest
{
    import core.stdc.errno : ECONNRESET, EINVAL, EPIPE;

    assert(winErrno(109) == EPIPE);        // ERROR_BROKEN_PIPE
    assert(winErrno(10_054) == ECONNRESET);
    assert(winErrno(87) == EINVAL);
    assert(winErrno(0xdead) == EIO);
    assert(ntErrno(0xc000_0120) == ECANCELED); // STATUS_CANCELLED
    assert(ntErrno(0xc000_014b) == EPIPE);     // STATUS_PIPE_BROKEN
}

/// A socket another completion port owns is rejected with `EINVAL`, not
/// issued to complete on a port that never delivers it here. A socket this
/// backend associated keeps working on later operations.
@("iocp.associate.foreignPortIsRejected")
@system unittest
{
    import core.stdc.errno : EINVAL;
    import sparkles.event_horizon.op : OpClass;

    IocpBackend b;
    assert(!b.open(BackendConfig()).hasError);
    scope (exit) b.close();
    SOCKET client, server;
    connectedSockets(client, server);
    scope (exit) closesocket(client);
    scope (exit) closesocket(server);

    auto other = CreateIoCompletionPort(INVALID_HANDLE_VALUE, null, 0, 0);
    assert(other !is null);
    scope (exit) CloseHandle(other);
    assert(CreateIoCompletionPort(cast(HANDLE) server, other, 0, 0) !is null);

    ubyte[8] storage;
    OpSlot slot;
    slot.pinned = Buf.fromForeign(storage[], null);
    const token = OpToken.pack(1, 1, OpClass.user);
    assert(b.trySubmit(OpRecv(cast(int) server), token, slot));
    assert(b.reap((ref const RawCompletion c) {
        assert(c.userData == token.raw && c.res == -EINVAL);
    }) == 1);

    // Ours: associated by the first send, recognised by the second.
    slot.pinned.length = 1;
    foreach (round; 0 .. 2)
    {
        assert(b.trySubmit(OpSend(cast(int) client), token, slot));
        KernelTimespec deadline = KernelTimespec(2, 0);
        assert(b.submitAndWait(1, &deadline).value != 0);
        assert(b.reap((ref const RawCompletion c) {
            assert(c.userData == token.raw && c.res == 1);
        }) == 1);
    }
}

/// `close` twice is harmless, and one backend's close leaves another's
/// Winsock running: every `WSAStartup` has exactly one `WSACleanup`.
@("iocp.close.idempotentAndWinsockBalanced")
@system unittest
{
    IocpBackend first, second;
    assert(!first.open(BackendConfig()).hasError);
    assert(!second.open(BackendConfig()).hasError);
    scope (exit) second.close();
    first.close();
    first.close();
    SOCKET client, server;
    connectedSockets(client, server); // asserts Winsock still works
    closesocket(client);
    closesocket(server);
    assert(!first.open(BackendConfig()).hasError, "a closed backend opens again");
    first.close();
}

/// A cancel's completions reach a native host: the event is signalled and
/// the host's wait timeout drops to zero while completions are queued.
@("iocp.cancel.signalsTheNativeHost")
@system unittest
{
    import sparkles.event_horizon.op : OpClass;

    IocpBackend b;
    assert(!b.open(BackendConfig()).hasError);
    scope (exit) b.close();
    OpSlot slot;
    const target = OpToken.pack(1, 1, OpClass.user);
    const cancel = OpToken.pack(2, 1, OpClass.internal);
    assert(b.trySubmit(OpTimeout(KernelTimespec(60, 0)), target, slot));
    b.prepareNativeHostDrain();
    assert(b.trySubmitCancel(cancel, target));
    assert(WaitForSingleObject(cast(HANDLE) b.nativeHostWaitHandle(), 0) == 0);
    assert(b.nativeHostWaitTimeout(uint.max) == 0);
    assert(b.reap((ref const RawCompletion c) {}) == 2);
}

/// Refusing a cancel under completion backpressure leaves its timer intact,
/// so draining and retrying produces exactly the two required completions.
@("iocp.cancel.backpressureLeavesTargetLive")
@system unittest
{
    import sparkles.event_horizon.op : OpClass;

    IocpBackend b;
    assert(!b.open(BackendConfig()).hasError);
    scope (exit) b.close();
    OpSlot slot;
    foreach (i; 0 .. 63)
        assert(b.trySubmit(OpNop(), OpToken.pack(i, 1, OpClass.user), slot));
    assert(b.submitAndWait(1, null).value == 63);
    const target = OpToken.pack(64, 1, OpClass.user);
    const cancel = OpToken.pack(65, 1, OpClass.internal);
    assert(b.trySubmit(OpTimeout(KernelTimespec(60, 0)), target, slot));
    assert(!b.trySubmitCancel(cancel, target));
    assert(b.reap((ref const RawCompletion c) { assert(c.res == 0); }) == 63);
    assert(b.trySubmitCancel(cancel, target));
    uint targets, cancels;
    assert(b.reap((ref const RawCompletion c) {
        if (c.userData == target.raw)
        {
            ++targets;
            assert(c.res == -ECANCELED);
        }
        else
        {
            ++cancels;
            assert(c.userData == cancel.raw && c.res == 0);
        }
    }) == 2);
    assert(targets == 1 && cancels == 1);
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
    import sparkles.test_runner.skip : skipTest;
}

/// Synchronous pipe handles must be rejected before issuing I/O: even an
/// inline-successful operation does not supply the terminal IOCP packet.
@("iocp.fileIo.rejectsSynchronousHandles")
@system unittest
{
    import core.sys.windows.winbase : CreatePipe;
    import sparkles.event_horizon.op : OpClass;

    IocpBackend b;
    assert(!b.open(BackendConfig()).hasError);
    scope (exit) b.close();
    HANDLE reader, writer;
    assert(CreatePipe(&reader, &writer, null, 0));
    scope (exit) CloseHandle(reader);
    scope (exit) CloseHandle(writer);
    ubyte[1] payload = [42];
    uint written;
    assert(WriteFile(writer, payload.ptr, 1, &written, null) && written == 1);
    OpSlot slot;
    slot.pinned = Buf.fromForeign(payload[], null);
    const token = OpToken.pack(1, 1, OpClass.user);
    assert(b.trySubmit(OpRead(reader, Buf.init, ulong.max), token, slot));
    assert(b.reap((ref const RawCompletion c) {
        assert(c.userData == token.raw && c.res == -EINVAL);
    }) == 1, "synchronous read must reject immediately, not wait for a packet");
    slot.pinned.length = 1;
    assert(b.trySubmit(OpWrite(writer, Buf.init, ulong.max), token, slot));
    assert(b.reap((ref const RawCompletion c) {
        assert(c.userData == token.raw && c.res == -EINVAL);
    }) == 1, "synchronous write must reject immediately, not wait for a packet");
    uint got;
    assert(ReadFile(reader, payload.ptr, 1, &got, null) && got == 1 && payload[0] == 42);
}

/// Native pipe reads/writes use OVERLAPPED handles, cancellation waits for the
/// target packet, and the writer's close becomes a successful zero-byte EOF.
@("iocp.pipe.readWriteCancelAndEof")
@system unittest
{
    import sparkles.event_horizon.op : OpClass;
    import sparkles.event_horizon.sys.pipe : NativePipe;

    IocpBackend b;
    assert(!b.open(BackendConfig()).hasError);
    scope (exit) b.close();
    NativePipe pipe;
    assert(!NativePipe.create(pipe).hasError);
    ubyte[16] rx;
    ubyte[5] tx = cast(ubyte[5]) "hello";
    OpSlot readSlot, writeSlot;
    readSlot.pinned = Buf.fromForeign(rx[], null);
    writeSlot.pinned = Buf.fromForeign(tx[], null);
    writeSlot.pinned.length = tx.length;
    const readToken = OpToken.pack(1, 1, OpClass.user);
    const writeToken = OpToken.pack(2, 1, OpClass.user);
    assert(b.trySubmit(OpRead(pipe.reader.borrowFd.fd, Buf.init, ulong.max), readToken, readSlot));
    assert(b.trySubmit(OpWrite(pipe.writer.borrowFd.fd, Buf.init, ulong.max), writeToken, writeSlot));
    uint reads, writes;
    while (reads + writes < 2)
    {
        KernelTimespec deadline = KernelTimespec(2, 0);
        assert(b.submitAndWait(1, &deadline).value != 0);
        b.reap((ref const RawCompletion c) {
            assert(c.res == 5);
            if (c.userData == readToken.raw)
                assert(++reads == 1);
            else
                assert(c.userData == writeToken.raw && ++writes == 1);
        });
    }
    assert(rx[0 .. 5] == tx[]);

    const cancelToken = OpToken.pack(3, 1, OpClass.internal);
    assert(b.trySubmit(OpRead(pipe.reader.borrowFd.fd, Buf.init, ulong.max), readToken, readSlot));
    assert(b.trySubmitCancel(cancelToken, readToken));
    uint cancelled, acknowledged;
    while (cancelled + acknowledged < 2)
    {
        KernelTimespec deadline = KernelTimespec(2, 0);
        assert(b.submitAndWait(1, &deadline).value != 0);
        b.reap((ref const RawCompletion c) {
            if (c.userData == readToken.raw)
                assert(c.res == -ECANCELED && ++cancelled == 1);
            else
                assert(c.userData == cancelToken.raw && c.res == 0 && ++acknowledged == 1);
        });
    }
    pipe.writer.close();
    assert(b.trySubmit(OpRead(pipe.reader.borrowFd.fd, Buf.init, ulong.max), readToken, readSlot));
    KernelTimespec deadline = KernelTimespec(2, 0);
    assert(b.submitAndWait(1, &deadline).value != 0);
    assert(b.reap((ref const RawCompletion c) {
        assert(c.userData == readToken.raw && c.res == 0);
    }) == 1);
}

/// A write to a pipe whose reader is gone fails with `EPIPE`, as on POSIX,
/// and the handle's facts are read once: a second write is rejected the
/// same way without asking again.
@("iocp.pipe.brokenPipeWriteIsEpipe")
@system unittest
{
    import core.stdc.errno : EPIPE;
    import sparkles.event_horizon.op : OpClass;
    import sparkles.event_horizon.sys.pipe : NativePipe;

    IocpBackend b;
    assert(!b.open(BackendConfig()).hasError);
    scope (exit) b.close();
    NativePipe pipe;
    assert(!NativePipe.create(pipe).hasError);
    pipe.reader.close();
    ubyte[1] tx = [1];
    OpSlot slot;
    slot.pinned = Buf.fromForeign(tx[], null);
    slot.pinned.length = 1;
    const token = OpToken.pack(1, 1, OpClass.user);
    foreach (round; 0 .. 2)
    {
        assert(b.trySubmit(OpWrite(pipe.writer.borrowFd.fd, Buf.init, ulong.max), token, slot));
        KernelTimespec deadline = KernelTimespec(2, 0);
        assert(b.submitAndWait(1, &deadline).value != 0);
        assert(b.reap((ref const RawCompletion c) {
            assert(c.userData == token.raw && c.res == -EPIPE);
        }) == 1);
    }
    auto handle = cast(HANDLE) pipe.writer.borrowFd.fd;
    assert(b._associated.facts(handle) & Associations.pipe);
}

/// One operation never asks for more than `int.max` bytes, so a completed
/// count cannot read as `-errno`.
@("iocp.transferLength.capsAtIntMax")
@safe pure nothrow @nogc unittest
{
    assert(IocpBackend.transferLength(5) == 5);
    assert(IocpBackend.transferLength(int.max) == int.max);
    assert(IocpBackend.transferLength(size_t(uint.max) + 7) == int.max);
}

/// The M11 data-path gate (runs under Wine): drive a real WSASend through the
/// IOCP port on a loopback pair and confirm the peer receives the bytes, and
/// a WSARecv through the port receives the peer's reply — proving the
/// OVERLAPPED→token completion mapping end to end. It intentionally reaps
/// through the native-host mirror event rather than blocking on GQCS, proving
/// that real socket completions wake a User32-compatible hosted wait.
@("iocp.dataPath.sendRecvThroughPort")
@system
unittest
{
    IocpBackend b;
    if (b.open(BackendConfig()).hasError)
        skipTest("winsock unavailable");
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
    assert(WaitForSingleObject(cast(HANDLE) b.nativeHostWaitHandle(), 2_000) == 0,
        "WSARecv signalled the native-host completion mirror");
    b.prepareNativeHostDrain();
    b.reap((ref const RawCompletion c) {
        recvBytes = cast(uint) c.res;
        recvToken = c.userData;
    });
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
    assert(WaitForSingleObject(cast(HANDLE) b.nativeHostWaitHandle(), 2_000) == 0,
        "WSASend signalled the native-host completion mirror");
    b.prepareNativeHostDrain();
    b.reap((ref const RawCompletion c) { sentBytes = cast(uint) c.res; });
    assert(sentBytes == 5, "server echoed 5 bytes via IOCP");

    client.join();
    assert(clientGotEcho, "client received the echoed greeting");

    closesocket(server);
    closesocket(listener);
    closesocket(clientSock);
}
