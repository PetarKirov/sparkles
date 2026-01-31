{ pkgs }:
let
  inherit (pkgs) lib;
  inherit (pkgs.stdenv.hostPlatform) system;
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
    pkgs.ldc
    pkgs.dtools
    pkgs.dub

    pkgs.mold
  ]
  ++ lib.optionals (system == "x86_64-linux") [
    pkgs.dmd
  ];

  shellHook = ''
    figlet 'sparkles : *'
  '';
}
