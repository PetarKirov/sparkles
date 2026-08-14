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
  # `platformVersion` is the compile SDK (android.jar) *and* the
  # `--target-sdk-version` aapt2 stamps into every APK, so it is the app's
  # declared target — the API level whose behaviour changes the app opts into.
  #
  # 36 (Android 16) because Google Play stops accepting 35 for new submissions
  # and updates on 2026-08-31. It costs nothing in reach: targetSdk gates
  # behaviour, never installation — that is `ndk.minSdk`'s job — so raising it
  # excludes no device. What it does opt into is Android 16 enforcing
  # edge-to-edge with no way to decline (Android 15 still allowed
  # `windowOptOutEdgeToEdgeEnforcement`; 36 ignores it), which is why the
  # bottom toolbar's insets need checking on a device rather than assumed.
  #
  # `buildToolsVersion` deliberately trails at 35.0.0: aapt2, zipalign and
  # apksigner produce the bytes, and the APK is required to be bit-reproducible
  # (AND1), so their version is changed on its own evidence rather than dragged
  # along by a targetSdk bump. Linking against a newer android.jar with older
  # build-tools is supported and is what we do.
  buildToolsVersion = "35.0.0";
  platformVersion = "36";
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
