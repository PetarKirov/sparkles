/** Linux linker-wrap audit for the allocation-free fuzzy keystroke path. */
module sparkles.fuzzy.allocation_audit;

version (FuzzyAllocationAudit)
version (linux)
{
    // Module globals are thread-local in D. Normal parallel unittests therefore
    // cannot contaminate this audit while it samples its own runner thread.
    private bool auditActive;
    private size_t allocationCalls;

    extern(C) void* __real_malloc(size_t size) @system nothrow @nogc;
    extern(C) void* __real_calloc(size_t count, size_t size)
        @system nothrow @nogc;
    extern(C) void* __real_realloc(void* pointer, size_t size)
        @system nothrow @nogc;

    private void observedAllocation() @safe nothrow @nogc
    {
        if (auditActive)
            ++allocationCalls;
    }

    extern(C) void* __wrap_malloc(size_t size) @system nothrow @nogc
    {
        observedAllocation();
        return __real_malloc(size);
    }

    extern(C) void* __wrap_calloc(size_t count, size_t size)
        @system nothrow @nogc
    {
        observedAllocation();
        return __real_calloc(count, size);
    }

    extern(C) void* __wrap_realloc(void* pointer, size_t size)
        @system nothrow @nogc
    {
        observedAllocation();
        return __real_realloc(pointer, size);
    }

    @("fuzzy.allocation.completeKeystrokeHasZeroCalls")
    @system
    unittest
    {
        import core.memory : GC;
        import core.stdc.stdlib : free, malloc;

        import sparkles.fuzzy.common : CandidateView, CorpusId,
            DefaultFuzzyCaps, PathFlavor, ProjectId, QueryId;
        import sparkles.fuzzy.glob : compileGlob, globMatch, GlobMatchWorkspace,
            GlobProgram;
        import sparkles.fuzzy.history : ComboTable, FrecencyTable;
        import sparkles.base.unique : makeUnique;
        import sparkles.fuzzy.match : MatcherWorkspace;
        import sparkles.fuzzy.query : ConstraintWorkspace, parseQuery;
        import sparkles.fuzzy.rank : RankedResult;
        import sparkles.fuzzy.search : CandidateSnapshot, SearchAccumulator,
            searchChunk, SearchLimits, SearchStop;

        // Calibrate the binary itself: without every DUB --wrap flag reaching
        // the linker this direct call would leave the counter at zero.
        allocationCalls = 0;
        auditActive = true;
        auto calibration = malloc(1);
        auditActive = false;
        assert(calibration !is null && allocationCalls == 1,
            "libc allocation wrapper is not active");
        free(calibration);

        CandidateView[1] candidates;
        candidates[0].id.low = 1;
        candidates[0].path
            = "libs/base/src/sparkles/base/text/unicode_tables.d";
        candidates[0].filenameOffset = 33;
        candidates[0].pathFlavor = PathFlavor.unix;
        CandidateSnapshot snapshot;
        snapshot.id = CorpusId(0, 91);
        snapshot.candidates = candidates[];

        SearchAccumulator!8 accumulator;
        auto matcherOwner = makeUnique!(MatcherWorkspace!())();
        ref MatcherWorkspace!() matcher() => matcherOwner.get();
        ConstraintWorkspace!() constraints;
        RankedResult[8] page;
        GlobProgram!() glob;
        GlobMatchWorkspace!() globWorkspace;
        FrecencyTable!(4, 4) frecency;
        ComboTable!4 combo;
        ProjectId project = ProjectId(0, 2);
        QueryId queryId = QueryId(0, 3);

        // The measured region includes query/glob construction, candidate
        // analysis, match/rank/top-K/page, and both bounded history tables.
        const gcBefore = GC.allocatedInCurrentThread();
        allocationCalls = 0;
        auditActive = true;
        auto query = parseQuery("unicode tables");
        assert(query.hasValue);
        auto compiled = compileGlob("**/*.d", PathFlavor.unix, false, glob);
        assert(!compiled.hasError);
        auto globbed = globMatch(glob, candidates[0].path, globWorkspace);
        assert(globbed.hasValue && globbed.value);
        auto cursor = accumulator.begin(snapshot.id, 1, 1, 0, page.length);
        assert(cursor.hasValue);
        SearchLimits limits;
        limits.maxCandidates = 1;
        limits.maxAnalyzedUnits = DefaultFuzzyCaps.maxCandidateUnits;
        auto status = searchChunk(query.value, snapshot, cursor.value, limits,
            accumulator, matcher, constraints);
        assert(status.hasValue && status.value.stop == SearchStop.exhausted);
        auto count = accumulator.page(page);
        assert(count.hasValue && count.value == 1);
        assert(!frecency.record(candidates[0].id, 1_000).hasError);
        auto access = frecency.score(candidates[0].id, 1_000);
        assert(access.hasValue && access.value == 1);
        combo.record(project, queryId, candidates[0].id, 1_000);
        auto boost = combo.boost(project, queryId, candidates[0].id);
        assert(boost.hasValue);
        auditActive = false;
        const gcAfter = GC.allocatedInCurrentThread();

        assert(allocationCalls == 0,
            "the complete fuzzy keystroke path called a libc allocator");
        assert(gcAfter == gcBefore,
            "the complete fuzzy keystroke path allocated on the GC heap");
    }
}
