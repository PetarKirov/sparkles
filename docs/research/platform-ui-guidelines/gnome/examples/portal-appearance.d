#!/usr/bin/env dub
/+ dub.sdl:
    name "platform_ui_portal_appearance"
    targetPath "build"
    platforms "linux"
    dflags "-preview=in" "-preview=dip1000"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
 * Reading the desktop's appearance preferences through the XDG portal.
 *
 * `org.freedesktop.portal.Settings` is the one route that works on **both**
 * GNOME and KDE (and on any other desktop shipping a portal backend), from
 * inside a sandbox or out, without linking a toolkit. The
 * `org.freedesktop.appearance` namespace is the vendor-neutral part:
 *
 * | Key              | Type    | Values                                       |
 * | ---------------- | ------- | -------------------------------------------- |
 * | `color-scheme`   | `u`     | 0 no preference · 1 prefer-dark · 2 prefer-light |
 * | `accent-color`   | `(ddd)` | sRGB in [0,1]; out-of-range ⇒ unset          |
 * | `contrast`       | `u`     | 0 normal · 1 higher contrast                 |
 * | `reduced-motion` | `u`     | 0 no preference · 1 reduced                  |
 *
 * The program reads each key, reports which ones the *running* backend actually
 * implements, and derives the scheme. Two findings this example exists to make
 * visible, both observed rather than assumed:
 *
 *   - **The namespace is not uniformly implemented.** A key defined in the
 *     current spec can be absent from a deployed backend, answered as
 *     `org.freedesktop.portal.Error.NotFound`. Which keys are missing differs
 *     between GNOME and KDE — see [../index.md](../index.md) § "Coverage is
 *     per-backend" and [../../kde.md](../../kde.md).
 *   - **`accent-color` promises more than GNOME delivers.** The type is an
 *     arbitrary sRGB triple, but `xdg-desktop-portal-gnome` converts a
 *     nine-value `AdwAccentColor` enum to RGB at the boundary, so the answer is
 *     always one of nine hexes. See [../../libadwaita.md](../../libadwaita.md).
 *
 * Companion to docs/research/platform-ui-guidelines/gnome/index.md
 *   § "The portal route" and § "Change notification".
 *
 * Run with: dub run --single portal-appearance.d
 *
 * Portability: Linux only. It shells out to `gdbus` (or `busctl`) rather than
 * marshalling D-Bus itself — the deep-dive's § "What a D implementation needs"
 * records that a real client wants a D-Bus binding, which Sparkles does not have
 * yet. With no session bus, no portal, or neither helper on `PATH` it prints a
 * `SKIP:` line and exits 0, which is how CI runs it.
 */
module platform_ui_portal_appearance;

import std.algorithm : canFind, findSplit, startsWith;
import std.conv : to;
import std.format : format;
import std.process : environment, execute;
import std.stdio : writefln, writeln;
import std.string : strip;

enum portalDest = "org.freedesktop.portal.Desktop";
enum portalPath = "/org/freedesktop/portal/desktop";
enum appearance = "org.freedesktop.appearance";

/// The outcome of one `ReadOne` call: the raw reply, or the reason there is none.
struct KeyResult
{
    bool ok;         /// a value came back
    bool notFound;   /// the backend does not implement this key
    string raw;      /// verbatim reply (or error text)
}

/// Locate a D-Bus command-line client. `gdbus` ships with GLib, `busctl` with
/// systemd; a desktop running a portal has at least one.
string findDbusTool() @safe
{
    foreach (tool; ["gdbus", "busctl"])
    {
        const r = execute(["sh", "-c", "command -v " ~ tool]);
        if (r.status == 0 && r.output.strip.length)
            return tool;
    }
    return null;
}

/// `org.freedesktop.portal.Settings.ReadOne(namespace, key)`.
///
/// `ReadOne` — not `Read`. The spec marks `Read` deprecated because it
/// "returns the value wrapped in two variant layers instead of one"; `ReadOne`
/// was added in interface version 2.
KeyResult readOne(string tool, string key) @safe
{
    string[] argv = tool == "gdbus"
        ? [
            "gdbus", "call", "--session", "--dest", portalDest,
            "--object-path", portalPath,
            "--method", "org.freedesktop.portal.Settings.ReadOne",
            appearance, key,
        ]
        : [
            "busctl", "--user", "call", portalDest, portalPath,
            "org.freedesktop.portal.Settings", "ReadOne", "ss", appearance, key,
        ];

    const r = execute(argv);
    const text = r.output.strip;
    if (r.status == 0)
        return KeyResult(ok: true, raw: text);
    return KeyResult(
        notFound: text.canFind("NotFound") || text.canFind("not found"),
        raw: text);
}

/// Pull the first unsigned integer out of a `gdbus`/`busctl` reply.
bool parseUint(string raw, out uint value) @safe
{
    // gdbus: `(<uint32 1>,)`   busctl: `v u 1`
    size_t i;
    while (i < raw.length && (raw[i] < '0' || raw[i] > '9'))
    {
        // Skip the "uint32"/"32" type token so its digits are not mistaken for
        // the value.
        if (raw[i .. $].startsWith("uint32"))
            i += "uint32".length;
        else
            i++;
    }
    size_t start = i;
    while (i < raw.length && raw[i] >= '0' && raw[i] <= '9')
        i++;
    if (i == start)
        return false;
    value = raw[start .. i].to!uint;
    return true;
}

/// Pull the three doubles of an `(ddd)` accent reply.
bool parseAccent(string raw, out double[3] rgb) @safe
{
    size_t ci, i;
    while (ci < 3 && i < raw.length)
    {
        // A double here always contains a '.', which distinguishes it from the
        // structural digits in `uint32` and from array indices.
        if ((raw[i] >= '0' && raw[i] <= '9') || raw[i] == '-')
        {
            size_t start = i;
            while (i < raw.length && (
                    (raw[i] >= '0' && raw[i] <= '9') || raw[i] == '.'
                    || raw[i] == '-' || raw[i] == 'e' || raw[i] == '+'))
                i++;
            const tok = raw[start .. i];
            if (tok.canFind('.'))
            {
                rgb[ci++] = tok.to!double;
                continue;
            }
        }
        i++;
    }
    return ci == 3;
}

string hexOf(in double[3] rgb) @safe
    => format!"#%02X%02X%02X"(
        cast(ubyte)(rgb[0] * 255 + 0.5),
        cast(ubyte)(rgb[1] * 255 + 0.5),
        cast(ubyte)(rgb[2] * 255 + 0.5));

/// The nine colors `AdwAccentColor` can hold, as `adw_accent_color_to_rgba`
/// defines them. GNOME's portal backend emits exactly one of these, so a match
/// here proves the quantization the deep-dive describes.
static immutable namedAccents = [
    "blue":   "#3584E4", "teal":   "#2190A4", "green":  "#3A944A",
    "yellow": "#C88800", "orange": "#ED5B00", "red":    "#E62D42",
    "pink":   "#D56199", "purple": "#9141AC", "slate":  "#6F8396",
];

void main() @safe
{
    if (environment.get("DBUS_SESSION_BUS_ADDRESS") is null)
    {
        writeln("SKIP: no DBUS_SESSION_BUS_ADDRESS — no session bus to query.");
        return;
    }

    const tool = findDbusTool();
    if (tool is null)
    {
        writeln("SKIP: neither gdbus nor busctl on PATH.");
        return;
    }

    writefln!"desktop: XDG_CURRENT_DESKTOP=%s   (querying via %s)"(
        environment.get("XDG_CURRENT_DESKTOP", "(unset)"), tool);

    // Interface version: `ReadOne` needs >= 2.
    const ver = tool == "gdbus"
        ? execute([
            "gdbus", "call", "--session", "--dest", portalDest,
            "--object-path", portalPath, "--method",
            "org.freedesktop.DBus.Properties.Get",
            "org.freedesktop.portal.Settings", "version",
        ])
        : execute([
            "busctl", "--user", "get-property", portalDest, portalPath,
            "org.freedesktop.portal.Settings", "version",
        ]);
    if (ver.status != 0)
    {
        writeln("SKIP: org.freedesktop.portal.Settings is not available on this bus.");
        return;
    }
    uint v;
    if (parseUint(ver.output.strip, v))
        writefln!"portal Settings interface version: %d%s"(
            v, v >= 2 ? "" : "  (< 2: ReadOne unavailable)");
    writeln();

    writeln("org.freedesktop.appearance:");

    uint scheme = 0;
    bool haveScheme;

    foreach (key; ["color-scheme", "accent-color", "contrast", "reduced-motion"])
    {
        const res = readOne(tool, key);
        if (!res.ok)
        {
            writefln!"  %-14s %s"(key,
                res.notFound
                    ? "NOT IMPLEMENTED by this backend (portal.Error.NotFound)"
                    : "error: " ~ res.raw);
            continue;
        }

        if (key == "accent-color")
        {
            double[3] rgb;
            if (parseAccent(res.raw, rgb))
            {
                // Out-of-range means "unset", per the spec.
                const unset = rgb[0] < 0 || rgb[0] > 1 || rgb[1] < 0 || rgb[1] > 1
                    || rgb[2] < 0 || rgb[2] > 1;
                if (unset)
                    writefln!"  %-14s unset (out of [0,1])"(key);
                else
                {
                    const hex = hexOf(rgb);
                    string named = "not one of AdwAccentColor's nine";
                    foreach (name, value; namedAccents)
                        if (value == hex)
                            named = "= AdwAccentColor '" ~ name ~ "'";
                    writefln!"  %-14s %s  (%.4f, %.4f, %.4f)  %s"(
                        key, hex, rgb[0], rgb[1], rgb[2], named);
                }
            }
            else
                writefln!"  %-14s unparsed: %s"(key, res.raw);
            continue;
        }

        uint value;
        if (!parseUint(res.raw, value))
        {
            writefln!"  %-14s unparsed: %s"(key, res.raw);
            continue;
        }

        string meaning;
        final switch (key)
        {
        case "color-scheme":
            meaning = value == 1 ? "prefer-dark" : value == 2 ? "prefer-light"
                : "no preference";
            scheme = value;
            haveScheme = true;
            break;
        case "contrast":
            meaning = value == 1 ? "higher contrast" : "normal";
            break;
        case "reduced-motion":
            meaning = value == 1 ? "reduced" : "no preference";
            break;
        }
        writefln!"  %-14s %d  (%s)"(key, value, meaning);
    }

    writeln();
    if (haveScheme)
        // 0 means "no preference", NOT "light": the application's own default
        // wins there. Collapsing 0 into light is the single most common bug in
        // portal consumers — see ../index.md § "Three values, not two".
        writefln!"=> theme to use: %s"(
            scheme == 1 ? "the app's dark theme"
                : scheme == 2 ? "the app's light theme"
                : "the app's OWN default (0 = no preference, not light)");

    writeln();
    writeln("Change notification is the SettingChanged(namespace, key, value) signal;");
    writeln("watch it with:");
    writeln("  gdbus monitor --session --dest org.freedesktop.portal.Desktop");
    writeln("then change the system appearance. Note that a desktop running more");
    writeln("than one portal backend emits the signal MORE THAN ONCE per change,");
    writeln("so compare against the value you already hold before repainting.");
}
