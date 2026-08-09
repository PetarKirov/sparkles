#!/usr/bin/env dub
/+ dub.sdl:
    name "platform_ui_derive_palette"
    targetPath "build"
    dependency "sparkles:base" path="../../../../.."
    dependency "sparkles:ui" path="../../../../.."
    dflags "-preview=in" "-preview=dip1000"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
 * Deriving a `sparkles:ui` palette from an OS appearance triple.
 *
 * The platforms surveyed in this tree all hand an application the same three
 * scalars — a **color scheme**, an **accent color**, and a **contrast level**
 * (see [concepts.md](../../concepts.md)) — and every one of them leaves the
 * actual palette construction to the app. This program is that construction,
 * done the way [color-derivation/index.md](../index.md) recommends:
 *
 *   1. **Tone, not lightness.** Colors are placed on the CIE `L*` "tone" axis
 *      (0 = black, 100 = white), which is what Material's HCT uses for its
 *      third dimension. `L*` is perceptually uniform, so a fixed tone *delta*
 *      buys a predictable contrast ratio at any hue.
 *   2. **The tone-delta rule is verified, not asserted.** Material documents
 *      that "a difference of 40 in HCT tone guarantees a contrast ratio >= 3.0,
 *      and a difference of 50 guarantees a contrast ratio >= 4.5". Step 2 below
 *      sweeps every tone pair at those deltas and reports the worst case, so the
 *      rule this tree repeats is checked by the build rather than trusted.
 *   3. **Scheme flips the direction, not the recipe.** A light scheme puts text
 *      at a low tone on a high-tone surface; a dark scheme mirrors it. Contrast
 *      level shifts the deltas. The accent hue is preserved in both.
 *
 * Companion to docs/research/platform-ui-guidelines/color-derivation/index.md
 *   § "The tone-delta rule" and § "Deriving the Sparkles palette".
 *
 * Run with: dub run --single derive-palette.d
 *
 * Portability: pure computation — no OS, no terminal, no display. Green
 * everywhere. The live OS reads are the sibling examples
 * ([portal-appearance.d](../../gnome/examples/portal-appearance.d),
 * [kdeglobals-appearance.d](../../kde/examples/kdeglobals-appearance.d),
 * [color-scheme-probe.d](../../terminal/examples/color-scheme-probe.d)).
 */
module platform_ui_derive_palette;

import std.math : pow, round;
import std.stdio : writefln, writeln;

import sparkles.base.term_color : Color, RgbColor;
import sparkles.ui.style : ColorScheme, Palette, Slot;
import sparkles.ui.theme : Theme;

// ---------------------------------------------------------------------------
// sRGB ⇄ linear ⇄ luminance ⇄ tone (CIE L*)
// ---------------------------------------------------------------------------

/// One sRGB channel (0..1) linearized, per IEC 61966-2-1 — the transfer
/// function WCAG 2.x's relative-luminance definition uses verbatim.
double linearize(double channel) @safe pure nothrow @nogc
    => channel <= 0.040_45 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4);

/// WCAG relative luminance `Y` (0..1) of an sRGB color.
double luminance(in RgbColor c) @safe pure nothrow @nogc
    => 0.2126 * linearize(c.r / 255.0)
        + 0.7152 * linearize(c.g / 255.0)
        + 0.0722 * linearize(c.b / 255.0);

/// The WCAG 2.x contrast ratio between two colors, in `[1, 21]`.
double contrastRatio(in RgbColor a, in RgbColor b) @safe pure nothrow @nogc
{
    const la = luminance(a), lb = luminance(b);
    const hi = la > lb ? la : lb, lo = la > lb ? lb : la;
    return (hi + 0.05) / (lo + 0.05);
}

/// CIE `L*` ("tone" in HCT terms) from a relative luminance, 0..100.
double toneFromLuminance(double y) @safe pure nothrow @nogc
    => y <= 216.0 / 24_389.0 ? y * 24_389.0 / 27.0 : 116.0 * pow(y, 1.0 / 3.0) - 16.0;

/// The inverse: the luminance a given tone sits at.
double luminanceFromTone(double tone) @safe pure nothrow @nogc
{
    if (tone <= 8.0)
        return tone * 27.0 / 24_389.0;
    const f = (tone + 16.0) / 116.0;
    return f * f * f;
}

/// The neutral grey at a given tone — the reference point a tone delta is
/// measured against when the hue does not matter (surfaces, dividers, text).
RgbColor greyAtTone(double tone) @safe pure nothrow @nogc
{
    const y = luminanceFromTone(tone);
    // Invert the sRGB transfer function back to an 8-bit channel.
    const s = y <= 0.003_130_8 ? y * 12.92 : 1.055 * pow(y, 1.0 / 2.4) - 0.055;
    const v = cast(ubyte) round(s * 255.0);
    return RgbColor(v, v, v);
}

/// The same color moved to a target tone, keeping its hue and relative
/// chroma. A cheap stand-in for a full CAM16 round-trip: it scales the channel
/// *ratios* so the hue survives, then corrects the result onto the target tone.
/// Good enough for chrome accents; a real HCT solve would iterate.
RgbColor atTone(in RgbColor c, double targetTone) @safe pure nothrow @nogc
{
    const current = toneFromLuminance(luminance(c));
    if (current <= 0.01)
        return greyAtTone(targetTone);

    // Scale in linear light so the ratio between channels — and thus the hue —
    // is preserved, then clamp.
    const wanted = luminanceFromTone(targetTone);
    const have = luminance(c);
    const k = wanted / have;

    ubyte chan(ubyte v) @safe pure nothrow @nogc
    {
        const lin = linearize(v / 255.0) * k;
        const clamped = lin < 0 ? 0.0 : (lin > 1 ? 1.0 : lin);
        const s = clamped <= 0.003_130_8
            ? clamped * 12.92
            : 1.055 * pow(clamped, 1.0 / 2.4) - 0.055;
        return cast(ubyte) round(s * 255.0);
    }

    return RgbColor(chan(c.r), chan(c.g), chan(c.b));
}

// ---------------------------------------------------------------------------
// The OS appearance triple
// ---------------------------------------------------------------------------

/// The contrast levels the surveyed platforms expose. GNOME's portal and
/// Windows report a boolean; Android 14 and Apple report a third, middle step.
/// See [comparison.md](../../comparison.md) § "Dimension 3".
enum ContrastLevel : ubyte
{
    standard, /// no preference
    medium,   /// Android 14's middle step; Apple's `accessibilityContrast.high`
    high,     /// GNOME `contrast: 1`, Windows `HCF_HIGHCONTRASTON`
}

/// Exactly what every surveyed platform can be reduced to.
struct SystemAppearance
{
    ColorScheme scheme;
    RgbColor accent;
    ContrastLevel contrast;
}

/// The tone pair (text, surface) a scheme and contrast level call for. The
/// deltas come from the Material rule verified in step 2: 50 at standard, wider
/// as contrast rises. A dark scheme mirrors the axis rather than changing it.
void tonesFor(in SystemAppearance a, out double textTone, out double surfaceTone)
    @safe pure nothrow @nogc
{
    // Standard = ΔT 50 (≥ 4.5:1); medium = 60; high = 75 (near the extremes).
    const delta = a.contrast == ContrastLevel.high
        ? 75.0
        : (a.contrast == ContrastLevel.medium ? 60.0 : 50.0);

    if (a.scheme == ColorScheme.light)
    {
        surfaceTone = 98.0;
        textTone = surfaceTone - delta;
    }
    else
    {
        surfaceTone = 12.0;
        textTone = surfaceTone + delta;
    }
}

/// Derive a whole `sparkles:ui` theme from the OS triple.
///
/// Only the slots whose appearance genuinely follows the system are touched:
/// the page fore/background, the chrome band, the focused-pane accent and the
/// selection tint. The semantic status slots (`error`/`warn`/`info`) keep the
/// theme's authored hues — a red that follows the desktop accent stops meaning
/// "error", which is the trap [comparison.md](../../comparison.md)
/// § "What follows the system, and what must not" describes.
Theme deriveTheme(in SystemAppearance a, string name) @safe pure nothrow
{
    double textTone, surfaceTone;
    tonesFor(a, textTone, surfaceTone);

    const fg = greyAtTone(textTone);
    const bg = greyAtTone(surfaceTone);

    // The accent has to land on the *opposite* side of the surface to stay
    // legible: a dark scheme wants a light accent and vice versa.
    const accentTone = a.scheme == ColorScheme.light ? 40.0 : 80.0;
    const accent = atTone(a.accent, accentTone);

    auto theme = Theme(
        name: name,
        defaultFg: Color.fromRgb(fg),
        defaultBg: Color.fromRgb(bg),
    );

    Palette p = theme.effectivePalette();
    p.fg[Slot.chromeAccent] = Color.fromRgb(accent);
    p.fg[Slot.caret] = Color.fromRgb(accent);
    p.bg[Slot.chromeFocused] = Color.fromRgb(atTone(a.accent,
        a.scheme == ColorScheme.light ? 90.0 : 30.0));
    p.bg[Slot.selection] = Color.fromRgb(atTone(a.accent,
        a.scheme == ColorScheme.light ? 85.0 : 35.0));
    // A surface one step off the page, the way every platform separates a
    // panel from the document beneath it.
    p.bg[Slot.surface] = Color.fromRgb(greyAtTone(
        a.scheme == ColorScheme.light ? surfaceTone - 4.0 : surfaceTone + 6.0));

    theme.palette = p;
    theme.hasPalette = true;
    return theme;
}

// ---------------------------------------------------------------------------

string hex(in RgbColor c) @safe pure
{
    import std.format : format;
    return format!"#%02X%02X%02X"(c.r, c.g, c.b);
}

/// Two decimals, for splicing a shortfall into a message.
string fmt(double v) @safe pure
{
    import std.format : format;
    return format!"%.3f"(v);
}

void main() @safe
{
    writeln("=== 1. The tone axis ===");
    writeln("tone   grey      luminance");
    foreach (t; [0, 10, 20, 40, 50, 60, 80, 90, 100])
    {
        const g = greyAtTone(t);
        writefln!"%4d   %s   %.4f"(t, g.hex, luminance(g));
    }

    // Material's claim, checked rather than repeated. Sweep every tone pair at
    // a given delta and report the WORST contrast ratio it achieves.
    double worstRatioAt(double delta, out double worstLo) @safe
    {
        double worst = double.infinity;
        worstLo = 0;
        for (double lo = 0; lo + delta <= 100.0; lo += 0.25)
        {
            const r = contrastRatio(greyAtTone(lo), greyAtTone(lo + delta));
            if (r < worst)
            {
                worst = r;
                worstLo = lo;
            }
        }
        return worst;
    }

    writeln("\n=== 2. The tone-delta rule, measured ===");
    writeln("Material states: \"a difference of 40 in HCT tone guarantees a contrast");
    writeln("ratio >= 3.0, and a difference of 50 guarantees a contrast ratio >= 4.5\".");
    writeln();
    foreach (delta; [40.0, 50.0])
    {
        double at;
        const worst = worstRatioAt(delta, at);
        const claim = delta == 40.0 ? 3.0 : 4.5;
        writefln!"ΔT %.0f: worst %.3f:1 (tone %.0f→%.0f) vs claimed ≥ %.1f:1  %s"(
            delta, worst, at, at + delta, claim,
            worst >= claim ? "holds" : "MISSES by " ~ fmt(claim - worst));
    }

    // ΔT 50 misses 4.5:1 at the very top of the tone axis. The shortfall is
    // ~0.4%, so the rule is a sound design heuristic — but it is an
    // approximation, not the guarantee the wording claims, and a palette that
    // must *certify* WCAG AA has to check the ratio rather than trust the delta.
    // Solve for the delta that actually clears each threshold everywhere.
    writeln();
    foreach (target; [3.0, 4.5])
    {
        double need = 0;
        for (double d = 1; d <= 100.0; d += 0.25)
        {
            double at;
            if (worstRatioAt(d, at) >= target)
            {
                need = d;
                break;
            }
        }
        writefln!"smallest ΔT that clears %.1f:1 at every tone: %.2f"(target, need);
    }

    // What the build actually guarantees, as opposed to what the docs claim.
    {
        double at;
        assert(worstRatioAt(40.0, at) >= 3.0, "ΔT 40 no longer clears 3.0:1");
        assert(worstRatioAt(50.0, at) >= 4.47, "ΔT 50 fell below its measured floor");
    }

    writeln("\n=== 3. Derived themes from one accent ===");
    // The accent GNOME actually reported on the machine this example was
    // written on: portal `accent-color` (0.2078, 0.5176, 0.8941) = #3584E4.
    const gnomeBlue = RgbColor(0x35, 0x84, 0xE4);
    writefln!"OS accent: %s (GNOME 'blue')"(gnomeBlue.hex);

    foreach (scheme; [ColorScheme.light, ColorScheme.dark])
        foreach (level; [ContrastLevel.standard, ContrastLevel.high])
        {
            const app = SystemAppearance(scheme, gnomeBlue, level);
            const t = deriveTheme(app, "derived");
            const fg = t.defaultFg.rgb, bg = t.defaultBg.rgb;
            const pal = t.effectivePalette();
            const acc = pal.fg[Slot.chromeAccent].rgb;

            writefln!"\n%-5s / %-8s  fg %s  bg %s  accent %s"(
                scheme, level, fg.hex, bg.hex, acc.hex);
            writefln!"                 text/bg   %5.2f:1   accent/bg %5.2f:1"(
                contrastRatio(fg, bg), contrastRatio(acc, bg));

            // Body text must clear WCAG AA (4.5:1) in every combination — this
            // is the property the whole derivation exists to guarantee.
            assert(contrastRatio(fg, bg) >= 4.5,
                "derived body text fails WCAG AA");
            // The accent is chrome, not body text, so AA-large (3:1) applies.
            assert(contrastRatio(acc, bg) >= 3.0,
                "derived accent fails WCAG AA-large");
        }

    writeln("\n=== 4. Scheme inference vs. the OS answer ===");
    // What `schemeForBackground` in libs/ui/src/sparkles/ui/style.d does today:
    // Rec. 601 luma < 110 ⇒ dark. Compare it with the tone the same color sits
    // at. The two disagree in a band around the midpoint — which is exactly why
    // asking the OS beats inferring from a background color.
    import sparkles.ui.style : schemeForBackground;

    writeln("color     Rec601   tone    schemeForBackground   tone < 50");
    void row(in RgbColor c, string note) @safe
    {
        const luma = (c.r * 299 + c.g * 587 + c.b * 114) / 1000;
        const tone = toneFromLuminance(luminance(c));
        const byTone = tone < 50.0 ? "dark" : "light";
        const byLuma = schemeForBackground(c) == ColorScheme.dark ? "dark" : "light";
        writefln!"%s   %6d   %5.1f   %-19s   %-5s %s%s"(
            c.hex, luma, tone, byLuma, byTone,
            byLuma != byTone ? "<-- disagree  " : "", note);
    }

    // Neutral greys: the two agree almost everywhere, then part company in a
    // narrow band — luma 110 lands at tone ≈ 46.5, not at tone 50.
    foreach (t; [44, 46, 47, 48, 49])
        row(greyAtTone(t), "grey");

    // Saturated backgrounds are where the split is real rather than marginal.
    // Rec. 601 is computed on *gamma-encoded* channels and weights green at
    // 0.587; relative luminance is computed on *linear* light and weights it at
    // 0.7152. A saturated mid green reads light to one and dark to the other.
    writeln();
    row(RgbColor(0x00, 0x80, 0x00), "saturated green");
    row(RgbColor(0x1E, 0x1E, 0x2E), "catppuccin-mocha base");
    row(RgbColor(0x28, 0x2C, 0x34), "one-dark base");
    row(RgbColor(0x00, 0x2B, 0x36), "solarized-dark base");
    row(RgbColor(0xFD, 0xF6, 0xE3), "solarized-light base");
}
