# Runtime source import paths for sparkles:dmd-lsp semantic analysis
# (docs/specs/dmd-lsp/feature-requirements.md, BLD3).
#
# DMD-as-a-library resolves `import object;` / `import std.*;` against real
# druntime/phobos *sources* at analysis time. They must match the pinned
# frontend: druntime comes from the dmdserver-dub fork checkout itself (the
# same fetch as the dub lock entry — `lib.importJSON` keeps a single source of
# truth for rev + hash), and phobos from dlang/phobos at the fork's VERSION
# tag (v2.113.0-beta.1). The devshell (and app wrappers) expose the pair as
# the colon-separated $SPARKLES_DMD_IMPORT_PATH; tests skip when it is unset.
{ lib, ... }:
{
  perSystem =
    { pkgs, ... }:
    let
      dmdLock = (lib.importJSON ../dub-lock.json).dependencies.dmd;
      dmdSrc = pkgs.fetchgit {
        url = dmdLock.repository;
        rev = dmdLock.version;
        sha256 = dmdLock.sha256;
      };
      phobosSrc = pkgs.fetchFromGitHub {
        owner = "dlang";
        repo = "phobos";
        # v2.113.0-beta.1 — must track the dub-lock dmd pin's VERSION.
        rev = "8c9d000230f090aa2f552f27d96af7c474198513";
        hash = "sha256-Bx770VvpIjcJ+ZA9mhCAAPu+96sdFGuSxTSZ4LwksoM=";
      };
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
