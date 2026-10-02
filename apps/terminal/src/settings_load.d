/**
The configuration layers (`TCF2`–`TCF4`): compiled defaults → the Termux
compatibility files → `config.json` → the command line, each a sparse overlay
(`sparkles.wired.overlay`) recording the origin of every value it sets.

Nothing here stops the app (`TCF4`). A file that cannot be read or parsed
contributes nothing and leaves one located warning; a file with a bad value
loses that value only, and the warning names the file, the `$`-path and the
value. An absent file is not a warning at all — and contributes nothing, so
deleting `colors.properties` and reloading restores the defaults (`TCF3`).

NOTE: no module-level `@safe:` — the decode path infers `@system`.
*/
module settings_load;

import std.path : buildPath;

import sparkles.base.term_color : RgbColor;
import sparkles.terminal_view.component : ColorOverrides;
import sparkles.wired.json : JsonError;
import sparkles.wired.overlay : applyOverlay, Sparse;
import sparkles.wired.overlay : WiredOrigins = Origins;

import settings : SchemeColors, TerminalConfig;

/// Where each effective value came from (`TCF5`), lowest layer first.
enum OriginKind : ubyte
{
    /// The schema's field initialiser.
    default_,
    /// A `~/.termux` file.
    termux,
    /// `config.json`.
    file,
    /// A command-line flag.
    cli,
}

/// One value's provenance: the layer and its spelling (`termux:<file>`,
/// `file:<path>`, `cli:<flag>`).
struct Origin
{
    OriginKind kind;
    string detail;

    /// The origin column of `config show`.
    string text() const @safe pure nothrow
        => kind == OriginKind.default_ ? "default" : detail;

    /// Whether the value is still the schema's own.
    bool isDefault() const @safe pure nothrow @nogc => kind == OriginKind.default_;
}

/// The per-field provenance mirror of `TerminalConfig`.
alias Origins(T) = WiredOrigins!(T, Origin);

/// The resolved configuration and what it was resolved from.
struct LoadedConfig
{
    /// The effective value after every layer.
    TerminalConfig effective;
    /// Where each field's value came from.
    Origins!TerminalConfig origins;
    /// `config.json`'s own sparse content — a save rewrites this, never the
    /// resolved value, so a Termux or CLI value is never baked into the file.
    Sparse!TerminalConfig fileOverlay;
    /// `config.json`'s path, existing or not; empty when there is none.
    string filePath;
    /// Located warnings, in layer order.
    string[] warnings;

    /// Apply one command-line flag's overlay (`TCF2` layer 4).
    void applyCli(Sparse!TerminalConfig o, string flag)
    {
        applyOverlay(effective, origins, o, Origin(OriginKind.cli, "cli:" ~ flag));
    }
}

/// `<configDir>/sparkles-terminal/config.json` on the desktop; empty when
/// the platform has no config directory.
string desktopConfigPath() @safe
{
    import sparkles.core_cli.common_dirs : configDir;

    const dir = configDir();
    return dir.length ? buildPath(dir, "sparkles-terminal", "config.json") : null;
}

/// `<home>/.config/sparkles-terminal/config.json` on Android, where `home` is
/// the session's home directory.
string androidConfigPath(string home) @safe pure nothrow
    => buildPath(home, ".config", "sparkles-terminal", "config.json");

/**
Resolves layers 1–3: the defaults, the Termux files in `termuxDir` (empty
skips them) and the config file at `filePath` (empty, or absent, skips it).
The caller applies the command line on top with `LoadedConfig.applyCli`.
*/
LoadedConfig loadTerminalConfig(string filePath, string termuxDir)
{
    import std.file : exists;

    import sparkles.wired.config_file : readJsoncFileTolerant;

    LoadedConfig lc;
    lc.filePath = filePath;

    if (termuxDir.length)
        foreach (part; termuxLayer(termuxDir))
            applyOverlay(lc.effective, lc.origins, part.overlay,
                Origin(OriginKind.termux, "termux:" ~ part.file));

    if (filePath.length && filePath.exists)
    {
        auto r = readJsoncFileTolerant!(Sparse!TerminalConfig)(filePath);
        if (r.hasError)
            lc.warnings ~= configWarning(r.error, "this file's settings were ignored");
        else
        {
            foreach (e; r.value.dropped)
                lc.warnings ~= configWarning(e, "this value was ignored");
            lc.fileOverlay = r.value.value;
            applyOverlay(lc.effective, lc.origins, r.value.value,
                Origin(OriginKind.file, "file:" ~ filePath));
        }
    }
    return lc;
}

/// One located warning line (`TCF4`): the file, the position or `$`-path
/// and the offending value, and what was dropped.
string configWarning(JsonError e, string consequence) @safe
{
    import std.array : appender;

    auto w = appender!string;
    w ~= "config: ";
    if (e.filePath[].length)
    {
        w ~= e.filePath[];
        w ~= ": ";
    }
    e.toString(w);
    w ~= " — ";
    w ~= consequence;
    return w[];
}

// ─────────────────────────────────────────────────────────────────────────────
// The Termux layer (`TCF3`).
// ─────────────────────────────────────────────────────────────────────────────

/// One Termux file's contribution and the file it came from.
struct TermuxPart
{
    /// `termux.properties`, `colors.properties` or `font.ttf`.
    string file;
    /// What it sets; nothing else.
    Sparse!TerminalConfig overlay;
}

/**
The `~/.termux` files as overlays: `termux.properties`' `extra-keys` →
`extraKeys.layout`; `colors.properties` → both schemes, pinned
(`followSystem = false`); `font.ttf` → the font. A missing file, or one that
says nothing this layer maps, contributes no part.
*/
TermuxPart[] termuxLayer(string termuxDir)
{
    import std.file : exists;

    import extra_keys : propertyValue;
    import termux_config : parseTermuxColors;

    TermuxPart[] parts;

    const props = readOptional(buildPath(termuxDir, "termux.properties"));
    const layout = propertyValue(props, "extra-keys");
    if (layout !is null)
    {
        TermuxPart p = {file: "termux.properties"};
        p.overlay.extraKeys.layout = layout;
        parts ~= p;
    }

    const colors = parseTermuxColors(readOptional(buildPath(termuxDir, "colors.properties")));
    if (colors.any)
    {
        TermuxPart p = {file: "colors.properties"};
        setScheme(p.overlay.appearance.colors.dark, colors);
        setScheme(p.overlay.appearance.colors.light, colors);
        p.overlay.appearance.followSystem = false;
        parts ~= p;
    }

    const font = buildPath(termuxDir, "font.ttf");
    if (font.exists)
    {
        TermuxPart p = {file: "font.ttf"};
        p.overlay.appearance.font.family = font;
        parts ~= p;
    }
    return parts;
}

/// The overlay fields of one scheme that `c` speaks for. A palette entry the
/// file leaves out stays empty: the emulator's own colour for that slot.
private void setScheme(ref Sparse!SchemeColors s, in ColorOverrides c)
{
    if (c.hasForeground)
        s.foreground = hexColor(c.foreground);
    if (c.hasBackground)
        s.background = hexColor(c.background);
    if (c.hasCursor)
        s.cursor = hexColor(c.cursor);
    if (c.paletteMask)
    {
        auto palette = new string[16];
        foreach (i; 0 .. 16)
            if (c.paletteMask & (1 << i))
                palette[i] = hexColor(c.palette[i]);
        s.palette = palette;
    }
}

private string readOptional(string path)
{
    import std.file : exists, readText;

    import sparkles.base.logger : warning;

    try
        return path.exists ? readText(path) : null;
    catch (Exception e)
    {
        warning(i"config: unreadable $(path): $(e.msg)");
        return null;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// From the configuration to what the emulator takes.
// ─────────────────────────────────────────────────────────────────────────────

/// `#rrggbb`.
string hexColor(RgbColor c) @safe pure nothrow
{
    static immutable digits = "0123456789abcdef";
    char[7] s = '#';
    foreach (i, b; [c.r, c.g, c.b])
    {
        s[1 + 2 * i] = digits[b >> 4];
        s[2 + 2 * i] = digits[b & 0xF];
    }
    return s.idup;
}

/**
The scheme in effect: `colors.dark` or `.light` per the system when
`followSystem` is on (`TPR13`), the dark one otherwise — which a Termux
`colors.properties` makes the same as the light one.
*/
SchemeColors activeScheme(TerminalConfig c, bool systemDark) @safe pure nothrow
    => !c.appearance.followSystem || systemDark
        ? c.appearance.colors.dark : c.appearance.colors.light;

/**
A scheme as the emulator's colour overrides. An empty entry overrides
nothing; an unparsable one is dropped with a warning naming its `$`-path
(`where`, e.g. `appearance.colors.dark`), so one typo costs one colour.
*/
ColorOverrides colorOverrides(in SchemeColors s, string where, ref string[] warnings) @safe
{
    import std.conv : text;

    import termux_config : parseHexColor;

    ColorOverrides o;
    bool parse(string value, string field, out RgbColor c)
    {
        if (!value.length)
            return false;
        if (parseHexColor(value, c))
            return true;
        warnings ~= text("config: $.", where, ".", field, ": \"", value,
            "\" is not a #rrggbb colour — this value was ignored");
        return false;
    }

    RgbColor c;
    if (parse(s.foreground, "foreground", c))
    {
        o.foreground = c;
        o.hasForeground = true;
    }
    if (parse(s.background, "background", c))
    {
        o.background = c;
        o.hasBackground = true;
    }
    if (parse(s.cursor, "cursor", c))
    {
        o.cursor = c;
        o.hasCursor = true;
    }
    foreach (i, entry; s.palette)
    {
        if (i >= 16)
        {
            warnings ~= text("config: $.", where, ".palette has ", s.palette.length,
                " entries — entries past color15 were ignored");
            break;
        }
        if (parse(entry, text("palette[", i, "]"), c))
        {
            o.palette[i] = c;
            o.paletteMask |= cast(ushort)(1 << i);
        }
    }
    return o;
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests: hand-written fixtures per layer, with the expected resolved value.
// ─────────────────────────────────────────────────────────────────────────────

version (unittest)
{
    import sparkles.test_utils.tmpfs : TmpFS;
}

@("settings_load.loadTerminalConfig.defaultsWithoutFiles")
@system unittest
{
    auto fixture = TmpFS.create();
    auto lc = loadTerminalConfig(buildPath(fixture.dir, "config.json"),
        buildPath(fixture.dir, ".termux"));
    assert(lc.warnings.length == 0);
    assert(lc.effective == TerminalConfig.init);
    assert(lc.origins.behaviour.onExit.isDefault);
}

@("settings_load.loadTerminalConfig.fileOverridesTermuxEvenWithTheDefault")
@system unittest
{
    import extra_keys : defaultExtraKeysSpec;
    import settings : ExtraKeysVisibility, OnExit;

    auto fixture = TmpFS.create();
    fixture.writeFileAt(".termux/termux.properties",
        "extra-keys = [['ESC','TAB']]\n");
    fixture.writeFileAt(".termux/colors.properties",
        "foreground=#ffffff\nbackground=#000000\ncolor1=#ff0000\n");
    const file = fixture.writeFileAt("config.json", "{\n" ~
        "  // the TCF2 case: set to the default, over a lower layer's value\n" ~
        "  \"extraKeys\": { \"layout\": \"" ~ defaultExtraKeysSpec ~ "\", \"visible\": \"never\" },\n" ~
        "  \"behaviour\": { \"onExit\": \"hold\" },\n" ~
        "}\n");

    auto lc = loadTerminalConfig(file, buildPath(fixture.dir, ".termux"));
    assert(lc.warnings.length == 0, lc.warnings[0]);

    assert(lc.effective.extraKeys.layout == defaultExtraKeysSpec,
        "a value set to the default still overrides the Termux layer");
    assert(lc.origins.extraKeys.layout.text == "file:" ~ file);
    assert(lc.effective.extraKeys.visible == ExtraKeysVisibility.never);
    assert(lc.effective.behaviour.onExit == OnExit.hold);

    // colors.properties pins both schemes and turns following off (TCF3).
    assert(!lc.effective.appearance.followSystem);
    assert(lc.origins.appearance.followSystem.text == "termux:colors.properties");
    assert(lc.effective.appearance.colors.dark.foreground == "#ffffff");
    assert(lc.effective.appearance.colors.light.background == "#000000");
    assert(lc.effective.appearance.colors.light.palette[1] == "#ff0000");
    assert(lc.effective.appearance.colors.light.palette[2] == "",
        "a colour the file leaves out keeps the emulator's");
    // What the file did not say keeps the defaults.
    assert(lc.effective.appearance.font == TerminalConfig.init.appearance.font);
    assert(lc.fileOverlay.behaviour.onExit.get == OnExit.hold);
    assert(lc.fileOverlay.appearance.followSystem.isNull,
        "the Termux layer never leaks into the file's overlay");
}

@("settings_load.loadTerminalConfig.deletingATermuxFileRestoresTheDefault")
@system unittest
{
    import std.file : remove;

    auto fixture = TmpFS.create();
    const colors = fixture.writeFileAt(".termux/colors.properties", "background=#123456\n");
    const termux = buildPath(fixture.dir, ".termux");

    auto pinned = loadTerminalConfig(null, termux);
    assert(pinned.effective.appearance.colors.dark.background == "#123456");

    remove(colors);
    auto reloaded = loadTerminalConfig(null, termux);
    assert(reloaded.effective.appearance == TerminalConfig.init.appearance);
}

@("settings_load.loadTerminalConfig.malformedFilesDegradeLocated")
@system unittest
{
    import std.algorithm.searching : canFind;

    import settings : LinkAction;

    auto fixture = TmpFS.create();

    // A syntax error: the whole file is ignored, with its line.
    const broken = fixture.writeFileAt("broken.json", "{\n  \"links\": nope\n}\n");
    auto b = loadTerminalConfig(broken, null);
    assert(b.warnings.length == 1);
    assert(b.warnings[0].canFind(broken) && b.warnings[0].canFind("2"), b.warnings[0]);
    assert(b.warnings[0].canFind("this file's settings were ignored"));
    assert(b.effective == TerminalConfig.init);

    // One bad value: only that value is dropped, the rest applies.
    const typo = fixture.writeFileAt("typo.json",
        `{"links":{"tap":"sometimes","longPress":"open"},"paste":{"confirm":"never"}}`);
    auto t = loadTerminalConfig(typo, null);
    assert(t.warnings.length == 1, t.warnings.length ? t.warnings[0] : "");
    assert(t.warnings[0].canFind("links.tap") && t.warnings[0].canFind("sometimes"),
        t.warnings[0]);
    assert(t.warnings[0].canFind("this value was ignored"));
    assert(t.effective.links.tap == LinkAction.confirm);
    assert(t.effective.links.longPress == LinkAction.open);
    assert(t.effective.paste.confirm != TerminalConfig.init.paste.confirm);
}

@("settings_load.LoadedConfig.applyCli.isTheHighestLayer")
@system unittest
{
    auto fixture = TmpFS.create();
    const file = fixture.writeFileAt("config.json", `{"appearance":{"font":{"size":20}}}`);
    auto lc = loadTerminalConfig(file, null);

    Sparse!TerminalConfig cli;
    cli.appearance.font.size = 9;
    lc.applyCli(cli, "--font-size");
    assert(lc.effective.appearance.font.size == 9);
    assert(lc.origins.appearance.font.size.text == "cli:--font-size");
    assert(lc.fileOverlay.appearance.font.size.get == 20);
}

@("settings_load.colorOverrides.dropsOnlyTheBadColour")
@safe unittest
{
    import std.algorithm.searching : canFind;

    import settings : builtinDark;

    string[] warnings;
    auto s = builtinDark;
    s.palette = s.palette.dup;
    s.palette[3] = "yellowish";
    s.cursor = "";
    const o = colorOverrides(s, "appearance.colors.dark", warnings);
    assert(warnings.length == 1);
    assert(warnings[0].canFind("$.appearance.colors.dark.palette[3]"), warnings[0]);
    assert(o.hasForeground && o.foreground == RgbColor(0xcd, 0xd6, 0xf4));
    assert(!o.hasCursor, "an empty entry keeps the emulator's colour");
    assert(o.paletteMask == (0xFFFF & ~(1 << 3)));
}

@("settings_load.activeScheme.followsTheSystemUnlessPinned")
@safe unittest
{
    TerminalConfig c;
    assert(activeScheme(c, systemDark: true) == c.appearance.colors.dark);
    assert(activeScheme(c, systemDark: false) == c.appearance.colors.light);
    c.appearance.followSystem = false;
    assert(activeScheme(c, systemDark: false) == c.appearance.colors.dark);
}
