{ lib, ... }:
{
  perSystem =
    { config, pkgs, ... }:
    let
      # The Android cross-compilation outputs (nix/packages/android/) live in
      # their own aggregate (`all-android`, built by the `nix-build-android`
      # CI job): they multiply the closure by gigabytes (dual-ABI druntimes,
      # the NDK/SDK) and pull the unfree Android SDK — neither belongs in the
      # desktop cache aggregate.
      #
      # The android module DECLARES the names it owns rather than this file
      # matching on the string "android". A heuristic leaked in both
      # directions: an Android output not containing the word would join the
      # desktop aggregate and get built on macOS, and a desktop package that
      # did contain it would be silently dropped from CI. (The font build was
      # the live example — it lived under nix/packages/android/ but is a plain
      # cross-platform font package, and is now a first-class desktop output
      # in nix/packages/fonts.nix.)
      #
      # `or [ ]` because the android module only defines its outputs on
      # x86_64-linux; everywhere else there is nothing to subtract.
      androidNames = config.legacyPackages.androidPackageNames or [ ];
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
          # The lean shell the CI jobs actually activate. It must be in the
          # aggregate or it never reaches the binary cache, and every runner
          # rebuilds it from source.
          devshell-ci = config.devShells.ci;
        }
        // builtins.removeAttrs config.packages ([ "all-desktop" ] ++ androidNames)
        // lib.concatMapAttrs (
          libName: lib.mapAttrs' (exName: lib.nameValuePair "example-${libName}-${exName}")
        ) config.legacyPackages.examples
      );
    };
}
