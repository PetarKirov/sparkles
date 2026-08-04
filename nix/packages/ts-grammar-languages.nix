# The one list of tree-sitter grammars the project ships — imported by both
# consumers so the desktop bundle (nix/packages/ts-grammars.nix) and the
# Android per-ABI sonames (nix/packages/android/ts-grammars.nix) can never
# drift apart.
#
# Each name is BOTH the `pkgs.tree-sitter-grammars.tree-sitter-<name>`
# attribute and the bundle's directory / soname stem, so the two sides stay
# mechanically derivable from one string. A grammar whose nixpkgs attribute is
# spelled differently from the label people write (`qmljs` vs `qml`) keeps the
# *attribute* spelling here and is reached through an alias in
# `canonicalLanguage` (libs/syntax/src/sparkles/syntax/ts/registry.d) — the
# alias layer is where naming opinions live, not the packaging layer.
#
# `plain` = grammars whose nixpkgs output already carries usable `queries/`.
# Grammars needing query surgery (typescript/tsx/ocaml, plus the ones whose
# build drops `queries/`) are handled in the `special` set of
# nix/packages/ts-grammars.nix and listed in `special` below so the Android
# side still builds their parsers.
#
# Coverage is a normative requirement: docs/specs/hue/feature-requirements.md
# `LNG2`. Before adding a name, confirm the attribute exists:
#   nix eval nixpkgs#tree-sitter-grammars --apply 'x: builtins.attrNames x'
{
  plain = [
    "ada"
    "bash"
    "c"
    "c-sharp"
    "cmake"
    "cpp"
    "css"
    "d"
    "dart"
    "dockerfile"
    "elixir"
    "fsharp"
    "gas"
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
    "just"
    "koka"
    "kotlin"
    "latex"
    "lean"
    "llvm"
    "lua"
    "make"
    "markdown"
    "markdown-inline"
    "matlab"
    "mermaid"
    "meson"
    "nim"
    "nix"
    "odin"
    "powershell"
    "prisma"
    "proto"
    "python"
    "qmljs"
    "query"
    "ruby"
    "rust"
    "scala"
    "scheme"
    "sql"
    "swift"
    "tcl"
    "toml"
    "typst"
    "unison"
    "vue"
    "wast"
    "wat"
    "xml"
    "yaml"
    "zig"
  ];

  # Assembled by hand in nix/packages/ts-grammars.nix (query chaining or a
  # `queries/` dir the build drops); the Android side needs only the names.
  special = [
    "typescript"
    "tsx"
    "ocaml"
  ];
}
