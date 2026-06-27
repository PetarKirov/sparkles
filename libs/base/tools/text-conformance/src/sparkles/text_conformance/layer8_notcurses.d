/**
 * Layer 8 — per-string width vs notcurses' `ncstrwidth`.
 *
 * notcurses is a serious TUI library with careful, grapheme-aware width logic;
 * `ncstrwidth` returns the column count of an EGC string. Linked as a library
 * (the `sparkles.notcurses` ImportC shim → `libnotcurses-core`), it's a third
 * grapheme-aware width oracle alongside kitty (Layer 3) and ghostty (Layer 4),
 * compared per-string against `visibleWidth` over the control-free corpus.
 *
 * Gated behind `version(TextConformanceNotcurses)`.
 */
module sparkles.text_conformance.layer8_notcurses;

import std.algorithm : filter;
import std.array : array, join;
import std.conv : to;
import std.digest : toHexString;
import std.string : representation, toStringz;
import std.utf : byDchar;

import sparkles.base.text.grapheme : visibleWidth;

import sparkles.text_conformance.config : Config;
import sparkles.text_conformance.corpus : emojiStrings, graphemeBreakStrings;
import sparkles.text_conformance.report : Divergence, LayerResult;
import sparkles.text_conformance.util : hasCursorControl, hexOf;

version (TextConformanceNotcurses)
    import sparkles.notcurses;

version (TextConformanceNotcurses)
LayerResult runLayer8(in Config cfg)
{
    LayerResult r;
    r.name = "8: notcurses ncstrwidth";

    // ncstrwidth derives width via the process locale's ctype; force a UTF-8
    // locale (else it counts UTF-8 bytes as Latin-1). C.UTF-8 is always present
    // with glibc; fall back to the env locale.
    () @trusted {
        import core.stdc.locale : setlocale, LC_ALL;
        if (setlocale(LC_ALL, "C.UTF-8") is null)
            setlocale(LC_ALL, "");
    }();

    auto corpus = (emojiStrings(cfg) ~ graphemeBreakStrings(cfg))
        .filter!(s => !hasCursorControl(s)).array;

    foreach (s; corpus)
    {
        // ncstrwidth reads a NUL-terminated C string (no length param), so the
        // slice must be null-terminated — otherwise it reads past the buffer.
        int vb, vw;
        const cstr = s.toStringz;
        const w = () @trusted { return ncstrwidth(cstr, &vb, &vw); }();
        if (w < 0)
            continue; // ncstrwidth rejects a code point it deems unprintable

        const got = cast(int) visibleWidth(s);
        if (got == w)
        {
            r.passed++;
            continue;
        }
        r.divergences ~= Divergence(8, hexOf(s),
            got.to!string, w.to!string, causeOf(s));
    }

    return r;
}
else
LayerResult runLayer8(in Config cfg)
{
    LayerResult r;
    r.name = "8: notcurses ncstrwidth";
    r.skipped = true;
    r.skipReason = "built without notcurses (use the default 'application' config)";
    return r;
}

private string causeOf(string s) @safe
{
    bool hasModifier, hasJamo, hasZwj, hasVs16;
    foreach (cp; s.byDchar)
    {
        if (cp >= 0x1F3FB && cp <= 0x1F3FF) hasModifier = true;
        if (cp >= 0x1160 && cp <= 0x11FF) hasJamo = true;
        if (cp == 0x200D) hasZwj = true;
        if (cp == 0xFE0F) hasVs16 = true;
    }
    if (hasZwj) return "ZWJ sequence: notcurses' width model differs from the kitty TSP";
    if (hasModifier) return "RGI emoji-modifier sequence";
    if (hasJamo) return "conjoining Hangul jamo";
    if (hasVs16)
        return "emoji + VS16: sparkles/kitty-TSP promote the base to width 2; "
            ~ "notcurses keeps it width 1";
    return "visibleWidth vs notcurses ncstrwidth";
}
