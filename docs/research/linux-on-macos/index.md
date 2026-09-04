# Linux on macOS — building and testing Nix flake outputs

How to realize `{aarch64,x86_64}-linux` Nix derivations on an Apple-silicon
Mac, and how to _run_ the working-tree command `ci --test` for those
systems — not merely download a Linux ELF into `/nix/store`.

The sparkles flake already declares Linux outputs: `inputs.systems` is
[`nix-systems/triplet`][nix-systems-triplet], i.e.
`["aarch64-darwin" "aarch64-linux" "x86_64-linux"]`. GitHub Actions already
runs `ci --test` on `ubuntu-latest` (`x86_64-linux`) and `ubuntu-24.04-arm`
(`aarch64-linux`). This tree is about doing the same **from the laptop**.

**Last reviewed:** September 4, 2026

This survey answers six questions:

1. What is the difference between substituting a Linux store path, building
   one, and executing one — and how is a dev shell _entered_ with no builder?
   → [concepts][concepts]
2. What does Determinate Nix's native Linux builder actually do, and why
   does a configured host still get HTTP 400? → [determinate-linux-builder][detsys]
3. How does Apple `container` run a Linux userspace, including `linux/amd64`
   via Rosetta? → [apple-container][container]
4. What is the Virtualization.framework package underneath it?
   → [apple-containerization][containerization]
5. How does the older nix-darwin / nixpkgs Linux builder compare, and what
   is the open-source `external-builders` peer?
   → [nix-darwin-linux-builder][darwin-builder]
6. What should sparkles use today? → [sparkles-baseline][baseline] +
   [recommendations][recommendations]

---

## Master catalog

| Subject                          | What it is                                                | Runs Linux ELFs?   | Builds missing Linux drvs? | Link                                          |
| -------------------------------- | --------------------------------------------------------- | ------------------ | -------------------------- | --------------------------------------------- |
| Concepts                         | substitute vs build vs execute; store bind-mount          | —                  | —                          | [concepts.md][concepts]                       |
| Determinate native Linux builder | `external-builders` → `determinate-nixd builder` (VZ)     | derivations only   | yes, if the feature is on  | [determinate-linux-builder.md][detsys]        |
| Apple `container`                | OCI CLI; one lightweight VM per container                 | yes                | not by itself              | [apple-container.md][container]               |
| Apple Containerization           | Swift package: VZ + `vminitd` + Rosetta for `linux/amd64` | yes (as a library) | not by itself              | [apple-containerization.md][containerization] |
| nix-darwin `linux-builder`       | persistent NixOS VM, SSH remote builder                   | derivations only   | yes, once the VM is up     | [nix-darwin-linux-builder.md][darwin-builder] |
| Comparison                       | capability matrix                                         | —                  | —                          | [comparison.md][comparison]                   |
| sparkles baseline                | what this machine and this flake do today                 | observed           | observed                   | [sparkles-baseline.md][baseline]              |
| Recommendations                  | the dispatcher `ci --host-system`                         | —                  | —                          | [recommendations.md][recommendations]         |

## Taxonomy

### By Nix integration

| Integration                         | Mechanism                                                                | Subjects                                    |
| ----------------------------------- | ------------------------------------------------------------------------ | ------------------------------------------- |
| `external-builders` JSON protocol   | Nix execs a helper with a build.json; the helper runs the drv in a VM    | Determinate, [IOHK nix-linux-builder][iohk] |
| SSH `builders = @/etc/nix/machines` | classical remote builder                                                 | nix-darwin linux-builder                    |
| None (execute only)                 | bind-mount `/nix/store` into a Linux VM and exec an already-realized ELF | Apple `container`                           |

### By who provides the Linux kernel

| Kernel source                   | Subjects                                     |
| ------------------------------- | -------------------------------------------- |
| Determinate-shipped guest       | Determinate native builder                   |
| Apple `container system kernel` | Apple `container` / Containerization         |
| NixOS guest image               | nix-darwin linux-builder, `linux-builder-vz` |
| IOHK prebuilt `guest-kernel`    | nix-linux-builder                            |

## Milestones

| Date       | What landed                                                                                                                             |
| ---------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| 2022       | nixpkgs `darwin.linux-builder` (QEMU NixOS VM, SSH on port 31022)                                                                       |
| 2025-05-28 | [DeterminateSystems/nix-src#78][pr78] — `external-builders` experimental feature                                                        |
| 2025-08-05 | Determinate Nix 3.8.4 blog: native Linux builder for macOS (developer preview)                                                          |
| 2025-06-09 | Apple `container` / Containerization public repos                                                                                       |
| 2026-05-06 | IOHK `nix-linux-builder` v0.3.0 — same `external-builders` protocol, ungated                                                            |
| 2026-09-04 | This survey: Determinate builder configured but gated; Apple `container` 1.1.0 runs `ci --test` inside the reconstructed `devShells.ci` |

## Suggested reading

- **I want to run `ci --test` on Linux from this Mac.** [recommendations][recommendations], then `ci --linux-host-probe` and `ci --test --host-system aarch64-linux`.
- **I want `nix build .#packages.aarch64-linux.*` to compile missing paths.** [determinate-linux-builder][detsys] (gated) or [nix-darwin-linux-builder][darwin-builder] / [IOHK][iohk].
- **I am designing the dispatcher.** [concepts][concepts] then [sparkles-baseline][baseline].

## Sources

- [Determinate Nix 3.8.4 changelog][detsys-blog]
- [Determinate native Linux builder docs][detsys-docs]
- [Determinate troubleshooting][detsys-trouble]
- [Apple `container` README][container-gh]
- [Apple Containerization README][containerization-gh]
- [nixpkgs darwin-builder manual][nixpkgs-builder]
- [IOHK nix-linux-builder][iohk]

<!-- References -->

[concepts]: ./concepts.md
[detsys]: ./determinate-linux-builder.md
[container]: ./apple-container.md
[containerization]: ./apple-containerization.md
[darwin-builder]: ./nix-darwin-linux-builder.md
[comparison]: ./comparison.md
[baseline]: ./sparkles-baseline.md
[recommendations]: ./recommendations.md
[nix-systems-triplet]: https://github.com/nix-systems/triplet
[detsys-blog]: https://determinate.systems/blog/changelog-determinate-nix-384/
[detsys-docs]: https://docs.determinate.systems/determinate-nix/linux-builder/
[detsys-trouble]: https://docs.determinate.systems/troubleshooting/native-linux-builder/
[container-gh]: https://github.com/apple/container
[containerization-gh]: https://github.com/apple/containerization
[nixpkgs-builder]: https://github.com/NixOS/nixpkgs/blob/7016c95300d32ecec6a5bea651c63b5d09e3c0df/doc/packages/darwin-builder.section.md
[iohk]: https://github.com/input-output-hk/nix-linux-builder/blob/65ecc7687e0df4b3e634e3e026f8e7822a961800/README.md
[pr78]: https://github.com/DeterminateSystems/nix-src/pull/78
