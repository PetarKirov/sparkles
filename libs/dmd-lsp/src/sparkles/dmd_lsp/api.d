/**
The public facade of `sparkles:dmd-lsp` — a DMD-frontend-as-a-library semantic
core, ported from VisualD's `dmdserver` (Boost-1.0). See
`docs/specs/dmd-lsp/` for the architecture and requirement inventory.

This module is the only one dependents should import. The port lands in
stages (spec milestones L6–L7): the analysis driver + structured diagnostics
first, then the `semvisitor` type oracle (`tipAt` / `identifierSpans`).
*/
module sparkles.dmd_lsp.api;

@("dmd_lsp.api.frontendLinks")
@system unittest
{
    // Smoke test for the pinned dmd:frontend dependency: the LanguageServer
    // build initializes, parses, and semantically analyzes a module. Even an
    // import-free module implicitly imports `object`, so this needs runtime
    // source paths (COR6) — the devshell exports them; elsewhere the test
    // skips rather than failing or silently passing.
    import std.algorithm.iteration : each, splitter;
    import std.process : environment;

    import sparkles.test_runner.skip : skipTest;

    import dmd.frontend : addImport, deinitializeDMD, fullSemantic, initDMD,
        parseModule;

    const importPath = environment.get("SPARKLES_DMD_IMPORT_PATH", "");
    if (!importPath.length)
        skipTest("SPARKLES_DMD_IMPORT_PATH not set (enter `nix develop`)");

    initDMD();
    scope (exit) deinitializeDMD();
    importPath.splitter(':').each!addImport;

    auto parsed = parseModule("smoke.d", q{
        module smoke;
        int twice(int x) { return x * 2; }
    });
    assert(!parsed.diagnostics.hasErrors);
    fullSemantic(parsed.module_);
    assert(!parsed.diagnostics.hasErrors);
}

@("dmd_lsp.api.languageServerEnabled")
@safe pure nothrow @nogc unittest
{
    // The version identifier must propagate up from the dependency's manifest
    // (BLD1): without it this package would compile the dmd.* headers with
    // different declarations than the prebuilt library exports.
    version (LanguageServer) {}
    else static assert(false,
        "dmd:frontend must be the LanguageServer flavor (dmdserver-dub branch)");
}
