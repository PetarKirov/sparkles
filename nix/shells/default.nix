{pkgs}:
pkgs.mkShell {
  packages = with pkgs; [
    # devshell niceties
    figlet

    # D toolchain
    dmd
    ldc
    dtools
    dub
  ];

  shellHook = ''
    figlet 'sparkles : *'
  '';
}
