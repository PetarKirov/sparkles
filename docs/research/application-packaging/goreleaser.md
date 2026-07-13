# GoReleaser (cross-platform release engineering)

GoReleaser is a declarative release-automation control plane that turns a tagged
source checkout into a graph of binaries, archives, native packages, checksums,
SBOMs, signatures, release assets, package-manager manifests, container images,
and announcements.

| Field             | Value                                                                                        |
| ----------------- | -------------------------------------------------------------------------------------------- |
| Implementation    | Go 1.26.5 at the examined revision                                                           |
| License           | MIT for GoReleaser OSS                                                                       |
| Repository        | [`goreleaser/goreleaser` at the examined revision][repo-tree]                                |
| Documentation     | [Documentation source at the examined revision][docs-tree]                                   |
| Examined revision | `7630cd166fb4dbad0a29ea23cf5e941b66f72b09` (July 10, 2026)                                   |
| Examined version  | `v2.18.0-7630cd16-nightly`                                                                   |
| Configuration     | Versioned YAML, normally `.goreleaser.yaml`; JSON schemas are generated for OSS and Pro      |
| Distributions     | GoReleaser OSS; a separate paid, closed-source GoReleaser Pro binary                         |
| Primary role      | **Release control plane / orchestrator**                                                     |
| Secondary role    | **Application packager and publisher**, through built-in pipes and embedded libraries        |
| Not               | An application-side updater, package-manager daemon, package repository, or format primitive |

**Last reviewed:** July 12, 2026

> [!IMPORTANT]
> **Edition boundary:** this document describes the open-source repository at the
> exact revision above. Features explicitly labelled **Pro** are documented by that
> repository but implemented in the separate paid, closed-source distribution.
> The OSS loader detects `pro: true` and reports that a Pro configuration was given
> to GoReleaser OSS rather than silently treating unknown Pro fields as OSS
> capabilities ([`pkg/config/load.go`][config-load]).

---

## Overview

### What it solves

A release spans more than compilation: target matrices, archive layout, native
package metadata, changelogs, checksums, signing, release-host APIs, container
registries, package-manager catalogs, and announcements must all agree on one
version. GoReleaser centralizes those steps in a versioned configuration and a
single ordered pipeline. Its documentation states the intended replacement for
ad hoc release scripts verbatim ([`www/content/getting-started/intro.md`][intro]):

> “instead of writing scripts, you write a simple YAML configuration file;
> instead of many tools, you (usually) only need a single `goreleaser` binary.”

The “usually” matters. GoReleaser coordinates compilers, Docker, Syft, GPG,
Cosign, Snapcraft, and arbitrary hooks or publishers; it does not hermetically
supply every tool. The official GitHub Actions guidance explicitly leaves
installing, authenticating, and configuring those dependencies to the user
([`www/content/customization/ci/actions.md`][actions]).

### Design philosophy and classification

GoReleaser optimizes the common release path with defaults, then exposes IDs,
filters, Go templates, hooks, and publishers for exceptions. A normal release
starts from a clean Git tree and SemVer-compatible tag, defaults the model,
builds and packages, publishes, then announces; a pipe failure prevents later
pipeline stages from running ([`how-it-works.md`][how-it-works]).

Its correct classification has three layers:

1. **Control plane:** `cmd/release.go` loads configuration, creates a shared
   context, and runs every `pipeline.Pipeline` pipe in order. This is the core
   identity: orchestration of a release transaction, not definition of a file
   format ([`cmd/release.go`][release-command],
   [`internal/pipeline/pipeline.go`][pipeline]).
2. **Application packager/publisher:** archive, nFPM, Snapcraft, Flatpak,
   Makeself, source-RPM, Docker, and catalog pipes do produce distributable
   application artifacts and discovery metadata. This is a substantial built-in
   capability, not merely shelling out to a generic CI script ([pipeline]).
3. **Not a format primitive or updater:** `.deb`, RPM, APK, MSIX, archive, OCI,
   Homebrew, Winget, and other semantics remain owned by their formats and
   package managers. GoReleaser composes those primitives. It emits no library
   linked into the released application, runs no client update loop, and owns no
   installed-state database; generated packages and catalogs delegate lifecycle
   and update behavior to downstream package managers.

### OSS and Pro boundary

| Area                 | GoReleaser OSS                                                                          | GoReleaser Pro                                                                        |
| -------------------- | --------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| Source/license       | This MIT repository                                                                     | Separate paid, closed-source distribution                                             |
| Core flow            | Build, package, sign, publish, announce                                                 | Same model plus additional pipes and orchestration modes                              |
| Notable packaging    | Archives, nFPM packages including MSIX, Flatpak, source RPM, Makeself, Snap, containers | macOS `.app`/`.dmg`/`.pkg`; Windows MSI/NSIS; additional installer handling           |
| Scale/composition    | One YAML file, hooks, templates, custom publishers                                      | Includes, monorepos, split/merge and prepare/continue flows, whole-file templating    |
| Channels/publication | Tagged releases and snapshots                                                           | Nightlies; NPM, Cloudsmith/Gemfury repository integrations; cross-publishing and more |
| Filtering            | IDs, target matrices, skips, templated disable fields                                   | General artifact `if` expressions and richer template/artifact access                 |
| Licensing            | No runtime license key                                                                  | `--key`/`GORELEASER_KEY`; signed offline licenses for eligible plans                  |

The upstream Pro page is the authoritative inventory and describes Pro as “a
paid, closed-source GoReleaser distribution” ([`www/content/pro.md`][pro]). The
boundary is feature-specific: for example, nFPM itself is OSS while templated
nFPM contents/scripts are Pro; custom publishers are OSS while their general
`if` artifact predicate and templated extra files are Pro ([nFPM],
[custom-publishers]).

---

## How it works

### Pipeline and artifact graph

`Piper` is the minimal internal protocol: a string name and
`Run(*context.Context) error`. `BuildPipeline` first cleans/creates `dist`, loads
environment and Git state, parses SemVer, applies defaults, handles snapshot and
partial state, runs hooks, writes metadata/effective configuration, builds,
combines universal binaries, compresses, signs binaries, and notarizes. The full
`Pipeline` appends changelog, packaging, SBOM, checksum and artifact signing,
package-manager metadata, containers, publication, final `artifacts.json`, and
announcements ([pipeline]).

The shared in-memory `Artifacts` collection is the data plane between pipes.
Each `Artifact` records path, name, target dimensions, a typed kind, and an
open-ended `Extra` map. Its mutex-protected `Add` warns about duplicate
uploadable names; composable filters select by type, ID, OS, architecture,
format, and extension. `ReleaseUploadableTypes` is the canonical OSS set used by
checksumming, signing, and release upload ([`internal/artifact/artifact.go`][artifact]).
This is why a package-manager pipe can consume archives produced much earlier
without hard-coding their filesystem discovery.

Publication is itself an ordered sub-pipeline. Blob/upload/Artifactory and
container publishers run before the SCM release; Homebrew, Winget, Nix, AUR,
Krew, Scoop, Chocolatey, and related catalog publishers run after the release
because they need its URL. Publishers normally fail the operation immediately;
only publishers implementing `Continuable`, and only when fail-fast is disabled,
can accumulate errors and continue ([`internal/pipe/publish/publish.go`][publish-pipe]).
This is ordered orchestration with selective concurrency, not an atomic
cross-service transaction: a late failure can leave earlier remote side effects.

### Minimal configuration shape

A representative OSS configuration is:

```yaml
version: 2

builds:
  - id: cli
    main: ./cmd/example
    goos: [linux, darwin, windows]
    goarch: [amd64, arm64]
    flags: [-trimpath]
    mod_timestamp: '{{ .CommitTimestamp }}'

archives:
  - ids: [cli]
    formats: [tar.gz]
    format_overrides:
      - goos: windows
        formats: [zip]

nfpms:
  - ids: [cli]
    formats: [deb, rpm, apk]
    bindir: /usr/bin

checksum:
  name_template: checksums.txt

signs:
  - artifacts: checksum
```

Configuration loading first reads the version marker, accepts version `2`, and
then performs strict YAML decoding. An unsupported version warns and ultimately
produces a `VersionError`; strict decoding catches misspelled or unknown OSS
fields ([config-load]). Effective defaults are written back into `dist`, making
what the pipeline actually used inspectable ([pipeline]).

---

## Input and staging

The primary input is a Git checkout plus `.goreleaser.yaml`. A normal release
expects a clean working tree and a SemVer-compatible current tag; Git history is
also used for previous-tag discovery and changelog generation
([how-it-works]). `--config`, release-note/header/footer files, environment
variables, extra archive/package files, and hook-produced files are additional
inputs ([release-command], [archives]).

Staging is filesystem-based. The default output root is `./dist`; `--clean`
removes it before work, then the dist pipes recreate it. The pipeline writes
`metadata.json` before compilation, writes the fully defaulted effective config,
and accumulates build/package products beneath that root. It writes
`artifacts.json` after publishing so downstream automation sees the final graph
([dist-doc], [pipeline], [`internal/pipe/metadata/metadata.go`][metadata-code]).

Build IDs and target tuples connect stages. Builders create typed binary-like
artifacts; archive and package configurations select upstream build IDs and
platforms; later pipes select the resulting artifact IDs/types. This avoids a
single unstructured staging directory, although actual payloads still live on
the local filesystem and external tools may mutate or add them ([artifact],
[archives], [nFPM]).

Snapshot mode deliberately weakens release validation: `--snapshot` skips
validation, publication, and announcement, rewrites `.Version`, and leaves all
products local in `dist`. `--auto-snapshot` switches to that mode when the tree
is dirty ([release-command], [snapshots]).

## Outputs and targets

GoReleaser supports Go, Rust, Zig, TypeScript through Bun or Deno, and Python;
the source tree contains dedicated builder implementations for those toolchains
([intro], [`internal/builders/`][builders-tree]). The target vocabulary retains
Go-style names (`goos`, `goarch`, `goarm`, `goamd64`, and related variants) even
when the selected builder is not Go.

OSS output families at this revision include:

- raw binaries, universal binaries, C headers/static/shared libraries, and
  source archives;
- `tar.gz`, `tar.xz`, `tar.zst`, `tar`, `gz`, `xz`, ZIP, or unwrapped binary
  archive outputs ([archives]);
- nFPM `.deb`, RPM, APK, IPK, Arch Linux, Termux `.deb`, and Windows MSIX;
  Flatpak bundles, source RPMs, Makeself archives, and Snaps ([nFPM], [pipeline]);
- OCI/container images and manifests, Python wheels and source distributions;
- checksums, signatures/certificates, SBOMs, and release metadata;
- Homebrew casks/formulas, Nix packages, Winget manifests, AUR
  `PKGBUILD`/`.SRCINFO`, Krew and Scoop manifests, and Chocolatey packages
  ([artifact]).

The archive pipe normally groups binaries with README/license/changelog files,
allows per-OS format overrides, preserves or templates modes/owners/timestamps,
and can wrap files in a directory. `format: binary` bypasses archive creation
and makes the binary directly uploadable ([archives]). **Pro** adds application
bundles and installer/disk-image formats documented on the Pro feature list;
those must not be inferred from OSS artifact constants merely because shared
configuration types mention them ([pro], [artifact]).

## Metadata and dependencies

There are two metadata planes. Release metadata (`metadata.json`) records
project, current and previous tags, version, commit, date, and host runtime.
Artifact metadata (`artifacts.json`) serializes each artifact's filename, path,
target, type, and type-specific extras such as format, checksum, size, contained
binaries, image digest, and dynamic-link status ([metadata-code],
[`artifacts.md`][artifacts-doc]).

Package metadata is richer and format-facing. nFPM accepts package name, vendor,
homepage, maintainer, description, license, epoch/prerelease/release, section,
priority, dependency/provides/recommends/suggests/conflicts/replaces relations,
installation directories, contents, ownership/modes, and per-format overrides.
Debian can add `predepends`, `breaks`, triggers, control fields, and debconf
files; RPM, APK, Arch, IPK, and MSIX expose their own controls ([nFPM]). Homebrew
and Winget similarly render ecosystem-specific dependency and descriptive
metadata rather than embedding one universal dependency model ([homebrew],
[winget]).

GoReleaser does not resolve application runtime dependencies into a lockfile.
It records native package relations or catalog requirements and delegates
resolution to apt/dnf/apk/pacman/Homebrew/Winget/etc. Build dependencies are
also external: CI must provision compilers and tools, while Go module proxying
can improve Go source/dependency stability ([actions], [reproducible-builds]).

## Install, upgrade, and uninstall

GoReleaser runs at release time, not on the end user's machine. It therefore has
**no universal install/upgrade/uninstall engine** for the packaged application.
Lifecycle behavior is encoded into the selected output:

- nFPM packages place binaries in `bindir` (default `/usr/bin`), add arbitrary
  files/symlinks/config files/directories, and expose `preinstall`,
  `postinstall`, `preremove`, and `postremove`; APK and Arch add upgrade hooks,
  while format-specific ownership rules determine what removal cleans up
  ([nFPM]);
- Homebrew recipes/casks can express install, post-install, uninstall/zap,
  conflicts, services, completions, and manpages; their package manager owns
  transactions and upgrades ([homebrew-casks]);
- Winget manifests describe installers, package dependencies, URLs, versions,
  and installation notes, while Winget performs discovery and installation
  ([winget]).

There is no rollback coordinator across those ecosystems and no migration
protocol shared by all formats. Script idempotence, daemon restart policy,
configuration preservation, downgrade compatibility, and uninstall cleanup are
package-author responsibilities constrained by each native format.

Installing GoReleaser itself is a separate concern: upstream distributes it via
GitHub releases, Homebrew, NPM, Snap, Scoop, Chocolatey, Winget, apt/yum, AUR,
Nix/NUR, containers, Linux packages, `go install`, a download-and-run script,
and manual archives ([`install/oss.md`][install-oss]). Those channels update or
remove **GoReleaser**, not applications built with it.

## Signing and trust

Checksums default to SHA-256 and can be emitted as one aggregate file or one per
artifact; the code also supports SHA-1/SHA-2 variants, SHA-3, CRC32, MD5,
BLAKE2, and BLAKE3. A checksum proves transport integrity against the manifest,
not publisher identity ([checksums], [artifact]).

The signing pipe defaults to detached GnuPG signatures and can target checksums,
source, packages, archives, SBOMs, binaries, and—where available—installers and
disk images. It is command-driven: users may substitute `gpg2`, Cosign, or any
command that writes/modifies the expected artifact. Signing only the checksum
file is the documented common path; Cosign blob signing can emit a Sigstore
bundle containing signature and certificate ([signing]). Native package signing
is separate: nFPM supports key-backed RPM, Deb, APK, and MSIX signatures with
format- and ID-scoped passphrase environment variables ([nFPM]). Container
signing is another dedicated publisher in the publish pipeline ([publish-pipe]).

Trust policy remains downstream. GoReleaser can create and upload evidence but
does not force clients to verify it, distribute trust roots, or enforce key
rotation/revocation. The project's own installation instructions demonstrate a
stronger consumer workflow: verify the keyless Cosign identity/issuer bundle,
then verify SHA-256 checksums; GitHub attestations and signed container images
are also documented ([install-oss]). **Pro** adds native macOS signing and
notarization and release-asset re-download verification ([pro]).

## Publication and discovery

The SCM release pipe publishes release assets to supported source hosts after
build/package/signing. Other publishers target generic HTTP upload, blob
storage, Artifactory, Docker/OCI registries, Snapcraft, and catalog repositories.
Package-manager generators derive download URLs and checksums from the artifact
graph and release URL, then commit manifests or open pull requests where the
ecosystem requires review ([publish-pipe], [winget]).

Discovery is delegated rather than centralized:

- an SCM release page exposes archives, native packages, checksums, signatures,
  SBOMs, and notes;
- container registries expose image tags/manifests;
- Homebrew taps/casks, Scoop buckets, AUR, Nix/NUR, Krew, Chocolatey, Winget,
  and Snap stores expose their native indexes;
- custom publishers can bridge any unbuilt endpoint by receiving each filtered
  artifact and explicit environment variables ([custom-publishers]).

Ordering has semantic consequences: the SCM release precedes Homebrew/Winget
and similar publishers because their generated metadata needs its URL. There is
no distributed rollback when a later catalog commit fails, so reruns and remote
idempotence need deliberate design ([publish-pipe]).

## Updates and channels

For released applications, GoReleaser supplies versioned artifacts and updates
catalog entries; it does **not** supply an embedded updater. Stable updates
normally follow SemVer Git tags. Prerelease semantics are carried by the tag and
can cause catalog upload to be skipped when configured as `auto` ([how-it-works],
[homebrew], [winget]).

OSS snapshots are local/CI validation products: they rewrite the version and do
not upload. Continuous published **nightly** releases are a **Pro** feature.
Nightlies derive a version from the last stable version and short commit, may
maintain a single GitHub prerelease tag, and intentionally skip Go module
proxying plus most package-manager catalogs and announcers ([snapshots],
[nightlies]). This is a rolling artifact channel, not a client-side update
protocol.

The GoReleaser project itself offers stable and nightly binaries/images. Its
GitHub Action resolves `version: nightly` to an immutable nightly release rather
than blindly running a moving binary, while installation docs warn that
community-owned channels may lag ([actions], [install-oss]).

## Automation and CI

`goreleaser release --clean` is designed as the terminal step of tag-triggered
CI. The official GitHub Action exposes OSS versus Pro distribution, a SemVer
version constraint, arguments, working directory, and install-only mode; it
returns artifact and metadata JSON. The example checks out full history,
provisions Go, grants narrowly described permissions, and passes
`GITHUB_TOKEN` ([actions]).

The release command sets a whole-run timeout (default one hour), uses CPU-count
parallelism unless overridden, and offers `--skip`, `--fail-fast`, custom release
notes, draft mode, snapshots, and clean staging. Build targets are parallelized,
while the outer pipeline remains ordered. Publication is sequential by publisher;
a custom publisher's artifacts are parallelized and therefore must be
concurrency-safe ([release-command], [custom-publishers], [publish-pipe]).

CI is not made hermetic by the action. Full Git history is required; external
programs and registry logins must be installed/configured separately; tokens
need different scopes depending on release assets, packages, milestones, OIDC,
or cross-repository catalog updates ([actions]). This explicit dependency model
is portable but shifts environment drift and secret hygiene to pipeline owners.

## Supply chain and reproducibility

GoReleaser can layer four kinds of evidence: checksums, signatures/certificates,
per-artifact SBOMs, and platform attestations supplied by CI. The SBOM pipe
invokes Syft by default and can target source, package, archive, binary, or all
artifacts, but generated container images are not available to that pipe
([SBOMs]). Signing/checksum pipes consume the canonical uploadable artifact set,
so newly supported formats must be added consistently to that set ([artifact]).

Reproducibility is assisted, not guaranteed. Recommended controls are
`-trimpath`, <span v-pre>`mod_timestamp: "{{ .CommitTimestamp }}"`</span>, embedding the commit date
rather than wall-clock build time, a clean/non-moved tag, Go module proxying, and
pinning the Go/toolchain version. The upstream reproducibility guide explicitly
places compiler-version pinning outside GoReleaser's scope
([reproducible-builds]). Archive and package file mtimes can likewise be set from
`.CommitDate` ([archives], [nFPM]).

Residual nondeterminism includes external tool versions, container base images,
network repositories, host-specific package defaults (for example an RPM build
host unless overridden), wall-clock template functions, hooks, custom
publishers, and remote service behavior. The examined project configuration
models good practice by using commit timestamps and `-trimpath`, but that is a
configuration choice rather than a universal enforcement mechanism
([`.goreleaser.yaml`][self-config], [templates]).

Trust and reproducibility are related but distinct: a valid signature can attest
to a non-reproducible artifact, while a reproducible artifact still needs an
authenticated expected digest. GoReleaser provides mechanisms for both sides but
not an end-to-end mandatory policy.

## Extensibility and UX

The primary extension surface is declarative: stable IDs join builds to
archives/packages; target matrices and ignores shape fan-out; Go templates can
use Git, version, target, environment, release, and artifact fields; and
configuration defaults keep small projects short ([templates], [archives]).
`goreleaser check`/strict loading catches schema mistakes before a release, while
effective-config and artifact JSON make resolved state observable
([config-load], [metadata-code]).

Imperative escape hatches are process-based. OSS global `before` hooks run
commands before the release and abort on failure; **Pro** adds richer hook
objects and global `after` hooks. Build hooks, custom signing/SBOM commands, and
custom publishers cover tool-specific behavior. Custom publishers deliberately
inherit only a small environment allowlist and require explicit secret
forwarding; each publisher runs sequentially, but its artifacts run in parallel
([global-hooks], [custom-publishers], [signing], [SBOMs]).

There is no public dynamic plugin ABI for injecting a new in-process pipe into
the shipped binary. Built-in Go packages register builders and pipes at compile
time; end users extend a stock binary through YAML, templates, commands, and
remote APIs. This keeps distribution simple and failures process-isolated, but
complex custom behavior becomes shell/tool maintenance rather than a typed
extension SDK ([pipeline], [builders-tree], [custom-publishers]).

---

## Strengths

- **End-to-end release graph:** one configuration links compilation, packaging,
  integrity metadata, publication, catalogs, and announcements.
- **Broad output/discovery coverage:** native packages, archives, containers,
  and package-manager manifests share artifact identity and version data.
- **Good local/CI separation:** snapshots exercise production packaging without
  remote side effects.
- **Observable intermediates:** effective configuration, `metadata.json`, and
  `artifacts.json` make pipeline state consumable by later automation.
- **Composable trust mechanisms:** checksums, arbitrary signers, native package
  signatures, SBOMs, Cosign, and CI attestations can be layered.
- **Pragmatic extensibility:** templates, hooks, and per-artifact custom
  publishers cover unusual environments without forking GoReleaser.
- **Strict OSS/Pro configuration signal:** OSS reports accidental Pro configs
  instead of silently claiming support.

## Weaknesses

- **Not hermetic:** compilers, Docker, Syft, signing tools, credentials, and
  network services remain externally provisioned and versioned.
- **No cross-publisher transaction:** late catalog/announcement failure may
  follow already-published release assets or images.
- **No application updater:** channel selection, polling, verification,
  rollback, and installed-state management are delegated to consumers and
  package managers.
- **Format depth varies:** a common pipeline cannot erase native package and
  repository policy differences; format-specific configuration remains large.
- **Important scale and installer features are Pro-only:** split/merge,
  monorepos, nightlies, prepare/continue, and several desktop installers require
  the paid closed-source binary.
- **Process escape hatches trade typing for reach:** hooks and publishers can
  leak nondeterminism, rely on shell semantics, and require their own
  concurrency/idempotence discipline.
- **Go-shaped target vocabulary leaks through:** `goos`/`goarch` naming remains
  central despite support for multiple languages.

## Key design decisions and trade-offs

| Decision                                                    | Rationale                                                                                       | Trade-off                                                                                          |
| ----------------------------------------------------------- | ----------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| Ordered in-process pipe control plane                       | Gives every release a predictable progression and shared context                                | Late failures cannot atomically undo earlier remote effects                                        |
| Typed shared artifact graph                                 | Lets packaging, checksums, signing, metadata, and publishers compose by ID/type/target          | Open-ended `Extra` metadata weakens compile-time guarantees across artifact kinds                  |
| Versioned strict YAML plus defaults                         | Small common configs, early typo detection, inspectable effective config                        | Large native-format surface still produces lengthy YAML; upgrades can require config migration     |
| Git tag/history as release authority                        | Aligns version, changelog, source, and release URLs                                             | Shallow clones, dirty trees, moved tags, and non-SemVer schemes need special handling              |
| Local `dist` staging                                        | Easy inspection, scripting, caching, and snapshot validation                                    | External tools and stale/mutated files can reduce hermeticity; `--clean` matters                   |
| Delegate native formats to nFPM/package managers            | Reuses ecosystem lifecycle and dependency semantics                                             | No uniform install/upgrade/uninstall or rollback behavior                                          |
| External-command hooks, signers, SBOM tools, and publishers | Nearly unlimited integration without a plugin ABI                                               | Tool provisioning, secret handling, shell portability, and reproducibility become user concerns    |
| Publish SCM release before catalog metadata                 | Later recipes/manifests can contain final release URLs and hashes                               | Partial publication is possible if a catalog update fails                                          |
| Separate OSS and Pro binaries                               | Funds advanced orchestration and platform-specific features while preserving a capable MIT core | Closed-source boundary complicates auditability and feature portability                            |
| Snapshot skips validation/publish/announce                  | Safe, fast local and pull-request rehearsal                                                     | It does not fully exercise credentials, remote APIs, catalog review, or announcement failures      |
| No embedded application updater                             | Keeps GoReleaser out of application runtime and installed-state concerns                        | Products needing direct self-update must design discovery, trust, rollout, and rollback separately |

---

## Sources

- [`goreleaser/goreleaser` source tree at `7630cd1`][repo-tree]
- [`internal/pipeline/pipeline.go` — ordered build and release pipes][pipeline]
- [`cmd/release.go` — command flags, context, snapshot semantics, pipeline loop][release-command]
- [`internal/artifact/artifact.go` — artifact types, upload set, metadata, filters][artifact]
- [`internal/pipe/publish/publish.go` — publisher order and failure handling][publish-pipe]
- [`pkg/config/load.go` — versioned strict loading and OSS/Pro error][config-load]
- [`internal/pipe/metadata/metadata.go` — `metadata.json` and `artifacts.json`][metadata-code]
- [Introduction and supported languages][intro]
- [How a release is staged conceptually][how-it-works]
- [GoReleaser Pro feature and licensing boundary][pro]
- [Archive configuration][archives]
- [Homebrew Cask lifecycle and publication configuration][homebrew-casks]
- [nFPM native-package configuration and lifecycle scripts][nFPM]
- [Signing configuration][signing]
- [Checksum configuration][checksums]
- [SBOM configuration][SBOMs]
- [Publication pipeline extension through custom publishers][custom-publishers]
- [Official GitHub Actions integration][actions]
- [Snapshot and Pro nightly channel behavior][snapshots] · [nightlies]
- [Reproducible-build guidance][reproducible-builds]
- [OSS installation and artifact verification][install-oss]

<!-- References -->

[repo-tree]: https://github.com/goreleaser/goreleaser/tree/7630cd166fb4dbad0a29ea23cf5e941b66f72b09
[docs-tree]: https://github.com/goreleaser/goreleaser/tree/7630cd166fb4dbad0a29ea23cf5e941b66f72b09/www/content
[intro]: https://github.com/goreleaser/goreleaser/blob/7630cd166fb4dbad0a29ea23cf5e941b66f72b09/www/content/getting-started/intro.md
[how-it-works]: https://github.com/goreleaser/goreleaser/blob/7630cd166fb4dbad0a29ea23cf5e941b66f72b09/www/content/getting-started/how-it-works.md
[pro]: https://github.com/goreleaser/goreleaser/blob/7630cd166fb4dbad0a29ea23cf5e941b66f72b09/www/content/pro.md
[pipeline]: https://github.com/goreleaser/goreleaser/blob/7630cd166fb4dbad0a29ea23cf5e941b66f72b09/internal/pipeline/pipeline.go
[release-command]: https://github.com/goreleaser/goreleaser/blob/7630cd166fb4dbad0a29ea23cf5e941b66f72b09/cmd/release.go
[artifact]: https://github.com/goreleaser/goreleaser/blob/7630cd166fb4dbad0a29ea23cf5e941b66f72b09/internal/artifact/artifact.go
[publish-pipe]: https://github.com/goreleaser/goreleaser/blob/7630cd166fb4dbad0a29ea23cf5e941b66f72b09/internal/pipe/publish/publish.go
[config-load]: https://github.com/goreleaser/goreleaser/blob/7630cd166fb4dbad0a29ea23cf5e941b66f72b09/pkg/config/load.go
[metadata-code]: https://github.com/goreleaser/goreleaser/blob/7630cd166fb4dbad0a29ea23cf5e941b66f72b09/internal/pipe/metadata/metadata.go
[builders-tree]: https://github.com/goreleaser/goreleaser/tree/7630cd166fb4dbad0a29ea23cf5e941b66f72b09/internal/builders
[dist-doc]: https://github.com/goreleaser/goreleaser/blob/7630cd166fb4dbad0a29ea23cf5e941b66f72b09/www/content/customization/general/dist.md
[artifacts-doc]: https://github.com/goreleaser/goreleaser/blob/7630cd166fb4dbad0a29ea23cf5e941b66f72b09/www/content/customization/general/artifacts.md
[archives]: https://github.com/goreleaser/goreleaser/blob/7630cd166fb4dbad0a29ea23cf5e941b66f72b09/www/content/customization/package/archives.md
[nFPM]: https://github.com/goreleaser/goreleaser/blob/7630cd166fb4dbad0a29ea23cf5e941b66f72b09/www/content/customization/package/nfpm.md
[checksums]: https://github.com/goreleaser/goreleaser/blob/7630cd166fb4dbad0a29ea23cf5e941b66f72b09/www/content/customization/package/checksum.md
[signing]: https://github.com/goreleaser/goreleaser/blob/7630cd166fb4dbad0a29ea23cf5e941b66f72b09/www/content/customization/sign/sign.md
[SBOMs]: https://github.com/goreleaser/goreleaser/blob/7630cd166fb4dbad0a29ea23cf5e941b66f72b09/www/content/customization/sbom.md
[homebrew]: https://github.com/goreleaser/goreleaser/blob/7630cd166fb4dbad0a29ea23cf5e941b66f72b09/www/content/customization/publish/homebrew_formulas.md
[homebrew-casks]: https://github.com/goreleaser/goreleaser/blob/7630cd166fb4dbad0a29ea23cf5e941b66f72b09/www/content/customization/publish/homebrew_casks.md
[winget]: https://github.com/goreleaser/goreleaser/blob/7630cd166fb4dbad0a29ea23cf5e941b66f72b09/www/content/customization/publish/winget.md
[custom-publishers]: https://github.com/goreleaser/goreleaser/blob/7630cd166fb4dbad0a29ea23cf5e941b66f72b09/www/content/customization/publish/publishers.md
[global-hooks]: https://github.com/goreleaser/goreleaser/blob/7630cd166fb4dbad0a29ea23cf5e941b66f72b09/www/content/customization/general/hooks.md
[templates]: https://github.com/goreleaser/goreleaser/blob/7630cd166fb4dbad0a29ea23cf5e941b66f72b09/www/content/customization/general/templates.md
[actions]: https://github.com/goreleaser/goreleaser/blob/7630cd166fb4dbad0a29ea23cf5e941b66f72b09/www/content/customization/ci/actions.md
[snapshots]: https://github.com/goreleaser/goreleaser/blob/7630cd166fb4dbad0a29ea23cf5e941b66f72b09/www/content/customization/publish/snapshots.md
[nightlies]: https://github.com/goreleaser/goreleaser/blob/7630cd166fb4dbad0a29ea23cf5e941b66f72b09/www/content/customization/publish/nightlies.md
[reproducible-builds]: https://github.com/goreleaser/goreleaser/blob/7630cd166fb4dbad0a29ea23cf5e941b66f72b09/www/content/blog/reproducible-builds.md
[install-oss]: https://github.com/goreleaser/goreleaser/blob/7630cd166fb4dbad0a29ea23cf5e941b66f72b09/www/content/getting-started/install/oss.md
[self-config]: https://github.com/goreleaser/goreleaser/blob/7630cd166fb4dbad0a29ea23cf5e941b66f72b09/.goreleaser.yaml
