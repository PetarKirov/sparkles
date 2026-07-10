# Reproducible build of the wasm32-wasip1 module that powers the interactive
# drawTable playground in docs/libs/core-cli/, compiling
# `libs/core-cli/wasm/spk_table_wasm.d` against the real
# `sparkles.core_cli.ui.table` via the shared `buildDWasmModule` builder (see
# ./build-d-wasm-module.nix).
#
# Unlike text-wasm, drawTable allocates (GC) and imports `expected` (for name
# resolution only — validateTable is a never-instantiated template), so the
# build adds `libs/core-cli/src`, the `-preview=in -preview=dip1000` flags
# that libs/core-cli/dub.sdl uses, the `expected` dub package source on the
# import path, and exports `__wasm_call_ctors` so the embedder can run the
# druntime initialization the GC needs.
#
# x86_64-linux only (that is where the `ldc-wasm` toolchain is provided). The
# result is copied to docs/public/spk-table.wasm (see the docs page).
{ lib, ... }:
{
  perSystem =
    { config, system, ... }:
    lib.optionalAttrs (system == "x86_64-linux") {
      packages.table-wasm = config.legacyPackages.buildDWasmModule {
        pname = "spk-table-wasm";
        wasmName = "spk-table.wasm";
        entry = "libs/core-cli/wasm/spk_table_wasm.d";
        # base.text imports the runner's attributes (in the impl package).
        sourceDirs = [
          "libs/base/src"
          "libs/core-cli/src"
          "libs/test-runner-impl/src"
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
            version = "0.4.1";
            sha256 = "1ahr7gbjl6dgw1qs9x5yzcwhbzfg7ygdlsm9gw4hgmm1xrfcpri0";
          }
        ];
        description = "sparkles.core_cli.ui.table (drawTable) compiled to wasm (playground backend)";
      };
    };
}
