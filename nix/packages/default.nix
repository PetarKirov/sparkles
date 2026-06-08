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
      # CI). Prefer DMD on x86_64-linux: no LLVM backend, so ~half LDC's closure.
      # DMD only targets x86_64/i686-linux + x86_64-darwin; keep LDC elsewhere.
      ciCompiler = if pkgs.stdenv.hostPlatform.system == "x86_64-linux" then pkgs.dmd else pkgs.ldc;
    in
    {
      packages.ci = config.legacyPackages.buildSparklesApp (finalAttrs: {
        pname = "ci";
        version = "0.1.0";

        # ci references `ciCompiler` at runtime (see postFixup), so buildSparklesApp
        # subtracts this buildInput from the disallowed-leak set rather than
        # rejecting the reference.
        buildInputs = [ ciCompiler ];

        # ci shells out to `dub --single` at runtime to compile examples, so it
        # needs a D compiler + `dub` + git on PATH (via wrapProgram below).
        # gitMinimal avoids the second CPython that full git's git-p4 shebang pulls.
        postFixup =
          let
            path = lib.makeBinPath [
              ciCompiler
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

      apps.ci = {
        type = "app";
        program = lib.getExe config.packages.ci;
      };

      packages.release = config.legacyPackages.buildSparklesApp (finalAttrs: {
        pname = "release";
        version = "0.1.0";

        # `release` bundles the flake-built `ci` (pinned pre-flight checks) plus
        # git and `gh`; LLM agents are user-provided, found on the caller's PATH.
        postFixup =
          let
            path = lib.makeBinPath [
              pkgs.gitMinimal
              pkgs.gh
              config.packages.ci
            ];
          in
          ''
            wrapProgram $out/bin/${finalAttrs.pname} \
              --prefix PATH : ${path}
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
