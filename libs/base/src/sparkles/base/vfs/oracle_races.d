/**
Oracle 2 of `docs/specs/base/vfs/testing.md`: scripted races, on `MemVfs`.

Each scenario changes the tree from the interleaving hook (VFM3) before one
backend call, and is run once for every call index the unraced operation
makes, so every single-point interleaving is covered. Each names the
outcomes it allows and the forbidden effect it must not produce. This proves
the resolver's logic under each interleaving; it does not prove that a real
kernel's interleavings are covered.
*/
module sparkles.base.vfs.oracle_races;

version (unittest):

import sparkles.base.vfs;
import sparkles.base.vfs.mem : testVfs;

private:

// Runs `scenario` once unraced to count its calls, then once per call index
// with `mutate` applied just before that call.
void sweep(Setup, Mutate, Run)(scope Setup setup, Mutate mutate, scope Run run)
{
    size_t calls;
    {
        auto v = testVfs();
        setup(v);
        v.resetCounts();
        const unraced = run(v);
        assert(unraced is null, "unraced: " ~ unraced);
        calls = cast(size_t) v.totalCalls;
    }
    foreach (k; 0 .. calls + 1)
    {
        auto v = testVfs();
        setup(v);
        v.resetCounts();
        bool fired;
        v.hook = (size_t index, ref MemVfs fs) @safe nothrow @nogc {
            if (index == k && !fired)
            {
                fired = true;
                mutate(fs);
            }
        };
        const problem = run(v);
        import std.conv : to;

        assert(problem is null, "race before call " ~ k.to!string ~ ": " ~ problem);
    }
}

string kindName(ErrorKind k) @safe
{
    import std.conv : to;

    return k.to!string;
}

ResolvePolicy policyOf(SymlinkPolicy s, DotDotPolicy d) @safe
{
    ResolvePolicy p;
    p.symlinks = s;
    p.dotDot = d;
    return p;
}

@("vfs.oracle2.R1.renameDuringDotDot")
@safe unittest
{
    // BI, walk("a/b/c/../../x") while a/b moves out of the root: the `..`
    // steps return to held handles, so the result is a/x or notFound, never
    // outside/x.
    sweep((MemVfs* v) { v.mkdirs("r/a/b/c"); v.mkdirs("r/a/x"); v.mkdirs("outside/x"); },
        (ref MemVfs fs) { fs.rename("r/a/b", "outside/b"); },
        (MemVfs* v) {
            auto root = openRoot!(Rights.all)(v, "r", ambientAuthority(),
                policyOf(SymlinkPolicy.beneath, DotDotPolicy.inScope));
            auto d = root.value.walk("a/b/c/../../x");
            if (d.hasError)
                return d.error.kind == ErrorKind.notFound ? null
                    : "unexpected " ~ kindName(d.error.kind);
            char[4096] buf;
            const at = v.pathOf(d.value.core.handle, buf);
            return at == "r/a/x" ? null : "landed on " ~ at.idup;
        });
}

@("vfs.oracle2.R2R3.linkSwappedIn")
@safe unittest
{
    static string check(MemVfs* v, SymlinkPolicy s, ErrorKind refusal)
    {
        auto root = openRoot!(Rights.all)(v, "r", ambientAuthority(),
            policyOf(s, DotDotPolicy.reject));
        v.clearTouched();
        auto d = root.value.walk("a/b");
        if (v.touched("outside"))
            return "touched the sentinel";
        if (!d.hasError)
            return null; // the swap came after `b` was opened
        return d.error.kind == refusal || d.error.kind == ErrorKind.notFound ? null
            : "unexpected " ~ kindName(d.error.kind);
    }

    static void setup(MemVfs* v) @safe
    {
        v.mkdirs("r/a/b");
        v.writeFile("outside/secret", null);
    }

    // R2 (N): symlinkRefused. R3 (B): escapesRoot.
    sweep(&setup, (ref MemVfs fs) { fs.remove("r/a/b"); fs.symlink("r/a/b", "/"); },
        (MemVfs* v) => check(v, SymlinkPolicy.none, ErrorKind.symlinkRefused));
    sweep(&setup, (ref MemVfs fs) { fs.remove("r/a/b"); fs.symlink("r/a/b", "/"); },
        (MemVfs* v) => check(v, SymlinkPolicy.beneath, ErrorKind.escapesRoot));
}

@("vfs.oracle2.R4R5R6.removalUnderChange")
@safe unittest
{
    static string removeT(MemVfs* v)
    {
        auto root = openRoot!(Rights.all)(v, "r", ambientAuthority());
        auto r = root.value.removeTree("t");
        if (r.hasError)
            return "removeTree failed: " ~ kindName(r.error.kind);
        if (v.exists("r/t"))
            return "t survived";
        if (v.contents("outside/secret") != cast(const(ubyte)[]) "secret")
            return "the sentinel changed";
        return null;
    }

    // R4: a directory replaced by a link to outside: the link is removed,
    // never followed.
    sweep((MemVfs* v) { v.writeFile("r/t/d/f", null); v.writeFile("outside/secret", cast(const(ubyte)[]) "secret"); },
        (ref MemVfs fs) {
            if (fs.exists("r/t")) // a mutation after the removal would re-create t
            {
                fs.remove("r/t/d");
                fs.symlink("r/t/d", "../../outside");
            }
        },
        &removeT);
    // R5: an entry vanishes: not an error (VFD4).
    sweep((MemVfs* v) { v.writeFile("r/t/a", null); v.writeFile("r/t/b", null); v.writeFile("outside/secret", cast(const(ubyte)[]) "secret"); },
        (ref MemVfs fs) { fs.remove("r/t/b"); },
        &removeT);
    // R6: a directory replaced by a file: removed as an entry.
    sweep((MemVfs* v) { v.mkdirs("r/t/d"); v.writeFile("outside/secret", cast(const(ubyte)[]) "secret"); },
        (ref MemVfs fs) {
            if (fs.exists("r/t"))
            {
                fs.remove("r/t/d");
                fs.writeFile("r/t/d", null);
            }
        },
        &removeT);
}

@("vfs.oracle2.R7.rootMoved")
@safe unittest
{
    // The held root handle still names the directory after it moves.
    auto v = testVfs();
    v.mkdirs("r/a");
    auto root = openRoot!(Rights.all)(v, "r", ambientAuthority());
    assert(v.rename("r", "elsewhere/r"));
    assert(!root.value.walk("a").hasError);
}

@("vfs.oracle2.R8.mountDuringWalk")
@safe unittest
{
    sweep((MemVfs* v) { v.mkdirs("r/a/b"); },
        (ref MemVfs fs) { fs.mount("r/a/b"); },
        (MemVfs* v) {
            auto root = openRoot!(Rights.all)(v, "r", ambientAuthority());
            auto d = root.value.walk("a/b");
            return !d.hasError || d.error.kind == ErrorKind.crossesMount ? null
                : "unexpected " ~ kindName(d.error.kind);
        });
}

@("vfs.oracle2.R9.atomicWrite")
@safe unittest
{
    // A reader at every point of the write sees the old or the new content.
    string observed;
    sweep((MemVfs* v) { v.writeFile("r/f", cast(const(ubyte)[]) "old content"); },
        (ref MemVfs fs) {
            const c = fs.contents("r/f");
            if (c != cast(const(ubyte)[]) "old content" && c != cast(const(ubyte)[]) "new content!")
                observed = "mixed";
        },
        (MemVfs* v) {
            auto root = openRoot!(Rights.all)(v, "r", ambientAuthority());
            auto w = root.value.writeFileAtomic("f", "new content!");
            if (w.hasError)
                return "write failed: " ~ kindName(w.error.kind);
            if (observed !is null)
                return observed;
            return v.contents("r/f") == cast(const(ubyte)[]) "new content!" ? null : "wrong result";
        });
}
