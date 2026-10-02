/**
From the resolved configuration to what the host and the emulator take: the
window and font options (`GuiOptions`) and the session options
(`TerminalViewOptions`). The desktop's flags are the configuration's highest
layer (`TCF2`), spelled as they always were; this module owns that mapping
too, so `app.d` only parses.
*/
module cli;

import sparkles.terminal_view.component : TerminalViewOptions;
import sparkles.terminal_view.input : ExitBehavior;
import sparkles.ui_app.gui_options : GuiOptions;

import settings : OnExit, TerminalConfig;

/// The host's window/font options for a configuration and a window size in
/// cells. An empty styled face is left null, so the loader derives it from
/// the primary (the terminal's long-standing default, not the shared Maple
/// faces `GuiOptions` itself carries).
@safe pure nothrow
GuiOptions guiOptionsFrom(TerminalConfig c, int windowCols = 100, int windowRows = 30)
{
    static string orNull(string s) => s.length ? s : null;

    const f = c.appearance.font;
    GuiOptions gui;
    gui.font = f.family;
    gui.fontSize = f.size;
    gui.fontBold = orNull(f.bold);
    gui.fontItalic = orNull(f.italic);
    gui.fontBoldItalic = orNull(f.boldItalic);
    gui.fontCodepointMap = f.codepointMap.dup;
    gui.fontDir = f.fontDir.dup;
    gui.windowWidth = windowCols;
    gui.windowHeight = windowRows;
    gui.gui = true; // a terminal emulator IS a window; no backend probing
    return gui;
}

/**
The emulator's session options a configuration decides: scrollback, the exit
behaviour and the colour scheme in effect (`systemDark` picks it when
`appearance.followSystem` is on). Colour typos land in `warnings`.
*/
TerminalViewOptions viewOptionsFrom(TerminalConfig c, bool systemDark,
    ref string[] warnings) @safe
{
    import settings_load : activeScheme, colorOverrides;

    TerminalViewOptions o;
    o.scrollbackLimit = c.behaviour.scrollback < 0 ? size_t.max
        : cast(size_t) c.behaviour.scrollback;
    o.exitBehavior = exitBehaviorFor(c.behaviour.onExit);
    o.colors = colorOverrides(activeScheme(c, systemDark),
        !c.appearance.followSystem || systemDark ? "appearance.colors.dark"
            : "appearance.colors.light", warnings);
    return o;
}

/**
`behaviour.onExit` as the emulator's exit behaviour. Until the exit prompt
exists (`TSS2`), `prompt` keeps the screen until a key is pressed and
`promptOnFailure` does so only after a failure.
*/
ExitBehavior exitBehaviorFor(OnExit e) @safe pure nothrow @nogc
{
    final switch (e)
    {
        case OnExit.promptOnFailure:
            return ExitBehavior.holdOnFailure;
        case OnExit.prompt:
            return ExitBehavior.waitForKey;
        case OnExit.close:
            return ExitBehavior.close;
        case OnExit.hold:
            return ExitBehavior.hold;
    }
}

/// `--exit-behavior`'s historical spellings as `behaviour.onExit`; false for
/// an unknown one.
bool onExitFromFlag(scope const(char)[] s, out OnExit e) @safe pure nothrow @nogc
{
    switch (s)
    {
        case "close":
            e = OnExit.close;
            return true;
        case "wait-for-key":
            e = OnExit.prompt;
            return true;
        case "hold":
            e = OnExit.hold;
            return true;
        case "hold-on-failure":
            e = OnExit.promptOnFailure;
            return true;
        default:
            return false;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests.
// ─────────────────────────────────────────────────────────────────────────────

@("cli.guiOptionsFrom.preservesTheTerminalDefaults")
@safe pure nothrow
unittest
{
    // `terminal` opens with 13 pt monospace in a 100×30 window, styled faces
    // auto-derived — NOT the shared 18 pt Maple defaults GuiOptions carries.
    version (Android) {} else
    {
        const gui = guiOptionsFrom(TerminalConfig.init);
        assert(gui.font == "monospace");
        assert(gui.fontSize == 13);
        assert(gui.windowWidth == 100);
        assert(gui.windowHeight == 30);
        assert(gui.fontBold is null && gui.fontItalic is null
            && gui.fontBoldItalic is null);
        assert(gui.gui, "the backend decision is forced to the window");
    }
}

@("cli.guiOptionsFrom.passesTheFontThrough")
@safe pure nothrow
unittest
{
    TerminalConfig c;
    c.appearance.font.family = "/tmp/f.ttf";
    c.appearance.font.size = 20;
    c.appearance.font.bold = "Iosevka Bold";
    c.appearance.font.codepointMap = ["U+2600-U+26FF=Noto"];
    c.appearance.font.fontDir = ["/tmp/fonts"];
    const gui = guiOptionsFrom(c, 80, 24);
    assert(gui.font == "/tmp/f.ttf");
    assert(gui.fontSize == 20);
    assert(gui.fontBold == "Iosevka Bold" && gui.fontItalic is null);
    assert(gui.fontCodepointMap == ["U+2600-U+26FF=Noto"]);
    assert(gui.fontDir == ["/tmp/fonts"]);
    assert(gui.windowWidth == 80 && gui.windowHeight == 24);
}

@("cli.viewOptionsFrom.mapsTheSessionSettings")
@safe unittest
{
    import sparkles.base.term_color : RgbColor;

    TerminalConfig c;
    string[] warnings;
    auto o = viewOptionsFrom(c, systemDark: false, warnings);
    assert(o.scrollbackLimit == size_t.max, "-1 keeps everything");
    assert(o.exitBehavior == ExitBehavior.holdOnFailure);
    assert(o.colors.background == RgbColor(0xef, 0xf1, 0xf5), "light follows the system");

    c.behaviour.scrollback = 0;
    c.behaviour.onExit = OnExit.close;
    c.appearance.followSystem = false;
    o = viewOptionsFrom(c, systemDark: false, warnings);
    assert(o.scrollbackLimit == 0);
    assert(o.exitBehavior == ExitBehavior.close);
    assert(o.colors.background == RgbColor(0x1e, 0x1e, 0x2e), "pinned: the dark scheme");
    assert(warnings.length == 0);
}

@("cli.onExitFromFlag.keepsTheHistoricalSpellings")
@safe pure nothrow @nogc
unittest
{
    OnExit e;
    assert(onExitFromFlag("hold-on-failure", e) && e == OnExit.promptOnFailure);
    assert(onExitFromFlag("wait-for-key", e) && e == OnExit.prompt);
    assert(onExitFromFlag("close", e) && e == OnExit.close);
    assert(!onExitFromFlag("sometimes", e));
}
