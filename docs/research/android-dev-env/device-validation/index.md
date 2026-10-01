# Device validation and runnable probes

**Last reviewed:** September 30, 2026.

## Evidence levels

| Level                 | Meaning                                                | Examples in this catalog                                            |
| --------------------- | ------------------------------------------------------ | ------------------------------------------------------------------- |
| Observed locally      | Command/probe ran on connected physical hardware       | Pad AVF info, protected Microdroid boot, real app-domain probes     |
| Contributor observed  | Physical-device collector output supplied and reviewed | Pixel 7 Pro AVF capabilities and live NNS app/session/daemon views  |
| Upstream demonstrated | Source author records execution on a stated setup      | Rooted Lenovo Gunyah guide; NNS Android harness                     |
| Source inspected      | Mechanism verified in pinned implementation            | AVF permission checks, NNS launcher, custom bootstrap               |
| Proposed / inferred   | Integration could follow but has not passed locally    | No-DEX AVF owner, custom NixOS on Pad, Pixel/MediaTek compatibility |

A feature bit, device node, guest boot, app permission and complete development workflow are different achievements. The tests below do not claim a working local NixOS backend or quantify performance.

Stored device transcripts normalize carriage returns, NUL separators and trailing whitespace for repository text checks. They retain command output, including interleaved console lines and error messages; they are not byte-identical terminal captures. Implementation source snapshots remain byte-identical.

## Physical inventory

| Property                           | Xiaomi 11T Pro                                 | Xiaomi Pad 8 Pro                                                      |
| ---------------------------------- | ---------------------------------------------- | --------------------------------------------------------------------- |
| Model / device                     | `2107113SG` / `vili`                           | `25091RP04G` / `piano`                                                |
| SoC evidence                       | `SM8350` (Snapdragon 888)                      | `getprop ro.soc.model`: `SM8750P`; user identifies Snapdragon 8 Elite |
| Android / API                      | 14 / 34                                        | 16 / 36                                                               |
| Firmware                           | `V816.0.20.0.UKDEUXM`                          | `OS3.0.303.0.WPYEUXM`                                                 |
| Kernel                             | `5.4.289-qgki-g7dd106e6c847`                   | `6.6.77-android15-8-g4a507830d890-ab13636293-4k`                      |
| Boot/security                      | Locked, green verified boot, SELinux enforcing | Locked, green verified boot, SELinux enforcing                        |
| AVF feature                        | Absent                                         | Present                                                               |
| Hypervisor nodes                   | `/dev/kvm`, `/dev/gunyah`, `/dev/gzvm` absent  | `/dev/gunyah` present; KVM/GZ nodes absent                            |
| AVF tool                           | Absent                                         | `/apex/com.android.virt/bin/vm` present                               |
| App namespace route                | Rejected                                       | Rejected                                                              |
| Independent shell-owned guest boot | Not available through observed stack           | Protected Microdroid payload ready                                    |

The Pixel 10 Pro is deferred at the user's request. A contributor supplied [Pixel 7 Pro evidence][pixel7] from a provisioned Android 16 device: both AVF guest modes are reported, and a live NNS Zsh session has canonical store paths, the app UID and separate user/mount namespaces. The Pixel was not connected to this research workstation; no Pixel guest was launched by the collector. No MediaTek hardware was tested. These are exact deployment observations, not enduring support guarantees for the model names.

A separate `getconf PAGESIZE` query on the Pad returned 4096 bytes. Future device inventories should record page size and apply [the native compatibility checks][page-size] before attributing a launch failure to the execution backend.

The original phone was disconnected when the Pad was connected. Its initial results were recorded from live tool output; the Pad has [raw inventory][inventory-log], [capability output][avf-log], [guest boot log][boot-log] and [app probe output][app-log]. The phone was subsequently reconnected: its captured [app probe output][phone-app-log] was retrieved and its disposable `files/android-research` probe directory and `/data/local/tmp/sparkles-android-app-probe` removed. No system policy or existing application data was changed.

## Reproduce the inventory

[The inventory program][inventory-example] requires an explicit serial and performs read-only queries. Without arguments it prints `SKIP:` for CI. With a device:

```bash
dub docs/research/android-dev-env/device-validation/examples/inventory.d --serial SERIAL --adb /path/to/adb
```

It captures identity, shell security state, feature/node presence, resource snapshot and relevant app/process names. A shell UID of 2000 with seccomp disabled is **not** the app's execution context.

## App-domain probe

[The libc-only probe][app-example] compiles with `-betterC` against the Android Bionic toolchain. Run it from the terminal UI's actual session. `run-as` can copy the binary and retrieve output, but must not be used to execute the evidence-producing probe: its SELinux domain differs from the application session.

Successful cross-compilation used LDC Android 1.42.0 and NDK 28.1.13356709's `aarch64-linux-android29-clang`:

```bash
ldc2 -betterC -mtriple=aarch64--linux-android \
  -gcc=/path/to/ndk/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android29-clang \
  docs/research/android-dev-env/device-validation/examples/app-probe.d \
  -of=/tmp/sparkles-android-app-probe
```

The custom terminal's existing no-DEX APK was installed on the Pad because it was not present. The binary was copied into an app-private research directory, executed through short typed shell commands and its output retrieved afterward. This proves the test inherited the zygote-born application's policy; it is not a standalone ADB shell executable result.

| Probe                    | Xiaomi 11T Pro app session | Pad 8 Pro app session     |
| ------------------------ | -------------------------- | ------------------------- |
| UID/GID                  | `10488` / `10488`          | `10413` / `10413`         |
| SELinux domain           | `untrusted_app_27`         | `untrusted_app_27`        |
| `Seccomp`                | `2`                        | `2`                       |
| `CapEff`                 | Zero                       | Zero                      |
| `unshare(CLONE_NEWUSER)` | `-1`, errno 22 (`EINVAL`)  | `-1`, errno 22 (`EINVAL`) |
| `unshare(CLONE_NEWNS)`   | `-1`, errno 1 (`EPERM`)    | `-1`, errno 1 (`EPERM`)   |
| Combined namespaces      | `-1`, errno 22             | `-1`, errno 22            |
| `socket(AF_VSOCK)`       | `-1`, errno 13 (`EACCES`)  | `-1`, errno 13 (`EACCES`) |

Neither device exposes the NNS seccomp-bypass sysctl or `max_user_namespaces` at the probed paths. These observations reject direct app namespace entry on the tested configurations, but do not uniquely identify the cause of every rejected syscall. AF_VSOCK rejection does not exclude a framework-brokered descriptor or service-mediated transport.

[The full D namespace example][namespace-example] separately demonstrates disposable-child namespace behavior on a capable Linux host. It is not substituted for the Android app result.

## Pad AVF and protected guest

`vm info` reported “Only protected VMs are supported.” The world-readable/writable Gunyah node carries SELinux type `vendor_gunyah_dev`; the mode bits alone do not grant an ordinary app access. Android Terminal is preinstalled with management/custom permissions, but it was not used as the VM owner.

[The installed permission definitions][permission-log] report `MANAGE_VIRTUAL_MACHINE` as `signature|development|preinstalled` and `USE_CUSTOM_VIRTUAL_MACHINE` as `signature|development`. This supports investigating explicit development grants on this firmware. The existing terminal APK does not request them; no grant or no-DEX framework ownership test was performed.

A bounded shell-owned test ran:

```bash
adb -s SERIAL shell 'mkdir -p /data/local/tmp/sparkles-research-microdroid; timeout 20 /apex/com.android.virt/bin/vm run-microdroid --protected --mem 256 --work-dir /data/local/tmp/sparkles-research-microdroid'
```

[The complete log][boot-log] records pvmfw, successful verification of a debuggable payload, Microdroid initialization, `Hello Microdroid`, and `payload is ready`. Early `initrd_normal` AVB error messages are followed by firmware's explicit instruction to disregard them after successful debug-payload verification. The run ended with timeout exit status 124; [subsequent VM listing][cleanup-log] was empty. This was a stock signed Microdroid payload, not a custom NixOS image, an app-owned VM or a successful arbitrary guest signing experiment.

An initial invocation without creating the work directory failed before guest creation. The recorded successful command includes that prerequisite. The VM tool also created an empty temporary directory under `/data/local/tmp/microdroid`; it was removed after the run, together with the explicit instance/idsig files and app probe files. The custom terminal installation remains available on the Pad; existing Termux/nix-on-droid and Android Terminal data were untouched.

## Workload and resource limits

The phone snapshot had roughly 7 GiB total RAM, about 1.4 GiB available, 15% battery and a battery temperature reading of 50°C. The Pad snapshot had `MemTotal=7544184 kB`, `MemAvailable=1736308 kB`, 31% battery, 32.9°C and 126 GiB available on the reported data filesystem. These are transient pre-test snapshots, not performance characteristics.

Only one relevant VM mode was boot-tested, and the custom app's full PRoot bootstrap was not completed as part of this research. A same-device backend benchmark would therefore give misleading coverage. Follow [the proposed workload protocol][recommendations] after two backends meet functional gates.

The [Pixel report][pixel7] is an existing-process observation, not a workload benchmark. Its active NNS shell supplies new functional evidence, but signed substitution/build, DNS/TTY behavior, app-store-write rejection, independent terminal ownership and AVF custom-image boot remain acceptance gates. The report's seven nonzero process statuses reflect missing canonical paths outside NNS views, not seven failed NNS sessions.

## CI scope

The [examples][examples] are registered in `apps/ci`'s standalone defaults. CI parses an actual ELF, exercises real disposable namespace calls where permitted, runs the libc probe on Linux, and checks that device collectors skip without an explicit serial. CI does not silently contact hardware or prove AVF/NNS support. Device results remain dated evidence that must be rerun when firmware changes.

For a packaged collector and an agent prompt covering rooted Pixel/NNS contributions,
see [Contributor device probes][contributing].

## Sources

- [Inventory][inventory-log], [AVF info][avf-log], [guest boot][boot-log], [app domain][app-log], [cleanup][cleanup-log].
- [Namespace concepts][concepts] and [recommendations][recommendations].
- [Contributor Pixel 7 Pro observations and provenance][pixel7].

<!-- References -->

[contributing]: ./contributing.md
[pixel7]: ./pixel7.md
[phone-app-log]: ../grounding/device/phone-app-probe.txt
[inventory-example]: ./examples/inventory.d
[app-example]: ./examples/app-probe.d
[namespace-example]: ../concepts/examples/namespace-probe.d
[examples]: ../sources.md#runnable-evidence
[inventory-log]: ../grounding/device/pad-inventory.txt
[avf-log]: ../grounding/device/pad-avf-info.txt
[boot-log]: ../grounding/device/pad-microdroid.txt
[app-log]: ../grounding/device/pad-app-probe.txt
[cleanup-log]: ../grounding/device/pad-cleanup.txt
[permission-log]: ../grounding/device/pad-permissions.txt
[concepts]: ../concepts/index.md
[recommendations]: ../recommendations.md
[page-size]: ../concepts/index.md#host-page-size
