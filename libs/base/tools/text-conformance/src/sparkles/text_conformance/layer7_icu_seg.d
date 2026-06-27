/**
 * Layer 7 — grapheme segmentation vs ICU (`icu4c`), the reference UAX#29
 * implementation.
 *
 * Drives ICU's `ubrk_*` (UBRK_CHARACTER) break iterator in process through the
 * `sparkles.icu` wrapper and compares its cluster boundaries to
 * `byGraphemeCluster`. ICU tracks current Unicode (76.1 ≈ Unicode 16), so like
 * Layer 6 it cross-checks the library's older `std.uni` (15.0) segmentation from
 * a live, authoritative source — the gold standard alongside utf8proc.
 *
 * Gated behind `version(TextConformanceIcu)`.
 */
module sparkles.text_conformance.layer7_icu_seg;

import std.algorithm : map, equal;
import std.array : array, join;
import std.conv : to;
import std.format : format;
import std.range : walkLength;
import std.utf : byDchar;

import sparkles.base.text.grapheme : byGraphemeCluster;

import sparkles.text_conformance.config : Config;
import sparkles.text_conformance.corpus : emojiStrings, graphemeBreakStrings;
import sparkles.text_conformance.report : Divergence, LayerResult;
import sparkles.text_conformance.util : libClusters;

version (TextConformanceIcu)
    import sparkles.icu;

version (TextConformanceIcu)
LayerResult runLayer7(in Config cfg)
{
    LayerResult r;
    r.name = "7: ICU segmentation";

    auto corpus = emojiStrings(cfg) ~ graphemeBreakStrings(cfg);
    int[256] buf;
    foreach (s; corpus)
    {
        auto cps = s.byDchar.array;
        if (cps.length == 0)
            continue;

        const n = () @trusted {
            return sp_icu_grapheme_lengths(s.ptr, cast(int) s.length, buf.ptr, 256);
        }();
        if (n < 0)
            continue; // conversion/overflow error — skip (corpus strings are short)

        size_t[] want;
        foreach (i; 0 .. n)
            want ~= cast(size_t) buf[i];

        const got = libClusters(s);
        if (got.equal(want))
        {
            r.passed++;
            continue;
        }

        r.divergences ~= Divergence(7,
            cps.map!(cp => format("%04X", cast(uint) cp)).join(" "),
            got.map!(x => x.to!string).join(","),
            want.map!(x => x.to!string).join(","),
            "live UAX#29 (ICU 76 / Unicode 16) vs std.uni (15.0) grapheme boundary");
    }

    return r;
}
else
LayerResult runLayer7(in Config cfg)
{
    LayerResult r;
    r.name = "7: ICU segmentation";
    r.skipped = true;
    r.skipReason = "built without ICU (use the default 'application' config)";
    return r;
}
