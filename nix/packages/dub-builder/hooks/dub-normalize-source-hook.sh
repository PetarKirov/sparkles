# Unpack the source tree to a *build-path-independent* location.
#
# dub's build ID (the `<config>-<buildtype>-<hash>` directory under
# `$DUB_HOME/cache/<pkg>/<version>/build/`) hashes the absolute paths of the
# package's source files, so the very same sources compiled under two
# different directories land in two different cache entries. Every derivation
# that wants to share artifacts must therefore compile from the *same*
# absolute path — `$NIX_BUILD_TOP/dub-src`, which the Linux sandbox pins to
# `/build/dub-src` for every derivation (`sandbox-build-dir`).
#
# Without the sandbox `$NIX_BUILD_TOP` is a per-build temporary directory and
# the paths differ: artifact reuse silently degrades to a full rebuild. That
# is a slowdown, never a wrong result.
dubNormalizeSourceHook() {
    runHook preUnpack
    echo "Executing dubNormalizeSourceHook"

    : "${dubBuildRoot:=$NIX_BUILD_TOP}"
    export dubTreeRoot="$dubBuildRoot/dub-src"

    mkdir -p "$dubTreeRoot"
    cp -a "$src"/. "$dubTreeRoot"/
    chmod -R u+w "$dubTreeRoot"

    # dub decides "up to date" by comparing mtimes alone (`isUpToDate` in
    # dub/generators/build.d): a target is reused when no source file is
    # *strictly* newer than it. Pin the whole tree to the epoch so an
    # inherited artifact always wins, whatever `cp` did to the timestamps.
    #
    # This deliberately removes dub's only staleness check. What replaces it
    # is Nix itself: an artifact bundle is an input of this derivation, so
    # editing any source changes the bundle's hash and a fresh one is built.
    # The invariant that keeps that sound is that the bundle must be derived
    # from the *same* `src` as its consumer.
    find "$dubTreeRoot" -exec touch -h -d "@1" '{}' +

    cd "$dubTreeRoot/${dubSubdir:-.}"

    echo "Finished dubNormalizeSourceHook"
    runHook postUnpack
}

if [ -z "${dontDubNormalizeSource-}" ] && [ -z "${unpackPhase-}" ]; then
    unpackPhase=dubNormalizeSourceHook
fi
