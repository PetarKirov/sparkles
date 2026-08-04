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
#  - latex and unison have a nixpkgs grammar but ship no queries anywhere in
#    their source; nvim-treesitter maintains them out-of-tree, so the queries
#    come from `vimPlugins.nvim-treesitter` — the same project nixpkgs
#    generates `tree-sitter-grammars` from, so parser and queries agree.
#  - `fetched` grammars (racket, objc, starlark, ninja, asm, ebnf, lean) are
#    not in nixpkgs at all and are built here from a pinned source. They are
#    what a language gets *instead of* an approximating alias.
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
      langs = import ./ts-grammar-languages.nix;

      # nvim-treesitter's out-of-tree query set: `runtime/queries/<lang>/`.
      ntsQueries = lang: "${pkgs.vimPlugins.nvim-treesitter}/runtime/queries/${lang}";

      # A grammar nixpkgs does not package, built from the pinned revision.
      # `buildGrammar` installs `$out/parser` and copies `$out/queries` when
      # the source has them, so the result drops into `entry` unchanged.
      fetchedSrc =
        pin:
        pkgs.fetchFromGitHub {
          inherit (pin)
            owner
            repo
            rev
            hash
            ;
        };

      fetchedGrammar =
        name: pin:
        pkgs.tree-sitter.buildGrammar (
          {
            language = name;
            version = "0-unstable-${builtins.substring 0 7 pin.rev}";
            src = fetchedSrc pin;
          }
          // pkgs.lib.optionalAttrs (pin ? location) { inherit (pin) location; }
        );

      # Normalize one language directory from a grammar derivation.
      #  - grammar: the derivation providing `parser`
      #  - queriesDir: the directory holding the `*.scm` files (defaults to
      #    `${grammar}/queries`; pass an explicit path for grammars whose
      #    build drops queries or nests them, e.g. `${g.x.src}/queries/x`)
      #  - highlightsChain: optional list of highlights.scm files concatenated
      #    in order (base language first)
      entry =
        {
          name,
          grammar,
          queriesDir ? null,
          highlightsChain ? null,
        }:
        pkgs.runCommand "ts-grammar-${name}" { } (
          ''
            mkdir -p $out/queries
            ln -s ${grammar}/parser $out/parser
          ''
          + (
            if queriesDir != null then
              ''
                cp -r ${queriesDir}/. $out/queries/
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

      # Languages whose nixpkgs output already carries usable queries. The list
      # is shared with the Android soname bundle — see ts-grammar-languages.nix.
      # `d`, `xml` and `sdl` are pinned/surgered separately — see `special` below.
      plain = builtins.listToAttrs (
        map (name: {
          inherit name;
          value = entry {
            inherit name;
            grammar = g."tree-sitter-${name}";
          };
        }) langs.plain
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
          queriesDir = "${g.tree-sitter-ocaml.src}/queries";
        };
        # A nixpkgs grammar whose queries exist only in nvim-treesitter — the
        # source tree has no `.scm` at all. Both were plain text before.
        latex = entry {
          name = "latex";
          grammar = g.tree-sitter-latex;
          queriesDir = ntsQueries "latex";
        };
        unison = entry {
          name = "unison";
          grammar = g.tree-sitter-unison;
          queriesDir = ntsQueries "unison";
        };
        # Same shape as typescript/tsx: a grammar that extends another one and
        # whose queries cover only the extension. Upstream expresses that with
        # neovim's `; inherits:` header comment, which this engine does not
        # implement — so the inheritance is resolved here, by concatenation.
        #  - qmljs extends javascript; its own queries know annotations,
        #    properties and signals but not strings, numbers or comments.
        #  - vue's whole highlights.scm is one `; inherits: html_tags` line
        #    plus directive rules; without the base, a SFC is uncolored.
        qmljs = entry {
          name = "qmljs";
          grammar = g.tree-sitter-qmljs;
          queriesDir = "${g.tree-sitter-qmljs.src}/queries";
          highlightsChain = [
            "${g.tree-sitter-javascript}/queries/highlights.scm"
            "${g.tree-sitter-qmljs.src}/queries/highlights.scm"
          ];
        };
        vue = entry {
          name = "vue";
          grammar = g.tree-sitter-vue;
          queriesDir = "${g.tree-sitter-vue.src}/queries/vue";
          highlightsChain = [
            "${g.tree-sitter-vue.src}/queries/html_tags/highlights.scm"
            "${g.tree-sitter-vue.src}/queries/vue/highlights.scm"
          ];
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
      }
      # Grammars whose nixpkgs output ships no `queries/`: the .scm files live
      # in the source tree, either at its root (fsharp) or under a
      # per-language subdirectory the upstream repo uses to serve several
      # editors (`queries/<lang>/`, `queries/neovim/`). Point at the directory
      # that actually holds them.
      //
        builtins.mapAttrs
          (
            name: subdir:
            entry {
              inherit name;
              grammar = g."tree-sitter-${name}";
              queriesDir = "${g."tree-sitter-${name}".src}/${subdir}";
            }
          )
          {
            fsharp = "queries";
            just = "queries/just";
            matlab = "queries/neovim";
            query = "queries/query";
            tcl = "queries/tcl";
            typst = "queries/typst";
          };

      # Grammars nixpkgs does not package, built from their pinned source.
      fetched = builtins.mapAttrs (
        name: pin:
        entry {
          inherit name;
          grammar = fetchedGrammar name pin;
          # `buildGrammar` only picks up a `queries/` directly under the
          # grammar root; asm nests its own one level down.
          queriesDir = if name == "asm" then "${fetchedSrc pin}/queries/asm" else null;
        }
      ) langs.fetched;

      languages = plain // special // fetched;
    in
    {
      packages.ts-grammars = pkgs.linkFarm "sparkles-ts-grammars" (
        pkgs.lib.mapAttrsToList (name: path: { inherit name path; }) languages
      );
    };
}
