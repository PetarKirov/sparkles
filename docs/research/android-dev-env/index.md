# Nix development environments on Android

A custom terminal can own a Nix session without depending on the Termux application or Android Terminal. The difficult boundary is the execution backend: Android app permissions, Linux namespaces, the hypervisor and guest ABI determine which environment that terminal can actually launch.

This survey answers six questions:

1. What separates a [terminal, a distro and a VM owner][concepts]?
2. How much of [nix-on-droid's PRoot backend][proot] can the existing app reuse?
3. Can an app independently launch [NixOS through AVF][avf], including on MediaTek?
4. What changes for [Qualcomm Gunyah, pvmfw and Microdroid][gunyah]?
5. When can a [native canonical Nix store][native] replace PRoot?
6. Which option fits [Sparkles today][baseline], and what should be [implemented next][recommendations]?

**Last reviewed:** September 30, 2026.

> [!IMPORTANT]
> This is an evidence catalog, not a claim that every listed backend runs on every named SoC. [Device validation][devices] distinguishes locally observed behavior, upstream demonstrations, source inspection and proposed experiments. The application keeps its existing no-DEX constraint; calling installed framework classes through JNI remains in scope.

The latest [Pixel 7 Pro contributor report][pixel7] adds a live NNS canonical-store session under the terminal app UID and AVF declarations for both protected/non-protected VMs. The report uses a provisioned kernel/policy stack and root ADB; custom guest boot, Nix workloads and Sparkles ownership remain untested. The locally connected Pad/phone results and contributor observations are labeled separately.

## Master catalog

| Subject                 | Category                                   | Environment                               | Deployment requirement                                                    | Link                         |
| ----------------------- | ------------------------------------------ | ----------------------------------------- | ------------------------------------------------------------------------- | ---------------------------- |
| nix-on-droid            | Shared Android kernel; translated syscalls | Linux Nix packages, module system         | Ordinary sideloaded app; executable-files policy must permit bootstrap    | [Deep dive][proot]           |
| AVF on Pixel / MediaTek | Hardware VM managed by Android             | Full NixOS guest                          | Compatible framework/backend plus management and custom-guest permissions | [Deep dive][avf]             |
| Gunyah on Qualcomm      | Vendor hypervisor / privileged VM launcher | Full Linux guest; NixOS adaptation needed | Documented routes need root; firmware, driver and VMM compatibility       | [Deep dive][gunyah]          |
| NNS and native stores   | Shared Android kernel; real namespaces     | Canonical Linux store, portable services  | Root provisioning; NNS app route needs kernel and SELinux integration     | [Deep dive][native]          |
| Other execution routes  | Emulated VM / remote host / Bionic port    | Varies                                    | Different portability, latency and packaging compromises                  | [Alternatives][alternatives] |

## Taxonomy

### By execution boundary

| Boundary                        | Subjects                     | Consequence                                                            |
| ------------------------------- | ---------------------------- | ---------------------------------------------------------------------- |
| Syscall translation             | [PRoot][proot]               | App UID and Android kernel remain authoritative                        |
| Independent guest kernel        | [AVF][avf], [Gunyah][gunyah] | NixOS can own systemd, namespaces and guest filesystems                |
| Kernel namespace isolation      | [NNS][native]                | Fast Linux execution; Android kernel features still constrain packages |
| CPU emulation or remote machine | [Alternatives][alternatives] | Avoids local EL2 requirements at a resource or connectivity cost       |

### By deployment privilege

| Tier                | Plausible paths                                                        | Gate                                                                                  |
| ------------------- | ---------------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| Stock sideload only | [PRoot][proot]                                                         | App executable-files restrictions and bootstrap compatibility                         |
| ADB / Shizuku setup | [AVF][avf] where permission grants and APIs exist                      | Shell authority cannot manufacture a missing hypervisor or override all SELinux rules |
| Rooted device       | [Gunyah][gunyah], root-managed [native store][native], AVF experiments | Actual driver, firmware and policy support                                            |
| Custom kernel / ROM | [NNS app namespaces][native], platform AVF owner                       | Deliberate kernel and policy maintenance                                              |

## Milestones

| Date / release                                              | Capability                                                                           | Evidence and limitation                                                                              |
| ----------------------------------------------------------- | ------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------- |
| Android 10 (2019)                                           | Apps targeting API 29 cannot execute files in writable app home                      | [Android execution policy][exec-policy]; crucial for downloaded Linux packages                       |
| Android 14 / API 34 (2023)                                  | AVF framework Java APIs introduced                                                   | [Framework README][framework]; system APIs, not a public SDK promise                                 |
| Android 15 (2024)                                           | Management permission available to preinstalled apps; development ADB grant retained | [Framework README][framework]; custom-image permission is an additional gate                         |
| Android 16 source release (2025)                            | Custom Linux image machinery used by Android Terminal                                | [Released source][image-api]; API availability must be checked per firmware                          |
| June 2025 demonstration; repository reviewed September 2026 | Snapdragon 8 Elite Gunyah Linux boot                                                 | [Vendor-device guide][gunyah-guide]; one rooted Lenovo configuration                                 |
| September 2026 source snapshots                             | Custom Sparkles app and NNS namespace integration                                    | [Baseline][baseline], [source ledger][sources]; source evidence is separate from hardware validation |
| September 30, 2026 contributor report                       | Pixel 7 Pro live NNS session and both AVF guest-mode declarations                    | [Physical-device report][pixel7]; provisioned stack, no guest or workload launched by collector      |

## Suggested reading paths

- **Choosing a backend:** [Concepts][concepts] → [comparison][comparison] → [recommendations][recommendations].
- **Designing Sparkles:** [Baseline][baseline] → [PRoot][proot] → [AVF][avf] → [capability gates][recommendations].
- **Investigating rooted Qualcomm:** [Gunyah][gunyah] → [native stores][native] → [device protocol][devices].
- **Checking reproducibility:** [Source ledger][sources] → [device results and runnable probes][devices].

## Sources

- [Android execution policy][exec-policy] and [AVF framework source][framework].
- [Source revisions and provenance][sources]; individual deep dives cite implementation files.

<!-- References -->

[concepts]: ./concepts/index.md
[proot]: ./nix-on-droid.md
[avf]: ./avf.md
[gunyah]: ./gunyah.md
[native]: ./native-store.md
[baseline]: ./sparkles-baseline.md
[recommendations]: ./recommendations.md
[devices]: ./device-validation/index.md
[alternatives]: ./alternatives.md
[comparison]: ./comparison.md
[sources]: ./sources.md
[pixel7]: ./device-validation/pixel7.md
[exec-policy]: https://developer.android.com/about/versions/10/behavior-changes-10#execute-permission
[framework]: https://android.googlesource.com/platform/packages/modules/Virtualization/+/175a51b30123fa6b02b541f1969665708f7ec2c3/libs/framework-virtualization/README.md
[image-api]: https://android.googlesource.com/platform/packages/modules/Virtualization/+/46351de83cd509bc9a9fee8fc99b07fcc0cdd0bd/libs/framework-virtualization/src/android/system/virtualmachine/VirtualMachineCustomImageConfig.java
[gunyah-guide]: https://github.com/polygraphene/gunyah-on-sd-guide/blob/61ac570c2d467274d1d7d73605dcc685af6945b8/README.md
