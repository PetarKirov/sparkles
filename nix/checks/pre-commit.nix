{ lib, ... }:
{
  perSystem =
    { ... }:
    {
      pre-commit.settings.hooks.rustfmt.enable = lib.mkForce false;

      # Test data files contain exact byte sequences — no trailing newline
      pre-commit.settings.hooks.end-of-file-fixer.excludes = [ "^libs/core-cli/test/data/" ];

      pre-commit.settings.hooks.lychee = {
        enable = true;
        files = "\\.md$";
        settings = {
          configPath = "./lychee.toml";
          flags = "--no-progress";
        };
      };
    };
}
