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

      # The modules' host platform is WASI and the build platform this system:
      # nixpkgs' cross package set, whose `stdenvNoCC` builds no C toolchain
      # (the modules link through `ldc-sparkles`' own WASI sysroots, built
      # with the exception handling nixpkgs' WASI libc++ leaves out). Its
      # `hostPlatform.emulator` is wasmtime.
      wasiPkgs = pkgs.pkgsCross.wasm32-wasip1;

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

      # The site's WASI loader (docs/.vitepress/theme/wasi.ts) imports this package;
      # the agreement check gives node the version package.json pins.
      browserWasiShim =
        pkgs.runCommand "browser-wasi-shim-0.4.2"
          {
            src = pkgs.fetchurl {
              url = "https://registry.npmjs.org/@bjorn3/browser_wasi_shim/-/browser_wasi_shim-0.4.2.tgz";
              hash = "sha512-/iHkCVUG3VbcbmEHn5iIUpIrh7a7WPiwZ3sHy4HZKZzBdSadwdddYDZAII2zBvQYV0Lfi8naZngPCN7WPHI/hA==";
            };
          }
          ''
            mkdir $out
            tar xzf $src -C $out --strip-components=1
          '';

      buildWasmModule =
        {
          pname,
          appDir,
          # The linked module's name, the configuration's `targetName`.
          targetName,
          description,
          # A reactor exporting TCM5's buffer (`spk_buf_cap`), which the WASI
          # platform's emulator can initialize and call. The Nix module
          # imports the evaluator's host functions instead, and runs only
          # under `builtins.wasm`.
          reactor ? true,
        }:
        config.legacyPackages.buildSparklesAppWith { stdenv = wasiPkgs.stdenvNoCC; } (finalAttrs: {
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
          # A module, not an ELF: the cross environment's strip would look
          # for a WASI binutils that does not exist.
          dontStrip = true;

          # The module in a second runtime besides node: the platform's
          # emulator (wasmtime) validates it, exception handling included,
          # runs `_initialize` (druntime's start-up) and calls `spk_buf_cap`,
          # whose answer TCM5 bounds below. `doCheck` cannot do this: a cross
          # build never runs its check phase.
          passthru.tests =
            lib.optionalAttrs (reactor && wasiPkgs.stdenv.hostPlatform.emulatorAvailable pkgs)
              {
                emulator = pkgs.runCommand "${pname}-emulator" { } ''
                  # wasmtime keeps its compilation cache under $HOME.
                  export HOME="$TMPDIR"
                  cap="$(${wasiPkgs.stdenv.hostPlatform.emulator pkgs} run --invoke spk_buf_cap \
                    ${finalAttrs.finalPackage}/${targetName}.wasm)"
                  echo "spk_buf_cap: $cap" | tee "$out"
                  [ "$cap" -ge 262144 ]
                '';
              };

          meta = {
            inherit description;
            platforms = lib.platforms.wasi;
          };
        });

      # The packages whose default configuration is a WebAssembly module. Nix
      # builds each for `wasm32-unknown-wasip1`; `ci commits build-each` builds
      # each on the build graph for every host of `wasmModuleHostConfigs`
      # (build-graph E5),
      # from `legacyPackages.wasmModuleHosts`, which the toolchain table
      # carries (./toolchains.nix).
      wasmModules = {
        text-wasm = {
          appDir = "libs/base/text-wasm";
          targetName = "spk-text";
          description = "sparkles.base.text as a WebAssembly module (the docs' cell explorer)";
        };
        table-wasm = {
          appDir = "libs/core-cli/table-wasm";
          targetName = "spk-table";
          description = "drawTable as a WebAssembly module (the docs' table playground)";
        };
        wired-wasm = {
          appDir = "libs/wired/wired-wasm";
          targetName = "spk-wired";
          description = "sparkles:wired as a WebAssembly module (the docs' JSON/SDL playground, the npm package)";
        };
        # The dub recipe schema for Nix's `builtins.wasm` (docs/specs/wired/wasm,
        # WW3): a WASI command module, not a reactor.
        dub-manifest-nix-wasm = {
          appDir = "libs/dub-manifest/dub-manifest-nix-wasm";
          targetName = "spk-dub-manifest";
          description = "The dub recipe schema as a Nix builtins.wasm module";
          reactor = false;
        };
      };
      # wasip2 has no nixpkgs platform at this pin (`Unknown kernel: wasip2`),
      # so it is named by its config alone.
      wasmModuleHostConfigs = [
        wasiPkgs.stdenv.hostPlatform.config
        "wasm32-unknown-wasip2"
      ];
    in
    {
      packages.text-wasm = buildWasmModule (wasmModules.text-wasm // { pname = "text-wasm"; });
      packages.table-wasm = buildWasmModule (wasmModules.table-wasm // { pname = "table-wasm"; });
      packages.wired-wasm = buildWasmModule (wasmModules.wired-wasm // { pname = "wired-wasm"; });
      packages.dub-manifest-nix-wasm = buildWasmModule (
        wasmModules.dub-manifest-nix-wasm // { pname = "dub-manifest-nix-wasm"; }
      );
      legacyPackages.wasmModuleHosts = lib.mapAttrs (_: _: wasmModuleHostConfigs) wasmModules;

      # The npm package `@sparkles-pkgs/wired` (docs/specs/wired/wasm WW13): its
      # sources with the site's module beside them, as `npm publish` takes it.
      # The release workflow sets the version from the tag. Its test is the
      # package's own suite under node, its one dependency (the WASI shim the
      # site uses) placed as npm would place it.
      packages.npm-wired =
        pkgs.runCommand "npm-wired"
          {
            passthru.tests.node =
              pkgs.runCommand "npm-wired-tests"
                {
                  nativeBuildInputs = [ pkgs.nodejs ];
                }
                ''
                  cp -r ${config.packages.npm-wired} pkg
                  chmod -R u+w pkg
                  cp -r ${../../libs/wired/wired-wasm/npm/test} pkg/test
                  mkdir -p pkg/node_modules/@bjorn3
                  ln -s ${browserWasiShim} pkg/node_modules/@bjorn3/browser_wasi_shim
                  cd pkg
                  set -o pipefail
                  node --test test/index.test.mjs | tee "$out"
                '';
          }
          ''
            mkdir $out
            cp ${../../libs/wired/wired-wasm/npm}/{package.json,index.js,index.d.ts,README.md} $out/
            install -m644 ${config.packages.wired-wasm}/spk-wired.wasm $out/spk-wired.wasm
          '';

      # The site's three modules, as it serves them (TCM3): `ci docs
      # stage-wasm` copies them into docs/public/ before VitePress builds.
      #
      # Its tests: TCM9's agreement, each module under node agreeing with the
      # same functions run natively over a fixed corpus
      # (apps/ci/src/wasm_modules_check.d), loaded through the site's own loader
      # (TCM7); and each module's emulator test.
      packages.docs-wasm =
        pkgs.runCommand "docs-wasm"
          {
            passthru.tests = {
              agreement =
                pkgs.runCommand "wasm-modules-agree"
                  {
                    nativeBuildInputs = [ pkgs.nodejs ];
                  }
                  ''
                    set -o pipefail
                    ${lib.getExe config.packages.ci-minimal} check wasm-modules \
                      --text-module ${config.packages.text-wasm}/spk-text.wasm \
                      --table-module ${config.packages.table-wasm}/spk-table.wasm \
                      --wired-module ${config.packages.wired-wasm}/spk-wired.wasm \
                      --wasi-loader ${../../docs/.vitepress/theme/wasi.ts} \
                      --wasi-shim ${browserWasiShim} \
                      | tee "$out"
                  '';
            }
            // lib.concatMapAttrs (name: test: { "${name}-emulator" = test; }) (
              lib.mapAttrs (_: p: p.tests.emulator) {
                inherit (config.packages) text-wasm table-wasm wired-wasm;
              }
            );
          }
          ''
            install -Dm644 ${config.packages.text-wasm}/spk-text.wasm $out/spk-text.wasm
            install -Dm644 ${config.packages.table-wasm}/spk-table.wasm $out/spk-table.wasm
            install -Dm644 ${config.packages.wired-wasm}/spk-wired.wasm $out/spk-wired.wasm
          '';

      # The flake checks are the packages' tests.
      checks = {
        wasm-modules = config.packages.docs-wasm.tests.agreement;
        npm-wired = config.packages.npm-wired.tests.node;
      }
      // lib.filterAttrs (name: _: lib.hasSuffix "-emulator" name) config.packages.docs-wasm.tests;

      # The same answers computed natively, for the agreement check (WW10).
      packages.dub-manifest-nix-oracle = config.legacyPackages.buildSparklesApp {
        pname = "dub-manifest-nix-oracle";
        version = "0.1.0";
        appDir = "libs/dub-manifest/dub-manifest-nix-wasm";
        dubBuildFlags = [ "--config=oracle" ];
        installPhase = ''
          runHook preInstall
          install -Dm755 build/spk-dub-manifest-oracle $out/bin/spk-dub-manifest-oracle
          runHook postInstall
        '';
        meta = {
          description = "The dub recipe module's answers, computed natively";
          mainProgram = "spk-dub-manifest-oracle";
          platforms = lib.platforms.linux ++ lib.platforms.darwin;
        };
      };

      # The oracle's answers for every tracked `dub.sdl` and `dub.json` and for
      # the failure fixtures. The agreement check, run by an evaluator with
      # `builtins.wasm`, compares the module's answers with these.
      packages.dub-manifest-nix-answers =
        let
          root = ../..;
          recipes = lib.fileset.toSource {
            inherit root;
            fileset = lib.fileset.fileFilter (f: f.name == "dub.sdl" || f.name == "dub.json") root;
          };
          oracle = lib.getExe config.packages.dub-manifest-nix-oracle;
        in
        pkgs.runCommand "dub-manifest-nix-answers" { } ''
          mkdir $out
          cd ${recipes}
          find . -name dub.sdl -o -name dub.json | sed 's|^\./||' | LC_ALL=C sort > $out/recipes.txt
          ${oracle} . $(cat $out/recipes.txt) > $out/recipes.json
          ${oracle} --fixtures ${../../libs/dub-manifest/dub-manifest-nix-wasm/fixtures.json} > $out/fixtures.json
        '';

      # `nix run .#check-nix-wasm` from a checkout, on an evaluator with
      # `builtins.wasm` (WW10): the module and the recipe table checked against
      # the native oracle and the regular-expression reader.
      apps.check-nix-wasm = {
        type = "app";
        program = lib.getExe (
          pkgs.writeShellApplication {
            name = "check-nix-wasm";
            text = ''
              exec ${lib.getExe config.packages.ci-minimal} check nix-wasm \
                --module ${config.packages.dub-manifest-nix-wasm}/spk-dub-manifest.wasm \
                --answers ${config.packages.dub-manifest-nix-answers} "$@"
            '';
          }
        );
      };
    };
}
