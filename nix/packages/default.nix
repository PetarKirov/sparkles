{ lib, ... }:
{
  imports = [
    ./examples.nix
  ];

  perSystem =
    { config, pkgs, ... }:
    let
      inherit (config.legacyPackages) d-toolchain;

      # `ci` runs a D compiler to build the examples, so it lands in ci's
      # runtime closure (and every consumer's — pre-commit devShell, lint CI).
      # Prefer DMD on x86_64-linux: no LLVM backend, so ~half LDC's closure.
      # DMD only targets x86_64/i686-linux + x86_64-darwin; keep LDC elsewhere.
      ciCompiler = if pkgs.stdenv.hostPlatform.system == "x86_64-linux" then pkgs.dmd else pkgs.ldc;

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
          # D source files for the ci/release apps and their direct dependencies.
          # `base`/`core-cli` import the runner's `@…` attributes (in the impl
          # package) unconditionally, so its source must be present even in these
          # non-unittest library builds; `core-cli` likewise imports `math`
          # (ScreenSize) via importPaths; `release` deserializes agent replies
          # via `wired`.
          ++ map (path: fs.fileFilter (file: file.hasExt "d") (fromRoot path)) [
            "apps/ci/src"
            "apps/release/src"
            "libs/base/src"
            "libs/core-cli/src"
            "libs/math/src"
            "libs/versions/src"
            "libs/test-runner/src"
            "libs/test-runner-impl/src"
            "libs/wired/src"
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
        compiler = ciCompiler;

        nativeBuildInputs = [
          pkgs.makeWrapper
        ];

        # `ci` shells out to `dub run --single` / `dub build --single` at
        # runtime, so the wrapped binary genuinely needs the D compiler and
        # `dub` on its PATH. By default `buildDubPackage` declares the compiler
        # as a `disallowedReference` and runs `remove-references-to` in
        # `preFixup`, which would scrub the compiler path out of our
        # wrapper script (turning `…dmd-2.112.1/bin` into the placeholder
        # `…eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-dmd-2.112.1/bin`). Clearing
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
              # gitMinimal (no python/perl): ci only shells out to git plumbing
              # for link maintenance, and full git pulls a second CPython (via
              # git-p4's shebang) into the closure. See nix/shells/default.nix.
              pkgs.gitMinimal
              pkgs.dub
              ciCompiler
            ];
            # Render `--set NAME VALUE` triples for wrapProgram from the toolchain
            # env (non-empty on darwin: CC/CXX/SDKROOT/MACOSX_DEPLOYMENT_TARGET).
            # Not lib.cli.toCommandLine*: its option-spec model renders `--flag
            # value` pairs, not wrapProgram's three-token `--set KEY VALUE` form.
            setEnv = lib.escapeShellArgs (
              lib.concatLists (
                lib.mapAttrsToList (name: value: [
                  "--set"
                  name
                  value
                ]) d-toolchain.env
              )
            );
            # The cpu-pmu research probes (docs/research/cpu-pmu/examples) link
            # C libraries via `libs "dw" "elf"` / `libs "pfm"`. Inside the
            # devshell the shellHook exports these paths (nix/shells); carry
            # them in the wrapper too so `nix run .#ci -- --example-files`
            # links them outside any shell.
            exampleLibPath = lib.optionalString pkgs.stdenv.isLinux (
              lib.makeSearchPath "lib" [
                pkgs.elfutils.out
                pkgs.libpfm
              ]
            );
            exampleLibArgs = lib.optionalString (
              exampleLibPath != ""
            ) "--prefix LIBRARY_PATH : ${exampleLibPath} --prefix LD_LIBRARY_PATH : ${exampleLibPath}";
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
                ${exampleLibArgs} \
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

      apps.ci = {
        type = "app";
        program = lib.getExe config.packages.ci;
      };

      packages.release = pkgs.buildDubPackage (finalAttrs: {
        pname = "release";
        version = "0.1.0";

        inherit src;
        sourceRoot = "${finalAttrs.src.name}/apps/${finalAttrs.pname}";

        # Shared with `ci` and the example derivations (see ./examples.nix).
        dubLock = fromRoot "nix/dub-lock.json";
        compiler = pkgs.ldc;

        nativeBuildInputs = [
          pkgs.makeWrapper
        ];

        # Unlike `ci`, `release` needs no D compiler at runtime, so the
        # toolchain must not leak into the closure. `buildDubPackage` already
        # scrubs and disallows the compiler's `out`, but the druntime/phobos
        # *sources* live in ldc's separate `include` output, whose path gets
        # baked into the binary via assert/`__FILE__` strings — scrub and
        # disallow that output too (see postFixup).
        disallowedReferences = [
          pkgs.ldc
          pkgs.ldc.include
        ];

        preBuild = ''chmod -R u+w "$NIX_BUILD_TOP"'';

        installPhase = ''
          install -Dm755 build/${finalAttrs.pname} $out/bin/${finalAttrs.pname}
        '';

        # `release` shells out to `git`, optionally `gh` (for the GitHub release
        # stages), and — for the pre-flight checks — the repo's own `ci` tool.
        # Bundling the flake-built `ci` here means pre-flight uses the pinned,
        # never-stale binary (no nested `nix run`). LLM agents are deliberately
        # NOT bundled: they are user-provided and discovered on the caller's PATH.
        postFixup =
          let
            path = lib.makeBinPath [
              # gitMinimal, not git: release only drives porcelain that the
              # minimal build ships (log/push/tag/rev-parse/…, incl. the https
              # remote helper), while full git drags perl and a whole CPython
              # (via git-p4's shebang) into the closure — and `ci` below
              # already bundles gitMinimal, so this shares its store path.
              pkgs.gitMinimal
              pkgs.gh
              config.packages.ci
            ];
          in
          ''
            wrapProgram $out/bin/${finalAttrs.pname} \
              --prefix PATH : ${path}
            find "$out" -type f -exec remove-references-to -t ${pkgs.ldc.include} '{}' +
          '';

        meta = {
          description = ''
            Cut a sparkles release: scan tags, summarize commits, suggest a bump,
            write notes, tag and publish
          '';
          mainProgram = finalAttrs.pname;
        };
      });

      apps.release = {
        type = "app";
        program = lib.getExe config.packages.release;
      };
    };
}
