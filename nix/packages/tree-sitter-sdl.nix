# The SDLang grammar, maintained in-house at PetarKirov/tree-sitter-sdl (built
# to the tree-sitter-grammars contribution standard, pending upstreaming).
#
# It lives in its own package rather than inline in `ts-grammars.nix` because
# the Android cross-build needs the same pinned `src` (nix/packages/android/
# ts-grammars.nix compiles `src/parser.c` itself for each ABI), and one
# definition keeps the two from drifting.
{ inputs, ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      packages.tree-sitter-sdl = pkgs.tree-sitter.buildGrammar {
        language = "sdl";
        # Must match tree-sitter.json's `metadata.version`, or buildGrammar
        # logs a mismatch.
        version = "0.1.0";
        # v0.1.0
        src = inputs.tree-sitter-sdl-src;
        # No `generate = true`: `src/parser.c` is committed, per the upstream
        # convention, and is ABI 15 — inside the [13, 15] window the loader in
        # `libs/tree-sitter` accepts.

        meta = {
          description = "SDLang (Simple Declarative Language) grammar for tree-sitter";
          homepage = "https://github.com/PetarKirov/tree-sitter-sdl";
          license = pkgs.lib.licenses.mit;
        };
      };
    };
}
