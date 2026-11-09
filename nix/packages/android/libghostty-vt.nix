# libghostty-vt cross-built for Android, one static archive per ABI, linked
# into libhue.so (gui_ansi.d's off-screen VT for ` ```ansi ` fences) and
# libterminal.so (the terminal's VT engine). Ghostty's build.zig carries its own bionic support
# (pkg/android-ndk — zig bundles no Android libc, ziglang/zig#23906): given an
# android target it wires the libc/include/crt paths itself from
# `$ANDROID_NDK_HOME`, which we point at ldc-android's NDK so the sysroot
# matches everything else in the link.
#
# Built with SIMD (simdutf, highway), as on the desktop: the terminal parses
# everything a shell prints through it. SIMD is also what links it against
# libc (GhosttyZig.zig: `link_libc = if (cfg.simd) true else null`); without
# libc, pkg/wuffs exports null-returning `calloc`/`free` stubs, weak but
# hidden, which take over every allocation in the shared library the archive
# is linked into (the first 1.0 APKs died in druntime's `_d_dso_registry`).
# The archive's build rejects any such definition.
{ inputs, lib, ... }:
let
  # Whether this system can build Android at all (./host.nix).
  androidHost = import ./host.nix { inherit inputs; };
in
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
      # double-dash spelling). The `.<minSdk>` suffix pins the Android API level
      # the NDK crt/libs are selected for (./min-sdk.nix).
      zigTarget =
        abi:
        if abi == "arm64-v8a" then
          "aarch64-linux-android.${ndk.minSdk}"
        else
          "x86_64-linux-android.${ndk.minSdk}";

      # Zig has no prefix map for Zig code, so the DWARF of its compiler_rt,
      # its std and the package dependencies names wherever zig read them
      # from. Read them from copies in the build directory instead of the
      # store, which keeps zig and the dependency cache out of the closure
      # (toolchain spec TC15; the archives stay unstripped).
      unstoreZig =
        old:
        let
          zig = lib.findFirst (
            p: (p.pname or "") == "zig"
          ) (throw "libghostty-vt: no zig") old.nativeBuildInputs;
        in
        {
          zigBuildFlags = map (f: if f == "${old.deps}" then "../zig-deps" else f) old.zigBuildFlags;
          # Zig 0.17 dropped `zig build --zig-lib-dir`; its `--zig-lib=` must
          # lead the command line, so name the copy through the environment.
          preBuild = (old.preBuild or "") + ''
            cp -r ${old.deps} ../zig-deps
            cp -r ${zig}/lib/zig ../zig-lib
            chmod -R u+w ../zig-deps ../zig-lib
            export ZIG_LIB_DIR=$(realpath ../zig-lib)
          '';
          disallowedReferences = ndk.toolchainPaths ++ [
            zig
            old.deps
          ];
        };

      vtFor =
        t:
        (vt.override {
          optimize = "ReleaseFast";
        }).overrideAttrs
          (
            old:
            unstoreZig old
            // {
              pname = "libghostty-vt-android-${t.abi}";
              zigBuildFlags = (unstoreZig old).zigBuildFlags ++ [
                "-Dtarget=${zigTarget t.abi}"
              ];
              # The SIMD members are C++ compiled against the NDK's libc headers,
              # and their DWARF names the include directories as given. Hand
              # pkg/android-ndk, which reads only
              # `toolchains/llvm/prebuilt/<host>/sysroot`, an NDK in the build
              # directory whose sysroot links to the store, so those paths name
              # /build rather than the NDK (TC15, as unstoreZig above).
              preBuild = (unstoreZig old).preBuild + ''
                for host in ${ndk.ndkRoot}/toolchains/llvm/prebuilt/*; do
                  mkdir -p ../ndk/toolchains/llvm/prebuilt/$(basename $host)
                  ln -s $host/sysroot \
                    ../ndk/toolchains/llvm/prebuilt/$(basename $host)/sysroot
                done
                export ANDROID_NDK_HOME=$(realpath ../ndk)
              '';

              doCheck = false;

              # Target code: the host's strip/ranlib must not touch it (ndk.nix).
              dontStrip = true;
            }
          );

      libghostty-vt-android =
        pkgs.runCommand "libghostty-vt-android-${vt.version}"
          {
            disallowedReferences = ndk.toolchainPaths;
            meta = {
              description = "Ghostty VT static library cross-built for Android, per ABI";
              platforms = (androidHost system).platforms;
            };
          }
          ''
            mkdir -p $out/lib
            cp -r ${(vtFor (ndk.targets."arm64-v8a")).dev}/include $out/include
            ${lib.concatMapStrings (t: ''
              install -Dm644 ${(vtFor t).dev}/lib/libghostty-vt.a \
                $out/lib/${t.abi}/libghostty-vt.a
            '') (lib.attrValues ndk.targets)}

            # The archive must not define libc's allocator: a definition here
            # takes over every caller in the library it is linked into.
            for a in $out/lib/*/libghostty-vt.a; do
              if ${ndk.nm} --defined-only "$a" 2>/dev/null \
                  | grep -E ' [TtWw] (calloc|malloc|realloc|free)$'; then
                echo "$a defines a libc allocator symbol" >&2
                exit 1
              fi
            done
          '';
    in
    lib.optionalAttrs (androidHost system).supported {
      androidPackages.libghostty-vt-android = libghostty-vt-android;
    };
}
