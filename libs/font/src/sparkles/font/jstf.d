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

/// Whether the face has a readable `JSTF` table at all.
bool hasJstf(return scope const Face face) => !jstfHeader(face).hasError;

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

/// One priority record's lookup-index lists (FTS11); at most 32 each.
struct JstfPriorityInfo
{
    @safe pure nothrow @nogc:

    /// Whether the language system (and so its priority) exists.
    bool present;
    /// Whether a maximum record is attached for shrinkage / extension.
    bool hasShrinkageMaximum, hasExtensionMaximum;

    ushort[32] shrinkEnableGsub, shrinkDisableGsub, shrinkEnableGpos, shrinkDisableGpos;
    ushort[32] extendEnableGsub, extendDisableGsub, extendEnableGpos, extendDisableGpos;
    size_t shrinkEnableGsubCount, shrinkDisableGsubCount, shrinkEnableGposCount,
        shrinkDisableGposCount, extendEnableGsubCount, extendDisableGsubCount,
        extendEnableGposCount, extendDisableGposCount;
    /// A list longer than 32, truncated into its array above.
    bool overflow;

    private void takeList(const(ubyte)[] d, ulong start, size_t priorityAt, size_t field,
        ushort[] target, ref size_t count)
    {
        const offset = be16(d, priorityAt + field);
        if (offset == 0)
            return;
        const at = priorityAt + offset;
        if (!fits(d.length, at, 2))
        {
            overflow = true;
            return;
        }
        const n = be16(d, at);
        if (!fits(d.length, at + 2, 2UL * n))
        {
            overflow = true;
            return;
        }
        const take = n < 32 ? n : 32;
        foreach (i; 0 .. take)
            target[i] = be16(d, at + 2 + 2 * i);
        count = take;
        if (n > take)
            overflow = true;
    }
}

/**
The first priority record of `script`'s language system `language` (FTS11):
the default language system when `language` is `Tag.init`. Absence of
the table, script, language or priority is `present == false`.
*/
FontResult!JstfPriorityInfo jstfPriority(return scope const Face face, Tag script,
    Tag language)
{
    JstfPriorityInfo info;
    if (!face.has(jstfTag))
        return fontOk(info);
    const j = jstfHeader(face);
    if (j.hasError)
        return fontErr!JstfPriorityInfo(j.error);
    if (scriptOffset(j.value, script) == size_t.max)
        return fontOk(info);
    const view = scriptView(j.value, script);
    if (view.hasError)
        return fontErr!JstfPriorityInfo(view.error);
    const d = j.value.data;
    // Find the language system: default, or by tag.
    size_t langSysAt;
    if (language.isNone)
    {
        if (view.value.defaultLangSysAt == 0)
            return fontOk(info);
        langSysAt = view.value.at + view.value.defaultLangSysAt;
    }
    else
    {
        bool found;
        foreach (i; 0 .. view.value.langSysCount)
        {
            const recordAt = view.value.at + 6 + 6 * i;
            if (Tag(be32(d, recordAt)) == language)
            {
                langSysAt = view.value.at + be16(d, recordAt + 4);
                found = true;
                break;
            }
        }
        if (!found)
            return fontOk(info);
    }
    if (!fits(d.length, langSysAt, 2))
        return fontErr!JstfPriorityInfo(tableError(FontErrorKind.truncated, jstfTag,
            j.value.start, langSysAt));
    const priorityCount = be16(d, langSysAt);
    if (priorityCount == 0)
        return fontOk(info);
    if (!fits(d.length, langSysAt + 2, 2UL * priorityCount))
        return fontErr!JstfPriorityInfo(tableError(FontErrorKind.truncated, jstfTag,
            j.value.start, langSysAt + 2));
    const priorityOffset = be16(d, langSysAt + 2);
    if (priorityOffset == 0)
        return fontOk(info);
    const priorityAt = langSysAt + priorityOffset;
    if (!fits(d.length, priorityAt, 20))
        return fontErr!JstfPriorityInfo(tableError(FontErrorKind.truncated, jstfTag,
            j.value.start, priorityAt));
    info.present = true;
    info.hasShrinkageMaximum = be16(d, priorityAt + 8) != 0;
    info.hasExtensionMaximum = be16(d, priorityAt + 18) != 0;
    info.takeList(d, j.value.start, priorityAt, 0, info.shrinkEnableGsub[],
        info.shrinkEnableGsubCount);
    info.takeList(d, j.value.start, priorityAt, 2, info.shrinkDisableGsub[],
        info.shrinkDisableGsubCount);
    info.takeList(d, j.value.start, priorityAt, 4, info.shrinkEnableGpos[],
        info.shrinkEnableGposCount);
    info.takeList(d, j.value.start, priorityAt, 6, info.shrinkDisableGpos[],
        info.shrinkDisableGposCount);
    info.takeList(d, j.value.start, priorityAt, 10, info.extendEnableGsub[],
        info.extendEnableGsubCount);
    info.takeList(d, j.value.start, priorityAt, 12, info.extendDisableGsub[],
        info.extendDisableGsubCount);
    info.takeList(d, j.value.start, priorityAt, 14, info.extendEnableGpos[],
        info.extendEnableGposCount);
    info.takeList(d, j.value.start, priorityAt, 16, info.extendDisableGpos[],
        info.extendDisableGposCount);
    return fontOk(info);
}
