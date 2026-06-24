/**
 * Layer 5 — per-code-point width vs utf8proc's `utf8proc_charwidth`.
 *
 * utf8proc ([JuliaStrings/utf8proc](https://github.com/JuliaStrings/utf8proc))
 * is a small, widely-used C library with its own data-driven width model — a
 * genuinely independent oracle, linked as a *library* via the `sparkles:utf8proc`
 * ImportC bindings. It pins its own Unicode version (currently **17.0.0**,
 * reported in the notes), which happens to match sparkles' width tables, so this
 * layer also independently corroborates the Layer-1 raw-UCD oracle.
 *
 * Sweep every **assigned** scalar value (plus noncharacters, which sparkles
 * explicitly handles) and compare `codepointWidth(cp)` to
 * `utf8proc_charwidth(cp)`. Unassigned code points are excluded: sparkles
 * follows `EastAsianWidth.txt`'s reserved-Wide defaults for the CJK extension
 * blocks (→ 2) while utf8proc gives any unassigned code point width 1 — a real
 * but uninteresting policy difference over ~56k *reserved* code points nobody
 * renders. The remaining divergences fall in four documented places:
 *   - **regional indicators**: sparkles applies kitty's flag rule (2), utf8proc
 *     treats them as ordinary symbols (1);
 *   - **noncharacters**: sparkles discards them (0), utf8proc returns 1;
 *   - **conjoining Hangul jamo** (medial/final): sparkles forces 0, utf8proc
 *     gives 1 — the same class ghostty (Layer 4) flags, here independently;
 *   - **recently-assigned Marks**: utf8proc (UCD 17.0) gives 0, but sparkles'
 *     categories come from the older `std.uni` (15.0) — the same version skew
 *     Layer 1 reports, here confirmed by a second 17.0 source.
 *
 * Gated behind `version(TextConformanceUtf8proc)` so the offline/unittest builds
 * compile without the native dependency.
 */
module sparkles.text_conformance.layer5_utf8proc;

import std.conv : to;
import std.format : format;

import sparkles.base.text.width : codepointWidth;

import sparkles.text_conformance.config : Config;
import sparkles.text_conformance.report : Divergence, LayerResult;
import sparkles.text_conformance.ucd : loadWidthData, WidthData;

version (TextConformanceUtf8proc)
    import sparkles.utf8proc;

private bool isNoncharacter(dchar cp) @safe pure nothrow @nogc
    => (cp >= 0xFDD0 && cp <= 0xFDEF) || (cp & 0xFFFE) == 0xFFFE;

/// Explain a per-code-point width divergence from `cp`'s class and direction.
private string causeOf(dchar cp, int got, int want, in WidthData d) @safe nothrow
{
    if (cp >= 0x1F1E6 && cp <= 0x1F1FF)
        return "regional indicator: sparkles applies kitty's flag-half rule (2); "
            ~ "utf8proc treats it as an ordinary symbol (1)";
    if (isNoncharacter(cp))
        return "noncharacter: sparkles discards it (0); utf8proc returns 1";
    if (cp >= 0x1160 && cp <= 0x11FF)
        return "conjoining Hangul jamo: sparkles forces width 0 (composes onto the "
            ~ "lead); utf8proc gives 1 — the same class ghostty (Layer 4) flags";
    if ((d.mn[cp] || d.mc[cp] || d.me[cp]) && got == 1 && want == 0)
        return "Mark version skew: sparkles' std.uni (15.0) does not yet class it a "
            ~ "Mark; utf8proc (17.0) does (width 0)";
    if (d.cf[cp])
        return "format char (Cf): sparkles treats it zero-width (0); utf8proc gives 1";
    if (d.mc[cp] && want == 2)
        return "spacing mark: sparkles 0; utf8proc assigns it East-Asian width 2";
    return "codepointWidth vs utf8proc_charwidth";
}

version (TextConformanceUtf8proc)
LayerResult runLayer5(in Config cfg)
{
    auto d = loadWidthData(cfg);

    LayerResult r;
    r.name = "5: utf8proc charwidth";

    import std.string : fromStringz;
    const ver = () @trusted { return utf8proc_unicode_version().fromStringz.idup; }();
    r.notes ~= "utf8proc Unicode version: " ~ ver;

    size_t[string] buckets;
    size_t excludedUnassigned;
    foreach (uint cp; 0 .. 0x110000)
    {
        if (cp >= 0xD800 && cp <= 0xDFFF)
            continue; // surrogates are not scalar values

        const dc = cast(dchar) cp;
        // Skip unassigned code points (except noncharacters, which sparkles
        // explicitly handles): the reserved-Wide vs width-1 split over the CJK
        // extension blocks is a documented, uninteresting policy difference.
        if (utf8proc_category(cast(int) cp) == UTF8PROC_CATEGORY_CN && !isNoncharacter(dc))
        {
            excludedUnassigned++;
            continue;
        }

        const got = codepointWidth(dc);
        const want = utf8proc_charwidth(cast(int) cp);
        if (got == want)
        {
            r.passed++;
            continue;
        }

        buckets[bucketKey(dc, d)]++;
        r.divergences ~= Divergence(5, format("U+%04X", cp),
            got.to!string, want.to!string, causeOf(dc, got, want, d));
    }

    foreach (k, n; buckets)
        r.notes ~= format("%s: %d", k, n);
    r.notes ~= format("excluded %d unassigned code points (reserved-Wide vs 1)",
        excludedUnassigned);

    return r;
}
else
LayerResult runLayer5(in Config cfg)
{
    LayerResult r;
    r.name = "5: utf8proc charwidth";
    r.skipped = true;
    r.skipReason = "built without utf8proc (use the default 'application' config)";
    return r;
}

/// Short bucket label for the summary notes.
private string bucketKey(dchar cp, in WidthData d) @safe nothrow
{
    if (cp >= 0x1F1E6 && cp <= 0x1F1FF) return "regional-indicator";
    if (isNoncharacter(cp)) return "noncharacter";
    if (cp >= 0x1160 && cp <= 0x11FF) return "hangul-jamo";
    if (d.mn[cp] || d.mc[cp] || d.me[cp] || d.cf[cp]) return "mark/format";
    return "other";
}
