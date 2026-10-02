# Reproducible build of the wasm32-wasip1 module that powers the interactive
# drawTable playground in docs/libs/core-cli/, compiling
# `libs/core-cli/wasm/spk_table_wasm.d` against the real
# `sparkles.ui.components.table` via the shared `buildDWasmModule` builder (see
# ./build-d-wasm-module.nix).
#
# Both wasm widgets need `expected` sources for the base UTF-8 parser vocabulary.
# Unlike text-wasm, drawTable allocates (GC), so this build also adds
# `libs/ui/src` + `libs/core-cli/src`, the `-preview=in -preview=dip1000` flags
# that libs/core-cli/dub.sdl uses, and exports `__wasm_call_ctors` so the embedder
# can run the druntime initialization the GC needs. The base buffer's text
# writers also require the dependency-free `sparkles:reflection` sources.
#
# x86_64-linux only (that is where the `ldc-wasm` toolchain is provided). The
# result is copied to docs/public/spk-table.wasm (see the docs page).
{ inputs, lib, ... }:
{
  perSystem =
    { config, system, ... }:
    lib.optionalAttrs (system == "x86_64-linux") {
      packages.table-wasm = config.legacyPackages.buildDWasmModule {
        pname = "spk-table-wasm";
        wasmName = "spk-table.wasm";
        entry = "libs/core-cli/wasm/spk_table_wasm.d";
        # Marker UDAs in the base modules require the runner SHIM's
        # `attributes.d` even without -unittest; the impl is test-only.
        sourceDirs = [
          "libs/base/src"
          "libs/reflection/src"
          "libs/test-runner/src"
          "libs/core-cli/src"
          "libs/ui/src"
        ];
        exports = [
          "spk_buf_ptr"
          "spk_buf_cap"
          "spk_table_render"
          "spk_segment"
        ];
        exportCtors = true;
        dflags = [
          "-preview=in"
          "-preview=dip1000"
        ];
        dubImports = [
          {
            name = "expected";
            src = inputs.dub-expected;
          }
        ];
        description = "sparkles.ui.components.table (drawTable) compiled to wasm (playground backend)";
      };
    };
}
