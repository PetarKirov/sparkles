# Reproducible build of the wasm32-wasip1 module that powers the interactive
# cell-explorer widget in docs/specs/base/text/, compiling
# `libs/base/wasm/spk_text_wasm.d` against the real `sparkles.base.text` via
# the shared `buildDWasmModule` builder (see ./build-d-wasm-module.nix).
#
# x86_64-linux only (that is where the `ldc-wasm` toolchain is provided). The
# result is copied to docs/public/spk-text.wasm (see the docs page).
{ lib, ... }:
{
  perSystem =
    { config, system, ... }:
    lib.optionalAttrs (system == "x86_64-linux") {
      packages.text-wasm = config.legacyPackages.buildDWasmModule {
        pname = "spk-text-wasm";
        wasmName = "spk-text.wasm";
        entry = "libs/base/wasm/spk_text_wasm.d";
        # base.text imports the runner's attributes (in the impl package).
        sourceDirs = [
          "libs/base/src"
          "libs/test-runner-impl/src"
        ];
        exports = [
          "spk_buf_ptr"
          "spk_buf_cap"
          "spk_visible_width"
          "spk_segment"
        ];
        description = "sparkles.base.text compiled to wasm (cell-explorer widget backend)";
      };
    };
}
