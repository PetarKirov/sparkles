/**
The allocation check of `docs/specs/base/vfs/testing.md`, with libc wrapped.

Built only by `dub test :base -c allocation-audit` on Linux: the linker wraps
`malloc`, `calloc` and `realloc`, and the test counts their calls together
with druntime's per-thread GC counter around a run of VFS operations over a
pre-sized `MemVfs` arena. The expected count is zero for both.
*/
module sparkles.base.vfs.allocation_audit;

version (VfsAllocationAudit)
version (linux)
{
    // Module globals are thread-local, so parallel tests cannot contaminate
    // the counter this test samples on its own thread.
    private bool auditActive;
    private size_t allocationCalls;

    extern(C) void* __real_malloc(size_t size) @system nothrow @nogc;
    extern(C) void* __real_calloc(size_t count, size_t size) @system nothrow @nogc;
    extern(C) void* __real_realloc(void* pointer, size_t size) @system nothrow @nogc;

    private void observed() @safe nothrow @nogc
    {
        if (auditActive)
            ++allocationCalls;
    }

    extern(C) void* __wrap_malloc(size_t size) @system nothrow @nogc
    {
        observed();
        return __real_malloc(size);
    }

    extern(C) void* __wrap_calloc(size_t count, size_t size) @system nothrow @nogc
    {
        observed();
        return __real_calloc(count, size);
    }

    extern(C) void* __wrap_realloc(void* pointer, size_t size) @system nothrow @nogc
    {
        observed();
        return __real_realloc(pointer, size);
    }

    @("vfs.allocation.noLibcOrGcAllocation")
    @system unittest
    {
        import core.memory : GC;
        import core.stdc.stdlib : free, malloc;

        import sparkles.base.vfs;

        // Calibrate: without the --wrap flags this call would not be counted.
        allocationCalls = 0;
        auditActive = true;
        auto calibration = malloc(1);
        auditActive = false;
        assert(calibration !is null && allocationCalls == 1,
            "libc allocation wrapper is not active");
        free(calibration);

        auto nodes = new MemNode[128];
        auto bytes = new ubyte[8192];
        auto v = new MemVfs(nodes, bytes);
        v.writeFile("r/a/f", cast(const(ubyte)[]) "data");
        v.symlink("r/l", "a");

        static void exercise(MemVfs* v) @safe nothrow @nogc
        {
            ResolvePolicy beneath;
            beneath.symlinks = SymlinkPolicy.beneath;
            auto root = openRoot!(Rights.all)(v, "r", ambientAuthority(), beneath);
            auto d = root.value.walkAll("x/y");
            cast(void) d.value.writeFileAtomic("w", "payload");
            auto l = root.value.walk("l");
            char[32] names;
            auto listing = root.value.list(names[]);
            while (listing.value.next().value) {}
            cast(void) root.value.removeTree("x");
        }

        exercise(v);
        const gcBefore = GC.allocatedInCurrentThread();
        allocationCalls = 0;
        auditActive = true;
        exercise(v);
        auditActive = false;
        assert(allocationCalls == 0, "a VFS operation called a libc allocator");
        assert(GC.allocatedInCurrentThread() == gcBefore, "a VFS operation allocated on the GC heap");
    }
}
