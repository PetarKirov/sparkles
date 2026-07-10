# Shared builder for the single-module wasm32-wasip1 artifacts behind the
# interactive docs widgets (`text-wasm`, `table-wasm`). Compiles one entry
# module with dlang.nix's `ldc-wasm` toolchain (the LDC WASI fork), shrinks
# the result with `wasm-opt`, and guarantees a closure-free output: druntime/
# phobos assert messages bake `__FILE__` strings pointing into the toolchain's
# store path into the binary (LDC has no -ffile-prefix-map), so all store-path
# references are zeroed with `nuke-refs` — targeted scrubbing is fragile here,
# as the leaked path is the *unwrapped* inner ldc, not `ldc-wasm` itself — and
# `allowedReferences = [ ]` enforces that the installed .wasm references
# nothing at all.
#
# Exposed as `legacyPackages.buildDWasmModule` (flake-parts' escape hatch for
# non-derivation values — see `d-toolchain` for precedent); internal consumers
# call it via `config.legacyPackages.buildDWasmModule`.
{ inputs, lib, ... }:
{
  perSystem =
    { system, pkgs, ... }:
    {
      legacyPackages.buildDWasmModule =
        {
          pname,
          version ? "0.1.0",
          # Name of the installed artifact, e.g. "spk-text.wasm".
          wasmName,
          description,

          # Repo-relative path of the entry-point D module. Its directory is
          # included in the source fileset wholesale (so sibling assets come
          # along).
          entry,
          # Repo-relative directories holding the D sources the module may
          # reach; added to the fileset (*.d files only) and to the import path.
          sourceDirs,
          # Wasm symbols to export, rendered as `-L--export=<name>`.
          exports,
          # Also export `__wasm_call_ctors` (when defined) — required when the
          # module relies on druntime initialization (module ctors, GC).
          exportCtors ? false,
          # Extra D flags, e.g. the -preview flags of the library being wrapped.
          dflags ? [ ],
          # Dub registry packages whose `source/` dir is put on the import path
          # (name resolution only — nothing is linked). Fetched from the same
          # `mirror://dub` coordinates as nix/dub-lock.json:
          # { name, version, sha256 }.
          dubImports ? [ ],
        }:
        let
          ldcWasm = inputs.dlang-nix.packages.${system}.ldc-wasm;
          fs = lib.fileset;
          root = ../..;

          src = fs.toSource {
            inherit root;
            fileset = fs.unions (
              map (dir: fs.fileFilter (f: f.hasExt "d") (root + "/${dir}")) sourceDirs
              ++ [ (root + "/${builtins.dirOf entry}") ]
            );
          };

          dubZip =
            d:
            pkgs.fetchurl {
              name = "dub-${d.name}-${d.version}.zip";
              url = "mirror://dub/${d.name}/${d.version}.zip";
              inherit (d) sha256;
            };
        in
        pkgs.stdenv.mkDerivation {
          inherit pname version src;

          nativeBuildInputs = [
            ldcWasm
            pkgs.binaryen
            pkgs.nukeReferences
          ]
          ++ lib.optional (dubImports != [ ]) pkgs.unzip;

          buildPhase = ''
            runHook preBuild

            ${lib.concatMapStrings (d: ''
              mkdir -p dub-imports/${d.name}
              (cd dub-imports/${d.name} && unzip -q ${dubZip d})
            '') dubImports}

            ldc2 -mtriple=wasm32-wasip1 -O2 ${toString dflags} \
              ${toString (map (dir: "-I=${dir}") sourceDirs)} \
              ${
                toString (
                  map (d: ''-I="$(find dub-imports/${d.name} -type d -name source -print -quit)"'') dubImports
                )
              } \
              -i=sparkles \
              ${toString (map (name: "-L--export=${name}") exports)} \
              ${lib.optionalString exportCtors "-L--export-if-defined=__wasm_call_ctors"} \
              ${entry} -of=module.wasm

            wasm-opt -Oz --strip-debug --strip-producers module.wasm -o module.opt.wasm

            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            install -Dm644 module.opt.wasm $out/${wasmName}
            runHook postInstall
          '';

          # Zero the toolchain path strings (dead assert-message text) baked
          # into the module — the output must reference nothing (see the
          # header comment).
          postFixup = ''
            nuke-refs $out/${wasmName}
          '';
          allowedReferences = [ ];

          meta = {
            inherit description;
            platforms = [ "x86_64-linux" ];
          };
        };
    };
}
