/** Owned Unicode cell wrapping. Plans precede strings; allocated adapters are explicit. */
module sparkles.base.text.wrap;

public import sparkles.base.text.wrap_plan;
public import sparkles.base.text.layout_units : CellExtent, LayoutUnit;
import sparkles.base.text.wrap_solver;
import sparkles.base.text.layout_units : UnitStatus, checkedAdd;
import sparkles.base.text.utf : UtfToken, UtfTokenKind, UtfMode, UtfStatus, decodeToken, utfStorageOverlaps;
import sparkles.base.text.grapheme : GraphemeBreakState;
import sparkles.base.text.width : ClusterWidthState, CellPolicy, terminalKittyRevision;
import sparkles.base.text.line_break : lineOpportunities, LineBreakWorkspaceEntry;
import sparkles.base.text.boundaries : wordBoundaries, WordBoundaryWorkspace;
import sparkles.base.text.unicode_algorithm : UnicodeBoundary, UnicodeBoundaryKind;
import sparkles.base.text.unicode_tables : unicodeManifestIdentity, lineBreakClass, LineBreakClass;
import sparkles.base.text.wrap_cells_project : realizeCellProjection, RealizedCellProjection, CellProjectionStyles;

/// Zero is a genuine bounded capacity; unbounded is an independent tag.
struct CellWidth
{
    CellExtent extent;
    bool isUnbounded;
    static CellWidth bounded(ulong cells) @safe pure nothrow @nogc => CellWidth(CellExtent(cells), false);
    static CellWidth unbounded() @safe pure nothrow @nogc => CellWidth(CellExtent.init, true);
}
enum WhitespaceMode : ubyte { preserve, collapse, trimAroundBreak }
enum CellOpportunityPolicy : ubyte { unicode, wordPreserving }
enum CellOverflowPolicy : ubyte { reject, overflowUnit, graphemeEmergency }
enum StyleContinuity : ubyte { copyThrough, suspendResume }
enum FinalStylePolicy : ubyte { preserveFinalState, restoreInitialState }
enum FormattingPolicy : ubyte { rejectUnknown, opaqueCopyThrough, literal }
enum TabPolicy : ubyte { preserve, expand }
struct CellTabStops
{
    CellExtent interval = CellExtent(8);
    const(CellExtent)[] explicitStops;
    bool periodicTail = true;
}
struct CellNoBreakSpan { size_t start, end; }
struct CellGeometry
{
    CellWidth width;
    CellExtent startColumn;
    const(char)[] indent;
    ulong id;
}
struct CellFormattingEvent { size_t start, end; const(char)[] bytes; }
struct CellStyleProvider
{
    WrapResult delegate(CellStyleSnapshot, CellFormattingEvent, size_t remainingWork,
        ref CellStyleSnapshot, ref const(char)[] emission, ref size_t work) @safe nothrow @nogc transition;
}
struct WrapOptions
{
    CellWidth width = CellWidth.unbounded;
    const(char)[] indent, firstIndent;
    CellExtent startColumn;
    const(CellGeometry)[] geometry;
    bool repeatLastGeometry;
    WhitespaceMode whitespace;
    CellOpportunityPolicy opportunities;
    CellOverflowPolicy overflow = CellOverflowPolicy.graphemeEmergency;
    WrapSolver solver = WrapSolver.greedy;
    UtfMode malformed = UtfMode.replacement;
    StyleContinuity continuity = StyleContinuity.suspendResume;
    FinalStylePolicy finalStyle = FinalStylePolicy.preserveFinalState;
    FormattingPolicy formatting;
    TabPolicy tabs = TabPolicy.preserve;
    CellTabStops tabStops;
    const(CellNoBreakSpan)[] noBreak;
    CellStyleSnapshot initialStyle;
    CellStyleSnapshot indentStyle;
    CellStyleProvider styleProvider;
    bool emitSoftHyphenGlyph = true;
    /// Optional exact target extent for selection only. Unicode candidates and
    /// published fragment advances remain owned terminal cells. A provider may
    /// return needResults to request measurement outside the @nogc solver.
    WrapResult delegate(scope const(WrapFragment)[], scope const(CellStyleSnapshot)[], ref long)
        @safe nothrow @nogc selectionMeasure;
    /// Opt-in for a deterministic selectionMeasure whose realized prefixes have
    /// non-decreasing extent. Arbitrary target callbacks remain uncertified.
    bool selectionMeasureMonotone;
}

struct CellAtom
{
    size_t start, end, tokenIndex, styleBefore, styleAfter;
    bool formatting;
    const(char)[] emission;
    UtfToken token;
}
struct CellCluster
{
    size_t start, end, atomStart, atomEnd, tokenStart, tokenEnd;
    size_t styleStart, styleEnd, unitStart, unitEnd;
    /// Cumulative emitted byte-work bound at this cluster's end.
    size_t workEnd;
    long width;
    dchar first;
    bool whitespace, tab, separator, softHyphen, protectedUnit, ordinaryEnd, forcedEnd;
}
/// Bounds are record counts, never a per-cluster scalar limit.
struct CellWrapScratch
{
    UtfToken[] tokens;
    CellAtom[] atoms;
    CellCluster[] clusters;
    CellStyleSnapshot[] styles;
    UnicodeBoundary[] opportunities, words;
    LineBreakWorkspaceEntry[] lineWorkspace;
    WordBoundaryWorkspace[] wordWorkspace;
    WrapPrimitive[] primitives;
    WrapEndpoint[] endpoints;
    SourceRecord[] sourceRecords;
    WrapGeometry[] geometry;
    CellStyleSnapshot[] indentStyles;
    /// One base ordinal per geometry; native indent transitions follow contiguously.
    size_t[] indentStyleStarts;
    /// Two ordinal caches per fixed snapshot: inherited indent events and OSC closes.
    size_t[] styleTransitions;
    WrapFragment[] candidateFragments, realizedFragments;
    WrapSolverScratch solver;
}
private WrapResult invalidCell(size_t start = 0, size_t end = 0) @safe nothrow @nogc
    => WrapResult(status: WrapStatus.invalidInput, phase: WrapPhase.validation, sourceStart: start, sourceEnd: end);
private WrapResult cellScratch(size_t n = 1) @safe nothrow @nogc
    => WrapResult(status: WrapStatus.needScratch, phase: WrapPhase.scan, required: n);
private WrapResult cellArithmetic() @safe nothrow @nogc
    => WrapResult(status: WrapStatus.arithmeticExhausted);

private WrapResult checkedCellAdd(long a, long b, ref long sum) @safe nothrow @nogc
{
    LayoutUnit outValue;
    if (checkedAdd(LayoutUnit(a), LayoutUnit(b), outValue) != UnitStatus.ok) return cellArithmetic();
    sum = outValue.raw;
    return WrapResult.init;
}
private bool cellStorageAvoids(T)(CellWrapScratch scratch, scope const(T)[] borrowed) @safe nothrow @nogc
{
    return wrapStorageAvoids(borrowed, scratch.tokens, scratch.atoms, scratch.clusters,
        scratch.styles, scratch.opportunities, scratch.words, scratch.lineWorkspace,
        scratch.wordWorkspace, scratch.primitives, scratch.endpoints, scratch.sourceRecords,
        scratch.geometry, scratch.indentStyles, scratch.indentStyleStarts, scratch.styleTransitions,
        scratch.candidateFragments, scratch.realizedFragments)
        && solverStorageAvoids(scratch.solver, borrowed);
}
private bool cellStorageDisjoint(CellWrapScratch scratch, WrapPlanStorage storage,
    scope const ref WrapPlan previous) @safe nothrow @nogc
{
    const solver = scratch.solver;
    if (!wrapStorageDisjoint(scratch.tokens, scratch.atoms, scratch.clusters,
        scratch.styles, scratch.opportunities, scratch.words, scratch.lineWorkspace,
        scratch.wordWorkspace, scratch.primitives, scratch.endpoints, scratch.sourceRecords,
        scratch.geometry, scratch.indentStyles, scratch.indentStyleStarts, scratch.styleTransitions,
        scratch.candidateFragments, scratch.realizedFragments,
        solver.states, solver.selected, solver.ranked, solver.ordering, solver.temporary,
        solver.ids, solver.temporaryIds, solver.candidatePrimitives, solver.candidateGlues,
        solver.glueWidths, solver.sourceTransforms, solver.projection.lines, solver.projection.fragments,
        solver.projection.sourceRecords, solver.projection.styles, storage.lines, storage.fragments,
        storage.sourceRecords, storage.styles)) return false;
    return wrapPlanAvoids(previous, scratch.tokens, scratch.atoms, scratch.clusters,
        scratch.styles, scratch.opportunities, scratch.words, scratch.lineWorkspace,
        scratch.wordWorkspace, scratch.primitives, scratch.endpoints, scratch.sourceRecords,
        scratch.geometry, scratch.indentStyles, scratch.indentStyleStarts, scratch.styleTransitions,
        scratch.candidateFragments, scratch.realizedFragments,
        solver.states, solver.selected, solver.ranked, solver.ordering, solver.temporary,
        solver.ids, solver.temporaryIds, solver.candidatePrimitives, solver.candidateGlues,
        solver.glueWidths, solver.sourceTransforms, solver.projection.lines, solver.projection.fragments,
        solver.projection.sourceRecords, solver.projection.styles,
        storage.lines, storage.fragments, storage.sourceRecords, storage.styles);
}

private bool cellBytesAvoids(CellWrapScratch scratch, WrapPlanStorage storage,
    scope const(char)[] bytes) @safe nothrow @nogc
    => cellStorageAvoids(scratch, bytes)
        && wrapStorageAvoids(bytes, storage.lines, storage.fragments, storage.sourceRecords, storage.styles);

private bool cellStyleAvoids(CellWrapScratch scratch, WrapPlanStorage storage,
    CellStyleSnapshot style) @safe nothrow @nogc
{
    const(char)[][5] spans = [style.foreground, style.background, style.underlineColor,
        style.linkOpen, style.customRestore];
    foreach (span; spans) if (!cellBytesAvoids(scratch, storage, span)) return false;
    return true;
}

private bool cellOptionsAvoid(CellWrapScratch scratch, WrapPlanStorage storage,
    WrapOptions options) @safe nothrow @nogc
{
    if (!cellStorageAvoids(scratch, options.noBreak) || !cellStorageAvoids(scratch, options.geometry)
        || !cellStorageAvoids(scratch, options.tabStops.explicitStops)
        || !wrapStorageAvoids(options.noBreak, storage.lines, storage.fragments, storage.sourceRecords, storage.styles)
        || !wrapStorageAvoids(options.geometry, storage.lines, storage.fragments, storage.sourceRecords, storage.styles)
        || !wrapStorageAvoids(options.tabStops.explicitStops, storage.lines, storage.fragments, storage.sourceRecords, storage.styles)
        || !cellBytesAvoids(scratch, storage, options.firstIndent)
        || !cellBytesAvoids(scratch, storage, options.indent)
        || !cellStyleAvoids(scratch, storage, options.initialStyle)
        || !cellStyleAvoids(scratch, storage, options.indentStyle)) return false;
    foreach (ref const geometry; options.geometry)
        if (!cellBytesAvoids(scratch, storage, geometry.indent)) return false;
    return true;
}

private bool mandatoryScalar(dchar cp) @safe pure nothrow @nogc
{
    const c = lineBreakClass(cp);
    return c == LineBreakClass.BK || c == LineBreakClass.CR || c == LineBreakClass.LF || c == LineBreakClass.NL;
}
private bool protectedScalar(dchar cp) @safe pure nothrow @nogc
{
    const c = lineBreakClass(cp);
    return c == LineBreakClass.GL || c == LineBreakClass.WJ;
}

package WrapResult parseFormatting(const(char)[] source, size_t offset,
    FormattingPolicy policy, StyleContinuity continuity, CellStyleSnapshot before,
    ref CellStyleSnapshot after, ref size_t consumed) @safe nothrow @nogc
{
    WrapResult malformed() => WrapResult(status: WrapStatus.invalidFormatting,
        phase: WrapPhase.scan, sourceStart: offset, sourceEnd: source.length);
    if (source.length - offset < 2) return malformed();
    const start = offset;
    CellStyleSnapshot state = before;
    if (source[offset + 1] == '[')
    {
        size_t end = offset + 2;
        while (end < source.length && source[end] >= 0x20 && source[end] <= 0x3F) ++end;
        if (end == source.length) return malformed();
        if (source[end] != 'm')
            return WrapResult(status: WrapStatus.nonTextTerminalOperation, phase: WrapPhase.scan,
                sourceStart: start, sourceEnd: end + 1);
        const params = source[offset + 2 .. end];
        foreach (char c; params) if ((c < '0' || c > '9') && c != ';' && c != ':') return malformed();
        size_t cursor;
        do
        {
            const pStart = cursor;
            uint code;
            while (cursor < params.length && params[cursor] >= '0' && params[cursor] <= '9')
            {
                if (code > 6553) return malformed();
                code = code * 10 + params[cursor++] - '0';
            }
            bool colon = cursor < params.length && params[cursor] == ':';
            if (colon)
            {
                if (code == 4)
                {
                    ++cursor;
                    if (cursor == params.length || params[cursor] < '0' || params[cursor] > '5') return malformed();
                    state.underline = cast(CellUnderlineStyle)(params[cursor++] - '0');
                    if (cursor < params.length && params[cursor] != ';') return malformed();
                }
                else
                {
                    while (cursor < params.length && params[cursor] != ';') ++cursor;
                    if (code != 38 && code != 48 && code != 58) return malformed();
                }
            }
            if (code == 38 || code == 48 || code == 58)
            {
                if (!colon)
                {
                    if (cursor == params.length || params[cursor++] != ';') return malformed();
                    uint selector;
                    while (cursor < params.length && params[cursor] >= '0' && params[cursor] <= '9')
                    {
                        if (selector > 255) return malformed();
                        selector = selector * 10 + params[cursor++] - '0';
                    }
                    const extra = selector == 5 ? 1 : selector == 2 ? 3 : 0;
                    if (!extra) return malformed();
                    foreach (_; 0 .. extra)
                    {
                        if (cursor == params.length || params[cursor++] != ';') return malformed();
                        uint component;
                        const componentStart = cursor;
                        while (cursor < params.length && params[cursor] >= '0' && params[cursor] <= '9')
                        {
                            if (component > 255) return malformed();
                            component = component * 10 + params[cursor++] - '0';
                        }
                        if (cursor == componentStart || component > 255) return malformed();
                    }
                }
                const color = params[pStart .. cursor];
                if (code == 38) state.foreground = color;
                else if (code == 48) state.background = color;
                else state.underlineColor = color;
            }
            else if (code == 0)
            {
                const id = state.id;
                const link = state.linkOpen;
                state = CellStyleSnapshot.init;
                state.id = id;
                state.linkOpen = link;
            }
            else if (code == 4)
            {
                if (!colon) state.underline = CellUnderlineStyle.single;
            }
            else if (code == 21) state.underline = CellUnderlineStyle.doubleLine;
            else if (code == 24) state.underline = CellUnderlineStyle.none;
            else if (code >= 1 && code <= 9) state.attributes |= cast(ushort)(1U << (code - 1));
            else if (code == 22) state.attributes &= ~cast(ushort) 3;
            else if (code >= 23 && code <= 29) state.attributes &= ~cast(ushort)(1U << (code - 21));
            else if ((code >= 30 && code <= 37) || (code >= 90 && code <= 97)) state.foreground = params[pStart .. cursor];
            else if ((code >= 40 && code <= 47) || (code >= 100 && code <= 107)) state.background = params[pStart .. cursor];
            else if (code == 39) state.foreground = null;
            else if (code == 49) state.background = null;
            else if (code == 59) state.underlineColor = null;
            // SGR 10 selects the primary font, the only supported font state.
            // Preserve its source bytes without changing unrelated attributes.
            else if (code != 10)
            {
                if (policy != FormattingPolicy.opaqueCopyThrough || continuity != StyleContinuity.copyThrough)
                    return WrapResult(status: WrapStatus.unsupportedCapability, phase: WrapPhase.scan,
                        sourceStart: start, sourceEnd: end + 1);
                state.opaque = true;
            }
            if (cursor < params.length && params[cursor] != ';') return malformed();
            if (cursor == params.length) break;
            ++cursor;
        } while (cursor <= params.length);
        consumed = end + 1 - start;
    }
    else if (source[offset + 1] == ']')
    {
        size_t end = offset + 2;
        while (end < source.length && source[end] != '\x07'
            && !(source[end] == '\x1B' && end + 1 < source.length && source[end + 1] == '\\')) ++end;
        if (end == source.length) return malformed();
        const sequenceEnd = end + (source[end] == '\x07' ? 1 : 2);
        if (end - offset < 4 || source[offset + 2] != '8' || source[offset + 3] != ';')
            return WrapResult(status: WrapStatus.nonTextTerminalOperation, phase: WrapPhase.scan,
                sourceStart: offset, sourceEnd: sequenceEnd);
        size_t uri = offset + 4;
        while (uri < end && source[uri] != ';') ++uri;
        if (uri == end) return malformed();
        state.linkOpen = uri + 1 == end ? null : source[offset .. sequenceEnd];
        consumed = sequenceEnd - offset;
    }
    else
        return WrapResult(status: WrapStatus.nonTextTerminalOperation, phase: WrapPhase.scan,
            sourceStart: offset, sourceEnd: offset + 2);
    after = state;
    return WrapResult.init;
}

private WrapResult validateCellOptions(WrapOptions options) @safe nothrow @nogc
{
    if (options.solver == WrapSolver.knuthPlass) return WrapResult(status: WrapStatus.unsupportedCapability);
    if (options.width.extent.value > long.max || options.startColumn.value > long.max
        || options.tabStops.interval.value > long.max) return cellArithmetic();
    if (options.tabStops.periodicTail && !options.tabStops.interval.value) return invalidCell();
    foreach (i, stop; options.tabStops.explicitStops)
        if (stop.value > long.max || (i && stop.value <= options.tabStops.explicitStops[i - 1].value)) return invalidCell();
    foreach (ref const g; options.geometry)
        if (g.width.extent.value > long.max || g.startColumn.value > long.max) return cellArithmetic();
    foreach (i, span; options.noBreak)
        if (span.start > span.end || (i && span.start < options.noBreak[i - 1].end)) return invalidCell(span.start, span.end);
    return WrapResult.init;
}

private WrapResult validateRestore(CellStyleSnapshot style, WrapOptions options,
    WrapLimits limits, ref size_t work) @safe nothrow @nogc
{
    const bytes = style.customRestore;
    if (bytes.length > limits.providerWork - work)
        return WrapResult(status: WrapStatus.budgetExhausted, kind: WrapBudgetKind.providerWork,
            used: work, limit: limits.providerWork, required: bytes.length, phase: WrapPhase.scan);
    size_t cursor;
    CellStyleSnapshot state;
    while (cursor < bytes.length)
    {
        if (bytes[cursor] != '\x1B') return WrapResult(status: WrapStatus.invalidFormatting,
            phase: WrapPhase.scan, sourceStart: cursor, sourceEnd: cursor + 1);
        CellStyleSnapshot after;
        size_t consumed;
        auto r = parseFormatting(bytes, cursor, options.formatting, options.continuity, state, after, consumed);
        if (!r.succeeded) return r;
        state = after; cursor += consumed;
    }
    work += bytes.length;
    return WrapResult.init;
}

private WrapResult scanCells(SourceSnapshot source, WrapOptions options, WrapLimits limits,
    CellWrapScratch scratch, ref size_t atomCount, ref size_t tokenCount,
    ref size_t clusterCount, ref size_t styleCount, ref size_t styleWork,
    WrapPlanStorage storage = WrapPlanStorage.init) @safe nothrow @nogc
{
    auto result = validateCellOptions(options);
    WrapPlan emptyPlan;
    WrapPlanStorage noOutput;
    if (!cellStorageDisjoint(scratch, noOutput, emptyPlan) || !cellStorageAvoids(scratch, source.bytes))
        return invalidCell();
    if (!result.succeeded) return result;
    if (!cellOptionsAvoid(scratch, storage, options)) return invalidCell();
    if (source.bytes.length > limits.sourceBytes)
        return WrapResult(status: WrapStatus.budgetExhausted, kind: WrapBudgetKind.sourceBytes,
            used: source.bytes.length, limit: limits.sourceBytes, phase: WrapPhase.scan);
    if (!limits.inputRecords) return WrapResult(status: WrapStatus.budgetExhausted,
        kind: WrapBudgetKind.inputRecords, limit: 0, required: 1, phase: WrapPhase.scan);
    if (!scratch.styles.length) return cellScratch();
    result = validateRestore(options.initialStyle, options, limits, styleWork);
    if (!result.succeeded) return result;
    if (options.indentStyle.customRestore !is options.initialStyle.customRestore)
    {
        auto indentOptions = options;
        indentOptions.formatting = FormattingPolicy.rejectUnknown;
        indentOptions.continuity = StyleContinuity.suspendResume;
        result = validateRestore(options.indentStyle, indentOptions, limits, styleWork);
        if (!result.succeeded) return result;
    }
    scratch.styles[0] = options.initialStyle;
    size_t atoms, tokens, clusters, styles = 1, offset;
    size_t liveStyle;
    GraphemeBreakState breaks;
    ClusterWidthState width;
    CellCluster cluster;
    bool haveCluster, previousOpaque;
    WrapResult finish()
    {
        if (!haveCluster) return WrapResult.init;
        if (clusters == scratch.clusters.length) return cellScratch();
        cluster.width = cluster.tokenEnd == cluster.tokenStart ? 0 : width.width;
        if (previousOpaque) cluster.width = 1;
        scratch.clusters[clusters++] = cluster;
        haveCluster = false;
        return WrapResult.init;
    }
    while (offset < source.bytes.length)
    {
        if (atoms == scratch.atoms.length) return cellScratch();
        if (source.bytes[offset] == '\x1B' && options.formatting != FormattingPolicy.literal)
        {
            if (styles == scratch.styles.length) return cellScratch();
            if (atoms >= limits.inputRecords || clusters > limits.inputRecords - atoms - 1
                || styles >= limits.inputRecords - atoms - 1 - clusters)
                return WrapResult(status: WrapStatus.budgetExhausted, kind: WrapBudgetKind.inputRecords,
                    used: atoms + clusters + styles, limit: limits.inputRecords, required: 2);
            size_t count;
            CellStyleSnapshot after;
            result = parseFormatting(source.bytes, offset, options.formatting, options.continuity,
                scratch.styles[liveStyle], after, count);
            if (!result.succeeded) return result;
            const(char)[] emission = source.bytes[offset .. offset + count];
            if (options.styleProvider.transition !is null)
            {
                size_t work;
                result = options.styleProvider.transition(scratch.styles[liveStyle],
                    CellFormattingEvent(offset, offset + count, emission), limits.providerWork - styleWork,
                    after, emission, work);
                if (!result.succeeded)
                {
                    result.phase = WrapPhase.scan; result.sourceStart = offset; result.sourceEnd = offset + count;
                    return result;
                }
                if (work > limits.providerWork - styleWork)
                    return WrapResult(status: WrapStatus.budgetExhausted, kind: WrapBudgetKind.providerWork,
                        used: styleWork, limit: limits.providerWork);
                styleWork += work;
            }
            if (!cellStyleAvoids(scratch, storage, after)
                || !cellBytesAvoids(scratch, storage, emission)) return invalidCell(offset, offset + count);
            if (options.styleProvider.transition !is null)
            {
                if (emission.length > limits.providerWork - styleWork)
                    return WrapResult(status: WrapStatus.budgetExhausted, kind: WrapBudgetKind.providerWork,
                        used: styleWork, limit: limits.providerWork, required: emission.length);
                CellStyleSnapshot emittedState = scratch.styles[liveStyle];
                size_t cursor;
                while (cursor < emission.length)
                {
                    if (emission[cursor] != '\x1B') return invalidCell(offset, offset + count);
                    CellStyleSnapshot emittedAfter;
                    size_t consumed;
                    result = parseFormatting(emission, cursor, options.formatting, options.continuity,
                        emittedState, emittedAfter, consumed);
                    if (!result.succeeded)
                    { result.sourceStart = offset; result.sourceEnd = offset + count; return result; }
                    emittedState = emittedAfter; cursor += consumed;
                }
                styleWork += emission.length;
                if (after.customRestore !is scratch.styles[liveStyle].customRestore)
                {
                    result = validateRestore(after, options, limits, styleWork);
                    if (!result.succeeded)
                    { result.sourceStart = offset; result.sourceEnd = offset + count; return result; }
                }
            }
            const nextStyle = styles++;
            if (options.styleProvider.transition is null) after.id = nextStyle;
            scratch.styles[nextStyle] = after;
            scratch.atoms[atoms++] = CellAtom(start: offset, end: offset + count,
                styleBefore: liveStyle, styleAfter: nextStyle, formatting: true, emission: emission);
            liveStyle = nextStyle;
            offset += count;
            continue;
        }
        if (tokens == scratch.tokens.length) return cellScratch();
        const decoded = decodeToken(source.bytes[offset .. $], options.malformed, true, offset);
        if (decoded.result.status != UtfStatus.ok)
            return WrapResult(status: WrapStatus.invalidEncoding, phase: WrapPhase.scan,
                sourceStart: offset, sourceEnd: offset + decoded.result.consumed);
        const token = decoded.token;
        const opaque = token.kind == UtfTokenKind.opaqueByte;
        bool boundary;
        if (opaque) { breaks.reset(); boundary = true; }
        else
        {
            if (previousOpaque) breaks.reset();
            boundary = breaks.push(token.scalar);
        }
        if (boundary && haveCluster)
        {
            result = finish(); if (!result.succeeded) return result;
        }
        if (!haveCluster)
        {
            const start = clusters ? scratch.clusters[clusters - 1].end : 0;
            size_t atomStart = atoms;
            while (atomStart && scratch.atoms[atomStart - 1].start >= start) --atomStart;
            cluster = CellCluster(start: start, atomStart: atomStart, tokenStart: tokens,
                styleStart: atomStart < atoms ? scratch.atoms[atomStart].styleBefore : liveStyle,
                first: opaque ? 0 : token.scalar);
            width = ClusterWidthState.init;
            haveCluster = true;
        }
        scratch.tokens[tokens] = token;
        scratch.atoms[atoms++] = CellAtom(start: offset, end: token.end, tokenIndex: tokens,
            styleBefore: liveStyle, styleAfter: liveStyle, token: token);
        ++tokens;
        if (!opaque) width.push(token.scalar, false);
        cluster.end = token.end;
        cluster.atomEnd = atoms;
        cluster.tokenEnd = tokens;
        cluster.styleEnd = liveStyle;
        if (cluster.tokenEnd == cluster.tokenStart + 1)
        {
            cluster.whitespace = !opaque && (token.scalar == ' ' || token.scalar == '\t');
            cluster.tab = !opaque && token.scalar == '\t';
            cluster.softHyphen = !opaque && token.scalar == '\u00AD';
        }
        else
        {
            // CRLF is one mandatory cluster; combining content is not a space run.
            cluster.whitespace = false;
            cluster.tab = false;
        }
        if (!opaque)
        {
            cluster.separator |= mandatoryScalar(token.scalar);
            cluster.protectedUnit |= protectedScalar(token.scalar);
        }
        previousOpaque = opaque;
        offset = token.end;
    }
    if (haveCluster)
    {
        const trailingAfterSeparator = cluster.separator && cluster.end < source.bytes.length;
        const tailStart = cluster.end, tailAtoms = cluster.atomEnd, tailStyle = cluster.styleEnd;
        if (!trailingAfterSeparator)
        {
            cluster.end = source.bytes.length; cluster.atomEnd = atoms; cluster.styleEnd = liveStyle;
        }
        result = finish(); if (!result.succeeded) return result;
        if (trailingAfterSeparator)
        {
            if (clusters == scratch.clusters.length) return cellScratch();
            scratch.clusters[clusters++] = CellCluster(start: tailStart, end: source.bytes.length,
                atomStart: tailAtoms, atomEnd: atoms, tokenStart: tokens, tokenEnd: tokens,
                styleStart: tailStyle, styleEnd: liveStyle);
        }
    }
    else if (atoms)
    {
        if (clusters == scratch.clusters.length) return cellScratch();
        scratch.clusters[clusters++] = CellCluster(start: 0, end: source.bytes.length,
            atomStart: 0, atomEnd: atoms, styleEnd: liveStyle);
    }
    foreach (span; options.noBreak)
    {
        bool startValid = span.start == 0, endValid = span.end == source.bytes.length;
        foreach (ref const atom; scratch.atoms[0 .. atoms])
        { startValid |= atom.start == span.start; endValid |= atom.end == span.end; }
        if (!startValid || !endValid) return invalidCell(span.start, span.end);
    }
    size_t emittedWork;
    foreach (ref c; scratch.clusters[0 .. clusters])
    {
        foreach (ref const atom; scratch.atoms[c.atomStart .. c.atomEnd])
        {
            const bytes = atom.formatting ? atom.emission.length : atom.end - atom.start;
            if (bytes > size_t.max - emittedWork) return cellArithmetic();
            emittedWork += bytes;
        }
        c.workEnd = emittedWork;
    }
    if (atoms > limits.inputRecords || clusters > limits.inputRecords - atoms
        || styles > limits.inputRecords - atoms - clusters)
        return WrapResult(status: WrapStatus.budgetExhausted, kind: WrapBudgetKind.inputRecords,
            used: atoms + clusters + styles, limit: limits.inputRecords);
    atomCount = atoms; tokenCount = tokens; clusterCount = clusters; styleCount = styles;
    return WrapResult.init;
}

private WrapResult measureIndent(const(char)[] text, CellStyleSnapshot initial,
    ref long advance, ref CellStyleSnapshot finalStyle,
    CellStyleSnapshot[] snapshots = null, scope size_t* styleCount = null,
    size_t recordLimit = size_t.max, size_t recordBase = 0,
    scope CellTabStops tabStops = CellTabStops.init, long startColumn = 0) @safe nothrow @nogc
{
    CellStyleSnapshot style = initial;
    GraphemeBreakState gcb;
    ClusterWidthState width;
    long sum;
    size_t offset;
    while (offset < text.length)
    {
        if (text[offset] == '\x1B')
        {
            if (styleCount !is null)
            {
                if (*styleCount == snapshots.length) return cellScratch();
                if (recordBase > recordLimit || *styleCount >= recordLimit - recordBase)
                    return WrapResult(status: WrapStatus.budgetExhausted, kind: WrapBudgetKind.inputRecords,
                        used: recordBase + *styleCount, limit: recordLimit, required: 1);
            }
            size_t consumed;
            CellStyleSnapshot after;
            auto r = parseFormatting(text, offset, FormattingPolicy.rejectUnknown,
                StyleContinuity.suspendResume, style, after, consumed);
            if (!r.succeeded) return r;
            if (styleCount !is null)
            {
                after.id = *styleCount;
                snapshots[(*styleCount)++] = after;
            }
            style = after; offset += consumed;
            continue;
        }
        const decoded = decodeToken(text[offset .. $], UtfMode.strict, true, offset);
        if (decoded.result.status != UtfStatus.ok)
            return WrapResult(status: WrapStatus.invalidEncoding, sourceStart: offset,
                sourceEnd: offset + decoded.result.consumed);
        const token = decoded.token;
        if (token.scalar == '\t')
        {
            auto r = checkedCellAdd(sum, width.width, sum); if (!r.succeeded) return r;
            long column, tab;
            r = checkedCellAdd(startColumn, sum, column); if (!r.succeeded) return r;
            r = nextTab(column, tabStops, tab); if (!r.succeeded) return r;
            r = checkedCellAdd(sum, tab, sum); if (!r.succeeded) return r;
            gcb = GraphemeBreakState.init;
            width = ClusterWidthState.init;
            offset = token.end;
            continue;
        }
        if (token.scalar == '\x1B' || mandatoryScalar(token.scalar) || token.scalar == '\u00AD')
            return invalidCell(offset, token.end);
        if (gcb.push(token.scalar))
        {
            auto r = checkedCellAdd(sum, width.width, sum); if (!r.succeeded) return r;
            width = ClusterWidthState.init;
        }
        width.push(token.scalar, false);
        offset = token.end;
    }
    auto r = checkedCellAdd(sum, width.width, sum); if (!r.succeeded) return r;
    advance = sum;
    finalStyle = style;
    return WrapResult.init;
}
private WrapResult indentAdvance(const(char)[] text, ref long advance) @safe nothrow @nogc
{
    CellStyleSnapshot finalStyle;
    return measureIndent(text, CellStyleSnapshot.init, advance, finalStyle);
}
private WrapResult prepareGeometry(WrapOptions options, WrapLimits limits, CellWrapScratch scratch,
    ref size_t geometryCount, ref size_t work, ref size_t styles, size_t records) @safe nothrow @nogc
{
    auto r = validateCellOptions(options);
    if (!r.succeeded) return r;
    const count = options.geometry.length ? options.geometry.length : 2;
    if (scratch.geometry.length < count || scratch.indentStyles.length < count
        || scratch.indentStyleStarts.length < count) return cellScratch(count);
    foreach (i; 0 .. count)
    {
        const g = options.geometry.length ? options.geometry[i]
            : CellGeometry(options.width, options.startColumn, i == 0 ? options.firstIndent : options.indent, i);
        if (styles == scratch.styles.length) return cellScratch();
        if (records > limits.inputRecords || styles >= limits.inputRecords - records)
            return WrapResult(status: WrapStatus.budgetExhausted, kind: WrapBudgetKind.inputRecords,
                used: records + styles, limit: limits.inputRecords, required: 1, phase: WrapPhase.geometry);
        if (g.indent.length > limits.providerWork - work)
            return WrapResult(status: WrapStatus.budgetExhausted, kind: WrapBudgetKind.providerWork,
                used: work, limit: limits.providerWork, required: g.indent.length, phase: WrapPhase.geometry);
        work += g.indent.length;
        long indent;
        scratch.indentStyleStarts[i] = styles;
        scratch.styles[styles++] = options.indentStyle;
        r = measureIndent(g.indent, options.indentStyle, indent, scratch.indentStyles[i],
            scratch.styles, &styles, limits.inputRecords, records, options.tabStops,
            cast(long) g.startColumn.value);
        if (!r.succeeded) { r.phase = WrapPhase.geometry; return r; }
        const width = cast(long) g.width.extent.value;
        scratch.geometry[i] = WrapGeometry(capacity: width,
            mandatoryOverflow: 0,
            startColumn: cast(long) g.startColumn.value, indentExtent: indent, id: g.id, unbounded: g.width.isUnbounded);
    }
    geometryCount = count;
    return WrapResult.init;
}

package WrapResult nextTab(long column, scope CellTabStops stops, ref long advance) @safe nothrow @nogc
{
    foreach (stop; stops.explicitStops)
        if (stop.value > cast(ulong) column) { advance = cast(long) stop.value - column; return WrapResult.init; }
    if (!stops.periodicTail) return WrapResult(status: WrapStatus.noNextTabStop);
    const interval = cast(long) stops.interval.value;
    const distance = interval - column % interval;
    long end;
    auto r = checkedCellAdd(column, distance, end); if (!r.succeeded) return r;
    advance = distance;
    return WrapResult.init;
}

private struct CellMeasureContext
{
    const(CellCluster)[] clusters;
    WrapOptions options;
    const(WrapGeometry)[] preparedGeometry;
    const(size_t)[] indentStyleStarts;
    SourceSnapshot source;
    const(CellAtom)[] atoms;
    const(CellStyleSnapshot)[] styles;
    WrapFragment[] raw, realized;
    size_t overflowStart, overflowEnd;
    bool sawOverflow;
    bool monotoneContent;
    bool haveUnitExtent;
    size_t cachedUnitStart, cachedUnitEnd, cachedUnitIndentStyle;
    long cachedUnitWidth, cachedUnitColumn;
    const(char)[] cachedUnitIndent;

    WrapResult geometry(WrapStartState state, WrapEndpoint endpoint, ref WrapGeometry output) @safe nothrow @nogc
    {
        size_t index = state.paragraphLine;
        if (index >= preparedGeometry.length)
        {
            if (options.geometry.length && !options.repeatLastGeometry)
                return WrapResult(status: WrapStatus.geometryExhausted, line: index);
            index = preparedGeometry.length - 1;
        }
        output = preparedGeometry[index];
        return WrapResult.init;
    }
    const(char)[] indentFor(size_t paragraphLine) @safe nothrow @nogc
    {
        if (!options.geometry.length) return paragraphLine ? options.indent : options.firstIndent;
        const index = paragraphLine < options.geometry.length ? paragraphLine : options.geometry.length - 1;
        return options.geometry[index].indent;
    }
    WrapResult workFor(size_t start, size_t end, const(char)[] indent, ref size_t count) @safe nothrow @nogc
    {
        const before = start ? clusters[start - 1].workEnd : 0;
        const after = end ? clusters[end - 1].workEnd : 0;
        const emitted = after - before;
        if (emitted > size_t.max - indent.length) return cellArithmetic();
        const bytes = emitted + indent.length;
        if (bytes > (size_t.max - 4) / 4) return cellArithmetic();
        count = bytes * 4 + 4;
        return WrapResult.init;
    }
    WrapResult build(size_t start, size_t end, WrapGeometry geometry, bool hyphen,
        const(char)[] indent, ref RealizedCellProjection projection, size_t indentStyle = 0) @safe nothrow @nogc
    {
        CellProjector builder = CellProjector(source, options, atoms, clusters, styles, raw, null);
        if (indent.length)
        {
            auto r = builder.append(WrapFragment(kind: FragmentKind.bytes, bytes: indent,
                provenance: ProvenanceKind.synthetic, reason: SyntheticReason.indent,
                anchor: start < clusters.length ? clusters[start].start : source.bytes.length,
                styleBefore: indentStyle, styleAfter: indentStyle));
            if (!r.succeeded) return r;
        }
        auto r = builder.content(start, end, geometry, hyphen); if (!r.succeeded) return r;
        // Authored fragments already carry validated snapshot ordinals. Only
        // native inline indent transitions need the table during realization;
        // avoid revalidating every source style for every plain candidate.
        return realizeCellProjection(raw[0 .. builder.used], options, geometry.startColumn,
            realized, projection, indent.length ? styles : null);
    }
    WrapResult extent(size_t start, size_t end, WrapGeometry geometry, bool hyphen,
        ref long advance, ref size_t work, const(char)[] indent = null, size_t indentStyle = 0) @safe nothrow @nogc
    {
        size_t bound;
        auto r = workFor(start, end, indent, bound); if (!r.succeeded) return r;
        if (bound > size_t.max - work) return cellArithmetic();
        RealizedCellProjection projection;
        r = build(start, end, geometry, hyphen, indent, projection, indentStyle); if (!r.succeeded) return r;
        advance = projection.advance;
        if (options.selectionMeasure !is null)
        {
            r = options.selectionMeasure(realized[0 .. projection.written], styles, advance);
            if (!r.succeeded) return r;
            if (advance < 0) return invalidCell();
        }
        work += bound;
        return WrapResult.init;
    }
    WrapResult measure(scope const ref MeasurableInput input, WrapCandidate key,
        WrapGeometry geometry, size_t grant, ref WrapMeasurement output) @safe nothrow @nogc
    {
        const endpoint = input.endpoints[key.endpoint];
        const start = key.start.primitive, end = endpoint.contentEnd;
        const indent = indentFor(key.start.paragraphLine);
        const indentIndex = key.start.paragraphLine < indentStyleStarts.length
            ? key.start.paragraphLine : indentStyleStarts.length - 1;
        const indentStyle = indentStyleStarts[indentIndex];
        size_t required;
        auto r = workFor(start, end, indent, required); if (!r.succeeded) return r;
        const emergency = endpoint.origin == OpportunityOrigin.emergency;
        // Leading omitted whitespace is source coverage, not the overfull unit.
        // Keep the candidate's authored start while testing its retained content.
        size_t contentStart = start;
        if (options.whitespace != WhitespaceMode.preserve)
            while (contentStart < end && clusters[contentStart].whitespace)
                ++contentStart;
        const unitAnchor = contentStart < end ? contentStart : start;
        size_t unitStart = start, unitEnd = end, unitWork;
        if (unitAnchor < clusters.length)
        { unitStart = clusters[unitAnchor].unitStart; unitEnd = clusters[unitAnchor].unitEnd; }
        const cachedUnit = haveUnitExtent && cachedUnitStart == unitStart && cachedUnitEnd == unitEnd
            && cachedUnitColumn == geometry.startColumn && cachedUnitIndent == indent
            && cachedUnitIndentStyle == indentStyle;
        if (emergency && !cachedUnit)
        {
            r = workFor(unitStart, unitEnd, indent, unitWork); if (!r.succeeded) return r;
            if (unitWork > size_t.max - required) return cellArithmetic();
            required += unitWork;
        }
        if (required > grant) return WrapResult(status: WrapStatus.budgetExhausted,
            kind: WrapBudgetKind.providerWork, used: 0, limit: grant, required: required);
        const hyphen = options.emitSoftHyphenGlyph && endpoint.origin == OpportunityOrigin.discretionary && !endpoint.terminal;
        RealizedCellProjection projection;
        r = build(start, end, geometry, hyphen, indent, projection, indentStyle); if (!r.succeeded) return r;
        WrapMeasurement m = WrapMeasurement(natural: projection.advance, work: required);
        if (options.selectionMeasure !is null)
        {
            r = options.selectionMeasure(realized[0 .. projection.written], styles, m.natural);
            if (!r.succeeded) return r;
            if (m.natural < 0) return invalidCell();
        }
        if (key.start.hasPrevious && projection.hasText)
        {
            if (!(key.start.providerState & 1) && projection.first.kind != UtfTokenKind.opaqueByte)
            {
                GraphemeBreakState previous;
                if (!previous.tryRestoreIdentity(key.start.providerState >> 1)) return invalidCell();
                m.safeBreak = previous.push(projection.first.scalar);
            }
        }
        if (!endpoint.terminal && endpoint.tag != OpportunityTag.forced && !projection.hasSourceText) m.safeBreak = false;
        const nextState = (projection.trailing.identity << 1) | (projection.trailingOpaque ? 1UL : 0UL);
        m.nextProviderState = nextState;
        const oneCluster = projection.bodyClusters == 1;
        if (emergency)
        {
            long unitWidth;
            size_t unused;
            const unitHyphen = options.emitSoftHyphenGlyph && unitEnd < clusters.length
                && unitEnd > unitStart && clusters[unitEnd - 1].softHyphen;
            if (cachedUnit) unitWidth = cachedUnitWidth;
            else
            {
                r = extent(unitStart, unitEnd, geometry, unitHyphen, unitWidth, unused, indent, indentStyle);
                if (!r.succeeded) return r;
                // Certified target measurements are deterministic for the same
                // complete unit, column and indent brush.
                if (options.selectionMeasure is null || options.selectionMeasureMonotone)
                {
                    haveUnitExtent = true; cachedUnitStart = unitStart; cachedUnitEnd = unitEnd;
                    cachedUnitColumn = geometry.startColumn; cachedUnitIndent = indent; cachedUnitWidth = unitWidth;
                    cachedUnitIndentStyle = indentStyle;
                }
            }
            m.safeBreak &= unitWidth > geometry.capacity && !clusters[unitAnchor].protectedUnit
                && options.overflow == CellOverflowPolicy.graphemeEmergency;
        }
        // Leading/trailing whitespace omission and collapse retain the same
        // prefix from a fixed start; extending it adds nonnegative clusters.
        // A fixed indent only shifts tab stops. Soft-hyphen replacement can
        // reduce a later extent, so those streams remain uncertified.
        m.noFollowingFit = monotoneContent && !geometry.unbounded
            && m.natural > geometry.capacity;
        if (!geometry.unbounded && m.natural > geometry.capacity)
        {
            const contentUnitEnd = unitEnd && clusters[unitEnd - 1].separator ? unitEnd - 1 : unitEnd;
            const wholeUnit = start <= unitStart && unitStart <= contentStart && end == contentUnitEnd;
            const indivisibleUnit = options.overflow == CellOverflowPolicy.overflowUnit
                || !projection.hasSourceText
                || (unitAnchor < clusters.length && clusters[unitAnchor].protectedUnit);
            m.allowOverfull = options.overflow != CellOverflowPolicy.reject
                && ((wholeUnit && indivisibleUnit)
                    || (oneCluster && options.overflow == CellOverflowPolicy.graphemeEmergency));
            if (emergency && !oneCluster) m.allowOverfull = false;
            if (options.overflow == CellOverflowPolicy.reject && (wholeUnit || oneCluster))
            { sawOverflow = true; overflowStart = start < clusters.length ? clusters[start].start : 0;
                overflowEnd = end > start ? clusters[end - 1].end : overflowStart; }
        }
        output = m;
        return WrapResult.init;
    }
}

private WrapResult buildCellGraph(SourceSnapshot source, WrapOptions options, CellWrapScratch scratch,
    size_t atoms, size_t tokens, ref size_t clusters, ref size_t endpoints) @safe nothrow @nogc
{
    auto r = lineOpportunities(scratch.tokens[0 .. tokens], scratch.opportunities, scratch.lineWorkspace);
    if (!r.succeeded()) return cellScratch(r.required);
    if (options.opportunities == CellOpportunityPolicy.wordPreserving)
    {
        r = wordBoundaries(scratch.tokens[0 .. tokens], scratch.words, scratch.wordWorkspace);
        if (!r.succeeded()) return cellScratch(r.required);
    }
    if (clusters > scratch.primitives.length || atoms > scratch.sourceRecords.length) return cellScratch();
    size_t ep;
    foreach (i, ref cluster; scratch.clusters[0 .. clusters])
    {
        const boundary = scratch.opportunities[cluster.tokenEnd].kind;
        bool permitted = boundary != UnicodeBoundaryKind.prohibited;
        if (options.opportunities == CellOpportunityPolicy.wordPreserving && !cluster.separator && i + 1 != clusters)
            permitted &= scratch.words[cluster.tokenEnd].kind != UnicodeBoundaryKind.prohibited;
        foreach (span; options.noBreak)
            if (cluster.end > span.start && cluster.end < span.end) permitted = false;
        cluster.ordinaryEnd = permitted || cluster.separator || i + 1 == clusters;
        scratch.primitives[i] = WrapPrimitive(kind: PrimitiveKind.box, id: i,
            dimension: WrapDimension.cells, advance: cluster.width,
            fragment: WrapFragment(sourceStart: cluster.start, sourceEnd: cluster.end));
    }
    // Define maximal policy-unbreakable units. Protection is a unit property,
    // so an NBSP/WJ or author span is never bypassed by emergency splitting.
    size_t begin;
    foreach (i; 0 .. clusters)
        if (scratch.clusters[i].ordinaryEnd)
        {
            bool protectedUnit;
            foreach (ref const cluster; scratch.clusters[begin .. i + 1]) protectedUnit |= cluster.protectedUnit;
            foreach (span; options.noBreak)
                if (span.start < scratch.clusters[i].end && span.end > scratch.clusters[begin].start) protectedUnit = true;
            foreach (ref cluster; scratch.clusters[begin .. i + 1])
            { cluster.unitStart = begin; cluster.unitEnd = i + 1; cluster.protectedUnit = protectedUnit; }
            begin = i + 1;
        }
    foreach (i, ref const cluster; scratch.clusters[0 .. clusters])
    {
        const emergency = !cluster.ordinaryEnd && !cluster.protectedUnit
            && options.overflow == CellOverflowPolicy.graphemeEmergency;
        if (!cluster.ordinaryEnd && !emergency) continue;
        if (ep == scratch.endpoints.length) return cellScratch();
        if (i > (ulong.max - 1) / 2) return cellArithmetic();
        const terminal = i + 1 == clusters && !cluster.separator;
        scratch.endpoints[ep++] = WrapEndpoint(end: i + 1,
            contentEnd: cluster.separator ? i : i + 1, sourceEnd: cluster.end,
            alternativeId: cast(ulong)(i * 2 + (emergency ? 1 : 0)),
            tag: cluster.separator || terminal ? OpportunityTag.forced : OpportunityTag.optional,
            origin: emergency ? OpportunityOrigin.emergency
                : cluster.softHyphen ? OpportunityOrigin.discretionary : OpportunityOrigin.unicode,
            paragraphEnd: cluster.separator || terminal, terminal: terminal);
    }
    if (!clusters || scratch.clusters[clusters - 1].separator)
    {
        if (ep == scratch.endpoints.length) return cellScratch();
        if (clusters)
        {
            if (clusters == scratch.clusters.length || clusters == scratch.primitives.length) return cellScratch();
            scratch.clusters[clusters] = CellCluster(start: source.bytes.length, end: source.bytes.length,
                workEnd: scratch.clusters[clusters - 1].workEnd,
                atomStart: atoms, atomEnd: atoms, tokenStart: tokens, tokenEnd: tokens,
                unitStart: clusters, unitEnd: clusters + 1, ordinaryEnd: true,
                styleStart: scratch.clusters[clusters - 1].styleEnd, styleEnd: scratch.clusters[clusters - 1].styleEnd);
            scratch.primitives[clusters] = WrapPrimitive(kind: PrimitiveKind.anchor, id: clusters,
                fragment: WrapFragment(sourceStart: source.bytes.length, sourceEnd: source.bytes.length));
            ++clusters;
        }
        scratch.endpoints[ep++] = WrapEndpoint(end: clusters, contentEnd: clusters,
            sourceEnd: source.bytes.length, alternativeId: cast(ulong)(clusters * 2),
            tag: OpportunityTag.forced, paragraphEnd: true, terminal: true);
    }
    foreach (i, ref const atom; scratch.atoms[0 .. atoms])
        scratch.sourceRecords[i] = SourceRecord(atom.start, atom.end,
            atom.formatting ? ProvenanceKind.original
            : atom.token.kind == UtfTokenKind.replacement ? ProvenanceKind.replacement
            : mandatoryScalar(atom.token.kind == UtfTokenKind.opaqueByte ? 0 : atom.token.scalar) ? ProvenanceKind.separator
            : atom.token.kind != UtfTokenKind.opaqueByte && atom.token.scalar == '\u00AD' ? ProvenanceKind.omission
            : ProvenanceKind.original, i, atom.formatting);
    endpoints = ep;
    return WrapResult.init;
}

private struct CellProjector
{
    SourceSnapshot source;
    WrapOptions options;
    const(CellAtom)[] atoms;
    const(CellCluster)[] clusters;
    const(CellStyleSnapshot)[] styles;
    WrapFragment[] output;
    SourceRecord[] records;
    size_t used;
    size_t liveStyle, defaultStyle;

    WrapResult append(WrapFragment fragment) @safe nothrow @nogc
    {
        if (used == output.length) return cellScratch();
        output[used++] = fragment;
        return WrapResult.init;
    }
    WrapResult synthetic(const(char)[] bytes, size_t anchor, SyntheticReason reason) @safe nothrow @nogc
    {
        return append(WrapFragment(kind: FragmentKind.bytes, bytes: bytes,
            anchor: anchor, provenance: ProvenanceKind.synthetic, reason: reason, formatting: true,
            styleBefore: liveStyle, styleAfter: reason == SyntheticReason.styleSuspend ? defaultStyle : liveStyle));
    }
    WrapResult suspend(CellStyleSnapshot style, size_t anchor) @safe nothrow @nogc
    {
        if (style.linkOpen.length)
        {
            auto r = synthetic("\x1b]8;;\x1b\\", anchor, SyntheticReason.styleSuspend); if (!r.succeeded) return r;
        }
        if (style.active)
            return synthetic("\x1b[0m", anchor, SyntheticReason.styleSuspend);
        return WrapResult.init;
    }
    WrapResult resume(CellStyleSnapshot style, size_t anchor, size_t targetStyle = 0) @safe nothrow @nogc
    {
        const begin = used;
        if (style.customRestore.length)
        {
            auto r = synthetic(style.customRestore, anchor, SyntheticReason.styleResume); if (!r.succeeded) return r;
        }
        else if (style.active)
        {
            auto r = synthetic("\x1b[", anchor, SyntheticReason.styleResume); if (!r.succeeded) return r;
            bool first = true;
            static immutable string[9] codes = ["1", "2", "3", "4", "5", "6", "7", "8", "9"];
            foreach (i; 0 .. 9)
                if (i != 3 && (style.attributes & (1U << i)))
                {
                    if (!first) { r = synthetic(";", anchor, SyntheticReason.styleResume); if (!r.succeeded) return r; }
                    r = synthetic(codes[i], anchor, SyntheticReason.styleResume); if (!r.succeeded) return r;
                    first = false;
                }
            if (style.underline != CellUnderlineStyle.none)
            {
                static immutable string[6] underlines = ["4:0", "4", "4:2", "4:3", "4:4", "4:5"];
                if (!first) { r = synthetic(";", anchor, SyntheticReason.styleResume); if (!r.succeeded) return r; }
                r = synthetic(underlines[style.underline], anchor, SyntheticReason.styleResume);
                if (!r.succeeded) return r;
                first = false;
            }
            const(char)[][3] colors = [style.foreground, style.background, style.underlineColor];
            foreach (color; colors)
                if (color.length)
                {
                    if (!first) { r = synthetic(";", anchor, SyntheticReason.styleResume); if (!r.succeeded) return r; }
                    r = synthetic(color, anchor, SyntheticReason.styleResume); if (!r.succeeded) return r;
                    first = false;
                }
            r = synthetic("m", anchor, SyntheticReason.styleResume); if (!r.succeeded) return r;
        }
        if (style.linkOpen.length)
        { auto r = synthetic(style.linkOpen, anchor, SyntheticReason.styleResume); if (!r.succeeded) return r; }
        if (used > begin) output[used - 1].styleAfter = targetStyle;
        liveStyle = targetStyle;
        return WrapResult.init;
    }
    WrapResult content(size_t start, size_t end, WrapGeometry geometry, bool hyphen) @safe nothrow @nogc
    {
        const first = start < end ? clusters[start].atomStart : 0;
        const last = start < end ? clusters[end - 1].atomEnd : first;
        bool white(size_t index)
        {
            const a = atoms[index];
            return !a.formatting && a.token.kind != UtfTokenKind.opaqueByte
                && (a.token.scalar == ' ' || a.token.scalar == '\t');
        }
        bool invisible(size_t index)
        {
            const a = atoms[index];
            return a.formatting || (a.token.kind != UtfTokenKind.opaqueByte
                && (a.token.scalar == '\u00AD' || mandatoryScalar(a.token.scalar)));
        }
        size_t firstContent = last, lastContent = first;
        foreach (a; first .. last)
            if (!white(a) && !invisible(a))
            { if (firstContent == last) firstContent = a; lastContent = a + 1; }
        size_t cursor = first;
        while (cursor < last)
        {
            if (white(cursor) && (options.whitespace == WhitespaceMode.collapse
                || options.whitespace == WhitespaceMode.trimAroundBreak
                    && (cursor < firstContent || cursor >= lastContent)))
            {
                size_t runEnd = cursor + 1, consumedEnd = atoms[cursor].end;
                while (runEnd < last && (atoms[runEnd].formatting || white(runEnd)))
                { if (!atoms[runEnd].formatting) consumedEnd = atoms[runEnd].end; ++runEnd; }
                const retained = cursor > firstContent && (runEnd < lastContent || hyphen);
                bool emitted;
                foreach (a; cursor .. runEnd)
                {
                    const atom = atoms[a];
                    if (atom.formatting)
                    {
                        auto r = append(WrapFragment(kind: FragmentKind.bytes, bytes: atom.emission,
                            consumedStart: atom.start, consumedEnd: atom.end, sourceRecordOrdinal: a,
                            sourceStart: atom.start, sourceEnd: atom.end, formatting: true,
                            styleBefore: atom.styleBefore, styleAfter: atom.styleAfter,
                            provenance: ProvenanceKind.original));
                        if (!r.succeeded) return r;
                    }
                    else
                    {
                        if (records.length) records[a].kind = retained ? ProvenanceKind.replacement : ProvenanceKind.omission;
                        if (retained && !emitted)
                        {
                            auto r = append(WrapFragment(kind: FragmentKind.bytes, bytes: " ",
                                sourceStart: atoms[cursor].start, sourceEnd: consumedEnd,
                                consumedStart: atoms[cursor].start, consumedEnd: consumedEnd,
                                anchor: atoms[cursor].start, provenance: ProvenanceKind.replacement,
                                reason: SyntheticReason.replacement,
                                styleBefore: atom.styleBefore, styleAfter: atom.styleAfter));
                            if (!r.succeeded) return r;
                            emitted = true;
                        }
                    }
                }
                cursor = runEnd;
                continue;
            }
            const atom = atoms[cursor];
            WrapFragment fragment = WrapFragment(kind: FragmentKind.bytes,
                sourceStart: atom.start, sourceEnd: atom.end, consumedStart: atom.start,
                consumedEnd: atom.end, sourceRecordOrdinal: cursor, anchor: atom.start,
                styleBefore: atom.styleBefore, styleAfter: atom.styleAfter,
                provenance: ProvenanceKind.original, formatting: atom.formatting);
            if (atom.formatting) fragment.bytes = atom.emission;
            else
            {
                if (invisible(cursor)) { ++cursor; continue; }
                if (atom.token.kind == UtfTokenKind.replacement)
                { fragment.bytes = "\uFFFD"; fragment.provenance = ProvenanceKind.replacement; }
                else fragment.bytes = source.bytes[atom.start .. atom.end];
                if (options.tabs == TabPolicy.expand && atom.token.kind != UtfTokenKind.opaqueByte
                    && atom.token.scalar == '\t' && records.length) records[cursor].kind = ProvenanceKind.replacement;
            }
            auto r = append(fragment); if (!r.succeeded) return r;
            ++cursor;
        }
        if (hyphen)
        {
            const anchor = end ? clusters[end - 1].end : 0;
            auto r = append(WrapFragment(kind: FragmentKind.bytes, bytes: "-",
                anchor: anchor, provenance: ProvenanceKind.synthetic, reason: SyntheticReason.hyphen,
                styleBefore: end ? clusters[end - 1].styleEnd : 0, styleAfter: end ? clusters[end - 1].styleEnd : 0));
            if (!r.succeeded) return r;
        }
        return WrapResult.init;
    }
}

WrapResult tryWrapCells(SourceSnapshot source, WrapOptions options, WrapLimits limits,
    CellWrapScratch scratch, WrapPlanStorage storage, ref WrapPlan outPlan) @safe nothrow @nogc
{
    import sparkles.base.text.utf : utfObjectStorage;
    // Reject publication/input/scratch aliasing before either scan or callbacks.
    if (!cellStorageDisjoint(scratch, storage, outPlan)
        || !cellBytesAvoids(scratch, storage, source.bytes)
        || !cellOptionsAvoid(scratch, storage, options)
        || !cellStorageAvoids(scratch, utfObjectStorage(outPlan))
        || !wrapStorageAvoids(utfObjectStorage(outPlan), storage.lines, storage.fragments, storage.sourceRecords, storage.styles))
        return invalidCell();
    size_t atoms, tokens, clusters, styles, styleWork, endpoints, geometryCount, geometryWork;
    auto r = scanCells(source, options, limits, scratch, atoms, tokens, clusters, styles, styleWork, storage);
    if (!r.succeeded) return r;
    auto geometryLimits = limits;
    geometryLimits.providerWork -= styleWork;
    r = prepareGeometry(options, geometryLimits, scratch, geometryCount, geometryWork, styles, atoms + clusters);
    if (!r.succeeded) return r;
    if (styles == scratch.styles.length) return cellScratch();
    if (atoms > limits.inputRecords || clusters > limits.inputRecords - atoms
        || styles >= limits.inputRecords - atoms - clusters)
        return WrapResult(status: WrapStatus.budgetExhausted, kind: WrapBudgetKind.inputRecords,
            used: atoms + clusters + styles, limit: limits.inputRecords, required: 1);
    const defaultStyle = styles++;
    scratch.styles[defaultStyle] = CellStyleSnapshot(id: defaultStyle);
    r = buildCellGraph(source, options, scratch, atoms, tokens, clusters, endpoints);
    if (!r.succeeded) return r;
    CellMeasureContext context = CellMeasureContext(clusters: scratch.clusters[0 .. clusters], options: options,
        preparedGeometry: scratch.geometry[0 .. geometryCount], source: source, atoms: scratch.atoms[0 .. atoms],
        styles: scratch.styles[0 .. styles], raw: scratch.candidateFragments, realized: scratch.realizedFragments);
    context.indentStyleStarts = scratch.indentStyleStarts[0 .. geometryCount];
    context.monotoneContent = options.selectionMeasure is null || options.selectionMeasureMonotone;
    foreach (ref const cluster; context.clusters)
        if (cluster.softHyphen) { context.monotoneContent = false; break; }
    WrapProvider provider = WrapProvider(exact: true, measure: &context.measure, geometry: &context.geometry);
    MeasurableInput input = MeasurableInput(source, scratch.primitives[0 .. clusters],
        scratch.endpoints[0 .. endpoints], scratch.sourceRecords[0 .. atoms], WrapDimension.cells);
    input.malformed = options.malformed;
    WrapSolverOptions solverOptions = WrapSolverOptions(solver: options.solver);
    WrapGeometrySequence[1] geometries;
    size_t states, results;
    WrapUsage usage;
    auto effectiveLimits = limits;
    effectiveLimits.providerWork -= styleWork + geometryWork;
    r = selectBestWrapPath(input, geometries[], provider, solverOptions, effectiveLimits,
        scratch.solver, states, results, usage);
    if (!r.succeeded) return r;
    if (!results)
        return context.sawOverflow ? WrapResult(status: WrapStatus.unbreakableOverflow,
            sourceStart: context.overflowStart, sourceEnd: context.overflowEnd)
            : WrapResult(status: WrapStatus.noFeasiblePlan);
    const terminal = scratch.solver.ranked[0];
    const count = scratch.solver.states[terminal].objective.lines;
    if (scratch.solver.selected.length < count || scratch.solver.projection.lines.length < count
        || scratch.solver.projection.sourceRecords.length < atoms
        || scratch.solver.projection.styles.length < styles) return cellScratch();
    size_t cursor = terminal;
    foreach_reverse (i; 0 .. count)
    { scratch.solver.selected[i] = cursor; cursor = scratch.solver.states[cursor].predecessor; }
    scratch.solver.projection.sourceRecords[0 .. atoms] = scratch.sourceRecords[0 .. atoms];
    if (count > limits.outputRecords || atoms > limits.outputRecords - count
        || styles > limits.outputRecords - count - atoms)
        return WrapResult(status: WrapStatus.budgetExhausted, kind: WrapBudgetKind.outputRecords,
            used: count + atoms + styles, limit: limits.outputRecords);
    if (styles > size_t.max / 2) return cellArithmetic();
    if (scratch.styleTransitions.length < styles * 2) return cellScratch(styles * 2 - scratch.styleTransitions.length);
    scratch.styleTransitions[0 .. styles * 2] = size_t.max;
    CellProjectionStyles emittedStyles = CellProjectionStyles(snapshots: scratch.styles, used: styles,
        limit: limits.outputRecords - count - atoms, inherit: options.continuity == StyleContinuity.copyThrough,
        transitions: scratch.styleTransitions[0 .. styles * 2], fixedCount: styles);
    CellProjector projector = CellProjector(source, options, scratch.atoms[0 .. atoms],
        scratch.clusters[0 .. clusters], scratch.styles[0 .. styles],
        scratch.candidateFragments, scratch.solver.projection.sourceRecords);
    projector.defaultStyle = defaultStyle;
    size_t sourceStart, fragmentCount;
    foreach (i; 0 .. count)
    {
        const state = scratch.solver.states[scratch.solver.selected[i]];
        const parent = scratch.solver.states[state.predecessor];
        const endpoint = scratch.endpoints[state.endpoint];
        const start = parent.next.primitive;
        const end = endpoint.contentEnd;
        const startStyle = start < clusters ? scratch.clusters[start].styleStart : 0;
        const endStyle = endpoint.end ? scratch.clusters[endpoint.end - 1].styleEnd : 0;
        const fragmentStart = fragmentCount;
        projector.used = 0;
        projector.liveStyle = emittedStyles.live;
        const geometryIndex = parent.next.paragraphLine < geometryCount ? parent.next.paragraphLine : geometryCount - 1;
        const indentStyle = scratch.indentStyleStarts[geometryIndex];
        const indent = options.geometry.length
            ? options.geometry[parent.next.paragraphLine < options.geometry.length
                ? parent.next.paragraphLine : options.geometry.length - 1].indent
            : parent.next.paragraphLine == 0 ? options.firstIndent : options.indent;
        if (options.continuity == StyleContinuity.suspendResume && indent.length)
        {
            r = projector.suspend(scratch.styles[startStyle], sourceStart); if (!r.succeeded) return r;
        }
        if (indent.length)
        {
            if (options.continuity == StyleContinuity.suspendResume)
            { r = projector.resume(options.indentStyle, sourceStart, indentStyle); if (!r.succeeded) return r; }
            r = projector.append(WrapFragment(kind: FragmentKind.bytes, bytes: indent,
                advance: state.geometry.indentExtent, anchor: sourceStart,
                provenance: ProvenanceKind.synthetic, reason: SyntheticReason.indent,
                styleBefore: indentStyle, styleAfter: indentStyle));
            if (!r.succeeded) return r;
            if (options.continuity == StyleContinuity.suspendResume)
            {
                projector.liveStyle = geometryIndex + 1 < geometryCount
                    ? scratch.indentStyleStarts[geometryIndex + 1] - 1 : defaultStyle - 1;
                r = projector.suspend(scratch.indentStyles[geometryIndex], sourceStart);
                if (!r.succeeded) return r;
            }
        }
        if (options.continuity == StyleContinuity.suspendResume && (i || indent.length))
        {
            r = projector.resume(scratch.styles[startStyle], sourceStart, startStyle); if (!r.succeeded) return r;
        }
        const hyphen = options.emitSoftHyphenGlyph && endpoint.origin == OpportunityOrigin.discretionary && !endpoint.terminal;
        r = projector.content(start, end, state.geometry, hyphen); if (!r.succeeded) return r;
        // Mandatory separator bytes are omitted, but any authored formatting
        // adjacent to them remains ordered and preserves logical state.
        if (end < endpoint.end)
            foreach (c; end .. endpoint.end)
                foreach (a; scratch.clusters[c].atomStart .. scratch.clusters[c].atomEnd)
                    if (scratch.atoms[a].formatting)
                    {
                        const atom = scratch.atoms[a];
                        r = projector.append(WrapFragment(kind: FragmentKind.bytes, bytes: atom.emission,
                            sourceStart: atom.start, sourceEnd: atom.end, consumedStart: atom.start,
                            consumedEnd: atom.end, sourceRecordOrdinal: a, styleBefore: atom.styleBefore,
                            styleAfter: atom.styleAfter, formatting: true, provenance: ProvenanceKind.original));
                        if (!r.succeeded) return r;
                    }
        projector.liveStyle = endStyle;
        if (options.continuity == StyleContinuity.suspendResume && (i + 1 != count
            || options.finalStyle == FinalStylePolicy.restoreInitialState))
        {
            r = projector.suspend(scratch.styles[endStyle], endpoint.sourceEnd); if (!r.succeeded) return r;
            if (i + 1 == count && options.finalStyle == FinalStylePolicy.restoreInitialState)
            { r = projector.resume(options.initialStyle, endpoint.sourceEnd, 0); if (!r.succeeded) return r; }
        }
        size_t projectionBytes;
        foreach (ref const fragment; scratch.candidateFragments[0 .. projector.used])
        {
            if (fragment.bytes.length > size_t.max - projectionBytes) return cellArithmetic();
            projectionBytes += fragment.bytes.length;
        }
        if (projectionBytes > (size_t.max - 4) / 4) return cellArithmetic();
        const projectionWork = projectionBytes * 4 + 4;
        const remainingWork = effectiveLimits.providerWork - usage.providerWork;
        if (projectionWork > remainingWork)
            return WrapResult(status: WrapStatus.budgetExhausted, phase: WrapPhase.projection,
                kind: WrapBudgetKind.providerWork, used: usage.providerWork + styleWork + geometryWork,
                limit: limits.providerWork, required: projectionWork);
        if (fragmentCount > limits.outputRecords - count - atoms
            || emittedStyles.used > limits.outputRecords - count - atoms - fragmentCount)
            return WrapResult(status: WrapStatus.budgetExhausted, phase: WrapPhase.projection,
                kind: WrapBudgetKind.outputRecords, used: count + atoms + fragmentCount + emittedStyles.used,
                limit: limits.outputRecords);
        emittedStyles.limit = limits.outputRecords - count - atoms - fragmentCount;
        RealizedCellProjection realized;
        r = realizeCellProjection(scratch.candidateFragments[0 .. projector.used], options,
            state.geometry.startColumn, scratch.realizedFragments, realized,
            scratch.styles[0 .. styles], &emittedStyles);
        if (!r.succeeded) return r;
        usage.providerWork += projectionWork;
        long selectedExtent = realized.advance;
        if (options.selectionMeasure !is null)
        {
            r = options.selectionMeasure(scratch.realizedFragments[0 .. realized.written],
                scratch.styles[0 .. emittedStyles.used], selectedExtent);
            if (!r.succeeded) return r;
        }
        if (selectedExtent != state.measurement.natural)
            return WrapResult(status: WrapStatus.invalidInput, phase: WrapPhase.projection);
        if (realized.written > scratch.solver.projection.fragments.length - fragmentCount) return cellScratch();
        scratch.solver.projection.fragments[fragmentCount .. fragmentCount + realized.written] =
            scratch.realizedFragments[0 .. realized.written];
        fragmentCount += realized.written;
        if (emittedStyles.used > limits.outputRecords - count - atoms
            || fragmentCount > limits.outputRecords - count - atoms - emittedStyles.used)
            return WrapResult(status: WrapStatus.budgetExhausted, kind: WrapBudgetKind.outputRecords,
                used: count + atoms + fragmentCount + emittedStyles.used, limit: limits.outputRecords);
        long endColumn;
        r = checkedCellAdd(state.geometry.startColumn, realized.advance, endColumn); if (!r.succeeded) return r;
        scratch.solver.projection.lines[i] = WrapLine(fragmentsStart: fragmentStart, fragmentsEnd: fragmentCount,
            sourceStart: sourceStart, sourceEnd: endpoint.sourceEnd, endpointOrdinal: state.endpoint,
            alternativeId: endpoint.alternativeId, geometryId: state.geometry.id,
            paragraphLine: parent.next.paragraphLine, startColumn: state.geometry.startColumn,
            indentExtent: realized.indentAdvance, contentAdvance: realized.advance - realized.indentAdvance,
            visibleAdvance: realized.advance,
            originalContentAdvance: realized.advance - realized.indentAdvance,
            separatorStart: end < endpoint.end ? scratch.clusters[end].start : 0,
            separatorEnd: end < endpoint.end ? scratch.clusters[endpoint.end - 1].end : 0,
            endColumn: endColumn, capacity: cast(long)(options.geometry.length
                ? options.geometry[parent.next.paragraphLine < options.geometry.length
                    ? parent.next.paragraphLine : options.geometry.length - 1].width.extent.value
                : options.width.extent.value),
            unbounded: state.geometry.unbounded, overfull: state.overfull,
            emergency: endpoint.origin == OpportunityOrigin.emergency, paragraphEnd: endpoint.paragraphEnd,
            startStyle: scratch.styles[startStyle].id, endStyle: scratch.styles[endStyle].id);
        sourceStart = endpoint.sourceEnd;
    }
    styles = emittedStyles.used;
    if (scratch.solver.projection.styles.length < styles) return cellScratch();
    scratch.solver.projection.styles[0 .. styles] = scratch.styles[0 .. styles];
    if (count > size_t.max - atoms || fragmentCount > size_t.max - count - atoms
        || styles > size_t.max - count - atoms - fragmentCount) return cellArithmetic();
    usage.outputRecords = count + atoms + fragmentCount + styles;
    usage.providerWork += styleWork + geometryWork;
    if (usage.outputRecords > limits.outputRecords)
        return WrapResult(status: WrapStatus.budgetExhausted, kind: WrapBudgetKind.outputRecords,
            used: usage.outputRecords, limit: limits.outputRecords);
    WrapPlan prepared = WrapPlan(source: source, lines: scratch.solver.projection.lines[0 .. count],
        fragments: scratch.solver.projection.fragments[0 .. fragmentCount],
        sourceRecords: scratch.solver.projection.sourceRecords[0 .. atoms],
        styles: scratch.solver.projection.styles[0 .. styles],
        proof: options.solver == WrapSolver.greedy ? WrapProof.localGreedy : WrapProof.completeExact,
        solver: options.solver, dimension: WrapDimension.cells,
        objective: scratch.solver.states[terminal].objective, usage: usage,
        profile: unicodeManifestIdentity ~ "/terminalKitty/1",
        cellPolicy: CellPolicy.terminalKitty, cellPolicyRevision: terminalKittyRevision,
        policyIdentity: cast(ulong) options.whitespace | (cast(ulong) options.opportunities << 4)
            | (cast(ulong) options.overflow << 8) | (cast(ulong) options.tabs << 12)
            | (cast(ulong) options.continuity << 16) | (cast(ulong) options.formatting << 20));
    return publishWrapPlan(prepared, scratch.solver.projection, storage, outPlan);
}

struct CellFit
{
    const(char)[] text, replacement;
    size_t start, end, replacementAnchor;
    CellExtent advance;
}
/// Enumeration deliberately remeasures suffixes from their supplied column:
/// tabs are not subtractive and fitting never assumes monotone measurements.
private WrapResult fitCells(SourceSnapshot source, CellExtent budget, WrapOptions options,
    WrapLimits limits, CellWrapScratch scratch, bool suffix, ref CellFit outFit) @safe nothrow @nogc
{
    size_t atoms, tokens, clusters, styles, styleWork;
    import sparkles.base.text.utf : utfObjectStorage;
    if (!cellStorageAvoids(scratch, utfObjectStorage(outFit))
        || !cellStorageAvoids(scratch, outFit.text) || !cellStorageAvoids(scratch, outFit.replacement)) return invalidCell();
    auto r = scanCells(source, options, limits, scratch, atoms, tokens, clusters, styles, styleWork);
    if (!r.succeeded) return r;
    if (budget.value > long.max) return cellArithmetic();
    CellMeasureContext context = CellMeasureContext(clusters: scratch.clusters[0 .. clusters], options: options,
        source: source, atoms: scratch.atoms[0 .. atoms], styles: scratch.styles[0 .. styles],
        raw: scratch.candidateFragments, realized: scratch.realizedFragments);
    WrapGeometry geometry = WrapGeometry(startColumn: cast(long) options.startColumn.value);
    size_t selected = suffix ? clusters : 0;
    long measured;
    size_t usedWork = styleWork;
    foreach (i; 0 .. clusters + 1)
    {
        size_t required;
        const start = suffix ? i : 0;
        const end = suffix ? clusters : i;
        foreach (ref const c; scratch.clusters[start .. end])
        {
            if (c.separator) return invalidCell(c.start, c.end);
        }
        r = context.workFor(start, end, null, required); if (!r.succeeded) return r;
        if (required > limits.providerWork - usedWork)
            return WrapResult(status: WrapStatus.budgetExhausted, kind: WrapBudgetKind.providerWork,
                used: usedWork, limit: limits.providerWork, required: required);
        long advance;
        r = context.extent(start, end, geometry, false, advance, usedWork); if (!r.succeeded) return r;
        if (cast(ulong) advance <= budget.value && (suffix ? i < selected : i >= selected))
        { selected = i; measured = advance; }
    }
    const start = suffix ? (selected == clusters ? source.bytes.length : scratch.clusters[selected].start) : 0;
    const end = suffix ? source.bytes.length : (selected ? scratch.clusters[selected - 1].end : 0);
    outFit = CellFit(text: source.bytes[start .. end], start: start, end: end, advance: CellExtent(cast(ulong) measured));
    return WrapResult.init;
}
WrapResult tryFitPrefixCells(SourceSnapshot source, CellExtent budget, WrapOptions options,
    WrapLimits limits, CellWrapScratch scratch, ref CellFit outFit) @safe nothrow @nogc
    => fitCells(source, budget, options, limits, scratch, false, outFit);
WrapResult tryFitSuffixCells(SourceSnapshot source, CellExtent budget, WrapOptions options,
    WrapLimits limits, CellWrapScratch scratch, ref CellFit outFit) @safe nothrow @nogc
    => fitCells(source, budget, options, limits, scratch, true, outFit);

WrapResult tryFitCellsWithReplacement(SourceSnapshot source, CellExtent budget,
    const(char)[] replacement, WrapOptions options, WrapLimits limits,
    CellWrapScratch scratch, bool suffix, ref CellFit outFit) @safe nothrow @nogc
{
    import sparkles.base.text.utf : utfObjectStorage;
    if (!cellStorageAvoids(scratch, utfObjectStorage(outFit))
        || !cellStorageAvoids(scratch, replacement) || !cellStorageAvoids(scratch, outFit.text)
        || !cellStorageAvoids(scratch, outFit.replacement)) return invalidCell();
    if (budget.value > long.max || replacement.length > size_t.max / 4) return cellArithmetic();
    size_t atoms, tokens, clusters, styles, usedWork;
    auto r = scanCells(source, options, limits, scratch, atoms, tokens, clusters, styles, usedWork);
    if (!r.succeeded) return r;
    const replacementWork = replacement.length * 4;
    if (replacementWork > limits.providerWork - usedWork)
        return WrapResult(status: WrapStatus.budgetExhausted, kind: WrapBudgetKind.providerWork,
            used: usedWork, limit: limits.providerWork, required: replacementWork);
    if (!scratch.candidateFragments.length && replacement.length) return cellScratch();
    size_t rawCount;
    if (replacement.length)
        scratch.candidateFragments[rawCount++] = WrapFragment(kind: FragmentKind.bytes, bytes: replacement,
            provenance: ProvenanceKind.synthetic, reason: SyntheticReason.replacement);
    RealizedCellProjection isolated;
    r = realizeCellProjection(scratch.candidateFragments[0 .. rawCount], options,
        cast(long) options.startColumn.value, scratch.realizedFragments, isolated);
    if (!r.succeeded) return r;
    usedWork += replacementWork;
    if (cast(ulong) isolated.advance > budget.value) return WrapResult(status: WrapStatus.replacementDoesNotFit);
    CellMeasureContext context = CellMeasureContext(clusters: scratch.clusters[0 .. clusters], options: options,
        source: source, atoms: scratch.atoms[0 .. atoms], styles: scratch.styles[0 .. styles],
        raw: scratch.candidateFragments, realized: scratch.realizedFragments);
    WrapGeometry geometry = WrapGeometry(startColumn: cast(long) options.startColumn.value);
    size_t selected = suffix ? clusters : 0;
    long measured = isolated.advance;
    foreach (i; 0 .. clusters + 1)
    {
        const start = suffix ? i : 0, end = suffix ? clusters : i;
        foreach (ref const c; scratch.clusters[start .. end]) if (c.separator) return invalidCell(c.start, c.end);
        size_t required;
        r = context.workFor(start, end, null, required); if (!r.succeeded) return r;
        if (replacementWork > size_t.max - required) return cellArithmetic();
        required += replacementWork;
        if (required > limits.providerWork - usedWork)
            return WrapResult(status: WrapStatus.budgetExhausted, kind: WrapBudgetKind.providerWork,
                used: usedWork, limit: limits.providerWork, required: required);
        CellProjector builder = CellProjector(source, options, scratch.atoms[0 .. atoms],
            scratch.clusters[0 .. clusters], scratch.styles[0 .. styles], scratch.candidateFragments, null);
        const anchor = suffix ? (start < clusters ? scratch.clusters[start].start : source.bytes.length)
            : end ? scratch.clusters[end - 1].end : 0;
        const fragment = WrapFragment(kind: FragmentKind.bytes, bytes: replacement,
            provenance: ProvenanceKind.synthetic, reason: SyntheticReason.replacement, anchor: anchor);
        if (suffix && replacement.length) { r = builder.append(fragment); if (!r.succeeded) return r; }
        r = builder.content(start, end, geometry, false); if (!r.succeeded) return r;
        if (!suffix && replacement.length) { r = builder.append(fragment); if (!r.succeeded) return r; }
        RealizedCellProjection combined;
        r = realizeCellProjection(scratch.candidateFragments[0 .. builder.used], options,
            geometry.startColumn, scratch.realizedFragments, combined); if (!r.succeeded) return r;
        usedWork += required;
        if (cast(ulong) combined.advance <= budget.value && (suffix ? i < selected : i >= selected))
        { selected = i; measured = combined.advance; }
    }
    const start = suffix ? (selected < clusters ? scratch.clusters[selected].start : source.bytes.length) : 0;
    const end = suffix ? source.bytes.length : selected ? scratch.clusters[selected - 1].end : 0;
    outFit = CellFit(text: source.bytes[start .. end], replacement: replacement, start: start, end: end,
        replacementAnchor: suffix ? start : end, advance: CellExtent(cast(ulong) measured));
    return WrapResult.init;
}

/// Explicitly allocating adapter. Retried scratch allocation does not relax
/// exactness, policies, or measurements; the caller-bounded operation above is
/// the allocation-free authority.
WrapPlan cellWrapPlan(const(char)[] text, WrapOptions options = WrapOptions.init,
    scope void delegate() @safe measurePending = null) @safe
{
    import std.exception : enforce;
    import std.conv : to;
    if (text.length > (size_t.max - 128) / 64) throw new Exception("cell wrapping size exhausted");
    const records = text.length + 2;
    // Plain emission needs at most one fragment per source byte. Tabs, indent
    // and style continuity grow the fragment arena through the exact retry.
    size_t stateCapacity = options.solver == WrapSolver.greedy ? records : 128;
    size_t fragmentCapacity = records + 64;
    const geometryRecords = options.geometry.length ? options.geometry.length : 2;
    enforce(geometryRecords < size_t.max - records, "cell wrapping geometry storage exhausted");
    size_t styleCapacity = records + geometryRecords + 1;
    foreach (i; 0 .. geometryRecords)
    {
        const indent = options.geometry.length ? options.geometry[i].indent : i ? options.indent : options.firstIndent;
        enforce(indent.length <= size_t.max - styleCapacity, "cell wrapping indent storage exhausted");
        styleCapacity += indent.length;
    }
    CellWrapScratch scratch;
    scratch.tokens = new UtfToken[](records);
    scratch.atoms = new CellAtom[](records);
    scratch.clusters = new CellCluster[](records);
    scratch.opportunities = new UnicodeBoundary[](records);
    if (options.opportunities == CellOpportunityPolicy.wordPreserving)
    {
        scratch.words = new UnicodeBoundary[](records);
        scratch.wordWorkspace = new WordBoundaryWorkspace[](records);
    }
    scratch.lineWorkspace = new LineBreakWorkspaceEntry[](records);
    scratch.primitives = new WrapPrimitive[](records);
    scratch.endpoints = new WrapEndpoint[](records);
    scratch.sourceRecords = new SourceRecord[](records);
    scratch.solver.selected = new size_t[](records);
    scratch.solver.ranked = new size_t[](1);
    scratch.solver.ids = new ulong[](records);
    scratch.solver.temporaryIds = new ulong[](records);
    scratch.geometry = new WrapGeometry[](geometryRecords);
    scratch.indentStyles = new CellStyleSnapshot[](geometryRecords);
    scratch.indentStyleStarts = new size_t[](geometryRecords);
    for (;;)
    {
        scratch.styles = new CellStyleSnapshot[](styleCapacity);
        scratch.solver.states = new WrapSearchState[](stateCapacity);
        scratch.solver.ordering = new size_t[](stateCapacity);
        scratch.solver.temporary = new size_t[](stateCapacity);
        enforce(styleCapacity <= size_t.max / 2, "cell wrapping style transition storage exhausted");
        scratch.styleTransitions = new size_t[](styleCapacity * 2);
        scratch.candidateFragments = new WrapFragment[](fragmentCapacity);
        scratch.realizedFragments = new WrapFragment[](fragmentCapacity);
        scratch.solver.projection = WrapProjectionScratch(new WrapLine[](records),
            new WrapFragment[](fragmentCapacity), new SourceRecord[](records), new CellStyleSnapshot[](styleCapacity));
        WrapPlanStorage storage = WrapPlanStorage(new WrapLine[](records),
            new WrapFragment[](fragmentCapacity), new SourceRecord[](records), new CellStyleSnapshot[](styleCapacity));
        WrapLimits limits = WrapLimits(size_t.max, size_t.max, size_t.max, size_t.max,
            size_t.max, size_t.max, size_t.max, size_t.max);
        WrapPlan plan;
        WrapResult r;
        for (;;)
        {
            r = tryWrapCells(SourceSnapshot(text), options, limits, scratch, storage, plan);
            if (r.status != WrapStatus.needResults || measurePending is null) break;
            measurePending();
        }
        if (r.status == WrapStatus.needScratch || r.status == WrapStatus.needPlanStorage)
        {
            enforce(stateCapacity <= size_t.max / 2 && fragmentCapacity <= size_t.max / 2
                && styleCapacity <= size_t.max / 2, "cell wrapping storage exhausted");
            stateCapacity *= 2; fragmentCapacity *= 2; styleCapacity *= 2;
            continue;
        }
        enforce(r.succeeded, "cell wrapping failed: " ~ r.status.to!string);
        return plan;
    }
}

string wrapText(const(char)[] text, WrapOptions options = WrapOptions.init) @safe
{
    import std.exception : enforce, assumeUnique;
    const plan = cellWrapPlan(text, options);
    size_t extent;
    auto r = tryMaterializeWrap(plan, WrapEmissionOptions.init, null, extent);
    enforce(r.succeeded || r.status == WrapStatus.needOutput, "wrap emission invalid");
    char[] output = new char[](r.required);
    r = tryMaterializeWrap(plan, WrapEmissionOptions.init, output, extent);
    enforce(r.succeeded, "wrap emission failed");
    // This freshly allocated buffer is disjoint and only the validated emitter
    // has written it; no mutable alias survives the ownership transfer.
    return (() @trusted { return assumeUnique(output); })();
}

void writeWrappedText(Writer, Text)(ref Writer writer, Text text, WrapOptions options = WrapOptions.init)
{
    import std.range.primitives : put, isInputRange, ElementType;
    import std.traits : isSomeChar;
    import sparkles.base.buffer : SharedBuffer;
    import sparkles.base.text.utf : encodeScalar;
    static if (is(Text : const(char)[])) put(writer, wrapText(text, options));
    else
    {
        SharedBuffer!(char, 256) gathered;
        static if (isInputRange!Text && is(ElementType!Text : const(char)[]))
            foreach (chunk; text) gathered.put(chunk);
        else static if (isInputRange!Text && isSomeChar!(ElementType!Text))
            foreach (value; text)
            {
                static if (is(typeof(value) == char)) gathered.put(value);
                else
                {
                    char[4] encoded;
                    const result = encodeScalar(cast(dchar) value, encoded[]);
                    if (result.status != UtfStatus.ok) throw new Exception("invalid wrapping scalar");
                    gathered.put(encoded[0 .. result.written]);
                }
            }
        else static assert(false, "wrapping input must be UTF-8 bytes, chunks, or Unicode scalars");
        put(writer, wrapText(gathered[], options));
    }
}

/// Allocating, eagerly rendered forward range. Range iteration does not allocate;
/// construction gathers all input and selects the complete plan. For bounded
/// @nogc work use tryWrapCells with caller-owned scratch and plan storage.
struct WrappedLines
{
    private string _rendered;
    private size_t _start, _end;
    private bool _done;
    private void scan() @safe pure nothrow @nogc
    {
        _end = _start;
        while (_end < _rendered.length && _rendered[_end] != '\n') ++_end;
    }
    bool empty() const @safe pure nothrow @nogc => _done;
    const(char)[] front() const @safe pure nothrow @nogc => _rendered[_start .. _end];
    void popFront() @safe pure nothrow @nogc
    {
        if (_end == _rendered.length) { _done = true; return; }
        _start = _end + 1; scan();
    }
    typeof(this) save() @safe pure nothrow @nogc => this;
}
WrappedLines byWrappedLine(Text)(Text text, WrapOptions options = WrapOptions.init)
{
    import std.array : appender;
    auto writer = appender!string;
    writeWrappedText(writer, text, options);
    WrappedLines result;
    result._rendered = writer[];
    result.scan();
    return result;
}

/// Allocating, eagerly rendered emission chunks, not a streaming input wrapper
/// or an independently selected wrapping representation.
struct WrappedChunks(bool lineBuffered = true)
{
    private string _rendered;
    private size_t _start, _end;
    private size_t[] _ends;
    private size_t _chunk;
    private void configureChunks(WrapOptions options) @safe
    {
        import std.exception : enforce;
        enforce(_rendered.length < size_t.max, "chunk storage exhausted");
        auto tokens = new UtfToken[](_rendered.length + 1);
        auto boundaries = new bool[](tokens.length);
        GraphemeBreakState state;
        CellStyleSnapshot style;
        size_t offset, count;
        bool opaque;
        while (offset < _rendered.length)
        {
            if (_rendered[offset] == '\x1b' && options.formatting != FormattingPolicy.literal)
            {
                size_t consumed;
                CellStyleSnapshot after;
                const r = parseFormatting(_rendered, offset, options.formatting, options.continuity, style, after, consumed);
                enforce(r.succeeded, "invalid emitted chunk formatting");
                style = after; offset += consumed; continue;
            }
            const decoded = decodeToken(_rendered[offset .. $], options.malformed, true, offset);
            enforce(decoded.result.status == UtfStatus.ok, "invalid emitted chunk encoding");
            const token = decoded.token;
            if (token.kind == UtfTokenKind.opaqueByte)
            { state.reset(); boundaries[count] = true; opaque = true; }
            else
            {
                if (opaque) state.reset();
                boundaries[count] = state.push(token.scalar); opaque = false;
            }
            tokens[count++] = token; offset = token.end;
        }
        auto opportunities = new UnicodeBoundary[](count + 1);
        auto workspace = new LineBreakWorkspaceEntry[](count);
        const classified = lineOpportunities(tokens[0 .. count], opportunities, workspace);
        enforce(classified.succeeded(), "chunk opportunity storage exhausted");
        enforce(count <= (size_t.max - 1) / 2, "chunk storage exhausted");
        _ends = new size_t[](count * 2 + 1);
        size_t used, previous;
        void appendEnd(size_t end)
        {
            if (end > previous) { _ends[used++] = end; previous = end; }
        }
        foreach (i; 0 .. count)
        {
            const token = tokens[i];
            if (token.kind != UtfTokenKind.opaqueByte && token.scalar == '\n')
            { appendEnd(token.start); appendEnd(token.end); }
            else if (opportunities[i + 1].kind != UnicodeBoundaryKind.prohibited
                && (i + 1 == count || boundaries[i + 1])) appendEnd(token.end);
        }
        appendEnd(_rendered.length);
        _ends = _ends[0 .. used];
    }
    private void scan() @safe pure nothrow @nogc
    {
        if (_start == _rendered.length) { _end = _start; return; }
        static if (lineBuffered)
        {
            if (_rendered[_start] == '\n') { _end = _start + 1; return; }
            _end = _start;
            while (_end < _rendered.length && _rendered[_end] != '\n') ++_end;
        }
        else
        {
            _end = _ends[_chunk];
        }
    }
    bool empty() const @safe pure nothrow @nogc => _start == _rendered.length;
    const(char)[] front() const @safe pure nothrow @nogc => _rendered[_start .. _end];
    void popFront() @safe pure nothrow @nogc
    {
        _start = _end;
        static if (!lineBuffered) ++_chunk;
        scan();
    }
    typeof(this) save() @safe pure nothrow @nogc => this;
}
WrappedChunks!lineBuffered byWrappedChunk(bool lineBuffered = true, Text)(
    Text text, WrapOptions options = WrapOptions.init)
{
    import std.array : appender;
    auto writer = appender!string;
    writeWrappedText(writer, text, options);
    WrappedChunks!lineBuffered result;
    result._rendered = writer[];
    static if (!lineBuffered) result.configureChunks(options);
    result.scan();
    return result;
}

/// A bounded emitted projection retains its original selected plan and objective.
/// It is not a second line-selection algorithm or a claim of a new optimum.
struct CellWrapProjection
{
    WrapPlan selected;
    WrapPlan visible;
}

private struct CellClipBuilder
{
    const(WrapFragment)[] input;
    WrapFragment[] output;
    SourceRecord[] records;
    size_t used, recordCursor;
    long capacity, advance, indentAdvance;
    bool prefixOpen = true;
    bool clipped;

    WrapResult append(WrapFragment fragment) @safe nothrow @nogc
    {
        if (used == output.length) return cellScratch();
        output[used++] = fragment;
        return WrapResult.init;
    }
    WrapResult omit(WrapFragment fragment) @safe nothrow @nogc
    {
        if (fragment.provenance != ProvenanceKind.synthetic)
        {
            if (fragment.sourceRecordOrdinal != size_t.max)
            {
                const ordinal = fragment.sourceRecordOrdinal;
                if (ordinal >= records.length || records[ordinal].ordinal != ordinal
                    || records[ordinal].start != fragment.consumedStart
                    || records[ordinal].end != fragment.consumedEnd) return invalidCell();
                if (!records[ordinal].formatting) records[ordinal].kind = ProvenanceKind.omission;
            }
            else
            {
                while (recordCursor < records.length && records[recordCursor].end <= fragment.consumedStart) ++recordCursor;
                size_t index = recordCursor;
                while (index < records.length && records[index].start < fragment.consumedEnd)
                {
                    if (!records[index].formatting) records[index].kind = ProvenanceKind.omission;
                    ++index;
                }
                recordCursor = index;
            }
            fragment.provenance = ProvenanceKind.omission;
        }
        fragment.kind = FragmentKind.anchor;
        fragment.advance = 0;
        fragment.omitted = true;
        fragment.clusterProvenance = fragment.provenance;
        clipped = true;
        return append(fragment);
    }
    WrapResult emit(WrapFragment fragment, bool retain) @safe nothrow @nogc
    {
        if (fragment.formatting || fragment.omitted) return append(fragment);
        if (!retain) return omit(fragment);
        auto r = checkedCellAdd(advance, fragment.advance, advance);
        if (!r.succeeded) return r;
        if (fragment.reason == SyntheticReason.indent)
        { r = checkedCellAdd(indentAdvance, fragment.advance, indentAdvance); if (!r.succeeded) return r; }
        return append(fragment);
    }

}

/// Prefix clipping is a projection over the already committed cluster plan.
/// Removed glyphs become explicit zero-advance omission/anchor fragments. Style
/// actions are retained even past the visible prefix, preserving declared final
/// state and selected line suspension/resumption. No solver or measurer is called.
/// Capacity includes indentation; tabs retain their selected whole-unit advance.
WrapResult tryProjectWrapCells(const ref WrapPlan selected, CellExtent capacity,
    WrapLimits limits, WrapProjectionScratch scratch, WrapPlanStorage storage,
    ref CellWrapProjection outProjection) @safe nothrow @nogc
{
    if (selected.dimension != WrapDimension.cells || selected.cellPolicy != CellPolicy.terminalKitty
        || selected.cellPolicyRevision != terminalKittyRevision)
        return WrapResult(status: WrapStatus.unsupportedCapability, phase: WrapPhase.projection);
    if (capacity.value > long.max) return cellArithmetic();
    import sparkles.base.text.utf : utfObjectStorage;
    if (!wrapStorageAvoids(utfObjectStorage(outProjection), scratch.lines, scratch.fragments,
            scratch.sourceRecords, scratch.styles, storage.lines, storage.fragments,
            storage.sourceRecords, storage.styles)) return invalidCell();
    if (!wrapStorageDisjoint(scratch.lines, scratch.fragments, scratch.sourceRecords, scratch.styles,
            storage.lines, storage.fragments, storage.sourceRecords, storage.styles)
        || !wrapPlanAvoids(selected, scratch.lines, scratch.fragments, scratch.sourceRecords, scratch.styles,
            storage.lines, storage.fragments, storage.sourceRecords, storage.styles)
        || !wrapPlanAvoids(outProjection.visible, scratch.lines, scratch.fragments, scratch.sourceRecords, scratch.styles,
            storage.lines, storage.fragments, storage.sourceRecords, storage.styles)
        || !wrapPlanAvoids(outProjection.selected, scratch.lines, scratch.fragments, scratch.sourceRecords, scratch.styles,
            storage.lines, storage.fragments, storage.sourceRecords, storage.styles))
        return invalidCell();
    if (selected.source.bytes.length > limits.sourceBytes)
        return WrapResult(status: WrapStatus.budgetExhausted, kind: WrapBudgetKind.sourceBytes,
            used: selected.source.bytes.length, limit: limits.sourceBytes);
    if (selected.lines.length > size_t.max - selected.fragments.length
        || selected.sourceRecords.length > size_t.max - selected.lines.length - selected.fragments.length)
        return cellArithmetic();
    const inputRecords = selected.lines.length + selected.fragments.length + selected.sourceRecords.length;
    if (inputRecords > limits.inputRecords)
        return WrapResult(status: WrapStatus.budgetExhausted, kind: WrapBudgetKind.inputRecords,
            used: inputRecords, limit: limits.inputRecords);
    if (scratch.lines.length < selected.lines.length || scratch.sourceRecords.length < selected.sourceRecords.length)
        return cellScratch();
    scratch.sourceRecords[0 .. selected.sourceRecords.length] = selected.sourceRecords[];
    CellClipBuilder builder = CellClipBuilder(input: selected.fragments, output: scratch.fragments,
        records: scratch.sourceRecords[0 .. selected.sourceRecords.length], capacity: cast(long) capacity.value);
    size_t work;
    foreach (i, ref const sourceLine; selected.lines)
    {
        if (sourceLine.fragmentsStart > sourceLine.fragmentsEnd || sourceLine.fragmentsEnd > selected.fragments.length
            || sourceLine.startColumn < 0 || sourceLine.opaqueMaterialization) return invalidCell();
        const first = builder.used;
        builder.advance = 0; builder.indentAdvance = 0; builder.prefixOpen = true; builder.clipped = false;
        size_t cursor = sourceLine.fragmentsStart;
        while (cursor < sourceLine.fragmentsEnd)
        {
            const fragment = selected.fragments[cursor];
            if (fragment.advance < 0) return WrapResult(status: WrapStatus.unsupportedCapability, phase: WrapPhase.projection);
            if (fragment.clusterOrdinal == ulong.max && (fragment.formatting || fragment.omitted || fragment.kind == FragmentKind.anchor))
            {
                auto r = builder.append(fragment); if (!r.succeeded) return r;
                ++cursor; continue;
            }
            size_t end = cursor + 1;
            long advance = fragment.advance;
            if (fragment.clusterOrdinal == ulong.max)
                return WrapResult(status: WrapStatus.unsupportedCapability, phase: WrapPhase.projection);
            while (end < sourceLine.fragmentsEnd
                && selected.fragments[end].clusterOrdinal == fragment.clusterOrdinal)
            {
                auto r = checkedCellAdd(advance, selected.fragments[end].advance, advance); if (!r.succeeded) return r;
                ++end;
            }
            const remaining = builder.capacity - builder.advance;
            const retain = builder.prefixOpen && advance <= remaining;
            size_t runIndex = cursor;
            while (runIndex < end && (selected.fragments[runIndex].formatting
                || selected.fragments[runIndex].omitted || selected.fragments[runIndex].kind == FragmentKind.anchor)) ++runIndex;
            const run = selected.fragments[runIndex < end ? runIndex : cursor];
            const partialSpaces = builder.prefixOpen && !retain && remaining > 0 && runIndex < end
                && (run.kind == FragmentKind.spaces || run.kind == FragmentKind.glue)
                && run.repeat > 1 && run.advance == run.repeat && advance == run.advance;
            if (!retain) builder.prefixOpen = false;
            foreach (j; cursor .. end)
            {
                WrapFragment projected = selected.fragments[j];
                if (partialSpaces && j == runIndex)
                {
                    projected.repeat = cast(ulong) remaining; projected.advance = remaining;
                    projected.clusterCount = projected.repeat; projected.clusterProvenance = ProvenanceKind.replacement;
                    auto r = builder.emit(projected, true); if (!r.succeeded) return r;
                    WrapFragment omitted = run;
                    omitted.kind = FragmentKind.anchor; omitted.repeat = 0; omitted.advance = 0;
                    omitted.provenance = ProvenanceKind.synthetic; omitted.clusterProvenance = ProvenanceKind.omission;
                    omitted.anchor = run.consumedEnd; omitted.consumedStart = omitted.consumedEnd;
                    omitted.sourceRecordOrdinal = size_t.max; omitted.omitted = true;
                    r = builder.append(omitted); if (!r.succeeded) return r;
                    builder.clipped = true;
                }
                else
                {
                    if (!retain) projected.clusterProvenance = partialSpaces ? ProvenanceKind.replacement : ProvenanceKind.omission;
                    auto r = builder.emit(projected, retain); if (!r.succeeded) return r;
                }
            }
            cursor = end;
        }
        WrapLine visible = sourceLine;
        visible.fragmentsStart = first; visible.fragmentsEnd = builder.used;
        visible.indentExtent = builder.indentAdvance;
        visible.contentAdvance = builder.advance - builder.indentAdvance;
        visible.visibleAdvance = builder.advance;
        visible.originalContentAdvance = sourceLine.clipped ? sourceLine.originalContentAdvance : sourceLine.contentAdvance;
        visible.capacity = cast(long) capacity.value; visible.unbounded = false;
        visible.clipped = sourceLine.clipped || builder.clipped;
        auto r = checkedCellAdd(visible.startColumn, builder.advance, visible.endColumn); if (!r.succeeded) return r;
        scratch.lines[i] = visible;
    }
    if (selected.lines.length > size_t.max - selected.sourceRecords.length
        || builder.used > size_t.max - selected.lines.length - selected.sourceRecords.length) return cellArithmetic();
    const records = selected.lines.length + selected.sourceRecords.length + builder.used;
    if (records > limits.outputRecords)
        return WrapResult(status: WrapStatus.budgetExhausted, kind: WrapBudgetKind.outputRecords, used: records, limit: limits.outputRecords);
    WrapPlan prepared = selected;
    prepared.lines = scratch.lines[0 .. selected.lines.length];
    prepared.fragments = scratch.fragments[0 .. builder.used];
    prepared.sourceRecords = scratch.sourceRecords[0 .. selected.sourceRecords.length];
    prepared.styles = null;
    prepared.projection = true;
    prepared.usage = WrapUsage(sourceBytes: selected.source.bytes.length, inputRecords: inputRecords,
        providerWork: work, outputRecords: records);
    WrapPlan published;
    auto r = publishWrapPlan(prepared, scratch, storage, published);
    if (!r.succeeded) return r;
    published.styles = selected.styles;
    outProjection = CellWrapProjection(selected, published);
    return WrapResult.init;
}

/// Explicitly allocating UI/table projection adapter, never new selection.
CellWrapProjection projectWrapCells(const ref WrapPlan selected, CellExtent capacity) @safe
{
    import std.exception : enforce;
    const fragments = selected.fragments.length * 2;
    enforce(fragments / 2 == selected.fragments.length, "cell projection size exhausted");
    WrapProjectionScratch scratch = WrapProjectionScratch(new WrapLine[](selected.lines.length),
        new WrapFragment[](fragments), new SourceRecord[](selected.sourceRecords.length));
    WrapPlanStorage storage = WrapPlanStorage(new WrapLine[](selected.lines.length),
        new WrapFragment[](fragments), new SourceRecord[](selected.sourceRecords.length));
    WrapLimits limits = WrapLimits(size_t.max, size_t.max, size_t.max, size_t.max,
        size_t.max, size_t.max, size_t.max, size_t.max);
    CellWrapProjection projection;
    const r = tryProjectWrapCells(selected, capacity, limits, scratch, storage, projection);
    enforce(r.succeeded, "cell projection failed");
    return projection;
}
