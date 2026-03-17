/**
 * Directory traversal primitives with optional hook capabilities.
 */
module sparkles.build_primitives.dir_walk;

import sparkles.build_primitives.gitignore : GitIgnore;

@safe:

/// Hook capability: `bool enterDir(const(char)[] path)`.
enum bool hasEnterDir(Hook) = is(typeof({
    Hook hook = Hook.init;
    bool keep = hook.enterDir("src");
}));

/// Hook capability: `bool includeFile(const(char)[] path)`.
enum bool hasIncludeFile(Hook) = is(typeof({
    Hook hook = Hook.init;
    bool keep = hook.includeFile("src/main.d");
}));

/// Hook capability: `void onFile(const(char)[] path)`.
enum bool hasOnFile(Hook) = is(typeof({
    Hook hook = Hook.init;
    hook.onFile("src/main.d");
}));

/// Baseline hook for traversal without custom behavior.
struct NoopWalkHook {}

/// Walks all files under `root` in lexical order.
void walkDir(Hook = NoopWalkHook)(string root, auto ref Hook hook = Hook.init)
{
    import std.exception : enforce;
    import std.file : exists, isDir;

    enforce(root.exists, "walkDir root does not exist: " ~ root);
    enforce(root.isDir, "walkDir root is not a directory: " ~ root);

    walkDirImpl(root, "", hook);
}

/// Eagerly collects accepted files into an input range wrapper.
DirWalkerRange!Hook dirEntriesFilter(Hook = NoopWalkHook)(string root, Hook hook = Hook.init)
{
    return DirWalkerRange!Hook(root, hook);
}

/// Repository-aware filter using `.gitignore` rules.
struct GitRepositoryFilter
{
    const GitIgnore ignore;

    bool enterDir(const(char)[] relativePath) const
    {
        return !isGitMetadataPath(relativePath) && !ignore.isIgnored(relativePath, true);
    }

    bool includeFile(const(char)[] relativePath) const
    {
        return !isGitMetadataPath(relativePath) && !ignore.isIgnored(relativePath, false);
    }

private:

    bool isGitMetadataPath(const(char)[] relativePath) const pure nothrow
    {
        import std.algorithm.searching : startsWith;

        return relativePath == ".git" || relativePath.startsWith(".git/");
    }
}

/// Reads `.gitignore` from `root`.
GitIgnore readRepositoryGitIgnore(string root)
{
    import std.path : buildPath;

    return GitIgnore.fromFile(buildPath(root, ".gitignore"));
}

/// Traverses `root` with `.gitignore`-aware filtering.
DirWalkerRange!GitRepositoryFilter walkGitRepository(string root, GitIgnore gitIgnore)
{
    return dirEntriesFilter(root, GitRepositoryFilter(ignore: gitIgnore));
}

/// Traverses `root` using `.gitignore` loaded from disk.
DirWalkerRange!GitRepositoryFilter walkGitRepository(string root)
{
    return walkGitRepository(root, readRepositoryGitIgnore(root));
}

/// Input range over collected file paths.
struct DirWalkerRange(Hook = NoopWalkHook)
{
private:

    string[] _files;
    size_t _index;

public:

    this(string root, Hook hook = Hook.init)
    {
        auto collectingHook = CollectingHook!Hook(
            upstream: hook,
        );
        walkDir(root, collectingHook);
        _files = collectingHook.files;
    }

    @property bool empty() const => _index >= _files.length;

    @property string front() const
    in (!empty, "Cannot access front of an empty DirWalkerRange")
    {
        return _files[_index];
    }

    void popFront()
    in (!empty, "Cannot pop from an empty DirWalkerRange")
    {
        _index++;
    }
}

private:

struct CollectingHook(Hook)
{
    Hook upstream;
    string[] files;

    bool enterDir(const(char)[] relativePath)
    {
        static if (hasEnterDir!Hook)
            return upstream.enterDir(relativePath);
        return true;
    }

    bool includeFile(const(char)[] relativePath)
    {
        static if (hasIncludeFile!Hook)
            return upstream.includeFile(relativePath);
        return true;
    }

    void onFile(const(char)[] relativePath)
    {
        files ~= relativePath.idup;

        static if (hasOnFile!Hook)
            upstream.onFile(relativePath);
    }
}

void walkDirImpl(Hook)(string absolutePath, string relativePath, ref Hook hook)
{
    import std.algorithm.sorting : sort;
    import std.array : array;
    import std.file : SpanMode, dirEntries;
    import std.path : baseName;

    auto entries = absolutePath.dirEntries(SpanMode.shallow).array;
    entries.sort!((a, b) => a.name.baseName < b.name.baseName);

    foreach (entry; entries)
    {
        const name = entry.name.baseName;
        const relPath = relativePath.length == 0
            ? name
            : relativePath ~ "/" ~ name;

        if (entry.isDir)
        {
            bool shouldEnter = true;
            static if (hasEnterDir!Hook)
                shouldEnter = hook.enterDir(relPath);

            if (shouldEnter)
                walkDirImpl(entry.name, relPath, hook);

            continue;
        }

        bool shouldInclude = true;
        static if (hasIncludeFile!Hook)
            shouldInclude = hook.includeFile(relPath);

        if (!shouldInclude)
            continue;

        static if (hasOnFile!Hook)
            hook.onFile(relPath);
    }
}

@("buildPrimitives.dirWalk.hookFiltering")
@safe unittest
{
    import std.algorithm.sorting : sort;
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    struct FilteringHook
    {
        string[] seen;

        bool enterDir(const(char)[] relativePath)
        {
            return relativePath != "skip";
        }

        bool includeFile(const(char)[] relativePath)
        {
            import std.algorithm.searching : endsWith;
            return !relativePath.endsWith(".tmp");
        }

        void onFile(const(char)[] relativePath)
        {
            seen ~= relativePath.idup;
        }
    }

    const root = buildPath(tempDir(), "walkDir-hookFiltering-" ~ randomUUID.toString);
    mkdirRecurse(buildPath(root, "src"));
    mkdirRecurse(buildPath(root, "skip"));
    write(buildPath(root, "src", "main.d"), "module main;");
    write(buildPath(root, "src", "notes.tmp"), "temp");
    write(buildPath(root, "skip", "secret.d"), "ignored");

    scope (exit)
        rmdirRecurse(root);

    auto hook = FilteringHook.init;
    walkDir(root, hook);

    hook.seen.sort;
    assert(hook.seen == ["src/main.d"]);
}

@("buildPrimitives.dirWalk.walkGitRepository")
@safe unittest
{
    import std.algorithm.sorting : sort;
    import std.array : array;
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    const root = buildPath(tempDir(), "walkGitRepository-" ~ randomUUID.toString);
    mkdirRecurse(buildPath(root, "src"));
    mkdirRecurse(buildPath(root, "build"));
    mkdirRecurse(buildPath(root, ".git"));

    write(buildPath(root, ".gitignore"), "build/\n*.tmp\n!keep.tmp\n");
    write(buildPath(root, "README.md"), "README\n");
    write(buildPath(root, "src", "main.d"), "module main;\n");
    write(buildPath(root, "src", "notes.tmp"), "temp\n");
    write(buildPath(root, "src", "keep.tmp"), "keep\n");
    write(buildPath(root, "build", "artifact.txt"), "ignored\n");
    write(buildPath(root, ".git", "config"), "[core]\n");

    scope (exit)
        rmdirRecurse(root);

    auto files = walkGitRepository(root).array;
    files.sort;

    assert(files == [
        ".gitignore",
        "README.md",
        "src/keep.tmp",
        "src/main.d",
    ]);
}
