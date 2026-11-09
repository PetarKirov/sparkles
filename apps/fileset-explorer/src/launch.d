/**
Opening the explorer in a window or a terminal, shared by the command line
(app.d) and the Android entry (android_entry.d), and where its tree-sitter
grammars come from on each.
*/
module launch;

import sparkles.core_cli.args : RunExpected;
import sparkles.syntax.ts.registry : GrammarRegistry;
import sparkles.ui_app.gui_options : GuiOptions;
import sparkles.ui_app.host : RunConfig, TouchGestures;
import sparkles.ui_app.run : asRunResult;
import sparkles.ui_app.run_app : runApp;

import evaluate : Root;
import explorer : ExplorerApp;

/// The query the explorer opens with.
enum defaultQuery = "**/*.md | **/dub.sdl  # documents and recipes";

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
RunExpected!void launch(Root dir, string query, GuiOptions gui, bool touch = false)
{
    auto app = new ExplorerApp(dir, query);
    if (touch)
        app.layout = ExplorerApp.Layout.touch;
    RunConfig cfg = {
        title: "fileset explorer",
        gui: gui,
        fractionalScroll: true,
        touchGestures: TouchGestures.all,
    };
    cast(void) cfg.app.id.assign("dev.petar_kirov.sparkles.fileset_explorer");
    cast(void) cfg.app.name.assign("Fileset Explorer");
    return asRunResult(runApp(*app, cfg), "fileset-explorer");
}
