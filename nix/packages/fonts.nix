# The fonts sparkles ships, as first-class packages on every platform.
#
# `maple-mono` is a custom Maple Mono build with OpenType features frozen (see
# ./maple-mono). It started life inside nix/packages/android/ because that is
# where it was first needed, but nothing about it is Android: it is
# `stdenvNoCC`, a pure-Python build, no NDK, no cross-compilation, and
# `meta.platforms = all`. Exposing it here means it can be built, cached and
# installed on its own — and bundled with `sparkles:terminal` the same way the
# APK bundles it.
#
# Uiua386 needs no package of its own: it is `pkgs.uiua386`, already available
# everywhere. It appears in `fontBundle` so the *set* of fonts sparkles ships
# is defined once rather than per consumer.
{ lib, ... }:
{
  perSystem =
    { config, pkgs, ... }:
    let
      maple-mono = pkgs.callPackage ./maple-mono { };

      # One directory holding every font sparkles bundles, plus the `.charset`
      # coverage sidecars `FontSet`'s fontconfig-free path reads.
      #
      # `fc-query` runs HERE, at build time, on purpose: the Android device has
      # no fontconfig, and a bundled desktop build should not need one either
      # (a `--font-dir` consumer is portable precisely because it does not shell
      # out). Both consumers therefore get the same coverage data.
      fontBundle =
        pkgs.runCommand "sparkles-fonts"
          {
            nativeBuildInputs = [ pkgs.fontconfig ];
            meta = {
              description = "The font set sparkles bundles (Maple Mono NF CN, FiraCode Nerd Font Mono, DejaVu Sans Mono, Uiua386) with .charset sidecars";
              platforms = lib.platforms.all;
            };
          }
          ''
            mkdir -p $out/fonts

            # Primary family: Maple Mono NF CN, all four styled faces — the
            # -Bold/-Italic/-BoldItalic siblings the fontconfig-free variant scan
            # resolves by naming convention.
            for f in ${maple-mono}/share/fonts/truetype/*.ttf; do
              case "$(basename "$f")" in
                *-Regular.ttf | *-Bold.ttf | *-Italic.ttf | *-BoldItalic.ttf)
                  cp "$f" $out/fonts/
                  ;;
              esac
            done

            # Nerd-icon fallback. FiraCode ships no italics, so italic text
            # renders upright — the same behaviour as the desktop default.
            for f in FiraCodeNerdFontMono-Regular.ttf FiraCodeNerdFontMono-Bold.ttf; do
              cp ${pkgs.nerd-fonts.fira-code}/share/fonts/truetype/NerdFonts/FiraCode/$f \
                $out/fonts/
            done

            # Regular fallback with full styling.
            for f in DejaVuSansMono.ttf DejaVuSansMono-Bold.ttf \
                DejaVuSansMono-Oblique.ttf DejaVuSansMono-BoldOblique.ttf; do
              cp ${pkgs.dejavu_fonts}/share/fonts/truetype/$f $out/fonts/
            done

            # Uiua's glyph planes, reached through hue's --font-codepoint-map.
            cp ${pkgs.uiua386}/share/fonts/truetype/Uiua386.ttf $out/fonts/

            for font in $out/fonts/*.ttf; do
              fc-query --format=%{charset} "$font" > "$font.charset"
            done
          '';
    in
    {
      packages = {
        inherit maple-mono;
        sparkles-fonts = fontBundle;
      };

      # So the Android asset bundle composes the same set rather than
      # restating it.
      legacyPackages.sparklesFonts = {
        inherit maple-mono fontBundle;
        # The names this module owns. Both join `all-desktop` on every
        # system: a full Maple Mono rebuild measures ~156 s, which is modest
        # against that job's 20-minute budget, and macOS is a first-class
        # target here — `sparkles:terminal` runs there too, so caching the
        # bundle for it is the point of exposing these at all.
        names = [
          "maple-mono"
          "sparkles-fonts"
        ];
      };
    };
}
