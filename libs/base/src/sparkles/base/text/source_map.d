/**
Typed coordinate maps over immutable source revisions and owned Unicode transforms.

The caller owns every arena, source revision, transform profile identity and epoch.
A build is a full rescan: no fixed lookbehind certifies Unicode context. Rebuilding
invalidates earlier views even on failure. Queries check the supplied key before
reading borrowed map or transform storage. These maps are not UI document owners.
*/
module sparkles.base.text.source_map;

import sparkles.base.text.grapheme : GraphemeBreakState;
import sparkles.base.text.width : CellPolicy, terminalKittyRevision, ClusterWidthState;
import sparkles.base.text.utf : UtfEncoding, UtfMode, UtfStatus, UtfToken,
    UtfTokenKind, decodeToken, reconstructToken, utfStorageOverlaps, utfEncoding,
    isUtfUnit, addUtfCount;
import sparkles.base.text.unicode_tables : unicodeManifestIdentity;
import sparkles.base.text.unicode_algorithm : UnicodeSourceSpan;
import sparkles.base.text.transform : UnicodeTransformView;

/// Coordinates have no implicit conversions or unchecked arithmetic operators.
struct SourceByteOffset { size_t value; }
/// ditto
struct ScalarIndex { size_t value; }
/// ditto
struct Utf16Offset { size_t value; }
/// Boundary ordinal between whole graphemes: 0 through the cluster count.
struct GraphemeIndex { size_t value; }
/// ditto
struct CellPosition { size_t value; }
/// UTF-8 reconstruction offset in a Unicode transformation, not a source offset.
struct TransformedByteOffset { size_t value; }
/// Index of a transformed scalar or explicit opaque analysis unit.
struct TransformedUnitIndex { size_t value; }

struct SourceByteRange { SourceByteOffset start; SourceByteOffset end; }
struct TransformedByteRange { TransformedByteOffset start; TransformedByteOffset end; }
struct TransformedUnitRange { TransformedUnitIndex start; TransformedUnitIndex end; }

enum MapAffinity : ubyte { exact, before, after }
enum MapStatus : ubyte
{
    ok, outOfRange, notBoundary, overflow, invalidInput, invalidOptions,
    workspaceFull, overlap, staleSource, stalePolicy, staleView,
    unavailableGeometry, opaqueNotScalar, unavailableTransform,
}

/**
Immutable cache identity. The caller assigns source identity/revision and a complete
transform-profile identity/revision (including locale, pipeline and lexicon).
`manifestIdentity` is the pinned owned Unicode manifest. Encoding changes are source
changes; malformed mode, manifest, transform and cell changes are policy changes.
`none` requires cellPolicyRevision=0 and rejects cell queries. terminalKitty revision
1 uses owned cluster advances, including zero-width controls/separators. Tabs are
zero-width here, not contextual tab stops; wrapping owns explicit tab expansion.
*/
struct SourceMapKey
{
    ulong sourceIdentity;
    ulong sourceRevision;
    UtfEncoding encoding = UtfEncoding.utf8;
    UtfMode malformed = UtfMode.strict;
    string manifestIdentity = unicodeManifestIdentity;
    ulong transformIdentity;
    ulong transformRevision;
    CellPolicy cellPolicy = CellPolicy.terminalKitty;
    uint cellPolicyRevision = terminalKittyRevision;
}

/// One distinct caller-owned epoch, disjoint from every source and backing arena.
struct SourceMapEpoch
{
    ulong generation;
    bool published;
}

/// Internal geometry entry; its scalar/UTF-16 fields are unavailable for opaque input.
struct SourceMapBoundary
{
    size_t bytes;
    size_t scalar;
    size_t utf16;
    size_t grapheme;
    size_t cells;
    size_t clusterStart;
    size_t clusterEnd;
    bool clusterBoundary;
    private bool sourceCovered;
}

/// The caller supplies scalar-count+1 entries and, when transformed, unit-count+1.
struct SourceMapWorkspace
{
    SourceMapBoundary[] boundaries;
    size_t[] transformedBoundaries;
    SourceMapEpoch[] epoch;

    private MapStatus begin() scope @safe pure nothrow @nogc
    {
        if (epoch.length != 1)
            return MapStatus.invalidOptions;
        epoch[0].published = false;
        if (epoch[0].generation == ulong.max)
            return MapStatus.overflow;
        ++epoch[0].generation;
        return MapStatus.ok;
    }
}

/**
`lower`/`upper` expose the affinity envelope, never an exact contributor set.
`exact` says the input coordinate is a boundary and no transformation projection
was needed; `snapped`, `projected` and `deleted` explain loss of exactness. On an
exact cell coordinate shared by zero-advance clusters, before/after are exact
coordinate hits but select different source boundaries; exact-only requires a
unique boundary and rejects that tie. Failure never contains successful geometry.
*/
struct MapResult(T)
{
    MapStatus status;
    T value;
    T lower;
    T upper;
    bool exact;
    bool snapped;
    bool projected;
    bool deleted;
    size_t required;

    bool succeeded() scope const @safe pure nothrow @nogc => status == MapStatus.ok;
}

/// Checked arithmetic for any public coordinate, leaving the input unchanged.
MapResult!T addCoordinate(T)(T coordinate, size_t amount)
if (isCoordinate!T)
{
    if (!addUtfCount(coordinate.value, amount))
        return MapResult!T(status: MapStatus.overflow);
    return MapResult!T(value: coordinate, lower: coordinate, upper: coordinate, exact: true);
}

enum MapRelationshipKind : ubyte { contributor, deletion, emptyOutputEndpoints }

/**
A contributor row is one exact original span for one transformed unit. Expansion
therefore has several rows; composition has several rows for the same unit.
Deletion has an empty output interval at its declared boundary. The explicit
emptyOutputEndpoints row retains original 0/end, but is NOT a contributor hull.
*/
struct MapRelationship
{
    MapRelationshipKind kind;
    SourceByteRange source;
    TransformedUnitRange units;
    TransformedByteRange output;
}

struct MapRelationshipsResult
{
    MapStatus status;
    size_t written;
    size_t required;
    bool succeeded() scope const @safe pure nothrow @nogc => status == MapStatus.ok;
}

struct MapSourceSpansResult
{
    MapStatus status;
    const(UnicodeSourceSpan)[] spans;
}

/**
Borrowed immutable geometry. Source revision, workspace and transform arenas must
remain alive and unmodified throughout the borrow. Independent concurrent builds
need disjoint workspaces; querying published immutable views needs no hidden state.
The original bytes are not retained. Changing their revision requires a new key
and full build; callers must never mutate a revision in place under the same key.
*/
struct SourceMapView
{
    private SourceMapKey key_;
    private const(SourceMapBoundary)[] boundaries_;
    private const(size_t)[] transformedBoundaries_;
    private const(SourceMapEpoch)[] epoch_;
    private ulong generation_;
    private UnicodeTransformView transform_;
    private bool hasTransform_;
    private bool opaque_;
    private size_t sourceLength_;
    private size_t relationshipCount_;

    /// Checks key mismatch before touching borrowed epoch or cache arenas.
    MapStatus validate(in SourceMapKey key) scope const @safe pure nothrow @nogc
    {
        if (key.sourceIdentity != key_.sourceIdentity
            || key.sourceRevision != key_.sourceRevision || key.encoding != key_.encoding)
            return MapStatus.staleSource;
        if (key.malformed != key_.malformed || key.manifestIdentity != key_.manifestIdentity
            || key.transformIdentity != key_.transformIdentity
            || key.transformRevision != key_.transformRevision
            || key.cellPolicy != key_.cellPolicy
            || key.cellPolicyRevision != key_.cellPolicyRevision)
            return MapStatus.stalePolicy;
        if (epoch_.length != 1 || !epoch_[0].published
            || epoch_[0].generation != generation_)
            return MapStatus.staleView;
        if (hasTransform_ && !transform_.valid())
            return MapStatus.staleView;
        return MapStatus.ok;
    }

    /**
Map any source coordinate to another explicitly typed source coordinate. Scalar
and UTF-16 maps constrain scalar boundaries; involving graphemes/cells additionally
constrains whole clusters. Source-byte offsets are physical bytes for all supported
encodings. Opaque UTF-8 has byte/grapheme maps under CellPolicy.none, but cannot
claim scalar or UTF-16 geometry. Every query requires the current caller key.
    */
    MapResult!To mapTo(To, From)(in SourceMapKey key, From coordinate,
        MapAffinity affinity = MapAffinity.exact) scope const
    if (isSourceCoordinate!To && isSourceCoordinate!From)
    {
        const checked = validate(key);
        if (checked != MapStatus.ok)
            return MapResult!To(status: checked);
        if (!validAffinity(affinity))
            return MapResult!To(status: MapStatus.invalidOptions);
        static if (is(To == CellPosition) || is(From == CellPosition))
            if (key_.cellPolicy == CellPolicy.none)
                return MapResult!To(status: MapStatus.unavailableGeometry);
        static if (is(To == ScalarIndex) || is(To == Utf16Offset)
            || is(From == ScalarIndex) || is(From == Utf16Offset))
            if (opaque_)
                return MapResult!To(status: MapStatus.opaqueNotScalar);
        auto selected = select(coordinate);
        if (selected.status != MapStatus.ok)
            return MapResult!To(status: selected.status);
        static if (is(To == GraphemeIndex) || is(To == CellPosition)
            || is(From == GraphemeIndex) || is(From == CellPosition))
        {
            const lowerIndex = boundaries_[selected.lower].clusterStart;
            const upperIndex = boundaries_[selected.upper].clusterBoundary
                ? selected.upper : boundaries_[selected.upper].clusterEnd;
            selected.exact = selected.exact && lowerIndex == selected.lower
                && upperIndex == selected.upper;
            selected.lower = lowerIndex;
            selected.upper = upperIndex;
        }
        if (affinity == MapAffinity.exact && (!selected.exact || selected.lower != selected.upper))
            return MapResult!To(status: MapStatus.notBoundary);
        const lower = To(boundaryValue!To(boundaries_[selected.lower]));
        const upper = To(boundaryValue!To(boundaries_[selected.upper]));
        return MapResult!To(value: affinity == MapAffinity.after ? upper : lower,
            lower: lower, upper: upper, exact: selected.exact, snapped: !selected.exact);
    }

    /// SPEC TXT-MAP4 contributor-cut L/R envelope; not a contributor selection.
    MapResult!TransformedByteOffset sourceToTransformed(From)(in SourceMapKey key,
        From coordinate, MapAffinity affinity = MapAffinity.exact) scope const
    if (isSourceCoordinate!From)
    {
        const source = mapTo!SourceByteOffset(key, coordinate, affinity);
        if (!source.succeeded())
            return MapResult!TransformedByteOffset(status: source.status);
        if (!hasTransform_)
            return MapResult!TransformedByteOffset(status: MapStatus.unavailableTransform);
        const b = source.value.value;
        size_t left = transform_.units.length;
        size_t right;
        foreach (i; 0 .. transform_.units.length)
            foreach (span; transform_.contributingSourceSpans(i))
            {
                if (span.end > b && i < left)
                    left = i;
                if (span.start < b && i + 1 > right)
                    right = i + 1;
            }
        bool deleted;
        foreach (deletion; transform_.deletions)
            deleted = deleted || (deletion.source.start < deletion.source.end
                && deletion.source.start <= b && b <= deletion.source.end);
        const exact = source.exact && left == right && !deleted;
        if (affinity == MapAffinity.exact && !exact)
            return MapResult!TransformedByteOffset(status: MapStatus.notBoundary);
        const lower = TransformedByteOffset(transformedBoundaries_[left]);
        const upper = TransformedByteOffset(transformedBoundaries_[right]);
        return MapResult!TransformedByteOffset(value: affinity == MapAffinity.after ? upper : lower,
            lower: lower, upper: upper, exact: exact, snapped: source.snapped,
            projected: !exact, deleted: deleted);
    }

    /// Inverse contributor cuts plus every deleted span anchored at the output cut.
    MapResult!SourceByteOffset transformedToSource(in SourceMapKey key,
        TransformedByteOffset coordinate, MapAffinity affinity = MapAffinity.exact)
        scope const @safe pure nothrow @nogc
    {
        const checked = validate(key);
        if (checked != MapStatus.ok)
            return MapResult!SourceByteOffset(status: checked);
        if (!validAffinity(affinity))
            return MapResult!SourceByteOffset(status: MapStatus.invalidOptions);
        if (!hasTransform_)
            return MapResult!SourceByteOffset(status: MapStatus.unavailableTransform);
        const selected = selectTransformed(coordinate.value);
        if (selected.status != MapStatus.ok)
            return MapResult!SourceByteOffset(status: selected.status);
        if (affinity == MapAffinity.exact && !selected.exact)
            return MapResult!SourceByteOffset(status: MapStatus.notBoundary);
        const b = affinity == MapAffinity.after ? selected.upper : selected.lower;
        size_t left = sourceLength_;
        size_t right;
        foreach (i; 0 .. transform_.units.length)
            foreach (span; transform_.contributingSourceSpans(i))
            {
                if (i + 1 > b && span.start < left)
                    left = span.start;
                if (i < b && span.end > right)
                    right = span.end;
            }
        size_t lower = left < right ? left : right;
        size_t upper = left > right ? left : right;
        bool deleted;
        foreach (deletion; transform_.deletions)
            if (deletion.boundary == b)
            {
                if (deletion.source.start < lower)
                    lower = deletion.source.start;
                if (deletion.source.end > upper)
                    upper = deletion.source.end;
                deleted = true;
            }
        const exact = selected.exact && lower == upper && !deleted;
        if (affinity == MapAffinity.exact && !exact)
            return MapResult!SourceByteOffset(status: MapStatus.notBoundary);
        return MapResult!SourceByteOffset(value: SourceByteOffset(
            affinity == MapAffinity.after ? upper : lower), lower: SourceByteOffset(lower),
            upper: SourceByteOffset(upper), exact: exact, snapped: !selected.exact,
            projected: !exact, deleted: deleted);
    }

    /// Lossless transformed UTF-8/unit seam, including supplementary scalar interiors.
    MapResult!TransformedUnitIndex transformedByteToUnit(in SourceMapKey key,
        TransformedByteOffset coordinate, MapAffinity affinity = MapAffinity.exact)
        scope const @safe pure nothrow @nogc
    {
        const checked = validate(key);
        if (checked != MapStatus.ok)
            return MapResult!TransformedUnitIndex(status: checked);
        if (!validAffinity(affinity))
            return MapResult!TransformedUnitIndex(status: MapStatus.invalidOptions);
        if (!hasTransform_)
            return MapResult!TransformedUnitIndex(status: MapStatus.unavailableTransform);
        const selected = selectTransformed(coordinate.value);
        if (selected.status != MapStatus.ok)
            return MapResult!TransformedUnitIndex(status: selected.status);
        if (affinity == MapAffinity.exact && !selected.exact)
            return MapResult!TransformedUnitIndex(status: MapStatus.notBoundary);
        return MapResult!TransformedUnitIndex(value: TransformedUnitIndex(
            affinity == MapAffinity.after ? selected.upper : selected.lower),
            lower: TransformedUnitIndex(selected.lower), upper: TransformedUnitIndex(selected.upper),
            exact: selected.exact, snapped: !selected.exact);
    }

    MapResult!TransformedByteOffset transformedUnitToByte(in SourceMapKey key,
        TransformedUnitIndex coordinate) scope const @safe pure nothrow @nogc
    {
        const checked = validate(key);
        if (checked != MapStatus.ok)
            return MapResult!TransformedByteOffset(status: checked);
        if (!hasTransform_)
            return MapResult!TransformedByteOffset(status: MapStatus.unavailableTransform);
        if (coordinate.value >= transformedBoundaries_.length)
            return MapResult!TransformedByteOffset(status: MapStatus.outOfRange);
        const result = TransformedByteOffset(transformedBoundaries_[coordinate.value]);
        return MapResult!TransformedByteOffset(value: result, lower: result, upper: result, exact: true);
    }

    /// Exact highlighting spans; this borrow also expires when the transform is reused.
    MapSourceSpansResult contributingSourceSpans(in SourceMapKey key,
        TransformedUnitIndex coordinate) return scope const @safe pure nothrow @nogc
    {
        const checked = validate(key);
        if (checked != MapStatus.ok)
            return MapSourceSpansResult(status: checked);
        if (!hasTransform_)
            return MapSourceSpansResult(status: MapStatus.unavailableTransform);
        if (coordinate.value >= transform_.units.length)
            return MapSourceSpansResult(status: MapStatus.outOfRange);
        return MapSourceSpansResult(spans: transform_.contributingSourceSpans(coordinate.value));
    }

    MapRelationshipsResult relationshipCount(in SourceMapKey key)
        scope const @safe pure nothrow @nogc
    {
        const checked = validate(key);
        if (checked != MapStatus.ok)
            return MapRelationshipsResult(status: checked);
        if (!hasTransform_)
            return MapRelationshipsResult(status: MapStatus.unavailableTransform);
        return MapRelationshipsResult(written: relationshipCount_, required: relationshipCount_);
    }

    /// Whole relation enumeration. One-short capacity writes nothing and reports the total.
    MapRelationshipsResult relationships(in SourceMapKey key,
        scope MapRelationship[] destination) scope const @safe pure nothrow @nogc
    {
        return copyRelationships(key, SourceByteRange.init, TransformedByteRange.init,
            false, false, destination);
    }

    /// Return every exact contributor/deletion relationship overlapping this source range.
    /// A zero-length query selects rows whose closed source interval contains the boundary.
    MapRelationshipsResult relationshipsForSource(in SourceMapKey key, SourceByteRange source,
        scope MapRelationship[] destination) scope const @safe pure nothrow @nogc
    {
        return copyRelationships(key, source, TransformedByteRange.init, true, false, destination);
    }

    /// Output-range query is separate from cut envelopes and retains anchored deletions.
    MapRelationshipsResult relationshipsForTransformed(in SourceMapKey key,
        TransformedByteRange output, scope MapRelationship[] destination)
        scope const @safe pure nothrow @nogc
    {
        return copyRelationships(key, SourceByteRange.init, output, false, true, destination);
    }

    private BoundarySelection select(From)(From coordinate) scope const
    {
        const end = boundaryValue!From(boundaries_[$ - 1]);
        if (coordinate.value > end)
            return BoundarySelection(status: MapStatus.outOfRange);
        size_t first;
        size_t last = boundaries_.length;
        while (first < last)
        {
            const mid = first + (last - first) / 2;
            if (boundaryValue!From(boundaries_[mid]) < coordinate.value)
                first = mid + 1;
            else
                last = mid;
        }
        if (boundaryValue!From(boundaries_[first]) != coordinate.value)
            return BoundarySelection(lower: first - 1, upper: first);
        static if (is(From == CellPosition) || is(From == GraphemeIndex))
        {
            size_t after = first;
            last = boundaries_.length;
            while (after < last)
            {
                const mid = after + (last - after) / 2;
                if (boundaryValue!From(boundaries_[mid]) <= coordinate.value)
                    after = mid + 1;
                else
                    last = mid;
            }
            return BoundarySelection(lower: first,
                upper: boundaries_[after - 1].clusterStart, exact: true);
        }
        else
            return BoundarySelection(lower: first, upper: first, exact: true);
    }

    private BoundarySelection selectTransformed(size_t bytes)
        scope const @safe pure nothrow @nogc
    {
        if (bytes > transformedBoundaries_[$ - 1])
            return BoundarySelection(status: MapStatus.outOfRange);
        size_t first;
        size_t last = transformedBoundaries_.length;
        while (first < last)
        {
            const mid = first + (last - first) / 2;
            if (transformedBoundaries_[mid] < bytes)
                first = mid + 1;
            else
                last = mid;
        }
        return transformedBoundaries_[first] == bytes
            ? BoundarySelection(lower: first, upper: first, exact: true)
            : BoundarySelection(lower: first - 1, upper: first);
    }

    private MapRelationshipsResult copyRelationships(in SourceMapKey key,
        SourceByteRange source, TransformedByteRange output, bool filterSource,
        bool filterOutput, scope MapRelationship[] destination)
        scope const @safe pure nothrow @nogc
    {
        const checked = validate(key);
        if (checked != MapStatus.ok)
            return MapRelationshipsResult(status: checked);
        if (!hasTransform_)
            return MapRelationshipsResult(status: MapStatus.unavailableTransform);
        if ((filterSource && (source.start.value > source.end.value
                || source.end.value > sourceLength_))
            || (filterOutput && (output.start.value > output.end.value
                || output.end.value > transformedBoundaries_[$ - 1])))
            return MapRelationshipsResult(status: MapStatus.outOfRange);
        if (utfStorageOverlaps(destination, boundaries_)
            || utfStorageOverlaps(destination, transformedBoundaries_)
            || utfStorageOverlaps(destination, epoch_)
            || utfStorageOverlaps(destination, transform_.units)
            || utfStorageOverlaps(destination, transform_.spans)
            || utfStorageOverlaps(destination, transform_.deletions)
            || utfStorageOverlaps(destination, transform_.storageEpoch()))
            return MapRelationshipsResult(status: MapStatus.overlap);
        const filtered = filterSource || filterOutput;
        size_t required = filtered ? 0 : relationshipCount_;
        if (!filtered && destination.length < required)
            return MapRelationshipsResult(status: MapStatus.workspaceFull, required: required);
        // Filtered queries count first; complete enumeration reuses its cached count.
        foreach (pass; (filtered ? 0 : 1) .. 2)
        {
            size_t written;
            foreach (i; 0 .. transform_.units.length)
                foreach (span; transform_.contributingSourceSpans(i))
                {
                    const row = makeRelationship(MapRelationshipKind.contributor,
                        span, i, i + 1);
                    if (!matches(row, source, output, filterSource, filterOutput))
                        continue;
                    if (pass == 0)
                        ++required;
                    else
                        destination[written++] = row;
                }
            foreach (deletion; transform_.deletions)
            {
                const row = makeRelationship(MapRelationshipKind.deletion,
                    deletion.source, deletion.boundary, deletion.boundary);
                if (!matches(row, source, output, filterSource, filterOutput))
                    continue;
                if (pass == 0)
                    ++required;
                else
                    destination[written++] = row;
            }
            if (transform_.units.length == 0)
            {
                const row = makeRelationship(MapRelationshipKind.emptyOutputEndpoints,
                    UnicodeSourceSpan(0, sourceLength_), 0, 0);
                if (matches(row, source, output, filterSource, filterOutput))
                {
                    if (pass == 0)
                        ++required;
                    else
                        destination[written++] = row;
                }
            }
            if (pass == 0 && destination.length < required)
                return MapRelationshipsResult(status: MapStatus.workspaceFull, required: required);
        }
        return MapRelationshipsResult(written: required, required: required);
    }

    private MapRelationship makeRelationship(MapRelationshipKind kind,
        UnicodeSourceSpan source, size_t start, size_t end)
        scope const @safe pure nothrow @nogc
        => MapRelationship(kind: kind,
            source: SourceByteRange(SourceByteOffset(source.start), SourceByteOffset(source.end)),
            units: TransformedUnitRange(TransformedUnitIndex(start), TransformedUnitIndex(end)),
            output: TransformedByteRange(TransformedByteOffset(transformedBoundaries_[start]),
                TransformedByteOffset(transformedBoundaries_[end])));
}

struct SourceMapBuildResult
{
    MapStatus status;
    size_t requiredBoundaries;
    size_t requiredTransformedBoundaries;
    SourceByteOffset blocking;
    SourceMapView view;
    bool succeeded() scope const @safe pure nothrow @nogc => status == MapStatus.ok;
}

/**
Full conservative rebuild over owned decoding and grapheme/cell state. Source bytes
are physical bytes for char/wchar/dchar input; UTF-16 coordinates always count the
Unicode encoding of decoded scalars, not source bytes. An optional transform borrows
exact contributor sets/deletions, never copies their hulls. The owned transform core
uses UTF-8 provenance, so transformed maps require a char source. Source/transform
and every arena must be disjoint from the epoch before it invalidates old views.
No view is published unless every source and transform entry is complete.
*/
SourceMapBuildResult buildSourceMap(S)(scope const(S)[] source, SourceMapKey key,
    return scope ref SourceMapWorkspace workspace,
    return scope UnicodeTransformView transformed = UnicodeTransformView.init)
if (isUtfUnit!S)
{
    assert(!utfStorageOverlaps(source, workspace.epoch)
        && !utfStorageOverlaps(workspace.boundaries, workspace.epoch)
        && !utfStorageOverlaps(workspace.transformedBoundaries, workspace.epoch)
        && !utfStorageOverlaps(transformed.units, workspace.epoch)
        && !utfStorageOverlaps(transformed.spans, workspace.epoch)
        && !utfStorageOverlaps(transformed.deletions, workspace.epoch)
        && !utfStorageOverlaps(transformed.storageEpoch(), workspace.epoch),
        "map epoch must be disjoint from source, transform and every arena");
    const begun = workspace.begin();
    if (begun != MapStatus.ok)
        return SourceMapBuildResult(status: begun);
    if (key.encoding != utfEncoding!S || key.manifestIdentity != unicodeManifestIdentity
        || (key.malformed != UtfMode.strict && key.malformed != UtfMode.replacement
            && !(is(S == char) && key.malformed == UtfMode.opaque))
        || (key.cellPolicy != CellPolicy.none && key.cellPolicy != CellPolicy.terminalKitty)
        || (key.cellPolicy == CellPolicy.none && key.cellPolicyRevision != 0)
        || (key.cellPolicy == CellPolicy.terminalKitty
            && key.cellPolicyRevision != terminalKittyRevision))
        return SourceMapBuildResult(status: MapStatus.invalidOptions);
    const hasTransform = transformed.valid();
    // A nonempty invalidated transform is not absence of a transform.
    if (!hasTransform && (transformed.units.length || transformed.spans.length
        || transformed.deletions.length || transformed.storageEpoch().length))
        return SourceMapBuildResult(status: MapStatus.staleView);
    static if (!is(S == char))
        if (hasTransform)
            return SourceMapBuildResult(status: MapStatus.invalidOptions);
    if (source.length > size_t.max / S.sizeof)
        return SourceMapBuildResult(status: MapStatus.overflow);
    if (overlapsMap(source, workspace) || overlapsMap(transformed.units, workspace)
        || overlapsMap(transformed.spans, workspace)
        || overlapsMap(transformed.deletions, workspace)
        || overlapsMap(transformed.storageEpoch(), workspace)
        || utfStorageOverlaps(workspace.boundaries, workspace.transformedBoundaries))
        return SourceMapBuildResult(status: MapStatus.overlap);
    const measured = scanSourceMap(source, key, workspace.boundaries[0 .. 0], false);
    if (measured.status != MapStatus.ok)
        return SourceMapBuildResult(status: measured.status, blocking: measured.blocking);
    size_t transformedRequired;
    size_t relations;
    if (hasTransform)
    {
        transformedRequired = transformed.units.length;
        if (!addUtfCount(transformedRequired, 1))
            return SourceMapBuildResult(status: MapStatus.overflow);
        foreach (unit; transformed.units)
        {
            if (unit.provenanceStart > transformed.spans.length
                || unit.provenanceCount > transformed.spans.length - unit.provenanceStart
                || unit.provenanceCount == 0)
                return SourceMapBuildResult(status: MapStatus.invalidInput);
            if (!addUtfCount(relations, unit.provenanceCount))
                return SourceMapBuildResult(status: MapStatus.overflow);
            foreach (span; transformed.spans[unit.provenanceStart ..
                unit.provenanceStart + unit.provenanceCount])
                if (span.start >= span.end || span.end > measured.bytes)
                    return SourceMapBuildResult(status: MapStatus.invalidInput);
        }
        foreach (deletion; transformed.deletions)
            if (deletion.boundary > transformed.units.length
                || deletion.source.start >= deletion.source.end
                || deletion.source.end > measured.bytes)
                return SourceMapBuildResult(status: MapStatus.invalidInput);
        if (!addUtfCount(relations, transformed.deletions.length)
            || (transformed.units.length == 0 && !addUtfCount(relations, 1)))
            return SourceMapBuildResult(status: MapStatus.overflow);
    }
    SourceMapBuildResult result;
    result.requiredBoundaries = measured.required;
    result.requiredTransformedBoundaries = transformedRequired;
    if (workspace.boundaries.length < measured.required
        || workspace.transformedBoundaries.length < transformedRequired)
    {
        result.status = MapStatus.workspaceFull;
        return result;
    }
    const constructed = scanSourceMap(source, key,
        workspace.boundaries[0 .. measured.required], true);
    if (constructed.status != MapStatus.ok)
    {
        result.status = constructed.status;
        result.blocking = constructed.blocking;
        return result;
    }
    if (hasTransform)
    {
        size_t bytes;
        workspace.transformedBoundaries[0] = 0;
        foreach (i, unit; transformed.units)
        {
            char[4] encoded;
            const encodedResult = reconstructToken(UtfToken(kind: unit.kind,
                scalar: unit.value, byteValue: unit.opaqueByte), encoded[]);
            if (encodedResult.status != UtfStatus.ok)
            {
                result.status = MapStatus.invalidInput;
                return result;
            }
            if (!addUtfCount(bytes, encodedResult.written))
            {
                result.status = MapStatus.overflow;
                return result;
            }
            workspace.transformedBoundaries[i + 1] = bytes;
            foreach (span; transformed.contributingSourceSpans(i))
            {
                const status = coverSource(workspace.boundaries[0 .. measured.required], span);
                if (status != MapStatus.ok)
                {
                    result.status = status;
                    return result;
                }
            }
        }
        foreach (deletion; transformed.deletions)
        {
            const status = coverSource(workspace.boundaries[0 .. measured.required], deletion.source);
            if (status != MapStatus.ok)
            {
                result.status = status;
                return result;
            }
        }
        foreach (point; workspace.boundaries[0 .. measured.required - 1])
            if (!point.sourceCovered)
            {
                result.status = MapStatus.invalidInput;
                result.blocking = SourceByteOffset(point.bytes);
                return result;
            }
    }
    workspace.epoch[0].published = true;
    result.view = SourceMapView(key_: key,
        boundaries_: workspace.boundaries[0 .. measured.required],
        transformedBoundaries_: workspace.transformedBoundaries[0 .. transformedRequired],
        epoch_: workspace.epoch, generation_: workspace.epoch[0].generation,
        transform_: transformed, hasTransform_: hasTransform, opaque_: measured.opaque,
        sourceLength_: measured.bytes, relationshipCount_: relations);
    return result;
}

private enum isSourceCoordinate(T) = is(T == SourceByteOffset) || is(T == ScalarIndex)
    || is(T == Utf16Offset) || is(T == GraphemeIndex) || is(T == CellPosition);
private enum isCoordinate(T) = isSourceCoordinate!T || is(T == TransformedByteOffset)
    || is(T == TransformedUnitIndex);

private bool validAffinity(MapAffinity affinity) @safe pure nothrow @nogc
    => affinity == MapAffinity.exact || affinity == MapAffinity.before || affinity == MapAffinity.after;

private size_t boundaryValue(T)(in SourceMapBoundary point)
{
    static if (is(T == SourceByteOffset)) return point.bytes;
    else static if (is(T == ScalarIndex)) return point.scalar;
    else static if (is(T == Utf16Offset)) return point.utf16;
    else static if (is(T == GraphemeIndex)) return point.grapheme;
    else return point.cells;
}

private struct BoundarySelection
{
    MapStatus status;
    size_t lower;
    size_t upper;
    bool exact;
}

private struct ScanResult
{
    MapStatus status;
    size_t required;
    size_t bytes;
    bool opaque;
    SourceByteOffset blocking;
}

private ScanResult scanSourceMap(S)(scope const(S)[] source, in SourceMapKey key,
    scope SourceMapBoundary[] destination, bool write)
{
    GraphemeBreakState breaks;
    ClusterWidthState width;
    size_t offset;
    size_t scalar;
    size_t utf16;
    size_t grapheme;
    size_t cells;
    size_t clusterStart;
    bool previousOpaque;
    bool opaque;
    while (offset < source.length)
    {
        const decoded = decodeToken(source[offset .. $], key.malformed, true, offset);
        if (decoded.result.status != UtfStatus.ok)
            return ScanResult(status: decoded.result.status == UtfStatus.overflow
                ? MapStatus.overflow : MapStatus.invalidInput,
                blocking: SourceByteOffset(offset * S.sizeof));
        const token = decoded.token;
        bool boundary;
        if (token.kind == UtfTokenKind.opaqueByte)
        {
            breaks.reset();
            boundary = true;
            previousOpaque = opaque = true;
            if (key.cellPolicy != CellPolicy.none)
                return ScanResult(status: MapStatus.unavailableGeometry,
                    blocking: SourceByteOffset(offset * S.sizeof));
        }
        else
        {
            if (previousOpaque)
                breaks.reset();
            previousOpaque = false;
            boundary = breaks.push(token.scalar);
        }
        if (boundary && scalar != 0)
        {
            if (!addUtfCount(cells, cast(size_t) width.width) || !addUtfCount(grapheme, 1))
                return ScanResult(status: MapStatus.overflow);
            if (write)
                foreach (i; clusterStart .. scalar)
                    destination[i].clusterEnd = scalar;
            clusterStart = scalar;
            width = ClusterWidthState.init;
        }
        if (write)
            destination[scalar] = SourceMapBoundary(bytes: offset * S.sizeof,
                scalar: scalar, utf16: utf16, grapheme: grapheme, cells: cells,
                clusterStart: clusterStart, clusterBoundary: boundary);
        if (key.cellPolicy != CellPolicy.none)
            width.push(token.scalar, false);
        if (!addUtfCount(scalar, 1)
            || !addUtfCount(utf16, token.scalar > 0xFFFF ? 2 : 1))
            return ScanResult(status: MapStatus.overflow);
        offset = token.end;
    }
    if (scalar != 0)
    {
        if (!addUtfCount(cells, cast(size_t) width.width) || !addUtfCount(grapheme, 1))
            return ScanResult(status: MapStatus.overflow);
        if (write)
            foreach (i; clusterStart .. scalar)
                destination[i].clusterEnd = scalar;
    }
    if (write)
        destination[scalar] = SourceMapBoundary(bytes: source.length * S.sizeof,
            scalar: scalar, utf16: utf16, grapheme: grapheme, cells: cells,
            clusterStart: scalar, clusterEnd: scalar, clusterBoundary: true);
    if (!addUtfCount(scalar, 1))
        return ScanResult(status: MapStatus.overflow);
    return ScanResult(required: scalar, bytes: source.length * S.sizeof, opaque: opaque);
}

private bool overlapsMap(T)(scope T[] source, scope ref SourceMapWorkspace workspace)
{
    return utfStorageOverlaps(source, workspace.boundaries)
        || utfStorageOverlaps(source, workspace.transformedBoundaries)
        || utfStorageOverlaps(source, workspace.epoch);
}

private size_t sourceBoundaryIndex(scope const(SourceMapBoundary)[] points, size_t bytes)
    @safe pure nothrow @nogc
{
    size_t first;
    size_t last = points.length;
    while (first < last)
    {
        const mid = first + (last - first) / 2;
        if (points[mid].bytes < bytes)
            first = mid + 1;
        else
            last = mid;
    }
    return first < points.length && points[first].bytes == bytes ? first : size_t.max;
}

private MapStatus coverSource(scope SourceMapBoundary[] points, UnicodeSourceSpan span)
    @safe pure nothrow @nogc
{
    const first = sourceBoundaryIndex(points, span.start);
    const last = sourceBoundaryIndex(points, span.end);
    if (first == size_t.max || last == size_t.max)
        return MapStatus.notBoundary;
    foreach (i; first .. last)
        points[i].sourceCovered = true;
    return MapStatus.ok;
}

private bool rangesMeet(size_t start, size_t end, size_t queryStart, size_t queryEnd)
    @safe pure nothrow @nogc
{
    if (queryStart == queryEnd)
        return start <= queryStart && queryStart <= end;
    if (start == end)
        return queryStart <= start && start <= queryEnd;
    return start < queryEnd && queryStart < end;
}

private bool matches(in MapRelationship row, SourceByteRange source,
    TransformedByteRange output, bool filterSource, bool filterOutput)
    @safe pure nothrow @nogc
    => (!filterSource || rangesMeet(row.source.start.value, row.source.end.value,
            source.start.value, source.end.value))
        && (!filterOutput || rangesMeet(row.output.start.value, row.output.end.value,
            output.start.value, output.end.value));

@("text.sourceMap.supplementaryAndWholeClusterCoordinates")
@safe pure nothrow @nogc
unittest
{
    SourceMapBoundary[8] boundaries;
    SourceMapEpoch[1] epoch;
    auto workspace = SourceMapWorkspace(boundaries: boundaries[], epoch: epoch[]);
    SourceMapKey key;
    auto built = buildSourceMap("A\U0001F600B", key, workspace);
    assert(built.succeeded());
    const map = built.view;
    const interior = map.mapTo!SourceByteOffset(key, Utf16Offset(2));
    assert(interior.status == MapStatus.notBoundary);
    const before = map.mapTo!SourceByteOffset(key, Utf16Offset(2), MapAffinity.before);
    const after = map.mapTo!SourceByteOffset(key, Utf16Offset(2), MapAffinity.after);
    assert(before.value.value == 1 && after.value.value == 5);
    assert(before.snapped && after.snapped && !before.exact && !after.exact);
    static immutable size_t[2][4] pairs = [ [0, 0], [1, 1], [5, 3], [6, 4] ];
    foreach (pair; pairs)
    {
        const utf16 = map.mapTo!Utf16Offset(key, SourceByteOffset(pair[0]));
        assert(utf16.exact && utf16.value.value == pair[1]);
        const bytes = map.mapTo!SourceByteOffset(key, Utf16Offset(pair[1]));
        assert(bytes.exact && bytes.value.value == pair[0]);
    }
    assert(map.mapTo!ScalarIndex(key, SourceByteOffset(3)).status == MapStatus.notBoundary);
    assert(map.mapTo!ScalarIndex(key, SourceByteOffset(3), MapAffinity.before).value.value == 1);
    assert(map.mapTo!ScalarIndex(key, SourceByteOffset(3), MapAffinity.after).value.value == 2);
    assert(map.mapTo!SourceByteOffset(key, Utf16Offset(5)).status == MapStatus.outOfRange);
    assert(map.mapTo!CellPosition(key, SourceByteOffset(size_t.max)).status == MapStatus.outOfRange);
    assert(addCoordinate(SourceByteOffset(size_t.max), 1).status == MapStatus.overflow);
    assert(addCoordinate(Utf16Offset(size_t.max - 1), 1).value.value == size_t.max);

    built = buildSourceMap("e\u0301x", key, workspace);
    assert(built.succeeded());
    assert(built.view.mapTo!SourceByteOffset(key, CellPosition(1)).value.value == 3);
    assert(built.view.mapTo!Utf16Offset(key, SourceByteOffset(1)).value.value == 1);
    assert(built.view.mapTo!CellPosition(key, SourceByteOffset(1)).status == MapStatus.notBoundary);
    const clusterBefore = built.view.mapTo!SourceByteOffset(key, ScalarIndex(1), MapAffinity.before);
    assert(clusterBefore.exact && clusterBefore.value.value == 1);
    const cellBefore = built.view.mapTo!CellPosition(key, ScalarIndex(1), MapAffinity.before);
    const cellAfter = built.view.mapTo!CellPosition(key, ScalarIndex(1), MapAffinity.after);
    assert(cellBefore.snapped && cellBefore.value.value == 0);
    assert(cellAfter.snapped && cellAfter.value.value == 1);
    assert(built.view.mapTo!SourceByteOffset(key, GraphemeIndex(1)).value.value == 3);

    key.encoding = UtfEncoding.utf16;
    built = buildSourceMap("A\U0001F600B"w, key, workspace);
    assert(built.succeeded());
    assert(built.view.mapTo!SourceByteOffset(key, Utf16Offset(3)).value.value == 6);
    assert(built.view.mapTo!ScalarIndex(key, SourceByteOffset(4)).status == MapStatus.notBoundary);
    assert(built.view.mapTo!SourceByteOffset(key, Utf16Offset(2), MapAffinity.after).value.value == 6);
}

@("text.sourceMap.wideZeroAndEmptyEndpoints")
@safe pure nothrow @nogc
unittest
{
    SourceMapBoundary[8] boundaries;
    SourceMapEpoch[1] epoch;
    auto workspace = SourceMapWorkspace(boundaries: boundaries[], epoch: epoch[]);
    SourceMapKey key;
    auto built = buildSourceMap("\u754Cx", key, workspace);
    assert(built.succeeded());
    assert(built.view.mapTo!SourceByteOffset(key, CellPosition(1)).status == MapStatus.notBoundary);
    const before = built.view.mapTo!SourceByteOffset(key, CellPosition(1), MapAffinity.before);
    const after = built.view.mapTo!SourceByteOffset(key, CellPosition(1), MapAffinity.after);
    assert(before.value.value == 0 && after.value.value == 3);
    assert(before.snapped && after.snapped);
    assert(built.view.mapTo!SourceByteOffset(key, CellPosition(3)).value.value == 4);
    built = buildSourceMap("\U0001F1FA\U0001F1F8x", key, workspace);
    assert(built.succeeded());
    assert(built.view.mapTo!SourceByteOffset(key, CellPosition(2)).value.value == 8);
    built = buildSourceMap("\u200Bx\u200B", key, workspace);
    assert(built.succeeded());
    const zeroStartBefore = built.view.mapTo!SourceByteOffset(key, CellPosition(0), MapAffinity.before);
    const zeroStartAfter = built.view.mapTo!SourceByteOffset(key, CellPosition(0), MapAffinity.after);
    assert(zeroStartBefore.exact && zeroStartAfter.exact);
    assert(zeroStartBefore.value.value == 0 && zeroStartAfter.value.value == 3);
    assert(built.view.mapTo!SourceByteOffset(key, CellPosition(1), MapAffinity.before).value.value == 4);
    assert(built.view.mapTo!SourceByteOffset(key, CellPosition(1), MapAffinity.after).value.value == 7);
    assert(built.view.mapTo!SourceByteOffset(key, CellPosition(0)).status == MapStatus.notBoundary);
    built = buildSourceMap("\u200B\u200B", key, workspace);
    assert(built.succeeded());
    assert(built.view.mapTo!SourceByteOffset(key, CellPosition(0), MapAffinity.before).value.value == 0);
    assert(built.view.mapTo!SourceByteOffset(key, CellPosition(0), MapAffinity.after).value.value == 6);
    built = buildSourceMap("", key, workspace);
    assert(built.succeeded() && built.requiredBoundaries == 1);
    const empty = built.view.mapTo!SourceByteOffset(key, CellPosition(0));
    assert(empty.exact && empty.value.value == 0);
    assert(built.view.mapTo!GraphemeIndex(key, SourceByteOffset(1)).status == MapStatus.outOfRange);
    const controls = buildSourceMap("A\tB", key, workspace);
    assert(controls.succeeded());
    assert(controls.view.mapTo!SourceByteOffset(key, CellPosition(1), MapAffinity.before).value.value == 1);
    assert(controls.view.mapTo!SourceByteOffset(key, CellPosition(1), MapAffinity.after).value.value == 2);
    key.cellPolicy = CellPolicy.none;
    key.cellPolicyRevision = 0;
    built = buildSourceMap("A\tB", key, workspace);
    assert(built.succeeded());
    assert(built.view.mapTo!CellPosition(key, SourceByteOffset(1)).status == MapStatus.unavailableGeometry);
    key.malformed = UtfMode.opaque;
    built = buildSourceMap("A\xFF\u0301", key, workspace);
    assert(built.succeeded());
    assert(built.view.mapTo!SourceByteOffset(key, GraphemeIndex(2)).value.value == 2);
    assert(built.view.mapTo!Utf16Offset(key, SourceByteOffset(1)).status == MapStatus.opaqueNotScalar);
}

@("text.sourceMap.revisionPolicyReuseAndExhaustion")
@safe pure nothrow @nogc
unittest
{
    SourceMapBoundary[5] boundaries;
    SourceMapEpoch[1] epoch;
    auto workspace = SourceMapWorkspace(boundaries: boundaries[], epoch: epoch[]);
    SourceMapKey key;
    key.sourceIdentity = 17;
    key.sourceRevision = 1;
    auto built = buildSourceMap("\U0001F1E6\U0001F1E7\U0001F1E8", key, workspace);
    assert(built.succeeded());
    const old = built.view;
    auto newKey = key;
    ++newKey.sourceRevision;
    assert(old.mapTo!SourceByteOffset(newKey, CellPosition(0)).status == MapStatus.staleSource);
    auto newPolicy = key;
    ++newPolicy.cellPolicyRevision;
    assert(old.mapTo!SourceByteOffset(newPolicy, CellPosition(0)).status == MapStatus.stalePolicy);
    newPolicy = key;
    newPolicy.manifestIdentity = "different-release";
    assert(old.mapTo!SourceByteOffset(newPolicy, CellPosition(0)).status == MapStatus.stalePolicy);
    newPolicy = key;
    ++newPolicy.transformRevision;
    assert(old.mapTo!ScalarIndex(newPolicy, SourceByteOffset(0)).status == MapStatus.stalePolicy);
    built = buildSourceMap("\U0001F1E9\U0001F1E6\U0001F1E7\U0001F1E8", newKey, workspace);
    assert(built.succeeded());
    assert(old.validate(key) == MapStatus.staleView);
    assert(built.view.mapTo!GraphemeIndex(newKey, SourceByteOffset(12)).status == MapStatus.notBoundary);
    const before = built.view.mapTo!GraphemeIndex(newKey, SourceByteOffset(12), MapAffinity.before);
    const after = built.view.mapTo!GraphemeIndex(newKey, SourceByteOffset(12), MapAffinity.after);
    assert(before.value.value == 1 && after.value.value == 2 && before.snapped && after.snapped);
    const updated = built.view;
    const sentinel = boundaries[0];
    workspace.boundaries = boundaries[0 .. 3];
    const full = buildSourceMap("ABC", newKey, workspace);
    assert(full.status == MapStatus.workspaceFull && full.requiredBoundaries == 4);
    assert(full.view.validate(newKey) != MapStatus.ok && updated.validate(newKey) == MapStatus.staleView);
    assert(boundaries[0] == sentinel);
    workspace.boundaries = boundaries[];
    built = buildSourceMap("ABC", newKey, workspace);
    assert(built.succeeded());
    assert(built.view.mapTo!SourceByteOffset(newKey, ScalarIndex(3)).value.value == 3);
}

version (unittest)
{
    private struct MapTransformFixture
    {
        import sparkles.base.text.transform : UnicodeTransformWorkspace,
            UnicodeTransformUnit, UnicodeTransformEpoch, UnicodeDeletion;
        UnicodeTransformUnit[16] inputUnits;
        UnicodeTransformUnit[16] outputUnits;
        UnicodeSourceSpan[32] inputSpans;
        UnicodeSourceSpan[32] outputSpans;
        UnicodeDeletion[8] inputDeletions;
        UnicodeDeletion[8] outputDeletions;
        UnicodeTransformEpoch[1] inputEpoch;
        UnicodeTransformEpoch[1] outputEpoch;

        UnicodeTransformWorkspace input() scope return @safe pure nothrow @nogc
            => UnicodeTransformWorkspace(units: inputUnits[], spans: inputSpans[],
                deletions: inputDeletions[], epoch: inputEpoch[]);
        UnicodeTransformWorkspace output() scope return @safe pure nothrow @nogc
            => UnicodeTransformWorkspace(units: outputUnits[], spans: outputSpans[],
                deletions: outputDeletions[], epoch: outputEpoch[]);
    }
}

@("text.sourceMap.normalizationRelationsAndCutEnvelopes")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.text.transform : decodeTransformText;
    import sparkles.base.text.normalization : normalizeText, UnicodeNormalization,
        UnicodeNormalizationItem, UnicodeNormalizationScratch;
    MapTransformFixture fixture;
    auto input = fixture.input();
    auto output = fixture.output();
    UnicodeNormalizationItem[16] items;
    size_t[16] ordering;
    size_t[17] normalizationBoundaries;
    auto scratch = UnicodeNormalizationScratch(items[], ordering[], normalizationBoundaries[]);
    SourceMapBoundary[16] boundaries;
    size_t[17] transformedBoundaries;
    SourceMapEpoch[1] epoch;
    auto workspace = SourceMapWorkspace(boundaries: boundaries[],
        transformedBoundaries: transformedBoundaries[], epoch: epoch[]);
    SourceMapKey key;
    key.transformIdentity = 1;
    enum source = "a\u0315\u0300";
    assert(decodeTransformText(source, UtfMode.strict, input).succeeded());
    assert(normalizeText(input.output(), UnicodeNormalization.NFD, output, scratch).succeeded());
    auto built = buildSourceMap(source, key, workspace, output.output());
    assert(built.succeeded());
    const before = built.view.sourceToTransformed(key, SourceByteOffset(3), MapAffinity.before);
    const after = built.view.sourceToTransformed(key, SourceByteOffset(3), MapAffinity.after);
    assert(before.value.value == 1 && after.value.value == 5);
    assert(before.projected && after.projected && !before.exact && !after.exact);
    assert(built.view.sourceToTransformed(key, SourceByteOffset(3)).status == MapStatus.notBoundary);
    MapRelationship[8] rows;
    const selected = built.view.relationshipsForSource(key,
        SourceByteRange(SourceByteOffset(1), SourceByteOffset(3)), rows[]);
    assert(selected.succeeded() && selected.written == 1);
    assert(rows[0].source.start.value == 1 && rows[0].source.end.value == 3);
    assert(rows[0].output.start.value == 3 && rows[0].output.end.value == 5);
    const old = built.view;
    assert(normalizeText(input.output(), UnicodeNormalization.NFC, output, scratch).succeeded());
    assert(old.validate(key) == MapStatus.staleView);
    built = buildSourceMap(source, key, workspace, output.output());
    assert(built.succeeded());
    assert(built.view.sourceToTransformed(key, SourceByteOffset(3), MapAffinity.before).value.value == 0);
    assert(built.view.sourceToTransformed(key, SourceByteOffset(3), MapAffinity.after).value.value == 4);
    const contributors = built.view.contributingSourceSpans(key, TransformedUnitIndex(0));
    assert(contributors.status == MapStatus.ok && contributors.spans.length == 2);
    assert(contributors.spans[0] == UnicodeSourceSpan(0, 1));
    assert(contributors.spans[1] == UnicodeSourceSpan(3, 5));
    const inverseBefore = built.view.transformedToSource(key, TransformedByteOffset(2), MapAffinity.before);
    const inverseAfter = built.view.transformedToSource(key, TransformedByteOffset(2), MapAffinity.after);
    assert(inverseBefore.projected && inverseBefore.value.value == 1);
    assert(inverseAfter.projected && inverseAfter.value.value == 5);
    assert(decodeTransformText("e\u0301", UtfMode.strict, input).succeeded());
    assert(normalizeText(input.output(), UnicodeNormalization.NFC, output, scratch).succeeded());
    built = buildSourceMap("e\u0301", key, workspace, output.output());
    assert(built.succeeded());
    assert(built.view.sourceToTransformed(key, SourceByteOffset(1), MapAffinity.before).value.value == 0);
    assert(built.view.sourceToTransformed(key, SourceByteOffset(1), MapAffinity.after).value.value == 2);
    assert(decodeTransformText("\u00E9", UtfMode.strict, input).succeeded());
    assert(normalizeText(input.output(), UnicodeNormalization.NFD, output, scratch).succeeded());
    built = buildSourceMap("\u00E9", key, workspace, output.output());
    assert(built.succeeded());
    const end = built.view.sourceToTransformed(key, Utf16Offset(1));
    assert(end.exact && end.value.value == 3);
    const expansion = built.view.transformedToSource(key, TransformedByteOffset(1), MapAffinity.after);
    assert(expansion.projected && expansion.value.value == 2);
    const count = built.view.relationships(key, rows[]);
    assert(count.succeeded() && count.written == 2);
    assert(rows[0].source == rows[1].source && rows[0].source.end.value == 2);
    assert(rows[0].output.end.value == 1 && rows[1].output.start.value == 1);
    const sentinel = rows[0];
    const shortRows = built.view.relationships(key, rows[0 .. 1]);
    assert(shortRows.status == MapStatus.workspaceFull && shortRows.required == 2);
    assert(rows[0] == sentinel);
    workspace.transformedBoundaries = transformedBoundaries[0 .. 2];
    const shortMap = buildSourceMap("\u00E9", key, workspace, output.output());
    assert(shortMap.status == MapStatus.workspaceFull && shortMap.requiredTransformedBoundaries == 3);
    assert(built.view.validate(key) == MapStatus.staleView);
}

@("text.sourceMap.fullFoldAndDeletedEndpointRelations")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.text.transform : decodeTransformText, UnicodeTransformUnit, UnicodeDeletion;
    import sparkles.base.text.casing : caseTransform, UnicodeCaseMode, UnicodeCasingScratch;
    MapTransformFixture fixture;
    auto input = fixture.input();
    auto output = fixture.output();
    ubyte[16] contexts;
    size_t[17] casingBoundaries;
    auto scratch = UnicodeCasingScratch(contexts: contexts[], boundaryMap: casingBoundaries[]);
    SourceMapBoundary[8] boundaries;
    size_t[17] transformedBoundaries;
    SourceMapEpoch[1] epoch;
    auto workspace = SourceMapWorkspace(boundaries: boundaries[],
        transformedBoundaries: transformedBoundaries[], epoch: epoch[]);
    SourceMapKey key;
    key.transformIdentity = 2;
    assert(decodeTransformText("\u00DF", UtfMode.strict, input).succeeded());
    assert(caseTransform(input.output(), output, UnicodeCaseMode.fullFold, scratch).succeeded());
    auto built = buildSourceMap("\u00DF", key, workspace, output.output());
    assert(built.succeeded());
    const foldBefore = built.view.transformedToSource(key, TransformedByteOffset(1), MapAffinity.before);
    const foldAfter = built.view.transformedToSource(key, TransformedByteOffset(1), MapAffinity.after);
    assert(foldBefore.value.value == 0 && foldAfter.value.value == 2);
    assert(foldBefore.projected && foldAfter.projected);
    assert(built.view.transformedToSource(key, TransformedByteOffset(1)).status == MapStatus.notBoundary);
    assert(built.view.sourceToTransformed(key, SourceByteOffset(2)).value.value == 2);

    assert(output.begin().succeeded());
    UnicodeSourceSpan[1] surviving = [UnicodeSourceSpan(1, 2)];
    size_t first;
    assert(output.appendSources(surviving[], first).succeeded());
    assert(output.appendUnit(UnicodeTransformUnit(value: 'b', provenanceStart: first,
        provenanceCount: 1)).succeeded());
    assert(output.appendDeletion(UnicodeDeletion(0, UnicodeSourceSpan(0, 1))).succeeded());
    output.publish();
    built = buildSourceMap("ab", key, workspace, output.output());
    assert(built.succeeded());
    foreach (boundary; 0 .. 2)
    {
        const cut = built.view.sourceToTransformed(key, SourceByteOffset(boundary), MapAffinity.before);
        assert(cut.value.value == 0 && cut.deleted && cut.projected);
        assert(built.view.sourceToTransformed(key, SourceByteOffset(boundary)).status == MapStatus.notBoundary);
    }
    const deletionBefore = built.view.transformedToSource(key, TransformedByteOffset(0), MapAffinity.before);
    const deletionAfter = built.view.transformedToSource(key, TransformedByteOffset(0), MapAffinity.after);
    assert(deletionBefore.value.value == 0 && deletionAfter.value.value == 1);
    assert(deletionBefore.deleted && deletionAfter.projected);
    MapRelationship[4] rows;
    const deletionRows = built.view.relationshipsForTransformed(key,
        TransformedByteRange(TransformedByteOffset(0), TransformedByteOffset(0)), rows[]);
    assert(deletionRows.succeeded() && deletionRows.written == 2);
    assert(rows[1].kind == MapRelationshipKind.deletion && rows[1].source.end.value == 1);
    assert(output.begin().succeeded());
    assert(output.appendDeletion(UnicodeDeletion(0, UnicodeSourceSpan(0, 2))).succeeded());
    output.publish();
    built = buildSourceMap("ab", key, workspace, output.output());
    assert(built.succeeded());
    const entireBefore = built.view.transformedToSource(key, TransformedByteOffset(0), MapAffinity.before);
    const entireAfter = built.view.transformedToSource(key, TransformedByteOffset(0), MapAffinity.after);
    assert(entireBefore.value.value == 0 && entireAfter.value.value == 2);
    assert(entireBefore.deleted && entireAfter.deleted && entireBefore.projected && entireAfter.projected);
    const all = built.view.relationships(key, rows[]);
    assert(all.succeeded() && all.written == 2);
    assert(rows[0].kind == MapRelationshipKind.deletion);
    assert(rows[1].kind == MapRelationshipKind.emptyOutputEndpoints);
    assert(rows[1].source.start.value == 0 && rows[1].source.end.value == 2);
}
