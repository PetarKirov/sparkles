/**
 * Layer 1 — exhaustive per-code-point width sweep.
 *
 * For every Unicode scalar value (0..0x10FFFF minus the surrogate range), compare
 * `sparkles.base.text.width.codepointWidth` against the clean-room raw-UCD
 * `oracleCodepointWidth`. Divergences are bucketed by general category so the
 * summary shows *where* any disagreement lives (e.g. "all in Mc" points at a
 * spacing-mark policy or version skew rather than a random bug).
 */
module sparkles.text_conformance.layer1_width;

import std.conv : to;
import std.format : format;

import sparkles.base.text.width : codepointWidth;

import sparkles.text_conformance.config : Config;
import sparkles.text_conformance.oracle : oracleCodepointWidth;
import sparkles.text_conformance.report : Divergence, LayerResult;
import sparkles.text_conformance.ucd : loadWidthData, WidthData;

/// Diagnostic label for which class a code point falls in (oracle's view).
private string classify(dchar cp, in WidthData d) @safe nothrow
{
    if (cp >= 0x1F1E6 && cp <= 0x1F1FF) return "RegionalIndicator";
    if (d.controls[cp]) return "Cc";
    if (d.mn[cp]) return "Mn";
    if (d.mc[cp]) return "Mc";
    if (d.me[cp]) return "Me";
    if (d.cf[cp]) return "Cf";
    if (d.wide[cp]) return "EAW-W/F";
    return "other";
}

LayerResult runLayer1(in Config cfg)
{
    auto d = loadWidthData(cfg);

    LayerResult r;
    r.name = "1: codepoint width";

    size_t[string] buckets;
    foreach (uint cp; 0 .. 0x110000)
    {
        if (cp >= 0xD800 && cp <= 0xDFFF)
            continue; // surrogates are not scalar values

        const dc = cast(dchar) cp;
        const got = codepointWidth(dc);
        const want = oracleCodepointWidth(dc, d);
        if (got == want)
        {
            r.passed++;
            continue;
        }

        const cat = classify(dc, d);
        buckets[cat]++;
        r.divergences ~= Divergence(
            1,
            format("U+%04X", cp),
            got.to!string,
            want.to!string,
            format("%s (impl=%d oracle=%d)", cat, got, want),
        );
    }

    foreach (cat, n; buckets)
        r.notes ~= format("%s: %d divergence(s)", cat, n);

    return r;
}
