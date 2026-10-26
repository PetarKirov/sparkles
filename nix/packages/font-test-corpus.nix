# Faces sparkles:font is tested against but does not ship, exported by the
# dev shell as $SPARKLES_FONT_TEST_CORPUS (docs/specs/font/testing.md):
#
# * The bundle (./fonts.nix) holds no CFF2 table, so the variable CFF2
#   outline differential (§ Outlines) reads Adobe's variable Source Serif 4
#   and Source Sans 3 from nixpkgs.
# * The bundle holds no `JSTF` table, so the real-record JSTF check
#   (§ Shaping, FTS11) reads SIL's Scheherazade New, from nixpkgs, and
#   Lateef, from its release. Both are under the OFL, so unlike the unfree
#   corpus (./font-unfree-corpus.nix) they may sit in every binary cache.
# * No bundled variable face varies a vertical advance, so the vertical
#   metric checks (§ Variations, FTM20/FTM21) read Adobe Blank VF, whose
#   `HGHT` axis takes every advance from 0 to 1,000 units (`CFF2` with
#   `VORG`, and `glyf` with `gvar`), and Source Han Sans VF, whose `VVAR`
#   varies 248 vertical origins per face; only the collection's first face
#   is read. Both are under the OFL.
#
# Three directories hold the faces of M2's corpus gates (testing.md
# § Corpus), each listed with its source and licence in the corpus
# manifest, libs/font-oracle/test/goldens/manifest.txt:
#
# * `base/`: real `BASE` tables. Adobe's template (`icfb`/`icft`/`ideo`/
#   `romn` on both axes, `DFLT`/`hani`/`latn`) in CJK Radicals and Tally
#   Marks; a horizontal axis alone in Simon Cozens's baseline test; the
#   variable `BASE` 1.1 (format 3 coordinates through its own item
#   variation store) in Noto Serif JP VF, beside the static Noto Sans JP;
#   Adobe's width and vertical-width prototype; M+ and IPAex, whose
#   script lists have no `DFLT`. Source Han Sans VF and Adobe Blank VF,
#   above, carry `BASE` too.
# * `math/`: `MATH` faces with math kerns (STIX Two Math, KpMath,
#   Garamond-Math, Asana Math) and Latin Modern Math, which has none.
# * `harfbuzz/`: HarfBuzz's own API test fonts from the pinned source,
#   among them its `BASE` (`base.ttf`, `base-minmax.ttf`) and `MATH`
#   (`MathTestFont*.otf`) fixtures.
#
# The suites that read the top level list it shallowly, so these
# directories change none of them.
{ inputs, ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      packages.sparkles-font-test-corpus =
        let
          pinned =
            repo: rev: path: hash:
            pkgs.fetchurl {
              url = "https://raw.githubusercontent.com/${repo}/${rev}/${path}";
              inherit hash;
            };
          notoCjk = pinned "notofonts/noto-cjk" "f8d157532fbfaeda587e826d4cd5b21a49186f7c";
          cjkRadicals = pinned "adobe-fonts/cjk-radicals" "53626cc47e7b4eb28e8499872cd1e16fb0960250";
          widthVF = pinned "adobe-fonts/width-and-vertical-width-vf" "ed4e5c41613f68834a0c1d65b78f872ab4f479d7";
          texFont =
            pkg: dir: file:
            "${pkg.tex}/fonts/opentype/public/${dir}/${file}";
          baseFaces = {
            "BaselineTest-Regular-with-BASE.otf" =
              pinned "simoncozens/test-fonts" "d1cd9d87b8a128b25ed9aaf2e7ccb3a37b0e2a23"
                "BaselineTest-Regular-with-BASE.otf"
                "sha256-EdTquMbHlFyIGem+KZ1Yv8bck8TfxMVEghiKJoHih0M=";
            "CJKRadicals-Regular.otf" =
              cjkRadicals "CJKRadicals-Regular.otf" "sha256-yG6rdK87aKhVGZ8+lVmpUPwzvVe06zIEl8a/HiaQhvU=";
            "CJKRadicals-Regular.ttf" =
              cjkRadicals "CJKRadicals-Regular.ttf" "sha256-YDmRbGNXl+nlEJWJKbusN/hiumJdJ6AfXvfQ+yRxdO0=";
            "TallyMarks-Regular.otf" = pkgs.fetchurl {
              url = "https://github.com/adobe-fonts/tally-marks/releases/download/2.000/TallyMarks-Regular.otf";
              hash = "sha256-K6a88EVrJKzR656p2tJbo8eWDEfh6gGyjdpHbyG8ZdM=";
            };
            "WidthAndVWidthVF.otf" =
              widthVF "WidthAndVWidthVF.otf" "sha256-Yl2uYMhy5RK9Nt00wFYkDPPnoIeZNYYr/lodSdeeHWc=";
            "WidthAndVWidthVF.ttf" =
              widthVF "WidthAndVWidthVF.ttf" "sha256-+a+soIWxBeP4RgTxim1HIwiOVeP6Qqj6C8Ff0Ukh4H4=";
            "NotoSansJP-Regular.otf" =
              notoCjk "Sans/SubsetOTF/JP/NotoSansJP-Regular.otf" "sha256-3/cjulnVfRNnZKBLmy0DIFVE9814WnEUQtbS0IWsUHM=";
            "NotoSerifJP-VF.otf" =
              notoCjk "Serif/Variable/OTF/Subset/NotoSerifJP-VF.otf" "sha256-OXAf0Ja8USBKhETGwmWfAHspZ0oT62Ld+kcGOP6Bec0=";
            "Mplus1-Regular.otf" =
              "${pkgs.mplus-outline-fonts.githubRelease}/share/fonts/opentype/Mplus1-Regular.otf";
            "ipaexg.ttf" = "${pkgs.ipaexfont}/share/fonts/truetype/ipaexg.ttf";
          };
          mathFaces = {
            "STIXTwoMath-Regular.otf" = "${pkgs.stix-two}/share/fonts/opentype/STIXTwoMath-Regular.otf";
            "KpMath-Regular.otf" = texFont pkgs.texlive.pkgs.kpfonts-otf "kpfonts-otf" "KpMath-Regular.otf";
            "Garamond-Math.otf" = texFont pkgs.texlive.pkgs.garamond-math "garamond-math" "Garamond-Math.otf";
            "Asana-Math.otf" = texFont pkgs.texlive.pkgs.asana-math "asana-math" "Asana-Math.otf";
            "LatinModernMath-Regular.otf" = "${pkgs.lmmath}/share/fonts/opentype/latinmodern-math.otf";
          };
          under =
            dir: attrs: pkgs.lib.mapAttrs' (name: value: pkgs.lib.nameValuePair "${dir}/${name}" value) attrs;
          serif = "${pkgs.source-serif}/share/fonts/variable";
          sans = "${pkgs.source-sans}/share/fonts/opentype";
          scheherazade = "${pkgs.scheherazade-new}/share/fonts/truetype";
          adobeBlankVF =
            path: hash:
            pkgs.fetchurl {
              url = "https://raw.githubusercontent.com/adobe-fonts/adobe-blank-vf/24280dc3e7ab4d037e63e4678065b294929d1b8f/${path}";
              inherit hash;
            };
          lateef = pkgs.fetchzip {
            url = "https://github.com/silnrsi/font-lateef/releases/download/v4.400/Lateef-4.400.tar.xz";
            hash = "sha256-cRjx8ohozwUN5cQWGrDD7+jAGmhXvnLHLyt5pQCFQE4=";
          };
          weights = [
            "ExtraLight"
            "Light"
            "Regular"
            "Medium"
            "SemiBold"
            "Bold"
            "ExtraBold"
          ];
          faces =
            dir: family: names:
            builtins.listToAttrs (
              map (w: {
                name = "${family}-${w}.ttf";
                value = "${dir}/${family}-${w}.ttf";
              }) names
            );
        in
        pkgs.linkFarm "sparkles-font-test-corpus" (
          {
            "SourceSerif4Variable-Roman.otf" = "${serif}/SourceSerif4Variable-Roman.otf";
            "SourceSerif4Variable-Italic.otf" = "${serif}/SourceSerif4Variable-Italic.otf";
            "SourceSans3VF-Upright.otf" = "${sans}/SourceSans3VF-Upright.otf";
            "SourceSans3VF-Italic.otf" = "${sans}/SourceSans3VF-Italic.otf";
            "AdobeBlankVF.otf" =
              adobeBlankVF "OTF/AdobeBlankVF.otf" "sha256-8b6XNlkhkpoJifAzO0k4nyT0Hxuw23rpEOwG2K5G/8c=";
            "AdobeBlankVF.ttf" =
              adobeBlankVF "TTF/AdobeBlankVF.ttf" "sha256-IwUq/QVHunfUvGV6qIxa0iq31BwIfRGxIIt63WlIcjg=";
            "SourceHanSans-VF.otf.ttc" =
              "${pkgs.source-han-sans-vf-otf}/share/fonts/variable/SourceHanSans-VF.otf.ttc";
          }
          // faces scheherazade "ScheherazadeNew" [
            "Regular"
            "Medium"
            "SemiBold"
            "Bold"
          ]
          // faces lateef "Lateef" weights
          // under "base" baseFaces
          // under "math" mathFaces
          // {
            harfbuzz = "${inputs.harfbuzz-src}/test/api/fonts";
          }
        );
    };
}
