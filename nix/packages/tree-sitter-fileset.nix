# The fileset query language's grammar, in-house and in this repository
# (docs/specs/fileset-explorer/decisions.md, X6). `src/parser.c` is generated
# from `grammar.js` by `tree-sitter generate` and committed, as upstream
# grammars do; `FXL8` checks that it agrees with the D parser.
{ ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      packages.tree-sitter-fileset =
        let
          args = {
            language = "fileset";
            # Must match tree-sitter.json's `metadata.version`.
            version = "0.1.0";
            src = ./tree-sitter-fileset;
            meta = {
              description = "The fileset explorer's query language, for tree-sitter";
              license = pkgs.lib.licenses.boost;
            };
          };
        in
        pkgs.tree-sitter.buildGrammar (args // { passthru.grammarArgs = args; });
    };
}
