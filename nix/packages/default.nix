{ lib, ... }:
{
  imports = [
    ./examples.nix
    ./bench-tools.nix
  ];

  perSystem =
    {
      config,
      pkgs,
      inputs',
      ...
    }:
    let
      inherit (config.legacyPackages) d-toolchain;

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
        compiler = pkgs.ldc;

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
              pkgs.dub
              pkgs.ldc
            ];
            setEnv = lib.cli.toGNUCommandLineShell {
              mkOption = name: value: [
                "--set"
                name
                value
              ];
            } d-toolchain.env;
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
                --run 'ulimit -n ${toString d-toolchain.nofileLimit} 2>/dev/null || true'
            '';

        meta = {
          description = ''
            Repository CI helper for markdown examples, standalone examples, and
            markdown link maintenance
          '';
          mainProgram = finalAttrs.pname;
        };
      });

      packages.terminal = pkgs.buildDubPackage (finalAttrs: {
        pname = "terminal";
        version = "0.1.0";

        src = fs.toSource {
          inherit root;
          fileset = fs.unions (
            [
              # All sub-package manifests must be present: dub validates that
              # every sub-package declared in the root dub.sdl exists on disk.
              (fs.fileFilter isDubManifest root)
            ]
            # D/C source for the terminal app and its only direct dependencies
            # (their library configs pull in no further sibling sources).
            ++ map (path: fs.fileFilter (file: file.hasExt "d" || file.hasExt "c") (fromRoot path)) [
              "apps/terminal/src"
              "libs/core-cli/src"
              "libs/ghostty/src"
            ]
          );
        };
        sourceRoot = "${finalAttrs.src.name}/apps/${finalAttrs.pname}";

        dubLock = fromRoot "nix/dub-lock.json";
        compiler = pkgs.ldc;

        nativeBuildInputs = [
          pkgs.pkg-config
          pkgs.makeWrapper
        ];

        buildInputs = [
          pkgs.raylib
          inputs'.ghostty.packages.libghostty-vt
          inputs'.ghostty.packages.libghostty-vt.dev
        ];

        env = d-toolchain.env;

        preBuild = ''chmod -R u+w "$NIX_BUILD_TOP"'';

        installPhase = ''
          install -Dm755 build/${finalAttrs.pname} $out/bin/${finalAttrs.pname}
        '';

        # The terminal shells out to `fc-match` (fontconfig) at runtime to
        # resolve fonts (see apps/terminal/src/app.d). Under `nix run` PATH is
        # the ambient user environment, so wrap the binary to guarantee
        # fontconfig is reachable instead of relying on the user's PATH.
        postFixup = ''
          wrapProgram $out/bin/${finalAttrs.pname} \
            --prefix PATH : ${lib.makeBinPath [ pkgs.fontconfig ]}
        '';

        meta = {
          description = "A minimal terminal emulator using libghostty-vt";
          mainProgram = finalAttrs.pname;
        };
      });

      # CPU benchmark harness for the terminal. Pure D + core-cli (it only spawns
      # terminal binaries handed to it and reads /proc), so no raylib/ghostty
      # build inputs and no runtime wrapper are needed.
      packages.terminal-benchmark = pkgs.buildDubPackage (finalAttrs: {
        pname = "terminal-benchmark";
        version = "0.1.0";

        src = fs.toSource {
          inherit root;
          fileset = fs.unions (
            [
              (fs.fileFilter isDubManifest root)
            ]
            ++ map (path: fs.fileFilter (file: file.hasExt "d") (fromRoot path)) [
              "apps/terminal-benchmark/src"
              "libs/core-cli/src"
            ]
          );
        };
        sourceRoot = "${finalAttrs.src.name}/apps/${finalAttrs.pname}";

        dubLock = fromRoot "nix/dub-lock.json";
        compiler = pkgs.ldc;

        preBuild = ''chmod -R u+w "$NIX_BUILD_TOP"'';

        installPhase = ''
          install -Dm755 build/${finalAttrs.pname} $out/bin/${finalAttrs.pname}
        '';

        meta = {
          description = "CPU/throughput benchmark harness for the sparkles terminal emulator";
          mainProgram = finalAttrs.pname;
        };
      });

      apps.ci = {
        type = "app";
        program = lib.getExe config.packages.ci;
      };

      apps.terminal = {
        type = "app";
        program = lib.getExe config.packages.terminal;
      };

      apps.terminal-benchmark = {
        type = "app";
        program = lib.getExe config.packages.terminal-benchmark;
      };
    };
}
