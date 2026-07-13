# fpm and nFPM (Ruby and Go / package backends)

fpm and nFPM turn staged files and package metadata into native packages, but they make
different architectural bets: fpm is a package-format converter; nFPM is a Go packaging
library with a small declarative CLI.

| Field             | fpm                                                        | nFPM                                                                                                   |
| ----------------- | ---------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| Language          | Ruby                                                       | Go                                                                                                     |
| License           | MIT                                                        | MIT                                                                                                    |
| Repository        | [jordansissel/fpm][fpm-repo]                               | [goreleaser/nfpm][nfpm-repo]                                                                           |
| Documentation     | [README][fpm-readme] · [CLI reference][fpm-cli]            | [README][nfpm-readme] · [configuration][nfpm-example]                                                  |
| Reviewed source   | [`f51ba16fe8659cf2a4996a8e2b2e6a142bbc5b99`][fpm-reviewed] | [`6595841499a18755f03356b69511f32a8cec2761`][nfpm-reviewed]                                            |
| Category          | **Format converter/backend primitive**                     | **Format backend library and CLI**                                                                     |
| Hosts/targets     | Host/tool dependent; broad Unix package set and macOS PKG  | Pure-Go core for RPM, DEB, APK, Arch, IPK, and MSIX; input binaries must already target their platform |
| OSS/paid boundary | Open source                                                | Open source; GoReleaser commercial offerings are separate from nFPM                                    |

**Last reviewed:** July 12, 2026

> [!IMPORTANT]
> Neither tool is a release control plane. They do not compile a target matrix, host
> artifacts, update package repositories, submit catalog manifests, or run an installed
> updater. GoReleaser may call nFPM as one packaging stage; that does not make nFPM itself
> responsible for GoReleaser's build, signing, checksum, SBOM, or publication stages.

---

## Overview

### What it solves

fpm normalizes many package and language inputs into one in-memory package model and
staging directory, then converts that model to a selected output plugin. Its README
summarizes the user goal:

> “The goal of fpm is to make it easy and quick to build packages such as rpms, debs,
> OSX packages, etc.”
>
> — [`README.rst`][fpm-readme]

Its `-s`/`--input-type` can mean a filesystem directory or an existing/package-language
source such as `deb`, `rpm`, `gem`, `npm`, `python`, or `virtualenv`. `Command#execute`
loads the two plugin classes, asks the input plugin to populate staging and metadata,
runs `input.convert(output_class)`, and asks the output plugin to emit the result
([`lib/fpm/command.rb`][fpm-command], [`lib/fpm/package.rb`][fpm-package]). This is
conversion, not merely archive writing.

nFPM intentionally narrows that scope. Its README says:

> “I wanted something that could be used as a binary and/or as a library and that was
> really simple.”
>
> — [`README.md`][nfpm-readme]

`nfpm.Info` receives explicit package metadata and `files.Content` mappings; a registered
`Packager` writes one package to an `io.Writer` ([`nfpm.go`][nfpm-core]). It does not
import a Gem, Python package, DEB, or RPM and translate its metadata.

### Design philosophy

fpm favors **pluggable conversion and compatibility**. All package classes share metadata,
scripts, dependencies, staging/build workspaces, and conversion hooks; plugins may shell
out to `rpmbuild`, `pkgbuild`, `tar`, `ar`, language package managers, or other tools.
The flexibility brings a large runtime/tool surface.

nFPM favors **small library primitives and low external assumptions**. The CLI blank-imports
registered implementations and says it is a “0-dependencies” packager for `apk`, Arch,
`deb`, `ipk`, `msix`, and `rpm` ([`internal/cmd/root.go`][nfpm-root]). Package writers
construct formats in Go and accept an output stream. The library can inject signing
callbacks, which makes remote/KMS-backed signing possible without turning nFPM into a
secret manager.

## How it works

fpm's canonical staged-tree path is explicit:

```bash
fpm -s dir -t deb -n acme -v 1.2.3 \
    --depends 'libc6 >= 2.31' \
    ./build/acme=/usr/bin/acme ./LICENSE=/usr/share/doc/acme/LICENSE
```

nFPM expresses the same boundary in YAML:

```yaml
name: acme
arch: amd64
platform: linux
version: 1.2.3
maintainer: Acme <release@example.com>
depends:
  - libc6 >= 2.31
contents:
  - src: ./build/acme
    dst: /usr/bin/acme
    file_info:
      mode: 0755
```

The nFPM CLI infers a packager from the output extension or requires `--packager`, loads
configuration, applies format overrides/defaults, creates the output, and invokes
`Packager.Package(info, writer)` ([`internal/cmd/package.go`][nfpm-package-command]).
Its library boundary is intentionally smaller than fpm's conversion graph.

## Analysis dimensions

### Input and staging

fpm input plugins materialize a private `staging_path` plus common metadata. The `dir`
plugin copies `source=destination` mappings and preserves an install-root layout; package
input plugins may extract payload/control data, while language inputs may download and
install dependencies into staging ([`dir.rb`][fpm-dir], [`deb.rb`][fpm-deb]). Temporary
`staging_path` and `build_path` directories are removed unless `--debug-workspace` is set.
Arbitrary lifecycle scripts are read into the model.

nFPM consumes explicit `contents`: files, directories, symlinks, config files, ghost
entries, ownership, mode, and mtime. `PrepareForPackager` applies defaults and validates
format requirements before the writer runs ([`nfpm.go`][nfpm-core]). It does not build or
install an application into staging and does not resolve runtime libraries. Callers—often
GoReleaser—must provide final files.

### Outputs and target matrix

| Tool | Reviewed output implementations                                                                                        | Boundary                                                                                                                                                            |
| ---- | ---------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| fpm  | APK, DEB, FreeBSD pkg, macOS PKG, Pacman, P5P, pkgin, Puppet, RPM, shell installer, Snap, Solaris, tar, zip, directory | Plugins differ: some write archives, some invoke native/external tools; available conversion paths are not equally portable                                         |
| nFPM | APK, Arch Linux package, DEB, IPK, MSIX, binary RPM and SRPM                                                           | Writers are Go implementations, so foreign package bytes can often be produced on one host; payload architecture and target validity remain caller responsibilities |

fpm's same plugin classes can be inputs or outputs only where methods exist; listing a
class is not proof of bidirectional conversion. For example, its APK input reports that
extraction is not implemented and APK output reports that it does not sign packages
([`apk.rb`][fpm-apk]). macOS PKG delegates to `pkgbuild`, making macOS a native-tool host;
RPM options can pass through to `rpmbuild`.

nFPM's MSIX writer broadens it beyond Linux package formats, but nFPM does not produce
MSI/EXE installers, DMGs, PKGs, AppImages, Flatpaks, Snaps, or portable release archives.
It also does not cross-compile executables.

### Metadata and dependencies

Both models cover name, version/release, epoch, architecture, platform, maintainer/vendor,
description, homepage, license, dependencies, provides, conflicts, replaces, scripts, and
file metadata. fpm translates common fields in `converted_from` hooks and offers extensive
format-specific CLI flags. Translation is necessarily lossy where source and target
package semantics differ.

nFPM supports format overrides over a common `Info` and exposes richer native sections:
DEB pre-depends/recommends/suggests/triggers; RPM scripts/requires/compression; APK,
Arch, IPK, and MSIX-specific metadata ([`nfpm.go`][nfpm-core]). Dependency strings are
written into native metadata; neither project resolves or vendors those dependencies.

### Installation, upgrade, and uninstall

Generated native packages delegate installation databases, file ownership, upgrade
ordering, and removal to `dpkg`, RPM, APK, pacman, IPK, MSIX, or the corresponding
installer. fpm can attach before/after install, upgrade, remove, and transaction scripts,
with support varying by output plugin ([CLI reference][fpm-cli]). nFPM maps common and
format-specific script paths into each writer.

Neither tool installs the result, tracks deployed machines, or provides one portable
rollback/repair contract. Correct package name/version/architecture and script behavior
are caller policy. fpm's shell output is a self-extracting path with different guarantees
from a package-manager transaction.

### Signing and platform trust

fpm signing is uneven pass-through. `--rpm-sign` asks `rpmbuild` to sign; macOS packaging
can pass native options; the APK backend explicitly remains unsigned. There is no unified
PGP, Authenticode, Apple notarization, timestamp, or repository-signing stage.

nFPM directly supports package signatures for DEB, RPM, APK, and MSIX. `PackageSignature`
accepts key material or `SignFn`; its comment explicitly permits remote signers such as
KMS ([`nfpm.go`][nfpm-core]). DEB supports `debsign`/`dpkg-sig`-style payloads, RPM accepts
a PGP callback, APK signs its control digest, and MSIX loads a PFX
([`deb/deb.go`][nfpm-deb], [`rpm/rpm.go`][nfpm-rpm], [`apk/apk.go`][nfpm-apk],
[`msix/msix.go`][nfpm-msix]). This is package-envelope signing, not repository metadata
signing. nFPM does not timestamp Authenticode, notarize Apple software, or provision keys.

### Publication and discovery

Not applicable. Both stop at a local file or output stream. They do not create APT `Release`
metadata, RPM repository indexes, Alpine indexes, Arch repositories, MSIX App Installer
feeds, GitHub Releases, or store/catalog submissions. A release orchestrator or repository
tool must publish and index the package separately.

### Updates and release channels

Neither embeds an updater or models channels, rollout, deltas, promotion, or rollback.
A package manager can discover a newer package only after another system publishes an
updated repository index. Package identity and version fields enable that downstream
behavior but do not implement it.

### Automation and CI

Both CLIs are easy to run in one job. fpm's output plugins require Ruby plus a varying set
of executables, making container images or native runners part of the build contract.
Its broad input plugins may access networks and execute language tooling. nFPM's Go
library is easier to embed and its writer interface avoids subprocesses for the reviewed
formats; callers can stream bytes and inject signing.

Neither fans out runners, retries partial publication, isolates signing jobs, nor gathers
artifacts. GoReleaser's orchestration around nFPM belongs to GoReleaser, not nFPM.

### Supply-chain evidence and reproducibility

fpm honors `SOURCE_DATE_EPOCH` through `--source-date-epoch-default` as a hint for
archive timestamps ([`lib/fpm/command.rb`][fpm-command]); reproducibility still depends
on each plugin and external tool. nFPM's `Info.MTime` defaults from the same environment
concept and writers/tests use fixed mtimes; DEB tests explicitly compare repeat builds
with fixed time ([`nfpm.go`][nfpm-core], [`deb/deb_test.go`][nfpm-deb-test]).

Neither emits SBOMs, provenance attestations, or dependency lockfiles. Signing introduces
intentional nondeterminism or environment dependence unless the selected algorithm and
signer are reproducible. A control plane must record tool versions and hashes.

### Extensibility and UX

fpm discovers subclasses of `FPM::Package`; a plugin implements input/output and
conversion hooks while inheriting common options and staging. Its CLI is expressive but
large, and conversion can hide semantic mismatches.

nFPM's `RegisterPackager`, `Packager` interface, `Info` model, YAML/JSON tags, and
`io.Writer` output form a compact embedding API. Format overrides preserve native details.
The trade-off is deliberate narrowness: no general package-import interface, hooks for
release publication, or app-bundle abstraction.

## Strengths

- fpm rapidly converts directories and many existing/package-language inputs.
- fpm exposes deep native metadata and lifecycle-script controls.
- nFPM is embeddable, stream-oriented, and low-dependency for its supported writers.
- nFPM supports deterministic mtimes and injectable package-signing callbacks.
- Both cleanly fit as backend nodes beneath a release orchestrator.

## Weaknesses

- Neither builds target executables, repositories, catalog entries, feeds, or releases.
- fpm has a large Ruby/external-tool surface and uneven plugin capability/signing.
- Cross-format conversion can lose native metadata or lifecycle semantics.
- nFPM's format matrix is narrower and it does not import existing package types.
- Neither provides SBOM/provenance generation or a universal update model.

## Key design decisions and trade-offs

| Decision                                       | Rationale                                  | Trade-off                                            |
| ---------------------------------------------- | ------------------------------------------ | ---------------------------------------------------- |
| fpm normalizes through a common package object | Enable `-s X -t Y` conversion              | Native semantics may be lossy                        |
| fpm permits external tools per plugin          | Reuse mature ecosystem builders            | Host dependencies and reproducibility vary           |
| nFPM starts from explicit final files          | Keep the library simple and predictable    | Build/staging and dependency discovery stay upstream |
| nFPM writes through `io.Writer`                | Make embedding and testing straightforward | Publication is intentionally outside the API         |
| nFPM exposes `SignFn`                          | Allow local or remote package signers      | Secret policy and repository trust remain external   |
| Both stop at package construction              | Remain reusable backend primitives         | A separate control plane is mandatory for releases   |

## Sources

- fpm local clone at `/home/petar/code/repos/packaging/fpm`, reviewed at
  `f51ba16fe8659cf2a4996a8e2b2e6a142bbc5b99`.
- nFPM local clone at `/home/petar/code/repos/packaging/nfpm`, reviewed at
  `6595841499a18755f03356b69511f32a8cec2761`.
- fpm [`README.rst`][fpm-readme], command/conversion core, and package plugins under
  [`lib/fpm/package/`][fpm-plugins].
- nFPM [`nfpm.go`][nfpm-core], CLI registration, and format writer implementations.
- Evidence level: `[source-verified]`; no generated package was installed during review.

<!-- References -->

[fpm-repo]: https://github.com/jordansissel/fpm
[fpm-reviewed]: https://github.com/jordansissel/fpm/tree/f51ba16fe8659cf2a4996a8e2b2e6a142bbc5b99
[fpm-readme]: https://github.com/jordansissel/fpm/blob/f51ba16fe8659cf2a4996a8e2b2e6a142bbc5b99/README.rst
[fpm-cli]: https://github.com/jordansissel/fpm/blob/f51ba16fe8659cf2a4996a8e2b2e6a142bbc5b99/docs/cli-reference.rst
[fpm-command]: https://github.com/jordansissel/fpm/blob/f51ba16fe8659cf2a4996a8e2b2e6a142bbc5b99/lib/fpm/command.rb
[fpm-package]: https://github.com/jordansissel/fpm/blob/f51ba16fe8659cf2a4996a8e2b2e6a142bbc5b99/lib/fpm/package.rb
[fpm-plugins]: https://github.com/jordansissel/fpm/tree/f51ba16fe8659cf2a4996a8e2b2e6a142bbc5b99/lib/fpm/package
[fpm-dir]: https://github.com/jordansissel/fpm/blob/f51ba16fe8659cf2a4996a8e2b2e6a142bbc5b99/lib/fpm/package/dir.rb
[fpm-deb]: https://github.com/jordansissel/fpm/blob/f51ba16fe8659cf2a4996a8e2b2e6a142bbc5b99/lib/fpm/package/deb.rb
[fpm-apk]: https://github.com/jordansissel/fpm/blob/f51ba16fe8659cf2a4996a8e2b2e6a142bbc5b99/lib/fpm/package/apk.rb
[nfpm-repo]: https://github.com/goreleaser/nfpm
[nfpm-reviewed]: https://github.com/goreleaser/nfpm/tree/6595841499a18755f03356b69511f32a8cec2761
[nfpm-readme]: https://github.com/goreleaser/nfpm/blob/6595841499a18755f03356b69511f32a8cec2761/README.md
[nfpm-example]: https://github.com/goreleaser/nfpm/blob/6595841499a18755f03356b69511f32a8cec2761/internal/cmd/example.yml
[nfpm-core]: https://github.com/goreleaser/nfpm/blob/6595841499a18755f03356b69511f32a8cec2761/nfpm.go
[nfpm-root]: https://github.com/goreleaser/nfpm/blob/6595841499a18755f03356b69511f32a8cec2761/internal/cmd/root.go
[nfpm-package-command]: https://github.com/goreleaser/nfpm/blob/6595841499a18755f03356b69511f32a8cec2761/internal/cmd/package.go
[nfpm-deb]: https://github.com/goreleaser/nfpm/blob/6595841499a18755f03356b69511f32a8cec2761/deb/deb.go
[nfpm-deb-test]: https://github.com/goreleaser/nfpm/blob/6595841499a18755f03356b69511f32a8cec2761/deb/deb_test.go
[nfpm-rpm]: https://github.com/goreleaser/nfpm/blob/6595841499a18755f03356b69511f32a8cec2761/rpm/rpm.go
[nfpm-apk]: https://github.com/goreleaser/nfpm/blob/6595841499a18755f03356b69511f32a8cec2761/apk/apk.go
[nfpm-msix]: https://github.com/goreleaser/nfpm/blob/6595841499a18755f03356b69511f32a8cec2761/msix/msix.go
