/**
The entry point: parse the command line, run the explorer (`FXU8`, `FXE11`).

Everything with behaviour lives in the other modules, inside the test build.
*/
module app;

import std.array : split;
import std.conv : to;

import sparkles.base.term_caps : isTerminal, StdStream;
import sparkles.core_cli.args : Command, failRun, Flatten, Option, ranOk, runCli, RunExpected;
import sparkles.ui.geometry : Size;
import sparkles.ui_app.gui_options : GuiOptions;
import sparkles.ui_app.host : RunConfig;
import sparkles.ui_app.run : asRunResult;
import sparkles.ui_app.run_app : runApp;

import evaluate : Root;
import explorer : ExplorerApp;
import render : renderFrame;

int main(string[] args) => runCli!Explorer(args);

/// The command line.
@(Command("fileset-explorer",
    shortDescription: "Write a fileset and watch what it selects."))
struct Explorer
{
    @(Option("dir", description: "The fileset root.", placeholder: "PATH"))
    string dir = ".";

    @(Option("query", description: "The query to start with.", placeholder: "QUERY"))
    string query = "**/*.md | **/dub.sdl  # documents and recipes";

    @(Option("render-plain", description:
        "Print one frame as text after --keys, and exit. Also what happens without a terminal."))
    bool renderPlain;

    @(Option("keys", description: "Keystrokes before --render-plain's frame.", placeholder: "KEYS"))
    string keys;

    @(Option("size", description: "The --render-plain surface, in cells.", placeholder: "WxH"))
    string size = "100x30";

    @Flatten("GUI Options")
    GuiOptions gui;

    /// Runs the explorer, or renders one frame of it.
    RunExpected!void run()
    {
        auto app = new ExplorerApp(Root(dir: dir), query);
        if (renderPlain || !isTerminal(StdStream.stdin) || !isTerminal(StdStream.stdout))
        {
            import std.stdio : write;

            const wh = size.split('x');
            if (wh.length != 2)
                return failRun("--size is WIDTHxHEIGHT");
            write(renderFrame(*app, keys, Size(wh[0].to!int, wh[1].to!int), gui));
            return ranOk();
        }
        RunConfig cfg = { title: "fileset explorer", gui: gui };
        return asRunResult(runApp(*app, cfg), "fileset-explorer");
    }
}
