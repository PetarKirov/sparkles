# E6's deliberately local compiler workload. Run inside the app-owned Nix
# session with its pinned nixpkgs channel, then use --check to rebuild it.
{
  pkgs ? import <nixpkgs> { },
}:
pkgs.stdenv.mkDerivation {
  name = "sparkles-android-e6-local-build";
  dontUnpack = true;
  source = pkgs.writeText "main.c" ''
    #include <stdio.h>
    int main(void) {
        puts("android-exec-local-build-ok");
        return 0;
    }
  '';
  buildPhase = ''
    $CC "$source" -o probe
  '';
  doCheck = true;
  checkPhase = ''
    ./probe
  '';
  installPhase = ''
    mkdir -p $out/bin
    cp probe $out/bin/probe
  '';
}
