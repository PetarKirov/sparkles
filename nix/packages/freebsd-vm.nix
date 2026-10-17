# A local FreeBSD virtual machine (apps/ci/tools/freebsd-vm.d): the release's
# cloud-init image, booted under KVM, for the `_umtx_op` seam of
# sparkles.base.sync and anything else no hosted runner reaches.
#
#   nix run .#freebsd-vm -- test    # boot, copy the working tree, run base.sync
#
# The image is fetched, not built, and only this package retains it, so the
# package stays out of the desktop aggregate (nix/flake-exclusions.nix).
# x86_64 Linux only: the image is amd64, and the machine needs KVM.
{ lib, ... }:
{
  perSystem =
    { pkgs, system, ... }:
    let
      release = "14.5";
      image = pkgs.fetchurl {
        url = "https://download.freebsd.org/releases/VM-IMAGES/${release}-RELEASE/amd64/Latest/FreeBSD-${release}-RELEASE-amd64-BASIC-CLOUDINIT-ufs.qcow2.xz";
        # CHECKSUM.SHA256 beside the image.
        sha256 = "a2a8cd84cd59077225a0e75ead852e8a08fe26f9ab251a96d5a4fd4fe1db4454";
      };
    in
    lib.optionalAttrs (system == "x86_64-linux") {
      packages.freebsd-vm =
        pkgs.runCommand "freebsd-vm-${release}"
          {
            nativeBuildInputs = [
              pkgs.ldc
              pkgs.makeWrapper
            ];
            meta.mainProgram = "freebsd-vm";
          }
          ''
            mkdir -p $out/bin
            ldc2 -O -preview=in -preview=dip1000 -of=$out/bin/freebsd-vm \
              ${../../apps/ci/tools/freebsd-vm.d}
            rm -f $out/bin/*.o
            wrapProgram $out/bin/freebsd-vm \
              --set FREEBSD_VM_IMAGE ${image} \
              --prefix PATH : ${
                lib.makeBinPath [
                  pkgs.qemu_kvm
                  pkgs.xorriso
                  pkgs.xz
                  pkgs.openssh
                  pkgs.gnutar
                  pkgs.git
                  pkgs.coreutils
                ]
              }
          '';
    };
}
