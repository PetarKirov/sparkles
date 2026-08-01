# The Android packaging tree for the hue port: SDK tooling (sdk.nix), the
# per-ABI NDK cross-compilation table (ndk.nix), and — as the port progresses —
# the cross-built native dependencies (raylib, tree-sitter, grammar parsers,
# libghostty-vt), the `libhue.so` build, and the nix-native APK assembly
# (aapt2 + zipalign + apksigner; no Gradle, no Java — a pure NativeActivity
# APK with `hasCode="false"`).
#
# Everything in here is opt-in, x86_64-linux-only (the NDK/SDK ship prebuilt
# for that host alone), and pulls *unfree* Android SDK components through a
# scoped nixpkgs import — nothing in the default package set references it.
{ lib, ... }:
{
  imports = [
    ./build-apk.nix
    ./hello.nix
    ./hue.nix
    ./libghostty-vt.nix
    ./ndk.nix
    ./raylib.nix
    ./sdk.nix
    ./tree-sitter.nix
    ./ts-grammars.nix
  ];

  perSystem =
    {
      config,
      pkgs,
      system,
      ...
    }:
    lib.optionalAttrs (system == "x86_64-linux") {
      # The Android CI aggregate (the `nix-build-android` job): just the
      # repo-embedded APK — building it pulls the entire Android closure
      # (dual-ABI druntimes, raylib/tree-sitter/ghostty cross builds, all
      # grammar parsers, the Maple font build, the SDK tooling) as build
      # dependencies, so one output covers the whole pipeline. Kept out of
      # `all-desktop` (see nix/packages/all.nix).
      packages.all-android = pkgs.linkFarm "sparkles-all-android" {
        hue-apk-repo = config.packages.hue-apk-repo;
      };
    };
}
