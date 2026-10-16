# Termux on Google Play (Android / Bionic / `linker64`)

A Bionic-native Linux userspace runs under a current target SDK by never asking the kernel to execute a file from the app's writable data directory.

| Field          | Value                                                                                                              |
| -------------- | ------------------------------------------------------------------------------------------------------------------ |
| Language       | Java app; C `LD_PRELOAD` shim; shell/Make package recipes; Go and C patches                                        |
| License        | App GPL-3.0 (terminal libraries Apache-2.0); `termux-exec` Apache-2.0; packages under their own terms              |
| Repository     | [`termux-apps`][apps-readme], [`termux-exec`][exec-readme], [`termux-packages`][packages], [`termux-tools`][tools] |
| Documentation  | [Organization README][org-readme]; [`termux-exec` README][exec-readme]                                             |
| Category       | Shared kernel; exec redirection through the system dynamic linker                                                  |
| Prerequisites  | Bionic-linked packages; libc-mediated `exec`; APK-bundled loaders for anything else                                |
| Custom app fit | The `exec` contract transfers to any app; the package universe is Bionic, not `aarch64-linux` Nix                  |
| First / latest | First Play release June 7, 2024; inspected app `googleplay.2026.10.09` (`versionCode` 142)                         |

## Overview

### What it solves

Upstream Termux kept `targetSdkVersion` at Android 9 so that downloaded packages stayed executable, which locked it out of Google Play. The [organization README][org-readme] states the trade it reversed: “Android 10 disallowed executing downloaded files directly. The Termux app avoided that by using a `targetSdkVersion` of Android 9 … Termux was not able to be updated on Google Play starting in 2020”. The Play build is a separate code base that targets the current API level, drops `sharedUserId`, and requests fewer permissions.

### Design philosophy

The restriction is an SELinux rule about `execve(2)`, not about executable memory. [AOSP's `app_neverallows.te`][neverallow] forbids `execute_no_trans` on `app_data_file` for every untrusted app except the legacy target-SDK domains, calling it “a W^X violation (loading executable code from a writable home directory)”. [`untrusted_app_all.te`][untrusted-all] keeps two neighboring permissions for every app: mapping app data executable (`allow untrusted_app_all app_data_file:file { r_file_perms execute }`, the `dlopen` path) and executing the system linker (`allow untrusted_app_all system_linker_exec:file execute_no_trans`, added because “Chrome Crashpad uses the the dynamic linker to load native executables from an APK”). [`termux-exec`'s README][exec-readme] names the escape those two permissions combine into: “instead of executing an ELF file directly, executes `/system/bin/linker64 /path/to/elf` … the kernel sees only `/system/bin/linker64` being executed.” Everything else in the fork — the app launcher, the Go and PRoot patches, the `/proc/self/exe` emulation, the removed packages — exists to keep that one substitution invisible to programs, or to route around the cases it cannot cover.

## How it works

### The two executable locations

An app targeting API 29 or later may `execve` system files and the APK's extracted native libraries, which [`app.te`][app-te] grants as `apk_data_file:file { … x_file_perms }`; Android 10's behavior notes say apps “should load only the binary code that's embedded within an app's APK file” ([execute permission][exec-policy]). The Play app uses both locations deliberately:

- **The data directory holds packages; `linker64` runs them.** [`TermuxShellUtils`][shell-utils] starts every session by executing `/system/bin/linker64` with the real ELF as its first argument whenever the target lies under `/data/data/com.termux/files`, and sets `LD_PRELOAD=$PREFIX/lib/libtermux-exec.so` for every child.
- **The native-library directory holds what `linker64` cannot run.** The [app build][app-gradle] downloads PRoot's static loader into `src/main/jniLibs/<abi>/libproot-loader.so` and sets `jniLibs.useLegacyPackaging = true`, so the package manager extracts it to an executable location. [`TermuxInstaller.setupAppLibSymlink`][installer] links `$FILES/applib` to `nativeLibraryDir`, giving package recipes a stable path to it.

The bootstrap itself does not come from the network at first run. The build embeds the ~24 MB per-ABI `bootstrap-<arch>.zip` into `libtermux-bootstrap.so` with an `.incbin` ([assembly][bootstrap-asm]), and the installer extracts it into a staging prefix, applies `SYMLINKS.txt`, marks `bin/`, `libexec` and the APT helpers `0700`, then renames the prefix into place. The entry-name canonicalization carries the comment “Silence google play scanning flagging about this”, linking Google's zip-path-traversal advisory ([installer][installer]).

### The `exec` rewrite

[`execve` in `termux-exec`][exec-src] runs in every process that inherits `LD_PRELOAD`:

1. Rewrite `/bin/x` and `/usr/bin/x` (and shebang interpreters) to `$PREFIX/bin/x`, then normalize the path without resolving symlinks — `$PREFIX/bin/ls` must stay `ls`, not become `coreutils`.
2. Read the first 255 bytes. An ELF proceeds; a `#!` line yields the interpreter and at most one argument; anything else returns `ENOEXEC`.
3. If the real path lies under the data directory (or is `/system/bin/sh`), issue `execve("/system/bin/linker64", [argv0, target, (interp-arg, script,) args…])` and add `TERMUX_EXEC__PROC_SELF_EXE=<target>` to the environment. Otherwise strip `LD_PRELOAD`, `LD_LIBRARY_PATH` and that variable, and execute directly.
4. If the file cannot even be opened, clean the environment and pass the call through, which keeps KernelSU's virtual `/system/bin/su` working ([`termux-apps#10`][kernelsu]).

The dynamic linker accepts this because Bionic made it directly executable in a [2018 commit][bionic-exec] first shipped in Android 10. That commit also states the cost the rest of the fork pays: “The linker adjusts the argc/argv passed to main() … but doesn't adjust the auxv vector or files like /proc/self/{exe,cmdline,auxv,stat}. Those files will report that the kernel loaded the linker as an executable.” The linker then maps the target and its libraries with `mmap(PROT_EXEC)`, which the policy above still allows for app data files. [`exec-variants.c`][exec-variants] reimplements `execv`, `execvp`, `execvpe`, `execl*` and `fexecve` on top of the hooked `execve` because, as its header says, “For some reason these are only necessary starting with Android 14 - before that intercepting `execve()` is enough.” `system(3)` and `popen(3)` were fixed separately in `termux-exec` 1.4.

Run [the route model][route-example] to see the rewrite and its limits on synthetic headers (output identical on any host):

```bash
dub docs/research/android-dev-env/termux-play-store/examples/exec-route.d
```

It prints, for example, `execve: /system/bin/linker64 ls /data/data/com.termux/files/usr/bin/ls -l` for a package binary and `linker64 cannot link glibc: needs PRoot's APK loader …` for a Nix store executable.

### Repairing what the rewrite breaks

For every process started through the rewrite, the kernel records `linker64` as the executable. The fork repairs the visible consequences one mechanism at a time:

| Breakage                                                             | Repair                                                                                                                                                                           | Evidence                                                                  |
| -------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------- |
| `readlink("/proc/self/exe")` → `linker64`                            | `termux-exec` hooks `readlink(3)` and `realpath(3)` to answer from `TERMUX_EXEC__PROC_SELF_EXE`; `/proc/<pid>/exe` is answered by reading that process's `/proc/<pid>/environ`   | [`termux-readlink.c`][readlink], [`termux-realpath.c`][realpath]          |
| Programs that read `/proc/self/exe` with raw syscalls or bypass libc | Per-package patches: LLVM's `getMainExecutable`, `procps`, `pulseaudio`, `vtm`, `kitty`, `android-tools`, `zellij`, `lua-language-server`                                        | [LLVM patch][llvm-patch]; [org README][org-readme] changelog              |
| Go's `os/exec` issues raw `execve`                                   | The Go toolchain is patched: `os.StartProcess` reads the header itself and prepends `linker64` for ELFs and shebangs; `os.Executable` returns `argv` instead of `/proc/self/exe` | [`exec_posix.go` patch][go-exec], [`executable_procfs.go` patch][go-self] |
| Non-cgo Go binaries see `linker64`'s `argv`                          | `runtime.goargs` drops the extra leading argument when cgo is disabled, because Bionic's argument adjustment is only visible to code that goes through its libc                  | [`runtime1.go` patch][go-runtime]                                         |
| Go downloads an unpatched toolchain                                  | The build fails unless the pinned Go equals the latest release, because “a newer go version in go.mod lead[s] to a prebuilt toolchain (which lacks the Termux patches)”          | [`termux_setup_golang.sh` diff][go-setup]                                 |
| PRoot extracts and executes its loader                               | The loader is built as `libproot-loader-<arch>.so`, shipped in the APK, and the path is hard-coded to `$FILES/applib/libproot-loader.so`                                         | [`proot/build.sh`][proot-build], [`enter.c` patch][proot-enter]           |
| `memfd` executable mappings                                          | `libffi` is built with `ac_cv_func_memfd_create=no`                                                                                                                              | [commit `a4d1756c13`][libffi]                                             |
| `su` must not inherit the shim                                       | `termux-tools`' `su` wrapper unsets `LD_PRELOAD` and opts out of `termux-exec`                                                                                                   | [`su.in`][su]                                                             |

### What the fork removed instead

Some packages left the repository instead, for mixed reasons. Against the last merged upstream revision, 24 `packages/` and 7 `x11-packages/` directories are gone (a few only renamed, such as `pipes.sh` → `pipes-sh` and `openjdk-17` → `openjdk-21`/`-25`), among them `zig` (“Remove zig for now as it does not work with android-10 termux-exec”, commit `95e4f10b3e`), the whole `glibc-repo` (“Remove glibc support for simplicity”, commit `a356aadb31`), `valgrind` and `pypy`/`pypy3` (“for now”, no reason given), and `cabal-install`, `lfortran` and `qt5-qtwebengine`, which did not build. Only the first two are stated consequences of the exec model. Packages build at API level 30 instead of upstream's 24, for the three ABIs `aarch64`, `arm` and `x86_64` — `i686` was dropped. Packages are served from the separate `termux.net` repository with a dedicated signing key, so F-Droid and Play prefixes never share binaries ([bootstrap generator diff][bootstrap-gen], [`repo.json`][repo-json]). The maintainer's standard answer is that it “uses a package repository with modifications to be able to run under the updated targetSdk that Google Play requires, which so far has no mirrors” ([`termux-issues#46`][no-mirrors]); `termux-tools`' mirror selection was removed accordingly.

## Analysis

### Deployment and permissions

The inspected app declares `minSdkVersion=30` and `targetSdkVersion=37` ([`gradle.properties`][gradle-props]), one level above Play's floor: since August 31, 2026, “New apps and app updates must target Android 16 (API level 36) or higher” ([target API policy][play-target]). Under [`seapp_contexts`][seapp] that target places it in the plain `untrusted_app` domain, where nix-on-droid's target 28 places it in `untrusted_app_27`. It needed no root, no exemption and no kernel change: the workaround uses only operations the platform still grants to every app.

The technical gate and the policy gate are different. Play's [Device and Network Abuse policy][play-abuse] says an app “may not download executable code (such as dex, JAR, .so files) from a source other than Google Play”, exempting only code that “runs in a virtual machine or an interpreter”. Termux's own maintainers do not claim the `linker64` route satisfies it. The [termux.dev grant post][termux-dev-post] (November 2024) calls `system_linker_exec` a “hack” that “will likely get patched by Android as it is a security risk and cannot be relied on as a long term solution and is also not compliant with Google PlayStore policies”, and recommends the APK native-library route as “The solution that is approved by Android”; [agnostic-apollo's documentation][apollo-docs] repeats that it “is not compliant with Google PlayStore Policies”. Fredrik Fornwall, who maintains the Play build, framed it in the [upstream review][pr24-fornwall] as “a _temporary_ workaround … not a perfect solution, but I think it's the best one”. The app has nonetheless passed review continuously since June 2024. What Termux overcame is the target-SDK exec ban; no public source records an exemption from the download clause, so the app's presence shows only that review has not applied it so far.

Upstream's announcement of the release was explicit: the Play build “is functionally equivalent to `v0.108`”, lacks the `RUN_COMMAND` intent, and its exec route “violates PlayStore policies, so the PlayStore release may be taken down in future” ([`termux-app` discussion #4000][announce]).

The permission and component surface was reshaped for review, not only for the SDK bump. The organization README records that `sharedUserId` “is deprecated and did not pass the Google Play review” and that “the initial Google Play review did not approve the usage of multiple permissions.” Review then removed `Termux:Boot` from the store “due to not providing significant functionality”, and after “An initial appeal was overturned” it was folded into the app ([`termux-apps#47`][boot-pr]). The response was consolidation: `Termux:Boot` and `Termux:Widget` became components of the main APK in October 2024, and roughly twenty `Termux:API` commands — clipboard, notifications, SAF, camera info, microphone, speech — are now implemented in the app itself, so no second APK needs the old shared UID. `Termux:API`, `Termux:Tasker` and `Termux:Float` remain unavailable on Play. The [manifest][manifest] declares a `specialUse` foreground service with a written justification (a user serving pages to a browser while Termux is backgrounded); Play reviews that subtype and asks for “a link to a video demonstrating each foreground service feature” ([declaration requirements][play-fgs]). It also declares `MANAGE_EXTERNAL_STORAGE`, although terminals are not among the [policy's listed uses][play-files]. Review first rejected it — “Your app's usage of the permission must fall within permitted uses” — and accepted a resubmission that cited IDE apps already holding it ([`termux-apps#18`][storage-issue]); `termux-setup-storage` requests it since version 0.128. Supporting 16 KB pages, added in `2025.10.05`, is required of Play updates targeting API 35+ from February 1, 2027 ([page-size guide][page-sizes]).

### Nix compatibility and services

The workaround is Bionic-specific. `linker64` links against Bionic's `libc.so`; it cannot run an `aarch64-linux` glibc executable, whose `PT_INTERP` names a glibc `ld-linux-aarch64.so.1` that the kernel will not execute from app data either. The fork removed upstream's optional glibc repository rather than solve that. For [nix-on-droid][proot-page] the usable precedent is the PRoot path: PRoot rewrites every tracee `execve` into an `execve` of its loader, the loader maps the target and its interpreter with `mmap`, and the Play build makes that legal by shipping the loader as an APK native library. [PRoot's `get_loader_path`][proot-loader] already honors `PROOT_LOADER` even in its bundled build, so the existing nix-on-droid `proot-static` needs no loader patch — only a location the kernel will execute, for itself and for the loader.

### Terminal and no-DEX integration

The entire mechanism is native: an `LD_PRELOAD` library, an argument vector and a path convention. Nothing depends on Java except the launcher, whose decision is a dozen lines ([`setupShellCommandArguments`][shell-utils]). A NativeActivity app can make the same decision before `execve` in its PTY child. The Play app's own adaptations that do need managed code — notification permission prompts, SAF, `MANAGE_EXTERNAL_STORAGE`, foreground-service promotion — are lifecycle and permission matters, not execution ones.

### Files, networking and DNS

Shared storage is reached through `MANAGE_EXTERNAL_STORAGE` and symlinks under `~/storage`, the same layout as the F-Droid build; it is not executable in either. Networking is unchanged by the workaround. Targeting API 37 has a networking cost of its own: “Android 17 blocks local network access (ping, ssh, etc. to LAN devices) by default for apps targeting SDK 37+”, so the app requests `ACCESS_LOCAL_NETWORK` since July 2026 ([commit `f8809967`][local-net]).

### Performance and isolation

Exec through `linker64` adds the header read, a `realpath` and one `getenv` per `exec`; the loaded program then runs natively. There is no tracer, unlike PRoot. The workaround weakens nothing the kernel enforces: it is exactly what the policy permits, which is also why it offers no isolation beyond the app UID. The `LD_PRELOAD` contract is fragile rather than slow: a program that clears its environment, or a static helper that execs, silently loses the rewrite.

### Lifecycle and maintenance

The route rests on two `allow` rules Google keeps for compatibility, and the policy shows it watching them. `app_data_file` `execute` carries an `auditallow`, so every such mapping is logged, and the newer storage-area type is already denied `execute` with the comment “execute cannot be blocked on all of app_data_file without causing backwards compatibility issues (see b/237289679)” ([`app_neverallows.te`][neverallow]). Each target bump also moves the app into a domain with fewer compatibility grants: at Android 17, [`untrusted_app_34`][ua34] (targets 34–36) still allows ashmem `ioctl`s on `memfd` files, while the target-37 `untrusted_app` does not — a constraint on `libandroid-shmem`, whose own targetSdk fix the README dates January 13, 2026, before the bump to 37. A future target domain without `app_data_file` `execute` would break `linker64` and PRoot alike; only executables shipped inside the APK would survive. Android 17 moved one step in that direction for target 37: “All native files loaded using System.load() must be marked as read-only” ([Android 17 behavior changes][a17-dcl]). The rule as documented covers `System.load`, not the system linker's own mappings, and the app has shipped at target 37 since `googleplay.2026.06.21`; agnostic-apollo nonetheless expects “The system linker hack would likely break though unless apt is patched” to install files read-only ([`termux-app#2155`][a17-comment]).

Process lifetime is unchanged by the Play build. Android 12's phantom-process limit (32 by default) still kills a session's whole process group, surfacing as `[Process completed (signal 9)]` ([`termux-app#2366`][phantom]); Android 14 added “Disable child process restrictions” to Developer options, which resets when Developer options are switched off.

The cost is permanent divergence. `termux-packages` carries 1,285 changed files against its upstream merge base, and `termux-apps` is a rewrite rather than a patch series. Upstream merges are manual and periodic (the inspected `main` last merged upstream on June 21, 2026). Each Go release must be re-patched before the toolchain ships, and every newly packaged program that inspects its own executable is a potential regression. The [org README][org-readme] still calls the split “a temporary one as things stabilises”.

## Extent of the workaround

The [issue tracker][issues] (1,122 issues up to `#1653` on October 16, 2026, 361 open; 446 were closed on January 11, 2026 alone) records where the table below comes from. The maintainer's diagnosis recurs in it: “Termux on Google Play is not allowed to execute `…/usr/bin/tmux` directly, instead it executes `/apex/com.android.runtime/bin/linker64 …`” ([`termux-issues#149`][issue-149]), and the standing rule is that “you need to keep the `LD_PRELOAD` environment variable around while spawning sub processes” ([`termux-issues#24`][issue-24]). Relative interpreter paths once failed with `linker64`'s “error: expected absolute path” ([`#76`][issue-76], closed). Breakpoints that never trigger under `gdb` ([`#744`][issue-744]) and Go binaries from outside Termux's toolchain receiving their own path as `argv[1]` ([`termux-exec#9`][exec-9]) remain open.

| Workload                                     | Status on the Play build                                                                                                                                                          |
| -------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Packages from `termux.net`                   | Works: Bionic-dynamic ELFs and shebang scripts through `linker64`                                                                                                                 |
| User-compiled C/C++/Rust with Termux's clang | Works: the outputs are Bionic-dynamic and exec through libc                                                                                                                       |
| Go programs built with Termux's `golang`     | Works through the patched `os/exec` and runtime; Go toolchains fetched by `GOTOOLCHAIN` lack the patches                                                                          |
| Static executables (Zig/musl, static Go)     | Fails under `termux-exec`: `linker64` does not load them; an unmerged [September 2025 branch][static-loader] would hand `ET_EXEC` files to a `termux-elf-loader` not yet packaged |
| Raw-`execve` programs outside libc           | Fails unless patched or run under PRoot                                                                                                                                           |
| glibc executables (glibc repo, Nix store)    | Not provided; possible only under PRoot with the APK loader                                                                                                                       |
| PRoot distributions                          | Works since app 0.126 with the APK-shipped loader                                                                                                                                 |
| Programs that inspect `/proc/self/exe`       | Works when hooked or patched; unpatched raw readers see `linker64`                                                                                                                |
| Debugging with `gdb`                         | Open: breakpoints reported not to stop ([`#744`][issue-744])                                                                                                                      |
| Plugins and add-ons                          | Boot and Widget merged; about twenty API commands built in; `Termux:API`, Tasker, Float absent                                                                                    |

## Strengths

- Current target SDK, Play distribution and no root, using only operations every app retains.
- Exec indirection is native and small; the kernel-visible change is one path substitution.
- The APK-native-library route generalizes to anything known at build time: loaders, launchers and helpers can ship inside the APK.

## Weaknesses

- Correctness depends on `LD_PRELOAD` reaching every process and every program going through libc.
- Static, glibc and raw-syscall executables need per-package patches, PRoot or removal.
- A permanent fork of the package repository, toolchains and app, with a separate binary repository.
- Tolerated rather than sanctioned: the maintainers themselves call the route non-compliant with Play's executable-code policy and expect Android to close it.

## Key design decisions and trade-offs

| Decision                                 | Rationale                                                 | Trade-off                                                       |
| ---------------------------------------- | --------------------------------------------------------- | --------------------------------------------------------------- |
| `execve` the system linker, not the file | The kernel checks only the exec'd file's label            | `/proc/self/exe`, `argv` and static ELFs need emulation or fail |
| `LD_PRELOAD` interposition               | Covers every libc-mediated `exec` without rebuilding apps | Lost when environments are cleared; blind to raw syscalls       |
| Ship loaders as `lib*.so` in the APK     | Native-library files remain executable                    | Loader updates require an app release                           |
| Embed the bootstrap in a native library  | No first-run download; extraction is a local transaction  | ~24 MB per ABI in the APK                                       |
| Merge plugins into one APK               | No `sharedUserId`; fewer permissions per review           | Larger app; several plugins still missing                       |
| Separate `termux.net` repository         | Different API level, prefix assumptions and patches       | No binary sharing with F-Droid; duplicate maintenance           |

## Sources

- [Organization README][org-readme] (status, rationale, release history) and [issue tracker][issues].
- [`termux-exec` source][exec-src], [README][exec-readme], [`exec` variants][exec-variants], [`readlink`][readlink] and [`realpath`][realpath] hooks.
- [App launcher][shell-utils], [installer][installer], [build][app-gradle], [manifest][manifest].
- [Go patches][go-exec], [PRoot loader packaging][proot-build], [bootstrap generator][bootstrap-gen].
- [Bionic direct linker execution][bionic-exec]; [PRoot loader lookup][proot-loader].
- SELinux policy at `android17-release`: [`app_neverallows.te`][neverallow], [`untrusted_app_all.te`][untrusted-all], [`app.te`][app-te], [`seapp_contexts`][seapp].
- Play policy: [target API][play-target], [executable code][play-abuse], [all-files access][play-files], [foreground services][play-fgs]; [16 KB pages][page-sizes].
- Maintainer statements: [termux.dev][termux-dev-post], [upstream announcement][announce], [agnostic-apollo][apollo-docs], [`termux-exec-package#24`][pr24-apollo]; review events in [`termux-apps#47`][boot-pr] and [`#18`][storage-issue].
- [Source ledger][sources]; [exec-route model][route-example].

<!-- References -->

[org-readme]: https://github.com/termux-play-store/.github/blob/3094ae778e6ad87321229ab46c50893d04ffcb73/profile/README.md
[issues]: https://github.com/termux-play-store/termux-issues/issues
[apps-readme]: https://github.com/termux-play-store/termux-apps/blob/cf69df7a8d2a4c496f5b2464d0365a63a58716c5/README.md
[exec-readme]: https://github.com/termux-play-store/termux-exec/blob/47633d5df2db3dfea34cef568c6c82a7ba8dcc2e/README.md
[exec-src]: https://github.com/termux-play-store/termux-exec/blob/47633d5df2db3dfea34cef568c6c82a7ba8dcc2e/src/termux-exec.c#L253-L431
[exec-variants]: https://github.com/termux-play-store/termux-exec/blob/47633d5df2db3dfea34cef568c6c82a7ba8dcc2e/src/exec-variants.c
[readlink]: https://github.com/termux-play-store/termux-exec/blob/47633d5df2db3dfea34cef568c6c82a7ba8dcc2e/src/termux-readlink.c
[realpath]: https://github.com/termux-play-store/termux-exec/blob/47633d5df2db3dfea34cef568c6c82a7ba8dcc2e/src/termux-realpath.c
[static-loader]: https://github.com/termux-play-store/termux-exec/commit/00a7c00cfa139ad4a12ce5922c6e773116103224
[packages]: https://github.com/termux-play-store/termux-packages/tree/57401119f9988f79fa095398a9b33b03380222b3
[tools]: https://github.com/termux-play-store/termux-tools/tree/3f0880a0b4d085d251c230c6d5fe3d248c9c615d
[su]: https://github.com/termux-play-store/termux-tools/blob/3f0880a0b4d085d251c230c6d5fe3d248c9c615d/scripts/su.in
[shell-utils]: https://github.com/termux-play-store/termux-apps/blob/cf69df7a8d2a4c496f5b2464d0365a63a58716c5/termux-app/src/main/java/com/termux/app/TermuxShellUtils.java#L35-L140
[installer]: https://github.com/termux-play-store/termux-apps/blob/cf69df7a8d2a4c496f5b2464d0365a63a58716c5/termux-app/src/main/java/com/termux/app/TermuxInstaller.java
[app-gradle]: https://github.com/termux-play-store/termux-apps/blob/cf69df7a8d2a4c496f5b2464d0365a63a58716c5/termux-app/build.gradle.kts#L76-L189
[gradle-props]: https://github.com/termux-play-store/termux-apps/blob/cf69df7a8d2a4c496f5b2464d0365a63a58716c5/gradle.properties
[manifest]: https://github.com/termux-play-store/termux-apps/blob/cf69df7a8d2a4c496f5b2464d0365a63a58716c5/termux-app/src/main/AndroidManifest.xml
[bootstrap-asm]: https://github.com/termux-play-store/termux-apps/blob/cf69df7a8d2a4c496f5b2464d0365a63a58716c5/termux-app/src/main/cpp/termux-bootstrap-zip.S
[kernelsu]: https://github.com/termux-play-store/termux-apps/issues/10
[local-net]: https://github.com/termux-play-store/termux-apps/commit/f8809967aa246459ae40e0eacbcb9d54f75f84de
[go-exec]: https://github.com/termux-play-store/termux-packages/blob/57401119f9988f79fa095398a9b33b03380222b3/packages/golang/src-os-exec_posix.go.patch
[go-self]: https://github.com/termux-play-store/termux-packages/blob/57401119f9988f79fa095398a9b33b03380222b3/packages/golang/src-os-executable_procfs.go.patch
[go-runtime]: https://github.com/termux-play-store/termux-packages/blob/57401119f9988f79fa095398a9b33b03380222b3/packages/golang/src-runtime-runtime1.go.patch
[go-setup]: https://github.com/termux-play-store/termux-packages/blob/57401119f9988f79fa095398a9b33b03380222b3/scripts/build/setup/termux_setup_golang.sh
[llvm-patch]: https://github.com/termux-play-store/termux-packages/blob/57401119f9988f79fa095398a9b33b03380222b3/packages/libllvm/llvm-lib-Support-Unix-Path.inc.patch
[proot-build]: https://github.com/termux-play-store/termux-packages/blob/57401119f9988f79fa095398a9b33b03380222b3/packages/proot/build.sh
[proot-enter]: https://github.com/termux-play-store/termux-packages/blob/57401119f9988f79fa095398a9b33b03380222b3/packages/proot/src-execve-enter.c.patch
[libffi]: https://github.com/termux-play-store/termux-packages/commit/a4d1756c13ccfd5531cfbb5d7d70cde2d6ba45eb
[bootstrap-gen]: https://github.com/termux-play-store/termux-packages/blob/57401119f9988f79fa095398a9b33b03380222b3/scripts/generate-bootstraps.sh
[repo-json]: https://github.com/termux-play-store/termux-packages/blob/57401119f9988f79fa095398a9b33b03380222b3/repo.json
[bionic-exec]: https://android.googlesource.com/platform/bionic/+/8f639a40966c630c64166d2657da3ee641303194
[neverallow]: https://android.googlesource.com/platform/system/sepolicy/+/e066568e98d86db31a9346d30977f3632fa7073c/private/app_neverallows.te#64
[untrusted-all]: https://android.googlesource.com/platform/system/sepolicy/+/e066568e98d86db31a9346d30977f3632fa7073c/private/untrusted_app_all.te#24
[app-te]: https://android.googlesource.com/platform/system/sepolicy/+/e066568e98d86db31a9346d30977f3632fa7073c/private/app.te#471
[ua34]: https://android.googlesource.com/platform/system/sepolicy/+/e066568e98d86db31a9346d30977f3632fa7073c/private/untrusted_app_34.te#18
[seapp]: https://android.googlesource.com/platform/system/sepolicy/+/e066568e98d86db31a9346d30977f3632fa7073c/private/seapp_contexts
[exec-policy]: https://developer.android.com/about/versions/10/behavior-changes-10#execute-permission
[play-target]: https://support.google.com/googleplay/android-developer/answer/11926878
[play-abuse]: https://support.google.com/googleplay/android-developer/answer/9888379
[play-files]: https://support.google.com/googleplay/android-developer/answer/10467955
[play-fgs]: https://support.google.com/googleplay/android-developer/answer/13392821
[page-sizes]: https://developer.android.com/guide/practices/page-sizes
[termux-dev-post]: https://termux.dev/en/posts/general/2024/11/11/termux-selected-for-nlnet-ngi-mobifree-grant.html
[apollo-docs]: https://github.com/agnostic-apollo/Android-Docs/blob/8a14d48599d8f09fa38ff3ed7156957a3ac72fa3/site/pages/en/projects/docs/apps/processes/app-data-file-execute-restrictions.md#system-linker-exec
[pr24-fornwall]: https://github.com/termux/termux-exec-package/pull/24#issuecomment-1766527546
[pr24-apollo]: https://github.com/termux/termux-exec-package/pull/24#issuecomment-1743136933
[phantom]: https://github.com/termux/termux-app/issues/2366
[announce]: https://github.com/termux/termux-app/discussions/4000
[boot-pr]: https://github.com/termux-play-store/termux-apps/pull/47
[storage-issue]: https://github.com/termux-play-store/termux-apps/issues/18
[a17-dcl]: https://developer.android.com/about/versions/17/behavior-changes-17
[a17-comment]: https://github.com/termux/termux-app/issues/2155#issuecomment-4727619263
[no-mirrors]: https://github.com/termux-play-store/termux-issues/issues/46#issuecomment-2386367581
[issue-149]: https://github.com/termux-play-store/termux-issues/issues/149
[issue-24]: https://github.com/termux-play-store/termux-issues/issues/24
[issue-744]: https://github.com/termux-play-store/termux-issues/issues/744
[issue-76]: https://github.com/termux-play-store/termux-issues/issues/76
[exec-9]: https://github.com/termux-play-store/termux-exec/issues/9
[proot-loader]: https://github.com/termux/proot/blob/ab2e3464d04483b98a0614b470f3f8950d5a6468/src/execve/enter.c#L562-L588
[proot-page]: ../nix-on-droid.md
[sources]: ../sources.md
[route-example]: ./examples/exec-route.d
