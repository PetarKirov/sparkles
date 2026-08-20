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

      # `ci` execs a D compiler at runtime to build the examples, so it lands in
      # ci's runtime closure (and every consumer's — pre-commit devShell, lint
      # CI). Prefer DMD on x86_64-linux for `--example-files` / `--test`: no
      # LLVM backend, so ~half LDC's closure. DMD only targets
      # x86_64/i686-linux + x86_64-darwin; keep LDC elsewhere. `--wasm`
      # (via `--test-extracted --require-toolchain`) still needs LDC +
      # wasm-ld + a runtime, so those go on PATH even when DMD is the
      # default compiler.
      ciCompiler = if pkgs.stdenv.hostPlatform.system == "x86_64-linux" then pkgs.dmd else pkgs.ldc;
    in
    {
      packages.ci = config.legacyPackages.buildSparklesApp (finalAttrs: {
        pname = "ci";
        version = "0.1.0";

        # `--audit-fences` classifies fence labels against the grammar bundle, so
        # `ci` now links sparkles:syntax -> sparkles:tree-sitter, whose ImportC
        # shim `#include`s <tree_sitter/api.h>. That header is found through
        # pkg-config (dub#3085 feeds `--cflags` to ImportC), so the resolver has
        # to be present at *build* time — without it the build dies on
        # "tree_sitter/api.h: No such file or directory", which also breaks the
        # dev shell, since it depends on this package.
        nativeBuildInputs = [ pkgs.pkg-config ];

        # Runtime deps subtracted from buildSparklesApp's default scrub set:
        # - `ciCompiler` — shells out via PATH (see postFixup)
        # - `pkgs.ldc` / `pkgs.lld` / `pkgs.nodejs` — `--test-extracted --wasm`
        # - `pkgs.curl.out` — `--ci-stats` uses std.net.curl; Phobos bakes an
        #   absolute libcurl path
        # - `pkgs.tree-sitter` — `libs "tree-sitter"` in libs/tree-sitter
        buildInputs = [
          ciCompiler
          pkgs.ldc
          pkgs.lld
          pkgs.nodejs
          pkgs.curl.out
          pkgs.tree-sitter
        ];

        # ci shells out to `dub --single` at runtime to compile examples, so it
        # needs a D compiler + `dub` + git on PATH (via wrapProgram below).
        # gitMinimal avoids the second CPython that full git's git-p4 shebang pulls.
        postFixup =
          let
            path = lib.makeBinPath [
              ciCompiler
              pkgs.ldc
              pkgs.lld
              pkgs.nodejs
              pkgs.dub
              pkgs.gitMinimal
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
            exampleLibPath = lib.optionalString pkgs.stdenv.hostPlatform.isLinux (
              lib.makeSearchPath "lib" [
                pkgs.elfutils.out
                pkgs.libpfm
              ]
            );
            exampleLibArgs = lib.optionalString (
              exampleLibPath != ""
            ) "--prefix LIBRARY_PATH : ${exampleLibPath} --prefix LD_LIBRARY_PATH : ${exampleLibPath}";
          in
          # Best-effort bump of NOFILE: dub/ldc can open many files in parallel
          # builds. Redirect stderr and '|| true' so that on environments where
          # the hard cap is below nofileLimit (some CI runners, restricted
          # sandboxes) the wrapper does not abort under makeWrapper --run's set
          # -e semantics — we just fall back to the inherited limit.
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

      # `buildSparklesApp` derives the source closure from apps/terminal/dub.sdl
      # (transitively: base, core-cli, ghostty, math, and the test-runner
      # shim+impl) and supplies the shared dub plumbing, so only the raylib +
      # libghostty-vt build inputs and the fontconfig runtime wrapper remain.
      packages.terminal = config.legacyPackages.buildSparklesApp (finalAttrs: {
        pname = "terminal";
        version = "0.1.0";

        nativeBuildInputs = [ pkgs.pkg-config ];

        buildInputs = [
          pkgs.raylib
          inputs'.ghostty.packages.libghostty-vt
          inputs'.ghostty.packages.libghostty-vt.dev
        ];

        env = d-toolchain.env;

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
      # build inputs and no runtime wrapper are needed — just the default
      # `buildSparklesApp` closure (core-cli → base, math, test-runner shim+impl).
      packages.terminal-benchmark = config.legacyPackages.buildSparklesApp (finalAttrs: {
        pname = "terminal-benchmark";
        version = "0.1.0";

        meta = {
          description = "CPU/throughput benchmark harness for the sparkles terminal emulator";
          mainProgram = finalAttrs.pname;
        };
      });

      # The sparkles:ui catalog. It reaches raylib through `sparkles:ui-app`'s
      # `full` configuration — the gallery itself names no backend — so the
      # build inputs are the window's, not the application's. libghostty-vt is
      # the Terminal page's: it embeds `sparkles:terminal-view` (TVW7).
      # `fc-match` is on the same footing as the terminal's: the font set
      # shells out to it at runtime, and under `nix run` PATH is the ambient
      # user environment.
      packages.ui-gallery = config.legacyPackages.buildSparklesApp (finalAttrs: {
        pname = "ui-gallery";
        version = "0.1.0";

        nativeBuildInputs = [ pkgs.pkg-config ];
        buildInputs = [
          pkgs.raylib
          inputs'.ghostty.packages.libghostty-vt
          inputs'.ghostty.packages.libghostty-vt.dev
        ];

        env = d-toolchain.env;

        postFixup = ''
          wrapProgram $out/bin/${finalAttrs.pname} \
            --prefix PATH : ${lib.makeBinPath [ pkgs.fontconfig ]}
        '';

        meta = {
          description = "A browsable catalog of the sparkles:ui toolkit, in a terminal or a window";
          mainProgram = finalAttrs.pname;
        };
      });

      apps.ci = {
        type = "app";
        program = lib.getExe config.packages.ci;
      };

      packages.release = config.legacyPackages.buildSparklesApp (finalAttrs: {
        pname = "release";
        version = "0.1.0";

        # Deliberately UNWRAPPED. `release` shells out to git, `gh`, `ci` and —
        # for the publishing stages — fdroidserver, a JDK, rclone and
        # bundletool. Bundling all of that would put a Python and JVM toolchain
        # into the closure of a tool most often run to create a tag, and CI
        # would download it just to build an APK.
        #
        # So the lean package is the binary alone and takes its tools from
        # PATH, which the dev shell (and CI's own steps) already provide. When
        # it needs something it cannot find, the stage-aware check in
        # `sparkles.release.store.tools` names the missing program and what it
        # was for, rather than failing three steps in.
        #
        # `release-full` below is the same binary with everything pinned, for
        # the workstation that actually publishes.
        meta = {
          description = ''
            Cut a sparkles release: scan tags, summarize commits, suggest a bump,
            write notes, tag and publish
          '';
          mainProgram = finalAttrs.pname;
        };
      });

      # The publishing configuration: `release` with every external program it
      # can invoke pinned by this repository rather than resolved from PATH.
      #
      # This is what signs and publishes, so "whatever version happens to be
      # installed" is the wrong answer for all of them — an fdroidserver or
      # apksigner picked up from the environment would decide the bytes users
      # install.
      packages.release-full = pkgs.symlinkJoin {
        name = "release-full-${config.packages.release.version}";
        paths = [ config.packages.release ];
        nativeBuildInputs = [ pkgs.makeWrapper ];
        postBuild =
          let
            path = lib.makeBinPath [
              pkgs.gitMinimal
              pkgs.gh
              config.packages.ci
              pkgs.fdroidserver
              # fdroidserver shells out to keytool, jarsigner and jar, and the
              # nixpkgs package wraps only apksigner onto PATH — `fdroid
              # update` fails outright without a JDK.
              pkgs.jdk_headless
              pkgs.apksigner
              pkgs.rclone
              # Builds the App Bundle for the Play channel.
              pkgs.bundletool
            ];
          in
          ''
            wrapProgram $out/bin/release --prefix PATH : ${path}
          '';
        meta = {
          description = "release, with every publishing tool pinned (signing workstation)";
          mainProgram = "release";
        };
      };

      apps.release = {
        type = "app";
        program = lib.getExe config.packages.release;
      };
      # `nix run .#release-full` — the publishing configuration.
      apps.release-full = {
        type = "app";
        program = lib.getExe config.packages.release-full;
      };
      apps.terminal = {
        type = "app";
        program = lib.getExe config.packages.terminal;
      };

      apps.terminal-benchmark = {
        type = "app";
        program = lib.getExe config.packages.terminal-benchmark;
      };

      apps.ui-gallery = {
        type = "app";
        program = lib.getExe config.packages.ui-gallery;
      };
    };
}
