/** Caller-owned Unicode transformation storage and exact source relationships. */
module sparkles.base.text.transform;

import sparkles.base.text.unicode_algorithm : UnicodeResult, UnicodeStatus,
    UnicodeSourceSpan;
import sparkles.base.text.utf : UtfTokenKind, UtfMode, UtfStatus, decodeToken,
    utfStorageOverlaps;

/// One scalar or opaque byte, with indices into its view's provenance arena.
struct UnicodeTransformUnit
{
    dchar value;
    UtfTokenKind kind;
    ubyte opaqueByte;
    size_t provenanceStart;
    size_t provenanceCount;
    uint flags;

    bool isOpaque() const @safe pure nothrow @nogc
        => kind == UtfTokenKind.opaqueByte;
}

/// Source removed at an output boundary. Either affinity selects its endpoint.
struct UnicodeDeletion
{
    size_t boundary;
    UnicodeSourceSpan source;
}

enum UnicodeAffinity : ubyte { before, after }

/// One caller-owned epoch per workspace, disjoint from its other backing arenas.
struct UnicodeTransformEpoch
{
    ulong generation;
    bool published;
}

/// Borrowed output. The workspace must outlive this view and remain unmodified.
struct UnicodeTransformView
{
    const(UnicodeTransformUnit)[] units;
    const(UnicodeSourceSpan)[] spans;
    const(UnicodeDeletion)[] deletions;
    private const(UnicodeTransformEpoch)[] epoch;
    private ulong generation;
    private bool published;

    bool valid() scope const @safe pure nothrow @nogc
        => published && epoch.length == 1 && epoch[0].published
            && epoch[0].generation == generation;

    /// Borrowed lifetime arena, exposed read-only for cross-arena overlap preflight.
    const(UnicodeTransformEpoch)[] storageEpoch() return scope const
        @safe pure nothrow @nogc => epoch;

    const(UnicodeSourceSpan)[] contributingSourceSpans(size_t index)
        return scope const @safe pure nothrow @nogc
    in (valid() && index < units.length)
    {
        const unit = units[index];
        return spans[unit.provenanceStart .. unit.provenanceStart + unit.provenanceCount];
    }
}

/// Backing arrays are supplied and owned by the caller. No allocation occurs.
struct UnicodeTransformWorkspace
{
    UnicodeTransformUnit[] units;
    UnicodeSourceSpan[] spans;
    UnicodeDeletion[] deletions;
    UnicodeTransformEpoch[] epoch;
    private size_t unitCount;
    private size_t spanCount;
    private size_t deletionCount;

    /// Invalidate every earlier view before an operation inspects input.
    UnicodeResult begin() scope @safe pure nothrow @nogc
    {
        if (epoch.length != 1)
            return UnicodeResult(status: UnicodeStatus.invalidOptions);
        epoch[0].published = false;
        unitCount = spanCount = deletionCount = 0;
        if (epoch[0].generation == ulong.max)
            return UnicodeResult(status: UnicodeStatus.overflow);
        ++epoch[0].generation;
        return UnicodeResult.init;
    }

    /// No output becomes consumable until the whole operation succeeds.
    void publish() scope @safe pure nothrow @nogc
    in (epoch.length == 1)
    {
        epoch[0].published = true;
    }

    /// Borrow this workspace's generation and caller-owned output arenas.
    UnicodeTransformView output() return scope const @safe pure nothrow @nogc
    {
        if (epoch.length != 1)
            return UnicodeTransformView.init;
        const published = epoch[0].published;
        return UnicodeTransformView(units: units[0 .. (published ? unitCount : 0)],
            spans: spans[0 .. (published ? spanCount : 0)],
            deletions: deletions[0 .. (published ? deletionCount : 0)],
            epoch: epoch, generation: epoch[0].generation, published: published);
    }

    size_t length() scope const @safe pure nothrow @nogc => unitCount;
    size_t provenanceLength() scope const @safe pure nothrow @nogc => spanCount;
    size_t deletedLength() scope const @safe pure nothrow @nogc => deletionCount;

    /// Copy an already ordered, deduplicated source set into the output arena.
    UnicodeResult appendSources(scope const(UnicodeSourceSpan)[] source,
        ref size_t first) scope @safe pure nothrow @nogc
    {
        if (source.length > size_t.max - spanCount)
            return UnicodeResult(status: UnicodeStatus.overflow);
        if (source.length > spans.length - spanCount)
            return UnicodeResult(status: UnicodeStatus.workspaceFull,
                required: spanCount + source.length,
                blocking: source.length ? source[0] : UnicodeSourceSpan.init);
        first = spanCount;
        spans[spanCount .. spanCount + source.length] = source[];
        spanCount += source.length;
        return UnicodeResult.init;
    }

    /// Commit provenance constructed directly in the unused arena tail.
    UnicodeResult commitSources(size_t count, ref size_t first)
        scope @safe pure nothrow @nogc
    {
        if (count > size_t.max - spanCount)
            return UnicodeResult(status: UnicodeStatus.overflow);
        if (count > spans.length - spanCount)
            return UnicodeResult(status: UnicodeStatus.workspaceFull,
                required: spanCount + count);
        first = spanCount;
        spanCount += count;
        return UnicodeResult.init;
    }

    /// Append a unit referencing a source set already copied into this arena.
    UnicodeResult appendUnit(in UnicodeTransformUnit unit)
        scope @safe pure nothrow @nogc
    {
        if (unit.provenanceStart > spanCount
            || unit.provenanceCount > spanCount - unit.provenanceStart)
            return UnicodeResult(status: UnicodeStatus.invalidInput);
        if (unitCount == units.length)
            return UnicodeResult(status: UnicodeStatus.outputFull,
                required: unitCount + 1,
                blocking: unit.provenanceCount ? spans[unit.provenanceStart]
                    : UnicodeSourceSpan.init);
        units[unitCount++] = unit;
        return UnicodeResult.init;
    }

    /// Record source deletion; the operation still owns final boundary selection.
    UnicodeResult appendDeletion(in UnicodeDeletion deletion)
        scope @safe pure nothrow @nogc
    {
        if (deletionCount == deletions.length)
            return UnicodeResult(status: UnicodeStatus.workspaceFull,
                required: deletionCount + 1, blocking: deletion.source);
        deletions[deletionCount++] = deletion;
        return UnicodeResult.init;
    }

    /// Mutable committed construction prefix, unavailable from a failed view.
    UnicodeTransformUnit[] constructionUnits() return scope @safe pure nothrow @nogc
        => units[0 .. unitCount];

    UnicodeSourceSpan[] constructionSpans() return scope @safe pure nothrow @nogc
        => spans[0 .. spanCount];

    UnicodeDeletion[] constructionDeletions() return scope @safe pure nothrow @nogc
        => deletions[0 .. deletionCount];

    /// Remove a composed unit after its provenance has been merged.
    void eraseUnit(size_t index) scope @safe pure nothrow @nogc
    in (index < unitCount)
    {
        foreach (i; index .. unitCount - 1)
            units[i] = units[i + 1];
        --unitCount;
    }

    /// Compact a successfully constructed prefix without exposing partial output.
    void truncateUnits(size_t length) scope @safe pure nothrow @nogc
    in (length <= unitCount)
    {
        unitCount = length;
    }
}

/**
Decode a complete UTF-8 source into transform units and exact source spans.
Opaque mode preserves malformed bytes; strict failure publishes no prefix.
The epoch must be disjoint from source and every backing arena. This storage
precondition is asserted before invocation invalidates any earlier output.
*/
UnicodeResult decodeTransformText(scope const(char)[] source, UtfMode mode,
    scope ref UnicodeTransformWorkspace workspace) @safe pure nothrow @nogc
{
    assert(!utfStorageOverlaps(source, workspace.epoch)
        && !utfStorageOverlaps(workspace.units, workspace.epoch)
        && !utfStorageOverlaps(workspace.spans, workspace.epoch)
        && !utfStorageOverlaps(workspace.deletions, workspace.epoch),
        "decoding output epoch must be disjoint from source and all arenas");
    auto result = workspace.begin();
    if (!result.succeeded())
        return result;
    if (mode != UtfMode.strict && mode != UtfMode.replacement && mode != UtfMode.opaque)
        return UnicodeResult(status: UnicodeStatus.invalidOptions);
    if (utfStorageOverlaps(source, workspace.units)
        || utfStorageOverlaps(source, workspace.spans)
        || utfStorageOverlaps(source, workspace.deletions)
        || utfStorageOverlaps(workspace.units, workspace.spans)
        || utfStorageOverlaps(workspace.units, workspace.deletions)
        || utfStorageOverlaps(workspace.spans, workspace.deletions))
        return UnicodeResult(status: UnicodeStatus.overlap);
    size_t offset;
    while (offset < source.length)
    {
        const decoded = decodeToken(source[offset .. $], mode, true, offset);
        if (decoded.result.status != UtfStatus.ok)
            return UnicodeResult(status: UnicodeStatus.invalidInput,
                blocking: UnicodeSourceSpan(start: offset,
                    end: offset + decoded.result.consumed));
        UnicodeSourceSpan[1] origin = [UnicodeSourceSpan(
            start: decoded.token.start, end: decoded.token.end)];
        size_t first;
        result = workspace.appendSources(origin[], first);
        if (!result.succeeded())
            return result;
        result = workspace.appendUnit(UnicodeTransformUnit(
            value: decoded.token.scalar, kind: decoded.token.kind,
            opaqueByte: decoded.token.byteValue,
            provenanceStart: first, provenanceCount: 1));
        if (!result.succeeded())
            return result;
        offset += decoded.result.consumed;
    }
    workspace.publish();
    return UnicodeResult(written: workspace.length());
}

@("text.transform.generationAndFailurePublication")
@safe pure nothrow @nogc
unittest
{
    UnicodeTransformUnit[2] units;
    UnicodeSourceSpan[2] spans;
    UnicodeDeletion[1] deletions;
    UnicodeTransformEpoch[1] epoch;
    auto workspace = UnicodeTransformWorkspace(units: units[], spans: spans[],
        deletions: deletions[], epoch: epoch[]);
    assert(workspace.begin().succeeded());
    UnicodeSourceSpan[1] source = [UnicodeSourceSpan(start: 1, end: 3)];
    size_t first;
    assert(workspace.appendSources(source[], first).succeeded());
    assert(workspace.appendUnit(UnicodeTransformUnit(value: 'A',
        provenanceStart: first, provenanceCount: 1)).succeeded());
    workspace.publish();
    const old = workspace.output();
    assert(old.valid());
    assert(old.contributingSourceSpans(0)[0] == source[0]);
    assert(workspace.begin().succeeded());
    assert(!old.valid());
    assert(!workspace.output().valid());
    assert(workspace.output().units.length == 0);
}
