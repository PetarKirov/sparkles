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
        # `sparkles:base` carries the runner's marker UDAs unconditionally
        # (`@betterC` on `SmallBuffer`'s own tests, and the `base.text` modules),
        # so the SHIM — which is where `attributes.d` lives — has to be on the
        # path even though nothing here runs a test.
        sourceDirs = [
          "libs/base/src"
          "libs/test-runner/src"
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
