# Opt-in Android NDK cross-compilation dev shell.
#
# Kept separate from the default shell on purpose: it pulls in the *unfree*
# Android SDK NDK, it is large, and it is only useful for the mobile-targeted
# research examples under
# `docs/research/window-system-integration/os-apis/android/`, which are
# explicitly out of CI scope. Enter it with:
#
#     nix develop .#android
#
# It provides the `ldc-android` cross-compiler (from dlang.nix) plus the rest of
# the host D toolchain, and wires the env vars the research example's build
# command expects (`NDK`, `ANDROID_NDK_ROOT`, `ANDROID_CC`).
#
# The NDK itself is *not* re-derived here: we reuse the exact NDK that
# `ldc-android` links its runtime against (exposed via its `ndkRoot` passthru),
# so the headers/sysroot used to compile match the one used to link, and the
# unfree Android licence stays entirely dlang.nix's concern — this module never
# touches `androidenv`.
#
# `lib` is taken from the flake-level module args (nixpkgs.lib), NOT `pkgs.lib`:
# gating the *existence* of `devShells.android` on `pkgs.lib` would make the
# module's option structure depend on `pkgs`, which depends back on this module
# (infinite recursion).
{ lib, ... }:
{
  perSystem =
    {
      system,
      pkgs,
      inputs',
      ...
    }:
    let
      # `ldc-android` is a complete LDC (it cross-compiles for Android aarch64
      # *and* builds for the host), so it replaces the plain host `ldc` here —
      # both provide `bin/ldc2`, and we want the cross-capable one to win.
      ldcAndroid = inputs'.dlang-nix.packages.ldc-android;

      ndkRoot = ldcAndroid.ndkRoot;
      ndkClangBin = "${ndkRoot}/toolchains/llvm/prebuilt/linux-x86_64/bin";

      androidShell = pkgs.mkShell {
        packages = [
          pkgs.pkg-config
          # Cross-capable LDC (Android aarch64 + host), plus the rest of the D
          # toolchain. `ldc-android` stands in for the host `ldc`.
          ldcAndroid
          pkgs.dub
          pkgs.dtools
        ];

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
