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

Removal is best effort and never throws. A destructor that throws during
unwinding replaces the assertion that actually failed with a cleanup error,
and on Windows that is not hypothetical — git leaves read-only objects behind
that make recursive removal fail.
*/
struct TmpFS
{
    import std.file : mkdirRecurse, tempDir, remove, writeFile = write;
    import std.path : buildPath;

    enum uuid = 0;

    private string root;
    private string[] files;
    private bool ownsDir;

    @disable this();

    // A destructor plus value semantics would remove the same tree twice.
    // `create` returns by value, which is a move, so nothing legitimate needs
    // a copy.
    @disable this(this);

    const(string)[] createdFiles() const
    {
        return files;
    }

    private this(string root, bool ownsDir) pure nothrow @nogc
    {
        this.root = root;
        this.ownsDir = ownsDir;
    }

    ~this() nothrow
    {
        import std.file : rmdirRecurse;

        foreach (f; files)
            try
                remove(f);
            catch (Exception)
            {
            }

        if (!ownsDir)
            return;

        try
        {
            clearReadOnly(root);
            rmdirRecurse(root);
        }
        catch (Exception)
        {
        }
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
        import std.conv : to;

        static shared uint counter;
        const ordinal = atomicOp!"+="(counter, 1u);

        const root = buildPath(basePath,
            prefix ~ "-" ~ processToken() ~ "-" ~ ordinal.to!string);
        mkdirRecurse(root);
        return TmpFS(root, true);
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
        import std.file : exists, isDir;

        assert(existingDir.exists && existingDir.isDir,
            "share() needs an existing directory: " ~ existingDir);
        return TmpFS(existingDir, false);
    }

    string writeFile(string contents, uint suffix = uuid)
    {
        import std.conv : to;
        import std.uuid : randomUUID;

        string end = suffix == uuid ? randomUUID.toString() : suffix.to!string;
        const filepath = buildPath(root, "tmpfs-file#" ~ end);
        writeFile(filepath, contents);
        this.files ~= filepath;
        return filepath;
    }

    /// The scratch directory's path. It exists for as long as the instance
    /// does (and, for $(LREF share), for as long as its real owner keeps it).
    string dir() const pure nothrow @nogc
    {
        return root;
    }

    /// Rejects a relative path that would leave the fixture.
    ///
    /// Without this, `writeFileAt("../x")` writes *outside* the scratch tree —
    /// and, because tracked files are removed individually, then deletes that
    /// outside file when the fixture goes out of scope. A mistyped `..` would
    /// overwrite and then remove a real file.
    ///
    /// This is a component check rather than `openat2(RESOLVE_BENEATH)` on
    /// purpose: `openat2` is Linux 5.6+, and this helper runs on the Windows
    /// and macOS legs too. The kernel guarantee is worth having where the
    /// threat is an adversarial symlink race; here the threat is a typo in
    /// trusted test code, which a portable check answers completely.
    private static void enforceBeneath(string relativePath) @safe pure
    {
        import std.algorithm.iteration : splitter;
        import std.algorithm.searching : canFind;
        import std.path : isAbsolute;

        assert(!relativePath.isAbsolute,
            "relativePath must be relative: " ~ relativePath);
        assert(!relativePath.splitter('/').canFind("..")
            && !relativePath.splitter('\\').canFind(".."),
            "relativePath must stay beneath the fixture: " ~ relativePath);
    }

    /// On Windows a read-only file refuses deletion outright, and git marks
    /// every object it writes read-only — so a fixture that ran `git commit`
    /// would otherwise outlive itself. Elsewhere the attribute has no such
    /// meaning and the walk is skipped.
    private static void clearReadOnly(string root)
    {
        version (Windows)
        {
            import core.sys.windows.winnt : FILE_ATTRIBUTE_READONLY;
            import std.file : dirEntries, getAttributes, setAttributes, SpanMode;

            foreach (entry; dirEntries(root, SpanMode.depth, false))
            {
                const attrs = getAttributes(entry.name);
                if (attrs & FILE_ATTRIBUTE_READONLY)
                    setAttributes(entry.name, attrs & ~FILE_ATTRIBUTE_READONLY);
            }
        }
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
        enforceBeneath(relativePath);

        const path = buildPath(root, relativePath);
        mkdirRecurse(path);
        return path;
    }

    /**
    Writes `contents` at `relativePath` beneath $(LREF dir), creating any
    missing parent directories.

    Unlike $(LREF writeFile), the caller chooses the name — which is what a
    test needs when the name is part of the behaviour under test (`.gitignore`,
    `dub.sdl`, `logs/app.log`). `relativePath` must be relative; separators may
    be `/` on every platform.

    Returns: the full path written.
    */
    string writeFileAt(string relativePath, string contents)
    in (relativePath.length > 0, "relativePath must not be empty")
    {
        import std.path : dirName;

        enforceBeneath(relativePath);

        const filepath = buildPath(root, relativePath);
        mkdirRecurse(filepath.dirName);
        writeFile(filepath, contents);
        this.files ~= filepath;
        return filepath;
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
