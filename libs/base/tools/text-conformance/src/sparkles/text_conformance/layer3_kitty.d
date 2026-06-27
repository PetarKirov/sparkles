/**
 * Layer 3 — cross-check against kitty's reference `wcswidth`.
 *
 * kitty implements the *same* Text Sizing Protocol spec that `width.d` follows,
 * so this is a conformance check against the reference implementation, not an
 * independent policy. We feed a corpus (emoji + GraphemeBreakTest strings) to
 * `kitty +runpy` — each entry hex-encoded on stdin to dodge newline/encoding
 * issues — and diff kitty's width against `visibleWidth`.
 *
 * kitty is an optional external oracle: if it isn't on PATH (e.g. outside
 * `nix shell nixpkgs#kitty`), the layer skips gracefully. `--require-kitty`
 * turns that skip into a failure.
 */
module sparkles.text_conformance.layer3_kitty;

import std.algorithm : map;
import std.array : array, join;
import std.conv : to;
import std.digest : toHexString;
import std.process : execute, pipeProcess, Redirect, wait, ProcessException;
import std.string : representation, strip;

import sparkles.base.text.grapheme : visibleWidth;

import sparkles.text_conformance.config : Config;
import sparkles.text_conformance.corpus : emojiStrings, graphemeBreakStrings;
import sparkles.text_conformance.report : Divergence, LayerResult;
import sparkles.text_conformance.util : hexOf;

/// Python driver run inside kitty: read hex-encoded UTF-8 per line, print width.
private enum string kittyDriver = `import sys
from kitty.fast_data_types import wcswidth
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    print(wcswidth(bytes.fromhex(line).decode("utf-8")))`;

LayerResult runLayer3(in Config cfg)
{
    LayerResult r;
    r.name = "3: kitty wcswidth";

    if (!kittyAvailable())
    {
        if (cfg.requireKitty)
            throw new Exception("kitty unavailable and --require-kitty set "
                ~ "(run inside `nix shell nixpkgs#kitty`)");
        r.skipped = true;
        r.skipReason = "kitty not on PATH (run inside `nix shell nixpkgs#kitty`)";
        return r;
    }

    auto corpus = emojiStrings(cfg) ~ graphemeBreakStrings(cfg);
    auto kittyWidths = runKitty(corpus);
    if (kittyWidths.length != corpus.length)
        throw new Exception("kitty returned " ~ kittyWidths.length.to!string
            ~ " widths for " ~ corpus.length.to!string ~ " inputs");

    foreach (i, s; corpus)
    {
        const got = cast(int) visibleWidth(s);
        const want = kittyWidths[i];
        if (got == want)
        {
            r.passed++;
            continue;
        }
        r.divergences ~= Divergence(3, hexOf(s), got.to!string, want.to!string,
            causeOf(s));
    }

    return r;
}

/// Best-effort explanation of a width divergence from the string's content.
private string causeOf(string s)
{
    import std.utf : byDchar;
    bool hasModifier, hasTag, hasJamo, hasZwj;
    foreach (cp; s.byDchar)
    {
        if (cp >= 0x1F3FB && cp <= 0x1F3FF) hasModifier = true;
        if (cp >= 0xE0020 && cp <= 0xE007F) hasTag = true;
        if (cp >= 0x1160 && cp <= 0x11FF) hasJamo = true; // medial/final jamo
        if (cp == 0x200D) hasZwj = true;
    }
    if (hasModifier)
        return "RGI emoji-modifier sequence: width.d takes the (narrow) base width, "
            ~ "missing kitty spec rule 3 (modifier-sequence base → 2)";
    if (hasTag)
        return "RGI emoji-tag sequence: width.d takes the base width, "
            ~ "missing kitty spec rule 3 (tag-sequence base → 2)";
    if (hasJamo)
        return "conjoining Hangul jamo: width.d forces width 0 via its conjoining-range "
            ~ "hack; kitty gives an isolated medial/final jamo width 1";
    if (hasZwj)
        return "ZWJ sequence: kitty widens the joined emoji/dingbat to 2; "
            ~ "width.d takes the (neutral) base width";
    return "visibleWidth vs kitty wcswidth";
}

private bool kittyAvailable()
{
    try
        return execute(["kitty", "--version"]).status == 0;
    catch (ProcessException)
        return false;
}

/// Run `kitty +runpy`, piping hex-encoded corpus entries on stdin.
private int[] runKitty(const(string)[] corpus)
{
    import std.algorithm : map;
    import std.array : array;
    import sparkles.text_conformance.subprocess : runIntPipe;
    return runIntPipe(["kitty", "+runpy", kittyDriver], corpus.map!hexOf.array);
}
