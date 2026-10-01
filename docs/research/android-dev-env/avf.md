# Android Virtualization Framework (Android / Linux)

AVF can launch a complete Linux guest, but arbitrary NixOS images and independent app ownership require more than the presence of a virtualization feature.

| Field          | Value                                                                                         |
| -------------- | --------------------------------------------------------------------------------------------- |
| Language       | Java framework; Rust services; native VMM; Nix guest tooling                                  |
| License        | AOSP component licenses; nixos-avf GPL-3.0                                                    |
| Repository     | [AOSP framework][framework]; [nixos-avf][nixos]; [Podroid][engine]                            |
| Documentation  | [Framework README][framework]; [native demo restrictions][native-demo]                        |
| Category       | Android-managed hardware VM                                                                   |
| Prerequisites  | AVF feature/backend; management permission; custom-image API and permission; compatible guest |
| Custom app fit | JNI/framework spike or explicitly owned helper; no Android Terminal dependency                |

## Overview

### What it solves

A guest kernel permits genuine NixOS: systemd, Linux namespaces, ordinary glibc packages and build isolation within the guest. Android still controls VM allocation, host resource limits and access to files/network devices.

### Design philosophy

AVF brokers virtual machines through Android services. Its framework README says: “All of these APIs were introduced in API level 34 (Android 14).” [Source][framework] The same document identifies them as system APIs with a restricted management permission. Treat this as a platform capability with explicit deployment gates.

## How it works

The `android.system.virtualmachine` framework configures a VM and connects to `virtmgr`. [The framework service wrapper][service] spawns the native service with RPC file descriptors; it is not simply a stable public NDK Binder service discovered by name. [The service permission checks][permissions] distinguish `MANAGE_VIRTUAL_MACHINE` from `USE_CUSTOM_VIRTUAL_MACHINE`: raw configs are custom, and several modifications to application configs also cross that gate.

For a Linux guest, [custom image configuration][image] supplies kernel/initrd/disks, console input/output and optional devices. [Podroid][engine] demonstrates an independently owned app engine, including a virtio console (`hvc0`), guest control channels, persistent storage and filesystem/network bridges. Its [reflection wrapper][reflect] also intercepts private framework/AIDL structures; this is substantial platform-version coupling.

[Nixos-avf's guest module][nixos] imports the QEMU guest profile and generates a disk/configuration for Android Terminal. [Image finishing][finish] splits EFI/root partitions, emits `vm_config.json`, and adjusts filesystem details for Android tooling. The default configuration requests an **unprotected** guest, 4096 MiB memory and networking. That is useful guest-building prior art, not an independent custom terminal backend ready to consume unchanged.

## Analysis

### Deployment and permissions

[The framework README][framework] documents privileged apps on Android 14, preinstalled apps on Android 15, and explicit ADB management grants to other apps for development on both. Thus “all sideloaded apps are impossible” is too strong. A usable deployment still needs both requested permissions, successful grants, API access and a compatible custom-image path. Shizuku may provide shell authority where installed/authorized; it cannot add an absent backend or bypass arbitrary vendor SELinux policy.

Probe protected and nonprotected capability bits separately. [The Pad 8 Pro observation][devices] is particularly instructive: AVF is present and a protected Microdroid boot succeeds, but `vm info` reports only protected VMs. The usual unsigned, unprotected nixos-avf image cannot be inferred to work there. [Contributor Pixel 7 Pro evidence][pixel7] instead reports both guest modes through `kvm.arm-protected`, with `/dev/kvm` present. The read-only collector launched no guest, and its root-ADB context does not establish app grants or independent ownership. Pixel 10 testing remains deferred; MediaTek hardware is untested.

For MediaTek, [crosvm's GenieZone backend][geniezone] and [the kernel UAPI][gz-uapi] show a distinct `/dev/gzvm` adapter. Support must be established for the exact device/ROM and custom guest, rather than inferred from “MediaTek” or a Dimensity model name. pKVM, GenieZone and Gunyah are separate backend paths beneath the framework.

### Nix compatibility and services

Once a suitable NixOS kernel and disk boot, the guest can use the standard ARM64 Linux cache and systemd. Check guest kernel options, virtio devices, EFI/direct-kernel boot expectations and disk format. Nixos-avf's Terminal guest services exchange a gRPC port file under `/mnt/internal` and run TLS `ttyd`; simply displaying that existing Terminal session would violate the independent-owner requirement. Replace its owner-specific service contract with a custom guest session broker.

Protected guests add boot verification and identity constraints. [pvmfw][pvmfw] validates guest inputs and derives identity from measured boot. AVF support for Microdroid does not prove that arbitrary signed NixOS images are accepted by the vendor boot chain.

### Terminal and no-DEX integration

A NativeActivity can use JNI to instantiate installed framework classes without putting DEX into its own APK. This is an **implementation hypothesis**, not a completed compatibility demonstration. Attach a native worker to ART as the [current app does][baseline], check method/class availability, and initially poll lifecycle state to avoid assuming a custom Java callback subclass exists. Native streams/file descriptors still need careful ownership and backpressure handling.

[Podroid's application][application] enables `HiddenApiBypass`; its Kotlin/reflection solution does not prove a no-DEX route. Android's [non-SDK restrictions][hidden] apply to JNI as well as reflection. A supported platform/helper implementation may be necessary on a particular firmware.

The [native AOSP demo][native-demo] explicitly restricts its route to platform-level VMs. It uses platform RPC bindings and policy not supplied by the ordinary public NDK. Compiling that demo into the APK is not a portable shortcut. An explicit helper must own the VM lifecycle itself and authenticate the app, not borrow Android Terminal's running service.

### Files, networking and DNS

Guest storage should be app-owned and backed up independently of volatile sessions. Host directories can be exported via supported virtiofs/9P mechanisms or an app-level file bridge; Android scoped storage still governs the exporter. Avoid hardcoding another application's private `/mnt/internal` backing paths.

The framework's network option and permission/policy gates are firmware-specific. [Podroid's engine][engine] supplies userspace forwarding as another design; [nixos-avf][nixos] expects Terminal-specific guest services. Test DNS, VPN, offline operation and listen-port exposure through the chosen transport, including authentication for every forwarded terminal/control endpoint.

### Performance and isolation

Hardware guests avoid PRoot syscall interception and provide an independent kernel, at the cost of guest RAM, disk duplication and boot latency. Protected memory changes sharing and I/O constraints. Source comments about console throughput are design clues, not a local benchmark. The Pad's Microdroid success is a boot capability test, not a NixOS performance measurement.

### Lifecycle and maintenance

Persist VM configuration/disks, supervise the owner and reconnect to guest sessions after UI recreation. A foreground owner/helper requires a real Android lifecycle implementation. Nixos-avf and Android Terminal evolve together; Podroid's private-field interception adds another compatibility matrix. Pin guest/kernel tooling and test each supported Android build.

## Strengths

- Full guest Linux/NixOS semantics and independent guest kernel.
- AOSP management stack and real examples of independent app engines.
- Device capability checks permit a clear, honest fallback path.

## Weaknesses

- System/custom APIs, permissions and non-SDK rules vary by release and vendor.
- Protected-only support may exclude the simplest NixOS image route.
- No-DEX app ownership and long-lived background management need a demonstrated integration.

## Key design decisions and trade-offs

| Decision                                              | Rationale                                   | Trade-off                                     |
| ----------------------------------------------------- | ------------------------------------------- | --------------------------------------------- |
| Prefer nonprotected custom Linux guest when supported | Straightforward unsigned NixOS boot         | Unavailable on protected-only firmware        |
| Keep app/helper as explicit VM owner                  | Independent product lifecycle               | Framework/version integration work            |
| Use guest PTY broker                                  | Tabs, resize, reconnect and process control | Guest service and authenticated protocol      |
| Reuse nixos-avf image construction                    | Existing kernel/disk expertise              | Replace Terminal-specific service assumptions |

## Sources

- [Framework][framework], [permission checks][permissions], [released image API][image].
- [Nixos-avf guest][nixos] and [finisher][finish]; [Podroid engine][engine].
- [Actual device results][devices]; [source ledger][sources].

<!-- References -->

[framework]: https://android.googlesource.com/platform/packages/modules/Virtualization/+/175a51b30123fa6b02b541f1969665708f7ec2c3/libs/framework-virtualization/README.md
[service]: https://android.googlesource.com/platform/packages/modules/Virtualization/+/175a51b30123fa6b02b541f1969665708f7ec2c3/libs/framework-virtualization/src/android/system/virtualmachine/VirtualizationService.java
[permissions]: https://android.googlesource.com/platform/packages/modules/Virtualization/+/175a51b30123fa6b02b541f1969665708f7ec2c3/android/virtmgr/src/aidl.rs
[image]: https://android.googlesource.com/platform/packages/modules/Virtualization/+/46351de83cd509bc9a9fee8fc99b07fcc0cdd0bd/libs/framework-virtualization/src/android/system/virtualmachine/VirtualMachineCustomImageConfig.java
[native-demo]: https://android.googlesource.com/platform/packages/modules/Virtualization/+/175a51b30123fa6b02b541f1969665708f7ec2c3/android/vm_demo_native/README.md
[pvmfw]: https://android.googlesource.com/platform/packages/modules/Virtualization/+/175a51b30123fa6b02b541f1969665708f7ec2c3/guest/pvmfw/README.md
[nixos]: https://github.com/nix-community/nixos-avf/blob/d0a62c3f64b45a39570fde31a3a490b214bf19ee/avf/default.nix
[finish]: https://github.com/nix-community/nixos-avf/blob/d0a62c3f64b45a39570fde31a3a490b214bf19ee/avf/finish.nix
[engine]: https://github.com/ExTV/Podroid/blob/ce0121896b2895637ab1f656cbb0d75fa2874489/app/src/main/java/com/excp/podroid/engine/avf/AvfEngine.kt
[reflect]: https://github.com/ExTV/Podroid/blob/ce0121896b2895637ab1f656cbb0d75fa2874489/app/src/main/java/com/excp/podroid/engine/avf/AvfReflect.kt
[application]: https://github.com/ExTV/Podroid/blob/ce0121896b2895637ab1f656cbb0d75fa2874489/app/src/main/java/com/excp/podroid/PodroidApplication.kt
[hidden]: https://developer.android.com/guide/app-compatibility/restrictions-non-sdk-interfaces
[geniezone]: https://android.googlesource.com/platform/external/crosvm/+/853aaa9bdb28774fd82e7cfa4c910c95b0acaa5d/hypervisor/src/geniezone/mod.rs
[gz-uapi]: https://android.googlesource.com/kernel/common/+/5727772a3852ca071768d686c334d96bfdc2cc72/include/uapi/linux/gzvm.h
[devices]: ./device-validation/index.md
[baseline]: ./sparkles-baseline.md
[sources]: ./sources.md
[pixel7]: ./device-validation/pixel7.md
