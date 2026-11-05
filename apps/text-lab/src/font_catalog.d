/** Background catalog discovery and owned font-file preparation. */
module font_catalog;

import std.file : mkdirRecurse;
import std.path : baseName, buildPath, dirName;

import sparkles.base.buffer : UniqueBuffer;
import sparkles.base.vfs : ambientAuthority, OpenMode, openRoot, Rights;
import sparkles.event_horizon.raw_pool : RawCompletion, RawCpuPool, RawJob, RawPoolResult;
import sparkles.event_horizon.sys.vfs : BlockingVfs;
import sparkles.font.catalog : BuildOptions, BuildReport, buildCatalog, Catalog, FontSource, SourceKind;
import sparkles.font.corrections : CorrectionPolicy;
import sparkles.font : openFace;
import sparkles.base.unique : makeUnique, Unique;
import sparkles.fuzzy : CandidateSnapshot, CandidateView, ConstraintWorkspace, DefaultFuzzyCaps,
    FuzzyLimits, MatchConfig, MatcherWorkspace, parseQuery, positions, QueryStorage,
    RankedResult, Scoring, SearchAccumulator, searchChunk, SearchLimits, SearchStop, TextRange;
import sparkles.ui.components.picker : PickerState;

/// A picker entry names an exact member of a font file.
struct FontEntry
{
    string path, label;
    uint index;
    string family;
    int weight = 400;
    bool italic;
}

private struct CatalogJob
{
    BlockingVfs vfs;
    FontSource[] sources;
    string cache;
    Catalog catalog;
    BuildReport report;
    bool ok, done;
}

/// Caller-owned bytes outlive renderer instances and all background work.
struct FontLoad
{
    BlockingVfs vfs;
    string path;
    uint index;
    ulong generation;
    ulong contentHash;
    UniqueBuffer!ubyte bytes;
    bool ok, done;
    ulong lastUsed;
}

alias StyleLoads = FontLoad*[3];

private void discover(void* context) @safe nothrow @nogc
{
    auto job = (() @trusted => cast(CatalogJob*) context)();
    const result = buildCatalog(&job.vfs, job.sources,
        BuildOptions(workers: 1, corrections: CorrectionPolicy.apply, cacheDirectory: job.cache),
        ambientAuthority(), job.catalog, job.report);
    job.ok = !result.hasError;
}

private void discovered(void* context, bool cancelled) @safe nothrow @nogc
{
    auto job = (() @trusted => cast(CatalogJob*) context)();
    job.done = true;
    if (cancelled) job.ok = false;
}

private void load(void* context) @safe nothrow @nogc
{
    auto job = (() @trusted => cast(FontLoad*) context)();
    // Split without allocating on the worker.
    size_t slash = job.path.length;
    while (slash && job.path[slash - 1] != '/' && job.path[slash - 1] != '\\') --slash;
    const directory = slash ? job.path[0 .. slash] : ".";
    const filename = job.path[slash .. $];
    auto root = openRoot!(Rights.readOnly)(&job.vfs, directory, ambientAuthority());
    if (root.hasError) return;
    auto file = root.value.openFile!(OpenMode.read)(filename);
    if (file.hasError) return;
    const stat = file.value.stat();
    if (stat.hasError || stat.value.size > 256 * 1024 * 1024) return;
    job.bytes.length = cast(size_t) stat.value.size;
    size_t offset;
    while (offset < job.bytes.length)
    {
        const n = file.value.read(job.bytes[][offset .. $]);
        if (n.hasError || n.value == 0) return;
        offset += n.value;
    }
    job.ok = openFace(job.bytes[], job.index).hasValue;
    job.contentHash = 0xcbf2_9ce4_8422_2325;
    foreach (b; job.bytes[])
    {
        job.contentHash ^= b;
        job.contentHash *= 0x0000_0100_0000_01b3;
    }
}

private void loaded(void* context, bool cancelled) @safe nothrow @nogc
{
    auto job = (() @trusted => cast(FontLoad*) context)();
    job.done = true;
    if (cancelled) job.ok = false;
}

/// A bounded persistent pool; completion dispatch publishes worker-owned data.
final class FontLibrary
{
    private RawCpuPool!(8, 8) pool;
    private bool started;
    private CatalogJob* catalogJob;
    private FontLoad*[] loads;
    private ulong generation;
    private ulong access;
    private FontLoad*[] retained;
    FontEntry[] entries;
    bool ready;
    string error;

    /// Starts discovery after the initial specimen can paint.
    void start(string[] directories, string cacheDirectory) @system
    {
        if (started) return;
        started = typeof(pool).start(pool, 2) == RawPoolResult.accepted;
        if (!started)
        {
            ready = true;
            error = "Font workers could not start";
            return;
        }
        catalogJob = new CatalogJob;
        foreach (i, dir; directories)
        {
            import std.conv : text;
            catalogJob.sources ~= FontSource.directory(text("directory-", i), dir, true);
        }
        if (!directories.length)
        {
            import std.process : environment;

            const bundle = environment.get("SPARKLES_FONTS_PATH");
            if (bundle.length)
                catalogJob.sources ~= FontSource.bundle("bundle", bundle);
            catalogJob.sources ~= FontSource.platform("platform");
        }
        if (cacheDirectory.length)
        {
            try
            {
                mkdirRecurse(cacheDirectory);
                catalogJob.cache = cacheDirectory;
            }
            catch (Exception) {} // discovery remains usable without a cache
        }
        if (pool.submit(RawJob(&discover, &discovered, catalogJob)) != RawPoolResult.accepted)
        {
            catalogJob.done = true;
            error = "Font discovery could not be queued";
        }
    }

    /// Dispatches completion callbacks on the owning thread.
    bool poll() @system
    {
        if (!started) return false;
        RawCompletion completion;
        bool changed;
        while (pool.pollCompletion(completion) == RawPoolResult.accepted)
        {
            completion.dispatch();
            changed = true;
        }
        if (!ready && catalogJob !is null && catalogJob.done)
        {
            ready = true;
            if (!catalogJob.ok)
                error = "Font discovery failed";
            else
            {
                bool[string] seen;
                foreach (r; catalogJob.catalog.records)
                {
                    auto c = &catalogJob.catalog;
                    const id = c.text(r.identity).idup;
                    const source = c.sources[r.source];
                    const path = source.kind == SourceKind.platform ? id : buildPath(c.text(source.path).idup, id);
                    import std.conv : text;

                    const key = text(path, '#', r.index);
                    if (key in seen) continue;
                    seen[key] = true;
                    const label = c.text(r.family).idup ~ " · " ~ c.text(r.styleName).idup
                        ~ " · " ~ c.text(r.postScriptName).idup;
                    entries ~= FontEntry(path, label, r.index, c.text(r.family).idup,
                        r.weightMin / 65_536, r.italicMin != 0 || r.obliqueMin != 0);
                }
            }
        }
        return changed;
    }

    /// Queues a file read; prepared files are reused without another read.
    FontLoad* request(string path, uint index) @system
    {
        foreach (job; loads)
            if (job.path == path && job.index == index && (!job.done || job.ok))
            {
                job.lastUsed = ++access;
                error = null;
                return job;
            }
        if (!started) return null;
        // Evict the least recently used completed file. In-flight work and
        // renderer-borrowed bytes stay pinned; browsing has no lifetime quota.
        if (loads.length >= 64)
        {
            size_t victim = size_t.max;
            foreach (i, old; loads)
            {
                bool pinned;
                foreach (r; retained) pinned |= r is old;
                if (old.done && !pinned
                    && (victim == size_t.max || old.lastUsed < loads[victim].lastUsed))
                    victim = i;
            }
            if (victim == size_t.max) return null;
            destroy(*loads[victim]);
            loads = loads[0 .. victim] ~ loads[victim + 1 .. $];
        }
        auto job = new FontLoad;
        job.path = path;
        job.index = index;
        job.generation = ++generation;
        job.lastUsed = ++access;
        if (pool.submit(RawJob(&load, &loaded, job, generation)) != RawPoolResult.accepted)
        {
            error = "Font preparation queue is busy";
            return null;
        }
        loads ~= job;
        error = null;
        return job;
    }

    /// Pins bytes borrowed by the currently accepted renderer instances.
    void retain(FontLoad* current, StyleLoads styles = StyleLoads.init,
        scope FontLoad*[] fallbacks = null) @system
    {
        retained = [current];
        foreach (s; styles)
            if (s !is null) retained ~= s;
        foreach (s; fallbacks)
            if (s !is null) retained ~= s;
    }

    /// Waits for owned jobs before their buffers and pool are released.
    void stop() @system
    {
        if (started)
        {
            cast(void) pool.shutdown(true);
            RawCompletion completion;
            while (pool.pollCompletion(completion) == RawPoolResult.accepted)
                completion.dispatch();
        }
        started = false;
    }
}

/// Synchronous bounded fuzzy search; candidates contain catalog metadata only.
struct FontFinder
{
    private CandidateView[] candidates;
    private Unique!(MatcherWorkspace!DefaultFuzzyCaps) matcher;
    private QueryStorage!DefaultFuzzyCaps query;
    private ulong generation;

    /// Installs the completed immutable catalog snapshot.
    void corpus(in FontEntry[] entries) @safe
    {
        candidates = new CandidateView[entries.length];
        foreach (i, entry; entries)
        {
            candidates[i].id.low = i + 1;
            candidates[i].path = entry.label;
        }
        if (matcher.empty) matcher = makeUnique!(MatcherWorkspace!DefaultFuzzyCaps)();
    }

    /// Publishes the global best matches and preserves selection identity.
    void search(ref PickerState!128 state) @safe
    {
        if (matcher.empty) return;
        const source = state.prompt.text.idup;
        const parsed = parseQuery(source, matcher.get.textWorkspace);
        if (parsed.hasError)
        {
            state.error = parsed.error;
            return;
        }
        query = parsed.value;
        CandidateSnapshot snapshot;
        snapshot.id.low = 1;
        snapshot.candidates = candidates;
        SearchAccumulator!128 accumulator;
        auto cursor = accumulator.begin(snapshot.id, ++generation, generation, 0, 128);
        if (cursor.hasError) return;
        ConstraintWorkspace!DefaultFuzzyCaps constraints;
        while (true)
        {
            const progress = searchChunk(query, snapshot, cursor.value, SearchLimits.init,
                MatchConfig.init, Scoring.init, FuzzyLimits.init, accumulator, matcher.get, constraints);
            if (progress.hasError)
            {
                state.error = progress.error;
                return;
            }
            cursor.value = progress.value.cursor;
            if (progress.value.stop == SearchStop.exhausted) break;
        }
        RankedResult[128] rows;
        const count = accumulator.page(rows);
        if (count.hasValue) state.publish(rows[0 .. count.value], generation, false);
        state.corpusTotal = candidates.length;
    }

    /// Authoritative merged UTF-8 byte ranges for witness highlighting.
    TextRange[] highlights(size_t index) @safe
    {
        if (index >= candidates.length || matcher.empty) return null;
        TextRange[128] ranges;
        const count = positions(query, candidates[index], MatchConfig.init,
            FuzzyLimits.init, matcher.get, ranges);
        return count.hasValue ? ranges[0 .. count.value].dup : null;
    }
}

/// Ranking uses family and style, preserving the catalog's exact face index.
@("text_lab.fontFinder.ranksFixtureCatalog")
@safe unittest
{
    FontFinder finder;
    finder.corpus([FontEntry("a.ttc", "Alpha Regular", 2), FontEntry("b.ttf", "Beta Bold", 0)]);
    PickerState!128 state;
    state.open();
    foreach (c; "Beta") assert(state.prompt.type(c));
    finder.search(state);
    assert(state.rowCount == 1 && state.selectedCorpusIndex == 1);
    assert(finder.highlights(1).length);
}

/// Discovery and file loading complete off-thread and preserve cached ownership.
@("text_lab.fontCatalog.backgroundLoadsAndReusesOwnedBytes")
@system unittest
{
    import core.thread : Thread;
    import core.time : MonoTime, msecs, seconds;
    import std.conv : text;
    import std.file : copy, mkdir, rmdirRecurse, tempDir;
    import std.process : environment;

    const root = environment.get("SPARKLES_FONTS_PATH");
    assert(root.length, "SPARKLES_FONTS_PATH is required");
    const directory = buildPath(tempDir(), text("sparkles-font-loader-", MonoTime.currTime.ticks));
    mkdir(directory);
    scope (exit) rmdirRecurse(directory);
    const path = buildPath(directory, "font.ttf");
    copy(buildPath(root, "DejaVuSansMono.ttf"), path);
    auto library = new FontLibrary;
    library.start([directory], "");
    scope (exit) library.stop();
    auto first = library.request(path, 0);
    assert(first !is null);
    const deadline = MonoTime.currTime + 5.seconds;
    while ((!library.ready || !first.done) && MonoTime.currTime < deadline)
    {
        library.poll();
        Thread.sleep(1.msecs);
    }
    assert(library.ready && first.done && first.ok);
    assert(library.entries.length == 1 && library.entries[0].path == path);
    assert(first.bytes.length && first.contentHash);
    assert(library.request(path, 0) is first);
    auto invalid = library.request(path, uint.max);
    assert(invalid !is null);
    while (!invalid.done && MonoTime.currTime < deadline)
    {
        library.poll();
        Thread.sleep(1.msecs);
    }
    assert(invalid.done && !invalid.ok && first.bytes.length);
}

/// A corpus larger than the bounded queue makes progress when submission retries.
@("text_lab.fontCatalog.queuePressureRetriesWithoutDuplicateOwners")
@system unittest
{
    import core.thread : Thread;
    import core.time : MonoTime, msecs, seconds;
    import std.conv : text;
    import std.file : copy, mkdir, rmdirRecurse, tempDir;
    import std.process : environment;

    const root = environment.get("SPARKLES_FONTS_PATH");
    assert(root.length, "SPARKLES_FONTS_PATH is required");
    const directory = buildPath(tempDir(), text("sparkles-font-queue-", MonoTime.currTime.ticks));
    mkdir(directory);
    scope (exit) rmdirRecurse(directory);
    string[20] paths;
    foreach (i, ref path; paths)
    {
        path = buildPath(directory, text(i, ".ttf"));
        copy(buildPath(root, "DejaVuSansMono.ttf"), path);
    }
    auto library = new FontLibrary;
    library.start([directory], "");
    scope (exit) library.stop();
    FontLoad*[20] owners;
    const deadline = MonoTime.currTime + 10.seconds;
    bool complete;
    while (!complete && MonoTime.currTime < deadline)
    {
        library.poll();
        complete = library.ready;
        foreach (i, path; paths)
        {
            auto job = library.request(path, 0);
            if (job is null) { complete = false; break; }
            if (owners[i] !is null) assert(owners[i] is job);
            owners[i] = job;
            complete &= job.done && job.ok;
        }
        Thread.sleep(1.msecs);
    }
    assert(complete && library.loads.length == owners.length);
    foreach (i, job; owners) foreach (other; owners[i + 1 .. $]) assert(job !is other);
}
