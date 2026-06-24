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
 * Sweep every scalar value and compare `codepointWidth(cp)` to
 * `utf8proc_charwidth(cp)`. The model differs in three documented places:
 *   - **regional indicators**: sparkles applies kitty's flag rule (2), utf8proc
 *     treats them as ordinary symbols (1);
 *   - **noncharacters**: sparkles discards them (0), utf8proc returns 1;
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

/// Explain a per-code-point width divergence from `cp`'s class.
private string causeOf(dchar cp, in WidthData d) @safe nothrow
{
    if (cp >= 0x1F1E6 && cp <= 0x1F1FF)
        return "regional indicator: sparkles applies kitty's flag-half rule (2); "
            ~ "utf8proc treats it as an ordinary symbol (1)";
    if ((cp >= 0xFDD0 && cp <= 0xFDEF) || (cp & 0xFFFE) == 0xFFFE)
        return "noncharacter: sparkles discards it (0); utf8proc returns 1";
    if (d.mn[cp] || d.mc[cp] || d.me[cp] || d.cf[cp])
        return "Mark/format version skew: UCD 17.0 (utf8proc & the oracle) class "
            ~ "it width 0; sparkles' std.uni (15.0) does not yet";
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
    foreach (uint cp; 0 .. 0x110000)
    {
        if (cp >= 0xD800 && cp <= 0xDFFF)
            continue; // surrogates are not scalar values

        const dc = cast(dchar) cp;
        const got = codepointWidth(dc);
        const want = utf8proc_charwidth(cast(int) cp);
        if (got == want)
        {
            r.passed++;
            continue;
        }

        const cause = causeOf(dc, d);
        buckets[bucketKey(dc, d)]++;
        r.divergences ~= Divergence(5, format("U+%04X", cp),
            got.to!string, want.to!string, cause);
    }

    foreach (k, n; buckets)
        r.notes ~= format("%s: %d", k, n);

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
    if ((cp >= 0xFDD0 && cp <= 0xFDEF) || (cp & 0xFFFE) == 0xFFFE) return "noncharacter";
    if (d.mn[cp] || d.mc[cp] || d.me[cp] || d.cf[cp]) return "mark/format";
    return "other";
}
