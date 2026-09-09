{ lib, ... }:
{
  perSystem =
    {
      config,
      pkgs,
      inputs',
      ...
    }:
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
      exclusions = import ../flake-exclusions.nix;
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
        # The wasm toolchain (dlang.nix's `ldc-wasm`: the LDC fork, its LLVM
        # binutils, the wasi cross stdenv and `wasm-component-ld`). It is only
        # a *build-time* dependency of `table-wasm`/`text-wasm`, so it is in no
        # output's runtime closure, the `latest-<system>` release pins never
        # retained it, and Cachix evicted it — after which every job that
        # built a wasm module spent its whole time budget recompiling LDC and
        # timed out. As an aggregate member it is pushed by every nix-build
        # run and pinned with each release. Linux only: that is where
        # dlang.nix defines it.
        // lib.optionalAttrs (inputs'.dlang-nix.packages ? ldc-wasm) {
          ldc-wasm-toolchain = inputs'.dlang-nix.packages.ldc-wasm;
        }
        // builtins.removeAttrs config.packages (
          [ "all-desktop" ] ++ androidNames ++ exclusions.excludedCiPackages
        )
        // lib.concatMapAttrs (
          libName: lib.mapAttrs' (exName: lib.nameValuePair "example-${libName}-${exName}")
        ) config.legacyPackages.examples
      );
    };
}
