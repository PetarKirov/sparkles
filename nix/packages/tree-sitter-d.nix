# The D grammar, pinned to PetarKirov/tree-sitter-d so we pick up DUB
# single-file package recipe injections (`/+ dub.sdl: … +/` / `/+ dub.json: … +/`)
# before they land in upstream gdamore/tree-sitter-d and nixpkgs.
#
# Same packaging shape as tree-sitter-sdl.nix: one `buildGrammar` derivation
# whose `src` the desktop ts-grammars bundle and the Android cross-build both
# consume, so the two cannot drift.
{ inputs, ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      packages.tree-sitter-d = pkgs.tree-sitter.buildGrammar {
        language = "d";
        # package.json version at the pinned rev.
        version = "0.8.2";
        # feat/dub-single-file-injections — query-only change on top of main.
        src = inputs.tree-sitter-d-src;
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
