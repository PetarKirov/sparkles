# Apple Containerization (Swift package)

The library Apple `container` is built on: OCI image handling, ext4
population, a minimal Linux kernel, and a guest agent (`vminitd`) over
vsock. Virtualization.framework on macOS; cloud-hypervisor + KVM on
Linux.

|               |                                                                             |
| ------------- | --------------------------------------------------------------------------- |
| Language      | Swift                                                                       |
| License       | Apache-2.0                                                                  |
| Repository    | [`apple/containerization`][gh] @ `fc9e63846f365151aa6d3bf39d65e662abf431fc` |
| Documentation | [README][gh], [API docs][api]                                               |
| Category      | VMM-backed Linux container runtime                                          |

## Overview

### What it solves

> The Containerization package allows applications to use Linux
> containers. Containerization is written in Swift and uses
> Virtualization.framework on Apple silicon.

— [README][gh]

Sparkles does not link this package. It matters because every property
of `container run` (Rosetta, VirtioFS, one VM per container, nested
virt) is defined here.

### Design philosophy

Each Linux container is its own lightweight VM. `vminitd` is PID 1 and
exports gRPC over vsock so the host can configure the environment and
spawn the OCI process. A minimal kernel config trades features for boot
time; per-container kernels are a first-class API.

## How it works

**macOS backend:** `VZVirtualMachineManager` — Virtualization.framework,
no extra binaries.

**Linux backend:** `CHVirtualMachineManager` — one `cloud-hypervisor`
per VM, virtio-blk, virtio-fs (`virtiofsd`), TAP, hybrid vsock to the
same `vminitd`. Integration tests run _inside_ an Apple `container` with
`--virtualization` (nested KVM).

**Rosetta:** "Use Rosetta 2 for running linux/amd64 containers on Apple
silicon." That is `--rosetta` / `--arch amd64` on the CLI. Confirmed:
the x86_64 `uname` and the x86_64 Nix `hello` both ran.

**Kernel:** in-tree config under `kernel/`; tests start at Linux
6.14.9. Prebuilt Kata kernels are documented as a drop-in if `VIRTIO`
is built-in. Apple `container` 1.1.0 on this host booted **6.18.15**.

`vminitd` is compiled as a static Linux binary _inside a Linux
container_, not cross-compiled on the Mac — the package build depends
on the `container` CLI.

## Analysis spine

1. **Execution model.** VMM abstraction (`VirtualMachineManager` /
   `VirtualMachineInstance`); one VM; vsock guest agent.
2. **Nix integration.** None. Could in principle be an
   `external-builders` helper (that is what Determinate and IOHK wrote
   in Swift/C instead of this package).
3. **Architectures.** arm64 native; amd64 via Rosetta 2.
4. **Store sharing.** VirtioFS shares; ext4 for root. IOHK's ext4-loop
   workaround for `DAC_OVERRIDE` is the same class of bug.
5. **Availability.** Library requires macOS 26 + Xcode 26 to _build_.
   Consuming the signed `container` CLI does not.
6. **Interactive vs derivation.** Runtime for processes, not Nix drvs.

## Strengths

- The isolation story is a real VM, not a jail.
- Rosetta for `linux/amd64` is a supported path, not qemu-user.
- Nested virt on M3+ is explicit (`--virtualization`).

## Weaknesses

- Not a Nix builder.
- Guest memory is not fully ballooned back to macOS (documented on the
  CLI side).
- Building the package itself needs a working `container` CLI (chicken
  and egg for the guest init).

## Key design decisions and trade-offs

| Decision               | Rationale                            | Trade-off                       |
| ---------------------- | ------------------------------------ | ------------------------------- |
| One VM per container   | Isolation, dedicated addressing      | RAM, no shared-kernel density   |
| `vminitd` over vsock   | Host configures the guest after boot | Custom guest agent, not systemd |
| Rosetta instead of TCG | Fast `linux/amd64` on Apple silicon  | Apple silicon + Rosetta only    |

## Sources

- [README][gh]
- [API documentation][api]
- [kernel/README][kernel]

<!-- References -->

[gh]: https://github.com/apple/containerization
[api]: https://apple.github.io/containerization/documentation/
[kernel]: https://github.com/apple/containerization/blob/fc9e63846f365151aa6d3bf39d65e662abf431fc/kernel/README.md
