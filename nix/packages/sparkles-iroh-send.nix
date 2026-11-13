# The iroh bridge of `sparkles:iroh-send` (docs/specs/fileset-explorer, X18):
# `libsparkles_iroh_send.so`, which the fileset explorer loads at run time to
# send a fileset as `sendme send` sends a directory, and `iroh-collection`,
# the oracle of the D collection (content addressing `CAI1`).
#
# Both are built inside `sendme`'s own source tree, as targets of its package,
# so its `Cargo.lock` builds them unchanged and the flake fetches no crate
# `sendme` does not already use. The sources are libs/iroh-send/rust.
#
# The shells export the library as $SPARKLES_IROH_SEND_LIB and the oracle as
# $SPARKLES_IROH_COLLECTION; `sendme` itself, the receiver of FXS7, is
# $SPARKLES_SENDME.
{ lib, ... }:
{
  perSystem =
    { pkgs, ... }:
    let
      bridge = ../../libs/iroh-send/rust;
      lock = pkgs.callPackage ./sparkles-iroh-send-lock.nix { };
    in
    {
      packages.sparkles-iroh-send = pkgs.rustPlatform.buildRustPackage {
        pname = "sparkles-iroh-send";
        inherit (pkgs.sendme) version src;
        cargoLock.lockFile = lock;

        postPatch = ''
          cp ${bridge}/sparkles_iroh_send.rs ${bridge}/sparkles_iroh_receive.rs ${bridge}/iroh_collection.rs src/
          cat ${bridge}/targets.toml >> Cargo.toml
          cp ${lock} Cargo.lock
        '';

        cargoBuildFlags = [
          "--lib"
          "--bin"
          "iroh-collection"
        ];
        doCheck = false;

        # The library beside the oracle; `sendme`'s own binary is not built.
        postInstall = ''
          mkdir -p $out/lib
          find target -name libsparkles_iroh_send.so -path '*/release/*' -exec cp {} $out/lib/ \;
        '';

        meta = {
          description = "sendme's send, as a library the fileset explorer loads, and the collection oracle";
          license = with lib.licenses; [
            mit
            asl20
          ];
          mainProgram = "iroh-collection";
        };
      };
    };
}
