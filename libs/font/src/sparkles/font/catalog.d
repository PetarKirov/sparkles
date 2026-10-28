/**
The font catalog (`docs/specs/font/discovery.md` FTD13–FTD24, SPEC.md
FTD1–FTD3): face records built from font sources by this library's parser,
over base's capability VFS.

`buildCatalog` lists every source, follows symbolic links, stats each file,
reuses the cached records of a file whose key is unchanged, and describes
the rest: the calling thread maps or reads files through the VFS (a backend
need not be thread-safe), and worker threads parse them. Records are ordered
by source, identity and collection index, whatever the worker count (FTD17,
FTD21). Problems are outcomes in the report, never a failed build (FTD15).

A built `Catalog` never changes and may be read from any number of threads
(FTD14). It owns its records' storage; a memory source's bytes stay the
caller's. Nothing here uses the garbage collector.
*/
module sparkles.font.catalog;

import core.atomic : atomicOp;
import core.lifetime : move;

import sparkles.base.buffer : UniqueBuffer;
import sparkles.base.hash.blake3 : blake3, Blake3;
import sparkles.base.io.errors : ErrorKind, IoError, IoResult, ioErr, ioOk;
import sparkles.base.vfs : AmbientAuthority, EntryKind, hasMap, isVfs, OpenMode, openRoot, Rights,
    Stat, StatMask;

import sparkles.font.catalog_cache : CacheContents, CacheDiscard, CachedFile, decodeCache, encodeCache;
import sparkles.font.cmap : CodepointRange;
import sparkles.font.corrections : CorrectionPolicy;
import sparkles.font.errors : FontError, FontErrorKind;
import sparkles.font.face : openCollection, openFace;
import sparkles.font.face_record : AxisRecord, describeFace, FaceRecord, FieldError, PoolSpan,
    RecordPools, StringRef;
import sparkles.font.platform_fonts : listPlatformFonts, PlatformListing, PlatformOptions, PlatformProblem;

@safe nothrow @nogc:

/// The most links one path may follow (FTD16).
enum uint maxFontLinks = 40;
/// The most worker threads a build uses (FTD21).
enum uint maxCatalogWorkers = 64;
/// How deep a recursive directory source descends.
enum uint maxSourceDepth = 64;

/// What a source lists (FTD16).
enum SourceKind : ubyte
{
    files,
    directory,
    bundle,
    memory,
    platform,
}

/// How a source's files are read (FTD16).
enum ReadMode : ubyte
{
    /// `map` for bundle and platform sources, `read` otherwise.
    automatic,
    map,
    read,
}

/// One input of a build (FTD16). Strings and bytes are borrowed for the build.
struct FontSource
{
    @safe pure nothrow @nogc:

    SourceKind kind;
    /// Names the source in reports and the cache; unique in a build.
    const(char)[] label;
    /// The directory of a `files`, `directory` or `bundle` source.
    const(char)[] path;
    /// The file names of a `files` source.
    const(char[])[] names;
    bool recurse;
    /// A memory source's bytes, and its BLAKE3 hash if the caller knows it.
    const(ubyte)[] bytes;
    const(ubyte)[] contentHash;
    /// A platform source's options.
    PlatformOptions platformOptions;
    ReadMode mode;

    /// The named files under `path`.
    static FontSource files(const(char)[] label, const(char)[] path, const(char[])[] names)
        => FontSource(SourceKind.files, label, path, names);
    /// The font files under `path`, and under its subdirectories when `recurse`.
    static FontSource directory(const(char)[] label, const(char)[] path, bool recurse)
    {
        auto s = FontSource(SourceKind.directory, label, path);
        s.recurse = recurse;
        return s;
    }
    /// The bundled fonts under `path`, recursively.
    static FontSource bundle(const(char)[] label, const(char)[] path)
    {
        auto s = FontSource(SourceKind.bundle, label, path);
        s.recurse = true;
        return s;
    }
    /// One caller-owned buffer; `hash` is its BLAKE3 hash, if known.
    static FontSource memory(const(char)[] label, const(ubyte)[] bytes, const(ubyte)[] hash = null)
    {
        auto s = FontSource(SourceKind.memory, label);
        s.bytes = bytes;
        s.contentHash = hash;
        return s;
    }
    /// The platform's fonts (FTD18).
    static FontSource platform(const(char)[] label, PlatformOptions options = PlatformOptions.init)
    {
        auto s = FontSource(SourceKind.platform, label);
        s.platformOptions = options;
        return s;
    }

    /// Whether files of this source are mapped rather than read.
    bool maps() const => mode == ReadMode.map
        || mode == ReadMode.automatic && (kind == SourceKind.bundle || kind == SourceKind.platform);
}

/// Options of `buildCatalog`.
struct BuildOptions
{
    /// Worker threads: 0 for one per processor, at most `maxCatalogWorkers`.
    uint workers;
    /// Corrections are opt-in (FTX15): the GUI stack asks for `apply`.
    CorrectionPolicy corrections = CorrectionPolicy.off;
    /// The directory of the cache file; none when empty (FTD24).
    const(char)[] cacheDirectory;
    const(char)[] cacheName = "sparkles-font-catalog.bin";
}

/// The kinds of outcome a build reports (FTD15).
enum OutcomeKind : ubyte
{
    io,
    font,
    libraryUnavailable,
    symbolMissing,
    serviceFailed,
    directoryUnavailable,
    cacheDiscarded,
    stale,
    boxFace,
    linkLimit,
}

/// One problem of a build, attached to what it concerns (FTD15).
struct BuildOutcome
{
    OutcomeKind kind;
    /// The source's position, or `uint.max` for the build itself (the cache).
    uint source = uint.max;
    /// The file's identity, the library or directory's name, or the cache file.
    StringRef subject;
    /// A collection member's index, or `uint.max` for the whole file.
    uint face = uint.max;
    IoError io;
    FontError font;
    CacheDiscard discard;
    int code;
}

/// What a build did (FTD21).
struct BuildReport
{
    @safe nothrow @nogc:

    uint listed, skipped, described, reused, failed;
    /// The outcomes, in catalog order, the cache's last.
    UniqueBuffer!BuildOutcome outcomes;
    /// The strings outcomes refer to.
    UniqueBuffer!char strings;

    @disable this(this);

    /// The text of an outcome's `subject`.
    const(char)[] text(StringRef s) const return scope pure => strings[][s.offset .. s.offset + s.length];

    private void add(BuildOutcome o, scope const(char)[] subject) scope pure
    {
        o.subject = StringRef(cast(uint) strings.length, cast(uint) subject.length);
        strings.put(subject);
        outcomes.put(o);
    }
}

/// A source as the catalog keeps it, to reopen its files (FTD32).
struct CatalogSource
{
    SourceKind kind;
    StringRef label, path;
    bool maps;
    /// A memory source's bytes, borrowed.
    const(ubyte)[] bytes;
}

/// An alias of a record in the family index, sorted by ASCII-folded text.
package struct FamilyEntry
{
    StringRef alias_;
    uint record;
}

/// The catalog: records and the storage they refer into (FTD14).
struct Catalog
{
    @safe nothrow @nogc:

    private RecordPools pools_;
    private UniqueBuffer!FaceRecord records_;
    private UniqueBuffer!CatalogSource sources_;
    private UniqueBuffer!FamilyEntry families_;
    private CorrectionPolicy policy_;

    @disable this(this);

    /// The records, in catalog order (FTD17).
    const(FaceRecord)[] records() const return scope pure => records_[];
    /// The storage records refer into.
    ref const(RecordPools) pools() const return pure => pools_;
    /// The sources, in build order.
    const(CatalogSource)[] sources() const return scope pure => sources_[];
    /// The correction policy the records were built under.
    CorrectionPolicy policy() const scope pure => policy_;
    /// The text of `s`.
    const(char)[] text(StringRef s) const return scope pure => pools_.text(s);

    /**
    The records having `family` among their aliases, compared ignoring ASCII
    case, in catalog order, as indices into `records` (FTD26). Costs
    O(log a + m) for `a` aliases and `m` results; writes into `into` and
    returns how many there are, even past its length.
    */
    size_t family(scope const(char)[] family, scope uint[] into) const scope pure
    {
        const f = familyEntries(family);
        foreach (i, e; f)
            if (i < into.length)
                into[i] = e.record;
        return f.length;
    }

    /// The family index's entries for `family`, in catalog order. Costs O(log a).
    package const(FamilyEntry)[] familyEntries(scope const(char)[] family) const return scope pure
    {
        const f = families_[];
        size_t lo = 0, hi = f.length;
        while (lo < hi)
        {
            const mid = (lo + hi) / 2;
            if (compareFolded(text(f[mid].alias_), family) < 0)
                lo = mid + 1;
            else
                hi = mid;
        }
        size_t end = lo;
        while (end < f.length && compareFolded(text(f[end].alias_), family) == 0)
            ++end;
        return f[lo .. end];
    }

    /// The family names in ASCII-folded order, each once, through `sink(name, firstRecord)`.
    void eachFamily(scope void delegate(scope const(char)[], uint) @safe nothrow @nogc sink) const scope
    {
        foreach (r; records_[])
            if (r.family.length)
            {
                // A family is listed under its first record's family name only.
                uint[1] first;
                if (family(text(r.family), first[]) && &records_[][first[0]] is &r)
                    sink(text(r.family), first[0]);
            }
    }
}

/// `a` against `b` ignoring ASCII case: negative, zero or positive.
package int compareFolded(scope const(char)[] a, scope const(char)[] b) pure
{
    const n = a.length < b.length ? a.length : b.length;
    foreach (i; 0 .. n)
    {
        const x = fold(a[i]), y = fold(b[i]);
        if (x != y)
            return x < y ? -1 : 1;
    }
    return a.length < b.length ? -1 : a.length > b.length;
}

private char fold(char c) pure => c >= 'A' && c <= 'Z' ? cast(char)(c + 32) : c;

///
@("catalog.compareFolded")
unittest
{
    assert(compareFolded("Noto Sans", "noto sans") == 0 && compareFolded("A", "b") < 0);
    assert(compareFolded("ab", "a") > 0 && compareFolded("", "") == 0);
}

// ---------------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------------

/// Whether `name` ends in `.ttf`, `.otf`, `.ttc` or `.otc`, ignoring ASCII case (FTD16).
package bool isFontFileName(scope const(char)[] name) pure
{
    if (name.length < 5 || name[$ - 4] != '.')
        return false;
    const a = fold(name[$ - 3]), b = fold(name[$ - 2]), c = fold(name[$ - 1]);
    return (a == 't' || a == 'o') && (b == 't' && c == 'f' || b == 't' && c == 'c');
}

///
@("catalog.isFontFileName")
unittest
{
    assert(isFontFileName("a.ttf") && isFontFileName("B.OTC") && isFontFileName("x.Otf"));
    assert(!isFontFileName("a.pcf") && !isFontFileName(".ttf") && !isFontFileName("a.woff"));
}

/// The directory and name of `path`: `("/a/b", "c")` for `/a/b/c`; `(".", p)` without a slash.
/// A path cut at its last separator.
package struct PathParts
{
    const(char)[] dir, base;
}

/// ditto
package PathParts splitPath(return scope const(char)[] path) pure
{
    size_t slash = path.length;
    while (slash > 0 && path[slash - 1] != '/' && path[slash - 1] != '\\')
        --slash;
    if (slash == 0)
        return PathParts(".", path);
    return PathParts(slash == 1 ? path[0 .. 1] : path[0 .. slash - 1], path[slash .. $]);
}

/// Whether `p` is absolute: `/…`, or on Windows a drive or UNC prefix.
private bool isAbsolute(scope const(char)[] p) pure
    => p.length && (p[0] == '/' || p[0] == '\\' || p.length > 2 && p[1] == ':' && (p[2] == '\\' || p[2] == '/'));

/**
`path` without `.` components, empty components and the `..` components a
preceding name cancels, so two spellings of one file compare equal (FTD17).
A leading `/` is kept; a `..` with nothing to cancel stays.
*/
package void normalizePath(ref UniqueBuffer!char path) pure
{
    UniqueBuffer!char out_;
    const p = path[];
    const absolute = p.length && p[0] == '/';
    if (absolute)
        out_.put('/');
    const base = out_.length;
    size_t i;
    while (i < p.length)
    {
        size_t j = i;
        while (j < p.length && p[j] != '/')
            ++j;
        const c = p[i .. j];
        i = j + 1;
        if (c.length == 0 || c == ".")
            continue;
        if (c == "..")
        {
            // Drop the last name, unless there is none or it is itself `..`.
            size_t k = out_.length;
            while (k > base && out_[][k - 1] != '/')
                --k;
            const last = out_[][k .. $];
            if (out_.length > base && last != "..")
            {
                const keep = k > base ? k - 1 : base;
                while (out_.length > keep)
                    out_.popBack();
                continue;
            }
            if (absolute && out_.length == base)
                continue; // the root is its own parent
        }
        if (out_.length > base)
            out_.put('/');
        out_.put(c);
    }
    path.clear(false);
    path.put(out_[]);
}

///
@("catalog.normalizePath")
unittest
{
    UniqueBuffer!char p;
    static immutable string[2][5] cases = [["fonts/../store/./x.ttf", "store/x.ttf"], ["/a//b/../c", "/a/c"],
        ["../x", "../x"], ["/..", "/"], ["a/b/../../..", ".."]];
    foreach (t; cases)
    {
        p.clear(false);
        p.put(t[0]);
        normalizePath(p);
        assert(p[] == t[1], t[0]);
    }
}

/// `dir ~ "/" ~ name` into `into`.
private void joinPath(ref UniqueBuffer!char into, scope const(char)[] dir, scope const(char)[] name) pure
{
    into.clear(false);
    into.put(dir);
    if (dir.length && dir[$ - 1] != '/' && dir[$ - 1] != '\\')
        into.put('/');
    into.put(name);
}

// ---------------------------------------------------------------------------
// The build
// ---------------------------------------------------------------------------

/// A listed file: its source, identity and path, in the build's scratch strings.
private struct Listed
{
    uint source;
    StringRef identity;
    StringRef path;
}

/// A file read for parsing, with what is known of it.
private struct FileJob(V)
{
    uint source;
    StringRef identity;
    ulong size;
    long modifiedNs;
    bool hasModified;
    bool fromCache;
    /// The cache entry, when `fromCache`.
    size_t cached;
    const(ubyte)[] bytes;
    static if (hasMap!V)
        V.Mapping mapping;
    UniqueBuffer!ubyte owned;
    // Results of parsing.
    RecordPools pools;
    UniqueBuffer!FaceRecord records;
    UniqueBuffer!(FaceFailure) failures;
    FontError fileError;
    bool fileFailed;
    IoError ioError;
    bool linkLimited;
    bool loadFailed;
    /// The path the file was found at, links followed.
    UniqueBuffer!char resolved;

    @disable this(this);
}

/// A job on the C heap, as jobs own mappings and buffers and are never copied.
private FileJob!V* newJob(V)() @trusted
{
    import core.lifetime : emplace;
    import core.memory : pureMalloc;

    auto p = cast(FileJob!V*) pureMalloc((FileJob!V).sizeof);
    assert(p !is null, "out of memory");
    emplace(p);
    return p;
}

/// Destroys and frees a job of `newJob`.
private void freeJob(V)(FileJob!V* p) @trusted
{
    import core.memory : pureFree;

    destroy(*p);
    pureFree(p);
}

/// A collection member that did not open.
private struct FaceFailure
{
    uint index;
    FontError error;
}

/**
Builds a catalog from `sources` over `vfs` (FTD21): lists, stats, reuses the
cache, describes the rest over `options.workers` threads, and writes the
cache back when it changed (FTD24). `authority` opens the source directories,
the targets of links, and the cache directory. A repeated source label is
misuse and fails the build with `badValue` before anything is read.
*/
IoResult!void buildCatalog(V)(V* vfs, scope const(FontSource)[] sources, in BuildOptions options,
    AmbientAuthority authority, out Catalog catalog, out BuildReport report)
if (isVfs!V)
{
    foreach (i, a; sources)
        foreach (b; sources[0 .. i])
            if (a.label == b.label)
                return ioErr!void(ErrorKind.invalidName, cast(typeof(IoError.init.op)) 0, 0,
                    IoError.init.stage, "a source label is repeated");
    catalog.policy_ = options.corrections;

    UniqueBuffer!char scratch;
    foreach (s; sources)
    {
        CatalogSource c;
        c.kind = s.kind;
        c.label = catalog.pools_.add(s.label);
        c.path = catalog.pools_.add(s.path);
        c.maps = s.maps;
        c.bytes = s.bytes;
        catalog.sources_.put(c);
    }

    // The cache, read first (FTD24).
    CacheContents cache;
    const cacheUsed = options.cacheDirectory.length != 0;
    if (cacheUsed)
        readCache(vfs, options, authority, cache, report);

    // List every source (FTD16–FTD18).
    UniqueBuffer!Listed listed;
    UniqueBuffer!char names;
    foreach (i, s; sources)
        listSource(vfs, cast(uint) i, s, authority, listed, names, report);

    // Stat, resolve links, drop repeats, reuse the cache; load the rest in batches.
    UniqueBuffer!(FileJob!V*) jobs;
    CacheOut written;
    PathSet seen;
    const workers = workerCount(options.workers);
    bool cacheChanged = !cacheUsed || cache.discarded != CacheDiscard.none;
    foreach (ref l; listed[])
    {
        const source = sources[l.source];
        auto jobPtr = newJob!V();
        ref job = *jobPtr;
        job.source = l.source;
        job.identity = l.identity;
        if (source.kind == SourceKind.memory)
        {
            job.bytes = source.bytes;
            job.size = source.bytes.length;
        }
        else
        {
            const path = names[][l.path.offset .. l.path.offset + l.path.length];
            const loaded = resolveFile(vfs, path, authority, job, scratch, seen);
            if (loaded == Load.duplicate)
            {
                freeJob(jobPtr);
                continue;
            }
            if (loaded == Load.failed)
            {
                // Reported in catalog order when its batch is merged.
                job.loadFailed = true;
                report.listed++;
                jobs.put(jobPtr);
                continue;
            }
        }
        report.listed++;
        const key = names[][l.identity.offset .. l.identity.offset + l.identity.length];
        const hit = cache.find(source.label, key, job.size, job.modifiedNs, job.hasModified);
        if (hit != size_t.max)
        {
            job.fromCache = true;
            job.cached = hit;
            report.reused++;
        }
        else
        {
            cacheChanged = true;
            if (source.kind != SourceKind.memory && !readFile(vfs, authority, source.maps, job))
                job.loadFailed = true;
        }
        jobs.put(jobPtr);
        if (batchFull!V(jobs[]))
            flush!V(jobs, workers, options.corrections, catalog, cache, names, report, written);
    }
    flush!V(jobs, workers, options.corrections, catalog, cache, names, report, written);
    if (cache.files.length != report.reused)
        cacheChanged = true; // a cached file is no longer listed

    buildFamilyIndex(catalog);
    if (cacheUsed && cacheChanged)
        writeCache(vfs, options, authority, catalog, written, report);
    return ioOk();
}

/// How a file load ended.
private enum Load : ubyte
{
    loaded,
    duplicate,
    failed,
}

/// The identity text of a listed file.
private const(char)[] identityText(ref const UniqueBuffer!char names, in Listed l) pure
    => names[][l.identity.offset .. l.identity.offset + l.identity.length];

private BuildOutcome failure(uint source, IoError io, bool linkLimited) pure
{
    BuildOutcome o;
    o.kind = linkLimited ? OutcomeKind.linkLimit : OutcomeKind.io;
    o.source = source;
    o.io = io;
    return o;
}

/// The worker count for `requested` (0: one per processor), within `maxCatalogWorkers`.
private uint workerCount(uint requested)
{
    uint n = requested;
    if (n == 0)
        n = processorCount();
    return n < 1 ? 1 : n > maxCatalogWorkers ? maxCatalogWorkers : n;
}

private uint processorCount() @trusted
{
    version (Posix)
    {
        import core.sys.posix.unistd : sysconf, _SC_NPROCESSORS_ONLN;

        const n = sysconf(_SC_NPROCESSORS_ONLN);
        return n > 0 ? cast(uint) n : 1;
    }
    else version (Windows)
    {
        import core.sys.windows.winbase : GetSystemInfo, SYSTEM_INFO;

        SYSTEM_INFO info;
        GetSystemInfo(&info);
        return info.dwNumberOfProcessors;
    }
    else
        return 1;
}

/// Whether a batch should be parsed now: many files, or many bytes held in memory.
private bool batchFull(V)(scope const(FileJob!V*)[] jobs) pure
{
    if (jobs.length >= 4_096)
        return true;
    ulong held;
    foreach (j; jobs)
        held += j.owned.length;
    return held >= 256UL << 20;
}

// ---------------------------------------------------------------------------
// Listing
// ---------------------------------------------------------------------------

/// Lists source `index` into `listed`, its identities and paths into `names`.
private void listSource(V)(V* vfs, uint index, in FontSource s, AmbientAuthority authority,
    ref UniqueBuffer!Listed listed, ref UniqueBuffer!char names, ref BuildReport report)
{
    const from = listed.length;
    final switch (s.kind)
    {
        case SourceKind.memory:
        {
            ubyte[32] hash;
            if (s.contentHash.length == 32)
                hash[] = s.contentHash[];
            else
                hash = blake3(s.bytes);
            static immutable hex = "0123456789abcdef";
            const at = cast(uint) names.length;
            foreach (b; hash)
            {
                names.put(hex[b >> 4]);
                names.put(hex[b & 15]);
            }
            listed.put(Listed(index, StringRef(at, 64), StringRef.init));
            return;
        }
        case SourceKind.files:
            foreach (n; s.names)
            {
                const id = addName(names, n);
                listed.put(Listed(index, id, addPath(names, s.path, n)));
            }
            break;
        case SourceKind.directory, SourceKind.bundle:
            walkDirectory(vfs, index, s.path, "", s.recurse, 0, authority, listed, names, report);
            break;
        case SourceKind.platform:
        {
            auto p = listPlatformFonts(s.platformOptions);
            foreach (issue; p.issues)
            {
                BuildOutcome o;
                o.kind = issue.kind == PlatformProblem.libraryUnavailable ? OutcomeKind.libraryUnavailable
                    : issue.kind == PlatformProblem.symbolMissing ? OutcomeKind.symbolMissing
                    : issue.kind == PlatformProblem.serviceFailed ? OutcomeKind.serviceFailed
                    : OutcomeKind.directoryUnavailable;
                o.source = index;
                o.code = issue.code;
                report.add(o, issue.name);
            }
            foreach (f; p.files)
            {
                if (!isFontFileName(splitPath(f).base))
                {
                    report.skipped++;
                    continue;
                }
                const id = addName(names, f);
                listed.put(Listed(index, id, id));
            }
            foreach (d; p.directories)
                walkDirectory(vfs, index, d, d, false, 0, authority, listed, names, report);
            break;
        }
    }
    sortListed(listed[][from .. $], names);
}

private StringRef addName(ref UniqueBuffer!char names, scope const(char)[] s) pure
{
    const at = cast(uint) names.length;
    names.put(s);
    return StringRef(at, cast(uint) s.length);
}

private StringRef addPath(ref UniqueBuffer!char names, scope const(char)[] dir, scope const(char)[] name) pure
{
    const at = cast(uint) names.length;
    names.put(dir);
    if (dir.length && dir[$ - 1] != '/' && dir[$ - 1] != '\\')
        names.put('/');
    names.put(name);
    return StringRef(at, cast(uint)(names.length - at));
}

/**
Lists the font files under `path` (`prefix` the identity of the directory),
recursing when asked. A link is followed by `loadFile`, after listing; a
directory link is not entered, as a link's target is outside the walked tree.
*/
private void walkDirectory(V)(V* vfs, uint index, scope const(char)[] path, scope const(char)[] prefix,
    bool recurse, uint depth, AmbientAuthority authority, ref UniqueBuffer!Listed listed,
    ref UniqueBuffer!char names, ref BuildReport report)
{
    auto root = openRoot!(Rights.readOnly)(vfs, path, authority);
    if (root.hasError)
    {
        BuildOutcome o;
        o.source = index;
        o.io = root.error;
        report.add(o, path);
        return;
    }
    auto listing = root.value.list();
    if (listing.hasError)
    {
        BuildOutcome o;
        o.source = index;
        o.io = listing.error;
        report.add(o, path);
        return;
    }
    UniqueBuffer!char child, childId;
    for (;;)
    {
        const more = listing.value.next();
        if (more.hasError)
        {
            BuildOutcome o;
            o.source = index;
            o.io = more.error;
            report.add(o, path);
            return;
        }
        if (!more.value)
            break;
        const e = listing.value.front;
        EntryKind kind = e.kind;
        if (kind == EntryKind.unknown)
        {
            const st = root.value.statAt(e.name);
            kind = st.hasValue ? st.value.kind : EntryKind.other;
        }
        if (kind == EntryKind.directory)
        {
            if (!recurse)
                continue;
            if (depth + 1 >= maxSourceDepth)
            {
                BuildOutcome o;
                o.kind = OutcomeKind.io;
                o.source = index;
                o.io = IoError(ErrorKind.other);
                report.add(o, path);
                continue;
            }
            joinPath(child, path, e.name);
            joinPath(childId, prefix, e.name);
            walkDirectory(vfs, index, child[], prefix.length ? childId[] : e.name, true, depth + 1,
                authority, listed, names, report);
            continue;
        }
        if (kind != EntryKind.regular && kind != EntryKind.symlink)
            continue;
        if (!isFontFileName(e.name))
        {
            report.skipped++;
            continue;
        }
        const id = prefix.length ? addPath(names, prefix, e.name) : addName(names, e.name);
        listed.put(Listed(index, id, addPath(names, path, e.name)));
    }
}

/// Sorts one source's listed files by identity, byte order (FTD17).
private void sortListed(scope Listed[] l, ref const UniqueBuffer!char names) pure
{
    // Insertion sort over runs that are mostly ordered already; fine for directories.
    foreach (i; 1 .. l.length)
    {
        auto x = l[i];
        size_t j = i;
        while (j > 0 && identityText(names, l[j - 1]) > identityText(names, x))
        {
            l[j] = l[j - 1];
            --j;
        }
        l[j] = x;
    }
}

// ---------------------------------------------------------------------------
// Loading
// ---------------------------------------------------------------------------

/// The resolved paths seen so far, to list each file once (FTD17).
private struct PathSet
{
    @safe nothrow @nogc:

    private UniqueBuffer!char text;
    private UniqueBuffer!StringRef paths;
    private UniqueBuffer!uint slots; // indices + 1 into `paths`; 0 is empty

    @disable this(this);

    /// Adds `p`; false if it was already present.
    bool add(scope const(char)[] p) scope
    {
        if (slots.length < 2 * paths.length + 16)
            grow();
        const mask = slots.length - 1;
        size_t at = hashOf(p) & mask;
        while (slots[at])
        {
            const s = paths[slots[at] - 1];
            if (text[][s.offset .. s.offset + s.length] == p)
                return false;
            at = (at + 1) & mask;
        }
        const ref_ = StringRef(cast(uint) text.length, cast(uint) p.length);
        text.put(p);
        paths.put(ref_);
        slots[at] = cast(uint) paths.length;
        return true;
    }

    private void grow() scope
    {
        size_t size = 64;
        while (size < 4 * (paths.length + 1))
            size *= 2;
        slots.clear(false);
        foreach (_; 0 .. size)
            slots.put(0);
        foreach (i, s; paths[])
        {
            size_t at = hashOf(text[][s.offset .. s.offset + s.length]) & (size - 1);
            while (slots[at])
                at = (at + 1) & (size - 1);
            slots[at] = cast(uint)(i + 1);
        }
    }

    private static size_t hashOf(scope const(char)[] p) pure
    {
        ulong h = 0xcbf2_9ce4_8422_2325;
        foreach (c; p)
            h = (h ^ c) * 0x100_0000_01b3;
        return cast(size_t) h;
    }
}

/**
Resolves `path`'s links (at most `maxFontLinks`) into `job.resolved`,
stats the file, and drops a path already seen. Errors land in `job`.
*/
private Load resolveFile(V)(V* vfs, scope const(char)[] path, AmbientAuthority authority,
    ref FileJob!V job, ref UniqueBuffer!char scratch, ref PathSet seen)
{
    UniqueBuffer!char current;
    current.put(path);
    char[4096] target;
    foreach (hop; 0 .. maxFontLinks + 1)
    {
        const parts = splitPath(current[]);
        const dir = parts.dir, base = parts.base;
        auto root = openRoot!(Rights.readOnly)(vfs, dir, authority);
        if (root.hasError)
        {
            job.ioError = root.error;
            return Load.failed;
        }
        const st = root.value.statAt(base, StatMask.mtime);
        if (st.hasError)
        {
            job.ioError = st.error;
            return Load.failed;
        }
        if (st.value.kind == EntryKind.symlink)
        {
            if (hop == maxFontLinks)
            {
                job.linkLimited = true;
                return Load.failed;
            }
            const link = root.value.readlinkAt(base, target[]);
            if (link.hasError)
            {
                job.ioError = (() @trusted => link.error)();
                return Load.failed;
            }
            if (isAbsolute(link.value))
            {
                current.clear(false);
                current.put(link.value);
            }
            else
            {
                joinPath(scratch, dir, link.value);
                current.clear(false);
                current.put(scratch[]);
            }
            continue;
        }
        normalizePath(current);
        if (!seen.add(current[]))
            return Load.duplicate;
        job.size = st.value.size;
        job.hasModified = st.value.hasMtime;
        job.modifiedNs = st.value.mtimeNs;
        job.resolved.put(current[]);
        return Load.loaded;
    }
    assert(0);
}

/// Maps or reads the file `resolveFile` found into `job`; false, with the error in `job`, on failure.
private bool readFile(V)(V* vfs, AmbientAuthority authority, bool maps, ref FileJob!V job)
{
    const parts = splitPath(job.resolved[]);
    auto root = openRoot!(Rights.readOnly)(vfs, parts.dir, authority);
    if (root.hasError)
    {
        job.ioError = root.error;
        return false;
    }
    {
        const base = parts.base;
        auto file = root.value.openFile!(OpenMode.read)(base);
        if (file.hasError)
        {
            job.ioError = file.error;
            return false;
        }
        static if (hasMap!V)
            if (maps)
            {
                auto m = file.value.map();
                if (m.hasError)
                {
                    job.ioError = m.error;
                    return false;
                }
                job.mapping = move(m.value);
                job.bytes = (() @trusted => job.mapping.bytes)();
                return true;
            }
        foreach (_; 0 .. job.size)
            job.owned.put(0);
        size_t got;
        while (got < job.owned.length)
        {
            const n = file.value.read(job.owned[][got .. $]);
            if (n.hasError)
            {
                job.ioError = n.error;
                return false;
            }
            if (n.value == 0)
                break;
            got += n.value;
        }
        job.bytes = (() @trusted => cast(const(ubyte)[]) job.owned[][0 .. got])();
        return true;
    }
}

// ---------------------------------------------------------------------------
// Parsing and merging
// ---------------------------------------------------------------------------

/// The files the next cache write holds, referring into the catalog (FTD22).
private struct CacheOut
{
    UniqueBuffer!CachedFile files;
    UniqueBuffer!CachedFailure failures;

    @disable this(this);
}

import sparkles.font.catalog_cache : CachedFailure;

/// Describes every face of `job`'s file into its own pools (a worker's task).
private void parseJob(V)(FileJob!V* job, CorrectionPolicy policy)
{
    const c = openCollection(job.bytes);
    if (c.hasError)
    {
        job.fileFailed = true;
        job.fileError = c.error;
        return;
    }
    foreach (i; 0 .. c.value.count)
    {
        const f = openFace(job.bytes, i, policy);
        if (f.hasError)
        {
            job.failures.put(FaceFailure(i, f.error));
            continue;
        }
        FaceRecord r;
        describeFace(f.value, job.pools, r);
        job.records.put(r);
    }
}

/**
Runs `work(0)` … `work(count - 1)` over `workers` threads, the calling thread
among them, each index once. The threads are druntime's low-level ones: they
allocate nothing from the GC, and neither may `work`.
*/
private void runParallel(uint workers, size_t count, scope void delegate(size_t) @safe nothrow @nogc work)
    @trusted
{
    import core.thread.osthread : createLowLevelThread, joinLowLevelThread;
    import core.thread.types : ThreadID;

    static struct Shared
    {
        shared size_t next;
        size_t count;
        void delegate(size_t) @safe nothrow @nogc work;

        void run() nothrow @nogc
        {
            for (;;)
            {
                const i = atomicOp!"+="(next, 1) - 1;
                if (i >= count)
                    return;
                work(i);
            }
        }
    }

    auto s = Shared(0, count, work);
    const extra = workers > count ? cast(uint) count : workers;
    ThreadID[maxCatalogWorkers] ids;
    foreach (k; 1 .. extra)
        ids[k] = createLowLevelThread(cast(void delegate() nothrow) &s.run);
    s.run();
    foreach (k; 1 .. extra)
        if (ids[k] != ThreadID.init)
            joinLowLevelThread(ids[k]);
}

/// Parses the batch's new files, then merges every file of it in order, and frees the batch.
private void flush(V)(ref UniqueBuffer!(FileJob!V*) jobs, uint workers, CorrectionPolicy policy,
    ref Catalog catalog, ref const CacheContents cache, ref const UniqueBuffer!char names,
    ref BuildReport report, ref CacheOut written)
{
    auto batch = jobs[];
    runParallel(workers, batch.length, (i) {
        auto j = batch[i];
        if (!j.fromCache && !j.loadFailed)
            parseJob(j, policy);
    });
    foreach (j; batch)
    {
        const identity = names[][j.identity.offset .. j.identity.offset + j.identity.length];
        if (j.loadFailed)
        {
            report.failed++;
            report.add(failure(j.source, j.ioError, j.linkLimited), identity);
        }
        else if (j.fromCache)
            mergeCached(catalog, cache, cache.files[j.cached], j, identity, report, written);
        else
            mergeParsed(catalog, j, identity, report, written);
        freeJob(j);
    }
    jobs.clear(false);
}

/// The cache entry of a file, referring to the catalog's strings and the records from `first`.
private CachedFile cacheEntryOf(V)(ref Catalog catalog, FileJob!V* j, scope const(char)[] identity,
    uint first, ref CacheOut written)
{
    CachedFile f;
    f.label = catalog.sources_[j.source].label;
    f.identity = catalog.pools_.add(identity);
    f.size = j.size;
    f.modifiedNs = j.modifiedNs;
    f.hasModified = j.hasModified;
    f.records = PoolSpan(first, cast(uint)(catalog.records_.length - first));
    return f;
}

private void mergeParsed(V)(ref Catalog catalog, FileJob!V* j, scope const(char)[] identity,
    ref BuildReport report, ref CacheOut written)
{
    const first = cast(uint) catalog.records_.length;
    if (j.fileFailed)
    {
        report.failed++;
        BuildOutcome o;
        o.kind = OutcomeKind.font;
        o.source = j.source;
        o.font = j.fileError;
        report.add(o, identity);
    }
    else
    {
        report.described++;
        foreach (x; j.failures[])
        {
            BuildOutcome o;
            o.kind = OutcomeKind.font;
            o.source = j.source;
            o.face = x.index;
            o.font = x.error;
            report.add(o, identity);
        }
    }
    const id = catalog.pools_.add(identity);
    foreach (ref r; j.records[])
        appendRecord(catalog, r, j.pools, j.source, id, j.size, j.modifiedNs, j.hasModified);
    auto f = cacheEntryOf(catalog, j, identity, first, written);
    f.failed = j.fileFailed;
    f.error = j.fileError;
    f.failures.offset = cast(uint) written.failures.length;
    foreach (x; j.failures[])
        written.failures.put(CachedFailure(x.index, x.error));
    f.failures.count = cast(uint) j.failures.length;
    written.files.put(f);
}

private void mergeCached(V)(ref Catalog catalog, ref const CacheContents cache, in CachedFile c,
    FileJob!V* j, scope const(char)[] identity, ref BuildReport report, ref CacheOut written)
{
    const first = cast(uint) catalog.records_.length;
    if (c.failed)
    {
        report.failed++;
        BuildOutcome o;
        o.kind = OutcomeKind.font;
        o.source = j.source;
        o.font = c.error;
        report.add(o, identity);
    }
    foreach (x; cache.failures[][c.failures.offset .. c.failures.offset + c.failures.count])
    {
        BuildOutcome o;
        o.kind = OutcomeKind.font;
        o.source = j.source;
        o.face = x.index;
        o.font = x.error;
        report.add(o, identity);
    }
    const id = catalog.pools_.add(identity);
    foreach (ref r; cache.records[][c.records.offset .. c.records.offset + c.records.count])
        appendRecord(catalog, r, cache.pools, j.source, id, j.size, j.modifiedNs, j.hasModified);
    auto f = cacheEntryOf(catalog, j, identity, first, written);
    f.failed = c.failed;
    f.error = c.error;
    f.failures.offset = cast(uint) written.failures.length;
    foreach (x; cache.failures[][c.failures.offset .. c.failures.offset + c.failures.count])
        written.failures.put(x);
    f.failures.count = c.failures.count;
    written.files.put(f);
}

/// Appends a copy of `r`, whose storage is in `from`, to the catalog.
private void appendRecord(ref Catalog catalog, in FaceRecord r, ref const RecordPools from, uint source,
    StringRef identity, ulong size, long modifiedNs, bool hasModified)
{
    auto to = &catalog.pools_;
    FaceRecord c = r;
    c.source = source;
    c.identity = identity;
    c.fileSize = size;
    c.modifiedNs = modifiedNs;
    c.hasModified = hasModified;
    c.family = to.add(from.text(r.family));
    c.styleName = to.add(from.text(r.styleName));
    c.fullName = to.add(from.text(r.fullName));
    c.postScriptName = to.add(from.text(r.postScriptName));
    c.aliases.offset = cast(uint) to.aliases.length;
    foreach (a; from.aliasesOf(r))
        to.aliases.put(to.add(from.text(a)));
    c.coverage.offset = cast(uint) to.ranges.length;
    to.ranges.put(from.coverageOf(r));
    c.axes.offset = cast(uint) to.axes.length;
    to.axes.put(from.axesOf(r));
    c.errors.offset = cast(uint) to.errors.length;
    to.errors.put(from.errorsOf(r));
    catalog.records_.put(c);
}

/// Sorts every record's aliases into the family index (FTD26, FTD30).
private void buildFamilyIndex(ref Catalog catalog)
{
    foreach (i, ref r; catalog.records_[])
        foreach (a; catalog.pools_.aliasesOf(r))
            catalog.families_.put(FamilyEntry(a, cast(uint) i));
    auto f = catalog.families_[];
    // Insertion sort is stable: equal names keep catalog order.
    foreach (i; 1 .. f.length)
    {
        auto x = f[i];
        size_t j = i;
        while (j > 0 && compareFolded(catalog.text(f[j - 1].alias_), catalog.text(x.alias_)) > 0)
        {
            f[j] = f[j - 1];
            --j;
        }
        f[j] = x;
    }
}

// ---------------------------------------------------------------------------
// The cache file
// ---------------------------------------------------------------------------

private void readCache(V)(V* vfs, in BuildOptions options, AmbientAuthority authority, ref CacheContents cache,
    ref BuildReport report)
{
    BuildOutcome o;
    o.kind = OutcomeKind.cacheDiscarded;
    auto root = openRoot!(Rights.readOnly)(vfs, options.cacheDirectory, authority);
    if (root.hasError)
    {
        o.io = root.error;
        o.discard = cache.discarded = CacheDiscard.unreadable;
        report.add(o, options.cacheName);
        return;
    }
    auto file = root.value.openFile!(OpenMode.read)(options.cacheName);
    if (file.hasError)
    {
        // No cache yet is not a problem worth reporting.
        cache.discarded = CacheDiscard.unreadable;
        if (file.error.kind != ErrorKind.notFound)
        {
            o.io = file.error;
            o.discard = CacheDiscard.unreadable;
            report.add(o, options.cacheName);
        }
        return;
    }
    UniqueBuffer!ubyte bytes;
    ubyte[64 * 1024] chunk;
    for (;;)
    {
        const n = file.value.read(chunk[]);
        if (n.hasError)
        {
            o.io = n.error;
            o.discard = cache.discarded = CacheDiscard.unreadable;
            report.add(o, options.cacheName);
            return;
        }
        if (n.value == 0)
            break;
        bytes.put(chunk[0 .. n.value]);
    }
    decodeCache(bytes[], options.corrections, cache);
    if (cache.discarded != CacheDiscard.none)
    {
        o.discard = cache.discarded;
        report.add(o, options.cacheName);
    }
}

private void writeCache(V)(V* vfs, in BuildOptions options, AmbientAuthority authority, ref const Catalog catalog,
    ref const CacheOut written, ref BuildReport report)
{
    UniqueBuffer!ubyte bytes;
    encodeCache(written.files[], catalog.records_[], written.failures[], catalog.pools_, catalog.policy_, bytes);
    BuildOutcome o;
    o.kind = OutcomeKind.io;
    enum Rights writing = cast(Rights)(Rights.readOnly | Rights.create | Rights.write | Rights.rename);
    auto root = openRoot!writing(vfs,
        options.cacheDirectory, authority);
    if (root.hasError)
    {
        o.io = root.error;
        report.add(o, options.cacheName);
        return;
    }
    const w = root.value.writeFileAtomic(options.cacheName, bytes[]);
    if (w.hasError)
    {
        o.io = w.error;
        report.add(o, options.cacheName);
    }
}
