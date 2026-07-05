# The extern "C" shim over simdjson + rapidjson for the wired runtime JSON
# bench (libs/wired/bench/runtime/shims/cpp), built once per ISA preset. The
# installed wired-bench-cpp-shim.pc carries the whole link recipe for dub's
# `libs` directive: our static lib, -lstdc++, an rpath to simdjson's shared
# lib, and `Requires: simdjson` for the -L/-l flags and header cflags.
#
# simdjson itself stays the generic nixpkgs build on purpose: it compiles
# every SIMD kernel (up to AVX-512) and picks one at runtime, so a preset
# rebuild would add nothing. rapidjson is header-only; its compile-time SIMD
# gate is set here per preset.
{ lib, ... }:
{
  perSystem =
    { pkgs, ... }:
    let
      fs = lib.fileset;
      presets = import ./wired-bench-isa-presets.nix pkgs;

      shims = ../../libs/wired/bench/runtime/shims;
      src = fs.toSource {
        root = shims;
        fileset = fs.unions [
          (shims + "/include")
          (shims + "/cpp")
        ];
      };

      inherit (pkgs.stdenv) hostPlatform;
      rapidjsonSimd =
        if hostPlatform.isx86_64 then
          "-DRAPIDJSON_SSE42" # both presets are ≥ x86-64-v2 ⊇ SSE4.2
        else if hostPlatform.isAarch64 then
          "-DRAPIDJSON_NEON"
        else
          "";

      mkShim =
        preset:
        pkgs.stdenv.mkDerivation {
          pname = "wired-bench-cpp-shim-${preset.attr}";
          version = "0.1.0";
          inherit src;

          buildInputs = [
            pkgs.simdjson
            pkgs.rapidjson
          ];

          dontConfigure = true;

          buildPhase = ''
            runHook preBuild
            for f in cpp/*.cpp; do
              $CXX -std=c++17 -O2 -fPIC ${preset.cflags} ${rapidjsonSimd} \
                -Iinclude -c "$f" -o "$(basename "$f" .cpp).o"
            done
            $AR rcs libwired-bench-cpp-shim.a ./*.o
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            install -Dm644 libwired-bench-cpp-shim.a $out/lib/libwired-bench-cpp-shim.a
            install -Dm644 include/wired_bench_shim.h $out/include/wired_bench_shim.h
            mkdir -p $out/lib/pkgconfig
            cat > $out/lib/pkgconfig/wired-bench-cpp-shim.pc <<EOF
            Name: wired-bench-cpp-shim
            Description: extern "C" shim over simdjson + rapidjson (${preset.isa} build for the wired runtime bench)
            Version: 0.1.0
            Requires: simdjson
            Cflags: -I$out/include
            Libs: -L$out/lib -lwired-bench-cpp-shim -lstdc++ -Wl,-rpath,${pkgs.simdjson}/lib
            EOF
            runHook postInstall
          '';
        };
    in
    {
      packages = lib.listToAttrs (
        map (p: {
          name = "wired-bench-cpp-shim-${p.attr}";
          value = mkShim p;
        }) presets
      );
    };
}
