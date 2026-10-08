module sparkles.test_utils.tmpfs;

@safe:

/**
A scratch directory for a test, removed when the instance goes out of scope.

There are two ways to get one, and the difference is who owns the directory:

$(LIST
    * $(LREF create) makes a fresh, uniquely named directory and $(B owns) it:
    the whole tree — files written through this instance or behind its back,
    subdirectories, everything — is removed with the instance. This is what a
    test wants almost every time.
    * $(LREF share) attaches to a directory that already exists and $(B does
    not) own it: only the files this instance wrote are removed, and the
    directory outlives it. This is for a test that deliberately has two
    fixtures over one tree, or one that must not delete what another made.
)

Ownership is decided by which constructor ran, never by what a later call
happened to find on disk — so it cannot be forgotten, and a test that writes
into `dir()` through the code under test rather than through this fixture
still gets its tree cleaned up.

One instance is not thread-safe: `writeFileAt` appends to its file list and
the destructor reads it. That is the intended shape — one fixture per test,
used from the test's own thread — and `create` itself is safe to call
concurrently. Sharing a single instance across threads needs the caller's own
synchronization.

On POSIX, fixture writers are close-on-exec from the instant they open.
An unrelated child executing concurrently cannot retain a writer after its
exec and keep an executable fixture `ETXTBSY` after the parent's write has
completed. This applies to both `writeFile` and `writeFileAt`.

Removal is best effort and never throws. A destructor that throws during
unwinding replaces the assertion that actually failed with a cleanup error,
and on Windows that is not hypothetical — git leaves read-only objects behind
that make recursive removal fail.
*/
struct TmpFS
{
    import sparkles.base.io.errors : ErrorKind, IoError;
    import sparkles.base.vfs : Dir, OpenMode, ResolvePolicy, Rights, SymlinkPolicy,
        ambientAuthority, openRoot;
    import sparkles.event_horizon.sys : BlockingVfs;
    import std.file : tempDir;
    import std.path : buildPath;

    enum uuid = 0;

    private alias Scratch = Dir!(BlockingVfs, Rights.all);

    // Test code is trusted, so links inside the fixture are followed as long
    // as they stay in it; `..` is still refused, which is what turns a typo
    // into an assertion rather than a write outside the tree.
    private enum policy = ResolvePolicy(symlinks: SymlinkPolicy.beneath, crossMounts: true);

    private string root;
    private string[] files;
    private string[] relativeFiles;
    private bool ownsDir;
    // The backend lives on the heap: `Dir` points at it, and `create` moves
    // the fixture out of the frame that made it.
    private BlockingVfs* vfs;
    private Scratch scratch;
    // The directory holding `root`, kept open by an owning fixture so that
    // removal names the directory it created, wherever the path now leads.
    private Scratch parent;
    private string leaf;

    @disable this();

    // A destructor plus value semantics would remove the same tree twice.
    // `create` returns by value, which is a move, so nothing legitimate needs
    // a copy.
    @disable this(this);

    const(string)[] createdFiles() const
    {
        return files;
    }

    private this(string root, BlockingVfs* vfs, Scratch scratch) nothrow
    {
        import core.lifetime : move;

        this.root = root;
        this.vfs = vfs;
        this.scratch = move(scratch);
    }

    ~this() nothrow
    {
        if (vfs is null)
            return;

        foreach (rel; relativeFiles)
            removeFile(rel);

        if (!ownsDir)
            return;

        // Close first: Windows will not remove a directory with an open
        // handle on it unless every opener shared delete access.
        scratch.close();
        // The backend clears Windows' read-only attribute itself (VFN13),
        // which git sets on every object it writes.
        parent.removeTree(leaf);
    }

    private void removeFile(string rel) nothrow
    {
        import std.path : baseName, dirName;

        const dir = rel.dirName;
        if (dir == ".")
        {
            scratch.unlinkAt(rel);
            return;
        }
        auto d = scratch.walk(dir);
        if (d.hasValue)
            d.value.unlinkAt(rel.baseName);
    }

    /**
    Creates a fresh scratch directory and returns the fixture that owns it.

    `prefix` names the fixture for a human reading `/tmp`; it does not have to
    be unique. The directory actually used appends a random token and a
    process-wide ordinal, which makes three problems impossible rather than
    merely unlikely:

    $(LIST
        * Two concurrent runs of one suite — two worktrees, two agents, a CI
        matrix sharing a runner — cannot share a directory and delete each
        other's fixtures mid-test.
        * A crashed run cannot leave a directory behind for the next run to
        inherit and read a previous run's files from. The token is random
        rather than the process id for exactly this case: pids are recycled,
        so `prefix-<pid>-1` recurs and would collide with the leftovers of a
        run that died holding the same pid.
        * Two fixtures in one test function cannot collide, so neither needs
        an artificial prefix to tell them apart.
    )

    The directory exists when this returns, so a test may hand `dir()` to the
    code under test immediately; whatever that code puts there is removed
    with the fixture.

    `prefix` defaults to the calling function. That is a good name when the
    call sits in the test; from a shared helper it names the helper, which is
    merely less informative — no longer a correctness problem.
    */
    static TmpFS create(string prefix = __FUNCTION__, string basePath = tempDir())
    {
        import core.atomic : atomicOp;
        import core.lifetime : move;
        import std.conv : to;
        import std.file : mkdirRecurse;

        static shared uint counter;
        const ordinal = atomicOp!"+="(counter, 1u);
        const leaf = prefix ~ "-" ~ processToken() ~ "-" ~ ordinal.to!string;

        // `basePath` is the one path the fixture trusts, and the only one it
        // resolves from the process's ambient authority.
        mkdirRecurse(basePath);
        auto vfs = new BlockingVfs;
        auto parent = check(openRoot!(Rights.all)(vfs, basePath, ambientAuthority, policy),
            basePath);
        check(parent.mkdirAt(leaf), leaf);
        auto scratch = check(parent.openDir(leaf), leaf);

        auto tmp = TmpFS(buildPath(basePath, leaf), vfs, move(scratch));
        tmp.ownsDir = true;
        tmp.parent = move(parent);
        tmp.leaf = leaf;
        return tmp;
    }

    /**
    Attaches to `existingDir`, which must already exist, without owning it.

    Files written through the returned instance are removed with it; the
    directory and anything else in it are left alone. Use it when a test
    needs a second fixture over a tree that another fixture — or the test
    itself — owns.
    */
    static TmpFS share(string existingDir)
    in (existingDir.length > 0, "existingDir must not be empty")
    {
        import core.lifetime : move;

        auto vfs = new BlockingVfs;
        auto scratch = openRoot!(Rights.all)(vfs, existingDir, ambientAuthority, policy);
        assert(scratch.hasValue, "share() needs an existing directory: " ~ existingDir);
        return TmpFS(existingDir, vfs, move(scratch.value));
    }

    string writeFile(string contents, uint suffix = uuid)
    {
        import std.conv : to;
        import std.uuid : randomUUID;

        string end = suffix == uuid ? randomUUID.toString() : suffix.to!string;
        return writeFileAt("tmpfs-file#" ~ end, contents);
    }

    /// The scratch directory's path. It exists for as long as the instance
    /// does (and, for $(LREF share), for as long as its real owner keeps it).
    string dir() const pure nothrow @nogc
    {
        return root;
    }

    /// Eight hex digits of randomness, drawn once per *thread* — `static`
    /// inside a function is thread-local in D, which also makes the lazy
    /// initialization race-free without a lock. Uniqueness is unaffected: two
    /// threads drawing different tokens can only separate their fixtures
    /// further.
    private static string processToken() @safe
    {
        import std.uuid : randomUUID;

        static string token;
        if (token.length == 0)
            token = randomUUID.toString()[0 .. 8];
        return token;
    }

    /**
    Creates an empty directory at `relativePath` beneath $(LREF dir),
    including any missing parents, and returns its full path.

    A directory containing no file cannot be brought into being by writing a
    file, and several tests mean exactly that: a `.git` marker, a package
    directory with no recipe in it, a tree whose emptiness is the assertion.
    Removal is covered by the scratch directory's own when the instance owns
    it; a $(LREF share)d instance leaves it behind, as it leaves everything
    it did not write.
    */
    string ensureSubdir(string relativePath)
    in (relativePath.length > 0, "relativePath must not be empty")
    {
        check(scratch.walkAll(relativePath), relativePath);
        return buildPath(root, relativePath);
    }

    /**
    Writes `contents` at `relativePath` beneath $(LREF dir), creating any
    missing parent directories.

    Unlike $(LREF writeFile), the caller chooses the name — which is what a
    test needs when the name is part of the behaviour under test (`.gitignore`,
    `dub.sdl`, `logs/app.log`). `relativePath` must be relative and must not
    contain a `..` component; separators are `/` on every platform.

    The descriptor is close-on-exec from the instant it opens (VFH8), so a
    child that a concurrent thread spawns cannot keep an executable fixture
    `ETXTBSY` after this write has finished.

    Returns: the full path written.
    */
    string writeFileAt(string relativePath, string contents)
    in (relativePath.length > 0, "relativePath must not be empty")
    {
        import std.path : baseName, dirName;

        const dir = relativePath.dirName;
        if (dir == ".")
            writeContents(scratch, relativePath, contents);
        else
        {
            auto d = check(scratch.walkAll(dir), relativePath);
            writeContents(d, relativePath.baseName, contents);
        }

        const filepath = buildPath(root, relativePath);
        this.files ~= filepath;
        this.relativeFiles ~= relativePath;
        return filepath;
    }

    private static void writeContents(ref Scratch dir, string name, string contents)
    {
        import std.algorithm.comparison : min;
        import std.string : representation;

        auto f = check(dir.openFile!(OpenMode.createOrTruncate)(name), name);
        auto bytes = contents.representation;
        while (bytes.length > 0)
        {
            const n = check(f.write(bytes[0 .. min(bytes.length, size_t(1) << 30)]), name);
            bytes = bytes[n .. $];
        }
        check(f.close(), name);
    }

    /// The value of `r`, or the failure it names. A path that leaves the
    /// fixture is a bug in the test, so it fails as an assertion; anything
    /// else is the environment's, and throws as `std.file` would have.
    private static auto check(R)(auto ref R r, string what)
    {
        import core.lifetime : move;

        if (r.hasError)
        {
            const e = r.error;
            switch (e.kind)
            {
                case ErrorKind.escapesRoot, ErrorKind.dotDotRefused, ErrorKind.invalidName:
                    assert(0, "relativePath must stay beneath the fixture: " ~ what);
                default:
                    throw new TmpFSException(what, e);
            }
        }
        static if (__traits(hasMember, R, "value"))
            return move(r.value);
    }
}

/// A file-system failure inside a $(LREF TmpFS) fixture.
class TmpFSException : Exception
{
    import sparkles.base.io.errors : IoError;

    /// The failure as the capability VFS reported it.
    IoError error;

    this(string what, IoError error, string file = __FILE__, size_t line = __LINE__) @safe
    {
        import std.conv : text;

        this.error = error;
        super(text(what, ": ", error.kind, " in ", error.op,
            error.code ? text(" (", error.code, ")") : "",
            error.context.length ? ": " ~ error.context : ""), file, line);
    }
}

///
unittest
{
    import std.file : exists, isFile, readText;

    string path;

    {
        auto tmpfs = TmpFS.create();
        path = tmpfs.writeFile("Sample text");

        assert(path.exists && path.isFile);
        assert(path.readText == "Sample text");
    }

    assert(!path.exists);
}

///
unittest
{
    import std.file : exists, isFile, readText;

    const(string)[] createdFiles;

    {
        auto tmpfs = TmpFS.create();
        createdFiles = tmpfs.createdFiles;
        assert(createdFiles.length == 0);
        tmpfs.writeFile("file 1");
        tmpfs.writeFile("file 2");
        tmpfs.writeFile("file 3");

        createdFiles = tmpfs.createdFiles;
        assert(createdFiles.length == 3);

        foreach (f; createdFiles)
            assert(f.exists && f.isFile);
    }

    foreach (f; createdFiles)
        assert(!f.exists);
}

/// `create` owns its directory from the start: something written into it
/// behind the fixture's back — by the code under test, say — is removed with
/// the fixture all the same.
@("testUtils.tmpFS.createOwnsTheDirectoryImmediately")
@safe unittest
{
    import std.file : exists, isDir, write;
    import std.path : buildPath;

    string root, stray;

    {
        auto tmp = TmpFS.create();
        root = tmp.dir();
        assert(root.exists && root.isDir, "the directory exists on return");

        stray = buildPath(root, "written-by-the-code-under-test.txt");
        write(stray, "x");
    }

    assert(!stray.exists && !root.exists, "owned, so the whole tree goes");
}

/// `writeFileAt` names the file, creates missing parents, and the whole
/// scratch directory — nested directories included — is gone afterwards.
@("testUtils.tmpFS.writeFileAtCreatesParentsAndCleansTheTree")
@safe unittest
{
    import std.file : exists, readText;
    import std.path : buildPath;

    string root, nested;

    {
        auto tmp = TmpFS.create();
        root = tmp.dir();

        const flat = tmp.writeFileAt(".gitignore", "*.o\n");
        nested = tmp.writeFileAt("logs/deeper/app.log", "entry\n");

        assert(flat == buildPath(root, ".gitignore"));
        assert(flat.readText == "*.o\n");
        assert(nested.exists && nested.readText == "entry\n");
    }

    // The instance owns the directory, so it removes the whole tree — the
    // intermediate `logs/deeper` included, which the file list alone would
    // have leaked.
    assert(!nested.exists);
    assert(!root.exists);
}

/// A shared instance removes what it wrote and nothing else: the directory
/// and its owner's files survive it.
@("testUtils.tmpFS.shareDoesNotRemoveTheDirectory")
@safe unittest
{
    import std.file : exists;

    auto owner = TmpFS.create();
    const ownersFile = owner.writeFileAt("owners.txt", "keep");
    string borrowed;

    {
        auto borrower = TmpFS.share(owner.dir());
        borrowed = borrower.writeFileAt("inner.txt", "x");
        assert(borrowed.exists);
    }

    assert(owner.dir().exists, "a shared directory must survive the borrower");
    assert(ownersFile.exists, "and so must what its owner wrote");
    assert(!borrowed.exists, "only the borrower's own file is gone");
}

/// Two fixtures created with the same name get different directories, so a
/// second concurrent run — or a second fixture in one test — cannot collide
/// with the first.
@("testUtils.tmpFS.namesAreUniquePerInstance")
@safe unittest
{
    import std.file : exists;

    auto first = TmpFS.create("same-name");
    auto second = TmpFS.create("same-name");

    assert(first.dir() != second.dir(), "fixture directories must not collide");
    assert(first.dir().exists && second.dir().exists);
}

/// `ensureSubdir` expresses the thing a file write cannot: a directory whose
/// emptiness is the point.
@("testUtils.tmpFS.ensureSubdirMakesAnEmptyDirectory")
@safe unittest
{
    import std.file : dirEntries, exists, isDir, SpanMode;

    string marker;

    {
        auto tmp = TmpFS.create();
        marker = tmp.ensureSubdir("repo/.git");

        assert(marker.exists && marker.isDir);
        assert(dirEntries(marker, SpanMode.shallow).empty, "must be empty");
    }

    assert(!marker.exists, "the scratch tree removes it");
}

/// A relative path that climbs out of the fixture is refused, because the
/// fixture would otherwise write — and later delete — a file outside the tree
/// it owns.
@("testUtils.tmpFS.refusesAPathThatLeavesTheFixture")
@system unittest
{
    import core.exception : AssertError;
    import std.exception : assertThrown;
    import std.file : exists;

    auto tmp = TmpFS.create();

    assertThrown!AssertError(tmp.writeFileAt("../escaped.txt", "x"));
    assertThrown!AssertError(tmp.writeFileAt("a/../../escaped.txt", "x"));
    assertThrown!AssertError(tmp.ensureSubdir("../escaped"));

    // A `..` inside a *name* is not a climb, and stays allowed.
    const ok = tmp.writeFileAt("a..b/c..d.txt", "x");
    assert(ok.exists);
}

/// `share` refuses a directory that is not there: attaching to nothing would
/// silently turn every later write into a failure somewhere else.
@("testUtils.tmpFS.shareRequiresAnExistingDirectory")
@system unittest
{
    import core.exception : AssertError;
    import std.exception : assertThrown;
    import std.path : buildPath;

    auto tmp = TmpFS.create();
    assertThrown!AssertError(TmpFS.share(buildPath(tmp.dir(), "absent")));
}

version (linux)
{
    @("testUtils.tmpFS.writerDoesNotLeakIntoConcurrentExec")
    @system unittest
    {
        import core.stdc.errno : EAGAIN, EINTR, errno;
        import core.sys.linux.sys.eventfd : EFD_CLOEXEC, eventfd;
        import core.sys.posix.fcntl : O_CLOEXEC, O_NONBLOCK, O_RDONLY, fcntl, open;
        import core.sys.posix.poll : POLLHUP, POLLIN, poll, pollfd;
        import core.sys.posix.sys.stat : mkfifo;
        import core.sys.posix.unistd : close, read, write;
        import core.thread : Thread;
        import std.algorithm.comparison : min;
        import std.array : replicate;
        import std.path : buildPath;
        import std.process : Config, execute;
        import std.string : toStringz;

        auto tmp = TmpFS.create("fixture-writer-inheritance");
        const fifo = buildPath(tmp.dir, "held-writer");
        assert(mkfifo(fifo.toStringz, 384 /* 0o600 */) == 0);
        const reader = open(fifo.toStringz, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
        assert(reader >= 0);
        scope (exit) close(reader);
        const finished = eventfd(0, EFD_CLOEXEC);
        assert(finished >= 0);
        scope (exit) close(finished);

        // Linux's F_GETPIPE_SZ is not declared by druntime. Twice the actual
        // capacity blocks the writer until we drain it: no sleeps or races
        // are needed to keep a real writeFileAt descriptor open during exec.
        enum F_GETPIPE_SZ = 1032;
        const capacity = fcntl(reader, F_GETPIPE_SZ);
        assert(capacity > 0);
        immutable contents = "x".replicate(2 * cast(size_t) capacity);

        Throwable writerFailure;
        auto writer = new Thread(() {
            scope (exit)
            {
                ulong one = 1;
                ptrdiff_t sent;
                do sent = write(finished, &one, one.sizeof);
                while (sent < 0 && errno == EINTR);
                assert(sent == one.sizeof);
            }
            try tmp.writeFileAt("held-writer", contents);
            catch (Throwable failure) writerFailure = failure;
        });
        bool awaitWriterData()
        {
            pollfd[2] ready = [
                pollfd(reader, POLLIN, 0), pollfd(finished, POLLIN, 0)];
            int rc;
            do rc = poll(ready.ptr, ready.length, -1);
            while (rc < 0 && errno == EINTR);
            assert(rc > 0);
            if (ready[0].revents & POLLIN)
                return true;
            if (ready[1].revents & POLLIN)
                return false;
            // The writer may close the FIFO before recording its path and
            // signalling completion. Wait for that signal, not a HUP loop.
            assert(ready[0].revents & POLLHUP);
            do rc = poll(&ready[1], 1, -1);
            while (rc < 0 && errno == EINTR);
            assert(rc == 1 && (ready[1].revents & POLLIN));
            return false;
        }
        size_t consumed;
        bool joined;
        void finishWriter()
        {
            ubyte[4096] buffer;
            while (consumed < contents.length)
            {
                const count = read(reader, buffer.ptr,
                    min(buffer.length, contents.length - consumed));
                if (count > 0)
                    consumed += count;
                else if (count < 0 && errno == EINTR)
                    continue;
                else
                {
                    assert(count == 0 || (count < 0 && errno == EAGAIN));
                    // An early writer exception also signals completion,
                    // so cleanup cannot wait forever for missing payload.
                    if (!awaitWriterData())
                        break;
                }
            }
            writer.join();
            joined = true;
        }
        writer.start();
        scope (exit) if (!joined) finishWriter();

        // An open FIFO with no writer can return EOF even in blocking mode.
        // Readability, rather than a first-byte read, proves the writer has
        // connected and is blocked on more than the FIFO's capacity.
        if (!awaitWriterData())
        {
            finishWriter();
            if (writerFailure !is null)
                throw writerFailure;
            assert(0, "fixture writer completed before filling the FIFO");
        }
        // The reader is close-on-exec, so any matching fd in this child is
        // the fixture writer. Explicit inheritance models a normal POSIX
        // spawn rather than Phobos's default closing of unrelated handles.
        auto child = execute(["/bin/sh", "-c",
            "for fd in /proc/self/fd/*; do"
            ~ " if [ \"$fd\" -ef \"$1\" ]; then printf inherited; exit 1; fi;"
            ~ " done; printf isolated", "descriptor-probe", fifo],
            null, Config.inheritFDs);
        finishWriter();
        if (writerFailure !is null)
            throw writerFailure;
        assert(consumed == contents.length, "fixture write must deliver every byte");
        assert(child.status == 0 && child.output == "isolated",
            "a concurrent exec must not inherit the fixture writer");
    }
}
