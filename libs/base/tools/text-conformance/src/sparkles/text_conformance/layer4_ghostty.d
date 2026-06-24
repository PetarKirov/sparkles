/**
 * Layer 4 — cross-check against ghostty's VT engine, used as a *library*.
 *
 * Unlike kitty (a runtime binary queried via `wcswidth`), ghostty is linked in
 * via the `sparkles:ghostty` ImportC bindings to `libghostty-vt`. For each
 * corpus string we drive a real terminal: enable grapheme-cluster mode (DEC
 * 2027 — **off by default**, and the difference between per-codepoint and
 * modern grapheme width), write the bytes, and read the cursor column, which is
 * the number of cells the string advanced. That column equals `visibleWidth`.
 *
 * Why a second terminal oracle matters: ghostty and kitty *disagree* on the
 * contested width classes. With mode 2027 on, ghostty gives an emoji-modifier
 * sequence with a neutral base (e.g. ✌🏻 `270C 1F3FB`) width 1 and an isolated
 * Hangul jamo width 0 — siding with `sparkles`, where kitty gives 2 and 1.
 * Layer 3 vs Layer 4 thus shows those cases are terminal-dependent, not bugs.
 *
 * Domain note: `cursor_x` reflects real cursor *placement*, so cursor-moving
 * controls (CR/LF/HT/…) don't represent "width". We restrict this layer to
 * control-free strings (the whole emoji corpus + printable GraphemeBreakTest
 * strings); kitty's pure `wcswidth` (Layer 3) covers the rest.
 *
 * Gated behind `version(TextConformanceGhostty)` so the offline/unittest builds
 * compile without the native dependency.
 */
module sparkles.text_conformance.layer4_ghostty;

import std.algorithm : map, filter;
import std.array : array, join;
import std.conv : to;
import std.format : format;
import std.utf : byDchar;

import sparkles.base.text.grapheme : visibleWidth;

import sparkles.text_conformance.config : Config;
import sparkles.text_conformance.corpus : emojiStrings, graphemeBreakStrings;
import sparkles.text_conformance.report : Divergence, LayerResult;
import sparkles.text_conformance.ucd : loadWidthData, WidthData;
import sparkles.text_conformance.util : hasCursorControl, hexOf;

version (TextConformanceGhostty)
    import sparkles.ghostty;

version (TextConformanceGhostty)
LayerResult runLayer4(in Config cfg)
{
    LayerResult r;
    r.name = "4: ghostty (lib)";

    auto d = loadWidthData(cfg); // category data, for labelling divergences

    GhosttyTerminal term;
    GhosttyTerminalOptions opt = { cols: 1000, rows: 1, max_scrollback: 0 };
    if (ghostty_terminal_new(null, &term, opt) != GHOSTTY_SUCCESS)
        throw new Exception("ghostty_terminal_new failed");
    scope (exit) ghostty_terminal_free(term);

    // DEC mode 2027 (grapheme cluster) — off by default; without it ghostty
    // measures per code point (flags → 4, emoji+VS16 → 1).
    const graphemeMode = ghostty_mode_new(2027, false);

    auto corpus = (emojiStrings(cfg) ~ graphemeBreakStrings(cfg))
        .filter!(s => !hasCursorControl(s)).array;

    foreach (s; corpus)
    {
        ghostty_terminal_reset(term);            // RIS also clears mode 2027,
        ghostty_terminal_mode_set(term, graphemeMode, true); // so re-enable it
        ghostty_terminal_vt_write(term, cast(const(ubyte)*) s.ptr, s.length);

        uint x;
        ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_CURSOR_X, &x);

        const got = cast(int) visibleWidth(s);
        const want = cast(int) x;
        if (got == want)
        {
            r.passed++;
            continue;
        }
        r.divergences ~= Divergence(4, hexOf(s), got.to!string, want.to!string,
            causeOf(s, d));
    }

    return r;
}
else
LayerResult runLayer4(in Config cfg)
{
    LayerResult r;
    r.name = "4: ghostty (lib)";
    r.skipped = true;
    r.skipReason = "built without ghostty (use the default 'application' config)";
    return r;
}

/// Best-effort explanation of a divergence from the string's content and the
/// general categories of its code points. The dominant class is ghostty
/// advancing a cell for a *spacing* mark (Mc) or a prepended-format (Cf) code
/// point that the kitty Text Sizing Protocol — and so `width.d` — classes as a
/// zero-width Mark.
private string causeOf(string s, in WidthData d) @safe
{
    bool hasMc, hasCf, hasModifier;
    foreach (cp; s.byDchar)
    {
        if (d.mc[cp]) hasMc = true;
        if (d.cf[cp]) hasCf = true;
        if (cp >= 0x1F3FB && cp <= 0x1F3FF) hasModifier = true;
    }
    if (hasMc)
        return "spacing mark (Mc): ghostty advances a cell per mark; width.d & the "
            ~ "kitty TSP treat all Marks as width 0 (one cell per Brahmic syllable)";
    if (hasCf)
        return "prepended/format (Cf): ghostty advances a cell; the TSP treats it "
            ~ "as zero-width";
    if (hasModifier)
        return "RGI emoji-modifier sequence";
    return "visibleWidth vs ghostty cursor advance";
}
