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
        import sparkles.build_primitives.fileset.value : Fileset, Filesets;
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

    /// The same, for a fileset with `.gitignore` scopes: reading, parsing and
    /// applying them, and tracing their decisions, allocate nothing either
    /// (FSI2, invariant 2).
    @("fileset.allocation.scopedResolutionHasZeroCalls")
    @system unittest
    {
        import core.memory : GC;

        import sparkles.base.vfs.handles : ambientAuthority, openRoot;
        import sparkles.base.vfs.mem : MemVfs;
        import sparkles.base.vfs.types : Rights;
        import sparkles.build_primitives.fileset.driver : FilesetDriver;
        import sparkles.build_primitives.fileset.machine : Resolution, ResolutionLimits, StepKind;
        import sparkles.build_primitives.fileset.pattern : CasePolicy;
        import sparkles.build_primitives.fileset.tree_literal : memTree;
        import sparkles.build_primitives.fileset.value : Fileset, Filesets;

        auto tree = memTree(`.gitignore = *.log\nbuild/\n*.{o,a}
            a.log
            build/x.c
            src/.gitignore = !*.log\n/gen/
            src/a.log
            src/gen/g.d
            src/x.d
            src/y.{o,a}
            lib/z/.gitignore = *.d
            lib/z/w.d
            lib/z/w.c
        `);
        assert(!tree.hasError);
        auto root = openRoot!(Rights.readOnly)(&tree.value.get().vfs, "", ambientAuthority());
        auto sets = Filesets(CasePolicy.sensitive);
        const f = sets.difference(sets.everything, sets.gitignored);
        auto m = Resolution(sets, f, ResolutionLimits.init, false, true);
        auto driver = FilesetDriver!(MemVfs, Rights.readOnly)(64);
        auto cursor = m.start();
        size_t members, decisions;

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
                foreach (name; m.unitMembers)
                    ++members;
            else if (kind == StepKind.ignoreDecision)
                decisions += m.decisionLine + m.decisionSource.length > 0;
        }
        auditActive = false;
        const gcAfter = GC.allocatedInCurrentThread();

        assert(m.error.code == m.error.code.init, m.error.context);
        // .gitignore, src/.gitignore, src/a.log, src/x.d, lib/z/.gitignore, lib/z/w.c
        assert(members == 6);
        // a.log, build, src/a.log, src/gen, src/y.{o,a}, lib/z/w.d
        assert(decisions == 6);
        assert(allocationCalls == 0, "a scoped resolution step called the libc allocator");
        assert(gcAfter == gcBefore, "a scoped resolution step allocated on the GC heap");
    }

    /// The same, for a fold declaring every metadata kind and an order to
    /// sort by: stats, link reads, sorting units and handing over the
    /// directories above the start roots allocate nothing either.
    @("fileset.allocation.foldResolutionHasZeroCalls")
    @system unittest
    {
        import core.memory : GC;

        import sparkles.base.vfs.handles : ambientAuthority, openRoot;
        import sparkles.base.vfs.mem : MemVfs;
        import sparkles.build_primitives.fileset.driver : FilesetDriver, filesetRights;
        import sparkles.build_primitives.fileset.fso : EntryOrder, FsoMetadata, FsoNode, SchemeShape,
            Traversal;
        import sparkles.build_primitives.fileset.machine : Resolution, ResolutionLimits, StepKind;
        import sparkles.build_primitives.fileset.pattern : CasePolicy;
        import sparkles.build_primitives.fileset.tree_literal : memTree;
        import sparkles.build_primitives.fileset.value : Fileset, Filesets;

        auto tree = memTree("lib/x/a.b\nlib/x/a/c\nlib/x/run +x\nlib/x/l -> a/c\nsrc/z.d\nsrc/q/r.d\n");
        assert(!tree.hasError);
        auto root = openRoot!filesetRights(&tree.value.get().vfs, "", ambientAuthority());
        auto sets = Filesets(CasePolicy.sensitive);
        const f = sets.union_(sets.glob("lib/x/").value, sets.glob("src/**/*.d").value);
        const shape = SchemeShape(EntryOrder.gitTreeOrder,
            cast(FsoMetadata)(FsoMetadata.executable | FsoMetadata.mtime | FsoMetadata.linkTarget),
            Traversal.fold);
        auto m = Resolution(sets, f, ResolutionLimits.init, false, false, shape);
        auto driver = FilesetDriver!(MemVfs, filesetRights)(64);
        auto cursor = m.start();
        size_t units, entries, targets, executables;

        const gcBefore = GC.allocatedInCurrentThread();
        allocationCalls = 0;
        auditActive = true;
        for (;;)
        {
            StepKind kind;
            if (!m.step(sets, cursor, 2, kind))
                break;
            if (kind != StepKind.unit)
                driver.retire(m.retired);
            if (kind == StepKind.done)
                break;
            if (kind == StepKind.needIO)
                foreach (i; 0 .. m.batch.length)
                    driver.perform(m, root.value.borrow, i);
            else if (kind == StepKind.unit)
            {
                ++units;
                foreach (e; m.unitEntries)
                {
                    ++entries;
                    targets += e.node.target.length > 0;
                    executables += e.node.executable;
                }
                driver.retire(m.retired);
            }
        }
        auditActive = false;
        const gcAfter = GC.allocatedInCurrentThread();

        assert(m.error.code == m.error.code.init, m.error.context);
        // lib/x/a, lib/x, lib, src/q, src, and the fileset root
        assert(units == 6);
        // c; a.b a l run; x; r.d; q z.d; lib src
        assert(entries == 11);
        assert(targets == 1 && executables == 1);
        assert(allocationCalls == 0, "a fold's resolution step called the libc allocator");
        assert(gcAfter == gcBefore, "a fold's resolution step allocated on the GC heap");
    }

    // `S`, counting what its own calls allocate: only the scheme's work is
    // in the window, not the resolution's around it.
    private struct Audited(S)
    {
        import sparkles.base.io.errors : ErrorKind;
        import sparkles.build_primitives.fileset.fso : Traversal;
        import sparkles.build_primitives.fileset.scheme : shapeOf;

        S* inner;
        size_t gcBytes;
        private ulong gcMark;

        enum order = shapeOf!S.order;
        enum metadata = shapeOf!S.metadata;
        enum traversal = shapeOf!S.traversal;
        alias Result = S.Result;

        static if (traversal == Traversal.fold)
        {
            alias Value = S.Value;

            bool fold(Entries, Exec)(scope const(char)[] path, Entries entries, bool empty,
                ref Exec exec, out Value value)
            {
                open();
                scope (exit) close();
                return inner.fold(path, entries, empty, exec, value);
            }

            Result finish(ref Value root)
            {
                open();
                scope (exit) close();
                return inner.finish(root);
            }
        }
        else
        {
            bool visit(Entries, Exec)(scope const(char)[] path, Entries entries, bool empty,
                ref Exec exec)
            {
                open();
                scope (exit) close();
                return inner.visit(path, entries, empty, exec);
            }

            static if (shapeOf!S.leave)
                bool leave(Exec)(scope const(char)[] path, ref Exec exec)
                {
                    open();
                    scope (exit) close();
                    return inner.leave(path, exec);
                }

            Result finish()
            {
                open();
                scope (exit) close();
                return inner.finish();
            }
        }

        bool incomplete(scope const(char)[] path, ErrorKind kind) => inner.incomplete(path, kind);

        string failure() const => inner.failure;

        private void open()
        {
            import core.memory : GC;

            gcMark = GC.allocatedInCurrentThread();
            auditActive = true;
        }

        private void close()
        {
            import core.memory : GC;

            auditActive = false;
            gcBytes += GC.allocatedInCurrentThread() - gcMark;
        }
    }

    /// CAM5: once a scheme's buffers hold the tree's largest directory and
    /// deepest path, encoding directories and reading files allocate
    /// nothing: castore, git, NAR and the tee of castore and NAR, each in a
    /// second resolution of the same tree, through the same scheme.
    @("content_addressing.allocation.secondResolutionHasZeroCalls")
    @system unittest
    {
        import std.conv : text;
        import std.digest.sha : SHA1, SHA256;

        import sparkles.base.vfs.handles : ambientAuthority, openRoot;
        import sparkles.base.vfs.types : Rights;
        import sparkles.build_primitives.content_addressing.castore : CastoreScheme;
        import sparkles.build_primitives.content_addressing.git : GitTreeScheme;
        import sparkles.build_primitives.content_addressing.nar : CastoreNar, NarScheme;
        import sparkles.build_primitives.content_addressing.testing : LiteralRef;
        import sparkles.build_primitives.fileset.pattern : CasePolicy;
        import sparkles.build_primitives.fileset.scheme : resolveScheme;
        import sparkles.build_primitives.fileset.testing : RecordingExecutor;
        import sparkles.build_primitives.fileset.tree_literal : memTree;
        import sparkles.build_primitives.fileset.value : Fileset, Filesets;

        // `wide` outgrows every inline buffer, so the first resolution grows them.
        string literal = "src/a.d = module a;\nsrc/deep/er/still/b.d = b\nsrc/run +x = #!\n"
            ~ "src/l -> deep\nempty/\nhollow/inner/\nz = last\n";
        foreach (i; 0 .. 300)
            literal ~= text("wide/a-rather-long-file-name-", i, " = ", i, "\n");
        auto tree = memTree(literal, spareBytes: 64 * 1024);
        assert(!tree.hasError);
        auto vfs = &tree.value.get().vfs;
        // Larger than one read, so a file takes several.
        auto big = new ubyte[](40_000);
        foreach (i, ref b; big)
            b = cast(ubyte) i;
        assert(vfs.writeFile("src/deep/big", big));
        auto root = openRoot!(Rights.readOnly)(vfs, "", ambientAuthority());
        assert(!root.hasError);
        auto sets = Filesets(CasePolicy.sensitive);
        const f = sets.everything;

        static void auditTwice(S)(typeof(root.value.borrow()) dir, ref const Filesets sets, Fileset f)
        {
            S scheme;
            S.Result first;
            foreach (run; 0 .. 2)
            {
                RecordingExecutor exec;
                auto audited = Audited!S(&scheme);
                allocationCalls = 0;
                const r = resolveScheme(dir, sets, f, audited, exec);
                assert(!r.hasError, r.hasError ? r.error.context : "");
                if (run == 0)
                {
                    assert(allocationCalls + audited.gcBytes > 0,
                        S.stringof ~ ": the first resolution grew nothing, so the audit proves nothing");
                    first = r.value;
                    continue;
                }
                assert(r.value == first, S.stringof ~ ": the second resolution differs");
                assert(allocationCalls == 0, text(S.stringof, ": ", allocationCalls,
                    " libc allocations in the second resolution"));
                assert(audited.gcBytes == 0, text(S.stringof, ": ", audited.gcBytes,
                    " GC bytes in the second resolution"));
            }
        }

        auditTwice!CastoreScheme(root.value.borrow, sets, f);
        auditTwice!(GitTreeScheme!SHA1)(root.value.borrow, sets, f);
        auditTwice!(NarScheme!(SHA256, LiteralRef))(root.value.borrow, sets, f);
        auditTwice!(CastoreNar!LiteralRef)(root.value.borrow, sets, f);
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
