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
      dToolchain = import ../d-toolchain.nix { inherit pkgs; };

      envExports = lib.concatStringsSep "\n" (
        lib.mapAttrsToList (name: value: "export ${name}=${lib.escapeShellArg value}") dToolchain.env
      );
      mkSparklesShell =
        greeting:
        pkgs.mkShell {
          packages = [
            # Pre-commit hooks
            pkgs.prek
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
          ]
          ++ lib.optional greeting pkgs.figlet
          ++ dToolchain.packages;
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
