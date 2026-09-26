/// The batch D twoslash extractor (`docs/specs/dmd-lsp/`, `EXT1`–`EXT4`):
/// runs the `sparkles:twoslash-d` pipeline over an annotated D sample and
/// writes the `.twoslash.json` payload `apps/hue` renders.
///
/// One semantic analysis per process (`EXT2`): DMD-as-a-library is one big
/// global, so a directory target re-executes this binary once per file
/// instead of looping in-process.
module app;

import sparkles.base.buffer : SharedBuffer;

import std.stdio : stderr, writeln;

import sparkles.core_cli.args : Argument, HelpInfo, Option, parseCli, reportCliError;

import sparkles.dmd_lsp.api : AnalyzerConfig;
import sparkles.dmd_lsp.project : DubQuery;
import sparkles.twoslash.protocol : TwoslashReturn;

struct CliParams
{
    // The target: a `.d` sample or a directory of them. Declared variadic and
    // optional so the "no input given" and "extra inputs are ignored" behaviors
    // stay exactly as they were under the old leftover-argv handling.
    @(Argument("input", description: "A .d sample, or a directory of samples.", optional: true))
    string[] inputs;

    @(Option("out", description: "Output path for a file target, or output directory for a directory target; defaults to `<input-minus-.d>.twoslash.json` beside each input."))
    string outPath;

    @(Option("import", description: "Source import path for the analysis (repeatable); prepended to `$SPARKLES_DMD_IMPORT_PATH` and the sample's own `// @import:` directives."))
    string[] importPaths;

    @(Option("dflags", description: "Extra compiler flags (space-separated), merged with the sample's `// @dflags:` directives."))
    string dflags;

    @(Option("dub", description: "Analyze the input in the context of its dub project: `dub describe` supplies the import paths, string-import paths, version identifiers and dflags of the nearest dub.sdl/dub.json — or of the sample's own embedded recipe, when it is a single-file package. Off by default, so a standalone sample is never influenced by a project that happens to contain it."))
    bool dub;

    @(Option("dub-config", description: "With --dub: the dub configuration to describe (default: dub's own default configuration)."))
    string dubConfig;

    @(Option("dub-build", description: "With --dub: the dub build type to describe, e.g. unittest (default: dub's own default, debug)."))
    string dubBuild;

    @(Option("dub-compiler", description: "With --dub: the compiler dub describes for (`--compiler`): its `platform=` settings and flag spellings (default: dub's own)."))
    string dubCompiler;

    @(Option("dub-arch", description: "With --dub: the architecture dub describes for (`--arch`), e.g. x86 or an LDC triple."))
    string dubArch;

    @(Option("dub-override-config", description: "With --dub: a dependency's configuration, as `<package>/<configuration>` (`--override-config`; repeatable)."))
    string[] dubOverrideConfigs;

    @(Option("dub-d-version", description: "With --dub: an extra version identifier dub defines (`--d-version`; repeatable)."))
    string[] dubVersions;

    @(Option("dub-debug", description: "With --dub: an extra debug identifier dub defines (`--debug`; repeatable)."))
    string[] dubDebugs;

    @(Option("dub-dflags", description: "With --dub: the `$DFLAGS` dub runs under, which replaces the build type's own flags."))
    string dubDflags;

    /// The dub build `--dub` describes: every `--dub-*` option (`PRJ3`).
    DubQuery dubQuery() const @safe pure nothrow
        => DubQuery(config: dubConfig, buildType: dubBuild, compiler: dubCompiler,
            arch: dubArch, overrideConfigs: dubOverrideConfigs.dup, versionIds: dubVersions.dup,
            debugIds: dubDebugs.dup, dflags: dubDflags);

    /// The `--dub*` options again, for a child that must describe the same
    /// build. Inline `=` forms: a value may start with `-`.
    string[] dubFlags() const @safe pure nothrow
    {
        string[] flags;
        if (dub)
            flags ~= "--dub";
        if (dubConfig.length)
            flags ~= "--dub-config=" ~ dubConfig;
        if (dubBuild.length)
            flags ~= "--dub-build=" ~ dubBuild;
        if (dubCompiler.length)
            flags ~= "--dub-compiler=" ~ dubCompiler;
        if (dubArch.length)
            flags ~= "--dub-arch=" ~ dubArch;
        foreach (o; dubOverrideConfigs)
            flags ~= "--dub-override-config=" ~ o;
        foreach (v; dubVersions)
            flags ~= "--dub-d-version=" ~ v;
        foreach (d; dubDebugs)
            flags ~= "--dub-debug=" ~ d;
        if (dubDflags.length)
            flags ~= "--dub-dflags=" ~ dubDflags;
        return flags;
    }

    @(Option("verify", description: "Re-extract and diff against the existing payload instead of writing; exit 1 on drift (the golden-fixture guard)."))
    bool verify;

    @(Option("unittest", description: "Analyze `unittest` bodies too (implies the `unittest` version identifier), so a viewer explains test code as well as the code under test. Off by default: the golden corpus is analyzed exactly as written."))
    bool unittests;

    @(Option("quiet", description: "Suppress per-file progress output."))
    bool quiet;

    @(Option("lazy", description: "Emit hover nodes as bare spans without type/doc content (the lazy convention: underlines render, content resolves elsewhere). Queries/errors/completions stay eager."))
    bool lazyHovers;

    @(Option("stdout", description: "Write the payload as one compact JSON line on stdout instead of a file."))
    bool toStdout;

    @(Option("side", description: "Which compilation of a dcompute module to analyze (spec TGT5-TGT9). `auto` (the default) follows the module's `@compute` attribute: a deviceOnly module is analyzed as the dcompute LDC compiles it (its package's dub device configuration); a hostAndDevice module as host code, with the device side's errors merged in and every error only one side reports tagged `[host]`/`[device]`. `host` or `device` analyzes that side alone."))
    string side = "auto";

    @(Option("serve", description: "Oracle mode: analyze once, print the lazy payload as line 1 on stdout, then answer `{tip: <nodeIndex>}` JSON-line requests on stdin with the node's resolved content until EOF (spec EXT7)."))
    bool serve;
}

// `dub test` builds this package as a library and takes its `main` from the
// generated `dub_test_root` (see the unittest configuration in dub.sdl), so
// the CLI entry point steps aside for that build.
version (unittest) {} else
int main(string[] args)
{
    auto parsed = parseCli!CliParams(
        args,
        HelpInfo(
            "twoslash-extract",
            "Extract a twoslash node payload (types, queries, diagnostics, docs) " ~
            "from an annotated D sample (or a directory of samples) via DMD-as-a-library.",
            null
        )
    );
    if (!parsed)
        return reportCliError(parsed.error);
    const cli = parsed.value;

    if (cli.inputs.length == 0)
    {
        stderr.writeln("error: no input given (a .d sample or a directory); see --help");
        return 2;
    }
    const target = cli.inputs[0];

    if (cli.side != "auto" && cli.side != "host" && cli.side != "device")
    {
        stderr.writeln("error: --side must be auto, host or device, not `", cli.side, "`");
        return 2;
    }

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

    const source = readText(samplePath);
    const plan = sidePlan(cli, source);
    AnalyzerConfig config;
    if (!buildConfig(cli, samplePath, plan.side, config))
        return 1;

    auto live = LiveTwoslash.start(samplePath, source, config);
    scope (exit) live.shutdown();
    foreach (w; live.result.warnings)
        stderr.writeln("warning: ", samplePath, ": ", w);

    // The served payload carries the device side's errors too; `origin`
    // maps its node indices back to the ones the live analysis answers by.
    auto payload = live.result.payload;
    size_t[] origin;
    if (plan.mergeDevice)
        origin = mergeDeviceSide(cli, samplePath, payload);

    declareDPayload(payload);
    auto payloadJson = toJSON(payload);
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
            // A merged-in device error has no live node behind it: an empty tip.
            const liveIdx = !origin.length ? idx
                : idx < origin.length ? origin[idx] : size_t.max;
            const tip = liveIdx == size_t.max
                ? typeof(live.tipForNode(0)).init
                : live.tipForNode(liveIdx);

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
        // Inline `=` form: a dflags value starts with `-`, which the
        // space-separated form would read as the next option.
        if (cli.dflags.length)
            child ~= "--dflags=" ~ cli.dflags;
        child ~= cli.dubFlags;
        if (cli.side != "auto")
            child ~= "--side=" ~ cli.side;
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
    const plan = sidePlan(cli, source);
    AnalyzerConfig config;
    if (!buildConfig(cli, samplePath, plan.side, config))
        return 1;

    auto result = analyzeTwoslash(samplePath, source, config, cli.lazyHovers);
    foreach (w; result.warnings)
        stderr.writeln("warning: ", samplePath, ": ", w);
    if (plan.mergeDevice)
        mergeDeviceSide(cli, samplePath, result.payload);

    declareDPayload(result.payload);

    return cli.verify
        ? verifyPayload(cli, samplePath, outPath, result.payload)
        : writePayload(cli, samplePath, outPath, result.payload);
}

/// Which compilation of the sample an analysis stands in for.
enum Side
{
    host,   /// the ordinary (DMD) compile
    device, /// the dcompute LDC's device compile
}

/// The analysis a sample gets: which side, and whether the device side's
/// diagnostics are merged into it (`TGT9`).
struct SidePlan
{
    Side side;        ///
    bool mergeDevice; ///
}

/// Resolves `--side` against the sample's `@compute` attribute (`TGT5`).
SidePlan sidePlan(in CliParams cli, scope const(char)[] source) @safe
{
    import sparkles.dmd_lsp.device : ComputeMode, computeModeOf;

    switch (cli.side)
    {
        case "host": return SidePlan(Side.host);
        case "device": return SidePlan(Side.device);
        default:
            final switch (computeModeOf(source))
            {
                case ComputeMode.none: return SidePlan(Side.host);
                case ComputeMode.deviceOnly: return SidePlan(Side.device);
                case ComputeMode.hostAndDevice: return SidePlan(Side.host, mergeDevice: true);
            }
    }
}

@("twoslash-extract.sidePlan")
@safe unittest
{
    const hostAndDevice = "@compute(CompileFor.hostAndDevice) module m;";
    assert(sidePlan(CliParams(), "module m;") == SidePlan(Side.host));
    assert(sidePlan(CliParams(), "@compute module m;") == SidePlan(Side.device));
    assert(sidePlan(CliParams(), hostAndDevice) == SidePlan(Side.host, true));
    assert(sidePlan(CliParams(side: "device"), hostAndDevice) == SidePlan(Side.device));
    assert(sidePlan(CliParams(side: "host"), "@compute module m;") == SidePlan(Side.host));
}

/**
Analyzes the sample's device side in a child process (`EXT2`: one analysis
per process) and merges its errors into `payload` (`TGT9`); returns the node
index mapping `mergeSideDiagnostics` produces.

A device side that cannot be analyzed — no dcompute runtime on this machine,
say — is a warning, not a failure: the host analysis stands on its own.
*/
private size_t[] mergeDeviceSide(in CliParams cli, string samplePath,
    ref TwoslashReturn payload)
{
    import std.file : thisExePath;
    import std.process : Config, execute;

    import sparkles.twoslash_d.merge : mergeSideDiagnostics;
    import sparkles.wired.json : fromJSON;

    string[] child = [thisExePath, samplePath, "--side=device", "--stdout",
        "--lazy", "--quiet"];
    foreach (p; cli.importPaths)
        child ~= ["--import", p];
    if (cli.dflags.length)
        child ~= "--dflags=" ~ cli.dflags;
    child ~= cli.dubFlags;

    enum hostOnly = ": the device side could not be analyzed; showing the host side only";
    const r = execute(child, null, Config.stderrPassThrough);
    if (r.status != 0)
    {
        stderr.writeln("warning: ", samplePath, hostOnly);
        return null;
    }
    auto device = fromJSON!TwoslashReturn(r.output);
    if (device.hasError)
    {
        stderr.writeln("warning: ", samplePath, hostOnly, " (", device.error.toString(), ")");
        return null;
    }
    return mergeSideDiagnostics(payload, "host", device.value, "device");
}

/**
Assembles the analysis configuration one way for every mode: explicit
`--import`/`--dflags` first, then (with `--dub`) the enclosing project's
settings, then the environment's druntime/phobos tail.
*/
private bool buildConfig(in CliParams cli, string samplePath, Side side,
    out AnalyzerConfig config)
{
    import std.algorithm.searching : canFind;

    import sparkles.dmd_lsp.device : deviceConfigFor, retargetToDevice;
    import sparkles.dmd_lsp.options : runtimeImportPaths;

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

    // The device side is the package's device configuration — what
    // `shader-compile` compiles — not the host build (`TGT6`); explicit
    // `--import`s still come first. Without `--dub` the project is not
    // consulted on this side either: the host settings are retargeted.
    if (side == Side.device)
    {
        auto device = cli.dub
            ? deviceConfigFor(samplePath, config, cli.dubQuery)
            : retargetToDevice(config);
        device.importPaths = cli.importPaths
            ~ device.importPaths.filter!(p => !cli.importPaths.canFind(p)).array;
        config = device;
    }

    // `--import` prepends to the environment default rather than replacing it;
    // the default is the profile's runtime (DMD's, or the dcompute LDC's).
    if (config.importPaths.length)
        config.importPaths ~= runtimeImportPaths(config.effectiveProfile);

    // Reject an environment that cannot analyze *before* touching the frontend:
    // its own answer to a missing `object.d` is `fatal()`, which under the
    // collecting diagnostic sink exits 1 with nothing printed at all — and a
    // caller spawning this as an oracle (hue) then sees only a status code.
    import sparkles.dmd_lsp.options : runtimeSourcesProblem;

    if (const problem = runtimeSourcesProblem(config.effectiveImportPaths,
            config.effectiveProfile))
    {
        stderr.writeln("error: ", problem);
        return false;
    }
    return true;
}

/**
Folds the sample's dub project — its own embedded recipe, or the nearest
enclosing one (`PRJ17`) — into `config` (`PRJ5`).

Project settings are $(I appended): an explicit `--import`/`--dflags` stays
ahead of them in the search order, and the environment's druntime/phobos tail
is appended after both by the caller. Returns false when `--dub` was asked for
but cannot be honored — a silent fallback would produce a payload full of
"undefined identifier" nodes that looks like a source defect.
*/
private bool applyDubContext(in CliParams cli, string samplePath,
    ref AnalyzerConfig config)
{
    import sparkles.dmd_lsp.project : dubProjectFor;

    const proj = dubProjectFor(samplePath, cli.dubQuery);

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
        writeln("dub project ", proj.singleFile ? proj.recipe : proj.root, ": ",
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

    import sparkles.twoslash_d.emit : declareDPayload, twoslashPayloadLayout;
    import sparkles.wired.json : writeJSON;

    if (!outPath.exists)
    {
        stderr.writeln("error: ", outPath, ": missing payload (run without --verify to create it)");
        return 1;
    }

    // Compare the *bytes*, through the same layout `writeTwoslashFile` uses.
    // This used to compare parsed documents on the grounds that only the tree
    // was the contract — which is precisely why a wired default-layout change
    // silently reformatted every fixture (`e630631d`) without failing. Now the
    // layout is pinned, so the text is the contract too.
    declareDPayload(payload);
    SharedBuffer!(char, 8192) fresh;
    auto enc = writeJSON!twoslashPayloadLayout(payload, fresh);
    if (enc.hasError)
    {
        stderr.writeln("error: ", samplePath, ": ", enc.error.toString());
        return 1;
    }
    fresh ~= '\n'; // writeJSONFile's trailing newline

    if (readText(outPath) != fresh[])
    {
        stderr.writeln("error: ", outPath,
            ": payload drift — re-run twoslash-extract to regenerate");
        return 1;
    }
    if (!cli.quiet)
        writeln(samplePath, ": up to date");
    return 0;
}
