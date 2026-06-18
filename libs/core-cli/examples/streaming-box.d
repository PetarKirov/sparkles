#!/usr/bin/env dub
/+ dub.sdl:
name "streaming-box"
dependency "sparkles:core-cli" path="../../.."
targetPath "build"
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

import sparkles.core_cli.args;
import sparkles.core_cli.ui.box : BoxProps, drawBoxChunks, TitleOverflow;
import sparkles.base.term_style : Style, stylize;

/// Default visible length of a generated title / content when no length is given.
enum int titleDefaultLen = 64;
enum int contentDefaultLen = 600;

struct CliParams
{
    @CliOption("w|max-width", "Box width in columns")
    int maxWidth = 80;

    @CliOption("d|delay", "Animation delay per streamed chunk, in milliseconds")
    int delayMs = 12;

    @CliOption("title", "Use this literal string as the title")
    string title;

    @CliOption("title-command", "Run this shell command; its stdout becomes the title")
    string titleCommand;

    @CliOption("content", "Use this literal string (split on newlines) as the content")
    string content;

    @CliOption("content-command", "Run this shell command; its stdout lines become the content")
    string contentCommand;

    // `--title-generate [maxLen]` and `--content-generate [maxLen]` take an *optional*
    // value, which std.getopt cannot express, so they are extracted from argv by hand
    // (see takeOptionalIntFlag) before parseCliArgs runs.
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
    import core.stdc.stdlib : exit;
    import std.string : splitLines;

    // Pull the optional-value generate flags out of argv first (getopt can't parse an
    // option whose value is optional), leaving the rest for the struct parser.
    int titleGenerateLen = titleDefaultLen;
    int contentGenerateLen = contentDefaultLen;
    const titleGenerate = takeOptionalIntFlag(args, "title-generate", titleGenerateLen);
    const contentGenerate = takeOptionalIntFlag(args, "content-generate", contentGenerateLen);

    import std.conv : to;

    const cli = args.parseCliArgs!CliParams(HelpInfo(
        "streaming-box",
        "Animated streaming drawBox demo",
        [
            // --title-generate / --content-generate take an optional value, which
            // std.getopt cannot model, so they are documented here rather than in the
            // auto-generated OPTIONS section.
            "generated sources": [
                "--title-generate [maxLen], --content-generate [maxLen]",
                "Generate the title / content instead of taking it from a literal or a"
                    ~ " command. The optional maxLen is the target visible width in columns"
                    ~ " (default " ~ titleDefaultLen.to!string ~ " for the title, "
                    ~ contentDefaultLen.to!string ~ " for the content). At most one source"
                    ~ " — literal, --*-command, or --*-generate — may be given per group;"
                    ~ " with none, that group is generated.",
            ],
        ],
    ));

    // Within each group at most one source may be chosen; the groups are independent.
    if (auto bad = conflictingSources("title", [
            tuple("--title", cli.title.length > 0),
            tuple("--title-command", cli.titleCommand.length > 0),
            tuple("--title-generate", cast(bool) titleGenerate),
        ]))
    {
        stderr.writeln(bad);
        exit(2);
    }
    if (auto bad = conflictingSources("content", [
            tuple("--content", cli.content.length > 0),
            tuple("--content-command", cli.contentCommand.length > 0),
            tuple("--content-generate", cast(bool) contentGenerate),
        ]))
    {
        stderr.writeln(bad);
        exit(2);
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

    // The title lives in the box's top border, which (under the content-only-tick
    // model) is emitted attached to the first content chunk — it can't stream in
    // word-by-word without repainting, so there's nothing to pace here. Assemble it up
    // front and let only the body stream; pacing it would just block output with a
    // blank screen for the whole title.
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

/// Extract a `--<name> [N]` optional-value flag from `args` in place. Recognises
/// `--name`, `--name=N`, and `--name N` (the bare token is consumed as the length only
/// when it is all digits, so `--name --other` leaves `--other` untouched). Returns
/// whether the flag appeared; writes the parsed length to `length` when one is given.
bool takeOptionalIntFlag(ref string[] args, string name, ref int length)
{
    import std.algorithm : all;
    import std.ascii : isDigit;
    import std.conv : to, ConvException;

    const longName = "--" ~ name;
    const eqPrefix = longName ~ "=";
    bool found;
    string[] kept;
    for (size_t i = 0; i < args.length; ++i)
    {
        const a = args[i];
        if (a == longName)
        {
            found = true;
            if (i + 1 < args.length && args[i + 1].length && args[i + 1].all!isDigit)
                length = args[++i].to!int; // consume the optional length token
            continue;
        }
        if (a.length > eqPrefix.length && a[0 .. eqPrefix.length] == eqPrefix)
        {
            found = true;
            try
                length = a[eqPrefix.length .. $].to!int;
            catch (ConvException)
            { /* malformed --name=xx: keep the default length */ }
            continue;
        }
        kept ~= a;
    }
    args = kept;
    return found;
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
