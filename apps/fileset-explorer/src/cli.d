/**
The command line (`FXC1`–`FXC4`, `X19`): `view`, the default, opens the
explorer; `stats` prints its Stats tab; `send` does what its Send button
does; `emit` writes the query for another build system. `--dir` and
`--query` name the fileset for all four, on either side of the subcommand.
*/
module cli;

import core.time : Duration, msecs;
import std.array : split;
import std.conv : to;
import std.sumtype : SumType;

import sparkles.base.term_caps : isTerminal, StdStream;
import sparkles.core_cli.args : Argument, Command, failRun, Flatten, Option, ranOk, RunExpected, Subcommands;
import sparkles.iroh_send : SendPhase;
import sparkles.ui.geometry : Size;
import sparkles.ui_app.gui_options : GuiOptions, NativeOptions;

import evaluate : evaluate, humanBytes, Root;
import explorer : ExplorerApp;
import launch : defaultQuery, explorerGui, launch;
import render : renderFrame;
import send : BlobProvider, IrohProvider, openIrohProvider, SendStage, Sending;
import stats : formatStats, statsRows;

/// The command line.
@(Command("fileset-explorer",
    shortDescription: "Write a fileset and watch what it selects, print its numbers, or send it."))
struct Explorer
{
    @(Option("dir", description: "The fileset root.", placeholder: "PATH"))
    string dir = ".";

    @(Option("query", description: "The query: what `view` starts with, what the others act on.",
        placeholder: "QUERY"))
    string query = defaultQuery;

    @Subcommands
    SumType!(View, StatsCommand, SendCommand, Emit) command;
}

/// `view`: the explorer, in a window, the terminal, or one frame as text.
@(Command("view", isDefault: true,
    shortDescription: "Open the explorer (the default): a window, the terminal, or one frame as text."))
struct View
{
    @(Option("render-plain", description:
        "Print one frame as text after --keys, and exit. Also what happens without a terminal."))
    bool renderPlain;

    @(Option("keys", description: "Keystrokes before --render-plain's frame.", placeholder: "KEYS"))
    string keys;

    @(Option("size", description: "The --render-plain surface, in cells.", placeholder: "WxH"))
    string size = "100x30";

    @(Option("touch", description:
        "Draw the touch layout, as on a tablet, whatever the pointer."))
    bool touch;

    @Flatten("GUI Options")
    GuiOptions gui = explorerGui;

    @Flatten("Native Window Options")
    NativeOptions native;

    /// Runs the explorer, or renders one frame of it (`FXU8`).
    RunExpected!void run(Program)(in Program program)
    {
        const root = Root(dir: program.value.dir);
        const query = program.value.query;
        // Without a terminal, a frame as text, unless a window was asked for.
        if (renderPlain || (!gui.gui && (!isTerminal(StdStream.stdin) || !isTerminal(StdStream.stdout))))
        {
            import std.stdio : write;

            auto app = new ExplorerApp(root, query);
            if (touch)
                app.layout = ExplorerApp.Layout.touch;
            const wh = size.split('x');
            if (wh.length != 2)
                return failRun("--size is WIDTHxHEIGHT");
            write(renderFrame(*app, keys, Size(wh[0].to!int, wh[1].to!int), gui));
            return ranOk();
        }
        return launch(root, query, gui, touch, native);
    }
}

/// `stats`: the Stats tab, printed (`FXC2`).
@(Command("stats", shortDescription: "Print the numbers and names the Stats tab shows, and exit."))
struct StatsCommand
{
    @(Option("ids", description: "Compute the names however large the fileset is, as i does in the tree."))
    bool ids;

    ///
    int run(Program)(in Program program)
    {
        import std.stdio : stderr, write;

        string output, error;
        const status = statsCommand(Root(dir: program.value.dir), program.value.query, ids, output, error);
        write(output);
        stderr.write(error);
        return status;
    }
}

/**
What `stats` prints for `query` beneath `root` (`FXC2`): the Stats tab's
lines without its Send section, on `output`, and 0; or why the query does not
parse or resolve, on `error`, and 1.
*/
int statsCommand(in Root root, string query, bool ids, out string output, out string error)
{
    const o = evaluate(root, query, ids);
    if (o.failed)
    {
        error = "fileset-explorer: " ~ o.error.message ~ "\n";
        return 1;
    }
    output = formatStats(statsRows(o, o, ": stats --ids computes them"));
    return 0;
}

/// `send`: the Send button, from the command line (`FXC3`).
@(Command("send", shortDescription:
    "Send the fileset as sendme sends a directory: ask, then serve the ticket until interrupted."))
struct SendCommand
{
    @(Option("yes", description: "Send without asking; without a terminal, required."))
    bool yes;

    @(Option("no-relay", description: "Give a ticket of direct addresses only, for a receiver on the same network."))
    bool noRelay;

    ///
    int run(Program)(in Program program)
    {
        import core.stdc.signal : signal, SIGINT, SIGTERM;
        import core.thread : Thread;
        import std.stdio : stderr, stdout;

        signal(SIGINT, &onInterrupt);
        signal(SIGTERM, &onInterrupt);
        SendIo io;
        io.out_ = (string s) { stdout.write(s); stdout.flush(); };
        io.err = (string s) { stderr.write(s); stderr.flush(); };
        io.interrupted = () => interrupted;
        io.wait = (Duration d) { Thread.sleep(d); };
        io.interactive = isTerminal(StdStream.stdin) && isTerminal(StdStream.stderr);
        io.ask = (string question) => askOnStderr(question);
        const direct = noRelay;
        return sendCommand(Root(dir: program.value.dir), program.value.query, yes,
            (out string why) => openIrohProvider(why, direct), io);
    }
}

/// What `send` writes to and reads from, so a test can stand in for them.
struct SendIo
{
    void delegate(string) out_;       /// standard output: the receive command alone
    void delegate(string) err;        /// standard error: everything else
    bool delegate() interrupted;      /// an interrupt has come
    void delegate(Duration) wait;     /// between two reads of the send
    bool interactive;                 /// a person can answer a question
    bool delegate(string) ask;        /// a yes-or-no question, answered
    Duration tick = 250.msecs;        /// how often the send is read
}

/**
`send` (`FXC3`): what Send does, with the question asked of `io`. Exits 0
once interrupted, the provider stopped; 1 when it cannot send, is not let
to, or the send fails.
*/
int sendCommand(in Root root, string query, bool yes, BlobProvider delegate(out string why) makeProvider,
    ref SendIo io)
{
    import std.conv : text;

    const o = evaluate(root, query, withIds: true);
    if (o.failed)
    {
        io.err("fileset-explorer: " ~ o.error.message ~ "\n");
        return 1;
    }
    Sending s;
    s.makeProvider = makeProvider;
    s.ask(o, root, query);
    if (s.stage == SendStage.unavailable)
    {
        io.err("send: " ~ s.note ~ "\n");
        return 1;
    }
    io.err(text("send: ", s.sent.files.length, " files (", humanBytes(s.sent.bytes), ")",
        s.sent.links ? text(", ", s.sent.links, s.sent.links == 1 ? " link" : " links", " left out") : "", "\n",
        "send: collection ", s.sent.collection, "\n",
        "send: anyone with the ticket can fetch them\n"));
    if (!yes)
    {
        if (!io.interactive)
        {
            io.err("send: not sent: without a terminal, --yes says to send\n");
            return 1;
        }
        if (!io.ask("Send these files?"))
        {
            io.err("send: not sent\n");
            return 1;
        }
    }
    s.confirm();
    string lastPhase, lastProgress;
    bool printed;
    while (!io.interrupted())
    {
        s.tick();
        if (s.stage != SendStage.running)
        {
            io.err("send: " ~ s.note ~ "\n");
            return 1;
        }
        const phase = s.state.phase == SendPhase.importing ? "importing" : s.phaseText;
        if (phase != lastPhase)
        {
            io.err("send: " ~ s.phaseText ~ "\n");
            lastPhase = phase;
        }
        if (const cmd = s.receiveCommand)
        {
            if (!printed)
            {
                io.out_(cmd ~ "\n");
                printed = true;
            }
            const progress = text(s.state.peers, " connected, ", s.state.requests, " requests, ",
                humanBytes(s.state.bytesSent), " sent");
            if (progress != lastProgress)
            {
                io.err("send: " ~ progress ~ "\n");
                lastProgress = progress;
            }
        }
        io.wait(io.tick);
    }
    s.stop();
    io.err("send: stopped\n");
    return 0;
}

/// `emit`: the query written for another build system (`FXC4`, `FXE11`).
@(Command("emit", shortDescription:
    "Print the query written for TARGET: nix, git-pathspec, gitignore, rsync, tar, cargo, bazel or dub."))
struct Emit
{
    @(Argument("target"))
    string target;

    @(Option("nix-globs", description: "How nix writes a glob: shim, expand or refuse.", placeholder: "MODE"))
    string nixGlobs = "shim";

    /// The code on standard output, or the refusal on standard error and
    /// exit status 2 (`FXE11`).
    int run(Program)(in Program program)
    {
        import std.stdio : stderr, write;
        import export_tab : emitCommand;

        string output, error;
        const status = emitCommand(program.value.dir, program.value.query, target, nixGlobs, output, error);
        write(output);
        stderr.write(error);
        return status;
    }
}

// ---------------------------------------------------------------------------

private __gshared bool interrupted;

private extern (C) void onInterrupt(int) nothrow @nogc @system
{
    interrupted = true;
}

// A yes-or-no question on standard error, standard output being the ticket's.
private bool askOnStderr(string question)
{
    import std.stdio : readln, stderr;
    import std.string : chomp;
    import sparkles.core_cli.prompts : confirm, PromptIo, PromptPolicy;

    PromptIo io;
    io.readLine = () {
        auto line = readln();
        return line is null ? null : line.chomp;
    };
    io.write = (scope const(char)[] text) {
        stderr.rawWrite(text);
        stderr.flush();
    };
    const answer = confirm(question, false, PromptPolicy.interactive, io);
    return answer.hasValue && answer.value;
}
