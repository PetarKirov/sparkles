# Nix-pinned foreign syntax-highlighter panel for the sparkles:syntax render
# benchmark (libs/syntax/bench/render/foreign). Four other highlighters run the
# same corpus end-to-end so we can place our ANSI/HTML renderers against them:
#
#   bat        (syntect / Sublime-syntax)      ANSI only         — pkgs.bat
#   chroma     (Go, Pygments-derived)          ANSI + HTML       — pkgs.chroma
#   pygmentize (Pygments)                       ANSI + HTML       — pkgs.python3Packages.pygments
#   shiki-html (TextMate / VS Code grammars)   HTML only         — buildNpmPackage below
#
# The first three are stock nixpkgs binaries; only shiki needs real packaging.
# It is a tiny Node CLI (nix/packages/shiki-cli) over `codeToHtml`, built from a
# checked-in package-lock.json so the whole grammar/theme set is pinned.
#
# Everything is collected into a single `packages.syntax-foreign` linkFarm whose
# bin/ holds runnable wrappers: `bat`, `chroma`, `pygmentize`, `shiki-html`. The
# D foreign runner discovers them via $SYNTAX_FOREIGN (the linkFarm's bin dir)
# or an explicit path argument.
{ lib, ... }:
{
  perSystem =
    { pkgs, ... }:
    let
      # The shiki CLI: `shiki-html <file> <lang> [theme]` → HTML on stdout.
      shiki-cli = pkgs.buildNpmPackage {
        pname = "shiki-html-cli";
        version = "0.1.0";
        src = lib.fileset.toSource {
          root = ./shiki-cli;
          fileset = lib.fileset.unions [
            ./shiki-cli/package.json
            ./shiki-cli/package-lock.json
            ./shiki-cli/cli.mjs
          ];
        };
        npmDepsHash = "sha256-ZYgonGJURpRQ2Q+wKdlnkbkWy1JtAnPnztfZg55MFHA=";
        # Pure-JS package: nothing to compile, and there is no build script.
        dontNpmBuild = true;
        meta.mainProgram = "shiki-html";
      };

      pygments = pkgs.python3Packages.pygments;
    in
    {
      packages.syntax-foreign = pkgs.linkFarm "syntax-foreign" [
        {
          name = "bin/bat";
          path = lib.getExe pkgs.bat;
        }
        {
          name = "bin/chroma";
          path = lib.getExe pkgs.chroma;
        }
        {
          name = "bin/pygmentize";
          path = "${pygments}/bin/pygmentize";
        }
        {
          name = "bin/shiki-html";
          path = lib.getExe shiki-cli;
        }
      ];

      # Also expose shiki on its own so it can be built/debugged in isolation.
      packages.syntax-foreign-shiki = shiki-cli;
    };
}
