/**
Justification table enumeration (`docs/specs/font/SPEC.md` FTS11).

`JSTF` is read as data: its scripts and language systems, each script's
extender glyphs, and the priority records of lookup indices that
shrinkage and extension enable or disable. Absence (no table, no such
script or language) is reported as not present, malformed data as its
error, and an unknown version as `unsupportedVersion`. Measuring what a
record would do to a run is the shaping engine's job; choosing budgets
and inserting extenders is layout's.
*/
module sparkles.font.jstf;

import sparkles.font.bytes : be16, be32, fits;
import sparkles.font.errors : callerStorageError, FontError, FontErrorKind, FontResult,
    fontErr, fontOk, Tag, tableError;
import sparkles.font.face : Face;
import sparkles.font.tables : locate;

@safe pure nothrow @nogc:

private enum jstfTag = Tag("JSTF");

private struct Jstf
{
    const(ubyte)[] data;
    ulong start;
    ushort scriptCount;
}

/// The face's `JSTF` header: not present (not an error) without the table.
private FontResult!Jstf jstfHeader(return scope const Face face)
{
    auto at = locate(face, jstfTag);
    if (at.hasError)
        return fontErr!Jstf(at.error);
    const d = at.value.data;
    if (d.length < 6)
        return fontErr!Jstf(tableError(FontErrorKind.truncated, jstfTag, at.value.start,
            d.length));
    if (be16(d, 0) != 1)
        return fontErr!Jstf(tableError(FontErrorKind.unsupportedVersion, jstfTag,
            at.value.start, 0));
    Jstf j;
    j.data = d;
    j.start = at.value.start;
    j.scriptCount = be16(d, 4);
    if (!fits(d.length, 6, 6UL * j.scriptCount))
        return fontErr!Jstf(tableError(FontErrorKind.truncated, jstfTag, at.value.start, 6));
    return fontOk(j);
}

/// Whether the face has a `JSTF` table (FTS11): `false` without one, the table's error when it is unreadable.
FontResult!bool hasJstf(return scope const Face face)
{
    if (!face.has(jstfTag))
        return fontOk(false);
    const j = jstfHeader(face);
    if (j.hasError)
        return fontErr!bool(j.error);
    return fontOk(true);
}

/// The eight lookup-index lists of a `JstfPriority` record, in record order (FTS11).
enum JstfList : ubyte
{
    shrinkEnableGsub,
    shrinkDisableGsub,
    shrinkEnableGpos,
    shrinkDisableGpos,
    extendEnableGsub,
    extendDisableGsub,
    extendEnableGpos,
    extendDisableGpos,
}

/// Each list's offset field in a `JstfPriority` record; the maxima sit at 8 and 18.
private immutable ubyte[JstfList.max + 1] listField = [0, 2, 4, 6, 10, 12, 14, 16];

/**
One priority record of a language system (FTS11): the length of each
lookup-index list, and whether a `JstfMax` record is attached. A maximum
record holds `JSTF`'s own lookups, which the shaping engine cannot apply:
measuring one is `unsupportedCapability`
(`JustificationMode.maximumLookups`), never a manufactured result.
*/
struct JstfPriorityInfo
{
    @safe pure nothrow @nogc:

    /// Whether the record exists: its table, script, language system and index.
    bool present;
    /// Whether a `JstfMax` record is attached for shrinkage / extension.
    bool hasShrinkageMaximum, hasExtensionMaximum;
    /// The number of lookup indices in each list, by `JstfList`; 0 for an absent list.
    ushort[JstfList.max + 1] listLengths;

    /// The number of lookup indices in `list`.
    size_t listLength(JstfList list) const => listLengths[list];
}

/// Where priority record `index` of a language system sits, when present.
private struct PriorityAt
{
    bool present;
    const(ubyte)[] data;
    ulong start;
    size_t at;
}

/**
The language system `language` of `script` (the default one for
`Tag.init`): its offset, or `size_t.max` when the table, the script or
the language system is absent.
*/
private FontResult!PriorityAt languageSystem(return scope const Face face, Tag script, Tag language,
    out size_t langSysAt)
{
    langSysAt = size_t.max;
    if (!face.has(jstfTag))
        return fontOk(PriorityAt.init);
    const j = jstfHeader(face);
    if (j.hasError)
        return fontErr!PriorityAt(j.error);
    PriorityAt p;
    p.data = j.value.data;
    p.start = j.value.start;
    if (scriptOffset(j.value, script) == size_t.max)
        return fontOk(p);
    const view = scriptView(j.value, script);
    if (view.hasError)
        return fontErr!PriorityAt(view.error);
    if (language.isNone)
    {
        if (view.value.defaultLangSysAt != 0)
            langSysAt = view.value.at + view.value.defaultLangSysAt;
    }
    else
        foreach (i; 0 .. view.value.langSysCount)
        {
            const recordAt = view.value.at + 6 + 6 * i;
            if (Tag(be32(p.data, recordAt)) == language)
            {
                langSysAt = view.value.at + be16(p.data, recordAt + 4);
                break;
            }
        }
    if (langSysAt != size_t.max && !fits(p.data.length, langSysAt, 2))
        return fontErr!PriorityAt(tableError(FontErrorKind.truncated, jstfTag, p.start, langSysAt));
    return fontOk(p);
}

/**
The number of priority records of `script`'s language system `language`
(FTS11), the default one for `Tag.init`; 0 when the table, script or
language system is absent.
*/
FontResult!size_t jstfPriorityCount(return scope const Face face, Tag script, Tag language)
{
    size_t langSysAt;
    const p = languageSystem(face, script, language, langSysAt);
    if (p.hasError)
        return fontErr!size_t(p.error);
    if (langSysAt == size_t.max)
        return fontOk!size_t(0);
    const count = be16(p.value.data, langSysAt);
    if (!fits(p.value.data.length, langSysAt + 2, 2UL * count))
        return fontErr!size_t(tableError(FontErrorKind.truncated, jstfTag, p.value.start, langSysAt + 2));
    return fontOk!size_t(count);
}

/// Priority record `index`, with every list header checked.
private FontResult!PriorityAt priorityRecord(return scope const Face face, Tag script, Tag language,
    size_t index)
{
    const count = jstfPriorityCount(face, script, language);
    if (count.hasError)
        return fontErr!PriorityAt(count.error);
    size_t langSysAt;
    auto p = languageSystem(face, script, language, langSysAt).value;
    if (index >= count.value)
        return fontOk(PriorityAt.init);
    const d = p.data;
    const offset = be16(d, langSysAt + 2 + 2 * index);
    if (offset == 0)
        return fontErr!PriorityAt(tableError(FontErrorKind.badOffset, jstfTag, p.start, langSysAt + 2 + 2 * index));
    const at = langSysAt + offset;
    if (!fits(d.length, at, 20))
        return fontErr!PriorityAt(tableError(FontErrorKind.truncated, jstfTag, p.start, at));
    foreach (field; listField)
    {
        const listOffset = be16(d, at + field);
        if (listOffset == 0)
            continue;
        const listAt = at + listOffset;
        if (!fits(d.length, listAt, 2) || !fits(d.length, listAt + 2, 2UL * be16(d, listAt)))
            return fontErr!PriorityAt(tableError(FontErrorKind.truncated, jstfTag, p.start, listAt));
    }
    p.present = true;
    p.at = at;
    return fontOk(p);
}

/**
Priority record `index` of `script`'s language system `language` (FTS11),
the default one for `Tag.init`. Absence of the table, script, language
system or index is `present == false`; a list or record that does not
fit the table is `truncated`, and a null record offset `badOffset`.
Costs O(s + l) for `s` scripts and `l` language systems.
*/
FontResult!JstfPriorityInfo jstfPriority(return scope const Face face, Tag script, Tag language,
    size_t index = 0)
{
    const p = priorityRecord(face, script, language, index);
    if (p.hasError)
        return fontErr!JstfPriorityInfo(p.error);
    JstfPriorityInfo info;
    if (!p.value.present)
        return fontOk(info);
    const d = p.value.data, at = p.value.at;
    info.present = true;
    info.hasShrinkageMaximum = be16(d, at + 8) != 0;
    info.hasExtensionMaximum = be16(d, at + 18) != 0;
    foreach (list, field; listField)
    {
        const listOffset = be16(d, at + field);
        info.listLengths[list] = listOffset ? be16(d, at + listOffset) : 0;
    }
    return fontOk(info);
}

/**
The lookup indices of `list` in priority record `index` (FTS11), written
to `out_`: the count. An absent record or list is a count of zero;
`callerStorage` names the count in `needed` when `out_` is shorter.
*/
FontResult!size_t jstfPriorityLookups(return scope const Face face, Tag script, Tag language, size_t index,
    JstfList list, scope ushort[] out_)
{
    const p = priorityRecord(face, script, language, index);
    if (p.hasError)
        return fontErr!size_t(p.error);
    if (!p.value.present)
        return fontOk!size_t(0);
    const d = p.value.data;
    const listOffset = be16(d, p.value.at + listField[list]);
    if (listOffset == 0)
        return fontOk!size_t(0);
    const listAt = p.value.at + listOffset;
    const count = be16(d, listAt);
    if (count > out_.length)
        return fontErr!size_t(callerStorageError(count, jstfTag, p.value.start + listAt, listAt));
    foreach (i; 0 .. count)
        out_[i] = be16(d, listAt + 2 + 2 * i);
    return fontOk!size_t(count);
}


/**
The `JSTF` script tags, in table order, written to `out` (FTS11): the
count, with `callerStorage` exhaustion naming the count in `needed`.
No table is a count of zero.
*/
FontResult!size_t jstfScripts(return scope const Face face, scope Tag[] out_)
{
    if (!face.has(jstfTag))
        return fontOk!size_t(0);
    const j = jstfHeader(face);
    if (j.hasError)
        return fontErr!size_t(j.error);
    if (j.value.scriptCount > out_.length)
        return fontErr!size_t(callerStorageError(j.value.scriptCount, jstfTag,
            j.value.start, 4));
    foreach (i; 0 .. j.value.scriptCount)
        out_[i] = Tag(be32(j.value.data, 6 + 6 * i));
    return fontOk!size_t(j.value.scriptCount);
}

/// The offset of script `script`'s record, or `size_t.max` when absent.
private size_t scriptOffset(in Jstf j, Tag script)
{
    foreach (i; 0 .. j.scriptCount)
        if (Tag(be32(j.data, 6 + 6 * i)) == script)
            return be16(j.data, 6 + 6 * i + 4);
    return size_t.max;
}

private struct ScriptView
{
    size_t at;
    ushort extenderAt;
    ushort defaultLangSysAt;
    ushort langSysCount;
}

private FontResult!ScriptView scriptView(in Jstf j, Tag script)
{
    const offset = scriptOffset(j, script);
    if (offset == size_t.max)
        return fontErr!ScriptView(FontError(FontErrorKind.missingTable, script));
    const at = offset;
    if (!fits(j.data.length, at, 6))
        return fontErr!ScriptView(tableError(FontErrorKind.truncated, jstfTag, j.start, at));
    ScriptView v;
    v.at = at;
    v.extenderAt = be16(j.data, at);
    v.defaultLangSysAt = be16(j.data, at + 2);
    v.langSysCount = be16(j.data, at + 4);
    if (!fits(j.data.length, at + 6, 6UL * v.langSysCount))
        return fontErr!ScriptView(tableError(FontErrorKind.truncated, jstfTag, j.start, at + 4));
    return fontOk(v);
}

/**
The extender glyphs of `script` (FTS11), through its ExtenderGlyph table, written
to `out`: the count; a script without an extender table, or a face
without `JSTF`, is a count of zero.
*/
FontResult!size_t jstfExtenderGlyphs(return scope const Face face, Tag script,
    scope uint[] out_)
{
    if (!face.has(jstfTag))
        return fontOk!size_t(0);
    const j = jstfHeader(face);
    if (j.hasError)
        return fontErr!size_t(j.error);
    if (scriptOffset(j.value, script) == size_t.max)
        return fontOk!size_t(0);
    const view = scriptView(j.value, script);
    if (view.hasError)
        return fontErr!size_t(view.error);
    if (view.value.extenderAt == 0)
        return fontOk!size_t(0);
    const d = j.value.data;
    const at = view.value.at + view.value.extenderAt;
    if (!fits(d.length, at, 2))
        return fontErr!size_t(tableError(FontErrorKind.truncated, jstfTag, j.value.start, at));
    const count = be16(d, at);
    if (!fits(d.length, at + 2, 2UL * count))
        return fontErr!size_t(tableError(FontErrorKind.truncated, jstfTag, j.value.start, at + 2));
    if (count > out_.length)
        return fontErr!size_t(callerStorageError(count, jstfTag, j.value.start, at));
    foreach (i; 0 .. count)
        out_[i] = be16(d, at + 2 + 2 * i);
    return fontOk!size_t(count);
}
