module sparkles.test_utils.tmpfs;

@safe:

struct TmpFS
{
    import std.file : mkdirRecurse, tempDir, remove, writeFile = write;
    import std.path : buildPath;

    enum uuid = 0;

    const string basePath;
    const string prefix;

    private string[] files;

    @disable this();

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

    ~this()
    {
        foreach (f; files)
            remove(f);
    }

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
        mkdirRecurse(dir);
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
