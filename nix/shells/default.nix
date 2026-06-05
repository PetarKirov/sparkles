{ config, pkgs }:
let
  inherit (pkgs) lib;
  dToolchain = import ../d-toolchain.nix { inherit pkgs; };

  envExports = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (name: value: "export ${name}=${lib.escapeShellArg value}") dToolchain.env
  );
in
pkgs.mkShell {
  packages = [
    # devshell niceties
    pkgs.figlet

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

    # libsodium C bindings for :crypto (ImportC). pkg-config locates the
    # header dir; .dev carries the headers + libsodium.pc.
    pkgs.pkg-config
    pkgs.libsodium
    pkgs.libsodium.dev
  ]
  ++ dToolchain.packages;

  shellHook = ''
    ${envExports}
    export GITHUB_TOKEN="$(gh auth token)"
    export SODIUM_INCLUDE="$(pkg-config --cflags-only-I libsodium | sed 's/-I//' | tr -d ' ')"
    figlet 'sparkles : *'
  ''
  + config.pre-commit.installationScript;
}
