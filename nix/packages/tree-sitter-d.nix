# The D grammar, pinned to PetarKirov/tree-sitter-d so we pick up DUB
# single-file package recipe injections (`/+ dub.sdl: … +/` / `/+ dub.json: … +/`)
# before they land in upstream gdamore/tree-sitter-d and nixpkgs.
#
# Same packaging shape as tree-sitter-sdl.nix: one `buildGrammar` derivation
# whose `src` the desktop ts-grammars bundle and the Android cross-build both
# consume, so the two cannot drift.
{
  perSystem =
    { pkgs, ... }:
    {
      packages.tree-sitter-d = pkgs.tree-sitter.buildGrammar {
        language = "d";
        # package.json version at the pinned rev.
        version = "0.8.2";
        src = pkgs.fetchFromGitHub {
          owner = "PetarKirov";
          repo = "tree-sitter-d";
          # feat/dub-single-file-injections — query-only change on top of main.
          rev = "065bbbf8acfc7e8ed1e2d99957d669837aec6778";
          hash = "sha256-Zc0283t4mk/iZbpCpd2BrdIfM+ftSoCZbDnMB08/6O4=";
        };
        # No `generate = true`: `src/parser.c` is committed; the pin only
        # changes queries/injections.scm (and helix-injections.scm).

        meta = {
          description = "D grammar for tree-sitter (with DUB single-file recipe injections)";
          homepage = "https://github.com/PetarKirov/tree-sitter-d";
          license = pkgs.lib.licenses.mit;
        };
      };
    };
}
