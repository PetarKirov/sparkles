/++
This repository's invalidators
([ci task-DAG SPEC CIC5](../../../docs/specs/ci/task-dag/SPEC.md)): the paths
whose change selects every package under `--since`, checked before package
ownership. The list is declarative and grows only by editing it; the
selection algebra that consumes it is
`sparkles.build_primitives.workspace.select`.
+/
module repository_invalidators;

import sparkles.build_primitives.workspace.select : Invalidator;

/// The repository-wide inputs: a file, or a directory prefix ending in `/`.
static immutable Invalidator[] repositoryInvalidators = [
    // The root recipe and the dependency locks.
    Invalidator("dub.sdl"),
    Invalidator("dub.selections.json"),
    Invalidator("nix/dub-lock.json"),
    Invalidator("nix/ci-dub-lock.json"),
    // The toolchain and the shells.
    Invalidator("flake.nix"),
    Invalidator("flake.lock"),
    Invalidator("nix/d-toolchain.nix"),
    Invalidator("nix/shells/"),
    // The native libraries and import paths every package's actions read.
    Invalidator("nix/packages/"),
    // Package discovery, selection, and the task DAG.
    Invalidator("libs/build-primitives/src/sparkles/build_primitives/task/"),
    Invalidator("libs/build-primitives/src/sparkles/build_primitives/workspace/"),
    Invalidator("libs/build-primitives/src/sparkles/build_primitives/dub_manifest.d"),
    // `ci`'s command construction.
    Invalidator("apps/ci/src/commands/"),
    Invalidator("apps/ci/src/cli.d"),
    Invalidator("apps/ci/src/ci_main.d"),
    Invalidator("apps/ci/src/app.d"),
    Invalidator("apps/ci/tools/standardize-build-settings.d"),
];

@("repository_invalidators.cic5")
@safe pure nothrow @nogc
unittest
{
    import sparkles.build_primitives.workspace.select : invalidatorFor;

    alias hits = path => invalidatorFor(repositoryInvalidators, path) !is null;

    assert(hits("dub.sdl"));
    assert(hits("dub.selections.json"));
    assert(hits("nix/dub-lock.json"));
    assert(hits("nix/ci-dub-lock.json"));
    assert(hits("flake.nix"));
    assert(hits("flake.lock"));
    assert(hits("nix/d-toolchain.nix"));
    assert(hits("nix/shells/default.nix"));
    assert(hits("nix/packages/dub-builder/default.nix"));
    assert(hits("libs/build-primitives/src/sparkles/build_primitives/task/graph.d"));
    assert(hits("libs/build-primitives/src/sparkles/build_primitives/workspace/select.d"));
    assert(hits("libs/build-primitives/src/sparkles/build_primitives/dub_manifest.d"));
    assert(hits("apps/ci/src/app.d"));
    assert(hits("apps/ci/src/ci_main.d"));
    assert(hits("apps/ci/tools/standardize-build-settings.d"));

    // A sub-package's own recipe, the rest of build-primitives, and the rest
    // of `ci` are ordinary paths, owned by their packages.
    assert(!hits("libs/base/dub.sdl"));
    assert(!hits("README.md"));
    assert(!hits("libs/build-primitives/src/sparkles/build_primitives/gitignore.d"));
    assert(!hits("apps/ci/src/fence_audit.d"));
    assert(!hits("nix/packagesx"));
}
