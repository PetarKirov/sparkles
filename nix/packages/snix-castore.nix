# Snix's `snix-castore`, the oracle of the default content identity
# (docs/specs/build-primitives/filesets/decisions.md, A19):
# `snix-castore ingest <dir>` prints the castore digest of a directory, and
# `content_addressing.castore.snix` compares it with ours. The shells export
# it as $SPARKLES_SNIX_CASTORE; the test skips when that is unset.
#
# Snix is not in nixpkgs, and its repository is not a flake: this builds the
# one CLI from the `snix-src` input with our nixpkgs' Rust. Its few git
# dependencies are pinned by revision in Snix's Cargo.lock, so the builtin
# git fetcher needs no hashes for them. Linux only: that is where the
# oracle runs.
{ inputs, lib, ... }:
{
  perSystem =
    { pkgs, system, ... }:
    lib.optionalAttrs (lib.hasSuffix "-linux" system) {
      packages.snix-castore = pkgs.rustPlatform.buildRustPackage {
        pname = "snix-castore";
        version = "0-unstable-${inputs.snix-src.lastModifiedDate or "0"}";
        src = "${inputs.snix-src}/snix";
        cargoLock = {
          lockFile = "${inputs.snix-src}/snix/Cargo.lock";
          allowBuiltinFetchGit = true;
        };
        cargoBuildFlags = [
          "-p"
          "snix-cli-castore"
        ];
        nativeBuildInputs = [
          pkgs.pkg-config
          pkgs.protobuf
        ];
        # castore's build script compiles `snix/castore/protos/*.proto`
        # relative to this root: the repository's, not the workspace's.
        PROTO_ROOT = "${inputs.snix-src}";
        # Snix's own suites are not the oracle; ours is.
        doCheck = false;
        meta = {
          description = "Snix's castore CLI, the oracle of sparkles' content identity";
          homepage = "https://snix.dev";
          license = lib.licenses.gpl3Only;
          mainProgram = "snix-castore";
        };
      };
    };
}
