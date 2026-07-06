# Reproducible build of the wasm32-wasip1 module that powers the interactive
# cell-explorer widget in docs/specs/base/text/. Uses dlang.nix's `ldc-wasm`
# toolchain (built from the LDC WASI fork) to compile `libs/base/wasm/spk_text_wasm.d`
# against the real `sparkles.base.text`, then shrinks it with `wasm-opt`.
#
# x86_64-linux only (that is where the `ldc-wasm` toolchain is provided). A
# pre-commit hook (`gen-text-wasm`) copies the result to docs/public/spk-text.wasm.
{ inputs, lib, ... }:
{
  perSystem =
    { system, pkgs, ... }:
    lib.optionalAttrs (system == "x86_64-linux") {
      packages.text-wasm =
        let
          ldcWasm = inputs.dlang-nix.packages.${system}.ldc-wasm;
          fs = lib.fileset;
          root = ../..;
          src = fs.toSource {
            inherit root;
            fileset = fs.unions [
              (fs.fileFilter (f: f.hasExt "d") (root + "/libs/base/src"))
              # base.text imports the runner's attributes (in the impl package).
              (fs.fileFilter (f: f.hasExt "d") (root + "/libs/test-runner-impl/src"))
              (root + "/libs/base/wasm")
            ];
          };
        in
        pkgs.stdenv.mkDerivation {
          pname = "spk-text-wasm";
          version = "0.1.0";
          inherit src;

          nativeBuildInputs = [
            ldcWasm
            pkgs.binaryen
          ];

          buildPhase = ''
            runHook preBuild

            ldc2 -mtriple=wasm32-wasip1 -O2 \
              -I=libs/base/src -I=libs/test-runner-impl/src -i=sparkles \
              -L--export=spk_buf_ptr -L--export=spk_buf_cap \
              -L--export=spk_visible_width -L--export=spk_segment \
              libs/base/wasm/spk_text_wasm.d -of=spk-text.wasm

            wasm-opt -Oz --strip-debug --strip-producers spk-text.wasm -o spk-text.opt.wasm

            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            install -Dm644 spk-text.opt.wasm $out/spk-text.wasm
            runHook postInstall
          '';

          meta = {
            description = "sparkles.base.text compiled to wasm (cell-explorer widget backend)";
            platforms = [ "x86_64-linux" ];
          };
        };
    };
}
