/**
 * Directory traversal primitives with optional hook capabilities.
 */
module sparkles.build_primitives.dir_walk;

import sparkles.build_primitives.gitignore : GitIgnore, GitIgnoreStack;

/// Hook capability: `bool enterDir(const(char)[] path)`.
enum bool hasEnterDir(Hook) = is(typeof({
    Hook hook = Hook.init;
    bool keep = hook.enterDir("src");
}));

/// Hook capability: `void leaveDir(const(char)[] path)` — called after a
/// directory's subtree has been walked (only for directories that were
/// entered, so `enterDir`/`leaveDir` pairs nest like a stack).
enum bool hasLeaveDir(Hook) = is(typeof({
    Hook hook = Hook.init;
    hook.leaveDir("src");
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

/// Walks all files under `root` in lexical order. Symbolic links are reported
/// as files (never followed), matching git's view of symlinks as blobs.
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

/// Repository-aware filter applying nested `.gitignore` rules: the walk
/// root's `.gitignore` seeds the stack, every entered directory contributes
/// its own `.gitignore` (if any) to its subtree, and deeper rules override
/// shallower ones — matching git's precedence. `.git` is always skipped.
struct GitRepositoryFilter
{
    private string root;
    private GitIgnoreStack stack;

    /// `root` is the directory the walk starts from; `rootIgnore` is the
    /// `.gitignore` scope applying at that root.
    this(string root, GitIgnore rootIgnore) @safe pure nothrow
    {
        this.root = root;
        stack.push("", rootIgnore);
    }

    bool enterDir(const(char)[] relativePath) @safe
    {
        import std.path : buildPath;

        if (isGitMetadataPath(relativePath) || stack.isIgnored(relativePath, true))
            return false;

        // A directory's own `.gitignore` governs its contents (never itself).
        const dirPrefix = relativePath.idup;
        stack.push(dirPrefix, GitIgnore.fromFile(buildPath(root, dirPrefix, ".gitignore")));
        return true;
    }

    void leaveDir(const(char)[] relativePath) @safe pure
    {
        stack.pop();
    }

    bool includeFile(const(char)[] relativePath) const @safe pure
    {
        return !isGitMetadataPath(relativePath) && !stack.isIgnored(relativePath, false);
    }

private:

    bool isGitMetadataPath(const(char)[] relativePath) const @safe pure nothrow @nogc
    {
        import std.algorithm.searching : startsWith;

        return relativePath == ".git" || relativePath.startsWith(".git/");
    }
}

/// Reads `.gitignore` from `root`.
GitIgnore readRepositoryGitIgnore(string root) @safe
{
    import std.path : buildPath;

    return GitIgnore.fromFile(buildPath(root, ".gitignore"));
}

/// Traverses `root` with `.gitignore`-aware filtering, seeding the root scope
/// with `gitIgnore` (nested `.gitignore` files are still picked up below it).
DirWalkerRange!GitRepositoryFilter walkGitRepository(string root, GitIgnore gitIgnore) @safe
{
    return dirEntriesFilter(root, GitRepositoryFilter(root, gitIgnore));
}

/// Traverses `root` using the `.gitignore` files found on disk.
DirWalkerRange!GitRepositoryFilter walkGitRepository(string root) @safe
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

    void leaveDir(const(char)[] relativePath)
    {
        static if (hasLeaveDir!Hook)
            upstream.leaveDir(relativePath);
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

        // A symlink is never followed — even when it points at a directory it
        // is reported as a file, the same way git tracks it as a blob.
        if (!entry.isSymlink && entry.isDir)
        {
            bool shouldEnter = true;
            static if (hasEnterDir!Hook)
                shouldEnter = hook.enterDir(relPath);

            if (shouldEnter)
            {
                walkDirImpl(entry.name, relPath, hook);
                static if (hasLeaveDir!Hook)
                    hook.leaveDir(relPath);
            }

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

@("buildPrimitives.dirWalk.nestedGitignore")
@safe unittest
{
    import std.algorithm.sorting : sort;
    import std.array : array;
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    const root = buildPath(tempDir(), "walkGitRepository-nested-" ~ randomUUID.toString);
    mkdirRecurse(buildPath(root, "sub", "nested"));

    write(buildPath(root, ".gitignore"), "*.tmp\n");
    write(buildPath(root, "sub", ".gitignore"), "!keep.tmp\n*.log\n");
    write(buildPath(root, "a.tmp"), "ignored by root\n");
    write(buildPath(root, "a.log"), "kept: sub's rules do not apply here\n");
    write(buildPath(root, "sub", "keep.tmp"), "re-included by sub\n");
    write(buildPath(root, "sub", "other.tmp"), "still ignored by root\n");
    write(buildPath(root, "sub", "b.log"), "ignored by sub\n");
    write(buildPath(root, "sub", "nested", "c.log"), "sub's rules reach the subtree\n");

    scope (exit)
        rmdirRecurse(root);

    auto files = walkGitRepository(root).array;
    files.sort;

    assert(files == [
        ".gitignore",
        "a.log",
        "sub/.gitignore",
        "sub/keep.tmp",
    ]);
}

version (Posix)
@("buildPrimitives.dirWalk.symlinksNotFollowed")
@safe unittest
{
    import std.algorithm.sorting : sort;
    import std.array : array;
    import std.file : mkdirRecurse, rmdirRecurse, symlink, tempDir, write;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    const root = buildPath(tempDir(), "walkDir-symlinks-" ~ randomUUID.toString);
    mkdirRecurse(buildPath(root, "real"));
    write(buildPath(root, "real", "data.txt"), "data");
    symlink(buildPath(root, "real"), buildPath(root, "link"));

    scope (exit)
        rmdirRecurse(root);

    auto files = dirEntriesFilter(root).array;
    files.sort;

    // `link` appears once as a file; its target's contents are listed only
    // under `real`, never a second time through the link.
    assert(files == ["link", "real/data.txt"]);
}
