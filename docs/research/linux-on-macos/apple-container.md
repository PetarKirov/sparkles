# Apple `container` (CLI)

A Swift CLI that creates and runs Linux containers as lightweight VMs on
Apple silicon. OCI images in and out. Optimized for macOS 26.

|               |                                                                              |
| ------------- | ---------------------------------------------------------------------------- |
| Language      | Swift                                                                        |
| License       | Apache-2.0                                                                   |
| Repository    | [`apple/container`][gh] @ `5973b9cc626a3e7a499bb316a958237ebe14e2ed` (1.1.0) |
| Documentation | [technical overview][overview], [how-to][howto], [command reference][ref]    |
| Category      | Linux userspace on macOS                                                     |

## Overview

### What it solves

> `container` runs containers differently. Using the open source
> Containerization package, it runs a lightweight VM for each container
> that you create.

— [`docs/technical-overview.md`][overview]

That is the opposite of Docker Desktop's shared Linux VM. Each
`container run` is its own kernel, network namespace story, and VirtioFS
mount set.

### Design philosophy

VM isolation per container; OCI compatibility so images from any
registry run; macOS frameworks (Virtualization, vmnet, XPC, launchd)
instead of a Linux hypervisor userspace.

## How it works

`container system start` launches `container-apiserver` as a launch
agent, plus `container-core-images` and `container-network-vmnet`. Each
container gets `container-runtime-linux`. Observed 2026-09-04: CLI
1.1.0, apiserver the same commit.

```text
$ container run --rm --arch arm64 alpine uname -a
Linux … 6.18.15 #1 SMP Tue Mar 17 01:36:53 UTC 2026 aarch64 Linux

$ container run --rm --arch amd64 --rosetta alpine uname -a
Linux … 6.18.15 #1 SMP Tue Mar 17 01:36:53 UTC 2026 x86_64 Linux
```

`--volume /nix/store:/nix/store` (VirtioFS) lets a substituted Linux
`hello` and the sparkles `packages.aarch64-linux.ci` wrapper run.
`--volume $PWD:$PWD --workdir $PWD` gives `dub test` a writable tree.
`--env PATH=.../pkg-config/bin:/bin:/usr/bin` is required: the `ci`
wrapper's `PATH` has `ldc`/`dub`/`git` but not `pkg-config`, and
`dub test :ci` ImportC's `tree_sitter/api.h`.

`container run` always needs an image name (`alpine`). The image's
userspace is mostly unused when the command is a Nix ELF; alpine is a
stub rootfs. A missing image argument is `Error: invalid format for
image reference`.

**Container machines** (`container machine create`) persist a Linux
environment and mount `$HOME`. Sparkles lives on `/Volumes/Dev`, not
under `$HOME`, so a bind-mount of the repo is still required.
Nested virt (`--virtualization`) needs M3+ and a KVM-enabled kernel;
this host is `ARM64_T6041` (M5-class, Darwin 25.6.0) so nested virt is
available if a custom kernel is installed.

## Analysis spine

1. **Execution model.** One VZ VM per container; `vminitd` as guest
   PID 1; the OCI process is not PID 1 unless you skip `--init`.
2. **Nix integration.** None. Sparkles supplies it by bind-mounting
   `/nix/store` and exec'ing a substituted Linux `ci`.
3. **Architectures.** `--arch arm64` native; `--arch amd64 --rosetta`
   for x86_64-linux. Confirmed both ways.
4. **Store sharing.** VirtioFS bind mounts. `/nix/store:ro` is enough
   to _run_. Building new store paths needs a guest Nix.
5. **Availability.** Installed (`~/.nix-profile/bin/container`), works
   after `container system start --enable-kernel-install`.
6. **Interactive vs derivation.** Interactive and one-shot commands.
   The right tool for `ci --test`.

## Strengths

- Real Linux kernel, both arches, sub-second start after the kernel is
  cached.
- Bind-mount of `/nix/store` actually executes Linux Nix closures.
- `container machine` is the "edit on Mac, build in Linux" workflow,
  once extra volumes cover `/Volumes/Dev`.

## Weaknesses

- Not a Nix builder. Missing Linux drvs still need substitutes or
  another backend.
- Memory ballooning is partial; freed guest pages are not returned to
  macOS ([technical overview][overview]).
- Default image has no `pkg-config`; the dispatcher enters the whole
  dev shell instead (see [concepts][concepts]).
- **Rosetta does not honour `SA_RESETHAND`.** A `SIGSEGV` handler
  installed with that flag is delivered again and again instead of once
  ([`examples/sa-resethand.d`](./examples/sa-resethand.d): 100+
  deliveries under `--rosetta`, one on native aarch64-linux and Darwin).
  druntime's unittest segfault handler relies on the flag, so a test that
  deliberately crashes a forked child loops forever under Rosetta — see
  [sparkles-baseline § x86_64][baseline-x86].
- macOS 15 is tolerated but not supported.

## Key design decisions and trade-offs

| Decision             | Rationale                | Trade-off                              |
| -------------------- | ------------------------ | -------------------------------------- |
| One VM per container | Isolation, dedicated IPs | Heavier than a shared Docker VM        |
| OCI images           | Interop                  | Guest has no Nix unless you install it |
| VirtioFS bind mounts | Share the host tree      | Same DAC_OVERRIDE limits IOHK hit      |

## Sources

- [`apple/container` README][gh]
- [technical overview][overview], [how-to][howto], [command reference][ref]
- [container machines][machines]

<!-- References -->

[concepts]: ./concepts.md#enter-a-dev-shell-without-building-it
[baseline-x86]: ./sparkles-baseline.md#results-ci---test-on-x86_64-linux-rosetta
[gh]: https://github.com/apple/container
[overview]: https://github.com/apple/container/blob/5973b9cc626a3e7a499bb316a958237ebe14e2ed/docs/technical-overview.md
[howto]: https://github.com/apple/container/blob/5973b9cc626a3e7a499bb316a958237ebe14e2ed/docs/how-to.md
[ref]: https://github.com/apple/container/blob/5973b9cc626a3e7a499bb316a958237ebe14e2ed/docs/command-reference.md
[machines]: https://github.com/apple/container/blob/5973b9cc626a3e7a499bb316a958237ebe14e2ed/docs/container-machine.md
