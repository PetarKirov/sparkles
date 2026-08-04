# The one list of tree-sitter grammars the project ships — imported by both
# consumers so the desktop bundle (nix/packages/ts-grammars.nix) and the
# Android per-ABI sonames (nix/packages/android/ts-grammars.nix) can never
# drift apart. Pure data: no `pkgs`, so either consumer can read it.
#
# Each name is the bundle's directory / soname stem. For `plain` and `special`
# it is also the `pkgs.tree-sitter-grammars.tree-sitter-<name>` attribute, so
# the two sides stay mechanically derivable from one string; a grammar whose
# nixpkgs attribute is spelled differently from the label people write
# (`qmljs` vs `qml`) keeps the *attribute* spelling here and is reached through
# an alias in `canonicalLanguage`
# (libs/syntax/src/sparkles/syntax/ts/registry.d) — the alias layer is where
# naming opinions live, not the packaging layer.
#
# Three sources, in order of preference:
#  - `plain`    — a nixpkgs grammar whose output already carries usable
#                 `queries/`.
#  - `special`  — a nixpkgs grammar needing query surgery: its `.scm` files sit
#                 somewhere else (a per-editor subdirectory, the source root,
#                 or nvim-treesitter), or it extends another grammar and needs
#                 that one's highlights concatenated ahead of its own.
#                 Assembled by hand in nix/packages/ts-grammars.nix; listed
#                 here so the Android side still builds the parser.
#  - `fetched`  — a grammar nixpkgs does not package at all, pinned to the
#                 revision nvim-treesitter locks (its `parsers.lua`) and built
#                 with `pkgs.tree-sitter.buildGrammar`. This is what keeps a
#                 language *real* instead of aliased at an approximation:
#                 `racket`, `objc`, `starlark`, `ninja`, `asm`, `ebnf` and
#                 `lean` all have a grammar, none of them in nixpkgs.
#
# Coverage is a normative requirement: docs/specs/hue/feature-requirements.md
# `LNG2`. Before adding a nixpkgs name, confirm the attribute exists:
#   nix eval nixpkgs#tree-sitter-grammars --apply 'x: builtins.attrNames x'
# To add a `fetched` one, take the pin from nvim-treesitter's parsers.lua and
# compute the hash with:
#   nix-prefetch-url --unpack https://github.com/<owner>/<repo>/archive/<rev>.tar.gz
#   nix hash convert --hash-algo sha256 --to sri <base32>
#
# Still not shipped, and now verified rather than assumed:
#  - `wat`/`wast` — wasm-lsp/tree-sitter-wasm carries no `.scm` in any
#    revision, and neither nvim-treesitter nor helix has queries for them.
#  - SDLang (`dub.sdl`) — the only tree-sitter-sdlang on GitHub
#    (nordlow/tree-sitter-sdlang) has no grammar.js, no parser.c and no
#    queries; it is an empty repository. `sdl` stays aliased to `d`.
#  - Eff, Frank, Asymptote, MetaPost, NSIS, Wolfram, AsciiDoc, RPM spec, BNF —
#    no tree-sitter grammar exists anywhere for these.
{
  # `d`, `xml` and `sdl` are deliberately absent: the desktop bundle pins or
  # query-surgers them in its own `special` set, so listing them here would
  # build a second, wrong derivation that `plain // special` then discards.
  plain = [
    "ada"
    "bash"
    "c"
    "c-sharp"
    "cmake"
    "cpp"
    "css"
    "dart"
    "dockerfile"
    "elixir"
    "go"
    "gomod"
    "gowork"
    "haskell"
    "hocon"
    "html"
    "ini"
    "java"
    "javascript"
    "json"
    "json5"
    "jsonnet"
    "julia"
    "koka"
    "kotlin"
    "llvm"
    "lua"
    "make"
    "markdown"
    "markdown-inline"
    "mermaid"
    "meson"
    "nim"
    "nix"
    "odin"
    "powershell"
    "prisma"
    "proto"
    "python"
    "ruby"
    "rust"
    "scala"
    "scheme"
    "sql"
    "swift"
    "toml"
    "yaml"
    "zig"
  ];

  # Assembled by hand in nix/packages/ts-grammars.nix (query chaining or a
  # `queries/` dir the build drops); the Android side needs only the names.
  special = [
    "xml"
    "fsharp"
    "just"
    "latex"
    "matlab"
    "ocaml"
    "qmljs"
    "query"
    "tcl"
    "tsx"
    "typescript"
    "typst"
    "unison"
    "vue"
  ];

  # Grammars nixpkgs does not package. Pinned to the revision nvim-treesitter
  # locks so the parser and that project's queries agree; `queries` names the
  # subdirectory holding the `.scm` files when the repo keeps them somewhere
  # other than `queries/`, and `location` the grammar root inside a monorepo.
  fetched = {
    asm = {
      owner = "RubixDev";
      repo = "tree-sitter-asm";
      rev = "839741fef4dab5128952334624905c82b40c7133";
      hash = "sha256-AbMSSt3tTjyPe7ksNjBxxsqvdoKmIKymqzisUWrSTT0=";
    };
    ebnf = {
      owner = "RubixDev";
      repo = "ebnf";
      rev = "8e635b0b723c620774dfb8abf382a7f531894b40";
      hash = "sha256-Cch6WCYq9bsWGypzDGapxBLJ0ZB432uAl6YjEjBJ5yg=";
      location = "crates/tree-sitter-ebnf";
    };
    lean = {
      owner = "Julian";
      repo = "tree-sitter-lean";
      # Not an nvim-treesitter language; this is the upstream default branch,
      # which — unlike the revision nixpkgs pins — does ship `queries/`.
      rev = "86c2bcb379fe0b2ad13d8b3411400deff75b2785";
      hash = "sha256-y7KpMnnv8NuUXC9EiqwwflDHMYwXtR0voLfDpdN7614=";
    };
    ninja = {
      owner = "alemuller";
      repo = "tree-sitter-ninja";
      rev = "0a95cfdc0745b6ae82f60d3a339b37f19b7b9267";
      hash = "sha256-e/LpQUL3UHHko4QvMeT40LCvPZRT7xTGZ9z1Zaboru4=";
    };
    objc = {
      owner = "tree-sitter-grammars";
      repo = "tree-sitter-objc";
      rev = "181a81b8f23a2d593e7ab4259981f50122909fda";
      hash = "sha256-7W8ozhQJL+f+tQYz61EZexk9NkMu1pCAP5IIy1m3qak=";
    };
    racket = {
      owner = "6cdh";
      repo = "tree-sitter-racket";
      rev = "54649be8b939341d2d5410b594ab954fe8814bd0";
      hash = "sha256-+pYy/WzjXqTBBxJRBbyFKGOdBd1WZ+AFr8oUWJWR/qU=";
    };
    starlark = {
      owner = "tree-sitter-grammars";
      repo = "tree-sitter-starlark";
      rev = "a453dbf3ba433db0e5ec621a38a7e59d72e4dc69";
      hash = "sha256-iBchBq9NE4QqHc8MbWs4YgzUH6EB0W7RCIk07I6Zm+I=";
    };
  };
}
