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

import sparkles.test_runner.extract : ExtractedTest, extractUnittestBody,
    generateBetterCProgram, generateWasmJsShim, generateWasmProgram, sourceRootOf;
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
private bool inPath(string name) @safe
{
    import std.algorithm.iteration : splitter;
    import std.file : exists;
    import std.path : buildPath;
    import std.process : environment;

    foreach (dir; environment.get("PATH", "").splitter(':'))
        if (dir.length && buildPath(dir, name).exists)
            return true;
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
            location: TestLocation("src/pkg/a.d", 1, 1)),
        Test(fullName: "pkg.b.__unittest_L1_C1", name: "b",
            location: TestLocation("src/pkg/b.d", 1, 1)),
        Test(fullName: "other.c.__unittest_L1_C1", name: "c",
            location: TestLocation("lib2/src/other/c.d", 1, 1)),
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
            moduleName: test.moduleName,
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
