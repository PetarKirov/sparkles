# Grammar bundle for sparkles:syntax — one directory per language holding
# `parser` (the compiled grammar object exporting `tree_sitter_<lang>`) and
# `queries/` (highlights.scm & co in the upstream capture dialect, consumed
# as shipped). The devshell exports the bundle as $SPARKLES_TS_GRAMMAR_PATH;
# grammar-dependent tests skip when the variable is unset.
#
# Per-language packaging quirks are normalized here in the `entry` builder —
# supply-chain mess stays in nix, out of D code:
#  - typescript/tsx outputs ship no queries; upstream keeps them at the repo
#    root and expects javascript's highlights underneath — chained here
#    (base language first: the engine's same-node last-wins rule makes the
#    specific file override).
#  - ocaml's output ships no queries; they live at the src root.
{
  perSystem =
    { pkgs, ... }:
    let
      g = pkgs.tree-sitter-grammars;

      # Normalize one language directory from a grammar derivation.
      #  - grammar: the derivation providing `parser`
      #  - queriesFrom: where to copy `queries/` from (defaults to grammar;
      #    pass e.g. a `src` attr for grammars whose build drops queries)
      #  - highlightsChain: optional list of highlights.scm files concatenated
      #    in order (base language first)
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
            if queriesFrom != null then
              ''
                cp -r ${queriesFrom}/queries/. $out/queries/
              ''
            else if highlightsChain == null then
              ''
                if [ -d ${grammar}/queries ]; then
                  cp -r ${grammar}/queries/. $out/queries/
                fi
              ''
            else
              ""
          )
          + (
            if highlightsChain != null then
              ''
                chmod -R u+w $out/queries
                cat ${pkgs.lib.concatStringsSep " " highlightsChain} > $out/queries/highlights.scm
              ''
            else
              ""
          )
        );

      # Languages whose nixpkgs output already carries usable queries.
      plain = builtins.listToAttrs (
        map
          (name: {
            inherit name;
            value = entry {
              inherit name;
              grammar = g."tree-sitter-${name}";
            };
          })
          [
            "bash"
            "c"
            "c-sharp"
            "cpp"
            "css"
            "d"
            "go"
            "haskell"
            "html"
            "java"
            "javascript"
            "json"
            "kotlin"
            "markdown"
            "markdown-inline"
            "nix"
            "python"
            "rust"
            "scala"
            "toml"
            "xml"
            "yaml"
            "zig"
          ]
      );

      special = {
        typescript = entry {
          name = "typescript";
          grammar = g.tree-sitter-typescript;
          highlightsChain = [
            "${g.tree-sitter-javascript}/queries/highlights.scm"
            "${g.tree-sitter-typescript.src}/queries/highlights.scm"
          ];
        };
        tsx = entry {
          name = "tsx";
          grammar = g.tree-sitter-tsx;
          highlightsChain = [
            "${g.tree-sitter-javascript}/queries/highlights.scm"
            "${g.tree-sitter-tsx.src}/queries/highlights.scm"
          ];
        };
        ocaml = entry {
          name = "ocaml";
          grammar = g.tree-sitter-ocaml;
          queriesFrom = g.tree-sitter-ocaml.src;
        };
      };

      languages = plain // special;
    in
    {
      packages.ts-grammars = pkgs.linkFarm "sparkles-ts-grammars" (
        pkgs.lib.mapAttrsToList (name: path: { inherit name path; }) languages
      );
    };
}
