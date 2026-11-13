# The iroh bridge of `sparkles:iroh-send` (docs/specs/fileset-explorer, X18;
# docs/specs/fsx, XR): `libsparkles_iroh_send.so`, which the fileset explorer
# and `fsx` load at run time to send and to receive a collection as `sendme`
# does, and `iroh-collection`, the oracle of the D collection (content
# addressing `CAI1`).
#
# The package is libs/iroh-send/package.nix, written as nixpkgs writes one so
# that `fsx`'s package can call it: both targets are built inside `sendme`'s
# own source tree, against its Cargo.lock with one edge more (bao-tree, which
# the lock already holds), so the flake fetches no crate `sendme` does not use.
#
# The shells export the library as $SPARKLES_IROH_SEND_LIB and the oracle as
# $SPARKLES_IROH_COLLECTION; `sendme` itself, the receiver of FXS7, is
# $SPARKLES_SENDME.
{ ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      # libs/iroh-send/package.nix, which `fsx`'s package calls too.
      packages.sparkles-iroh-send = pkgs.callPackage ../../libs/iroh-send/package.nix {
        withOracle = true;
      };
    };
}
