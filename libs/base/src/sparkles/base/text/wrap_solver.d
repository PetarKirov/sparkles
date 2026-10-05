/** Exact, bounded finite measured-paragraph search. No font or publication model. */
module sparkles.base.text.wrap_solver;

public import sparkles.base.text.wrap_plan;
import sparkles.base.text.layout_units;
import sparkles.base.text.utf : utfStorageOverlaps, utfObjectStorage, UtfMode, UtfStatus, decodeToken;

@safe nothrow @nogc:

enum PrimitiveKind : ubyte { box, glue, kern, penalty, discretionary, anchor }
enum OpportunityTag : ubyte { optional, forbidden, forced }
enum OpportunityOrigin : ubyte { unicode, authored, discretionary, hyphenation, emergency }
enum TerminalAdjustment : ubyte { ragged, justified }

struct WrapPrimitive
{
    PrimitiveKind kind;
    ulong id;
    WrapDimension dimension;
    long advance, stretch, shrink;
    long minimum, maximum = long.max;
    WrapFragment fragment;
    // Discretionaries use unbroken content unless selected as a line endpoint.
    const(WrapPrimitive)[] unbroken;
    OpportunityTag opportunity;
}
struct WrapEndpoint
{
    size_t end, contentEnd, sourceEnd;
    ulong alternativeId;
    OpportunityTag tag;
    OpportunityOrigin origin;
    int penalty;
    bool flagged, paragraphEnd, terminal, allowOverfull;
    ulong continuationId, providerState;
    const(WrapPrimitive)[] pre, post;
}
struct MeasurableInput
{
    SourceSnapshot source;
    const(WrapPrimitive)[] primitives;
    const(WrapEndpoint)[] endpoints;
    const(SourceRecord)[] sourceRecords;
    WrapDimension dimension;
    ulong resourceRevision;
    UtfMode malformed = UtfMode.strict;
}
private immutable WrapEndpoint[1] emptyTerminal = [
    WrapEndpoint(tag: OpportunityTag.forced, paragraphEnd: true, terminal: true)
];
private MeasurableInput normalizedInput(const ref MeasurableInput supplied)
{
    MeasurableInput input = supplied;
    if (!input.source.bytes.length && !input.primitives.length && !input.endpoints.length)
        input.endpoints = emptyTerminal[];
    return input;
}
struct WrapGeometry
{
    long capacity, startColumn, indentExtent;
    long mandatoryOverflow;
    ulong id, nextState;
    bool unbounded;
    const(WrapFragment)[] indent;
}
struct WrapGeometrySequence
{
    const(WrapGeometry)[] lines;
    bool repeatLast;
    ulong id;
}
struct WrapStartState
{
    size_t primitive, paragraphLine, totalLines;
    size_t previousEndpoint = size_t.max;
    ulong continuationId, providerState, geometryState;
    WrapFitness previousFitness;
    bool previousFlagged, hasPrevious;
}
struct WrapCandidate
{
    WrapStartState start;
    size_t endpoint, geometryAlternative;
}
struct MeasuredGlue
{
    long natural, stretch, shrink, minimum, maximum;
    size_t fragmentOrdinal;
}
struct WrapMeasurement
{
    long natural, stretch, shrink;
    bool safeBreak = true;
    bool allowOverfull;
    /// Exact certificate: for this start, no later endpoint can fit its geometry.
    /// Used only after greedy has a non-overfull choice; overfull alternatives
    /// then cannot outrank it. Arbitrary providers default to no certificate.
    bool noFollowingFit;
    size_t work;
    ulong nextProviderState, visualMap;
    ulong materializationId;
    bool opaqueMaterialization;
    // A custom provider's descriptors borrow immutable provider storage and must
    // survive the plan. Fixed primitives are projected by base instead.
    const(WrapFragment)[] fragments;
    const(MeasuredGlue)[] glues;
}
struct WrapProvider
{
    bool additive, monotone, exact;
    WrapResult delegate(const ref MeasurableInput, WrapCandidate,
        WrapGeometry, size_t remainingWork, ref WrapMeasurement) @safe nothrow @nogc measure;
    WrapResult delegate(WrapStartState, WrapEndpoint, ref WrapGeometry) @safe nothrow @nogc geometry;
}
struct WrapSolverOptions
{
    WrapSolver solver = WrapSolver.greedy;
    WrapRatio stretchTolerance;
    TerminalAdjustment terminal;
    ulong linePenalty, fitnessDemerit, consecutiveDiscretionaryDemerit, terminalDiscretionaryDemerit;
    size_t minimumLines = 1, maximumLines = size_t.max;
}

/// Ranked alternatives retain full prefixes. Single-plan search may discard a
/// dominated prefix only when its complete future state matches another label.
struct WrapSearchState
{
    WrapStartState next;
    size_t predecessor = size_t.max, endpoint = size_t.max, geometryAlternative;
    WrapGeometry geometry;
    WrapMeasurement measurement;
    WrapRatio ratio;
    WrapFitness fitness;
    WrapObjective objective;
    bool overfull;
    bool fixedProjection;
    size_t sourceRank, alternativeRank, ordinalRank;
    size_t dominanceNext = size_t.max;
    bool superseded;
}
struct WrapSolverScratch
{
    WrapSearchState[] states;
    size_t[] selected, ranked;
    size_t[] ordering, temporary;
    ulong[] ids, temporaryIds;
    WrapPrimitive[] candidatePrimitives;
    MeasuredGlue[] candidateGlues;
    long[] glueWidths;
    SourceRecord[] sourceTransforms;
    WrapProjectionScratch projection;
}
struct WrapAlternativeStorage
{
    WrapPlan[] plans;
    WrapPlanStorage metadata;
}
struct WrapAlternativePlans
{
    const(WrapPlan)[] plans;
    bool exhaustive, moreAlternatives;
}

private WrapResult arithmetic() => WrapResult(status: WrapStatus.arithmeticExhausted, phase: WrapPhase.selection);
private WrapResult invalid() => WrapResult(status: WrapStatus.invalidInput, phase: WrapPhase.validation);
private WrapResult scratchFailure(size_t n = 1) => WrapResult(status: WrapStatus.needScratch, required: n);
private WrapResult budget(WrapBudgetKind kind, size_t used, size_t limit)
    => WrapResult(status: WrapStatus.budgetExhausted, phase: WrapPhase.selection, kind: kind, used: used, limit: limit);
bool solverStorageAvoids(T)(WrapSolverScratch scratch, scope const(T)[] borrowed)
{
    return wrapStorageAvoids(borrowed, scratch.states, scratch.selected, scratch.ranked,
        scratch.ordering, scratch.temporary, scratch.ids, scratch.temporaryIds,
        scratch.candidatePrimitives, scratch.candidateGlues, scratch.glueWidths, scratch.sourceTransforms,
        scratch.projection.lines, scratch.projection.fragments, scratch.projection.sourceRecords, scratch.projection.styles);
}
bool solverStorageDisjoint(WrapSolverScratch scratch, WrapPlanStorage storage,
    scope const ref WrapPlan previous)
{
    if (!wrapStorageDisjoint(scratch.states, scratch.selected, scratch.ranked,
        scratch.ordering, scratch.temporary, scratch.ids, scratch.temporaryIds,
        scratch.candidatePrimitives, scratch.candidateGlues, scratch.glueWidths, scratch.sourceTransforms,
        scratch.projection.lines, scratch.projection.fragments, scratch.projection.sourceRecords, scratch.projection.styles,
        storage.lines, storage.fragments, storage.sourceRecords, storage.styles)) return false;
    return wrapPlanAvoids(previous, scratch.states, scratch.selected, scratch.ranked,
        scratch.ordering, scratch.temporary, scratch.ids, scratch.temporaryIds,
        scratch.candidatePrimitives, scratch.candidateGlues, scratch.glueWidths, scratch.sourceTransforms,
        scratch.projection.lines, scratch.projection.fragments, scratch.projection.sourceRecords, scratch.projection.styles,
        storage.lines, storage.fragments, storage.sourceRecords, storage.styles);
}
private bool inputStorageAvoids(Slices...)(scope const ref MeasurableInput input,
    scope const(WrapGeometrySequence)[] geometries, Slices arenas)
{
    if (!wrapStorageAvoids(input.source.bytes, arenas)
        || !wrapStorageAvoids(input.primitives, arenas)
        || !wrapStorageAvoids(input.endpoints, arenas)
        || !wrapStorageAvoids(input.sourceRecords, arenas)
        || !wrapStorageAvoids(geometries, arenas)) return false;
    foreach (ref const p; input.primitives)
    {
        if (!wrapStorageAvoids(p.unbroken, arenas) || !wrapStorageAvoids(p.fragment.bytes, arenas)) return false;
        foreach (ref const leaf; p.unbroken) if (!wrapStorageAvoids(leaf.fragment.bytes, arenas)) return false;
    }
    foreach (ref const e; input.endpoints)
    {
        if (!wrapStorageAvoids(e.pre, arenas) || !wrapStorageAvoids(e.post, arenas)) return false;
        foreach (ref const p; e.pre) if (!wrapStorageAvoids(p.fragment.bytes, arenas)) return false;
        foreach (ref const p; e.post) if (!wrapStorageAvoids(p.fragment.bytes, arenas)) return false;
    }
    foreach (ref const sequence; geometries)
    {
        if (!wrapStorageAvoids(sequence.lines, arenas)) return false;
        foreach (ref const g; sequence.lines)
        {
            if (!wrapStorageAvoids(g.indent, arenas)) return false;
            foreach (ref const f; g.indent) if (!wrapStorageAvoids(f.bytes, arenas)) return false;
        }
    }
    return true;
}
private bool measuredStorageAvoids(Slices...)(scope const(WrapSearchState)[] states, Slices arenas)
{
    foreach (ref const state; states)
    {
        if (!wrapStorageAvoids(state.geometry.indent, arenas)
            || !wrapStorageAvoids(state.measurement.fragments, arenas)
            || !wrapStorageAvoids(state.measurement.glues, arenas)) return false;
        foreach (ref const fragment; state.geometry.indent)
            if (!wrapStorageAvoids(fragment.bytes, arenas)) return false;
        foreach (ref const fragment; state.measurement.fragments)
            if (!wrapStorageAvoids(fragment.bytes, arenas)) return false;
    }
    return true;
}

private bool uniqueIds(scope ulong[] ids, scope ulong[] temporary)
{
    foreach (digit; 0U .. 8U)
    {
        size_t[256] bins;
        foreach (id; ids) ++bins[(id >> (digit * 8)) & 255];
        size_t cursor;
        foreach (ref bin; bins) { const n = bin; bin = cursor; cursor += n; }
        foreach (id; ids) temporary[bins[(id >> (digit * 8)) & 255]++] = id;
        ids[] = temporary[0 .. ids.length];
    }
    foreach (i; 1 .. ids.length) if (ids[i] == ids[i - 1]) return false;
    return true;
}

private bool sourceBoundary(scope const ref MeasurableInput input, size_t position)
{
    if (position > input.source.bytes.length) return false;
    if (!position || position == input.source.bytes.length) return true;
    const start = position > 3 ? position - 3 : 0;
    foreach (offset; start .. position)
    {
        const decoded = decodeToken(input.source.bytes[offset .. $], input.malformed, true, offset);
        if (decoded.result.status == UtfStatus.ok && decoded.token.end > position) return false;
    }
    return true;
}
private bool validSourceFragment(scope const ref MeasurableInput input, scope const ref WrapFragment fragment)
{
    return fragment.sourceStart <= fragment.sourceEnd && sourceBoundary(input, fragment.sourceStart)
        && sourceBoundary(input, fragment.sourceEnd) && sourceBoundary(input, fragment.anchor)
        && (fragment.provenance != ProvenanceKind.synthetic || fragment.sourceStart == fragment.sourceEnd);
}
private bool validLeaf(scope const ref WrapPrimitive p, WrapDimension dimension)
{
    if (p.dimension != dimension || p.kind == PrimitiveKind.penalty
        || p.kind == PrimitiveKind.discretionary || p.unbroken.length) return false;
    if (p.kind == PrimitiveKind.kern) return p.stretch == 0 && p.shrink == 0;
    if (p.kind == PrimitiveKind.anchor) return p.advance == 0 && p.stretch == 0 && p.shrink == 0;
    if (p.advance < 0 || p.stretch < 0 || p.shrink < 0 || p.shrink > p.advance) return false;
    if (p.kind == PrimitiveKind.box && (p.stretch || p.shrink)) return false;
    return p.kind != PrimitiveKind.glue || (p.minimum >= 0 && p.minimum <= p.advance
        && p.maximum >= p.advance);
}
private WrapResult validate(scope const ref MeasurableInput input,
    scope const(WrapGeometrySequence)[] geometries, scope WrapProvider provider,
    WrapSolverOptions options, WrapLimits limits, WrapSolverScratch scratch, bool structureOnly = false)
{
    if ((!structureOnly && !geometries.length) || !input.endpoints.length || options.minimumLines == 0
        || options.maximumLines < options.minimumLines || options.stretchTolerance.denominator == 0
        || options.stretchTolerance.negative) return invalid();
    if (provider.measure !is null && !provider.exact)
        return WrapResult(status: WrapStatus.exactMeasurementRequired);
    if (input.source.bytes.length > limits.sourceBytes)
        return budget(WrapBudgetKind.sourceBytes, input.source.bytes.length, limits.sourceBytes);
    size_t records = input.primitives.length;
    foreach (ref const p; input.primitives)
    {
        if (p.unbroken.length > size_t.max - records) return arithmetic();
        records += p.unbroken.length;
    }
    foreach (ref const e; input.endpoints)
    {
        if (e.pre.length > size_t.max - records) return arithmetic();
        records += e.pre.length;
        if (e.post.length > size_t.max - records) return arithmetic();
        records += e.post.length;
    }
    if (records > limits.inputRecords) return budget(WrapBudgetKind.inputRecords, records, limits.inputRecords);
    if (input.endpoints.length > limits.alternatives)
        return budget(WrapBudgetKind.alternatives, input.endpoints.length, limits.alternatives);
    WrapPlan empty;
    WrapPlanStorage noOutput;
    if (!solverStorageDisjoint(scratch, noOutput, empty)
        || !solverStorageAvoids(scratch, input.source.bytes)
        || !solverStorageAvoids(scratch, input.primitives)
        || !solverStorageAvoids(scratch, input.endpoints)
        || !solverStorageAvoids(scratch, input.sourceRecords)
        || !solverStorageAvoids(scratch, geometries)) return invalid();
    foreach (ref const p; input.primitives)
    {
        if (!solverStorageAvoids(scratch, p.unbroken) || !solverStorageAvoids(scratch, p.fragment.bytes)) return invalid();
        foreach (ref const leaf; p.unbroken)
            if (!solverStorageAvoids(scratch, leaf.fragment.bytes)) return invalid();
    }
    foreach (ref const e; input.endpoints)
    {
        if (!solverStorageAvoids(scratch, e.pre) || !solverStorageAvoids(scratch, e.post)) return invalid();
        foreach (ref const p; e.pre) if (!solverStorageAvoids(scratch, p.fragment.bytes)) return invalid();
        foreach (ref const p; e.post) if (!solverStorageAvoids(scratch, p.fragment.bytes)) return invalid();
    }
    foreach (ref const geometry; geometries)
    {
        if (!solverStorageAvoids(scratch, geometry.lines)) return invalid();
        foreach (ref const line; geometry.lines)
        {
            if (!solverStorageAvoids(scratch, line.indent)) return invalid();
            foreach (ref const f; line.indent) if (!solverStorageAvoids(scratch, f.bytes)) return invalid();
        }
    }
    const largest = input.primitives.length > input.endpoints.length ? input.primitives.length : input.endpoints.length;
    const maximumIds = largest > 1 ? largest : 0;
    if (scratch.ids.length < maximumIds || scratch.temporaryIds.length < maximumIds) return scratchFailure(maximumIds);
    if (input.primitives.length > 1)
    {
        foreach (i, ref const p; input.primitives) scratch.ids[i] = p.id;
        if (!uniqueIds(scratch.ids[0 .. input.primitives.length], scratch.temporaryIds)) return invalid();
    }
    if (input.endpoints.length > 1)
    {
        foreach (i, ref const e; input.endpoints) scratch.ids[i] = e.alternativeId;
        if (!uniqueIds(scratch.ids[0 .. input.endpoints.length], scratch.temporaryIds)) return invalid();
    }
    size_t sourceOffset;
    while (sourceOffset < input.source.bytes.length)
    {
        const decoded = decodeToken(input.source.bytes[sourceOffset .. $], input.malformed, true, sourceOffset);
        if (decoded.result.status != UtfStatus.ok)
            return WrapResult(status: WrapStatus.invalidEncoding, phase: WrapPhase.validation,
                sourceStart: sourceOffset, sourceEnd: sourceOffset + decoded.result.consumed);
        sourceOffset = decoded.token.end;
    }
    size_t lastOwnedEnd;
    foreach (i, ref const p; input.primitives)
    {
        if (p.dimension != input.dimension || !validSourceFragment(input, p.fragment)) return invalid();
        if (p.kind == PrimitiveKind.discretionary)
        {
            foreach (ref const leaf; p.unbroken)
                if (!validLeaf(leaf, input.dimension) || !validSourceFragment(input, leaf.fragment)) return invalid();
        }
        else if (p.kind == PrimitiveKind.penalty)
        {
            if (p.advance || p.stretch || p.shrink || p.unbroken.length) return invalid();
        }
        else if (!validLeaf(p, input.dimension)) return invalid();
        if (p.fragment.sourceEnd > p.fragment.sourceStart)
        {
            if (p.fragment.sourceStart < lastOwnedEnd) return invalid();
            lastOwnedEnd = p.fragment.sourceEnd;
        }
    }
    foreach (i, ref const e; input.endpoints)
    {
        if (e.end > input.primitives.length || e.contentEnd > e.end
            || e.sourceEnd > input.source.bytes.length
            || (e.tag == OpportunityTag.optional && (e.penalty < -10000 || e.penalty > 10000))
            || (i && (e.end < input.endpoints[i - 1].end || e.sourceEnd < input.endpoints[i - 1].sourceEnd))) return invalid();
        if (!e.end && !(e.terminal && input.primitives.length == 0)) return invalid();
        if (!sourceBoundary(input, e.sourceEnd)) return invalid();
        foreach (ref const p; e.pre)
            if (!validLeaf(p, input.dimension) || !validSourceFragment(input, p.fragment)) return invalid();
        foreach (ref const p; e.post)
            if (!validLeaf(p, input.dimension) || !validSourceFragment(input, p.fragment)) return invalid();
        if (e.terminal && (e.end != input.primitives.length || !e.paragraphEnd
            || e.sourceEnd != input.source.bytes.length)) return invalid();
    }
    if (!input.endpoints[$ - 1].terminal) return invalid();
    foreach (i, ref const p; input.primitives)
        if (p.kind == PrimitiveKind.penalty || p.kind == PrimitiveKind.discretionary)
        {
            bool found;
            foreach (ref const e; input.endpoints)
                if (e.end == i + 1 && e.tag == p.opportunity) found = true;
            if (!found && p.opportunity != OpportunityTag.forbidden) return invalid();
        }
    size_t end;
    foreach (ref const record; input.sourceRecords)
    {
        if (record.start != end || record.end < end || record.end > input.source.bytes.length) return invalid();
        if (!sourceBoundary(input, record.start) || !sourceBoundary(input, record.end)) return invalid();
        end = record.end;
    }
    if (end != input.source.bytes.length) return invalid();
    foreach (ref const geometry; geometries)
    {
        if (!geometry.lines.length && provider.geometry is null) return invalid();
        foreach (ref const line; geometry.lines)
            if (line.capacity < 0 || line.startColumn < 0 || line.indentExtent < 0 || line.mandatoryOverflow < 0) return invalid();
    }
    return WrapResult.init;
}

/// Assemble one exact candidate, replacing the selected discretionary and carrying
/// the previous endpoint's post sequence. No additive/monotone assumption is used.
private WrapResult assemble(scope const ref MeasurableInput input, WrapCandidate key,
    scope WrapPrimitive[] output, ref size_t count)
{
    size_t n;
    WrapResult append(scope const(WrapPrimitive)[] sequence)
    {
        if (sequence.length > output.length - n) return scratchFailure(sequence.length - (output.length - n));
        output[n .. n + sequence.length] = sequence[];
        n += sequence.length;
        return WrapResult.init;
    }
    if (key.start.previousEndpoint != size_t.max)
    {
        auto r = append(input.endpoints[key.start.previousEndpoint].post);
        if (!r.succeeded) return r;
    }
    const endpoint = input.endpoints[key.endpoint];
    if (endpoint.contentEnd < key.start.primitive) return invalid();
    foreach (i; key.start.primitive .. endpoint.contentEnd)
    {
        const p = input.primitives[i];
        if (p.kind == PrimitiveKind.discretionary)
        {
            if (i + 1 == endpoint.end) continue;
            auto r = append(p.unbroken);
            if (!r.succeeded) return r;
        }
        else if (p.kind != PrimitiveKind.penalty)
        {
            if (n == output.length) return scratchFailure();
            output[n++] = p;
        }
    }
    auto r = append(endpoint.pre);
    if (!r.succeeded) return r;
    count = n;
    return WrapResult.init;
}
// Endpoint permission cannot turn several policy units into one. Equal boundary
// alternatives remain distinct and forbidden opportunities do not end a unit.
// A contextual provider may instead certify its actual indivisible
// materialization through measurement.allowOverfull.
private bool legalOverfullUnit(scope const ref MeasurableInput input, WrapCandidate key)
{
    const end = input.endpoints[key.endpoint].end;
    foreach (ref const endpoint; input.endpoints)
        if (endpoint.end > key.start.primitive && endpoint.end < end
            && endpoint.tag != OpportunityTag.forbidden) return false;
    return true;
}


private WrapResult fixedMeasure(const(WrapPrimitive)[] pieces,
    MeasuredGlue[] glues, ref WrapMeasurement measurement)
{
    WrapMeasurement m;
    size_t g;
    foreach (i, ref const p; pieces)
    {
        LayoutUnit a = LayoutUnit(m.natural), b = LayoutUnit(p.advance), sum;
        if (checkedAdd(a, b, sum) != UnitStatus.ok) return arithmetic();
        m.natural = sum.raw;
        if (p.stretch > long.max - m.stretch || p.shrink > long.max - m.shrink) return arithmetic();
        m.stretch += p.stretch;
        m.shrink += p.shrink;
        if (p.kind == PrimitiveKind.glue)
        {
            if (g == glues.length) return scratchFailure();
            glues[g++] = MeasuredGlue(p.advance, p.stretch, p.shrink, p.minimum, p.maximum, i);
        }
    }
    m.glues = glues[0 .. g];
    measurement = m;
    return WrapResult.init;
}

private WrapResult mul(ulong a, ulong b, ref U128 outValue)
{
    return checkedMultiply(U128(a), U128(b), outValue) == UnitStatus.ok ? WrapResult.init : arithmetic();
}
private WrapResult distance(long high, long low, ref ulong result)
{
    I128 difference;
    if (checkedSubtract(signedWide(high), signedWide(low), difference) != UnitStatus.ok
        || difference.negative || difference.magnitude.hi) return arithmetic();
    result = difference.magnitude.lo;
    return WrapResult.init;
}
private ulong divisor64(ulong a, ulong b)
{
    while (b) { const remainder = a % b; a = b; b = remainder; }
    return a;
}
private WrapResult ratioFor(WrapMeasurement m, long target, WrapSolverOptions options,
    bool terminal, bool overfull, ref WrapRatio ratio, ref WrapFitness fitness, ref ulong badness)
{
    if (overfull) { badness = 10000; fitness = WrapFitness.tight; ratio = WrapRatio.init; return WrapResult.init; }
    if (terminal && options.terminal == TerminalAdjustment.ragged && m.natural <= target)
    { ratio = WrapRatio.init; fitness = WrapFitness.decent; badness = 0; return WrapResult.init; }
    const negative = m.natural > target;
    ulong diff;
    if (!(negative ? distance(m.natural, target, diff) : distance(target, m.natural, diff)).succeeded) return arithmetic();
    const coefficient = negative ? m.shrink : m.stretch;
    if (diff && coefficient == 0) return WrapResult(status: WrapStatus.noFeasiblePlan);
    ulong denominator = diff ? cast(ulong) coefficient : 1UL;
    const gcd = divisor64(diff, denominator);
    diff /= gcd; denominator /= gcd;
    ratio = WrapRatio(diff, denominator, negative);
    U128 lhs, rhs;
    if (negative && diff > denominator) return WrapResult(status: WrapStatus.noFeasiblePlan);
    if (!negative)
    {
        if (!mul(diff, options.stretchTolerance.denominator, lhs).succeeded
            || !mul(options.stretchTolerance.numerator, denominator, rhs).succeeded) return arithmetic();
        if (compare(lhs, rhs) > 0) return WrapResult(status: WrapStatus.noFeasiblePlan);
    }
    U128 twice;
    if (!mul(diff, 2, twice).succeeded) return arithmetic();
    const halfCompare = compare(twice, U128(denominator));
    fitness = negative ? (halfCompare > 0 ? WrapFitness.tight : WrapFitness.decent)
        : halfCompare <= 0 ? WrapFitness.decent : diff <= denominator ? WrapFitness.loose : WrapFitness.veryLoose;
    U128 numerator, divisor, square;
    if (checkedSquare(diff, square) != UnitStatus.ok
        || checkedMultiply(square, U128(diff), numerator) != UnitStatus.ok
        || checkedMultiply(numerator, U128(100), numerator) != UnitStatus.ok
        || checkedSquare(denominator, square) != UnitStatus.ok
        || checkedMultiply(square, U128(denominator), divisor) != UnitStatus.ok) return arithmetic();
    U128 quotient, remainder;
    if (checkedDivide(numerator, divisor, quotient, remainder) != UnitStatus.ok) return arithmetic();
    if (remainder.lo || remainder.hi)
        if (checkedAdd(quotient, U128(1), quotient) != UnitStatus.ok) return arithmetic();
    badness = quotient.hi || quotient.lo > 10000 ? 10000 : quotient.lo;
    return WrapResult.init;
}

/// Glue realization is bounded by 64 full scans plus linear passes, independent
/// of residual magnitude. The same routine is used for feasibility and projection.
WrapResult realizeWrapGlue(scope const(MeasuredGlue)[] glues, long natural,
    long target, WrapRatio ratio, WrapRatio tolerance, scope long[] widths,
    bool naturalOnly = false)
{
    if (!ratio.denominator || !tolerance.denominator || tolerance.negative || target < 0
        || utfStorageOverlaps(glues, widths)) return invalid();
    if (glues.length > size_t.max / 2) return arithmetic();
    if (widths.length < glues.length * 2) return scratchFailure(glues.length * 2 - widths.length);
    long total = natural;
    foreach (i, ref const glue; glues)
    {
        if (glue.natural < 0 || glue.stretch < 0 || glue.shrink < 0 || glue.shrink > glue.natural
            || glue.minimum < 0 || glue.minimum > glue.natural || glue.maximum < glue.natural) return invalid();
        if (naturalOnly) { widths[i] = glue.natural; continue; }
        U128 stretchProduct, stretchQuotient, remainder;
        if (!mul(tolerance.numerator, cast(ulong) glue.stretch, stretchProduct).succeeded
            || checkedDivide(stretchProduct, U128(tolerance.denominator), stretchQuotient, remainder) != UnitStatus.ok)
            return arithmetic();
        U128 widenedUpper;
        if (checkedAdd(U128(cast(ulong) glue.natural), stretchQuotient, widenedUpper) != UnitStatus.ok) return arithmetic();
        const upper = compare(widenedUpper, U128(cast(ulong) glue.maximum)) < 0
            ? cast(long) widenedUpper.lo : glue.maximum;
        const lower = glue.minimum > glue.natural - glue.shrink ? glue.minimum : glue.natural - glue.shrink;
        U128 product;
        if (!mul(ratio.numerator, cast(ulong) (ratio.negative ? glue.shrink : glue.stretch), product).succeeded)
            return arithmetic();
        Rational adjusted = Rational(I128(product, ratio.negative), U128(ratio.denominator));
        Rational base = Rational(signedWide(glue.natural), U128(1)), ideal;
        long width;
        int lowerCompare, upperCompare;
        if (checkedAdd(base, adjusted, ideal) != UnitStatus.ok
            || checkedCompare(ideal, Rational(signedWide(lower), U128(1)), lowerCompare) != UnitStatus.ok
            || checkedCompare(ideal, Rational(signedWide(upper), U128(1)), upperCompare) != UnitStatus.ok) return arithmetic();
        if (lowerCompare < 0) width = lower;
        else if (upperCompare > 0) width = upper;
        else if (checkedRound(ideal, width) != UnitStatus.ok) return arithmetic();
        LayoutUnit sum;
        if (checkedAdd(LayoutUnit(total), LayoutUnit(width - glue.natural), sum) != UnitStatus.ok) return arithmetic();
        total = sum.raw;
        widths[i] = width;
        widths[glues.length + i] = upper;
    }
    if (naturalOnly) return WrapResult.init;
    const negative = total > target;
    ulong residual;
    if (!(negative ? distance(total, target, residual) : distance(target, total, residual)).succeeded) return arithmetic();
    ulong maximum;
    U128 capacity;
    foreach (i, ref const glue; glues)
    {
        const lower = glue.minimum > glue.natural - glue.shrink ? glue.minimum : glue.natural - glue.shrink;
        widths[glues.length + i] = negative ? widths[i] - lower : widths[glues.length + i] - widths[i];
    }
    ulong remainingCapacity(size_t i) => cast(ulong) widths[glues.length + i];
    foreach (i; 0 .. glues.length)
    {
        const c = remainingCapacity(i);
        if (c > maximum) maximum = c;
        if (checkedAdd(capacity, U128(c), capacity) != UnitStatus.ok) return arithmetic();
    }
    if (compare(U128(residual), capacity) > 0) return WrapResult(status: WrapStatus.noFeasiblePlan);
    ulong lo, hi = maximum;
    while (lo < hi)
    {
        const middle = lo + (hi - lo) / 2 + (hi - lo) % 2;
        U128 sum;
        foreach (i; 0 .. glues.length)
        {
            const c = remainingCapacity(i);
            if (checkedAdd(sum, U128(c < middle ? c : middle), sum) != UnitStatus.ok) return arithmetic();
        }
        if (compare(sum, U128(residual)) <= 0) lo = middle;
        else hi = middle - 1;
    }
    ulong left = residual;
    foreach (i; 0 .. glues.length)
    {
        const c = remainingCapacity(i);
        const delta = c < lo ? c : lo;
        widths[i] += negative ? -cast(long) delta : cast(long) delta;
        widths[glues.length + i] -= cast(long) delta;
        left -= delta;
    }
    foreach (i; 0 .. glues.length)
        if (left && remainingCapacity(i)) { widths[i] += negative ? -1 : 1; --left; }
    return left ? WrapResult(status: WrapStatus.noFeasiblePlan) : WrapResult.init;
}

private WrapResult costEdge(scope const ref WrapSearchState parent, WrapEndpoint endpoint,
    WrapGeometry geometry, WrapMeasurement m, WrapSolverOptions options,
    bool overfullAllowed, ref WrapSearchState state, scope long[] glueWidths)
{
    state.objective = parent.objective;
    if (state.objective.lines == size_t.max) return arithmetic();
    ++state.objective.lines;
    if (endpoint.origin == OpportunityOrigin.emergency)
    {
        if (state.objective.emergencyBreaks == size_t.max) return arithmetic();
        ++state.objective.emergencyBreaks;
    }
    if (m.stretch < 0 || m.shrink < 0) return invalid();
    ulong badness;
    if (options.solver == WrapSolver.knuthPlass)
    {
        if (geometry.unbounded) return WrapResult(status: WrapStatus.unsupportedCapability);
        auto feasibility = geometry.mandatoryOverflow > 0 ? WrapResult(status: WrapStatus.noFeasiblePlan)
            : ratioFor(m, geometry.capacity, options, endpoint.paragraphEnd, false,
                state.ratio, state.fitness, badness);
        if (feasibility.succeeded)
            feasibility = realizeWrapGlue(m.glues, m.natural, geometry.capacity, state.ratio,
                options.stretchTolerance, glueWidths,
                endpoint.paragraphEnd && options.terminal == TerminalAdjustment.ragged && m.natural <= geometry.capacity);
        if (!feasibility.succeeded && feasibility.status != WrapStatus.noFeasiblePlan) return feasibility;
        if (feasibility.succeeded) state.overfull = false;
        else
        {
            state.overfull = m.natural > geometry.capacity || geometry.mandatoryOverflow > 0;
            if (!state.overfull || !overfullAllowed) return feasibility;
            auto r = ratioFor(m, geometry.capacity, options, endpoint.paragraphEnd, true,
                state.ratio, state.fitness, badness);
            if (!r.succeeded) return r;
            r = realizeWrapGlue(m.glues, m.natural, geometry.capacity, state.ratio,
                options.stretchTolerance, glueWidths, true);
            if (!r.succeeded) return r;
        }
    }
    else state.overfull = !geometry.unbounded && (m.natural > geometry.capacity || geometry.mandatoryOverflow > 0);
    if (state.overfull)
    {
        if (!overfullAllowed) return WrapResult(status: WrapStatus.noFeasiblePlan);
        if (state.objective.overfullLines == size_t.max) return arithmetic();
        ++state.objective.overfullLines;
        U128 sum;
        const excess = m.natural > geometry.capacity ? cast(ulong) m.natural - cast(ulong) geometry.capacity : 0UL;
        U128 overflow;
        if (checkedAdd(U128(excess), U128(cast(ulong) geometry.mandatoryOverflow), overflow) != UnitStatus.ok
            || checkedAdd(U128(state.objective.overflowLow, state.objective.overflowHigh), overflow, sum) != UnitStatus.ok) return arithmetic();
        state.objective.overflowLow = sum.lo; state.objective.overflowHigh = sum.hi;
    }
    if (options.solver == WrapSolver.balanced)
    {
        U128 cost = U128(state.objective.costLow, state.objective.costHigh), square;
        ulong slack;
        if (!endpoint.paragraphEnd && !geometry.unbounded && m.natural < geometry.capacity)
            if (!distance(geometry.capacity, m.natural, slack).succeeded) return arithmetic();
        if (checkedSquare(slack, square) != UnitStatus.ok || checkedAdd(cost, square, cost) != UnitStatus.ok)
            return arithmetic();
        state.objective.costLow = cost.lo; state.objective.costHigh = cost.hi;
    }
    else if (options.solver == WrapSolver.knuthPlass)
    {
        if (badness > ulong.max - options.linePenalty) return arithmetic();
        U128 square;
        if (checkedSquare(options.linePenalty + badness, square) != UnitStatus.ok) return arithmetic();
        I128 demerit = I128(square, false), term;
        if (endpoint.tag == OpportunityTag.optional)
        {
            const p = endpoint.penalty < 0 ? cast(ulong) -cast(long) endpoint.penalty : cast(ulong) endpoint.penalty;
            if (checkedSquare(p, square) != UnitStatus.ok) return arithmetic();
            term = I128(square, endpoint.penalty < 0);
            if (checkedAdd(demerit, term, demerit) != UnitStatus.ok) return arithmetic();
        }
        if (parent.next.hasPrevious)
        {
            const difference = cast(int) state.fitness - cast(int) parent.next.previousFitness;
            if (difference > 1 || difference < -1)
                if (checkedAdd(demerit, I128(U128(options.fitnessDemerit), false), demerit) != UnitStatus.ok) return arithmetic();
            if (parent.next.previousFlagged && endpoint.flagged)
                if (checkedAdd(demerit, I128(U128(options.consecutiveDiscretionaryDemerit), false), demerit) != UnitStatus.ok) return arithmetic();
            if (parent.next.previousFlagged && endpoint.paragraphEnd)
                if (checkedAdd(demerit, I128(U128(options.terminalDiscretionaryDemerit), false), demerit) != UnitStatus.ok) return arithmetic();
        }
        I128 total = I128(U128(state.objective.costLow, state.objective.costHigh), state.objective.negativeCost);
        if (checkedAdd(total, demerit, total) != UnitStatus.ok) return arithmetic();
        state.objective.costLow = total.magnitude.lo; state.objective.costHigh = total.magnitude.hi;
        state.objective.negativeCost = total.negative;
    }
    return WrapResult.init;
}

private int compareObjective(WrapObjective a, WrapObjective b, bool includeLines = true)
{
    if (a.overfullLines != b.overfullLines) return a.overfullLines < b.overfullLines ? -1 : 1;
    int c = compare(U128(a.overflowLow, a.overflowHigh), U128(b.overflowLow, b.overflowHigh));
    if (c) return c;
    if (a.emergencyBreaks != b.emergencyBreaks) return a.emergencyBreaks < b.emergencyBreaks ? -1 : 1;
    if (a.negativeCost != b.negativeCost) return a.negativeCost ? -1 : 1;
    c = compare(U128(a.costLow, a.costHigh), U128(b.costLow, b.costHigh));
    if (a.negativeCost) c = -c;
    if (c) return c;
    return includeLines && a.lines != b.lines ? (a.lines < b.lines ? -1 : 1) : 0;
}
// Prefix ranks are computed breadth-by-depth with stable radix sorts over
// (previous rank, current logical key). This gives constant-time complete tie
// comparison without copying paths into states or repeated predecessor walks.
private ubyte rankDigit(scope const ref MeasurableInput input,
    scope const(WrapSearchState)[] states, size_t index, uint kind, uint byteIndex)
{
    const state = states[index];
    ulong value;
    if (byteIndex < 8)
    {
        const endpoint = input.endpoints[state.endpoint];
        value = kind == 0 ? ~cast(ulong) endpoint.sourceEnd
            : kind == 1 ? endpoint.alternativeId : cast(ulong) state.endpoint;
    }
    else
    {
        const parent = states[state.predecessor];
        value = cast(ulong)(kind == 0 ? parent.sourceRank
            : kind == 1 ? parent.alternativeRank : parent.ordinalRank);
        byteIndex -= 8;
    }
    // Shift the full 64-bit key before narrowing its bounded [0, 255] digit.
    return cast(ubyte)((value >> (byteIndex * 8)) & ubyte.max);
}
private void rankPrefixes(scope const ref MeasurableInput input, scope WrapSearchState[] states,
    scope size_t[] ordering, scope size_t[] temporary, size_t maximumDepth)
{
    foreach (depth; 1 .. maximumDepth + 1)
    {
        size_t count;
        foreach (i, ref const state; states)
            if (state.objective.lines == depth) ordering[count++] = i;
        foreach (kind; 0U .. 3U)
        {
            foreach (digit; 0U .. 16U)
            {
                size_t[256] bins;
                foreach (i; ordering[0 .. count]) ++bins[rankDigit(input, states, i, kind, digit)];
                size_t cursor;
                foreach (ref bin; bins) { const n = bin; bin = cursor; cursor += n; }
                foreach (i; ordering[0 .. count])
                    temporary[bins[rankDigit(input, states, i, kind, digit)]++] = i;
                ordering[0 .. count] = temporary[0 .. count];
            }
            size_t rank;
            foreach (position; 0 .. count)
            {
                if (position)
                {
                    bool same = true;
                    foreach (digit; 0U .. 16U)
                        same &= rankDigit(input, states, ordering[position], kind, digit)
                            == rankDigit(input, states, ordering[position - 1], kind, digit);
                    if (!same) ++rank;
                }
                ref state = states[ordering[position]];
                if (kind == 0) state.sourceRank = rank;
                else if (kind == 1) state.alternativeRank = rank;
                else state.ordinalRank = rank;
            }
        }
    }
}
private int comparePath(scope const ref MeasurableInput input,
    scope const(WrapSearchState)[] states, size_t a, size_t b)
{
    const x = states[a], y = states[b];
    const cost = compareObjective(x.objective, y.objective);
    if (cost) return cost;
    if (x.sourceRank != y.sourceRank) return x.sourceRank < y.sourceRank ? -1 : 1;
    if (x.alternativeRank != y.alternativeRank) return x.alternativeRank < y.alternativeRank ? -1 : 1;
    if (x.ordinalRank != y.ordinalRank) return x.ordinalRank < y.ordinalRank ? -1 : 1;
    return x.geometryAlternative < y.geometryAlternative ? -1
        : x.geometryAlternative > y.geometryAlternative ? 1 : 0;
}
private void sortCompletePaths(scope const ref MeasurableInput input,
    scope const(WrapSearchState)[] states, scope size_t[] ordering, scope size_t[] temporary)
{
    size_t run = 1;
    while (run < ordering.length)
    {
        size_t start;
        while (start < ordering.length)
        {
            const middle = start + (run < ordering.length - start ? run : ordering.length - start);
            const end = middle + (run < ordering.length - middle ? run : ordering.length - middle);
            size_t left = start, right = middle, outIndex = start;
            while (left < middle || right < end)
                temporary[outIndex++] = right == end || (left < middle
                    && comparePath(input, states, ordering[left], ordering[right]) <= 0)
                    ? ordering[left++] : ordering[right++];
            start = end;
        }
        ordering[] = temporary[0 .. ordering.length];
        if (run > ordering.length / 2) break;
        run *= 2;
    }
}

private size_t futureHash(scope const ref WrapSearchState state)
{
    const s = state.next;
    return s.primitive ^ (s.paragraphLine * 131) ^ (s.totalLines * 8191)
        ^ (s.previousEndpoint * 524287) ^ cast(size_t) s.providerState
        ^ cast(size_t) s.geometryState ^ cast(size_t) s.continuationId
        ^ state.geometryAlternative;
}

// Prefix tie order must agree with rankPrefixes, before those ranks exist.
private int comparePrefix(scope const ref MeasurableInput input,
    scope const(WrapSearchState)[] states, scope const ref WrapSearchState a,
    scope const ref WrapSearchState b)
{
    const cost = compareObjective(a.objective, b.objective);
    if (cost) return cost;
    foreach (kind; 0 .. 3)
        foreach (depth; 0 .. a.objective.lines)
        {
            size_t xi = a.endpoint, yi = b.endpoint;
            if (depth + 1 < a.objective.lines)
            {
                size_t x = a.predecessor, y = b.predecessor;
                foreach (_; depth + 2 .. a.objective.lines)
                {
                    x = states[x].predecessor;
                    y = states[y].predecessor;
                }
                xi = states[x].endpoint;
                yi = states[y].endpoint;
            }
            const xv = kind == 0 ? ~cast(ulong) input.endpoints[xi].sourceEnd
                : kind == 1 ? input.endpoints[xi].alternativeId : cast(ulong) xi;
            const yv = kind == 0 ? ~cast(ulong) input.endpoints[yi].sourceEnd
                : kind == 1 ? input.endpoints[yi].alternativeId : cast(ulong) yi;
            if (xv != yv) return xv < yv ? -1 : 1;
        }
    return 0;
}

/// Complete search, including ranked prefix labels. Exact exhaustion never
/// publishes an incumbent or switches modes. Greedy prunes only certified tails.
private WrapResult search(const ref MeasurableInput input,
    scope const(WrapGeometrySequence)[] geometries, scope WrapProvider provider,
    WrapSolverOptions options, WrapLimits limits, WrapSolverScratch scratch,
    size_t resultLimit, bool exhaustive, ref size_t stateCount,
    ref size_t resultCount, ref size_t available, ref WrapUsage usage, bool singlePlan = false)
{
    auto r = validate(input, geometries, provider, options, limits, scratch);
    if (!r.succeeded) return r;
    usage.sourceBytes = input.source.bytes.length;
    usage.inputRecords = input.primitives.length;
    foreach (ref const p; input.primitives) usage.inputRecords += p.unbroken.length;
    foreach (ref const e; input.endpoints) usage.inputRecords += e.pre.length + e.post.length;
    usage.alternatives = input.endpoints.length;
    const dominate = singlePlan && resultLimit == 1 && !exhaustive
        && options.solver != WrapSolver.greedy;
    if (dominate && !scratch.ordering.length) return scratchFailure();
    if (dominate) scratch.ordering[] = size_t.max;
    // Validation's radix arena is free until the next validation. Endpoints are
    // ordered by end, so cache the next forced bound once, not once per state.
    if (input.endpoints.length > 1)
    {
        size_t forced = input.primitives.length;
        foreach_reverse (i; 0 .. input.endpoints.length)
        {
            if (input.endpoints[i].tag == OpportunityTag.forced) forced = input.endpoints[i].end;
            scratch.temporaryIds[i] = forced;
        }
    }
    size_t n;
    foreach (g; 0 .. geometries.length)
    {
        if (n == limits.states) return budget(WrapBudgetKind.states, n, limits.states);
        if (n == scratch.states.length) return scratchFailure();
        scratch.states[n] = WrapSearchState.init;
        scratch.states[n++].geometryAlternative = g;
    }
    size_t count, total;
    for (size_t cursor; cursor < n; ++cursor)
    {
        const parent = scratch.states[cursor];
        if (parent.superseded) continue;
        if (parent.endpoint != size_t.max && input.endpoints[parent.endpoint].terminal)
        {
            if (total == size_t.max) return arithmetic();
            ++total;
            if (exhaustive && total > resultLimit) return WrapResult(status: WrapStatus.needResults, required: total);
            continue;
        }
        if (parent.next.paragraphLine >= options.maximumLines) continue;
        size_t first, upper = input.endpoints.length;
        while (first < upper)
        {
            const middle = first + (upper - first) / 2;
            if (input.endpoints[middle].end <= parent.next.primitive) first = middle + 1;
            else upper = middle;
        }
        if (!parent.next.primitive && parent.endpoint == size_t.max && !input.primitives.length) first = 0;
        const forcedEnd = first < input.endpoints.length && input.endpoints.length > 1
            ? cast(size_t) scratch.temporaryIds[first] : input.primitives.length;
        size_t greedyChoice = size_t.max;
        WrapSearchState greedyState;
        foreach (eIndex; first .. input.endpoints.length)
        {
            ref const endpoint = input.endpoints[eIndex];
            if (endpoint.end > forcedEnd) break;
            if (endpoint.tag == OpportunityTag.forbidden) continue;
            if (usage.transitions == limits.transitions) return budget(WrapBudgetKind.transitions, usage.transitions, limits.transitions);
            ++usage.transitions;
            const key = WrapCandidate(parent.next, eIndex, parent.geometryAlternative);
            WrapGeometry geometry;
            if (provider.geometry !is null)
            {
                r = provider.geometry(parent.next, endpoint, geometry);
                if (!r.succeeded) { r.phase = WrapPhase.geometry; r.candidate = eIndex; r.line = parent.objective.lines; return r; }
            }
            else
            {
                const sequence = geometries[parent.geometryAlternative];
                size_t index = parent.next.paragraphLine;
                if (index >= sequence.lines.length)
                {
                    if (!sequence.repeatLast) return WrapResult(status: WrapStatus.geometryExhausted,
                        phase: WrapPhase.geometry, line: index);
                    index = sequence.lines.length - 1;
                }
                geometry = sequence.lines[index];
            }
            if (geometry.capacity < 0 || geometry.startColumn < 0 || geometry.indentExtent < 0
                || geometry.mandatoryOverflow < 0 || !solverStorageAvoids(scratch, geometry.indent)) return invalid();
            foreach (ref const fragment; geometry.indent)
                if (!solverStorageAvoids(scratch, fragment.bytes) || !validSourceFragment(input, fragment)) return invalid();
            if (geometry.unbounded && endpoint.tag != OpportunityTag.forced && !endpoint.terminal) continue;
            WrapMeasurement m;
            if (usage.measurements == limits.measurements) return budget(WrapBudgetKind.measurements, usage.measurements, limits.measurements);
            ++usage.measurements;
            if (provider.measure !is null)
            {
                r = provider.measure(input, key, geometry, limits.providerWork - usage.providerWork, m);
                if (!r.succeeded) { r.phase = WrapPhase.measurement; r.candidate = eIndex; r.line = parent.objective.lines; return r; }
                if (m.work > limits.providerWork - usage.providerWork)
                    return budget(WrapBudgetKind.providerWork, usage.providerWork, limits.providerWork);
                usage.providerWork += m.work;
                if (!solverStorageAvoids(scratch, m.fragments) || !solverStorageAvoids(scratch, m.glues)) return invalid();
                foreach (ref const fragment; m.fragments)
                    if (!solverStorageAvoids(scratch, fragment.bytes)) return invalid();
            }
            else
            {
                size_t pieces;
                r = assemble(input, key, scratch.candidatePrimitives, pieces);
                if (!r.succeeded) return r;
                r = fixedMeasure(scratch.candidatePrimitives[0 .. pieces], scratch.candidateGlues, m);
                if (!r.succeeded) return r;
            }
            if (options.solver == WrapSolver.greedy && m.noFollowingFit
                && greedyChoice != size_t.max && !greedyState.overfull) break;
            if (!m.safeBreak) continue;
            long totalStretch, totalShrink;
            foreach (g, ref const glue; m.glues)
            {
                if (glue.natural < 0 || glue.stretch < 0 || glue.shrink < 0 || glue.shrink > glue.natural
                    || glue.minimum < 0 || glue.minimum > glue.natural || glue.maximum < glue.natural
                    || (g && glue.fragmentOrdinal <= m.glues[g - 1].fragmentOrdinal)) return invalid();
                if (glue.stretch > long.max - totalStretch || glue.shrink > long.max - totalShrink) return arithmetic();
                totalStretch += glue.stretch; totalShrink += glue.shrink;
            }
            if (totalStretch != m.stretch || totalShrink != m.shrink) return invalid();
            if (endpoint.paragraphEnd && (parent.next.paragraphLine + 1 < options.minimumLines
                || parent.next.paragraphLine + 1 > options.maximumLines)) continue;
            WrapSearchState state;
            state.predecessor = cursor; state.endpoint = eIndex;
            state.fixedProjection = provider.measure is null;
            state.geometryAlternative = parent.geometryAlternative;
            state.geometry = geometry; state.measurement = m;
            if (m.natural < 0 && input.dimension == WrapDimension.cells) continue;
            const overfullAllowed = m.allowOverfull
                || (endpoint.allowOverfull && legalOverfullUnit(input, key));
            r = costEdge(parent, endpoint, geometry, m, options, overfullAllowed, state, scratch.glueWidths);
            if (r.status == WrapStatus.noFeasiblePlan) continue;
            if (!r.succeeded) return r;
            state.next = WrapStartState(primitive: endpoint.end,
                paragraphLine: endpoint.paragraphEnd ? 0 : parent.next.paragraphLine + 1,
                totalLines: parent.next.totalLines + 1, previousEndpoint: eIndex,
                continuationId: endpoint.continuationId,
                providerState: provider.measure is null ? endpoint.providerState : m.nextProviderState,
                geometryState: geometry.nextState, previousFitness: state.fitness,
                previousFlagged: endpoint.flagged, hasPrevious: !endpoint.paragraphEnd);
            if (provider.measure is null) state.measurement.glues = null;
            if (options.solver == WrapSolver.greedy)
            {
                bool better = greedyChoice == size_t.max;
                if (!better)
                {
                    const old = input.endpoints[greedyChoice];
                    const oldRank = greedyState.overfull ? 2 : old.origin == OpportunityOrigin.emergency ? 1 : 0;
                    const rank = state.overfull ? 2 : endpoint.origin == OpportunityOrigin.emergency ? 1 : 0;
                    better = rank < oldRank || (rank == oldRank && (endpoint.sourceEnd > old.sourceEnd
                        || (endpoint.sourceEnd == old.sourceEnd && (endpoint.alternativeId < old.alternativeId
                            || (endpoint.alternativeId == old.alternativeId && eIndex < greedyChoice)))));
                }
                if (better) { greedyChoice = eIndex; greedyState = state; }
            }
            else
            {
                if (dominate)
                {
                    const bucket = futureHash(state) % scratch.ordering.length;
                    size_t equivalent = scratch.ordering[bucket];
                    while (equivalent != size_t.max)
                    {
                        ref old = scratch.states[equivalent];
                        if (!old.superseded && old.geometryAlternative == state.geometryAlternative
                            && old.next == state.next)
                        {
                            if (comparePrefix(input, scratch.states[0 .. n], old, state) <= 0) break;
                            // Only an unvisited label can be replaced in place:
                            // published descendants must retain their predecessor.
                            if (equivalent > cursor)
                            {
                                state.dominanceNext = old.dominanceNext;
                                old = state;
                                break;
                            }
                            old.superseded = true;
                        }
                        equivalent = old.dominanceNext;
                    }
                    if (equivalent != size_t.max) continue;
                    state.dominanceNext = scratch.ordering[bucket];
                    scratch.ordering[bucket] = n;
                }
                if (n == limits.states) return budget(WrapBudgetKind.states, n, limits.states);
                if (n == scratch.states.length) return scratchFailure();
                scratch.states[n++] = state;
            }
        }
        if (options.solver == WrapSolver.greedy && greedyChoice != size_t.max)
        {
            if (n == limits.states) return budget(WrapBudgetKind.states, n, limits.states);
            if (n == scratch.states.length) return scratchFailure();
            scratch.states[n++] = greedyState;
        }
    }
    if (scratch.ordering.length < n || scratch.temporary.length < n)
        return scratchFailure(n - (scratch.ordering.length < scratch.temporary.length
            ? scratch.ordering.length : scratch.temporary.length));
    size_t maximumDepth;
    foreach (ref const state; scratch.states[0 .. n])
        if (state.objective.lines > maximumDepth) maximumDepth = state.objective.lines;
    rankPrefixes(input, scratch.states[0 .. n], scratch.ordering, scratch.temporary, maximumDepth);
    size_t complete;
    foreach (i, ref const state; scratch.states[0 .. n])
        if (!state.superseded && state.endpoint != size_t.max && input.endpoints[state.endpoint].terminal)
            scratch.ordering[complete++] = i;
    sortCompletePaths(input, scratch.states[0 .. n], scratch.ordering[0 .. complete], scratch.temporary);
    count = complete < resultLimit ? complete : resultLimit;
    if (scratch.ranked.length < count) return scratchFailure(count - scratch.ranked.length);
    scratch.ranked[0 .. count] = scratch.ordering[0 .. count];
    usage.states = n;
    stateCount = n; resultCount = count; available = total;
    return WrapResult(status: WrapStatus.ok, exhaustive: total <= resultLimit, moreAlternatives: total > resultLimit);
}

private WrapResult validateStructuredFragments(scope const ref MeasurableInput input,
    scope const(WrapFragment)[] fragments, long expectedAdvance)
{
    LayoutUnit total;
    foreach (ref const fragment; fragments)
    {
        if (fragment.kind > FragmentKind.max || fragment.provenance > ProvenanceKind.max
            || fragment.reason > SyntheticReason.max || !validSourceFragment(input, fragment)) return invalid();
        if (checkedAdd(total, LayoutUnit(fragment.advance), total) != UnitStatus.ok) return arithmetic();
        if (fragment.provenance != ProvenanceKind.original) continue;
        const authored = input.source.bytes[fragment.sourceStart .. fragment.sourceEnd];
        if (fragment.kind == FragmentKind.bytes)
        {
            if (fragment.bytes != authored) return invalid();
        }
        else if (fragment.kind == FragmentKind.anchor)
        {
            if (authored.length) return invalid();
        }
        else
        {
            if (fragment.repeat != authored.length) return invalid();
            foreach (c; authored) if (c != ' ') return invalid();
        }
    }
    return total.raw == expectedAdvance ? WrapResult.init : invalid();
}

// Structured custom materializations must actually emit every ledger-owned
// original byte exactly once. Fixed objects and opaque provider handles retain
// their separately declared materialization contract.
private WrapResult validateStructuredSource(scope const ref WrapPlan plan,
    scope const(WrapSearchState)[] states, scope const(size_t)[] selected)
{
    size_t record, offset;
    void nextOriginal()
    {
        while (record < plan.sourceRecords.length
            && (plan.sourceRecords[record].end <= offset
                || plan.sourceRecords[record].kind != ProvenanceKind.original))
        {
            if (offset < plan.sourceRecords[record].end) offset = plan.sourceRecords[record].end;
            ++record;
        }
    }
    foreach (i, ref const line; plan.lines)
    {
        if (states[selected[i]].fixedProjection || line.opaqueMaterialization)
        {
            if (offset < line.sourceEnd) offset = line.sourceEnd;
            nextOriginal();
            continue;
        }
        foreach (ref const fragment; plan.fragments[line.fragmentsStart .. line.fragmentsEnd])
        {
            if (fragment.provenance != ProvenanceKind.original
                || fragment.sourceStart == fragment.sourceEnd) continue;
            nextOriginal();
            if (fragment.sourceStart != offset || fragment.sourceEnd > line.sourceEnd) return invalid();
            while (offset < fragment.sourceEnd)
            {
                if (record == plan.sourceRecords.length || plan.sourceRecords[record].start > offset
                    || plan.sourceRecords[record].kind != ProvenanceKind.original) return invalid();
                const end = plan.sourceRecords[record].end;
                offset = end < fragment.sourceEnd ? end : fragment.sourceEnd;
                if (offset == end && offset < fragment.sourceEnd)
                {
                    ++record;
                    if (record < plan.sourceRecords.length && plan.sourceRecords[record].start != offset) return invalid();
                }
            }
        }
        nextOriginal();
        if (record < plan.sourceRecords.length && offset < line.sourceEnd) return invalid();
    }
    nextOriginal();
    return record == plan.sourceRecords.length ? WrapResult.init : invalid();
}

private WrapResult project(const ref MeasurableInput input,
    WrapSolverOptions options, WrapSolverScratch scratch, size_t terminal,
    WrapUsage usage, ref WrapPlan plan)
{
    const count = scratch.states[terminal].objective.lines;
    if (scratch.selected.length < count || scratch.projection.lines.length < count) return scratchFailure(count);
    size_t cursor = terminal;
    foreach_reverse (i; 0 .. count) { scratch.selected[i] = cursor; cursor = scratch.states[cursor].predecessor; }
    size_t transforms;
    foreach (lineIndex; 0 .. count)
    {
        const state = scratch.states[scratch.selected[lineIndex]];
        const endpoint = input.endpoints[state.endpoint];
        foreach (ordinal; endpoint.contentEnd .. endpoint.end)
        {
            const p = input.primitives[ordinal];
            if (p.fragment.sourceStart == p.fragment.sourceEnd) continue;
            if (transforms == scratch.sourceTransforms.length) return scratchFailure();
            scratch.sourceTransforms[transforms++] = SourceRecord(p.fragment.sourceStart, p.fragment.sourceEnd,
                p.kind == PrimitiveKind.discretionary ? ProvenanceKind.replacement : ProvenanceKind.omission, ordinal);
        }
        if (endpoint.end && endpoint.contentEnd == endpoint.end
            && input.primitives[endpoint.end - 1].kind == PrimitiveKind.discretionary)
        {
            const p = input.primitives[endpoint.end - 1];
            if (p.fragment.sourceStart != p.fragment.sourceEnd)
            {
                if (transforms == scratch.sourceTransforms.length) return scratchFailure();
                scratch.sourceTransforms[transforms++] = SourceRecord(p.fragment.sourceStart,
                    p.fragment.sourceEnd, ProvenanceKind.replacement, endpoint.end - 1);
            }
        }
    }
    size_t fragments;
    size_t sourceStart;
    foreach (lineIndex; 0 .. count)
    {
        const state = scratch.states[scratch.selected[lineIndex]];
        const parent = scratch.states[state.predecessor];
        const endpoint = input.endpoints[state.endpoint];
        const begin = fragments;
        WrapResult append(WrapFragment fragment)
        {
            if (fragments == scratch.projection.fragments.length) return scratchFailure();
            scratch.projection.fragments[fragments++] = fragment;
            return WrapResult.init;
        }
        auto indentResult = validateStructuredFragments(input, state.geometry.indent, state.geometry.indentExtent);
        if (!indentResult.succeeded) return indentResult;
        foreach (fragment; state.geometry.indent)
        {
            auto r = append(fragment); if (!r.succeeded) return r;
        }
        WrapMeasurement m = state.measurement;
        size_t pieces;
        if (state.fixedProjection)
        {
            auto r = assemble(input, WrapCandidate(parent.next, state.endpoint, state.geometryAlternative), scratch.candidatePrimitives, pieces);
            if (!r.succeeded) return r;
            r = fixedMeasure(scratch.candidatePrimitives[0 .. pieces], scratch.candidateGlues, m);
            if (!r.succeeded) return r;
        }
        if (!state.fixedProjection)
        {
            if (m.opaqueMaterialization)
            {
                if (!m.materializationId || m.fragments.length) return invalid();
            }
            else
            {
                if (m.fragments.length > scratch.projection.fragments.length - fragments) return scratchFailure(m.fragments.length);
                auto r = validateStructuredFragments(input, m.fragments, m.natural);
                if (!r.succeeded) return r;
                foreach (ref const glue; m.glues)
                    if (glue.fragmentOrdinal >= m.fragments.length
                        || m.fragments[glue.fragmentOrdinal].advance != glue.natural) return invalid();
            }
        }
        if (options.solver == WrapSolver.knuthPlass)
        {
            const naturalOnly = state.overfull || (endpoint.paragraphEnd && options.terminal == TerminalAdjustment.ragged
                && m.natural <= state.geometry.capacity);
            auto r = realizeWrapGlue(m.glues, m.natural, state.geometry.capacity, state.ratio,
                options.stretchTolerance, scratch.glueWidths, naturalOnly);
            if (!r.succeeded) return r;
        }
        size_t g;
        const fragmentCount = state.fixedProjection ? pieces : m.fragments.length;
        foreach (i; 0 .. fragmentCount)
        {
            WrapFragment fragment = state.fixedProjection ? scratch.candidatePrimitives[i].fragment : m.fragments[i];
            if (state.fixedProjection)
            {
                fragment.itemId = scratch.candidatePrimitives[i].id;
                fragment.advance = scratch.candidatePrimitives[i].advance;
            }
            if (g < m.glues.length && m.glues[g].fragmentOrdinal == i)
            {
                const width = options.solver == WrapSolver.knuthPlass ? scratch.glueWidths[g] : m.glues[g].natural;
                fragment.advance = width;
                if (input.dimension == WrapDimension.cells
                    && (fragment.kind == FragmentKind.glue || fragment.kind == FragmentKind.spaces))
                    fragment.repeat = cast(ulong) width;
                ++g;
            }
            auto r = append(fragment); if (!r.succeeded) return r;
        }
        const justified = options.solver == WrapSolver.knuthPlass && !state.overfull
            && !(endpoint.paragraphEnd && options.terminal == TerminalAdjustment.ragged && m.natural <= state.geometry.capacity);
        const advance = justified ? state.geometry.capacity : m.natural;
        LayoutUnit endColumn;
        if (checkedAdd(LayoutUnit(state.geometry.startColumn), LayoutUnit(state.geometry.indentExtent), endColumn) != UnitStatus.ok
            || checkedAdd(endColumn, LayoutUnit(advance), endColumn) != UnitStatus.ok) return arithmetic();
        if (!m.opaqueMaterialization)
        {
            LayoutUnit emittedEnd = LayoutUnit(state.geometry.startColumn);
            foreach (ref const fragment; scratch.projection.fragments[begin .. fragments])
                if (checkedAdd(emittedEnd, LayoutUnit(fragment.advance), emittedEnd) != UnitStatus.ok) return arithmetic();
            if (emittedEnd != endColumn) return invalid();
        }
        scratch.projection.lines[lineIndex] = WrapLine(fragmentsStart: begin, fragmentsEnd: fragments,
            sourceStart: sourceStart, sourceEnd: endpoint.sourceEnd, endpointOrdinal: state.endpoint,
            alternativeId: endpoint.alternativeId, geometryId: state.geometry.id,
            continuationId: endpoint.continuationId, providerState: state.next.providerState,
            paragraphLine: parent.next.paragraphLine, startColumn: state.geometry.startColumn,
            indentExtent: state.geometry.indentExtent, contentAdvance: advance, endColumn: endColumn.raw,
            capacity: state.geometry.capacity, unbounded: state.geometry.unbounded,
            overfull: state.overfull, emergency: endpoint.origin == OpportunityOrigin.emergency,
            paragraphEnd: endpoint.paragraphEnd, adjustment: state.ratio, fitness: state.fitness,
            visualMap: m.visualMap, materializationId: m.materializationId,
            opaqueMaterialization: m.opaqueMaterialization,
            startStyle: begin < fragments ? scratch.projection.fragments[begin].styleBefore : 0,
            endStyle: begin < fragments ? scratch.projection.fragments[fragments - 1].styleAfter : 0);
        sourceStart = endpoint.sourceEnd;
    }
    size_t recordCount, transformation;
    foreach (ref const authored; input.sourceRecords)
    {
        size_t position = authored.start;
        do
        {
            while (transformation < transforms && scratch.sourceTransforms[transformation].end <= position) ++transformation;
            SourceRecord record = authored;
            record.start = position;
            if (transformation < transforms)
            {
                const replacement = scratch.sourceTransforms[transformation];
                if (replacement.start > position)
                    record.end = replacement.start < authored.end ? replacement.start : authored.end;
                else
                {
                    record.end = replacement.end < authored.end ? replacement.end : authored.end;
                    record.kind = replacement.kind;
                }
            }
            if (recordCount == scratch.projection.sourceRecords.length) return scratchFailure();
            scratch.projection.sourceRecords[recordCount++] = record;
            position = record.end;
        } while (position < authored.end);
    }
    if (fragments > size_t.max - count || recordCount > size_t.max - fragments - count) return arithmetic();
    usage.outputRecords = fragments + count + recordCount;
    plan = WrapPlan(source: input.source, lines: scratch.projection.lines[0 .. count],
        fragments: scratch.projection.fragments[0 .. fragments],
        sourceRecords: scratch.projection.sourceRecords[0 .. recordCount],
        proof: options.solver == WrapSolver.greedy ? WrapProof.localGreedy : WrapProof.completeExact,
        solver: options.solver, dimension: input.dimension, objective: scratch.states[terminal].objective,
        usage: usage, resourceRevision: input.resourceRevision,
        stretchTolerance: options.stretchTolerance, linePenalty: options.linePenalty,
        fitnessDemerit: options.fitnessDemerit,
        consecutiveDiscretionaryDemerit: options.consecutiveDiscretionaryDemerit,
        terminalDiscretionaryDemerit: options.terminalDiscretionaryDemerit,
        minimumLines: options.minimumLines, maximumLines: options.maximumLines,
        justifiedTerminal: options.terminal == TerminalAdjustment.justified,
        geometryAlternative: scratch.states[terminal].geometryAlternative);
    return validateStructuredSource(plan, scratch.states, scratch.selected[0 .. count]);
}
/// Structural validation seam for semantic adapters. Uses the same validator as
/// solving, never geometry/measurement callbacks. Only ids/temporaryIds arenas
/// need entries (max(primitives.length,endpoints.length)); other arenas may be
/// empty. Supplied immutable snapshots and scratch still must be disjoint.
WrapResult tryValidateWrapInput(const ref MeasurableInput supplied,
    WrapSolverScratch scratch, WrapLimits limits)
{
    if (!solverStorageAvoids(scratch, utfObjectStorage(supplied))) return invalid();
    MeasurableInput input = normalizedInput(supplied);
    return validate(input, null, WrapProvider.init, WrapSolverOptions.init, limits, scratch, true);
}

/// Selection-only seam for cell adapters. Results remain scratch labels, not
/// published plans; projection is independent of selection and must stage all
/// fallible work before publication.
WrapResult selectWrapPaths(const ref MeasurableInput supplied,
    scope const(WrapGeometrySequence)[] geometries, scope WrapProvider provider,
    WrapSolverOptions options, WrapLimits limits, WrapSolverScratch scratch,
    size_t resultLimit, bool exhaustive, ref size_t stateCount,
    ref size_t resultCount, ref size_t available, ref WrapUsage usage)
{
    if (!solverStorageAvoids(scratch, utfObjectStorage(supplied))) return invalid();
    MeasurableInput input = normalizedInput(supplied);
    return search(input, geometries, provider, options, limits, scratch,
        resultLimit, exhaustive, stateCount, resultCount, available, usage);
}

// Internal single-plan adapter: it does not promise ranked path enumeration.
package WrapResult selectBestWrapPath(const ref MeasurableInput supplied,
    scope const(WrapGeometrySequence)[] geometries, scope WrapProvider provider,
    WrapSolverOptions options, WrapLimits limits, WrapSolverScratch scratch,
    ref size_t stateCount, ref size_t resultCount, ref WrapUsage usage)
{
    if (!solverStorageAvoids(scratch, utfObjectStorage(supplied))) return invalid();
    MeasurableInput input = normalizedInput(supplied);
    size_t available;
    return search(input, geometries, provider, options, limits, scratch,
        1, false, stateCount, resultCount, available, usage, true);
}


WrapResult trySolveWrap(const ref MeasurableInput supplied, WrapGeometrySequence geometry,
    scope WrapProvider provider, WrapSolverOptions options, WrapLimits limits,
    WrapSolverScratch scratch, WrapPlanStorage storage, ref WrapPlan outPlan)
{
    MeasurableInput input = normalizedInput(supplied);
    WrapGeometrySequence[1] geometries = [geometry];
    if (!solverStorageDisjoint(scratch, storage, outPlan)
        || !solverStorageAvoids(scratch, utfObjectStorage(supplied))
        || !wrapStorageAvoids(utfObjectStorage(supplied), storage.lines, storage.fragments, storage.sourceRecords, storage.styles)
        || !inputStorageAvoids(input, geometries[], storage.lines, storage.fragments, storage.sourceRecords, storage.styles,
            utfObjectStorage(outPlan)))
        return invalid();
    size_t stateCount, resultCount, available;
    WrapUsage usage;
    auto r = search(input, geometries[], provider, options, limits, scratch, 1, false,
        stateCount, resultCount, available, usage, true);
    if (!r.succeeded) return r;
    if (!measuredStorageAvoids(scratch.states[0 .. stateCount],
        storage.lines, storage.fragments, storage.sourceRecords, storage.styles, utfObjectStorage(outPlan))) return invalid();
    if (!resultCount) return WrapResult(status: WrapStatus.noFeasiblePlan, phase: WrapPhase.selection);
    WrapPlan prepared;
    r = project(input, options, scratch, scratch.ranked[0], usage, prepared);
    if (!r.succeeded) return r;
    if (prepared.usage.outputRecords > limits.outputRecords)
        return budget(WrapBudgetKind.outputRecords, prepared.usage.outputRecords, limits.outputRecords);
    return publishWrapPlan(prepared, scratch.projection, storage, outPlan);
}

/// Every prefix remains a distinct label, including equal-cost paths. Result
/// storage is a single disjoint arena partitioned only after all plans validate.
WrapResult trySolveWrapAlternatives(const ref MeasurableInput supplied,
    scope const(WrapGeometrySequence)[] geometries, scope WrapProvider provider,
    WrapSolverOptions options, WrapLimits limits, size_t maximumResults, bool exhaustive,
    WrapSolverScratch scratch, WrapPlan[] preparedPlans,
    WrapAlternativeStorage storage, ref WrapAlternativePlans outPlans)
{
    MeasurableInput input = normalizedInput(supplied);
    if (!maximumResults || options.solver == WrapSolver.greedy) return invalid();
    WrapPlan empty;
    if (!solverStorageDisjoint(scratch, storage.metadata, empty)
        || !solverStorageAvoids(scratch, preparedPlans) || !solverStorageAvoids(scratch, storage.plans)
        || !solverStorageAvoids(scratch, utfObjectStorage(supplied))
        || !solverStorageAvoids(scratch, utfObjectStorage(outPlans))
        || !wrapStorageAvoids(utfObjectStorage(supplied), preparedPlans, storage.plans,
            storage.metadata.lines, storage.metadata.fragments, storage.metadata.sourceRecords, storage.metadata.styles)
        || !wrapStorageDisjoint(preparedPlans, storage.plans, storage.metadata.lines,
            storage.metadata.fragments, storage.metadata.sourceRecords, storage.metadata.styles, utfObjectStorage(outPlans))
        || !wrapStorageAvoids(outPlans.plans, preparedPlans, storage.plans, storage.metadata.lines,
            storage.metadata.fragments, storage.metadata.sourceRecords, storage.metadata.styles)
        || !inputStorageAvoids(input, geometries, preparedPlans, storage.plans,
            storage.metadata.lines, storage.metadata.fragments, storage.metadata.sourceRecords, storage.metadata.styles,
            utfObjectStorage(outPlans))) return invalid();
    foreach (ref const old; outPlans.plans)
        if (!solverStorageDisjoint(scratch, storage.metadata, old)
            || !wrapPlanAvoids(old, preparedPlans, storage.plans, utfObjectStorage(outPlans))) return invalid();
    size_t n, count, available;
    WrapUsage usage;
    auto r = search(input, geometries, provider, options, limits, scratch, maximumResults, exhaustive,
        n, count, available, usage);
    if (!r.succeeded) return r;
    if (!measuredStorageAvoids(scratch.states[0 .. n], preparedPlans, storage.plans,
        storage.metadata.lines, storage.metadata.fragments, storage.metadata.sourceRecords, storage.metadata.styles,
        utfObjectStorage(outPlans))) return invalid();
    if (count > preparedPlans.length || count > storage.plans.length)
        return WrapResult(status: WrapStatus.needResults, required: count);
    // Each selected projection occupies its own scratch partition. No callback
    // or search runs during publication.
    auto arena = scratch.projection;
    size_t lineCount, fragmentCount, recordCount;
    foreach (i; 0 .. count)
    {
        auto local = scratch;
        local.projection = WrapProjectionScratch(arena.lines[lineCount .. $],
            arena.fragments[fragmentCount .. $], arena.sourceRecords[recordCount .. $]);
        r = project(input, options, local, scratch.ranked[i], usage, preparedPlans[i]);
        if (!r.succeeded) return r;
        lineCount += preparedPlans[i].lines.length;
        fragmentCount += preparedPlans[i].fragments.length;
        recordCount += preparedPlans[i].sourceRecords.length;
    }
    if (lineCount > size_t.max - fragmentCount || recordCount > size_t.max - lineCount - fragmentCount) return arithmetic();
    if (lineCount + fragmentCount + recordCount > limits.outputRecords)
        return budget(WrapBudgetKind.outputRecords, lineCount + fragmentCount + recordCount, limits.outputRecords);
    if (storage.metadata.lines.length < lineCount || storage.metadata.fragments.length < fragmentCount
        || storage.metadata.sourceRecords.length < recordCount)
        return WrapResult(status: WrapStatus.needPlanStorage, required: lineCount + fragmentCount + recordCount);
    // Validate all alias/lifetime constraints without committing any arena.
    if (utfStorageOverlaps(storage.metadata.lines, arena.lines)
        || utfStorageOverlaps(storage.metadata.lines, arena.fragments)
        || utfStorageOverlaps(storage.metadata.lines, arena.sourceRecords)
        || utfStorageOverlaps(storage.metadata.fragments, arena.lines)
        || utfStorageOverlaps(storage.metadata.fragments, arena.fragments)
        || utfStorageOverlaps(storage.metadata.fragments, arena.sourceRecords)
        || utfStorageOverlaps(storage.metadata.sourceRecords, arena.lines)
        || utfStorageOverlaps(storage.metadata.sourceRecords, arena.fragments)
        || utfStorageOverlaps(storage.metadata.sourceRecords, arena.sourceRecords)
        || utfStorageOverlaps(storage.metadata.lines, input.source.bytes)
        || utfStorageOverlaps(storage.metadata.fragments, input.source.bytes)
        || utfStorageOverlaps(storage.metadata.sourceRecords, input.source.bytes)) return invalid();
    foreach (ref const plan; preparedPlans[0 .. count]) foreach (ref const fragment; plan.fragments)
        if (utfStorageOverlaps(storage.metadata.lines, fragment.bytes)
            || utfStorageOverlaps(storage.metadata.fragments, fragment.bytes)
            || utfStorageOverlaps(storage.metadata.sourceRecords, fragment.bytes)) return invalid();
    storage.metadata.lines[0 .. lineCount] = arena.lines[0 .. lineCount];
    storage.metadata.fragments[0 .. fragmentCount] = arena.fragments[0 .. fragmentCount];
    storage.metadata.sourceRecords[0 .. recordCount] = arena.sourceRecords[0 .. recordCount];
    lineCount = 0; fragmentCount = 0; recordCount = 0;
    foreach (i; 0 .. count)
    {
        auto plan = preparedPlans[i];
        plan.lines = storage.metadata.lines[lineCount .. lineCount + plan.lines.length];
        plan.fragments = storage.metadata.fragments[fragmentCount .. fragmentCount + plan.fragments.length];
        plan.sourceRecords = storage.metadata.sourceRecords[recordCount .. recordCount + plan.sourceRecords.length];
        lineCount += plan.lines.length; fragmentCount += plan.fragments.length; recordCount += plan.sourceRecords.length;
        storage.plans[i] = plan;
    }
    outPlans = WrapAlternativePlans(storage.plans[0 .. count], available <= maximumResults, available > maximumResults);
    return WrapResult(status: WrapStatus.ok, exhaustive: outPlans.exhaustive, moreAlternatives: outPlans.moreAlternatives);
}
