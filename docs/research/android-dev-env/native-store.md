# Native canonical stores and NNS (Linux / Android / Zig)

A real filesystem view of `/nix/store` removes PRoot tracing, while retaining Android's kernel and deployment constraints.

| Field          | Value                                                                                                  |
| -------------- | ------------------------------------------------------------------------------------------------------ |
| Language       | Zig 0.16 launcher/bridge; Nix; kernel patches; shell integration                                       |
| License        | No root license file found in inspected NNS revision; resolve terms before code reuse                  |
| Repository     | [NNS][readme]; [Nix store implementation][store]                                                       |
| Documentation  | [Kernel requirements][kernel], [DNS bridge][dns], [Android test harness][test]                         |
| Category       | Shared kernel; real namespace / privileged filesystem setup                                            |
| Prerequisites  | Root store provisioning; user/mount namespace route or privileged launcher; appropriate Android policy |
| Custom app fit | Execute launcher through existing PTY; no Termux app dependency                                        |

## Overview

### What it solves

Canonical `/nix/store` paths can be made real in a process's mount view rather than translated on every syscall. NNS combines this with boot provisioning, portable services and a glibc-to-Bionic DNS/TTY bridge.

### Design philosophy

The current README calls its launcher a “user-namespace `nix-enter` launcher (no proot)”. [Source][readme] The repository targets a Pixel 7 Pro with EvolutionX, SukiSU and a custom GKI kernel. This is a controlled deployment stack, not a stock-phone trick.

## How it works

[Current `nix-enter.zig`][launcher] is the authority for launcher mechanics; some older module prose describes a different mount-move design. The launcher is static/no-libc, forks a disposable child, prepares a private mount namespace, constructs a scratch root, bind-mounts the real host view under `.nns-host` and the physical store (normally `/data/nix`) at `/nix`, mirrors needed host directories, then uses `pivot_root` and detaches the old root. The parent owns cleanup and remains in its original namespace.

Non-root entry uses `CLONE_NEWUSER` plus `CLONE_NEWNS`, preserving numeric UID/GID mappings rather than granting host root. Root entry uses a mount namespace directly; explicit userns mode is also available. The launcher manages parent death and scratch cleanup. Canonical paths therefore resolve through actual mounts, while inherited Android UID/resource policy still matters.

[Nix's own chroot-store documentation][store] similarly requires user and mount namespaces for relocation. Its [run implementation][run] performs real namespace/chroot setup. Neither feature can manufacture missing Android kernel support or remove an inherited zygote filter.

## Analysis

### Deployment and permissions

[NNS kernel integration][kernel] requires `CONFIG_USER_NS=y` and an exec-time seccomp bypass facility. A root-controlled exact-path allowlist under `/proc/sys/kernel/seccomp_bypass_paths` causes the patched kernel to clear the inherited filter for approved entry executables. This cannot be implemented by an ordinary userspace process. NNS also adds an `nns_app` SELinux transition and rules for namespace/mount/PTY operations.

“SELinux enforcing” remains compatible with these deliberate policy changes; it does not mean the original stock policy is unchanged. Both [locally probed stock Xiaomi devices][devices] reject the app namespace route. On the Pad, a newer 6.6 kernel and AVF support do not change that finding.

A root-owned helper using mount namespaces/chroot is another native design, potentially without NNS's userns path, but still needs policy and a carefully scoped privilege interface. Do not expose arbitrary root command execution to a terminal client merely to simplify entry.

### Nix compatibility and services

A canonical Linux store can reuse normal binary-cache outputs. [NNS's nix-on-droid integration][module] replaces the PRoot login backend, points clients at the root daemon and disables PRoot bundling. The [daemon configuration][config] disables build sandboxing and uses an empty build-user group; this is not a sandboxed multi-user NixOS installation by default.

Portable runit services can supervise selected daemons. They do not create systemd, a guest kernel, Linux containers or all NixOS module semantics. Kernel features needed by builds, debuggers and network tools must be tested individually. A remote builder can reduce local compilation work but does not resolve local loader/runtime incompatibility.

### Terminal and no-DEX integration

The app can launch `nix-enter` through a native PTY, preserving its rendering/input architecture. Provisioning and privilege live outside the ordinary UI process. Session handoff must preserve environment, working directory, cancellation and process ownership. This fits no-DEX more naturally than porting managed framework code, but only after the device stack is deliberately provisioned.

### Files, networking and DNS

[The DNS bridge][dns] preloads a glibc-side shim that calls a Bionic resolver helper with a clean environment and bounded protocol. It covers dynamic `getaddrinfo`, not every resolver API, statically linked program or custom DNS stack. Its physical helper path matters to Android linker namespaces. The bridge also handles selected terminal ioctl compatibility; it is not a blanket libc ABI converter.

Store write ownership belongs to the daemon/provisioning layer. The app's same-UID namespace view should not make the shared store writable. Credential-encrypted data availability affects boot/unlock startup. Test Android DNS routing/VPN, shared file permissions and TTY behavior explicitly rather than inheriting desktop assumptions.

### Performance and isolation

Native pathname resolution avoids PRoot's tracing overhead. It shares the Android kernel, scheduler, resource controls and security policy, so it cannot reproduce a guest's isolation. The root namespace should remain unchanged after entry. [NNS's Android harness][test] checks a real non-debuggable zygote app, policy transition, same-UID entry, parent namespace stability, non-writable shared store and signed cache substitution. Those are upstream test claims read from source; this research did not rebuild and run its custom-kernel VM harness.

### Lifecycle and maintenance

The root module, kernel patches, SELinux rules, launcher and DNS bridge form a versioned unit. Kernel/ROM updates need a recovery and compatibility plan. NNS's README labels the session/service integration in progress despite mature launcher/bridge pieces. A terminal integrating it should make backend readiness and boot/unlock state visible, and should not promise automatic migration across different app UIDs or kernel updates.

## Strengths

- Native Linux execution with canonical store paths and no syscall tracer.
- Existing native PTY can invoke the launcher directly.
- NNS includes realistic Android app-domain test architecture and resolver integration.

## Weaknesses

- The ordinary-app route requires substantial custom kernel and policy integration.
- Android kernel limitations remain; no complete NixOS/systemd semantics.
- Root provisioning, bridge compatibility and unresolved repository license terms require separate decisions.

## Key design decisions and trade-offs

| Decision                          | Rationale                                      | Trade-off                                      |
| --------------------------------- | ---------------------------------------------- | ---------------------------------------------- |
| Canonical store in real mounts    | Reuse Linux outputs without tracing            | Needs namespaces or privileged setup           |
| Preserve app UID                  | Avoid host-root terminal sessions              | Android policy/resource limits remain          |
| Kernel exec-time filter exemption | Enable namespace syscalls from zygote children | Custom security integration and upgrade burden |
| Root daemon owns store            | Share persistent packages safely               | Privileged lifecycle and daemon trust          |

## Sources

- [Launcher source][launcher], [kernel contract][kernel], [DNS bridge][dns].
- [Module integration][module], [Android harness][test], [Nix store model][store].
- [Device observations][devices] and [source ledger][sources].

<!-- References -->

[readme]: https://github.com/reo101/NNS/blob/28d2229a664cbe29e55a051d648a789b6511f735/README.md
[launcher]: https://github.com/reo101/NNS/blob/28d2229a664cbe29e55a051d648a789b6511f735/module/src/nix-enter.zig
[kernel]: https://github.com/reo101/NNS/blob/28d2229a664cbe29e55a051d648a789b6511f735/kernel/README.md
[dns]: https://github.com/reo101/NNS/blob/28d2229a664cbe29e55a051d648a789b6511f735/module/src/DNS.md
[module]: https://github.com/reo101/NNS/blob/28d2229a664cbe29e55a051d648a789b6511f735/nix/nix-on-droid.nix
[config]: https://github.com/reo101/NNS/blob/28d2229a664cbe29e55a051d648a789b6511f735/module/etc/nix/nix.conf
[test]: https://github.com/reo101/NNS/blob/28d2229a664cbe29e55a051d648a789b6511f735/tests/android/README.md
[store]: https://github.com/NixOS/nix/blob/1ed54a0fd62da96d4f5e9c806555861e46f65341/src/libstore/local-store.md
[run]: https://github.com/NixOS/nix/blob/1ed54a0fd62da96d4f5e9c806555861e46f65341/src/nix/run.cc
[devices]: ./device-validation/index.md
[sources]: ./sources.md
