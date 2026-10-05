/** Whole emitted-stream cell measurement and immutable cluster projection. */
module sparkles.base.text.wrap_cells_project;

import sparkles.base.text.wrap_plan;
import sparkles.base.text.wrap : WrapOptions, TabPolicy, FormattingPolicy, StyleContinuity, parseFormatting, nextTab;
import sparkles.base.text.utf : UtfMode, UtfStatus, UtfToken, UtfTokenKind, decodeToken, utfStorageOverlaps, utfObjectStorage;
import sparkles.base.text.grapheme : GraphemeBreakState;
import sparkles.base.text.width : ClusterWidthState;
import sparkles.base.text.layout_units : LayoutUnit, UnitStatus, checkedAdd;

@safe nothrow @nogc:

struct RealizedCellProjection
{
    size_t written;
    long advance, indentAdvance;
    GraphemeBreakState trailing;
    bool trailingOpaque;
    UtfToken first;
    bool hasText, hasSourceText;
    ulong bodyClusters;
}

/// Selected realization carries the emitted style through copy-through lines.
/// The initial prefix is immutable; only newly derived transition states append.
struct CellProjectionStyles
{
    CellStyleSnapshot[] snapshots;
    size_t used, live;
    size_t limit = size_t.max;
    bool inherit;
    size_t[] transitions;
    size_t fixedCount;

    WrapResult transition(CellStyleSnapshot after, size_t preferred, ref size_t ordinal,
        size_t cacheKey = size_t.max) scope @safe nothrow @nogc
    {
        bool same(CellStyleSnapshot a, CellStyleSnapshot b) @safe pure nothrow @nogc
            => a.attributes == b.attributes && a.underline == b.underline && a.foreground == b.foreground
                && a.background == b.background && a.underlineColor == b.underlineColor
                && a.linkOpen == b.linkOpen && a.customRestore == b.customRestore && a.opaque == b.opaque;
        if (cacheKey < transitions.length && transitions[cacheKey] < used
            && same(after, snapshots[transitions[cacheKey]])) ordinal = transitions[cacheKey];
        else if (preferred < used && same(after, snapshots[preferred])) ordinal = preferred;
        else if (live < used && same(after, snapshots[live])) ordinal = live;
        else
        {
            if (used >= limit) return WrapResult(status: WrapStatus.budgetExhausted,
                phase: WrapPhase.projection, kind: WrapBudgetKind.outputRecords, used: used, limit: limit, required: 1);
            if (used == snapshots.length) return WrapResult(status: WrapStatus.needScratch,
                phase: WrapPhase.projection, required: 1);
            ordinal = used;
            after.id = ordinal;
            snapshots[used++] = after;
        }
        live = ordinal;
        if (cacheKey < transitions.length) transitions[cacheKey] = ordinal;
        return WrapResult.init;
    }
}
private WrapResult arithmetic() => WrapResult(status: WrapStatus.arithmeticExhausted, phase: WrapPhase.projection);
private WrapResult add(long a, long b, ref long outValue)
{
    LayoutUnit sum;
    if (checkedAdd(LayoutUnit(a), LayoutUnit(b), sum) != UnitStatus.ok) return arithmetic();
    outValue = sum.raw;
    return WrapResult.init;
}
private struct StreamProjector
{
    WrapOptions options;
    long startColumn;
    WrapFragment[] output;
    size_t used, groupStart, textEnd;
    ulong ordinal, groupCount = 1;
    long closed, indentAdvance, extra;
    GraphemeBreakState breaks;
    ClusterWidthState width;
    bool have, opaque, lastOpaque, tab;
    long tabAdvance;
    UtfToken first;
    bool hasText, hasSourceText;
    ulong bodyClusters;
    const(CellStyleSnapshot)[] snapshots;
    CellProjectionStyles* styles;

    WrapResult append(WrapFragment fragment) scope @safe nothrow @nogc
    {
        if (used == output.length) return WrapResult(status: WrapStatus.needScratch, phase: WrapPhase.projection, required: 1);
        fragment.advance = 0;
        fragment.clusterOrdinal = ulong.max;
        output[used++] = fragment;
        return WrapResult.init;
    }
    WrapResult finish(size_t end) scope @safe nothrow @nogc
    {
        if (!have) return WrapResult.init;
        long advance = opaque ? 1 : tab ? tabAdvance : width.width;
        auto r = add(advance, extra, advance); if (!r.succeeded) return r;
        size_t sourceStart = size_t.max, sourceEnd;
        bool syntheticText, transformed, haveSource, sourceText;
        size_t expected;
        bool contiguous = true;
        foreach (ref const fragment; output[groupStart .. end])
        {
            if (fragment.provenance == ProvenanceKind.synthetic)
            {
                if (!fragment.formatting)
                {
                    syntheticText = true;
                    sourceText |= fragment.reason == SyntheticReason.hyphen;
                }
                continue;
            }
            if (fragment.consumedStart < sourceStart) sourceStart = fragment.consumedStart;
            sourceText |= !fragment.formatting && fragment.kind != FragmentKind.anchor;
            if (fragment.consumedEnd > sourceEnd) sourceEnd = fragment.consumedEnd;
            if (haveSource && expected != fragment.consumedStart) contiguous = false;
            expected = fragment.consumedEnd; haveSource = true;
            transformed |= fragment.provenance != ProvenanceKind.original;
        }
        if (!haveSource)
        {
            sourceStart = groupStart < end ? output[groupStart].anchor : 0;
            sourceEnd = sourceStart;
        }
        const provenance = !haveSource ? ProvenanceKind.synthetic
            : syntheticText || transformed || !contiguous ? ProvenanceKind.replacement : ProvenanceKind.original;
        bool assigned;
        foreach (ref fragment; output[groupStart .. end])
        {
            fragment.clusterOrdinal = ordinal;
            fragment.clusterSourceStart = sourceStart;
            fragment.clusterSourceEnd = sourceEnd;
            fragment.clusterProvenance = provenance;
            fragment.clusterCount = groupCount;
            if (fragment.provenance != ProvenanceKind.synthetic)
            { fragment.sourceStart = sourceStart; fragment.sourceEnd = sourceEnd; }
            if (!fragment.formatting && !assigned)
            {
                fragment.advance = advance; assigned = true;
                if (fragment.reason == SyntheticReason.indent)
                { r = add(indentAdvance, advance, indentAdvance); if (!r.succeeded) return r; }
            }
        }
        r = add(closed, advance, closed); if (!r.succeeded) return r;
        if (sourceText)
        {
            hasSourceText = true;
            if (groupCount > ulong.max - bodyClusters) return arithmetic();
            bodyClusters += groupCount;
        }
        if (groupCount > ulong.max - ordinal) return arithmetic();
        ordinal += groupCount;
        groupStart = end;
        have = false;
        extra = 0; groupCount = 1; tab = false; opaque = false;
        width = ClusterWidthState.init;
        return WrapResult.init;
    }
    WrapResult currentColumn(ref long column) scope @safe nothrow @nogc
    {
        long advance = have ? (opaque ? 1 : tab ? tabAdvance : width.width) : 0;
        auto r = add(advance, extra, advance); if (!r.succeeded) return r;
        r = add(closed, advance, advance); if (!r.succeeded) return r;
        return add(startColumn, advance, column);
    }
    WrapResult scalar(UtfToken token, WrapFragment fragment) scope @safe nothrow @nogc
    {
        const isOpaque = token.kind == UtfTokenKind.opaqueByte;
        if (!hasText) { first = token; hasText = true; }
        bool boundary;
        if (isOpaque) { breaks.reset(); boundary = true; }
        else
        {
            if (lastOpaque) breaks.reset();
            boundary = breaks.push(token.scalar);
        }
        if (boundary && have)
        { auto r = finish(textEnd); if (!r.succeeded) return r; }
        if (!have) { groupStart = used; have = true; opaque = isOpaque; }
        lastOpaque = isOpaque;
        if (!isOpaque) width.push(token.scalar, false);
        auto r = append(fragment); if (!r.succeeded) return r;
        textEnd = used;
        return WrapResult.init;
    }
    WrapResult spaces(WrapFragment original, ulong count) scope @safe nothrow @nogc
    {
        if (!count) return WrapResult.init;
        auto fragment = original;
        fragment.kind = FragmentKind.spaces; fragment.bytes = null; fragment.repeat = 1;
        auto r = scalar(UtfToken(scalar: ' '), fragment); if (!r.succeeded) return r;
        if (count > 1)
        {
            fragment.repeat = count - 1;
            r = scalar(UtfToken(scalar: ' '), fragment); if (!r.succeeded) return r;
            if (count - 2 > long.max) return arithmetic();
            extra = cast(long) (count - 2);
            groupCount = count - 1;
        }
        return WrapResult.init;
    }
    WrapResult consume(WrapFragment original) scope @safe nothrow @nogc
    {
        if (original.kind == FragmentKind.anchor)
        {
            if (styles is null) return append(original);
            auto anchor = original;
            anchor.styleBefore = anchor.styleAfter = styles.live;
            return append(anchor);
        }
        if (original.formatting)
        {
            auto fragment = original;
            if (styles !is null)
            {
                if (original.styleAfter >= styles.used) return WrapResult(status: WrapStatus.invalidInput);
                fragment.styleBefore = styles.live;
                if (original.reason == SyntheticReason.styleSuspend
                    || styles.inherit && original.provenance != ProvenanceKind.synthetic)
                {
                    auto state = styles.snapshots[styles.live];
                    size_t cursor;
                    while (cursor < original.bytes.length)
                    {
                        if (original.bytes[cursor] != '\x1B')
                            return WrapResult(status: WrapStatus.invalidFormatting, phase: WrapPhase.projection,
                                sourceStart: original.consumedStart, sourceEnd: original.consumedEnd);
                        CellStyleSnapshot after;
                        size_t consumed;
                        auto r = parseFormatting(original.bytes, cursor, options.formatting, options.continuity,
                            state, after, consumed); if (!r.succeeded) return r;
                        state = after; cursor += consumed;
                    }
                    if (original.reason != SyntheticReason.styleSuspend && options.styleProvider.transition !is null)
                    {
                        const declared = styles.snapshots[cast(size_t) original.styleAfter];
                        state.customRestore = declared.customRestore;
                        state.opaque |= declared.opaque;
                    }
                    size_t next;
                    size_t cacheKey = size_t.max;
                    if (original.reason == SyntheticReason.styleSuspend
                        && original.bytes.length > 1 && original.bytes[1] == ']'
                        && original.styleBefore < styles.fixedCount)
                        cacheKey = styles.fixedCount + cast(size_t) original.styleBefore;
                    auto r = styles.transition(state, cast(size_t) original.styleAfter, next, cacheKey);
                    if (!r.succeeded) return r;
                    fragment.styleAfter = next;
                }
                else styles.live = cast(size_t) original.styleAfter;
            }
            return append(fragment);
        }
        auto current = original;
        if (styles !is null && styles.inherit)
            current.styleBefore = current.styleAfter = styles.live;
        if (current.kind == FragmentKind.spaces || current.kind == FragmentKind.glue)
            return spaces(current, current.repeat);
        size_t offset;
        size_t style = cast(size_t) current.styleBefore;
        size_t declaredStyle = cast(size_t) original.styleBefore;
        CellStyleSnapshot styleState;
        if (styles !is null) styleState = styles.snapshots[styles.live];
        else if (style < snapshots.length) styleState = snapshots[style];
        while (offset < original.bytes.length)
        {
            auto fragment = current;
            if (original.provenance == ProvenanceKind.synthetic
                && (original.reason == SyntheticReason.indent
                    || original.reason == SyntheticReason.replacement && options.formatting != FormattingPolicy.literal)
                && original.bytes[offset] == '\x1B')
            {
                size_t consumed;
                CellStyleSnapshot after;
                auto r = parseFormatting(original.bytes, offset, FormattingPolicy.rejectUnknown,
                    StyleContinuity.suspendResume, styleState, after, consumed);
                if (!r.succeeded) return r;
                fragment.bytes = original.bytes[offset .. offset + consumed];
                fragment.formatting = true;
                fragment.styleBefore = style;
                if (styles !is null && styles.inherit)
                {
                    size_t preferred = size_t.max;
                    if (original.reason == SyntheticReason.indent && styles.fixedCount
                        && declaredStyle < styles.fixedCount - 1)
                        preferred = ++declaredStyle;
                    r = styles.transition(after, preferred, style, preferred); if (!r.succeeded) return r;
                }
                else if (original.reason == SyntheticReason.indent && snapshots.length)
                {
                    if (style == size_t.max || style + 1 >= snapshots.length)
                        return WrapResult(status: WrapStatus.invalidInput, phase: WrapPhase.projection);
                    ++style;
                    after = snapshots[style];
                    if (styles !is null) styles.live = style;
                }
                fragment.styleAfter = style;
                r = append(fragment); if (!r.succeeded) return r;
                styleState = after; offset += consumed;
                continue;
            }
            const mode = original.provenance == ProvenanceKind.synthetic ? UtfMode.strict : options.malformed;
            const decoded = decodeToken(original.bytes[offset .. $], mode, true, offset);
            if (decoded.result.status != UtfStatus.ok)
                return WrapResult(status: WrapStatus.invalidEncoding, phase: WrapPhase.projection,
                    sourceStart: original.consumedStart, sourceEnd: original.consumedEnd);
            fragment.bytes = original.bytes[offset .. decoded.token.end];
            if (original.provenance == ProvenanceKind.synthetic && original.reason == SyntheticReason.indent
                || styles !is null && styles.inherit)
                fragment.styleBefore = fragment.styleAfter = style;
            if (decoded.token.kind != UtfTokenKind.opaqueByte && decoded.token.scalar == '\t')
            {
                long column, distance;
                auto r = currentColumn(column); if (!r.succeeded) return r;
                r = nextTab(column, options.tabStops, distance); if (!r.succeeded) return r;
                if (options.tabs == TabPolicy.expand)
                {
                    fragment.provenance = ProvenanceKind.replacement;
                    r = spaces(fragment, cast(ulong) distance); if (!r.succeeded) return r;
                }
                else
                {
                    r = scalar(decoded.token, fragment); if (!r.succeeded) return r;
                    tab = true; tabAdvance = distance;
                    output[used - 1].terminalTab = true;
                }
            }
            else
            {
                auto r = scalar(decoded.token, fragment); if (!r.succeeded) return r;
            }
            offset = decoded.token.end;
        }
        return WrapResult.init;
    }
}

/// Raw descriptors may omit/rewrite source; only this emitted stream defines
/// widths and projected clusters. Formatting never pushes or resets GCB state.
/// Repeated expansion spaces use two scalar pushes plus checked run arithmetic.
WrapResult realizeCellProjection(const(WrapFragment)[] raw, WrapOptions options,
    long startColumn, WrapFragment[] output, ref RealizedCellProjection result,
    const(CellStyleSnapshot)[] snapshots = null, scope CellProjectionStyles* styles = null)
{
    if (startColumn < 0 || utfStorageOverlaps(raw, output) || utfStorageOverlaps(snapshots, output)
        || utfStorageOverlaps(options.tabStops.explicitStops, output)
        || !wrapStorageAvoids(utfObjectStorage(result), raw, snapshots, output, options.tabStops.explicitStops))
        return WrapResult(status: WrapStatus.invalidInput);
    if (styles !is null && (styles.used > styles.snapshots.length || styles.live >= styles.used
        || styles.fixedCount > styles.used
        || utfStorageOverlaps(snapshots, styles.transitions)
        || utfStorageOverlaps(snapshots, styles.snapshots)
            && (snapshots.ptr != styles.snapshots.ptr || snapshots.length > styles.used)
        || !wrapStorageAvoids(options.tabStops.explicitStops, styles.snapshots, styles.transitions)
        || !wrapStorageDisjoint(styles.snapshots, styles.transitions, raw, output)
        || !wrapStorageAvoids(utfObjectStorage(*styles), styles.snapshots, styles.transitions, raw, output)
        || !wrapStorageAvoids(utfObjectStorage(result), styles.snapshots, styles.transitions, utfObjectStorage(*styles))))
        return WrapResult(status: WrapStatus.invalidInput);
    foreach (ref const fragment; raw)
        if (utfStorageOverlaps(fragment.bytes, output)
            || styles !is null && !wrapStorageAvoids(fragment.bytes, styles.snapshots, styles.transitions))
            return WrapResult(status: WrapStatus.invalidInput);
    const(CellStyleSnapshot)[] retained = styles is null ? snapshots : styles.snapshots[0 .. styles.used];
    foreach (ref const snapshot; retained)
    {
        const(char)[][5] spans = [snapshot.foreground, snapshot.background, snapshot.underlineColor,
            snapshot.linkOpen, snapshot.customRestore];
        foreach (span; spans)
            if (utfStorageOverlaps(span, output)
                || styles !is null && !wrapStorageAvoids(span, styles.snapshots, styles.transitions))
                return WrapResult(status: WrapStatus.invalidInput);
    }
    if (styles !is null && snapshots.ptr != styles.snapshots.ptr)
        foreach (ref const snapshot; snapshots)
        {
            const(char)[][5] spans = [snapshot.foreground, snapshot.background, snapshot.underlineColor,
                snapshot.linkOpen, snapshot.customRestore];
            foreach (span; spans)
                if (!wrapStorageAvoids(span, output, styles.snapshots, styles.transitions))
                    return WrapResult(status: WrapStatus.invalidInput);
        }
    scope StreamProjector projector = StreamProjector(options: options, startColumn: startColumn,
        output: output, snapshots: snapshots, styles: styles);
    foreach (fragment; raw)
    { auto r = projector.consume(fragment); if (!r.succeeded) return r; }
    auto r = projector.finish(projector.textEnd); if (!r.succeeded) return r;
    // A style-only line still has a stable zero-width mapping group.
    foreach (ref fragment; output[projector.groupStart .. projector.used])
    {
        fragment.clusterOrdinal = projector.ordinal;
        fragment.clusterSourceStart = fragment.consumedStart;
        fragment.clusterSourceEnd = fragment.consumedEnd;
        fragment.clusterProvenance = fragment.provenance;
    }
    result = RealizedCellProjection(projector.used, projector.closed, projector.indentAdvance,
        projector.breaks, projector.lastOpaque, projector.first, projector.hasText,
        projector.hasSourceText, projector.bodyClusters);
    return WrapResult.init;
}
