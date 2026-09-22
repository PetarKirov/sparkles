module sparkles.test_utils.tmpfs;

@safe:

/**
A scratch directory for a test, removed when the instance goes out of scope.

Cleanup removes only what this instance made: the files it wrote, and the
scratch directory itself when `ensureDir` was the thing that created it. A
directory that already existed is left alone, so two instances sharing a
`prefix` cannot delete each other's work.

One instance is not thread-safe: `writeFileAt` appends to its file list,
`ensureDir` checks and then sets ownership, and the destructor reads both.
That is the intended shape — one fixture per test, used from the test's own
thread — and `create` itself is safe to call concurrently. Sharing a single
instance across threads needs the caller's own synchronization.

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

    const string basePath;
    const string prefix;

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

    pure nothrow @nogc
    this(string prefix, string basePath)
    {
        this.basePath = basePath;
        this.prefix = prefix;
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
            rmdirRecurse(dir);
        catch (Exception)
        {
        }
    }

    /**
    Creates a fixture rooted at a directory derived from `prefix`.

    `prefix` names the fixture for a human reading `/tmp`; it does not have to
    be unique. The directory actually used appends a random token and a
    process-wide ordinal, which makes three problems impossible rather than
    merely unlikely:

    $(LIST
        * Two concurrent runs of one suite — two worktrees, two agents, a CI
        matrix sharing a runner — cannot share a directory and delete each
        other's fixtures mid-test.
        * A crashed run cannot leave a directory behind for the next run to
        inherit. An inherited directory is one this instance did not create,
        so it would never be cleaned (see the ownership rule above), and a
        test could read a previous run's files. The token is random rather
        than the process id for exactly this case: pids are recycled, so
        `prefix-<pid>-1` recurs and would collide with the leftovers of a run
        that died holding the same pid.
        * Two fixtures in one test function cannot collide, so neither needs
        an artificial prefix to tell them apart.
    )

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

        auto result = TmpFS(
            prefix ~ "-" ~ processToken() ~ "-" ~ ordinal.to!string,
            basePath,
        );
        return result;
    }

    string writeFile(string contents, uint suffix = uuid)
    {
        import std.conv : to;
        import std.uuid : randomUUID;

        ensureDir();
        string end = suffix == uuid ? randomUUID.toString() : suffix.to!string;
        const filepath = buildPath(dir, "tmpfs-file#" ~ end);
        writeFile(filepath, contents);
        this.files ~= filepath;
        return filepath;
    }

    string dir()
    {
        return buildPath(basePath, prefix);
    }

    void ensureDir()
    {
        import std.file : exists;

        if (!dir.exists)
            ownsDir = true;

        mkdirRecurse(dir);
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
    Removal is covered by the scratch directory's own, so nothing is tracked
    here.
    */
    string ensureSubdir(string relativePath)
    in (relativePath.length > 0, "relativePath must not be empty")
    {
        import std.path : isAbsolute;

        assert(!relativePath.isAbsolute, "relativePath must be relative");

        ensureDir();
        const path = buildPath(dir, relativePath);
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
        import std.path : dirName, isAbsolute;

        assert(!relativePath.isAbsolute, "relativePath must be relative");

        ensureDir();
        const filepath = buildPath(dir, relativePath);
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

    // The instance created the directory, so it removes the whole tree —
    // the intermediate `logs/deeper` included, which the file list alone
    // would have leaked.
    assert(!nested.exists);
    assert(!root.exists);
}

/// A directory the instance did not create outlives it: two instances that
/// share a prefix must not delete each other's work.
@("testUtils.tmpFS.doesNotRemoveADirectoryItDidNotCreate")
@safe unittest
{
    import std.file : exists, mkdirRecurse, rmdirRecurse;

    auto outer = TmpFS.create();
    outer.ensureDir();
    const shared_ = outer.dir();
    scope (exit)
        rmdirRecurse(shared_);

    {
        auto inner = TmpFS.create(outer.prefix, outer.basePath);
        inner.writeFileAt("inner.txt", "x");
    }

    assert(shared_.exists, "an inherited directory must survive the borrower");
}

/// Two fixtures created with the same name get different directories, so a
/// second concurrent run — or a second fixture in one test — cannot collide
/// with the first.
@("testUtils.tmpFS.namesAreUniquePerInstance")
@safe unittest
{
    auto first = TmpFS.create("same-name");
    auto second = TmpFS.create("same-name");

    assert(first.dir() != second.dir(), "fixture directories must not collide");

    first.ensureDir();
    second.ensureDir();

    import std.file : exists;

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
