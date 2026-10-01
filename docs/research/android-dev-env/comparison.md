# Comparison and architectural synthesis

**Last reviewed:** September 30, 2026.

## At a glance

| Dimension                | [nix-on-droid][proot]                                                              | [AVF][avf]                                                                             | [Gunyah custom VMM][gunyah]                         | [NNS/native][native]                                                                      |
| ------------------------ | ---------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------- | --------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| Stock app reach          | Broad sideload route, subject to executable policy                                 | Device/API/permission dependent                                                        | Documented custom routes rooted; stock AVF separate | NNS app path needs provisioned kernel/policy                                              |
| Full NixOS               | No                                                                                 | Yes, if custom guest boots                                                             | Possible; adaptation unverified locally             | No, shared Android kernel/userspace integration                                           |
| Standard Linux cache     | Canonical translated store                                                         | Canonical guest store                                                                  | Canonical guest store                               | Canonical mounted store                                                                   |
| Guest kernel ownership   | No                                                                                 | Yes                                                                                    | Yes                                                 | No                                                                                        |
| No-DEX fit               | Native login + PTY already implemented                                             | JNI hypothesis or explicit helper                                                      | Native helper plausible; authority required         | Native launcher + PTY                                                                     |
| Long-lived owner         | App supervisor needed                                                              | Framework/owner lifecycle needed                                                       | Root helper/VMM lifecycle needed                    | Provisioning daemon + app session                                                         |
| Cost center              | Syscall tracing, compatibility patches                                             | Guest RAM/boot, API integration                                                        | Vendor forks, firmware/verification and I/O         | Kernel/SELinux upgrades, DNS/TTY bridge                                                   |
| Physical-device evidence | Separate nix-on-droid PRoot observed; custom bootstrap not independently completed | Pad protected Microdroid boot, shell-owned; Pixel contributor reports both guest modes | Pad exposes Gunyah; no custom NixOS boot            | Stock Xiaomi app namespace attempts rejected; contributor Pixel has live same-UID NNS Zsh |

## Per-dimension comparison

### Deployment and permissions

PRoot has the fewest kernel prerequisites, but target-SDK executable policy is a serious product constraint. AVF's feature bit does not imply an app permission grant or usable nonprotected guest. The Pad demonstrates a stock **protected-only** route; it changes the Qualcomm feasibility assessment without proving unprotected NixOS. NNS makes its required custom stack explicit. Rooted Gunyah work should remain an advanced-device track until exact configurations are verified.

[The contributor Pixel 7 Pro][pixel7] separates two useful tracks: AVF declares both protected/non-protected support, while NNS has an already running app-UID canonical-store session under deliberately provisioned policy. The former is a capability declaration, the latter a captured userspace process. Neither establishes Sparkles ownership, a complete Nix workload, or an unmodified stock deployment. The kernel's `CONFIG_GUNYAH=y` does not change its reported active pKVM backend.

### Nix compatibility and services

All four can preserve the logical `/nix/store` under the appropriate execution view. Only an independently booted Linux VM can provide the complete NixOS system model. Shared-kernel paths support a large Linux userspace but inherit Android limitations. Disabling Nix build sandboxing enables some workloads at a loss of isolation; it is not evidence of equivalent sandbox support.

### Terminal and no-DEX integration

Local PRoot/native entry naturally fit the existing PTY. VMs require guest PTY sessions and a host owner/control channel. Installed framework classes may be called via JNI while the APK has no DEX; hidden APIs and lifecycle callbacks remain concrete engineering gates. A managed helper can be explicitly owned and deployed separately if that product choice is accepted, but no dependency on Android Terminal's owner is permitted.

### Files, networking and DNS

Every backend needs a deliberate host-file contract. Shared-kernel paths do not escape Android file permissions; guest sharing needs an exporter and supported virtual transport. PRoot's static resolver, NNS's Bionic bridge and VM networking differ under VPN/private DNS. Port exposure and session/control authentication must be tested as actual behavior, not inferred from localhost labels.

### Performance and isolation

PRoot pays for intercepted syscalls; namespaces eliminate that translation; hardware VMs add memory and virtual I/O overhead but supply kernel independence. Source inspection cannot rank real workload throughput. The original phone was warm and low on available RAM; the Pad test used only a 256 MiB Microdroid guest. These observations do not support numerical build-speed or battery claims.

### Lifecycle and maintenance

App process survival, terminal session survival and persistent files are different promises. VM disks can persist while guests are stopped; reconnectable PTYs need a guest service. Shared-store daemons can outlive UIs only when deliberately supervised. Bootstrap recovery, image migrations, kernel policy changes and owner death are required acceptance cases.

## Consensus standard

The inspected implementations converge on a canonical Linux filesystem view, a backend-specific entry/owner, and a terminal transport layered above it. They also require explicit adaptations for Android lifecycle and networking. A capability report must include authority and guest mode, not simply CPU architecture or the presence of a node.

## Architectural trade-offs

1. **Broad reach versus guest completeness:** ship PRoot first; add full NixOS where proven custom guests are available.
2. **Native speed versus managed device stack:** NNS removes tracing by accepting kernel/policy ownership.
3. **Protected boot versus flexible images:** protected-only hardware demands verified guest preparation and may constrain I/O; unsigned images are simpler where nonprotected capability exists.
4. **No-DEX UI versus owner integration:** native rendering is already solved; portable API access and durable owner lifecycle remain separate work.

## Sparkles delta table

| Modern capability               | [Current baseline][baseline]                                           | Required delta                                                                       |
| ------------------------------- | ---------------------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| Custom local terminal           | NativeActivity + native PTY works                                      | Preserve UI/backend separation                                                       |
| Custom PRoot package identity   | Configurable module + installer/login source                           | Demonstrate full bootstrap/cache/build cycle in custom app                           |
| Honest capability discovery     | Research inventory/probes                                              | Product report with deployment/permission/mode gates                                 |
| Independent AVF lifecycle       | Not implemented                                                        | JNI or explicit helper create/start/stop/delete/reconnect spike                      |
| Full NixOS guest                | Guest prior art inspected                                              | App-owned disks/config and guest PTY broker                                          |
| Qualcomm protected/custom route | Stock Microdroid boot proven on Pad                                    | Prove accepted custom Linux boot inputs before promising NixOS                       |
| Native namespace entry          | Rejected on stock Xiaomi; contributor Pixel has an NNS app-UID session | Sparkles-owned launcher contract, deployment provenance and workload/isolation tests |
| Durable sessions                | Activity/session machinery                                             | Defined owner death, UI recreation, reboot and unlock behavior                       |
| Quantified workload comparison  | None                                                                   | Same-device, same-output workload protocol after two backends work                   |

## Sources

- [PRoot][proot], [AVF][avf], [Gunyah][gunyah], [NNS][native] implementation evidence.
- [Baseline][baseline], [device validation][devices], [source ledger][sources].

<!-- References -->

[proot]: ./nix-on-droid.md
[avf]: ./avf.md
[gunyah]: ./gunyah.md
[native]: ./native-store.md
[baseline]: ./sparkles-baseline.md
[devices]: ./device-validation/index.md
[sources]: ./sources.md
[pixel7]: ./device-validation/pixel7.md
