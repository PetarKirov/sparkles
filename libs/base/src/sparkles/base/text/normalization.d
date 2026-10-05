/** Unicode 18 UAX #15 normalization with caller-owned storage and exact provenance. */
module sparkles.base.text.normalization;

import sparkles.base.text.transform : UnicodeTransformView, UnicodeTransformWorkspace,
    UnicodeTransformUnit, UnicodeDeletion;
import sparkles.base.text.unicode_algorithm : UnicodeResult, UnicodeStatus, UnicodeSourceSpan;
import sparkles.base.text.utf : UtfTokenKind, isUnicodeScalar, utfStorageOverlaps;
import sparkles.base.text.unicode_tables : canonicalDecomposition,
    canonicalDecompositionValue, compatibilityDecomposition,
    compatibilityDecompositionValue, canonicalCombiningClass, canonicalComposition;

enum UnicodeNormalization : ubyte { NFC, NFD, NFKC, NFKD }

/// An implementation scratch entry; inputIndex follows a unit through reordering.
struct UnicodeNormalizationItem
{
    UnicodeTransformUnit unit;
    size_t inputIndex;
    ubyte canonicalClass;
}

/** Scratch is borrowed only during normalizeText, never retained by the output.
 * items holds the entire decomposed input. ordering holds the longest nonstarter
 * run that needs reordering. boundaries needs input.units.length + 1 entries only
 * when input has deletions. All scratch and output arenas must be disjoint.
 */
struct UnicodeNormalizationScratch
{
    UnicodeNormalizationItem[] items;
    size_t[] ordering;
    size_t[] boundaries;
}

private bool overlapsTransform(T)(scope T[] arena, in UnicodeTransformView input,
    scope ref UnicodeTransformWorkspace output) @safe pure nothrow @nogc
{
    return utfStorageOverlaps(input.units, arena)
        || utfStorageOverlaps(input.spans, arena)
        || utfStorageOverlaps(input.deletions, arena)
        || utfStorageOverlaps(input.storageEpoch(), arena)
        || utfStorageOverlaps(output.units, arena)
        || utfStorageOverlaps(output.spans, arena)
        || utfStorageOverlaps(output.deletions, arena)
        || utfStorageOverlaps(output.epoch, arena);
}

private bool sourceLess(in UnicodeSourceSpan a, in UnicodeSourceSpan b)
    @safe pure nothrow @nogc
    => a.start < b.start || (a.start == b.start && a.end < b.end);

private UnicodeSourceSpan blockingSource(in UnicodeTransformUnit unit,
    scope const(UnicodeSourceSpan)[] spans) @safe pure nothrow @nogc
    => unit.provenanceCount ? spans[unit.provenanceStart] : UnicodeSourceSpan.init;

private ubyte combiningClass(in UnicodeNormalizationItem item)
    @safe pure nothrow @nogc
    => item.canonicalClass;

private UnicodeResult orderCanonical(scope UnicodeNormalizationItem[] items,
    scope size_t[] ordering, scope const(UnicodeSourceSpan)[] spans)
    @safe pure nothrow @nogc
{
    size_t first;
    while (first < items.length)
    {
        if (combiningClass(items[first]) == 0) { ++first; continue; }
        size_t end = first + 1;
        ubyte previous = combiningClass(items[first]);
        bool ordered = true;
        while (end < items.length)
        {
            const ccc = combiningClass(items[end]);
            if (!ccc) break;
            if (ccc < previous) ordered = false;
            previous = ccc;
            ++end;
        }
        const count = end - first;
        if (!ordered)
        {
            if (count > ordering.length)
                return UnicodeResult(status: UnicodeStatus.workspaceFull,
                    required: count, blocking: blockingSource(items[first].unit, spans));
            // Stable counting-sort permutation, then linear in-place cycles.
            size_t[256] positions;
            foreach (i; first .. end) ++positions[combiningClass(items[i])];
            size_t offset;
            foreach (ref position; positions)
            {
                const frequency = position;
                position = offset;
                offset += frequency;
            }
            foreach (i; 0 .. count)
                ordering[i] = positions[combiningClass(items[first + i])]++;
            foreach (i; 0 .. count)
            {
                while (ordering[i] != i)
                {
                    const target = ordering[i];
                    const item = items[first + i];
                    items[first + i] = items[first + target];
                    items[first + target] = item;
                    const next = ordering[i];
                    ordering[i] = ordering[target];
                    ordering[target] = next;
                }
            }
        }
        first = end;
    }
    return UnicodeResult.init;
}

private UnicodeResult mergeSources(ref UnicodeTransformUnit starter,
    in UnicodeTransformUnit next, scope ref UnicodeTransformWorkspace output)
    @safe pure nothrow @nogc
{
    const a = output.constructionSpans()[starter.provenanceStart ..
        starter.provenanceStart + starter.provenanceCount];
    const b = output.constructionSpans()[next.provenanceStart ..
        next.provenanceStart + next.provenanceCount];
    if (a == b) return UnicodeResult.init;
    size_t ai, bi, count;
    // Count first, so exhaustion reports the exact union requirement.
    while (ai < a.length || bi < b.length)
    {
        if (bi == b.length || (ai < a.length && sourceLess(a[ai], b[bi]))) ++ai;
        else if (ai == a.length || sourceLess(b[bi], a[ai])) ++bi;
        else { ++ai; ++bi; }
        ++count;
    }
    const start = output.provenanceLength();
    if (count > size_t.max - start)
        return UnicodeResult(status: UnicodeStatus.overflow);
    if (count > output.spans.length - start)
        return UnicodeResult(status: UnicodeStatus.workspaceFull,
            required: start + count, blocking: blockingSource(next, output.constructionSpans()));
    ai = bi = 0;
    size_t written;
    while (ai < a.length || bi < b.length)
    {
        UnicodeSourceSpan source;
        if (bi == b.length || (ai < a.length && sourceLess(a[ai], b[bi]))) source = a[ai++];
        else if (ai == a.length || sourceLess(b[bi], a[ai])) source = b[bi++];
        else { source = a[ai++]; ++bi; }
        output.spans[start + written++] = source;
    }
    size_t committed;
    auto result = output.commitSources(count, committed);
    if (!result.succeeded()) return result;
    starter.provenanceStart = committed;
    starter.provenanceCount = count;
    return UnicodeResult.init;
}

/** Normalize the entire input, with no allocation and no Stream-Safe CGJ insertion.
 * Generated decomposition mappings are recursively expanded by the pinned generator;
 * Hangul decomposition is algorithmic here. Composition includes zero-CCC pairs and
 * uses the generated full-composition-exclusion-filtered table and Hangul algorithm.
 * Failure invalidates old output and publishes no partial result. required names the
 * number of entries needed in the exhausted arena, not bytes.
 * A prior deletion maps after the rightmost output unit with any contributor to the
 * left of its input boundary. A composite crossing that boundary thus maps after
 * the composite; its original deletion source interval is retained unchanged.
 * Storage precondition: each workspace has one distinct caller-owned epoch,
 * disjoint from all input, output, and scratch arenas. This is asserted before
 * invocation invalidation; violating it is not a recoverable transform failure.
 */
UnicodeResult normalizeText(in UnicodeTransformView input, UnicodeNormalization form,
    scope ref UnicodeTransformWorkspace output, scope UnicodeNormalizationScratch scratch)
    @safe pure nothrow @nogc
{
    assert(!utfStorageOverlaps(input.units, output.epoch)
        && !utfStorageOverlaps(input.spans, output.epoch)
        && !utfStorageOverlaps(input.deletions, output.epoch)
        && !utfStorageOverlaps(input.storageEpoch(), output.epoch)
        && !utfStorageOverlaps(output.units, output.epoch)
        && !utfStorageOverlaps(output.spans, output.epoch)
        && !utfStorageOverlaps(output.deletions, output.epoch)
        && !utfStorageOverlaps(scratch.items, output.epoch)
        && !utfStorageOverlaps(scratch.ordering, output.epoch)
        && !utfStorageOverlaps(scratch.boundaries, output.epoch),
        "normalization output epoch must be distinct and disjoint from all arenas");
    // Preflight reads slice metadata only; no aliased input contents are inspected.
    const overlap = utfStorageOverlaps(input.units, output.units)
        || utfStorageOverlaps(input.units, output.spans)
        || utfStorageOverlaps(input.units, output.deletions)
        || utfStorageOverlaps(input.spans, output.units)
        || utfStorageOverlaps(input.spans, output.spans)
        || utfStorageOverlaps(input.spans, output.deletions)
        || utfStorageOverlaps(input.deletions, output.units)
        || utfStorageOverlaps(input.deletions, output.spans)
        || utfStorageOverlaps(input.deletions, output.deletions)
        || utfStorageOverlaps(input.storageEpoch(), output.units)
        || utfStorageOverlaps(input.storageEpoch(), output.spans)
        || utfStorageOverlaps(input.storageEpoch(), output.deletions)
        || utfStorageOverlaps(output.units, output.spans)
        || utfStorageOverlaps(output.units, output.deletions)
        || utfStorageOverlaps(output.spans, output.deletions)
        || overlapsTransform(scratch.items, input, output)
        || overlapsTransform(scratch.ordering, input, output)
        || overlapsTransform(scratch.boundaries, input, output)
        || utfStorageOverlaps(scratch.items, scratch.ordering)
        || utfStorageOverlaps(scratch.items, scratch.boundaries)
        || utfStorageOverlaps(scratch.ordering, scratch.boundaries);
    auto result = output.begin();
    if (!result.succeeded()) return result;
    if (overlap) return UnicodeResult(status: UnicodeStatus.overlap);
    if (cast(uint) form > cast(uint) UnicodeNormalization.NFKD)
        return UnicodeResult(status: UnicodeStatus.invalidOptions);
    if (!input.valid()) return UnicodeResult(status: UnicodeStatus.staleView);
    foreach (span; input.spans)
        if (span.start > span.end) return UnicodeResult(status: UnicodeStatus.invalidInput, blocking: span);
    foreach (unit; input.units)
    {
        if (cast(uint) unit.kind > cast(uint) UtfTokenKind.opaqueByte
            || (!unit.isOpaque() && !isUnicodeScalar(unit.value))
            || unit.provenanceStart > input.spans.length
            || unit.provenanceCount > input.spans.length - unit.provenanceStart)
            return UnicodeResult(status: UnicodeStatus.invalidInput);
        const sources = input.spans[unit.provenanceStart .. unit.provenanceStart + unit.provenanceCount];
        foreach (i; 1 .. sources.length)
            if (!sourceLess(sources[i - 1], sources[i]))
                return UnicodeResult(status: UnicodeStatus.invalidInput, blocking: sources[i]);
    }
    foreach (deletion; input.deletions)
        if (deletion.boundary > input.units.length || deletion.source.start > deletion.source.end)
            return UnicodeResult(status: UnicodeStatus.invalidInput, blocking: deletion.source);
    if (input.deletions.length)
    {
        if (input.units.length == size_t.max) return UnicodeResult(status: UnicodeStatus.overflow);
        if (scratch.boundaries.length < input.units.length + 1)
            return UnicodeResult(status: UnicodeStatus.workspaceFull,
                required: input.units.length + 1, blocking: input.deletions[0].source);
        scratch.boundaries[0 .. input.units.length + 1] = 0;
    }
    const compatibility = form == UnicodeNormalization.NFKC || form == UnicodeNormalization.NFKD;
    size_t count;
    foreach (inputIndex, sourceUnit; input.units)
    {
        UnicodeTransformUnit unit = sourceUnit;
        const hangul = !unit.isOpaque() && unit.value >= 0xAC00 && unit.value <= 0xD7A3;
        const mapping = unit.isOpaque() || hangul ? typeof(canonicalDecomposition('A')).init
            : compatibility ? compatibilityDecomposition(unit.value) : canonicalDecomposition(unit.value);
        const hangulIndex = hangul ? unit.value - 0xAC00 : 0;
        const length = hangul ? (hangulIndex % 28 ? 3 : 2) : mapping.present ? mapping.length : 1;
        if (length > size_t.max - count) return UnicodeResult(status: UnicodeStatus.overflow);
        if (length > scratch.items.length - count)
            return UnicodeResult(status: UnicodeStatus.workspaceFull, required: count + length,
                blocking: blockingSource(unit, input.spans));
        size_t first;
        result = output.appendSources(input.spans[unit.provenanceStart ..
            unit.provenanceStart + unit.provenanceCount], first);
        if (!result.succeeded()) return result;
        unit.provenanceStart = first;
        foreach (i; 0 .. length)
        {
            auto part = unit;
            if (hangul)
                part.value = cast(dchar)(i == 0 ? 0x1100 + hangulIndex / 588
                    : i == 1 ? 0x1161 + (hangulIndex % 588) / 28 : 0x11A7 + hangulIndex % 28);
            else if (mapping.present)
                part.value = compatibility ? compatibilityDecompositionValue(mapping.offset + i)
                    : canonicalDecompositionValue(mapping.offset + i);
            const ccc = part.isOpaque() ? 0 : canonicalCombiningClass(part.value);
            scratch.items[count++] = UnicodeNormalizationItem(part, inputIndex, cast(ubyte) ccc);
        }
    }
    auto items = scratch.items[0 .. count];
    result = orderCanonical(items, scratch.ordering, output.constructionSpans());
    if (!result.succeeded()) return result;
    const compose = form == UnicodeNormalization.NFC || form == UnicodeNormalization.NFKC;
    size_t written = compose ? 0 : count;
    size_t starter = size_t.max;
    ubyte previousClass;
    if (compose)
    {
        foreach (readIndex; 0 .. count)
        {
            auto item = items[readIndex];
            const ccc = combiningClass(item);
            if (!item.unit.isOpaque() && starter != size_t.max
                && (previousClass == 0 || previousClass < ccc))
            {
                const composite = canonicalComposition(items[starter].unit.value, item.unit.value);
                if (composite != dchar.init)
                {
                    result = mergeSources(items[starter].unit, item.unit, output);
                    if (!result.succeeded()) return result;
                    items[starter].unit.value = composite;
                    items[starter].unit.flags |= item.unit.flags;
                    if (item.unit.kind == UtfTokenKind.replacement)
                        items[starter].unit.kind = UtfTokenKind.replacement;
                    if (item.inputIndex < items[starter].inputIndex)
                        items[starter].inputIndex = item.inputIndex;
                    continue;
                }
            }
            if (written != readIndex) items[written] = item;
            if (item.unit.isOpaque()) starter = size_t.max;
            else if (ccc == 0) starter = written;
            previousClass = ccc;
            ++written;
        }
    }
    foreach (i; 0 .. written)
    {
        result = output.appendUnit(items[i].unit);
        if (!result.succeeded()) return result;
        if (input.deletions.length)
        {
            const boundary = items[i].inputIndex + 1;
            if (scratch.boundaries[boundary] < i + 1) scratch.boundaries[boundary] = i + 1;
        }
    }
    if (input.deletions.length)
    {
        foreach (i; 1 .. input.units.length + 1)
            if (scratch.boundaries[i] < scratch.boundaries[i - 1])
                scratch.boundaries[i] = scratch.boundaries[i - 1];
        foreach (deletion; input.deletions)
        {
            result = output.appendDeletion(UnicodeDeletion(scratch.boundaries[deletion.boundary], deletion.source));
            if (!result.succeeded()) return result;
        }
    }
    output.publish();
    return UnicodeResult(written: written);
}

version (unittest)
{
    private void normalizationInput(scope const(dchar)[] values,
        ref UnicodeTransformWorkspace workspace) @safe pure nothrow @nogc
    {
        assert(workspace.begin().succeeded());
        foreach (i, value; values)
        {
            UnicodeSourceSpan[1] source = [UnicodeSourceSpan(i * 3, i * 3 + 1)];
            size_t first;
            assert(workspace.appendSources(source[], first).succeeded());
            assert(workspace.appendUnit(UnicodeTransformUnit(value: value,
                provenanceStart: first, provenanceCount: 1)).succeeded());
        }
        workspace.publish();
    }
}

@("text.normalization.reorderingCompositionAndDeletionProvenance")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.text.transform : UnicodeTransformEpoch;
    UnicodeTransformUnit[8] inputUnits, outputUnits;
    UnicodeSourceSpan[32] inputSpans, outputSpans;
    UnicodeDeletion[4] inputDeletions, outputDeletions;
    UnicodeTransformEpoch[1] inputEpoch, outputEpoch;
    auto input = UnicodeTransformWorkspace(units: inputUnits[], spans: inputSpans[],
        deletions: inputDeletions[], epoch: inputEpoch[]);
    auto output = UnicodeTransformWorkspace(units: outputUnits[], spans: outputSpans[],
        deletions: outputDeletions[], epoch: outputEpoch[]);
    UnicodeNormalizationItem[16] items;
    size_t[16] ordering, boundaries;
    auto scratch = UnicodeNormalizationScratch(items[], ordering[], boundaries[]);
    dchar[4] values = ['A', 0x0315, 0x0300, 0x0323];
    normalizationInput(values[], input);
    const source = input.output();
    assert(normalizeText(source, UnicodeNormalization.NFD, output, scratch).succeeded());
    auto view = output.output();
    assert(view.units[0].value == 'A' && view.units[1].value == 0x0323
        && view.units[2].value == 0x0300 && view.units[3].value == 0x0315);
    assert(view.contributingSourceSpans(1)[0] == UnicodeSourceSpan(9, 10));
    assert(view.contributingSourceSpans(2)[0] == UnicodeSourceSpan(6, 7));
    assert(view.contributingSourceSpans(3)[0] == UnicodeSourceSpan(3, 4));
    assert(source.valid() && source.units[1].value == 0x0315);

    dchar[3] composition = ['A', 0x0315, 0x0300];
    normalizationInput(composition[], input);
    assert(input.appendDeletion(UnicodeDeletion(2, UnicodeSourceSpan(4, 5))).succeeded());
    assert(normalizeText(input.output(), UnicodeNormalization.NFC, output, scratch).succeeded());
    view = output.output();
    assert(view.units.length == 2 && view.units[0].value == 0x00C0 && view.units[1].value == 0x0315);
    UnicodeSourceSpan[2] exact = [UnicodeSourceSpan(0, 1), UnicodeSourceSpan(6, 7)];
    assert(view.contributingSourceSpans(0) == exact[]);
    assert(view.contributingSourceSpans(1)[0] == UnicodeSourceSpan(3, 4));
    assert(view.deletions[0] == UnicodeDeletion(2, UnicodeSourceSpan(4, 5)));
}

@("text.normalization.hangulCompatibilityBlockingAndOpaqueBarriers")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.text.transform : UnicodeTransformEpoch;
    UnicodeTransformUnit[16] inputUnits, outputUnits;
    UnicodeSourceSpan[64] inputSpans, outputSpans;
    UnicodeTransformEpoch[1] inputEpoch, outputEpoch;
    auto input = UnicodeTransformWorkspace(units: inputUnits[], spans: inputSpans[], epoch: inputEpoch[]);
    auto output = UnicodeTransformWorkspace(units: outputUnits[], spans: outputSpans[], epoch: outputEpoch[]);
    UnicodeNormalizationItem[32] items;
    size_t[32] ordering;
    auto scratch = UnicodeNormalizationScratch(items[], ordering[]);
    dchar[1] hangul = [0xAC01];
    normalizationInput(hangul[], input);
    assert(normalizeText(input.output(), UnicodeNormalization.NFD, output, scratch).succeeded());
    auto view = output.output();
    assert(view.units.length == 3 && view.units[0].value == 0x1100
        && view.units[1].value == 0x1161 && view.units[2].value == 0x11A8);
    assert(view.units[0].provenanceStart == view.units[2].provenanceStart);
    dchar[3] jamo = [0x1100, 0x1161, 0x11A8];
    normalizationInput(jamo[], input);
    assert(normalizeText(input.output(), UnicodeNormalization.NFC, output, scratch).succeeded());
    view = output.output();
    assert(view.units.length == 1 && view.units[0].value == 0xAC01);
    assert(view.contributingSourceSpans(0).length == 3);
    dchar[2] bengali = [0x09C7, 0x09BE];
    normalizationInput(bengali[], input);
    assert(normalizeText(input.output(), UnicodeNormalization.NFC, output, scratch).succeeded());
    view = output.output();
    assert(view.units.length == 1 && view.units[0].value == 0x09CB);
    UnicodeSourceSpan[2] bengaliSources = [UnicodeSourceSpan(0, 1), UnicodeSourceSpan(3, 4)];
    assert(view.contributingSourceSpans(0) == bengaliSources[]);
    dchar[1] ligature = [0xFB03];
    normalizationInput(ligature[], input);
    assert(normalizeText(input.output(), UnicodeNormalization.NFKD, output, scratch).succeeded());
    view = output.output();
    assert(view.units.length == 3 && view.units[0].value == 'f'
        && view.units[1].value == 'f' && view.units[2].value == 'i');
    assert(view.contributingSourceSpans(0) == view.contributingSourceSpans(2));
    dchar[3] blocked = ['A', 0x0305, 0x0300];
    normalizationInput(blocked[], input);
    assert(normalizeText(input.output(), UnicodeNormalization.NFC, output, scratch).succeeded());
    view = output.output();
    assert(view.units.length == 3 && view.units[0].value == 'A' && view.units[2].value == 0x0300);
    dchar[3] barrier = ['A', 0, 0x0300];
    normalizationInput(barrier[], input);
    input.constructionUnits()[1].kind = UtfTokenKind.opaqueByte;
    input.constructionUnits()[1].opaqueByte = 0xFF;
    assert(normalizeText(input.output(), UnicodeNormalization.NFC, output, scratch).succeeded());
    view = output.output();
    assert(view.units.length == 3 && view.units[0].value == 'A'
        && view.units[1].isOpaque() && view.units[1].opaqueByte == 0xFF
        && view.units[2].value == 0x0300);
    dchar[1] excluded = [0x0344];
    normalizationInput(excluded[], input);
    assert(normalizeText(input.output(), UnicodeNormalization.NFC, output, scratch).succeeded());
    view = output.output();
    assert(view.units.length == 2 && view.units[0].value == 0x0308 && view.units[1].value == 0x0301);
}

@("text.normalization.capacityInvalidationScalarOptionsAndOverlap")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.text.transform : UnicodeTransformEpoch;
    UnicodeTransformUnit[8] inputUnits, outputUnits;
    UnicodeSourceSpan[32] inputSpans, outputSpans;
    UnicodeTransformEpoch[1] inputEpoch, outputEpoch;
    auto input = UnicodeTransformWorkspace(units: inputUnits[], spans: inputSpans[], epoch: inputEpoch[]);
    auto output = UnicodeTransformWorkspace(units: outputUnits[], spans: outputSpans[], epoch: outputEpoch[]);
    UnicodeNormalizationItem[8] items;
    size_t[8] ordering;
    auto scratch = UnicodeNormalizationScratch(items[], ordering[]);
    dchar[3] values = ['A', 0x0315, 0x0300];
    normalizationInput(values[], input);
    assert(normalizeText(input.output(), UnicodeNormalization.NFD, output, scratch).succeeded());
    const old = output.output();
    auto shortScratch = UnicodeNormalizationScratch(items[], ordering[0 .. 1]);
    auto failure = normalizeText(input.output(), UnicodeNormalization.NFD, output, shortScratch);
    assert(failure.status == UnicodeStatus.workspaceFull && failure.required == 2);
    assert(!old.valid() && !output.output().valid() && output.output().units.length == 0);
    shortScratch = UnicodeNormalizationScratch(items[0 .. 2], ordering[]);
    failure = normalizeText(input.output(), UnicodeNormalization.NFD, output, shortScratch);
    assert(failure.status == UnicodeStatus.workspaceFull && failure.required == 3);
    output.units = outputUnits[0 .. 1];
    failure = normalizeText(input.output(), UnicodeNormalization.NFD, output, scratch);
    assert(failure.status == UnicodeStatus.outputFull && failure.required == 2);
    output.units = outputUnits[];
    output.spans = outputSpans[0 .. 1];
    failure = normalizeText(input.output(), UnicodeNormalization.NFD, output, scratch);
    assert(failure.status == UnicodeStatus.workspaceFull && failure.required == 2);
    output.spans = outputSpans[];
    failure = normalizeText(input.output(), cast(UnicodeNormalization) 255, output, scratch);
    assert(failure.status == UnicodeStatus.invalidOptions && !output.output().valid());
    input.constructionUnits()[0].value = cast(dchar) 0xD800;
    failure = normalizeText(input.output(), UnicodeNormalization.NFC, output, scratch);
    assert(failure.status == UnicodeStatus.invalidInput && !output.output().valid());
    input.constructionUnits()[0].value = 'A';
    output.units = inputUnits[];
    failure = normalizeText(input.output(), UnicodeNormalization.NFC, output, scratch);
    assert(failure.status == UnicodeStatus.overlap && !output.output().valid());
    assert(input.output().valid() && input.output().units[0].value == 'A');
}
