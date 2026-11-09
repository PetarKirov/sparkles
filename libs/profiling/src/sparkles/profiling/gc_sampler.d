/**
Where a program's GC allocations come from, and what of them stays live.

A garbage collector, registered as `sampler`, that forwards everything to
druntime's conservative collector and records a stack every
`SPARKLES_GC_SAMPLE_BYTES` (64 KiB by default) allocated, the collections
with their pauses, and, after each collection, which sampled blocks survived
it and whether the collector scans them. Run a program that links this module
with

---
SPARKLES_GC_SAMPLES=out.gcs ./program --DRT-gcopt=gc:sampler
---

and summarize `out.gcs` with `ci --gc-report out.gcs --gc-exe ./program`.
Nothing is recorded, and the collector is druntime's own, unless a run
selects `gc:sampler`.

The file is text, one record a line; a frame is `module@offset`, the module's
path and the return address's offset into it (for `addr2line`):

$(UL
    $(LI `# total BYTES allocs COUNT collections COUNT` — the header.)
    $(LI `S BYTES COUNT FRAME...` — a sample: the bytes and allocations since
        the last one, and the stack of the allocation that crossed the
        interval. Each sample stands for its bytes, so summing them by site
        attributes every byte allocated.)
    $(LI `C ALLOCATED MICROSECONDS FRAME...` — a collection: the bytes
        allocated before it, its pause, and the stack of the allocation that
        set it off.)
    $(LI `L BYTES SCANNED FRAME...` — a sampled block live after the last
        collection, standing for its sample's bytes; `SCANNED` is `1` when
        the collector scans it for pointers, `0` when it does not.)
)

Linux only (glibc's `backtrace`); elsewhere the module is empty and
`gcSamplerAvailable` is `false`.
*/
module sparkles.profiling.gc_sampler;

version (linux) version = SparklesGcSampler;

/// Whether this platform has the `sampler` collector.
version (SparklesGcSampler)
    enum bool gcSamplerAvailable = true;
else
    enum bool gcSamplerAvailable = false;

version (SparklesGcSampler):

import core.gc.gcinterface : GC, BlkInfo, RootIterator, RangeIterator;
import core.gc.registry : createGCInstance, registerGCFactory;
import core.memory : GCStats = GC;
import core.thread.threadbase : ThreadBase;
import core.atomic : atomicStore, cas;
import core.stdc.stdlib : getenv, malloc, realloc, strtoull;
import core.stdc.stdio : FILE, fopen, fclose, fprintf, fputc;
import core.sys.linux.execinfo : backtrace;
import core.sys.linux.dlfcn : dladdr, Dl_info;
import core.time : MonoTime;

/**
Marks the module as used, so a program that links it as part of a static
library keeps it, and with it the collector's registration. `sparkles:ui-app`
calls it; any other program calls it once, anywhere.
*/
pragma(inline, false) void linkGcSampler() @safe pure nothrow @nogc {}

private:

enum depth = 28;

struct Sample
{
    size_t bytes;
    uint count;
    uint frames;
    void*[depth] stack;
    void* base;      // the sampled block, while it lives
    uint attributes; // its attributes at the last census
    bool dead, counted;
}

__gshared Sample* samples;
__gshared size_t sampleCount, sampleCapacity;
__gshared Sample* collections;
__gshared size_t collectionCount, collectionCapacity;
__gshared size_t interval = 64 * 1024, pending, pendingCount, totalBytes, totalCount;
__gshared size_t seenCollections;
shared bool busy;

Sample* push(ref Sample* array, ref size_t length, ref size_t capacity) nothrow @nogc
{
    if (length == capacity)
    {
        capacity = capacity ? capacity * 2 : 4096;
        array = cast(Sample*) realloc(array, capacity * Sample.sizeof);
    }
    auto s = &array[length++];
    *s = Sample.init;
    return s;
}

// Counts an allocation; returns the sample it completes, or null.
Sample* note(size_t size) nothrow @nogc
{
    while (!cas(&busy, false, true)) {}
    scope (exit) atomicStore(busy, false);
    totalBytes += size;
    ++totalCount;
    pending += size;
    ++pendingCount;
    if (pending < interval)
        return null;
    auto s = push(samples, sampleCount, sampleCapacity);
    s.bytes = pending;
    s.count = cast(uint) pendingCount;
    s.frames = backtrace(s.stack.ptr, depth);
    pending = 0;
    pendingCount = 0;
    return s;
}

// After an allocation: which sampled blocks the collection it ran (if any)
// left alive, and what it cost.
void afterAllocation(GC inner, Sample* sample, void* block, long started) nothrow
{
    if (sample !is null && block !is null)
        sample.base = inner.addrOf(block);
    const n = inner.profileStats().numCollections;
    if (n == seenCollections)
        return;
    seenCollections = n;
    auto c = push(collections, collectionCount, collectionCapacity);
    c.bytes = totalBytes;
    c.count = cast(uint) ((MonoTime.currTime.ticks - started) * 1_000_000 / MonoTime.ticksPerSecond);
    c.frames = backtrace(c.stack.ptr, depth);
    foreach (ref s; samples[0 .. sampleCount])
    {
        if (s.dead || s.base is null)
            continue;
        const info = inner.query(s.base);
        if (info.base !is s.base)
        {
            s.dead = true;
            continue;
        }
        s.attributes = info.attr;
        s.counted = true;
    }
}

final class Sampler : GC
{
    GC inner;
    this(GC inner) nothrow @nogc { this.inner = inner; }

    static long now() nothrow @nogc => MonoTime.currTime.ticks;

    void* malloc(size_t size, uint bits, const TypeInfo ti) nothrow
    {
        auto s = note(size);
        const t = now();
        auto p = inner.malloc(size, bits, ti);
        afterAllocation(inner, s, p, t);
        return p;
    }
    BlkInfo qalloc(size_t size, uint bits, const scope TypeInfo ti) nothrow
    {
        auto s = note(size);
        const t = now();
        auto b = inner.qalloc(size, bits, ti);
        afterAllocation(inner, s, b.base, t);
        return b;
    }
    void* calloc(size_t size, uint bits, const TypeInfo ti) nothrow
    {
        auto s = note(size);
        const t = now();
        auto p = inner.calloc(size, bits, ti);
        afterAllocation(inner, s, p, t);
        return p;
    }
    void* realloc(void* p, size_t size, uint bits, const TypeInfo ti) nothrow
    {
        auto s = note(size);
        const t = now();
        auto q = inner.realloc(p, size, bits, ti);
        afterAllocation(inner, s, q, t);
        return q;
    }
    // In-place growth counts what it adds to the block: `extend` asked for
    // directly, or an append (`expandArrayUsed`) that grew a large block's
    // pages. An append within the block's capacity adds nothing.
    size_t extend(void* p, size_t minSize, size_t maxSize, const TypeInfo ti) nothrow
    {
        const before = inner.query(p).size;
        const after = inner.extend(p, minSize, maxSize, ti);
        if (after > before)
            note(after - before);
        return after;
    }

    void enable() { inner.enable(); }
    void disable() { inner.disable(); }
    void collect() nothrow { inner.collect(); }
    void minimize() nothrow { inner.minimize(); }
    uint getAttr(void* p) nothrow => inner.getAttr(p);
    uint setAttr(void* p, uint mask) nothrow => inner.setAttr(p, mask);
    uint clrAttr(void* p, uint mask) nothrow => inner.clrAttr(p, mask);
    size_t reserve(size_t size) nothrow => inner.reserve(size);
    void free(void* p) nothrow @nogc { inner.free(p); }
    void* addrOf(void* p) nothrow @nogc => inner.addrOf(p);
    size_t sizeOf(void* p) nothrow @nogc => inner.sizeOf(p);
    BlkInfo query(void* p) nothrow => inner.query(p);
    GCStats.Stats stats() @safe nothrow @nogc => inner.stats();
    GCStats.ProfileStats profileStats() @safe nothrow @nogc => inner.profileStats();
    void addRoot(void* p) nothrow @nogc { inner.addRoot(p); }
    void removeRoot(void* p) nothrow @nogc { inner.removeRoot(p); }
    @property RootIterator rootIter() @nogc => inner.rootIter;
    void addRange(void* p, size_t size, const TypeInfo ti) nothrow @nogc { inner.addRange(p, size, ti); }
    void removeRange(void* p) nothrow @nogc { inner.removeRange(p); }
    @property RangeIterator rangeIter() @nogc => inner.rangeIter;
    void runFinalizers(const scope void[] segment) nothrow { inner.runFinalizers(segment); }
    bool inFinalizer() nothrow @nogc @safe => inner.inFinalizer();
    ulong allocatedInCurrentThread() nothrow => inner.allocatedInCurrentThread();
    void[] getArrayUsed(void* p, bool atomic = false) nothrow => inner.getArrayUsed(p, atomic);
    bool expandArrayUsed(void[] slice, size_t newUsed, bool atomic = false) nothrow @trusted
    {
        const before = inner.query(slice.ptr).size;
        const grown = inner.expandArrayUsed(slice, newUsed, atomic);
        const after = inner.query(slice.ptr).size;
        if (after > before)
            note(after - before);
        return grown;
    }
    size_t reserveArrayCapacity(void[] slice, size_t request, bool atomic = false) nothrow @safe
        => inner.reserveArrayCapacity(slice, request, atomic);
    bool shrinkArrayUsed(void[] slice, size_t existingUsed, bool atomic = false) nothrow
        => inner.shrinkArrayUsed(slice, existingUsed, atomic);
    void initThread(ThreadBase t) nothrow @nogc { inner.initThread(t); }
    void cleanupThread(ThreadBase t) nothrow @nogc { inner.cleanupThread(t); }
}

GC create()
{
    import core.lifetime : emplace;
    if (auto bytes = getenv("SPARKLES_GC_SAMPLE_BYTES"))
        if (const n = strtoull(bytes, null, 10))
            interval = cast(size_t) n;
    enum size = __traits(classInstanceSize, Sampler);
    auto memory = malloc(size)[0 .. size];
    return emplace!Sampler(memory, createGCInstance("conservative"));
}

pragma(crt_constructor) extern (C) void sparklesRegisterGcSampler()
{
    registerGCFactory("sampler", &create);
}

void writeStack(FILE* f, ref const Sample s) nothrow @nogc
{
    foreach (address; s.stack[0 .. s.frames])
    {
        Dl_info info;
        if (dladdr(address, &info) && info.dli_fname)
            fprintf(f, " %s@0x%zx", info.dli_fname,
                cast(size_t) address - cast(size_t) info.dli_fbase - 1);
        else
            fprintf(f, " ?@%p", address);
    }
    fputc('\n', f);
}

pragma(crt_destructor) extern (C) void sparklesWriteGcSamples()
{
    auto path = getenv("SPARKLES_GC_SAMPLES");
    if (path is null || sampleCount == 0)
        return;
    auto f = fopen(path, "w");
    if (f is null)
        return;
    fprintf(f, "# total %zu allocs %zu collections %zu\n", totalBytes, totalCount, collectionCount);
    foreach (ref s; samples[0 .. sampleCount])
    {
        fprintf(f, "S %zu %u", s.bytes, s.count);
        writeStack(f, s);
    }
    foreach (ref c; collections[0 .. collectionCount])
    {
        fprintf(f, "C %zu %u", c.bytes, c.count);
        writeStack(f, c);
    }
    enum noScan = 2; // `GC.BlkAttr.NO_SCAN`
    foreach (ref s; samples[0 .. sampleCount])
        if (s.counted && !s.dead)
        {
            fprintf(f, "L %zu %d", s.bytes, (s.attributes & noScan) ? 0 : 1);
            writeStack(f, s);
        }
    fclose(f);
}
