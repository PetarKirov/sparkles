# Pixel 7 Pro (Android / NNS / AVF)

A contributor's root-ADB report captures a live canonical-store NNS session and AVF capability declarations on a provisioned Pixel 7 Pro.

**Last reviewed:** September 30, 2026.

| Field               | Observed value / scope                                                                     |
| ------------------- | ------------------------------------------------------------------------------------------ |
| Device              | Pixel 7 Pro, `cheetah`, `GS201`, `arm64-v8a`                                               |
| Android             | 16 / API 36, `BP4A.251205.006/14401865`, `user/release-keys`                               |
| Kernel / page size  | Reported `6.1.134`, 4096 bytes                                                             |
| Collector authority | UID 0, `u:r:ksu:s0`, SELinux enforcing, seccomp disabled                                   |
| Evidence category   | Contributor-collected physical-device report, inspected locally; no local device execution |
| NNS deployment      | Module `3.1.0`, `versionCode=4`; installed source/kernel/policy revisions not supplied     |
| Terminal frontend   | `com.termux.nix`; Sparkles was not the observed frontend                                   |
| AVF backend         | `kvm.arm-protected`, protected and non-protected support reported                          |
| Experiment boundary | Read-only inventory and existing-process inspection; no new guest or Nix workload launched |

## Overview

### What it establishes

[The capability report][avf-info] says: “Both protected and non-protected VMs are supported.” More substantially, [the captured Zsh process][session] executes a binary under canonical `/nix/store`, retains the terminal application's UID and runs in distinct user and mount namespaces. This advances NNS evidence from source inspection to an observed provisioned-device session.

### Evidence discipline

The report records processes already running while the collector inspected them. It does not reproduce their launch, measure syscall latency, run a derivation, or demonstrate Sparkles ownership. The Android boot properties report a locked bootloader and green verified boot; root `ksu`, the NNS policy domain and the kernel seccomp-bypass facility are also observed. These properties must not be presented as proof of an untouched stock kernel or policy. [Identity][identity], [security][security], [namespace policy][namespace-policy]

## Provenance and published excerpts

The contributor supplied `pixel7-report.tar.xz`. Its contents are **uncompressed GNU tar**, despite the suffix. The report was collected in September 2026. Its exact collection timestamp and private archive digest are omitted from publication. Its manifest has 28 probe records. All referenced output files are present and every `output_limit_reached` flag is false. Seven process probes have exit status 1; none of those statuses alone establishes an NNS failure.

The handoff supplied collector revision `1fa8d36707330435fd6e7ca8e34deec1229fe542`. [Collector source][collector] matches the logged command set, but the report does not embed a binary/source revision. Treat the revision as handoff provenance rather than an independently recovered executable identity. The inspected NNS source remains `28d2229a664cbe29e55a051d648a789b6511f735`; module version and launcher hashes do not identify the deployed source commit by themselves.

The published grounding directory contains nine complete normalized logs, three logs with non-epoch file timestamps explicitly replaced, and seven explicitly marked excerpts. Normalization removes carriage returns, NUL terminators and trailing whitespace. Process excerpts preserve command/exit headers, identity/security/namespace fields, selected mount targets and final store/socket metadata; non-epoch file timestamps are explicitly replaced where present. Generic `1970-01-01` timestamps are retained. Mount targets retained are `/`, `/nix`, `/nix/store`, `/etc`, `/tmp` and `/dev/pts`; unrelated Android/APEX/application and recursively exposed scratch mounts are omitted. The process inventory omits unrelated matched applications/services, and the resource excerpt omits available memory, disk usage and battery state. App UIDs, PIDs and namespace identifiers are local technical identifiers retained to establish equality and separation; build fingerprints and executable hashes identify software, not a unique device. Public upstream handles remain as source attribution. The original archive, complete private process/mount inventory and manifest are not committed.

## How the observed session works

The inspected [NNS launcher][launcher] creates a private filesystem view and uses `pivot_root`. The device report is consistent with this mechanism: [Zsh's root][session] is an app-owned 16-MiB tmpfs, and `/nix` exposes the `/nix` subtree of the data F2FS filesystem. On the Android side that subtree resides at `/data/nix`. Store paths are real mounts, rather than PRoot pathname translations.

The following table compares three processes captured in the same report. Namespace identifiers are opaque inode IDs meaningful only within this collection.

| Property             | Terminal application, PID `10820` | Launcher parent, PID `15606` | NNS Zsh, PID `15612`                                            |
| -------------------- | --------------------------------- | ---------------------------- | --------------------------------------------------------------- |
| Executable           | `/system/bin/app_process64`       | `/data/nix/bin/nix-enter`    | `/nix/store/yrn0bmddzgif6rlwyvnbgjar9z9py3ql-zsh-5.9.2/bin/zsh` |
| UID/GID              | `10578` / `10578`                 | `10578` / `10578`            | `10578` / `10578`                                               |
| SELinux domain       | `untrusted_app_27`                | `nns_app`                    | `nns_app`                                                       |
| `Seccomp` / filters  | `2` / `1`                         | `0` / `0`                    | `0` / `0`                                                       |
| `CapEff` / `CapPrm`  | Zero / zero                       | Zero / zero                  | Zero / zero                                                     |
| `NoNewPrivs`         | `0`                               | `0`                          | `1`                                                             |
| Mount namespace      | `4026536764`                      | `4026536764`                 | `4026536795`                                                    |
| User namespace       | `4026531837`                      | `4026531837`                 | `4026536794`                                                    |
| UID/GID mapping      | Initial namespace                 | Initial namespace            | `10578 10578 1`                                                 |
| Canonical store view | Absent                            | Absent                       | Present                                                         |

Sources: [application][application], [launcher parent][parent], [session][session]. The Zsh bounding capability set is nonzero, while its effective and permitted sets are zero. Do not conflate a bounding set with active privileges or a new user namespace with host-root identity. [Capability semantics][capabilities], [user namespace mappings][user-namespaces]

## Analysis

### Deployment and permissions

[Kernel configuration][kernel-config] reports `CONFIG_USER_NS=y`, `CONFIG_NAMESPACES=y`, `CONFIG_SECCOMP=y` and `CONFIG_SECCOMP_FILTER=y`. [The bypass allowlist][namespace-policy] contains exactly `/data/nix/bin/nix-enter`. The installed launcher has SELinux type `nns_exec`; its public and module copies have the same SHA-256:

```text
e8ad23aed71e1f2d8cccc87289e858b2da39b47a761840b13016036f07e65b02
```

The observed app-to-launcher transition and seccomp change agree with [NNS's inspected exec-time kernel patch][seccomp-patch] and policy design. The report does not supply the deployed patch set or independently trace the transition. [Installed layout][layout]

[AVF info][avf-info] reports `/dev/kvm`, `kvm.arm-protected`, both guest modes, no VFIO-platform support, no assignable devices and an OS list containing `microdroid`. [Permission definitions][permissions] report `MANAGE_VIRTUAL_MACHINE` as `signature|development|preinstalled` and `USE_CUSTOM_VIRTUAL_MACHINE` as `signature|development`. No package permission-grant dump was collected. Definitions are not grants, and root-ADB authority is not ordinary-app authority.

[Kernel configuration][kernel-config] also contains `CONFIG_GUNYAH=y`, but [device-node inspection][features] finds neither `/dev/gunyah` nor `/dev/gzvm`. Backend selection must follow the actual AVF report, not a compiled kernel option. `CONFIG_PID_NS` is disabled; a mount/user namespace session does not imply all Linux isolation features are available. Host virtio options do not establish a future guest kernel's configuration.

### Nix compatibility and services

[The root Nix process][daemon] runs the store artifact named `nix-2.34.8` in a separate mount view, UID 0 and `ksu`, with effective capabilities. [Runit processes][processes] and [their supervisor's view][services] establish existing portable service supervision. A Nix process name/path is not a captured `nix --version`, daemon round-trip, evaluation, signed substitution or build result.

[The installed configuration][nns-config] contains an empty `build-users-group` and `sandbox = false`. The daemon socket is mode `0666`; the store directory is root-owned `0755`. A writable filesystem mount is not sufficient to infer app write access, because ownership, capabilities and SELinux also govern it. Conversely, the directory metadata alone is not a complete test of every store object's write permissions. The app-store-unwritable acceptance gate remains untested.

### Terminal and no-DEX integration

The live frontend is `com.termux.nix`, whose app process remains `untrusted_app_27` and seccomp-filtered while its launched NNS session has a different execution view. This is useful evidence for [a native launcher/PTY backend][native], but no Sparkles APK, no-DEX integration, resize/signal behavior or independently owned app lifecycle was tested. The report does not show the launch command or parent PID chain; the common UID, cgroup and namespace relationships support the session interpretation without reconstructing a complete launch trace.

### Files, networking and DNS

[The installed DNS library and resolver][nns-config] are present with `system_data_file` labels. Their existence does not establish preload activation, successful name resolution, VPN/private-DNS handling or terminal ioctl compatibility. The NNS session shares the reported host network namespace; it is not a separate virtual network. File-sharing and app-store-write tests remain required.

### Performance and isolation

The published [resource excerpt][resources] retains approximately 11.3 GiB total RAM. Transient available-memory, filesystem-usage and battery measurements are omitted for privacy. Total RAM alone is not a benchmark, guest-disk capacity measurement or memory-sizing recommendation.

No timing experiment was run. Namespace separation is observed, but NNS still shares the Android kernel and the captured configuration disables Nix build sandboxing. AVF's available non-protected mode suggests a simpler unsigned custom-image experiment than the Pad's protected-only mode; actual Linux/NixOS boot remains untested.

### Lifecycle and maintenance

[The AVF listing][vm-list] is empty at collection time. It neither proves nor disproves earlier guest execution. Launcher parents retain their original mount/user namespace view while the session has a different one. That supports the namespace-lifetime design at one instant, not cleanup, reconnect, reboot or upgrade reliability.

All seven exit-1 process logs end with missing canonical-store/socket paths for processes outside the NNS filesystem view: two root launcher parents, the terminal application and its non-root launcher parent, plus three unrelated matched processes. The successful session/daemon/service logs contain those paths. Publish these absences as expected view differences, not seven broken installations. Earlier command failures can still be masked by a compound command's final exit; the complete command must be read.

## Strengths and limits of this evidence

- A real Nix-store executable, app UID retention, policy transition and namespace separation appear together in one physical-device report.
- Protected/non-protected AVF declarations and actual backend/node evidence are recorded separately from guest boot.
- Source deployment identity, app permission grants, active Nix/DNS/TTY workloads and Sparkles ownership are still missing.
- The provisioned kernel/policy route must not be generalized to the tested stock Xiaomi devices or all Pixel builds.

## Next acceptance gates

| Gate                       | Current evidence                                     | Required follow-up                                                                                       |
| -------------------------- | ---------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| Deployed source identity   | Module version and matching launcher hashes          | NNS commit/local changes, kernel build/patch set and installed policy provenance                         |
| App execution route        | Existing app and NNS session captured                | Actual launch command, before/after app-domain syscall probe, new session owned by Sparkles              |
| Usable Nix workflow        | Live Zsh and root Nix process                        | `nix --version`, pure evaluation, signed cache download and small derivation inside the session          |
| NNS boundary               | Same UID, zero effective capabilities, mounted store | Explicit store-write rejection, DNS/TTY, lifecycle and restart checks                                    |
| Custom AVF Linux           | Both modes reported, CLI includes `run`              | Bounded disposable custom kernel/root-disk boot with caller authority recorded                           |
| Independent NixOS terminal | Not demonstrated                                     | Guest Nix/systemd workload and app/helper create/start/stop/reconnect without Android Terminal ownership |

## Sources

- Complete normalized logs: [identity][identity], [security][security], [AVF capabilities][avf-info], [guest listing][vm-list], [CLI][cli], [boot artifact metadata/hashes][artifacts], [permission definitions][permissions], [kernel config][kernel-config], [namespace policy][namespace-policy].
- Logs with non-epoch file timestamps omitted: [AVF features/nodes][features], [NNS layout][layout], [NNS config][nns-config].
- Explicit excerpts: [resources][resources], [application][application], [launcher parent][parent], [session][session], [Nix process][daemon], [runit supervisor][services], [process inventory][processes].
- [Collector revision][collector], [NNS launcher][launcher], [exec-time seccomp patch][seccomp-patch], [namespace/capability semantics][user-namespaces].
- [Contributor protocol][contributing], [device inventory][devices], [native-store analysis][native].

<!-- References -->

[identity]: ../grounding/device/pixel7/identity.txt
[security]: ../grounding/device/pixel7/security.txt
[resources]: ../grounding/device/pixel7/resources.txt
[features]: ../grounding/device/pixel7/avf-features.txt
[avf-info]: ../grounding/device/pixel7/avf-info.txt
[vm-list]: ../grounding/device/pixel7/avf-list.txt
[cli]: ../grounding/device/pixel7/avf-cli.txt
[artifacts]: ../grounding/device/pixel7/avf-artifacts.txt
[permissions]: ../grounding/device/pixel7/avf-permissions.txt
[kernel-config]: ../grounding/device/pixel7/kernel-config.txt
[namespace-policy]: ../grounding/device/pixel7/namespace-policy.txt
[layout]: ../grounding/device/pixel7/nns-layout.txt
[nns-config]: ../grounding/device/pixel7/nns-config.txt
[application]: ../grounding/device/pixel7/pid-10820.txt
[parent]: ../grounding/device/pixel7/pid-15606.txt
[session]: ../grounding/device/pixel7/pid-15612.txt
[daemon]: ../grounding/device/pixel7/pid-1946.txt
[services]: ../grounding/device/pixel7/pid-2007.txt
[processes]: ../grounding/device/pixel7/processes.txt
[collector]: https://github.com/PetarKirov/sparkles/blob/1fa8d36707330435fd6e7ca8e34deec1229fe542/docs/research/android-dev-env/device-validation/examples/contributor-probe.d
[launcher]: https://github.com/reo101/NNS/blob/28d2229a664cbe29e55a051d648a789b6511f735/module/src/nix-enter.zig
[seccomp-patch]: https://github.com/reo101/NNS/blob/28d2229a664cbe29e55a051d648a789b6511f735/kernel/patches/nns-seccomp-bypass.patch
[capabilities]: https://man7.org/linux/man-pages/man7/capabilities.7.html
[user-namespaces]: https://man7.org/linux/man-pages/man7/user_namespaces.7.html
[contributing]: ./contributing.md
[devices]: ./index.md
[native]: ../native-store.md
