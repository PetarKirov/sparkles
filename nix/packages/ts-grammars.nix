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
#
# Grammars not taken from nixpkgs (or pinned ahead of it):
#  - `sdl` — in-house (nix/packages/tree-sitter-sdl.nix); no SDLang grammar
#    existed upstream.
#  - `d` — pinned to PetarKirov/tree-sitter-d for DUB single-file package
#    recipe injections until that lands in gdamore/tree-sitter-d + nixpkgs
#    (nix/packages/tree-sitter-d.nix).
{
  perSystem =
    { config, pkgs, ... }:
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
      # `d` is pinned separately — see `special` below.
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
            "yaml"
            "zig"
          ]
      );

      special = {
        # Pinned fork: DUB single-file recipe injections in queries/injections.scm.
        d = entry {
          name = "d";
          grammar = config.packages.tree-sitter-d;
        };
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
        # tree-sitter-xml 0.7 is a multi-language repo (xml + dtd). The
        # compiled `parser` ships alone; highlights live at
        # `queries/xml/highlights.scm` in `src`, not `queries/highlights.scm`.
        xml = entry {
          name = "xml";
          grammar = g.tree-sitter-xml;
          highlightsChain = [
            "${g.tree-sitter-xml.src}/queries/xml/highlights.scm"
          ];
        };
        # Not in nixpkgs — ours. The directory name must stay `sdl`: that is
        # what `canonicalLanguage` lowercases a `.sdl` extension to, and the
        # loader derives the `tree_sitter_sdl` symbol from it.
        sdl = entry {
          name = "sdl";
          grammar = config.packages.tree-sitter-sdl;
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
