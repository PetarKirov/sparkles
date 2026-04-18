import core.time : MonoTime;

import std.algorithm.iteration : filter;
import std.array : array;
import std.conv : to;
import std.digest : toHexString;
import std.digest.sha : sha256Of;
import std.file : SpanMode, dirEntries, exists, mkdirRecurse, readText, write;
import std.path : baseName, buildPath, dirName, extension;
import std.stdio : stderr, writeln;

import sparkles.markdown : ParseResult, parse, toHtml;

int main(string[] args)
{
    auto corporaDir = args.length > 1
        ? args[1]
        : buildPath("libs", "markdown", "bench", "corpora");
    auto resultsPath = args.length > 2
        ? args[2]
        : buildPath("libs", "markdown", "bench", "results", "sparkles.jsonl");

    if (!exists(corporaDir))
    {
        stderr.writeln("Benchmark corpora directory not found: ", corporaDir);
        return 2;
    }

    auto entries = dirEntries(corporaDir, SpanMode.shallow)
        .filter!(e => !e.isDir && extension(e.name) == ".md")
        .array;

    if (entries.length == 0)
    {
        stderr.writeln("No .md workloads found in ", corporaDir);
        return 2;
    }

    auto resultDir = dirName(resultsPath);
    if (resultDir.length > 0)
        mkdirRecurse(resultDir);

    string outv;

    foreach (entry; entries)
    {
        auto markdown = readText(entry.name);

        auto started = MonoTime.currTime;
        ParseResult parsed = parse(markdown);
        auto html = parsed.toHtml();
        auto elapsed = MonoTime.currTime - started;

        auto hash = sha256Of(cast(const(ubyte)[]) html);

        outv ~= "{" ~
            "\"parser\":\"sparkles\"," ~
            "\"workload\":\"" ~ baseName(entry.name) ~ "\"," ~
            "\"iteration\":1," ~
            "\"wall_ns\":" ~ elapsed.total!"nsecs".to!string ~ "," ~
            "\"user_ns\":0," ~
            "\"sys_ns\":0," ~
            "\"peak_rss_bytes\":0," ~
            "\"output_hash\":\"sha256:" ~ toHexString(hash) ~ "\"" ~
            "}\n";
    }

    write(resultsPath, outv);
    writeln("bench: wrote ", entries.length, " benchmark rows to ", resultsPath);

    return 0;
}
