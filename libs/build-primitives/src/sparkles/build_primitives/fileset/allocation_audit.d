/**
The allocation audit of invariant 2 (SPEC.md §12): libc's allocation family
wrapped by the linker, and druntime's per-thread GC counter, sampled around
fileset evaluation.

Built only by `dub test :build-primitives -c allocation-audit` on Linux. The
expected count is zero for both.
*/
module sparkles.build_primitives.fileset.allocation_audit;

version (FilesetAllocationAudit)
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

    /// The resolution machine's steps, and the in-memory driver answering
    /// them, allocate nothing once both are made.
    @("fileset.allocation.resolutionStepsHaveZeroCalls")
    @system unittest
    {
        import core.memory : GC;

        import sparkles.base.vfs.handles : ambientAuthority, openRoot;
        import sparkles.build_primitives.fileset.driver : FilesetDriver, filesetRights;
        import sparkles.build_primitives.fileset.machine : Resolution, StepKind;
        import sparkles.build_primitives.fileset.pattern : CasePolicy;
        import sparkles.build_primitives.fileset.tree_literal : memTree;
        import sparkles.build_primitives.fileset.value : Filesets;
        import sparkles.base.vfs.mem : MemVfs;

        auto tree = memTree("src/a.d\nsrc/b/c.d\nsrc/b/run +x\nsrc/gen/x.d\ndocs/i.md\nvendor/v/w\n"
            ~ "e/\nbin/tool +x\nbin/notes\n");
        assert(!tree.hasError);
        auto root = openRoot!filesetRights(&tree.value.get().vfs, "", ambientAuthority());
        auto sets = Filesets(CasePolicy.sensitive);
        const f = sets.unionOf(
            sets.difference(sets.glob("src/**/*.d").value, sets.glob("gen/").value),
            sets.intersection(sets.glob("bin/*").value, sets.executable),
            sets.glob("vendor/").value, sets.glob("e/").value);
        auto m = Resolution(sets, f);
        auto driver = FilesetDriver!(MemVfs, filesetRights)(64);
        auto cursor = m.start();
        size_t members, units, empties;

        const gcBefore = GC.allocatedInCurrentThread();
        allocationCalls = 0;
        auditActive = true;
        for (;;)
        {
            StepKind kind;
            if (!m.step(sets, cursor, 2, kind))
                break;
            driver.retire(m.retired);
            if (kind == StepKind.done)
                break;
            if (kind == StepKind.needIO)
                foreach (i; 0 .. m.batch.length)
                    driver.perform(m, root.value.borrow, i);
            else if (kind == StepKind.unit)
            {
                ++units;
                foreach (name; m.unitMembers)
                    ++members;
                empties += m.unitEmpty;
            }
        }
        auditActive = false;
        const gcAfter = GC.allocatedInCurrentThread();

        assert(m.error.code == m.error.code.init, m.error.context);
        assert(members == 4); // src/a.d, src/b/c.d, bin/tool, vendor/v/w
        // `e`, and `docs` and `src/gen`: entered because the unanchored
        // `vendor/` and `e/` could still match beneath them, and memberless.
        assert(empties == 3);
        assert(units > 5);
        assert(allocationCalls == 0, "a resolution step called the libc allocator");
        assert(gcAfter == gcBefore, "a resolution step allocated on the GC heap");
    }

    @("fileset.allocation.evaluationHasZeroCalls")
    @system unittest
    {
        import core.memory : GC;
        import core.stdc.stdlib : free, malloc;

        import sparkles.build_primitives.fileset.pattern : CasePolicy;
        import sparkles.build_primitives.fileset.value : DirVerdict, EntryFacts, FileVerdict,
            FilesetEvaluator, Filesets;

        // Calibrate: without the --wrap flags this call would not be counted.
        allocationCalls = 0;
        auditActive = true;
        auto calibration = malloc(1);
        auditActive = false;
        assert(calibration !is null && allocationCalls == 1,
            "libc allocation wrapper is not active");
        free(calibration);

        // Building allocates; that is allowed.
        auto sets = Filesets(CasePolicy.insensitive);
        const f = sets.union_(
            sets.difference(sets.glob("src/**/*.{d,di}").value, sets.ignored("gen/\n*.o\n!keep.o\n").value),
            sets.intersection(sets.glob("bin/*").value, sets.executable));
        auto ev = FilesetEvaluator(sets, f);
        ulong[16] root, child, grand;

        const gcBefore = GC.allocatedInCurrentThread();
        allocationCalls = 0;
        auditActive = true;
        ev.rootState(sets, root[]);
        const v1 = ev.enter(sets, root[], "src", child[]);
        const v2 = ev.enter(sets, child[], "gen", grand[]);
        const v3 = ev.enter(sets, root[], "bin", grand[]);
        const fv = ev.fileVerdict(sets, grand[], "tool", EntryFacts.init);
        const c1 = ev.contains(sets, "src/a/b/c.D");
        const c2 = ev.contains(sets, "src/gen/c.d");
        const c3 = ev.contains(sets, "bin/café", true);
        const c4 = ev.contains(sets, "src/x/\xFF\xFE.d");
        auditActive = false;
        const gcAfter = GC.allocatedInCurrentThread();

        assert(v1 == DirVerdict.descend && v2 == DirVerdict.skip && v3 == DirVerdict.descend);
        assert(fv == FileVerdict.undecided);
        assert(c1 && !c2 && c3 && c4);
        assert(allocationCalls == 0, "fileset evaluation called the libc allocator");
        assert(gcAfter == gcBefore, "fileset evaluation allocated on the GC heap");
    }
}
