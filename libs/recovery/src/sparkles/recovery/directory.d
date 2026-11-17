/**
Private, durable archive directories with process-shared ownership leases.

A `LeasedDirectory` is one archive: a private directory created under a base
directory with a random name, synced up to a durable namespace root, and held
with an exclusive `flock` for as long as its owner lives. Another process
claims it only after the owner closes it or dies, so a crashed session's
archive is recovered without two instances writing to it. Linux only, for
now: elsewhere every call reports `unavailable`.
*/
module sparkles.recovery.directory;

import sparkles.base.expected : Expected, err, ok;
import sparkles.base.text.cstring : hasInteriorNul, toTempStringz;
import sparkles.event_horizon.sys.descriptor : OwnedFd;
import std.path : absolutePath, buildNormalizedPath, buildPath, dirName;
import std.uuid : randomUUID;
import std.file : mkdirRecurse;

version (linux)
{
    import core.stdc.errno : errno, EAGAIN, EINTR, ENOENT, EWOULDBLOCK;
    import core.sys.linux.sys.file : flock, LOCK_EX, LOCK_NB, LOCK_SH;
    import core.sys.posix.fcntl : O_NOFOLLOW;
    import core.sys.posix.sys.stat : mkdirat;
    import sparkles.event_horizon.sys.posix : openat, fsync, AT_FDCWD,
        O_RDONLY, O_DIRECTORY, O_CLOEXEC;
}

/// Why a lease was not granted.
enum DirectoryIssueKind : ubyte
{
    busy,        /// another live owner holds it
    missing,     /// the archive no longer exists
    unavailable, /// anything else; the message says what
}

/// A refused lease and its user-facing message.
struct DirectoryIssue
{
    DirectoryIssueKind kind; ///
    string message;          ///
}

/// A granted lease or why not.
alias DirectoryResult = Expected!(LeasedDirectory, DirectoryIssue);

/**
One archive's directory lock. Keep this owner alive until its storage work has
stopped, then close it explicitly. Other processes can claim an archive only
after its owner closes or terminates. Creation and claim serialize against
the base directory lock so a half-initialized archive cannot be claimed.
*/
class LeasedDirectory
{
    private string path_;
    private OwnedFd descriptor;

    private this(string path, ref OwnedFd directory) @safe nothrow @nogc
    {
        path_ = path;
        descriptor = OwnedFd(directory.release());
    }

    /// The archive's absolute path.
    string path() const @safe pure nothrow @nogc => path_;
    /// Whether this owner still holds the lease.
    bool owned() const @safe pure nothrow @nogc => descriptor.valid;
    /// Releases the lease; idempotent.
    void close() @safe nothrow @nogc { descriptor.close(); }

    /**
    Make a private archive under an existing, already durable namespace root.
    Sync the created subtree up to that root before publishing it. A platform
    supplies the root: initialization must not open inaccessible ancestors
    outside an Android application's private namespace.
    */
    static DirectoryResult create(string base, string durableRoot) @safe nothrow
    {
        version (linux)
        {
            if (!base.length || base.hasInteriorNul || !durableRoot.length || durableRoot.hasInteriorNul)
                return unavailable("Invalid recovery base or namespace root.");
            try
            {
                base = buildNormalizedPath(absolutePath(base));
                durableRoot = buildNormalizedPath(absolutePath(durableRoot));
                if (base != durableRoot && durableRoot != "/"
                    && !(base.length > durableRoot.length && base[0 .. durableRoot.length] == durableRoot
                        && base[durableRoot.length] == '/'))
                    return unavailable("The recovery base is outside its durable namespace root.");
                auto root = OwnedFd(openDirectory(durableRoot));
                if (!root.valid) return unavailable("The durable recovery namespace root is unavailable.");
                (() @trusted { mkdirRecurse(base); })();
                auto parent = OwnedFd(openDirectory(base));
                if (!parent.valid || lock(parent.borrowFd.fd, LOCK_EX) != 0)
                    return unavailable("The recovery base directory could not be locked.");
                const name = randomUUID().toString();
                if ((() @trusted => mkdirat(parent.borrowFd.fd, name.toTempStringz.ptr, 448))() != 0)
                    return unavailable("A private recovery archive could not be created.");
                const path = buildPath(base, name);
                auto directory = OwnedFd(openDirectory(path, true));
                if (!directory.valid || lock(directory.borrowFd.fd, LOCK_EX | LOCK_NB) != 0)
                    return unavailable("The new recovery archive could not be owned.");
                auto synced = syncAncestors(path, durableRoot);
                if (synced.hasError) return err!LeasedDirectory(synced.error);
                return ok!DirectoryIssue(new LeasedDirectory(path, directory));
            }
            catch (Exception) { return unavailable("The recovery archive could not be initialized."); }
        }
        else return unavailable("Recovery directory leases are unavailable on this platform.");
    }

    /// Claim an abandoned archive; an active archive returns a typed busy outcome.
    static DirectoryResult claim(string path) @safe nothrow
    {
        version (linux)
        {
            if (!path.length || path.hasInteriorNul) return unavailable("Invalid recovery archive directory.");
            try
            {
                path = absolutePath(path);
                auto parent = OwnedFd(openDirectory(dirName(path)));
                if (!parent.valid || lock(parent.borrowFd.fd, LOCK_SH) != 0)
                    return unavailable("The recovery base directory could not be locked.");
                auto directory = OwnedFd(openDirectory(path, true));
                if (!directory.valid)
                {
                    if (errno == ENOENT)
                        return err!LeasedDirectory(DirectoryIssue(DirectoryIssueKind.missing,
                            "The recovery archive no longer exists."));
                    return unavailable("The recovery archive is not an accessible ordinary directory.");
                }
                if (lock(directory.borrowFd.fd, LOCK_EX | LOCK_NB) != 0)
                {
                    if (errno == EAGAIN || errno == EWOULDBLOCK)
                        return err!LeasedDirectory(DirectoryIssue(DirectoryIssueKind.busy,
                            "The recovery archive belongs to another active owner."));
                    return unavailable("The recovery archive could not be locked.");
                }
                return ok!DirectoryIssue(new LeasedDirectory(path, directory));
            }
            catch (Exception) { return unavailable("The recovery archive could not be claimed."); }
        }
        else return unavailable("Recovery directory leases are unavailable on this platform.");
    }
}

private DirectoryResult unavailable(string message) @safe pure nothrow @nogc
    => err!LeasedDirectory(DirectoryIssue(DirectoryIssueKind.unavailable, message));

version (linux)
{
    private int openDirectory(string path, bool noFollow = false) @safe nothrow @nogc
        => (() @trusted => openat(AT_FDCWD, path.toTempStringz.ptr,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | (noFollow ? O_NOFOLLOW : 0)))();

    private int lock(int fd, int operation) @safe nothrow @nogc
    {
        int result;
        do result = flock(fd, operation);
        while (result != 0 && errno == EINTR);
        return result;
    }

    private Expected!(void, DirectoryIssue) syncAncestors(string path, string durableRoot) @safe nothrow
    {
        while (true)
        {
            auto directory = OwnedFd(openDirectory(path));
            if (!directory.valid)
                return err!void(DirectoryIssue(DirectoryIssueKind.unavailable,
                    "A recovery ancestor directory could not be opened for sync."));
            int result;
            do result = (() @trusted => fsync(directory.borrowFd.fd))();
            while (result != 0 && errno == EINTR);
            if (result != 0)
                return err!void(DirectoryIssue(DirectoryIssueKind.unavailable,
                    "Recovery directory creation could not be durably acknowledged."));
            if (path == durableRoot) break;
            const parent = dirName(path);
            if (parent == path)
                return err!void(DirectoryIssue(DirectoryIssueKind.unavailable,
                    "Recovery initialization could not reach its namespace root."));
            path = parent;
        }
        return ok!DirectoryIssue();
    }
}

/// An active archive cannot be claimed again, and closing releases its lease.
@("recovery.directory.privateOwnershipAndReclaim")
@safe unittest
{
    version (linux) {}
    else
    {
        import sparkles.test_runner.skip : skipTest;
        skipTest("Recovery directory leases currently require Linux flock.");
    }
    import sparkles.test_utils.tmpfs : TmpFS;
    import std.file : getAttributes;
    import std.path : buildPath;
    auto fixture = TmpFS.create();
    const base = buildPath(fixture.dir, "new", "sessions");
    auto created = LeasedDirectory.create(base, fixture.dir);
    assert(created.hasValue);
    scope (exit) created.value.close();
    assert(((() @trusted => getAttributes(created.value.path))() & 63) == 0);
    auto busy = LeasedDirectory.claim(created.value.path);
    assert(busy.hasError && busy.error.kind == DirectoryIssueKind.busy);
    const path = created.value.path;
    created.value.close();
    auto claimed = LeasedDirectory.claim(path);
    assert(claimed.hasValue && claimed.value.path == path);
    scope (exit) claimed.value.close();
}

/// Initialization needs no read access above the platform-provided namespace root.
@("recovery.directory.staysInsideSandboxRoot")
@safe unittest
{
    import sparkles.test_runner.skip : skipTest;
    version (linux)
    {
        import core.sys.posix.sys.stat : chmod, S_IRWXU, S_IXUSR;
        import core.sys.posix.unistd : geteuid;
        import sparkles.test_utils.tmpfs : TmpFS;
        import std.file : exists, mkdir;
        if ((() @trusted => geteuid())() == 0)
            skipTest("Root bypasses the directory-read restriction used by this sandbox test.");
        auto fixture = TmpFS.create();
        const root = buildPath(fixture.dir, "namespace");
        (() @trusted { mkdir(root); })();
        scope (exit) (() @trusted => chmod(fixture.dir.toTempStringz.ptr, S_IRWXU))();
        assert((() @trusted => chmod(fixture.dir.toTempStringz.ptr, S_IXUSR))() == 0);
        auto directory = LeasedDirectory.create(buildPath(root, "new", "sessions"), root);
        assert(directory.hasValue);
        scope (exit) directory.value.close();
        auto escaped = LeasedDirectory.create(buildPath(root, "..", "escape"), root);
        assert(escaped.hasError && !(() @trusted => exists(buildPath(fixture.dir, "escape")))());
    }
    else skipTest("Recovery directory initialization currently requires Linux.");
}
