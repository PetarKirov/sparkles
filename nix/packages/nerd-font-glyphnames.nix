# Nerd Fonts' glyphnames.json at the release the flake's nixpkgs ships
# (nerd-fonts 3.4.0), pinned by commit and hash. The packaged fonts carry no
# copy, so it is fetched on its own. The design system's icon table
# (`sparkles.ui.icons`, GLY4) is generated from it by
# apps/ci/tools/gen-icons.d, and checked against it by a sparkles:ui test
# that skips when $SPARKLES_NERD_FONT_GLYPHNAMES is unset.
_: {
  perSystem =
    { pkgs, ... }:
    {
      packages.nerd-font-glyphnames = pkgs.fetchurl {
        name = "nerd-fonts-3.4.0-glyphnames.json";
        url = "https://raw.githubusercontent.com/ryanoasis/nerd-fonts/fa7b859994228a9c8759f99c55a8d31ee92a1b5e/glyphnames.json";
        hash = "sha256-4tENI/W/8L1vBnbpsB2XifzcZW3ntJiilVwncW6kQ5w=";
      };
    };
}
