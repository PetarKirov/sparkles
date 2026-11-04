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
{ inputs, ... }:
{
  perSystem =
    {
      config,
      pkgs,
      inputs',
      lib,
      system,
      ...
    }:
    let
      toolchain = inputs'.dlang-nix.packages;
      # CI builds the Android closure and the WebAssembly modules on
      # x86_64 Linux only (.github/workflows/ci.yml; WTD8).
      onX86Linux = system == "x86_64-linux";
    in
    {
      legacyPackages.pinTargets = {
        # The toolchain source inputs: cached in Cachix to ensure that fresh CI
        # runners substitute them directly via HTTP instead of git-cloning
        # hundreds of megabytes during flake evaluation (TC23).
        toolchain-input-llvm-sparkles = inputs.dlang-nix.inputs.llvm-sparkles;
        toolchain-input-ldc-sparkles = inputs.dlang-nix.inputs.ldc-sparkles;
        toolchain-input-dmd-src = inputs.dmd-src;
        toolchain-input-phobos-src = inputs.phobos-src;

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

        # Heavy library inputs: pinned in Cachix to protect against LRU eviction.
        ghostty-src = inputs.ghostty;
        harfbuzz-source = inputs.harfbuzz-src;
        maple-font-cn-base-src = inputs.maple-font-cn-base;
        json-test-suite-src = inputs.json-test-suite;
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
