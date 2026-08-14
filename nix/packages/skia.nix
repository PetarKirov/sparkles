# Skia, with the GN flags `sparkles:ui-skia` needs.
#
# This is an override of nixpkgs' `skia`, not a build from source. The
# distinction matters and was measured, because the obvious reading of
# "nixpkgs' libskia.so has zero `skgpu::graphite` symbols" is that Graphite
# needs a from-scratch build with Skia's 53-entry `DEPS` tree synced. It does
# not — Graphite is merely switched off:
#
#   * `//:graphite` (BUILD.gn:1176) depends only on `:core`, `:gpu_shared` and
#     `:vello`, plus the vulkan headers Skia bundles at
#     `include/third_party/vulkan`.
#   * `spirv-tools` is pulled in ONLY under `if (is_debug)`, and nixpkgs builds
#     with `is_official_build=true`.
#   * `vulkan-memory-allocator` and `vulkan-headers` are already `buildInputs`
#     of the nixpkgs derivation under its `enableVulkan` argument, which
#     defaults to on for non-Darwin.
#
# So Graphite costs a flag, and the upstream system-dependency approach
# (harfbuzz, icu, freetype, fontconfig, expat, zlib, libpng, libwebp from
# nixpkgs; `skia_use_dng_sdk=false`, `skia_use_wuffs=false`) carries over
# untouched. If a future flag does need a vendored external — most likely the
# Android cross-build, where the system deps must themselves be cross-built —
# the pattern to copy is nixpkgs' chromium: a generated lock of
# `{url, rev, hash}` triples resolved through `fetchFromGitiles`
# (`pkgs/applications/networking/browsers/chromium/common.nix`), which is the
# same shape as this repo's `nix/dub-lock.json`.
{
  perSystem =
    { pkgs, ... }:
    {
      packages.skia = pkgs.skia.overrideAttrs (old: {
        pname = "skia-sparkles";

        # Upstream bug, hit on the first build of this package: Graphite's
        # Vulkan bring-up entry point is unreachable from a shared library.
        #
        # `src/gpu/graphite/vk/VulkanGraphiteUtils.cpp` DEFINES
        # `skgpu::graphite::ContextFactory::MakeVulkan`, but never includes
        # `include/gpu/graphite/vk/VulkanGraphiteContext.h` — the header that
        # carries the `SK_API` (visibility("default")) declaration. With
        # `is_official_build=true`, and therefore `-fvisibility=hidden`, the
        # definition is compiled hidden and never reaches libskia.so's dynamic
        # symbol table. The shipped header still advertises it, so the failure
        # is a link error at the consumer, not here.
        #
        # Verified absent from all 2468 exported symbols of the stock build and
        # present in neither m144 nor m153; `src/gpu/graphite/dawn/
        # DawnGraphiteUtils.cpp` has the identical omission. m153's replacement
        # API (`SkContexts::MakeGraphite`) is still a stub that returns nullptr,
        # so this is the only route to a Graphite Vulkan context. Upstreamable
        # one-liner; drop this when it lands.
        postPatch = (old.postPatch or "") + ''
          substituteInPlace src/gpu/graphite/vk/VulkanGraphiteUtils.cpp \
            --replace-fail \
              '#include "src/gpu/graphite/vk/VulkanSharedContext.h"' \
              '#include "src/gpu/graphite/vk/VulkanSharedContext.h"
          #include "include/gpu/graphite/vk/VulkanGraphiteContext.h"'
        '';

        gnFlags = old.gnFlags ++ [
          # The renderer sparkles:ui-skia targets. Graphite has no GL backend
          # at all (include/gpu/graphite/ ships dawn/, mtl/ and vk/ only),
          # which is why the Android and macOS stories in the plan are Vulkan
          # and Metal rather than GLES.
          "skia_enable_graphite=true"

          # Ganesh stays enabled beside Graphite as the recorded escape hatch:
          # it is the fallback if Graphite bring-up stalls, and the only route
          # to a GL context on hardware without usable Vulkan.
          "skia_enable_ganesh=true"

          # SVG must be requested explicitly. `gn/skia.gni` derives
          # `skia_enable_svg = !is_component_build`, and nixpkgs builds with
          # `is_component_build=true`, so the shipped package has no SVG at
          # all — which hue's IMG2 (SVG rasterisation) requires.
          "skia_enable_svg=true"

          # The hook the hybrid font decision needs: repo policy resolves the
          # family/style/codepoint-map and hands Skia a directory, rather than
          # Skia's fontconfig manager owning selection.
          "skia_enable_fontmgr_custom_directory=true"

          # Not needed by any sparkles consumer; each is a chunk of closure and
          # build time. Dawn in particular would pull its own DEPS tree.
          "skia_use_dawn=false"
          "skia_enable_skottie=false"
          "skia_enable_pdf=false"
        ];

        # Every capability above is a claim about the dynamic symbol table, so
        # assert it there. Each of these has already been observed missing once
        # — Graphite because the flag was off, SVG because `is_component_build`
        # silently disables it, and `ContextFactory::MakeVulkan` through the
        # visibility bug patched above — and each failed silently, surfacing
        # only as a link error in a consumer much later.
        postInstall = (old.postInstall or "") + ''
          syms=$(${pkgs.buildPackages.binutils}/bin/nm -D --defined-only "$out/lib/libskia.so")

          require() {
            if ! printf '%s\n' "$syms" | grep -q "$1"; then
              echo "skia: expected symbol matching '$1' ($2) is not exported" >&2
              exit 1
            fi
          }

          # Graphite's Vulkan context factory — the bring-up entry point.
          require '14ContextFactory10MakeVulkan' 'skgpu::graphite::ContextFactory::MakeVulkan'
          # Graphite itself.
          require '8graphite7Context11makeRecorder' 'skgpu::graphite::Context::makeRecorder'
          # The Ganesh escape hatch.
          require 'GrDirectContexts6MakeGL' 'GrDirectContexts::MakeGL'
          # The GPU-free raster target the golden-image tests paint into.
          require '10SkSurfaces6Raster' 'SkSurfaces::Raster'

          test -e "$out/lib/libsvg.so" || {
            echo "skia: skia_enable_svg=true did not produce libsvg.so" >&2
            exit 1
          }
        '';

        meta = old.meta // {
          description = "Skia built with Graphite/Vulkan, Ganesh and SVG for sparkles:ui-skia";
        };
      });
    };
}
