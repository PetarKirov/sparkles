# nix-on-droid (Nix / Android / PRoot)

A Linux Nix userspace runs under an ordinary Android app UID through translated filesystem operations.

| Field          | Value                                                               |
| -------------- | ------------------------------------------------------------------- |
| Language       | Nix modules; native PRoot; Java original app                        |
| License        | Modules MIT; app and PRoot have their own licenses                  |
| Repository     | [Published module revision][upstream]; [original app][installer]    |
| Documentation  | [Module README][upstream]; [local revision ledger][sources]         |
| Category       | Shared kernel; syscall translation                                  |
| Prerequisites  | Executable app files, supported ABI, bootstrap and compatible PRoot |
| Custom app fit | Direct native PTY integration; no Termux app dependency             |

## Overview

### What it solves

Nix-on-droid brings standard Linux Nix outputs into a writable Android app installation without user namespaces or root. Its README states: “It does not require root, user namespaces support or disabling SELinux”. [Source][upstream]

### Design philosophy

The distro and terminal front end are separable. Upstream ships a Termux-derived app, but its Nix modules generate bootstrap files and a login command that another app can launch. The local fork makes package identity configurable through `androidAppId`; the [snapshotted configuration][config] is evidence for this adaptation, rather than a claim that unpublished local commits are available upstream.

## How it works

[The login wrapper][login] launches PRoot with a physical app-private store bound at logical `/nix`, supplies `/bin`, `/etc`, `/usr`, temporary directories and a view of Android at `/android`, and enables `--link2symlink` and `--sysvipc`. Fake `/proc` files can compensate for unavailable Android proc entries. HOME and temporary/link state belong to the app installation.

[PRoot's event loop][event] uses `ptrace` to intercept tracee syscalls, with seccomp-assisted filtering; [its ELF handling][elf] arranges execution of Linux binaries through its loader machinery. This changes pathname behavior rather than creating a kernel chroot. Children still have the Android UID, SELinux domain, seccomp restrictions and shared kernel.

[The bootstrap generator][bootstrap] and [Nix directory builder][nix-dir] stage a Nix closure, initialize the store database and package the login environment. [The Java installer][installer] unpacks into a staging prefix, applies `SYMLINKS.txt` and `EXECUTABLES.txt`, then renames the prefix into place. A replacement app must preserve those semantics and validate archives rather than simply extracting arbitrary paths.

## Analysis

### Deployment and permissions

Stock sideloading is the strongest deployment story among these approaches. It still depends on Android executable-file policy: [Android 10][exec-policy] forbids executing writable app-home files for apps targeting API 29 or later. The current Sparkles app targets 28 while requiring API 29 at runtime; this distinction is material. A future current-target distribution needs a demonstrated execution design, not just a manifest target bump.

### Nix compatibility and services

The logical canonical store permits Linux binary-cache reuse. The local module sets `sandbox = false`; [Nix configuration][nix-config] supplies trusted cache keys. Linux packages remain subject to Android's kernel and process policy. This is a nix-on-droid module system, not booted NixOS: systemd, mount-dependent services, containers and namespace-isolated builds must not be promised.

### Terminal and no-DEX integration

Spawn `usr/bin/login` through the app's existing native PTY and pass its own package identity and environment. The [Sparkles session snapshot][session] already implements this path. No managed Termux UI is required. Porting Termux Java code verbatim would introduce both managed-code architecture and licensing questions; reuse the bootstrap protocol and backend contract deliberately.

### Files, networking and DNS

Filesystem translation has overhead on metadata-heavy workloads. The [local networking module][network] generates a static `resolv.conf` using public resolvers; it does not implement NNS's Bionic DNS bridge. VPN and private-DNS behavior therefore need direct tests. `/android` exposes host paths only where Android's actual permissions allow access. Storage Access Framework grants do not automatically become ordinary Linux paths.

### Performance and isolation

PRoot tracing adds overhead, especially for filesystem/process-heavy builds; no defensible device-to-device percentage follows from source inspection. Pure computation may spend little time in the tracer. Debuggers and nested tracing require workload tests; do not broadly label all `ptrace` tools impossible. PRoot is a compatibility layer, not a security sandbox against the app's own UID.

### Lifecycle and maintenance

The app owns the PTY/process tree and must handle shutdown, child reaping and reconnect semantics. Bootstrap upgrades need a transaction and recovery path. PRoot's Android patches, native executable policy, hardcoded loader/temp paths and app UID ownership create a maintenance surface beyond ordinary nixpkgs updates. The original app's foreground services and wake-lock behavior do not transfer merely by copying the distro.

## Strengths

- Broad stock-device reach without modifying the kernel or SELinux.
- Existing custom app session/installer code closely matches the required backend.
- Canonical store and ordinary Linux package outputs.

## Weaknesses

- Syscall translation overhead and Android-kernel compatibility gaps.
- Executable-files policy complicates modern target-SDK distribution.
- Native activity lifecycle alone does not supervise long-running development services.

## Key design decisions and trade-offs

| Decision                      | Rationale                 | Trade-off                                            |
| ----------------------------- | ------------------------- | ---------------------------------------------------- |
| Translate paths under app UID | Avoid root and namespaces | Tracing overhead; host policy remains                |
| Canonical logical store       | Reuse Linux outputs       | Requires translation for every absolute store access |
| Disable build sandbox         | Namespace constraints     | Less build isolation                                 |
| Replace terminal front end    | Own UX and no-DEX APK     | Must implement installer/session/lifecycle contracts |

## Sources

- [Published module README][upstream]; [original installer][installer].
- [Local source snapshots][sources], [PRoot syscall handling][event] and [ELF execution][elf].

<!-- References -->

[upstream]: https://github.com/nix-community/nix-on-droid/blob/55b6449b4582a4ba3ce712543c973360a026db7d/README.md
[installer]: https://github.com/nix-community/nix-on-droid-app/blob/e87b6091bffa7b6eafb1b59cc7824f5692441cd0/app/src/main/java/com/termux/app/TermuxInstaller.java
[sources]: ./sources.md
[config]: ./grounding/nix-on-droid/build-config.nix.txt
[login]: ./grounding/nix-on-droid/login.nix.txt
[bootstrap]: ./grounding/nix-on-droid/bootstrap.nix.txt
[nix-dir]: ./grounding/nix-on-droid/nix-directory.nix.txt
[nix-config]: ./grounding/nix-on-droid/nix.nix.txt
[network]: ./grounding/nix-on-droid/networking.nix.txt
[session]: ./grounding/sparkles/session.d.txt
[event]: https://github.com/termux/proot/blob/ab2e3464d04483b98a0614b470f3f8950d5a6468/src/tracee/event.c
[elf]: https://github.com/termux/proot/blob/ab2e3464d04483b98a0614b470f3f8950d5a6468/src/execve/elf.c
[exec-policy]: https://developer.android.com/about/versions/10/behavior-changes-10#execute-permission
