# The toolchain table (build-graph SPEC §8.1, BGH4): the toolchain of every
# host platform the build graph may build for, keyed by its nixpkgs `config`,
# as `$SPARKLES_TOOLCHAINS` names it (libs/build-graph/src/sparkles/build_graph/platforms.d
# reads it).
#
# Each entry is taken from the same packages the Nix builds use: the build
# platform's from the shell's own toolchain (`pkgs.ldc`, `pkgs.dmd`, the C
# compiler wrapper and lld, so its paths are the ones `PATH` gives), the WASI
# previews' from dlang.nix's `ldc-sparkles` (./wasm-modules.nix), and
# Android's from `ldc-android` and the per-ABI `pkg-config` directory
# (./android). `system` and `canExecute` come from nixpkgs' elaboration of
# the `config`, never restated.
#
# A shell exports the table of the toolchains it carries: the default shell
# and `ci` the build platform and the WASI previews; `nix develop .#android`
# Android's too, whose NDK no other shell should download.
{ inputs, lib, ... }:
let
  androidHost = import ./android/host.nix { inherit inputs; };
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
      build = pkgs.stdenv.buildPlatform;
      llvmAr = lib.getExe' pkgs.llvm-binutils-sparkles "llvm-ar";
      wasiLdc = lib.getExe' inputs'.dlang-nix.packages.ldc-sparkles "ldc2";

      # An entry for the platform nixpkgs elaborates from `config`.
      entryFor =
        platform: attrs:
        {
          inherit (platform) system;
          canExecute = build.canExecute platform;
        }
        //
          lib.optionalAttrs
            (!build.canExecute platform && platform.emulatorAvailable pkgs && !platform.isAndroid)
            {
              # qemu-user cannot run a Bionic program (it needs /system/bin/linker64),
              # so an Android host names no emulator, and its tests are skipped (BGH8).
              emulator = platform.emulator pkgs;
            }
        // attrs;

      native = entryFor build (
        {
          ldc = lib.getExe' pkgs.ldc "ldc2";
          # The C driver the Nix builds and `dub` link with: on macOS the wrapped
          # fork clang LDC's wrapper defaults to (`CC` in ../d-toolchain.nix, TC6).
          cc = if build.isDarwin then "${pkgs.ldc.linkCc}/bin/cc" else "${pkgs.stdenv.cc}/bin/cc";
          archiver =
            if build.isDarwin then "${pkgs.stdenv.cc.bintools}/bin/ar" else "${pkgs.stdenv.cc}/bin/ar";
        }
        # DMD, like the shells', only where dlang.nix builds it (x86-64).
        // lib.optionalAttrs build.isx86_64 { dmd = lib.getExe' pkgs.dmd "dmd"; }
        # lld links on Linux (the build-settings policy); elsewhere the C
        # driver's own linker, as `ci`'s graph driver chose before the table.
        // lib.optionalAttrs build.isLinux { linker = lib.getExe' pkgs.lld-sparkles "ld.lld"; }
      );

      wasip1 = lib.systems.elaborate { config = "wasm32-unknown-wasip1"; };
      wasi = {
        ${wasip1.config} = entryFor wasip1 {
          triple = wasip1.config;
          ldc = wasiLdc;
          archiver = llvmAr;
        };
        # nixpkgs has no wasip2 kernel at this pin (`Unknown kernel: wasip2`),
        # so its `system` and `canExecute` are stated, as wasip1's would be,
        # until nixpkgs elaborates it.
        "wasm32-unknown-wasip2" = {
          system = "wasm32-wasip2";
          canExecute = false;
          triple = "wasm32-unknown-wasip2";
          ldc = wasiLdc;
          archiver = llvmAr;
          emulator = lib.getExe pkgs.wasmtime;
        };
      };

      # Android: one entry per ABI of the NDK table the APKs build against.
      android =
        let
          inherit (androidHost system) ldcAndroid;
          configOf = {
            "arm64-v8a" = "aarch64-unknown-linux-android";
            "x86_64" = "x86_64-unknown-linux-android";
          };
        in
        lib.mapAttrs' (
          _: t:
          let
            platform = lib.systems.elaborate { config = configOf.${t.abi}; };
          in
          lib.nameValuePair platform.config (
            entryFor platform {
              inherit (t) triple;
              ldc = lib.getExe' ldcAndroid "ldc2";
              # The NDK's, as the Nix Android builds archive with (./android/ndk.nix).
              archiver = config.legacyPackages.androidNdk.ar;
              pkgConfigLibdir = "${config.packages.android-pkg-config}/${t.abi}";
            }
          )
        ) config.legacyPackages.androidNdk.targets;

      tableOf =
        hosts:
        pkgs.writeText "sparkles-toolchains.json" (
          builtins.toJSON {
            build = build.config;
            hosts = {
              ${build.config} = native;
            }
            // hosts;
            # The packages whose default configuration builds for another host,
            # and those hosts (./wasm-modules.nix).
            packages = config.legacyPackages.wasmModuleHosts;
          }
        );
    in
    {
      legacyPackages = {
        toolchainTable = tableOf wasi;
      }
      // lib.optionalAttrs (androidHost system).supported {
        toolchainTableAndroid = tableOf (wasi // android);
      };
    };
}
