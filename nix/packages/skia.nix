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
    let
      inherit (pkgs) lib stdenv;

      # `.so` on Linux, `.dylib` on Darwin.
      soExt = stdenv.hostPlatform.extensions.sharedLibrary;

      # Graphite has no GL backend, so its bring-up entry point differs per
      # platform — and so does which one exists at all. nixpkgs' skia defaults
      # `enableVulkan` to `!isDarwin` and sets `skia_use_metal=true` there, so
      # asserting `MakeVulkan` everywhere would fail the macOS build on a
      # correctly-built library. Matches the plan: Vulkan on Linux/Android,
      # Metal on macOS.
      graphiteEntryPoint =
        if stdenv.hostPlatform.isDarwin then
          {
            mangled = "14ContextFactory9MakeMetal";
            pretty = "skgpu::graphite::ContextFactory::MakeMetal";
          }
        else
          {
            mangled = "14ContextFactory10MakeVulkan";
            pretty = "skgpu::graphite::ContextFactory::MakeVulkan";
          };
    in
    {
      packages.skia = pkgs.skia.overrideAttrs (old: {
        pname = "skia-sparkles";

        # Skia hides almost everything, and that is fatal for how sparkles
        # binds it. `is_official_build=true` implies `-fvisibility=hidden`, so
        # only symbols upstream marked `SK_API` reach libskia.so's dynamic
        # symbol table — 2468 of them in the stock build. The D binding is
        # `extern(C++)` against real mangled symbols with no C shim (plan
        # decision 2), so any entry point upstream forgot to mark is simply
        # unreachable from D.
        #
        # That set is not empty, and the first thing sparkles needs is in it:
        # `skgpu::graphite::ContextFactory::MakeVulkan`, the ONLY way to create
        # a Graphite Vulkan context, is absent from the stock build (verified
        # by hand with `nm -D | c++filt`). It is declared `SK_API` in the
        # shipped header `include/gpu/graphite/vk/VulkanGraphiteContext.h` but
        # defined in `src/gpu/graphite/vk/VulkanGraphiteUtils.cpp`, which never
        # includes that header — whereas its sibling `VulkanBackendTexture.cpp`
        # does include its own public header and exports fine. m153 has the
        # same gap, and its replacement API (`SkContexts::MakeGraphite`) is
        # still a stub returning nullptr.
        #
        # So a targeted patch (adding that include) would plausibly fix this
        # one symbol; it is deliberately NOT the approach taken, and was not
        # measured either way. Exporting everything is the durable answer: it
        # removes a whole class of "upstream forgot the annotation" failures
        # that this binding style would otherwise hit one symbol at a time.
        # Cost: the dynamic symbol table grows 2468 -> 12758 and libskia.so
        # grows 11.6 MB -> 14.1 MB.

        gnFlags = old.gnFlags ++ [
          # See the note above. `extra_cflags_cc` is additive here: the base
          # derivation sets `extra_cflags` (the harfbuzz include path) and
          # never sets this one, so the two do not collide.
          "extra_cflags_cc=[\"-fvisibility=default\"]"

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
        # Every capability above is a claim about the dynamic symbol table, so
        # assert it there. Each has already been observed missing once —
        # Graphite because the flag was off, SVG because `is_component_build`
        # silently disables it, `ContextFactory::MakeVulkan` through the
        # visibility default — and each failed silently, surfacing only as a
        # link error in a consumer much later.
        postInstall = (old.postInstall or "") + ''
          syms="$NIX_BUILD_TOP/skia-dynsyms.txt"
          ${pkgs.buildPackages.binutils}/bin/nm -D --defined-only \
            "$out/lib/libskia${soExt}" > "$syms"
          echo "skia: $(wc -l < "$syms") exported symbols"

          require() {
            grep -q "$1" "$syms" || {
              echo "skia: expected symbol matching '$1' ($2) is not exported" >&2
              exit 1
            }
          }

          # Graphite's context factory — the bring-up entry point, and the
          # symbol that is hidden without `-fvisibility=default`. Vulkan on
          # Linux, Metal on macOS.
          require '${graphiteEntryPoint.mangled}' '${graphiteEntryPoint.pretty}'
          # Graphite itself.
          require '8graphite7Context12makeRecorder' 'skgpu::graphite::Context::makeRecorder'
          # The Ganesh escape hatch. GL only where Skia builds a GL backend —
          # nixpkgs' darwin build is Metal-only.
          ${lib.optionalString (
            !stdenv.hostPlatform.isDarwin
          ) "require 'GrDirectContexts6MakeGL' 'GrDirectContexts::MakeGL'"}
          # The GPU-free raster target the golden-image tests paint into.
          require '10SkSurfaces6Raster' 'SkSurfaces::Raster'

          test -e "$out/lib/libsvg${soExt}" || {
            echo "skia: skia_enable_svg=true did not produce libsvg${soExt}" >&2
            exit 1
          }
        '';

        meta = old.meta // {
          description = "Skia built with Graphite/Vulkan, Ganesh and SVG for sparkles:ui-skia";
        };
      });
    };
}
