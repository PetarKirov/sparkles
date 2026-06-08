{ lib, ... }:
{
  perSystem =
    { config, pkgs, ... }:
    {
      # Aggregate of every derivation the `nix-build` CI job builds and pushes
      # to the binary cache: the full dev shell, every package, and every
      # standalone example (examples.<lib>.<name>, flattened). New outputs are
      # picked up automatically — the workflow just runs `nix build .#all`.
      packages.all = pkgs.linkFarm "sparkles-all" (
        {
          devshell-full = config.devShells.full;
        }
        // builtins.removeAttrs config.packages [ "all" ]
        // lib.concatMapAttrs (
          libName: lib.mapAttrs' (exName: lib.nameValuePair "example-${libName}-${exName}")
        ) config.legacyPackages.examples
      );
    };
}
