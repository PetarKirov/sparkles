{ lib, ... }:
{
  perSystem =
    { config, pkgs, ... }:
    let
      # The Android cross-compilation outputs (nix/packages/android/) live in
      # their own aggregate (`all-android`, built by the `nix-build-android`
      # CI job): they multiply the closure by gigabytes (dual-ABI druntimes,
      # the NDK/SDK, the Maple font build) and pull the unfree Android SDK —
      # neither belongs in the desktop cache aggregate. Recognized by naming
      # convention: every android output carries "android" or "-apk" in its
      # name.
      isAndroid = name: lib.hasInfix "android" name || lib.hasInfix "-apk" name;
    in
    {
      # Aggregate of every desktop derivation the `nix-build` CI job builds
      # and pushes to the binary cache: the full dev shell, every
      # (non-Android) package, and every standalone example
      # (examples.<lib>.<name>, flattened). New outputs are picked up
      # automatically — the workflow just runs `nix build .#all-desktop`.
      packages.all-desktop = pkgs.linkFarm "sparkles-all-desktop" (
        {
          devshell-full = config.devShells.full;
        }
        // lib.filterAttrs (name: _: !(isAndroid name)) (
          builtins.removeAttrs config.packages [
            "all-desktop"
            "all-android"
          ]
        )
        // lib.concatMapAttrs (
          libName: lib.mapAttrs' (exName: lib.nameValuePair "example-${libName}-${exName}")
        ) config.legacyPackages.examples
      );
    };
}
