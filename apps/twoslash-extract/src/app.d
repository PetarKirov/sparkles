/// The batch D twoslash extractor (`docs/specs/dmd-lsp/`, `EXT1`–`EXT4`):
/// runs the `sparkles:twoslash-d` pipeline over an annotated D sample and
/// writes the `.twoslash.json` payload `apps/hue` renders.
///
/// One semantic analysis per process (`EXT2`): DMD-as-a-library is one big
/// global, so a directory target re-executes this binary once per file
/// instead of looping in-process.
module app;

import std.stdio : stderr, writeln;

import sparkles.core_cli.args : CliOption, HelpInfo, parseCliArgs;

import sparkles.dmd_lsp.api : AnalyzerConfig;

struct CliParams
{
    @CliOption("out", "Output path for a file target, or output directory for a directory target; defaults to `<input-minus-.d>.twoslash.json` beside each input.")
    string outPath;

    @CliOption("import", "Source import path for the analysis (repeatable); prepended to `$SPARKLES_DMD_IMPORT_PATH` and the sample's own `// @import:` directives.")
    string[] importPaths;

    @CliOption("dflags", "Extra compiler flags (space-separated), merged with the sample's `// @dflags:` directives.")
    string dflags;

    @CliOption("dub", "Analyze the input in the context of its enclosing dub project: `dub describe` supplies the import paths, string-import paths, version identifiers and dflags of the nearest dub.sdl/dub.json. Off by default, so a standalone sample is never influenced by a project that happens to contain it.")
    bool dub;

    @CliOption("dub-config", "With --dub: the dub configuration to describe (default: dub's own default configuration).")
    string dubConfig;

    @CliOption("dub-build", "With --dub: the dub build type to describe, e.g. unittest (default: dub's own default, debug).")
    string dubBuild;

    @CliOption("verify", "Re-extract and diff against the existing payload instead of writing; exit 1 on drift (the golden-fixture guard).")
    bool verify;

    @CliOption("quiet", "Suppress per-file progress output.")
    bool quiet;
}

int main(string[] args)
{
    auto argv = args;
    const cli = argv.parseCliArgs!CliParams(
        HelpInfo(
            "twoslash-extract",
            "Extract a twoslash node payload (types, queries, diagnostics, docs) " ~
            "from an annotated D sample (or a directory of samples) via DMD-as-a-library.",
            null
        )
    );

    if (argv.length < 2)
    {
        stderr.writeln("error: no input given (a .d sample or a directory); see --help");
        return 2;
    }
    const target = argv[1];

    import std.file : exists, isDir;

    if (!target.exists)
    {
        stderr.writeln("error: no such file or directory: ", target);
        return 2;
    }

    return target.isDir ? runDirectory(cli, target) : runFile(cli, target, cli.outPath);
}

/// Directory target: one child process per sample (`EXT2`) — the analysis
/// core must never be reused within a process.
private int runDirectory(in CliParams cli, string dir)
{
    import std.algorithm.iteration : filter;
    import std.algorithm.searching : endsWith;
    import std.algorithm.sorting : sort;
    import std.array : array;
    import std.file : dirEntries, SpanMode, thisExePath;
    import std.path : baseName, buildPath, setExtension;
    import std.process : execute;

    auto samples = dirEntries(dir, SpanMode.shallow)
        .filter!(e => e.isFile && e.name.endsWith(".d"))
        .filter!(e => !e.name.baseName.startsWithDot)
        .array;
    samples.sort!((a, b) => a.name < b.name);
    if (!samples.length)
    {
        stderr.writeln("error: no .d samples in ", dir);
        return 2;
    }

    int rc = 0;
    foreach (sample; samples)
    {
        string[] child = [thisExePath, sample.name];
        if (cli.outPath.length)
            child ~= ["--out", buildPath(cli.outPath,
                sample.name.baseName.setExtension("twoslash.json"))];
        foreach (p; cli.importPaths)
            child ~= ["--import", p];
        if (cli.dflags.length)
            child ~= ["--dflags", cli.dflags];
        if (cli.dub)
            child ~= "--dub";
        if (cli.dubConfig.length)
            child ~= ["--dub-config", cli.dubConfig];
        if (cli.dubBuild.length)
            child ~= ["--dub-build", cli.dubBuild];
        if (cli.verify)
            child ~= "--verify";
        if (cli.quiet)
            child ~= "--quiet";

        const r = execute(child);
        if (r.output.length)
            stderr.write(r.output);
        if (r.status != 0)
            rc = r.status;
    }
    return rc;
}

private bool startsWithDot(scope const(char)[] name) @safe pure nothrow @nogc
    => name.length && name[0] == '.';

private int runFile(in CliParams cli, string samplePath, string outPath)
{
    import std.algorithm.iteration : filter, splitter;
    import std.array : array;
    import std.file : readText;
    import std.path : setExtension;

    import sparkles.twoslash_d.analyze : analyzeTwoslash;
    import sparkles.twoslash_d.emit : declareDPayload;

    if (!outPath.length)
        outPath = samplePath.setExtension("twoslash.json");

    const source = readText(samplePath);
    auto config = AnalyzerConfig(
        importPaths: cli.importPaths.dup,
        dflags: cli.dflags.splitter(' ').filter!(f => f.length).array);

    // `--dub` (PRJ5): the enclosing project's settings, appended behind any
    // explicit `--import`/`--dflags` so those keep priority.
    if (cli.dub && !applyDubContext(cli, samplePath, config))
        return 1;

    // `--import` prepends to the environment default rather than replacing it.
    if (config.importPaths.length)
        config.importPaths ~= AnalyzerConfig().effectiveImportPaths;

    auto result = analyzeTwoslash(samplePath, source, config);
    foreach (w; result.warnings)
        stderr.writeln("warning: ", samplePath, ": ", w);

    declareDPayload(result.payload);

    return cli.verify
        ? verifyPayload(cli, samplePath, outPath, result.payload)
        : writePayload(cli, samplePath, outPath, result.payload);
}

/**
Folds the enclosing dub project's build settings into `config` (`PRJ5`).

Project settings are $(I appended): an explicit `--import`/`--dflags` stays
ahead of them in the search order, and the environment's druntime/phobos tail
is appended after both by the caller. Returns false when `--dub` was asked for
but cannot be honored — a silent fallback would produce a payload full of
"undefined identifier" nodes that looks like a source defect.
*/
private bool applyDubContext(in CliParams cli, string samplePath,
    ref AnalyzerConfig config)
{
    import sparkles.dmd_lsp.project : DubQuery, dubProjectFor;

    const proj = dubProjectFor(samplePath,
        DubQuery(config: cli.dubConfig, buildType: cli.dubBuild));

    if (!proj.found)
    {
        stderr.writeln("error: --dub: no dub.sdl/dub.json above ", samplePath);
        return false;
    }
    if (!proj.usable)
    {
        stderr.writeln("error: --dub: ", proj.error);
        return false;
    }

    config.importPaths ~= proj.analyzer.importPaths;
    config.stringImportPaths ~= proj.analyzer.stringImportPaths;
    config.versionIds ~= proj.analyzer.versionIds;
    config.debugIds ~= proj.analyzer.debugIds;
    config.dflags ~= proj.analyzer.dflags;

    if (!cli.quiet)
        writeln("dub project ", proj.root, ": ",
            proj.analyzer.importPaths.length, " import paths, ",
            proj.analyzer.versionIds.length, " versions, ",
            proj.analyzer.dflags.length, " dflags");
    return true;
}

private int writePayload(P)(in CliParams cli, string samplePath, string outPath, P payload)
{
    import sparkles.twoslash_d.emit : writeTwoslashFile;

    auto written = writeTwoslashFile(payload, outPath);
    if (written.hasError)
    {
        stderr.writeln("error: ", outPath, ": ", written.error.toString());
        return 1;
    }
    if (!cli.quiet)
        writeln(samplePath, " -> ", outPath, " (", payload.nodes.length, " nodes)");
    return 0;
}

/// `--verify` (`EXT3`): the payload on disk must match a fresh extraction.
private int verifyPayload(P)(in CliParams cli, string samplePath, string outPath, P payload)
{
    import std.file : exists, readText;

    import sparkles.wired.json : toJSON;

    if (!outPath.exists)
    {
        stderr.writeln("error: ", outPath, ": missing payload (run without --verify to create it)");
        return 1;
    }

    auto fresh = toJSON(payload);
    if (fresh.hasError)
    {
        stderr.writeln("error: ", samplePath, ": ", fresh.error.toString());
        return 1;
    }

    import std.json : parseJSON;

    // Compare as parsed documents, not as text: wired writes the payload
    // through `writeJSONFile`, and only the tree is the contract.
    const onDisk = parseJSON(readText(outPath));
    if (onDisk != parseJSON(fresh.value[]))
    {
        stderr.writeln("error: ", outPath,
            ": payload drift — re-run twoslash-extract to regenerate");
        return 1;
    }
    if (!cli.quiet)
        writeln(samplePath, ": up to date");
    return 0;
}
