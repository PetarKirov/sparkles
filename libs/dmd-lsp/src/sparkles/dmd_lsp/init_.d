/**
Global DMD initialization for one analysis — the batch-mode counterpart of
`dmdserver`'s `dmdinit.d` (Boost-1.0), reduced per spec `COR2`:

$(LIST
    * One `initAnalyzer` per session; there is deliberately $(B no)
        `dmdReinit` and no mangled-name `dmdStatics` reset table — batch
        isolation is one-analysis-per-process (`EXT2`), and teardown is the
        frontend's own `deinitializeDMD` (driven by `Analyzer`'s destructor).
    * The target is the $(B host) OS/arch (the original hardcodes Windows).
    * Doc comments are always retained (`ddoc.doOutput`) so the type oracle
        can surface them (spec `DOC1`).
)
*/
module sparkles.dmd_lsp.init_;

import sparkles.dmd_lsp.diag : DiagnosticSink;
import sparkles.dmd_lsp.options : AnalyzerConfig;

import core.sync.mutex : Mutex;

/**
Serializes access to DMD's process-wide globals; held for an `Analyzer`'s
whole lifetime (see $(REF Analyzer, sparkles,dmd_lsp,api)).

It lives here rather than next to its only user because the module
constructor that creates it would otherwise close a cycle:
`api` → `visitor` → `testing` → `api`, with `visitor`'s property-table
constructor at the other end. `init_` is a leaf, so the runtime can order
the two.
*/
__gshared Mutex dmdGlobalsLock;

shared static this()
{
    dmdGlobalsLock = new Mutex;
}

/// Initializes DMD's globals for one analysis session: frontend `initDMD`
/// with the sink's handler, analysis-friendly parameters, the `-dflags`
/// subset, and the resolved import paths. Call exactly once per process.
void initAnalyzer(ref DiagnosticSink sink, in AnalyzerConfig config) @system
{
    import std.algorithm.iteration : each;
    import std.functional : toDelegate;

    import dmd.frontend : addImport, addStringImport, initDMD;
    import dmd.globals : global;

    initDMD(
        (const ref loc, headerColor, header, messageFormat, args, p1, p2) nothrow
            => sink.handle(loc, headerColor, header, messageFormat, args, p1, p2),
        null,
        config.versionIds);

    // Analysis-mode parameters (dmdSetupParams's batch-relevant subset):
    // uncapped diagnostics, no object emission, warnings/deprecations as
    // informational messages, doc comments kept for tooltips (DOC1).
    global.params.v.errorLimit = 0;
    global.params.obj = false;
    global.params.useInline = false;
    global.params.ddoc.doOutput = true;
    // The *lexer's* copy of the same switch, which `main` mirrors from
    // `params.ddoc.doOutput`. It gates capturing a documented unittest's body
    // (`parseUnitTest`'s `codedoc`), which is the `Examples:` section a tooltip
    // shows — without it the comment survives and the example does not.
    global.compileEnv.ddocOutput = true;
    {
        import dmd.globals : DiagnosticReporting;

        global.params.useWarnings = DiagnosticReporting.inform;
        global.params.useDeprecated = DiagnosticReporting.inform;
    }

    applyDflags(config.dflags);
    applyDebugIds(config.debugIds);

    const importPaths = config.effectiveImportPaths;
    importPaths.each!addImport;
    config.stringImportPaths.each!addStringImport;

    installCPreprocessor(importPaths);
}

/**
Installs the C preprocessor hook, so an `import` that resolves to a `.c`/`.h`
file is preprocessed rather than parsed raw (spec `COR7`).

DMD reads a C file through `global.preprocess`, a function pointer its own
driver assigns (`main.d`) and `initDMD` does not. Left null, `dmodule.d` hands
the unexpanded text to the ImportC parser, which rejects the first `#include`
and then reports every declaration behind that header as undefined — for an
ImportC binding, hundreds of them, all of which read as defects in the user's
code.

Returns whether the hook was installed. Both prerequisites — a preprocessor to
run and the `importc.h` it must force-include — are probed up front, because
$(REF preprocessCFile, sparkles,dmd_lsp,cpreprocess) commits to them per file
and a missing one has no good answer at that point. Not installing is the
strictly better degradation: the analysis still runs, just with the
pre-existing ImportC blindness.
*/
bool installCPreprocessor(scope const string[] importPaths) @system
{
    import std.algorithm.iteration : filter;
    import std.file : exists;
    import std.path : buildPath;
    import std.range : takeOne;

    import dmd.globals : global;
    import sparkles.dmd_lsp.cpreprocess : preprocessCFile, setPreprocessor;

    // `importc.h` ships beside `object.d`, so the runtime import paths are the
    // whole search — the same place dmd's own `findImportcH` looks.
    foreach (header; importPaths.filter!(p => p.buildPath("importc.h").exists)
        .takeOne)
    {
        const command = cPreprocessorCommand();
        if (!command.length)
            return false;

        setPreprocessor(command, header.buildPath("importc.h"));
        global.preprocess = &preprocessCFile;
        return true;
    }
    return false;
}

/**
The C preprocessor to run, or empty when none is usable.

Mirrors the choice `dmd.cpreprocess.cppCommand` (private) would make, but as a
$(I probe): the frontend's version errors and `fatal()`s when its pick is
absent, and on Windows it goes looking for a Visual Studio installation to do
it. Here an absent preprocessor simply means "do not install the hook", which
is why Windows is served only by an explicit `$CPPCMD`.
*/
private string cPreprocessorCommand() @safe
{
    import std.process : environment;

    // `.length`, not truthiness: an empty `string` still has a non-null
    // pointer, so `if (environment.get(…, ""))` would take this branch always.
    const explicit = environment.get("CPPCMD", "");
    if (explicit.length)
        return resolvable(explicit) ? explicit : null;

    version (Windows)
        return null; // cl.exe discovery is the driver's job, not a probe's
    else version (OSX)
        enum candidate = "clang";
    else version (OpenBSD)
        enum candidate = "/usr/libexec/cpp";
    else
        enum candidate = "cpp";

    return resolvable(candidate) ? candidate : null;
}

/// Whether a command name or path can be executed: an absolute/relative path
/// must exist, a bare name must be on `PATH`.
private bool resolvable(string command) @safe
{
    import std.algorithm.iteration : splitter;
    import std.algorithm.searching : canFind;
    import std.file : exists;
    import std.path : buildPath, dirSeparator;
    import std.process : environment;

    if (command.canFind(dirSeparator))
        return command.exists;

    foreach (dir; environment.get("PATH", "").splitter(':'))
        if (dir.length && dir.buildPath(command).exists)
            return true;
    return false;
}

/**
A null-terminated copy of `s`, kept alive for the process.

DMD's `Array!(const(char)*)` fields are malloc'd and invisible to the GC, so a
bare `toStringz` result pushed into one is collectable while the frontend still
points at it. The anchor list is the cheapest fix that stays plain D.
*/
private const(char)* anchored(scope const(char)[] s) @trusted
{
    import std.string : toStringz;

    const z = s.toStringz;
    _cStringAnchors ~= z;
    return z;
}

private __gshared const(char)*[] _cStringAnchors;

/**
Applies the supported `// @dflags:` subset (spec `COR5`). Unknown flags are
ignored — a sample's flags are advisory analysis configuration, not a build
system. Supported: the `-preview=*` features this repo builds with plus the
common analysis-relevant switches.
*/
void applyDflags(scope const string[] dflags) @system
{
    import dmd.cond : VersionCondition;
    import dmd.globals : FeatureState, global;

    foreach (flag; dflags)
    {
        switch (flag)
        {
            case "-preview=in":
                global.params.previewIn = true;
                break;
            case "-preview=dip1000":
                global.params.useDIP25 = FeatureState.enabled;
                global.params.useDIP1000 = FeatureState.enabled;
                break;
            case "-preview=dip25":
            case "-dip25":
                global.params.useDIP25 = FeatureState.enabled;
                break;
            case "-preview=dip1021":
                global.params.useDIP1021 = true;
                break;
            case "-preview=nosharedaccess":
                global.params.noSharedAccess = FeatureState.enabled;
                break;
            case "-preview=fixAliasThis":
                global.params.fixAliasThis = true;
                break;
            case "-preview=rvaluerefparam":
                global.params.rvalueRefParam = FeatureState.enabled;
                break;
            case "-preview=systemVariables":
                global.params.systemVariables = FeatureState.enabled;
                break;
            case "-betterC":
                // Also the derived params dmd's own CLI post-processing sets
                // (main.d) — semantic checks read these, not `betterC` alone.
                global.params.betterC = true;
                global.params.allInst = true;
                global.params.useModuleInfo = false;
                global.params.useTypeInfo = false;
                global.params.useExceptions = false;
                global.params.useGC = false;
                break;
            case "-unittest":
                // The driver does both (`mars.d`): analyze unittest bodies
                // *and* predefine the `unittest` version identifier. Setting
                // only the parameter analyzes bodies whose
                // `version (unittest)` imports never came in — a file that
                // guards its test-only imports that way (the repo idiom) then
                // reports every one of them as an undefined identifier.
                global.params.useUnitTests = true;
                VersionCondition.addPredefinedGlobalIdent("unittest");
                break;
            case "-debug":
                global.params.debugEnabled = true;
                break;
            default:
                // `-P<flag>` forwards one switch to the C preprocessor. The
                // include paths of an ImportC dependency arrive this way
                // (`PRJ18`), and they are the difference between reading a
                // header and reporting everything in it as undefined.
                const forwarded = preprocessorSwitch(flag);
                if (forwarded.length)
                    global.params.cppswitches.push(anchored(forwarded));
                break; // advisory: unknown flags are skipped
        }
    }
}

/// The switch a `-P<flag>` (or `-P=<flag>`) dflag forwards; empty for anything
/// that is not one.
private const(char)[] preprocessorSwitch(return scope const(char)[] flag) @safe pure nothrow @nogc
{
    if (flag.length <= 2 || flag[0 .. 2] != "-P")
        return null;
    const value = flag[2 .. $];
    return value[0] == '=' ? value[1 .. $] : value;
}

@("dmd_lsp.init_.preprocessorSwitch")
@safe pure nothrow @nogc unittest
{
    assert(preprocessorSwitch("-P-I/usr/include") == "-I/usr/include");
    assert(preprocessorSwitch("-P=-DFOO") == "-DFOO");
    assert(preprocessorSwitch("-preview=in").length == 0);
    assert(preprocessorSwitch("-P").length == 0);
    assert(preprocessorSwitch("-P=").length == 0);
}

private void applyDebugIds(scope const string[] debugIds) @system
{
    import dmd.cond : DebugCondition;

    foreach (ident; debugIds)
        DebugCondition.addGlobalIdent(ident);
}
