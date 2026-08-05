# Install `$DUB_HOME` as the derivation's output, so downstream builds can
# inherit it as `dubArtifacts`. The counterpart of dubHomeSetupHook.
#
# The mtimes are flattened again on the way out: `cp -a` inside the sandbox
# preserves them, but a bundle that has been through a binary cache should not
# depend on that.
installDubArtifactsHook() {
    runHook preInstall
    echo "Executing installDubArtifactsHook"

    : "${dubArtifactsTimestamp:=1000000000}"

    mkdir -p "$out"
    cp -a "$DUB_HOME"/. "$out"/
    chmod -R u+w "$out"
    find "$out" -exec touch -h -d "@$dubArtifactsTimestamp" '{}' +

    echo "Finished installDubArtifactsHook"
    runHook postInstall
}
