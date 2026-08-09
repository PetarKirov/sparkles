#!/usr/bin/env dub
/+ dub.sdl:
    name "platform_ui_kdeglobals_appearance"
    targetPath "build"
    platforms "posix"
    dependency "sparkles:base" path="../../../../.."
    dflags "-preview=in" "-preview=dip1000"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
 * Reading Plasma's appearance directly out of `kdeglobals`.
 *
 * Plasma ships a portal backend, so [the portal route](../../gnome/examples/portal-appearance.d)
 * works on KDE too — but `xdg-desktop-portal-kde` implements only
 * `color-scheme`, `accent-color` and `reduced-motion`; it does **not** answer
 * `contrast`. An application that wants the full picture on Plasma, or that
 * wants the actual scheme *colors* rather than a light/dark bit, has to read
 * `kdeglobals` — which is also what `KColorScheme` itself does.
 *
 * `kdeglobals` is INI-shaped. The parts that matter here:
 *
 *   - `[General] ColorScheme=` — the scheme's display name (e.g. `BreezeDark`).
 *   - `[General] AccentColor=r,g,b` — the user's accent, absent when they
 *     have not overridden the scheme's own.
 *   - `[Colors:Window] BackgroundNormal=r,g,b` and `ForegroundNormal=` — the
 *     window band. Plasma exports **eight** such `[Colors:*]` sets.
 *   - `[Colors:View] BackgroundNormal=` — the *document* background, which is
 *     the one a text viewer should follow, not `Window`.
 *
 * The last point is the finding this example exists to make: Plasma does not
 * hand out one background, it hands out a set of role-scoped ones, and picking
 * `Window` for a document surface is a visible mistake on schemes where the two
 * differ. Unlike GNOME — where the portal's light/dark bit is all there is —
 * following Plasma properly means consuming a palette, not a scalar.
 *
 * Companion to docs/research/platform-ui-guidelines/kde.md
 *   § "kdeglobals is the interface" and § "Eight color sets, not one".
 *
 * Run with: dub run --single kdeglobals-appearance.d
 *
 * Portability: POSIX. When no `kdeglobals` exists — any non-Plasma machine,
 * which is how CI runs it — it prints a `SKIP:` line and exits 0.
 */
module platform_ui_kdeglobals_appearance;

import std.algorithm : startsWith;
import std.array : split;
import std.conv : to;
import std.file : exists, readText;
import std.format : format;
import std.path : buildPath;
import std.process : environment;
import std.stdio : writefln, writeln;
import std.string : lineSplitter, strip;

import sparkles.base.term_color : RgbColor;

/// A parsed `kdeglobals`: section → key → value, in file order.
struct Ini
{
    string[string][string] sections;

    string get(string section, string key, string fallback = null) const @safe
    {
        if (auto s = section in sections)
            if (auto v = key in *s)
                return *v;
        return fallback;
    }

    bool has(string section) const @safe => (section in sections) !is null;
}

Ini parseIni(string text) @safe
{
    Ini ini;
    string current = "";
    foreach (line; text.lineSplitter)
    {
        auto t = line.strip;
        if (!t.length || t.startsWith("#") || t.startsWith(";"))
            continue;
        if (t.startsWith("[") && t[$ - 1] == ']')
        {
            current = t[1 .. $ - 1].idup;
            // Make sure an empty section still registers, so `has` is truthful.
            if (current !in ini.sections)
                ini.sections[current] = null;
            continue;
        }
        const eq = () @safe {
            foreach (i, c; t)
                if (c == '=')
                    return i;
            return size_t.max;
        }();
        if (eq == size_t.max)
            continue;
        ini.sections[current][t[0 .. eq].strip.idup] = t[eq + 1 .. $].strip.idup;
    }
    return ini;
}

/// Plasma writes colors as decimal `r,g,b` (sometimes with a fourth alpha
/// component, which is ignored here).
bool parseColor(string value, out RgbColor c) @safe
{
    auto parts = value.split(",");
    if (parts.length < 3)
        return false;
    try
        c = RgbColor(parts[0].strip.to!ubyte, parts[1].strip.to!ubyte,
            parts[2].strip.to!ubyte);
    catch (Exception)
        return false;
    return true;
}

string hex(in RgbColor c) @safe => format!"#%02X%02X%02X"(c.r, c.g, c.b);

/// Rec. 601 luma, the same test `sparkles.ui.style.schemeForBackground` applies.
int luma(in RgbColor c) @safe pure nothrow @nogc
    => (c.r * 299 + c.g * 587 + c.b * 114) / 1000;

/// Where `kdeglobals` lives, honouring `XDG_CONFIG_HOME`.
string kdeglobalsPath() @safe
{
    const xdg = environment.get("XDG_CONFIG_HOME");
    const base = xdg !is null && xdg.length
        ? xdg
        : buildPath(environment.get("HOME", ""), ".config");
    return buildPath(base, "kdeglobals");
}

void main() @safe
{
    const path = kdeglobalsPath();
    if (!path.exists)
    {
        writefln!"SKIP: %s does not exist — not a Plasma session."(path);
        return;
    }

    writefln!"reading %s"(path);
    const ini = parseIni(path.readText);
    writeln();

    const schemeName = ini.get("General", "ColorScheme", "(unset)");
    writefln!"[General] ColorScheme = %s"(schemeName);

    RgbColor accent;
    const accentRaw = ini.get("General", "AccentColor");
    if (accentRaw !is null && parseColor(accentRaw, accent))
        writefln!"[General] AccentColor  = %s (%s)"(hex(accent), accentRaw);
    else
        // Absent means "use the scheme's own accent", not "no accent" — the
        // scheme file's DecorationFocus is the fallback.
        writeln("[General] AccentColor  = unset (inherit the scheme's own)");

    // The eight sets Plasma exports. Which ones are present tells you how
    // complete the active scheme is.
    writeln();
    writeln("[Colors:*] sets present, with their normal fg/bg:");
    // Note the last one: Plasma spells the inactive header
    // `[Colors:Header][Inactive]` — two bracket groups on one line, which a
    // naive INI reader mangles. `label` is what a human should see.
    static immutable string[2][] sets = [
        ["Window", "Window"], ["View", "View"], ["Button", "Button"],
        ["Selection", "Selection"], ["Tooltip", "Tooltip"],
        ["Complementary", "Complementary"], ["Header", "Header"],
        ["Header][Inactive", "Header (inactive)"],
    ];
    RgbColor viewBg;
    bool haveViewBg;
    foreach (pair; sets)
    {
        const set = pair[0], label = pair[1];
        const section = "Colors:" ~ set;
        if (!ini.has(section))
        {
            writefln!"  %-18s absent"(label);
            continue;
        }
        RgbColor bg, fg;
        const bgOk = parseColor(ini.get(section, "BackgroundNormal", ""), bg);
        const fgOk = parseColor(ini.get(section, "ForegroundNormal", ""), fg);
        writefln!"  %-18s bg %s   fg %s"(label,
            bgOk ? hex(bg) : "  n/a  ", fgOk ? hex(fg) : "  n/a  ");
        if (set == "View" && bgOk)
        {
            viewBg = bg;
            haveViewBg = true;
        }
    }

    writeln();
    // `View`, not `Window`: a file viewer paints a document, and Plasma
    // distinguishes the two deliberately.
    if (haveViewBg)
        writefln!"=> document surface is Colors:View bg %s (Rec.601 luma %d ⇒ %s)"(
            hex(viewBg), luma(viewBg), luma(viewBg) < 110 ? "dark" : "light");
    else
        writeln("=> no Colors:View set; fall back to Colors:Window, then to the portal bit");

    writeln();
    writeln("Change notification: Plasma rewrites kdeglobals and KConfig's watcher");
    writeln("(org.kde.kconfig.notify D-Bus signals, plus a file watch) picks it up.");
    writeln("A non-KDE application without KConfig should prefer the portal's");
    writeln("SettingChanged signal and treat kdeglobals as the detail source.");
}
