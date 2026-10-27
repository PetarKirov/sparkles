# The store paths Sparkles keeps pinned in its Cachix cache, as data:
# `legacyPackages.<system>.pinTargets.<name>`, pinned as `<name>-<system>`
# with one revision (docs/specs/toolchain/SPEC.md, TC23).
#
# The cache holds 10 GiB, and an unpinned path is evicted once newer pushes
# need the room. A pin keeps a path whose rebuild costs CI the most: none of
# these is on cache.nixos.org, because each is either Sparkles' own toolchain
# or a package the overlay or a Sparkles recipe changes. Packages that are
# cheap to rebuild stay unpinned; they come back from cache or source.
#
# Each entry is the exact derivation the flake's builds use, so the pinned
# path is the one CI asks the cache for.
{ ... }:
{
  perSystem =
    {
      config,
      pkgs,
      inputs',
      lib,
      ...
    }:
    let
      inherit (pkgs.stdenv.hostPlatform) isLinux isx86_64;
      toolchain = inputs'.dlang-nix.packages;
      # CI builds the Android closure and the WebAssembly modules on
      # x86_64 Linux only (.github/workflows/ci.yml; WTD8).
      onX86Linux = isLinux && isx86_64;
    in
    {
      legacyPackages.pinTargets = {
        # The toolchain: the fork's LLVM (hours to build) and the LDC built on
        # it. The binary LDC that bootstraps it is a download, not a build.
        toolchain-llvm-spirv-vulkan = toolchain.llvm-spirv-vulkan;
        toolchain-ldc-vulkan = toolchain.ldc-vulkan;

        # Skia (`sparkles:ui-skia`), the Zig build of libghostty-vt, the
        # Maple Mono build with Sparkles' glyphs, the tree-sitter grammar
        # set, and HarfBuzz at the release `sparkles:font` pins, whose test
        # suite runs on every build.
        skia-sparkles = config.packages.skia;
        inherit (config.packages)
          libghostty-vt
          maple-mono
          ts-grammars
          harfbuzz
          ;
      }
      // lib.optionalAttrs onX86Linux {
        # DMD, whose test suite runs on every build.
        toolchain-dmd = pkgs.dmd;
        toolchain-ldc-android = toolchain.ldc-android;
        # The WebAssembly modules' toolchain, per WASI preview: the drivers
        # (whose closures hold the sysroots: wasi-libc, libc++ and their LTO
        # builds) and the D runtimes. The `ldc-sparkles` around them only wraps
        # the pinned compiler, so it stays unpinned.
        toolchain-wasi-wasip1 = toolchain.wasi-wasip1;
        toolchain-wasi-wasip2 = toolchain.wasi-wasip2;
        toolchain-ldc-sparkles-wasi-runtime-wasip1 = toolchain.ldc-sparkles-wasi-runtime-wasip1;
        toolchain-ldc-sparkles-wasi-runtime-wasip2 = toolchain.ldc-sparkles-wasi-runtime-wasip2;

        # The Android cross libraries the APKs link.
        inherit (config.packages)
          raylib-android
          libghostty-vt-android
          ts-grammars-android
          harfbuzz-android
          freetype-android
          tree-sitter-android
          libkqueue-android
          ;
      };
    };
}
