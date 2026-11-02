/**
The Windows spawn machinery (SPEC §13.9): `ChildProcess`, `spawnProcess`,
`observeExit`, `wait` — native Win32, not a POSIX emulation. `live`
re-exports this module on Windows, so consumer spellings do not change.

$(UL
    $(LI $(B Spawn.) `CreateProcessW` with `CREATE_SUSPENDED`: argv is
        encoded by the inverse of `CommandLineToArgvW`'s rules, every string
        is UTF-16, and the environment block is the §13.1 overlay result,
        sorted case-insensitively and double-NUL terminated. Inheritance is
        restricted to the child's own stdio ends by `STARTUPINFOEXW` and
        `PROC_THREAD_ATTRIBUTE_HANDLE_LIST`.)
    $(LI $(B Containment.) Each child gets its own Job Object with
        `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`; the suspended child is
        assigned, then resumed, so no child code runs outside the job and
        every descendant joins it. A failed assignment terminates and reaps
        the suspended child and fails the spawn. The reap closes the job,
        which ends any descendant still in it.)
    $(LI $(B Pipes.) Uniquely named, one instance each, remote clients
        rejected; the parent end is overlapped and rides the scheduler's
        port, the child end is synchronous and inheritable only through the
        handle list.)
    $(LI $(B Exit.) `OpWaitHandle` on the process handle: one wait
        completion packet associated with the port (no threadpool wait, no
        helper thread, no polling). The handle pins the process identity
        until the reap, so a stale operation can never reach a recycled pid.
        The exit code is read once, as `ExitStatus(signaled: false, code)`.)
)

The PATH search follows §13.1: the child's environment decides it, each
candidate is attempted by `CreateProcessW` itself (not-found moves on,
access-denied is remembered, anything else ends the search), a name with a
path separator is spawned as spelled, a relative candidate is resolved
against the child's cwd, and a name without an extension gets `.exe`. The
parent's directory and cwd are not searched implicitly. Batch files are
refused: `cmd.exe` parses their command line by other rules, so they are
run as `["cmd.exe", "/c", …]` explicitly.
*/
module sparkles.event_horizon.live_windows;

version (Windows)  :

import core.lifetime : move;
import core.stdc.errno : EACCES, ECHILD, EINVAL, EIO, ENOENT, ENOEXEC, ESRCH;
import core.sys.windows.winbase : PROCESS_INFORMATION, STARTUPINFOW;
import core.sys.windows.windef : BOOL, DWORD, HANDLE;

import sparkles.event_horizon.backend.concept : canSubmitOp;
import sparkles.event_horizon.backend.iocp : winErrno;
import sparkles.event_horizon.backend.select : DefaultBackend;
import sparkles.event_horizon.errors : ioError, IoError, IoErrorStage, IoResult,
    OpKind, ioErr, ioOk;
import sparkles.event_horizon.op : OpWaitHandle;
import sparkles.event_horizon.proc : ExitStatus, ProcessConfig, StdioMode, StdioSpec;
import sparkles.event_horizon.sched : Sched;
import sparkles.event_horizon.sys.descriptor : BorrowedFd, NativeHandle, OwnedFd,
    invalidHandle;

/// The exit code a hard kill (`TerminateProcess` / `TerminateJobObject`)
/// leaves; Windows has no signals, so a killed child reports
/// `ExitStatus(signaled: false, code: killedExitCode)`.
enum uint killedExitCode = 1;

/// A spawned child (SPEC §13.2, §13.9): its id, the parent ends of whichever
/// streams were piped, its process handle and its Job Object.
struct ChildProcess
{
    int pid = -1;       /// the process id; -1 after a successful `wait`
    OwnedFd stdinW;     /// write end of the child's stdin  (piped, or the ConPTY input)
    OwnedFd stdoutR;    /// read end of the child's stdout  (piped only)
    OwnedFd stderrR;    /// read end of the child's stderr  (piped only)
    /// `spawnPty` only: the read end of the ConPTY's output. A ConPTY takes
    /// its input and output on two pipes, so input is written to `stdinW`.
    OwnedFd ptyMaster;
    OwnedFd process;    /// the process handle: pins identity until the reap
    OwnedFd job;        /// the child's Job Object (kill on close)
    package PseudoConsole pty;  /// `spawnPty` only; closed by the reap
    package bool exited;       /// the handle signalled (`observeExit`)
    package bool processGroup; /// created with `CREATE_NEW_PROCESS_GROUP`

    /// `true` while the child is reapable.
    bool opCast(T : bool)() const @safe pure nothrow @nogc => pid > 0;

    /// Terminates the child alone (`TerminateProcess`). `ESRCH` after a
    /// successful `wait`.
    IoResult!void kill(uint exitCode = killedExitCode) @trusted nothrow @nogc
    {
        if (pid <= 0)
            return ioErr!void(ESRCH, OpKind.none, IoErrorStage.submit,
                "child already reaped");
        if (!TerminateProcess(process.borrowFd.fd, exitCode))
            return ioErr!void(winErrno(GetLastError()), OpKind.none,
                IoErrorStage.submit, "TerminateProcess failed");
        return ioOk();
    }

    /// Terminates the child's whole tree (`TerminateJobObject`). `ESRCH`
    /// after a successful `wait`.
    IoResult!void killGroup(uint exitCode = killedExitCode) @trusted nothrow @nogc
    {
        if (pid <= 0)
            return ioErr!void(ESRCH, OpKind.none, IoErrorStage.submit,
                "child already reaped");
        if (!TerminateJobObject(job.borrowFd.fd, exitCode))
            return ioErr!void(winErrno(GetLastError()), OpKind.none,
                IoErrorStage.submit, "TerminateJobObject failed");
        return ioOk();
    }
}

// ── UTF-16 staging ──────────────────────────────────────────────────────────

/// `s` as UTF-16, optionally NUL-terminated; false on invalid UTF-8.
package bool toWide(scope const(char)[] s, out wchar[] wide, bool terminate = false)
    @trusted nothrow
{
    enum uint CP_UTF8 = 65_001, MB_ERR_INVALID_CHARS = 8;
    if (s.length > int.max)
        return false;
    int n = s.length == 0 ? 0 : MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
        s.ptr, cast(int) s.length, null, 0);
    if (s.length != 0 && n == 0)
        return false;
    wide = new wchar[](n + (terminate ? 1 : 0));
    if (terminate)
        wide[$ - 1] = 0; // wchar.init is 0xFFFF, not NUL
    if (n != 0)
        MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s.ptr, cast(int) s.length,
            wide.ptr, n);
    return true;
}

/// `w` as UTF-8 (unpaired surrogates become U+FFFD).
package string fromWide(scope const(wchar)[] w) @trusted nothrow
{
    enum uint CP_UTF8 = 65_001;
    if (w.length == 0)
        return "";
    const n = WideCharToMultiByte(CP_UTF8, 0, w.ptr, cast(int) w.length, null, 0,
        null, null);
    auto s = new char[](n);
    WideCharToMultiByte(CP_UTF8, 0, w.ptr, cast(int) w.length, s.ptr, n, null, null);
    return (() @trusted => cast(string) s)();
}

// ── the command line (CommandLineToArgvW, inverted) ─────────────────────────

/**
Appends `arg` to `line` so that `CommandLineToArgvW` returns it unchanged.
The program name (`first`) follows that function's own rule for the first
token — quotes delimit it and backslashes are literal — so it may not
contain a quote. Every later argument is quoted when empty or when it holds
a space, tab, newline, vertical tab or quote; inside quotes a run of
backslashes is doubled before a quote or the closing quote, and a quote is
escaped. Returns false for an unrepresentable program name.
*/
package bool appendArgument(ref wchar[] line, scope const(wchar)[] arg, bool first)
    @safe pure nothrow
{
    bool needsQuotes = arg.length == 0;
    foreach (c; arg)
        if (c == ' ' || c == '\t' || c == '\n' || c == '\v' || c == '"')
            needsQuotes = true;
    if (line.length)
        line ~= ' ';
    if (first)
    {
        foreach (c; arg)
            if (c == '"')
                return false;
        if (needsQuotes)
            line ~= '"';
        line ~= arg;
        if (needsQuotes)
            line ~= '"';
        return true;
    }
    if (!needsQuotes)
    {
        line ~= arg;
        return true;
    }
    line ~= '"';
    size_t backslashes;
    foreach (c; arg)
    {
        if (c == '\\')
        {
            ++backslashes;
            continue;
        }
        // Backslashes are literal unless a quote follows: then each one is
        // escaped, and so is the quote.
        foreach (_; 0 .. (c == '"' ? 2 * backslashes + 1 : backslashes))
            line ~= '\\';
        backslashes = 0;
        line ~= c;
    }
    foreach (_; 0 .. 2 * backslashes) // before the closing quote
        line ~= '\\';
    line ~= '"';
    return true;
}

// ── the environment (SPEC §13.1 overlay, Windows rules) ─────────────────────

/// An entry's name: up to the first '=' after the first character, so the
/// hidden per-drive entries (`=C:=C:\dir`) keep their leading '='.
package const(wchar)[] envName(return scope const(wchar)[] entry) @safe pure nothrow @nogc
{
    foreach (i, c; entry)
        if (i > 0 && c == '=')
            return entry[0 .. i];
    return entry;
}

/// Ordinal, case-insensitive comparison: -1, 0, 1 (`CompareStringOrdinal`).
package int compareNames(scope const(wchar)[] a, scope const(wchar)[] b) @trusted nothrow @nogc
{
    const r = CompareStringOrdinal(a.ptr, cast(int) a.length, b.ptr, cast(int) b.length, TRUE);
    return r == 1 ? -1 : r == 3 ? 1 : 0;
}

/// The inherited environment's entries, copied (`GetEnvironmentStringsW`).
package wchar[][] inheritedEnvironmentW() @trusted nothrow
{
    auto block = GetEnvironmentStringsW();
    if (block is null)
        return null;
    scope (exit) FreeEnvironmentStringsW(block);
    wchar[][] entries;
    for (auto p = block; *p != 0;)
    {
        size_t n;
        while (p[n] != 0)
            ++n;
        entries ~= p[0 .. n].dup;
        p += n + 1;
    }
    return entries;
}

/**
The child's environment per SPEC §13.1 with Windows matching: the base is
`cfg.env` when non-null, else the inherited block; `envOverlay` applies in
order with case-insensitive names. Validation matches POSIX (empty names,
'=' or NUL in a name, NUL in a value: `EINVAL` before any child exists).
`entries` is the result, sorted as `CreateProcessW` requires; `custom` says
whether a block must be passed at all.
*/
package IoResult!(wchar[][]) windowsEnvironment(in ProcessConfig cfg, out bool custom)
    @safe nothrow
{
    alias Entries = wchar[][];
    if (cfg.env !is null)
        foreach (entry; cfg.env)
        {
            size_t equals = size_t.max;
            foreach (i, c; entry)
            {
                if (c == '\0')
                    return ioErr!Entries(EINVAL, OpKind.none, IoErrorStage.submit,
                        "environment entry must not contain NUL");
                if (c == '=' && equals == size_t.max)
                    equals = i;
            }
            if (equals == size_t.max || equals == 0)
                return ioErr!Entries(EINVAL, OpKind.none, IoErrorStage.submit,
                    "environment entry must be nonempty KEY=value");
        }
    foreach (change; cfg.envOverlay)
    {
        if (change.name.length == 0)
            return ioErr!Entries(EINVAL, OpKind.none, IoErrorStage.submit,
                "environment name must not be empty");
        foreach (c; change.name)
            if (c == '=' || c == '\0')
                return ioErr!Entries(EINVAL, OpKind.none, IoErrorStage.submit,
                    "environment name must not contain '=' or NUL");
        if (!change.unset)
            foreach (c; change.value)
                if (c == '\0')
                    return ioErr!Entries(EINVAL, OpKind.none, IoErrorStage.submit,
                        "environment value must not contain NUL");
    }

    custom = cfg.env !is null || cfg.envOverlay.length > 0;
    Entries entries;
    if (cfg.env !is null)
        foreach (e; cfg.env)
        {
            wchar[] w;
            if (!toWide(e, w))
                return ioErr!Entries(EINVAL, OpKind.none, IoErrorStage.submit,
                    "environment entry is not UTF-8");
            entries ~= w;
        }
    else
        entries = inheritedEnvironmentW();

    foreach (change; cfg.envOverlay)
    {
        wchar[] name;
        if (!toWide(change.name, name))
            return ioErr!Entries(EINVAL, OpKind.none, IoErrorStage.submit,
                "environment name is not UTF-8");
        size_t writeAt;
        foreach (entry; entries)
            if (compareNames(envName(entry), name) != 0)
                entries[writeAt++] = entry;
        entries = entries[0 .. writeAt];
        if (!change.unset)
        {
            wchar[] value;
            if (!toWide(change.value, value))
                return ioErr!Entries(EINVAL, OpKind.none, IoErrorStage.submit,
                    "environment value is not UTF-8");
            entries ~= name ~ "="w ~ value;
        }
    }
    sortEnvironment(entries);
    return ioOk(entries);
}

/// Sorts entries by name, case-insensitively and ordinally — the order the
/// `CreateProcessW` documentation requires. Stable, so a caller-supplied
/// block's duplicate spellings keep their relative order.
package void sortEnvironment(wchar[][] entries) @safe nothrow
{
    foreach (i; 1 .. entries.length)
        for (size_t j = i; j > 0 && compareNames(envName(entries[j - 1]),
                envName(entries[j])) > 0; --j)
        {
            auto t = entries[j - 1];
            entries[j - 1] = entries[j];
            entries[j] = t;
        }
}

/// The double-NUL environment block for `entries` (an empty one is two NULs).
package wchar[] environmentBlock(scope const(wchar[])[] entries) @safe pure nothrow
{
    wchar[] block;
    foreach (e; entries)
    {
        block ~= e;
        block ~= '\0';
    }
    if (entries.length == 0)
        block ~= '\0';
    block ~= '\0';
    return block;
}

/// The child's PATH value from its entries, or null when it has none.
package const(wchar)[] pathOf(scope return const(wchar[])[] entries) @safe nothrow
{
    foreach (e; entries)
        if (compareNames(envName(e), "PATH"w) == 0)
            return e.length > 5 ? e[5 .. $] : ""w;
    return null;
}

// ── the PATH search ─────────────────────────────────────────────────────────

private bool isAbsolutePath(scope const(wchar)[] p) @safe pure nothrow @nogc
    => (p.length >= 3 && p[1] == ':' && (p[2] == '\\' || p[2] == '/'))
        || (p.length >= 1 && (p[0] == '\\' || p[0] == '/'));

private bool hasSeparator(scope const(wchar)[] p) @safe pure nothrow @nogc
{
    foreach (c; p)
        if (c == '\\' || c == '/' || c == ':')
            return true;
    return false;
}

/// Whether the last path component has an extension.
private bool hasExtension(scope const(wchar)[] p) @safe pure nothrow @nogc
{
    foreach_reverse (c; p)
    {
        if (c == '.')
            return true;
        if (c == '\\' || c == '/' || c == ':')
            return false;
    }
    return false;
}

private bool isBatch(scope const(wchar)[] p) @safe nothrow
{
    if (p.length < 4)
        return false;
    const ext = p[$ - 4 .. $];
    return compareNames(ext, ".bat"w) == 0 || compareNames(ext, ".cmd"w) == 0;
}

/// The directories an unset PATH searches: the system and Windows directories.
private wchar[][] defaultSearchDirs() @trusted nothrow
{
    wchar[][] dirs;
    wchar[260] buf;
    auto n = GetSystemDirectoryW(buf.ptr, cast(uint) buf.length);
    if (n > 0 && n < buf.length)
        dirs ~= buf[0 .. n].dup;
    n = GetWindowsDirectoryW(buf.ptr, cast(uint) buf.length);
    if (n > 0 && n < buf.length)
        dirs ~= buf[0 .. n].dup;
    return dirs;
}

/// The candidate executables for `program`, in search order (SPEC §13.1).
package wchar[][] searchCandidates(scope const(wchar)[] program,
    scope const(wchar)[] path, bool pathSet, scope const(wchar)[] childCwd) @safe nothrow
{
    wchar[][] dirs;
    if (hasSeparator(program))
        dirs ~= null;
    else if (!pathSet)
        dirs = defaultSearchDirs();
    else
    {
        size_t start;
        foreach (i; 0 .. path.length + 1)
            if (i == path.length || path[i] == ';')
            {
                auto segment = path[start .. i];
                if (segment.length >= 2 && segment[0] == '"' && segment[$ - 1] == '"')
                    segment = segment[1 .. $ - 1];
                if (segment.length) // Windows ignores empty components
                    dirs ~= segment.dup;
                start = i + 1;
            }
    }
    wchar[][] out_;
    foreach (dir; dirs)
    {
        wchar[] c = dir is null ? program.dup : dir ~ "\\"w ~ program;
        if (!hasExtension(program))
            c ~= ".exe"w;
        if (childCwd.length && !isAbsolutePath(c))
            c = childCwd ~ "\\"w ~ c;
        out_ ~= c;
    }
    return out_;
}

// ── stdio plumbing ──────────────────────────────────────────────────────────

private shared ulong stdioPipeSequence;

/**
One pipe for a child stream: the parent end is the server instance of a
uniquely named pipe (`FIRST_PIPE_INSTANCE`, one instance, remote clients
rejected, overlapped, not inheritable); the child end is the synchronous,
inheritable client. `parentReads` picks the direction.
*/
private bool openStdioPipe(bool parentReads, out OwnedFd parent, out HANDLE child)
    @trusted nothrow
{
    import core.atomic : atomicOp;

    wchar[96] name;
    enum prefix = `\\.\pipe\sparkles-eh-proc-`w;
    name[0 .. prefix.length] = prefix;
    size_t at = prefix.length;
    ulong[2] values = [GetCurrentProcessId(), atomicOp!"+="(stdioPipeSequence, 1UL)];
    foreach (value; values)
    {
        foreach_reverse (digit; 0 .. 16)
            name[at++] = "0123456789abcdef"w[(value >> (digit * 4)) & 15];
        name[at++] = '-';
    }
    name[at - 1] = 0;
    enum uint PIPE_ACCESS_INBOUND = 1, PIPE_ACCESS_OUTBOUND = 2,
        FILE_FLAG_OVERLAPPED = 0x4000_0000, FILE_FLAG_FIRST_PIPE_INSTANCE = 0x8_0000,
        PIPE_REJECT_REMOTE_CLIENTS = 8;
    enum uint GENERIC_READ = 0x8000_0000, GENERIC_WRITE = 0x4000_0000, OPEN_EXISTING = 3;
    auto server = CreateNamedPipeW(name.ptr,
        (parentReads ? PIPE_ACCESS_INBOUND : PIPE_ACCESS_OUTBOUND)
            | FILE_FLAG_OVERLAPPED | FILE_FLAG_FIRST_PIPE_INSTANCE,
        PIPE_REJECT_REMOTE_CLIENTS, 1, 65_536, 65_536, 0, null);
    if (server == invalidHandle)
        return false;
    parent = OwnedFd(server);
    SECURITY_ATTRIBUTES inherit = {nLength: SECURITY_ATTRIBUTES.sizeof, bInheritHandle: TRUE};
    // FILE_WRITE_ATTRIBUTES on a read end lets the child call
    // SetNamedPipeHandleState, as some runtimes do on their stdin.
    enum uint FILE_WRITE_ATTRIBUTES = 0x100;
    child = CreateFileW(name.ptr, parentReads ? GENERIC_WRITE
        : GENERIC_READ | FILE_WRITE_ATTRIBUTES, 0, &inherit, OPEN_EXISTING, 0, null);
    if (child == invalidHandle)
    {
        child = null;
        parent.close();
        return false;
    }
    // The client already connected; ERROR_PIPE_CONNECTED confirms it.
    OVERLAPPED_ ov;
    if (!ConnectNamedPipe(server, &ov) && GetLastError() != 535)
    {
        CloseHandle(child);
        child = null;
        parent.close();
        return false;
    }
    return true;
}

/// An inheritable duplicate of `h` (null stays null).
private bool inheritableCopy(HANDLE h, out HANDLE copy) @trusted nothrow @nogc
{
    enum uint DUPLICATE_SAME_ACCESS = 2;
    if (h is null || h == invalidHandle)
        return true;
    return DuplicateHandle(GetCurrentProcess(), h, GetCurrentProcess(), &copy, 0,
        TRUE, DUPLICATE_SAME_ACCESS) != 0;
}

private HANDLE openNul() @trusted nothrow @nogc
{
    enum uint GENERIC_READ = 0x8000_0000, GENERIC_WRITE = 0x4000_0000,
        FILE_SHARE_READ = 1, FILE_SHARE_WRITE = 2, OPEN_EXISTING = 3;
    SECURITY_ATTRIBUTES inherit = {nLength: SECURITY_ATTRIBUTES.sizeof, bInheritHandle: TRUE};
    auto h = CreateFileW("NUL"w.ptr, GENERIC_READ | GENERIC_WRITE,
        FILE_SHARE_READ | FILE_SHARE_WRITE, &inherit, OPEN_EXISTING, 0, null);
    return h == invalidHandle ? null : h;
}

// ── spawn ───────────────────────────────────────────────────────────────────

/// Maps a `CreateProcessW` failure to the errno the portable surface reports.
private int spawnErrno(uint code) @safe pure nothrow @nogc
{
    switch (code)
    {
    case 2, 3:          return ENOENT;  // FILE_NOT_FOUND, PATH_NOT_FOUND
    case 5:             return EACCES;  // ACCESS_DENIED
    case 193, 216, 129: return ENOEXEC; // BAD_EXE_FORMAT, EXE_MACHINE_TYPE_MISMATCH, CHILD_NOT_COMPLETE
    default:            return winErrno(code);
    }
}

private string spawnFailureContext(int rc) @safe pure nothrow @nogc
{
    switch (rc)
    {
    case ENOENT:  return "program not found in child PATH";
    case EACCES:  return "program found in child PATH but not executable";
    case ENOEXEC: return "program is not a recognised executable";
    default:      return "CreateProcessW failed";
    }
}

/**
Spawns `argv` (PATH-searched per the child's environment) per `cfg`
(SPEC §13.1–§13.2, §13.9): per-stream pipes, `NUL`, borrowed handles
(`StdioSpec.fd` carries a `HANDLE` value — Windows guarantees handles fit
32 bits) or the parent's own; the environment overlay; the working
directory; `newProcessGroup` as `CREATE_NEW_PROCESS_GROUP`. The child runs
inside its own Job Object from its first instruction.
*/
IoResult!ChildProcess spawnProcess(scope const(char[])[] argv,
    in ProcessConfig cfg = ProcessConfig()) @trusted
    => spawnImpl(argv, cfg, null);

/// The one spawn path. A `pseudoConsole` (`spawnPty`) replaces the stdio
/// wiring: the child's console is the ConPTY, and it inherits no handle.
private IoResult!ChildProcess spawnImpl(scope const(char[])[] argv,
    in ProcessConfig cfg, void* pseudoConsole) @trusted
{
    if (argv.length == 0)
        return ioErr!ChildProcess(EINVAL, OpKind.none, IoErrorStage.submit, "empty argv");
    foreach (arg; argv)
        foreach (c; arg)
            if (c == '\0')
                return ioErr!ChildProcess(EINVAL, OpKind.none, IoErrorStage.submit,
                    "argv entries must not contain NUL");
    if (cfg.cwd !is null)
        foreach (c; cfg.cwd)
            if (c == '\0')
                return ioErr!ChildProcess(EINVAL, OpKind.none, IoErrorStage.submit,
                    "cwd must not contain NUL");
    if (cfg.stdinSpec.mode == StdioMode.mergeStdout
        || cfg.stdoutSpec.mode == StdioMode.mergeStdout)
        return ioErr!ChildProcess(EINVAL, OpKind.none, IoErrorStage.submit,
            "mergeStdout is stderr-only");

    // The command line, the environment and the search, before any handle.
    wchar[] line;
    foreach (i, arg; argv)
    {
        wchar[] w;
        if (!toWide(arg, w))
            return ioErr!ChildProcess(EINVAL, OpKind.none, IoErrorStage.submit,
                "argv entries must be UTF-8");
        if (!appendArgument(line, w, i == 0))
            return ioErr!ChildProcess(EINVAL, OpKind.none, IoErrorStage.submit,
                "a program name cannot contain '\"' on Windows");
    }
    bool customEnv;
    auto envBuilt = windowsEnvironment(cfg, customEnv);
    if (envBuilt.hasError)
        return ioErr!ChildProcess(envBuilt.error);
    auto block = customEnv ? environmentBlock(envBuilt.value) : null;
    const childPath = pathOf(envBuilt.value);
    wchar[] cwd;
    if (cfg.cwd !is null && !toWide(cfg.cwd, cwd, true))
        return ioErr!ChildProcess(EINVAL, OpKind.none, IoErrorStage.submit,
            "cwd must be UTF-8");
    wchar[] program;
    cast(void) toWide(argv[0], program);
    auto candidates = searchCandidates(program, childPath, childPath !is null,
        cwd.length ? cwd[0 .. $ - 1] : null);
    foreach (candidate; candidates)
        if (isBatch(candidate))
            return ioErr!ChildProcess(EINVAL, OpKind.none, IoErrorStage.submit,
                "batch files must be run as cmd.exe /c explicitly");

    // The child's three handles: inheritable, and closed once it has its own.
    ChildProcess child;
    HANDLE[3] ends;
    scope (exit)
        foreach (h; ends)
            if (h !is null)
                CloseHandle(h);
    const(StdioSpec)[3] specs = [cfg.stdinSpec, cfg.stdoutSpec, cfg.stderrSpec];
    enum uint STD_INPUT_HANDLE = cast(uint) -10;
    static immutable uint[3] stdIds = [STD_INPUT_HANDLE, STD_INPUT_HANDLE - 1,
        STD_INPUT_HANDLE - 2];
    foreach (i, spec; pseudoConsole is null ? specs[] : specs[0 .. 0])
    {
        bool ok = true;
        final switch (spec.mode)
        {
        case StdioMode.inherit:
            ok = inheritableCopy(GetStdHandle(stdIds[i]), ends[i]);
            break;
        case StdioMode.pipe:
            auto parentEnd = i == 0 ? &child.stdinW : i == 1 ? &child.stdoutR : &child.stderrR;
            ok = openStdioPipe(i != 0, *parentEnd, ends[i]);
            break;
        case StdioMode.nullDev:
            ends[i] = openNul();
            ok = ends[i] !is null;
            break;
        case StdioMode.fd:
            ok = inheritableCopy(cast(HANDLE) cast(ptrdiff_t) spec.fd, ends[i]);
            break;
        case StdioMode.mergeStdout:
            ok = inheritableCopy(ends[1], ends[i]);
            break;
        }
        if (!ok)
            return ioErr!ChildProcess(winErrno(GetLastError()), OpKind.none,
                IoErrorStage.submit, "child stdio setup failed");
    }

    // Exactly these handles are inherited, whatever else is inheritable.
    HANDLE[3] listed;
    size_t listedCount;
    foreach (h; ends)
    {
        bool seen = h is null;
        foreach (l; listed[0 .. listedCount])
            seen |= l == h;
        if (!seen)
            listed[listedCount++] = h;
    }
    size_t attrSize;
    InitializeProcThreadAttributeList(null, 1, 0, &attrSize);
    auto attrStorage = new ubyte[](attrSize);
    auto attrs = cast(void*) attrStorage.ptr;
    if (!InitializeProcThreadAttributeList(attrs, 1, 0, &attrSize))
        return ioErr!ChildProcess(winErrno(GetLastError()), OpKind.none,
            IoErrorStage.submit, "InitializeProcThreadAttributeList failed");
    scope (exit) DeleteProcThreadAttributeList(attrs);
    enum size_t PROC_THREAD_ATTRIBUTE_HANDLE_LIST = 0x2_0002;
    if (listedCount != 0 && !UpdateProcThreadAttribute(attrs, 0,
            PROC_THREAD_ATTRIBUTE_HANDLE_LIST, listed.ptr, listedCount * HANDLE.sizeof,
            null, null))
        return ioErr!ChildProcess(winErrno(GetLastError()), OpKind.none,
            IoErrorStage.submit, "PROC_THREAD_ATTRIBUTE_HANDLE_LIST failed");
    enum size_t PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = 0x2_0016;
    if (pseudoConsole !is null && !UpdateProcThreadAttribute(attrs, 0,
            PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, pseudoConsole, (void*).sizeof, null, null))
        return ioErr!ChildProcess(winErrno(GetLastError()), OpKind.none,
            IoErrorStage.submit, "PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE failed");

    STARTUPINFOEXW si;
    si.StartupInfo.cb = STARTUPINFOEXW.sizeof;
    enum uint STARTF_USESTDHANDLES = 0x100;
    si.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    si.StartupInfo.hStdInput = ends[0];
    si.StartupInfo.hStdOutput = ends[1];
    si.StartupInfo.hStdError = ends[2];
    si.lpAttributeList = attrs;

    // The job exists before the child: assignment cannot be the step that
    // runs out of resources with a live child and no containment.
    auto job = CreateJobObjectW(null, null);
    if (job is null)
        return ioErr!ChildProcess(winErrno(GetLastError()), OpKind.none,
            IoErrorStage.submit, "CreateJobObjectW failed");
    child.job = OwnedFd(job);
    JobExtendedLimit limit;
    limit.basic.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limit,
            JobExtendedLimit.sizeof))
        return ioErr!ChildProcess(winErrno(GetLastError()), OpKind.none,
            IoErrorStage.submit, "kill-on-close job limit failed");

    enum uint CREATE_SUSPENDED = 4, CREATE_NEW_PROCESS_GROUP = 0x200,
        CREATE_UNICODE_ENVIRONMENT = 0x400, EXTENDED_STARTUPINFO_PRESENT = 0x8_0000;
    const flags = CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT
        | EXTENDED_STARTUPINFO_PRESENT | (cfg.newProcessGroup ? CREATE_NEW_PROCESS_GROUP : 0);
    PROCESS_INFORMATION pi;
    int rc = ENOENT;
    bool sawEacces;
    foreach (candidate; candidates)
    {
        auto app = candidate ~ '\0';
        auto mutableLine = line ~ '\0'; // CreateProcessW may write to it
        if (CreateProcessW(app.ptr, mutableLine.ptr, null, null, listedCount != 0,
                flags, block is null ? null : block.ptr, cwd.length ? cwd.ptr : null,
                &si.StartupInfo, &pi))
        {
            rc = 0;
            break;
        }
        rc = spawnErrno(GetLastError());
        if (rc == EACCES)
        {
            sawEacces = true;
            continue;
        }
        if (rc != ENOENT)
            break;
    }
    if (rc == ENOENT && sawEacces)
        rc = EACCES;
    if (rc != 0)
        return ioErr!ChildProcess(rc, OpKind.none, IoErrorStage.submit,
            spawnFailureContext(rc));

    child.process = OwnedFd(pi.hProcess);
    scope (exit) CloseHandle(pi.hThread);
    // Assign while suspended, then resume: no child instruction runs
    // outside the job, so no descendant can escape it.
    if (!AssignProcessToJobObject(job, pi.hProcess) || ResumeThread(pi.hThread) == uint.max)
    {
        const err = winErrno(GetLastError());
        TerminateProcess(pi.hProcess, killedExitCode);
        WaitForSingleObject(pi.hProcess, uint.max); // a suspended child ends at once
        return ioErr!ChildProcess(err, OpKind.none, IoErrorStage.submit,
            "job assignment failed; the suspended child was terminated");
    }
    child.pid = cast(int) pi.dwProcessId;
    child.processGroup = cfg.newProcessGroup;
    return ioOk(move(child));
}

// ── PTY spawning over ConPTY (SPEC §13.3, §13.9) ────────────────────────────

/// The ConPTY entry points (`kernel32`, Windows 10 1809+), resolved at run
/// time so an older host fails `spawnPty` with `ENOSYS` instead of loading.
private struct ConPtyApi
{
    extern (Windows) nothrow @nogc
    {
        int function(uint size, HANDLE input, HANDLE output, uint flags, void** pc) create;
        int function(void* pc, uint size) resize;
        void function(void* pc) close;
    }
}

private __gshared ConPtyApi conPtyApi_;
private shared ubyte conPtyState; // 0 unresolved, 1 present, 2 absent

private const(ConPtyApi)* conPtyApi() @trusted nothrow @nogc
{
    import core.atomic : atomicLoad, atomicStore;

    auto state = atomicLoad(conPtyState);
    if (state == 0)
    {
        auto kernel32 = GetModuleHandleW("kernel32.dll"w.ptr);
        ConPtyApi api;
        if (kernel32 !is null)
        {
            api.create = cast(typeof(api.create)) GetProcAddress(kernel32, "CreatePseudoConsole");
            api.resize = cast(typeof(api.resize)) GetProcAddress(kernel32, "ResizePseudoConsole");
            api.close = cast(typeof(api.close)) GetProcAddress(kernel32, "ClosePseudoConsole");
        }
        const present = api.create !is null && api.resize !is null && api.close !is null;
        if (present)
            conPtyApi_ = api;
        state = present ? 1 : 2;
        atomicStore(conPtyState, state);
    }
    return state == 1 ? &conPtyApi_ : null;
}

/// A `COORD` packed the way the ConPTY calls take it by value.
private uint coord(ushort cols, ushort rows) @safe pure nothrow @nogc
    => cast(uint) cols | (cast(uint) rows << 16);

/// The move-only owner of an `HPCON`.
package struct PseudoConsole
{
    private void* _pc;

    @disable this(this);
    ~this() @safe nothrow @nogc { close(); }

    bool valid() const @safe pure nothrow @nogc => _pc !is null;

    /// Ends conhost; its output pipe then reaches EOF. A second call does
    /// nothing.
    void close() @trusted nothrow @nogc
    {
        if (_pc is null)
            return;
        conPtyApi().close(_pc);
        _pc = null;
    }
}

/**
Spawns `argv` on a fresh pseudoconsole (SPEC §13.3, §13.9): a ConPTY of
`cols` × `rows`, fed through two uniquely named pipes whose parent ends are
overlapped and ride the port — `ptyMaster` reads the console's output (VT
sequences), `stdinW` writes its input. `stdinSpec`/`stdoutSpec`/`stderrSpec`
are ignored: the child's console is the ConPTY, and it inherits no handle.
Everything else is `spawnProcess`'s: the PATH search, the overlay, the cwd,
the suspended start inside its own Job Object.

The pseudoconsole is closed by the reap, which ends conhost and so the
output pipe: drain `ptyMaster` concurrently, as a terminal does, or at least
until the reap, then to EOF. `ENOSYS` where ConPTY is missing.
*/
IoResult!ChildProcess spawnPty(scope const(char[])[] argv,
    ushort cols, ushort rows, in ProcessConfig cfg = ProcessConfig()) @trusted
{
    import core.stdc.errno : ENOSYS;

    auto api = conPtyApi();
    if (api is null)
        return ioErr!ChildProcess(ENOSYS, OpKind.none, IoErrorStage.setup,
            "this host has no ConPTY");
    OwnedFd input, output;
    HANDLE consoleReads, consoleWrites;
    if (!openStdioPipe(false, input, consoleReads))
        return ioErr!ChildProcess(winErrno(GetLastError()), OpKind.none,
            IoErrorStage.setup, "pty input pipe failed");
    scope (exit) CloseHandle(consoleReads);
    if (!openStdioPipe(true, output, consoleWrites))
        return ioErr!ChildProcess(winErrno(GetLastError()), OpKind.none,
            IoErrorStage.setup, "pty output pipe failed");
    scope (exit) CloseHandle(consoleWrites);
    PseudoConsole pty;
    const hr = api.create(coord(cols, rows), consoleReads, consoleWrites, 0, &pty._pc);
    if (hr < 0)
        return ioErr!ChildProcess(EIO, OpKind.none, IoErrorStage.setup,
            "CreatePseudoConsole failed");
    auto spawned = spawnImpl(argv, cfg, pty._pc);
    if (spawned.hasError)
        return ioErr!ChildProcess(spawned.error);
    auto child = move(spawned.value);
    child.pty = move(pty);
    child.stdinW = move(input);
    child.ptyMaster = move(output);
    return ioOk(move(child));
}

/// Propagates a resize to the pseudoconsole (SPEC §13.3); the child's
/// console buffer and window follow.
IoResult!void resizePty(ref ChildProcess child, ushort cols, ushort rows)
    @trusted nothrow @nogc
{
    import core.stdc.errno : EBADF;

    if (!child.pty.valid)
        return ioErr!void(EBADF, OpKind.none, IoErrorStage.submit, "not a PTY child");
    if (conPtyApi().resize(child.pty._pc, coord(cols, rows)) < 0)
        return ioErr!void(EIO, OpKind.none, IoErrorStage.submit,
            "ResizePseudoConsole failed");
    return ioOk();
}

// ── the live net capability on Winsock (SPEC §10.3, §11) ────────────────────

/// The live net capability: TCP sockets through Winsock, connections over
/// the port (`ConnectEx`, `AcceptEx`). `Stream`/`Listener` are the tier-B
/// `io` handles, as on POSIX. The backend has started Winsock.
struct RingNet
{
    import sparkles.event_horizon.io : IoListener = Listener, IoStream = Stream;
    import sparkles.event_horizon.net : SockAddr;

    enum string capName = "net";

    /// The connected-stream handle type (SPEC §10.3 `isNet`).
    alias Stream = IoStream;

    /// The listening-socket handle type.
    alias Listener = IoListener;

    private Sched* _sched;

    /// Binds to the scheduler whose port backs the socket ops.
    this(Sched* sched) @safe pure nothrow @nogc
    {
        _sched = sched;
    }

    /// Creates a TCP socket, binds it to `at`, and listens.
    IoResult!Listener listen(SockAddr at, int backlog = 128) @trusted nothrow
    {
        const s = socket(2 /* AF_INET */, 1 /* SOCK_STREAM */, 0);
        if (s == size_t.max)
            return ioErr!Listener(winErrno(WSAGetLastError()), OpKind.none,
                IoErrorStage.setup, "socket() failed");
        if (bind(s, at.storage.ptr, at.len) != 0 || listen_(s, backlog) != 0)
        {
            const err = winErrno(WSAGetLastError());
            closesocket(s);
            return ioErr!Listener(err, OpKind.none, IoErrorStage.setup,
                "bind/listen failed");
        }
        return ioOk(Listener(cast(int) s));
    }

    /// Creates a TCP socket and connects it to `to` (parks on the port).
    IoResult!Stream connect(SockAddr to)
    {
        import sparkles.event_horizon.io : connect_ = connect;

        const s = (() @trusted => socket(2 /* AF_INET */, 1 /* SOCK_STREAM */, 0))();
        if (s == size_t.max)
            return ioErr!Stream(winErrno((() @trusted => WSAGetLastError())()),
                OpKind.none, IoErrorStage.setup, "socket() failed");
        auto stream = Stream(cast(int) s);
        auto r = connect_(stream, to);
        if (r.hasError)
        {
            stream.close();
            return ioErr!Stream(r.error);
        }
        return ioOk(stream);
    }
}

private extern (Windows) nothrow @nogc
{
    size_t socket(int af, int type, int protocol);
    int bind(size_t s, const(void)* addr, uint length);
    pragma(mangle, "listen") int listen_(size_t s, int backlog);
    int closesocket(size_t s);
    int WSAGetLastError();
    HANDLE GetModuleHandleW(const(wchar)* name);
    void* GetProcAddress(HANDLE module_, const(char)* name);
}
pragma(lib, "ws2_32");

// ── exit (SPEC §13.9) ───────────────────────────────────────────────────────

/// The exit status of a signalled process handle, read once.
package IoResult!ExitStatus exitStatusOf(ref ChildProcess child) @trusted nothrow @nogc
{
    uint code;
    if (!GetExitCodeProcess(child.process.borrowFd.fd, &code))
        return ioErr!ExitStatus(winErrno(GetLastError()), OpKind.waitid,
            IoErrorStage.completion, "GetExitCodeProcess failed");
    return ioOk(ExitStatus(false, cast(int) code));
}

/// Clears the job's kill-on-close limit, so the reap leaves whatever is still
/// in it running (`ResidualPolicy.detach`). Best effort: a failure only means
/// the residual is ended at the reap after all.
package void detachJob(ref ChildProcess child) @trusted nothrow @nogc
{
    if (!child.job.valid)
        return;
    JobExtendedLimit limit;
    cast(void) SetInformationJobObject(child.job.borrowFd.fd,
        JobObjectExtendedLimitInformation, &limit, JobExtendedLimit.sizeof);
}

/// Consumes the reap right: closes the process handle and the job (which
/// ends any descendant left in it) and nulls the pid.
private void consume(ref ChildProcess child) @safe nothrow @nogc
{
    // Closing the pseudoconsole ends conhost, which closes the output pipe:
    // the master's reader then sees EOF.
    child.pty.close();
    child.process.close();
    child.job.close();
    child.pid = -1;
}

static if (canSubmitOp!(DefaultBackend, OpWaitHandle))
{
    /// Parks until the child's process handle signals, without consuming
    /// the reap: the handle stays open, so sampling and the job remain
    /// valid. `ECHILD` once reaped.
    package IoResult!ExitStatus observeExit(ref Sched s, ref ChildProcess child) @trusted
    {
        if (child.pid <= 0 || !child.process.valid)
            return ioErr!ExitStatus(ECHILD, OpKind.waitid, IoErrorStage.submit,
                "no child to reap");
        if (!child.exited)
        {
            auto o = s.await(OpWaitHandle(child.process.borrowFd.fd));
            if (o.res < 0)
                return ioErr!ExitStatus(-o.res, OpKind.waitid);
            child.exited = true;
        }
        return exitStatusOf(child);
    }

    /// Parks until the child exits (one wait completion packet), reads its
    /// exit code once and consumes the reap right. Sets `pid = -1`.
    IoResult!ExitStatus wait(ref Sched s, ref ChildProcess child) @trusted
    {
        auto st = observeExit(s, child);
        if (st.hasValue)
            consume(child);
        return st;
    }

    private struct LaneWaitJob
    {
        HANDLE process;
        uint timeoutMs;
        uint result;
    }

    private void laneWaitCall(void* p) nothrow
    {
        auto job = cast(LaneWaitJob*) p;
        job.result = WaitForSingleObject(job.process, job.timeoutMs);
    }

    /// The termination-critical fallback reap, off the scheduler thread
    /// (SPEC §13.8): taken only after an in-ring wait failed with something
    /// other than a lost right. Shared by `supervise`.
    package IoResult!ExitStatus reapOnLane(ref Sched s, ref ChildProcess child) @trusted
    {
        import sparkles.event_horizon.blocking_pool : sharedBlockingPool;

        if (child.pid <= 0)
            return ioErr!ExitStatus(ECHILD, OpKind.waitid, IoErrorStage.submit,
                "no child to reap");
        auto pool = sharedBlockingPool();
        if (pool.hasError)
            return ioErr!ExitStatus(pool.error);
        LaneWaitJob job = {process: child.process.borrowFd.fd, timeoutMs: uint.max};
        auto ran = pool.value.runMandatory(s, &laneWaitCall, &job);
        if (ran.hasError)
            return ioErr!ExitStatus(ran.error);
        if (job.result != 0)
            return ioErr!ExitStatus(EIO, OpKind.waitid, IoErrorStage.completion,
                "WaitForSingleObject fallback failed");
        child.exited = true;
        auto st = exitStatusOf(child);
        if (st.hasValue)
            consume(child);
        return st;
    }

    /// One non-blocking probe of the root (a finite lane job): whether its
    /// handle has signalled. The supervisor's observer-failure path.
    package bool probeExited(ref ChildProcess child) @trusted nothrow @nogc
        => child.process.valid && WaitForSingleObject(child.process.borrowFd.fd, 0) == 0;
}

// ── the console control channel (SPEC §13.9 graceful stage) ─────────────────

/**
Sends `CTRL_BREAK_EVENT` to the child's process group when that group can
receive it: the child was created as a group leader and is attached to
this process's console (`GetConsoleProcessList`). Returns false — no soft
signal deliverable — otherwise, never broadcasting to the console.
*/
package bool sendConsoleBreak(ref ChildProcess child) @trusted nothrow
{
    if (child.pid <= 0 || !child.processGroup || child.exited)
        return false;
    uint[64] small;
    uint[] pids = small[];
    for (;;)
    {
        const n = GetConsoleProcessList(pids.ptr, cast(uint) pids.length);
        if (n == 0)
            return false; // no console: no control channel at all
        if (n <= pids.length)
        {
            pids = pids[0 .. n];
            break;
        }
        pids = new uint[](n);
    }
    bool attached;
    foreach (p; pids)
        attached |= p == cast(uint) child.pid;
    enum uint CTRL_BREAK_EVENT = 1;
    return attached && GenerateConsoleCtrlEvent(CTRL_BREAK_EVENT, cast(uint) child.pid) != 0;
}

// ── Job Object vocabulary (shared with `sampling_windows`) ──────────────────

package enum int JobObjectBasicAndIoAccountingInformation = 8;
package enum int JobObjectExtendedLimitInformation = 9;
package enum uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000;

/// `JOBOBJECT_BASIC_LIMIT_INFORMATION`.
package struct JobBasicLimit
{
    long PerProcessUserTimeLimit, PerJobUserTimeLimit;
    uint LimitFlags;
    size_t MinimumWorkingSetSize, MaximumWorkingSetSize;
    uint ActiveProcessLimit;
    size_t Affinity;
    uint PriorityClass, SchedulingClass;
}

/// `IO_COUNTERS`.
package struct IoCounters
{
    ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
    ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
}

/// `JOBOBJECT_EXTENDED_LIMIT_INFORMATION`.
package struct JobExtendedLimit
{
    JobBasicLimit basic;
    IoCounters io;
    size_t ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
}

/// `JOBOBJECT_BASIC_ACCOUNTING_INFORMATION`.
package struct JobBasicAccounting
{
    long TotalUserTime, TotalKernelTime, ThisPeriodTotalUserTime, ThisPeriodTotalKernelTime;
    uint TotalPageFaultCount, TotalProcesses, ActiveProcesses, TotalTerminatedProcesses;
}

/// `JOBOBJECT_BASIC_AND_IO_ACCOUNTING_INFORMATION`.
package struct JobBasicAndIoAccounting
{
    JobBasicAccounting basic;
    IoCounters io;
}

version (Win64)
{
    static assert(JobBasicLimit.sizeof == 64);
    static assert(JobExtendedLimit.sizeof == 144);
    static assert(JobBasicAndIoAccounting.sizeof == 96);
}

// ── bindings ────────────────────────────────────────────────────────────────

private enum BOOL TRUE = 1;

private struct SECURITY_ATTRIBUTES
{
    uint nLength;
    void* lpSecurityDescriptor;
    BOOL bInheritHandle;
}

private struct STARTUPINFOEXW
{
    STARTUPINFOW StartupInfo;
    void* lpAttributeList;
}

private struct OVERLAPPED_
{
    size_t Internal, InternalHigh;
    uint Offset, OffsetHigh;
    HANDLE hEvent;
}

package extern (Windows) nothrow @nogc
{
    BOOL QueryInformationJobObject(HANDLE job, int infoClass, void* info, uint length,
        uint* returned);
    HANDLE CreateJobObjectW(void* attributes, const(wchar)* name);
}

private extern (Windows) nothrow @nogc
{
    uint GetLastError();
    BOOL CloseHandle(HANDLE);
    BOOL CreateProcessW(const(wchar)* app, wchar* commandLine, void* processAttributes,
        void* threadAttributes, BOOL inheritHandles, uint flags, void* environment,
        const(wchar)* cwd, STARTUPINFOW* startup, PROCESS_INFORMATION* info);
    uint ResumeThread(HANDLE thread);
    BOOL TerminateProcess(HANDLE process, uint exitCode);
    BOOL GetExitCodeProcess(HANDLE process, uint* exitCode);
    uint WaitForSingleObject(HANDLE handle, uint milliseconds);
    BOOL SetInformationJobObject(HANDLE job, int infoClass, void* info, uint length);
    BOOL AssignProcessToJobObject(HANDLE job, HANDLE process);
    BOOL TerminateJobObject(HANDLE job, uint exitCode);
    BOOL InitializeProcThreadAttributeList(void* list, uint count, uint flags, size_t* size);
    BOOL UpdateProcThreadAttribute(void* list, uint flags, size_t attribute, void* value,
        size_t size, void* previous, size_t* returned);
    void DeleteProcThreadAttributeList(void* list);
    HANDLE CreateNamedPipeW(const(wchar)* name, uint openMode, uint pipeMode,
        uint maxInstances, uint outBuffer, uint inBuffer, uint timeout, void* attributes);
    HANDLE CreateFileW(const(wchar)* name, uint access, uint share,
        SECURITY_ATTRIBUTES* attributes, uint disposition, uint flags, HANDLE templateFile);
    BOOL ConnectNamedPipe(HANDLE pipe, OVERLAPPED_* ov);
    HANDLE GetStdHandle(uint id);
    HANDLE GetCurrentProcess();
    uint GetCurrentProcessId();
    BOOL DuplicateHandle(HANDLE sourceProcess, HANDLE source, HANDLE targetProcess,
        HANDLE* target, uint access, BOOL inherit, uint options);
    int MultiByteToWideChar(uint codePage, uint flags, const(char)* s, int n,
        wchar* w, int wn);
    int WideCharToMultiByte(uint codePage, uint flags, const(wchar)* w, int wn,
        char* s, int n, const(char)* defaultChar, BOOL* usedDefault);
    wchar* GetEnvironmentStringsW();
    BOOL FreeEnvironmentStringsW(wchar* block);
    int CompareStringOrdinal(const(wchar)* a, int na, const(wchar)* b, int nb, BOOL ignoreCase);
    uint GetSystemDirectoryW(wchar* buffer, uint size);
    uint GetWindowsDirectoryW(wchar* buffer, uint size);
    uint GetConsoleProcessList(uint* pids, uint count);
    BOOL GenerateConsoleCtrlEvent(uint event, uint processGroupId);
}

pragma(lib, "kernel32");

// ── test fixtures: the test binary as its own scripted child ────────────────

version (unittest)
{
    /**
    The test binary re-executed as a scripted child: `[self, "--eh-child",
    mode, args…]` performs `mode` from a module constructor and exits before
    the runner starts — exact bytes, exit codes, console handlers and
    grandchildren with no shell and no PowerShell start-up.

    $(UL
        $(LI `lines` — stdout `a\r\nb`, stderr `\0\xff\n`, stdout `c\nlast`;)
        $(LI `exit N`; `env NAME` (value or `<unset>`); `cwd`; `args …`
            (one received argument per line); `cat` (stdin to stdout);)
        $(LI `sleep MS` and `ignore-break MS` (prints `ready`, then sleeps;
            the latter survives `CTRL_BREAK_EVENT`);)
        $(LI `grandchild MS` — starts `sleep MS` sharing its stdio, prints
            `ready`, exits 0;)
        $(LI `alloc MB MS` — commits and touches MB MiB, prints `ready`, sleeps;
            `alloc-tree MB MS` does the same beside a grandchild `alloc MB MS`;)
        $(LI `feed` — stdin to stdout, then `err` to stderr, exit 3;
            `console-size MS` — prints its console window's `cols rows`, sleeps;)
        $(LI `chatty N` — N lines to each stream, interleaved;)
        $(LI `has-handle H` — `yes` if handle value H is open in the child.))
    */
    package string[] childArgv(scope string[] script...) @safe nothrow
        => [selfPath(), "--eh-child"] ~ script.dup;

    package string selfPath() @trusted nothrow
    {
        wchar[1024] buf;
        const n = GetModuleFileNameW(null, buf.ptr, cast(uint) buf.length);
        return fromWide(buf[0 .. n]);
    }

    /// Skips only under Wine (no wait completion packets); native Windows
    /// without them is a failure. Call before `Sched.run`.
    package void requireProcessWait() @safe
    {
        import sparkles.event_horizon.sys.nt : runningUnderWine, waitPacketApi;
        import sparkles.test_runner.skip : skipTest;

        if (waitPacketApi() is null)
        {
            assert(runningUnderWine(), "native Windows without wait completion packets");
            skipTest("Wine exports no NtAssociateWaitCompletionPacket");
        }
    }

    private void childWrite(uint which, scope const(char)[] bytes) @trusted nothrow @nogc
    {
        uint written;
        WriteFile(GetStdHandle(which), bytes.ptr, cast(uint) bytes.length, &written, null);
    }

    private extern (Windows) BOOL ignoreConsoleEvent(uint) nothrow @nogc => TRUE;

    /// `CONSOLE_SCREEN_BUFFER_INFO`, flattened.
    private struct ConsoleBufferInfo
    {
        short sizeX, sizeY, cursorX, cursorY;
        ushort attributes;
        short left, top, right, bottom;
        short maxX, maxY;
    }

    /// Starts `[self, "--eh-child", script…]` sharing this child's stdio
    /// wholesale: the descendant holds the supervised pipes open after its
    /// parent exits.
    private bool spawnSelf(string script) @trusted nothrow
    {
        wchar[] line;
        cast(void) toWide("\"" ~ selfPath() ~ "\" --eh-child " ~ script, line, true);
        STARTUPINFOW si;
        si.cb = STARTUPINFOW.sizeof;
        PROCESS_INFORMATION pi;
        if (!CreateProcessW(null, line.ptr, null, null, TRUE, 0, null, null, &si, &pi))
            return false;
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
        return true;
    }

    /// Commits and touches `mb` MiB, so it is all in the working set.
    private void touchMegabytes(int mb) @trusted nothrow @nogc
    {
        const size = cast(size_t) mb << 20;
        auto p = cast(ubyte*) VirtualAlloc(null, size, 0x3000, 4); // COMMIT|RESERVE, RW
        if (p is null)
            ExitProcess(3);
        for (size_t at = 0; at < size; at += 4096)
            p[at] = 1;
    }

    private int runChild(scope const(wchar[])[] args) @trusted nothrow
    {
        import core.stdc.stdlib : atoi;

        enum uint OUT = cast(uint) -11, ERR = cast(uint) -12, IN = cast(uint) -10;
        const mode = fromWide(args[0]);
        int number(size_t i) => i < args.length ? atoi((fromWide(args[i]) ~ '\0').ptr) : 0;
        switch (mode)
        {
        case "lines":
            childWrite(OUT, "a\r\nb");
            childWrite(ERR, "\0\xff\n");
            childWrite(OUT, "c\nlast");
            return 0;
        case "exit":
            return number(1);
        case "env":
            wchar[32_768] buf;
            const name = args[1] ~ '\0';
            const n = GetEnvironmentVariableW(name.ptr, buf.ptr, cast(uint) buf.length);
            childWrite(OUT, n == 0 && GetLastError() == 203 ? "<unset>" : fromWide(buf[0 .. n]));
            childWrite(OUT, "\n");
            return 0;
        case "cwd":
            wchar[1024] buf;
            const n = GetCurrentDirectoryW(cast(uint) buf.length, buf.ptr);
            childWrite(OUT, fromWide(buf[0 .. n]));
            return 0;
        case "args":
            foreach (a; args[1 .. $])
            {
                childWrite(OUT, fromWide(a));
                childWrite(OUT, "\n");
            }
            return 0;
        case "cat":
            ubyte[4096] buf;
            uint got;
            while (ReadFile(GetStdHandle(IN), buf.ptr, buf.length, &got, null) && got != 0)
                childWrite(OUT, cast(const(char)[]) buf[0 .. got]);
            return 0;
        case "ignore-break":
            SetConsoleCtrlHandler(&ignoreConsoleEvent, TRUE);
            goto case "sleep";
        case "sleep":
            childWrite(OUT, "ready\n");
            Sleep(number(1));
            return 0;
        case "grandchild":
            if (!spawnSelf("sleep " ~ fromWide(args[1])))
                return 2;
            childWrite(OUT, "ready\n");
            return 0;
        case "alloc":
            touchMegabytes(number(1));
            childWrite(OUT, "ready\n");
            Sleep(number(2));
            return 0;
        case "alloc-tree":
            if (!spawnSelf("alloc " ~ fromWide(args[1]) ~ " " ~ fromWide(args[2])))
                return 2;
            touchMegabytes(number(1));
            childWrite(OUT, "ready\n");
            Sleep(number(2));
            return 0;
        case "feed":
            ubyte[4096] fed;
            uint n;
            while (ReadFile(GetStdHandle(IN), fed.ptr, fed.length, &n, null) && n != 0)
                childWrite(OUT, cast(const(char)[]) fed[0 .. n]);
            childWrite(ERR, "err");
            return 3;
        case "console-size":
            ConsoleBufferInfo info;
            if (!GetConsoleScreenBufferInfo(GetStdHandle(OUT), &info))
                return 4;
            import std.conv : to;

            childWrite(OUT, (info.right - info.left + 1).to!string ~ " "
                ~ (info.bottom - info.top + 1).to!string ~ "\n");
            Sleep(number(1));
            return 0;
        case "chatty":
            foreach (i; 0 .. number(1))
            {
                childWrite(OUT, "out\n");
                childWrite(ERR, "err\n");
            }
            return 0;
        case "has-handle":
            uint flags;
            auto h = cast(HANDLE) cast(ptrdiff_t) number(1);
            childWrite(OUT, GetHandleInformation(h, &flags) ? "yes\n" : "no\n");
            return 0;
        default:
            return 99;
        }
    }

    shared static this()
    {
        int argc;
        auto argv = (() @trusted => CommandLineToArgvW(GetCommandLineW(), &argc))();
        if (argv is null || argc < 3)
            return;
        auto a1 = (() @trusted => argv[1])();
        size_t n;
        while ((() @trusted => a1[n])() != 0)
            ++n;
        if ((() @trusted => a1[0 .. n])() != "--eh-child"w)
            return;
        wchar[][] args;
        foreach (i; 2 .. argc)
            (() @trusted {
                size_t len;
                while (argv[i][len] != 0)
                    ++len;
                args ~= argv[i][0 .. len].dup;
            })();
        (() @trusted => ExitProcess(cast(uint) runChild(args)))();
    }

    private extern (Windows) nothrow @nogc
    {
        uint GetModuleFileNameW(HANDLE module_, wchar* buffer, uint size);
        wchar* GetCommandLineW();
        BOOL WriteFile(HANDLE, const(void)*, uint, uint*, void*);
        BOOL ReadFile(HANDLE, void*, uint, uint*, void*);
        uint GetEnvironmentVariableW(const(wchar)* name, wchar* buffer, uint size);
        uint GetCurrentDirectoryW(uint size, wchar* buffer);
        void Sleep(uint ms);
        void* VirtualAlloc(void* address, size_t size, uint type, uint protect);
        void ExitProcess(uint code);
        BOOL SetConsoleCtrlHandler(BOOL function(uint) nothrow @nogc handler, BOOL add);
        BOOL GetHandleInformation(HANDLE, uint*);
        BOOL GetConsoleScreenBufferInfo(HANDLE console, ConsoleBufferInfo* info);
        HANDLE CreateEventW(SECURITY_ATTRIBUTES* attributes, BOOL manual, BOOL initial,
            const(wchar)* name);
    }

    package extern (Windows) wchar** CommandLineToArgvW(const(wchar)* line, int* argc)
        nothrow @nogc;
    pragma(lib, "shell32");

    /// Reads `from` to EOF.
    package const(ubyte)[] drainAll(BorrowedFd from) @trusted
    {
        import sparkles.base.buffer : SharedBuffer;
        import sparkles.event_horizon.io : read;

        const(ubyte)[] all;
        for (;;)
        {
            SharedBuffer!(ubyte, 512) chunk;
            chunk.length = 512;
            auto got = read(from, move(chunk));
            assert(!got.res.hasError, got.res.hasError ? got.res.error.context : "");
            if (got.res.value == 0)
                return all;
            all ~= got.buf[][0 .. got.res.value];
        }
    }
}

version (unittest)
{
    import sparkles.event_horizon.proc : EnvironmentChange;
    import sparkles.event_horizon.sched : schedOrSkip;
}

/// Every argument survives `CommandLineToArgvW` unchanged: quotes,
/// backslash runs before quotes and at the end, empty strings, whitespace.
@("live.windows.commandLineRoundTrip")
@system unittest
{
    static immutable wstring[] args = [`C:\Program Files\tool.exe`, ``, `plain`,
        `two words`, `a"b`, `a\b`, `a\\"b`, `trail\`, `trail space\ `, `\\server\share`,
        "tab\there", `"quoted"`, `\"`, `\\`, `x\\\"y`];
    wchar[] line;
    foreach (i, a; args)
        assert(appendArgument(line, a, i == 0));
    line ~= '\0';
    int argc;
    auto argv = CommandLineToArgvW(line.ptr, &argc);
    assert(argv !is null && argc == args.length);
    foreach (i, expected; args)
    {
        size_t n;
        while (argv[i][n] != 0)
            ++n;
        assert(argv[i][0 .. n] == expected);
    }
    wchar[] bad;
    assert(!appendArgument(bad, `a"b.exe`, true), "a program name cannot hold a quote");
}

/// The overlay sets, replaces case-insensitively and unsets; the block is
/// sorted ordinally without case and double-NUL terminated.
@("live.windows.environmentOverlaySortAndBlock")
@safe unittest
{
    ProcessConfig cfg;
    cfg.env = ["Zeta=1", "path=C:\\old", "alpha=2", "Gone=x"];
    cfg.envOverlay = [EnvironmentChange("PATH", "C:\\new"),
        EnvironmentChange("gone", null, true), EnvironmentChange("Beta", "3")];
    bool custom;
    auto r = windowsEnvironment(cfg, custom);
    assert(r.hasValue && custom);
    assert(r.value == ["alpha=2"w, "Beta=3"w, "PATH=C:\\new"w, "Zeta=1"w]);
    assert(pathOf(r.value) == "C:\\new"w);
    assert(environmentBlock(r.value) == "alpha=2\0Beta=3\0PATH=C:\\new\0Zeta=1\0\0"w);
    assert(environmentBlock(null) == "\0\0"w);

    ProcessConfig inherit;
    bool inheritCustom;
    assert(windowsEnvironment(inherit, inheritCustom).hasValue && !inheritCustom);
    ProcessConfig bad;
    bad.envOverlay = [EnvironmentChange("A=B", "x")];
    assert(windowsEnvironment(bad, inheritCustom).error.code == EINVAL);
}

/// The PATH search: separators spell a path, `.exe` is appended to a bare
/// name, relative candidates resolve against the child's cwd, empty and
/// quoted components follow Windows.
@("live.windows.searchCandidates")
@safe unittest
{
    assert(searchCandidates("tool"w, `C:\a;;"C:\b c";rel`w, true, null)
        == [`C:\a\tool.exe`w, `C:\b c\tool.exe`w, `rel\tool.exe`w]);
    assert(searchCandidates("tool.com"w, `C:\a`w, true, `D:\cwd`w) == [`C:\a\tool.com`w]);
    assert(searchCandidates(`bin\tool`w, `C:\a`w, true, `D:\cwd`w) == [`D:\cwd\bin\tool.exe`w]);
    assert(searchCandidates("tool"w, null, false, null).length >= 1, "system dirs");
    wchar[] z;
    assert(toWide("ab", z, true) && z == "ab\0"w, "terminated with NUL, not wchar.init");
}

/// Spawn, separate streams, exact bytes, exit status, one reap.
@("live.windows.spawnStreamsAndWait")
@system unittest
{
    requireProcessWait();
    Sched s;
    schedOrSkip(s);
    auto r = s.run(() {
        ProcessConfig cfg;
        cfg.stderrSpec = StdioSpec(StdioMode.pipe);
        auto spawned = spawnProcess(childArgv("lines"), cfg);
        assert(spawned.hasValue, spawned.hasError ? spawned.error.context : "");
        auto child = move(spawned.value);
        assert(child.pid > 0 && !child.stdinW.valid);
        assert(drainAll(child.stdoutR.borrowFd) == cast(const(ubyte)[]) "a\r\nbc\nlast");
        assert(drainAll(child.stderrR.borrowFd) == [0, 0xff, '\n']);
        auto st = wait(s, child);
        assert(st.hasValue && st.value.ok);
        assert(!child && !child.process.valid && !child.job.valid);
        assert(wait(s, child).error.code == ECHILD, "one reap");
        assert(child.kill().error.code == ESRCH);
    });
    assert(!r.hasError);
}

/// Exit codes, stdin, cwd, merged stderr and the argument vector survive a
/// real child.
@("live.windows.exitStdinCwdMergeAndArgs")
@system unittest
{
    requireProcessWait();
    Sched s;
    schedOrSkip(s);
    auto r = s.run(() {
        auto exited = spawnProcess(childArgv("exit", "7"));
        auto child = move(exited.value);
        assert(wait(s, child).value == ExitStatus(false, 7));

        ProcessConfig piped;
        piped.stdinSpec = StdioSpec(StdioMode.pipe);
        auto cat = move(spawnProcess(childArgv("cat"), piped).value);
        import sparkles.base.buffer : SharedBuffer;
        import sparkles.event_horizon.io : write;
        SharedBuffer!(ubyte, 64) payload;
        payload ~= cast(const(ubyte)[]) "through stdin\n";
        assert(!write(cat.stdinW, move(payload)).res.hasError);
        cat.stdinW.close();
        assert(drainAll(cat.stdoutR.borrowFd) == cast(const(ubyte)[]) "through stdin\n");
        assert(wait(s, cat).value.ok);

        ProcessConfig inDir;
        wchar[260] sys;
        const n = GetSystemDirectoryW(sys.ptr, cast(uint) sys.length);
        inDir.cwd = fromWide(sys[0 .. n]);
        auto cwd = move(spawnProcess(childArgv("cwd"), inDir).value);
        assert(cast(string) drainAll(cwd.stdoutR.borrowFd) == inDir.cwd);
        assert(wait(s, cwd).value.ok);

        ProcessConfig merged;
        merged.stderrSpec = StdioSpec(StdioMode.mergeStdout);
        auto lines = move(spawnProcess(childArgv("lines"), merged).value);
        assert(drainAll(lines.stdoutR.borrowFd) == cast(const(ubyte)[]) "a\r\nb\0\xff\nc\nlast");
        assert(wait(s, lines).value.ok);

        auto argv = childArgv("args", "", "two words", `a"b`, `trail\`, "ünï");
        auto echoed = move(spawnProcess(argv).value);
        assert(cast(string) drainAll(echoed.stdoutR.borrowFd)
            == "\ntwo words\na\"b\ntrail\\\nünï\n");
        assert(wait(s, echoed).value.ok);
    });
    assert(!r.hasError);
}

/// Environment set/replace/unset reach the child, matched without case,
/// and the PATH search uses the child's PATH: found, then not found with
/// no child left behind.
@("live.windows.environmentAndPathLookup")
@system unittest
{
    requireProcessWait();
    Sched s;
    schedOrSkip(s);
    auto r = s.run(() {
        string envOf(string name, const(EnvironmentChange)[] overlay)
        {
            ProcessConfig cfg;
            cfg.envOverlay = overlay;
            auto child = move(spawnProcess(childArgv("env", name), cfg).value);
            auto got = cast(string) drainAll(child.stdoutR.borrowFd);
            assert(wait(s, child).value.ok);
            return got;
        }
        assert(envOf("EH_SET", [EnvironmentChange("EH_SET", "v1")]) == "v1\n");
        assert(envOf("EH_SET", [EnvironmentChange("EH_SET", "v1"),
            EnvironmentChange("eh_set", "v2")]) == "v2\n");
        assert(envOf("EH_SET", [EnvironmentChange("EH_SET", "v1"),
            EnvironmentChange("Eh_Set", null, true)]) == "<unset>\n");

        wchar[260] sys;
        const n = GetSystemDirectoryW(sys.ptr, cast(uint) sys.length);
        ProcessConfig onPath;
        onPath.stdoutSpec = StdioSpec(StdioMode.nullDev);
        onPath.envOverlay = [EnvironmentChange("Path", fromWide(sys[0 .. n]))];
        auto found = spawnProcess(["cmd", "/c", "exit 3"], onPath);
        assert(found.hasValue, found.hasError ? found.error.context : "");
        auto cmd = move(found.value);
        assert(wait(s, cmd).value == ExitStatus(false, 3));

        ProcessConfig offPath;
        offPath.envOverlay = [EnvironmentChange("PATH", `C:\eh-no-such-dir`)];
        auto missing = spawnProcess(["cmd", "/c", "exit 3"], offPath);
        assert(missing.hasError && missing.error.code == ENOENT);
    });
    assert(!r.hasError);
}

/// Only the child's stdio ends are inherited: an inheritable handle of the
/// parent's that is not in the handle list is absent in the child.
@("live.windows.handleListRestrictsInheritance")
@system unittest
{
    requireProcessWait();
    SECURITY_ATTRIBUTES inherit = {nLength: SECURITY_ATTRIBUTES.sizeof, bInheritHandle: TRUE};
    auto leaked = CreateEventW(&inherit, TRUE, 0, null);
    assert(leaked !is null);
    scope (exit) CloseHandle(leaked);
    Sched s;
    schedOrSkip(s);
    auto r = s.run(() {
        import std.conv : to;

        auto child = move(spawnProcess(childArgv("has-handle",
            (cast(size_t) leaked).to!string)).value);
        assert(cast(string) drainAll(child.stdoutR.borrowFd) == "no\n");
        assert(wait(s, child).value.ok);
    });
    assert(!r.hasError);
}

/// `kill` ends the root, `killGroup` the whole job; a killed child reports
/// `killedExitCode`, and the reap closes the job.
@("live.windows.killAndKillGroup")
@system unittest
{
    requireProcessWait();
    Sched s;
    schedOrSkip(s);
    auto r = s.run(() {
        auto one = move(spawnProcess(childArgv("sleep", "30000")).value);
        assert(!one.kill().hasError);
        assert(wait(s, one).value == ExitStatus(false, killedExitCode));

        auto tree = move(spawnProcess(childArgv("grandchild", "30000")).value);
        // The root exits at once; the grandchild holds stdout open.
        assert(wait(s, tree).value.ok, "the root's own status");
        // The reap closed the job, so the grandchild died with it: EOF.
        // Its own `ready`, and the grandchild's if it ran before the job ended.
        const out_ = cast(string) drainAll(tree.stdoutR.borrowFd);
        assert(out_ == "ready\n" || out_ == "ready\nready\n");
    });
    assert(!r.hasError);
}

version (unittest)
{
    /// A real Win32 message-loop host (the `wsi` shape): it drains the
    /// thread's message queue and blocks in `MsgWaitForMultipleObjectsEx`
    /// on Event Horizon's one native handle. It counts its waits, so a test
    /// can see that nothing but the expected completion woke it.
    private struct MessageHost
    {
        uint waits;

        bool dispatchPending() @trusted nothrow
        {
            MSG_ message;
            bool any;
            while (PeekMessageW(&message, null, 0, 0, 1 /* PM_REMOVE */))
            {
                any = true;
                DispatchMessageW(&message);
            }
            return any;
        }

        IoResult!bool wait(void* handle, uint timeoutMs) @trusted nothrow
        {
            ++waits;
            enum uint QS_ALLINPUT = 0x4FF, MWMO_INPUTAVAILABLE = 4, WAIT_TIMEOUT = 258;
            const r = MsgWaitForMultipleObjectsEx(1, &handle, timeoutMs, QS_ALLINPUT,
                MWMO_INPUTAVAILABLE);
            if (r == uint.max)
                return ioErr!bool(winErrno(GetLastError()), OpKind.none,
                    IoErrorStage.completion, "MsgWaitForMultipleObjectsEx failed");
            return ioOk(r != WAIT_TIMEOUT);
        }
    }

    private struct MSG_
    {
        HANDLE hwnd;
        uint message;
        size_t wParam;
        ptrdiff_t lParam;
        uint time;
        int x, y;
        uint lPrivate;
    }

    private extern (Windows) nothrow @nogc
    {
        BOOL PeekMessageW(MSG_* message, HANDLE hwnd, uint first, uint last, uint remove);
        ptrdiff_t DispatchMessageW(const(MSG_)* message);
        uint MsgWaitForMultipleObjectsEx(uint count, const(void*)* handles, uint ms,
            uint wakeMask, uint flags);
    }
    pragma(lib, "user32");

    /// Ticks `s` through `host` until `done`, with a host timeout far past
    /// any bound the caller asserts: a missed wake would sleep through it.
    private void driveHosted(ref Sched s, ref MessageHost host, scope bool delegate() done)
        @system
    {
        import core.time : seconds;

        while (!done())
        {
            auto r = s.tickHosted(host, 30.seconds);
            assert(!r.hasError, r.hasError ? r.error.context : "");
        }
    }
}

/// A message-loop host blocked in `MsgWaitForMultipleObjectsEx` observes a
/// child's exit promptly with no other input: the exit's wait packet is
/// queued on the port the host waits on.
@("live.windows.messageHostObservesProcessExit")
@system unittest
{
    import core.time : MonoTime, msecs, seconds;

    requireProcessWait();
    Sched s;
    schedOrSkip(s);
    MessageHost host;
    bool done;
    ExitStatus status;
    MonoTime spawned, observed;
    assert(!s.spawn(() {
        ProcessConfig quiet; // no pipes: the exit is the only completion
        quiet.stdinSpec = quiet.stdoutSpec = quiet.stderrSpec = StdioSpec(StdioMode.nullDev);
        auto child = move(spawnProcess(childArgv("sleep", "300"), quiet).value);
        spawned = MonoTime.currTime;
        status = wait(s, child).value;
        observed = MonoTime.currTime;
        done = true;
    }).hasError);
    driveHosted(s, host, () => done);
    assert(status.ok);
    const took = observed - spawned;
    assert(took >= 300.msecs && took < 3.seconds, "the exit woke the host");
}

/// A message-loop host observes a short in-ring sleep at the
/// high-resolution timer's precision, not the clock interval's: the
/// timer's packet ends the host's wait.
@("live.windows.messageHostObservesHighResolutionTimer")
@system unittest
{
    import std.algorithm.sorting : sort;
    import core.time : Duration, MonoTime, msecs;
    import sparkles.event_horizon.io : sleep;

    requireProcessWait(); // the timer packet needs the same exports
    Sched s;
    schedOrSkip(s);
    MessageHost host;
    Duration[7] runs;
    size_t finished;
    assert(!s.spawn(() {
        foreach (ref run; runs)
        {
            const before = MonoTime.currTime;
            assert(!sleep(s, 3.msecs).hasError);
            run = MonoTime.currTime - before;
            ++finished;
        }
    }).hasError);
    driveHosted(s, host, () => finished == runs.length);
    sort(runs[]);
    assert(runs[0] >= 3.msecs, "never early");
    assert(runs[3] < 10.msecs, "the timer's packet, not a ~15.6 ms tick, woke the host");
}

// ── capture, ConPTY and the capability row on Windows ──────────────────────

version (unittest)
{
    import sparkles.event_horizon.capability : hasCaps;
    import sparkles.event_horizon.clock : isClock;
    import sparkles.event_horizon.live_shared : Env, RingClock, RingProc, capture,
        canWaitProcesses, liveEnv, testCaptureReadErrno;
    import sparkles.event_horizon.net : isNet;
    import sparkles.event_horizon.proc : isProc;

    static assert(isClock!RingClock);
    static assert(isNet!RingNet);
    static assert(isProc!RingProc);
    static assert(canWaitProcesses);
    static assert(hasCaps!(Env, "clock", "net", "proc", "fs"));

    /// Skips unless ConPTY can run here: Wine's is not a test target.
    private void requireConPty() @safe
    {
        import sparkles.event_horizon.sys.nt : runningUnderWine;
        import sparkles.test_runner.skip : skipTest;

        requireProcessWait();
        if (conPtyApi() is null)
        {
            assert(runningUnderWine(), "native Windows 10 1809+ has ConPTY");
            skipTest("no ConPTY on this host");
        }
    }

    /// Reads `from` until `needle` appears; the bytes read so far.
    private const(ubyte)[] readUntil(BorrowedFd from, scope const(char)[] needle) @trusted
    {
        import std.algorithm.searching : canFind;
        import sparkles.base.buffer : SharedBuffer;
        import sparkles.event_horizon.io : read;

        const(ubyte)[] all;
        while (!(cast(const(char)[]) all).canFind(needle))
        {
            SharedBuffer!(ubyte, 512) chunk;
            chunk.length = 512;
            auto got = read(from, move(chunk));
            assert(!got.res.hasError && got.res.value != 0, "EOF before the needle");
            all ~= got.buf[][0 .. got.res.value];
        }
        return all;
    }
}

/// `capture` runs to completion over the port: stdin fed, both streams
/// separate, the exit code as data — and merged streams in output order.
@("live.windows.captureStreamsStdinStatusAndMerge")
@system unittest
{
    requireProcessWait();
    Sched s;
    schedOrSkip(s);
    auto r = s.run(() {
        ProcessConfig cfg;
        cfg.stderrSpec = StdioSpec(StdioMode.pipe);
        auto got = capture(s, childArgv("feed"), cfg, cast(const(ubyte)[]) "fed via stdin");
        assert(got.hasValue, got.hasError ? got.error.context : "");
        assert(got.value.stdout_[] == cast(const(ubyte)[]) "fed via stdin");
        assert(got.value.stderr_[] == cast(const(ubyte)[]) "err");
        assert(got.value.status == ExitStatus(false, 3));

        ProcessConfig merged;
        merged.stderrSpec = StdioSpec(StdioMode.mergeStdout);
        auto one = capture(s, childArgv("lines"), merged);
        assert(one.hasValue && one.value.status.ok);
        assert(one.value.stdout_[] == cast(const(ubyte)[]) "a\r\nb\0\xff\nc\nlast");
        assert(one.value.stderr_.length == 0);
    });
    assert(!r.hasError);
}

/// A failed read ends a chatty run (the job is terminated, so the child
/// cannot block on its pipe forever) and is reported, never posing as EOF;
/// a cancellation kills and reaps; a drain that cannot be admitted fails
/// the run with `ENOBUFS`, still reaping.
@("live.windows.captureReadErrorCancellationAndAdmission")
@system unittest
{
    import core.time : MonoTime, msecs, seconds;
    import sparkles.event_horizon.scope_ : withDeadline;
    import sparkles.event_horizon.sched : SchedOptions;

    requireProcessWait();
    {
        Sched s;
        schedOrSkip(s);
        testCaptureReadErrno = EIO;
        scope (exit) testCaptureReadErrno = 0;
        auto r = s.run(() {
            const started = MonoTime.currTime;
            auto got = capture(s, childArgv("chatty", "100000000"));
            assert(got.hasError && got.error.code == EIO);
            assert(MonoTime.currTime - started < 10.seconds);
        });
        assert(!r.hasError);
    }
    {
        Sched s;
        schedOrSkip(s);
        auto r = s.run(() {
            import core.stdc.errno : ECANCELED;

            const started = MonoTime.currTime;
            bool sawCancel;
            auto outcome = withDeadline!((ref sc) {
                auto got = capture(s, childArgv("sleep", "30000"));
                sawCancel = got.hasError && got.error.code == ECANCELED;
                return 0;
            })(s, 100.msecs);
            assert(outcome.hasError && outcome.error.isTimeout && sawCancel);
            assert(MonoTime.currTime - started < 10.seconds, "killed, not waited out");
        });
        assert(!r.hasError);
    }
    {
        import core.stdc.errno : ENOBUFS;

        Sched s;
        SchedOptions opts;
        opts.maxFibers = 2;
        schedOrSkip(s, opts);
        auto r = s.run(() {
            ProcessConfig cfg;
            cfg.stderrSpec = StdioSpec(StdioMode.pipe);
            auto got = capture(s, childArgv("chatty", "100000000"), cfg);
            assert(got.hasError && got.error.code == ENOBUFS);
        });
        assert(!r.hasError);
    }
}

/// A ConPTY child sees a console of the preset size; resizing reaches the
/// pseudoconsole; input written to `stdinW` reaches the child, and output
/// arrives on `ptyMaster` over the port. The reap closes the pseudoconsole,
/// and the master then reaches EOF.
@("live.windows.spawnPtyConsoleSizeInputAndEof")
@system unittest
{
    requireConPty();
    Sched s;
    schedOrSkip(s);
    auto r = s.run(() {
        auto spawned = spawnPty(childArgv("console-size", "200"), 80, 24);
        assert(spawned.hasValue, spawned.hasError ? spawned.error.context : "");
        auto child = move(spawned.value);
        assert(child.ptyMaster.valid && child.stdinW.valid && !child.stdoutR.valid);
        cast(void) readUntil(child.ptyMaster.borrowFd, "80 24");
        assert(!resizePty(child, 100, 30).hasError);
        assert(wait(s, child).value.ok);
        cast(void) drainAll(child.ptyMaster.borrowFd); // EOF after the reap
        assert(resizePty(child, 80, 24).error.code == 9 /* EBADF */);

        auto cat = move(spawnPty(childArgv("cat"), 80, 24).value);
        import sparkles.base.buffer : SharedBuffer;
        import sparkles.event_horizon.io : write;

        SharedBuffer!(ubyte, 64) typed;
        typed ~= cast(const(ubyte)[]) "typed\r";
        assert(!write(cat.stdinW, move(typed)).res.hasError);
        cast(void) readUntil(cat.ptyMaster.borrowFd, "typed");
        assert(!cat.killGroup().hasError);
        assert(wait(s, cat).value == ExitStatus(false, killedExitCode));
        cast(void) drainAll(cat.ptyMaster.borrowFd);
    });
    assert(!r.hasError);
}

/// The live row on Windows carries every capability: `RingProc` spawns
/// and reaps through the port, and `RingNet` listens and connects over
/// Winsock and IOCP.
@("live.windows.liveEnvProcAndNet")
@system unittest
{
    import sparkles.event_horizon.io : accept, recv, send;
    import sparkles.event_horizon.net : SockAddr, ipv4;

    requireProcessWait();
    Sched s;
    schedOrSkip(s);
    auto r = s.run(() {
        auto env = liveEnv(&s);
        auto child = move(env.proc.spawn(childArgv("exit", "5")).value);
        assert(env.proc.wait(child).value == ExitStatus(false, 5));

        auto listener = env.net.listen(ipv4("127.0.0.1", 0)).value;
        scope (exit) listener.close();
        SockAddr bound;
        int length = bound.storage.length;
        assert(getsockname(cast(size_t) listener.fd, bound.storage.ptr, &length) == 0);
        bound.len = length;
        bool served;
        import sparkles.event_horizon.scope_ : withScope;

        auto outcome = withScope!((ref sc) {
            sc.spawn(() {
                auto peer = accept(listener).value;
                scope (exit) peer.close();
                served = true;
            });
            auto stream = env.net.connect(bound);
            assert(stream.hasValue, stream.hasError ? stream.error.context : "");
            stream.value.close();
        })(s);
        assert(!outcome.hasError && served);
    });
    assert(!r.hasError);
}

version (unittest)
private extern (Windows) int getsockname(size_t s, void* addr, int* length) nothrow @nogc;
