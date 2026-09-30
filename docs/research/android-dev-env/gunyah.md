# Gunyah, AVF and protected guests (Qualcomm / Linux)

Qualcomm devices can expose a working hardware VM route, but the firmware, driver, VMM and guest verification chain form a device-specific stack.

| Field          | Value                                                                                         |
| -------------- | --------------------------------------------------------------------------------------------- |
| Language       | Kernel/VMM native code; shell demonstration; managed example app                              |
| License        | Per-component terms; DroidVM GPL-3.0 with additional permissions                              |
| Repository     | [Gunyah device guide][guide]; [DroidVM backend][backend]; [AOSP protected firmware][firmware] |
| Documentation  | [Guide][guide], [pvmfw route][pvmfw-guide], [network setup][network]                          |
| Category       | Vendor hypervisor; protected VM / privileged custom VMM                                       |
| Prerequisites  | Exposed Gunyah driver, compatible VMM/kernel, appropriate permissions and firmware            |
| Custom app fit | Native terminal plus owned privileged helper or compatible AVF owner                          |

## Overview

### What it solves

A Gunyah-backed guest can run Linux independently of Android's app syscall restrictions. A custom terminal could connect to a guest PTY without using the Termux app or Android Terminal. A complete NixOS adaptation remains a separate task from reaching a Linux console.

### Design philosophy

The guide describes its scope as: “A guide to run protected VM with gunyah on a SD 8 elite device.” [Source][guide] Its declared test platform is a rooted, unlocked Lenovo Y700 gen4 with Android 15 and a specific ZUXOS build. The route is evidence of possibility on that setup, not a universal Snapdragon support promise.

## How it works

The guide invokes a patched `crosvm` with `--protected-vm-without-firmware`, `--disable-sandbox`, `--no-balloon`, a specified SWIOTLB budget and root memlock setup. It demonstrates a custom ARM64 Linux kernel with a Debian root disk. Some documented output reaches a systemd emergency shell: inspect the demonstrated endpoint rather than treating a boot log as finished development UX. Booting a Microdroid kernel/initrd without its expected disks can panic and is not a complete Microdroid deployment.

[The pvmfw variant][pvmfw-guide] supplies signed boot inputs, an instance partition and device-tree data. The author points older generations toward that route, but the declared environment remains the same Elite device; this is not independently demonstrated gen2/gen3 coverage. Firmware acceptance of an AOSP test key on one board does not imply the same key works on production devices generally.

[Current DroidVM code][backend] selects Gunyah explicitly and handles protected, without-firmware and pseudo-unprotected modes, with additional graphics and host-sharing machinery. Its pseudo-unprotected mode is a fork-specific strategy with different confidentiality implications, not the official AVF nonprotected capability bit. The project's [device registry][registry] is a candidate compatibility list, not a set of locally verified devices.

## Analysis

### Deployment and permissions

Separate two paths: **stock AVF** through the framework and **root-owned crosvm** using vendor nodes directly. On the [Xiaomi Pad 8 Pro][devices], a locked, enforcing Android 16 build exposes `/dev/gunyah` and AVF; the stock protected Microdroid guest actually boots through the ADB VM tool. This is stronger evidence than the rooted guide for this device's stock framework, but it still does not establish custom NixOS acceptance or an ordinary app's permission path.

World-readable/writable Unix permissions on `/dev/gunyah` do not override its `vendor_gunyah_dev` SELinux label. Shell or system service access must not be projected onto an app UID. Likewise the Snapdragon 888 phone tested here has neither an exposed Gunyah node nor AVF feature. A SoC generation label alone is insufficient.

### Nix compatibility and services

A full ARM64 Linux guest can in principle use NixOS outputs, provided its kernel/device tree/disk transport and firmware verification are adapted. That is an **inference**, not a local NixOS boot result. [Microdroid's architecture][microdroid] targets a minimal Android native-payload environment with Bionic and no full Android system server. Dropping a NixOS userspace into a payload library does not provide glibc, canonical store paths or systemd boot.

[Protected firmware][firmware] validates guest boot inputs and binds identity to them. Kernel/initrd signing, instance state, SWIOTLB requirements and vendor firmware constraints belong in the acceptance test. Do not flash a different pvmfw as a routine research probe.

[AOSP's boot implementation][firmware-boot] passes its embedded `PUBLIC_KEY` to `verify_payload`. The trusted key is therefore a firmware input, not an arbitrary key supplied by the app. The Lenovo guide's known test-key acceptance must be verified independently before attempting equivalent signed custom images on the Pad.

### Terminal and no-DEX integration

A native helper can own `crosvm`, descriptors and guest transport while the no-DEX terminal remains a client. The helper must have independently provisioned authority and survive/recover across UI exits. [DroidVM][backend] is useful prior art for native VM launching and console plumbing; its managed application architecture does not meet the no-DEX constraint directly. The AVF framework/JNI questions from [the AVF deep dive][avf] also apply when Gunyah is underneath AVF.

### Files, networking and DNS

[The guide's network setup][network] uses root-managed TAP/veth/NAT and static guest networking. It requires privileges beyond normal app sockets and should not be confused with the stock AVF networking contract. Guest DNS and VPN routing need validation through whichever route is chosen. Older protected-memory sharing limitations and newer fork graphics/hostshare support must be versioned; a blanket “Gunyah cannot share files or graphics” is no longer supported by current DroidVM source.

### Performance and isolation

Hardware execution can avoid PRoot tracing, but restricted shared-memory I/O, bounce buffers and SWIOTLB sizing can dominate particular workloads. `--disable-sandbox` changes host VMM confinement; protected guest confidentiality does not automatically imply a safely confined root VMM. Pseudo-unprotected sharing must not be sold as protected confidentiality. No local Nix build or cross-backend benchmark was run.

### Lifecycle and maintenance

The independent owner must manage VMM lifetime, guest shutdown, instance-state reset after image identity changes and persistent root disks. Vendor kernel/VMM forks and firmware policy add maintenance beyond the guest Nix configuration. The stock Pad Microdroid probe ended with no remaining VM; see [raw evidence and cleanup][devices]. The Pixel investigation is deferred rather than represented as an unperformed comparison.

## Strengths

- Real upstream Linux boot demonstrations and a local stock protected guest boot.
- Independent guest kernel and potential full NixOS semantics.
- Both framework and privileged-helper designs can keep the terminal UI independent.

## Weaknesses

- Custom Linux acceptance and unprotected modes vary with firmware and VMM forks.
- Root-based demonstrations are not ordinary-app deployment proofs.
- NixOS guest integration, app ownership and protected I/O require substantial validation.

## Key design decisions and trade-offs

| Decision                                                  | Rationale                             | Trade-off                                               |
| --------------------------------------------------------- | ------------------------------------- | ------------------------------------------------------- |
| Start with stock AVF capability checks                    | Uses installed service/firmware stack | Protected-only mode may block simplest NixOS route      |
| Use an owned root VMM helper where explicitly provisioned | Flexible custom kernels/disks         | Security and vendor maintenance burden                  |
| Treat pvmfw as a boot verification stage                  | Correct protected-guest model         | Signed inputs and instance identity become requirements |
| Keep guest services independent of Terminal               | Custom application ownership          | New transport/control implementation                    |

## Sources

- [Guide][guide], [protected boot variant][pvmfw-guide], [networking][network].
- [DroidVM source][backend], [pvmfw][firmware], [Microdroid][microdroid].
- [Local device evidence][devices] and [revision ledger][sources].

<!-- References -->

[guide]: https://github.com/polygraphene/gunyah-on-sd-guide/blob/61ac570c2d467274d1d7d73605dcc685af6945b8/README.md
[pvmfw-guide]: https://github.com/polygraphene/gunyah-on-sd-guide/blob/61ac570c2d467274d1d7d73605dcc685af6945b8/PVMFW.md
[network]: https://github.com/polygraphene/gunyah-on-sd-guide/blob/61ac570c2d467274d1d7d73605dcc685af6945b8/NETWORK.md
[backend]: https://github.com/Droid-VM/DroidVM/blob/5c896915789294e3dbb9af81d6a53ee5f436887b/app/src/main/java/cn/classfun/droidvm/daemon/vm/backend/CrosvmBackendInstance.java
[registry]: https://github.com/Droid-VM/DroidVM/blob/5c896915789294e3dbb9af81d6a53ee5f436887b/app/src/main/assets/data/gunyah.yaml
[firmware]: https://android.googlesource.com/platform/packages/modules/Virtualization/+/175a51b30123fa6b02b541f1969665708f7ec2c3/guest/pvmfw/README.md
[firmware-boot]: https://android.googlesource.com/platform/packages/modules/Virtualization/+/175a51b30123fa6b02b541f1969665708f7ec2c3/guest/pvmfw/src/main.rs
[microdroid]: https://android.googlesource.com/platform/packages/modules/Virtualization/+/175a51b30123fa6b02b541f1969665708f7ec2c3/build/microdroid/README.md
[devices]: ./device-validation/index.md
[avf]: ./avf.md
[sources]: ./sources.md
