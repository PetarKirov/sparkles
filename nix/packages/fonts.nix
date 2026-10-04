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
{ inputs, lib, ... }:
{
  perSystem =
    { config, pkgs, ... }:
    let
      maple-mono = pkgs.callPackage ./maple-mono {
        src = inputs.maple-font;
        cnBaseStatic = inputs.maple-font-cn-base;
        ufoExtractorWheel = inputs.ufo-extractor-wheel;
      };

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
              description = "Bundled monospace, Roboto interface, Noto Sans Unicode fallback and Noto Color Emoji fonts with .charset sidecars";
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

            # The interface face (design-system `GLY10`): chrome text in
            # `FontRole.ui`, bundled for Android, whose system faces are variable
            # fonts a raylib atlas cannot weight, and as the desktop's fallback.
            for f in Roboto-Regular.ttf Roboto-Bold.ttf; do
              cp ${pkgs.roboto}/share/fonts/truetype/$f $out/fonts/
            done

            # Uiua's glyph planes, reached through hue's --font-codepoint-map.
            cp ${pkgs.uiua386}/share/fonts/truetype/Uiua386.ttf $out/fonts/

            # Full script coverage, without duplicating every weight/style.
            # nixpkgs normalizes variable-font names to NotoSans<Script>.ttf;
            # scripts without variable fonts use the regular static face.
            find ${pkgs.noto-fonts}/share/fonts/noto -type f \
              \( -name 'NotoSans*.ttf' -o -name 'NotoSans*.otf' \) \
              \( -name '*-Regular.*' -o ! -name '*-*' \) \
              -exec cp '{}' $out/fonts/ \;
            cp ${pkgs.noto-fonts-color-emoji}/share/fonts/noto/NotoColorEmoji.ttf $out/fonts/

            # The binary font outputs omit upstream licenses. Retain the
            # original notices from their pinned sources, with source-relative
            # paths so per-family copyright notices cannot overwrite each other.
            for source in ${pkgs.noto-fonts.src} ${pkgs.noto-fonts-color-emoji.src}; do
              case "$source" in
                ${pkgs.noto-fonts.src}) family=noto-sans ;;
                *) family=noto-color-emoji ;;
              esac
              mkdir -p "$out/licenses/$family"
              (cd "$source" && find . -type f \
                \( -iname '*license*' -o -iname '*licence*' -o -iname 'OFL*' -o -iname 'NOTICE*' \) \
                -exec cp --parents '{}' "$out/licenses/$family/" \;)
            done

            cat > $out/NOTICE <<'EOF'
            Maple Mono NF CN and FiraCode Nerd Font Mono: OFL-1.1.
            DejaVu Sans Mono: Bitstream Vera + Arev.
            Roboto: OFL-1.1, https://github.com/googlefonts/roboto-3-classic.
            Uiua386: MIT.
            Noto Sans Unicode fallback fonts: OFL-1.1, https://notofonts.github.io.
            Noto Color Emoji: OFL-1.1, https://github.com/googlefonts/noto-emoji.
            Original Noto license and copyright notices accompany this bundle in licenses/.
            EOF

            find $out/fonts -type f \( -name '*.ttf' -o -name '*.otf' \) -print0 \
              | while IFS= read -r -d "" font; do
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
