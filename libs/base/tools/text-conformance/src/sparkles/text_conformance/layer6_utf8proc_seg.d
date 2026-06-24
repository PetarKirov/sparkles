/**
 * Layer 6 — grapheme segmentation vs utf8proc (a *live* UAX#29 implementation).
 *
 * Layers 0 and 2 check segmentation against static UCD test files; this checks
 * `byGraphemeCluster` against `utf8proc_grapheme_break_stateful` running in
 * process at utf8proc's pinned Unicode version (17.0). Because the library
 * segments via Phobos `std.uni` (Unicode 15.0), the two disagree exactly on the
 * boundaries that changed since 15.0 — Indic conjuncts (InCB) and a couple of
 * emoji/ZWJ cases — independently corroborating the std.uni lag Layer 0 finds at
 * `--segmentation-unicode-version 15.1+`.
 *
 * Gated behind `version(TextConformanceUtf8proc)` (same binding as Layer 5).
 */
module sparkles.text_conformance.layer6_utf8proc_seg;

import std.algorithm : map, equal;
import std.array : appender, array, join;
import std.conv : to;
import std.format : format;
import std.range : walkLength;
import std.utf : byDchar;

import sparkles.base.text.grapheme : byGraphemeCluster;

import sparkles.text_conformance.config : Config;
import sparkles.text_conformance.corpus : emojiStrings, graphemeBreakStrings;
import sparkles.text_conformance.report : Divergence, LayerResult;

version (TextConformanceUtf8proc)
    import sparkles.utf8proc;

/// Cluster lengths (in code points) the library produces for `s`.
private size_t[] libClusters(string s) @safe
{
    size_t[] got;
    foreach (u; s.byGraphemeCluster)
        if (!u.isEscape)
            got ~= u.slice.byDchar.walkLength;
    return got;
}

version (TextConformanceUtf8proc)
LayerResult runLayer6(in Config cfg)
{
    LayerResult r;
    r.name = "6: utf8proc segmentation";

    auto corpus = emojiStrings(cfg) ~ graphemeBreakStrings(cfg);
    foreach (s; corpus)
    {
        auto cps = s.byDchar.array;
        if (cps.length == 0)
            continue;

        // utf8proc cluster lengths via the stateful break predicate.
        size_t[] want;
        int state = 0;
        size_t cur = 1;
        foreach (i; 1 .. cps.length)
        {
            const brk = () @trusted {
                return utf8proc_grapheme_break_stateful(cps[i - 1], cps[i], &state);
            }();
            if (brk) { want ~= cur; cur = 1; }
            else cur++;
        }
        want ~= cur;

        const got = libClusters(s);
        if (got.equal(want))
        {
            r.passed++;
            continue;
        }

        r.divergences ~= Divergence(6,
            cps.map!(cp => format("%04X", cast(uint) cp)).join(" "),
            got.map!(n => n.to!string).join(","),
            want.map!(n => n.to!string).join(","),
            "live UAX#29 (utf8proc 17.0) vs std.uni (15.0) grapheme boundary");
    }

    return r;
}
else
LayerResult runLayer6(in Config cfg)
{
    LayerResult r;
    r.name = "6: utf8proc segmentation";
    r.skipped = true;
    r.skipReason = "built without utf8proc (use the default 'application' config)";
    return r;
}
