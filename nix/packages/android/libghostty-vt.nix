# libghostty-vt cross-built for Android, one static archive per ABI, linked
# into libhue.so (gui_ansi.d's off-screen VT for ` ```ansi ` fences) and
# libterminal.so (the terminal's VT engine). Ghostty's build.zig carries its own bionic support
# (pkg/android-ndk — zig bundles no Android libc, ziglang/zig#23906): given an
# android target it wires the libc/include/crt paths itself from
# `$ANDROID_NDK_HOME`, which we point at ldc-android's NDK so the sysroot
# matches everything else in the link.
#
# Built with `-Dsimd=false`: the SIMD members (simdutf, highway) are C++ and
# multiply the cross-compile surface for a throughput win an off-screen fence
# decoder never notices. Revisit if a profile ever says otherwise.
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
          simd = false;
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
              env = (old.env or { }) // {
                ANDROID_NDK_HOME = ndk.ndkRoot;
              };

              # Without SIMD the library is built without libc
              # (GhosttyZig.zig: `link_libc = if (cfg.simd) true else null`),
              # and pkg/wuffs then exports `calloc`/`free` stubs that return
              # null — weak, but hidden. In an archive linked into a shared
              # library a weak definition in an object still beats libc.so's,
              # and hidden binds every caller in that library to it: druntime's
              # first `calloc` (`_d_dso_registry`) got null and the APKs died
              # in `dlopen`. libc is always in our link, so drop the stubs.
              postPatch = (old.postPatch or "") + ''
                substituteInPlace pkg/wuffs/src/main.zig \
                  --replace-fail 'if (!builtin.link_libc) {' 'if (false) {'
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
