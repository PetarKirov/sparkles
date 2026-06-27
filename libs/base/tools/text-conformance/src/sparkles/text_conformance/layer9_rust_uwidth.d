/**
 * Layer 9 — width vs Rust's `unicode-width` crate (the de-facto width model in
 * the Rust TUI ecosystem: alacritty/helix/ratatui, etc.).
 *
 * Driven through the `uwidth-rs` helper binary (built by nix / `cargo`) over the
 * shared subprocess protocol. Two comparisons:
 *   - **per code point** over assigned scalars (ratcheted, like Layer 5):
 *     `UnicodeWidthChar::width(cp)` vs `codepointWidth`;
 *   - **per string** over the corpus (informational note, not ratcheted):
 *     `UnicodeWidthStr::width(s)` vs `visibleWidth` — `unicode-width` is
 *     grapheme-unaware, so it diverges on essentially every multi-scalar
 *     cluster; we report the count rather than allowlisting thousands of rows.
 *
 * Needs the `uwidth-rs` binary on PATH (runtime-skip if absent, like kitty) and
 * utf8proc for the assigned-code-point filter (`version(TextConformanceUtf8proc)`).
 */
module sparkles.text_conformance.layer9_rust_uwidth;

import std.algorithm : map;
import std.array : array, join;
import std.conv : to;
import std.digest : toHexString;
import std.format : format;
import std.process : execute, ProcessException;
import std.string : representation;

import sparkles.base.text.grapheme : visibleWidth;
import sparkles.base.text.width : codepointWidth;

import sparkles.text_conformance.config : Config;
import sparkles.text_conformance.corpus : emojiStrings, graphemeBreakStrings;
import sparkles.text_conformance.report : Divergence, LayerResult;
import sparkles.text_conformance.subprocess : runIntPipe;
import sparkles.text_conformance.ucd : loadWidthData, WidthData;
import sparkles.text_conformance.util : cpClass, hexOf, isNoncharacter;

version (TextConformanceUtf8proc)
    import sparkles.utf8proc;

private enum string rustCmd = "uwidth-rs";

private bool rustAvailable()
{
    try
        return execute([rustCmd, "cp"]).status == 0; // empty stdin → EOF → exit 0
    catch (ProcessException)
        return false;
}

/// Per-code-point divergence cause (cf. Layer 5's utf8proc classification).
private string causeOf(dchar cp, in WidthData d) @safe nothrow
{
    if (cp >= 0x1F1E6 && cp <= 0x1F1FF)
        return "regional indicator: sparkles applies kitty's flag rule (2); "
            ~ "unicode-width gives 1";
    if (isNoncharacter(cp))
        return "noncharacter: sparkles discards it (0); unicode-width gives 1";
    if (cp >= 0x1160 && cp <= 0x11FF)
        return "conjoining Hangul jamo: sparkles forces 0; unicode-width gives 1";
    if (d.mn[cp] || d.mc[cp] || d.me[cp] || d.cf[cp])
        return "Mark/format: width-class or version difference";
    return "codepointWidth vs unicode-width";
}

version (TextConformanceUtf8proc)
LayerResult runLayer9(in Config cfg)
{
    LayerResult r;
    r.name = "9: rust unicode-width";

    if (!rustAvailable())
    {
        r.skipped = true;
        r.skipReason = "uwidth-rs not on PATH (build via nix `.#uwidth-rs` or cargo)";
        return r;
    }

    auto d = loadWidthData(cfg);

    // --- per code point, over assigned scalars (excludes unassigned like Layer 5) ---
    dchar[] cps;
    string[] hexes;
    foreach (uint cp; 0 .. 0x110000)
    {
        if (cp >= 0xD800 && cp <= 0xDFFF)
            continue;
        if (utf8proc_category(cast(int) cp) == UTF8PROC_CATEGORY_CN && !isNoncharacter(cast(dchar) cp))
            continue;
        cps ~= cast(dchar) cp;
        hexes ~= format("%04X", cp);
    }

    const cpw = runIntPipe([rustCmd, "cp"], hexes);
    if (cpw.length != cps.length)
        throw new Exception(format("uwidth-rs cp: got %s widths for %s inputs",
            cpw.length, cps.length));

    size_t[string] buckets;
    foreach (i, cp; cps)
    {
        const got = codepointWidth(cp);
        if (got == cpw[i])
        {
            r.passed++;
            continue;
        }
        buckets[cpClass(cp, d)]++;
        r.divergences ~= Divergence(9, format("U+%04X", cast(uint) cp),
            got.to!string, cpw[i].to!string, causeOf(cp, d));
    }
    foreach (k, n; buckets)
        r.notes ~= format("%s: %d", k, n);

    // --- per string, over the corpus (informational: grapheme-unaware gap) ---
    auto corpus = emojiStrings(cfg) ~ graphemeBreakStrings(cfg);
    const sw = runIntPipe([rustCmd, "str"], corpus.map!hexOf.array);
    size_t agree, diff;
    foreach (i, s; corpus)
        if (i < sw.length && cast(int) visibleWidth(s) == sw[i])
            agree++;
        else
            diff++;
    r.notes ~= format("per-string: agrees %s/%s; %s grapheme-unaware diffs (not ratcheted)",
        agree, corpus.length, diff);

    return r;
}
else
LayerResult runLayer9(in Config cfg)
{
    LayerResult r;
    r.name = "9: rust unicode-width";
    r.skipped = true;
    r.skipReason = "built without utf8proc (needed for the assigned-code-point filter)";
    return r;
}
