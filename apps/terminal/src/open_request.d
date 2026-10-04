/**
Open requests (`TDV1`–`TDV4`): a program in a pane asks for a local file to
be opened, and the terminal opens it in a viewer pane beside that pane.

The requests arrive on a server thread — the desktop's `xdg-open` shim over
the per-app socket ($(LREF startOpenServer)), Android's `termux-open` / `am
start -a VIEW` through the `am` server — and reach the frame through a small
queue: the server decides what it can alone (the file is missing, unreadable,
or not a kind the viewer shows), queues the rest, and answers the requesting
command once the frame has opened the pane (`TDV3`). The pane that asked is
found from the socket peer's process: its ancestry leads to one pane's child
($(LREF paneOfProcess)).

The decision half is pure and host-tested; the sockets are Posix.
*/
module open_request;

version (Posix):

import core.sync.mutex : Mutex;
import core.time : msecs, MonoTime;

import sparkles.doc_view.kind : ViewKind, viewKindOf;

// ─────────────────────────────────────────────────────────────────────────────
// Deciding.
// ─────────────────────────────────────────────────────────────────────────────

/// What becomes of a request.
enum OpenVerdict : ubyte
{
    open,    /// the viewer shows it: queue it for the frame
    refuse,  /// missing or unreadable: status 1 and a message (`TDV3`)
    decline, /// a kind the viewer does not show: the platform's handler
}

/// A verdict and, for a refusal, why.
struct OpenCheck
{
    OpenVerdict verdict;
    string message;
}

/**
The local path a request names: a `file://` URI decoded, a relative path made
absolute against the requester's directory `cwd`. Null for anything that is
not a local file (`https:`, `mailto:`, …).
*/
string localPathOf(string target, string cwd) @safe
{
    import std.algorithm.searching : canFind, startsWith;
    import std.path : buildNormalizedPath, isAbsolute;
    import std.uri : decodeComponent;

    if (target.startsWith("file://"))
    {
        auto rest = target["file://".length .. $];
        // `file://host/path`: only the local host is ours.
        if (!rest.startsWith("/"))
        {
            if (!rest.startsWith("localhost/"))
                return null;
            rest = rest["localhost".length .. $];
        }
        try
            return decodeComponent(rest).buildNormalizedPath;
        catch (Exception)
            return null;
    }
    // A scheme other than `file:` is not a path.
    foreach (i, c; target)
    {
        if (c == ':')
            return null;
        if (c == '/')
            break;
    }
    if (!target.length)
        return null;
    return target.isAbsolute ? target.buildNormalizedPath
        : buildNormalizedPath(cwd.length ? cwd : "/", target);
}

/// Whether the viewer takes `path`, by what is on disk.
OpenCheck checkOpen(string path) @system
{
    import std.file : exists, isDir;
    import std.stdio : File;

    if (!path.length || !path.exists)
        return OpenCheck(OpenVerdict.refuse, path ~ ": no such file");
    if (path.isDir)
        return OpenCheck(OpenVerdict.decline);
    try
        File(path, "rb").close();
    catch (Exception)
        return OpenCheck(OpenVerdict.refuse, path ~ ": not readable");
    return viewKindOf(path) == ViewKind.unsupported
        ? OpenCheck(OpenVerdict.decline) : OpenCheck(OpenVerdict.open);
}

// ─────────────────────────────────────────────────────────────────────────────
// The queue between the servers and the frame.
// ─────────────────────────────────────────────────────────────────────────────

/// One queued request.
struct OpenRequest
{
    uint id;
    string path; /// absolute
    int pid;     /// the requesting process, or 0 when unknown
}

private struct Answer
{
    uint id;
    bool ok;
    string message;
}

private shared Mutex queueLock;
private shared OpenRequest[] queued;
private shared Answer[] answers;
private shared uint lastId;

shared static this()
{
    queueLock = new shared Mutex;
}

/// Queues `path` for the frame; the id to wait on.
uint enqueueOpen(string path, int pid) @trusted
{
    queueLock.lock();
    scope (exit) queueLock.unlock();
    import core.atomic : atomicOp;

    const id = atomicOp!"+="(lastId, 1);
    queued ~= cast(shared) OpenRequest(id, path, pid);
    return id;
}

/// The requests queued since the last call (the frame's side).
OpenRequest[] takeOpenRequests() @trusted
{
    queueLock.lock();
    scope (exit) queueLock.unlock();
    auto r = cast(OpenRequest[]) queued;
    queued = null;
    return r;
}

/// The frame's answer to request `id`: opened, or why not.
void answerOpen(uint id, bool ok, string message) @trusted
{
    queueLock.lock();
    scope (exit) queueLock.unlock();
    answers ~= cast(shared) Answer(id, ok, message);
}

/**
Waits up to `timeoutMs` for the frame's answer to `id` (`TDV3`: the command
returns once the pane is open, never waiting for it to close). A frame that
does not answer in time — a window hidden and not drawing — counts as opened:
the request stays queued and opens when the frame runs.
*/
bool awaitOpen(uint id, out string message, int timeoutMs = 3000) @trusted
{
    import core.thread : Thread;

    const until = MonoTime.currTime + timeoutMs.msecs;
    while (MonoTime.currTime < until)
    {
        {
            queueLock.lock();
            scope (exit) queueLock.unlock();
            foreach (i, a; cast(Answer[]) answers)
                if (a.id == id)
                {
                    message = a.message;
                    answers = answers[0 .. i] ~ answers[i + 1 .. $];
                    return a.ok;
                }
        }
        Thread.sleep(10.msecs);
    }
    return true;
}

// ─────────────────────────────────────────────────────────────────────────────
// Which pane asked.
// ─────────────────────────────────────────────────────────────────────────────

version (OSX)
{
    // libproc: `proc_pidinfo(pid, PROC_PIDTBSDINFO, …)` fills a `proc_bsdinfo`
    // (136 bytes), whose fifth `uint32_t` is `pbi_ppid`.
    private extern (C) int proc_pidinfo(int pid, int flavor, ulong arg, void* buffer,
        int size) nothrow @nogc;
    private enum PROC_PIDTBSDINFO = 3, procBsdInfoSize = 136, pbiPpidAt = 4;
}

/// The parent of process `pid` (`/proc/<pid>/stat`; libproc on macOS), or 0.
int parentOf(int pid) @system
{
    import std.conv : text, to;
    import std.file : readText;
    import std.string : lastIndexOf, split;

    version (OSX)
    {
        uint[procBsdInfoSize / 4] info;
        if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, info.ptr, procBsdInfoSize)
            != procBsdInfoSize)
            return 0;
        return cast(int) info[pbiPpidAt];
    }
    else try
    {
        const stat = readText(text("/proc/", pid, "/stat"));
        // `pid (comm) state ppid …` — comm may hold spaces and parentheses.
        const close = stat.lastIndexOf(')');
        const fields = stat[close + 2 .. $].split(' ');
        return fields.length > 1 ? fields[1].to!int : 0;
    }
    catch (Exception)
        return 0;
}

/**
The pane whose child is `pid` or an ancestor of it — `childOf` answers "which
pane runs this pid", 0 for none. 0 when no ancestor is a pane's child.
*/
ulong paneOfProcess(int pid, scope ulong delegate(int pid) @system childOf) @system
{
    foreach (_; 0 .. 64)
    {
        if (pid <= 1)
            return 0;
        if (const pane = childOf(pid))
            return pane;
        pid = parentOf(pid);
    }
    return 0;
}

/// The working directory of process `pid`, or null.
string cwdOf(int pid) @system
{
    import std.conv : text;
    import std.file : readLink;

    if (pid <= 0)
        return null;
    try
        return readLink(text("/proc/", pid, "/cwd"));
    catch (Exception)
        return null;
}

/// The process at the other end of a connected Unix socket, or 0.
int peerProcess(int fd) @system nothrow @nogc
{
    version (linux)
    {
        import core.sys.posix.sys.socket : getsockopt, socklen_t, SOL_SOCKET;

        enum SO_PEERCRED = 17;
        static struct Ucred
        {
            int pid;
            uint uid, gid;
        }

        Ucred c;
        socklen_t len = c.sizeof;
        if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &c, &len) != 0)
            return 0;
        return c.pid;
    }
    else version (OSX)
    {
        import core.sys.posix.sys.socket : getsockopt, socklen_t;

        enum SOL_LOCAL = 0, LOCAL_PEERPID = 2; // <sys/un.h>
        int pid;
        socklen_t len = pid.sizeof;
        if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &len) != 0)
            return 0;
        return pid;
    }
    else
        return 0;
}

// ─────────────────────────────────────────────────────────────────────────────
// The desktop's socket and its `xdg-open` (`TDV4`).
// ─────────────────────────────────────────────────────────────────────────────

/// The reply's statuses, in the `am` reply's framing (`amReply`).
enum ShimStatus : int
{
    opened = 0,
    refused = 1,
    declined = 2, /// the shim hands the file to the next `xdg-open`
}

/// The per-app directory: `$XDG_RUNTIME_DIR/sparkles-terminal-<pid>`, else
/// one under the temporary directory.
string openDir() @safe
{
    import std.conv : text;
    import std.file : tempDir;
    import std.path : buildPath;
    import std.process : environment, thisProcessID;

    const base = environment.get("XDG_RUNTIME_DIR", tempDir);
    return buildPath(base, text("sparkles-terminal-", thisProcessID));
}

/**
Makes this process's sessions answer `xdg-open` (`TDV4`): a `bin/xdg-open`
link to this executable in the per-app directory, the directory first on the
`PATH` every pane inherits, and `SPARKLES_TERMINAL_SOCKET` naming the socket
$(LREF startOpenServer) listens on. Returns the directory (remove it at exit),
or null after a warning when it could not be made.
*/
string installOpenShim() @system
{
    import std.file : mkdirRecurse, symlink, thisExePath;
    import std.path : buildPath;
    import std.process : environment;

    import sparkles.base.logger : warning;

    const dir = openDir();
    const bin = buildPath(dir, "bin");
    try
    {
        mkdirRecurse(bin);
        symlink(thisExePath, buildPath(bin, "xdg-open"));
    }
    catch (Exception e)
    {
        warning(i"open: cannot install the xdg-open shim: $(e.msg)");
        return null;
    }
    const path = environment.get("PATH", "");
    environment["PATH"] = path.length ? bin ~ ":" ~ path : bin;
    environment["SPARKLES_TERMINAL_SOCKET"] = buildPath(dir, "open.sock");
    return dir;
}

/// Removes the per-app directory $(LREF installOpenShim) made; quietly, at exit.
void removeOpenDir(string dir) @system nothrow
{
    import std.file : rmdirRecurse;

    try
        rmdirRecurse(dir);
    catch (Exception)
    {
        // A directory under the runtime dir goes with the session anyway.
    }
}

/**
Listens on `path` for the shim's requests on a thread of its own; false
(after a warning) when it cannot.
*/
bool startOpenServer(string path) @system
{
    import core.thread : Thread;

    const fd = listenUnix(path);
    if (fd < 0)
        return false;
    auto t = new Thread({ serveShim(fd); });
    t.isDaemon = true;
    t.start();
    return true;
}

/// A listening Unix socket at `path`, or -1 after a warning.
int listenUnix(string path) @system
{
    import core.sys.posix.sys.socket : AF_UNIX, bind, listen, sockaddr, socket, SOCK_STREAM;
    import core.sys.posix.sys.un : sockaddr_un;
    import core.sys.posix.unistd : close, unlink;
    import std.string : toStringz;

    import sparkles.base.logger : warning;

    unlink(path.toStringz);
    const fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0)
        return -1;
    sockaddr_un addr;
    addr.sun_family = AF_UNIX;
    if (path.length >= addr.sun_path.length)
    {
        warning(i"open: socket path too long: $(path)");
        close(fd);
        return -1;
    }
    addr.sun_path[0 .. path.length] = cast(byte[]) path;
    if (bind(fd, cast(sockaddr*) &addr, addr.sizeof) != 0 || listen(fd, 8) != 0)
    {
        warning(i"open: cannot listen on $(path)");
        close(fd);
        return -1;
    }
    return fd;
}

private void serveShim(int listener) @system
{
    import core.sys.posix.sys.socket : accept;
    import core.sys.posix.unistd : close;

    import sparkles.base.logger : warning;

    for (;;)
    {
        const conn = accept(listener, null, null);
        if (conn < 0)
            continue;
        scope (exit) close(conn);
        try
            answerShim(conn);
        catch (Exception e)
            warning(i"open: request failed: $(e.msg)");
    }
}

private void answerShim(int conn) @system
{
    import am_command : amReply;

    // One path, NUL-terminated, already absolute.
    auto request = receiveAll(conn);
    if (request.length && request[$ - 1] == '\0')
        request = request[0 .. $ - 1];
    const path = localPathOf(cast(string) request.idup, null);
    if (path is null)
        return sendAll(conn, amReply(ShimStatus.declined, "", ""));
    const check = checkOpen(path);
    final switch (check.verdict)
    {
        case OpenVerdict.refuse:
            return sendAll(conn, amReply(ShimStatus.refused, "", "xdg-open: " ~ check.message ~ "\n"));
        case OpenVerdict.decline:
            return sendAll(conn, amReply(ShimStatus.declined, "", ""));
        case OpenVerdict.open:
            string msg;
            const ok = awaitOpen(enqueueOpen(path, peerProcess(conn)), msg);
            return sendAll(conn, ok ? amReply(ShimStatus.opened, "", "")
                : amReply(ShimStatus.refused, "", "xdg-open: " ~ msg ~ "\n"));
    }
}

/// Reads until the peer shuts its side down (64 KiB at most).
char[] receiveAll(int conn) @system
{
    import core.sys.posix.sys.socket : recv;

    char[] request;
    char[4096] buf = void;
    for (;;)
    {
        const n = recv(conn, buf.ptr, buf.length, 0);
        if (n <= 0)
            break;
        request ~= buf[0 .. n];
        if (request.length > 64 * 1024)
            break;
    }
    return request;
}

/// Writes all of `msg`.
void sendAll(int conn, scope const(char)[] msg) @system
{
    import core.sys.posix.sys.socket : send;

    size_t sent;
    while (sent < msg.length)
    {
        const n = send(conn, msg.ptr + sent, msg.length - sent, 0);
        if (n <= 0)
            return;
        sent += n;
    }
}

/**
`xdg-open` as the shim (this executable, run by that name): a local file goes
to the terminal over `SPARKLES_TERMINAL_SOCKET`; anything it declines — and
anything when no terminal answers — goes to the next `xdg-open` on `PATH`.
*/
int xdgOpenShim(string[] args) @system
{
    import core.sys.posix.sys.socket : AF_UNIX, connect, shutdown, SHUT_WR, sockaddr,
        socket, SOCK_STREAM;
    import core.sys.posix.sys.un : sockaddr_un;
    import core.sys.posix.unistd : close;
    import std.file : getcwd;
    import std.process : environment;
    import std.stdio : stderr;

    if (args.length != 2)
        return execNext(args);
    const sock = environment.get("SPARKLES_TERMINAL_SOCKET", "");
    const path = localPathOf(args[1], getcwd());
    if (!sock.length || path is null)
        return execNext(args);

    const fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0)
        return execNext(args);
    sockaddr_un addr;
    addr.sun_family = AF_UNIX;
    if (sock.length >= addr.sun_path.length)
        return execNext(args);
    addr.sun_path[0 .. sock.length] = cast(byte[]) sock;
    if (connect(fd, cast(sockaddr*) &addr, addr.sizeof) != 0)
    {
        close(fd);
        return execNext(args);
    }
    sendAll(fd, path ~ "\0");
    shutdown(fd, SHUT_WR);
    const reply = receiveAll(fd);
    close(fd);

    int code;
    string out_, err;
    if (!parseReply(reply, code, out_, err) || code == ShimStatus.declined)
        return execNext(args);
    if (err.length)
        stderr.write(err);
    return code;
}

/// Splits `<code>\0<stdout>\0<stderr>\0`.
bool parseReply(scope const(char)[] reply, out int code, out string out_, out string err) @safe
{
    import std.conv : to;
    import std.string : indexOf;

    const a = reply.indexOf('\0');
    if (a <= 0)
        return false;
    const b = reply[a + 1 .. $].indexOf('\0');
    if (b < 0)
        return false;
    const c = reply[a + 1 + b + 1 .. $].indexOf('\0');
    if (c < 0)
        return false;
    try
        code = reply[0 .. a].to!int;
    catch (Exception)
        return false;
    out_ = reply[a + 1 .. a + 1 + b].idup;
    err = reply[a + 1 + b + 1 .. a + 1 + b + 1 + c].idup;
    return true;
}

// Runs the first `xdg-open` on PATH that is not this executable.
private int execNext(string[] args) @system
{
    import core.sys.posix.unistd : execv;
    import std.algorithm.iteration : splitter;
    import std.file : exists, isFile, thisExePath;
    import std.path : buildPath;
    import std.process : environment;
    import std.stdio : stderr;
    import std.string : toStringz;

    const self = realPathOf(thisExePath);
    foreach (dir; environment.get("PATH", "").splitter(':'))
    {
        if (!dir.length)
            continue;
        const candidate = buildPath(dir, "xdg-open");
        bool usable;
        try
            usable = candidate.exists && candidate.isFile && realPathOf(candidate) != self;
        catch (Exception)
            usable = false;
        if (!usable)
            continue;
        const(char)*[] argv = [candidate.toStringz];
        foreach (a; args[1 .. $])
            argv ~= a.toStringz;
        argv ~= null;
        execv(argv[0], argv.ptr);
    }
    stderr.writeln("xdg-open: no other xdg-open on PATH");
    return 3;
}

private string realPathOf(string p) @system
{
    import core.stdc.stdlib : free;
    import core.sys.posix.stdlib : realpath;
    import std.string : fromStringz, toStringz;

    auto r = realpath(p.toStringz, null);
    if (r is null)
        return p;
    scope (exit) free(r);
    return r.fromStringz.idup;
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests.
// ─────────────────────────────────────────────────────────────────────────────

@("open_request.localPathOf.urisAndRelativePaths")
@safe unittest
{
    assert(localPathOf("README.md", "/home/u/src") == "/home/u/src/README.md");
    assert(localPathOf("../a b.md", "/home/u/src") == "/home/u/a b.md");
    assert(localPathOf("/etc/hosts", "/x") == "/etc/hosts");
    assert(localPathOf("file:///tmp/a%20b.png", null) == "/tmp/a b.png");
    assert(localPathOf("file://localhost/tmp/x", null) == "/tmp/x");
    assert(localPathOf("file://otherhost/tmp/x", null) is null);
    assert(localPathOf("https://nixos.org", "/x") is null);
    assert(localPathOf("mailto:a@b", "/x") is null);
    assert(localPathOf("", "/x") is null);
}

@("open_request.checkOpen.verdicts")
@system unittest
{
    import std.file : remove, tempDir, write;
    import std.path : buildPath;

    const md = buildPath(tempDir, "open-request-check.md");
    const bin = buildPath(tempDir, "open-request-check.bin");
    write(md, "# hi\n");
    write(bin, "\x7fELF\x00\x00\x01");
    scope (exit)
    {
        remove(md);
        remove(bin);
    }
    assert(checkOpen(md).verdict == OpenVerdict.open);
    assert(checkOpen(bin).verdict == OpenVerdict.decline, "binary: the desktop's handler");
    assert(checkOpen(tempDir).verdict == OpenVerdict.decline, "a directory is not ours");
    const gone = checkOpen(buildPath(tempDir, "open-request-missing.md"));
    assert(gone.verdict == OpenVerdict.refuse && gone.message.length);
}

@("open_request.queue.roundTrip")
@system unittest
{
    import core.thread : Thread;

    const id = enqueueOpen("/tmp/x.md", 42);
    auto t = new Thread({
        foreach (r; takeOpenRequests())
            answerOpen(r.id, r.path == "/tmp/x.md" && r.pid == 42, "nope");
    });
    t.start();
    string msg;
    assert(awaitOpen(id, msg));
    t.join();
}

@("open_request.paneOfProcess.walksTheAncestry")
@system unittest
{
    import core.sys.posix.unistd : getpid, getppid;

    // This process's parent stands in for a pane's child.
    const parent = getppid();
    assert(paneOfProcess(getpid(), (int p) => p == parent ? 7UL : 0UL) == 7);
    assert(paneOfProcess(getpid(), (int p) => 0UL) == 0);
}

@("open_request.parseReply.amFraming")
@safe unittest
{
    int code;
    string o, e;
    assert(parseReply("1\0\0no such file\n\0", code, o, e) && code == 1 && e == "no such file\n");
    assert(parseReply("0\0\0\0", code, o, e) && code == 0 && !e.length);
    assert(!parseReply("garbage", code, o, e));
}
