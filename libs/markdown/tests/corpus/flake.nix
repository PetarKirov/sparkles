{
  description = "Sparkles markdown test corpus source pins";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

    commonmark-spec.url = "github:commonmark/commonmark-spec";
    cmark.url = "github:commonmark/cmark";
    cmark-gfm.url = "github:github/cmark-gfm";

    commonmark-js.url = "github:commonmark/commonmark.js";
    markdown-it.url = "github:markdown-it/markdown-it";
    micromark.url = "github:micromark/micromark";
    marked.url = "github:markedjs/marked";
    nextra.url = "github:shuding/nextra";
    mdx-js.url = "github:mdx-js/mdx";

    pulldown-cmark.url = "github:pulldown-cmark/pulldown-cmark";
    comrak.url = "github:kivikakk/comrak";
    markdown-rs.url = "github:wooorm/markdown-rs";

    md4c.url = "github:mity/md4c";
    goldmark.url = "github:yuin/goldmark";
  };

  outputs =
    { self, nixpkgs, ... }:
    let
      lib = nixpkgs.lib;
    in
    {
      lib.fixtureSources = builtins.fromJSON (builtins.readFile ./sources.json);

      # The fileset is consumed by ingestion tooling to assemble deterministic
      # fixture collections independent from filesystem traversal order.
      lib.fixtureFileset = lib.fileset.unions [
        ./tier_a
        ./tier_b
        ./tier_c
        ./tier_d
        ./generated
      ];
    };
}
