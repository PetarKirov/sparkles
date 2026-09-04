# Determinate native Linux builder (Nix)

A Virtualization.framework-backed `external-builders` helper that lets
`nix build` realize `aarch64-linux` and `x86_64-linux` derivations on
macOS without SSH, Docker, or a persistent NixOS VM.

|               |                                                                           |
| ------------- | ------------------------------------------------------------------------- |
| Language      | Swift (nixd) + Nix                                                        |
| License       | Determinate Nix (not upstream Nix)                                        |
| First release | Determinate Nix 3.8.4, 2025-08-05                                         |
| Documentation | [linux-builder docs][docs], [changelog][blog], [troubleshooting][trouble] |
| Category      | Nix derivation builder                                                    |

## Overview

### What it solves

Nix derivations are system-specific. On `aarch64-darwin`,
`nix build nixpkgs#legacyPackages.aarch64-linux.cowsay` normally needs a
cache hit, a remote builder, or a local Linux VM. Determinate's helper
is meant to make that command work with no extra setup.

> That's right: with Determinate Nix you can now build Linux derivations
> on macOS without pulling from a cache or running a remote builder, a
> Docker image, or a Linux virtual machine.

— [Changelog: a native Linux builder for macOS][blog]

### Design philosophy

Nix grows an `external-builders` hook; `determinate-nixd` implements the
hook by booting a short-lived Linux VM via Virtualization.framework.
Configuration is a JSON blob in `nix.conf`, not a launchd NixOS guest.

## How it works

`nix show-config external-builders` on this host (Determinate Nix
3.22.3, 2026-09-04):

```json
[
  {
    "systems": ["aarch64-linux", "x86_64-linux"],
    "program": "/usr/local/bin/determinate-nixd",
    "args": ["builder"]
  }
]
```

`determinate-nixd builder --help` exposes `--memory-size` (default 8
GiB), `--cpu-count` (default **1**), `--kernel`, `--initrd`. The
nix-darwin-generated `/etc/nix/nix.custom.conf` does not pass
`--cpu-count`, so a successful builder would run `ci --test` on one
vCPU unless that JSON is edited.

The feature is gated. Troubleshooting requires a FlakeHub login (this
host is logged in as `PetarKirov`) and an access grant. The probe:

```text
error: Cannot build '...-sparkles-linux-builder-probe.drv'
… while waiting for the build environment … to initialize
Error: failed to set up Native Linux Builder
Caused by:
    HTTP status code 400 Bad Request, reply: The Native Linux Builder
    is not currently available. Contact support@determinate.systems
    for more information.
```

`determinate-nixd version` lists enabled features as `lazy-trees` only
— not `native-linux-builder`. The blog's check ("If you see the message
`The feature native-linux-builder is enabled`") is negative here.

Nix-side work: [nix-src#78][pr78] (merged 2025-07-17,
`6d121936064b591f212cb90fb88e274306f38419`), plus #141 and #152.

## Analysis spine

1. **Execution model.** One VM per derivation (or a pooled VM — the
   helper is opaque). Not an interactive shell.
2. **Nix integration.** First-class: Nix decides to exec the helper
   when the drv's system matches.
3. **Architectures.** Both `aarch64-linux` and `x86_64-linux` in the
   JSON. x86_64 is presumably Rosetta-in-guest; not independently
   confirmed here because the helper never booted.
4. **Store sharing.** The helper must mount the Darwin `/nix/store`
   into the guest (same VirtioFS problem IOHK documents). Outputs land
   back in the host store.
5. **Availability.** Configured on this host, FlakeHub-authenticated,
   **feature-gated off**.
6. **Interactive vs derivation.** Derivation only. `ci --test` is not a
   drv.

## Strengths

- Transparent `nix build .#packages.aarch64-linux.ci` when enabled.
- No SSH keys, no `/etc/nix/machines`, no persistent disk image.
- Same protocol as the open-source IOHK helper.

## Weaknesses

- Access is granted by Determinate, not by having the bits installed.
- Default `--cpu-count 1` is wrong for a parallel test suite.
- No interactive shell when a Linux build fails (IOHK adds
  `nix-linux-shell` for that).
- A configured-but-gated helper still _runs_ and returns 400, so Nix
  does not fall back to "just substitute". Sparkles' dispatcher
  therefore passes `--option external-builders '[]'` when realizing
  cached paths.

## Key design decisions and trade-offs

| Decision                           | Rationale                  | Trade-off                                   |
| ---------------------------------- | -------------------------- | ------------------------------------------- |
| `external-builders` instead of SSH | No daemon VM, no host keys | New Nix feature; not in every Nix           |
| Feature-gate behind FlakeHub       | Gradual rollout            | A working install can still be a 400        |
| Default 1 vCPU / 8 GiB             | Conservative for laptops   | Unusable for `ci --test` without JSON edits |

## Sources

- [Determinate 3.8.4 blog][blog]
- [Docs][docs] / [troubleshooting][trouble]
- [nix-src#78][pr78]

<!-- References -->

[blog]: https://determinate.systems/blog/changelog-determinate-nix-384/
[docs]: https://docs.determinate.systems/determinate-nix/linux-builder/
[trouble]: https://docs.determinate.systems/troubleshooting/native-linux-builder/
[pr78]: https://github.com/DeterminateSystems/nix-src/pull/78
