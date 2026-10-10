/**
The backend concept (VFB1–VFB3): what a type must provide for the capability
VFS's handles and algorithms to run over it.

A backend is a set of single-name primitives over `(V.Handle, name)`, each
returning an `IoResult` when the operation completes (VFB2). Lexical checks,
rights and policy live above the backend; a primitive does exactly the system
call (or its in-memory equivalent) it names, never follows the named entry
(VFO2), and classifies its failure itself (VFN1).

Primitives:

$(TABLE
$(TR $(TH Primitive) $(TH Result))
$(TR $(TD `openRootDir(path)`) $(TD the ambient open behind `openRoot`; follows links))
$(TR $(TD `openDirAt(dir, name)`) $(TD a directory handle; `symlinkRefused` for a link))
$(TR $(TD `reopen(dir)`) $(TD a new handle to the same directory, by opening `.`))
$(TR $(TD `openFileAt(dir, name, mode, sharing)`) $(TD a file handle))
$(TR $(TD `mkdirAt(dir, name, sharing)`) $(TD nothing))
$(TR $(TD `statAt(dir, name, mask)`, `fstat(h, mask)`) $(TD a `Stat`))
$(TR $(TD `readlinkAt(dir, name, buffer)`) $(TD the target's length, written to `buffer`))
$(TR $(TD `symlinkAt(dir, name, target)`) $(TD nothing))
$(TR $(TD `unlinkAt`, `rmdirAt`) $(TD nothing))
$(TR $(TD `renameAt(dir, name, dstDir, dstName)`) $(TD nothing))
$(TR $(TD `openListing(dir)`) $(TD a `V.Listing` independent of every other))
$(TR $(TD `nextEntry(listing, buffer, nameLength, kind)`) $(TD `false` at the end))
$(TR $(TD `closeListing(listing)`) $(TD nothing; cannot fail))
$(TR $(TD `read`, `write`) $(TD a byte count))
$(TR $(TD `sync`, `close`) $(TD nothing))
)

Optional: `bool wholePathFor(ResolvePolicy)` with
`resolveWhole(dir, path, policy)`, a kernel resolver (VFB3); and
`MountCheck mountCheckFor(ResolvePolicy)`.
*/
module sparkles.base.vfs.concept;

import sparkles.base.io.errors : IoResult;
import sparkles.base.vfs.types : EntryKind, MountCheck, OpenMode, ResolvePolicy, Sharing,
    Stat, StatMask;

/// Whether `V` is a capability VFS backend (VFB1).
enum isVfs(V) = is(V.Handle) && is(V.Listing) && __traits(compiles, (
        ref V v, V.Handle h, ref V.Listing l, scope const(char)[] n, scope char[] buf,
        scope ubyte[] data, scope const(ubyte)[] cdata, Sharing s, OpenMode m, StatMask mask) {
    IoResult!(V.Handle) root = v.openRootDir(n);
    IoResult!(V.Handle) dir = v.openDirAt(h, n);
    IoResult!(V.Handle) again = v.reopen(h);
    IoResult!(V.Handle) file = v.openFileAt(h, n, m, s);
    IoResult!void mk = v.mkdirAt(h, n, s);
    IoResult!Stat st = v.statAt(h, n, mask);
    IoResult!Stat fst = v.fstat(h, mask);
    IoResult!size_t link = v.readlinkAt(h, n, buf);
    IoResult!void sym = v.symlinkAt(h, n, n);
    IoResult!void ul = v.unlinkAt(h, n);
    IoResult!void rd = v.rmdirAt(h, n);
    IoResult!void rn = v.renameAt(h, n, h, n);
    IoResult!(V.Listing) lst = v.openListing(h);
    size_t len;
    EntryKind kind;
    IoResult!bool more = v.nextEntry(l, buf, len, kind);
    v.closeListing(l);
    IoResult!size_t r = v.read(h, data);
    IoResult!size_t w = v.write(h, cdata);
    IoResult!void sy = v.sync(h);
    IoResult!void cl = v.close(h);
});

/// Whether `V` offers a whole-path resolver (VFB3).
enum hasWholePathResolver(V) = __traits(compiles, (ref V v, V.Handle h,
        scope const(char)[] path, ResolvePolicy p) {
    bool b = v.wholePathFor(p);
    IoResult!(V.Handle) r = v.resolveWhole(h, path, p);
});

/// The mount check a backend reports for a policy (VFR2): its own answer if
/// it declares one, otherwise a device comparison when crossings are refused.
MountCheck mountCheckOf(V)(ref V vfs, ResolvePolicy policy)
{
    static if (__traits(compiles, vfs.mountCheckFor(policy)))
        return vfs.mountCheckFor(policy);
    else
        return policy.crossMounts ? MountCheck.none : MountCheck.racy;
}

/// Whether `V` can open a directory for search only (VFN14):
/// `openSearchAt(dir, name)`, used by the walk for the directories it passes
/// through.
enum hasSearchOpen(V) = __traits(compiles, (ref V v, V.Handle h, scope const(char)[] n) {
    IoResult!(V.Handle) r = v.openSearchAt(h, n);
});

/// Whether the kernel resolver `vfs` chose for a root has since been found
/// withdrawn (VFR5): the backend's `wholePathWithdrawn()`, or false.
bool resolverWithdrawn(V)(ref V vfs)
{
    static if (__traits(compiles, vfs.wholePathWithdrawn()))
        return vfs.wholePathWithdrawn();
    else
        return false;
}
