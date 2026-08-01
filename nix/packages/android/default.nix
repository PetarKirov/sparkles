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
      # The Android CI aggregate (the `nix-build-android` job). Kept out of
      # `all-desktop` (see nix/packages/all.nix).
      #
      # `hue-apk-repo` alone would pull the entire cross closure (dual-ABI
      # druntimes, raylib/tree-sitter/ghostty cross builds, all grammar
      # parsers, the Maple font build, the SDK tooling), so it nearly covers
      # the pipeline on its own — but "nearly" left three outputs with no CI
      # coverage at all:
      #
      #   * `hue-apk` — the command AGENTS.md and docs/specs/hue/android.md
      #     both name as THE way to build the port. It differs from the repo
      #     variant only in its asset bundle, so covering it is one extra
      #     aapt2+apksigner run…
      #   * `hue-android-assets` — …which is what that bundle is: the sample
      #     documents behind AND8, previously built by nothing.
      #   * `hello-apk` — the M1 smoke test. It is the only artifact that
      #     isolates "the D-on-Android spine works" (static druntime in a
      #     .so, android_main → main, EGL bring-up, APK tooling) from "hue
      #     works", which is exactly the bisect you want when the emulator
      #     shows a black screen. Cheap once the closure is warm, and
      #     building it is what stops it rotting.
      packages.all-android = pkgs.linkFarm "sparkles-all-android" {
        hue-apk = config.packages.hue-apk;
        hue-apk-repo = config.packages.hue-apk-repo;
        hello-apk = config.packages.hello-apk;
      };

      # The names this module owns, so nix/packages/all.nix can subtract them
      # instead of guessing from the string "android". A heuristic guarding a
      # multi-GB unfree closure leaks both ways: an Android output that does
      # not happen to contain "android" joins the desktop aggregate (and gets
      # built on macOS), and a *desktop* package that does is silently dropped
      # from CI. Declaring the set makes both impossible.
      #
      # Keep in sync with the `packages.*` assignments across this directory —
      # `all-android` itself included, since the desktop aggregate must not
      # contain it either.
      legacyPackages.androidPackageNames = [
        "all-android"
        "hello-apk"
        "hue-android-assets"
        "hue-apk"
        "hue-apk-repo"
        "libghostty-vt-android"
        "libhello-android"
        "libhue-android"
        "raylib-android"
        "tree-sitter-android"
        "ts-grammars-android"
      ];
    };
}
