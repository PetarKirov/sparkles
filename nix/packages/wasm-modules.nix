# The documentation site's WebAssembly modules (docs/specs/toolchain/wasm-modules.md):
# `text-wasm` (the cell explorer, `sparkles:text-wasm`) and `table-wasm` (the
# table playground, `sparkles:table-wasm`). Each is the dub package's `wasm`
# configuration, built by dub for `wasm32-unknown-wasip1` (TCM1) with
# dlang.nix's `ldc-sparkles`, whose ldc2.conf selects the preview's druntime,
# Phobos and compiler driver by triple; the recipes hold the sources, flags
# and exports. `wasm-opt -Oz` (TCM8) shrinks the linked module.
#
# The output references nothing: druntime's and Phobos' templates name their
# source files in assertion messages, and those are mapped out of the store
# (`-ffile-prefix-map`, as `ldc.reproducible` does for native programs).
{ lib, ... }:
{
  perSystem =
    {
      config,
      inputs',
      pkgs,
      ...
    }:
    let
      ldcSparkles = inputs'.dlang-nix.packages.ldc-sparkles;

      # `ldc-sparkles` mapping the compiler's store paths to `/ldc` in `__FILE__`,
      # assertion messages and debug info. Its `ldc2` is already a wrapper
      # naming its own ldc2.conf, so the map is passed as flags, not as a
      # configuration.
      wasiLdc =
        let
          layers = lib.unique (
            [ ldcSparkles ]
            ++ lib.optional (ldcSparkles ? unwrapped) ldcSparkles.unwrapped
            ++ lib.optional (ldcSparkles.unwrapped ? unwrapped) ldcSparkles.unwrapped.unwrapped
          );
          prefixMap = lib.concatMapStringsSep " " (p: "-ffile-prefix-map=${p}=/ldc") layers;
        in
        pkgs.symlinkJoin {
          name = "ldc-sparkles-reproducible-${ldcSparkles.version}";
          paths = [ ldcSparkles ];
          nativeBuildInputs = [ pkgs.makeWrapper ];
          postBuild = ''
            for drv in ldc2 ldmd2; do
              wrapProgram "$out/bin/$drv" --add-flags "${prefixMap}"
            done
          '';
          passthru = {
            unwrapped = ldcSparkles;
            mapsStorePaths = true;
            all = [ ldcSparkles ];
          };
          meta = ldcSparkles.meta // {
            mainProgram = "ldc2";
          };
        };

      buildWasmModule =
        {
          pname,
          appDir,
          # The linked module's name, the configuration's `targetName`.
          targetName,
          description,
        }:
        config.legacyPackages.buildSparklesApp (finalAttrs: {
          inherit pname appDir;
          version = "0.1.0";
          compiler = wasiLdc;
          dubBuildType = "wasm-lto";
          dubBuildFlags = [
            "--arch=wasm32-unknown-wasip1"
            "--config=wasm"
          ];
          nativeBuildInputs = [ pkgs.binaryen ];

          postBuild = ''
            wasm-opt -Oz --strip-debug --strip-producers \
              build/${targetName}.wasm -o build/${targetName}.opt.wasm
          '';
          installPhase = ''
            runHook preInstall
            install -Dm644 build/${targetName}.opt.wasm $out/${targetName}.wasm
            runHook postInstall
          '';

          allowedReferences = [ ];

          meta = {
            inherit description;
            platforms = lib.platforms.linux ++ lib.platforms.darwin;
          };
        });
    in
    {
      packages.text-wasm = buildWasmModule {
        pname = "text-wasm";
        appDir = "libs/base/text-wasm";
        targetName = "spk-text";
        description = "sparkles.base.text as a WebAssembly module (the docs' cell explorer)";
      };

      packages.table-wasm = buildWasmModule {
        pname = "table-wasm";
        appDir = "libs/core-cli/table-wasm";
        targetName = "spk-table";
        description = "drawTable as a WebAssembly module (the docs' table playground)";
      };
    };
}
