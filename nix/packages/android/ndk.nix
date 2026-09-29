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
# Nothing here names the build host. The NDK files its LLVM toolchain under a
# per-host directory (`toolchains/llvm/prebuilt/linux-x86_64`, `…/darwin-x86_64`),
# and `ldc-android` already resolved it for the host it was built for
# (`ndkToolchain`), so every path below follows the host without restating
# the table. What varies per *target* is `targets`, and it is the same on every
# host: an APK built on a Mac and one built on Linux carry the same ABIs.
#
# Every derivation that produces target code sets `dontStrip = true`. stdenv's
# fixup strips with the HOST binutils and then re-runs the host `ranlib` over
# every `.a` (its errors silenced). On macOS that is cctools, which rewrites an
# ELF archive with a Mach-O style `__.SYMDEF SORTED` symbol table that lld
# rejects as "truncated or malformed"; on Linux, GNU strip quietly strips the
# x86_64 archives and not the aarch64 ones. The shipped `.so` files are
# stripped deliberately, with this NDK's `strip`, by buildAndroidApk.
#
# `lib` comes from the flake-level module args (see nix/shells/android.nix for
# why gating on `pkgs.lib` would recurse).
{ inputs, lib, ... }:
let
  # Whether this system can build Android at all (./host.nix).
  androidHost = import ./host.nix { inherit inputs; };
in
{
  perSystem =
    { system, ... }:
    let
      inherit (androidHost system) ldcAndroid;
      ndkRoot = ldcAndroid.ndkRoot;
      clangBin = "${ldcAndroid.ndkToolchain}/bin";

      # Android 10. The single source of truth for the API level: the NDK
      # clang wrappers below, every native dependency's platform flag, the
      # driver every D link goes through (build-d-android-lib.nix), and the
      # `--min-sdk-version` aapt2 stamps into the APK (build-apk.nix) all read
      # it, so the declared floor cannot drift from the one the code was built
      # against.
      #
      # The constraints that set it, the highest one winning:
      #
      #   23  libkqueue's monitor thread waits on `sigwaitinfo`, which bionic
      #       hides below 23 (`__INTRODUCED_IN`) — see libkqueue.nix.
      #   26  the Skia/Graphite/Vulkan GUI backend.
      #   29  LDC's static druntime uses native ELF TLS, and every D library
      #       therefore references `__tls_get_addr`, which bionic exports from
      #       API 29. This was the real floor while minSdk still claimed 26:
      #       the APK installed on API 26–28 and then failed to load its .so
      #       ("cannot locate symbol __tls_get_addr"). Found by the terminal
      #       port (docs/specs/terminal/android.md), measured with llvm-nm
      #       against each API level's libc stub.
      #
      # Raising it is monotone-safe (a higher `__ANDROID_API__` only unhides
      # declarations), but *lowering* the floor under installed users is not:
      # a minSdk increase silently drops devices out of the update path and
      # F-Droid offers no migration for that. So it is set to its intended
      # long-term value now, before anything is published.
      minSdk = "29";

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
    lib.optionalAttrs (androidHost system).supported {
      legacyPackages.androidNdk = {
        inherit ndkRoot minSdk;
        ar = "${clangBin}/llvm-ar";
        strip = "${clangBin}/llvm-strip";
        nm = "${clangBin}/llvm-nm";
        # raylib's PLATFORM_ANDROID backend compiles this glue in; it defines
        # `ANativeActivity_onCreate`, which only the framework references —
        # final links need `-Wl,-u,ANativeActivity_onCreate` to keep it.
        nativeAppGlue = "${ndkRoot}/sources/android/native_app_glue";
        # ImportC's preprocessor is the HOST cc (ldc2 shells out to it), so a
        # cross build must point it at the NDK's headers explicitly — this is
        # what lets `jni_c.c` resolve <jni.h> and the JNI bridge live in D
        # instead of a hand-written C file. ABI-independent.
        sysrootInclude = "${ldcAndroid.ndkToolchain}/sysroot/usr/include";
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
