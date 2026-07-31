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
    {
        import dmd.globals : DiagnosticReporting;

        global.params.useWarnings = DiagnosticReporting.inform;
        global.params.useDeprecated = DiagnosticReporting.inform;
    }

    applyDflags(config.dflags);
    applyDebugIds(config.debugIds);

    config.effectiveImportPaths.each!addImport;
    config.stringImportPaths.each!addStringImport;
}

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
                break; // advisory: unknown flags are skipped
        }
    }
}

private void applyDebugIds(scope const string[] debugIds) @system
{
    import dmd.cond : DebugCondition;

    foreach (ident; debugIds)
        DebugCondition.addGlobalIdent(ident);
}
