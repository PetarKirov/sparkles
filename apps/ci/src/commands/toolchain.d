/// How a command invokes dub and the compilers: test and build command lines,
/// sanitizer and `DFLAGS` environments, and per-package commands.
module commands.toolchain;

import sparkles.base.hw_caps : hwParallelism, describe;
import sparkles.base.logger : error;
import sparkles.build_primitives.dub_manifest : DubManifest;
import std.algorithm : any, canFind, startsWith;
import std.conv : to;
import std.path : baseName, buildPath;
import std.process : environment;
import std.stdio : stdout;
import std.string : indexOf;

package string[string] mergeEnv(const string[string] a, const(string[string]) b)
{
    string[string] out_;
    foreach (k, v; a)
        out_[k] = v;
    foreach (k, v; b)
        out_[k] = v;
    return out_;
}

/**
The compiler dub will actually use, as dub itself reports it (`"ldc"`, `"dmd"`,
`"gdc"`), or empty when that cannot be determined.

Asked rather than guessed. `$DC` decides it when set, but otherwise the choice
falls out of `$PATH` order — the dev shell resolves to `ldc2` while the Nix-built
`ci` closure resolves to `dmd` — so neither the environment nor a hardcoded
default answers this. `dub describe` reports the resolved compiler and honours
the same `--compiler=` this run passes, which makes it the one source that
cannot disagree with the build.
*/
package string resolvedCompiler(string repoRoot, in string[] subPackages)
{
    import std.json : JSONException, parseJSON;
    import sparkles.core_cli.process_utils : runCaptured;

    if (subPackages.length == 0)
        return null;

    auto cmd = ["dub", "describe", "--root", repoRoot, ":" ~ subPackages[0].baseName];
    const dc = environment.get("DC", "");
    if (dc.length)
        cmd ~= "--compiler=" ~ dc;

    const result = runCaptured(cmd);
    if (!result.succeeded)
        return null;
    try
    {
        auto doc = parseJSON(result.stdout);
        if (const c = "compiler" in doc.object)
            return c.str;
    }
    catch (JSONException)
    {
        // A describe that does not parse is not worth failing a test run over;
        // the flag it would have decided is a no-op on LDC's default anyway.
    }
    return null;
}

/++
The WASI-enabled `ldc2` that $(MREF each_commit)'s WebAssembly packages build
with, from `$SPARKLES_WASI_LDC`; `false`, reported, when one of `pkgPaths`
needs it and it is unset.
+/
bool findWasiCompiler(in string[] pkgPaths, out string compiler)
{
    import std.algorithm.searching : any, canFind;
    import each_commit : wasiCompilerVariable, wasiPackages;

    compiler = environment.get(wasiCompilerVariable, "");
    if (compiler.length || !pkgPaths.any!(p => wasiPackages.canFind(p.baseName)))
        return true;
    error(i"$(wasiCompilerVariable) is unset: the WebAssembly modules need an ldc2 with the WASI runtime (the ci package sets it: nix run .#ci)");
    return false;
}

/// True when a sub-package's recipe declares `targetType "sourceLibrary"`.
/// A sourceLibrary has no binary output in its default configuration, so `dub build :pkg`
/// fails unless directed to its `unittest` configuration.
private bool isSourceLibrary(string repoRoot, string packagePath)
{
    import sparkles.build_primitives.dub_manifest : readDubManifest;

    const manifest = readDubManifest(buildPath(repoRoot, packagePath, "dub.sdl"));
    return manifest.hasValue && declaresSourceLibrary(manifest.value);
}

/// Whether a recipe sets `targetType "sourceLibrary"`, at the top level or in
/// any configuration. Only the setting counts, never the word in a comment:
/// ui-gallery's recipe mentions a sourceLibrary it depends on, and treating it
/// as one built its `unittest` configuration, which never compiles `main`, so
/// `ci commits build-each` passed a commit whose executable did not build.
bool declaresSourceLibrary(in DubManifest manifest) @safe pure nothrow @nogc
{
    import std.algorithm.searching : any;

    return manifest.targetType == "sourceLibrary"
        || manifest.configurations.any!(c => c.targetType == "sourceLibrary");
}

@("ci.declaresSourceLibrary.ignoresComments")
@safe pure unittest
{
    import sparkles.build_primitives.dub_manifest : parseDubManifest;

    bool declares(string recipe) => declaresSourceLibrary(parseDubManifest(recipe).value);

    assert(declares("name \"x\"\ntargetType \"sourceLibrary\"\n"));
    assert(declares("configuration \"a\" {\n    targetType \"sourceLibrary\"\n}\n"));
    assert(!declares("// A sourceLibrary: its sources compile here\ntargetType \"executable\"\n"));
    assert(!declares("targetType \"library\" // not a sourceLibrary\n"));
}

/// `dub build :pkg` argv, honouring `$DC` and stating dub's default `debug`
/// build type — implicit, `$DFLAGS` would replace it (see
/// $(LREF testBuildType)). LDC flags are added separately via
/// $(LREF withLdcDflags).
package string[] dubBuildCommand(string repoRoot, string packagePath, string pkgName, string[] extra = null)
{
    auto cmd = ["dub", "--root", repoRoot, "build", ":" ~ pkgName, "-b", "debug"];
    if (isSourceLibrary(repoRoot, packagePath))
        cmd ~= "--config=unittest";
    const dc = environment.get("DC", "");
    if (dc.length)
        cmd ~= "--compiler=" ~ dc;
    if (extra.length)
        cmd ~= extra;
    return cmd;
}

/// Worker count for the parallel `ci test` leg: at least 2 so a test
/// cannot hide on the 8 MiB main thread.
uint parallelTestThreads(uint hw) @safe pure nothrow @nogc
    => hw < 2 ? 2 : hw;

@("ci.parallelTestThreads.atLeastTwo")
@safe pure nothrow @nogc
unittest
{
    assert(parallelTestThreads(0) == 2);
    assert(parallelTestThreads(1) == 2);
    assert(parallelTestThreads(8) == 8);
}

/// `dub test :pkg` argv, honouring `$DC`: `dubArgs` are dub's, `runnerArgs`
/// the test binary's (see $(LREF withTestArgs)). LDC flags are added
/// separately via $(LREF withLdcDflags).
package string[] dubTestCommand(string repoRoot, string pkgName,
    const(string)[] dubArgs = null, const(string)[] runnerArgs = null)
{
    auto cmd = ["dub", "--root", repoRoot, "test", ":" ~ pkgName];
    const dc = environment.get("DC", "");
    if (dc.length)
        cmd ~= "--compiler=" ~ dc;
    return withTestArgs(cmd, dubArgs, runnerArgs);
}

/// The build type every `dub test` states explicitly: dub's own `unittest`,
/// or `unittest-cov` when coverage is on.
///
/// Stating it is the point. dub documents that "setting the DFLAGS
/// environment variable will override the build type", and `$DFLAGS` is
/// always set under LDC here (see $(LREF withLdcDflags)) — so a `dub test`
/// without `-b` performs a `$DFLAGS` build that carries no `-unittest`. The
/// binary then holds zero tests, prints "All unit tests have been run
/// successfully." and exits 0: a package whose tests fail reports green.
package string[] testBuildType(bool coverage) @safe pure nothrow
    => ["-b", coverage ? "unittest-cov" : "unittest"];

@("ci.testBuildType.alwaysExplicit")
@safe pure nothrow
unittest
{
    assert(testBuildType(false) == ["-b", "unittest"]);
    assert(testBuildType(true) == ["-b", "unittest-cov"]);
}

/// Whether dub got as far as executing the test binary — decided from the
/// child's output, since a status alone cannot tell a failed link from a
/// failed test.
///
/// dub announces the run as `Running <target> …`, and a `dub test` target is
/// named `<package>-test-<config>`; a nonzero exit is then reported as
/// `Program exited with code N`. Either line means the build succeeded, so a
/// failure after it is the tests' verdict and must never trigger the
/// without-coverage retry.
package bool testBinaryRan(scope const(char)[] output) @safe pure nothrow @nogc
{
    import std.string : indexOf;

    if (output.indexOf("Program exited with code") >= 0)
        return true;
    // Line by line over bytes: `\n` never occurs inside a UTF-8 sequence.
    while (output.length)
    {
        const nl = output.indexOf('\n');
        auto line = nl < 0 ? output : output[0 .. nl];
        output = nl < 0 ? null : output[nl + 1 .. $];
        size_t i;
        while (i < line.length && (line[i] == ' ' || line[i] == '\t'))
            i++;
        line = line[i .. $];
        if (line.length > 8 && line[0 .. 8] == "Running " && line.indexOf("-test-") >= 0)
            return true;
    }
    return false;
}

@("ci.testBinaryRan.buildFailureVersusTestFailure")
@safe pure nothrow @nogc
unittest
{
    // A link failure: dub never reached the run.
    assert(!testBinaryRan("Linking sparkles-wired-test-unittest\n"
        ~ "ld: symbol(s) not found\nError ldc2 failed with exit code 1."));
    // The binary ran and its tests failed — the shapes from the real log.
    assert(testBinaryRan("     Running libs/wired/build/sparkles-wired-test-unittest -t 1\n"
        ~ "✗ sdl.decimal.beatsPhobosToReal\nError Program exited with code 1"));
    assert(testBinaryRan("     Running libs/wired/build/sparkles-wired-test-unittest\n"));
    assert(testBinaryRan("Error Program exited with code -11"));
    // dub's own pre-build chatter is not the binary.
    assert(!testBinaryRan("Running pre-build commands...\nError ldc2 failed with exit code 1."));
    assert(!testBinaryRan(""));
}

/// `baseCmd` plus `dubArgs` for dub and `runtimeArgs` for the test binary.
///
/// dub stops reading its own options at the first `--` and hands the rest to
/// the program, so the order is load-bearing: a `-b` placed after the runner's
/// `-t 1` is an argument the test binary ignores, not a build type.
package string[] withTestArgs(const(string)[] baseCmd, const(string)[] dubArgs,
    const(string)[] runtimeArgs) @safe pure nothrow
{
    string[] cmd = baseCmd.dup;
    cmd ~= dubArgs;
    if (runtimeArgs.length)
    {
        cmd ~= "--";
        cmd ~= runtimeArgs;
    }
    return cmd;
}

@("ci.withTestArgs.dubBeforeDoubleDash")
@safe pure nothrow
unittest
{
    const base = ["dub", "test", ":x"];
    assert(withTestArgs(base, ["-b", "unittest-cov"], ["--DRT-covopt=merge:1", "-t", "1"])
        == ["dub", "test", ":x", "-b", "unittest-cov", "--", "--DRT-covopt=merge:1", "-t", "1"]);
    assert(withTestArgs(base, null, null) == base);
    assert(withTestArgs(base, ["-b", "unittest"], null) == ["dub", "test", ":x", "-b", "unittest"]);
}

/// True when `$DC` (or its basename) is LDC.
package bool compilerIsLdc(string dc) @safe
{
    const n = dc.baseName;
    return n == "ldc2" || n == "ldc"
        || n.startsWith("ldc2-") || n.startsWith("ldc-");
}

@("ci.compilerIsLdc")
@safe
unittest
{
    assert(compilerIsLdc("ldc2"));
    assert(compilerIsLdc("/nix/store/…/bin/ldc2"));
    assert(compilerIsLdc("ldc2-1.41.0"));
    assert(!compilerIsLdc("dmd"));
    assert(!compilerIsLdc(""));
}

@("ci.dubBuildCommand")
unittest
{
    const cmd = dubBuildCommand("/repo", "libs/base", "base");
    assert(cmd[0 .. 4] == ["dub", "--root", "/repo", "build"]);
    assert(cmd[4] == ":base");
    assert(cmd[5 .. 7] == ["-b", "debug"]);
}

@("ci.dubTestCommand.forwardsRunnerArgs")
unittest
{
    const cmd = dubTestCommand("/repo", "dql", ["-b", "unittest-cov"], ["-t", "1"]);
    assert(cmd[0 .. 4] == ["dub", "--root", "/repo", "test"]);
    assert(cmd[4] == ":dql");
    assert(cmd[$ - 5 .. $] == ["-b", "unittest-cov", "--", "-t", "1"]);
}

/// Linux is the only host where nixpkgs LDC can link ASan (gcc `libasan`
/// fallback). Darwin's LDC looks for `libclang_rt.asan_osx_dynamic.dylib`,
/// which the nix build does not ship.
bool sanitizePlatformSupported() @safe pure nothrow @nogc
{
    version (linux)
        return true;
    else
        return false;
}

/// Compiler flags for $(LREF runDubTestsMode) `sanitize: true`.
///
/// $(LIST
///     $(ITEM `-fsanitize=address` — LDC IR pass; Linux links gcc `libasan`)
/// )
///
/// `--enable-stackovf-sanitizer` used to sit beside it. It is an LLVM option
/// of the Hexagon backend's frame lowering, so it probed nothing on x86_64 or
/// aarch64; a stock LDC accepted it only because its LLVM builds every target,
/// and an LDC whose LLVM lacks Hexagon rejects it.
///
/// There is deliberately no UBSan here. LDC rejects `-fsanitize=undefined`
/// for D, and `-Xcc=-fsanitize=undefined` does not reach ImportC either:
/// `-Xcc` goes to the C preprocessor (`cc -E`) and to the link driver, while
/// the C bodies are code-generated by LDC, which has no UBSan pass. Measured
/// on a C file with a signed add and a variable shift: 0 `__ubsan_handle_*`
/// call sites through LDC against 6 through clang. All it did was link
/// `libubsan` into every test binary — see
/// `docs/research/sanitizers/ubsan.md`.
enum string sanitizeCompilerFlags = "-fsanitize=address";

/// ASan runtime options.
///
/// $(LIST
///     $(ITEM `detect_leaks=0` — LSan flags druntime's trace-info mallocs)
///     $(ITEM `halt_on_error=1:abort_on_error=1` — stop on the first finding,
///           so the package's verdict is the report, not a later cascade)
///     $(ITEM `detect_stack_use_after_return=0` — the fake stack is off.
///           LDC 1.42's druntime passes `null` to
///           `__sanitizer_finish_switch_fiber` when a `Fiber` reaches
///           `TERM` (`core/thread/fiber/base.d`, `switchIn`), which drops
///           the thread's fake stack; ASan then lazily creates a new one
///           that the GC never learns about (`asan_fakestack` is captured
///           once at thread start), so a GC-owned value referenced only
///           from an instrumented local can be collected early. Every
///           terminated fiber — `sparkles:event-horizon` runs them to
///           `TERM` as its normal path — re-arms that. With the fake
///           stack off, locals stay on the real stack and the switch hooks
///           are inert. The price is that stack-use-after-return goes
///           undetected.)
/// )
enum string sanitizeAsanOptions =
    "detect_leaks=0:halt_on_error=1:abort_on_error=1:detect_stack_use_after_return=0";

string[string] sanitizeChildEnv() @safe
{
    string[string] env;
    env["DFLAGS"] = sanitizeCompilerFlags;
    env["ASAN_OPTIONS"] = sanitizeAsanOptions;
    return env;
}

@("ci.sanitizePlatformSupported.linuxOnly")
@safe pure nothrow @nogc
unittest
{
    version (linux)
        assert(sanitizePlatformSupported());
    else
        assert(!sanitizePlatformSupported());
}

@("ci.sanitizeCompilerFlags.addressOnly")
@safe pure nothrow @nogc
unittest
{
    assert(sanitizeCompilerFlags.canFind("-fsanitize=address"));
    // A Hexagon-only LLVM option, which an LDC without that target rejects.
    assert(!sanitizeCompilerFlags.canFind("stackovf"));
    // No UBSan: LDC rejects `-fsanitize=undefined` for D, and `-Xcc` never
    // reaches ImportC codegen, so the flag instruments nothing.
    assert(!sanitizeCompilerFlags.canFind("undefined"));
    assert(!sanitizeCompilerFlags.canFind("-Xcc"));
    assert(!sanitizeCompilerFlags.canFind("-fstack-clash-protection"));
}

@("ci.sanitizeChildEnv.pinsLeakHaltAndFakeStackPolicy")
@safe
unittest
{
    const env = sanitizeChildEnv();
    assert(env["DFLAGS"] == sanitizeCompilerFlags);
    assert(env["ASAN_OPTIONS"].canFind("detect_leaks=0"));
    assert(env["ASAN_OPTIONS"].canFind("halt_on_error=1"));
    assert(env["ASAN_OPTIONS"].canFind("abort_on_error=1"));
    // The fake stack must stay off until druntime restores it across a
    // fiber's TERM; see `sanitizeAsanOptions`.
    assert(env["ASAN_OPTIONS"].canFind("detect_stack_use_after_return=0"));
    assert("UBSAN_OPTIONS" !in env);
}

/// A child's `DFLAGS` on top of the ambient `$DFLAGS`, so a mode that adds
/// flags (`--coverage`, `ci test --sanitize address`) does not drop the ones the shell
/// already carries: `ci test` keeps them, and the other legs must build the
/// same code plus their own switches.
private string[string] withAmbientDflags(const string[string] env, string ambient) @safe
{
    string[string] out_;
    foreach (k, v; env)
        out_[k] = v;
    if (ambient.length)
        if (auto own = "DFLAGS" in out_)
            out_["DFLAGS"] = ambient ~ " " ~ *own;
    return out_;
}

@("ci.withAmbientDflags.prependsTheShellFlags")
@safe
unittest
{
    assert(withAmbientDflags(["DFLAGS": "-fsanitize=address"], "-L-L/opt/lib")["DFLAGS"]
        == "-L-L/opt/lib -fsanitize=address");
    // No ambient flags: the child's are the whole value.
    assert(withAmbientDflags(["DFLAGS": "-cov"], "")["DFLAGS"] == "-cov");
    // No child DFLAGS: nothing to merge into; the ambient value is inherited
    // by the child process on its own.
    assert("DFLAGS" !in withAmbientDflags(["ASAN_OPTIONS": "x"], "-L-L/opt/lib"));
}

/// Merge LDC's `-linkonce-templates` into a child environment's `DFLAGS`.
///
/// A no-op unless `$DC` is LDC, and when `DFLAGS` already has the flag. A
/// `DFLAGS` in `env` is stacked on the ambient `$DFLAGS` first
/// ($(LREF withAmbientDflags)).
///
/// No `--threads`: it is not an LDC option but LLVM's legacy ThinLTO code
/// generator's, which LDC never uses (it compiles on one thread), and it
/// parses only where LDC links LLVM as one shared library.
package string[string] withLdcDflags(const string[string] env)
{
    const dc = environment.get("DC", "");
    auto out_ = withAmbientDflags(env, environment.get("DFLAGS", ""));
    if (!compilerIsLdc(dc))
        return out_;

    const existing = "DFLAGS" in out_
        ? out_["DFLAGS"]
        : environment.get("DFLAGS", "");
    if (!existing.canFind("-linkonce-templates"))
        out_["DFLAGS"] = existing.length
            ? existing ~ " -linkonce-templates"
            : "-linkonce-templates";
    return out_;
}

/**
One command `ci test` or `ci test --build-only` runs for a package, as a planner outside
this module needs it to run the package the same way: the `ci test --watch` rounds,
which run it as a task.
*/
struct PackageCommand
{
    string label;       /// `-t 1`, `build`
    string[] argv;      ///
    string[string] env; /// added to the inherited environment
}

/// The legs `ci test` runs for the package in the repository-relative
/// `pkgDir`, in order, without coverage: `-t 1`, then the parallel leg on
/// `threads` threads ($(LREF defaultTestThreads)).
PackageCommand[] packageTestCommands(string repoRoot, string pkgDir, uint threads)
{
    const pkgName = pkgDir.baseName;
    const parallelN = threads.to!string;
    PackageCommand leg(string label, string[] runnerArgs)
        => PackageCommand(label, dubTestCommand(repoRoot, pkgName, testBuildType(false), runnerArgs),
            withLdcDflags(null));
    return [
        leg("-t 1", ["-t", "1", "--skip-slow"]),
        leg("-t " ~ parallelN, ["-t", parallelN, "--skip-slow"]),
    ];
}

/// The parallel leg's thread count `ci test` uses now. It follows the host's
/// load, so a planner that compares commands across runs reads it once.
uint defaultTestThreads() => parallelTestThreads(hwParallelism());

/// The command `ci test --build-only` runs for the package in the repository-relative
/// `pkgDir`, with `wasiCompiler` as $(LREF findWasiCompiler) found it.
PackageCommand packageBuildCommand(string repoRoot, string pkgDir, string wasiCompiler)
{
    import each_commit : targetBuildArgs;

    const pkgName = pkgDir.baseName;
    return PackageCommand("build",
        dubBuildCommand(repoRoot, pkgDir, pkgName, targetBuildArgs(pkgName, wasiCompiler)),
        withLdcDflags(null));
}
