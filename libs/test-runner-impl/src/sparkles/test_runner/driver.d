/**
 * Process orchestration for the `--better-c` and `--wasm` runner modes:
 * extract the annotated tests (see $(MREF sparkles,test_runner,extract)),
 * generate a standalone program, compile it for the special environment, and
 * execute it.
 *
 * Uses only `std.process`/`std.file` so it works in every host package —
 * including `sparkles:base`, whose test build has no `core-cli`.
 */
module sparkles.test_runner.driver;

import sparkles.test_runner.extract : CtfeTarget, ExtractedTest,
    extractUnittestBody, generateBetterCProgram, generateCtfeProgram,
    generateWasmJsShim, generateWasmProgram, sourceRootOf;
import sparkles.test_runner.model : Test;

/// Options shared by both driver modes.
struct DriverOptions
{
    string compiler; /// explicit D compiler; empty = `$DC`, then `ldc2`, `dmd`
    string[] importPaths; /// extra `-I` paths
    string[] includeImports; /// extra `-i=<pattern>` module-inclusion patterns
    bool keep; /// keep the generated files and print their location
    bool verbose; /// echo the commands that are run
}

/// The outcome of one driver run.
struct DriverOutcome
{
    size_t testCount;
    bool succeeded = true;
    bool skipped; /// missing toolchain — reported but not a failure
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Whether an executable is reachable through `$PATH`.
///
/// A local re-implementation rather than `sparkles.core_cli.process_utils.isInPath`:
/// this module is source-compiled into `base`'s test build, which has no
/// `core-cli` dependency (the impl-library cycle is `impl → base`).
private bool inPath(string name) @safe
{
    import std.algorithm.iteration : splitter;
    import std.file : exists, isFile;
    import std.path : buildPath, pathSeparator;
    import std.process : environment;

    foreach (dir; environment.get("PATH", "").splitter(pathSeparator))
    {
        const candidate = buildPath(dir, name);
        if (dir.length && candidate.exists && candidate.isFile)
            return true;
    }
    return false;
}

/// The D compiler to use: explicit choice, `$DC`, or the first of
/// `ldc2`/`dmd` found in `$PATH` (empty string when none).
string detectCompiler(string preferred) @safe
{
    import std.process : environment;

    if (preferred.length)
        return preferred;
    if (const dc = environment.get("DC", null))
        return dc;
    foreach (candidate; ["ldc2", "dmd"])
        if (inPath(candidate))
            return candidate;
    return null;
}

/// This package's own source root — extracted modules are compiled with
/// `-unittest`, so their `version (unittest)` imports of
/// `sparkles.test_runner.attributes` must resolve.
private enum string runnerSourceRoot =
    sourceRootOf(__FILE_FULL_PATH__, "sparkles.test_runner.driver");

/// `-I` roots derived from every discovered test's module-name ↔ file-path
/// pair, plus the runner's own root and the user-supplied extras.
string[] deriveImportPaths(in Test[] allTests, in string[] extra) @safe pure
{
    import std.algorithm.searching : canFind;

    string[] roots = extra.dup ~ runnerSourceRoot;
    foreach (ref test; allTests)
    {
        const root = sourceRootOf(test.location.file, test.moduleName);
        if (root !is null && !roots.canFind(root))
            roots ~= root;
    }
    return roots;
}

@("deriveImportPaths.uniqueRoots")
@safe pure
unittest
{
    import sparkles.test_runner.model : TestLocation;

    const tests = [
        Test(fullName: "pkg.a.__unittest_L1_C1", name: "a",
            location: TestLocation(file: "src/pkg/a.d", line: 1, column: 1)),
        Test(fullName: "pkg.b.__unittest_L1_C1", name: "b",
            location: TestLocation(file: "src/pkg/b.d", line: 1, column: 1)),
        Test(fullName: "other.c.__unittest_L1_C1", name: "c",
            location: TestLocation(file: "lib2/src/other/c.d", line: 1, column: 1)),
    ];
    assert(deriveImportPaths(tests, ["extra"]) ==
        ["extra", runnerSourceRoot, "src", "lib2/src"]);
}

/// The dub package root containing `sourceRoot`: the nearest ancestor
/// directory (including itself) with a `dub.sdl`/`dub.json`, or `null`.
private string findPackageRoot(string sourceRoot) @safe
{
    import std.file : exists;
    import std.path : buildPath, dirName;

    for (string dir = sourceRoot; dir.length && dir != "/" && dir != ".";
        dir = dir.dirName)
    {
        if (buildPath(dir, "dub.sdl").exists || buildPath(dir, "dub.json").exists)
            return dir;
    }
    return null;
}

/// Import paths reported by `dub describe` for the packages containing the
/// derived source roots — this is how paths of registry dependencies (e.g.
/// `expected`) are found. Best-effort: failures yield an empty list.
private string[] dubDescribeImportPaths(in string[] sourceRoots, bool verbose)
{
    import std.algorithm.iteration : filter;
    import std.algorithm.searching : canFind;
    import std.string : lineSplitter;

    if (!inPath("dub"))
        return null;

    string[] packageRoots;
    foreach (root; sourceRoots)
    {
        const packageRoot = findPackageRoot(root);
        if (packageRoot !is null && !packageRoots.canFind(packageRoot))
            packageRoots ~= packageRoot;
    }

    string[] paths;
    foreach (packageRoot; packageRoots)
    {
        const result = run(["dub", "describe", "--root", packageRoot,
            "--data=import-paths", "--data-list"], verbose);
        if (result.status != 0)
            continue;
        foreach (line; result.output.lineSplitter.filter!(l => l.length))
            if (!paths.canFind(line))
                paths ~= line;
    }
    return paths;
}

/// Slices the bodies of `tests` out of their source files. Files are read
/// relative to the working directory — the same place the compiler resolved
/// them from when the test build was created.
ExtractedTest[] extractTests(in Test[] tests)
{
    import std.conv : text;
    import std.file : readText;

    string[string] sources;
    ExtractedTest[] extracted;
    foreach (ref test; tests)
    {
        auto source = test.location.file in sources;
        if (source is null)
        {
            sources[test.location.file] = readText(test.location.file);
            source = test.location.file in sources;
        }

        const body_ = extractUnittestBody(*source, test.location.line);
        if (body_ is null)
            throw new Exception(text("could not extract the unittest at ",
                test.location.file, ":", test.location.line, " (", test.name, ")"));

        extracted ~= ExtractedTest(
            name: test.name,
            // Strip aggregate qualifiers so a test nested in a struct/class emits
            // `import pkg.mod;`, not `import pkg.mod.Aggregate;` (mirrors the @ctfe
            // path, which also uses probeModuleName).
            moduleName: probeModuleName(test),
            file: test.location.file,
            line: test.location.line,
            functionAttributes: test.traits.functionAttributes,
            body_: body_,
        );
    }
    return extracted;
}

/// A fresh scratch directory for the generated program.
private string makeWorkDir(string flavor)
{
    import std.conv : text;
    import std.file : mkdirRecurse, tempDir;
    import std.path : buildPath;
    import std.process : thisProcessID;

    const dir = buildPath(tempDir,
        text("sparkles-test-runner-", flavor, "-", thisProcessID));
    mkdirRecurse(dir);
    return dir;
}

/// Runs `command`, echoing it when `verbose`, and returns (status, output).
private auto run(const(string)[] command, bool verbose)
{
    import std.process : execute;
    import std.stdio : stderr;

    if (verbose)
    {
        import std.string : join;

        stderr.writeln("$ ", command.join(" "));
    }
    return execute(command);
}

/// The extra `-i=<pattern>` flags requested with `--include-import` (e.g.
/// `--include-import=std.ascii` to compile a std module in when an extracted
/// test needs one of its non-template functions).
private string[] includeFlags(in DriverOptions options) @safe pure
{
    import std.algorithm.iteration : map;
    import std.array : array;

    return options.includeImports.map!(p => "-i=" ~ p).array;
}

/// The complete `-I` flag list: derived source roots, `dub describe`d
/// dependency paths, and user extras.
private string[] allImportFlags(in Test[] allTests, in DriverOptions options)
{
    import std.algorithm.iteration : map;
    import std.algorithm.searching : canFind;
    import std.array : array;

    auto roots = deriveImportPaths(allTests, options.importPaths);
    foreach (path; dubDescribeImportPaths(roots, options.verbose))
        if (!roots.canFind(path))
            roots ~= path;
    return roots.map!(p => "-I" ~ p).array;
}

// ─────────────────────────────────────────────────────────────────────────────
// @ctfe
// ─────────────────────────────────────────────────────────────────────────────

/// The outcome of evaluating `@ctfe` tests through a probe compile.
struct CtfeOutcome
{
    bool skipped; /// no D compiler found — reported but not a failure
    bool succeeded; /// the probe compiled: every selected test passed
    string[] failedNames; /// failing tests attributed from the compiler errors
    string output; /// full compiler output (`__ctfeWrite` text, errors, …)
}

/// The actual module containing `test`: `test.moduleName` with aggregate
/// qualifiers stripped (a nested test's `fullName` includes its aggregate),
/// found by peeling trailing components until the name matches the file path.
string probeModuleName(const Test test) @safe pure nothrow
{
    string candidate = test.moduleName;
    while (candidate.length)
    {
        if (sourceRootOf(test.location.file, candidate) !is null)
            return candidate;
        size_t cut = 0;
        foreach_reverse (i, c; candidate)
            if (c == '.')
            {
                cut = i;
                break;
            }
        if (!cut)
            break;
        candidate = candidate[0 .. cut];
    }
    return test.moduleName;
}

@("probeModuleName.nestedAndPlain")
@safe pure
unittest
{
    import sparkles.test_runner.model : TestLocation;

    const plain = Test(fullName: "pkg.mod.__unittest_L1_C1", name: "t",
        location: TestLocation(file: "src/pkg/mod.d", line: 1, column: 1));
    assert(probeModuleName(plain) == "pkg.mod");

    const nested = Test(fullName: "pkg.mod.Host.__unittest_L9_C1", name: "t",
        location: TestLocation(file: "src/pkg/mod.d", line: 9, column: 1));
    assert(probeModuleName(nested) == "pkg.mod");

    // Unresolvable path ↔ name pairs fall back to the raw module name.
    const odd = Test(fullName: "pkg.mod.__unittest_L1_C1", name: "t",
        location: TestLocation(file: "elsewhere.d", line: 1, column: 1));
    assert(probeModuleName(odd) == "pkg.mod");
}

/// Failing test names attributed from probe-compile output: the display-name
/// argument of `ctfePassed!(…, "name")` on `error instantiating` lines.
string[] parseCtfeFailures(string output) @safe pure
{
    import std.algorithm.searching : canFind;
    import std.string : indexOf, lineSplitter;

    string[] names;
    foreach (line; output.lineSplitter)
    {
        if (!line.canFind("error instantiating"))
            continue;
        auto at = line.indexOf("ctfePassed!(");
        if (at < 0)
            continue;
        const open = line.indexOf('"', at);
        if (open < 0)
            continue;
        size_t close = open + 1;
        while (close < line.length && !(line[close] == '"' && line[close - 1] != '\\'))
            close++;
        if (close >= line.length)
            continue;
        const name = line[open + 1 .. close];
        if (!names.canFind(name))
            names ~= name;
    }
    return names;
}

@("parseCtfeFailures.trailLines")
@safe pure
unittest
{
    enum output = "src/m.d(12,5): Error: boom\n" ~
        "probe.d(60,27): Error: template instance " ~
        "`sparkles_test_runner_ctfe.ctfePassed!(__unittest_L12_C1, \"a.one\")` " ~
        "error instantiating\n" ~
        "probe.d(60,13):        while evaluating: `static assert(ctfePassed!" ~
        "(__unittest_L12_C1, \"a.one\"))`\n" ~
        "probe.d(64,27): Error: template instance " ~
        "`sparkles_test_runner_ctfe.ctfePassed!(__unittest_L30_C1, \"b.two\")` " ~
        "error instantiating\n";
    assert(parseCtfeFailures(output) == ["a.one", "b.two"]);
    assert(parseCtfeFailures("all fine") == []);
}

/// Evaluates the given `@ctfe` tests: generates a probe program selecting
/// exactly those tests, and compiles it — together with the tests' module
/// sources — with `-o- -unittest` (semantic analysis only, so CTFE runs but
/// nothing is codegen'd or linked). When `traceFile` is given, LDC's
/// `-ftime-trace` flags are added and the trace is written there.
CtfeOutcome runCtfeTests(
    in Test[] ctfeTests, in Test[] allTests, in DriverOptions options,
    string traceFile = null)
{
    import std.algorithm.searching : canFind;
    import std.file : mkdirRecurse, write;
    import std.path : buildPath, dirName;
    import std.stdio : stdout;

    CtfeOutcome outcome;

    const compiler = detectCompiler(options.compiler);
    if (!compiler.length)
    {
        outcome.skipped = true;
        return outcome;
    }

    CtfeTarget[] targets;
    string[] moduleFiles;
    foreach (ref test; ctfeTests)
    {
        targets ~= CtfeTarget(
            moduleName: probeModuleName(test),
            file: test.location.file,
            line: test.location.line,
            name: test.name,
        );
        if (!moduleFiles.canFind(test.location.file))
            moduleFiles ~= test.location.file;
    }

    const workDir = makeWorkDir("ctfe");
    const sourceFile = buildPath(workDir, "ctfe_tests.d");
    write(sourceFile, generateCtfeProgram(targets));

    string[] traceFlags;
    if (traceFile.length)
    {
        mkdirRecurse(traceFile.dirName);
        traceFlags = ["-ftime-trace", "-ftime-trace-file=" ~ traceFile,
            "--ftime-trace-granularity=0"];
    }

    const compile = run(
        [compiler, "-o-", "-unittest", "-checkaction=context"]
            ~ traceFlags ~ includeFlags(options)
            ~ allImportFlags(allTests, options) ~ moduleFiles ~ [sourceFile],
        options.verbose);

    outcome.succeeded = compile.status == 0;
    outcome.output = compile.output;
    if (!outcome.succeeded)
        outcome.failedNames = parseCtfeFailures(compile.output);
    if (options.keep)
        stdout.writeln("generated files kept in ", workDir);
    return outcome;
}

// ─────────────────────────────────────────────────────────────────────────────
// --better-c
// ─────────────────────────────────────────────────────────────────────────────

/// Extracts the `@betterC` tests, compiles them with `-betterC` (no
/// druntime), runs the result, and reports.
DriverOutcome runBetterCTests(Test[] betterCTests, Test[] allTests, in DriverOptions options)
{
    import std.array : array;
    import std.algorithm.iteration : map;
    import std.file : write;
    import std.path : buildPath;
    import std.stdio : stdout, stderr;

    DriverOutcome outcome;
    outcome.testCount = betterCTests.length;
    if (!betterCTests.length)
    {
        stdout.writeln("no @betterC tests found");
        return outcome;
    }

    const compiler = detectCompiler(options.compiler);
    if (!compiler.length)
    {
        stderr.writeln("skipping @betterC tests: no D compiler found (set $DC or --compiler)");
        outcome.skipped = true;
        return outcome;
    }

    const workDir = makeWorkDir("betterc");
    const sourceFile = buildPath(workDir, "betterc_tests.d");
    const binary = buildPath(workDir, "betterc_tests");
    write(sourceFile, generateBetterCProgram(extractTests(betterCTests)));

    const importFlags = allImportFlags(allTests, options);
    // By default only the generated program is compiled, so extracted tests
    // can use templates/CTFE-able code from the imported modules but cannot
    // link against their non-template functions (same constraints as the
    // phobos @betterC suite). `--include-import=<pattern>` compiles matching
    // modules in (`-i=<pattern>`) — they must be betterC-codegen-clean, e.g.
    // `--include-import=sparkles.base.text --include-import=std.ascii`.
    const compile = run(
        [compiler, "-betterC", "-of=" ~ binary]
            ~ includeFlags(options) ~ importFlags ~ [sourceFile],
        options.verbose);
    if (compile.status != 0)
    {
        stderr.writeln(compile.output);
        stderr.writeln("failed to compile the extracted @betterC tests (see above)");
        outcome.succeeded = false;
        return outcome;
    }

    const result = run([binary], options.verbose);
    stdout.write(result.output);
    outcome.succeeded = result.status == 0;
    if (options.keep)
        stdout.writeln("generated files kept in ", workDir);
    return outcome;
}

// ─────────────────────────────────────────────────────────────────────────────
// --wasm
// ─────────────────────────────────────────────────────────────────────────────

/// Extracts the `@wasm` tests, cross-compiles them to `wasm32` with LDC, and
/// runs them with the first available WebAssembly-capable runtime
/// (`node`, `deno`, `bun`, or `wasmtime`).
DriverOutcome runWasmTests(Test[] wasmTests, Test[] allTests, in DriverOptions options)
{
    import std.algorithm.iteration : map;
    import std.algorithm.searching : canFind;
    import std.array : array;
    import std.conv : text;
    import std.file : write;
    import std.path : buildPath;
    import std.stdio : stdout, stderr;

    DriverOutcome outcome;
    outcome.testCount = wasmTests.length;
    if (!wasmTests.length)
    {
        stdout.writeln("no @wasm tests found");
        return outcome;
    }

    // llvm_trap + -mtriple make this LDC-specific.
    const compiler = detectCompiler(options.compiler);
    if (!compiler.canFind("ldc"))
    {
        stderr.writeln("skipping @wasm tests: an LDC compiler is required (set $DC or --compiler)");
        outcome.skipped = true;
        return outcome;
    }

    const workDir = makeWorkDir("wasm");
    const sourceFile = buildPath(workDir, "wasm_tests.d");
    const wasmFile = buildPath(workDir, "wasm_tests.wasm");
    const shimFile = buildPath(workDir, "wasm_tests.js");
    const extracted = extractTests(wasmTests);
    write(sourceFile, generateWasmProgram(extracted));
    write(shimFile, generateWasmJsShim(extracted, wasmFile));

    const importFlags = allImportFlags(allTests, options);
    const compile = run(
        [compiler, "-mtriple=wasm32-unknown-unknown-wasm", "-betterC",
            // reactor-style module: no _start, tests are individual exports
            "-L--no-entry",
            "-of=" ~ wasmFile] ~ includeFlags(options) ~ importFlags ~ [sourceFile],
        options.verbose);
    if (compile.status != 0)
    {
        stderr.writeln(compile.output);
        stderr.writeln("failed to cross-compile the extracted @wasm tests (see above)");
        stderr.writeln("note: with a stock LDC, the import chain of a @wasm test's " ~
            "module must avoid druntime headers that do not support wasm32;\n" ~
            "point --compiler (or $DC) at a wasm-enabled LDC build for full " ~
            "druntime/Phobos support");
        outcome.succeeded = false;
        return outcome;
    }

    const(string)[] runCommand;
    if (inPath("node"))
        runCommand = ["node", shimFile];
    else if (inPath("deno"))
        runCommand = ["deno", "run", "--allow-read", shimFile];
    else if (inPath("bun"))
        runCommand = ["bun", shimFile];
    else if (inPath("wasmtime"))
    {
        // No JS runtime: invoke each exported test directly.
        foreach (i, ref test; extracted)
        {
            const result = run(["wasmtime", "run",
                "--invoke", text("run_test_", i), wasmFile], options.verbose);
            const ok = result.status == 0;
            stdout.writeln(ok ? " ✓ " : " ✗ ", test.name,
                " [", test.file, ":", test.line, "]");
            if (!ok)
            {
                stdout.write(result.output);
                outcome.succeeded = false;
            }
        }
        if (options.keep)
            stdout.writeln("generated files kept in ", workDir);
        return outcome;
    }
    else
    {
        stderr.writeln("skipping @wasm tests: no WebAssembly runtime found " ~
            "(looked for node, deno, bun, wasmtime)");
        outcome.skipped = true;
        return outcome;
    }

    const result = run(runCommand, options.verbose);
    stdout.write(result.output);
    outcome.succeeded = result.status == 0;
    if (options.keep)
        stdout.writeln("generated files kept in ", workDir);
    return outcome;
}
