/**
Open requests (`TDV1`–`TDV4`, `TDV15`): a program in a pane asks for a local
file to be opened, and the terminal opens it in a viewer pane beside that
pane.

Most arrive in-band: the shims — this executable run as `xdg-open`, as `open`
on macOS, or as `sparkles-open`; a shell script on Android — decide what they
can where the file is (missing, unreadable, or not a kind the viewer shows)
and write the rest to their terminal as OSC 5379 ($(LREF openShim)). The pane
whose output carries it is the pane that asked, so nothing maps a process to
a pane; `sparkles:terminal-view` reads the sequence and the workspace opens
the file.

Android's `termux-open` / `am start -a VIEW`, which nix-on-droid's tools send
to the `am` server, still arrive on a server thread: they reach the frame
through a small queue, and the pane is found from the socket peer's process,
whose ancestry leads to one pane's child ($(LREF paneOfProcess)).

The decisions are host-tested.
*/
module open_request;

version (Posix):

import core.time : msecs, MonoTime;

import sparkles.base.sync.mutex : Mutex;
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
    import std.file : exists, isDir, isFile;
    import std.stdio : File;

    if (!path.length || !path.exists)
        return OpenCheck(OpenVerdict.refuse, path ~ ": no such file");
    if (path.isDir)
        return OpenCheck(OpenVerdict.decline);
    // Refuse before probing: opening a FIFO with no writer (or a device
    // with odd semantics) blocks, and this runs on the frame (TDV15).
    if (!path.isFile)
        return OpenCheck(OpenVerdict.refuse, path ~ ": not a regular file");
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

/// Queues `path` for the frame; the id to wait on.
uint enqueueOpen(string path, int pid) @trusted
{
    auto held = queueLock.guard();
    import core.atomic : atomicOp;

    const id = atomicOp!"+="(lastId, 1);
    queued ~= cast(shared) OpenRequest(id, path, pid);
    return id;
}

/// The requests queued since the last call (the frame's side).
OpenRequest[] takeOpenRequests() @trusted
{
    auto held = queueLock.guard();
    auto r = cast(OpenRequest[]) queued;
    queued = null;
    return r;
}

/// The frame's answer to request `id`: opened, or why not.
void answerOpen(uint id, bool ok, string message) @trusted
{
    auto held = queueLock.guard();
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
            auto held = queueLock.guard();
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

/// The process at the other end of a connected Unix socket, or 0 (the `am`
/// server's peer on Android).
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
    else
        return 0;
}

// ─────────────────────────────────────────────────────────────────────────────
// The desktop's shims and the in-band request (`TDV4`, `TDV15`).
// ─────────────────────────────────────────────────────────────────────────────

/// The names the shim answers to on this platform, besides `sparkles-open`:
/// the opener programs call here.
version (OSX)
    immutable string[] shimNames = ["open", "sparkles-open"];
else
    immutable string[] shimNames = ["xdg-open", "sparkles-open"];

/// Whether `argv0` names the shim: this executable, run as an opener.
bool isShimName(string argv0) @safe pure
{
    import std.algorithm.searching : canFind;
    import std.path : baseName;

    return shimNames.canFind(argv0.baseName);
}

/// The environment variable each pane gets while open requests are the
/// app's (`TDV4`): a shim run elsewhere — another terminal, a cron job — hands
/// everything to the platform's opener and writes nothing.
enum string openEnvVar = "SPARKLES_TERMINAL_OPEN";

/**
The open request for `path` as a program writes it to its terminal
(`TDV15`): `ESC ] 5379 ; open ; <base64 of the path> ST`.
*/
string openRequestSequence(string path) @safe pure
{
    import std.base64 : Base64;

    return "\x1b]5379;open;" ~ Base64.encode(cast(const(ubyte)[]) path) ~ "\x1b\\";
}

///
@("open_request.openRequestSequence")
@safe pure unittest
{
    assert(openRequestSequence("/tmp/a b.md") == "\x1b]5379;open;L3RtcC9hIGIubWQ=\x1b\\");
}

/// What the shim does with one invocation.
enum ShimAction : ubyte
{
    platform, /// run the platform's opener: not one local file, or not ours
    refuse,   /// a missing or unreadable file: a message, status 1 (`TDV3`)
    request,  /// write the open request to the terminal, status 0
}

/// A decision and what it needs: the absolute path to request, or the message.
struct ShimDecision
{
    ShimAction action;
    string path;    /// `request`: the file, absolute
    string message; /// `refuse`: why
}

/**
Decides one shim invocation `args` (its own name first), run from `cwd`, with
open requests the app's (`enabled`): exactly one local file the viewer shows
is a request; a missing or unreadable one is refused here, where it can be
seen; anything else — flags, several files, a URL, a directory, a kind the
viewer does not show, or no app to ask — is the platform's.
*/
ShimDecision decideShim(string[] args, string cwd, bool enabled) @system
{
    if (!enabled || args.length != 2 || (args[1].length && args[1][0] == '-'))
        return ShimDecision(ShimAction.platform);
    const path = localPathOf(args[1], cwd);
    if (path is null)
        return ShimDecision(ShimAction.platform);
    const check = checkOpen(path);
    final switch (check.verdict)
    {
        case OpenVerdict.open:
            return ShimDecision(ShimAction.request, path);
        case OpenVerdict.refuse:
            return ShimDecision(ShimAction.refuse, null, check.message);
        case OpenVerdict.decline:
            return ShimDecision(ShimAction.platform);
    }
}

/**
The opener as the shim (this executable, run as `xdg-open`, `open` on macOS,
or `sparkles-open`; `TDV4`): a local file the viewer shows becomes an open
request written to the controlling terminal (`TDV15`), which the pane that
owns it reads; everything else goes to the next opener of the same name on
`PATH` (`sparkles-open` has none, and says so).
*/
int openShim(string[] args) @system
{
    import core.sys.posix.fcntl : O_NOCTTY, O_WRONLY, open;
    import core.sys.posix.unistd : close, write;
    import std.file : getcwd;
    import std.path : baseName;
    import std.process : environment;
    import std.stdio : stderr;

    const name = args.length ? args[0].baseName : "sparkles-open";
    const d = decideShim(args, getcwd(), environment.get(openEnvVar, "") == "1");
    final switch (d.action)
    {
        case ShimAction.platform:
            return execNext(args);
        case ShimAction.refuse:
            stderr.writeln(name, ": ", d.message);
            return 1;
        case ShimAction.request:
            const tty = open("/dev/tty", O_WRONLY | O_NOCTTY);
            if (tty < 0)
                return execNext(args); // no terminal of ours to ask
            scope (exit) close(tty);
            const seq = openRequestSequence(d.path);
            size_t done;
            while (done < seq.length)
            {
                const n = write(tty, seq.ptr + done, seq.length - done);
                if (n <= 0)
                    return execNext(args);
                done += n;
            }
            return 0;
    }
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
Makes this process's sessions' open requests the app's (`TDV4`): links to
this executable under the shim's names (`shimNames`) in the per-app
directory, the directory first on the `PATH` every pane inherits, and
`SPARKLES_TERMINAL_OPEN=1`. Returns the directory (remove it at exit), or
null after a warning when it could not be made.
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
        foreach (name; shimNames)
            symlink(thisExePath, buildPath(bin, name));
    }
    catch (Exception e)
    {
        warning(i"open: cannot install the open shims: $(e.msg)");
        return null;
    }
    const path = environment.get("PATH", "");
    environment["PATH"] = path.length ? bin ~ ":" ~ path : bin;
    environment[openEnvVar] = "1";
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

// Runs the first opener of this name on PATH that is not this executable.
private int execNext(string[] args) @system
{
    import core.sys.posix.unistd : execv;
    import std.algorithm.iteration : splitter;
    import std.file : exists, isFile, thisExePath;
    import std.path : baseName, buildPath;
    import std.process : environment;
    import std.stdio : stderr;
    import std.string : toStringz;

    const name = args.length ? args[0].baseName : "sparkles-open";
    const self = realPathOf(thisExePath);
    if (name != "sparkles-open")
        foreach (dir; environment.get("PATH", "").splitter(':'))
        {
            if (!dir.length)
                continue;
            const candidate = buildPath(dir, name);
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
    stderr.writeln(name, name == "sparkles-open"
        ? ": opens one local file in the sparkles terminal that runs it"
        : ": no other " ~ name ~ " on PATH");
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
    version (Posix)
    {
        // A non-regular file is refused before any open: probing one with
        // `File(path, "rb")` blocks on a FIFO with no writer. `/dev/null`
        // is the character device that stands in for the class.
        const dev = checkOpen("/dev/null");
        assert(dev.verdict == OpenVerdict.refuse && dev.message.length,
            "a device is not a regular file");
        import core.sys.posix.sys.stat : mkfifo;
        import std.string : toStringz;

        const fifo = buildPath(tempDir, "open-request-fifo.md");
        assert(mkfifo(fifo.toStringz, 0x180) == 0); // 0600
        scope (exit)
            remove(fifo);
        assert(checkOpen(fifo).verdict == OpenVerdict.refuse,
            "a FIFO is refused without opening it");
    }
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

@("open_request.decideShim.oneLocalFileTheViewerShows")
@system unittest
{
    import std.file : remove, tempDir, write;
    import std.path : buildPath;

    const md = buildPath(tempDir, "open-request-shim.md");
    write(md, "# hi\n");
    scope (exit) remove(md);
    const cwd = tempDir;
    with (ShimAction)
    {
        assert(decideShim(["xdg-open", md], cwd, true) == ShimDecision(request, md));
        assert(decideShim(["open", "open-request-shim.md"], cwd, true).path == md,
            "a relative path, against the shim's directory");
        assert(decideShim(["xdg-open", md], cwd, false).action == platform,
            "outside one of the app's panes, the platform's");
        assert(decideShim(["open", "-a", "Preview", md], cwd, true).action == platform);
        assert(decideShim(["open", "-R", md], cwd, true).action == platform, "a flag");
        assert(decideShim(["xdg-open", "https://nixos.org"], cwd, true).action == platform);
        assert(decideShim(["xdg-open", tempDir], cwd, true).action == platform, "a directory");
        const gone = decideShim(["xdg-open", "no-such-open-request.md"], cwd, true);
        assert(gone.action == refuse && gone.message.length, "refused where it can be seen");
    }
}

@("open_request.isShimName")
@safe pure unittest
{
    assert(isShimName("/run/user/1000/sparkles-terminal-7/bin/sparkles-open"));
    version (OSX)
        assert(isShimName("open") && !isShimName("xdg-open"));
    else
        assert(isShimName("xdg-open") && !isShimName("open"));
    assert(!isShimName("sparkles_terminal"));
}
