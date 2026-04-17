{ config, pkgs }:
let
  inherit (pkgs) lib;
  inherit (pkgs.stdenv.hostPlatform) system;
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

    # D toolchain
    pkgs.dtools
    pkgs.dub

    # Profiling
    pkgs.tracy
    pkgs.capstone

    pkgs.mold

    # Documentation site
    pkgs.nodejs
    # CI helper (markdown examples, standalone examples, link maintenance)
    config.packages.ci
  ]
  ++ [ dToolchain.ldc ]
  ++ lib.optionals (system == "x86_64-linux") [
    pkgs.dmd
  ];

  shellHook = ''
    ${envExports}
    export GITHUB_TOKEN="$(gh auth token)"
    figlet 'sparkles : *'
  ''
  + config.pre-commit.installationScript;
}
