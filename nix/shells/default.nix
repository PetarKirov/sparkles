{
  perSystem =
    {
      config,
      pkgs,
      inputs',
      ...
    }:
    let
      inherit (pkgs) lib;
      inherit (config.legacyPackages) d-toolchain;

      envExports = lib.concatStringsSep "\n" (
        lib.mapAttrsToList (name: value: "export ${name}=${lib.escapeShellArg value}") d-toolchain.env
      );
      mkSparklesShell =
        greeting:
        pkgs.mkShell {
          packages = [
            # Pre-commit hooks
            pkgs.prek
            pkgs.lychee
            # Used by :test-utils package
            pkgs.delta
            # Profiling
            pkgs.tracy
            pkgs.capstone
            pkgs.mold
            # Documentation site
            pkgs.nodejs
            # CI helper (markdown examples, standalone examples, link maintenance)
            config.packages.ci

            # libcurl — linked by the gen_unicode_tables generator tool
            # (libs/base/tools), which fetches UCD files via std.net.curl.
            pkgs.curl

            # ghostty
            pkgs.pkg-config
            inputs'.ghostty.packages.libghostty-vt
            inputs'.ghostty.packages.libghostty-vt.dev

            # Independent oracle libraries for the text-conformance harness
            # (bindings under libs/base/tools/text-conformance/bindings). utf8proc
            # is single-output (headers + .pc in `out`); icu/notcurses carry their
            # pkg-config in the `.dev` output.
            pkgs.utf8proc
            pkgs.icu
            pkgs.icu.dev
            pkgs.notcurses
            pkgs.notcurses.dev

            # rendering
            pkgs.raylib
          ]
          # OS-API research examples (docs/research/.../os-apis): the X11 and Wayland
          # ImportC examples are **Linux-only**, so gate these on Linux — `wayland`,
          # `libx11`, etc. refuse to evaluate on darwin. pkg-config (above) resolves
          # the headers via the `.dev` outputs (dub#3085 feeds `--cflags` to ImportC);
          # `xvfb-run` lets the X11 example open a real window on a headless runner.
          ++ lib.optionals pkgs.stdenv.isLinux [
            pkgs.libx11
            pkgs.libx11.dev
            pkgs.xorgproto
            pkgs.wayland
            pkgs.wayland.dev
            pkgs.xvfb-run
          ]
          ++ lib.optional greeting pkgs.figlet
          ++ d-toolchain.packages;
          shellHook = ''
            ${envExports}
            export GITHUB_TOKEN="$(gh auth token)"
            ${lib.optionalString greeting "figlet 'sparkles : *'"}
          ''
          + config.pre-commit.installationScript;
        };
    in
    {
      devShells = {
        # Quiet shell for non-interactive use (LLM agents, scripts, CI).
        default = mkSparklesShell false;
        # Full shell for interactive use — adds the figlet greeting on entry.
        full = mkSparklesShell true;
      };
    };
}
