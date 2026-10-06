/**
Atomic replacement of a file's contents (VFO9).

The new contents go to a fresh temporary entry in the same directory, created
with `createNew`, written, synced and closed, and then renamed over the
target, so a concurrent reader sees the complete old or the complete new
contents. Any failure removes the temporary entry.
*/
module sparkles.base.vfs.write;

import sparkles.base.io.errors : ErrorKind, IoError, IoErrorStage, IoResult, OpKind, ioErr, ioOk;
import sparkles.base.vfs.concept : isVfs;
import sparkles.base.vfs.types : Access, Disposition, OpenMode, Sharing, maxNameLength;

/// How many fresh temporary names are tried before giving up with `exists`.
enum size_t temporaryNameAttempts = 16;

/// Replaces `name` in `dir` with `bytes`, atomically.
IoResult!void writeFileAtomicAt(V, H)(ref V vfs, H dir, scope const(char)[] name,
    scope const(ubyte)[] bytes, Sharing sharing, bool executable)
if (isVfs!V && is(H == V.Handle))
{
    char[maxNameLength] temp;
    const mode = OpenMode(Access.write, Disposition.createNew, executable);
    foreach (attempt; 0 .. temporaryNameAttempts)
    {
        const t = temporaryName(temp, name, attempt);
        auto file = vfs.openFileAt(dir, t, mode, sharing);
        if (file.hasError)
        {
            if (file.error.kind == ErrorKind.exists)
                continue;
            return ioErr!void(file);
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
        if (!failed)
        {
            auto s = vfs.sync(file.value);
            if (s.hasError)
                failure = s.error, failed = true;
        }
        auto c = vfs.close(file.value);
        if (!failed && c.hasError)
            failure = c.error, failed = true;
        if (!failed)
        {
            auto r = vfs.renameAt(dir, t, dir, name);
            if (!r.hasError)
                return ioOk();
            failure = r.error;
        }
        vfs.unlinkAt(dir, t);
        return ioErr!void(failure);
    }
    return ioErr!void(ErrorKind.exists, OpKind.openAt, 0,
        IoErrorStage.completion, "no fresh temporary name");
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
