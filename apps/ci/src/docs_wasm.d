/++
`--stage-docs-wasm`: put the documentation site's WebAssembly modules where
VitePress serves them (docs/specs/toolchain/wasm-modules.md, `TCM3`).

The modules are built from the tree the site is built from (`nix build
.#docs-wasm`) and copied into `docs/public/`; none is committed. Without
`nix`, copies a previous run left are reused, and their absence is an error.
+/
module docs_wasm;

import std.conv : octal;

/// The modules the site loads, as `.#docs-wasm` installs them.
immutable string[] docsWasmModules = ["spk-text.wasm", "spk-table.wasm"];

/// Where the site serves them from, relative to the repository root.
enum docsWasmDir = "docs/public";

/++
Builds `.#docs-wasm` from the repository at `repoRoot` and copies its modules
into $(LREF docsWasmDir). Returns the process exit status.
+/
int stageDocsWasm(string repoRoot)
{
    import std.algorithm.searching : all;
    import std.file : copy, exists, getSize, setAttributes;
    import std.path : buildPath;
    import std.process : execute, ProcessException;
    import std.array : array;
    import std.stdio : stderr;
    import std.string : lineSplitter, strip;

    const outDir = buildPath(repoRoot, docsWasmDir);
    bool nix;
    try
        nix = execute(["nix", "--version"]).status == 0;
    catch (ProcessException)
        nix = false;
    if (!nix)
    {
        if (docsWasmModules.all!(m => buildPath(outDir, m).exists))
        {
            stderr.writeln("--stage-docs-wasm: nix not found; reusing the modules in ", outDir);
            return 0;
        }
        stderr.writeln("--stage-docs-wasm: nix not found, and ", outDir, " lacks the modules: ",
            "copy those of `nix build .#docs-wasm` there");
        return 1;
    }

    const build = execute(["nix", "build", repoRoot ~ "#docs-wasm", "--no-link", "--print-out-paths"]);
    if (build.status != 0)
    {
        stderr.writeln("--stage-docs-wasm: nix build .#docs-wasm failed:\n", build.output);
        return 1;
    }
    // The store path is the last line; nix's warnings come before it.
    const store = build.output.strip.lineSplitter.array[$ - 1];
    foreach (m; docsWasmModules)
    {
        const target = buildPath(outDir, m);
        copy(buildPath(store, m), target);
        setAttributes(target, octal!644);
        stderr.writeln("--stage-docs-wasm: wrote ", target, " (", getSize(target), " bytes)");
    }
    return 0;
}
