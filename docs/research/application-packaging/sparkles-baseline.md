# The Sparkles Packaging Baseline

An audit of what this repository builds, releases, and distributes today. This page
records observed configuration and code; it does not infer unimplemented packaging
behavior from tool names or future plans.

**Last reviewed:** July 12, 2026

> [!IMPORTANT]
> Sparkles currently has a mature **source/package release** and Nix binary-cache
> pipeline, but no general end-user application-packaging matrix. The repository does
> not currently produce `.deb`, RPM, Arch packages, AppImage, Flatpak, Snap, MSI, MSIX,
> setup EXEs, `.app`, DMG, PKG, or XIP artifacts in its release workflow. Those formats
> are research targets, not tested current behavior.

## Current product and version identity

Sparkles is one `dub` monorepo package with sub-packages. Its release policy is one
SemVer version for the entire repository: an annotated `vX.Y.Z` git tag is authoritative,
and no `dub.sdl` carries a `version` field. code.dlang.org exposes the repository as the
`sparkles` package and consumers select sub-packages such as `sparkles:base`; internal
sub-package edges use relative `path=` dependencies. These are current facts from
[`docs/guidelines/release.md`][release-guide] and the root/package manifests, not a
proposed application identity scheme.

The implication for application packaging is useful but limited: a future artifact can
derive its marketing/package version from the same tag, while each platform still needs
a stable native identifier—package name, MSI/MSIX identity, macOS bundle identifier—and
explicit upgrade semantics ([concepts § identity][concepts-identity], [platform
gotchas][gotchas]).

## What Nix builds today

[`flake.nix`][flake] uses `flake-parts` over the triplet system set and imports the
package modules under `nix/packages/`. The relevant outputs are:

- `packages.ci`: a `buildDubPackage` executable wrapped with `gitMinimal`, `dub`, and a D
  compiler because it compiles/runs examples at runtime;
- `packages.release`: a `buildDubPackage` executable wrapped with `gitMinimal`, `gh`, and
  the flake-built `ci`; it deliberately excludes the D compiler from its runtime closure;
- `legacyPackages.examples.<lib>.<name>`: one Nix derivation per standalone D example;
- `packages.run-all-examples`: a smoke runner for runnable example derivations;
- `packages.all`: a `linkFarm` aggregating `devShells.full`, every package except itself,
  and flattened standalone examples.

[`nix/packages/default.nix`][nix-default] builds both CLI executables with LDC except that
`ci` prefers DMD on `x86_64-linux`; it uses the shared Nix-format
`nix/dub-lock.json`. [`nix/packages/examples.nix`][nix-examples] enumerates
`libs/*/examples/**.d`, builds each single-file program in release mode, scrubs selected
unneeded runtime references, and records build-only versus runnable examples.
[`nix/packages/all.nix`][nix-all] is an aggregate closure, not an installer or portable
bundle format.

Nix therefore supplies pinned build inputs, per-system derivations, a binary cache, and
an auditable closure. It does **not** currently define a normalized application stage
tree, platform installer metadata, code signing, SBOM, or an end-user updater feed
([release pipeline][pipeline]). A Nix store closure also is not automatically portable to
non-Nix systems.

## CI and host coverage

The main [CI workflow][ci-workflow] tests:

| Runner / target                   | Compiler coverage | Work performed                                                |
| --------------------------------- | ----------------- | ------------------------------------------------------------- |
| `ubuntu-latest` / `x86_64-linux`  | LDC and DMD       | `nix flake check`, all sub-package tests, standalone examples |
| `macos-latest` / `aarch64-darwin` | LDC               | same main test path                                           |
| `windows-latest`                  | LDC 1.41.0        | one Win32 OS-API example only                                 |

A separate `nix-build` job builds and pushes `.#all` on Ubuntu and macOS. The Windows
job does not build all Sparkles packages and does not package or sign a Windows release.
The [docs workflow][docs-workflow] builds VitePress on Linux and deploys to Cloudflare
Pages; the [lint workflow][lint-workflow] runs repository hooks and markdown-example
verification. These provide strong source/tests/docs gates but no clean-VM installer
install/upgrade/uninstall tests.

## The `release` application

[`apps/release/src/app.d`][release-app] and the normative
[`docs/specs/release/SPEC.md`][release-spec] implement release orchestration around git,
GitHub, code.dlang.org, and the current Nix pipeline:

1. scan SemVer tags and commits since the latest;
2. derive a pre-1.0-aware bump from conventional commits (or accept an override);
3. gather release notes in `$EDITOR` or through a user-provided CLI LLM agent;
4. run preflight checks unless `--no-verify`;
5. create an annotated tag locally;
6. optionally push it, create a draft GitHub Release, and publish the release.

The cumulative stages are `create-tag`, `push-tag`, `create-gh-release-draft`, and
`publish-gh-release`. Split mode can associate commits with PRs, validate an agent's
contiguous release plan, and create a chain of tags oldest-first. Artifacts under
`.result/release-split/` are review records for segmentation/notes, not distributable
application artifacts.

The packaged `release` binary shells out to `git`, optionally `gh`, and the repository's
`ci`; it does not invoke WiX, `makemsix`, `codesign`, `notarytool`, `dpkg-deb`, `rpmbuild`,
`appimagetool`, Flatpak, or Snapcraft. Its “publish” vocabulary currently means tag and
GitHub Release state, not package-index publication ([concepts § publish][concepts-publish]).

## Current release workflow

The [Release workflow][release-workflow] triggers when a GitHub Release is **published**
(or manually):

1. `notify-dub-registry` POSTs the Sparkles update endpoint so code.dlang.org ingests the
   tag promptly. The registry can independently discover any pushed tag earlier, so tag
   push is the real point of no return.
2. `nix-build-pin` runs on `ubuntu-latest` (`x86_64-linux`) and `macos-latest`
   (`aarch64-darwin`), checks out full history, builds `nix build .#all`, pushes the
   resulting closure to Cachix, and pins it as `latest-<system>` with three retained
   revisions.
3. Only the highest version-sorted `v*` tag may advance the stable Cachix pins, preventing
   split-release races or republished old releases from moving them backward.

This is a real immutable-source-to-binary-cache path, and it already has a primitive
promotion guard (“highest tag moves `latest-*`”). But the outputs are Nix store closures,
not versioned downloadable archives/native installers; no release asset checksums, SBOM,
provenance statement, platform code signatures, package repositories, or updater channels
are emitted by this workflow.

## Baseline against the ten dimensions

| Dimension                    | Sparkles today                                                         | Evidence / limit                                                                   |
| ---------------------------- | ---------------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| Role and scope               | source release + D registry notification + Nix closure cache           | [release guide][release-guide], [workflow][release-workflow]                       |
| Input and staging            | tagged git tree; Nix filesets per derivation                           | no common end-user stage-tree contract                                             |
| Output/install model         | code.dlang.org source package; Nix derivations/closures                | no portable archive or OS-native installer                                         |
| Dependency/runtime policy    | Nix closure pins runtime/build deps; `dub` lockfiles pin D deps        | no declared non-Nix redistribution boundary                                        |
| Target/host matrix           | full CI on `x86_64-linux` and `aarch64-darwin`; narrow Windows example | no Windows release matrix; no Linux distro baseline matrix                         |
| Identity/version/upgrades    | one annotated SemVer tag for all D sub-packages                        | no MSI/MSIX/bundle/repository identity or upgrade policy                           |
| Signing/notarization         | git/GitHub credentials and Cachix trust only                           | no Authenticode, Developer ID, notarization, or repository signing                 |
| Publishing/channels          | GitHub Release, code.dlang.org notification, Cachix `latest-*` pins    | no package indexes/stores/community catalog submissions                            |
| Updater/rollback             | Nix/Cachix consumers may address immutable store paths                 | no application updater/feed contract                                               |
| Supply chain/reproducibility | Nix pins inputs/closures; CI builds `.#all`                            | no final-artifact checksum manifest, SBOM, provenance, or measured reproducibility |

## The concrete delta

The nearest reusable foundation is not a particular packager; it is the existing release
control plane:

- one immutable tag/version and annotated release notes;
- a release CLI with preflight and cumulative outward stages;
- native-host CI on Linux and Apple Silicon macOS;
- a Nix definition that builds all packages/examples and pushes closures to Cachix;
- a highest-tag guard that prevents backward promotion.

What is missing is the application-delivery half: declare supported products/targets,
produce matrix binaries, normalize stage trees, choose format/channel pairs, establish
stable native identities, sign/notarize, generate checksums/SBOM/provenance, attach
immutable release assets, validate installers on clean hosts, and publish/promote package
indexes. The [comparison delta][comparison-delta] maps those gaps to surveyed prior art;
[recommendations] proposes an ordered path without claiming implementation.

## Sources

- [`flake.nix`][flake]
- [`nix/packages/all.nix`][nix-all], [`default.nix`][nix-default], and
  [`examples.nix`][nix-examples]
- [`apps/release/src/app.d`][release-app] and [`apps/release/dub.sdl`][release-dub]
- [`docs/specs/release/SPEC.md`][release-spec]
- [`docs/guidelines/release.md`][release-guide]
- [`.github/workflows/ci.yml`][ci-workflow], [`release.yml`][release-workflow],
  [`docs.yml`][docs-workflow], and [`lint.yml`][lint-workflow]

<!-- References -->

[concepts-identity]: ./concepts.md#identity-version-and-upgrades
[concepts-publish]: ./concepts.md#publish-and-promote
[pipeline]: ./release-pipeline.md
[comparison-delta]: ./comparison.md#the-sparkles-delta
[recommendations]: ./recommendations.md
[gotchas]: ./platform-gotchas.md
[flake]: ../../../flake.nix
[nix-all]: ../../../nix/packages/all.nix
[nix-default]: ../../../nix/packages/default.nix
[nix-examples]: ../../../nix/packages/examples.nix
[release-app]: ../../../apps/release/src/app.d
[release-dub]: ../../../apps/release/dub.sdl
[release-spec]: ../../specs/release/SPEC.md
[release-guide]: ../../guidelines/release.md
[ci-workflow]: ../../../.github/workflows/ci.yml
[release-workflow]: ../../../.github/workflows/release.yml
[docs-workflow]: ../../../.github/workflows/docs.yml
[lint-workflow]: ../../../.github/workflows/lint.yml
