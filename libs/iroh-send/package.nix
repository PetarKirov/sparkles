# The iroh bridge of `sparkles:iroh-send`, written as nixpkgs writes a package
# (callPackage with nixpkgs' own arguments): `libsparkles_iroh_send.so`, which
# the fileset explorer and `fsx` load at run time to send and to receive a
# collection as `sendme` does, and with `withOracle`, `iroh-collection`, the
# oracle of the D collection (content addressing `CAI1`).
#
# Both are built inside `sendme`'s own source tree, as targets of its package,
# against its Cargo.lock with one edge more: the receive half names bao-tree,
# which the lock already holds through iroh-blobs, so no crate is added and
# the vendored sources are the ones the upstream lock names.
{
  lib,
  stdenv,
  rustPlatform,
  runCommand,
  sendme,
  withOracle ? false,
}:
let
  bridge = ./rust;
  lock = runCommand "sendme-${sendme.version}-Cargo.lock" { } ''
    sed '/^name = "sendme"$/,/^]$/ s/^ "anyhow",$/ "anyhow",\n "bao-tree",/' ${sendme.src}/Cargo.lock > $out
    grep -A4 '^name = "sendme"$' $out | grep -q '"bao-tree"' || { echo "the lock's sendme entry was not patched" >&2; exit 1; }
  '';
in
rustPlatform.buildRustPackage {
  pname = "sparkles-iroh-send";
  inherit (sendme) version src;
  cargoLock.lockFile = lock;

  postPatch = ''
    cp ${bridge}/sparkles_iroh_send.rs ${bridge}/sparkles_iroh_receive.rs ${bridge}/iroh_collection.rs src/
    cat ${bridge}/targets.toml >> Cargo.toml
    cp ${lock} Cargo.lock
  '';

  cargoBuildFlags = [
    "--lib"
  ]
  ++ lib.optionals withOracle [
    "--bin"
    "iroh-collection"
  ];
  doCheck = false;

  # The library, and the oracle when asked for; `sendme`'s own binary is not
  # installed.
  postInstall = ''
    mkdir -p $out/lib
    find target -name libsparkles_iroh_send${stdenv.hostPlatform.extensions.sharedLibrary} -path '*/release/*' -exec cp {} $out/lib/ \;
    ${lib.optionalString (!withOracle) "rm -rf $out/bin"}
  '';

  passthru = { inherit lock; };

  meta = {
    description = "sendme's send and receive, as a library a D program loads at run time";
    license = with lib.licenses; [
      mit
      asl20
    ];
  }
  // lib.optionalAttrs withOracle { mainProgram = "iroh-collection"; };
}
