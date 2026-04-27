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
          "dub-lock.json"
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

        dubLock = fromRoot "apps/${finalAttrs.pname}/dub-lock.json";
        compiler = dToolchain.ldc;

        nativeBuildInputs = [
          pkgs.makeWrapper
        ];

        # The unpacked source is read-only by default; dub needs to write
        # build artifacts into each package's `targetPath "build"` directory.
        preBuild = ''chmod -R u+w "$NIX_BUILD_TOP"'';

        installPhase =
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

            wrapProgram $out/bin/${finalAttrs.pname} \
              --prefix PATH : ${path} \
              ${setEnv} \
              --run 'ulimit -n ${toString dToolchain.nofileLimit}'
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
