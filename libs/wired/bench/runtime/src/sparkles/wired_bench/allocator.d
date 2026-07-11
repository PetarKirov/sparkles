/**
Allocator field leveling for the benchmark process.

Each timed parse allocates a multi-MB document arena that the untimed
`after`/`teardown` frees. By default glibc trims blocks above its dynamic
mmap threshold back to the kernel on `free`, so a parse-in-a-loop can
refault the whole arena every iteration — and whether an engine pays
depends on its allocation pattern (one block vs several, sizes relative
to the sliding threshold), not on parser quality. glibc's dynamic
threshold eventually self-levels a steady single-size loop, but not
immediately and not uniformly across engines.

Raising the trim/mmap thresholds to 64 MiB at process start makes page
faults a first-iteration cost for every engine equally (standard practice
in parser benchmarking; a jemalloc/mimalloc swap does the same
implicitly). This restores what the pre-runner executable harness did in
its `main`; the disclosure lives in $(MREF sparkles,wired_bench,provenance).
*/
module sparkles.wired_bench.allocator;

version (linux)
{
    private extern (C) int mallopt(int param, int value) nothrow @nogc;

    // <malloc.h>: M_TRIM_THRESHOLD trims the top of the heap on free;
    // M_MMAP_THRESHOLD is the size above which allocations use mmap (and
    // are munmap'd on free — the refault source).
    private enum M_TRIM_THRESHOLD = -1;
    private enum M_MMAP_THRESHOLD = -3;
    private enum thresholdBytes = 64 * 1024 * 1024;

    /// Whether the leveling was applied (both mallopt calls succeeded) —
    /// read by the provenance line.
    package shared bool allocatorLevelled;

    shared static this()
    {
        const a = mallopt(M_TRIM_THRESHOLD, thresholdBytes);
        const b = mallopt(M_MMAP_THRESHOLD, thresholdBytes);
        allocatorLevelled = (a == 1 && b == 1);
    }
}
else
{
    /// Off Linux the leveling is a no-op; the field stays false.
    package shared bool allocatorLevelled;
}

version (linux)
@("allocator.levelingApplied")
@system unittest
{
    // The module's `shared static this()` runs at process start; by the
    // time any test runs, the leveling must have been applied (both
    // mallopt calls return 1 on glibc).
    assert(allocatorLevelled,
        "allocator field leveling did not apply — mallopt failed?");
}
