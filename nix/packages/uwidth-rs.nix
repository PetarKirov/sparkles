# Reproducible build of the `uwidth-rs` width oracle used by the
# text-conformance harness (Layer 9 — the Rust `unicode-width` crate). Built with
# buildRustPackage from the checked-in Cargo.lock; put on the devshell PATH so
# the harness can shell out to it.
{ lib, ... }:
{
  perSystem =
    { pkgs, ... }:
    let
      fs = lib.fileset;
      crate = ../../libs/base/tools/text-conformance/oracles/uwidth-rs;
      src = fs.toSource {
        root = crate;
        fileset = fs.unions [
          (crate + "/Cargo.toml")
          (crate + "/Cargo.lock")
          (crate + "/src")
        ];
      };
    in
    {
      packages.uwidth-rs = pkgs.rustPlatform.buildRustPackage {
        pname = "uwidth-rs";
        version = "0.1.0";
        inherit src;
        cargoLock.lockFile = crate + "/Cargo.lock";
        meta.mainProgram = "uwidth-rs";
      };
    };
}
