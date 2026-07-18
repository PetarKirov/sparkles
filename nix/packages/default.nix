{ lib, ... }:
{
  imports = [
    ./examples.nix
  ];

  perSystem =
    { config, pkgs, ... }:
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
    };
}
