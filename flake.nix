{
  nixConfig = {
    extra-substituters = [
      "https://sparkles.cachix.org"
      "https://dlang-community.cachix.org"
    ];
    extra-trusted-public-keys = [
      "sparkles.cachix.org-1:CPQ+GG8UKQCNUyvCrgZj8p7P+7cYqpjmGAmUPlLwbZc="
      "dlang-community.cachix.org-1:eAX1RqX4PjTDPCAp/TvcZP+DYBco2nJBackkAJ2BsDQ="
    ];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";

    git-hooks-nix = {
      url = "github:cachix/git-hooks.nix";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-compat.follows = "flake-compat";
      };
    };

    systems.url = "github:nix-systems/triplet";

    dlang-nix = {
      # feat/ldc-wasm: extends feat/ldc-android (the `ldc-android` aarch64 cross-
      # compiler used by `devShells.android`) with the `ldc-wasm` wasm32-wasip2
      # toolchain consumed by `packages.text-wasm`. Revert toward the default
      # branch once these land upstream.
      url = "github:PetarKirov/dlang.nix/feat/ldc-wasm";
      inputs = {
        flake-compat.follows = "flake-compat";
        flake-parts.follows = "flake-parts";
        git-hooks-nix.follows = "git-hooks-nix";
      };
    };

    ghostty = {
      url = "github:ghostty-org/ghostty";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.systems.follows = "systems";
      inputs.flake-compat.follows = "flake-compat";
    };

    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };
  };
  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        inputs.git-hooks-nix.flakeModule
        ./nix/d-toolchain.nix
        ./nix/packages/all.nix
        ./nix/packages/default.nix
        ./nix/packages/text-wasm.nix
        ./nix/packages/table-wasm.nix
        ./nix/packages/uwidth-rs.nix
        ./nix/packages/wired-bench-data.nix
        ./nix/packages/wired-bench-yyjson.nix
        ./nix/packages/wired-bench-cpp-shim.nix
        ./nix/packages/wired-bench-rs.nix
        ./nix/checks/pre-commit.nix
        ./nix/shells/default.nix
        ./nix/shells/android.nix
      ];
      systems = import inputs.systems;
    };
}
