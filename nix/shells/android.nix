# Opt-in Android NDK cross-compilation dev shell.
#
# Kept separate from the default shell on purpose: it pulls in the *unfree*
# Android SDK NDK (and you must accept its licence), it is large, and it is only
# useful for the mobile-targeted research examples under
# `docs/research/window-system-integration/os-apis/android/`, which are
# explicitly out of CI scope. Enter it with:
#
#     nix develop .#android
#
# It provides the NDK toolchain (clang wrapper, sysroot headers/libs, the CMake
# toolchain file) plus the host D toolchain, and wires the env vars the research
# example's build command expects (`NDK`, `ANDROID_NDK_ROOT`, `ANDROID_CC`).
#
# The `ldc-android` cross-compiler itself is added in a follow-up commit once
# the dlang.nix branch that provides it is wired in.
# `lib` is taken from the flake-level module args (nixpkgs.lib), NOT `pkgs.lib`:
# gating the *existence* of `devShells.android` on `pkgs.lib` would make the
# module's option structure depend on `pkgs`, which depends back on this module
# (infinite recursion).
{ inputs, lib, ... }:
{
  perSystem =
    {
      system,
      config,
      pkgs,
      ...
    }:
    let
      inherit (config.legacyPackages) d-toolchain;

      # Re-import nixpkgs with the unfree Android licence accepted, scoped to
      # this shell only so the default toolchain/package set stays free.
      androidPkgs = import inputs.nixpkgs {
        inherit system;
        config = {
          allowUnfree = true;
          android_sdk.accept_license = true;
        };
      };
      ndkBundle = (androidPkgs.androidenv.composeAndroidPackages { includeNDK = true; }).ndk-bundle;
      ndkRoot = "${ndkBundle}/libexec/android-sdk/ndk/${ndkBundle.version}";
      ndkClangBin = "${ndkRoot}/toolchains/llvm/prebuilt/linux-x86_64/bin";

      androidShell = pkgs.mkShell {
        packages = [
          pkgs.pkg-config
          ndkBundle
        ]
        ++ d-toolchain.packages;

        shellHook = ''
          export ANDROID_NDK_ROOT=${ndkRoot}
          export ANDROID_NDK_HOME=${ndkRoot}
          export NDK=${ndkRoot}
          export ANDROID_CC=${ndkClangBin}/aarch64-linux-android21-clang
          export PATH=${ndkClangBin}:$PATH
        '';
      };
    in
    # The NDK ships prebuilt for an x86_64-linux host only.
    lib.optionalAttrs (system == "x86_64-linux") {
      devShells.android = androidShell;
    };
}
