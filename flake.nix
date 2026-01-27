{
  inputs = {
    mcl-nixos-modules.url = "github:metacraft-labs/nixos-modules";

    nixpkgs.follows = "mcl-nixos-modules/nixpkgs";
    flake-parts.follows = "mcl-nixos-modules/flake-parts";
  };

  outputs =
    inputs@{ flake-parts, mcl-nixos-modules, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        mcl-nixos-modules.modules.flake.git-hooks
      ];
      systems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];
      perSystem =
        { pkgs, ... }:
        {
          devShells.default = import ./nix/shells/default.nix { inherit pkgs; };
        };
    };
}
