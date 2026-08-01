# Android SDK tooling for the nix-native APK pipeline, in two compositions:
# a minimal *build* SDK (aapt2 + zipalign + apksigner from build-tools, plus
# android.jar) that the APK assembly references, and a *dev* SDK that adds
# adb, the emulator and an x86_64 system image for on-emulator testing.
# Keeping them apart is what stops the multi-GB emulator closure becoming a
# build input of every APK — see the note at the compositions below.
#
# This is the one place the repo touches `androidenv`, through a *scoped*
# unfree nixpkgs import — the main `pkgs` stays licence-clean, matching the
# stance of `nix/shells/android.nix` (whose NDK comes from `ldc-android`
# instead; see nix/packages/android/ndk.nix for why the two must not mix).
#
# `lib` comes from the flake-level module args (see nix/shells/android.nix).
{ inputs, lib, ... }:
let
  buildToolsVersion = "35.0.0";
  platformVersion = "35";
in
{
  perSystem =
    { system, ... }:
    let
      androidPkgs = import inputs.nixpkgs {
        inherit system;
        config = {
          allowUnfree = true;
          android_sdk.accept_license = true;
        };
      };

      # Composed TWICE, deliberately.
      #
      # Tool paths are interpolated as strings, so every one of them carries
      # its composition's derivation context: whatever that composition
      # includes becomes a build input of everything that references a single
      # binary from it. Assembling an APK needs three ~10 MB tools — aapt2,
      # zipalign, apksigner — plus android.jar; taking them from an
      # emulator-bearing composition would make the emulator (~1 GB) and the
      # google_apis x86_64 system image (~2-3 GB) build inputs of every APK,
      # downloaded and then *pushed to the binary cache* by CI, for a build
      # phase that never runs either.
      buildSdk = androidPkgs.androidenv.composeAndroidPackages {
        platformVersions = [ platformVersion ];
        buildToolsVersions = [ buildToolsVersion ];
      };

      # The interactive composition: adds the emulator and a system image to
      # boot it against. Referenced only by nix/shells/android.nix.
      devSdk = androidPkgs.androidenv.composeAndroidPackages {
        platformVersions = [ platformVersion ];
        buildToolsVersions = [ buildToolsVersion ];
        # (platform-tools — adb — are always included.)
        includeEmulator = true;
        includeSystemImages = true;
        systemImageTypes = [ "google_apis" ];
        abiVersions = [ "x86_64" ];
      };

      buildSdkRoot = "${buildSdk.androidsdk}/libexec/android-sdk";
      devSdkRoot = "${devSdk.androidsdk}/libexec/android-sdk";
    in
    lib.optionalAttrs (system == "x86_64-linux") {
      legacyPackages.androidSdk = {
        inherit platformVersion devSdkRoot;
        # ── APK assembly (build-apk.nix): the minimal closure ──
        # aapt2, zipalign, apksigner.
        buildTools = "${buildSdkRoot}/build-tools/${buildToolsVersion}";
        # The compile-time framework stubs `aapt2 link -I` resolves against.
        androidJar = "${buildSdkRoot}/platforms/android-${platformVersion}/android.jar";
        # ── Interactive only (nix/shells/android.nix) ──
        # adb, from the same root as the emulator so one ANDROID_SDK_ROOT serves.
        platformTools = "${devSdkRoot}/platform-tools";
      };
    };
}
