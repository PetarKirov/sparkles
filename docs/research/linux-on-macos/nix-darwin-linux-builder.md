# nix-darwin `linux-builder` and peers (NixOS VM)

The classical way to build Linux on macOS: a persistent NixOS guest,
reached over SSH, registered in `nix.buildMachines`. Two transports
(QEMU and Virtualization.framework) and one open-source
`external-builders` reimplementation (IOHK).

|          |                                                      |
| -------- | ---------------------------------------------------- |
| Language | Nix + NixOS                                          |
| License  | MIT (nix-darwin / nixpkgs)                           |
| Module   | [`nix-darwin/modules/nix/linux-builder.nix`][module] |
| Manual   | [nixpkgs darwin-builder section][manual]             |
| Category | Persistent remote builder                            |

## Overview

### What it solves

> `darwin.linux-builder` provides a way to bootstrap a Linux remote
> builder on a macOS machine.

— [nixpkgs manual][manual]

This host's `/etc/nix/machines` is **missing**. `builders =
@/etc/nix/machines` therefore names nothing. nix-darwin _does_ write
`external-builders` for Determinate; it does **not** enable
`nix.linux-builder`.

### Design philosophy

A real NixOS system, with its own store image, SSH, and
`nix-daemon`. The host Nix is a client. Persistence of `/nix/store` on
the guest is the point: rebuilds are incremental.

## How it works

**QEMU path.** `pkgs.darwin.linux-builder` →
`nixos/modules/profiles/nix-builder-vm.nix`. launchd runs
`create-builder`. SSH on localhost:31022, user `builder`, host key
published in the module (a known private key — acceptable only because
the VM is local). `useNixStoreImage = true` so the guest store is a
snapshot, not a bind of the host store (otherwise the host's lockfile
deadlocks the guest).

**VZ path.** `pkgs.darwin.linux-builder-vz` (macOS 13+, Apple silicon).
Rosetta in the guest for `x86_64-linux` instead of TCG. Same SSH
identity, so switching is a disk-format change (delete the qcow2; vz
writes raw). Nested virt (`virtualisation.vz.nestedVirtualization`) on
macOS 15+ / M3+ gives the guest `/dev/kvm` for NixOS tests.

**IOHK `nix-linux-builder`**
([`65ecc7687e0df4b3e634e3e026f8e7822a961800`][iohk], v0.3.0) implements
the same `external-builders` JSON protocol as Determinate, in-process
with Virtualization.framework, no SSH. VirtioFS of `/nix/store` plus an
ext4 loop for `/build` because VirtioFS does not honour `DAC_OVERRIDE`.
UID mapping patches guest passwd to Darwin `nixbld` UIDs (351–382).
`nix-linux-shell` is an interactive fail-into-VM. Prebuilt kernel/initrd
on GitHub Releases break the bootstrap cycle. **Not gated.**

## Analysis spine

1. **Execution model.** Persistent VM (nix-darwin) vs per-drv VM (IOHK /
   Determinate).
2. **Nix integration.** SSH `buildMachines` vs `external-builders`.
3. **Architectures.** QEMU: typically host-arch Linux. VZ / IOHK: both
   Linux arches via Rosetta.
4. **Store sharing.** Isolated guest store (nix-darwin QEMU) vs VirtioFS
   host store (IOHK, Determinate).
5. **Availability.** Not enabled here. IOHK is an opt-in flake input.
6. **Interactive vs derivation.** SSH into `builder@linux-builder` is
   interactive; the Nix integration is still derivation-only.

## Strengths

- Known quantity; Hydra-style `supportedFeatures` (`kvm`,
  `big-parallel`).
- Guest NixOS can be reconfigured once the first builder exists.
- IOHK is the ungated Determinate-shaped tool.

## Weaknesses

- First boot is a large NixOS closure; chicken-and-egg without
  substitutes.
- QEMU on macOS is slower than VZ; DNS over SLiRP needs a public
  nameserver workaround.
- Persistent disk grows; `ephemeral` wipes it.
- Does not by itself run `ci --test` in a working tree.

## Key design decisions and trade-offs

| Decision                    | Rationale                  | Trade-off                         |
| --------------------------- | -------------------------- | --------------------------------- |
| SSH remote builder          | Works with every Nix       | Keys, ports, launchd VM           |
| Isolated guest store (QEMU) | Avoid store lock deadlocks | Duplicate closure                 |
| IOHK ext4 loop for `/build` | VirtioFS `DAC_OVERRIDE`    | Extra image, not a POSIX fs share |

## Sources

- [nix-darwin module][module]
- [nixpkgs manual][manual]
- [IOHK README][iohk]

<!-- References -->

[module]: https://github.com/nix-darwin/nix-darwin/blob/4cff07de74b50e64bdd68cd4e722ab5b6b35ee48/modules/nix/linux-builder.nix
[manual]: https://github.com/NixOS/nixpkgs/blob/7016c95300d32ecec6a5bea651c63b5d09e3c0df/doc/packages/darwin-builder.section.md
[iohk]: https://github.com/input-output-hk/nix-linux-builder/blob/65ecc7687e0df4b3e634e3e026f8e7822a961800/README.md
