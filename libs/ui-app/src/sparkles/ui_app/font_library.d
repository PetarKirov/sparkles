/**
The font library a font picker runs over: catalog discovery and font-file
preparation on a bounded background pool, and a bounded fuzzy finder over
the catalog's faces, with owned bytes that outlive every renderer instance
that borrows them. Extracted from text-lab, which still drives it.
*/
module sparkles.ui_app.font_library;

import std.file : mkdirRecurse;
import std.path : baseName, buildPath, dirName;

import sparkles.base.buffer : UniqueBuffer;
import sparkles.base.vfs : ambientAuthority, OpenMode, openRoot, Rights;
import sparkles.event_horizon.raw_pool : RawCompletion, RawCpuPool, RawJob, RawPoolResult;
import sparkles.event_horizon.sys.vfs : BlockingVfs;
import sparkles.font.catalog : BuildOptions, BuildReport, buildCatalog, Catalog, FontSource, SourceKind;
import sparkles.font.corrections : CorrectionPolicy;
import sparkles.font : openFace, Tag, UserCoordinate;
import sparkles.font.families : collectFamilies, DocumentFont, FamilyStyle, FontControls, fontControls,
    FontFamily, instanceCoordinates, LigatureSupport, ligatureSupport, writeRecordPath;
import sparkles.base.unique : makeUnique, Unique;
import sparkles.fuzzy : CandidateSnapshot, CandidateView, ConstraintWorkspace, DefaultFuzzyCaps,
    FuzzyError, FuzzyLimits, MatchConfig, MatcherWorkspace, parseQuery, positions, QueryStorage,
    RankedResult, Scoring, SearchAccumulator, searchChunk, SearchLimits, SearchStop, TextRange;
import sparkles.ui.components.picker : PickerState;
import sparkles.ui_app.specimen_font : SpecimenFontRequest;

/// A picker entry names an exact member of a font file.
struct FontEntry
{
    string path, label;
    uint index;
    string family;
    int weight = 400;
    bool italic;
    bool variable;
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
    /// The catalog's families (font `FTD47`) and their names, once `ready`.
    FontFamily[] families;
    string[] familyNames;
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
                    int weight = r.weightMin / 65_536;
                    bool italic = r.italicMin != 0 || r.obliqueMin != 0;
                    if (r.hasItalAxis || r.hasSlntAxis) italic = false;
                    foreach (axis; c.pools.axesOf(r))
                    {
                        if (axis.tag == Tag("wght")) weight = axis.defaultValue / 65_536;
                        if (axis.tag == Tag("ital") || axis.tag == Tag("slnt"))
                            italic |= axis.defaultValue != 0;
                    }
                    entries ~= FontEntry(path, label, r.index, c.text(r.family).idup,
                        weight, italic, r.axes.count != 0);
                }
                UniqueBuffer!FontFamily grouped;
                collectFamilies(catalogJob.catalog, grouped);
                families = grouped[].dup;
                foreach (family; families)
                    familyNames ~= catalogJob.catalog.text(family.name).idup;
            }
        }
        return changed;
    }

    /// Where `style`'s member of `families[family]` is; absent when the family has none (font `FTD47`).
    FontMember member(size_t family, FamilyStyle style) @system
    {
        FontMember m;
        if (catalogJob is null || family >= families.length) return m;
        const s = families[family][style];
        if (!s.present) return m;
        UniqueBuffer!char path;
        if (!writeRecordPath(catalogJob.catalog, s.record, path)) return m;
        m.path = path[].idup;
        m.index = catalogJob.catalog.records[s.record].index;
        m.coordinates = s.userCoordinates.dup;
        m.present = true;
        return m;
    }

    /// The index in `families` of the family named `name`, ignoring ASCII case, or `size_t.max`.
    size_t familyIndex(scope const(char)[] name) const @safe
    {
        import std.uni : sicmp;

        foreach (i, n; familyNames)
            if (sicmp(n, name) == 0) return i;
        return size_t.max;
    }

    /**
    Queues the regular member of `families[family]` and its real bold, italic
    and bold-italic files. A style slot carries a file, not coordinates: a
    member that is an instance of the regular face itself (a variable bold)
    is not queued, so the renderer draws that style with the regular face
    and $(LREF controls) reports it unsupported, and a separate variable
    file (a variable italic) draws at its default instance.
    */
    DocumentFontLoads requestDocumentFont(size_t family) @system
    {
        DocumentFontLoads loads;
        loads.family = family;
        const regular = member(family, FamilyStyle.regular);
        if (!regular.present) return loads;
        loads.regular = request(regular.path, regular.index);
        loads.styles = requestStyles(family);
        return loads;
    }

    /// The bold, italic and bold-italic slots of $(LREF requestDocumentFont) alone.
    StyleLoads requestStyles(size_t family) @system
    {
        StyleLoads styles;
        const regular = member(family, FamilyStyle.regular);
        if (!regular.present) return styles;
        static immutable FamilyStyle[3] slots = [FamilyStyle.bold, FamilyStyle.italic, FamilyStyle.boldItalic];
        foreach (slot, style; slots)
        {
            const m = member(family, style);
            if (m.present && (m.path != regular.path || m.index != regular.index))
                styles[slot] = request(m.path, m.index);
        }
        return styles;
    }

    /**
    What `families[family]` supports of the document font's controls (font
    `FTD51`), as `loads` can draw them: ligatures are read from the regular
    member once its bytes are prepared (`unknown` before), and a style is
    available only when its own file was queued.
    */
    FontControls controls(size_t family, in DocumentFontLoads loads) @system
    {
        if (family >= families.length) return FontControls.init;
        auto ligatures = LigatureSupport.unknown;
        if (loads.regular !is null && loads.regular.done && loads.regular.ok)
        {
            const face = openFace(loads.regular.bytes[], loads.regular.index);
            if (face.hasValue) ligatures = ligatureSupport(face.value);
        }
        auto c = fontControls(families[family], ligatures);
        foreach (slot; 0 .. 3)
            c.styles[slot + 1] = loads.styles[slot] !is null && (!loads.styles[slot].done || loads.styles[slot].ok);
        return c;
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

/// A family member's file: its path, its index in a collection, and the coordinates that realize the style.
struct FontMember
{
    string path;
    uint index;
    const(UserCoordinate)[] coordinates;
    bool present;
}

/// The files a document font over one family draws from: the regular member and the bold, italic and bold-italic slots.
struct DocumentFontLoads
{
    size_t family = size_t.max;
    FontLoad* regular;
    StyleLoads styles;
}

/**
The specimen request that draws `font` over `loads` (font `FTD51`): the
regular member at `font.size` (rounded to whole pixels) with
`instanceCoordinates`' `wght` and `opsz`, and each prepared style file.
False while a load is pending or when the regular member failed; `request`
is left alone then. The request borrows the loads' bytes, so `retain` them
with `FontLibrary.retain`. Line height, letter spacing and ligatures are not
part of a specimen request; the caller applies them to its own layout.
*/
bool documentFontRequest(in FontFamily family, in DocumentFontLoads loads, in DocumentFont font,
    ref SpecimenFontRequest request) @system
{
    if (loads.regular is null || !loads.regular.done || !loads.regular.ok) return false;
    foreach (s; loads.styles)
        if (s !is null && !s.done) return false;
    const d = font.clamped();
    SpecimenFontRequest r;
    r.path = loads.regular.path;
    r.faceIndex = loads.regular.index;
    r.px = cast(int)(d.size + 0.5f);
    UserCoordinate[6] coordinates;
    const n = instanceCoordinates(family, FamilyStyle.regular, d, coordinates);
    r.coordinates = coordinates[0 .. n].dup;
    r.bytes = loads.regular.bytes[];
    r.contentHash = loads.regular.contentHash;
    r.familyStyles = true;
    foreach (slot, s; loads.styles)
        if (s !is null && s.ok)
        {
            r.styleBytes[slot] = s.bytes[];
            r.styleIndices[slot] = s.index;
            r.styleContentHashes[slot] = s.contentHash;
        }
    request = r;
    return true;
}

/// Synchronous bounded fuzzy search; candidates contain catalog metadata only.
struct FontFinder
{
    private CandidateView[] candidates;
    private size_t[] indices;
    private Unique!(MatcherWorkspace!DefaultFuzzyCaps) matcher;
    private QueryStorage!DefaultFuzzyCaps query;
    private ulong generation;

    /// Installs the completed immutable catalog snapshot.
    void corpus(in FontEntry[] entries) @safe
    {
        install(mainFontEntries(entries), (size_t i) => entries[i].label);
    }

    /**
    Installs the families as the corpus (EAP16): the monospace ones only, or
    every family when `showAll`. `entryIndex` then maps a row to its index in
    `families`.
    */
    void families(in FontFamily[] families, in string[] names, bool showAll) @safe
    {
        size_t[] chosen;
        foreach (i, family; families)
            if (showAll || family.monospace) chosen ~= i;
        install(chosen, (size_t i) => names[i]);
    }

    private void install(size_t[] chosen, scope string delegate(size_t) @safe label) @safe
    {
        candidates = null;
        indices = chosen;
        foreach (i; indices)
        {
            CandidateView candidate;
            candidate.id.low = i + 1;
            candidate.path = label(i);
            candidates ~= candidate;
        }
        if (matcher.empty) matcher = makeUnique!(MatcherWorkspace!DefaultFuzzyCaps)();
    }

    /// Maps a ranked picker row back to the full fallback/style catalog.
    size_t entryIndex(size_t index) const @safe pure nothrow @nogc
        => index < indices.length ? indices[index] : size_t.max;

    /// Publishes the global best matches and preserves selection identity.
    void search(ref PickerState!128 state) @safe
    {
        RankedResult[128] rows;
        const count = rank(state.prompt.text.idup, rows, state.error);
        if (count == size_t.max) return;
        state.publish(rows[0 .. count], generation, false);
        state.corpusTotal = candidates.length;
    }

    /// The best matches of `source` as `entryIndex` values, best first, at most 128.
    size_t[] matching(string source) @safe
    {
        RankedResult[128] rows;
        FuzzyError error;
        const count = rank(source, rows, error);
        size_t[] result;
        if (count != size_t.max)
            foreach (row; rows[0 .. count]) result ~= entryIndex(row.corpusIndex);
        return result;
    }

    /// Ranks every candidate against `source` into `rows`; `size_t.max` on an error.
    private size_t rank(string source, ref RankedResult[128] rows, ref FuzzyError error) @safe
    {
        if (matcher.empty) return size_t.max;
        const parsed = parseQuery(source, matcher.get.textWorkspace);
        if (parsed.hasError)
        {
            error = parsed.error;
            return size_t.max;
        }
        query = parsed.value;
        CandidateSnapshot snapshot;
        snapshot.id.low = 1;
        snapshot.candidates = candidates;
        SearchAccumulator!128 accumulator;
        auto cursor = accumulator.begin(snapshot.id, ++generation, generation, 0, 128);
        if (cursor.hasError) return size_t.max;
        ConstraintWorkspace!DefaultFuzzyCaps constraints;
        while (true)
        {
            const progress = searchChunk(query, snapshot, cursor.value, SearchLimits.init,
                MatchConfig.init, Scoring.init, FuzzyLimits.init, accumulator, matcher.get, constraints);
            if (progress.hasError)
            {
                error = progress.error;
                return size_t.max;
            }
            cursor.value = progress.value.cursor;
            if (progress.value.stop == SearchStop.exhausted) break;
        }
        const count = accumulator.page(rows);
        return count.hasValue ? count.value : size_t.max;
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

/// One regular representative per family. Script/UI satellites collapse only
/// when their main family is installed; fallback discovery retains every face.
size_t[] mainFontEntries(in FontEntry[] entries) @safe
{
    import std.algorithm.searching : startsWith;
    import std.math : abs;
    import std.string : strip, toLower;

    bool[string] families;
    foreach (entry; entries) if (entry.family.length) families[entry.family.toLower] = true;
    size_t[string] chosen;
    string key(FontEntry entry)
    {
        auto family = (entry.family.length ? entry.family : entry.label).toLower.strip;
        if (family.length > 3 && family[$ - 3 .. $] == " ui"
            && family[0 .. $ - 3] in families) family = family[0 .. $ - 3];
        foreach (root; ["noto sans", "noto serif"])
            if (family.startsWith(root ~ " ") && root in families
                && family != root ~ " mono" && family != root ~ " display") return root;
        return family;
    }
    long score(in FontEntry entry, string group)
        => (entry.family.toLower == group ? 0L : 1_000_000L)
            + (entry.italic ? 100_000L : 0L) + 2 * abs(cast(long) entry.weight - 400)
            + (entry.variable ? 0 : 1);
    foreach (i, entry; entries)
    {
        const group = key(entry);
        if (auto old = group in chosen)
        {
            const a = score(entry, group), b = score(entries[*old], group);
            if (a < b || a == b && entry.path < entries[*old].path) *old = i;
        }
        else chosen[group] = i;
    }
    size_t[] result;
    foreach (i, entry; entries) if (chosen[key(entry)] == i) result ~= i;
    return result;
}

/// Main family selection never removes fallback records or invents a root.
@("ui_app.fontLibrary.finder.mainCollections")
@safe unittest
{
    auto entries = [
        FontEntry("bold", "Noto Sans Bold", 0, "Noto Sans", 700),
        FontEntry("arabic", "Noto Sans Arabic", 0, "Noto Sans Arabic"),
        FontEntry("regular", "Noto Sans Regular", 0, "Noto Sans"),
        FontEntry("ui", "Noto Sans Arabic UI", 0, "Noto Sans Arabic UI"),
        FontEntry("mono", "Noto Sans Mono", 0, "Noto Sans Mono"),
        FontEntry("other", "Other Arabic", 0, "Other Arabic")];
    assert(mainFontEntries(entries) == [2, 4, 5]);
    assert(mainFontEntries(entries[1 .. 2]) == [0]);
    FontFinder finder;
    finder.corpus(entries);
    PickerState!128 state;
    state.open();
    finder.search(state);
    assert(state.rowCount == 3);
    assert(finder.entryIndex(0) == 2 && finder.entryIndex(size_t.max) == size_t.max);
}

/// Ranking uses family and style, preserving the catalog's exact face index.
@("ui_app.fontLibrary.finder.ranksFixtureCatalog")
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
@("ui_app.fontLibrary.backgroundLoadsAndReusesOwnedBytes")
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
@("ui_app.fontLibrary.queuePressureRetriesWithoutDuplicateOwners")
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

/// The family picker lists monospace families unless asked for all of them.
@("ui_app.fontLibrary.finder.familiesMonospaceAndShowAll")
@safe unittest
{
    auto families = new FontFamily[3];
    families[0].monospace = true;
    families[2].monospace = true;
    const names = ["Fira Code", "Roboto", "Iosevka"];
    FontFinder finder;
    finder.families(families, names, false);
    assert(finder.matching("") == [0, 2]);
    foreach (i; finder.matching("roboto")) assert(i != 1, "a proportional family is filtered out");
    assert(finder.matching("iosevka")[0] == 2);
    finder.families(families, names, true);
    assert(finder.matching("") == [0, 1, 2]);
    assert(finder.matching("roboto")[0] == 1, "show all reaches it");
    PickerState!128 state;
    state.open();
    foreach (c; "fira") assert(state.prompt.type(c));
    finder.search(state);
    assert(state.rowCount == 1 && finder.entryIndex(state.selectedCorpusIndex) == 0);
}

/// A document font over real files: its members load in the background and
/// become a specimen request; a family without italics reports them unsupported.
@("ui_app.fontLibrary.documentFontRequest")
@system unittest
{
    import core.thread : Thread;
    import core.time : MonoTime, msecs, seconds;
    import std.conv : text;
    import std.file : copy, mkdir, rmdirRecurse, tempDir;
    import std.process : environment;
    import sparkles.font.families : ControlState, FontControl;

    const root = environment.get("SPARKLES_FONTS_PATH");
    assert(root.length, "SPARKLES_FONTS_PATH is required");
    const directory = buildPath(tempDir(), text("sparkles-font-families-", MonoTime.currTime.ticks));
    mkdir(directory);
    scope (exit) rmdirRecurse(directory);
    foreach (name; ["DejaVuSansMono.ttf", "DejaVuSansMono-Bold.ttf", "DejaVuSansMono-Oblique.ttf",
        "DejaVuSansMono-BoldOblique.ttf", "Roboto-Regular.ttf", "Roboto-Bold.ttf"])
        copy(buildPath(root, name), buildPath(directory, name));
    auto library = new FontLibrary;
    library.start([directory], "");
    scope (exit) library.stop();
    const deadline = MonoTime.currTime + 10.seconds;
    while (!library.ready && MonoTime.currTime < deadline)
    {
        library.poll();
        Thread.sleep(1.msecs);
    }
    assert(library.ready && library.familyNames == ["DejaVu Sans Mono", "Roboto"], library.familyNames.text);
    const dejavu = library.familyIndex("dejavu sans mono");
    const roboto = library.familyIndex("Roboto");
    assert(dejavu == 0 && roboto == 1 && library.familyIndex("Missing") == size_t.max);
    assert(library.member(dejavu, FamilyStyle.italic).path == buildPath(directory, "DejaVuSansMono-Oblique.ttf"));

    auto loads = library.requestDocumentFont(dejavu);
    auto robotoLoads = library.requestDocumentFont(roboto);
    SpecimenFontRequest request;
    DocumentFont font;
    font.size = 15.6;
    while (!documentFontRequest(library.families[dejavu], loads, font, request) && MonoTime.currTime < deadline)
    {
        library.poll();
        Thread.sleep(1.msecs);
    }
    assert(request.path == buildPath(directory, "DejaVuSansMono.ttf") && request.px == 16);
    assert(request.familyStyles && request.bytes.length && request.coordinates.length == 0);
    foreach (bytes; request.styleBytes) assert(bytes.length, "every style is a real file");
    const controls = library.controls(dejavu, loads);
    assert(controls.supports(FontControl.bold) && controls.supports(FontControl.boldItalic));
    assert(controls.state(FontControl.ligatures) != ControlState.unknown, "read from the prepared bytes");
    assert(controls.state(FontControl.weight) == ControlState.unsupported);

    while (!documentFontRequest(library.families[roboto], robotoLoads, font, request) && MonoTime.currTime < deadline)
    {
        library.poll();
        Thread.sleep(1.msecs);
    }
    assert(request.styleBytes[0].length && !request.styleBytes[1].length && !request.styleBytes[2].length);
    const robotoControls = library.controls(roboto, robotoLoads);
    assert(robotoControls.supports(FontControl.bold));
    assert(robotoControls.state(FontControl.italic) == ControlState.unsupported
        && robotoControls.state(FontControl.boldItalic) == ControlState.unsupported);
}
