/**
Opening the explorer in a window or a terminal, shared by the command line
(app.d) and the Android entry (android_entry.d), and where its tree-sitter
grammars come from on each.
*/
module launch;

import sparkles.core_cli.args : RunExpected;
import sparkles.syntax.ts.registry : GrammarRegistry;
import sparkles.ui_app.gui_options : GuiOptions, NativeOptions;
import sparkles.ui_app.host : RunConfig, TouchGestures;
import sparkles.ui_app.run : asRunResult;
import sparkles.ui_app.run_app : runApp;

import sparkles.fileset_tools.evaluate : Root;
import explorer : ExplorerApp;

/// The query the explorer opens with.
enum defaultQuery = "**/*.md | **/dub.sdl  # documents and recipes";

/// The cell font's size, in points (`FXU16`): a third under the toolkit's
/// default, for a denser tree and help, on the desktop and on Android.
enum int explorerFontPoints = 12;

/// The window options the explorer starts from; flags the user types win.
enum GuiOptions explorerGui = GuiOptions(fontSize: explorerFontPoints);

/// FXU16: the explorer's cell font is 25–40% under the toolkit's.
@("fileset_explorer.FXU16.density")
@safe pure nothrow @nogc unittest
{
    import sparkles.ui_app.gui_options : defaultFontSizePoints;

    static assert(explorerGui.fontSize == 12);
    static assert(explorerGui.fontSize <= defaultFontSizePoints * 3 / 4
        && explorerGui.fontSize >= defaultFontSizePoints * 6 / 10);
}

/**
The grammar queries' root when the parsers load by soname from the
application's own libraries (Android, `FXA3`); empty: the parsers and queries
are found through `$SPARKLES_TS_GRAMMAR_PATH`.
*/
string sonameQueriesRoot;

/// The grammars the help and the Export tab highlight with.
GrammarRegistry appGrammars() @safe
    => sonameQueriesRoot.length ? GrammarRegistry.fromSonames(sonameQueriesRoot)
        : GrammarRegistry.fromEnvironment();

/**
Runs the explorer on `dir`, starting from `query`, until it quits.

Touch resolves through the gesture recogniser (`FXU10`): a tap is a click, a
drag scrolls the pane under it by its exact distance, and a lifted finger
flings it on.
*/
RunExpected!void launch(Root dir, string query, GuiOptions gui, bool touch = false,
    NativeOptions native = NativeOptions.init, bool nerdFont = true)
{
    auto app = new ExplorerApp(dir, query);
    if (touch)
        app.layout = ExplorerApp.Layout.touch;
    return asRunResult(runApp(*app, explorerRunConfig(gui, native, nerdFont)), "fileset-explorer");
}

/**
What the explorer asks of its host. In a terminal, bare pointer motion
(any-event tracking): a terminal declares hover only when asked for it, and
without hover the explorer takes the touch layout (`FXU11`), whose rows are
two cells tall, where hue's tree has rows of one.
*/
RunConfig explorerRunConfig(GuiOptions gui, NativeOptions native = NativeOptions.init, bool nerdFont = true)
    @safe
{
    RunConfig cfg = {
        title: "fileset explorer",
        gui: gui,
        native: native,
        motion: true,
        fractionalScroll: true,
        touchGestures: TouchGestures.all,
        // Hue's file icons in a terminal too, as hue draws them (`FXU9`).
        nerdFont: nerdFont,
    };
    cast(void) cfg.app.id.assign("dev.petar_kirov.sparkles.fileset_explorer");
    cast(void) cfg.app.name.assign("Fileset Explorer");
    return cfg;
}
