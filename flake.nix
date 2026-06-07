{
  inputs = {
    mcl-nixos-modules = {
      url = "github:metacraft-labs/nixos-modules";
      inputs.dlang-nix.follows = "dlang-nix";
    };

    nixpkgs.follows = "mcl-nixos-modules/nixpkgs-unstable";
    flake-parts.follows = "mcl-nixos-modules/flake-parts";

    git-hooks-nix.follows = "mcl-nixos-modules/git-hooks-nix";

    systems.url = "github:nix-systems/triplet";

    dlang-nix = {
      url = "github:PetarKirov/dlang.nix";
      inputs = {
        flake-compat.follows = "mcl-nixos-modules/flake-compat";
        flake-parts.follows = "flake-parts";
        git-hooks-nix.follows = "git-hooks-nix";
      };
    };
  };
  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        inputs.git-hooks-nix.flakeModule
        ./nix/d-toolchain.nix
        ./nix/packages/default.nix
        ./nix/checks/pre-commit.nix
        ./nix/shells/default.nix
      ];
      systems = import inputs.systems;
    };
}
