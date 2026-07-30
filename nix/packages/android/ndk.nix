# Per-ABI Android NDK cross-compilation table shared by the android package
# derivations (raylib, tree-sitter, grammar parsers, libhue.so). Pure values,
# no derivation of its own.
#
# The NDK is *not* re-derived here: it is the exact NDK `ldc-android` built its
# D runtimes against (the `ndkRoot` passthru), so the C sysroot every native
# dep compiles against matches the one druntime/phobos were linked with — the
# same invariant `nix/shells/android.nix` documents. The unfree Android licence
# stays dlang.nix's concern on this path.
#
# `lib` comes from the flake-level module args (see nix/shells/android.nix for
# why gating on `pkgs.lib` would recurse).
{ lib, ... }:
{
  perSystem =
    { system, inputs', ... }:
    let
      ldcAndroid = inputs'.dlang-nix.packages.ldc-android;
      ndkRoot = ldcAndroid.ndkRoot;
      clangBin = "${ndkRoot}/toolchains/llvm/prebuilt/linux-x86_64/bin";

      # Android 5.0 — matches the API level ldc-android's runtimes and the
      # NDK clang wrappers below target.
      minSdk = "21";

      mkTarget =
        {
          abi,
          triple,
          clangPrefix,
        }:
        {
          inherit abi triple;
          cc = "${clangBin}/${clangPrefix}${minSdk}-clang";
          cxx = "${clangBin}/${clangPrefix}${minSdk}-clang++";
        };
    in
    lib.optionalAttrs (system == "x86_64-linux") {
      legacyPackages.androidNdk = {
        inherit ndkRoot minSdk;
        ar = "${clangBin}/llvm-ar";
        strip = "${clangBin}/llvm-strip";
        nm = "${clangBin}/llvm-nm";
        # raylib's PLATFORM_ANDROID backend compiles this glue in; it defines
        # `ANativeActivity_onCreate`, which only the framework references —
        # final links need `-Wl,-u,ANativeActivity_onCreate` to keep it.
        nativeAppGlue = "${ndkRoot}/sources/android/native_app_glue";
        # Mandatory for every shipped .so with targetSdk 35: Android 15+
        # devices with 16 KB pages reject 4 KB-aligned native libraries.
        pageAlignFlags = "-Wl,-z,max-page-size=16384";
        # One entry per shipped ABI: aarch64 = physical devices, x86_64 =
        # emulator system images. `triple` is the LDC -mtriple spelling (double
        # dash — LDC's ldc2.conf section regexes require the empty vendor).
        targets = {
          "arm64-v8a" = mkTarget {
            abi = "arm64-v8a";
            triple = "aarch64--linux-android";
            clangPrefix = "aarch64-linux-android";
          };
          "x86_64" = mkTarget {
            abi = "x86_64";
            triple = "x86_64--linux-android";
            clangPrefix = "x86_64-linux-android";
          };
        };
      };
    };
}
