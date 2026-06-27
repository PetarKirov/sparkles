/**
 * Shared corpus loaders: the concrete strings the layers measure.
 *
 * Layer 3 feeds these to kitty; keeping the extraction here avoids re-deriving
 * the same strings the segmentation (Layer 0) and emoji (Layer 2) layers parse.
 */
module sparkles.text_conformance.corpus;

import std.array : appender, array;
import std.algorithm : map, splitter, filter, findSplit;
import std.conv : to;
import std.string : strip, lineSplitter;

import sparkles.text_conformance.config : Config;
import sparkles.text_conformance.ucd : emojiTestText, ucdText;

/// Build a UTF-8 string from a sequence of code points.
private string toUtf8(const(dchar)[] cps)
{
    auto buf = appender!string;
    foreach (cp; cps)
        buf.put(cp);
    return buf[];
}

/// Every fully-qualified RGI emoji sequence as a UTF-8 string.
string[] emojiStrings(in Config cfg)
{
    string[] result;
    foreach (raw; emojiTestText(cfg).lineSplitter)
    {
        auto semi = raw.findSplit(";");
        if (!semi[1].length)
            continue;
        if (semi[2].findSplit("#")[0].strip != "fully-qualified")
            continue;
        auto cps = semi[0].strip.splitter(' ')
            .filter!(t => t.length)
            .map!(t => cast(dchar) t.to!uint(16))
            .array;
        if (cps.length)
            result ~= toUtf8(cps);
    }
    return result;
}

/// Every `GraphemeBreakTest.txt` test string (the boundary markers dropped).
string[] graphemeBreakStrings(in Config cfg)
{
    string[] result;
    foreach (raw; ucdText(cfg.segVersion, "auxiliary/GraphemeBreakTest.txt", cfg).lineSplitter)
    {
        const line = raw.findSplit("#")[0].strip;
        if (line.length == 0)
            continue;
        auto cps = line.splitter(' ')
            .filter!(t => t.length && t != "÷" && t != "×")
            .map!(t => cast(dchar) t.to!uint(16))
            .array;
        if (cps.length)
            result ~= toUtf8(cps);
    }
    return result;
}
