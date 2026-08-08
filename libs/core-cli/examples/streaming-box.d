#!/usr/bin/env dub
/+ dub.sdl:
name "streaming-box"
dependency "sparkles:core-cli" path="../../.."
targetPath "build"
    // Optimised, assertions live, `debug {}` blocks out — the build every nix
    // artifact uses. Neither `debug` (which compiles those blocks in) nor
    // `release` (which deletes assert *expressions*, side effects included).
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/

module streaming_box_example;

// Animated `drawBox`: the box is rendered as a lazy range of *chunks* whose `popFront`
// sleeps, so iterating `drawBoxChunks!false` reveals the box cell by cell — text
// appears word by word inside the frame, like tokens typed by an LLM — while the frame
// draws in place and the bottom border lands once the content ends.
//
// The title and the content each come from one of three mutually-exclusive sources
// (the two groups are independent — mix freely):
//
//   * literal          --title 'The title'         --content 'a line'
//   * shell command    --title-command 'cmd'       --content-command 'seq 1 1000'
//   * generated        --title-generate [maxLen]    --content-generate [maxLen]
//
// With nothing chosen for a group, that group is generated, so the demo always runs.
//
//   dub run --single streaming-box.d -- --max-width 72 --delay 12
//   dub run --single streaming-box.d -- --content-command 'seq 1 40' --max-width 96
//   dub run --single streaming-box.d -- --title 'Logs' --content-command 'bat --color=always app.d'
//   dub run --single streaming-box.d -- --title-generate 30 --content-generate 200

import core.thread : Thread;
import core.time : dur;
import std.range.primitives : ElementType, empty, front, popFront;
import std.stdio : stderr, stdout, write, writeln;

import sparkles.core_cli.args : HelpInfo, Option, parseCli, reportCliError;
import sparkles.ui.components.box : BoxProps, drawBoxChunks, TitleOverflow;
import sparkles.base.term_style : Style, stylize;

/// Default visible length of a generated title / content when no length is given.
enum int titleDefaultLen = 64;
enum int contentDefaultLen = 600;

struct CliParams
{
    @(Option("w|max-width", description: "Box width in columns"))
    int maxWidth = 80;

    @(Option("d|delay", description: "Animation delay per streamed chunk, in milliseconds"))
    int delayMs = 12;

    @(Option("title", description: "Use this literal string as the title"))
    string title;

    @(Option("title-command", description: "Run this shell command; its stdout becomes the title"))
    string titleCommand;

    @(Option("content", description: "Use this literal string (split on newlines) as the content"))
    string content;

    @(Option("content-command", description: "Run this shell command; its stdout lines become the content"))
    string contentCommand;

    // `--title-generate [maxLen]` and `--content-generate [maxLen]` take an *optional*
    // value — the shape `counter: true` gives an integral option: a bare `--flag`
    // increments the field, while `--flag N` / `--flag=N` assign N. So 0 means "not
    // given", 1 means "given, no length" (the sentinel a bare flag leaves behind), and
    // anything larger is the requested length; see `generateLen`.
    @(Option("title-generate", counter: true, description: "Generate the title; the optional value is its target visible width in columns"))
    int titleGenerate;

    @(Option("content-generate", counter: true, description: "Generate the content; the optional value is its target visible width in columns"))
    int contentGenerate;
}

/// Decode a `[maxLen]` counter flag: 0 = the flag was absent, 1 = it was given bare
/// (use `dflt`), anything else is the length the user asked for.
int generateLen(int flag, int dflt) => flag > 1 ? flag : dflt;

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

int main(string[] args)
{
    import std.conv : to;
    import std.string : splitLines;

    auto parsed = parseCli!CliParams(args, HelpInfo(
        "streaming-box",
        "Animated streaming drawBox demo",
        [
            // The per-option help above says what each flag does; this says how the
            // three sources of a group relate to each other.
            "generated sources": [
                "--title-generate [maxLen], --content-generate [maxLen]",
                "Generate the title / content instead of taking it from a literal or a"
                    ~ " command. The value is optional; omitted, the target visible width"
                    ~ " is " ~ titleDefaultLen.to!string ~ " columns for the title and "
                    ~ contentDefaultLen.to!string ~ " for the content. At most one source"
                    ~ " — literal, --*-command, or --*-generate — may be given per group;"
                    ~ " with none, that group is generated.",
            ],
        ],
    ));
    if (!parsed)
        return reportCliError(parsed.error);
    const cli = parsed.value;

    const titleGenerateLen = generateLen(cli.titleGenerate, titleDefaultLen);
    const contentGenerateLen = generateLen(cli.contentGenerate, contentDefaultLen);

    // Within each group at most one source may be chosen; the groups are independent.
    if (auto bad = conflictingSources("title", [
            tuple("--title", cli.title.length > 0),
            tuple("--title-command", cli.titleCommand.length > 0),
            tuple("--title-generate", cli.titleGenerate > 0),
        ]))
    {
        stderr.writeln(bad);
        return 2;
    }
    if (auto bad = conflictingSources("content", [
            tuple("--content", cli.content.length > 0),
            tuple("--content-command", cli.contentCommand.length > 0),
            tuple("--content-generate", cli.contentGenerate > 0),
        ]))
    {
        stderr.writeln(bad);
        return 2;
    }

    // Resolve each group: literal → command → generated (the default when none chosen).
    const fullTitle =
        cli.title.length ? cli.title
        : cli.titleCommand.length ? runCommandTitle(cli.titleCommand)
        : generatedTitle(titleGenerateLen);

    string[] content =
        cli.content.length ? cli.content.splitLines
        : cli.contentCommand.length ? runCommandLines(cli.contentCommand)
        : generatedColoredLines(contentGenerateLen);

    // Assemble the full title up front; `drawBoxChunks` streams it word-by-word on the
    // top border itself (the title is the first row of the chunk stream), so there's
    // nothing to pace here — pacing the box's output animates the title and the body
    // alike.
    const title = fullTitle;

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
    foreach (chunk; drawBoxChunks!false(content, title, props)
            .delayedRange(cli.delayMs))
    {
        write(chunk);
        stdout.flush(); // show each chunk as it is produced, not at program exit
    }
    writeln();

    return 0;
}

import std.typecons : tuple, Tuple;

/// Validate that at most one source in a group was selected. Returns an error message
/// (the conflicting flags) when two or more are set, else `null`.
string conflictingSources(string group, Tuple!(string, bool)[] sources)
{
    import std.algorithm : filter, map;
    import std.array : array, join;

    auto chosen = sources.filter!(s => s[1]).map!(s => s[0]).array;
    if (chosen.length <= 1)
        return null;
    return "streaming-box: " ~ chosen.join(", ") ~ " are mutually exclusive ("
        ~ group ~ " has only one source)";
}

/// Run `cmd` in a shell and use its stdout (joined to one line) as the title. Falls
/// back to a generated title if the command fails or produces nothing.
string runCommandTitle(string cmd)
{
    import std.array : join;
    import std.string : strip;

    auto lines = runShell(cmd);
    auto title = lines.join(" ").strip;
    return title.length ? title : generatedTitle(titleDefaultLen);
}

/// Run `cmd` in a shell and use its stdout lines as the content. Falls back to
/// generated colored content if the command fails or produces nothing.
string[] runCommandLines(string cmd)
{
    auto lines = runShell(cmd);
    return lines.length ? lines : generatedColoredLines(contentDefaultLen);
}

/// Run a shell command and capture its stdout as lines (terminators stripped). On a
/// non-zero exit or a spawn failure, warn on stderr and return an empty array so the
/// caller can fall back to generated output.
string[] runShell(string cmd)
{
    import std.process : pipeShell, ProcessException, Redirect, wait;

    try
    {
        auto p = pipeShell(cmd, Redirect.stdout);
        string[] lines;
        foreach (line; p.stdout.byLineCopy)
            lines ~= line;
        if (wait(p.pid) == 0)
            return lines;
        stderr.writeln("streaming-box: command exited non-zero: ", cmd,
            "\n  Falling back to generated output.");
    }
    catch (ProcessException e)
        stderr.writeln("streaming-box: could not run command (", cmd, "): ", e.msg,
            "\n  Falling back to generated output.");
    return null;
}

/// A generated title of about `targetLen` visible columns.
string generatedTitle(int targetLen)
{
    import std.array : join;
    return generatedTitleWords(targetLen).join(" ");
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
