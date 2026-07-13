/++
Foreign syntax-highlighter benchmark panel for `sparkles:syntax`.

Runs the Nix-pinned foreign highlighters (bat/syntect, chroma, pygments, shiki)
over the same corpus as the in-process render benchmark and reports MB/s of
*source* highlighted, so our ANSI/HTML renderers can be placed against other
libraries on identical input.

> [!IMPORTANT]
> These are **end-to-end wall-clock** numbers: each measurement spawns the tool,
> which pays process startup + grammar/theme load + full parse + render on every
> run. That is deliberately *not* comparable to our in-process per-render `ansi`/
> `html` rows (parse-once, re-render a cached event stream). It **is** comparable
> among the foreign tools, and to our own end-to-end path (read file → parse →
> render). To amortise spawn cost the corpus is concatenated ×N to ~1.5 MB, so
> the number is dominated by highlight throughput, not `fork`/`exec`.

Tool discovery: the four tool wrappers are found in a bin directory taken from
(in order) the first CLI argument, `$SYNTAX_FOREIGN`, or `$PATH`. Build the bin
dir with `nix build .#syntax-foreign` (its `result/bin`).

Usage:

    dub run --root=libs/syntax/bench/render/foreign -- [BIN_DIR]

    # or, with the linkFarm on PATH already:
    SYNTAX_FOREIGN=$PWD/result/bin \
        dub run --root=libs/syntax/bench/render/foreign

Environment:
    SYNTAX_FOREIGN        bin dir holding bat/chroma/pygmentize/shiki-html
    SYNTAX_FOREIGN_REPS   runs timed per (tool,lang,format) cell (default 5)
    SYNTAX_FOREIGN_TARGET target concatenated input size in bytes (default 1500000)
    SYNTAX_FOREIGN_LANGS  comma list to restrict languages (default all present)
    SYNTAX_FOREIGN_JSON   output JSON path (default results/<date>-<host>-foreign.json)
+/
module app;

import std.algorithm : filter, map, sort, canFind;
import std.array : appender, array, join, replicate;
import std.conv : to;
import std.datetime.stopwatch : StopWatch, AutoStart;
import std.datetime.systime : Clock;
import std.file : exists, read, readText, mkdirRecurse, write, thisExePath;
import std.format : format;
import std.path : buildPath, dirName, baseName;
import std.process : execute, environment, Config;
import std.stdio : writeln, writefln, stderr;

// --- output formats --------------------------------------------------------

enum Format
{
    ansi,
    html,
}

string label(Format f) @safe pure nothrow
{
    return f == Format.ansi ? "ansi" : "html";
}

// --- corpus languages ------------------------------------------------------

/// A language in the corpus: a display tag and the corpus file that backs it.
/// The per-tool grammar name is looked up in `Tool.langName`; a `null` there
/// means the tool cannot highlight that language, and the cell is skipped.
struct Lang
{
    string tag; /// canonical tag, e.g. "d", "python", "typescript"
    string file; /// corpus filename under corpus/
}

immutable Lang[] langs = [
    Lang("d", "sample.d"),
    Lang("python", "sample.py"),
    Lang("typescript", "sample.ts"),
];

// --- tools -----------------------------------------------------------------

/// A foreign highlighter: which formats it can emit, how it names each corpus
/// language, and how to build its argv for a given format + input file.
struct Tool
{
    string name; /// wrapper basename in the bin dir
    Format[] formats; /// output formats this tool produces
    string[string] langName; /// corpus tag -> the tool's grammar name (absent = unsupported)
    string[] delegate(string bin, Format fmt, string lang, string file) argv;
}

Tool[] buildTools() @safe
{
    Tool[] tools;

    // bat (syntect / Sublime-syntax) — ANSI only.
    tools ~= Tool(
        "bat",
        [Format.ansi],
        ["d": "d", "python": "python", "typescript": "typescript"],
        (bin, fmt, lang, file) => [
            bin, "--language", lang, "--color=always", "--style=plain",
            "--paging=never", file
        ],
    );

    // chroma (Go) — ANSI + HTML.
    tools ~= Tool(
        "chroma",
        [Format.ansi, Format.html],
        ["d": "d", "python": "python", "typescript": "typescript"],
        (bin, fmt, lang, file) => [
            bin, "--lexer", lang, "--formatter",
            fmt == Format.ansi ? "terminal256" : "html", file
        ],
    );

    // pygmentize (Pygments) — ANSI + HTML.
    tools ~= Tool(
        "pygmentize",
        [Format.ansi, Format.html],
        ["d": "d", "python": "python", "typescript": "typescript"],
        (bin, fmt, lang, file) => [
            bin, "-l", lang, "-f",
            fmt == Format.ansi ? "terminal256" : "html", file
        ],
    );

    // shiki (TextMate / VS Code grammars) — HTML only.
    tools ~= Tool(
        "shiki-html",
        [Format.html],
        ["d": "d", "python": "python", "typescript": "typescript"],
        (bin, fmt, lang, file) => [bin, file, lang],
    );

    return tools;
}

// --- measurement -----------------------------------------------------------

struct Result
{
    string tool;
    string lang;
    string format;
    bool ok;
    string skipReason;
    size_t inputBytes;
    size_t outputBytes;
    double medianMs;
    double mbPerSec;
}

double median(double[] xs) @safe
{
    if (xs.length == 0)
        return 0;
    auto s = xs.dup;
    s.sort();
    const n = s.length;
    return n % 2 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2;
}

/// Time `argv` `reps` times (plus one warmup), returning the median wall time
/// in milliseconds and the output byte count. `ok=false` with a reason when the
/// tool exits non-zero or produces empty output (so an unsupported (tool,lang)
/// pair is skipped rather than fatal).
Result measure(string tool, string lang, Format fmt, string[] argv,
    size_t inputBytes, size_t reps)
{
    Result r;
    r.tool = tool;
    r.lang = lang;
    r.format = fmt.label;
    r.inputBytes = inputBytes;

    // Warmup — also our correctness gate: a tool that can't handle the language
    // fails here and the cell is skipped.
    auto warm = execute(argv, null, Config.none, size_t.max);
    if (warm.status != 0)
    {
        r.skipReason = format("exit %d", warm.status);
        return r;
    }
    if (warm.output.length == 0)
    {
        r.skipReason = "empty output";
        return r;
    }
    r.outputBytes = warm.output.length;

    auto samples = appender!(double[]);
    foreach (_; 0 .. reps)
    {
        auto sw = StopWatch(AutoStart.yes);
        auto res = execute(argv, null, Config.none, size_t.max);
        sw.stop();
        if (res.status != 0)
        {
            r.skipReason = format("exit %d (timed run)", res.status);
            return r;
        }
        samples ~= sw.peek.total!"usecs" / 1000.0;
    }

    r.medianMs = median(samples[]);
    r.ok = true;
    r.mbPerSec = r.medianMs > 0
        ? (cast(double) inputBytes / 1e6) / (r.medianMs / 1000.0) : 0;
    return r;
}

// --- driver ----------------------------------------------------------------

string resolveBinDir(string[] args) @safe
{
    if (args.length > 1 && args[1].length)
        return args[1];
    return environment.get("SYNTAX_FOREIGN", "");
}

/// Locate a tool: prefer `binDir/name`, else rely on `$PATH` (return the bare
/// name and let `execute` resolve it), else empty if truly absent.
string toolPath(string binDir, string name) @safe
{
    if (binDir.length)
    {
        const p = buildPath(binDir, name);
        if (p.exists)
            return p;
    }
    return name; // let execute() search $PATH
}

/// Build the ~target-byte concatenated input for a corpus file, written to a
/// temp path, and return (path, byteCount, reps).
struct Blown
{
    string path;
    size_t bytes;
    size_t reps;
}

Blown blowUp(string corpusFile, string tmpDir, size_t target)
{
    const src = readText(corpusFile);
    size_t reps = src.length ? (target + src.length - 1) / src.length : 1;
    if (reps < 1)
        reps = 1;
    // Join with a blank line so tokens from adjacent copies never fuse.
    const unit = src ~ "\n\n";
    auto buf = appender!string;
    foreach (_; 0 .. reps)
        buf ~= unit;
    const outPath = buildPath(tmpDir, "blown-" ~ corpusFile.baseName);
    write(outPath, buf[]);
    return Blown(outPath, buf[].length, reps);
}

int main(string[] args)
{
    // corpus/ sits next to foreign/ under bench/render/. Resolve relative to
    // this file's build layout: the exe lives in foreign/build/, corpus in
    // foreign/../corpus.
    const foreignDir = thisExePath.dirName.dirName; // .../foreign
    const corpusDir = buildPath(foreignDir.dirName, "corpus");
    if (!corpusDir.exists)
    {
        stderr.writefln("corpus dir not found: %s", corpusDir);
        return 1;
    }

    const binDir = resolveBinDir(args);
    if (binDir.length)
        writefln("# foreign tools bin dir: %s", binDir);
    else
        writeln("# no SYNTAX_FOREIGN / argv bin dir — resolving tools on $PATH");

    const reps = environment.get("SYNTAX_FOREIGN_REPS", "5").to!size_t;
    const target = environment.get("SYNTAX_FOREIGN_TARGET", "1500000").to!size_t;

    string[] langFilter;
    if (auto lf = environment.get("SYNTAX_FOREIGN_LANGS", ""))
        langFilter = lf.split(',');

    // Scratch dir for the blown-up inputs.
    const tmpDir = buildPath(environment.get("TMPDIR", "/tmp"),
        "syntax-foreign-" ~ Clock.currTime.toUnixTime.to!string);
    mkdirRecurse(tmpDir);

    auto tools = buildTools();

    // Pre-build blown-up input per present corpus language.
    Blown[string] blown;
    foreach (const ref l; langs)
    {
        if (langFilter.length && !langFilter.canFind(l.tag))
            continue;
        const cf = buildPath(corpusDir, l.file);
        if (!cf.exists)
        {
            stderr.writefln("# skip lang %s — no corpus file %s", l.tag, l.file);
            continue;
        }
        blown[l.tag] = blowUp(cf, tmpDir, target);
    }

    Result[] results;
    foreach (ref t; tools)
    {
        const bin = toolPath(binDir, t.name);
        foreach (const ref l; langs)
        {
            auto b = l.tag in blown;
            if (b is null)
                continue;
            auto gn = l.tag in t.langName;
            foreach (fmt; t.formats)
            {
                if (gn is null)
                {
                    results ~= Result(t.name, l.tag, fmt.label, false,
                        "no grammar", b.bytes, 0, 0, 0);
                    continue;
                }
                auto argv = t.argv(bin, fmt, *gn, b.path);
                results ~= measure(t.name, l.tag, fmt, argv, b.bytes, reps);
            }
        }
    }

    printTable(results, reps, target);
    const jsonPath = writeJson(results, foreignDir, reps, target);
    writefln("\n# JSON snapshot: %s", jsonPath);
    return 0;
}

string[] split(string s, char sep) @safe pure
{
    import std.algorithm : splitter;

    return s.length ? s.splitter(sep).array : null;
}

// --- reporting -------------------------------------------------------------

void printTable(Result[] results, size_t reps, size_t target)
{
    writefln("\n# Foreign syntax-highlighter panel — end-to-end wall clock");
    writefln("# (spawn + parse + render per run; input ~%.1f MB; median of %d runs)",
        target / 1e6, reps);
    writefln("# NOT comparable to our in-process per-render rows — comparable among these.\n");

    writefln("%-12s %-11s %-6s %10s %10s %12s", "tool", "lang", "fmt",
        "MB/s", "med ms", "out KB");
    writefln("%-12s %-11s %-6s %10s %10s %12s", "----", "----", "---",
        "----", "------", "------");

    foreach (const ref r; results)
    {
        if (r.ok)
            writefln("%-12s %-11s %-6s %10.1f %10.2f %12.1f",
                r.tool, r.lang, r.format, r.mbPerSec, r.medianMs,
                r.outputBytes / 1024.0);
        else
            writefln("%-12s %-11s %-6s %10s %10s %12s   (%s)",
                r.tool, r.lang, r.format, "-", "-", "-", r.skipReason);
    }
}

string writeJson(Result[] results, string foreignDir, size_t reps, size_t target)
{
    import std.datetime.systime : SysTime;

    const now = Clock.currTime;
    const date = format("%04d-%02d-%02d", now.year, cast(int) now.month, now.day);
    const host = environment.get("HOSTNAME", environment.get("HOST", "host"));

    string jsonPath = environment.get("SYNTAX_FOREIGN_JSON", "");
    if (jsonPath.length == 0)
    {
        const resultsDir = buildPath(foreignDir, "results");
        mkdirRecurse(resultsDir);
        jsonPath = buildPath(resultsDir, format("%s-%s-foreign.json", date, host));
    }
    else
        mkdirRecurse(jsonPath.dirName);

    auto j = appender!string;
    j ~= "{\n";
    j ~= format("  \"schema\": \"syntax-foreign/1\",\n");
    j ~= format("  \"date\": \"%s\",\n", date);
    j ~= format("  \"host\": %s,\n", jstr(host));
    j ~= format("  \"reps\": %d,\n", reps);
    j ~= format("  \"targetBytes\": %d,\n", target);
    j ~= "  \"note\": \"end-to-end wall clock (spawn+parse+render); comparable among these tools, not to in-process rows\",\n";
    j ~= "  \"results\": [\n";
    foreach (i, const ref r; results)
    {
        j ~= "    {";
        j ~= format("\"tool\": %s, \"lang\": %s, \"format\": %s, \"ok\": %s, ",
            jstr(r.tool), jstr(r.lang), jstr(r.format), r.ok ? "true" : "false");
        j ~= format("\"inputBytes\": %d, \"outputBytes\": %d, \"medianMs\": %.4f, \"mbPerSec\": %.4f",
            r.inputBytes, r.outputBytes, r.medianMs, r.mbPerSec);
        if (!r.ok)
            j ~= format(", \"skip\": %s", jstr(r.skipReason));
        j ~= i + 1 < results.length ? "},\n" : "}\n";
    }
    j ~= "  ]\n}\n";
    write(jsonPath, j[]);
    return jsonPath;
}

string jstr(string s) @safe pure
{
    auto o = appender!string;
    o ~= '"';
    foreach (char c; s)
    {
        switch (c)
        {
        case '"':
            o ~= "\\\"";
            break;
        case '\\':
            o ~= "\\\\";
            break;
        case '\n':
            o ~= "\\n";
            break;
        default:
            o ~= c;
        }
    }
    o ~= '"';
    return o[];
}
