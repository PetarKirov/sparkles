# Device validation and runnable probes

**Last reviewed:** October 16, 2026.

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

## Current-target experiments

E1–E5, a bounded E8 and the Play reference E9 ran on the Xiaomi 11T Pro on October 16, 2026, after explicit owner
approval; the owner then authorized the remaining experiments. The
[Play Termux source analysis][play] supplies predictions, not the results below.
Android 14 cannot establish Android 17 behavior, AVF support or 16 KB-page
compatibility. M0b's full Nix workflow remains a separate gate.

### Observed execution routes

| Experiment | Observed locally                                                                                                                                                                                                                                    | Evidence                                                         |
| ---------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------- |
| E1         | The same copied Bionic probe executes directly at target 28 (`exit=0`); target 36 reports `execve` errno 13 (`EACCES`, `exit=1`). Contexts are `untrusted_app_27` (UID 10468) and `untrusted_app` (UID 10488), not `runas_app`.                     | [Target 28][e1-28], [target 36][e1-36], [audit window][e1-audit] |
| E2         | Absolute-path linker launch succeeds in both apps; `/proc/self/exe` names `/apex/com.android.runtime/bin/linker64`, while `argv[0]` is the probe path and `argv[1]` is `marker`. Both relative paths fail with `expected absolute path` and exit 1. | [Target 28][e2-28], [target 36][e2-36]                           |
| E3         | Target 36 successfully `dlopen`s the app-data library. The audit log contains granted `{ execute }` for that exact `.so` and the same app domain.                                                                                                   | [Session][e3-36], [audit][e3-audit]                              |
| E4         | The static ELF runs from app data at target 28. At target 36, direct app-data execution reports `EACCES`, linker launch rejects ELF type 2, and the identical file executes from the APK's extracted native-library directory.                      | [Target 28][e4-28], [target 36][e4-36], [audit window][e4-audit] |
| E8         | In the disposable target-36 app, all 40 children survived the seven-second sample with phantom monitoring set both `false` and `true`; the probe then terminated/reaped its own children. No signal-9 kill was reproduced.                          | [Monitoring disabled][e8-off], [enabled][e8-on]                  |

E5 ran the glibc Nix-store `hello` successfully with APK-native `proot-static`
and `PROOT_LOADER`; the same invocation with `PROOT_LOADER` unset failed with
permission denied. [The session][e5-36] and [mapping audits][e5-audit] are local
evidence for the reduced-scale current-target PRoot design, not a Nix bootstrap,
signed substitution, compiler build or distribution-policy acceptance.

E9 used owner-installed Play Termux `googleplay.2026.10.09`, target 37, UID
10503, verified with `installerPackageName=com.android.vending`. [Its output][e9-play]
shows the Bionic probe running with the preload hook, which reports its own
path through `/proc/self/exe`; without `LD_PRELOAD` it reports `linker64`.
Both static cases fail with `unexpected e_type: 2`. After a separately approved
installation of GDB 16.3-3, [the batch breakpoint test][e9-gdb] resolves `main`
initially, then runs to normal exit without stopping and ends with the
breakpoint pending. This reproduces one reported failure, not all debugger
behavior. The initial missing-GDB and system-`timeout` launch failures in the
combined transcript are setup failures, not breakpoint evidence; the final
test uses Termux's own `timeout` wrapper.

E1's log window contains a granted executable mapping, but no matching
`execute_no_trans` denial. It therefore observes rejection and domain identity,
not the exact denied SELinux permission. Unrelated `search` and `getopt` denials
in the transcript are not evidence of that permission. No SELinux policy was changed.

The existing target-28 app reports version `reo101-25`; the initial target-36
APK was the handoff's previously built variant, and E4 updated only that newly
installed disposable package to the native-payload build. These are not identical
frontend revisions, so this is not a single-variable rebuild comparison. The
probe bytes and session command were identical. [Provenance and commands][exec-provenance]
record the APK/payload hashes and copy-only `run-as` use.

E8 used [a bounded fork probe][child-example], not a sustained build. Each child
self-exits after ten seconds if the parent dies; the parent samples after seven
seconds. The app was moved to Home during each run. ADB read back
`settings_enable_monitor_phantom_procs=false` then `true`; this exercises the
platform setting, not a verified Xiaomi Developer-options UI toggle. Both it
and `activity_manager/max_phantom_processes` were originally unset (`null`).
The former was deleted afterward and read back `null`, restoring its prior
state; the latter was never changed. These short idle tests do not prove the
default process limit absent or characterize OEM scheduling/long-term survival.

Agree each experiment's exact procedure with the device owner before starting.
Prefer owner-run commands and pasted session output plus relevant `avc:` logcat
lines. Do not install, launch, copy to or query the phone automatically. No root,
flashing, SELinux changes or app-data reset is part of this protocol. E8 changes
a Developer option only with separate consent; E9 is optional and owner-installed.

### Host preparation

The [exec probe][exec-example] reports UID, SELinux context, `/proc/self/exe`
and arguments. Its `--exec` mode reports the actual `execve` errno on failure;
`--dlopen` loads [the small shared-library payload][load-example]. Build on the
workstation in `nix develop .#android`; these commands do not contact a device:

```bash
mkdir -p /tmp/opencode/android-dev-env
ldc2 -betterC -mtriple=aarch64--linux-android -gcc="$ANDROID_CC" docs/research/android-dev-env/device-validation/examples/exec-probe.d -of=/tmp/opencode/android-dev-env/exec-probe
ldc2 -betterC -mtriple=aarch64--linux-android -gcc="$ANDROID_CC" --d-version=ExecProbeStatic -L-static docs/research/android-dev-env/device-validation/examples/exec-probe.d -of=/tmp/opencode/android-dev-env/static-probe
ldc2 -betterC -mtriple=aarch64--linux-android -gcc="$ANDROID_CC" --d-version=LoadProbeLibrary -shared -relocation-model=pic docs/research/android-dev-env/device-validation/examples/load-probe.d -of=/tmp/opencode/android-dev-env/libload-probe.so
```

Check with `file` and `readelf -l`: `exec-probe` must be Bionic-dynamic with
`PT_INTERP=/system/bin/linker64`; `static-probe` must have no `PT_INTERP`.
These three cross-compilations passed locally on October 16, 2026. This is host
build evidence, not evidence that Android will execute them.

`mkTerminalApk` now accepts `targetSdk` (default 28) and `extraNativeLibs`, an
ABI-keyed map of non-conflicting `lib*.so` files. Unsupported ABI keys, invalid
library names and replacement of bundled libraries are rejected. Build a separate
target-36 plain-shell app carrying E4's static payload:

```bash
nix build --impure --no-link --print-out-paths --expr 'let f = builtins.getFlake (toString ./.); in f.legacyPackages.x86_64-linux.mkTerminalApk { appId = "dev.petar_kirov.sparkles.terminal.t36"; pname = "terminal-t36"; label = "terminal target 36 probe"; targetSdk = 36; extraNativeLibs."arm64-v8a"."libstatic-probe.so" = /tmp/opencode/android-dev-env/static-probe; }'
```

Before an approved install, record the APK hash, manifest target and revision.
Verify `lib/arm64-v8a/libstatic-probe.so` is present and no DEX is present.
Do not replace the existing target-28 app or use `adb install -r` on an
unidentified existing target-36 installation. Agree any update separately.

### E1: direct app-data execution protocol

Installation scope: only the new
`dev.petar_kirov.sparkles.terminal.t36` APK, alongside the existing
`dev.petar_kirov.sparkles.terminal`. Installation was approved before execution.
For reproduction, stage the dynamic payload separately for each package. The operator
sets `PKG` to one of those two exact IDs and `SERIAL` to `bd123586`:

```bash
adb -s "$SERIAL" shell "run-as $PKG sh -c 'mkdir -p files/android-exec-research && cat > files/android-exec-research/exec-probe && chmod 700 files/android-exec-research/exec-probe'" < /tmp/opencode/android-dev-env/exec-probe
```

`run-as` is used only to copy/chmod files, never to execute a probe. In each
app's actual terminal UI, set `R` to its own absolute research directory
(`/data/user/0/PACKAGE/files/android-exec-research`, substituting the exact
package ID), then run:

```bash
/system/bin/linker64 "$R/exec-probe" --exec "$R/exec-probe"
printf 'exit=%s\n' "$?"
```

The launcher route is identical in both apps. Prediction, confirmed above: target 28
executes the child; target 36 reports errno 13 (`EACCES`). Record the printed
context and UID, wall-clock test window and matching denial if visible. A
missing logcat line does not prove the absence of a denial; a `runas_app`
context invalidates the experiment. Stop on unexpected context or loader failure.

### E2–E4: reproduction protocol

| Experiment | Procedure in the real app session                                                                                                                                                                                                                                                                                                                     | Prediction (observations above)                                                                                                                                |
| ---------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| E2         | Run `/system/bin/linker64 "$R/exec-probe" marker`; then `cd "$R"` and `/system/bin/linker64 ./exec-probe marker`. Capture complete output, arguments and exit statuses in both apps.                                                                                                                                                                  | Absolute succeeds and the executable link names the linker; relative path is rejected. Do not assume argument rewriting: record what this device prints.       |
| E3         | Stage `libload-probe.so` beside the probe using the same copy-only approach; in target 36 run `/system/bin/linker64 "$R/exec-probe" --dlopen "$R/libload-probe.so"`.                                                                                                                                                                                  | Successful `dlopen`; a granted `execute` audit may be visible. Missing audit output does not contradict successful loading.                                    |
| E4         | Stage `static-probe` with mode 700. Compare `/system/bin/linker64 "$R/exec-probe" --exec "$R/static-probe"`, `/system/bin/linker64 "$R/static-probe"`, and direct execution of the identical `libstatic-probe.so` in the app's installed native-library directory. Obtain that directory from the installed package metadata, not a guessed APK path. | At target 36: app-data direct execution fails, linker rejects static ELF, APK-native execution works. At target 28 the direct app-data control should succeed. |

Do not interpret the E4 basename `.so` as a shared object: it is the same static
ELF under Android's extraction naming convention. Compare hashes before testing.

### E5–E9: gates and remaining preparation

The optional `current-target.nix` fixture builds the same pinned PRoot's
executable **and** matching loader, an AArch64 glibc `hello` closure and a
disposable target-36 APK. It never invokes ADB:

```bash
nix build --builders '' --impure --no-link --print-out-paths --file docs/research/android-dev-env/device-validation/current-target.nix apk glibcClosure helloPath
```

E6's compiler workload and E7's benchmark were deferred when the phone's battery
sensor still reported 50°C while USB-charging (15% level). The [benchmark
harness][start-example] and [silent payload][true-example] are prepared, not
measurements. After cooldown, verify every route succeeds before collecting five
trials of 1,000 starts; the same Bionic payload can isolate route costs without
comparing different libc/program implementations. Default host invocation skips
the benchmark and the child-count experiment.

The owner installed the Play reference for E9; no Play account was accessed by
the agent. With separate approval, `pkg install -y gdb` added 28 packages (117 MB
download, 701 MB installed; zero upgrades/removals), including compiler/Python
dependencies. Before/after package lists and the install log are retained in
the [combined transcript][e9-play]. These packages remain installed.

| Experiment | Gate before agreeing the device procedure                                                                                                                                                                                                                                                                                                      | Evidence to capture                                                                                                                                                                      |
| ---------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| E5         | Select pinned, same-ABI `proot-static`, its matching loader and a small glibc closure; package both helpers through `extraNativeLibs`. Run with an absolute APK-native `PROOT_LOADER`, then a negative control with it unset. This reduced-scale gate passed; `current-target.nix` reproduces the fixtures.                                    | Helper/closure hashes, exact argv/environment, exit status and app context; distinguish a loader-location failure from other PRoot errors.                                               |
| E6         | E5 passes. Adapt the bootstrap's PRoot invocation to the APK-native executable and loader. `session.mode = "bootstrap-shell"` now starts `login` as `/system/bin/sh login` in initial, post-install and later sessions, but does **not** rewrite the script's internal commands or set `PROOT_LOADER`. Use an isolated bootstrap app/data set. | M0 workload: `nix --version`, canonical store, signed cache substitution, compiler/Git workflow and a small local derivation; record execution-route evidence and no-DEX APK inspection. |
| E7         | E5/E6 functional gates pass and owner agrees a bounded workload: five trials of approximately 1,000 successful `true` starts by direct target-28, linker target-36 and PRoot routes.                                                                                                                                                           | Raw elapsed times, success counts, median/range, thermal/battery state, identical payloads and warm/cold classification. The diagnostic probe prints output and is not a timing payload. |
| E8         | Owner separately approves a bounded 40-child test, the Developer-option toggle and restoration of its original value. Agree timeout, background/foreground state and child cleanup before running.                                                                                                                                             | Setting before/after, child count, elapsed time, exit signals and available process-kill logs. No kill does not prove the global limit is absent.                                        |
| E9         | Optional: owner chooses and installs Play Termux using their own account. Agree disposable files/package changes and debugger procedure.                                                                                                                                                                                                       | App/target version, linker/static controls and an actual `gdb` breakpoint hit or failure. App presence alone is not validation.                                                          |

**M0b is partially observed, not delivered.** E5 closes the reduced-scale
glibc-loader gate; the full bootstrap/cache/build workflow and downloaded-code
policy acceptance remain unvalidated.

### Recording and cleanup

After each approved experiment, save the operator's transcript under
`grounding/device/` with date, device/firmware, APK and payload hashes, target
SDK, commands, timestamps, app UID/context, exit statuses, relevant audit output,
privilege context and limitations. Label each claim observed, contradicted or
still source-inspected. The linked E1–E5/E8/E9 transcripts are actual device output.

Cleanup is owner-approved removal of only the named research directory in the
existing app and uninstall of the newly installed disposable app. Confirm that
the latter was created by this experiment before uninstalling it. Preserve all
existing terminal/nix-on-droid data and restore E8's original setting. Never
clear logcat or reset an existing app to simplify collection.

Current cleanup state: the test app and named research directories are retained
for deferred E6/E7, as are the explicitly approved Play GDB packages. All E8
children were reaped, its setting was restored, and E9's loopback transfer
server/ADB mappings were removed. No existing app was uninstalled or reset.

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
[play]: ../termux-play-store/index.md
[exec-example]: ./examples/exec-probe.d
[load-example]: ./examples/load-probe.d
[e1-28]: ../grounding/device/phone-exec-e1-target28.txt
[e1-36]: ../grounding/device/phone-exec-e1-target36.txt
[e1-audit]: ../grounding/device/phone-exec-e1-audit.txt
[e2-28]: ../grounding/device/phone-exec-e2-target28.txt
[e2-36]: ../grounding/device/phone-exec-e2-target36.txt
[e3-36]: ../grounding/device/phone-exec-e3-target36.txt
[e3-audit]: ../grounding/device/phone-exec-e3-audit.txt
[e4-28]: ../grounding/device/phone-exec-e4-target28.txt
[e4-36]: ../grounding/device/phone-exec-e4-target36.txt
[e4-audit]: ../grounding/device/phone-exec-e4-audit.txt
[exec-provenance]: ../grounding/device/phone-exec-provenance.txt
[e8-off]: ../grounding/device/phone-exec-e8-monitor-off.txt
[e8-on]: ../grounding/device/phone-exec-e8-monitor-on.txt
[child-example]: ./examples/child-probe.d
[start-example]: ./examples/start-bench.d
[true-example]: ./examples/true-probe.d
[e5-36]: ../grounding/device/phone-exec-e5-target36.txt
[e5-audit]: ../grounding/device/phone-exec-e5-audit.txt
[e9-play]: ../grounding/device/phone-exec-e9-play.txt
[e9-gdb]: ../grounding/device/phone-exec-e9-gdb.txt
