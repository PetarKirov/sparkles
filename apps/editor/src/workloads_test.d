/**
The editor's acceptance workloads (`EAP27`–`EAP30`, plan item 9): a 1 MiB and
a 10 MiB source file and a 1 MiB single line, each opened, drawn, edited and
searched through the real app and the recording host. Each phase reports
its wall time separately (open, the first frame, the median steady frame,
an edit with its frame, a find-next with its frame), so a regression names
the phase it lives in. Run with `dub test :editor -- --bench -i workload`.
*/
module workloads_test;

import core.time : Duration, MonoTime;
import sparkles.test_runner.attributes : workload;

version (unittest):

private string sourceOf(size_t bytes, bool oneLine) @safe pure nothrow
{
    enum line = "    int value = compute(alpha, beta) + 42; // a typical line of code\n";
    auto result = new char[bytes];
    foreach (i, ref c; result)
        c = oneLine && line[i % line.length] == '\n' ? ' ' : line[i % line.length];
    return (() @trusted => cast(string) result)();
}

private double ms(Duration d) @safe pure nothrow @nogc => d.total!"hnsecs" / 10_000.0;

@("editor.workload.documents")
@workload
@system unittest
{
    import std.algorithm : sort;
    import std.stdio : writefln, writeln;
    import editor_app : EditorApp;
    import commands : Command, CommandId;
    import sparkles.input : Key, keyEvent;
    import sparkles.ui_app.record : RecordingHost;
    import sparkles.ui_app.run_app : AppTheme, FrameSnapshot, presentApp;
    import sparkles.ui.editor.command : EditCommand;
    import sparkles.ui.style : defaultTwoslashPalette;

    writeln("\neditor workloads: wall ms per phase (recording host, 120×40 cells)");
    writefln("%-18s %9s %9s %9s %9s %9s", "document", "open", "first", "steady", "edit", "find");
    static struct Case { string name; size_t bytes; bool oneLine; }
    foreach (c; [Case("1 MiB source", 1 << 20, false), Case("10 MiB source", 10 << 20, false),
        Case("1 MiB one line", 1 << 20, true)])
    {
        auto app = new EditorApp;
        scope (exit) destroy(*app);
        RecordingHost host;
        host.size.width = 120;
        host.size.height = 40;
        FrameSnapshot frame;
        const bytes = sourceOf(c.bytes, c.oneLine);
        auto start = MonoTime.currTime;
        assert(app.openBytes(c.name ~ ".c", bytes));
        const open = MonoTime.currTime - start;
        start = MonoTime.currTime;
        presentApp(*app, host, AppTheme(defaultTwoslashPalette()), frame);
        const first = MonoTime.currTime - start;
        Duration[15] frames;
        foreach (ref f; frames)
        {
            start = MonoTime.currTime;
            presentApp(*app, host, AppTheme(defaultTwoslashPalette()), frame);
            f = MonoTime.currTime - start;
        }
        sort(frames[]);
        app.document.field.run(EditCommand.setRange(bytes.length / 2, bytes.length / 2));
        start = MonoTime.currTime;
        app.document.field.insert("x");
        presentApp(*app, host, AppTheme(defaultTwoslashPalette()), frame);
        const edit = MonoTime.currTime - start;
        app.execute(CommandId(Command.find));
        app.finder.query.setText("compute");
        start = MonoTime.currTime;
        app.execute(CommandId(Command.findNext));
        presentApp(*app, host, AppTheme(defaultTwoslashPalette()), frame);
        const find = MonoTime.currTime - start;
        writefln("%-18s %9.2f %9.2f %9.2f %9.2f %9.2f", c.name, ms(open), ms(first),
            ms(frames[$ / 2]), ms(edit), ms(find));
        assert(app.document.field.state.selection.primary.end - app.document.field.state.selection.primary.start == 7);
    }
}
