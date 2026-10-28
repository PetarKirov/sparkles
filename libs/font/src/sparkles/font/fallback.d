/**
Fallback chains (`docs/specs/font/discovery.md` FTD31–FTD34, FTD38; SPEC.md
FTD5–FTD6): the ordered faces consulted when the preferred one cannot draw a
character, with user routes and the generated box-drawing face as ordinary
entries.

`buildChain` turns a primary request and an item list (routes, `primary`,
then families, `boxDrawing` and `everything`) into entries, each a record
with the match that chose it and its provenance. A record appears once per
coordinates and synthesis, so faces whose coverage repeats an earlier one's
stay: they may shape what the earlier cannot. `characterEntry` answers from
coverage alone. A `FaceStore`, a value beside the chain (FTA5), opens faces
on first use; a `CharacterCache` memoizes character answers under the
chain's identity. A chain never changes; a store and a cache belong to one
thread at a time (FTD14).
*/
module sparkles.font.fallback;

import sparkles.base.buffer : UniqueBuffer;
import sparkles.base.hash.blake3 : Blake3;
import sparkles.base.unique : makeUnique;
import sparkles.base.vfs : AmbientAuthority, isVfs;

import sparkles.font.box_face : boxFaceCoverage, boxFaceFamily, boxFaceMeasure, buildBoxFace;
import sparkles.font.catalog : BuildOutcome, Catalog, CatalogSource, compareFolded, FileJob, freeJob,
    openRecordFile, OutcomeKind;
import sparkles.font.cmap : charMap, CodepointRange;
import sparkles.font.corrections : CorrectionPolicy;
import sparkles.font.errors : FontError, FontErrorKind, FontResult, fontErr, fontOk;
import sparkles.font.face : Face, openFace;
import sparkles.font.face_record : ColourFormat, FaceRecord, RecordPools, StringRef;
import sparkles.font.instance : instance, InstanceSize, Synthesis, UserCoordinate;
import sparkles.font.matching : Match, matchFont, MatchRequest;
import sparkles.font.metrics : cellMetrics;
import sparkles.font.outlines : PointWorkspace;
import sparkles.font.units : Ppem;

@safe nothrow @nogc:

/// What a chain item contributes (FTD31).
enum ChainItemKind : ubyte
{
    route,
    primary,
    family,
    boxDrawing,
    everything,
}

/// One item of a chain's specification (FTD31). Requests and ranges are borrowed for the build.
struct ChainItem
{
    @safe pure nothrow @nogc:

    ChainItemKind kind;
    MatchRequest request;
    /// A route's scalars, sorted and disjoint.
    const(CodepointRange)[] ranges;

    /// The primary request's match.
    static ChainItem primary() => ChainItem(ChainItemKind.primary);
    /// The match of `request`.
    static ChainItem family(MatchRequest request) => ChainItem(ChainItemKind.family, request);
    /// The match of `request`, answering only for `ranges`.
    static ChainItem route(const(CodepointRange)[] ranges, MatchRequest request)
        => ChainItem(ChainItemKind.route, request, ranges);
    /// The generated box-drawing face over the primary match.
    static ChainItem boxDrawing() => ChainItem(ChainItemKind.boxDrawing);
    /// Every other family's match for the primary request's values.
    static ChainItem everything() => ChainItem(ChainItemKind.everything);
}

/// A chain entry (FTD32).
struct ChainEntry
{
    @safe pure nothrow @nogc:

    ChainItemKind kind;
    /// The record's index in the catalog; `uint.max` for the box-drawing face.
    uint record = uint.max;
    /// The match that chose it.
    Match match;
    /// The item that contributed it.
    uint item;
    /// The family name that selected it, as provenance.
    StringRef family;
    /// A route's ranges, in the chain's range pool.
    uint rangesOffset, rangesCount;

    /// Whether this is the generated box-drawing face.
    bool isBoxDrawing() const pure => kind == ChainItemKind.boxDrawing;
}

/// A text or emoji presentation for character lookup (FTD33).
enum Presentation : ubyte
{
    unspecified,
    text,
    emoji,
}

/// `characterEntry`'s answer when no entry holds the scalar.
enum size_t noEntry = size_t.max;

/// An item that contributed nothing, and why.
struct ChainOutcome
{
    uint item;
    /// `noMatch` (`FontErrorKind.missingTable` stands for it) or the box face's error.
    bool noMatch;
}

/// A fallback chain (FTD31–FTD34).
struct FallbackChain
{
    @safe nothrow @nogc:

    private const(Catalog)* catalog_;
    private UniqueBuffer!ChainEntry entries_;
    private UniqueBuffer!CodepointRange ranges_;
    private UniqueBuffer!char strings_;
    private UniqueBuffer!ChainOutcome outcomes_;
    private size_t primary_ = noEntry;
    private ubyte[16] identity_;
    // The box-drawing face's record (FTD38).
    private RecordPools boxPools_;
    private FaceRecord boxRecord_;

    @disable this(this);

    /// The entries, in order.
    const(ChainEntry)[] entries() const return scope pure => entries_[];
    /// The catalog the chain was built over.
    ref const(Catalog) catalog() const return pure => *catalog_;
    /// The primary match's entry, or `noEntry`.
    size_t primary() const scope pure => primary_;
    /// The items that contributed nothing.
    const(ChainOutcome)[] outcomes() const return scope pure => outcomes_[];
    /// The chain's 128-bit identity (FTD34).
    ubyte[16] identity() const scope pure => identity_;
    /// The family name an entry was selected by.
    const(char)[] familyOf(in ChainEntry e) const return scope pure
        => strings_[][e.family.offset .. e.family.offset + e.family.length];
    /// A route entry's ranges.
    const(CodepointRange)[] routeRanges(in ChainEntry e) const return scope pure
        => ranges_[][e.rangesOffset .. e.rangesOffset + e.rangesCount];

    /// The record an entry stands for: the catalog's, or the box-drawing face's (FTD38).
    ref const(FaceRecord) recordOf(in ChainEntry e) const return pure
        => e.isBoxDrawing ? boxRecord_ : catalog_.records[e.record];
    /// The pools `recordOf(e)` refers into.
    ref const(RecordPools) poolsOf(in ChainEntry e) const return pure
        => e.isBoxDrawing ? boxPools_ : catalog_.pools;

    /// Whether entry `e` answers for `cp` by coverage, its route's ranges included.
    bool holds(in ChainEntry e, dchar cp) const pure
    {
        if (e.kind == ChainItemKind.route && !inRanges(routeRanges(e), cp))
            return false;
        return poolsOf(e).covers(recordOf(e), cp);
    }

    /**
    The route that claims `cp` (FTD33): the first route entry whose ranges
    hold `cp` and whose face covers it, or `noEntry`. A route overrides the
    primary for its scalars; one whose face lacks the scalar lets it fall
    through to the chain. Layout splits spans so that each cluster a route
    claims, by its base scalar, is shaped apart from the others (FTD7).
    Costs O(routes · log k).
    */
    size_t routeEntry(dchar cp) const pure
    {
        foreach (i, ref e; entries_[])
        {
            if (e.kind != ChainItemKind.route)
                break; // routes come first
            if (holds(e, cp))
                return i;
        }
        return noEntry;
    }

    /**
    The first entry holding `cp` (FTD33), without opening any face: with
    emoji presentation the first with a colour format, else the first; with
    text presentation the first without one, else the first. `noEntry` when
    none holds it. Costs O(E log k).
    */
    size_t characterEntry(dchar cp, Presentation presentation = Presentation.unspecified) const pure
    {
        size_t first = noEntry;
        foreach (i, ref e; entries_[])
        {
            if (!holds(e, cp))
                continue;
            if (presentation == Presentation.unspecified)
                return i;
            const colour = recordOf(e).colourFormats != 0;
            if (presentation == Presentation.emoji ? colour : !colour)
                return i;
            if (first == noEntry)
                first = i;
        }
        return first;
    }
}

private bool inRanges(scope const(CodepointRange)[] ranges, dchar cp) pure
{
    size_t lo = 0, hi = ranges.length;
    while (lo < hi)
    {
        const mid = (lo + hi) / 2;
        if (ranges[mid].last < cp)
            lo = mid + 1;
        else
            hi = mid;
    }
    return lo < ranges.length && ranges[lo].first <= cp;
}

/**
Builds a chain over `catalog` (FTD31): `items` must be routes, then
`primary`, then any others (`badValue` otherwise, or for an invalid
request). An item matching nothing contributes nothing and is listed in
`outcomes`; without a primary match `boxDrawing` contributes nothing too.
Costs one match per item, O(F) matches for `everything`, and O(R) to hash
the identity.
*/
FontResult!bool buildChain(ref const Catalog catalog, in MatchRequest primary, scope const(ChainItem)[] items,
    out FallbackChain chain)
{
    size_t at;
    while (at < items.length && items[at].kind == ChainItemKind.route)
        ++at;
    if (at >= items.length || items[at].kind != ChainItemKind.primary)
        return fontErr!bool(FontError(FontErrorKind.badValue));
    foreach (it; items[at + 1 .. $])
        if (it.kind == ChainItemKind.route || it.kind == ChainItemKind.primary)
            return fontErr!bool(FontError(FontErrorKind.badValue));

    chain.catalog_ = (() @trusted => &catalog)(); // a chain borrows its catalog (FTD14)
    UniqueBuffer!bool seen; // records with an entry
    foreach (_; 0 .. catalog.records.length)
        seen.put(false);

    foreach (k, ref it; items)
    {
        const item = cast(uint) k;
        final switch (it.kind)
        {
            case ChainItemKind.route, ChainItemKind.primary, ChainItemKind.family:
            {
                const request = it.kind == ChainItemKind.primary ? primary : it.request;
                const m = matchFont(catalog, request);
                if (m.hasError)
                    return fontErr!bool(m.error);
                if (!m.value.found)
                {
                    chain.outcomes_.put(ChainOutcome(item, true));
                    continue;
                }
                ChainEntry e;
                e.kind = it.kind;
                e.record = m.value.record;
                e.match = m.value;
                e.item = item;
                e.family = chain.addString(request.families[m.value.score.family]);
                if (it.kind == ChainItemKind.route)
                {
                    e.rangesOffset = cast(uint) chain.ranges_.length;
                    chain.ranges_.put(it.ranges);
                    e.rangesCount = cast(uint) it.ranges.length;
                }
                else if (chain.repeats(seen, e))
                    continue;
                if (it.kind == ChainItemKind.primary)
                    chain.primary_ = chain.entries_.length;
                if (it.kind != ChainItemKind.route)
                    seen[e.record] = true;
                chain.entries_.put(e);
                break;
            }
            case ChainItemKind.boxDrawing:
                if (chain.primary_ == noEntry)
                {
                    chain.outcomes_.put(ChainOutcome(item, true));
                    continue;
                }
                ChainEntry e;
                e.kind = ChainItemKind.boxDrawing;
                e.item = item;
                e.match = chain.entries_[chain.primary_].match;
                e.family = chain.addString(boxFaceFamily);
                chain.entries_.put(e);
                chain.describeBoxFace();
                break;
            case ChainItemKind.everything:
                addEverything(catalog, primary, item, chain, seen);
                break;
        }
    }
    chain.identity_ = chainIdentity(catalog, primary, items, chain);
    return fontOk(true);
}

private StringRef addString(ref FallbackChain chain, scope const(char)[] s) pure
{
    const at = cast(uint) chain.strings_.length;
    chain.strings_.put(s);
    return StringRef(at, cast(uint) s.length);
}

/// Whether an entry for `e`'s record, coordinates and synthesis exists already (FTD31).
private bool repeats(ref const FallbackChain chain, ref const UniqueBuffer!bool seen, in ChainEntry e) pure
{
    if (!seen[e.record])
        return false;
    foreach (ref x; chain.entries_[])
        if (x.kind != ChainItemKind.route && x.record == e.record
                && x.match.userCoordinates == e.match.userCoordinates && x.match.synthesis == e.match.synthesis)
            return true;
    return false;
}

/// FTD31's `everything`: every other family in folded-name order, matched with the primary's values.
private void addEverything(ref const Catalog catalog, in MatchRequest primary, uint item, ref FallbackChain chain,
    ref UniqueBuffer!bool seen)
{
    // Families in folded order: walk records sorted by folded family, catalog order breaking ties.
    UniqueBuffer!uint order;
    foreach (i, ref r; catalog.records)
        if (r.family.length)
            order.put(cast(uint) i);
    auto o = order[];
    foreach (i; 1 .. o.length)
    {
        const x = o[i];
        size_t j = i;
        while (j > 0 && compareFolded(catalog.text(catalog.records[o[j - 1]].family),
                catalog.text(catalog.records[x].family)) > 0)
        {
            o[j] = o[j - 1];
            --j;
        }
        o[j] = x;
    }
    const(char)[] previous;
    foreach (i; o)
    {
        const name = catalog.text(catalog.records[i].family);
        if (previous !is null && compareFolded(previous, name) == 0)
            continue;
        previous = name;
        const(char[])[1] families = [name];
        scope MatchRequest r = primary;
        r.families = families[];
        const m = matchFont(catalog, r);
        if (m.hasError || !m.value.found)
            continue;
        ChainEntry e;
        e.kind = ChainItemKind.everything;
        e.record = m.value.record;
        e.match = m.value;
        e.match.score.family = 0;
        e.item = item;
        e.family = chain.addString(name);
        if (chain.repeats(seen, e))
            continue;
        seen[e.record] = true;
        chain.entries_.put(e);
    }
}

/// The box-drawing face's record: its family, the primary match's style, its coverage (FTD38).
private void describeBoxFace(ref FallbackChain chain)
{
    const p = chain.entries_[chain.primary_].match;
    auto r = &chain.boxRecord_;
    r.family = chain.boxPools_.add(boxFaceFamily);
    r.weightMin = r.weightMax = p.weight;
    r.widthMin = r.widthMax = p.width;
    r.italicMin = r.italicMax = p.italic;
    r.obliqueMin = r.obliqueMax = p.oblique;
    r.coverage.offset = cast(uint) chain.boxPools_.ranges.length;
    chain.boxPools_.ranges.put(boxFaceCoverage());
    r.coverage.count = cast(uint) boxFaceCoverage().length;
    r.unitsPerEm = 0; // known only once built at a ppem
}

/// FTD34: the catalog's policy and record keys, the primary request, the items and every entry.
private ubyte[16] chainIdentity(ref const Catalog catalog, in MatchRequest primary, scope const(ChainItem)[] items,
    ref const FallbackChain chain)
{
    Blake3 h;
    void u32(uint v)
    {
        ubyte[4] b = [cast(ubyte) v, cast(ubyte)(v >> 8), cast(ubyte)(v >> 16), cast(ubyte)(v >> 24)];
        h.put(b[]);
    }
    void u64(ulong v)
    {
        u32(cast(uint) v);
        u32(cast(uint)(v >> 32));
    }
    void str(scope const(char)[] s)
    {
        u32(cast(uint) s.length);
        h.put(s);
    }
    void request(in MatchRequest r)
    {
        u32(cast(uint) r.families.length);
        foreach (f; r.families)
            str(f);
        u32(r.weight);
        u32(r.width);
        u32(r.style);
        u32(r.obliqueAngle);
        u32(r.synthesizeWeight | r.synthesizeStyle << 1 | r.obliqueOnly << 2);
    }
    u32(catalog.policy);
    foreach (ref r; catalog.records)
    {
        str(catalog.text(catalog.sources[r.source].label));
        str(catalog.text(r.identity));
        u32(r.index);
        u64(r.fileSize);
        u64(r.modifiedNs);
    }
    request(primary);
    foreach (ref it; items)
    {
        u32(it.kind);
        request(it.request);
        u32(cast(uint) it.ranges.length);
        foreach (c; it.ranges)
        {
            u32(c.first);
            u32(c.last);
        }
    }
    foreach (ref e; chain.entries_[])
    {
        u32(e.kind);
        u32(e.record);
        foreach (c; e.match.userCoordinates)
        {
            u32(c.tag.value);
            u32(c.value);
        }
        u32(e.match.synthesis.emboldenStrength);
        u32(e.match.synthesis.obliqueSlant);
    }
    const d = h.finish();
    ubyte[16] id = d[0 .. 16];
    return id;
}

// ---------------------------------------------------------------------------
// The character cache (FTD33)
// ---------------------------------------------------------------------------

/**
Memoized character answers under the key (chain identity, scalar,
presentation), in a fixed table of `slots` entries; a colliding answer
replaces the older one. A separate value: it never changes the chain.
*/
struct CharacterCache(size_t slots = 4_096)
if (slots && (slots & (slots - 1)) == 0)
{
    @safe pure nothrow @nogc:

    private static struct Slot
    {
        ubyte[16] chain;
        dchar cp;
        Presentation presentation;
        bool used;
        size_t entry;
    }

    private Slot[slots] table_;

    /// The answer of `chain.characterEntry(cp, presentation)`, computed once per key.
    size_t characterEntry(ref const FallbackChain chain, dchar cp, Presentation presentation = Presentation.unspecified)
    {
        const id = chain.identity;
        const at = (cp * 0x9E37_79B1u ^ presentation ^ id[0] ^ id[1] << 8) & (slots - 1);
        auto s = &table_[at];
        if (s.used && s.cp == cp && s.presentation == presentation && s.chain == id)
            return s.entry;
        *s = Slot(id, cp, presentation, true, chain.characterEntry(cp, presentation));
        return s.entry;
    }
}

// ---------------------------------------------------------------------------
// The face store (FTD32)
// ---------------------------------------------------------------------------

/// An opened entry of a store.
private struct Opened(V)
{
    bool tried;
    bool open;
    BuildOutcome outcome;
    FileJob!V* file;
    Face face;
}

/// A box-drawing face built at one ppem.
private struct BoxBuild
{
    uint ppem;
    UniqueBuffer!ubyte bytes;
    Face face;
    bool failed;
    FontError error;

    @disable this(this);
}

/**
The faces of a chain's entries, opened on first use (FTD32), and the
box-drawing faces built per ppem. It keeps everything it opens until it is
destroyed; a face it returns stays valid as long as the store does. One
thread at a time (FTD14).
*/
struct FaceStore(V)
if (isVfs!V)
{
    private V* vfs_;
    private const(FallbackChain)* chain_;
    private AmbientAuthority authority_;
    private UniqueBuffer!(Opened!V) entries_;
    private UniqueBuffer!(BoxBuild*) boxes_;

    // The VFS and chain a store borrows: they outlive it (FTD14), which `scope` cannot express here.
    private V* vfs() scope @trusted => cast(V*) vfs_;
    private const(FallbackChain)* chain() scope @trusted => cast(const(FallbackChain)*) chain_;

    @disable this(this);

    /// A store for `chain`'s entries, reading through `vfs` under `authority`.
    this(V* vfs, ref const FallbackChain chain, AmbientAuthority authority)
    {
        vfs_ = vfs;
        chain_ = borrow(chain); // a store borrows its chain (FTD14)
        authority_ = authority;
        foreach (_; 0 .. chain.entries.length)
            entries_.put(Opened!V.init);
    }

    ~this()
    {
        foreach (ref e; entries_[])
            if (e.file !is null)
                freeJob(e.file);
        foreach (b; boxes_[])
            freeBox(b);
    }

    /**
    The face of entry `i`, opening its file the first time (FTD32): the
    file's `stale`, `io` or `linkLimit` outcome, or the face's `font`
    outcome, when it cannot be opened; such an entry answers nothing for the
    store's life. The box-drawing entry has no face of its own: use
    `boxFace`.
    */
    const(Face)* face(size_t i, out BuildOutcome outcome) return scope
    {
        auto e = &entries_[i];
        const entry = chain.entries[i];
        assert(!entry.isBoxDrawing, "the box-drawing face is built per ppem: use boxFace");
        if (!e.tried)
        {
            e.tried = true;
            const r = chain.catalog.records[entry.record];
            // The VFS outlives the store (FTD14); `scope` cannot say so through `Dir`.
            BuildOutcome opened;
            e.file = (() @trusted => openRecordFile(cast(V*) vfs_, chain.catalog, r, authority_, opened))();
            e.outcome = opened;
            if (e.file !is null)
            {
                const f = openFace(e.file.bytes, r.index, chain.catalog.policy);
                if (f.hasValue)
                {
                    e.face = (() @trusted => cast(Face) f.value)();
                    e.open = true;
                }
                else
                {
                    e.outcome.kind = OutcomeKind.font;
                    e.outcome.font = f.error;
                }
            }
        }
        outcome = e.outcome;
        return e.open ? (() @trusted => &e.face)() : null;
    }

    /**
    The box-drawing face at the integer `ppem` (FTD36), built from the
    primary entry's cell metrics at that ppem the first time; every build is
    kept until the store is destroyed or `releaseBoxFaces` is called. The
    error is the `boxFace` outcome's.
    */
    FontResult!(const(Face)*) boxFace(uint ppem) return scope
    {
        foreach (b; boxes_[])
            if (b.ppem == ppem)
                return b.failed ? fontErr!(const(Face)*)(b.error) : fontOk((() @trusted => cast(const(Face)*) &b.face)());
        auto b = newBox(ppem);
        boxes_.put(b);
        build(b);
        return b.failed ? fontErr!(const(Face)*)(b.error) : fontOk((() @trusted => cast(const(Face)*) &b.face)());
    }

    /// Frees every box-drawing face; the caller holds no result borrowing one (FTD32).
    void releaseBoxFaces() @system
    {
        foreach (b; boxes_[])
            freeBox(b);
        boxes_.clear();
    }

    private void build(BoxBuild* b) scope
    {
        BuildOutcome ignored;
        const primary = chain.primary;
        auto pf = primary == noEntry ? null : face(primary, ignored);
        if (pf is null)
        {
            b.failed = true;
            b.error = FontError(FontErrorKind.unsupportedCapability);
            return;
        }
        const ppem = Ppem.fromInteger(b.ppem);
        if (ppem.hasError)
        {
            b.failed = true;
            b.error = ppem.error;
            return;
        }
        const m = chain.entries[primary].match;
        const inst = instance(*pf, InstanceSize.pixels(ppem.value), m.userCoordinates, m.synthesis);
        if (inst.hasError)
        {
            b.failed = true;
            b.error = inst.error;
            return;
        }
        const map = charMap(*pf);
        if (map.hasError)
        {
            b.failed = true;
            b.error = map.error;
            return;
        }
        // The workspace is large: it lives on the heap, not the stack.
        auto ws = makeUnique!PointWorkspace();
        const cell = cellMetrics(inst.value, map.value, b.ppem, *ws);
        if (cell.hasError)
        {
            b.failed = true;
            b.error = cell.error;
            return;
        }
        const layout = boxFaceMeasure(cell.value);
        if (layout.hasError)
        {
            b.failed = true;
            b.error = layout.error;
            return;
        }
        foreach (_; 0 .. layout.value.length)
            b.bytes.put(0);
        const bytes = buildBoxFace(cell.value, b.bytes[]);
        if (bytes.hasError)
        {
            b.failed = true;
            b.error = bytes.error;
            return;
        }
        const f = openFace(b.bytes[], 0);
        if (f.hasError)
        {
            b.failed = true;
            b.error = f.error;
            return;
        }
        b.face = (() @trusted => cast(Face) f.value)();
    }
}

private BoxBuild* newBox(uint ppem) @trusted
{
    import core.lifetime : emplace;
    import core.memory : pureMalloc;

    auto p = cast(BoxBuild*) pureMalloc(BoxBuild.sizeof);
    assert(p !is null, "out of memory");
    emplace(p);
    p.ppem = ppem;
    return p;
}

private void freeBox(BoxBuild* p) @trusted
{
    import core.memory : pureFree;

    destroy(*p);
    pureFree(p);
}

/// The address of `x`, for a value that borrows it and must not outlive it (FTD14).
private const(T)* borrow(T)(ref const T x) @trusted => &x;
