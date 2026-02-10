{ lib, ... }:
{
  perSystem =
    { ... }:
    {
      pre-commit.settings.hooks.rustfmt.enable = lib.mkForce false;

      # Test data files contain exact byte sequences — no trailing newline
      pre-commit.settings.hooks.end-of-file-fixer.excludes = [ "^libs/core-cli/test/data/" ];
    };
}
