/**
Atomic writes of a file's contents (VFO9).

The new contents go to a fresh temporary entry in the same directory, created
with `createNew`, written, synced and closed, and then committed under the
target's name, so a concurrent reader sees the complete old or the complete
new contents, or, for a new file, nothing. Any failure before the commit
removes the temporary entry.

A replacing write commits with a rename. A creating write commits with a
rename that cannot replace, where the backend has one (VFB8), and otherwise
with a hard link followed by removing the temporary name: both fail with
`exists` if the name is taken, even by an entry that appeared during the
write. Android's application sandbox refuses hard links, so the no-replace
rename comes first.
*/
module sparkles.base.vfs.write;

import sparkles.base.io.errors : ErrorKind, IoError, IoErrorStage, IoResult, OpKind, ioErr, ioOk;
import sparkles.base.vfs.concept : hasLinkAt, hasRenameNoReplace, hasSetPermissions, isVfs;
import sparkles.base.vfs.types : Access, AtomicDisposition, AtomicMode, AtomicReceipt, Disposition,
    EntryKind, OpenMode, Sharing, StatMask, maxNameLength;

/// How many fresh temporary names are tried before giving up with `exists`.
enum size_t temporaryNameAttempts = 16;

/// Writes `bytes` to `name` in `dir` atomically, as `mode` says (VFO9).
IoResult!AtomicReceipt writeFileAtomicAt(AtomicMode mode, V, H)(ref V vfs, H dir,
    scope const(char)[] name, scope const(ubyte)[] bytes, Sharing sharing)
if (isVfs!V && is(H == V.Handle))
{
    static assert(!mode.keepPermissions || mode.disposition == AtomicDisposition.replace,
        "keepPermissions applies only to a replacing write");
    static assert(!mode.keepPermissions || hasSetPermissions!V,
        V.stringof ~ " cannot set permissions, so it cannot keep them");
    static assert(mode.disposition != AtomicDisposition.createNew
        || hasRenameNoReplace!V || hasLinkAt!V,
        V.stringof ~ " has neither a no-replace rename nor a hard link, so it cannot create atomically");

    bool keep;
    uint keptBits;
    static if (mode.keepPermissions)
    {
        auto existing = vfs.statAt(dir, name, StatMask.basic);
        if (existing.hasError)
        {
            if (existing.error.kind != ErrorKind.notFound)
                return ioErr!AtomicReceipt(existing);
        }
        else
        {
            final switch (existing.value.kind)
            {
                case EntryKind.regular: break;
                case EntryKind.directory:
                    return ioErr!AtomicReceipt(ErrorKind.isADirectory, OpKind.statAt);
                case EntryKind.symlink:
                    return ioErr!AtomicReceipt(ErrorKind.symlinkRefused, OpKind.statAt);
                case EntryKind.unknown:
                case EntryKind.other:
                    return ioErr!AtomicReceipt(ErrorKind.other, OpKind.statAt, 0,
                        IoErrorStage.completion, "only a regular file can be replaced");
            }
            keep = true;
            version (Posix)
                keptBits = existing.value.permissions;
        }
    }

    char[maxNameLength] temp;
    const open = OpenMode(Access.write, Disposition.createNew, mode.executable);
    foreach (attempt; 0 .. temporaryNameAttempts)
    {
        const t = temporaryName(temp, name, attempt);
        auto file = vfs.openFileAt(dir, t, open, sharing);
        if (file.hasError)
        {
            if (file.error.kind == ErrorKind.exists)
                continue;
            return ioErr!AtomicReceipt(file);
        }

        IoError failure;
        bool failed;
        size_t done;
        while (!failed && done < bytes.length)
        {
            auto w = vfs.write(file.value, bytes[done .. $]);
            if (w.hasError)
                failure = w.error, failed = true;
            else if (w.value == 0)
                failure = IoError(ErrorKind.other, 0, OpKind.write), failed = true;
            else
                done += w.value;
        }
        static if (mode.keepPermissions)
            if (!failed && keep)
            {
                auto p = vfs.setPermissions(file.value, keptBits);
                if (p.hasError)
                    failure = p.error, failed = true;
            }
        if (!failed)
        {
            auto s = vfs.sync(file.value);
            if (s.hasError)
                failure = s.error, failed = true;
        }
        auto c = vfs.close(file.value);
        if (!failed && c.hasError)
            failure = c.error, failed = true;
        AtomicReceipt receipt;
        if (!failed)
        {
            auto committed = commit!mode(vfs, dir, t, name, receipt);
            if (!committed.hasError)
            {
                static if (mode.syncDirectory)
                    receipt.directorySynced = !vfs.sync(dir).hasError;
                return ioOk(receipt);
            }
            failure = committed.error;
        }
        vfs.unlinkAt(dir, t);
        return ioErr!AtomicReceipt(failure);
    }
    return ioErr!AtomicReceipt(ErrorKind.exists, OpKind.openAt, 0,
        IoErrorStage.completion, "no fresh temporary name");
}

/*
Installs the closed temporary `t` as `name`. A creating commit's error leaves
the temporary in place for the caller to remove; a link commit removes it
itself and reports a removal it could not make in the receipt.
*/
private IoResult!void commit(AtomicMode mode, V, H)(ref V vfs, H dir, scope const(char)[] t,
    scope const(char)[] name, ref AtomicReceipt receipt)
{
    static if (mode.disposition == AtomicDisposition.replace)
        return vfs.renameAt(dir, t, dir, name);
    else
    {
        static if (hasRenameNoReplace!V)
        {
            auto r = vfs.renameNoReplaceAt(dir, t, dir, name);
            static if (hasLinkAt!V)
            {
                if (!r.hasError || r.error.kind != ErrorKind.unsupported)
                    return r;
            }
            else
                return r;
        }
        static if (hasLinkAt!V)
        {
            auto l = vfs.linkAt(dir, t, dir, name);
            if (l.hasError)
                return l;
            receipt.temporaryLeft = vfs.unlinkAt(dir, t).hasError;
            return ioOk();
        }
    }
}

private size_t nextTemporary;

/*
A hidden name beside the target: `.` + up to 200 bytes of the target's name
+ `.tmp-` + a counter in hex. Unique within the process; `createNew` and the
retry loop handle a collision with another process.
*/
private const(char)[] temporaryName(return ref char[maxNameLength] buffer,
    scope const(char)[] name, size_t attempt) @safe nothrow @nogc
{
    static immutable hex = "0123456789abcdef";
    size_t n;
    buffer[n++] = '.';
    const stem = name.length < 200 ? name.length : 200;
    buffer[n .. n + stem] = name[0 .. stem];
    n += stem;
    buffer[n .. n + 5] = ".tmp-";
    n += 5;
    size_t counter = nextTemporary++ * temporaryNameAttempts + attempt;
    char[16] digits;
    size_t d;
    do
    {
        digits[d++] = hex[counter & 15];
        counter >>= 4;
    }
    while (counter);
    foreach_reverse (i; 0 .. d)
        buffer[n++] = digits[i];
    return buffer[0 .. n];
}
