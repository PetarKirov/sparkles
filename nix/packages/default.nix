{ lib, ... }:
{
  imports = [
    ./examples.nix
  ];

  perSystem =
    { config, pkgs, ... }:
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
        ];

      src = fs.toSource {
        inherit root;
        fileset = fs.unions (
          [
            # Dub validates that all sub-packages declared in the root dub.sdl
            # exist on disk even when only building :ci, so the sibling manifests
            # must be present too.
            (fs.fileFilter isDubManifest root)
          ]
          # D source files for the ci app and its only direct dependency.
          ++ map (path: fs.fileFilter (file: file.hasExt "d") (fromRoot path)) [
            "apps/ci/src"
            "libs/core-cli/src"
          ]
        );
      };
    in
    {
      packages.ci = pkgs.buildDubPackage (finalAttrs: {
        pname = "ci";
        version = "0.1.0";

        inherit src;
        sourceRoot = "${finalAttrs.src.name}/apps/${finalAttrs.pname}";

        # The Nix-format lockfile is shared with the standalone example
        # derivations (see ./examples.nix); keeping it under `nix/` keeps
        # that sharing explicit instead of having `examples.nix` reach
        # into a sibling sub-package's dir to grab the file.
        dubLock = fromRoot "nix/dub-lock.json";
        compiler = dToolchain.ldc;

        nativeBuildInputs = [
          pkgs.makeWrapper
        ];

        # `ci` shells out to `dub run --single` / `dub build --single` at
        # runtime, so the wrapped binary genuinely needs `ldc2` and `dub`
        # on its PATH. By default `buildDubPackage` declares the compiler
        # as a `disallowedReference` and runs `remove-references-to` in
        # `preFixup`, which would scrub the compiler path out of our
        # wrapper script (turning `…ldc-1.41.0/bin` into the placeholder
        # `…eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-ldc-1.41.0/bin`). Clearing
        # `disallowedReferences` keeps the runtime closure honest.
        disallowedReferences = [ ];

        # The unpacked source is read-only by default; dub needs to write
        # build artifacts into each package's `targetPath "build"` directory.
        preBuild = ''chmod -R u+w "$NIX_BUILD_TOP"'';

        installPhase = ''
          install -Dm755 build/${finalAttrs.pname} $out/bin/${finalAttrs.pname}
        '';

        # Wrap in `postFixup` rather than `installPhase` so we run *after*
        # `buildDubPackage`'s `preFixup`, which strips references to the
        # compiler. Wrapping there would otherwise leave the placeholder
        # path in PATH and break `dub run --single`.
        postFixup =
          let
            path = lib.makeBinPath [
              pkgs.git
              dToolchain.dub
              dToolchain.ldc
            ];
            setEnv = lib.cli.toGNUCommandLineShell {
              mkOption = name: value: [
                "--set"
                name
                value
              ];
            } dToolchain.env;
          in
          ''
            install -Dm755 build/${finalAttrs.pname} $out/bin/${finalAttrs.pname}
          ''
          +
            # Best-effort bump of NOFILE: dub/ldc can open many files in
            # parallel builds. Redirect stderr and '|| true' so that on
            # environments where the hard cap is below nofileLimit (some
            # CI runners, restricted sandboxes) the wrapper does not abort
            # under makeWrapper --run's set -e semantics — we just fall
            # back to the inherited limit.
            ''
              wrapProgram $out/bin/${finalAttrs.pname} \
                --prefix PATH : ${path} \
                ${setEnv} \
                --run 'ulimit -n ${toString dToolchain.nofileLimit} 2>/dev/null || true'
            '';

        meta = {
          description = ''
            Repository CI helper for markdown examples, standalone examples, and
            markdown link maintenance
          '';
          mainProgram = finalAttrs.pname;
        };
      });

      apps.ci = {
        type = "app";
        program = lib.getExe config.packages.ci;
      };
    };
}
