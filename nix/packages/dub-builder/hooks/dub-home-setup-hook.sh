# Assemble `$DUB_HOME` from the registry dependencies and, when one is
# supplied, a previously built artifact bundle.
#
# `$DUB_HOME` must sit at the same absolute path in every derivation that
# shares artifacts: dub records absolute `targetBinaryPath`s in its per-package
# `db.json`, and the cached targets of a package's dependencies are themselves
# inputs to the up-to-date check. `$NIX_BUILD_TOP/.dub` is `/build/.dub` under
# the sandbox — the same reasoning as dubNormalizeSourceHook.
dubHomeSetupHook() {
    echo "Executing dubHomeSetupHook"

    : "${dubBuildRoot:=$NIX_BUILD_TOP}"
    : "${dubArtifactsTimestamp:=1000000000}"
    export DUB_HOME="$dubBuildRoot/.dub"

    if [ -z "${dubDeps-}" ] && [ -z "${dubArtifacts-}" ]; then
        echo "dubHomeSetupHook: one of 'dubDeps' or 'dubArtifacts' must be set."
        exit 1
    fi

    mkdir -p "$DUB_HOME"
    # Registry packages first (the lockfile is authoritative for `packages/`),
    # then the bundle on top — it carries both `packages/` and the `cache/`
    # build outputs, and was produced from the same lockfile.
    if [ -n "${dubDeps-}" ]; then
        cp -a "$dubDeps"/.dub/. "$DUB_HOME"/
    fi
    if [ -n "${dubArtifacts-}" ]; then
        chmod -R u+w "$DUB_HOME"
        cp -a "$dubArtifacts"/. "$DUB_HOME"/
    fi
    chmod -R u+w "$DUB_HOME"

    # Flatten every mtime under `$DUB_HOME` to one instant. The up-to-date
    # test is a strict `source > target`, so equal timestamps read as fresh —
    # and flattening removes the failure mode where `cp` stamps files in
    # directory-traversal order and a dependency's *sources* end up newer than
    # the artifact built from them, cascading a rebuild up the whole chain.
    find "$DUB_HOME" -exec touch -h -d "@$dubArtifactsTimestamp" '{}' +

    echo "Finished dubHomeSetupHook"
}

if [ -z "${dontDubHomeSetup-}" ]; then
    preConfigureHooks+=(dubHomeSetupHook)
fi
