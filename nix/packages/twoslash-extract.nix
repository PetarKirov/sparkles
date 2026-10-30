# The batch/oracle D twoslash extractor (`docs/specs/dmd-lsp/`, EXT1-EXT7).
#
# Unlike the other apps this one has *two* runtime dependencies that are
# invisible in its dub manifest, because they are looked up at analysis time:
#
#   * druntime/phobos sources matching the pinned frontend, via
#     `$SPARKLES_DMD_IMPORT_PATH` (BLD3). Without them DMD cannot resolve
#     `import object;` and calls `fatal()` — historically a *silent* exit(1).
#   * `dub` plus a D compiler, for `--dub` (`dub describe` supplies the
#     enclosing project's import paths/versions/dflags — PRJ2; dub probes the
#     compiler it defaults to, so one must be on PATH as well).
#
# One build, two wrappers over it. `.#twoslash-extract`, the developer tool,
# carries both (`--set-default` for the paths, `--prefix` for the tools), so
# `nix run .#twoslash-extract` works outside the devshell. `passthru.oracle`,
# the extractor `hue` spawns for live types (see hue.nix), carries only the
# import paths: `hue` is a shipped program, whose closure holds no toolchain
# (docs/specs/toolchain/SPEC.md, TC13), and its `--dub` uses the `dub` and
# compiler the user's project builds with. Either way a caller who exports
# their own import paths still wins.
{ lib, ... }:
{
  perSystem =
    { config, pkgs, ... }:
    let
      inherit (config.legacyPackages) d-toolchain;

      # Only needed to answer `dub describe`'s compiler probe. Prefer DMD on
      # x86_64-linux (no LLVM backend — roughly half LDC's closure), matching
      # the `ci` package's reasoning; DMD only targets x86_64/i686-linux and
      # x86_64-darwin, so keep LDC elsewhere.
      dubCompiler = if pkgs.stdenv.hostPlatform.system == "x86_64-linux" then pkgs.dmd else pkgs.ldc;

      unwrapped = config.legacyPackages.buildSparklesApp (finalAttrs: {
        pname = "twoslash-extract";
        version = "0.1.0";

        # Optimized, with the DMD frontend's own assertions left in (`BLD6`).
        # `release` compiles them out, which is how an incomplete fork table
        # crashed every locally built binary while this one carried on with a
        # null `TypeInfo` — a fork that has drifted should say so. It costs
        # ~3% of analysis time and, since the fixup phase strips the debug
        # info the build type asks for, 0.1 MiB of binary (6.6 vs 6.5) and
        # nothing at all in the closure. Assert messages carry their own
        # `file:line`, so they stay readable after that strip.
        dubBuildType = "checked";

        # `dmd:frontend`'s pre-generate step (`config.d`) shells out to
        # `git describe` for the compiler version string. It falls back to the
        # checked-in VERSION file when git *fails*, but throws outright when
        # the binary is missing — so git must exist at build time even though
        # the fetched source has no `.git`.
        nativeBuildInputs = [ pkgs.gitMinimal ];

        env = d-toolchain.env;

        meta = {
          description = "Extract a twoslash node payload from an annotated D sample via DMD-as-a-library";
          mainProgram = finalAttrs.pname;
        };
      });

      importPaths = "${config.packages.dmd-import-paths}/druntime:${config.packages.dmd-import-paths}/phobos";
      # The device side of a `@compute` module (TGT3), where `ldc-vulkan` exists.
      ldcImportPaths =
        lib.optionalString (config.packages ? ldc-import-paths)
          "--set-default SPARKLES_LDC_IMPORT_PATH ${config.packages.ldc-import-paths}/druntime:${config.packages.ldc-import-paths}/phobos";

      wrap =
        { name, tools }:
        pkgs.runCommand name
          {
            nativeBuildInputs = [ pkgs.makeWrapper ];
            inherit (unwrapped) version meta;
            passthru = { inherit unwrapped; };
          }
          ''
            makeWrapper ${lib.getExe unwrapped} $out/bin/${unwrapped.pname} \
              --set-default SPARKLES_DMD_IMPORT_PATH ${importPaths} \
              ${ldcImportPaths} \
              ${lib.optionalString (tools != [ ]) "--prefix PATH : ${lib.makeBinPath tools}"}
          '';
    in
    {
      packages.twoslash-extract =
        (wrap {
          name = "twoslash-extract-${unwrapped.version}";
          tools = [
            dubCompiler
            pkgs.dub
            pkgs.gitMinimal
          ];
        }).overrideAttrs
          (old: {
            passthru = old.passthru // {
              oracle = wrap {
                name = "twoslash-extract-oracle-${unwrapped.version}";
                tools = [ ];
              };
            };
          });

      apps.twoslash-extract = {
        type = "app";
        program = lib.getExe config.packages.twoslash-extract;
        meta.description = config.packages.twoslash-extract.meta.description;
      };
    };
}
