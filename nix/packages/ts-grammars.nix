# Grammar bundle for sparkles:syntax — one directory per language holding
# `parser` (the compiled grammar object exporting `tree_sitter_<lang>`) and
# `queries/` (highlights.scm & co in the upstream capture dialect, consumed
# as shipped). The devshell exports the bundle as $SPARKLES_TS_GRAMMAR_PATH;
# grammar-dependent tests skip when the variable is unset.
#
# Per-language packaging quirks (grammars whose nixpkgs output ships no
# queries, chained highlight files, multi-grammar repos) are normalized here
# in the `entry` builder — supply-chain mess stays in nix, out of D code.
{
  perSystem =
    { pkgs, ... }:
    let
      g = pkgs.tree-sitter-grammars;

      # Normalize one language directory from a grammar derivation.
      #  - grammar: the derivation providing `parser`
      #  - queriesFrom: where to copy `queries/` from (defaults to grammar;
      #    pass e.g. `src` attrs for grammars whose build drops queries)
      #  - highlightsChain: optional list of highlights.scm files concatenated
      #    in order (base language first — the engine's later-pattern-wins
      #    rule makes the specific file override when listed last)
      entry =
        {
          name,
          grammar,
          queriesFrom ? null,
          highlightsChain ? null,
        }:
        pkgs.runCommand "ts-grammar-${name}" { } (
          ''
            mkdir -p $out/queries
            ln -s ${grammar}/parser $out/parser
          ''
          + (
            if highlightsChain != null then
              ''
                cat ${pkgs.lib.concatStringsSep " " highlightsChain} > $out/queries/highlights.scm
              ''
            else if queriesFrom != null then
              ''
                cp -r ${queriesFrom}/queries/. $out/queries/
              ''
            else
              ''
                if [ -d ${grammar}/queries ]; then
                  cp -r ${grammar}/queries/. $out/queries/
                fi
              ''
          )
        );
    in
    {
      packages.ts-grammars = pkgs.linkFarm "sparkles-ts-grammars" [
        {
          name = "json";
          path = entry {
            name = "json";
            grammar = g.tree-sitter-json;
          };
        }
      ];
    };
}
