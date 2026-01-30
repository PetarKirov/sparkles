{ pkgs }:
pkgs.mkShell {
  packages = with pkgs; [
    # devshell niceties
    figlet

    # D toolchain
    dmd
    ldc
    dtools
    dub

    mold
  ];

  shellHook = ''
    figlet 'sparkles : *'
  '';
}
