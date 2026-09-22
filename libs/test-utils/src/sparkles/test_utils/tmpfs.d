module sparkles.test_utils.tmpfs;

@safe:

/**
A scratch directory for a test, removed when the instance goes out of scope.

Cleanup removes only what this instance made: the files it wrote, and the
scratch directory itself when `ensureDir` was the thing that created it. A
directory that already existed is left alone, so two instances sharing a
`prefix` cannot delete each other's work.

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
    Creates a fixture rooted at `basePath/prefix`.

    `prefix` defaults to the *calling* function, which gives each test its own
    directory. Take care when calling this from a shared helper: every test
    routed through one helper would then share one directory, and the test
    runner executes tests in parallel. Pass an explicit, unique `prefix` in
    that case.
    */
    static TmpFS create(string prefix = __FUNCTION__, string basePath = tempDir())
    {
        auto result = TmpFS(prefix, basePath);
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
