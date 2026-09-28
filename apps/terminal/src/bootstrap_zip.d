/**
Unpacking a nix-on-droid bootstrap zip (docs/specs/terminal/android.md,
`NOD6`) — the format `pkgs/bootstrap.nix` writes and Termux's installer reads:

$(LIST
    * regular files and directories, stored under their prefix-relative
        paths;
    * `SYMLINKS.txt`: one `target←linkpath` line per symlink (the builder
        deletes the links themselves from the tree); targets are used
        verbatim — absolute store paths resolve under proot — link paths are
        prefix-relative;
    * `EXECUTABLES.txt`: one prefix-relative path per executable file.
)

Everything lands in a staging directory first; the caller renames it into
place only when this returns success, so a failed or interrupted install never
leaves a half-populated prefix behind. Plain POSIX and Phobos — host-tested.
*/
module bootstrap_zip;

/// Progress of an extraction: `done` of `total` archive members.
alias ExtractProgress = void delegate(size_t done, size_t total) nothrow;

/**
Extract `zipPath` into `staging` (removed first if present). Returns `null` on
success, else the reason; on failure `staging` is removed again.

Refuses — rather than extracts — an entry or a link path that would leave
`staging` (absolute, or with a `..` component), and an archive missing either
list: a bootstrap without them is not one this app knows how to finish.
*/
string extractBootstrap(string zipPath, string staging, scope ExtractProgress progress = null)
{
    import std.file : exists, rmdirRecurse;

    try
    {
        if (staging.exists)
            rmdirRecurse(staging);
        const err = extractInto(zipPath, staging, progress);
        if (err is null)
            return null;
        if (staging.exists)
            rmdirRecurse(staging);
        return err;
    }
    catch (Exception e)
    {
        try
            if (staging.exists)
                rmdirRecurse(staging);
        catch (Exception) {}
        return e.msg;
    }
}

private string extractInto(string zipPath, string staging, scope ExtractProgress progress)
{
    import core.sys.posix.sys.stat : chmod;
    import core.sys.posix.unistd : symlink;
    import std.file : mkdirRecurse, write;
    import std.mmfile : MmFile;
    import std.path : buildPath, dirName;
    import std.string : lineSplitter, strip, toStringz;
    import std.zip : ZipArchive;

    import sparkles.android.bundle : isSafeAssetRel;

    auto mm = new MmFile(zipPath);
    scope (exit) destroy(mm);
    auto zip = new ZipArchive(mm[]);

    const symlinksText = memberText(zip, "SYMLINKS.txt");
    if (symlinksText is null)
        return "not a nix-on-droid bootstrap: SYMLINKS.txt missing";
    const executablesText = memberText(zip, "EXECUTABLES.txt");
    if (executablesText is null)
        return "not a nix-on-droid bootstrap: EXECUTABLES.txt missing";

    mkdirRecurse(staging);
    const total = zip.directory.length;
    size_t done;
    foreach (name, member; zip.directory)
    {
        ++done;
        if (progress !is null && (done % 64 == 0 || done == total))
            progress(done, total);
        if (name == "SYMLINKS.txt" || name == "EXECUTABLES.txt")
            continue;

        const isDir = name.length && name[$ - 1] == '/';
        const rel = isDir ? name[0 .. $ - 1] : name;
        if (rel.length == 0)
            continue;
        if (!isSafeAssetRel(rel))
            return "refusing an entry outside the prefix: " ~ name;

        const dest = buildPath(staging, rel);
        if (isDir)
        {
            mkdirRecurse(dest);
            continue;
        }
        mkdirRecurse(dest.dirName);
        write(dest, zip.expand(member));
        chmod(dest.toStringz, octal600);
    }

    foreach (line; executablesText.lineSplitter)
    {
        const rel = line.strip;
        if (rel.length == 0)
            continue;
        if (!isSafeAssetRel(rel))
            return "refusing an executable outside the prefix: " ~ rel;
        // A listed path the archive lacks is not fatal (Termux logs and
        // continues): the file simply is not there to run.
        chmod(buildPath(staging, rel).toStringz, octal700);
    }

    foreach (line; symlinksText.lineSplitter)
    {
        if (line.strip.length == 0)
            continue;
        string target, link;
        if (!splitSymlinkLine(line, target, link))
            return "malformed SYMLINKS.txt line: " ~ line;
        if (!isSafeAssetRel(link))
            return "refusing a symlink outside the prefix: " ~ link;
        const dest = buildPath(staging, link);
        mkdirRecurse(dest.dirName);
        if (symlink(target.toStringz, dest.toStringz) != 0)
            return "cannot create symlink " ~ link ~ " -> " ~ target;
    }
    return null;
}

private enum uint octal600 = 0x180; // rw-------
private enum uint octal700 = 0x1C0; // rwx------

/// A member's text, or `null` when the archive has no such member.
private string memberText(ZipArchive)(ZipArchive zip, string name)
{
    auto m = name in zip.directory;
    if (m is null)
        return null;
    return cast(string) zip.expand(*m).idup;
}

/// Split `target←linkpath` (U+2190, the bootstrap builder's separator).
bool splitSymlinkLine(const(char)[] line, out string target, out string link) @safe pure
{
    import std.string : indexOf, strip;

    enum sep = "←";
    const s = line.strip;
    const at = s.indexOf(sep);
    if (at <= 0 || at + sep.length >= s.length)
        return false;
    if (s[at + sep.length .. $].indexOf(sep) >= 0)
        return false; // Termux's `split` would reject a second arrow too
    target = s[0 .. at].idup;
    link = s[at + sep.length .. $].idup;
    return true;
}

///
@("bootstrap_zip.splitSymlinkLine")
@safe pure unittest
{
    string t, l;
    assert(splitSymlinkLine("/nix/store/abc-bash/bin/sh←bin/sh", t, l));
    assert(t == "/nix/store/abc-bash/bin/sh" && l == "bin/sh");
    assert(!splitSymlinkLine("no-arrow", t, l));
    assert(!splitSymlinkLine("←bin/sh", t, l));
    assert(!splitSymlinkLine("a←b←c", t, l));
}

version (unittest)
{
    /// A bootstrap-shaped zip at `path` from `(name, content)` pairs.
    private void writeZip(string path, string[2][] entries) @system
    {
        import std.file : write;
        import std.zip : ArchiveMember, CompressionMethod, ZipArchive;

        auto zip = new ZipArchive;
        foreach (e; entries)
        {
            auto m = new ArchiveMember;
            m.name = e[0];
            m.expandedData(cast(ubyte[]) e[1].dup);
            m.compressionMethod = CompressionMethod.deflate;
            zip.addMember(m);
        }
        write(path, zip.build());
    }

    private string scratchDir(string tag) @system
    {
        import std.conv : text;
        import std.file : mkdirRecurse, tempDir;
        import std.path : buildPath;
        import std.process : thisProcessID;

        const d = buildPath(tempDir, text("bootstrap-zip-", tag, "-", thisProcessID));
        mkdirRecurse(d);
        return d;
    }
}

@("bootstrap_zip.extractsFilesExecutablesAndSymlinks")
@system unittest
{
    import core.sys.posix.sys.stat : lstat, stat_t, S_IFLNK, S_IFMT;
    import std.file : exists, readLink, readText, rmdirRecurse;
    import std.path : buildPath;
    import std.string : toStringz;

    const dir = scratchDir("ok");
    scope (exit) rmdirRecurse(dir);
    const zipPath = buildPath(dir, "bootstrap-x86_64.zip");
    writeZip(zipPath, [
        ["bin/login", "#!/system/bin/sh\nexec true\n"],
        ["usr/lib/login-inner", "echo inner\n"],
        ["nix/store/abc-bash/bin/bash", "ELF"],
        ["etc/", ""],
        ["EXECUTABLES.txt", "bin/login\nnix/store/abc-bash/bin/bash\n"],
        ["SYMLINKS.txt", "/nix/store/abc-bash/bin/bash←bin/sh\n"],
    ]);

    size_t lastDone, lastTotal;
    const staging = buildPath(dir, "usr-staging");
    const err = extractBootstrap(zipPath, staging,
        (size_t d, size_t t) nothrow { lastDone = d; lastTotal = t; });
    assert(err is null, err);
    assert(lastDone == lastTotal && lastTotal == 6, "the last member reports");

    assert(readText(buildPath(staging, "usr/lib/login-inner")) == "echo inner\n");
    assert(buildPath(staging, "etc").exists);
    assert(!buildPath(staging, "SYMLINKS.txt").exists, "the lists are not files of the prefix");

    stat_t st;
    assert(lstat(buildPath(staging, "bin/login").toStringz, &st) == 0);
    assert((st.st_mode & 0x1FF) == octal700, "listed executables are 0700");
    assert(lstat(buildPath(staging, "usr/lib/login-inner").toStringz, &st) == 0);
    assert((st.st_mode & 0x1FF) == octal600, "everything else is 0600");

    assert(lstat(buildPath(staging, "bin/sh").toStringz, &st) == 0);
    assert((st.st_mode & S_IFMT) == S_IFLNK);
    assert(readLink(buildPath(staging, "bin/sh")) == "/nix/store/abc-bash/bin/bash",
        "targets are used verbatim — proot resolves the store path");
}

@("bootstrap_zip.refusesWhatIsNotABootstrapAndCleansUp")
@system unittest
{
    import std.file : exists, rmdirRecurse;
    import std.path : buildPath;

    const dir = scratchDir("bad");
    scope (exit) rmdirRecurse(dir);
    const staging = buildPath(dir, "usr-staging");

    const noLists = buildPath(dir, "a.zip");
    writeZip(noLists, [["bin/login", "x"]]);
    assert(extractBootstrap(noLists, staging) !is null);
    assert(!staging.exists, "a failed install leaves no staging dir");

    const escaping = buildPath(dir, "b.zip");
    writeZip(escaping, [
        ["../evil", "x"], ["EXECUTABLES.txt", ""], ["SYMLINKS.txt", ""],
    ]);
    const err = extractBootstrap(escaping, staging);
    assert(err !is null && !buildPath(dir, "evil").exists, "no entry escapes");
    assert(!staging.exists);

    const badLink = buildPath(dir, "c.zip");
    writeZip(badLink, [
        ["EXECUTABLES.txt", ""], ["SYMLINKS.txt", "/etc/passwd←../../outside\n"],
    ]);
    assert(extractBootstrap(badLink, staging) !is null);
    assert(!staging.exists);
}
