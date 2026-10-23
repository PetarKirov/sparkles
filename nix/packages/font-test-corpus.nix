# Faces sparkles:font is tested against but does not ship, exported by the
# dev shell as $SPARKLES_FONT_TEST_CORPUS. The bundle (./fonts.nix) holds no
# CFF2 table, so the variable CFF2 outline differential (docs/specs/font/
# testing.md § Outlines) reads Adobe's variable Source Serif 4 and Source
# Sans 3 from nixpkgs.
{
  perSystem =
    { pkgs, ... }:
    {
      packages.sparkles-font-test-corpus =
        let
          serif = "${pkgs.source-serif}/share/fonts/variable";
          sans = "${pkgs.source-sans}/share/fonts/opentype";
        in
        pkgs.linkFarm "sparkles-font-test-corpus" {
          "SourceSerif4Variable-Roman.otf" = "${serif}/SourceSerif4Variable-Roman.otf";
          "SourceSerif4Variable-Italic.otf" = "${serif}/SourceSerif4Variable-Italic.otf";
          "SourceSans3VF-Upright.otf" = "${sans}/SourceSans3VF-Upright.otf";
          "SourceSans3VF-Italic.otf" = "${sans}/SourceSans3VF-Italic.otf";
        };
    };
}
