# libghostty-vt cross-built for Android, one static archive per ABI, linked
# into libhue.so (gui_ansi.d's off-screen VT for ` ```ansi ` fences — the only
# ghostty consumer). Ghostty's build.zig carries its own bionic support
# (pkg/android-ndk — zig bundles no Android libc, ziglang/zig#23906): given an
# android target it wires the libc/include/crt paths itself from
# `$ANDROID_NDK_HOME`, which we point at ldc-android's NDK so the sysroot
# matches everything else in the link.
#
# Built with `-Dsimd=false`: the SIMD members (simdutf, highway) are C++ and
# multiply the cross-compile surface for a throughput win an off-screen fence
# decoder never notices. Revisit if a profile ever says otherwise.
{ lib, ... }:
{
  perSystem =
    {
      config,
      inputs',
      pkgs,
      system,
      ...
    }:
    let
      ndk = config.legacyPackages.androidNdk;
      vt = inputs'.ghostty.packages.libghostty-vt;

      # Zig target triple (single-dash; only LDC's -mtriple wants the
      # double-dash spelling). The `.21` suffix pins the Android API level the
      # NDK crt/libs are selected for (matches ndk.minSdk).
      zigTarget =
        abi:
        if abi == "arm64-v8a" then
          "aarch64-linux-android.${ndk.minSdk}"
        else
          "x86_64-linux-android.${ndk.minSdk}";

      vtFor =
        t:
        (vt.override {
          simd = false;
          optimize = "ReleaseFast";
        }).overrideAttrs
          (old: {
            pname = "libghostty-vt-android-${t.abi}";
            zigBuildFlags = old.zigBuildFlags ++ [
              "-Dtarget=${zigTarget t.abi}"
            ];
            env = (old.env or { }) // {
              ANDROID_NDK_HOME = ndk.ndkRoot;
            };
            doCheck = false;
          });

      libghostty-vt-android =
        pkgs.runCommand "libghostty-vt-android-${vt.version}"
          {
            meta = {
              description = "Ghostty VT static library cross-built for Android, per ABI";
              platforms = [ "x86_64-linux" ];
            };
          }
          ''
            mkdir -p $out/lib
            cp -r ${(vtFor (ndk.targets."arm64-v8a")).dev}/include $out/include
            ${lib.concatMapStrings (t: ''
              install -Dm644 ${(vtFor t).dev}/lib/libghostty-vt.a \
                $out/lib/${t.abi}/libghostty-vt.a
            '') (lib.attrValues ndk.targets)}
          '';
    in
    lib.optionalAttrs (system == "x86_64-linux") {
      packages.libghostty-vt-android = libghostty-vt-android;
    };
}
