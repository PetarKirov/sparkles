/// Full-file VitePress comparisons, with source provenance and explicit outputs.
module comparison_examples;

import std.algorithm : startsWith, endsWith;
import std.array : array, join;
import std.exception : enforce;
import std.file : readText, exists, isSymlink;
import std.path : buildPath, absolutePath, asNormalizedPath, dirName, baseName;
import std.string : strip, lineSplitter, indexOf;

struct ComparisonExample
{
    string sourcePath;
    string expectedOutput;
    string outputFenceType;
    size_t codeStart, outputStart, outputEnd;
}

/// Concepts with native Tier-A counterparts in the two detailed D guides.
enum callbackConcepts = ["timers", "concurrency", "deadline", "tcp_echo", "file_read", "retry"];

/// Articles converted to the separate tutorial suite. Grow this list as each
/// complete article lands; deleting a marker cannot downgrade its coverage.
enum tutorialArticles = ["coming-from-nodejs.md", "coming-from-vibe-core.md"];

/// Validate suite provenance and return standalone assertion counterparts.
/// Basenames identify concepts; full resolved paths identify executable programs.
/// An article must use one suite consistently throughout its comparisons.
string[] migrationContractSources(string article, const(ComparisonExample)[] examples,
    string docsRoot)
{
    import std.algorithm : canFind;
    const root = docsRoot.absolutePath.asNormalizedPath.array.idup;
    const snippets = buildPath(root, "libs/event-horizon/tutorial/snippets");
    const tutorials = buildPath(snippets, "tutorial");
    enforce(examples.length > 0, "missing migration implementations");
    const tutorial = examples[0].sourcePath.dirName == tutorials;
    enforce(!tutorialArticles.canFind(article.baseName) || tutorial,
        "converted article must import the tutorial suite");
    string[] contracts;
    foreach (example; examples)
    {
        enforce(example.sourcePath.dirName == (tutorial ? tutorials : snippets),
            "migration implementations must use one canonical suite");
        if (tutorial)
            contracts ~= resolveComparisonSource(
                "<<< @/libs/event-horizon/tutorial/snippets/" ~ example.sourcePath.baseName
                    ~ " [contract]", root);
    }
    return contracts;
}

/// The migration series cannot pass by dropping a whole pair or its marker.
void validateMigrationComparisons(string filename, const(ComparisonExample)[] examples)
{
    import std.algorithm : canFind;
    enum concepts = ["timers", "concurrency", "deadline", "tcp_echo", "channel",
        "file_read", "exec", "spawn", "signal", "retry"];
    auto article = filename.baseName;
    string prefix;
    switch(article)
    {
    case "coming-from-nodejs.md": prefix = "node"; break;
    case "coming-from-vibe-core.md": prefix = "vibe"; break;
    case "coming-from-eventcore.md": prefix = "ec"; break;
    case "coming-from-hunt-net.md": prefix = "hunt"; break;
    case "coming-from-libasync.md": prefix = "libasync"; break;
    case "coming-from-photon.md": prefix = "photon"; break;
    case "coming-from-eve.md": prefix = "eve"; break;
    case "coming-from-collie.md": prefix = "collie"; break;
    default: enforce(false, "unknown migration article: add its coverage contract");
    }
    const detailed = prefix == "ec" || prefix == "vibe";
    enforce(examples.length == concepts.length * 2 + (detailed ? callbackConcepts.length : 0),
        "migration article requires every concept and its required implementation styles");
    string[] seen;
    for (size_t i; i < examples.length;)
    {
        enforce(i + 1 < examples.length, "incomplete comparison concept");
        auto foreignName = examples[i].sourcePath.baseName;
        auto ehName = examples[i + 1].sourcePath.baseName;
        enforce(ehName.startsWith("eh_") && ehName.endsWith(".d"), "second implementation must be event-horizon");
        auto concept = ehName[3 .. $ - 2];
        enforce(concepts.canFind(concept) && !seen.canFind(concept), "missing or duplicate migration concept");
        enforce(foreignName == prefix ~ "_" ~ concept ~ (prefix == "node" ? ".mjs" : ".d"),
            "foreign implementation must demonstrate the same concept");
        seen ~= concept;
        i += 2;
        if (detailed && callbackConcepts.canFind(concept))
        {
            enforce(i < examples.length && examples[i].sourcePath.baseName == "eh_callback_" ~ concept ~ ".d",
                "missing or mismatched event-horizon callback implementation");
            ++i;
        }
    }
}

@("comparison_examples.requiredCoverage") unittest
{
    ComparisonExample[] items;
    foreach (concept; ["timers", "concurrency", "deadline", "tcp_echo", "channel",
        "file_read", "exec", "spawn", "signal", "retry"])
    {
        items ~= ComparisonExample("node_" ~ concept ~ ".mjs");
        items ~= ComparisonExample("eh_" ~ concept ~ ".d");
    }
    validateMigrationComparisons("coming-from-nodejs.md", items);
    import std.exception : assertThrown;
    assertThrown(validateMigrationComparisons("coming-from-nodejs.md", items[0 .. $ - 2]));
    items[0].sourcePath = "node_exec.mjs";
    assertThrown(validateMigrationComparisons("coming-from-nodejs.md", items));
}

@("comparison_examples.callbackCoverage") @system unittest
{
    import std.algorithm : canFind;
    import std.exception : assertThrown;
    foreach (prefix; ["ec", "vibe"])
    {
        ComparisonExample[] items;
        foreach (concept; ["timers", "concurrency", "deadline", "tcp_echo", "channel",
            "file_read", "exec", "spawn", "signal", "retry"])
        {
            items ~= ComparisonExample(prefix ~ "_" ~ concept ~ ".d");
            items ~= ComparisonExample("eh_" ~ concept ~ ".d");
            if (callbackConcepts.canFind(concept))
                items ~= ComparisonExample("eh_callback_" ~ concept ~ ".d");
        }
        auto page = prefix == "ec" ? "coming-from-eventcore.md" : "coming-from-vibe-core.md";
        validateMigrationComparisons(page, items);
        assertThrown(validateMigrationComparisons(page, items[0 .. $ - 1]));
        items[2].sourcePath = "eh_callback_retry.d";
        assertThrown(validateMigrationComparisons(page, items));
    }
}

@("comparison_examples.threeStyles") @system unittest
{
    string resolve(string directive, string root) { return directive; }
    enum page = "<!-- verified-comparisons -->\n::: code-group\n"
        ~ "<<< @/ec_timers.d [eventcore]\n```ansi [eventcore output]\n1\n```\n"
        ~ "<<< @/eh_timers.d [event-horizon fibers]\n```ansi [event-horizon fibers output]\n2\n```\n"
        ~ "<<< @/eh_callback_timers.d [event-horizon callbacks]\n```ansi [event-horizon callbacks output]\n3\n```\n:::\n";
    auto items = extractComparisons(page, "", &resolve);
    assert(items.length == 3 && items[2].expectedOutput == "3");
    assert(items[0].outputEnd < items[1].codeStart && items[1].outputEnd < items[2].codeStart);
    import std.string : replace;
    import std.exception : assertThrown;
    assertThrown(extractComparisons(page.replace("callbacks output", "wrong output"), "", &resolve));
    assertThrown(extractComparisons(page.replace("event-horizon callbacks", "unrelated"), "", &resolve));
}

/// Only full-file imports are executable. Reject escapes, including symlinked parents.
string resolveComparisonSource(string directive, string docsRoot)
{
    auto parts = directive.strip;
    enforce(parts.startsWith("<<< @/"), "expected a docs-root snippet import");
    parts = parts[6 .. $];
    auto end = parts.indexOf(" [");
    enforce(end > 0 && parts.endsWith("]"), "snippet needs an implementation label");
    auto path = parts[0 .. end];
    enforce(path.endsWith(".d") || path.endsWith(".mjs"), "comparison needs a complete .d or .mjs file (no slices)");
    enforce(!path.startsWith("/") && path.indexOf("..") < 0 && path.indexOf('\\') < 0,
        "snippet path must stay inside docs");
    auto root = docsRoot.absolutePath.asNormalizedPath.array;
    auto resolved = buildPath(root, path);
    enforce(resolved.exists, "missing comparison source: " ~ resolved);
    for (auto p = resolved; p != root; p = p.dirName)
        enforce(!p.isSymlink, "symlinked comparison source: " ~ p);
    return resolved;
}

/// Strict pages have only paired, full-file implementations in their code groups.
/// Output indices always refer to Markdown, never to the imported source.
ComparisonExample[] extractComparisons(string content, string docsRoot,
    string delegate(string, string) resolve = null)
{
    if (resolve is null) resolve = (string line, string root) => resolveComparisonSource(line, root);
    import std.algorithm : canFind;
    bool strict;
    auto lines = content.lineSplitter.array;
    ComparisonExample[] result;
    bool group;
    bool[size_t] outputStarts;
    string[] labels;
    string fence;
    foreach (i; 0 .. lines.length)
    {
        auto line = lines[i].strip;
        if (fence.length)
        {
            if (line == fence) fence = null;
            continue;
        }
        if (lines[i].startsWith("    ") || lines[i].startsWith("\t")) continue;
        if (line.startsWith("```") || line.startsWith("~~~"))
        {
            size_t n;
            while (n < line.length && line[n] == line[0]) ++n;
            fence = line[0 .. n];
            enforce(!strict || !group || (i in outputStarts) !is null,
                "strict comparisons require source imports with their own output tabs");
            auto language = line[n .. $];
            enforce(!strict || group || !(language.startsWith("d ") || language == "d"
                || language.startsWith("js") || language.startsWith("javascript")),
                "strict implementation code must be inside its comparison group");
            continue;
        }
        if (line == "<!-- verified-comparisons -->") { strict = true; continue; }
        if (!strict) continue;
        if (line == "::: code-group")
        {
            enforce(!group, "nested comparison group");
            group = true;
            labels = null;
            continue;
        }
        if (line == ":::" && group)
        {
            const paired = labels.length == 2 && (labels.canFind("event-horizon")
                || labels.canFind("event-horizon fibers"));
            const threeStyles = labels.length == 3 && labels.canFind("event-horizon fibers")
                && labels.canFind("event-horizon callbacks");
            enforce(paired || threeStyles,
                "comparison needs one foreign implementation and the required event-horizon styles");
            group = false;
            continue;
        }
        if (!line.startsWith("<<< @/")) continue;
        if (!strict && !group) continue; // ordinary imports retain legacy behavior
        enforce(group, "comparison source must be inside a code group");
        const labelStart = line.indexOf(" [");
        enforce(labelStart > 0 && line.endsWith("]"), "missing implementation label");
        auto label = line[labelStart + 2 .. $ - 1];
        enforce(!labels.canFind(label), "duplicate implementation label");
        labels ~= label;
        size_t start = i + 1;
        while (start < lines.length && lines[start].strip.length == 0) ++start;
        const outputFence = "ansi [" ~ label ~ " output]";
        enforce(start < lines.length && lines[start].strip == "```" ~ outputFence,
            "missing labelled output for " ~ label);
        size_t end = start + 1;
        while (end < lines.length && lines[end].strip != "```") ++end;
        enforce(end < lines.length, "unterminated comparison output");
        result ~= ComparisonExample(resolve(line, docsRoot),
            lines[start + 1 .. end].join("\n"), outputFence, i, start, end);
        outputStarts[start] = true;
    }
    enforce(!strict || (!group && result.length > 0), "empty or unterminated strict comparisons");
    return result;
}

@("comparison_examples.invalidSources") unittest
{
    import std.exception : assertThrown;
    foreach (directive; ["<<< @/../outside.d [x]", "<<< @/x.d{1-4} [x]",
        "<<< @/x.cpp [x]", "<<< @/missing.d", "<<< @/missing.d [x]"])
        assertThrown(resolveComparisonSource(directive, "/tmp"));
}

@("comparison_examples.repeatedImportsAndMalformedGroups") unittest
{
    string resolve(string directive, string root) { return directive; }
    enum pair = "::: code-group\n<<< @/f.d [foreign]\n```ansi [foreign output]\na\n```\n"
        ~ "<<< @/e.d [event-horizon]\n```ansi [event-horizon output]\nb\n```\n:::\n";
    enum marker = "<!-- verified-comparisons -->\n";
    auto examples = extractComparisons(marker ~ pair ~ pair, "", &resolve);
    assert(examples.length == 4);
    assert(examples[0].sourcePath == examples[2].sourcePath);
    assert(examples[0].outputStart != examples[2].outputStart);
    import std.string : replace;
    import std.exception : assertThrown;
    assertThrown(extractComparisons(marker ~ pair.replace("::: code-group", ""), "", &resolve));
    assertThrown(extractComparisons(marker ~ pair ~ "::: code-group\n:::\n", "", &resolve));
    assertThrown(extractComparisons(marker ~ pair.replace(":::\n", ""), "", &resolve));
    assertThrown(extractComparisons(marker ~ pair.replace("::: code-group\n",
        "::: code-group\n```ansi [orphan output]\noops\n```\n"), "", &resolve));
}

@("comparison_examples.pairsAndProvenance") unittest
{
    string resolve(string directive, string root) { return root ~ directive; }
    enum page = "<!-- verified-comparisons -->\n::: code-group\n"
        ~ "<<< @/foreign.d [foreign]\n\n```ansi [foreign output]\nfirst\n```\n"
        ~ "<<< @/eh.d [event-horizon]\n```ansi [event-horizon output]\nsecond\n```\n:::\n";
    auto items = extractComparisons(page, "/docs", &resolve);
    assert(items.length == 2);
    assert(items[0].expectedOutput == "first" && items[1].expectedOutput == "second");
    assert(items[0].codeStart == 2 && items[0].outputStart == 4 && items[0].outputEnd == 6);
    assert(items[1].sourcePath == "/docs<<< @/eh.d [event-horizon]");
    import std.string : replace;
    import std.exception : assertThrown;
    assertThrown(extractComparisons(page.replace("foreign output", "wrong output"), "", &resolve));
    assertThrown(extractComparisons(page.replace("[event-horizon]", "[foreign]"), "", &resolve));
    assertThrown(extractComparisons("<!-- verified-comparisons -->", "", &resolve));
    assert(extractComparisons("````markdown\n" ~ page ~ "````", "", &resolve).length == 0);
    assert(extractComparisons("~~~markdown\n" ~ page ~ "~~~", "", &resolve).length == 0);
    assert(extractComparisons("    " ~ page.replace("\n", "\n    "), "", &resolve).length == 0);
}

@("comparison_examples.dualSuiteProvenance") @system unittest
{
    import std.file : tempDir, mkdirRecurse, write, remove, rmdirRecurse;
    import std.uuid : randomUUID;
    import std.exception : assertThrown;

    const root = buildPath(tempDir, "dual-suite-" ~ randomUUID().toString());
    const snippets = buildPath(root, "libs/event-horizon/tutorial/snippets");
    const tutorials = buildPath(snippets, "tutorial");
    mkdirRecurse(tutorials);
    scope(exit) rmdirRecurse(root);
    foreach (name; ["node_timers.mjs", "eh_timers.d"])
    {
        buildPath(snippets, name).write("contract");
        buildPath(tutorials, name).write("tutorial");
    }
    auto items = [ComparisonExample(buildPath(tutorials, "node_timers.mjs")),
        ComparisonExample(buildPath(tutorials, "eh_timers.d"))];
    auto contracts = migrationContractSources("coming-from-nodejs.md", items, root);
    assert(contracts == [buildPath(snippets, "node_timers.mjs"), buildPath(snippets, "eh_timers.d")]);
    assert(contracts[0] != items[0].sourcePath); // Same basename is not same program.
    auto mixed = items.dup;
    mixed[1].sourcePath = contracts[1];
    assertThrown(migrationContractSources("coming-from-nodejs.md", mixed, root));
    mixed[0].sourcePath = contracts[0];
    assertThrown(migrationContractSources("coming-from-nodejs.md", mixed, root)); // No downgrade.
    remove(contracts[0]);
    assertThrown(migrationContractSources("coming-from-nodejs.md", items, root));
    version (Posix)
    {
        import core.sys.posix.unistd : symlink;
        import std.string : toStringz;
        assert(symlink(items[0].sourcePath.toStringz, contracts[0].toStringz) == 0);
        assertThrown(migrationContractSources("coming-from-nodejs.md", items, root));
    }
}

@("comparison_examples.realSourceBoundary") unittest
{
    import std.file : tempDir, mkdir, write, rmdirRecurse;
    import std.uuid : randomUUID;
    import std.exception : assertThrown;
    auto root = buildPath(tempDir, "comparison-parser-" ~ randomUUID().toString());
    mkdir(root);
    scope(exit) rmdirRecurse(root);
    buildPath(root, "source.d").write("void main() {}\n");
    assert(resolveComparisonSource("<<< @/source.d [foreign]", root) == buildPath(root, "source.d"));
    version(Posix)
    {
        import std.file : symlink;
        symlink(buildPath(root, "source.d"), buildPath(root, "alias.d"));
        assertThrown(resolveComparisonSource("<<< @/alias.d [foreign]", root));
        symlink(root, buildPath(root, "alias"));
        assertThrown(resolveComparisonSource("<<< @/alias/source.d [foreign]", root));
    }
}
