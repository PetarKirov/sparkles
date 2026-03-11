#!/usr/bin/env dub
/+ dub.sdl:
    name "dedup_md_reference_links"
+/

import std.algorithm : any, canFind, filter, map, sort;
import std.array : array, join;
import std.file : exists, readText, write;
import std.getopt : getopt;
import std.process : execute;
import std.regex : ctRegex, matchFirst;
import std.stdio : stderr, writeln;
import std.string : endsWith, lineSplitter, replace, toLower;

struct CliOptions
{
    bool fix;
    bool help;
}

struct ReferenceDef
{
    size_t lineIndex;
    string label;
    string url;
}

struct DuplicateGroup
{
    string filePath;
    string canonicalLabel;
    string url;
    ReferenceDef[] defs;
}

private __gshared immutable refDefRegex = ctRegex!(r"^\[([^\]]+)\]:\s+(https?://\S+)");

int main(string[] args)
{
    CliOptions cli;

    getopt(
        args,
        "fix", &cli.fix,
        "help|h", &cli.help,
    );

    if (cli.help)
    {
        writeln("Find duplicate markdown reference definitions that point to the same URL.");
        writeln("Usage: dedup_md_reference_links.d [--fix] [--help] [path ...]");
        writeln("  --fix   Rewrite files to one canonical label per duplicate URL");
        writeln("  --help  Show this help");
        return 0;
    }

    auto mdFiles = selectedMarkdownFiles(args);
    auto duplicateGroups = collectDuplicateGroups(mdFiles);

    if (duplicateGroups.length == 0)
    {
        writeln("No duplicate markdown reference URLs found.");
        return 0;
    }

    printDuplicateGroups(duplicateGroups);

    if (!cli.fix)
        return 1;

    auto changedFiles = fixDuplicateGroups(mdFiles, duplicateGroups);

    writeln();
    writeln("Updated ", changedFiles.length, " file(s).");
    foreach (filePath; changedFiles)
        writeln("  ", filePath);

    return 0;
}

string[] trackedMarkdownFiles()
{
    const result = execute(["git", "ls-files", "--", "*.md"]);
    if (result.status != 0)
    {
        stderr.writeln("Failed to enumerate markdown files with git ls-files.");
        stderr.writeln(result.output);
        return [];
    }

    return result.output
        .lineSplitter
        .filter!(line => line.length != 0)
        .map!(line => line.idup)
        .array;
}

string[] selectedMarkdownFiles(string[] args)
{
    if (args.length <= 1)
        return trackedMarkdownFiles();

    return args[1 .. $]
        .filter!(path => path.length != 0)
        .filter!(path => path.endsWith(".md"))
        .filter!(path => exists(path))
        .map!(path => path.idup)
        .array;
}

DuplicateGroup[] collectDuplicateGroups(string[] mdFiles)
{
    DuplicateGroup[] groups;

    foreach (filePath; mdFiles)
    {
        auto refsByUrl = parseReferenceDefs(filePath);

        foreach (url, defs; refsByUrl)
        {
            if (defs.length < 2)
                continue;

            const canonical = chooseCanonicalLabel(defs);

            groups ~= DuplicateGroup(
                filePath,
                canonical,
                url,
                defs.sort!((a, b) => a.lineIndex < b.lineIndex).array,
            );
        }
    }

    groups.sort!((a, b)
        => a.filePath < b.filePath
        || (a.filePath == b.filePath && a.url < b.url)
    );
    return groups;
}

ReferenceDef[][string] parseReferenceDefs(string filePath)
{
    ReferenceDef[][string] refsByUrl;

    const lines = readText(filePath).lineSplitter.array;

    foreach (lineIndex, line; lines)
    {
        auto match = matchFirst(line, refDefRegex);
        if (match.empty)
            continue;

        auto label = match.captures[1].idup;
        auto url = match.captures[2].idup;

        refsByUrl[url] ~= ReferenceDef(lineIndex, label, url);
    }

    return refsByUrl;
}

string chooseCanonicalLabel(ReferenceDef[] defs)
{
    auto best = defs[0].label;
    auto bestScore = labelScore(best);

    foreach (def; defs[1 .. $])
    {
        const score = labelScore(def.label);
        const shouldReplace = score > bestScore;

        if (shouldReplace)
        {
            best = def.label;
            bestScore = score;
        }
    }

    return best;
}

int labelScore(string label)
{
    int score = 0;

    if (label.canFind(" "))
        score += 40;

    if (label.any!(c => c >= 'A' && c <= 'Z'))
        score += 10;

    if (containsKeyword(label))
        score += 15;

    if (isUrlishLabel(label))
        score -= 60;

    if (label.canFind("-hackage") || label.canFind("-website") || label.canFind("-docs"))
        score -= 10;

    return score;
}

bool containsKeyword(string label)
{
    static immutable keywords = [
        "repository",
        "documentation",
        "announcement",
        "website",
        "release",
        "hackage",
        "book",
        "api",
        "guide",
        "proposal",
    ];

    const lower = label.toLower;
    return keywords.any!(kw => lower.canFind(kw));
}

bool isUrlishLabel(string label)
{
    if (label.canFind("/") || label.canFind("://"))
        return true;

    if (!label.canFind(" ") && label.canFind("."))
        return true;

    return false;
}

void printDuplicateGroups(DuplicateGroup[] groups)
{
    writeln("Duplicate markdown reference URLs found:");

    foreach (group; groups)
    {
        writeln();
        writeln(group.filePath, ":");
        writeln("  canonical: [", group.canonicalLabel, "]");
        writeln("  url: ", group.url);

        foreach (def; group.defs)
            writeln("    - [", def.label, "] @ line ", def.lineIndex + 1);
    }
}

string[] fixDuplicateGroups(string[] mdFiles, DuplicateGroup[] groups)
{
    DuplicateGroup[][string] groupsByFile;
    foreach (group; groups)
        groupsByFile[group.filePath] ~= group;

    string[] changedFiles;

    foreach (filePath; mdFiles)
    {
        if (filePath !in groupsByFile)
            continue;

        const originalText = readText(filePath);
        auto lines = originalText.lineSplitter.array;
        bool hadTrailingNewline = originalText.length > 0 && originalText[$ - 1] == '\n';

        bool[] removeLine = new bool[](lines.length);
        string[string] replacementByLabel;

        foreach (group; groupsByFile[filePath])
        {
            foreach (def; group.defs)
            {
                if (def.label == group.canonicalLabel)
                    continue;

                removeLine[def.lineIndex] = true;
                replacementByLabel[def.label] = group.canonicalLabel;
            }
        }

        auto oldLabels = replacementByLabel.keys.array;
        oldLabels.sort!((a, b) => a.length > b.length);
        string[] outputLines;

        foreach (lineIndex, originalLine; lines)
        {
            if (removeLine[lineIndex])
                continue;

            auto line = originalLine.idup;
            foreach (oldLabel; oldLabels)
                line = line.replace("[" ~ oldLabel ~ "]", "[" ~ replacementByLabel[oldLabel] ~ "]");

            if (line.length >= 4 && line[0 .. 4] == "- [")
            {
                if (outputLines.length > 0 && outputLines[$ - 1] == line)
                    continue;
            }

            outputLines ~= line;
        }

        auto rewritten = outputLines.join("\n");
        if (hadTrailingNewline)
            rewritten ~= "\n";

        write(filePath, rewritten);
        changedFiles ~= filePath;
    }

    return changedFiles;
}
