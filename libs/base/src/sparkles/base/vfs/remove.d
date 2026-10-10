/**
Tree removal over held handles (VFD1–VFD5, VFP8).

`removeTree` keeps the directories it descends into on an explicit stack of at
most `maxRemovalDepth` handles, not on the call stack (VFD1). It classifies
each entry by opening it as a directory without following it, so a link is
removed as an entry and never entered (VFD2); it lists each directory through
its own handle and lists it again until a listing yields nothing (VFD3); an
entry that vanished meanwhile is not an error (VFD4); and any other failure
stops it with the entries already removed staying removed (VFD5).
*/
module sparkles.base.vfs.remove;

import sparkles.base.io.errors : ErrorKind, IoError, IoResult, OpKind, ioErr, ioOk;
import sparkles.base.vfs.concept : isVfs;
import sparkles.base.vfs.types : EntryKind, StatMask, maxNameLength, maxRemovalDepth;

/// Removes `name` in `dir` and, if it is a directory, everything beneath it.
IoResult!void removeTreeAt(V, H)(ref V vfs, H dir, scope const(char)[] name,
    bool crossMounts)
if (isVfs!V && is(H == V.Handle))
{
    Removal!V r = Removal!V(&vfs, dir, crossMounts);
    return r.run(name);
}

private struct Frame(V)
{
    V.Handle handle;
    ubyte nameLength;
    ubyte relists; // times it was listed again after rmdir found it not empty
    char[maxNameLength] name;
}

/// How often `removeTree` lists a directory again when entries keep appearing
/// in it, before it reports `notEmpty`.
enum size_t maxRelists = 16;

private struct Removal(V)
{
    V* vfs;
    V.Handle dir;
    bool crossMounts;
    Frame!V[maxRemovalDepth] frames;
    size_t depth;

    @disable this(this);

    this(V* vfs, V.Handle dir, bool crossMounts)
    {
        this.vfs = vfs;
        this.dir = dir;
        this.crossMounts = crossMounts;
    }

    IoResult!void run(scope const(char)[] name) scope
    {
        const first = enter(dir, name);
        if (first.kind == ErrorKind.notFound || first.kind == ErrorKind.notADirectory)
            return ioOk(); // vanished, or a non-directory now removed
        if (first.kind != ErrorKind.other)
            return fail(first);

        char[maxNameLength] entryName;
        while (depth > 0)
        {
            auto top = &frames[depth - 1];
            auto listing = vfs.openListing(top.handle);
            if (listing.hasError)
                return fail(listing.error);

            bool removedAny, descended;
            IoError failure = IoError(ErrorKind.other);
            while (true)
            {
                size_t length;
                EntryKind kind;
                auto more = vfs.nextEntry(listing.value, entryName[], length, kind);
                if (more.hasError)
                {
                    failure = more.error;
                    break;
                }
                if (!more.value)
                    break;
                const step = enter(top.handle, entryName[0 .. length]);
                if (step.kind == ErrorKind.other)
                {
                    descended = true; // a directory: descend before listing further
                    break;
                }
                if (step.kind == ErrorKind.notADirectory)
                {
                    removedAny = true;
                    continue;
                }
                if (step.kind != ErrorKind.notFound)
                {
                    failure = step;
                    break;
                }
            }
            vfs.closeListing(listing.value);
            if (failure.kind != ErrorKind.other)
                return fail(failure);
            if (descended || removedAny)
                continue; // VFD3: list again until a listing yields nothing

            // Empty: remove it from its parent while still holding it.
            const parent = depth >= 2 ? frames[depth - 2].handle : dir;
            char[maxNameLength] nameCopy;
            const own = nameCopy[0 .. top.nameLength];
            nameCopy[0 .. top.nameLength] = top.name[0 .. top.nameLength];
            auto gone = vfs.rmdirAt(parent, own);
            if (gone.hasError && gone.error.kind == ErrorKind.notEmpty
                && top.relists++ < maxRelists)
                continue; // entries appeared meanwhile: list it again (VFD3)
            vfs.close(top.handle);
            --depth;
            if (!gone.hasError || gone.error.kind == ErrorKind.notFound)
                continue;
            if (gone.error.kind != ErrorKind.notADirectory)
                return fail(gone.error);
            // The name now holds a non-directory. Below the top, listing the
            // parent again classifies it; at the top, classify it here.
            if (depth == 0)
            {
                const again = enter(dir, own);
                if (again.kind != ErrorKind.other && again.kind != ErrorKind.notADirectory
                    && again.kind != ErrorKind.notFound)
                    return fail(again);
            }
        }
        return ioOk();
    }

    /*
    Classifies `name` in `parent`. A directory is pushed and `other` returned;
    a non-directory is unlinked and `notADirectory` returned; `notFound` means
    it vanished; any other kind is the failure.
    */
    IoError enter(V.Handle parent, scope const(char)[] name) scope
    {
        auto opened = vfs.openDirAt(parent, name);
        if (opened.hasError)
        {
            const k = opened.error.kind;
            if (k == ErrorKind.symlinkRefused || k == ErrorKind.notADirectory)
            {
                auto u = vfs.unlinkAt(parent, name);
                if (u.hasError && u.error.kind != ErrorKind.notFound)
                    return u.error;
                return IoError(ErrorKind.notADirectory);
            }
            return opened.error;
        }
        if (!crossMounts)
        {
            auto outer = vfs.fstat(parent, StatMask.basic);
            auto inner = vfs.fstat(opened.value, StatMask.basic);
            if (outer.hasError || inner.hasError || outer.value.device != inner.value.device)
            {
                vfs.close(opened.value);
                return outer.hasError ? outer.error : inner.hasError ? inner.error
                    : IoError(ErrorKind.crossesMount, 0, OpKind.openAt);
            }
        }
        if (depth == maxRemovalDepth)
        {
            vfs.close(opened.value);
            return IoError(ErrorKind.depthExceeded, 0, OpKind.openAt);
        }
        auto f = &frames[depth++];
        f.handle = opened.value;
        f.relists = 0;
        f.nameLength = cast(ubyte) name.length;
        f.name[0 .. name.length] = name[];
        return IoError(ErrorKind.other);
    }

    IoResult!void fail(IoError e) scope
    {
        while (depth > 0)
            vfs.close(frames[--depth].handle);
        return ioErr!void(e);
    }
}
