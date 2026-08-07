/// The terminal's historical CLI, mapped onto the host's options — spellings
/// and defaults preserved (the shared-CLI unification is a separate, visible
/// change; this migration's gate is identical behavior).
module cli;

import sparkles.ui_app.gui_options : GuiOptions;

/// The flag values `main` collects, at their pre-migration defaults.
struct TerminalCli
{
    string font = "monospace";
    int fontSizePt = 13;
    int windowCols = 100;
    int windowRows = 30;
    string[] codepointMaps;
    string[] fontDirs;
}

/// The host's window/font options for those flags. The styled faces are
/// cleared so the loader auto-derives them from the primary — the
/// pre-migration `FaceOverrides.init` behavior, not the shared Maple default.
@safe pure nothrow
GuiOptions guiOptionsFrom(TerminalCli cli)
{
    GuiOptions gui;
    gui.font = cli.font;
    gui.fontSize = cli.fontSizePt;
    gui.fontBold = null;
    gui.fontItalic = null;
    gui.fontBoldItalic = null;
    gui.fontCodepointMap = cli.codepointMaps;
    gui.fontDir = cli.fontDirs;
    gui.windowWidth = cli.windowCols;
    gui.windowHeight = cli.windowRows;
    gui.gui = true; // a terminal emulator IS a window; no backend probing
    return gui;
}

@("cli.guiOptionsFrom.preservesTheTerminalDefaults")
@safe pure nothrow
unittest
{
    // The migration must not silently change what `terminal` opens with:
    // 13 pt monospace in a 100×30 window, styled faces auto-derived — NOT the
    // shared 18 pt Maple defaults GuiOptions itself carries.
    const gui = guiOptionsFrom(TerminalCli());
    assert(gui.font == "monospace");
    assert(gui.fontSize == 13);
    assert(gui.windowWidth == 100);
    assert(gui.windowHeight == 30);
    assert(gui.fontBold is null && gui.fontItalic is null
        && gui.fontBoldItalic is null);
    assert(gui.gui, "the backend decision is forced to the window");
}

@("cli.guiOptionsFrom.passesTheFlagsThrough")
@safe pure nothrow
unittest
{
    auto cli = TerminalCli(
        font: "/tmp/f.ttf",
        fontSizePt: 20,
        windowCols: 80,
        windowRows: 24,
        codepointMaps: ["U+2600-U+26FF=Noto"],
        fontDirs: ["/tmp/fonts"],
    );
    const gui = guiOptionsFrom(cli);
    assert(gui.font == "/tmp/f.ttf");
    assert(gui.fontSize == 20);
    assert(gui.fontCodepointMap == ["U+2600-U+26FF=Noto"]);
    assert(gui.fontDir == ["/tmp/fonts"]);
    assert(gui.windowWidth == 80 && gui.windowHeight == 24);
}
