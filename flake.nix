{
  inputs = {
    mcl-nixos-modules.url = "github:metacraft-labs/nixos-modules";

    nixpkgs.follows = "mcl-nixos-modules/nixpkgs-unstable";
    flake-parts.follows = "mcl-nixos-modules/flake-parts";

    git-hooks-nix.follows = "mcl-nixos-modules/git-hooks-nix";
  };

  outputs =
    inputs@{ flake-parts, mcl-nixos-modules, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        inputs.git-hooks-nix.flakeModule

        ./nix/packages/default.nix
        ./nix/checks/pre-commit.nix
      ];
      systems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];
      perSystem =
        { config, pkgs, ... }:
        {
          devShells.default = import ./nix/shells/default.nix { inherit config pkgs; };
        };
    };
}
