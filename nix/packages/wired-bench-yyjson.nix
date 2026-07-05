# yyjson for the wired runtime JSON bench, built from pinned source once per
# ISA preset (the nixpkgs build is generic; yyjson is deliberately scalar C,
# but the bench's ISA policy is "compile every engine natively"). Installs
# the static lib, the header, and a yyjson.pc so the ImportC binding
# sub-package (libs/wired/bench/runtime/bindings/yyjson) resolves both its
# `libs "yyjson"` link flags and its `#include <yyjson.h>` cflags through
# pkg-config (dub #3085).
{ lib, ... }:
{
  perSystem =
    { pkgs, ... }:
    let
      presets = import ./wired-bench-isa-presets.nix pkgs;

      version = "0.12.0";
      src = pkgs.fetchzip {
        url = "https://github.com/ibireme/yyjson/archive/refs/tags/${version}.tar.gz";
        hash = "sha256-1CYnEgUMUc7eqdkv6M/KyL/MdVQBMov9HgLCycF6++w=";
      };

      mkYyjson =
        preset:
        pkgs.stdenv.mkDerivation {
          pname = "wired-bench-yyjson-${preset.attr}";
          inherit version src;

          dontConfigure = true;

          buildPhase = ''
            runHook preBuild
            $CC -std=c11 -O2 -fPIC ${preset.cflags} -c src/yyjson.c -o yyjson.o
            $AR rcs libyyjson.a yyjson.o
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            install -Dm644 libyyjson.a $out/lib/libyyjson.a
            install -Dm644 src/yyjson.h $out/include/yyjson.h
            mkdir -p $out/lib/pkgconfig
            cat > $out/lib/pkgconfig/yyjson.pc <<EOF
            Name: yyjson
            Description: yyjson (${preset.isa} build for the wired runtime bench)
            Version: ${version}
            Cflags: -I$out/include
            Libs: -L$out/lib -lyyjson
            EOF
            runHook postInstall
          '';
        };
    in
    {
      packages = lib.listToAttrs (
        map (p: {
          name = "wired-bench-yyjson-${p.attr}";
          value = mkYyjson p;
        }) presets
      );
    };
}
