# Runtime source import paths for sparkles:dmd-lsp semantic analysis
# (docs/specs/dmd-lsp/feature-requirements.md, BLD3).
#
# DMD-as-a-library resolves `import object;` / `import std.*;` against real
# druntime/phobos *sources* at analysis time. They must match the pinned
# frontend: druntime comes from the dmdserver-dub fork checkout itself
# (`inputs.dmd-src`, locked with the rest of the SBOM; keep it in lockstep
# with nix/dub-lock.json's `dmd` entry), and phobos from dlang/phobos at the
# fork's VERSION tag (v2.113.0-beta.1, `inputs.phobos-src`). The devshell
# (and app wrappers) expose the pair as the colon-separated
# $SPARKLES_DMD_IMPORT_PATH; tests skip when it is unset.
{ inputs, ... }:
{
  perSystem =
    { pkgs, ... }:
    let
      dmdSrc = inputs.dmd-src;
      phobosSrc = inputs.phobos-src;
    in
    {
      packages.dmd-import-paths = pkgs.linkFarm "sparkles-dmd-import-paths" [
        {
          name = "druntime";
          path = "${dmdSrc}/druntime/src";
        }
        {
          name = "phobos";
          path = phobosSrc;
        }
      ];
    };
}
