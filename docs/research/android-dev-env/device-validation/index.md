# Device validation and runnable probes

**Last reviewed:** October 17, 2026.

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

Only one relevant VM mode was boot-tested. E6 now completes the custom app's
PRoot Nix workflow on the phone, but there is no second backend with the same
working workload. A same-device backend comparison would therefore still give
misleading coverage. E7 is only a process-start microbenchmark. Follow
[the proposed workload protocol][recommendations] after two backends meet
functional gates.

The [Pixel report][pixel7] is an existing-process observation, not a workload benchmark. Its active NNS shell supplies new functional evidence, but signed substitution/build, DNS/TTY behavior, app-store-write rejection, independent terminal ownership and AVF custom-image boot remain acceptance gates. The report's seven nonzero process statuses reflect missing canonical paths outside NNS views, not seven failed NNS sessions.

## Current-target experiments

E1–E9 ran on the Xiaomi 11T Pro (Android 14) on October 16, 2026, with the
owner's approval for each step. They compare the existing target-28 terminal
(`untrusted_app_27`) with a disposable target-36 build (`untrusted_app`) running
the same probe bytes. The [Play Termux source analysis][play] supplied the
predictions. Android 14 says nothing about Android 17's rules, AVF or 16 KB
pages, and none of this bears on Play-policy acceptance; those limits apply to
every result below.

### Results

| Experiment | Observed                                                                                                                                                                                                                                                                                           | Evidence                                                         |
| ---------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------- |
| E1         | A Bionic probe copied into app data executes directly at target 28 (`exit=0`); at target 36 `execve` fails with errno 13 (`EACCES`). Contexts are `untrusted_app_27` (UID 10468) and `untrusted_app` (UID 10488), not `runas_app`.                                                                 | [Target 28][e1-28], [target 36][e1-36], [audit window][e1-audit] |
| E2         | An absolute-path `linker64` launch succeeds in both apps. `/proc/self/exe` names `/apex/com.android.runtime/bin/linker64`; `argv[0]` is the probe and `argv[1]` is `marker`. A relative path fails with `expected absolute path`.                                                                  | [Target 28][e2-28], [target 36][e2-36]                           |
| E3         | Target 36 `dlopen`s a library from app data; the audit log shows `granted { execute }` for that file.                                                                                                                                                                                              | [Session][e3-36], [audit][e3-audit]                              |
| E4         | A static ELF runs from app data at target 28, where the audit log shows `granted { execute_no_trans }`. At target 36 direct execution fails with `EACCES`, `linker64` rejects it (`unexpected e_type: 2`), and the identical file runs from the APK's native-library directory.                    | [Target 28][e4-28], [target 36][e4-36], [audit window][e4-audit] |
| E5         | A glibc Nix-store `hello` runs under APK-native `proot-static` with `PROOT_LOADER` set to the APK-native loader. With `PROOT_LOADER` unset, PRoot's `execve` fails with permission denied.                                                                                                         | [Session][e5-36], [audit][e5-audit]                              |
| E6         | A patched nix-on-droid bootstrap completes in the target-36 app, and signed substitution, GCC, Git, a local build and a restart all work; [details below](#e6-full-current-target-nix-prototype).                                                                                                  | [Workload][e6-workload], [restart][e6-relogin]                   |
| E7         | 15,000 process starts across three routes; [timings below](#e7-process-start-microbenchmark).                                                                                                                                                                                                      | [Direct][e7-direct], [linker][e7-linker], [PRoot][e7-proot]      |
| E8         | All 40 children of a [bounded fork probe][child-example] survived a seven-second background sample with phantom-process monitoring set `false` and then `true`. No signal-9 kill occurred.                                                                                                         | [Monitoring off][e8-off], [on][e8-on]                            |
| E9         | In Play Termux (`googleplay.2026.10.09`, target 37), the preload hook makes `/proc/self/exe` name the probe; without `LD_PRELOAD` it names `linker64`. Both static cases fail with `unexpected e_type: 2`. Under GDB 16.3-3 a breakpoint on `main` resolves but never stops, as reported upstream. | [Session][e9-play], [GDB][e9-gdb]                                |

Notes on reading the results:

- **E1** shows the rejection and the domain, not the denied permission: its log
  window has no `execute_no_trans` denial line. The `search` and `getopt`
  denials in it are unrelated.
- **The two apps differ in more than the target.** The target-28 app is version
  `reo101-25`; the target-36 app was built from this branch, and E4 updated it
  to the build carrying the static payload. The probe bytes and session
  commands were identical. [Provenance][exec-provenance] records the APK and
  payload hashes; `run-as` was used only to copy files in.
- **E8** set `settings_enable_monitor_phantom_procs` through ADB, which is the
  platform setting behind Developer options, not Xiaomi's UI toggle. It and
  `activity_manager/max_phantom_processes` were unset beforehand; the first was
  deleted afterwards and the second never changed. A short idle test does not
  show the process limit is absent or say anything about long-term survival.
- **E9's** Play Termux was installed by the owner, from their own account. The
  first GDB attempts in the combined transcript failed for setup reasons
  (GDB missing, then the system `timeout`); the breakpoint result comes from the
  final run.

### E6: full current-target Nix prototype

The `bootstrapApk` fixture embeds a 35.9 MiB bootstrap in the target-36 app.
The app's installer extracted 4,050 files, started `login` through
`/system/bin/sh` (the `bootstrap-shell` session mode), unpacked the pinned
channels and completed the first nix-on-droid generation. The
[first][e6-screen1] and [last][e6-screen2] setup screens are screen-text
captures, not complete PTY transcripts.

The bootstrap comes from nix-on-droid with
`native-proot.patch` (next to this page) applied, so it is a research fork,
not an upstream deployment. The patch makes both the bootstrap's login and every
later activation's login start PRoot and its loader from the APK, and stops
activation from copying a PRoot update into app data. The app finds its
native-library directory at runtime with `dladdr` and exports it as
`SPARKLES_NATIVE_LIBRARY_DIR`, so no install path is hard-coded.

| Check               | Observed                                                                                                                        |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| App identity        | UID 10488, `untrusted_app`; no root or policy changes                                                                           |
| Nix and store       | Nix 2.18.4, with executables under the logical `/nix/store`                                                                     |
| Signed substitution | `hello` from `cache.nixos.org` with `require-sigs = true` and local builds disabled; `nix-store --verify-path` succeeded        |
| Compiler and Git    | GCC 13.2.0 and Git 2.44.1 substituted, then run                                                                                 |
| Local derivation    | The [C workload][local-build-example] built, ran and passed a `--check` rebuild                                                 |
| Git workflow        | A repository was initialised and a commit made and read back                                                                    |
| Restart             | After force-stop and relaunch, login still used the APK-native paths, and Nix, the built program and the commit were all usable |

The workload ends `workload-exit=0` and the restart `relogin-exit=0`. A first
collector run assumed `grep` in the minimal profile and stopped early
([kept separately][e6-setup]). The [derivation check][e6-derivation] confirms
the published `local-build.nix` instantiates to the derivation that was built.
The [audit log][e6-audit] shows only granted executable mappings; it is not a
syscall trace, so that every exec went through the APK rests on the PRoot and
login sources plus E1's rejection of direct execution.

The channel source was served to the phone from a temporary loopback HTTP server
over `adb reverse`, with nixpkgs pinned to
`49ee0e94463abada1de470c9c07bfc12b36dcf40`. The device's stored channel URL
still names that server, so `nix-channel --update` there fails until it is
repointed at a published source.

### E7: process-start microbenchmark

The [harness][start-example] ran five trials of 1,000 fork/exec/wait cycles of
a [silent Bionic payload][true-example] per route. The PRoot route ran the
harness inside one PRoot session, not a new PRoot per child. All 15,000 starts
succeeded.

| Route                                          | Median (ms/start) | Range of trial means (ms/start) | Evidence                |
| ---------------------------------------------- | ----------------- | ------------------------------- | ----------------------- |
| Direct app-data execution, target 28           | 12.20             | 10.65–12.50                     | [Raw trials][e7-direct] |
| System linker, target 36                       | 10.42             | 8.85–10.89                      | [Raw trials][e7-linker] |
| Inside PRoot with APK-native loader, target 36 | 30.68             | 28.78–31.21                     | [Raw trials][e7-proot]  |

The median and range are over the five trial means. Routes ran in table order,
in two different apps, with no randomisation or CPU-frequency control, so the
first two routes are comparable and the gap between them is not meaningful.
PRoot roughly triples process-start cost. This does not measure a Nix workload
or close milestone M7.

### Reproducing

The [exec probe][exec-example] prints UID, SELinux context, `/proc/self/exe`
and its arguments; `--exec` reports the `execve` errno and `--dlopen` loads
[the library payload][load-example]. Cross-compile in `nix develop .#android`,
with `OUT` any scratch directory:

```bash
OUT=$(mktemp -d)
ldc2 -betterC -mtriple=aarch64--linux-android -gcc="$ANDROID_CC" docs/research/android-dev-env/device-validation/examples/exec-probe.d -of="$OUT/exec-probe"
ldc2 -betterC -mtriple=aarch64--linux-android -gcc="$ANDROID_CC" --d-version=ExecProbeStatic -L-static docs/research/android-dev-env/device-validation/examples/exec-probe.d -of="$OUT/static-probe"
ldc2 -betterC -mtriple=aarch64--linux-android -gcc="$ANDROID_CC" --d-version=LoadProbeLibrary -shared -relocation-model=pic docs/research/android-dev-env/device-validation/examples/load-probe.d -of="$OUT/libload-probe.so"
```

`readelf -l` should show `PT_INTERP=/system/bin/linker64` for `exec-probe` and
no `PT_INTERP` for `static-probe`. `mkTerminalApk` takes `targetSdk` (default 28) and `extraNativeLibs`, an ABI-keyed map of extra `lib*.so` files that may
not replace bundled ones. The E1–E4 app is:

```bash
nix build --impure --no-link --print-out-paths --expr "let f = builtins.getFlake (toString ./.); in f.legacyPackages.x86_64-linux.mkTerminalApk { appId = \"dev.petar_kirov.sparkles.terminal.t36\"; pname = \"terminal-t36\"; label = \"terminal target 36 probe\"; targetSdk = 36; extraNativeLibs.\"arm64-v8a\".\"libstatic-probe.so\" = $OUT/static-probe; }"
```

[`current-target.nix`](./current-target.nix) builds the E5 fixtures (`apk`,
`glibcClosure`, `helloPath`) and the E6 ones (`bootstrapApk`, `sourceTarball`):

```bash
nix build --builders '' --impure --no-link --print-out-paths --file docs/research/android-dev-env/device-validation/current-target.nix apk glibcClosure helloPath bootstrapApk sourceTarball
```

Copy payloads in with `run-as`, which only copies and never executes, because
`run-as` runs in the exempt `runas_app` domain:

```bash
adb -s "$SERIAL" shell "run-as $PKG sh -c 'mkdir -p files/android-exec-research && cat > files/android-exec-research/exec-probe && chmod 700 files/android-exec-research/exec-probe'" < "$OUT/exec-probe"
```

Run everything else in the app's own terminal, with `R` set to
`/data/user/0/<package>/files/android-exec-research`. A `runas_app` context in
the output invalidates the run.

| Experiment | Command in the app session                                                                                                                                                                                                   |
| ---------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| E1         | `/system/bin/linker64 "$R/exec-probe" --exec "$R/exec-probe"`                                                                                                                                                                |
| E2         | `/system/bin/linker64 "$R/exec-probe" marker`, then `cd "$R"` and `/system/bin/linker64 ./exec-probe marker`                                                                                                                 |
| E3         | `/system/bin/linker64 "$R/exec-probe" --dlopen "$R/libload-probe.so"`                                                                                                                                                        |
| E4         | `/system/bin/linker64 "$R/exec-probe" --exec "$R/static-probe"`, `/system/bin/linker64 "$R/static-probe"`, then `libstatic-probe.so` from the native-library directory reported by the package manager (the same static ELF) |

Collect `avc:` lines with `adb logcat -d -T '<start time>'`; a missing line
proves nothing. E8 changes a Developer option, and E9 installs a third-party
app, so each needs the owner's separate consent. No step needs root, flashing,
policy changes or an app-data reset.

### Device state afterwards

The target-36 app, its Nix store and the research directories are still on the
phone, as are the 28 packages (701 MB) that the GDB install added to Play
Termux. The E8 setting was restored, every E8 child was reaped, and the
loopback server and `adb reverse` mapping were removed. No existing app was
uninstalled or reset.

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
[e7-direct]: ../grounding/device/phone-exec-e7-direct.txt
[e7-linker]: ../grounding/device/phone-exec-e7-linker.txt
[e7-proot]: ../grounding/device/phone-exec-e7-proot.txt
[e6-screen1]: ../grounding/device/phone-exec-e6-bootstrap-screen-01.txt
[e6-screen2]: ../grounding/device/phone-exec-e6-bootstrap-screen-02.txt
[e6-workload]: ../grounding/device/phone-exec-e6-workload.txt
[e6-relogin]: ../grounding/device/phone-exec-e6-relogin.txt
[e6-setup]: ../grounding/device/phone-exec-e6-workload-setup.txt
[e6-derivation]: ../grounding/device/phone-exec-e6-canonical-derivation.txt
[e6-audit]: ../grounding/device/phone-exec-e6-audit.txt
[local-build-example]: ./local-build.nix
