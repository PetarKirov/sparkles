/**
`ui-gallery` — a browsable catalog of the `sparkles:ui` toolkit.

The entry point does three things and no more: parse the command line, build the
component, hand it to `runApp`. It names no canvas, no window and no terminal —
which backend opens is the host's decision, and the same `view` runs on either.
*/
module app;

import std.stdio : stderr, write, writefln, writeln;
import std.traits : isDynamicArray, isSomeString;

import sparkles.core_cli.args : HelpInfo, Option, parseCli, reportCliError;
import sparkles.ui_app.gui_options : GuiCliFields, GuiOptions, resolveTheme;
import sparkles.ui_app.host : RunConfig;

import sparkles.ui_app.run : RunOutcome;
import sparkles.ui_app.run_app : runApp;
import gallery : Gallery;
import registry : pageIndexOf, pages;
import render : renderAnsi, renderPlain, RenderRequest;
import state : GalleryState, themeNames;

/**
The gallery's command line.

The window/font/theme flags come from the shared mixin rather than being
declared again here — that is what `CLI1`–`CLI3` exist for, and it means
`--font-size` means the same thing in every application in the repository.
*/
struct Params
{
    mixin GuiCliFields;

    @(Option("page|p", description:
        "Start on this page, by name prefix or 1-based number."))
    string page;

    @(Option("list-pages", description:
        "Print the catalog and exit. Needs no backend."))
    bool listPages;

    @(Option("list-themes", description: "Print the built-in themes and exit."))
    bool listThemes;

    @(Option("render", description:
        "Render one frame to stdout and exit, opening nothing. Use with "
        ~ "--page, --keys and --window-width/--window-height."))
    bool render;

    @(Option("render-plain", description:
        "As --render, but glyphs only with no colour — the form the golden "
        ~ "snapshots compare against."))
    bool renderPlain;

    @(Option("keys|k", description:
        "With --render: keystrokes to deliver before the frame is taken, "
        ~ "e.g. ']]j'."))
    string keys;
}

int main(string[] args)
{
    auto parsed = parseCli!Params(args, HelpInfo(
        "ui-gallery",
        "A browsable catalog of the sparkles:ui toolkit — the same widget "
        ~ "trees, laid out and painted in a terminal or in a window.",
        null,
    ));
    if (!parsed)
        return reportCliError(parsed.error);
    const cli = parsed.value;

    if (cli.listPages)
    {
        foreach (i, ref p; pages)
            writefln("%2d  %-14s %s", i + 1, p.title, p.blurb);
        return 0;
    }

    if (cli.listThemes)
    {
        foreach (n; themeNames)
            writeln(n);
        return 0;
    }

    // A theme name no built-in carries is reported rather than silently
    // substituted — the resolver returns null precisely so this layer, the one
    // that can print, decides what to do about a typo.
    if (resolveTheme(cli) is null)
    {
        stderr.writefln("ui-gallery: unknown theme '%s' (try --list-themes)",
            cli.theme);
        return 2;
    }

    if (cli.render || cli.renderPlain)
    {
        const req = RenderRequest(
            page: pageIndexOf(cli.page),
            keys: cli.keys,
            width: cli.windowWidth,
            height: cli.windowHeight,
        );
        write(cli.renderPlain ? renderPlain(req) : renderAnsi(req));
        return 0;
    }

    // `Params` is `mixin GuiCliFields` plus this application's own flags, so
    // the shared fields are its first N in declaration order and the copy is
    // structural rather than a list that could fall out of date. The array
    // fields are duplicated because the parsed value arrives `const`.
    GuiOptions gui;
    static foreach (i, T; typeof(GuiOptions.tupleof))
    {
        static if (isDynamicArray!T && !isSomeString!T)
            gui.tupleof[i] = cli.tupleof[i].dup;
        else
            gui.tupleof[i] = cli.tupleof[i];
    }

    RunConfig cfg = {
        title: "sparkles ui gallery",
        gui: gui,
        targetFps: 60,
    };

    auto app = Gallery(GalleryState(
        page: pageIndexOf(cli.page),
        themeIndex: themeIndexOf(cli.theme),
    ));

    final switch (runApp(app, cfg))
    {
        case RunOutcome.ok:
            return 0;
        case RunOutcome.notInteractive:
            stderr.writeln("ui-gallery needs a terminal or a display");
            return 2;
        case RunOutcome.noBackend:
            stderr.writeln("ui-gallery: this build carries no interactive backend");
            return 1;
        case RunOutcome.openFailed:
            stderr.writeln("ui-gallery: the backend would not open");
            return 1;
    }
}

/// Where `name` sits in the catalog's own theme order. Falls back to the
/// default rather than failing: an alias spelling (`tokyonight`) resolves as a
/// theme but is not one of the ordered names, and starting on the default is a
/// better answer there than refusing to run.
private size_t themeIndexOf(scope const(char)[] name)
{
    import sparkles.ui.themes : builtinThemes;

    const wanted = name in builtinThemes;
    if (wanted !is null)
        foreach (i, n; themeNames)
            if (builtinThemes[n].name == wanted.name)
                return i;
    return GalleryState.init.themeIndex;
}
