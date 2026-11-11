/**
The fileset driver: one adapter over any capability-VFS backend (FSD1).

`FilesetDriver!(V, R)` answers the resolution machine's requests on the
handles of a root its caller opened: a `readDir` opens a child of a
directory it already holds and lists it, a `stat` is `statAt` on the
directory holding the entry. Every operation names one entry of a held
handle (FSD5); which links and mounts a lookup may cross is the root's policy
(FSD6, FSD7), so a link is followed only through `walk` and only when the
machine was told the root's policy follows links. The driver holds one handle
per directory in progress and closes it when the machine retires it
(FSD4: descriptor policy is the driver's).

How a batch runs is an executor's choice: `InlineExecutor` performs the
requests one after another; the event-horizon executor
(`sparkles.build_primitives.fileset.driver_loop`) runs them concurrently
under an admission budget. The in-memory driver is this adapter over
`MemVfs` (FSD2), the synchronous one over `BlockingVfs` (test and
documentation only, FSD3), and the event-horizon one over `RingVfs`.

A resolution's consumer is a sink: `directory(path, members, empty)` for each
resolved directory, before its subdirectories' (a stream, FSS3), and
`incomplete(path, kind)` for each entry that could not be read (FSE2).
`PathCollector` is one. A sink that also has `ignoreDecision(path, isDir,
excluded, source, line, pattern)` hears, for each entry a `.gitignore` rule
decided, which rule it was (FSI3); one with `ignoreRulesSkipped(count)`
hears, once the resolution is done, how many `.gitignore` rule lines no
fileset pattern expresses, so that they did not apply (A15). A scheme is the richer consumer:
`sparkles.build_primitives.fileset.scheme`.

A `gitignored` fileset makes the machine ask for `readFile`, which needs a
root opened with read rights.
*/
module sparkles.build_primitives.fileset.driver;

import core.lifetime : move;

import sparkles.base.expected : Expected, err, ok;
import sparkles.base.io.errors : ErrorKind;
import sparkles.base.text.errors : NoGcHook;
import sparkles.base.vfs.concept : isVfs;
import sparkles.base.vfs.handles : Dir, DirRef;
import sparkles.base.vfs.types : EntryKind, Rights, StatMask, hasRights;

import sparkles.build_primitives.fileset.machine : Cursor, Request, RequestKind, Resolution, ResolutionError,
    ResolutionErrorCode, ResolutionLimits, StepKind, noDir;
import sparkles.build_primitives.fileset.value : Fileset, Filesets;

/// The rights a fileset root needs: look up, list and stat.
enum Rights filesetRights = cast(Rights)(Rights.lookup | Rights.list | Rights.stat);

/// The bytes of the longest link target the driver reads.
enum size_t linkTargetRoom = 4096;

/// The result of a resolution: nothing, or why it failed.
alias ResolutionResult = Expected!(void, ResolutionError, NoGcHook);

/**
Performs a batch's requests one after another.

Every executor also runs a scheme's own work (FSS4): `spawn(work)` starts
it under the executor's admission budget (FSS6), and `join` returns once all
of it has run (FSS7). Here both are immediate.

An executor whose budget can refuse work (an `acquire` interrupted, or a
budget closed) says so through an optional `bool refused()`: the resolution
then ends with `notAdmitted`, never with a request left unanswered or a
scheme's work silently dropped.
*/
struct InlineExecutor
{
    /// Calls `perform(i)` for each request `i` of `batch`.
    void run(Perform)(scope const(Request)[] batch, scope Perform perform)
    {
        foreach (i; 0 .. batch.length)
            perform(i);
    }

    /// Runs `work` now.
    void spawn(Work)(scope Work work)
    {
        work();
    }

    /// Returns: nothing spawned is left running.
    void join()
    {
    }
}

/// Whether `exec` refused work its budget did not admit: its optional
/// `refused` primitive, `false` for an executor without one.
bool refusedWork(Exec)(ref Exec exec)
{
    static if (__traits(hasMember, Exec, "refused"))
        return exec.refused;
    else
        return false;
}

/// The error a resolution whose executor refused work ends with.
enum ResolutionError notAdmittedError = ResolutionError(ResolutionErrorCode.notAdmitted,
    RequestKind.init, "the executor's budget refused work: interrupted, or the budget closed");

/**
Answers one resolution's requests on the directory handles beneath one root.
Move-only; it allocates its handle table when made.
*/
struct FilesetDriver(V, Rights R)
if (isVfs!V && hasRights(R, filesetRights))
{
    @disable this(this);

    private Dir!(V, R)[] handles;

    /// A driver with room for `frames` directories in progress.
    this(uint frames) @trusted nothrow @nogc
    {
        import core.lifetime : emplace;
        import core.memory : pureMalloc;
        import core.exception : onOutOfMemoryError;

        auto p = cast(Dir!(V, R)*) pureMalloc(frames * Dir!(V, R).sizeof);
        if (p is null)
            onOutOfMemoryError();
        handles = p[0 .. frames];
        foreach (ref h; handles)
            emplace(&h);
    }

    ~this() @trusted
    {
        import core.memory : pureFree;

        foreach (ref h; handles)
            destroy(h);
        pureFree(handles.ptr);
        handles = null;
    }

    /// Performs request `i` of `m`'s batch beneath `root`, and answers it.
    void perform(ref Resolution m, DirRef!(V, R) root, size_t i)
    {
        const req = m.batch[i];
        const index = cast(uint) i;
        final switch (req.kind)
        {
            case RequestKind.readDir:
                // `walk`, not `openDir`: it applies the root's policy to the
                // one name, so a link is followed only where the policy says
                // and a mount boundary is refused unless it allows crossing.
                auto opened = req.dir == noDir
                    ? root.walk(req.name)
                    : handles[req.dir].walk(req.name);
                // A link whose target climbs out of its own directory, as
                // `a/link -> ../b` does, escapes the walk from that directory
                // and may still stay beneath the root: walking its whole
                // path from the root decides (FSD6).
                if (opened.hasError && opened.error.kind == ErrorKind.escapesRoot
                    && req.throughLink && req.path.length)
                    opened = root.walk(req.path);
                if (opened.hasError)
                    return m.failed(index, opened.error.kind);
                if (req.mask & StatMask.identity)
                {
                    // Under `symlinks = beneath`: what tells a link back to
                    // an ancestor (D6).
                    auto st = opened.value.stat(StatMask.identity);
                    if (st.hasError)
                        return m.failed(index, st.error.kind);
                    m.identified(index, st.value.device, st.value.inode);
                }
                auto listing = opened.value.list();
                if (listing.hasError)
                    return m.failed(index, listing.error.kind);
                for (;;)
                {
                    auto more = listing.value.next();
                    if (more.hasError)
                        return m.failed(index, more.error.kind);
                    if (!more.value)
                        break;
                    const e = listing.value.front;
                    m.entry(index, e.name, e.kind);
                }
                handles[req.target] = move(opened.value);
                return m.listed(index);
            case RequestKind.stat:
                auto st = handles[req.dir].statAt(req.name, req.mask);
                if (st.hasError)
                    return m.failed(index, st.error.kind);
                return m.statted(index, st.value);
            case RequestKind.readFile:
                // A `.gitignore` (FSI): a root opened without read rights
                // cannot satisfy a `gitignored` fileset (FSM2).
                static if (hasRights(R, Rights.read))
                    return readFile(m, root, req, index);
                else
                    return m.failed(index, ErrorKind.unsupported);
            case RequestKind.readlink:
                // `readlinkAt` on the link's own directory never follows
                // it (FSO2).
                char[linkTargetRoom] buffer = void;
                auto target = handles[req.dir].readlinkAt(req.name, buffer[]);
                if (target.hasError)
                    return m.failed(index, target.error.kind);
                return m.linkRead(index, target.value);
        }
    }

    static if (hasRights(R, Rights.read))
    {
        // Reads the file `req` names into the machine's room.
        private void readFile(ref Resolution m, DirRef!(V, R) root, in Request req, uint index)
        {
            import sparkles.base.vfs.types : OpenMode;

            if (req.dir != noDir)
                return readInto(m, handles[req.dir].openFile!(OpenMode.read)(req.name), index);
            // A path beneath the fileset root: walk to its directory.
            size_t slash = req.name.length;
            while (slash > 0 && req.name[slash - 1] != '/')
                --slash;
            if (slash == 0)
                return readInto(m, root.openFile!(OpenMode.read)(req.name), index);
            auto dir = root.walk(req.name[0 .. slash - 1]);
            if (dir.hasError)
                return m.failed(index, dir.error.kind);
            return readInto(m, dir.value.openFile!(OpenMode.read)(req.name[slash .. $]), index);
        }

        private void readInto(F)(ref Resolution m, F opened, uint index)
        {
            if (opened.hasError)
                return m.failed(index, opened.error.kind);
            auto bytes = cast(ubyte[]) m.fileRoom;
            size_t n;
            while (n < bytes.length)
            {
                auto r = opened.value.read(bytes[n .. $]);
                if (r.hasError)
                    return m.failed(index, r.error.kind);
                if (r.value == 0)
                    break;
                n += r.value;
            }
            bool whole = true;
            if (n == bytes.length)
            {
                // Full: one more byte says whether the file was larger.
                ubyte[1] probe;
                auto r = opened.value.read(probe[]);
                if (r.hasError)
                    return m.failed(index, r.error.kind);
                whole = r.value == 0;
            }
            m.fileRead(index, n, whole);
        }
    }

    /// The handle of directory `id`, held until it is retired.
    DirRef!(V, R) borrowDir(uint id) return
        => handles[id].borrow;

    /// Closes the handle of directory `id`.
    void retire(uint id)
    {
        if (id != noDir && id < handles.length)
            handles[id] = Dir!(V, R).init;
    }
}

/**
Resolves `f` beneath `root` into `sink`, running each batch on `exec`.
`followLinks` must say whether `root`'s policy follows links beneath it
(FSD6). `budget` bounds the work of one machine step (FSM6).
*/
ResolutionResult resolve(V, Rights R, Sink)(DirRef!(V, R) root, ref const Filesets sets,
    Fileset f, ref Sink sink, ResolutionLimits limits = ResolutionLimits.init, size_t budget = 4096)
{
    InlineExecutor exec;
    return resolveWith(root, sets, f, sink, exec, limits, budget);
}

/// ditto, running each batch on `exec`.
ResolutionResult resolveWith(V, Rights R, Sink, Exec)(DirRef!(V, R) root, ref const Filesets sets,
    Fileset f, ref Sink sink, ref Exec exec, ResolutionLimits limits = ResolutionLimits.init,
    size_t budget = 4096)
{
    import sparkles.base.vfs.types : SymlinkPolicy;

    const followLinks = root.policy.symlinks == SymlinkPolicy.beneath;
    // A sink that can hear which `.gitignore` rule decided an entry is told
    // (FSI3).
    enum traceIgnores = __traits(hasMember, Sink, "ignoreDecision");
    auto m = Resolution(sets, f, limits, followLinks, traceIgnores);
    auto driver = FilesetDriver!(V, R)(limits.maxFrames);
    auto cursor = m.start();
    for (;;)
    {
        StepKind kind;
        if (!m.step(sets, cursor, budget, kind))
            return err!(void, NoGcHook)(m.error);
        driver.retire(m.retired);
        final switch (kind)
        {
            case StepKind.needIO:
                exec.run(m.batch, (size_t i) { driver.perform(m, root, i); });
                if (refusedWork(exec))
                    return err!(void, NoGcHook)(notAdmittedError);
                break;
            case StepKind.unit:
                sink.directory(m.unitPath, m.unitMembers, m.unitEmpty);
                break;
            case StepKind.incomplete:
                sink.incomplete(m.incompletePath, m.incompleteKind);
                break;
            case StepKind.ignoreDecision:
                static if (traceIgnores)
                    sink.ignoreDecision(m.decisionPath, m.decisionIsDir, m.decisionExcluded,
                        m.decisionSource, m.decisionLine, m.decisionPattern);
                break;
            case StepKind.budget:
            case StepKind.leave: // a sink declares no shape, so never hears one
                break;
            case StepKind.done:
                static if (__traits(hasMember, Sink, "ignoreRulesSkipped"))
                    sink.ignoreRulesSkipped(m.ignoreSkippedRules);
                return ok!(ResolutionError, NoGcHook)();
        }
    }
}

/// A sink collecting member paths, empty directories and incomplete entries,
/// each in the order the resolution reported them.
struct PathCollector
{
    string[] members;     /// relative to the fileset root
    string[] emptyDirs;   /// FSV4
    string[] unreadable;  /// `path: kind` of each incomplete entry, FSE2
    uint skippedIgnoreRules; /// `.gitignore` rule lines that did not apply (A15)

    /// Receives a resolved directory.
    void directory(Members)(scope const(char)[] path, scope Members names, bool empty)
    {
        foreach (name; names)
            members ~= path.length ? (path ~ "/" ~ name).idup : name.idup;
        if (empty)
            emptyDirs ~= path.idup;
    }

    /// Receives an entry that could not be read.
    void incomplete(scope const(char)[] path, ErrorKind kind) @safe
    {
        import std.conv : to;

        unreadable ~= (path ~ ": " ~ kind.to!string).idup;
    }

    /// Receives the count of `.gitignore` rule lines that did not apply.
    void ignoreRulesSkipped(uint count) @safe pure nothrow @nogc
    {
        skippedIgnoreRules = count;
    }

    /// One text holding everything collected, for byte comparison.
    string transcript() const @safe
    {
        import std.array : join;

        return "members:\n" ~ members.join("\n") ~ "\nempty:\n" ~ emptyDirs.join("\n")
            ~ "\nincomplete:\n" ~ unreadable.join("\n") ~ "\n";
    }
}
