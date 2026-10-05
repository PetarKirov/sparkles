/** UI span projection over the single owned base cell-plan authority. */
module sparkles.ui.wrap;

import sparkles.base.term_color : RgbColor, xterm256ToRgb;
import sparkles.ui.style : Slot, TextStyle;
import sparkles.base.term_style : TextAttr, UnderlineStyle;
import sparkles.base.text.wrap : CellWidth, CellGeometry, CellExtent, CellNoBreakSpan,
    WrapOptions, WhitespaceMode, TabPolicy, cellWrapPlan, projectWrapCells;
import sparkles.base.text.wrap_plan : WrapPlan, WrapLine, WrapFragment, WrapSolver,
    WrapEmissionOptions, WrapResult, WrapStatus, FragmentKind, ProvenanceKind, SyntheticReason, CellStyleSnapshot, tryMaterializeWrap;

@safe:

/// Styled bytes remain UI-owned; all wrapping geometry/provenance comes from base.
struct TextSpan
{
    const(char)[] text;
    Slot slot = Slot.inherit;
    TextStyle textStyle;
    bool paintBackground;
    bool noBreak;
    RgbColor fg;
    bool hasFg;
    RgbColor bg;
    bool hasBg;
    size_t srcStart = size_t.max;
    size_t srcEnd;
    ushort linkId;
    // Rich projections retain their immutable cell plan for hit/selection/copy.
    const(WrapPlan)* wrapPlan;
    size_t wrapLine, logicalStart, logicalEnd;
    ProvenanceKind sourceRelation = ProvenanceKind.original;
    long cellAdvance;
    /// Committed target advance; -1 keeps the owned terminal cell geometry.
    long paintAdvance = -1;
    ProvenanceKind projectionRelation = ProvenanceKind.original;
    const(char)[] clusterText;
    bool clusterTextBorrowed, formatting;
    ushort ansiAttributes;
    UnderlineStyle ansiUnderline;
    size_t ansiSnapshot = size_t.max;
    const(char)[] ansiUri;
    ulong logicalGroup = ulong.max;
    size_t consumedStart, consumedEnd;
    SyntheticReason syntheticReason;
}
enum TextWrap : ubyte { none, greedy, balanced }

/// Painting, hits and selection share committed target geometry.
long spanPaintAdvance(scope const ref TextSpan span) pure nothrow @nogc
    => span.paintAdvance < 0 ? span.cellAdvance : span.paintAdvance;

/// The leading brush of adjacent whole clusters may share a measured run.
bool sameSpanBrush(scope const ref TextSpan a, scope const ref TextSpan b)
    pure nothrow @nogc
    => a.slot == b.slot && a.textStyle == b.textStyle
        && a.paintBackground == b.paintBackground && a.fg == b.fg
        && a.bg == b.bg && a.hasFg == b.hasFg && a.hasBg == b.hasBg
        && a.linkId == b.linkId && a.ansiAttributes == b.ansiAttributes
        && a.ansiUnderline == b.ansiUnderline && a.ansiSnapshot == b.ansiSnapshot;

/// Resolve authored inheritance before applying the ANSI brush overlay.
TextStyle resolvedSpanStyle(scope const ref TextSpan span, in TextStyle inherited)
    pure nothrow @nogc
{
    TextStyle style = span.textStyle == TextStyle.init ? inherited : span.textStyle;
    style.bold |= (span.ansiAttributes & TextAttr.bold.bits) != 0;
    style.italic |= (span.ansiAttributes & TextAttr.italic.bits) != 0;
    if (span.ansiUnderline != UnderlineStyle.none) style.underline = span.ansiUnderline;
    return style;
}

private const(char)[] renderedLine(scope const ref WrapPlan plan, size_t index)
{
    import std.exception : enforce;
    WrapPlan one = plan;
    one.lines = plan.lines[index .. index + 1];
    size_t extent;
    auto result = tryMaterializeWrap(one, WrapEmissionOptions(sourceRevision: plan.source.revision,
        resourceRevision: plan.resourceRevision), null, extent);
    enforce(result.succeeded || result.status == WrapStatus.needOutput, "invalid UI line projection");
    char[] output = new char[](result.required);
    result = tryMaterializeWrap(one, WrapEmissionOptions(sourceRevision: plan.source.revision,
        resourceRevision: plan.resourceRevision), output, extent);
    enforce(result.succeeded, "UI line projection failed");
    return output;
}

/// Allocating UI adapter over owned candidates. Optional target measurement
/// selects lines through the same base solver; it never overrides cell advances.
/// Width zero stays bounded zero. `none` is the explicit unbounded choice.
const(char)[][] wrapLines(F = typeof(null))(const(char)[] text, int width,
    TextWrap algorithm = TextWrap.greedy, int firstLineWidth = -1,
    scope F measure = null, bool measureMonotone = false)
{
    import std.exception : enforce;
    enforce(width >= 0 && firstLineWidth >= -1, "negative UI wrap capacity");
    WrapOptions options;
    options.width = algorithm == TextWrap.none ? CellWidth.unbounded : CellWidth.bounded(cast(ulong) width);
    options.solver = algorithm == TextWrap.balanced ? WrapSolver.balanced : WrapSolver.greedy;
    options.whitespace = algorithm == TextWrap.none ? WhitespaceMode.preserve : WhitespaceMode.collapse;
    options.tabs = TabPolicy.expand;
    if (firstLineWidth >= 0 && algorithm != TextWrap.none)
    {
        auto geometry = new CellGeometry[](2);
        geometry[0] = CellGeometry(CellWidth.bounded(cast(ulong) firstLineWidth));
        geometry[1] = CellGeometry(options.width);
        options.geometry = geometry[];
        options.repeatLastGeometry = true;
    }
    static if (is(F == typeof(null)))
        const plan = cellWrapPlan(text, options);
    else
        const plan = uiCellPlan(text, options, [TextSpan(text)], [size_t(0), text.length], measure, true,
            TextStyle.init, measureMonotone);
    auto lines = new const(char)[][](plan.lines.length);
    foreach (i; 0 .. lines.length) lines[i] = renderedLine(plan, i);
    return lines;
}

/// Complete text is gathered once because UI spans are formatting boundaries,
/// not grapheme/Unicode-opportunity boundaries. The returned span lists borrow
/// their authored spans or the owned gathered snapshot and retain the base plan.
TextSpan[][] wrapSpans(F = typeof(null))(const(TextSpan)[] spans, int width, int hangIndent = 0,
    TextWrap algorithm = TextWrap.greedy, WhitespaceMode whitespace = WhitespaceMode.collapse,
    bool clipToWidth = false, scope F measure = null, TextStyle inheritedStyle = TextStyle.init,
    bool measureMonotone = false)
{
    import std.exception : enforce;
    if (algorithm == TextWrap.none && spans.length && spans[0].wrapPlan !is null)
    {
        const plan = spans[0].wrapPlan;
        const line = spans[0].wrapLine;
        enforce(line < plan.lines.length, "stale committed rich row");
        long advance;
        auto row = new TextSpan[](spans.length);
        foreach (i, ref const span; spans)
        {
            enforce(span.wrapPlan == plan && span.wrapLine == line && span.cellAdvance >= 0
                && span.cellAdvance <= long.max - advance, "inconsistent committed rich row");
            advance += span.cellAdvance;
            row[i] = span;
        }
        enforce(advance == plan.lines[line].endColumn - plan.lines[line].startColumn,
            "committed rich row advance mismatch");
        TextSpan[][] retained = [row];
        return clipToWidth ? clipSpanLines(retained, cast(size_t) width, hangIndent) : retained;
    }
    enforce(width >= 0 && hangIndent >= 0, "negative rich wrap geometry");
    size_t length;
    foreach (ref const span; spans)
    {
        enforce(span.text.length <= size_t.max - length, "rich wrap size exhausted");
        length += span.text.length;
    }
    char[] logical = new char[](length);
    auto starts = new size_t[](spans.length + 1);
    CellNoBreakSpan[] protectedSpans;
    size_t offset;
    foreach (i, ref const span; spans)
    {
        starts[i] = offset;
        logical[offset .. offset + span.text.length] = span.text[];
        if (span.noBreak && span.text.length)
        {
            if (protectedSpans.length && protectedSpans[$ - 1].end == offset)
                protectedSpans[$ - 1].end = offset + span.text.length;
            else protectedSpans ~= CellNoBreakSpan(offset, offset + span.text.length);
        }
        offset += span.text.length;
    }
    starts[$ - 1] = offset;
    WrapOptions options;
    options.width = algorithm == TextWrap.none ? CellWidth.unbounded : CellWidth.bounded(cast(ulong) width);
    options.whitespace = algorithm == TextWrap.none ? WhitespaceMode.preserve : whitespace;
    options.solver = algorithm == TextWrap.balanced ? WrapSolver.balanced : WrapSolver.greedy;
    options.noBreak = protectedSpans;
    options.tabs = TabPolicy.expand;
    CellGeometry[] geometry = [CellGeometry(options.width),
        CellGeometry(algorithm == TextWrap.none ? CellWidth.unbounded
            : CellWidth.bounded(cast(ulong)(width > hangIndent ? width - hangIndent : 0)))];
    options.geometry = geometry[];
    options.repeatLastGeometry = true;
    auto plan = uiCellPlan(logical, options, spans, starts, measure, false, inheritedStyle, measureMonotone);
    if (clipToWidth) plan = projectWrapCells(plan, CellExtent(cast(ulong) width)).visible;
    return projectSpanMetadata(plan, spans, starts);
}

// Candidate bytes live in preallocated storage. The callback groups exactly
// the complete borrowed brush runs the display list can paint without copying.
private struct UiSelectionMeasure(F)
{
    F measure;
    const(TextSpan)[] authored;
    const(size_t)[] starts;
    TextStyle inheritedStyle;
    char[] buffer;
    WrapFragment[] pending;
    CellStyleSnapshot[] pendingStyles;
    size_t pendingStyleCount;
    size_t pendingCount;
    bool coalesceAll;
    struct Cached
    {
        const(WrapFragment)[] fragments;
        const(CellStyleSnapshot)[] brushes;
        long extent;
    }
    Cached[][size_t] cache;

    // Hash stable scalar identity, not a struct's padding or slice addresses.
    // The complete value comparison below remains the authority.
    static size_t cacheKey(scope const(WrapFragment)[] fragments) @safe pure nothrow @nogc
    {
        size_t key = fragments.length;
        foreach (ref const fragment; fragments)
        {
            key = key * 16_777_619 ^ fragment.consumedStart;
            key = key * 16_777_619 ^ fragment.consumedEnd;
            key = key * 16_777_619 ^ cast(size_t) fragment.kind;
            key = key * 16_777_619 ^ cast(size_t) fragment.repeat;
            key = key * 16_777_619 ^ cast(size_t) fragment.clusterOrdinal;
            key = key * 16_777_619 ^ cast(size_t) fragment.styleBefore;
        }
        return key;
    }

    TextSpan brushAt(size_t offset) const pure nothrow @nogc
    {
        size_t i;
        while (i + 1 < authored.length && starts[i + 1] <= offset) ++i;
        return authored.length ? authored[i] : TextSpan.init;
    }

    WrapResult extent(scope const(WrapFragment)[] fragments,
        scope const(CellStyleSnapshot)[] styles, ref long result)
    {
        size_t used, cursor, previousEnd;
        bool have, previousBorrowed;
        TextSpan brush;
        result = 0;
        WrapResult flush()
        {
            if (!have) return WrapResult.init;
            const width = measure(buffer[0 .. used], brush.textStyle);
            if (width < 0 || width > long.max - result)
                return WrapResult(status: WrapStatus.arithmeticExhausted);
            result += width;
            used = 0;
            have = false;
            return WrapResult.init;
        }
        while (cursor < fragments.length)
        {
            const start = cursor;
            const first = fragments[start];
            ++cursor;
            while (cursor < fragments.length && first.clusterOrdinal != ulong.max
                && fragments[cursor].clusterOrdinal == first.clusterOrdinal) ++cursor;
            size_t leader = start;
            while (leader < cursor && (fragments[leader].formatting
                || fragments[leader].omitted || fragments[leader].kind == FragmentKind.anchor)) ++leader;
            if (leader == cursor)
            {
                if (coalesceAll) continue;
                auto r = flush(); if (!r.succeeded) return r;
                previousBorrowed = false;
                continue;
            }
            auto nextBrush = fragments[leader].provenance == ProvenanceKind.synthetic
                ? TextSpan.init : brushAt(fragments[leader].consumedStart);
            const snapshot = cast(size_t) fragments[leader].styleBefore;
            if (snapshot < styles.length && !applySnapshotState(nextBrush, styles[snapshot]))
                return WrapResult(status: WrapStatus.invalidFormatting);
            nextBrush.ansiSnapshot = snapshot;
            nextBrush.textStyle = resolvedSpanStyle(nextBrush, inheritedStyle);
            size_t expected = first.clusterSourceStart;
            bool borrowed = true;
            foreach (ref const fragment; fragments[start .. cursor])
            {
                if (fragment.formatting || fragment.omitted || fragment.kind == FragmentKind.anchor) continue;
                borrowed &= fragment.kind == FragmentKind.bytes
                    && fragment.provenance == ProvenanceKind.original
                    && fragment.consumedStart == expected
                    && fragment.bytes.length == fragment.consumedEnd - fragment.consumedStart;
                expected = fragment.consumedEnd;
            }
            borrowed &= expected == first.clusterSourceEnd;
            if (have && !(coalesceAll || (previousBorrowed && borrowed
                && first.clusterSourceStart == previousEnd && sameSpanBrush(brush, nextBrush))))
            { auto r = flush(); if (!r.succeeded) return r; }
            if (!have) { brush = nextBrush; have = true; }
            foreach (ref const fragment; fragments[start .. cursor])
            {
                if (fragment.formatting || fragment.omitted || fragment.kind == FragmentKind.anchor) continue;
                const count = fragment.kind == FragmentKind.bytes ? fragment.bytes.length : fragment.repeat;
                if (count > buffer.length - used) return WrapResult(status: WrapStatus.needScratch);
                const end = used + cast(size_t) count;
                if (fragment.kind == FragmentKind.bytes) buffer[used .. end] = fragment.bytes[];
                else buffer[used .. end] = ' ';
                used = end;
            }
            previousBorrowed = borrowed;
            previousEnd = first.clusterSourceEnd;
        }
        return flush();
    }

    WrapResult request(scope const(WrapFragment)[] fragments,
        scope const(CellStyleSnapshot)[] styles, ref long result)
        nothrow @nogc
    {
        static if (__traits(compiles, {
            WrapResult delegate(scope const(WrapFragment)[], scope const(CellStyleSnapshot)[], ref long)
                @safe nothrow @nogc direct = &extent;
        }))
            return extent(fragments, styles, result);
        else
        {
            // Hashes select a bucket, never prove identity: compare complete
            // fragment and brush values so collisions cannot change selection.
            const bucket = cacheKey(fragments) in cache;
            if (bucket !is null) foreach (ref const entry; *bucket)
            {
                if (entry.fragments != fragments) continue;
                bool equal = true;
                foreach (i, ref const fragment; fragments)
                {
                    const snapshot = cast(size_t) fragment.styleBefore;
                    const brush = snapshot < styles.length ? styles[snapshot] : CellStyleSnapshot.init;
                    if (entry.brushes[i] != brush) { equal = false; break; }
                }
                if (equal) { result = entry.extent; return WrapResult.init; }
            }
            if (fragments.length > pending.length || styles.length > pendingStyles.length)
                return WrapResult(status: WrapStatus.needScratch);
            pendingCount = fragments.length;
            pending[0 .. pendingCount] = fragments[];
            pendingStyleCount = styles.length;
            pendingStyles[0 .. pendingStyleCount] = styles[];
            return WrapResult(status: WrapStatus.needResults);
        }
    }

    void measurePending()
    {
        import std.exception : enforce;
        long value;
        const r = extent(pending[0 .. pendingCount], pendingStyles[0 .. pendingStyleCount], value);
        enforce(r.succeeded, "UI candidate measurement failed");
        auto brushes = new CellStyleSnapshot[](pendingCount);
        foreach (i, ref const fragment; pending[0 .. pendingCount])
            if (fragment.styleBefore < pendingStyleCount)
                brushes[i] = pendingStyles[cast(size_t) fragment.styleBefore];
        cache[cacheKey(pending[0 .. pendingCount])] ~=
            Cached(pending[0 .. pendingCount].dup, brushes, value);
    }
}

private WrapPlan uiCellPlan(F)(const(char)[] text, WrapOptions options,
    const(TextSpan)[] spans, const(size_t)[] starts, scope F measure, bool coalesceAll = false,
    TextStyle inheritedStyle = TextStyle.init, bool measureMonotone = false)
{
    static if (is(F == typeof(null)))
        return cellWrapPlan(text, options);
    else
    {
        import std.exception : enforce;
        enforce(text.length <= (size_t.max - 8) / 8, "UI measurement storage exhausted");
        auto context = UiSelectionMeasure!F(measure, spans, starts);
        context.coalesceAll = coalesceAll;
        context.inheritedStyle = inheritedStyle;
        options.selectionMeasureMonotone = measureMonotone;
        context.buffer = new char[](text.length * 8 + 8);
        static if (!__traits(compiles, {
            WrapResult delegate(scope const(WrapFragment)[], scope const(CellStyleSnapshot)[], ref long)
                @safe nothrow @nogc direct = &context.extent;
        }))
        {
            context.pending = new WrapFragment[](text.length * 8 + 8);
            context.pendingStyles = new CellStyleSnapshot[](text.length * 8 + 8);
        }
        // WrapOptions also owns returnable indentation borrows, so its callback
        // cannot express a separate scope lifetime. Only this synchronous call
        // sees the stack delegate; WrapPlan retains no callback or context.
        scope void delegate() @safe pending;
        (() @trusted {
            options.selectionMeasure = &context.request;
            pending = &context.measurePending;
        })();
        return cellWrapPlan(text, options, pending);
    }
}

private struct ClusterPayload { const(char)[] bytes; bool borrowed; }
private size_t groupEnd(scope const ref WrapPlan plan, size_t start, size_t limit)
{
    const first = plan.fragments[start];
    if (first.clusterOrdinal == ulong.max) return start + 1;
    size_t end = start + 1;
    while (end < limit && plan.fragments[end].clusterOrdinal == first.clusterOrdinal) ++end;
    return end;
}
private ClusterPayload clusterPayload(const ref WrapPlan plan, size_t start, size_t end)
{
    import std.exception : enforce, assumeUnique;
    size_t count, expected, originalStart;
    bool have, borrowed = true;
    foreach (ref const fragment; plan.fragments[start .. end])
    {
        if (fragment.formatting || fragment.omitted || fragment.kind == FragmentKind.anchor) continue;
        const n = fragment.kind == FragmentKind.bytes ? fragment.bytes.length : fragment.repeat;
        enforce(n <= size_t.max - count, "cluster output exhausted");
        count += cast(size_t) n;
        if (!have) { originalStart = fragment.consumedStart; expected = originalStart; }
        borrowed &= fragment.kind == FragmentKind.bytes && fragment.provenance == ProvenanceKind.original
            && fragment.consumedStart == expected && fragment.bytes.length == fragment.consumedEnd - fragment.consumedStart;
        expected = fragment.consumedEnd; have = true;
    }
    if (have && borrowed && expected <= plan.source.bytes.length)
        return ClusterPayload(plan.source.bytes[originalStart .. expected],
            originalStart == plan.fragments[start].clusterSourceStart
                && expected == plan.fragments[start].clusterSourceEnd);
    char[] output = new char[](count);
    size_t offset;
    foreach (ref const fragment; plan.fragments[start .. end])
    {
        if (fragment.formatting || fragment.omitted || fragment.kind == FragmentKind.anchor) continue;
        if (fragment.kind == FragmentKind.bytes)
        { output[offset .. offset + fragment.bytes.length] = fragment.bytes[]; offset += fragment.bytes.length; }
        else
        { const n = cast(size_t) fragment.repeat; output[offset .. offset + n] = ' '; offset += n; }
    }
    // The generated payload is uniquely owned; no mutable view escapes.
    return ClusterPayload((() @trusted { return assumeUnique(output); })(), false);
}
private bool snapshotColor(scope const(char)[] parameters, ref RgbColor color) @safe pure nothrow @nogc
{
    uint[7] values;
    size_t count, position;
    while (position < parameters.length && count < values.length)
    {
        uint value;
        while (position < parameters.length && parameters[position] >= '0' && parameters[position] <= '9')
        {
            if (value > 6553) return false;
            value = value * 10 + parameters[position++] - '0';
        }
        values[count++] = value;
        if (position < parameters.length)
        { if (parameters[position] != ';' && parameters[position] != ':') return false; ++position; }
    }
    if (!count || position != parameters.length) return false;
    const code = values[0];
    if (count == 1)
    {
        uint index;
        if (code >= 30 && code <= 37) index = code - 30;
        else if (code >= 40 && code <= 47) index = code - 40;
        else if (code >= 90 && code <= 97) index = code - 90 + 8;
        else if (code >= 100 && code <= 107) index = code - 100 + 8;
        else return false;
        color = xterm256ToRgb(cast(ubyte) index); return true;
    }
    if (count >= 3 && values[1] == 5 && values[count - 1] <= 255)
    { color = xterm256ToRgb(cast(ubyte) values[count - 1]); return true; }
    if (count >= 5 && values[1] == 2 && values[count - 3] <= 255 && values[count - 2] <= 255 && values[count - 1] <= 255)
    { color = RgbColor(cast(ubyte) values[count - 3], cast(ubyte) values[count - 2], cast(ubyte) values[count - 1]); return true; }
    return false;
}
private bool applySnapshotState(ref TextSpan span, const ref CellStyleSnapshot state)
    pure nothrow @nogc
{
    const flags = state.attributes;
    span.ansiAttributes = cast(ushort)(
        ((flags & 1) ? TextAttr.bold.bits : 0)
        | ((flags & 2) ? TextAttr.dim.bits : 0)
        | ((flags & 4) ? TextAttr.italic.bits : 0)
        | ((flags & (1 << 6)) ? TextAttr.inverse.bits : 0)
        | ((flags & (1 << 7)) ? TextAttr.hidden.bits : 0)
        | ((flags & (1 << 8)) ? TextAttr.strikethrough.bits : 0));
    span.ansiUnderline = cast(UnderlineStyle) state.underline;
    if (state.foreground.length)
    {
        if (!snapshotColor(state.foreground, span.fg)) return false;
        span.hasFg = true;
    }
    if (state.background.length)
    {
        if (!snapshotColor(state.background, span.bg)) return false;
        span.hasBg = true;
        span.paintBackground = true;
    }
    if (state.linkOpen.length)
    {
        size_t start = 4;
        while (start < state.linkOpen.length && state.linkOpen[start] != ';') ++start;
        if (start < state.linkOpen.length)
        {
            const end = state.linkOpen[$ - 1] == '\x07' ? state.linkOpen.length - 1 : state.linkOpen.length - 2;
            if (start + 1 <= end) span.ansiUri = state.linkOpen[start + 1 .. end];
        }
    }
    return true;
}
private void applySnapshot(ref TextSpan span, scope const ref WrapPlan plan, size_t snapshot)
{
    import std.exception : enforce;
    if (snapshot >= plan.styles.length) return;
    span.ansiSnapshot = snapshot;
    enforce(applySnapshotState(span, plan.styles[snapshot]), "unsupported ANSI color snapshot");
}
private TextSpan[][] projectSpanMetadata(WrapPlan plan, const(TextSpan)[] authored, const(size_t)[] starts)
{
    import std.exception : enforce;
    auto retained = new WrapPlan;
    *retained = plan;
    auto lines = new TextSpan[][](plan.lines.length);
    foreach (li, ref const line; plan.lines)
    {
        size_t cursor = line.fragmentsStart;
        while (cursor < line.fragmentsEnd)
        {
            const end = groupEnd(plan, cursor, line.fragmentsEnd);
            const payload = clusterPayload(plan, cursor, end);
            bool leader;
            foreach (fi; cursor .. end)
            {
                const fragment = plan.fragments[fi];
                if (fragment.kind == FragmentKind.anchor) continue;
                const text = fragment.kind == FragmentKind.bytes ? fragment.bytes : renderedSpaces(fragment.repeat);
                const first = fragment.consumedStart, last = fragment.consumedEnd;
                size_t si;
                while (si < authored.length && starts[si + 1] <= first) ++si;
                bool emitted;
                do
                {
                    TextSpan span;
                    size_t begin = first, finish = last;
                    if (fragment.provenance != ProvenanceKind.synthetic && si < authored.length)
                    {
                        span = authored[si];
                        begin = first > starts[si] ? first : starts[si];
                        finish = last < starts[si + 1] ? last : starts[si + 1];
                        if (begin >= finish) break;
                        span.text = fragment.provenance == ProvenanceKind.original
                            ? authored[si].text[begin - starts[si] .. finish - starts[si]] : text;
                        span.sourceRelation = authored[si].srcStart == size_t.max ? ProvenanceKind.synthetic
                            : authored[si].sourceRelation == ProvenanceKind.original ? fragment.provenance : authored[si].sourceRelation;
                        if (span.srcStart != size_t.max && authored[si].sourceRelation == ProvenanceKind.original
                            && authored[si].srcEnd >= authored[si].srcStart
                            && authored[si].srcEnd - authored[si].srcStart == authored[si].text.length
                            && fragment.provenance == ProvenanceKind.original)
                        { span.srcStart = authored[si].srcStart + begin - starts[si]; span.srcEnd = authored[si].srcStart + finish - starts[si]; }
                        else if (span.srcStart != size_t.max && span.sourceRelation == ProvenanceKind.original)
                            span.sourceRelation = ProvenanceKind.replacement;
                    }
                    else
                    { span.text = text; span.sourceRelation = ProvenanceKind.synthetic; }
                    span.wrapPlan = retained; span.wrapLine = li;
                    span.logicalGroup = fragment.clusterOrdinal;
                    span.logicalStart = fragment.clusterOrdinal == ulong.max ? fragment.sourceStart : fragment.clusterSourceStart;
                    span.logicalEnd = fragment.clusterOrdinal == ulong.max ? fragment.sourceEnd : fragment.clusterSourceEnd;
                    span.consumedStart = begin; span.consumedEnd = finish;
                    span.cellAdvance = emitted ? 0 : fragment.advance;
                    span.formatting = fragment.formatting;
                    span.projectionRelation = fragment.provenance;
                    span.syntheticReason = fragment.reason;
                    if (!leader && !fragment.formatting)
                    { span.clusterText = payload.bytes; span.clusterTextBorrowed = payload.borrowed; leader = true; }
                    applySnapshot(span, plan, cast(size_t) fragment.styleBefore);
                    lines[li] ~= span;
                    emitted = true;
                    if (fragment.provenance != ProvenanceKind.original || fragment.provenance == ProvenanceKind.synthetic) break;
                    ++si;
                } while (si < authored.length && starts[si] < last);
            }
            cursor = end;
        }
    }
    return lines;
}

/// Allocation occurs only at layout's commit boundary. Existing immutable plans
/// are projected, never concatenated, segmented, selected, or measured again.
TextSpan[][] clipSpanLines(TextSpan[][] lines, size_t maximum, int hangIndent = 0)
{
    import std.exception : enforce;
    enforce(hangIndent >= 0, "negative hanging indent");
    auto output = new TextSpan[][](lines.length);
    const(WrapPlan)*[const(WrapPlan)*][size_t] cache;
    foreach (li, row; lines)
    {
        size_t capacity = li && cast(size_t) hangIndent < maximum ? maximum - hangIndent
            : li && hangIndent ? 0 : maximum;
        if (!row.length) { output[li] = row; continue; }
        const source = row[0].wrapPlan;
        enforce(source !is null && row[0].wrapLine < source.lines.length, "rich row lacks committed plan");
        const lineIndex = row[0].wrapLine;
        foreach (ref const span; row) enforce(span.wrapPlan == source && span.wrapLine == lineIndex, "mixed rich row plans");
        const line = source.lines[lineIndex];
        if (line.endColumn - line.startColumn <= capacity)
        { output[li] = row; continue; }
        const(WrapPlan)* visible;
        auto byCapacity = capacity in cache;
        if (byCapacity !is null)
        {
            auto found = source in *byCapacity;
            if (found !is null) visible = *found;
        }
        if (visible is null)
        {
            auto projection = projectWrapCells(*source, CellExtent(capacity));
            auto projectedPlan = new WrapPlan;
            *projectedPlan = projection.visible;
            visible = projectedPlan;
            cache[capacity][source] = visible;
        }
        auto projected = new TextSpan[](row.length);
        foreach (i, ref const original; row)
        {
            TextSpan span = original;
            span.wrapPlan = visible;
            span.cellAdvance = 0;
            bool retained = original.formatting;
            ClusterPayload payload;
            const visibleLine = visible.lines[lineIndex];
            size_t cursor = visibleLine.fragmentsStart;
            while (cursor < visibleLine.fragmentsEnd)
            {
                const end = groupEnd(*visible, cursor, visibleLine.fragmentsEnd);
                const f = visible.fragments[cursor];
                const matches = original.logicalGroup != ulong.max && f.clusterOrdinal == original.logicalGroup;
                if (matches)
                {
                    span.projectionRelation = f.clusterProvenance;
                    bool any;
                    foreach (ref const fragment; visible.fragments[cursor .. end])
                    {
                        any |= !fragment.omitted && !fragment.formatting && fragment.kind != FragmentKind.anchor;
                        if (fragment.consumedStart == original.consumedStart && fragment.consumedEnd == original.consumedEnd
                            && !fragment.formatting && !fragment.omitted) span.cellAdvance = original.cellAdvance ? fragment.advance : 0;
                    }
                    retained |= any;
                    if (original.clusterText.length) payload = clusterPayload(*visible, cursor, end);
                    break;
                }
                cursor = end;
            }
            if (!retained)
            { span.text = null; span.clusterText = null; span.clusterTextBorrowed = false; span.projectionRelation = ProvenanceKind.omission; }
            else if (original.clusterText.length)
            {
                span.clusterText = payload.bytes; span.clusterTextBorrowed = payload.borrowed;
                if (original.projectionRelation != ProvenanceKind.original) span.text = payload.bytes;
            }
            projected[i] = span;
        }
        output[li] = projected;
    }
    return output;
}
/// Complete retained line advance, never the sum of independently measured spans.
int spanLineWidth(scope const(TextSpan)[] spans)
{
    import std.exception : enforce;
    long width;
    if (spans.length && spans[0].wrapPlan !is null)
    {
        const plan = spans[0].wrapPlan;
        enforce(spans[0].wrapLine < plan.lines.length, "stale rich line");
        foreach (ref const span; spans)
            enforce(span.wrapPlan == plan && span.wrapLine == spans[0].wrapLine, "mixed rich line plans");
        const line = plan.lines[spans[0].wrapLine];
        width = line.endColumn - line.startColumn;
    }
    else
    {
        char[] logical;
        foreach (ref const span; spans) logical ~= span.text;
        const plan = cellWrapPlan(logical, WrapOptions(width: CellWidth.unbounded));
        foreach (ref const line; plan.lines)
            if (line.endColumn - line.startColumn > width) width = line.endColumn - line.startColumn;
    }
    enforce(width >= 0 && width <= int.max, "UI line extent exhausted");
    return cast(int) width;
}

private const(char)[] renderedSpaces(ulong count)
{
    import std.exception : enforce;
    enforce(count <= size_t.max, "rich tab expansion exhausted");
    char[] spaces = new char[](cast(size_t) count);
    spaces[] = ' ';
    return spaces;
}
private size_t borrowedOffset(scope const(char)[] parent, scope const(char)[] child) @trusted pure nothrow @nogc
{
    const p = cast(size_t) parent.ptr, c = cast(size_t) child.ptr;
    return c >= p && c - p <= parent.length && child.length <= parent.length - (c - p) ? c - p : size_t.max;
}

@("ui.wrap.ownedClustersAndTransformedIdentity") unittest
{
    assert(wrapLines("e\u0301x", 1) == ["e\u0301", "x"]);
    assert(wrapLines("a\n\n", 8) == ["a", "", ""]);
    TextSpan[] spans = [TextSpan("e", srcStart: 10, srcEnd: 11),
        TextSpan("\u0301x", srcStart: 11, srcEnd: 14)];
    const lines = wrapSpans(spans, 1);
    assert(lines.length == 2 && lines[1].length == 1);
    assert(lines[1][0].text == "x" && lines[1][0].srcStart == 13 && lines[1][0].srcEnd == 14);
    assert(lines[1][0].wrapPlan !is null && lines[1][0].logicalStart == 3);
    const prose = wrapSpans([TextSpan("a  b", srcStart: 100, srcEnd: 120)], 8);
    assert(prose[0][1].text == " " && prose[0][1].srcStart == 100 && prose[0][1].srcEnd == 120
        && prose[0][1].sourceRelation == ProvenanceKind.replacement);
}

@("ui.wrap.measuredSelection.fullRenderedRunRounding") unittest
{
    import sparkles.base.text.grapheme : visibleWidth;
    static int direct(scope const(char)[] s, in TextStyle st)
        pure nothrow @nogc => (cast(int) visibleWidth(s) + 1) / 2;
    static int allocating(scope const(char)[] s, in TextStyle st)
    {
        const copy = s.idup;
        return (cast(int) visibleWidth(copy) + 1) / 2;
    }
    foreach (algorithm; [TextWrap.greedy, TextWrap.balanced])
    {
        // Rounding isolated glyphs would reject this fitting complete run.
        assert(wrapLines("a a", 2, algorithm, -1, &direct) == ["a a"]);
        assert(wrapLines("a a", 2, algorithm, -1, &allocating) == ["a a"],
            "measurers outside the solver's attributes keep exact selection");
    }
}

@("ui.wrap.measuredSelection.nonmonotoneRemainsExact")
@safe
unittest
{
    // A fitting short candidate, an over-capacity middle candidate, and a
    // fitting longer candidate forbid the monotone-tail shortcut.
    static int width(scope const(char)[] text, in TextStyle style)
        pure nothrow @nogc => text.length == 3 ? 3 : 1;
    assert(wrapLines("a b c", 1, TextWrap.greedy, -1, &width) == ["a b c"]);
}

@("ui.wrap.measuredSelection.ansiBrushPreservesInheritedTypography")
@safe
unittest
{
    import sparkles.base.text.grapheme : visibleWidth;
    import sparkles.ui.style : FontRole, TypeStep;
    static int width(scope const(char)[] text, in TextStyle style)
        pure nothrow @nogc
    {
        assert(style.fontRole == FontRole.ui && style.typeStep == TypeStep.title);
        return cast(int) visibleWidth(text) * (style.bold ? 2 : 1);
    }
    const inherited = TextStyle(fontRole: FontRole.ui, typeStep: TypeStep.title);
    foreach (algorithm; [TextWrap.greedy, TextWrap.balanced])
    {
        auto lines = wrapSpans([TextSpan("\x1b[1;4:3mab\x1b[22mcd")], 4, 0,
            algorithm, WhitespaceMode.preserve, false, &width, inherited);
        assert(lines.length == 2);
        string[] visible;
        foreach (line; lines)
        {
            string text;
            foreach (ref const span; line)
            {
                if (span.formatting || !span.clusterText.length) continue;
                text ~= span.clusterText;
                const style = resolvedSpanStyle(span, inherited);
                assert(style.fontRole == FontRole.ui && style.typeStep == TypeStep.title);
                assert(style.underline == UnderlineStyle.curly);
                assert(style.bold == (span.clusterText == "a" || span.clusterText == "b"));
            }
            visible ~= text;
        }
        assert(visible == ["ab", "cd"]);
    }
}
