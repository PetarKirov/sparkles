/**
Reading a whole regular file (VFO12).

The file is opened with `regularOnly`, so a FIFO, a device or a link in its
place is refused without waiting, and its contents are checked against the
size and times it had when opened: a file that grows, shrinks or is
rewritten while it is read fails instead of yielding a mix.
*/
module sparkles.base.vfs.read;

import std.range.primitives : put;

import sparkles.base.io.errors : ErrorKind, IoErrorStage, IoResult, OpKind, ioErr, ioOk;
import sparkles.base.vfs.concept : isVfs;
import sparkles.base.vfs.types : OpenMode, Sharing, Stat, StatMask;

/// The bytes `readFileAt` reads per call.
enum size_t readChunkBytes = 16 * 1024;

/**
Puts the contents of the regular file `name` in `dir` into `sink`, an output
range of `const(ubyte)[]`, and returns their length (VFO12). A file longer
than `maximum` bytes fails with `bufferTooSmall` before anything is read. A
sink with `reserve(size_t)` is given the file's size first.
*/
IoResult!size_t readFileAt(V, H, W)(ref V vfs, H dir, scope const(char)[] name, ref W sink,
    size_t maximum)
if (isVfs!V && is(H == V.Handle))
{
    auto file = vfs.openFileAt(dir, name, OpenMode.regularRead, Sharing.init);
    if (file.hasError)
        return ioErr!size_t(file);
    scope (exit) vfs.close(file.value);
    enum mask = cast(StatMask)(StatMask.mtime | StatMask.change);
    auto before = vfs.fstat(file.value, mask);
    if (before.hasError)
        return ioErr!size_t(before);
    if (before.value.size > maximum)
        return ioErr!size_t(ErrorKind.bufferTooSmall, OpKind.read, 0, IoErrorStage.completion,
            "the file exceeds the byte limit");
    const size = cast(size_t) before.value.size;
    static if (__traits(compiles, sink.reserve(size)))
        sink.reserve(size);
    ubyte[readChunkBytes] chunk;
    size_t done;
    // One read past the size: a file that grew shows itself here.
    while (true)
    {
        const want = size - done < chunk.length ? size - done + 1 : chunk.length;
        auto r = vfs.read(file.value, chunk[0 .. want]);
        if (r.hasError)
            return ioErr!size_t(r);
        if (r.value == 0)
            break;
        if (done + r.value > size)
            return changed();
        put(sink, cast(const(ubyte)[]) chunk[0 .. r.value]);
        done += r.value;
    }
    if (done != size)
        return changed();
    auto after = vfs.fstat(file.value, mask);
    if (after.hasError)
        return ioErr!size_t(after);
    if (!sameContents(before.value, after.value))
        return changed();
    return ioOk(done);
}

private IoResult!size_t changed() @safe pure nothrow @nogc
    => ioErr!size_t(ErrorKind.other, OpKind.read, 0, IoErrorStage.completion,
        "the file changed while it was read");

private bool sameContents(in Stat a, in Stat b) @safe pure nothrow @nogc
    => a.size == b.size && a.hasMtime == b.hasMtime && a.mtimeNs == b.mtimeNs
        && a.hasCtime == b.hasCtime && a.ctimeNs == b.ctimeNs;
