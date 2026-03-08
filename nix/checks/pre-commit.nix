{ lib, ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      pre-commit.settings.hooks.rustfmt.enable = lib.mkForce false;

      # Test data files contain exact byte sequences — no trailing newline
      pre-commit.settings.hooks.end-of-file-fixer.excludes = [ "^libs/core-cli/test/data/" ];

      pre-commit.settings.hooks.lychee = {
        enable = true;
        files = "\\.md$";
        entry = lib.mkForce (
          toString (
            pkgs.writeShellScript "lychee-with-auth" ''
              exec ${lib.getExe pkgs.lychee} \
                --config ./lychee.toml \
                --no-progress \
                --cache \
                --header "Authorization: Bearer $GITHUB_TOKEN" \
                "$@"
            ''
          )
        );
      };
    };
}
