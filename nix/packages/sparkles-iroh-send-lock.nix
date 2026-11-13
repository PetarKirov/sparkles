# `sendme` 0.37's Cargo.lock with one edge more: the bridge's receive half
# (libs/iroh-send/rust/sparkles_iroh_receive.rs) names bao-tree, which the lock
# already holds through iroh-blobs, so the `sendme` package now lists it among
# its dependencies. No crate is added or changed, so the vendored sources are
# the ones the upstream lock names.
#
# Both builds of the bridge vendor from this lock and copy it into the tree
# (`sparkles-iroh-send.nix`, `android/iroh-send.nix`).
{ runCommand, sendme }:
runCommand "sendme-${sendme.version}-Cargo.lock" { } ''
  sed '/^name = "sendme"$/,/^]$/ s/^ "anyhow",$/ "anyhow",\n "bao-tree",/' ${sendme.src}/Cargo.lock > $out
  grep -A4 '^name = "sendme"$' $out | grep -q '"bao-tree"' || { echo "the lock's sendme entry was not patched" >&2; exit 1; }
''
