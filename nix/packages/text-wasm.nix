# Reproducible build of the wasm32-wasip1 module that powers the interactive
# cell-explorer widget in docs/specs/base/text/, compiling
# `libs/base/wasm/spk_text_wasm.d` against the real `sparkles.base.text` via
# the shared `buildDWasmModule` builder (see ./build-d-wasm-module.nix).
#
# UTF-8 validation imports the `expected` parser vocabulary even though the
# exported width/segmentation path does not allocate. Supply its source through
# the shared builder's import-only dependency mechanism, not a runtime library.
#
# x86_64-linux only (that is where the `ldc-wasm` toolchain is provided). The
# result is copied to docs/public/spk-text.wasm (see the docs page).
{ inputs, lib, ... }:
{
  perSystem =
    { config, system, ... }:
    lib.optionalAttrs (system == "x86_64-linux") {
      packages.text-wasm = config.legacyPackages.buildDWasmModule {
        pname = "spk-text-wasm";
        wasmName = "spk-text.wasm";
        entry = "libs/base/wasm/spk_text_wasm.d";
        # Marker UDAs in the base modules require the runner SHIM's
        # `attributes.d` even without -unittest; the impl is test-only.
        sourceDirs = [
          "libs/base/src"
          "libs/test-runner/src"
        ];
        exports = [
          "spk_buf_ptr"
          "spk_buf_cap"
          "spk_visible_width"
          "spk_segment"
        ];
        dubImports = [
          {
            name = "expected";
            src = inputs.dub-expected;
          }
        ];
        description = "sparkles.base.text compiled to wasm (cell-explorer widget backend)";
      };
    };
}
