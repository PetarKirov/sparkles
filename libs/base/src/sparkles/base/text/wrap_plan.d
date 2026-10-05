/** Borrowed wrapping plans, explicit provenance, and bounded transactional emission. */
module sparkles.base.text.wrap_plan;

import sparkles.base.text.utf : utfStorageOverlaps, utfObjectStorage;
import sparkles.base.text.width : CellPolicy;

@safe nothrow @nogc:

/// Checked byte-address arena contracts, including unused capacity.
bool wrapStorageDisjoint(Slices...)(Slices slices)
{
    static foreach (i; 0 .. Slices.length)
        static foreach (j; 0 .. i)
            if (utfStorageOverlaps(slices[i], slices[j])) return false;
    return true;
}
bool wrapStorageAvoids(T, Slices...)(scope const(T)[] borrowed, Slices slices)
{
    static foreach (i; 0 .. Slices.length)
        if (utfStorageOverlaps(borrowed, slices[i])) return false;
    return true;
}
/// Covers the publication header and every retained borrowed resource, not just
/// bytes currently emitted. Used by planning, projection and both copy modes.
bool wrapPlanAvoids(Slices...)(scope const ref WrapPlan plan, Slices arenas)
{
    // Only the boolean overlap result escapes; the scoped header view is never
    // retained or published, even when the aggregate contains borrowed pointers.
    const headerAvoids = (() @trusted { return wrapStorageAvoids(utfObjectStorage(plan), arenas); })();
    if (!headerAvoids
        || !wrapStorageAvoids(plan.source.bytes, arenas)
        || !wrapStorageAvoids(plan.lines, arenas) || !wrapStorageAvoids(plan.fragments, arenas)
        || !wrapStorageAvoids(plan.sourceRecords, arenas) || !wrapStorageAvoids(plan.styles, arenas)
        || !wrapStorageAvoids(plan.profile, arenas)) return false;
    foreach (ref const fragment; plan.fragments)
        if (!wrapStorageAvoids(fragment.bytes, arenas)) return false;
    foreach (ref const style; plan.styles)
    {
        const(char)[][5] bytes = [style.foreground, style.background, style.underlineColor, style.linkOpen, style.customRestore];
        foreach (span; bytes) if (!wrapStorageAvoids(span, arenas)) return false;
    }
    return true;
}
enum WrapStatus : ubyte
{
    ok, invalidInput, unsupportedCapability, arithmeticExhausted, needScratch,
    needPlanStorage, needResults, needOutput, budgetExhausted, geometryExhausted,
    noFeasiblePlan, exactMeasurementRequired, callbackFailure, cancelled,
    unbreakableOverflow, noNextTabStop, replacementDoesNotFit,
    invalidEncoding, invalidFormatting, nonTextTerminalOperation, stalePlan,
    outOfRange, notBoundary,
}
enum WrapPhase : ubyte { validation, scan, geometry, measurement, selection, projection, emission }
enum WrapBudgetKind : ubyte { sourceBytes, inputRecords, alternatives, states, transitions, measurements, providerWork, outputRecords }
enum WrapProof : ubyte { localGreedy, completeExact, completeApproximate }
enum WrapSolver : ubyte { greedy, balanced, knuthPlass }
enum WrapDimension : ubyte { cells, physical }
enum WrapAffinity : ubyte { before, after }
enum ProvenanceKind : ubyte { original, replacement, omission, separator, synthetic }
enum FragmentKind : ubyte { bytes, spaces, glue, anchor }
enum SyntheticReason : ubyte { none, indent, hyphen, styleSuspend, styleResume, newline, replacement }

struct WrapResult
{
    WrapStatus status;
    WrapPhase phase;
    WrapBudgetKind kind;
    size_t used, limit, required;
    size_t sourceStart, sourceEnd, candidate, line;
    int callerCode;
    bool exhaustive;
    bool moreAlternatives;
    bool succeeded() const @safe pure nothrow @nogc => status == WrapStatus.ok;
}

/// Every limit is explicit. Defaults intentionally admit no work.
struct WrapLimits
{
    size_t sourceBytes, inputRecords, alternatives, states, transitions;
    size_t measurements, providerWork, outputRecords;
}
struct WrapUsage
{
    size_t sourceBytes, inputRecords, alternatives, states, transitions;
    size_t measurements, providerWork, outputRecords;
}
struct SourceSnapshot
{
    const(char)[] bytes;
    ulong identity, revision;
}
struct SourceRecord
{
    size_t start, end;
    ProvenanceKind kind;
    size_t ordinal;
    bool formatting;
}

/// Bytes borrow immutable source/replacement resources, never planning scratch.
/// `repeat` is the space/glue output count; `advance` is in the plan's dimension.
struct WrapFragment
{
    FragmentKind kind;
    const(char)[] bytes;
    ulong repeat;
    long advance;
    size_t sourceStart, sourceEnd, anchor;
    ProvenanceKind provenance;
    SyntheticReason reason;
    ulong payload;
    ulong itemId;
    size_t consumedStart, consumedEnd;
    size_t sourceRecordOrdinal = size_t.max;
    ulong styleBefore, styleAfter;
    bool formatting, omitted;
    ulong clusterOrdinal = ulong.max;
    ulong clusterCount = 1;
    size_t clusterSourceStart, clusterSourceEnd;
    ProvenanceKind clusterProvenance;
    bool terminalTab;
}
struct WrapRatio
{
    ulong numerator;
    ulong denominator = 1;
    bool negative;
}
enum WrapFitness : ubyte { tight, decent, loose, veryLoose }
struct WrapLine
{
    size_t fragmentsStart, fragmentsEnd;
    size_t sourceStart, sourceEnd;
    size_t endpointOrdinal;
    ulong alternativeId;
    ulong geometryId, continuationId, providerState;
    size_t paragraphLine;
    long startColumn, indentExtent, contentAdvance, endColumn, capacity;
    bool unbounded, overfull, emergency, paragraphEnd;
    WrapRatio adjustment;
    WrapFitness fitness;
    ulong startStyle, endStyle;
    ulong visualMap;
    ulong materializationId;
    long visibleAdvance, originalContentAdvance;
    bool clipped, opaqueMaterialization;
    size_t separatorStart, separatorEnd;
}
struct WrapObjective
{
    size_t overfullLines, emergencyBreaks, lines;
    // Portable raw unsigned/signed 128 values; sign-magnitude for demerits.
    ulong overflowLow, overflowHigh;
    ulong costLow, costHigh;
    bool negativeCost;
}
/// SGR 4:n underline variants. Underline is not an attribute bit.
enum CellUnderlineStyle : ubyte { none, single, doubleLine, curly, dotted, dashed }
struct CellStyleSnapshot
{
    ulong id;
    ushort attributes;
    CellUnderlineStyle underline;
    const(char)[] foreground, background, underlineColor, linkOpen;
    const(char)[] customRestore;
    bool opaque;
    bool active() const @safe pure nothrow @nogc
        => attributes || underline != CellUnderlineStyle.none || foreground.length
            || background.length || underlineColor.length || customRestore.length;
}
struct WrapPlan
{
    SourceSnapshot source;
    const(WrapLine)[] lines;
    const(WrapFragment)[] fragments;
    const(SourceRecord)[] sourceRecords;
    const(CellStyleSnapshot)[] styles;
    WrapProof proof;
    WrapSolver solver;
    WrapDimension dimension;
    WrapObjective objective;
    WrapUsage usage;
    ulong resourceRevision;
    const(char)[] profile;
    CellPolicy cellPolicy;
    uint cellPolicyRevision;
    WrapRatio stretchTolerance;
    ulong linePenalty, fitnessDemerit, consecutiveDiscretionaryDemerit, terminalDiscretionaryDemerit;
    size_t minimumLines, maximumLines;
    bool justifiedTerminal;
    ulong policyIdentity;
    size_t geometryAlternative;
    bool projection;
}
struct WrapPlanStorage
{
    WrapLine[] lines;
    WrapFragment[] fragments;
    SourceRecord[] sourceRecords;
    CellStyleSnapshot[] styles;
}
struct WrapProjectionScratch
{
    WrapLine[] lines;
    WrapFragment[] fragments;
    SourceRecord[] sourceRecords;
    CellStyleSnapshot[] styles;
}

/// Publication is the only write to supplied plan storage. Call after all fallible work.
WrapResult publishWrapPlan(ref WrapPlan prepared, WrapProjectionScratch scratch,
    WrapPlanStorage storage, ref WrapPlan published)
{
    if (storage.lines.length < prepared.lines.length
        || storage.fragments.length < prepared.fragments.length
        || storage.sourceRecords.length < prepared.sourceRecords.length
        || storage.styles.length < prepared.styles.length)
        return WrapResult(status: WrapStatus.needPlanStorage, phase: WrapPhase.projection,
            required: prepared.lines.length + prepared.fragments.length + prepared.sourceRecords.length + prepared.styles.length);
    if (!wrapStorageDisjoint(storage.lines, storage.fragments, storage.sourceRecords, storage.styles,
            scratch.lines, scratch.fragments, scratch.sourceRecords, scratch.styles)
        || overlapsPlanStorage(storage, published)
        || !wrapStorageAvoids(prepared.source.bytes, storage.lines, storage.fragments, storage.sourceRecords, storage.styles))
        return WrapResult(status: WrapStatus.invalidInput, phase: WrapPhase.validation);
    foreach (ref const fragment; prepared.fragments)
        if (!wrapStorageAvoids(fragment.bytes, storage.lines, storage.fragments, storage.sourceRecords, storage.styles,
                scratch.lines, scratch.fragments, scratch.sourceRecords, scratch.styles))
            return WrapResult(status: WrapStatus.invalidInput, phase: WrapPhase.validation);
    foreach (ref const style; prepared.styles)
    {
        const(char)[][5] bytes = [style.foreground, style.background, style.underlineColor, style.linkOpen, style.customRestore];
        foreach (span; bytes)
            if (!wrapStorageAvoids(span, storage.lines, storage.fragments, storage.sourceRecords, storage.styles,
                    scratch.lines, scratch.fragments, scratch.sourceRecords, scratch.styles))
                return WrapResult(status: WrapStatus.invalidInput, phase: WrapPhase.validation);
    }
    storage.lines[0 .. prepared.lines.length] = prepared.lines[];
    storage.fragments[0 .. prepared.fragments.length] = prepared.fragments[];
    storage.sourceRecords[0 .. prepared.sourceRecords.length] = prepared.sourceRecords[];
    storage.styles[0 .. prepared.styles.length] = prepared.styles[];
    prepared.lines = storage.lines[0 .. prepared.lines.length];
    prepared.fragments = storage.fragments[0 .. prepared.fragments.length];
    prepared.sourceRecords = storage.sourceRecords[0 .. prepared.sourceRecords.length];
    prepared.styles = storage.styles[0 .. prepared.styles.length];
    published = prepared;
    return WrapResult.init;
}
bool overlapsPlanStorage(WrapPlanStorage storage, scope const ref WrapPlan plan)
{
    return !wrapStorageAvoids(plan.lines, storage.lines, storage.fragments, storage.sourceRecords, storage.styles)
        || !wrapStorageAvoids(plan.fragments, storage.lines, storage.fragments, storage.sourceRecords, storage.styles)
        || !wrapStorageAvoids(plan.sourceRecords, storage.lines, storage.fragments, storage.sourceRecords, storage.styles)
        || !wrapStorageAvoids(plan.styles, storage.lines, storage.fragments, storage.sourceRecords, storage.styles);
}

enum WrapNewline : ubyte { lf, crlf }
struct WrapEmissionOptions
{
    WrapNewline newline;
    ulong sourceRevision, resourceRevision;
}

/// Measures first, then writes; failed capacity/revision/overlap leaves every byte untouched.
WrapResult tryMaterializeWrap(scope const ref WrapPlan plan, WrapEmissionOptions options,
    scope char[] output, ref size_t outExtent)
{
    if (options.sourceRevision != plan.source.revision
        || options.resourceRevision != plan.resourceRevision)
        return WrapResult(status: WrapStatus.stalePlan, phase: WrapPhase.emission);
    if (!wrapPlanAvoids(plan, output))
        return WrapResult(status: WrapStatus.invalidInput, phase: WrapPhase.emission);
    size_t required;
    foreach (i, ref const line; plan.lines)
    {
        if (line.fragmentsStart > line.fragmentsEnd || line.fragmentsEnd > plan.fragments.length)
            return WrapResult(status: WrapStatus.invalidInput, phase: WrapPhase.emission);
        if (line.opaqueMaterialization)
            return WrapResult(status: WrapStatus.unsupportedCapability, phase: WrapPhase.emission);
        foreach (ref const fragment; plan.fragments[line.fragmentsStart .. line.fragmentsEnd])
        {
            if (utfStorageOverlaps(output, fragment.bytes))
                return WrapResult(status: WrapStatus.invalidInput, phase: WrapPhase.emission);
            const count = fragment.kind == FragmentKind.bytes ? fragment.bytes.length
                : fragment.kind == FragmentKind.anchor ? 0 : fragment.repeat;
            if (count > size_t.max - required)
                return WrapResult(status: WrapStatus.arithmeticExhausted, phase: WrapPhase.emission);
            required += cast(size_t) count;
        }
        const separator = i + 1 == plan.lines.length ? 0
            : options.newline == WrapNewline.lf ? 1 : 2;
        if (separator > size_t.max - required)
            return WrapResult(status: WrapStatus.arithmeticExhausted, phase: WrapPhase.emission);
        required += separator;
    }
    if (output.length < required)
        return WrapResult(status: WrapStatus.needOutput, phase: WrapPhase.emission, required: required);
    size_t offset;
    foreach (i, ref const line; plan.lines)
    {
        foreach (ref const fragment; plan.fragments[line.fragmentsStart .. line.fragmentsEnd])
        {
            if (fragment.kind == FragmentKind.bytes)
            {
                output[offset .. offset + fragment.bytes.length] = fragment.bytes[];
                offset += fragment.bytes.length;
            }
            else if (fragment.kind != FragmentKind.anchor)
            {
                const count = cast(size_t) fragment.repeat;
                output[offset .. offset + count] = ' ';
                offset += count;
            }
        }
        if (i + 1 != plan.lines.length)
        {
            if (options.newline == WrapNewline.crlf) output[offset++] = '\r';
            output[offset++] = '\n';
        }
    }
    outExtent = offset;
    return WrapResult(status: WrapStatus.ok, required: required);
}

/// The ledger, rather than rendered output offsets, defines copy-original.
WrapResult tryCopyOriginal(scope const ref WrapPlan plan, scope char[] output, ref size_t extent)
{
    size_t expected;
    foreach (ref const record; plan.sourceRecords)
    {
        if (record.start != expected || record.end < record.start || record.end > plan.source.bytes.length)
            return WrapResult(status: WrapStatus.invalidInput);
        expected = record.end;
    }
    if (expected != plan.source.bytes.length || !wrapPlanAvoids(plan, output))
        return WrapResult(status: WrapStatus.invalidInput);
    if (output.length < expected)
        return WrapResult(status: WrapStatus.needOutput, required: expected);
    output[0 .. expected] = plan.source.bytes[];
    extent = expected;
    return WrapResult.init;
}
struct WrappedPosition
{
    WrapStatus status;
    size_t line, sourceBoundary;
    long column;
    ProvenanceKind provenance;
}

private size_t mappedGroupEnd(scope const ref WrapPlan plan, size_t first, size_t limit)
{
    const id = plan.fragments[first].clusterOrdinal;
    if (id == ulong.max) return first + 1;
    size_t end = first + 1;
    const firstFragment = plan.fragments[first];
    while (end < limit)
    {
        const next = plan.fragments[end];
        if (next.clusterOrdinal == id) { ++end; continue; }
        // A tab expansion contains several paint clusters but is one source
        // transformation. Affinity at its interior cell boundaries must address
        // that unit's before/after range, not adjacent space-cluster endpoints.
        if (firstFragment.clusterProvenance == ProvenanceKind.replacement
            && next.clusterProvenance == ProvenanceKind.replacement
            && next.clusterSourceStart == firstFragment.clusterSourceStart
            && next.clusterSourceEnd == firstFragment.clusterSourceEnd)
        { ++end; continue; }
        break;
    }
    return end;
}
private bool mappedAdvance(scope const(WrapFragment)[] fragments, ref long advance)
{
    long sum;
    foreach (ref const fragment; fragments)
    {
        if (fragment.advance < 0 || fragment.advance > long.max - sum) return false;
        sum += fragment.advance;
    }
    advance = sum; return true;
}
WrappedPosition cellToSource(scope const ref WrapPlan plan, size_t lineIndex,
    long column, WrapAffinity affinity)
{
    if (plan.dimension != WrapDimension.cells || lineIndex >= plan.lines.length)
        return WrappedPosition(status: WrapStatus.outOfRange);
    const line = plan.lines[lineIndex];
    if (column < line.startColumn || column > line.endColumn)
        return WrappedPosition(status: WrapStatus.outOfRange);
    long cursor = line.startColumn;
    size_t first = line.fragmentsStart;
    while (first < line.fragmentsEnd)
    {
        const end = mappedGroupEnd(plan, first, line.fragmentsEnd);
        const fragment = plan.fragments[first];
        long advance;
        if (!mappedAdvance(plan.fragments[first .. end], advance) || advance > long.max - cursor)
            return WrappedPosition(status: WrapStatus.arithmeticExhausted);
        const next = cursor + advance;
        if (column < next || (column == next && affinity == WrapAffinity.before))
        {
            const grouped = fragment.clusterOrdinal != ulong.max;
            const provenance = grouped ? fragment.clusterProvenance : fragment.provenance;
            const start = grouped ? fragment.clusterSourceStart : fragment.sourceStart;
            const finish = grouped ? fragment.clusterSourceEnd : fragment.sourceEnd;
            const boundary = provenance == ProvenanceKind.synthetic ? fragment.anchor
                : column == cursor ? start : column == next ? finish
                : affinity == WrapAffinity.before ? start : finish;
            return WrappedPosition(WrapStatus.ok, lineIndex, boundary, column, provenance);
        }
        cursor = next; first = end;
    }
    return WrappedPosition(WrapStatus.ok, lineIndex,
        affinity == WrapAffinity.before ? line.sourceStart : line.sourceEnd, column, ProvenanceKind.omission);
}
WrappedPosition sourceToLine(scope const ref WrapPlan plan, size_t boundary,
    WrapAffinity affinity)
{
    if (boundary > plan.source.bytes.length) return WrappedPosition(status: WrapStatus.outOfRange);
    foreach (i, ref const line; plan.lines)
        if (line.separatorEnd > line.separatorStart && boundary >= line.separatorStart && boundary <= line.separatorEnd)
        {
            const next = affinity == WrapAffinity.after && i + 1 < plan.lines.length ? i + 1 : i;
            return WrappedPosition(WrapStatus.ok, next,
                affinity == WrapAffinity.before ? line.separatorStart : line.separatorEnd,
                next == i ? line.endColumn : plan.lines[next].startColumn, ProvenanceKind.separator);
        }
    bool found;
    WrappedPosition chosen;
    foreach (i, ref const line; plan.lines)
    {
        if (boundary < line.sourceStart || boundary > line.sourceEnd) continue;
        long column = line.startColumn;
        WrappedPosition current = WrappedPosition(WrapStatus.ok, i, boundary, column, ProvenanceKind.omission);
        size_t first = line.fragmentsStart;
        while (first < line.fragmentsEnd)
        {
            const end = mappedGroupEnd(plan, first, line.fragmentsEnd);
            const fragment = plan.fragments[first];
            long advance;
            if (!mappedAdvance(plan.fragments[first .. end], advance) || advance > long.max - column)
                return WrappedPosition(status: WrapStatus.arithmeticExhausted);
            const grouped = fragment.clusterOrdinal != ulong.max;
            const provenance = grouped ? fragment.clusterProvenance : fragment.provenance;
            const start = grouped ? fragment.clusterSourceStart : fragment.sourceStart;
            const finish = grouped ? fragment.clusterSourceEnd : fragment.sourceEnd;
            if (provenance != ProvenanceKind.synthetic && boundary >= start && boundary <= finish)
            {
                current.column = column + (boundary == start ? 0 : boundary == finish ? advance
                    : affinity == WrapAffinity.before ? 0 : advance);
                current.sourceBoundary = boundary == start || boundary == finish ? boundary
                    : affinity == WrapAffinity.before ? start : finish;
                current.provenance = provenance;
                break;
            }
            if (provenance != ProvenanceKind.synthetic && boundary < start)
            { current.column = column; current.sourceBoundary = start; break; }
            column += advance;
            current.column = column;
            first = end;
        }
        if (!found || affinity == WrapAffinity.after) chosen = current;
        found = true;
        if (affinity == WrapAffinity.before) break;
    }
    return found ? chosen : WrappedPosition(status: WrapStatus.notBoundary);
}
