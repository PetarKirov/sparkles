#!/usr/bin/env dub
/+ dub.sdl:
name "streaming-box"
dependency "sparkles:core-cli" path="../../.."
targetPath "build"
+/

module streaming_box_example;

// Animated `drawBox`: the box is rendered as a lazy range of *chunks* whose `popFront`
// sleeps, so iterating `drawBoxChunks!(lineBuffered: false)` reveals the box cell by
// cell — text appears word by word inside the frame, like tokens typed by an LLM —
// while the frame draws in place and the bottom border lands once the content ends.
// The content showcases colour by listing a source file through `bat` (`--file`), or —
// with no file — generated colour so the demo always runs.
//
//   dub run --single streaming-box.d -- --max-width 72 --delay 12
//   dub run --single streaming-box.d -- --file path/to/src.d --max-width 96 --delay 6

import core.thread : Thread;
import core.time : dur;
import std.range.primitives : ElementType, empty, front, popFront;
import std.stdio : stderr, stdout, write, writeln;

import sparkles.core_cli.args;
import sparkles.core_cli.ui.box : BoxProps, drawBoxChunks, TitleOverflow;
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

    @CliOption("d|delay", "Animation delay per streamed chunk, in milliseconds")
    int delayMs = 12;
}

/// A forward range that sleeps on each `popFront`, so consuming it animates output.
/// Granularity-agnostic: it paces whatever range it wraps — title words, or the box's
/// cell-granular output chunks.
struct DelayedRange(R)
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

auto delayedRange(R)(R src, int delayMs) => DelayedRange!R(src, delayMs);

void main(string[] args)
{
    const cli = args.parseCliArgs!CliParams(
        HelpInfo("streaming-box", "Animated streaming drawBox demo"));

    // Compose the title first (DelayedRange paces the words too), so the box's top
    // border is ready before the content streams in.
    string title;
    foreach (word; delayedRange(generatedTitleWords(cli.titleLength), cli.delayMs))
        title ~= (title.length ? " " : "") ~ word;

    // A fixed-width box so the top can be drawn before any content arrives and the
    // content can stream in; `wrap` shows the nested title box for a long title.
    const props = BoxProps(
        minWidth: cli.maxWidth,
        maxWidth: cli.maxWidth,
        titleOverflow: TitleOverflow.wrap,
    );

    // Pace the box's cell-granular output: each chunk is a word/segment (the frame
    // pieces ride along for free), so the box reveals itself token by token. `write`
    // (not `writeln`) — the chunks already carry their own newlines.
    auto content = sourceLines(cli);
    foreach (chunk; drawBoxChunks!false(content, title, props)
            .delayedRange(cli.delayMs))
    {
        write(chunk);
        stdout.flush(); // show each chunk as it is produced, not at program exit
    }
    writeln();
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
