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
{
  perSystem =
    { pkgs, ... }:
    {
      packages.sparkles-font-test-corpus =
        let
          serif = "${pkgs.source-serif}/share/fonts/variable";
          sans = "${pkgs.source-sans}/share/fonts/opentype";
          scheherazade = "${pkgs.scheherazade-new}/share/fonts/truetype";
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
          }
          // faces scheherazade "ScheherazadeNew" [
            "Regular"
            "Medium"
            "SemiBold"
            "Bold"
          ]
          // faces lateef "Lateef" weights
        );
    };
}
