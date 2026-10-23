/**
FTS11 JSTF tests: script, extender-glyph and priority enumeration over
fixture tables (every priority record, each lookup-index list into
caller storage), absence on a face without one, and malformed records
reported as errors rather than as absent or short lists.
*/
module sparkles.font.jstf_test;

import sparkles.font;
import sparkles.font.fixtures;

/// A lookup-index list: count, then indices.
private ubyte[] lookupList(const(ushort)[] indices) @safe pure nothrow
{
    ubyte[] t = u16(cast(uint) indices.length);
    foreach (i; indices)
        t ~= u16(i);
    return t;
}

/**
A `JstfPriority` record (20 bytes of offsets) followed by its lists: the
lists are given by `JstfList` order, empty for an absent one; `maxima`
attaches shrinkage and extension maximum records (pointed at the first
list's bytes: only their presence is read).
*/
private ubyte[] priority(const(int[])[] lists, bool[2] maxima = [false, false]) @safe pure nothrow
in (lists.length == 8)
{
    ubyte[] body;
    uint[8] offsets;
    foreach (i, list; lists)
        if (list.length)
        {
            offsets[i] = cast(uint)(20 + body.length);
            ushort[] indices;
            foreach (v; list)
                indices ~= cast(ushort) v;
            body ~= lookupList(indices);
        }
    const maximumAt = body.length ? 20u : 0u;
    return u16(offsets[0]) ~ u16(offsets[1]) ~ u16(offsets[2]) ~ u16(offsets[3])
        ~ u16(maxima[0] ? maximumAt : 0) ~ u16(offsets[4]) ~ u16(offsets[5]) ~ u16(offsets[6])
        ~ u16(offsets[7]) ~ u16(maxima[1] ? maximumAt : 0) ~ body;
}

/**
A `JSTF` with one `DFLT` script: extenders {3, 5} and a default language
system holding `priorities`, in order.
*/
private ubyte[] jstfTable(const(ubyte[])[] priorities) @safe pure nothrow
{
    // JstfLangSys: a priority count, its offset array, then the records.
    ubyte[] langSys = u16(cast(uint) priorities.length);
    uint at = cast(uint)(2 + 2 * priorities.length);
    foreach (p; priorities)
    {
        langSys ~= u16(at);
        at += cast(uint) p.length;
    }
    foreach (p; priorities)
        langSys ~= p;
    const extenders = u16(2) ~ u16(3) ~ u16(5); // ExtenderGlyph: count, then glyph IDs
    // Script: a 12-byte header (extender, default langsys, count, one
    // record), then ExtenderGlyph, then the language system.
    const scriptHeader = 6 + 6;
    const langSysAt = cast(uint)(scriptHeader + extenders.length);
    const script = u16(scriptHeader) ~ u16(langSysAt) ~ u16(1)
        ~ cast(const(ubyte)[]) "ROM " ~ u16(langSysAt) ~ extenders ~ langSys;
    return u32(0x0001_0000) ~ u16(1) ~ cast(const(ubyte)[]) "DFLT" ~ u16(12) ~ script;
}

private const(ubyte)[] withJstf(const(ubyte)[] jstf) @safe pure nothrow
{
    auto tables = minimalTables(6);
    tables ~= TableData("JSTF", jstf);
    return sfnt(tables);
}

@("jstf.enumeration.fixture")
@safe pure nothrow
unittest
{
    // Priority 0 enables GSUB lookup 7 for shrinkage and GPOS lookup 9
    // for extension, with a shrinkage maximum; priority 1 disables GSUB
    // lookups 1, 2 and 3 for extension.
    const bytes = withJstf(jstfTable([
        priority([[7], [], [], [], [], [], [9], []], [true, false]),
        priority([[], [], [], [], [], [1, 2, 3], [], []]),
    ]));
    const face = openFace(bytes).value;
    assert(hasJstf(face).value);
    Tag[4] scripts;
    assert(jstfScripts(face, scripts[]).value == 1 && scripts[0] == Tag("DFLT"));
    uint[8] extenders;
    const n = jstfExtenderGlyphs(face, Tag("DFLT"), extenders[]);
    assert(n.hasValue && n.value == 2 && extenders[0] == 3 && extenders[1] == 5);

    assert(jstfPriorityCount(face, Tag("DFLT"), Tag.init).value == 2);
    const first = jstfPriority(face, Tag("DFLT"), Tag.init).value;
    assert(first.present && first.hasShrinkageMaximum && !first.hasExtensionMaximum);
    assert(first.listLength(JstfList.shrinkEnableGsub) == 1 && first.listLength(JstfList.extendEnableGpos) == 1
        && first.listLength(JstfList.extendDisableGsub) == 0);
    ushort[4] lookups;
    assert(jstfPriorityLookups(face, Tag("DFLT"), Tag.init, 0, JstfList.shrinkEnableGsub, lookups[]).value == 1
        && lookups[0] == 7);
    assert(jstfPriorityLookups(face, Tag("DFLT"), Tag.init, 0, JstfList.extendEnableGpos, lookups[]).value == 1
        && lookups[0] == 9);

    // The second record, past what the first reported.
    const second = jstfPriority(face, Tag("DFLT"), Tag.init, 1).value;
    assert(second.present && !second.hasShrinkageMaximum && second.listLength(JstfList.extendDisableGsub) == 3);
    ushort[3] exact;
    assert(jstfPriorityLookups(face, Tag("DFLT"), Tag.init, 1, JstfList.extendDisableGsub, exact[]).value == 3
        && exact == [1, 2, 3]);
    ushort[2] short_ = [9, 9];
    const tooShort = jstfPriorityLookups(face, Tag("DFLT"), Tag.init, 1, JstfList.extendDisableGsub, short_[]);
    assert(tooShort.hasError && tooShort.error.limit == FontLimit.callerStorage && tooShort.error.needed == 3);
    assert(short_ == [9, 9]);

    // Past the last record, an unknown language and an unknown script are absent.
    assert(!jstfPriority(face, Tag("DFLT"), Tag.init, 2).value.present);
    assert(!jstfPriority(face, Tag("DFLT"), Tag("JAN ")).value.present);
    assert(jstfPriorityCount(face, Tag("latn"), Tag.init).value == 0);
    assert(!jstfPriority(face, Tag("latn"), Tag.init).value.present);
}

/// A list longer than any fixed array is copied whole: no silent cap.
@("jstf.priority.longList")
@safe pure nothrow
unittest
{
    int[] many;
    foreach (i; 0 .. 40)
        many ~= i;
    const bytes = withJstf(jstfTable([priority([many, [], [], [], [], [], [], []])]));
    const face = openFace(bytes).value;
    assert(jstfPriority(face, Tag("DFLT"), Tag.init).value.listLength(JstfList.shrinkEnableGsub) == 40);
    ushort[40] all;
    assert(jstfPriorityLookups(face, Tag("DFLT"), Tag.init, 0, JstfList.shrinkEnableGsub, all[]).value == 40);
    assert(all[39] == 39);
}

/// Malformed priority data is its error, distinct from absence and from a long list.
@("jstf.priority.malformed")
@safe pure nothrow
unittest
{
    // A list whose count runs past the table.
    auto table = jstfTable([priority([[7, 8], [], [], [], [], [], [], []])]);
    table[$ - 5] = 0xFF; // the list's count becomes 255
    auto face = openFace(withJstf(table)).value;
    const truncated = jstfPriority(face, Tag("DFLT"), Tag.init);
    assert(truncated.hasError && truncated.error.kind == FontErrorKind.truncated && truncated.error.tag == Tag("JSTF"));
    ushort[4] lookups;
    assert(jstfPriorityLookups(face, Tag("DFLT"), Tag.init, 0, JstfList.shrinkEnableGsub, lookups[]).hasError);

    // A null priority offset.
    auto nullRecord = jstfTable([priority([[7], [], [], [], [], [], [], []])]);
    const langSysAt = nullRecord.length - priority([[7], [], [], [], [], [], [], []]).length - 4;
    nullRecord[langSysAt + 2] = 0;
    nullRecord[langSysAt + 3] = 0;
    face = openFace(withJstf(nullRecord)).value;
    const badOffset = jstfPriority(face, Tag("DFLT"), Tag.init);
    assert(badOffset.hasError && badOffset.error.kind == FontErrorKind.badOffset);

    // A table too short for its header: present but unreadable.
    face = openFace(withJstf(u32(0x0001_0000))).value;
    assert(hasJstf(face).hasError && jstfPriorityCount(face, Tag("DFLT"), Tag.init).hasError);
}

@("jstf.enumeration.absent")
@safe pure nothrow
unittest
{
    const bytes = sfnt(minimalTables(2));
    const face = openFace(bytes).value;
    assert(!hasJstf(face).value);
    Tag[2] scripts;
    assert(jstfScripts(face, scripts[]).value == 0);
    assert(jstfPriorityCount(face, Tag("DFLT"), Tag.init).value == 0);
    assert(!jstfPriority(face, Tag("DFLT"), Tag.init).value.present);
}
