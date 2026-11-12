/++
What this repository states of its workspace inputs
([ci task-DAG SPEC CIC5](../../../docs/specs/ci/task-dag/SPEC.md);
[design](../../../docs/specs/build-primitives/build-graph/fileset-native-workspace.md)
BGW12): a change to any of it selects every package under `--since`.

Only what cannot be derived is stated here. The recipes and the lockfiles
are files planning reads, so they are workspace inputs by being read; the
planner's inputs are the closures of the packages that plan. What stays is
the toolchain's and the shells' definition, which no plan reads, and the
names the compiler's working-directory lookup could find (D49). The
selection itself is `sparkles.build_primitives.workspace.select`.
+/
module repository_inputs;

import sparkles.build_primitives.resolve.platform : BuildPlatform;
import sparkles.build_primitives.resolve.project : RegistrySources;
import sparkles.build_primitives.workspace.input_sets : WorkspaceInputs;
import sparkles.build_primitives.workspace.select : FocusOptions;

/// The toolchain and the shells, and the native libraries and import paths
/// every package's actions read: fileset patterns no plan reads.
static immutable string[] toolchainInputs = [
    "flake.nix",
    "flake.lock",
    "nix/d-toolchain.nix",
    "nix/shells/**",
    "nix/packages/**",
];

/// The files besides the recipes that planning reads: the dependency locks
/// the registry and dub's selections come from.
static immutable string[] lockfiles = ["dub.selections.json", "nix/dub-lock.json", "nix/ci-dub-lock.json"];

/// The first components of the importable modules: this repository's and
/// the toolchain's (D49).
static immutable string[] moduleRoots = ["sparkles", "std", "core", "etc", "ldc"];

/// The command that plans: its own sources are workspace inputs (D54).
enum plannerPackage = "sparkles:ci";

/// The library it plans and runs the work with: its closure is a workspace
/// input (D54). Not `ci`'s whole closure, which reaches `ui`, `syntax` and
/// `twoslash` through `docs`, and would make an edit to 30 of the 73
/// packages select all of them.
static immutable string[] plannerLibraries = ["sparkles:build-primitives"];

/// The focus options carrying this repository's workspace inputs, resolved
/// for `platform` with the registry `registry`.
FocusOptions repositoryFocus(BuildPlatform platform, RegistrySources registry) @safe pure nothrow
{
    FocusOptions options;
    options.workspace = WorkspaceInputs(read: lockfiles.dup, patterns: toolchainInputs.dup,
        moduleRoots: moduleRoots.dup);
    options.plannerPackage = plannerPackage;
    options.plannerLibraries = plannerLibraries;
    options.platform = platform;
    options.registry = registry;
    return options;
}

/// CIC5 over this repository: the read files, the toolchain and the
/// planner's inputs select every package; a library outside the planner's
/// closure, documentation and a recipe tool do not.
@("repository_inputs.cic5")
@system
unittest
{
    import std.conv : text;
    import std.path : buildNormalizedPath, buildPath;
    import std.process : environment;

    import sparkles.build_primitives.resolve.driver : SystemDriver;
    import sparkles.build_primitives.resolve.registry : nixRegistrySources, readDubLocks;
    import sparkles.build_primitives.workspace.discovery : readWorkspaceAt;
    import sparkles.build_primitives.workspace.package_graph : buildPackageGraph, RecipeRole;
    import sparkles.build_primitives.workspace.select : workspaceInputSets;
    import sparkles.test_runner.skip : skipTest;

    const sources = environment.get("SPARKLES_DUB_SOURCES");
    if (sources is null)
        skipTest("SPARKLES_DUB_SOURCES is not set");

    // This file is apps/ci/src/repository_inputs.d.
    const root = buildNormalizedPath(__FILE_FULL_PATH__, "../../../..");
    const host = ["linux", "posix"];
    auto driver = new SystemDriver;
    const locked = readDubLocks([root.buildPath("nix", "dub-lock.json"), root.buildPath("nix", "ci-dub-lock.json")],
        driver);
    assert(!locked.hasError, locked.hasError ? locked.error : "");
    auto registry = nixRegistrySources(locked.value, sources, driver);
    assert(!registry.hasError, registry.hasError ? registry.error : "");

    const workspace = readWorkspaceAt(root).value;
    const graph = buildPackageGraph(workspace.rootName, workspace.recipes, RecipeRole.test, host).value;
    const options = repositoryFocus(BuildPlatform(host.dup, ["x86_64"], "ldc", "ldc2", 2111, "1.41.0"),
        registry.value);
    auto inputs = workspaceInputSets(root, graph, workspace, options, host);

    foreach (path; [
        // Read by planning.
        "dub.sdl", "dub.selections.json", "nix/dub-lock.json", "nix/ci-dub-lock.json",
        // The toolchain, the shells and the native libraries.
        "flake.nix", "flake.lock", "nix/d-toolchain.nix", "nix/shells/default.nix",
        "nix/packages/dub-builder/default.nix",
        // The planner: build-primitives' closure, and ci's own sources.
        "libs/build-primitives/src/sparkles/build_primitives/task/graph.d",
        "libs/build-primitives/src/sparkles/build_primitives/workspace/select.d",
        "libs/build-primitives/src/sparkles/build_primitives/dub_manifest.d",
        "libs/base/src/sparkles/base/buffer.d",
        "apps/ci/src/app.d", "apps/ci/src/ci_main.d", "apps/ci/dub.sdl",
        // A top-level directory a module could be found in.
        "sparkles/base/buffer.d", "std/stdio.d",
    ])
        assert(inputs.inWorkspace(path), path);

    foreach (path; [
        // ci reaches these through `docs`, but does not plan with them.
        "libs/ui/src/sparkles/ui/package.d", "libs/syntax/dub.sdl", "libs/docs/src/sparkles/docs/glossary.d",
        // A sub-package's recipe outside the planner is its own package's.
        "libs/font/dub.sdl",
        // Documentation and tools that only rewrite recipes.
        "README.md", "docs/specs/ci/task-dag/SPEC.md", "apps/ci/tools/standardize-build-settings.d",
    ])
        assert(!inputs.inWorkspace(path), path);
}
