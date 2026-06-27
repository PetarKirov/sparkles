/**
 * Layer 0 — grapheme segmentation vs the official `GraphemeBreakTest.txt`.
 *
 * Each test line denotes a string with `÷` (cluster boundary) and `×` (no
 * boundary) between hex code points, e.g. `÷ 0061 × 0301 ÷`. The `÷`/`×` marks
 * *are* the UAX#29 ground truth — no second implementation is needed. We build
 * the string, run `byGraphemeCluster`, and check that its cluster lengths match
 * the lengths the line prescribes.
 *
 * This corpus must match the SEGMENTATION Unicode version (Phobos `std.uni`),
 * not the width version; mismatches in recently-added scripts are the signal
 * that `--segmentation-unicode-version` is set wrong (see config.d).
 */
module sparkles.text_conformance.layer0_segmentation;

import std.array : appender, join;
import std.algorithm : map, splitter, findSplit;
import std.conv : to;
import std.range : walkLength;
import std.string : strip, lineSplitter;
import std.utf : byDchar;

import sparkles.base.text.grapheme : byGraphemeCluster;

import sparkles.text_conformance.config : Config;
import sparkles.text_conformance.report : Divergence, LayerResult;
import sparkles.text_conformance.ucd : ucdText;

/// One parsed test line: the code points and the cluster lengths it prescribes.
private struct Case
{
    dchar[] cps;
    size_t[] clusterLengths;
}

/// Parse a `GraphemeBreakTest.txt` line. Returns a zero-cp `Case` for
/// comment/blank lines (the caller skips those).
private Case parseLine(string line) @safe
{
    Case c;
    size_t cur;
    foreach (tok; line.splitter(' '))
    {
        if (tok == "÷")
        {
            if (cur > 0) { c.clusterLengths ~= cur; cur = 0; }
        }
        else if (tok == "×" || tok.length == 0)
        {
            // no-boundary marker / padding — stays in the current cluster
        }
        else
        {
            c.cps ~= cast(dchar) tok.to!uint(16);
            cur++;
        }
    }
    if (cur > 0)
        c.clusterLengths ~= cur;
    return c;
}

LayerResult runLayer0(in Config cfg)
{
    const text = ucdText(cfg.segVersion, "auxiliary/GraphemeBreakTest.txt", cfg);

    LayerResult r;
    r.name = "0: segmentation";

    foreach (raw; text.lineSplitter)
    {
        const line = raw.findSplit("#")[0].strip;
        if (line.length == 0)
            continue;

        const c = parseLine(line);
        if (c.cps.length == 0)
            continue;

        // Build the UTF-8 string the line denotes.
        auto buf = appender!string;
        foreach (cp; c.cps)
            buf.put(cp);

        // Cluster lengths (in code points) the library produces.
        size_t[] got;
        foreach (u; buf[].byGraphemeCluster)
        {
            if (u.isEscape)
                continue;
            got ~= u.slice.byDchar.walkLength;
        }

        if (got == c.clusterLengths)
        {
            r.passed++;
            continue;
        }

        r.divergences ~= Divergence(
            0,
            c.cps.map!(cp => format04X(cp)).join(" "),
            got.map!(n => n.to!string).join(","),
            c.clusterLengths.map!(n => n.to!string).join(","),
            "cluster-length mismatch",
        );
    }

    return r;
}

private string format04X(dchar cp) @safe
{
    import std.format : format;
    return format("%04X", cast(uint) cp);
}
