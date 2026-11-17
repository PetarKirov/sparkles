/**
Native regular-file storage over the capability VFS; provider URIs use a
separate adapter.

A path becomes a root on its directory and a name in it. The atomic write,
its create-only disposition and directory durability are
`sparkles.base.vfs.write`'s (VFO9); the regular-file read is the VFS's
`readFile` (VFO12). This module keeps the editor's vocabulary: the save
authorization the UI grants, the receipt it shows, and the messages.
*/
module document_files;

import sparkles.base.expected : Expected, err, ok;
import sparkles.base.text.cstring : hasInteriorNul;

version (Posix)
{
    import sparkles.base.vfs : AtomicDisposition, AtomicMode, CreateDefault, ErrorKind, IoError,
        OpKind, ResolvePolicy, Rights, ambientAuthority, openRoot;
    import sparkles.event_horizon.sys.vfs : BlockingVfs;
}

/// Existing files may be replaced only after the UI explains the nonconditional commit.
enum SaveAuthorization : ubyte { createOnly, replaceConfirmed }

/// A returned receipt means the destination commit happened; durability is acknowledged separately.
struct SaveReceipt
{
    bool durable;
    string warning;
}

/**
Write `bytes` to `path` atomically, durably acknowledging the directory.
`createOnly` never replaces an entry, including one that appears during the
write; `replaceConfirmed` replaces only a regular file and keeps its
permission bits. A new file is private to its owner.
*/
Expected!SaveReceipt saveAtomic(string path, string bytes,
    SaveAuthorization authorization = SaveAuthorization.createOnly) @safe
{
    if (authorization != SaveAuthorization.createOnly && authorization != SaveAuthorization.replaceConfirmed)
        return err!SaveReceipt("Invalid save authorization.");
    version (Posix)
    {
        import std.path : baseName, dirName;

        if (!path.length || hasInteriorNul(path)) return err!SaveReceipt("Invalid destination path.");
        const name = baseName(path);
        if (!name.length || name == "." || name == ".." || name == "/")
            return err!SaveReceipt("The destination must name a regular file.");
        enum Rights rights = cast(Rights)(Rights.create | Rights.write | Rights.rename | Rights.stat);
        auto dir = openRoot!rights(new BlockingVfs, dirName(path), ambientAuthority(),
            ResolvePolicy.init, CreateDefault.ownerOnly);
        if (dir.hasError) return err!SaveReceipt("The destination directory could not be opened.");
        enum create = AtomicMode(AtomicDisposition.createNew, syncDirectory: true);
        enum replace = AtomicMode(AtomicDisposition.replace, keepPermissions: true, syncDirectory: true);
        const creating = authorization == SaveAuthorization.createOnly;
        auto written = creating ? dir.value.writeFileAtomic!create(name, bytes)
            : dir.value.writeFileAtomic!replace(name, bytes);
        if (written.hasError) return err!SaveReceipt(saveFailure(written.error, creating));
        SaveReceipt receipt;
        receipt.durable = written.value.directorySynced;
        if (written.value.temporaryLeft)
            receipt.warning = "The document was saved, but its private temporary could not be removed.";
        if (!receipt.durable)
            receipt.warning = "The document was saved, but directory durability could not be acknowledged.";
        return ok(receipt);
    }
    else return err!SaveReceipt("The native file-save adapter is unavailable on this platform.");
}

version (Posix)
private string saveFailure(in IoError error, bool creating) @safe pure nothrow @nogc
{
    if (error.kind == ErrorKind.exists && error.op != OpKind.openAt)
        return "The destination already exists; replacement needs confirmation.";
    if (error.kind == ErrorKind.isADirectory || error.kind == ErrorKind.symlinkRefused
        || (error.op == OpKind.statAt && error.kind == ErrorKind.other))
        return "Only a regular file can be replaced; choose another destination.";
    switch (error.op)
    {
        case OpKind.statAt: return "The destination metadata could not be checked.";
        case OpKind.openAt: return "A private save temporary could not be created.";
        case OpKind.write: return "Writing the save temporary failed.";
        case OpKind.setPermissions: return "The destination permissions could not be preserved.";
        case OpKind.fsync: return "The save temporary could not be synced.";
        case OpKind.close: return "Closing the save temporary failed before commit.";
        default:
            return creating
                ? "The destination was not created; it may already exist or disallow atomic creation."
                : "The destination could not be replaced.";
    }
}

/// Whether a read follows a symbolic link in the path's last component.
enum FinalLink : ubyte { refuse, follow }

/**
Read only a regular file, never waiting on one that is not (a raced FIFO, say).
Byte/UTF-8 admission is separate; the maximum bounds allocation without
truncating input. A document named through a link is read through it
(`FinalLink.follow`); recovery files are not.
*/
Expected!string readRegularBytes(string path, size_t maximum = 512UL << 20,
    FinalLink link = FinalLink.refuse) @safe nothrow
{
    version (Posix)
    {
        import std.array : appender;
        import std.path : baseName, dirName;

        if (!path.length || hasInteriorNul(path)) return err!string("Invalid document path.");
        if (link == FinalLink.follow) path = resolvedPath(path);
        const name = baseName(path);
        if (!name.length || name == "." || name == ".." || name == "/")
            return err!string("Only regular files can be opened as documents.");
        auto dir = openRoot!(Rights.read)(new BlockingVfs, dirName(path), ambientAuthority());
        if (dir.hasError) return err!string("The document could not be opened.");
        auto sink = appender!(ubyte[]);
        const read = dir.value.readFile(name, sink, maximum);
        if (read.hasError)
        {
            const e = read.error;
            if (e.kind == ErrorKind.bufferTooSmall)
                return err!string("The document exceeds the configured byte limit.");
            if (e.kind == ErrorKind.isADirectory || e.kind == ErrorKind.symlinkRefused
                || e.context == "not a regular file")
                return err!string("Only regular files can be opened as documents.");
            if (e.context == "the file changed while it was read")
                return err!string("The document changed while it was being opened.");
            if (e.op == OpKind.read) return err!string("The document could not be read.");
            return err!string("The document could not be opened.");
        }
        // The appender's array is this call's alone.
        return ok((() @trusted => cast(string) sink[])());
    }
    else return err!string("The regular-file adapter is unavailable on this platform.");
}

/// The path with every link resolved, or the path itself when it does not resolve.
version (Posix)
private string resolvedPath(string path) @trusted nothrow
{
    import core.stdc.stdlib : free;
    import core.sys.posix.stdlib : realpath;
    import sparkles.base.text.cstring : toTempStringz;
    import std.string : fromStringz;

    auto resolved = realpath(path.toTempStringz.ptr, null);
    if (resolved is null) return path;
    scope (exit) free(resolved);
    return resolved.fromStringz.idup;
}

/// A document opened through a link reads its target; recovery reads refuse the link.
@("editor.documentFiles.regularBytesFollowOnlyForDocuments")
@system unittest
{
    version (Posix)
    {
        import core.sys.posix.unistd : symlink;
        import sparkles.base.text.cstring : toTempStringz;
        import sparkles.test_utils.tmpfs : TmpFS;
        import std.path : buildPath;
        auto fixture = TmpFS.create();
        const path = fixture.writeFile("\xef\xbb\xbfa\r\nb\n");
        const loaded = readRegularBytes(path);
        assert(loaded.hasValue && loaded.value == "\xef\xbb\xbfa\r\nb\n");
        assert(readRegularBytes(path, 2).error == "The document exceeds the configured byte limit.");
        assert(readRegularBytes(fixture.dir).hasError);
        const link = buildPath(fixture.dir, "link.txt");
        assert(symlink(path.toTempStringz.ptr, link.toTempStringz.ptr) == 0);
        assert(readRegularBytes(link).hasError);
        const followed = readRegularBytes(link, 512, FinalLink.follow);
        assert(followed.hasValue && followed.value == loaded.value);
    }
    else
    {
        import sparkles.test_runner.skip : skipTest;
        skipTest("The native POSIX file adapter is not available.");
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
    assert(refused.error == "The destination already exists; replacement needs confirmation.");
    assert(readText(path) == "first\r\n");
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
        import sparkles.base.text.cstring : toTempStringz;
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
        const refused = saveAtomic(link, "must not write through the link", SaveAuthorization.replaceConfirmed);
        assert(refused.error == "Only a regular file can be replaced; choose another destination.");
        assert(readText(path) == "replacement");
        const fresh = saveAtomic(buildPath(fixture.dir, "fresh.txt"), "new");
        assert(fresh.hasValue);
        assert(stat(buildPath(fixture.dir, "fresh.txt").toTempStringz.ptr, &info) == 0
            && (info.st_mode & 511) == 384, "a new document is private to its owner");
    }
    else
    {
        import sparkles.test_runner.skip : skipTest;
        skipTest("The native POSIX file adapter is not available.");
    }
}
