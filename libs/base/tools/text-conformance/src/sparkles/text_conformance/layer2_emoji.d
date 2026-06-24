/**
 * Layer 2 — cluster width & segmentation over the official `emoji-test.txt`.
 *
 * Every `fully-qualified` line is, by construction, a single RGI grapheme
 * cluster. For each we assert two independent things:
 *   1. `byGraphemeCluster` coalesces it into exactly one cluster (segmentation),
 *   2. that cluster's width equals the clean-room `oracleClusterWidth`.
 *
 * The emoji corpus tracks the segmentation Unicode version (so std.uni knows
 * the sequences), while the width oracle uses the width version — the two-axis
 * split again.
 */
module sparkles.text_conformance.layer2_emoji;

import std.array : appender, array, join;
import std.algorithm : map, splitter, filter, findSplit;
import std.conv : to;
import std.format : format;
import std.string : strip, lineSplitter;

import sparkles.base.text.grapheme : byGraphemeCluster, ClusterMeasure;

import sparkles.text_conformance.config : Config;
import sparkles.text_conformance.oracle : oracleClusterWidth;
import sparkles.text_conformance.report : Divergence, LayerResult;
import sparkles.text_conformance.ucd : emojiTestText, loadWidthData;

LayerResult runLayer2(in Config cfg)
{
    auto d = loadWidthData(cfg);
    const text = emojiTestText(cfg);

    LayerResult r;
    r.name = "2: emoji clusters";

    size_t mergeFailures, widthFailures;
    foreach (raw; text.lineSplitter)
    {
        // Format: `1F600 1F3FB ; fully-qualified  # 😀 …`
        auto semi = raw.findSplit(";");
        if (!semi[1].length)
            continue;
        const status = semi[2].findSplit("#")[0].strip;
        if (status != "fully-qualified")
            continue;

        auto cps = semi[0].strip.splitter(' ')
            .filter!(t => t.length)
            .map!(t => cast(dchar) t.to!uint(16))
            .array;
        if (cps.length == 0)
            continue;

        auto buf = appender!string;
        foreach (cp; cps)
            buf.put(cp);

        ClusterMeasure[] clusters;
        foreach (u; buf[].byGraphemeCluster)
            if (!u.isEscape)
                clusters ~= u;

        const hexKey = cps.map!(cp => format("%04X", cast(uint) cp)).join(" ");

        // Check 1: the RGI sequence must be a single cluster.
        if (clusters.length != 1)
        {
            mergeFailures++;
            r.divergences ~= Divergence(2, hexKey, clusters.length.to!string, "1",
                "segmentation: RGI emoji split into multiple clusters");
            continue;
        }

        // Check 2: the cluster width must match the independent oracle.
        const want = oracleClusterWidth(cps, d);
        const got = clusters[0].width;
        if (got != want)
        {
            widthFailures++;
            r.divergences ~= Divergence(2, hexKey, got.to!string, want.to!string,
                "cluster-width mismatch");
        }
        else
            r.passed++;
    }

    if (mergeFailures)
        r.notes ~= format("segmentation merge failures: %d", mergeFailures);
    if (widthFailures)
        r.notes ~= format("width mismatches: %d", widthFailures);

    return r;
}
