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

    @CliOption("unittest", "Analyze `unittest` bodies too (implies the `unittest` version identifier), so a viewer explains test code as well as the code under test. Off by default: the golden corpus is analyzed exactly as written.")
    bool unittests;

    @CliOption("quiet", "Suppress per-file progress output.")
    bool quiet;

    @CliOption("lazy", "Emit hover nodes as bare spans without type/doc content (the lazy convention: underlines render, content resolves elsewhere). Queries/errors/completions stay eager.")
    bool lazyHovers;

    @CliOption("stdout", "Write the payload as one compact JSON line on stdout instead of a file.")
    bool toStdout;

    @CliOption("serve", "Oracle mode: analyze once, print the lazy payload as line 1 on stdout, then answer `{tip: <nodeIndex>}` JSON-line requests on stdin with the node's resolved content until EOF (spec EXT7).")
    bool serve;
}

// `dub test` builds this package as a library and takes its `main` from the
// generated `dub_test_root` (see the unittest configuration in dub.sdl), so
// the CLI entry point steps aside for that build.
version (unittest) {} else
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

    if (cli.serve)
    {
        if (target.isDir)
        {
            stderr.writeln("error: --serve takes a single .d file");
            return 2;
        }
        return runServe(cli, target);
    }
    return target.isDir ? runDirectory(cli, target) : runFile(cli, target, cli.outPath);
}

/**
The resident oracle (`--serve`): one analysis held alive for the process
(`EXT2`), the lazy payload on stdout line 1, then a JSON-lines request loop —
`{"tip": <nodeIndex>}` →
`{"node": <i>, "text": …, "docs": …, "tags": […], "signature": {…}}` —
until stdin closes. Malformed requests answer `{"error": …}` and the loop
continues; hue drives this through `ResidentProcess`.
*/
private int runServe(in CliParams cli, string samplePath)
{
    import std.file : readText;
    import std.json : JSONType, JSONValue, parseJSON;
    import std.stdio : stdin, stdout;

    import sparkles.dmd_lsp.api : AnalyzerConfig;
    import sparkles.twoslash_d.analyze : LiveTwoslash, wireSignature;
    import sparkles.twoslash_d.emit : declareDPayload;
    import sparkles.wired.json : toJSON;

    AnalyzerConfig config;
    if (!buildConfig(cli, samplePath, config))
        return 1;

    auto live = LiveTwoslash.start(samplePath, readText(samplePath), config);
    scope (exit) live.shutdown();
    foreach (w; live.result.warnings)
        stderr.writeln("warning: ", samplePath, ": ", w);

    declareDPayload(live.result.payload);
    auto payloadJson = toJSON(live.result.payload);
    if (payloadJson.hasError)
    {
        stderr.writeln("error: ", payloadJson.error.toString());
        return 1;
    }
    stdout.writeln(payloadJson.value[]);
    stdout.flush();

    foreach (line; stdin.byLineCopy)
    {
        JSONValue reply;
        try
        {
            const req = parseJSON(line);
            const tipReq = "tip" in req;
            if (tipReq is null || tipReq.type != JSONType.integer)
                throw new Exception("expected {\"tip\": <nodeIndex>}");
            const idx = cast(size_t) tipReq.integer;
            const tip = live.tipForNode(idx);

            reply["node"] = JSONValue(idx);
            reply["text"] = JSONValue(tip.found
                ? (tip.kind.length ? "(" ~ tip.kind ~ ") " ~ tip.code : tip.code)
                : "");
            reply["docs"] = JSONValue(tip.doc);
            JSONValue[] tags;
            foreach (t; tip.tags)
            {
                JSONValue[] pair;
                foreach (part; t)
                    pair ~= JSONValue(part);
                tags ~= JSONValue(pair);
            }
            reply["tags"] = JSONValue(tags);
            // The structure the batch path puts on the node, so a live-resolved
            // hover reflows and abbreviates like every other one (`EXT7`).
            // wired encodes to text, so it re-enters std.json to join the reply
            // — the reply is one small object per hover, not a hot path.
            auto sig = toJSON(wireSignature(tip));
            if (sig.hasError)
                throw new Exception(sig.error.toString());
            reply["signature"] = parseJSON(sig.value[]);
        }
        catch (Exception e)
            reply = JSONValue(["error": JSONValue(e.msg)]);
        stdout.writeln(reply.toString);
        stdout.flush();
    }
    return 0;
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
    AnalyzerConfig config;
    if (!buildConfig(cli, samplePath, config))
        return 1;

    auto result = analyzeTwoslash(samplePath, source, config, cli.lazyHovers);
    foreach (w; result.warnings)
        stderr.writeln("warning: ", samplePath, ": ", w);

    declareDPayload(result.payload);

    return cli.verify
        ? verifyPayload(cli, samplePath, outPath, result.payload)
        : writePayload(cli, samplePath, outPath, result.payload);
}

/**
Assembles the analysis configuration one way for every mode: explicit
`--import`/`--dflags` first, then (with `--dub`) the enclosing project's
settings, then the environment's druntime/phobos tail.
*/
private bool buildConfig(in CliParams cli, string samplePath,
    out AnalyzerConfig config)
{
    import std.algorithm.iteration : filter, splitter;
    import std.array : array;

    import sparkles.dmd_lsp.api : AnalyzerConfig;

    config = AnalyzerConfig(
        importPaths: cli.importPaths.dup,
        dflags: cli.dflags.splitter(' ').filter!(f => f.length).array);

    // `--dub` (PRJ5): the enclosing project's settings, appended behind any
    // explicit `--import`/`--dflags` so those keep priority.
    if (cli.dub && !applyDubContext(cli, samplePath, config))
        return false;

    if (cli.unittests)
        config.dflags ~= "-unittest";

    // `--import` prepends to the environment default rather than replacing it.
    if (config.importPaths.length)
        config.importPaths ~= AnalyzerConfig().effectiveImportPaths;

    // Reject an environment that cannot analyze *before* touching the frontend:
    // its own answer to a missing `object.d` is `fatal()`, which under the
    // collecting diagnostic sink exits 1 with nothing printed at all — and a
    // caller spawning this as an oracle (hue) then sees only a status code.
    import sparkles.dmd_lsp.options : runtimeSourcesProblem;

    if (const problem = runtimeSourcesProblem(config.effectiveImportPaths))
    {
        stderr.writeln("error: ", problem);
        return false;
    }
    return true;
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
        stderr.writeln("warning: --dub: no dub.sdl/dub.json above ", samplePath,
            " — analyzing with the environment defaults");
        return true;
    }
    if (!proj.usable)
    {
        // Degrade, never abort (`PRJ15`): without the project's import paths
        // the analysis is poorer, but a viewer that shows nothing at all is
        // worse than one that shows what the environment defaults resolve.
        stderr.writeln("warning: --dub: ", proj.error,
            " — analyzing with the environment defaults");
        return true;
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

    if (cli.toStdout)
    {
        import std.stdio : stdout;

        import sparkles.wired.json : toJSON;

        auto j = toJSON(payload);
        if (j.hasError)
        {
            stderr.writeln("error: ", j.error.toString());
            return 1;
        }
        stdout.writeln(j.value[]);
        stdout.flush();
        return 0;
    }

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
