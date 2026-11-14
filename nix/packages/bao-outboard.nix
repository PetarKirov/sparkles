# The oracle of the iroh outboard
# (docs/specs/build-primitives/content-addressing/decisions.md, C2):
# `bao-outboard <file>...` prints each file's BLAKE3 root and the pre-order
# outboard that n0's `bao-tree` computes at iroh's 16 KiB chunk groups, and
# `content_addressing.outboard.baoTree` compares them with ours. The shells
# export it as $SPARKLES_BAO_OUTBOARD; the test skips when that is unset.
#
# `bao-tree` is a library with no CLI in nixpkgs, so the few lines in
# ./bao-outboard call it; its Cargo.lock pins the crate.
{ lib, ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      packages.bao-outboard = pkgs.rustPlatform.buildRustPackage {
        pname = "bao-outboard";
        version = "0.1.0";
        src = ./bao-outboard;
        cargoLock.lockFile = ./bao-outboard/Cargo.lock;
        meta = {
          description = "bao-tree's outboard of a file, the oracle of sparkles' iroh outboards";
          license = with lib.licenses; [
            mit
            asl20
          ];
          mainProgram = "bao-outboard";
        };
      };
    };
}
