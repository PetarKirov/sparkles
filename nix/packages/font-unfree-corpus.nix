# Unfree faces sparkles:font is checked against, opt-in: Microsoft's core
# fonts' Arial and Times New Roman hold `JSTF` tables, a second family beside
# the free test corpus's (./font-test-corpus.nix; docs/specs/font/testing.md
# § Shaping, FTS11). Their licence allows
# redistributing only the original installers, so this package is never
# pushed to a binary cache: it is listed in `excludedCiPackages`
# (nix/flake-exclusions.nix), and the dev shell does not reference it. Point
# the oracle at it by hand:
#
#   SPARKLES_FONT_UNFREE_CORPUS=$(nix build --no-link --print-out-paths \
#     .#sparkles-font-unfree-corpus) dub test :font-oracle
{ inputs, lib, ... }:
{
  perSystem =
    { system, pkgs, ... }:
    let
      # Only corefonts is allowed past the unfree check.
      unfree = import inputs.nixpkgs {
        inherit system;
        config.allowUnfreePredicate = p: lib.getName p == "corefonts";
      };
      faces = "${unfree.corefonts}/share/fonts/truetype";
    in
    {
      packages.sparkles-font-unfree-corpus = pkgs.linkFarm "sparkles-font-unfree-corpus" (
        lib.genAttrs [
          "Arial.ttf"
          "Arial_Bold.ttf"
          "Times_New_Roman.ttf"
          "Times_New_Roman_Bold.ttf"
        ] (name: "${faces}/${name}")
      );
    };
}
