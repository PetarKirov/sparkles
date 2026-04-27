{ lib, ... }:
{
  perSystem =
    { pkgs, ... }:
    let
      dToolchain = import ../d-toolchain.nix { inherit pkgs; };

      fs = lib.fileset;
      root = ../..;
      fromRoot = lib.path.append root;

      isDubManifest =
        file:
        builtins.elem file.name [
          "dub.sdl"
          "dub.selections.json"
          "dub-lock.json"
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

      # Decompose an absolute example path into the metadata needed for the
      # derivation (lib name, file basename, attribute name, sub-paths).
      #
      # Examples can live either directly under `libs/<lib>/examples/` (a
      # single `.d` file) or one or more directories deeper for self-contained
      # multi-file examples that ship their own `views/` (e.g.
      # `libs/<lib>/examples/cli/git/git.d`). The dub-package source root is
      # always the parent directory of the `.d` file so that single-file
      # builds resolve `views/` next to the script.
      exampleInfo =
        examplePath:
        let
          subpath = lib.path.removePrefix root examplePath;
          parts = lib.splitString "/" (lib.removePrefix "./" subpath);
          libName = builtins.elemAt parts 1;
          fileBase = lib.removeSuffix ".d" (lib.last parts);
          parentDirRel = lib.concatStringsSep "/" (lib.init parts);
          examplePathRel = lib.concatStringsSep "/" parts;
        in
        {
          inherit
            libName
            fileBase
            parentDirRel
            examplePathRel
            ;
          examplesRel = "libs/${libName}/examples";
          librarySrcRel = "libs/${libName}/src";
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
              # `dependency "sparkles:<lib>" path="../../.."`.
              (fs.fileFilter (file: file.hasExt "d") (fromRoot info.librarySrcRel))
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
          sourceRoot = "${finalAttrs.src.name}/${info.parentDirRel}";

          # The example only depends (transitively) on packages already pinned
          # by the ci helper, so we share the same lockfile instead of
          # generating one per example.
          dubLock = fromRoot "apps/ci/dub-lock.json";
          compiler = dToolchain.ldc;

          # The unpacked source is read-only by default; dub needs to write
          # build artifacts into the package's `targetPath "build"` directory.
          preBuild = ''chmod -R u+w "$NIX_BUILD_TOP"'';

          # Override the default `dub build` invocation: the example carries
          # its own inline `dub.sdl` block, so we need `--single` mode against
          # the specific .d file instead of a package-rooted build.
          dontDubBuild = true;
          buildPhase = ''
            runHook preBuild

            dub build \
              --single ${info.fileBase}.d \
              --compiler=${lib.getExe dToolchain.ldc} \
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
            description = "Standalone example: ${info.examplePathRel}";
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
    in
    {
      legacyPackages.examples = examplesByLib;
    };
}
