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
      # feat/ldc-android: adds the `ldc-android` aarch64 cross-compiler used by
      # the opt-in `devShells.android` (see nix/shells/android.nix). Revert to
      # the default branch once that work merges upstream.
      url = "github:PetarKirov/dlang.nix/feat/ldc-android";
      inputs = {
        flake-compat.follows = "mcl-nixos-modules/flake-compat";
        flake-parts.follows = "flake-parts";
        git-hooks-nix.follows = "git-hooks-nix";
      };
    };

    ghostty = {
      url = "github:ghostty-org/ghostty";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.systems.follows = "systems";
      inputs.flake-compat.follows = "mcl-nixos-modules/flake-compat";
      inputs.home-manager.follows = "mcl-nixos-modules/home-manager";
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
        ./nix/shells/android.nix
      ];
      systems = import inputs.systems;
    };
}
