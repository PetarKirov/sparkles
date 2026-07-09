# Reproducible build of the wasm32-wasip1 module that powers the interactive
# drawTable playground in docs/libs/core-cli/. Uses dlang.nix's `ldc-wasm`
# toolchain (built from the LDC WASI fork) to compile `libs/core-cli/wasm/
# spk_table_wasm.d` against the real `sparkles.core_cli.ui.table`, then shrinks it
# with `wasm-opt`.
#
# Unlike text-wasm, drawTable allocates (GC) and imports `expected` (for name
# resolution only — validateTable is a never-instantiated template), so the build
# adds `libs/core-cli/src`, the `-preview=in -preview=dip1000` flags that
# libs/core-cli/dub.sdl uses, and the `expected` dub package source on the import
# path (fetched via the same `mirror://dub` hash pinned in nix/dub-lock.json).
#
# x86_64-linux only (that is where the `ldc-wasm` toolchain is provided). The
# result is copied to docs/public/spk-table.wasm (see the docs page).
{ inputs, lib, ... }:
{
  perSystem =
    { system, pkgs, ... }:
    lib.optionalAttrs (system == "x86_64-linux") {
      packages.table-wasm =
        let
          ldcWasm = inputs.dlang-nix.packages.${system}.ldc-wasm;
          fs = lib.fileset;
          root = ../..;
          src = fs.toSource {
            inherit root;
            fileset = fs.unions [
              (fs.fileFilter (f: f.hasExt "d") (root + "/libs/base/src"))
              (fs.fileFilter (f: f.hasExt "d") (root + "/libs/core-cli/src"))
              # base.text imports the runner's attributes (in the impl package).
              (fs.fileFilter (f: f.hasExt "d") (root + "/libs/test-runner-impl/src"))
              (root + "/libs/core-cli/wasm")
            ];
          };
          # The `expected` package source — the same artifact buildDubPackage would
          # fetch from nix/dub-lock.json (`mirror://dub/expected/0.4.1.zip`).
          expectedZip = pkgs.fetchurl {
            name = "dub-expected-0.4.1.zip";
            url = "mirror://dub/expected/0.4.1.zip";
            sha256 = "1ahr7gbjl6dgw1qs9x5yzcwhbzfg7ygdlsm9gw4hgmm1xrfcpri0";
          };
        in
        pkgs.stdenv.mkDerivation {
          pname = "spk-table-wasm";
          version = "0.1.0";
          inherit src;

          nativeBuildInputs = [
            ldcWasm
            pkgs.binaryen
            pkgs.unzip
          ];

          buildPhase = ''
            runHook preBuild

            mkdir expected-src
            (cd expected-src && unzip -q ${expectedZip})
            expectedInc=$(dirname "$(find expected-src -path '*/source/expected.d')")

            ldc2 -mtriple=wasm32-wasip1 -O2 -preview=in -preview=dip1000 \
              -I=libs/base/src -I=libs/core-cli/src -I=libs/test-runner-impl/src \
              -I="$expectedInc" -i=sparkles \
              -L--export=spk_buf_ptr -L--export=spk_buf_cap \
              -L--export=spk_table_render -L--export=spk_segment \
              -L--export-if-defined=__wasm_call_ctors \
              libs/core-cli/wasm/spk_table_wasm.d -of=spk-table.wasm

            wasm-opt -Oz --strip-debug --strip-producers spk-table.wasm -o spk-table.opt.wasm

            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            install -Dm644 spk-table.opt.wasm $out/spk-table.wasm
            runHook postInstall
          '';

          meta = {
            description = "sparkles.core_cli.ui.table (drawTable) compiled to wasm (playground backend)";
            platforms = [ "x86_64-linux" ];
          };
        };
    };
}
