#!/usr/bin/env dub
/+ dub.sdl:
name "streaming-box"
dependency "sparkles:core-cli" path="../../.."
targetPath "build"
+/

module streaming_box_example;

// Animated `drawBox`: both the title and the content are pulled from a range whose
// `popFront` sleeps, so iterating `drawBoxLines` draws the box top-to-bottom over
// time. The content showcases colour by listing a source file through `bat`
// (`--file`), or — with no file — generated colour so the demo always runs.
//
//   dub run --single streaming-box.d -- --max-width 72 --delay 40
//   dub run --single streaming-box.d -- --file path/to/src.d --max-width 96 --delay 25

import core.thread : Thread;
import core.time : dur;
import std.range.primitives : ElementType, empty, front, popFront;
import std.stdio : stderr, stdout, writeln;

import sparkles.core_cli.args;
import sparkles.core_cli.ui.box : BoxProps, drawBoxLines, TitleOverflow;
import sparkles.base.term_style : Style, stylize;

struct CliParams
{
    @CliOption("w|max-width", "Box width in columns")
    int maxWidth = 80;

    @CliOption("t|title-length", "Length of the generated title in columns")
    int titleLength = 64;

    @CliOption("f|file", "Source file to colorize via `bat` (else generated content)")
    string file;

    @CliOption("c|content-length", "Generated content length when no --file")
    int contentLength = 600;

    @CliOption("d|delay", "Animation delay per streamed line, in milliseconds")
    int delayMs = 60;
}

/// A forward range that sleeps on each `popFront`, so consuming it animates output.
struct DelayedLines(R)
{
    private R _src;
    private int _delayMs;

    bool empty() => _src.empty;
    ElementType!R front() => _src.front;
    void popFront()
    {
        _src.popFront;
        if (!_src.empty)
            Thread.sleep(dur!"msecs"(_delayMs));
    }
}

auto delayedLines(R)(R src, int delayMs) => DelayedLines!R(src, delayMs);

void main(string[] args)
{
    const cli = args.parseCliArgs!CliParams(
        HelpInfo("streaming-box", "Animated streaming drawBox demo"));

    // Stream the title from a delayed range first: the words arrive over time, so
    // the box's top border appears only once the title has fully composed.
    string title;
    foreach (word; delayedLines(generatedTitleWords(cli.titleLength), cli.delayMs))
        title ~= (title.length ? " " : "") ~ word;

    // A fixed-width box so the top can be drawn before any content arrives and the
    // rows can stream in; `wrap` shows the nested title box for a long title.
    const props = BoxProps(
        minWidth: cli.maxWidth,
        maxWidth: cli.maxWidth,
        titleOverflow: TitleOverflow.wrap,
    );

    // Pull the content lazily through the delayed range; each emitted box row drives
    // one source `popFront`, so the rows appear one by one.
    auto content = delayedLines(sourceLines(cli), cli.delayMs);
    foreach (line; drawBoxLines(content, title, props))
    {
        writeln(line);
        stdout.flush(); // show each row as it is produced, not at program exit
    }
}

/// Content lines: a source file colorized by `bat`, or generated colored text when
/// `--file` is absent or `bat` is unavailable.
string[] sourceLines(in CliParams cli)
{
    if (cli.file.length)
    {
        import std.process : pipeProcess, ProcessException, Redirect, wait;

        try
        {
            auto p = pipeProcess(
                ["bat", "--color=always", "--style=plain", "--paging=never", cli.file],
                Redirect.stdout);
            string[] lines;
            foreach (line; p.stdout.byLineCopy)
                lines ~= line;
            if (wait(p.pid) == 0)
                return lines;
            stderr.writeln("streaming-box: `bat` exited non-zero; using generated content.");
        }
        catch (ProcessException e)
            stderr.writeln("streaming-box: could not run `bat` (is it on PATH?): ", e.msg,
                "\n  Falling back to generated content.");
    }
    return generatedColoredLines(cli.contentLength);
}

/// Words for a generated title, totalling about `targetLen` visible columns.
string[] generatedTitleWords(int targetLen)
{
    static immutable words = [
        "Streaming", "the", "drawBox", "title", "and", "content", "from", "a",
        "delayed", "range", "to", "animate", "the", "rendering", "row", "by", "row",
    ];
    string[] result;
    int total;
    size_t i;
    while (total < targetLen)
    {
        const w = words[i % $];
        result ~= w;
        total += cast(int) w.length + 1;
        ++i;
    }
    return result;
}

/// Generated colored content lines, totalling about `targetLen` visible columns.
string[] generatedColoredLines(int targetLen)
{
    static immutable Style[] palette = [
        Style.red, Style.green, Style.yellow, Style.blue, Style.magenta, Style.cyan,
    ];
    static immutable words = [
        "lorem", "ipsum", "dolor", "sit", "amet", "consectetur", "adipiscing",
        "elit", "sed", "eiusmod", "tempor", "incididunt", "labore", "magna",
    ];
    string[] lines;
    int total;
    size_t w;
    while (total < targetLen)
    {
        string line;
        foreach (k; 0 .. 8)
        {
            line ~= (k ? " " : "") ~ words[w % $].stylize(palette[w % $]);
            ++w;
        }
        lines ~= line;
        total += 60;
    }
    return lines;
}
