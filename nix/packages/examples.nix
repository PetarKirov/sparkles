{ lib, ... }:
{
  perSystem =
    { pkgs, ... }:
    let
      fs = lib.fileset;
      root = ../..;
      fromRoot = lib.path.append root;

      isDubManifest =
        file:
        builtins.elem file.name [
          "dub.sdl"
          "dub.selections.json"
        ];

      # Enumerate every standalone `.d` example across all libs as a flat
      # list of absolute paths (matching `libs/*/examples/**.d`). The
      # `fs.maybeMissing` lifts each potential `examples/` dir into a
      # fileset that's empty when the dir is absent (so libs without
      # examples just contribute nothing), and the final intersection
      # with `*.d` files under `libs` filters out non-`.d` siblings such
      # as the shared `views/**/*.txt` string-import assets.
      allExampleFiles = lib.pipe (builtins.readDir (fromRoot "libs")) [
        (lib.filterAttrs (_: type: type == "directory"))
        (lib.mapAttrsToList (name: _: fs.maybeMissing (fromRoot "libs/${name}/examples")))
        fs.unions
        (fs.intersection (fs.fileFilter (file: file.hasExt "d") (fromRoot "libs")))
        fs.toList
      ];

      # Every lib's `src/` tree, as one fileset. An example may `dependency` on
      # any sibling sub-package (e.g. `tree.d` pulls in `build-primitives`), and
      # `core-cli` additionally imports `math` (ScreenSize) via importPaths — so
      # rather than guess the transitive set per example, include them all (a
      # `dub build --single` only compiles what the example actually reaches).
      allLibSources = lib.pipe (builtins.readDir (fromRoot "libs")) [
        (lib.filterAttrs (_: type: type == "directory"))
        (lib.mapAttrsToList (name: _: fs.maybeMissing (fromRoot "libs/${name}/src")))
        fs.unions
        (fs.intersection (
          fs.fileFilter (file: file.hasExt "d" || file.hasExt "c" || file.hasExt "i") (fromRoot "libs")
        ))
      ];

      # Decompose an absolute example path into the metadata needed for the
      # derivation (lib name, file basename, attribute name, sub-paths).
      exampleInfo =
        examplePath:
        let
          subpath = lib.path.removePrefix root examplePath;
          parts = lib.splitString "/" (lib.removePrefix "./" subpath);
          libName = builtins.elemAt parts 1;
          fileBase = lib.removeSuffix ".d" (lib.last parts);
        in
        {
          inherit libName fileBase;
          examplesRel = "libs/${libName}/examples";
        };

      mkExamplePackage =
        examplePath:
        let
          info = exampleInfo examplePath;

          src = fs.toSource {
            inherit root;
            fileset = fs.unions [
              # Dub validates every sub-package declared in the root `dub.sdl`,
              # so all sibling manifests must be present even when only one
              # example is being built.
              (fs.fileFilter isDubManifest root)
              # Library sources the example links against via
              # `dependency "sparkles:<lib>" path="../../.."` — plus the impl
              # runner sources `base`/`core-cli` import unconditionally, and
              # `math` which `core-cli` reaches via importPaths. See allLibSources.
              allLibSources
              # The full `examples/` subtree — this brings in the shared
              # `views/` string-import assets alongside the script itself.
              (fromRoot info.examplesRel)
            ];
          };
        in
        pkgs.buildDubPackage (finalAttrs: {
          pname = "${info.libName}-example-${info.fileBase}";
          version = "0.1.0";

          inherit src;
          sourceRoot = "${finalAttrs.src.name}/${info.examplesRel}";

          # The examples currently depend on the same set of packages as
          # the `ci` helper, so we share a single Nix-format lockfile
          # under `nix/dub-lock.json` instead of generating (and
          # regenerating) one per example. If a future example pulls in
          # an additional dependency, that dep needs to be added to the
          # shared lockfile or split out into its own.
          dubLock = fromRoot "nix/dub-lock.json";
          compiler = pkgs.ldc;

          # Examples that depend on sparkles:syntax (or other ImportC bindings)
          # need pkg-config + the C library so dub#3085 can feed -P-I...
          # to ImportC for headers like <tree_sitter/api.h>.
          nativeBuildInputs = [ pkgs.pkg-config ];
          buildInputs = [ pkgs.tree-sitter ];

          # The unpacked source is read-only by default; dub needs to write
          # build artifacts into the package's `targetPath "build"` directory.
          preBuild = ''chmod -R u+w "$NIX_BUILD_TOP"'';

          # Phobos bakes store paths into every binary that must not leak into
          # the runtime closure: assert/`__FILE__` strings referencing ldc's
          # separate `include` output (~19 MiB; buildDubPackage scrubs and
          # disallows only the compiler's `out` — same story as `release` in
          # ./default.nix), plus the nixpkgs-patched `libcurl.so.4` dlopen
          # path (which alone pulls the ~18 MiB openssl/krb5/nghttp tail) and
          # the tzdata dir. The curl/tzdata paths are phobos *service* paths,
          # but no example touches std.net.curl or named time zones — the
          # run-all-examples runner exercises them all — so scrub and
          # disallow all three. NB: `pkgs.curl.out` — libcurl's output; bare
          # `pkgs.curl` coerces to the `-bin` output.
          disallowedReferences = [
            pkgs.ldc
            pkgs.ldc.include
            pkgs.curl.out
            pkgs.tzdata
          ];
          postFixup = ''
            find "$out" -type f -exec remove-references-to \
              -t ${pkgs.ldc.include} -t ${pkgs.curl.out} -t ${pkgs.tzdata} '{}' +
          '';

          # Override the default `dub build` invocation: the example carries
          # its own inline `dub.sdl` block, so we need `--single` mode against
          # the specific .d file instead of a package-rooted build.
          dontDubBuild = true;
          buildPhase = ''
            runHook preBuild

            dub build \
              --single ${info.fileBase}.d \
              --compiler=${lib.getExe pkgs.ldc} \
              --skip-registry=all \
              --build=release

            runHook postBuild
          '';

          # Each example's inline `dub.sdl` declares both
          # `name "<file-base>"` and `targetPath "build"`, so the produced
          # binary is always `build/<fileBase>`.
          installPhase = ''
            install -Dm755 build/${info.fileBase} $out/bin/${info.fileBase}
          '';

          meta = {
            description = "Standalone example: ${info.libName}/examples/${info.fileBase}.d";
            mainProgram = info.fileBase;
          };
        });

      # Group example derivations by their owning lib:
      # `examples.<lib>.<exampleName>`.
      examplesByLib = lib.pipe allExampleFiles [
        (lib.groupBy (path: (exampleInfo path).libName))
        (lib.mapAttrs (
          _: paths:
          lib.listToAttrs (
            map (path: {
              name = (exampleInfo path).fileBase;
              value = mkExamplePackage path;
            }) paths
          )
        ))
      ];

      # Faithful port of ci's `parseStandaloneExampleMode` (apps/ci/src/app.d):
      # skip the shebang and the inline `/+ dub.sdl: … +/` block, then scan the
      # header comment — the first `// ci:` / `// run_md_examples:` directive
      # decides the mode, and the header ends at the first non-comment line.
      exampleMode =
        examplePath:
        let
          step =
            acc: rawLine:
            let
              line = lib.trim rawLine;
              directive =
                prefix:
                acc
                // {
                  mode =
                    if lib.toLower (lib.trim (lib.removePrefix prefix line)) == "build-only" then
                      "build-only"
                    else
                      "run";
                };
            in
            if acc.mode != null || line == "" || lib.hasPrefix "#!" line then
              acc
            else if acc.insideDubSdl then
              acc // { insideDubSdl = !lib.hasPrefix "+/" line; }
            else if lib.hasPrefix "/+ dub.sdl:" line then
              acc // { insideDubSdl = true; }
            else if lib.hasPrefix "// ci:" line then
              directive "// ci:"
            else if lib.hasPrefix "// run_md_examples:" line then
              directive "// run_md_examples:"
            else if !lib.hasPrefix "//" line then
              acc // { mode = "run"; }
            else
              acc;
          result = lib.foldl' step {
            mode = null;
            insideDubSdl = false;
          } (lib.splitString "\n" (builtins.readFile examplePath));
        in
        if result.mode == null then "run" else result.mode;

      # Every example paired with its derivation and ci-equivalent mode.
      annotatedExamples = map (
        path:
        let
          info = exampleInfo path;
        in
        {
          label = "${info.libName}/${info.fileBase}";
          mode = exampleMode path;
          drv = examplesByLib.${info.libName}.${info.fileBase};
        }
      ) allExampleFiles;
    in
    {
      legacyPackages.examples = examplesByLib;

      # Smoke-run every standalone example the way `ci --example-files` does:
      # `// ci: build-only` examples are built (they are retained in the
      # script's closure) but not executed; the rest run sequentially and any
      # non-zero exit is collected into the final status.
      packages.run-all-examples = pkgs.writeShellApplication {
        name = "run-all-examples";
        text = ''
          failures=0
          ${lib.concatMapStrings (
            ex:
            if ex.mode == "build-only" then
              ''
                echo "⊘ ${ex.label} — build-only, not run (${ex.drv})"
                echo
              ''
            else
              ''
                echo "━━━ ${ex.label} ━━━"
                if ! ${lib.getExe ex.drv}; then
                  echo "✗ ${ex.label} failed"
                  failures=$((failures + 1))
                fi
                echo
              ''
          ) annotatedExamples}
          total=${
            toString (builtins.length (builtins.filter (ex: ex.mode != "build-only") annotatedExamples))
          }
          echo "$((total - failures))/$total examples ran successfully"
          [ "$failures" -eq 0 ]
        '';
      };
    };
}
