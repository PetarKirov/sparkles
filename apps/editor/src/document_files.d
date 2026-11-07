/** Native regular-file storage; provider URIs use a separate adapter. */
module document_files;

import sparkles.base.expected : Expected, err, ok;
import sparkles.base.text.cstring : hasInteriorNul, toTempStringz;
import sparkles.event_horizon.sys.descriptor : OwnedFd;

version (Posix)
{
    import core.stdc.errno : errno, EINTR, ENOENT;
    import core.sys.posix.sys.stat : fchmod, fstat, stat_t, S_IFMT, S_IFREG;
    import core.sys.posix.fcntl : O_NONBLOCK;
    import core.sys.posix.unistd : linkat, read;
    import sparkles.event_horizon.sys.posix : openat, AT_FDCWD, AT_SYMLINK_NOFOLLOW,
        O_RDONLY, O_WRONLY, O_CREAT, O_EXCL, O_CLOEXEC, O_DIRECTORY,
        close, fstatat, fsync, renameat, unlinkat, write;
}

/// Existing files may be replaced only after the UI explains the nonconditional commit.
enum SaveAuthorization : ubyte { createOnly, replaceConfirmed }

/// A returned receipt means the destination commit happened; durability is acknowledged separately.
struct SaveReceipt
{
    bool durable;
    string warning;
}

/// Sync a private temporary, then install it in one directory-relative atomic operation.
/// createOnly uses a hard-link commit that cannot replace an existing entry, including races.
Expected!SaveReceipt saveAtomic(string path, string bytes,
    SaveAuthorization authorization = SaveAuthorization.createOnly) @safe
{
    if (authorization != SaveAuthorization.createOnly && authorization != SaveAuthorization.replaceConfirmed)
        return err!SaveReceipt("Invalid save authorization.");
    version (Posix)
    {
        import std.path : baseName, dirName;
        import std.uuid : randomUUID;
        if (!path.length || hasInteriorNul(path)) return err!SaveReceipt("Invalid destination path.");
        const name = baseName(path);
        if (!name.length || name == "." || name == ".." || name == "/")
            return err!SaveReceipt("The destination must name a regular file.");
        auto directory = OwnedFd((() @trusted => openat(AT_FDCWD, dirName(path).toTempStringz.ptr,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC))());
        if (!directory.valid) return err!SaveReceipt("The destination directory could not be opened.");
        const parent = directory.borrowFd.fd;
        stat_t existing;
        const found = (() @trusted => fstatat(parent, name.toTempStringz.ptr,
            &existing, AT_SYMLINK_NOFOLLOW))() == 0;
        if (!found && errno != ENOENT)
            return err!SaveReceipt("The destination metadata could not be checked.");
        if (found)
        {
            if (authorization != SaveAuthorization.replaceConfirmed)
                return err!SaveReceipt("The destination already exists; replacement needs confirmation.");
            if ((existing.st_mode & S_IFMT) != S_IFREG)
                return err!SaveReceipt("Only a regular file can be replaced; choose another destination.");
        }
        const temporary = ".sparkles-editor-" ~ randomUUID().toString();
        auto file = OwnedFd((() @trusted => openat(parent, temporary.toTempStringz.ptr,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 384))());
        if (!file.valid) return err!SaveReceipt("A private save temporary could not be created.");
        bool cleanup = true;
        scope (exit) if (cleanup) (() @trusted => unlinkat(parent, temporary.toTempStringz.ptr, 0))();
        const fd = file.borrowFd.fd;
        size_t done;
        while (done < bytes.length)
        {
            const count = (() @trusted => write(fd, bytes.ptr + done, bytes.length - done))();
            if (count < 0 && errno == EINTR) continue;
            if (count <= 0) return err!SaveReceipt("Writing the save temporary failed.");
            done += cast(size_t) count;
        }
        if (found && (() @trusted => fchmod(fd, existing.st_mode & 511))() != 0)
            return err!SaveReceipt("The destination permissions could not be preserved.");
        int synced;
        do synced = (() @trusted => fsync(fd))();
        while (synced != 0 && errno == EINTR);
        if (synced != 0) return err!SaveReceipt("The save temporary could not be synced.");
        const closing = file.release();
        if ((() @trusted => close(closing))() != 0)
            return err!SaveReceipt("Closing the save temporary failed before commit.");
        SaveReceipt receipt;
        if (authorization == SaveAuthorization.createOnly)
        {
            if ((() @trusted => linkat(parent, temporary.toTempStringz.ptr,
                    parent, name.toTempStringz.ptr, 0))() != 0)
                return err!SaveReceipt("The destination was not created; it may already exist or disallow atomic creation.");
            if ((() @trusted => unlinkat(parent, temporary.toTempStringz.ptr, 0))() == 0) cleanup = false;
            else receipt.warning = "The document was saved, but its private temporary could not be removed.";
        }
        else
        {
            if ((() @trusted => renameat(parent, temporary.toTempStringz.ptr,
                    parent, name.toTempStringz.ptr))() != 0)
                return err!SaveReceipt("The destination could not be replaced.");
            cleanup = false;
        }
        do synced = (() @trusted => fsync(parent))();
        while (synced != 0 && errno == EINTR);
        receipt.durable = synced == 0;
        if (!receipt.durable)
            receipt.warning = "The document was saved, but directory durability could not be acknowledged.";
        return ok(receipt);
    }
    else return err!SaveReceipt("The native file-save adapter is unavailable on this platform.");
}

/// Two competing atomic creators produce exactly one complete winner, never a silent replacement.
@("editor.documentFiles.concurrentCreateHasOneWinner")
@system unittest
{
    version (Posix)
    {
        import core.thread : Thread;
        import sparkles.test_utils.tmpfs : TmpFS;
        import std.file : readText;
        import std.path : buildPath;
        import std.conv : text;
        struct Attempt
        {
            string path, bytes;
            bool committed;
            void run() { committed = saveAtomic(path, bytes).hasValue; }
        }
        auto fixture = TmpFS.create();
        foreach (round; 0 .. 8)
        {
            const path = buildPath(fixture.dir, text("race-", round));
            Attempt first = Attempt(path, "first complete document");
            Attempt second = Attempt(path, "second complete document");
            auto a = new Thread(&first.run);
            auto b = new Thread(&second.run);
            a.start(); b.start();
            a.join(); b.join();
            assert(first.committed != second.committed);
            assert(readText(path) == (first.committed ? first.bytes : second.bytes));
        }
    }
    else
    {
        import sparkles.test_runner.skip : skipTest;
        skipTest("The native POSIX file adapter is not available.");
    }
}

/// Read only a regular descriptor. O_NONBLOCK prevents a raced FIFO from trapping the worker.
/// Byte/UTF-8 admission is separate; the maximum bounds allocation without truncating input.
Expected!string readRegularBytes(string path, size_t maximum = 512UL << 20) @safe nothrow
{
    version (Posix)
    {
        if (!path.length || hasInteriorNul(path)) return err!string("Invalid document path.");
        auto file = OwnedFd((() @trusted => openat(AT_FDCWD, path.toTempStringz.ptr,
            O_RDONLY | O_NONBLOCK | O_CLOEXEC))());
        if (!file.valid) return err!string("The document could not be opened.");
        const fd = file.borrowFd.fd;
        stat_t before;
        if ((() @trusted => fstat(fd, &before))() != 0)
            return err!string("The document metadata could not be read.");
        if ((before.st_mode & S_IFMT) != S_IFREG)
            return err!string("Only regular files can be opened as documents.");
        if (before.st_size < 0 || cast(ulong) before.st_size > maximum)
            return err!string("The document exceeds the configured byte limit.");
        auto bytes = new char[cast(size_t) before.st_size];
        size_t done;
        while (done < bytes.length)
        {
            const count = (() @trusted => read(fd, bytes.ptr + done, bytes.length - done))();
            if (count < 0)
            {
                if (errno == EINTR) continue;
                return err!string("The document could not be read.");
            }
            if (!count) return err!string("The document changed while it was being opened.");
            done += cast(size_t) count;
        }
        char extra;
        ptrdiff_t trailing;
        do trailing = (() @trusted => read(fd, &extra, 1))();
        while (trailing < 0 && errno == EINTR);
        if (trailing < 0) return err!string("The document could not be read.");
        stat_t after;
        if (trailing || (() @trusted => fstat(fd, &after))() != 0 || before.st_size != after.st_size)
            return err!string("The document changed while it was being opened.");
        static if (__traits(compiles, before.st_mtim))
        {
            if (before.st_mtim != after.st_mtim || before.st_ctim != after.st_ctim)
                return err!string("The document changed while it was being opened.");
        }
        else static if (__traits(compiles, before.st_mtimespec))
        {
            if (before.st_mtimespec != after.st_mtimespec || before.st_ctimespec != after.st_ctimespec)
                return err!string("The document changed while it was being opened.");
        }
        return ok((() @trusted => cast(string) bytes)());
    }
    else return err!string("The regular-file adapter is unavailable on this platform.");
}

/// Byte reads preserve the envelope and refuse nonregular inputs without waiting for a writer.
@("editor.documentFiles.regularBytesAndFifo")
@system unittest
{
    version (Posix) {}
    else
    {
        import sparkles.test_runner.skip : skipTest;
        skipTest("The native POSIX file adapter is not available.");
    }
    import sparkles.test_utils.tmpfs : TmpFS;
    import std.path : buildPath;
    auto fixture = TmpFS.create();
    const path = fixture.writeFile("\xef\xbb\xbfa\r\nb\n");
    const loaded = readRegularBytes(path);
    assert(loaded.hasValue && loaded.value == "\xef\xbb\xbfa\r\nb\n");
    assert(readRegularBytes(path, 2).hasError);
    assert(readRegularBytes(fixture.dir).hasError);
    version (Posix)
    {
        import core.sys.posix.sys.stat : mkfifo;
        import sparkles.base.text.cstring : toTempStringz;
        const fifo = buildPath(fixture.dir, "pipe");
        assert(mkfifo(fifo.toTempStringz.ptr, 384) == 0);
        assert(readRegularBytes(fifo).hasError);
    }
}

/// New destinations never overwrite a raced/existing entry; replacement requires explicit policy.
@("editor.documentFiles.atomicCreateAndAuthorizedReplace")
@system unittest
{
    version (Posix) {}
    else
    {
        import sparkles.test_runner.skip : skipTest;
        skipTest("The native POSIX file adapter is not available.");
    }
    import sparkles.test_utils.tmpfs : TmpFS;
    import std.file : readText;
    import std.path : buildPath;
    auto fixture = TmpFS.create();
    const path = buildPath(fixture.dir, "document.txt");
    const created = saveAtomic(path, "first\r\n");
    assert(created.hasValue && readText(path) == "first\r\n");
    assert(created.value.durable || created.value.warning.length);
    const refused = saveAtomic(path, "must not replace");
    assert(refused.hasError && readText(path) == "first\r\n");
    const replaced = saveAtomic(path, "second\n", SaveAuthorization.replaceConfirmed);
    assert(replaced.hasValue && readText(path) == "second\n");
    assert(saveAtomic(fixture.dir, "must not replace directory",
        SaveAuthorization.replaceConfirmed).hasError);
}

/// Replacing a document preserves ordinary permissions and refuses symlink destinations.
@("editor.documentFiles.permissionsAndSymlinkDestination")
@system unittest
{
    version (Posix)
    {
        import core.sys.posix.sys.stat : chmod, stat_t, stat;
        import core.sys.posix.unistd : symlink;
        import sparkles.test_utils.tmpfs : TmpFS;
        import std.path : buildPath;
        import std.file : readText;
        auto fixture = TmpFS.create();
        const path = fixture.writeFile("original");
        assert(chmod(path.toTempStringz.ptr, 416) == 0); // 0640
        const replaced = saveAtomic(path, "replacement", SaveAuthorization.replaceConfirmed);
        assert(replaced.hasValue);
        stat_t info;
        assert(stat(path.toTempStringz.ptr, &info) == 0 && (info.st_mode & 511) == 416);
        const link = buildPath(fixture.dir, "link.txt");
        assert(symlink(path.toTempStringz.ptr, link.toTempStringz.ptr) == 0);
        assert(saveAtomic(link, "must not write through the link", SaveAuthorization.replaceConfirmed).hasError);
        assert(readText(path) == "replacement");
    }
    else
    {
        import sparkles.test_runner.skip : skipTest;
        skipTest("The native POSIX file adapter is not available.");
    }
}
