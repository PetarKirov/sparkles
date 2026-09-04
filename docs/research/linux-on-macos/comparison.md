# Comparison — Linux on macOS builders and runtimes

**Last reviewed:** September 4, 2026

## At a glance

|                                | [Determinate native builder][detsys] | [Apple `container`][container] | [nix-darwin linux-builder][darwin] | [IOHK nix-linux-builder][iohk] |
| ------------------------------ | ------------------------------------ | ------------------------------ | ---------------------------------- | ------------------------------ |
| Job                            | realize Linux drvs                   | run Linux processes            | realize Linux drvs                 | realize Linux drvs             |
| Transport                      | VZ via `determinate-nixd`            | VZ, one VM per container       | QEMU SSH or VZ SSH                 | VZ via `external-builders`     |
| `aarch64-linux`                | yes (gated)                          | `--arch arm64`                 | yes                                | yes                            |
| `x86_64-linux`                 | yes (gated)                          | `--arch amd64 --rosetta`       | VZ+Rosetta / QEMU TCG              | Rosetta                        |
| Runs `ci --test` in a worktree | no                                   | **yes**                        | only if you SSH in and install dub | no                             |
| Builds uncached Linux drvs     | **yes**, if granted                  | not by itself                  | **yes**                            | **yes**, ungated               |
| Persistent guest store         | opaque                               | no (ephemeral container)       | **yes**                            | host store via VirtioFS        |
| Setup on this host             | configured, **HTTP 400**             | **works** (1.1.0)              | `/etc/nix/machines` missing        | not installed                  |
| Interactive fail shell         | no                                   | `container exec` / machine     | `ssh builder@linux-builder`        | `nix-linux-shell`              |

## Consensus

**Split the jobs.** Realizing a Linux drv and executing a working-tree
test suite are different kernels of work. Every Nix-native helper
(Determinate, nix-darwin, IOHK) is a _builder_. Apple `container` is a
_runtime_. Sparkles needs both: substitutes (or a builder) for
`packages.aarch64-linux.ci`, and a runtime to exec it.

**Virtualization.framework won the transport.** Determinate, Apple
`container`, `linux-builder-vz`, and IOHK all sit on VZ. QEMU remains
the bootstrap for Intel Macs and for the stock `darwin.linux-builder`.

**Rosetta, not TCG, for `x86_64-linux` on Apple silicon.** Apple
Containerization, `linux-builder-vz`, and IOHK all say so. Confirmed
here with `uname` and Nix `hello`.

## The splits

1. **Gating.** Determinate's helper is a product feature. IOHK's is a
   flake you enable. Same protocol, different door.
2. **Guest store vs host store.** nix-darwin QEMU snapshots the store
   to avoid lock deadlocks. IOHK/Determinate/container bind the host
   store and pay VirtioFS's `DAC_OVERRIDE` tax (IOHK with an ext4 loop).
3. **Persistence.** A launchd NixOS VM keeps `/nix/store` warm. Apple
   `container run --rm` does not. `container machine` is the persistent
   sibling, but `$HOME` is not `/Volumes/Dev`.

## Delta — sparkles today

See [sparkles-baseline][baseline]. The short version: Linux flake
outputs **substitute**; they do not **build**; they **execute** inside
Apple `container` with `/nix/store` mounted — and the dev shell is
**entered** there from its derivation's JSON, the way `nix-shell` enters
one, so the guest has CI's exact environment. `ci --host-system` is the
dispatcher.

<!-- References -->

[detsys]: ./determinate-linux-builder.md
[container]: ./apple-container.md
[darwin]: ./nix-darwin-linux-builder.md
[iohk]: ./nix-darwin-linux-builder.md
[baseline]: ./sparkles-baseline.md
