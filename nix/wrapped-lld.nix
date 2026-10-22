{ pkgs }:
# Keep wasm-ld/lld-link available, but route host ELF links through Nix's
# bintools wrapper, which discovers store-library RPATHs from -L arguments.
if !pkgs.stdenv.hostPlatform.isLinux then
  pkgs.lld
else
  pkgs.symlinkJoin {
    name = "sparkles-lld-${pkgs.lld.version}";
    paths = [ pkgs.lld ];
    postBuild = ''
      rm "$out/bin/ld.lld"
      ln -s ${pkgs.llvmPackages.bintools}/bin/ld.lld "$out/bin/ld.lld"
    '';
  }
