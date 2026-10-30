# `legacyPackages.nativeLibs`: the C libraries Sparkles' D packages link,
# grouped by the library that names them, with the `.dev` outputs that carry
# their headers and pkg-config files (ImportC reads both). One list per group,
# shared by `buildSparklesApp`, the examples and the dev shell, so the three
# cannot disagree about what a group needs.
{ lib, ... }:
{
  perSystem =
    { config, pkgs, ... }:
    {
      legacyPackages.nativeLibs = {
        # raylib-text's ImportC shaping bridge and native runtime: FreeType,
        # and the HarfBuzz sparkles:font pins (FTS8, nix/packages/harfbuzz.nix).
        shaping = [
          pkgs.freetype
          pkgs.freetype.dev
          config.packages.harfbuzz
          config.packages.harfbuzz.dev
        ];

        # `libs "vulkan"` in libs/vulkan. The `.dev` output carries
        # `vulkan.pc`, whose `includedir` points at vulkan-headers, so one
        # pkg-config entry supplies both the ImportC include path and the link
        # flags: vulkan-headers ships no `.pc` of its own.
        vulkan = [
          pkgs.vulkan-loader
          pkgs.vulkan-loader.dev
        ];

        # The window system's native libraries, `libs "wayland-client" "xcb" …
        # "xkbcommon-x11"` in libs/wsi: Linux only. `xcb-imdkit` is the X11
        # backend's XIM client, and its `.pc` requires xcb-util.
        wsi = lib.optionals pkgs.stdenv.hostPlatform.isLinux [
          pkgs.wayland
          pkgs.wayland.dev
          pkgs.libxkbcommon
          pkgs.libxkbcommon.dev
          pkgs.libxcb
          pkgs.libxcb.dev
          pkgs.xcb-imdkit
          pkgs.libxcb-util
          pkgs.libxcb-util.dev
        ];
      };
    };
}
