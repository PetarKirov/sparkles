# Android SDK tooling for the nix-native APK pipeline: aapt2 + zipalign +
# apksigner (build-tools), android.jar (platforms), adb (platform-tools), and
# the emulator + an x86_64 system image for on-emulator testing.
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

      sdk = androidPkgs.androidenv.composeAndroidPackages {
        platformVersions = [ platformVersion ];
        buildToolsVersions = [ buildToolsVersion ];
        # (platform-tools — adb — are always included.)
        includeEmulator = true;
        includeSystemImages = true;
        systemImageTypes = [ "google_apis" ];
        abiVersions = [ "x86_64" ];
      };

      sdkRoot = "${sdk.androidsdk}/libexec/android-sdk";
    in
    lib.optionalAttrs (system == "x86_64-linux") {
      legacyPackages.androidSdk = {
        inherit
          androidPkgs
          sdk
          sdkRoot
          platformVersion
          ;
        # aapt2, zipalign, apksigner.
        buildTools = "${sdkRoot}/build-tools/${buildToolsVersion}";
        # The compile-time framework stubs `aapt2 link -I` resolves against.
        androidJar = "${sdkRoot}/platforms/android-${platformVersion}/android.jar";
        # adb.
        platformTools = "${sdkRoot}/platform-tools";
      };
    };
}
