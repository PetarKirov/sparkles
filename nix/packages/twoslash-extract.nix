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
# Both are wrapped in with `--set-default`/`--prefix`, so `nix run
# .#twoslash-extract` — and `hue`'s live-types oracle, which spawns this
# binary (see hue.nix) — work outside the devshell, while a caller who
# exports their own still wins.
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
    in
    {
      packages.twoslash-extract = config.legacyPackages.buildSparklesApp (finalAttrs: {
        pname = "twoslash-extract";
        version = "0.1.0";

        # A genuine runtime reference (see postFixup), so buildSparklesApp
        # subtracts it from the disallowed-leak set instead of rejecting it —
        # this matters where `dubCompiler` *is* the build compiler (LDC).
        buildInputs = [ dubCompiler ];

        env = d-toolchain.env;

        postFixup =
          let
            path = lib.makeBinPath [
              dubCompiler
              pkgs.dub
              pkgs.gitMinimal
            ];
            importPaths = "${config.packages.dmd-import-paths}/druntime:${config.packages.dmd-import-paths}/phobos";
          in
          ''
            wrapProgram $out/bin/${finalAttrs.pname} \
              --set-default SPARKLES_DMD_IMPORT_PATH ${importPaths} \
              --prefix PATH : ${path}
          '';

        meta = {
          description = "Extract a twoslash node payload from an annotated D sample via DMD-as-a-library";
          mainProgram = finalAttrs.pname;
        };
      });

      apps.twoslash-extract = {
        type = "app";
        program = lib.getExe config.packages.twoslash-extract;
      };
    };
}
